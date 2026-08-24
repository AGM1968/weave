#!/usr/bin/env bash
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

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
if [ "$TESTS_FAILED" -gt 0 ]; then
    echo -e "${RED}$TESTS_FAILED check(s) failed${NC}"; exit 1
fi
echo -e "${GREEN}ALL CHECKS PASSED${NC}"
exit 0
