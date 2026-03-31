#!/bin/bash
# Weave Installer — Install wv CLI to user-level location
#
# Usage:
#   ./install.sh              Install (copy files)
#   ./install.sh --dev        Install (symlink files, for development)
#   ./install.sh --uninstall  Remove all installed files
#   ./install.sh --upgrade    Pull latest and reinstall
#   ./install.sh --verify     Install and verify with selftest
#   ./install.sh --check-deps Check required dependencies
#
# Remote install:
#   curl -sSL https://raw.githubusercontent.com/AGM1968/weave/main/install.sh | bash

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

INSTALL_DIR="${WV_INSTALL_DIR:-$HOME/.local/bin}"
LIB_DIR="${WV_LIB_DIR:-$HOME/.local/lib/weave}"
CONFIG_DIR="${WV_CONFIG_DIR:-$HOME/.config/weave}"
MANIFEST="$CONFIG_DIR/manifest.txt"

# ═══════════════════════════════════════════════════════════════════════════
# Dependency Checking
# ═══════════════════════════════════════════════════════════════════════════

check_deps() {
    echo -e "${CYAN}━━━ Dependency Check ━━━${NC}"
    local missing=0
    
    # Required
    for cmd in sqlite3 jq git; do
        if command -v "$cmd" &>/dev/null; then
            local ver=$("$cmd" --version 2>&1 | head -1)
            echo -e "  ${GREEN}✓${NC} $cmd: $ver"
        else
            echo -e "  ${RED}✗${NC} $cmd: not found (required)"
            missing=1
        fi
    done
    
    # Optional
    if command -v gh &>/dev/null; then
        local ver=$(gh --version 2>&1 | head -1)
        echo -e "  ${GREEN}✓${NC} gh: $ver"
    else
        echo -e "  ${YELLOW}⊘${NC} gh: not found (optional, needed for GitHub sync)"
    fi
    
    if command -v curl &>/dev/null; then
        local ver=$(curl --version 2>&1 | head -1)
        echo -e "  ${GREEN}✓${NC} curl: $ver"
    else
        echo -e "  ${YELLOW}⊘${NC} curl: not found (optional, needed for remote install)"
    fi
    
    echo ""
    if [ "$missing" -eq 1 ]; then
        echo -e "${RED}Missing required dependencies.${NC}"
        return 1
    else
        echo -e "${GREEN}All required dependencies available.${NC}"
        return 0
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# Uninstall
# ═══════════════════════════════════════════════════════════════════════════

do_uninstall() {
    echo -e "${CYAN}━━━ Weave Uninstaller ━━━${NC}"
    
    if [ ! -f "$MANIFEST" ]; then
        echo -e "${YELLOW}No manifest found at $MANIFEST${NC}"
        echo "Attempting to remove known locations..."
        
        # Remove known files
        rm -f "$INSTALL_DIR/wv" "$INSTALL_DIR/wv-test" "$INSTALL_DIR/wv-create" \
              "$INSTALL_DIR/wv-close" "$INSTALL_DIR/wv-init-repo" \
              "$INSTALL_DIR/wv-update"
        rm -rf "$LIB_DIR"
        
        echo -e "${GREEN}✓ Removed CLI tools from $INSTALL_DIR${NC}"
        echo -e "${GREEN}✓ Removed lib modules from $LIB_DIR${NC}"
        echo -e "${YELLOW}Note: Config at $CONFIG_DIR preserved (contains user data)${NC}"
        return 0
    fi
    
    echo "Reading manifest..."
    local count=0
    while IFS= read -r file; do
        if [ -e "$file" ] || [ -L "$file" ]; then
            rm -f "$file"
            count=$((count + 1))
        fi
    done < "$MANIFEST"
    
    # Remove empty directories
    rmdir "$LIB_DIR/lib" "$LIB_DIR/cmd" "$LIB_DIR" 2>/dev/null || true
    
    rm -f "$MANIFEST"
    
    echo -e "${GREEN}✓ Removed $count files${NC}"
    echo -e "${YELLOW}Note: Config at $CONFIG_DIR preserved (contains user data)${NC}"
    echo ""
    echo "To fully remove Weave including config:"
    echo "  rm -rf $CONFIG_DIR"
}

# ═══════════════════════════════════════════════════════════════════════════
# Upgrade
# ═══════════════════════════════════════════════════════════════════════════

do_upgrade() {
    echo -e "${CYAN}━━━ Weave Upgrader ━━━${NC}"
    
    # Get current version
    local current_ver=""
    if [ -f "$LIB_DIR/lib/VERSION" ]; then
        current_ver=$(cat "$LIB_DIR/lib/VERSION" | tr -d '[:space:]')
    elif command -v wv &>/dev/null; then
        current_ver=$(wv --version 2>/dev/null | awk '{print $2}')
    fi
    
    echo "Current version: ${current_ver:-unknown}"
    
    # Find source repo
    local repo_root=""
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    
    if [ -n "$repo_root" ] && [ -f "$repo_root/scripts/lib/VERSION" ]; then
        # Local repo - pull latest
        echo "Found local repo at $repo_root"
        echo "Pulling latest..."
        (cd "$repo_root" && git pull --ff-only 2>/dev/null) || {
            echo -e "${YELLOW}Warning: git pull failed, using current local version${NC}"
        }
        
        local new_ver=$(cat "$repo_root/scripts/lib/VERSION" | tr -d '[:space:]')
        echo "New version: $new_ver"
        
        if [ "$current_ver" = "$new_ver" ]; then
            echo -e "${GREEN}Already at latest version ($new_ver)${NC}"
            return 0
        fi
        
        echo "Upgrading $current_ver -> $new_ver..."
        (cd "$repo_root" && bash install.sh)
    else
        # Download from GitHub
        echo "Downloading latest from GitHub..."
        local tmp_dir
        tmp_dir=$(mktemp -d)
        trap 'rm -rf "$tmp_dir"' EXIT
        
        curl -sSL "https://raw.githubusercontent.com/AGM1968/weave/main/scripts/lib/VERSION" \
            -o "$tmp_dir/VERSION" 2>/dev/null || {
            echo -e "${RED}Failed to check latest version${NC}"
            return 1
        }
        
        local new_ver=$(cat "$tmp_dir/VERSION" | tr -d '[:space:]')
        echo "Latest version: $new_ver"
        
        if [ "$current_ver" = "$new_ver" ]; then
            echo -e "${GREEN}Already at latest version ($new_ver)${NC}"
            return 0
        fi
        
        echo "Upgrading $current_ver -> $new_ver..."
        curl -sSL "https://raw.githubusercontent.com/AGM1968/weave/main/install.sh" | bash
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# Install Helper Functions
# ═══════════════════════════════════════════════════════════════════════════

# Install a file (copy or symlink based on mode)
# Usage: install_file <src> <dst>
install_file() {
    local src="$1"
    local dst="$2"
    
    # Remove existing file/symlink first
    rm -f "$dst" 2>/dev/null || true
    
    if [ "$DEV_MODE" = "1" ]; then
        # Use absolute path for symlink
        local abs_src=$(cd "$(dirname "$src")" && pwd)/$(basename "$src")
        ln -sf "$abs_src" "$dst"
    else
        cp "$src" "$dst"
    fi
    
    # Record in manifest
    echo "$dst" >> "$MANIFEST"
}

# Download and install a file
# Usage: download_file <url> <dst>
download_file() {
    local url="$1"
    local dst="$2"
    
    curl -sSL "$url" -o "$dst"
    echo "$dst" >> "$MANIFEST"
}

# ═══════════════════════════════════════════════════════════════════════════
# Main Install
# ═══════════════════════════════════════════════════════════════════════════

do_install() {
    local mode_label="Installing"
    [ "$DEV_MODE" = "1" ] && mode_label="Installing (dev mode - symlinks)"
    
    echo -e "${CYAN}━━━ Weave Installer ━━━${NC}"
    echo "$mode_label..."
    
    # Clear old manifest
    rm -f "$MANIFEST"
    mkdir -p "$(dirname "$MANIFEST")"

# Create directories
mkdir -p "$INSTALL_DIR"
mkdir -p "$LIB_DIR/lib"
mkdir -p "$LIB_DIR/cmd"
mkdir -p "$CONFIG_DIR"

# Create config subdirectories
mkdir -p "$CONFIG_DIR/hooks"
mkdir -p "$CONFIG_DIR/lib"
mkdir -p "$CONFIG_DIR/agents"
mkdir -p "$CONFIG_DIR/skills/breadcrumbs"
mkdir -p "$CONFIG_DIR/skills/close-session"
mkdir -p "$CONFIG_DIR/skills/wv-decompose-work"
mkdir -p "$CONFIG_DIR/skills/fix-issue"
mkdir -p "$CONFIG_DIR/skills/pre-mortem"
mkdir -p "$CONFIG_DIR/skills/wv-verify-complete"
mkdir -p "$CONFIG_DIR/skills/resolve-refs"
mkdir -p "$CONFIG_DIR/skills/wv-clarify-spec"
mkdir -p "$CONFIG_DIR/skills/sanity-check"
mkdir -p "$CONFIG_DIR/skills/ship-it"
mkdir -p "$CONFIG_DIR/skills/wv-guard-scope"
mkdir -p "$CONFIG_DIR/skills/wv-detect-loop"
mkdir -p "$CONFIG_DIR/skills/weave-audit"
mkdir -p "$CONFIG_DIR/skills/weave"
mkdir -p "$CONFIG_DIR/skills/zero-in"
mkdir -p "$CONFIG_DIR/skills/plan-agent"

# Download or copy wv CLI + config
if [ -f "./scripts/wv" ]; then
    echo -e "${YELLOW}Installing from local source...${NC}"
    # CLI entry point
    install_file ./scripts/wv "$INSTALL_DIR/wv"
    install_file ./scripts/wv-test "$INSTALL_DIR/wv-test"
    # wv-runtime: generate installed script with baked-in repo + venv paths
    _runtime_repo="$(pwd)"
    _runtime_python="$_runtime_repo/.venv/bin/python3"
    [ -x "$_runtime_python" ] || _runtime_python=python3
    cat > "$INSTALL_DIR/wv-runtime" <<RUNTIME_SCRIPT
#!/bin/bash
# wv-runtime — generated by install.sh (repo: $_runtime_repo)
export WV_RUNTIME_PROG="wv-runtime"
PYTHONPATH="$_runtime_repo\${PYTHONPATH:+:\$PYTHONPATH}"
if [ -x "$_runtime_repo/.venv/bin/python3" ]; then
  ln -sf "$_runtime_repo/.venv/bin/python3" "$_runtime_repo/.venv/bin/weave"
  exec "$_runtime_repo/.venv/bin/weave" -m runtime "\$@"
fi
exec "$_runtime_python" -m runtime "\$@"
RUNTIME_SCRIPT
    chmod +x "$INSTALL_DIR/wv-runtime"
    # Library modules (XDG: ~/.local/lib/weave/lib/)
    install_file ./scripts/lib/wv-config.sh "$LIB_DIR/lib/wv-config.sh"
    install_file ./scripts/lib/wv-db.sh "$LIB_DIR/lib/wv-db.sh"
    install_file ./scripts/lib/wv-validate.sh "$LIB_DIR/lib/wv-validate.sh"
    install_file ./scripts/lib/wv-cache.sh "$LIB_DIR/lib/wv-cache.sh"
    install_file ./scripts/lib/wv-journal.sh "$LIB_DIR/lib/wv-journal.sh"
    install_file ./scripts/lib/wv-gh.sh "$LIB_DIR/lib/wv-gh.sh"
    install_file ./scripts/lib/wv-delta.sh "$LIB_DIR/lib/wv-delta.sh"
    install_file ./scripts/lib/wv-resolve-project.sh "$LIB_DIR/lib/wv-resolve-project.sh"
    install_file ./scripts/lib/VERSION "$LIB_DIR/lib/VERSION"
    # Command modules (XDG: ~/.local/lib/weave/cmd/)
    install_file ./scripts/cmd/wv-cmd-core.sh "$LIB_DIR/cmd/wv-cmd-core.sh"
    install_file ./scripts/cmd/wv-cmd-graph.sh "$LIB_DIR/cmd/wv-cmd-graph.sh"
    install_file ./scripts/cmd/wv-cmd-data.sh "$LIB_DIR/cmd/wv-cmd-data.sh"
    install_file ./scripts/cmd/wv-cmd-ops.sh "$LIB_DIR/cmd/wv-cmd-ops.sh"
    install_file ./scripts/cmd/wv-cmd-quality.sh "$LIB_DIR/cmd/wv-cmd-quality.sh"
    # Python sync package
    mkdir -p "$LIB_DIR/weave_gh"
    for pyf in ./scripts/weave_gh/*.py; do
        install_file "$pyf" "$LIB_DIR/weave_gh/$(basename "$pyf")"
    done
    # Python quality package
    mkdir -p "$LIB_DIR/weave_quality"
    for pyf in ./scripts/weave_quality/*.py; do
        install_file "$pyf" "$LIB_DIR/weave_quality/$(basename "$pyf")"
    done
    # Scripts
    cp ./scripts/context-guard.sh "$CONFIG_DIR/"
    cp ./scripts/resolve-refs.sh "$CONFIG_DIR/"
    # Lib available to hooks from global path (~/.config/weave/hooks/../lib/)
    cp ./scripts/lib/wv-resolve-project.sh "$CONFIG_DIR/lib/wv-resolve-project.sh"
    # Claude hooks (all 9 — registered globally via ~/.claude/settings.json under Alt-A)
    cp ./.claude/hooks/context-guard.sh "$CONFIG_DIR/hooks/"
    cp ./.claude/hooks/session-start-context.sh "$CONFIG_DIR/hooks/"
    cp ./.claude/hooks/session-end-sync.sh "$CONFIG_DIR/hooks/"
    cp ./.claude/hooks/stop-check.sh "$CONFIG_DIR/hooks/"
    cp ./.claude/hooks/post-edit-lint.sh "$CONFIG_DIR/hooks/"
    cp ./.claude/hooks/pre-compact-context.sh "$CONFIG_DIR/hooks/"
    cp ./.claude/hooks/pre-action.sh "$CONFIG_DIR/hooks/"
    cp ./.claude/hooks/pre-claim-skills.sh "$CONFIG_DIR/hooks/"
    cp ./.claude/hooks/pre-close-verification.sh "$CONFIG_DIR/hooks/"
    # Agents
    cp ./.claude/agents/weave-guide.md "$CONFIG_DIR/agents/"
    cp ./.claude/agents/epic-planner.md "$CONFIG_DIR/agents/"
    cp ./.claude/agents/learning-curator.md "$CONFIG_DIR/agents/"
    # Skills
    cp ./.claude/skills/breadcrumbs/SKILL.md "$CONFIG_DIR/skills/breadcrumbs/"
    cp ./.claude/skills/close-session/SKILL.md "$CONFIG_DIR/skills/close-session/"
    cp ./.claude/skills/wv-decompose-work/SKILL.md "$CONFIG_DIR/skills/wv-decompose-work/"
    cp ./.claude/skills/fix-issue/SKILL.md "$CONFIG_DIR/skills/fix-issue/"
    cp ./.claude/skills/pre-mortem/SKILL.md "$CONFIG_DIR/skills/pre-mortem/"
    cp ./.claude/skills/wv-verify-complete/SKILL.md "$CONFIG_DIR/skills/wv-verify-complete/"
    cp ./.claude/skills/resolve-refs/SKILL.md "$CONFIG_DIR/skills/resolve-refs/"
    cp ./.claude/skills/wv-clarify-spec/SKILL.md "$CONFIG_DIR/skills/wv-clarify-spec/"
    cp ./.claude/skills/sanity-check/SKILL.md "$CONFIG_DIR/skills/sanity-check/"
    cp ./.claude/skills/ship-it/SKILL.md "$CONFIG_DIR/skills/ship-it/"
    cp ./.claude/skills/wv-guard-scope/SKILL.md "$CONFIG_DIR/skills/wv-guard-scope/"
    cp ./.claude/skills/wv-detect-loop/SKILL.md "$CONFIG_DIR/skills/wv-detect-loop/"
    cp ./.claude/skills/weave-audit/SKILL.md "$CONFIG_DIR/skills/weave-audit/"
    cp ./.claude/skills/weave-audit/audit-report.sh "$CONFIG_DIR/skills/weave-audit/"
    cp ./.claude/skills/weave/SKILL.md "$CONFIG_DIR/skills/weave/"
    cp ./.claude/skills/zero-in/SKILL.md "$CONFIG_DIR/skills/zero-in/"
    cp ./.claude/skills/plan-agent/SKILL.md "$CONFIG_DIR/skills/plan-agent/"
    # CLAUDE.md template (generic, not project-specific)
    cp ./templates/CLAUDE.md.template "$CONFIG_DIR/CLAUDE.md.template"
    # Workflow reference (compact wv cheatsheet for new repos)
    cp ./templates/WORKFLOW.md "$CONFIG_DIR/WORKFLOW.md"
    # Plan template for wv plan --template
    cp ./templates/PLAN.md.template "$CONFIG_DIR/PLAN.md.template" 2>/dev/null || true
    # Topology enrichment spec template for wv enrich-topology
    cp ./templates/TOPOLOGY-ENRICH.json.template "$CONFIG_DIR/TOPOLOGY-ENRICH.json.template" 2>/dev/null || true
    # Makefile template for wv-init-repo
    cp ./templates/Makefile.template "$CONFIG_DIR/Makefile.template" 2>/dev/null || true
    cp ./templates/copilot-instructions.stub.md "$CONFIG_DIR/copilot-instructions.stub.md" 2>/dev/null || true
    # AGENTS.md template (generic, not project-specific)
    cp ./templates/AGENTS.md.template "$CONFIG_DIR/AGENTS.md.template" 2>/dev/null || true
else
    echo -e "${YELLOW}Downloading from GitHub...${NC}"
    REPO="https://raw.githubusercontent.com/AGM1968/weave/main"
    # CLI entry point
    download_file "$REPO/scripts/wv" "$INSTALL_DIR/wv"
    download_file "$REPO/scripts/wv-test" "$INSTALL_DIR/wv-test"
    # Library modules (XDG: ~/.local/lib/weave/lib/)
    download_file "$REPO/scripts/lib/wv-config.sh" "$LIB_DIR/lib/wv-config.sh"
    download_file "$REPO/scripts/lib/wv-db.sh" "$LIB_DIR/lib/wv-db.sh"
    download_file "$REPO/scripts/lib/wv-validate.sh" "$LIB_DIR/lib/wv-validate.sh"
    download_file "$REPO/scripts/lib/wv-cache.sh" "$LIB_DIR/lib/wv-cache.sh"
    download_file "$REPO/scripts/lib/wv-gh.sh" "$LIB_DIR/lib/wv-gh.sh"
    download_file "$REPO/scripts/lib/wv-delta.sh" "$LIB_DIR/lib/wv-delta.sh"
    download_file "$REPO/scripts/lib/wv-resolve-project.sh" "$LIB_DIR/lib/wv-resolve-project.sh"
    download_file "$REPO/scripts/lib/VERSION" "$LIB_DIR/lib/VERSION"
    # Command modules (XDG: ~/.local/lib/weave/cmd/)
    download_file "$REPO/scripts/cmd/wv-cmd-core.sh" "$LIB_DIR/cmd/wv-cmd-core.sh"
    download_file "$REPO/scripts/cmd/wv-cmd-graph.sh" "$LIB_DIR/cmd/wv-cmd-graph.sh"
    download_file "$REPO/scripts/cmd/wv-cmd-data.sh" "$LIB_DIR/cmd/wv-cmd-data.sh"
    download_file "$REPO/scripts/cmd/wv-cmd-ops.sh" "$LIB_DIR/cmd/wv-cmd-ops.sh"
    download_file "$REPO/scripts/cmd/wv-cmd-quality.sh" "$LIB_DIR/cmd/wv-cmd-quality.sh"
    # Python sync package (auto-discover modules from GitHub API)
    mkdir -p "$LIB_DIR/weave_gh"
    local py_modules
    py_modules=$(curl -sSL "https://api.github.com/repos/AGM1968/weave/contents/scripts/weave_gh?ref=main" \
        | jq -r '.[] | select(.name | endswith(".py")) | .name' 2>/dev/null)
    if [ -z "$py_modules" ]; then
        # Fallback: hardcoded list if API is unavailable (rate-limited, offline)
        py_modules="__init__.py models.py cli.py data.py rendering.py labels.py body.py phases.py notify.py __main__.py"
    fi
    for pyfile in $py_modules; do
        download_file "$REPO/scripts/weave_gh/${pyfile}" "$LIB_DIR/weave_gh/${pyfile}"
    done
    # Python quality package (auto-discover modules from GitHub API)
    mkdir -p "$LIB_DIR/weave_quality"
    local quality_modules
    quality_modules=$(curl -sSL "https://api.github.com/repos/AGM1968/weave/contents/scripts/weave_quality?ref=main" \
        | jq -r '.[] | select(.name | endswith(".py")) | .name' 2>/dev/null)
    if [ -z "$quality_modules" ]; then
        quality_modules="__init__.py __main__.py models.py git_metrics.py python_parser.py bash_heuristic.py hotspots.py db.py"
    fi
    for pyfile in $quality_modules; do
        download_file "$REPO/scripts/weave_quality/${pyfile}" "$LIB_DIR/weave_quality/${pyfile}"
    done
    # Scripts
    curl -sSL "$REPO/scripts/context-guard.sh" -o "$CONFIG_DIR/context-guard.sh"
    curl -sSL "$REPO/scripts/resolve-refs.sh" -o "$CONFIG_DIR/resolve-refs.sh"
    # Lib available to hooks from global path (~/.config/weave/hooks/../lib/)
    curl -sSL "$REPO/scripts/lib/wv-resolve-project.sh" -o "$CONFIG_DIR/lib/wv-resolve-project.sh"
    # Claude hooks
    curl -sSL "$REPO/.claude/hooks/session-start-context.sh" -o "$CONFIG_DIR/hooks/session-start-context.sh"
    curl -sSL "$REPO/.claude/hooks/session-end-sync.sh" -o "$CONFIG_DIR/hooks/session-end-sync.sh"
    curl -sSL "$REPO/.claude/hooks/stop-check.sh" -o "$CONFIG_DIR/hooks/stop-check.sh"
    curl -sSL "$REPO/.claude/hooks/post-edit-lint.sh" -o "$CONFIG_DIR/hooks/post-edit-lint.sh"
    curl -sSL "$REPO/.claude/hooks/pre-compact-context.sh" -o "$CONFIG_DIR/hooks/pre-compact-context.sh"
    curl -sSL "$REPO/.claude/hooks/pre-action.sh" -o "$CONFIG_DIR/hooks/pre-action.sh"
    curl -sSL "$REPO/.claude/hooks/pre-claim-skills.sh" -o "$CONFIG_DIR/hooks/pre-claim-skills.sh"
    curl -sSL "$REPO/.claude/hooks/pre-close-verification.sh" -o "$CONFIG_DIR/hooks/pre-close-verification.sh"
    # Agents
    curl -sSL "$REPO/.claude/agents/weave-guide.md" -o "$CONFIG_DIR/agents/weave-guide.md"
    curl -sSL "$REPO/.claude/agents/epic-planner.md" -o "$CONFIG_DIR/agents/epic-planner.md"
    curl -sSL "$REPO/.claude/agents/learning-curator.md" -o "$CONFIG_DIR/agents/learning-curator.md"
    # Skills
    curl -sSL "$REPO/.claude/skills/breadcrumbs/SKILL.md" -o "$CONFIG_DIR/skills/breadcrumbs/SKILL.md"
    curl -sSL "$REPO/.claude/skills/close-session/SKILL.md" -o "$CONFIG_DIR/skills/close-session/SKILL.md"
    curl -sSL "$REPO/.claude/skills/wv-decompose-work/SKILL.md" -o "$CONFIG_DIR/skills/wv-decompose-work/SKILL.md"
    curl -sSL "$REPO/.claude/skills/fix-issue/SKILL.md" -o "$CONFIG_DIR/skills/fix-issue/SKILL.md"
    curl -sSL "$REPO/.claude/skills/pre-mortem/SKILL.md" -o "$CONFIG_DIR/skills/pre-mortem/SKILL.md"
    curl -sSL "$REPO/.claude/skills/wv-verify-complete/SKILL.md" -o "$CONFIG_DIR/skills/wv-verify-complete/SKILL.md"
    curl -sSL "$REPO/.claude/skills/resolve-refs/SKILL.md" -o "$CONFIG_DIR/skills/resolve-refs/SKILL.md"
    curl -sSL "$REPO/.claude/skills/wv-clarify-spec/SKILL.md" -o "$CONFIG_DIR/skills/wv-clarify-spec/SKILL.md"
    curl -sSL "$REPO/.claude/skills/sanity-check/SKILL.md" -o "$CONFIG_DIR/skills/sanity-check/SKILL.md"
    curl -sSL "$REPO/.claude/skills/ship-it/SKILL.md" -o "$CONFIG_DIR/skills/ship-it/SKILL.md"
    curl -sSL "$REPO/.claude/skills/wv-guard-scope/SKILL.md" -o "$CONFIG_DIR/skills/wv-guard-scope/SKILL.md"
    curl -sSL "$REPO/.claude/skills/wv-detect-loop/SKILL.md" -o "$CONFIG_DIR/skills/wv-detect-loop/SKILL.md"
    curl -sSL "$REPO/.claude/skills/weave-audit/SKILL.md" -o "$CONFIG_DIR/skills/weave-audit/SKILL.md"
    curl -sSL "$REPO/.claude/skills/weave/SKILL.md" -o "$CONFIG_DIR/skills/weave/SKILL.md"
    curl -sSL "$REPO/.claude/skills/zero-in/SKILL.md" -o "$CONFIG_DIR/skills/zero-in/SKILL.md"
    curl -sSL "$REPO/.claude/skills/weave-audit/audit-report.sh" -o "$CONFIG_DIR/skills/weave-audit/audit-report.sh"
    # CLAUDE.md template (generic, not project-specific)
    curl -sSL "$REPO/templates/CLAUDE.md.template" -o "$CONFIG_DIR/CLAUDE.md.template"
    # Workflow reference (compact wv cheatsheet for new repos)
    curl -sSL "$REPO/templates/WORKFLOW.md" -o "$CONFIG_DIR/WORKFLOW.md" 2>/dev/null || true
    # Plan template for wv plan --template
    curl -sSL "$REPO/templates/PLAN.md.template" -o "$CONFIG_DIR/PLAN.md.template" 2>/dev/null || true
    # Topology enrichment spec template for wv enrich-topology
    curl -sSL "$REPO/templates/TOPOLOGY-ENRICH.json.template" -o "$CONFIG_DIR/TOPOLOGY-ENRICH.json.template" 2>/dev/null || true
    # Makefile template for wv-init-repo
    curl -sSL "$REPO/templates/Makefile.template" -o "$CONFIG_DIR/Makefile.template" 2>/dev/null || true
    # AGENTS.md template (generic, not project-specific)
    curl -sSL "$REPO/templates/AGENTS.md.template" -o "$CONFIG_DIR/AGENTS.md.template" 2>/dev/null || true
fi

chmod +x "$INSTALL_DIR/wv"
chmod +x "$INSTALL_DIR/wv-test"
chmod +x "$CONFIG_DIR/context-guard.sh"
chmod +x "$CONFIG_DIR/resolve-refs.sh"
chmod +x "$CONFIG_DIR/hooks/"*.sh
chmod +x "$CONFIG_DIR/skills/weave-audit/audit-report.sh"

# Alt-A: Register all hooks globally in ~/.claude/settings.json
# Per-project settings.json should have NO hooks key (it would shadow global hooks)
merge_global_claude_settings() {
    local global_settings="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
    local hooks_dir="$CONFIG_DIR/hooks"

    # Backup before modifying
    if [ -f "$global_settings" ]; then
        cp "$global_settings" "${global_settings}.bak"
    fi

    # Build the complete hooks block with absolute paths (no $HOME — doesn't expand in Claude Code)
    local hooks_json
    hooks_json=$(jq -n \
        --arg h "$hooks_dir" \
        '{
            "SessionStart": [{"matcher":"","hooks":[
                {"type":"command","command":($h+"/context-guard.sh")},
                {"type":"command","command":($h+"/session-start-context.sh")}
            ]}],
            "PreCompact": [{"matcher":"","hooks":[
                {"type":"command","command":($h+"/pre-compact-context.sh")}
            ]}],
            "PreToolUse": [
                {"matcher":"Edit|Write|NotebookEdit|Bash|mcp__ide__executeCode|create_file|replace_string_in_file|insert_edit_into_file|multi_replace_string_in_file|run_in_terminal|edit_notebook_file","hooks":[
                    {"type":"command","command":($h+"/pre-action.sh"),"timeout":10}
                ]},
                {"matcher":"Bash","hooks":[
                    {"type":"command","command":($h+"/pre-claim-skills.sh"),"timeout":10}
                ]},
                {"matcher":"Bash","hooks":[
                    {"type":"command","command":($h+"/pre-close-verification.sh"),"timeout":10}
                ]}
            ],
            "PostToolUse": [{"matcher":"Edit|Write|create_file|replace_string_in_file|insert_edit_into_file|multi_replace_string_in_file","hooks":[
                {"type":"command","command":($h+"/post-edit-lint.sh"),"timeout":30}
            ]}],
            "Stop": [{"matcher":"","hooks":[
                {"type":"command","command":($h+"/stop-check.sh")}
            ]}],
            "SessionEnd": [{"matcher":"","hooks":[
                {"type":"command","command":($h+"/session-end-sync.sh")}
            ]}]
        }')

    # Merge into global settings (preserving enabledPlugins and other keys)
    local existing="{}"
    [ -f "$global_settings" ] && existing=$(cat "$global_settings")
    echo "$existing" | jq --argjson hooks "$hooks_json" '. + {hooks: $hooks}' > "$global_settings"
    echo -e "${GREEN}✓ Registered all hooks in $global_settings${NC}"
    echo -e "${YELLOW}  Note: per-project .claude/settings.json must NOT have a 'hooks' key${NC}"
    echo -e "${YELLOW}  (project hooks shadow global hooks — shallow merge limitation)${NC}"
}
merge_global_claude_settings

echo -e "${GREEN}✓ Installed wv to $INSTALL_DIR${NC}"
echo -e "${GREEN}✓ Installed lib modules to $LIB_DIR${NC}"

# Check PATH
if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
    echo ""
    echo -e "${YELLOW}Add to your shell profile:${NC}"
    echo "  export PATH=\"\$PATH:$INSTALL_DIR\""
fi

# Create init command for target repos
cat > "$INSTALL_DIR/wv-init-repo" << 'INITEOF'
#!/bin/bash
# Initialize or update Weave in a target repository
#
# Usage:
#   wv-init-repo                 # Default: --agent=claude (init only)
#   wv-init-repo --agent=claude  # Claude Code hooks, skills, settings
#   wv-init-repo --agent=copilot # VS Code Copilot MCP config
#   wv-init-repo --update        # Update managed files (hooks, skills, agents)
#   wv-init-repo --force         # Overwrite ALL files including user-customized
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

AGENT_ARG="claude"
UPDATE_MODE=0
FORCE_MODE=0
for arg in "$@"; do
    case "$arg" in
        --agent=*) AGENT_ARG="${arg#--agent=}" ;;
        --update) UPDATE_MODE=1 ;;
        --force) UPDATE_MODE=1; FORCE_MODE=1 ;;
        --help|-h)
            echo "Usage: wv-init-repo [--agent=claude|copilot|all] [--update] [--force]"
            echo ""
            echo "  claude   (default) Claude Code hooks, skills, settings.local.json"
            echo "  copilot  VS Code Copilot .vscode/mcp.json + copilot-instructions.md"
            echo "  all      Both Claude Code and VS Code Copilot"
            echo ""
            echo "  --update  Update managed files (hooks, skills, agents, copilot-instructions)"
            echo "            Preserves user-customized files (CLAUDE.md, settings.local.json)"
            echo "  --force   Like --update but overwrites ALL files including user-customized"
            echo ""
            echo "  Comma-separated: --agent=claude,copilot"
            exit 0
            ;;
    esac
done

# Expand 'all' and parse comma-separated values
if [ "$AGENT_ARG" = "all" ]; then
    AGENTS=(claude copilot)
else
    IFS=',' read -ra AGENTS <<< "$AGENT_ARG"
fi

# Validate each agent
for agent in "${AGENTS[@]}"; do
    case "$agent" in
        claude|copilot) ;;
        *)
            echo -e "${YELLOW}Unknown agent: $agent — skipping${NC}" >&2
            ;;
    esac
done

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
CONFIG_DIR="${WV_CONFIG_DIR:-$HOME/.config/weave}"
MCP_SERVER="${WV_LIB_DIR:-$HOME/.local/lib/weave}/mcp/dist/index.js"

AGENT_LABEL=$(IFS=','; echo "${AGENTS[*]}")
if [ "$FORCE_MODE" = "1" ]; then
    echo -e "${CYAN}━━━ Weave Init (agent=$AGENT_LABEL, force) ━━━${NC}"
elif [ "$UPDATE_MODE" = "1" ]; then
    echo -e "${CYAN}━━━ Weave Update (agent=$AGENT_LABEL) ━━━${NC}"
else
    echo -e "${CYAN}━━━ Weave Init (agent=$AGENT_LABEL) ━━━${NC}"
fi

# ── Core setup (all agents) ──────────────────────────────────────────────
mkdir -p "$REPO_ROOT/.weave"

# .gitignore management (idempotent)
GITIGNORE="$REPO_ROOT/.gitignore"
WEAVE_PATTERNS=(
    ".weave/archive/"
    ".weave/*.db"
    ".weave/*.db-wal"
    ".weave/*.db-shm"
    "!.weave/state.sql"
    "!.claude/settings.json"
)
if [ -f "$GITIGNORE" ]; then
    added=0
    for entry in "${WEAVE_PATTERNS[@]}"; do
        if ! grep -qxF "$entry" "$GITIGNORE"; then
            if [ "$added" -eq 0 ]; then
                echo "" >> "$GITIGNORE"
                echo "# Weave" >> "$GITIGNORE"
            fi
            echo "$entry" >> "$GITIGNORE"
            added=1
        fi
    done
    if [ "$added" -eq 1 ]; then
        echo -e "  ${GREEN}✓${NC} .gitignore (updated with Weave entries)"
    else
        echo -e "  ${YELLOW}⊘${NC} .gitignore (Weave entries already present)"
    fi
else
    echo "# Weave" > "$GITIGNORE"
    printf '%s\n' "${WEAVE_PATTERNS[@]}" >> "$GITIGNORE"
    echo -e "  ${GREEN}✓${NC} .gitignore (created with Weave entries)"
fi

# Git hook: prepare-commit-msg (portable, awk-based)
HOOK_DIR="$REPO_ROOT/.git/hooks"
if [ -d "$HOOK_DIR" ] && [ ! -f "$HOOK_DIR/prepare-commit-msg" ]; then
    cat > "$HOOK_DIR/prepare-commit-msg" << 'HOOKEOF'
#!/usr/bin/env sh
# Weave: append Weave-ID trailers to commit messages
COMMIT_MSG_FILE="$1"
COMMIT_SOURCE="$2"
case "$COMMIT_SOURCE" in merge|squash) exit 0 ;; esac
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || exit 0)
WV="$(command -v wv 2>/dev/null || echo "$REPO_ROOT/scripts/wv")"
[ ! -x "$WV" ] && exit 0
ACTIVE_IDS=$("$WV" list --status=active --json 2>/dev/null | jq -r '.[].id' 2>/dev/null)
[ -z "$ACTIVE_IDS" ] && exit 0
grep -q "^Weave-ID:" "$COMMIT_MSG_FILE" 2>/dev/null && exit 0
for id in $ACTIVE_IDS; do
    if grep -q "^Co-Authored-By:" "$COMMIT_MSG_FILE" 2>/dev/null; then
        tmp="${COMMIT_MSG_FILE}.wv$$"
        awk -v wid="Weave-ID: $id" '/^Co-Authored-By:/ && !done {print wid; done=1} {print}' \
            "$COMMIT_MSG_FILE" > "$tmp" && mv "$tmp" "$COMMIT_MSG_FILE"
    else
        printf '\nWeave-ID: %s\n' "$id" >> "$COMMIT_MSG_FILE"
    fi
done
exit 0
HOOKEOF
    chmod +x "$HOOK_DIR/prepare-commit-msg"
    echo -e "  ${GREEN}✓${NC} .git/hooks/prepare-commit-msg"
elif [ -f "$HOOK_DIR/prepare-commit-msg" ]; then
    echo -e "  ${YELLOW}⊘${NC} .git/hooks/prepare-commit-msg (already exists, skipped)"
fi

# Git hook: pre-commit (enforce active Weave node)
if [ -d "$HOOK_DIR" ] && [ ! -f "$HOOK_DIR/pre-commit" ]; then
    cat > "$HOOK_DIR/pre-commit" << 'HOOKEOF'
#!/usr/bin/env sh
# Weave pre-commit hook: require active node before committing code changes
#
# Enforces the "track ALL work in Weave" rule.
# Allows .weave/-only commits and WIP checkpoints through.
#
# Skip with: git commit --no-verify (or WV_SKIP_PRECOMMIT=1)

# Allow explicit bypass
[ "${WV_SKIP_PRECOMMIT:-0}" = "1" ] && exit 0

# Find wv
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || exit 0)
WV="$(command -v wv 2>/dev/null || echo "$REPO_ROOT/scripts/wv")"
[ ! -x "$WV" ] && exit 0

# Check what's being committed — if only .weave/ files, always allow
STAGED_FILES=$(git diff --cached --name-only 2>/dev/null)
[ -z "$STAGED_FILES" ] && exit 0

NON_WEAVE_FILES=$(echo "$STAGED_FILES" | grep -v '^\.weave/' || true)
[ -z "$NON_WEAVE_FILES" ] && exit 0

# Allow auto-checkpoint WIP commits
[ "${WV_AUTO_CHECKPOINT_ACTIVE:-0}" = "1" ] && exit 0

# Run ruff linter on staged Python files (fast — blocks on lint errors)
STAGED_PY=$(echo "$NON_WEAVE_FILES" | grep '\.py$' || true)
if [ -n "$STAGED_PY" ] && command -v ruff > /dev/null 2>&1; then
    RUFF_OUT=$(ruff check $STAGED_PY 2>&1 || true)
    if [ -n "$RUFF_OUT" ] && [ "$RUFF_OUT" != "All checks passed!" ]; then
        echo "" >&2
        echo "✗ ruff lint errors in staged files:" >&2
        echo "$RUFF_OUT" >&2
        echo "" >&2
        echo "  Fix with: ruff check --fix <file>  (then re-stage)" >&2
        echo "" >&2
        exit 1
    fi
fi

# Check for active Weave nodes
ACTIVE_COUNT=$("$WV" list --status=active --json 2>/dev/null | jq 'length' 2>/dev/null || echo "0")

if [ "$ACTIVE_COUNT" = "0" ] || [ -z "$ACTIVE_COUNT" ]; then
    cat >&2 << 'EOF'

  No active Weave node -- commit blocked.

  Every code change must be tracked. Either:
    wv work <id>         # claim an existing task
    wv add "..." --gh    # create + track new work

  Then retry your commit.

  Bypass: git commit --no-verify
          WV_SKIP_PRECOMMIT=1 git commit

EOF
    exit 1
fi

exit 0
HOOKEOF
    chmod +x "$HOOK_DIR/pre-commit"
    echo -e "  ${GREEN}✓${NC} .git/hooks/pre-commit (Weave node enforcement)"
elif [ -f "$HOOK_DIR/pre-commit" ]; then
    echo -e "  ${YELLOW}⊘${NC} .git/hooks/pre-commit (already exists, skipped)"
fi

# .gitattributes: merge strategy + diff suppression for Weave state files
# Uses BEGIN/END markers (like Makefile template) for reliable idempotent updates
GITATTR="$REPO_ROOT/.gitattributes"
ATTR_MARKER_BEGIN="# ── BEGIN WEAVE GITATTRIBUTES ──"
ATTR_MARKER_END="# ── END WEAVE GITATTRIBUTES ──"
ATTR_BLOCK="${ATTR_MARKER_BEGIN}
# Weave state files: latest local dump always wins (DB is source of truth).
# Requires: git config merge.ours.driver true (done by wv-init-repo)
.weave/state.sql merge=ours -diff linguist-generated
.weave/state.sql.txt-dump -diff linguist-generated
.weave/nodes.jsonl merge=ours -diff linguist-generated
.weave/edges.jsonl merge=ours -diff linguist-generated

# Delta files: unique filenames mean no real conflicts; merge=theirs is a safety net.
# Requires: git config merge.theirs.driver \"cp %B %A\" (done by wv-init-repo)
.weave/deltas/**/*.sql merge=theirs
${ATTR_MARKER_END}"

if [ -f "$GITATTR" ]; then
    if grep -qF "$ATTR_MARKER_BEGIN" "$GITATTR"; then
        # Markers present — replace between them + strip orphaned weave comments
        tmpattr=$(mktemp)
        awk -v begin="$ATTR_MARKER_BEGIN" -v end="$ATTR_MARKER_END" -v block="$ATTR_BLOCK" '
            $0 == begin { print block; skip=1; next }
            skip && $0 == end { skip=0; next }
            skip { next }
            /^# .*(merge=ours|merge=theirs|merge driver|ours merge|theirs merge)/ { next }
            /^# .*(hot-zone|source of truth|serialization|linguist-generated)/ { next }
            /^# .*(Weave|weave|\.weave).*(state|dump|delta|merge|file)/ { next }
            /^# .*(delta|Delta).*(idempotent|INSERT OR REPLACE|unique|safety)/ { next }
            /^# Requires:.*merge/ { next }
            /^# Weave:/ { next }
            { print }
        ' "$GITATTR" > "$tmpattr"
        # Remove trailing blank lines
        sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$tmpattr"
        mv "$tmpattr" "$GITATTR"
        echo -e "  ${GREEN}✓${NC} .gitattributes (updated)"
    else
        # No markers — strip old .weave/ entries + associated comments, append marked block
        # This path runs once per repo (upgrade from pre-v1.23.1 format)
        tmpattr=$(mktemp)
        awk '
            /^\.weave\// { next }
            /^# .*(merge=ours|merge=theirs|merge driver|ours merge|theirs merge)/ { next }
            /^# .*(hot-zone|source of truth|serialization|linguist-generated)/ { next }
            /^# .*(Weave|weave|\.weave).*(state|dump|delta|merge|file)/ { next }
            /^# .*(delta|Delta).*(idempotent|INSERT OR REPLACE|unique|safety)/ { next }
            /^# Requires:.*merge/ { next }
            /^# Weave:/ { next }
            { print }
        ' "$GITATTR" > "$tmpattr"
        # Remove trailing blank lines
        sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$tmpattr"
        { echo ""; echo "$ATTR_BLOCK"; } >> "$tmpattr"
        mv "$tmpattr" "$GITATTR"
        echo -e "  ${GREEN}✓${NC} .gitattributes (upgraded to managed block)"
    fi
else
    echo "$ATTR_BLOCK" > "$GITATTR"
    echo -e "  ${GREEN}✓${NC} .gitattributes (created)"
fi

# Register 'ours' merge driver (required for .gitattributes merge=ours)
git config merge.ours.driver true 2>/dev/null || true
echo -e "  ${GREEN}✓${NC} git merge.ours.driver configured"

# Register 'theirs' merge driver (required for .gitattributes merge=theirs)
# Used by .weave/deltas/**/*.sql — on conflict, accept remote version
git config merge.theirs.driver "cp %B %A" 2>/dev/null || true
echo -e "  ${GREEN}✓${NC} git merge.theirs.driver configured"

# Initialize wv database (idempotent — skip if already running)
if wv init 2>/dev/null; then
    echo -e "  ${GREEN}✓${NC} Weave database initialized"
else
    echo -e "  ${YELLOW}⊘${NC} Weave database (already initialized)"
fi

# ── Agent-specific setup ─────────────────────────────────────────────────

for AGENT in "${AGENTS[@]}"; do

if [ "$AGENT" = "claude" ]; then
    # Claude Code: skills, agents, CLAUDE.md, settings.json, settings.local.json
    # Alt-A architecture (v1.15.0+): hooks fire globally from ~/.claude/settings.json.
    # Per-project settings.json has NO hooks key — any hooks key shadows globals (shallow spread).
    # Managed files (always overwritten in --update mode): skills, agents
    # User files (only overwritten with --force): CLAUDE.md, settings.local.json, settings.json

    # ── Skills (managed — always update) ──
    SKILLS=(breadcrumbs close-session fix-issue plan-agent pre-mortem resolve-refs sanity-check ship-it weave weave-audit wv-clarify-spec wv-decompose-work wv-detect-loop wv-guard-scope wv-verify-complete zero-in)
    for skill in "${SKILLS[@]}"; do
        if [ -f "$CONFIG_DIR/skills/$skill/SKILL.md" ]; then
            mkdir -p "$REPO_ROOT/.claude/skills/$skill"
            if [ "$UPDATE_MODE" = "1" ] || [ ! -f "$REPO_ROOT/.claude/skills/$skill/SKILL.md" ]; then
                cp "$CONFIG_DIR/skills/$skill/SKILL.md" "$REPO_ROOT/.claude/skills/$skill/"
                # Copy extra files (e.g., audit-report.sh)
                for extra in "$CONFIG_DIR/skills/$skill/"*; do
                    [ "$(basename "$extra")" = "SKILL.md" ] && continue
                    [ -f "$extra" ] && cp "$extra" "$REPO_ROOT/.claude/skills/$skill/" && chmod +x "$REPO_ROOT/.claude/skills/$skill/$(basename "$extra")" 2>/dev/null
                done
                echo -e "  ${GREEN}✓${NC} .claude/skills/$skill"
            else
                echo -e "  ${YELLOW}⊘${NC} .claude/skills/$skill (exists, use --update to overwrite)"
            fi
        fi
    done

    # ── Agents (managed — always update) ──
    mkdir -p "$REPO_ROOT/.claude/agents"
    AGENT_FILES=(weave-guide.md epic-planner.md learning-curator.md)
    for agent_file in "${AGENT_FILES[@]}"; do
        if [ -f "$CONFIG_DIR/agents/$agent_file" ]; then
            if [ "$UPDATE_MODE" = "1" ] || [ ! -f "$REPO_ROOT/.claude/agents/$agent_file" ]; then
                cp "$CONFIG_DIR/agents/$agent_file" "$REPO_ROOT/.claude/agents/"
                echo -e "  ${GREEN}✓${NC} .claude/agents/$agent_file"
            else
                echo -e "  ${YELLOW}⊘${NC} .claude/agents/$agent_file (exists, use --update to overwrite)"
            fi
        fi
    done

    # AGENTS.md stub (create once, never overwrite — user may customize)
    if [ ! -f "$REPO_ROOT/.claude/agents/AGENTS.md" ] || [ "$FORCE_MODE" = "1" ]; then
        cat > "$REPO_ROOT/.claude/agents/AGENTS.md" << 'AGENTSEOF'
# Weave Agents

Specialized subagents for Weave workflow. Use via the Task tool with the appropriate
`subagent_type`.

| Agent            | Purpose                        | Trigger                          |
| ---------------- | ------------------------------ | -------------------------------- |
| weave-guide      | Workflow guidance               | Unsure how to use Weave          |
| epic-planner     | Strategic planning              | Starting a new epic or sprint    |
| learning-curator | Knowledge capture               | After completing significant work|
AGENTSEOF
        echo -e "  ${GREEN}✓${NC} .claude/agents/AGENTS.md"
    elif [ -f "$REPO_ROOT/.claude/agents/AGENTS.md" ]; then
        echo -e "  ${YELLOW}⊘${NC} .claude/agents/AGENTS.md (already exists, skipped)"
    fi

    # ── CLAUDE.md (weave block — prepend/update, preserve project content) ──
    if [ -f "$CONFIG_DIR/CLAUDE.md.template" ]; then
        _weave_block=$(cat "$CONFIG_DIR/CLAUDE.md.template")
        if [ ! -f "$REPO_ROOT/CLAUDE.md" ]; then
            # New repo: create with weave block + project knowledge placeholder
            {
                printf '# Project Instructions\n\n'
                printf '%s\n' "$_weave_block"
                printf '\n## Project Knowledge\n\n'
                printf '<!-- Add project-specific knowledge below: stack, environment, conventions, pitfalls -->\n'
            } > "$REPO_ROOT/CLAUDE.md"
            echo -e "  ${GREEN}✓${NC} CLAUDE.md (created with Weave block)"
        elif grep -q 'BEGIN WEAVE CLAUDE\.MD\|WEAVE-BLOCK-START' "$REPO_ROOT/CLAUDE.md"; then
            # Existing with block (new or old marker): replace the block, preserve everything else
            _before=$(sed -n '1,/BEGIN WEAVE CLAUDE\.MD\|WEAVE-BLOCK-START/{ /BEGIN WEAVE CLAUDE\.MD\|WEAVE-BLOCK-START/d; p; }' "$REPO_ROOT/CLAUDE.md")
            _after=$(sed -n '/END WEAVE CLAUDE\.MD\|WEAVE-BLOCK-END/,${  /END WEAVE CLAUDE\.MD\|WEAVE-BLOCK-END/d; p; }' "$REPO_ROOT/CLAUDE.md")
            { printf '%s\n' "$_before"; printf '%s\n' "$_weave_block"; printf '%s' "$_after"; } > "$REPO_ROOT/CLAUDE.md"
            echo -e "  ${GREEN}✓${NC} CLAUDE.md (Weave block updated)"
        elif [ "$UPDATE_MODE" = "1" ] || [ "$FORCE_MODE" = "1" ]; then
            # Existing without block + --update/--force: prepend block
            _existing=$(cat "$REPO_ROOT/CLAUDE.md")
            { printf '%s\n\n' "$_weave_block"; printf '%s\n' "$_existing"; } > "$REPO_ROOT/CLAUDE.md"
            echo -e "  ${GREEN}✓${NC} CLAUDE.md (Weave block prepended)"
        else
            echo -e "  ${YELLOW}⊘${NC} CLAUDE.md (exists without Weave block — use --update to prepend)"
        fi
    fi

    # ── settings.json (permissions only — NO hooks key, Alt-A) ──
    # Hooks fire globally from ~/.claude/settings.json. A per-project hooks key
    # would shadow globals entirely (shallow spread). Only write on init or --force.
    if [ ! -f "$REPO_ROOT/.claude/settings.json" ] || [ "$FORCE_MODE" = "1" ]; then
        printf '{"permissions":{"allow":["Write","Edit"]}}\n' | jq . > "$REPO_ROOT/.claude/settings.json"
        echo -e "  ${GREEN}✓${NC} .claude/settings.json (permissions only)"
    elif [ "$UPDATE_MODE" = "1" ]; then
        # On --update, strip any stale hooks key if present
        existing=$(cat "$REPO_ROOT/.claude/settings.json")
        if echo "$existing" | jq -e '.hooks' >/dev/null 2>&1; then
            echo "$existing" | jq 'del(.hooks)' > "$REPO_ROOT/.claude/settings.json"
            echo -e "  ${GREEN}✓${NC} .claude/settings.json (removed stale hooks key)"
        else
            echo -e "  ${YELLOW}⊘${NC} .claude/settings.json (already clean, skipped)"
        fi
    else
        echo -e "  ${YELLOW}⊘${NC} .claude/settings.json (already exists, skipped)"
    fi

    # ── settings.local.json (user file — permissions + MCP servers) ──
    if [ ! -f "$REPO_ROOT/.claude/settings.local.json" ] || [ "$FORCE_MODE" = "1" ]; then
        cat > "$REPO_ROOT/.claude/settings.local.json" << SETTINGSEOF
{
  "mcpServers": {
    "weave": {
      "command": "node",
      "args": ["$MCP_SERVER"]
    },
    "weave-inspect": {
      "command": "node",
      "args": ["$MCP_SERVER", "--scope=inspect"]
    }
  },
  "permissions": {
    "allow": [
      "Bash(wv *)",
      "Bash(git push:*)",
      "Bash(gh issue *)"
    ]
  }
}
SETTINGSEOF
        echo -e "  ${GREEN}✓${NC} .claude/settings.local.json"
    else
        echo -e "  ${YELLOW}⊘${NC} .claude/settings.local.json (user file, use --force to overwrite)"
    fi

    # ── Makefile (create on init, section-replace on --force/--update) ──
    if [ -f "$CONFIG_DIR/Makefile.template" ]; then
        if [ ! -f "$REPO_ROOT/Makefile" ]; then
            cp "$CONFIG_DIR/Makefile.template" "$REPO_ROOT/Makefile"
            echo -e "  ${GREEN}✓${NC} Makefile (wv targets)"
        elif [ "$FORCE_MODE" = "1" ] || [ "$UPDATE_MODE" = "1" ]; then
            if grep -q '# ── BEGIN WEAVE TARGETS ──' "$REPO_ROOT/Makefile"; then
                # Replace existing weave section, preserve user targets
                _tmp_mk=$(mktemp)
                # Keep everything before BEGIN marker
                sed '/# ── BEGIN WEAVE TARGETS ──/,$d' "$REPO_ROOT/Makefile" > "$_tmp_mk"
                # Insert new weave section
                cat "$CONFIG_DIR/Makefile.template" >> "$_tmp_mk"
                # Keep everything after END marker
                sed -n '/# ── END WEAVE TARGETS ──/,${/# ── END WEAVE TARGETS ──/d;p}' "$REPO_ROOT/Makefile" >> "$_tmp_mk"
                mv "$_tmp_mk" "$REPO_ROOT/Makefile"
                echo -e "  ${GREEN}✓${NC} Makefile (weave targets updated, user targets preserved)"
            elif ! grep -q '^wv-status:' "$REPO_ROOT/Makefile"; then
                # No markers and no wv targets — append
                echo "" >> "$REPO_ROOT/Makefile"
                cat "$CONFIG_DIR/Makefile.template" >> "$REPO_ROOT/Makefile"
                echo -e "  ${GREEN}✓${NC} Makefile (appended wv targets)"
            else
                # Has old-style wv targets without markers — warn
                echo -e "  ${YELLOW}⊘${NC} Makefile (has wv targets but no section markers — manually replace or delete wv-* targets first)"
            fi
        elif grep -q '^wv-status:' "$REPO_ROOT/Makefile"; then
            echo -e "  ${YELLOW}⊘${NC} Makefile (wv targets already present)"
        else
            echo -e "  ${YELLOW}⊘${NC} Makefile (exists, use --update to append wv targets)"
        fi
    fi

fi

if [ "$AGENT" = "copilot" ]; then
    # VS Code Copilot: .vscode/mcp.json + .github/copilot-instructions.md

    # ── mcp.json (user file — only create on init or with --force) ──
    mkdir -p "$REPO_ROOT/.vscode"
    if [ ! -f "$REPO_ROOT/.vscode/mcp.json" ] || [ "$FORCE_MODE" = "1" ]; then
        cat > "$REPO_ROOT/.vscode/mcp.json" << MCPEOF
{
  "servers": {
    "weave": {
      "command": "node",
      "args": ["$MCP_SERVER"]
    },
    "weave-inspect": {
      "command": "node",
      "args": ["$MCP_SERVER", "--scope=inspect"]
    }
  }
}
MCPEOF
        echo -e "  ${GREEN}✓${NC} .vscode/mcp.json"
        if [ ! -f "$MCP_SERVER" ]; then
            echo -e "  ${YELLOW}⊘${NC} MCP server not found at $MCP_SERVER"
            echo -e "    Run: install.sh --with-mcp"
        fi
    else
        echo -e "  ${YELLOW}⊘${NC} .vscode/mcp.json (user file, use --force to overwrite)"
    fi

    # ── .vscode/settings.json — strip ghost setting on --update ──
    _VSCODE_SETTINGS="$REPO_ROOT/.vscode/settings.json"
    if [ "$UPDATE_MODE" = "1" ] && [ -f "$_VSCODE_SETTINGS" ]; then
        if grep -q '"chat.hooks.enabled"' "$_VSCODE_SETTINGS" 2>/dev/null; then
            # Remove the ghost setting line (and trailing comma if present)
            sed -i '/"chat\.hooks\.enabled"/d' "$_VSCODE_SETTINGS"
            # Clean up empty JSON object or trailing commas
            if python3 -c "import json,sys; d=json.load(open('$_VSCODE_SETTINGS')); json.dump(d,open('$_VSCODE_SETTINGS','w'),indent=2)" 2>/dev/null; then
                echo -e "  ${GREEN}✓${NC} .vscode/settings.json (stripped ghost setting chat.hooks.enabled)"
            else
                echo -e "  ${YELLOW}⚠${NC} .vscode/settings.json (removed chat.hooks.enabled, verify JSON)"
            fi
        fi
    fi

    # ── .github/hooks/ — VS Code native hook location (scaffold on init) ──
    if [ ! -d "$REPO_ROOT/.github/hooks" ]; then
        mkdir -p "$REPO_ROOT/.github/hooks"
        cat > "$REPO_ROOT/.github/hooks/README.md" << 'GHHOOKSEOF'
# VS Code Hooks

This directory is the VS Code-native hook location (`chat.hookFilesLocations`).
Place `*.json` hook configuration files here for team-shared VS Code hooks.

Global personal hooks live in `~/.claude/settings.json` and fire for all agents.
GHHOOKSEOF
        echo -e "  ${GREEN}✓${NC} .github/hooks/ (VS Code hook directory scaffolded)"
    else
        echo -e "  ${YELLOW}⊘${NC} .github/hooks/ (already exists)"
    fi

    # ── copilot-instructions.md (managed — always update from template) ──
    mkdir -p "$REPO_ROOT/.github"
    _STUB_TEMPLATE="$CONFIG_DIR/copilot-instructions.stub.md"
    if [ ! -f "$REPO_ROOT/.github/copilot-instructions.md" ] || [ "$UPDATE_MODE" = "1" ]; then
        if [ -f "$_STUB_TEMPLATE" ]; then
            cp "$_STUB_TEMPLATE" "$REPO_ROOT/.github/copilot-instructions.md"
        else
            # Fallback: inline minimal stub if template not installed
            cat > "$REPO_ROOT/.github/copilot-instructions.md" << 'COPILOTEOF'
# GitHub Copilot Instructions

This repository uses **Weave** for task tracking. Every code change must be tracked.

## Before every file edit

Call `weave_edit_guard` (MCP) before any edit. If blocked, claim a task first.

## Reference

- MCP: `weave_guide` (topics: workflow, github, learnings, context)
- CLI: `~/.config/weave/WORKFLOW.md`

COPILOTEOF
        fi
        echo -e "  ${GREEN}✓${NC} .github/copilot-instructions.md"
    else
        echo -e "  ${YELLOW}⊘${NC} .github/copilot-instructions.md (exists, use --update to overwrite)"
    fi

fi

done  # end for AGENT in AGENTS

# ── Summary ──
echo ""
if [ "$UPDATE_MODE" = "1" ]; then
    echo -e "${GREEN}✓ Weave updated in $REPO_ROOT (agent=$AGENT_LABEL)${NC}"

    # Warn about unstaged changes from update
    local_changes=$(cd "$REPO_ROOT" && git diff --name-only 2>/dev/null; git ls-files --others --exclude-standard .claude/ .github/ .vscode/ 2>/dev/null || true)
    if [ -n "$local_changes" ]; then
        echo ""
        echo -e "${YELLOW}⚠ Unstaged changes from update:${NC}"
        echo "$local_changes" | while read -r f; do echo "  $f"; done
        echo -e "${YELLOW}  Run: git add -A .claude/ .github/ .vscode/ && git commit -m 'chore: update Weave scaffolding'${NC}"
    fi
else
    echo -e "${GREEN}✓ Weave initialized in $REPO_ROOT (agent=$AGENT_LABEL)${NC}"
fi
echo "  .weave/         — graph storage"
echo "  .gitignore      — Weave entries added"
for _a in "${AGENTS[@]}"; do
    if [ "$_a" = "claude" ]; then
        echo "  .claude/hooks/   — session lifecycle hooks"
        echo "  .claude/skills/  — on-demand skills"
        echo "  CLAUDE.md        — agent instructions"
    elif [ "$_a" = "copilot" ]; then
        echo "  .vscode/mcp.json — Copilot MCP config"
        echo "  .github/copilot-instructions.md — Minimal stub (workflow via weave_guide)"
        echo "  .github/hooks/ — VS Code native hook location"
    fi
done
INITEOF

chmod +x "$INSTALL_DIR/wv-init-repo"

# Create wv-update command (re-runs installer)
# Capture the install source dir at install time so wv-update can find it later
_WV_SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cat > "$INSTALL_DIR/wv-update" << UPDATEEOF
#!/bin/bash
# Re-run the Weave installer to update all components
set -e
echo "Updating Weave..."
INSTALL_DIR="$INSTALL_DIR"
CONFIG_DIR="$CONFIG_DIR"

# Find source: CWD git repo > source repo (baked in at install time) > GitHub download
REPO_ROOT=\$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if [ -n "\$REPO_ROOT" ] && [ -f "\$REPO_ROOT/install.sh" ] && [ -f "\$REPO_ROOT/scripts/wv" ]; then
    cd "\$REPO_ROOT"
    bash install.sh
elif [ -f "$_WV_SOURCE_DIR/install.sh" ] && [ -f "$_WV_SOURCE_DIR/scripts/wv" ] && git -C "$_WV_SOURCE_DIR" rev-parse --git-dir &>/dev/null; then
    # Installed from local git repo — use it as update source
    cd "$_WV_SOURCE_DIR"
    git pull --ff-only 2>/dev/null || true
    bash install.sh
else
    curl -sSL https://raw.githubusercontent.com/AGM1968/weave/main/install.sh | bash
fi
UPDATEEOF
chmod +x "$INSTALL_DIR/wv-update"

# MCP server (optional)
if [ "$WITH_MCP" = "1" ]; then
    echo ""
    echo -e "${CYAN}━━━ MCP Server ━━━${NC}"
    if ! command -v node &>/dev/null; then
        echo -e "${RED}✗ node not found — MCP server requires Node.js${NC}"
        echo "  Install Node.js 18+ and re-run with --with-mcp"
    elif ! command -v npm &>/dev/null; then
        echo -e "${RED}✗ npm not found — MCP server requires npm${NC}"
    else
        local mcp_dir="$LIB_DIR/mcp"
        mkdir -p "$mcp_dir"
        if [ -f "./mcp/package.json" ]; then
            echo "Building MCP server from local source..."
            cp ./mcp/package.json ./mcp/tsconfig.json "$mcp_dir/" 2>/dev/null || true
            cp -r ./mcp/src "$mcp_dir/" 2>/dev/null || true
            (cd "$mcp_dir" && npm install --production=false --silent 2>&1 | tail -1 && npm run build --silent 2>&1) && {
                echo -e "${GREEN}✓ MCP server built${NC}"
                echo "$mcp_dir" >> "$MANIFEST"
            } || {
                echo -e "${RED}✗ MCP server build failed${NC}"
            }
        else
            echo "Downloading MCP server from GitHub..."
            local mcp_repo="https://raw.githubusercontent.com/AGM1968/weave/main/mcp"
            curl -sSL "$mcp_repo/package.json" -o "$mcp_dir/package.json"
            curl -sSL "$mcp_repo/tsconfig.json" -o "$mcp_dir/tsconfig.json"
            mkdir -p "$mcp_dir/src"
            curl -sSL "$mcp_repo/src/index.ts" -o "$mcp_dir/src/index.ts"
            (cd "$mcp_dir" && npm install --production=false --silent 2>&1 | tail -1 && npm run build --silent 2>&1) && {
                echo -e "${GREEN}✓ MCP server built${NC}"
                echo "$mcp_dir" >> "$MANIFEST"
            } || {
                echo -e "${RED}✗ MCP server build failed${NC}"
            }
        fi
        if [ -f "$mcp_dir/dist/index.js" ]; then
            echo ""
            echo "To register with Claude Code, add to .claude/settings.local.json:"
            echo "  \"mcpServers\": {"
            echo "    \"weave\": {"
            echo "      \"command\": \"node\","
            echo "      \"args\": [\"$mcp_dir/dist/index.js\"]"
            echo "    }"
            echo "  }"
        fi
    fi
fi

echo ""
echo -e "${GREEN}━━━ Installation Complete ━━━${NC}"
echo ""
echo "Commands installed:"
echo "  wv            — Core CLI ($("$INSTALL_DIR/wv" --version 2>/dev/null || echo "unknown version"))"
echo "  wv-test       — Isolated test runner"
echo "  wv-runtime    — Weave coding agent (headless or --tui)"
echo "  wv-init-repo  — Initialize Weave in a new repo"
echo "  wv-update     — Update Weave to latest version"
[ "$WITH_MCP" = "1" ] && [ -f "$LIB_DIR/mcp/dist/index.js" ] && \
    echo "  weave-mcp     — MCP server ($LIB_DIR/mcp/dist/index.js)"
echo ""
echo "To set up a new repo:"
echo "  cd /path/to/your/repo"
echo "  wv-init-repo"

# Run verification if requested
if [ "$VERIFY" = "1" ]; then
    echo ""
    echo -e "${CYAN}Running verification (wv selftest)...${NC}"
    if "$INSTALL_DIR/wv" selftest; then
        echo -e "${GREEN}✓ Verification passed${NC}"
    else
        echo -e "${RED}✗ Verification failed — installation may be incomplete${NC}" >&2
        exit 1
    fi
fi
}

# ═══════════════════════════════════════════════════════════════════════════
# Main Entry Point
# ═══════════════════════════════════════════════════════════════════════════

DEV_MODE=0
WITH_MCP=0
VERIFY=0
LOCAL_SOURCE=""

# Parse arguments
action=""
for arg in "$@"; do
    case "$arg" in
        --dev)              DEV_MODE=1 ;;
        --with-mcp)         WITH_MCP=1 ;;
        --no-mcp)           WITH_MCP=0; NO_MCP_EXPLICIT=1 ;;
        --verify)           VERIFY=1 ;;
        --local-source=*)   LOCAL_SOURCE="${arg#*=}" ;;
        --uninstall)        action="uninstall" ;;
        --upgrade)          action="upgrade" ;;
        --check-deps)       action="check-deps" ;;
        --help|-h)          action="help" ;;
        *)
            echo "Unknown option: $arg"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Auto-detect existing MCP installation — rebuild it on every install
# so upstream source changes (e.g. spawnSync fix) don't get stranded.
# Only relevant for install action (not uninstall/upgrade/check-deps).
if [ "${action:-install}" = "install" ] && [ "$WITH_MCP" = "0" ] && [ "${NO_MCP_EXPLICIT:-0}" != "1" ] && [ -f "${HOME}/.local/lib/weave/mcp/dist/index.js" ]; then
    WITH_MCP=1
    echo -e "${YELLOW}Note: Existing MCP server detected, will rebuild automatically.${NC}"
    echo "  (Use --no-mcp to skip. Use --with-mcp to silence this message.)"
fi

# If --local-source given, cd to that directory so relative paths work
if [ -n "$LOCAL_SOURCE" ]; then
    cd "$LOCAL_SOURCE"
fi

case "${action:-install}" in
    uninstall)  do_uninstall; exit 0 ;;
    upgrade)    do_upgrade; exit 0 ;;
    check-deps) check_deps; exit 0 ;;
    help)
        echo "Weave Installer"
        echo ""
        echo "Usage: $0 [options]"
        echo ""
        echo "Options:"
        echo "  (none)             Install by copying files"
        echo "  --dev              Install by symlinking (for development)"
        echo "  --with-mcp         Also build and install the MCP server (requires Node.js)"
        echo "  --no-mcp           Skip MCP rebuild even if already installed"
        echo "  --verify           Run wv selftest after install to verify"
        echo "  --local-source=DIR Install from DIR instead of current directory"
        echo "  --uninstall        Remove all installed files"
        echo "  --upgrade          Pull latest and reinstall"
        echo "  --check-deps       Check required dependencies"
        echo "  --help             Show this help"
        ;;
    install)    do_install ;;
esac
