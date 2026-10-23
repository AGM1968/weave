#!/bin/bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# Test: wv add --parent preserves child ID in stdout
# Regression test for bug where invalidate_context_cache clobbered $id variable
# Fixed in: scripts/lib/wv-cache.sh (use node_id instead of id in for loop)
#
# Root cause: invalidate_context_cache used `for id in ...` without local declaration,
# which overwrote the caller's $id variable with the last node ID in the loop (parent ID).

set -euo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)

# This suite had NO isolation: it called whatever `wv` was on PATH, against
# whatever graph was ambient, and created and deleted nodes there. That was
# survivable while nothing ran it -- it was one of thirteen suites outside every
# aggregate. The moment it joined one it wrote to the repository under test from
# inside a parallel batch, and took Data Commands and Sprint 3+4 Commands down
# with it; a failure partway through would also have left its two nodes in a real
# user's graph. Isolate it the way every other suite is isolated, and drive the
# repository's own scripts/wv rather than an installed one that may not be the
# code under test.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$PROJECT_ROOT/scripts/wv"
TEST_DIR="/tmp/wv-gh-issue-body-test-$$"
export WV_HOT_ZONE="$TEST_DIR"
export WV_DB="$TEST_DIR/brain.db"
export WV_PROJECT_DIR="$TEST_DIR"
export WV_REQUIRE_LEARNING=0
export WV_AUTO_SYNC=0
export WV_AUTO_CHECKPOINT=0
cleanup() { cd /tmp; rm -rf "$TEST_DIR"; }
trap cleanup EXIT

rm -rf "$TEST_DIR"; mkdir -p "$TEST_DIR"
cd "$TEST_DIR"
git init -q
"$WV" init >/dev/null 2>&1 || true

echo "━━━ Test: wv add --parent preserves child ID ━━━"

# Use timestamp to avoid alias collisions
timestamp=$(date +%s)

# `2>&1 | tail -1` was how both ids were read, and it is the reason this suite
# failed inside the aggregate while passing standalone: it merges stderr into
# the capture and then trusts whatever line happens to be last. `wv add` prints
# a confirmation line and then the bare id, so any advisory or warning that
# lands after it -- far likelier under a parallel batch -- becomes the "id", and
# the suite went on to use "✓ wv-4d78d7: Test parent epic ..." as a node id.
# Read stdout only, and take the last line that IS an id.
node_id_from() { grep -oE '^wv-[a-f0-9]{6}$' | tail -1; }

# Create parent node
parent_id=$("$WV" add "Test parent epic $$-$timestamp" --status=todo --force 2>/dev/null | node_id_from)
echo "Created parent: $parent_id"

# Create child with --parent
child_id=$("$WV" add "Test child task $$-$timestamp" --parent="$parent_id" --alias=test-child-$$-$timestamp --force 2>/dev/null | node_id_from)

echo "Output child ID: $child_id"

# Verify child ID is different from parent ID
if [  "$child_id" = "$parent_id" ]; then
    echo "❌ FAIL: Child ID equals parent ID (bug reproduced!)"
    "$WV" delete "$parent_id" --force --no-gh 2>/dev/null || true
    exit 1
fi

# Verify child ID format
if ! [[ "$child_id" =~ ^wv-[a-f0-9]{6}$ ]]; then
    echo "❌ FAIL: Invalid child ID format: $child_id"
    "$WV" delete "$parent_id" --force --no-gh 2>/dev/null || true
    exit 1
fi

# Verify child node exists
if ! "$WV" show "$child_id" >/dev/null 2>&1; then
    echo "❌ FAIL: Child node not found"
    "$WV" delete "$parent_id" --force --no-gh 2>/dev/null || true
    exit 1
fi

echo "✓ All checks passed"

# Cleanup
"$WV" delete "$child_id" --force --no-gh 2>/dev/null || true
"$WV" delete "$parent_id" --force --no-gh 2>/dev/null || true

echo "✓ PASS: wv add --parent preserves child ID correctly"
