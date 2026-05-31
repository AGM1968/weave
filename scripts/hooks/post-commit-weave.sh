#!/usr/bin/env bash
# Weave post-commit hook: run deferred non-critical suites queued by pre-commit.
# Best-effort only: never blocks completed commits.

hook_progress() {
    [ "${WV_HOOK_PROGRESS:-1}" = "0" ] && return 0
    printf '%s\n' "Weave post-commit: $1" >&2
}

# hook_duration_ms <start_nanos> — wall-clock milliseconds elapsed since a
# `date +%s%N` timestamp (LL1). Returns 0 when nanosecond `date` is unavailable
# (literal "N" output) or the start is the 0 sentinel, so a ledger row never
# carries a bogus negative/garbage cost.
hook_duration_ms() {
    local _t0="$1" _t1 _d
    _t1=$(date +%s%N 2>/dev/null || echo 0)
    case "$_t0" in ''|*[!0-9]*) echo 0; return 0 ;; esac
    case "$_t1" in ''|*[!0-9]*) echo 0; return 0 ;; esac
    [ "$_t0" = "0" ] && { echo 0; return 0; }
    _d=$(( (_t1 - _t0) / 1000000 ))
    [ "$_d" -lt 0 ] && _d=0
    echo "$_d"
}

suite_cost() {
    case "$1" in
        tests/test-graph.sh) echo 35 ;;
        tests/test-hooks.sh) echo 25 ;;
        tests/test-core.sh)  echo 180 ;;
        *) echo 0 ;;
    esac
}

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || exit 0)
QUEUE_FILE="$REPO_ROOT/.git/.weave-deferred-suites"

[ -s "$QUEUE_FILE" ] || exit 0

# Resolve wv + the files in the just-made commit, for the test_results ledger (P6a).
WV="$(command -v wv 2>/dev/null || echo "$REPO_ROOT/scripts/wv")"
_pc_committed_csv=$(git diff-tree --no-commit-id --name-only -r HEAD 2>/dev/null \
    | grep -v '^\.weave/' | paste -sd ',' - 2>/dev/null || echo "")

hook_progress "processing deferred suite queue..."

_pc_total=0
_pc_passed=0
_pc_failed=0

while IFS= read -r _pc_suite; do
    [ -z "$_pc_suite" ] && continue

    case "$_pc_suite" in
        tests/test-core.sh|tests/test-graph.sh|tests/test-hooks.sh) ;;
        *)
            hook_progress "skipping unknown deferred suite: $_pc_suite"
            continue
            ;;
    esac

    _pc_total=$((_pc_total + 1))
    _pc_cost=$(suite_cost "$_pc_suite")
    hook_progress "running deferred $_pc_suite (~${_pc_cost}s)..."

    _pc_t0=$(date +%s%N 2>/dev/null || echo 0)
    GIT_CONFIG_COUNT=1 \
        GIT_CONFIG_KEY_0=core.hooksPath \
        GIT_CONFIG_VALUE_0=/dev/null \
        bash "$REPO_ROOT/$_pc_suite" </dev/null >/dev/null 2>&1
    _pc_rc=$?
    _pc_dur=$(hook_duration_ms "$_pc_t0")
    # Record the deferred suite outcome in the verification ledger (P6a) with its
    # wall-clock cost (LL1). Best-effort.
    "$WV" test-record "$_pc_suite" --files="${_pc_committed_csv:-}" --exit="$_pc_rc" --duration="$_pc_dur" >/dev/null 2>&1 || true
    if [ "$_pc_rc" -eq 0 ]; then
        _pc_passed=$((_pc_passed + 1))
    else
        _pc_failed=$((_pc_failed + 1))
        echo "Weave post-commit: deferred suite failed: $_pc_suite" >&2
        echo "  Run manually: bash $_pc_suite" >&2
    fi
done < "$QUEUE_FILE"

rm -f "$QUEUE_FILE"

if [ "$_pc_total" -gt 0 ]; then
    hook_progress "deferred suites complete: $_pc_passed/$_pc_total passed"
fi

exit 0
