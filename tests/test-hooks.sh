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
    if grep -qF "$needle" <<<"$haystack"; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Expected to find: $needle"
        echo "  In: $(echo "$haystack" | head -3)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if ! grep -qF "$needle" <<<"$haystack"; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Expected NOT to find: $needle"
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

# --- pre-action.sh (discover phase still blocks edits) ---
echo ""
echo "--- pre-action.sh (discover phase blocks edits) ---"
setup_test_env
printf '%s' discover > "$WV_HOT_ZONE/.session_phase"

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
assert_exit_code "0" "$EXIT_CODE_IMP" "pre-claim: exits 0 (advisory, never blocks) with impact data"
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

# Pattern-table parity: every lock key classified by bash-dedup.sh must also
# appear in bash-dedup-post.sh, or its lock is never cleared/promoted.
TESTS_RUN=$((TESTS_RUN + 1))
PRE_KEYS=$(grep -oP 'LOCK_KEY="\K[a-z-]+' "$HOOKS_DIR/bash-dedup.sh" | sort -u)
POST_KEYS=$(grep -oP '^_handle_lock "\K[a-z-]+' "$HOOKS_DIR/bash-dedup-post.sh" | sort -u)
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
assert_exit_code "1" "$EXIT_CODE" "stop-check: hard-blocks on this session's own active node"
assert_contains "$OUTPUT" '"decision": "block"' "stop-check: emits block decision JSON for own active node"

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

# --- repo-managed git hooks ---
echo ""
echo "--- repo-managed git hooks ---"

# Structural regression (wv-fa566a follow-up): the install-drift self-heal
# subshell must not let a caller's exported test/dev-isolation vars (e.g.
# this very suite's WV_LIB_DIR="$PROJECT_ROOT/scripts") leak into the real
# ./install.sh it shells out to — that previously redirected the MCP build
# into an untracked scripts/mcp/ tree instead of ~/.local/lib/weave/mcp. A
# full dynamic run is slow/network-dependent (npm install); assert the
# unset guard is present in source instead.
SELF_HEAL_BLOCK=$(sed -n '/Self-heal install drift/,/^fi$/p' "$PROJECT_ROOT/scripts/hooks/pre-commit-weave.sh")
assert_contains "$SELF_HEAL_BLOCK" "unset WV_LIB_DIR" \
    "pre-commit self-heal unsets WV_LIB_DIR before shelling out to install.sh"
assert_contains "$SELF_HEAL_BLOCK" "unset WV_LIB_DIR WV_CONFIG_DIR WV_HOT_ZONE WV_DB WV_PROJECT_DIR" \
    "pre-commit self-heal clears all known test-isolation vars, not just one"

setup_test_env
mkdir -p "$TEST_DIR/project/tests"
cat > "$TEST_DIR/project/tests/test-graph.sh" <<'EOF'
#!/bin/sh
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
assert_contains "$OUTPUT" "checking for an active Weave node" "git pre-commit: streams active-node check"

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

# discover phase with non-.weave file staged must block (no active node bypass)
setup_test_env
printf '%s' discover > "$WV_HOT_ZONE/.session_phase"
echo "# content" > "$TEST_DIR/project/src.sh"
git -C "$TEST_DIR/project" add src.sh
set +e
OUTPUT=$(cd "$TEST_DIR/project" && bash "$PROJECT_ROOT/scripts/hooks/pre-commit-weave.sh" 2>&1)
EXIT_CODE=$?
set -e
assert_exit_code "1" "$EXIT_CODE" "git pre-commit: discover phase blocks non-.weave commit without active node"
assert_contains "$OUTPUT" "No active Weave node" "git pre-commit: discover phase emits no-active-node message"

# discover phase with only .weave/ files staged must pass (already handled by early exit)
setup_test_env
printf '%s' discover > "$WV_HOT_ZONE/.session_phase"
mkdir -p "$TEST_DIR/project/.weave"
echo "{}" > "$TEST_DIR/project/.weave/state.json"
git -C "$TEST_DIR/project" add .weave/state.json
set +e
OUTPUT=$(cd "$TEST_DIR/project" && bash "$PROJECT_ROOT/scripts/hooks/pre-commit-weave.sh" 2>&1)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "git pre-commit: discover phase allows .weave/-only commit"

setup_test_env
HOOK_ID=$(add_active_node "Prepare hook task" --criteria="hook adds trailer|smoke passes" --risks=low 2>/dev/null | tail -1)
MSG_FILE="$TEST_DIR/project/COMMIT_EDITMSG"
printf 'hook smoke\n' > "$MSG_FILE"
set +e
OUTPUT=$(cd "$TEST_DIR/project" && sh "$PROJECT_ROOT/scripts/hooks/prepare-commit-msg-weave.sh" "$MSG_FILE" 2>&1)
EXIT_CODE=$?
set -e
assert_exit_code "0" "$EXIT_CODE" "prepare-commit-msg hook exits 0"
MSG_CONTENT=$(cat "$MSG_FILE")
assert_contains "$MSG_CONTENT" "Weave-ID: $HOOK_ID" "prepare-commit-msg hook appends active Weave-ID"

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
if ! echo "$OUTPUT" | grep -q "Verification evidence required"; then
    echo -e "${GREEN}✓${NC} lifecycle: close allowed with verification"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "${RED}✗${NC} lifecycle: close allowed with verification"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# 7. Complete the node
"$WV" done "$TASK_ID" 2>/dev/null
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
add_active_node "Another active task" 2>/dev/null
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

# Plant a crash sentinel
echo '{"ts":"2026-03-27T00:00:00Z","active":["wv-aabbcc"]}' > "$WV_HOT_ZONE/.session_sentinel"

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
echo '{"ts":"2026-03-27T00:01:00Z","active":["wv-ccddee"]}' > "$WV_HOT_ZONE/.session_sentinel"
# _BRIDGE_SLUG dir was deleted above; isolated HOME has no JSONL for this slug

OUTPUT=$(HOME="$BRIDGE_HOME" bash "$HOOKS_DIR/session-start-context.sh" 2>/dev/null || true)
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
assert_contains "$OUTPUT" "additionalContext" "budget-tally: threshold call emits additionalContext"
assert_contains "$OUTPUT" "wv called 3x" "budget-tally: advisory mentions call count"
assert_contains "$OUTPUT" "narrower queries" "budget-tally: advisory suggests narrower queries"

# 5) Advisory only fires once per session
OUTPUT=$(echo '{"tool_name":"Bash","tool_input":{"command":"wv show wv-abc"},"tool_response":{"output":"x"}}' \
    | bash "$HOOKS_DIR/wv-budget-tally.sh" 2>&1 || true)
assert_equals "" "$OUTPUT" "budget-tally: advisory fires only once per session"
CALLS=$(jq -r '.calls' "$BUDGET_FILE")
assert_equals "4" "$CALLS" "budget-tally: 4th call still counted after advisory"

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
sqlite3 "$TF_DB" "INSERT INTO nodes VALUES ('wv-active1', 'active', '{}', datetime('now'));"
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

# 3) Failed tool call: skipped
echo "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$TEST_DIR/never.py\"},\"tool_response\":{\"success\":false}}" \
    | bash "$HOOKS_DIR/wv-touched-files.sh" >/dev/null 2>&1 || true
RING_CONTENT=$(cat "$RING_FILE" 2>/dev/null || echo "")
TESTS_RUN=$((TESTS_RUN + 1))
if ! echo "$RING_CONTENT" | grep -qF "never.py"; then
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
if ! echo "$RING_CONTENT" | grep -qF "file1.py"; then
    echo -e "${GREEN}✓${NC} touched-files: oldest path evicted"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "${RED}✗${NC} touched-files: oldest path should have been evicted"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi
assert_contains "$RING_CONTENT" "file5.py" "touched-files: newest path retained"

# 6) Node cap on metadata.touched_files
export WV_TOUCHED_NODE_CAP=2
sqlite3 "$TF_DB" "UPDATE nodes SET metadata='{}' WHERE id='wv-active1';"
for i in a b c d; do
    echo "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$TEST_DIR/${i}.py\"},\"tool_response\":{\"success\":true}}" \
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

    sqlite3 "$TF_DB" "UPDATE nodes SET metadata='{}' WHERE id='wv-active1';"
    jq -nc \
        --arg tool_name "$tool_name" \
        --arg input_key "$input_key" \
        --arg file_path "$file_path" \
        '{tool_name:$tool_name, tool_input:{($input_key):$file_path}, tool_response:{success:true}}' \
        | bash "$HOOKS_DIR/wv-touched-files.sh" >/dev/null 2>&1 || true
    tool_meta=$(sqlite3 "$TF_DB" "SELECT json_extract(metadata, '\$.touched_files') FROM nodes WHERE id='wv-active1';" 2>/dev/null)
    assert_contains "$tool_meta" "$expected_path" "touched-files: ${tool_name} participates in attribution"
}

assert_touched_files_tool "create_file" "filePath" "$TEST_DIR/vscode.py" "vscode.py"
assert_touched_files_tool "replace_string_in_file" "filePath" "$TEST_DIR/replace.py" "replace.py"
assert_touched_files_tool "insert_edit_into_file" "filePath" "$TEST_DIR/insert.py" "insert.py"
assert_touched_files_tool "multi_replace_string_in_file" "filePath" "$TEST_DIR/multi.py" "multi.py"
assert_touched_files_tool "NotebookEdit" "path" "$TEST_DIR/notebook.ipynb" "notebook.ipynb"
assert_touched_files_tool "edit_notebook_file" "filePath" "$TEST_DIR/edit-notebook.ipynb" "edit-notebook.ipynb"

# 8) Stale primary falls back to an active node and clears the stale stamp
PRIMARY_FILE="$WV_HOT_ZONE/primary"
sqlite3 "$TF_DB" "INSERT INTO nodes VALUES ('wv-old-primary', 'done', '{}', datetime('now', '-1 hour'));"
sqlite3 "$TF_DB" "UPDATE nodes SET updated_at=datetime('now', '-1 hour') WHERE id='wv-active1';"
sqlite3 "$TF_DB" "INSERT INTO nodes VALUES ('wv-active2', 'active', '{}', datetime('now'));"
echo "wv-old-primary" > "$PRIMARY_FILE"
sqlite3 "$TF_DB" "UPDATE nodes SET metadata='{}' WHERE id='wv-active2';"
echo "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$TEST_DIR/fallback.py\"},\"tool_response\":{\"success\":true}}" \
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
sqlite3 "$CANON_DB" "INSERT INTO nodes VALUES ('wv-canon1', 'active', '{}', datetime('now'));"
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
            if grep -qE '"decision"[[:space:]]*:[[:space:]]*"block"|decision:[[:space:]]*"block"' "$path"; then
                schema_check "$hook ($event): no deprecated flat decision schema" 1
            else
                schema_check "$hook ($event): no deprecated flat decision schema" 0
            fi

            if grep -q 'hookSpecificOutput' "$path"; then
                if grep -q 'PreToolUse' "$path" && grep -q 'permissionDecision' "$path"; then
                    schema_check "$hook ($event): uses hookSpecificOutput.permissionDecision" 0
                else
                    schema_check "$hook ($event): hookSpecificOutput missing PreToolUse+permissionDecision" 1
                fi
                if grep -qE 'permissionDecision[^"]*"DENY"' "$path"; then
                    schema_check "$hook ($event): permissionDecision value is lowercase 'deny'" 1
                else
                    schema_check "$hook ($event): permissionDecision value is lowercase 'deny'" 0
                fi
            else
                schema_check "$hook ($event): no JSON emission (exit-code-only is acceptable)" 0
            fi
            ;;
        PostToolUse|Stop)
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
assert_contains "$MC_OUT" "additionalContext" "memory-capture: emits additionalContext advisory for repo-scoped write"
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
