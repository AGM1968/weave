#!/bin/bash
# Stop hook: Soft-warn on uncommitted changes, hard-block on unpushed commits.
#
# Design rationale (wv-2291e6):
#   Uncommitted changes → user is probably still working → warn via stderr, exit 0
#   Unpushed commits    → user committed but forgot to push → block, exit 1
#
# The stop hook fires every time Claude finishes a response, not just at session
# end. Blocking on uncommitted changes forces close-session protocol even when
# the user wants to keep working. Soft warnings let the conversation continue.

set -e

INPUT=$(cat)
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false')

# Prevent infinite loops
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
    exit 0
fi

# Resolve project directory
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HOOK_DIR/../lib/wv-resolve-project.sh" 2>/dev/null || source "$HOOK_DIR/../../scripts/lib/wv-resolve-project.sh" || exit 0
cd "$WV_PROJECT_DIR" 2>/dev/null || exit 0

# Cooldown lock: after emitting a block, suppress re-blocking for 120s.
# The dirty-state checks still run; only the hard block (exit 1) is suppressed.
# This lets the agent make progress on sync commands without being blocked on
# every response, while still enforcing a clean state after cooldown expires.
_SC_REPO_HASH=$(echo "$WV_PROJECT_DIR" | md5sum | cut -c1-8)
_SC_HOT_ZONE="${WV_HOT_ZONE:-/dev/shm/weave/${_SC_REPO_HASH}}"
_SC_LOCK="${_SC_HOT_ZONE}/.stop_check_lock"
_SC_IN_COOLDOWN=false
if [ -f "$_SC_LOCK" ]; then
    _sc_lock_ts=$(cat "$_SC_LOCK" 2>/dev/null || echo 0)
    _sc_now=$(date +%s)
    if [ $((_sc_now - _sc_lock_ts)) -lt 120 ]; then
        _SC_IN_COOLDOWN=true
    fi
fi

# Warn on active nodes that haven't been updated recently (crash/abandon signal).
# Nodes active for >30 min with no update suggest a crashed or abandoned session.
if [ -x "${WV:-wv}" ] || command -v wv >/dev/null 2>&1; then
    _WV="${WV:-wv}"
    IDLE_NODES=$("$_WV" list --json 2>/dev/null | jq -r --argjson cutoff "$(date -d '30 minutes ago' +%s 2>/dev/null || date -v-30M +%s 2>/dev/null || echo 0)" \
        '.[] | select(.status=="active") | select((.updated_at | strptime("%Y-%m-%d %H:%M:%S") | mktime) < $cutoff) | "  \(.id): \(.text[:60])"' 2>/dev/null || true)
    if [ -n "$IDLE_NODES" ]; then
        echo "Note: active node(s) with no update in >30 min — possible abandoned work:" >&2
        echo "$IDLE_NODES" >&2
        echo "  Close with: wv done <id> --skip-verification" >&2
    fi
fi

# Check for uncommitted changes (exclude .weave/ — infrastructure files
# auto-committed by auto_checkpoint/session-end-sync, not user work)
UNCOMMITTED=$(git status --porcelain 2>/dev/null | grep -vc '\.weave/' || true)

if [ "$UNCOMMITTED" -gt 0 ]; then
    # Soft warning: stderr message + exit 0 (does not block)
    echo "Note: $UNCOMMITTED uncommitted change(s). Commit and push before ending your session." >&2
    exit 0
fi

# Check for dirty .weave/ state (sync not yet run — breadcrumbs/nodes still local)
WEAVE_DIRTY=$(git status --porcelain 2>/dev/null | grep -c '\.weave/' || true)
# Check if we're ahead of origin
# shellcheck disable=SC1083  # @{u} is a git refspec, not a literal brace
AHEAD=$(git rev-list --count @{u}..HEAD 2>/dev/null || echo "0")

# Soft warn on unsaved weave state (does not block — auto-checkpoint handles this)
if [ "$WEAVE_DIRTY" -gt 0 ] && [ "$AHEAD" -eq 0 ]; then
    echo "Note: unsaved weave state. Run: wv sync --gh && git add .weave/ && git commit -m 'chore(weave): sync state [skip ci]' && git push" >&2
    exit 0
fi

# Hard block only on unpushed commits — real work loss risk
if [ "$AHEAD" -gt 0 ]; then
    PARTS="$AHEAD unpushed commit(s)"
    if [ "$WEAVE_DIRTY" -gt 0 ]; then
        PARTS="$PARTS, unsaved weave state"
        SYNC_CMD="wv sync --gh && git add .weave/ && git commit -m 'chore(weave): sync state [skip ci]' && git push"
    else
        SYNC_CMD="git push"
    fi
    if [ "$_SC_IN_COOLDOWN" = true ]; then
        echo "Note: $PARTS (sync in progress — cooldown active)." >&2
        exit 0
    fi
    mkdir -p "$_SC_HOT_ZONE" 2>/dev/null || true
    date +%s > "$_SC_LOCK" 2>/dev/null || true
    cat << EOF
{
    "decision": "block",
    "reason": "$PARTS. Run: $SYNC_CMD"
}
EOF
    exit 1
fi

# State is clean — clear any stale cooldown lock so the next session isn't skipped
rm -f "$_SC_LOCK" 2>/dev/null || true
exit 0
