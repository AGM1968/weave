#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
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
# Hooks read their input with $(cat). A hook run here without a pipe must see
# EOF, not wait on whatever stdin launched the suite: from a background job it
# blocked session-start-context.sh until killed.
exec </dev/null
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Paths. Resolve once from an absolute script path, then leave any inherited cwd
# before setup removes a prior test directory that may currently contain the shell.
SCRIPT_SOURCE="${BASH_SOURCE[0]:-$0}"
case "$SCRIPT_SOURCE" in
    /*) ;;
    *) SCRIPT_SOURCE="$PWD/$SCRIPT_SOURCE" ;;
esac
SCRIPT_DIR="$(cd -P "$(dirname "$SCRIPT_SOURCE")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"
HOOKS_DIR="$PROJECT_ROOT/.claude/hooks"
WV="$PROJECT_ROOT/scripts/wv"
export WV_LIB_DIR="$PROJECT_ROOT/scripts"

# Test environment
TEST_DIR="/tmp/wv-hooks-test-$$"
export WV_HOT_ZONE="$TEST_DIR"
export WV_DB="$TEST_DIR/brain.db"
export WV_REQUIRE_LEARNING=0
# Session-local state is per owner (wv-43d6be): pin one owner, whatever
# session runs this suite, and resolve its hot-zone directory on demand.
export WV_AGENT_ID=test-hooks-agent
owner_dir() { local d="$WV_HOT_ZONE/owners/$WV_AGENT_ID"; mkdir -p "$d"; printf '%s' "$d"; }
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
    if grep -qF -- "$needle" <<<"$haystack"; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Expected to find: $needle"
        echo "  In: $(echo "$haystack" | sed -n '1,3p')"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if ! grep -qF -- "$needle" <<<"$haystack"; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Expected NOT to find: $needle"
        echo "  In: $(echo "$haystack" | sed -n '1,3p')"
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
    cd "$PROJECT_ROOT"
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR/project/.claude/hooks"
    mkdir -p "$TEST_DIR/project/.weave"
    mkdir -p "$TEST_DIR/project/scripts"

    # Create symlinks so hooks can find wv and lib
    ln -sf "$WV" "$TEST_DIR/project/scripts/wv"
    mkdir -p "$TEST_DIR/project/scripts/lib"
    ln -sf "$PROJECT_ROOT/scripts/lib/wv-resolve-project.sh" "$TEST_DIR/project/scripts/lib/wv-resolve-project.sh"
    ln -sf "$PROJECT_ROOT/scripts/lib/wv-resolve-runtime.sh" "$TEST_DIR/project/scripts/lib/wv-resolve-runtime.sh"

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

setup_uninitialized_project() {
    cd "$PROJECT_ROOT"
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR/project/.claude/hooks"
    mkdir -p "$TEST_DIR/project/scripts"

    # Create symlinks so hooks can find wv and lib
    ln -sf "$WV" "$TEST_DIR/project/scripts/wv"
    mkdir -p "$TEST_DIR/project/scripts/lib"
    ln -sf "$PROJECT_ROOT/scripts/lib/wv-resolve-project.sh" "$TEST_DIR/project/scripts/lib/wv-resolve-project.sh"
    ln -sf "$PROJECT_ROOT/scripts/lib/wv-resolve-runtime.sh" "$TEST_DIR/project/scripts/lib/wv-resolve-runtime.sh"

    cd "$TEST_DIR/project"
    git init -q
    git config commit.gpgsign false
    git config user.name "Hook Test"
    git config user.email "hook-test@example.com"
    git commit --allow-empty -m "init" -q

    export CLAUDE_PROJECT_DIR="$TEST_DIR/project"
    export WV_PROJECT_DIR="$TEST_DIR/project"
}

if [ "${1:-}" = "--cwd-smoke" ]; then
    # The second setup starts from the first disposable project; without the
    # known-good cd above it deletes its own inherited cwd and later hooks fail.
    setup_test_env
    setup_uninitialized_project
    [ "$PWD" = "$TEST_DIR/project" ]
    echo "deleted-cwd setup is resilient"
    exit 0
fi

add_active_node() {
    local text="$1"
    shift || true
    "$WV" add "$text" --status=active --force \
        --criteria="hook test setup works|active node available for hook checks" \
        --risks=low "$@"
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

setup_uninitialized_project
OUTPUT=$(bash "$HOOKS_DIR/session-start-context.sh" 2>/dev/null || true)
assert_contains "$OUTPUT" "hookSpecificOutput" "session-start: still returns hook output in uninitialized repo"
assert_equals "absent" "$(if [ -d "$TEST_DIR/project/.weave" ]; then echo present; else echo absent; fi)" "session-start: does not create .weave in uninitialized repo"

# Graph-shrink guard: a stale/wiped hot-zone DB at session-start must never commit a
# .weave snapshot smaller than HEAD (regression that lost the cross-harness telemetry
# epic on 2026-06-24). Build a committed HEAD graph (BIG), then restore a smaller but
# consistent on-disk snapshot (SMALL) and confirm the hook self-heals instead of
# clobbering: no session-start commit, disk restored to HEAD, warning surfaced.
setup_test_env
PROJ="$TEST_DIR/project"
add_active_node "shrink-guard node 1" >/dev/null 2>&1
add_active_node "shrink-guard node 2" >/dev/null 2>&1
"$WV" sync >/dev/null 2>&1 || true
# Capture the SMALL (2-node) consistent snapshot before growing the graph.
SMALL_SNAP="$TEST_DIR/small-weave"
rm -rf "$SMALL_SNAP" && cp -a "$PROJ/.weave" "$SMALL_SNAP"
add_active_node "shrink-guard node 3" >/dev/null 2>&1
add_active_node "shrink-guard node 4" >/dev/null 2>&1
"$WV" sync >/dev/null 2>&1 || true
# wv auto-checkpoints .weave on sync; commit only if anything is still unstaged so
# HEAD ends with the full (BIG) graph either way.
( cd "$PROJ" && git add .weave/ 2>/dev/null; git diff --cached --quiet -- .weave/ || git commit -q -m "full graph" ) || true
HEAD_NODE_LINES=$(git -C "$PROJ" show HEAD:.weave/nodes.jsonl | wc -l | tr -d ' ')
# Simulate the stale on-disk state a bad reload would leave: restore SMALL over disk
# and reload so the live DB matches it (disk + DB both behind the committed HEAD).
rm -rf "$PROJ/.weave" && cp -a "$SMALL_SNAP" "$PROJ/.weave"
"$WV" load >/dev/null 2>&1 || true
COMMITS_BEFORE=$(git -C "$PROJ" log --oneline | grep -c "session-start state" || true)
OUTPUT=$(bash "$HOOKS_DIR/session-start-context.sh" 2>/dev/null || true)
COMMITS_AFTER=$(git -C "$PROJ" log --oneline | grep -c "session-start state" || true)
DISK_NODE_LINES=$(wc -l < "$PROJ/.weave/nodes.jsonl" | tr -d ' ')
assert_equals "$COMMITS_BEFORE" "$COMMITS_AFTER" "session-start: shrink guard does NOT commit a graph smaller than HEAD"
assert_equals "$HEAD_NODE_LINES" "$DISK_NODE_LINES" "session-start: shrink guard restores .weave/nodes.jsonl from HEAD"
assert_contains "$OUTPUT" "shrank" "session-start: shrink guard surfaces a regression warning"

# Negative case: when disk matches HEAD (no shrink), the guard stays silent.
setup_test_env
add_active_node "no-shrink node" >/dev/null 2>&1
"$WV" sync >/dev/null 2>&1 || true
( cd "$TEST_DIR/project" && git add .weave/ 2>/dev/null; git diff --cached --quiet -- .weave/ || git commit -q -m "graph" ) || true
OUTPUT=$(bash "$HOOKS_DIR/session-start-context.sh" 2>/dev/null || true)
assert_not_contains "$OUTPUT" "shrank" "session-start: no regression warning when disk matches HEAD"

# Session-start snapshot stages graph state only (wv-2e6341): it swept a
# half-written test-map.conf row into a [skip ci] 'session-start state' commit
# that ran none of the gates a config change selects. A graph change still
# commits; the config edit stays in the tree; a staged config edit is caller
# work and stops the snapshot. The shrink-guard cases above are unchanged.
setup_test_env
PROJ="$TEST_DIR/project"
add_active_node "snapshot scope node" >/dev/null 2>&1
"$WV" sync >/dev/null 2>&1 || true
printf '[map]\nsrc/a.sh = tests/test-a.sh\n' > "$PROJ/.weave/test-map.conf"
( cd "$PROJ" && git add -A .weave/ && git commit -q -m "graph + config" ) >/dev/null 2>&1 || true
echo 'src/b.sh = tests/test-b.sh' >> "$PROJ/.weave/test-map.conf"
echo "- snapshot scope trail $$" >> "$PROJ/.weave/trails.md"
_SS_BASE=$(git -C "$PROJ" rev-parse HEAD)
bash "$HOOKS_DIR/session-start-context.sh" >/dev/null 2>&1 || true
assert_equals "committed" "$(git -C "$PROJ" diff --quiet "$_SS_BASE" HEAD -- .weave/trails.md && echo uncommitted || echo committed)" \
    "session-start: the snapshot still commits graph state"
# Captured first: piped into grep -q, a MATCH could SIGPIPE git log and pipefail
# would report it as "absent" -- a pass on the very regression this guards.
_ss_log=$(git -C "$PROJ" log --format= --name-only "$_SS_BASE..HEAD")
assert_equals "absent" "$(grep -qx '.weave/test-map.conf' <<< "$_ss_log" && echo present || echo absent)" \
    "session-start: a dirty test-map.conf is not swept into the snapshot"
assert_equals " M .weave/test-map.conf" "$(git -C "$PROJ" status --porcelain -- .weave/test-map.conf)" \
    "session-start: the test-map.conf edit stays in the working tree"

git -C "$PROJ" add .weave/test-map.conf
echo "- staged-config trail $$" >> "$PROJ/.weave/trails.md"
_SS_BASE=$(git -C "$PROJ" rev-parse HEAD)
bash "$HOOKS_DIR/session-start-context.sh" >/dev/null 2>&1 || true
assert_equals "$_SS_BASE" "$(git -C "$PROJ" rev-parse HEAD)" \
    "session-start: a staged test-map.conf stops the snapshot commit"
assert_equals "M  .weave/test-map.conf" "$(git -C "$PROJ" status --porcelain -- .weave/test-map.conf)" \
    "session-start: the staged test-map.conf stays staged"
git -C "$PROJ" reset -q -- .weave/test-map.conf

# The session-start snapshot honours the auto-commit switch (wv-99d4d2): it was
# the one self-made commit wv-fbbdff left reading neither WV_AUTO_CHECKPOINT=0
# nor the hold file, so a release holding HEAD still could still be moved.
_SS_HOLD="$PROJ/$(git -C "$PROJ" rev-parse --git-path weave-autocommit-hold)"
echo "- held trail $$" >> "$PROJ/.weave/trails.md"
_SS_BASE=$(git -C "$PROJ" rev-parse HEAD)
WV_AUTO_CHECKPOINT=0 bash "$HOOKS_DIR/session-start-context.sh" >/dev/null 2>&1 || true
assert_equals "$_SS_BASE" "$(git -C "$PROJ" rev-parse HEAD)" \
    "session-start: WV_AUTO_CHECKPOINT=0 stops the snapshot commit"
touch "$_SS_HOLD"
env -u WV_AUTO_CHECKPOINT bash "$HOOKS_DIR/session-start-context.sh" >/dev/null 2>&1 || true
assert_equals "$_SS_BASE" "$(git -C "$PROJ" rev-parse HEAD)" \
    "session-start: the hold file stops the snapshot commit with no variable set"
rm -f "$_SS_HOLD"
env -u WV_AUTO_CHECKPOINT bash "$HOOKS_DIR/session-start-context.sh" >/dev/null 2>&1 || true
assert_equals "committed" "$(git -C "$PROJ" diff --quiet "$_SS_BASE" HEAD -- .weave/trails.md && echo uncommitted || echo committed)" \
    "session-start: control: with the hold file gone the snapshot commits"

# --- pre-compact-context.sh ---
echo ""
echo "--- pre-compact-context.sh ---"
setup_test_env

# Add a node so there's data to report
add_active_node "Test compact node" 2>/dev/null

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

# --- pre-action.sh (malformed payload fails closed) ---
# wv-692c2d gave the fail-closed posture to `wv hook dispatch`/`normalize`, and
# tests/test-codex-hooks.sh covers those. Nothing exercised pre-action.sh's own
# copy of the rule, so relocating it into _hc_check_payload could have silently
# downgraded a broken mutation event to inspection with every suite still green.
echo ""
echo "--- pre-action.sh (malformed payload) ---"
setup_test_env

set +e
OUTPUT=$(echo '{"tool_input":{"file_path":"test.py"}}' | bash "$HOOKS_DIR/pre-action.sh" 2>&1)
EXIT_CODE=$?
set -e
assert_exit_code "2" "$EXIT_CODE" "pre-action: exits 2 on a payload missing tool_name"
assert_contains "$OUTPUT" "malformed" "pre-action: names the malformation on stderr"

set +e
OUTPUT=$(echo '{"tool_name":"Edit","tool_input":"not-an-object"}' | bash "$HOOKS_DIR/pre-action.sh" 2>&1)
EXIT_CODE=$?
set -e
assert_exit_code "2" "$EXIT_CODE" "pre-action: exits 2 when tool_input is not an object"

# Empty stdin is a manual invocation, not a broken host event — it must stay a no-op.
set +e
OUTPUT=$(printf '' | bash "$HOOKS_DIR/pre-action.sh" 2>&1)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "pre-action: empty stdin stays a no-op, not a block"

# --- pre-action.sh (discover phase still blocks edits) ---
echo ""
echo "--- pre-action.sh (discover phase blocks edits) ---"
setup_test_env
printf '%s' discover > "$(owner_dir)/.session_phase"

set +e
OUTPUT=$(echo '{"tool_name":"Edit","tool_input":{"file_path":"test.py"}}' | bash "$HOOKS_DIR/pre-action.sh" 2>&1)
EXIT_CODE=$?
set -e
assert_exit_code "2" "$EXIT_CODE" "pre-action: exits 2 when edit attempted in discover phase"
assert_contains "$OUTPUT" "Discovery is for reading, searching, and planning only" "pre-action: discover edit block explains read-only discovery"

# --- pre-action.sh (with active node) ---
echo ""
echo "--- pre-action.sh (active node, no blockers) ---"
setup_test_env
add_active_node "Active test task" 2>/dev/null

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
add_active_node "MCP test task" 2>/dev/null
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
add_active_node "VS Code test task" 2>/dev/null
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
add_active_node "filePath guard test" 2>/dev/null
set +e
OUTPUT=$(echo '{"tool_name":"create_file","tool_input":{"filePath":"/home/user/.local/lib/weave/lib/something.sh"}}' | bash "$HOOKS_DIR/pre-action.sh" 2>&1)
EXIT_CODE=$?
set -e
assert_exit_code "2" "$EXIT_CODE" "pre-action: blocks installed-path edit via camelCase filePath"
assert_contains "$OUTPUT" "installed copy" "pre-action: shows installed-path error for camelCase filePath"

# Claude Code sends file_path (snake_case) — existing behavior still works
setup_test_env
add_active_node "file_path guard test" 2>/dev/null
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
TASK_ID=$(add_active_node "Cache test" 2>/dev/null | tail -1)
# Clear any existing stamp
rm -f "$(owner_dir)/.context_checked_"* 2>/dev/null || true
set +e
OUTPUT=$(echo '{"tool_name":"Edit","tool_input":{"file_path":"test.py"}}' | bash "$HOOKS_DIR/pre-action.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "cache: first call passes (cache miss)"
TESTS_RUN=$((TESTS_RUN + 1))
if [ -f "$(owner_dir)/.context_checked_${TASK_ID}" ]; then
    echo -e "${GREEN}✓${NC} cache: stamp file created after first call"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "${RED}✗${NC} cache: stamp file created after first call"
    echo "  Expected $(owner_dir)/.context_checked_${TASK_ID} to exist"
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
if [ ! -f "$(owner_dir)/.context_checked_${TASK_ID}" ]; then
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
if [ -f "$(owner_dir)/.context_checked_${TASK_ID}" ]; then
    echo -e "${GREEN}✓${NC} cache: stamp re-created after invalidation"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "${RED}✗${NC} cache: stamp re-created after invalidation"
    echo "  Expected $(owner_dir)/.context_checked_${TASK_ID} to exist"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# --- pre-claim-skills.sh (matching command) ---
echo ""
echo "--- pre-claim-skills.sh ---"
setup_test_env

# Node without done_criteria → hard gate (missing planning)
ID=$("$WV" add "Claim test" --force 2>/dev/null | tail -1)
set +e
OUTPUT=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"cmd\":\"wv work $ID\"}}" | bash "$HOOKS_DIR/pre-claim-skills.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "pre-claim: exits 0 (soft deny) for real Bash payload"
assert_contains "$OUTPUT" "hookSpecificOutput" "pre-claim: uses canonical hookSpecificOutput schema"
assert_contains "$OUTPUT" "permissionDecision" "pre-claim: contains permissionDecision field"
assert_contains "$OUTPUT" "/ship-it" "pre-claim: suggests ship-it when done_criteria absent"
# Combined preflight (wv-7c28f4): ALL unmet gates in ONE message, not serial discovery.
# ID is missing criteria AND alias AND risks — every gate must appear in a single deny.
assert_contains "$OUTPUT" "alias" "pre-claim combined: alias gate reported alongside done_criteria"
assert_contains "$OUTPUT" "pre-mortem" "pre-claim combined: premortem advisory reported alongside done_criteria"
# wv-6e4798: the advisory rides with the deny under its own heading, never among
# the requirements the agent is told to satisfy.
assert_contains "$OUTPUT" "required before claiming: [1] done_criteria" "pre-claim combined: requirements are headed as required"
assert_contains "$OUTPUT" "Advisory, does not block the claim: risks/premortem" "pre-claim combined: the risks advisory is headed apart from the requirements"
_req_part=$(printf '%s' "$OUTPUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' | sed 's/Advisory, does not block the claim:.*//')
assert_equals "0" "$(grep -c 'risks/premortem' <<< "$_req_part" || true)" "pre-claim combined: the requirement list does not name risks/premortem"

# wv-6e4798: criteria and alias set, risks absent. The advisory alone never
# denies: it returns as context and the host's normal flow decides the claim.
# This denied on every retry while the test above it asserted only exit 0.
ID_ADV=$("$WV" add "Claim test advisory only" --alias=claim-adv --metadata='{"done_criteria":["c1"]}' --force 2>/dev/null | tail -1)
set +e
OUTPUT_ADV=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"cmd\":\"wv work $ID_ADV\"}}" | bash "$HOOKS_DIR/pre-claim-skills.sh" 2>/dev/null)
EXIT_CODE_ADV=$?
set -e
assert_exit_code "0" "$EXIT_CODE_ADV" "pre-claim advisory-only: exits 0"
assert_equals "null" "$(printf '%s' "$OUTPUT_ADV" | jq -r '.hookSpecificOutput.permissionDecision // "null"' 2>/dev/null)" "pre-claim advisory-only: no permission decision, so the claim is not denied"
assert_contains "$(printf '%s' "$OUTPUT_ADV" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)" "not a requirement; the claim proceeds: risks/premortem not set" "pre-claim advisory-only: the advice returns as additionalContext"

# Node with done_criteria but no risks → tiered advisory
ID2=$("$WV" add "Claim test criteria-only" --metadata='{"done_criteria":["c1"]}' --force 2>/dev/null | tail -1)
set +e
OUTPUT2=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"cmd\":\"wv work $ID2\"}}" | bash "$HOOKS_DIR/pre-claim-skills.sh" 2>/dev/null)
EXIT_CODE2=$?
set -e
assert_exit_code "0" "$EXIT_CODE2" "pre-claim: exits 0 when criteria set but risks absent"
assert_contains "$OUTPUT2" "pre-mortem" "pre-claim: suggests pre-mortem when done_criteria present but risks absent"

# Node with done_criteria + risks but no alias → tier 3 deny
ID3_NOALIAS=$("$WV" add "Claim test no alias" --metadata='{"done_criteria":["c1"],"risks":[]}' --force 2>/dev/null | tail -1)
set +e
OUTPUT3_NOALIAS=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"cmd\":\"wv work $ID3_NOALIAS\"}}" | bash "$HOOKS_DIR/pre-claim-skills.sh" 2>/dev/null)
EXIT_CODE3_NOALIAS=$?
set -e
assert_exit_code "0" "$EXIT_CODE3_NOALIAS" "pre-claim: exits 0 (soft deny) when alias absent"
assert_contains "$OUTPUT3_NOALIAS" "alias" "pre-claim: suggests alias when done_criteria+risks present but alias absent"

# Node with done_criteria, risks, and alias → silent pass
ID3=$("$WV" add "Claim test both" --alias=claim-test --metadata='{"done_criteria":["c1"],"risks":[]}' --force 2>/dev/null | tail -1)
set +e
OUTPUT3=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"cmd\":\"wv work $ID3\"}}" | bash "$HOOKS_DIR/pre-claim-skills.sh" 2>/dev/null)
EXIT_CODE3=$?
set -e
assert_exit_code "0" "$EXIT_CODE3" "pre-claim: exits 0 when done_criteria, risks, and alias present"
assert_equals "" "$OUTPUT3" "pre-claim: silent when planning metadata complete"

# finding wv-cd5ddb: a "premortem" key (what /pre-mortem writes) must satisfy the
# pre-mortem gate — not only the legacy "risks" key. Otherwise a node with a real
# premortem gets nagged for a missing static risk label.
ID_PM=$("$WV" add "Claim test premortem key" --alias=claim-pm --metadata='{"done_criteria":["c1"],"premortem":"Risk: x. Mitigation: y."}' --force 2>/dev/null | tail -1)
set +e
OUTPUT_PM=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"cmd\":\"wv work $ID_PM\"}}" | bash "$HOOKS_DIR/pre-claim-skills.sh" 2>/dev/null)
EXIT_CODE_PM=$?
set -e
assert_exit_code "0" "$EXIT_CODE_PM" "pre-claim: exits 0 when premortem key present"
assert_equals "" "$OUTPUT_PM" "pre-claim: silent when premortem (not risks) satisfies the gate (wv-cd5ddb)"

# finding wv-cd5ddb: the pre-mortem advisory is grounded in real wv impact blast
# radius, not the static risk-string heuristic. A node that blocks another should
# report a non-zero impacted count in the advisory.
ID_SEED=$("$WV" add "Impact advisory seed" --metadata='{"done_criteria":["c1"]}' --force 2>/dev/null | tail -1)
ID_DOWN=$("$WV" add "Impact advisory downstream" --force 2>/dev/null | tail -1)
"$WV" link "$ID_SEED" "$ID_DOWN" --type=blocks --context='{"summary":"seed blocks downstream"}' >/dev/null 2>&1
set +e
OUTPUT_IMP=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"cmd\":\"wv work $ID_SEED\"}}" | bash "$HOOKS_DIR/pre-claim-skills.sh" 2>/dev/null)
EXIT_CODE_IMP=$?
set -e
assert_exit_code "0" "$EXIT_CODE_IMP" "pre-claim: exits 0 with impact data (a deny here: the node has no alias)"
assert_contains "$OUTPUT_IMP" "pre-mortem" "pre-claim: still suggests pre-mortem when risks/premortem absent"
assert_contains "$OUTPUT_IMP" "Blast radius (wv impact)" "pre-claim: advisory grounded in wv impact blast radius (wv-cd5ddb)"
assert_contains "$OUTPUT_IMP" "1 impacted" "pre-claim: advisory reports real impacted count"

# Graceful fallback: when impact yields no data the advisory still fires (no Blast line),
# and the claim is never errored. ID2 (no edges) exercises the empty-blast-radius path.
set +e
OUTPUT_FB=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"cmd\":\"wv work $ID2\"}}" | bash "$HOOKS_DIR/pre-claim-skills.sh" 2>/dev/null)
EXIT_CODE_FB=$?
set -e
assert_exit_code "0" "$EXIT_CODE_FB" "pre-claim: exits 0 when impact has no downstream (graceful)"
assert_contains "$OUTPUT_FB" "pre-mortem" "pre-claim: advisory still fires with empty blast radius"

# Back-compat: older test payload shape still accepted
set +e
OUTPUT=$(echo "{\"command\":\"wv update $ID --status=active\"}" | bash "$HOOKS_DIR/pre-claim-skills.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "pre-claim: exits 0 for legacy root command payload"

# Non-matching command
OUTPUT=$(echo '{"command":"wv list --json"}' | bash "$HOOKS_DIR/pre-claim-skills.sh" 2>/dev/null || true)
assert_equals "" "$OUTPUT" "pre-claim: silent for non-matching commands"

# Fail-open: unknown node ID (or transient empty read) must not block.
# Previously: wv show returned [], hook interpreted missing done_criteria as a
# claim-on-unplanned-node and soft-denied. New behavior: empty read → allow,
# let wv work itself surface the clearer "node not found" error.
set +e
OUTPUT=$(echo '{"tool_name":"Bash","tool_input":{"cmd":"wv work wv-deadbe"}}' \
    | bash "$HOOKS_DIR/pre-claim-skills.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "pre-claim: exits 0 for unknown node (fail-open)"
assert_equals "" "$OUTPUT" "pre-claim: silent on unreadable / missing node"

# --- pre-close-verification.sh (no verification) ---
echo ""
echo "--- pre-close-verification.sh ---"
setup_test_env
ID=$(add_active_node "Close test" 2>/dev/null | tail -1)

set +e
OUTPUT=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"cmd\":\"wv done $ID\"}}" | bash "$HOOKS_DIR/pre-close-verification.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_contains "$OUTPUT" "permissionDecisionReason" "pre-close: warns when no verification metadata for real Bash payload"
assert_contains "$OUTPUT" "\"permissionDecision\": \"deny\"" "pre-close: uses hookSpecificOutput permissionDecision deny schema (lowercase)"
assert_exit_code "0" "$EXIT_CODE" "pre-close: exits 0 (soft deny) when no verification"

# With --skip-verification flag (should pass)
SKIP_ID=$(add_active_node "Skip verification close test" --metadata='{"commit":"deadbeef"}' 2>/dev/null | tail -1)
set +e
OUTPUT=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"cmd\":\"wv done $SKIP_ID --skip-verification\"}}" | bash "$HOOKS_DIR/pre-close-verification.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "pre-close: exits 0 with --skip-verification bypass on real Bash payload"

# --skip-verification must be reachable for a node with NO commit attribution.
# It used to be checked AFTER the attribution gate, so the gate denied first and
# the flag never ran -- unreachable for exactly the closes it exists for. The
# existing bypass case above gives the node {"commit":"deadbeef"}, which routes
# around the attribution gate entirely, so it never covered this (wv-e22386).
UNATTRIB_ID=$(add_active_node "Skip verification, no commit attribution" 2>/dev/null | tail -1)
set +e
OUTPUT=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"cmd\":\"wv done $UNATTRIB_ID --skip-verification\"}}" | bash "$HOOKS_DIR/pre-close-verification.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "pre-close: --skip-verification exits 0 with no commit attribution"
assert_not_contains "$OUTPUT" "No commit attributed" "pre-close: --skip-verification is reached before the attribution deny"

# The attribution deny must not advise amending: the earlier commit may already
# be pushed, and rewriting it orphans the refs recorded against it.
NOAMEND_ID=$(add_active_node "Attribution deny wording" 2>/dev/null | tail -1)
set +e
OUTPUT=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"cmd\":\"wv done $NOAMEND_ID\"}}" | bash "$HOOKS_DIR/pre-close-verification.sh" 2>/dev/null)
set -e
assert_not_contains "$OUTPUT" "amend the latest work commit" "pre-close: deny no longer advises amending a possibly-pushed commit"

# Finding nodes require violation_type (enum) even with --skip-verification
FINDING_ID=$(add_active_node "Finding close test" --metadata='{"type":"finding"}' 2>/dev/null | tail -1)
set +e
OUTPUT=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"cmd\":\"wv done $FINDING_ID --skip-verification\"}}" | bash "$HOOKS_DIR/pre-close-verification.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_contains "$OUTPUT" "finding node requires violation_type" "pre-close: finding schema enforced before close"
assert_exit_code "0" "$EXIT_CODE" "pre-close: finding schema denial is soft"

# Minimal shape (violation_type only) passes — commit:"deadbeef" bypasses commit-check
"$WV" update "$FINDING_ID" --metadata='{"type":"finding","commit":"deadbeef","finding":{"violation_type":"repo:hygiene"}}' 2>/dev/null
OUTPUT=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"cmd\":\"wv done $FINDING_ID --skip-verification\"}}" | bash "$HOOKS_DIR/pre-close-verification.sh" 2>/dev/null || true)
assert_equals "" "$OUTPUT" "pre-close: minimal finding (violation_type only) passes"

# Full shape also passes
"$WV" update "$FINDING_ID" --metadata='{"type":"finding","commit":"deadbeef","finding":{"violation_type":"test:gap","root_cause":"bootstrap omitted active-node type","proposed_fix":"record active_node_type in session_start metadata","confidence":"high","fixable":true}}' 2>/dev/null
OUTPUT=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"cmd\":\"wv done $FINDING_ID --skip-verification\"}}" | bash "$HOOKS_DIR/pre-close-verification.sh" 2>/dev/null || true)
assert_equals "" "$OUTPUT" "pre-close: full finding metadata passes with skip-verification"

# Free-text violation_type (not in enum) rejected — bypass write-time guard to test hook in isolation
sqlite3 "$WV_DB" "UPDATE nodes SET metadata=json_set(metadata, '$.finding.violation_type', 'R10:open_node_at_end') WHERE id='$FINDING_ID';"
OUTPUT=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"cmd\":\"wv done $FINDING_ID --skip-verification\"}}" | bash "$HOOKS_DIR/pre-close-verification.sh" 2>/dev/null || true)
assert_contains "$OUTPUT" "invalid enum" "pre-close: free-text violation_type rejected with enum hint"

# Optional fields present but invalid are rejected — bypass write-time guard to test hook in isolation
_BAD_META='{"type":"finding","commit":"deadbeef","finding":{"violation_type":"repo:regression","confidence":0.92,"fixable":"yes"}}'
sqlite3 "$WV_DB" "UPDATE nodes SET metadata=json('$_BAD_META') WHERE id='$FINDING_ID';"
OUTPUT=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"cmd\":\"wv done $FINDING_ID --skip-verification\"}}" | bash "$HOOKS_DIR/pre-close-verification.sh" 2>/dev/null || true)
assert_contains "$OUTPUT" "finding.confidence" "pre-close: invalid optional field types are denied"

# With verification metadata
"$WV" update "$ID" --metadata='{"verification":{"method":"test","result":"pass"},"commit":"deadbeef"}' 2>/dev/null
OUTPUT=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"cmd\":\"wv done $ID\"}}" | bash "$HOOKS_DIR/pre-close-verification.sh" 2>/dev/null || true)
# Should NOT warn when verification exists
TESTS_RUN=$((TESTS_RUN + 1))
if ! grep -q "Verification evidence required" <<< "$OUTPUT"; then
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
ID2="$(add_active_node "inline-flag test node" --metadata='{"commit":"deadbeef"}' 2>/dev/null | grep -oP 'wv-[0-9a-f]{4,6}')"
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

# File-based --verification-evidence flag also satisfies hook
set +e
OUTPUT=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"cmd\":\"wv done $ID2 --verification-evidence-file=/tmp/evidence.txt --learning=\\\"test\\\"\"}}" | bash "$HOOKS_DIR/pre-close-verification.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "pre-close: exits 0 when --verification-evidence-file flag present"
assert_equals "" "$OUTPUT" "pre-close: silent (no deny) when --verification-evidence-file flag present"

# ship-agent uses the same close-time gate and must honor inline verification flags
set +e
OUTPUT=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"cmd\":\"wv ship-agent $ID2 --verification-method=\\\"make check\\\" --learning=\\\"test\\\" --json\"}}" | bash "$HOOKS_DIR/pre-close-verification.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "pre-close: exits 0 for ship-agent when inline verification flag present"
assert_equals "" "$OUTPUT" "pre-close: silent (no deny) for ship-agent when verification flag present"

# Agent mode emits progress markers to stderr for close-time hook checks
set +e
OUTPUT=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"cmd\":\"wv done $ID2 --verification-method=\\\"make check\\\" --learning=\\\"test\\\"\"}}" | env WV_AGENT_MODE=1 bash "$HOOKS_DIR/pre-close-verification.sh" 2>&1)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "pre-close: agent mode progress markers still allow the command"
assert_contains "$OUTPUT" "[wv-agent-mode] pre-close: load node metadata" "pre-close: agent mode reports node metadata progress"
assert_contains "$OUTPUT" "[wv-agent-mode] pre-close: check verification inputs" "pre-close: agent mode reports verification progress"

# Agent mode surfaces strict timeout messages when a hook stage exceeds its timeout
set +e
OUTPUT=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"cmd\":\"wv done $ID2 --verification-method=\\\"make check\\\" --learning=\\\"test\\\"\"}}" | env WV_AGENT_MODE=1 WV_AGENT_TEST_TIMEOUT_STAGE=node-json bash "$HOOKS_DIR/pre-close-verification.sh" 2>&1)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "pre-close: timeout denial remains a soft deny in agent mode"
assert_contains "$OUTPUT" "timed out during node metadata lookup" "pre-close: agent mode timeout explains which stage timed out"

git -C "$TEST_DIR/project" add -A 2>/dev/null
git -C "$TEST_DIR/project" commit -m "hook hygiene baseline" -q 2>/dev/null || true

COMMIT_ID=$(add_active_node "commit hygiene test node" --metadata='{"verification":{"method":"test","result":"pass"}}' 2>/dev/null | tail -1)
echo "dirty" > "$TEST_DIR/project/commit-hygiene.txt"
set +e
OUTPUT=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"cmd\":\"wv done $COMMIT_ID\"}}" | bash "$HOOKS_DIR/pre-close-verification.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_contains "$OUTPUT" "Commit work before close" "pre-close: denies close when non-.weave changes are still uncommitted"
assert_exit_code "0" "$EXIT_CODE" "pre-close: uncommitted-change denial is soft"

git -C "$TEST_DIR/project" add commit-hygiene.txt
git -C "$TEST_DIR/project" commit -m "feat: unattributed commit hygiene" -q 2>/dev/null
OUTPUT=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"cmd\":\"wv done $COMMIT_ID\"}}" | bash "$HOOKS_DIR/pre-close-verification.sh" 2>/dev/null || true)
assert_contains "$OUTPUT" "No commit attributed to $COMMIT_ID" "pre-close: denies close when the work commit is not attributed to the node"

git -C "$TEST_DIR/project" commit --amend -m "feat: attributed commit hygiene" -m "Weave-ID: $COMMIT_ID" -q 2>/dev/null
OUTPUT=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"cmd\":\"wv done $COMMIT_ID\"}}" | bash "$HOOKS_DIR/pre-close-verification.sh" 2>/dev/null || true)
assert_equals "" "$OUTPUT" "pre-close: silent when an attributed work commit exists"

# wv-e48993: the dirty-tree gate must scope to the closing node's OWN
# touched_files (captured live by wv-touched-files.sh), not every dirty file
# in the repo -- an earlier, already-closed session's leftover foreign dirt
# must not block this node's close. Give it an attributed commit up front
# (mirrors COMMIT_ID's own setup above) so the dirty-file check is the ONLY
# gate left to exercise -- otherwise the later "no commit attributed" gate
# would also deny, for an unrelated reason, and mask what this is testing.
SCOPE_ID=$(add_active_node "touched-files scoping test node" \
    --metadata='{"verification":{"method":"test","result":"pass"},"touched_files":["scoped-own.txt"]}' 2>/dev/null | tail -1)
echo "seed" > "$TEST_DIR/project/scope-seed.txt"
git -C "$TEST_DIR/project" add scope-seed.txt
git -C "$TEST_DIR/project" commit -q -m "feat: scope test seed" -m "Weave-ID: $SCOPE_ID"

echo "foreign" > "$TEST_DIR/project/foreign-dirt.txt"
set +e
OUTPUT=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"cmd\":\"wv done $SCOPE_ID\"}}" | bash "$HOOKS_DIR/pre-close-verification.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_equals "" "$OUTPUT" "pre-close: silent when the only dirt is outside this node's touched_files"
assert_exit_code "0" "$EXIT_CODE" "pre-close: foreign-dirt pass-through does not itself error"

rm -f "$TEST_DIR/project/foreign-dirt.txt"
echo "own work" > "$TEST_DIR/project/scoped-own.txt"
set +e
OUTPUT=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"cmd\":\"wv done $SCOPE_ID\"}}" | bash "$HOOKS_DIR/pre-close-verification.sh" 2>/dev/null)
set -e
assert_contains "$OUTPUT" "Commit work before close" "pre-close: still denies close when dirt IS in this node's touched_files"

rm -f "$TEST_DIR/project/scoped-own.txt"
git -C "$TEST_DIR/project" rm -q scope-seed.txt >/dev/null 2>&1 || true
git -C "$TEST_DIR/project" commit -q -m "chore: clean up scoping test fixture" >/dev/null 2>&1 || true
"$WV" "done" "$SCOPE_ID" --skip-verification 2>/dev/null || true  # cleanup

# wv-822bea/wv-37e2e0: metadata.touched_files is capped at 50 entries
# (wv-touched-files.sh's WV_TOUCHED_NODE_CAP); node_files is the same
# attribution written UNCAPPED. A node whose 51st touched file fell off the
# metadata ring must still be recognized as owning it via node_files, not
# treated as foreign dirt that blocks close.
CAP_ID=$(add_active_node ">50 touched-files cap regression node" \
    --metadata='{"verification":{"method":"test","result":"pass"}}' 2>/dev/null | tail -1)
CAP_META='{"touched_files":['
for _capn in $(seq 1 50); do
    CAP_META="${CAP_META}\"cap-file-${_capn}.txt\","
done
CAP_META="${CAP_META%,}]}"
sqlite3 "$WV_DB" "UPDATE nodes SET metadata=json_patch(metadata, '$CAP_META') WHERE id='$CAP_ID';" 2>/dev/null
for _capn in $(seq 1 51); do
    sqlite3 "$WV_DB" "INSERT OR IGNORE INTO node_files(node_id, path) VALUES ('$CAP_ID', 'cap-file-${_capn}.txt');" 2>/dev/null
done
echo "seed" > "$TEST_DIR/project/cap-seed.txt"
git -C "$TEST_DIR/project" add cap-seed.txt
git -C "$TEST_DIR/project" commit -q -m "feat: cap test seed" -m "Weave-ID: $CAP_ID"
# cap-file-51.txt is in node_files (uncapped) but fell out of metadata's
# 50-entry ring — dirtying it must still be recognized as this node's own.
echo "own work past the cap" > "$TEST_DIR/project/cap-file-51.txt"
set +e
OUTPUT=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"cmd\":\"wv done $CAP_ID\"}}" | bash "$HOOKS_DIR/pre-close-verification.sh" 2>/dev/null)
set -e
assert_contains "$OUTPUT" "Commit work before close" "pre-close: 51st touched file (past metadata cap) still recognized via node_files"

rm -f "$TEST_DIR/project/cap-file-51.txt"
git -C "$TEST_DIR/project" rm -q cap-seed.txt >/dev/null 2>&1 || true
git -C "$TEST_DIR/project" commit -q -m "chore: clean up cap test fixture" >/dev/null 2>&1 || true
"$WV" "done" "$CAP_ID" --skip-verification 2>/dev/null || true  # cleanup

# wv-cdafa1: inside an E5 capture window (WV_WORKFLOW_ID set) the attribution
# hook queues the edit instead of writing the graph. Close verification runs
# before wv done applies the queue, so it must count a queued path as the
# node's own. touched_files names another file, so the gate is in its scoped
# mode, where a file it does not know is foreign and lets the close through.
QUEUE_ID=$(add_active_node "queued attribution close node" \
    --metadata='{"verification":{"method":"test","result":"pass"},"touched_files":["queue-other.txt"]}' 2>/dev/null | tail -1)
echo "seed" > "$TEST_DIR/project/queue-seed.txt"
git -C "$TEST_DIR/project" add queue-seed.txt
git -C "$TEST_DIR/project" commit -q -m "feat: queue test seed" -m "Weave-ID: $QUEUE_ID"
echo "own work, queued" > "$TEST_DIR/project/queued-own.txt"
echo "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$TEST_DIR/project/queued-own.txt\"},\"tool_response\":{\"success\":true}}" \
    | WV_WORKFLOW_ID=e5-test bash "$HOOKS_DIR/wv-touched-files.sh" >/dev/null 2>&1 || true
assert_equals "0" "$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM node_files WHERE node_id='$QUEUE_ID' AND path='queued-own.txt';")" \
    "attribution queue: an edit in a capture window does not write the graph"
assert_contains "$(cat "$(dirname "$WV_DB")/attribution-queue" 2>/dev/null)" "queued-own.txt" \
    "attribution queue: the edit waits in the queue beside the DB"
set +e
OUTPUT=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"cmd\":\"wv done $QUEUE_ID\"}}" | bash "$HOOKS_DIR/pre-close-verification.sh" 2>/dev/null)
set -e
assert_contains "$OUTPUT" "Commit work before close" "pre-close: a queued, unapplied edit is still the node's own"
rm -f "$TEST_DIR/project/queued-own.txt" "$(dirname "$WV_DB")/attribution-queue"
git -C "$TEST_DIR/project" rm -q queue-seed.txt >/dev/null 2>&1 || true
git -C "$TEST_DIR/project" commit -q -m "chore: clean up queue test fixture" >/dev/null 2>&1 || true
"$WV" "done" "$QUEUE_ID" --skip-verification 2>/dev/null || true  # cleanup

# wv-cdafa1: counted admission keeps only source=agent call-log rows and needs
# each row's graph_identity_before to equal the previous row's after. An agent
# read, an Edit through the hook, an agent read, then an agent mutation: in a
# window the read leaves the queue alone and the mutation applies it, so the
# chain holds. Outside a window the hook writes at once, between two agent
# rows, which is the break the queue exists to prevent -- the control that
# shows the chain assertion can fail.
_chain_run() {  # <window: 1|0> <file>
    local id log window="$1" file="$2"
    log="$TEST_DIR/chain-$file.jsonl"
    rm -f "$log"
    # The real config.env sets WV_CALL_LOG and beats the environment, so these
    # agent rows would land in the user's own call log; give wv an empty one.
    local WV_CONFIG_DIR="$TEST_DIR/chain-config"
    mkdir -p "$WV_CONFIG_DIR"
    export WV_CONFIG_DIR
    id=$(add_active_node "attribution chain node $file" --metadata='{"verification":{"method":"test","result":"pass"}}' 2>/dev/null | tail -1)
    WV_CALL_LOG="$log" WV_CALL_SOURCE=agent "$WV" status >/dev/null 2>&1 || true
    echo "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$TEST_DIR/project/$file\"},\"tool_response\":{\"success\":true}}" \
        | if [ "$window" = 1 ]; then WV_WORKFLOW_ID=e5-test bash "$HOOKS_DIR/wv-touched-files.sh"; \
          else env -u WV_WORKFLOW_ID bash "$HOOKS_DIR/wv-touched-files.sh"; fi >/dev/null 2>&1 || true
    WV_CALL_LOG="$log" WV_CALL_SOURCE=agent "$WV" show "$id" --json >/dev/null 2>&1 || true
    CHAIN_AFTER_READ=$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM node_files WHERE node_id='$id' AND path='$file';")
    WV_CALL_LOG="$log" WV_CALL_SOURCE=agent "$WV" update "$id" --metadata='{"chain_probe":1}' >/dev/null 2>&1 || true
    CHAIN_AFTER_MUTATION=$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM node_files WHERE node_id='$id' AND path='$file';")
    CHAIN_ROWS=$(jq -s '[.[] | select(.source == "agent" and .parent_call_id == null)] | length' "$log" 2>/dev/null)
    CHAIN_BREAKS=$(jq -s '[.[] | select(.source == "agent" and .parent_call_id == null)] as $r
        | [range(1; $r | length) | select($r[.].graph_identity_before != $r[. - 1].graph_identity_after)] | length' "$log" 2>/dev/null)
    "$WV" "done" "$id" --skip-verification >/dev/null 2>&1 || true
}
_chain_run 1 chain-window.txt
assert_equals "3" "$CHAIN_ROWS" "attribution chain: three agent rows were logged in the window"
assert_equals "0" "$CHAIN_AFTER_READ" "attribution chain: an agent read leaves the queued edit unapplied"
assert_equals "1" "$CHAIN_AFTER_MUTATION" "attribution chain: the agent's next mutation applies the queued edit"
assert_equals "0" "$CHAIN_BREAKS" "attribution chain: an Edit in a capture window leaves the agent identity chain unbroken"
_chain_run 0 chain-direct.txt
assert_equals "1" "$CHAIN_AFTER_READ" "attribution chain: outside a window the edit is written at once"
assert_equals "1" "$CHAIN_BREAKS" "attribution chain: outside a window the direct write breaks the chain (control)"

# wv-734186: verification_method/verification_evidence were only ever
# askable at THIS close-time gate -- wv add --verification-plan lets it be
# recorded upfront, and the gate's own rejection must surface it back as a
# reminder rather than asking the question cold a second time.
PLAN_ID=$(add_active_node "verification plan test node" \
    --metadata='{"verification_plan":"run pytest tests/foo.py"}' 2>/dev/null | tail -1)
echo "seed" > "$TEST_DIR/project/plan-seed.txt"
git -C "$TEST_DIR/project" add plan-seed.txt
git -C "$TEST_DIR/project" commit -q -m "feat: plan seed" -m "Weave-ID: $PLAN_ID"
OUTPUT=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"cmd\":\"wv done $PLAN_ID\"}}" | bash "$HOOKS_DIR/pre-close-verification.sh" 2>/dev/null)
assert_contains "$OUTPUT" 'Recorded plan: \"run pytest tests/foo.py\"' \
    "pre-close: surfaces a recorded --verification-plan as a reminder"
"$WV" "done" "$PLAN_ID" --skip-verification 2>/dev/null || true  # cleanup

"$WV" "done" "$ID2" --skip-verification 2>/dev/null || true  # cleanup

# Non-matching command
OUTPUT=$(echo '{"command":"wv list"}' | bash "$HOOKS_DIR/pre-close-verification.sh" 2>/dev/null || true)
assert_equals "" "$OUTPUT" "pre-close: silent for non-matching commands"

# --- bash-dedup.sh / bash-dedup-post.sh ---
echo ""
echo "--- bash-dedup.sh / bash-dedup-post.sh ---"
setup_test_env

DEDUP_LOCK_DIR="/tmp/weave-bash-locks-$(id -u)/$(echo "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" | md5sum 2>/dev/null | cut -c1-8 || echo default)"
# 700 like the hook makes it: a base left 775 by the umask is refused (wv-80be32).
(umask 077 && mkdir -p "$DEDUP_LOCK_DIR")

# First call: lock is absent — should allow (exit 0, no denial output)
rm -f "$DEDUP_LOCK_DIR/wv-sync.lock"
set +e
OUTPUT=$(echo '{"tool_name":"Bash","tool_input":{"command":"wv sync --gh"}}' | bash "$HOOKS_DIR/bash-dedup.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "bash-dedup: first call exits 0 (allow)"
TESTS_RUN=$((TESTS_RUN + 1))
if grep -q '"deny"' <<< "$OUTPUT"; then
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

# wv-d3af9a: a command another PreToolUse hook blocked never started, so no
# PostToolUse cleared its pending lock, which then denied the corrected retry
# for the whole 120s grace period. Past the spawn window a pending lock denies
# only while its command is actually running.
dedup_pending() {  # dedup_pending <age-seconds> <locked-command>
    printf '%s\npending\n%s\n' "$(( $(date +%s) - $1 ))" "$2" > "$DEDUP_LOCK_DIR/wv-sync.lock"
}
dedup_try() {  # dedup_try [command]
    jq -nc --arg c "${1:-wv sync --gh --retry-marker}" '{tool_name:"Bash",tool_input:{command:$c}}' \
        | bash "$HOOKS_DIR/bash-dedup.sh" 2>/dev/null || true
}
dedup_pending 30 "wv sync --gh --blocked-marker-$$"
assert_not_contains "$(dedup_try)" '"deny"' "bash-dedup: a pending lock whose command never started does not deny the retry"
# wv-5362e2: the spawn window denied a corrected retry 8s after another hook
# refused the first call. Inside the window only an identical call (two issued
# together, before either process exists) denies unchecked.
dedup_pending 2 "wv sync --gh --blocked-marker-$$"
assert_not_contains "$(dedup_try)" '"deny"' "bash-dedup: inside the spawn window a corrected retry of a refused call is allowed"
dedup_pending 2 "wv sync --gh --retry-marker"
DEDUP_OUT=$(dedup_try)
assert_contains "$DEDUP_OUT" '"deny"' "bash-dedup: inside the spawn window an identical call still denies"
assert_contains "$DEDUP_OUT" 'if another hook refused it, it never ran, so re-issue it once the lock is 10s old' "bash-dedup: the unchecked deny names the refusal case and the wait"
assert_not_contains "$DEDUP_OUT" 'already running' "bash-dedup: the unchecked deny does not claim the call is running"
bash -c "exec -a 'wv sync --gh --live-marker-$$' sleep 30" &
DEDUP_LIVE_PID=$!
sleep 1
dedup_pending 30 "wv sync --gh --live-marker-$$"
assert_contains "$(dedup_try)" '"deny"' "bash-dedup: a pending lock whose command is running still denies"
dedup_pending 2 "wv sync --gh --live-marker-$$"
DEDUP_OUT=$(dedup_try)
assert_contains "$DEDUP_OUT" '"deny"' "bash-dedup: inside the spawn window a different call still denies while the locked one runs"
assert_contains "$DEDUP_OUT" 'already running' "bash-dedup: a checked deny says the call is running"
kill "$DEDUP_LIVE_PID" 2>/dev/null || true
wait "$DEDUP_LIVE_PID" 2>/dev/null || true
rm -f "$DEDUP_LOCK_DIR/wv-sync.lock"
# The lock keeps one line per field: a multi-line command stores its first line,
# so it cannot spill into the task-id line, and an identical call still matches.
DEDUP_MULTI=$'wv sync --gh --multi-marker\ngit status'
dedup_try "$DEDUP_MULTI" >/dev/null
assert_equals "3" "$(wc -l < "$DEDUP_LOCK_DIR/wv-sync.lock" | tr -d ' ')" "bash-dedup: a multi-line command takes a three-line lock"
assert_equals "wv sync --gh --multi-marker" "$(sed -n 3p "$DEDUP_LOCK_DIR/wv-sync.lock")" "bash-dedup: the lock stores the command's first line"
assert_contains "$(dedup_try "$DEDUP_MULTI")" '"deny"' "bash-dedup: an identical multi-line call inside the spawn window denies"
rm -f "$DEDUP_LOCK_DIR/wv-sync.lock"

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

# False-positive guard table: structural keywords inside quoted args must not
# classify. Pairs of (cmd, lock-key-that-must-not-exist).
declare -a FP_CASES=(
    'wv done wv-abc1 --learning="bash tests/test-core.sh 109/109, make check 572/572"|make-build'
    "wv done wv-abc1 --learning='pattern: run make check after every change'|make-build"
    'wv done wv-abc1 --learning="after git push the release is live"|git-push'
    'wv done wv-abc1 --learning="poetry run pytest tests/ covers weave_gh"|pytest'
    'wv done wv-abc1 --learning="npm install refreshes the MCP bundle"|npm-build'
)
for entry in "${FP_CASES[@]}"; do
    fp_cmd="${entry%|*}"
    fp_key="${entry##*|}"
    FP_INPUT=$(jq -n --arg cmd "$fp_cmd" '{"tool_name":"Bash","tool_input":{"command":$cmd}}')
    set +e
    OUTPUT=$(echo "$FP_INPUT" | bash "$HOOKS_DIR/bash-dedup.sh" 2>/dev/null)
    EXIT_CODE=$?
    set -e
    assert_exit_code "0" "$EXIT_CODE" "bash-dedup: '$fp_key' keyword in quoted arg exits 0"
    if [[ -f "$DEDUP_LOCK_DIR/$fp_key.lock" ]]; then
        echo -e "${RED}✗${NC} bash-dedup: false-positive $fp_key lock for quoted keyword"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        rm -f "$DEDUP_LOCK_DIR/$fp_key.lock"
    else
        echo -e "${GREEN}✓${NC} bash-dedup: no false-positive $fp_key lock for quoted keyword"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    fi
    TESTS_RUN=$((TESTS_RUN + 1))
done

# True-positive: an actual `make check` invocation must still create the lock.
TP_INPUT='{"tool_name":"Bash","tool_input":{"command":"make check"}}'
set +e
OUTPUT=$(echo "$TP_INPUT" | bash "$HOOKS_DIR/bash-dedup.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "bash-dedup: real 'make check' first call exits 0"
if [[ -f "$DEDUP_LOCK_DIR/make-build.lock" ]]; then
    echo -e "${GREEN}✓${NC} bash-dedup: real 'make check' creates make-build lock"
    TESTS_PASSED=$((TESTS_PASSED + 1))
    rm -f "$DEDUP_LOCK_DIR/make-build.lock"
else
    echo -e "${RED}✗${NC} bash-dedup: real 'make check' must create make-build lock"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi
TESTS_RUN=$((TESTS_RUN + 1))

# Git-commit lock lifecycle. Regression guard: the pattern table in
# bash-dedup-post.sh must include git-commit, or a completed foreground commit
# leaves its lock pending and the second commit of the standard
# "work commit → .weave/ sync commit" sequence is denied for GRACE_PERIOD.
rm -f "$DEDUP_LOCK_DIR/git-commit.lock"
GC_INPUT=$(jq -n --arg cmd 'git add -A && git commit -m "feat: test"' \
    '{"tool_name":"Bash","tool_input":{"command":$cmd}}')
set +e
OUTPUT=$(echo "$GC_INPUT" | bash "$HOOKS_DIR/bash-dedup.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "bash-dedup: first git commit exits 0 (allow)"
TESTS_RUN=$((TESTS_RUN + 1))
if [[ -f "$DEDUP_LOCK_DIR/git-commit.lock" ]]; then
    echo -e "${GREEN}✓${NC} bash-dedup: git commit creates git-commit lock"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "${RED}✗${NC} bash-dedup: git commit must create git-commit lock"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# Second commit while lock is fresh — denied
set +e
OUTPUT=$(echo "$GC_INPUT" | bash "$HOOKS_DIR/bash-dedup.sh" 2>/dev/null)
set -e
assert_contains "$OUTPUT" '"deny"' "bash-dedup: second git commit while locked is denied"

# Foreground completion must clear the git-commit lock
GC_POST=$(jq -n --arg cmd 'git add -A && git commit -m "feat: test"' \
    '{"tool_name":"Bash","tool_input":{"command":$cmd,"run_in_background":false},"tool_response":{"output":"done","success":true}}')
echo "$GC_POST" | bash "$HOOKS_DIR/bash-dedup-post.sh" 2>/dev/null
TESTS_RUN=$((TESTS_RUN + 1))
if [[ -f "$DEDUP_LOCK_DIR/git-commit.lock" ]]; then
    echo -e "${RED}✗${NC} bash-dedup-post: foreground git commit must clear git-commit lock"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    rm -f "$DEDUP_LOCK_DIR/git-commit.lock"
else
    echo -e "${GREEN}✓${NC} bash-dedup-post: foreground git commit clears git-commit lock"
    TESTS_PASSED=$((TESTS_PASSED + 1))
fi

# Background commit must be promoted to running (lock preserved past GRACE_PERIOD)
echo "$GC_INPUT" | bash "$HOOKS_DIR/bash-dedup.sh" 2>/dev/null || true  # re-acquire
GC_BG=$(jq -n --arg cmd 'git add -A && git commit -m "feat: test"' \
    '{"tool_name":"Bash","tool_input":{"command":$cmd,"run_in_background":true},"tool_response":{"output":null,"backgroundTaskId":"gcbg1","success":true}}')
set +e
echo "$GC_BG" | bash "$HOOKS_DIR/bash-dedup-post.sh" 2>/dev/null
set -e
TESTS_RUN=$((TESTS_RUN + 1))
if [[ -f "$DEDUP_LOCK_DIR/git-commit.lock" ]] \
    && [[ "$(sed -n '2p' "$DEDUP_LOCK_DIR/git-commit.lock")" == "running" ]]; then
    echo -e "${GREEN}✓${NC} bash-dedup-post: background git commit promotes lock to running"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "${RED}✗${NC} bash-dedup-post: background git commit must promote lock to running"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi
rm -f "$DEDUP_LOCK_DIR/git-commit.lock"

# Pattern-table parity: every lock key the dedup guard (wv-pre-tool-use.sh) classifies must also
# appear in the release guard (wv-post-tool-use.sh), or its lock is never cleared/promoted.
TESTS_RUN=$((TESTS_RUN + 1))
PRE_KEYS=$(grep -oP 'LOCK_KEY="\K[a-z-]+' "$PROJECT_ROOT/scripts/lib/wv-pre-tool-use.sh" | sort -u)
POST_KEYS=$(grep -oP '^[[:space:]]*_handle_lock "\K[a-z-]+' "$PROJECT_ROOT/scripts/lib/wv-post-tool-use.sh" | sort -u)
MISSING_KEYS=$(comm -23 <(echo "$PRE_KEYS") <(echo "$POST_KEYS"))
if [[ -z "$MISSING_KEYS" ]]; then
    echo -e "${GREEN}✓${NC} bash-dedup: pre/post lock-key tables are in sync"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "${RED}✗${NC} bash-dedup: lock keys missing from bash-dedup-post.sh: $(echo "$MISSING_KEYS" | tr '\n' ' ')"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ── Poller guard: deny busy-wait loops only while a background task is live ──────
# A running lock with empty task-id (line 4) and a recent epoch reads as live via
# the age-window fallback — no fuser-held file needed in the test.
rm -f "$DEDUP_LOCK_DIR"/*.lock
POLLER_CMD='until grep -q done /tmp/somelog; do sleep 3; done'

# (a) No background task in flight → poller allowed (no deny).
set +e
OUTPUT=$(echo "$(jq -n --arg c "$POLLER_CMD" '{"tool_name":"Bash","tool_input":{"command":$c}}')" \
    | bash "$HOOKS_DIR/bash-dedup.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "bash-dedup poller: idle poller exits 0"
assert_not_contains "$OUTPUT" '"deny"' "bash-dedup poller: poller allowed when nothing is in flight"

# (b) A live running bg lock present → poller denied with yield guidance.
printf '%s\nrunning\nmake check\n\n' "$(date +%s)" > "$DEDUP_LOCK_DIR/make-build.lock"
set +e
OUTPUT=$(echo "$(jq -n --arg c "$POLLER_CMD" '{"tool_name":"Bash","tool_input":{"command":$c}}')" \
    | bash "$HOOKS_DIR/bash-dedup.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "bash-dedup poller: deny is a soft (exit 0) JSON decision"
assert_contains "$OUTPUT" '"deny"' "bash-dedup poller: poller denied while bg task is live"
assert_contains "$OUTPUT" 'task-notification' "bash-dedup poller: deny message tells the agent to yield"

# (c) Quoted prose containing until/sleep must NOT be treated as a poller, even
# with a live bg lock present (CMD_STRIPPED removes the quoted region).
PROSE_CMD='wv done wv-abc1 --learning="loop until the job is done, then sleep on it"'
set +e
OUTPUT=$(echo "$(jq -n --arg c "$PROSE_CMD" '{"tool_name":"Bash","tool_input":{"command":$c}}')" \
    | bash "$HOOKS_DIR/bash-dedup.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "bash-dedup poller: quoted until/sleep prose exits 0"
assert_not_contains "$OUTPUT" '"deny"' "bash-dedup poller: quoted until/sleep prose is not a poller"

# (d) A stale running lock (old epoch, no task id) must NOT keep denying pollers.
printf '%s\nrunning\nmake check\n\n' "$(( $(date +%s) - 700 ))" > "$DEDUP_LOCK_DIR/make-build.lock"
set +e
OUTPUT=$(echo "$(jq -n --arg c "$POLLER_CMD" '{"tool_name":"Bash","tool_input":{"command":$c}}')" \
    | bash "$HOOKS_DIR/bash-dedup.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "bash-dedup poller: stale lock exits 0"
assert_not_contains "$OUTPUT" '"deny"' "bash-dedup poller: poller allowed once bg lock is stale"
rm -f "$DEDUP_LOCK_DIR"/*.lock

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

# Regression: tool_response.success=false must short-circuit (jq '.x // true'
# previously collapsed explicit boolean false to true). Write a syntactically
# broken Python file; if the success=false guard is honored, ruff is never
# invoked and no additionalContext is emitted.
echo 'def broken(' > "$TEST_DIR/project/broken.py"
set +e
OUTPUT=$(echo "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$TEST_DIR/project/broken.py\"},\"tool_response\":{\"success\":false}}" \
    | bash "$HOOKS_DIR/post-edit-lint.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "post-edit-lint: exits 0 when tool reported failure"
TESTS_RUN=$((TESTS_RUN + 1))
if [[ -z "$OUTPUT" ]]; then
    echo -e "${GREEN}✓${NC} post-edit-lint: emits nothing when tool_response.success=false"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "${RED}✗${NC} post-edit-lint: should skip lint on tool failure (got: $OUTPUT)"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# The install nudge is an advisory, so it must reach the agent: both hosts read
# PostToolUse context only from hookSpecificOutput.additionalContext (wv-09aa6f).
OUTPUT=$(jq -cn --arg p "$PROJECT_ROOT/scripts/wv" '{tool_name:"Edit",tool_input:{file_path:$p},tool_response:{success:true}}' \
    | (cd "$PROJECT_ROOT" && bash "$HOOKS_DIR/post-edit-lint.sh") 2>/dev/null || true)
assert_contains "$(jq -r '.hookSpecificOutput.additionalContext // empty' <<<"$OUTPUT" 2>/dev/null)" "Edited installed source" \
    "post-edit-lint: the install nudge is hookSpecificOutput.additionalContext"

# Regression (wv-5af710): prettier reflowed the generated workflow-classes block
# in templates/WORKFLOW.md after a prose edit elsewhere in the file, so
# gen-workflow-classes.sh --check failed and make check went red. Edit prose in
# a copy of the real doc, run the hook, then run the generator's own check.
if command -v prettier >/dev/null 2>&1; then
    _pel_repo="$TEST_DIR/project"
    mkdir -p "$_pel_repo/templates" "$_pel_repo/scripts/lib"
    # .prettierrc is dev formatter config and does not ship; the public
    # projection's aggregate aborted here under set -e. The reflow this case
    # guards needs only the markdown wrap settings, so seed those when absent.
    if [ -f "$PROJECT_ROOT/.prettierrc" ]; then
        cp "$PROJECT_ROOT/.prettierrc" "$_pel_repo/"
    else
        printf '%s\n' '{"proseWrap":"always","overrides":[{"files":"*.md","options":{"proseWrap":"always","printWidth":100}}]}' \
            > "$_pel_repo/.prettierrc"
    fi
    cp "$PROJECT_ROOT/scripts/gen-workflow-classes.sh" "$_pel_repo/scripts/"
    cp "$PROJECT_ROOT/scripts/lib/wv-workflow-classes.gen.sh" "$_pel_repo/scripts/lib/"
    cp "$PROJECT_ROOT/templates/workflow-classes.conf" "$PROJECT_ROOT/templates/WORKFLOW.md" "$_pel_repo/templates/"
    _pel_doc="$_pel_repo/templates/WORKFLOW.md"
    _pel_region() { sed -n '/^<!-- BEGIN GENERATED/,/^<!-- END GENERATED/p' "$1"; }
    _pel_before=$(_pel_region "$_pel_doc")
    assert_equals "0" "$(bash "$_pel_repo/scripts/gen-workflow-classes.sh" --check >/dev/null 2>&1; echo $?)" \
        "post-edit-lint: the copied WORKFLOW.md projection starts current"
    # A prose paragraph far past printWidth: prettier must wrap it, which proves
    # the formatter ran rather than being skipped.
    _pel_long="Prose edit outside the generated block$(printf ' word%.0s' $(seq 1 40))."
    printf '\n%s\n' "$_pel_long" >> "$_pel_doc"
    set +e
    echo "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$_pel_doc\"}}" \
        | (cd "$_pel_repo" && bash "$HOOKS_DIR/post-edit-lint.sh") >/dev/null 2>&1
    EXIT_CODE=$?
    set -e
    assert_exit_code "0" "$EXIT_CODE" "post-edit-lint: exits 0 formatting WORKFLOW.md"
    assert_equals "absent" "$(grep -qxF -- "$_pel_long" "$_pel_doc" && echo present || echo absent)" \
        "post-edit-lint: prettier reformatted the edited prose"
    assert_equals "$_pel_before" "$(_pel_region "$_pel_doc")" \
        "post-edit-lint: the generated region is byte-identical after formatting"
    assert_equals "0" "$(bash "$_pel_repo/scripts/gen-workflow-classes.sh" --check >/dev/null 2>&1; echo $?)" \
        "post-edit-lint: gen-workflow-classes.sh --check stays green after a prose edit"
    # The same for every managed-block marker family (wv-89e3dd): an edit to
    # CLAUDE.md reflowed its '<!-- ── BEGIN WEAVE' blocks, which the commit gate
    # then refused as projection drift. A consumer's CLAUDE.md carries two of
    # them. The fixture takes the init-repo block from this checkout's CLAUDE.md
    # and writes the WEAVE:MEMORY block in `wv memory render`'s shape, because
    # the public CLAUDE.md has no memory block (memories never ship, wv-ab5f6c)
    # and copying the whole file failed the release projection (wv-a1fc6e). The
    # memory block keeps what prettier would change: no blank line after the
    # heading and index lines past printWidth.
    _pel_claude="$_pel_repo/CLAUDE.md"
    _pel_managed() { sed -n "/^<!-- ── BEGIN WEAVE$2/,/^<!-- ── END WEAVE$2/p" "$1"; }
    {
        _pel_managed "$PROJECT_ROOT/CLAUDE.md" ' CLAUDE.MD'
        printf '\n# Project\n\nProject notes outside every managed block.\n\n'
        printf '%s\n' \
            '<!-- ── BEGIN WEAVE:MEMORY ── managed by wv memory render, do not edit manually -->' \
            '## WEAVE:MEMORY' \
            '' \
            'Authority: weave graph. Recall: `wv memory recall --agent=all --json`. Capture: `wv remember <text>`.' \
            '' \
            "- [\`wv-000001\`] A fixture memory index entry long enough to pass printWidth$(printf ' word%.0s' $(seq 1 25)) (verified: 2026-11-01T00:00:00Z)" \
            "- [\`wv-000002\`] A second entry, so the block holds a list prettier would rewrap$(printf ' word%.0s' $(seq 1 25)) (verified: 2026-11-01T00:00:00Z)" \
            '' \
            '<!-- ── END WEAVE:MEMORY ── -->'
    } > "$_pel_claude"
    _pel_init=$(_pel_managed "$_pel_claude" ' CLAUDE.MD')
    _pel_memory=$(_pel_managed "$_pel_claude" ':MEMORY')
    assert_equals "yes" "$([ -n "$_pel_init" ] && [ -n "$_pel_memory" ] && echo yes || echo no)" \
        "post-edit-lint: the CLAUDE.md fixture carries both managed blocks"
    printf '\n%s\n' "$_pel_long" >> "$_pel_claude"
    set +e
    echo "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$_pel_claude\"}}" \
        | (cd "$_pel_repo" && bash "$HOOKS_DIR/post-edit-lint.sh") >/dev/null 2>&1
    set -e
    assert_equals "absent" "$(grep -qxF -- "$_pel_long" "$_pel_claude" && echo present || echo absent)" \
        "post-edit-lint: prettier reformatted the prose appended to CLAUDE.md"
    assert_equals "$_pel_init" "$(_pel_managed "$_pel_claude" ' CLAUDE.MD')" \
        "post-edit-lint: CLAUDE.md's init-repo block is byte-identical after formatting"
    assert_equals "$_pel_memory" "$(_pel_managed "$_pel_claude" ':MEMORY')" \
        "post-edit-lint: CLAUDE.md's WEAVE:MEMORY block is byte-identical after formatting"
    unset -f _pel_region _pel_managed
else
    echo -e "${YELLOW}⊘${NC} post-edit-lint: prettier not installed, generated-region test skipped"
fi

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
_FAKE_REMOTE=$(mktemp -d "$TEST_DIR/fake-remote.XXXXXX")
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
STDERR_TMP=$(mktemp)
OUTPUT=$(echo '{}' | bash "$HOOKS_DIR/stop-check.sh" 2>"$STDERR_TMP")
EXIT_CODE=$?
STDERR_OUT=$(cat "$STDERR_TMP"); rm -f "$STDERR_TMP"
set -e
assert_exit_code "0" "$EXIT_CODE" "stop-check: exits 0 (soft warn) with unpushed commits"
assert_contains "$STDERR_OUT" "unpushed" "stop-check: warns about unpushed commits on stderr"

# --- stop-check.sh: cross-agent active-node scoping (wv-86ea58) ---
# Sandboxed Claude Code and Codex/Copilot/MCP sessions on the same repo can share
# one hot zone. An active node claimed by a DIFFERENT agent must not hard-block
# THIS session's stop-check; an active node claimed by THIS agent still must.
echo ""
echo "--- stop-check.sh (cross-agent active-node scoping) ---"
setup_test_env
git -C "$TEST_DIR/project" add -A 2>/dev/null
git -C "$TEST_DIR/project" commit -m "test setup" -q 2>/dev/null
rm -f "$(WV_PROJECT_DIR="$TEST_DIR/project" "$WV" hotzone --db 2>/dev/null | xargs dirname 2>/dev/null)/.stop_check_lock" 2>/dev/null || true

# Foreign agent's active node (e.g. copilot/MCP identity) — must NOT block.
WV_AGENT_ID="copilot-other-session" "$WV" add "foreign agent active node" --status=active --force \
    --criteria="c1" --risks=low >/dev/null 2>&1

set +e
OUTPUT=$(echo '{}' | bash "$HOOKS_DIR/stop-check.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "stop-check: does not hard-block on a different agent's active node"

# This session's OWN active node — must still hard-block.
add_active_node "own agent active node" >/dev/null 2>&1

set +e
OUTPUT=$(echo '{}' | bash "$HOOKS_DIR/stop-check.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
# The block is the JSON with exit 0: Codex reads exit 1 as a failed hook and
# plain text as invalid Stop output (wv-25903d, wv-5b774a).
assert_exit_code "0" "$EXIT_CODE" "stop-check: hard-blocks on this session's own active node"
assert_equals "block" "$(printf '%s' "$OUTPUT" | jq -r '.decision' 2>/dev/null)" \
    "stop-check: emits block decision JSON for own active node"

# A dirty tree must not skip the block (wv-fd81b5): the soft warnings used to
# exit before the active-node check, so in-flight work could end the session.
rm -f "$(WV_PROJECT_DIR="$TEST_DIR/project" "$WV" hotzone --db 2>/dev/null | xargs dirname 2>/dev/null)/.stop_check_lock" 2>/dev/null || true
echo "mid-edit" > "$TEST_DIR/project/mid-edit.txt"
set +e
STDERR_TMP=$(mktemp)
OUTPUT=$(echo '{}' | bash "$HOOKS_DIR/stop-check.sh" 2>"$STDERR_TMP")
EXIT_CODE=$?
STDERR_OUT=$(cat "$STDERR_TMP"); rm -f "$STDERR_TMP"
set -e
assert_exit_code "0" "$EXIT_CODE" "stop-check: exits 0 with an active node and a dirty tree"
assert_equals "block" "$(printf '%s' "$OUTPUT" | jq -r '.decision' 2>/dev/null)" \
    "stop-check: blocks on its own active node even with uncommitted changes"
# Inside the cooldown the second stop is allowed and the soft warning still runs.
set +e
STDERR_OUT=$(echo '{}' | bash "$HOOKS_DIR/stop-check.sh" 2>&1 1>/dev/null)
OUTPUT=$(echo '{}' | bash "$HOOKS_DIR/stop-check.sh" 2>/dev/null)
set -e
assert_equals "" "$OUTPUT" "stop-check: a second stop inside the cooldown is not blocked"
assert_contains "$STDERR_OUT" "uncommitted" "stop-check: the cooldown stop still warns about uncommitted changes"
rm -f "$TEST_DIR/project/mid-edit.txt"

# --- stop-check.sh: an open node waiting on visible background work (wv-e229c8) ---
# A node held open while its own gate or push runs is not abandoned work: the
# stop is allowed with a note naming the process, and no cooldown is armed, so
# a long wait never turns into a block on every turn. Nothing in flight, or
# another owner's gate, still blocks.
echo ""
echo "--- stop-check.sh (in-flight gate or push) ---"
SC_LOCK="$(WV_PROJECT_DIR="$TEST_DIR/project" "$WV" hotzone --db 2>/dev/null | xargs dirname 2>/dev/null)/.stop_check_lock"
SC_HOLDER="$TEST_DIR/project/$(git -C "$TEST_DIR/project" rev-parse --git-path weave-gate.holder.json)"
HOLD_LIB="$PROJECT_ROOT/scripts/lib/wv-gate-hold.sh"
# start_holder <agent id>: a gate holding this checkout's lock, as the hooks take it.
start_holder() {
    rm -f "$SC_HOLDER"
    WV_AGENT_ID="$1" bash -c 'cd "$2" && . "$1" && wv_gate_hold_acquire pre-commit "test gate" && exec sleep 60' \
        _ "$HOLD_LIB" "$TEST_DIR/project" &
    HOLD_PID=$!
    for _ in $(seq 50); do [ -s "$SC_HOLDER" ] && break; sleep 0.1; done
}
stop_holder() { kill "$HOLD_PID" 2>/dev/null; wait "$HOLD_PID" 2>/dev/null || true; rm -f "$SC_HOLDER"; }

# run_stop: one stop from a clean cooldown; stdout in OUTPUT, stderr in STDERR_OUT.
run_stop() {
    local err
    rm -f "$SC_LOCK"
    err=$(mktemp)
    set +e
    OUTPUT=$(echo '{}' | bash "$HOOKS_DIR/stop-check.sh" 2>"$err")
    set -e
    STDERR_OUT=$(cat "$err"); rm -f "$err"
}

start_holder "$WV_AGENT_ID"
run_stop
assert_equals "" "$OUTPUT" "stop-check: an open node waiting on its own live gate is not blocked"
assert_contains "$STDERR_OUT" "pre-commit gate pid $HOLD_PID" "stop-check: the allowed stop names the gate process"
assert_equals "absent" "$([ -e "$SC_LOCK" ] && echo present || echo absent)" \
    "stop-check: waiting on a live gate arms no cooldown"
stop_holder

start_holder "another-owner-agent"
run_stop
assert_equals "block" "$(printf '%s' "$OUTPUT" | jq -r '.decision' 2>/dev/null)" \
    "stop-check: another owner's gate does not excuse this session's open node"
stop_holder

run_stop
assert_equals "block" "$(printf '%s' "$OUTPUT" | jq -r '.decision' 2>/dev/null)" \
    "stop-check: an open node with nothing in flight still blocks"

# A push whose gate has finished but which is still talking to its remote holds
# no gate lock; the running git push for this checkout is what the node waits on.
SLOW_REMOTE="$TEST_DIR/slow-remote.git"
git init -q --bare "$SLOW_REMOTE"
printf '#!/bin/sh\necho $$ > hook.pid\nexec sleep 60\n' > "$SLOW_REMOTE/hooks/pre-receive"
chmod +x "$SLOW_REMOTE/hooks/pre-receive"
git -C "$TEST_DIR/project" -c core.hooksPath=/dev/null push -q "$SLOW_REMOTE" HEAD:refs/heads/slow >/dev/null 2>&1 &
PUSH_PID=$!
for _ in $(seq 50); do [ -s "$SLOW_REMOTE/hook.pid" ] && break; sleep 0.1; done
run_stop
assert_equals "" "$OUTPUT" "stop-check: an open node waiting on a running git push is not blocked"
assert_contains "$STDERR_OUT" "git pid $PUSH_PID" "stop-check: the allowed stop names the git push"
kill "$(cat "$SLOW_REMOTE/hook.pid" 2>/dev/null)" "$PUSH_PID" 2>/dev/null || true
wait "$PUSH_PID" 2>/dev/null || true
rm -f "$SC_LOCK"

# --- stop-check.sh: a guard that cannot load does not pass silently (wv-c7d114) ---
# A copy of the hook with no loadable lib anywhere it looks: the nearest copy is
# half-installed (defines no wv_stop_guard), the repo and HOME copies are absent.
echo ""
echo "--- stop-check.sh (guard cannot load) ---"
_sc_broken="$TEST_DIR/broken-guard"
mkdir -p "$_sc_broken/hooks" "$_sc_broken/lib" "$_sc_broken/home"
cp "$HOOKS_DIR/stop-check.sh" "$_sc_broken/hooks/stop-check.sh"
echo ': half-installed' > "$_sc_broken/lib/wv-lifecycle-end.sh"
set +e
STDERR_TMP=$(mktemp)
OUTPUT=$(echo '{}' | HOME="$_sc_broken/home" bash "$_sc_broken/hooks/stop-check.sh" 2>"$STDERR_TMP")
EXIT_CODE=$?
STDERR_OUT=$(cat "$STDERR_TMP"); rm -f "$STDERR_TMP"
set -e
assert_exit_code "0" "$EXIT_CODE" "stop-check: an unloadable guard still exits 0 (Stop blocks are JSON)"
assert_equals "block" "$(printf '%s' "$OUTPUT" | jq -r '.decision' 2>/dev/null)" \
    "stop-check: an unloadable guard blocks the first stop instead of passing silently"
assert_contains "$STDERR_OUT" "could not be loaded" "stop-check: an unloadable guard warns on stderr"
set +e
STDERR_TMP=$(mktemp)
OUTPUT=$(echo '{"stop_hook_active": true}' | HOME="$_sc_broken/home" bash "$_sc_broken/hooks/stop-check.sh" 2>"$STDERR_TMP")
EXIT_CODE=$?
STDERR_OUT=$(cat "$STDERR_TMP"); rm -f "$STDERR_TMP"
set -e
assert_exit_code "0" "$EXIT_CODE" "stop-check: the retry after an unloadable-guard block exits 0"
assert_equals "" "$OUTPUT" "stop-check: the retry is allowed, so a broken install cannot trap a session"
assert_contains "$STDERR_OUT" "could not be loaded" "stop-check: the allowed retry still warns on stderr"

# --- session-end-sync.sh ---
echo ""
echo "--- session-end-sync.sh ---"
setup_test_env

set +e
OUTPUT=$(echo '{"reason":"user_exit"}' | bash "$HOOKS_DIR/session-end-sync.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "session-end: exits 0"

setup_uninitialized_project
set +e
OUTPUT=$(echo '{"reason":"user_exit"}' | bash "$HOOKS_DIR/session-end-sync.sh" 2>&1)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "session-end: exits 0 in uninitialized repo"
assert_equals "absent" "$(if [ -d "$TEST_DIR/project/.weave" ]; then echo present; else echo absent; fi)" "session-end: does not create .weave in uninitialized repo"

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

# Verify session-end runs only its local steps (a local sync, the
# checkpoint commit through WV_AUTO_CHECKPOINT_ACTIVE rather than a blanket
# --no-verify bypass): no GitHub sync and no push, which the host cut off at
# exit and left a half-finished journal behind (wv-a32e69).
setup_test_env
SPY_HOME="$TEST_DIR/home"
mkdir -p "$SPY_HOME/.local/bin"
WV_LOG="$TEST_DIR/wv-calls.log"
# The spy records WV_CHECKPOINT_PULL too: session end must not pull (wv-a32e69).
cat > "$SPY_HOME/.local/bin/wv" <<EOF
#!/bin/sh
echo "pull=\${WV_CHECKPOINT_PULL:-unset} \$*" >> "$WV_LOG"
exit 0
EOF
chmod +x "$SPY_HOME/.local/bin/wv"

# Force the commit path and require the automation env var in pre-commit.
# Remove the source-repo symlink so the hook falls back to HOME/.local/bin/wv.
# That fallback belongs to an INSTALLED hook only: one run from this checkout
# pairs with the checkout's scripts/wv (wv-706439), so running $HOOKS_DIR here
# executed the real CLI, never the spy, and the log was never written
# (wv-5fd0b5). Run the hook from an installed layout under the spy HOME, whose
# resolver has no sibling wv.
rm -f "$TEST_DIR/project/scripts/wv"
SPY_WEAVE="$SPY_HOME/.config/weave"
mkdir -p "$SPY_WEAVE/hooks" "$SPY_WEAVE/lib"
cp "$HOOKS_DIR/session-end-sync.sh" "$SPY_WEAVE/hooks/"
cp "$PROJECT_ROOT"/scripts/lib/*.sh "$SPY_WEAVE/lib/"
echo "checkpoint" >> "$TEST_DIR/project/.weave/breadcrumbs.md"
cat > "$TEST_DIR/project/.git/hooks/pre-commit" <<'EOF'
#!/bin/sh
[ "${WV_AUTO_CHECKPOINT_ACTIVE:-0}" = "1" ] && exit 0
echo "missing WV_AUTO_CHECKPOINT_ACTIVE" >&2
exit 1
EOF
chmod +x "$TEST_DIR/project/.git/hooks/pre-commit"
# A remote it could push to, so "pushes nothing" is observed, not assumed.
SPY_REMOTE="$TEST_DIR/spy-remote.git"
git init -q --bare "$SPY_REMOTE"
git -C "$TEST_DIR/project" remote add origin "$SPY_REMOTE" 2>/dev/null \
    || git -C "$TEST_DIR/project" remote set-url origin "$SPY_REMOTE"
# Name the branch main with origin/main upstream, so a bare `git push` would
# succeed: otherwise push.default=simple refuses it and "pushes nothing" passes
# whatever the routine does.
git -C "$TEST_DIR/project" branch -q -M main
git -C "$TEST_DIR/project" push -q -u origin main 2>/dev/null
SPY_REMOTE_BEFORE=$(git -C "$SPY_REMOTE" rev-parse main 2>/dev/null)

set +e
OUTPUT=$(HOME="$SPY_HOME" CLAUDE_PROJECT_DIR="$TEST_DIR/project" \
    bash "$SPY_WEAVE/hooks/session-end-sync.sh" <<< '{"reason":"stubbed_session_end"}' 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "session-end: exits 0 with a stub wv + automation pre-commit"
WV_CALLS=$(cat "$WV_LOG" 2>/dev/null || echo "<spy never invoked>")
# Prune is an explicit command only (owner ruling 2026-11-09, wv-68c882).
assert_not_contains "$WV_CALLS" "prune" "session-end: does not prune"
assert_contains "$WV_CALLS" "pull=0 sync" "session-end: flushes state.sql with a local wv sync that does not pull"
assert_not_contains "$WV_CALLS" "--gh" "session-end: runs no GitHub sync"
assert_equals "$SPY_REMOTE_BEFORE" "$(git -C "$SPY_REMOTE" rev-parse main 2>/dev/null)" \
    "session-end: pushes nothing"
LAST_MSG=$(git -C "$TEST_DIR/project" log -1 --pretty=%s 2>/dev/null || true)
assert_contains "$LAST_MSG" "auto-checkpoint" "session-end: auto-checkpoint commit succeeds without blanket bypass"

# --- repo-managed git hooks ---
echo ""
echo "--- repo-managed git hooks ---"

# Installation is now explicit; test-precommit-selfheal-isolation.sh drives
# real hook callers and verifies that no installer runs (wv-801b89).

setup_test_env
mkdir -p "$TEST_DIR/project/tests"
FRESH_SUITE_RUNS="$TEST_DIR/fresh-suite-runs"
cat > "$TEST_DIR/project/tests/test-graph.sh" <<EOF
#!/bin/sh
echo run >> "$FRESH_SUITE_RUNS"
exit 0
EOF
chmod +x "$TEST_DIR/project/tests/test-graph.sh"
git -C "$TEST_DIR/project" add tests/test-graph.sh
add_active_node "Git hook progress task" --criteria="hook prints progress|smoke repo stays green" --risks=low >/dev/null 2>&1
set +e
OUTPUT=$(cd "$TEST_DIR/project" && bash "$PROJECT_ROOT/scripts/hooks/pre-commit-weave.sh" 2>&1)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "git pre-commit: exits 0 with active node and passing shell smoke"
assert_contains "$OUTPUT" "running tests/test-graph.sh" "git pre-commit: streams shell-test progress"
assert_contains "$OUTPUT" "checking for an active Weave claim held by this actor" "git pre-commit: streams active-node check"
assert_equals "1" "$(wc -l < "$FRESH_SUITE_RUNS" | tr -d ' ')" \
    "git pre-commit: first unknown result executes the real suite"

# This fixture is a consumer: even identical staged bytes must rerun because
# checkout tools can change. Frozen reuse is covered by test-gate-input-reuse.sh.
set +e
OUTPUT=$(cd "$TEST_DIR/project" && bash "$PROJECT_ROOT/scripts/hooks/pre-commit-weave.sh" 2>&1)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "git pre-commit: fresh green result exits 0"
assert_contains "$OUTPUT" "checkout inputs are mutable: reuse disabled" \
    "git pre-commit: explains why consumer results cannot be reused"
assert_equals "2" "$(wc -l < "$FRESH_SUITE_RUNS" | tr -d ' ')" \
    "git pre-commit: fresh green consumer result still executes the suite again"

# Staged-byte changes also execute the suite.
printf '# changed\n' >> "$TEST_DIR/project/tests/test-graph.sh"
git -C "$TEST_DIR/project" add tests/test-graph.sh
set +e
OUTPUT=$(cd "$TEST_DIR/project" && bash "$PROJECT_ROOT/scripts/hooks/pre-commit-weave.sh" 2>&1)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "git pre-commit: stale result reruns and passes"
assert_contains "$OUTPUT" "running tests/test-graph.sh" \
    "git pre-commit: stale result falls through to real suite execution"
assert_equals "3" "$(wc -l < "$FRESH_SUITE_RUNS" | tr -d ' ')" \
    "git pre-commit: stale staged bytes execute the suite exactly once"

# wv-5da0e8: a routed file edited while its suite runs. The result describes the
# content the suite started on, so staging the edited file and committing again
# must run the suite, not reuse a row fingerprinted after the edit.
setup_test_env
mkdir -p "$TEST_DIR/project/tests" "$TEST_DIR/project/src"
MIDRUN_RUNS="$TEST_DIR/midrun-runs"
cat > "$TEST_DIR/project/tests/test-mid.sh" <<EOF
#!/bin/sh
echo run >> "$MIDRUN_RUNS"
[ "\$(wc -l < "$MIDRUN_RUNS")" -eq 1 ] && echo '# edited mid-run' >> "$TEST_DIR/project/src/app.sh"
exit 0
EOF
chmod +x "$TEST_DIR/project/tests/test-mid.sh"
git -C "$TEST_DIR/project" add tests/test-mid.sh
git -C "$TEST_DIR/project" -c core.hooksPath=/dev/null commit -q -m "mid-run suite"
printf '[map]\nsrc/app.sh = tests/test-mid.sh\n' > "$TEST_DIR/project/.weave/test-map.conf"
# The gate routes by the map git holds (F5, wv-fe8007), so HEAD carries it.
git -C "$TEST_DIR/project" add -f .weave/test-map.conf
git -C "$TEST_DIR/project" -c core.hooksPath=/dev/null commit -q --allow-empty -m "route the suites"
printf '#!/bin/sh\necho start\n' > "$TEST_DIR/project/src/app.sh"
git -C "$TEST_DIR/project" add src/app.sh
add_active_node "Mid-run edit task" --criteria="edited file is not certified|next gate reruns" --risks=low >/dev/null 2>&1
set +e
OUTPUT=$(cd "$TEST_DIR/project" && bash "$PROJECT_ROOT/scripts/hooks/pre-commit-weave.sh" 2>&1)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "git pre-commit: the mid-run suite passes"
assert_contains "$(cat "$TEST_DIR/project/src/app.sh")" "edited mid-run" \
    "git pre-commit: the suite really edited the routed file during its run"
git -C "$TEST_DIR/project" add src/app.sh
set +e
OUTPUT=$(cd "$TEST_DIR/project" && bash "$PROJECT_ROOT/scripts/hooks/pre-commit-weave.sh" 2>&1)
EXIT_CODE=$?
set -e
assert_not_contains "$OUTPUT" "reusing fresh green result for tests/test-mid.sh" \
    "git pre-commit: content edited mid-run is not reused as tested"
assert_equals "2" "$(wc -l < "$MIDRUN_RUNS" | tr -d ' ')" \
    "git pre-commit: content edited mid-run runs the suite again"

setup_test_env
mkdir -p "$TEST_DIR/project/scripts/hooks" "$TEST_DIR/project/tests"
cat > "$TEST_DIR/project/scripts/hooks/local-hook.sh" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$TEST_DIR/project/tests/test-hooks.sh" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$TEST_DIR/project/scripts/hooks/local-hook.sh" "$TEST_DIR/project/tests/test-hooks.sh"
git -C "$TEST_DIR/project" add scripts/hooks/local-hook.sh tests/test-hooks.sh
add_active_node "Git hook impact-selected task" --criteria="impact suite mapping works|test-core.sh excluded from pre-commit" --risks=low >/dev/null 2>&1
set +e
OUTPUT=$(cd "$TEST_DIR/project" && bash "$PROJECT_ROOT/scripts/hooks/pre-commit-weave.sh" 2>&1)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "git pre-commit: exits 0 with impact-selected suite mapping"
assert_contains "$OUTPUT" "impact-selected shell suites" "git pre-commit: reports impact-selected suite list"
assert_contains "$OUTPUT" "tests/test-hooks.sh" "git pre-commit: selects tests/test-hooks.sh for hook file changes"
QUEUE_FILE="$TEST_DIR/project/.git/.weave-deferred-suites"
assert_equals "absent" "$(if [ -f "$QUEUE_FILE" ]; then echo present; else echo absent; fi)" "git pre-commit: no deferred queue written (test-core.sh excluded from pre-commit)"

# wv-8138ec: the selected suites run as a bounded pool. Two planted suites
# rendezvous — each writes its marker and waits for the other's — so they pass
# only when they genuinely overlap; run one after the other, the first times
# out. $2/$3 are each suite's exit code after the rendezvous; a suite that
# fails prints a line the replay must carry.
_pool_setup() {
    setup_test_env
    mkdir -p "$TEST_DIR/project/tests" "$TEST_DIR/project/src"
    POOL_DIR="$TEST_DIR/pool"
    mkdir -p "$POOL_DIR"
    for _pool_s in a b; do
        _pool_o=$([ "$_pool_s" = a ] && echo b || echo a)
        _pool_rc=$([ "$_pool_s" = a ] && echo "$2" || echo "$3")
        cat > "$TEST_DIR/project/tests/test-p$_pool_s.sh" <<EOF
#!/bin/sh
touch "$POOL_DIR/$_pool_s"
echo "\${WV_GATE_LANE_JOBS-unset}" > "$POOL_DIR/$_pool_s.lanejobs"
n=0
while [ ! -f "$POOL_DIR/$_pool_o" ] && [ \$n -lt ${POOL_WAIT:-100} ]; do sleep 0.1; n=\$((n + 1)); done
[ -f "$POOL_DIR/$_pool_o" ] || { echo "✗ rendezvous timed out waiting for $_pool_o"; exit 3; }
[ "$_pool_rc" = 0 ] || echo "✗ planted assertion in p$_pool_s"
exit $_pool_rc
EOF
        chmod +x "$TEST_DIR/project/tests/test-p$_pool_s.sh"
    done
    git -C "$TEST_DIR/project" add tests/test-pa.sh tests/test-pb.sh
    git -C "$TEST_DIR/project" -c core.hooksPath=/dev/null commit -q -m "pool suites"
    printf '[map]\nsrc/app.sh = tests/test-pa.sh tests/test-pb.sh\n' > "$TEST_DIR/project/.weave/test-map.conf"
    # The gate routes by the map git holds (F5, wv-fe8007), so HEAD carries it.
    git -C "$TEST_DIR/project" add -f .weave/test-map.conf
    git -C "$TEST_DIR/project" -c core.hooksPath=/dev/null commit -q --allow-empty -m "route the suites"
    printf '#!/bin/sh\necho %s\n' "$1" > "$TEST_DIR/project/src/app.sh"
    git -C "$TEST_DIR/project" add src/app.sh
    add_active_node "Suite pool task" --criteria="pool runs suites|pool reports failures" --risks=low >/dev/null 2>&1
}
_pool_run() {
    set +e
    OUTPUT=$(cd "$TEST_DIR/project" && WV_GATE_JOBS="$1" bash "$PROJECT_ROOT/scripts/hooks/pre-commit-weave.sh" 2>&1)
    EXIT_CODE=$?
    set -e
}

_pool_setup pool-green 0 0
_pool_run 2
assert_exit_code "0" "$EXIT_CODE" "suite pool: two suites that must overlap both pass at WV_GATE_JOBS=2"
assert_contains "$OUTPUT" "running 2 suites, up to 2 at a time" "suite pool: announces the bound"
assert_contains "$OUTPUT" "passed tests/test-pa.sh" "suite pool: reports suite a as it finishes"
assert_contains "$OUTPUT" "passed tests/test-pb.sh" "suite pool: reports suite b as it finishes"

_pool_setup pool-red 1 0
_pool_run 2
assert_exit_code "1" "$EXIT_CODE" "suite pool: one failing suite fails the gate"
assert_contains "$OUTPUT" "✗ tests/test-pa.sh failed (exit 1)" "suite pool: the failure names its suite and exit code"
assert_contains "$OUTPUT" "planted assertion in pa" "suite pool: the failing suite's own output is replayed"
assert_contains "$OUTPUT" "full output: " "suite pool: the full captured output is kept on disk"
assert_not_contains "$OUTPUT" "✗ tests/test-pb.sh failed" "suite pool: the passing sibling is not reported as failed"

# wv-4666cb: each suite row carries when that suite started and exited, read by
# its worker, and the gate row when the gate started, so a failure's time is
# measured rather than taken from ts, which is written after the last suite.
# pb outlives the failing pa by 2s: a time taken at drain would give pa pb's end.
_pool_setup pool-times 1 0
sed -i 's/^exit 0$/sleep 2; exit 0/' "$TEST_DIR/project/tests/test-pb.sh"
git -C "$TEST_DIR/project" add tests/test-pb.sh
_pt_log="$TEST_DIR/times/suite_runs.jsonl"
mkdir -p "$TEST_DIR/times"
set +e
OUTPUT=$(cd "$TEST_DIR/project" && WV_SUITE_LOG="$_pt_log" WV_GATE_LOG='' WV_GATE_JOBS=2 \
    bash "$PROJECT_ROOT/scripts/hooks/pre-commit-weave.sh" 2>&1)
EXIT_CODE=$?
set -e
assert_exit_code "1" "$EXIT_CODE" "suite times: the planted failure fails the gate"
_pt_row() { jq -c --arg s "$1" 'select(.suite == $s)' "$_pt_log" 2>/dev/null | tail -1; }
_pt_a=$(_pt_row tests/test-pa.sh)
_pt_b=$(_pt_row tests/test-pb.sh)
_pt_g=$(tail -1 "$TEST_DIR/times/gate_runs.jsonl" 2>/dev/null)
assert_equals "true true" \
    "$(jq -r '((.started_ms|type) == "number" and (.ended_ms|type) == "number" and .ended_ms >= .started_ms
               and ((.ended_ms - .started_ms - .duration_ms) | fabs) <= 1000) | tostring' <<< "$_pt_a$_pt_b" | paste -sd ' ')" \
    "suite times: both suite rows carry a start and an exit that agree with their duration"
assert_equals "true" \
    "$(jq -nr --argjson a "${_pt_a:-null}" --argjson b "${_pt_b:-null}" '($b.ended_ms - $a.ended_ms) >= 1500 | tostring' 2>/dev/null)" \
    "suite times: the failing suite's exit is its own, not its longer sibling's"
assert_equals "true" \
    "$(jq -nr --argjson a "${_pt_a:-null}" --argjson b "${_pt_b:-null}" --argjson g "${_pt_g:-null}" '
        ($g.started_ms|type) == "number"
        and $g.started_ms <= ([$a.started_ms, $b.started_ms] | min)
        and ($g.started_ms + $g.duration_ms + 5) >= ([$a.ended_ms, $b.ended_ms] | max)
        and ($a.ended_ms - $g.started_ms) < $g.duration_ms | tostring' 2>/dev/null)" \
    "suite times: the gate row's start precedes its suites, so first-failure time is pa.ended_ms - gate.started_ms"

# wv-c909ff: a commit with no claim is refused before the pool, not after it.
# The same suites route as above; the setup's claim is returned to todo.
_pool_setup pool-noclaim 0 0
for _nc_id in $("$WV" list --status=active --json 2>/dev/null | jq -r '.[].id'); do
    "$WV" update "$_nc_id" --status=todo >/dev/null 2>&1
done
assert_equals "0" "$("$WV" list --status=active --json 2>/dev/null | jq 'length')" \
    "no claim: (precondition) no node is active"
_pool_run 2
assert_exit_code "1" "$EXIT_CODE" "no claim: the commit is refused"
assert_contains "$OUTPUT" "No active Weave node" "no claim: for the missing claim"
assert_contains "$OUTPUT" "active Weave claim held by this actor (before the suites)" \
    "no claim: by the check made before the suites"
assert_not_contains "$OUTPUT" "running 2 suites" "no claim: the pool never launches"
assert_equals "0" "$(find "$POOL_DIR" -type f ! -name '*.lanejobs' | wc -l | tr -d ' ')" \
    "no claim: no routed suite started"

# Serial bound: the rendezvous cannot complete, so whichever suite launches
# first fails, and the one queued behind it must not start once the gate has
# its verdict.
POOL_WAIT=5 _pool_setup pool-serial 0 0
_pool_run 1
assert_exit_code "1" "$EXIT_CODE" "suite pool: WV_GATE_JOBS=1 runs suites one at a time"
assert_contains "$OUTPUT" "rendezvous timed out waiting for" "suite pool: serial run replays the timeout line"
assert_contains "$OUTPUT" "not run after the failure: tests/test-p" "suite pool: no suite starts after a failure"
assert_equals "1" "$(find "$POOL_DIR" -type f ! -name '*.lanejobs' | wc -l | tr -d ' ')" \
    "suite pool: exactly one suite ran; the queued one really did not start"

# Keep going (wv-7df799, gate-preflight.sh --keep-going): the same serial run
# starts the queued suite after the first failure, and replays both failures.
# Both suites plant a failure: run serially, the first times out on the
# rendezvous, and the second (finding the first's marker) fails its assertion.
POOL_WAIT=5 _pool_setup pool-keep-going 1 1
set +e
OUTPUT=$(cd "$TEST_DIR/project" && WV_GATE_KEEP_GOING=1 WV_GATE_JOBS=1 \
    bash "$PROJECT_ROOT/scripts/hooks/pre-commit-weave.sh" 2>&1)
EXIT_CODE=$?
set -e
assert_exit_code "1" "$EXIT_CODE" "keep going: the gate still fails"
assert_not_contains "$OUTPUT" "not run after the failure" "keep going: no suite is skipped after a failure"
assert_equals "2" "$(find "$POOL_DIR" -type f ! -name '*.lanejobs' | wc -l | tr -d ' ')" \
    "keep going: both queued suites ran"
assert_contains "$OUTPUT" "✗ tests/test-pa.sh failed" "keep going: the first failure is replayed"
assert_contains "$OUTPUT" "✗ tests/test-pb.sh failed" "keep going: and the second, with its own entry"

# A candidate lane's share of the bound (wv-d7af8d): WV_GATE_LANE_JOBS wins
# over WV_GATE_JOBS, which config.env could set, and no suite inherits it.
POOL_WAIT=5 _pool_setup pool-lane-share 0 0
set +e
OUTPUT=$(cd "$TEST_DIR/project" && WV_GATE_JOBS=2 WV_GATE_LANE_JOBS=1 bash "$PROJECT_ROOT/scripts/hooks/pre-commit-weave.sh" 2>&1)
EXIT_CODE=$?
set -e
assert_exit_code "1" "$EXIT_CODE" "suite pool: a lane share of 1 runs suites one at a time though WV_GATE_JOBS=2"
assert_not_contains "$OUTPUT" "up to 2 at a time" "suite pool: the lane share, not WV_GATE_JOBS, is the bound"
_pool_setup pool-lane-share-2 0 0
set +e
OUTPUT=$(cd "$TEST_DIR/project" && WV_GATE_JOBS=1 WV_GATE_LANE_JOBS=2 bash "$PROJECT_ROOT/scripts/hooks/pre-commit-weave.sh" 2>&1)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "suite pool: a lane share of 2 lets the two suites overlap"
assert_contains "$OUTPUT" "running 2 suites, up to 2 at a time" "suite pool: announces the lane share as its bound"
assert_equals "unset unset" "$(cat "$POOL_DIR/a.lanejobs" "$POOL_DIR/b.lanejobs" 2>/dev/null | paste -sd ' ')" \
    "suite pool: no suite inherits the lane share"

# Consumer outcomes are history, not readiness. Recording still waits for the
# pool to drain: pa finishes at once; pb hashes the explicit history log, waits
# until pa has finished and the pool has had time to reap it, and hashes again.
setup_test_env
mkdir -p "$TEST_DIR/project/tests" "$TEST_DIR/project/src"
POOL_DIR="$TEST_DIR/pool"
mkdir -p "$POOL_DIR"
: > "$TEST_DIR/pool-suite-runs.jsonl"
printf '#!/bin/sh\ntouch "%s/a-done"\nexit 0\n' "$POOL_DIR" > "$TEST_DIR/project/tests/test-pa.sh"
cat > "$TEST_DIR/project/tests/test-pb.sh" <<EOF
#!/bin/sh
before=\$(cksum < "$TEST_DIR/pool-suite-runs.jsonl")
n=0
while [ ! -f "$POOL_DIR/a-done" ] && [ \$n -lt 100 ]; do sleep 0.1; n=\$((n + 1)); done
sleep 3
after=\$(cksum < "$TEST_DIR/pool-suite-runs.jsonl")
[ "\$before" = "\$after" ] || { echo "✗ checkout history changed while this suite ran"; exit 1; }
exit 0
EOF
chmod +x "$TEST_DIR/project/tests/test-pa.sh" "$TEST_DIR/project/tests/test-pb.sh"
git -C "$TEST_DIR/project" add tests/test-pa.sh tests/test-pb.sh
git -C "$TEST_DIR/project" -c core.hooksPath=/dev/null commit -q -m "pool quiet suites"
printf '[map]\nsrc/app.sh = tests/test-pa.sh tests/test-pb.sh\n' > "$TEST_DIR/project/.weave/test-map.conf"
# The gate routes by the map git holds (F5, wv-fe8007), so HEAD carries it.
git -C "$TEST_DIR/project" add -f .weave/test-map.conf
git -C "$TEST_DIR/project" -c core.hooksPath=/dev/null commit -q --allow-empty -m "route the suites"
printf '#!/bin/sh\necho quiet\n' > "$TEST_DIR/project/src/app.sh"
git -C "$TEST_DIR/project" add src/app.sh
add_active_node "Suite pool quiet task" --criteria="pool runs suites|pool writes no history row mid-run" --risks=low >/dev/null 2>&1
WV_SUITE_LOG="$TEST_DIR/pool-suite-runs.jsonl" _pool_run 2
assert_exit_code "0" "$EXIT_CODE" "suite pool: no history row is written while a sibling suite runs"
assert_not_contains "$OUTPUT" "checkout history changed" "suite pool: the reading suite saw unchanged history"
_pool_recorded() {
    jq -se --arg suite "$1" 'any(.[]; .suite == $suite and .execution_mode == "checkout" and .exit == 0)' \
        "$TEST_DIR/pool-suite-runs.jsonl" >/dev/null 2>&1 \
        && echo yes || echo no
}
assert_equals "yes yes" "$(_pool_recorded tests/test-pa.sh) $(_pool_recorded tests/test-pb.sh)" \
    "suite pool: both results are recorded once the pool drains"

# Interrupted gate (ultrareview #4575): a suite that already finished keeps its
# result; the one that was stopped records nothing. pa finishes at once, pb
# sleeps; the gate gets SIGTERM while pb still runs.
setup_test_env
mkdir -p "$TEST_DIR/project/tests" "$TEST_DIR/project/src"
POOL_DIR="$TEST_DIR/pool"
mkdir -p "$POOL_DIR"
printf '#!/bin/sh\ntouch "%s/a-done"\nexit 0\n' "$POOL_DIR" > "$TEST_DIR/project/tests/test-pa.sh"
printf '#!/bin/sh\nsleep 37\nexit 0\n' > "$TEST_DIR/project/tests/test-pb.sh"
chmod +x "$TEST_DIR/project/tests/test-pa.sh" "$TEST_DIR/project/tests/test-pb.sh"
git -C "$TEST_DIR/project" add tests/test-pa.sh tests/test-pb.sh
git -C "$TEST_DIR/project" -c core.hooksPath=/dev/null commit -q -m "pool interrupt suites"
printf '[map]\nsrc/app.sh = tests/test-pa.sh tests/test-pb.sh\n' > "$TEST_DIR/project/.weave/test-map.conf"
# The gate routes by the map git holds (F5, wv-fe8007), so HEAD carries it.
git -C "$TEST_DIR/project" add -f .weave/test-map.conf
git -C "$TEST_DIR/project" -c core.hooksPath=/dev/null commit -q --allow-empty -m "route the suites"
printf '#!/bin/sh\necho interrupt\n' > "$TEST_DIR/project/src/app.sh"
git -C "$TEST_DIR/project" add src/app.sh
add_active_node "Suite pool interrupt task" --criteria="pool records finished results|stopped suites record nothing" --risks=low >/dev/null 2>&1
( cd "$TEST_DIR/project" && WV_SUITE_LOG="$TEST_DIR/pool-suite-runs.jsonl" WV_GATE_JOBS=2 \
    exec bash "$PROJECT_ROOT/scripts/hooks/pre-commit-weave.sh" ) >/dev/null 2>&1 &
_pool_gate=$!
_pool_n=0
while [ ! -f "$POOL_DIR/a-done" ] && [ "$_pool_n" -lt 200 ]; do sleep 0.1; _pool_n=$((_pool_n + 1)); done
sleep 1
# Under set -e: the killed gate's status (130) must not end this suite.
kill -TERM "$_pool_gate" 2>/dev/null || true
wait "$_pool_gate" 2>/dev/null || true
assert_equals "yes no" "$(_pool_recorded tests/test-pa.sh) $(_pool_recorded tests/test-pb.sh)" \
    "suite pool: an interrupted gate records the finished suite and not the stopped one"
sleep 0.5
# Anchored: an unanchored -f pattern also matches any shell whose command line
# merely contains the text (the one running this suite, for instance).
assert_equals "0" "$(pgrep -fc '^sleep 37$' 2>/dev/null || true)" \
    "suite pool: an interrupted gate leaves none of the stopped suite's processes running"

# Git runs the hook with GIT_INDEX_FILE set (a temporary index for
# 'git commit -- <paths>'); a suite must not inherit it, or git in the suite's
# own temp repository writes into this commit's index (wv-34ef3d).
setup_test_env
mkdir -p "$TEST_DIR/project/tests" "$TEST_DIR/project/src"
cat > "$TEST_DIR/project/tests/test-pa.sh" <<'EOF'
#!/bin/sh
for v in GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_PREFIX; do
    eval "val=\${$v:-}"
    [ -z "$val" ] || { echo "✗ $v leaked into the suite: $val"; exit 1; }
done
exit 0
EOF
chmod +x "$TEST_DIR/project/tests/test-pa.sh"
git -C "$TEST_DIR/project" add tests/test-pa.sh
git -C "$TEST_DIR/project" -c core.hooksPath=/dev/null commit -q -m "env probe suite"
printf '[map]\nsrc/app.sh = tests/test-pa.sh\n' > "$TEST_DIR/project/.weave/test-map.conf"
# The gate routes by the map git holds (F5, wv-fe8007), so HEAD carries it.
git -C "$TEST_DIR/project" add -f .weave/test-map.conf
git -C "$TEST_DIR/project" -c core.hooksPath=/dev/null commit -q --allow-empty -m "route the suites"
printf '#!/bin/sh\necho env\n' > "$TEST_DIR/project/src/app.sh"
git -C "$TEST_DIR/project" add src/app.sh
add_active_node "Suite env isolation task" --criteria="suites start without git repository variables|hook still reads the staged index" --risks=low >/dev/null 2>&1
set +e
OUTPUT=$(cd "$TEST_DIR/project" && GIT_INDEX_FILE="$TEST_DIR/project/.git/index" GIT_PREFIX="" \
    bash "$PROJECT_ROOT/scripts/hooks/pre-commit-weave.sh" 2>&1)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "suite pool: a suite does not inherit the commit's GIT_INDEX_FILE"
assert_not_contains "$OUTPUT" "leaked into the suite" "suite pool: no git repository variable reaches the suite"

# wv-a118d6: .weave/ configuration is gated like any other file; only graph
# state skips selection. The hook used to drop every staged .weave/ path, so the
# '.weave/test-map.conf = ...' row never fired and a map-only commit exited 0
# with no suite. The project links this checkout's libs so the hook tests the
# source allowlist, not whatever is installed. Each case writes a distinct map
# so a green ledger row from the previous case cannot be reused.
_a118_setup() {
    setup_test_env
    mkdir -p "$TEST_DIR/project/tests"
    for _a118_lib in wv-config.sh wv-validate.sh wv-checkpoint-ci.sh; do
        ln -sf "$PROJECT_ROOT/scripts/lib/$_a118_lib" "$TEST_DIR/project/scripts/lib/$_a118_lib"
    done
    A118_MARKER="$TEST_DIR/map-guard-ran"
    rm -f "$A118_MARKER"
    printf '#!/bin/sh\necho ran >> "%s"\nexit %s\n' "$A118_MARKER" "$1" > "$TEST_DIR/project/tests/test-map-guard.sh"
    chmod +x "$TEST_DIR/project/tests/test-map-guard.sh"
    git -C "$TEST_DIR/project" add tests/test-map-guard.sh
    git -C "$TEST_DIR/project" -c core.hooksPath=/dev/null commit -q -m "guard suite"
    printf '[map]\n# case: %s\n.weave/test-map.conf = tests/test-map-guard.sh\n.weave/nodes.jsonl = tests/test-map-guard.sh\n.weave/state.sql = tests/test-map-guard.sh\n' \
        "$2" > "$TEST_DIR/project/.weave/test-map.conf"
}
_a118_run() {
    set +e
    OUTPUT=$(cd "$TEST_DIR/project" && bash "$PROJECT_ROOT/scripts/hooks/pre-commit-weave.sh" 2>&1)
    EXIT_CODE=$?
    set -e
}

_a118_setup 0 map-only
git -C "$TEST_DIR/project" add .weave/test-map.conf
add_active_node "Map-only commit gate task" --criteria="map row fires|graph state skips" --risks=low >/dev/null 2>&1
_a118_run
assert_exit_code "0" "$EXIT_CODE" "git pre-commit: a map-only commit passes when its mapped suite passes"
assert_contains "$OUTPUT" "running tests/test-map-guard.sh" \
    "git pre-commit: a map-only commit runs the suite its own test-map row names"
assert_equals "1" "$(wc -l < "$A118_MARKER" 2>/dev/null | tr -d ' ' || echo 0)" \
    "git pre-commit: the map-only commit's suite executed once"

_a118_setup 1 map-only-red
git -C "$TEST_DIR/project" add .weave/test-map.conf
add_active_node "Map-only red gate task" --criteria="failing map suite blocks" --risks=low >/dev/null 2>&1
_a118_run
assert_exit_code "1" "$EXIT_CODE" "git pre-commit: a failing suite mapped from test-map.conf blocks a map-only commit"

_a118_setup 0 with-other-files
mkdir -p "$TEST_DIR/project/src"
echo 'echo hi' > "$TEST_DIR/project/src/other.sh"
git -C "$TEST_DIR/project" add .weave/test-map.conf src/other.sh
add_active_node "Map plus source gate task" --criteria="map row fires alongside source" --risks=low >/dev/null 2>&1
_a118_run
assert_exit_code "0" "$EXIT_CODE" "git pre-commit: test-map.conf staged with other files passes"
assert_contains "$OUTPUT" "running tests/test-map-guard.sh" \
    "git pre-commit: test-map.conf staged with other files still selects its mapped suite"

# Graph state keeps skipping selection even when a map row names it.
_a118_setup 1 graph-state
git -C "$TEST_DIR/project" add -f .weave/test-map.conf
git -C "$TEST_DIR/project" -c core.hooksPath=/dev/null commit -q -m "map"
echo '{"id":"wv-000001"}' > "$TEST_DIR/project/.weave/nodes.jsonl"
echo '-- dump' > "$TEST_DIR/project/.weave/state.sql"
git -C "$TEST_DIR/project" add -f .weave/nodes.jsonl .weave/state.sql
_a118_run
assert_exit_code "0" "$EXIT_CODE" "git pre-commit: a graph-state-only commit is allowed through"
assert_not_contains "$OUTPUT" "running tests/test-map-guard.sh" \
    "git pre-commit: graph-state files do not select suites, even with a map row"
assert_equals "absent" "$(if [ -f "$A118_MARKER" ]; then echo present; else echo absent; fi)" \
    "git pre-commit: no suite executed for a graph-state-only commit"

# Verify scripts/cmd/*.sh changes do not trigger test-core.sh
setup_test_env
mkdir -p "$TEST_DIR/project/scripts/cmd" "$TEST_DIR/project/tests"
cat > "$TEST_DIR/project/scripts/cmd/wv-cmd-custom.sh" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$TEST_DIR/project/scripts/cmd/wv-cmd-custom.sh"
git -C "$TEST_DIR/project" add scripts/cmd/wv-cmd-custom.sh
add_active_node "Git hook cmd-only task" --criteria="cmd changes skip test-core|hook exits cleanly" --risks=low >/dev/null 2>&1
set +e
OUTPUT=$(cd "$TEST_DIR/project" && bash "$PROJECT_ROOT/scripts/hooks/pre-commit-weave.sh" 2>&1)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "git pre-commit: cmd-only change exits 0 without running test-core.sh"
assert_not_contains "$OUTPUT" "test-core.sh" "git pre-commit: test-core.sh not triggered for scripts/cmd changes"

# Consumer repos do not have to ship Weave's own pytest fixture directories.
# The hook should skip optional focused dirs that are absent and let test-map
# driven shell suites handle repo-local tests.
setup_test_env
mkdir -p "$TEST_DIR/project/src"
cat > "$TEST_DIR/project/src/consumer.py" <<'EOF'
def answer() -> int:
    return 42
EOF
git -C "$TEST_DIR/project" add src/consumer.py
add_active_node "Git hook consumer pytest task" --criteria="missing optional pytest dirs skipped|consumer Python commit passes" --risks=low >/dev/null 2>&1
set +e
OUTPUT=$(cd "$TEST_DIR/project" && bash "$PROJECT_ROOT/scripts/hooks/pre-commit-weave.sh" 2>&1)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "git pre-commit: consumer Python commit skips missing optional pytest dirs"
assert_not_contains "$OUTPUT" "tests/weave_quality" "git pre-commit: does not pass missing weave_quality dir to pytest"
assert_not_contains "$OUTPUT" "tests/weave_indexer" "git pre-commit: does not pass missing weave_indexer dir to pytest"
# wv-734186: this fixture has no .weave/test-map.conf at all -- the impact
# gate message must say so explicitly, not the same generic text a
# present-but-non-matching config would also produce.
assert_contains "$OUTPUT" "impact gate inert: no .weave/test-map.conf found" \
    "git pre-commit: impact-inert message distinguishes a fully absent config"

# wv-734186: a PRESENT .weave/test-map.conf that simply does not match the
# staged file must say so distinctly, and name the unmatched file(s).
setup_test_env
mkdir -p "$TEST_DIR/project/src"
printf '[map]\nsrc/ = tests/test-graph.sh\n' > "$TEST_DIR/project/.weave/test-map.conf"
# Commit the map first: a staged test-map.conf is itself a gated file
# (wv-a118d6) and would be named as unmatched alongside docs.md.
git -C "$TEST_DIR/project" add .weave/test-map.conf
git -C "$TEST_DIR/project" -c core.hooksPath=/dev/null commit -q -m "map"
cat > "$TEST_DIR/project/docs.md" <<'EOF'
# unrelated docs change, not covered by the src/ mapping above
EOF
git -C "$TEST_DIR/project" add docs.md
add_active_node "Git hook unmatched-config task" --criteria="present-but-nonmatching config is distinguished|unmatched file is named" --risks=low >/dev/null 2>&1
set +e
OUTPUT=$(cd "$TEST_DIR/project" && bash "$PROJECT_ROOT/scripts/hooks/pre-commit-weave.sh" 2>&1)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "git pre-commit: present-but-nonmatching test-map.conf still exits 0"
assert_contains "$OUTPUT" "impact gate inert: .weave/test-map.conf exists but matched none" \
    "git pre-commit: impact-inert message distinguishes a present-but-nonmatching config"
assert_contains "$OUTPUT" "Unmatched: docs.md" \
    "git pre-commit: impact-inert message names the actual unmatched file"

# The shellcheck gate reads the STAGED BLOB, not the working tree (wv-d6c692).
# (A comment opening with the bare word "shellcheck" is parsed as a directive.)
# Naming staged files and letting shellcheck read them off disk checks whatever
# is in the worktree, so a dirty index behind a clean worktree committed content
# that was never linted. This stages a finding, then cleans the worktree.
setup_test_env
mkdir -p "$TEST_DIR/project/scripts"
if command -v shellcheck >/dev/null 2>&1; then
    cp "$PROJECT_ROOT/.shellcheckrc" "$TEST_DIR/project/.shellcheckrc" 2>/dev/null || true
    printf '#!/bin/bash\necho $(ls)\n' > "$TEST_DIR/project/scripts/staged-dirty.sh"
    git -C "$TEST_DIR/project" add scripts/staged-dirty.sh
    printf '#!/bin/bash\necho "clean"\n' > "$TEST_DIR/project/scripts/staged-dirty.sh"
    set +e
    OUTPUT=$(cd "$TEST_DIR/project" && bash "$PROJECT_ROOT/scripts/hooks/pre-commit-weave.sh" 2>&1)
    EXIT_CODE=$?
    set -e
    assert_exit_code "1" "$EXIT_CODE" "git pre-commit: dirty index behind a clean worktree is refused"
    assert_contains "$OUTPUT" "STAGED content" "git pre-commit: names the staged blob as the thing linted"
    git -C "$TEST_DIR/project" reset -q >/dev/null 2>&1 || true
    rm -f "$TEST_DIR/project/scripts/staged-dirty.sh"
else
    echo -e "  ${YELLOW}-${NC} shellcheck unavailable — staged-blob gate test skipped"
fi

# NUL-safety and fail-closed materialisation (wv-baf98b, wv-32fef5). An earlier
# version piped `-z` output through `tr '\0' '\n'`, so a path containing a
# newline was skipped entirely, and `xargs` split paths on spaces into
# nonexistent files and blocked commits for files that were fine.
setup_test_env
if command -v shellcheck >/dev/null 2>&1; then
    cp "$PROJECT_ROOT/.shellcheckrc" "$TEST_DIR/project/.shellcheckrc" 2>/dev/null || true
    mkdir -p "$TEST_DIR/project/scripts"
    printf '#!/bin/bash\necho $(ls)\n' > "$TEST_DIR/project/scripts/nl"$'\n'"name.sh"
    git -C "$TEST_DIR/project" add "scripts/nl"$'\n'"name.sh" 2>/dev/null
    set +e
    OUTPUT=$(cd "$TEST_DIR/project" && bash "$PROJECT_ROOT/scripts/hooks/pre-commit-weave.sh" 2>&1)
    EXIT_CODE=$?
    set -e
    assert_exit_code "1" "$EXIT_CODE" "git pre-commit: a newline in a staged path is still linted"
    assert_contains "$OUTPUT" "STAGED content" "git pre-commit: newline path reaches the linter"
    git -C "$TEST_DIR/project" reset -q >/dev/null 2>&1 || true
    rm -f "$TEST_DIR/project/scripts/nl"$'\n'"name.sh"

    printf '#!/bin/bash\necho "fine"\n' > "$TEST_DIR/project/scripts/with space.sh"
    git -C "$TEST_DIR/project" add "scripts/with space.sh"
    set +e
    OUTPUT=$(cd "$TEST_DIR/project" && bash "$PROJECT_ROOT/scripts/hooks/pre-commit-weave.sh" 2>&1)
    set -e
    assert_not_contains "$OUTPUT" "STAGED content" "git pre-commit: a clean path containing a space is not falsely blocked"
    git -C "$TEST_DIR/project" reset -q >/dev/null 2>&1 || true
    rm -f "$TEST_DIR/project/scripts/with space.sh"
else
    echo -e "  ${YELLOW}-${NC} shellcheck unavailable — NUL-safety gate tests skipped"
fi

# Repo-declared shellcheck scope (wv-b9ce14, wv-7608e6). Adopted only by a
# tracked .weave/shellcheck.conf; selection by extension or STAGED shebang with
# the declared exclusions; otherwise the fixed patterns, unchanged.
sc_hook() {  # sc_hook [env...] -> OUTPUT, EXIT_CODE
    set +e
    OUTPUT=$(cd "$TEST_DIR/project" && env "$@" bash "$PROJECT_ROOT/scripts/hooks/pre-commit-weave.sh" 2>&1)
    EXIT_CODE=$?
    set -e
}
sc_reset() { git -C "$TEST_DIR/project" reset -q >/dev/null 2>&1 || true; }
SC_CONF=$'[scope]\nmode = derived\n[exclude]\ntests/fixtures/\n'
setup_test_env
if command -v shellcheck >/dev/null 2>&1; then
    P="$TEST_DIR/project"
    cp "$PROJECT_ROOT/.shellcheckrc" "$P/.shellcheckrc" 2>/dev/null || true
    mkdir -p "$P/tests/fixtures/scan" "$P/bin"

    # Unadopted, with an unrelated scripts/shell-files.sh: the fixed patterns.
    printf '#!/bin/bash\necho unrelated\n' > "$P/scripts/shell-files.sh"
    printf '#!/bin/bash\necho $(ls)\n' > "$P/tests/test-unlinted.sh"
    git -C "$P" add scripts/shell-files.sh tests/test-unlinted.sh
    sc_hook
    assert_not_contains "$OUTPUT" "STAGED content" \
        "git pre-commit: without .weave/shellcheck.conf a tests/ script is outside the fixed patterns"
    printf '#!/bin/bash\necho $(ls)\n' > "$P/scripts/legacy.sh"; git -C "$P" add scripts/legacy.sh
    sc_hook
    assert_contains "$OUTPUT" "SC2046" "git pre-commit: without a declaration the fixed patterns still lint scripts/*.sh"
    sc_reset; rm -f "$P/scripts/legacy.sh"

    # Adopted: tests/ and an extensionless shebang script are linted, fixtures are not.
    printf '%s' "$SC_CONF" > "$P/.weave/shellcheck.conf"
    git -C "$P" add -f .weave/shellcheck.conf tests/test-unlinted.sh
    sc_hook
    assert_exit_code "1" "$EXIT_CODE" "git pre-commit: an adopted scope lints a staged tests/ script"
    assert_contains "$OUTPUT" "SC2046" "git pre-commit: ...and reports its finding"
    sc_reset; git -C "$P" add -f .weave/shellcheck.conf
    printf '#!/usr/bin/env bash\necho $(ls)\n' > "$P/bin/tool"; git -C "$P" add bin/tool
    sc_hook
    assert_contains "$OUTPUT" "SC2046" "git pre-commit: an adopted scope lints an extensionless shebang script"
    # Staged bytes decide: the worktree copy turning into Python changes nothing.
    printf '#!/usr/bin/env python3\nprint(1)\n' > "$P/bin/tool"
    sc_hook
    assert_contains "$OUTPUT" "SC2046" "git pre-commit: the STAGED shebang is the one judged"
    sc_reset; rm -f "$P/bin/tool"; git -C "$P" add -f .weave/shellcheck.conf
    printf '#!/bin/bash\necho $(ls)\n' > "$P/tests/fixtures/scan/unsafe.sh"; git -C "$P" add -f tests/fixtures/scan/unsafe.sh
    sc_hook
    assert_not_contains "$OUTPUT" "STAGED content" "git pre-commit: a declared exclusion is not linted"
    sc_reset

    # A declaration that cannot be read fails closed.
    printf '[scope]\nmode = everything\n' > "$P/.weave/shellcheck.conf"
    git -C "$P" add -f .weave/shellcheck.conf
    sc_hook
    assert_exit_code "1" "$EXIT_CODE" "git pre-commit: a malformed scope declaration refuses the commit"
    assert_contains "$OUTPUT" "staged .weave/shellcheck.conf" "git pre-commit: ...and names the declaration"
    sc_reset

    # One policy: what the hook lints is what the shared selection function
    # (scripts/lib/wv-shell-scope.sh, which make's helper also applies; see
    # tests/test-shell-files.sh) picks among the staged files. A stub linter
    # on PATH records the hook's arguments.
    printf '%s' "$SC_CONF" > "$P/.weave/shellcheck.conf"
    printf '#!/bin/sh\necho ok\n' > "$P/bin/tool"; printf 'echo lib\n' > "$P/lib.bash"
    printf '#!/usr/bin/env python3\nprint(1)\n' > "$P/bin/pytool"
    git -C "$P" add -f .weave/shellcheck.conf tests/test-unlinted.sh tests/fixtures/scan/unsafe.sh bin/tool bin/pytool lib.bash
    mkdir -p "$TEST_DIR/sc-stub"
    printf '#!/bin/sh\n[ "$1" = --severity=warning ] && shift\n[ "$1" = -- ] && shift\nprintf "%%s\\n" "$@" >> "%s"\n' \
        "$TEST_DIR/sc-args" > "$TEST_DIR/sc-stub/shellcheck"; chmod +x "$TEST_DIR/sc-stub/shellcheck"
    : > "$TEST_DIR/sc-args"
    sc_hook PATH="$TEST_DIR/sc-stub:$PATH"
    HOOK_SEL=$(LC_ALL=C sort "$TEST_DIR/sc-args")
    POLICY_SEL=$(cd "$P" && bash -c 'source "$1"; wv_shell_scope_read_conf .weave/shellcheck.conf >/dev/null || exit 1
        git diff --cached --name-only --diff-filter=ACMR -z | wv_shell_scope_select . | tr "\0" "\n"' _ \
        "$PROJECT_ROOT/scripts/lib/wv-shell-scope.sh" | LC_ALL=C sort)
    assert_equals "$POLICY_SEL" "$HOOK_SEL" "git pre-commit: the hook lints exactly what the shared selection picks (one policy)"
    assert_equals $'bin/tool\nlib.bash\ntests/test-unlinted.sh' "$HOOK_SEL" "git pre-commit: ...which is the extension-or-shebang set minus exclusions"
    sc_reset

    # A commit cannot narrow or drop the declaration that lints it (wv-49b687):
    # with HEAD declaring the scope, deleting it or excluding the file in the
    # same commit still lints the file; the next commit is judged by the new one.
    rm -f "$P/bin/tool" "$P/bin/pytool" "$P/lib.bash"
    printf '%s' "$SC_CONF" > "$P/.weave/shellcheck.conf"
    git -C "$P" add -f .weave/shellcheck.conf && git -C "$P" -c core.hooksPath=/dev/null commit -q -m "adopt scope"
    git -C "$P" rm -q --cached .weave/shellcheck.conf; git -C "$P" add tests/test-unlinted.sh
    sc_hook
    # No claim is held here, so the exit status alone is not the lint's; the
    # finding is the evidence.
    assert_contains "$OUTPUT" "SC2046" "git pre-commit: deleting the declaration in the same commit still lints under HEAD's"
    sc_reset
    printf '%s' "$SC_CONF" > "$P/.weave/shellcheck.conf"; printf 'tests/\n' >> "$P/.weave/shellcheck.conf"
    git -C "$P" add -f .weave/shellcheck.conf tests/test-unlinted.sh
    sc_hook
    assert_contains "$OUTPUT" "SC2046" "git pre-commit: excluding a file in the same commit still lints it under HEAD's declaration"
    sc_reset
    printf '[scope]\nmode = derived\n' > "$P/.weave/shellcheck.conf"
    git -C "$P" add -f .weave/shellcheck.conf tests/fixtures/scan/unsafe.sh
    sc_hook
    assert_contains "$OUTPUT" "SC2046" "git pre-commit: ...and a file only the staged declaration selects is linted too (the union)"
    sc_reset
    printf '%s' "$SC_CONF" > "$P/.weave/shellcheck.conf"
    # An unreadable HEAD declaration never blocks the commit repairing it, and
    # applies meanwhile with no exclusions, the strictest reading.
    printf '[scope]\nmode = everything\n' > "$P/.weave/shellcheck.conf"
    git -C "$P" add -f .weave/shellcheck.conf && git -C "$P" -c core.hooksPath=/dev/null commit -q -m "broken scope"
    printf '%s' "$SC_CONF" > "$P/.weave/shellcheck.conf"
    git -C "$P" add -f .weave/shellcheck.conf tests/fixtures/scan/unsafe.sh
    sc_hook
    assert_not_contains "$OUTPUT" "shellcheck gate:" "git pre-commit: an unreadable HEAD declaration does not refuse the commit repairing it"
    assert_contains "$OUTPUT" "SC2046" "git pre-commit: ...and applies with no exclusions meanwhile"
    sc_reset
    git -C "$P" add -f .weave/shellcheck.conf && git -C "$P" -c core.hooksPath=/dev/null commit -q -m "repair scope"

    # .shellcheckrc is read from git, not the working tree, and HEAD's applies
    # as well when this commit changes it (wv-49b687).
    # Untracked everywhere, the working-tree copy is not configuration: the
    # working tree is not what is committed (wv-e929cf, which reversed the
    # earlier rule that it applied as local configuration).
    printf '#!/bin/bash\necho $(ls)\n' > "$P/scripts/rc.sh"
    printf 'disable=SC2046\n' > "$P/.shellcheckrc"
    git -C "$P" add scripts/rc.sh
    sc_hook
    assert_contains "$OUTPUT" "SC2046" "git pre-commit: an untracked .shellcheckrc does not relax the gate"
    sc_reset
    # A tracked rc that suppresses nothing; this repository's own .shellcheckrc
    # does not ship, so the release projection has none to copy (wv-c6366c).
    printf '# tracked baseline: suppresses nothing\n' > "$P/.shellcheckrc"
    git -C "$P" add -f .shellcheckrc && git -C "$P" -c core.hooksPath=/dev/null commit -q -m "track .shellcheckrc"
    printf 'disable=SC2046\n' > "$P/.shellcheckrc"
    git -C "$P" add scripts/rc.sh
    sc_hook
    assert_contains "$OUTPUT" "SC2046" "git pre-commit: once tracked, an unstaged .shellcheckrc suppression does not relax the gate"
    git -C "$P" add -f .shellcheckrc
    sc_hook
    assert_contains "$OUTPUT" "SC2046" "git pre-commit: a suppression staged with the code it suppresses is refused"
    assert_contains "$OUTPUT" "under HEAD's shellcheck configuration" "git pre-commit: ...naming HEAD's configuration"
    sc_reset
    git -C "$P" add -f .shellcheckrc && git -C "$P" -c core.hooksPath=/dev/null commit -q -m "suppress SC2046"
    git -C "$P" add scripts/rc.sh
    sc_hook
    assert_not_contains "$OUTPUT" "STAGED content" "git pre-commit: once committed on its own, the suppression applies"
    sc_reset; rm -f "$P/scripts/rc.sh"
else
    echo -e "  ${YELLOW}-${NC} shellcheck unavailable — declared-scope gate tests skipped"
fi

# discover phase with non-.weave file staged must block (no active node bypass)
setup_test_env
printf '%s' discover > "$(owner_dir)/.session_phase"
echo "# content" > "$TEST_DIR/project/src.sh"
git -C "$TEST_DIR/project" add src.sh
set +e
OUTPUT=$(cd "$TEST_DIR/project" && bash "$PROJECT_ROOT/scripts/hooks/pre-commit-weave.sh" 2>&1)
EXIT_CODE=$?
set -e
assert_exit_code "1" "$EXIT_CODE" "git pre-commit: discover phase blocks non-.weave commit without active node"
assert_contains "$OUTPUT" "No active Weave node" "git pre-commit: discover phase emits no-active-node message"

# discover phase with only graph state staged must pass (early exit). Graph
# state, not any .weave/ file: configuration under .weave/ is gated (wv-a118d6).
setup_test_env
printf '%s' discover > "$(owner_dir)/.session_phase"
mkdir -p "$TEST_DIR/project/.weave"
echo "{}" > "$TEST_DIR/project/.weave/nodes.jsonl"
git -C "$TEST_DIR/project" add -f .weave/nodes.jsonl
set +e
OUTPUT=$(cd "$TEST_DIR/project" && bash "$PROJECT_ROOT/scripts/hooks/pre-commit-weave.sh" 2>&1)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "git pre-commit: discover phase allows a graph-state-only commit"

# Admission is per actor (wv-99d559): an active node claimed by SOMEONE ELSE no
# longer admits a commit. Identities are explicit: the suite itself may run
# under any harness's markers.
setup_test_env
echo "# content" > "$TEST_DIR/project/admit.sh"
git -C "$TEST_DIR/project" add admit.sh
FOREIGN_ADMIT_ID=$(WV_AGENT_ID="codex-other-host-user" add_active_node "Foreign admission task" 2>/dev/null | tail -1)
set +e
OUTPUT=$(cd "$TEST_DIR/project" && WV_AGENT_ID="claude-this-host-user" bash "$PROJECT_ROOT/scripts/hooks/pre-commit-weave.sh" 2>&1)
EXIT_CODE=$?
set -e
assert_exit_code "1" "$EXIT_CODE" "git pre-commit: another agent's claim does not admit this actor's commit"
assert_contains "$OUTPUT" "No active Weave node is claimed by claude-this-host-user" \
    "git pre-commit: the refusal names the committing actor"
assert_contains "$OUTPUT" "$FOREIGN_ADMIT_ID  claimed by codex-other-host-user" \
    "git pre-commit: the refusal names who holds the active claim"
set +e
OUTPUT=$(cd "$TEST_DIR/project" && env -u WV_AGENT_ID -u CLAUDECODE -u AI_AGENT -u CLAUDE_CODE_SSE_PORT -u CODEX_THREAD_ID \
    -u CODEX_CI -u COPILOT_AGENT bash "$PROJECT_ROOT/scripts/hooks/pre-commit-weave.sh" 2>&1)
EXIT_CODE=$?
set -e
assert_exit_code "1" "$EXIT_CODE" "git pre-commit: an agent's claim does not admit a human's commit either"
(cd "$TEST_DIR/project" && WV_AGENT_ID="claude-this-host-user" "$WV" work "$FOREIGN_ADMIT_ID" --force >/dev/null 2>&1) || true
set +e
OUTPUT=$(cd "$TEST_DIR/project" && WV_AGENT_ID="claude-this-host-user" bash "$PROJECT_ROOT/scripts/hooks/pre-commit-weave.sh" 2>&1)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "git pre-commit: after wv work --force the taking-over actor is admitted"
assert_not_contains "$OUTPUT" "No active Weave node is claimed by" "git pre-commit: no refusal once the claim is held"
set +e
OUTPUT=$(cd "$TEST_DIR/project" && WV_AGENT_ID="codex-other-host-user" bash "$PROJECT_ROOT/scripts/hooks/pre-commit-weave.sh" 2>&1)
EXIT_CODE=$?
set -e
assert_exit_code "1" "$EXIT_CODE" "git pre-commit: the previous holder is no longer admitted after the takeover"
assert_not_contains "$OUTPUT" "linked worktree" "git pre-commit: an ordinary checkout's refusal carries no worktree note"

# A linked worktree keeps its own graph (owner decision wv-d88fed): a claim in
# the main checkout does not admit a commit there, so both claim refusals say
# so and name the main checkout. The worktree gets its own hot zone, as wv
# resolves one per checkout.
setup_test_env
WT_DIR="$TEST_DIR/linked"
git -C "$TEST_DIR/project" worktree add -q --detach "$WT_DIR"
mkdir -p "$WT_DIR/scripts/lib"
for f in wv lib/wv-resolve-project.sh lib/wv-resolve-runtime.sh; do ln -sf "$TEST_DIR/project/scripts/$f" "$WT_DIR/scripts/$f"; done
wt_env() { (cd "$WT_DIR" && WV_HOT_ZONE="$TEST_DIR/wtzone" WV_DB="$TEST_DIR/wtzone/brain.db" \
    WV_PROJECT_DIR="$WT_DIR" CLAUDE_PROJECT_DIR="$WT_DIR" "$@"); }
wt_env "$WV" load >/dev/null 2>&1 || true
echo "# content" > "$WT_DIR/wt.sh"
git -C "$WT_DIR" add wt.sh
set +e
OUTPUT=$(wt_env bash "$PROJECT_ROOT/scripts/hooks/pre-commit-weave.sh" 2>&1)
EXIT_CODE=$?
set -e
assert_exit_code "1" "$EXIT_CODE" "git pre-commit: a linked worktree with no claim of its own is refused"
assert_contains "$OUTPUT" "No active Weave node — commit blocked" "git pre-commit: ...by the no-claim box"
assert_contains "$OUTPUT" "This is a linked worktree of:" "git pre-commit: ...which says it is a linked worktree"
assert_contains "$OUTPUT" "     $(cd "$TEST_DIR/project" && pwd -P)" "git pre-commit: ...names the main checkout"
assert_contains "$OUTPUT" "In this worktree run wv load, then claim:" "git pre-commit: ...and says to load and claim there"
WT_FOREIGN_ID=$(wt_env env WV_AGENT_ID="codex-other-host-user" bash -c "$(declare -f add_active_node); WV='$WV'; add_active_node 'Worktree foreign task'" 2>/dev/null | tail -1)
set +e
OUTPUT=$(wt_env env WV_AGENT_ID="claude-this-host-user" bash "$PROJECT_ROOT/scripts/hooks/pre-commit-weave.sh" 2>&1)
EXIT_CODE=$?
set -e
assert_exit_code "1" "$EXIT_CODE" "git pre-commit: another actor's claim in the worktree does not admit this actor"
assert_contains "$OUTPUT" "$WT_FOREIGN_ID  claimed by codex-other-host-user" "git pre-commit: ...the not-mine refusal lists it"
assert_contains "$OUTPUT" "This is a linked worktree of:" "git pre-commit: ...and carries the worktree note"
git -C "$TEST_DIR/project" worktree remove --force "$WT_DIR" 2>/dev/null || true

# Former exemptions no longer admit substantive content (wv-68aeff): with no
# claim, every one of them is refused; graph state alone still passes.
ex_hook() {  # ex_hook [env...] -> OUTPUT, EXIT_CODE (no node is claimed)
    set +e
    OUTPUT=$(cd "$TEST_DIR/project" && env "$@" bash "$PROJECT_ROOT/scripts/hooks/pre-commit-weave.sh" 2>&1)
    EXIT_CODE=$?
    set -e
}
ex_reset() { git -C "$TEST_DIR/project" reset -q >/dev/null 2>&1 || true; }
setup_test_env
P="$TEST_DIR/project"
printf 'x = 1\n' > "$P/tracked.py"
git -C "$P" add tracked.py && git -C "$P" -c core.hooksPath=/dev/null commit -q -m "tracked file"
echo "# substantive" > "$P/work.sh"

git -C "$P" add work.sh; ex_hook WV_STYLE_COMMIT=1
assert_exit_code "1" "$EXIT_CODE" "git pre-commit: WV_STYLE_COMMIT=1 no longer admits substantive content"
ex_reset
printf 'x  =  1\n' > "$P/tracked.py"; git -C "$P" add tracked.py; ex_hook
assert_exit_code "1" "$EXIT_CODE" "git pre-commit: a whitespace-only diff is not admitted without a claim"
assert_not_contains "$OUTPUT" "Whitespace-only change" "git pre-commit: ...and the shortcut message is gone"
ex_reset; git -C "$P" checkout -q -- tracked.py
git -C "$P" add work.sh; ex_hook WV_AUTO_CHECKPOINT_ACTIVE=1
assert_exit_code "1" "$EXIT_CODE" "git pre-commit: WV_AUTO_CHECKPOINT_ACTIVE=1 is not authority for substantive content"
ex_reset
echo '{}' > "$P/.weave/nodes.jsonl"; git -C "$P" add -f .weave/nodes.jsonl; ex_hook WV_AUTO_CHECKPOINT_ACTIVE=1
assert_exit_code "0" "$EXIT_CODE" "git pre-commit: a graph-state-only checkpoint still passes"
ex_hook
assert_exit_code "0" "$EXIT_CODE" "git pre-commit: ...with or without the flag"
ex_reset
printf '%s' closing > "$(owner_dir)/.session_phase"
git -C "$P" add work.sh; ex_hook
assert_exit_code "1" "$EXIT_CODE" "git pre-commit: the closing phase no longer waives admission for substantive work"
ex_reset
printf '%s' closing > "$(owner_dir)/.session_phase"
git -C "$P" add -f .weave/nodes.jsonl; ex_hook
assert_exit_code "0" "$EXIT_CODE" "git pre-commit: a graph-state commit in the closing phase still passes"
ex_reset

# No wv: refused in a Weave-managed repository, admitted elsewhere.
mv "$P/scripts/wv" "$TEST_DIR/wv.aside"
git -C "$P" add -f .weave/nodes.jsonl && git -C "$P" -c core.hooksPath=/dev/null commit -q -m "track .weave"
git -C "$P" add work.sh; ex_hook PATH=/usr/bin:/bin
assert_exit_code "1" "$EXIT_CODE" "git pre-commit: with no wv, a Weave-managed repository refuses substantive content"
assert_contains "$OUTPUT" "so this Weave-managed repository cannot check the staged changes" "git pre-commit: ...saying why"
ex_reset
echo '{"x":1}' > "$P/.weave/nodes.jsonl"; git -C "$P" add -f .weave/nodes.jsonl; ex_hook PATH=/usr/bin:/bin
assert_exit_code "0" "$EXIT_CODE" "git pre-commit: with no wv, graph state still passes"
ex_reset
# Managed is HEAD or the index (wv-49b687): staging the deletion of .weave/
# with the code does not remove the refusal from the same commit.
git -C "$P" rm -q -r --cached .weave; git -C "$P" add work.sh; ex_hook PATH=/usr/bin:/bin
assert_exit_code "1" "$EXIT_CODE" "git pre-commit: with no wv, staging .weave/'s deletion with code is still refused"
assert_contains "$OUTPUT" "so this Weave-managed repository cannot check the staged changes" "git pre-commit: ...by the same refusal"
ex_reset
git -C "$P" rm -q -r --cached .weave && git -C "$P" -c core.hooksPath=/dev/null commit -q -m "untrack .weave"
git -C "$P" add work.sh; ex_hook PATH=/usr/bin:/bin
assert_exit_code "0" "$EXIT_CODE" "git pre-commit: with no wv, a repository that tracks no .weave/ is admitted"
ex_reset; mv "$TEST_DIR/wv.aside" "$P/scripts/wv"

setup_test_env
HOOK_ID=$(add_active_node "Prepare hook task" --criteria="hook adds trailer|smoke passes" --risks=low 2>/dev/null | tail -1)
HOOK_ID_2=$(add_active_node "Second prepare hook task" --criteria="multi-claim hook adds trailer" --risks=low 2>/dev/null | tail -1)
FOREIGN_HOOK_ID=$(WV_AGENT_ID="codex-other-session" add_active_node "Foreign prepare hook task" \
    --criteria="foreign claim is excluded" --risks=low 2>/dev/null | tail -1)
MSG_FILE="$TEST_DIR/project/COMMIT_EDITMSG"
printf 'hook smoke\n' > "$MSG_FILE"
set +e
OUTPUT=$(cd "$TEST_DIR/project" && sh "$PROJECT_ROOT/scripts/hooks/prepare-commit-msg-weave.sh" "$MSG_FILE" 2>&1)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "prepare-commit-msg hook exits 0"
MSG_CONTENT=$(cat "$MSG_FILE")
assert_contains "$MSG_CONTENT" "Weave-ID: $HOOK_ID" "prepare-commit-msg hook appends active Weave-ID"
assert_contains "$MSG_CONTENT" "Weave-ID: $HOOK_ID_2" "prepare-commit-msg hook appends every current-agent active ID"
assert_not_contains "$MSG_CONTENT" "Weave-ID: $FOREIGN_HOOK_ID" "prepare-commit-msg hook excludes foreign-agent active IDs"

# A message ending in Co-Authored-By takes the rewrite branch: the trailer goes
# above the co-author line, and the rewritten file replaces the message
# (wv-8561b6: with '&& mv' flipped to '|| mv' the rewrite was discarded and
# every suite still passed).
printf 'hook smoke\n\nCo-Authored-By: Someone <someone@example.com>\n' > "$MSG_FILE"
set +e
(cd "$TEST_DIR/project" && sh "$PROJECT_ROOT/scripts/hooks/prepare-commit-msg-weave.sh" "$MSG_FILE" >/dev/null 2>&1)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "prepare-commit-msg hook exits 0 on a co-authored message"
ABOVE_COAUTHOR=$(awk '/^Co-Authored-By:/ {exit} {print}' "$MSG_FILE")
assert_contains "$ABOVE_COAUTHOR" "Weave-ID: $HOOK_ID" \
    "prepare-commit-msg hook writes the trailer above Co-Authored-By"
assert_contains "$ABOVE_COAUTHOR" "Weave-ID: $HOOK_ID_2" \
    "prepare-commit-msg hook writes every trailer above Co-Authored-By"
assert_equals "0" "$(find "$TEST_DIR/project" -maxdepth 1 -name 'COMMIT_EDITMSG.wv*' | wc -l | tr -d ' ')" \
    "prepare-commit-msg hook leaves no rewrite temp file behind"

# Git hooks tag their wv calls source=hook (wv-f47c10). A commit from a Claude
# session inherits WV_CALL_SOURCE=agent, and the e5-c02 capture logged 27 gate
# calls as agent calls. A stub wv first on PATH (the hooks resolve wv with
# command -v) records the tag of every call. Each hook must make at least one
# call, or an empty log would pass vacuously. A test run's tag must survive.
TAG_DIR="$TEST_DIR/hook-source-tag"
mkdir -p "$TAG_DIR/bin" "$TAG_DIR/repo/.weave" "$TAG_DIR/repo/src"
cat > "$TAG_DIR/bin/wv" <<'EOF'
#!/bin/sh
printf '%s\n' "${WV_CALL_SOURCE:-unset}" >> "$WV_STUB_LOG"
echo '[]'
EOF
chmod +x "$TAG_DIR/bin/wv"
(
    cd "$TAG_DIR/repo" && git init -q && git config user.name "Hook Test" \
        && git config user.email "hook-test@example.com" && git config commit.gpgsign false \
        && git commit -q --allow-empty -m init
    printf '[heavy]\nsrc/ = tests/none.sh\n' > .weave/test-map.conf
    # Committed with the pushed file: pre-push reads the pushed commits' maps
    # from git (wv-418d4c), so an uncommitted map would owe nothing.
    echo pushed > src/pushed.sh && git add src/pushed.sh && git add -f .weave/test-map.conf && git commit -q -m pushed
    echo staged > src/staged.sh && git add src/staged.sh
)
_hook_call_tags() {  # <inherited WV_CALL_SOURCE> <hook>: distinct tags logged
    : > "$TAG_DIR/log"
    (
        cd "$TAG_DIR/repo" || exit 1
        export PATH="$TAG_DIR/bin:$PATH" WV_STUB_LOG="$TAG_DIR/log" WV_CALL_SOURCE="$1"
        case "$2" in
            pre-commit) bash "$PROJECT_ROOT/scripts/hooks/pre-commit-weave.sh" ;;
            prepare-commit-msg)
                echo msg > "$TAG_DIR/msg"
                sh "$PROJECT_ROOT/scripts/hooks/prepare-commit-msg-weave.sh" "$TAG_DIR/msg" ;;
            pre-push)
                bash "$PROJECT_ROOT/scripts/hooks/pre-push-weave.sh" origin unused \
                    < <(printf 'refs/heads/main %s refs/heads/main %040d\n' "$(git rev-parse HEAD)" 0) ;;
        esac
    ) >/dev/null 2>&1
    sort -u "$TAG_DIR/log" | paste -sd ',' -
}
for _tag_hook in pre-commit prepare-commit-msg pre-push; do
    assert_equals "hook" "$(_hook_call_tags agent "$_tag_hook")" \
        "git $_tag_hook: wv calls are tagged hook, not the inherited agent tag"
    assert_equals "test" "$(_hook_call_tags test "$_tag_hook")" \
        "git $_tag_hook: a test run's WV_CALL_SOURCE=test tag survives"
done

# Agent-host guards tag their own wv calls hook at entry (wv-a093ea). The claim
# preflight never loaded wv-hook-common, so its wv show/wv impact inherited
# WV_CALL_SOURCE=agent from Claude Code's settings and the S4e rehearsal logged
# them as agent work. The other guards loaded hook-common with `|| true`, so a
# failed load did the same. A stub wv in the fixture project (wv-resolve-project
# prefers it) records each call's tag; the "broken" layout is a copy of
# scripts/lib whose wv-hook-common fails to load, with an empty HOME so no
# installed copy stands in.
GUARD_TAG_DIR="$TEST_DIR/guard-source-tag"
mkdir -p "$GUARD_TAG_DIR/project/.weave" "$GUARD_TAG_DIR/project/scripts" "$GUARD_TAG_DIR/home"
cat > "$GUARD_TAG_DIR/project/scripts/wv" <<'EOF'
#!/bin/sh
printf '%s\n' "${WV_CALL_SOURCE:-unset}" >> "$WV_STUB_LOG"
case "$1" in
    show) echo '{"id":"wv-abc123","text":"t","alias":"a","status":"active","metadata":"{\"done_criteria\":[\"c\"],\"risks\":[]}"}' ;;
    *) echo '{}' ;;
esac
EOF
chmod +x "$GUARD_TAG_DIR/project/scripts/wv"
cp -R "$PROJECT_ROOT/scripts/lib" "$GUARD_TAG_DIR/broken-lib"
echo 'return 1' > "$GUARD_TAG_DIR/broken-lib/wv-hook-common.sh"
_guard_call_tags() {  # <inherited WV_CALL_SOURCE> <adapter|broken> <guard> <command>
    : > "$GUARD_TAG_DIR/log"
    (
        cd "$GUARD_TAG_DIR/project" || exit 1
        export WV_STUB_LOG="$GUARD_TAG_DIR/log" WV_CALL_SOURCE="$1" \
            WV_PROJECT_DIR="$GUARD_TAG_DIR/project" CLAUDE_PROJECT_DIR="$GUARD_TAG_DIR/project"
        _input=$(jq -cn --arg c "$4" --arg cwd "$GUARD_TAG_DIR/project" \
            '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}')
        if [ "$2" = adapter ]; then
            printf '%s' "$_input" | bash "$HOOKS_DIR/pre-claim-skills.sh"
        else
            export HOME="$GUARD_TAG_DIR/home"
            # shellcheck source=/dev/null
            . "$GUARD_TAG_DIR/broken-lib/wv-pre-tool-use.sh" && "$3" "$_input"
        fi
    ) >/dev/null 2>&1
    sort -u "$GUARD_TAG_DIR/log" | paste -sd ',' -
}
assert_equals "hook" "$(_guard_call_tags agent adapter wv_ptu_claim_guard 'wv work wv-abc123')" \
    "claim preflight (Claude adapter): wv show/impact tagged hook, not the inherited agent tag"
assert_equals "test" "$(_guard_call_tags test adapter wv_ptu_claim_guard 'wv work wv-abc123')" \
    "claim preflight (Claude adapter): a test run's WV_CALL_SOURCE=test tag survives"
assert_equals "hook" "$(_guard_call_tags agent broken wv_ptu_claim_guard 'wv work wv-abc123')" \
    "claim preflight: calls tagged hook when wv-hook-common cannot load"
assert_equals "hook" "$(_guard_call_tags agent broken wv_ptu_close_guard 'wv done wv-abc123')" \
    "close verification: calls tagged hook when wv-hook-common cannot load"

# Every subshell guard in the three host-neutral hook libraries sets the tag as
# its entry, so a guard added later cannot rely on hook-common's side effect.
_untagged_guards=""
for _guard_lib in wv-pre-tool-use wv-post-tool-use wv-lifecycle-end; do
    _untagged_guards="$_untagged_guards$(awk '
        /^wv_[a-z_]+\(\) *\( *$/ { name = $1; sub(/\(\).*/, "", name); n = 0; next }
        name != "" { n++; if ($0 ~ /_tag_hook$/) { name = ""; next } if (n >= 3) { print name; name = "" } }
    ' "$PROJECT_ROOT/scripts/lib/$_guard_lib.sh")"
done
assert_equals "" "$_untagged_guards" \
    "every hook guard in pre-tool-use/post-tool-use/lifecycle-end tags hook within its first lines"

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
TASK_ID=$("$WV" add "Lifecycle test task" --force 2>/dev/null | tail -1)
OUTPUT=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"cmd\":\"wv work $TASK_ID\"}}" | bash "$HOOKS_DIR/pre-claim-skills.sh" 2>/dev/null || true)
"$WV" work "$TASK_ID" 2>/dev/null
TASK_STATUS=$("$WV" show "$TASK_ID" --json 2>/dev/null | jq -r '.status')
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
if ! grep -q "Verification evidence required" <<< "$OUTPUT"; then
    echo -e "${GREEN}✓${NC} lifecycle: close allowed with verification"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "${RED}✗${NC} lifecycle: close allowed with verification"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# 7. Complete the node
"$WV" "done" "$TASK_ID" 2>/dev/null
TASK_STATUS=$("$WV" show "$TASK_ID" --json 2>/dev/null | jq -r '.status')
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
# The stub replaces the project's scripts/wv, the first place the resolver
# looks. A stub in HOME/.local/bin is never reached from a checkout hook, which
# pairs with the checkout's own wv (wv-706439), so it silently ran the real CLI
# -- sync --gh included -- against this fixture (wv-5fd0b5).
LIFECYCLE_HOME="$TEST_DIR/lifecycle-home"
LIFECYCLE_LOG="$TEST_DIR/lifecycle-wv-calls.log"
mkdir -p "$LIFECYCLE_HOME"
rm -f "$TEST_DIR/project/scripts/wv"
cat > "$TEST_DIR/project/scripts/wv" <<EOF
#!/bin/sh
echo "\$*" >> "$LIFECYCLE_LOG"
exit 0
EOF
chmod +x "$TEST_DIR/project/scripts/wv"
set +e
OUTPUT=$(HOME="$LIFECYCLE_HOME" CLAUDE_PROJECT_DIR="$TEST_DIR/project" \
    bash "$HOOKS_DIR/session-end-sync.sh" <<< '{"reason":"lifecycle_test"}' 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "lifecycle: session ends cleanly"
assert_contains "$(cat "$LIFECYCLE_LOG" 2>/dev/null || echo "<stub never invoked>")" "sync" \
    "lifecycle: session end reaches the project's wv, not another copy"

# 11. Pre-compact preserves context during lifecycle
add_active_node "Another active task" 2>/dev/null
OUTPUT=$(bash "$HOOKS_DIR/pre-compact-context.sh" 2>/dev/null || true)
assert_contains "$OUTPUT" "Active:" "lifecycle: pre-compact reports active work during session"

# Put back the real wv the lifecycle stub replaced: later sections reach the
# project's scripts/wv first, and context-guard now asks it for the policy
# (wv-f757a4) -- against the stub every policy check read "unknown".
ln -sf "$WV" "$TEST_DIR/project/scripts/wv"

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

setup_uninitialized_project
set +e
OUTPUT=$(bash "$HOOKS_DIR/context-guard.sh" 2>/dev/null)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "context-guard: exits 0 in uninitialized repo"
assert_contains "$OUTPUT" "policy" "context-guard: emits policy line in uninitialized repo"
assert_equals "absent" "$(if [ -d "$TEST_DIR/project/.weave" ]; then echo present; else echo absent; fi)" "context-guard: does not create .weave in uninitialized repo"

# ============================================================
# --- JSONL bridge: crash path includes last-prompt ---
echo ""
echo "--- session-start: JSONL bridge (crash path) ---"
setup_test_env

# Plant a crash sentinel over a real active node: the hook reports the graph's
# active nodes at exit, not the sentinel's start-time list (wv-4efe06). No stop
# record, so the previous session died mid-turn.
add_active_node "Active at crash" >/dev/null 2>&1
"$WV" sync 2>/dev/null || true
echo '{"ts":"2026-03-27T00:00:00Z","active":[]}' > "$WV_HOT_ZONE/.session_sentinel"

BRIDGE_HOME="$TEST_DIR/bridge-home"
mkdir -p "$BRIDGE_HOME"

# Create Claude JSONL under an isolated HOME at the slug derived from the
# unique test project dir. Hook code resolves wv from the repo path, not HOME.
_BRIDGE_SLUG=$(echo "$WV_PROJECT_DIR" | tr '/' '-')
_BRIDGE_JSONL_DIR="$BRIDGE_HOME/.claude/projects/${_BRIDGE_SLUG}"
mkdir -p "$_BRIDGE_JSONL_DIR"
printf '%s\n' \
    '{"type":"summary","summary":"prev session"}' \
    '{"type":"last-prompt","lastPrompt":"okay whats next on the list"}' \
    > "$_BRIDGE_JSONL_DIR/session.jsonl"

OUTPUT=$(HOME="$BRIDGE_HOME" bash "$HOOKS_DIR/session-start-context.sh" 2>/dev/null || true)
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
add_active_node "Orphaned after reboot" 2>/dev/null
"$WV" sync 2>/dev/null || true

_BRIDGE2_JSONL_DIR="$BRIDGE_HOME/.claude/projects/${_BRIDGE_SLUG}"
mkdir -p "$_BRIDGE2_JSONL_DIR"
printf '%s\n' \
    '{"type":"last-prompt","lastPrompt":"sync state visibility"}' \
    > "$_BRIDGE2_JSONL_DIR/session.jsonl"

OUTPUT=$(HOME="$BRIDGE_HOME" bash "$HOOKS_DIR/session-start-context.sh" 2>/dev/null || true)
rm -rf "$_BRIDGE2_JSONL_DIR"

assert_contains "$OUTPUT" "Last prompt:" "JSONL bridge: secondary detection includes Last prompt field"
assert_contains "$OUTPUT" "sync state visibility" "JSONL bridge: secondary detection includes last-prompt text"

# ============================================================
# --- JSONL bridge: graceful degradation (no JSONL dir) ---
echo ""
echo "--- session-start: JSONL bridge (degradation, no JSONL) ---"
setup_test_env

# Crash sentinel with no JSONL for this (unique temp) project path — bridge must degrade
add_active_node "Active at crash, no JSONL" >/dev/null 2>&1
"$WV" sync 2>/dev/null || true
echo '{"ts":"2026-03-27T00:01:00Z","active":[]}' > "$WV_HOT_ZONE/.session_sentinel"
# _BRIDGE_SLUG dir was deleted above; isolated HOME has no JSONL for this slug

OUTPUT=$(HOME="$BRIDGE_HOME" bash "$HOOKS_DIR/session-start-context.sh" 2>/dev/null || true)
assert_contains "$OUTPUT" "CRASH DETECTED" "JSONL bridge: crash detected even without JSONL"
# Must not contain "Last prompt:" when no JSONL available
TESTS_RUN=$((TESTS_RUN + 1))
if grep -qF "Last prompt:" <<< "$OUTPUT"; then
    echo -e "${RED}✗${NC} JSONL bridge: degrades gracefully when no JSONL (unexpected Last prompt: found)"
    TESTS_FAILED=$((TESTS_FAILED + 1))
else
    echo -e "${GREEN}✓${NC} JSONL bridge: degrades gracefully when no JSONL"
    TESTS_PASSED=$((TESTS_PASSED + 1))
fi

# ============================================================
# --- Hook JSON schema audit (H2.T3) ---
# For each hook, assert it emits the right JSON schema for its event type:
#   PreToolUse  → hookSpecificOutput.permissionDecision (current API)
#   PostToolUse → flat {"decision":"block","reason":"..."}
#   Stop        → flat {"decision":"block","reason":"..."}
#   SessionStart→ hookSpecificOutput.additionalContext (no permissionDecision)
# The common regression is using the wrong event's schema (e.g. permissionDecision
# inside a Stop hook) — the CLI silently ignores such output.
# ============================================================
# Test: wv-budget-tally.sh — A2 in-session token tally hook
# ============================================================
echo ""
echo "Test: wv-budget-tally"
echo "====================="
setup_test_env

export WV_BUDGET_DIR="$TEST_DIR/budget"
BUDGET_FILE="$WV_BUDGET_DIR/session-budget.json"
rm -rf "$WV_BUDGET_DIR"
unset WV_NONINTERACTIVE WV_BUDGET_DISABLE
export WV_BUDGET_THRESHOLD=3

# 1) Non-Bash tool: ignored
OUTPUT=$(echo '{"tool_name":"Edit","tool_input":{"file_path":"x.py"},"tool_response":{"output":"ok"}}' \
    | bash "$HOOKS_DIR/wv-budget-tally.sh" 2>&1 || true)
assert_equals "" "$OUTPUT" "budget-tally: non-Bash tool produces no output"

# 2) Bash but non-wv command: ignored, no budget file
OUTPUT=$(echo '{"tool_name":"Bash","tool_input":{"command":"git status"},"tool_response":{"output":"clean"}}' \
    | bash "$HOOKS_DIR/wv-budget-tally.sh" 2>&1 || true)
assert_equals "" "$OUTPUT" "budget-tally: non-wv Bash produces no output"
TESTS_RUN=$((TESTS_RUN + 1))
if [[ ! -f "$BUDGET_FILE" ]]; then
    echo -e "${GREEN}✓${NC} budget-tally: non-wv Bash does not create budget file"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "${RED}✗${NC} budget-tally: budget file should not exist for non-wv calls"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# 3) wv call below threshold: tallied, no advisory
OUTPUT=$(echo '{"tool_name":"Bash","tool_input":{"command":"wv status"},"tool_response":{"output":"some output"}}' \
    | bash "$HOOKS_DIR/wv-budget-tally.sh" 2>&1 || true)
assert_equals "" "$OUTPUT" "budget-tally: 1st wv call below threshold = no advisory"
CALLS=$(jq -r '.calls' "$BUDGET_FILE" 2>/dev/null || echo "")
assert_equals "1" "$CALLS" "budget-tally: 1st call increments counter to 1"

# 4) Reach threshold (call #3) — advisory fires
echo '{"tool_name":"Bash","tool_input":{"command":"wv ready"},"tool_response":{"output":"ab"}}' \
    | bash "$HOOKS_DIR/wv-budget-tally.sh" >/dev/null 2>&1 || true
OUTPUT=$(echo '{"tool_name":"Bash","tool_input":{"command":"./scripts/wv learnings"},"tool_response":{"output":"longer output text"}}' \
    | bash "$HOOKS_DIR/wv-budget-tally.sh" 2>&1 || true)
assert_equals "PostToolUse" "$(jq -r '.hookSpecificOutput.hookEventName // empty' <<<"$OUTPUT" 2>/dev/null)" "budget-tally: threshold call emits hookSpecificOutput"
assert_contains "$(jq -r '.hookSpecificOutput.additionalContext // empty' <<<"$OUTPUT" 2>/dev/null)" "wv called 3x" "budget-tally: the advisory is the additionalContext both hosts read"
assert_contains "$OUTPUT" "wv called 3x" "budget-tally: advisory mentions call count"
assert_contains "$OUTPUT" "narrower queries" "budget-tally: advisory suggests narrower queries"

# 5) Advisory only fires once per session
OUTPUT=$(echo '{"tool_name":"Bash","tool_input":{"command":"wv show wv-abc"},"tool_response":{"output":"x"}}' \
    | bash "$HOOKS_DIR/wv-budget-tally.sh" 2>&1 || true)
assert_equals "" "$OUTPUT" "budget-tally: advisory fires only once per session"
CALLS=$(jq -r '.calls' "$BUDGET_FILE")
assert_equals "4" "$CALLS" "budget-tally: 4th call still counted after advisory"

# Claude Code's Bash result carries stdout and stderr, never an output field, so
# the byte tally read nothing from a real call (wv-461da4). 5 + 2 bytes here.
BYTES_BEFORE=$(jq -r '.bytes' "$BUDGET_FILE")
echo '{"tool_name":"Bash","tool_input":{"command":"wv status"},"tool_response":{"stdout":"12345","stderr":"ab","interrupted":false,"isImage":false,"noOutputExpected":false}}' \
    | bash "$HOOKS_DIR/wv-budget-tally.sh" >/dev/null 2>&1 || true
assert_equals "$((BYTES_BEFORE + 7))" "$(jq -r '.bytes' "$BUDGET_FILE")" "budget-tally: counts the bytes of a real Claude Bash result (stdout + stderr)"

# 6) WV_NONINTERACTIVE suppresses advisory across the threshold
rm -f "$BUDGET_FILE"
export WV_NONINTERACTIVE=1
for _ in 1 2 3 4; do
    echo '{"tool_name":"Bash","tool_input":{"command":"wv status"},"tool_response":{"output":"x"}}' \
        | bash "$HOOKS_DIR/wv-budget-tally.sh" >/dev/null 2>&1 || true
done
OUTPUT=$(echo '{"tool_name":"Bash","tool_input":{"command":"wv status"},"tool_response":{"output":"x"}}' \
    | bash "$HOOKS_DIR/wv-budget-tally.sh" 2>&1 || true)
assert_equals "" "$OUTPUT" "budget-tally: WV_NONINTERACTIVE suppresses advisory"
CALLS=$(jq -r '.calls' "$BUDGET_FILE")
assert_equals "5" "$CALLS" "budget-tally: WV_NONINTERACTIVE still tallies calls"
unset WV_NONINTERACTIVE
unset WV_BUDGET_THRESHOLD
unset WV_BUDGET_DIR

# ============================================================
# Test: wv-touched-files.sh — B1 relevance signal hook
# ============================================================
echo ""
echo "Test: wv-touched-files"
echo "======================"
setup_test_env

export WV_TOUCHED_DIR="$TEST_DIR/touched"
RING_FILE="$WV_TOUCHED_DIR/recent-edits.txt"
rm -rf "$WV_TOUCHED_DIR"
export WV_TOUCHED_NODE_CAP=50
export WV_TOUCHED_RING_CAP=20

# Set up a fake DB with one active node so the hook has something to write to.
TF_DB="$TEST_DIR/touched-brain.db"
rm -f "$TF_DB"
sqlite3 "$TF_DB" "CREATE TABLE nodes (id TEXT PRIMARY KEY, status TEXT, metadata TEXT, updated_at DATETIME);"
sqlite3 "$TF_DB" "CREATE TABLE node_files (node_id TEXT NOT NULL, path TEXT NOT NULL, PRIMARY KEY (node_id, path));"
sqlite3 "$TF_DB" "INSERT INTO nodes VALUES ('wv-active1', 'active', '{\"claimed_by\":\"test-hooks-agent\"}', datetime('now'));"
sqlite3 "$TF_DB" "INSERT INTO nodes VALUES ('wv-todo1', 'todo', '{}', datetime('now'));"
export WV_DB="$TF_DB"

# 1) Non-edit tool: ignored
OUTPUT=$(echo '{"tool_name":"Bash","tool_input":{"command":"ls"},"tool_response":{"success":true}}' \
    | bash "$HOOKS_DIR/wv-touched-files.sh" 2>&1 || true)
assert_equals "" "$OUTPUT" "touched-files: non-edit tool produces no output"
TESTS_RUN=$((TESTS_RUN + 1))
if [[ ! -f "$RING_FILE" ]]; then
    echo -e "${GREEN}✓${NC} touched-files: non-edit tool does not create ring"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "${RED}✗${NC} touched-files: ring should not exist for non-edit calls"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# 2) Edit on a file: writes to ring AND updates active node metadata
echo "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$TEST_DIR/project/foo.py\"},\"tool_response\":{\"success\":true}}" \
    | bash "$HOOKS_DIR/wv-touched-files.sh" >/dev/null 2>&1 || true
RING_CONTENT=$(cat "$RING_FILE" 2>/dev/null || echo "")
assert_contains "$RING_CONTENT" "foo.py" "touched-files: ring records edited file"
META_FILES=$(sqlite3 "$TF_DB" "SELECT json_extract(metadata, '\$.touched_files') FROM nodes WHERE id='wv-active1';" 2>/dev/null)
assert_contains "$META_FILES" "foo.py" "touched-files: active node metadata.touched_files updated"
NODE_FILE_PATH=$(sqlite3 "$TF_DB" "SELECT path FROM node_files WHERE node_id='wv-active1' AND path='foo.py';" 2>/dev/null)
assert_equals "foo.py" "$NODE_FILE_PATH" "touched-files: node_files row written for active node"

# 2b) A file outside the repository is not the node's work (wv-67c7b6): it got
# attributed absolute, no test map could route it, and wv done read it stale.
echo "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/tmp/wv-outside-repo/notes.md\"},\"tool_response\":{\"success\":true}}" \
    | bash "$HOOKS_DIR/wv-touched-files.sh" >/dev/null 2>&1 || true
assert_equals "0" "$(sqlite3 "$TF_DB" "SELECT COUNT(*) FROM node_files WHERE path LIKE '/%';" 2>/dev/null)" \
    "touched-files: a path outside the repository is not attributed to the node"

# 3) Failed tool call: skipped
echo "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$TEST_DIR/project/never.py\"},\"tool_response\":{\"success\":false}}" \
    | bash "$HOOKS_DIR/wv-touched-files.sh" >/dev/null 2>&1 || true
RING_CONTENT=$(cat "$RING_FILE" 2>/dev/null || echo "")
TESTS_RUN=$((TESTS_RUN + 1))
if ! grep -qF "never.py" <<< "$RING_CONTENT"; then
    echo -e "${GREEN}✓${NC} touched-files: failed tool call is skipped"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "${RED}✗${NC} touched-files: failed tool call should not write ring"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# 4) Dedup: same file edited twice appears once in ring
echo "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TEST_DIR/project/foo.py\"},\"tool_response\":{\"success\":true}}" \
    | bash "$HOOKS_DIR/wv-touched-files.sh" >/dev/null 2>&1 || true
FOO_COUNT=$(grep -c "foo.py" "$RING_FILE" 2>/dev/null || echo 0)
assert_equals "1" "$FOO_COUNT" "touched-files: ring deduplicates repeated paths"
NODE_FILE_COUNT=$(sqlite3 "$TF_DB" "SELECT COUNT(*) FROM node_files WHERE node_id='wv-active1' AND path='foo.py';" 2>/dev/null)
assert_equals "1" "$NODE_FILE_COUNT" "touched-files: node_files deduplicates repeated paths"

# 5) Ring cap: only last N paths retained
export WV_TOUCHED_RING_CAP=3
rm -f "$RING_FILE"
for i in 1 2 3 4 5; do
    echo "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TEST_DIR/file${i}.py\"},\"tool_response\":{\"success\":true}}" \
        | bash "$HOOKS_DIR/wv-touched-files.sh" >/dev/null 2>&1 || true
done
RING_LINES=$(wc -l < "$RING_FILE" 2>/dev/null || echo 0)
assert_equals "3" "$RING_LINES" "touched-files: ring respects cap (last 3 of 5)"
RING_CONTENT=$(cat "$RING_FILE" 2>/dev/null || echo "")
TESTS_RUN=$((TESTS_RUN + 1))
if ! grep -qF "file1.py" <<< "$RING_CONTENT"; then
    echo -e "${GREEN}✓${NC} touched-files: oldest path evicted"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "${RED}✗${NC} touched-files: oldest path should have been evicted"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi
assert_contains "$RING_CONTENT" "file5.py" "touched-files: newest path retained"

# 6) Node cap on metadata.touched_files
export WV_TOUCHED_NODE_CAP=2
sqlite3 "$TF_DB" "UPDATE nodes SET metadata='{\"claimed_by\":\"test-hooks-agent\"}' WHERE id='wv-active1';"
for i in a b c d; do
    echo "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$TEST_DIR/project/${i}.py\"},\"tool_response\":{\"success\":true}}" \
        | bash "$HOOKS_DIR/wv-touched-files.sh" >/dev/null 2>&1 || true
done
NODE_COUNT=$(sqlite3 "$TF_DB" "SELECT json_array_length(json_extract(metadata, '\$.touched_files')) FROM nodes WHERE id='wv-active1';" 2>/dev/null)
assert_equals "2" "$NODE_COUNT" "touched-files: active node touched_files capped"

# 7) Full attribution matcher coverage: every supported write tool is attributed
assert_touched_files_tool() {
    local tool_name="$1"
    local input_key="$2"
    local file_path="$3"
    local expected_path="$4"
    local tool_meta

    sqlite3 "$TF_DB" "UPDATE nodes SET metadata='{\"claimed_by\":\"test-hooks-agent\"}' WHERE id='wv-active1';"
    jq -nc \
        --arg tool_name "$tool_name" \
        --arg input_key "$input_key" \
        --arg file_path "$file_path" \
        '{tool_name:$tool_name, tool_input:{($input_key):$file_path}, tool_response:{success:true}}' \
        | bash "$HOOKS_DIR/wv-touched-files.sh" >/dev/null 2>&1 || true
    tool_meta=$(sqlite3 "$TF_DB" "SELECT json_extract(metadata, '\$.touched_files') FROM nodes WHERE id='wv-active1';" 2>/dev/null)
    assert_contains "$tool_meta" "$expected_path" "touched-files: ${tool_name} participates in attribution"
}

assert_touched_files_tool "create_file" "filePath" "$TEST_DIR/project/vscode.py" "vscode.py"
assert_touched_files_tool "replace_string_in_file" "filePath" "$TEST_DIR/project/replace.py" "replace.py"
assert_touched_files_tool "insert_edit_into_file" "filePath" "$TEST_DIR/project/insert.py" "insert.py"
assert_touched_files_tool "multi_replace_string_in_file" "filePath" "$TEST_DIR/project/multi.py" "multi.py"
assert_touched_files_tool "NotebookEdit" "path" "$TEST_DIR/project/notebook.ipynb" "notebook.ipynb"
assert_touched_files_tool "edit_notebook_file" "filePath" "$TEST_DIR/project/edit-notebook.ipynb" "edit-notebook.ipynb"

# 8) Stale primary falls back to an active node and clears the stale stamp
PRIMARY_FILE="$(owner_dir)/primary"
sqlite3 "$TF_DB" "INSERT INTO nodes VALUES ('wv-old-primary', 'done', '{}', datetime('now', '-1 hour'));"
sqlite3 "$TF_DB" "UPDATE nodes SET updated_at=datetime('now', '-1 hour') WHERE id='wv-active1';"
sqlite3 "$TF_DB" "INSERT INTO nodes VALUES ('wv-active2', 'active', '{\"claimed_by\":\"test-hooks-agent\"}', datetime('now'));"
echo "wv-old-primary" > "$PRIMARY_FILE"
sqlite3 "$TF_DB" "UPDATE nodes SET metadata='{\"claimed_by\":\"test-hooks-agent\"}' WHERE id='wv-active2';"
echo "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$TEST_DIR/project/fallback.py\"},\"tool_response\":{\"success\":true}}" \
    | bash "$HOOKS_DIR/wv-touched-files.sh" >/dev/null 2>&1 || true
FALLBACK_META=$(sqlite3 "$TF_DB" "SELECT json_extract(metadata, '\$.touched_files') FROM nodes WHERE id='wv-active2';" 2>/dev/null)
assert_contains "$FALLBACK_META" "fallback.py" "touched-files: stale primary falls back to an active node"
TESTS_RUN=$((TESTS_RUN + 1))
if [ ! -f "$PRIMARY_FILE" ]; then
    echo -e "${GREEN}✓${NC} touched-files: stale primary stamp cleared during fallback"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "${RED}✗${NC} touched-files: stale primary stamp should be cleared"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# 9) Canonical runtime resolver path: no WV_TOUCHED_DIR/WV_DB overrides needed
unset WV_TOUCHED_DIR WV_DB
CANON_HOT="$TEST_DIR/canonical-hot"
export WV_HOT_ZONE="$CANON_HOT"
mkdir -p "$CANON_HOT"
CANON_DB="$CANON_HOT/brain.db"
rm -f "$CANON_DB"
sqlite3 "$CANON_DB" "CREATE TABLE nodes (id TEXT PRIMARY KEY, status TEXT, metadata TEXT, updated_at DATETIME);"
sqlite3 "$CANON_DB" "CREATE TABLE node_files (node_id TEXT NOT NULL, path TEXT NOT NULL, PRIMARY KEY (node_id, path));"
sqlite3 "$CANON_DB" "INSERT INTO nodes VALUES ('wv-canon1', 'active', '{\"claimed_by\":\"test-hooks-agent\"}', datetime('now'));"
echo "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$TEST_DIR/project/canon.py\"},\"tool_response\":{\"success\":true}}" \
    | bash "$HOOKS_DIR/wv-touched-files.sh" >/dev/null 2>&1 || true
CANON_RING_CONTENT=$(cat "$CANON_HOT/recent-edits.txt" 2>/dev/null || echo "")
assert_contains "$CANON_RING_CONTENT" "canon.py" "touched-files: canonical resolver writes ring without overrides"
CANON_META=$(sqlite3 "$CANON_DB" "SELECT json_extract(metadata, '\$.touched_files') FROM nodes WHERE id='wv-canon1';" 2>/dev/null)
assert_contains "$CANON_META" "canon.py" "touched-files: canonical resolver writes metadata without overrides"
CANON_NODE_FILE=$(sqlite3 "$CANON_DB" "SELECT path FROM node_files WHERE node_id='wv-canon1' AND path='canon.py';" 2>/dev/null)
assert_equals "canon.py" "$CANON_NODE_FILE" "touched-files: canonical resolver writes node_files without overrides"
export WV_HOT_ZONE="$TEST_DIR"
export WV_DB="$TF_DB"

unset WV_TOUCHED_DIR WV_TOUCHED_NODE_CAP WV_TOUCHED_RING_CAP WV_DB

echo ""
echo "--- Hook JSON schema audit ---"

# Static hook → event-type map. Keep in sync with ~/.claude/settings.json hooks.
declare -A HOOK_EVENTS=(
    [pre-action.sh]=PreToolUse
    [pre-claim-skills.sh]=PreToolUse
    [pre-close-verification.sh]=PreToolUse
    [bash-dedup.sh]=PreToolUse
    [post-edit-lint.sh]=PostToolUse
    [bash-dedup-post.sh]=PostToolUse
    [wv-budget-tally.sh]=PostToolUse
    [wv-touched-files.sh]=PostToolUse
    [post-memory-capture.sh]=PostToolUse
    [stop-check.sh]=Stop
    [session-start-context.sh]=SessionStart
    [context-guard.sh]=SessionStart
    [session-end-sync.sh]=SessionEnd
    [pre-compact-context.sh]=PreCompact
)

schema_check() {
    local label="$1"
    local ok="$2"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$ok" = "0" ]; then
        echo -e "${GREEN}✓${NC} $label"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $label"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

for hook in "${!HOOK_EVENTS[@]}"; do
    event="${HOOK_EVENTS[$hook]}"
    path="$HOOKS_DIR/$hook"
    if [ ! -f "$path" ]; then
        schema_check "$hook ($event): file exists" 1
        continue
    fi

    case "$event" in
        PreToolUse)
            # An adapter's output is the guard it calls (wv-d3fbcb): read that
            # guard's body from the library along with the adapter, or a deny
            # emitted there is invisible here and the check passes vacuously.
            src=$(cat "$path")
            guard=$(grep -m1 -oE 'wv_ptu_[a-z]+_guard' "$path" || true)
            if [ -n "$guard" ]; then
                src+=$'\n'$(awk -v f="$guard" '$0 ~ "^" f "\\(\\) \\($" { p = 1 } p { print } p && /^\)$/ { exit }' \
                    "$PROJECT_ROOT/scripts/lib/wv-pre-tool-use.sh")
            fi
            if grep -qE '"decision"[[:space:]]*:[[:space:]]*"block"|decision:[[:space:]]*"block"' <<<"$src"; then
                schema_check "$hook ($event): no deprecated flat decision schema" 1
            else
                schema_check "$hook ($event): no deprecated flat decision schema" 0
            fi

            if grep -q 'hookSpecificOutput' <<<"$src"; then
                if grep -q 'PreToolUse' <<<"$src" && grep -q 'permissionDecision' <<<"$src"; then
                    schema_check "$hook ($event): uses hookSpecificOutput.permissionDecision" 0
                else
                    schema_check "$hook ($event): hookSpecificOutput missing PreToolUse+permissionDecision" 1
                fi
                if grep -qE 'permissionDecision[^"]*"DENY"' <<<"$src"; then
                    schema_check "$hook ($event): permissionDecision value is lowercase 'deny'" 1
                else
                    schema_check "$hook ($event): permissionDecision value is lowercase 'deny'" 0
                fi
            else
                schema_check "$hook ($event): no JSON emission (exit-code-only is acceptable)" 0
            fi
            ;;
        PostToolUse)
            # As for PreToolUse: an adapter's output is the guard it calls, so
            # read that guard's body from the library along with the adapter.
            src=$(cat "$path")
            guard=$(grep -m1 -oE 'wv_potu_[a-z_]+_guard' "$path" || true)
            if [ -n "$guard" ]; then
                src+=$'\n'$(awk -v f="$guard" '$0 ~ "^" f "\\(\\) \\($" { p = 1 } p { print } p && /^\)$/ { exit }' \
                    "$PROJECT_ROOT/scripts/lib/wv-post-tool-use.sh")
            fi
            if grep -q 'permissionDecision' <<<"$src"; then
                schema_check "$hook ($event): does not use permissionDecision (PreToolUse-only)" 1
            else
                schema_check "$hook ($event): does not use permissionDecision (PreToolUse-only)" 0
            fi
            # Both hosts read PostToolUse context only from
            # hookSpecificOutput.additionalContext; a top-level one is ignored by
            # Claude Code and rejected by Codex (wv-09aa6f).
            if grep -qE '\{\\?"?additionalContext' <<<"$src"; then
                schema_check "$hook ($event): no top-level additionalContext" 1
            else
                schema_check "$hook ($event): no top-level additionalContext" 0
            fi
            ;;
        Stop)
            if grep -q 'permissionDecision' "$path"; then
                schema_check "$hook ($event): does not use permissionDecision (PreToolUse-only)" 1
            else
                schema_check "$hook ($event): does not use permissionDecision (PreToolUse-only)" 0
            fi
            if grep -q 'hookSpecificOutput' "$path"; then
                schema_check "$hook ($event): does not use hookSpecificOutput" 1
            else
                schema_check "$hook ($event): does not use hookSpecificOutput" 0
            fi
            ;;
        SessionStart)
            if grep -q 'permissionDecision' "$path"; then
                schema_check "$hook ($event): does not use permissionDecision" 1
            else
                schema_check "$hook ($event): does not use permissionDecision" 0
            fi
            if grep -qE '"decision"[[:space:]]*:[[:space:]]*"block"' "$path"; then
                schema_check "$hook ($event): does not use flat decision (PostToolUse/Stop-only)" 1
            else
                schema_check "$hook ($event): does not use flat decision (PostToolUse/Stop-only)" 0
            fi
            ;;
        SessionEnd|PreCompact)
            if grep -q 'permissionDecision' "$path"; then
                schema_check "$hook ($event): does not use permissionDecision" 1
            else
                schema_check "$hook ($event): does not use permissionDecision" 0
            fi
            if grep -qE '"decision"[[:space:]]*:[[:space:]]*"block"' "$path"; then
                schema_check "$hook ($event): does not use flat decision schema" 1
            else
                schema_check "$hook ($event): does not use flat decision schema" 0
            fi
            ;;
    esac
done

# ============================================================
# post-memory-capture.sh — repo-scoped Claude memory capture (S5)
# ============================================================
echo ""
echo "--- post-memory-capture.sh ---"
setup_test_env

mc_home="$TEST_DIR/mc-home"
mc_slug=$(printf '%s' "$TEST_DIR/project" | tr '/' '-')
mc_memdir="$mc_home/.claude/projects/$mc_slug/memory"
mkdir -p "$mc_memdir"
printf '# m\n\ndurable fact about the resolver path\n' > "$mc_memdir/a.md"

# 1. Matching repo slug, dry default -> advisory + import suggestion, no graph write.
MC_OUT=$(printf '{"tool_name":"Write","tool_response":{"success":true},"tool_input":{"file_path":"%s/a.md"}}' "$mc_memdir" \
    | HOME="$mc_home" WV_PROJECT_DIR="$TEST_DIR/project" WV_HOT_ZONE="$TEST_DIR" bash "$HOOKS_DIR/post-memory-capture.sh" 2>/dev/null || true)
assert_contains "$(jq -r '.hookSpecificOutput.additionalContext // empty' <<<"$MC_OUT" 2>/dev/null)" "Repo-scoped Claude memory write" "memory-capture: emits the advisory as hookSpecificOutput.additionalContext"
assert_contains "$MC_OUT" "wv memory import" "memory-capture: advisory points at graph import"
assert_not_contains "$MC_OUT" "permissionDecision" "memory-capture: PostToolUse hook does not gate (no permissionDecision)"

# 2. Different repo slug -> repo-scope proof rejects, no output (wv-4109ef).
mc_other="$mc_home/.claude/projects/-some-other-repo/memory"
mkdir -p "$mc_other"; printf '# m\n\nx\n' > "$mc_other/b.md"
MC_OTHER=$(printf '{"tool_name":"Write","tool_response":{"success":true},"tool_input":{"file_path":"%s/b.md"}}' "$mc_other" \
    | HOME="$mc_home" WV_PROJECT_DIR="$TEST_DIR/project" WV_HOT_ZONE="$TEST_DIR" bash "$HOOKS_DIR/post-memory-capture.sh" 2>/dev/null || true)
assert_equals "" "$MC_OTHER" "memory-capture: rejects a different repo's Claude memory (repo-scope proof)"

# 3. Non-memory file in the repo -> no-op.
MC_CODE=$(printf '{"tool_name":"Write","tool_response":{"success":true},"tool_input":{"file_path":"%s/project/src.py"}}' "$TEST_DIR" \
    | HOME="$mc_home" WV_PROJECT_DIR="$TEST_DIR/project" WV_HOT_ZONE="$TEST_DIR" bash "$HOOKS_DIR/post-memory-capture.sh" 2>/dev/null || true)
assert_equals "" "$MC_CODE" "memory-capture: ignores non-memory file writes"

# 4. Tool failure -> no-op even for a matching memory path.
MC_FAIL=$(printf '{"tool_name":"Write","tool_response":{"success":false},"tool_input":{"file_path":"%s/a.md"}}' "$mc_memdir" \
    | HOME="$mc_home" WV_PROJECT_DIR="$TEST_DIR/project" WV_HOT_ZONE="$TEST_DIR" bash "$HOOKS_DIR/post-memory-capture.sh" 2>/dev/null || true)
assert_equals "" "$MC_FAIL" "memory-capture: skips on failed tool call"

# 4b. The repository keeps Claude memory outside the graph by recorded choice
# (wv-27131a): no advisory, no pending record. Without a reason it records no
# choice, and the advisory returns.
mkdir -p "$TEST_DIR/project/.weave"
printf '[memory]\noutside_graph = claude\nreason = field notes stay in Claude memory\n' > "$TEST_DIR/project/.weave/policy.conf"
rm -f "$TEST_DIR/memory-capture-pending.tsv"
MC_KEPT=$(printf '{"tool_name":"Write","tool_response":{"success":true},"tool_input":{"file_path":"%s/a.md"}}' "$mc_memdir" \
    | HOME="$mc_home" WV_PROJECT_DIR="$TEST_DIR/project" WV_HOT_ZONE="$TEST_DIR" bash "$HOOKS_DIR/post-memory-capture.sh" 2>/dev/null || true)
assert_equals "" "$MC_KEPT" "memory-capture: silent when policy.conf keeps Claude memory outside the graph"
assert_equals "absent" "$([ -e "$TEST_DIR/memory-capture-pending.tsv" ] && echo present || echo absent)" \
    "memory-capture: records no pending import under that choice"
printf '[memory]\noutside_graph = claude\n' > "$TEST_DIR/project/.weave/policy.conf"
MC_NOREASON=$(printf '{"tool_name":"Write","tool_response":{"success":true},"tool_input":{"file_path":"%s/a.md"}}' "$mc_memdir" \
    | HOME="$mc_home" WV_PROJECT_DIR="$TEST_DIR/project" WV_HOT_ZONE="$TEST_DIR" bash "$HOOKS_DIR/post-memory-capture.sh" 2>/dev/null || true)
assert_contains "$MC_NOREASON" "Repo-scoped Claude memory write" "memory-capture: a choice without a reason is no choice"
rm -f "$TEST_DIR/project/.weave/policy.conf"

# 5. Opt-in import (WV_MEMORY_CAPTURE=1) runs the first EXECUTABLE wv candidate:
# a project scripts/wv that is not executable is skipped for the checkout's own.
# Neither the import path nor the candidate walk had a case (wv-e53f56: '&&'
# flipped to '||' took the project's file, and '-z' flipped to '-n' exited
# exactly when a wv was found; both survived every suite).
mc_ck="$TEST_DIR/mc-checkout"
mkdir -p "$mc_ck/.claude/hooks" "$mc_ck/scripts/lib"
cp "$HOOKS_DIR/post-memory-capture.sh" "$mc_ck/.claude/hooks/"
cp "$PROJECT_ROOT/scripts/lib/wv-resolve-project.sh" "$PROJECT_ROOT/scripts/lib/wv-resolve-runtime.sh" \
    "$PROJECT_ROOT/scripts/lib/wv-hook-common.sh" "$PROJECT_ROOT/scripts/lib/wv-post-tool-use.sh" "$mc_ck/scripts/lib/"
MC_LOG="$TEST_DIR/mc-import.log"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\n' "$MC_LOG" > "$mc_ck/scripts/wv"
chmod +x "$mc_ck/scripts/wv"
rm -f "$TEST_DIR/project/scripts/wv"
printf '#!/bin/sh\nexit 0\n' > "$TEST_DIR/project/scripts/wv"
chmod -x "$TEST_DIR/project/scripts/wv"
printf '{"tool_name":"Write","tool_response":{"success":true},"tool_input":{"file_path":"%s/a.md"}}' "$mc_memdir" \
    | HOME="$mc_home" WV_PROJECT_DIR="$TEST_DIR/project" WV_HOT_ZONE="$TEST_DIR" WV_MEMORY_CAPTURE=1 \
      bash "$mc_ck/.claude/hooks/post-memory-capture.sh" >/dev/null 2>&1 || true
assert_contains "$(cat "$MC_LOG" 2>/dev/null || echo "<no wv ran>")" "memory import --source=claude --path=$mc_memdir" \
    "memory-capture: opt-in import runs the first executable wv, skipping a non-executable one"

# A project-local CLI must not replace the CLI paired with the hook library:
# inside a protected lane it would execute working-tree bytes (wv-971035).
: > "$MC_LOG"
MC_DECOY_LOG="$TEST_DIR/mc-decoy.log"
cat > "$TEST_DIR/project/scripts/wv" <<EOF
#!/bin/sh
if [ "\$1 \$2" = 'memory import' ]; then printf 'wrong-copy\n' >> "$MC_DECOY_LOG"; fi
exit 0
EOF
chmod +x "$TEST_DIR/project/scripts/wv"
printf '{"tool_name":"Write","tool_response":{"success":true},"tool_input":{"file_path":"%s/a.md"}}' "$mc_memdir" \
    | HOME="$mc_home" WV_PROJECT_DIR="$TEST_DIR/project" WV_HOT_ZONE="$TEST_DIR" WV_MEMORY_CAPTURE=1 \
      bash "$mc_ck/.claude/hooks/post-memory-capture.sh" >/dev/null 2>&1 || true
assert_contains "$(cat "$MC_LOG" 2>/dev/null || echo "<no wv ran>")" "memory import --source=claude --path=$mc_memdir" \
    "memory-capture: the library's own CLI wins over a project-local decoy"
assert_equals "" "$(cat "$MC_DECOY_LOG" 2>/dev/null || true)" \
    "memory-capture: project-local decoy never imports"

# ============================================================
# Agent-hook branches the S0 re-measure found undriven (wv-e53f56)
# ============================================================
echo ""
echo "--- agent-hook branches (wv-e53f56) ---"

# context-guard: a Weave history over 100 nodes lowers the load policy, a small
# one does not. The existing policy case ran without a nodes.jsonl at all, so
# the history branch never executed and flipping '-gt 100' survived.
setup_test_env
export POLICY_CACHE="$TEST_DIR/.context_policy"
for cg_n in 150 5; do
    rm -f "$POLICY_CACHE"
    seq 1 "$cg_n" | sed 's/.*/{}/' > "$TEST_DIR/project/.weave/nodes.jsonl"
    bash "$HOOKS_DIR/context-guard.sh" >/dev/null 2>&1 || true
    cg_policy=$(head -1 "$POLICY_CACHE" 2>/dev/null || echo "<no policy cached>")
    if [ "$cg_n" -gt 100 ]; then
        assert_equals "LOW" "$cg_policy" "context-guard: a ${cg_n}-node history lowers the policy to LOW"
    else
        assert_equals "HIGH" "$cg_policy" "context-guard: a ${cg_n}-node history keeps a small repo HIGH"
    fi
done

# pre-compact: the checkpoint folds into a previous graph-only checkpoint, but
# never amends a commit that carries code, and its message is the checkpoint
# line with at most the skip-ci marker (flipping the marker's '&&' to '||'
# appended the helper's name instead).
# WV_DB is exported for this whole suite, and an overridden WV_DB makes wv sync
# write nothing to .weave/, so the hook never had anything to commit here. It
# resolves to the same file through WV_HOT_ZONE, so drop it for this block.
setup_test_env
cd "$TEST_DIR/project"
pc_saved_wv_db="${WV_DB:-}"
unset WV_DB
# The hook's own 'wv sync' commits .weave/ as "sync state" when it can; the
# checkpoint logic under test runs only when that commit was skipped (throttled
# after a recent auto-checkpoint), so hold it off for the whole block.
export _WV_SKIP_SYNC_COMMIT=1
add_active_node "pre-compact amend fixture one" >/dev/null 2>&1
"$WV" sync >/dev/null 2>&1 || true
git add .weave && git commit -qm "chore(weave): auto-checkpoint 10:00" || true
pc_count=$(git rev-list --count HEAD)
add_active_node "pre-compact amend fixture two" >/dev/null 2>&1
bash "$HOOKS_DIR/pre-compact-context.sh" >/dev/null 2>&1 || true
assert_equals "$pc_count" "$(git rev-list --count HEAD)" \
    "pre-compact: new graph state folds into a graph-only checkpoint"

printf 'print(1)\n' > app.py
add_active_node "pre-compact code fixture" >/dev/null 2>&1
"$WV" sync >/dev/null 2>&1 || true
git add app.py .weave && git commit -qm "chore(weave): auto-checkpoint 10:05" || true
pc_code_head=$(git rev-parse HEAD)
pc_count=$(git rev-list --count HEAD)
add_active_node "pre-compact code fixture two" >/dev/null 2>&1
bash "$HOOKS_DIR/pre-compact-context.sh" >/dev/null 2>&1 || true
assert_equals "$((pc_count + 1))" "$(git rev-list --count HEAD)" \
    "pre-compact: a checkpoint after a commit carrying code is a new commit"
assert_equals "$pc_code_head" "$(git rev-parse HEAD~1)" \
    "pre-compact: the commit carrying code keeps its hash"
pc_msg=$(git log -1 --format=%s)
if [[ "$pc_msg" =~ ^wip:\ pre-compact\ checkpoint\ [0-9]{2}:[0-9]{2}(\ \[skip\ ci\])?$ ]]; then pc_msg_ok=yes; else pc_msg_ok="$pc_msg"; fi
assert_equals "yes" "$pc_msg_ok" "pre-compact: the checkpoint message carries at most the skip-ci marker"

# With an upstream and only graph state unpushed, the checkpoint must carry the
# skip-ci marker. Above, the range held app.py, so the marker was rightly empty
# and flipping the helper's '&&' to '||' (which empties it always) survived.
git init --bare -q "$TEST_DIR/pc-origin.git"
git remote add origin "$TEST_DIR/pc-origin.git" 2>/dev/null || true
git push -q -u origin HEAD 2>/dev/null || true
add_active_node "pre-compact upstream fixture" >/dev/null 2>&1
bash "$HOOKS_DIR/pre-compact-context.sh" >/dev/null 2>&1 || true
pc_msg=$(git log -1 --format=%s)
if [[ "$pc_msg" =~ ^wip:\ pre-compact\ checkpoint\ [0-9]{2}:[0-9]{2}\ \[skip\ ci\]$ ]]; then pc_msg_ok=yes; else pc_msg_ok="$pc_msg"; fi
assert_equals "yes" "$pc_msg_ok" "pre-compact: a graph-only checkpoint over an upstream carries [skip ci]"
unset _WV_SKIP_SYNC_COMMIT
[ -n "$pc_saved_wv_db" ] && export WV_DB="$pc_saved_wv_db"

# post-edit-lint: files in the typed modules get a Pyrefly pass, others do not.
setup_test_env
cd "$TEST_DIR/project"
if command -v pyrefly >/dev/null 2>&1; then
    mkdir -p scripts/weave_quality scripts/other
    printf 'project-includes = ["scripts"]\n' > pyrefly.toml
    printf 'x: int = "not an int"\n' > scripts/weave_quality/typed_probe.py
    printf 'x: int = "not an int"\n' > scripts/other/typed_probe.py
    pel_mod=$(printf '{"tool_name":"Edit","tool_response":{"success":true},"tool_input":{"file_path":"%s"}}' \
        "$TEST_DIR/project/scripts/weave_quality/typed_probe.py" | bash "$HOOKS_DIR/post-edit-lint.sh" 2>/dev/null || true)
    assert_contains "$pel_mod" "Pyrefly type errors in scripts/weave_quality" \
        "post-edit-lint: a type error in a typed module is reported"
    assert_contains "$pel_mod" "bad-assignment" \
        "post-edit-lint: the checker diagnosed the planted assignment, not a setup failure"
    pel_other=$(printf '{"tool_name":"Edit","tool_response":{"success":true},"tool_input":{"file_path":"%s"}}' \
        "$TEST_DIR/project/scripts/other/typed_probe.py" | bash "$HOOKS_DIR/post-edit-lint.sh" 2>/dev/null || true)
    assert_not_contains "$pel_other" "Pyrefly" "post-edit-lint: a file outside the typed modules gets no type-check pass"
else
    echo "  (post-edit-lint Pyrefly cases skipped: pyrefly is not on PATH)"
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
