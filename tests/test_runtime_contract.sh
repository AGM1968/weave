#!/usr/bin/env bash
# test_runtime_contract.sh — CLI contract tests for runtime-consumed commands
#
# Validates that each of the 12 commands the weave-runtime consumes returns
# parseable JSON with the required fields, and exits 0 on success.
#
# Commands under test (read-side):
#   wv ready --json, wv list --json, wv show --json, wv context --json,
#   wv learnings --json, wv tree --json, wv health --json, wv status
# Mutators (Phase 0):
#   wv work --json, wv done --json, wv add --json, wv sync --json
#
# Exit codes:
#   0 - All tests passed
#   1 - One or more tests failed

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

TEST_DIR="/tmp/wv-contract-test-$$"
export WV_HOT_ZONE="$TEST_DIR"
export WV_DB="$TEST_DIR/brain.db"
export WV_REQUIRE_LEARNING=0
export WV_NO_WARN=1

cleanup() { rm -rf "$TEST_DIR" 2>/dev/null; }
trap cleanup EXIT

setup_test_env() {
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR"
    cd "$TEST_DIR"
    git init -q
    "$WV" init >/dev/null 2>&1
}

assert_json() {
    local output="$1"
    local message="$2"
    TESTS_RUN=$((TESTS_RUN + 1))
    if echo "$output" | jq '.' >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Not valid JSON: $output"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

assert_field() {
    local output="$1"
    local field="$2"
    local message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    local val
    val=$(echo "$output" | jq -r "$field" 2>/dev/null)
    if [ -n "$val" ] && [ "$val" != "null" ]; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Field $field missing or null in: $output"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
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

echo "========================================"
echo "Runtime CLI Contract Tests"
echo "========================================"

# -------------------------------------------------------------------------
# Setup: create test data
# -------------------------------------------------------------------------

setup_test_env

NODE_A=$("$WV" add "Alpha task" --status=todo 2>/dev/null)
NODE_B=$("$WV" add "Beta task" --status=todo 2>/dev/null)
NODE_C=$("$WV" add "Gamma epic" --status=active 2>/dev/null)

# -------------------------------------------------------------------------
# 1. wv add --json
# -------------------------------------------------------------------------

echo ""
echo "Test: wv add --json"
echo "==================="

OUT=$("$WV" add "New runtime task" --json 2>/dev/null)
assert_json "$OUT" "wv add --json returns valid JSON"
assert_field "$OUT" ".id" "wv add --json has .id field"
assert_field "$OUT" ".text" "wv add --json has .text field"
assert_field "$OUT" ".status" "wv add --json has .status field"
NEW_ID=$(echo "$OUT" | jq -r '.id')
assert_equals "todo" "$(echo "$OUT" | jq -r '.status')" "wv add --json status is todo"

# -------------------------------------------------------------------------
# 2. wv work --json
# -------------------------------------------------------------------------

echo ""
echo "Test: wv work --json"
echo "===================="

OUT=$("$WV" work "$NODE_A" --json 2>/dev/null)
assert_json "$OUT" "wv work --json returns valid JSON"
assert_field "$OUT" ".id" "wv work --json has .id field"
assert_field "$OUT" ".text" "wv work --json has .text field"
assert_field "$OUT" ".status" "wv work --json has .status field"
assert_equals "$NODE_A" "$(echo "$OUT" | jq -r '.id')" "wv work --json .id matches claimed node"
assert_equals "active" "$(echo "$OUT" | jq -r '.status')" "wv work --json status is active"

# -------------------------------------------------------------------------
# 3. wv done --json
# -------------------------------------------------------------------------

echo ""
echo "Test: wv done --json"
echo "===================="

OUT=$("$WV" done "$NODE_A" --skip-verification --json 2>/dev/null)
assert_json "$OUT" "wv done --json returns valid JSON"
assert_field "$OUT" ".id" "wv done --json has .id field"
assert_field "$OUT" ".text" "wv done --json has .text field"
assert_field "$OUT" ".status" "wv done --json has .status field"
assert_equals "$NODE_A" "$(echo "$OUT" | jq -r '.id')" "wv done --json .id matches closed node"
assert_equals "done" "$(echo "$OUT" | jq -r '.status')" "wv done --json status is done"

# -------------------------------------------------------------------------
# 4. wv ready --json
# -------------------------------------------------------------------------

echo ""
echo "Test: wv ready --json"
echo "====================="

OUT=$("$WV" ready --json 2>/dev/null)
assert_json "$OUT" "wv ready --json returns valid JSON"
assert_equals "array" "$(echo "$OUT" | jq -r 'type')" "wv ready --json is a JSON array"
# NODE_B should be in the ready list
assert_field "$(echo "$OUT" | jq --arg id "$NODE_B" '.[] | select(.id == $id)')" ".id" \
    "wv ready --json includes todo node"

# -------------------------------------------------------------------------
# 5. wv list --json
# -------------------------------------------------------------------------

echo ""
echo "Test: wv list --json"
echo "===================="

OUT=$("$WV" list --json 2>/dev/null)
assert_json "$OUT" "wv list --json returns valid JSON"
assert_equals "array" "$(echo "$OUT" | jq -r 'type')" "wv list --json is a JSON array"
# Should include active node NODE_C
assert_field "$(echo "$OUT" | jq --arg id "$NODE_C" '.[] | select(.id == $id)')" ".id" \
    "wv list --json includes active node"

# -------------------------------------------------------------------------
# 6. wv show --json
# -------------------------------------------------------------------------

echo ""
echo "Test: wv show --json"
echo "===================="

OUT=$("$WV" show "$NODE_B" --json 2>/dev/null)
assert_json "$OUT" "wv show --json returns valid JSON"
assert_field "$OUT" ".[0].id" "wv show --json has .id field"
assert_field "$OUT" ".[0].text" "wv show --json has .text field"
assert_field "$OUT" ".[0].status" "wv show --json has .status field"
assert_equals "$NODE_B" "$(echo "$OUT" | jq -r '.[0].id')" "wv show --json .id matches requested node"

# -------------------------------------------------------------------------
# 7. wv context --json
# -------------------------------------------------------------------------

echo ""
echo "Test: wv context --json"
echo "======================="

export WV_ACTIVE="$NODE_C"
OUT=$("$WV" context "$NODE_C" --json 2>/dev/null)
assert_json "$OUT" "wv context --json returns valid JSON"
assert_field "$OUT" ".node" "wv context --json has .node field"
assert_field "$OUT" ".node.id" "wv context --json .node has .id"
unset WV_ACTIVE

# -------------------------------------------------------------------------
# 8. wv sync --json
# -------------------------------------------------------------------------

echo ""
echo "Test: wv sync --json"
echo "===================="

OUT=$("$WV" sync --json 2>/dev/null)
assert_json "$OUT" "wv sync --json returns valid JSON"
assert_field "$OUT" ".ok" "wv sync --json has .ok field"
assert_field "$OUT" ".synced_to" "wv sync --json has .synced_to field"
assert_equals "true" "$(echo "$OUT" | jq -r '.ok')" "wv sync --json .ok is true"

# -------------------------------------------------------------------------
# 9. wv status (no --json, but parseable for runtime: check exit 0)
# -------------------------------------------------------------------------

echo ""
echo "Test: wv status"
echo "==============="

TESTS_RUN=$((TESTS_RUN + 1))
if "$WV" status >/dev/null 2>&1; then
    echo -e "${GREEN}✓${NC} wv status exits 0"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "${RED}✗${NC} wv status exits 0"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# -------------------------------------------------------------------------
# 10. wv health --json
# -------------------------------------------------------------------------

echo ""
echo "Test: wv health --json"
echo "======================"

OUT=$("$WV" health --json 2>/dev/null)
assert_json "$OUT" "wv health --json returns valid JSON"
assert_field "$OUT" ".score" "wv health --json has .score field"

# -------------------------------------------------------------------------
# 11. wv tree --json
# -------------------------------------------------------------------------

echo ""
echo "Test: wv tree --json"
echo "===================="

OUT=$("$WV" tree --json 2>/dev/null)
assert_json "$OUT" "wv tree --json returns valid JSON"
assert_equals "array" "$(echo "$OUT" | jq -r 'type')" "wv tree --json is a JSON array"

# -------------------------------------------------------------------------
# 12. wv learnings --json
# -------------------------------------------------------------------------

echo ""
echo "Test: wv learnings --json"
echo "========================="

# Add a learning to make the output non-empty
"$WV" done "$NEW_ID" --learning="decision: test" --json >/dev/null 2>&1 || true

OUT=$("$WV" learnings --json 2>/dev/null)
assert_json "$OUT" "wv learnings --json returns valid JSON"
assert_equals "array" "$(echo "$OUT" | jq -r 'type')" "wv learnings --json is a JSON array"

# -------------------------------------------------------------------------
# Results
# -------------------------------------------------------------------------

echo ""
echo "========================================"
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
echo "========================================"

if [ "$TESTS_FAILED" -eq 0 ]; then
    echo -e "${GREEN}All tests passed${NC}"
    exit 0
else
    echo -e "${RED}$TESTS_FAILED test(s) failed${NC}"
    exit 1
fi
