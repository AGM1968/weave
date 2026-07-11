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
    local _wv_pypath
    _wv_pypath=$(_wv_python_module_path weave_quality)
    _wv_agent_python_exec_module weave_quality "$_wv_pypath" "$@"
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
        structural-search) cmd_quality_structural_search "$@" ;;
        patterns) cmd_quality_patterns "$@" ;;
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
  structural-search  Find code by structural pattern (requires ast-grep)
  patterns           Structural + prose pattern rules: scan/list/promote

Options:
  --json         JSON output (scan, hotspots, diff, functions)
  --top=N        Limit results (hotspots, promote)
  --exclude=G    Exclude files matching glob (scan, repeatable)
  --parent=<id>  Parent node ID for promote (required)

Quality gate (enforced on wv done):
  wv done blocks if a file linked to the node has a function above the
  language CC threshold: Python=25, Bash=100, TypeScript=15.

  To identify violations:    wv quality functions <file>
  To rescan after a fix:     wv quality scan   (commit first — uses git blob SHAs)
  To exempt a path, add to .weave/quality.conf:
    [exempt]
    install.sh       # full path
    archive/         # directory prefix (trailing / required)
  Then run: wv load

  Full reference: scripts/weave_quality/README.md § Quality Gate
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

# ═══════════════════════════════════════════════════════════════════════════
# cmd_quality_structural_search — wv quality structural-search
# ═══════════════════════════════════════════════════════════════════════════

cmd_quality_structural_search() {
    local json_flag=""
    local pattern=""
    local lang=""
    local repo="."

    while [ $# -gt 0 ]; do
        case "$1" in
            --json)       json_flag="--json" ;;
            --pattern=*)  pattern="${1#--pattern=}" ;;
            --pattern)    shift; pattern="$1" ;;
            --lang=*)     lang="${1#--lang=}" ;;
            --lang)       shift; lang="$1" ;;
            --repo=*)     repo="${1#--repo=}" ;;
            --repo)       shift; repo="$1" ;;
            --help|-h)
                echo "Usage: wv quality structural-search --pattern=<pat> --lang=<lang> [--repo=<path>] [--json]" >&2
                echo "" >&2
                echo "  Find code by structural AST pattern (requires ast-grep binary)." >&2
                echo "  --pattern  ast-grep pattern (e.g. '\$F(\$\$\$ARGS)')" >&2
                echo "  --lang     Language: python, bash, typescript, go, rust, ..." >&2
                echo "  --repo     Repository root to search (default: .)" >&2
                echo "  --json     JSON output: [{file, line, column, match_text, node_kind}]" >&2
                return 0
                ;;
            *)
                echo -e "${RED}Unexpected argument: $1${NC}" >&2
                return 1
                ;;
        esac
        shift
    done

    if [ -z "$pattern" ]; then
        echo -e "${RED}Error: --pattern=<pat> is required${NC}" >&2
        return 1
    fi
    if [ -z "$lang" ]; then
        echo -e "${RED}Error: --lang=<lang> is required${NC}" >&2
        return 1
    fi

    local py_args=()
    py_args+=("structural-search")
    py_args+=("--pattern" "$pattern")
    py_args+=("--lang" "$lang")
    py_args+=("--repo" "$repo")
    [ -n "$json_flag" ] && py_args+=("$json_flag")

    _wv_quality_python "${py_args[@]}"
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_quality_patterns — wv quality patterns {scan|list|promote}
# ═══════════════════════════════════════════════════════════════════════════

cmd_quality_patterns() {
    local subcmd="${1:-}"
    shift 2>/dev/null || true

    case "$subcmd" in
        scan|list|promote) ;;
        ""|help|-h|--help)
            cat >&2 <<'EOF'
Usage: wv quality patterns <subcommand> [options]

Subcommands:
  scan [path]    Run all active code/prose pattern rules and store findings
  list [path]    List active rules with last-scan hit counts
  promote        Promote findings as Weave nodes (--parent=<id> required)

Options:
  --json         JSON output
  --parent=<id>  Parent node ID (promote only, required)
  --dry-run      Show what would be created (promote only)

Pattern rules are loaded from:
  1. Built-in rules: scripts/weave_quality/default_patterns/*.yaml
  2. Custom rules:   .weave/patterns/*.yaml

Code rules require ast-grep. Prose rules are stdlib-only and still run when
ast-grep is absent.

To disable a rule, add to .weave/quality.conf:
  [patterns]
  disabled = unquoted-variable, bare-except-pass
EOF
            return 0
            ;;
        *)
            echo -e "${RED}Unknown patterns subcommand: $subcmd${NC}" >&2
            echo "Run 'wv quality patterns help' for usage." >&2
            return 1
            ;;
    esac

    local json_flag=""
    local path_arg=""
    local parent=""
    local dry_run=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --json)       json_flag="--json" ;;
            --parent=*)   parent="${1#--parent=}" ;;
            --parent)     shift; parent="$1" ;;
            --dry-run)    dry_run="--dry-run" ;;
            --help|-h)    ;;
            -*)
                echo -e "${RED}Unexpected option: $1${NC}" >&2
                return 1
                ;;
            *)
                path_arg="$1"
                ;;
        esac
        shift
    done

    local py_args=("patterns" "$subcmd")
    [ -n "$path_arg" ] && py_args+=("$path_arg")
    [ -n "$json_flag" ] && py_args+=("$json_flag")

    if [ "$subcmd" = "promote" ]; then
        if [ -z "$parent" ]; then
            echo -e "${RED}Error: --parent=<id> is required for promote${NC}" >&2
            return 1
        fi
        py_args+=("--parent" "$parent")
        [ -n "$dry_run" ] && py_args+=("$dry_run")
    fi

    _wv_quality_python "${py_args[@]}"
}
