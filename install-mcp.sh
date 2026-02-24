#!/bin/bash
# Standalone MCP server installer for Weave
#
# Usage:
#   ./install-mcp.sh              Build and install MCP server
#   ./install-mcp.sh --verify     Build, install, and verify with wv mcp-status
#
# Requires: Node.js 18+, npm

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

VERIFY=0
for arg in "$@"; do
    case "$arg" in
        --verify) VERIFY=1 ;;
        --help|-h)
            echo "Weave MCP Server Installer"
            echo ""
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  (none)    Build and install MCP server"
            echo "  --verify  Also verify with wv mcp-status"
            echo "  --help    Show this help"
            exit 0
            ;;
    esac
done

echo -e "${CYAN}━━━ Weave MCP Server Installer ━━━${NC}"

# Check dependencies
if ! command -v node &>/dev/null; then
    echo -e "${RED}✗ node not found — MCP server requires Node.js 18+${NC}"
    echo "  Install from: https://nodejs.org/"
    exit 1
fi

if ! command -v npm &>/dev/null; then
    echo -e "${RED}✗ npm not found — MCP server requires npm${NC}"
    exit 1
fi

node_ver=$(node --version 2>/dev/null)
echo -e "  ${GREEN}✓${NC} node $node_ver"

# Determine paths
LIB_DIR="${WV_LIB_DIR:-$HOME/.local/lib/weave}"
MCP_DIR="$LIB_DIR/mcp"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$MCP_DIR"

# Build from local source or download
if [ -f "$SCRIPT_DIR/mcp/package.json" ]; then
    echo "Building from local source..."
    cp "$SCRIPT_DIR/mcp/package.json" "$SCRIPT_DIR/mcp/tsconfig.json" "$MCP_DIR/" 2>/dev/null || true
    cp -r "$SCRIPT_DIR/mcp/src" "$MCP_DIR/" 2>/dev/null || true
else
    echo "Downloading from GitHub..."
    REPO="https://raw.githubusercontent.com/AGM1968/weave/main/mcp"
    curl -sSL "$REPO/package.json" -o "$MCP_DIR/package.json"
    curl -sSL "$REPO/tsconfig.json" -o "$MCP_DIR/tsconfig.json"
    mkdir -p "$MCP_DIR/src"
    curl -sSL "$REPO/src/index.ts" -o "$MCP_DIR/src/index.ts"
fi

# Install dependencies and build
echo "Installing dependencies..."
(cd "$MCP_DIR" && npm install --production=false --silent 2>&1 | tail -1)

echo "Building TypeScript..."
if (cd "$MCP_DIR" && npm run build --silent 2>&1); then
    echo -e "${GREEN}✓ MCP server built at $MCP_DIR/dist/index.js${NC}"
else
    echo -e "${RED}✗ Build failed${NC}" >&2
    exit 1
fi

# Show IDE config instructions
echo ""
echo "To register with your IDE:"
echo "  wv-init-repo --agent=copilot   # VS Code → .vscode/mcp.json + copilot-instructions.md"
echo "  wv-init-repo --agent=claude    # Claude Code → .claude/settings.local.json"
echo "  wv-init-repo --agent=all       # Both agents in same repo"
echo ""
echo "Or add manually to your IDE config:"
echo "  Server path: $MCP_DIR/dist/index.js"
echo "  Command: node $MCP_DIR/dist/index.js"

# Verify if requested
if [ "$VERIFY" = "1" ]; then
    echo ""
    if command -v wv >/dev/null 2>&1; then
        wv mcp-status
    else
        echo -e "${YELLOW}wv not in PATH — skipping verification${NC}"
    fi
fi
