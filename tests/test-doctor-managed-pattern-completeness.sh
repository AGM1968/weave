#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# test-doctor-managed-pattern-completeness.sh — wv doctor's managed-pattern
# completeness advisory
#
# Source: wv-8d16bd (external code review round 3 re-audit) — the companion
# audit deleted a custom rule that was shadowing a managed rule (following
# the shadow-warning's own "delete the local copy" advice) WITHOUT rerunning
# 'wv init-repo --update' afterward, and the managed version was never
# resynced -- the rule vanished entirely (24 rules -> 23). The existing
# pattern-shadow check (wv-3a0a40) only re-derives cmd_patterns_list's own
# warning, which stops firing the moment the id drops out of active_ids --
# it reports a false "pass" for a rule that is not shadowed, it is MISSING.
# This check closes that gap: cross-references the union of .overridden
# (shadowed ids) and .manifest (currently-synced ids) against what actually
# resolves in either tier.
#
# Covers:
#   - WARN: an id in .overridden with no file in EITHER tier (the vanished-
#     rule bug, reproduced exactly)
#   - PASS: an id in .manifest whose managed file is actually present
#   - PASS: an id in .overridden whose custom override is actually present
#     (the ordinary, currently-shadowed-but-not-lost state)
#   - Check absent entirely: neither .overridden nor .manifest exists (no
#     managed-pattern reconcile history at all)
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

TEST_DIR="/tmp/wv-doctor-mc-fixture-$$"
export WV_HOT_ZONE="$TEST_DIR/hotzone"

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

test_vanished_rule_warns() {
    echo "-- .overridden names an id with no file in EITHER tier -> doctor WARN (the reproduced bug)"
    mkdir -p .weave/patterns/managed
    echo "markdown-bold-label-metadata.yaml" > .weave/patterns/managed/.overridden
    local out
    out=$("$WV" doctor 2>&1 || true)
    assert_contains "$out" "managed-pattern-completeness" "doctor emits a managed-pattern-completeness check"
    assert_contains "$out" "markdown-bold-label-metadata" "doctor names the vanished id"
    assert_contains "$out" "wv init-repo --update" "doctor names the required follow-up command"
    # The exact false-pass this check exists to catch: pattern-shadow alone
    # reports clean because the id already dropped out of active_ids.
    assert_contains "$out" "pattern-shadow: no managed-rule shadowing detected" "pattern-shadow alone would false-pass this exact state"
}

test_resynced_managed_file_passes() {
    echo "-- .manifest names an id whose managed file IS present -> doctor PASS"
    mkdir -p .weave/patterns/managed
    echo "markdown-bold-label-metadata.yaml" > .weave/patterns/managed/.manifest
    cat > .weave/patterns/managed/markdown-bold-label-metadata.yaml <<'EOF'
id: markdown-bold-label-metadata
language: prose
kind: regex
patterns:
  - absent
EOF
    local out
    out=$("$WV" doctor 2>&1 || true)
    assert_contains "$out" "managed-pattern-completeness" "doctor emits a managed-pattern-completeness check"
    assert_contains "$out" "every known managed-pattern id resolves in one tier" "doctor reports completeness"
}

test_currently_shadowed_custom_file_passes() {
    echo "-- .overridden names an id whose custom override IS present -> doctor PASS (ordinary shadow, not lost)"
    mkdir -p .weave/patterns/managed
    echo "markdown-bold-label-metadata.yaml" > .weave/patterns/managed/.overridden
    cat > .weave/patterns/markdown-bold-label-metadata.yaml <<'EOF'
id: markdown-bold-label-metadata
language: prose
kind: regex
patterns:
  - absent
EOF
    local out
    out=$("$WV" doctor 2>&1 || true)
    assert_contains "$out" "managed-pattern-completeness" "doctor emits a managed-pattern-completeness check"
    assert_contains "$out" "every known managed-pattern id resolves in one tier" "doctor reports completeness"
}

test_no_reconcile_history_skips_check() {
    echo "-- neither .overridden nor .manifest exists -> check does not fire"
    local out
    out=$("$WV" doctor 2>&1 || true)
    assert_not_contains "$out" "managed-pattern-completeness" "no managed-pattern-completeness line without reconcile history"
}

test_json_mode_carries_the_same_advisory() {
    echo "-- wv doctor --json carries the same managed-pattern-completeness check"
    mkdir -p .weave/patterns/managed
    echo "markdown-bold-label-metadata.yaml" > .weave/patterns/managed/.overridden
    local out
    out=$("$WV" doctor --json 2>&1 || true)
    assert_contains "$out" '"check":"managed-pattern-completeness"' "doctor --json includes the check"
    assert_contains "$out" '"status":"warn"' "doctor --json marks it warn"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    echo "test-doctor-managed-pattern-completeness.sh"
    echo ""

    setup_test_env; test_vanished_rule_warns
    setup_test_env; test_resynced_managed_file_passes
    setup_test_env; test_currently_shadowed_custom_file_passes
    setup_test_env; test_no_reconcile_history_skips_check
    setup_test_env; test_json_mode_carries_the_same_advisory

    echo ""
    echo "========================================"
    echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
    echo "========================================"

    [ "$TESTS_FAILED" -eq 0 ] || exit 1
    exit 0
}

main "$@"
