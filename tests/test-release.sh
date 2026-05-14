#!/bin/bash
# test-release.sh — Regression tests for build-release.sh
# Weave-ID: wv-73eb55

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TESTS_RUN=0
TESTS_PASSED=0

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_equals() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-assertion}"
    if [ "$expected" = "$actual" ]; then
        echo -e "  ${GREEN}✓${NC} $msg"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗${NC} $msg"
        echo "    Expected: '$expected'"
        echo "    Actual:   '$actual'"
    fi
    TESTS_RUN=$((TESTS_RUN + 1))
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-contains assertion}"
    if echo "$haystack" | grep -qF "$needle"; then
        echo -e "  ${GREEN}✓${NC} $msg"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗${NC} $msg"
        echo "    Expected to contain: '$needle'"
        echo "    Actual: '$haystack'"
    fi
    TESTS_RUN=$((TESTS_RUN + 1))
}

TEST_ROOT=$(mktemp -d)
cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
echo "  build-release.sh Regression Tests"
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""

SOURCE_BARE="$TEST_ROOT/source-origin.git"
SOURCE_CLONE="$TEST_ROOT/source"
OUTPUT_BARE="$TEST_ROOT/output-origin.git"
OUTPUT_REPO="$TEST_ROOT/weave"
FAKE_BIN="$TEST_ROOT/fake-bin"
CALLER_HOME="$TEST_ROOT/caller-home"
GH_LOG="$TEST_ROOT/gh.log"

git init --bare -q "$SOURCE_BARE"
git clone -q "$REPO_ROOT" "$SOURCE_CLONE"
git -C "$SOURCE_CLONE" remote set-url origin "$SOURCE_BARE"
git -C "$SOURCE_CLONE" config user.name "Weave Test"
git -C "$SOURCE_CLONE" config user.email "weave-test@example.com"

git init --bare -q "$OUTPUT_BARE"
mkdir -p "$OUTPUT_REPO"
git -C "$OUTPUT_REPO" init -q
git -C "$OUTPUT_REPO" remote add origin "$OUTPUT_BARE"
git -C "$OUTPUT_REPO" config user.name "Weave Test"
git -C "$OUTPUT_REPO" config user.email "weave-test@example.com"

mkdir -p "$FAKE_BIN" "$CALLER_HOME/.config/gh"
cat > "$FAKE_BIN/gh" <<'EOF'
#!/bin/bash
set -euo pipefail

printf 'HOME=%s CMD=%s %s\n' "${HOME:-}" "${1:-}" "${2:-}" >> "${GH_SPY_LOG:?}"

if [ "${1:-}" = "release" ] && [ "${2:-}" = "view" ]; then
    exit 1
fi

if [ "${1:-}" = "release" ] && [ "${2:-}" = "create" ]; then
    echo "fake release created"
    exit 0
fi

exit 0
EOF
chmod +x "$FAKE_BIN/gh"

release_output=""
release_rc=0
release_output=$(cd "$SOURCE_CLONE" && \
    HOME="$CALLER_HOME" \
    GH_SPY_LOG="$GH_LOG" \
    PATH="$FAKE_BIN:$PATH" \
    ./build-release.sh --output="$OUTPUT_REPO" --release --verify 2>&1) || release_rc=$?

assert_equals "0" "$release_rc" "build-release --release --verify succeeds in sandbox regression test"
assert_contains "$release_output" "Release build verified" "verify phase completes before release publish"

gh_log_contents=$(cat "$GH_LOG")
assert_contains "$gh_log_contents" "CMD=release view" "gh release view called after verify"
assert_contains "$gh_log_contents" "CMD=release create" "gh release create called after verify"

wrong_home_lines=$(printf '%s\n' "$gh_log_contents" | grep -v "^HOME=$CALLER_HOME CMD=" || true)
assert_equals "" "$wrong_home_lines" "gh sees caller HOME after verify sandbox"

echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
echo -e "Results: $TESTS_PASSED/$TESTS_RUN passed"
if [ "$TESTS_PASSED" -eq "$TESTS_RUN" ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed.${NC}"
    exit 1
fi