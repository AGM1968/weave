#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# test-doctor-hotzone-shadow.sh — wv doctor's second-brain.db advisory
#
# Source: wv-854b4a (decision wv-ff0419 Q1: the hot-zone rule belongs to the
# tool). Placement follows the runtime class (is_sandboxed_runtime), so a
# brain.db for this repository under a placement root it does not resolve to is
# another runtime class's zone or debris. On 2026-09-25 an empty one, created by
# sqlite3 opening a guessed /dev/shm path, was read as a split brain.
#
# Covers:
#   - PASS: no brain.db for this repo outside the live hot zone
#   - WARN: an empty brain.db under another root (guessed-path debris)
#   - WARN: a non-empty brain.db under another root (second DB for the repo)
#   - the live hot zone's own root is never reported
#   - planted shadows do not change what wv hotzone db resolves
#   - wv help hotzone lists the db subcommand
#
# Roots come from WV_DOCTOR_PLACEMENT_ROOTS, so nothing is planted in the real
# /tmp/weave-codex-<uid> or /dev/shm/weave.
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

TEST_DIR="/tmp/wv-doctor-hzshadow-fixture-$$"
export WV_CONFIG_DIR="$TEST_DIR/config"

cleanup() { cd /tmp && rm -rf "$TEST_DIR"; }
trap cleanup EXIT

setup_test_env() {
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR/repo" "$TEST_DIR/roots/live" "$TEST_DIR/roots/other-a" "$TEST_DIR/roots/other-b"
    cd "$TEST_DIR/repo"
    git init -q
    export WV_PROJECT_DIR="$TEST_DIR/repo"
    HASH=$(echo "$TEST_DIR/repo" | md5sum | cut -c1-8)
    export WV_HOT_ZONE="$TEST_DIR/roots/live/$HASH"
    export WV_DOCTOR_PLACEMENT_ROOTS="$TEST_DIR/roots/live $TEST_DIR/roots/other-a $TEST_DIR/roots/other-b"
    "$WV" init >/dev/null 2>&1 || true
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if grep -qF -- "$needle" <<< "$haystack"; then
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
    if grep -qF -- "$needle" <<< "$haystack"; then
        echo -e "  ${RED}[FAIL]${NC} $message (unexpected '$needle' in output)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    else
        echo -e "  ${GREEN}[PASS]${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    fi
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

# ─── Tests ──────────────────────────────────────────────────────────────────

test_clean_passes() {
    echo "-- only the live hot zone holds this repo's brain.db → PASS"
    local out
    out=$("$WV" doctor 2>&1 || true)
    assert_contains "$out" "hot-zone shadow" "doctor emits a hot-zone shadow check"
    assert_contains "$out" "no brain.db for this repo outside" "doctor reports no second DB"
    assert_not_contains "$out" "$TEST_DIR/roots/live/$HASH/brain.db (left by" "the live zone is never reported as a shadow"
}

test_empty_shadow_warns() {
    echo "-- an empty brain.db under another root → WARN, names wv hotzone db"
    mkdir -p "$TEST_DIR/roots/other-a/$HASH"
    : > "$TEST_DIR/roots/other-a/$HASH/brain.db"
    local out
    out=$("$WV" doctor 2>&1 || true)
    assert_contains "$out" "empty $TEST_DIR/roots/other-a/$HASH/brain.db" "doctor names the empty shadow"
    assert_contains "$out" "left by opening a guessed path" "doctor says how an empty shadow arises"
    assert_contains "$out" "wv hotzone db" "doctor points at the resolver"
}

test_nonempty_shadow_warns() {
    echo "-- a non-empty brain.db under another root → WARN as a second DB"
    mkdir -p "$TEST_DIR/roots/other-b/$HASH"
    sqlite3 "$TEST_DIR/roots/other-b/$HASH/brain.db" "CREATE TABLE nodes(id TEXT);"
    local out
    out=$("$WV" doctor 2>&1 || true)
    assert_contains "$out" "second brain.db for this repo at $TEST_DIR/roots/other-b/$HASH/brain.db" \
        "doctor names the second DB"
    assert_contains "$out" "placement follows is_sandboxed_runtime" "doctor states the placement rule"
}

test_resolution_unchanged() {
    echo "-- planted shadows do not change what wv hotzone db resolves"
    local before after
    before=$("$WV" hotzone db 2>/dev/null)
    mkdir -p "$TEST_DIR/roots/other-a/$HASH" "$TEST_DIR/roots/other-b/$HASH"
    : > "$TEST_DIR/roots/other-a/$HASH/brain.db"
    sqlite3 "$TEST_DIR/roots/other-b/$HASH/brain.db" "CREATE TABLE nodes(id TEXT);"
    after=$("$WV" hotzone db 2>/dev/null)
    assert_equals "$before" "$after" "wv hotzone db resolves the same path with shadows present"
    assert_equals "$TEST_DIR/roots/live/$HASH/brain.db" "$after" "and that path is the live zone"
}

test_help_lists_db() {
    echo "-- wv help hotzone lists the db subcommand"
    local out
    out=$("$WV" help hotzone 2>&1 || true)
    assert_contains "$out" "wv hotzone db" "help names wv hotzone db"
    assert_contains "$out" "sqlite3 on a guessed path creates an empty database" "help says why to use it"
}

main() {
    echo "========================================"
    echo "Doctor Hot-Zone Shadow Advisory (wv-854b4a)"
    echo "========================================"

    setup_test_env; test_clean_passes
    setup_test_env; test_empty_shadow_warns
    setup_test_env; test_nonempty_shadow_warns
    setup_test_env; test_resolution_unchanged
    setup_test_env; test_help_lists_db

    echo ""
    echo "========================================"
    echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
    echo "========================================"

    [ "$TESTS_FAILED" -eq 0 ] || exit 1
    exit 0
}

main "$@"
