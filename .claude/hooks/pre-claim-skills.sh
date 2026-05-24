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
        # wv show --json returns a compact object (not array) for single-ID queries.
        # Fail-open when node is missing or DB is unreadable — let wv work surface errors.
        NODE_JSON=$("$WV" show "$NODE_ID" --json 2>/dev/null || true)
        if [[ -z "$NODE_JSON" ]] || [[ "$NODE_JSON" = "[]" ]]; then
            exit 0
        fi

        NODE_TEXT=$(echo "$NODE_JSON" | jq -r '.text // ""' 2>/dev/null || echo "")
        HAS_SHIP_IT=$(echo "$NODE_JSON" | jq -r '.metadata | fromjson | has("done_criteria")' 2>/dev/null || echo "false")
        HAS_PRE_MORTEM=$(echo "$NODE_JSON" | jq -r '.metadata | fromjson | has("risks")' 2>/dev/null || echo "false")
        NODE_ALIAS=$(echo "$NODE_JSON" | jq -r '.alias // ""' 2>/dev/null || echo "")

        # Tiers (checked in order — first failing tier blocks):
        #   1. done_criteria missing → soft deny (node is unplanned)
        #   2. risks missing → advisory (planned but no risk assessment)
        #   3. alias missing → soft deny (graph unreadable without aliases)
        #   4. all present → silent pass
        if [[ "$HAS_SHIP_IT" == "false" ]]; then
            reason="Run /ship-it before claiming $NODE_ID ($NODE_TEXT) — done_criteria not set. Use --criteria= on wv add, or: wv update $NODE_ID --metadata='{\"done_criteria\":[...]}'"
            jq -n --arg reason "$reason" \
                '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$reason}}'
            exit 0
        elif [[ "$HAS_PRE_MORTEM" == "false" ]]; then
            reason="Consider running /pre-mortem (risks) before claiming $NODE_ID ($NODE_TEXT). Proceed with wv update if already done."
            jq -n --arg reason "$reason" \
                '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$reason}}'
            exit 0
        elif [[ -z "$NODE_ALIAS" ]]; then
            reason="Set an alias before claiming $NODE_ID — graph is unreadable without short names. Run: wv update $NODE_ID --alias=<short-name>"
            jq -n --arg reason "$reason" \
                '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$reason}}'
            exit 0
        fi
    fi
fi

# No suggestion needed — allow silently
exit 0
