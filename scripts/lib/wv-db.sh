#!/bin/bash
# wv-db.sh — Database initialization, migrations, queries
#
# Sourced by: wv entry point (after wv-config.sh)
# Dependencies: wv-config.sh (for WV_DB, WV_HOT_ZONE, WEAVE_DIR, etc.)

# ═══════════════════════════════════════════════════════════════════════════
# Database Initialization
# ═══════════════════════════════════════════════════════════════════════════

db_init() {
    mkdir -p "$WV_HOT_ZONE"
    mkdir -p "$WEAVE_DIR"
    validate_hot_size

    local pragmas
    read -r WV_CACHE WV_MMAP <<< "$(select_pragmas)"
    local max_pages=$(( WV_HOT_SIZE * 256 ))  # page_size=4096, so MB*256=pages

    sqlite3 "$WV_DB" <<EOF >/dev/null
-- Performance pragmas (scaled to system RAM, capped to hot zone)
PRAGMA journal_mode = WAL;
PRAGMA busy_timeout = 5000;
PRAGMA synchronous = NORMAL;
PRAGMA foreign_keys = ON;
PRAGMA cache_size = $WV_CACHE;
PRAGMA mmap_size = $WV_MMAP;
PRAGMA temp_store = MEMORY;
PRAGMA max_page_count = $max_pages;

-- nodes: task/context nodes (graph vertices)
CREATE TABLE IF NOT EXISTS nodes (
    id TEXT PRIMARY KEY,
    text TEXT NOT NULL,
    status TEXT DEFAULT 'todo',
    metadata JSON DEFAULT '{}',
    alias TEXT,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    -- Virtual columns for O(1) metadata filtering (Tier 1)
    priority INTEGER GENERATED ALWAYS AS (json_extract(metadata, '$.priority')) VIRTUAL,
    type TEXT GENERATED ALWAYS AS (json_extract(metadata, '$.type')) VIRTUAL
);

-- edges: relationships between nodes (graph edges)
CREATE TABLE IF NOT EXISTS edges (
    source TEXT NOT NULL,
    target TEXT NOT NULL,
    type TEXT NOT NULL CHECK(type IN ('blocks', 'relates_to', 'implements', 'contradicts', 'supersedes', 'references', 'obsoletes', 'addresses')),
    weight REAL DEFAULT 1.0,
    context JSON DEFAULT '{}',
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY(source, target, type),
    FOREIGN KEY(source) REFERENCES nodes(id),
    FOREIGN KEY(target) REFERENCES nodes(id)
);

-- indexes for fast graph traversal
CREATE INDEX IF NOT EXISTS idx_nodes_status ON nodes(status);
CREATE INDEX IF NOT EXISTS idx_nodes_priority ON nodes(priority);
CREATE INDEX IF NOT EXISTS idx_nodes_type ON nodes(type);
CREATE INDEX IF NOT EXISTS idx_nodes_type_priority ON nodes(type, priority);
CREATE UNIQUE INDEX IF NOT EXISTS idx_nodes_alias ON nodes(alias) WHERE alias IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_edges_target ON edges(target);
CREATE INDEX IF NOT EXISTS idx_edges_type ON edges(type);
CREATE INDEX IF NOT EXISTS idx_edges_source_type ON edges(source, type);
CREATE INDEX IF NOT EXISTS idx_edges_target_type ON edges(target, type);

-- FTS5 full-text search index (Phase 2.1)
-- Uses porter stemmer + unicode for better search quality
CREATE VIRTUAL TABLE IF NOT EXISTS nodes_fts USING fts5(
    id, text, metadata,
    content=nodes,
    content_rowid=rowid,
    tokenize='porter unicode61'
);

-- Keep FTS in sync with nodes table
CREATE TRIGGER IF NOT EXISTS nodes_ai AFTER INSERT ON nodes BEGIN
    INSERT INTO nodes_fts(rowid, id, text, metadata)
    VALUES (new.rowid, new.id, new.text, new.metadata);
END;

CREATE TRIGGER IF NOT EXISTS nodes_ad AFTER DELETE ON nodes BEGIN
    INSERT INTO nodes_fts(nodes_fts, rowid, id, text, metadata)
    VALUES ('delete', old.rowid, old.id, old.text, old.metadata);
END;

CREATE TRIGGER IF NOT EXISTS nodes_au AFTER UPDATE ON nodes BEGIN
    INSERT INTO nodes_fts(nodes_fts, rowid, id, text, metadata)
    VALUES ('delete', old.rowid, old.id, old.text, old.metadata);
    INSERT INTO nodes_fts(rowid, id, text, metadata)
    VALUES (new.rowid, new.id, new.text, new.metadata);
END;
EOF
}

# ═══════════════════════════════════════════════════════════════════════════
# Database Migrations
# ═══════════════════════════════════════════════════════════════════════════

# Migrate edges table from old schema (no weight/context/created_at) to new.
# Safe to run repeatedly — ALTER TABLE on existing column is a no-op error we suppress.
db_migrate_edges() {
    # ALTER TABLE cannot use CURRENT_TIMESTAMP as default (non-constant).
    # Use NULL default for migration; new rows get timestamp from CREATE TABLE schema.
    sqlite3 "$WV_DB" <<'MIGRATE' 2>/dev/null || true
ALTER TABLE edges ADD COLUMN weight REAL DEFAULT 1.0;
ALTER TABLE edges ADD COLUMN context JSON DEFAULT '{}';
ALTER TABLE edges ADD COLUMN created_at DATETIME;
CREATE INDEX IF NOT EXISTS idx_edges_source_type ON edges(source, type);
CREATE INDEX IF NOT EXISTS idx_edges_target_type ON edges(target, type);
MIGRATE
}

# Migrate nodes table to add alias column (Sprint 3: human-readable aliases).
# Safe to run repeatedly — ALTER TABLE on existing column is a no-op error we suppress.
db_migrate_alias() {
    sqlite3 "$WV_DB" <<'MIGRATE' 2>/dev/null || true
ALTER TABLE nodes ADD COLUMN alias TEXT;
CREATE UNIQUE INDEX IF NOT EXISTS idx_nodes_alias ON nodes(alias) WHERE alias IS NOT NULL;
MIGRATE
}

# Migrate nodes table to add virtual columns for JSON metadata (Tier 1).
# Safe to run repeatedly — ALTER TABLE on existing column is a no-op error we suppress.
db_migrate_virtual_columns() {
    # Virtual columns are computed from JSON on read, no storage overhead.
    # VIRTUAL keyword may be required for older SQLite versions (<3.31).
    sqlite3 "$WV_DB" <<'MIGRATE' 2>/dev/null || true
ALTER TABLE nodes ADD COLUMN priority INTEGER GENERATED ALWAYS AS (json_extract(metadata, '$.priority')) VIRTUAL;
ALTER TABLE nodes ADD COLUMN type TEXT GENERATED ALWAYS AS (json_extract(metadata, '$.type')) VIRTUAL;
CREATE INDEX IF NOT EXISTS idx_nodes_priority ON nodes(priority);
CREATE INDEX IF NOT EXISTS idx_nodes_type ON nodes(type);
CREATE INDEX IF NOT EXISTS idx_nodes_type_priority ON nodes(type, priority);
MIGRATE
}

# Migrate to add FTS5 full-text search table (Phase 2.1).
# Safe to run repeatedly — creates only if not exists.
db_migrate_fts5() {
    # Check if FTS5 is available in this SQLite build
    local fts5_available
    fts5_available=$(sqlite3 "$WV_DB" "SELECT sqlite_compileoption_used('ENABLE_FTS5');" 2>/dev/null || echo "0")
    
    if [ "$fts5_available" != "1" ]; then
        # FTS5 not available, skip silently
        return 0
    fi
    
    # Create FTS5 table and triggers if they don't exist
    sqlite3 "$WV_DB" <<'MIGRATE' 2>/dev/null || true
-- FTS5 full-text search index
CREATE VIRTUAL TABLE IF NOT EXISTS nodes_fts USING fts5(
    id, text, metadata,
    content=nodes,
    content_rowid=rowid,
    tokenize='porter unicode61'
);

-- Keep FTS in sync with nodes table
CREATE TRIGGER IF NOT EXISTS nodes_ai AFTER INSERT ON nodes BEGIN
    INSERT INTO nodes_fts(rowid, id, text, metadata)
    VALUES (new.rowid, new.id, new.text, new.metadata);
END;

CREATE TRIGGER IF NOT EXISTS nodes_ad AFTER DELETE ON nodes BEGIN
    INSERT INTO nodes_fts(nodes_fts, rowid, id, text, metadata)
    VALUES ('delete', old.rowid, old.id, old.text, old.metadata);
END;

CREATE TRIGGER IF NOT EXISTS nodes_au AFTER UPDATE ON nodes BEGIN
    INSERT INTO nodes_fts(nodes_fts, rowid, id, text, metadata)
    VALUES ('delete', old.rowid, old.id, old.text, old.metadata);
    INSERT INTO nodes_fts(rowid, id, text, metadata)
    VALUES (new.rowid, new.id, new.text, new.metadata);
END;
MIGRATE
}

# Rebuild FTS5 index from existing nodes (for migration or repair)
db_reindex_fts5() {
    db_ensure
    
    # Check if FTS5 is available
    local fts5_available
    fts5_available=$(sqlite3 "$WV_DB" "SELECT sqlite_compileoption_used('ENABLE_FTS5');" 2>/dev/null || echo "0")
    
    if [ "$fts5_available" != "1" ]; then
        echo "Error: FTS5 not available in this SQLite build" >&2
        return 1
    fi
    
    echo "Rebuilding FTS5 index..." >&2
    
    sqlite3 "$WV_DB" <<'REINDEX'
-- Ensure FTS table exists
CREATE VIRTUAL TABLE IF NOT EXISTS nodes_fts USING fts5(
    id, text, metadata,
    content=nodes,
    content_rowid=rowid,
    tokenize='porter unicode61'
);

-- Rebuild entire index (FTS5 special command for content tables)
INSERT INTO nodes_fts(nodes_fts) VALUES('rebuild');
REINDEX

    local count
    count=$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM nodes_fts;")
    echo "Indexed $count nodes" >&2
}

# ═══════════════════════════════════════════════════════════════════════════
# Database Ensure (with auto-prune)
# ═══════════════════════════════════════════════════════════════════════════

db_ensure() {
    if [ ! -f "$WV_DB" ]; then
        # Migration: detect pre-v1.2 global hot zone layout
        # Old: /dev/shm/weave/brain.db (single DB for all repos)
        # New: /dev/shm/weave/<hash>/brain.db (per-repo namespace)
        local old_global_db="${_WV_BASE_HOT_ZONE}/brain.db"
        if [ -z "$WV_DB_CUSTOM" ] && [ -f "$old_global_db" ] && [ "$old_global_db" != "$WV_DB" ]; then
            local old_nodes
            old_nodes=$(sqlite3 -cmd ".timeout 5000" "$old_global_db" "SELECT COUNT(*) FROM nodes;" 2>/dev/null || echo "0")
            if [ "$old_nodes" -gt 0 ] 2>/dev/null; then
                echo -e "${YELLOW}Found pre-v1.2 global database: $old_global_db ($old_nodes nodes)${NC}" >&2
                echo -e "${YELLOW}Migrating to per-repo path: $WV_DB${NC}" >&2
                mkdir -p "$(dirname "$WV_DB")"
                if cp "$old_global_db" "$WV_DB" 2>/dev/null; then
                    echo -e "${GREEN}✓ Migrated $old_nodes nodes to $WV_DB${NC}" >&2
                    echo -e "${YELLOW}Old database kept at $old_global_db — remove manually when ready${NC}" >&2
                    # Run schema migrations on the copied DB
                    db_migrate_edges
                    db_migrate_alias
                    db_migrate_virtual_columns
                    db_migrate_fts5
                    _WV_DB_READY=1
                    return 0
                else
                    echo -e "${RED}Migration failed — continuing with normal init${NC}" >&2
                fi
            fi
        fi

        if [ -z "$WV_DB_CUSTOM" ] && [ -f "$WEAVE_DIR/state.sql" ]; then
            # State exists on disk but DB is missing (reboot, new machine)
            # Auto-load instead of starting fresh — prevents silent data loss
            echo -e "${YELLOW}Weave database not found at $WV_DB${NC}" >&2
            echo -e "${YELLOW}Restoring from $WEAVE_DIR/state.sql...${NC}" >&2
            db_init
            if sqlite3 "$WV_DB" < "$WEAVE_DIR/state.sql" 2>/dev/null; then
                db_migrate_edges
                db_migrate_alias
                db_migrate_virtual_columns
                db_migrate_fts5
                echo -e "${GREEN}✓${NC} Restored from $WEAVE_DIR/state.sql" >&2
            else
                echo -e "${RED}Error: failed to restore from state.sql${NC}" >&2
                echo "Run 'wv load' manually or 'wv init' to start fresh." >&2
            fi
        else
            db_init
            # Safety net: warn if .weave/ has data but we just created an empty DB
            if [ -z "$WV_DB_CUSTOM" ] && [ -d "$WEAVE_DIR" ]; then
                local has_data=false
                [ -f "$WEAVE_DIR/nodes.jsonl" ] && [ -s "$WEAVE_DIR/nodes.jsonl" ] && has_data=true
                [ -f "$WEAVE_DIR/state.sql" ] && has_data=true
                if $has_data; then
                    echo -e "${YELLOW}Warning: Empty database but .weave/ contains data.${NC}" >&2
                    echo -e "${YELLOW}Run 'wv load' to restore your graph.${NC}" >&2
                fi
            fi
        fi
    else
        # DB exists — check for empty database with data on disk (safety net)
        local cold_start_flag="$WV_HOT_ZONE/.cold_start_checked"
        if [ ! -f "$cold_start_flag" ] && [ -z "$WV_DB_CUSTOM" ]; then
            touch "$cold_start_flag"
            local node_count
            node_count=$(sqlite3 -cmd ".timeout 5000" "$WV_DB" "SELECT COUNT(*) FROM nodes;" 2>/dev/null || echo "0")
            if [ "$node_count" = "0" ] && [ -f "$WEAVE_DIR/state.sql" ]; then
                echo -e "${YELLOW}Warning: Database has 0 nodes but .weave/state.sql exists.${NC}" >&2
                echo -e "${YELLOW}Run 'wv load' to restore your graph.${NC}" >&2
            fi
        fi
    fi
    # Check DB size once per invocation — auto-prune if over limit
    # WV_DISABLE_AUTOPRUNE=1 skips this (used during sync to prevent mid-sync data loss)
    if [ -z "${_WV_SIZE_CHECKED:-}" ] && [ -f "$WV_DB" ] && [ -z "${WV_DISABLE_AUTOPRUNE:-}" ]; then
        _WV_SIZE_CHECKED=1
        local db_size
        db_size=$(stat -c%s "$WV_DB" 2>/dev/null || stat -f%z "$WV_DB" 2>/dev/null || echo 0)
        if [ "$db_size" -gt "$WV_MAX_DB_SIZE" ] 2>/dev/null; then
            echo "wv: database is $(( db_size / 1048576 ))MB (limit $(( WV_MAX_DB_SIZE / 1048576 ))MB), auto-pruning..." >&2
            # Inline aggressive prune — archive done nodes >24h
            local archive_dir="$WEAVE_DIR/archive"
            mkdir -p "$archive_dir"
            sqlite3 -json "$WV_DB" "SELECT * FROM nodes WHERE status='done' AND updated_at < datetime('now', '-24 hours')" 2>/dev/null \
                | jq -c '.[]' >> "$archive_dir/$(date +%Y-%m-%d).jsonl" 2>/dev/null || true
            sqlite3 "$WV_DB" "
                DELETE FROM edges WHERE source IN (SELECT id FROM nodes WHERE status='done' AND updated_at < datetime('now', '-24 hours'))
                   OR target IN (SELECT id FROM nodes WHERE status='done' AND updated_at < datetime('now', '-24 hours'));
                DELETE FROM nodes WHERE status='done' AND updated_at < datetime('now', '-24 hours');
                VACUUM;
            " 2>/dev/null
            if [ $? -ne 0 ]; then
                echo "wv: auto-prune failed (database locked or disk full?)" >&2
            fi
            # Clear entire context cache after auto-prune (can't track specific affected nodes)
            rm -rf "$WV_HOT_ZONE/context_cache" 2>/dev/null || true
            echo "wv: context cache cleared after auto-prune" >&2
        fi
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# Query Helpers
# ═══════════════════════════════════════════════════════════════════════════

db_query() {
    db_ensure
    sqlite3 -batch -cmd ".timeout 5000" "$WV_DB" "$1"
}

db_query_json() {
    db_ensure
    sqlite3 -json -cmd ".timeout 5000" "$WV_DB" "$1"
}
