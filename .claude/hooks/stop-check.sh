#!/bin/bash
# Stop hook: Check if session close protocol was followed
# Warns if there are uncommitted changes

set -e

INPUT=$(cat)
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false')

# Prevent infinite loops
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
    exit 0
fi

# Resolve project directory
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/../../scripts/lib/wv-resolve-project.sh" || exit 0
cd "$WV_PROJECT_DIR" 2>/dev/null || exit 0

# Check for uncommitted changes
UNCOMMITTED=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')

if [ "$UNCOMMITTED" -gt 0 ]; then
    cat << EOF
{
    "decision": "block",
    "reason": "There are $UNCOMMITTED uncommitted changes. Run the /close-session skill to properly end the session with git push."
}
EOF
    exit 1
fi

# Check if we're ahead of origin
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
