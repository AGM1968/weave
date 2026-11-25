#!/usr/bin/env bash
# scripts/lib/wv-clock.sh (wv-b17a85): every reading names its clock, and a
# duration is only taken between two readings of the same one. A suspend inside
# the interval (boottime and wall run on, monotonic stops) is not counted; a
# clock stepping back never yields a negative duration; a reading that falls
# back to another clock is labelled as that clock, never as monotonic.
set -uo pipefail
export WV_TEST_SUITE=1
export WV_CALL_SOURCE=test
ROOT=$(cd "$(dirname "$0")/.." && pwd)
LIB="$ROOT/scripts/lib/wv-clock.sh"
run=0 pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }

T=$(mktemp -d "${TMPDIR:-/tmp}/wv-clock-XXXXXX")
trap 'rm -rf "$T"' EXIT
# shellcheck source=scripts/lib/wv-clock.sh
source "$LIB"
# Set by name through wv_clock_ms / wv_clock_since (printf -v).
ms="" kind="" d="" dk="" s="" sk=""

echo "a real reading"
unset WV_CLOCK_TEST_FILE
wv_clock_ms ms kind
check "is monotonic where python3 is on PATH" "monotonic" "$kind"
check "...in whole milliseconds" "yes" "$([[ "$ms" =~ ^[0-9]+$ ]] && [ "$ms" -gt 0 ] && echo yes)"
wv_clock_since d dk "$ms" "$kind"
check "a real interval is measured on the same clock" "monotonic" "$dk"
check "...and is not negative" "yes" "$([ "$d" -ge 0 ] && echo yes)"

echo "fallbacks are labelled by the clock they read"
mkdir -p "$T/nopy"
for tool in date tail sed; do ln -s "$(command -v "$tool")" "$T/nopy/$tool"; done
# shellcheck disable=SC2016  # expanded by the inner shell, from its arguments
r=$(PATH="$T/nopy" "$BASH" -c 'source "$1"; wv_clock_ms m k; echo "$k"' _ "$LIB")
if [ -r /proc/uptime ]; then
    check "without python3, /proc/uptime is read and labelled boottime" "boottime" "$r"
else
    check "without python3 or /proc/uptime, the wall clock is read and labelled wall" "wall" "$r"
fi

echo "a suspend inside the interval is not counted (fake clocks)"
export WV_CLOCK_TEST_FILE="$T/clock"
# The host slept an hour between the readings: boottime and wall ran on,
# monotonic did not. Each case reads one start and one end.
printf '%s\n' "1000 monotonic" "6000 monotonic" > "$WV_CLOCK_TEST_FILE"
wv_clock_ms s sk; wv_clock_since d dk "$s" "$sk"
check "monotonic readings give the time the host was awake" "5000 monotonic" "$d $dk"
printf '%s\n' "1000 boottime" "3606000 boottime" > "$WV_CLOCK_TEST_FILE"
wv_clock_ms s sk; wv_clock_since d dk "$s" "$sk"
check "...boottime readings keep the suspend and say so" "3605000 boottime" "$d $dk"

echo "a clock stepping back leaves the duration non-negative"
printf '%s\n' "9000 wall" "4000 wall" > "$WV_CLOCK_TEST_FILE"
wv_clock_ms s sk; wv_clock_since d dk "$s" "$sk"
check "a wall clock stepped back 5 s gives 0, labelled wall" "0 wall" "$d $dk"
printf '%s\n' "9000 monotonic" "4000 monotonic" > "$WV_CLOCK_TEST_FILE"
wv_clock_ms s sk; wv_clock_since d dk "$s" "$sk"
check "...as does any reading pair that goes backwards" "0 monotonic" "$d $dk"

echo "a duration across two clocks is not a duration"
printf '%s\n' "1000 monotonic" "2000 boottime" > "$WV_CLOCK_TEST_FILE"
wv_clock_ms s sk; wv_clock_since d dk "$s" "$sk"
check "start and end on different clocks: 0, unknown" "0 unknown" "$d $dk"
printf '%s\n' "2000 monotonic" > "$WV_CLOCK_TEST_FILE"
wv_clock_since d dk "" monotonic
check "a missing start: 0, unknown" "0 unknown" "$d $dk"
printf '%s\n' "2000 sundial" > "$WV_CLOCK_TEST_FILE"
wv_clock_ms s sk
check "an undeclared kind reads as unknown" "unknown" "$sk"

echo "the seam is closed outside a test"
printf '%s\n' "1 monotonic" > "$WV_CLOCK_TEST_FILE"
# shellcheck disable=SC2016  # expanded by the inner shell, from its arguments
r=$(WV_TEST_SUITE=0 bash -c 'source "$1"; wv_clock_ms m k; echo "$m"' _ "$LIB")
check "WV_CLOCK_TEST_FILE is ignored without WV_TEST_SUITE=1" "no" "$([ "$r" = 1 ] && echo yes || echo no)"
unset WV_CLOCK_TEST_FILE

echo "hook_duration_ms (wall readings held by callers)"
check "a 0 start is unmeasured" "0" "$(hook_duration_ms 0)"
check "a start in the future is clamped to 0" "0" "$(hook_duration_ms $(( $(wv_now ns) + 60000000000 )))"  # BSD date prints %N literally (wv-99f296)
check "a non-numeric start is unmeasured" "0" "$(hook_duration_ms 17N)"

echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
