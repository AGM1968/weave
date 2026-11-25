#!/bin/bash
# wv-db-lineage.sh — writer-lineage schema: classify it, repair it, refuse what
# cannot be repaired.
#
# Sourced by wv-db.sh, which owns the rest of the schema. This is a module of
# its own because the classifier is shared: wv doctor asks it the same question
# db_migrate_lineage asks, and a diagnostic that reimplements the shape it is
# diagnosing is how a database that could not sync passed its own health check.
# Keeping the pair in one file makes that sharing structural rather than a
# convention two call sites happen to follow.

# Migrate nodes and edges to carry writer lineage (wv-e1556b, epic delta-causality).
#
# Delta replay used to resolve every conflict by comparing wall clocks, which is
# not an ordering that can answer "which write happened after the other"
# (docs/PROPOSAL-delta-causality.md). These two columns carry the information the
# comparison was missing: which actor last wrote the row, and at what point on
# that actor's Lamport counter.
#
# lineage_seq is a Lamport value, not a timestamp. It is only ever compared to
# other lineage_seq values, and an actor advances it past the maximum it has
# observed, so it is monotonic per actor by construction and comparable across
# actors. (lineage_seq, lineage_actor) is a total order with a deterministic
# tie-break for concurrent writes.
#
# The CHECK constraints are the point, not decoration. nodes.updated_at is
# declared DATETIME (NUMERIC affinity) but is written as TEXT by
# CURRENT_TIMESTAMP and as INTEGER by direct SQL; SQLite orders every INTEGER
# before every TEXT, so a mixed-storage-class column does not compare values at
# all, it compares storage classes and one side wins unconditionally. Pinning the
# storage class at write time is what stops the replacement inheriting that.
#
# Backfill is deterministic: pre-causality rows take ('', 0), which sorts before
# every real lineage and identifies them as pre-cutover to the loader.
#
# Called from db_init as well as from cmd_load, so a freshly created database and
# a migrated one carry byte-identical schema text — ALTER TABLE appends columns
# at the end of the stored CREATE TABLE, which a hand-written CREATE TABLE in the
# db_init heredoc could not reproduce. state.sql is compared byte-wise by the
# auto_sync no-op guard, so that divergence would be permanent churn between
# agents.
#
# Canonical column order is (lineage_actor, lineage_seq) on BOTH tables — the
# order this migration produces on a clean table. ALTER TABLE ADD COLUMN can only
# append, so a load-migrate reaches that order only when the snapshot it imported
# carried no lineage columns or already carried them in this order.
#
# The repair is therefore per table and per column, driven by what
# pragma_table_info reports rather than by hope. It was four ALTERs in one
# sqlite3 script wrapped in `2>/dev/null || true`, which can neither converge nor
# report that it did not:
#   - a database whose nodes are already migrated hits `duplicate column name` on
#     statement 1, and a CLI that bails on the first script error never reaches
#     either edges statement. Whether it bails is a property of the sqlite3
#     build, not of the SQL: 3.46.1 prints the error and carries on (exit 1),
#     which is why the consumer's Debian 12 CLI ends up half-migrated where this
#     machine does not. tests/test-data.sh pins that mode with a `-bail` shim
#     rather than trusting whichever build happens to run the suite.
#   - `2>/dev/null || true` then discarded the error text AND the exit status, so
#     a schema the migration had not established was indistinguishable from one
#     it had.
# That shipped in rc.11 and cost a consumer every wv sync and every
# `commit-refs --prune` for the life of the database (wv-e1556b) — the failure
# repeats identically on each retry, so it never self-heals.
#
# A shape ALTER TABLE cannot reach — lineage_seq present without lineage_actor,
# or the two already reversed — is NOT repaired in place: appending the missing
# column would pin a non-canonical order into the stored CREATE TABLE text, and
# state.sql is byte-compared by the auto_sync no-op guard, so the "repair" would
# become permanent churn between agents. Those shapes fail loudly with recovery
# guidance instead (that is how the wv-e1556b snapshot first shipped — nodes with
# lineage_seq alone, later auto-synced to a reversed (seq, actor)). Two things
# follow:
#   - a diverged snapshot must be REGENERATED from a canonical db_init database
#     (see wv-5d3ba8), never hand-patched;
#   - a hot-zone DB already migrated in the wrong order does NOT self-heal on
#     `wv load` — cmd_load's pre-flight `auto_sync --force` dumps that DB over
#     state.sql first. Recover by moving the hot zone aside so the reload has
#     no live DB to flush, keeping the old copy to diff (hot_zone_rebuild_advice,
#     wv-4ccc98).
# tests/test-data.sh guards the committed .weave/state.sql against regressing to
# a non-db_init order.

# db_lineage_shape TABLE — classify a table's writer-lineage columns from
# pragma_table_info, in stored order. Prints exactly one of:
#   canonical  (lineage_actor, lineage_seq) — nothing to do
#   absent     neither column               — repairable, append both
#   actor-only lineage_actor alone          — repairable, append lineage_seq
#   seq-only   lineage_seq alone            — NOT repairable, appending reverses
#   reversed   (lineage_seq, lineage_actor) — NOT repairable, already reversed
#   no-table   the table does not exist yet (db_init has not run)
#   unknown    the query itself failed
# One sqlite3 invocation, because both this and wv doctor call it on paths that
# run per load. Shared with doctor so the CLI and its diagnostic cannot disagree
# about what shape the database is in. The classification is done in SQL rather
# than by a bash case over the column list: same answer, and the branch count
# stays out of this file's complexity budget (the bash CC backend attributes
# every branch after db_init to db_init).
db_lineage_shape() {
    local _t="$1" _shape
    _shape=$(sqlite3 "$WV_DB" "
        SELECT CASE
            WHEN (SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='$_t') = 0
                THEN 'no-table'
            WHEN _cols = 'lineage_actor,lineage_seq' THEN 'canonical'
            WHEN _cols = 'lineage_seq,lineage_actor' THEN 'reversed'
            WHEN _cols = 'lineage_actor'             THEN 'actor-only'
            WHEN _cols = 'lineage_seq'               THEN 'seq-only'
            WHEN _cols = ''                          THEN 'absent'
            ELSE 'unknown'
        END FROM (SELECT COALESCE((SELECT group_concat(name) FROM (
                     SELECT name FROM pragma_table_info('$_t')
                     WHERE name IN ('lineage_actor','lineage_seq') ORDER BY cid)), '') AS _cols);
        " 2>/dev/null) || _shape=""
    printf '%s' "${_shape:-unknown}"
}

# _db_lineage_add_column TABLE COLUMN — one ALTER, one sqlite3 invocation, so a
# duplicate-column error on one column cannot suppress the repair of another.
# The column text is identical to what a fresh db_init produces; state.sql is
# byte-compared, so it has to be.
_db_lineage_add_column() {
    local _t="$1" _c="$2" _sql _err
    case "$_c" in
        lineage_actor) _sql="ALTER TABLE $_t ADD COLUMN lineage_actor TEXT NOT NULL DEFAULT '' CHECK(typeof(lineage_actor) = 'text');" ;;
        lineage_seq)   _sql="ALTER TABLE $_t ADD COLUMN lineage_seq INTEGER NOT NULL DEFAULT 0 CHECK(typeof(lineage_seq) = 'integer');" ;;
        *) return 1 ;;
    esac
    if ! _err=$(sqlite3 "$WV_DB" "$_sql" 2>&1); then
        echo "Error: lineage migration could not add $_t.$_c: $_err" >&2
        return 1
    fi
    return 0
}

# db_lineage_pair_verdict NODES_SHAPE EDGES_SHAPE — the verdict for the PAIR.
#
# The shape of one table decides nothing on its own: what matters is whether the
# two together are a state the database is allowed to be in. Four verdicts, and
# every pair maps to exactly one:
#   canonical     both tables canonical — nothing to do
#   preinit       BOTH tables absent — db_init has not created them yet
#   repairable    both shapes are ones ALTER TABLE can reach from — migrate
#   unrepairable  everything else
#
# 'no-table' is benign only when it describes both tables. A mixed pair —
# nodes canonical, edges not created — was previously read as benign by a
# substring match here and by an `||` in wv doctor, so a database that could not
# sync passed its own diagnostic with an advisory. That is the same blind spot
# the lineage repair was written to close, one level up: integrity_check does not
# look at columns, and neither of those looked at the pair.
db_lineage_pair_verdict() {
    local _n="$1" _e="$2"
    if [ "$_n" = "canonical" ] && [ "$_e" = "canonical" ]; then printf 'canonical'; return 0; fi
    if [ "$_n" = "no-table" ] && [ "$_e" = "no-table" ]; then printf 'preinit'; return 0; fi
    case "$_n" in canonical|absent|actor-only) ;; *) printf 'unrepairable'; return 0 ;; esac
    case "$_e" in canonical|absent|actor-only) ;; *) printf 'unrepairable'; return 0 ;; esac
    printf 'repairable'
}

# _db_lineage_unrepairable_report SHAPES — the one message a consumer sees when
# the schema cannot be established, naming the shape found and the exact
# recovery. Silence here is what turned a schema bug into a permanent outage.
_db_lineage_unrepairable_report() {
    echo "Error: writer-lineage schema is not canonical and could not be repaired ($1)" >&2
    echo "  required: (lineage_actor, lineage_seq) on both nodes and edges" >&2
    echo "  ALTER TABLE can only append, so a reversed or seq-first shape cannot be repaired in place." >&2
    echo "  wv sync and wv commit-refs cannot persist until this is fixed. Recover with:" >&2
    echo "    $(hot_zone_rebuild_advice 2>/dev/null || echo "move the hot zone aside (never delete it), wv load, then wv hotzone diff the old brain.db against the new one")" >&2
}

# _db_lineage_repair_pair — append what each table is missing, one ALTER per
# sqlite3 invocation. Only reached for a pair db_lineage_pair_verdict called
# repairable, so every shape here is one ALTER TABLE can append to without
# disturbing canonical order.
_db_lineage_repair_pair() {
    local _t _shape _rc=0
    for _t in nodes edges; do
        _shape=$(db_lineage_shape "$_t")
        case "$_shape" in
            canonical) ;;
            absent)
                _db_lineage_add_column "$_t" lineage_actor || _rc=1
                _db_lineage_add_column "$_t" lineage_seq || _rc=1
                ;;
            actor-only)
                _db_lineage_add_column "$_t" lineage_seq || _rc=1
                ;;
            *) _rc=1 ;;
        esac
    done
    return "$_rc"
}

db_migrate_lineage() {
    local _rc=0 _found="" _verdict _preinit=0
    _verdict=$(db_lineage_pair_verdict "$(db_lineage_shape nodes)" "$(db_lineage_shape edges)")
    case "$_verdict" in
        canonical) ;;
        preinit)
            # db_init has not created the tables yet. It calls this immediately
            # after creating them, and cmd_load calls it against a database
            # state.sql has just replaced, so there is nothing here to repair —
            # and, below, nothing to index either.
            _preinit=1
            ;;
        repairable) _db_lineage_repair_pair || _rc=1 ;;
        *) _rc=1 ;;
    esac
    # Postcondition, verified rather than assumed: the defect this replaces was a
    # migration that reported success on a schema it had never established. The
    # verdict is recomputed from the database rather than inferred from the
    # branch that ran, so a repair that silently did nothing fails here.
    _found="nodes=$(db_lineage_shape nodes), edges=$(db_lineage_shape edges)"
    if [ "$_rc" -eq 0 ]; then
        case "$(db_lineage_pair_verdict "$(db_lineage_shape nodes)" "$(db_lineage_shape edges)")" in
            canonical|preinit) ;;
            *) _rc=1 ;;
        esac
    fi
    if [ "$_rc" -ne 0 ]; then
        _db_lineage_unrepairable_report "$_found"
        return 1
    fi
    # Two objects the lineage columns are a precondition for, in one script
    # because they share that precondition and one failure message:
    #   - the replay indexes: replay orders by (lineage_seq, lineage_actor) and
    #     seeds an actor's counter from the maximum it can observe, both covering
    #     -index reads. An index that silently failed to exist is a slow replay
    #     nobody would trace back to here.
    #   - the cross-machine deletion tombstone (epic delta-causality, wv-ba9dc8 +
    #     wv-0d5e07), which replaces the gitignored machine-local
    #     .weave/.prune_epoch: dump_state_sql emits this table so a delete travels
    #     to every clone. Delta v2 node_delete/edge_delete write a row here on the
    #     op lineage; the v1 paths wv delete / wv prune write one on the deleted
    #     row's own lineage via db_write_tombstone. cmd_load's
    #     _reconcile_tombstones then removes any entity the delta back-catalog
    #     resurrected at or below its tombstone lineage_seq, while a genuine
    #     higher-lineage recreate survives. It lives here rather than in the
    #     db_init heredoc so a fresh and a migrated database carry byte-identical
    #     CREATE TABLE text (state.sql is byte-compared by auto_sync).
    # Checked, not swallowed — but a database whose tables db_init has not created
    # yet has nothing to index, and that is not a failure.
    local _obj_err
    if ! _obj_err=$(sqlite3 "$WV_DB" <<'MIGRATE_OBJECTS' 2>&1
CREATE INDEX IF NOT EXISTS idx_nodes_lineage ON nodes(lineage_seq, lineage_actor);
CREATE INDEX IF NOT EXISTS idx_edges_lineage ON edges(lineage_seq, lineage_actor);
CREATE TABLE IF NOT EXISTS tombstones (
    kind TEXT NOT NULL CHECK(kind IN ('node','edge')),
    id TEXT NOT NULL,
    lineage_seq INTEGER NOT NULL DEFAULT 0 CHECK(typeof(lineage_seq) = 'integer'),
    lineage_actor TEXT NOT NULL DEFAULT '' CHECK(typeof(lineage_actor) = 'text'),
    PRIMARY KEY (kind, id)
);
MIGRATE_OBJECTS
    ) && [ "$_preinit" -ne 1 ]; then
        echo "Error: lineage migration could not create the replay indexes or the tombstones table: $_obj_err" >&2
        return 1
    fi
    return 0
}

