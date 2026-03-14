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

# Try to sync Weave (best effort)
if [ -x "$WV" ]; then
    "$WV" sync 2>/dev/null || true
fi

# Try to prune old nodes (best effort)
if [ -x "$WV" ]; then
    "$WV" prune --age=48h 2>/dev/null || true
fi

# Derive hot zone path (shared across checkpoint stamp + sentinel cleanup)
_SE_REPO_HASH=$(echo "$WV_PROJECT_DIR" | md5sum | cut -c1-8)
_SE_HOT_ZONE="${WV_HOT_ZONE:-/dev/shm/weave/${_SE_REPO_HASH}}"

# Auto-commit .weave/ state to break drift cycle
# (prevents stop-check blocking on dirty .weave/ from sync/prune above)
# Always amend the most recent checkpoint if one exists in this session (within 2h).
# This collapses all session-end state into a single checkpoint commit.
_LAST_CP=$(git log -1 --format=%ct --grep='auto-checkpoint\|pre-compact checkpoint\|sync state' 2>/dev/null || echo 0)
_NOW=$(date +%s)
_ELAPSED=$((_NOW - _LAST_CP))
git add .weave/ 2>/dev/null || true
if ! git diff --cached --quiet 2>/dev/null; then
    if [ "$_ELAPSED" -lt 7200 ]; then
        # Recent checkpoint exists within session window — amend it
        git commit --amend --no-edit --no-verify 2>/dev/null || \
            git commit -m "chore(weave): auto-checkpoint $(date +%H:%M) [skip ci]" --no-verify 2>/dev/null || true
    else
        git commit -m "chore(weave): auto-checkpoint $(date +%H:%M) [skip ci]" --no-verify 2>/dev/null || true
    fi
    # Update checkpoint stamp so auto_checkpoint sees this commit
    echo "$_NOW" > "${_SE_HOT_ZONE}/.last_checkpoint" 2>/dev/null || true
fi

# Push to remote (best effort — stop-check already validates clean state)
git push 2>/dev/null || true

# Log session end
echo "[$(date -Iseconds)] Session ended: $REASON" >> .claude/session.log 2>/dev/null || true

# Clear crash sentinel on clean shutdown (must be LAST — if sync/push failed
# and stop-check blocked exit, sentinel persists for next session detection)
rm -f "${_SE_HOT_ZONE}/.session_sentinel"

exit 0
