#!/bin/bash
# wv-cmd-findings.sh -- Finding node commands
#
# Commands: findings list, findings promote
# Sourced by: wv entry point (after lib modules)
# Dependencies: wv-config.sh, wv-db.sh, wv-validate.sh

_wv_findings_python() {
    local _wv_pypath
    _wv_pypath=$(_wv_python_module_path weave_quality)
    _wv_agent_python_exec_module weave_quality "$_wv_pypath" "$@"
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
    local stale_days=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --json)     format="json" ;;
            --fixable)  fixable_only=true ;;
            --all)      show_all=true ;;
            --limit=*)  limit="${1#--limit=}" ;;
            --stale=*)  stale_days="${1#--stale=}" ;;
            --help|-h)
                echo "Usage: wv findings list [--fixable] [--json] [--limit=N | --all] [--stale=N]" >&2
                echo "  --stale=N   show only findings promoted more than N days ago" >&2
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

    local stale_clause=""
    if [ -n "$stale_days" ]; then
        stale_clause="AND (
            json_extract(n.metadata, '\$.promoted_at') IS NOT NULL
            AND CAST((julianday('now') - julianday(json_extract(n.metadata, '\$.promoted_at'))) AS INTEGER) >= $stale_days
        )"
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
            CASE WHEN EXISTS (
                SELECT 1 FROM edges e
                JOIN nodes t ON e.source = t.id
                WHERE e.target = n.id AND e.type = 'resolves' AND t.status != 'done'
            ) THEN 1 ELSE 0 END AS has_fix,
            CASE
                WHEN json_extract(n.metadata, '\$.promoted_at') IS NOT NULL
                THEN CAST((julianday('now') - julianday(json_extract(n.metadata, '\$.promoted_at'))) AS INTEGER)
                ELSE NULL
            END AS age_days,
            n.text
        FROM nodes n
        WHERE json_extract(n.metadata, '$.type') = 'finding'
        $fixable_clause
        $stale_clause
        ORDER BY n.created_at DESC
        $limit_clause;
    "

    if [ "$format" = "json" ]; then
        local results
        results=$(db_query_json "SELECT n.id, n.text, n.status, n.metadata FROM nodes n
            WHERE json_extract(n.metadata, '$.type') = 'finding'
            $fixable_clause
            $stale_clause
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
    # text reads LAST: it can contain literal '|' (e.g. "fix | calibration: ...");
    # the final read variable absorbs the remainder, so internal pipes are safe.
    while IFS='|' read -r id status fixable confidence violation_type has_fix age_days text; do
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
        # Age — only shown when promoted_at is set
        local age_tag=""
        if [ -n "$age_days" ] && [ "$age_days" != "NULL" ]; then
            if [ "$age_days" -ge 14 ]; then
                age_tag=" ${YELLOW}${age_days}d${NC}"
            else
                age_tag=" ${age_days}d"
            fi
        fi
        echo -e "${CYAN}$id${NC}${status_tag} $fix_badge conf=$conf_str $vtype${fix_status}${age_tag}"
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
    local since_days=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --json)       json_flag="--json" ;;
            --top=*)      top_n="${1#--top=}" ;;
            --top)        shift; top_n="$1" ;;
            --since-days=*) since_days="${1#--since-days=}" ;;
            --since-days)   shift; since_days="$1" ;;
            --parent=*)   parent="${1#--parent=}" ;;
            --parent)     shift; parent="$1" ;;
            --dry-run)    dry_run="--dry-run" ;;
            --apply)      apply="--apply" ;;
            --include-guardrails) include_guardrails="--include-guardrails" ;;
            --include-root-causes) include_root_causes="--include-root-causes" ;;
            --include-tooling) include_tooling="--include-tooling" ;;
            --help|-h)
                echo "Usage: wv findings promote [--top=N] [--since-days=N] [--json] [--dry-run] [--include-guardrails] [--include-root-causes] [--include-tooling] [--apply --parent=<node-id>]" >&2
                echo "  --top defines the reviewed candidate window; --apply does not backfill past that window." >&2
                echo "  --since-days gates stale signal: only promote learnings whose source node closed within N days (default 30; 0 disables)." >&2
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
    [ -n "$since_days" ] && py_args+=("--since-days" "$since_days")
    [ -n "$json_flag" ] && py_args+=("$json_flag")
    [ -n "$dry_run" ] && py_args+=("$dry_run")
    [ -n "$apply" ] && py_args+=("$apply")
    [ -n "$include_guardrails" ] && py_args+=("$include_guardrails")
    [ -n "$include_root_causes" ] && py_args+=("$include_root_causes")
    [ -n "$include_tooling" ] && py_args+=("$include_tooling")

    _wv_findings_python "${py_args[@]}"
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_validate_finding — validate finding metadata for a node
#
# Exit 0: valid  Exit 1: invalid
# Stdout: {"valid":true|false,"errors":[...]}
# ═══════════════════════════════════════════════════════════════════════════

cmd_validate_finding() {
    local id=""

    while [ $# -gt 0 ]; do
        case "$1" in
            -*)
                echo -e "${RED}Error: unknown flag '$1'${NC}" >&2; return 1 ;;
            *)
                if [ -z "$id" ]; then id="$1"; else
                    echo -e "${RED}Error: unexpected argument '$1'${NC}" >&2; return 1
                fi ;;
        esac
        shift
    done

    if [ -z "$id" ]; then
        echo -e "${RED}Error: node ID required${NC}" >&2; return 1
    fi

    db_ensure
    local resolved
    resolved=$(resolve_id "$id") || return 1

    local meta_raw
    meta_raw=$(db_query "SELECT metadata FROM nodes WHERE id='$(sql_escape "$resolved")';")
    if [ -z "$meta_raw" ]; then
        echo -e "${RED}Error: node $resolved not found${NC}" >&2; return 1
    fi

    local meta_json
    meta_json=$(printf '%s' "$meta_raw" | jq -r '.' 2>/dev/null || echo "{}")
    local node_type
    node_type=$(printf '%s' "$meta_json" | jq -r '.type // "task"' 2>/dev/null || echo "task")

    if [ "$node_type" != "finding" ]; then
        printf '{"valid":true,"errors":[],"note":"not a finding node"}\n'
        return 0
    fi

    local errors_raw
    errors_raw=$(_finding_missing_fields "$meta_json" 2>/dev/null || true)

    if [ -z "$errors_raw" ]; then
        printf '{"valid":true,"errors":[]}\n'
        return 0
    fi

    local errors_json
    errors_json=$(printf '%s\n' "$errors_raw" | jq -R . | jq -s . 2>/dev/null || echo '[]')
    printf '{"valid":false,"errors":%s}\n' "$errors_json"
    return 1
}
