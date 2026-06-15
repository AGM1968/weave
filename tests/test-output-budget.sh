#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# test-output-budget.sh — Golden-budget regression net (output budget D5)
#
# Pins the default output of token-heavy commands on a fixture graph so
# unbounded-output regressions fail CI instead of landing in agent context.
# See docs/PROPOSAL-wv-output-budget.md. Weave-ID: wv-b6c6db
#
# Fixture: 6 epics x 30 tasks (186 tree nodes), 60 pitfalls (10 addressed).
# Ceilings are generous (~1.5x observed) — they pin the order of magnitude,
# not the exact rendering.
#
# Exit codes:
#   0 - All tests passed
#   1 - One or more tests failed

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$PROJECT_ROOT/scripts/wv"

TEST_DIR="/tmp/wv-output-budget-test-$$"
export WV_HOT_ZONE="$TEST_DIR"
export WV_DB="$TEST_DIR/brain.db"
export WV_REQUIRE_LEARNING=0
export WV_PROJECT_DIR="$TEST_DIR"
unset WV_TREE_CAP

# Byte ceilings for default (capped) output. If a default shape grows past
# these, that growth is a contract change — adjust deliberately, not silently.
TREE_BYTE_CEILING=12288
PITFALLS_BYTE_CEILING=12288

cleanup() {
    cd /tmp
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

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
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_le() {
    local actual="$1" ceiling="$2" message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$actual" -le "$ceiling" ]; then
        echo -e "${GREEN}✓${NC} $message ($actual <= $ceiling)"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Actual:  $actual"
        echo "  Ceiling: $ceiling"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

setup_fixture() {
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR"
    cd "$TEST_DIR"
    git init -q
    "$WV" init >/dev/null 2>&1

    # Seed directly: 186 nodes via wv add would dominate suite runtime.
    # priority/type are VIRTUAL generated columns — never in the INSERT list.
    sqlite3 "$WV_DB" <<'SQL'
INSERT INTO nodes (id, text, status, metadata)
WITH RECURSIVE e(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM e WHERE i < 6)
SELECT printf('wv-e%05d', i),
       printf('epic %d: output budget fixture epic with representative title length', i),
       'todo', '{"type":"epic"}'
FROM e;

INSERT INTO nodes (id, text, status, metadata)
WITH RECURSIVE t(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM t WHERE i < 180)
SELECT printf('wv-a%05d', i),
       printf('task %d: fixture task with representative node text length for the budget', i),
       'todo',
       CASE WHEN i <= 60
            THEN json_object('type', 'task', 'pitfall',
                 printf('pitfall %d: fixture pitfall text long enough to be representative', i))
            ELSE '{"type":"task"}'
       END
FROM t;

INSERT INTO edges (source, target, type)
WITH RECURSIVE t(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM t WHERE i < 180)
SELECT printf('wv-a%05d', i), printf('wv-e%05d', ((i - 1) % 6) + 1), 'implements'
FROM t;

-- First 10 pitfalls get an incoming 'addresses' edge -> addressed.
INSERT INTO edges (source, target, type)
WITH RECURSIVE t(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM t WHERE i < 10)
SELECT printf('wv-e%05d', ((i - 1) % 6) + 1), printf('wv-a%05d', i), 'addresses'
FROM t;
SQL
}

count_tree_node_lines() {
    # Node lines carry a type label; '+N more' markers and summary do not.
    echo "$1" | grep -cE 'Epic:|Task:' || true
}

echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
echo "  Output budget golden tests (tree / audit-pitfalls)"
echo "═══════════════════════════════════════════════════════════════════════════"

setup_fixture

node_count=$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM nodes;")
assert_equals "186" "$node_count" "fixture seeded (186 nodes)"

# ── wv tree ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}wv tree${NC}"

tree_default=$("$WV" tree)
assert_contains "$tree_default" "Showing 50 of 186 nodes" "default tree prints truncation summary"
assert_equals "50" "$(count_tree_node_lines "$tree_default")" "default tree renders exactly 50 nodes"
assert_contains "$tree_default" "more not shown" "default tree marks cut subtrees (+N more)"
assert_le "$(printf '%s' "$tree_default" | wc -c)" "$TREE_BYTE_CEILING" "default tree stays under byte ceiling"

tree_all=$("$WV" tree --all)
assert_not_contains "$tree_all" "Showing" "--all lifts the cap (no truncation line)"
assert_equals "186" "$(count_tree_node_lines "$tree_all")" "--all renders all 186 nodes"

tree_env=$(WV_TREE_CAP=10 "$WV" tree)
assert_contains "$tree_env" "Showing 10 of 186 nodes" "WV_TREE_CAP env knob honored"

tree_json=$("$WV" tree --json 2>/dev/null)
assert_equals "50" "$(echo "$tree_json" | jq 'length')" "--json capped at 50 elements"
tree_json_stderr=$("$WV" tree --json 2>&1 >/dev/null)
assert_contains "$tree_json_stderr" "showing 50 of 186" "--json reports truncation on stderr"
assert_equals "186" "$("$WV" tree --json --all 2>/dev/null | jq 'length')" "--json --all returns full set"

tree_mermaid=$("$WV" tree --mermaid)
assert_contains "$tree_mermaid" "%% showing 50 of 186 nodes" "--mermaid caps nodes with comment marker"

tree_subtree=$("$WV" tree wv-e00001)
assert_not_contains "$tree_subtree" "Showing" "31-node subtree renders uncapped"
assert_equals "31" "$(count_tree_node_lines "$tree_subtree")" "subtree renders root + 30 children"

# ── wv audit-pitfalls ───────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}wv audit-pitfalls${NC}"

ap_default=$("$WV" audit-pitfalls)
assert_contains "$ap_default" "Showing 20 of 50 matching" "default prints truncation summary"
assert_not_contains "$ap_default" "[ADDRESSED]" "default hides addressed pitfalls"
assert_equals "20" "$(echo "$ap_default" | grep -c '\[UNADDRESSED\]' || true)" "default renders exactly 20 entries"
assert_contains "$ap_default" "Total pitfalls: 60" "summary still reports full totals"
assert_le "$(printf '%s' "$ap_default" | wc -c)" "$PITFALLS_BYTE_CEILING" "default output stays under byte ceiling"

ap_json=$("$WV" audit-pitfalls --json 2>/dev/null)
assert_equals "20" "$(echo "$ap_json" | jq 'length')" "--json capped at 20 entries"
assert_equals "0" "$(echo "$ap_json" | jq '[.[] | select(.addressed)] | length')" "--json default excludes addressed"

assert_equals "60" "$("$WV" audit-pitfalls --all --json 2>/dev/null | jq 'length')" "--all returns every pitfall"
assert_equals "5" "$("$WV" audit-pitfalls --top=5 --json 2>/dev/null | jq 'length')" "--top=N honored"
assert_equals "10" "$("$WV" audit-pitfalls --only-addressed --json 2>/dev/null | jq 'length')" "--only-addressed returns addressed set"

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
if [ "$TESTS_FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
