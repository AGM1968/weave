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
source "$HOOK_DIR/../lib/wv-resolve-project.sh" 2>/dev/null || source "$HOOK_DIR/../../scripts/lib/wv-resolve-project.sh" || exit 0
cd "$WV_PROJECT_DIR" 2>/dev/null || exit 0

# Check for uncommitted changes (exclude .weave/ — infrastructure files
# auto-committed by auto_checkpoint/session-end-sync, not user work)
UNCOMMITTED=$(git status --porcelain 2>/dev/null | grep -v '\.weave/' | wc -l | tr -d ' ')

if [ "$UNCOMMITTED" -gt 0 ]; then
    # Soft warning: stderr message + exit 0 (does not block)
    echo "Note: $UNCOMMITTED uncommitted change(s). Commit and push before ending your session." >&2
    exit 0
fi

# Check if we're ahead of origin — this means work was committed but not pushed.
# Hard block: the user has finished working (they committed) but forgot to push.
# shellcheck disable=SC1083  # @{u} is a git refspec, not a literal brace
AHEAD=$(git rev-list --count @{u}..HEAD 2>/dev/null || echo "0")

if [ "$AHEAD" -gt 0 ]; then
    cat << EOF
{
    "decision": "block",
    "reason": "There are $AHEAD unpushed commits. Run 'git push' before ending the session."
}
EOF
    exit 1
fi

exit 0
