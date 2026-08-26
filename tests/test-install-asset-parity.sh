#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# test-install-asset-parity.sh — installed assets match what the repo ships.
#
# Three things can silently ship a broken install, and all three have happened
# or nearly happened here:
#
#   1. A module missing from install.sh's hardcoded fallback list. The install
#      succeeds and the package dies at import time on the target machine.
#   2. A new asset directory the local branch never copies.
#   3. A contract the runtime reads that only exists in a source checkout.
#
# install.sh and build-release.sh are OUTSIDE the E6 implementation-source
# closure, so this parity suite is their gate: editing them triggers no runner
# recapture, which is exactly why nothing else would catch the drift.
#
# Exit codes: 0 all checks pass, 1 otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECKER="$SCRIPT_DIR/lib/install-asset-parity.py"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
TESTS_RUN=0; TESTS_PASSED=0; TESTS_FAILED=0
pass() { TESTS_RUN=$((TESTS_RUN+1)); TESTS_PASSED=$((TESTS_PASSED+1)); echo -e "  ${GREEN}✓${NC} $1"; }
fail() { TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAILED=$((TESTS_FAILED+1)); echo -e "  ${RED}✗${NC} $1"; [ -n "${2:-}" ] && echo "$2"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "=== install asset parity ==="
echo ""

if [ ! -f "$CHECKER" ]; then
    fail "parity checker is present" "    missing: $CHECKER"
    echo "Results: $TESTS_PASSED/$TESTS_RUN passed"; exit 1
fi

python3 "$CHECKER" > "$TMP/out" 2>&1
status=$?
if [ "$status" -ne 0 ] || ! grep -q '^COUNT ' "$TMP/out"; then
    fail "fallback lists match the repository" "    checker exited $status without a COUNT line:
$(sed 's/^/    /' "$TMP/out")"
else
    problems=$(grep '^PROBLEM' "$TMP/out" || true)
    if [ -z "$problems" ]; then
        pass "fallback lists match the repository ($(awk '/^COUNT/{print $2}' "$TMP/out") lists)"
    else
        fail "fallback lists match the repository" "$(printf '%s\n' "$problems" | sed 's/^PROBLEM /    /')"
    fi
fi

# The release manifest ships directories recursively, so a new package under
# scripts/ is covered only if SHIP_DIRS names it.
if grep -q '^    scripts/weave_coaching$' -- "$ROOT/build-release.sh"; then
    pass "build-release ships the pure coaching package"
else
    fail "build-release ships the pure coaching package" \
        "    add scripts/weave_coaching to SHIP_DIRS; a package directory is not shipped by default"
fi

# .weave/test-map.conf must not carry a duplicate source key. A second row for a
# path either shadows the first or is ignored, and both outcomes silently change
# which suites the impact gate selects -- which is how an evidence battery lost
# its route earlier in this session, surfacing only as an unrelated failure.
dupes=$(cut -d= -f1 "$ROOT/.weave/test-map.conf" | grep -v '^#\|^\[' | sed 's/ *$//' | sort | uniq -d)
if [ -z "$dupes" ]; then
    pass "test-map.conf has no duplicate source keys"
else
    fail "test-map.conf has no duplicate source keys" \
        "    merge these into one row instead of adding a second:
$(printf '%s\n' "$dupes" | sed 's/^/    /')"
fi

# Negative control: a checker that stopped checking passes everything above.
work="$TMP/repo"
mkdir -p "$work/tests/lib" "$work/scripts/weave_coaching" "$work/scripts/weave_quality/guides" "$work/contracts"
cp "$CHECKER" "$work/tests/lib/"
cp "$ROOT/install.sh" "$work/"
cp "$ROOT"/contracts/violation-vocabulary-v1.json "$ROOT"/contracts/coaching-*.json "$work/contracts/" 2>/dev/null
cp "$ROOT"/scripts/weave_coaching/*.py "$work/scripts/weave_coaching/"
cp "$ROOT"/scripts/weave_quality/guides/*.md "$work/scripts/weave_quality/guides/"
mkdir -p "$work/scripts/weave_quality"
cp "$ROOT"/scripts/weave_quality/*.py "$work/scripts/weave_quality/"
# A new module nobody added to the fallback list is the exact drift this catches.
printf 'x = 1\n' > "$work/scripts/weave_coaching/forgotten.py"
(cd "$work" && python3 tests/lib/install-asset-parity.py) > "$TMP/out" 2>&1
if grep -q 'fallback omits forgotten.py' "$TMP/out"; then
    pass "a module missing from the fallback list is reported"
else
    fail "a module missing from the fallback list is reported" \
        "    the checker did not notice an unlisted module
$(sed 's/^/    /' "$TMP/out")"
fi

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
[ "$TESTS_FAILED" -eq 0 ]
