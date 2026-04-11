#!/bin/bash
# PreToolUse hook: Require verification evidence before closing work
# Triggers on: wv done <id>

set -e

# Read stdin (JSON payload from Claude Code)
INPUT=$(cat)

# Fast path: skip jq if stdin doesn't contain our trigger pattern
case "$INPUT" in
    *"wv done"*) ;;
    *"wv ship"*) ;;
    *) exit 0 ;;
esac

# Extract the command from Bash tool use.
# Real PreToolUse payloads nest terminal commands under tool_input.{cmd,command},
# while older tests used a top-level .command field.
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.cmd // .tool_input.command // .command // empty' 2>/dev/null)

# Check if this is a wv done/ship command
if [[ "$COMMAND" =~ wv[[:space:]](done|ship)[[:space:]]wv-[0-9a-f]{4,6} ]]; then
    # Extract the node ID
    NODE_ID=$(echo "$COMMAND" | grep -oP 'wv-[0-9a-f]{4,6}')

    # Get node details
    HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$HOOK_DIR/../lib/wv-resolve-project.sh" 2>/dev/null || source "$HOOK_DIR/../../scripts/lib/wv-resolve-project.sh" || exit 0
    if [ -x "$WV" ]; then
        NODE_TEXT=$("$WV" show "$NODE_ID" 2>/dev/null | grep "Text:" | sed 's/^[^:]*: //' || echo "")
        NODE_META=$("$WV" show "$NODE_ID" --json 2>/dev/null | jq -r '.[0].metadata // "{}"' 2>/dev/null || echo "{}")
        NODE_TYPE=$(echo "$NODE_META" | jq -r '.type // "unknown"' 2>/dev/null || echo "unknown")

        if [[ "$NODE_TYPE" == "finding" ]]; then
            MISSING_FINDING=$(echo "$NODE_META" | jq -r '
                (.finding // {}) as $finding |
                [
                    (if (($finding.violation_type // null) | type) == "string" and (($finding.violation_type | gsub("^\\s+|\\s+$"; "")) | length) > 0 then empty else "finding.violation_type" end),
                    (if (($finding.root_cause // null) | type) == "string" and (($finding.root_cause | gsub("^\\s+|\\s+$"; "")) | length) > 0 then empty else "finding.root_cause" end),
                    (if (($finding.proposed_fix // null) | type) == "string" and (($finding.proposed_fix | gsub("^\\s+|\\s+$"; "")) | length) > 0 then empty else "finding.proposed_fix" end),
                    (if (["high", "medium", "low"] | index(($finding.confidence // "") | tostring)) != null then empty else "finding.confidence" end),
                    (if ($finding.fixable | type) == "boolean" then empty else "finding.fixable" end),
                    (if (($finding | has("evidence_sessions")) | not) or ((($finding.evidence_sessions // null) | type) == "array" and ([$finding.evidence_sessions[]? | select((type != "string") or ((gsub("^\\s+|\\s+$"; "")) | length == 0))] | length) == 0) then empty else "finding.evidence_sessions" end)
                ] | join(", ")
            ' 2>/dev/null || echo "")
            if [[ -n "$MISSING_FINDING" ]]; then
                jq -n \
                    --arg detail "Finding nodes require structured metadata before close. Missing or invalid: $MISSING_FINDING. Run: wv update $NODE_ID --metadata='{\"finding\":{\"violation_type\":\"...\",\"root_cause\":\"...\",\"proposed_fix\":\"...\",\"confidence\":\"high\",\"fixable\":true}}' first." \
                    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $detail}}'
                exit 0
            fi
        fi

        # Check for --skip-verification flag
        if [[ "$COMMAND" =~ --skip-verification ]]; then
            exit 0
        fi

        # Inline verification flags satisfy the requirement without a prior wv update
        if [[ "$COMMAND" =~ --verification-method= ]] || [[ "$COMMAND" =~ --verification-evidence= ]]; then
            exit 0
        fi

        # Check if verification metadata already exists
        HAS_VERIFICATION=$(echo "$NODE_META" | jq -r 'has("verification")' 2>/dev/null || echo "false")

        # Also check old schema for backward compatibility
        HAS_LEGACY_VERIFICATION=$(echo "$NODE_META" | jq -r '(has("verification_method") or has("verification_evidence"))' 2>/dev/null || echo "false")

        # Require verification for non-trivial work
        if [[ "$HAS_VERIFICATION" == "false" && "$HAS_LEGACY_VERIFICATION" == "false" ]]; then
            # Check if this is trivial (breadcrumbs, test nodes, etc.)
            IS_TRIVIAL=false
            if [[ "$NODE_TYPE" == "breadcrumbs" ]] || [[ "$NODE_TEXT" =~ ^Test ]]; then
                IS_TRIVIAL=true
            fi

            if [[ "$IS_TRIVIAL" == "false" ]]; then
                # PreToolUse soft deny (exit 0 + hookSpecificOutput JSON)
                # Schema: hookSpecificOutput.permissionDecision (current API, not deprecated top-level)
                # "deny" is lowercase — "DENY" silently fails (original bug)
                jq -n \
                    --arg node "$NODE_ID" \
                    --arg detail "Run: wv done $NODE_ID --verification-method=\"make check\" --verification-evidence=\"all tests pass\" ... — or wv update $NODE_ID --metadata='{\"verification_method\":\"...\"}' first — or --skip-verification for trivial tasks." \
                    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $detail}}'
                exit 0
            fi
        fi
    fi
fi

# No issues found — allow the command to proceed
exit 0
