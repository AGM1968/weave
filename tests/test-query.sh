#!/usr/bin/env bash
# test-query.sh — Tests for wv query command
#
# Tests: predicate parsing, HAS (dual-schema), MATCH FTS, IN, stale,
#        --format, --include, --order, --limit, error handling
#
# Exit codes:
#   0 - All tests passed
#   1 - One or more tests failed

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

TEST_DIR="/tmp/wv-query-test-$$"
export WV_HOT_ZONE="$TEST_DIR"
export WV_DB="$TEST_DIR/brain.db"

cleanup() {
    cd /tmp
    [ -d "$TEST_DIR" ] && rm -rf "$TEST_DIR"
}
trap cleanup EXIT

setup_test_env() {
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR/.weave"
    cd "$TEST_DIR"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    "$WV" init 2>/dev/null
}

strip_ansi() {
    sed 's/\x1b\[[0-9;]*m//g'
}

assert_contains() {
    local haystack="$1" needle="$2" message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if echo "$haystack" | strip_ansi | grep -qF "$needle"; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Expected to find: $needle"
        echo "  In: $(echo "$haystack" | strip_ansi | head -5)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if ! echo "$haystack" | strip_ansi | grep -qF "$needle"; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Did not expect to find: $needle"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

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

assert_exit_ok() {
    local cmd="$1" message="$2"
    TESTS_RUN=$((TESTS_RUN + 1))
    if eval "$cmd" >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $message"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_exit_fail() {
    local cmd="$1" message="$2"
    TESTS_RUN=$((TESTS_RUN + 1))
    if ! eval "$cmd" >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $message"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# ---------------------------------------------------------------------------
# Setup: populate test DB with known nodes
# ---------------------------------------------------------------------------

populate_nodes() {
    # active task (--force bypasses claim-ready hook in test env)
    TASK_ID=$("$WV" add "wq-test: active task node" --status=active --force 2>/dev/null | head -1)

    # done node with learning (new schema)
    DONE_ID=$("$WV" add "wq-test: done node with decision learning" --status=done \
        --metadata='{"learning":"decision: use phrase-quote for FTS5 | pitfall: subshell loses state"}' \
        2>/dev/null | head -1)

    # done node with dual-schema learning fields
    DUAL_ID=$("$WV" add "wq-test: dual-schema learning node" --status=done \
        --metadata='{"decision":"prefer indexes over full scans","pattern":"always EXPLAIN QUERY PLAN"}' \
        2>/dev/null | head -1)

    # finding node (--force bypasses active-node check)
    FIND_ID=$("$WV" add "wq-test: finding about sqlite busy timeout" --status=active \
        --metadata='{"type":"finding","finding":{"fixable":1,"confidence":"high","violation_type":"perf"}}' \
        --force 2>/dev/null | head -1)

    # node with metadata field
    META_ID=$("$WV" add "wq-test: node with custom priority" --status=todo \
        --metadata='{"priority":"high"}' \
        2>/dev/null | head -1)

    export TASK_ID DONE_ID DUAL_ID FIND_ID META_ID
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

echo ""
echo -e "${YELLOW}=== wv query: basic predicates ===${NC}"

setup_test_env
populate_nodes

out=$("$WV" query status=active 2>&1)
assert_contains "$out" "wq-test: active task node" "status=active returns active node"
assert_not_contains "$out" "wq-test: done node" "status=active excludes done node"

out=$("$WV" query status=done 2>&1)
assert_contains "$out" "wq-test: done node" "status=done returns done nodes"
assert_not_contains "$out" "wq-test: active task" "status=done excludes active"

out=$("$WV" query status!=active 2>&1)
assert_not_contains "$out" "wq-test: active task" "status!=active excludes active"

echo ""
echo -e "${YELLOW}=== wv query: HAS predicate ===${NC}"

out=$("$WV" query "HAS learning" 2>&1)
assert_contains "$out" "wq-test: done node with decision learning" "HAS learning matches learning field"

out=$("$WV" query "HAS decision" 2>&1)
assert_contains "$out" "wq-test: dual-schema learning node" "HAS decision matches dual-schema node"

out=$("$WV" query "HAS learning" 2>&1)
assert_contains "$out" "wq-test: dual-schema learning node" "HAS learning is dual-schema aware (decision field counts)"

out=$("$WV" query "HAS priority" 2>&1)
assert_contains "$out" "wq-test: node with custom priority" "HAS priority matches metadata field"
assert_not_contains "$out" "wq-test: active task" "HAS priority excludes nodes without it"

echo ""
echo -e "${YELLOW}=== wv query: MATCH FTS ===${NC}"

out=$("$WV" query "MATCH sqlite" 2>&1)
assert_contains "$out" "wq-test: finding about sqlite busy timeout" "MATCH sqlite finds sqlite node"

out=$("$WV" query "MATCH phrase-quote" 2>&1)
assert_contains "$out" "wq-test: done node with decision learning" "MATCH phrase-quote finds learning node"

out=$("$WV" query "MATCH nonexistent_xyz_term_abc" 2>&1)
assert_contains "$out" "No results" "MATCH nonexistent term returns no results"

echo ""
echo -e "${YELLOW}=== wv query: MATCH dual-FTS learning recall ===${NC}"

# A node whose match phrase appears only in learning/decision, not in the text field.
# nodes_fts indexes metadata so both tables cover the same phrases — this test verifies
# that learning-content nodes are returned and not silently dropped.
LEARNING_ONLY_ID=$("$WV" add "wq-test: node with generic title" --status=done \
    --metadata='{"decision":"prefer unique sentinel phrase zxqvfoo for testing","pattern":"sentinel only in learning"}' \
    2>/dev/null | head -1)
export LEARNING_ONLY_ID

out=$("$WV" query "MATCH zxqvfoo" 2>&1)
assert_contains "$out" "wq-test: node with generic title" "MATCH phrase-in-learning-only returns the node"

out=$("$WV" query "MATCH unique sentinel phrase" 2>&1)
assert_contains "$out" "wq-test: node with generic title" "MATCH multi-word phrase-in-learning returns the node"

echo ""
echo -e "${YELLOW}=== wv query: IN predicate ===${NC}"

out=$("$WV" query "status IN (active,todo)" 2>&1)
assert_contains "$out" "wq-test: active task node" "status IN active,todo returns active"
assert_contains "$out" "wq-test: node with custom priority" "status IN active,todo returns todo"
assert_not_contains "$out" "wq-test: done node" "status IN active,todo excludes done"

echo ""
echo -e "${YELLOW}=== wv query: --format ===${NC}"

out=$("$WV" query status=active --format=short 2>&1)
# short format: ids only — no colon+text
assert_not_contains "$out" "wq-test:" "short format omits text"
assert_contains "$out" "wv-" "short format contains id prefix"

out=$("$WV" query status=active --format=json 2>&1)
assert_contains "$out" '"id"' "json format contains id key"
assert_contains "$out" '"status"' "json format contains status key"

echo ""
echo -e "${YELLOW}=== wv query: --include ===${NC}"

out=$("$WV" query "HAS learning" --include=learning 2>&1)
assert_contains "$out" "Decision:" "include=learning renders Decision label"

out=$("$WV" query "HAS decision" --include=learning 2>&1)
assert_contains "$out" "Decision:" "include=learning renders dual-schema decision"

out=$("$WV" query status=active --include=hygiene 2>&1)
assert_contains "$out" "hygiene=" "include=hygiene renders hygiene field"

echo ""
echo -e "${YELLOW}=== wv query: --limit ===${NC}"

# add 5 more nodes to ensure limit works
for i in 1 2 3 4 5; do
    "$WV" add "wq-test: limit-test node $i" --status=todo 2>/dev/null
done

out=$("$WV" query status=todo --limit=2 --format=short 2>&1)
count=$(echo "$out" | grep -c "wv-" || true)
assert_equals "2" "$count" "--limit=2 returns exactly 2 results"

# limit=0 means unbounded
out=$("$WV" query status=todo --limit=0 --format=short 2>&1)
count=$(echo "$out" | grep -c "wv-" || true)
[ "$count" -gt 2 ] && {
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}✓${NC} --limit=0 returns more than 2 results (unbounded)"
} || {
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}✗${NC} --limit=0 should be unbounded, got $count"
}

echo ""
echo -e "${YELLOW}=== wv query: --order ===${NC}"

out=$("$WV" query status=done --order=oldest --limit=1 --format=short 2>&1)
assert_contains "$out" "wv-" "--order=oldest returns a result"

out=$("$WV" query "MATCH sqlite" --order=relevance --format=short 2>&1)
assert_contains "$out" "wv-" "--order=relevance with MATCH returns result"

echo ""
echo -e "${YELLOW}=== wv query: error handling ===${NC}"

out=$("$WV" query --unknown-flag 2>&1 || true)
assert_contains "$out" "Error" "unknown flag reports error"

out=$("$WV" query "bad predicate without op" 2>&1 || true)
assert_contains "$out" "Error" "unparseable predicate reports error"

echo ""
echo -e "${YELLOW}=== wv query: --help ===${NC}"

out=$("$WV" query --help 2>&1)
assert_contains "$out" "Predicates:" "--help shows Predicates section"
assert_contains "$out" "MATCH" "--help mentions MATCH"
assert_contains "$out" "HAS" "--help mentions HAS"
assert_contains "$out" "Examples:" "--help shows examples"

echo ""
echo -e "${YELLOW}=== wv help lists query ===${NC}"

out=$("$WV" help 2>&1)
assert_contains "$out" "query" "wv help lists query command"

out=$("$WV" help query 2>&1)
assert_contains "$out" "Predicates:" "wv help query delegates to --help"

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------

echo ""
echo -e "${YELLOW}=== Results ===${NC}"
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
echo -e "Tests: $TESTS_RUN | Passed: ${GREEN}$TESTS_PASSED${NC} | Failed: ${RED}$TESTS_FAILED${NC}"

if [ "$TESTS_FAILED" -eq 0 ]; then
    echo -e "${GREEN}ALL TESTS PASSED${NC}"
    exit 0
else
    echo -e "${RED}$TESTS_FAILED TESTS FAILED${NC}"
    exit 1
fi
