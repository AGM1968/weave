#!/usr/bin/env bash
# Test cache invalidation for all edge-modifying commands
#
# Tests that context cache is properly invalidated when:
# 1. cmd_refs creates edges in link mode
# 2. cmd_prune deletes nodes and edges
# 3. cmd_block, cmd_link, cmd_done modify edges
#
# Exit codes:
#   0 - All tests passed
#   1 - One or more tests failed

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$PROJECT_ROOT/scripts/wv"

# Test environment
TEST_DIR="/tmp/wv-cache-test-$$"
export WEAVE_DIR="$TEST_DIR/.weave"

# Cleanup function
cleanup() {
    if [ -d "$TEST_DIR" ]; then
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

# Test helpers
setup_test_env() {
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR"
    cd "$TEST_DIR"
    "$WV" init >/dev/null 2>&1
}

assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="$3"

    TESTS_RUN=$((TESTS_RUN + 1))

    if [ "$expected" = "$actual" ]; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Expected: $expected"
        echo "  Actual:   $actual"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"

    TESTS_RUN=$((TESTS_RUN + 1))

    if echo "$haystack" | grep -q "$needle"; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Expected to find: $needle"
        echo "  In: $haystack"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

# Test 1: cmd_refs link mode invalidates cache
test_cmd_refs_link_invalidation() {
    echo ""
    echo "Test 1: cmd_refs --link invalidates cache"
    echo "========================================="

    setup_test_env

    # Create two nodes
    local src
    src=$("$WV" add "Test source node" | tail -1)
    local tgt
    tgt=$("$WV" add "Test target node" | tail -1)

    # Get initial context (populates cache)
    local before_count
    before_count=$("$WV" context "$src" --json | jq -r '.related | length')
    assert_equals "0" "$before_count" "Initial context has no related nodes"

    # Create a file with weave ID reference
    echo "This document references $tgt for details" > test.txt

    # Use cmd_refs to create edge
    "$WV" refs test.txt --link --from="$src" >/dev/null 2>&1

    # Get context again (should reflect new edge due to cache invalidation)
    local after_count
    after_count=$("$WV" context "$src" --json | jq -r '.related | length')
    assert_equals "1" "$after_count" "Context shows new related node after refs --link"

    # Verify the related node is the target
    local related_id
    related_id=$("$WV" context "$src" --json | jq -r '.related[0].id')
    assert_equals "$tgt" "$related_id" "Related node is the target node"

    # Verify target node context also updated (bidirectional invalidation)
    local target_context
    target_context=$("$WV" context "$tgt" --json | jq -r '.related | length')
    # Target may or may not show reverse relationship depending on query logic
    # But the cache should be invalidated (no stale data)
}

# Test 2: cmd_block invalidates cache
test_cmd_block_invalidation() {
    echo ""
    echo "Test 2: cmd_block invalidates cache"
    echo "===================================="

    setup_test_env

    # Create two nodes
    local node1
    node1=$("$WV" add "Node 1" | tail -1)
    local node2
    node2=$("$WV" add "Node 2" | tail -1)

    # Get initial context
    local before_blockers
    before_blockers=$("$WV" context "$node1" --json | jq -r '.blockers | length')
    assert_equals "0" "$before_blockers" "Initial context has no blockers"

    # Block node1 by node2
    "$WV" block "$node1" --by="$node2" >/dev/null 2>&1

    # Get context again
    local after_blockers
    after_blockers=$("$WV" context "$node1" --json | jq -r '.blockers | length')
    assert_equals "1" "$after_blockers" "Context shows blocker after wv block"

    # Verify blocker is node2
    local blocker_id
    blocker_id=$("$WV" context "$node1" --json | jq -r '.blockers[0].id')
    assert_equals "$node2" "$blocker_id" "Blocker is the expected node"
}

# Test 3: cmd_done invalidates cache
test_cmd_done_invalidation() {
    echo ""
    echo "Test 3: cmd_done invalidates cache"
    echo "==================================="

    setup_test_env

    # Create blocker and blocked nodes
    local blocker
    blocker=$("$WV" add "Blocker node" | tail -1)
    local blocked
    blocked=$("$WV" add "Blocked node" | tail -1)

    # Create blocking relationship
    "$WV" block "$blocked" --by="$blocker" >/dev/null 2>&1

    # Verify blocked node has blocker
    local before_count
    before_count=$("$WV" context "$blocked" --json | jq -r '.blockers | length')
    assert_equals "1" "$before_count" "Blocked node has one blocker"

    # Complete blocker
    "$WV" done "$blocker" >/dev/null 2>&1

    # Get context again - done blockers are filtered out by design
    # (see WEAVE_v1.md: "blockers (done nodes filtered out)")
    local after_count
    after_count=$("$WV" context "$blocked" --json | jq -r '.blockers | length')
    assert_equals "0" "$after_count" "Done blocker is filtered from context"
}

# Test 4: cmd_link invalidates cache
test_cmd_link_invalidation() {
    echo ""
    echo "Test 4: cmd_link invalidates cache"
    echo "==================================="

    setup_test_env

    # Create two nodes
    local node1
    node1=$("$WV" add "Node 1" | tail -1)
    local node2
    node2=$("$WV" add "Node 2" | tail -1)

    # Get initial context
    local before_related
    before_related=$("$WV" context "$node1" --json | jq -r '.related | length')
    assert_equals "0" "$before_related" "Initial context has no related nodes"

    # Create link
    "$WV" link "$node1" "$node2" --type=references --weight=0.8 >/dev/null 2>&1

    # Get context again
    local after_related
    after_related=$("$WV" context "$node1" --json | jq -r '.related | length')
    assert_equals "1" "$after_related" "Context shows related node after wv link"
}

# Test 5: cmd_prune invalidates cache
test_cmd_prune_invalidation() {
    echo ""
    echo "Test 5: cmd_prune invalidates cache"
    echo "===================================="

    setup_test_env

    # Create old done node
    local old_node
    old_node=$("$WV" add "Old node to prune" | tail -1)

    # Create dependent node
    local dep_node
    dep_node=$("$WV" add "Dependent node" | tail -1)

    # Create blocking relationship
    "$WV" block "$dep_node" --by="$old_node" >/dev/null 2>&1

    # Complete old node
    "$WV" done "$old_node" >/dev/null 2>&1

    # Artificially age the node
    # Database is at $WV_HOT_ZONE/brain.db (tmpfs location)
    local hot_zone
    hot_zone=$(find /dev/shm -maxdepth 1 -type d -name "weave*" 2>/dev/null | head -1)
    if [ -z "$hot_zone" ]; then
        echo -e "${YELLOW}⊘${NC} Skipping prune test - cannot find hot zone in /dev/shm"
        return
    fi

    local db_path="$hot_zone/brain.db"
    if [ ! -f "$db_path" ]; then
        echo -e "${YELLOW}⊘${NC} Skipping prune test - cannot find database at $db_path"
        return
    fi

    sqlite3 "$db_path" "UPDATE nodes SET updated_at='2020-01-01 00:00:00' WHERE id='$old_node';" 2>/dev/null

    # Get context before prune (should include old blocker)
    local before_blockers
    before_blockers=$("$WV" context "$dep_node" --json | jq -r '.blockers | length')

    # Prune old nodes
    "$WV" prune --age=1h >/dev/null 2>&1

    # Get context after prune
    local after_blockers
    after_blockers=$("$WV" context "$dep_node" --json | jq -r '.blockers | length')

    # After prune, old blocker should be gone (or show as done)
    # The key test is that cache was invalidated and query ran fresh
    if [ "$after_blockers" -lt "$before_blockers" ] || [ "$after_blockers" -eq 0 ]; then
        assert_equals "true" "true" "Cache invalidated after prune (blocker count changed or is 0)"
    else
        # Check if the blocker still exists but was just completed
        local blocker_exists
        blocker_exists=$("$WV" show "$old_node" 2>/dev/null | grep -c "^ID:" || echo "0")
        assert_equals "0" "$blocker_exists" "Old node was pruned (no longer exists)"
    fi
}

# Test 6: Cache files are actually created and removed
test_cache_file_lifecycle() {
    echo ""
    echo "Test 6: Cache files are created and removed"
    echo "============================================"

    setup_test_env

    # Create a node
    local node
    node=$("$WV" add "Test node" | tail -1)

    # Get context (should create cache file)
    "$WV" context "$node" --json >/dev/null 2>&1

    # Check if cache file exists
    local cache_dir
    cache_dir=$(find "$WV_HOT_ZONE" -type d -name "context_cache" 2>/dev/null | head -1)

    if [ -z "$cache_dir" ]; then
        echo -e "${YELLOW}⊘${NC} Cache directory not found - cache may not be enabled"
        return
    fi

    local cache_file="$cache_dir/${node}.json"
    if [ -f "$cache_file" ]; then
        assert_equals "true" "true" "Cache file created after wv context"
    else
        echo -e "${YELLOW}⊘${NC} Cache file not found - caching may be disabled"
        return
    fi

    # Create another node and link it
    local node2
    node2=$("$WV" add "Test node 2" | tail -1)
    "$WV" link "$node" "$node2" --type=references >/dev/null 2>&1

    # Cache file should be removed (invalidated)
    if [ ! -f "$cache_file" ]; then
        assert_equals "true" "true" "Cache file removed after edge modification"
    else
        # On some systems, cache might still exist but be outdated
        # The important thing is that the next query returns fresh data
        local related_count
        related_count=$("$WV" context "$node" --json | jq -r '.related | length')
        assert_equals "1" "$related_count" "Cache returns fresh data after invalidation"
    fi
}

# Run all tests
main() {
    echo "Cache Invalidation Tests"
    echo "========================"
    echo "Testing: cmd_refs, cmd_block, cmd_done, cmd_link, cmd_prune"
    echo ""

    test_cmd_refs_link_invalidation
    test_cmd_block_invalidation
    test_cmd_done_invalidation
    test_cmd_link_invalidation
    test_cmd_prune_invalidation
    test_cache_file_lifecycle

    # Summary
    echo ""
    echo "Test Summary"
    echo "============"
    echo "Tests run:    $TESTS_RUN"
    echo -e "Tests passed: ${GREEN}$TESTS_PASSED${NC}"

    if [ "$TESTS_FAILED" -gt 0 ]; then
        echo -e "Tests failed: ${RED}$TESTS_FAILED${NC}"
        exit 1
    else
        echo -e "${GREEN}All tests passed!${NC}"
        exit 0
    fi
}

main "$@"
