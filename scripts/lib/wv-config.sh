#!/bin/bash
# wv-config.sh — Configuration, hot zone detection, colors
#
# Sourced by: wv entry point
# Dependencies: None

# ═══════════════════════════════════════════════════════════════════════════
# Version and Paths
# ═══════════════════════════════════════════════════════════════════════════

# Read version from VERSION file (next to this script)
_WV_LIB_DIR="${WV_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
if [ -f "$_WV_LIB_DIR/lib/VERSION" ]; then
    WV_VERSION=$(cat "$_WV_LIB_DIR/lib/VERSION" | tr -d '[:space:]')
else
    WV_VERSION="1.0.0"  # Fallback
fi

# SCRIPT_DIR is set by entry point, fall back if sourced directly
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
# Reject home/root as REPO_ROOT — same boundary rule as wv-resolve-project.sh.
# git failing from ~ produces REPO_ROOT=$HOME → WEAVE_DIR=~/.weave → source_hooks_dir=~/.claude/hooks
# (caveman plugin), causing false hook-drift warnings in wv doctor.
if [ "$REPO_ROOT" = "$HOME" ] || [ "$REPO_ROOT" = "/root" ]; then
    REPO_ROOT=""
fi
WEAVE_DIR="${WEAVE_DIR:-${REPO_ROOT:+$REPO_ROOT/.weave}}"

# Side-effect-free runtime resolution helpers shared with hooks.
source "$_WV_LIB_DIR/lib/wv-resolve-runtime.sh"
REPO_ROOT=$(canonicalize_runtime_path "$REPO_ROOT")

# ═══════════════════════════════════════════════════════════════════════════
# Hot Zone Configuration
# ═══════════════════════════════════════════════════════════════════════════

# Maximum hot zone usage in MB. Default 512MB.
WV_HOT_SIZE=${WV_HOT_SIZE:-512}

# Maximum database size in bytes. Default 50MB.
WV_MAX_DB_SIZE=${WV_MAX_DB_SIZE:-52428800}

_WV_ENV_OVERRIDE_HOT_ZONE=$(resolve_env_override_hot_zone)
if [ -n "$_WV_ENV_OVERRIDE_HOT_ZONE" ] && ! hot_zone_matches_repo "$_WV_ENV_OVERRIDE_HOT_ZONE" "$REPO_ROOT"; then
    _WV_ENV_OVERRIDE_OWNER=$(read_hot_zone_owner "$_WV_ENV_OVERRIDE_HOT_ZONE")
    [ -z "$_WV_ENV_OVERRIDE_OWNER" ] && [ -n "${WV_PROJECT_DIR:-}" ] && _WV_ENV_OVERRIDE_OWNER="$WV_PROJECT_DIR"

    # Shell-exported override leaks can persist across commands; warn once per
    # shell session for the same leak/repo tuple to avoid noisy repeated output.
    _WV_WARN_ONCE_DIR="${XDG_RUNTIME_DIR:-/tmp}"
    [ -d "$_WV_WARN_ONCE_DIR" ] && [ -w "$_WV_WARN_ONCE_DIR" ] || _WV_WARN_ONCE_DIR="/tmp"
    _WV_WARN_ONCE_KEY=$(printf '%s|%s|%s|%s' "$REPO_ROOT" "$_WV_ENV_OVERRIDE_HOT_ZONE" "${_WV_ENV_OVERRIDE_OWNER:-unknown}" "${PPID:-0}" | md5sum | cut -c1-16)
    _WV_WARN_ONCE_FILE="${_WV_WARN_ONCE_DIR}/wv-leaked-override-${_WV_WARN_ONCE_KEY}.warned"
    if [ ! -f "$_WV_WARN_ONCE_FILE" ]; then
        echo "wv: ignoring leaked WV_HOT_ZONE/WV_DB override from ${_WV_ENV_OVERRIDE_OWNER:-another repo} (current repo: $REPO_ROOT)" >&2
        : > "$_WV_WARN_ONCE_FILE" 2>/dev/null || true
    fi

    unset WV_HOT_ZONE WV_DB WV_PRIMARY_FILE
fi

# Set up hot zone and database paths
# Per-repo namespace: hash the repo root to isolate each repo's hot zone.
# This prevents multiple repos from sharing a single brain.db on tmpfs.
_WV_BASE_HOT_ZONE=$(resolve_hot_zone)
WV_HOT_ZONE="${WV_HOT_ZONE:-$(resolve_repo_hot_zone "$_WV_BASE_HOT_ZONE" "$REPO_ROOT")}"
WV_DB_CUSTOM="${WV_DB:+1}"
WV_DB="${WV_DB:-$(resolve_db "$WV_HOT_ZONE")}"
WV_PRIMARY_FILE="${WV_PRIMARY_FILE:-$(resolve_primary_file "$WV_HOT_ZONE")}"

# Primary active node helpers
# The "primary" node is the most recently claimed via `wv work`.
# Stored in $WV_HOT_ZONE/primary (tmpfs, session-scoped).
set_primary_node() {
    local id="$1"
    echo "$id" > "$WV_PRIMARY_FILE"
}

get_primary_node() {
    [ -f "$WV_PRIMARY_FILE" ] && cat "$WV_PRIMARY_FILE" 2>/dev/null || echo ""
}

clear_primary_node() {
    rm -f "$WV_PRIMARY_FILE" 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════════════════
# Colors
# ═══════════════════════════════════════════════════════════════════════════

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
DIM='\033[2m'
NC='\033[0m'

# NO_COLOR support (https://no-color.org/) + auto-detect non-tty
# Disable colors when: NO_COLOR is set, or stdout is not a terminal (pipes, captures, CI)
if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
    RED=''
    GREEN=''
    YELLOW=''
    CYAN=''
    DIM=''
    NC=''
fi

# ═══════════════════════════════════════════════════════════════════════════
# Output mode resolution
# ═══════════════════════════════════════════════════════════════════════════
#
# wv_resolve_mode [--mode=ARG]
#   Resolves the effective output mode for a command. Priority:
#     1. Explicit --mode= flag from caller (ARG, already extracted)
#     2. WV_MODE env var
#     3. Auto-detect: non-tty or WV_AGENT=1 → discover; tty → execute
#   Echoes: bootstrap | discover | execute | full
#
wv_resolve_mode() {
    local explicit="${1:-}"
    if [ -n "$explicit" ]; then
        case "$explicit" in
            bootstrap|discover|execute|full) echo "$explicit"; return ;;
        esac
    fi
    if [ -n "${WV_MODE:-}" ]; then
        case "$WV_MODE" in
            bootstrap|discover|execute|full) echo "$WV_MODE"; return ;;
        esac
    fi
    if [ ! -t 1 ] || [ "${WV_AGENT:-0}" = "1" ]; then
        echo "discover"
    else
        echo "execute"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# RAM Detection and Pragma Selection
# ═══════════════════════════════════════════════════════════════════════════

detect_ram_mb() {
    local ram_kb=0
    if [ -f /proc/meminfo ]; then
        ram_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
    elif command -v sysctl >/dev/null 2>&1; then
        ram_kb=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 ))
    fi
    echo $(( ram_kb / 1024 ))
}

select_pragmas() {
    local ram_mb
    ram_mb=$(detect_ram_mb)
    if [ -n "${WV_CACHE_SIZE:-}" ] && [ -n "${WV_MMAP_SIZE:-}" ]; then
        echo "$WV_CACHE_SIZE" "$WV_MMAP_SIZE"
    elif is_container; then
        echo "-10000" "134217728"
    elif [ "$ram_mb" -lt 2048 ] 2>/dev/null; then
        echo "-25000" "268435456"
    elif [ "$ram_mb" -lt 8192 ] 2>/dev/null; then
        echo "-50000" "1073741824"
    else
        echo "-100000" "2147483648"
    fi
}

validate_hot_size() {
    local avail_kb
    avail_kb=$(df -k "$WV_HOT_ZONE" 2>/dev/null | awk 'NR==2 {print $4}')
    [ -z "$avail_kb" ] && return
    local avail_mb=$(( avail_kb / 1024 ))
    if [ "$WV_HOT_SIZE" -gt "$avail_mb" ] 2>/dev/null; then
        WV_HOT_SIZE=$(( avail_mb * 80 / 100 ))
        echo "wv: hot zone limited to ${WV_HOT_SIZE}MB (80% of ${avail_mb}MB available)" >&2
    fi
}

# wv_set_phase — write .session_phase atomically with enum validation.
# Usage: wv_set_phase <phase> [<hot-zone-dir>]
# Valid values sourced from PHASE_VALUES in wv-validate.sh.
# Falls back to no-op if hot zone unavailable.
wv_set_phase() {
    local phase="$1"
    local hot_zone="${2:-${WV_HOT_ZONE:-}}"
    local valid=false
    local p
    for p in ${PHASE_VALUES:-discover execute closing}; do
        [ "$phase" = "$p" ] && valid=true && break
    done
    if [ "$valid" = false ]; then
        echo "wv_set_phase: invalid phase '$phase' (valid: ${PHASE_VALUES:-discover execute closing})" >&2
        return 1
    fi
    [ -n "$hot_zone" ] && printf '%s' "$phase" > "${hot_zone}/.session_phase" 2>/dev/null || true
}
