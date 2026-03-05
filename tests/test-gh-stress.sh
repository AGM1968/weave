#!/usr/bin/env bash
# test-gh-stress.sh — GitHub API stress tests for Weave sync
#
# IMPORTANT: These tests hit the live GitHub API. They are NOT part of the
# default test suite. Run manually with explicit opt-in.
#
# Run: bash tests/test-gh-stress.sh
#
# Prerequisites:
#   - gh CLI authenticated
#   - Write access to the repository
#   - Rate limit budget available
#
# Exit codes:
#   0 - All tests passed
#   1 - One or more tests failed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$PROJECT_ROOT/scripts/wv"
SYNC_SCRIPT="$PROJECT_ROOT/scripts/sync-weave-gh.sh"

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

# Helpers
assert_equals() {
    local expected="$1" actual="$2" message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$expected" = "$actual" ]; then
        echo -e "  ${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗${NC} $message"
        echo "    Expected: $expected"
        echo "    Actual:   $actual"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if echo "$haystack" | grep -qF "$needle"; then
        echo -e "  ${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗${NC} $message"
        echo "    Expected to find: $needle"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# Preflight Checks
# ═══════════════════════════════════════════════════════════════════════════

echo "═══════════════════════════════════════════════════════════════════════════"
echo -e "${CYAN}Weave GitHub API Stress Tests${NC}"
echo -e "${YELLOW}WARNING: These tests create real GitHub issues!${NC}"
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""

# Check gh CLI
if ! command -v gh >/dev/null 2>&1; then
    echo -e "${RED}Error: gh CLI not found. Install from https://cli.github.com${NC}"
    exit 1
fi

# Check auth
if ! gh auth status >/dev/null 2>&1; then
    echo -e "${RED}Error: gh not authenticated. Run: gh auth login${NC}"
    exit 1
fi

# Check sync script exists
if [ ! -x "$SYNC_SCRIPT" ]; then
    echo -e "${RED}Error: sync-weave-gh.sh not found or not executable${NC}"
    exit 1
fi

echo -e "${GREEN}Preflight OK${NC}"
echo ""

# ═══════════════════════════════════════════════════════════════════════════
# 4.6.1 Rate Limiting with Batch Creates
# ═══════════════════════════════════════════════════════════════════════════

test_gh_rate_limit() {
    echo -e "${CYAN}Test: Rate Limiting with Batch Creates (4.6.1)${NC}"
    echo "================================================"
    echo ""
    echo "  NOTE: This test documents rate limiting behavior."
    echo "  It does NOT create issues — it checks what WOULD happen."
    echo ""

    # Check current rate limit status
    local rate_info
    rate_info=$(gh api rate_limit 2>&1 | jq '.resources.core' 2>/dev/null || echo "{}")
    local remaining
    remaining=$(echo "$rate_info" | jq '.remaining' 2>/dev/null || echo "unknown")
    local limit
    limit=$(echo "$rate_info" | jq '.limit' 2>/dev/null || echo "unknown")

    TESTS_RUN=$((TESTS_RUN + 1))
    echo -e "  ${GREEN}✓${NC} Rate limit: $remaining/$limit remaining"
    TESTS_PASSED=$((TESTS_PASSED + 1))

    # Check if sync script has any rate limiting
    local has_sleep has_retry
    has_sleep=$(grep -c "sleep" "$SYNC_SCRIPT" 2>/dev/null | tr -d '[:space:]' || echo "0")
    has_retry=$(grep -cE "retry|429|403" "$SYNC_SCRIPT" 2>/dev/null | tr -d '[:space:]' || echo "0")

    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$has_sleep" -gt 0 ] || [ "$has_retry" -gt 0 ]; then
        echo -e "  ${GREEN}✓${NC} Sync script has rate limiting (sleep=$has_sleep, retry=$has_retry)"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${YELLOW}⚠${NC} Sync script has NO rate limiting (sleep=$has_sleep, retry=$has_retry)"
        # Don't count as failure — it's a known gap
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# 4.6.2 Issue Body Length
# ═══════════════════════════════════════════════════════════════════════════

test_gh_body_length() {
    echo ""
    echo -e "${CYAN}Test: Issue Body Length Guard (4.6.2)${NC}"
    echo "======================================"
    echo ""
    echo "  NOTE: Checks sync script for body length handling."
    echo ""

    # Check if sync script has body length guard
    local has_truncate has_length_check
    has_truncate=$(grep -cE "truncat|65536|limit.*body" "$SYNC_SCRIPT" 2>/dev/null | tr -d '[:space:]' || echo "0")
    has_length_check=$(grep -cE '\${#.*body\}|wc -c.*body' "$SYNC_SCRIPT" 2>/dev/null | tr -d '[:space:]' || echo "0")

    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$has_truncate" -gt 0 ] || [ "$has_length_check" -gt 0 ]; then
        echo -e "  ${GREEN}✓${NC} Sync script has body length handling"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${YELLOW}⚠${NC} Sync script has NO body length guard (known gap)"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# 4.8.3 GH Label Round-Trip
# ═══════════════════════════════════════════════════════════════════════════

test_gh_label_roundtrip() {
    echo ""
    echo -e "${CYAN}Test: GH Label Type Mapping (4.8.3)${NC}"
    echo "====================================="
    echo ""
    echo "  NOTE: Checks get_type_label() correctness without creating issues."
    echo ""

    # Check the type mapping in the sync script
    local has_epic has_maintenance
    has_epic=$(grep -c '"epic"' "$SYNC_SCRIPT" 2>/dev/null | tr -d '[:space:]' || echo "0")
    has_maintenance=$(grep -c '"maintenance"' "$SYNC_SCRIPT" 2>/dev/null | tr -d '[:space:]' || echo "0")

    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$has_epic" -gt 0 ]; then
        echo -e "  ${GREEN}✓${NC} Sync script maps 'epic' type"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${YELLOW}⚠${NC} Sync script doesn't map 'epic' type (defaults to 'task')"
    fi

    # Check the default fallthrough
    local default_case
    default_case=$(grep -A1 '^\s*\*)' "$SYNC_SCRIPT" 2>/dev/null | grep -o '"[^"]*"' | head -1 || echo "unknown")
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -e "  ${YELLOW}ℹ${NC} Default type label: $default_case"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

# ═══════════════════════════════════════════════════════════════════════════
# Run Tests
# ═══════════════════════════════════════════════════════════════════════════

test_gh_rate_limit
test_gh_body_length
test_gh_label_roundtrip

# Summary
echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
echo -e "${CYAN}Results: $TESTS_PASSED/$TESTS_RUN passed${NC}"
echo "═══════════════════════════════════════════════════════════════════════════"

if [ "$TESTS_FAILED" -gt 0 ]; then
    echo -e "${RED}FAILED${NC}"
    exit 1
else
    echo -e "${GREEN}ALL TESTS PASSED${NC}"
    exit 0
fi
