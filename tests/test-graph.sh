#!/usr/bin/env bash
# test-graph.sh — Test Weave graph commands
#
# Tests: block, link, resolve, related, edges, path
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
TEST_DIR="/tmp/wv-graph-test-$$"
export WV_HOT_ZONE="$TEST_DIR"
export WV_DB="$TEST_DIR/brain.db"

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

    if echo "$haystack" | grep -qF "$needle"; then
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

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"

    TESTS_RUN=$((TESTS_RUN + 1))

    if ! echo "$haystack" | grep -qF "$needle"; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Expected NOT to find: $needle"
        echo "  In: $haystack"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

assert_success() {
    local message="$1"
    shift

    TESTS_RUN=$((TESTS_RUN + 1))

    if "$@" >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Command failed: $*"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

assert_fails() {
    local message="$1"
    shift

    TESTS_RUN=$((TESTS_RUN + 1))

    if ! "$@" >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Expected command to fail: $*"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

# ============================================================================
# Test: block
# ============================================================================
test_block() {
    echo ""
    echo "Test: wv block"
    echo "=============="

    setup_test_env

    # Create two nodes
    local blocker target
    blocker=$("$WV" add "Blocker task" 2>&1 | tail -1)
    target=$("$WV" add "Target task" 2>&1 | tail -1)

    # Block target by blocker
    local output
    output=$("$WV" block "$target" --by="$blocker" 2>&1)
    assert_contains "$output" "blocked by" "block outputs confirmation"

    # Verify target status changed to blocked
    local status
    status=$("$WV" show "$target" --json 2>&1)
    assert_contains "$status" '"status":"blocked"' "block sets status to blocked"

    # Verify blocker appears in ready list (not blocked)
    output=$("$WV" ready 2>&1)
    assert_contains "$output" "$blocker" "blocker is in ready list"
    assert_not_contains "$output" "$target" "blocked node not in ready list"

    # Block requires both arguments
    assert_fails "block requires target ID" "$WV" block
    assert_fails "block requires --by argument" "$WV" block "$target"

    # Block prevents self-blocking
    assert_fails "block prevents self-blocking" "$WV" block "$blocker" --by="$blocker"

    # Block prevents circular blocking
    assert_fails "block prevents circular blocking" "$WV" block "$blocker" --by="$target"
}

# ============================================================================
# Test: link
# ============================================================================
test_link() {
    echo ""
    echo "Test: wv link"
    echo "============="

    setup_test_env

    # Create nodes
    local from to
    from=$("$WV" add "Source node" 2>&1 | tail -1)
    to=$("$WV" add "Target node" 2>&1 | tail -1)

    # Create a link
    local output
    output=$("$WV" link "$from" "$to" --type=implements 2>&1)
    assert_contains "$output" "Linked" "link outputs confirmation"
    assert_contains "$output" "implements" "link shows edge type"

    # Verify link exists via edges command
    output=$("$WV" edges "$from" 2>&1)
    assert_contains "$output" "$to" "link appears in edges"
    assert_contains "$output" "implements" "edge type appears in edges"

    # Link with weight
    output=$("$WV" link "$from" "$to" --type=relates_to --weight=0.5 2>&1)
    assert_contains "$output" "weight: 0.5" "link shows custom weight"

    # Link requires both nodes
    assert_fails "link requires from ID" "$WV" link
    assert_fails "link requires to ID" "$WV" link "$from"

    # Link requires --type
    assert_fails "link requires --type argument" "$WV" link "$from" "$to"

    # Link validates edge type
    assert_fails "link rejects invalid edge type" "$WV" link "$from" "$to" --type=invalid

    # Link validates nodes exist
    assert_fails "link fails for non-existent source" "$WV" link "wv-0000" "$to" --type=relates_to
    assert_fails "link fails for non-existent target" "$WV" link "$from" "wv-0000" --type=relates_to

    # Link validates weight range
    assert_fails "link rejects weight > 1" "$WV" link "$from" "$to" --type=relates_to --weight=1.5
    assert_fails "link rejects negative weight" "$WV" link "$from" "$to" --type=relates_to --weight=-0.5
}

# ============================================================================
# Test: resolve
# ============================================================================
test_resolve() {
    echo ""
    echo "Test: wv resolve"
    echo "================"

    setup_test_env

    # Create contradicting nodes
    local node1 node2
    node1=$("$WV" add "Approach A" 2>&1 | tail -1)
    node2=$("$WV" add "Approach B" 2>&1 | tail -1)

    # Create contradiction edge
    "$WV" link "$node1" "$node2" --type=contradicts >/dev/null 2>&1

    # Resolve with winner
    local output
    output=$("$WV" resolve "$node1" "$node2" --winner="$node1" --rationale="A is better" 2>&1)
    assert_contains "$output" "supersedes" "resolve --winner creates supersedes"
    assert_contains "$output" "$node1" "resolve shows winner"

    # Verify loser is marked done
    local loser_status
    loser_status=$("$WV" show "$node2" --json 2>&1)
    assert_contains "$loser_status" '"status":"done"' "resolve marks loser as done"

    # Test merge resolution
    setup_test_env
    node1=$("$WV" add "Idea X" 2>&1 | tail -1)
    node2=$("$WV" add "Idea Y" 2>&1 | tail -1)
    "$WV" link "$node1" "$node2" --type=contradicts >/dev/null 2>&1

    output=$("$WV" resolve "$node1" "$node2" --merge 2>&1)
    assert_contains "$output" "merged" "resolve --merge creates merged node"

    # Both original nodes should be done
    local n1_status n2_status
    n1_status=$("$WV" show "$node1" --json 2>&1)
    n2_status=$("$WV" show "$node2" --json 2>&1)
    assert_contains "$n1_status" '"status":"done"' "merge marks node1 done"
    assert_contains "$n2_status" '"status":"done"' "merge marks node2 done"

    # Test defer resolution
    setup_test_env
    node1=$("$WV" add "Option 1" 2>&1 | tail -1)
    node2=$("$WV" add "Option 2" 2>&1 | tail -1)
    "$WV" link "$node1" "$node2" --type=contradicts >/dev/null 2>&1

    output=$("$WV" resolve "$node1" "$node2" --defer 2>&1)
    assert_contains "$output" "deferred" "resolve --defer works"
    assert_contains "$output" "related" "defer converts to relates_to"

    # Resolve requires mode
    setup_test_env
    node1=$("$WV" add "A" 2>&1 | tail -1)
    node2=$("$WV" add "B" 2>&1 | tail -1)
    assert_fails "resolve requires resolution mode" "$WV" resolve "$node1" "$node2"

    # Winner must be one of the nodes
    assert_fails "resolve requires valid winner" "$WV" resolve "$node1" "$node2" --winner="wv-0000"
}

# ============================================================================
# Test: related
# ============================================================================
test_related() {
    echo ""
    echo "Test: wv related"
    echo "================"

    setup_test_env

    # Create nodes with relationships
    local epic feature1 feature2
    epic=$("$WV" add "Epic" 2>&1 | tail -1)
    feature1=$("$WV" add "Feature 1" 2>&1 | tail -1)
    feature2=$("$WV" add "Feature 2" 2>&1 | tail -1)

    # Create edges
    "$WV" link "$feature1" "$epic" --type=implements >/dev/null 2>&1
    "$WV" link "$feature2" "$epic" --type=implements >/dev/null 2>&1
    "$WV" link "$feature1" "$feature2" --type=relates_to >/dev/null 2>&1

    # Related shows all relationships
    local output
    output=$("$WV" related "$epic" 2>&1)
    assert_contains "$output" "$feature1" "related shows feature1"
    assert_contains "$output" "$feature2" "related shows feature2"

    # Related with --type filter
    output=$("$WV" related "$epic" --type=implements 2>&1)
    assert_contains "$output" "implements" "related --type filters by type"

    # Related with --direction filter
    output=$("$WV" related "$feature1" --direction=outbound 2>&1)
    assert_contains "$output" "$epic" "related --direction=outbound shows targets"

    output=$("$WV" related "$epic" --direction=inbound 2>&1)
    assert_contains "$output" "$feature1" "related --direction=inbound shows sources"

    # Related --json
    output=$("$WV" related "$epic" --json 2>&1)
    assert_contains "$output" "[" "related --json outputs JSON array"

    # Related requires node ID
    assert_fails "related requires node ID" "$WV" related

    # Related fails for non-existent node
    assert_fails "related fails for non-existent node" "$WV" related "wv-0000"
}

# ============================================================================
# Test: edges
# ============================================================================
test_edges() {
    echo ""
    echo "Test: wv edges"
    echo "=============="

    setup_test_env

    # Create nodes with edges
    local node1 node2 node3
    node1=$("$WV" add "Node 1" 2>&1 | tail -1)
    node2=$("$WV" add "Node 2" 2>&1 | tail -1)
    node3=$("$WV" add "Node 3" 2>&1 | tail -1)

    # Create various edges
    "$WV" link "$node1" "$node2" --type=implements >/dev/null 2>&1
    "$WV" link "$node1" "$node3" --type=relates_to >/dev/null 2>&1
    "$WV" block "$node2" --by="$node3" >/dev/null 2>&1

    # Edges shows all edges for a node
    local output
    output=$("$WV" edges "$node1" 2>&1)
    assert_contains "$output" "$node2" "edges shows target node"
    assert_contains "$output" "implements" "edges shows edge type"
    assert_contains "$output" "relates_to" "edges shows multiple types"

    # Edges with --type filter
    output=$("$WV" edges "$node1" --type=implements 2>&1)
    assert_contains "$output" "implements" "edges --type filters results"
    assert_not_contains "$output" "relates_to" "edges --type excludes other types"

    # Edges --json
    output=$("$WV" edges "$node1" --json 2>&1)
    assert_contains "$output" "[" "edges --json outputs JSON"

    # Edges requires node ID
    assert_fails "edges requires node ID" "$WV" edges

    # Edges fails for non-existent node
    assert_fails "edges fails for non-existent node" "$WV" edges "wv-0000"

    # Edges validates edge type
    assert_fails "edges rejects invalid edge type" "$WV" edges "$node1" --type=invalid
}

# ============================================================================
# Test: path
# ============================================================================
test_path() {
    echo ""
    echo "Test: wv path"
    echo "============="

    setup_test_env

    # Create a dependency chain: task <- feature <- epic
    local epic feature task
    epic=$("$WV" add "Epic" 2>&1 | tail -1)
    feature=$("$WV" add "Feature" 2>&1 | tail -1)
    task=$("$WV" add "Task" 2>&1 | tail -1)

    # Create blocking edges (emulates dependency chain)
    "$WV" block "$feature" --by="$epic" >/dev/null 2>&1
    "$WV" block "$task" --by="$feature" >/dev/null 2>&1

    # Path shows ancestry chain
    local output
    output=$("$WV" path "$task" 2>&1)
    assert_contains "$output" "Epic" "path includes root"
    assert_contains "$output" "Feature" "path includes intermediate"
    assert_contains "$output" "Task" "path includes leaf"

    # Path --format=chain shows as arrows
    output=$("$WV" path "$task" --format=chain 2>&1)
    assert_contains "$output" "→" "path --format=chain uses arrows"

    # Path requires node ID
    assert_fails "path requires node ID" "$WV" path

    # Path fails for non-existent node
    assert_fails "path fails for non-existent node" "$WV" path "wv-0000"
}

# ============================================================================
# Main
# ============================================================================
main() {
    echo "========================================"
    echo "Weave Graph Command Tests"
    echo "========================================"

    test_block
    test_link
    test_resolve
    test_related
    test_edges
    test_path

    echo ""
    echo "========================================"
    echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
    echo "========================================"

    if [ "$TESTS_FAILED" -gt 0 ]; then
        echo -e "${RED}$TESTS_FAILED test(s) failed${NC}"
        exit 1
    else
        echo -e "${GREEN}All tests passed${NC}"
        exit 0
    fi
}

main "$@"
