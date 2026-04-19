#!/bin/bash
# wv-cmd-findings.sh -- Finding node commands
#
# Commands: findings list, findings promote
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
        list)    cmd_findings_list "$@" ;;
        promote) cmd_findings_promote "$@" ;;
        ""|help|-h|--help)
            cat >&2 <<'EOF'
Usage: wv findings <subcommand> [options]

Subcommands:
  list           List finding nodes with fixable/confidence summary
  promote        Promote historical learnings into finding nodes

list options:
  --fixable      Only show fixable findings
  --json         JSON output

promote options:
  --top=N        Limit results (default: 5)
  --json         JSON output
  --dry-run      Review candidates without creating nodes (default)
  --apply        Create finding nodes (requires --parent=<id>)
  --include-guardrails  Include operational/reporting guardrails
  --include-root-causes Include validated explanatory root-cause insights
  --include-tooling  Include Weave/runtime/tooling findings (internal use)
  --parent=<id>  Parent node ID to link via references when applying
                 (finding->source_pitfall uses addresses edge so
                  wv audit-pitfalls marks the source as [ADDRESSED])

Promoted findings use metadata.type="finding" and nested
  finding.{violation_type, root_cause, proposed_fix, confidence, fixable};
  confidence must be high|medium|low and evidence_sessions is optional.
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

cmd_findings_list() {
    local format="text"
    local fixable_only=false
    local limit=20
    local show_all=false

    while [ $# -gt 0 ]; do
        case "$1" in
            --json)    format="json" ;;
            --fixable) fixable_only=true ;;
            --all)     show_all=true ;;
            --limit=*) limit="${1#--limit=}" ;;
            --help|-h)
                echo "Usage: wv findings list [--fixable] [--json] [--limit=N | --all]" >&2
                echo "  Default: shows most recent 20. Use --all for full list (can be large)." >&2
                return 0
                ;;
            *)
                echo -e "${RED}Unexpected argument: $1${NC}" >&2
                return 1
                ;;
        esac
        shift
    done

    local fixable_clause=""
    if [ "$fixable_only" = true ]; then
        fixable_clause="AND json_extract(n.metadata, '$.finding.fixable') = 1"
    fi

    local limit_clause=""
    if [ "$show_all" != true ]; then
        limit_clause="LIMIT $limit"
    fi

    local total
    total=$(db_query "SELECT COUNT(*) FROM nodes n WHERE json_extract(n.metadata, '\$.type') = 'finding' $fixable_clause;" 2>/dev/null || echo 0)
    : "${total:=0}"

    local query="
        SELECT
            n.id,
            n.status,
            json_extract(n.metadata, '$.finding.fixable')    AS fixable,
            json_extract(n.metadata, '$.finding.confidence') AS confidence,
            json_extract(n.metadata, '$.finding.violation_type') AS violation_type,
            n.text,
            CASE WHEN EXISTS (
                SELECT 1 FROM edges e
                JOIN nodes t ON e.source = t.id
                WHERE e.target = n.id AND e.type = 'resolves' AND t.status != 'done'
            ) THEN 1 ELSE 0 END AS has_fix
        FROM nodes n
        WHERE json_extract(n.metadata, '$.type') = 'finding'
        $fixable_clause
        ORDER BY n.created_at DESC
        $limit_clause;
    "

    if [ "$format" = "json" ]; then
        local results
        results=$(db_query_json "SELECT n.id, n.text, n.status, n.metadata FROM nodes n
            WHERE json_extract(n.metadata, '$.type') = 'finding'
            $fixable_clause
            ORDER BY n.created_at DESC
            $limit_clause;")
        [ -z "$results" ] && echo "[]" || echo "$results"
        return
    fi

    local rows
    rows=$(db_query "$query")

    if [ -z "$rows" ]; then
        echo "No finding nodes found." >&2
        return 0
    fi

    local count=0
    while IFS='|' read -r id status fixable confidence violation_type text has_fix; do
        count=$((count + 1))
        # Fixable badge (compact)
        local fix_badge
        if [ "$fixable" = "1" ]; then
            fix_badge="fixable"
        else
            fix_badge="not-fixable"
        fi
        # Fix-in-progress indicator
        local fix_status=""
        [ "$has_fix" = "1" ] && fix_status=" [FIX]"
        # Confidence (compact)
        local conf_str="${confidence:-?}"
        local vtype="${violation_type:-unknown}"
        # Strip "Finding: " prefix and truncate to 72 chars
        local display_text
        display_text=$(echo "$text" | sed 's/^[Ff]inding: //' | cut -c1-72)
        # Status only shown if not done
        local status_tag=""
        [ "$status" != "done" ] && status_tag=" [$status]"
        echo -e "${CYAN}$id${NC}${status_tag} $fix_badge conf=$conf_str $vtype${fix_status}"
        echo -e "  $display_text"
    done <<< "$rows"

    echo ""
    if [ "$show_all" != true ] && [ "$count" -lt "$total" ]; then
        echo "$count of $total finding(s) shown. Use --all or --limit=N for more."
    else
        echo "$count finding(s) total."
    fi
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
