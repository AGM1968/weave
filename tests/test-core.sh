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
export WV_REQUIRE_LEARNING=0

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

    if echo "$haystack" | grep -qF -- "$needle"; then
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

    if ! echo "$haystack" | grep -qF -- "$needle"; then
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

    # --risks=<level> must always seed both risk_level AND risks:[] so the
    # pre-claim hook's has("risks") check passes on immediate claim.
    local risk_id risk_meta
    for level in none low medium high critical; do
        risk_id=$("$WV" add "risks=$level" --risks="$level" 2>&1 | tail -1)
        risk_meta=$("$WV" show "$risk_id" --json | jq -r '.[0].metadata')
        assert_contains "$risk_meta" "\"risk_level\":\"$level\"" "--risks=$level sets risk_level"
        assert_contains "$risk_meta" '"risks":[]' "--risks=$level seeds empty risks list"
    done
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

    # Learning gate: wv done requires --learning or --skip-verification
    id=$("$WV" add "Task needing learning" 2>&1 | tail -1)
    assert_fails "done rejects bare close when learning required" \
        env WV_REQUIRE_LEARNING=1 "$WV" done "$id"

    # Same node succeeds with --skip-verification
    local sv_exit=0
    WV_REQUIRE_LEARNING=1 "$WV" done "$id" --skip-verification >/dev/null 2>&1 || sv_exit=$?
    assert_equals "0" "$sv_exit" "done accepts --skip-verification"

    # Finding nodes require structured finding metadata before close
    local finding_id finding_output
    finding_id=$("$WV" add "Finding needing schema" --metadata='{"type":"finding"}' 2>&1 | tail -1)
    assert_fails "done rejects incomplete finding metadata" \
        env WV_REQUIRE_LEARNING=1 "$WV" done "$finding_id" --skip-verification

    "$WV" update "$finding_id" --metadata='{"type":"finding","finding":{"violation_type":"R10:open_node_at_end","root_cause":"bootstrap omitted active-node type","proposed_fix":"record active_node_type in session_start metadata","confidence":0.92,"fixable":"yes"}}' >/dev/null 2>&1
    assert_fails "done rejects invalid finding metadata types" \
        env WV_REQUIRE_LEARNING=1 "$WV" done "$finding_id" --skip-verification

    "$WV" update "$finding_id" --metadata='{"type":"finding","finding":{"violation_type":"R10:open_node_at_end","root_cause":"bootstrap omitted active-node type","proposed_fix":"record active_node_type in session_start metadata","confidence":"high","fixable":true}}' >/dev/null 2>&1
    finding_output=$(WV_REQUIRE_LEARNING=1 "$WV" done "$finding_id" --skip-verification 2>&1)
    assert_contains "$finding_output" "Closed" "done accepts complete finding metadata"

    # Non-interactive overlap: close proceeds and skips overlap advisory writes entirely
    local seed_id overlap_id overlap_learning overlap_exit overlap_output overlap_meta
    overlap_learning="decision: keep overlap prompts resumable | pattern: store pending close state | pitfall: tty prompts hang unattended flows"
    seed_id=$("$WV" add "Seed overlap learning" 2>&1 | tail -1)
    WV_REQUIRE_LEARNING=1 "$WV" done "$seed_id" --learning="$overlap_learning" >/dev/null 2>&1

    overlap_id=$("$WV" add "Overlap advisory" 2>&1 | tail -1)
    overlap_exit=0
    overlap_output=$(WV_REQUIRE_LEARNING=1 WV_NONINTERACTIVE=1 "$WV" done "$overlap_id" --learning="$overlap_learning" 2>&1) || overlap_exit=$?
    assert_equals "0" "$overlap_exit" "done succeeds non-interactively when overlap detected"
    assert_not_contains "$overlap_output" "Overlap noted in metadata" "done skips overlap advisory output in non-interactive mode"

    overlap_meta=$("$WV" show "$overlap_id" --json 2>&1)
    assert_not_contains "$overlap_meta" "learning_overlap_noted" "done skips learning_overlap_noted metadata in non-interactive mode"
    assert_contains "$overlap_meta" '"status":"done"' "node is closed despite overlap"

    local finding_overlap_id finding_overlap_exit finding_overlap_output finding_overlap_meta
    finding_overlap_id=$("$WV" add "Finding overlap advisory" --metadata='{"type":"finding","verification":{"method":"test","result":"pass"},"finding":{"violation_type":"schema_enforcement_test","root_cause":"runtime wv_done wrapper validates finding metadata types and presence before allowing close","proposed_fix":"agents must set confidence as one of high|medium|low (string) and fixable as boolean before closing a finding node","confidence":"high","fixable":true}}' 2>&1 | tail -1)
    finding_overlap_exit=0
    finding_overlap_output=$(WV_REQUIRE_LEARNING=1 WV_NONINTERACTIVE=1 "$WV" done "$finding_overlap_id" --learning="$overlap_learning" 2>&1) || finding_overlap_exit=$?
    assert_equals "0" "$finding_overlap_exit" "done succeeds for finding nodes when overlap is advisory"
    assert_contains "$finding_overlap_output" "Closed" "finding overlap advisory still closes the node"
    finding_overlap_meta=$("$WV" show "$finding_overlap_id" --json 2>&1)
    assert_contains "$finding_overlap_meta" '"status":"done"' "finding node is closed despite overlap"
    assert_not_contains "$finding_overlap_meta" "learning_overlap_noted" "finding close also skips overlap advisory metadata in non-interactive mode"

    local ship_id ship_exit ship_output ship_meta ship_remote
    ship_remote="$TEST_DIR/ship-remote.git"
    git config user.email "test@example.com"
    git config user.name "Weave Test"
    git init --bare -q "$ship_remote"
    git remote add origin "$ship_remote"
    git add . >/dev/null 2>&1 || true
    git commit -m "test baseline" --allow-empty >/dev/null 2>&1 || true
    git push -u origin HEAD >/dev/null 2>&1

    ship_id=$("$WV" add "Ship overlap parity" 2>&1 | tail -1)
    ship_exit=0
    ship_output=$(WV_REQUIRE_LEARNING=1 WV_NONINTERACTIVE=1 "$WV" ship "$ship_id" --learning="$overlap_learning" --no-overlap-check 2>&1) || ship_exit=$?
    assert_equals "0" "$ship_exit" "ship accepts --no-overlap-check"
    ship_meta=$("$WV" show "$ship_id" --json 2>&1)
    assert_contains "$ship_meta" '"status":"done"' "ship still closes the node with --no-overlap-check"
    assert_not_contains "$ship_meta" "learning_overlap_noted" "ship forwards no-overlap-check to done"

    # --acknowledge-overlap still clears legacy pending_close state (backward compat)
    local legacy_id legacy_meta legacy_exit legacy_output
    legacy_id=$("$WV" add "Legacy stuck node" 2>&1 | tail -1)
    legacy_meta=$(jq -n --arg node "$legacy_id" \
        '{"needs_human_verification": true, "pending_close": {"reason": "learning_overlap", "overlap_with": "wv-fake", "learning": "test", "created_at": "2026-01-01T00:00:00Z", "resume_command": ("wv done " + $node + " --acknowledge-overlap")}}')
    "$WV" update "$legacy_id" --metadata="$legacy_meta" >/dev/null 2>&1
    legacy_exit=0
    legacy_output=$(WV_REQUIRE_LEARNING=1 WV_NONINTERACTIVE=1 "$WV" done "$legacy_id" --acknowledge-overlap 2>&1) || legacy_exit=$?
    assert_equals "0" "$legacy_exit" "done clears legacy pending_close with --acknowledge-overlap"
    assert_contains "$legacy_output" "Closed" "acknowledge-overlap closes legacy stuck node"
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

    # Context surfaces linked finding metadata via resolves edge
    local finding_id
    finding_id=$("$WV" add "Investigate open-node false positive" --metadata='{"type":"finding","finding":{"violation_type":"R10:open_node_at_end","root_cause":"bootstrap omitted active-node type","proposed_fix":"record active_node_type in session_start metadata","confidence":"high","fixable":true}}' 2>&1 | tail -1)
    "$WV" link "$id" "$finding_id" --type=resolves >/dev/null 2>&1
    output=$("$WV" context "$id" --json 2>&1)
    assert_contains "$output" "\"finding\"" "context includes finding block when resolves edge exists"
    assert_contains "$output" "\"violation_type\": \"R10:open_node_at_end\"" "context finding includes violation type"

    # Context falls back to primary node from wv work
    output=$("$WV" context --json 2>&1)
    assert_contains "$output" "\"id\": \"$id\"" "context falls back to primary node"

    # Context without primary or WV_ACTIVE shows usage
    rm -f "$WV_HOT_ZONE/primary" 2>/dev/null || true
    output=$("$WV" context --json 2>&1 || true)
    assert_contains "$output" "wv work" "context without ID suggests wv work"

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

    # current_intent round-trip: set via wv update, visible in wv show, survives wv load
    local intent_id
    intent_id=$("$WV" add "Intent test node" 2>&1 | tail -1)
    "$WV" update "$intent_id" --metadata='{"current_intent":"testing intent persistence"}' >/dev/null 2>&1
    output=$("$WV" show "$intent_id" 2>&1)
    assert_contains "$output" "Intent:" "current_intent appears as Intent: in wv show"
    assert_contains "$output" "testing intent persistence" "current_intent value shown in wv show"
    # Simulate wv load round-trip (dump + reload from state.sql)
    "$WV" sync >/dev/null 2>&1 || true
    output=$("$WV" show "$intent_id" 2>&1)
    assert_contains "$output" "testing intent persistence" "current_intent survives sync/load round-trip"
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
# Test: update --metadata merge (SQL json_patch port; H1.T2)
# ============================================================================
# Regression for the silent-fallback bug where jq merge failure caused the new
# metadata to overwrite the stored value, wiping existing keys. Exercises the
# conditions listed in PROPOSAL-wv-post-split-hardening Target 3.
test_update_metadata_merge() {
    echo ""
    echo "Test: wv update --metadata merge"
    echo "================================"

    setup_test_env
    "$WV" init >/dev/null 2>&1

    local id1 id2 id3 meta
    # Case A — node with no initial metadata: first update stores the new blob.
    id1=$("$WV" add "no initial meta" 2>&1 | tail -1)
    "$WV" update "$id1" --metadata='{"k":"v"}' >/dev/null 2>&1
    meta=$("$WV" show "$id1" --json | jq -r '.[0].metadata')
    assert_contains "$meta" '"k":"v"' "merge: empty → new key stored"

    # Case B — existing key preserved, new key added.
    id2=$("$WV" add "existing meta" --criteria="c1" 2>&1 | tail -1)
    "$WV" update "$id2" --metadata='{"extra":"z"}' >/dev/null 2>&1
    meta=$("$WV" show "$id2" --json | jq -r '.[0].metadata')
    assert_contains "$meta" 'done_criteria' "merge: existing key preserved"
    assert_contains "$meta" '"extra":"z"' "merge: new key added"

    # Case C — payload with unicode, apostrophe, and literal '||' does not trip
    # a silent fallback (the old code's jq || echo fallback would have nuked
    # done_criteria on any jq failure).
    id3=$("$WV" add "stress payload" --criteria="c1" 2>&1 | tail -1)
    "$WV" update "$id3" --metadata='{"note":"O'\''Donovan → test || foo"}' >/dev/null 2>&1
    meta=$("$WV" show "$id3" --json | jq -r '.[0].metadata')
    assert_contains "$meta" 'done_criteria' "merge: stress payload preserves existing key"
    assert_contains "$meta" "O'Donovan" "merge: apostrophe round-trips"
    assert_contains "$meta" '||' "merge: literal || survives"

    # Case D — invalid JSON is rejected loudly; stored metadata is unchanged.
    local id4 before after
    id4=$("$WV" add "invalid json rejected" --criteria="c1" 2>&1 | tail -1)
    before=$("$WV" show "$id4" --json | jq -r '.[0].metadata')
    if "$WV" update "$id4" --metadata='{"bad": syntax}' >/dev/null 2>&1; then
        echo -e "${RED}✗${NC} invalid JSON should have been rejected"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        TESTS_RUN=$((TESTS_RUN + 1))
    else
        echo -e "${GREEN}✓${NC} invalid JSON rejected with non-zero exit"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        TESTS_RUN=$((TESTS_RUN + 1))
    fi
    after=$("$WV" show "$id4" --json | jq -r '.[0].metadata')
    assert_equals "$before" "$after" "rejected update leaves metadata untouched"

    # Case E — immediate update-then-claim sequence (the primary Target 1
    # friction). After setting done_criteria via --metadata, wv work must pass
    # the pre-claim readiness check on the very next invocation.
    local id5
    id5=$("$WV" add "claim readiness" 2>&1 | tail -1)
    "$WV" update "$id5" --metadata='{"done_criteria":"c","risks":[],"risk_level":"low"}' >/dev/null 2>&1
    meta=$("$WV" show "$id5" --json | jq -r '.[0].metadata')
    assert_contains "$meta" '"done_criteria":"c"' "update-then-claim: done_criteria visible immediately"
}

# ============================================================================
# Test: orphan prevention
# ============================================================================
test_orphan_prevention() {
    echo ""
    echo "Test: orphan prevention"
    echo "======================="

    setup_test_env
    "$WV" init >/dev/null 2>&1

    # Create an epic (type=epic in metadata) as root
    local epic_id
    epic_id=$("$WV" add "Root epic" --metadata='{"type":"epic"}' 2>&1 | tail -1)
    assert_contains "$epic_id" "wv-" "epic created successfully"

    # With an active epic, adding a task without --parent must fail
    local output
    output=$("$WV" add "Orphan task attempt" 2>&1 || true)
    assert_contains "$output" "--parent" "orphan guard fires when active epic exists"
    assert_contains "$output" "Error" "orphan guard prints error message"

    # Verify the node was rolled back (guard deletes node on error)
    # Note: the add output WILL contain wv-XXXX from the creation step before rollback.
    # The correct check is that the node doesn't appear in the list after the failed add.
    local list_output
    list_output=$("$WV" list 2>&1)
    assert_not_contains "$list_output" "Orphan task attempt" "orphan guard rolls back the node"

    # With --parent specified, add succeeds
    local child_id
    child_id=$("$WV" add "Linked child task" --parent="$epic_id" 2>&1 | tail -1)
    assert_contains "$child_id" "wv-" "add with --parent succeeds"

    # With --force, add succeeds even without --parent
    local forced_id
    forced_id=$("$WV" add "Force-created task" --force 2>&1 | tail -1)
    assert_contains "$forced_id" "wv-" "add with --force bypasses orphan guard"

    # No active epics — task allowed without --parent (the gap that let wv-2efef5 exist)
    # Mark the epic done so no active epics remain
    "$WV" done "$epic_id" >/dev/null 2>&1
    local free_id
    free_id=$("$WV" add "No-parent task when no active epics" 2>&1 | tail -1)
    assert_contains "$free_id" "wv-" "add without --parent allowed when no active epics exist"
}

# ============================================================================
# Test: findings promote
# ============================================================================
test_findings_promote() {
    echo ""
    echo "Test: wv findings promote"
    echo "========================="

    setup_test_env
    "$WV" init >/dev/null 2>&1

    local source_id parent_id output all_nodes
    source_id=$("$WV" add "Investigate install hook drift" 2>&1 | tail -1)
    "$WV" done "$source_id" \
        --learning="pitfall: hooks copied by install.sh but not wired into settings.json; add settings wiring in install.sh" \
        >/dev/null 2>&1

    output=$(WV_CLI="$WV" PATH="$PROJECT_ROOT/scripts:$PATH" "$WV" findings promote --json 2>&1)
    assert_contains "$output" '"candidates"' "findings promote defaults to dry-run candidates"
    assert_contains "$output" "$source_id" "findings promote reports source node"
    assert_fails "findings promote --apply requires parent" "$WV" findings promote --apply

    parent_id=$("$WV" add "Review promoted historical findings" 2>&1 | tail -1)
    output=$(WV_CLI="$WV" PATH="$PROJECT_ROOT/scripts:$PATH" \
        "$WV" findings promote --apply --parent="$parent_id" --json 2>&1)
    assert_contains "$output" '"promoted"' "findings promote apply returns promoted nodes"
    assert_contains "$output" "$parent_id" "findings promote apply reports parent"

    all_nodes=$("$WV" list --all --json 2>&1)
    assert_contains "$all_nodes" 'historical_finding_id' "promoted finding stores idempotency metadata"
    assert_contains "$all_nodes" '"type\": \"finding\"' "promoted finding is stored as finding node"
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
    test_orphan_prevention
    test_done
    test_findings_promote
    test_work
    test_list
    test_show
    test_ready
    test_status
    test_update_metadata_merge

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
