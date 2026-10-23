#!/usr/bin/env bash
# run-all.sh counts what each suite reports, and names what it cannot count
# (wv-40c851). It used to parse only "Results: X/Y passed", so a suite printing
# "Tests: N | Passed: P | Failed: F", or only a PASS verdict, contributed 0/0
# and the test total silently understated what ran. A copy of run-all.sh runs
# here against stub suites, one per shape, under the real suites' names. The
# PASS-only stub borrows a suite the public release keeps: this file ships, and
# a Rust evidence suite name here trips the release leak guard (wv-eeaded).
set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
TMP=$(mktemp -d /tmp/wv-run-all-counts-XXXXXX)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/tests" "$TMP/.weave"
cp "$ROOT/tests/run-all.sh" "$TMP/tests/run-all.sh"
mkdir -p "$TMP/scripts/lib"
cp "$ROOT/scripts/lib/wv-scratch.sh" "$TMP/scripts/lib/wv-scratch.sh"
printf '#!/bin/bash\necho "Results: 3/3 passed"\n' > "$TMP/tests/test-policy-cells.sh"
printf '#!/bin/bash\necho "Tests: 5 | Passed: 5 | Failed: 0"\n' > "$TMP/tests/test-quality.sh"
printf '#!/bin/bash\necho "Violation vocabulary: PASS"\n' > "$TMP/tests/test-violation-vocabulary.sh"

# run_one <filter> -> the copied aggregate's output for that one suite
run_one() { (cd "$TMP" && bash tests/run-all.sh --serial --suite="$1" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'); }

out=$(run_one test-policy-cells)
[[ "$out" == *"Policy Rule Cells: 3/3 tests"* ]] && [[ "$out" == *"Total tests: 3/3 passed"* ]] &&
    ok "a Results: X/Y suite is counted" || bad "a Results: X/Y suite is counted" "$(grep -E 'Cells|Total' <<< "$out")"

out=$(run_one "Quality Scan and Reset")
[[ "$out" == *"Quality Scan and Reset: 5/5 tests"* ]] && [[ "$out" == *"Total tests: 5/5 passed"* ]] &&
    ok "a Tests: N | Passed: P suite is counted, not read as 0/0" ||
    bad "a Tests: N | Passed: P suite is counted, not read as 0/0" "$(grep -E 'Quality|Total' <<< "$out")"

out=$(run_one test-violation-vocabulary)
if [[ "$out" == *"Violation Vocabulary Contract: no test count"* ]] && [[ "$out" != *"Contract: 0/0"* ]] &&
    [[ "$out" == *"Not in the test total"*"test-violation-vocabulary.sh"* ]] &&
    grep -qx "uncounted-suite: test-violation-vocabulary.sh" <<< "$out"; then
    ok "a suite with no parseable count is named, never counted as 0/0"
else
    bad "a suite with no parseable count is named, never counted as 0/0" "$(grep -E 'Contract|Total|uncounted|Not in' <<< "$out")"
fi

# Capacity is checked before any suite starts, in serial and parallel mode.
printf '#!/bin/bash\ntouch "%s/probe"\necho "Results: 3/3 passed"\n' "$TMP" > "$TMP/tests/test-policy-cells.sh"
for mode in --serial --parallel; do
    rm -f "$TMP/probe"
    rc=0
    out=$(WV_SCRATCH_MIN_KB=999999999999 bash "$TMP/tests/run-all.sh" "$mode" --suite=test-policy-cells 2>&1) || rc=$?
    run=$((run+1))
    if [ "$rc" -ne 0 ] && [ ! -e "$TMP/probe" ] && [[ "$out" == *"insufficient capacity before expensive work"* ]]; then
        pass=$((pass+1)); echo "  ✓ $mode refuses capacity before starting a suite"
    else
        echo "  FAIL: $mode capacity preflight (rc=$rc): $out"
    fi
done

echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
