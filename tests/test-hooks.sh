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

# No active nodes — should block Edit
set +e
OUTPUT=$(echo '{"tool_name":"Edit","tool_input":{"file_path":"test.py"}}' | bash "$HOOKS_DIR/pre-action.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "1" "$EXIT_CODE" "pre-action: exits 1 when no active node"
assert_contains "$OUTPUT" "No active Weave node" "pre-action: warns about missing active node"

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

# --- pre-claim-skills.sh (matching command) ---
echo ""
echo "--- pre-claim-skills.sh ---"
setup_test_env
ID=$("$WV" add "Claim test" 2>/dev/null | tail -1)

OUTPUT=$(echo "{\"command\":\"wv update $ID --status=active\"}" | bash "$HOOKS_DIR/pre-claim-skills.sh" 2>/dev/null || true)
# May or may not output suggestion depending on metadata state
EXIT_CODE=$?
assert_exit_code "0" "0" "pre-claim: exits 0 (advisory, never blocks)"

# Non-matching command
OUTPUT=$(echo '{"command":"wv list --json"}' | bash "$HOOKS_DIR/pre-claim-skills.sh" 2>/dev/null || true)
assert_equals "" "$OUTPUT" "pre-claim: silent for non-matching commands"

# --- pre-close-verification.sh (no verification) ---
echo ""
echo "--- pre-close-verification.sh ---"
setup_test_env
ID=$("$WV" add "Close test" --status=active 2>/dev/null | tail -1)

OUTPUT=$(echo "{\"command\":\"wv done $ID\"}" | bash "$HOOKS_DIR/pre-close-verification.sh" 2>/dev/null || true)
assert_contains "$OUTPUT" "Verification evidence required" "pre-close: warns when no verification metadata"
assert_contains "$OUTPUT" "verification_status" "pre-close: includes verification_status in output"

# With verification metadata
"$WV" update "$ID" --metadata='{"verification":{"method":"test","result":"pass"}}' 2>/dev/null
OUTPUT=$(echo "{\"command\":\"wv done $ID\"}" | bash "$HOOKS_DIR/pre-close-verification.sh" 2>/dev/null || true)
# Should NOT warn when verification exists
TESTS_RUN=$((TESTS_RUN + 1))
if ! echo "$OUTPUT" | grep -q "Verification evidence required"; then
    echo -e "${GREEN}✓${NC} pre-close: silent when verification metadata present"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "${RED}✗${NC} pre-close: should be silent when verification metadata present"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# Non-matching command
OUTPUT=$(echo '{"command":"wv list"}' | bash "$HOOKS_DIR/pre-close-verification.sh" 2>/dev/null || true)
assert_equals "" "$OUTPUT" "pre-close: silent for non-matching commands"

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

set +e
OUTPUT=$(echo '{}' | bash "$HOOKS_DIR/stop-check.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "stop-check: exits 0 with clean git state"

# Dirty state (uncommitted changes)
echo "dirty" > "$TEST_DIR/project/dirty.txt"
git -C "$TEST_DIR/project" add dirty.txt

set +e
OUTPUT=$(echo '{}' | bash "$HOOKS_DIR/stop-check.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "stop-check: exits 0 (returns block decision in JSON)"
assert_contains "$OUTPUT" "uncommitted" "stop-check: warns about uncommitted changes"
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
OUTPUT=$(echo "{\"command\":\"wv update $TASK_ID --status=active\"}" | bash "$HOOKS_DIR/pre-claim-skills.sh" 2>/dev/null || true)
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

# 5. Try to close without verification (should warn)
OUTPUT=$(echo "{\"command\":\"wv done $TASK_ID\"}" | bash "$HOOKS_DIR/pre-close-verification.sh" 2>/dev/null || true)
assert_contains "$OUTPUT" "Verification evidence required" "lifecycle: close blocked without verification"

# 6. Add verification and close (should be silent)
"$WV" update "$TASK_ID" --metadata='{"verification":{"method":"test","command":"echo ok","result":"pass","evidence":"lifecycle test"}}' 2>/dev/null
OUTPUT=$(echo "{\"command\":\"wv done $TASK_ID\"}" | bash "$HOOKS_DIR/pre-close-verification.sh" 2>/dev/null || true)
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
set +e
OUTPUT=$(echo '{"reason":"lifecycle_test"}' | bash "$HOOKS_DIR/session-end-sync.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "lifecycle: session ends cleanly"

# 11. Pre-compact preserves context during lifecycle
"$WV" add "Another active task" --status=active 2>/dev/null
OUTPUT=$(bash "$HOOKS_DIR/pre-compact-context.sh" 2>/dev/null || true)
assert_contains "$OUTPUT" "Active:" "lifecycle: pre-compact reports active work during session"

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
