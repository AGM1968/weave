#!/bin/bash
# wv-gh.sh — GitHub notification helpers for live progress comments
#
# Called from cmd_work, cmd_done, cmd_block when WV_GH_NOTIFY=1 is set.
# Posts real-time comments and label updates to linked GitHub issues.
#
# Usage:
#   source scripts/lib/wv-gh.sh
#   gh_notify <node-id> <event> [extra args...]
#
# Events:
#   work     — Agent claimed the task
#   done     — Node completed (pass --learning="..." for learning text)
#   block    — Node blocked (pass --blocker=<id> for blocker reference)
#
# Configuration:
#   WV_GH_NOTIFY=1      Enable notifications (opt-in, default off)
#   WV_GH_NOTIFY=0       Disable notifications (explicit)

gh_notify() {
    # Guard: opt-in only
    [ "${WV_GH_NOTIFY:-0}" = "1" ] || return 0

    # Guard: gh CLI must be available
    command -v gh >/dev/null 2>&1 || return 0

    # Guard: python3 must be available for the sync module
    command -v python3 >/dev/null 2>&1 || return 0

    local node_id="$1"
    local event="$2"
    shift 2 || return 0

    # Build extra args
    local extra_args=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --learning=*) extra_args+=("--learning" "${1#*=}") ;;
            --blocker=*)  extra_args+=("--blocker" "${1#*=}") ;;
        esac
        shift
    done

    # Delegate to Python sync module's --notify mode (synchronous)
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

    # Resolve PYTHONPATH through symlinks (same fix as wv-cmd-data.sh)
    local _gh_pypath="$script_dir"
    if [ ! -d "$_gh_pypath/weave_gh" ]; then
        local _gh_real
        _gh_real=$(readlink -f "$_gh_pypath/lib/wv-config.sh" 2>/dev/null || echo "")
        if [ -n "$_gh_real" ]; then
            _gh_pypath=$(dirname "$(dirname "$_gh_real")")
        fi
    fi

    # Bypass venv python to avoid PYTHONPATH conflicts
    local _gh_python3
    if [ -n "${VIRTUAL_ENV:-}" ] && [ -x /usr/bin/python3 ]; then
        _gh_python3=/usr/bin/python3
    else
        _gh_python3=python3
    fi

    local _gh_log="${WV_HOT_ZONE}/gh_notify.log"
    PYTHONPATH="$_gh_pypath" "$_gh_python3" -m weave_gh --notify "$node_id" "$event" "${extra_args[@]}" 2>>"$_gh_log" || true
}

_refresh_parent_gh() {
    # Refresh parent epic GH issue body after closing a child node.
    # Lightweight: only updates if content hash changed.
    command -v gh >/dev/null 2>&1 || return 0
    command -v python3 >/dev/null 2>&1 || return 0

    local child_id="$1"

    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

    # Resolve PYTHONPATH through symlinks (same as gh_notify)
    local _gh_pypath="$script_dir"
    if [ ! -d "$_gh_pypath/weave_gh" ]; then
        local _gh_real
        _gh_real=$(readlink -f "$_gh_pypath/lib/wv-config.sh" 2>/dev/null || echo "")
        if [ -n "$_gh_real" ]; then
            _gh_pypath=$(dirname "$(dirname "$_gh_real")")
        fi
    fi

    local _gh_python3
    if [ -n "${VIRTUAL_ENV:-}" ] && [ -x /usr/bin/python3 ]; then
        _gh_python3=/usr/bin/python3
    else
        _gh_python3=python3
    fi

    PYTHONPATH="$_gh_pypath" "$_gh_python3" -m weave_gh --refresh-parent "$child_id" 2>/dev/null || true
}
