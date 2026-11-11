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
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)

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
UNRELATED_PID=""
FAKE_PID=""
cleanup() {
    [ -z "$UNRELATED_PID" ] || kill "$UNRELATED_PID" 2>/dev/null || true
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
(cd "$TEST_DIR/repo" && exec sleep 30) &
UNRELATED_PID=$!
sleep 0.3
_result=""
if _result=$(_wv_concurrent_session "$TEST_DIR/repo"); then
    check "unrelated (non-agent-named) process in repo cwd does not trigger an advisory" false
else
    check "unrelated (non-agent-named) process in repo cwd does not trigger an advisory" true
fi
kill "$UNRELATED_PID" 2>/dev/null || true
wait "$UNRELATED_PID" 2>/dev/null || true
UNRELATED_PID=""
sleep 0.2

# ── A process named like an agent CLI, with a cwd inside the repo, must match ──
cp /bin/sleep "$TEST_DIR/fake-bin/codex"
(cd "$TEST_DIR/repo" && exec "$TEST_DIR/fake-bin/codex" 30) &
FAKE_PID=$!
sleep 0.3
_result=""
if _result=$(_wv_concurrent_session "$TEST_DIR/repo"); then
    check "agent-named process with a cwd inside the repo triggers an advisory" true
else
    check "agent-named process with a cwd inside the repo triggers an advisory" false
fi
# shellcheck disable=SC2016  # $1/$2 expand in the bash -c child, passed as positional arguments
check "advisory names the offending pid" bash -c '[[ "$1" == *"$2"* ]]' _ "$_result" "$FAKE_PID"
# shellcheck disable=SC2016  # $1/$2 expand in the bash -c child, passed as positional arguments
check "advisory references wv-fa566a for traceability" bash -c '[[ "$1" == *"wv-fa566a"* ]]' _ "$_result"
kill "$FAKE_PID" 2>/dev/null || true
wait "$FAKE_PID" 2>/dev/null || true
FAKE_PID=""

# ── pi and Amp run with comm `pi` / `amp` (observed, wv-d09cee): exact match ──
for _agent in pi amp; do
    cp /bin/sleep "$TEST_DIR/fake-bin/$_agent"
    (cd "$TEST_DIR/repo" && exec "$TEST_DIR/fake-bin/$_agent" 30) &
    FAKE_PID=$!
    sleep 0.3
    if _result=$(_wv_concurrent_session "$TEST_DIR/repo") && [[ "$_result" == *"pid $FAKE_PID"* ]]; then
        check "live $_agent process with a cwd inside the repo triggers an advisory" true
    else
        check "live $_agent process with a cwd inside the repo triggers an advisory" false
    fi
    kill "$FAKE_PID" 2>/dev/null || true
    wait "$FAKE_PID" 2>/dev/null || true
    FAKE_PID=""
done

# ── A name that merely starts with pi/amp (pip, ampd) is not an agent ──
for _lookalike in pip ampd; do
    cp /bin/sleep "$TEST_DIR/fake-bin/$_lookalike"
    (cd "$TEST_DIR/repo" && exec "$TEST_DIR/fake-bin/$_lookalike" 30) &
    FAKE_PID=$!
    sleep 0.3
    if _wv_concurrent_session "$TEST_DIR/repo" >/dev/null; then
        check "$_lookalike process (pi/amp prefix only) does not trigger an advisory" false
    else
        check "$_lookalike process (pi/amp prefix only) does not trigger an advisory" true
    fi
    kill "$FAKE_PID" 2>/dev/null || true
    wait "$FAKE_PID" 2>/dev/null || true
    FAKE_PID=""
done

# ── Own process tree (ancestor chain) must never self-flag ──
_self_result=""
if _self_result=$(cd "$TEST_DIR/repo" && _wv_concurrent_session "$TEST_DIR/repo"); then
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
