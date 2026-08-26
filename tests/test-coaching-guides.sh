#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# test-coaching-guides.sh — coaching guide assets and their resolution contract.
#
# Two halves. The package guides must validate, and the scanner must REJECT each
# defect the contract exists to prevent. The second half is what stops this
# suite going green against a validator that stopped checking.
#
# The harness fails closed: a scanner that crashes, is missing, or returns no
# COUNT line is a failure, never a silent pass. An earlier revision of the two
# sibling suites reported success after their validator died, which is the
# failure this shape removes.
#
# Exit codes: 0 all checks pass, 1 otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCANNER="$SCRIPT_DIR/lib/coaching-guide-scan.py"
GUIDES="$ROOT/scripts/weave_quality/guides"
CATALOG="$ROOT/contracts/violation-vocabulary-v1.json"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
TESTS_RUN=0; TESTS_PASSED=0; TESTS_FAILED=0
pass() { TESTS_RUN=$((TESTS_RUN+1)); TESTS_PASSED=$((TESTS_PASSED+1)); echo -e "  ${GREEN}✓${NC} $1"; }
fail() { TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAILED=$((TESTS_FAILED+1)); echo -e "  ${RED}✗${NC} $1"; [ -n "${2:-}" ] && echo "$2"; }

TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

echo "=== coaching guide assets ==="
echo ""

if [ ! -f "$SCANNER" ]; then
    fail "scanner is present" "    missing: $SCANNER"
    echo "Results: $TESTS_PASSED/$TESTS_RUN passed"; exit 1
fi

# scan <dir> — writes the scanner's output to $TMP/out and RETURNS its exit
# status. Deliberately not a command substitution: a status set inside `$(...)`
# is lost with the subshell, which is how a crashed validator reads as clean.
scan() {
    python3 "$SCANNER" "$1" "$CATALOG" > "$TMP/out" 2>&1
}

scan_ok() { printf '%s\n' "$1" | grep -q '^COUNT '; }

# ── the shipped package guides ────────────────────────────────────────────────
scan "$GUIDES"; scan_status=$?
output=$(cat "$TMP/out")
if [ "$scan_status" -ne 0 ] || ! scan_ok "$output"; then
    fail "package guides scan completes" "    scanner exited $scan_status without a COUNT line:
$(printf '%s\n' "$output" | sed 's/^/    /')"
else
    problems=$(printf '%s\n' "$output" | grep '^PROBLEM' || true)
    if [ -z "$problems" ]; then
        pass "package guides validate ($(printf '%s\n' "$output" | awk '/^COUNT/{print $2}') guides)"
    else
        fail "package guides validate" "$(printf '%s\n' "$problems" | sed 's/^PROBLEM /    /')"
    fi
fi

# ── negative controls ─────────────────────────────────────────────────────────
# Each builds a guide directory carrying exactly one defect, then requires the
# scanner to name it. `expect_problem <label> <fragment>` runs against $TMP/case.
new_case() {
    rm -rf "$TMP/case"; mkdir -p "$TMP/case"
    cp "$GUIDES/_clean.md" "$GUIDES/_incomplete.md" "$GUIDES/_uncoached.md" "$TMP/case/"
}

expect_problem() {
    local label="$1" fragment="$2" out status
    scan "$TMP/case"; status=$?
    out=$(cat "$TMP/out")
    if [ "$status" -ne 0 ] || ! scan_ok "$out"; then
        fail "$label" "    scanner crashed (exit $status) instead of reporting the defect"
        return
    fi
    if printf '%s\n' "$out" | grep -qF -- "$fragment"; then
        pass "$label"
    else
        fail "$label" "    expected a problem mentioning: $fragment
$(printf '%s\n' "$out" | sed 's/^/    /')"
    fi
}

new_case
sed 's/^id: swallowed-exception$/id: something-else/' "$GUIDES/swallowed-exception.md" \
    > "$TMP/case/swallowed-exception.md"
expect_problem "frontmatter id must match the filename" "does not match filename"

new_case
grep -v '^## Corrective move$' "$GUIDES/swallowed-exception.md" \
    | sed '/^Catch only what you can name/,/^logging and returning a default is a legitimate choice when it is a choice.$/d' \
    > "$TMP/case/swallowed-exception.md"
expect_problem "a required section may not be missing" "corrective_move is required"

new_case
sed 's|^violation_type: code:swallowed-exception$|violation_type: code:invented-type|' \
    "$GUIDES/swallowed-exception.md" > "$TMP/case/swallowed-exception.md"
expect_problem "violation_type must be catalogued" "is not catalogued"

new_case
cp "$GUIDES/swallowed-exception.md" "$TMP/case/swallowed-exception.python.extra.md"
expect_problem "at most one language suffix" "at most one"

new_case
mkdir -p "$TMP/case/nested"
expect_problem "guides must be flat" "no subdirectories"

new_case
{ cat "$GUIDES/swallowed-exception.md"; printf '\nStatus: done.\n'; } \
    | sed 's/Status: done./Status: done \xe2\x9c\x93/' > "$TMP/case/swallowed-exception.md"
expect_problem "guides use text markers, not emoji" "not emoji"

new_case
rm "$TMP/case/_uncoached.md"
expect_problem "the fallback guide must ship" "_uncoached.md must ship"

# A guide with no frontmatter is reported by name rather than crashing the run:
# one broken guide should not hide the state of the others.
new_case
printf 'no frontmatter here\n' > "$TMP/case/swallowed-exception.md"
expect_problem "an unparseable guide is reported" "missing frontmatter opening fence"

# But a scan that cannot be trusted at all must fail closed. A missing guides
# directory is not "no problems found"; it is a scan that did not happen.
scan "$TMP/definitely-absent"; scan_status=$?
out=$(cat "$TMP/out")
if [ "$scan_status" -ne 0 ] && ! scan_ok "$out"; then
    pass "a scan that cannot run fails closed"
else
    fail "a scan that cannot run fails closed" \
        "    scanner exited $scan_status and produced a COUNT line for a directory that does not exist"
fi

# ── the resolution contract ───────────────────────────────────────────────────
resolution=$(python3 - "$ROOT" <<'PY'
import json, sys
schema = json.load(open(f"{sys.argv[1]}/contracts/coaching-guide-v1.schema.json"))
order = schema["$defs"]["resolution"]["properties"]["order"]["const"]
expected = [
    ".weave/guides/<id>.<language>.md",
    ".weave/guides/<id>.md",
    "<package>/guides/<id>.<language>.md",
    "<package>/guides/<id>.md",
    "<package>/guides/_uncoached.md",
]
print("ORDER_OK" if order == expected else f"ORDER_BAD {order}")
props = schema["$defs"]["resolution"]["properties"]
print("FAILCLOSED_OK" if props["invalid_override"]["const"] == "fail_closed" else "FAILCLOSED_BAD")
PY
)
if [ -z "$resolution" ]; then
    fail "resolution contract is readable" "    schema read produced no output"
else
    printf '%s\n' "$resolution" | grep -q '^ORDER_OK$' \
        && pass "resolution order is project-language first, package fallback last" \
        || fail "resolution order is project-language first, package fallback last" \
            "    $(printf '%s\n' "$resolution" | grep '^ORDER_BAD' || echo 'order missing')"
    printf '%s\n' "$resolution" | grep -q '^FAILCLOSED_OK$' \
        && pass "an invalid project override fails closed" \
        || fail "an invalid project override fails closed" \
            "    invalid_override must be fail_closed, not a silent fall-through to the package guide"
fi

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
[ "$TESTS_FAILED" -eq 0 ]
