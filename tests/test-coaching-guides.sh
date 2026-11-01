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
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)

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
    if grep -qF -- "$fragment" <<< "$out"; then
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
# Refused by name: a crash further in also exits nonzero without a COUNT line,
# which let the scanner lose its own check unnoticed (wv-e07ee4).
scan "$TMP/definitely-absent"; scan_status=$?
out=$(cat "$TMP/out")
if [ "$scan_status" -ne 0 ] && ! scan_ok "$out" && grep -q 'not a guides directory' <<< "$out" \
        && ! grep -q Traceback <<< "$out"; then
    pass "a scan that cannot run fails closed"
else
    fail "a scan that cannot run fails closed" \
        "    scanner exited $scan_status for a directory that does not exist; output:
$(sed 's/^/    /' <<< "$out" | tail -3)"
fi

# ── the declared-section extension ────────────────────────────────────────────
# The fixed four sections cannot express a violation type with named sub-forms
# or a corpus exemplars block, which is the shape one consumer's register guide grew
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
    if grep -q '^PROBLEM' <<< "$out"; then
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

# A consumer's filler guide (wv-964548): a colon in a declared name was refused
# with "is not a section name", which named no rule, and its comma-separated
# declaration read as one name. Owner ruling 2026-10-29: colons are prose.
new_case
extended_guide "Procedure: author-comparable review" "Procedure: author-comparable review"
expect_clean "a declared name may hold a colon"

new_case
extended_guide "Exemplars *from* the corpus" "Exemplars *from* the corpus"
expect_problem "a refused name states what a name may hold" "separate names with |"

new_case
extended_guide "Navigation pointers, Procedure: review" "Navigation pointers"
expect_problem "a comma-separated declaration is told to use |" "(a comma does not separate names; use |)"

# Violations are collected, not raised at the first (wv-273b2d), so a refused
# declaration's heading must not be reported a second time as undeclared.
new_case
extended_guide "Exemplars *from* the corpus" "Exemplars *from* the corpus"
scan "$TMP/case"; out=$(cat "$TMP/out")
if grep -qF "separate names with |" <<< "$out" && ! grep -qF "must be declared in frontmatter" <<< "$out"; then
    pass "a refused declaration is reported once, not again at its heading"
else
    fail "a refused declaration is reported once, not again at its heading" "$(sed 's/^/    /' <<< "$out")"
fi

# A repeated frontmatter key kept the last value and dropped the first.
new_case
sed 's|^summary: \(.*\)$|summary: \1\nsummary: a second summary|' "$GUIDES/swallowed-exception.md" \
    > "$TMP/case/swallowed-exception.md"
expect_problem "a repeated frontmatter key is rejected" "frontmatter 'summary' appears twice"

# The parser's name pattern and both coaching schemas' label patterns are one
# rule written three times; they move together or not at all.
parity=$(python3 - "$ROOT" <<'PY_PARITY'
import json, sys
sys.path.insert(0, f"{sys.argv[1]}/scripts")
from weave_quality.guides import SECTION_NAME_PATTERN
guide = json.load(open(f"{sys.argv[1]}/contracts/coaching-guide-v1.schema.json"))
response = json.load(open(f"{sys.argv[1]}/contracts/coaching-response-v1.schema.json"))
found = []
def walk(node):
    if isinstance(node, dict):
        label = node.get("label")
        if isinstance(label, dict) and "pattern" in label:
            found.append(label["pattern"])
        for value in node.values():
            walk(value)
    elif isinstance(node, list):
        for value in node:
            walk(value)
walk(guide); walk(response)
print("PARITY_OK" if len(found) == 2 and set(found) == {SECTION_NAME_PATTERN.pattern} else f"PARITY_BAD {found}")
PY_PARITY
)
if [ "$parity" = "PARITY_OK" ]; then
    pass "the schemas' label pattern is the parser's section-name pattern"
else
    fail "the schemas' label pattern is the parser's section-name pattern" "    $parity"
fi

# The four shipped guides carry no declaration and must keep loading unchanged;
# another consumer's six sit at exactly the fixed set for the same reason.
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
    if grep -qxF -- "${key}_OK" <<< "$extension"; then
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
if ! grep -q '^COUNT ' <<< "$authoring"; then
    fail "authoring templates validate" "    check produced no COUNT line:
$(printf '%s\n' "$authoring" | sed 's/^/    /')"
elif grep -q '^PROBLEM' <<< "$authoring"; then
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
    grep -q '^ORDER_OK$' <<< "$resolution" \
        && pass "resolution order is project-language first, package fallback last" \
        || fail "resolution order is project-language first, package fallback last" \
            "    $(printf '%s\n' "$resolution" | grep '^ORDER_BAD' || echo 'order missing')"
    grep -q '^FAILCLOSED_OK$' <<< "$resolution" \
        && pass "an invalid project override fails closed" \
        || fail "an invalid project override fails closed" \
            "    invalid_override must be fail_closed, not a silent fall-through to the package guide"
fi

# ── doctor report (wv-7730bd): what wv doctor records, from the shipped code ──
echo ""
echo "doctor report"
gdoc() {  # gdoc <project-root> [catalog] -> JSON on stdout, exit status in $GDOC_RC
    GDOC_RC=0
    PYTHONPATH="$ROOT/scripts" python3 -m weave_quality.guides doctor --project-root "$1" \
        --package-dir "$ROOT/scripts/weave_quality/guides" ${2:+--catalog "$2"} > "$TMP/gdoc.json" 2>&1 || GDOC_RC=$?
}
dp="$TMP/doctor-proj"
mkdir -p "$dp/.weave/guides"
gdoc "$dp"
[ "$GDOC_RC" -eq 0 ] && jq -e '.invalid == [] and .unresolved == [] and .fallback_only == [] and .canonical_types > 0' "$TMP/gdoc.json" >/dev/null \
    && pass "doctor: a project with no overrides reports every canonical type coached by its own guide" \
    || fail "doctor: a project with no overrides reports every canonical type coached by its own guide" "$(cat "$TMP/gdoc.json")"
# A Python-specific override that parses but coaches the wrong type: only a
# resolution in its own language context selects it.
sed 's/^violation_type: code:swallowed-exception$/violation_type: code:unsafe-subprocess/' \
    "$ROOT/scripts/weave_quality/guides/swallowed-exception.python.md" > "$dp/.weave/guides/swallowed-exception.python.md"
gdoc "$dp"
[ "$GDOC_RC" -eq 0 ] && jq -e '.invalid == [] and (.unresolved | length) == 1
    and .unresolved[0].violation_type == "code:swallowed-exception" and .unresolved[0].language == "python"' "$TMP/gdoc.json" >/dev/null \
    && pass "doctor: a parse-valid python override coaching the wrong type is unresolved in its own language" \
    || fail "doctor: a parse-valid python override coaching the wrong type is unresolved in its own language" "$(cat "$TMP/gdoc.json")"
jq -e '.fallback_only == [] and ([.unresolved[] | select(.language == null)] | length) == 0' "$TMP/gdoc.json" >/dev/null \
    && pass "doctor: ...while generic resolution of every canonical type stays healthy" \
    || fail "doctor: ...while generic resolution of every canonical type stays healthy" "$(cat "$TMP/gdoc.json")"
rm -f "$dp/.weave/guides/swallowed-exception.python.md"
# A file that is not UTF-8 is one invalid guide, not a lost report.
printf '\xff\xfe---\n' > "$dp/.weave/guides/filler.md"
gdoc "$dp"
[ "$GDOC_RC" -eq 0 ] && jq -e '[.invalid[] | select(.file == "filler.md" and (.error | test("UTF-8")))] | length == 1' "$TMP/gdoc.json" >/dev/null \
    && pass "doctor: a guide that is not UTF-8 is reported invalid, and the report survives" \
    || fail "doctor: a guide that is not UTF-8 is reported invalid, and the report survives" "$(cat "$TMP/gdoc.json")"
rm -f "$dp/.weave/guides/filler.md"
# Three faults in one override are three violations in one run, not the first
# of them (wv-273b2d). The coaching path resolves through the same parser, so it
# refuses with the same three: the unresolved entry is resolve()'s own error.
printf -- '---\nid: swallowed-exception\ntitle: Old title\nviolation_type: code:swallowed-exception\nsummary: x\n---\n\n## Why\n\nx\n\n## Corrective move\n\nx\n\n## Avoid\n\na\n\n## Avoid\n\nb\n\n## Extra\n\nc\n' \
    > "$dp/.weave/guides/swallowed-exception.md"
gdoc "$dp"
[ "$GDOC_RC" -eq 0 ] && jq -e '.invalid | length == 1 and (.[0].errors | length == 3
    and (.[0] | test(":3: unknown frontmatter .title.$")) and (.[1] | test("duplicate section .Avoid."))
    and (.[2] | test("unknown section .Extra.")))' "$TMP/gdoc.json" >/dev/null \
    && pass "doctor: a guide with three faults reports all three, in file order" \
    || fail "doctor: a guide with three faults reports all three, in file order" "$(cat "$TMP/gdoc.json")"
# Equality alone held before the fix too, both sides carrying the first fault.
[ "$GDOC_RC" -eq 0 ] && jq -e '.invalid[0].error as $e
    | [.unresolved[] | select(.violation_type == "code:swallowed-exception" and .language == null)]
    | length == 1 and .[0].error == $e
    and ($e | test("frontmatter .title.") and test("section .Avoid.") and test("section .Extra."))' "$TMP/gdoc.json" >/dev/null \
    && pass "doctor: the coaching resolution refuses the guide with the same three" \
    || fail "doctor: the coaching resolution refuses the guide with the same three" "$(cat "$TMP/gdoc.json")"
rm -f "$dp/.weave/guides/swallowed-exception.md"
# A project guide serving no catalogued type is reported unused.
printf -- '---\nid: orphan-note\nviolation_type: code:swallowed-exception\nsummary: x\n---\n\n## Why\n\nx\n\n## Corrective move\n\nx\n' \
    > "$dp/.weave/guides/orphan-note.md"
gdoc "$dp"
[ "$GDOC_RC" -eq 0 ] && jq -e '.unused == ["orphan-note.md"]' "$TMP/gdoc.json" >/dev/null \
    && pass "doctor: a project guide no catalogued type selects is reported unused" \
    || fail "doctor: a project guide no catalogued type selects is reported unused" "$(cat "$TMP/gdoc.json")"
rm -f "$dp/.weave/guides/orphan-note.md"
# The seeded example is listed apart from unused, but only while its type is
# uncatalogued: the same id coaching a real type is a misnamed guide.
cp "$ROOT/templates/authoring/guides/example-violation.md" "$dp/.weave/guides/"
gdoc "$dp"
[ "$GDOC_RC" -eq 0 ] && jq -e '.unused == [] and .examples == ["example-violation.md"]' "$TMP/gdoc.json" >/dev/null \
    && pass "doctor: the seeded example guide is listed as an example, not unused" \
    || fail "doctor: the seeded example guide is listed as an example, not unused" "$(cat "$TMP/gdoc.json")"
sed -i 's/^violation_type: .*/violation_type: code:swallowed-exception/' "$dp/.weave/guides/example-violation.md"
gdoc "$dp"
jq -e '.unused == ["example-violation.md"] and .examples == []' "$TMP/gdoc.json" >/dev/null \
    && pass "doctor: the example id coaching a catalogued type is reported unused" \
    || fail "doctor: the example id coaching a catalogued type is reported unused" "$(cat "$TMP/gdoc.json")"
rm -f "$dp/.weave/guides/example-violation.md"
# The report names the module copy that produced it, for the wrong-copy check.
gdoc "$dp"
jq -e --arg m "$(readlink -f "$ROOT/scripts/weave_quality/guides.py")" '.module == $m' "$TMP/gdoc.json" >/dev/null \
    && pass "doctor: the report names the module file that computed it" \
    || fail "doctor: the report names the module file that computed it" "$(cat "$TMP/gdoc.json")"
# A malformed catalogue fails the check; it is never an empty universe.
for shape in '{}' '{"types":{"code:swallowed-exception":"malformed"}}' '{"types":{"x:y":{"status":"legacy","guide":"x"}}}' 'not json'; do
    printf '%s' "$shape" > "$TMP/catalog.json"
    gdoc "$dp" "$TMP/catalog.json"
    [ "$GDOC_RC" -eq 2 ] && jq -e '.code == "catalog_unreadable"' "$TMP/gdoc.json" >/dev/null \
        && pass "doctor: catalogue $shape fails with catalog_unreadable" \
        || fail "doctor: catalogue $shape fails with catalog_unreadable" "    rc=$GDOC_RC $(cat "$TMP/gdoc.json")"
done
# One bad entry in an otherwise healthy catalogue fails the check too, never a
# smaller universe (wv-b303c9). The real catalogue, with one entry rewritten.
cat_with() {  # cat_with <jq filter on the swallowed-exception entry> -> $TMP/catalog.json
    jq --arg t code:swallowed-exception ".types[\$t] |= ($1)" "$ROOT/contracts/violation-vocabulary-v1.json" > "$TMP/catalog.json"
}
n_canon=$(jq '[.types[] | select(.status == "canonical")] | length' "$ROOT/contracts/violation-vocabulary-v1.json")
cat_with '.guide = "nonexistent-guide"'
gdoc "$dp" "$TMP/catalog.json"
[ "$GDOC_RC" -eq 0 ] && jq -e --argjson n "$n_canon" '.canonical_types == $n and .fallback_only == ["code:swallowed-exception"]' "$TMP/gdoc.json" >/dev/null \
    && pass "doctor: control: a canonical type whose guide is missing is reported fallback-only" \
    || fail "doctor: control: a canonical type whose guide is missing is reported fallback-only" "    rc=$GDOC_RC $(cat "$TMP/gdoc.json")"
cat_with '.status = "canoncial" | .guide = "nonexistent-guide"'
gdoc "$dp" "$TMP/catalog.json"
[ "$GDOC_RC" -eq 2 ] && jq -e '.code == "catalog_unreadable" and (.error | test("unsupported status"))' "$TMP/gdoc.json" >/dev/null \
    && pass "doctor: a misspelled status fails the catalogue instead of dropping the type" \
    || fail "doctor: a misspelled status fails the catalogue instead of dropping the type" "    rc=$GDOC_RC $(cat "$TMP/gdoc.json")"
cat_with '.status = "legacy"'
gdoc "$dp" "$TMP/catalog.json"
[ "$GDOC_RC" -eq 0 ] && jq -e --argjson n "$((n_canon - 1))" '.canonical_types == $n' "$TMP/gdoc.json" >/dev/null \
    && pass "doctor: control: a supported reclassification leaves coverage one type smaller" \
    || fail "doctor: control: a supported reclassification leaves coverage one type smaller" "    rc=$GDOC_RC $(cat "$TMP/gdoc.json")"
for g in 'Swallowed.Exception' '_uncoached' '../swallowed-exception'; do
    cat_with ".guide = \"$g\""
    gdoc "$dp" "$TMP/catalog.json"
    [ "$GDOC_RC" -eq 2 ] && jq -e '.code == "catalog_unreadable" and (.error | test("guide basename"))' "$TMP/gdoc.json" >/dev/null \
        && pass "doctor: catalogue guide basename $g fails the catalogue" \
        || fail "doctor: catalogue guide basename $g fails the catalogue" "    rc=$GDOC_RC $(cat "$TMP/gdoc.json")"
done
# An unlistable guides directory fails the check rather than reading as empty.
if [ "$(id -u)" -ne 0 ]; then
    chmod 000 "$dp/.weave/guides"
    gdoc "$dp"
    chmod 755 "$dp/.weave/guides"
    [ "$GDOC_RC" -eq 2 ] && jq -e '.error | test("cannot be")' "$TMP/gdoc.json" >/dev/null \
        && pass "doctor: an unreadable guides directory fails the check" \
        || fail "doctor: an unreadable guides directory fails the check" "    rc=$GDOC_RC $(cat "$TMP/gdoc.json")"
fi

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
[ "$TESTS_FAILED" -eq 0 ]
