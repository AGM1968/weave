#!/bin/bash
# context-guard.sh - Session start wrapper with load policy
#
# Runs wv status and emits a context load policy based on observable heuristics.
# Designed for Claude Code SessionStart hook and MCP overview surfaces.

set -e

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/../lib/wv-hook-common.sh" 2>/dev/null || source "$HOOK_DIR/../../scripts/lib/wv-hook-common.sh" 2>/dev/null || true
_hc_refresh

# Colors
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

# Find repo root first so WV resolution can prefer the local repo script.
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
WEAVE_DIR="$REPO_ROOT/.weave"

if [ -x "$REPO_ROOT/scripts/wv" ]; then
    WV="$REPO_ROOT/scripts/wv"
elif command -v wv >/dev/null 2>&1; then
    WV="$(command -v wv)"
elif [ -x "$HOME/.local/bin/wv" ]; then
    WV="$HOME/.local/bin/wv"
else
    WV=""
fi

# Policy cache (1-hour TTL). Default to the committed .weave location so the
# runtime can consume the same signal. Tests may override via POLICY_CACHE.
POLICY_CACHE="${POLICY_CACHE:-${WEAVE_DIR}/.context_policy}"
POLICY_TTL=3600
RUNTIME_MD="$WEAVE_DIR/runtime.md"
RUNTIME_MARKER_BEGIN="<!-- BEGIN WEAVE RUNTIME CONTEXT -->"
RUNTIME_MARKER_END="<!-- END WEAVE RUNTIME CONTEXT -->"

# Heuristics for policy decision
determine_policy() {
    local policy="MEDIUM"
    local reasons=()
    local large_files
    local jsonl_lines
    local total_files

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

write_policy_cache() {
    local policy="$1"
    shift
    local reasons=("$@")
    local cache_parent
    local default_cache="${WEAVE_DIR}/.context_policy"

    if [ "$POLICY_CACHE" = "$default_cache" ] && [ ! -d "$WEAVE_DIR" ]; then
        return 0
    fi

    cache_parent="$(dirname "$POLICY_CACHE")"
    mkdir -p "$cache_parent" 2>/dev/null || return 0
    printf '%s\n' "$policy" "${reasons[@]}" > "$POLICY_CACHE" 2>/dev/null || true
}

refresh_runtime_md() {
    local policy="$1"
    local block
    local tmp

    [ -f "$RUNTIME_MD" ] || return 0

    block="${RUNTIME_MARKER_BEGIN}
Current context policy: ${policy}
Policy source: .weave/.context_policy
This file is loaded into weave-runtime system prompts. Keep repo-specific instructions below this block.
${RUNTIME_MARKER_END}"

    tmp=$(mktemp)
    if grep -qF "$RUNTIME_MARKER_BEGIN" "$RUNTIME_MD"; then
        awk -v begin="$RUNTIME_MARKER_BEGIN" -v end="$RUNTIME_MARKER_END" -v block="$block" '
            $0 == begin { print block; skip=1; next }
            skip && $0 == end { skip=0; next }
            skip { next }
            { print }
        ' "$RUNTIME_MD" > "$tmp"
    else
        {
            printf '%s\n\n' "$block"
            cat "$RUNTIME_MD"
        } > "$tmp"
    fi

    if cmp -s "$tmp" "$RUNTIME_MD"; then
        rm -f "$tmp"
    else
        mv "$tmp" "$RUNTIME_MD"
    fi
}

# Determine policy (shared by both output modes)
if [ -f "$POLICY_CACHE" ] && [ "$(( $(date +%s) - $(stat -c %Y "$POLICY_CACHE" 2>/dev/null || echo 0) ))" -lt "$POLICY_TTL" ]; then
    policy=$(head -1 "$POLICY_CACHE")
    mapfile -t reasons < <(tail -n +2 "$POLICY_CACHE")
else
    _policy_output=$(determine_policy)
    policy=$(echo "$_policy_output" | head -1)
    mapfile -t reasons < <(echo "$_policy_output" | tail -n +2)
    write_policy_cache "$policy" "${reasons[@]}"
fi

refresh_runtime_md "$policy"

if [ -t 1 ] && [ "${WV_AGENT:-0}" != "1" ]; then
    # Human tty — full banner
    echo -e "${CYAN}━━━ Weave Context Policy ━━━${NC}"
    if [ -n "$WV" ] && [ -x "$WV" ]; then
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
            echo "└─ Use line ranges for large files"
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

    # Stale findings advisory: findings promoted >14 days ago with no fix
    if [ -n "$WV_DB" ] && [ -f "$WV_DB" ]; then
        _stale_count=$(sqlite3 "$WV_DB" "
            SELECT COUNT(*) FROM nodes
            WHERE json_extract(metadata, '\$.type') = 'finding'
              AND status != 'done'
              AND json_extract(metadata, '\$.promoted_at') IS NOT NULL
              AND CAST((julianday('now') - julianday(json_extract(metadata, '\$.promoted_at'))) AS INTEGER) >= 14;
        " 2>/dev/null || echo 0)
        if [ "${_stale_count:-0}" -gt 0 ]; then
            echo -e "${YELLOW}⚠ $_stale_count finding(s) unreviewed for 14+ days — run: wv findings list --stale=14${NC}"
        fi
    fi

    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
else
    # Agent/captured — compact single line
    if [ -n "$WV" ] && [ -x "$WV" ]; then
        "$WV" load 2>/dev/null || true
    fi
    _status_line=""
    if [ -n "$WV" ] && [ -x "$WV" ]; then
        _status_line=$("$WV" status 2>/dev/null || true)
    fi
    # Extract counts from status line (format: "Work: N active, M ready, K blocked.")
    _active=$(echo "$_status_line" | grep -oP '\d+(?= active)' || echo "0")
    _ready=$(echo "$_status_line" | grep -oP '\d+(?= ready)' || echo "0")
    _blocked=$(echo "$_status_line" | grep -oP '\d+(?= blocked)' || echo "0")
    # Extract current node if present (format: "Primary: wv-XXXX: ...")
    _current=$(echo "$_status_line" | grep -oP '(?<=Primary: )wv-[a-f0-9]+' || echo "none")
    echo "Weave: ${_active} active, ${_ready} ready, ${_blocked} blocked | policy=${policy} | current=${_current}"
fi
