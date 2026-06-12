#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# test-pattern-audit-check7.sh — Tests for pattern-audit Check 7
#
# Source: audit finding A3-2 + >=5 prior shipped bugs (graph learnings) —
# a function whose last statement is a bare `[ cond ] && cmd` returns 1 when
# the condition is false; under set -euo pipefail a caller in a plain context
# aborts. Check 7 crystallizes that recurring pitfall into an enforced gate.
#
# Covers (one fixture file, five functions):
#   - FAIL: non-predicate function ending in `[ cond ] && cmd`
#   - PASS: predicate-by-name (is_/has_/can_ prefix, underscore variant)
#   - PASS: '# predicate' annotation on the definition line
#   - PASS: `[ cond ] && cmd || true` (alternative present — safe)
#   - PASS: if/fi tail
#
# Exit codes: 0 all passed, 1 unexpected failure
# Weave-ID: wv-14492b

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

TEST_DIR="/tmp/wv-pa-check7-test-$$"
export WV_HOT_ZONE="$TEST_DIR"
export WV_DB="$TEST_DIR/brain.db"
export WV_REQUIRE_LEARNING=0
export WV_RUN_CACHE=0
export WV_PROJECT_DIR="$TEST_DIR"
mkdir -p "$TEST_DIR/scripts"
cd "$TEST_DIR"
git init -q 2>/dev/null || true
"$WV" init >/dev/null 2>&1

assert_contains() {
    local haystack="$1" needle="$2" msg="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if echo "$haystack" | grep -qF -- "$needle"; then
        echo -e "  ${GREEN}✓${NC} $msg"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗${NC} $msg"
        echo "    expected to contain: $needle"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" msg="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if echo "$haystack" | grep -qF -- "$needle"; then
        echo -e "  ${RED}✗${NC} $msg"
        echo "    expected NOT to contain: $needle"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    else
        echo -e "  ${GREEN}✓${NC} $msg"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    fi
}

# ─── Fixture: scripts/fixture.sh with one bad and four safe tails ──────────
cat > "$TEST_DIR/scripts/fixture.sh" <<'EOF'
#!/bin/bash

bad_tail_fn() {
    local x="$1"
    [ -n "$x" ] && echo "$x"
}

is_present() {
    [ -n "$1" ] && [ -e "$1" ]
}

_can_write() {
    [ -w "$1" ] && [ -d "$1" ]
}

annotated_helper() { # predicate
    [ -n "$1" ] && [ "$1" != "none" ]
}

guarded_tail_fn() {
    local x="$1"
    [ -n "$x" ] && echo "$x" || true
}

iffi_tail_fn() {
    local x="$1"
    if [ -n "$x" ]; then
        echo "$x"
    fi
}
EOF

echo "--- Check 7: bad tail flagged, safe shapes pass ---"
AUDIT_OUT=$("$WV" pattern-audit 2>&1 | grep -A10 'Check 7' || true)

assert_contains     "$AUDIT_OUT" "Check 7 FAIL"   "Check 7 fails on a fixture with a bare tail"
assert_contains     "$AUDIT_OUT" "bad_tail_fn"    "non-predicate bare tail is flagged"
assert_not_contains "$AUDIT_OUT" "is_present"     "is_ prefix is exempt"
assert_not_contains "$AUDIT_OUT" "_can_write"     "_can_ prefix is exempt"
assert_not_contains "$AUDIT_OUT" "annotated_helper" "# predicate annotation is exempt"
assert_not_contains "$AUDIT_OUT" "guarded_tail_fn"  "|| alternative is safe"
assert_not_contains "$AUDIT_OUT" "iffi_tail_fn"     "if/fi tail is safe"

echo "--- Check 7: JSON shape ---"
JSON_OUT=$("$WV" pattern-audit --json 2>/dev/null || true)
C7_STATUS=$(echo "$JSON_OUT" | jq -r '.pattern_audit.findings[] | select(.check=="function_tail_returns") | .status' 2>/dev/null || echo "")
C7_COUNT=$(echo "$JSON_OUT" | jq -r '.pattern_audit.findings[] | select(.check=="function_tail_returns") | .count' 2>/dev/null || echo "")
assert_contains "$C7_STATUS" "fail" "JSON reports function_tail_returns fail"
assert_contains "$C7_COUNT"  "1"    "JSON counts exactly the one bad tail"

echo "--- Check 7: clean fixture passes ---"
sed -i 's/^    \[ -n "$x" \] \&\& echo "$x"$/    if [ -n "$x" ]; then echo "$x"; fi/' "$TEST_DIR/scripts/fixture.sh"
AUDIT_OUT2=$("$WV" pattern-audit 2>&1 | grep 'Check 7' || true)
assert_contains "$AUDIT_OUT2" "Check 7 PASS" "Check 7 passes after the tail is converted to if/fi"

echo "--- Check 7: missing scripts dir warns, does not fail ---"
rm -rf "$TEST_DIR/scripts"
AUDIT_OUT3=$("$WV" pattern-audit 2>&1 | grep 'Check 7' || true)
assert_contains "$AUDIT_OUT3" "Check 7 WARN" "missing scripts dir is a warn-skip"

# ─── Teardown + summary ─────────────────────────────────────────────────────
cd /tmp && rm -rf "$TEST_DIR"
echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
if [ "$TESTS_FAILED" -eq 0 ]; then
    echo -e "${GREEN}All tests passed${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed${NC}"
    exit 1
fi
