#!/usr/bin/env bash
# test-hook-duration.sh — hook_duration_ms in the pre-commit and pre-push hooks.
#
# Both gates record each suite's wall-clock cost with this helper, and the
# suite ledger's timings (and the [heavy] tier chosen from them) are only as
# good as it is. Flipping its negative clamp to '-ge 0' zeroed every recorded
# duration and no suite noticed (wv-8561b6, S0 re-measure). The helper is
# defined in each hook, so each copy is extracted from its own file and driven
# directly.
#
# Exit codes:
#   0 - All tests passed
#   1 - One or more tests failed

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS_RUN=0
TESTS_FAILED=0

check() {
    local description="$1"; shift
    TESTS_RUN=$((TESTS_RUN + 1))
    if "$@"; then
        echo -e "${GREEN}✓${NC} $description"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "${RED}✗${NC} $description"
    fi
}

for hook in pre-commit-weave.sh pre-push-weave.sh; do
    src="$ROOT/scripts/hooks/$hook"
    body=$(awk '/^hook_duration_ms\(\) \{/ {on=1} on {print} on && /^\}/ {exit}' "$src")
    check "$hook: defines hook_duration_ms" test -n "$body"
    [ -n "$body" ] || continue
    eval "$body"

    now=$(date +%s%N)
    case "$now" in *[!0-9]*) echo "  (nanosecond date unavailable; timing cases skipped)"; continue ;; esac

    past=$(hook_duration_ms "$((now - 2000000000))")
    check "$hook: a start 2s ago reports about 2000ms (got $past)" \
        test "$past" -ge 1900 -a "$past" -lt 60000
    future=$(hook_duration_ms "$((now + 5000000000))")
    check "$hook: a start in the future clamps to 0 (got $future)" test "$future" = 0
    check "$hook: the 0 sentinel reports 0" test "$(hook_duration_ms 0)" = 0
    check "$hook: a non-numeric start reports 0" test "$(hook_duration_ms 12N)" = 0
    check "$hook: an empty start reports 0" test "$(hook_duration_ms '')" = 0
    unset -f hook_duration_ms
done

echo ""
echo "Results: $((TESTS_RUN - TESTS_FAILED))/$TESTS_RUN passed"
[ "$TESTS_FAILED" -eq 0 ]
