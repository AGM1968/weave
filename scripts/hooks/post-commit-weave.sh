#!/usr/bin/env bash
# Weave post-commit hook: run deferred non-critical suites queued by pre-commit.
# Best-effort only: never blocks completed commits.

hook_progress() {
    [ "${WV_HOOK_PROGRESS:-1}" = "0" ] && return 0
    printf '%s\n' "Weave post-commit: $1" >&2
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

    if GIT_CONFIG_COUNT=1 \
        GIT_CONFIG_KEY_0=core.hooksPath \
        GIT_CONFIG_VALUE_0=/dev/null \
        bash "$REPO_ROOT/$_pc_suite" </dev/null >/dev/null 2>&1; then
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
