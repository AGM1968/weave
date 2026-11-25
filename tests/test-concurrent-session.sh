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
# shellcheck source=tests/lib/fake-agent-bin.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/fake-agent-bin.sh"
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
mkdir -p "$TEST_DIR/repo" "$TEST_DIR/fake-bin" "$TEST_DIR/copilot-home/session-state"
git -C "$TEST_DIR/repo" init -q
# Copilot session-state is read from $COPILOT_HOME (wv-e6a111); a fixture home
# keeps the operator's live Copilot sessions out of this suite.
export COPILOT_HOME="$TEST_DIR/copilot-home"
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
fake_agent_bin "$TEST_DIR/fake-bin/codex"
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
    fake_agent_bin "$TEST_DIR/fake-bin/$_agent"
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
    fake_agent_bin "$TEST_DIR/fake-bin/$_lookalike"
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

stop_fake() {
    kill "$FAKE_PID" 2>/dev/null || true
    wait "$FAKE_PID" 2>/dev/null || true
    FAKE_PID=""
}

# ── Lookalikes judged by exe basename too: comm and exe both pip/ping/pipewire ──
for _lookalike in ping pipewire; do
    fake_agent_bin "$TEST_DIR/fake-bin/$_lookalike"
    (cd "$TEST_DIR/repo" && exec "$TEST_DIR/fake-bin/$_lookalike" 30) &
    FAKE_PID=$!
    sleep 0.3
    if _wv_concurrent_session "$TEST_DIR/repo" >/dev/null; then
        check "$_lookalike exe (pi prefix only) does not trigger an advisory" false
    else
        check "$_lookalike exe (pi prefix only) does not trigger an advisory" true
    fi
    stop_fake
done

# ── wv-e6a111: Copilot CLI renames its main thread, so comm != exe basename ──
# A bash copy named copilot sets its own comm and stays alive; sleep children
# have comm=sleep and are not matched.
cp /bin/bash "$TEST_DIR/fake-bin/copilot"
start_mainthread_copilot() {
    # shellcheck disable=SC2016  # $$ expands in the fake copilot's own shell
    (cd "$1" && exec "$TEST_DIR/fake-bin/copilot" -c 'printf MainThread > /proc/$$/comm; while :; do sleep 1; done') &
    FAKE_PID=$!
    sleep 0.4
}
start_mainthread_copilot "$TEST_DIR/repo"
# shellcheck disable=SC2016  # $1 expands in the bash -c child
check "fixture: comm is MainThread while the exe is named copilot" \
    bash -c '[ "$(cat /proc/$1/comm)" = MainThread ] && [ "$(basename "$(readlink /proc/$1/exe)")" = copilot ]' _ "$FAKE_PID"
if _result=$(_wv_concurrent_session "$TEST_DIR/repo") && [[ "$_result" == *"pid $FAKE_PID"* ]]; then
    check "copilot exe with comm MainThread and a cwd inside the repo triggers an advisory" true
else
    check "copilot exe with comm MainThread and a cwd inside the repo triggers an advisory" false
fi
stop_fake
start_mainthread_copilot "$TEST_DIR"
if _wv_concurrent_session "$TEST_DIR/repo" >/dev/null; then
    check "the same copilot process with its cwd outside the repo (no lock) is not flagged" false
else
    check "the same copilot process with its cwd outside the repo (no lock) is not flagged" true
fi
stop_fake

# ── wv-e6a111: VS Code's copilot-runtime keeps cwd=$HOME; its session-state lock
# (inuse.<pid>.lock + workspace.yaml) is the workspace signal ──
fake_agent_bin "$TEST_DIR/fake-bin/copilot-runtime"
SS="$COPILOT_HOME/session-state"
start_runtime() {
    (cd "$TEST_DIR" && exec "$TEST_DIR/fake-bin/$1" 30) &
    FAKE_PID=$!
    sleep 0.3
}
# write_session <id> <pid> <workspace dir or ""> — empty workspace: lock only
write_session() {
    rm -rf "${SS:?}/$1"
    mkdir -p "$SS/$1"
    : >"$SS/$1/inuse.$2.lock"
    [ -z "$3" ] || printf 'id: %s\ncwd: %s\ngit_root: %s\nclient_name: vscode-agent-host\n' "$1" "$3" "$3" >"$SS/$1/workspace.yaml"
}
lock_flags() {
    _result=""
    _result=$(_wv_concurrent_session "$TEST_DIR/repo") && [[ "$_result" == *"pid $FAKE_PID"* ]]
}
mkdir -p "$TEST_DIR/other-repo"

start_runtime copilot-runtime
write_session s-live "$FAKE_PID" "$TEST_DIR/repo"
if lock_flags; then
    check "live copilot-runtime with cwd outside the repo and a lock naming the repo is flagged" true
else
    check "live copilot-runtime with cwd outside the repo and a lock naming the repo is flagged" false
fi
# shellcheck disable=SC2016  # $1 expands in the bash -c child
check "lock advisory names the client and wv-fa566a" bash -c '[[ "$1" == *vscode-agent-host* && "$1" == *wv-fa566a* ]]' _ "$_result"
write_session s-live "$FAKE_PID" "$TEST_DIR/repo/sub"
if lock_flags; then
    check "a lock whose workspace is under the repo is flagged" true
else
    check "a lock whose workspace is under the repo is flagged" false
fi
write_session s-live "$FAKE_PID" ""
if lock_flags; then
    check "a lock without workspace.yaml is skipped" false
else
    check "a lock without workspace.yaml is skipped" true
fi
write_session s-live "$FAKE_PID" "$TEST_DIR/other-repo"
if lock_flags; then
    check "a lock whose workspace names another repo is not flagged" false
else
    check "a lock whose workspace names another repo is not flagged" true
fi
write_session s-live "$FAKE_PID" "${TEST_DIR}/repo-sibling"
if lock_flags; then
    check "a workspace that only shares the repo path as a prefix is not flagged" false
else
    check "a workspace that only shares the repo path as a prefix is not flagged" true
fi
# Reused pid: a dead session's dir names this repo, its lock predates the live
# copilot process now holding that pid, and the live process's own session
# names another repo.
write_session s-live "$FAKE_PID" "$TEST_DIR/other-repo"
write_session s-stale "$FAKE_PID" "$TEST_DIR/repo"
python3 -I -c 'import os, sys; t = float(sys.argv[1]); os.utime(sys.argv[2], (t, t))' "$(( $(date +%s) - 3600 ))" "$SS/s-stale/inuse.$FAKE_PID.lock"  # touch -d is GNU-only (wv-f6b909)
if lock_flags; then
    check "a stale lock whose pid was reused by a copilot working in another repo is not flagged" false
else
    check "a stale lock whose pid was reused by a copilot working in another repo is not flagged" true
fi
rm -rf "${SS:?}/s-stale"
stop_fake

# Dead pid: the lock outlives its process.
start_runtime copilot-runtime
_dead=$FAKE_PID
stop_fake
write_session s-live "$_dead" "$TEST_DIR/repo"
if _wv_concurrent_session "$TEST_DIR/repo" >/dev/null; then
    check "a lock whose pid is dead is not flagged" false
else
    check "a lock whose pid is dead is not flagged" true
fi

# Live pid, but not a copilot exe.
fake_agent_bin "$TEST_DIR/fake-bin/node"
start_runtime node
write_session s-live "$FAKE_PID" "$TEST_DIR/repo"
if lock_flags; then
    check "a lock held by a live non-copilot process is not flagged" false
else
    check "a lock held by a live non-copilot process is not flagged" true
fi
stop_fake
rm -rf "${SS:?}/s-live"

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
