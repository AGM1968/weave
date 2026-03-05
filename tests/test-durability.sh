#!/usr/bin/env bash
# test-durability.sh — Test durable execution patterns
#
# Tests: journal-wrapped ship/sync/delete, crash simulation at each step,
#        journal recovery, ship_pending metadata fallback, wv recover,
#        auto_sync suppression via _WV_IN_JOURNAL guard
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
TEST_DIR="/tmp/wv-durability-test-$$"
export WV_HOT_ZONE="$TEST_DIR"
export WV_DB="$TEST_DIR/brain.db"
export WV_AUTO_SYNC=0  # Disable auto-sync in tests
export WV_AUTO_CHECKPOINT=0  # Disable auto-checkpoint in tests

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
    mkdir -p .weave
    # Initialize the database
    "$WV" init 2>/dev/null || true
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
        echo "  In: $(echo "$haystack" | head -3)"
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

echo -e "${CYAN}═══ Durability Tests ═══${NC}"
echo ""

# ─── Journal wrapping in cmd_sync ───────────────────────────────────────

echo -e "${CYAN}--- cmd_sync journal wrapping ---${NC}"
setup_test_env

# Create a node to have something in the DB
"$WV" add "test node for sync" >/dev/null 2>&1

# Run sync (should create + complete journal op)
"$WV" sync 2>/dev/null

# Journal should be clean after successful sync
journal_file="$WV_HOT_ZONE/ops.journal"
if [ -f "$journal_file" ] && [ -s "$journal_file" ]; then
    # File exists but should be empty (cleaned after complete op)
    local_size=$(wc -c < "$journal_file")
    assert_equals "0" "$local_size" "Journal clean after successful sync"
else
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -e "${GREEN}✓${NC} Journal clean after successful sync (no file)"
    TESTS_PASSED=$((TESTS_PASSED + 1))
fi

# ─── Journal wrapping in cmd_delete ─────────────────────────────────────

echo ""
echo -e "${CYAN}--- cmd_delete journal wrapping ---${NC}"
setup_test_env

node_id=$("$WV" add "node to delete" 2>/dev/null | grep -oP 'wv-[a-f0-9]+')
"$WV" delete "$node_id" --force 2>/dev/null

# Verify node is gone
node_check=$("$WV" show "$node_id" 2>&1 || true)
assert_contains "$node_check" "not found" "Node deleted successfully"

# ─── Simulated crash during ship (journal recovery) ────────────────────

echo ""
echo -e "${CYAN}--- Simulated crash during ship ---${NC}"
setup_test_env

# Source libs for direct journal manipulation
source "$PROJECT_ROOT/scripts/lib/wv-config.sh"
source "$PROJECT_ROOT/scripts/lib/wv-journal.sh"

# Create and claim a node
node_id=$("$WV" add "ship crash test" 2>/dev/null | grep -oP 'wv-[a-f0-9]+')
"$WV" work "$node_id" >/dev/null 2>&1

# Simulate: ship started, done completed, sync pending (crash)
journal_begin "ship" "{\"id\":\"$node_id\",\"gh\":false}"
journal_step 1 "done"
# Actually do the done
"$WV" done "$node_id" >/dev/null 2>&1
journal_complete 1
journal_step 2 "sync"
# CRASH HERE — sync never completed

# Verify journal detects incomplete op
recovery=$("$WV" recover --json 2>/dev/null)
assert_contains "$recovery" '"status":"incomplete"' "recover detects incomplete ship"
assert_contains "$recovery" '"op":"ship"' "recover identifies ship operation"
assert_contains "$recovery" '"action":"sync"' "recover identifies stuck at sync"

# ─── ship_pending metadata marker ──────────────────────────────────────

echo ""
echo -e "${CYAN}--- ship_pending metadata fallback ---${NC}"
setup_test_env

node_id=$("$WV" add "pending test" 2>/dev/null | grep -oP 'wv-[a-f0-9]+')
"$WV" work "$node_id" >/dev/null 2>&1

# Manually set ship_pending (simulating cmd_ship start before crash)
sqlite3 "$WV_DB" "UPDATE nodes SET metadata = json_set(COALESCE(metadata,'{}'), '\$.ship_pending', json('true')) WHERE id = '$node_id';"

# Verify the marker is set
pending=$(sqlite3 "$WV_DB" "SELECT json_extract(metadata, '\$.ship_pending') FROM nodes WHERE id='$node_id';")
assert_equals "1" "$pending" "ship_pending marker set in metadata"

# Simulate reboot: clear journal (tmpfs gone), but metadata survives
rm -f "$WV_HOT_ZONE/ops.journal"

# wv recover should find the pending node via metadata fallback
recovery=$("$WV" recover --json 2>/dev/null)
assert_contains "$recovery" '"ship_pending"' "recover finds ship_pending via metadata"

# ─── _WV_IN_JOURNAL guard on auto_sync ─────────────────────────────────

echo ""
echo -e "${CYAN}--- _WV_IN_JOURNAL auto_sync guard ---${NC}"
setup_test_env

source "$PROJECT_ROOT/scripts/lib/wv-config.sh"
source "$PROJECT_ROOT/scripts/lib/wv-journal.sh"

# Set the guard
export _WV_IN_JOURNAL=1
export WV_AUTO_SYNC=1  # Enable for this test

# Source the data module to get auto_sync
source "$PROJECT_ROOT/scripts/cmd/wv-cmd-data.sh"

# auto_sync should be a no-op when _WV_IN_JOURNAL is set
# (We can't easily test this without side effects, but verify the guard works)
# Just verify auto_sync returns 0 without doing anything
stamp_before=""
[ -f "$WV_HOT_ZONE/.last_sync" ] && stamp_before=$(cat "$WV_HOT_ZONE/.last_sync")
auto_sync 2>/dev/null || true
stamp_after=""
[ -f "$WV_HOT_ZONE/.last_sync" ] && stamp_after=$(cat "$WV_HOT_ZONE/.last_sync")

assert_equals "$stamp_before" "$stamp_after" "auto_sync skipped during journal op"

unset _WV_IN_JOURNAL
export WV_AUTO_SYNC=0

# ─── wv recover on clean state ─────────────────────────────────────────

echo ""
echo -e "${CYAN}--- wv recover clean state ---${NC}"
setup_test_env

result=$("$WV" recover --json 2>/dev/null)
assert_contains "$result" '"clean"' "recover reports clean on fresh state"

# ─── wv doctor journal check ───────────────────────────────────────────

echo ""
echo -e "${CYAN}--- wv doctor journal check ---${NC}"
setup_test_env

doctor_out=$("$WV" doctor 2>&1)
assert_contains "$doctor_out" "journal" "doctor checks journal health"
assert_contains "$doctor_out" "clean" "doctor reports clean journal"

# Create incomplete journal entry
source "$PROJECT_ROOT/scripts/lib/wv-config.sh"
source "$PROJECT_ROOT/scripts/lib/wv-journal.sh"
journal_begin "sync" '{}'
journal_step 1 "dump"
# No complete, no end

doctor_out=$("$WV" doctor 2>&1)
assert_contains "$doctor_out" "incomplete" "doctor detects incomplete journal op"
assert_contains "$doctor_out" "recover" "doctor suggests wv recover"

# ─── Scan single-transaction atomicity ──────────────────────────────────

echo ""
echo -e "${CYAN}--- Scan single-transaction ---${NC}"

# This is tested via the existing pytest suite (249 tests).
# Verify db.py has no conn.commit() in upsert functions:
commit_count=$(grep -c 'conn\.commit()' "$PROJECT_ROOT/scripts/weave_quality/db.py" 2>/dev/null || echo 0)
assert_equals "1" "$commit_count" "db.py has exactly 1 conn.commit() (in _migrate_v2 schema only)"

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
