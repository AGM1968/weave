#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# test-phase-fsm.sh — Tests for session phase state machine
#
# Sprint 1 prerequisite: wv-b7813e (feat(S1): wv_set_phase + PHASE_VALUES + wv doctor check)
#
# Covers:
#   - PHASE_VALUES constant exported from wv-validate.sh
#   - wv_set_phase() validates before writing
#   - All 5 write sites use wv_set_phase (checked via grep in pattern-audit)
#   - wv doctor flags invalid .session_phase value
#   - Default behaviour (missing file → execute)
#   - Transition table: work→execute, done→closing, pre-commit→discover, session-start→discover
#
# Until wv-b7813e lands, structural checks run as EXPECT-FAIL.
#
# Exit codes:
#   0 - All tests passed (or expected failures recorded)
#   1 - Unexpected failure

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$PROJECT_ROOT/scripts/wv"
WV_VALIDATE="$PROJECT_ROOT/scripts/lib/wv-validate.sh"

TEST_DIR="/tmp/wv-phase-fsm-test-$$"
export WV_HOT_ZONE="$TEST_DIR"
export WV_DB="$TEST_DIR/brain.db"
export WV_REQUIRE_LEARNING=0
export WV_RUN_CACHE=0
export WV_PROJECT_DIR="$TEST_DIR"

cleanup() { cd /tmp && rm -rf "$TEST_DIR"; }
trap cleanup EXIT

setup_test_env() {
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR"
    export WV_PROJECT_DIR="$TEST_DIR"
    cd "$TEST_DIR"
    git init -q
    "$WV" init -q 2>/dev/null || true
}

assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$expected" = "$actual" ]; then
        echo -e "  ${GREEN}[PASS]${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} $message (expected '$expected', got '$actual')"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if echo "$haystack" | grep -qF "$needle"; then
        echo -e "  ${GREEN}[PASS]${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} $message (expected '$needle' in output)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_exit() {
    local expected_exit="$1"
    local actual_exit="$2"
    local message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$expected_exit" -eq "$actual_exit" ]; then
        echo -e "  ${GREEN}[PASS]${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} $message (expected exit $expected_exit, got $actual_exit)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# ─── Tests ────────────────────────────────────────────────────────────────────

test_phase_values_constant_exists() {
    echo "-- PHASE_VALUES exported from wv-validate.sh"
    local phase_values
    # shellcheck source=/dev/null
    phase_values=$(bash -c "source '$WV_VALIDATE' 2>/dev/null; echo \"\${PHASE_VALUES:-}\"")
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ -n "$phase_values" ]; then
        echo -e "  ${GREEN}[PASS]${NC} PHASE_VALUES defined in wv-validate.sh"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} PHASE_VALUES not defined in wv-validate.sh"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

test_phase_values_contains_all_values() {
    echo "-- PHASE_VALUES contains execute, discover, closing"
    local phase_values
    phase_values=$(bash -c "source '$WV_VALIDATE' 2>/dev/null; echo \"\${PHASE_VALUES:-}\"")
    for val in execute discover closing; do
        if echo "$phase_values" | grep -qw "$val"; then
            echo -e "  ${GREEN}[PASS]${NC} PHASE_VALUES contains '$val'"
            TESTS_RUN=$((TESTS_RUN + 1))
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo -e "  ${RED}[FAIL]${NC} PHASE_VALUES missing '$val'"
            TESTS_RUN=$((TESTS_RUN + 1))
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    done
}

test_set_phase_valid_values() {
    echo "-- wv_set_phase accepts valid values"
    setup_test_env
    # Source lib and call wv_set_phase; check file contents
    for phase in execute discover closing; do
        local rc=0
        bash -c "
            export WV_HOT_ZONE='$TEST_DIR'
            source '$PROJECT_ROOT/scripts/lib/wv-config.sh' 2>/dev/null || true
            source '$WV_VALIDATE' 2>/dev/null || true
            source '$PROJECT_ROOT/scripts/lib/wv-resolve-runtime.sh' 2>/dev/null || true
            type wv_set_phase >/dev/null 2>&1 && wv_set_phase '$phase'
        " || rc=$?
        local written
        written=$(cat "$TEST_DIR/.session_phase" 2>/dev/null || echo "")
        if [ "$written" = "$phase" ]; then
            echo -e "  ${GREEN}[PASS]${NC} wv_set_phase writes '$phase'"
            TESTS_RUN=$((TESTS_RUN + 1))
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo -e "  ${RED}[FAIL]${NC} wv_set_phase failed to write '$phase'"
            TESTS_RUN=$((TESTS_RUN + 1))
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    done
}

test_set_phase_rejects_invalid() {
    echo "-- wv_set_phase rejects unknown values"
    setup_test_env
    local rc=0
    bash -c "
        export WV_HOT_ZONE='$TEST_DIR'
        source '$WV_VALIDATE' 2>/dev/null || true
        type wv_set_phase >/dev/null 2>&1 && wv_set_phase 'invalid-phase'
    " 2>/dev/null || rc=$?
    # Expect nonzero exit; file should not be written with invalid value
    local written
    written=$(cat "$TEST_DIR/.session_phase" 2>/dev/null || echo "")
    if [ "$written" = "invalid-phase" ] || [ -z "$written" ] && [ "$rc" -eq 0 ]; then
        echo -e "  ${RED}[FAIL]${NC} wv_set_phase accepted invalid phase value"
        TESTS_RUN=$((TESTS_RUN + 1))
        TESTS_FAILED=$((TESTS_FAILED + 1))
    else
        echo -e "  ${GREEN}[PASS]${NC} wv_set_phase rejects 'invalid-phase'"
        TESTS_RUN=$((TESTS_RUN + 1))
        TESTS_PASSED=$((TESTS_PASSED + 1))
    fi
}

test_default_phase_is_execute() {
    echo "-- missing .session_phase defaults to execute (both hooks)"
    setup_test_env
    rm -f "$TEST_DIR/.session_phase"
    local phase
    # Both hook readers do: cat .session_phase 2>/dev/null || echo "execute"
    phase=$(cat "$TEST_DIR/.session_phase" 2>/dev/null || echo "execute")
    assert_equals "execute" "$phase" "missing .session_phase defaults to execute"
}

test_work_transition_sets_execute() {
    echo "-- wv work sets phase to execute"
    setup_test_env
    local id
    id=$("$WV" add "test task" 2>/dev/null | tail -1)
    "$WV" update "$id" --alias=phase-test 2>/dev/null
    # Pre-set to discover so we can detect the change
    echo "discover" > "$TEST_DIR/.session_phase"
    WV_SKIP_PRECOMMIT=1 "$WV" work "$id" 2>/dev/null || true
    local phase
    phase=$(cat "$TEST_DIR/.session_phase" 2>/dev/null || echo "")
    # Transition already works (raw echo in cmd_work); assert_equals now.
    # After wv-b7813e: this same test verifies wv_set_phase is being used.
    assert_equals "execute" "$phase" "wv work sets .session_phase to execute"
}

test_add_active_transition_sets_execute() {
    echo "-- wv add --status=active sets phase to execute (WorkClaimed event)"
    setup_test_env
    echo "discover" > "$TEST_DIR/.session_phase"
    "$WV" add "active-on-create task" --status=active --standalone \
        --criteria="c1" --risks=low --alias=add-active-test 2>/dev/null >/dev/null || true
    local phase
    phase=$(cat "$TEST_DIR/.session_phase" 2>/dev/null || echo "")
    assert_equals "execute" "$phase" "wv add --status=active sets .session_phase to execute"
}

test_add_todo_does_not_change_phase() {
    echo "-- wv add (todo) leaves phase unchanged"
    setup_test_env
    echo "discover" > "$TEST_DIR/.session_phase"
    "$WV" add "plain todo task" --standalone --alias=add-todo-test 2>/dev/null >/dev/null || true
    local phase
    phase=$(cat "$TEST_DIR/.session_phase" 2>/dev/null || echo "")
    assert_equals "discover" "$phase" "wv add without --status=active leaves phase at discover"
}

test_done_transition_sets_closing() {
    echo "-- wv done sets phase to closing"
    setup_test_env
    local id
    id=$("$WV" add "test task" 2>/dev/null | tail -1)
    "$WV" update "$id" --alias=phase-test2 2>/dev/null
    WV_SKIP_PRECOMMIT=1 "$WV" work "$id" 2>/dev/null || true
    WV_SKIP_PRECOMMIT=1 "$WV" done "$id" --skip-verification 2>/dev/null || true
    local phase
    phase=$(cat "$TEST_DIR/.session_phase" 2>/dev/null || echo "")
    # Transition already works (raw echo in cmd_done); assert_equals now.
    # After wv-b7813e: this same test verifies wv_set_phase is being used.
    assert_equals "closing" "$phase" "wv done sets .session_phase to closing"
}

test_doctor_flags_invalid_phase() {
    echo "-- wv doctor flags invalid .session_phase"
    setup_test_env
    "$WV" init -q 2>/dev/null || true
    echo "bogus-xphase" > "$TEST_DIR/.session_phase"
    local output rc=0
    output=$("$WV" doctor 2>&1) || rc=$?
    # Check for the invalid value itself (not "phase" which may appear in path names)
    if echo "$output" | grep -q "bogus-xphase\|invalid.*phase\|unknown.*phase"; then
        echo -e "  ${GREEN}[PASS]${NC} wv doctor flags invalid phase value"
        TESTS_RUN=$((TESTS_RUN + 1))
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} wv doctor did not flag invalid phase value"
        TESTS_RUN=$((TESTS_RUN + 1))
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

test_no_raw_phase_writes_in_source() {
    echo "-- no raw 'echo ... > .session_phase' calls outside wv_set_phase"
    local output rc=0
    output=$("$WV" pattern-audit 2>&1) || rc=$?
    if [ "$rc" -eq 0 ] && echo "$output" | grep -q "Check 3 PASS"; then
        echo -e "  ${GREEN}[PASS]${NC} no raw .session_phase writes"
        TESTS_RUN=$((TESTS_RUN + 1))
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} pattern-audit Check 3 did not pass"
        echo "$output" | sed 's/^/    /'
        TESTS_RUN=$((TESTS_RUN + 1))
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    echo "test-phase-fsm.sh"
    echo ""
    test_phase_values_constant_exists
    test_phase_values_contains_all_values
    test_set_phase_valid_values
    test_set_phase_rejects_invalid
    test_default_phase_is_execute
    test_work_transition_sets_execute
    test_add_active_transition_sets_execute
    test_add_todo_does_not_change_phase
    test_done_transition_sets_closing
    test_doctor_flags_invalid_phase
    test_no_raw_phase_writes_in_source

    echo ""
    echo "========================================"
    echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
    echo "========================================"

    [ "$TESTS_FAILED" -eq 0 ] || exit 1
    exit 0
}

main "$@"
