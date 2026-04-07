#!/bin/bash
# wv-cmd-findings.sh -- Historical finding promotion commands
#
# Commands: findings promote
# Sourced by: wv entry point (after lib modules)
# Dependencies: wv-config.sh, wv-db.sh, wv-validate.sh

_wv_findings_python() {
    local _wv_pypath="${WV_LIB_DIR:-$SCRIPT_DIR}"
    if [ ! -d "$_wv_pypath/weave_quality" ]; then
        local _wv_real
        _wv_real=$(readlink -f "$_wv_pypath/lib/wv-config.sh" 2>/dev/null || echo "")
        if [ -n "$_wv_real" ]; then
            _wv_pypath=$(dirname "$(dirname "$_wv_real")")
        fi
    fi

    local _wv_python3=python3
    if [ -n "${CONDA_PREFIX:-}" ] || [ -n "${CONDA_DEFAULT_ENV:-}" ]; then
        if ! python3 -c "import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)" 2>/dev/null; then
            if [ -x /usr/bin/python3 ]; then
                _wv_python3=/usr/bin/python3
            fi
        fi
    fi

    PYTHONPATH="$_wv_pypath" "$_wv_python3" -m weave_quality "$@"
}

cmd_findings() {
    local subcmd="${1:-}"
    shift 2>/dev/null || true

    case "$subcmd" in
        promote) cmd_findings_promote "$@" ;;
        ""|help|-h|--help)
            cat >&2 <<'EOF'
Usage: wv findings <subcommand> [options]

Subcommands:
  promote        Promote historical learnings into finding nodes

Options:
  --top=N        Limit results (default: 5)
  --json         JSON output
  --dry-run      Review candidates without creating nodes (default)
  --apply        Create finding nodes (requires --parent=<id>)
  --include-guardrails  Include operational/reporting guardrails
  --include-root-causes Include validated explanatory root-cause insights
  --include-tooling  Include Weave/runtime/tooling findings (internal use)
  --parent=<id>  Parent node ID to link via references when applying
EOF
            return 0
            ;;
        *)
            echo -e "${RED}Unknown findings subcommand: $subcmd${NC}" >&2
            echo "Run 'wv findings help' for usage." >&2
            return 1
            ;;
    esac
}

cmd_findings_promote() {
    local json_flag=""
    local top_n=""
    local parent=""
    local dry_run=""
    local apply=""
    local include_guardrails=""
    local include_root_causes=""
    local include_tooling=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --json)       json_flag="--json" ;;
            --top=*)      top_n="${1#--top=}" ;;
            --top)        shift; top_n="$1" ;;
            --parent=*)   parent="${1#--parent=}" ;;
            --parent)     shift; parent="$1" ;;
            --dry-run)    dry_run="--dry-run" ;;
            --apply)      apply="--apply" ;;
            --include-guardrails) include_guardrails="--include-guardrails" ;;
            --include-root-causes) include_root_causes="--include-root-causes" ;;
            --include-tooling) include_tooling="--include-tooling" ;;
            --help|-h)
                echo "Usage: wv findings promote [--top=N] [--json] [--dry-run] [--include-guardrails] [--include-root-causes] [--include-tooling] [--apply --parent=<node-id>]" >&2
                echo "  --top defines the reviewed candidate window; --apply does not backfill past that window." >&2
                return 0
                ;;
            *)
                echo -e "${RED}Unexpected argument: $1${NC}" >&2
                return 1
                ;;
        esac
        shift
    done

    if [ -n "$apply" ] && [ -n "$dry_run" ]; then
        echo -e "${RED}Error: --apply and --dry-run are mutually exclusive${NC}" >&2
        return 1
    fi

    if [ -n "$apply" ] && [ -z "$parent" ]; then
        echo -e "${RED}Error: --parent=<node-id> is required with --apply${NC}" >&2
        return 1
    fi

    if [ -n "$parent" ] && [[ ! "$parent" =~ ^wv-[a-f0-9]{4,6}$ ]]; then
        local resolved_parent=""
        resolved_parent=$(resolve_id "$parent" 2>/dev/null || true)
        [ -n "$resolved_parent" ] && parent="$resolved_parent"
    fi

    [ -z "$apply" ] && dry_run="--dry-run"

    local py_args=()
    [ -n "$WV_HOT_ZONE" ] && py_args+=("--hot-zone" "$WV_HOT_ZONE")
    py_args+=("findings-promote")
    [ -n "$parent" ] && py_args+=("--parent" "$parent")
    [ -n "$top_n" ] && py_args+=("--top" "$top_n")
    [ -n "$json_flag" ] && py_args+=("$json_flag")
    [ -n "$dry_run" ] && py_args+=("$dry_run")
    [ -n "$apply" ] && py_args+=("$apply")
    [ -n "$include_guardrails" ] && py_args+=("$include_guardrails")
    [ -n "$include_root_causes" ] && py_args+=("$include_root_causes")
    [ -n "$include_tooling" ] && py_args+=("$include_tooling")

    _wv_findings_python "${py_args[@]}"
}
