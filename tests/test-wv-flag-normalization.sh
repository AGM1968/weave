#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# test-wv-flag-normalization.sh — the canonical flags survive telemetry normalization.
#
# scripts/wv redacts any argv token it does not recognise. That is right for
# operands, and wrong for flags: an unrecognised --dry-run, --apply and --detail
# all normalise to the same <redacted:N>, so call statistics cannot distinguish a
# reviewed dry-run from an applied promotion — the one distinction the canonical
# lifecycle most needs to observe.
#
# A value-taking flag needs BOTH lists. In _wv_known_option alone, its operand is
# normalised as a separate token rather than recognised as its value.
#
# Exit codes: 0 all checks pass, 1 otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
TESTS_RUN=0; TESTS_PASSED=0; TESTS_FAILED=0
pass() { TESTS_RUN=$((TESTS_RUN+1)); TESTS_PASSED=$((TESTS_PASSED+1)); echo -e "  ${GREEN}✓${NC} $1"; }
fail() { TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAILED=$((TESTS_FAILED+1)); echo -e "  ${RED}✗${NC} $1"; [ -n "${2:-}" ] && echo "$2"; }

echo "=== wv canonical flag normalization ==="
echo ""

# The two lists are read out of the entry point itself rather than re-declared
# here: a copy would drift exactly as every other duplicated list in this repo has.
known_line=$(grep -n -- '--json|--json-v2|--all|--count|--findings|' "$ROOT/scripts/wv" | head -1 | cut -d: -f1)
consumes_line=$(awk 'NR>'"$known_line"' && /--status\|--parent\|--subtree\|--text\|--metadata\|--metadata-file\|/{print NR; exit}' "$ROOT/scripts/wv")

if [ -z "$known_line" ] || [ -z "$consumes_line" ]; then
    fail "both option lists are present in scripts/wv" \
        "    known=$known_line consumes=$consumes_line"
    echo ""; echo "Results: $TESTS_PASSED/$TESTS_RUN passed"; exit 1
fi

known=$(sed -n "${known_line}p" "$ROOT/scripts/wv")
consumes=$(sed -n "${consumes_line}p" "$ROOT/scripts/wv")

for flag in --canonical --dry-run --apply --detail --plan-file; do
    case "$known" in
        *"$flag|"*) pass "$flag is a known option (recorded by name, not redacted)" ;;
        *) fail "$flag is a known option (recorded by name, not redacted)" \
               "    add it to _wv_known_option, or telemetry cannot tell it from any other flag" ;;
    esac
done

case "$consumes" in
    *"--plan-file|"*) pass "--plan-file also consumes its value" ;;
    *) fail "--plan-file also consumes its value" \
           "    a value-taking flag needs _wv_option_consumes_value too, or its operand
    is normalised as a separate token instead of as its value" ;;
esac

# The boolean flags must NOT be in the consumes list: claiming a boolean takes a
# value would swallow the following argument out of the telemetry record.
for flag in --canonical --dry-run --apply --detail; do
    case "$consumes" in
        *"$flag|"*) fail "$flag is boolean and must not consume a value" \
                        "    it would swallow the next argv token" ;;
        *) pass "$flag is boolean and consumes nothing" ;;
    esac
done

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
[ "$TESTS_FAILED" -eq 0 ]
