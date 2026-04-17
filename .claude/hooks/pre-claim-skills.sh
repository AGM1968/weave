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
        NODE_JSON=$("$WV" show "$NODE_ID" --json 2>/dev/null || echo "[]")

        # Fail-open on unreadable state.
        # If `wv show` returned [] (node missing, DB unreadable, or a transient
        # auto_sync window where the dumped state is being rewritten), we cannot
        # confidently assess done_criteria/risks — so silently allow the claim
        # and let wv work itself surface a clearer error if the node truly
        # doesn't exist. Blocking on an empty read forces the model to burn a
        # turn on a diagnostic wv show just to recover.
        NODE_COUNT=$(echo "$NODE_JSON" | jq -r 'length // 0' 2>/dev/null || echo "0")
        if [[ "$NODE_COUNT" == "0" || -z "$NODE_COUNT" ]]; then
            exit 0
        fi

        NODE_TEXT=$(echo "$NODE_JSON" | jq -r '.[0].text // ""' 2>/dev/null || echo "")
        HAS_SHIP_IT=$(echo "$NODE_JSON" | jq -r '.[0].metadata | fromjson | has("done_criteria")' 2>/dev/null || echo "false")
        HAS_PRE_MORTEM=$(echo "$NODE_JSON" | jq -r '.[0].metadata | fromjson | has("risks")' 2>/dev/null || echo "false")

        # Only suggest if not already done.
        # Tiers:
        #   - done_criteria missing → soft deny (node is unplanned)
        #   - done_criteria present, risks missing → advisory only (planned but no risk assessment)
        #   - both present → silent pass
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
        fi
    fi
fi

# No suggestion needed — allow silently
exit 0
