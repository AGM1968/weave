#!/bin/bash
# PreToolUse hook: Require verification evidence before closing work
# Triggers on: wv done <id>

set -e

# Read stdin (JSON payload from Claude Code)
INPUT=$(cat)

# Extract the command from Bash tool use
COMMAND=$(echo "$INPUT" | jq -r '.command // empty' 2>/dev/null)

# Check if this is a wv done command
if [[ "$COMMAND" =~ wv[[:space:]]done[[:space:]]wv-[0-9a-f]{4,6} ]]; then
    # Check for --skip-verification flag
    if [[ "$COMMAND" =~ --skip-verification ]]; then
        exit 0
    fi

    # Extract the node ID
    NODE_ID=$(echo "$COMMAND" | grep -oP 'wv-[0-9a-f]{4,6}')

    # Get node details
    HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$HOOK_DIR/../../scripts/lib/wv-resolve-project.sh" || exit 0
    if [ -x "$WV" ]; then
        NODE_TEXT=$("$WV" show "$NODE_ID" 2>/dev/null | grep "Text:" | sed 's/^[^:]*: //' || echo "")
        NODE_META=$("$WV" show "$NODE_ID" --json 2>/dev/null | jq -r '.[0].metadata // "{}"' 2>/dev/null || echo "{}")
        NODE_TYPE=$(echo "$NODE_META" | jq -r '.type // "unknown"' 2>/dev/null || echo "unknown")

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
                # Build and self-validate JSON before output
                JSON_OUT=$(jq -n \
                    --arg node "$NODE_ID" \
                    --arg reason "Verification evidence required before closing $NODE_ID. Add verification metadata or use --skip-verification for trivial tasks." \
                    --arg pdr "Node $NODE_ID has no verification metadata. Verification enforces 'works right' over 'looks right' before the CLOSE phase." \
                    '{
                        "decision": "block",
                        "reason": $reason,
                        "permissionDecisionReason": $pdr,
                        "node": $node,
                        "options": [
                            "wv update <id> --metadata='"'"'{\"verification\":{\"method\":\"test\",\"command\":\"...\",\"result\":\"pass\",\"evidence\":\"...\"}}'"'"' && wv done <id> --learning=\"...\"",
                            "wv done <id> --skip-verification --learning=\"...\"  # Explicitly bypass for trivial tasks"
                        ]
                    }')
                echo "$JSON_OUT"
                exit 0
            fi
        fi
    fi
fi

# No issues found — allow the command to proceed
exit 0
