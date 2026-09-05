#!/usr/bin/env bash
# wv-delta.sh — Pure-bash delta tracking
# See docs/PROPOSAL-wv-delta.md for full design rationale.
#
# Overview
# --------
# SQLite triggers fire on every INSERT/UPDATE/DELETE to nodes and edges,
# writing a row to _warp_changes. Two uses:
#
#   1. O(1) change detection — auto_sync checks EXISTS(_warp_changes) before
#      deciding whether to run a full .dump. No changes = no I/O, no git noise.
#
#   2. Delta files — wv_delta_changeset emits executable SQL that describes
#      only what changed since the last reset. Saved to .weave/deltas/ and
#      replayed by other agents on wv load (multi-agent merge, Sprint 2+).
#
# History: the trigger schema and changeset format were proven in a Rust binary
# (warp-session, ~/Projects/warp/). That binary is a research artifact in a
# separate project; this file is the production implementation.
#
# Functions:
#   wv_delta_init         Create _warp_changes table + 6 triggers (idempotent)
#   wv_delta_has_changes  O(1) check → exit 0 if changes exist, exit 1 if not
#   wv_delta_reset        Clear all tracked changes
#   wv_delta_changeset    Emit SQL changeset to stdout
#   wv_delta_v2_write_operations
#                          Emit Delta v2 semantic operation JSON sidecars

# Shell cache: once _warp_changes is confirmed to exist, skip the probe SELECT
# on every auto_sync cycle (~60s). Saves one sqlite3 round-trip per cycle.
_WV_DELTA_INITED=""

# --- DDL ---
# This schema originated from warp/crates/warp-session/src/schema.rs (the Rust
# research prototype). The two implementations have since diverged: trigger
# payloads were extended here (created_at/updated_at on nodes) without updating
# the Rust crate. warp-session is a research artifact in a separate project and
# is not used in production. Delta files from different wv versions are compatible
# as long as they only reference columns that exist in the target DB schema.

_WV_DELTA_CREATE_TABLE="
CREATE TABLE IF NOT EXISTS _warp_changes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    table_name TEXT NOT NULL,
    operation TEXT NOT NULL CHECK(operation IN ('INSERT','UPDATE','DELETE')),
    row_id TEXT NOT NULL,
    old_data JSON,
    new_data JSON,
    ts DATETIME DEFAULT CURRENT_TIMESTAMP
);
"

_WV_DELTA_TRIGGERS_NODES="
CREATE TRIGGER IF NOT EXISTS _warp_nodes_insert AFTER INSERT ON nodes
BEGIN
    INSERT INTO _warp_changes(table_name, operation, row_id, new_data)
    VALUES ('nodes', 'INSERT', NEW.id, json_object(
        'id', NEW.id, 'text', NEW.text, 'status', NEW.status,
        'metadata', NEW.metadata, 'alias', NEW.alias,
        'created_at', NEW.created_at, 'updated_at', NEW.updated_at
    ));
END;

CREATE TRIGGER IF NOT EXISTS _warp_nodes_update AFTER UPDATE ON nodes
BEGIN
    INSERT INTO _warp_changes(table_name, operation, row_id, old_data, new_data)
    VALUES ('nodes', 'UPDATE', NEW.id,
        json_object(
            'id', OLD.id, 'text', OLD.text, 'status', OLD.status,
            'metadata', OLD.metadata, 'alias', OLD.alias,
            'updated_at', OLD.updated_at
        ),
        json_object(
            'id', NEW.id, 'text', NEW.text, 'status', NEW.status,
            'metadata', NEW.metadata, 'alias', NEW.alias,
            'updated_at', NEW.updated_at
        )
    );
END;

CREATE TRIGGER IF NOT EXISTS _warp_nodes_delete AFTER DELETE ON nodes
BEGIN
    INSERT INTO _warp_changes(table_name, operation, row_id, old_data)
    VALUES ('nodes', 'DELETE', OLD.id, json_object(
        'id', OLD.id, 'text', OLD.text, 'status', OLD.status,
        'metadata', OLD.metadata, 'alias', OLD.alias,
        'created_at', OLD.created_at, 'updated_at', OLD.updated_at
    ));
END;
"

_WV_DELTA_TRIGGERS_EDGES="
-- Edge row_id is stored as 'source:target:type' (colon-separated composite key).
-- Colons are safe here: node IDs are hex-only (wv-[a-f0-9]+), edge types are
-- from a known enum (blocks/implements/addresses/etc). wv_delta_changeset splits
-- on the first and second colon to reconstruct the three components for DELETE SQL.
CREATE TRIGGER IF NOT EXISTS _warp_edges_insert AFTER INSERT ON edges
BEGIN
    INSERT INTO _warp_changes(table_name, operation, row_id, new_data)
    VALUES ('edges', 'INSERT', NEW.source || ':' || NEW.target || ':' || NEW.type, json_object(
        'source', NEW.source, 'target', NEW.target, 'type', NEW.type,
        'weight', NEW.weight, 'context', NEW.context,
        'created_at', NEW.created_at
    ));
END;

CREATE TRIGGER IF NOT EXISTS _warp_edges_update AFTER UPDATE ON edges
BEGIN
    INSERT INTO _warp_changes(table_name, operation, row_id, old_data, new_data)
    VALUES ('edges', 'UPDATE', NEW.source || ':' || NEW.target || ':' || NEW.type,
        json_object(
            'source', OLD.source, 'target', OLD.target, 'type', OLD.type,
            'weight', OLD.weight, 'context', OLD.context
        ),
        json_object(
            'source', NEW.source, 'target', NEW.target, 'type', NEW.type,
            'weight', NEW.weight, 'context', NEW.context
        )
    );
END;

CREATE TRIGGER IF NOT EXISTS _warp_edges_delete AFTER DELETE ON edges
BEGIN
    INSERT INTO _warp_changes(table_name, operation, row_id, old_data)
    VALUES ('edges', 'DELETE', OLD.source || ':' || OLD.target || ':' || OLD.type, json_object(
        'source', OLD.source, 'target', OLD.target, 'type', OLD.type,
        'weight', OLD.weight, 'context', OLD.context
    ));
END;
"

# --- Functions ---

# wv_delta_init — install _warp_changes table and 6 triggers on a DB.
# Always drops and recreates triggers so existing DBs pick up payload schema
# changes (e.g. new columns added to trigger JSON objects). The table itself
# uses CREATE TABLE IF NOT EXISTS (preserving in-flight changes).
# Called by: cmd_init, cmd_load (after state.sql import and after db_init),
# and wv_delta_has_changes (self-healing path).
wv_delta_init() {
    local db="$1"
    sqlite3 -cmd ".timeout 5000" "$db" "
${_WV_DELTA_CREATE_TABLE}
DROP TRIGGER IF EXISTS _warp_nodes_insert;
DROP TRIGGER IF EXISTS _warp_nodes_update;
DROP TRIGGER IF EXISTS _warp_nodes_delete;
DROP TRIGGER IF EXISTS _warp_edges_insert;
DROP TRIGGER IF EXISTS _warp_edges_update;
DROP TRIGGER IF EXISTS _warp_edges_delete;
${_WV_DELTA_TRIGGERS_NODES}${_WV_DELTA_TRIGGERS_EDGES}"
    _WV_DELTA_INITED=1
}

# wv_delta_has_changes — O(1) gate for auto_sync.
# Returns exit 0 (true) if any rows in _warp_changes, exit 1 (false) otherwise.
#
# Self-healing: if _warp_changes doesn't exist (e.g. DB created outside cmd_load),
# attempts to init triggers rather than crashing. Guards that nodes table exists
# first — trigger DDL references it, so CREATE TRIGGER would fail on a bare DB.
#
# After the first successful probe, sets _WV_DELTA_INITED to skip the probe
# SELECT on all subsequent calls within the same shell session.
wv_delta_has_changes() {
    local db="$1"
    if [ -z "$_WV_DELTA_INITED" ]; then
        if ! sqlite3 -cmd ".timeout 5000" "$db" "SELECT 1 FROM _warp_changes LIMIT 0;" 2>/dev/null; then
            # Self-heal: init only if nodes table already exists
            sqlite3 -cmd ".timeout 5000" "$db" "SELECT 1 FROM nodes LIMIT 0;" 2>/dev/null || return 1
            wv_delta_init "$db"
            return 1  # No changes yet — just initialized
        fi
        _WV_DELTA_INITED=1
    fi
    local result
    result=$(sqlite3 -cmd ".timeout 5000" "$db" "SELECT EXISTS(SELECT 1 FROM _warp_changes);")
    [ "$result" = "1" ]
}

# wv_mutation_seq — a monotonic counter of graph MUTATIONS.
#
# _warp_changes.id is AUTOINCREMENT, so SQLite keeps its high-water mark in
# sqlite_sequence even after wv_delta_reset clears the rows. That makes it a
# true mutation clock where timestamps are not:
#
#   - MAX(updated_at) cannot see a DELETE at all, and can move BACKWARDS when
#     the deleted row was the newest -- measured: unlinking the most recent edge
#     moved it 1787519439 -> 1787519438, so a cache written before the deletion
#     looks newer than the clock and is served stale.
#   - Second-resolution timestamps cannot separate two changes in one second.
#   - A file mtime measures access, not change, because SQLite journals on reads.
#
# Prints 0 when the table has never been written, which is a safe "unknown"
# because it can only cause a miss, never a stale hit.
wv_mutation_seq() {
    local db="${1:-$WV_DB}"
    local seq
    seq=$(sqlite3 -cmd ".timeout 5000" "$db" \
        "SELECT COALESCE((SELECT seq FROM sqlite_sequence WHERE name='_warp_changes'), 0);" 2>/dev/null || echo "")
    case "$seq" in
        ''|*[!0-9]*) echo 0 ;;
        *) echo "$seq" ;;
    esac
}

# wv_mutation_seq_for_snapshot <seq-before> <seq-after> — the counter it is safe
# to record for a snapshot taken between those two readings.
#
# Recording the counter read AFTER a snapshot certifies content the snapshot may
# not hold: a mutation landing between the two is marked captured and then stays
# invisible for good, because every later freshness test compares against that
# number. Unchanged means the snapshot IS that graph, so the exact value is
# safe. Changed means a writer raced the snapshot, and the earlier value is the
# only one that cannot overstate what was captured. Understating costs one
# redundant sync; overstating loses the mutation.
#
# Prints nothing when there is no usable reading, which callers treat as "record
# no stamp" -- an absent stamp already reads as "needs sync" downstream.
wv_mutation_seq_for_snapshot() {
    local before="${1:-}" after="${2:-}"
    case "$before" in ''|*[!0-9]*) before="" ;; esac
    case "$after" in ''|*[!0-9]*) after="" ;; esac
    if [ -z "$before" ]; then
        return 0
    elif [ "$before" = "$after" ]; then
        printf '%s\n' "$after"
    else
        printf '%s\n' "$before"
    fi
}

# wv_delta_reset DB [MAX_ID] — clear the change log after a successful sync or
# delta replay. Called after: auto_sync persists state.sql, cmd_load replays
# deltas, and cmd_prune (prevents pruned-node DELETEs from leaking into delta
# files).
#
# MAX_ID scopes the delete to rows this cycle actually processed. A snapshot
# (dump_state_sql, or the changeset+stamp pass) is taken at some earlier
# instant; an unconditional `DELETE FROM _warp_changes` run afterward can also
# delete a row a CONCURRENT writer inserted in between, even though that row
# was captured in neither the snapshot nor any emitted delta — a real
# interleaving, not a test artifact: snapshot records "before", another
# process commits "after" (adding a _warp_changes row), the broad reset then
# erases the only record of "after", and a reboot or fresh load loses it for
# good. Passing the id this cycle's own watermark read (captured BEFORE the
# snapshot) preserves any row a concurrent writer added after that instant,
# leaving it pending for the next cycle. Omitted, the delete stays
# unconditional — used only by callers with no partial-batch concern (e.g.
# cmd_load's post-replay drain of self-generated trigger noise).
#
# Failures are no longer silently swallowed: a `DELETE` that cannot run means
# _warp_changes stays exactly as large as before, which is safe (rows are
# reprocessed, not lost) but worth a visible warning rather than a bare
# `|| true` that hid it completely.
wv_delta_reset() {
    local db="$1" max_id="${2:-}"
    local where=""
    if [ -n "$max_id" ]; then
        case "$max_id" in *[!0-9]*) max_id="" ;; esac
        [ -n "$max_id" ] && where=" WHERE id <= $max_id"
    fi
    local err
    if ! err=$(sqlite3 -cmd ".timeout 5000" "$db" "DELETE FROM _warp_changes$where;" 2>&1); then
        # A genuinely uninitialized repo's hot-zone DB has no _warp_changes
        # table at all -- nothing was ever tracked, so there is nothing
        # pending to drain. That is the already-satisfied case, not a
        # failure (deep-review finding: callers now check this return value,
        # and a missing table would otherwise wrongly fail every "nothing to
        # persist" skip path an uninitialized repo takes, every time).
        case "$err" in
            *"no such table: _warp_changes"*) return 0 ;;
        esac
        echo "wv: warning: failed to drain change tracking (retained for next sync): $err" >&2
        return 1
    fi
}

# wv_lineage_seq_base DB [DELTAS_ROOT] — the highest lineage sequence this actor
# could already have made durable, anywhere it can observe (wv-4a05e7, wv-cdb45a).
#
# Two sources, and the max of them:
#   - the graph's lineage_seq high-water (MAX over nodes and edges). Local writes
#     stamp this at emit time (wv_lineage_stamp) and it travels in state.sql, so
#     it survives a hot-zone wipe. 0 before the S2 columns exist or before the
#     first stamped sync.
#   - the committed Delta v2 catalog: DELTAS_ROOT/*/v2/*.json, whose 12-digit
#     filename prefix IS the actor_sequence. This closes the residual where an
#     actor reloads from a state.sql that lags its own already-committed ops
#     (PROPOSAL-delta-causality.md "Residual").
#
# Callers add 1 to get the next sequence to emit. DELTAS_ROOT defaults to the
# conventional .weave/deltas under the DB's hot zone parent, which is usually
# wrong for a hot-zone DB — pass it explicitly from auto_sync ($WEAVE_DIR/deltas).
wv_lineage_seq_base() {
    local db="$1" deltas_root="${2:-}"
    local graph_max=0 catalog_max=0 f base name

    graph_max=$(sqlite3 -cmd ".timeout 5000" "$db" "
        SELECT COALESCE(MAX(m), 0) FROM (
            SELECT MAX(lineage_seq) AS m FROM nodes
            UNION ALL SELECT MAX(lineage_seq) FROM edges
        );" 2>/dev/null || echo 0)
    case "$graph_max" in ''|*[!0-9]*) graph_max=0 ;; esac

    if [ -n "$deltas_root" ] && [ -d "$deltas_root" ]; then
        # Nullglob-free: the loop body guards on existence.
        for f in "$deltas_root"/*/v2/*.json; do
            [ -e "$f" ] || continue
            name=${f##*/}
            name=${name%%-*}
            case "$name" in
                ''|*[!0-9]*) continue ;;
            esac
            # 10# forces base-10 so a zero-padded "000000000012" is not read as octal.
            [ "$((10#$name))" -gt "$catalog_max" ] && catalog_max=$((10#$name))
        done
    fi

    if [ "$graph_max" -ge "$catalog_max" ]; then base="$graph_max"; else base="$catalog_max"; fi
    printf '%s\n' "$base"
}

# wv_lineage_stamp DB ACTOR_ID SEQ [MAX_ID] — record (SEQ, ACTOR_ID) as the last
# writer on every node and edge that changed since the last reset (wv-cdb45a).
#
# Called by auto_sync AFTER the changeset and v2 sidecars are generated and
# BEFORE the state.sql dump, so:
#   - the stamp is not itself in the delta it would otherwise describe;
#   - state.sql carries the new high-water, which is what makes
#     wv_lineage_seq_base monotonic across syncs (a repeated seq would let the
#     next real change be skipped by its own guard as already-applied);
#   - the _warp_changes rows the stamp UPDATE trigger writes are cleared by the
#     wv_delta_reset at the end of the same auto_sync, so they never leak into a
#     later changeset (they would only ever produce '-- no-op UPDATE' anyway:
#     the trigger payload carries no lineage column).
#
# MAX_ID bounds the subqueries to id <= MAX_ID, matching wv_delta_changeset's
# own bound for the SAME emission. Without it, a row a concurrent writer added
# after this cycle's watermark was captured — deliberately left unprocessed by
# the changeset — could still satisfy this stamp's field-diff and get its
# lineage attributed to a batch it was never part of.
wv_lineage_stamp() {
    local db="$1" actor_id="$2" seq="$3" max_id="${4:-}"
    case "$seq" in ''|*[!0-9]*) return 0 ;; esac
    local actor_q
    actor_q=$(printf '%s' "$actor_id" | sed "s/'/''/g")
    local bound=""
    if [ -n "$max_id" ]; then
        case "$max_id" in *[!0-9]*) max_id="" ;; esac
        [ -n "$max_id" ] && bound=" AND id <= $max_id"
    fi
    # The field-diff mirrors wv_delta_changeset's own no-op detection: stamp a
    # row only when this sync actually emits an INSERT/UPDATE statement for it. A
    # touch that changed nothing but updated_at emits '-- no-op' and must not
    # advance lineage, or the local high-water would outrun what any delta
    # carries and the next real inbound change to that row would be refused.
    # No longer swallowed by `|| true` (round 4 finding 4): the caller
    # reported success and could publish/drain its tracker even when this
    # stamp never landed -- rows the just-emitted delta claims lineage for
    # would carry their OLD (or 0) lineage on disk. A stale inbound op below
    # this cycle's seq could then still apply against them locally, and with
    # v2 writing disabled the un-stamped local high-water risks a repeated
    # seq being handed out next cycle. Surfaces the actual sqlite error and
    # returns non-zero so the caller (_wv_emit_deltas) aborts before the
    # dump, exactly like a wv_delta_changeset or compaction failure.
    local err
    if ! err=$(sqlite3 -cmd ".timeout 5000" "$db" "
UPDATE nodes SET lineage_seq=$seq, lineage_actor='$actor_q'
 WHERE id IN (
   SELECT row_id FROM _warp_changes
   WHERE table_name='nodes'$bound AND (
     operation='INSERT' OR (operation='UPDATE' AND (
       json_extract(old_data,'\$.text')     IS NOT json_extract(new_data,'\$.text')     OR
       json_extract(old_data,'\$.status')   IS NOT json_extract(new_data,'\$.status')   OR
       json_extract(old_data,'\$.metadata') IS NOT json_extract(new_data,'\$.metadata') OR
       json_extract(old_data,'\$.alias')    IS NOT json_extract(new_data,'\$.alias')
     ))
   ));
UPDATE edges SET lineage_seq=$seq, lineage_actor='$actor_q'
 WHERE (source || ':' || target || ':' || type) IN (
   SELECT row_id FROM _warp_changes
   WHERE table_name='edges'$bound AND (
     operation='INSERT' OR (operation='UPDATE' AND (
       json_extract(old_data,'\$.weight')  IS NOT json_extract(new_data,'\$.weight')  OR
       json_extract(old_data,'\$.context') IS NOT json_extract(new_data,'\$.context')
     ))
   ));
" 2>&1); then
        echo "wv: warning: lineage stamp failed -- rows changed by this emission may not carry the lineage their delta claims: $err" >&2
        return 1
    fi
}

# wv_delta_compact_batch DB — net multiple _warp_changes rows for the SAME
# entity into at most one row before either wv_delta_changeset or
# wv_delta_v2_write_operations reads the table. Self-captures this cycle's
# watermark under its own write lock (round 4 finding 2 — see the function
# body's header for why) and prints it to stdout; the caller must use that
# returned value, not one it captures separately, for every later step.
#
# Every operation in one emission deliberately carries the SAME lineage tuple
# (one seq per sync, not one per op — wv-cdb45a/wv-4a05e7's writer contract).
# That is correct for independent entities, but when _warp_changes accumulates
# TWO OR MORE rows for the SAME (table_name, row_id) before a reset — ordinary
# sequential commands (e.g. two `wv touch` calls, or a `wv done` that patches
# metadata in several steps) throttled into one auto_sync cycle — the guard
# mechanism cannot represent two statements for one row at one shared seq: on
# a fresh replay, whichever applies first stamps the row to that seq, and the
# second's own guard then reads as "already applied" (same seq, same actor is
# never `>`) and is silently dropped, even though it is the causally later,
# correct change. Proven end-to-end: A->B then B->C in one batch replays to B,
# not C. This is not order-dependent — v1 already replays a single file in
# chronological (ORDER BY id) order and still loses the second statement,
# because the guard's tie-break has no way to prefer "later in this batch"
# over "already seen this seq". Collapsing to one net operation per entity
# per batch removes the ambiguity at its source: a batch can only ever contain
# the ONE statement the guard's (seq, actor) model was designed to describe.
#
# Classification is by EXISTENCE, not operation labels (review round 3):
# `existed_before` = the group's first recorded op was not INSERT (the row
# predates this batch). `exists_after` = the row is ACTUALLY PRESENT in the
# live table right now, checked directly against nodes/edges rather than
# inferred from the last op's label. The label-based version this replaced
# read `first_op`/`last_op` off the _warp_changes rows and got three things
# wrong, all reproduced directly: (1) the UPDATE trigger's new_data omits
# created_at (only the INSERT and DELETE triggers carry it), so a chain
# ending in UPDATE (e.g. INSERT then UPDATE) netted to an "INSERT" whose
# new_data had no created_at key at all -- created_at=NULL on replay; (2) a
# delete-then-recreate chain (first_op DELETE, last_op INSERT) was classified
# "else -> UPDATE" by the OLD first/last rule, but a plain UPDATE statement
# does nothing against a row the receiver does not have -- the recreate was
# silently lost on any receiver whose baseline predates the original row,
# and if the recreated fields happened to equal the pre-delete fields the
# field-diff even collapsed it to a bare "-- no-op" comment; (3) old_data on
# the netted UPDATE never carried created_at either, so even when the UPDATE
# DID apply, a receiver's stale created_at from before the chain was never
# corrected. Fixed by never trusting a historical snapshot for the "final"
# row image: whenever exists_after is true the net operation is INSERT
# (regardless of existed_before), with new_data read FRESH from the live
# table right now -- guaranteed complete, and the v1 INSERT arm is already an
# UPSERT (`ON CONFLICT DO UPDATE`), so it applies correctly whether the
# receiver has the row or not, exactly the case a delete-then-recreate needs.
# The three remaining outcomes:
#   exists_after         -> net INSERT, new_data = live row (upserts either way)
#   existed_before, !exists_after -> net DELETE (row_id only)
#   !existed_before, !exists_after -> created and destroyed within this
#                                      batch; drop the whole group, nothing
#                                      to tell a fresh clone that never
#                                      observed either step.
#
# Singleton groups (COUNT(*) = 1) are untouched: this is a no-op for the
# overwhelmingly common case of one change per entity per sync.
#
# Runs inside one explicit transaction (all-or-nothing; a partial mutation of
# _warp_changes would corrupt what the changeset/v2 writer read next) and no
# longer swallows a failure silently -- a warning surfaces one, and the
# caller (auto_sync) aborts the cycle rather than proceeding to generate a
# changeset from a table compaction only partially touched.
#
# Self-watermarking (round 4 finding 2): the watermark used to be captured by
# the CALLER in its own separate `sqlite3` invocation, before this function's
# BEGIN IMMEDIATE ever ran. That left a race window: a concurrent writer
# committing between the caller's SELECT and this function's own lock
# acquisition lands a row correctly EXCLUDED from `_warp_net`'s grouping (its
# id is above the stale watermark) -- but `exists_after`/`new_data` are read
# from the LIVE nodes/edges tables, unbounded, so they see that same
# concurrent write's effect anyway. A post-watermark update or delete could
# then be emitted under the EARLIER batch's lineage. Direct repro: watermark
# rows B/todo->B/active, then a post-watermark write POST/active; the
# compacted earlier row came out as INSERT POST/active. Fixed by capturing
# the watermark as the FIRST statement inside this function's own BEGIN
# IMMEDIATE, into a temp table every bound below reads from: since BEGIN
# IMMEDIATE holds the write lock for the rest of this transaction, nothing
# concurrent can land between that capture and the live-table reads used to
# build `new_data` -- the watermark, the grouping, and the live reads are now
# one atomic view. This function prints the locked-in watermark to stdout on
# success (the caller captures it via command substitution and must use this
# value, not one of its own, for every subsequent step of the cycle -- the
# changeset, the v2 sidecars, the lineage stamp, and the final reset). On
# failure the transaction is rolled back and a best-effort, NOT lock-protected
# fallback watermark is still printed (this path only runs when compaction
# itself failed, an already-rare condition; preferable to aborting the whole
# sync cycle over it) -- return code distinguishes the two for a caller that
# wants to know.
wv_delta_compact_batch() {
    local db="$1"
    local out
    if ! out=$(sqlite3 -cmd ".timeout 5000" "$db" "
BEGIN IMMEDIATE;
DROP TABLE IF EXISTS _warp_watermark;
CREATE TEMP TABLE _warp_watermark AS SELECT COALESCE(MAX(id),0) AS max_id FROM _warp_changes;
DROP TABLE IF EXISTS _warp_net;
CREATE TEMP TABLE _warp_net AS
SELECT
    table_name, row_id,
    (SELECT operation FROM _warp_changes w WHERE w.table_name=g.table_name AND w.row_id=g.row_id AND w.id<=(SELECT max_id FROM _warp_watermark) ORDER BY w.id ASC  LIMIT 1) AS first_op,
    (SELECT old_data  FROM _warp_changes w WHERE w.table_name=g.table_name AND w.row_id=g.row_id AND w.id<=(SELECT max_id FROM _warp_watermark) ORDER BY w.id ASC  LIMIT 1) AS first_old,
    MAX(id) AS keep_id
FROM _warp_changes g
WHERE id <= (SELECT max_id FROM _warp_watermark)
GROUP BY table_name, row_id
HAVING COUNT(*) > 1;

-- exists_after, computed live rather than trusted from any historical
-- snapshot: nodes by id; edges by the colon-composite row_id, split the same
-- way wv_delta_changeset's own edge DELETE arm does. Safe to read live here
-- (round 4 finding 2): the watermark above and this read now share the same
-- BEGIN IMMEDIATE transaction, so nothing concurrent can have landed between
-- them -- the live tables can only reflect operations already accounted for
-- by id <= the watermark this same transaction just captured.
ALTER TABLE _warp_net ADD COLUMN exists_after INTEGER;
UPDATE _warp_net SET exists_after = (
  CASE WHEN table_name = 'nodes' THEN
    (SELECT COUNT(*) FROM nodes WHERE id = _warp_net.row_id)
  WHEN table_name = 'edges'
       AND instr(row_id, ':') > 0
       AND instr(substr(row_id, instr(row_id,':')+1), ':') > 0 THEN
    (SELECT COUNT(*) FROM edges
     WHERE source = substr(row_id,1,instr(row_id,':')-1)
       AND target = substr(substr(row_id,instr(row_id,':')+1),1,
             instr(substr(row_id,instr(row_id,':')+1),':')-1)
       AND type   = substr(substr(row_id,instr(row_id,':')+1),
             instr(substr(row_id,instr(row_id,':')+1),':')+1))
  ELSE 0 END
);

-- Created and destroyed within this batch: nothing to tell a fresh clone.
DELETE FROM _warp_changes
WHERE id <= (SELECT max_id FROM _warp_watermark)
  AND (table_name, row_id) IN (
    SELECT table_name, row_id FROM _warp_net WHERE first_op='INSERT' AND exists_after=0
  );

-- Existed before, gone now: net DELETE. Collapse every row in the group down
-- to the one being kept; row_id is all the DELETE arm needs.
DELETE FROM _warp_changes
WHERE id <= (SELECT max_id FROM _warp_watermark)
  AND id NOT IN (SELECT keep_id FROM _warp_net WHERE first_op != 'INSERT' AND exists_after = 0)
  AND (table_name, row_id) IN (
    SELECT table_name, row_id FROM _warp_net WHERE first_op != 'INSERT' AND exists_after = 0
  );
UPDATE _warp_changes SET operation = 'DELETE', old_data = NULL, new_data = NULL
WHERE id IN (SELECT keep_id FROM _warp_net WHERE first_op != 'INSERT' AND exists_after = 0);

-- Exists now (regardless of whether it existed before): net INSERT, new_data
-- read FRESH from the live table -- never from a historical snapshot, which
-- is exactly what was incomplete (missing created_at) or stale (predating a
-- delete-then-recreate) before. old_data is unused by the INSERT/upsert arm.
DELETE FROM _warp_changes
WHERE id <= (SELECT max_id FROM _warp_watermark)
  AND id NOT IN (SELECT keep_id FROM _warp_net WHERE exists_after > 0)
  AND (table_name, row_id) IN (
    SELECT table_name, row_id FROM _warp_net WHERE exists_after > 0
  );
UPDATE _warp_changes
SET operation = 'INSERT',
    old_data = NULL,
    new_data = (
      SELECT json_object('id',n.id,'text',n.text,'status',n.status,
                          'metadata',n.metadata,'alias',n.alias,
                          'created_at',n.created_at,'updated_at',n.updated_at)
      FROM nodes n JOIN _warp_net w ON w.keep_id = _warp_changes.id
      WHERE w.table_name = 'nodes' AND n.id = w.row_id
    )
WHERE id IN (
  SELECT keep_id FROM _warp_net WHERE exists_after > 0 AND table_name = 'nodes'
);
UPDATE _warp_changes
SET operation = 'INSERT',
    old_data = NULL,
    new_data = (
      SELECT json_object('source',e.source,'target',e.target,'type',e.type,
                          'weight',e.weight,'context',e.context,
                          'created_at',e.created_at)
      FROM edges e JOIN _warp_net w ON w.keep_id = _warp_changes.id
      WHERE w.table_name = 'edges'
        AND e.source = substr(w.row_id,1,instr(w.row_id,':')-1)
        AND e.target = substr(substr(w.row_id,instr(w.row_id,':')+1),1,
              instr(substr(w.row_id,instr(w.row_id,':')+1),':')-1)
        AND e.type   = substr(substr(w.row_id,instr(w.row_id,':')+1),
              instr(substr(w.row_id,instr(w.row_id,':')+1),':')+1)
    )
WHERE id IN (
  SELECT keep_id FROM _warp_net WHERE exists_after > 0 AND table_name = 'edges'
);

DROP TABLE _warp_net;
SELECT max_id FROM _warp_watermark;
DROP TABLE _warp_watermark;
COMMIT;
" 2>&1); then
        sqlite3 -cmd ".timeout 5000" "$db" "ROLLBACK;" 2>/dev/null || true
        echo "wv: warning: batch compaction failed, _warp_changes left as captured: $out" >&2
        local fallback
        fallback=$(sqlite3 -cmd ".timeout 5000" "$db" "SELECT COALESCE(MAX(id),0) FROM _warp_changes;" 2>/dev/null || echo 0)
        case "$fallback" in *[!0-9]*) fallback=0 ;; esac
        printf '%s\n' "$fallback"
        return 1
    fi
    printf '%s\n' "$out"
}

# wv_delta_changeset — emit an executable SQL changeset to stdout.
#
# wv_delta_changeset DB [ACTOR_ID] [SEQ] [MAX_ID]
#   ACTOR_ID / SEQ carry this emission's lineage stamp (wv-cdb45a). Every arm
#   below writes (lineage_seq, lineage_actor) onto the target row and guards its
#   own effect on lineage, so replaying a delta whose lineage does not advance
#   the row is a no-op and a stale delta cannot revert or delete a
#   causally-newer row. Omitting them (legacy/test callers) emits SEQ 0 /
#   actor '', which can only ever land on a row still at lineage_seq 0.
#
# Uses SQL-generating-SQL: a single sqlite3 query reads _warp_changes and
# produces INSERT / UPDATE / DELETE statements for each row, ordered by id
# (insertion order = causal order). No external tools — sqlite3's quote()
# handles all SQL escaping correctly.
#
# INSERT rows  → pre-clear alias conflict (nodes only) + INSERT ... ON CONFLICT DO UPDATE
# UPDATE rows  → UPDATE ... SET <changed-fields> WHERE id=... (field-level,
#                IS NOT used for NULL-safe comparison; only changed fields
#                appear in the SET clause — safe for concurrent field edits)
# DELETE rows  → DELETE WHERE (precise key match)
#
# UPDATE field-diff: compares old_data vs new_data column by column. Only
# emits SET clauses for columns where the values differ (using IS NOT, which
# correctly handles NULL transitions unlike !=). No-op UPDATEs (all fields
# unchanged — possible if a trigger fires on a write with identical values)
# emit a SQL comment rather than invalid SQL.
#
# Edge DELETE parsing: row_id is 'source:target:type'. The CASE expression
# splits on the first and second colon using substr/instr. The two-colon guard
# (instr of remainder > 0) catches any malformed row_id and emits a warning
# comment rather than silently dropping the delete.
#
# Output is written to .weave/deltas/<date>/<epoch>-<agent>.sql by auto_sync
# and replayed on other agents via cmd_load.
wv_delta_changeset() {
    local db="$1" actor_id="${2:-}" seq="${3:-0}" max_id="${4:-}"
    case "$seq" in ''|*[!0-9]*) seq=0 ;; esac
    local actor_q
    actor_q=$(printf '%s' "$actor_id" | sed "s/'/''/g")
    local _wc_bound=""
    if [ -n "$max_id" ]; then
        case "$max_id" in *[!0-9]*) max_id="" ;; esac
        [ -n "$max_id" ] && _wc_bound=" WHERE id <= $max_id"
    fi
    # Lineage header (wv-5a2627): cmd_load orders the v1 SQL delta replay by this
    # (seq, actor), not by the wall-clock filename epoch — a skewed machine or a
    # variable-width epoch prefix misorders that lexical sort, and an
    # INSERT-then-DELETE inversion is the difference between a deleted node and a
    # resurrected one. One inert `/* */` line — a block comment, not `--`, so the
    # changeset stays safe to pass as a `sqlite3 <db> "<sql>"` argument (a leading
    # `--` is parsed as an option). Every op in this emission shares one seq, so
    # one header per file is exact. A legacy/test emission (seq 0) writes no
    # header; cmd_load sorts it first, deterministically, preserving the old
    # back-catalog order.
    if [ "$seq" -gt 0 ]; then
        printf '/* weave-lineage seq=%s actor=%s */\n' "$seq" "${actor_id//$'\n'/ }"
    fi
    # $seq / '$actor_q' are bash-expanded before sqlite3 sees the query; SQLite's
    # own json '\$.field' paths keep the backslash. The lineage guard G is the
    # same predicate for every write arm: apply iff the target row is still
    # pre-cutover (lineage_seq 0), or this emission's (seq, actor) is strictly
    # after the row's own (seq, actor). Equal (seq, actor) — the same delta
    # replayed — fails G, so replay is a no-op. DELETE uses the <= form of the
    # same order: it fires only when nothing the deleter did not see has since
    # touched the row.
    sqlite3 -cmd ".timeout 5000" "$db" "
SELECT
  CASE
    -- node INSERT (node_create): upsert by PK. The alias pre-clear stays: a
    -- SQLite 3.24 UPSERT takes one ON CONFLICT clause, so an alias-UNIQUE
    -- collision would otherwise throw; nullify the alias on whatever other node
    -- holds it first. created_at is preserved from the originating agent.
    -- DO UPDATE is lineage-guarded (G): a stale delta replayed against a row a
    -- later delta already advanced is a no-op, not a reversion.
    -- The pre-clear is lineage-guarded on BOTH sides of the steal: the TARGET
    -- row (id=incoming, mirroring guard G, fires unconditionally only when
    -- the target does not exist yet) AND the HOLDER row being cleared (the
    -- row actually matched by alias=incoming). Checking only the target left
    -- an absent-target stale create free to steal a causally NEWER holder's
    -- alias outright: the holder is a DIFFERENT row from the target, so an
    -- absent target said nothing about whether the holder is absent too or
    -- how causally advanced it is. The holder clause below is the row's own
    -- lineage_seq/lineage_actor checked against guard G, exactly as if the
    -- holder itself were the target of a lineage-guarded write. The clear
    -- ALSO stamps the holder's own lineage (round 3 finding 3c): omitting
    -- this left a cleared holder still carrying its OLD (lower) lineage, so
    -- a stale delta the holder's own removal had already superseded -- e.g.
    -- an earlier DELETE the create's causally-later clear should have
    -- blocked -- could still apply against it, since nothing recorded that
    -- the clear had touched the row at all. And the whole clause is scoped
    -- to status != 'done' on BOTH sides (round 3 finding 3b): production's
    -- actual constraint is the partial index idx_nodes_alias ... WHERE
    -- alias IS NOT NULL AND status != 'done' (scripts/lib/wv-db.sh), not a
    -- plain UNIQUE column -- a done node's alias is never enforced unique at
    -- all, so it can never be a real holder, and an incoming write whose OWN
    -- new status is 'done' can never actually collide with anyone either.
    WHEN operation = 'INSERT' AND table_name = 'nodes' THEN
      CASE WHEN json_extract(new_data,'\$.alias') IS NOT NULL
           AND json_extract(new_data,'\$.status') != 'done'
        THEN 'UPDATE nodes SET alias=NULL, lineage_seq=' || $seq || ', lineage_actor=' || quote('$actor_q')
             || ' WHERE alias=' || quote(json_extract(new_data,'\$.alias'))
             || ' AND id!=' || quote(json_extract(new_data,'\$.id'))
             || ' AND status != ' || quote('done')
             || ' AND (nodes.lineage_seq = 0'
             || '      OR ' || $seq || ' > nodes.lineage_seq'
             || '      OR (' || $seq || ' = nodes.lineage_seq AND ' || quote('$actor_q') || ' > nodes.lineage_actor))'
             || ' AND (NOT EXISTS (SELECT 1 FROM nodes tgt WHERE tgt.id=' || quote(json_extract(new_data,'\$.id')) || ')'
             || ' OR EXISTS (SELECT 1 FROM nodes tgt WHERE tgt.id=' || quote(json_extract(new_data,'\$.id'))
             || ' AND (tgt.lineage_seq = 0'
             || '      OR ' || $seq || ' > tgt.lineage_seq'
             || '      OR (' || $seq || ' = tgt.lineage_seq AND ' || quote('$actor_q') || ' > tgt.lineage_actor))));' || char(10)
        ELSE ''
      END
      || 'INSERT INTO nodes(id,text,status,metadata,alias,created_at,updated_at,lineage_seq,lineage_actor) VALUES('
      || quote(json_extract(new_data,'\$.id')) || ','
      || quote(json_extract(new_data,'\$.text')) || ','
      || quote(json_extract(new_data,'\$.status')) || ','
      || quote(json_extract(new_data,'\$.metadata')) || ','
      -- The alias VALUE is itself a SQL expression, not a literal -- it must be
      -- evaluated on the RECEIVER at replay time, against the receiver's OWN
      -- nodes table, exactly like the pre-clear statement above it. Emitting
      -- the quoted alias outright is wrong for the same reason the
      -- unconditional pre-clear was: if a holder survives the pre-clear
      -- (causally newer, correctly left alone), inserting the contested value
      -- anyway hits the UNIQUE constraint and aborts the whole statement batch
      -- over an ordinary cross-agent collision. Checking EXISTS at generation
      -- time here would query the WRITER's own database, the wrong one
      -- entirely -- this changeset is generated once on this machine but
      -- replayed on a DIFFERENT machine's nodes table later, whose holder
      -- state at replay time is exactly what the pre-clear statement just
      -- resolved. So this builds a CASE-WHEN-NOT-EXISTS SQL FRAGMENT as the
      -- literal output text; the receiver evaluates it live, immediately
      -- after its own pre-clear ran in the same transaction. The node itself
      -- is still created (its id does not collide with anything); it just
      -- does not carry the alias it lost the contest for. A done target
      -- always keeps its requested alias unconditionally -- the partial
      -- index never indexes it, so there is nothing to contest.
      || (CASE WHEN json_extract(new_data,'\$.alias') IS NULL THEN 'NULL'
          WHEN json_extract(new_data,'\$.status') = 'done'
            THEN quote(json_extract(new_data,'\$.alias'))
          ELSE '(CASE WHEN NOT EXISTS(SELECT 1 FROM nodes WHERE alias='
               || quote(json_extract(new_data,'\$.alias')) || ' AND status != ' || quote('done')
               || ') THEN ' || quote(json_extract(new_data,'\$.alias')) || ' ELSE NULL END)'
          END) || ','
      || quote(json_extract(new_data,'\$.created_at')) || ','
      || quote(json_extract(new_data,'\$.updated_at')) || ','
      || $seq || ',' || quote('$actor_q') || ')'
      || ' ON CONFLICT(id) DO UPDATE SET'
      || ' text=excluded.text, status=excluded.status,'
      || ' metadata=excluded.metadata, alias=excluded.alias,'
      -- created_at IS overwritten on a guarded win, matching
      -- wv-delta-v2-replay.py's _apply_node_create (which always includes it
      -- in its guard-passed UPDATE). Guard G already establishes this write
      -- is causally authoritative over whatever the receiver has -- there is
      -- no scenario where that holds AND the incoming created_at is wrong,
      -- and a genuine delete-then-recreate (wv_delta_compact_batch nets this
      -- shape to INSERT) NEEDS the new created_at to land, not the
      -- destroyed row's stale one (round 3 finding 2.2/2.3).
      || ' created_at=excluded.created_at,'
      || ' updated_at=excluded.updated_at,'
      || ' lineage_seq=excluded.lineage_seq, lineage_actor=excluded.lineage_actor'
      || ' WHERE nodes.lineage_seq = 0'
      || '    OR ' || $seq || ' > nodes.lineage_seq'
      || '    OR (' || $seq || ' = nodes.lineage_seq AND ' || quote('$actor_q') || ' > nodes.lineage_actor);'

    -- node UPDATE (node_patch): field-level diff via IS NOT (NULL-safe). Only
    -- changed fields appear in SET; updated_at and the lineage stamp are always
    -- included. Same lineage guard G in the WHERE. A write that changed nothing
    -- but updated_at emits a comment and does not advance lineage.
    -- Alias arbitration (round 3 finding 3a): a patch that lands a non-NULL
    -- alias needs the same pre-clear + guarded-value machinery as the node
    -- INSERT arm above, scoped to the same partial index (alias IS NOT NULL
    -- AND status != 'done'). Two paths claim the index, not just an outright
    -- alias change: (1) the alias column itself changes to a new non-NULL
    -- value, or (2) the alias is unchanged but status transitions OUT of
    -- 'done' -- the row is newly entering the partial index carrying an
    -- alias it already held, uncontested only because 'done' rows were never
    -- indexed. The reverse transition (INTO 'done') needs no pre-clear:
    -- SQLite drops the row from the partial index on its own, releasing the
    -- alias for others without this delta doing anything. The pre-clear's
    -- target-guard clause mirrors guard G for THIS row exactly, so whenever
    -- the main UPDATE below would be stale and not apply, the pre-clear does
    -- not fire either -- a stale patch cannot steal an alias on the way to
    -- losing its own guard.
    WHEN operation = 'UPDATE' AND table_name = 'nodes' THEN
      CASE WHEN
        (json_extract(old_data,'\$.text')     IS NOT json_extract(new_data,'\$.text'))     OR
        (json_extract(old_data,'\$.status')   IS NOT json_extract(new_data,'\$.status'))   OR
        (json_extract(old_data,'\$.metadata') IS NOT json_extract(new_data,'\$.metadata')) OR
        (json_extract(old_data,'\$.alias')    IS NOT json_extract(new_data,'\$.alias'))
      THEN
        (CASE WHEN json_extract(new_data,'\$.alias') IS NOT NULL
               AND json_extract(new_data,'\$.status') != 'done'
               AND (json_extract(old_data,'\$.alias') IS NOT json_extract(new_data,'\$.alias')
                    OR json_extract(old_data,'\$.status') = 'done')
          THEN 'UPDATE nodes SET alias=NULL, lineage_seq=' || $seq || ', lineage_actor=' || quote('$actor_q')
               || ' WHERE alias=' || quote(json_extract(new_data,'\$.alias'))
               || ' AND id!=' || quote(json_extract(new_data,'\$.id'))
               || ' AND status != ' || quote('done')
               || ' AND (nodes.lineage_seq = 0'
               || '      OR ' || $seq || ' > nodes.lineage_seq'
               || '      OR (' || $seq || ' = nodes.lineage_seq AND ' || quote('$actor_q') || ' > nodes.lineage_actor))'
               || ' AND EXISTS (SELECT 1 FROM nodes tgt WHERE tgt.id=' || quote(json_extract(new_data,'\$.id'))
               || ' AND (tgt.lineage_seq = 0'
               || '      OR ' || $seq || ' > tgt.lineage_seq'
               || '      OR (' || $seq || ' = tgt.lineage_seq AND ' || quote('$actor_q') || ' > tgt.lineage_actor)));' || char(10)
          ELSE ''
        END)
        || 'UPDATE nodes SET '
        || rtrim(
             CASE WHEN json_extract(old_data,'\$.text') IS NOT json_extract(new_data,'\$.text')
                  THEN 'text='     || quote(json_extract(new_data,'\$.text'))     || ',' ELSE '' END
             || CASE WHEN json_extract(old_data,'\$.status') IS NOT json_extract(new_data,'\$.status')
                     THEN 'status='   || quote(json_extract(new_data,'\$.status'))   || ',' ELSE '' END
             || CASE WHEN json_extract(old_data,'\$.metadata') IS NOT json_extract(new_data,'\$.metadata')
                     THEN 'metadata=' || quote(json_extract(new_data,'\$.metadata')) || ',' ELSE '' END
             || CASE WHEN (json_extract(old_data,'\$.alias') IS NOT json_extract(new_data,'\$.alias'))
                       OR (json_extract(new_data,'\$.alias') IS NOT NULL
                           AND json_extract(old_data,'\$.status') = 'done'
                           AND json_extract(new_data,'\$.status') != 'done')
                     THEN 'alias=' ||
                       (CASE WHEN json_extract(new_data,'\$.alias') IS NULL THEN 'NULL'
                             WHEN json_extract(new_data,'\$.status') = 'done'
                               THEN quote(json_extract(new_data,'\$.alias'))
                             ELSE '(CASE WHEN NOT EXISTS(SELECT 1 FROM nodes WHERE alias='
                                  || quote(json_extract(new_data,'\$.alias')) || ' AND status != ' || quote('done')
                                  || ' AND id!=' || quote(json_extract(new_data,'\$.id'))
                                  || ') THEN ' || quote(json_extract(new_data,'\$.alias')) || ' ELSE NULL END)'
                        END)
                     || ',' ELSE '' END
             || 'updated_at=' || quote(json_extract(new_data,'\$.updated_at')) || ',',
             ','
           )
        || ', lineage_seq=' || $seq || ', lineage_actor=' || quote('$actor_q')
        || ' WHERE id=' || quote(json_extract(new_data,'\$.id'))
        || '   AND (nodes.lineage_seq = 0'
        || '        OR ' || $seq || ' > nodes.lineage_seq'
        || '        OR (' || $seq || ' = nodes.lineage_seq AND ' || quote('$actor_q') || ' > nodes.lineage_actor));'
      ELSE
        '-- no-op UPDATE on node ' || quote(json_extract(new_data,'\$.id'))
      END

    -- edge INSERT (edge_create): upsert by composite PK. Same lineage guard G on
    -- DO UPDATE — a stale edge INSERT can no longer overwrite weight or context
    -- another agent set at a higher lineage.
    WHEN operation = 'INSERT' AND table_name = 'edges' THEN
      'INSERT INTO edges(source,target,type,weight,context,created_at,lineage_seq,lineage_actor) VALUES('
      || quote(json_extract(new_data,'\$.source')) || ','
      || quote(json_extract(new_data,'\$.target')) || ','
      || quote(json_extract(new_data,'\$.type')) || ','
      || COALESCE(json_extract(new_data,'\$.weight'), 'NULL') || ','
      || quote(json_extract(new_data,'\$.context')) || ','
      || quote(json_extract(new_data,'\$.created_at')) || ','
      || $seq || ',' || quote('$actor_q') || ')'
      || ' ON CONFLICT(source,target,type) DO UPDATE SET'
      || ' weight=excluded.weight, context=excluded.context,'
      -- created_at overwritten on a guarded win — see the node INSERT arm's
      -- comment above; edges have the identical delete-then-recreate case.
      || ' created_at=excluded.created_at,'
      || ' lineage_seq=excluded.lineage_seq, lineage_actor=excluded.lineage_actor'
      || ' WHERE edges.lineage_seq = 0'
      || '    OR ' || $seq || ' > edges.lineage_seq'
      || '    OR (' || $seq || ' = edges.lineage_seq AND ' || quote('$actor_q') || ' > edges.lineage_actor);'

    -- edge UPDATE (edge_patch): only weight and context are mutable. Field diff
    -- as for nodes; lineage stamp always set; same guard G in the WHERE.
    WHEN operation = 'UPDATE' AND table_name = 'edges' THEN
      CASE WHEN
        (json_extract(old_data,'\$.weight')  IS NOT json_extract(new_data,'\$.weight'))  OR
        (json_extract(old_data,'\$.context') IS NOT json_extract(new_data,'\$.context'))
      THEN
        'UPDATE edges SET '
        || rtrim(
             CASE WHEN json_extract(old_data,'\$.weight') IS NOT json_extract(new_data,'\$.weight')
                  THEN 'weight='  || COALESCE(json_extract(new_data,'\$.weight'), 'NULL') || ',' ELSE '' END
             || CASE WHEN json_extract(old_data,'\$.context') IS NOT json_extract(new_data,'\$.context')
                     THEN 'context=' || quote(json_extract(new_data,'\$.context'))             || ',' ELSE '' END,
             ','
           )
        || ', lineage_seq=' || $seq || ', lineage_actor=' || quote('$actor_q')
        || ' WHERE source=' || quote(json_extract(new_data,'\$.source'))
        || '   AND target='   || quote(json_extract(new_data,'\$.target'))
        || '   AND type='     || quote(json_extract(new_data,'\$.type'))
        || '   AND (edges.lineage_seq = 0'
        || '        OR ' || $seq || ' > edges.lineage_seq'
        || '        OR (' || $seq || ' = edges.lineage_seq AND ' || quote('$actor_q') || ' > edges.lineage_actor));'
      ELSE
        '-- no-op UPDATE on edge ' || quote(json_extract(new_data,'\$.source'))
        || ':' || quote(json_extract(new_data,'\$.target'))
        || ':' || quote(json_extract(new_data,'\$.type'))
      END

    -- node DELETE (node_delete): fires only if nothing the deleter did not see
    -- has since touched the row -- the SAME (seq, actor) tuple order every
    -- other arm's guard G uses, via SQLite row-value comparison (already the
    -- idiom db_write_tombstone's ON CONFLICT uses). A row recreated or patched
    -- at a higher (seq, actor) survives a stale DELETE replayed from the
    -- committed catalog; an equal seq is broken by actor, not silently allowed
    -- through. lineage_seq 0 (pre-cutover, untouched) still deletes. A bare
    -- lineage_seq <= seq (no actor tiebreak) let a delete at (seq, actor-A)
    -- remove a row a causally later (seq, actor-Z) write had just landed.
    WHEN operation = 'DELETE' AND table_name = 'nodes' THEN
      'DELETE FROM nodes WHERE id=' || quote(row_id)
      || ' AND (lineage_seq = 0 OR (lineage_seq, lineage_actor) <= (' || $seq || ',' || quote('$actor_q') || '));'

    WHEN operation = 'DELETE' AND table_name = 'edges'
         AND instr(row_id, ':') > 0
         AND instr(substr(row_id, instr(row_id,':')+1), ':') > 0 THEN
      -- edge DELETE (edge_delete): split 'source:target:type', same
      -- (seq, actor) stale-delete guard as node DELETE.
      'DELETE FROM edges WHERE source=' || quote(substr(row_id,1,instr(row_id,':')-1))
      || ' AND target=' || quote(substr(substr(row_id,instr(row_id,':')+1),1,
         instr(substr(row_id,instr(row_id,':')+1),':')-1))
      || ' AND type=' || quote(substr(substr(row_id,instr(row_id,':')+1),
         instr(substr(row_id,instr(row_id,':')+1),':')+1))
      || ' AND (lineage_seq = 0 OR (lineage_seq, lineage_actor) <= (' || $seq || ',' || quote('$actor_q') || '));'

    WHEN operation = 'DELETE' AND table_name = 'edges' THEN
      '-- WARNING: unparseable edge row_id: ' || quote(row_id)
  END
FROM _warp_changes$_wc_bound ORDER BY id;
"
}


# wv_delta_v2_write_operations DB OUT_DIR ACTOR_ID [DELTAS_ROOT]
#
# Delta v2 writer. Emits one immutable JSON operation sidecar per semantic change
# in _warp_changes, covering every arm the v1 SQL changeset carries:
#
#   nodes INSERT -> node_create   nodes UPDATE -> node_patch   nodes DELETE -> node_delete
#   edges INSERT -> edge_create   edges UPDATE -> edge_patch   edges DELETE -> edge_delete
#
# node_patch fields: status, text, alias (columns); claimed_by, risk_level
# (metadata sugar, emitted only when they are the sole metadata change); metadata
# (the whole object, emitted when any other metadata key moved). edge_patch
# fields: weight, context. A UPDATE that moved nothing semantic (only updated_at)
# emits no operation.
#
# The sidecars are only consumed by `wv load` when WV_DELTA_V2_WRITE=1 has been
# emitting them; the SQL delta remains the compatibility authority until then.
# On failure this function returns non-zero; auto_sync warns and continues unless
# WV_DELTA_V2_STRICT=1, which makes the failure abort the sync.
#
# Lineage / actor_sequence durability (wv-4a05e7): the counter is NOT
# _warp_changes.id (tmpfs sqlite_sequence, restarts at 1 on every reboot or
# `wv load`). The batch is seeded from wv_lineage_seq_base -- the same helper the
# v1 changeset and wv_lineage_stamp use -- and every operation in one emission
# carries the SAME lineage value (base+1), matching the single seq the v1
# changeset and the row stamp use for that sync. operation_id is uuid5 over
# {actor_id, actor_sequence, payload}, so distinct payloads in one batch still
# get distinct ids; a repeated payload from the same actor at the same seed is
# byte-identical by design (keeps the stability test green). Row stamping is the
# replay path's job (wv-delta-v2-replay.py), never the writer's. DELTAS_ROOT
# defaults to OUT_DIR/../.. (OUT_DIR is the per-day .../deltas/<date>/v2 dir).
wv_delta_v2_write_operations() {
    local db="$1" out_dir="$2" actor_id="$3"
    local deltas_root="${4:-}" max_id="${5:-}" manifest="${6:-}"
    [ -n "$deltas_root" ] || deltas_root="${out_dir%/*/*}"
    case "$max_id" in *[!0-9]*) max_id="" ;; esac
    mkdir -p "$out_dir" || return 1
    local base
    base=$(wv_lineage_seq_base "$db" "$deltas_root")
    python3 - "$db" "$out_dir" "$actor_id" "$base" "$max_id" "$manifest" <<'PY'
import hashlib
import json
import os
import sqlite3
import sys
import uuid

db, out_dir, actor_id, base_arg, max_id_arg, manifest_arg = sys.argv[1:7]
try:
    seq = int(base_arg) + 1
except (TypeError, ValueError):
    seq = 1

STATUSES = {"todo", "ready", "active", "blocked", "done"}
RISK_LEVELS = {"none", "low", "medium", "high"}
META_SUGAR = ("claimed_by", "risk_level")


def canonical(value):
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int) and not isinstance(value, bool):
        return str(value)
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    if isinstance(value, list):
        return "[" + ",".join(canonical(item) for item in value) + "]"
    if isinstance(value, dict):
        return "{" + ",".join(
            canonical(str(key)) + ":" + canonical(value[key])
            for key in sorted(value.keys())
        ) + "}"
    raise TypeError(f"unsupported canonical value type: {type(value).__name__}")


def sha256_text(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def parse_change_json(raw):
    if not raw:
        return {}
    value = json.loads(raw)
    return value if isinstance(value, dict) else {}


def parse_metadata(raw):
    if raw is None or raw == "":
        return {}
    if isinstance(raw, dict):
        return raw
    try:
        value = json.loads(raw)
    except (TypeError, json.JSONDecodeError):
        return {}
    return value if isinstance(value, dict) else {}


def claimed_by(metadata):
    value = metadata.get("claimed_by")
    if value is None:
        return None
    if isinstance(value, str) and value:
        return value
    raise ValueError("claimed_by must be null or non-empty string")


def risk_level(metadata):
    value = metadata.get("risk_level", "none")
    if isinstance(value, str) and value in RISK_LEVELS:
        return value
    raise ValueError("risk_level must be one of none/low/medium/high")


def weight_str(value):
    # weave.canonical-json.v1 has no non-integer number form, so edge weight
    # travels as repr(float(x)); replay parses it back with float().
    if value is None:
        return None
    return repr(float(value))


def node_patch_fields(old_data, new_data):
    fields = {}
    old_status, new_status = old_data.get("status"), new_data.get("status")
    if old_status != new_status:
        if old_status in STATUSES and new_status in STATUSES:
            fields["status"] = {"expected": old_status, "value": new_status}
        else:
            raise ValueError("status must be a stable lifecycle value")

    old_text, new_text = old_data.get("text"), new_data.get("text")
    if old_text != new_text:
        fields["text"] = {"expected": old_text, "value": new_text}

    old_alias, new_alias = old_data.get("alias"), new_data.get("alias")
    if old_alias != new_alias:
        fields["alias"] = {"expected": old_alias, "value": new_alias}

    old_meta = parse_metadata(old_data.get("metadata"))
    new_meta = parse_metadata(new_data.get("metadata"))
    if old_meta != new_meta:
        old_rest = {k: v for k, v in old_meta.items() if k not in META_SUGAR}
        new_rest = {k: v for k, v in new_meta.items() if k not in META_SUGAR}
        if old_rest == new_rest:
            old_claimed, new_claimed = claimed_by(old_meta), claimed_by(new_meta)
            if old_claimed != new_claimed:
                fields["claimed_by"] = {"expected": old_claimed, "value": new_claimed}
            old_risk, new_risk = risk_level(old_meta), risk_level(new_meta)
            if old_risk != new_risk:
                fields["risk_level"] = {"expected": old_risk, "value": new_risk}
        else:
            fields["metadata"] = {"expected": old_meta, "value": new_meta}
    return fields


def edge_patch_fields(old_data, new_data):
    fields = {}
    old_weight, new_weight = weight_str(old_data.get("weight")), weight_str(new_data.get("weight"))
    if old_weight != new_weight:
        fields["weight"] = {"expected": old_weight, "value": new_weight}
    old_context, new_context = old_data.get("context"), new_data.get("context")
    if old_context != new_context:
        fields["context"] = {"expected": old_context, "value": new_context}
    return fields


def edge_key(row_id, data):
    if data.get("source") and data.get("target") and data.get("type"):
        return data["source"], data["target"], data["type"]
    parts = row_id.split(":", 2)
    if len(parts) != 3 or not all(parts):
        raise ValueError(f"unparseable edge row_id: {row_id!r}")
    return parts[0], parts[1], parts[2]


def payload_for(row):
    _change_id, table_name, operation, row_id, old_raw, new_raw = row
    old_data = parse_change_json(old_raw)
    new_data = parse_change_json(new_raw)

    if table_name == "nodes":
        entity = {"kind": "node", "id": row_id}
        if operation == "INSERT":
            meta = parse_metadata(new_data.get("metadata"))
            status = new_data.get("status")
            if status not in STATUSES:
                raise ValueError("node_create status must be a stable lifecycle value")
            row = {
                "text": new_data.get("text"),
                "status": status,
                "metadata": meta,
                "alias": new_data.get("alias"),
                "created_at": new_data.get("created_at"),
            }
            return entity, {"kind": "node_create", "row": row}
        if operation == "UPDATE":
            fields = node_patch_fields(old_data, new_data)
            if not fields:
                return None
            return entity, {"kind": "node_patch", "fields": fields}
        if operation == "DELETE":
            return entity, {"kind": "node_delete"}
        return None

    if table_name == "edges":
        if operation == "INSERT":
            key = edge_key(row_id, new_data)
            entity = {"kind": "edge", "source": key[0], "target": key[1], "type": key[2]}
            row = {
                "weight": weight_str(new_data.get("weight")),
                "context": new_data.get("context"),
                "created_at": new_data.get("created_at"),
            }
            return entity, {"kind": "edge_create", "row": row}
        if operation == "UPDATE":
            key = edge_key(row_id, new_data)
            entity = {"kind": "edge", "source": key[0], "target": key[1], "type": key[2]}
            fields = edge_patch_fields(old_data, new_data)
            if not fields:
                return None
            return entity, {"kind": "edge_patch", "fields": fields}
        if operation == "DELETE":
            key = edge_key(row_id, old_data)
            entity = {"kind": "edge", "source": key[0], "target": key[1], "type": key[2]}
            return entity, {"kind": "edge_delete"}
        return None

    return None


def operation_for(row, actor_sequence):
    built = payload_for(row)
    if built is None:
        return None
    entity, mutation = built
    payload = {
        "entity": entity,
        "lineage": {"seq": actor_sequence, "actor": actor_id},
        "mutation": mutation,
    }
    seed = canonical({
        "actor_id": actor_id,
        "actor_sequence": actor_sequence,
        "payload": payload,
    })
    operation_id = str(uuid.uuid5(uuid.NAMESPACE_URL, sha256_text(seed)))
    operation_doc = {
        "format": "weave.delta.v2",
        "operation_id": operation_id,
        "actor_id": actor_id,
        "actor_sequence": actor_sequence,
        "canonicalization": "weave.canonical-json.v1",
        "payload": payload,
    }
    operation_doc["operation_sha256"] = sha256_text(canonical(operation_doc))
    return operation_doc


conn = sqlite3.connect(db)
# Bounded to the SAME watermark auto_sync passes to wv_delta_changeset and
# wv_lineage_stamp for this emission. Without it, a row a concurrent writer
# added after the watermark was captured -- deliberately left for the NEXT
# cycle by the v1 path -- would still be picked up here, stamping a
# concurrent change into a batch it was never part of and diverging from
# what the v1 changeset for the SAME sync actually describes.
try:
    max_id = int(max_id_arg)
except (TypeError, ValueError):
    max_id = None
if max_id is not None:
    rows = conn.execute(
        "SELECT id, table_name, operation, row_id, old_data, new_data "
        "FROM _warp_changes WHERE id <= ? ORDER BY id",
        (max_id,),
    ).fetchall()
else:
    rows = conn.execute(
        "SELECT id, table_name, operation, row_id, old_data, new_data "
        "FROM _warp_changes ORDER BY id"
    ).fetchall()
# Every operation this emission writes carries the same lineage value (seq),
# matching the single seq the v1 changeset and wv_lineage_stamp use for the
# sync. Skipped rows consume nothing, so a re-emission from an unreset change
# row with the same seed is byte-identical.
#
# Round 5 finding: a failure-path cleanup keyed on the lineage_seq filename
# prefix alone (e.g. `rm -f 000000000042-*.json`) deletes every sidecar at
# that seq regardless of WHICH invocation wrote it -- two actors can
# legitimately compute the same next seq independently before either has
# stamped it, and each writes files under distinct (actor-scoped)
# operation_ids at that same prefix. Recording every path THIS call actually
# creates -- flushed immediately, so a partial batch that fails partway
# through the row loop still leaves an accurate manifest of what it wrote --
# lets a caller clean up exactly its own files, never a sibling actor's.
manifest_fh = open(manifest_arg, "w", encoding="utf-8") if manifest_arg else None
written = 0
try:
    for row in rows:
        op = operation_for(row, seq)
        if op is None:
            continue
        path = os.path.join(out_dir, f"{op['actor_sequence']:012d}-{op['operation_id']}.json")
        tmp = f"{path}.tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(canonical(op))
            fh.write("\n")
        os.replace(tmp, path)
        written += 1
        if manifest_fh is not None:
            manifest_fh.write(path + "\n")
            manifest_fh.flush()
finally:
    if manifest_fh is not None:
        manifest_fh.close()
print(written)
PY
}
