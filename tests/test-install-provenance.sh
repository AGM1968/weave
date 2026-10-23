#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# test-install-provenance.sh — regression tests for install provenance
#
# Source: wv-89f85b (release review 3) found install provenance incomplete four
# ways, and wv-597164 that all four were fixed in 2ff83c31 with no test behind
# them. VERSION alone cannot answer "which fixes does this install have", so
# provenance is what makes a stale or unreproducible install visible; every one
# of these defects made that answer wrong while still looking healthy.
#
# Covers:
#   - untracked files count as dirty (`git diff --quiet HEAD` ignores them, so
#     an install built from a tree carrying uncommitted new files recorded
#     dirty=false and looked reproducible when it was not)
#   - a dirty install WARNS instead of passing (it matches no commit, so a
#     clean pass hid exactly the case where the running code corresponds to
#     nothing in the history)
#   - doctor honours WV_LIB_DIR (a hardcoded path reported on a DIFFERENT
#     install than the one running whenever the library lives elsewhere)
#   - a remote install records provenance (without it, doctor's "not recorded —
#     re-run install.sh" advice could never be cleared by the reinstall it
#     recommends)
#
# Exit codes:
#   0 - All tests passed
#   1 - One or more tests failed

set -euo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TEST_DIR="/tmp/wv-install-provenance-$$"
export WV_HOT_ZONE="$TEST_DIR/hotzone"
export WV_DB="$TEST_DIR/hotzone/brain.db"

cleanup() { cd /tmp && rm -rf "$TEST_DIR"; }
trap cleanup EXIT

assert_equals() {
    local expected="$1" actual="$2" message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$expected" = "$actual" ]; then
        echo -e "  ${GREEN}[PASS]${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} $message (expected '$expected', got '$actual')"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if grep -qF -- "$needle" <<< "$haystack"; then
        echo -e "  ${GREEN}[PASS]${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} $message (expected '$needle' in output)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if grep -qF -- "$needle" <<< "$haystack"; then
        echo -e "  ${RED}[FAIL]${NC} $message (unexpected '$needle' in output)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    else
        echo -e "  ${GREEN}[PASS]${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    fi
}

prov_field() {  # prov_field <provenance-file> <key>
    grep -m1 "^$2=" "$1" 2>/dev/null | cut -d= -f2-
}

# ─── Fixture: an installable source clone, installed into a sandbox prefix ───
#
# The source is a clone, not this checkout: the dirty-tree cases have to add an
# untracked file to the tree being installed FROM, and doing that here would
# dirty the developer's own repository.
SRC="$TEST_DIR/src"
HOME_DIR="$TEST_DIR/home"
BIN_DIR="$TEST_DIR/install/bin"
LIB_DIR="$TEST_DIR/install/lib"
CONFIG_DIR="$TEST_DIR/install/config"
PROV="$LIB_DIR/lib/INSTALL_PROVENANCE"

mkdir -p "$TEST_DIR" "$HOME_DIR" "$BIN_DIR" "$LIB_DIR" "$CONFIG_DIR"
git clone -q --shared "$PROJECT_ROOT" "$SRC"
# The clone alone checks out HEAD, so the suite would exercise the COMMITTED
# install.sh and never the working tree -- which is the copy the pre-commit
# gate is guarding and the only one an uncommitted fix lives in. Overlay the
# tracked working-tree files and commit them, so the fixture is both current
# and clean (dirty= has to start false for the untracked case to mean
# anything). Found by mutation-checking: reverting the fix left the suite
# green, because the suite was reading a different copy of the file.
# One tar, fed the file list directly: piping through `xargs -0 tar cf -`
# splits a long list across several tar invocations, and the receiving tar
# reads only the first archive, so the rest die on SIGPIPE.
git -C "$PROJECT_ROOT" ls-files -z \
    | tar -C "$PROJECT_ROOT" --null --files-from=- -cf - \
    | tar -C "$SRC" -xf -
git -C "$SRC" add -A
git -C "$SRC" -c user.email=test@test -c user.name=test -c commit.gpgsign=false \
    commit -q -m "working tree under test" >/dev/null 2>&1 || true
if [ -n "$(git -C "$SRC" status --porcelain)" ]; then
    echo "fixture error: source clone is not clean before the first install" >&2
    exit 1
fi

run_install() {  # run_install [extra env assignments handled by caller]
    (
        cd "$SRC"
        HOME="$HOME_DIR" \
        CLAUDE_CONFIG_DIR="$HOME_DIR/.claude" \
        WV_INSTALL_DIR="$BIN_DIR" \
        WV_LIB_DIR="$LIB_DIR" \
        WV_CONFIG_DIR="$CONFIG_DIR" \
            bash ./install.sh
    ) >/dev/null 2>&1
}

doctor_provenance_line() {  # doctor_provenance_line [lib-dir-override]
    local lib="${1:-$LIB_DIR}"
    (
        HOME="$HOME_DIR" \
        CLAUDE_CONFIG_DIR="$HOME_DIR/.claude" \
        WV_LIB_DIR="$lib" \
        WV_HOT_ZONE="$TEST_DIR/hotzone" \
        WV_DB="$TEST_DIR/hotzone/brain.db" \
            bash "$BIN_DIR/wv" doctor 2>&1
    ) | grep -m1 "install provenance" || true
}

# ─── Tests ──────────────────────────────────────────────────────────────────

test_clean_source_records_clean_install() {
    echo "-- install from a clean checkout records dirty=false"
    run_install
    assert_equals "false" "$(prov_field "$PROV" dirty)" "a clean source tree records dirty=false"
    assert_equals "$(git -C "$SRC" rev-parse HEAD)" "$(prov_field "$PROV" commit)" \
        "provenance records the source commit"
    assert_equals \
        "$(sha256sum "$SRC/scripts/weave_quality/default_patterns/manifest.json" | cut -d' ' -f1)" \
        "$(sha256sum "$LIB_DIR/weave_quality/default_patterns/manifest.json" | cut -d' ' -f1)" \
        "local install preserves the default-pattern authority manifest bytes"
}

test_untracked_files_count_as_dirty() {
    echo "-- an untracked file in the source tree makes the install dirty"
    # The defect: `git diff --quiet HEAD` reports a tree carrying new,
    # uncommitted files as clean, so the install claimed to be reproducible
    # from a commit that does not contain those files.
    # Deliberately extension-less: this repository gitignores *.txt, and an
    # ignored probe is invisible to `git status --porcelain` too, which makes
    # the test pass for the wrong reason -- it did, on the first run.
    printf 'uncommitted\n' > "$SRC/untracked-probe"
    run_install
    rm -f "$SRC/untracked-probe"
    assert_equals "true" "$(prov_field "$PROV" dirty)" \
        "an untracked file in the source tree records dirty=true"
}

test_dirty_install_warns() {
    echo "-- doctor WARNS on an install built from a dirty tree"
    # Provenance still says dirty=true from the test above; assert the report,
    # not just the file. A dirty install matches no commit, so a pass here hid
    # the one case where the running code corresponds to nothing in history.
    local line
    line=$(doctor_provenance_line)
    assert_contains "$line" "DIRTY tree" "doctor reports the install as built from a dirty tree"
    assert_not_contains "$line" "✓" "a dirty install is not reported as a pass"
    # Restore a clean install for the remaining tests.
    run_install
    assert_equals "false" "$(prov_field "$PROV" dirty)" "reinstall from the clean tree clears dirty"
}

test_doctor_honours_wv_lib_dir() {
    echo "-- doctor reads provenance from WV_LIB_DIR, not a hardcoded path"
    # The defect: with the library relocated, doctor described a DIFFERENT
    # install than the one the caller was running. A decoy at the default path
    # is what makes the difference observable.
    mkdir -p "$HOME_DIR/.local/lib/weave/lib"
    cat > "$HOME_DIR/.local/lib/weave/lib/INSTALL_PROVENANCE" <<'DECOY'
installed_at=2020-01-01T00:00:00Z
source_path=/nonexistent/decoy
commit=0000000000000000000000000000000000000000
describe=DECOY-AT-DEFAULT-PATH
branch=decoy
dirty=false
DECOY
    local line
    line=$(doctor_provenance_line "$LIB_DIR")
    assert_not_contains "$line" "DECOY-AT-DEFAULT-PATH" \
        "doctor does not read the default path when WV_LIB_DIR points elsewhere"
    assert_contains "$line" "$(prov_field "$PROV" describe)" \
        "doctor reports the relocated install's own describe"
}

test_remote_install_records_provenance() {
    echo "-- a remote install records provenance too"
    # A remote install has no source checkout, but recording nothing made
    # doctor's "not recorded — re-run ./install.sh" advice unclearable: the
    # reinstall it asked for produced the same empty state. Served offline by a
    # curl stand-in that resolves GitHub URLs against this checkout, so the
    # remote branch of install.sh runs for real without network.
    local remote_home="$TEST_DIR/remote-home"
    local remote_lib="$TEST_DIR/remote/lib"
    local remote_bin="$TEST_DIR/remote/bin"
    local remote_config="$TEST_DIR/remote/config"
    local stub_dir="$TEST_DIR/stub-bin"
    local cwd="$TEST_DIR/not-a-checkout"
    mkdir -p "$remote_home" "$remote_lib" "$remote_bin" "$remote_config" "$stub_dir" "$cwd"

    cat > "$stub_dir/curl" <<'STUB'
#!/usr/bin/env bash
# Offline stand-in for curl: resolves GitHub raw/API URLs against a local
# checkout so install.sh's download branch can run without network.
set -u
url=""
out=""
while [ $# -gt 0 ]; do
    case "$1" in
        --version) echo "curl 8.0.0 (offline test stub)"; exit 0 ;;
        -o) out="$2"; shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done
raw="https://raw.githubusercontent.com/AGM1968/weave/main/"
api="https://api.github.com/repos/AGM1968/weave/contents/"
emit() { if [ -n "$out" ]; then cat > "$out"; else cat; fi; }
case "$url" in
    "$raw"*)
        rel="${url#"$raw"}"
        [ -f "$WV_TEST_CURL_SRC/$rel" ] || exit 22
        emit < "$WV_TEST_CURL_SRC/$rel"
        ;;
    "$api"*)
        rel="${url#"$api"}"
        rel="${rel%%\?*}"
        [ -d "$WV_TEST_CURL_SRC/$rel" ] || exit 22
        {
            printf '['
            sep=""
            for entry in "$WV_TEST_CURL_SRC/$rel"/*; do
                [ -f "$entry" ] || continue
                printf '%s{"name":"%s","type":"file"}' "$sep" "$(basename "$entry")"
                sep=","
            done
            printf ']'
        } | emit
        ;;
    *) exit 22 ;;
esac
STUB
    chmod +x "$stub_dir/curl"

    local rc=0
    (
        cd "$cwd"
        PATH="$stub_dir:$PATH" \
        WV_TEST_CURL_SRC="$SRC" \
        HOME="$remote_home" \
        CLAUDE_CONFIG_DIR="$remote_home/.claude" \
        WV_INSTALL_DIR="$remote_bin" \
        WV_LIB_DIR="$remote_lib" \
        WV_CONFIG_DIR="$remote_config" \
            bash "$SRC/install.sh"
    ) >"$TEST_DIR/remote-install.log" 2>&1 || rc=$?

    local remote_prov="$remote_lib/lib/INSTALL_PROVENANCE"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ -f "$remote_prov" ]; then
        echo -e "  ${GREEN}[PASS]${NC} a remote install writes INSTALL_PROVENANCE"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} a remote install writes INSTALL_PROVENANCE (rc=$rc, see $TEST_DIR/remote-install.log)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 0
    fi
    assert_contains "$(prov_field "$remote_prov" source_path)" "remote:" \
        "remote provenance names the remote source"
    assert_equals "unknown" "$(prov_field "$remote_prov" commit)" \
        "remote provenance is honest that the commit is unknown"
    assert_contains "$(prov_field "$remote_prov" describe)" "remote-" \
        "remote provenance describes itself as a remote install"
    assert_equals \
        "$(sha256sum "$SRC/scripts/weave_quality/default_patterns/manifest.json" | cut -d' ' -f1)" \
        "$(sha256sum "$remote_lib/weave_quality/default_patterns/manifest.json" | cut -d' ' -f1)" \
        "remote install preserves the default-pattern authority manifest bytes"
}

echo "=== install provenance regression tests ==="
test_clean_source_records_clean_install
test_untracked_files_count_as_dirty
test_dirty_install_warns
test_doctor_honours_wv_lib_dir
test_remote_install_records_provenance

echo ""
echo "Tests: $TESTS_RUN | Passed: $TESTS_PASSED | Failed: $TESTS_FAILED"
# tests/run-all.sh only parses a line matching "X/Y passed" (its comment says it
# prefers this form because tail -1 on the "Tests: X | Passed: Y | Failed: Z"
# line picks up "Failed: 0" as the test count). Without this line the suite
# contributes 0/0 to the run-all summary and reads as if it asserted nothing.
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
[ "$TESTS_FAILED" -eq 0 ] || exit 1
echo "ALL TESTS PASSED"
