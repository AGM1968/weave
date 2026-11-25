#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# test-hook-common.sh — Tests for wv-hook-common.sh shared hook library
#
# Sprint 1 prerequisite: wv-0ab403 (feat(S1): extract wv-hook-common.sh)
# Also depends on: wv-b7813e (wv_set_phase) — common lib uses it
#
# Covers:
#   - wv-hook-common.sh can be sourced without error
#   - Hot-zone path resolution matches wv's own resolution
#   - Default phase (execute) when .session_phase missing
#   - DB pre-flight: exits 0 gracefully when brain.db missing
#   - All 7 hooks load wv-hook-common.sh, directly or through the library an
#     adapter sources (static check), and wv doctor and pattern-audit Check 4
#     apply the same rule (wv-b80a86)
#   - Hooks that resolve the project have installed-path resolver fallbacks
#   - install.sh includes wv-hook-common.sh in both copy blocks
#
# Exit codes:
#   0 - All tests passed
#   1 - Unexpected failure

set -euo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$PROJECT_ROOT/scripts/wv"
HOOK_COMMON="$PROJECT_ROOT/scripts/lib/wv-hook-common.sh"

HOOKS_NEEDING_COMMON=(
    ".claude/hooks/pre-action.sh"
    ".claude/hooks/session-start-context.sh"
    ".claude/hooks/session-end-sync.sh"
    ".claude/hooks/stop-check.sh"
    ".claude/hooks/pre-compact-context.sh"
    ".claude/hooks/wv-touched-files.sh"
)

HOOKS_NEEDING_RESOLVE_FALLBACK=(
    ".claude/hooks/pre-action.sh"
    ".claude/hooks/pre-claim-skills.sh"
    ".claude/hooks/pre-close-verification.sh"
    ".claude/hooks/pre-compact-context.sh"
    ".claude/hooks/session-end-sync.sh"
    ".claude/hooks/session-start-context.sh"
    ".claude/hooks/stop-check.sh"
    ".claude/hooks/wv-touched-files.sh"
)

TEST_DIR="/tmp/wv-hook-common-test-$$"
export WV_HOT_ZONE="$TEST_DIR"
export WV_DB="$TEST_DIR/brain.db"
export WV_REQUIRE_LEARNING=0
export WV_RUN_CACHE=0
export WV_PROJECT_DIR="$TEST_DIR"

cleanup() { cd /tmp && rm -rf "$TEST_DIR"; }
trap cleanup EXIT

setup_test_env() {
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR"
    export WV_PROJECT_DIR="$TEST_DIR"
    cd "$TEST_DIR"
    git init -q
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

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if grep -qF -- "$needle" <<< "$haystack"; then
        echo -e "  ${GREEN}[PASS]${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} $message (expected '$needle')"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}


# ─── Tests ────────────────────────────────────────────────────────────────────

test_hook_common_file_exists() {
    echo "-- wv-hook-common.sh exists"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ -f "$HOOK_COMMON" ]; then
        echo -e "  ${GREEN}[PASS]${NC} wv-hook-common.sh exists"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} wv-hook-common.sh does not exist"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

test_hook_common_sources_without_error() {
    echo "-- wv-hook-common.sh sources without error"
    [ -f "$HOOK_COMMON" ] || {
        echo -e "  ${RED}[FAIL]${NC} wv-hook-common.sh does not exist — cannot source it"
        TESTS_RUN=$((TESTS_RUN + 1))
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return
    }
    local rc=0
    bash -c "
        export WV_PROJECT_DIR='$TEST_DIR'
        source '$HOOK_COMMON' 2>/dev/null
    " || rc=$?
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$rc" -eq 0 ]; then
        echo -e "  ${GREEN}[PASS]${NC} wv-hook-common.sh sources without error"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} wv-hook-common.sh source failed with exit $rc"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

test_hot_zone_path_matches_wv() {
    echo "-- hot-zone path resolution matches wv CLI"
    setup_test_env
    [ -f "$HOOK_COMMON" ] || {
        echo -e "  ${RED}[FAIL]${NC} wv-hook-common.sh does not exist — cannot resolve its path"
        TESTS_RUN=$((TESTS_RUN + 1))
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return
    }
    # Canonical resolver path (the zone holding the repo's DB, else /tmp; wv-b831e3)
    local wv_zone
    wv_zone=$(bash -c "
        export WV_PROJECT_DIR='$TEST_DIR'
        source '$PROJECT_ROOT/scripts/lib/wv-resolve-runtime.sh' 2>/dev/null
        resolve_repo_hot_zone \"\" '$TEST_DIR'
    " 2>/dev/null || echo "")
    # hook-common must resolve the same path
    local common_zone
    common_zone=$(bash -c "
        export WV_PROJECT_DIR='$TEST_DIR'
        cd '$TEST_DIR'
        source '$HOOK_COMMON' 2>/dev/null
        echo \"\${_HC_HOT_ZONE:-MISSING}\"
    " 2>/dev/null || echo "MISSING")
    assert_equals "$wv_zone" "$common_zone" "hook-common hot-zone path matches canonical resolver"
}

test_default_phase_when_file_missing() {
    echo "-- default phase is execute when .session_phase missing"
    setup_test_env
    rm -f "$TEST_DIR/.session_phase"
    [ -f "$HOOK_COMMON" ] || {
        # Still verify the shell fallback pattern without hook-common
        local phase
        phase=$(cat "$TEST_DIR/.session_phase" 2>/dev/null || echo "execute")
        assert_equals "execute" "$phase" "shell fallback: missing file defaults to execute"
        return
    }
    local phase
    phase=$(bash -c "
        export WV_HOT_ZONE='$TEST_DIR'
        source '$HOOK_COMMON' 2>/dev/null
        echo \"\${_HC_PHASE:-execute}\"
    " 2>/dev/null || echo "execute")
    assert_equals "execute" "$phase" "hook-common: missing .session_phase defaults to execute"
}

test_codex_zone_followed_without_env_signal() {
    echo "-- resolve_hot_zone follows an existing legacy /tmp zone even without env signal (wv-d6af2f)"
    local uid; uid=$(id -u)
    # The commit gate runs suites with WV_TEST_HOT_ZONE_ROOT, which the resolver
    # honours under WV_TEST_MODE=1 and which this case does not scrub, so the
    # zone it plants and expects is under that root, as resolve_hot_zone's is.
    local root=""
    if [ "${WV_TEST_MODE:-}" = "1" ] && [ "${WV_TEST_HOT_ZONE_ROOT:0:1}" = "/" ]; then
        root="${WV_TEST_HOT_ZONE_ROOT%/}"
    fi
    local codex_dir="${root}/tmp/weave-codex-${uid}"
    local created=0
    [ -d "$codex_dir" ] || { mkdir -p "$codex_dir" && created=1; }
    # Scrub every codex env signal to mimic a harness-spawned hook process.
    local zone
    zone=$(env -u CLAUDE_CODE_SSE_PORT -u CLAUDECODE -u AI_AGENT -u CODEX_THREAD_ID -u CODEX_CI -u COPILOT_AGENT \
               -u WV_HOT_ZONE -u WV_DB bash -c "
        source '$PROJECT_ROOT/scripts/lib/wv-resolve-runtime.sh' 2>/dev/null
        resolve_hot_zone
    " 2>/dev/null || echo "")
    # By either of the /tmp zone's names: the neutral one once this host has
    # the alias (wv-95bddf); tests/test-hot-zone-placement.sh pins which. The
    # name must lead to the planted directory: mapping the neutral name onto it
    # unconditionally passed when no legacy zone existed and the resolver chose
    # the neutral one by default (wv-60edf8).
    local physical=""
    [ -n "$zone" ] && physical=$(readlink -f "$zone" 2>/dev/null || true)
    [ -n "$physical" ] && [ "$physical" = "$(readlink -f "$codex_dir")" ] && zone="$codex_dir"
    # Only remove the dir if this test created it; rmdir is a no-op on a live (non-empty) zone.
    [ "$created" = "1" ] && { rmdir "$codex_dir" 2>/dev/null || true; }
    assert_equals "$codex_dir" "$zone" "hook-context resolve_hot_zone follows the existing legacy /tmp zone via filesystem signal"
}

test_db_preflight_graceful_when_missing() {
    echo "-- DB pre-flight returns 1 (signal to caller: exit 0) when brain.db missing"
    setup_test_env
    rm -f "$TEST_DIR/brain.db"
    [ -f "$HOOK_COMMON" ] || { _hc_xfail "hook-common not yet created"; return; }
    local rc=0
    bash -c "
        export WV_HOT_ZONE='$TEST_DIR'
        export WV_DB='$TEST_DIR/brain.db'
        source '$HOOK_COMMON' 2>/dev/null
        _hc_db_preflight 2>/dev/null
    " || rc=$?
    assert_equals "1" "$rc" "_hc_db_preflight: returns 1 for missing DB (hook should exit 0)"
}

test_all_hooks_source_common() {
    echo "-- all 7 hooks source wv-hook-common.sh"
    for hook_rel in "${HOOKS_NEEDING_COMMON[@]}"; do
        local hook_path="$PROJECT_ROOT/$hook_rel"
        TESTS_RUN=$((TESTS_RUN + 1))
        if [ ! -f "$hook_path" ]; then
            echo -e "  ${RED}[FAIL]${NC} hook not found: $hook_rel"
            TESTS_FAILED=$((TESTS_FAILED + 1))
            continue
        fi
        # Code, not comments: an adapter that only mentions the library in a
        # comment would pass vacuously. A PreToolUse, PostToolUse or Stop
        # adapter loads it through the guard library it sources (wv-d3fbcb,
        # wv-594381, wv-25903d), so read that too.
        local code guard_lib
        code=$(grep -v '^[[:space:]]*#' "$hook_path" 2>/dev/null)
        for guard_lib in wv-pre-tool-use wv-post-tool-use wv-lifecycle-end; do
            if grep -qF -- "$guard_lib.sh" <<<"$code"; then
                code+=$'\n'$(grep -v '^[[:space:]]*#' "$PROJECT_ROOT/scripts/lib/$guard_lib.sh" 2>/dev/null)
            fi
        done
        if grep -q "wv-hook-common" <<<"$code"; then
            echo -e "  ${GREEN}[PASS]${NC} $hook_rel sources wv-hook-common"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo -e "  ${RED}[FAIL]${NC} $hook_rel does not load wv-hook-common, directly or through its library"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    done
}

# wv-b80a86: wv doctor and pattern-audit Check 4 judge hook wiring with one
# helper, _hook_common_unwired, which must agree with the static rule above:
# executable lines only, following the library an adapter sources. Before,
# both grepped the adapter file alone, so the four thin adapters failed and
# pre-action.sh passed on a comment.
test_hook_common_rule_shared() {
    echo "-- doctor and Check 4 share the hook-common rule"
    local ops="$PROJECT_ROOT/scripts/cmd/wv-cmd-doctor.sh" fx home rel out
    unwired() {  # unwired <root>: the helper, under pipefail, with no installed fallback
        HOME="$home" bash -c 'set -euo pipefail; source "$1"; _hook_common_unwired "$2"' _ "$ops" "$1" | paste -sd' ' -
    }
    fx=$(mktemp -d /tmp/wv-hc-rule-XXXXXX); home="$fx/home"
    mkdir -p "$home" "$fx/.claude/hooks" "$fx/scripts/lib"
    assert_equals "" "$(unwired "$PROJECT_ROOT")" "the live hooks all pass the shared rule, as the static check says"
    for rel in "${HOOKS_NEEDING_COMMON[@]}"; do
        printf '#!/bin/bash\nsource "$HOME/.config/weave/lib/wv-hook-common.sh"\n' > "$fx/$rel"
    done
    printf '#!/bin/bash\nfor d in x; do . "$d/wv-guard.sh"; done\n' > "$fx/.claude/hooks/pre-action.sh"
    printf '#!/bin/bash\n_src wv-hook-common\n' > "$fx/scripts/lib/wv-guard.sh"
    printf '#!/bin/bash\n# loads wv-hook-common, says the comment\nexit 0\n' > "$fx/.claude/hooks/stop-check.sh"
    printf '#!/bin/bash\n. "$d/wv-plain.sh"\n' > "$fx/.claude/hooks/session-end-sync.sh"
    printf '#!/bin/bash\n# wv-hook-common in a comment only\n:\n' > "$fx/scripts/lib/wv-plain.sh"
    printf '#!/bin/bash\n. "$d/wv-big.sh"\n' > "$fx/.claude/hooks/wv-touched-files.sh"
    { printf '_src wv-hook-common\n'; for _ in $(seq 6000); do printf 'filler_line_padding_padding\n'; done; } > "$fx/scripts/lib/wv-big.sh"
    out=$(unwired "$fx")
    assert_equals ".claude/hooks/session-end-sync.sh .claude/hooks/stop-check.sh" "$out" \
        "unwired: a comment-only hook and an adapter whose library does not load it, nothing else"
    assert_equals "0" "$(grep -c 'wv-touched-files' <<< "$out")" \
        "a library whose match precedes 120 KB passes under pipefail (no SIGPIPE false negative)"
    git -C "$fx" init -q
    out=$(cd "$fx" && HOME="$home" WV_HOT_ZONE="$fx/hot" WV_CONFIG_DIR="$fx/cfg" "$WV" pattern-audit --json 2>/dev/null \
        | jq -c '.pattern_audit.findings[] | select(.check == "hook_common_sourcing") | [.status, .count]')
    assert_equals '["fail",2]' "$out" "pattern-audit Check 4 reports the same two hooks"
    assert_equals "2" "$(grep -c '_hook_common_unwired "' "$ops")" \
        "doctor and Check 4 call the one helper (no second copy of the rule)"
    rm -rf "$fx"
}

test_install_sh_ships_hook_common() {
    echo "-- install.sh ships wv-hook-common.sh"
    local install_sh="$PROJECT_ROOT/install.sh"
    TESTS_RUN=$((TESTS_RUN + 1))
    if grep -q "wv-hook-common" "$install_sh" 2>/dev/null; then
        echo -e "  ${GREEN}[PASS]${NC} install.sh references wv-hook-common.sh"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} install.sh does not ship wv-hook-common.sh"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

test_hooks_have_installed_resolver_fallback() {
    echo "-- hooks that resolve projects have installed resolver fallback"
    for hook_rel in "${HOOKS_NEEDING_RESOLVE_FALLBACK[@]}"; do
        local hook_path="$PROJECT_ROOT/$hook_rel"
        TESTS_RUN=$((TESTS_RUN + 1))
        if [ ! -f "$hook_path" ]; then
            echo -e "  ${RED}[FAIL]${NC} hook not found: $hook_rel"
            TESTS_FAILED=$((TESTS_FAILED + 1))
            continue
        fi
        # Matches both shapes: a literal per-library source line, and a hook that
        # resolves the library NAME through a shared search path (pre-action.sh).
        # The assertion is that the installed location is reachable at all, not
        # that one particular line spells it out — pinning the line shape made a
        # refactor that KEPT the fallback look like it had dropped it.
        if grep -q '\.config/weave/lib/wv-resolve-project\.sh' "$hook_path" 2>/dev/null \
            || grep -q '\.config/weave/lib' "$hook_path" 2>/dev/null; then
            echo -e "  ${GREEN}[PASS]${NC} $hook_rel has installed resolver fallback"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo -e "  ${RED}[FAIL]${NC} $hook_rel lacks installed resolver fallback"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    done
}

# Behavioural counterpart to the grep above: prove pre-action.sh really does
# load its libraries from the installed location, by running a copy that has no
# sibling libs at all and a HOME pointing at a synthetic install. The grep can
# only see that a path is mentioned; this sees it used.
test_pre_action_resolves_installed_libs() {
    echo "-- pre-action.sh resolves libraries from the installed location"
    TESTS_RUN=$((TESTS_RUN + 1))

    local sandbox fake_home rc
    sandbox=$(mktemp -d)
    fake_home="$sandbox/home"
    mkdir -p "$fake_home/.config/weave/lib" "$sandbox/elsewhere"
    cp "$PROJECT_ROOT"/scripts/lib/wv-resolve-project.sh \
       "$PROJECT_ROOT"/scripts/lib/wv-validate.sh \
       "$PROJECT_ROOT"/scripts/lib/wv-config.sh \
       "$PROJECT_ROOT"/scripts/lib/wv-python-floor.sh \
       "$PROJECT_ROOT"/scripts/lib/wv-hook-common.sh \
       "$PROJECT_ROOT"/scripts/lib/wv-resolve-runtime.sh \
       "$PROJECT_ROOT"/scripts/lib/wv-pre-tool-use.sh \
       "$fake_home/.config/weave/lib/" 2>/dev/null
    cp "$PROJECT_ROOT/.claude/hooks/pre-action.sh" "$sandbox/elsewhere/pre-action.sh"

    # A malformed payload is the cheapest proof the libraries loaded: the exit-2
    # verdict comes from _hc_classify_tool + _hc_check_payload, so a hook that
    # failed to source them could not produce it.
    set +e
    env HOME="$fake_home" bash "$sandbox/elsewhere/pre-action.sh" \
        < <(echo '{"tool_input":{"file_path":"x.py"}}') >/dev/null 2>&1
    rc=$?
    set -e
    rm -rf "$sandbox"

    if [ "$rc" -eq 2 ]; then
        echo -e "  ${GREEN}[PASS]${NC} installed-location libraries are loaded and enforce"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} hook with no sibling libs did not enforce via installed libs (rc=$rc)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# A readable library is not necessarily a loadable one. When the nearest copy is
# broken, the search must fall through to a valid one further out: a hook that
# claims the load and then dies at its first _hc_* call exits 127, which
# PreToolUse reads as ALLOW — so a malformed mutation payload that must be
# blocked with 2 sails through instead. Silent, and worse than a hard failure.
test_pre_action_falls_through_broken_library() {
    echo "-- pre-action.sh falls through a broken nearest library (${1:-syntax})"
    TESTS_RUN=$((TESTS_RUN + 1))

    local sandbox fake_home rc
    sandbox=$(mktemp -d)
    fake_home="$sandbox/home"
    mkdir -p "$fake_home/.config/weave/lib" "$sandbox/hooks" "$sandbox/lib"
    cp "$PROJECT_ROOT"/scripts/lib/wv-resolve-project.sh \
       "$PROJECT_ROOT"/scripts/lib/wv-validate.sh \
       "$PROJECT_ROOT"/scripts/lib/wv-config.sh \
       "$PROJECT_ROOT"/scripts/lib/wv-python-floor.sh \
       "$PROJECT_ROOT"/scripts/lib/wv-hook-common.sh \
       "$PROJECT_ROOT"/scripts/lib/wv-resolve-runtime.sh \
       "$PROJECT_ROOT"/scripts/lib/wv-pre-tool-use.sh \
       "$fake_home/.config/weave/lib/" 2>/dev/null
    cp "$PROJECT_ROOT/.claude/hooks/pre-action.sh" "$sandbox/hooks/pre-action.sh"
    # The guard library sits beside the broken copy, so the search the guard
    # makes for its own libraries (wv-pre-tool-use.sh) meets the broken one first.
    cp "$PROJECT_ROOT/scripts/lib/wv-pre-tool-use.sh" "$sandbox/lib/"
    # Nearest candidate ($HOOK_DIR/../lib): readable, and broken in the way the
    # caller asks for. "syntax" dies before running anything; "guard" is the
    # nastier one — it sets the library's own double-source guard and THEN fails,
    # so a fallback that re-sources hits that guard and returns immediately,
    # leaving the library unloaded even though the source appeared to succeed.
    case "${1:-syntax}" in
        guard)  printf '_WV_HOOK_COMMON_LOADED=1\nreturn 1\n' > "$sandbox/lib/wv-hook-common.sh" ;;
        *)      printf 'this is ( not valid bash\n' > "$sandbox/lib/wv-hook-common.sh" ;;
    esac

    set +e
    env HOME="$fake_home" bash "$sandbox/hooks/pre-action.sh" \
        < <(echo '{"tool_input":{"file_path":"x.py"}}') >/dev/null 2>&1
    rc=$?
    set -e
    rm -rf "$sandbox"

    if [ "$rc" -eq 2 ]; then
        echo -e "  ${GREEN}[PASS]${NC} ${1:-syntax}-broken nearest library falls through to the installed one (rc=2)"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} expected 2 (block) with a ${1:-syntax}-broken nearest library, got rc=$rc"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# The edit guard fails closed (wv-187945, owner ruling 2026-11-03). It exited 0
# with a warning whenever it could not run, so a half-installed library or a
# missing graph database admitted every edit with no claim. Now an edit to a
# file in a Weave checkout is blocked with the fix named; a read, or an edit in
# no Weave checkout, still passes.
test_edit_guard_fails_closed() {
    echo "-- the edit guard fails closed when it cannot run"
    local sandbox proj plain fake_home rc err
    sandbox=$(mktemp -d)
    proj="$sandbox/proj" plain="$sandbox/plain" fake_home="$sandbox/home"
    mkdir -p "$proj/.weave" "$plain" "$fake_home/.config/weave/lib" "$sandbox/hooks" "$sandbox/lib"
    git -C "$proj" init -q
    _fc_case() {  # _fc_case <label> <expected rc> <hook> <payload> [stderr needle]
        TESTS_RUN=$((TESTS_RUN + 1))
        set +e
        err=$( (cd "$proj" && env -u WV_PROJECT_DIR -u CLAUDE_PROJECT_DIR HOME="$fake_home" \
            bash "$3" <<< "$4") 2>&1 >/dev/null)
        rc=$?
        set -e
        if [ "$rc" = "$2" ] && { [ -z "${5:-}" ] || grep -qF -- "$5" <<< "$err"; }; then
            echo -e "  ${GREEN}[PASS]${NC} $1"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo -e "  ${RED}[FAIL]${NC} $1 (rc=$rc, expected $2; stderr: ${err:0:200})"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    }
    _fc_edit() { jq -cn --arg t "$1" --arg p "$2" '{tool_name:$t,tool_input:{file_path:$p,old_string:"a",new_string:"b"}}'; }

    # 1. No guard library anywhere: the adapter alone decides.
    cp "$PROJECT_ROOT/.claude/hooks/pre-action.sh" "$sandbox/hooks/pre-action.sh"
    _fc_case "no guard library: an edit in a Weave checkout is blocked" 2 \
        "$sandbox/hooks/pre-action.sh" "$(_fc_edit Edit "$proj/app.py")" "Edits in $proj are blocked"
    _fc_case "no guard library: an edit outside any Weave checkout passes" 0 \
        "$sandbox/hooks/pre-action.sh" "$(_fc_edit Edit "$plain/notes.txt")"
    _fc_case "no guard library: a read passes" 0 \
        "$sandbox/hooks/pre-action.sh" "$(_fc_edit Read "$proj/app.py")"

    # 2. The guard loads but wv-hook-common does not.
    cp "$PROJECT_ROOT/scripts/lib/wv-pre-tool-use.sh" "$PROJECT_ROOT/scripts/lib/wv-resolve-project.sh" \
       "$PROJECT_ROOT/scripts/lib/wv-resolve-runtime.sh" "$sandbox/lib/"
    _fc_case "no wv-hook-common: an edit in a Weave checkout is blocked" 2 \
        "$sandbox/hooks/pre-action.sh" "$(_fc_edit Write "$proj/app.py")" "wv-hook-common.sh could not be loaded"
    _fc_case "no wv-hook-common: a read passes" 0 \
        "$sandbox/hooks/pre-action.sh" "$(_fc_edit Read "$proj/app.py")"

    # 3. Every library loads, but the project's graph database is missing.
    _fc_case "a missing graph database blocks an edit and says how to load it" 2 \
        "$PROJECT_ROOT/.claude/hooks/pre-action.sh" \
        "$(_fc_edit Edit "$proj/app.py")" "run any wv command"
    rm -rf "$sandbox"
}

# ─── Per-check unit tests (t6) ────────────────────────────────────────────────
# One allow path + one deny/block path per _hc_check_* function.


test_hc_check_installed_path_allow() {
    echo "-- _hc_check_installed_path: allow non-installed path"
    [ -f "$HOOK_COMMON" ] || { _hc_xfail "hook-common not yet created"; return; }
    local rc=0
    bash -c "
        source '$HOOK_COMMON' 2>/dev/null
        _hc_check_installed_path 'Edit' '{\"file_path\":\"/home/user/project/file.sh\"}'
    " 2>/dev/null || rc=$?
    assert_equals "0" "$rc" "_hc_check_installed_path: pass-through for non-installed path"
}

test_hc_check_installed_path_block() {
    echo "-- _hc_check_installed_path: hard-block ~/.local/bin edit"
    [ -f "$HOOK_COMMON" ] || { _hc_xfail "hook-common not yet created"; return; }
    local rc=0
    bash -c "
        source '$HOOK_COMMON' 2>/dev/null
        _hc_check_installed_path 'Edit' '{\"file_path\":\"/home/user/.local/bin/wv\"}'
    " 2>/dev/null || rc=$?
    assert_equals "2" "$rc" "_hc_check_installed_path: blocks ~/.local/bin edit (rc=2)"
}

test_hc_classify_tool_home_claude_exempt() {
    echo "-- _hc_classify_tool: \$HOME/.claude/ edit is exempt (SHOULD_CHECK=false)"
    [ -f "$HOOK_COMMON" ] || { _hc_xfail "hook-common not yet created"; return; }
    local should_check
    should_check=$(bash -c "
        export HOME='/home/testuser'
        source '$HOOK_COMMON' 2>/dev/null
        _hc_classify_tool 'Edit' '{\"file_path\":\"/home/testuser/.claude/projects/x/memory/foo.md\"}'
        echo \"\$_HC_SHOULD_CHECK\"
    " 2>/dev/null || echo "ERR")
    assert_equals "false" "$should_check" "_hc_classify_tool: \$HOME/.claude/ edit leaves SHOULD_CHECK=false"
}

test_hc_classify_tool_project_file_enforced() {
    echo "-- _hc_classify_tool: project file edit is enforced (SHOULD_CHECK=true)"
    [ -f "$HOOK_COMMON" ] || { _hc_xfail "hook-common not yet created"; return; }
    local should_check
    should_check=$(bash -c "
        export HOME='/home/testuser'
        source '$HOOK_COMMON' 2>/dev/null
        _hc_classify_tool 'Edit' '{\"file_path\":\"/home/testuser/Projects/repo/.claude/settings.json\"}'
        echo \"\$_HC_SHOULD_CHECK\"
    " 2>/dev/null || echo "ERR")
    assert_equals "true" "$should_check" "_hc_classify_tool: project-local .claude/ edit stays enforced (SHOULD_CHECK=true)"
}

test_hc_init_hygiene_tally_uses_hook_adapter_class() {
    echo "-- _hc_init_hygiene_tally: counts every manifest hook edit tool"
    [ -f "$HOOK_COMMON" ] || { _hc_xfail "hook-common not yet created"; return; }
    setup_test_env
    local tally
    tally=$(bash -c "
        export WV_HOT_ZONE='$TEST_DIR'
        source '$HOOK_COMMON' 2>/dev/null
        _hc_init_hygiene_tally 'mcp__ide__executeCode'
        printf '%s' \"\$_HC_TALLY_FILE\"
    " 2>/dev/null || echo "ERR")
    assert_equals "$TEST_DIR/session-edits.json" "$tally" "_hc_init_hygiene_tally: uses manifest tool class"
}

test_hc_classify_tool_manifest_commands_bypass() {
    echo "-- _hc_classify_tool: manifest safe commands bypass enforcement"
    [ -f "$HOOK_COMMON" ] || { _hc_xfail "hook-common not yet created"; return; }
    local command bypass
    for command in bootstrap search context quick recover; do
        bypass=$(bash -c "
            source '$HOOK_COMMON' 2>/dev/null
            _hc_classify_tool 'Bash' '{\"cmd\":\"wv $command\"}'
            echo \"\$_HC_BYPASS_CMD\"
        " 2>/dev/null || echo "ERR")
        assert_equals "true" "$bypass" "_hc_classify_tool: wv $command bypasses from manifest"
    done
}

test_hc_check_phase_allow_execute() {
    echo "-- _hc_check_phase: allow edit in execute phase"
    [ -f "$HOOK_COMMON" ] || { _hc_xfail "hook-common not yet created"; return; }
    setup_test_env
    local rc=0
    bash -c "
        export WV_HOT_ZONE='$TEST_DIR'
        source '$HOOK_COMMON' 2>/dev/null
        _HC_PHASE='execute'
        _HC_IS_EDIT_TOOL=true
        _hc_check_phase
    " 2>/dev/null || rc=$?
    assert_equals "0" "$rc" "_hc_check_phase: allows edit in execute phase"
}

test_hc_check_phase_block_discover_edit() {
    echo "-- _hc_check_phase: hard-block edit in discover phase"
    [ -f "$HOOK_COMMON" ] || { _hc_xfail "hook-common not yet created"; return; }
    setup_test_env
    local rc=0
    bash -c "
        export WV_HOT_ZONE='$TEST_DIR'
        source '$HOOK_COMMON' 2>/dev/null
        _HC_PHASE='discover'
        _HC_IS_EDIT_TOOL=true
        _hc_check_phase
    " 2>/dev/null || rc=$?
    assert_equals "2" "$rc" "_hc_check_phase: blocks edit in discover phase (rc=2)"
}

test_hc_check_active_node_allow() {
    echo "-- _hc_check_active_node: allow when active node exists"
    [ -f "$HOOK_COMMON" ] || { _hc_xfail "hook-common not yet created"; return; }
    setup_test_env
    local mock_wv="$TEST_DIR/mock-wv-node"
    printf '#!/bin/bash\necho '"'"'[{"id":"wv-abc123","text":"test","status":"active","updated_at":"2026-01-01T00:00:00Z"}]'"'"'\n' > "$mock_wv"
    chmod +x "$mock_wv"
    local rc=0
    bash -c "
        export WV_HOT_ZONE='$TEST_DIR'
        source '$HOOK_COMMON' 2>/dev/null
        WV='$mock_wv'
        _hc_check_active_node
    " 2>/dev/null || rc=$?
    assert_equals "0" "$rc" "_hc_check_active_node: allows when active node present"
}

test_hc_check_active_node_block_none() {
    echo "-- _hc_check_active_node: block when no active node (rc=2)"
    [ -f "$HOOK_COMMON" ] || { _hc_xfail "hook-common not yet created"; return; }
    setup_test_env
    local mock_wv="$TEST_DIR/mock-wv-empty"
    printf '#!/bin/bash\necho "[]"\n' > "$mock_wv"
    chmod +x "$mock_wv"
    local rc=0
    bash -c "
        export WV_HOT_ZONE='$TEST_DIR'
        source '$HOOK_COMMON' 2>/dev/null
        WV='$mock_wv'
        _hc_check_active_node
    " 2>/dev/null || rc=$?
    assert_equals "2" "$rc" "_hc_check_active_node: blocks (rc=2) when no active node"
}

test_hc_check_stale_node_allow_no_epoch() {
    echo "-- _hc_check_stale_node: allow when no epoch file"
    [ -f "$HOOK_COMMON" ] || { _hc_xfail "hook-common not yet created"; return; }
    setup_test_env
    rm -f "$TEST_DIR/.session_epoch"
    local rc=0
    bash -c "
        export WV_HOT_ZONE='$TEST_DIR'
        source '$HOOK_COMMON' 2>/dev/null
        _HC_ACTIVE_NODES='[{\"id\":\"wv-abc\",\"text\":\"old task\",\"updated_at\":\"2020-01-01T00:00:00Z\"}]'
        _hc_check_stale_node
    " 2>/dev/null || rc=$?
    assert_equals "0" "$rc" "_hc_check_stale_node: allows when no epoch file"
}

test_hc_check_stale_node_block_stale() {
    echo "-- _hc_check_stale_node: block when node predates session epoch"
    [ -f "$HOOK_COMMON" ] || { _hc_xfail "hook-common not yet created"; return; }
    setup_test_env
    echo "1767225600" > "$TEST_DIR/.session_epoch"  # 2026-01-01 00:00:00 UTC
    local rc=0
    bash -c "
        export WV_HOT_ZONE='$TEST_DIR'
        source '$HOOK_COMMON' 2>/dev/null
        _HC_ACTIVE_NODES='[{\"id\":\"wv-abc\",\"text\":\"old task\",\"updated_at\":\"2020-01-01T00:00:00Z\"}]'
        _hc_check_stale_node
    " 2>/dev/null || rc=$?
    assert_equals "2" "$rc" "_hc_check_stale_node: blocks stale node (epoch mismatch)"
}

test_hc_check_stale_node_allow_fresh_sqlite_utc() {
    echo "-- _hc_check_stale_node: allow fresh node in sqlite UTC format (no false TZ-stale)"
    [ -f "$HOOK_COMMON" ] || { _hc_xfail "hook-common not yet created"; return; }
    setup_test_env
    # Node updated 60s AFTER session start, in the real sqlite zone-less UTC format.
    # timegm(2026-01-01 12:00:00) = 1767268800; epoch 60s earlier = node is fresh.
    echo "1767268740" > "$TEST_DIR/.session_epoch"
    local rc=0
    # Force a UTC-ahead zone: a naive `date -d` (local) parse would read the stamp
    # ~5.5h earlier and falsely flag it stale. Correct UTC parse keeps it fresh.
    bash -c "
        export TZ='Asia/Kolkata'
        export WV_HOT_ZONE='$TEST_DIR'
        source '$HOOK_COMMON' 2>/dev/null
        _HC_ACTIVE_NODES='[{\"id\":\"wv-abc\",\"text\":\"fresh task\",\"updated_at\":\"2026-01-01 12:00:00\"}]'
        _hc_check_stale_node
    " 2>/dev/null || rc=$?
    assert_equals "0" "$rc" "_hc_check_stale_node: fresh sqlite-UTC node not falsely stale in UTC+ zone"
}

test_hc_check_contradictions_allow_none() {
    echo "-- _hc_check_contradictions: allow when no contradictions"
    [ -f "$HOOK_COMMON" ] || { _hc_xfail "hook-common not yet created"; return; }
    local rc=0
    bash -c "
        export WV_HOT_ZONE='$TEST_DIR'
        source '$HOOK_COMMON' 2>/dev/null
        _HC_CONTEXT_PACK='{\"contradictions\":[]}'
        _hc_check_contradictions 'wv-abc123'
    " 2>/dev/null || rc=$?
    assert_equals "0" "$rc" "_hc_check_contradictions: allows when no contradictions"
}

test_hc_check_contradictions_block_present() {
    echo "-- _hc_check_contradictions: block when contradictions present"
    [ -f "$HOOK_COMMON" ] || { _hc_xfail "hook-common not yet created"; return; }
    local rc=0
    bash -c "
        export WV_HOT_ZONE='$TEST_DIR'
        source '$HOOK_COMMON' 2>/dev/null
        _HC_CONTEXT_PACK='{\"contradictions\":[{\"id\":\"wv-xyz\",\"text\":\"conflicting node\"}]}'
        _hc_check_contradictions 'wv-abc123'
    " 2>/dev/null || rc=$?
    assert_equals "2" "$rc" "_hc_check_contradictions: blocks (rc=2) when contradictions present"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    echo "test-hook-common.sh"
    echo "  Per-check unit tests (t6) run against the extracted _hc_check_* functions."
    echo ""
    test_hook_common_file_exists
    test_hook_common_sources_without_error
    test_hot_zone_path_matches_wv
    test_default_phase_when_file_missing
    test_codex_zone_followed_without_env_signal
    test_db_preflight_graceful_when_missing
    test_all_hooks_source_common
    test_hook_common_rule_shared
    test_hooks_have_installed_resolver_fallback
    test_pre_action_resolves_installed_libs
    test_pre_action_falls_through_broken_library syntax
    test_pre_action_falls_through_broken_library guard
    test_edit_guard_fails_closed
    test_install_sh_ships_hook_common

    echo ""
    echo "-- per-check unit tests"
    test_hc_check_installed_path_allow
    test_hc_check_installed_path_block
    test_hc_classify_tool_home_claude_exempt
    test_hc_classify_tool_project_file_enforced
    test_hc_init_hygiene_tally_uses_hook_adapter_class
    test_hc_classify_tool_manifest_commands_bypass
    test_hc_check_phase_allow_execute
    test_hc_check_phase_block_discover_edit
    test_hc_check_active_node_allow
    test_hc_check_active_node_block_none
    test_hc_check_stale_node_allow_no_epoch
    test_hc_check_stale_node_block_stale
    test_hc_check_stale_node_allow_fresh_sqlite_utc
    test_hc_check_contradictions_allow_none
    test_hc_check_contradictions_block_present

    echo ""
    echo "========================================"
    echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
    echo "========================================"

    [ "$TESTS_FAILED" -eq 0 ] || exit 1
    exit 0
}

main "$@"
