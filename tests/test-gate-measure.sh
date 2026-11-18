#!/usr/bin/env bash
# Gate measurement (wv-ffda33): suite records carry the gate that ran them, one
# gate record per invocation lands in the gate log beside the suite log, and
# `wv analyze gates` reports exact per-phase figures from those records while
# keeping history from before gate ids apart as approximate. All logs live in a
# temp dir via WV_SUITE_LOG, so the user's durable history is never touched.
set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
export WV_CALL_SOURCE=test
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WV="$(cd "$SCRIPT_DIR/.." && pwd)/scripts/wv"

run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected '$2', got '$3'"; }

TMP=$(mktemp -d /tmp/wv-gate-measure-XXXXXX)
trap 'rm -rf "$TMP"' EXIT
export WV_SUITE_LOG="$TMP/suite_runs.jsonl" WV_HOT_ZONE="$TMP/hz" WV_DB="$TMP/hz/brain.db" WV_RUN_CACHE=0
# The pre-commit gate exports its own phase and id to the suites it runs; this
# suite states its own, so it must not inherit the gate's.
unset WV_GATE_PHASE WV_GATE_ID WV_GATE_LOG
mkdir -p "$TMP/hz"
SUITES="$TMP/suite_runs.jsonl"; GATES="$TMP/gate_runs.jsonl"

# ── records ──
WV_GATE_PHASE=pre-commit WV_GATE_ID=g1 "$WV" test-record tests/test-a.sh --exit=0 --duration=2000 --estimate=1000 >/dev/null 2>&1
check "a suite record carries the gate's phase, id and estimate" "pre-commit g1 1000" \
    "$(tail -1 "$SUITES" | jq -r '"\(.phase) \(.gate_id) \(.estimate_ms)"')"

"$WV" test-record tests/test-b.sh --exit=0 --duration=500 >/dev/null 2>&1
check "a suite record from outside a gate keeps the old shape" "false false false" \
    "$(tail -1 "$SUITES" | jq -r '"\(has("phase")) \(has("gate_id")) \(has("estimate_ms"))"')"

before=$(wc -l < "$SUITES")
"$WV" test-record gate --gate --phase=pre-commit --gate-id=g1 --exit=0 --duration=4000 --estimate=2000 \
    --suites=tests/test-a.sh,tests/test-b.sh >/dev/null 2>&1
check "a gate record lands in the gate log beside the suite log" "g1 4000 2" \
    "$(tail -1 "$GATES" | jq -r '"\(.gate_id) \(.duration_ms) \(.suites | length)"')"
check "...and adds nothing to the suite log" "$before" "$(wc -l < "$SUITES")"

"$WV" test-record gate --gate --phase=pre-commit --gate-id=g2 --exit=1 --duration=10000 --estimate=5000 --suites=tests/test-a.sh >/dev/null 2>&1
"$WV" test-record gate --gate --phase=post-commit --gate-id=g3 --exit=0 --duration=60000 --suites=tests/test-core.sh >/dev/null 2>&1
check "a gate with no estimate records null, not zero" "null" "$(tail -1 "$GATES" | jq -r '.estimate_ms')"

# ── analyze gates ──
out=$("$WV" analyze gates --json 2>/dev/null)
pc=$(jq -c '.phases[] | select(.phase == "pre-commit")' <<< "$out")
check "per-phase counts and failures" "2 1" "$(jq -r '"\(.gates) \(.failed)"' <<< "$pc")"
check "wall p50/p90/max in seconds" "4 10 10" "$(jq -r '"\(.wall_p50_s|floor) \(.wall_p90_s|floor) \(.wall_max_s|floor)"' <<< "$pc")"
check "estimate error is actual over estimate" "true" "$(jq -r '.estimate_ratio_p50 == 2' <<< "$pc")"
check "phases are reported separately" "post-commit,pre-commit" "$(jq -r '[.phases[].phase] | sort | join(",")' <<< "$out")"
check "the worst-estimated suite is named with its ratio" "tests/test-a.sh true" \
    "$(jq -r '.estimate_misses[0] | "\(.suite) \(.ratio_p50 == 2)"' <<< "$out")"
check "only runs without a gate id count as approximate history" "1" \
    "$(jq -r '.approximate_by_commit.commits' <<< "$out")"
check "--since filters by timestamp" "0" "$("$WV" analyze gates --json --since=2999-01-01 2>/dev/null | jq -r '.phases | length')"

# ── when a suite started and exited, and when its gate started (wv-4666cb) ──
# After the analyze checks above, so these records cannot move their counts.
# ts is when a line is written, which for a gate is after its last suite: a
# failure's own time can only come from started_ms/ended_ms.
"$WV" test-record tests/test-when.sh --exit=1 --duration=1500 \
    --started-ms=1792000000000 --ended-ms=1792000001500 >/dev/null 2>&1
check "a suite record carries the suite's start and exit in epoch ms" "1792000000000 1792000001500" \
    "$(tail -1 "$SUITES" | jq -r '"\(.started_ms) \(.ended_ms)"')"
"$WV" test-record tests/test-when.sh --exit=0 --duration=5 >/dev/null 2>&1
check "a suite record without them keeps the old shape" "false false" \
    "$(tail -1 "$SUITES" | jq -r '"\(has("started_ms")) \(has("ended_ms"))"')"
"$WV" test-record tests/test-when.sh --exit=0 --duration=5 --started-ms=- --ended-ms=0 >/dev/null 2>&1
check "an unknown time (date without %N) or 0 is absent, not recorded as 0" "false false" \
    "$(tail -1 "$SUITES" | jq -r '"\(has("started_ms")) \(has("ended_ms"))"')"
"$WV" test-record gate --gate --phase=when --gate-id=g4 --exit=1 --duration=3000 \
    --started-ms=1791999999000 >/dev/null 2>&1
check "a gate record carries its start in epoch ms" "1791999999000" "$(tail -1 "$GATES" | jq -r '.started_ms')"
"$WV" test-record gate --gate --phase=when --gate-id=g5 --exit=0 --duration=5 >/dev/null 2>&1
check "a gate record without one has no started_ms" "false" "$(tail -1 "$GATES" | jq -r 'has("started_ms")')"

# ── candidate-lane time in the gate record (wv-3dbc11) ──
# Lanes write no suite rows, so their time lives only here (wv-241d5f). Own
# phase, so the per-phase analyze checks above keep their counts.
_gm_lanes='[{"path":"scripts/lib/a.sh","reused":true,"ms":4000,"jobs":2,"rc":0},{"path":"scripts/lib/b.sh","reused":false,"ms":6000,"jobs":2,"rc":0}]'
"$WV" test-record gate --gate --phase=lanes --gate-id=l1 --exit=0 --duration=20000 \
    --started-ms=1792000000000 --lanes="$_gm_lanes" --lanes-ms=8000 --lanes-started-ms=1792000012000 >/dev/null 2>&1
check "a gate that ran lanes records each lane, their wall and the protected pass" \
    "scripts/lib/a.sh,scripts/lib/b.sh true,false 8000 1792000012000 12000" \
    "$(tail -1 "$GATES" | jq -r '"\([.lanes[].path] | join(",")) \([.lanes[].reused] | map(tostring) | join(",")) \(.lanes_ms) \(.lanes_started_ms) \(.protected_ms)"')"
"$WV" test-record gate --gate --phase=lanes --gate-id=l2 --exit=1 --duration=30000 --started-ms=1792000100000 \
    --lanes='[{"path":"scripts/lib/a.sh","reused":true,"ms":20000,"jobs":4,"rc":1}]' --lanes-ms=21000 \
    --lanes-started-ms=1792000108000 >/dev/null 2>&1
"$WV" test-record gate --gate --phase=lanes --gate-id=l3 --exit=0 --duration=9000 \
    --lanes= --lanes-ms= --lanes-started-ms=- >/dev/null 2>&1
# The record must be this gate's own: on jq 1.6 an empty lanes value once
# passed the array test, aborted the append, and left l2 as the last line
# (wv-b12fb4).
check "a gate with no lane is recorded and carries no lane fields" "l3 false false false false" \
    "$(tail -1 "$GATES" | jq -r '"\(.gate_id) \(has("lanes")) \(has("lanes_ms")) \(has("lanes_started_ms")) \(has("protected_ms"))"')"
"$WV" test-record gate --gate --phase=lanes --gate-id=l4 --exit=0 --duration=9000 \
    --lanes='not json' --lanes-ms=5 >/dev/null 2>&1
check "malformed lanes are dropped, not written as a string" "l4 false false" \
    "$(tail -1 "$GATES" | jq -r '"\(.gate_id) \(has("lanes")) \(has("lanes_ms"))"')"
_gm_out=$("$WV" analyze gates --json 2>/dev/null)
check "analyze reports lane time only over gates that recorded it" "2 8 21 0.58 8 12" \
    "$(jq -r '.phases[] | select(.phase == "lanes") | "\(.lane_gates) \(.lanes_p50_s|floor) \(.lanes_p90_s|floor) \(.lanes_share_of_wall) \(.protected_p50_s|floor) \(.protected_p90_s|floor)"' <<< "$_gm_out")"
check "...and phases with no lane record report none" "0 null" \
    "$(jq -r '.phases[] | select(.phase == "pre-commit") | "\(.lane_gates) \(.lanes_p50_s)"' <<< "$_gm_out")"
check "the costliest lane paths are named with their reruns" "scripts/lib/a.sh 24 2 0|scripts/lib/b.sh 6 1 1" \
    "$(jq -r '[.costly_lanes[] | "\(.path) \(.total_s|floor) \(.runs) \(.reran)"] | join("|")' <<< "$_gm_out")"
check "the text report shows the lane line, naming its scheduler" "1" \
    "$(WV_MODE=full "$WV" analyze gates 2>/dev/null | grep -c 'candidate lanes (fixed-share) in 2 gates: lanes p50 8')"
# Lane figures are segmented by scheduler revision, never blended (wv-428a92):
# rows naming no scheduler ran fixed shares; a newer revision gets its own
# figures, and the top-level ones describe the newest alone.
"$WV" test-record gate --gate --phase=lanes --gate-id=l5 --exit=0 --duration=10000 --started-ms=1792000200000 \
    --lanes='[{"path":"scripts/lib/a.sh","reused":false,"ms":2000,"jobs":4,"rc":0,"scheduler":"shared-slots"}]' \
    --lanes-ms=2000 --lanes-started-ms=1792000207000 >/dev/null 2>&1
_gm_out=$("$WV" analyze gates --json 2>/dev/null)
check "the top-level lane figures describe the newest scheduler alone" "shared-slots 1 2" \
    "$(jq -r '.phases[] | select(.phase == "lanes") | "\(.lane_scheduler) \(.lane_gates) \(.lanes_p50_s|floor)"' <<< "$_gm_out")"
check "...and each revision keeps its own figures, the older ones unchanged" "fixed-share:2:8:21|shared-slots:1:2:2" \
    "$(jq -r '.phases[] | select(.phase == "lanes") | [.lane_schedulers[] | "\(.scheduler):\(.lane_gates):\(.lanes_p50_s|floor):\(.lanes_p90_s|floor)"] | join("|")' <<< "$_gm_out")"
_gm_text=$(WV_MODE=full "$WV" analyze gates 2>/dev/null)
check "the text report gives each revision its own line" "1 1" \
    "$(grep -c 'candidate lanes (fixed-share) in 2 gates' <<< "$_gm_text") $(grep -c 'candidate lanes (shared-slots) in 1 gates' <<< "$_gm_text")"

# ── host pressure over a gate (wv-58b10e) ──
# PSI some-stall totals (µs) at the gate's start and end become each kind's
# stalled time and its share of the gate's wall. Own phase, as above.
"$WV" test-record gate --gate --phase=stall --gate-id=s1 --exit=0 --duration=10000 \
    --pressure-start=1000000,500000 --pressure-end=3000000,600000 >/dev/null 2>&1
check "a gate record carries the CPU and IO stall over the gate and its share of wall" \
    '{"cpu_some_ms":2000,"io_some_ms":100,"cpu_some_share":0.2,"io_some_share":0.01}' \
    "$(tail -1 "$GATES" | jq -c '.pressure')"
"$WV" test-record gate --gate --phase=stall --gate-id=s2 --exit=0 --duration=10000 \
    --pressure-start=0,0 --pressure-end=6000000,1000000 >/dev/null 2>&1
"$WV" test-record gate --gate --phase=stall --gate-id=s3 --exit=0 --duration=10000 >/dev/null 2>&1
check "a gate record without readings has no pressure" "false" "$(tail -1 "$GATES" | jq -r 'has("pressure")')"
"$WV" test-record gate --gate --phase=stall-bad --gate-id=s4 --exit=0 --duration=10000 \
    --pressure-start=5000,5000 --pressure-end=4000,6000 >/dev/null 2>&1
check "counters that went backwards (a reboot between readings) record no pressure" "false" \
    "$(tail -1 "$GATES" | jq -r 'has("pressure")')"
"$WV" test-record gate --gate --phase=stall-bad --gate-id=s5 --exit=0 --duration=10000 \
    --pressure-start='1,x' --pressure-end=2,2 >/dev/null 2>&1
check "a malformed reading records no pressure" "false" "$(tail -1 "$GATES" | jq -r 'has("pressure")')"
mkdir -p "$TMP/psi"
printf 'some avg10=1.00 avg60=0.50 avg300=0.10 total=123\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' > "$TMP/psi/cpu"
printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=456\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=9\n' > "$TMP/psi/io"
_gm_lib="$(cd "$SCRIPT_DIR/.." && pwd)/scripts/lib/wv-gate-pool.sh"
check "the hooks' reader takes each kind's some total" "123,456" \
    "$(# shellcheck source=scripts/lib/wv-gate-pool.sh
    source "$_gm_lib" && WV_PRESSURE_DIR="$TMP/psi" gate_pressure_totals)"
check "...and reads nothing where the kernel has no PSI" "" \
    "$(# shellcheck source=scripts/lib/wv-gate-pool.sh
    source "$_gm_lib" && WV_PRESSURE_DIR="$TMP/nopsi" gate_pressure_totals 2>&1)"
_gm_out=$("$WV" analyze gates --json 2>/dev/null)
check "analyze reports stall shares over the gates that recorded them" "3 2 0.2 0.6 0.01 0.1" \
    "$(jq -r '.phases[] | select(.phase == "stall") | "\(.gates) \(.pressure_gates) \(.cpu_stall_p50) \(.cpu_stall_p90) \(.io_stall_p50) \(.io_stall_p90)"' <<< "$_gm_out")"
check "...and the text report shows them" "1" \
    "$(WV_MODE=full "$WV" analyze gates 2>/dev/null | grep -c 'host stall over 2 gates: CPU p50 20% p90 60%, IO p50 1% p90 10% of wall')"
WV_GATE_PHASE=stall WV_GATE_ID=s2 "$WV" test-record tests/test-stalled.sh --exit=0 --duration=9000 --estimate=1000 >/dev/null 2>&1
_gm_out=$("$WV" analyze gates --json --max-stall=0.5 2>/dev/null)
check "--max-stall leaves out the gates above it and counts the unmeasured it keeps" "2 1 1" \
    "$(jq -r '"\(.phases[] | select(.phase == "stall") | .gates) \(.stall_filter.excluded) \(.phases[] | select(.phase == "stall") | .pressure_gates)"' <<< "$_gm_out")"
check "...and the left-out gates' suite runs" "absent" \
    "$(jq -r 'if any(.estimate_misses[]; .suite == "tests/test-stalled.sh") then "present" else "absent" end' <<< "$_gm_out")"
check "...which are reported without it" "present" \
    "$("$WV" analyze gates --json 2>/dev/null | jq -r 'if any(.estimate_misses[]; .suite == "tests/test-stalled.sh") then "present" else "absent" end')"
"$WV" analyze gates --json --max-stall=2 >/dev/null 2>&1
check "a --max-stall outside 0-1 is refused" "1" "$?"

# ── analyze suites p50 ignores the unmeasured sentinel ──
for d in 0 0 0 300 500; do "$WV" test-record tests/test-c.sh --exit=0 --duration=$d >/dev/null 2>&1; done
check "suite p50 is the median of measured runs, ignoring 0" "500" \
    "$("$WV" analyze suites --json 2>/dev/null | jq -r '.suites[] | select(.suite == "tests/test-c.sh") | .p50_ms')"

# ── recent_p50 follows a growing suite; p50 lags it ──
for d in 100 100 100 100 100 100 100 100 100 100 100 900 900 900 900 900 900; do
    "$WV" test-record tests/test-grow.sh --exit=0 --duration=$d >/dev/null 2>&1
done
check "recent p50 is the median of the last 10 measured runs, all-history p50 lags" "900 100" \
    "$("$WV" analyze suites --json 2>/dev/null | jq -r '.suites[] | select(.suite == "tests/test-grow.sh") | "\(.recent_p50_ms) \(.p50_ms)"')"

# ── every row names the clock its duration was measured on (wv-b17a85) ──
"$WV" test-record tests/test-clk.sh --exit=0 --duration=100 --clock=monotonic >/dev/null 2>&1
check "a suite row carries the clock it was measured on" "monotonic" "$(tail -1 "$SUITES" | jq -r '.clock')"
"$WV" test-record tests/test-clk.sh --exit=0 --duration=100 --clock=sundial >/dev/null 2>&1
check "...an undeclared clock is dropped, never guessed" "false" "$(tail -1 "$SUITES" | jq -r 'has("clock")')"
"$WV" test-record gate --gate --phase=pre-commit --gate-id=gclk --exit=0 --duration=5 --clock=boottime >/dev/null 2>&1
check "a gate row carries the clock it was measured on" "gclk boottime" "$(tail -1 "$GATES" | jq -r '"\(.gate_id) \(.clock)"')"

# Estimates read monotonic runs only; a wall or boottime run (one that may hold
# a suspend) never moves them; a suite with no monotonic run yet keeps its
# unlabelled history until it has one.
est() { "$WV" analyze suites --json 2>/dev/null | jq -r --arg s "$1" '.suites[] | select(.suite == $s) | "\(.p50_ms) \(.recent_p50_ms) \(.estimate_basis)"'; }
for d in 200 200 200; do "$WV" test-record tests/test-sus.sh --exit=0 --duration=$d >/dev/null 2>&1; done
check "a suite with only unlabelled history is estimated from it" "200 200 legacy" "$(est tests/test-sus.sh)"
for d in 9000000 9000000 9000000 9000000; do "$WV" test-record tests/test-sus.sh --exit=0 --duration=$d --clock=wall >/dev/null 2>&1; done
"$WV" test-record tests/test-sus.sh --exit=0 --duration=9000000 --clock=boottime >/dev/null 2>&1
"$WV" test-record tests/test-sus.sh --exit=0 --duration=9000000 --clock=unknown >/dev/null 2>&1
check "...and wall, boottime or unknown runs, which may hold a suspend, never move it" "200 200 legacy" "$(est tests/test-sus.sh)"
"$WV" test-record tests/test-sus.sh --exit=0 --duration=300 --clock=monotonic >/dev/null 2>&1
check "one monotonic run replaces the unlabelled history as the estimate" "300 300 monotonic" "$(est tests/test-sus.sh)"
"$WV" test-record tests/test-wallonly.sh --exit=0 --duration=9000000 --clock=wall >/dev/null 2>&1
check "a suite timed only on the wall clock is unmeasured" "0 0 none" "$(est tests/test-wallonly.sh)"

# ── a test run without its own log never writes the user's durable history ──
fakehome="$TMP/home"; mkdir -p "$fakehome"
(
    unset WV_SUITE_LOG WV_GATE_LOG WV_SUITE_LOG_DEFAULT
    export HOME="$fakehome" WV_CONFIG_DIR="$fakehome/.config/weave" WV_CALL_SOURCE=test
    "$WV" test-record tests/test-leak.sh --exit=0 --duration=5 >/dev/null 2>&1
    "$WV" test-record gate --gate --phase=pre-commit --gate-id=leak --exit=0 --duration=5 >/dev/null 2>&1
)
check "a test run with no log of its own leaves the default logs unwritten" "absent" \
    "$([ -e "$fakehome/.local/share/weave/suite_runs.jsonl" ] || [ -e "$fakehome/.local/share/weave/gate_runs.jsonl" ] && echo present || echo absent)"
(
    unset WV_SUITE_LOG WV_GATE_LOG WV_SUITE_LOG_DEFAULT WV_CALL_SOURCE
    export HOME="$fakehome" WV_CONFIG_DIR="$fakehome/.config/weave"
    "$WV" test-record gate --gate --phase=pre-commit --gate-id=real --exit=0 --duration=5 >/dev/null 2>&1
)
check "a real (non-test) run still writes the default gate log" "real" \
    "$(jq -r '.gate_id' "$fakehome/.local/share/weave/gate_runs.jsonl" 2>/dev/null)"

echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
