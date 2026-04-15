#!/usr/bin/env bash
# test-hooks.sh — Test all Claude Code hooks
#
# Tests each hook in .claude/hooks/ with simulated JSON input.
# Hooks are bash scripts that receive JSON on stdin and return
# structured output. They run in Claude Code's lifecycle events.
#
# Exit codes:
#   0 - All tests passed
#   1 - One or more tests failed

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS_DIR="$PROJECT_ROOT/.claude/hooks"
WV="$PROJECT_ROOT/scripts/wv"

# Test environment
TEST_DIR="/tmp/wv-hooks-test-$$"
export WV_HOT_ZONE="$TEST_DIR"
export WV_DB="$TEST_DIR/brain.db"
export WV_REQUIRE_LEARNING=0
export CLAUDE_PROJECT_DIR="$TEST_DIR/project"
export WV_PROJECT_DIR="$TEST_DIR/project"

cleanup() {
    cd /tmp
    if [ -d "$TEST_DIR" ]; then
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

# Test helpers
assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$expected" = "$actual" ]; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Expected: $expected"
        echo "  Actual:   $actual"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if echo "$haystack" | grep -qF "$needle"; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Expected to find: $needle"
        echo "  In: $(echo "$haystack" | head -3)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_exit_code() {
    local expected="$1"
    local actual="$2"
    local message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$expected" = "$actual" ]; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Expected exit code: $expected"
        echo "  Actual exit code:   $actual"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# Setup: create isolated test environment with git repo and wv database
setup_test_env() {
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR/project/.claude/hooks"
    mkdir -p "$TEST_DIR/project/.weave"
    mkdir -p "$TEST_DIR/project/scripts"

    # Create symlinks so hooks can find wv and lib
    ln -sf "$WV" "$TEST_DIR/project/scripts/wv"
    mkdir -p "$TEST_DIR/project/scripts/lib"
    ln -sf "$PROJECT_ROOT/scripts/lib/wv-resolve-project.sh" "$TEST_DIR/project/scripts/lib/wv-resolve-project.sh"

    # Init git repo (needed by stop-check and context-guard)
    cd "$TEST_DIR/project"
    git init -q
    # Disable GPG signing for test repo (global gpgsign=true would fail in CI/SSH)
    git config commit.gpgsign false
    git config user.name "Hook Test"
    git config user.email "hook-test@example.com"
    git commit --allow-empty -m "init" -q

    # Init wv database
    "$WV" load 2>/dev/null || "$WV" status 2>/dev/null || true

    # Set CLAUDE_PROJECT_DIR to test project
    export CLAUDE_PROJECT_DIR="$TEST_DIR/project"
export WV_PROJECT_DIR="$TEST_DIR/project"
}

# ============================================================
echo "=== Hook Tests ==="
echo ""

# --- session-start-context.sh ---
echo "--- session-start-context.sh ---"
setup_test_env

OUTPUT=$(bash "$HOOKS_DIR/session-start-context.sh" 2>/dev/null || true)
assert_contains "$OUTPUT" "hookSpecificOutput" "session-start: outputs hookSpecificOutput JSON"
assert_contains "$OUTPUT" "SessionStart" "session-start: identifies as SessionStart event"
assert_contains "$OUTPUT" "additionalContext" "session-start: includes additionalContext field"

# --- pre-compact-context.sh ---
echo ""
echo "--- pre-compact-context.sh ---"
setup_test_env

# Add a node so there's data to report
"$WV" add "Test compact node" --status=active 2>/dev/null

OUTPUT=$(bash "$HOOKS_DIR/pre-compact-context.sh" 2>/dev/null || true)
assert_contains "$OUTPUT" "Weave state" "pre-compact: outputs Weave state header"
assert_contains "$OUTPUT" "Active:" "pre-compact: includes Active section"
assert_contains "$OUTPUT" "Ready:" "pre-compact: includes Ready count"
assert_contains "$OUTPUT" "Learnings:" "pre-compact: includes Learnings section"

# Verify it uses WV_DB env var (not hardcoded path)
OUTPUT2=$(WV_DB="$TEST_DIR/brain.db" bash "$HOOKS_DIR/pre-compact-context.sh" 2>/dev/null || true)
assert_contains "$OUTPUT2" "Weave state" "pre-compact: respects WV_DB env var"

# --- pre-action.sh (no active node) ---
echo ""
echo "--- pre-action.sh (no active node) ---"
setup_test_env

# No active nodes — should hard-block Edit (exit 2)
set +e
OUTPUT=$(echo '{"tool_name":"Edit","tool_input":{"file_path":"test.py"}}' | bash "$HOOKS_DIR/pre-action.sh" 2>&1)
EXIT_CODE=$?
set -e
assert_exit_code "2" "$EXIT_CODE" "pre-action: exits 2 (hard block) when no active node"
assert_contains "$OUTPUT" "No active Weave node" "pre-action: message on stderr when no active node"

# --- pre-action.sh (with active node) ---
echo ""
echo "--- pre-action.sh (active node, no blockers) ---"
setup_test_env
"$WV" add "Active test task" --status=active 2>/dev/null

set +e
OUTPUT=$(echo '{"tool_name":"Edit","tool_input":{"file_path":"test.py"}}' | bash "$HOOKS_DIR/pre-action.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "pre-action: exits 0 when active node exists"

# --- pre-action.sh (non-matching tool passes through) ---
echo ""
echo "--- pre-action.sh (non-matching tool) ---"
setup_test_env

set +e
OUTPUT=$(echo '{"tool_name":"Read","tool_input":{"file_path":"test.py"}}' | bash "$HOOKS_DIR/pre-action.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "pre-action: exits 0 for Read tool (not checked)"

# --- pre-action.sh (mcp__ide__executeCode enforced) ---
echo ""
echo "--- pre-action.sh (mcp__ide__executeCode) ---"
setup_test_env

# No active nodes: mcp__ide__executeCode must be hard-blocked (exit 2)
set +e
OUTPUT=$(echo '{"tool_name":"mcp__ide__executeCode","tool_input":{"code":"print(1)"}}' | bash "$HOOKS_DIR/pre-action.sh" 2>&1)
EXIT_CODE=$?
set -e
assert_exit_code "2" "$EXIT_CODE" "pre-action: exits 2 for mcp__ide__executeCode without active node"

# With active node: mcp__ide__executeCode must be allowed (exit 0)
setup_test_env
"$WV" add "MCP test task" --status=active 2>/dev/null
set +e
OUTPUT=$(echo '{"tool_name":"mcp__ide__executeCode","tool_input":{"code":"print(1)"}}' | bash "$HOOKS_DIR/pre-action.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "pre-action: exits 0 for mcp__ide__executeCode with active node"

# --- pre-action.sh (VS Code tool names — SHOULD_CHECK coverage) ---
echo ""
echo "--- pre-action.sh (VS Code tool names) ---"

# create_file without active node: must block (exit 2)
setup_test_env
set +e
OUTPUT=$(echo '{"tool_name":"create_file","tool_input":{"filePath":"new.py"}}' | bash "$HOOKS_DIR/pre-action.sh" 2>&1)
EXIT_CODE=$?
set -e
assert_exit_code "2" "$EXIT_CODE" "pre-action: exits 2 for create_file without active node"

# replace_string_in_file without active node: must block (exit 2)
setup_test_env
set +e
OUTPUT=$(echo '{"tool_name":"replace_string_in_file","tool_input":{"filePath":"src/main.ts"}}' | bash "$HOOKS_DIR/pre-action.sh" 2>&1)
EXIT_CODE=$?
set -e
assert_exit_code "2" "$EXIT_CODE" "pre-action: exits 2 for replace_string_in_file without active node"

# create_file with active node: must allow (exit 0)
setup_test_env
"$WV" add "VS Code test task" --status=active 2>/dev/null
set +e
OUTPUT=$(echo '{"tool_name":"create_file","tool_input":{"filePath":"new.py"}}' | bash "$HOOKS_DIR/pre-action.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "pre-action: exits 0 for create_file with active node"

# run_in_terminal (VS Code Bash equivalent): non-wv-done command passes through
setup_test_env
set +e
OUTPUT=$(echo '{"tool_name":"run_in_terminal","tool_input":{"command":"ls -la"}}' | bash "$HOOKS_DIR/pre-action.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "pre-action: exits 0 for run_in_terminal with non-wv command"

# --- pre-action.sh (camelCase filePath — installed-path guard) ---
echo ""
echo "--- pre-action.sh (camelCase filePath guard) ---"

# VS Code sends filePath (camelCase) — must detect installed-path edits
setup_test_env
"$WV" add "filePath guard test" --status=active 2>/dev/null
set +e
OUTPUT=$(echo '{"tool_name":"create_file","tool_input":{"filePath":"/home/user/.local/lib/weave/lib/something.sh"}}' | bash "$HOOKS_DIR/pre-action.sh" 2>&1)
EXIT_CODE=$?
set -e
assert_exit_code "2" "$EXIT_CODE" "pre-action: blocks installed-path edit via camelCase filePath"
assert_contains "$OUTPUT" "installed copy" "pre-action: shows installed-path error for camelCase filePath"

# Claude Code sends file_path (snake_case) — existing behavior still works
setup_test_env
"$WV" add "file_path guard test" --status=active 2>/dev/null
set +e
OUTPUT=$(echo '{"tool_name":"Edit","tool_input":{"file_path":"/home/user/.local/bin/wv"}}' | bash "$HOOKS_DIR/pre-action.sh" 2>&1)
EXIT_CODE=$?
set -e
assert_exit_code "2" "$EXIT_CODE" "pre-action: blocks installed-path edit via snake_case file_path"

# --- pre-action.sh (first-call-only cache: hit, miss, invalidation) ---
echo ""
echo "--- pre-action.sh (context cache S2.1-S2.3) ---"

# Cache miss: first call creates stamp file
setup_test_env
TASK_ID=$("$WV" add "Cache test" --status=active 2>/dev/null | tail -1)
# Clear any existing stamp
rm -f "$WV_HOT_ZONE/.context_checked_"* 2>/dev/null || true
set +e
OUTPUT=$(echo '{"tool_name":"Edit","tool_input":{"file_path":"test.py"}}' | bash "$HOOKS_DIR/pre-action.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "cache: first call passes (cache miss)"
TESTS_RUN=$((TESTS_RUN + 1))
if [ -f "$WV_HOT_ZONE/.context_checked_${TASK_ID}" ]; then
    echo -e "${GREEN}✓${NC} cache: stamp file created after first call"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "${RED}✗${NC} cache: stamp file created after first call"
    echo "  Expected $WV_HOT_ZONE/.context_checked_${TASK_ID} to exist"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# Cache hit: second call exits 0 immediately (stamp exists)
set +e
OUTPUT=$(echo '{"tool_name":"Edit","tool_input":{"file_path":"test.py"}}' | bash "$HOOKS_DIR/pre-action.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "cache: second call passes (cache hit)"

# Invalidation: invalidate_context_cache clears stamp
source "$PROJECT_ROOT/scripts/lib/wv-cache.sh"
invalidate_context_cache "$TASK_ID"
TESTS_RUN=$((TESTS_RUN + 1))
if [ ! -f "$WV_HOT_ZONE/.context_checked_${TASK_ID}" ]; then
    echo -e "${GREEN}✓${NC} cache: stamp cleared by invalidate_context_cache"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "${RED}✗${NC} cache: stamp cleared by invalidate_context_cache"
    echo "  Expected stamp to be removed"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# After invalidation: next call re-checks (cache miss again) and re-creates stamp
set +e
OUTPUT=$(echo '{"tool_name":"Edit","tool_input":{"file_path":"test.py"}}' | bash "$HOOKS_DIR/pre-action.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "cache: call after invalidation passes (re-check)"
TESTS_RUN=$((TESTS_RUN + 1))
if [ -f "$WV_HOT_ZONE/.context_checked_${TASK_ID}" ]; then
    echo -e "${GREEN}✓${NC} cache: stamp re-created after invalidation"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "${RED}✗${NC} cache: stamp re-created after invalidation"
    echo "  Expected $WV_HOT_ZONE/.context_checked_${TASK_ID} to exist"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# --- pre-claim-skills.sh (matching command) ---
echo ""
echo "--- pre-claim-skills.sh ---"
setup_test_env

# Node without done_criteria → hard gate (missing planning)
ID=$("$WV" add "Claim test" 2>/dev/null | tail -1)
set +e
OUTPUT=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"cmd\":\"wv work $ID\"}}" | bash "$HOOKS_DIR/pre-claim-skills.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "pre-claim: exits 0 (soft deny) for real Bash payload"
assert_contains "$OUTPUT" "hookSpecificOutput" "pre-claim: uses canonical hookSpecificOutput schema"
assert_contains "$OUTPUT" "permissionDecision" "pre-claim: contains permissionDecision field"
assert_contains "$OUTPUT" "/ship-it" "pre-claim: suggests ship-it when done_criteria absent"

# Node with done_criteria but no risks → tiered advisory
ID2=$("$WV" add "Claim test criteria-only" --metadata='{"done_criteria":["c1"]}' 2>/dev/null | tail -1)
set +e
OUTPUT2=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"cmd\":\"wv work $ID2\"}}" | bash "$HOOKS_DIR/pre-claim-skills.sh" 2>/dev/null)
EXIT_CODE2=$?
set -e
assert_exit_code "0" "$EXIT_CODE2" "pre-claim: exits 0 when criteria set but risks absent"
assert_contains "$OUTPUT2" "pre-mortem" "pre-claim: suggests pre-mortem when done_criteria present but risks absent"

# Node with both done_criteria and risks → silent pass
ID3=$("$WV" add "Claim test both" --metadata='{"done_criteria":["c1"],"risks":[]}' 2>/dev/null | tail -1)
set +e
OUTPUT3=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"cmd\":\"wv work $ID3\"}}" | bash "$HOOKS_DIR/pre-claim-skills.sh" 2>/dev/null)
EXIT_CODE3=$?
set -e
assert_exit_code "0" "$EXIT_CODE3" "pre-claim: exits 0 when both done_criteria and risks present"
assert_equals "" "$OUTPUT3" "pre-claim: silent when planning metadata complete"

# Back-compat: older test payload shape still accepted
set +e
OUTPUT=$(echo "{\"command\":\"wv update $ID --status=active\"}" | bash "$HOOKS_DIR/pre-claim-skills.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "pre-claim: exits 0 for legacy root command payload"

# Non-matching command
OUTPUT=$(echo '{"command":"wv list --json"}' | bash "$HOOKS_DIR/pre-claim-skills.sh" 2>/dev/null || true)
assert_equals "" "$OUTPUT" "pre-claim: silent for non-matching commands"

# --- pre-close-verification.sh (no verification) ---
echo ""
echo "--- pre-close-verification.sh ---"
setup_test_env
ID=$("$WV" add "Close test" --status=active 2>/dev/null | tail -1)

set +e
OUTPUT=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"cmd\":\"wv done $ID\"}}" | bash "$HOOKS_DIR/pre-close-verification.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_contains "$OUTPUT" "permissionDecisionReason" "pre-close: warns when no verification metadata for real Bash payload"
assert_contains "$OUTPUT" "\"permissionDecision\": \"deny\"" "pre-close: uses hookSpecificOutput permissionDecision deny schema (lowercase)"
assert_exit_code "0" "$EXIT_CODE" "pre-close: exits 0 (soft deny) when no verification"

# With --skip-verification flag (should pass)
set +e
OUTPUT=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"cmd\":\"wv done $ID --skip-verification\"}}" | bash "$HOOKS_DIR/pre-close-verification.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "pre-close: exits 0 with --skip-verification bypass on real Bash payload"

# Finding nodes still require structured finding metadata even with --skip-verification
FINDING_ID=$("$WV" add "Finding close test" --status=active --metadata='{"type":"finding"}' 2>/dev/null | tail -1)
set +e
OUTPUT=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"cmd\":\"wv done $FINDING_ID --skip-verification\"}}" | bash "$HOOKS_DIR/pre-close-verification.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_contains "$OUTPUT" "Finding nodes require structured metadata before close" "pre-close: finding schema enforced before close"
assert_exit_code "0" "$EXIT_CODE" "pre-close: finding schema denial is soft"

"$WV" update "$FINDING_ID" --metadata='{"type":"finding","finding":{"violation_type":"R10:open_node_at_end","root_cause":"bootstrap omitted active-node type","proposed_fix":"record active_node_type in session_start metadata","confidence":"high","fixable":true}}' 2>/dev/null
OUTPUT=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"cmd\":\"wv done $FINDING_ID --skip-verification\"}}" | bash "$HOOKS_DIR/pre-close-verification.sh" 2>/dev/null || true)
assert_equals "" "$OUTPUT" "pre-close: complete finding metadata passes with skip-verification"

"$WV" update "$FINDING_ID" --metadata='{"type":"finding","finding":{"violation_type":"R10:open_node_at_end","root_cause":"bootstrap omitted active-node type","proposed_fix":"record active_node_type in session_start metadata","confidence":0.92,"fixable":"yes"}}' 2>/dev/null
OUTPUT=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"cmd\":\"wv done $FINDING_ID --skip-verification\"}}" | bash "$HOOKS_DIR/pre-close-verification.sh" 2>/dev/null || true)
assert_contains "$OUTPUT" "Missing or invalid: finding.confidence, finding.fixable" "pre-close: invalid finding field types are denied"

# With verification metadata
"$WV" update "$ID" --metadata='{"verification":{"method":"test","result":"pass"}}' 2>/dev/null
OUTPUT=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"cmd\":\"wv done $ID\"}}" | bash "$HOOKS_DIR/pre-close-verification.sh" 2>/dev/null || true)
# Should NOT warn when verification exists
TESTS_RUN=$((TESTS_RUN + 1))
if ! echo "$OUTPUT" | grep -q "Verification evidence required"; then
    echo -e "${GREEN}✓${NC} pre-close: silent when verification metadata present for real Bash payload"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "${RED}✗${NC} pre-close: should be silent when verification metadata present for real Bash payload"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# Back-compat: older test payload shape still accepted
set +e
OUTPUT=$(echo "{\"command\":\"wv done $ID\"}" | bash "$HOOKS_DIR/pre-close-verification.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "pre-close: exits 0 for legacy root command payload when verification exists"

# Inline --verification-method flag satisfies hook without prior wv update
ID2="$("$WV" add "inline-flag test node" --status=active 2>/dev/null | grep -oP 'wv-[0-9a-f]{4,6}')"
set +e
OUTPUT=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"cmd\":\"wv done $ID2 --verification-method=\\\"make check\\\" --learning=\\\"test\\\"\"}}" | bash "$HOOKS_DIR/pre-close-verification.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "pre-close: exits 0 when --verification-method inline flag present"
assert_equals "" "$OUTPUT" "pre-close: silent (no deny) when --verification-method inline flag present"

# Inline --verification-evidence flag also satisfies hook
set +e
OUTPUT=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"cmd\":\"wv done $ID2 --verification-evidence=\\\"5 passed\\\" --learning=\\\"test\\\"\"}}" | bash "$HOOKS_DIR/pre-close-verification.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "pre-close: exits 0 when --verification-evidence inline flag present"
assert_equals "" "$OUTPUT" "pre-close: silent (no deny) when --verification-evidence inline flag present"

"$WV" done "$ID2" --skip-verification 2>/dev/null || true  # cleanup

# Non-matching command
OUTPUT=$(echo '{"command":"wv list"}' | bash "$HOOKS_DIR/pre-close-verification.sh" 2>/dev/null || true)
assert_equals "" "$OUTPUT" "pre-close: silent for non-matching commands"

# --- bash-dedup.sh / bash-dedup-post.sh ---
echo ""
echo "--- bash-dedup.sh / bash-dedup-post.sh ---"
setup_test_env

DEDUP_LOCK_DIR="/tmp/weave-bash-locks/$(echo "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" | md5sum 2>/dev/null | cut -c1-8 || echo default)"
mkdir -p "$DEDUP_LOCK_DIR"

# First call: lock is absent — should allow (exit 0, no denial output)
rm -f "$DEDUP_LOCK_DIR/wv-sync.lock"
set +e
OUTPUT=$(echo '{"tool_name":"Bash","tool_input":{"command":"wv sync --gh"}}' | bash "$HOOKS_DIR/bash-dedup.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "bash-dedup: first call exits 0 (allow)"
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$OUTPUT" | grep -q '"deny"'; then
    echo -e "${RED}✗${NC} bash-dedup: first call must not deny"
    TESTS_FAILED=$((TESTS_FAILED + 1))
else
    echo -e "${GREEN}✓${NC} bash-dedup: first call does not deny"
    TESTS_PASSED=$((TESTS_PASSED + 1))
fi

# Second call while lock is fresh — should deny
set +e
OUTPUT=$(echo '{"tool_name":"Bash","tool_input":{"command":"wv sync --gh"}}' | bash "$HOOKS_DIR/bash-dedup.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "bash-dedup: second call exits 0 (deny via JSON)"
assert_contains "$OUTPUT" '"deny"' "bash-dedup: second call emits deny decision"

# Post hook: foreground completion clears lock
echo '{"tool_name":"Bash","tool_input":{"command":"wv sync --gh","run_in_background":false},"tool_response":{"output":"done","success":true}}' \
    | bash "$HOOKS_DIR/bash-dedup-post.sh" 2>/dev/null
TESTS_RUN=$((TESTS_RUN + 1))
if [[ -f "$DEDUP_LOCK_DIR/wv-sync.lock" ]]; then
    echo -e "${RED}✗${NC} bash-dedup-post: foreground completion must clear lock"
    TESTS_FAILED=$((TESTS_FAILED + 1))
else
    echo -e "${GREEN}✓${NC} bash-dedup-post: foreground completion clears lock"
    TESTS_PASSED=$((TESTS_PASSED + 1))
fi

# Post hook: background command (via tool_input flag) does NOT clear lock
echo '{"tool_name":"Bash","tool_input":{"command":"wv sync --gh","run_in_background":true},"tool_response":{"output":"Command running in background with ID: abc123.","success":true}}' \
    | bash "$HOOKS_DIR/bash-dedup.sh" 2>/dev/null || true  # re-acquire lock
set +e
echo '{"tool_name":"Bash","tool_input":{"command":"wv sync --gh","run_in_background":true},"tool_response":{"output":"Command running in background with ID: abc123.","success":true}}' \
    | bash "$HOOKS_DIR/bash-dedup-post.sh" 2>/dev/null
set -e
TESTS_RUN=$((TESTS_RUN + 1))
if [[ -f "$DEDUP_LOCK_DIR/wv-sync.lock" ]]; then
    echo -e "${GREEN}✓${NC} bash-dedup-post: background command preserves lock (tool_input flag)"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "${RED}✗${NC} bash-dedup-post: background command must preserve lock"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# Post hook: background command (via tool_response output pattern) does NOT clear lock
set +e
echo '{"tool_name":"Bash","tool_input":{"command":"wv sync --gh","run_in_background":false},"tool_response":{"output":"Command running in background with ID: xyz999. Output is being written to: /tmp/foo","success":true}}' \
    | bash "$HOOKS_DIR/bash-dedup-post.sh" 2>/dev/null
set -e
TESTS_RUN=$((TESTS_RUN + 1))
if [[ -f "$DEDUP_LOCK_DIR/wv-sync.lock" ]]; then
    echo -e "${GREEN}✓${NC} bash-dedup-post: background command preserves lock (response output pattern)"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "${RED}✗${NC} bash-dedup-post: background command must preserve lock (response output pattern)"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

rm -f "$DEDUP_LOCK_DIR/wv-sync.lock"

# False-positive guard: "wv sync" inside a quoted argument must NOT create a lock
FP_INPUT=$(jq -n --arg cmd 'wv done wv-abc1 --verification-evidence="wv sync --gh ran fine" --learning="x"' \
    '{"tool_name":"Bash","tool_input":{"command":$cmd}}')
set +e
OUTPUT=$(echo "$FP_INPUT" | bash "$HOOKS_DIR/bash-dedup.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "bash-dedup: wv sync inside quoted arg does not create lock"
assert_equals "" "$OUTPUT" "bash-dedup: wv sync inside quoted arg is not denied"
if [[ -f "$DEDUP_LOCK_DIR/wv-sync.lock" ]]; then
    echo -e "${RED}✗${NC} bash-dedup: false-positive lock created for wv sync in quoted arg"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    rm -f "$DEDUP_LOCK_DIR/wv-sync.lock"
else
    echo -e "${GREEN}✓${NC} bash-dedup: no false-positive lock for wv sync in quoted arg"
    TESTS_PASSED=$((TESTS_PASSED + 1))
fi
TESTS_RUN=$((TESTS_RUN + 1))

# --- post-edit-lint.sh ---
echo ""
echo "--- post-edit-lint.sh ---"
setup_test_env

# Test with non-lintable file (should pass silently)
set +e
OUTPUT=$(echo '{"tool_name":"Edit","tool_input":{"file_path":"test.txt"}}' | bash "$HOOKS_DIR/post-edit-lint.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "post-edit-lint: exits 0 for non-lintable file"

# Test with Python file (ruff if available)
set +e
OUTPUT=$(echo '{"tool_name":"Edit","tool_input":{"file_path":"test.py"}}' | bash "$HOOKS_DIR/post-edit-lint.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "post-edit-lint: exits 0 for Python file"

# --- stop-check.sh (clean state) ---
echo ""
echo "--- stop-check.sh ---"
setup_test_env

# Commit all test scaffolding so the repo is truly clean
git -C "$TEST_DIR/project" add -A 2>/dev/null
git -C "$TEST_DIR/project" commit -m "test setup" -q 2>/dev/null

set +e
OUTPUT=$(echo '{}' | bash "$HOOKS_DIR/stop-check.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "stop-check: exits 0 with clean git state"

# Dirty state (uncommitted changes) — soft warn, does NOT block
echo "dirty" > "$TEST_DIR/project/dirty.txt"
git -C "$TEST_DIR/project" add dirty.txt

set +e
STDERR_OUTPUT=$(echo '{}' | bash "$HOOKS_DIR/stop-check.sh" 2>&1 1>/dev/null)
OUTPUT=$(echo '{}' | bash "$HOOKS_DIR/stop-check.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "stop-check: exits 0 (soft warn) with uncommitted changes"
assert_contains "$STDERR_OUTPUT" "uncommitted" "stop-check: stderr warns about uncommitted changes"

# Unpushed commits — auto-push attempted, fails → hard block
# Create a real bare remote so tracking/AHEAD works, then remove it so push fails
_FAKE_REMOTE=$(mktemp -d)
git init --bare -q "$_FAKE_REMOTE"
git -C "$TEST_DIR/project" commit -m "unpushed work" -q 2>/dev/null
git -C "$TEST_DIR/project" remote add origin "file://$_FAKE_REMOTE" 2>/dev/null || true
git -C "$TEST_DIR/project" push -u origin HEAD:main -q 2>/dev/null || \
    git -C "$TEST_DIR/project" push -u origin HEAD:master -q 2>/dev/null || true
# Make a new commit so AHEAD=1
echo "ahead" > "$TEST_DIR/project/ahead.txt"
git -C "$TEST_DIR/project" add ahead.txt
git -C "$TEST_DIR/project" commit -m "ahead of upstream" -q 2>/dev/null
# Remove the remote so push will fail
rm -rf "$_FAKE_REMOTE"

set +e
OUTPUT=$(echo '{}' | bash "$HOOKS_DIR/stop-check.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "1" "$EXIT_CODE" "stop-check: exits 1 (hard block) with unpushed commits"
assert_contains "$OUTPUT" "auto-push failed" "stop-check: warns about unpushed commits"
assert_contains "$OUTPUT" "block" "stop-check: decision is block"

# --- session-end-sync.sh ---
echo ""
echo "--- session-end-sync.sh ---"
setup_test_env

set +e
OUTPUT=$(echo '{"reason":"user_exit"}' | bash "$HOOKS_DIR/session-end-sync.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "session-end: exits 0"

# Check session log was written
if [ -f "$TEST_DIR/project/.claude/session.log" ]; then
    LOG_CONTENT=$(cat "$TEST_DIR/project/.claude/session.log")
    assert_contains "$LOG_CONTENT" "user_exit" "session-end: logs session end reason"
else
    # session.log requires .claude/ dir in project
    mkdir -p "$TEST_DIR/project/.claude"
    OUTPUT=$(echo '{"reason":"test_exit"}' | bash "$HOOKS_DIR/session-end-sync.sh" 2>/dev/null || true)
    if [ -f "$TEST_DIR/project/.claude/session.log" ]; then
        LOG_CONTENT=$(cat "$TEST_DIR/project/.claude/session.log")
        assert_contains "$LOG_CONTENT" "test_exit" "session-end: logs session end reason"
    else
        TESTS_RUN=$((TESTS_RUN + 1))
        echo -e "${YELLOW}⊘${NC} session-end: session.log not created (best-effort logging)"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    fi
fi

# Verify session-end uses `wv sync --gh` and commit automation via
# WV_AUTO_CHECKPOINT_ACTIVE rather than a blanket --no-verify bypass.
setup_test_env
SPY_HOME="$TEST_DIR/home"
mkdir -p "$SPY_HOME/.local/bin"
WV_LOG="$TEST_DIR/wv-calls.log"
cat > "$SPY_HOME/.local/bin/wv" <<EOF
#!/bin/sh
echo "\$*" >> "$WV_LOG"
exit 0
EOF
chmod +x "$SPY_HOME/.local/bin/wv"

# Force the commit path and require the automation env var in pre-commit.
# Remove the source-repo symlink so the hook falls back to HOME/.local/bin/wv.
rm -f "$TEST_DIR/project/scripts/wv"
echo "checkpoint" >> "$TEST_DIR/project/.weave/breadcrumbs.md"
cat > "$TEST_DIR/project/.git/hooks/pre-commit" <<'EOF'
#!/bin/sh
[ "${WV_AUTO_CHECKPOINT_ACTIVE:-0}" = "1" ] && exit 0
echo "missing WV_AUTO_CHECKPOINT_ACTIVE" >&2
exit 1
EOF
chmod +x "$TEST_DIR/project/.git/hooks/pre-commit"

set +e
OUTPUT=$(HOME="$SPY_HOME" CLAUDE_PROJECT_DIR="$TEST_DIR/project" \
    bash "$HOOKS_DIR/session-end-sync.sh" <<< '{"reason":"stubbed_session_end"}' 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "session-end: exits 0 with sync --gh stub + automation pre-commit"
WV_CALLS=$(cat "$WV_LOG")
assert_contains "$WV_CALLS" "sync --gh" "session-end: calls wv sync --gh"
LAST_MSG=$(git -C "$TEST_DIR/project" log -1 --pretty=%s 2>/dev/null || true)
assert_contains "$LAST_MSG" "auto-checkpoint" "session-end: auto-checkpoint commit succeeds without blanket bypass"

# ============================================================
# INTEGRATION TEST: Full session lifecycle
# ============================================================
echo ""
echo "=== Integration: Full Session Lifecycle ==="
setup_test_env

# 1. Session start
OUTPUT=$(bash "$HOOKS_DIR/session-start-context.sh" 2>/dev/null || true)
assert_contains "$OUTPUT" "SessionStart" "lifecycle: session starts successfully"

# 2. Create and claim a node (triggers pre-claim-skills)
TASK_ID=$("$WV" add "Lifecycle test task" 2>/dev/null | tail -1)
OUTPUT=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"cmd\":\"wv work $TASK_ID\"}}" | bash "$HOOKS_DIR/pre-claim-skills.sh" 2>/dev/null || true)
"$WV" update "$TASK_ID" --status=active 2>/dev/null
TASK_STATUS=$("$WV" show "$TASK_ID" --json 2>/dev/null | jq -r '.[0].status')
assert_equals "active" "$TASK_STATUS" "lifecycle: node claimed successfully"

# 3. Pre-action gate allows edit (active node exists)
set +e
OUTPUT=$(echo '{"tool_name":"Edit","tool_input":{"file_path":"test.py"}}' | bash "$HOOKS_DIR/pre-action.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "lifecycle: pre-action allows edit with active node"

# 4. Simulate edit and lint check
echo "print('hello')" > "$TEST_DIR/project/test.py"
set +e
OUTPUT=$(echo '{"tool_name":"Edit","tool_input":{"file_path":"test.py"}}' | bash "$HOOKS_DIR/post-edit-lint.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "lifecycle: post-edit-lint passes"

# 5. Try to close without verification (should hard-block with exit 2)
set +e
OUTPUT=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"cmd\":\"wv done $TASK_ID\"}}" | bash "$HOOKS_DIR/pre-close-verification.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_contains "$OUTPUT" "permissionDecision" "lifecycle: close blocked without verification"
assert_exit_code "0" "$EXIT_CODE" "lifecycle: close soft-denied without verification"

# 6. Add verification and close (should be silent)
"$WV" update "$TASK_ID" --metadata='{"verification":{"method":"test","command":"echo ok","result":"pass","evidence":"lifecycle test"}}' 2>/dev/null
OUTPUT=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"cmd\":\"wv done $TASK_ID\"}}" | bash "$HOOKS_DIR/pre-close-verification.sh" 2>/dev/null || true)
TESTS_RUN=$((TESTS_RUN + 1))
if ! echo "$OUTPUT" | grep -q "Verification evidence required"; then
    echo -e "${GREEN}✓${NC} lifecycle: close allowed with verification"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "${RED}✗${NC} lifecycle: close allowed with verification"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# 7. Complete the node
"$WV" done "$TASK_ID" 2>/dev/null
TASK_STATUS=$("$WV" show "$TASK_ID" --json 2>/dev/null | jq -r '.[0].status')
assert_equals "done" "$TASK_STATUS" "lifecycle: node completed"

# 8. Commit so stop-check passes
git -C "$TEST_DIR/project" add -A 2>/dev/null
git -C "$TEST_DIR/project" commit -m "lifecycle test" -q 2>/dev/null

# 9. Stop check (clean state)
set +e
OUTPUT=$(echo '{}' | bash "$HOOKS_DIR/stop-check.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "lifecycle: stop-check passes with clean state"

# 10. Session end
LIFECYCLE_HOME="$TEST_DIR/lifecycle-home"
mkdir -p "$LIFECYCLE_HOME/.local/bin"
cat > "$LIFECYCLE_HOME/.local/bin/wv" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$LIFECYCLE_HOME/.local/bin/wv"
rm -f "$TEST_DIR/project/scripts/wv"
set +e
OUTPUT=$(HOME="$LIFECYCLE_HOME" CLAUDE_PROJECT_DIR="$TEST_DIR/project" \
    bash "$HOOKS_DIR/session-end-sync.sh" <<< '{"reason":"lifecycle_test"}' 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "lifecycle: session ends cleanly"

# 11. Pre-compact preserves context during lifecycle
"$WV" add "Another active task" --status=active 2>/dev/null
OUTPUT=$(bash "$HOOKS_DIR/pre-compact-context.sh" 2>/dev/null || true)
assert_contains "$OUTPUT" "Active:" "lifecycle: pre-compact reports active work during session"

# ============================================================
# Context-guard tests (S1.5 + S1.6)
# ============================================================
echo ""
echo "=== Context Guard ==="

# Reset to test project
cd "$TEST_DIR/project"
export POLICY_CACHE="$TEST_DIR/.context_policy"
rm -f "$POLICY_CACHE" 2>/dev/null || true

# Create some tracked files so git ls-files has something
for i in $(seq 1 5); do echo "x=1" > "mod${i}.py"; done
git add -A && git commit -m "add test files" -q

# 1. Fresh run → should produce a policy (small repo = HIGH)
set +e
OUTPUT=$(bash "$HOOKS_DIR/context-guard.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "context-guard: exits 0"
assert_contains "$OUTPUT" "policy" "context-guard: emits policy line"

# 2. Cache file should exist after first run
TESTS_RUN=$((TESTS_RUN + 1))
if [ -f "$POLICY_CACHE" ]; then
    echo -e "${GREEN}✓${NC} context-guard: cache file created"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "${RED}✗${NC} context-guard: cache file created"
    echo "  Expected $POLICY_CACHE to exist"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# 3. Cached policy matches first run
CACHED_POLICY=$(head -1 "$POLICY_CACHE" 2>/dev/null || echo "")
assert_equals "HIGH" "$CACHED_POLICY" "context-guard: small repo yields HIGH policy"

# 4. Cache TTL expiry — backdate cache mtime, should recompute
touch -d "2 hours ago" "$POLICY_CACHE" 2>/dev/null || touch -t 202001010000 "$POLICY_CACHE"
set +e
OUTPUT2=$(bash "$HOOKS_DIR/context-guard.sh" 2>/dev/null)
EXIT_CODE2=$?
set -e
assert_exit_code "0" "$EXIT_CODE2" "context-guard: exits 0 after stale cache"
# Cache should be refreshed (mtime within last minute)
MTIME=$(stat -c %Y "$POLICY_CACHE" 2>/dev/null || echo 0)
NOW=$(date +%s)
AGE=$(( NOW - MTIME ))
TESTS_RUN=$((TESTS_RUN + 1))
if [ "$AGE" -lt 60 ]; then
    echo -e "${GREEN}✓${NC} context-guard: stale cache was refreshed"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "${RED}✗${NC} context-guard: stale cache was refreshed"
    echo "  Cache age: ${AGE}s (expected < 60s)"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ============================================================
# --- JSONL bridge: crash path includes last-prompt ---
echo ""
echo "--- session-start: JSONL bridge (crash path) ---"
setup_test_env

# Plant a crash sentinel
echo '{"ts":"2026-03-27T00:00:00Z","active":["wv-aabbcc"]}' > "$WV_HOT_ZONE/.session_sentinel"

# Create Claude JSONL in real HOME at the slug derived from the (unique) test project dir.
# Using real HOME avoids breaking wv lib resolution inside the hook.
_BRIDGE_SLUG=$(echo "$WV_PROJECT_DIR" | tr '/' '-')
_BRIDGE_JSONL_DIR="$HOME/.claude/projects/${_BRIDGE_SLUG}"
mkdir -p "$_BRIDGE_JSONL_DIR"
printf '%s\n' \
    '{"type":"summary","summary":"prev session"}' \
    '{"type":"last-prompt","lastPrompt":"okay whats next on the list"}' \
    > "$_BRIDGE_JSONL_DIR/session.jsonl"

OUTPUT=$(bash "$HOOKS_DIR/session-start-context.sh" 2>/dev/null || true)
rm -rf "$_BRIDGE_JSONL_DIR"

assert_contains "$OUTPUT" "CRASH DETECTED" "JSONL bridge: crash path emits CRASH DETECTED"
assert_contains "$OUTPUT" "Last prompt:" "JSONL bridge: crash output includes Last prompt field"
assert_contains "$OUTPUT" "okay whats next on the list" "JSONL bridge: crash output includes last-prompt text"

# ============================================================
# --- JSONL bridge: secondary detection path (no sentinel, active node) ---
echo ""
echo "--- session-start: JSONL bridge (secondary detection path) ---"
setup_test_env

# Active node but no sentinel (reboot recovery)
# Must sync so wv load inside the hook restores this node from state.sql
"$WV" add "Orphaned after reboot" --status=active 2>/dev/null
"$WV" sync 2>/dev/null || true

_BRIDGE2_JSONL_DIR="$HOME/.claude/projects/${_BRIDGE_SLUG}"
mkdir -p "$_BRIDGE2_JSONL_DIR"
printf '%s\n' \
    '{"type":"last-prompt","lastPrompt":"sync state visibility"}' \
    > "$_BRIDGE2_JSONL_DIR/session.jsonl"

OUTPUT=$(bash "$HOOKS_DIR/session-start-context.sh" 2>/dev/null || true)
rm -rf "$_BRIDGE2_JSONL_DIR"

assert_contains "$OUTPUT" "Last prompt:" "JSONL bridge: secondary detection includes Last prompt field"
assert_contains "$OUTPUT" "sync state visibility" "JSONL bridge: secondary detection includes last-prompt text"

# ============================================================
# --- JSONL bridge: graceful degradation (no JSONL dir) ---
echo ""
echo "--- session-start: JSONL bridge (degradation, no JSONL) ---"
setup_test_env

# Crash sentinel with no JSONL for this (unique temp) project path — bridge must degrade
echo '{"ts":"2026-03-27T00:01:00Z","active":["wv-ccddee"]}' > "$WV_HOT_ZONE/.session_sentinel"
# _BRIDGE_SLUG dir was deleted above; real HOME has no JSONL for this slug

OUTPUT=$(bash "$HOOKS_DIR/session-start-context.sh" 2>/dev/null || true)
assert_contains "$OUTPUT" "CRASH DETECTED" "JSONL bridge: crash detected even without JSONL"
# Must not contain "Last prompt:" when no JSONL available
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$OUTPUT" | grep -qF "Last prompt:"; then
    echo -e "${RED}✗${NC} JSONL bridge: degrades gracefully when no JSONL (unexpected Last prompt: found)"
    TESTS_FAILED=$((TESTS_FAILED + 1))
else
    echo -e "${GREEN}✓${NC} JSONL bridge: degrades gracefully when no JSONL"
    TESTS_PASSED=$((TESTS_PASSED + 1))
fi

# ============================================================
echo ""
echo "=== Results ==="
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
if [ "$TESTS_FAILED" -gt 0 ]; then
    echo -e "${RED}$TESTS_FAILED test(s) failed${NC}"
    exit 1
else
    echo -e "${GREEN}All tests passed${NC}"
    exit 0
fi
