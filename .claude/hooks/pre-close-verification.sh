#!/bin/bash
# PreToolUse hook: Require verification evidence before closing work
# Triggers on: wv done <id>

set -e

# Read stdin (JSON payload from Claude Code)
INPUT=$(cat)

# Extract the command from Bash tool use
COMMAND=$(echo "$INPUT" | jq -r '.command // empty' 2>/dev/null)

# Check if this is a wv done command
if [[ "$COMMAND" =~ wv[[:space:]]done[[:space:]]wv-[0-9a-f]{4} ]]; then
    # Extract the node ID
    NODE_ID=$(echo "$COMMAND" | grep -oP 'wv-[0-9a-f]{4}')

    # Get node details
    HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$HOOK_DIR/../../scripts/lib/wv-resolve-project.sh" || exit 0
    if [ -x "$WV" ]; then
        NODE_TEXT=$("$WV" show "$NODE_ID" 2>/dev/null | grep "Text:" | sed 's/^[^:]*: //' || echo "")
        NODE_META=$("$WV" show "$NODE_ID" --json 2>/dev/null | jq -r '.[0]."json(metadata)" // "{}"' 2>/dev/null || echo "{}")
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
                cat <<EOF
{
    "warning": "Verification evidence required before closing",
    "node": "$NODE_ID",
    "text": "$NODE_TEXT",
    "type": "$NODE_TYPE",
    "verification_status": {
        "has_verification": false
    },
    "action_required": "Add verification metadata before completing",
    "options": [
        "wv update $NODE_ID --metadata='{\"verification\":{\"method\":\"test\",\"command\":\"...\",\"result\":\"pass\",\"evidence\":\"...\"}}' && wv done $NODE_ID --learning=\"...\"",
        "wv done $NODE_ID --learning=\"...\"  # For trivial tasks without verification"
    ],
    "rationale": "Verification prevents 'looks right' over 'works right' - CLOSE phase requires evidence"
}
EOF
            fi
        fi
    fi
fi

# Always allow the command to proceed (return success) - hook is advisory
exit 0
