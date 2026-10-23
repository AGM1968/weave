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
