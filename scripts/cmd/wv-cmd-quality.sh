#!/bin/bash
# wv-cmd-quality.sh -- Code quality commands
#
# Commands: quality scan, quality hotspots, quality functions, quality diff, quality promote, quality reset
# Sourced by: wv entry point (after lib modules)
# Dependencies: wv-config.sh, wv-db.sh
#
# This is the 5th cmd module. It wraps the weave_quality Python module
# using the same PYTHONPATH bootstrap pattern as wv-cmd-data.sh for weave_gh.

# ═══════════════════════════════════════════════════════════════════════════
# _wv_quality_python — Invoke the weave_quality Python module
# ═══════════════════════════════════════════════════════════════════════════

_wv_quality_python() {
    # Resolve the scripts/ parent directory via symlink dereferencing
    # Same pattern as weave_gh invocation in wv-cmd-data.sh
    local _wv_pypath="${WV_LIB_DIR:-$SCRIPT_DIR}"
    if [ ! -d "$_wv_pypath/weave_quality" ]; then
        # Dev-mode symlinks: resolve through to actual source
        local _wv_real
        _wv_real=$(readlink -f "$_wv_pypath/lib/wv-config.sh" 2>/dev/null || echo "")
        if [ -n "$_wv_real" ]; then
            _wv_pypath=$(dirname "$(dirname "$_wv_real")")
        fi
    fi

    # Bypass active virtualenv to avoid Poetry conflicts with system python
    local _wv_python3
    if [ -n "${VIRTUAL_ENV:-}" ] && [ -x /usr/bin/python3 ]; then
        _wv_python3=/usr/bin/python3
    else
        _wv_python3=python3
    fi

    PYTHONPATH="$_wv_pypath" "$_wv_python3" -m weave_quality "$@"
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_quality — Main quality command dispatcher
# ═══════════════════════════════════════════════════════════════════════════

cmd_quality() {
    local subcmd="${1:-}"
    shift 2>/dev/null || true

    case "$subcmd" in
        scan)    cmd_quality_scan "$@" ;;
        hotspots) cmd_quality_hotspots "$@" ;;
        functions) cmd_quality_functions "$@" ;;
        diff)    cmd_quality_diff "$@" ;;
        reset)   cmd_quality_reset "$@" ;;
        promote) cmd_quality_promote "$@" ;;
        ""|help|-h|--help)
            cat >&2 <<'EOF'
Usage: wv quality <subcommand> [options]

Subcommands:
  scan [path]    Scan codebase for quality metrics [--exclude=<glob>]
  reset          Delete quality.db for recovery
  hotspots       Ranked hotspot report
  functions [p]  Per-function CC report for a file or directory
  diff           Delta report vs previous scan
  promote        Create Weave nodes from findings (--parent=<id> required)

Options:
  --json         JSON output (scan, hotspots, diff, functions)
  --top=N        Limit results (hotspots, promote)
  --exclude=G    Exclude files matching glob (scan, repeatable)
  --parent=<id>  Parent node ID for promote (required)
EOF
            return 0
            ;;
        *)
            echo -e "${RED}Unknown quality subcommand: $subcmd${NC}" >&2
            echo "Run 'wv quality help' for usage." >&2
            return 1
            ;;
    esac
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_quality_scan — wv quality scan [path]
# ═══════════════════════════════════════════════════════════════════════════

cmd_quality_scan() {
    local scan_path=""
    local json_flag=""
    local -a exclude_args=()

    while [ $# -gt 0 ]; do
        case "$1" in
            --json)  json_flag="--json" ;;
            --exclude=*) exclude_args+=("--exclude" "${1#--exclude=}") ;;
            --exclude)   shift; exclude_args+=("--exclude" "$1") ;;
            --help|-h)
                echo "Usage: wv quality scan [path] [--json] [--exclude=<glob>]" >&2
                return 0
                ;;
            *)
                if [ -z "$scan_path" ]; then
                    scan_path="$1"
                else
                    echo -e "${RED}Unexpected argument: $1${NC}" >&2
                    return 1
                fi
                ;;
        esac
        shift
    done

    # Build Python args
    local py_args=()
    [ -n "$WV_HOT_ZONE" ] && py_args+=("--hot-zone" "$WV_HOT_ZONE")
    py_args+=("scan")
    [ -n "$scan_path" ] && py_args+=("$scan_path")
    [ -n "$json_flag" ] && py_args+=("$json_flag")
    [ ${#exclude_args[@]} -gt 0 ] && py_args+=("${exclude_args[@]}")

    _wv_quality_python "${py_args[@]}"
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_quality_reset — wv quality reset
# ═══════════════════════════════════════════════════════════════════════════

cmd_quality_reset() {
    local py_args=()
    [ -n "$WV_HOT_ZONE" ] && py_args+=("--hot-zone" "$WV_HOT_ZONE")
    py_args+=("reset")

    _wv_quality_python "${py_args[@]}"
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_quality_functions — wv quality functions [path] [--json]
# ═══════════════════════════════════════════════════════════════════════════

cmd_quality_functions() {
    local json_flag=""
    local fn_path=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --json)  json_flag="--json" ;;
            --help|-h)
                echo "Usage: wv quality functions [path] [--json]" >&2
                return 0
                ;;
            *)
                if [ -z "$fn_path" ]; then
                    fn_path="$1"
                else
                    echo -e "${RED}Unexpected argument: $1${NC}" >&2
                    return 1
                fi
                ;;
        esac
        shift
    done

    local py_args=()
    [ -n "$WV_HOT_ZONE" ] && py_args+=("--hot-zone" "$WV_HOT_ZONE")
    py_args+=("functions")
    [ -n "$fn_path" ] && py_args+=("$fn_path")
    [ -n "$json_flag" ] && py_args+=("$json_flag")

    _wv_quality_python "${py_args[@]}"
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_quality_hotspots — wv quality hotspots [--top=N] [--json]
# ═══════════════════════════════════════════════════════════════════════════

cmd_quality_hotspots() {
    local json_flag=""
    local top_n=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --json)      json_flag="--json" ;;
            --top=*)     top_n="${1#--top=}" ;;
            --top)       shift; top_n="$1" ;;
            --help|-h)
                echo "Usage: wv quality hotspots [--top=N] [--json]" >&2
                return 0
                ;;
            *)
                echo -e "${RED}Unexpected argument: $1${NC}" >&2
                return 1
                ;;
        esac
        shift
    done

    local py_args=()
    [ -n "$WV_HOT_ZONE" ] && py_args+=("--hot-zone" "$WV_HOT_ZONE")
    py_args+=("hotspots")
    [ -n "$top_n" ] && py_args+=("--top" "$top_n")
    [ -n "$json_flag" ] && py_args+=("$json_flag")

    _wv_quality_python "${py_args[@]}"
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_quality_diff — wv quality diff [--json]
# ═══════════════════════════════════════════════════════════════════════════

cmd_quality_diff() {
    local json_flag=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --json)  json_flag="--json" ;;
            --help|-h)
                echo "Usage: wv quality diff [--json]" >&2
                return 0
                ;;
            *)
                echo -e "${RED}Unexpected argument: $1${NC}" >&2
                return 1
                ;;
        esac
        shift
    done

    local py_args=()
    [ -n "$WV_HOT_ZONE" ] && py_args+=("--hot-zone" "$WV_HOT_ZONE")
    py_args+=("diff")
    [ -n "$json_flag" ] && py_args+=("$json_flag")

    _wv_quality_python "${py_args[@]}"
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_quality_promote — wv quality promote --parent=<id> [--top=N] [--json] [--dry-run]
# ═══════════════════════════════════════════════════════════════════════════

cmd_quality_promote() {
    local json_flag=""
    local top_n=""
    local parent=""
    local dry_run=""
    local upsert=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --json)       json_flag="--json" ;;
            --top=*)      top_n="${1#--top=}" ;;
            --top)        shift; top_n="$1" ;;
            --parent=*)   parent="${1#--parent=}" ;;
            --parent)     shift; parent="$1" ;;
            --upsert)     upsert="--upsert" ;;
            --dry-run)    dry_run="--dry-run" ;;
            --help|-h)
                echo "Usage: wv quality promote --parent=<node-id> [--top=N] [--upsert] [--json] [--dry-run]" >&2
                return 0
                ;;
            *)
                echo -e "${RED}Unexpected argument: $1${NC}" >&2
                return 1
                ;;
        esac
        shift
    done

    if [ -z "$parent" ]; then
        echo -e "${RED}Error: --parent=<node-id> is required${NC}" >&2
        return 1
    fi

    local py_args=()
    [ -n "$WV_HOT_ZONE" ] && py_args+=("--hot-zone" "$WV_HOT_ZONE")
    py_args+=("promote")
    py_args+=("--parent" "$parent")
    [ -n "$top_n" ] && py_args+=("--top" "$top_n")
    [ -n "$upsert" ] && py_args+=("$upsert")
    [ -n "$json_flag" ] && py_args+=("$json_flag")
    [ -n "$dry_run" ] && py_args+=("$dry_run")

    _wv_quality_python "${py_args[@]}"
}
