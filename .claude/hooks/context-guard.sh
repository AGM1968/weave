#!/bin/bash
# context-guard.sh - on-demand view of the context load policy
#
# The policy itself is `wv context-policy` (wv-f757a4): the one computation every
# harness reads, MCP weave_overview included. This script adds a human banner,
# `wv load`/`wv status` and the stale-findings advisory.
#
# No longer a registered SessionStart hook (wv-a523de): its compact
# "Weave: ... | policy=... | current=..." line is now the first line of the
# context `wv hook dispatch --event=SessionStart` emits for every host. Running
# both in one Claude matcher group raced two `wv load`s at every session start.

set -e

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$HOOK_DIR/../lib/wv-hook-common.sh" 2>/dev/null \
    || source "$HOOK_DIR/../../scripts/lib/wv-hook-common.sh" 2>/dev/null \
    || source "${HOME}/.config/weave/lib/wv-hook-common.sh" 2>/dev/null \
    || true
_hc_refresh

# Resolve wv beside this hook first (checkout hook -> checkout wv, installed hook
# -> installed wv), so a suite driving the checkout never reads an older install.
source "$HOOK_DIR/../lib/wv-resolve-project.sh" 2>/dev/null \
    || source "$HOOK_DIR/../../scripts/lib/wv-resolve-project.sh" 2>/dev/null \
    || source "${HOME}/.config/weave/lib/wv-resolve-project.sh" 2>/dev/null \
    || true
[ -n "${WV:-}" ] && [ -x "$WV" ] || WV="$(command -v wv 2>/dev/null || true)"

# Colors
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

policy="unknown"
reasons=()
if [ -n "$WV" ] && [ -x "$WV" ]; then
    if _policy_json=$("$WV" context-policy --json 2>/dev/null); then
        policy=$(jq -r '.policy // "unknown"' <<< "$_policy_json" 2>/dev/null || echo unknown)
        mapfile -t reasons < <(jq -r '.reasons[]?' <<< "$_policy_json" 2>/dev/null)
    fi
fi

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
        *)
            echo -e "policy: ${YELLOW}unknown${NC} (wv context-policy unavailable)"
            ;;
    esac
    echo "edit targets: native-read before editing (shell cat/grep don't satisfy edit-guards)"

    if [ ${#reasons[@]} -gt 0 ]; then
        echo ""
        echo "reason: ${reasons[0]}"
    fi

    # Stale findings advisory: findings promoted >14 days ago with no fix
    if [ -n "${WV_DB:-}" ] && [ -f "$WV_DB" ]; then
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
