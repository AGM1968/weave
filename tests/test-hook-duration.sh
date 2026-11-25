#!/usr/bin/env bash
# test-hook-duration.sh — hook_duration_ms, the wall-clock helper both gates
# load from scripts/lib/wv-clock.sh.
#
# The gates time a suite or lane the supervisor gave no monotonic reading for
# with this helper (labelled clock=wall, wv-b17a85), and those timings are only
# as good as it is. Flipping its negative clamp to '-ge 0' zeroed every
# recorded duration and no suite noticed (wv-8561b6, S0 re-measure). Each hook
# once carried its own copy; the one copy is now the library's, loaded here
# with no caller definition in place and driven directly.
#
# Exit codes:
#   0 - All tests passed
#   1 - One or more tests failed

set -euo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)

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

hook=wv-clock.sh
unset -f hook_duration_ms
# shellcheck source=scripts/lib/wv-clock.sh
source "$ROOT/scripts/lib/$hook"
check "$hook: defines hook_duration_ms" declare -F hook_duration_ms
# wv_now validates the reading and falls back to a portable clock, so the
# timing cases run on every host instead of skipping where date has no %N
# (wv-43082a).
# shellcheck source=scripts/lib/wv-resolve-runtime.sh
source "$ROOT/scripts/lib/wv-resolve-runtime.sh"
now=$(wv_now ns) || now=""
if ! declare -F hook_duration_ms >/dev/null; then
    :
elif ! [[ "$now" =~ ^[0-9]{19,}$ ]]; then
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}✗${NC} $hook: no nanosecond clock (wv_now ns gave '$now')"
else
    past=$(hook_duration_ms "$((now - 2000000000))")
    check "$hook: a start 2s ago reports about 2000ms (got $past)" \
        test "$past" -ge 1900 -a "$past" -lt 60000
    future=$(hook_duration_ms "$((now + 5000000000))")
    check "$hook: a start in the future clamps to 0 (got $future)" test "$future" = 0
    check "$hook: the 0 sentinel reports 0" test "$(hook_duration_ms 0)" = 0
    check "$hook: a non-numeric start reports 0" test "$(hook_duration_ms 12N)" = 0
    check "$hook: an empty start reports 0" test "$(hook_duration_ms '')" = 0
fi

echo ""
echo "Results: $((TESTS_RUN - TESTS_FAILED))/$TESTS_RUN passed"
[ "$TESTS_FAILED" -eq 0 ]
