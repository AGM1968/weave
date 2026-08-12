#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# test-init-repo.sh — Tests for wv init-repo subcommand
#
# Verifies that wv init-repo delegates to standalone wv-init-repo and
# creates the correct scaffolding: .claude/settings.json (permissions only,
# no hooks key), CLAUDE.md, --agent=copilot generates VS Code/GitHub files,
# and --agent=codex generates the Codex setup contract.
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

# Build the generated init tool and installed assets from this checkout. This
# prevents the suite from passing against an unrelated user installation.
TEST_INSTALL="$TEST_DIR/install"
mkdir -p "$TEST_INSTALL/home" "$TEST_INSTALL/bin" "$TEST_INSTALL/lib" "$TEST_INSTALL/config"
HOME="$TEST_INSTALL/home" \
CLAUDE_CONFIG_DIR="$TEST_INSTALL/home/.claude" \
WV_INSTALL_DIR="$TEST_INSTALL/bin" \
WV_LIB_DIR="$TEST_INSTALL/lib" \
WV_CONFIG_DIR="$TEST_INSTALL/config" \
    bash "$PROJECT_ROOT/install.sh" >/dev/null
export WV_INSTALL_DIR="$TEST_INSTALL/bin"
export WV_LIB_DIR="$TEST_INSTALL/lib"
export WV_CONFIG_DIR="$TEST_INSTALL/config"
export PATH="$TEST_INSTALL/bin:$PATH"

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
    if echo "$haystack" | grep -qF -- "$needle"; then
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
    if ! echo "$haystack" | grep -qF -- "$needle"; then
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

# wv-cccf70: the scaffolded CLAUDE.md used to ship a "./scripts/wv" wv()
# fallback verbatim -- that path only exists in weave's own source repo,
# never in a scaffolded consumer repo, so the fallback silently failed
# outright instead of falling back. Must now point at the actual global
# install location instead.
assert_not_contains "$(cat "$REPO/CLAUDE.md")" './scripts/wv"' \
    "scaffolded CLAUDE.md does not ship the dead ./scripts/wv fallback"
assert_contains "$(cat "$REPO/CLAUDE.md")" '$HOME/.local/bin/wv' \
    "scaffolded CLAUDE.md wv() fallback points at the real global install path"
assert_file_exists "$REPO/.claude/settings.local.json"      "creates settings.local.json"
assert_file_exists "$REPO/.weave/runtime.md"                "creates .weave/runtime.md scaffold"
assert_file_exists "$REPO/.weave/patterns/managed/.manifest" "creates managed pattern manifest"
assert_file_exists "$REPO/.weave/patterns/managed/prose-filler-phrases.yaml" "projects curated prose rules"
assert_file_exists "$REPO/.git/hooks/pre-commit"            "installs actual pre-commit hook entrypoint"
assert_file_exists "$REPO/.git/hooks/post-commit"           "installs actual post-commit hook entrypoint"
assert_file_exists "$REPO/.git/hooks/prepare-commit-msg"    "installs actual prepare-commit-msg hook entrypoint"
assert_file_absent "$REPO/.git/hooks/pre-commit-weave.sh"   "does not install source filename as git hook entrypoint"
assert_contains "$(cat "$REPO/.weave/runtime.md")" "Agent Runtime Notes" "runtime.md includes agent runtime notes"
assert_contains "$(cat "$REPO/.weave/runtime.md")" "/tmp/weave-codex-*" "runtime.md documents Codex hot zone"
assert_contains "$(cat "$REPO/.git/hooks/pre-commit")" "_pc_pytest_dirs" "pre-commit hook has optional pytest-dir guard"
assert_contains "$(cat "$REPO/.gitignore")" ".weave/.context_policy" "adds .weave/.context_policy to .gitignore"
assert_contains "$OUTPUT" "Weave"                           "output mentions Weave"

PATTERN_CONFIG="${WV_CONFIG_DIR:-$HOME/.config/weave}/quality-patterns/managed"
if diff -qr "$PROJECT_ROOT/templates/quality-patterns/managed" "$PATTERN_CONFIG" >/dev/null 2>&1; then
    TESTS_RUN=$((TESTS_RUN + 1)); TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}✓${NC} installed managed pattern assets match canonical source"
else
    TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}✗${NC} installed managed pattern assets match canonical source"
fi

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
assert_file_exists "$REPO3/.mcp.json"                       "copilot: creates .mcp.json"
assert_file_exists "$REPO3/.github/copilot-instructions.md" "copilot: creates copilot-instructions.md"
assert_file_exists "$REPO3/.github/hooks/README.md"         "copilot: scaffolds .github/hooks/"
assert_file_exists "$REPO3/.weave/runtime.md"               "copilot: creates .weave/runtime.md scaffold"

# Verify mcp.json points to MCP server and uses VS Code 'servers' key (not 'mcpServers')
MCP_JSON=$(cat "$REPO3/.mcp.json")
assert_contains "$MCP_JSON" '"weave"'                       "copilot: mcp.json has weave server"
assert_contains "$MCP_JSON" '"weave-session"'               "copilot: mcp.json has weave-session server"
assert_contains "$MCP_JSON" '"weave-lite"'                  "copilot: mcp.json has weave-lite server"
assert_contains "$MCP_JSON" '"weave-inspect"'               "copilot: mcp.json has weave-inspect server"
assert_not_contains "$MCP_JSON" '"weave-graph"'             "copilot: mcp.json does not ship weave-graph"
assert_contains "$MCP_JSON" 'index.js'                      "copilot: mcp.json points to index.js"
assert_contains "$MCP_JSON" '"WV_AGENT_ID"'                 "copilot: mcp.json pins explicit Weave agent identity"
assert_contains "$MCP_JSON" 'copilot-${workspaceFolderBasename}' "copilot: mcp.json uses workspace-scoped Copilot identity"
assert_not_contains "$MCP_JSON" '"mcpServers"'              "copilot: mcp.json uses 'servers' not 'mcpServers'"
assert_not_contains "$MCP_JSON" '"inputs"'                  "copilot: mcp.json has no 'inputs' key"
SERVER_COUNT=$(jq '.servers | keys | length' "$REPO3/.mcp.json")
assert_equals "4" "$SERVER_COUNT"                           "copilot: mcp.json ships exactly four servers"

# Verify ghost setting is NOT written
if [ -f "$REPO3/.vscode/settings.json" ]; then
    VS_SETTINGS=$(cat "$REPO3/.vscode/settings.json")
    assert_not_contains "$VS_SETTINGS" 'chat.hooks.enabled' "copilot: NO ghost setting in .vscode/settings.json"
else
    TESTS_RUN=$((TESTS_RUN + 1)); TESTS_PASSED=$((TESTS_PASSED + 1)); echo -e "${GREEN}✓${NC} copilot: .vscode/settings.json not created (ghost setting removed)"
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

# --- --agent=codex creates Codex contract only ---
echo ""
echo "--- --agent=codex ---"
REPO_CODEX=$(make_test_repo "codex")
cd "$REPO_CODEX"
echo "universal" > "$REPO_CODEX/AGENTS.md"

OUTPUT=$("$WV" init-repo --agent=codex 2>&1)
assert_file_exists "$REPO_CODEX/.codex/weave.json"           "codex: creates .codex/weave.json"
assert_file_exists "$REPO_CODEX/.weave/runtime.md"           "codex: creates .weave/runtime.md scaffold"

CODEX_JSON=$(cat "$REPO_CODEX/.codex/weave.json")
assert_contains "$CODEX_JSON" '"schema": "weave.codex.v1"'   "codex: contract has schema"
assert_contains "$CODEX_JSON" '"universal_instructions": "AGENTS.md"' "codex: contract points at universal AGENTS.md"
assert_contains "$CODEX_JSON" '"noninteractive_close": "./scripts/wv ship-agent"' "codex: contract names repo-local ship-agent close"
assert_contains "$CODEX_JSON" '"local_first": "./scripts/wv sync"' "codex: contract names local-first sync"
assert_contains "$CODEX_JSON" '"external_network": "./scripts/wv sync --gh"' "codex: contract names external GitHub sync"
assert_contains "$CODEX_JSON" '"requires_sandbox_approval": true' "codex: contract marks GitHub sync approval"
assert_contains "$CODEX_JSON" '"fallback": "$HOME/.local/bin/wv bootstrap-agent --json"' "codex: bootstrap fallback is portable"
assert_contains "$CODEX_JSON" '"authority": "weave-graph"' "codex: memory contract marks graph authority"
assert_contains "$CODEX_JSON" '"command": "./scripts/wv memory recall --agent=all --json"' "codex: memory recall is graph-wide"
assert_contains "$CODEX_JSON" '"command": "./scripts/wv memory scan --source=codex --json"' "codex: memory scan names Codex evidence source"
assert_contains "$CODEX_JSON" '"command": "./scripts/wv memory import --source=codex --json"' "codex: memory import names Codex candidate import"
assert_contains "$CODEX_JSON" '"claim": "./scripts/wv work <id>"' "codex: contract includes safe claim command"
assert_contains "$CODEX_JSON" '"record_edit": "./scripts/wv touch <id> --files=<path>"' "codex: contract includes safe edit attribution command"
assert_contains "$CODEX_JSON" '"default_registration": "weave-lite"' "codex: contract names lite MCP default"
assert_contains "$CODEX_JSON" '"full_requires": "--codex-mcp=full"' "codex: contract requires explicit full MCP"
assert_contains "$CODEX_JSON" "Use CLI for GitHub sync" "codex: contract keeps network operations on CLI"
assert_contains "$OUTPUT" 'codex mcp: skipped (use --codex-mcp to register weave-lite)' "codex: MCP registration is opt-in"
assert_contains "$OUTPUT" 'codex hooks: skipped (use --codex-hooks to generate for review)' "codex: hooks are opt-in"
assert_file_absent "$REPO_CODEX/.codex/hooks.json"             "codex: default init does not generate hooks"
assert_contains "$CODEX_JSON" '"enabled": 0'                 "codex: default contract records hooks disabled"
assert_contains "$CODEX_JSON" 'bootstrap-agent --json'       "codex: contract names bootstrap-agent"
assert_contains "$CODEX_JSON" 'doctor --agent --json'        "codex: contract names agent doctor"
CODEX_SCHEMA=$(jq -r '.schema' "$REPO_CODEX/.codex/weave.json")
assert_equals "weave.codex.v1" "$CODEX_SCHEMA"               "codex: contract is valid JSON"

assert_equals "universal" "$(cat "$REPO_CODEX/AGENTS.md")"   "codex: preserves existing AGENTS.md"
assert_file_absent "$REPO_CODEX/CLAUDE.md"                   "codex-only: no CLAUDE.md"
assert_file_absent "$REPO_CODEX/.claude/settings.json"       "codex-only: no .claude/settings.json"
assert_file_absent "$REPO_CODEX/.github/copilot-instructions.md" "codex-only: no copilot-instructions.md"

printf '%s\n' '{"schema":"stale"}' > "$REPO_CODEX/.codex/weave.json"
"$WV" init-repo --agent=codex --update 2>&1 >/dev/null
CODEX_SCHEMA=$(jq -r '.schema' "$REPO_CODEX/.codex/weave.json")
assert_equals "weave.codex.v1" "$CODEX_SCHEMA"               "codex: --update refreshes contract"

printf '%s\n' '{"custom":true}' > "$REPO_CODEX/.codex/weave.json"
"$WV" init-repo --agent=codex --force 2>&1 >/dev/null
CODEX_SCHEMA=$(jq -r '.schema' "$REPO_CODEX/.codex/weave.json")
assert_equals "weave.codex.v1" "$CODEX_SCHEMA"               "codex: --force refreshes contract"

FAKE_BIN="$TEST_DIR/fake-bin"
mkdir -p "$FAKE_BIN"
mkdir -p "$REPO_CODEX/mcp/dist"
printf '%s\n' '/* fake mcp bundle */' > "$REPO_CODEX/mcp/dist/index.js"
cat > "$FAKE_BIN/codex" <<'CODEXFAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CODEX_MCP_LOG"
if [ "$1" = "mcp" ] && [ "$2" = "list" ]; then
    printf '%s\n' 'Name   Command  Args'
    printf '%s\n' 'weave  node     /tmp/weave/mcp/dist/index.js'
fi
CODEXFAKE
chmod +x "$FAKE_BIN/codex"
CODEX_MCP_LOG="$TEST_DIR/codex-mcp.log" PATH="$FAKE_BIN:$PATH" \
    "$WV" init-repo --agent=codex --force --codex-mcp 2>&1 >/dev/null
assert_contains "$(cat "$TEST_DIR/codex-mcp.log")" "mcp remove weave" "codex: --codex-mcp prunes stale full MCP registration"
assert_contains "$(cat "$TEST_DIR/codex-mcp.log")" "mcp add weave-lite" "codex: --codex-mcp registers lite MCP by default"
assert_contains "$(cat "$TEST_DIR/codex-mcp.log")" "--scope=lite" "codex: default MCP registration uses lite scope"

CODEX_MCP_LOG="$TEST_DIR/codex-mcp-full.log" PATH="$FAKE_BIN:$PATH" \
    "$WV" init-repo --agent=codex --force --codex-mcp=full 2>&1 >/dev/null
assert_contains "$(cat "$TEST_DIR/codex-mcp-full.log")" "mcp add weave" "codex: full MCP registration is explicit"
assert_contains "$(cat "$TEST_DIR/codex-mcp-full.log")" "--scope=all" "codex: full MCP registration uses all scope"

OUTPUT=$("$WV" init-repo --agent=codex --force --codex-hooks 2>&1)
assert_file_exists "$REPO_CODEX/.codex/hooks.json"             "codex: --codex-hooks generates project hooks"
assert_contains "$(cat "$REPO_CODEX/.codex/hooks.json")" '"PreToolUse"' "codex: hook config includes edit guard"
assert_contains "$(cat "$REPO_CODEX/.codex/hooks.json")" 'hook dispatch --event=PostToolUse --json' "codex: hook config calls shared dispatcher"
assert_contains "$(cat "$REPO_CODEX/.codex/weave.json")" '"enabled": 1' "codex: opt-in contract records hooks enabled"
assert_contains "$OUTPUT" 'Review and trust these project hooks with /hooks' "codex: opt-in prints trust guidance"

# --- --agent=all creates all supported agent surfaces ---
echo ""
echo "--- --agent=all ---"
REPO4=$(make_test_repo "all")
cd "$REPO4"

OUTPUT=$("$WV" init-repo --agent=all 2>&1)
assert_file_exists "$REPO4/.claude/settings.json"           "all: creates .claude/settings.json"
assert_file_exists "$REPO4/CLAUDE.md"                       "all: creates CLAUDE.md"
assert_file_exists "$REPO4/.mcp.json"                       "all: creates .mcp.json"
assert_file_exists "$REPO4/.github/copilot-instructions.md" "all: creates copilot-instructions.md"
assert_file_exists "$REPO4/.codex/weave.json"               "all: creates Codex contract"

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

# A project-owned top-level rule must survive managed updates unchanged.
mkdir -p "$REPO5/.weave/patterns"
printf 'id: project-local\nlanguage: prose\nkind: regex\npatterns:\n  - local\n' \
    > "$REPO5/.weave/patterns/project-local.yaml"
printf 'id: prose-ai-vocabulary\nlanguage: prose\nkind: lexicon\nterms:\n  - localterm\n' \
    > "$REPO5/.weave/patterns/prose-ai-vocabulary.yaml"

# Simulate a stale previously-managed rule and a stale current rule.
printf 'stale\n' > "$REPO5/.weave/patterns/managed/removed-rule.yaml"
printf 'removed-rule.yaml\n' >> "$REPO5/.weave/patterns/managed/.manifest"
printf 'stale current content\n' \
    > "$REPO5/.weave/patterns/managed/prose-filler-phrases.yaml"

# Corrupt copilot-instructions to verify update overwrites it
echo "stale" > "$REPO5/.github/copilot-instructions.md"

OUTPUT=$("$WV" init-repo --agent=all --update 2>&1)
COPILOT5=$(cat "$REPO5/.github/copilot-instructions.md")
assert_contains "$COPILOT5" "Weave"                         "--update: refreshes copilot-instructions.md"
assert_file_absent "$REPO5/.weave/patterns/managed/removed-rule.yaml" \
    "--update: prunes only stale manifest-owned patterns"
assert_contains "$(cat "$REPO5/.weave/patterns/managed/prose-filler-phrases.yaml")" \
    "Filler phrase" "--update: refreshes managed pattern content"
assert_contains "$(cat "$REPO5/.weave/patterns/project-local.yaml")" \
    "project-local" "--update: preserves project-local patterns"
assert_contains "$(cat "$REPO5/.weave/patterns/prose-ai-vocabulary.yaml")" \
    "localterm" "--update: preserves a project-local managed-ID override"
assert_file_absent "$REPO5/.weave/patterns/managed/prose-ai-vocabulary.yaml" \
    "--update: does not duplicate a project-local override in managed rules"
assert_contains "$(cat "$REPO5/.weave/patterns/managed/.overridden")" \
    "prose-ai-vocabulary.yaml" \
    "--update: records the shadowed managed rule id in .overridden"
PATTERN_HASH_BEFORE=$(find "$REPO5/.weave/patterns" -type f -print0 | sort -z | xargs -0 sha256sum)
"$WV" init-repo --agent=all --update 2>&1 >/dev/null
PATTERN_HASH_AFTER=$(find "$REPO5/.weave/patterns" -type f -print0 | sort -z | xargs -0 sha256sum)
assert_equals "$PATTERN_HASH_BEFORE" "$PATTERN_HASH_AFTER" \
    "--update: managed pattern projection is idempotent"

# Invalid prior manifests and symlinked destinations fail before mutation.
REPO_PATTERN_BAD=$(make_test_repo "pattern-invalid-manifest")
cd "$REPO_PATTERN_BAD"
"$WV" init-repo --agent=claude >/dev/null 2>&1
KNOWN_PATTERN="$REPO_PATTERN_BAD/.weave/patterns/managed/prose-filler-phrases.yaml"
KNOWN_PATTERN_HASH=$(sha256sum "$KNOWN_PATTERN" | awk '{print $1}')
printf '../escape.yaml\n' > "$REPO_PATTERN_BAD/.weave/patterns/managed/.manifest"
if "$WV" init-repo --agent=claude --update >/dev/null 2>&1; then
    assert_equals "failure" "success" "--update: rejects unsafe prior pattern manifest"
else
    assert_equals "$KNOWN_PATTERN_HASH" "$(sha256sum "$KNOWN_PATTERN" | awk '{print $1}')" \
        "--update: invalid manifest fails before managed files mutate"
fi

REPO_PATTERN_LINK=$(make_test_repo "pattern-symlink")
cd "$REPO_PATTERN_LINK"
mkdir -p .weave "$TEST_DIR/pattern-external"
ln -s "$TEST_DIR/pattern-external" .weave/patterns
if "$WV" init-repo --agent=claude >/dev/null 2>&1; then
    assert_equals "failure" "success" "init: rejects symlinked pattern destination"
else
    assert_equals "0" "$(find "$TEST_DIR/pattern-external" -mindepth 1 | wc -l)" \
        "init: symlink rejection does not write outside repository"
fi

REPO_WEAVE_LINK=$(make_test_repo "weave-symlink")
cd "$REPO_WEAVE_LINK"
rm -rf .weave
mkdir -p "$TEST_DIR/weave-external"
ln -s "$TEST_DIR/weave-external" .weave
if "$WV" init-repo --agent=claude >/dev/null 2>&1; then
    assert_equals "failure" "success" "init: rejects symlinked .weave ancestor"
else
    assert_equals "0" "$(find "$TEST_DIR/weave-external" -mindepth 1 | wc -l)" \
        "init: .weave symlink rejection does not write outside repository"
fi

# Installed bundle corruption and truncated manifests must fail before an
# existing project's managed rules change.
cd "$REPO5"
SOURCE_MANIFEST="$PATTERN_CONFIG/manifest.txt"
SOURCE_MANIFEST_BACKUP=$(cat "$SOURCE_MANIFEST")
KNOWN_REPO_PATTERN="$REPO5/.weave/patterns/managed/prose-filler-phrases.yaml"
KNOWN_REPO_HASH=$(sha256sum "$KNOWN_REPO_PATTERN" | awk '{print $1}')
printf '%s' "$SOURCE_MANIFEST_BACKUP" > "$SOURCE_MANIFEST"
if "$WV" init-repo --agent=all --update >/dev/null 2>&1; then
    assert_equals "failure" "success" "--update: rejects unterminated source manifest"
else
    assert_equals "$KNOWN_REPO_HASH" "$(sha256sum "$KNOWN_REPO_PATTERN" | awk '{print $1}')" \
        "--update: truncated source manifest fails before mutation"
fi
printf '%s\n' "$SOURCE_MANIFEST_BACKUP" > "$SOURCE_MANIFEST"

SOURCE_RULE="$PATTERN_CONFIG/prose-filler-phrases.yaml"
SOURCE_RULE_BACKUP=$(cat "$SOURCE_RULE")
printf 'id: malformed\n' > "$SOURCE_RULE"
if "$WV" init-repo --agent=all --update >/dev/null 2>&1; then
    assert_equals "failure" "success" "--update: rejects corrupted installed pattern"
else
    assert_equals "$KNOWN_REPO_HASH" "$(sha256sum "$KNOWN_REPO_PATTERN" | awk '{print $1}')" \
        "--update: corrupted installed pattern fails before mutation"
fi
printf '%s\n' "$SOURCE_RULE_BACKUP" > "$SOURCE_RULE"
cd "$REPO5"

# --update should strip ghost setting from .vscode/settings.json
if [ -d "$REPO5/.vscode" ]; then
    echo '{"chat.hooks.enabled": true, "other.setting": 42}' > "$REPO5/.vscode/settings.json"
    "$WV" init-repo --agent=copilot --update 2>&1 >/dev/null
    if [ -f "$REPO5/.vscode/settings.json" ]; then
        VS5=$(cat "$REPO5/.vscode/settings.json")
        assert_not_contains "$VS5" 'chat.hooks.enabled'     "--update: strips ghost setting from .vscode/settings.json"
    else
        TESTS_RUN=$((TESTS_RUN + 1)); TESTS_PASSED=$((TESTS_PASSED + 1)); echo -e "${GREEN}✓${NC} --update: .vscode/settings.json cleaned up"
    fi
fi

# --update should prepend Weave block but preserve user content
echo "my custom content" > "$REPO5/CLAUDE.md"
"$WV" init-repo --update 2>&1 >/dev/null
assert_contains "$(cat "$REPO5/CLAUDE.md")" "BEGIN WEAVE CLAUDE.MD"  "--update: prepends Weave block to CLAUDE.md"
assert_contains "$(cat "$REPO5/CLAUDE.md")" "my custom content"  "--update: preserves user content in CLAUDE.md"

# Pre-marker Weave stub: --update should add markers without losing custom content.
# Simulates upgrading a repo that has an old-style Weave stub without BEGIN/END markers.
PRE_MARKER_STUB='# GitHub Copilot Instructions

git status && wv status
wv work <id>
If 0 active nodes, use wv status to find active node first.

## Repo-specific Copilot Notes

Keep this custom instruction.'
printf '%s\n' "$PRE_MARKER_STUB" > "$REPO5/.github/copilot-instructions.md"
"$WV" init-repo --agent=copilot --update 2>&1 >/dev/null
COPILOT_PM=$(cat "$REPO5/.github/copilot-instructions.md")
assert_contains "$COPILOT_PM" "BEGIN WEAVE COPILOT.MD"      "--update pre-marker: adds markers"
assert_contains "$COPILOT_PM" "Keep this custom instruction." "--update pre-marker: preserves custom content"
assert_contains "$COPILOT_PM" "If 0 active nodes, use wv status to find active node first." \
    "--update pre-marker: preserves legacy unmarked content"

# --- --help works ---
echo ""
echo "--- help ---"
HELP=$("$WV" init-repo --help 2>&1 || true)
assert_contains "$HELP" "agent"                             "--help: mentions agent flag"
assert_contains "$HELP" "copilot"                           "--help: mentions copilot"
assert_contains "$HELP" "codex"                             "--help: mentions codex"
assert_contains "$HELP" "update"                            "--help: mentions update"

# --- help text includes init-repo ---
echo ""
echo "--- help registration ---"
HELP=$("$WV" --help 2>&1 || true)
assert_contains "$HELP" "init-repo"                         "wv --help lists init-repo command"

# --- .gitattributes: fresh repo gets marker block ---
echo ""
echo "--- gitattributes: fresh ---"
REPO6=$(make_test_repo "gitattr-fresh")
cd "$REPO6"
"$WV" init-repo --agent=claude >/dev/null 2>&1
assert_file_exists "$REPO6/.gitattributes"                                "gitattr: creates .gitattributes"
assert_contains "$(cat "$REPO6/.gitattributes")" "BEGIN WEAVE GITATTRIBUTES" "gitattr: has BEGIN marker"
assert_contains "$(cat "$REPO6/.gitattributes")" "END WEAVE GITATTRIBUTES"   "gitattr: has END marker"
assert_contains "$(cat "$REPO6/.gitattributes")" "-diff linguist-generated"  "gitattr: has -diff flag"
assert_contains "$(cat "$REPO6/.gitattributes")" "state.sql.txt-dump"        "gitattr: has txt-dump entry"
assert_contains "$(cat "$REPO6/.gitattributes")" "deltas/**/*.sql merge=theirs" "gitattr: has deltas merge=theirs"

# --- .gitattributes: upgrade bare entries to marker block ---
echo ""
echo "--- gitattributes: upgrade ---"
REPO7=$(make_test_repo "gitattr-upgrade")
cd "$REPO7"
# Write old-style bare entries (what wv-init-repo <v1.23.0 generated)
cat > "$REPO7/.gitattributes" << 'GITEOF'
# Weave: latest local dump always wins (DB is source of truth)
.weave/state.sql merge=ours
.weave/nodes.jsonl merge=ours
.weave/edges.jsonl merge=ours
GITEOF
"$WV" init-repo --update --agent=claude >/dev/null 2>&1
GA7=$(cat "$REPO7/.gitattributes")
assert_contains "$GA7" "BEGIN WEAVE GITATTRIBUTES"    "gitattr upgrade: has BEGIN marker"
assert_contains "$GA7" "-diff linguist-generated"      "gitattr upgrade: has -diff flag"
assert_contains "$GA7" "deltas/**/*.sql merge=theirs"  "gitattr upgrade: has deltas entry"
# Check no line is exactly the bare form (without -diff)
if echo "$GA7" | grep -qxF '.weave/state.sql merge=ours'; then
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -e "${RED}✗${NC} gitattr upgrade: bare entry stripped"
    TESTS_FAILED=$((TESTS_FAILED + 1))
else
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -e "${GREEN}✓${NC} gitattr upgrade: bare entry stripped"
    TESTS_PASSED=$((TESTS_PASSED + 1))
fi

# --- .gitattributes: preserves user entries ---
echo ""
echo "--- gitattributes: user entries preserved ---"
REPO8=$(make_test_repo "gitattr-user")
cd "$REPO8"
cat > "$REPO8/.gitattributes" << 'GITEOF'
*.pbf filter=lfs diff=lfs merge=lfs -text
*.tif filter=lfs diff=lfs merge=lfs -text

.weave/state.sql merge=ours
.weave/nodes.jsonl merge=ours
.weave/edges.jsonl merge=ours
GITEOF
"$WV" init-repo --update --agent=claude >/dev/null 2>&1
GA8=$(cat "$REPO8/.gitattributes")
assert_contains "$GA8" "*.pbf filter=lfs"              "gitattr user: preserves LFS entries"
assert_contains "$GA8" "*.tif filter=lfs"              "gitattr user: preserves tif entry"
assert_contains "$GA8" "BEGIN WEAVE GITATTRIBUTES"     "gitattr user: has marker block"

# --- .gitattributes: idempotent (marker block already present) ---
echo ""
echo "--- gitattributes: idempotent ---"
REPO9=$(make_test_repo "gitattr-idem")
cd "$REPO9"
"$WV" init-repo --agent=claude >/dev/null 2>&1
FIRST=$(cat "$REPO9/.gitattributes")
"$WV" init-repo --update --agent=claude >/dev/null 2>&1
SECOND=$(cat "$REPO9/.gitattributes")
assert_equals "$FIRST" "$SECOND" "gitattr idempotent: second run produces identical output"

# --- scripts/hooks/ vendor seeding: missing source is seeded, not skipped ---
# Regression for wv-2adeef: a consumer that vendors only some hook sources must
# have the missing one(s) SEEDED on --update, not just refreshed-if-present.
echo ""
echo "--- vendor hook-source seeding ---"
REPO10=$(make_test_repo "vendor-seed")
cd "$REPO10"
mkdir -p scripts/hooks
# Simulate a repo scaffolded before post-commit-weave.sh existed: 2 of 3 sources.
_LIB_HOOKS_DIR="${LIB_DIR:-$HOME/.local/lib/weave}/hooks"
if [ -f "$_LIB_HOOKS_DIR/pre-commit-weave.sh" ]; then
    cp "$_LIB_HOOKS_DIR/pre-commit-weave.sh" scripts/hooks/
    cp "$_LIB_HOOKS_DIR/prepare-commit-msg-weave.sh" scripts/hooks/
    # post-commit-weave.sh intentionally absent
    "$WV" init-repo --update --agent=claude >/dev/null 2>&1
    assert_file_exists "$REPO10/scripts/hooks/post-commit-weave.sh" \
        "vendor seed: missing hook source is seeded on --update"
    # And it matches the canonical lib copy
    if cmp -s "$_LIB_HOOKS_DIR/post-commit-weave.sh" "$REPO10/scripts/hooks/post-commit-weave.sh"; then
        TESTS_RUN=$((TESTS_RUN + 1)); TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "${GREEN}✓${NC} vendor seed: seeded source matches canonical lib copy"
    else
        TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "${RED}✗${NC} vendor seed: seeded source matches canonical lib copy"
    fi
else
    TESTS_RUN=$((TESTS_RUN + 1)); TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${YELLOW}⊘${NC} vendor seed: skipped (lib hooks not installed)"
fi

# --- installed git-hook refresh: stale Weave hook updated, custom hook kept ---
# Regression for wv-4bb42e: --update must refresh an existing Weave-managed
# .git/hooks/ hook even when its (older) wording lacks the exact marker, while
# still preserving a genuinely custom user hook.
echo ""
echo "--- installed git-hook refresh ---"
REPO11=$(make_test_repo "hook-refresh")
cd "$REPO11"
"$WV" init-repo --agent=claude >/dev/null 2>&1
# Stale Weave pre-commit: a Weave signature (WV_SKIP_PRECOMMIT) but NOT the
# current "Weave pre-commit" marker — the old logic would skip this as custom.
printf '#!/usr/bin/env bash\n# legacy weave guard\n# bypass: WV_SKIP_PRECOMMIT=1\nexit 0\n' > "$REPO11/.git/hooks/pre-commit"
chmod +x "$REPO11/.git/hooks/pre-commit"
# Genuinely custom hook: no Weave signature — must be preserved.
printf '#!/bin/sh\necho my-custom-prepare-hook\n' > "$REPO11/.git/hooks/prepare-commit-msg"
chmod +x "$REPO11/.git/hooks/prepare-commit-msg"
"$WV" init-repo --agent=claude --update >/dev/null 2>&1
assert_contains "$(cat "$REPO11/.git/hooks/pre-commit")" "Weave pre-commit hook" \
    "hook-refresh: stale Weave pre-commit refreshed on --update (not skipped as custom)"
assert_contains "$(cat "$REPO11/.git/hooks/prepare-commit-msg")" "my-custom-prepare-hook" \
    "hook-refresh: genuinely custom hook preserved"

# --- repository class boundary: fork/upstream repos fail before mutation ---
echo ""
echo "--- repository class boundary ---"
REPO_CLASS_LOCAL=$(make_test_repo "repo-class-local")
cd "$REPO_CLASS_LOCAL"
assert_equals "owned" "$("$WV" repo-class --offline --json | jq -r '.class')" \
    "repo-class: no-remote repository remains auto-owned"

REPO_CLASS_TYPO=$(make_test_repo "repo-class-typo")
cd "$REPO_CLASS_TYPO"
TYPO_RC=0
"$WV" init-repo --repository-clas=vendored-upstream >/dev/null 2>&1 || TYPO_RC=$?
assert_equals "2" "$TYPO_RC" "repo-class: installed init rejects unknown classification flags"
assert_equals "0" "$(find . -path ./.git -prune -o -type f -print | wc -l)" \
    "repo-class: unknown init flag fails before worktree writes"

REPO_CLASS_FORK=$(make_test_repo "repo-class-fork")
cd "$REPO_CLASS_FORK"
git remote add origin git@github.com:example/owned-fork.git
git remote add upstream https://github.com/upstream/canonical.git
CLASS_BEFORE=$(find . -path ./.git -prune -o -type f -print | sort)
FORK_CLASS=$("$WV" repo-class --offline --json | jq -r '.class')
assert_equals "vendored-upstream" "$FORK_CLASS" \
    "repo-class: distinct upstream remote is fail-closed vendored evidence"
if "$WV" init-repo --force >/dev/null 2>&1; then
    assert_equals "refused" "allowed" "repo-class: --force cannot bypass vendored guard"
else
    assert_equals "$CLASS_BEFORE" "$(find . -path ./.git -prune -o -type f -print | sort)" \
        "repo-class: vendored init refusal makes zero worktree writes"
fi
OWNED_OVERRIDE_RC=0
"$WV" repo-class set owned >/dev/null 2>&1 || OWNED_OVERRIDE_RC=$?
assert_equals "1" "$([ "$OWNED_OVERRIDE_RC" -ne 0 ] && echo 1 || echo 0)" \
    "repo-class: owned fork override requires acknowledgement"
"$WV" repo-class set owned --acknowledge-upstream-fork >/dev/null
assert_equals "owned" "$(git config --local --get weave.repositoryClass)" \
    "repo-class: acknowledged override persists only in local Git config"
"$WV" init-repo --agent=claude >/dev/null 2>&1
assert_file_exists "$REPO_CLASS_FORK/.weave/runtime.md" \
    "repo-class: fingerprint-valid explicit owned fork may initialize"
git remote set-url origin git@github.com:example/repointed-fork.git
assert_equals "ambiguous" "$("$WV" repo-class --offline --json | jq -r '.class')" \
    "repo-class: remote topology change invalidates explicit owned classification"

REPO_CLASS_EQUIV=$(make_test_repo "repo-class-equivalent-remotes")
cd "$REPO_CLASS_EQUIV"
git remote add origin git@github.com:example/same-repository.git
git remote add upstream https://github.com/example/same-repository.git
assert_equals "ambiguous" "$("$WV" repo-class --offline --json | jq -r '.class')" \
    "repo-class: equivalent SSH and HTTPS remotes are not false vendored evidence"

# An origin-only remote cannot be assumed owned when API evidence is unavailable.
REPO_CLASS_AMBIG=$(make_test_repo "repo-class-ambiguous")
cd "$REPO_CLASS_AMBIG"
git remote add origin https://github.com/example/unknown.git
assert_equals "ambiguous" "$("$WV" repo-class --offline --json | jq -r '.class')" \
    "repo-class: unresolved remote-bearing repo is ambiguous offline"
AMBIG_OVERRIDE_RC=0
"$WV" repo-class set owned >/dev/null 2>&1 || AMBIG_OVERRIDE_RC=$?
assert_equals "1" "$([ "$AMBIG_OVERRIDE_RC" -ne 0 ] && echo 1 || echo 0)" \
    "repo-class: ambiguous owned override requires risk acknowledgement"
if "$WV" init-repo >/dev/null 2>&1; then
    assert_equals "refused" "allowed" "repo-class: ambiguous init is refused"
else
    assert_equals "0" "$(find . -path ./.git -prune -o -type f -print | wc -l)" \
        "repo-class: ambiguous refusal occurs before first worktree write"
fi

# The owned override fingerprint includes push topology, not only fetch URLs.
"$WV" repo-class set owned --acknowledge-upstream-fork >/dev/null
git remote set-url --add --push origin git@github.com:example/push-target.git
assert_equals "ambiguous" "$("$WV" repo-class --offline --json | jq -r '.class')" \
    "repo-class: push topology change invalidates explicit owned classification"
git config --local --unset-all weave.repositoryClass
git config --local --unset-all weave.repositoryClassRemoteFingerprint

# Stub GitHub evidence for an origin-only fork; API failure never implies owned.
FAKE_BIN="$TEST_DIR/fake-gh-bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/gh" <<'GH'
#!/usr/bin/env bash
printf 'true\tfalse\tfalse\ttrue\tupstream/canonical\n'
GH
chmod +x "$FAKE_BIN/gh"
assert_equals "vendored-upstream" \
    "$(PATH="$FAKE_BIN:$PATH" "$WV" repo-class --json | jq -r '.class')" \
    "repo-class: GitHub fork evidence classifies origin-only fork as vendored"

# Read-only audit reports both current and reachable historical exposure.
REPO_CLASS_AUDIT=$(make_test_repo "repo-class-audit")
cd "$REPO_CLASS_AUDIT"
git config user.email test@example.com
git config user.name Test
git commit -q --allow-empty -m "clean base"
printf '{"mcpServers":{"weave-lite":{}}}\n' > .mcp.json
git add .mcp.json
git commit -q -m "seed historical weave state"
git rm -q .mcp.json
git commit -q -m "remove current weave state"
"$WV" repo-class set vendored-upstream >/dev/null
AUDIT_STATUS_BEFORE=$(git status --porcelain=v1)
AUDIT_RC=0
AUDIT_JSON=$("$WV" repo-class audit --offline --json) || AUDIT_RC=$?
assert_equals "1" "$([ "$AUDIT_RC" -ne 0 ] && echo 1 || echo 0)" \
    "repo-class audit: historical exposure exits nonzero"
assert_equals "true" "$(jq -r '.remediation_required' <<< "$AUDIT_JSON")" \
    "repo-class audit: historical .weave exposure requires remediation"
assert_equals "reachable_exposure" "$(jq -r '.exposure_state' <<< "$AUDIT_JSON")" \
    "repo-class audit: ref-reachable history is actionable exposure"
assert_equals "$AUDIT_STATUS_BEFORE" "$(git status --porcelain=v1)" \
    "repo-class audit: inspection leaves worktree and index unchanged"

# Reflog-only history is inert residue: report it, but do not require
# irreversible reflog expiry or object pruning to satisfy the exposure gate.
AUDIT_EXPOSURE_COMMIT=$(git rev-parse HEAD~1)
AUDIT_CLEAN_BASE=$(git rev-parse HEAD~2)
git reset -q --hard "$AUDIT_CLEAN_BASE"

assert_reachable_audit_exposure() {
    local ref_kind="$1" audit_ref_rc=0 audit_ref_json
    audit_ref_json=$("$WV" repo-class audit --offline --json) || audit_ref_rc=$?
    assert_equals "1" "$audit_ref_rc" \
        "repo-class audit: $ref_kind-reachable exposure exits one"
    assert_equals "reachable_exposure" "$(jq -r '.exposure_state' <<< "$audit_ref_json")" \
        "repo-class audit: $ref_kind-reachable exposure has actionable state"
    assert_equals "true" "$(jq -r --arg sha "$AUDIT_EXPOSURE_COMMIT" '.reachable_exposure.history_commits | index($sha) != null' <<< "$audit_ref_json")" \
        "repo-class audit: $ref_kind-reachable exposure identifies the commit"
}

git branch audit-exposure "$AUDIT_EXPOSURE_COMMIT"
assert_reachable_audit_exposure "branch"
git branch -D audit-exposure >/dev/null
git tag --no-sign --no-annotate audit-exposure "$AUDIT_EXPOSURE_COMMIT"
assert_reachable_audit_exposure "tag"
git tag -d audit-exposure >/dev/null
git update-ref refs/remotes/origin/audit-exposure "$AUDIT_EXPOSURE_COMMIT"
assert_reachable_audit_exposure "remote-tracking"
git update-ref -d refs/remotes/origin/audit-exposure

AUDIT_RESIDUE_STATUS_BEFORE=$(git status --porcelain=v1)
AUDIT_RESIDUE_RC=0
AUDIT_RESIDUE_JSON=$("$WV" repo-class audit --offline --json) || AUDIT_RESIDUE_RC=$?
assert_equals "0" "$AUDIT_RESIDUE_RC" \
    "repo-class audit: reflog-only residue does not fail the exposure gate"
assert_equals "false" "$(jq -r '.remediation_required' <<< "$AUDIT_RESIDUE_JSON")" \
    "repo-class audit: reflog-only residue requires no remediation"
assert_equals "true" "$(jq -r '.gate_passed' <<< "$AUDIT_RESIDUE_JSON")" \
    "repo-class audit: reflog-only residue passes the gate"
assert_equals "residue_only" "$(jq -r '.exposure_state' <<< "$AUDIT_RESIDUE_JSON")" \
    "repo-class audit: reflog-only history has an advisory state"
assert_equals "true" "$(jq -r --arg sha "$AUDIT_EXPOSURE_COMMIT" '.residue.commits | index($sha) != null' <<< "$AUDIT_RESIDUE_JSON")" \
    "repo-class audit: advisory identifies the unreachable exposure commit"
assert_equals "false" "$(jq -r '.clean' <<< "$AUDIT_RESIDUE_JSON")" \
    "repo-class audit: legacy clean field still reports historical residue"
assert_equals "true" "$(jq -r --arg sha "$AUDIT_EXPOSURE_COMMIT" '.history_commits | index($sha) != null' <<< "$AUDIT_RESIDUE_JSON")" \
    "repo-class audit: legacy history field retains residue commits"
assert_equals "$AUDIT_RESIDUE_STATUS_BEFORE" "$(git status --porcelain=v1)" \
    "repo-class audit: residue inspection leaves worktree and index unchanged"

# Direct graph initialization and repair paths share the same deny boundary.
if env -u WV_DB -u WV_DB_CUSTOM WV_PROJECT_DIR="$REPO_CLASS_AUDIT" \
    WV_HOT_ZONE="$TEST_DIR/repo-class-audit-hot" "$WV" init >/dev/null 2>&1; then
    assert_equals "refused" "allowed" "repo-class: wv init refuses vendored repository"
else
    assert_equals "0" "$(find .weave -type f 2>/dev/null | wc -l)" \
        "repo-class: refused wv init creates no graph files"
fi
REPO_CLASS_OTHER=$(make_test_repo "repo-class-other-cwd")
cd "$REPO_CLASS_OTHER"
if env -u WV_DB -u WV_DB_CUSTOM WEAVE_DIR="$REPO_CLASS_AUDIT/.weave" \
    WV_HOT_ZONE="$TEST_DIR/repo-class-other-hot" "$WV" init >/dev/null 2>&1; then
    assert_equals "refused" "allowed" "repo-class: wv init guards the persistent target, not caller cwd"
else
    assert_equals "0" "$(find "$REPO_CLASS_AUDIT/.weave" -type f 2>/dev/null | wc -l)" \
        "repo-class: cross-directory init refusal creates no graph files"
fi
SYMLINK_TARGET="$TEST_DIR/repo-class-symlink-target"
mkdir -p "$SYMLINK_TARGET"
ln -s "$SYMLINK_TARGET" "$REPO_CLASS_OTHER/.weave"
if env -u WV_DB -u WV_DB_CUSTOM WEAVE_DIR="$REPO_CLASS_OTHER/.weave" \
    WV_HOT_ZONE="$TEST_DIR/repo-class-symlink-hot" "$WV" init --force >/dev/null 2>&1; then
    assert_equals "refused" "allowed" "repo-class: wv init refuses symlinked persistent target"
else
    assert_equals "0" "$(find "$SYMLINK_TARGET" -type f | wc -l)" \
        "repo-class: symlink refusal writes nothing through the target"
fi
if env -u WV_DB -u WV_DB_CUSTOM WEAVE_DIR="$REPO_CLASS_AUDIT/.weave" \
    WV_HOT_ZONE="$TEST_DIR/repo-class-doctor-hot" "$WV" doctor --repair >/dev/null 2>&1; then
    assert_equals "refused" "allowed" "repo-class: doctor repair guards persistent target, not caller cwd"
else
    assert_equals "0" "$(find "$REPO_CLASS_AUDIT/.weave" -type f 2>/dev/null | wc -l)" \
        "repo-class: cross-directory repair refusal creates no graph files"
fi
cd "$REPO_CLASS_AUDIT"
if "$WV" doctor --repair >/dev/null 2>&1; then
    assert_equals "refused" "allowed" "repo-class: doctor --repair refuses vendored repository"
else
    assert_equals "$AUDIT_STATUS_BEFORE" "$(git status --porcelain=v1)" \
        "repo-class: refused repair leaves repository unchanged"
fi

# Current marker detection covers both working-tree and staged index content.
REPO_CLASS_MARKER_AUDIT=$(make_test_repo "repo-class-marker-audit")
cd "$REPO_CLASS_MARKER_AUDIT"
git config user.email test@example.com
git config user.name Test
printf 'project instructions\n' > CLAUDE.md
git add CLAUDE.md
git commit -q -m "clean instructions"
"$WV" repo-class set vendored-upstream >/dev/null
printf 'BEGIN WEAVE\n' > CLAUDE.md
MARKER_WORKTREE_RC=0
MARKER_WORKTREE_JSON=$("$WV" repo-class audit --offline --json) || MARKER_WORKTREE_RC=$?
assert_equals "1" "$MARKER_WORKTREE_RC" \
    "repo-class audit: unstaged current marker exposure exits one"
assert_equals "true" "$(jq -r '.current_exposure.marker_paths | index("CLAUDE.md") != null' <<< "$MARKER_WORKTREE_JSON")" \
    "repo-class audit: unstaged current marker path is reported"
git add CLAUDE.md
printf 'project instructions\n' > CLAUDE.md
MARKER_INDEX_STATUS_BEFORE=$(git status --porcelain=v1)
MARKER_INDEX_RC=0
MARKER_INDEX_JSON=$("$WV" repo-class audit --offline --json) || MARKER_INDEX_RC=$?
assert_equals "1" "$MARKER_INDEX_RC" \
    "repo-class audit: staged-only current marker exposure exits one"
assert_equals "true" "$(jq -r '.current_exposure.marker_paths | index("CLAUDE.md") != null' <<< "$MARKER_INDEX_JSON")" \
    "repo-class audit: staged-only current marker path is reported"
assert_equals "$MARKER_INDEX_STATUS_BEFORE" "$(git status --porcelain=v1)" \
    "repo-class audit: staged-only inspection leaves index and worktree unchanged"

# Full-history traversal retains exposure on a merged side branch even when
# the merge result deliberately keeps the clean parent tree.
REPO_CLASS_MERGE_AUDIT=$(make_test_repo "repo-class-merge-audit")
cd "$REPO_CLASS_MERGE_AUDIT"
git config user.email test@example.com
git config user.name Test
git commit -q --allow-empty -m "clean base"
MERGE_BASE_BRANCH=$(git branch --show-current)
git checkout -q -b audit-exposed-side
mkdir -p .weave
printf 'scaffolding\n' > .weave/state.sql
git add .weave/state.sql
git commit -q -m "side branch scaffolding"
MERGE_EXPOSURE_COMMIT=$(git rev-parse HEAD)
git checkout -q "$MERGE_BASE_BRANCH"
git merge -q --no-ff -s ours -m "merge without scaffolding tree" audit-exposed-side
git branch -D audit-exposed-side >/dev/null
"$WV" repo-class set vendored-upstream >/dev/null
MERGE_AUDIT_RC=0
MERGE_AUDIT_JSON=$("$WV" repo-class audit --offline --json) || MERGE_AUDIT_RC=$?
assert_equals "1" "$MERGE_AUDIT_RC" \
    "repo-class audit: merged side-branch exposure exits one"
assert_equals "true" "$(jq -r --arg sha "$MERGE_EXPOSURE_COMMIT" '.reachable_exposure.history_commits | index($sha) != null' <<< "$MERGE_AUDIT_JSON")" \
    "repo-class audit: full history identifies merged exposure commit"

# Historical path scanning covers markerless managed scaffolding too.
REPO_CLASS_AGENT_AUDIT=$(make_test_repo "repo-class-agent-audit")
cd "$REPO_CLASS_AGENT_AUDIT"
git config user.email test@example.com
git config user.name Test
git commit -q --allow-empty -m "clean base"
mkdir -p .claude/agents
printf 'managed agent instructions without marker text\n' > .claude/agents/weave-guide.md
git add .claude/agents/weave-guide.md
git commit -q -m "add markerless managed agent"
AGENT_EXPOSURE_COMMIT=$(git rev-parse HEAD)
git rm -q .claude/agents/weave-guide.md
git commit -q -m "remove managed agent"
"$WV" repo-class set vendored-upstream >/dev/null
AGENT_AUDIT_RC=0
AGENT_AUDIT_JSON=$("$WV" repo-class audit --offline --json) || AGENT_AUDIT_RC=$?
assert_equals "1" "$AGENT_AUDIT_RC" \
    "repo-class audit: markerless managed-agent history exits one"
assert_equals "reachable_exposure" "$(jq -r '.exposure_state' <<< "$AGENT_AUDIT_JSON")" \
    "repo-class audit: markerless managed-agent history is actionable"
assert_equals "true" "$(jq -r --arg sha "$AGENT_EXPOSURE_COMMIT" '.reachable_exposure.history_commits | index($sha) != null' <<< "$AGENT_AUDIT_JSON")" \
    "repo-class audit: markerless managed-agent exposure identifies the commit"

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
