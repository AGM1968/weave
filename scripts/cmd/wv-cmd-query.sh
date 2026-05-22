#!/usr/bin/env bash
# wv-cmd-query.sh — Unified predicate-based graph reader
# Commands: query
# Helpers:  _query_parse_predicate, _query_resolve_key, _query_build_sql,
#           _query_render, _query_render_table,
#           _render_include_learning, _render_include_finding, _render_include_hygiene

# ═══════════════════════════════════════════════════════════════════════════
# _query_resolve_key — map predicate key to SQL expression
# ═══════════════════════════════════════════════════════════════════════════

_query_resolve_key() {
    local key="$1"
    case "$key" in
        id|text|status|created_at|updated_at|alias) echo "n.$key" ;;
        # Virtual generated columns — faster than json_extract
        type)     echo "n.type" ;;
        priority) echo "n.priority" ;;
        # Computed: days since promoted_at (finding-specific; NULL for non-findings)
        stale)    echo "(julianday('now') - julianday(json_extract(n.metadata, '\$.promoted_at')))" ;;
        hygiene)  echo "json_extract(n.metadata, '\$.learning_hygiene')" ;;
        *)
            [[ "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || {
                echo "Error: invalid metadata key: $key" >&2; return 1
            }
            echo "json_extract(n.metadata, '\$.$key')" ;;
    esac
}

# ═══════════════════════════════════════════════════════════════════════════
# _query_parse_predicate — parse one predicate string to SQL fragment
# Returns empty string for MATCH predicates (handled by caller pre-scan).
# ═══════════════════════════════════════════════════════════════════════════

_query_parse_predicate() {
    local raw="$1"

    # HAS <key> — dual-schema aware for "learning"
    if [[ "$raw" == HAS\ * ]]; then
        local k="${raw#HAS }"
        [[ "$k" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || { echo "Error: invalid key: $k" >&2; return 1; }
        if [ "$k" = "learning" ]; then
            echo "(json_extract(n.metadata, '\$.learning') IS NOT NULL OR json_extract(n.metadata, '\$.decision') IS NOT NULL OR json_extract(n.metadata, '\$.pattern') IS NOT NULL OR json_extract(n.metadata, '\$.pitfall') IS NOT NULL)"
        else
            echo "json_extract(n.metadata, '\$.$k') IS NOT NULL"
        fi
        return 0
    fi

    # MATCH — state handled by pre-scan in _query_build_sql; return empty
    [[ "$raw" == MATCH\ * ]] && return 0

    # key IN (v1,v2,...)
    local k2 vals2
    k2=$(printf '%s' "$raw"   | sed -n 's/^\([A-Za-z_][A-Za-z0-9_.]*\) IN (\(.*\))$/\1/p')
    vals2=$(printf '%s' "$raw" | sed -n 's/^\([A-Za-z_][A-Za-z0-9_.]*\) IN (\(.*\))$/\2/p')
    if [ -n "$k2" ]; then
        local col; col=$(_query_resolve_key "$k2") || return 1
        local lst; lst=$(printf '%s' "$vals2" | sed "s/,/','/g;s/^/'/;s/\$/'/" )
        echo "$col IN ($lst)"
        return 0
    fi

    # key OP value
    local k op v
    k=$(printf '%s' "$raw"  | sed -n 's/^\([A-Za-z_][A-Za-z0-9_.]*\)\(>=\|<=\|!=\|=\|>\|<\).*$/\1/p')
    op=$(printf '%s' "$raw" | sed -n 's/^[A-Za-z_][A-Za-z0-9_.]*\(>=\|<=\|!=\|=\|>\|<\).*$/\1/p')
    v=$(printf '%s' "$raw"  | sed -n "s/^[A-Za-z_][A-Za-z0-9_.]*\(>=\|<=\|!=\|=\|>\|<\)//p")
    if [ -n "$k" ] && [ -n "$op" ] && [ -n "$v" ]; then
        local col; col=$(_query_resolve_key "$k") || return 1
        case "$op" in
            =|!=) printf "%s %s '%s'\n" "$col" "$op" "$(printf '%s' "$v" | sed "s/'/''/g")" ;;
            *)    printf "(%s) %s %s\n" "$col" "$op" "$v" ;;
        esac
        return 0
    fi

    echo "Error: cannot parse predicate: '$raw'" >&2
    return 1
}

# ═══════════════════════════════════════════════════════════════════════════
# _query_build_sql — assemble WHERE + ORDER + LIMIT
# Signature: _query_build_sql <from_source> <order> <limit> [predicates...]
#
# MATCH pre-scan: _qp_needs_fts state MUST be extracted before the parse loop.
# Setting it inside frag=$(parse_pred) runs in a subshell — assignment lost.
# ═══════════════════════════════════════════════════════════════════════════

_query_build_sql() {
    local from_source="$1" order="$2" limit="$3"; shift 3
    local -a preds=("$@")

    # Pre-scan for MATCH before parse loop (subshell cannot set globals)
    local needs_fts=0 fts_expr=""
    local -a non_match=()
    for p in "${preds[@]}"; do
        if [[ "$p" == MATCH\ * ]]; then
            needs_fts=1
            fts_expr="${p#MATCH }"
            fts_expr="${fts_expr%\"}"; fts_expr="${fts_expr#\"}"
        else
            non_match+=("$p")
        fi
    done

    local -a where_frags=()
    for p in "${non_match[@]}"; do
        local frag; frag=$(_query_parse_predicate "$p") || return 1
        [ -n "$frag" ] && where_frags+=("$frag")
    done

    local where_sql=""
    [ ${#where_frags[@]} -gt 0 ] && \
        where_sql="WHERE $(printf '%s AND ' "${where_frags[@]}" | sed 's/ AND $//')"

    local order_sql
    case "$order" in
        recent)    order_sql="n.created_at DESC" ;;
        oldest)    order_sql="n.created_at ASC" ;;
        relevance) order_sql="rank" ;;
        hygiene)   order_sql="json_extract(n.metadata, '\$.learning_hygiene') DESC" ;;
        stale)     order_sql="json_extract(n.metadata, '\$.promoted_at') ASC" ;;
        *)         order_sql="n.created_at DESC" ;;
    esac

    # Empty or "0" limit means unbounded (no LIMIT clause)
    local limit_clause=""
    [ -n "$limit" ] && [ "$limit" != "0" ] && limit_clause="LIMIT $limit"

    if [ "$needs_fts" = "1" ]; then
        # Double-quote phrase: neutralises operator injection, searches any FTS column
        local safe; safe=$(printf '%s' "$fts_expr" | sed 's/"/""/g')
        printf 'SELECT n.id, n.text, n.status, n.metadata, f.rank AS rank
              FROM nodes_fts f
              JOIN nodes n ON f.rowid = n.rowid
              WHERE nodes_fts MATCH '"'"'"%s"'"'"'
              %s
              ORDER BY rank
              %s;\n' \
            "$safe" \
            "${where_sql:+AND ${where_sql#WHERE }}" \
            "$limit_clause"
    else
        printf 'SELECT n.id, n.text, n.status, n.metadata
              FROM %s n
              %s
              ORDER BY %s
              %s;\n' \
            "$from_source" "$where_sql" "$order_sql" "$limit_clause"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# Render layer
# ═══════════════════════════════════════════════════════════════════════════

_render_include_learning() {
    local rows="$1"
    local _green _yellow _cyan _nc
    printf -v _green '%b' "$GREEN"
    printf -v _yellow '%b' "$YELLOW"
    printf -v _cyan '%b' "$CYAN"
    printf -v _nc '%b' "$NC"
    # Port of _learnings_format_text from wv-cmd-data.sh — dual-schema aware
    echo "$rows" | jq -r --arg G "$_green" --arg Y "$_yellow" \
        --arg C "$_cyan" --arg N "$_nc" '
        .[] |
        .id as $id | .text as $text |
        ((.metadata // "{}") | if type == "string" then fromjson else . end) as $m |
        ($m.decision // null) as $td |
        ($m.pattern  // null) as $tp |
        ($m.pitfall  // null) as $tpi |
        ($m.learning // "") as $raw |
        (if ($td or $tp or $tpi) then
          {decision: $td, pattern: $tp, pitfall: $tpi, note: null}
        elif ($raw | test("^(decision|pattern|pitfall):"; "i")) then
          ($raw | gsub(";\\s*(?<m>(decision|pattern|pitfall):)"; " | \(.m)"; "i")
               | until(test("\\|\\s*\\|") | not; gsub("\\|\\s*\\|"; "|"))) as $norm |
          ($norm | split(" | ") | map(select(length > 0) | gsub("^\\s+|\\s+$"; "")) |
           map(select(length > 0)) | reduce .[] as $seg (
            {};
            if ($seg | test("^decision:"; "i")) then .decision = ($seg | sub("^decision:\\s*"; ""; "i"))
            elif ($seg | test("^pattern:"; "i"))  then .pattern  = ($seg | sub("^pattern:\\s*";  ""; "i"))
            elif ($seg | test("^pitfall:"; "i"))  then .pitfall  = ($seg | sub("^pitfall:\\s*";  ""; "i"))
            else
              if   .pitfall  then .pitfall  = .pitfall  + " | " + $seg
              elif .pattern  then .pattern  = .pattern  + " | " + $seg
              elif .decision then .decision = .decision + " | " + $seg
              else .note = ((.note // "") + (if .note then " | " else "" end) + $seg)
              end
            end
          ))
        elif ($raw | length > 0) then {note: $raw}
        else {}
        end) as $p |
        ($C + $id + $N + ": " + ($text | .[0:72])),
        (if $p.decision then "  " + $G + "Decision:" + $N + " " + $p.decision else empty end),
        (if $p.pattern  then "  " + $G + "Pattern:"  + $N + "  " + $p.pattern  else empty end),
        (if $p.pitfall  then "  " + $Y + "Pitfall:"  + $N + "  " + $p.pitfall  else empty end),
        (if $p.note     then "  Note: " + $p.note else empty end),
        ""
    ' 2>/dev/null
}

_render_include_finding() {
    local rows="$1"
    local _yellow _cyan _nc
    printf -v _yellow '%b' "$YELLOW"
    printf -v _cyan '%b' "$CYAN"
    printf -v _nc '%b' "$NC"
    # Note: has_fix requires JOIN to edges — not available here; omitted (Phase 1 known gap)
    echo "$rows" | jq -r --arg Y "$_yellow" --arg C "$_cyan" --arg N "$_nc" '
        .[] | select(
            ((.metadata // "{}") | if type == "string" then fromjson else . end) | .type == "finding"
        ) |
        .id as $id | .text as $text |
        ((.metadata // "{}") | if type == "string" then fromjson else . end) as $m |
        ($m.finding.fixable    // 0 | if . == 1 then "fixable" else "not-fixable" end) as $fix |
        ($m.finding.confidence // "?") as $conf |
        ($m.finding.violation_type // "unknown") as $vtype |
        (if $m.promoted_at then
            ((now - ($m.promoted_at | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime)) / 86400 | floor | tostring) + "d"
         else "" end) as $age |
        ($C + $id + $N + " " + $fix + " conf=" + $conf + " " + $vtype + (if $age != "" then " " + $age else "" end)),
        ("  " + ($text | ltrimstr("Finding: ") | ltrimstr("finding: ") | .[0:72])),
        ""
    ' 2>/dev/null
}

_render_include_hygiene() {
    local rows="$1"
    echo "$rows" | jq -r '
        .[] |
        .id as $id |
        ((.metadata // "{}") | if type == "string" then fromjson else . end) as $m |
        ($m.learning_hygiene // "n/a" | tostring) as $h |
        $id + "  hygiene=" + $h
    ' 2>/dev/null
}

_query_render_table() {
    local rows="$1"; shift
    local -a includes=("$@")
    local _cyan _nc
    printf -v _cyan '%b' "$CYAN"
    printf -v _nc '%b' "$NC"

    if [ -z "${includes[*]}" ] || [[ " ${includes[*]} " == *" text "* ]]; then
        # Default: id + truncated text
        echo "$rows" | jq -r --arg C "$_cyan" --arg N "$_nc" \
            '.[] | $C + .id + $N + ": " + (.text | .[0:72])' 2>/dev/null
        return
    fi

    for inc in "${includes[@]}"; do
        case "$inc" in
            learning) _render_include_learning "$rows" ;;
            finding)  _render_include_finding  "$rows" ;;
            hygiene)  _render_include_hygiene  "$rows" ;;
            text)
                echo "$rows" | jq -r --arg C "$_cyan" --arg N "$_nc" \
                    '.[] | $C + .id + $N + ": " + (.text | .[0:72])' 2>/dev/null ;;
        esac
    done
}

_query_render() {
    local format="$1" includes_str="$2" sql="$3"
    local -a includes=()
    [ -n "$includes_str" ] && IFS=',' read -ra includes <<< "$includes_str"

    case "$format" in
        json)
            # db_query_json_v2 expands metadata string → nested object
            db_query_json_v2 "$sql" ;;
        short)
            db_query "$sql" | awk -F'|' '{print $1}' ;;
        table|*)
            local rows
            rows=$(db_query_json "$sql") || return 1
            [ -z "$rows" ] || [ "$rows" = "[]" ] && { echo "No results." >&2; return 0; }
            _query_render_table "$rows" "${includes[@]}" ;;
    esac
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_query — main entry point
# ═══════════════════════════════════════════════════════════════════════════

_query_help() {
    cat <<'EOF'
Usage: wv query [predicates...] [--order=<field>] [--limit=N] [--format=table|json|short] [--include=<type>]

Predicates:
  key=value         exact match (column or metadata field)
  key!=value        not equal
  key>=N            numeric comparison (>=, <=, >, <)
  key IN (a,b,c)    membership
  HAS key           metadata field is present (HAS learning = dual-schema aware)
  MATCH "expr"      FTS5 phrase search across all indexed columns

Keys: id, text, status, type, priority, alias, created_at, updated_at,
      stale (days since promoted_at — findings only), hygiene, or any metadata field

Order: recent (default), oldest, relevance (MATCH only), hygiene, stale
Include: text (default), learning, finding, hygiene
Format: table (default), json (nested metadata), short (ids only)

Examples:
  wv query status=active
  wv query type=finding stale>=7 --include=finding
  wv query HAS learning --order=recent --limit=20 --include=learning
  wv query MATCH "sqlite" status=done --order=relevance --limit=10
  wv query status!=done type=task --format=json
EOF
}

cmd_query() {
    local format="table"
    local order="recent"
    local limit="20"
    local include_str=""
    local -a predicates=()

    while [ $# -gt 0 ]; do
        case "$1" in
            --help|-h)   _query_help; return 0 ;;
            --format=*)  format="${1#*=}" ;;
            --order=*)   order="${1#*=}" ;;
            --limit=*)   limit="${1#*=}" ;;
            --include=*) include_str="${1#*=}" ;;
            --*)
                echo "Error: unknown option: $1" >&2
                echo "Run 'wv query --help' for usage." >&2
                return 1 ;;
            # HAS/MATCH as two shell args — docs show unquoted form; parser requires
            # single-arg "HAS key". Consume next arg to rebuild the single-arg form.
            HAS)
                if [ $# -lt 2 ]; then
                    echo "Error: HAS requires a key argument (e.g. HAS learning)" >&2; return 1
                fi
                predicates+=("HAS $2"); shift ;;
            MATCH)
                if [ $# -lt 2 ]; then
                    echo "Error: MATCH requires an expression argument (e.g. MATCH \"query\")" >&2; return 1
                fi
                predicates+=("MATCH $2"); shift ;;
            *)           predicates+=("$1") ;;
        esac
        shift
    done

    db_ensure

    local sql
    sql=$(_query_build_sql "nodes" "$order" "$limit" "${predicates[@]}") || return 1
    _query_render "$format" "$include_str" "$sql"
}
