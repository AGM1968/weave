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
#   wv_delta_apply        Apply SQL from stdin to a database (Sprint 2 merge path)

# Shell cache: once _warp_changes is confirmed to exist, skip the probe SELECT
# on every auto_sync cycle (~60s). Saves one sqlite3 round-trip per cycle.
_WV_DELTA_INITED=""

# --- DDL (identical schema to warp/crates/warp-session/src/schema.rs) ---
# Keeping schema identical means delta files produced by either implementation
# are interchangeable. Do not change column names or trigger DDL without
# also updating the warp crate.

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
        'metadata', NEW.metadata, 'alias', NEW.alias
    ));
END;

CREATE TRIGGER IF NOT EXISTS _warp_nodes_update AFTER UPDATE ON nodes
BEGIN
    INSERT INTO _warp_changes(table_name, operation, row_id, old_data, new_data)
    VALUES ('nodes', 'UPDATE', NEW.id,
        json_object(
            'id', OLD.id, 'text', OLD.text, 'status', OLD.status,
            'metadata', OLD.metadata, 'alias', OLD.alias
        ),
        json_object(
            'id', NEW.id, 'text', NEW.text, 'status', NEW.status,
            'metadata', NEW.metadata, 'alias', NEW.alias
        )
    );
END;

CREATE TRIGGER IF NOT EXISTS _warp_nodes_delete AFTER DELETE ON nodes
BEGIN
    INSERT INTO _warp_changes(table_name, operation, row_id, old_data)
    VALUES ('nodes', 'DELETE', OLD.id, json_object(
        'id', OLD.id, 'text', OLD.text, 'status', OLD.status,
        'metadata', OLD.metadata, 'alias', OLD.alias
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
        'weight', NEW.weight, 'context', NEW.context
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
# Idempotent (CREATE TABLE IF NOT EXISTS / CREATE TRIGGER IF NOT EXISTS).
# Called by: cmd_init, cmd_load (after state.sql import and after db_init),
# and wv_delta_has_changes (self-healing path).
wv_delta_init() {
    local db="$1"
    sqlite3 "$db" "${_WV_DELTA_CREATE_TABLE}${_WV_DELTA_TRIGGERS_NODES}${_WV_DELTA_TRIGGERS_EDGES}"
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
        if ! sqlite3 "$db" "SELECT 1 FROM _warp_changes LIMIT 0;" 2>/dev/null; then
            # Self-heal: init only if nodes table already exists
            sqlite3 "$db" "SELECT 1 FROM nodes LIMIT 0;" 2>/dev/null || return 1
            wv_delta_init "$db"
            return 1  # No changes yet — just initialized
        fi
        _WV_DELTA_INITED=1
    fi
    local result
    result=$(sqlite3 "$db" "SELECT EXISTS(SELECT 1 FROM _warp_changes);")
    [ "$result" = "1" ]
}

# wv_delta_reset — clear the change log after a successful sync or delta replay.
# Called after: auto_sync persists state.sql, cmd_load replays deltas,
# and cmd_prune (prevents pruned-node DELETEs from leaking into delta files).
wv_delta_reset() {
    local db="$1"
    sqlite3 "$db" "DELETE FROM _warp_changes;" 2>/dev/null || true
}

# wv_delta_changeset — emit an executable SQL changeset to stdout.
#
# Uses SQL-generating-SQL: a single sqlite3 query reads _warp_changes and
# produces INSERT / UPDATE / DELETE statements for each row, ordered by id
# (insertion order = causal order). No external tools — sqlite3's quote()
# handles all SQL escaping correctly.
#
# INSERT rows  → INSERT OR REPLACE (creates or replaces the full row)
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
# and replayed on other agents via cmd_load. See wv_delta_apply for replay.
wv_delta_changeset() {
    local db="$1"
    sqlite3 "$db" "
SELECT
  CASE
    -- INSERT: create the full row (idempotent via OR REPLACE)
    WHEN operation = 'INSERT' AND table_name = 'nodes' THEN
      'INSERT OR REPLACE INTO nodes(id,text,status,metadata,alias) VALUES('
      || quote(json_extract(new_data,'\$.id')) || ','
      || quote(json_extract(new_data,'\$.text')) || ','
      || quote(json_extract(new_data,'\$.status')) || ','
      || quote(json_extract(new_data,'\$.metadata')) || ','
      || quote(json_extract(new_data,'\$.alias')) || ');'

    -- UPDATE nodes: field-level diff via IS NOT (NULL-safe).
    -- Only changed fields appear in the SET clause.
    -- Outer CASE guards against no-op UPDATEs producing invalid SQL.
    WHEN operation = 'UPDATE' AND table_name = 'nodes' THEN
      CASE WHEN
        (json_extract(old_data,'\$.text')     IS NOT json_extract(new_data,'\$.text'))     OR
        (json_extract(old_data,'\$.status')   IS NOT json_extract(new_data,'\$.status'))   OR
        (json_extract(old_data,'\$.metadata') IS NOT json_extract(new_data,'\$.metadata')) OR
        (json_extract(old_data,'\$.alias')    IS NOT json_extract(new_data,'\$.alias'))
      THEN
        'UPDATE nodes SET '
        || rtrim(
             CASE WHEN json_extract(old_data,'\$.text') IS NOT json_extract(new_data,'\$.text')
                  THEN 'text='     || quote(json_extract(new_data,'\$.text'))     || ',' ELSE '' END
             || CASE WHEN json_extract(old_data,'\$.status') IS NOT json_extract(new_data,'\$.status')
                     THEN 'status='   || quote(json_extract(new_data,'\$.status'))   || ',' ELSE '' END
             || CASE WHEN json_extract(old_data,'\$.metadata') IS NOT json_extract(new_data,'\$.metadata')
                     THEN 'metadata=' || quote(json_extract(new_data,'\$.metadata')) || ',' ELSE '' END
             || CASE WHEN json_extract(old_data,'\$.alias') IS NOT json_extract(new_data,'\$.alias')
                     THEN 'alias='    || quote(json_extract(new_data,'\$.alias'))    || ',' ELSE '' END,
             ','
           )
        || ' WHERE id=' || quote(json_extract(new_data,'\$.id')) || ';'
      ELSE
        '-- no-op UPDATE on node ' || quote(json_extract(new_data,'\$.id'))
      END

    -- INSERT edge: create the full row (idempotent via OR REPLACE)
    WHEN operation = 'INSERT' AND table_name = 'edges' THEN
      'INSERT OR REPLACE INTO edges(source,target,type,weight,context) VALUES('
      || quote(json_extract(new_data,'\$.source')) || ','
      || quote(json_extract(new_data,'\$.target')) || ','
      || quote(json_extract(new_data,'\$.type')) || ','
      || COALESCE(json_extract(new_data,'\$.weight'), 'NULL') || ','
      || quote(json_extract(new_data,'\$.context')) || ');'

    -- UPDATE edge: only weight and context are mutable (source/target/type are PK)
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
        || ' WHERE source=' || quote(json_extract(new_data,'\$.source'))
        || ' AND target='   || quote(json_extract(new_data,'\$.target'))
        || ' AND type='     || quote(json_extract(new_data,'\$.type')) || ';'
      ELSE
        '-- no-op UPDATE on edge ' || quote(json_extract(new_data,'\$.source'))
        || ':' || quote(json_extract(new_data,'\$.target'))
        || ':' || quote(json_extract(new_data,'\$.type'))
      END

    WHEN operation = 'DELETE' AND table_name = 'nodes' THEN
      'DELETE FROM nodes WHERE id=' || quote(row_id) || ';'

    WHEN operation = 'DELETE' AND table_name = 'edges'
         AND instr(row_id, ':') > 0
         AND instr(substr(row_id, instr(row_id,':')+1), ':') > 0 THEN
      -- Split 'source:target:type' on first and second colon
      'DELETE FROM edges WHERE source=' || quote(substr(row_id,1,instr(row_id,':')-1))
      || ' AND target=' || quote(substr(substr(row_id,instr(row_id,':')+1),1,
         instr(substr(row_id,instr(row_id,':')+1),':')-1))
      || ' AND type=' || quote(substr(substr(row_id,instr(row_id,':')+1),
         instr(substr(row_id,instr(row_id,':')+1),':')+1)) || ';'

    WHEN operation = 'DELETE' AND table_name = 'edges' THEN
      '-- WARNING: unparseable edge row_id: ' || quote(row_id)
  END
FROM _warp_changes ORDER BY id;
"
}

# wv_delta_apply — apply a SQL changeset from stdin to a target database.
# Thin wrapper around sqlite3 with a 5s busy timeout.
#
# Not yet called in production — reserved for Sprint 2 multi-agent merge path
# where cmd_load will pipe individual delta files through this function rather
# than shelling out to sqlite3 directly. The current cmd_load replay loop calls
# sqlite3 directly for now.
wv_delta_apply() {
    local db="$1"
    sqlite3 -cmd ".timeout 5000" "$db"
}
