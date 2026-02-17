#!/bin/bash
# PreToolUse hook: Enforce graph-first before edits (require valid Context Pack)
# Per proposal (lines 204-208):
#   Triggers on: edit_file, create_file, wv done
#   Does NOT trigger on: read-only operations, wv add, wv show

set -e

# Read stdin (JSON payload from Claude Code)
INPUT=$(cat)

# Extract tool name and input
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
TOOL_INPUT=$(echo "$INPUT" | jq -r '.tool_input // empty' 2>/dev/null)

# Block edits to installed copies (should edit source in scripts/ instead)
if [[ "$TOOL" =~ ^(Edit|Write)$ ]]; then
    FILE_PATH=$(echo "$TOOL_INPUT" | jq -r '.file_path // empty' 2>/dev/null)
    if [[ "$FILE_PATH" =~ \.local/(bin|lib/weave) ]]; then
        cat <<EOF
ERROR: Editing installed copy at $FILE_PATH
Edit the SOURCE file instead:
  ~/.local/bin/wv          → scripts/wv
  ~/.local/lib/weave/lib/  → scripts/lib/
  ~/.local/lib/weave/cmd/  → scripts/cmd/
After editing source, run: ./install.sh
EOF
        exit 1
    fi
fi

# Check if this is an operation we should enforce
SHOULD_CHECK=false

# Edit operations (Edit, Write, NotebookEdit, create_file, edit_file)
if [[ "$TOOL" =~ ^(Edit|Write|NotebookEdit)$ ]]; then
    SHOULD_CHECK=true
fi

# Bash commands: wv done or wv-close (but NOT wv add, wv show, wv ready, etc.)
if [[ "$TOOL" == "Bash" ]]; then
    CMD=$(echo "$TOOL_INPUT" | jq -r '.cmd // .command // empty' 2>/dev/null)
    if [[ "$CMD" =~ (wv[[:space:]]+done|wv-close|wv[[:space:]]done) ]]; then
        SHOULD_CHECK=true
    fi
fi

if [ "$SHOULD_CHECK" = "false" ]; then
    exit 0
fi

# Find active node (status=active)
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/../../scripts/lib/wv-resolve-project.sh" || exit 0
if [ ! -x "$WV" ]; then
    # wv not available, allow action
    exit 0
fi

# Get active nodes
ACTIVE_NODES=$("$WV" list --status=active --json 2>/dev/null || echo "[]")
ACTIVE_COUNT=$(echo "$ACTIVE_NODES" | jq 'length' 2>/dev/null || echo "0")

if [ "$ACTIVE_COUNT" = "0" ]; then
    # No active nodes, suggest using /weave to start work
    cat <<EOF
⚠️  No active Weave node found.

Use \`/weave\` to select work before editing files:
- \`/weave\` — Show ready work
- \`/weave wv-xxxx\` — Claim specific node
- \`/weave "description"\` — Create new node

This ensures graph-first workflow with Context Pack generation.
EOF
    exit 1
fi

if [ "$ACTIVE_COUNT" -gt "1" ]; then
    # Multiple active nodes, warn but allow
    echo "⚠️  Warning: Multiple active nodes found. Consider completing one before starting another."
    exit 0
fi

# Get the active node ID
NODE_ID=$(echo "$ACTIVE_NODES" | jq -r '.[0].id' 2>/dev/null)

if [ -z "$NODE_ID" ] || [ "$NODE_ID" = "null" ]; then
    exit 0
fi

# Check if Context Pack has been generated (cache exists or can be generated)
# Per-repo hot zone namespace
_REPO_ROOT_PA=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
_REPO_HASH_PA=$(echo "$_REPO_ROOT_PA" | md5sum | cut -c1-8)
CACHE_DIR="${WV_HOT_ZONE:-/dev/shm/weave/${_REPO_HASH_PA}}/context_cache"
CACHE_FILE="$CACHE_DIR/${NODE_ID}.json"

# Try to generate/retrieve Context Pack
CONTEXT_PACK=$("$WV" context "$NODE_ID" --json 2>/dev/null || echo "")

if [ -z "$CONTEXT_PACK" ]; then
    cat <<EOF
⚠️  Context Pack generation failed for node $NODE_ID.

This is required before editing files. Check:
- Does the node exist? Run: \`wv show $NODE_ID\`
- Is the database accessible? Run: \`wv status\`
EOF
    exit 1
fi

# Check for contradictions
CONTRADICTIONS=$(echo "$CONTEXT_PACK" | jq '.contradictions | length' 2>/dev/null || echo "0")
if [ "$CONTRADICTIONS" -gt "0" ]; then
    CONTRADICTION_LIST=$(echo "$CONTEXT_PACK" | jq -r '.contradictions[] | "  - \(.id): \(.text)"' 2>/dev/null || echo "")
    cat <<EOF
🛑 HARD STOP: Contradictions detected for node $NODE_ID

The following nodes contradict your current work:
$CONTRADICTION_LIST

Resolve contradictions before proceeding:
  \`wv resolve $NODE_ID <other-id> --winner=$NODE_ID\` (if this approach wins)
  \`wv resolve $NODE_ID <other-id> --merge\` (combine both approaches)
  \`wv resolve $NODE_ID <other-id> --defer\` (defer decision, mark as related)

Cannot proceed to EXECUTE phase until contradictions are resolved.
EOF
    exit 1
fi

# Check for blockers (only non-done blockers count)
BLOCKERS=$(echo "$CONTEXT_PACK" | jq '[.blockers[] | select(.status != "done")] | length' 2>/dev/null || echo "0")
if [ "$BLOCKERS" -gt "0" ]; then
    BLOCKER_LIST=$(echo "$CONTEXT_PACK" | jq -r '.blockers[] | select(.status != "done") | "  - \(.id): \(.text)"' 2>/dev/null || echo "")
    cat <<EOF
🛑 BLOCKED: Cannot proceed with node $NODE_ID

This node is blocked by:
$BLOCKER_LIST

Complete the blocking work first, then retry.
Or unblock with: \`wv update $NODE_ID --status=todo\` (removes blocked status)
EOF
    exit 1
fi

# All checks passed - Context Pack is valid, no contradictions, no blockers
# Allow the edit to proceed
exit 0
