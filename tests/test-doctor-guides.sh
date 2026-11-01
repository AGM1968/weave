#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# test-doctor-guides.sh — wv doctor's guide-validity and guide-completeness
# records (wv-7730bd)
#
# The records are computed by 'python3 -m weave_quality.guides doctor', the
# shipped parser and resolver, from the module copy coaching selects. These
# cases drive 'wv doctor' end to end in a fixture project:
#   - healthy project, seeded example only, orphan guide (pass / pass / warn)
#   - an invalid guide whose filename carries a double quote: validity fails
#     and 'wv doctor --json' still parses (detail escaping)
#   - one guide with three faults names all three in one run (wv-273b2d)
#   - a python override coaching the wrong type fails in its own language
#   - a weave_quality/ decoy in the project root does not shadow the selected
#     copy (PYTHONSAFEPATH), and where an interpreter ignores that, the
#     module-identity check fails the record instead of trusting the decoy
#   - a doctor that crashes or prints an incomplete report fails both records
#   - so does a report whose entries have the wrong shape, while a well-formed
#     invalid entry fails validity alone (wv-13dec1)
#
# Exit codes:
#   0 - All tests passed
#   1 - Unexpected failure

set -euo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$PROJECT_ROOT/scripts/wv"
PKG_GUIDES="$PROJECT_ROOT/scripts/weave_quality/guides"

TEST_DIR="/tmp/wv-doctor-guides-fixture-$$"
export WV_HOT_ZONE="$TEST_DIR/hotzone"

cleanup() { cd /tmp && rm -rf "$TEST_DIR"; }
trap cleanup EXIT

setup_test_env() {
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR/repo/.weave/guides"
    cd "$TEST_DIR/repo"
}

# check_status <json> <check> -> the record's status, or "absent"
check_status() {
    printf '%s' "$1" | jq -r --arg c "$2" '[.checks[] | select(.check == $c) | .status][0] // "absent"'
}

check_detail() {
    printf '%s' "$1" | jq -r --arg c "$2" '[.checks[] | select(.check == $c) | .detail][0] // ""'
}

assert_eq() {
    local expected="$1" actual="$2" message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$expected" = "$actual" ]; then
        echo -e "  ${GREEN}[PASS]${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} $message (expected '$expected', got '$actual')"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if grep -qF -- "$needle" <<< "$haystack"; then
        echo -e "  ${GREEN}[PASS]${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} $message (expected '$needle' in '$haystack')"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# doctor_json -> wv doctor --json, which must parse: an unparsable report is a
# failure of its own, reported here rather than as a missing record.
doctor_json() {
    local out
    out=$("$WV" doctor --json 2>/dev/null || true)
    if ! printf '%s' "$out" | jq -e '.checks | type == "array"' >/dev/null 2>&1; then
        echo -e "  ${RED}[FAIL]${NC} wv doctor --json did not parse" >&2
        printf '%s\n' "$out" | tail -c 400 >&2
        TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1))
        printf '{"checks":[]}'
        return 0
    fi
    printf '%s' "$out"
}

# fake_python <body> — a project .venv interpreter, which wv prefers.
fake_python() {
    mkdir -p .venv/bin
    printf '#!/usr/bin/env bash\n%s\n' "$1" > .venv/bin/python3
    chmod +x .venv/bin/python3
}

plant_decoy() {
    mkdir -p weave_quality
    : > weave_quality/__init__.py
    # A healthy-shaped report from the wrong copy: only the module path betrays it.
    printf '%s\n' 'import json, pathlib' \
        'print(json.dumps({"canonical_types": 16, "project_guides_checked": 0, "invalid": [], "unresolved": [], "unused": [], "examples": [], "fallback_only": [], "module": str(pathlib.Path(__file__).resolve())}))' \
        > weave_quality/guides.py
}

# ─── Tests ──────────────────────────────────────────────────────────────────

test_healthy_project() {
    echo "-- no project guides -> validity pass, every canonical type coached"
    local out
    out=$(doctor_json)
    assert_eq "pass" "$(check_status "$out" guide-validity)" "guide-validity passes"
    assert_eq "pass" "$(check_status "$out" guide-completeness)" "guide-completeness passes"
    assert_contains "$(check_detail "$out" guide-completeness)" "canonical violation types coach through a guide of their own" "completeness states what it computed"
}

test_seeded_example_passes() {
    echo "-- the seeded example guide alone -> validity pass (unused by design)"
    cp "$PROJECT_ROOT/templates/authoring/guides/example-violation.md" .weave/guides/
    local out
    out=$(doctor_json)
    assert_eq "pass" "$(check_status "$out" guide-validity)" "seeded example does not warn"
}

test_orphan_guide_warns() {
    echo "-- a project guide no catalogued type selects -> validity warn"
    printf -- '---\nid: orphan-note\nviolation_type: code:swallowed-exception\nsummary: x\n---\n\n## Why\n\nx\n\n## Corrective move\n\nx\n' \
        > .weave/guides/orphan-note.md
    local out
    out=$(doctor_json)
    assert_eq "warn" "$(check_status "$out" guide-validity)" "orphan guide warns"
    assert_contains "$(check_detail "$out" guide-validity)" "orphan-note.md" "warning names the guide"
}

test_invalid_guide_with_quote_in_name() {
    echo "-- an invalid guide named with a double quote -> validity fail, --json still parses"
    printf 'no frontmatter\n' > '.weave/guides/bad"name.md'
    local out
    out=$(doctor_json)
    assert_eq "fail" "$(check_status "$out" guide-validity)" "invalid guide fails validity"
    assert_contains "$(check_detail "$out" guide-validity)" 'bad"name.md' "detail carries the file name intact"
}

test_invalid_guide_names_the_field() {
    echo "-- a consumer's pre-rc.14 guides -> validity fail names each failing field (wv-ba21bd)"
    # A repeated heading parsed until rc.13 (the second body replaced the first),
    # and an unknown frontmatter key went unread until rc.14's doctor parsed
    # every project guide. The detail listed file names only.
    printf -- '---\nid: legacy-note\nviolation_type: repo:hygiene\nsummary: x\n---\n\n## Why\n\nx\n\n## Corrective move\n\nx\n\n## Avoid\n\na\n\n## Avoid\n\nb\n' \
        > .weave/guides/legacy-note.md
    printf -- '---\nid: titled-note\ntitle: Old title\nviolation_type: repo:hygiene\nsummary: x\n---\n\n## Why\n\nx\n\n## Corrective move\n\nx\n' \
        > .weave/guides/titled-note.md
    local out detail
    out=$(doctor_json)
    detail=$(check_detail "$out" guide-validity)
    assert_eq "fail" "$(check_status "$out" guide-validity)" "invalid guides fail validity"
    assert_contains "$detail" "legacy-note.md: duplicate section 'Avoid'" "detail names the repeated section"
    assert_contains "$detail" "titled-note.md:3: unknown frontmatter 'title'" "detail names the unknown frontmatter key and its line"
}

test_three_faults_in_one_run() {
    echo "-- one guide with three faults -> one doctor run names all three (wv-273b2d)"
    # The parser stopped at its first fault, so a consumer's filler.md surfaced
    # its three one run at a time: fix one, run again, meet the next.
    printf -- '---\nid: three-faults\ntitle: Old title\nviolation_type: repo:hygiene\nsummary: x\n---\n\n## Why\n\nx\n\n## Corrective move\n\nx\n\n## Avoid\n\na\n\n## Avoid\n\nb\n\n## Extra\n\nc\n' \
        > .weave/guides/three-faults.md
    local out detail
    out=$(doctor_json)
    detail=$(check_detail "$out" guide-validity)
    assert_eq "fail" "$(check_status "$out" guide-validity)" "the guide fails validity"
    assert_contains "$detail" "three-faults.md:3: unknown frontmatter 'title'" "first fault: the unknown frontmatter key"
    assert_contains "$detail" "three-faults.md: duplicate section 'Avoid'" "second fault: the repeated section"
    assert_contains "$detail" "three-faults.md: unknown section 'Extra'" "third fault: the undeclared heading"
}

test_wrong_type_python_override() {
    echo "-- a parse-valid python override coaching the wrong type -> validity fail in its own language"
    sed 's/^violation_type: code:swallowed-exception$/violation_type: code:unsafe-subprocess/' \
        "$PKG_GUIDES/swallowed-exception.python.md" > .weave/guides/swallowed-exception.python.md
    local out
    out=$(doctor_json)
    assert_eq "fail" "$(check_status "$out" guide-validity)" "wrong-type override fails validity"
    assert_contains "$(check_detail "$out" guide-validity)" "code:swallowed-exception (python)" "detail names the type and language"
    assert_eq "pass" "$(check_status "$out" guide-completeness)" "generic completeness is unaffected"
}

test_cwd_decoy_does_not_shadow() {
    echo "-- a weave_quality/ decoy in the project root does not replace the selected copy"
    plant_decoy
    printf 'no frontmatter\n' > .weave/guides/broken.md
    local out
    out=$(doctor_json)
    # The decoy would report a clean bill; the real module sees broken.md.
    assert_eq "fail" "$(check_status "$out" guide-validity)" "the selected module ran, not the decoy"
    assert_contains "$(check_detail "$out" guide-validity)" "broken.md" "real module's findings are reported"
}

test_decoy_that_runs_is_refused() {
    echo "-- an interpreter that ignores PYTHONSAFEPATH runs the decoy -> both records fail (wrong copy)"
    plant_decoy
    fake_python "unset PYTHONSAFEPATH; exec python3 \"\$@\""
    local out
    out=$(doctor_json)
    assert_eq "fail" "$(check_status "$out" guide-validity)" "decoy report is refused"
    assert_contains "$(check_detail "$out" guide-validity)" "not the selected copy" "detail names the wrong copy"
    assert_eq "fail" "$(check_status "$out" guide-completeness)" "completeness is not computed from the decoy"
}

test_crashing_doctor_fails_closed() {
    echo "-- the guides doctor exits nonzero -> both records fail"
    fake_python 'exit 3'
    local out
    out=$(doctor_json)
    assert_eq "fail" "$(check_status "$out" guide-validity)" "nonzero exit fails validity"
    assert_eq "fail" "$(check_status "$out" guide-completeness)" "nonzero exit fails completeness"
}

test_incomplete_report_fails_closed() {
    echo "-- the guides doctor prints an incomplete report -> both records fail"
    fake_python "printf '{\"canonical_types\": 0}\\n'"
    local out
    out=$(doctor_json)
    assert_eq "fail" "$(check_status "$out" guide-validity)" "incomplete report fails validity"
    assert_contains "$(check_detail "$out" guide-validity)" "no complete report" "detail says the report was incomplete"
    assert_eq "fail" "$(check_status "$out" guide-completeness)" "incomplete report fails completeness"
}

# mutate_report <jq filter> — the real module runs and its report is rewritten:
# the module path stays the selected copy's, so only the filtered field is wrong.
mutate_report() {
    fake_python "if [[ \" \$* \" == *' weave_quality.guides '* ]]; then python3 \"\$@\" | jq -c '$1'; exit \"\${PIPESTATUS[0]}\"; fi; exec python3 \"\$@\""
}

test_malformed_entries_fail_closed() {
    echo "-- report entries of the wrong shape -> both records fail (wv-13dec1)"
    local f out
    mutate_report '.'
    out=$(doctor_json)
    assert_eq "pass pass" "$(check_status "$out" guide-validity) $(check_status "$out" guide-completeness)" \
        "control: the rewriting wrapper alone changes nothing"
    # An entry without its violations, or with none, renders nothing to fix.
    for f in '.invalid = [{}]' '.invalid = [42]' '.fallback_only = [null]' \
        '.invalid = [{"file": "broken.md", "error": "bad guide"}]' \
        '.invalid = [{"file": "broken.md", "error": "bad guide", "errors": []}]' \
        '.unresolved = [{"violation_type": "code:x", "language": null, "error": ""}]' \
        '.examples = [""]' '.project_guides_checked = -1' '.canonical_types = 1.5'; do
        mutate_report "$f"
        out=$(doctor_json)
        assert_eq "fail fail" "$(check_status "$out" guide-validity) $(check_status "$out" guide-completeness)" \
            "$f is refused"
    done
    assert_contains "$(check_detail "$out" guide-validity)" "no complete report" "detail says the report was incomplete"
}

test_wellformed_invalid_entry_fails_validity() {
    echo "-- a well-formed invalid entry -> validity fail, completeness unaffected"
    mutate_report '.invalid = [{"file": "broken.md", "error": "bad guide", "errors": ["bad guide"]}]'
    local out
    out=$(doctor_json)
    assert_eq "fail" "$(check_status "$out" guide-validity)" "a reported invalid guide fails validity"
    assert_contains "$(check_detail "$out" guide-validity)" "coaching would fail for: broken.md: bad guide" "detail names the guide and its error"
    assert_eq "pass" "$(check_status "$out" guide-completeness)" "completeness still passes"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    echo "test-doctor-guides.sh"
    echo ""

    setup_test_env; test_healthy_project
    setup_test_env; test_seeded_example_passes
    setup_test_env; test_orphan_guide_warns
    setup_test_env; test_invalid_guide_with_quote_in_name
    setup_test_env; test_invalid_guide_names_the_field
    setup_test_env; test_three_faults_in_one_run
    setup_test_env; test_wrong_type_python_override
    setup_test_env; test_cwd_decoy_does_not_shadow
    setup_test_env; test_decoy_that_runs_is_refused
    setup_test_env; test_crashing_doctor_fails_closed
    setup_test_env; test_incomplete_report_fails_closed
    setup_test_env; test_malformed_entries_fail_closed
    setup_test_env; test_wellformed_invalid_entry_fails_validity

    echo ""
    echo "========================================"
    echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
    echo "========================================"

    [ "$TESTS_FAILED" -eq 0 ] || exit 1
    exit 0
}

main "$@"
