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
WEAVE_DIR="${WEAVE_DIR:-$REPO_ROOT/.weave}"

# ═══════════════════════════════════════════════════════════════════════════
# Hot Zone Configuration
# ═══════════════════════════════════════════════════════════════════════════

# Minimum free space required in hot zone (KB). Default 100MB.
WV_MIN_SHM=${WV_MIN_SHM:-102400}

# Maximum hot zone usage in MB. Default 512MB.
WV_HOT_SIZE=${WV_HOT_SIZE:-512}

# Maximum database size in bytes. Default 50MB.
WV_MAX_DB_SIZE=${WV_MAX_DB_SIZE:-52428800}

# Check if a path has enough free space (in KB)
check_free_space() {
    local path="$1"
    local min_kb="${2:-$WV_MIN_SHM}"
    local avail_kb
    avail_kb=$(df -k "$path" 2>/dev/null | awk 'NR==2 {print $4}')
    [ -n "$avail_kb" ] && [ "$avail_kb" -ge "$min_kb" ] 2>/dev/null
}

# Detect if running inside a container
_WV_CONTAINER=""
is_container() {
    if [ -z "$_WV_CONTAINER" ]; then
        if [ -f /.dockerenv ] || [ -f /run/.containerenv ] \
            || grep -qE 'docker|containerd|podman' /proc/1/cgroup 2>/dev/null \
            || [ -n "${CI:-}" ]; then
            _WV_CONTAINER=yes
        else
            _WV_CONTAINER=no
        fi
    fi
    [ "$_WV_CONTAINER" = "yes" ]
}

# Cross-platform hot zone detection
detect_hot_zone() {
    if [ -n "${WV_HOT_ZONE:-}" ]; then
        echo "${WV_HOT_ZONE}"
        return
    fi

    case "$(uname -s)" in
        Linux*)
            if is_container; then
                echo "wv: container detected, using /tmp (safe default)" >&2
                echo "/tmp/weave"
            elif [ -d "/dev/shm" ] && [ -w "/dev/shm" ] && check_free_space "/dev/shm"; then
                echo "/dev/shm/weave"
            else
                [ -d "/dev/shm" ] && [ -w "/dev/shm" ] && \
                    echo "wv: /dev/shm has <${WV_MIN_SHM}KB free, falling back to /tmp" >&2
                echo "/tmp/weave"
            fi
            ;;
        Darwin*)
            echo "${TMPDIR:-/tmp}/weave"
            ;;
        MINGW*|CYGWIN*|MSYS*)
            echo "${TEMP:-/tmp}/weave"
            ;;
        *)
            echo "$WEAVE_DIR"
            ;;
    esac
}

# Set up hot zone and database paths
# Per-repo namespace: hash the repo root to isolate each repo's hot zone.
# This prevents multiple repos from sharing a single brain.db on tmpfs.
_WV_BASE_HOT_ZONE=$(detect_hot_zone)
if [ -n "$REPO_ROOT" ] && [ "$REPO_ROOT" != "/" ]; then
    _WV_REPO_HASH=$(echo "$REPO_ROOT" | md5sum | cut -c1-8)
    WV_HOT_ZONE="${WV_HOT_ZONE:-${_WV_BASE_HOT_ZONE}/${_WV_REPO_HASH}}"
else
    WV_HOT_ZONE="${WV_HOT_ZONE:-${_WV_BASE_HOT_ZONE}}"
fi
WV_DB_CUSTOM="${WV_DB:+1}"
WV_DB="${WV_DB:-$WV_HOT_ZONE/brain.db}"

# ═══════════════════════════════════════════════════════════════════════════
# Colors
# ═══════════════════════════════════════════════════════════════════════════

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
DIM='\033[2m'
NC='\033[0m'

# NO_COLOR support (https://no-color.org/)
# If NO_COLOR env var is set (to any value), disable all colors
if [ -n "${NO_COLOR:-}" ]; then
    RED=''
    GREEN=''
    YELLOW=''
    CYAN=''
    DIM=''
    NC=''
fi

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
