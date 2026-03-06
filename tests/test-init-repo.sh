#!/usr/bin/env bash
# test-init-repo.sh — Tests for wv init-repo subcommand
#
# Verifies that wv init-repo delegates to standalone wv-init-repo and
# creates the correct scaffolding: .claude/settings.json (permissions only,
# no hooks key), CLAUDE.md, and --agent=copilot generates VS Code/GitHub files.
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
WV="$PROJECT_ROOT/scripts/wv"

# Test environment
TEST_DIR="/tmp/wv-init-repo-test-$$"
export WV_HOT_ZONE="$TEST_DIR/hotzone"
export WV_DB="$TEST_DIR/hotzone/brain.db"

cleanup() {
    cd /tmp
    [ -d "$TEST_DIR" ] && rm -rf "$TEST_DIR"
    # Clean up any hot zones created by test repos
    for d in /dev/shm/weave/*/; do
        [ -d "$d" ] || continue
        # Only remove hot zones created during this test run (by path hash)
        local db="$d/brain.db"
        [ -f "$db" ] || rm -rf "$d" 2>/dev/null || true
    done
}
trap cleanup EXIT

# ── Helpers ──────────────────────────────────────────────────────────────────

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
        echo "  In: $(echo "$haystack" | head -5)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if ! echo "$haystack" | grep -qF "$needle"; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Did NOT expect to find: $needle"
        echo "  But found it in: $(echo "$haystack" | head -5)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_file_exists() {
    local path="$1"
    local message="$2"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ -f "$path" ]; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $message"
        echo "  File not found: $path"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_file_absent() {
    local path="$1"
    local message="$2"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ ! -f "$path" ]; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $message"
        echo "  File unexpectedly exists: $path"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# Create a fresh isolated git repo for each test group
make_test_repo() {
    local repo_path="$TEST_DIR/$1"
    mkdir -p "$repo_path"
    cd "$repo_path"
    git init -q
    git config commit.gpgsign false
    echo "$repo_path"
}

# ── Tests ─────────────────────────────────────────────────────────────────────

echo "=== Init-Repo Tests ==="
echo ""

# --- Basic creation in fresh repo (default: --agent=claude) ---
echo "--- basic creation (claude) ---"
REPO=$(make_test_repo "fresh")
cd "$REPO"

OUTPUT=$("$WV" init-repo 2>&1)
assert_file_exists "$REPO/.claude/settings.json"            "creates .claude/settings.json"
assert_file_exists "$REPO/CLAUDE.md"                        "copies CLAUDE.md from template"
assert_file_exists "$REPO/.claude/settings.local.json"      "creates settings.local.json"
assert_contains "$OUTPUT" "Weave"                           "output mentions Weave"

# --- settings.json content: no hooks key ---
echo ""
echo "--- settings.json schema ---"
SETTINGS=$(cat "$REPO/.claude/settings.json")
assert_contains "$SETTINGS" '"permissions"'                 "settings.json has permissions key"
assert_contains "$SETTINGS" '"allow"'                       "settings.json has allow array"
assert_contains "$SETTINGS" '"Write"'                       "settings.json allows Write"
assert_contains "$SETTINGS" '"Edit"'                        "settings.json allows Edit"
assert_not_contains "$SETTINGS" '"hooks"'                   "settings.json has NO hooks key (Alt-A)"

# Verify it's valid JSON with correct allow entries
PARSED=$(echo "$SETTINGS" | jq -r '.permissions.allow | length' 2>/dev/null || echo "INVALID")
assert_equals "2"  "$PARSED"                                "settings.json is valid JSON with 2 allow entries"

# --- skip existing files (no --force) ---
echo ""
echo "--- skip-existing without --force ---"
REPO2=$(make_test_repo "existing")
cd "$REPO2"
mkdir -p "$REPO2/.claude"
echo '{"hooks":{}}' > "$REPO2/.claude/settings.json"
echo "existing content" > "$REPO2/CLAUDE.md"

OUTPUT=$("$WV" init-repo 2>&1)
assert_contains "$OUTPUT" "exists"                          "mentions existing files"
assert_equals "existing content" "$(cat "$REPO2/CLAUDE.md")"  "preserves existing CLAUDE.md"

# --- --force overwrites ---
echo ""
echo "--- --force overwrites ---"
OUTPUT=$("$WV" init-repo --force 2>&1)
SETTINGS2=$(cat "$REPO2/.claude/settings.json")
assert_not_contains "$SETTINGS2" '"hooks"'                  "--force: overwrites hooks-polluted settings.json"
assert_contains "$SETTINGS2" '"permissions"'                "--force: new settings.json has permissions"

# --- --agent=copilot creates VS Code + GitHub files ---
echo ""
echo "--- --agent=copilot ---"
REPO3=$(make_test_repo "copilot")
cd "$REPO3"

OUTPUT=$("$WV" init-repo --agent=copilot 2>&1)
assert_file_exists "$REPO3/.vscode/mcp.json"                "copilot: creates .vscode/mcp.json"
assert_file_exists "$REPO3/.github/copilot-instructions.md" "copilot: creates copilot-instructions.md"
assert_file_exists "$REPO3/.github/hooks/README.md"         "copilot: scaffolds .github/hooks/"

# Verify mcp.json points to MCP server
MCP_JSON=$(cat "$REPO3/.vscode/mcp.json")
assert_contains "$MCP_JSON" '"weave"'                       "copilot: mcp.json has weave server"
assert_contains "$MCP_JSON" 'index.js'                      "copilot: mcp.json points to index.js"

# Verify ghost setting is NOT written
if [ -f "$REPO3/.vscode/settings.json" ]; then
    VS_SETTINGS=$(cat "$REPO3/.vscode/settings.json")
    assert_not_contains "$VS_SETTINGS" 'chat.hooks.enabled' "copilot: NO ghost setting in .vscode/settings.json"
else
    TESTS_PASSED=$((TESTS_PASSED + 1)); echo -e "${GREEN}✓${NC} copilot: .vscode/settings.json not created (ghost setting removed)"
fi

# Verify copilot-instructions is minimal stub (not workflow dump)
COPILOT=$(cat "$REPO3/.github/copilot-instructions.md")
assert_contains "$COPILOT" "Weave"                          "copilot: instructions mention Weave"
assert_contains "$COPILOT" "weave_edit_guard"               "copilot: instructions include edit guard"
assert_contains "$COPILOT" "weave_guide"                    "copilot: instructions reference weave_guide"
assert_not_contains "$COPILOT" "MCP Tools (31 total)"       "copilot: stub does NOT contain MCP tools dump"
assert_not_contains "$COPILOT" "Session Start (MANDATORY)"  "copilot: stub does NOT contain workflow commands"

# copilot-only should NOT create claude-specific files
assert_file_absent "$REPO3/CLAUDE.md"                       "copilot-only: no CLAUDE.md"
assert_file_absent "$REPO3/.claude/settings.json"           "copilot-only: no .claude/settings.json"

# --- --agent=all creates both ---
echo ""
echo "--- --agent=all ---"
REPO4=$(make_test_repo "all")
cd "$REPO4"

OUTPUT=$("$WV" init-repo --agent=all 2>&1)
assert_file_exists "$REPO4/.claude/settings.json"           "all: creates .claude/settings.json"
assert_file_exists "$REPO4/CLAUDE.md"                       "all: creates CLAUDE.md"
assert_file_exists "$REPO4/.vscode/mcp.json"                "all: creates .vscode/mcp.json"
assert_file_exists "$REPO4/.github/copilot-instructions.md" "all: creates copilot-instructions.md"

# settings.json still has no hooks key
SETTINGS4=$(cat "$REPO4/.claude/settings.json")
assert_not_contains "$SETTINGS4" '"hooks"'                  "all: settings.json has NO hooks key"

# --- --update refreshes managed files ---
echo ""
echo "--- --update ---"
REPO5=$(make_test_repo "update")
cd "$REPO5"

# First init
"$WV" init-repo --agent=all 2>&1 >/dev/null

# Corrupt copilot-instructions to verify update overwrites it
echo "stale" > "$REPO5/.github/copilot-instructions.md"

OUTPUT=$("$WV" init-repo --agent=all --update 2>&1)
COPILOT5=$(cat "$REPO5/.github/copilot-instructions.md")
assert_contains "$COPILOT5" "Weave"                         "--update: refreshes copilot-instructions.md"

# --update should strip ghost setting from .vscode/settings.json
if [ -d "$REPO5/.vscode" ]; then
    echo '{"chat.hooks.enabled": true, "other.setting": 42}' > "$REPO5/.vscode/settings.json"
    "$WV" init-repo --agent=copilot --update 2>&1 >/dev/null
    if [ -f "$REPO5/.vscode/settings.json" ]; then
        VS5=$(cat "$REPO5/.vscode/settings.json")
        assert_not_contains "$VS5" 'chat.hooks.enabled'     "--update: strips ghost setting from .vscode/settings.json"
    else
        TESTS_PASSED=$((TESTS_PASSED + 1)); echo -e "${GREEN}✓${NC} --update: .vscode/settings.json cleaned up"
    fi
fi

# --update should prepend Weave block but preserve user content
echo "my custom content" > "$REPO5/CLAUDE.md"
"$WV" init-repo --update 2>&1 >/dev/null
assert_contains "$(cat "$REPO5/CLAUDE.md")" "WEAVE-BLOCK-START"  "--update: prepends Weave block to CLAUDE.md"
assert_contains "$(cat "$REPO5/CLAUDE.md")" "my custom content"  "--update: preserves user content in CLAUDE.md"

# --- --help works ---
echo ""
echo "--- help ---"
HELP=$("$WV" init-repo --help 2>&1 || true)
assert_contains "$HELP" "agent"                             "--help: mentions agent flag"
assert_contains "$HELP" "copilot"                           "--help: mentions copilot"
assert_contains "$HELP" "update"                            "--help: mentions update"

# --- help text includes init-repo ---
echo ""
echo "--- help registration ---"
HELP=$("$WV" --help 2>&1 || true)
assert_contains "$HELP" "init-repo"                         "wv --help lists init-repo command"

# ─────────────────────────────────────────────────────────────────────────────
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
