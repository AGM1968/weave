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
mkdir -p "$TMP/tests/lib"
cp "$ROOT/tests/lib/errexit-report.sh" "$TMP/tests/lib/errexit-report.sh"
mkdir -p "$TMP/scripts/lib"
cp "$ROOT/scripts/lib/wv-scratch.sh" "$TMP/scripts/lib/wv-scratch.sh"
printf '#!/bin/bash\necho "Results: 3/3 passed"\n' > "$TMP/tests/test-policy-cells.sh"
printf '#!/bin/bash\necho "Tests: 5 | Passed: 5 | Failed: 0"\n' > "$TMP/tests/test-quality.sh"
printf '#!/bin/bash\necho "Violation vocabulary: PASS"\n' > "$TMP/tests/test-violation-vocabulary.sh"

# run_one <mode> <filter> -> the copied aggregate's output for that one suite.
# Both modes print their own per-suite line; the release --verify runs the
# parallel one, which printed a no-count suite as 0/0 (wv-0be4c5).
run_one() { (cd "$TMP" && bash tests/run-all.sh "$1" --suite="$2" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'); }

for mode in --serial --parallel; do
    out=$(run_one "$mode" test-policy-cells)
    [[ "$out" == *"Policy Rule Cells: 3/3 tests"* ]] && [[ "$out" == *"Total tests: 3/3 passed"* ]] &&
        ok "$mode: a Results: X/Y suite is counted" ||
        bad "$mode: a Results: X/Y suite is counted" "$(grep -E 'Cells|Total' <<< "$out")"

    out=$(run_one "$mode" "Quality Scan and Reset")
    [[ "$out" == *"Quality Scan and Reset: 5/5 tests"* ]] && [[ "$out" == *"Total tests: 5/5 passed"* ]] &&
        ok "$mode: a Tests: N | Passed: P suite is counted, not read as 0/0" ||
        bad "$mode: a Tests: N | Passed: P suite is counted, not read as 0/0" "$(grep -E 'Quality|Total' <<< "$out")"

    out=$(run_one "$mode" test-violation-vocabulary)
    if [[ "$out" == *"Violation Vocabulary Contract: no test count"* ]] && [[ "$out" != *"Contract: 0/0"* ]] &&
        [[ "$out" == *"Not in the test total"*"test-violation-vocabulary.sh"* ]] &&
        grep -qx "uncounted-suite: test-violation-vocabulary.sh" <<< "$out"; then
        ok "$mode: a suite with no parseable count is named, never counted as 0/0"
    else
        bad "$mode: a suite with no parseable count is named, never counted as 0/0" \
            "$(grep -E 'Contract|Total|uncounted|Not in' <<< "$out")"
    fi
done

# A suite that errexit ends names where (wv-f03855). The rc.16 publish's first
# verify stopped on a suite whose setup sent a failing command's output to
# /dev/null, and run-all could say only "no test count". The stub's child bash
# fails under its own set -e first and must not report: only the suite does,
# so the output holds exactly one report.
cat > "$TMP/tests/test-policy-cells.sh" <<'STUB'
#!/bin/bash
set -euo pipefail
out=$(bash -c 'set -e; false' 2>&1) || true
echo "child:[$out]"
id=$(printf 'none\n' | grep wv-)
echo "Results: 1/1 passed"
STUB
for mode in --serial --parallel; do
    out=$(run_one "$mode" test-policy-cells)
    # One report: a child that inherited the trap would add its own line.
    if [[ "$out" == *"Error: test-policy-cells.sh stopped at line 5 (exit 1): id="* ]] &&
        [ "$(grep -c 'Error: .* stopped at line' <<< "$out")" = 1 ]; then
        ok "$mode: a suite errexit ends names its file, line, exit code and command"
    else
        bad "$mode: a suite errexit ends names its file, line, exit code and command" \
            "$(grep -E 'Cells|Error|child' <<< "$out")"
    fi
done

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
