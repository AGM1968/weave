#!/usr/bin/env bash
# test-concurrent-session.sh — Regression coverage for _wv_concurrent_session
# (wv-fa566a): a live second agent process sharing this working tree should
# surface as a wv bootstrap advisory, without self-flagging the caller's own
# process tree or unrelated processes.
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

check() {
    local description="$1"
    shift
    TESTS_RUN=$((TESTS_RUN + 1))
    if "$@"; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "${GREEN}✓${NC} $description"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "${RED}✗${NC} $description"
    fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ ! -d /proc ]; then
    echo "SKIP: /proc not available on this platform (Linux-only check)"
    exit 0
fi

source "$PROJECT_ROOT/scripts/lib/wv-validate.sh" 2>/dev/null || true
source "$PROJECT_ROOT/scripts/lib/wv-config.sh"

TEST_DIR="/tmp/wv-concurrent-session-test-$$"
mkdir -p "$TEST_DIR/repo" "$TEST_DIR/fake-bin"
git -C "$TEST_DIR/repo" init -q
FAKE_PID=""
cleanup() {
    [ -z "$FAKE_PID" ] || kill "$FAKE_PID" 2>/dev/null || true
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

echo "Test: _wv_concurrent_session detection"
echo "======================================="

# ── Clean state: no other process has a cwd inside the repo ──
_result=""
if _result=$(_wv_concurrent_session "$TEST_DIR/repo"); then
    check "no advisory when no other process has a cwd inside the repo" false
else
    check "no advisory when no other process has a cwd inside the repo" true
fi

# ── Unrelated process with a cwd inside the repo (not agent-named) must not match ──
(cd "$TEST_DIR/repo" && sleep 30 &)
sleep 0.3
_result=""
if _result=$(_wv_concurrent_session "$TEST_DIR/repo"); then
    check "unrelated (non-agent-named) process in repo cwd does not trigger an advisory" false
else
    check "unrelated (non-agent-named) process in repo cwd does not trigger an advisory" true
fi
pkill -f "sleep 30" 2>/dev/null || true
sleep 0.2

# ── A process named like an agent CLI, with a cwd inside the repo, must match ──
cp /bin/sleep "$TEST_DIR/fake-bin/codex"
(cd "$TEST_DIR/repo" && "$TEST_DIR/fake-bin/codex" 30 &)
sleep 0.3
FAKE_PID=$(pgrep -f "$TEST_DIR/fake-bin/codex" | head -1)
_result=""
if _result=$(_wv_concurrent_session "$TEST_DIR/repo"); then
    check "agent-named process with a cwd inside the repo triggers an advisory" true
else
    check "agent-named process with a cwd inside the repo triggers an advisory" false
fi
check "advisory names the offending pid" bash -c '[[ "$1" == *"$2"* ]]' _ "$_result" "$FAKE_PID"
check "advisory references wv-fa566a for traceability" bash -c '[[ "$1" == *"wv-fa566a"* ]]' _ "$_result"
kill "$FAKE_PID" 2>/dev/null || true
FAKE_PID=""

# ── Own process tree (ancestor chain) must never self-flag ──
_self_result=""
if _self_result=$(_wv_concurrent_session "$PROJECT_ROOT"); then
    check "does not self-flag the caller's own ancestor chain" false
else
    check "does not self-flag the caller's own ancestor chain" true
fi

echo ""
echo "========================================"
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
echo "========================================"
if [ "$TESTS_FAILED" -eq 0 ]; then
    echo -e "${GREEN}All tests passed${NC}"
    exit 0
else
    echo -e "${RED}$TESTS_FAILED tests FAILED${NC}"
    exit 1
fi
