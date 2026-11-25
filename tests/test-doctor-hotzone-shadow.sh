#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# test-doctor-hotzone-shadow.sh — wv doctor's second-brain.db advisory
#
# Source: wv-854b4a (decision wv-ff0419 Q1: the hot-zone rule belongs to the
# tool). Placement adopts the zone holding this repository's database
# (wv-b831e3), so a brain.db under a placement root it does not resolve to is
# an empty one or debris (wv refuses when two non-empty ones exist). On
# 2026-09-25 an empty one, created by
# sqlite3 opening a guessed /dev/shm path, was read as a split brain.
#
# Covers:
#   - PASS: no brain.db for this repo outside the live hot zone
#   - WARN: an empty brain.db under another root (guessed-path debris)
#   - WARN: a non-empty brain.db under another root (second DB for the repo)
#   - the live hot zone's own root is never reported
#   - planted shadows do not change what wv hotzone db resolves
#   - wv help hotzone lists the db subcommand
#   - the /tmp zone's two names: which is physical, in every state (wv-7e1e49)
#
# Roots come from WV_DOCTOR_PLACEMENT_ROOTS, so nothing is planted in the real
# /tmp/weave-hotzone-<uid> (or its legacy name) or /dev/shm/weave.
#
# Exit codes:
#   0 - All tests passed
#   1 - Unexpected failure

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
# The product's md5sum (wv-resolve-runtime.sh, side-effect free): the repo hash a
# product path is keyed on, the same on macOS, which has no md5sum(1) (wv-ef5621).
# shellcheck disable=SC1091  # resolved at run time
source "$PROJECT_ROOT/scripts/lib/wv-resolve-runtime.sh"
WV="$PROJECT_ROOT/scripts/wv"

TEST_DIR="/tmp/wv-doctor-hzshadow-fixture-$$"
export WV_CONFIG_DIR="$TEST_DIR/config"

cleanup() { cd /tmp && rm -rf "$TEST_DIR"; }
trap cleanup EXIT

setup_test_env() {
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR/repo" "$TEST_DIR/roots/live" "$TEST_DIR/roots/other-a" "$TEST_DIR/roots/other-b"
    cd "$TEST_DIR/repo"
    git init -q
    export WV_PROJECT_DIR="$TEST_DIR/repo"
    HASH=$(echo "$TEST_DIR/repo" | md5sum | cut -c1-8)
    export WV_HOT_ZONE="$TEST_DIR/roots/live/$HASH"
    export WV_DOCTOR_PLACEMENT_ROOTS="$TEST_DIR/roots/live $TEST_DIR/roots/other-a $TEST_DIR/roots/other-b"
    "$WV" init >/dev/null 2>&1 || true
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"
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
    local haystack="$1"
    local needle="$2"
    local message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if grep -qF -- "$needle" <<< "$haystack"; then
        echo -e "  ${RED}[FAIL]${NC} $message (unexpected '$needle' in output)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    else
        echo -e "  ${GREEN}[PASS]${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    fi
}

assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$expected" = "$actual" ]; then
        echo -e "  ${GREEN}[PASS]${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} $message (expected '$expected', got '$actual')"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# ─── Tests ──────────────────────────────────────────────────────────────────

test_clean_passes() {
    echo "-- only the live hot zone holds this repo's brain.db → PASS"
    local out
    out=$("$WV" doctor 2>&1 || true)
    assert_contains "$out" "hot-zone shadow" "doctor emits a hot-zone shadow check"
    assert_contains "$out" "no brain.db for this repo outside" "doctor reports no second DB"
    assert_not_contains "$out" "$TEST_DIR/roots/live/$HASH/brain.db (left by" "the live zone is never reported as a shadow"
}

test_empty_shadow_warns() {
    echo "-- an empty brain.db under another root → WARN, names wv hotzone db"
    mkdir -p "$TEST_DIR/roots/other-a/$HASH"
    : > "$TEST_DIR/roots/other-a/$HASH/brain.db"
    local out
    out=$("$WV" doctor 2>&1 || true)
    assert_contains "$out" "empty $TEST_DIR/roots/other-a/$HASH/brain.db" "doctor names the empty shadow"
    assert_contains "$out" "left by opening a guessed path" "doctor says how an empty shadow arises"
    assert_contains "$out" "wv hotzone db" "doctor points at the resolver"
}

test_nonempty_shadow_warns() {
    echo "-- a non-empty brain.db under another root → WARN as a second DB"
    mkdir -p "$TEST_DIR/roots/other-b/$HASH"
    sqlite3 "$TEST_DIR/roots/other-b/$HASH/brain.db" "CREATE TABLE nodes(id TEXT);"
    local out
    out=$("$WV" doctor 2>&1 || true)
    assert_contains "$out" "second brain.db for this repo at $TEST_DIR/roots/other-b/$HASH/brain.db" \
        "doctor names the second DB"
    assert_contains "$out" "Placement adopts the zone holding a database (wv-b831e3)" "doctor states the placement rule"
    assert_contains "$out" "wv hotzone diff $TEST_DIR/roots/live/$HASH/brain.db $TEST_DIR/roots/other-b/$HASH/brain.db" \
        "doctor says to diff the two copies before removing either (wv-a73141)"
    assert_not_contains "$out" "keep one and remove the other" "doctor no longer advises sync-free removal"
}

test_alias_of_the_live_zone_is_not_a_shadow() {
    echo "-- the live DB reached through an alias root → PASS, the same file, never 'remove' (wv-6f2eed)"
    rmdir "$TEST_DIR/roots/other-a"
    ln -s "$TEST_DIR/roots/live" "$TEST_DIR/roots/other-a"
    local out
    out=$("$WV" doctor 2>&1 || true)
    assert_contains "$out" "no brain.db for this repo outside" "doctor reports no second DB"
    assert_contains "$out" "also reached as $TEST_DIR/roots/other-a/$HASH/brain.db: the same file" \
        "doctor names the alias path as the same file"
    assert_not_contains "$out" "second brain.db" "the live DB under its other name is not a second DB"
    assert_not_contains "$out" "keep one and remove the other" "doctor never advises removing the live DB"
}

test_live_zone_under_its_alias_name() {
    echo "-- the live zone resolved by its alias name, the real directory a root → PASS"
    rmdir "$TEST_DIR/roots/other-a"
    ln -s "$TEST_DIR/roots/live" "$TEST_DIR/roots/other-a"
    local out
    out=$(WV_HOT_ZONE="$TEST_DIR/roots/other-a/$HASH" "$WV" doctor 2>&1 || true)
    assert_contains "$out" "no brain.db for this repo outside" "doctor reports no second DB"
    assert_not_contains "$out" "second brain.db" "the real path of the live DB is not a second DB"
}

test_one_file_two_names_reported_once() {
    echo "-- a second DB reached by two roots is reported once"
    mkdir -p "$TEST_DIR/roots/other-b/$HASH"
    sqlite3 "$TEST_DIR/roots/other-b/$HASH/brain.db" "CREATE TABLE nodes(id TEXT);"
    rmdir "$TEST_DIR/roots/other-a"
    ln -s "$TEST_DIR/roots/other-b" "$TEST_DIR/roots/other-a"
    local out
    out=$("$WV" doctor 2>&1 || true)
    assert_equals "1" "$(grep -c "second brain.db" <<< "$out")" "one warning for one file"
}

test_resolution_unchanged() {
    echo "-- planted shadows do not change what wv hotzone db resolves"
    local before after
    before=$("$WV" hotzone db 2>/dev/null)
    mkdir -p "$TEST_DIR/roots/other-a/$HASH" "$TEST_DIR/roots/other-b/$HASH"
    : > "$TEST_DIR/roots/other-a/$HASH/brain.db"
    sqlite3 "$TEST_DIR/roots/other-b/$HASH/brain.db" "CREATE TABLE nodes(id TEXT);"
    after=$("$WV" hotzone db 2>/dev/null)
    assert_equals "$before" "$after" "wv hotzone db resolves the same path with shadows present"
    assert_equals "$TEST_DIR/roots/live/$HASH/brain.db" "$after" "and that path is the live zone"
}

# The /tmp zone's two names (wv-7e1e49): doctor says which is physical. The
# names live under WV_TEST_HOT_ZONE_ROOT, so nothing touches the real /tmp zone;
# WV_HOT_ZONE keeps the repo's own zone out of it.
# names_record prints the hot-zone names check as "<status>|<detail>", so each
# case asserts the verdict and the message together (wv-9d2cd2: a verdict that
# disagrees with the guard is the defect, whatever the message says).
names_record() {
    WV_TEST_MODE=1 WV_TEST_HOT_ZONE_ROOT="$TEST_DIR/z" "$WV" doctor --json 2>/dev/null \
        | python3 -c 'import json,sys
for c in json.load(sys.stdin).get("checks", []):
    if c.get("check") == "hot-zone names":
        print(c["status"] + "|" + c["detail"])' || true
}

test_zone_names() {
    local uid n l out
    uid=$(id -u)
    n="$TEST_DIR/z/tmp/weave-hotzone-$uid"
    l="$TEST_DIR/z/tmp/weave-codex-$uid"
    mkdir -p "$TEST_DIR/z/tmp"

    # The two /tmp names are Linux placement; on macOS the zone is under
    # $TMPDIR and doctor skips this check by design (wv-cmd-doctor.sh
    # _doctor_check_hot_zone_names). Assert that, not the Linux cases (wv-f8e26d).
    case "${OSTYPE:-}" in darwin*)
        echo "-- zone names: darwin"
        mkdir -m 700 "$l"
        assert_equals "" "$(names_record)" "PASS: doctor reports no /tmp zone names on macOS"
        rmdir "$l"
        return 0 ;;
    esac

    echo "-- zone names: neither exists"
    out=$(names_record)
    assert_equals "pass|neither $n nor $l is a zone; first use creates $n and the fence link $l" "$out" \
        "PASS: doctor says what first use creates (wv-97d68a)"

    echo "-- zone names: legacy directory only"
    mkdir -m 700 "$l"
    out=$(names_record)
    assert_equals "pass|physical: $l (legacy layout); the alias $n is added on the next wv call that opens the zone. To relocate: wv hotzone migrate, in a quiet window" "$out" \
        "PASS: doctor names the legacy directory physical"

    echo "-- zone names: the alias"
    ln -s "$l" "$n"
    out=$(names_record)
    assert_equals "pass|physical: $l (legacy layout); $n is an alias of it. To relocate: wv hotzone migrate, in a quiet window" "$out" \
        "PASS: doctor reports both names and the physical one"

    echo "-- zone names: an alias with a trailing slash, which the guard refuses (wv-9d2cd2)"
    rm "$n"; ln -s "$l/" "$n"
    out=$(names_record)
    assert_equals "warn|$n is a symlink to $l/, not $l; wv refuses it as a hot-zone base" "$out" \
        "WARN: doctor agrees with the guard about an inexact target"

    echo "-- zone names: an alias whose target is absent, which first use replaces (wv-9d2cd2, wv-97d68a)"
    rm "$n"; ln -s "$l" "$n"; rmdir "$l"
    out=$(names_record)
    assert_equals "pass|$n is an alias of $l, which is absent; the next wv call that opens the zone makes $n the physical directory" "$out" \
        "PASS: doctor agrees with the guard about a dangling alias"
    mkdir -m 700 "$l"

    echo "-- zone names: an alias to another directory"
    rm "$n"; mkdir -m 700 "$TEST_DIR/z/other"; ln -s "$TEST_DIR/z/other" "$n"
    out=$(names_record)
    assert_equals "warn|$n is a symlink to $TEST_DIR/z/other, not $l; wv refuses it as a hot-zone base" "$out" \
        "WARN: doctor warns about an alias to anything else"

    echo "-- zone names: neutral directory only"
    rm "$n"; rmdir "$l"; mkdir -m 700 "$n"
    out=$(names_record)
    assert_equals "pass|physical: $n; legacy name $l absent (the next wv call that opens the zone adds its fence link)" "$out" \
        "PASS: doctor names the neutral directory physical"

    echo "-- zone names: neutral directory with its legacy fence link (wv-97d68a)"
    ln -s "$n" "$l"
    out=$(names_record)
    assert_equals "pass|physical: $n; legacy name $l is its fence link (wv-97d68a)" "$out" \
        "PASS: doctor names the fence link"
    rm "$l"

    echo "-- zone names: two directories, neither populated (wv-9d2cd2)"
    mkdir -m 700 "$l"
    out=$(names_record)
    assert_equals "pass|physical: $l (neither holds a database, so the legacy directory is the default authority); $n and $l are separate directories" "$out" \
        "PASS: doctor calls the empty legacy directory the default, not the one holding databases"

    echo "-- zone names: two directories, only the legacy one populated"
    mkdir -m 700 "$l/aaaa1111"
    sqlite3 "$l/aaaa1111/brain.db" "CREATE TABLE nodes(id TEXT);"
    out=$(names_record)
    assert_equals "pass|physical: $l (the one holding databases); $n and $l are separate directories" "$out" \
        "PASS: doctor names the populated legacy directory physical"

    echo "-- zone names: two directories, both populated"
    mkdir -m 700 "$n/bbbb2222"
    sqlite3 "$n/bbbb2222/brain.db" "CREATE TABLE nodes(id TEXT);"
    out=$(names_record)
    assert_equals "warn|$n and $l are separate directories that both hold databases; wv refuses to pick one" "$out" \
        "WARN: doctor warns about two populated zones"
}

test_help_lists_db() {
    echo "-- wv help hotzone lists the db subcommand"
    local out
    out=$("$WV" help hotzone 2>&1 || true)
    assert_contains "$out" "wv hotzone db" "help names wv hotzone db"
    assert_contains "$out" "sqlite3 on a guessed path creates an empty database" "help says why to use it"
}

main() {
    echo "========================================"
    echo "Doctor Hot-Zone Shadow Advisory (wv-854b4a)"
    echo "========================================"

    setup_test_env; test_clean_passes
    setup_test_env; test_empty_shadow_warns
    setup_test_env; test_nonempty_shadow_warns
    setup_test_env; test_alias_of_the_live_zone_is_not_a_shadow
    setup_test_env; test_live_zone_under_its_alias_name
    setup_test_env; test_one_file_two_names_reported_once
    setup_test_env; test_resolution_unchanged
    setup_test_env; test_zone_names
    setup_test_env; test_help_lists_db

    echo ""
    echo "========================================"
    echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
    echo "========================================"

    [ "$TESTS_FAILED" -eq 0 ] || exit 1
    exit 0
}

main "$@"
