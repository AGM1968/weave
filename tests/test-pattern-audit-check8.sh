#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# test-pattern-audit-check8.sh — Tests for pattern-audit Check 8
#
# Source: wv-15aacf — raw sqlite3 probes against quality.db drifted from the
# owner schema once already. Check 8 keeps shell-side quality.db access inside
# explicitly blessed helpers or the Python quality owner module.

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

TEST_DIR="/tmp/wv-pa-check8-test-$$"
export WV_HOT_ZONE="$TEST_DIR"
export WV_DB="$TEST_DIR/brain.db"
export WV_REQUIRE_LEARNING=0
export WV_RUN_CACHE=0
export WV_PROJECT_DIR="$TEST_DIR"

cleanup() { cd /tmp && rm -rf "$TEST_DIR"; }
trap cleanup EXIT

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

setup_test_env() {
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR/scripts/cmd"
    cd "$TEST_DIR"
    git init -q
    "$WV" init -q 2>/dev/null || true
}

write_bad_fixture() {
    cat > "$TEST_DIR/scripts/cmd/bad-quality.sh" <<'EOF'
#!/bin/bash

random_probe() {
    sqlite3 "$WV_HOT_ZONE/quality.db" "SELECT id FROM quality_scans LIMIT 1;"
}
EOF
}

write_good_fixture() {
    cat > "$TEST_DIR/scripts/cmd/good-quality.sh" <<'EOF'
#!/bin/bash

_preflight_policy_readiness() {
    local quality_db="$WV_HOT_ZONE/quality.db"
    sqlite3 "$quality_db" "SELECT id FROM scan_meta LIMIT 1;"
}

_bootstrap_agent_tools_json() {
    sqlite3 "$WV_HOT_ZONE/quality.db" "SELECT id FROM scan_meta LIMIT 1;"
}
EOF
}

echo "--- Check 8: raw quality.db sqlite3 outside helpers is flagged ---"
setup_test_env
write_bad_fixture
write_good_fixture
AUDIT_OUT=$("$WV" pattern-audit 2>&1 | grep -A8 'Check 8' || true)
assert_contains "$AUDIT_OUT" "Check 8 FAIL" "Check 8 fails on raw quality.db sqlite3 access"
assert_contains "$AUDIT_OUT" "random_probe" "offending function is listed"
assert_contains "$AUDIT_OUT" "quality_scans" "offending invented-table probe is visible"
assert_not_contains "$AUDIT_OUT" "good-quality.sh" "blessed helper fixture is exempt"

echo "--- Check 8: JSON shape ---"
JSON_OUT=$("$WV" pattern-audit --json 2>/dev/null || true)
C8_STATUS=$(echo "$JSON_OUT" | jq -r '.pattern_audit.findings[] | select(.check=="quality_db_sqlite_owner") | .status' 2>/dev/null || echo "")
C8_COUNT=$(echo "$JSON_OUT" | jq -r '.pattern_audit.findings[] | select(.check=="quality_db_sqlite_owner") | .count' 2>/dev/null || echo "")
assert_contains "$C8_STATUS" "fail" "JSON reports quality_db_sqlite_owner fail"
assert_contains "$C8_COUNT" "1" "JSON counts exactly the one bad access"

echo "--- Check 8: clean fixture passes ---"
rm -f "$TEST_DIR/scripts/cmd/bad-quality.sh"
AUDIT_OUT2=$("$WV" pattern-audit 2>&1 | grep 'Check 8' || true)
assert_contains "$AUDIT_OUT2" "Check 8 PASS" "Check 8 passes when only blessed helpers remain"

echo "--- Check 8: missing scripts dir warns, does not fail ---"
rm -rf "$TEST_DIR/scripts"
AUDIT_OUT3=$("$WV" pattern-audit 2>&1 | grep 'Check 8' || true)
assert_contains "$AUDIT_OUT3" "Check 8 WARN" "missing scripts dir is a warn-skip"

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
if [ "$TESTS_FAILED" -eq 0 ]; then
    echo -e "${GREEN}All tests passed${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed${NC}"
    exit 1
fi
