#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# test-doctor-pattern-shadow.sh — wv doctor's managed-pattern-rule shadow advisory
#
# Source: wv-3a0a40 — 'wv quality patterns list' already warns (stderr, both
# --json and text mode) when a project-local custom rule shares an id with a
# managed rule (see _shadowed_managed_pattern_ids in
# scripts/weave_quality/__main__.py) -- the local copy silently shadows the
# managed one, which was never actually applied. `wv doctor` (a separate,
# install-health-oriented entry point) had no equivalent advisory at all.
# The doctor check added here does NOT re-derive the shadow-detection logic
# -- it invokes the SAME 'patterns list' Python entry point and captures its
# own stderr, matching the same command's own already-tested behavior.
#
# Covers:
#   - WARN: a project-local rule shadows a managed rule (.overridden marker
#     names it, and a same-id custom rule file exists)
#   - PASS: .overridden marker present but no shadowing local rule exists
#   - Check absent entirely: no .weave/patterns/managed/ dir at all (cheap
#     short-circuit, matches _shadowed_managed_pattern_ids' own early return)
#   - WARN, never PASS: the delegated 'patterns list' invocation itself
#     fails (e.g. a malformed local rule) -- wv-92ca0e, found by external
#     code review. An unevaluated check must never report pass.
#
# Exit codes:
#   0 - All tests passed
#   1 - Unexpected failure

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$PROJECT_ROOT/scripts/wv"

TEST_DIR="/tmp/wv-doctor-shadow-fixture-$$"
export WV_HOT_ZONE="$TEST_DIR/hotzone"
export WV_CONFIG_DIR="$TEST_DIR/config"

cleanup() { cd /tmp && rm -rf "$TEST_DIR"; }
trap cleanup EXIT

setup_test_env() {
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR/repo"
    cd "$TEST_DIR/repo"
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if echo "$haystack" | grep -qF "$needle"; then
        echo -e "  ${GREEN}[PASS]${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} $message (expected '$needle' in output)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if echo "$haystack" | grep -qF "$needle"; then
        echo -e "  ${RED}[FAIL]${NC} $message (unexpected '$needle' in output)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    else
        echo -e "  ${GREEN}[PASS]${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    fi
}

# ─── Tests ──────────────────────────────────────────────────────────────────

test_shadowed_rule_warns() {
    echo "-- .overridden marker + a same-id local rule → doctor WARN"
    mkdir -p .weave/patterns/managed
    mkdir -p "$WV_CONFIG_DIR/quality-patterns/managed"
    echo "shadowed-rule.yaml" > .weave/patterns/managed/.overridden
    echo "shadowed-rule.yaml" > "$WV_CONFIG_DIR/quality-patterns/managed/manifest.txt"
    cat > "$WV_CONFIG_DIR/quality-patterns/managed/shadowed-rule.yaml" <<'EOF'
id: shadowed-rule
language: prose
kind: regex
patterns:
  - managed
EOF
    cat > .weave/patterns/shadowed-rule.yaml <<'EOF'
id: shadowed-rule
language: prose
kind: regex
patterns:
  - absent
EOF
    local out
    out=$("$WV" doctor 2>&1 || true)
    assert_contains "$out" "pattern-shadow" "doctor emits a pattern-shadow check"
    assert_contains "$out" "managed rule(s) shadowed by a local copy" "doctor warns on the shadowing rule"
}

test_no_local_rule_passes() {
    echo "-- .overridden marker present but no matching local rule file → doctor PASS"
    mkdir -p .weave/patterns/managed
    echo "shadowed-rule.yaml" > .weave/patterns/managed/.overridden
    local out
    out=$("$WV" doctor 2>&1 || true)
    assert_contains "$out" "pattern-shadow" "doctor emits a pattern-shadow check"
    assert_contains "$out" "no managed-rule shadowing detected" "doctor reports no shadowing"
    assert_not_contains "$out" "shadowed by a local copy" "no shadow warning without a shadowing rule"
}

test_no_managed_dir_skips_check() {
    echo "-- no .weave/patterns/managed/ at all → check does not fire"
    local out
    out=$("$WV" doctor 2>&1 || true)
    assert_not_contains "$out" "pattern-shadow" "no pattern-shadow line without an .overridden marker"
}

test_delegate_failure_never_reports_pass() {
    echo "-- delegated 'patterns list' fails (malformed local rule) → doctor WARN, never PASS (wv-92ca0e)"
    mkdir -p .weave/patterns/managed
    echo "shadowed-rule.yaml" > .weave/patterns/managed/.overridden
    cat > .weave/patterns/shadowed-rule.yaml <<'EOF'
id: shadowed-rule
language: prose
kind: regex
patterns:
  - absent
EOF
    # Unrelated rule, malformed independently of the shadow fixture --
    # breaks _load_pattern_rules entirely, before shadow detection would
    # even run.
    printf 'id: [unclosed\n' > .weave/patterns/broken-rule.yaml
    local out
    out=$("$WV" doctor 2>&1 || true)
    assert_contains "$out" "pattern-shadow" "doctor still emits a pattern-shadow check"
    assert_contains "$out" "could not evaluate managed-rule shadowing" "doctor reports the evaluation failure"
    assert_not_contains "$out" "pattern-shadow: no managed-rule shadowing detected" "never reports pass for an unevaluated check"
}

test_json_mode_carries_the_same_advisory() {
    echo "-- wv doctor --json carries the same pattern-shadow check"
    mkdir -p .weave/patterns/managed
    echo "shadowed-rule.yaml" > .weave/patterns/managed/.overridden
    cat > .weave/patterns/shadowed-rule.yaml <<'EOF'
id: shadowed-rule
language: prose
kind: regex
patterns:
  - absent
EOF
    local out
    out=$("$WV" doctor --json 2>&1 || true)
    assert_contains "$out" '"check":"pattern-shadow"' "doctor --json includes the pattern-shadow check"
    assert_contains "$out" '"status":"warn"' "doctor --json marks it warn"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    echo "test-doctor-pattern-shadow.sh"
    echo ""

    setup_test_env; test_shadowed_rule_warns
    setup_test_env; test_no_local_rule_passes
    setup_test_env; test_no_managed_dir_skips_check
    setup_test_env; test_delegate_failure_never_reports_pass
    setup_test_env; test_json_mode_carries_the_same_advisory

    echo ""
    echo "========================================"
    echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
    echo "========================================"

    [ "$TESTS_FAILED" -eq 0 ] || exit 1
    exit 0
}

main "$@"
