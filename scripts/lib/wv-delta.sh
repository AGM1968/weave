#!/usr/bin/env bash
# wv-delta.sh — Pure-bash delta tracking (replaces warp-session binary)
# See docs/PROPOSAL-wv-delta.md for design decisions.
#
# Functions:
#   wv_delta_init         Create _warp_changes table + 6 triggers (idempotent)
#   wv_delta_has_changes  O(1) check → exit 0 if changes exist, exit 1 if not
#   wv_delta_reset        Clear all tracked changes
#   wv_delta_changeset    Emit SQL changeset to stdout
#   wv_delta_apply        Apply SQL from stdin to a database

# Shell cache: skip probe SELECT after first successful init (Task 2.5 optimization)
_WV_DELTA_INITED=""

# --- DDL (identical to warp/crates/warp-session/src/schema.rs) ---

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

wv_delta_init() {
    local db="$1"
    sqlite3 "$db" "${_WV_DELTA_CREATE_TABLE}${_WV_DELTA_TRIGGERS_NODES}${_WV_DELTA_TRIGGERS_EDGES}"
    _WV_DELTA_INITED=1
}

wv_delta_has_changes() {
    local db="$1"
    # Self-healing: if _warp_changes doesn't exist, init triggers
    # Guard: nodes table must exist (trigger DDL requires it) — bail if not
    if [ -z "$_WV_DELTA_INITED" ]; then
        if ! sqlite3 "$db" "SELECT 1 FROM _warp_changes LIMIT 0;" 2>/dev/null; then
            sqlite3 "$db" "SELECT 1 FROM nodes LIMIT 0;" 2>/dev/null || return 1
            wv_delta_init "$db"
            return 1  # No changes yet (just initialized)
        fi
        _WV_DELTA_INITED=1
    fi
    local result
    result=$(sqlite3 "$db" "SELECT EXISTS(SELECT 1 FROM _warp_changes);")
    [ "$result" = "1" ]
}

wv_delta_reset() {
    local db="$1"
    sqlite3 "$db" "DELETE FROM _warp_changes;" 2>/dev/null || true
}

wv_delta_changeset() {
    local db="$1"
    sqlite3 "$db" "
SELECT
  CASE
    WHEN operation IN ('INSERT','UPDATE') AND table_name = 'nodes' THEN
      'INSERT OR REPLACE INTO nodes(id,text,status,metadata,alias) VALUES('
      || quote(json_extract(new_data,'\$.id')) || ','
      || quote(json_extract(new_data,'\$.text')) || ','
      || quote(json_extract(new_data,'\$.status')) || ','
      || quote(json_extract(new_data,'\$.metadata')) || ','
      || quote(json_extract(new_data,'\$.alias')) || ');'
    WHEN operation IN ('INSERT','UPDATE') AND table_name = 'edges' THEN
      'INSERT OR REPLACE INTO edges(source,target,type,weight,context) VALUES('
      || quote(json_extract(new_data,'\$.source')) || ','
      || quote(json_extract(new_data,'\$.target')) || ','
      || quote(json_extract(new_data,'\$.type')) || ','
      || COALESCE(json_extract(new_data,'\$.weight'), 'NULL') || ','
      || quote(json_extract(new_data,'\$.context')) || ');'
    WHEN operation = 'DELETE' AND table_name = 'nodes' THEN
      'DELETE FROM nodes WHERE id=' || quote(row_id) || ';'
    WHEN operation = 'DELETE' AND table_name = 'edges'
         AND instr(row_id, ':') > 0
         AND instr(substr(row_id, instr(row_id,':')+1), ':') > 0 THEN
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

wv_delta_apply() {
    local db="$1"
    sqlite3 -cmd ".timeout 5000" "$db"
}
