#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# test-test-hook-registry.sh — INVENTORY audit of production WV_TEST_* hooks.
#
# Fault-injection hooks live in shipped code, so the set of them has to stay
# deliberate: an unregistered one is production surface nobody reviewed. This
# audits the inventory in tests/wv-test-hooks.registry against what production
# code actually contains, in both directions.
#
# Scope, stated plainly: this proves the INVENTORY is complete and current. It
# proves nothing about whether any hook is correctly gated or correctly
# validated -- those are behavioural properties, asserted in the suite that
# owns each hook. A green run here is not evidence that a hook is safe.
#
# Exit codes: 0 all checks pass, 1 otherwise.

set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTRY="${WV_TEST_HOOK_REGISTRY:-$SCRIPT_DIR/wv-test-hooks.registry}"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
TESTS_RUN=0; TESTS_PASSED=0; TESTS_FAILED=0

pass() { TESTS_RUN=$((TESTS_RUN+1)); TESTS_PASSED=$((TESTS_PASSED+1)); echo -e "  ${GREEN}✓${NC} $1"; }
fail() { TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAILED=$((TESTS_FAILED+1)); echo -e "  ${RED}✗${NC} $1"; [ -n "${2:-}" ] && echo "    $2"; }

# Production sources: everything shipped, excluding the suite itself, and the
# release builder, whose seams can skip a release gate (wv-cfa8ee).
scan_production() {
    grep -rho "WV_TEST_[A-Z0-9_]*" \
        "$REPO_ROOT/scripts" "$REPO_ROOT/install.sh" "$REPO_ROOT/build-release.sh" 2>/dev/null \
        | sort -u
}

registry_names() {
    grep -v '^#' "$REGISTRY" 2>/dev/null | grep -v '^[[:space:]]*$' \
        | cut -d'|' -f1 | tr -d ' ' | sort -u
}

echo "=== WV_TEST_* hook registry audit (inventory only) ==="
echo ""

if [ ! -f "$REGISTRY" ]; then
    fail "registry exists" "not found: $REGISTRY"
    echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
    exit 1
fi
pass "registry exists"

FOUND=$(scan_production)
REGISTERED=$(registry_names)

# 1. Every hook in production code is registered. This is the direction that
#    matters: an unregistered hook is unreviewed production surface.
UNREGISTERED=$(comm -23 <(printf '%s\n' "$FOUND") <(printf '%s\n' "$REGISTERED"))
if [ -z "$UNREGISTERED" ]; then
    pass "every WV_TEST_* hook in production code is registered"
else
    fail "every WV_TEST_* hook in production code is registered" \
        "unregistered: $(printf '%s' "$UNREGISTERED" | tr '\n' ' ')— add it to $(basename "$REGISTRY")"
fi

# 2. Every registered hook still exists, so the inventory cannot rot into a
#    list of names that no longer mean anything.
STALE=$(comm -13 <(printf '%s\n' "$FOUND") <(printf '%s\n' "$REGISTERED"))
if [ -z "$STALE" ]; then
    pass "every registered hook still appears in production code"
else
    fail "every registered hook still appears in production code" \
        "stale entries: $(printf '%s' "$STALE" | tr '\n' ' ')"
fi

# 3. Each entry's owning file really contains it, so the registry points at the
#    code a reader needs to look at.
while IFS='|' read -r name owner _values _purpose; do
    name=$(printf '%s' "$name" | tr -d ' ')
    owner=$(printf '%s' "$owner" | sed 's/^ *//; s/ *$//')
    [ -n "$name" ] || continue
    [ "$owner" = "(master)" ] && continue
    if [ -f "$REPO_ROOT/$owner" ] && grep -q -- "$name" "$REPO_ROOT/$owner"; then
        pass "$name is present in its registered owner ($owner)"
    else
        fail "$name is present in its registered owner ($owner)" "not found in $owner"
    fi
done < <(grep -v '^#' "$REGISTRY" | grep -v '^[[:space:]]*$')

# Deliberately NOT checked here: whether a site actually GATES on
# WV_TEST_MODE. Grep finding that string in a file cannot distinguish a real
# guard from a mention in a comment, and a check that looks like proof but is
# not is worse than no check. Gating is proven behaviourally, per hook, in the
# suite that owns it: test-data.sh (WV_TEST_SYNC_STUB),
# test-cache-invalidation.sh (WV_TEST_IMPACT_RACE) and test-commit-refs.sh
# (WV_TEST_FAIL_ORPHAN_KINDS) each assert that a valid value is inert without
# the master opt-in and that an invalid value is rejected.

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
if [ "$TESTS_FAILED" -gt 0 ]; then
    echo -e "${RED}$TESTS_FAILED check(s) failed${NC}"
    exit 1
fi
echo -e "${GREEN}ALL CHECKS PASSED${NC}"
exit 0
