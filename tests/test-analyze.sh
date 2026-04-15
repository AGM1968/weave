#!/bin/bash
# test-analyze.sh — Tests for wv analyze sessions --token-hogs
# Weave-ID: wv-ad7df8

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$REPO_ROOT/scripts/wv"

# Counter for tests
TESTS_RUN=0
TESTS_PASSED=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-contains assertion}"
    if echo "$haystack" | grep -qF "$needle"; then
        echo -e "  ${GREEN}✓${NC} $msg"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗${NC} $msg"
        echo "    Expected to contain: '$needle'"
        echo "    Actual: '$haystack'"
    fi
    TESTS_RUN=$((TESTS_RUN + 1))
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-not contains assertion}"
    if ! echo "$haystack" | grep -qF "$needle"; then
        echo -e "  ${GREEN}✓${NC} $msg"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗${NC} $msg"
        echo "    Expected NOT to contain: '$needle'"
        echo "    Actual: '$haystack'"
    fi
    TESTS_RUN=$((TESTS_RUN + 1))
}

# ═══════════════════════════════════════════════════════════════════════════
# Setup — synthetic call log
# ═══════════════════════════════════════════════════════════════════════════

LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT

# Write 3 synthetic entries: wv show (largest), wv status, wv ready
cat >"$LOG" <<'EOF'
{"ts":1000000000.0,"cmd":"wv show","stdout_bytes":9000,"stderr_bytes":0,"elapsed_ms":80}
{"ts":1000000001.0,"cmd":"wv status","stdout_bytes":100,"stderr_bytes":0,"elapsed_ms":15}
{"ts":1000000002.0,"cmd":"wv ready","stdout_bytes":4500,"stderr_bytes":0,"elapsed_ms":30}
{"ts":1000000003.0,"cmd":"wv show","stdout_bytes":8000,"stderr_bytes":0,"elapsed_ms":75}
EOF

echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
echo "  wv analyze sessions -- token-hogs"
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""

# ───────────────────────────────────────────────────────────────────────────
# Test 1: basic output contains top command
# ───────────────────────────────────────────────────────────────────────────
output=$($WV analyze sessions --token-hogs --log="$LOG" 2>&1)
assert_contains "$output" "wv show" "top command 'wv show' appears in output"

# ───────────────────────────────────────────────────────────────────────────
# Test 2: aggregation — wv show has 2 calls totalling 17000 bytes
# ───────────────────────────────────────────────────────────────────────────
output=$($WV analyze sessions --token-hogs --log="$LOG" 2>&1)
assert_contains "$output" "17000" "wv show bytes aggregated correctly (2 calls * ~8500 avg = 17000)"

# ───────────────────────────────────────────────────────────────────────────
# Test 3: ordering — wv show before wv ready (17000 > 4500)
# Output may be single-line JSON, so check string position within line
# ───────────────────────────────────────────────────────────────────────────
show_pos=$(echo "$output" | tr ',' '\n' | grep -n '"wv show"' | head -1 | cut -d: -f1)
ready_pos=$(echo "$output" | tr ',' '\n' | grep -n '"wv ready"' | head -1 | cut -d: -f1)
if [ -n "$show_pos" ] && [ -n "$ready_pos" ] && [ "$show_pos" -lt "$ready_pos" ]; then
    echo -e "  ${GREEN}✓${NC} wv show ranked before wv ready"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗${NC} wv show ranked before wv ready"
    echo "    show_pos=$show_pos ready_pos=$ready_pos"
fi
TESTS_RUN=$((TESTS_RUN + 1))

# ───────────────────────────────────────────────────────────────────────────
# Test 4: --top=1 limits output to single entry
# ───────────────────────────────────────────────────────────────────────────
output=$($WV analyze sessions --token-hogs --log="$LOG" --top=1 2>&1)
assert_contains "$output" "wv show" "--top=1 includes top entry"
assert_not_contains "$output" "wv status" "--top=1 excludes lower entries"

# ───────────────────────────────────────────────────────────────────────────
# Test 5: missing log produces informative message (not a crash)
# Output varies by mode (JSON in discover/bootstrap, human text otherwise),
# but both paths include "no call log found".
# ───────────────────────────────────────────────────────────────────────────
output=$($WV analyze sessions --token-hogs --log=/nonexistent/path.jsonl 2>&1 || true)
assert_contains "$output" "no call log found" "missing log shows informative message"

# ───────────────────────────────────────────────────────────────────────────
# Test 6: WV_CALL_LOG env var picked up as default log path
# ───────────────────────────────────────────────────────────────────────────
output=$(WV_CALL_LOG="$LOG" $WV analyze sessions --token-hogs 2>&1)
assert_contains "$output" "wv show" "WV_CALL_LOG env var used as default log"

echo ""

# ═══════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════
echo "═══════════════════════════════════════════════════════════════════════════"
echo -e "Results: $TESTS_PASSED/$TESTS_RUN passed"
if [ "$TESTS_PASSED" -eq "$TESTS_RUN" ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed.${NC}"
    exit 1
fi
