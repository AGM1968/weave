#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# test-doctor-closed-node-dirt.sh — wv doctor's closed-node uncommitted-dirt
# attribution advisory
#
# Source: wv-e48993 — pre-close-verification.sh's dirty-tree gate now scopes
# its BLOCKING check to the closing node's own touched_files (a same-repo
# fix), so foreign dirt from an already-closed session no longer blocks
# `wv done` and is no longer misattributed under the wrong node's Weave-ID.
# That fixed the false-block bug, but it also means a session can close
# every node it owns and still leave real work uncommitted with nothing
# reporting it afterward. This doctor check closes that gap: advisory only,
# it attributes current non-.weave dirt to a node (active or done) whose
# touched_files overlaps it, preferring an active-node match (ordinary
# in-progress work, never a warning) over a done-node match (plausibly
# left behind).
#
# wv-822bea/wv-950080 (distribution re-audit): the original version stopped
# at the FIRST candidate node (active nodes sorted first) whose touched_files
# overlapped ANY dirty path and reported pass/warn for the whole dirty set
# based on that one match alone -- a mixed dirty set (one file explained by
# an active node, a second file that is done-owned or fully unattributed)
# false-PASSED as soon as the active node matched, without ever looking at
# whether it explained the rest. It also used `grep -Ff` (substring, not
# exact-path) matching. Fixed: classify the FULL remainder after subtracting
# active-owned paths, exact-line matched, sourced from both the uncapped
# node_files table and the capped metadata.touched_files display copy.
#
# Covers:
#   - PASS: no non-.weave dirt at all
#   - PASS: dirt explained by a CURRENTLY ACTIVE node's own touched_files
#   - WARN with attribution: dirt matches a DONE node's touched_files and no
#     active node explains it
#   - WARN with no attribution: dirt matches neither an active nor a done
#     node's touched_files
#   - WARN (not false-PASS): a MIXED dirty set where one file is active-owned
#     and a second is done-owned/unowned -- the active match must not mask it
#   - substring/prefix collision: a node owning "foo" must not explain dirt
#     on "foo.txt" (exact path equality only)
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

TEST_DIR="/tmp/wv-doctor-closed-dirt-fixture-$$"
export WV_HOT_ZONE="$TEST_DIR/hotzone"

cleanup() { cd /tmp && rm -rf "$TEST_DIR"; }
trap cleanup EXIT

setup_test_env() {
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR/repo"
    cd "$TEST_DIR/repo"
    git init -q
    git config user.email t@t
    git config user.name t
    git config commit.gpgsign false
    touch README.md
    git add README.md
    git commit -q -m init
    "$WV" init >/dev/null 2>&1
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

test_clean_tree_passes() {
    echo "-- no non-.weave dirt at all -> doctor PASS"
    local out
    out=$("$WV" doctor 2>&1 || true)
    assert_contains "$out" "closed-node-dirt" "doctor emits a closed-node-dirt check"
    assert_contains "$out" "no uncommitted non-.weave files" "doctor reports a clean tree"
}

test_active_node_explains_dirt_passes() {
    echo "-- dirt matches a CURRENTLY ACTIVE node's touched_files -> doctor PASS"
    local id
    id=$("$WV" add "active owner" --status=active --force --criteria="c" --risks=low \
        --metadata='{"touched_files":["own.txt"]}' 2>&1 | grep -oE 'wv-[0-9a-f]+' | head -1)
    echo "work in progress" > own.txt
    local out
    out=$("$WV" doctor 2>&1 || true)
    assert_contains "$out" "closed-node-dirt" "doctor emits a closed-node-dirt check"
    assert_contains "$out" "explained by currently active node" "doctor treats active node's own dirt as ordinary, not a warning"
    "$WV" done "$id" --skip-verification >/dev/null 2>&1 || true
}

test_done_node_match_warns_with_attribution() {
    echo "-- dirt matches a DONE node's touched_files, no active match -> doctor WARN with attribution"
    local id
    id=$("$WV" add "closed owner" --status=active --force --criteria="c" --risks=low \
        --metadata='{"touched_files":["leftover.txt"]}' 2>&1 | grep -oE 'wv-[0-9a-f]+' | head -1)
    echo "seed" > seed.txt
    git add seed.txt
    git commit -q -m "feat: seed" -m "Weave-ID: $id"
    "$WV" done "$id" --verification-method=test --verification-evidence=pass --learning="decision: test" >/dev/null 2>&1 || true
    echo "leftover from that closed session" > leftover.txt
    local out
    out=$("$WV" doctor 2>&1 || true)
    assert_contains "$out" "closed-node-dirt" "doctor emits a closed-node-dirt check"
    assert_contains "$out" "already-closed node(s)" "doctor attributes the dirt to a done node that touched it"
}

test_unmatched_dirt_warns_without_attribution() {
    echo "-- dirt matches neither an active nor a done node -> doctor WARN, no attribution"
    echo "nobody's file" > orphan-dirt.txt
    local out
    out=$("$WV" doctor 2>&1 || true)
    assert_contains "$out" "closed-node-dirt" "doctor emits a closed-node-dirt check"
    assert_contains "$out" "no clear owner among active/done nodes" "doctor admits it cannot attribute the dirt"
}

test_mixed_dirt_does_not_false_pass() {
    echo "-- MIXED dirty set: one file active-owned, one file done-owned -> doctor WARN, not PASS"
    # This is the exact repro from the re-audit: an active node's own match
    # must not mask a second, unexplained dirty file.
    local active_id
    active_id=$("$WV" add "active partial owner" --status=active --force --criteria="c" --risks=low \
        --metadata='{"touched_files":["active.txt"]}' 2>&1 | grep -oE 'wv-[0-9a-f]+' | head -1)
    local done_id
    done_id=$("$WV" add "closed partial owner" --status=active --force --criteria="c" --risks=low \
        --metadata='{"touched_files":["leftover.txt"]}' 2>&1 | grep -oE 'wv-[0-9a-f]+' | head -1)
    echo "seed" > seed.txt
    git add seed.txt
    git commit -q -m "feat: seed" -m "Weave-ID: $done_id"
    "$WV" done "$done_id" --verification-method=test --verification-evidence=pass --learning="decision: test" >/dev/null 2>&1 || true
    echo "in progress" > active.txt
    echo "leftover from closed session" > leftover.txt
    local out
    out=$("$WV" doctor 2>&1 || true)
    assert_contains "$out" "closed-node-dirt" "doctor emits a closed-node-dirt check"
    assert_not_contains "$out" "explained by currently active node(s) own work" "doctor does not false-pass the mixed set on the active match alone"
    assert_contains "$out" "already-closed node(s)" "doctor still surfaces the done-owned remainder"
    "$WV" done "$active_id" --skip-verification >/dev/null 2>&1 || true
}

test_substring_owner_does_not_explain_longer_path() {
    echo "-- exact-path match only: a node owning \"foo\" must not explain dirt on \"foo.txt\""
    local id
    id=$("$WV" add "narrow owner" --status=active --force --criteria="c" --risks=low \
        --metadata='{"touched_files":["foo"]}' 2>&1 | grep -oE 'wv-[0-9a-f]+' | head -1)
    echo "unrelated longer path" > foo.txt
    local out
    out=$("$WV" doctor 2>&1 || true)
    assert_contains "$out" "closed-node-dirt" "doctor emits a closed-node-dirt check"
    assert_not_contains "$out" "explained by currently active node" "doctor does not let \"foo\" ownership substring-match \"foo.txt\""
    "$WV" done "$id" --skip-verification >/dev/null 2>&1 || true
}

test_json_mode_carries_the_same_advisory() {
    echo "-- wv doctor --json carries the same closed-node-dirt check"
    echo "nobody's file" > orphan-dirt.txt
    local out
    out=$("$WV" doctor --json 2>&1 || true)
    assert_contains "$out" '"check":"closed-node-dirt"' "doctor --json includes the closed-node-dirt check"
    assert_contains "$out" '"status":"warn"' "doctor --json marks it warn"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    echo "test-doctor-closed-node-dirt.sh"
    echo ""

    setup_test_env; test_clean_tree_passes
    setup_test_env; test_active_node_explains_dirt_passes
    setup_test_env; test_done_node_match_warns_with_attribution
    setup_test_env; test_unmatched_dirt_warns_without_attribution
    setup_test_env; test_mixed_dirt_does_not_false_pass
    setup_test_env; test_substring_owner_does_not_explain_longer_path
    setup_test_env; test_json_mode_carries_the_same_advisory

    echo ""
    echo "========================================"
    echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
    echo "========================================"

    [ "$TESTS_FAILED" -eq 0 ] || exit 1
    exit 0
}

main "$@"
