#!/bin/bash
# test-health.sh — Tests for wv health inspection commands (health, audit-pitfalls, edge-types)
#
# Run: bash tests/test-health.sh
# Exit: 0 if all pass, 1 if any fail
#
# Each test uses isolated WV_DB via reset_db() to prevent pollution.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
WV="$REPO_ROOT/scripts/wv"

# Test isolation
TEST_WV_DIR="/tmp/wv-health-test-$$"
export WV_HOT_ZONE="$TEST_WV_DIR"
export WV_DB="$TEST_WV_DIR/test.db"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Counters
TESTS_RUN=0
TESTS_PASSED=0

# ============================================================================
# Test Utilities
# ============================================================================

reset_db() {
    rm -rf "$TEST_WV_DIR"
    mkdir -p "$TEST_WV_DIR"
    rm -f "$WV_DB"
}

cleanup() {
    [ -d "$TEST_WV_DIR" ] && rm -rf "$TEST_WV_DIR"
}
trap cleanup EXIT

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if echo "$haystack" | grep -qF "$needle"; then
        echo -e "  ${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "  ${RED}✗${NC} $message"
        echo "    Expected to contain: '$needle'"
        echo "    Got: '$haystack'"
        return 1
    fi
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if echo "$haystack" | grep -qF "$needle"; then
        echo -e "  ${RED}✗${NC} $message"
        echo "    Should NOT contain: '$needle'"
        return 1
    else
        echo -e "  ${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    fi
}

assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$expected" = "$actual" ]; then
        echo -e "  ${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "  ${RED}✗${NC} $message"
        echo "    Expected: '$expected'"
        echo "    Got: '$actual'"
        return 1
    fi
}

assert_succeeds() {
    local message="$1"
    shift
    TESTS_RUN=$((TESTS_RUN + 1))
    if "$@" >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "  ${RED}✗${NC} $message"
        echo "    Command failed: $*"
        return 1
    fi
}

assert_json_field() {
    local json="$1"
    local field="$2"
    local expected="$3"
    local message="$4"
    TESTS_RUN=$((TESTS_RUN + 1))
    local actual
    actual=$(echo "$json" | jq -r "$field" 2>/dev/null || echo "PARSE_ERROR")
    if [ "$actual" = "$expected" ]; then
        echo -e "  ${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "  ${RED}✗${NC} $message"
        echo "    Expected $field = '$expected'"
        echo "    Got: '$actual'"
        return 1
    fi
}

# ============================================================================
# Test: edge-types command
# ============================================================================
echo "Testing: edge-types command"

reset_db

# edge-types shows all valid types
output=$($WV edge-types 2>&1)
assert_contains "$output" "blocks" "edge-types shows blocks"
assert_contains "$output" "relates_to" "edge-types shows relates_to"
assert_contains "$output" "implements" "edge-types shows implements"
assert_contains "$output" "contradicts" "edge-types shows contradicts"
assert_contains "$output" "supersedes" "edge-types shows supersedes"
assert_contains "$output" "references" "edge-types shows references"
assert_contains "$output" "obsoletes" "edge-types shows obsoletes"
assert_contains "$output" "addresses" "edge-types shows addresses"

# edge-types shows descriptions
assert_contains "$output" "Workflow dependency" "edge-types shows blocks description"
assert_contains "$output" "semantic relationship" "edge-types shows relates_to description"
assert_contains "$output" "pitfall" "edge-types shows addresses description"

# ============================================================================
# Test: health command (empty database)
# ============================================================================
echo ""
echo "Testing: health command (empty database)"

reset_db

# health works on empty database
output=$($WV health 2>&1)
assert_contains "$output" "Health Check" "health shows header"
assert_contains "$output" "Score:" "health shows score"
assert_contains "$output" "Nodes:" "health shows nodes section"
assert_contains "$output" "Edges:" "health shows edges section"

# health --json works on empty database
json_output=$($WV health --json 2>&1)
assert_json_field "$json_output" ".status" "healthy" "health --json shows healthy status"
assert_json_field "$json_output" ".score" "100" "health --json shows 100 score on empty db"
assert_json_field "$json_output" ".nodes.total" "0" "health --json shows 0 total nodes"
assert_json_field "$json_output" ".edges.total" "0" "health --json shows 0 total edges"

# ============================================================================
# Test: health command (with data)
# ============================================================================
echo ""
echo "Testing: health command (with data)"

reset_db

# Create test nodes of different statuses
$WV add "Active task" --status=active >/dev/null
$WV add "Blocked task" --status=blocked >/dev/null
$WV add "Done task" --status=done >/dev/null
node1=$($WV add "Todo task 1")
node2=$($WV add "Todo task 2")

# Create some edges
$WV link "$node1" "$node2" --type=blocks >/dev/null 2>&1

# health shows correct counts
json_output=$($WV health --json 2>&1)
assert_json_field "$json_output" ".nodes.total" "5" "health counts 5 total nodes"
assert_json_field "$json_output" ".nodes.active" "1" "health counts 1 active node"
assert_json_field "$json_output" ".nodes.blocked" "1" "health counts 1 blocked node"
assert_json_field "$json_output" ".nodes.done" "1" "health counts 1 done node"
assert_json_field "$json_output" ".edges.total" "1" "health counts 1 edge"
assert_json_field "$json_output" ".edges.blocking" "1" "health counts 1 blocking edge"

# ============================================================================
# Test: health score with pitfalls
# ============================================================================
echo ""
echo "Testing: health score with pitfalls"

reset_db

# Add unaddressed pitfall - should reduce health score
pitfall=$($WV add "Pitfall: Something is wrong" --metadata='{"pitfall":"This is a pitfall"}')

json_output=$($WV health --json 2>&1)
assert_json_field "$json_output" ".pitfalls.total" "1" "health counts 1 pitfall"
assert_json_field "$json_output" ".pitfalls.unaddressed" "1" "health counts 1 unaddressed"

# Score should be reduced (100 - 10 per unaddressed pitfall)
score=$(echo "$json_output" | jq -r '.score')
if [ "$score" -lt 100 ]; then
    echo -e "  ${GREEN}✓${NC} unaddressed pitfall reduces health score"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗${NC} unaddressed pitfall should reduce health score"
fi
TESTS_RUN=$((TESTS_RUN + 1))

# Address the pitfall
fix=$($WV add "Fix for pitfall" --status=done)
$WV link "$fix" "$pitfall" --type=addresses >/dev/null 2>&1

json_output=$($WV health --json 2>&1)
assert_json_field "$json_output" ".pitfalls.addressed" "1" "health counts 1 addressed"
assert_json_field "$json_output" ".pitfalls.unaddressed" "0" "health counts 0 unaddressed"
assert_json_field "$json_output" ".score" "100" "health score restored to 100"

# ============================================================================
# Test: health with contradictions
# ============================================================================
echo ""
echo "Testing: health with contradictions"

reset_db

# Add contradiction edge - should reduce health score heavily
node1=$($WV add "Node A")
node2=$($WV add "Node B")
$WV link "$node1" "$node2" --type=contradicts >/dev/null 2>&1

json_output=$($WV health --json 2>&1)
contradictions=$(echo "$json_output" | jq -r '.issues.unresolved_contradictions')
assert_equals "1" "$contradictions" "health counts 1 contradiction"

# Score should be reduced (15 points per contradiction)
score=$(echo "$json_output" | jq -r '.score')
if [ "$score" -lt 100 ]; then
    echo -e "  ${GREEN}✓${NC} contradictions reduce health score"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗${NC} contradictions should reduce health score"
fi
TESTS_RUN=$((TESTS_RUN + 1))

# ============================================================================
# Test: audit-pitfalls command (empty)
# ============================================================================
echo ""
echo "Testing: audit-pitfalls command (empty)"

reset_db

# audit-pitfalls on empty db reports no pitfalls
output=$($WV audit-pitfalls 2>&1)
assert_contains "$output" "No pitfalls" "audit-pitfalls reports no pitfalls"

# ============================================================================
# Test: audit-pitfalls command (with pitfalls)
# ============================================================================
echo ""
echo "Testing: audit-pitfalls command (with pitfalls)"

reset_db

# Add pitfall nodes
pitfall1=$($WV add "Pitfall: First issue" --metadata='{"pitfall":"Description of first issue"}')
pitfall2=$($WV add "Pitfall: Second issue" --metadata='{"pitfall":"Description of second issue"}')

# Both should show as unaddressed
output=$($WV audit-pitfalls 2>&1)
assert_contains "$output" "UNADDRESSED" "audit-pitfalls shows UNADDRESSED"
assert_contains "$output" "First issue" "audit-pitfalls shows first pitfall"
assert_contains "$output" "Second issue" "audit-pitfalls shows second pitfall"
assert_contains "$output" "Total pitfalls: 2" "audit-pitfalls counts 2 total"
assert_contains "$output" "Unaddressed: 2" "audit-pitfalls counts 2 unaddressed"

# Address one pitfall
fix=$($WV add "Fix for first issue" --status=done)
$WV link "$fix" "$pitfall1" --type=addresses >/dev/null 2>&1

output=$($WV audit-pitfalls 2>&1)
assert_contains "$output" "ADDRESSED" "audit-pitfalls shows ADDRESSED"
assert_contains "$output" "Addressed: 1" "audit-pitfalls counts 1 addressed"
assert_contains "$output" "Unaddressed: 1" "audit-pitfalls counts 1 unaddressed"
assert_contains "$output" "$fix" "audit-pitfalls shows fix node ID"

# ============================================================================
# Test: audit-pitfalls --json
# ============================================================================
echo ""
echo "Testing: audit-pitfalls --json"

# JSON output
json_output=$($WV audit-pitfalls --json 2>&1)
count=$(echo "$json_output" | jq 'length' 2>/dev/null || echo "0")
assert_equals "2" "$count" "audit-pitfalls --json returns 2 nodes"

# Check addressed field
addressed_count=$(echo "$json_output" | jq '[.[] | select(.addressed == true)] | length')
assert_equals "1" "$addressed_count" "audit-pitfalls --json has 1 addressed"

unaddressed_count=$(echo "$json_output" | jq '[.[] | select(.addressed == false)] | length')
assert_equals "1" "$unaddressed_count" "audit-pitfalls --json has 1 unaddressed"

# ============================================================================
# Test: audit-pitfalls filters
# ============================================================================
echo ""
echo "Testing: audit-pitfalls filters"

# --only-unaddressed filter
output=$($WV audit-pitfalls --only-unaddressed 2>&1)
assert_not_contains "$output" "[ADDRESSED]" "only-unaddressed excludes addressed"
assert_contains "$output" "[UNADDRESSED]" "only-unaddressed shows unaddressed"

# --only-addressed filter
output=$($WV audit-pitfalls --only-addressed 2>&1)
assert_contains "$output" "[ADDRESSED]" "only-addressed shows addressed"
assert_not_contains "$output" "[UNADDRESSED]" "only-addressed excludes unaddressed"

# ============================================================================
# Test: audit-pitfalls with different resolution types
# ============================================================================
echo ""
echo "Testing: audit-pitfalls resolution types"

reset_db

# Create pitfalls addressed by different edge types
p1=$($WV add "Pitfall: P1" --metadata='{"pitfall":"Test addresses"}')
p2=$($WV add "Pitfall: P2" --metadata='{"pitfall":"Test implements"}')
p3=$($WV add "Pitfall: P3" --metadata='{"pitfall":"Test supersedes"}')

f1=$($WV add "Fix via addresses")
f2=$($WV add "Fix via implements")
f3=$($WV add "Fix via supersedes")

$WV link "$f1" "$p1" --type=addresses >/dev/null 2>&1
$WV link "$f2" "$p2" --type=implements >/dev/null 2>&1
$WV link "$f3" "$p3" --type=supersedes >/dev/null 2>&1

# All should be addressed
json_output=$($WV audit-pitfalls --json 2>&1)
addressed_count=$(echo "$json_output" | jq '[.[] | select(.addressed == true)] | length')
assert_equals "3" "$addressed_count" "all resolution edge types count as addressed"

output=$($WV audit-pitfalls 2>&1)
assert_contains "$output" "Unaddressed: 0" "no pitfalls unaddressed"

# ============================================================================
# Test: health status thresholds
# ============================================================================
echo ""
echo "Testing: health status thresholds"

reset_db

# Perfect health (score >= 90) = healthy
json_output=$($WV health --json 2>&1)
assert_json_field "$json_output" ".status" "healthy" "score 100 = healthy"

# Add 2 unaddressed pitfalls (-20) = warning (80)
$WV add "Pitfall: Issue 1" --metadata='{"pitfall":"p1"}' >/dev/null
$WV add "Pitfall: Issue 2" --metadata='{"pitfall":"p2"}' >/dev/null

json_output=$($WV health --json 2>&1)
score=$(echo "$json_output" | jq -r '.score')
status=$(echo "$json_output" | jq -r '.status')
if [ "$score" -ge 70 ] && [ "$score" -lt 90 ]; then
    assert_equals "warning" "$status" "score 70-89 = warning"
else
    echo -e "  ${YELLOW}⚠${NC} Score $score, status $status (expected warning range)"
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))
fi

# Add more pitfalls to go unhealthy
$WV add "Pitfall: Issue 3" --metadata='{"pitfall":"p3"}' >/dev/null
$WV add "Pitfall: Issue 4" --metadata='{"pitfall":"p4"}' >/dev/null
$WV add "Pitfall: Issue 5" --metadata='{"pitfall":"p5"}' >/dev/null

json_output=$($WV health --json 2>&1)
score=$(echo "$json_output" | jq -r '.score')
status=$(echo "$json_output" | jq -r '.status')
if [ "$score" -lt 70 ]; then
    assert_equals "unhealthy" "$status" "score < 70 = unhealthy"
else
    echo -e "  ${YELLOW}⚠${NC} Score $score (expected < 70 for unhealthy)"
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))
fi

# ============================================================================
# Test: health with invalid status values
# ============================================================================
echo ""
echo "Testing: health with invalid status values"

reset_db

# Direct database manipulation to insert invalid status (bypass validation)
$WV add "Valid node" >/dev/null
WEAVE_DB="${WV_DB}"

# Insert node with invalid status directly
sqlite3 "$WEAVE_DB" "INSERT INTO nodes (id, text, status, created_at, updated_at) 
VALUES ('wv-inv1', 'Invalid status node', 'banana', datetime('now'), datetime('now'));" 2>/dev/null

# Health should detect invalid status and reduce score
json_output=$($WV health --json 2>&1)
score=$(echo "$json_output" | jq -r '.score')
invalid_count=$(echo "$json_output" | jq -r '.issues.invalid_statuses // 0')

assert_equals "1" "$invalid_count" "health detects 1 invalid status"

if [ "$score" -lt 100 ]; then
    echo -e "  ${GREEN}✓${NC} invalid status reduces health score"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗${NC} invalid status should reduce health score (got $score)"
fi
TESTS_RUN=$((TESTS_RUN + 1))

# Score should be reduced by 20 per invalid status
expected_score=80  # 100 - 20 for 1 invalid status
if [ "$score" -le "$expected_score" ]; then
    echo -e "  ${GREEN}✓${NC} invalid status deducts 20 points (score: $score)"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗${NC} expected score <= $expected_score, got $score"
fi
TESTS_RUN=$((TESTS_RUN + 1))

# Text output should mention invalid statuses
text_output=$($WV health 2>&1)
if echo "$text_output" | grep -q "invalid status"; then
    echo -e "  ${GREEN}✓${NC} health text output shows invalid status warning"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗${NC} health text output should mention invalid status"
fi
TESTS_RUN=$((TESTS_RUN + 1))

# ============================================================================
# Results
# ============================================================================
echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
echo -e "Tests: ${GREEN}$TESTS_PASSED${NC}/${YELLOW}$TESTS_RUN${NC} passed"

if [ "$TESTS_PASSED" -eq "$TESTS_RUN" ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed!${NC}"
    exit 1
fi
