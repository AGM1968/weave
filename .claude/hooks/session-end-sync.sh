#!/bin/bash
# SessionEnd hook: Final sync before exit
# Syncs Weave state to git layer + clears crash sentinel (v1.16.0)

set -e

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/../lib/wv-resolve-project.sh" 2>/dev/null || source "$HOOK_DIR/../../scripts/lib/wv-resolve-project.sh" || exit 0

# Read input for reason
INPUT=$(cat)
REASON=$(echo "$INPUT" | jq -r '.reason // "unknown"')

cd "$WV_PROJECT_DIR" 2>/dev/null || exit 0

# Prune before sync so baseline captures prune state.
# Without this ordering, pruned nodes reappear on next load (state.sql
# is dumped pre-prune, and prune DELETEs are suppressed from deltas).
if [ -x "$WV" ]; then
    "$WV" prune --age=48h 2>/dev/null || true
fi

# Sync Weave state to git layer + GitHub issue state (best effort).
# Phase B: session-end uses fast mode — bounded to the union of impacted sets
# for currently active nodes. Run `wv sync --gh --mode=full` for an exhaustive
# reconcile when GitHub state has drifted.
if [ -x "$WV" ]; then
    "$WV" sync --gh --mode=fast 2>/dev/null || true
fi

# Local state flush: ensure state.sql reflects current DB regardless of GH sync
# outcome. wv sync --gh may skip nodes outside the fast-mode impacted set; a
# plain wv sync (no --gh) force-dumps the full DB so wv load on the next session
# (including post-reboot) does not restore stale active-node status.
if [ -x "$WV" ]; then
    "$WV" sync 2>/dev/null || true
fi

# Derive hot zone path (shared across checkpoint stamp + sentinel cleanup)
_SE_REPO_HASH=$(echo "$WV_PROJECT_DIR" | md5sum | cut -c1-8)
_SE_HOT_ZONE="${WV_HOT_ZONE:-/dev/shm/weave/${_SE_REPO_HASH}}"

# Auto-commit .weave/ state to break drift cycle
# (prevents stop-check blocking on dirty .weave/ from sync/prune above)
# Amend only when HEAD is itself an unpushed weave-only checkpoint commit —
# same three-guard rule as auto_checkpoint in wv-cmd-data.sh:
#   (a) unpushed  (b) subject matches checkpoint patterns  (c) no non-.weave files
git add .weave/ 2>/dev/null || true
if ! git diff --cached --quiet 2>/dev/null; then
    _SE_BRANCH=$(git branch --show-current 2>/dev/null || echo "main")
    _SE_LOCAL_HEAD=$(git rev-parse HEAD 2>/dev/null || echo "")
    _SE_REMOTE_HEAD=$(git rev-parse "origin/$_SE_BRANCH" 2>/dev/null || echo "none")
    _SE_LAST_MSG=$(git log -1 --format='%s' 2>/dev/null || echo "")
    _SE_LAST_NW=$(git diff HEAD~1 HEAD --name-only 2>/dev/null | grep -v '^\.weave/' | grep -v '^$' || true)
    _NOW=$(date +%s)
    if [ "$_SE_LOCAL_HEAD" != "$_SE_REMOTE_HEAD" ] \
       && [[ "$_SE_LAST_MSG" =~ auto-checkpoint|sync\ state|session-start\ state|pre-compact\ checkpoint ]] \
       && [ -z "$_SE_LAST_NW" ]; then
        # HEAD is an unpushed weave-only checkpoint — safe to amend
        WV_AUTO_CHECKPOINT_ACTIVE=1 git commit --amend --no-edit 2>/dev/null || \
            WV_AUTO_CHECKPOINT_ACTIVE=1 git commit -m "chore(weave): auto-checkpoint $(date +%H:%M) [skip ci]" 2>/dev/null || true
    else
        WV_AUTO_CHECKPOINT_ACTIVE=1 git commit -m "chore(weave): auto-checkpoint $(date +%H:%M) [skip ci]" 2>/dev/null || true
    fi
    # Update checkpoint stamp so auto_checkpoint sees this commit
    echo "$_NOW" > "${_SE_HOT_ZONE}/.last_checkpoint" 2>/dev/null || true
fi

# Push to remote with exponential backoff (multi-agent contention)
# Skip if no remote configured (e.g. test environments, local-only repos)
if git remote get-url origin >/dev/null 2>&1; then
    for _se_attempt in 1 2 3 4 5; do
        git push 2>/dev/null && break
        [ "$_se_attempt" -lt 5 ] && sleep $(( (2 ** _se_attempt) + RANDOM % 3 ))
        git pull --rebase --autostash --quiet 2>/dev/null || true
    done
fi

# Log session end
echo "[$(date -Iseconds)] Session ended: $REASON" >> .claude/session.log 2>/dev/null || true

# Clear crash sentinel on clean shutdown (must be LAST — if sync/push failed
# and stop-check blocked exit, sentinel persists for next session detection)
rm -f "${_SE_HOT_ZONE}/.session_sentinel"

exit 0
