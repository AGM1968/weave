#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# test-pattern-audit-check9.sh — Tests for pattern-audit Check 9
#
# Source: PROPOSAL-wv-agent-memory-substrate — the graph is the single memory
# authority; per-harness stores are evidence/projections. Check 9 keeps
# harness-store reads ($HOME/.claude/projects, VS Code workspaceStorage, the
# ~/.codex session/state/memory DBs) inside blessed scan/import/telemetry/doctor
# helpers so a recall/render/bootstrap path cannot turn a harness file into
# authoritative memory.

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

TEST_DIR="/tmp/wv-pa-check9-test-$$"
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
    cat > "$TEST_DIR/scripts/cmd/bad-memory.sh" <<'EOF'
#!/bin/bash

rogue_recall() {
    cat "$HOME/.claude/projects/$slug/memory/notes.md"
}
EOF
}

write_good_fixture() {
    cat > "$TEST_DIR/scripts/cmd/good-memory.sh" <<'EOF'
#!/bin/bash

_memory_scan_claude() {
    local project_dir="$HOME/.claude/projects/$slug"
    find "$project_dir" -name '*.md'
}
EOF
}

echo "--- Check 9: harness-store read outside blessed helpers is flagged ---"
setup_test_env
write_bad_fixture
write_good_fixture
AUDIT_OUT=$("$WV" pattern-audit 2>&1 | grep -A8 'Check 9' || true)
assert_contains "$AUDIT_OUT" "Check 9 FAIL" "Check 9 fails on harness-store read in a non-blessed function"
assert_contains "$AUDIT_OUT" "rogue_recall" "offending function is listed"
assert_not_contains "$AUDIT_OUT" "good-memory.sh" "blessed scan-helper fixture is exempt"

echo "--- Check 9: JSON shape ---"
JSON_OUT=$("$WV" pattern-audit --json 2>/dev/null || true)
C9_STATUS=$(echo "$JSON_OUT" | jq -r '.pattern_audit.findings[] | select(.check=="memory_authority_owner") | .status' 2>/dev/null || echo "")
C9_COUNT=$(echo "$JSON_OUT" | jq -r '.pattern_audit.findings[] | select(.check=="memory_authority_owner") | .count' 2>/dev/null || echo "")
assert_contains "$C9_STATUS" "fail" "JSON reports memory_authority_owner fail"
assert_contains "$C9_COUNT" "1" "JSON counts exactly the one rogue read"

echo "--- Check 9: clean fixture passes ---"
rm -f "$TEST_DIR/scripts/cmd/bad-memory.sh"
AUDIT_OUT2=$("$WV" pattern-audit 2>&1 | grep 'Check 9' || true)
assert_contains "$AUDIT_OUT2" "Check 9 PASS" "Check 9 passes when only blessed helpers read harness stores"

echo "--- Check 9: missing scripts dir warns, does not fail ---"
rm -rf "$TEST_DIR/scripts"
AUDIT_OUT3=$("$WV" pattern-audit 2>&1 | grep 'Check 9' || true)
assert_contains "$AUDIT_OUT3" "Check 9 WARN" "missing scripts dir is a warn-skip"

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
if [ "$TESTS_FAILED" -eq 0 ]; then
    echo -e "${GREEN}All tests passed${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed${NC}"
    exit 1
fi
