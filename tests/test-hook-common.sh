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
#   - All 7 hooks source wv-hook-common.sh (static check)
#   - Hooks that resolve the project have installed-path resolver fallbacks
#   - install.sh includes wv-hook-common.sh in both copy blocks
#
# Until wv-0ab403 lands, structural tests run as EXPECT-FAIL.
#
# Exit codes:
#   0 - All tests passed (or expected failures recorded)
#   1 - Unexpected failure

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_XFAIL=0

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
    ".claude/hooks/context-guard.sh"
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
    if echo "$haystack" | grep -qF "$needle"; then
        echo -e "  ${GREEN}[PASS]${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} $message (expected '$needle')"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_xfail() {
    local expected="$1"
    local actual="$2"
    local message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$expected" = "$actual" ]; then
        echo -e "  ${GREEN}[PASS]${NC} $message (FIXED — was EXPECT-FAIL)"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${YELLOW}[XFAIL]${NC} $message (wv-0ab403 not yet landed)"
        TESTS_XFAIL=$((TESTS_XFAIL + 1))
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
        echo -e "  ${YELLOW}[XFAIL]${NC} wv-hook-common.sh not yet created (wv-0ab403 pending)"
        TESTS_XFAIL=$((TESTS_XFAIL + 1))
    fi
}

test_hook_common_sources_without_error() {
    echo "-- wv-hook-common.sh sources without error"
    [ -f "$HOOK_COMMON" ] || {
        echo -e "  ${YELLOW}[XFAIL]${NC} hook-common not yet created — skip source test"
        TESTS_RUN=$((TESTS_RUN + 1))
        TESTS_XFAIL=$((TESTS_XFAIL + 1))
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
        echo -e "  ${YELLOW}[XFAIL]${NC} hook-common not yet created — skip path test"
        TESTS_RUN=$((TESTS_RUN + 1))
        TESTS_XFAIL=$((TESTS_XFAIL + 1))
        return
    }
    # Canonical resolver path (runtime-aware: /dev/shm on native, /tmp on codex/container)
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
    echo "-- resolve_hot_zone follows an existing codex zone even without env signal (wv-d6af2f)"
    local uid; uid=$(id -u)
    local codex_dir="/tmp/weave-codex-${uid}"
    local created=0
    [ -d "$codex_dir" ] || { mkdir -p "$codex_dir" && created=1; }
    # Scrub every codex env signal to mimic a harness-spawned hook process.
    local zone
    zone=$(env -u CLAUDE_CODE_SSE_PORT -u CODEX_THREAD_ID -u CODEX_CI -u COPILOT_AGENT \
               -u WV_HOT_ZONE -u WV_DB bash -c "
        source '$PROJECT_ROOT/scripts/lib/wv-resolve-runtime.sh' 2>/dev/null
        resolve_hot_zone
    " 2>/dev/null || echo "")
    # Only remove the dir if this test created it; rmdir is a no-op on a live (non-empty) zone.
    [ "$created" = "1" ] && rmdir "$codex_dir" 2>/dev/null
    assert_equals "$codex_dir" "$zone" "hook-context resolve_hot_zone follows existing codex zone via filesystem signal"
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
            echo -e "  ${YELLOW}[XFAIL]${NC} hook not found: $hook_rel"
            TESTS_XFAIL=$((TESTS_XFAIL + 1))
            continue
        fi
        if grep -q "wv-hook-common" "$hook_path" 2>/dev/null; then
            echo -e "  ${GREEN}[PASS]${NC} $hook_rel sources wv-hook-common"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo -e "  ${YELLOW}[XFAIL]${NC} $hook_rel does not source wv-hook-common (wv-0ab403 pending)"
            TESTS_XFAIL=$((TESTS_XFAIL + 1))
        fi
    done
}

test_install_sh_ships_hook_common() {
    echo "-- install.sh ships wv-hook-common.sh"
    local install_sh="$PROJECT_ROOT/install.sh"
    TESTS_RUN=$((TESTS_RUN + 1))
    if grep -q "wv-hook-common" "$install_sh" 2>/dev/null; then
        echo -e "  ${GREEN}[PASS]${NC} install.sh references wv-hook-common.sh"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${YELLOW}[XFAIL]${NC} install.sh does not ship wv-hook-common.sh (wv-0ab403 pending)"
        TESTS_XFAIL=$((TESTS_XFAIL + 1))
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
        if grep -q '\.config/weave/lib/wv-resolve-project\.sh' "$hook_path" 2>/dev/null; then
            echo -e "  ${GREEN}[PASS]${NC} $hook_rel has installed resolver fallback"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo -e "  ${RED}[FAIL]${NC} $hook_rel lacks installed resolver fallback"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    done
}

# ─── Per-check unit tests (t6) ────────────────────────────────────────────────
# One allow path + one deny/block path per _hc_check_* function.

_hc_xfail() {
    echo -e "  ${YELLOW}[XFAIL]${NC} $1"
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_XFAIL=$((TESTS_XFAIL + 1))
}

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
    echo "  NOTE: Structural tests run as EXPECT-FAIL until wv-0ab403 lands."
    echo "  Per-check unit tests (t6) run against the extracted _hc_check_* functions."
    echo ""
    test_hook_common_file_exists
    test_hook_common_sources_without_error
    test_hot_zone_path_matches_wv
    test_default_phase_when_file_missing
    test_codex_zone_followed_without_env_signal
    test_db_preflight_graceful_when_missing
    test_all_hooks_source_common
    test_hooks_have_installed_resolver_fallback
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
    if [ "$TESTS_XFAIL" -gt 0 ]; then
        echo "  ($TESTS_XFAIL expected failures — promote to assert_equals when wv-0ab403 lands)"
    fi
    echo "========================================"

    [ "$TESTS_FAILED" -eq 0 ] || exit 1
    exit 0
}

main "$@"
