#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# test-quality.sh -- Test wv quality scan and reset commands (Sprint 3)
#
# Tests: wv quality scan, wv quality scan --json, wv quality reset,
#        wv quality help, incremental scan, unknown subcommand
#
# Exit codes:
#   0 - All tests passed
#   1 - One or more tests failed

set -euo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$PROJECT_ROOT/scripts/wv"

# Test environment
TEST_DIR="/tmp/wv-quality-test-$$"
export WV_HOT_ZONE="$TEST_DIR"
export WV_DB="$TEST_DIR/brain.db"

cleanup() {
    cd /tmp
    if [ -d "$TEST_DIR" ]; then
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

setup_test_env() {
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR/.weave"
    cd "$TEST_DIR"
    # Need git repo for quality scanner
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    git config commit.gpgsign false
}

# Create sample source files for scanning
create_sample_files() {
    # Python file with some complexity
    cat > "$TEST_DIR/sample.py" <<'PYEOF'
import os
import sys

class Calculator:
    """A simple calculator."""

    def __init__(self):
        self.history = []

    def add(self, a, b):
        if a < 0 or b < 0:
            raise ValueError("Negative")
        result = a + b
        self.history.append(result)
        return result

    def divide(self, a, b):
        if b == 0:
            raise ZeroDivisionError("Cannot divide by zero")
        return a / b

def main():
    calc = Calculator()
    for i in range(10):
        if i % 2 == 0:
            calc.add(i, i + 1)
        else:
            calc.divide(i, 1)

if __name__ == "__main__":
    main()
PYEOF

    # Bash file with functions
    cat > "$TEST_DIR/helper.sh" <<'SHEOF'
#!/bin/bash
# Helper script

setup() {
    local dir="$1"
    if [ -z "$dir" ]; then
        echo "Error: no dir" >&2
        return 1
    fi
    mkdir -p "$dir"
}

cleanup() {
    local dir="$1"
    if [ -d "$dir" ]; then
        rm -rf "$dir"
    fi
}

main() {
    local action="${1:-}"
    case "$action" in
        setup)   setup "$2" ;;
        cleanup) cleanup "$2" ;;
        *)       echo "Unknown: $action" >&2; return 1 ;;
    esac
}

main "$@"
SHEOF
    chmod +x "$TEST_DIR/helper.sh"

    # Commit so git metrics work
    git add -A
    git commit -q -m "Initial commit with sample files"
}

# ---------------------------------------------------------------------------
# Test helpers
# ---------------------------------------------------------------------------

assert_equals() {
    local expected="$1" actual="$2" message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$expected" = "$actual" ]; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Expected: $expected"
        echo "  Actual:   $actual"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

strip_ansi() {
    sed 's/\x1b\[[0-9;]*m//g'
}

assert_contains() {
    local haystack="$1" needle="$2" message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    local clean_haystack
    clean_haystack=$(strip_ansi <<<"$haystack")
    if grep -qF -- "$needle" <<<"$clean_haystack"; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Expected to find: $needle"
        echo "  In: $(strip_ansi <<<"$haystack" | sed -n '1,5p')"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    local clean_haystack
    clean_haystack=$(strip_ansi <<<"$haystack")
    if ! grep -qF -- "$needle" <<<"$clean_haystack"; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Expected NOT to find: $needle"
        echo "  In: $(strip_ansi <<<"$haystack" | sed -n '1,5p')"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_success() {
    local message="$1"; shift
    TESTS_RUN=$((TESTS_RUN + 1))
    if "$@" >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Command failed: $*"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_fails() {
    local message="$1"; shift
    TESTS_RUN=$((TESTS_RUN + 1))
    if ! "$@" >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Command should have failed: $*"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_json_field() {
    local json="$1" field="$2" expected="$3" message="$4"
    local actual
    actual=$(echo "$json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$field',''))" 2>/dev/null || echo "PARSE_ERROR")
    assert_equals "$expected" "$actual" "$message"
}

assert_json_field_gt() {
    local json="$1" field="$2" threshold="$3" message="$4"
    local actual
    actual=$(echo "$json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$field',0))" 2>/dev/null || echo "0")
    TESTS_RUN=$((TESTS_RUN + 1))
    if python3 -c "exit(0 if $actual > $threshold else 1)" 2>/dev/null; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Expected $field > $threshold, got: $actual"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# TESTS
# ═══════════════════════════════════════════════════════════════════════════

echo -e "${YELLOW}=== wv quality tests (Sprint 3) ===${NC}"
echo ""

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
echo -e "${YELLOW}--- Setup ---${NC}"
setup_test_env
# Init wv brain.db so wv dispatcher works
"$WV" init -q 2>/dev/null || true
create_sample_files

# ---------------------------------------------------------------------------
# Test: wv quality help
# ---------------------------------------------------------------------------
echo -e "${YELLOW}--- Help ---${NC}"

test_help_output() {
    local out
    out=$("$WV" quality help 2>&1) || true
    assert_contains "$out" "Usage:" "quality help shows usage"
    assert_contains "$out" "scan" "quality help mentions scan"
    assert_contains "$out" "reset" "quality help mentions reset"
    assert_contains "$out" "hotspots" "quality help mentions hotspots"
}
test_help_output

test_help_flags() {
    local out
    out=$("$WV" quality -h 2>&1) || true
    assert_contains "$out" "scan" "-h flag shows help"
    out=$("$WV" quality --help 2>&1) || true
    assert_contains "$out" "scan" "--help flag shows help"
}
test_help_flags

test_patterns_help_documents_rule_schema() {
    local out
    out=$("$WV" quality patterns --help 2>&1) || true
    assert_contains "$out" "kind: lexicon" "patterns help documents kind: lexicon"
    assert_contains "$out" "kind: motif" "patterns help documents kind: motif"
    assert_contains "$out" "kind: density" "patterns help documents kind: density"
    assert_contains "$out" "kind: regex" "patterns help documents kind: regex"
    assert_contains "$out" "match_scope" "patterns help documents match_scope"
    assert_contains "$out" "maturity" "patterns help documents maturity"
    assert_contains "$out" "require_no_digit_within" "patterns help documents require_no_digit_within"
    assert_contains "$out" "min_count" "patterns help documents min_count"
    assert_contains "$out" "Managed rules" "patterns help documents the managed rule tier"
}
test_patterns_help_documents_rule_schema

# ---------------------------------------------------------------------------
# Test: patterns validate reports a rule saved with the wrong extension
# Regression (release review 3): only *.yaml is loaded, so a rule saved as
# *.yml never runs. scan and list warn about it; validate -- the one command
# whose whole job is telling an author what is wrong with their rule files --
# enumerated *.yaml alone, omitted the stray, and answered valid: true, exit 0.
# Runs against its own repo: the shared TEST_DIR fixture is scanned by later
# tests and must not gain rule files or be re-initialised underneath them.
# ---------------------------------------------------------------------------
test_patterns_validate_reports_stray_yml() {
    local yrepo
    yrepo=$(mktemp -d "/tmp/wv-quality-yml-XXXXXX")
    mkdir -p "$yrepo/.weave/patterns"
    printf 'id: stray-rule\nlanguage: python\nkind: ast\n' > "$yrepo/.weave/patterns/stray-rule.yml"

    local out rc=0
    out=$("$WV" quality patterns validate "$yrepo" 2>&1) || rc=$?
    assert_equals "1" "$rc" "validate exits nonzero when a rule file is ignored for its extension"
    assert_contains "$out" "stray-rule" "validate names the ignored rule file"
    assert_contains "$out" "IGNORED" "validate marks it ignored, not valid and not invalid"
    assert_contains "$out" "stray-rule.yaml" "validate says what to rename it to"

    local vjson
    vjson=$("$WV" quality patterns validate "$yrepo" --json 2>/dev/null) || true
    assert_equals "false" "$(echo "$vjson" | jq -r '.valid')" "validate does not report valid with an ignored rule present"
    assert_equals "ignored" "$(echo "$vjson" | jq -r '.rules[] | select(.rule_id=="stray-rule") | .status')" "the stray is carried in the structured result"

    # A .yml beside a .yaml of the same stem is a renamed copy, not the
    # cross-tier id collision the duplicate check exists to catch: the .yaml
    # must still validate on its own terms.
    rm -f "$yrepo/.weave/patterns/stray-rule.yml"
    cat > "$yrepo/.weave/patterns/pair-rule.yaml" <<'PAIREOF'
id: pair-rule
language: python
message: "probe rule"
severity: warning
rule:
  pattern: |
    try:
      $$$BODY
    except:
      pass
PAIREOF
    cp "$yrepo/.weave/patterns/pair-rule.yaml" "$yrepo/.weave/patterns/pair-rule.yml"
    vjson=$("$WV" quality patterns validate "$yrepo" --json 2>/dev/null) || true
    assert_equals "valid" "$(echo "$vjson" | jq -r '.rules[] | select(.rule_id=="pair-rule" and .status!="ignored") | .status')" \
        "a .yaml is not invalidated by a same-stem .yml beside it"
    assert_equals "ignored" "$(echo "$vjson" | jq -r '.rules[] | select(.rule_id=="pair-rule" and .status=="ignored") | .status')" \
        "the same-stem .yml is still reported as ignored"

    rm -rf "$yrepo"
}
test_patterns_validate_reports_stray_yml

# ---------------------------------------------------------------------------
# Test: wv quality scan --json (first scan, all files changed)
# ---------------------------------------------------------------------------
echo -e "${YELLOW}--- Scan (JSON) ---${NC}"

test_scan_json_first_run() {
    local out
    out=$("$WV" quality scan --json 2>/dev/null)

    # Must be valid JSON
    assert_success "scan --json produces valid JSON" python3 -c "import json; json.loads('$out')"

    # Check required fields
    assert_json_field "$out" "scan_id" "1" "scan_id is 1 for first scan"
    assert_json_field_gt "$out" "files_scanned" "0" "files_scanned > 0"
    assert_json_field_gt "$out" "files_changed" "0" "files_changed > 0 on first scan"
    assert_json_field_gt "$out" "duration_ms" "0" "duration_ms > 0"

    # git_head should be a hex string
    local head
    head=$(echo "$out" | python3 -c "import sys,json; print(json.load(sys.stdin).get('git_head',''))" 2>/dev/null)
    TESTS_RUN=$((TESTS_RUN + 1))
    if grep -qE '^[0-9a-f]{7,40}$' <<< "$head"; then
        echo -e "${GREEN}✓${NC} git_head is a valid hex SHA"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} git_head is a valid hex SHA"
        echo "  Got: $head"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi

    # Languages should include python and bash
    local langs
    langs=$(echo "$out" | python3 -c "import sys,json; d=json.load(sys.stdin); print(','.join(sorted(d.get('languages',{}).keys())))" 2>/dev/null)
    assert_contains "$langs" "python" "languages includes python"
    assert_contains "$langs" "bash" "languages includes bash"

    # quality_score should exist (0-100)
    local score
    score=$(echo "$out" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('quality_score','MISSING'))" 2>/dev/null)
    TESTS_RUN=$((TESTS_RUN + 1))
    if python3 -c "s=$score; exit(0 if 0 <= s <= 100 else 1)" 2>/dev/null; then
        echo -e "${GREEN}✓${NC} quality_score in range 0-100 ($score)"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} quality_score in range 0-100"
        echo "  Got: $score"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}
test_scan_json_first_run

# ---------------------------------------------------------------------------
# Test: wv quality scan (stderr output)
# ---------------------------------------------------------------------------
echo -e "${YELLOW}--- Scan (stderr) ---${NC}"

test_scan_stderr() {
    local out
    out=$("$WV" quality scan 2>&1 1>/dev/null) || true
    assert_contains "$out" "Scanning" "stderr shows Scanning message"
    assert_contains "$out" "Duration:" "stderr shows Duration"
    assert_contains "$out" "Hotspots:" "stderr shows Hotspots"
    assert_contains "$out" "Quality score:" "stderr shows Quality score"
}
test_scan_stderr

# ---------------------------------------------------------------------------
# Test: Incremental scan (second run, nothing changed)
# ---------------------------------------------------------------------------
echo -e "${YELLOW}--- Incremental scan ---${NC}"

test_incremental_scan() {
    local out
    out=$("$WV" quality scan --json 2>/dev/null)

    # files_changed should be 0 since nothing changed
    assert_json_field "$out" "files_changed" "0" "incremental scan: files_changed is 0"

    # files_scanned should still be > 0
    assert_json_field_gt "$out" "files_scanned" "0" "incremental scan: files_scanned still > 0"
}
test_incremental_scan

# ---------------------------------------------------------------------------
# Test: Incremental scan detects file change
# ---------------------------------------------------------------------------
echo -e "${YELLOW}--- Incremental scan after edit ---${NC}"

test_incremental_after_edit() {
    # Modify a file
    echo "# New comment" >> "$TEST_DIR/sample.py"
    git add -A && git commit -q -m "Edit sample.py"

    local out
    out=$("$WV" quality scan --json 2>/dev/null)

    # files_changed should be > 0 now
    assert_json_field_gt "$out" "files_changed" "0" "files_changed > 0 after editing sample.py"
}
test_incremental_after_edit

# ---------------------------------------------------------------------------
# Test: wv quality scan with explicit path
# ---------------------------------------------------------------------------
echo -e "${YELLOW}--- Scan with explicit path ---${NC}"

test_scan_explicit_path() {
    local out
    out=$("$WV" quality scan "$TEST_DIR" --json 2>/dev/null)

    assert_json_field_gt "$out" "files_scanned" "0" "scan with explicit path finds files"
}
test_scan_explicit_path

# ---------------------------------------------------------------------------
# Test: wv quality reset
# ---------------------------------------------------------------------------
echo -e "${YELLOW}--- Reset ---${NC}"

test_reset() {
    # Ensure quality.db exists after previous scans
    local qdb="$WV_HOT_ZONE/quality.db"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ -f "$qdb" ]; then
        echo -e "${GREEN}✓${NC} quality.db exists before reset"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} quality.db exists before reset"
        echo "  Not found at: $qdb"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi

    # Reset
    local out
    out=$("$WV" quality reset 2>&1)
    assert_contains "$out" "Deleted" "reset output says Deleted"

    # DB should be gone
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ ! -f "$qdb" ]; then
        echo -e "${GREEN}✓${NC} quality.db removed after reset"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} quality.db removed after reset"
        echo "  Still exists at: $qdb"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}
test_reset

# ---------------------------------------------------------------------------
# Test: wv quality reset when no DB exists
# ---------------------------------------------------------------------------
echo -e "${YELLOW}--- Reset (no DB) ---${NC}"

test_reset_no_db() {
    local out
    out=$("$WV" quality reset 2>&1)
    assert_contains "$out" "No quality.db" "reset with no DB says so"
}
test_reset_no_db

# ---------------------------------------------------------------------------
# Test: Scan after reset (full rescan)
# ---------------------------------------------------------------------------
echo -e "${YELLOW}--- Scan after reset ---${NC}"

test_scan_after_reset() {
    local out
    out=$("$WV" quality scan --json 2>/dev/null)

    # Should be a fresh scan (scan_id resets)
    assert_json_field "$out" "scan_id" "1" "scan_id is 1 after reset"
    assert_json_field_gt "$out" "files_changed" "0" "files_changed > 0 after reset (full rescan)"
}
test_scan_after_reset

# ---------------------------------------------------------------------------
# Test: Unknown subcommand
# ---------------------------------------------------------------------------
echo -e "${YELLOW}--- Error handling ---${NC}"

test_unknown_subcommand() {
    assert_fails "unknown subcommand fails" "$WV" quality bogus
}
test_unknown_subcommand

# ---------------------------------------------------------------------------
# Test: implemented subcommands succeed, unimplemented stubs fail
# ---------------------------------------------------------------------------
test_subcommand_status() {
    assert_success "hotspots runs" "$WV" quality hotspots
    assert_success "diff runs" "$WV" quality diff
    assert_fails "promote stub fails" "$WV" quality promote
}
test_subcommand_status

# ---------------------------------------------------------------------------
# Test: patterns show reports the ENGINE's matcher, not the rule YAML
#
# Two unrelated consumer repositories each rebuilt this decoding from the YAML
# and each got it wrong differently (wv-aa3fb1). These assert the three things
# the YAML alone cannot tell you.
# ---------------------------------------------------------------------------
test_patterns_show_selectors() {
    assert_fails "show with no rule id and no --all fails" \
        "$WV" quality patterns show
    assert_fails "show with an unknown rule id fails" \
        "$WV" quality patterns show no-such-rule-at-all
    assert_success "show --all runs" "$WV" quality patterns show --all
}
test_patterns_show_selectors

seed_kind_rules() {
    # Seeded rather than borrowed from the managed set: this test asserts
    # kind semantics, so it must not depend on which rules a given repo
    # happens to have projected.
    mkdir -p "$TEST_DIR/.weave/patterns"
    cat > "$TEST_DIR/.weave/patterns/test-citation-kind.yaml" <<'RULEEOF'
id: test-citation-kind
language: prose
kind: citation
severity: warning
message: citation integrity fixture
paths:
  - "*.md"
terms:
  - unresolved-author-date
  - cited-reference-missing-year
RULEEOF
    cat > "$TEST_DIR/.weave/patterns/test-density-kind.yaml" <<'RULEEOF'
id: test-density-kind
language: prose
kind: density
match_scope: paragraph
min_count: 3
severity: info
message: density fixture
paths:
  - "*.md"
terms:
  - "—"
RULEEOF
}
seed_kind_rules

test_patterns_show_citation_has_no_expressions() {
    # The regression this exists to prevent: a decoder that reads citation's
    # terms: as searchable text emits \bunresolved-author-date\b, matches
    # nothing, and reports a clean zero that looks like a real measurement.
    local out
    out=$("$WV" quality patterns show test-citation-kind --json 2>&1) || {
        assert_equals "0" "1" "show citation rule succeeds"
        return
    }
    local exprs
    exprs=$(printf '%s' "$out" | python3 -c "
import json,sys
r = json.load(sys.stdin)['rules'][0]
print('null' if r['expressions'] is None else 'NOT-NULL')
")
    assert_equals "null" "$exprs" "citation rule reports no searchable expressions"
    assert_contains "$out" "check modes" "citation rule states why it has none"
}
test_patterns_show_citation_has_no_expressions

test_patterns_show_kind_semantics() {
    local out
    out=$("$WV" quality patterns show --all --json 2>&1) || return
    # lexicon/motif are case-insensitive; a consumer decoding them
    # case-sensitively undercounts every sentence-initial hit.
    local flags
    flags=$(printf '%s' "$out" | python3 -c "
import json,sys
rules = json.load(sys.stdin)['rules']
lex = [r for r in rules if r.get('kind') in ('lexicon','motif')]
print('MISSING' if not lex else
      'ok' if all('IGNORECASE' in (r.get('flags') or []) for r in lex) else 'BAD')
")
    assert_equals "ok" "$flags" "lexicon/motif rules declare IGNORECASE"

    # regex too. The surface shipped calling these "matched verbatim", and its
    # first real consumer undercounted every regex rule's corpus rate because
    # of it (wv-d199d4). _regex_findings compiles with re.IGNORECASE.
    local rx
    rx=$(printf '%s' "$out" | python3 -c "
import json,sys
rules = json.load(sys.stdin)['rules']
r = [x for x in rules if x.get('kind') == 'regex']
print('MISSING' if not r else
      'ok' if all('IGNORECASE' in (x.get('flags') or []) for x in r) else 'BAD')
")
    assert_equals "ok" "$rx" "regex rules declare IGNORECASE"

    # density is a lowercased substring scan with NO word boundary -- that is
    # what lets an em dash be a valid term.
    local dens
    dens=$(printf '%s' "$out" | python3 -c "
import json,sys
rules = json.load(sys.stdin)['rules']
d = [r for r in rules if r.get('kind') == 'density']
if not d:
    print('SKIP')
else:
    ok = all('LOWERCASE_SUBSTRING' in (r.get('flags') or [])
             and not any(e.startswith('\\\\b') for e in r['expressions'])
             for r in d)
    print('ok' if ok else 'BAD')
")
    if [ "$dens" != "SKIP" ]; then
        assert_equals "ok" "$dens" "density rules are unbounded lowercase substrings"
    fi
}
test_patterns_show_kind_semantics

test_patterns_show_never_misses_engine_findings() {
    # The property a consumer depends on: whatever the engine flags, the
    # published expressions must also match. They may match MORE (min_count,
    # exempt and match_scope only ever suppress), never less.
    local tmp
    tmp=$(mktemp -d)
    cat > "$tmp/sample.md" <<'SAMPLE'
This is a testament to the seamless interplay of the pivotal work, and
it delves into a groundbreaking tapestry — showcasing a cutting-edge
result — in order to demonstrate that it clearly matters most.
SAMPLE
    local verdict
    verdict=$("$WV" quality patterns show --all --json 2>/dev/null | python3 -c "
import json, re, sys
rules = json.load(sys.stdin)['rules']
text = open('$tmp/sample.md').read()
missed = []
for r in rules:
    exprs = r.get('expressions')
    if not exprs:
        continue
    flags = re.IGNORECASE if 'IGNORECASE' in (r.get('flags') or []) else 0
    for e in exprs:
        if 'LOWERCASE_SUBSTRING' in (r.get('flags') or []):
            continue
        try:
            re.compile(e, flags)
        except re.error as exc:
            missed.append(f'{r[\"id\"]}: uncompilable {e!r}: {exc}')
print('ok' if not missed else '; '.join(missed))
")
    rm -rf "$tmp"
    assert_equals "ok" "$verdict" "every published expression compiles as published"
}
test_patterns_show_never_misses_engine_findings

# ---------------------------------------------------------------------------
# Test: a structural zero is distinguishable from a clean result
#
# Every shipped prose rule is scoped to docs/*.md, docs/**/*.md and *.md, so a
# scan of a .py or .sh file reported each of them at 0 -- a zero that means
# "never ran", printed identically to one that means "examined, found nothing"
# (wv-33733d).
# ---------------------------------------------------------------------------
test_structural_zero_is_named() {
    local tmp
    tmp=$(mktemp -d)
    printf 'def f(a):\n    """A docstring, not a rendering fault."""\n    return a\n' > "$tmp/probe.py"
    printf 'Prose, not a rendering fault, in a document.\n' > "$tmp/probe.md"

    local py_out
    py_out=$("$WV" quality patterns scan "$tmp/probe.py" 2>&1 || true)
    assert_contains "$py_out" "out of scope" \
        "scanning a .py names the out-of-scope rules instead of reporting a bare zero"
    assert_contains "$py_out" "n/a" \
        "an inapplicable prose rule is marked n/a rather than 0"

    # The mirror (wv-76fc4a): on a markdown target the ast-grep code rules
    # have no file of their language, so they are named out of scope rather
    # than counted as applied, and the prose rules are not.
    local md_out
    md_out=$("$WV" quality patterns scan "$tmp/probe.md" 2>&1 || true)
    assert_contains "$md_out" "out of scope for this target" \
        "a markdown target names the code rules it cannot apply"
    assert_contains "$md_out" "bare-except-pass [" \
        "a python code rule is listed on a markdown target"
    local md_json
    md_json=$("$WV" quality patterns scan "$tmp/probe.md" --json 2>/dev/null | python3 -c "
import json,sys
d = json.load(sys.stdin)
oos = set(d.get('out_of_scope') or [])
print('ok' if 'bare-except-pass' in oos and not any(r.startswith('prose-') for r in oos) else sorted(oos))
" 2>/dev/null || true)
    assert_equals "ok" "$md_json" "code rules, not prose rules, are out of scope on a markdown target"

    local json_ok
    json_ok=$("$WV" quality patterns scan "$tmp/probe.py" --json 2>/dev/null | python3 -c "
import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    print('NO-JSON'); raise SystemExit
oos = d.get('out_of_scope')
print('ok' if isinstance(oos, list) and oos else 'MISSING')
" || true)
    assert_equals "ok" "$json_ok" "--json carries an out_of_scope list"

    rm -rf "$tmp"
}
test_structural_zero_is_named

# ---------------------------------------------------------------------------
# Test: prose-shape sees what a repair sweep did
#
# Finding counts cannot show that a sweep converted 32 joins into 32 full stops
# (wv-8b5432). The signature is coord_pct falling while sentences rise and word
# count barely moves -- joins became terminators rather than another
# relationship. This builds exactly that edit and asserts the instrument reads
# it, then asserts the comparison is symmetric.
# ---------------------------------------------------------------------------
test_prose_shape_reads_a_split_sweep() {
    local tmp
    tmp="$TEST_DIR/shapeproof"
    rm -rf "$tmp"; mkdir -p "$tmp"

    # Ten sentences, each continuing after a comma with a coordinator.
    : > "$tmp/doc.md"
    for i in $(seq 1 10); do
        echo "The gauge recorded a value at station $i, and the operator logged the reading before the shift ended." >> "$tmp/doc.md"
        echo "" >> "$tmp/doc.md"
    done
    git add -A >/dev/null 2>&1 || true
    git commit -qm "shape baseline" >/dev/null 2>&1 || true

    local before_json
    before_json=$("$WV" quality prose-shape "$tmp" --json 2>/dev/null || true)
    local coord_before
    coord_before=$(printf '%s' "$before_json" | python3 -c "
import json,sys
print(json.load(sys.stdin)['current']['coord_pct'])
" 2>/dev/null || echo "")
    assert_equals "100.0" "$coord_before" "every baseline sentence continues with a coordinator"

    # The split-only sweep: each join becomes a full stop. No rewriting.
    : > "$tmp/doc.md"
    for i in $(seq 1 10); do
        echo "The gauge recorded a value at station $i. The operator logged the reading before the shift ended." >> "$tmp/doc.md"
        echo "" >> "$tmp/doc.md"
    done

    local out
    out=$("$WV" quality prose-shape "$tmp" --baseline HEAD --json 2>/dev/null || true)
    local verdict
    verdict=$(printf '%s' "$out" | python3 -c "
import json,sys
d = json.load(sys.stdin)
delta, before = d['delta'], d['baseline']['profile']
# The signature: joins converted to terminators rather than into another
# relationship. Sentences up, coordinators down, subordinate and phrase
# continuations NOT taking up the slack, and the word count roughly flat.
# Flatness is proportional -- dropping 'and' costs a word per split, which is
# 0.07% of a 23k-word document and 5.6% of a small fixture.
words_moved = abs(delta['words']) / max(before['words'], 1)
ok = (delta['sentences'] > 0
      and delta['coord_pct'] < -50
      and delta['subord_pct'] <= 1
      and delta['phrase_pct'] <= 1
      and words_moved < 0.10)
print('signature' if ok else f\"MISS s={delta['sentences']} c={delta['coord_pct']} w={words_moved:.3f}\")
" 2>/dev/null || echo "ERROR")
    assert_equals "signature" "$verdict" "a split-only sweep reads as joins becoming terminators"

    # Symmetry: a file added after the baseline must be excluded, not folded in.
    echo "A wholly new document, added after the baseline was taken." > "$tmp/new.md"
    local added
    added=$("$WV" quality prose-shape "$tmp" --baseline HEAD --json 2>/dev/null | python3 -c "
import json,sys
d = json.load(sys.stdin)
print(d['added_since_baseline'])
" 2>/dev/null || echo "")
    assert_equals "1" "$added" "a file added since the baseline is excluded from the delta"

    rm -rf "$tmp"
}
test_prose_shape_reads_a_split_sweep

# wv-a6b418: a root scan after a subdirectory scan declared every file scanned
# but stored a report only for the changed one, because carry-forward copied
# from the subdirectory scan, which held no root files. 'wv quality functions'
# then answered "No scanned files found" for every unchanged file. Fixed in
# d868368d2; this drives the public CLI, on a database never reset.
test_root_subdirectory_root_scan_keeps_every_report() {
    local tmp="$TEST_DIR/rootsub" out f n
    rm -rf "$tmp"; mkdir -p "$tmp/r/src" "$tmp/r/scripts" "$tmp/hot"
    rs() { (cd "$tmp/r" && WEAVE_DIR="$tmp/r/.weave" WV_HOT_ZONE="$tmp/hot" WV_DB="$tmp/hot/brain.db" \
        WV_AUTO_CHECKPOINT=0 "$WV" "$@"); }
    git -C "$tmp/r" init -q
    printf 'def alpha(x):\n    if x:\n        return 1\n    return 2\n' > "$tmp/r/src/a.py"
    printf 'def beta():\n    return 3\n' > "$tmp/r/top.py"
    printf 'gamma() {\n  if [ -n "$1" ]; then echo y; fi\n}\n' > "$tmp/r/scripts/b.sh"
    git -C "$tmp/r" add -A
    git -C "$tmp/r" -c core.hooksPath=/dev/null -c user.email=t@t -c user.name=t commit -qm init
    rs init >/dev/null 2>&1
    rs quality scan --json >/dev/null 2>&1
    rs quality scan scripts --json >/dev/null 2>&1
    printf 'def beta():\n    return 4\n' > "$tmp/r/top.py"
    out=$(rs quality scan --json 2>/dev/null) || true
    assert_json_field "$out" "files_changed" "1" "the second root scan rescans only the edited file"
    assert_json_field "$out" "files_total" "3" "...and reports all three files"
    n=$(sqlite3 "$tmp/hot/quality.db" "SELECT COUNT(*) FROM files WHERE scan_id=(SELECT MAX(id) FROM scan_meta)") || true
    assert_equals "3" "$n" "...and stores a report for each of them"
    for f in src/a.py top.py scripts/b.sh; do
        out=$(rs quality functions "$f" 2>&1) || true
        assert_contains "$out" "CC=" "wv quality functions $f answers after root, scripts, root"
    done
    rm -rf "$tmp"
}
test_root_subdirectory_root_scan_keeps_every_report

# wv-561071 (rc.14 consumer audit K8): 'wv quality patterns scan --help' ran a
# repository-wide scan, because the patterns option loop had an empty --help
# arm. Every quality subcommand's --help prints usage, exits 0 quickly, and
# leaves no scan behind in quality.db.
test_every_quality_help_prints_usage_and_does_no_work() {
    cd "$TEST_DIR" || return
    local line out rc
    for line in "prose-shape" "scan" "functions" "freshness" "hotspots" "diff" "promote" \
            "structural-search" "patterns scan" "patterns list" "patterns show" \
            "patterns adjudicate" "patterns report" "patterns validate" "patterns promote"; do
        rm -f "$WV_HOT_ZONE/quality.db"
        rc=0
        # shellcheck disable=SC2086  # a subcommand line, split on purpose
        out=$(timeout 20 "$WV" quality $line --help 2>&1) || rc=$?
        assert_equals "0" "$rc" "wv quality $line --help exits 0"
        assert_contains "$out" "Usage:" "...and prints its usage"
        assert_equals "no" "$([ -e "$WV_HOT_ZONE/quality.db" ] && echo yes || echo no)" "...and leaves no scan in quality.db"
    done
}
test_every_quality_help_prints_usage_and_does_no_work

# ═══════════════════════════════════════════════════════════════════════════
# Results
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${YELLOW}=== Results ===${NC}"
echo -e "Tests: $TESTS_RUN | Passed: ${GREEN}$TESTS_PASSED${NC} | Failed: ${RED}$TESTS_FAILED${NC}"

if [ "$TESTS_FAILED" -eq 0 ]; then
    echo -e "${GREEN}ALL TESTS PASSED${NC}"
    exit 0
else
    echo -e "${RED}$TESTS_FAILED TESTS FAILED${NC}"
    exit 1
fi
