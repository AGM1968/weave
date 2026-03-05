#!/bin/bash
# Test: wv add --parent preserves child ID in stdout
# Regression test for bug where invalidate_context_cache clobbered $id variable
# Fixed in: scripts/lib/wv-cache.sh (use node_id instead of id in for loop)
#
# Root cause: invalidate_context_cache used `for id in ...` without local declaration,
# which overwrote the caller's $id variable with the last node ID in the loop (parent ID).

set -euo pipefail

echo "━━━ Test: wv add --parent preserves child ID ━━━"

# Use timestamp to avoid alias collisions
timestamp=$(date +%s)

# Create parent node
parent_id=$(wv add "Test parent epic $$-$timestamp" --status=todo --force 2>&1 | tail -1)
echo "Created parent: $parent_id"

# Create child with --parent 
child_id=$(wv add "Test child task $$-$timestamp" --parent="$parent_id" --alias=test-child-$$-$timestamp --force 2>&1 | tail -1)

echo "Output child ID: $child_id"

# Verify child ID is different from parent ID
if [  "$child_id" = "$parent_id" ]; then
    echo "❌ FAIL: Child ID equals parent ID (bug reproduced!)"
    wv delete "$parent_id" --force --no-gh 2>/dev/null || true
    exit 1
fi

# Verify child ID format
if ! [[ "$child_id" =~ ^wv-[a-f0-9]{6}$ ]]; then
    echo "❌ FAIL: Invalid child ID format: $child_id"
    wv delete "$parent_id" --force --no-gh 2>/dev/null || true
    exit 1
fi

# Verify child node exists
if ! wv show "$child_id" >/dev/null 2>&1; then
    echo "❌ FAIL: Child node not found"
    wv delete "$parent_id" --force --no-gh 2>/dev/null || true
    exit 1
fi

echo "✓ All checks passed"

# Cleanup
wv delete "$child_id" --force --no-gh 2>/dev/null || true
wv delete "$parent_id" --force --no-gh 2>/dev/null || true

echo "✓ PASS: wv add --parent preserves child ID correctly"
