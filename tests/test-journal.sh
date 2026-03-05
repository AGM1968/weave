#!/usr/bin/env bash
# test-journal.sh — Test operation journal (wv-journal.sh)
#
# Tests: journal_begin, journal_step, journal_complete, journal_end,
#        journal_recover, journal_clean, journal_has_incomplete,
#        _WV_IN_JOURNAL guard
#
# Exit codes:
#   0 - All tests passed
#   1 - One or more tests failed

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
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
TEST_DIR="/tmp/wv-journal-test-$$"
export WV_HOT_ZONE="$TEST_DIR"
export WV_DB="$TEST_DIR/brain.db"

# Cleanup
cleanup() {
    cd /tmp
    if [ -d "$TEST_DIR" ]; then
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

# ═══════════════════════════════════════════════════════════════════════════
# Test helpers
# ═══════════════════════════════════════════════════════════════════════════

setup_test_env() {
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR"
    cd "$TEST_DIR"
    git init -q
    # Source the journal lib (needs wv-config.sh loaded first)
    source "$PROJECT_ROOT/scripts/lib/wv-config.sh"
    source "$PROJECT_ROOT/scripts/lib/wv-journal.sh"
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
        echo "  Expected failure but succeeded: $*"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# Tests
# ═══════════════════════════════════════════════════════════════════════════

echo -e "${CYAN}═══ Journal Library Tests ═══${NC}"
echo ""

# --- Test 1: journal_begin creates journal file with begin event ---
echo -e "${CYAN}--- Basic lifecycle ---${NC}"
setup_test_env

journal_begin "ship" '{"id":"wv-1234"}'

assert_equals "1" "$(wc -l < "$_WV_JOURNAL_FILE")" \
    "journal_begin writes one line"

line=$(head -1 "$_WV_JOURNAL_FILE")
assert_contains "$line" '"event":"begin"' \
    "begin event recorded"
assert_contains "$line" '"op":"ship"' \
    "operation type recorded"
assert_contains "$line" '"wv-1234"' \
    "args recorded"

# --- Test 2: _WV_IN_JOURNAL is set during operation ---
assert_equals "1" "${_WV_IN_JOURNAL:-0}" \
    "_WV_IN_JOURNAL=1 during operation"

# --- Test 3: journal_step records pending step ---
journal_step 1 "done" '{"id":"wv-1234"}'

assert_equals "2" "$(wc -l < "$_WV_JOURNAL_FILE")" \
    "journal_step appends one line"

line=$(tail -1 "$_WV_JOURNAL_FILE")
assert_contains "$line" '"status":"pending"' \
    "step starts as pending"
assert_contains "$line" '"action":"done"' \
    "step action recorded"
assert_contains "$line" '"step":1' \
    "step number recorded"

# --- Test 4: journal_complete marks step done ---
journal_complete 1

line=$(tail -1 "$_WV_JOURNAL_FILE")
assert_contains "$line" '"status":"done"' \
    "journal_complete marks step done"

# --- Test 5: Full lifecycle (4-step ship) ---
journal_step 2 "sync" '{"gh":true}'
journal_complete 2
journal_step 3 "git_commit"
journal_complete 3
journal_step 4 "git_push"
journal_complete 4
journal_end

assert_equals "" "${_WV_IN_JOURNAL:-}" \
    "_WV_IN_JOURNAL unset after journal_end"

line=$(tail -1 "$_WV_JOURNAL_FILE")
assert_contains "$line" '"event":"end"' \
    "journal_end records end event"

total_lines=$(wc -l < "$_WV_JOURNAL_FILE")
assert_equals "10" "$total_lines" \
    "Complete ship op = 10 lines (begin + 4×step/complete + end)"

echo ""
echo -e "${CYAN}--- Recovery detection ---${NC}"

# --- Test 6: journal_has_incomplete returns false for complete ops ---
setup_test_env

journal_begin "sync" '{"gh":false}'
journal_step 1 "dump"
journal_complete 1
journal_step 2 "gh_sync"
journal_complete 2
journal_end

assert_fails "journal_has_incomplete returns 1 for complete ops" \
    journal_has_incomplete

# --- Test 7: journal_has_incomplete returns true for interrupted ops ---
setup_test_env

journal_begin "ship" '{"id":"wv-5678"}'
journal_step 1 "done"
journal_complete 1
journal_step 2 "sync"
# Simulating crash: no journal_complete 2, no journal_end

assert_success "journal_has_incomplete returns 0 for interrupted ops" \
    journal_has_incomplete

# --- Test 8: journal_recover detects the incomplete op ---
recovery_json=$(journal_recover --json)

assert_contains "$recovery_json" '"status":"incomplete"' \
    "journal_recover finds incomplete op"
assert_contains "$recovery_json" '"op":"ship"' \
    "journal_recover identifies op type"
assert_contains "$recovery_json" '"action":"sync"' \
    "journal_recover identifies stuck action"

# --- Test 9: journal_recover --json includes completed steps ---
completed_steps=$(echo "$recovery_json" | jq -r '.operation.completed_steps | join(",")')
assert_equals "1" "$completed_steps" \
    "journal_recover reports step 1 as completed"

pending_action=$(echo "$recovery_json" | jq -r '.operation.pending_step.action')
assert_equals "sync" "$pending_action" \
    "journal_recover reports pending action"

echo ""
echo -e "${CYAN}--- Edge cases ---${NC}"

# --- Test 10: journal_recover on clean state returns 1 ---
setup_test_env

assert_fails "journal_recover returns 1 on empty journal" \
    journal_recover --json

# --- Test 11: journal_recover on no file returns 1 ---
rm -f "$_WV_JOURNAL_FILE"

assert_fails "journal_recover returns 1 on missing journal" \
    journal_recover --json

# --- Test 12: journal_clean removes completed ops ---
setup_test_env

# Complete operation
journal_begin "sync" '{"gh":true}'
journal_step 1 "dump"
journal_complete 1
journal_end

# Incomplete operation
journal_begin "ship" '{"id":"wv-aaaa"}'
journal_step 1 "done"
# crash here

lines_before=$(wc -l < "$_WV_JOURNAL_FILE")
journal_clean
lines_after=$(wc -l < "$_WV_JOURNAL_FILE")

# After clean: should only have the incomplete op's events (2 lines: begin + step)
assert_equals "2" "$lines_after" \
    "journal_clean keeps only incomplete op events (before=$lines_before)"

# Verify incomplete op is still recoverable
assert_success "Incomplete op still recoverable after clean" \
    journal_has_incomplete

# --- Test 13: journal_clean on all-complete ops truncates ---
setup_test_env

journal_begin "sync" '{}'
journal_step 1 "dump"
journal_complete 1
journal_end

journal_clean

assert_equals "0" "$(wc -c < "$_WV_JOURNAL_FILE")" \
    "journal_clean truncates when all ops complete"

# --- Test 14: Multiple complete ops + one incomplete ---
setup_test_env

# Op 1: complete
journal_begin "sync" '{"run":1}'
journal_step 1 "dump"
journal_complete 1
journal_end

# Op 2: complete
journal_begin "ship" '{"run":2}'
journal_step 1 "done"
journal_complete 1
journal_step 2 "sync"
journal_complete 2
journal_end

# Op 3: incomplete
journal_begin "ship" '{"run":3}'
journal_step 1 "done"
journal_complete 1
journal_step 2 "sync"
# crash

assert_success "has_incomplete finds the one incomplete among 3 ops" \
    journal_has_incomplete

recovery=$(journal_recover --json)
assert_contains "$recovery" '"run":3' \
    "journal_recover finds the correct (latest) incomplete op"

# --- Test 15: Human-readable recovery output ---
setup_test_env
journal_begin "ship" '{"id":"wv-beef"}'
journal_step 1 "done"
journal_complete 1
journal_step 2 "sync"
# crash

human_output=$(journal_recover 2>&1)
assert_contains "$human_output" "Incomplete operation" \
    "Human output shows warning"
assert_contains "$human_output" "wv ship" \
    "Human output shows op type"
assert_contains "$human_output" "sync" \
    "Human output shows stuck action"

echo ""
echo -e "${CYAN}--- _WV_IN_JOURNAL guard ---${NC}"

# --- Test 16: Nested operations prevented ---
setup_test_env

journal_begin "ship" '{"id":"wv-1111"}'
saved_op_id="$_WV_CURRENT_OP_ID"

# Starting a new journal_begin during an active journal
# overwrites the current op (by design — caller's responsibility)
journal_begin "sync" '{}'

# The guard variable should still be set
assert_equals "1" "${_WV_IN_JOURNAL:-0}" \
    "_WV_IN_JOURNAL stays set across nested begin"

journal_end
assert_equals "" "${_WV_IN_JOURNAL:-}" \
    "_WV_IN_JOURNAL unset after nested end"

# ═══════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${CYAN}═══════════════════════════════════${NC}"
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
if [ "$TESTS_FAILED" -gt 0 ]; then
    echo -e "${RED}$TESTS_FAILED test(s) failed${NC}"
    exit 1
else
    echo -e "${GREEN}All tests passed${NC}"
    exit 0
fi
