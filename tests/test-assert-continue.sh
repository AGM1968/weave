#!/usr/bin/env bash
# A failed assertion is recorded, never fatal (wv-75e31a).
#
# Suites that run under set -e and define their own assert_* helpers used to
# return 1 from the helper's failure branch. errexit then ended the suite at
# its first failed assertion: every later result went unreported, and so did
# the summary, so one failure looked like the only one. The helpers now record
# the failure and return 0; TESTS_FAILED decides the suite's exit status.
#
# Pinned here, for every suite under tests/ that sets -e and defines assert_*
# helpers (found by scanning, so a new suite is covered without a list):
#   - after a failing call to each helper the next statement still runs;
#   - the failing call's output differs from a passing call's, so the failure
#     branch really ran (a helper that never fails cannot satisfy the first);
#   - the scan finds the suites it is meant to cover (it is not vacuous).
# Counters differ between suites (TESTS_FAILED, FAIL, failures...), which is
# why the check is the defect itself -- does the suite go on -- not a count.
# A helper whose call shape is not listed below is reported, not exercised.
set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }

T=$(mktemp -d /tmp/wv-assert-continue-XXXXXX)
trap 'rm -rf "$T"' EXIT
: > "$T/present"

# helpers_of <suite> -> the suite's top-level assert_* function definitions.
helpers_of() {
    awk '/^assert_[a-z_]*\(\) *\{/ { inf = 1 } inf { print } inf && /^\}/ { inf = 0 }' "$1"
}

# A failing and a passing call for each helper shape these suites define.
# assert_json_field is left out: its field argument is a jq path in some
# suites and a dict key in others, and where it is not a delegate to
# assert_equals it is covered by the suite's own assert_equals shape.
fail_call() {
    case "$1" in
        assert_equals) echo 'assert_equals a b "m"' ;;
        assert_not_equals) echo 'assert_not_equals a a "m"' ;;
        assert_contains) echo 'assert_contains hay needle "m"' ;;
        assert_not_contains) echo 'assert_not_contains needle needle "m"' ;;
        assert_success|assert_succeeds) echo "$1 \"m\" false" ;;
        assert_fails) echo 'assert_fails "m" true' ;;
        assert_jq_true) echo "assert_jq_true '{}' '.x == 1' \"m\"" ;;
        assert_file_exists) echo "assert_file_exists \"$T/absent\" \"m\"" ;;
        assert_file_absent) echo "assert_file_absent \"$T/present\" \"m\"" ;;
        *) return 1 ;;
    esac
}
pass_call() {
    case "$1" in
        assert_equals) echo 'assert_equals a a "m"' ;;
        assert_not_equals) echo 'assert_not_equals a b "m"' ;;
        assert_contains) echo 'assert_contains needle needle "m"' ;;
        assert_not_contains) echo 'assert_not_contains hay needle "m"' ;;
        assert_success|assert_succeeds) echo "$1 \"m\" true" ;;
        assert_fails) echo 'assert_fails "m" false' ;;
        assert_jq_true) echo "assert_jq_true '{\"x\":1}' '.x == 1' \"m\"" ;;
        assert_file_exists) echo "assert_file_exists \"$T/present\" \"m\"" ;;
        assert_file_absent) echo "assert_file_absent \"$T/absent\" \"m\"" ;;
        *) return 1 ;;
    esac
}

suites=()
for f in "$SCRIPT_DIR"/test-*.sh; do
    grep -qE '^set -[a-z]*e' "$f" || continue
    grep -qE '^assert_[a-z_]*\(\) *\{' "$f" || continue
    suites+=("$f")
done
echo "scan"
names=$(printf '%s\n' "${suites[@]}" | xargs -n1 basename 2>/dev/null)
if [ "${#suites[@]}" -ge 8 ] && grep -qx 'test-core.sh' <<< "$names"; then
    ok "the scan finds the set -e suites with their own helpers (${#suites[@]}, test-core among them)"
else
    bad "the scan finds the set -e suites with their own helpers" "found ${#suites[@]}"
fi

for f in "${suites[@]}"; do
    echo "$(basename "$f")"
    helpers_of "$f" > "$T/helpers.sh"
    for h in $(grep -oE '^assert_[a-z_]+' "$T/helpers.sh" | sort -u); do
        if ! fc=$(fail_call "$h") || ! pc=$(pass_call "$h"); then
            echo "  - $h: call shape not listed here, not exercised"
            continue
        fi
        # Each call runs in its own errexit shell with every counter name these
        # suites use zeroed and the one helper they share stubbed. Not -u: the
        # defect is errexit, and an unset name here is the probe's, not theirs.
        probe() {
            bash -c "
                set -eo pipefail
                RED='' GREEN='' YELLOW='' BLUE='' NC=''
                TESTS=0 TESTS_RUN=0 TESTS_PASSED=0 TESTS_FAILED=0 PASS=0 FAIL=0 PASSED=0 FAILED=0
                strip_ansi() { cat; }
                source '$T/helpers.sh'
                $1
                echo AFTER
            " 2>&1
        }
        fo=$(probe "$fc"); po=$(probe "$pc")
        if ! grep -qx AFTER <<< "$fo"; then
            bad "$h: the suite goes on after a failed assertion" "aborted: $(tail -2 <<< "$fo" | tr '\n' ' ')"
        elif [ "$fo" = "$po" ]; then
            bad "$h: the failing call takes the failure branch" "same output as a passing call"
        else
            ok "$h: the suite goes on after a failed assertion"
        fi
    done
done

echo ""
echo "assert continue: $pass/$run passed"
[ "$pass" -eq "$run" ]
