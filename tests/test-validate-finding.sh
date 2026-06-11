#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# test-validate-finding.sh — Golden fixture tests for wv validate-finding
#
# Contract: exit 0 = valid, exit 1 = invalid, stdout = {"valid":bool,"errors":[...]}
# The hook (pre-close-verification.sh) delegates to this subcommand.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$PROJECT_ROOT/scripts/wv"

TEST_DIR="/tmp/wv-validate-finding-test-$$"
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
    "$WV" init >/dev/null 2>&1
}

assert_exit() {
    local expected="$1" actual="$2" msg="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$expected" -eq "$actual" ]; then
        echo -e "  ${GREEN}✓${NC} $msg"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗${NC} $msg (expected exit $expected, got $actual)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" msg="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if printf '%s' "$haystack" | grep -qF "$needle"; then
        echo -e "  ${GREEN}✓${NC} $msg"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗${NC} $msg (expected '$needle' in output)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" msg="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if ! printf '%s' "$haystack" | grep -qF "$needle"; then
        echo -e "  ${GREEN}✓${NC} $msg"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗${NC} $msg (unexpected '$needle' in output)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# ─── Fixture helpers (correct finding metadata structure) ──────────────────────
# Findings use metadata.type="finding" and metadata.finding.* for fields.

_add_finding() {
    local id
    id=$("$WV" add "test finding node" 2>/dev/null | tail -1)
    "$WV" update "$id" --metadata="$1" >/dev/null 2>&1
    echo "$id"
}

_valid_meta() {
    printf '%s' '{"type":"finding","finding":{"violation_type":"repo:regression","root_cause":"cache not invalidated on ship-agent","proposed_fix":"add ship-agent to write-list","confidence":"high","fixable":true}}'
}

_missing_violation_type_meta() {
    printf '%s' '{"type":"finding","finding":{"root_cause":"something broke"}}'
}

_invalid_violation_type_meta() {
    printf '%s' '{"type":"finding","finding":{"violation_type":"not:a:real:type"}}'
}

_bad_optional_meta() {
    # violation_type valid, but confidence has wrong value
    printf '%s' '{"type":"finding","finding":{"violation_type":"repo:hygiene","confidence":"very-sure"}}'
}

# ─── Tests ────────────────────────────────────────────────────────────────────

test_valid_finding_exits_zero() {
    echo ""
    echo "Test: valid finding"
    setup_test_env
    local id
    id=$(_add_finding "$(_valid_meta)")
    local rc=0
    "$WV" validate-finding "$id" >/dev/null 2>&1 || rc=$?
    assert_exit 0 "$rc" "valid finding: exits 0"

    local out
    out=$("$WV" validate-finding "$id" 2>/dev/null)
    assert_contains "$out" '"valid":true' "valid finding: JSON has valid:true"
    assert_contains "$out" '"errors":[]' "valid finding: errors array empty"
}

test_missing_violation_type_exits_one() {
    echo ""
    echo "Test: missing violation_type"
    setup_test_env
    local id
    id=$(_add_finding "$(_missing_violation_type_meta)")
    local rc=0
    "$WV" validate-finding "$id" >/dev/null 2>&1 || rc=$?
    assert_exit 1 "$rc" "missing violation_type: exits 1"

    local out
    out=$("$WV" validate-finding "$id" 2>/dev/null || true)
    assert_contains "$out" '"valid":false' "missing violation_type: JSON has valid:false"
    assert_contains "$out" "violation_type" "missing violation_type: errors names the field"
}

test_invalid_violation_type_exits_one() {
    echo ""
    echo "Test: invalid violation_type enum"
    setup_test_env
    local id
    id=$("$WV" add "test finding node" 2>/dev/null | tail -1)

    # Tier 1: wv update --metadata rejects an invalid enum at write time.
    local rc=0
    "$WV" update "$id" --metadata="$(_invalid_violation_type_meta)" >/dev/null 2>&1 || rc=$?
    assert_exit 1 "$rc" "invalid enum: rejected at update time"

    # Read-side branch (pre-close hook still validates legacy/dirty data):
    # plant the bad metadata via direct sqlite, bypassing the write-time guard.
    local db
    db=$("$WV" hotzone --db 2>/dev/null)
    sqlite3 "$db" "UPDATE nodes SET metadata='$(_invalid_violation_type_meta)' WHERE id='$id';"
    rc=0
    "$WV" validate-finding "$id" >/dev/null 2>&1 || rc=$?
    assert_exit 1 "$rc" "invalid enum: exits 1"

    local out
    out=$("$WV" validate-finding "$id" 2>/dev/null || true)
    assert_contains "$out" "invalid enum" "invalid enum: error message names the problem"
    assert_not_contains "$out" '"valid":true' "invalid enum: not reported as valid"
}

test_bad_optional_field_exits_one() {
    echo ""
    echo "Test: bad optional field (confidence)"
    setup_test_env
    local id
    id=$(_add_finding "$(_bad_optional_meta)")
    local rc=0
    "$WV" validate-finding "$id" >/dev/null 2>&1 || rc=$?
    assert_exit 1 "$rc" "bad confidence value: exits 1"

    local out
    out=$("$WV" validate-finding "$id" 2>/dev/null || true)
    assert_contains "$out" "confidence" "bad confidence: named in errors"
}

test_unknown_node_exits_nonzero() {
    echo ""
    echo "Test: unknown node ID"
    setup_test_env
    local rc=0
    "$WV" validate-finding "wv-000000" >/dev/null 2>&1 || rc=$?
    assert_exit 1 "$rc" "unknown node: exits 1"
}

test_non_finding_node_exits_zero() {
    echo ""
    echo "Test: non-finding node (trivially valid)"
    setup_test_env
    local id
    id=$("$WV" add "regular task" 2>/dev/null | tail -1)
    local rc=0
    "$WV" validate-finding "$id" >/dev/null 2>&1 || rc=$?
    assert_exit 0 "$rc" "non-finding node: exits 0 (nothing to validate)"

    local out
    out=$("$WV" validate-finding "$id" 2>/dev/null)
    assert_contains "$out" '"valid":true' "non-finding: JSON has valid:true"
}

test_help_text() {
    echo ""
    echo "Test: --help"
    local out
    out=$("$WV" validate-finding --help 2>&1 || true)
    assert_contains "$out" "validate-finding" "help: mentions command name"
    assert_contains "$out" "exit" "help: mentions exit code semantics"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    echo "========================================"
    echo "validate-finding Tests"
    echo "========================================"

    test_valid_finding_exits_zero
    test_missing_violation_type_exits_one
    test_invalid_violation_type_exits_one
    test_bad_optional_field_exits_one
    test_unknown_node_exits_nonzero
    test_non_finding_node_exits_zero
    test_help_text

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
