#!/usr/bin/env bash
# test-hook-stale-copy.sh — Regression coverage for the git-hook stale-copy
# guard (wv-98f12b).
#
# .git/hooks/ holds COPIES of scripts/hooks/*-weave.sh, refreshed only by
# install.sh or wv init-repo. A copy that fell behind its source kept gating
# commits with old logic and said nothing (this repo's own pre-commit was found
# 30 lines behind). prepare-commit-msg compares itself with the repository's
# source and, when they differ, announces it and runs the source instead.
#
# pre-commit and pre-push no longer hop to the working tree (S2a, wv-1f98b6):
# where HEAD carries the hook they run HEAD's committed copy, and say so when
# the installed copy differs from it; with no committed hook they run
# themselves. tests/test-protected-dispatcher.sh covers the protection.
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

assert_equals() {
    local expected="$1" actual="$2" description="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$expected" = "$actual" ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "${GREEN}✓${NC} $description"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "${RED}✗${NC} $description"
        echo "  Expected: $expected"
        echo "  Actual:   $actual"
    fi
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Hooks a commit fires. post-commit was retired (wv-56c823); pre-push is not
# fired by a commit and is covered by a direct invocation below.
HOOKS=(pre-commit prepare-commit-msg)

# A pre-commit gate that itself re-executed its source exports the loop guard;
# it must not leak into the scenarios below.
unset WV_HOOK_REEXEC

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

# A fake wv keeps the real prepare-commit-msg body cheap: no active node, so it
# exits before touching the message.
FAKE_BIN="$TEST_DIR/bin"
mkdir -p "$FAKE_BIN"
printf '#!/bin/sh\necho "[]"\n' > "$FAKE_BIN/wv"
chmod +x "$FAKE_BIN/wv"
export PATH="$FAKE_BIN:$PATH"

# new_repo <dir> — an empty repo whose .git/hooks/ holds the REAL Weave hooks.
new_repo() {
    local dir="$1" h
    git init -q "$dir"
    mkdir -p "$dir/.git/lib"
    cp -R "$REPO_ROOT/scripts/lib/." "$dir/.git/lib/"
    for h in "${HOOKS[@]}"; do
        install -m 755 "$REPO_ROOT/scripts/hooks/$h-weave.sh" "$dir/.git/hooks/$h"
    done
}

# ── stale copies run the source and say so ────────────────────────────────
STALE="$TEST_DIR/stale"
new_repo "$STALE"
LOG="$TEST_DIR/stale.log"
: > "$LOG"
mkdir -p "$STALE/scripts/hooks"
for h in "${HOOKS[@]}"; do
    printf '#!/usr/bin/env bash\necho "%s source ran" >> "%s"\n' "$h" "$LOG" > "$STALE/scripts/hooks/$h-weave.sh"
done
set +e
_err=$(cd "$STALE" && git -c core.hooksPath="$STALE/.git/hooks" -c user.name=t -c user.email=t@t \
    commit -q --allow-empty -m "probe" 2>&1 >/dev/null)
rc=$?
set -e
if [ "$rc" -ne 0 ]; then printf '%s\n' "$_err" >&2; fi
assert_equals "0" "$rc" "stale copies: commit succeeds"
assert_equals "1" "$(grep -cxF -- "prepare-commit-msg source ran" "$LOG" || true)" "stale prepare-commit-msg copy runs the repository source exactly once"
assert_equals "1" "$(printf '%s\n' "$_err" | grep -cF -- "Weave prepare-commit-msg: installed hook differs" || true)" "stale prepare-commit-msg copy announces the drift"
assert_equals "0" "$(grep -cxF -- "pre-commit source ran" "$LOG" || true)" "no committed pre-commit (unborn HEAD): the working-tree source is not run"

# ── a committed pre-commit runs from HEAD, never the working tree ─────────
git -C "$STALE" add scripts/hooks
git -C "$STALE" -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@t commit -q -m "commit the sources"
printf '#!/usr/bin/env bash\necho "pre-commit working tree ran" >> "%s"\n' "$LOG" > "$STALE/scripts/hooks/pre-commit-weave.sh"
: > "$LOG"
set +e
_err=$(cd "$STALE" && git -c core.hooksPath="$STALE/.git/hooks" -c user.name=t -c user.email=t@t \
    commit -q --allow-empty -m "probe 2" 2>&1 >/dev/null)
rc=$?
set -e
assert_equals "0" "$rc" "committed pre-commit: commit succeeds"
assert_equals "1" "$(grep -cxF -- "pre-commit source ran" "$LOG" || true)" "the installed copy runs HEAD's committed pre-commit exactly once"
assert_equals "0" "$(grep -cxF -- "pre-commit working tree ran" "$LOG" || true)" "...never the working tree's"
assert_equals "1" "$(printf '%s\n' "$_err" | grep -cF -- "Weave pre-commit: running HEAD's committed gate" || true)" "...and says the copy differs from it"
git -C "$STALE" checkout -q -- scripts/hooks

# ── a current copy runs itself, silently ──────────────────────────────────
CURRENT="$TEST_DIR/current"
new_repo "$CURRENT"
mkdir -p "$CURRENT/scripts/hooks"
cp "$REPO_ROOT/scripts/hooks/prepare-commit-msg-weave.sh" "$CURRENT/scripts/hooks/"
printf 'msg\n' > "$TEST_DIR/msg"
set +e
_err=$(cd "$CURRENT" && ./.git/hooks/prepare-commit-msg "$TEST_DIR/msg" message 2>&1 >/dev/null)
rc=$?
set -e
assert_equals "0" "$rc" "current copy: hook exits 0"
assert_equals "" "$_err" "current copy: no drift warning"

# ── a repository without the source (plain consumer) is untouched ─────────
CONSUMER="$TEST_DIR/consumer"
new_repo "$CONSUMER"
set +e
_err=$(cd "$CONSUMER" && ./.git/hooks/prepare-commit-msg "$TEST_DIR/msg" message 2>&1 >/dev/null)
rc=$?
set -e
assert_equals "0" "$rc" "no source in repo: hook exits 0"
assert_equals "" "$_err" "no source in repo: no drift warning"

# ── the loop guard stops a second hop ─────────────────────────────────────
: > "$LOG"
set +e
_err=$(cd "$STALE" && WV_HOOK_REEXEC=1 ./.git/hooks/prepare-commit-msg "$TEST_DIR/msg" message 2>&1 >/dev/null)
set -e
assert_equals "0" "$(grep -c "source ran" "$LOG" || true)" "WV_HOOK_REEXEC set: the source is not executed again"
assert_equals "" "$_err" "WV_HOOK_REEXEC set: no drift warning"

# ── pre-push runs HEAD's committed copy too (wv-862ac0, S2a) ──────────────
: > "$LOG"
install -m 755 "$REPO_ROOT/scripts/hooks/pre-push-weave.sh" "$STALE/.git/hooks/pre-push"
printf '#!/usr/bin/env bash\necho "pre-push source ran" >> "%s"\n' "$LOG" > "$STALE/scripts/hooks/pre-push-weave.sh"
git -C "$STALE" add scripts/hooks/pre-push-weave.sh
git -C "$STALE" -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@t commit -q -m "commit pre-push"
printf '#!/usr/bin/env bash\necho "pre-push working tree ran" >> "%s"\n' "$LOG" > "$STALE/scripts/hooks/pre-push-weave.sh"
set +e
_err=$(cd "$STALE" && ./.git/hooks/pre-push origin "$TEST_DIR/remote" </dev/null 2>&1 >/dev/null)
rc=$?
set -e
assert_equals "0" "$rc" "stale pre-push copy: exits 0 via HEAD's committed copy"
assert_equals "1" "$(grep -cxF -- "pre-push source ran" "$LOG" || true)" "stale pre-push copy runs HEAD's committed pre-push exactly once"
assert_equals "0" "$(grep -cxF -- "pre-push working tree ran" "$LOG" || true)" "...never the working tree's"
assert_equals "1" "$(printf '%s\n' "$_err" | grep -cF -- "Weave pre-push: running HEAD's committed gate" || true)" "...and says the copy differs from it"

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
