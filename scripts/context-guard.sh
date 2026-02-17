#!/bin/bash
# context-guard.sh - Session start wrapper with load policy
#
# Runs wv status and emits a context load policy based on observable heuristics.
# Designed for Claude Code SessionStart hook.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WV="$SCRIPT_DIR/wv"

# Colors
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

# Find repo root
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
WEAVE_DIR="$REPO_ROOT/.weave"

# Heuristics for policy decision
determine_policy() {
    local policy="MEDIUM"
    local reasons=()
    
    # Check for large files in common locations
    large_files=$(find "$REPO_ROOT" -type f \( -name "*.py" -o -name "*.ts" -o -name "*.js" -o -name "*.go" \) \
        -size +50k 2>/dev/null | wc -l)
    
    if [ "$large_files" -gt 10 ]; then
        policy="LOW"
        reasons+=("many large source files detected")
    fi
    
    # Check Weave database size
    if [ -f "$WEAVE_DIR/nodes.jsonl" ]; then
        jsonl_lines=$(wc -l < "$WEAVE_DIR/nodes.jsonl" 2>/dev/null || echo "0")
        if [ "$jsonl_lines" -gt 100 ]; then
            policy="LOW"
            reasons+=("large Weave history ($jsonl_lines nodes)")
        fi
    fi
    
    # Check if we're in a known large repo
    total_files=$(find "$REPO_ROOT" -type f -name "*.py" -o -name "*.ts" -o -name "*.js" 2>/dev/null | wc -l)
    if [ "$total_files" -gt 500 ]; then
        if [ "$policy" = "MEDIUM" ]; then
            policy="MEDIUM"  # Don't downgrade further, just note it
            reasons+=("large codebase ($total_files source files)")
        fi
    fi
    
    # Default case - fresh/small repo
    if [ ${#reasons[@]} -eq 0 ]; then
        policy="HIGH"
        reasons+=("small/fresh workspace")
    fi
    
    echo "$policy"
    printf '%s\n' "${reasons[@]}"
}

# Load Weave and show status
echo -e "${CYAN}━━━ Memory System v5.0 (Weave) ━━━${NC}"
if [ -x "$WV" ]; then
    "$WV" load 2>/dev/null || true
    "$WV" status 2>/dev/null || true
fi

# Determine and display policy
echo ""
_policy_output=$(determine_policy)
policy=$(echo "$_policy_output" | head -1)
mapfile -t reasons < <(echo "$_policy_output" | tail -n +2)

case $policy in
    HIGH)
        echo -e "policy: ${GREEN}HIGH${NC}"
        echo "├─ Can read medium files whole (<500 lines)"
        echo "├─ Grep first for large files"
        echo "└─ Avoid known megafiles"
        ;;
    MEDIUM)
        echo -e "policy: ${YELLOW}MEDIUM${NC}"
        echo "├─ Prefer grep before read"
        echo "├─ Avoid full-file reads >500 lines"
        echo "└─ Use read_range for large files"
        ;;
    LOW)
        echo -e "policy: ${YELLOW}LOW${NC}"
        echo "├─ Always grep first"
        echo "├─ Only read small slices (<200 lines)"
        echo "└─ Summarize rather than quote"
        ;;
esac

if [ ${#reasons[@]} -gt 0 ]; then
    echo ""
    echo "reason: ${reasons[0]}"
fi

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
