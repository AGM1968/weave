#!/bin/bash
# PreToolUse hook: Suggest /ship-it and /pre-mortem when claiming work
# Triggers on: wv update <id> --status=active

set -e

# Read stdin (JSON payload from Claude Code)
INPUT=$(cat)

# Extract the command from Bash tool use
COMMAND=$(echo "$INPUT" | jq -r '.command // empty' 2>/dev/null)

# Check if this is a wv update command setting status to active
if [[ "$COMMAND" =~ wv[[:space:]]update[[:space:]]wv-[0-9a-f]{4,6}.*--status=active ]]; then
    # Extract the node ID
    NODE_ID=$(echo "$COMMAND" | grep -oP 'wv-[0-9a-f]{4,6}')

    # Get node details
    HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$HOOK_DIR/../../scripts/lib/wv-resolve-project.sh" || exit 0
    if [ -x "$WV" ]; then
        NODE_TEXT=$("$WV" show "$NODE_ID" 2>/dev/null | grep "Text:" | sed 's/^[^:]*: //' || echo "")
        NODE_TYPE=$("$WV" show "$NODE_ID" --json 2>/dev/null | jq -r '.[0].type // "unknown"' || echo "unknown")

        # Check if ship-it or pre-mortem metadata already exists
        HAS_SHIP_IT=$("$WV" show "$NODE_ID" --json 2>/dev/null | jq -r '.[0].metadata | fromjson | has("done_criteria")' 2>/dev/null || echo "false")
        HAS_PRE_MORTEM=$("$WV" show "$NODE_ID" --json 2>/dev/null | jq -r '.[0].metadata | fromjson | has("risks")' 2>/dev/null || echo "false")

        # Only suggest if not already done
        if [[ "$HAS_SHIP_IT" == "false" || "$HAS_PRE_MORTEM" == "false" ]]; then
            cat <<EOF
{
    "suggestion": "Consider running procedural skills before claiming work",
    "node": "$NODE_ID",
    "text": "$NODE_TEXT",
    "type": "$NODE_TYPE",
    "skills": {
        "ship_it": {
            "needed": $([ "$HAS_SHIP_IT" == "false" ] && echo "true" || echo "false"),
            "purpose": "Define done criteria upfront to prevent scope creep"
        },
        "pre_mortem": {
            "needed": $([ "$HAS_PRE_MORTEM" == "false" ] && echo "true" || echo "false"),
            "purpose": "Identify risks and define rollback plan before starting"
        }
    },
    "recommendation": "Run: /ship-it $NODE_ID && /pre-mortem $NODE_ID before proceeding"
}
EOF
        fi
    fi
fi

# Always allow the command to proceed (return success)
exit 0
