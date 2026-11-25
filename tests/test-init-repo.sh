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

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# wv_stat: GNU and BSD stat behind one call (wv-resolve-runtime.sh, side-effect free).
# shellcheck disable=SC1091  # resolved at run time
source "$PROJECT_ROOT/scripts/lib/wv-resolve-runtime.sh"
WV="$PROJECT_ROOT/scripts/wv"

# Test environment
TEST_DIR="/tmp/wv-init-repo-test-$$"
export WV_HOT_ZONE="$TEST_DIR/hotzone"
export WV_DB="$TEST_DIR/hotzone/brain.db"

# One hot zone per test repository, all under TEST_DIR. The first repository to
# initialise a shared exported zone stamps it, and wv refuses it in every other
# repository (wv-5e804e); before that, each later repository fell back silently
# to a default hot zone outside TEST_DIR. The name is a cksum of the repo path:
# POSIX on every host, where md5sum(1) is absent on macOS and an empty hash put
# every repository in one zone (wv-ef5621). An explicit per-call WV_HOT_ZONE (the
# repo-class cases) is left alone.
mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/wv" <<EOF
#!/usr/bin/env bash
if [ "\${WV_HOT_ZONE:-}" = "$TEST_DIR/hotzone" ]; then
    root=\$(git rev-parse --show-toplevel 2>/dev/null || pwd)
    WV_HOT_ZONE="$TEST_DIR/hotzone/\$(printf '%s' "\$root" | cksum | cut -d' ' -f1)"
    export WV_HOT_ZONE WV_DB="\$WV_HOT_ZONE/brain.db"
fi
# The commit gate injects core.hooksPath=/dev/null through GIT_CONFIG_* so
# nested commits run no hooks. init-repo must see each fixture repository's own
# config: it installs hooks only where git runs them and reports core.hooksPath
# instead (wv-76c726), so the injection would read as every fixture's setting.
if [ "\${1:-}" = "init-repo" ]; then
    unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
fi
exec "$WV" "\$@"
EOF
chmod +x "$TEST_DIR/bin/wv"
WV="$TEST_DIR/bin/wv"

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
    if grep -qF -- "$needle" <<< "$haystack"; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Expected to find: $needle"
        echo "  In: $(echo "$haystack" | sed -n '1,5p')"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if ! grep -qF -- "$needle" <<< "$haystack"; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Did NOT expect to find: $needle"
        echo "  But found it in: $(echo "$haystack" | sed -n '1,5p')"
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
# shellcheck disable=SC2016  # the expected text contains a literal $ reference
assert_contains "$(cat "$REPO/CLAUDE.md")" '$HOME/.local/bin/wv' \
    "scaffolded CLAUDE.md wv() fallback points at the real global install path"
assert_file_exists "$REPO/.claude/settings.local.json"      "creates settings.local.json"
assert_file_exists "$REPO/.weave/runtime.md"                "creates .weave/runtime.md scaffold"
assert_file_exists "$REPO/.weave/patterns/managed/.manifest" "creates managed pattern manifest"
assert_file_exists "$REPO/.weave/patterns/managed/prose-filler-phrases.yaml" "projects curated prose rules"
assert_file_exists "$REPO/.git/hooks/pre-commit"            "installs actual pre-commit hook entrypoint"
assert_file_absent "$REPO/.git/hooks/post-commit"           "does not install the retired post-commit hook (wv-56c823)"
assert_file_exists "$REPO/.git/hooks/prepare-commit-msg"    "installs actual prepare-commit-msg hook entrypoint"
assert_file_absent "$REPO/.git/hooks/pre-commit-weave.sh"   "does not install source filename as git hook entrypoint"
assert_contains "$(cat "$REPO/.weave/runtime.md")" "Agent Runtime Notes" "runtime.md includes agent runtime notes"
assert_contains "$(cat "$REPO/.weave/runtime.md")" "/tmp/weave-hotzone-*" "runtime.md documents the /tmp hot zone by its neutral name"
# Release review 3 (wv-89f85b): a fresh consumer's runtime.md contradicted
# itself about where wv lives. The session-start code fence hardcoded
# ./scripts/wv -- which a consumer repo does not have, so the fallback did not
# fall back, it failed -- while the prose below it advised the installed
# binary. Both halves are now chosen together from the same pair of variables,
# so assert them together, and in a CONSUMER repo, which is where the two
# disagreed. The same contradiction is asserted for CLAUDE.md above.
# Scoped to the fence, not the whole file: the prose below it names the same
# installed path, so a whole-file grep passes even with the contradiction fully
# restored -- it did when this was written that way.
RUNTIME_SESSION_START=$(awk '
    /^## Session Start/ { in_section = 1; next }
    in_section && /^```bash/ { in_fence = 1; next }
    in_fence && /^```/ { exit }
    in_fence { print }
' "$REPO/.weave/runtime.md")
# shellcheck disable=SC2016  # the expected text contains a literal $ reference
assert_contains "$RUNTIME_SESSION_START" '$HOME/.local/bin/wv' \
    "runtime.md session-start fallback points at the installed binary"
assert_not_contains "$RUNTIME_SESSION_START" './scripts/wv' \
    "runtime.md session-start does not hand a consumer the repo-local path it lacks"
assert_contains "$(cat "$REPO/.weave/runtime.md")" 'call the installed binary directly' \
    "runtime.md prose agrees with its own session-start block"
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
assert_file_exists "$REPO3/.vscode/mcp.json"               "copilot: creates .vscode/mcp.json"
assert_equals "absent" "$([ -e "$REPO3/.mcp.json" ] && echo present || echo absent)" \
    "copilot: writes no root .mcp.json (Claude Code's file, wv-d1ef4b)"
assert_file_exists "$REPO3/.github/copilot-instructions.md" "copilot: creates copilot-instructions.md"
assert_file_exists "$REPO3/.github/hooks/README.md"         "copilot: scaffolds .github/hooks/"
assert_file_exists "$REPO3/.github/hooks/weave.json"        "copilot: registers executable VS Code Local hooks"
assert_file_exists "$REPO3/.weave/runtime.md"               "copilot: creates .weave/runtime.md scaffold"
VSCODE_HOOKS=$(cat "$REPO3/.github/hooks/weave.json" 2>/dev/null || true)
assert_equals 'PostToolUse PreCompact PreToolUse SessionStart Stop' \
    "$(jq -r '.hooks | keys | join(" ")' <<<"$VSCODE_HOOKS")" "copilot: all five Local lifecycle events registered"
assert_equals true "$(jq -r '[.hooks[][] | .type == "command" and (.command | startswith("wv hook dispatch ")) and (.command | endswith(" --format=vscode"))] | length == 5 and all' <<<"$VSCODE_HOOKS")" \
    "copilot: consumer hooks use installed wv and Local output"

# Existing directories must gain the managed file without losing other hooks.
printf '{"hooks":{}}\n' > "$REPO3/.github/hooks/team.json"
printf 'local custom hook\n' > "$REPO3/.github/hooks/weave.json"
OUTPUT=$("$WV" init-repo --agent=copilot 2>&1)
assert_equals 'local custom hook' "$(cat "$REPO3/.github/hooks/weave.json")" "copilot: init preserves an existing managed hook file"
OUTPUT=$("$WV" init-repo --agent=copilot --update 2>&1)
assert_equals "$VSCODE_HOOKS" "$(cat "$REPO3/.github/hooks/weave.json")" "copilot: --update refreshes managed hooks in an existing directory"
assert_equals '{"hooks":{}}' "$(cat "$REPO3/.github/hooks/team.json")" "copilot: --update preserves team hooks"
rm "$REPO3/.github/hooks/weave.json"
OUTPUT=$("$WV" init-repo --agent=copilot 2>&1)
assert_file_exists "$REPO3/.github/hooks/weave.json" "copilot: existing hook directory still gains missing registrations"

# Verify .vscode/mcp.json points to MCP server and uses VS Code 'servers' key (not 'mcpServers')
MCP_JSON=$(cat "$REPO3/.vscode/mcp.json")
assert_contains "$MCP_JSON" '"weave"'                       "copilot: mcp.json has weave server"
assert_contains "$MCP_JSON" '"weave-session"'               "copilot: mcp.json has weave-session server"
assert_contains "$MCP_JSON" '"weave-lite"'                  "copilot: mcp.json has weave-lite server"
assert_contains "$MCP_JSON" '"weave-inspect"'               "copilot: mcp.json has weave-inspect server"
assert_not_contains "$MCP_JSON" '"weave-graph"'             "copilot: mcp.json does not ship weave-graph"
assert_contains "$MCP_JSON" 'index.js'                      "copilot: mcp.json points to index.js"
assert_contains "$MCP_JSON" '"WV_AGENT_ID"'                 "copilot: mcp.json pins explicit Weave agent identity"
# shellcheck disable=SC2016  # the expected text contains a literal $ reference
assert_contains "$MCP_JSON" 'copilot-${workspaceFolderBasename}' "copilot: mcp.json uses workspace-scoped Copilot identity"
assert_not_contains "$MCP_JSON" '"mcpServers"'              "copilot: mcp.json uses 'servers' not 'mcpServers'"
assert_not_contains "$MCP_JSON" '"inputs"'                  "copilot: mcp.json has no 'inputs' key"
SERVER_COUNT=$(jq '.servers | keys | length' "$REPO3/.vscode/mcp.json")
assert_equals "4" "$SERVER_COUNT"                           "copilot: mcp.json ships exactly four servers"

# A legacy root .mcp.json that Weave wrote (VS Code shape) is removed on
# --update; a user-owned root .mcp.json is kept (wv-d1ef4b).
jq '{servers: .servers}' "$REPO3/.vscode/mcp.json" > "$REPO3/.mcp.json"
OUTPUT=$("$WV" init-repo --agent=copilot 2>&1)
assert_file_exists "$REPO3/.mcp.json"                       "copilot: plain init leaves an existing root .mcp.json"
OUTPUT=$("$WV" init-repo --agent=copilot --update 2>&1)
assert_equals "absent" "$([ -e "$REPO3/.mcp.json" ] && echo present || echo absent)" \
    "copilot: --update removes the Weave-written VS Code-shaped root .mcp.json"
assert_contains "$OUTPUT" "removed legacy VS Code-shaped copy" "copilot: --update reports the legacy removal"
printf '{"mcpServers":{"weave":{"command":"node","args":["x.js"]}}}\n' > "$REPO3/.mcp.json"
OUTPUT=$("$WV" init-repo --agent=copilot --force 2>&1)
assert_equals '{"mcpServers":{"weave":{"command":"node","args":["x.js"]}}}' "$(cat "$REPO3/.mcp.json")" \
    "copilot: --force keeps a user-owned mcpServers root .mcp.json"
jq '{servers: (.servers + {"team-tool": {"command": "x"}})}' "$REPO3/.vscode/mcp.json" > "$REPO3/.mcp.json"
OUTPUT=$("$WV" init-repo --agent=copilot --update 2>&1)
assert_file_exists "$REPO3/.mcp.json"                       "copilot: --update keeps a root .mcp.json with non-Weave servers"
rm -f "$REPO3/.mcp.json"

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

# --- copilot: the inline fallback block is localized like the template one ---
# Regression (release review 3): when the stub template is missing from the
# config dir, the Copilot surface is built from an inline copy. That copy was
# emitted UNLOCALIZED, so it kept the shipped stub's consumer wording while
# hardcoding ./scripts/wv -- handing an agent in a consumer repo a path that
# does not exist, directly contradicting the prose beside it. Both branches now
# go through _wv_localize_agent_block.
echo ""
echo "--- copilot: inline fallback localization ---"
COP_STUB="$WV_CONFIG_DIR/copilot-instructions.stub.md"
COP_STUB_BACKUP="$TEST_DIR/copilot-instructions.stub.md.bak"
cp "$COP_STUB" "$COP_STUB_BACKUP"
rm -f "$COP_STUB"

# (a) a consumer repo has no ./scripts/wv, so the fallback must name the binary
REPO_FB=$(make_test_repo "copilot-fallback-consumer")
cd "$REPO_FB"
"$WV" init-repo --agent=copilot >/dev/null 2>&1
COP_FB=$(cat "$REPO_FB/.github/copilot-instructions.md")
# shellcheck disable=SC2016  # the expected text contains a literal $ reference
assert_contains "$COP_FB" 'wv() { "$HOME/.local/bin/wv" "$@"; }' "copilot fallback: consumer repo falls back to the installed binary"
assert_not_contains "$COP_FB" 'wv() { ./scripts/wv "$@"; }' "copilot fallback: consumer repo is not sent to a nonexistent ./scripts/wv"

# (b) a weave source checkout does vendor scripts/wv, so it must be preferred
REPO_FB2=$(make_test_repo "copilot fallback source")
mkdir -p "$REPO_FB2/scripts/lib"
printf '#!/bin/sh\nprintf "source-hook:%%s\\n" "$*"\n' > "$REPO_FB2/scripts/wv"
chmod +x "$REPO_FB2/scripts/wv"
touch "$REPO_FB2/scripts/lib/wv-config.sh"
cd "$REPO_FB2"
"$WV" init-repo --agent=copilot >/dev/null 2>&1
COP_FB2=$(cat "$REPO_FB2/.github/copilot-instructions.md")
assert_contains "$COP_FB2" 'wv() { ./scripts/wv "$@"; }' "copilot fallback: source checkout prefers the repo-local wrapper"
# shellcheck disable=SC2016  # the expected text contains a literal $ reference
assert_not_contains "$COP_FB2" 'wv() { "$HOME/.local/bin/wv" "$@"; }' "copilot fallback: source checkout is not sent to the installed binary"
VSCODE_COMMAND=$(jq -r '.hooks.PreToolUse[0].command' "$REPO_FB2/.github/hooks/weave.json")
assert_equals 'source-hook:hook dispatch --event=PreToolUse --format=vscode' \
    "$(bash -c "$VSCODE_COMMAND")" "copilot: generated Local command runs source CLI with spaces in the repository path"

cp "$COP_STUB_BACKUP" "$COP_STUB"

# --- git hooks are replaced by rename, never rewritten in place ---
# Regression (release review 4, wv-c5ed92): the hook was installed with a plain
# `cp` onto the destination, which truncates and rewrites the existing inode.
# The pre-commit hook's own drift self-heal runs install.sh, so a commit that
# touched the hook source rewrote the file bash was mid-way through executing:
# it resumed at its old byte offset inside new content and died with a syntax
# error naming a valid line, then succeeded on retry, which read as a flake.
# A rename swaps the directory entry and leaves the running process on its
# original inode -- so a refreshed hook must have a DIFFERENT inode.
echo ""
echo "--- git hook replacement is atomic ---"
REPO_HOOK=$(make_test_repo "hook-atomicity")
cd "$REPO_HOOK"
"$WV" init-repo --agent=claude >/dev/null 2>&1
assert_equals "yes" "$([ -f "$REPO_HOOK/.git/hooks/pre-commit" ] && echo yes || echo no)" \
    "hook: pre-commit is installed"
# Inodes through the product's wv_stat (GNU and BSD). The old stat -c read
# failed on BSD and its "|| echo before/after" fallbacks always differed, so the
# rename check passed without measuring anything (wv-0bf286, wv-b30dc6).
HOOK_INODE_BEFORE=$(wv_stat ino "$REPO_HOOK/.git/hooks/pre-commit" 2>/dev/null)
# Prove the refresh actually happens, or the inode comparison proves nothing.
printf '# drift marker\n' >> "$REPO_HOOK/.git/hooks/pre-commit"
"$WV" init-repo --agent=claude --update >/dev/null 2>&1
HOOK_INODE_AFTER=$(wv_stat ino "$REPO_HOOK/.git/hooks/pre-commit" 2>/dev/null)
assert_not_contains "$(cat "$REPO_HOOK/.git/hooks/pre-commit" 2>/dev/null)" "# drift marker" \
    "hook: refresh actually replaced the file"
if ! [[ "$HOOK_INODE_BEFORE" =~ ^[0-9]+$ && "$HOOK_INODE_AFTER" =~ ^[0-9]+$ ]]; then
    HOOK_REPLACE="unmeasured (inodes [$HOOK_INODE_BEFORE] [$HOOK_INODE_AFTER])"
elif [ "$HOOK_INODE_BEFORE" != "$HOOK_INODE_AFTER" ]; then HOOK_REPLACE=rename; else HOOK_REPLACE=in-place; fi
assert_equals "rename" "$HOOK_REPLACE" \
    "hook: replaced by rename (new inode), not rewritten under a running process"

# --- AGENTS.md opts in by marker (wv-6ef83b) ---
# A consumer AGENTS.md is user-owned: init-repo refreshes a WEAVE PROCEDURES
# block it already carries and touches nothing else; one without the block is
# preserved byte for byte (the codex case below).
echo ""
echo "--- AGENTS.md marker-gated procedure index ---"
REPO_AGENTS=$(make_test_repo "agentsmd")
printf '%s\n' '# Our agents' 'hand text above' '<!-- BEGIN WEAVE PROCEDURES -->' 'stale line' \
    '<!-- END WEAVE PROCEDURES -->' 'hand text below' > "$REPO_AGENTS/AGENTS.md"
(cd "$REPO_AGENTS" && "$WV" init-repo --agent=codex >/dev/null 2>&1) || true
AGENTS_TEXT=$(cat "$REPO_AGENTS/AGENTS.md")
assert_contains "$AGENTS_TEXT" "wv guide --procedure=discovery-routing" "agents: init-repo fills a marked AGENTS.md procedure index"
assert_not_contains "$AGENTS_TEXT" "stale line" "agents: the managed block is replaced, not appended to"
assert_contains "$AGENTS_TEXT" "hand text above" "agents: hand text before the block is kept"
assert_contains "$AGENTS_TEXT" "hand text below" "agents: hand text after the block is kept"

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
# shellcheck disable=SC2016  # the expected text holds a literal $HOME or $(...)
assert_contains "$CODEX_JSON" '"noninteractive_close": "$HOME/.local/bin/wv ship-agent"' "codex: contract names repo-local ship-agent close"
# shellcheck disable=SC2016  # the expected text holds a literal $HOME or $(...)
assert_contains "$CODEX_JSON" '"local_first": "$HOME/.local/bin/wv sync"' "codex: contract names local-first sync"
# shellcheck disable=SC2016  # the expected text holds a literal $HOME or $(...)
assert_contains "$CODEX_JSON" '"external_network": "$HOME/.local/bin/wv sync --gh"' "codex: contract names external GitHub sync"
assert_contains "$CODEX_JSON" '"requires_sandbox_approval": true' "codex: contract marks GitHub sync approval"
# shellcheck disable=SC2016  # the expected text contains a literal $ reference
assert_contains "$CODEX_JSON" '"fallback": "$HOME/.local/bin/wv bootstrap-agent --json"' "codex: bootstrap fallback is portable"
assert_contains "$CODEX_JSON" '"authority": "weave-graph"' "codex: memory contract marks graph authority"
# shellcheck disable=SC2016  # the expected text holds a literal $HOME or $(...)
assert_contains "$CODEX_JSON" '"command": "$HOME/.local/bin/wv memory recall --agent=all --json"' "codex: memory recall is graph-wide"
# shellcheck disable=SC2016  # the expected text holds a literal $HOME or $(...)
assert_contains "$CODEX_JSON" '"command": "$HOME/.local/bin/wv memory scan --source=codex --json"' "codex: memory scan names Codex evidence source"
# shellcheck disable=SC2016  # the expected text holds a literal $HOME or $(...)
assert_contains "$CODEX_JSON" '"command": "$HOME/.local/bin/wv memory import --source=codex --json"' "codex: memory import names Codex candidate import"
# shellcheck disable=SC2016  # the expected text holds a literal $HOME or $(...)
assert_contains "$CODEX_JSON" '"claim": "$HOME/.local/bin/wv work <id>"' "codex: contract includes safe claim command"
# shellcheck disable=SC2016  # the expected text holds a literal $HOME or $(...)
assert_contains "$CODEX_JSON" '"record_edit": "$HOME/.local/bin/wv touch <id> --files=<path>"' "codex: contract includes safe edit attribution command"
# A consumer has no scripts/wv (wv-dce969): no entry may name one, the memory
# render included, which used to put ./scripts/wv back on every sync.
assert_not_contains "$CODEX_JSON" './scripts/wv' "codex: a consumer's contract names no repo-local scripts/wv"
assert_contains "$CODEX_JSON" '"prefer_repo_local_wv": false' "codex: a consumer's contract does not prefer a repo-local wv"
SELF_HOST=$(make_test_repo "codex-self-host"); cd "$SELF_HOST"
mkdir -p "$SELF_HOST/scripts/lib"
printf '#!/bin/sh\n' > "$SELF_HOST/scripts/wv"; chmod +x "$SELF_HOST/scripts/wv"
: > "$SELF_HOST/scripts/lib/wv-config.sh"
"$WV" init-repo --agent=codex --codex-hooks >/dev/null 2>&1 || true
assert_contains "$(cat "$SELF_HOST/.codex/weave.json" 2>/dev/null)" '"claim": "./scripts/wv work <id>"' \
    "codex: the source checkout's contract keeps its own scripts/wv"
# shellcheck disable=SC2016  # the expected text holds a literal $HOME or $(...)
assert_contains "$(cat "$SELF_HOST/.codex/hooks.json" 2>/dev/null)" '$(git rev-parse --show-toplevel)/scripts/wv' \
    "codex: the source checkout's hooks keep its own scripts/wv"
cd "$REPO_CODEX"
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
"$WV" init-repo --agent=codex --update >/dev/null
CODEX_SCHEMA=$(jq -r '.schema' "$REPO_CODEX/.codex/weave.json")
assert_equals "weave.codex.v1" "$CODEX_SCHEMA"               "codex: --update refreshes contract"

printf '%s\n' '{"custom":true}' > "$REPO_CODEX/.codex/weave.json"
"$WV" init-repo --agent=codex --force >/dev/null
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
    "$WV" init-repo --agent=codex --force --codex-mcp >/dev/null
assert_contains "$(cat "$TEST_DIR/codex-mcp.log")" "mcp remove weave" "codex: --codex-mcp prunes stale full MCP registration"
assert_contains "$(cat "$TEST_DIR/codex-mcp.log")" "mcp add weave-lite" "codex: --codex-mcp registers lite MCP by default"
assert_contains "$(cat "$TEST_DIR/codex-mcp.log")" "--scope=lite" "codex: default MCP registration uses lite scope"

CODEX_MCP_LOG="$TEST_DIR/codex-mcp-full.log" PATH="$FAKE_BIN:$PATH" \
    "$WV" init-repo --agent=codex --force --codex-mcp=full >/dev/null
assert_contains "$(cat "$TEST_DIR/codex-mcp-full.log")" "mcp add weave" "codex: full MCP registration is explicit"
assert_contains "$(cat "$TEST_DIR/codex-mcp-full.log")" "--scope=all" "codex: full MCP registration uses all scope"

# wv-d3c35c: a consumer has no mcp/ and wv does not export WV_LIB_DIR, so the
# server is looked up in the installed library wv-init-repo resolves itself, and
# a codex outside PATH is named with --codex-bin or found in the VS Code
# extension. HOME is a fake whose library mirrors this install's, with (mcp) or
# without (nomcp) a built server; WV_LIB_DIR is unset for these calls.
codex_fake_home() {
    local h="$TEST_DIR/codex-home-$1" e
    mkdir -p "$h/.local/lib/weave"
    for e in "$WV_LIB_DIR"/*; do
        [ "${e##*/}" = mcp ] || ln -s "$e" "$h/.local/lib/weave/"
    done
    if [ "$1" = mcp ]; then
        mkdir -p "$h/.local/lib/weave/mcp/dist"
        printf '%s\n' '/* installed mcp bundle */' > "$h/.local/lib/weave/mcp/dist/index.js"
    fi
    printf '%s' "$h"
}
# PATH with every codex taken out, so only --codex-bin or the extension finds one.
NOCODEX_PATH=""
IFS=: read -ra _nc_dirs <<< "$PATH"
for _nc_d in "${_nc_dirs[@]}"; do
    if [ -e "$_nc_d/codex" ]; then
        _nc_f="$TEST_DIR/nocodex-$(printf '%s' "$_nc_d" | cksum | cut -d' ' -f1)"
        mkdir -p "$_nc_f"
        for _nc_x in "$_nc_d"/*; do [ "${_nc_x##*/}" = codex ] || ln -sf "$_nc_x" "$_nc_f/"; done
        _nc_d="$_nc_f"
    fi
    NOCODEX_PATH="${NOCODEX_PATH:+$NOCODEX_PATH:}$_nc_d"
done
OUTSIDE_CODEX="$TEST_DIR/outside/codex"
mkdir -p "${OUTSIDE_CODEX%/*}"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$0 $*" >> "$CODEX_MCP_LOG"\n' > "$OUTSIDE_CODEX"
chmod +x "$OUTSIDE_CODEX"
REPO_NOMCP="$TEST_DIR/consumer-no-mcp"
mkdir -p "$REPO_NOMCP" && git -C "$REPO_NOMCP" init -q
codex_consumer() { # home args...
    local h="$1"; shift
    (cd "$REPO_NOMCP" && env -u WV_LIB_DIR HOME="$h" PATH="$NOCODEX_PATH" \
        CODEX_MCP_LOG="$TEST_DIR/codex-lookup.log" "$WV" init-repo --agent=codex --force "$@" 2>&1)
}
CH=$(codex_fake_home mcp)
: > "$TEST_DIR/codex-lookup.log"
OUTPUT=$(codex_consumer "$CH" --codex-mcp --codex-bin="$OUTSIDE_CODEX")
assert_contains "$(cat "$TEST_DIR/codex-lookup.log")" "$OUTSIDE_CODEX mcp add weave-lite" "codex: --codex-bin names a codex outside PATH"
assert_contains "$(cat "$TEST_DIR/codex-lookup.log")" "$CH/.local/lib/weave/mcp/dist/index.js" "codex: the installed MCP server is found with WV_LIB_DIR unset"
OUTPUT=$(codex_consumer "$CH" --codex-mcp --codex-bin="$TEST_DIR/no-such-codex")
assert_contains "$OUTPUT" "--codex-bin=$TEST_DIR/no-such-codex is not an executable file" "codex: a --codex-bin that is not executable is reported"
OUTPUT=$(codex_consumer "$CH" --codex-mcp)
assert_contains "$OUTPUT" "codex not found on PATH, in a VS Code extension's bin/ or under nvm" "codex: with no codex anywhere, the message names where it looked"
CODEX_EXT="$CH/.vscode/extensions/openai.chatgpt-9.9.9-linux-x64/bin/linux-x86_64"
mkdir -p "$CODEX_EXT" && cp "$OUTSIDE_CODEX" "$CODEX_EXT/codex"
: > "$TEST_DIR/codex-lookup.log"
OUTPUT=$(codex_consumer "$CH" --codex-mcp)
assert_contains "$(cat "$TEST_DIR/codex-lookup.log")" "$CODEX_EXT/codex mcp add weave-lite" "codex: the VS Code extension's codex is found when PATH has none"
CH2=$(codex_fake_home nomcp)
OUTPUT=$(codex_consumer "$CH2" --codex-mcp --codex-bin="$OUTSIDE_CODEX")
assert_contains "$OUTPUT" "looked for $CH2/.local/lib/weave/mcp/dist/index.js" "codex: a missing MCP server names the path looked in"
assert_not_contains "$OUTPUT" "npm run build" "codex: ...and never an mcp/ build the consumer lacks"
assert_not_contains "$OUTPUT" "$REPO_NOMCP/mcp/dist" "codex: ...nor a consumer mcp/ directory"

# wv-f2a6a3: a consumer whose ignore rules hide *.json and *.md never sees the
# Codex contract, its hooks or CLAUDE.md in git status; init-repo and doctor name
# each hidden surface with the rule, and a re-included or tracked one is not named.
REPO_IGN="$TEST_DIR/consumer-ignores-json"
mkdir -p "$REPO_IGN" && git -C "$REPO_IGN" init -q
printf '%s\n' '*.json' '*.md' '!AGENTS.md' > "$REPO_IGN/.gitignore"
printf '%s\n' '# team agents file' > "$REPO_IGN/AGENTS.md"
OUTPUT=$(cd "$REPO_IGN" && "$WV" init-repo --agent=claude,codex --codex-hooks 2>&1)
assert_contains "$OUTPUT" "written for the team but hidden from git by this repository's ignore rules" "ignored surfaces: init-repo reports hidden surfaces"
assert_contains "$OUTPUT" ".codex/weave.json  (rule .gitignore:1:*.json)" "ignored surfaces: init-repo names .codex/weave.json with its rule"
assert_contains "$OUTPUT" ".codex/hooks.json  (rule .gitignore:1:*.json)" "ignored surfaces: init-repo names .codex/hooks.json with its rule"
assert_contains "$OUTPUT" "CLAUDE.md  (rule .gitignore:2:*.md)" "ignored surfaces: init-repo names CLAUDE.md with its rule"
assert_not_contains "$OUTPUT" "AGENTS.md  (rule" "ignored surfaces: a re-included surface is not named"
DOCTOR=$(cd "$REPO_IGN" && "$WV" doctor --json 2>/dev/null | jq -c '[.checks[] | select(.check == "shared surfaces")][0]')
assert_contains "$DOCTOR" '"status":"warn"' "ignored surfaces: doctor warns"
assert_contains "$DOCTOR" ".codex/weave.json (rule .gitignore:1:*.json)" "ignored surfaces: doctor names the surface and rule"
git -C "$REPO_IGN" add -A -f
DOCTOR=$(cd "$REPO_IGN" && "$WV" doctor --json 2>/dev/null | jq -c '[.checks[] | select(.check == "shared surfaces")][0]')
assert_contains "$DOCTOR" '"status":"pass"' "ignored surfaces: once tracked (git add -f), doctor passes"

OUTPUT=$("$WV" init-repo --agent=codex --force --codex-hooks 2>&1)
assert_file_exists "$REPO_CODEX/.codex/hooks.json"             "codex: --codex-hooks generates project hooks"
assert_contains "$(cat "$REPO_CODEX/.codex/hooks.json")" '"PreToolUse"' "codex: hook config includes edit guard"
assert_contains "$(cat "$REPO_CODEX/.codex/hooks.json")" 'hook dispatch --event=PostToolUse --format=host' "codex: hook config calls shared dispatcher"
# Codex blocks only on exit 2 with a stderr reason or exit 0 with deny JSON;
# --json's exit 1 reads as a failed hook, so the guard must use --format=host (wv-5b774a).
assert_contains "$(cat "$REPO_CODEX/.codex/hooks.json")" 'hook dispatch --event=PreToolUse --format=host' "codex: edit guard answers in a shape Codex honours"
assert_contains "$(cat "$REPO_CODEX/.codex/hooks.json")" 'hook dispatch --event=Stop --format=host' "codex: stop guard answers in a shape Codex honours (wv-25903d)"
assert_contains "$(cat "$REPO_CODEX/.codex/hooks.json")" 'hook dispatch --event=PreCompact --format=host' "codex: hook config checkpoints before compaction"
assert_contains "$(cat "$REPO_CODEX/.codex/weave.json")" '"enabled": 1' "codex: opt-in contract records hooks enabled"
assert_contains "$OUTPUT" 'Review and trust these project hooks with /hooks' "codex: opt-in prints trust guidance"
# A consumer's hooks call the installed wv, absolute, since hooks run without
# the login PATH; none names the scripts/wv it lacks (wv-dce969).
CODEX_HOOKS_JSON=$(cat "$REPO_CODEX/.codex/hooks.json")
# shellcheck disable=SC2016  # the expected text holds a literal $HOME or $(...)
assert_equals "5 0" "$(jq -r '[.hooks[][].hooks[].command] | "\(map(select(startswith("\"$HOME/.local/bin/wv\" hook dispatch"))) | length) \(map(select(test("scripts/wv"))) | length)"' <<< "$CODEX_HOOKS_JSON")" \
    "codex: all five consumer hooks call the installed wv and none names scripts/wv"
NO_AGENTS=$(make_test_repo "codex-no-agents"); cd "$NO_AGENTS"
"$WV" init-repo --agent=codex >/dev/null 2>&1 || true
assert_file_exists "$NO_AGENTS/AGENTS.md" "codex: a consumer with no AGENTS.md gets one the contract can name"
assert_contains "$(cat "$NO_AGENTS/AGENTS.md" 2>/dev/null)" 'BEGIN WEAVE PROCEDURES' \
    "codex: ...from the shipped template, with the block procedures refresh"
# shellcheck disable=SC2016  # the expected text holds literal backticks
assert_not_contains "$(cat "$NO_AGENTS/AGENTS.md" 2>/dev/null)" 'repo-local `./scripts/wv` wrapper' \
    "codex: ...which sends a consumer to the installed wv, not a scripts/wv it lacks"
cd "$REPO_CODEX"

# --- --agent=all creates all supported agent surfaces ---
echo ""
echo "--- --agent=all ---"
REPO4=$(make_test_repo "all")
cd "$REPO4"

OUTPUT=$("$WV" init-repo --agent=all 2>&1)
assert_file_exists "$REPO4/.claude/settings.json"           "all: creates .claude/settings.json"
assert_file_exists "$REPO4/CLAUDE.md"                       "all: creates CLAUDE.md"
assert_file_exists "$REPO4/.vscode/mcp.json"               "all: creates .vscode/mcp.json"
assert_equals "absent" "$([ -e "$REPO4/.mcp.json" ] && echo present || echo absent)" \
    "all: writes no VS Code-shaped root .mcp.json"
assert_file_exists "$REPO4/.github/copilot-instructions.md" "all: creates copilot-instructions.md"
assert_file_exists "$REPO4/.codex/weave.json"               "all: creates Codex contract"

# settings.json still has no hooks key
SETTINGS4=$(cat "$REPO4/.claude/settings.json")
assert_not_contains "$SETTINGS4" '"hooks"'                  "all: settings.json has NO hooks key"

# --- rc.15 rollout findings: the proposal is not graph dirt, a decline is
# durable, and an update reports what it added (wv-0f6962, wv-ef9ba9) ---
echo ""
echo "--- --update: proposal dirt, decline, additions ---"
REPO4B=$(make_test_repo "rollout")
cd "$REPO4B"
OUTPUT=$("$WV" init-repo --agent=claude --update 2>&1)
assert_contains "$OUTPUT" "Added by this update (not present before" \
    "--update on a never-scaffolded repository says it added files"
# The count the summary reports equals the files that appeared (the fixture
# started empty), and the list names them. Which file sorts into the printed
# 40 varies by platform: an assertion on one name failed on ubuntu-26.04 (rc.16).
_added_n=$(grep -oE 'beyond a refresh\): [0-9]+ file' <<< "$OUTPUT" | grep -oE '[0-9]+')
_actual_n=$(cd "$REPO4B" && find . -path ./.git -prune -o -type f -print | wc -l | tr -d ' ')
assert_equals "$_actual_n" "${_added_n:-none}" "--update: the added count is every file that appeared"
assert_contains "$OUTPUT" "  + " "--update: names the added files"
OUTPUT=$("$WV" init-repo --agent=claude --update 2>&1)
assert_not_contains "$OUTPUT" "Added by this update" \
    "--update on an already-scaffolded repository reports no additions"
if git -C "$REPO4B" check-ignore -q .weave/gate-provision.proposed.json; then
    echo -e "  ${GREEN}✓${NC} the proposal path is ignored in the consumer .gitignore"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗${NC} the proposal path should be ignored in the consumer .gitignore"
fi
TESTS_RUN=$((TESTS_RUN + 1))
printf '{}\n' > "$REPO4B/.weave/gate-provision.proposed.json"
printf 'declined 2026-11-10: no frozen suites wanted here\n' > "$REPO4B/.weave/gate-provision.declined"
OUTPUT=$("$WV" init-repo --agent=claude --update 2>&1)
assert_contains "$OUTPUT" "declined by .weave/gate-provision.declined" \
    "--update respects a durable decline"
assert_file_absent "$REPO4B/.weave/gate-provision.proposed.json" \
    "--update removes the proposal a decline supersedes"

# --- --update refreshes managed files ---
echo ""
echo "--- --update ---"
REPO5=$(make_test_repo "update")
cd "$REPO5"

# First init
"$WV" init-repo --agent=all >/dev/null

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
"$WV" init-repo --agent=all --update >/dev/null
PATTERN_HASH_AFTER=$(find "$REPO5/.weave/patterns" -type f -print0 | sort -z | xargs -0 sha256sum)
assert_equals "$PATTERN_HASH_BEFORE" "$PATTERN_HASH_AFTER" \
    "--update: managed pattern projection is idempotent"

# --- authoring templates: the consumer's side of the guide contract ---
# Weave templated nothing a consumer could author a guide against, so two
# unrelated consumer repos each built the same tooling alone. These cover the
# seeding contract: agent-neutral, seed never clobbers, refresh keeps current.
echo ""
echo "--- authoring templates ---"
REPO_AUTHOR=$(make_test_repo "authoring")
cd "$REPO_AUTHOR"

# --agent=codex, not claude: guides are agent-neutral and must not be scaffolded
# out of the Claude branch, which is where the sibling seeded templates live.
"$WV" init-repo --agent=codex >/dev/null 2>&1
assert_file_exists "$REPO_AUTHOR/.weave/guides.README.md" \
    "authoring: seeds the guide contract regardless of agent"
assert_file_exists "$REPO_AUTHOR/.weave/guides/example-violation.md" \
    "authoring: seeds a guide to copy"
assert_contains "$(cat "$REPO_AUTHOR/.weave/guides.README.md")" "sections:" \
    "authoring: the contract documents the declared-section extension"
assert_contains "$(cat "$REPO_AUTHOR/.weave/guides.README.md")" "upstream" \
    "authoring: the contract documents the promotion path"

# The resolution directory holds guides and nothing else, so anything that globs
# it -- doctor's guide-shadow advisory, a consumer's own validator -- never has
# to special-case a file that is not a guide.
GUIDE_DIR_ENTRIES=$(ls "$REPO_AUTHOR/.weave/guides")
assert_equals "example-violation.md" "$GUIDE_DIR_ENTRIES" \
    "authoring: nothing but guides is seeded into .weave/guides/"

# The seeded guide must satisfy the shipped parser, not merely look like a guide.
if PYTHONPATH="$WV_LIB_DIR" python3 -c "
import sys
from pathlib import Path
from weave_quality.guides import parse_guide
parse_guide(Path(sys.argv[1]), 'project')
" "$REPO_AUTHOR/.weave/guides/example-violation.md" 2>"$TEST_DIR/authoring-parse.err"; then
    TESTS_RUN=$((TESTS_RUN + 1)); TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}✓${NC} authoring: the seeded guide parses with the shipped parser"
else
    TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}✗${NC} authoring: the seeded guide parses with the shipped parser"
    sed 's/^/    /' "$TEST_DIR/authoring-parse.err"
fi

# seed mode: an authored file is never overwritten, which is the whole point of
# handing a consumer a starting point rather than a managed asset.
echo "AUTHORED HERE" >> "$REPO_AUTHOR/.weave/guides/example-violation.md"
echo "stale" > "$REPO_AUTHOR/.weave/guides.README.md"
"$WV" init-repo --agent=codex --update >/dev/null 2>&1
assert_contains "$(cat "$REPO_AUTHOR/.weave/guides/example-violation.md")" "AUTHORED HERE" \
    "authoring: --update preserves an authored guide"
assert_not_contains "$(cat "$REPO_AUTHOR/.weave/guides.README.md")" "stale" \
    "authoring: --update refreshes the contract reference"

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
    assert_equals "0" "$(( $(find "$TEST_DIR/pattern-external" -mindepth 1 | wc -l) ))" \
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
    assert_equals "0" "$(( $(find "$TEST_DIR/weave-external" -mindepth 1 | wc -l) ))" \
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
    "$WV" init-repo --agent=copilot --update >/dev/null
    if [ -f "$REPO5/.vscode/settings.json" ]; then
        VS5=$(cat "$REPO5/.vscode/settings.json")
        assert_not_contains "$VS5" 'chat.hooks.enabled'     "--update: strips ghost setting from .vscode/settings.json"
    else
        TESTS_RUN=$((TESTS_RUN + 1)); TESTS_PASSED=$((TESTS_PASSED + 1)); echo -e "${GREEN}✓${NC} --update: .vscode/settings.json cleaned up"
    fi
fi

# --update should prepend Weave block but preserve user content
echo "my custom content" > "$REPO5/CLAUDE.md"
"$WV" init-repo --update >/dev/null
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
"$WV" init-repo --agent=copilot --update >/dev/null
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
assert_contains "$(cat "$REPO6/.gitattributes")" "quality-adjudications.jsonl merge=union" "gitattr: adjudications use union merge"
assert_contains "$(cat "$REPO6/.gitattributes")" "deltas/**/*.sql merge=theirs" "gitattr: has deltas merge=theirs"
# wv-8595fb: concurrent trails notes merge through the installed driver.
assert_contains "$(cat "$REPO6/.gitattributes")" ".weave/trails.md merge=wv-trails" "gitattr: trails.md uses the notes-aware driver"
assert_contains "$(git -C "$REPO6" config --get merge.wv-trails.driver)" "$WV_LIB_DIR/merge-trails.py" "gitattr: the trails driver runs the installed script"
assert_file_exists "$WV_LIB_DIR/merge-trails.py" "install: the trails merge driver is installed"
assert_contains "$(cat "$REPO6/.gitignore")" "!.weave/quality-adjudications.jsonl" "gitignore: adjudication projection remains tracked"

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
if grep -qxF '.weave/state.sql merge=ours' <<< "$GA7"; then
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -e "${RED}✗${NC} gitattr upgrade: bare entry stripped"
    TESTS_FAILED=$((TESTS_FAILED + 1))
else
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -e "${GREEN}✓${NC} gitattr upgrade: bare entry stripped"
    TESTS_PASSED=$((TESTS_PASSED + 1))
fi

# --- runtime ignores: one list, and committed runtime state named (wv-9a54da) ---
echo ""
echo "--- gitignore: runtime ignores ---"
REPO8=$(make_test_repo "runtime-ignores")
cd "$REPO8"
mkdir -p .weave
printf 'a.sql\n' > .weave/.applied_deltas
printf '{}\n' > .weave/sync-digest-cache.json
printf 'graph\n' > .weave/state.sql
git add -A && git -c user.name=t -c user.email=t@t commit -qm "consumer committed runtime state"
OUT8=$("$WV" init-repo --update --agent=claude 2>&1)
GI8=$(cat "$REPO8/.gitignore")
# shellcheck source=scripts/lib/wv-runtime-ignores.sh
source "$PROJECT_ROOT/scripts/lib/wv-runtime-ignores.sh"
missing8=""
while IFS= read -r entry; do
    grep -qxF -- "$entry" <<< "$GI8" || missing8="$missing8 $entry"
done < <(wv_runtime_ignores)
assert_equals "" "$missing8" "runtime ignores: every canonical entry is in the consumer .gitignore"
assert_contains "$OUT8" "git rm --cached -- .weave/.applied_deltas .weave/sync-digest-cache.json" \
    "runtime ignores: already-tracked runtime files are named with the command that untracks them"
assert_not_contains "$OUT8" "git rm --cached -- .weave/state.sql" "runtime ignores: graph state is not named"
assert_equals ".weave/.applied_deltas" "$(git ls-files .weave/.applied_deltas)" \
    "runtime ignores: init-repo leaves the index to the operator"

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
# Simulate a repo scaffolded before pre-push-weave.sh existed: 2 of 3 sources.
_LIB_HOOKS_DIR="$WV_LIB_DIR/hooks"
if [ -f "$_LIB_HOOKS_DIR/pre-commit-weave.sh" ]; then
    cp "$_LIB_HOOKS_DIR/pre-commit-weave.sh" scripts/hooks/
    cp "$_LIB_HOOKS_DIR/prepare-commit-msg-weave.sh" scripts/hooks/
    # pre-push-weave.sh intentionally absent
    "$WV" init-repo --update --agent=claude >/dev/null 2>&1
    assert_file_exists "$REPO10/scripts/hooks/pre-push-weave.sh" \
        "vendor seed: missing hook source is seeded on --update"
    # And it matches the canonical lib copy
    if cmp -s "$_LIB_HOOKS_DIR/pre-push-weave.sh" "$REPO10/scripts/hooks/pre-push-weave.sh"; then
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


# --- install.sh --update keeps the Codex contract's memory entries (wv-2ab164) ---
# _write_codex_contract rewrites .codex/weave.json whole, and memory.entries[]
# is not in its template: wv memory render --agent=codex fills it from the
# graph. So every --update silently emptied the Codex agent's memory until the
# next render. --update now re-renders the entries from the graph.
echo ""
echo "--- codex memory entries survive --update ---"
REPO_CX=$(make_test_repo "codex-memory")
cd "$REPO_CX"
"$WV" init-repo --agent=codex >/dev/null 2>&1
"$WV" remember "codex memory fixture fact" >/dev/null 2>&1
"$WV" memory render --agent=codex >/dev/null 2>&1
CX_BEFORE=$(jq -r '.memory.entries | length' .codex/weave.json 2>/dev/null || echo missing)
assert_equals "1" "$CX_BEFORE" "codex memory: render puts the graph memory in the contract (precondition)"
"$WV" init-repo --update --agent=codex >/dev/null 2>&1
assert_equals "$CX_BEFORE" "$(jq -r '.memory.entries | length' .codex/weave.json 2>/dev/null || echo missing)" \
    "codex memory: --update keeps the contract's memory entries"
assert_contains "$(jq -r '.memory.entries[].text // empty' .codex/weave.json 2>/dev/null)" "codex memory fixture fact" \
    "codex memory: the kept entry is the graph's memory"
# --- --update turns a full-text memory block into the index (wv-91f0ca) ---
# The projections now carry one line per memory. A consumer upgraded with
# --update had its old full-text block until a memory changed; --update now
# re-renders a block that is there, and adds none where the user has none.
echo ""
echo "--- --update refreshes an existing memory block to the index ---"
REPO_MI=$(make_test_repo "memory-index")
cd "$REPO_MI"
"$WV" init-repo --agent=claude >/dev/null 2>&1
"$WV" remember "Index fixture first sentence. MEMORY-INDEX-SECOND-SENTENCE belongs to the full text only." >/dev/null 2>&1
printf '%s\n' '<!-- ── BEGIN WEAVE:MEMORY ── managed by wv memory render, do not edit manually -->' \
    '## WEAVE:MEMORY' '' '- [`wv-000000`] an old full-text entry MEMORY-INDEX-SECOND-SENTENCE (verified: unknown)' \
    '<!-- ── END WEAVE:MEMORY ── -->' >> CLAUDE.md
"$WV" init-repo --update --agent=claude >/dev/null 2>&1
MI_BLOCK=$(sed -n '/BEGIN WEAVE:MEMORY/,/END WEAVE:MEMORY/p' CLAUDE.md)
assert_contains "$MI_BLOCK" "Index fixture first sentence." "memory index: --update re-renders the existing block from the graph"
assert_equals "0" "$(grep -c 'MEMORY-INDEX-SECOND-SENTENCE' <<< "$MI_BLOCK" || true)" "memory index: the block carries the index, not the full text"
REPO_MN=$(make_test_repo "memory-noblock")
cd "$REPO_MN"
"$WV" init-repo --agent=claude >/dev/null 2>&1
"$WV" remember "A memory in a repo whose CLAUDE.md has no block" >/dev/null 2>&1
"$WV" init-repo --update --agent=claude >/dev/null 2>&1
assert_equals "0" "$(grep -c 'WEAVE:MEMORY' CLAUDE.md || true)" "memory index: --update adds no block to a CLAUDE.md without one"
# --- the skills a consumer gets are the skills install.sh installs (wv-b49316, wv-fb2c31) ---
# install.sh named its skills twice: WV_CONFIG_SKILLS (what it writes to CONFIG_DIR) and a SKILLS
# array wv init-repo copied into a consumer. The breadcrumbs -> trails rename
# reached only the first, so consumers kept a deprecated skill and never got
# trails. wv-b49316 tested that the two lists agreed; wv-fb2c31 removed the
# second list: wv init-repo reads the manifest install.sh writes from
# WV_CONFIG_SKILLS, so the two cannot disagree. --update must deliver trails.
echo ""
echo "--- consumer skills match the installed skills ---"
SK_INIT=$(sed -n "/^cat > \"\$INSTALL_DIR\/wv-init-repo\" << 'INITEOF'/,/^INITEOF\$/p" "$PROJECT_ROOT/install.sh")
assert_equals "0" "$(grep -cE '^ +SKILLS=\([a-z]' <<< "$SK_INIT" || true)" \
    "skills: wv init-repo carries no skill list of its own"
# From the opening line through the first line with ')': a /start/,/)/ sed
# range looks for its end only from the next line, so a one-line array ran on to
# a later ')' (wv-1fc64f). awk, not sed's ':a;...;ba': BSD sed ends a label at
# the newline, so ';' joined it to the label name (wv-0bf286).
SK_CONFIG=$(awk '/^WV_CONFIG_SKILLS=\(/ { f = 1 } f { print; if (/\)/) exit }' "$PROJECT_ROOT/install.sh" | tr '\n' ' ' \
    | sed 's/^WV_CONFIG_SKILLS=(//; s/)//' | tr ' ' '\n' | { grep . || true; } | sort -u | tr '\n' ' ')
# Both sets are empty since every Weave skill is a projection (wv-c7f784); an
# empty grep must not end the suite under pipefail.
SK_MANIFEST=$({ grep . "$WV_CONFIG_DIR/skills/.weave-installed" 2>/dev/null || true; } | sort -u | tr '\n' ' ')
assert_equals "$SK_CONFIG" "$SK_MANIFEST" "skills: the installed manifest is the WV_CONFIG_SKILLS set"
# Negative control: a skill named only in the manifest reaches the consumer,
# so the manifest is what wv init-repo reads.
if [ -f "$WV_CONFIG_DIR/skills/.weave-installed" ]; then
    cp "$WV_CONFIG_DIR/skills/.weave-installed" "$TEST_INSTALL/manifest.saved"
    mkdir -p "$WV_CONFIG_DIR/skills/zz-manifest-probe"
    printf -- '---\nname: zz-manifest-probe\n---\nprobe\n' > "$WV_CONFIG_DIR/skills/zz-manifest-probe/SKILL.md"
    echo zz-manifest-probe >> "$WV_CONFIG_DIR/skills/.weave-installed"
    REPO_SKM=$(make_test_repo "skills-manifest")
    cd "$REPO_SKM"
    "$WV" init-repo --update --agent=claude >/dev/null 2>&1
    assert_file_exists "$REPO_SKM/.claude/skills/zz-manifest-probe/SKILL.md" \
        "skills: a skill named only in the manifest is delivered (the manifest is read)"
    cp "$TEST_INSTALL/manifest.saved" "$WV_CONFIG_DIR/skills/.weave-installed"
    rm -rf "$WV_CONFIG_DIR/skills/zz-manifest-probe"
fi
# trails is a projection of the agent-memory procedure (wv-d231af), not an
# install.sh skill: --update delivers it through project-procedures.sh.
REPO_SK=$(make_test_repo "skills-trails")
cd "$REPO_SK"
"$WV" init-repo --update --agent=claude >/dev/null 2>&1
assert_file_exists "$REPO_SK/.claude/skills/trails/SKILL.md" "skills: --update delivers trails to a consumer"
assert_contains "$(cat "$REPO_SK/.claude/skills/trails/SKILL.md" 2>/dev/null)" "WEAVE-MANAGED-SKILL" \
    "skills: the delivered trails is the agent-memory procedure's projection"
assert_equals "absent" "$([ -e "$REPO_SK/.claude/skills/breadcrumbs" ] && echo present || echo absent)" \
    "skills: --update no longer delivers the deprecated breadcrumbs skill"

# --- scripts/hooks/ vendor refresh is gated on --update/--force (wv-d6e9ba) ---
# install.sh overwrote a differing vendored hook source on every run, so a plain
# `wv init-repo` silently reverted a local hook edit. A differing source is now
# refreshed only on --update/--force, with the notice the other gated copies
# print; seeding a missing source stays ungated (wv-2adeef, above).
echo ""
echo "--- vendor hook-source refresh is gated ---"
if [ -f "$_LIB_HOOKS_DIR/pre-commit-weave.sh" ]; then
    REPO_VG=$(make_test_repo "vendor-gate")
    cd "$REPO_VG"
    mkdir -p scripts/hooks
    cp "$_LIB_HOOKS_DIR/pre-commit-weave.sh" scripts/hooks/
    cp "$_LIB_HOOKS_DIR/prepare-commit-msg-weave.sh" scripts/hooks/
    printf '\n# local edit (wv-d6e9ba)\n' >> scripts/hooks/pre-commit-weave.sh
    VG_EDITED=$(cksum < scripts/hooks/pre-commit-weave.sh)
    VG_OUT=$("$WV" init-repo --agent=claude 2>&1)
    assert_equals "$VG_EDITED" "$(cksum < scripts/hooks/pre-commit-weave.sh)" \
        "vendor gate: a plain init-repo leaves a locally edited hook source alone"
    assert_contains "$VG_OUT" "scripts/hooks/pre-commit-weave.sh (exists, use --update to overwrite)" \
        "vendor gate: the skip prints the exists-use-update notice"
    assert_file_exists "$REPO_VG/scripts/hooks/pre-push-weave.sh" \
        "vendor gate: a missing hook source is still seeded without --update"
    "$WV" init-repo --update --agent=claude >/dev/null 2>&1
    if cmp -s "$_LIB_HOOKS_DIR/pre-commit-weave.sh" scripts/hooks/pre-commit-weave.sh; then
        TESTS_RUN=$((TESTS_RUN + 1)); TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "${GREEN}✓${NC} vendor gate: --update refreshes the edited source"
    else
        TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "${RED}✗${NC} vendor gate: --update refreshes the edited source"
    fi
else
    TESTS_RUN=$((TESTS_RUN + 1)); TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${YELLOW}⊘${NC} vendor gate: skipped (lib hooks not installed)"
fi

# The retired post-commit hook (wv-56c823): --update removes a Weave copy and
# its vendored source, and leaves a custom post-commit hook alone.
REPO_PC=$(make_test_repo "retire-postcommit")
cd "$REPO_PC"
mkdir -p scripts/hooks .git/hooks
printf '#!/usr/bin/env bash\n# Weave post-commit hook: run deferred non-critical suites queued by pre-commit.\n' \
    | tee .git/hooks/post-commit > scripts/hooks/post-commit-weave.sh
chmod +x .git/hooks/post-commit scripts/hooks/post-commit-weave.sh
"$WV" init-repo --update --agent=claude >/dev/null 2>&1
assert_file_absent "$REPO_PC/.git/hooks/post-commit" "retired post-commit: a Weave copy is removed on --update"
assert_file_absent "$REPO_PC/scripts/hooks/post-commit-weave.sh" "retired post-commit: its vendored source is removed on --update"
REPO_PC_CUSTOM=$(make_test_repo "retire-postcommit-custom")
cd "$REPO_PC_CUSTOM"
mkdir -p .git/hooks
printf '#!/bin/sh\necho "my own post-commit"\n' > .git/hooks/post-commit
chmod +x .git/hooks/post-commit
"$WV" init-repo --update --agent=claude >/dev/null 2>&1
assert_file_exists "$REPO_PC_CUSTOM/.git/hooks/post-commit" "retired post-commit: a custom post-commit hook is left alone"

# A single update must converge both the tracked source and its installed hook.
# The old order installed .git/hooks/pre-commit from the stale tracked source,
# then refreshed scripts/hooks/pre-commit-weave.sh, leaving doctor to require a
# second update before the two files matched.
REPO10_ORDER=$(make_test_repo "vendor-refresh-order")
cd "$REPO10_ORDER"
mkdir -p scripts/hooks
printf '#!/bin/sh\n# Weave pre-commit\n# stale vendored source\n' > scripts/hooks/pre-commit-weave.sh
chmod +x scripts/hooks/pre-commit-weave.sh
"$WV" init-repo --update --agent=claude >/dev/null 2>&1
if cmp -s "$_LIB_HOOKS_DIR/pre-commit-weave.sh" "$REPO10_ORDER/scripts/hooks/pre-commit-weave.sh" \
    && cmp -s "$REPO10_ORDER/scripts/hooks/pre-commit-weave.sh" "$REPO10_ORDER/.git/hooks/pre-commit"; then
    HOOK_SOURCE_PARITY=yes
else
    HOOK_SOURCE_PARITY=no
fi
assert_equals "yes" "$HOOK_SOURCE_PARITY" \
    "vendor refresh: one update leaves tracked and installed pre-commit hooks identical"

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
assert_equals "0" "$(( $(find . -path ./.git -prune -o -type f -print | wc -l) ))" \
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
    assert_equals "0" "$(( $(find . -path ./.git -prune -o -type f -print | wc -l) ))" \
        "repo-class: ambiguous refusal occurs before first worktree write"
fi
# The refusal's hint must name the flag its owned override then demands; it
# used to name it only for a vendored-upstream class (wv-bd5115).
AMBIG_HINT=$("$WV" init-repo 2>&1 >/dev/null || true)
assert_contains "$AMBIG_HINT" "wv repo-class set owned --acknowledge-upstream-fork" \
    "repo-class: an ambiguous refusal names the flag the owned override demands"

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
    assert_equals "0" "$(( $(find .weave -type f 2>/dev/null | wc -l) ))" \
        "repo-class: refused wv init creates no graph files"
fi
REPO_CLASS_OTHER=$(make_test_repo "repo-class-other-cwd")
cd "$REPO_CLASS_OTHER"
if env -u WV_DB -u WV_DB_CUSTOM WEAVE_DIR="$REPO_CLASS_AUDIT/.weave" \
    WV_HOT_ZONE="$TEST_DIR/repo-class-other-hot" "$WV" init >/dev/null 2>&1; then
    assert_equals "refused" "allowed" "repo-class: wv init guards the persistent target, not caller cwd"
else
    assert_equals "0" "$(( $(find "$REPO_CLASS_AUDIT/.weave" -type f 2>/dev/null | wc -l) ))" \
        "repo-class: cross-directory init refusal creates no graph files"
fi
SYMLINK_TARGET="$TEST_DIR/repo-class-symlink-target"
mkdir -p "$SYMLINK_TARGET"
ln -s "$SYMLINK_TARGET" "$REPO_CLASS_OTHER/.weave"
if env -u WV_DB -u WV_DB_CUSTOM WEAVE_DIR="$REPO_CLASS_OTHER/.weave" \
    WV_HOT_ZONE="$TEST_DIR/repo-class-symlink-hot" "$WV" init --force >/dev/null 2>&1; then
    assert_equals "refused" "allowed" "repo-class: wv init refuses symlinked persistent target"
else
    assert_equals "0" "$(( $(find "$SYMLINK_TARGET" -type f | wc -l) ))" \
        "repo-class: symlink refusal writes nothing through the target"
fi
if env -u WV_DB -u WV_DB_CUSTOM WEAVE_DIR="$REPO_CLASS_AUDIT/.weave" \
    WV_HOT_ZONE="$TEST_DIR/repo-class-doctor-hot" "$WV" doctor --repair >/dev/null 2>&1; then
    assert_equals "refused" "allowed" "repo-class: doctor repair guards persistent target, not caller cwd"
else
    assert_equals "0" "$(( $(find "$REPO_CLASS_AUDIT/.weave" -type f 2>/dev/null | wc -l) ))" \
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

# S0 provisioning diagnostics are advisory and never execute the suite scripts.
REPO_GATE_PATHS=$(make_test_repo gate-paths)
cd "$REPO_GATE_PATHS"
mkdir -p .weave checks
printf 'venv_ee/\n.private/\n' > .gitignore
cat > .weave/test-map.conf <<'EOF'
[map]
src/ = checks/unconditional.sh
[default]
checks/default.sh
[scanners]
checks/scanner.sh = scripts/**
[heavy]
checks/not-routed.sh
[inputs]
checks/not-routed.sh = src/**
EOF
cat > checks/unconditional.sh <<'EOF'
touch suite-was-executed
source venv_ee/bin/activate
EOF
cat > checks/default.sh <<'EOF'
ACTIVATE=".private/bin/activate"
if [ -f "$ACTIVATE" ]; then source "$ACTIVATE"; fi
EOF
cat > checks/scanner.sh <<'EOF'
# .private/comment-only is not a literal script argument.
PY=.private/bin/python
"$PY" -m pytest
EOF
cat > checks/not-routed.sh <<'EOF'
source .private/not-routed
EOF
OUTPUT=$("$WV" init-repo --agent=codex 2>&1)
assert_contains "$OUTPUT" 'gate ignored paths:' "init-repo emits the advisory without refusing setup"
assert_contains "$OUTPUT" 'venv_ee/bin/activate' "init-repo identifies unconditional ignored activation"
DOCTOR_JSON=$("$WV" doctor --json 2>/dev/null || true)
GATE_PATH_STATUS=$(jq -r '.checks[] | select(.check == "gate ignored paths") | .status' <<< "$DOCTOR_JSON")
GATE_PATH_DETAIL=$(jq -r '.checks[] | select(.check == "gate ignored paths") | .detail' <<< "$DOCTOR_JSON")
assert_equals warn "$GATE_PATH_STATUS" "doctor reports ignored paths as WARN, not FAIL"
assert_contains "$GATE_PATH_DETAIL" 'checks/default.sh:' "default suites are inspected"
assert_contains "$GATE_PATH_DETAIL" '.private/bin/activate' "guarded activation assignment is inspected"
assert_contains "$GATE_PATH_DETAIL" 'checks/scanner.sh:' "scanner suites are inspected"
assert_contains "$GATE_PATH_DETAIL" '.private/bin/python' "literal interpreter assignment is inspected"
assert_not_contains "$GATE_PATH_DETAIL" 'comment-only' "comments do not invent ignored-path references"
assert_not_contains "$GATE_PATH_DETAIL" 'not-routed' "heavy and input entries alone do not create routes"
assert_file_absent "$REPO_GATE_PATHS/suite-was-executed" "diagnostics never execute routed scripts"
OUTPUT=$("$WV" doctor 2>/dev/null || true)
assert_contains "$OUTPUT" 'gate ignored paths:' "text doctor emits the same advisory"
assert_contains "$OUTPUT" 'venv_ee/bin/activate' "text doctor identifies the literal ignored path"

# An ignored gate declaration never reaches a commit (wv-bca9ec): the gate
# reads it from committed blobs only, so git add skips it and the repository
# stays on its default with no message.
REPO_DECL_IGNORED=$(make_test_repo decl-ignored)
cd "$REPO_DECL_IGNORED"
mkdir -p .weave checks
printf '*.json\n' > .gitignore
printf 'docs/ = checks/docs.sh\n' > .weave/test-map.conf
printf 'exit 0\n' > checks/docs.sh
printf '{"version": 3, "default": {"mode": "checkout"}, "recipes": {}, "suites": {}}\n' > .weave/gate-provision.json
OUTPUT=$("$WV" init-repo --agent=codex 2>&1)
assert_contains "$OUTPUT" '.weave/gate-provision.json is ignored by .gitignore:1:*.json' \
    "init-repo names the rule that ignores the gate declaration"
assert_contains "$OUTPUT" '!.weave/gate-provision.json' "init-repo gives the exception line"
DECL_DETAIL=$(jq -r '.checks[] | select(.check == "gate ignored paths") | .detail' <<< "$("$WV" doctor --json 2>/dev/null || true)")
assert_contains "$DECL_DETAIL" '.weave/gate-provision.json is ignored' "doctor warns about the ignored declaration"
printf '!.weave/gate-provision.json\n' >> .gitignore
DECL_DETAIL=$(jq -r '.checks[] | select(.check == "gate ignored paths") | .detail' <<< "$("$WV" doctor --json 2>/dev/null || true)")
assert_not_contains "$DECL_DETAIL" 'gate-provision.json' "with the exception, no declaration warning"
printf '*.json\n' > .gitignore
git add -f .weave/gate-provision.json
DECL_DETAIL=$(jq -r '.checks[] | select(.check == "gate ignored paths") | .detail' <<< "$("$WV" doctor --json 2>/dev/null || true)")
assert_not_contains "$DECL_DETAIL" 'gate-provision.json' "a tracked declaration is not reported as ignored"
cd "$REPO_GATE_PATHS"

# A symlinked declaration or suite must not read outside this repository.
cp .weave/test-map.conf "$TEST_DIR/outside-map.conf"
mv .weave/test-map.conf .weave/test-map.saved
ln -s "$TEST_DIR/outside-map.conf" .weave/test-map.conf
DOCTOR_JSON=$("$WV" doctor --json 2>/dev/null || true)
GATE_PATH_DETAIL=$(jq -r '.checks[] | select(.check == "gate ignored paths") | .detail' <<< "$DOCTOR_JSON")
assert_contains "$GATE_PATH_DETAIL" 'test-map.conf is outside the repository' "outside declarations are refused before reading"
rm .weave/test-map.conf
mv .weave/test-map.saved .weave/test-map.conf
printf 'source .private/outside-script\n' > "$TEST_DIR/outside-suite.sh"
rm checks/unconditional.sh
ln -s "$TEST_DIR/outside-suite.sh" checks/unconditional.sh
DOCTOR_JSON=$("$WV" doctor --json 2>/dev/null || true)
GATE_PATH_DETAIL=$(jq -r '.checks[] | select(.check == "gate ignored paths") | .detail' <<< "$DOCTOR_JSON")
assert_contains "$GATE_PATH_DETAIL" 'checks/unconditional.sh: routed script unavailable' "outside suite symlinks are not followed"
assert_not_contains "$GATE_PATH_DETAIL" 'outside-script' "outside suite contents are not inspected"
rm checks/unconditional.sh
printf 'source "${ENVIRONMENT}/bin/activate"\n' > checks/unconditional.sh
printf 'echo safe\n' > checks/default.sh
printf 'echo safe\n' > checks/scanner.sh
DOCTOR_JSON=$("$WV" doctor --json 2>/dev/null || true)
GATE_PATH_STATUS=$(jq -r '.checks[] | select(.check == "gate ignored paths") | .status' <<< "$DOCTOR_JSON")
assert_equals pass "$GATE_PATH_STATUS" "removing ignored references clears the advisory"
GATE_PATH_DETAIL=$(jq -r '.checks[] | select(.check == "gate ignored paths") | .detail' <<< "$DOCTOR_JSON")
assert_contains "$GATE_PATH_DETAIL" 'computed paths are not evaluated' "a clean literal scan does not certify dynamic paths"

# Exercise doctor with the installed CLI too, not only the checkout wrapper.
printf 'source .private/bin/activate\n' > checks/unconditional.sh
GATE_PATH_ZONE="$TEST_DIR/hotzone/$(printf '%s' "$REPO_GATE_PATHS" | cksum | cut -d' ' -f1)"  # as the wrapper names it
DOCTOR_JSON=$(WV_HOT_ZONE="$GATE_PATH_ZONE" WV_DB="$GATE_PATH_ZONE/brain.db" \
    "$TEST_INSTALL/bin/wv" doctor --json 2>/dev/null || true)
GATE_PATH_DETAIL=$(jq -r '.checks[] | select(.check == "gate ignored paths") | .detail' <<< "$DOCTOR_JSON")
assert_contains "$GATE_PATH_DETAIL" '.private/bin/activate' "installed doctor uses the shipped scanner"

# --- gate provisioning proposal (S4, wv-0ee3f4) ---
# init-repo proposes a declaration from the lockfiles it finds and never writes
# .weave/gate-provision.json: adopting a suite is the repository's decision.
echo ""
echo "--- gate provisioning proposal ---"
REPO_PROP=$(make_test_repo "provision-proposal")
cd "$REPO_PROP"
mkdir -p web tests
printf '[tool.poetry]\n' > pyproject.toml; printf '# lock\n' > poetry.lock
printf '{}\n' > web/package.json; printf '{}\n' > web/package-lock.json
printf '#!/usr/bin/env bash\n' > tests/test-unit.sh
mkdir -p .weave && printf '[map]\nsrc/ = tests/test-unit.sh\n' > .weave/test-map.conf
OUTPUT=$("$WV" init-repo --agent=codex 2>&1)
assert_file_exists "$REPO_PROP/.weave/gate-provision.proposed.json" "proposal: written beside the declaration"
assert_equals "absent" "$([ -e "$REPO_PROP/.weave/gate-provision.json" ] && echo present || echo absent)" \
    "proposal: the declaration itself is never written"
assert_contains "$OUTPUT" "gate-provision.proposed.json" "proposal: init-repo says where it is"
assert_equals "node-npm-web python-poetry" \
    "$(jq -r '.recipes | keys | join(" ")' .weave/gate-provision.proposed.json 2>/dev/null)" \
    "proposal: one recipe per locked toolchain"
assert_equals '["python-poetry","node-npm-web"]' \
    "$(jq -c '.suites["tests/test-unit.sh"].recipes' .weave/gate-provision.proposed.json 2>/dev/null)" \
    "proposal: the mapped suite is offered every detected recipe"
# The gate's own loader admits the proposal once it is adopted: committed, it
# is the base tree's declaration, which is what decides adoption (rule 1).
cp .weave/gate-provision.proposed.json .weave/gate-provision.json
git add -f .weave/gate-provision.json tests/test-unit.sh pyproject.toml poetry.lock web >/dev/null 2>&1
# Its own identity: the gate runs suites with an isolated HOME and no git config.
git -c user.email=t@t -c user.name=t -c core.hooksPath=/dev/null commit -qm "adopt the proposal" >/dev/null 2>&1
if PROP_DECL=$(python3 -I "$TEST_INSTALL/lib/lib/wv-gate-suite.py" --declarations \
        --policy "$TEST_INSTALL/lib/lib/wv-gate-provision.json" --repo "$REPO_PROP" --tree "HEAD^{tree}" \
        --base HEAD 2>&1); then
    assert_equals "true" "$(jq -r '.policy.suites | has("tests/test-unit.sh")' <<< "$PROP_DECL" 2>/dev/null)" \
        "proposal: the gate's loader admits it once adopted"
else
    assert_equals "admitted" "refused: $PROP_DECL" "proposal: the gate's loader admits it once adopted"
fi
OUTPUT=$("$WV" init-repo --agent=codex --update 2>&1)
assert_not_contains "$OUTPUT" "gate-provision.proposed.json (review" "proposal: no new proposal once a declaration exists"
REPO_UNLOCKED=$(make_test_repo "provision-unlocked")
cd "$REPO_UNLOCKED"
printf 'requests==2.0\n' > requirements.txt; mkdir -p scripts; printf '#!/usr/bin/env bash\n' > scripts/test-impacted.sh
OUTPUT=$("$WV" init-repo --agent=codex 2>&1)
assert_equals "absent" "$([ -e "$REPO_UNLOCKED/.weave/gate-provision.proposed.json" ] && echo present || echo absent)" \
    "proposal: an unlocked manifest proposes nothing"
assert_contains "$OUTPUT" "requirements.txt is a name-and-version list" "proposal: and says why"

# ─────────────────────────────────────────────────────────────────────────────
# Host hook contract (wv-0f70b5): every hook Weave registers, for every host,
# carries an explicit timeout inside that host's cap. A hook without one runs on
# the host's default budget, which the host can change without notice (Claude
# Code 2.1.74 cut SessionEnd to 1.5 s and the session-end routine failed on
# every exit for eight months, wv-a32e69). Reads the files this checkout's
# install.sh and init-repo generate, not install.sh's source text.
echo ""
echo "--- host hook contract ---"
REPO_HOOKS=$(make_test_repo "host-hooks")
cd "$REPO_HOOKS"
"$WV" init-repo --agent=codex,copilot --codex-hooks >/dev/null 2>&1 || true
# untimed <config>: "Event:command" for each hook without a numeric timeout > 0.
untimed() {
    jq -r '.hooks // {} | to_entries[] | .key as $ev
        | .value[]? | (if has("hooks") then .hooks[]? else . end)
        | select((.timeout | type) != "number" or .timeout <= 0)
        | "\($ev):\(.command)"' "$1" 2>&1
}
# over_cap <config> <event> <cap>: timeouts of <event> above <cap>.
over_cap() {
    jq -r --arg ev "$2" --argjson cap "$3" '[.hooks[$ev][]? | (if has("hooks") then .hooks[]? else . end)
        | .timeout | select(type == "number" and . > $cap)] | map(tostring) | join(" ")' "$1" 2>&1
}
for cfg in "$TEST_INSTALL/home/.claude/settings.json" "$REPO_HOOKS/.codex/hooks.json" "$REPO_HOOKS/.github/hooks/weave.json"; do
    assert_file_exists "$cfg" "host hooks: $(basename "$(dirname "$cfg")")/$(basename "$cfg") is generated"
    assert_equals "true" "$(jq -r '(.hooks // {}) | length > 0' "$cfg" 2>/dev/null)" \
        "host hooks: $(basename "$(dirname "$cfg")")/$(basename "$cfg") registers hooks"
    assert_equals "" "$(untimed "$cfg")" \
        "host hooks: every hook in $(basename "$(dirname "$cfg")")/$(basename "$cfg") has an explicit timeout"
done
# Documented caps: Claude Code raises the SessionEnd budget to a hook's timeout
# only up to 60 s; Codex 0.146.0 clamps SessionEnd to 3 s (default 1 s).
assert_equals "" "$(over_cap "$TEST_INSTALL/home/.claude/settings.json" SessionEnd 60)" \
    "host hooks: Claude Code SessionEnd timeout is within its 60 s cap"
assert_equals "" "$(over_cap "$REPO_HOOKS/.codex/hooks.json" SessionEnd 3)" \
    "host hooks: Codex SessionEnd timeout, if registered, is within its 3 s cap"
# The checker itself refuses an untimed hook, so the contract cannot pass vacuously.
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"x"}]}],"PreCompact":[{"type":"command","command":"y","timeout":0}]}}\n' \
    > "$REPO_HOOKS/untimed.json"
assert_equals "Stop:x PreCompact:y" "$(untimed "$REPO_HOOKS/untimed.json" | sort -r | tr '\n' ' ' | sed 's/ $//')" \
    "host hooks: the contract check flags a hook with no timeout or a zero one"

# wv doctor --agent reports each host's version and hook budgets, and flags a
# version that changed since the last run. Fake hosts on PATH keep it hermetic.
HOST_BIN="$TEST_DIR/fake-hosts"
mkdir -p "$HOST_BIN"
printf '#!/bin/sh\necho "codex-cli 0.146.0"\n' > "$HOST_BIN/codex"
chmod +x "$HOST_BIN/codex"
DOC_CFG="$TEST_DIR/doctor-config"
mkdir -p "$DOC_CFG"
DOC_OUT=$(PATH="$HOST_BIN:$PATH" WV_DOCTOR_HOSTS=codex WV_CONFIG_DIR="$DOC_CFG" "$WV" doctor --agent --json 2>/dev/null || true)
DOC_ROW=$(jq -r '[.checks[] | select(.check == "host hooks") | .detail | select(startswith("codex "))][0] // ""' <<<"$DOC_OUT" 2>/dev/null)
assert_contains "$DOC_ROW" "codex 0.146.0" "doctor: records the host version"
assert_contains "$DOC_ROW" "SessionStart=120" "doctor: reports per-event hook budgets"
assert_equals '0.146.0' "$(jq -r '.codex // ""' "$DOC_CFG/host-versions.json" 2>/dev/null)" \
    "doctor: keeps the version it saw"
printf '#!/bin/sh\necho "codex-cli 0.147.0"\n' > "$HOST_BIN/codex"
DOC_OUT=$(PATH="$HOST_BIN:$PATH" WV_DOCTOR_HOSTS=codex WV_CONFIG_DIR="$DOC_CFG" "$WV" doctor --agent --json 2>/dev/null || true)
DOC_ROW=$(jq -r '[.checks[] | select(.check == "host hooks" and (.detail | startswith("codex ")))][0] | "\(.status) \(.detail)"' <<<"$DOC_OUT" 2>/dev/null)
assert_contains "$DOC_ROW" "warn codex 0.147.0" "doctor: a changed host version warns"
assert_contains "$DOC_ROW" "changed from 0.146.0" "doctor: and names the version it changed from"
cd "$PROJECT_ROOT"

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
