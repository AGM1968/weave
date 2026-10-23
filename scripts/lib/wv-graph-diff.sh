#!/usr/bin/env bash
# wv-graph-diff.sh -- the durable graph tables, and a read-only comparison of
# two copies of one repository's graph over them (wv hotzone diff).
#
# Source-only: defines WV_DURABLE_TABLES and wv_graph_diff, and has no
# dependencies, because scripts/wv runs `wv hotzone diff` before wv-config.sh
# resolves placement (wv-757de1). The diff is what a repository whose
# placement conflicts (its database in two hot zones) needs in order to
# recover, and that same conflict makes wv-config.sh refuse every command, so
# the comparison must not depend on resolving a hot zone at all. It takes two
# explicit database paths, opens both read-only, and resolves or creates no hot
# zone. Read-only is SQLite's: it writes no page of either database, though a
# reader of a WAL database that has no -wal/-shm beside it creates them, as
# any reader does. immutable=1 would avoid that by ignoring the WAL, which
# would compare a live copy without its newest commits.

# The tables wv sync exports to .weave/state.sql (dump_state_sql) and wv load
# restores: everything a repository keeps when one copy of its graph is
# chosen over another. FTS, the delta tracker and caches are rebuilt on load.
# dump_state_sql dumps exactly this list, and wv_graph_diff refuses a table it
# has no comparison for, so a newly exported table cannot be skipped by the
# comparison the removal procedure relies on (wv-4898f7).
WV_DURABLE_TABLES=(nodes edges node_files tombstones)

# wv_replay_clock_sql <schema> — the query wv load's legacy-delta guard reads
# (wv-875c72): MAX(nodes.updated_at) normalised to epoch seconds. Without a
# causal-cutover marker, a pre-wv-875c72 INSERT OR REPLACE node delta whose
# filename epoch is at or below this clock is skipped as stale, and replayed
# above it. It is the one place updated_at decides what a load keeps, so
# cmd_load and wv_graph_diff both read it from here (wv-8d4f7d): copies with
# different clocks can load the same legacy catalog to different text.
wv_replay_clock_sql() {
    cat <<SQL
SELECT COALESCE(MAX(
    CASE
        WHEN typeof(updated_at) IN ('integer','real') THEN CAST(updated_at AS INTEGER)
        WHEN CAST(updated_at AS TEXT) != ''
             AND CAST(updated_at AS TEXT) NOT GLOB '*[^0-9]*'
        THEN CAST(updated_at AS INTEGER)
        ELSE CAST(strftime('%s', updated_at) AS INTEGER)
    END
), 0)
FROM ${1:-main}.nodes;
SQL
}

# _wv_graph_diff_sql <table> <lineage> — the comparison of one durable table
# between main (the first database) and other (the second), one line per
# difference. <lineage> is 1 when both copies carry lineage_seq/lineage_actor.
# Lineage is compared, not ignored (wv-60911e): _reconcile_tombstones deletes a
# node or edge whose (lineage_seq, lineage_actor) is at or below its
# tombstone's, so two copies agreeing on content but not on lineage can keep
# an entity in one and delete it in the other. Per-row created_at/updated_at
# decide nothing; the one timestamp authority, the replay clock, is compared
# separately (wv_replay_clock_sql).
_wv_graph_diff_sql() {
    local lin="${2:-1}" nl="" el="" tl=""
    if [ "$lin" = 1 ]; then
        nl="OR m.lineage_seq IS NOT o.lineage_seq OR m.lineage_actor IS NOT o.lineage_actor"
        el="OR e.lineage_seq IS NOT x.lineage_seq OR e.lineage_actor IS NOT x.lineage_actor"
        tl="t.lineage_seq IS NOT x.lineage_seq OR t.lineage_actor IS NOT x.lineage_actor"
    fi
    case "$1" in
        nodes)
            cat <<SQL
SELECT 'only in first:  node ' || id FROM main.nodes WHERE id NOT IN (SELECT id FROM other.nodes)
UNION ALL SELECT 'only in second: node ' || id FROM other.nodes WHERE id NOT IN (SELECT id FROM main.nodes)
UNION ALL SELECT 'differs:        node ' || m.id || ' (' || rtrim(
    CASE WHEN m.text IS NOT o.text THEN 'text ' ELSE '' END ||
    CASE WHEN m.status IS NOT o.status THEN 'status ' ELSE '' END ||
    CASE WHEN m.metadata IS NOT o.metadata THEN 'metadata ' ELSE '' END ||
    CASE WHEN m.alias IS NOT o.alias THEN 'alias ' ELSE '' END ||
    $( [ "$lin" = 1 ] && echo "CASE WHEN ${nl#OR } THEN 'lineage ' || m.lineage_seq || ':' || m.lineage_actor || ' vs ' || o.lineage_seq || ':' || o.lineage_actor ELSE '' END" || echo "''" )) || ')'
  FROM main.nodes m JOIN other.nodes o ON o.id = m.id
  WHERE m.text IS NOT o.text OR m.status IS NOT o.status
     OR m.metadata IS NOT o.metadata OR m.alias IS NOT o.alias $nl;
SQL
        ;;
        edges)
            cat <<SQL
SELECT 'only in first:  edge ' || source || ' -' || type || '-> ' || target FROM main.edges e
  WHERE NOT EXISTS (SELECT 1 FROM other.edges x WHERE x.source = e.source AND x.target = e.target AND x.type = e.type)
UNION ALL SELECT 'only in second: edge ' || source || ' -' || type || '-> ' || target FROM other.edges e
  WHERE NOT EXISTS (SELECT 1 FROM main.edges x WHERE x.source = e.source AND x.target = e.target AND x.type = e.type)
UNION ALL SELECT 'differs:        edge ' || e.source || ' -' || e.type || '-> ' || e.target || ' (' || rtrim(
    CASE WHEN e.weight IS NOT x.weight THEN 'weight ' ELSE '' END ||
    CASE WHEN e.context IS NOT x.context THEN 'context ' ELSE '' END ||
    $( [ "$lin" = 1 ] && echo "CASE WHEN ${el#OR } THEN 'lineage ' || e.lineage_seq || ':' || e.lineage_actor || ' vs ' || x.lineage_seq || ':' || x.lineage_actor ELSE '' END" || echo "''" )) || ')'
  FROM main.edges e JOIN other.edges x ON x.source = e.source AND x.target = e.target AND x.type = e.type
  WHERE e.weight IS NOT x.weight OR e.context IS NOT x.context $el;
SQL
        ;;
        node_files)
            cat <<'SQL'
SELECT 'only in first:  file ' || node_id || ' ' || path FROM main.node_files f
  WHERE NOT EXISTS (SELECT 1 FROM other.node_files x WHERE x.node_id = f.node_id AND x.path = f.path)
UNION ALL SELECT 'only in second: file ' || node_id || ' ' || path FROM other.node_files f
  WHERE NOT EXISTS (SELECT 1 FROM main.node_files x WHERE x.node_id = f.node_id AND x.path = f.path);
SQL
        ;;
        tombstones)
            # The tombstone's lineage is the deletion threshold itself: the
            # same tombstone at two thresholds keeps a recreated entity
            # between them in one copy and deletes it in the other.
            cat <<'SQL'
SELECT 'only in first:  tombstone ' || kind || ' ' || id || ' (lineage ' || lineage_seq || ':' || lineage_actor || ')' FROM main.tombstones t
  WHERE NOT EXISTS (SELECT 1 FROM other.tombstones x WHERE x.kind = t.kind AND x.id = t.id)
UNION ALL SELECT 'only in second: tombstone ' || kind || ' ' || id || ' (lineage ' || lineage_seq || ':' || lineage_actor || ')' FROM other.tombstones t
  WHERE NOT EXISTS (SELECT 1 FROM main.tombstones x WHERE x.kind = t.kind AND x.id = t.id)
UNION ALL SELECT 'differs:        tombstone ' || t.kind || ' ' || t.id || ' (lineage ' || t.lineage_seq || ':' || t.lineage_actor || ' vs ' || x.lineage_seq || ':' || x.lineage_actor || ')'
  FROM main.tombstones t JOIN other.tombstones x ON x.kind = t.kind AND x.id = t.id
SQL
            [ -n "$tl" ] && echo "  WHERE $tl;" || echo "  WHERE 0;"
        ;;
        *) return 1 ;;
    esac
}

# _wv_graph_diff_inspect <db> — print "<tables> lineage=<0|1>": the durable
# tables <db> has, and whether its nodes and edges carry lineage. Fails, exit
# 2 after saying why, when <db> cannot be read as an SQLite database or lacks
# the core tables nodes and edges (wv-57ee72): an inspection error must never
# read as an absent table, or two unreadable files would compare equal. Only
# node_files and tombstones may be absent, from a graph that predates them;
# dump_state_sql then exports nothing for them.
_wv_graph_diff_inspect() {
    local db="$1" out t have="" lin
    if ! out=$(sqlite3 -readonly "$db" "SELECT name FROM sqlite_master WHERE type = 'table';" 2>&1); then
        echo "wv hotzone diff: cannot read $db as an SQLite database: ${out//$'\n'/ }" >&2
        return 2
    fi
    for t in "${WV_DURABLE_TABLES[@]}"; do
        if grep -qxF -- "$t" <<< "$out"; then
            have+="$t "
        elif [ "$t" = nodes ] || [ "$t" = edges ]; then
            echo "wv hotzone diff: $db is not a Weave graph: it has no $t table" >&2
            return 2
        fi
    done
    if ! lin=$(sqlite3 -readonly "$db" "SELECT (SELECT count(*) FROM pragma_table_info('nodes') WHERE name IN ('lineage_seq','lineage_actor')) + (SELECT count(*) FROM pragma_table_info('edges') WHERE name IN ('lineage_seq','lineage_actor'));" 2>&1); then
        echo "wv hotzone diff: cannot inspect $db: ${lin//$'\n'/ }" >&2
        return 2
    fi
    case "$lin" in
        4) lin=1 ;;
        0) lin=0 ;;
        *) echo "wv hotzone diff: $db has a partial lineage schema; open it with wv first (wv-60911e)" >&2
           return 2 ;;
    esac
    echo "${have}lineage=${lin}"
}

# wv_graph_diff <first.db> <second.db> — compare two copies of one graph over
# every durable table, read-only. Prints each difference and a verdict.
# Exit 0 identical, 1 different, 2 unusable arguments or a database that is
# unreadable or not a Weave graph.
wv_graph_diff() {
    local first="${1:-}" second="${2:-}" table sql out all="" n fa sa lin fh sh holder side
    if [ -z "$first" ] || [ -z "$second" ] || [ ! -s "$first" ] || [ ! -s "$second" ]; then
        echo "Usage: wv hotzone diff <brain.db> <brain.db>  (two existing databases)" >&2
        return 2
    fi
    case "$second" in
        *"'"*|*'?'*|*'#'*|*'%'*)
            echo "wv hotzone diff: path contains ' ? # or %, which a read-only attach cannot take: $second" >&2
            return 2 ;;
    esac
    fa=$(_wv_graph_diff_inspect "$first") || return 2
    sa=$(_wv_graph_diff_inspect "$second") || return 2
    if [ "${fa##*lineage=}" != "${sa##*lineage=}" ]; then
        echo "wv hotzone diff: only one copy carries lineage, which decides what tombstones delete; open both with wv first, then compare (wv-60911e)" >&2
        return 2
    fi
    lin="${fa##*lineage=}"
    for table in "${WV_DURABLE_TABLES[@]}"; do
        if ! sql=$(_wv_graph_diff_sql "$table" "$lin"); then
            echo "wv hotzone diff: no comparison for durable table '$table'; refusing to report the copies identical" >&2
            return 2
        fi
        case " $fa " in *" $table "*) fh=1 ;; *) fh=0 ;; esac
        case " $sa " in *" $table "*) sh=1 ;; *) sh=0 ;; esac
        if [ "$fh$sh" = 00 ]; then
            continue
        elif [ "$fh$sh" = 01 ] || [ "$fh$sh" = 10 ]; then
            # Absent in one copy (it predates the table): every row the other
            # holds is a difference.
            if [ "$fh" = 1 ]; then holder="$first"; side="first: "; else holder="$second"; side="second:"; fi
            if ! out=$(sqlite3 -readonly "$holder" "SELECT count(*) FROM $table;" 2>&1); then
                echo "wv hotzone diff: cannot read $table in $holder: ${out//$'\n'/ }" >&2
                return 2
            fi
            [ "$out" != "0" ] && all+="only in ${side} ${out} ${table} row(s); the other database has no ${table} table"$'\n'
            continue
        fi
        if ! out=$(sqlite3 -readonly "$first" "ATTACH DATABASE 'file:${second}?mode=ro' AS other; $sql" 2>&1); then
            echo "wv hotzone diff: could not compare $table in $first and $second: ${out//$'\n'/ }" >&2
            return 2
        fi
        [ -n "$out" ] && all+="$out"$'\n'
    done
    # The replay clock decides legacy-delta replay (wv-8d4f7d); report it
    # whenever it differs, with both values, whatever the tables say.
    local fc sc
    if ! fc=$(sqlite3 -readonly "$first" "$(wv_replay_clock_sql main)" 2>&1) \
        || ! sc=$(sqlite3 -readonly "$second" "$(wv_replay_clock_sql main)" 2>&1); then
        echo "wv hotzone diff: could not read the replay clock of $first or $second" >&2
        return 2
    fi
    [ "$fc" != "$sc" ] && all+="differs:        replay clock ${fc} vs ${sc} (MAX nodes.updated_at: without a causal-cutover marker, wv load skips a legacy INSERT OR REPLACE delta at or below it)"$'\n'
    echo "first:  $first"
    echo "second: $second"
    if [ -z "$all" ]; then
        echo "identical: ${WV_DURABLE_TABLES[*]} agree"
        return 0
    fi
    printf '%s' "$all"
    local -a lines
    mapfile -t lines <<< "${all%$'\n'}"
    n=${#lines[@]}
    echo "${n} difference(s): carry every change the kept copy lacks into it with wv commands before removing the other"
    return 1
}
