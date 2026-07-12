#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# test-pattern-audit-check1.sh — Tests for pattern-audit Check 1 (cache
# write-list completeness), including the $WV self-reference regression
# (wv-dfaa75): Check 1 must scan the dispatch table of the checkout that is
# actually running pattern-audit, not whatever "wv" happens to resolve on
# PATH. A different installed/tagged wv on PATH previously produced a false
# result — either hiding a real unclassified command or fabricating one that
# only exists in the PATH binary, not the checkout under test.

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

TEST_DIR="/tmp/wv-pa-check1-test-$$"
export WV_HOT_ZONE="$TEST_DIR"
export WV_DB="$TEST_DIR/brain.db"
export WV_REQUIRE_LEARNING=0
export WV_RUN_CACHE=0
export WV_PROJECT_DIR="$TEST_DIR"

cleanup() { cd /tmp && rm -rf "$TEST_DIR"; }
trap cleanup EXIT

assert_contains() {
    local haystack="$1" needle="$2" msg="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if echo "$haystack" | grep -qF -- "$needle"; then
        echo -e "  ${GREEN}✓${NC} $msg"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗${NC} $msg"
        echo "    expected to contain: $needle"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" msg="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if echo "$haystack" | grep -qF -- "$needle"; then
        echo -e "  ${RED}✗${NC} $msg"
        echo "    expected NOT to contain: $needle"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    else
        echo -e "  ${GREEN}✓${NC} $msg"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    fi
}

setup_test_env() {
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR"
    cd "$TEST_DIR"
    git init -q
    "$WV" init -q 2>/dev/null || true
}

echo "--- Check 1: current dispatch table is fully classified ---"
setup_test_env
JSON_OUT=$("$WV" pattern-audit --json 2>/dev/null || true)
C1_STATUS=$(echo "$JSON_OUT" | jq -r '.pattern_audit.findings[] | select(.check=="cache_classification") | .status' 2>/dev/null || echo "")
assert_contains "$C1_STATUS" "pass" "Check 1 passes on the real, currently-shipped dispatch table"

echo "--- Check 1: a different wv on PATH must not be consulted instead of self ---"
FAKE_BIN="$TEST_DIR/fake-bin"
mkdir -p "$FAKE_BIN"
# A fake "wv" whose dispatch table contains a command that exists nowhere in
# the real classifier lists. If Check 1 resolves via `command -v wv` instead
# of self-referencing the checkout that is actually running, it will report
# this fake command as unclassified even though it does not exist in the
# real running wv.
cat > "$FAKE_BIN/wv" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    zzz_fake_unclassified_cmd) echo "fake" ;;
esac
EOF
chmod +x "$FAKE_BIN/wv"

FAKE_PATH_OUT=$(PATH="$FAKE_BIN:$PATH" "$WV" pattern-audit --json 2>/dev/null || true)
FAKE_C1_STATUS=$(echo "$FAKE_PATH_OUT" | jq -r '.pattern_audit.findings[] | select(.check=="cache_classification") | .status' 2>/dev/null || echo "")
FAKE_C1_DETAIL=$(echo "$FAKE_PATH_OUT" | jq -r '.pattern_audit.findings[] | select(.check=="cache_classification") | .detail' 2>/dev/null || echo "")
assert_not_contains "$FAKE_C1_DETAIL" "zzz_fake_unclassified_cmd" \
    "a differently-shaped wv earlier on PATH does not leak its commands into the result"
assert_contains "$FAKE_C1_STATUS" "pass" \
    "result still reflects the real running checkout's own dispatch table, not the PATH decoy"

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
if [ "$TESTS_FAILED" -eq 0 ]; then
    echo -e "${GREEN}All tests passed${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed${NC}"
    exit 1
fi
