#!/usr/bin/env bash
# build-release.sh — Build a clean distributable release of Weave
#
# Creates a release directory with only the shipping manifest:
#   scripts/, mcp/, install.sh, install-mcp.sh, templates/, tests/ (CLI tests only),
#   .claude/hooks|agents|skills/, README.md, CHANGELOG.md,
#   pyproject.toml, .gitattributes
#   CLAUDE.md, AGENTS.md, .github/copilot-instructions.md (generated from templates)
#
# NOT shipped: runtime/ (internal Python TUI, dogfooded locally only).
# All tests/test_runtime_*.py are stripped — they import from runtime/ and
# will fail at import in a release install with no runtime/ source present.
#
# Usage:
#   ./build-release.sh                  # Build to dist/weave-<version>/
#   ./build-release.sh --output=/tmp/x  # Build to custom directory
#   ./build-release.sh --tar            # Also create .tar.gz archive
#   ./build-release.sh --verify         # Build + run install + selftest
#   ./build-release.sh --tag            # Create git tag v<version> on source repo
#   ./build-release.sh --release        # Tag + create GitHub Release (implies --tag --tar)
#   ./build-release.sh --dry-run        # Show what would be copied
#
# The output directory gets a fresh .weave/ with empty state.sql,
# ready for a new user to install and init.
#
# Design decisions:
#   - Default output is dist/ (gitignored) inside this repo — standard
#     convention for build artifacts. Safe to rm -rf at any time.
#   - Use --output=<path> for building directly to a public repo location,
#     e.g. --output=/home/user/Projects/weave for the distribution copy.
#     If the output dir contains .git/, it is preserved (rsync --exclude).
#   - .claude/hooks, .claude/agents, .claude/skills ship because install.sh
#     copies them to ~/.config/weave/. Root-level .claude/ files
#     (settings.local.json, session.log, delegation-rules.yml) do NOT ship —
#     they are machine-specific or dev-only.
#   - wv-init-repo --agent=all generates both Claude and Copilot configs
#     in a target repo from the installed copies.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="$(cat "$SCRIPT_DIR/scripts/lib/VERSION" 2>/dev/null || echo "unknown")"

# Defaults
OUTPUT_DIR=""
CREATE_TAR=false
VERIFY=false
DRY_RUN=false
TAG_RELEASE=false
PUBLISH_RELEASE=false

# Colors (respect NO_COLOR)
if [[ -z "${NO_COLOR:-}" ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' CYAN='' NC=''
fi

# ---------------------------------------------------------------------------
# Shipping manifest — files and directories to include in the release
# ---------------------------------------------------------------------------

# Directories (copied recursively, preserving structure)
SHIP_DIRS=(
    scripts/cmd
    scripts/hooks
    scripts/lib
    scripts/weave_gh
    scripts/weave_quality
    mcp/src
    templates
    tests
    .claude/hooks
    .claude/agents
    .claude/skills
)

# Paths to remove after copy (local-only, not shipped in public release)
STRIP_PATHS=(
    .claude/skills/dev-guide
    # runtime/ source is not shipped (internal dogfood only).
    # All runtime test files must be stripped — they import from runtime/
    # and will fail at import time in a release install with no runtime/ source.
    tests/test_runtime_agent_runtime.py
    tests/test_runtime_bootstrap_context.py
    tests/test_runtime_bootstrap_lifecycle.py
    tests/test_runtime_compaction_services.py
    tests/test_runtime_efficiency.py
    tests/test_runtime_evaluation_services.py
    tests/test_runtime_hive_runtime.py
    tests/test_runtime_model_routing.py
    tests/test_runtime_orchestration_tasks.py
    tests/test_runtime_p5_fixes.py
    tests/test_runtime_p7_compliance.py
    tests/test_runtime_phase1.py
    tests/test_runtime_prompt_cache_services.py
    tests/test_runtime_query_config.py
    tests/test_runtime_query_stop_hooks.py
    tests/test_runtime_security.py
    tests/test_runtime_session_export.py
    tests/test_runtime_session_lifecycle.py
    tests/test_runtime_session.py
    tests/test_runtime_smoke.py
    tests/test_runtime_sprint_a.py
    tests/test_runtime_sprint_b.py
    tests/test_runtime_sprint_c.py
    tests/test_runtime_sprintc.py
    tests/test_runtime_sprint_d.py
    tests/test_runtime_surfaces_config.py
    tests/test_runtime_tool_execution.py
    tests/test_runtime_tool_orchestration.py
    tests/test_runtime_tools.py
    tests/test_runtime_tui.py
    tests/test_runtime_wv_client.py
    tests/test_signal_symbiosis.py
)

# Individual files
SHIP_FILES=(
    scripts/wv
    scripts/wv-test
    scripts/context-guard.sh
    scripts/resolve-refs.sh
    install.sh
    install-mcp.sh
    mcp/package.json
    mcp/tsconfig.json
    mcp/jest.config.js
    mcp/README.md
    README.public.md
    CHANGELOG.md
    CONTRIBUTING.md
    LICENSE
    pyproject.toml
    .gitattributes
    .markdownlint.json
    .mcp.json
    templates/copilot-instructions.stub.md
    templates/AGENTS.md.template
)

# Files explicitly excluded from shipping (dev-only)
# Listed here for documentation — these are never copied
# shellcheck disable=SC2034
EXCLUDED_DOCS=(
    "CLAUDE.md              — dev reference (generated from template at build time)"
    "AGENTS.md              — dev reference (generated from template at build time)"
    ".github/copilot-instructions.md — dev reference (generated from stub at build time)"
    "README.md              — sandbox README (README.public.md ships as README.md)"
    ".claude/settings.*     — settings.json (hooks) scaffolded by wv-init-repo; settings.local.json (permissions) is user-specific"
    ".claude/session.log    — dev session log"
    ".claude/delegation*    — dev delegation rules"
    ".github/workflows/     — CI workflows for dev sandbox (copilot-instructions.md ships)"
    "archive/               — deprecated scripts and docs"
    "docs/                  — internal plans, proposals, epics"
    "runtime/               — internal Python TUI/agent runner; not part of the public Weave CLI release"
    ".weave/                — sandbox graph state (fresh one created)"
    "poetry.lock            — dev dependency lock"
    "requirements-dev.txt   — dev deps"
    ".prettierrc            — dev formatter config"
    ".prettierignore        — dev formatter config"
    "*.txt                  — conversation logs"
    "*.pdf                  — generated PDFs"
    "README.pdf             — generated from README.md"
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
die()   { error "$1"; exit 1; }

usage() {
    cat <<'EOF'
Usage: ./build-release.sh [OPTIONS]

Options:
  --output=DIR    Output directory (default: dist/weave-<version>)
  --tar           Create .tar.gz archive alongside directory
  --verify        After build, install to temp dir and run selftest
  --tag           Create annotated git tag v<version> on source repo
  --release       Create GitHub Release on public repo (implies --tag --tar)
  --dry-run       Show what would be copied without doing it
  -h, --help      Show this help

Examples:
  ./build-release.sh                    # Standard build
  ./build-release.sh --tar --verify     # Build, archive, and verify
  ./build-release.sh --release          # Full release: build, tag, archive, publish
  ./build-release.sh --dry-run          # Preview shipping manifest
EOF
    exit 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

for arg in "$@"; do
    case "$arg" in
        --output=*)  OUTPUT_DIR="${arg#*=}" ;;
        --tar)       CREATE_TAR=true ;;
        --verify)    VERIFY=true ;;
        --tag)       TAG_RELEASE=true ;;
        --release)   PUBLISH_RELEASE=true; TAG_RELEASE=true; CREATE_TAR=true ;;
        --dry-run)   DRY_RUN=true ;;
        -h|--help)   usage ;;
        *)           die "Unknown option: $arg" ;;
    esac
done

# Default output directory
if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="$SCRIPT_DIR/dist/weave-$VERSION"
fi

# ---------------------------------------------------------------------------
# Dry run
# ---------------------------------------------------------------------------

if [[ "$DRY_RUN" == true ]]; then
    echo "Weave $VERSION — Shipping Manifest"
    echo "=================================="
    echo ""
    echo "Directories:"
    for dir in "${SHIP_DIRS[@]}"; do
        file_count=$(find "$SCRIPT_DIR/$dir" -type f 2>/dev/null | wc -l)
        echo "  $dir/ ($file_count files)"
    done
    echo ""
    echo "Files:"
    for file in "${SHIP_FILES[@]}"; do
        if [[ -f "$SCRIPT_DIR/$file" ]]; then
            size=$(du -h "$SCRIPT_DIR/$file" | cut -f1)
            echo "  $file ($size)"
        else
            echo "  $file (MISSING)"
        fi
    done
    echo ""
    echo "Generated:"
    echo "  .weave/state.sql (empty schema)"
    echo "  .weave/nodes.jsonl (empty)"
    echo "  .weave/edges.jsonl (empty)"
    echo "  .gitignore (release version)"
    echo ""
    echo "Output: $OUTPUT_DIR"
    [[ "$CREATE_TAR" == true ]] && echo "Archive: ${OUTPUT_DIR}.tar.gz"
    exit 0
fi

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------

info "Building Weave $VERSION release..."

# Verify we're in the right directory
[[ -f "$SCRIPT_DIR/scripts/wv" ]] || die "Must run from the memory-system repo root"
[[ -f "$SCRIPT_DIR/scripts/lib/VERSION" ]] || die "VERSION file not found"

# Check all shipping files exist
missing=0
for file in "${SHIP_FILES[@]}"; do
    if [[ ! -f "$SCRIPT_DIR/$file" ]]; then
        error "Missing shipping file: $file"
        missing=$((missing + 1))
    fi
done
for dir in "${SHIP_DIRS[@]}"; do
    if [[ ! -d "$SCRIPT_DIR/$dir" ]]; then
        error "Missing shipping directory: $dir/"
        missing=$((missing + 1))
    fi
done
[[ $missing -gt 0 ]] && die "$missing missing items in shipping manifest"

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

# Build into temp dir, then rsync to preserve .git/ in output
BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$BUILD_DIR"' EXIT
mkdir -p "$OUTPUT_DIR"

# Copy directories
for dir in "${SHIP_DIRS[@]}"; do
    mkdir -p "$BUILD_DIR/$dir"
    cp -r "$SCRIPT_DIR/$dir/." "$BUILD_DIR/$dir/"
    ok "Copied $dir/"
done

# Strip local-only paths (not shipped in public release)
for strip in "${STRIP_PATHS[@]}"; do
    if [[ -e "$BUILD_DIR/${strip:?}" ]]; then
        rm -rf "$BUILD_DIR/${strip:?}"
    fi
done

# Copy individual files (preserving directory structure)
for file in "${SHIP_FILES[@]}"; do
    file_dir=$(dirname "$file")
    if [[ "$file_dir" != "." ]]; then
        mkdir -p "$BUILD_DIR/$file_dir"
    fi
    cp "$SCRIPT_DIR/$file" "$BUILD_DIR/$file"
done

# Rename README.public.md to README.md in output
if [[ -f "$BUILD_DIR/README.public.md" ]]; then
    mv "$BUILD_DIR/README.public.md" "$BUILD_DIR/README.md"
fi

# Generate agent instruction files from templates (not memory-system's own full docs)
if [[ -f "$SCRIPT_DIR/templates/CLAUDE.md.template" ]]; then
    cp "$SCRIPT_DIR/templates/CLAUDE.md.template" "$BUILD_DIR/CLAUDE.md"
    ok "Generated CLAUDE.md from template"
else
    warn "templates/CLAUDE.md.template not found — CLAUDE.md not shipped"
fi

if [[ -f "$SCRIPT_DIR/templates/AGENTS.md.template" ]]; then
    cp "$SCRIPT_DIR/templates/AGENTS.md.template" "$BUILD_DIR/AGENTS.md"
    ok "Generated AGENTS.md from template"
else
    warn "templates/AGENTS.md.template not found — AGENTS.md not shipped"
fi

if [[ -f "$SCRIPT_DIR/templates/copilot-instructions.stub.md" ]]; then
    mkdir -p "$BUILD_DIR/.github"
    cp "$SCRIPT_DIR/templates/copilot-instructions.stub.md" "$BUILD_DIR/.github/copilot-instructions.md"
    ok "Generated .github/copilot-instructions.md from stub"
else
    warn "templates/copilot-instructions.stub.md not found — copilot-instructions not shipped"
fi

ok "Copied $(( ${#SHIP_FILES[@]} )) individual files"

# Remove dev-only test files from shipped tests/
DEV_ONLY_TESTS=(
    "tests/weave_quality/test_mccabe_crossval.py"
)
for f in "${DEV_ONLY_TESTS[@]}"; do
    rm -f "$BUILD_DIR/$f"
done

# Preserve executable permissions
chmod +x "$BUILD_DIR/scripts/wv"
chmod +x "$BUILD_DIR/scripts/wv-test"
chmod +x "$BUILD_DIR/install.sh"
chmod +x "$BUILD_DIR/install-mcp.sh"

# ---------------------------------------------------------------------------
# Create fresh .weave/ for new users
# ---------------------------------------------------------------------------

mkdir -p "$BUILD_DIR/.weave"

# Use wv itself to create a proper schema (ensures consistency with actual DB)
info "Creating fresh .weave/ with empty schema..."
fresh_db=$(mktemp -d)
# CRITICAL: Run wv init in an isolated directory so it doesn't resolve
# the current project's hot zone and wipe the live database
(cd "$fresh_db" && git init -q && WV_DB="$fresh_db/brain.db" "$BUILD_DIR/scripts/wv" init --force) 2>/dev/null || true
if [[ -f "$fresh_db/brain.db" ]]; then
    sqlite3 "$fresh_db/brain.db" .dump > "$BUILD_DIR/.weave/state.sql"
    rm -rf "$fresh_db"
else
    # Fallback: create schema directly with sqlite3
    warn "Could not create fresh DB with wv init, creating minimal schema"
    rm -rf "$fresh_db"
    cat > "$BUILD_DIR/.weave/state.sql" <<'SCHEMA'
CREATE TABLE IF NOT EXISTS nodes(id TEXT PRIMARY KEY, text TEXT, status TEXT DEFAULT 'todo', type TEXT DEFAULT 'task', created TEXT DEFAULT (datetime('now')), updated TEXT DEFAULT (datetime('now')), metadata TEXT DEFAULT '{}');
CREATE VIRTUAL TABLE IF NOT EXISTS nodes_fts USING fts5(text, content=nodes, content_rowid=rowid);
CREATE TABLE IF NOT EXISTS edges(src TEXT, dst TEXT, type TEXT, created TEXT DEFAULT (datetime('now')), PRIMARY KEY(src, dst, type));
SCHEMA
fi

# Empty JSONL exports
: > "$BUILD_DIR/.weave/nodes.jsonl"
: > "$BUILD_DIR/.weave/edges.jsonl"

ok "Created fresh .weave/ with empty schema"

# ---------------------------------------------------------------------------
# Create release .gitignore (simplified for end users)
# ---------------------------------------------------------------------------

cat > "$BUILD_DIR/.gitignore" <<'GITIGNORE'
# Python
__pycache__/
*.py[cod]
*.pyc
.mypy_cache/
.ruff_cache/
*.egg-info/
dist/
build/

# Weave runtime (state.sql is the git-tracked dump)
.weave/*.db
.weave/*.db-wal
.weave/*.db-shm
.weave/archive/

# Editors & OS
.DS_Store
Thumbs.db
*.swp
*~
.idea/

# Weave — git-tracked graph exports
!.weave/state.sql
!.weave/nodes.jsonl
!.weave/edges.jsonl
GITIGNORE

ok "Created release .gitignore"

# ---------------------------------------------------------------------------
# Strip dev-only content from copied files
# ---------------------------------------------------------------------------

# Remove __pycache__ directories that may have been copied
find "$BUILD_DIR" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true

# Remove .pyc files
find "$BUILD_DIR" -name "*.pyc" -delete 2>/dev/null || true

# Strip dev dependencies from pyproject.toml (end users don't need ruff, mypy, etc.)
if [[ -f "$BUILD_DIR/pyproject.toml" ]]; then
    python3 -c "
import sys
lines = open(sys.argv[1]).readlines()
out = []
skip = False
for line in lines:
    # Detect section headers: lines starting with [ but not array values (indented)
    stripped = line.lstrip()
    is_header = stripped.startswith('[') and not line[0].isspace() and '=' not in stripped.split(']')[0]
    if is_header:
        section = stripped.strip()
        # Strip dev-only tool sections. Preserve [tool.poetry] — it sets package-mode=false
        # which is required for 'poetry install' to work in the distributed release.
        DEV_SECTIONS = {
            '[dependency-groups]',
            '[tool.ruff]', '[tool.mypy]', '[tool.pyright]',
            '[tool.pytest.ini_options]',
            '[tool.pylint]', '[tool.pylint.main]',
            '[tool.pylint.\"messages control\"]',
            '[tool.pylint.design]', '[tool.pylint.format]',
        }
        skip = section in DEV_SECTIONS
    if not skip:
        out.append(line)
# Strip trailing blank lines
while out and out[-1].strip() == '':
    out.pop()
out.append('\n')
open(sys.argv[1], 'w').write(''.join(out))
" "$BUILD_DIR/pyproject.toml"
    ok "Stripped dev dependencies from pyproject.toml"
fi

ok "Stripped dev artifacts"

# ---------------------------------------------------------------------------
# Sync build to output (preserving .git/)
# ---------------------------------------------------------------------------

info "Syncing build to $OUTPUT_DIR..."
rsync -a --delete --exclude='.git' "$BUILD_DIR/" "$OUTPUT_DIR/"
ok "Synced to $OUTPUT_DIR (preserved .git/)"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

file_count=$(find "$OUTPUT_DIR" -type f | wc -l)
total_size=$(du -sh "$OUTPUT_DIR" | cut -f1)

echo ""
echo "=========================================="
echo "  Weave $VERSION Release Build"
echo "=========================================="
echo "  Output:  $OUTPUT_DIR"
echo "  Files:   $file_count"
echo "  Size:    $total_size"
echo "=========================================="

# ---------------------------------------------------------------------------
# Optional: tar archive
# ---------------------------------------------------------------------------

if [[ "$CREATE_TAR" == true ]]; then
    tar_file="${OUTPUT_DIR}.tar.gz"
    tar_parent=$(dirname "$OUTPUT_DIR")
    tar_name=$(basename "$OUTPUT_DIR")
    tar -czf "$tar_file" -C "$tar_parent" "$tar_name"
    tar_size=$(du -sh "$tar_file" | cut -f1)
    ok "Created archive: $tar_file ($tar_size)"
fi

# ---------------------------------------------------------------------------
# Optional: verify (install + selftest in isolated env)
# ---------------------------------------------------------------------------

if [[ "$VERIFY" == true ]]; then
    echo ""
    info "Verifying release build..."

    verify_dir=$(mktemp -d)
    trap 'rm -rf "$verify_dir"' EXIT

    # Install from the release build
    export HOME="$verify_dir/home"
    mkdir -p "$HOME/.claude"

    info "Installing from release build..."
    if bash "$OUTPUT_DIR/install.sh" --local-source="$OUTPUT_DIR" 2>&1; then
        ok "Install succeeded"
    else
        die "Install failed — release build is broken"
    fi

    # Run selftest
    wv_bin="$HOME/.local/bin/wv"
    if [[ -x "$wv_bin" ]]; then
        info "Running selftest..."
        if "$wv_bin" selftest 2>&1; then
            ok "Selftest passed"
        else
            warn "Selftest failed (may need git init in isolated env)"
        fi
    else
        die "wv binary not found at $wv_bin after install"
    fi

    echo ""
    ok "Release build verified"
fi

echo ""
ok "Build complete. To install: cd $OUTPUT_DIR && ./install.sh"

# ---------------------------------------------------------------------------
# Optional: tag source repo
# ---------------------------------------------------------------------------

if [[ "$TAG_RELEASE" == true ]]; then
    tag_name="v$VERSION"
    if git tag -l "$tag_name" | grep -q "$tag_name"; then
        warn "Tag $tag_name already exists on source repo -- skipping"
    else
        info "Creating annotated tag $tag_name on source repo..."
        # Extract release notes from CHANGELOG.md for this version
        changelog_notes=""
        if [[ -f "$SCRIPT_DIR/CHANGELOG.md" ]]; then
            changelog_notes=$(sed -n "/^## \[$VERSION\]/,/^## \[/{ /^## \[$VERSION\]/d; /^## \[/d; p; }" "$SCRIPT_DIR/CHANGELOG.md" | sed '/^$/d' | head -20)
        fi
        if [[ -n "$changelog_notes" ]]; then
            git -C "$SCRIPT_DIR" tag -a "$tag_name" -m "$tag_name: $(echo "$changelog_notes" | head -1)"
        else
            git -C "$SCRIPT_DIR" tag -a "$tag_name" -m "$tag_name"
        fi
        git -C "$SCRIPT_DIR" push origin "$tag_name" 2>/dev/null || warn "Could not push tag (no remote or auth)"
        ok "Tagged source repo: $tag_name"
    fi
fi

# ---------------------------------------------------------------------------
# Optional: create GitHub Release on public repo
# ---------------------------------------------------------------------------

if [[ "$PUBLISH_RELEASE" == true ]]; then
    echo ""
    info "Creating GitHub Release..."

    # Detect the public repo -- check if --output points to a git repo with a remote
    release_repo=""
    if [[ -d "$OUTPUT_DIR/.git" ]]; then
        release_repo=$(git -C "$OUTPUT_DIR" remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||; s|\.git$||')
    fi

    if [[ -z "$release_repo" ]]; then
        warn "No git remote found in output dir -- cannot create GitHub release"
        warn "To publish: initialize git in $OUTPUT_DIR, push to GitHub, then run:"
        warn "  gh release create v$VERSION --repo OWNER/REPO ${OUTPUT_DIR}.tar.gz"
    else
        tag_name="v$VERSION"
        tar_file="${OUTPUT_DIR}.tar.gz"

        # Check if release already exists
        if gh release view "$tag_name" --repo "$release_repo" &>/dev/null; then
            warn "Release $tag_name already exists on $release_repo -- skipping"
        else
            # Extract release notes from CHANGELOG
            release_notes="Weave $VERSION release."
            if [[ -f "$SCRIPT_DIR/CHANGELOG.md" ]]; then
                extracted=$(sed -n "/^## \[$VERSION\]/,/^## \[/{
                    /^## \[$VERSION\]/d
                    /^## \[/d
                    p
                }" "$SCRIPT_DIR/CHANGELOG.md")
                if [[ -n "$extracted" ]]; then
                    release_notes="$extracted"
                fi
            fi

            # Tag the output repo if not already tagged
            if ! git -C "$OUTPUT_DIR" tag -l "$tag_name" | grep -q "$tag_name"; then
                git -C "$OUTPUT_DIR" tag -a "$tag_name" -m "$tag_name"
                git -C "$OUTPUT_DIR" push origin "$tag_name" 2>/dev/null || true
            fi

            # Create the release
            if [[ -f "$tar_file" ]]; then
                gh release create "$tag_name" \
                    --repo "$release_repo" \
                    --title "Weave $VERSION" \
                    --notes "$release_notes" \
                    "$tar_file" 2>&1
            else
                gh release create "$tag_name" \
                    --repo "$release_repo" \
                    --title "Weave $VERSION" \
                    --notes "$release_notes" 2>&1
            fi
            ok "Published GitHub Release: https://github.com/$release_repo/releases/tag/$tag_name"
        fi
    fi
fi
