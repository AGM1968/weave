#!/bin/bash
# test-install-ast-grep.sh — installer must not download optional ast-grep by default.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0

assert_equals() {
    local expected="$1" actual="$2" msg="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$expected" = "$actual" ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "${GREEN}✓${NC} $msg"
    else
        echo -e "${RED}✗${NC} $msg"
        echo "  expected: $expected"
        echo "  actual:   $actual"
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" msg="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$haystack" == *"$needle"* ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "${GREEN}✓${NC} $msg"
    else
        echo -e "${RED}✗${NC} $msg"
        echo "  expected to contain: $needle"
    fi
}

make_stub() {
    local dir="$1" name="$2"
    cat > "$dir/$name" <<'SH'
#!/bin/bash
echo "$0 $*" >> "$WV_STUB_LOG"
exit 99
SH
    chmod +x "$dir/$name"
}

echo "=== Install ast-grep opt-in tests ==="

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

stub_bin="$tmp/bin"
install_dir="$tmp/install-bin"
lib_dir="$tmp/lib"
config_dir="$tmp/config"
home_dir="$tmp/home"
mkdir -p "$stub_bin" "$install_dir" "$lib_dir" "$config_dir" "$home_dir/.claude"

make_stub "$stub_bin" cargo
make_stub "$stub_bin" curl
make_stub "$stub_bin" unzip

export WV_STUB_LOG="$tmp/stub.log"
touch "$WV_STUB_LOG"

PATH="$stub_bin:/usr/bin:/bin" \
HOME="$home_dir" \
WV_INSTALL_DIR="$install_dir" \
WV_LIB_DIR="$lib_dir" \
WV_CONFIG_DIR="$config_dir" \
SKIP_AST_GREP=0 \
bash "$PROJECT_ROOT/install.sh" --no-mcp >/tmp/wv-install-ast-default.out 2>&1

default_out=$(cat /tmp/wv-install-ast-default.out)
default_calls=$(cat "$WV_STUB_LOG")

assert_contains "$default_out" "no download attempted" "default install reports ast-grep skipped without download"
assert_equals "" "$default_calls" "default install does not call cargo/curl/unzip for ast-grep"

: > "$WV_STUB_LOG"
set +e
PATH="$stub_bin:/usr/bin:/bin" \
HOME="$home_dir" \
WV_INSTALL_DIR="$install_dir" \
WV_LIB_DIR="$lib_dir" \
WV_CONFIG_DIR="$config_dir" \
bash "$PROJECT_ROOT/install.sh" --no-mcp --with-ast-grep >/tmp/wv-install-ast-optin.out 2>&1
rc=$?
set -e

optin_out=$(cat /tmp/wv-install-ast-optin.out)
optin_calls=$(cat "$WV_STUB_LOG")

assert_equals "0" "$rc" "explicit ast-grep install failure remains non-fatal"
assert_contains "$optin_out" "explicit install" "opt-in install advertises explicit ast-grep mode"
assert_contains "$optin_calls" "cargo install ast-grep" "opt-in install may call cargo"

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
[ "$TESTS_PASSED" -eq "$TESTS_RUN" ]
