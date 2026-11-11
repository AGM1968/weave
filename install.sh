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
#   ./install.sh --with-ast-grep Install optional ast-grep helper (may use network)
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
        _print_uninstall_notes
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
    _print_uninstall_notes
}

_print_uninstall_notes() {
    local global_settings="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
    echo -e "${YELLOW}Note: Config at $CONFIG_DIR preserved (contains user data)${NC}"
    echo ""
    echo "To fully remove Weave including config:"
    echo "  rm -rf $CONFIG_DIR"
    echo ""
    echo -e "${YELLOW}Note: Claude Code hook entries in $global_settings are NOT removed.${NC}"
    echo "After deleting $CONFIG_DIR, clean the stale hooks key:"
    echo "  jq 'del(.hooks)' $global_settings > /tmp/_wv_s.json && mv /tmp/_wv_s.json $global_settings"
    echo ""
    echo -e "${YELLOW}Note: Git hooks installed by wv-init-repo in consumer repos must be removed manually.${NC}"
    echo "Per repo:"
    echo "  rm -f /path/to/repo/.git/hooks/pre-commit"
    echo "  rm -f /path/to/repo/.git/hooks/post-commit"
    echo "  rm -f /path/to/repo/.git/hooks/prepare-commit-msg"
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

    # Verify the source before touching dst. A concurrent process editing this
    # same checkout (e.g. another live agent session) can make src vanish
    # between install runs; removing dst first would leave the installed copy
    # deleted with nothing to replace it (wv-fa566a).
    if [ ! -e "$src" ]; then
        echo "install_file: source not found, leaving existing install untouched: $src" >&2
        return 1
    fi

    if [ "$DEV_MODE" = "1" ]; then
        # Use absolute path for symlink
        local abs_src=$(cd "$(dirname "$src")" && pwd)/$(basename "$src")
        ln -sf "$abs_src" "$dst"
    else
        # Copy to a same-directory temp file and rename into place, so a
        # copy that fails partway (disk full, src vanishes mid-copy) never
        # leaves dst removed or truncated.
        local tmp_dst
        tmp_dst=$(mktemp "${dst}.XXXXXX" 2>/dev/null) || tmp_dst="${dst}.tmp.$$"
        if ! cp "$src" "$tmp_dst"; then
            rm -f "$tmp_dst" 2>/dev/null || true
            echo "install_file: copy failed, leaving existing install untouched: $src -> $dst" >&2
            return 1
        fi
        chmod --reference="$src" "$tmp_dst" 2>/dev/null || true
        mv -f "$tmp_dst" "$dst"
    fi

    # Record in manifest
    echo "$dst" >> "$MANIFEST"
}

# install_copy <src> <dst-file-or-dir> -- copy into an installed location the
# way install_file does (same-directory temp file, then rename), without its
# dev-mode symlink or manifest entry. A plain `cp` rewrote the installed file
# in place, so a hook bash was reading while another session ran ./install.sh
# could execute the start of the old file and the end of the new (wv-f854f6).
# A rename leaves a running reader on the old inode and gives a new reader the
# whole new file.
install_copy() {
    local src="$1" dst="$2" tmp
    [ -d "$dst" ] && dst="${dst%/}/$(basename "$src")"
    if [ ! -e "$src" ]; then
        echo "install_copy: source not found, leaving existing install untouched: $src" >&2
        return 1
    fi
    tmp=$(mktemp "${dst}.XXXXXX" 2>/dev/null) || tmp="${dst}.tmp.$$"
    if ! cp "$src" "$tmp"; then
        rm -f "$tmp" 2>/dev/null || true
        echo "install_copy: copy failed, leaving existing install untouched: $src -> $dst" >&2
        return 1
    fi
    chmod --reference="$src" "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$dst"
}

# Download and install a file
# Usage: download_file <url> <dst>
download_file() {
    local url="$1"
    local dst="$2"

    # Same atomic-replace principle as install_file: download to a temp file
    # first so a network failure never leaves dst truncated/empty while still
    # being recorded in the manifest as installed.
    local tmp_dst
    tmp_dst=$(mktemp "${dst}.XXXXXX" 2>/dev/null) || tmp_dst="${dst}.tmp.$$"
    if ! curl -fsSL "$url" -o "$tmp_dst"; then
        rm -f "$tmp_dst" 2>/dev/null || true
        echo "download_file: download failed, leaving existing install untouched: $url -> $dst" >&2
        return 1
    fi
    mv -f "$tmp_dst" "$dst"
    echo "$dst" >> "$MANIFEST"
}

# install_procedure_assets — install canonical procedure bodies outside consumer repos.
# Local installs copy the source tree; download installs enumerate the flat canonical tree.
# The destination is a fully-managed mirror: it is wiped and repopulated so a procedure or
# resource deleted from the source is also removed here (otherwise init-repo would keep
# projecting it, bypassing the adapters' stale cleanup).
install_procedure_assets() {
    local destination="$CONFIG_DIR/procedures"
    local staging old procedure_file
    # Populate a sibling staging directory first.  Removing the live canonical
    # set before a failed local copy/download would leave init-repo with no
    # usable procedures, and would break the deletion guarantee on retry.
    mkdir -p "$CONFIG_DIR"
    staging=$(mktemp -d "$CONFIG_DIR/.procedures-staging.XXXXXX")
    if [ -d "./templates/procedures" ]; then
        if ! cp -a ./templates/procedures/. "$staging/"; then
            rm -rf "$staging"
            return 1
        fi
    else
        local listing procedure_files
        if ! listing=$(curl -fsSL "https://api.github.com/repos/AGM1968/weave/contents/templates/procedures?ref=main"); then
            rm -rf "$staging"
            return 1
        fi
        # Do not treat a failed/empty API response as an empty canonical set: a
        # successful swap in that state would erase a known-good installation.
        if ! procedure_files=$(printf '%s' "$listing" | jq -er '[.[]? | select(.type == "file") | .name] | if length > 0 then .[] else error("no procedure files") end'); then
            rm -rf "$staging"
            return 1
        fi
        while IFS= read -r procedure_file; do
            [ "$procedure_file" = ".gitkeep" ] && continue
            if ! curl -fsSL "$REPO/templates/procedures/$procedure_file" -o "$staging/$procedure_file"; then
                rm -rf "$staging"
                return 1
            fi
            echo "$destination/$procedure_file" >> "$MANIFEST"
        done <<< "$procedure_files"
    fi

    old="$CONFIG_DIR/.procedures-old.$$"
    rm -rf "$old"
    if [ -e "$destination" ]; then mv "$destination" "$old"; fi
    if ! mv "$staging" "$destination"; then
        [ -e "$old" ] && mv "$old" "$destination"
        rm -rf "$staging"
        return 1
    fi
    rm -rf "$old"
}

install_pattern_assets() {
    local destination="$CONFIG_DIR/quality-patterns/managed"
    local staging old pattern_file
    mkdir -p "$(dirname "$destination")"
    staging=$(mktemp -d "$CONFIG_DIR/.quality-patterns-staging.XXXXXX")
    if [ -d "./templates/quality-patterns/managed" ]; then
        if ! cp -a ./templates/quality-patterns/managed/. "$staging/"; then
            rm -rf "$staging"
            return 1
        fi
    else
        if ! curl -fsSL "$REPO/templates/quality-patterns/managed/manifest.txt" \
            -o "$staging/manifest.txt"; then
            rm -rf "$staging"
            return 1
        fi
        while IFS= read -r pattern_file; do
            case "$pattern_file" in
                ""|*/*|*..*) rm -rf "$staging"; return 1 ;;
                *.yaml) ;;
                *) rm -rf "$staging"; return 1 ;;
            esac
            if ! curl -fsSL \
                "$REPO/templates/quality-patterns/managed/$pattern_file" \
                -o "$staging/$pattern_file"; then
                rm -rf "$staging"
                return 1
            fi
        done < "$staging/manifest.txt"
    fi

    if [ ! -s "$staging/manifest.txt" ] \
        || [ -n "$(tail -c 1 "$staging/manifest.txt")" ] \
        || [ "$(sort "$staging/manifest.txt" | uniq -d | wc -l)" -ne 0 ]; then
        rm -rf "$staging"
        return 1
    fi
    while IFS= read -r pattern_file; do
        case "$pattern_file" in
            ""|*/*|*..*) rm -rf "$staging"; return 1 ;;
            *.yaml) ;;
            *) rm -rf "$staging"; return 1 ;;
        esac
        [ -f "$staging/$pattern_file" ] || { rm -rf "$staging"; return 1; }
    done < "$staging/manifest.txt"
    for pattern_file in "$staging"/*.yaml; do
        [ -f "$pattern_file" ] || { rm -rf "$staging"; return 1; }
        grep -qxF "$(basename "$pattern_file")" "$staging/manifest.txt" \
            || { rm -rf "$staging"; return 1; }
    done
    if ! PYTHONPATH="$LIB_DIR" python3 - "$staging" <<'PY'
import sys
from pathlib import Path
from weave_quality.prose_rules import validate_pattern_rule

root = Path(sys.argv[1])
for path in root.glob("*.yaml"):
    validate_pattern_rule(path, path.stem)
PY
    then
        rm -rf "$staging"
        return 1
    fi

    old="$CONFIG_DIR/.quality-patterns-old.$$"
    rm -rf "$old"
    if [ -e "$destination" ] || [ -L "$destination" ]; then
        mv "$destination" "$old"
    fi
    if ! mv "$staging" "$destination"; then
        [ -e "$old" ] && mv "$old" "$destination"
        rm -rf "$staging"
        return 1
    fi
    rm -rf "$old"
    while IFS= read -r pattern_file; do
        echo "$destination/$pattern_file" >> "$MANIFEST"
    done < "$destination/manifest.txt"
    echo "$destination/manifest.txt" >> "$MANIFEST"
}

# repo_hooks_refresh_allowed — may this run rewrite the CURRENT repository's
# .git/hooks? Only when HOME is the account's real home. The hook directory is
# found from the working directory, not from the install target, so a test
# suite that sandboxes HOME/WV_LIB_DIR and runs install.sh from the repo root
# otherwise rewrote the real repository's live hooks mid-gate, with whatever
# the working tree held (wv-7f6c9d). A real ./install.sh and the pre-commit
# self-heal both keep the real HOME. Returns 0 when allowed.
repo_hooks_refresh_allowed() {
    local real_home
    real_home=$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6)
    [ -n "$real_home" ] || real_home=$(eval echo "~$(id -un)" 2>/dev/null)
    [ -n "$real_home" ] && [ -d "$real_home" ] && [ -d "${HOME:-}" ] || return 1
    [ "$(cd "$HOME" && pwd -P)" = "$(cd "$real_home" && pwd -P)" ]
}

# remove_retired_git_hook <hook-name> <marker> — delete a Weave hook that is no
# longer shipped, only when it carries that hook's Weave signature: a custom
# hook of the same name is the user's and is left alone. The post-commit
# deferred-suite queue was retired by wv-56c823 (nothing had written its queue
# since e2d80d855; the two-tier gate, wv-862ac0, replaced it).
remove_retired_git_hook() {
    local hook_name="$1" marker="$2"
    [ -d "${HOOK_DIR:-}" ] || return 0
    local hook_dst="$HOOK_DIR/$hook_name"
    [ -f "$hook_dst" ] || return 0
    if grep -qF -- "$marker" "$hook_dst" 2>/dev/null; then
        rm -f "$hook_dst" && echo -e "  ${GREEN}✓${NC} .git/hooks/$hook_name (retired Weave hook removed)"
    else
        echo -e "  ${YELLOW}⊘${NC} .git/hooks/$hook_name (custom hook, left alone)"
    fi
}

# resolve_git_hook_dir <repo dir> — print the directory git runs this
# repository's hooks from, or print why Weave will not install there and
# return 1 (wv-76c726). Writing $REPO_ROOT/.git/hooks or git-dir/hooks missed
# both cases git itself handles: in a linked worktree .git is a file and the
# hooks live in the common dir, and core.hooksPath moves them elsewhere; the
# install then returned 0 having installed nothing. core.hooksPath is reported,
# not written to: it is usually a hook manager's tracked directory or a global
# one every repository shares, neither of which is Weave's to change.
resolve_git_hook_dir() {
    local repo="$1" hooks hooks_path
    hooks=$(git -C "$repo" rev-parse --git-path hooks 2>/dev/null) && [ -n "$hooks" ] || {
        echo "not a git repository: $repo"
        return 1
    }
    hooks_path=$(git -C "$repo" config --get core.hooksPath 2>/dev/null || true)
    if [ -n "$hooks_path" ]; then
        echo "core.hooksPath is set ($hooks_path): git runs hooks only from there, which Weave does not write to. Call the Weave hooks from it, e.g. ${WV_LIB_DIR:-$HOME/.local/lib/weave}/hooks/pre-commit-weave.sh from its pre-commit"
        return 1
    fi
    case "$hooks" in /*) ;; *) hooks="$(cd "$repo" && pwd -P)/$hooks" ;; esac
    mkdir -p "$hooks" 2>/dev/null || { echo "cannot create $hooks"; return 1; }
    printf '%s\n' "$hooks"
}

# set_hook_dir_or_report <repo dir> — set HOOK_DIR for install_git_hook_from_repo,
# or say loudly that no Weave git hook is active and leave HOOK_DIR empty.
set_hook_dir_or_report() {
    local resolved
    if resolved=$(resolve_git_hook_dir "$1"); then
        HOOK_DIR="$resolved"
    else
        HOOK_DIR=""
        echo -e "  ${YELLOW}⚠${NC} Weave git hooks NOT installed — no commit or push gate is active here: $resolved" >&2
    fi
}

install_git_hook_from_repo() {
    local hook_path="$1"
    local marker="$2"
    local hook_name="${3:-}"
    local hook_src_name
    local action="installed"
    hook_src_name=$(basename "$hook_path")
    [ -n "$hook_name" ] || hook_name="$hook_src_name"

    # set_hook_dir_or_report has already said why when HOOK_DIR is empty.
    if [ -z "${HOOK_DIR:-}" ] || [ ! -d "$HOOK_DIR" ]; then
        return 0
    fi

    local hook_dst="$HOOK_DIR/$hook_name"
    if [ -f "$hook_dst" ]; then
        # Refresh only a Weave-managed hook. Match the exact marker OR any stable
        # Weave signature, so an OLDER installed hook whose header wording has
        # since changed is still recognised and refreshed — instead of being
        # mistaken for a custom user hook and skipped (left stale, the friction
        # wv doctor flagged with a manual `install -m 755 ...`). A genuinely
        # custom hook (no Weave signature) is still preserved. The signatures
        # live in wv-git-hook-signature.sh, shared with wv doctor (wv-3a7368).
        if wv_git_hook_is_weave "$hook_dst" "$marker"; then
            action="updated"
        else
            # Preserved, but say what that costs: this gate is not active.
            echo -e "  ${YELLOW}⚠${NC} $hook_dst is a custom hook, kept as is — the Weave $hook_name gate is NOT active. Call ${WV_LIB_DIR:-$HOME/.local/lib/weave}/hooks/$hook_src_name from it to enable it." >&2
            return 0
        fi
    fi

    local lib_hook="${WV_LIB_DIR:-$HOME/.local/lib/weave}/hooks/$hook_src_name"

    # Write to a same-directory temp and RENAME into place. Copying onto the
    # destination truncates and rewrites the inode -- and the pre-commit hook's
    # own install-drift self-heal runs install.sh, so a commit that touched the
    # hook source rewrote the very file bash was executing. Bash reads a script
    # incrementally, so it resumed at its old byte offset inside new content and
    # died with a syntax error naming a line that was perfectly valid; the retry
    # then succeeded, which made it read as a flake. A rename swaps the
    # directory entry and leaves the running process on its original inode.
    local hook_tmp hook_got=0
    hook_tmp=$(mktemp "${hook_dst}.XXXXXX" 2>/dev/null) || hook_tmp="${hook_dst}.tmp.$$"
    if [ -f "$hook_path" ]; then
        cp "$hook_path" "$hook_tmp" && hook_got=1
    elif [ -f "$lib_hook" ]; then
        cp "$lib_hook" "$hook_tmp" && hook_got=1
    else
        local repo_base="${REPO:-https://raw.githubusercontent.com/AGM1968/weave/main}"
        curl -sSL "$repo_base/scripts/hooks/$hook_src_name" -o "$hook_tmp" \
            && [ -s "$hook_tmp" ] && hook_got=1
    fi
    if [ "$hook_got" != "1" ]; then
        rm -f "$hook_tmp" 2>/dev/null || true
        echo -e "  ${YELLOW}⊘${NC} .git/hooks/$hook_name (source unavailable, existing hook kept)"
        return 0
    fi
    chmod +x "$hook_tmp"
    if ! mv -f "$hook_tmp" "$hook_dst" 2>/dev/null; then
        rm -f "$hook_tmp" 2>/dev/null || true
        echo -e "  ${YELLOW}⊘${NC} .git/hooks/$hook_name (could not be replaced, existing hook kept)"
        return 0
    fi
    echo -e "  ${GREEN}✓${NC} .git/hooks/$hook_name ($action)"
}

# install_git_hook_module_from_repo <module source> — copy a module the
# installed pre-commit hook loads from beside itself into the same hooks dir
# (wv-758b3a, owner ruling on wv-0e2998). Taken from this repository's own
# source and nowhere else, never from LIB_DIR or the network: only Weave's
# source repository has it, so no consumer receives it. Installed only beside
# a Weave pre-commit hook; a custom hook does not load it.
install_git_hook_module_from_repo() {
    local mod_path="$1" mod_name mod_tmp
    mod_name=$(basename "$mod_path")
    if [ -z "${HOOK_DIR:-}" ] || [ ! -d "$HOOK_DIR" ] || [ ! -f "$mod_path" ]; then
        return 0
    fi
    if ! wv_git_hook_is_weave "$HOOK_DIR/pre-commit" "Weave pre-commit"; then
        return 0
    fi
    mod_tmp=$(mktemp "$HOOK_DIR/$mod_name.XXXXXX" 2>/dev/null) || mod_tmp="$HOOK_DIR/$mod_name.tmp.$$"
    if ! cp "$mod_path" "$mod_tmp" 2>/dev/null || ! chmod 644 "$mod_tmp" \
        || ! mv -f "$mod_tmp" "$HOOK_DIR/$mod_name" 2>/dev/null; then
        rm -f "$mod_tmp" 2>/dev/null || true
        echo -e "  ${YELLOW}⚠${NC} .git/hooks/$mod_name could not be installed; the pre-commit hook beside it needs it" >&2
        return 0
    fi
    echo -e "  ${GREEN}✓${NC} .git/hooks/$mod_name (installed)"
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
mkdir -p "$LIB_DIR/profiling"
mkdir -p "$CONFIG_DIR"

# The install lock (wv-f854f6): while this installer replaces files, its PID
# sits in $CONFIG_DIR/.install-in-progress. wv and the hooks' library loaders
# wait for it (up to 10 s) before loading, so a session running alongside
# never loads some libraries from before the install and some from after.
# WV_INSTALLING exempts this installer's own children from that wait.
WV_INSTALL_LOCK="$CONFIG_DIR/.install-in-progress"
export WV_INSTALLING=$$
echo $$ > "$WV_INSTALL_LOCK"
trap 'rm -f "$WV_INSTALL_LOCK"' EXIT

# Create config subdirectories
mkdir -p "$CONFIG_DIR/hooks"
mkdir -p "$CONFIG_DIR/lib"
mkdir -p "$CONFIG_DIR/agents"
# The skills install.sh places in CONFIG_DIR - the ONE list the mkdir, copy,
# download and prune steps below read (wv-f4a68b). Four hand-kept copies of it
# drifted: the breadcrumbs -> trails rename reached only some of them.
WV_CONFIG_SKILLS=(trails close-session wv-decompose-work fix-issue pre-mortem wv-verify-complete
    resolve-refs wv-clarify-spec sanity-check ship-it wv-guard-scope wv-detect-loop weave-audit
    weave zero-in plan-agent)
for _wv_sk in "${WV_CONFIG_SKILLS[@]}"; do mkdir -p "$CONFIG_DIR/skills/$_wv_sk"; done

# Record source path so wv self-update can find the dev clone later
_WV_INSTALL_SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if git -C "$_WV_INSTALL_SOURCE" rev-parse --git-dir &>/dev/null 2>&1; then
    echo "$_WV_INSTALL_SOURCE" > "$CONFIG_DIR/source-path"
fi

# Download or copy wv CLI + config
if [ -f "./scripts/wv" ]; then
    echo -e "${YELLOW}Installing from local source...${NC}"
    # CLI entry point
    install_file ./scripts/wv "$INSTALL_DIR/wv"
    install_file ./scripts/wv-test "$INSTALL_DIR/wv-test"
    # wv-runtime bash wrapper retired (S2) — use python -m weave_runtime from
    # the standalone weave-runtime repo instead. Clean up stale installed copy.
    rm -f "$INSTALL_DIR/wv-runtime" 2>/dev/null || true
    # Library modules (XDG: ~/.local/lib/weave/lib/)
    install_file ./scripts/lib/wv-config.sh "$LIB_DIR/lib/wv-config.sh"
    install_file ./scripts/lib/wv-db.sh "$LIB_DIR/lib/wv-db.sh"
    install_file ./scripts/lib/wv-db-lineage.sh "$LIB_DIR/lib/wv-db-lineage.sh"
    install_file ./scripts/lib/wv-validate.sh "$LIB_DIR/lib/wv-validate.sh"
    install_file ./scripts/lib/wv-cache.sh "$LIB_DIR/lib/wv-cache.sh"
    install_file ./scripts/lib/wv-command-capabilities.sh "$LIB_DIR/lib/wv-command-capabilities.sh"
    install_file ./scripts/lib/wv-policy-rules.sh "$LIB_DIR/lib/wv-policy-rules.sh"
    install_file ./scripts/lib/wv-journal.sh "$LIB_DIR/lib/wv-journal.sh"
    install_file ./scripts/lib/wv-attempt-journal.sh "$LIB_DIR/lib/wv-attempt-journal.sh"
    install_file ./scripts/lib/wv-gh.sh "$LIB_DIR/lib/wv-gh.sh"
    install_file ./scripts/lib/wv-delta.sh "$LIB_DIR/lib/wv-delta.sh"
    install_file ./scripts/lib/wv-delta-catalog.sh "$LIB_DIR/lib/wv-delta-catalog.sh"
    install_file ./scripts/lib/wv-compact-pre-cutover.sh "$LIB_DIR/lib/wv-compact-pre-cutover.sh"
    install_file ./scripts/lib/wv-delta-v2-replay.py "$LIB_DIR/lib/wv-delta-v2-replay.py"
    install_file ./scripts/lib/wv-load-ack.py "$LIB_DIR/lib/wv-load-ack.py"
    install_file ./scripts/lib/wv-clone-roster.py "$LIB_DIR/lib/wv-clone-roster.py"
    install_file ./scripts/lib/wv-checkpoint-generation.sh "$LIB_DIR/lib/wv-checkpoint-generation.sh"
    install_file ./scripts/lib/wv-checkpoint-ci.sh "$LIB_DIR/lib/wv-checkpoint-ci.sh"
    install_file ./scripts/lib/wv-shell-scope.sh "$LIB_DIR/lib/wv-shell-scope.sh"
    install_file ./scripts/lib/wv-scratch.sh "$LIB_DIR/lib/wv-scratch.sh"
    install_file ./scripts/lib/wv-gate-pool.sh "$LIB_DIR/lib/wv-gate-pool.sh"
    install_file ./scripts/lib/wv-gate-supervisor.py "$LIB_DIR/lib/wv-gate-supervisor.py"
    install_file ./scripts/lib/wv-gate-suite.py "$LIB_DIR/lib/wv-gate-suite.py"
    install_file ./scripts/lib/wv-gate-provision.json "$LIB_DIR/lib/wv-gate-provision.json"
    install_file ./scripts/lib/wv-gate-paths.py "$LIB_DIR/lib/wv-gate-paths.py"
    install_file ./scripts/lib/wv-gate-propose.py "$LIB_DIR/lib/wv-gate-propose.py"
    install_file ./scripts/lib/wv-gate-snapshot.sh "$LIB_DIR/lib/wv-gate-snapshot.sh"
    install_file ./scripts/lib/wv-gate-lanes.sh "$LIB_DIR/lib/wv-gate-lanes.sh"
    install_file ./scripts/lib/wv-gate-hold.sh "$LIB_DIR/lib/wv-gate-hold.sh"
    install_file ./scripts/lib/wv-repository-class.sh "$LIB_DIR/lib/wv-repository-class.sh"
    install_file ./scripts/lib/wv-git-hook-signature.sh "$LIB_DIR/lib/wv-git-hook-signature.sh"
    install_file ./scripts/lib/wv-runtime-ignores.sh "$LIB_DIR/lib/wv-runtime-ignores.sh"
    install_file ./scripts/lib/wv-workflow-classes.gen.sh "$LIB_DIR/lib/wv-workflow-classes.gen.sh"
    install_file ./scripts/lib/wv-violation-vocabulary.gen.sh "$LIB_DIR/lib/wv-violation-vocabulary.gen.sh"
    install_file ./scripts/lib/wv-hook-common.sh "$LIB_DIR/lib/wv-hook-common.sh"
    install_file ./scripts/lib/wv-hook-observe.sh "$LIB_DIR/lib/wv-hook-observe.sh"
    install_file ./scripts/lib/wv-pre-tool-use.sh "$LIB_DIR/lib/wv-pre-tool-use.sh"
    install_file ./scripts/lib/wv-post-tool-use.sh "$LIB_DIR/lib/wv-post-tool-use.sh"
    install_file ./scripts/lib/wv-attribution.sh "$LIB_DIR/lib/wv-attribution.sh"
    install_file ./scripts/lib/wv-lifecycle-end.sh "$LIB_DIR/lib/wv-lifecycle-end.sh"
    install_file ./scripts/lib/wv-session-start.sh "$LIB_DIR/lib/wv-session-start.sh"
    install_file ./scripts/lib/wv-resolve-project.sh "$LIB_DIR/lib/wv-resolve-project.sh"
    install_file ./scripts/lib/wv-resolve-runtime.sh "$LIB_DIR/lib/wv-resolve-runtime.sh"
    install_file ./scripts/lib/wv-graph-diff.sh "$LIB_DIR/lib/wv-graph-diff.sh"
    install_file ./scripts/lib/VERSION "$LIB_DIR/lib/VERSION"

    # Install provenance. VERSION alone cannot answer "which fixes does this
    # install have": fixes land continuously between bumps, so an install can
    # be dozens of commits behind while reporting an identical version string.
    # That is not hypothetical — a consumer sat 72 commits behind v1.71.0-rc.5,
    # still hitting a jq argv-limit bug fixed four days earlier, with nothing on
    # its side able to reveal it. Recording the source commit makes the question
    # answerable with `wv doctor` instead of a file-by-file diff.
    {
        echo "installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "source_path=$(pwd -P 2>/dev/null || echo unknown)"
        echo "commit=$(git rev-parse HEAD 2>/dev/null || echo unknown)"
        echo "describe=$(git describe --tags --always --dirty 2>/dev/null || echo unknown)"
        echo "branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
        # Untracked files count. `git diff --quiet HEAD` ignores them, so an
        # install built from a tree carrying uncommitted new files recorded
        # dirty=false and looked reproducible when it was not.
        echo "dirty=$(if [ -n "$(git status --porcelain 2>/dev/null)" ]; then echo true; else echo false; fi)"
    } > "$LIB_DIR/lib/INSTALL_PROVENANCE" 2>/dev/null || true
    # Command modules (XDG: ~/.local/lib/weave/cmd/)
    install_file ./scripts/cmd/wv-cmd-core.sh "$LIB_DIR/cmd/wv-cmd-core.sh"
    install_file ./scripts/cmd/wv-cmd-graph.sh "$LIB_DIR/cmd/wv-cmd-graph.sh"
    install_file ./scripts/cmd/wv-cmd-data.sh "$LIB_DIR/cmd/wv-cmd-data.sh"
    install_file ./scripts/cmd/wv-cmd-ops.sh "$LIB_DIR/cmd/wv-cmd-ops.sh"
    install_file ./scripts/cmd/wv-cmd-doctor.sh "$LIB_DIR/cmd/wv-cmd-doctor.sh"
    install_file ./scripts/cmd/wv-cmd-health.sh "$LIB_DIR/cmd/wv-cmd-health.sh"
    install_file ./scripts/cmd/wv-cmd-help.sh "$LIB_DIR/cmd/wv-cmd-help.sh"
    install_file ./scripts/cmd/wv-cmd-orient.sh "$LIB_DIR/cmd/wv-cmd-orient.sh"
    install_file ./scripts/cmd/wv-cmd-gate.sh "$LIB_DIR/cmd/wv-cmd-gate.sh"
    install_file ./scripts/cmd/wv-cmd-python.sh "$LIB_DIR/cmd/wv-cmd-python.sh"
    install_file ./scripts/cmd/wv-cmd-hotzone.sh "$LIB_DIR/cmd/wv-cmd-hotzone.sh"
    install_file ./scripts/cmd/wv-cmd-gitstate.sh "$LIB_DIR/cmd/wv-cmd-gitstate.sh"
    install_file ./scripts/cmd/wv-cmd-procedures.sh "$LIB_DIR/cmd/wv-cmd-procedures.sh"
    install_file ./scripts/cmd/wv-cmd-graduate.sh "$LIB_DIR/cmd/wv-cmd-graduate.sh"
    install_file ./scripts/cmd/wv-cmd-recover.sh "$LIB_DIR/cmd/wv-cmd-recover.sh"
    install_file ./scripts/cmd/wv-cmd-quality.sh "$LIB_DIR/cmd/wv-cmd-quality.sh"
    install_file ./scripts/cmd/wv-cmd-findings.sh "$LIB_DIR/cmd/wv-cmd-findings.sh"
    install_file ./scripts/cmd/wv-cmd-analyze.sh "$LIB_DIR/cmd/wv-cmd-analyze.sh"
    install_file ./scripts/cmd/wv-cmd-indexer.sh "$LIB_DIR/cmd/wv-cmd-indexer.sh"
    install_file ./scripts/cmd/wv-cmd-query.sh "$LIB_DIR/cmd/wv-cmd-query.sh"
    install_file ./scripts/cmd/wv-cmd-hook.sh "$LIB_DIR/cmd/wv-cmd-hook.sh"
    install_file ./profiling/audit_sessions.py "$LIB_DIR/profiling/audit_sessions.py"
    install_file ./profiling/checkpoint_overlap.py "$LIB_DIR/profiling/checkpoint_overlap.py"
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
    mkdir -p "$LIB_DIR/weave_quality/rules"
    for rulef in ./scripts/weave_quality/rules/*.yaml; do
        install_file "$rulef" "$LIB_DIR/weave_quality/rules/$(basename "$rulef")"
    done
    mkdir -p "$LIB_DIR/weave_quality/default_patterns"
    for installed_pattern in "$LIB_DIR"/weave_quality/default_patterns/*.yaml; do
        [ -f "$installed_pattern" ] || continue
        [ -f "./scripts/weave_quality/default_patterns/$(basename "$installed_pattern")" ] \
            || rm -f "$installed_pattern"
    done
    for pf in ./scripts/weave_quality/default_patterns/*.yaml; do
        install_file "$pf" "$LIB_DIR/weave_quality/default_patterns/$(basename "$pf")"
    done
    install_file ./scripts/weave_quality/default_patterns/manifest.json \
        "$LIB_DIR/weave_quality/default_patterns/manifest.json"
    # Coaching guide assets. Flat by contract: both installer paths enumerate
    # this directory non-recursively, which is also why a guide basename may
    # never contain a dot or a slash.
    mkdir -p "$LIB_DIR/weave_quality/guides"
    # A guide that left the package (wv-6d72de) is pruned like a pattern above,
    # or the installed copy would coach on after its type is gone.
    for installed_guide in "$LIB_DIR"/weave_quality/guides/*.md; do
        [ -f "$installed_guide" ] || continue
        [ -f "./scripts/weave_quality/guides/$(basename "$installed_guide")" ] \
            || rm -f "$installed_guide"
    done
    for guide in ./scripts/weave_quality/guides/*.md; do
        install_file "$guide" "$LIB_DIR/weave_quality/guides/$(basename "$guide")"
    done
    # Pure coaching package: planner and view. Installed like any other package
    # so the resolved guide and the code that renders it travel together.
    mkdir -p "$LIB_DIR/weave_coaching"
    for pyf in ./scripts/weave_coaching/*.py; do
        install_file "$pyf" "$LIB_DIR/weave_coaching/$(basename "$pyf")"
    done
    # Machine-readable contracts the runtime reads (the violation vocabulary and
    # the coaching schemas). Installed mode resolves these from $LIB_DIR, never
    # from a source checkout that may not exist on the target machine.
    mkdir -p "$LIB_DIR/contracts"
    for contract in ./contracts/violation-vocabulary-v1.json ./contracts/coaching-*.json; do
        [ -f "$contract" ] || continue
        install_file "$contract" "$LIB_DIR/contracts/$(basename "$contract")"
    done
    # The MCP contract is one of these, and is installed unconditionally rather
    # than under --with-mcp: wv mcp-status reads it whether or not this machine
    # builds the server, and it used to be read from the CONSUMER repository's
    # own mcp/contract.json -- a file no consumer has, which made scope
    # reporting collapse silently instead of failing.
    if [ -f ./mcp/contract.json ]; then
        mkdir -p "$LIB_DIR/mcp"
        install_file ./mcp/contract.json "$LIB_DIR/mcp/contract.json"
    else
        # Guarded like the contracts loop above: install_file returns nonzero on
        # a missing source and this script runs under set -e, so a bare call
        # would turn one absent asset into an aborted install. An absence is not
        # silent either way -- wv mcp-status reports the authority unavailable.
        echo "install: mcp/contract.json not found in source; wv mcp-status will report the contract unavailable" >&2
    fi
    mkdir -p "$LIB_DIR/weave_indexer"
    for pyf in ./scripts/weave_indexer/*.py; do
        install_file "$pyf" "$LIB_DIR/weave_indexer/$(basename "$pyf")"
    done
    mkdir -p "$LIB_DIR/weave_search"
    for pyf in ./scripts/weave_search/*.py; do
        install_file "$pyf" "$LIB_DIR/weave_search/$(basename "$pyf")"
    done
    # Git hook sources — stored in LIB_DIR/hooks/ so wv-init-repo --update
    # can refresh vendored scripts/hooks/ in consumer repos without network access
    mkdir -p "$LIB_DIR/hooks"
    install_file ./scripts/hooks/pre-commit-weave.sh "$LIB_DIR/hooks/pre-commit-weave.sh"
    # Builder-only (wv-758b3a): Weave's source repository alone has it, and a
    # release does not ship it, so a LIB_DIR copy exists only where it does.
    if [ -f ./scripts/hooks/pre-commit-recovery.sh ]; then
        install_file ./scripts/hooks/pre-commit-recovery.sh "$LIB_DIR/hooks/pre-commit-recovery.sh"
    else
        rm -f "$LIB_DIR/hooks/pre-commit-recovery.sh" 2>/dev/null || true
    fi
    # post-commit-weave.sh is retired (wv-56c823): drop an installed copy.
    rm -f "$LIB_DIR/hooks/post-commit-weave.sh" 2>/dev/null || true
    install_file ./scripts/hooks/prepare-commit-msg-weave.sh "$LIB_DIR/hooks/prepare-commit-msg-weave.sh"
    install_file ./scripts/hooks/pre-push-weave.sh "$LIB_DIR/hooks/pre-push-weave.sh"
    install_file ./scripts/hooks/reference-transaction-weave.sh "$LIB_DIR/hooks/reference-transaction-weave.sh"

    # Refresh THIS repository's git hooks too, when installing from inside one.
    #
    # These were only ever refreshed by the generated `wv-init-repo` (the call
    # sites live inside the INITEOF heredoc), so a normal `./install.sh` upgrade
    # updated LIB_DIR and left .git/hooks/ at whatever version it was scaffolded
    # with. A behaviour change to a hook therefore did not take effect for an
    # existing install until someone ran `wv init-repo --update` or copied it by
    # hand — which is how a new pre-commit gate could sit inert while `wv doctor`
    # reported the hook merely "stale". install_git_hook_from_repo was defined
    # here and never called; this is the missing call.
    #
    # It refreshes only Weave-managed hooks: a custom hook without a Weave
    # signature is preserved and skipped, per the marker check in the function.
    # A sandboxed install (tests redirect HOME) leaves them alone: see
    # repo_hooks_refresh_allowed.
    if repo_hooks_refresh_allowed && git rev-parse --git-dir >/dev/null 2>&1; then
        # shellcheck source=scripts/lib/wv-git-hook-signature.sh
        source ./scripts/lib/wv-git-hook-signature.sh
        set_hook_dir_or_report "$PWD"
        install_git_hook_from_repo ./scripts/hooks/pre-commit-weave.sh "Weave pre-commit" "pre-commit"
        install_git_hook_module_from_repo ./scripts/hooks/pre-commit-recovery.sh
        remove_retired_git_hook "post-commit" "Weave post-commit"
        install_git_hook_from_repo ./scripts/hooks/prepare-commit-msg-weave.sh "Weave: append Weave-ID trailers" "prepare-commit-msg"
        install_git_hook_from_repo ./scripts/hooks/pre-push-weave.sh "Weave pre-push" "pre-push"
        install_git_hook_from_repo ./scripts/hooks/reference-transaction-weave.sh "Weave reference-transaction" "reference-transaction"
    fi
    # Scripts
    # context-guard.sh has one copy, under hooks/ (an on-demand banner since
    # wv-a523de folded its SessionStart line into wv hook dispatch); the
    # diverged scripts/ copy it replaced is dropped (wv-5cfbc1).
    rm -f "$CONFIG_DIR/context-guard.sh" 2>/dev/null || true
    install_copy ./scripts/resolve-refs.sh "$CONFIG_DIR/"
    install_copy ./scripts/project-procedures.sh "$CONFIG_DIR/"
    install_copy ./scripts/gen-procedures.sh "$CONFIG_DIR/"
    # Lib available to hooks from global path (~/.config/weave/hooks/../lib/)
    install_copy ./scripts/lib/wv-resolve-project.sh "$CONFIG_DIR/lib/wv-resolve-project.sh"
    install_copy ./scripts/lib/wv-resolve-runtime.sh "$CONFIG_DIR/lib/wv-resolve-runtime.sh"
    install_copy ./scripts/lib/wv-validate.sh "$CONFIG_DIR/lib/wv-validate.sh"
    install_copy ./scripts/lib/wv-config.sh "$CONFIG_DIR/lib/wv-config.sh"
    install_copy ./scripts/lib/wv-workflow-classes.gen.sh "$CONFIG_DIR/lib/wv-workflow-classes.gen.sh"
    install_copy ./scripts/lib/wv-violation-vocabulary.gen.sh "$CONFIG_DIR/lib/wv-violation-vocabulary.gen.sh"
    install_copy ./scripts/lib/wv-hook-common.sh "$CONFIG_DIR/lib/wv-hook-common.sh"
    install_copy ./scripts/lib/wv-hook-observe.sh "$CONFIG_DIR/lib/wv-hook-observe.sh"
    install_copy ./scripts/lib/wv-pre-tool-use.sh "$CONFIG_DIR/lib/wv-pre-tool-use.sh"
    install_copy ./scripts/lib/wv-post-tool-use.sh "$CONFIG_DIR/lib/wv-post-tool-use.sh"
    install_copy ./scripts/lib/wv-attribution.sh "$CONFIG_DIR/lib/wv-attribution.sh"
    install_copy ./scripts/lib/wv-lifecycle-end.sh "$CONFIG_DIR/lib/wv-lifecycle-end.sh"
    install_copy ./scripts/lib/wv-policy-rules.sh "$CONFIG_DIR/lib/wv-policy-rules.sh"
    install_copy ./scripts/lib/wv-checkpoint-ci.sh "$CONFIG_DIR/lib/wv-checkpoint-ci.sh"
    install_copy ./scripts/lib/wv-shell-scope.sh "$CONFIG_DIR/lib/wv-shell-scope.sh"
    install_copy ./scripts/lib/wv-scratch.sh "$CONFIG_DIR/lib/wv-scratch.sh"
    install_copy ./scripts/lib/wv-repository-class.sh "$CONFIG_DIR/lib/wv-repository-class.sh"
    # Claude hooks (all 9 — registered globally via ~/.claude/settings.json under Alt-A)
    install_copy ./.claude/hooks/context-guard.sh "$CONFIG_DIR/hooks/"
    install_copy ./.claude/hooks/session-start-context.sh "$CONFIG_DIR/hooks/"
    install_copy ./.claude/hooks/session-end-sync.sh "$CONFIG_DIR/hooks/"
    install_copy ./.claude/hooks/stop-check.sh "$CONFIG_DIR/hooks/"
    install_copy ./.claude/hooks/post-edit-lint.sh "$CONFIG_DIR/hooks/"
    install_copy ./.claude/hooks/pre-compact-context.sh "$CONFIG_DIR/hooks/"
    install_copy ./.claude/hooks/pre-action.sh "$CONFIG_DIR/hooks/"
    install_copy ./.claude/hooks/pre-claim-skills.sh "$CONFIG_DIR/hooks/"
    install_copy ./.claude/hooks/pre-close-verification.sh "$CONFIG_DIR/hooks/"
    install_copy ./.claude/hooks/bash-dedup.sh "$CONFIG_DIR/hooks/"
    install_copy ./.claude/hooks/bash-dedup-post.sh "$CONFIG_DIR/hooks/"
    install_copy ./.claude/hooks/wv-budget-tally.sh "$CONFIG_DIR/hooks/"
    install_copy ./.claude/hooks/wv-touched-files.sh "$CONFIG_DIR/hooks/"
    install_copy ./.claude/hooks/post-memory-capture.sh "$CONFIG_DIR/hooks/"
    # Agents
    install_copy ./.claude/agents/weave-guide.md "$CONFIG_DIR/agents/"
    install_copy ./.claude/agents/epic-planner.md "$CONFIG_DIR/agents/"
    install_copy ./.claude/agents/learning-curator.md "$CONFIG_DIR/agents/"
    # Skills
    for _wv_sk in "${WV_CONFIG_SKILLS[@]}"; do
        install_copy "./.claude/skills/$_wv_sk/SKILL.md" "$CONFIG_DIR/skills/$_wv_sk/"
    done
    install_copy ./.claude/skills/weave-audit/audit-report.sh "$CONFIG_DIR/skills/weave-audit/"
    # CLAUDE.md template (generic, not project-specific)
    install_copy ./templates/CLAUDE.md.template "$CONFIG_DIR/CLAUDE.md.template"
    # Workflow reference (compact wv cheatsheet for new repos)
    install_copy ./templates/WORKFLOW.md "$CONFIG_DIR/WORKFLOW.md"
    # Plan template for wv plan --template
    install_copy ./templates/PLAN.md.template "$CONFIG_DIR/PLAN.md.template" 2>/dev/null || true
    # Topology enrichment spec template for wv enrich-topology
    install_copy ./templates/TOPOLOGY-ENRICH.json.template "$CONFIG_DIR/TOPOLOGY-ENRICH.json.template" 2>/dev/null || true
    # Makefile template for wv-init-repo
    install_copy ./templates/Makefile.template "$CONFIG_DIR/Makefile.template" 2>/dev/null || true
    # Fast impact-scoped test runner template + CI paths-ignore snippet for wv-init-repo
    install_copy ./templates/test-impacted.sh.template "$CONFIG_DIR/test-impacted.sh.template" 2>/dev/null || true
    install_copy ./templates/ci-weave-paths-ignore.snippet.yml "$CONFIG_DIR/ci-weave-paths-ignore.snippet.yml" 2>/dev/null || true
    install_copy ./templates/copilot-instructions.stub.md "$CONFIG_DIR/copilot-instructions.stub.md" 2>/dev/null || true
    # Authoring templates: what a consumer needs to WRITE a guide (and, as the
    # manifest grows, the other classes it may author) rather than only receive
    # one. Copied whole; wv-init-repo reads manifest.conf to place them.
    if [ -d ./templates/authoring ]; then
        rm -rf "$CONFIG_DIR/authoring"
        mkdir -p "$CONFIG_DIR/authoring"
        cp -a ./templates/authoring/. "$CONFIG_DIR/authoring/" 2>/dev/null || true
    fi
    # AGENTS.md template (generic, not project-specific)
    install_copy ./templates/AGENTS.md.template "$CONFIG_DIR/AGENTS.md.template" 2>/dev/null || true
else
    echo -e "${YELLOW}Downloading from GitHub...${NC}"
    REPO="https://raw.githubusercontent.com/AGM1968/weave/main"
    # CLI entry point
    download_file "$REPO/scripts/wv" "$INSTALL_DIR/wv"
    download_file "$REPO/scripts/wv-test" "$INSTALL_DIR/wv-test"
    # Library modules (XDG: ~/.local/lib/weave/lib/)
    download_file "$REPO/scripts/lib/wv-config.sh" "$LIB_DIR/lib/wv-config.sh"
    download_file "$REPO/scripts/lib/wv-db.sh" "$LIB_DIR/lib/wv-db.sh"
    download_file "$REPO/scripts/lib/wv-db-lineage.sh" "$LIB_DIR/lib/wv-db-lineage.sh"
    download_file "$REPO/scripts/lib/wv-validate.sh" "$LIB_DIR/lib/wv-validate.sh"
    download_file "$REPO/scripts/lib/wv-cache.sh" "$LIB_DIR/lib/wv-cache.sh"
    download_file "$REPO/scripts/lib/wv-command-capabilities.sh" "$LIB_DIR/lib/wv-command-capabilities.sh"
    download_file "$REPO/scripts/lib/wv-policy-rules.sh" "$LIB_DIR/lib/wv-policy-rules.sh"
    download_file "$REPO/scripts/lib/wv-journal.sh" "$LIB_DIR/lib/wv-journal.sh"
    download_file "$REPO/scripts/lib/wv-attempt-journal.sh" "$LIB_DIR/lib/wv-attempt-journal.sh"
    download_file "$REPO/scripts/lib/wv-gh.sh" "$LIB_DIR/lib/wv-gh.sh"
    download_file "$REPO/scripts/lib/wv-delta.sh" "$LIB_DIR/lib/wv-delta.sh"
    download_file "$REPO/scripts/lib/wv-delta-catalog.sh" "$LIB_DIR/lib/wv-delta-catalog.sh"
    download_file "$REPO/scripts/lib/wv-compact-pre-cutover.sh" "$LIB_DIR/lib/wv-compact-pre-cutover.sh"
    download_file "$REPO/scripts/lib/wv-delta-v2-replay.py" "$LIB_DIR/lib/wv-delta-v2-replay.py"
    download_file "$REPO/scripts/lib/wv-load-ack.py" "$LIB_DIR/lib/wv-load-ack.py"
    download_file "$REPO/scripts/lib/wv-clone-roster.py" "$LIB_DIR/lib/wv-clone-roster.py"
    download_file "$REPO/scripts/lib/wv-checkpoint-generation.sh" "$LIB_DIR/lib/wv-checkpoint-generation.sh"
    download_file "$REPO/scripts/lib/wv-checkpoint-ci.sh" "$LIB_DIR/lib/wv-checkpoint-ci.sh"
    download_file "$REPO/scripts/lib/wv-shell-scope.sh" "$LIB_DIR/lib/wv-shell-scope.sh"
    download_file "$REPO/scripts/lib/wv-scratch.sh" "$LIB_DIR/lib/wv-scratch.sh"
    download_file "$REPO/scripts/lib/wv-gate-pool.sh" "$LIB_DIR/lib/wv-gate-pool.sh"
    download_file "$REPO/scripts/lib/wv-gate-supervisor.py" "$LIB_DIR/lib/wv-gate-supervisor.py"
    download_file "$REPO/scripts/lib/wv-gate-suite.py" "$LIB_DIR/lib/wv-gate-suite.py"
    download_file "$REPO/scripts/lib/wv-gate-provision.json" "$LIB_DIR/lib/wv-gate-provision.json"
    download_file "$REPO/scripts/lib/wv-gate-paths.py" "$LIB_DIR/lib/wv-gate-paths.py"
    download_file "$REPO/scripts/lib/wv-gate-propose.py" "$LIB_DIR/lib/wv-gate-propose.py"
    download_file "$REPO/scripts/lib/wv-gate-snapshot.sh" "$LIB_DIR/lib/wv-gate-snapshot.sh"
    download_file "$REPO/scripts/lib/wv-gate-lanes.sh" "$LIB_DIR/lib/wv-gate-lanes.sh"
    download_file "$REPO/scripts/lib/wv-gate-hold.sh" "$LIB_DIR/lib/wv-gate-hold.sh"
    download_file "$REPO/scripts/lib/wv-repository-class.sh" "$LIB_DIR/lib/wv-repository-class.sh"
    download_file "$REPO/scripts/lib/wv-git-hook-signature.sh" "$LIB_DIR/lib/wv-git-hook-signature.sh"
    download_file "$REPO/scripts/lib/wv-runtime-ignores.sh" "$LIB_DIR/lib/wv-runtime-ignores.sh"
    download_file "$REPO/scripts/lib/wv-workflow-classes.gen.sh" "$LIB_DIR/lib/wv-workflow-classes.gen.sh"
    download_file "$REPO/scripts/lib/wv-violation-vocabulary.gen.sh" "$LIB_DIR/lib/wv-violation-vocabulary.gen.sh"
    download_file "$REPO/scripts/lib/wv-hook-common.sh" "$LIB_DIR/lib/wv-hook-common.sh"
    download_file "$REPO/scripts/lib/wv-hook-observe.sh" "$LIB_DIR/lib/wv-hook-observe.sh"
    download_file "$REPO/scripts/lib/wv-pre-tool-use.sh" "$LIB_DIR/lib/wv-pre-tool-use.sh"
    download_file "$REPO/scripts/lib/wv-post-tool-use.sh" "$LIB_DIR/lib/wv-post-tool-use.sh"
    download_file "$REPO/scripts/lib/wv-attribution.sh" "$LIB_DIR/lib/wv-attribution.sh"
    download_file "$REPO/scripts/lib/wv-lifecycle-end.sh" "$LIB_DIR/lib/wv-lifecycle-end.sh"
    download_file "$REPO/scripts/lib/wv-session-start.sh" "$LIB_DIR/lib/wv-session-start.sh"
    download_file "$REPO/scripts/lib/wv-resolve-project.sh" "$LIB_DIR/lib/wv-resolve-project.sh"
    download_file "$REPO/scripts/lib/wv-resolve-runtime.sh" "$LIB_DIR/lib/wv-resolve-runtime.sh"
    download_file "$REPO/scripts/lib/wv-graph-diff.sh" "$LIB_DIR/lib/wv-graph-diff.sh"
    download_file "$REPO/scripts/lib/VERSION" "$LIB_DIR/lib/VERSION"
    # A remote install has no source checkout, but it must still record WHAT it
    # installed -- otherwise doctor's "not recorded" warning can never be
    # cleared by the reinstall it recommends, which makes the advice useless.
    # source=remote is the honest answer to "which commit": unknown, from $REPO.
    {
        echo "installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "source_path=remote:$REPO"
        echo "commit=unknown"
        echo "describe=remote-$(cat "$LIB_DIR/lib/VERSION" 2>/dev/null | tr -d '[:space:]')"
        echo "branch=unknown"
        echo "dirty=unknown"
    } > "$LIB_DIR/lib/INSTALL_PROVENANCE" 2>/dev/null || true
    # Command modules (XDG: ~/.local/lib/weave/cmd/)
    download_file "$REPO/scripts/cmd/wv-cmd-core.sh" "$LIB_DIR/cmd/wv-cmd-core.sh"
    download_file "$REPO/scripts/cmd/wv-cmd-graph.sh" "$LIB_DIR/cmd/wv-cmd-graph.sh"
    download_file "$REPO/scripts/cmd/wv-cmd-data.sh" "$LIB_DIR/cmd/wv-cmd-data.sh"
    download_file "$REPO/scripts/cmd/wv-cmd-ops.sh" "$LIB_DIR/cmd/wv-cmd-ops.sh"
    download_file "$REPO/scripts/cmd/wv-cmd-doctor.sh" "$LIB_DIR/cmd/wv-cmd-doctor.sh"
    download_file "$REPO/scripts/cmd/wv-cmd-health.sh" "$LIB_DIR/cmd/wv-cmd-health.sh"
    download_file "$REPO/scripts/cmd/wv-cmd-help.sh" "$LIB_DIR/cmd/wv-cmd-help.sh"
    download_file "$REPO/scripts/cmd/wv-cmd-orient.sh" "$LIB_DIR/cmd/wv-cmd-orient.sh"
    download_file "$REPO/scripts/cmd/wv-cmd-gate.sh" "$LIB_DIR/cmd/wv-cmd-gate.sh"
    download_file "$REPO/scripts/cmd/wv-cmd-python.sh" "$LIB_DIR/cmd/wv-cmd-python.sh"
    download_file "$REPO/scripts/cmd/wv-cmd-hotzone.sh" "$LIB_DIR/cmd/wv-cmd-hotzone.sh"
    download_file "$REPO/scripts/cmd/wv-cmd-gitstate.sh" "$LIB_DIR/cmd/wv-cmd-gitstate.sh"
    download_file "$REPO/scripts/cmd/wv-cmd-procedures.sh" "$LIB_DIR/cmd/wv-cmd-procedures.sh"
    download_file "$REPO/scripts/cmd/wv-cmd-graduate.sh" "$LIB_DIR/cmd/wv-cmd-graduate.sh"
    download_file "$REPO/scripts/cmd/wv-cmd-recover.sh" "$LIB_DIR/cmd/wv-cmd-recover.sh"
    download_file "$REPO/scripts/cmd/wv-cmd-quality.sh" "$LIB_DIR/cmd/wv-cmd-quality.sh"
    download_file "$REPO/scripts/cmd/wv-cmd-findings.sh" "$LIB_DIR/cmd/wv-cmd-findings.sh"
    download_file "$REPO/scripts/cmd/wv-cmd-analyze.sh" "$LIB_DIR/cmd/wv-cmd-analyze.sh"
    download_file "$REPO/scripts/cmd/wv-cmd-indexer.sh" "$LIB_DIR/cmd/wv-cmd-indexer.sh"
    download_file "$REPO/scripts/cmd/wv-cmd-query.sh" "$LIB_DIR/cmd/wv-cmd-query.sh"
    download_file "$REPO/scripts/cmd/wv-cmd-hook.sh" "$LIB_DIR/cmd/wv-cmd-hook.sh"
    download_file "$REPO/profiling/audit_sessions.py" "$LIB_DIR/profiling/audit_sessions.py"
    download_file "$REPO/profiling/checkpoint_overlap.py" "$LIB_DIR/profiling/checkpoint_overlap.py"
    # Git hook sources (used by wv-init-repo --update refresh)
    mkdir -p "$LIB_DIR/hooks"
    download_file "$REPO/scripts/hooks/pre-commit-weave.sh" "$LIB_DIR/hooks/pre-commit-weave.sh"
    rm -f "$LIB_DIR/hooks/post-commit-weave.sh" 2>/dev/null || true   # retired (wv-56c823)
    download_file "$REPO/scripts/hooks/prepare-commit-msg-weave.sh" "$LIB_DIR/hooks/prepare-commit-msg-weave.sh"
    download_file "$REPO/scripts/hooks/pre-push-weave.sh" "$LIB_DIR/hooks/pre-push-weave.sh"
    download_file "$REPO/scripts/hooks/reference-transaction-weave.sh" "$LIB_DIR/hooks/reference-transaction-weave.sh"
    # Python sync package (auto-discover modules from GitHub API)
    mkdir -p "$LIB_DIR/weave_gh"
    local py_modules
    py_modules=$(curl -sSL "https://api.github.com/repos/AGM1968/weave/contents/scripts/weave_gh?ref=main" \
        | jq -r '.[] | select(.name | endswith(".py")) | .name' 2>/dev/null)
    if [ -z "$py_modules" ]; then
        # Fallback: hardcoded list if API is unavailable (rate-limited, offline)
        py_modules="__init__.py models.py cli.py data.py rendering.py labels.py body.py phases.py notify.py digest_cache.py repair_checkpoint.py __main__.py"
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
        # Fallback for an unavailable/rate-limited API. Kept in exact-set parity
        # with scripts/weave_quality/*.py by tests/test-install-asset-parity.sh:
        # a module missing here installs a package that imports and then fails at
        # runtime, and this list had already drifted twice before that check
        # existed.
        quality_modules="__init__.py __main__.py ast_cache.py bash_ast_grep.py bash_heuristic.py classification.py coaching_apply.py coaching_evidence.py db.py external_tools.py findings.py git_metrics.py guides.py hotspots.py listing.py models.py pattern_loader.py prose_rules.py prose_shape.py python_parser.py typescript_parser.py"
    fi
    for pyfile in $quality_modules; do
        download_file "$REPO/scripts/weave_quality/${pyfile}" "$LIB_DIR/weave_quality/${pyfile}"
    done
    # Quality rules directory
    mkdir -p "$LIB_DIR/weave_quality/rules"
    for rule_file in bash_cc typescript_cc typescript_functions; do
        download_file "$REPO/scripts/weave_quality/rules/${rule_file}.yaml" \
            "$LIB_DIR/weave_quality/rules/${rule_file}.yaml"
    done
    # Default pattern rules
    mkdir -p "$LIB_DIR/weave_quality/default_patterns"
    # Retired defaults moved into memory-system's own .weave/patterns:
    # live-db-file-operation and lookup-skips-beside-self (wv-6d72de),
    # git-listing-rename-blind and sqlite-dot-command-swallows-sql (wv-ca97ce).
    rm -f "$LIB_DIR/weave_quality/default_patterns/prose-casual-register.yaml" \
        "$LIB_DIR/weave_quality/default_patterns/prose-number-free-verification.yaml" \
        "$LIB_DIR/weave_quality/default_patterns/live-db-file-operation.yaml" \
        "$LIB_DIR/weave_quality/default_patterns/lookup-skips-beside-self.yaml" \
        "$LIB_DIR/weave_quality/default_patterns/git-listing-rename-blind.yaml" \
        "$LIB_DIR/weave_quality/default_patterns/sqlite-dot-command-swallows-sql.yaml" \
        "$LIB_DIR/weave_quality/guides/live-db-file-operation.md" \
        "$LIB_DIR/weave_quality/guides/rename-blind-listing.md" \
        "$LIB_DIR/weave_quality/guides/swallowed-sql.md"
    for pattern_rule in subprocess-shell-true bare-except-pass unquoted-variable prose-register-review prose-emphasis-hedge listing-glob-fails-open; do
        download_file "$REPO/scripts/weave_quality/default_patterns/${pattern_rule}.yaml" \
            "$LIB_DIR/weave_quality/default_patterns/${pattern_rule}.yaml"
    done
    download_file "$REPO/scripts/weave_quality/default_patterns/manifest.json" \
        "$LIB_DIR/weave_quality/default_patterns/manifest.json"
    # Coaching guide assets. Enumerated non-recursively, like the modules above,
    # which is why the guides directory must stay flat.
    mkdir -p "$LIB_DIR/weave_quality/guides"
    local coaching_guides
    coaching_guides=$(curl -sSL "https://api.github.com/repos/AGM1968/weave/contents/scripts/weave_quality/guides?ref=main" \
        | jq -r '.[] | select(.name | endswith(".md")) | .name' 2>/dev/null)
    if [ -z "$coaching_guides" ]; then
        coaching_guides="_clean.md _incomplete.md _uncoached.md register.md swallowed-exception.md swallowed-exception.python.md vacuous-verification.md unsafe-subprocess.md unquoted-expansion.md generated-vocabulary.md filler.md unearned-significance.md self-attested-virtue.md work-context-leakage.md punctuation-density.md malformed-markup.md citation-integrity.md metadata-formatting.md design-flaw.md"
    fi
    for guide_file in $coaching_guides; do
        download_file "$REPO/scripts/weave_quality/guides/${guide_file}" \
            "$LIB_DIR/weave_quality/guides/${guide_file}"
    done
    # Pure coaching package
    mkdir -p "$LIB_DIR/weave_coaching"
    local coaching_modules
    coaching_modules=$(curl -sSL "https://api.github.com/repos/AGM1968/weave/contents/scripts/weave_coaching?ref=main" \
        | jq -r '.[] | select(.name | endswith(".py")) | .name' 2>/dev/null)
    if [ -z "$coaching_modules" ]; then
        coaching_modules="__init__.py planner.py view.py"
    fi
    for coaching_file in $coaching_modules; do
        download_file "$REPO/scripts/weave_coaching/${coaching_file}" \
            "$LIB_DIR/weave_coaching/${coaching_file}"
    done
    # Machine-readable contracts the runtime reads
    mkdir -p "$LIB_DIR/contracts"
    for contract_file in violation-vocabulary-v1.json coaching-promotion-v1.schema.json \
        coaching-response-v1.schema.json coaching-guide-v1.schema.json; do
        download_file "$REPO/contracts/${contract_file}" "$LIB_DIR/contracts/${contract_file}"
    done
    # The MCP contract, on the same terms as the local path above.
    mkdir -p "$LIB_DIR/mcp"
    download_file "$REPO/mcp/contract.json" "$LIB_DIR/mcp/contract.json"
    # Python indexer package
    mkdir -p "$LIB_DIR/weave_indexer"
    download_file "$REPO/scripts/weave_indexer/__init__.py" "$LIB_DIR/weave_indexer/__init__.py"
    download_file "$REPO/scripts/weave_indexer/__main__.py" "$LIB_DIR/weave_indexer/__main__.py"
    download_file "$REPO/scripts/weave_indexer/symbols.py" "$LIB_DIR/weave_indexer/symbols.py"
    # Python search package
    mkdir -p "$LIB_DIR/weave_search"
    download_file "$REPO/scripts/weave_search/__init__.py" "$LIB_DIR/weave_search/__init__.py"
    download_file "$REPO/scripts/weave_search/__main__.py" "$LIB_DIR/weave_search/__main__.py"
    download_file "$REPO/scripts/weave_search/graph.py" "$LIB_DIR/weave_search/graph.py"
    download_file "$REPO/scripts/weave_search/definitions.py" "$LIB_DIR/weave_search/definitions.py"
    # Scripts
    rm -f "$CONFIG_DIR/context-guard.sh" 2>/dev/null || true   # one copy, under hooks/ (wv-5cfbc1)
    curl -sSL "$REPO/scripts/resolve-refs.sh" -o "$CONFIG_DIR/resolve-refs.sh"
    curl -sSL "$REPO/scripts/project-procedures.sh" -o "$CONFIG_DIR/project-procedures.sh"
    curl -sSL "$REPO/scripts/gen-procedures.sh" -o "$CONFIG_DIR/gen-procedures.sh"
    # Lib available to hooks from global path (~/.config/weave/hooks/../lib/)
    curl -sSL "$REPO/scripts/lib/wv-resolve-project.sh" -o "$CONFIG_DIR/lib/wv-resolve-project.sh"
    curl -sSL "$REPO/scripts/lib/wv-resolve-runtime.sh" -o "$CONFIG_DIR/lib/wv-resolve-runtime.sh"
    curl -sSL "$REPO/scripts/lib/wv-validate.sh" -o "$CONFIG_DIR/lib/wv-validate.sh"
    curl -sSL "$REPO/scripts/lib/wv-config.sh" -o "$CONFIG_DIR/lib/wv-config.sh"
    # Must land before wv-hook-common.sh sources it; absent here, hooks silently disable classification.
    curl -sSL "$REPO/scripts/lib/wv-workflow-classes.gen.sh" -o "$CONFIG_DIR/lib/wv-workflow-classes.gen.sh"
    curl -sSL "$REPO/scripts/lib/wv-hook-common.sh" -o "$CONFIG_DIR/lib/wv-hook-common.sh"
    curl -sSL "$REPO/scripts/lib/wv-hook-observe.sh" -o "$CONFIG_DIR/lib/wv-hook-observe.sh"
    curl -sSL "$REPO/scripts/lib/wv-pre-tool-use.sh" -o "$CONFIG_DIR/lib/wv-pre-tool-use.sh"
    curl -sSL "$REPO/scripts/lib/wv-post-tool-use.sh" -o "$CONFIG_DIR/lib/wv-post-tool-use.sh"
    curl -sSL "$REPO/scripts/lib/wv-attribution.sh" -o "$CONFIG_DIR/lib/wv-attribution.sh"
    curl -sSL "$REPO/scripts/lib/wv-lifecycle-end.sh" -o "$CONFIG_DIR/lib/wv-lifecycle-end.sh"
    curl -sSL "$REPO/scripts/lib/wv-policy-rules.sh" -o "$CONFIG_DIR/lib/wv-policy-rules.sh"
    curl -sSL "$REPO/scripts/lib/wv-checkpoint-ci.sh" -o "$CONFIG_DIR/lib/wv-checkpoint-ci.sh"
    curl -sSL "$REPO/scripts/lib/wv-shell-scope.sh" -o "$CONFIG_DIR/lib/wv-shell-scope.sh"
    curl -sSL "$REPO/scripts/lib/wv-scratch.sh" -o "$CONFIG_DIR/lib/wv-scratch.sh"
    curl -sSL "$REPO/scripts/lib/wv-repository-class.sh" -o "$CONFIG_DIR/lib/wv-repository-class.sh"
    # Claude hooks
    curl -sSL "$REPO/.claude/hooks/context-guard.sh" -o "$CONFIG_DIR/hooks/context-guard.sh"
    curl -sSL "$REPO/.claude/hooks/session-start-context.sh" -o "$CONFIG_DIR/hooks/session-start-context.sh"
    curl -sSL "$REPO/.claude/hooks/session-end-sync.sh" -o "$CONFIG_DIR/hooks/session-end-sync.sh"
    curl -sSL "$REPO/.claude/hooks/stop-check.sh" -o "$CONFIG_DIR/hooks/stop-check.sh"
    curl -sSL "$REPO/.claude/hooks/post-edit-lint.sh" -o "$CONFIG_DIR/hooks/post-edit-lint.sh"
    curl -sSL "$REPO/.claude/hooks/pre-compact-context.sh" -o "$CONFIG_DIR/hooks/pre-compact-context.sh"
    curl -sSL "$REPO/.claude/hooks/pre-action.sh" -o "$CONFIG_DIR/hooks/pre-action.sh"
    curl -sSL "$REPO/.claude/hooks/pre-claim-skills.sh" -o "$CONFIG_DIR/hooks/pre-claim-skills.sh"
    curl -sSL "$REPO/.claude/hooks/pre-close-verification.sh" -o "$CONFIG_DIR/hooks/pre-close-verification.sh"
    curl -sSL "$REPO/.claude/hooks/bash-dedup.sh" -o "$CONFIG_DIR/hooks/bash-dedup.sh"
    curl -sSL "$REPO/.claude/hooks/bash-dedup-post.sh" -o "$CONFIG_DIR/hooks/bash-dedup-post.sh"
    curl -sSL "$REPO/.claude/hooks/wv-budget-tally.sh" -o "$CONFIG_DIR/hooks/wv-budget-tally.sh"
    curl -sSL "$REPO/.claude/hooks/wv-touched-files.sh" -o "$CONFIG_DIR/hooks/wv-touched-files.sh"
    curl -sSL "$REPO/.claude/hooks/post-memory-capture.sh" -o "$CONFIG_DIR/hooks/post-memory-capture.sh"
    # Agents
    curl -sSL "$REPO/.claude/agents/weave-guide.md" -o "$CONFIG_DIR/agents/weave-guide.md"
    curl -sSL "$REPO/.claude/agents/epic-planner.md" -o "$CONFIG_DIR/agents/epic-planner.md"
    curl -sSL "$REPO/.claude/agents/learning-curator.md" -o "$CONFIG_DIR/agents/learning-curator.md"
    # Skills
    for _wv_sk in "${WV_CONFIG_SKILLS[@]}"; do
        curl -sSL "$REPO/.claude/skills/$_wv_sk/SKILL.md" -o "$CONFIG_DIR/skills/$_wv_sk/SKILL.md"
    done
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
    # Fast impact-scoped test runner template + CI paths-ignore snippet for wv-init-repo
    curl -sSL "$REPO/templates/test-impacted.sh.template" -o "$CONFIG_DIR/test-impacted.sh.template" 2>/dev/null || true
    curl -sSL "$REPO/templates/ci-weave-paths-ignore.snippet.yml" -o "$CONFIG_DIR/ci-weave-paths-ignore.snippet.yml" 2>/dev/null || true
    curl -sSL "$REPO/templates/copilot-instructions.stub.md" -o "$CONFIG_DIR/copilot-instructions.stub.md" 2>/dev/null || true
    # Authoring templates. The manifest is fetched first and then enumerates the
    # rest: a hardcoded fallback list here is the drift install-asset-parity.py
    # exists to catch, and a manifest that lists a file it did not fetch would
    # seed a consumer with a dangling row.
    mkdir -p "$CONFIG_DIR/authoring"
    if curl -fsSL "$REPO/templates/authoring/manifest.conf" \
        -o "$CONFIG_DIR/authoring/manifest.conf" 2>/dev/null; then
        while IFS='|' read -r _authoring_src _authoring_rest; do
            case "$_authoring_src" in ""|\#*) continue ;; esac
            [ -n "$_authoring_rest" ] || continue
            mkdir -p "$CONFIG_DIR/authoring/$(dirname "$_authoring_src")"
            curl -sSL "$REPO/templates/authoring/$_authoring_src" \
                -o "$CONFIG_DIR/authoring/$_authoring_src" 2>/dev/null || true
        done < "$CONFIG_DIR/authoring/manifest.conf"
    fi
    # AGENTS.md template (generic, not project-specific)
    curl -sSL "$REPO/templates/AGENTS.md.template" -o "$CONFIG_DIR/AGENTS.md.template" 2>/dev/null || true
fi

# Prune CONFIG_DIR skills install.sh placed before and no longer ships
# (wv-f4a68b); left alone they stayed resident forever. Only names install.sh
# itself recorded are candidates, so a hand-written skill, or one another tool
# placed, is never touched, and a procedure-projected skill (it carries the
# WEAVE-MANAGED-SKILL marker) is kept even if listed. A CONFIG_DIR older than
# the manifest is seeded with the skills retired before the manifest existed.
_wv_sk_manifest="$CONFIG_DIR/skills/.weave-installed"
if [ -f "$_wv_sk_manifest" ]; then
    _wv_sk_prev=$(cat "$_wv_sk_manifest")
else
    _wv_sk_prev="breadcrumbs epic-breakdown prove-it rubber-duck stay-in-lane unstuck"
fi
for _wv_sk in $_wv_sk_prev; do
    [[ "$_wv_sk" =~ ^[a-z0-9-]+$ ]] || continue
    case " ${WV_CONFIG_SKILLS[*]} " in *" $_wv_sk "*) continue ;; esac
    [ -d "$CONFIG_DIR/skills/$_wv_sk" ] || continue
    grep -qF 'WEAVE-MANAGED-SKILL' "$CONFIG_DIR/skills/$_wv_sk/SKILL.md" 2>/dev/null && continue
    rm -rf "${CONFIG_DIR:?}/skills/${_wv_sk:?}"
    echo -e "  ${GREEN}✓${NC} skills/$_wv_sk (no longer shipped, removed)"
done
printf '%s\n' "${WV_CONFIG_SKILLS[@]}" > "$_wv_sk_manifest"

chmod +x "$INSTALL_DIR/wv"
chmod +x "$INSTALL_DIR/wv-test"
chmod +x "$CONFIG_DIR/resolve-refs.sh"
chmod +x "$CONFIG_DIR/project-procedures.sh"
chmod +x "$CONFIG_DIR/gen-procedures.sh"
chmod +x "$CONFIG_DIR/hooks/"*.sh
chmod +x "$CONFIG_DIR/skills/weave-audit/audit-report.sh"
install_procedure_assets
install_pattern_assets

# Alt-A: Register all hooks globally in ~/.claude/settings.json
# Per-project settings.json should have NO hooks key (it would shadow global hooks)
merge_global_claude_settings() {
    local global_settings="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
    local hooks_dir="$CONFIG_DIR/hooks"

    mkdir -p "$(dirname "$global_settings")"

    # Backup before modifying
    if [ -f "$global_settings" ]; then
        cp "$global_settings" "${global_settings}.bak"
    fi

    # Build the complete hooks block with absolute paths (no $HOME — doesn't expand in Claude Code)
    # SessionEnd carries an explicit timeout: Claude Code gives SessionEnd hooks
    # a shared 1.5 s budget unless a hook sets a longer one (up to 60 s), and
    # cut the session-end routine off on every exit from 2026-03 (wv-a32e69).
    # Every hook carries an explicit timeout (host hook contract, wv-0f70b5):
    # tests/test-init-repo.sh refuses one without, and wv doctor --agent reports
    # them. SessionStart measured ~34 s on a large graph (2026-11-06, wv-b16af6).
    local hooks_json
    hooks_json=$(jq -n \
        --arg h "$hooks_dir" \
        '{
            "SessionStart": [{"matcher":"","hooks":[
                {"type":"command","command":($h+"/session-start-context.sh"),"timeout":120}
            ]}],
            "PreCompact": [{"matcher":"","hooks":[
                {"type":"command","command":($h+"/pre-compact-context.sh"),"timeout":30}
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
                ]},
                {"matcher":"Bash","hooks":[
                    {"type":"command","command":($h+"/bash-dedup.sh"),"timeout":5}
                ]}
            ],
            "PostToolUse": [
                {"matcher":"Edit|Write|create_file|replace_string_in_file|insert_edit_into_file|multi_replace_string_in_file","hooks":[
                    {"type":"command","command":($h+"/post-edit-lint.sh"),"timeout":30}
                ]},
                {"matcher":"Bash","hooks":[
                    {"type":"command","command":($h+"/bash-dedup-post.sh"),"timeout":5}
                ]},
                {"matcher":"Bash","hooks":[
                    {"type":"command","command":($h+"/wv-budget-tally.sh"),"timeout":5}
                ]},
                {"matcher":"Edit|Write|NotebookEdit|create_file|replace_string_in_file|insert_edit_into_file|multi_replace_string_in_file","hooks":[
                    {"type":"command","command":($h+"/wv-touched-files.sh"),"timeout":5}
                ]},
                {"matcher":"Edit|Write|NotebookEdit","hooks":[
                    {"type":"command","command":($h+"/post-memory-capture.sh"),"timeout":10}
                ]}
            ],
            "PostToolUseFailure": [
                {"matcher":"Bash","hooks":[
                    {"type":"command","command":($h+"/bash-dedup-post.sh"),"timeout":5}
                ]}
            ],
            "Stop": [{"matcher":"","hooks":[
                {"type":"command","command":($h+"/stop-check.sh"),"timeout":30}
            ]}],
            "SessionEnd": [{"matcher":"","hooks":[
                {"type":"command","command":($h+"/session-end-sync.sh"),"timeout":30}
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
#   wv-init-repo --agent=codex   # Codex setup contract
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
CODEX_MCP_SCOPE=""
CODEX_HOOKS=0
REPOSITORY_CLASS_ARG=""
ACKNOWLEDGE_UPSTREAM_FORK=0
for arg in "$@"; do
    case "$arg" in
        --agent=*) AGENT_ARG="${arg#--agent=}" ;;
        --update) UPDATE_MODE=1 ;;
        --force) UPDATE_MODE=1; FORCE_MODE=1 ;;
        --codex-hooks) CODEX_HOOKS=1 ;;
        --codex-mcp) CODEX_MCP_SCOPE="lite" ;;
        --codex-mcp=lite|--codex-mcp=inspect|--codex-mcp=full) CODEX_MCP_SCOPE="${arg#--codex-mcp=}" ;;
        --repository-class=*) REPOSITORY_CLASS_ARG="${arg#--repository-class=}" ;;
        --acknowledge-upstream-fork) ACKNOWLEDGE_UPSTREAM_FORK=1 ;;
        --help|-h)
            echo "Usage: wv-init-repo [--agent=claude|copilot|codex|all] [--update] [--force] [--repository-class=owned|vendored-upstream] [--acknowledge-upstream-fork] [--codex-hooks] [--codex-mcp[=lite|inspect|full]]"
            echo ""
            echo "  claude   (default) Claude Code hooks, skills, settings.local.json"
            echo "  copilot  VS Code Copilot MCP config (.vscode/mcp.json + legacy .mcp.json) + copilot-instructions.md"
            echo "  codex    Codex setup contract (.codex/weave.json); AGENTS.md remains universal"
            echo "  all      Claude Code, VS Code Copilot, and Codex"
            echo ""
            echo "  --update  Update managed files (hooks, skills, agents, copilot-instructions)"
            echo "            Preserves user-customized files (CLAUDE.md, settings.local.json, MCP config)"
            echo "  --force   Like --update but also rewrites MCP config files (.vscode/mcp.json, .mcp.json)"
            echo "  --repository-class=CLASS  Persist clone-local owned or vendored-upstream classification"
            echo "  --acknowledge-upstream-fork  Required to classify an unresolved or upstream repo as owned"
            echo "  --codex-hooks  Generate project lifecycle hooks for explicit review and trust"
            echo "  --codex-mcp  Register weave-lite in Codex global config (local/read-mostly scope)"
            echo "  --codex-mcp=inspect  Register read-only weave-inspect instead"
            echo "  --codex-mcp=full     Register full weave server explicitly"
            echo ""
            echo "  Comma-separated: --agent=claude,copilot,codex"
            exit 0
            ;;
        *) echo "wv-init-repo: unknown argument: $arg" >&2; exit 2 ;;
    esac
done

# Expand 'all' and parse comma-separated values
if [ "$AGENT_ARG" = "all" ]; then
    AGENTS=(claude copilot codex)
else
    IFS=',' read -ra AGENTS <<< "$AGENT_ARG"
fi

# Validate each agent
for agent in "${AGENTS[@]}"; do
    case "$agent" in
        claude|copilot|codex) ;;
        *)
            echo -e "${YELLOW}Unknown agent: $agent — skipping${NC}" >&2
            ;;
    esac
done

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

# On --update, list the repository's files before anything is written, so the
# summary can name what the update ADDED as against what it refreshed
# (wv-ef9ba9). .git is skipped; everything else counts, since managed files
# land under .claude/, .github/, .vscode/, .codex/, .weave/, scripts/ and the
# root.
_IR_FILES_BEFORE=""
if [ "$UPDATE_MODE" = "1" ]; then
    _IR_FILES_BEFORE=$(mktemp)
    (cd "$REPO_ROOT" && find . -path ./.git -prune -o -type f -print 2>/dev/null | sort) > "$_IR_FILES_BEFORE"
fi

# _wv_localize_agent_block — correct a managed agent block for THIS repo.
#
# The shipped templates describe a consumer: they set the PATH fallback to
# the installed wv and state the repo "does not vendor weave's own
# scripts/wv". In the weave source checkout both halves are false, and
# `wv init-repo --update` wrote them over accurate guidance -- pointing an
# agent at the installed binary while it edits the working tree, so it would
# test something other than what it changed. Applied to every rendered agent
# surface, not just CLAUDE.md, since they carry the same paragraph.
_wv_localize_agent_block() {
    if [ ! -x "$REPO_ROOT/scripts/wv" ] || [ ! -f "$REPO_ROOT/scripts/lib/wv-config.sh" ]; then
        printf '%s\n' "$1"
        return 0
    fi
    printf '%s\n' "$1" | awk '
        /^if ! command -v wv >\/dev\/null 2>&1; then wv\(\)/ {
            print "if ! command -v wv >/dev/null 2>&1; then wv() { ./scripts/wv \"$@\"; }; fi"
            print "# ./scripts/wv appends existing $HOME/.local/bin and $HOME/.cargo/bin for user tools;"
            print "# the Weave Makefile targets apply the same PATH fallback for sandbox shells."
            # Drop the template s own comment paragraph, however many lines
            # it runs to: CLAUDE.md.template uses three and the copilot stub
            # two, and a fixed count would swallow the first command line of
            # the shorter surface.
            skip = 1
            next
        }
        skip == 1 && /^#/ { next }
        skip == 1 { skip = 0 }
        { print }
    '
}

CONFIG_DIR="${WV_CONFIG_DIR:-$HOME/.config/weave}"
MCP_SERVER="${WV_LIB_DIR:-$HOME/.local/lib/weave}/mcp/dist/index.js"
WV_BIN_DIR=$(cd "$(dirname "$0")" && pwd)
WV_BIN="$WV_BIN_DIR/wv"

# _refresh_memory_projection <projection> <file> -- on --update, re-render the
# graph's memory index into a projection that already carries a WEAVE:MEMORY
# block, so an upgrade replaces the old full-text block with the index
# (wv-91f0ca). A file without the block is the user's, and is left alone.
_refresh_memory_projection() {
    local projection="$1" file="$2"
    [ "$UPDATE_MODE" = "1" ] && [ -x "$WV_BIN" ] && [ -f "$file" ] || return 0
    grep -qF -- '<!-- ── BEGIN WEAVE:MEMORY ──' "$file" || return 0
    if (cd "$REPO_ROOT" && "$WV_BIN" memory render --agent="$projection" --path="$file" >/dev/null 2>&1); then
        echo -e "  ${GREEN}✓${NC} ${file#"$REPO_ROOT"/} memory index (rendered from the graph)"
    else
        echo -e "  ${YELLOW}⚠${NC} ${file#"$REPO_ROOT"/} memory index not rendered - run: wv memory render --agent=$projection"
    fi
}
REPO_CLASS_LIB="${WV_LIB_DIR:-$HOME/.local/lib/weave}/lib/wv-repository-class.sh"
[ -f "$REPO_CLASS_LIB" ] || { echo "wv-init-repo: repository classification helper missing: $REPO_CLASS_LIB" >&2; exit 1; }
# shellcheck source=scripts/lib/wv-repository-class.sh
source "$REPO_CLASS_LIB"
HOOK_SIGNATURE_LIB="${WV_LIB_DIR:-$HOME/.local/lib/weave}/lib/wv-git-hook-signature.sh"
[ -f "$HOOK_SIGNATURE_LIB" ] || { echo "wv-init-repo: hook signature helper missing: $HOOK_SIGNATURE_LIB" >&2; exit 1; }
# shellcheck source=scripts/lib/wv-git-hook-signature.sh
source "$HOOK_SIGNATURE_LIB"
RUNTIME_IGNORES_LIB="${WV_LIB_DIR:-$HOME/.local/lib/weave}/lib/wv-runtime-ignores.sh"
[ -f "$RUNTIME_IGNORES_LIB" ] || { echo "wv-init-repo: runtime ignore list missing: $RUNTIME_IGNORES_LIB" >&2; exit 1; }
# shellcheck source=scripts/lib/wv-runtime-ignores.sh
source "$RUNTIME_IGNORES_LIB"
if [ -n "$REPOSITORY_CLASS_ARG" ]; then
    wv_repository_class_set "$REPO_ROOT" "$REPOSITORY_CLASS_ARG" "$ACKNOWLEDGE_UPSTREAM_FORK"
fi
wv_repository_require_owned "$REPO_ROOT" "wv init-repo" || exit 1

# remove_retired_git_hook <hook-name> <marker> — delete a Weave hook that is no
# longer shipped, only when it carries that hook's Weave signature: a custom
# hook of the same name is the user's and is left alone. The post-commit
# deferred-suite queue was retired by wv-56c823 (nothing had written its queue
# since e2d80d855; the two-tier gate, wv-862ac0, replaced it).
remove_retired_git_hook() {
    local hook_name="$1" marker="$2"
    [ -d "${HOOK_DIR:-}" ] || return 0
    local hook_dst="$HOOK_DIR/$hook_name"
    [ -f "$hook_dst" ] || return 0
    if grep -qF -- "$marker" "$hook_dst" 2>/dev/null; then
        rm -f "$hook_dst" && echo -e "  ${GREEN}✓${NC} .git/hooks/$hook_name (retired Weave hook removed)"
    else
        echo -e "  ${YELLOW}⊘${NC} .git/hooks/$hook_name (custom hook, left alone)"
    fi
}

# resolve_git_hook_dir <repo dir> — print the directory git runs this
# repository's hooks from, or print why Weave will not install there and
# return 1 (wv-76c726). Writing $REPO_ROOT/.git/hooks or git-dir/hooks missed
# both cases git itself handles: in a linked worktree .git is a file and the
# hooks live in the common dir, and core.hooksPath moves them elsewhere; the
# install then returned 0 having installed nothing. core.hooksPath is reported,
# not written to: it is usually a hook manager's tracked directory or a global
# one every repository shares, neither of which is Weave's to change.
resolve_git_hook_dir() {
    local repo="$1" hooks hooks_path
    hooks=$(git -C "$repo" rev-parse --git-path hooks 2>/dev/null) && [ -n "$hooks" ] || {
        echo "not a git repository: $repo"
        return 1
    }
    hooks_path=$(git -C "$repo" config --get core.hooksPath 2>/dev/null || true)
    if [ -n "$hooks_path" ]; then
        echo "core.hooksPath is set ($hooks_path): git runs hooks only from there, which Weave does not write to. Call the Weave hooks from it, e.g. ${WV_LIB_DIR:-$HOME/.local/lib/weave}/hooks/pre-commit-weave.sh from its pre-commit"
        return 1
    fi
    case "$hooks" in /*) ;; *) hooks="$(cd "$repo" && pwd -P)/$hooks" ;; esac
    mkdir -p "$hooks" 2>/dev/null || { echo "cannot create $hooks"; return 1; }
    printf '%s\n' "$hooks"
}

# set_hook_dir_or_report <repo dir> — set HOOK_DIR for install_git_hook_from_repo,
# or say loudly that no Weave git hook is active and leave HOOK_DIR empty.
set_hook_dir_or_report() {
    local resolved
    if resolved=$(resolve_git_hook_dir "$1"); then
        HOOK_DIR="$resolved"
    else
        HOOK_DIR=""
        echo -e "  ${YELLOW}⚠${NC} Weave git hooks NOT installed — no commit or push gate is active here: $resolved" >&2
    fi
}

install_git_hook_from_repo() {
    local hook_path="$1"
    local marker="$2"
    local hook_name="${3:-}"
    local hook_src_name
    local action="installed"
    hook_src_name=$(basename "$hook_path")
    [ -n "$hook_name" ] || hook_name="$hook_src_name"

    # set_hook_dir_or_report has already said why when HOOK_DIR is empty.
    if [ -z "${HOOK_DIR:-}" ] || [ ! -d "$HOOK_DIR" ]; then
        return 0
    fi

    local hook_dst="$HOOK_DIR/$hook_name"
    if [ -f "$hook_dst" ]; then
        # Refresh only a Weave-managed hook. Match the exact marker OR any stable
        # Weave signature, so an OLDER installed hook whose header wording has
        # since changed is still recognised and refreshed — instead of being
        # mistaken for a custom user hook and skipped (left stale, the friction
        # wv doctor flagged with a manual `install -m 755 ...`). A genuinely
        # custom hook (no Weave signature) is still preserved. The signatures
        # live in wv-git-hook-signature.sh, shared with wv doctor (wv-3a7368).
        if wv_git_hook_is_weave "$hook_dst" "$marker"; then
            action="updated"
        else
            # Preserved, but say what that costs: this gate is not active.
            echo -e "  ${YELLOW}⚠${NC} $hook_dst is a custom hook, kept as is — the Weave $hook_name gate is NOT active. Call ${WV_LIB_DIR:-$HOME/.local/lib/weave}/hooks/$hook_src_name from it to enable it." >&2
            return 0
        fi
    fi

    local lib_hook="${WV_LIB_DIR:-$HOME/.local/lib/weave}/hooks/$hook_src_name"

    # Write to a same-directory temp and RENAME into place. Copying onto the
    # destination truncates and rewrites the inode -- and the pre-commit hook's
    # own install-drift self-heal runs install.sh, so a commit that touched the
    # hook source rewrote the very file bash was executing. Bash reads a script
    # incrementally, so it resumed at its old byte offset inside new content and
    # died with a syntax error naming a line that was perfectly valid; the retry
    # then succeeded, which made it read as a flake. A rename swaps the
    # directory entry and leaves the running process on its original inode.
    local hook_tmp hook_got=0
    hook_tmp=$(mktemp "${hook_dst}.XXXXXX" 2>/dev/null) || hook_tmp="${hook_dst}.tmp.$$"
    if [ -f "$hook_path" ]; then
        cp "$hook_path" "$hook_tmp" && hook_got=1
    elif [ -f "$lib_hook" ]; then
        cp "$lib_hook" "$hook_tmp" && hook_got=1
    else
        local repo_base="${REPO:-https://raw.githubusercontent.com/AGM1968/weave/main}"
        curl -sSL "$repo_base/scripts/hooks/$hook_src_name" -o "$hook_tmp" \
            && [ -s "$hook_tmp" ] && hook_got=1
    fi
    if [ "$hook_got" != "1" ]; then
        rm -f "$hook_tmp" 2>/dev/null || true
        echo -e "  ${YELLOW}⊘${NC} .git/hooks/$hook_name (source unavailable, existing hook kept)"
        return 0
    fi
    chmod +x "$hook_tmp"
    if ! mv -f "$hook_tmp" "$hook_dst" 2>/dev/null; then
        rm -f "$hook_tmp" 2>/dev/null || true
        echo -e "  ${YELLOW}⊘${NC} .git/hooks/$hook_name (could not be replaced, existing hook kept)"
        return 0
    fi
    echo -e "  ${GREEN}✓${NC} .git/hooks/$hook_name ($action)"
}

# install_git_hook_module_from_repo <module source> — copy a module the
# installed pre-commit hook loads from beside itself into the same hooks dir
# (wv-758b3a, owner ruling on wv-0e2998). Taken from this repository's own
# source and nowhere else, never from LIB_DIR or the network: only Weave's
# source repository has it, so no consumer receives it. Installed only beside
# a Weave pre-commit hook; a custom hook does not load it.
install_git_hook_module_from_repo() {
    local mod_path="$1" mod_name mod_tmp
    mod_name=$(basename "$mod_path")
    if [ -z "${HOOK_DIR:-}" ] || [ ! -d "$HOOK_DIR" ] || [ ! -f "$mod_path" ]; then
        return 0
    fi
    if ! wv_git_hook_is_weave "$HOOK_DIR/pre-commit" "Weave pre-commit"; then
        return 0
    fi
    mod_tmp=$(mktemp "$HOOK_DIR/$mod_name.XXXXXX" 2>/dev/null) || mod_tmp="$HOOK_DIR/$mod_name.tmp.$$"
    if ! cp "$mod_path" "$mod_tmp" 2>/dev/null || ! chmod 644 "$mod_tmp" \
        || ! mv -f "$mod_tmp" "$HOOK_DIR/$mod_name" 2>/dev/null; then
        rm -f "$mod_tmp" 2>/dev/null || true
        echo -e "  ${YELLOW}⚠${NC} .git/hooks/$mod_name could not be installed; the pre-commit hook beside it needs it" >&2
        return 0
    fi
    echo -e "  ${GREEN}✓${NC} .git/hooks/$mod_name (installed)"
}

AGENT_LABEL=$(IFS=','; echo "${AGENTS[*]}")
if [ "$FORCE_MODE" = "1" ]; then
    echo -e "${CYAN}━━━ Weave Init (agent=$AGENT_LABEL, force) ━━━${NC}"
elif [ "$UPDATE_MODE" = "1" ]; then
    echo -e "${CYAN}━━━ Weave Update (agent=$AGENT_LABEL) ━━━${NC}"
else
    echo -e "${CYAN}━━━ Weave Init (agent=$AGENT_LABEL) ━━━${NC}"
fi

# ── Core setup (all agents) ──────────────────────────────────────────────
if [ -L "$REPO_ROOT/.weave" ]; then
    echo "wv-init-repo: refusing symlinked .weave directory: $REPO_ROOT/.weave" >&2
    exit 1
fi
mkdir -p "$REPO_ROOT/.weave"

# Curated shared pattern rules. The managed subdirectory is owned by
# wv-init-repo; top-level .weave/patterns/*.yaml remains project-owned.
_PATTERN_SRC="$CONFIG_DIR/quality-patterns/managed"
_PATTERN_PARENT="$REPO_ROOT/.weave/patterns"
_PATTERN_DST="$REPO_ROOT/.weave/patterns/managed"
_PATTERN_SRC_MANIFEST="$_PATTERN_SRC/manifest.txt"
_PATTERN_DST_MANIFEST="$_PATTERN_DST/.manifest"
if [ -f "$_PATTERN_SRC_MANIFEST" ]; then
    if [ -L "$_PATTERN_PARENT" ] || [ -L "$_PATTERN_DST" ]; then
        echo "wv-init-repo: refusing symlinked managed pattern directory: $_PATTERN_DST" >&2
        exit 1
    fi
    if [ ! -s "$_PATTERN_SRC_MANIFEST" ] \
        || [ -n "$(tail -c 1 "$_PATTERN_SRC_MANIFEST")" ] \
        || [ "$(sort "$_PATTERN_SRC_MANIFEST" | uniq -d | wc -l)" -ne 0 ]; then
        echo "wv-init-repo: invalid or duplicate managed pattern manifest" >&2
        exit 1
    fi
    while IFS= read -r _pattern_file; do
        case "$_pattern_file" in
            ""|*/*|*..*)
                echo "wv-init-repo: invalid managed pattern manifest entry: $_pattern_file" >&2
                exit 1
                ;;
            *.yaml) ;;
            *)
                echo "wv-init-repo: invalid managed pattern manifest entry: $_pattern_file" >&2
                exit 1
                ;;
        esac
        [ -f "$_PATTERN_SRC/$_pattern_file" ] && [ ! -L "$_PATTERN_SRC/$_pattern_file" ] || {
            echo "wv-init-repo: managed pattern missing from installed assets: $_pattern_file" >&2
            exit 1
        }
    done < "$_PATTERN_SRC_MANIFEST"
    for _pattern_source in "$_PATTERN_SRC"/*.yaml; do
        [ -f "$_pattern_source" ] || continue
        grep -qxF "$(basename "$_pattern_source")" "$_PATTERN_SRC_MANIFEST" || {
            echo "wv-init-repo: unmanifested managed pattern asset: $_pattern_source" >&2
            exit 1
        }
    done
    if ! PYTHONPATH="${WV_LIB_DIR:-$HOME/.local/lib/weave}" python3 - "$_PATTERN_SRC" <<'PY'
import sys
from pathlib import Path
from weave_quality.prose_rules import validate_pattern_rule

root = Path(sys.argv[1])
for path in root.glob("*.yaml"):
    validate_pattern_rule(path, path.stem)
PY
    then
        echo "wv-init-repo: installed managed pattern assets failed validation" >&2
        exit 1
    fi
    if [ -d "$_PATTERN_DST" ] && find "$_PATTERN_DST" -type l -print -quit | grep -q .; then
        echo "wv-init-repo: refusing symlink inside managed pattern directory: $_PATTERN_DST" >&2
        exit 1
    fi
    if [ -f "$_PATTERN_DST_MANIFEST" ]; then
        if [ ! -s "$_PATTERN_DST_MANIFEST" ] \
            || [ -n "$(tail -c 1 "$_PATTERN_DST_MANIFEST")" ] \
            || [ "$(sort "$_PATTERN_DST_MANIFEST" | uniq -d | wc -l)" -ne 0 ]; then
            echo "wv-init-repo: invalid or duplicate prior managed pattern manifest" >&2
            exit 1
        fi
        while IFS= read -r _old_pattern; do
            case "$_old_pattern" in
                ""|*/*|*..*) echo "wv-init-repo: invalid prior managed pattern manifest" >&2; exit 1 ;;
                *.yaml) ;;
                *) echo "wv-init-repo: invalid prior managed pattern manifest" >&2; exit 1 ;;
            esac
        done < "$_PATTERN_DST_MANIFEST"
    fi

    mkdir -p "$_PATTERN_PARENT"
    _PATTERN_STAGE=$(mktemp -d "$_PATTERN_PARENT/.managed-staging.XXXXXX")
    if [ -d "$_PATTERN_DST" ]; then
        cp -a "$_PATTERN_DST/." "$_PATTERN_STAGE/"
    fi
    rm -f "$_PATTERN_STAGE/.manifest"
    if [ -f "$_PATTERN_DST_MANIFEST" ]; then
        while IFS= read -r _old_pattern; do
            rm -f "$_PATTERN_STAGE/$_old_pattern"
        done < "$_PATTERN_DST_MANIFEST"
    fi
    _new_pattern_manifest="$_PATTERN_STAGE/.manifest"
    : > "$_new_pattern_manifest"
    # .overridden is rebuilt fresh every run: it records managed rule ids this
    # reconcile skipped because a same-named project-local rule already exists
    # (almost always a completed promotion round-trip where the local copy
    # should be deleted). `wv quality patterns list`/`doctor` read it to warn
    # that the local copy is silently shadowing an improved managed version.
    _new_pattern_overridden="$_PATTERN_STAGE/.overridden"
    : > "$_new_pattern_overridden"
    while IFS= read -r _pattern_file; do
        _pattern_local_override="$REPO_ROOT/.weave/patterns/$_pattern_file"
        if [ -f "$_pattern_local_override" ]; then
            echo -e "  ${YELLOW}⊘${NC} .weave/patterns/managed/$_pattern_file (project-local override preserved)"
            printf '%s\n' "$_pattern_file" >> "$_new_pattern_overridden"
            continue
        fi
        if [ -e "$_PATTERN_STAGE/$_pattern_file" ]; then
            echo -e "  ${YELLOW}⊘${NC} .weave/patterns/managed/$_pattern_file (unmanaged file exists, preserved)"
            continue
        fi
        cp "$_PATTERN_SRC/$_pattern_file" "$_PATTERN_STAGE/$_pattern_file"
        printf '%s\n' "$_pattern_file" >> "$_new_pattern_manifest"
    done < "$_PATTERN_SRC_MANIFEST"
    _PATTERN_OLD="$_PATTERN_PARENT/.managed-old.$$"
    rm -rf "$_PATTERN_OLD"
    [ ! -e "$_PATTERN_DST" ] || mv "$_PATTERN_DST" "$_PATTERN_OLD"
    if ! mv "$_PATTERN_STAGE" "$_PATTERN_DST"; then
        [ ! -e "$_PATTERN_OLD" ] || mv "$_PATTERN_OLD" "$_PATTERN_DST"
        rm -rf "$_PATTERN_STAGE"
        exit 1
    fi
    rm -rf "$_PATTERN_OLD"
    echo -e "  ${GREEN}✓${NC} .weave/patterns/managed (reconciled)"
fi

# .weave/runtime.md scaffold (shared by weave-runtime system prompt injection)
# Two-block architecture:
#   Block 1: BEGIN/END WEAVE RUNTIME CONTEXT  — context policy, managed by context-guard.sh
#   Block 2: BEGIN/END WEAVE RUNTIME CONTENT  — generic Weave guidance, updatable by --update
#   Below block 2: repo-specific content, never touched by init-repo
# The PATH guidance differs by repo kind, and stating the wrong one is worse
# than stating none: a consumer has no ./scripts/wv to prefer, while in the
# weave source checkout pointing at the installed binary sends an agent to test
# something other than the tree it is editing.
if [ -x "$REPO_ROOT/scripts/wv" ] && [ -f "$REPO_ROOT/scripts/lib/wv-config.sh" ]; then
    _WV_RUNTIME_WV_FALLBACK='if ! command -v wv >/dev/null 2>&1; then wv() { ./scripts/wv "$@"; }; fi'
    _WV_RUNTIME_PATH_NOTE='If `wv` is not on PATH, prefer the repo-local wrapper, then the installed binary:

```bash
./scripts/wv bootstrap --json
$HOME/.local/bin/wv bootstrap --json
```

The repo-local wrapper appends existing user tool directories (`$HOME/.local/bin`,
`$HOME/.cargo/bin`) to PATH so sandbox agent shells can see tools such as `ast-grep`
without putting the repository or current directory on PATH. Set
`WV_DISABLE_USER_TOOL_PATHS=1` to disable this normalization.'
else
    _WV_RUNTIME_WV_FALLBACK='if ! command -v wv >/dev/null 2>&1; then wv() { "$HOME/.local/bin/wv" "$@"; }; fi'
    _WV_RUNTIME_PATH_NOTE='If `wv` is not on PATH, call the installed binary directly:

```bash
$HOME/.local/bin/wv bootstrap --json
```

This repository does not vendor weave'"'"'s own `scripts/wv`; wv is installed globally
by install.sh.'
fi

RUNTIME_MD="$REPO_ROOT/.weave/runtime.md"
RUNTIME_MD_MARKER_BEGIN="<!-- BEGIN WEAVE RUNTIME CONTEXT -->"
RUNTIME_MD_CONTENT_BEGIN="<!-- BEGIN WEAVE RUNTIME CONTENT -->"
RUNTIME_MD_CONTENT_END="<!-- END WEAVE RUNTIME CONTENT -->"
RUNTIME_MD_BLOCK="${RUNTIME_MD_MARKER_BEGIN}
Current context policy: unknown (refresh on session start)
Policy source: .weave/.context_policy
This file is loaded into weave-runtime system prompts. Keep repo-specific instructions below this block.
<!-- END WEAVE RUNTIME CONTEXT -->"
_runtime_content_block() {
cat << 'RUNTIMECONTENTEOF'
<!-- BEGIN WEAVE RUNTIME CONTENT -->
## Session Start

```bash
RUNTIMECONTENTEOF
# Executable fallback, chosen for the repo this lands in: a consumer has
# no ./scripts/wv, so hardcoding it handed the agent a path that does not
# exist while the surrounding prose advised the installed binary.
printf '%s\n' "$_WV_RUNTIME_WV_FALLBACK"
cat << 'RUNTIMECONTENTEOF'
wv bootstrap --json   # single call: active/ready/blocked + learnings + context policy
```

Key signals: `active` count (must claim before editing), `git_sync` status, `ready` list,
`context_policy` (HIGH/MEDIUM/LOW — governs file read depth), recent `learnings`.

## Session Close

```bash
git add <files> && git commit -m "..."
wv done <id> --learning="decision: ... | pattern: ... | pitfall: ..."
wv sync --gh && git add .weave/
git diff --cached --quiet || git commit -m "chore(weave): sync state [skip ci]"
git push
```

Shortcut: `wv ship <id> --learning="..."` (done + sync; still requires push after).

## GraphPolicyViolation (wv done blocked)

```bash
wv quality functions <file>    # identify functions over CC limit
# Option A: refactor, commit, wv quality scan, retry wv done
# Option B: add to .weave/quality.conf [exempt] then wv load, retry wv done
```

## Agent Runtime Notes
RUNTIMECONTENTEOF
# Emitted OUTSIDE the quoted heredoc: that heredoc is <<'EOF' precisely because
# the rest of its body contains $ sequences that must stay literal, so a
# placeholder inside it would have been written out verbatim.
printf '\n%s\n' "$_WV_RUNTIME_PATH_NOTE"
cat << 'RUNTIMECONTENTEOF'

In sandbox agent shells (Codex/Copilot/Claude Code), Weave uses a persistent
`/tmp/weave-hotzone-*` hot zone because `/dev/shm` is not stable across tool invocations.
During the rename transition that name is an alias of the legacy `/tmp/weave-codex-*`
directory, which stays the physical one; `wv doctor` reports which is physical.
<!-- END WEAVE RUNTIME CONTENT -->
RUNTIMECONTENTEOF
}
if [ ! -f "$RUNTIME_MD" ]; then
    {
        printf '%s\n\n' "$RUNTIME_MD_BLOCK"
        _runtime_content_block
        printf '\nAdd repo-specific instructions below this line.\n'
    } > "$RUNTIME_MD"
    echo -e "  ${GREEN}✓${NC} .weave/runtime.md"
elif ! grep -qF -- "$RUNTIME_MD_MARKER_BEGIN" "$RUNTIME_MD"; then
    # No context block at all — prepend both blocks
    _tmp_runtime=$(mktemp)
    {
        printf '%s\n\n' "$RUNTIME_MD_BLOCK"
        _runtime_content_block
        printf '\n'
        cat "$RUNTIME_MD"
    } > "$_tmp_runtime"
    mv "$_tmp_runtime" "$RUNTIME_MD"
    echo -e "  ${GREEN}✓${NC} .weave/runtime.md (managed blocks prepended)"
elif ([ "$UPDATE_MODE" = "1" ] || [ "$FORCE_MODE" = "1" ]) && ! grep -qF -- "$RUNTIME_MD_CONTENT_BEGIN" "$RUNTIME_MD"; then
    # Has context block but no content block — inject content block after context block
    _tmp_runtime=$(mktemp)
    awk -v content="$(_runtime_content_block)" '
        /END WEAVE RUNTIME CONTEXT/ { print; print ""; print content; next }
        { print }
    ' "$RUNTIME_MD" > "$_tmp_runtime"
    mv "$_tmp_runtime" "$RUNTIME_MD"
    echo -e "  ${GREEN}✓${NC} .weave/runtime.md (content block injected)"
elif [ "$UPDATE_MODE" = "1" ] || [ "$FORCE_MODE" = "1" ]; then
    # Has both blocks — surgical swap of content block, preserve everything outside
    _before=$(awk '/BEGIN WEAVE RUNTIME CONTENT/{exit} {print}' "$RUNTIME_MD")
    _after=$(awk '/END WEAVE RUNTIME CONTENT/{found=1; next} found{print}' "$RUNTIME_MD")
    _tmp_runtime=$(mktemp)
    {
        [ -n "$_before" ] && printf '%s\n\n' "$_before"
        _runtime_content_block
        [ -n "$_after" ] && printf '%s\n' "$_after"
    } > "$_tmp_runtime"
    mv "$_tmp_runtime" "$RUNTIME_MD"
    echo -e "  ${GREEN}✓${NC} .weave/runtime.md (content block updated)"
else
    echo -e "  ${YELLOW}⊘${NC} .weave/runtime.md (already exists, skipped)"
fi

# .gitignore management (idempotent)
GITIGNORE="$REPO_ROOT/.gitignore"
# The runtime files come from the one list in wv-runtime-ignores.sh (wv-9a54da);
# the rest keep graph exports and the shared Claude settings tracked.
WEAVE_PATTERNS=(
    "${WV_RUNTIME_IGNORES[@]}"
    "!.weave/state.sql"
    "!.weave/quality-adjudications.jsonl"
    "!.claude/settings.json"
    ".claude/settings.local.json"
)
if [ -f "$GITIGNORE" ]; then
    added=0
    for entry in "${WEAVE_PATTERNS[@]}"; do
        if ! grep -qxF -- "$entry" "$GITIGNORE"; then
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
# Runtime state committed before it was ignored stays tracked, and churns or
# conflicts on every commit. Name it; untracking is the operator's commit.
_wv_tracked_runtime=$(wv_runtime_tracked "$REPO_ROOT" | tr '\n' ' ')
if [ -n "${_wv_tracked_runtime% }" ]; then
    echo -e "  ${YELLOW}⚠${NC} machine-local runtime files are committed; untrack them (the files stay on disk):"
    echo "      git rm --cached -- ${_wv_tracked_runtime% } && git commit -m 'chore(weave): untrack runtime files'"
fi

# scripts/hooks/ vendor refresh — for a consumer repo that vendors hook sources,
# converge scripts/hooks/ to the canonical set from LIB_DIR so PR review and
# wv doctor --source-compare see every installed hook. SEED a source that is
# missing (not just refresh ones already present): a consumer scaffolded before
# a hook was added (e.g. post-commit-weave.sh) installs the .git/hooks/ copy from
# the LIB_DIR fallback but never gets the vendored source otherwise, leaving a
# permanent source/installed asymmetry (wv-2adeef).
_LIB_HOOKS="${WV_LIB_DIR:-$HOME/.local/lib/weave}/hooks"
if [ -d "$REPO_ROOT/scripts/hooks" ] && [ -d "$_LIB_HOOKS" ]; then
    _updated_vendor=0
    # A vendored copy of a retired hook source goes too (wv-56c823), when it
    # is Weave's (carries the Weave post-commit signature).
    if [ -f "$REPO_ROOT/scripts/hooks/post-commit-weave.sh" ] \
        && grep -qF "Weave post-commit" "$REPO_ROOT/scripts/hooks/post-commit-weave.sh" 2>/dev/null; then
        rm -f "$REPO_ROOT/scripts/hooks/post-commit-weave.sh"
        echo -e "  ${GREEN}✓${NC} scripts/hooks/post-commit-weave.sh (retired, removed)"
    fi
    for _hf in pre-commit-weave.sh prepare-commit-msg-weave.sh pre-push-weave.sh reference-transaction-weave.sh; do
        [ -f "$_LIB_HOOKS/$_hf" ] || continue
        if [ ! -f "$REPO_ROOT/scripts/hooks/$_hf" ]; then
            cp "$_LIB_HOOKS/$_hf" "$REPO_ROOT/scripts/hooks/$_hf"
            chmod +x "$REPO_ROOT/scripts/hooks/$_hf"
            echo -e "  ${GREEN}✓${NC} scripts/hooks/$_hf (seeded)"
            _updated_vendor=1
        elif ! cmp -s "$_LIB_HOOKS/$_hf" "$REPO_ROOT/scripts/hooks/$_hf" 2>/dev/null; then
            # A differing source may be a local edit: refresh it only when asked,
            # as every other copy that already exists is (wv-d6e9ba). Seeding a
            # missing source above stays ungated.
            if [ "$UPDATE_MODE" = "1" ]; then
                cp "$_LIB_HOOKS/$_hf" "$REPO_ROOT/scripts/hooks/$_hf"
                chmod +x "$REPO_ROOT/scripts/hooks/$_hf"
                echo -e "  ${GREEN}✓${NC} scripts/hooks/$_hf (updated)"
                _updated_vendor=1
            else
                echo -e "  ${YELLOW}⊘${NC} scripts/hooks/$_hf (exists, use --update to overwrite)"
            fi
        fi
    done
    [ "$_updated_vendor" -eq 0 ] && true
fi

# Refresh tracked hook sources before installing .git/hooks copies. Installing
# first leaves the executable one release behind whenever a consumer vendors a
# stale source: the first pass copies that stale file into .git/hooks and only
# then refreshes its source, so doctor requires a second update to converge.
set_hook_dir_or_report "$REPO_ROOT"

# Git hook: prepare-commit-msg (portable, awk-based)
install_git_hook_from_repo "./scripts/hooks/prepare-commit-msg-weave.sh" "Weave: append Weave-ID trailers" "prepare-commit-msg"

# Git hook: pre-commit (enforce active Weave node)
install_git_hook_from_repo "./scripts/hooks/pre-commit-weave.sh" "Weave pre-commit" "pre-commit"
install_git_hook_module_from_repo "./scripts/hooks/pre-commit-recovery.sh"

# Git hook: post-commit -- retired (wv-56c823); remove a Weave copy, keep a custom one
remove_retired_git_hook "post-commit" "Weave post-commit"

# Git hook: pre-push (the heavy tier of the commit gate, wv-862ac0; exits at
# once in a repository whose test map has no [heavy] section)
install_git_hook_from_repo "./scripts/hooks/pre-push-weave.sh" "Weave pre-push" "pre-push"

# Git hook: reference-transaction (publishes only the tree the pre-commit gate
# judged, wv-5f9d1c; passes every other ref update untouched)
install_git_hook_from_repo "./scripts/hooks/reference-transaction-weave.sh" "Weave reference-transaction" "reference-transaction"

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
.weave/quality-adjudications.jsonl merge=union
.weave/breadcrumbs.md merge=ours
# Causal cutover marker (wv-2448dd): an operator declaration stamped once when
# every agent has synced. merge=ours keeps the local stamp rather than halting a
# merge; concurrent stamping is operator error the coordination gate guards.
.weave/causal-cutover merge=ours -diff linguist-generated

# Delta files: unique filenames mean no real conflicts; merge=theirs is a safety net.
# Requires: git config merge.theirs.driver \"cp %B %A\" (done by wv-init-repo)
# v1 SQL changesets and, post-cutover (wv-4448a2), the immutable Delta v2 op
# sidecars under deltas/<date>/v2/.
.weave/deltas/**/*.sql merge=theirs
.weave/deltas/**/*.json merge=theirs
${ATTR_MARKER_END}"

if [ -f "$GITATTR" ]; then
    if grep -qF -- "$ATTR_MARKER_BEGIN" "$GITATTR"; then
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

# ── authoring templates (.weave/guides/, and whatever the manifest grows) ──
# Weave delivers guides, procedures and rules into a consumer but templated
# nothing a consumer could author against, so two unrelated consumer repos
# each built the same guide tooling alone. This seeds the contract instead.
#
# Deliberately manifest-driven rather than a block per class: a consumer may
# author a procedure on the same footing as a guide, so the next class is a
# template file and a manifest row, not another branch here.
_AUTHORING_SRC="$CONFIG_DIR/authoring"
if [ -f "$_AUTHORING_SRC/manifest.conf" ]; then
    while IFS='|' read -r _auth_src _auth_dst _auth_mode _auth_note; do
        case "$_auth_src" in ""|\#*) continue ;; esac
        case "$_auth_dst" in
            ""|/*|*..*)
                echo "wv-init-repo: invalid authoring destination: $_auth_dst" >&2
                exit 1
                ;;
        esac
        case "$_auth_mode" in
            seed|refresh) ;;
            *)
                echo "wv-init-repo: invalid authoring mode for $_auth_dst: $_auth_mode" >&2
                exit 1
                ;;
        esac
        [ -f "$_AUTHORING_SRC/$_auth_src" ] || {
            echo "wv-init-repo: authoring template missing from installed assets: $_auth_src" >&2
            exit 1
        }
        _auth_full="$REPO_ROOT/$_auth_dst"
        _auth_dir=$(dirname "$_auth_full")
        if [ -L "$_auth_dir" ] || [ -L "$_auth_full" ]; then
            echo "wv-init-repo: refusing symlinked authoring destination: $_auth_dst" >&2
            exit 1
        fi
        if [ -f "$_auth_full" ] \
            && { [ "$_auth_mode" = "seed" ] \
                 || { [ "$UPDATE_MODE" != "1" ] && [ "$FORCE_MODE" != "1" ]; }; }; then
            echo -e "  ${YELLOW}⊘${NC} $_auth_dst (exists — authored here, not overwritten)"
            continue
        fi
        mkdir -p "$_auth_dir"
        cp "$_AUTHORING_SRC/$_auth_src" "$_auth_full"
        echo -e "  ${GREEN}✓${NC} $_auth_dst ($_auth_note)"
    done < "$_AUTHORING_SRC/manifest.conf"
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
    SKILLS=(trails close-session fix-issue plan-agent pre-mortem resolve-refs sanity-check ship-it weave weave-audit wv-clarify-spec wv-decompose-work wv-detect-loop wv-guard-scope wv-verify-complete zero-in)
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

Specialized subagents for Weave workflow. Spawn via whatever agent-spawning mechanism your
host supports (Agent tool, MCP client subagent, shell subprocess, etc.).

## Session start (always)

```bash
AGENTSEOF
# Executable fallback, chosen for the repo this lands in: a consumer has
# no ./scripts/wv, so hardcoding it handed the agent a path that does not
# exist while the surrounding prose advised the installed binary.
printf '%s\n' "$_WV_RUNTIME_WV_FALLBACK"
cat << 'AGENTSEOF'
wv bootstrap --json   # single call: active/ready/blocked + recent learnings + context policy
```

Key signals: `active` count (must claim before editing), `git_sync` status, `ready` list,
`context_policy` (HIGH/MEDIUM/LOW — governs file read depth), recent `learnings`.

## Session close (always)

```bash
git add <files> && git commit -m "..."
wv done <id> --learning="decision: ... | pattern: ... | pitfall: ..."
wv sync --gh && git add .weave/
git diff --cached --quiet || git commit -m "chore(weave): sync state [skip ci]"
git push
```

Shortcut: `wv ship <id> --learning="..."` (done + sync; still requires push after).

## Operating rules

- No edits without an active node — `wv work <id>` first if `wv status` shows 0 active.
- To reopen a done node: `wv work <id> --reopen` (plain `wv work` errors on done nodes).
- Discovery before claiming may read, search, and report only.
- `wv search "<topic>"` before `wv add` to avoid duplicates.
- Set `--criteria=` and `--risks=` at creation time, not reactively at claim time.
- Commit before `wv done` — pre-commit hook blocks after node is closed.
- `wv context <id> --json` before complex work.

## Subagents

| Agent            | Purpose                        | Trigger                           |
| ---------------- | ------------------------------ | --------------------------------- |
| weave-guide      | Workflow guidance               | Unsure how to use Weave           |
| epic-planner     | Strategic planning              | Starting a new epic or sprint     |
| learning-curator | Knowledge capture               | After completing significant work |

## Code search

If `wv index` has been run, prefer hybrid code search over grep/glob for discovery:

```bash
wv search --code "query"                  # hybrid BM25 + cosine (CLI)
wv search --code "query" --mode=fts       # exact tokens / function names
wv search --code "query" --graph          # include active Weave nodes per file
```

MCP equivalent: `weave_code_search` (parameters: `query`, `mode`, `limit`, `graph`).
AGENTSEOF
        echo -e "  ${GREEN}✓${NC} .claude/agents/AGENTS.md"
    elif [ -f "$REPO_ROOT/.claude/agents/AGENTS.md" ]; then
        echo -e "  ${YELLOW}⊘${NC} .claude/agents/AGENTS.md (already exists, skipped)"
    fi


    # ── CLAUDE.md (weave block — prepend/update, preserve project content) ──
    if [ -f "$CONFIG_DIR/CLAUDE.md.template" ]; then
        _weave_block=$(cat "$CONFIG_DIR/CLAUDE.md.template")
        # The template's PATH-fallback paragraph is written for a consumer repo
        # and asserts the repo "does not vendor weave's own scripts/wv". In the
        # weave source checkout that is exactly backwards, and running
        # `wv init-repo --update` there replaced accurate guidance with a false
        # statement plus a fallback pointing at the INSTALLED wv rather than the
        # working tree -- so an agent following it would edit source and test
        # something else. A repo that vendors scripts/wv gets the vendored form.
        _weave_block=$(_wv_localize_agent_block "$_weave_block")
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
            # Existing with block: surgical replace using awk (no sed 1,/REGEX/ first-line gotcha)
            _before=$(awk '/BEGIN WEAVE CLAUDE\.MD|WEAVE-BLOCK-START/{exit} {print}' "$REPO_ROOT/CLAUDE.md")
            _after=$(awk '/END WEAVE CLAUDE\.MD|WEAVE-BLOCK-END/{found=1; next} found{print}' "$REPO_ROOT/CLAUDE.md")
            {
                [ -n "$_before" ] && printf '%s\n' "$_before"
                printf '%s\n' "$_weave_block"
                [ -n "$_after" ] && printf '%s\n' "$_after"
            } > "$REPO_ROOT/CLAUDE.md"
            echo -e "  ${GREEN}✓${NC} CLAUDE.md (Weave block updated)"
        elif [ "$UPDATE_MODE" = "1" ] || [ "$FORCE_MODE" = "1" ]; then
            # Existing without block + --update/--force: prepend block
            _existing=$(cat "$REPO_ROOT/CLAUDE.md")
            { printf '%s\n\n' "$_weave_block"; printf '%s\n' "$_existing"; } > "$REPO_ROOT/CLAUDE.md"
            echo -e "  ${GREEN}✓${NC} CLAUDE.md (Weave block prepended)"
        else
            echo -e "  ${YELLOW}⊘${NC} CLAUDE.md (exists without Weave block — use --update to prepend)"
        fi
        _refresh_memory_projection claude "$REPO_ROOT/CLAUDE.md"
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
    # lint-file is consumer-owned: written once below END WEAVE TARGETS, never overwritten.
    _lint_file_stub() {
        printf '\n## Lint a single file — called by weave-runtime TUI after_tool hook.\n'
        printf '## Consumer-owned: init-repo writes this once and never overwrites it.\n'
        printf '## Replace @true with your project'"'"'s per-file linter.\n'
        printf '#   Python:  ruff check --no-fix $$(FILE) 2>&1 || true\n'
        printf '#   JS/TS:   npx eslint $$(FILE) 2>&1 || true\n'
        printf '#   Ruby:    bundle exec rubocop $$(FILE) 2>&1 || true\n'
        printf '.PHONY: lint-file\n'
        printf 'lint-file:\n'
        printf '\t@true\n'
    }
    if [ -f "$CONFIG_DIR/Makefile.template" ]; then
        if [ ! -f "$REPO_ROOT/Makefile" ]; then
            cp "$CONFIG_DIR/Makefile.template" "$REPO_ROOT/Makefile"
            _lint_file_stub >> "$REPO_ROOT/Makefile"
            echo -e "  ${GREEN}✓${NC} Makefile (wv targets)"
        elif [ "$FORCE_MODE" = "1" ] || [ "$UPDATE_MODE" = "1" ]; then
            if grep -q '# ── BEGIN WEAVE TARGETS ──' "$REPO_ROOT/Makefile"; then
                # Replace existing weave section, preserve user targets
                _tmp_mk=$(mktemp)
                # Keep everything before BEGIN marker
                sed '/# ── BEGIN WEAVE TARGETS ──/,$d' "$REPO_ROOT/Makefile" > "$_tmp_mk"
                # Insert new weave section
                cat "$CONFIG_DIR/Makefile.template" >> "$_tmp_mk"
                # Keep everything after END marker (includes consumer lint-file if already outside block)
                sed -n '/# ── END WEAVE TARGETS ──/,${/# ── END WEAVE TARGETS ──/d;p}' "$REPO_ROOT/Makefile" >> "$_tmp_mk"
                # Migration: if lint-file was inside old block (now gone), append stub below
                if ! grep -q '^lint-file:' "$_tmp_mk"; then
                    _lint_file_stub >> "$_tmp_mk"
                fi
                # Suppress write when only the version comment changed
                _strip_ver() { grep -v '^# Generated by wv-init-repo v' "$1"; }
                if _strip_ver "$_tmp_mk" | diff -q - <(_strip_ver "$REPO_ROOT/Makefile") >/dev/null 2>&1; then
                    rm -f "$_tmp_mk"
                    echo -e "  ${GREEN}✓${NC} Makefile (weave targets up to date)"
                else
                    mv "$_tmp_mk" "$REPO_ROOT/Makefile"
                    echo -e "  ${GREEN}✓${NC} Makefile (weave targets updated, user targets preserved)"
                fi
            elif ! grep -q '^wv-status:' "$REPO_ROOT/Makefile"; then
                # No markers and no wv targets — append
                echo "" >> "$REPO_ROOT/Makefile"
                cat "$CONFIG_DIR/Makefile.template" >> "$REPO_ROOT/Makefile"
                if ! grep -q '^lint-file:' "$REPO_ROOT/Makefile"; then
                    _lint_file_stub >> "$REPO_ROOT/Makefile"
                fi
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

    # ── scripts/test-impacted.sh (fast impact-scoped pre-commit test runner) ──
    # Seeded if-absent only: the template ships an editable CONFIG block (SRC_PREFIX/
    # TEST_ROOT/RUNNER/RUN_ENV) the consumer tunes per repo, so we never clobber an
    # edited copy on --update. Map src/ -> it in .weave/test-map.conf to activate.
    if [ -f "$CONFIG_DIR/test-impacted.sh.template" ]; then
        if [ ! -f "$REPO_ROOT/scripts/test-impacted.sh" ]; then
            mkdir -p "$REPO_ROOT/scripts"
            cp "$CONFIG_DIR/test-impacted.sh.template" "$REPO_ROOT/scripts/test-impacted.sh"
            chmod +x "$REPO_ROOT/scripts/test-impacted.sh"
            echo -e "  ${GREEN}✓${NC} scripts/test-impacted.sh (edit CONFIG block, then map src/ in .weave/test-map.conf)"
        else
            echo -e "  ${YELLOW}⊘${NC} scripts/test-impacted.sh (exists — edited per repo, not overwritten)"
        fi
    fi


    # ── .weave/ci-weave-paths-ignore.snippet.yml (CI hygiene reference snippet) ──
    # Reference doc, not auto-applied: editing a consumer's workflows automatically
    # is unsafe. Refreshed on --update so the guidance stays current.
    if [ -f "$CONFIG_DIR/ci-weave-paths-ignore.snippet.yml" ]; then
        mkdir -p "$REPO_ROOT/.weave"
        _snip_dst="$REPO_ROOT/.weave/ci-weave-paths-ignore.snippet.yml"
        if [ ! -f "$_snip_dst" ] || [ "$UPDATE_MODE" = "1" ] || [ "$FORCE_MODE" = "1" ]; then
            cp "$CONFIG_DIR/ci-weave-paths-ignore.snippet.yml" "$_snip_dst"
            echo -e "  ${GREEN}✓${NC} .weave/ci-weave-paths-ignore.snippet.yml (add paths-ignore: ['.weave/**'] to your workflows)"
        else
            echo -e "  ${YELLOW}⊘${NC} .weave/ci-weave-paths-ignore.snippet.yml (already present)"
        fi
    fi

    # ── .claude/hooks/ (managed — update from installed hooks on --update) ──
    # Hooks fire globally from ~/.config/weave/hooks/ (Alt-A architecture).
    # Consumer repos may have a local .claude/hooks/ copy from before this change
    # or from wv-init-repo itself.  On --update, sync stale hooks from the
    # installed source so `wv doctor` hook drift passes without a manual cp.
    CLAUDE_HOOKS_DIR="$REPO_ROOT/.claude/hooks"
    INSTALLED_HOOKS_DIR="$HOME/.config/weave/hooks"
    if [ -d "$CLAUDE_HOOKS_DIR" ] && [ -d "$INSTALLED_HOOKS_DIR" ]; then
        _hooks_updated=0
        _hooks_skipped=0
        for src in "$INSTALLED_HOOKS_DIR"/*.sh; do
            [ -f "$src" ] || continue
            fname=$(basename "$src")
            dst="$CLAUDE_HOOKS_DIR/$fname"
            if [ ! -f "$dst" ] || \
               [ "$(md5sum "$src" 2>/dev/null | awk '{print $1}')" != \
                 "$(md5sum "$dst" 2>/dev/null | awk '{print $1}')" ]; then
                cp "$src" "$dst"
                _hooks_updated=$((_hooks_updated + 1))
            else
                _hooks_skipped=$((_hooks_skipped + 1))
            fi
        done
        if [ "$_hooks_updated" -gt 0 ]; then
            echo -e "  ${GREEN}✓${NC} .claude/hooks/ ($_hooks_updated updated, $_hooks_skipped already current)"
        else
            echo -e "  ${YELLOW}⊘${NC} .claude/hooks/ (all $_hooks_skipped hooks already current)"
        fi
    fi

fi

if [ "$AGENT" = "copilot" ]; then
        # VS Code Copilot: .vscode/mcp.json + .mcp.json + .github/copilot-instructions.md

        # Both files below are committed/shared via git (unlike settings.local.json),
        # so baking in THIS machine's resolved $HOME breaks every other machine/user
        # that clones the repo (e.g. node /home/<user>/... ENOENTs on any other box).
        # Emit the portable ${env:HOME} form whenever the resolved path sits under
        # $HOME (the standard install layout); fall back to the literal path for
        # non-standard installs (e.g. WV_LIB_DIR override, dev-mode repo-relative
        # paths) where portability isn't the goal anyway.
        MCP_SERVER_JSON="$MCP_SERVER"
        case "$MCP_SERVER" in
            "$HOME"/*) MCP_SERVER_JSON="\${env:HOME}${MCP_SERVER#$HOME}" ;;
        esac
        WV_BIN_JSON="$WV_BIN"
        case "$WV_BIN" in
            "$HOME"/*) WV_BIN_JSON="\${env:HOME}${WV_BIN#$HOME}" ;;
        esac

        # ── .vscode/mcp.json (VS Code workspace MCP config; user file) ──
        if [ ! -f "$REPO_ROOT/.vscode/mcp.json" ] || [ "$FORCE_MODE" = "1" ]; then
                mkdir -p "$REPO_ROOT/.vscode"
                cat > "$REPO_ROOT/.vscode/mcp.json" << MCPEOF
{
    "servers": {
        "weave": {
            "command": "node",
            "args": ["$MCP_SERVER_JSON"],
            "env": {
                "WV_PATH": "$WV_BIN_JSON",
                "WV_PROJECT_ROOT": "\${workspaceFolder}",
                "WV_AGENT_ID": "copilot-\${workspaceFolderBasename}"
            }
        },
        "weave-session": {
            "command": "node",
            "args": ["$MCP_SERVER_JSON", "--scope=session"],
            "env": {
                "WV_PATH": "$WV_BIN_JSON",
                "WV_PROJECT_ROOT": "\${workspaceFolder}",
                "WV_AGENT_ID": "copilot-\${workspaceFolderBasename}"
            }
        },
        "weave-lite": {
            "command": "node",
            "args": ["$MCP_SERVER_JSON", "--scope=lite"],
            "env": {
                "WV_PATH": "$WV_BIN_JSON",
                "WV_PROJECT_ROOT": "\${workspaceFolder}",
                "WV_AGENT_ID": "copilot-\${workspaceFolderBasename}"
            }
        },
        "weave-inspect": {
            "command": "node",
            "args": ["$MCP_SERVER_JSON", "--scope=inspect"],
            "env": {
                "WV_PATH": "$WV_BIN_JSON",
                "WV_PROJECT_ROOT": "\${workspaceFolder}",
                "WV_AGENT_ID": "copilot-\${workspaceFolderBasename}"
            }
        }
    }
}
MCPEOF
                echo -e "  ${GREEN}✓${NC} .vscode/mcp.json"
        else
                echo -e "  ${YELLOW}⊘${NC} .vscode/mcp.json (user file, use --force to overwrite)"
        fi

        # ── .mcp.json (legacy root MCP config; user file) ──
    if [ ! -f "$REPO_ROOT/.mcp.json" ] || [ "$FORCE_MODE" = "1" ]; then
        cat > "$REPO_ROOT/.mcp.json" << MCPEOF
{
    "servers": {
        "weave": {
            "command": "node",
            "args": ["$MCP_SERVER_JSON"],
            "env": {
                "WV_PATH": "$WV_BIN_JSON",
                "WV_PROJECT_ROOT": "\${workspaceFolder}",
                "WV_AGENT_ID": "copilot-\${workspaceFolderBasename}"
            }
        },
        "weave-session": {
            "command": "node",
            "args": ["$MCP_SERVER_JSON", "--scope=session"],
            "env": {
                "WV_PATH": "$WV_BIN_JSON",
                "WV_PROJECT_ROOT": "\${workspaceFolder}",
                "WV_AGENT_ID": "copilot-\${workspaceFolderBasename}"
            }
        },
        "weave-lite": {
            "command": "node",
            "args": ["$MCP_SERVER_JSON", "--scope=lite"],
            "env": {
                "WV_PATH": "$WV_BIN_JSON",
                "WV_PROJECT_ROOT": "\${workspaceFolder}",
                "WV_AGENT_ID": "copilot-\${workspaceFolderBasename}"
            }
        },
        "weave-inspect": {
            "command": "node",
            "args": ["$MCP_SERVER_JSON", "--scope=inspect"],
            "env": {
                "WV_PATH": "$WV_BIN_JSON",
                "WV_PROJECT_ROOT": "\${workspaceFolder}",
                "WV_AGENT_ID": "copilot-\${workspaceFolderBasename}"
            }
        }
    }
}
MCPEOF
        echo -e "  ${GREEN}✓${NC} .mcp.json"
        if [ ! -f "$MCP_SERVER" ]; then
            echo -e "  ${YELLOW}⊘${NC} MCP server not found at $MCP_SERVER"
            echo -e "    Run: install.sh --with-mcp"
        fi
    else
        echo -e "  ${YELLOW}⊘${NC} .mcp.json (user file, use --force to overwrite)"
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

    # ── .github/hooks/ — VS Code Local's native registrations (wv-971035) ──
    if [ ! -d "$REPO_ROOT/.github/hooks" ]; then
        mkdir -p "$REPO_ROOT/.github/hooks"
        cat > "$REPO_ROOT/.github/hooks/README.md" << 'GHHOOKSEOF'
# VS Code Hooks

`weave.json` registers the shared Weave guards for VS Code's **Local** harness.
Review it with **Chat: Configure Hooks** in a trusted workspace. Local's
`chat.useHooks` must be enabled. Run `wv init-repo --agent=copilot --update`
to refresh this managed file; other JSON hook files are preserved.

These are native Local hooks, not Copilot Agent Host SDK registrations. Hook
payloads, tool names and output decisions differ between harnesses. Inspect
the Local agent debug logs to confirm the tools in use are classified by the
shared guards; fixture parity does not prove that the live host fired a hook.

Claude's personal hooks do not fire here by default. If `chat.useClaudeHooks`
is enabled, avoid registering the same Weave guards twice.

Reference: https://code.visualstudio.com/docs/agents/reference/hooks-reference
GHHOOKSEOF
        echo -e "  ${GREEN}✓${NC} .github/hooks/ (VS Code hook directory scaffolded)"
    fi
    if [ ! -f "$REPO_ROOT/.github/hooks/weave.json" ] || [ "$UPDATE_MODE" = "1" ]; then
        _vscode_hooks=$(cat <<'VSCODEHOOKSEOF'
{
  "hooks": {
    "SessionStart": [{"type": "command", "command": "wv hook dispatch --event=SessionStart --format=vscode", "timeout": 120}],
    "PreToolUse": [{"type": "command", "command": "wv hook dispatch --event=PreToolUse --format=vscode", "timeout": 30}],
    "PostToolUse": [{"type": "command", "command": "wv hook dispatch --event=PostToolUse --format=vscode", "timeout": 30}],
    "PreCompact": [{"type": "command", "command": "wv hook dispatch --event=PreCompact --format=vscode", "timeout": 30}],
    "Stop": [{"type": "command", "command": "wv hook dispatch --event=Stop --format=vscode", "timeout": 30}]
  }
}
VSCODEHOOKSEOF
)
        # Source checkouts must test their own CLI; consumer repos use PATH.
        _vscode_wv=wv
        if [ -x "$REPO_ROOT/scripts/wv" ] && [ -f "$REPO_ROOT/scripts/lib/wv-config.sh" ]; then
            _vscode_wv='"$(git rev-parse --show-toplevel)/scripts/wv"'
        fi
        # shellcheck disable=SC2016  # $wv is a jq variable
        jq --arg wv "$_vscode_wv" '.hooks[][] |= (.command |= sub("^wv "; $wv + " "))' \
            <<<"$_vscode_hooks" > "$REPO_ROOT/.github/hooks/weave.json"
        echo -e "  ${GREEN}✓${NC} .github/hooks/weave.json (VS Code Local hooks; review before use)"
    else
        echo -e "  ${YELLOW}⊘${NC} .github/hooks/weave.json (already exists, use --update to refresh)"
    fi

    # ── copilot-instructions.md (marker-aware — preserves repo content outside markers) ──
    mkdir -p "$REPO_ROOT/.github"
    _STUB_TEMPLATE="$CONFIG_DIR/copilot-instructions.stub.md"

    # Build managed block from installed template or inline fallback. BOTH go
    # through _wv_localize_agent_block: the fallback is a copy of the shipped
    # stub, so it describes a consumer -- installed binary, "does not vendor
    # weave's own scripts/wv" -- and rendering it unlocalized in the weave
    # source checkout wrote guidance that was false there, the same way the
    # template branch did before it was localized. One correction, one path.
    if [ -f "$_STUB_TEMPLATE" ]; then
        _copilot_block=$(_wv_localize_agent_block "$(cat "$_STUB_TEMPLATE")")
    else
        _copilot_block=$(_wv_localize_agent_block "$(cat << 'COPILOTEOF'
<!-- ── BEGIN WEAVE COPILOT.MD ── managed by wv init-repo, do not edit manually -->
# GitHub Copilot Instructions

This repository uses **Weave** for task tracking. Every code change must be tracked.

## Pre-flight (run before anything else)

```bash
if ! command -v wv >/dev/null 2>&1; then wv() { "$HOME/.local/bin/wv" "$@"; }; fi
wv bootstrap --json   # single call: active/ready/blocked + learnings + context policy
```

If 0 active nodes, claim one before touching files:

```bash
wv search "<topic>"        # check for existing related work before claiming/creating
wv ready                  # list unblocked work
wv work <id>              # claim it
```

## Before every file edit

Call `weave_edit_guard` (MCP) before any edit. If blocked, claim a task first.

## Core loop

```bash
wv work <id>                                             # 1. claim
# ... edit files ...
git add <files> && git commit -m "..."                   # 2. commit BEFORE wv done
wv done <id> --learning="..." --no-overlap-check         # 3. close (no prompts)
wv sync --gh && git add .weave/                          # 4a. sync graph (may dirty .weave/)
git diff --cached --quiet || git commit -m "chore(weave): sync state [skip ci]"  # 4b. commit if dirty
git push                                                 # 4c. MANDATORY
```

> **Order matters**: commit first, then `wv done`, then sync+push. Never reverse steps 2–4.

## Shortcuts

```bash
# Trivial one-file work (no open GH issue needed):
wv quick "<description>" --learning="..."

# Done + sync in one step (check `wv status` for pending Git sync):
wv ship <id> --learning="..." --no-overlap-check

# Create a standalone node without a parent (persists intentional standalone metadata):
wv add "<description>" --standalone
# `wv health` reports these as intentional_standalones, not orphan_nodes.
```

## Sync modes

`wv sync --gh` accepts `--mode=fast|full|repair` (and an optional `--node=<id>` focus):

- `fast` — default for `wv ship` and session-end; bounded to focus + impacted set.
- `full` — explicit default for plain `wv sync --gh`; exhaustive reconcile.
- `repair` — resumes from `.weave/repair-checkpoint.json` after an interrupted/crashed sync.
  `wv recover` and the stop-hook recommend this when the checkpoint exists.

## Context pack for complex nodes

Before starting non-trivial work, load the context pack:

```bash
wv bootstrap --json        # preferred session-start snapshot (single call)
wv context <id> --json    # ancestors, blockers, pitfalls — cached per session
```

Use `wv touch <id> --intent="..."` for low-cost intent/progress updates between larger steps.

## Learnings format

Structured learnings are more useful for future sessions:

```
--learning="decision: X | pattern: Y | pitfall: Z"
```

For non-interactive agent flows, prefer `--no-overlap-check` on `wv done`/`wv ship` once
verification and learnings are ready.

## Code search

If `wv index` has been run, use hybrid code search instead of file browsing:

```bash
wv search --code "query"             # hybrid BM25 + cosine (CLI)
wv search --code "query" --mode=fts  # exact tokens / function names
```

MCP equivalent: `weave_code_search` (parameters: `query`, `mode`, `limit`, `graph`).

## Reference

- MCP: `weave_guide` (topics: workflow, github, learnings, context)
- CLI: `wv --help`, `wv help <command>`, or `~/.config/weave/WORKFLOW.md`
<!-- ── END WEAVE COPILOT.MD ── -->
COPILOTEOF
)")
    fi

    _cop_dst="$REPO_ROOT/.github/copilot-instructions.md"
    if [ ! -f "$_cop_dst" ]; then
        printf '%s\n' "$_copilot_block" > "$_cop_dst"
        echo -e "  ${GREEN}✓${NC} .github/copilot-instructions.md (created)"
    elif grep -q 'BEGIN WEAVE COPILOT\.MD' "$_cop_dst"; then
        # Existing with markers: surgical replace using awk (no sed 1,/REGEX/ first-line gotcha)
        _cop_before=$(awk '/BEGIN WEAVE COPILOT\.MD/{exit} {print}' "$_cop_dst")
        _cop_after=$(awk '/END WEAVE COPILOT\.MD/{found=1; next} found{print}' "$_cop_dst")
        {
            [ -n "$_cop_before" ] && printf '%s\n' "$_cop_before"
            printf '%s\n' "$_copilot_block"
            [ -n "$_cop_after" ] && printf '%s\n' "$_cop_after"
        } > "$_cop_dst"
        echo -e "  ${GREEN}✓${NC} .github/copilot-instructions.md (Weave block updated)"
    elif grep -qE 'weave_edit_guard|wv status.*active node|git status.*&&.*wv status' "$_cop_dst" \
         && [ "$UPDATE_MODE" = "1" ]; then
        # Pre-marker Weave stub (Weave workflow fingerprint, no markers yet): add managed markers
        # without discarding possible user customizations mixed into the old unmarked file.
        _cop_existing=$(cat "$_cop_dst")
        { printf '%s\n\n' "$_copilot_block"; printf '%s\n' "$_cop_existing"; } > "$_cop_dst"
        echo -e "  ${GREEN}✓${NC} .github/copilot-instructions.md (pre-marker Weave block marked; existing content preserved)"
    elif [ "$UPDATE_MODE" = "1" ] || [ "$FORCE_MODE" = "1" ]; then
        # User-written file without markers + --update/--force: prepend block
        _cop_existing=$(cat "$_cop_dst")
        { printf '%s\n\n' "$_copilot_block"; printf '%s\n' "$_cop_existing"; } > "$_cop_dst"
        echo -e "  ${GREEN}✓${NC} .github/copilot-instructions.md (Weave block prepended)"
    else
        echo -e "  ${YELLOW}⊘${NC} .github/copilot-instructions.md (exists without Weave block — use --update to prepend)"
    fi
    _refresh_memory_projection copilot "$_cop_dst"

fi

if [ "$AGENT" = "codex" ]; then
    echo ""
    echo "Configuring Codex setup contract..."

    _CODEX_DIR="$REPO_ROOT/.codex"
    _CODEX_CONTRACT="$_CODEX_DIR/weave.json"
    CODEX_HOOKS_ENABLED="$CODEX_HOOKS"
    [ ! -f "$_CODEX_DIR/hooks.json" ] || CODEX_HOOKS_ENABLED=1

    _write_codex_contract() {
        mkdir -p "$_CODEX_DIR"
        cat > "$_CODEX_CONTRACT" << CODEXEOF
{
  "schema": "weave.codex.v1",
  "bootstrap": {
    "command": "./scripts/wv bootstrap-agent --json",
    "fallback": "\$HOME/.local/bin/wv bootstrap-agent --json"
  },
  "doctor": {
    "command": "./scripts/wv doctor --agent --json",
    "fallback": "\$HOME/.local/bin/wv doctor --agent --json"
  },
  "runtime": {
    "hot_zone": "shared",
    "expected_prefix": "/tmp/weave-hotzone-\${uid}",
    "prefer_repo_local_wv": true
  },
  "hooks": {
    "enabled": $CODEX_HOOKS_ENABLED,
    "config": ".codex/hooks.json",
    "trust_command": "/hooks",
    "requires_review": true,
    "dispatcher": "./scripts/wv hook dispatch"
  },
  "workflow": {
    "universal_instructions": "AGENTS.md",
    "no_edits_without_active_node": true,
    "noninteractive_close": "./scripts/wv ship-agent"
  },
  "memory": {
    "authority": "weave-graph",
    "lifecycle_field": "metadata.mem_status",
    "policy": "codex-local memory is evidence; weave graph is authority",
    "capture": {
      "command": "./scripts/wv remember --json",
      "fallback": "\$HOME/.local/bin/wv remember --json"
    },
    "recall": {
      "command": "./scripts/wv memory recall --agent=all --json",
      "fallback": "\$HOME/.local/bin/wv memory recall --agent=all --json"
    },
    "scan": {
      "command": "./scripts/wv memory scan --source=codex --json",
      "fallback": "\$HOME/.local/bin/wv memory scan --source=codex --json"
    },
    "import": {
      "command": "./scripts/wv memory import --source=codex --json",
      "fallback": "\$HOME/.local/bin/wv memory import --source=codex --json"
    },
    "crystallize": {
      "command": "./scripts/wv memory crystallize --json",
      "fallback": "\$HOME/.local/bin/wv memory crystallize --json"
    }
  },
  "commands": {
    "claim": "./scripts/wv work <id>",
    "record_edit": "./scripts/wv touch <id> --files=<path>",
    "close": "./scripts/wv ship-agent <id> --learning-file=<path> --verification-method=<cmd> --verification-evidence-file=<path> --json",
    "local_sync": "./scripts/wv sync --mode=fast --node=<id>",
    "github_sync": "./scripts/wv sync --gh --mode=fast --node=<id>",
    "push": "git push"
  },
  "mcp": {
    "default_registration": "weave-lite",
    "recommended_scope": "lite",
    "read_only": "weave-inspect",
    "full_requires": "--codex-mcp=full",
    "network_policy": "Use CLI for GitHub sync, git push, and other privileged/network operations."
  },
  "github_sync": {
    "local_first": "./scripts/wv sync",
    "external_network": "./scripts/wv sync --gh",
    "requires_sandbox_approval": true,
    "failure_policy": "local .weave sync remains valid; rerun external_network with network/SSH approval"
  }
}
CODEXEOF
    }

    _write_codex_hooks() {
        mkdir -p "$_CODEX_DIR"
        cat > "$_CODEX_DIR/hooks.json" <<'CODEXHOOKSEOF'
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|resume|clear|compact",
        "hooks": [
          {
            "type": "command",
            "command": "\"$(git rev-parse --show-toplevel)/scripts/wv\" hook dispatch --event=SessionStart --format=host",
            "timeout": 120,
            "statusMessage": "Loading Weave context"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Bash|apply_patch|Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "\"$(git rev-parse --show-toplevel)/scripts/wv\" hook dispatch --event=PreToolUse --format=host",
            "timeout": 30,
            "statusMessage": "Checking Weave active node"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Bash|apply_patch|Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "\"$(git rev-parse --show-toplevel)/scripts/wv\" hook dispatch --event=PostToolUse --format=host",
            "timeout": 30,
            "statusMessage": "Recording Weave edit context"
          }
        ]
      }
    ],
    "PreCompact": [
      {
        "matcher": "manual|auto",
        "hooks": [
          {
            "type": "command",
            "command": "\"$(git rev-parse --show-toplevel)/scripts/wv\" hook dispatch --event=PreCompact --format=host",
            "timeout": 30,
            "statusMessage": "Checkpointing Weave state"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "\"$(git rev-parse --show-toplevel)/scripts/wv\" hook dispatch --event=Stop --format=host",
            "timeout": 30,
            "statusMessage": "Checking Weave close state"
          }
        ]
      }
    ]
  }
}
CODEXHOOKSEOF
    }

    if [ ! -f "$_CODEX_CONTRACT" ] || [ "$UPDATE_MODE" = "1" ] || [ "$FORCE_MODE" = "1" ] || [ "$CODEX_HOOKS" = "1" ]; then
        _write_codex_contract
        echo -e "  ${GREEN}✓${NC} .codex/weave.json"
        # memory.entries[] is not part of this template: wv memory render
        # --agent=codex fills it from the graph. Rewriting the contract without
        # re-rendering emptied the Codex agent's memory on every --update
        # (wv-2ab164). A repo with no graph yet renders an empty list.
        if [ -x "$WV_BIN" ]; then
            if (cd "$REPO_ROOT" && "$WV_BIN" memory render --agent=codex >/dev/null 2>&1); then
                echo -e "  ${GREEN}✓${NC} .codex/weave.json memory entries (rendered from the graph)"
            else
                echo -e "  ${YELLOW}⚠${NC} .codex/weave.json memory entries not rendered - run: wv memory render --agent=codex"
            fi
        fi
    else
        echo -e "  ${YELLOW}⊘${NC} .codex/weave.json (already exists, use --update to refresh)"
    fi

    if [ "$CODEX_HOOKS" = "1" ]; then
        _write_codex_hooks
        echo -e "  ${GREEN}✓${NC} .codex/hooks.json"
        echo "  Review and trust these project hooks with /hooks before expecting enforcement."
    else
        echo -e "  ${YELLOW}⊘${NC} codex hooks: skipped (use --codex-hooks to generate for review)"
    fi

    # Optional: register a scoped Weave MCP server with Codex. Codex sandbox
    # approvals apply cleanly to CLI commands, not MCP tool calls, so default to
    # the narrow lite scope and require an explicit full-scope opt-in.
    if [ -z "$CODEX_MCP_SCOPE" ]; then
        echo -e "  ${YELLOW}⊘${NC} codex mcp: skipped (use --codex-mcp to register weave-lite)"
    elif command -v codex >/dev/null 2>&1; then
        _mcp_server=""
        if [ -f "$WV_LIB_DIR/mcp/dist/index.js" ]; then
            _mcp_server="$WV_LIB_DIR/mcp/dist/index.js"
        elif [ -f "$REPO_ROOT/mcp/dist/index.js" ]; then
            _mcp_server="$REPO_ROOT/mcp/dist/index.js"
        fi
        if [ -n "$_mcp_server" ]; then
            _codex_mcp_name="weave-lite"
            _codex_mcp_scope="lite"
            if [ "$CODEX_MCP_SCOPE" = "inspect" ]; then
                _codex_mcp_name="weave-inspect"
                _codex_mcp_scope="inspect"
            elif [ "$CODEX_MCP_SCOPE" = "full" ]; then
                _codex_mcp_name="weave"
                _codex_mcp_scope="all"
            fi
            if [ "$_codex_mcp_name" != "weave" ] && codex mcp list 2>/dev/null | grep -q '^weave[[:space:]]'; then
                codex mcp remove weave >/dev/null 2>&1 \
                    && echo -e "  ${GREEN}✓${NC} codex mcp: removed stale full weave registration"
            fi
            codex mcp add "$_codex_mcp_name" \
                --env "WV_PATH=$WV_BIN" \
                --env "WV_PROJECT_DIR=$REPO_ROOT" \
                -- node "$_mcp_server" "--scope=$_codex_mcp_scope" 2>/dev/null \
                && echo -e "  ${GREEN}✓${NC} codex mcp: $_codex_mcp_name registered (--scope=$_codex_mcp_scope)" \
                || echo -e "  ${YELLOW}⊘${NC} codex mcp add $_codex_mcp_name skipped (already registered or error)"
        else
            echo -e "  ${YELLOW}⊘${NC} codex mcp: MCP server not built — run 'npm run build' in mcp/ first"
        fi
    else
        echo -e "  ${YELLOW}⊘${NC} codex mcp: codex command not found"
    fi
fi

done  # end for AGENT in AGENTS

# ── .weave/gate-provision.proposed.json (gate provisioning S4, wv-0ee3f4) ──
# A declaration proposed from the lockfiles found, never the declaration itself:
# adopting a suite is the repository's decision (transition rule 1), so the
# proposal sits beside .weave/gate-provision.json for review, and only while no
# declaration exists. Agent-neutral: the gate reads gate-provision.json alone.
#
# The proposal is machine-local (in WV_RUNTIME_IGNORES, so neither git status
# nor wv doctor reads it as graph dirt) and a repository declines it durably
# with a tracked .weave/gate-provision.declined file, which stops it being
# written again (wv-0f6962: five consumers sat dirty_weave on an unadopted
# proposal after the rc.15 rollout).
_gp_propose="${REPO_CLASS_LIB%/*}/wv-gate-propose.py"
if [ -e "$REPO_ROOT/.weave/gate-provision.declined" ]; then
    rm -f "$REPO_ROOT/.weave/gate-provision.proposed.json"
    echo -e "  ${YELLOW}⊘${NC} gate provisioning: declined by .weave/gate-provision.declined; no proposal written"
elif [ -f "$_gp_propose" ] && [ ! -e "$REPO_ROOT/.weave/gate-provision.json" ]; then
    _gp_notes=$(mktemp)
    if _gp_out=$(python3 -I "$_gp_propose" "$REPO_ROOT" 2>"$_gp_notes") && [ -n "$_gp_out" ]; then
        mkdir -p "$REPO_ROOT/.weave"
        printf '%s\n' "$_gp_out" > "$REPO_ROOT/.weave/gate-provision.proposed.json"
        echo -e "  ${GREEN}✓${NC} .weave/gate-provision.proposed.json (ignored by git; adopt: rename it to gate-provision.json and its suites run frozen from the next commit; decline: write .weave/gate-provision.declined with the reason and commit it)"
    fi
    sed 's/^/  ⊘ /' "$_gp_notes"
    rm -f "$_gp_notes"
fi

# Procedure bodies live in the installed config; this projects only the adapter
# requested by init-repo. AGENTS.md stays user-owned: only a WEAVE PROCEDURES
# block the file already carries is refreshed, never created (wv-6ef83b).
if [ -x "$CONFIG_DIR/project-procedures.sh" ]; then
    "$CONFIG_DIR/project-procedures.sh" --repo="$REPO_ROOT" --agent="$AGENT_ARG"
fi

# ── Summary ──
echo ""
if [ "$UPDATE_MODE" = "1" ]; then
    echo -e "${GREEN}✓ Weave updated in $REPO_ROOT (agent=$AGENT_LABEL)${NC}"

    # An update refreshes what the repository had adopted; anything it created
    # that was not there before is an addition, and is reported as one so the
    # operator sees the scaffold grew (wv-ef9ba9: a never-fully-scaffolded
    # consumer gained 53 files from an --update with nothing in the summary to
    # say so). The set is the difference of two file listings taken around the
    # run, so every write site is covered without instrumenting each one.
    if [ -n "${_IR_FILES_BEFORE:-}" ] && [ -f "$_IR_FILES_BEFORE" ]; then
        _ir_added=$(cd "$REPO_ROOT" && find . -path ./.git -prune -o -type f -print 2>/dev/null | sort | comm -13 "$_IR_FILES_BEFORE" - | sed 's#^\./##')
        rm -f "$_IR_FILES_BEFORE"
        if [ -n "$_ir_added" ]; then
            echo ""
            echo -e "${YELLOW}⚠ Added by this update (not present before, beyond a refresh): $(printf '%s\n' "$_ir_added" | wc -l | tr -d ' ') file(s)${NC}"
            printf '%s\n' "$_ir_added" | head -40 | sed 's/^/  + /'
            [ "$(printf '%s\n' "$_ir_added" | wc -l)" -gt 40 ] && echo "  + ..."
        fi
    fi

    # Warn about unstaged changes from update. Include scripts/hooks/ — the
    # vendor refresh now seeds/refreshes hook SOURCES there (e.g. a newly added
    # post-commit-weave.sh), which the old .claude/.github/.vscode glob missed.
    local_changes=$(cd "$REPO_ROOT" && git diff --name-only 2>/dev/null; git ls-files --others --exclude-standard .claude/ .github/ .vscode/ .weave/patterns/ .weave/guides/ .weave/guides.README.md scripts/hooks/ 2>/dev/null || true)
    if [ -n "$local_changes" ]; then
        echo ""
        echo -e "${YELLOW}⚠ Unstaged scaffolding changes from update:${NC}"
        echo "$local_changes" | while read -r f; do echo "  $f"; done
        # The consumer's own Weave pre-commit hook blocks a commit without an
        # active node, and a repo with active epics needs --standalone to claim,
        # so the bare `git commit` the hint used to print just hits that wall.
        # Give a sequence that actually lands the commit.
        echo -e "${YELLOW}  To commit (the Weave pre-commit hook needs an active node):${NC}"
        echo "    wv add \"chore: sync Weave scaffolding\" --standalone --alias=weave-scaffold \\"
        echo "      --status=active --criteria=\"scaffolding synced\" --risks=low"
        echo "    git add -A .claude/ .github/ .vscode/ .weave/patterns/ .weave/guides/ .weave/guides.README.md scripts/hooks/ .gitignore && git commit -m \"chore(weave): sync scaffolding\""
        echo "    wv done <node-id> --skip-verification        # <node-id> from the wv add line above"
        echo -e "${YELLOW}  Quick path (no node): WV_SKIP_PRECOMMIT=1 git add -A … && git commit -m '…'${NC}"
    fi
else
    echo -e "${GREEN}✓ Weave initialized in $REPO_ROOT (agent=$AGENT_LABEL)${NC}"
fi
echo "  .weave/         — graph storage"
echo "  .weave/patterns/managed/ — curated shared quality rules"
echo "  .weave/guides/ — write coaching prose this repo needs; see .weave/guides.README.md"
echo "  .gitignore      — Weave entries added"
for _a in "${AGENTS[@]}"; do
    if [ "$_a" = "claude" ]; then
        echo "  .claude/hooks/   — session lifecycle hooks"
        echo "  .claude/skills/  — on-demand skills"
        echo "  CLAUDE.md        — agent instructions"
    elif [ "$_a" = "copilot" ]; then
        echo "  .vscode/mcp.json — VS Code workspace MCP config"
        echo "  .mcp.json — Copilot MCP config (legacy/root)"
        echo "  .github/copilot-instructions.md — Minimal stub (workflow via weave_guide)"
        echo "  .github/hooks/ — VS Code native hook location"
    elif [ "$_a" = "codex" ]; then
        echo "  .codex/weave.json — Codex setup contract (AGENTS.md remains universal)"
        [ "$CODEX_HOOKS" != "1" ] || echo "  .codex/hooks.json — project lifecycle hooks (review/trust with /hooks)"
    fi
done
# Advisory only: ignored checkout paths cannot appear in a frozen suite tree.
_gate_paths=""
if _gate_paths=$(python3 -I "${REPO_CLASS_LIB%/*}/wv-gate-paths.py" "$REPO_ROOT" 2>&1); then
    [ -z "$_gate_paths" ] || printf '  ⚠ gate ignored paths: %s\n' "$_gate_paths"
else
    printf '  ⚠ gate ignored paths: %s\n' "$_gate_paths"
fi
# Note whether code search index exists
if [ -x "$(command -v wv 2>/dev/null)" ]; then
    _chunks_count=$(wv hotzone db 2>/dev/null | xargs -I{} sqlite3 {} "SELECT COUNT(*) FROM chunks" 2>/dev/null || echo "0")
    if [ "${_chunks_count:-0}" -gt 0 ]; then
        echo "  code index      — ${_chunks_count} chunks indexed (wv search --code enabled)"
    else
        echo "  code index      — not built. Run: wv index . (enables wv search --code)"
    fi
fi
INITEOF

chmod +x "$INSTALL_DIR/wv-init-repo"
echo "$INSTALL_DIR/wv-init-repo" >> "$MANIFEST"

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
echo "$INSTALL_DIR/wv-update" >> "$MANIFEST"

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
            # Refresh the repo-local ./mcp/dist too: git does not track it, but
            # vitest (SERVER_PATH) and the .mcp.json repo fallback read it — a
            # stale checkout dist shipped an old server to dev (wv-0cd7f8).
            if [ -d "./mcp/node_modules" ]; then
                (cd ./mcp && npm run build --silent 2>&1 | tail -1) || true
            fi
            cp ./mcp/package.json ./mcp/tsconfig.json "$mcp_dir/" 2>/dev/null || true
            cp -r ./mcp/src "$mcp_dir/" 2>/dev/null || true
            (cd "$mcp_dir" && npm install --production=false --silent 2>&1 | tail -1 && npm run build --silent 2>&1) && {
                echo -e "${GREEN}✓ MCP server built${NC}"
                echo -e "${YELLOW}  ↻ Restart your Claude session for MCP changes to take effect${NC}"
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
                echo -e "${YELLOW}  ↻ Restart your Claude session for MCP changes to take effect${NC}"
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

# ast-grep (optional — enables wv quality structural-search + accurate bash CC)
_install_ast_grep() {
    local ag_bin="$INSTALL_DIR/ast-grep"
    if command -v ast-grep >/dev/null 2>&1; then
        echo -e "${GREEN}✓ ast-grep already available: $(command -v ast-grep)${NC}"
        return 0  # already on PATH
    fi
    if [ -x "$ag_bin" ]; then
        echo -e "${GREEN}✓ ast-grep already installed: $ag_bin${NC}"
        return 0  # already installed by us
    fi

    if [ "${WITH_AST_GREP:-0}" != "1" ]; then
        echo -e "${YELLOW}⊘ ast-grep not installed (optional; no download attempted)${NC}"
        echo "  Enables structural-search and AST-accurate Bash/TypeScript quality scans."
        echo "  To install explicitly: ./install.sh --with-ast-grep"
        echo "  Or install yourself: cargo install ast-grep --locked"
        return 0
    fi

    # Try cargo first (self-updating, version-agnostic)
    if command -v cargo >/dev/null 2>&1; then
        echo -e "${CYAN}Installing ast-grep via cargo...${NC}"
        cargo install ast-grep --quiet 2>/dev/null && {
            # symlink into INSTALL_DIR if cargo bin differs
            local cargo_bin
            cargo_bin=$(command -v ast-grep 2>/dev/null || echo "")
            if [ -n "$cargo_bin" ] && [ "$cargo_bin" != "$ag_bin" ]; then
                ln -sf "$cargo_bin" "$ag_bin" 2>/dev/null || true
            fi
            echo -e "${GREEN}✓ ast-grep installed (via cargo)${NC}"
            return 0
        }
    fi
    # Fallback: prebuilt musl binary from GitHub releases
    local ag_version="0.42.3"
    local ag_url="https://github.com/ast-grep/ast-grep/releases/download/${ag_version}/ast-grep-x86_64-unknown-linux-musl.zip"
    if command -v curl >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1; then
        echo -e "${CYAN}Downloading ast-grep ${ag_version}...${NC}"
        local tmp_dir
        tmp_dir=$(mktemp -d)
        if curl -fsSL --retry 3 "$ag_url" -o "$tmp_dir/ast-grep.zip" && \
           unzip -tq "$tmp_dir/ast-grep.zip" >/dev/null && \
           unzip -q "$tmp_dir/ast-grep.zip" -d "$tmp_dir" && \
           mv "$tmp_dir/ast-grep" "$ag_bin" 2>/dev/null && \
           chmod +x "$ag_bin"; then
            rm -rf "$tmp_dir"
            echo -e "${GREEN}✓ ast-grep ${ag_version} installed to $ag_bin${NC}"
            return 0
        fi
        rm -rf "$tmp_dir"
    fi
    echo -e "${YELLOW}⚠ ast-grep not installed (optional) — structural-search + accurate bash CC unavailable${NC}"
    echo "  Install manually: cargo install ast-grep --locked"
    return 0
}

if [ "${SKIP_AST_GREP:-0}" != "1" ]; then
    echo ""
    if [ "${WITH_AST_GREP:-0}" = "1" ]; then
        echo -e "${CYAN}━━━ ast-grep (optional, explicit install) ━━━${NC}"
    else
        echo -e "${CYAN}━━━ ast-grep (optional) ━━━${NC}"
    fi
    _install_ast_grep
fi

echo ""
echo -e "${GREEN}━━━ Installation Complete ━━━${NC}"
echo ""
echo "Commands installed:"
echo "  wv            — Core CLI ($("$INSTALL_DIR/wv" --version 2>/dev/null || echo "unknown version"))"
echo "  wv-test       — Isolated test runner"
echo "  (wv-runtime retired — use python -m weave_runtime from standalone repo)"
echo "  wv init-repo  — Initialize Weave in a new repo"
echo "  wv-update     — Update Weave to latest version"
[ "$WITH_MCP" = "1" ] && [ -f "$LIB_DIR/mcp/dist/index.js" ] && \
    echo "  weave-mcp     — MCP server ($LIB_DIR/mcp/dist/index.js)"
echo ""
echo "To set up a new repo:"
echo "  cd /path/to/your/repo"
echo "  wv init-repo"
echo ""
echo -e "${YELLOW}Existing Weave repositories require a managed-asset refresh after install:${NC}"
echo "  cd /path/to/existing/repo && wv init-repo --update"

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
WITH_AST_GREP="${WITH_AST_GREP:-0}"
VERIFY=0
LOCAL_SOURCE=""

# Parse arguments
action=""
for arg in "$@"; do
    case "$arg" in
        --dev)              DEV_MODE=1 ;;
        --with-mcp)         WITH_MCP=1 ;;
        --no-mcp)           WITH_MCP=0; NO_MCP_EXPLICIT=1 ;;
        --with-ast-grep)    WITH_AST_GREP=1 ;;
        --no-ast-grep)      SKIP_AST_GREP=1 ;;
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
        echo "  --with-ast-grep    Install optional ast-grep helper (may use cargo/GitHub network)"
        echo "  --no-ast-grep      Skip ast-grep detection/install messaging"
        echo "  --verify           Run wv selftest after install to verify"
        echo "  --local-source=DIR Install from DIR instead of current directory"
        echo "  --uninstall        Remove manifest-tracked files (preserves ~/.config/weave; see output for manual cleanup)"
        echo "  --upgrade          Pull latest and reinstall"
        echo "  --check-deps       Check required dependencies"
        echo "  --help             Show this help"
        ;;
    install)    do_install ;;
esac
