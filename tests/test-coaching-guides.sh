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

# ── the declared-section extension ────────────────────────────────────────────
# The fixed four sections cannot express a violation type with named sub-forms
# or a corpus exemplars block, which is the shape nowcast's register guide grew
# into. A guide may declare extra section names in frontmatter; the vocabulary
# stays CLOSED around that declaration, and these controls are what says so.

# expect_clean <label> — the case directory must produce no PROBLEM at all.
expect_clean() {
    local label="$1" out status
    scan "$TMP/case"; status=$?
    out=$(cat "$TMP/out")
    if [ "$status" -ne 0 ] || ! scan_ok "$out"; then
        fail "$label" "    scanner crashed (exit $status) instead of validating the case"
        return
    fi
    if printf '%s\n' "$out" | grep -q '^PROBLEM'; then
        fail "$label" "$(printf '%s\n' "$out" | grep '^PROBLEM' | sed 's/^PROBLEM /    /')"
    else
        pass "$label"
    fi
}

# extended_guide <declaration> <heading> — swallowed-exception plus one extra
# section, written to the case directory.
extended_guide() {
    sed "s|^summary: |sections: $1\nsummary: |" "$GUIDES/swallowed-exception.md" \
        > "$TMP/case/swallowed-exception.md"
    { printf '\n## %s\n\n' "$2"
      printf 'Qualifiers stack until the sentence asserts nothing.\n'; } \
        >> "$TMP/case/swallowed-exception.md"
}

new_case
extended_guide "Clause accretion, the form the others hide behind" \
               "Clause accretion, the form the others hide behind"
expect_clean "a declared section is admitted"

new_case
extended_guide "Clause accretion, the form the others hide behind" "Something else entirely"
expect_problem "an undeclared section is still rejected" "must be declared in frontmatter"

new_case
sed 's|^summary: |sections: Exemplars from the corpus\nsummary: |' \
    "$GUIDES/swallowed-exception.md" > "$TMP/case/swallowed-exception.md"
expect_problem "a declaration the body never uses is rejected" "no such heading"

new_case
extended_guide "Avoid" "Avoid"
expect_problem "a declaration may not restate a fixed section" "never redefine it"

# The four shipped guides carry no declaration and must keep loading unchanged;
# earth-engine-analysis's six sit at exactly the fixed set for the same reason.
# The package scan above already covers that, so what is left is schema drift:
# a parser that grew the extension while the contract did not would go green on
# every control here.
extension=$(python3 - "$ROOT" <<'PY_SCHEMA'
import json, sys
schema = json.load(open(f"{sys.argv[1]}/contracts/coaching-guide-v1.schema.json"))
defs = schema["$defs"]
print("DECLARATION_OK" if "sections" in defs["frontmatter"]["properties"] else "DECLARATION_MISSING")
extended = defs.get("extended_sections", {})
props = extended.get("items", {}).get("properties", {})
print("EXTENDED_OK" if {"label", "body"} <= set(props) else "EXTENDED_MISSING")
print("CLOSED_OK" if defs["sections"]["additionalProperties"] is False else "CLOSED_BAD")
PY_SCHEMA
)
for check in DECLARATION:"frontmatter declares the extension" \
             EXTENDED:"the extended-section shape is contracted" \
             CLOSED:"the fixed section set stays closed"; do
    key="${check%%:*}"; label="${check#*:}"; label="${label%\"}"; label="${label#\"}"
    if printf '%s\n' "$extension" | grep -qxF -- "${key}_OK"; then
        pass "$label"
    else
        fail "$label" "    contracts/coaching-guide-v1.schema.json has drifted from guides.py"
    fi
done

# ── the authoring templates a consumer is handed ──────────────────────────────
# A guide template that no longer parses is worse than none: it teaches the
# shape the parser rejects, in the one repository least able to tell. And a
# manifest row pointing at a file that is not shipped seeds a consumer with a
# dangling destination, which wv-init-repo turns into a hard failure at init.
authoring=$(python3 - "$ROOT" <<'PY_AUTHORING'
import sys
from pathlib import Path

root = Path(sys.argv[1])
sys.path.insert(0, str(root / "scripts"))
from weave_quality.guides import GuideError, parse_guide  # noqa: E402

templates = root / "templates" / "authoring"
manifest = templates / "manifest.conf"
if not manifest.is_file():
    print("MANIFEST_MISSING")
    raise SystemExit(0)

rows = []
for line in manifest.read_text(encoding="utf-8").splitlines():
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    rows.append(line.split("|"))

problems = []
declared = set()
for row in rows:
    if len(row) != 4:
        problems.append(f"row is not <src>|<dst>|<mode>|<note>: {row}")
        continue
    src, dst, mode, note = (field.strip() for field in row)
    declared.add(src)
    if not (templates / src).is_file():
        problems.append(f"manifest names a template that is not shipped: {src}")
    if mode not in {"seed", "refresh"}:
        problems.append(f"{src}: unknown mode {mode!r}")
    if not note:
        problems.append(f"{src}: no note, so init-repo would print a bare path")
    if dst.startswith("/") or ".." in dst:
        problems.append(f"{src}: unsafe destination {dst!r}")
    # Prose about a class belongs beside the resolution directory, never in it.
    if dst.startswith(".weave/guides/") and not dst.endswith(".md"):
        problems.append(f"{src}: {dst!r} is not a guide but lands among guides")

present = {
    str(path.relative_to(templates))
    for path in templates.rglob("*")
    if path.is_file() and path.name != "manifest.conf"
}
for orphan in sorted(present - declared):
    problems.append(f"template is shipped but unmanifested: {orphan}")

# Every guide template must satisfy the parser that will resolve it.
for src in sorted(declared):
    path = templates / src
    if not path.is_file() or not str(Path(src).parent) == "guides":
        continue
    if path.name == "README.md":
        continue
    try:
        parse_guide(path, "project")
    except GuideError as exc:
        problems.append(f"guide template does not parse: {exc}")

for problem in problems:
    print("PROBLEM " + problem)
print(f"COUNT {len(rows)}")
PY_AUTHORING
)
if ! printf '%s\n' "$authoring" | grep -q '^COUNT '; then
    fail "authoring templates validate" "    check produced no COUNT line:
$(printf '%s\n' "$authoring" | sed 's/^/    /')"
elif printf '%s\n' "$authoring" | grep -q '^PROBLEM'; then
    fail "authoring templates validate" \
        "$(printf '%s\n' "$authoring" | grep '^PROBLEM' | sed 's/^PROBLEM /    /')"
else
    pass "authoring templates validate ($(printf '%s\n' "$authoring" | awk '/^COUNT/{print $2}') manifest rows)"
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
