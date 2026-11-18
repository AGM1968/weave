#!/usr/bin/env bash
# shellcheck disable=SC2016  # the patterns under test are literal shell text containing $; they must not expand here
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# test-assert-helper-safety.sh — grep patterns that come from a variable must
# carry an option barrier, in tests AND in production shell.
#
# A value beginning with "-" is parsed as OPTIONS, not as the pattern:
#   positive assertion  -> false negative (reports "not found" for text that is there)
#   negative assertion  -> silent false PASS (grep errors, `!` turns that into success)
#   production branch   -> silently takes the wrong path
#
# Barriers differ by command, which is what hid the git cases:
#   grep      `--` ends option parsing; `-e`/`-f` also bind the pattern
#   git grep  `--` separates PATHS. Only `-e`/`-f` bind the pattern.
#
# The scan lives in tests/lib/grep-safety-scan.py. This file additionally
# proves the SCANNER itself recognises every form -- lowercase, uppercase,
# braced, composite and git grep -- because a scanner is exactly the kind of
# thing that passes while covering one shape.
#
# Exit codes: 0 all checks pass, 1 otherwise.

set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCANNER="$SCRIPT_DIR/lib/grep-safety-scan.py"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
TESTS_RUN=0; TESTS_PASSED=0; TESTS_FAILED=0
pass() { TESTS_RUN=$((TESTS_RUN+1)); TESTS_PASSED=$((TESTS_PASSED+1)); echo -e "  ${GREEN}✓${NC} $1"; }
fail() { TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAILED=$((TESTS_FAILED+1)); echo -e "  ${RED}✗${NC} $1"; [ -n "${2:-}" ] && echo "$2"; }

echo "=== grep pattern option-barrier safety ==="
echo ""

if [ ! -x "$SCANNER" ]; then
    fail "scanner is present and executable" "    missing: $SCANNER"
    echo "Results: $TESTS_PASSED/$TESTS_RUN passed"; exit 1
fi
pass "scanner is present and executable"

# ── 1. The scanner recognises every unsafe FORM, and no safe one ─────────────
# Without this the suite would prove only that whatever shape the scanner
# happens to match is absent -- which is how the first version of this audit
# reported 7/7 while missing composite, braced and git grep patterns entirely.
# Fixtures are checked in under tests/fixtures/grep-safety/ rather than written
# inline: an inline heredoc would put deliberately-unsafe lines into this file's
# own source, where the repository scan below would flag them. The scanner skips
# any fixtures/ directory for the same reason.
FIXTURE="$SCRIPT_DIR/fixtures/grep-safety"
assert_form() {
    local label="$1" form="$2" out
    # Capture, then match. The scanner exits 1 BY DESIGN when it reports hits,
    # and this suite runs under `set -o pipefail`, so piping it into grep made
    # every one of these assertions fail even when the form was found.
    out=$(python3 "$SCANNER" "$FIXTURE/unsafe.sh" 2>/dev/null || true)
    if grep -qF -- "$form" <<<"$out"; then
        pass "scanner detects $label"
    else
        fail "scanner detects $label" "    not reported: $form"
    fi
}
assert_form "a lowercase \$var pattern"       '"$lower"'
assert_form "an UPPERCASE \$VAR pattern"      '"$UPPER"'
assert_form "a \${braced} pattern"            '"${braced}"'
assert_form "a composite \"\$a|\$b\" pattern" '"$alpha|$beta"'
assert_form "a git grep pattern"              '"$marker_ere"'
assert_form "a barrier arriving AFTER the pattern" '"$after_barrier"'
assert_form "a line-continued grep"           '"$continued"'
assert_form "a line-continued git grep"       '"$git_continued"'
SAFE_FOUND=$(python3 "$SCANNER" "$FIXTURE/safe.sh" 2>/dev/null | grep -c ':[0-9]*:' || true)
if [ "$SAFE_FOUND" = "0" ]; then
    pass "scanner reports nothing for barriered, literal and anchored forms"
else
    fail "scanner reports nothing for barriered, literal and anchored forms" \
        "$(python3 "$SCANNER" "$FIXTURE/safe.sh" 2>/dev/null | sed 's/^/    /')"
fi

# ── 1b. Discovery reaches shell files with no .sh suffix ─────────────────────
# scripts/wv, scripts/wv-test and scripts/wv-battery-wrapper are shipped entry
# points with no extension. Selecting files on the suffix alone excluded them
# from every production-wide claim this audit makes.
EXTLESS=$(mktemp -d)
printf '#!/usr/bin/env bash\ngrep -q "$extensionless" file\n' > "$EXTLESS/toolname"
chmod +x "$EXTLESS/toolname"
EXT_OUT=$(python3 "$SCANNER" "$EXTLESS" 2>/dev/null || true)
if grep -qF -- '"$extensionless"' <<<"$EXT_OUT"; then
    pass "directory traversal reaches an extensionless shell file"
else
    fail "directory traversal reaches an extensionless shell file" \
        "    scanned $EXTLESS and reported: ${EXT_OUT:-nothing}"
fi
rm -rf "$EXTLESS"

# ── 2. The repository is clean under that scanner ────────────────────────────
REPO_HITS=$(python3 "$SCANNER" "$REPO_ROOT/scripts" "$REPO_ROOT/install.sh" "$REPO_ROOT/tests" 2>/dev/null | grep -v '^---' || true)
if [ -z "$REPO_HITS" ]; then
    pass "no grep in tests or production takes a variable pattern without a barrier"
else
    fail "no grep in tests or production takes a variable pattern without a barrier" \
"$(printf '%s\n' "$REPO_HITS" | sed 's/^/    /')
    grep: use  grep -qF -- \"\$pattern\"
    git grep: use  git grep -e \"\$pattern\" -- paths   (-- there means PATHS)"
fi

# ── 3. Behavioural: the prescribed shape holds in both directions ────────────
probe_contains()     { grep -qF -- "$2" <<<"$1"; }
probe_not_contains() { ! grep -qF -- "$2" <<<"$1"; }
HAY=$(printf 'alpha\n- Next ready: wv-bbbbbb\nomega\n')
probe_contains "$HAY" "- Next ready: wv-bbbbbb" \
    && pass "a leading-dash needle is found when present" \
    || fail "a leading-dash needle is found when present"
probe_not_contains "$HAY" "- absent needle" \
    && pass "a leading-dash needle is reported absent when absent" \
    || fail "a leading-dash needle is reported absent when absent"
# The false-PASS case itself: the negative form must REJECT a present needle.
if probe_not_contains "$HAY" "- Next ready: wv-bbbbbb"; then
    fail "the negative form rejects a leading-dash needle that IS present" \
        "    it passed, which is the vacuous success this file exists to prevent"
else
    pass "the negative form rejects a leading-dash needle that IS present"
fi
probe_contains "abc" "a.c" \
    && fail "a regex metacharacter is matched literally" "    'a.c' matched 'abc'" \
    || pass "a regex metacharacter is matched literally"

# ── 4. Early-exit pipelines under pipefail (wv-a70659) ──────────────────────
# `writer | grep -q PAT` under pipefail returns 141 when the pattern MATCHES:
# grep leaves at the first hit, the writer takes SIGPIPE, pipefail promotes it.
# A match therefore reports failure -- never a false pass, but a timing-
# dependent false failure, which is how it presented as the rc.12 "45 of 46"
# flake. The fix throughout is the shape this very file uses above: capture,
# then match on a herestring, so there is no writer process left to signal.
PIPE_SCANNER="$SCRIPT_DIR/lib/pipe-safety-scan.py"
PIPE_FIXTURE="$SCRIPT_DIR/fixtures/pipe-safety"

assert_pipe_form() {
    local label="$1" form="$2" out
    out=$(python3 "$PIPE_SCANNER" "$PIPE_FIXTURE/unsafe.sh" 2>/dev/null || true)
    if grep -qF -- "$form" <<<"$out"; then
        pass "pipe scanner detects $label"
    else
        fail "pipe scanner detects $label" "    not reported: $form"
    fi
}
assert_pipe_form "grep -q"            "grep -q 'needle'"
assert_pipe_form "a bundled grep -qF" "grep -qF 'needle'"
assert_pipe_form "grep -l"            "grep -l 'needle'"
assert_pipe_form "grep -m N"          "grep -m 1 'needle'"
assert_pipe_form "head -N"            "head -5"
assert_pipe_form "head -n N"          "head -n 20"
assert_pipe_form "sed with a q command" "sed 2q"
assert_pipe_form "sed -n with ;q"     "sed -n '1p;q'"
assert_pipe_form "the read builtin"   "read -r line"
assert_pipe_form "a negated pipeline" "! producer | grep -q 'needle'"
assert_pipe_form "a line-continued pipeline" "grep -q 'continued across lines'"
# A trailing | continues the pipeline without a backslash (wv-29452e): the
# scanner joined only backslashes, and such a pipeline flaked the pre-push gate.
assert_pipe_form "a pipeline continued after a trailing |" "grep -q 'continued after a trailing pipe'"
# Inside $( ): the substitution consumes the pipeline's status (x=$(w | grep -q P
# && echo yes)); the scanner used to treat the whole $( ) as one opaque stage.
assert_pipe_form "a pipeline inside a command substitution" "grep -q 'inside a substitution'"
# A reader that is not the last stage still SIGPIPEs its writer (wv-7699b4): the
# scanner judged only stages[-1], and test-core's `git log | grep -m1 | cut`
# failed the rc.13 release aggregate with 141.
assert_pipe_form "an early-exit reader mid-pipeline" "grep -m1 'mid-pipeline reader'"

# Safe shapes must not be reported, and they are skipped because the rule does
# not match them -- not by a list of exceptions.
pipe_safe_out=$(python3 "$PIPE_SCANNER" "$PIPE_FIXTURE/safe.sh" 2>/dev/null || true)
if grep -qF -- "safe.sh:" <<<"$pipe_safe_out"; then
    fail "pipe scanner reports nothing for herestring, awk and consume-all readers"         "$(sed 's/^/    /' <<<"$pipe_safe_out")"
else
    pass "pipe scanner reports nothing for herestring, awk and consume-all readers"
fi

# Without pipefail the pipeline reports its last stage, so the bug cannot occur.
pipe_nopf_out=$(python3 "$PIPE_SCANNER" "$PIPE_FIXTURE/nopipefail.sh" 2>/dev/null || true)
if grep -qF -- "nopipefail.sh:" <<<"$pipe_nopf_out"; then
    fail "pipe scanner skips files that do not set pipefail"         "$(sed 's/^/    /' <<<"$pipe_nopf_out")"
else
    pass "pipe scanner skips files that do not set pipefail"
fi

# Every root that holds maintained shell: shipped (scripts, templates incl.
# procedure resources, .claude hooks and projected skills, the installers,
# build-release.sh) and repo tooling (tests, patches). Left out: docs/findings
# probe scripts and archive/, which are evidence and never ship. Before
# wv-db7ec6 only tests/ and scripts/ were scanned, so a broken shipped skill
# helper (weave-audit's audit-report.sh, exit 141 on any real graph) passed.
PIPE_ROOTS=(tests scripts templates .claude install.sh install-mcp.sh)
pipe_repo_rc=0
pipe_repo_out=$(cd "$REPO_ROOT" && python3 "$PIPE_SCANNER" "${PIPE_ROOTS[@]}" 2>&1) || pipe_repo_rc=$?
if [ "$pipe_repo_rc" -eq 0 ]; then
    pass "no early-exit pipeline under pipefail in any maintained shell root"
elif [ "$pipe_repo_rc" -eq 1 ]; then
    fail "no early-exit pipeline under pipefail in any maintained shell root" \
        "$(grep -E '^[^-].*:[0-9]+:' <<<"$pipe_repo_out" | sed 's/^/    /')
    capture first, then match on a herestring: grep -q PAT <<< \"\$value\""
else
    # A missing root or a scanner crash is not a clean result.
    fail "no early-exit pipeline under pipefail in any maintained shell root" \
        "    the scanner did not run (rc $pipe_repo_rc): $pipe_repo_out"
fi

# A root that does not exist is an error, never zero hits: a renamed root
# would otherwise shrink the scope above while it still passed.
pipe_missing_rc=0
python3 "$PIPE_SCANNER" "$REPO_ROOT/no-such-root-$$" >/dev/null 2>&1 || pipe_missing_rc=$?
if [ "$pipe_missing_rc" -eq 2 ]; then
    pass "pipe scanner exits 2 on a root that does not exist"
else
    fail "pipe scanner exits 2 on a root that does not exist" "    got rc $pipe_missing_rc"
fi

# The clean-repo claim above is only as wide as the files the walk selects: 1b's
# guarantee, for this scanner. Inverting its suffix test dropped every
# extensionless entry point (scripts/wv) and still read clean (wv-8fb6c6).
PIPE_EXTLESS=$(mktemp -d)
printf '#!/usr/bin/env bash\nset -o pipefail\nproducer | grep -q "extensionless"\n' > "$PIPE_EXTLESS/toolname"
# A dotted name is decided by its suffix, even under a shell shebang.
printf '#!/usr/bin/env bash\nset -o pipefail\nproducer | grep -q "dotted"\n' > "$PIPE_EXTLESS/helper.py"
pipe_ext_out=$(python3 "$PIPE_SCANNER" "$PIPE_EXTLESS" 2>/dev/null || true)
if grep -qF -- 'toolname:3:' <<<"$pipe_ext_out" && ! grep -qF -- 'helper.py' <<<"$pipe_ext_out"; then
    pass "pipe scanner's walk reaches an extensionless shell file and skips other suffixes"
else
    fail "pipe scanner's walk reaches an extensionless shell file and skips other suffixes" \
        "    scanned $PIPE_EXTLESS and reported: ${pipe_ext_out:-nothing}"
fi
rm -rf "$PIPE_EXTLESS"

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
if [ "$TESTS_FAILED" -gt 0 ]; then
    echo -e "${RED}$TESTS_FAILED check(s) failed${NC}"; exit 1
fi
echo -e "${GREEN}ALL CHECKS PASSED${NC}"
exit 0
