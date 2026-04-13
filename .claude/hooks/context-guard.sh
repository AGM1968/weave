#!/bin/bash
# context-guard.sh - Session start wrapper with load policy
#
# Runs wv status and emits a context load policy based on observable heuristics.
# Designed for Claude Code SessionStart hook.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WV="$(command -v wv 2>/dev/null || echo "$HOME/.local/bin/wv")"

# Colors
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

# Find repo root
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
WEAVE_DIR="$REPO_ROOT/.weave"

# Policy cache (1-hour TTL)
_HOT_ZONE="${WV_HOT_ZONE:-/dev/shm/weave}"
POLICY_CACHE="${POLICY_CACHE:-${_HOT_ZONE}/.context_policy}"
POLICY_TTL=3600

# Heuristics for policy decision
determine_policy() {
    local policy="MEDIUM"
    local reasons=()
    
    # Check for large files in common locations (git ls-files reads index, no disk walk)
    large_files=$(cd "$REPO_ROOT" && git ls-files -z '*.py' '*.ts' '*.js' '*.go' 2>/dev/null | \
        xargs -0 -r stat -c %s 2>/dev/null | awk '$1 > 51200 {c++} END {print c+0}')
    
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
    
    # Check if we're in a known large repo (git ls-files reads index, no disk walk)
    total_files=$(git -C "$REPO_ROOT" ls-files '*.py' '*.ts' '*.js' 2>/dev/null | wc -l)
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

# Determine policy (shared by both output modes)
if [ -f "$POLICY_CACHE" ] && [ "$(( $(date +%s) - $(stat -c %Y "$POLICY_CACHE" 2>/dev/null || echo 0) ))" -lt "$POLICY_TTL" ]; then
    policy=$(head -1 "$POLICY_CACHE")
    mapfile -t reasons < <(tail -n +2 "$POLICY_CACHE")
else
    _policy_output=$(determine_policy)
    policy=$(echo "$_policy_output" | head -1)
    mapfile -t reasons < <(echo "$_policy_output" | tail -n +2)
    mkdir -p "$(dirname "$POLICY_CACHE")"
    printf '%s\n' "$policy" "${reasons[@]}" > "$POLICY_CACHE" 2>/dev/null || true
fi

if [ -t 1 ] && [ "${WV_AGENT:-0}" != "1" ]; then
    # Human tty — full banner
    echo -e "${CYAN}━━━ Memory System v5.0 (Weave) ━━━${NC}"
    if [ -x "$WV" ]; then
        "$WV" load 2>/dev/null || true
        "$WV" status 2>/dev/null || true
    fi

    echo ""
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
else
    # Agent/captured — compact single line
    if [ -x "$WV" ]; then
        "$WV" load 2>/dev/null || true
    fi
    _status_line=""
    if [ -x "$WV" ]; then
        _status_line=$("$WV" status 2>/dev/null || true)
    fi
    # Extract counts from status line (format: "Work: N active, M ready, K blocked.")
    _active=$(echo "$_status_line" | grep -oP '\d+(?= active)' || echo "0")
    _ready=$(echo "$_status_line"  | grep -oP '\d+(?= ready)'  || echo "0")
    _blocked=$(echo "$_status_line" | grep -oP '\d+(?= blocked)' || echo "0")
    # Extract current node if present (format: "Primary: wv-XXXX: ...")
    _current=$(echo "$_status_line" | grep -oP '(?<=Primary: )wv-[a-f0-9]+' || echo "none")
    echo "Weave: ${_active} active, ${_ready} ready, ${_blocked} blocked | policy=${policy} | current=${_current}"
fi
