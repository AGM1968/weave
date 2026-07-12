#!/usr/bin/env bash
# test-install-file.sh — Regression coverage for install_file/download_file
# atomic-replace behavior (wv-fa566a).
#
# install.sh is a top-level installer script, not a sourceable library — it
# runs the full install flow when executed. To test install_file/download_file
# in isolation without triggering a real install, extract just their function
# bodies (the real source, not a reimplementation) and eval them.
#
# Exit codes:
#   0 - All tests passed
#   1 - One or more tests failed

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

assert_equals() {
    local expected="$1" actual="$2" description="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$expected" = "$actual" ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "${GREEN}✓${NC} $description"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "${RED}✗${NC} $description"
        echo "  Expected: $expected"
        echo "  Actual:   $actual"
    fi
}

assert_file_exists() {
    local path="$1" description="$2"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ -e "$path" ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "${GREEN}✓${NC} $description"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "${RED}✗${NC} $description (missing: $path)"
    fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TEST_DIR="/tmp/wv-install-file-test-$$"
mkdir -p "$TEST_DIR"
trap 'rm -rf "$TEST_DIR"' EXIT

# Extract the real install_file/download_file source (not a reimplementation)
# and eval it, so we're testing the actual shipped functions.
FUNCS=$(sed -n '/^install_file() {/,/^}/p; /^download_file() {/,/^}/p' "$PROJECT_ROOT/install.sh")
eval "$FUNCS"

echo "Test: install_file/download_file atomic replace"
echo "================================================="

# ── install_file: normal success ──
MANIFEST="$TEST_DIR/manifest.txt"
DEV_MODE=0
: > "$MANIFEST"
mkdir -p "$TEST_DIR/src" "$TEST_DIR/dst"
printf 'v1 content\n' > "$TEST_DIR/src/f.sh"
install_file "$TEST_DIR/src/f.sh" "$TEST_DIR/dst/f.sh"
assert_equals "v1 content" "$(cat "$TEST_DIR/dst/f.sh")" "install_file: copies content on success"
assert_equals "$TEST_DIR/dst/f.sh" "$(cat "$MANIFEST")" "install_file: records dst in manifest on success"

# ── install_file: source missing must not delete an existing dst ──
: > "$MANIFEST"
printf 'installed copy\n' > "$TEST_DIR/dst/f.sh"
set +e
install_file "$TEST_DIR/src/missing.sh" "$TEST_DIR/dst/f.sh" 2>/dev/null
rc=$?
set -e
assert_equals "1" "$rc" "install_file: returns 1 when source is missing"
assert_file_exists "$TEST_DIR/dst/f.sh" "install_file: leaves existing dst in place when source is missing"
assert_equals "installed copy" "$(cat "$TEST_DIR/dst/f.sh")" "install_file: dst content untouched when source is missing"
assert_equals "" "$(cat "$MANIFEST")" "install_file: does not record a failed install in the manifest"

# ── install_file: cp failure must not delete an existing dst ──
FAKE_BIN="$TEST_DIR/fake-bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/cp" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$FAKE_BIN/cp"
: > "$MANIFEST"
printf 'installed copy\n' > "$TEST_DIR/dst/f.sh"
set +e
PATH="$FAKE_BIN:$PATH" install_file "$TEST_DIR/src/f.sh" "$TEST_DIR/dst/f.sh" 2>/dev/null
rc=$?
set -e
assert_equals "1" "$rc" "install_file: returns 1 when cp fails"
assert_equals "installed copy" "$(cat "$TEST_DIR/dst/f.sh")" "install_file: dst content untouched when cp fails"

# ── download_file: normal success ──
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
    if [ "$prev" = "-o" ]; then out="$arg"; fi
    prev="$arg"
done
printf 'downloaded content\n' > "$out"
exit 0
EOF
chmod +x "$FAKE_BIN/curl"
: > "$MANIFEST"
PATH="$FAKE_BIN:$PATH" download_file "https://example.invalid/f.sh" "$TEST_DIR/dst/g.sh"
assert_equals "downloaded content" "$(cat "$TEST_DIR/dst/g.sh")" "download_file: writes content on success"
assert_equals "$TEST_DIR/dst/g.sh" "$(cat "$MANIFEST")" "download_file: records dst in manifest on success"

# ── download_file: curl failure must not corrupt an existing dst ──
cat > "$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
exit 22
EOF
chmod +x "$FAKE_BIN/curl"
: > "$MANIFEST"
printf 'installed copy\n' > "$TEST_DIR/dst/g.sh"
set +e
PATH="$FAKE_BIN:$PATH" download_file "https://example.invalid/404" "$TEST_DIR/dst/g.sh" 2>/dev/null
rc=$?
set -e
assert_equals "1" "$rc" "download_file: returns 1 when curl fails"
assert_equals "installed copy" "$(cat "$TEST_DIR/dst/g.sh")" "download_file: dst content untouched when curl fails"
assert_equals "" "$(cat "$MANIFEST")" "download_file: does not record a failed download in the manifest"

echo ""
echo "========================================"
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
echo "========================================"
if [ "$TESTS_FAILED" -eq 0 ]; then
    echo -e "${GREEN}All tests passed${NC}"
    exit 0
else
    echo -e "${RED}$TESTS_FAILED tests FAILED${NC}"
    exit 1
fi
