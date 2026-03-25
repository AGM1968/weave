#!/bin/bash
# PreToolUse hook: Suggest /ship-it and /pre-mortem when claiming work
# Triggers on: wv update <id> --status=active

set -e

# Read stdin (JSON payload from Claude Code)
INPUT=$(cat)

# Fast path: skip jq if stdin doesn't contain our trigger pattern
case "$INPUT" in
    *"wv update"*"--status=active"*) ;;
    *"wv work"*) ;;
    *) exit 0 ;;
esac

# Extract the command from Bash tool use.
# Real PreToolUse payloads nest terminal commands under tool_input.{cmd,command},
# while older tests used a top-level .command field.
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.cmd // .tool_input.command // .command // empty' 2>/dev/null)

# Check if this is a claim command in either the old or current workflow.
if [[ "$COMMAND" =~ wv[[:space:]]update[[:space:]]wv-[0-9a-f]{4,6}.*--status=active ]] || \
   [[ "$COMMAND" =~ wv[[:space:]]work[[:space:]]wv-[0-9a-f]{4,6} ]]; then
    # Extract the node ID
    NODE_ID=$(echo "$COMMAND" | grep -oP 'wv-[0-9a-f]{4,6}')

    # Get node details
    HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$HOOK_DIR/../lib/wv-resolve-project.sh" 2>/dev/null || source "$HOOK_DIR/../../scripts/lib/wv-resolve-project.sh" || exit 0
    if [ -x "$WV" ]; then
        NODE_TEXT=$("$WV" show "$NODE_ID" 2>/dev/null | grep "Text:" | sed 's/^[^:]*: //' || echo "")
        NODE_TYPE=$("$WV" show "$NODE_ID" --json 2>/dev/null | jq -r '.[0].type // "unknown"' || echo "unknown")

        # Check if ship-it or pre-mortem metadata already exists
        HAS_SHIP_IT=$("$WV" show "$NODE_ID" --json 2>/dev/null | jq -r '.[0].metadata | fromjson | has("done_criteria")' 2>/dev/null || echo "false")
        HAS_PRE_MORTEM=$("$WV" show "$NODE_ID" --json 2>/dev/null | jq -r '.[0].metadata | fromjson | has("risks")' 2>/dev/null || echo "false")

        # Only suggest if not already done
        if [[ "$HAS_SHIP_IT" == "false" || "$HAS_PRE_MORTEM" == "false" ]]; then
            # Build suggestion parts
            skills_needed=""
            if [ "$HAS_SHIP_IT" == "false" ]; then
                skills_needed="/ship-it (done criteria)"
            fi
            if [ "$HAS_PRE_MORTEM" == "false" ]; then
                [ -n "$skills_needed" ] && skills_needed="$skills_needed and "
                skills_needed="${skills_needed}/pre-mortem (risks)"
            fi

            # Soft deny: model sees the reason and can choose to proceed
            cat <<EOF
{"decision": "block", "reason": "Consider running $skills_needed before claiming $NODE_ID ($NODE_TEXT). Proceed with wv update if already done."}
EOF
            exit 0
        fi
    fi
fi

# No suggestion needed — allow silently
exit 0
