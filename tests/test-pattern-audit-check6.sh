#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# test-pattern-audit-check6.sh — Tests for pattern-audit Check 6
#
# Source: finding wv-f752a5 / wv-8bb0f4 (recurrence) — "not ready" intent
# expressed as node metadata (deferred=true / blocked_on) while status='todo'
# with no inbound blocks edge still surfaces in `wv ready`. Check 6 promotes
# that recurring learning to an enforced gate.
#
# Covers:
#   - FAIL: a todo node with metadata.deferred=true and no blocks edge
#   - FAIL: a todo node with metadata.blocked_on set and no blocks edge
#   - PASS: same node re-encoded as status=blocked-external drops the divergence
#   - PASS: a todo node whose deferral is backed by a real blocks edge
#
# Exit codes:
#   0 - All tests passed
#   1 - Unexpected failure

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

TEST_DIR="/tmp/wv-pa-check6-test-$$"
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

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if echo "$haystack" | grep -qF "$needle"; then
        echo -e "  ${RED}[FAIL]${NC} $message (unexpected '$needle' in output)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    else
        echo -e "  ${GREEN}[PASS]${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    fi
}

# Extract the wv-XXXXXX id from a `wv add` invocation.
_add_node() {
    "$WV" add "$1" --metadata="$2" 2>/dev/null | grep -oE 'wv-[a-f0-9]{6}' | head -1
}

# ─── Tests ──────────────────────────────────────────────────────────────────

test_deferred_metadata_fails() {
    echo "-- todo + metadata.deferred=true + no blocks edge → Check 6 FAIL"
    local id out
    id=$(_add_node "deferred via metadata only" '{"deferred":true}')
    out=$("$WV" pattern-audit 2>&1 || true)
    assert_contains "$out" "Check 6 FAIL" "deferred-but-ready node flagged"
    assert_contains "$out" "$id" "the divergent node id is listed"
}

test_blocked_on_metadata_fails() {
    echo "-- todo + metadata.blocked_on set + no blocks edge → Check 6 FAIL"
    local out
    _add_node "blocked_on via metadata only" '{"blocked_on":"some external gate"}' >/dev/null
    out=$("$WV" pattern-audit 2>&1 || true)
    assert_contains "$out" "Check 6 FAIL" "blocked_on-but-ready node flagged"
}

test_blocked_external_status_passes() {
    echo "-- re-encode as status=blocked-external → Check 6 PASS"
    local id out
    id=$(_add_node "deferred, will be fixed" '{"deferred":true}')
    "$WV" update "$id" --status=blocked-external >/dev/null 2>&1
    out=$("$WV" pattern-audit 2>&1 || true)
    assert_contains "$out" "Check 6 PASS" "no divergence once status encodes deferral"
    assert_not_contains "$out" "Check 6 FAIL" "no FAIL after re-encoding"
}

test_blocks_edge_passes() {
    echo "-- todo + deferred metadata BUT backed by a real blocks edge → Check 6 PASS"
    local blocker deferred out
    blocker=$(_add_node "the active blocker" '{}')
    deferred=$(_add_node "deferred but properly blocked" '{"deferred":true}')
    # blocker blocks deferred; blocker is not done → deferred is genuinely not ready
    "$WV" link "$blocker" "$deferred" --type=blocks >/dev/null 2>&1
    out=$("$WV" pattern-audit 2>&1 || true)
    assert_contains "$out" "Check 6 PASS" "deferral backed by a blocks edge is not a divergence"
}

test_doctor_node_state_advisory() {
    echo "-- wv doctor mirrors Check 6 as a per-install advisory"
    _add_node "deferred via metadata only" '{"deferred":true}' >/dev/null
    local out
    out=$("$WV" doctor 2>&1 || true)
    assert_contains "$out" "node-state" "doctor emits a node-state check"
    assert_contains "$out" "remain ready" "doctor warns on deferred-but-ready node"
}

test_hotzone_db_prints_resolved_path() {
    echo "-- wv hotzone db prints the resolved brain.db path"
    local dbpath
    dbpath=$("$WV" hotzone db 2>/dev/null)
    case "$dbpath" in
        */brain.db) echo -e "  ${GREEN}[PASS]${NC} hotzone db ends in brain.db"; TESTS_RUN=$((TESTS_RUN+1)); TESTS_PASSED=$((TESTS_PASSED+1)) ;;
        *) echo -e "  ${RED}[FAIL]${NC} hotzone db returned '$dbpath'"; TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAILED=$((TESTS_FAILED+1)) ;;
    esac
    # --db alias resolves identically
    local dbpath2
    dbpath2=$("$WV" hotzone --db 2>/dev/null)
    assert_contains "$dbpath2" "$dbpath" "hotzone --db matches hotzone db"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    echo "test-pattern-audit-check6.sh"
    echo ""

    setup_test_env; test_deferred_metadata_fails
    setup_test_env; test_blocked_on_metadata_fails
    setup_test_env; test_blocked_external_status_passes
    setup_test_env; test_blocks_edge_passes
    setup_test_env; test_doctor_node_state_advisory
    setup_test_env; test_hotzone_db_prints_resolved_path

    echo ""
    echo "========================================"
    echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
    echo "========================================"

    [ "$TESTS_FAILED" -eq 0 ] || exit 1
    exit 0
}

main "$@"
