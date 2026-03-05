#!/usr/bin/env bash
# test-core.sh — Test core Weave commands
#
# Tests: init, add, done, list, show, ready, status
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
TEST_DIR="/tmp/wv-core-test-$$"
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
    git init -q
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
# Test: init
# ============================================================================
test_init() {
    echo ""
    echo "Test: wv init"
    echo "============="

    setup_test_env

    # Test init creates database
    local output
    output=$("$WV" init 2>&1)
    assert_contains "$output" "Initialized Weave" "init outputs success message"
    assert_success "init creates database file" test -f "$WV_DB"

    # Test init is idempotent (empty DB)
    output=$("$WV" init 2>&1)
    assert_contains "$output" "Initialized Weave" "init is idempotent on empty DB"
}

test_init_recovery() {
    echo ""
    echo "Test: wv init recovery"
    echo "======================"

    # Set up isolated test env with git repo (needed for WEAVE_DIR resolution)
    local INIT_TEST_DIR
    INIT_TEST_DIR=$(mktemp -d)
    local OLD_HOT="$WV_HOT_ZONE"
    local OLD_DB="$WV_DB"
    export WV_HOT_ZONE="$INIT_TEST_DIR/hot"
    export WV_DB="$WV_HOT_ZONE/brain.db"

    cd "$INIT_TEST_DIR"
    git init -q

    # Create initial state: init, add nodes, sync
    "$WV" init >/dev/null 2>&1
    "$WV" add "Recovery test node" >/dev/null 2>&1
    "$WV" add "Another node" >/dev/null 2>&1
    "$WV" sync >/dev/null 2>&1
    assert_success "state.sql created by sync" test -f "$INIT_TEST_DIR/.weave/state.sql"

    # Simulate reboot: wipe hot zone (DB gone, state.sql remains)
    rm -rf "$WV_HOT_ZONE"

    # wv init should auto-recover
    local output
    output=$("$WV" init 2>&1)
    assert_contains "$output" "Recovered" "init detects reboot and recovers"
    assert_contains "$output" "2 nodes" "init reports recovered node count"
    assert_success "DB restored after recovery" test -f "$WV_DB"

    # Verify data survived
    output=$("$WV" list --all 2>&1)
    assert_contains "$output" "Recovery test node" "recovered data is accessible"

    # Test guard: init with existing data should fail
    output=$("$WV" init 2>&1 || true)
    assert_contains "$output" "already exists" "init refuses to overwrite existing data"

    # Test --force bypasses guard
    output=$("$WV" init --force 2>&1)
    assert_contains "$output" "Initialized Weave" "init --force reinitializes"

    # Restore original env
    export WV_HOT_ZONE="$OLD_HOT"
    export WV_DB="$OLD_DB"
    cd /tmp
    rm -rf "$INIT_TEST_DIR"
}

# ============================================================================
# Test: add
# ============================================================================
test_add() {
    echo ""
    echo "Test: wv add"
    echo "============"

    setup_test_env
    "$WV" init >/dev/null 2>&1

    # Basic add
    local output id
    output=$("$WV" add "Test task one" 2>&1)
    assert_contains "$output" "wv-" "add outputs node ID"

    # Extract ID from output (last line)
    id=$(echo "$output" | tail -1)
    assert_contains "$id" "wv-" "add returns bare ID on last line"

    # Add with status
    output=$("$WV" add "Active task" --status=active 2>&1)
    id=$(echo "$output" | tail -1)
    local show_output
    show_output=$("$WV" show "$id" 2>&1)
    assert_contains "$show_output" "active" "add --status sets correct status"

    # Add with metadata
    output=$("$WV" add "Task with metadata" --metadata='{"priority":1,"type":"bug"}' 2>&1)
    id=$(echo "$output" | tail -1)
    show_output=$("$WV" show "$id" --json 2>&1)
    # Metadata is JSON-encoded in the output, so quotes are escaped
    assert_contains "$show_output" 'priority' "add --metadata stores JSON"
    assert_contains "$show_output" 'bug' "add --metadata stores all fields"

    # Add fails without text
    assert_fails "add requires text" "$WV" add

    # Add fails with invalid metadata JSON
    assert_fails "add rejects invalid JSON metadata" "$WV" add "Bad metadata" --metadata='not-json'
}

# ============================================================================
# Test: done
# ============================================================================
test_done() {
    echo ""
    echo "Test: wv done"
    echo "============="

    setup_test_env
    "$WV" init >/dev/null 2>&1

    # Create a node
    local id
    id=$("$WV" add "Task to complete" 2>&1 | tail -1)

    # Mark done
    local output
    output=$("$WV" done "$id" 2>&1)
    assert_contains "$output" "Closed" "done outputs completion message"

    # Verify status changed
    local show_output
    show_output=$("$WV" show "$id" 2>&1)
    assert_contains "$show_output" "done" "done sets status to done"

    # Done with learning
    id=$("$WV" add "Task with learning" 2>&1 | tail -1)
    output=$("$WV" done "$id" --learning="pattern: always test your code" 2>&1)
    assert_contains "$output" "Closed" "done with learning succeeds"

    # Verify learning was captured in metadata
    local show_meta
    show_meta=$("$WV" show "$id" --json 2>&1)
    assert_contains "$show_meta" "always test your code" "done --learning stores in metadata"

    # Done on non-existent node fails
    assert_fails "done on non-existent node fails" "$WV" done "wv-0000"
}

# ============================================================================
# Test: work
# ============================================================================
test_work() {
    echo ""
    echo "Test: wv work"
    echo "============="

    setup_test_env
    "$WV" init >/dev/null 2>&1

    # Create a node
    local id
    id=$("$WV" add "Task to work on" 2>&1 | tail -1)

    # Claim work
    local output
    output=$("$WV" work "$id" 2>&1)
    assert_contains "$output" "Claimed" "work outputs claim message"
    assert_contains "$output" "WV_ACTIVE=$id" "work shows export command"

    # Verify status changed to active
    local show_output
    show_output=$("$WV" show "$id" 2>&1)
    assert_contains "$show_output" "active" "work sets status to active"

    # Work --quiet outputs only export
    output=$("$WV" work "$id" --quiet 2>&1)
    assert_equals "export WV_ACTIVE=$id" "$output" "work --quiet outputs only export"

    # Context uses WV_ACTIVE when set
    export WV_ACTIVE="$id"
    output=$("$WV" context --json 2>&1)
    assert_contains "$output" "\"id\": \"$id\"" "context uses WV_ACTIVE"
    unset WV_ACTIVE

    # Context without WV_ACTIVE or ID shows usage
    output=$("$WV" context --json 2>&1 || true)
    assert_contains "$output" "WV_ACTIVE" "context without ID suggests WV_ACTIVE"

    # Work on non-existent node fails
    assert_fails "work on non-existent node fails" "$WV" work "wv-0000"
}

# ============================================================================
# Test: list
# ============================================================================
test_list() {
    echo ""
    echo "Test: wv list"
    echo "============="

    setup_test_env
    "$WV" init >/dev/null 2>&1

    # Create nodes with different statuses
    local id1 id2 id3
    id1=$("$WV" add "Todo task" --status=todo 2>&1 | tail -1)
    id2=$("$WV" add "Active task" --status=active 2>&1 | tail -1)
    id3=$("$WV" add "Done task" --status=done 2>&1 | tail -1)

    # Default list excludes done
    local output
    output=$("$WV" list 2>&1)
    assert_contains "$output" "$id1" "list shows todo nodes"
    assert_contains "$output" "$id2" "list shows active nodes"
    assert_not_contains "$output" "$id3" "list excludes done nodes by default"

    # List --all includes done
    output=$("$WV" list --all 2>&1)
    assert_contains "$output" "$id3" "list --all includes done nodes"

    # List --json outputs JSON array
    output=$("$WV" list --json 2>&1)
    assert_contains "$output" "[" "list --json outputs JSON array"
    assert_contains "$output" '"id"' "list --json includes id field"

    # List with status filter
    output=$("$WV" list --status=active 2>&1)
    assert_contains "$output" "$id2" "list --status=active shows active"
    assert_not_contains "$output" "$id1" "list --status=active excludes todo"
}

# ============================================================================
# Test: show
# ============================================================================
test_show() {
    echo ""
    echo "Test: wv show"
    echo "============="

    setup_test_env
    "$WV" init >/dev/null 2>&1

    # Create a node with metadata
    local id
    id=$("$WV" add "Show test node" --metadata='{"priority":2,"type":"feature"}' 2>&1 | tail -1)

    # Basic show
    local output
    output=$("$WV" show "$id" 2>&1)
    assert_contains "$output" "$id" "show displays node ID"
    assert_contains "$output" "Show test node" "show displays node text"
    assert_contains "$output" "todo" "show displays status"

    # Show --json
    output=$("$WV" show "$id" --json 2>&1)
    assert_contains "$output" '"id"' "show --json has id field"
    assert_contains "$output" '"text"' "show --json has text field"
    assert_contains "$output" '"status"' "show --json has status field"
    assert_contains "$output" 'metadata' "show --json has metadata field"

    # Show non-existent node returns error
    assert_fails "show non-existent node fails" "$WV" show "wv-0000"

    # Show without ID fails
    assert_fails "show without ID fails" "$WV" show
}

# ============================================================================
# Test: ready
# ============================================================================
test_ready() {
    echo ""
    echo "Test: wv ready"
    echo "=============="

    setup_test_env
    "$WV" init >/dev/null 2>&1

    # Create unblocked nodes
    local id1 id2 id3
    id1=$("$WV" add "Ready task 1" 2>&1 | tail -1)
    id2=$("$WV" add "Ready task 2" 2>&1 | tail -1)

    # Create a blocked node
    id3=$("$WV" add "Blocked task" 2>&1 | tail -1)
    "$WV" block "$id3" --by="$id1" >/dev/null 2>&1

    # Ready shows unblocked nodes
    local output
    output=$("$WV" ready 2>&1)
    assert_contains "$output" "$id1" "ready shows unblocked node"
    assert_contains "$output" "$id2" "ready shows second unblocked node"
    assert_not_contains "$output" "$id3" "ready excludes blocked node"

    # Ready --json outputs JSON
    output=$("$WV" ready --json 2>&1)
    assert_contains "$output" "[" "ready --json outputs JSON array"

    # Ready --count outputs count only
    output=$("$WV" ready --count 2>&1)
    assert_equals "2" "$output" "ready --count returns correct count"

    # Complete a blocker and verify blocked node becomes ready
    "$WV" done "$id1" >/dev/null 2>&1
    output=$("$WV" ready 2>&1)
    assert_contains "$output" "$id3" "ready shows newly unblocked node"
}

# ============================================================================
# Test: status
# ============================================================================
test_status() {
    echo ""
    echo "Test: wv status"
    echo "==============="

    setup_test_env
    "$WV" init >/dev/null 2>&1

    # Create some nodes
    "$WV" add "Task 1" --status=todo >/dev/null 2>&1
    "$WV" add "Task 2" --status=active >/dev/null 2>&1
    local id3
    id3=$("$WV" add "Task 3" 2>&1 | tail -1)
    "$WV" done "$id3" >/dev/null 2>&1

    # Status shows summary
    local output
    output=$("$WV" status 2>&1)
    assert_contains "$output" "active" "status shows active count"
    assert_contains "$output" "ready" "status shows ready count"
    assert_contains "$output" "blocked" "status shows blocked count"

    # Status shows active work prominently
    assert_contains "$output" "Task 2" "status highlights active work"
}

# ============================================================================
# Main
# ============================================================================
main() {
    echo "========================================"
    echo "Weave Core Command Tests"
    echo "========================================"

    test_init
    test_init_recovery
    test_add
    test_done
    test_work
    test_list
    test_show
    test_ready
    test_status

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
