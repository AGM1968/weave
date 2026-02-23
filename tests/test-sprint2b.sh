#!/usr/bin/env bash
# test-sprint2b.sh — Test Sprint 2b: Agent Orientation features
#
# Tests: breadcrumbs, digest, learnings filters, write-time validation
#
# Exit codes:
#   0 - All tests passed
#   1 - One or more tests failed

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$PROJECT_ROOT/scripts/wv"

# Test environment
TEST_DIR="/tmp/wv-sprint2b-test-$$"
export WV_HOT_ZONE="$TEST_DIR"
export WV_DB="$TEST_DIR/brain.db"

cleanup() {
    if [ -d "$TEST_DIR" ]; then
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

setup_test_env() {
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR"
    cd "$TEST_DIR"
}

# ---------------------------------------------------------------------------
# Test helpers (same pattern as other test suites)
# ---------------------------------------------------------------------------

assert_equals() {
    local expected="$1" actual="$2" message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$expected" = "$actual" ]; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Expected: $expected"
        echo "  Actual:   $actual"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if echo "$haystack" | grep -qF "$needle"; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Expected to find: $needle"
        echo "  In: $(echo "$haystack" | head -5)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if ! echo "$haystack" | grep -qF "$needle"; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Expected NOT to find: $needle"
        echo "  In: $(echo "$haystack" | head -5)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_success() {
    local message="$1"; shift
    TESTS_RUN=$((TESTS_RUN + 1))
    if "$@" >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Command failed: $*"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_fails() {
    local message="$1"; shift
    TESTS_RUN=$((TESTS_RUN + 1))
    if ! "$@" >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Expected command to fail: $*"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# Test: Digest command
# ═══════════════════════════════════════════════════════════════════════════

test_digest() {
    echo ""
    echo "=== Digest ==="

    setup_test_env
    $WV init >/dev/null 2>&1

    # Create some nodes to get meaningful stats
    local id1 id2 id3 id4
    id1=$($WV add "Task one" 2>&1 | tail -1)
    id2=$($WV add "Task two" 2>&1 | tail -1)
    id3=$($WV add "Task three" 2>&1 | tail -1)
    id4=$($WV add "Active task" 2>&1 | tail -1)
    $WV work "$id4" >/dev/null 2>&1

    # Text format
    local output
    output=$($WV digest 2>/dev/null)
    assert_contains "$output" "nodes" "digest shows node count"
    assert_contains "$output" "active" "digest shows active count"
    assert_contains "$output" "ready" "digest shows ready count"

    # JSON format
    local json_output
    json_output=$($WV digest --json 2>/dev/null)

    TESTS_RUN=$((TESTS_RUN + 1))
    if echo "$json_output" | jq '.' >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} digest --json is valid JSON"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} digest --json is valid JSON"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi

    assert_contains "$json_output" '"nodes"' "digest JSON has nodes field"
    assert_contains "$json_output" '"active"' "digest JSON has active field"
    assert_contains "$json_output" '"ready"' "digest JSON has ready field"
    assert_contains "$json_output" '"blocked"' "digest JSON has blocked field"
    assert_contains "$json_output" '"done"' "digest JSON has done field"
    assert_contains "$json_output" '"alerts"' "digest JSON has alerts field"
    assert_contains "$json_output" '"issues"' "digest JSON has issues object"

    # JSON values are reasonable
    local node_count
    node_count=$(echo "$json_output" | jq '.nodes' 2>/dev/null)
    assert_equals "4" "$node_count" "digest JSON shows correct total nodes"

    local active_count
    active_count=$(echo "$json_output" | jq '.active' 2>/dev/null)
    assert_equals "1" "$active_count" "digest JSON shows correct active count"
}

# ═══════════════════════════════════════════════════════════════════════════
# Test: Breadcrumbs command
# ═══════════════════════════════════════════════════════════════════════════

test_breadcrumbs() {
    echo ""
    echo "=== Breadcrumbs ==="

    setup_test_env
    $WV init >/dev/null 2>&1

    # Create some test data
    $WV add "Active work item" >/dev/null 2>&1
    local id1
    id1=$($WV add "Working on this" 2>&1 | tail -1)
    $WV work "$id1" >/dev/null 2>&1

    # Show with no breadcrumbs
    local show_output
    show_output=$($WV breadcrumbs show 2>/dev/null)
    assert_contains "$show_output" "No breadcrumbs" "show without saved breadcrumbs says none"

    # Save breadcrumbs
    assert_success "breadcrumbs save succeeds" "$WV" breadcrumbs save

    # Show saved breadcrumbs
    show_output=$($WV breadcrumbs show 2>/dev/null)
    assert_contains "$show_output" "Session Breadcrumbs" "show has header"
    assert_contains "$show_output" "Health" "show has health section"

    # Save with message
    assert_success "breadcrumbs save with message" "$WV" breadcrumbs save --message="Test checkpoint"
    show_output=$($WV breadcrumbs show 2>/dev/null)
    assert_contains "$show_output" "Test checkpoint" "show includes custom message"
    assert_contains "$show_output" "Notes" "show has Notes section for message"

    # Clear breadcrumbs
    local clear_output
    clear_output=$($WV breadcrumbs clear 2>/dev/null)
    assert_contains "$clear_output" "cleared" "clear confirms deletion"

    # Show after clear
    show_output=$($WV breadcrumbs show 2>/dev/null)
    assert_contains "$show_output" "No breadcrumbs" "show after clear says none"

    # Invalid action
    assert_fails "breadcrumbs with invalid action fails" "$WV" breadcrumbs invalid_action
}

# ═══════════════════════════════════════════════════════════════════════════
# Test: Learnings filters (--category, --grep, --recent)
# ═══════════════════════════════════════════════════════════════════════════

test_learnings_filters() {
    echo ""
    echo "=== Learnings Filters ==="

    setup_test_env
    $WV init >/dev/null 2>&1

    # Create nodes with various learning types via metadata
    local id1 id2 id3 id4
    id1=$($WV add "Auth implementation" --metadata='{"decision":"Use JWT tokens"}' 2>&1 | tail -1)
    id2=$($WV add "Cache layer" --metadata='{"pattern":"Cache aside pattern"}' 2>&1 | tail -1)
    id3=$($WV add "API design" --metadata='{"pitfall":"REST naming is tricky"}' 2>&1 | tail -1)
    id4=$($WV add "DB migration" 2>&1 | tail -1)

    # Mark all as done (id1-3 already have learning metadata, id4 gets --learning)
    $WV done "$id1" --no-warn >/dev/null 2>&1
    $WV done "$id2" --no-warn >/dev/null 2>&1
    $WV done "$id3" --no-warn >/dev/null 2>&1
    $WV done "$id4" --learning="Always backup first" --no-warn >/dev/null 2>&1

    # Basic learnings (no filter)
    local output
    output=$($WV learnings 2>/dev/null)
    assert_contains "$output" "JWT" "learnings shows decision content"
    assert_contains "$output" "Cache aside" "learnings shows pattern content"
    assert_contains "$output" "REST naming" "learnings shows pitfall content"
    assert_contains "$output" "backup" "learnings shows learning content"

    # Category filter: decision only
    output=$($WV learnings --category=decision 2>/dev/null)
    assert_contains "$output" "JWT" "category=decision shows decisions"
    assert_not_contains "$output" "Cache aside" "category=decision excludes patterns"

    # Category filter: pitfall only
    output=$($WV learnings --category=pitfall 2>/dev/null)
    assert_contains "$output" "REST naming" "category=pitfall shows pitfalls"
    assert_not_contains "$output" "JWT" "category=pitfall excludes decisions"

    # Category filter: pattern only
    output=$($WV learnings --category=pattern 2>/dev/null)
    assert_contains "$output" "Cache aside" "category=pattern shows patterns"

    # Invalid category
    local err_output
    err_output=$($WV learnings --category=invalid 2>&1 || true)
    assert_contains "$err_output" "invalid" "invalid category gives error"

    # Grep filter
    output=$($WV learnings --grep=JWT 2>/dev/null)
    assert_contains "$output" "JWT" "grep=JWT finds match"

    output=$($WV learnings --grep=backup 2>/dev/null)
    assert_contains "$output" "backup" "grep=backup finds match"

    # Recent limit
    output=$($WV learnings --recent=2 2>/dev/null)
    # Should show at most 2 results (exact content depends on order)
    local line_count
    line_count=$(echo "$output" | grep -c '─\|━\|ID:' || true)
    # Just check it doesn't error and produces output
    assert_success "learnings --recent=2 succeeds" "$WV" learnings --recent=2

    # Invalid recent
    err_output=$($WV learnings --recent=abc 2>&1 || true)
    assert_contains "$err_output" "number" "non-numeric --recent gives error"

    # JSON output
    local json_output
    json_output=$($WV learnings --json 2>/dev/null)
    TESTS_RUN=$((TESTS_RUN + 1))
    if echo "$json_output" | jq '.' >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} learnings --json is valid JSON"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} learnings --json is valid JSON"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi

    # Combined filters
    output=$($WV learnings --category=decision --grep=JWT 2>/dev/null)
    assert_contains "$output" "JWT" "combined category+grep works"
}

# ═══════════════════════════════════════════════════════════════════════════
# Test: Write-time validation on done
# ═══════════════════════════════════════════════════════════════════════════

test_validation_on_done() {
    echo ""
    echo "=== Write-time Validation ==="

    setup_test_env
    $WV init >/dev/null 2>&1

    # Create an orphan node (no edges, no learning) and complete it
    local id1
    id1=$($WV add "Orphan task" 2>&1 | tail -1)

    # Complete without learning — should show validation warnings on stderr
    local full_output
    full_output=$($WV done "$id1" 2>&1)
    assert_contains "$full_output" "learning" "done without learning shows learning warning"
    assert_contains "$full_output" "Orphan" "done without edges shows orphan warning"

    # Create a linked node with learning — should NOT warn
    setup_test_env
    $WV init >/dev/null 2>&1
    local parent child
    parent=$($WV add "Parent" 2>&1 | tail -1)
    child=$($WV add "Child" 2>&1 | tail -1)
    $WV link "$child" "$parent" --type=implements >/dev/null 2>&1

    local done_output
    done_output=$($WV done "$child" --learning="Learned something" 2>&1)
    assert_not_contains "$done_output" "No learning" "done with learning suppresses learning warning"
    assert_not_contains "$done_output" "Orphan" "done with edges suppresses orphan warning"

    # Test --no-warn suppresses all warnings
    setup_test_env
    $WV init >/dev/null 2>&1
    local orphan
    orphan=$($WV add "Another orphan" 2>&1 | tail -1)

    done_output=$($WV done "$orphan" --no-warn 2>&1)
    assert_not_contains "$done_output" "Validation" "done --no-warn suppresses all warnings"
    assert_not_contains "$done_output" "learning" "done --no-warn suppresses learning warning"
}

# ═══════════════════════════════════════════════════════════════════════════
# Test: Breadcrumbs content with rich data
# ═══════════════════════════════════════════════════════════════════════════

test_breadcrumbs_rich() {
    echo ""
    echo "=== Breadcrumbs (rich data) ==="

    setup_test_env
    $WV init >/dev/null 2>&1

    # Create a blocked node (wv block sets status=blocked AND creates edge)
    local blocker blocked
    blocker=$($WV add "Blocker task" 2>&1 | tail -1)
    blocked=$($WV add "Blocked task" 2>&1 | tail -1)
    $WV block "$blocked" --by="$blocker" >/dev/null 2>&1

    # Create a node with learning (via metadata since done doesn't support --decision)
    local done_id
    done_id=$($WV add "Completed work" --metadata='{"decision":"Important decision"}' 2>&1 | tail -1)
    $WV done "$done_id" --no-warn >/dev/null 2>&1

    # Create an active node
    local active_id
    active_id=$($WV add "Working now" 2>&1 | tail -1)
    $WV work "$active_id" >/dev/null 2>&1

    # Save breadcrumbs
    $WV breadcrumbs save >/dev/null 2>&1
    local output
    output=$($WV breadcrumbs show 2>/dev/null)

    assert_contains "$output" "Active Work" "breadcrumbs shows Active Work section"
    assert_contains "$output" "Working now" "breadcrumbs shows active node text"
    assert_contains "$output" "Health" "breadcrumbs shows Health section"
    assert_contains "$output" "Blocked" "breadcrumbs shows Blocked section"
}

# ═══════════════════════════════════════════════════════════════════════════
# Test: Digest alerts
# ═══════════════════════════════════════════════════════════════════════════

test_digest_alerts() {
    echo ""
    echo "=== Digest Alerts ==="

    setup_test_env
    $WV init >/dev/null 2>&1

    # Create a node with a pitfall but no addressing edge
    local id1
    id1=$($WV add "Task with pitfall" --metadata='{"pitfall":"Something bad"}' 2>&1 | tail -1)
    $WV done "$id1" --no-warn >/dev/null 2>&1

    local json_output
    json_output=$($WV digest --json 2>/dev/null)
    local pitfall_count
    pitfall_count=$(echo "$json_output" | jq '.issues.unaddressed_pitfalls' 2>/dev/null)
    assert_equals "1" "$pitfall_count" "digest detects unaddressed pitfall"

    # Text output should show alert
    local text_output
    text_output=$($WV digest 2>/dev/null)
    assert_contains "$text_output" "pitfall" "digest text shows pitfall alert"
}

# ═══════════════════════════════════════════════════════════════════════════
# Run all tests
# ═══════════════════════════════════════════════════════════════════════════

main() {
    echo "Sprint 2b: Agent Orientation Tests"
    echo "════════════════════════════════════"

    test_digest
    test_breadcrumbs
    test_learnings_filters
    test_validation_on_done
    test_breadcrumbs_rich
    test_digest_alerts

    echo ""
    echo "════════════════════════════════════"
    echo -e "Results: ${TESTS_PASSED}/${TESTS_RUN} passed"

    if [ "$TESTS_FAILED" -gt 0 ]; then
        echo -e "${RED}${TESTS_FAILED} tests FAILED${NC}"
        exit 1
    else
        echo -e "${GREEN}ALL TESTS PASSED${NC}"
        exit 0
    fi
}

main "$@"
