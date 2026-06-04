#!/bin/bash
# wv-db.sh — Database initialization, migrations, queries
#
# Sourced by: wv entry point (after wv-config.sh)
# Dependencies: wv-config.sh (for WV_DB, WV_HOT_ZONE, WEAVE_DIR, etc.)

# ═══════════════════════════════════════════════════════════════════════════
# Database Initialization
# ═══════════════════════════════════════════════════════════════════════════

db_stamp_repo_owner() {
    [ -n "${REPO_ROOT:-}" ] || return 0
    [ -n "${WV_HOT_ZONE:-}" ] || return 0

    local owner_file canonical_repo_root
    owner_file=$(resolve_hot_zone_owner_file "$WV_HOT_ZONE")
    [ -n "$owner_file" ] || return 0

    canonical_repo_root=$(canonicalize_runtime_path "$REPO_ROOT")
    mkdir -p "$WV_HOT_ZONE" 2>/dev/null || true
    printf '%s\n' "$canonical_repo_root" > "$owner_file" 2>/dev/null || true
    chmod 600 "$owner_file" 2>/dev/null || true
}

db_init() {
    # Security: hot zone may be under /dev/shm or /tmp (shared-mount parents).
    # Create 700/600 so other local users cannot read the graph. `umask 077`
    # covers the DB file; explicit chmod covers existing dirs that predate
    # this change. See security review L5 (2026-04-19).
    #
    # Do not create $WEAVE_DIR here. db_init backs both explicit initialization
    # and read-ish paths like `wv health`, `wv status`, and session-start
    # hooks. Auto-creating the repo's .weave directory here would opt
    # uninitialized repositories into Weave just by inspecting them.
    local prev_umask
    prev_umask=$(umask)
    umask 077
    mkdir -p "$WV_HOT_ZONE"
    chmod 700 "$WV_HOT_ZONE" 2>/dev/null || true
    umask "$prev_umask"
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
    type TEXT NOT NULL CHECK(type IN ('blocks', 'relates_to', 'implements', 'contradicts', 'supersedes', 'references', 'obsoletes', 'addresses', 'resolves')),
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
CREATE UNIQUE INDEX IF NOT EXISTS idx_nodes_alias ON nodes(alias) WHERE alias IS NOT NULL AND status != 'done';
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

-- node_files: repo-relative files attributed by the touched-files hook.
CREATE TABLE IF NOT EXISTS node_files (
    node_id TEXT NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
    path    TEXT NOT NULL,
    PRIMARY KEY (node_id, path)
);

CREATE INDEX IF NOT EXISTS idx_node_files_node ON node_files(node_id);

-- file_metrics: per-file quality metrics, flat schema (populated by wv done in P2).
-- Stub is always present so the policy trigger can be compiled; starts empty.
-- Populated by wv done querying quality.db (weave_quality/db.py) before the UPDATE.
-- language: file extension ('py', 'sh', 'ts', '') — drives per-language threshold lookup.
CREATE TABLE IF NOT EXISTS file_metrics (
    path       TEXT PRIMARY KEY,
    mccabe_max INTEGER NOT NULL DEFAULT 0,
    language   TEXT    NOT NULL DEFAULT ''
);

-- policy_thresholds: configurable quality gates consulted by the done trigger
CREATE TABLE IF NOT EXISTS policy_thresholds (
    key   TEXT PRIMARY KEY,
    value REAL NOT NULL
);

INSERT OR IGNORE INTO policy_thresholds(key, value) VALUES ('mccabe_max',    15);
INSERT OR IGNORE INTO policy_thresholds(key, value) VALUES ('mccabe_max_py', 25);
INSERT OR IGNORE INTO policy_thresholds(key, value) VALUES ('mccabe_max_sh', 100);
INSERT OR IGNORE INTO policy_thresholds(key, value) VALUES ('mccabe_max_ts', 15);
INSERT OR IGNORE INTO policy_thresholds(key, value) VALUES ('gini_max', 0.85);
INSERT OR IGNORE INTO policy_thresholds(key, value) VALUES ('trend_deteriorating', 0);
-- test_gate: 0=off (inert), 1=warn (soft, cmd_done), 2=block (trigger ABORT). Default off; P6c rolls out.
INSERT OR IGNORE INTO policy_thresholds(key, value) VALUES ('test_gate', 0);

-- quality_exempt: path patterns excluded from quality gate enforcement.
-- Patterns use SQLite LIKE syntax; trailing '/' matches directory prefix (appended as '%').
-- Populated by wv load from .weave/quality.conf [exempt] section.
CREATE TABLE IF NOT EXISTS quality_exempt (
    path_pattern TEXT PRIMARY KEY,
    reason       TEXT NOT NULL DEFAULT ''
);

-- file_trend: per-file trend direction, refreshed by wv done from quality.db.
-- Values: 'deteriorating' | 'stable' | 'refactored'. Consumed by wv-67a870 soft
-- warning and wv-44cbc5 hard gate; stored here so the trigger can query it.
CREATE TABLE IF NOT EXISTS file_trend (
    path      TEXT PRIMARY KEY,
    direction TEXT NOT NULL DEFAULT 'stable'
);

-- test_results: the verification ledger (P6a/P6b). Records each suite's outcome
-- per covered file when it runs (pre-commit, post-commit, make check, CI) so
-- wv done can read a fresh result instead of invoking a runner — the
-- producer/consumer split (PROPOSAL graph-as-policy-boundary §4.6). Producers
-- are language-specific test runners; the consumer (_done_refresh_test_status)
-- is language-neutral.
--   fingerprint = git blob hash of THIS single file (mtime:size fallback for
--                 unstaged/untracked). Per-file so the consumer can recompute it
--                 with the identical pure function — no ephemeral combined key to
--                 reconstruct. wv test-record writes one row per --files entry.
--   commit_sha  = short HEAD at record time ('commit' in the proposal; renamed
--                 to avoid the SQL reserved word).
-- PK (suite, path): latest outcome wins per suite+file.
CREATE TABLE IF NOT EXISTS test_results (
    suite       TEXT    NOT NULL,
    path        TEXT    NOT NULL DEFAULT '',
    fingerprint TEXT    NOT NULL,
    exit_code   INTEGER NOT NULL,
    ran_at      TEXT    NOT NULL DEFAULT (datetime('now')),
    commit_sha  TEXT    NOT NULL DEFAULT '',
    duration_ms INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (suite, path)
);

CREATE INDEX IF NOT EXISTS idx_test_results_suite ON test_results(suite);

-- file_test_status: per-file test-correctness state (P6b consumer side).
-- state ∈ {green, red, stale, unknown}; refreshed by _done_refresh_test_status
-- from test_results before the status flip. nodes_policy_check reads it (3rd
-- clause), gated by policy_thresholds.test_gate (0=off, 1=warn, 2=block).
CREATE TABLE IF NOT EXISTS file_test_status (
    path  TEXT PRIMARY KEY,
    state TEXT NOT NULL DEFAULT 'unknown'
);

-- chunks: file content slices with embeddings for semantic search.
-- embedding is a raw float32 BLOB (N * 4 bytes); NULL until wv index runs.
CREATE TABLE IF NOT EXISTS chunks (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    file       TEXT    NOT NULL,
    line_start INTEGER NOT NULL,
    line_end   INTEGER NOT NULL,
    content    TEXT    NOT NULL,
    embedding  BLOB,
    indexed_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_chunks_file ON chunks(file);

-- FTS5 over chunk content enables BM25 keyword fallback when no embedding.
CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
    content,
    file UNINDEXED,
    line_start UNINDEXED,
    line_end UNINDEXED,
    content=chunks,
    content_rowid=id
);

-- Trigger: keep chunks_fts in sync on insert
CREATE TRIGGER IF NOT EXISTS chunks_ai AFTER INSERT ON chunks BEGIN
    INSERT INTO chunks_fts(rowid, content, file, line_start, line_end)
    VALUES (new.id, new.content, new.file, new.line_start, new.line_end);
END;

-- Trigger: keep chunks_fts in sync on delete
CREATE TRIGGER IF NOT EXISTS chunks_ad AFTER DELETE ON chunks BEGIN
    INSERT INTO chunks_fts(chunks_fts, rowid, content, file, line_start, line_end)
    VALUES ('delete', old.id, old.content, old.file, old.line_start, old.line_end);
END;

-- Trigger: keep chunks_fts in sync on update
CREATE TRIGGER IF NOT EXISTS chunks_au AFTER UPDATE ON chunks BEGIN
    INSERT INTO chunks_fts(chunks_fts, rowid, content, file, line_start, line_end)
    VALUES ('delete', old.id, old.content, old.file, old.line_start, old.line_end);
    INSERT INTO chunks_fts(rowid, content, file, line_start, line_end)
    VALUES (new.id, new.content, new.file, new.line_start, new.line_end);
END;

-- Trigger: gate active→done transitions on file quality metrics.
-- Fires BEFORE the UPDATE so the FTS AFTER UPDATE trigger never sees a
-- violating state. RAISE(ABORT, ...) requires a string literal — structured
-- JSON payload is built by cmd_done after catch.
-- quality_exempt patterns (trailing '/' = directory prefix) are excluded from the gate.
CREATE TRIGGER IF NOT EXISTS nodes_policy_check
BEFORE UPDATE OF status ON nodes
WHEN NEW.status = 'done' AND OLD.status = 'active'
BEGIN
        SELECT CASE
                WHEN EXISTS (
                        SELECT 1 FROM node_files nf
                        JOIN file_metrics fm ON fm.path = nf.path
                        WHERE nf.node_id = NEW.id
                            AND fm.mccabe_max > COALESCE(
                                (SELECT value FROM policy_thresholds WHERE key = 'mccabe_max_' || fm.language),
                                (SELECT value FROM policy_thresholds WHERE key = 'mccabe_max')
                            )
                            AND NOT EXISTS (
                                SELECT 1 FROM quality_exempt qe
                                WHERE nf.path LIKE
                                    CASE WHEN qe.path_pattern LIKE '%/'
                                         THEN qe.path_pattern || '%'
                                         ELSE qe.path_pattern
                                    END
                            )
                ) THEN RAISE(ABORT, 'GraphPolicyViolation: mccabe_max threshold exceeded')
                WHEN EXISTS (
                        SELECT 1 FROM node_files nf
                        JOIN file_trend ft ON ft.path = nf.path
                        WHERE nf.node_id = NEW.id
                            AND ft.direction = 'deteriorating'
                            AND (SELECT value FROM policy_thresholds WHERE key = 'trend_deteriorating') >= 1
                            AND NOT EXISTS (
                                SELECT 1 FROM quality_exempt qe
                                WHERE nf.path LIKE
                                    CASE WHEN qe.path_pattern LIKE '%/'
                                         THEN qe.path_pattern || '%'
                                         ELSE qe.path_pattern
                                    END
                            )
                ) THEN RAISE(ABORT, 'GraphPolicyViolation: trend_deteriorating threshold exceeded')
        END;
END;
EOF
    # Authoritative trigger: recreate nodes_policy_check from the single-source
    # emitter so a fresh DB has the complete (3-clause) trigger immediately, not
    # only after the next db_ensure migration pass. The inline copy in the schema
    # heredoc above is the bootstrap version; this supersedes it. (The heredoc is
    # an unquoted <<EOF — it cannot call a function mid-body, hence this follow-up.)
    _policy_trigger_sql | sqlite3 "$WV_DB" 2>/dev/null || true
    # Tighten perms on the DB file in case it predates the umask change.
    [ -f "$WV_DB" ] && chmod 600 "$WV_DB" 2>/dev/null || true
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

# Migrate edges table CHECK constraint to allow newer edge types like resolves.
# SQLite cannot ALTER an existing CHECK constraint, so rebuild the table in place.
db_migrate_edge_type_enum() {
    db_migrate_edges

    local edges_sql
    edges_sql=$(sqlite3 "$WV_DB" "SELECT sql FROM sqlite_master WHERE type='table' AND name='edges';" 2>/dev/null || true)
    if [[ "$edges_sql" == *"'resolves'"* ]]; then
        return 0
    fi

    sqlite3 "$WV_DB" <<'MIGRATE'
PRAGMA foreign_keys = OFF;
BEGIN;
ALTER TABLE edges RENAME TO edges_old;
CREATE TABLE edges (
    source TEXT NOT NULL,
    target TEXT NOT NULL,
    type TEXT NOT NULL CHECK(type IN ('blocks', 'relates_to', 'implements', 'contradicts', 'supersedes', 'references', 'obsoletes', 'addresses', 'resolves')),
    weight REAL DEFAULT 1.0,
    context JSON DEFAULT '{}',
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY(source, target, type),
    FOREIGN KEY(source) REFERENCES nodes(id),
    FOREIGN KEY(target) REFERENCES nodes(id)
);
INSERT INTO edges (source, target, type, weight, context, created_at)
SELECT source, target, type, weight, context, created_at
FROM edges_old;
DROP TABLE edges_old;
CREATE INDEX IF NOT EXISTS idx_edges_target ON edges(target);
CREATE INDEX IF NOT EXISTS idx_edges_type ON edges(type);
CREATE INDEX IF NOT EXISTS idx_edges_source_type ON edges(source, type);
CREATE INDEX IF NOT EXISTS idx_edges_target_type ON edges(target, type);
COMMIT;
PRAGMA foreign_keys = ON;
MIGRATE
}

# Migrate nodes table to add alias column (Sprint 3: human-readable aliases).
# Safe to run repeatedly — ALTER TABLE on existing column is a no-op error we suppress.
db_migrate_alias() {
    sqlite3 "$WV_DB" <<'MIGRATE' 2>/dev/null || true
ALTER TABLE nodes ADD COLUMN alias TEXT;
MIGRATE
    # Relax alias uniqueness: allow reuse when prior node is done.
    # DROP the old strict index, then create the relaxed one.
    sqlite3 "$WV_DB" <<'MIGRATE_ALIAS_IDX' 2>/dev/null || true
DROP INDEX IF EXISTS idx_nodes_alias;
CREATE UNIQUE INDEX IF NOT EXISTS idx_nodes_alias ON nodes(alias) WHERE alias IS NOT NULL AND status != 'done';
MIGRATE_ALIAS_IDX
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

# Migrate to add nodes_learning_fts — separate FTS5 table over extracted learning text.
# Indexed: decision, pattern, pitfall, learning fields from metadata JSON.
# Weighted 2× in cmd_search relative to node title (text) matches.
# Safe to run repeatedly — CREATE IF NOT EXISTS guards + backfill skips existing rows.
db_migrate_fts5_learning() {
    local fts5_available
    fts5_available=$(sqlite3 "$WV_DB" "SELECT sqlite_compileoption_used('ENABLE_FTS5');" 2>/dev/null || echo "0")
    [ "$fts5_available" != "1" ] && return 0

    sqlite3 "$WV_DB" <<'MIGRATE' 2>/dev/null || true
CREATE VIRTUAL TABLE IF NOT EXISTS nodes_learning_fts USING fts5(
    id, learning_text,
    tokenize='porter unicode61'
);

-- Keep learning FTS in sync with nodes table
CREATE TRIGGER IF NOT EXISTS nodes_learning_ai AFTER INSERT ON nodes BEGIN
    INSERT INTO nodes_learning_fts(rowid, id, learning_text)
    VALUES (new.rowid, new.id,
        TRIM(
            COALESCE(json_extract(new.metadata, '$.decision'), '') || ' ' ||
            COALESCE(json_extract(new.metadata, '$.pattern'),  '') || ' ' ||
            COALESCE(json_extract(new.metadata, '$.pitfall'),  '') || ' ' ||
            COALESCE(json_extract(new.metadata, '$.learning'), '')
        )
    );
END;

CREATE TRIGGER IF NOT EXISTS nodes_learning_ad AFTER DELETE ON nodes BEGIN
    DELETE FROM nodes_learning_fts WHERE rowid = old.rowid;
END;

CREATE TRIGGER IF NOT EXISTS nodes_learning_au AFTER UPDATE ON nodes BEGIN
    DELETE FROM nodes_learning_fts WHERE rowid = old.rowid;
    INSERT INTO nodes_learning_fts(rowid, id, learning_text)
    VALUES (new.rowid, new.id,
        TRIM(
            COALESCE(json_extract(new.metadata, '$.decision'), '') || ' ' ||
            COALESCE(json_extract(new.metadata, '$.pattern'),  '') || ' ' ||
            COALESCE(json_extract(new.metadata, '$.pitfall'),  '') || ' ' ||
            COALESCE(json_extract(new.metadata, '$.learning'), '')
        )
    );
END;
MIGRATE

    # Backfill existing nodes that have learning content but no FTS row yet.
    sqlite3 "$WV_DB" <<'BACKFILL' 2>/dev/null || true
INSERT OR IGNORE INTO nodes_learning_fts(rowid, id, learning_text)
SELECT n.rowid, n.id,
    TRIM(
        COALESCE(json_extract(n.metadata, '$.decision'), '') || ' ' ||
        COALESCE(json_extract(n.metadata, '$.pattern'),  '') || ' ' ||
        COALESCE(json_extract(n.metadata, '$.pitfall'),  '') || ' ' ||
        COALESCE(json_extract(n.metadata, '$.learning'), '')
    )
FROM nodes n
WHERE TRIM(
    COALESCE(json_extract(n.metadata, '$.decision'), '') || ' ' ||
    COALESCE(json_extract(n.metadata, '$.pattern'),  '') || ' ' ||
    COALESCE(json_extract(n.metadata, '$.pitfall'),  '') || ' ' ||
    COALESCE(json_extract(n.metadata, '$.learning'), '')
) != ''
AND n.rowid NOT IN (SELECT rowid FROM nodes_learning_fts);
BACKFILL
}

# Backfill promoted_at on existing finding nodes that predate the bash-level stamp.
# Pure UPDATE — no triggers (SQLite virtual column + warp trigger interaction crashes).
# Safe to run repeatedly — WHERE clause filters to nodes that still lack the field.
db_migrate_finding_promoted_at() {
    sqlite3 "$WV_DB" <<'BACKFILL' 2>/dev/null || true
UPDATE nodes
SET metadata = json_patch(COALESCE(metadata, '{}'),
      json_object('promoted_at', strftime('%Y-%m-%dT%H:%M:%SZ', 'now')))
WHERE json_extract(metadata, '$.type') = 'finding'
  AND json_extract(metadata, '$.promoted_at') IS NULL;
BACKFILL
}

# Migrate to add the test_results verification ledger (P6a/P6b). Per-file rows
# keyed (suite, path) so the consumer can recompute each file's fingerprint with
# the identical pure function. The ledger is a throwaway cache repopulated by the
# commit hooks, so an old-shape table (pre-path, PK suite,fingerprint) is dropped
# and recreated rather than data-migrated.
db_migrate_test_results() {
    # Detect the legacy shape (no 'path' column) and drop it — no data to preserve.
    local has_path
    has_path=$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM pragma_table_info('test_results') WHERE name='path';" 2>/dev/null || echo "0")
    local table_exists
    table_exists=$(sqlite3 "$WV_DB" "SELECT name FROM sqlite_master WHERE type='table' AND name='test_results';" 2>/dev/null || echo "")
    if [ -n "$table_exists" ] && [ "$has_path" = "0" ]; then
        sqlite3 "$WV_DB" "DROP TABLE IF EXISTS test_results;" 2>/dev/null || true
    fi

    sqlite3 "$WV_DB" <<'MIGRATE' 2>/dev/null || true
CREATE TABLE IF NOT EXISTS test_results (
    suite       TEXT    NOT NULL,
    path        TEXT    NOT NULL DEFAULT '',
    fingerprint TEXT    NOT NULL,
    exit_code   INTEGER NOT NULL,
    ran_at      TEXT    NOT NULL DEFAULT (datetime('now')),
    commit_sha  TEXT    NOT NULL DEFAULT '',
    duration_ms INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (suite, path)
);

CREATE INDEX IF NOT EXISTS idx_test_results_suite ON test_results(suite);
MIGRATE

    # An existing path-shape table predating duration_ms (LL1): add the column in
    # place rather than dropping — preserves current-state freshness rows the P6b
    # consumer (file_test_status) reads. ALTER ADD COLUMN with a DEFAULT is cheap.
    local has_duration
    has_duration=$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM pragma_table_info('test_results') WHERE name='duration_ms';" 2>/dev/null || echo "1")
    if [ "$has_duration" = "0" ]; then
        sqlite3 "$WV_DB" "ALTER TABLE test_results ADD COLUMN duration_ms INTEGER NOT NULL DEFAULT 0;" 2>/dev/null || true
    fi
}

# Migrate to add node_files, policy_thresholds, and the done-gate trigger.
# Safe to run repeatedly — CREATE IF NOT EXISTS + INSERT OR IGNORE.
db_migrate_policy_tables() {
    sqlite3 "$WV_DB" <<'MIGRATE' 2>/dev/null || true
CREATE TABLE IF NOT EXISTS node_files (
    node_id TEXT NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
    path    TEXT NOT NULL,
    PRIMARY KEY (node_id, path)
);

CREATE INDEX IF NOT EXISTS idx_node_files_node ON node_files(node_id);

CREATE TABLE IF NOT EXISTS policy_thresholds (
    key   TEXT PRIMARY KEY,
    value REAL NOT NULL
);

INSERT OR IGNORE INTO policy_thresholds(key, value) VALUES ('mccabe_max',    15);
INSERT OR IGNORE INTO policy_thresholds(key, value) VALUES ('mccabe_max_py', 25);
INSERT OR IGNORE INTO policy_thresholds(key, value) VALUES ('mccabe_max_sh', 100);
INSERT OR IGNORE INTO policy_thresholds(key, value) VALUES ('mccabe_max_ts', 15);
INSERT OR IGNORE INTO policy_thresholds(key, value) VALUES ('gini_max', 0.85);
INSERT OR IGNORE INTO policy_thresholds(key, value) VALUES ('trend_deteriorating', 0);

CREATE TABLE IF NOT EXISTS file_metrics (
    path       TEXT PRIMARY KEY,
    mccabe_max INTEGER NOT NULL DEFAULT 0,
    language   TEXT    NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS file_trend (
    path      TEXT PRIMARY KEY,
    direction TEXT NOT NULL DEFAULT 'stable'
);

CREATE TRIGGER IF NOT EXISTS nodes_policy_check
BEFORE UPDATE OF status ON nodes
WHEN NEW.status = 'done' AND OLD.status = 'active'
BEGIN
        SELECT CASE
                WHEN EXISTS (
                        SELECT 1 FROM node_files nf
                        JOIN file_metrics fm ON fm.path = nf.path
                        WHERE nf.node_id = NEW.id
                            AND fm.mccabe_max > COALESCE(
                                (SELECT value FROM policy_thresholds WHERE key = 'mccabe_max_' || fm.language),
                                (SELECT value FROM policy_thresholds WHERE key = 'mccabe_max')
                            )
                ) THEN RAISE(ABORT, 'GraphPolicyViolation: mccabe_max threshold exceeded')
                WHEN EXISTS (
                        SELECT 1 FROM node_files nf
                        JOIN file_trend ft ON ft.path = nf.path
                        WHERE nf.node_id = NEW.id
                            AND ft.direction = 'deteriorating'
                            AND (SELECT value FROM policy_thresholds WHERE key = 'trend_deteriorating') >= 1
                ) THEN RAISE(ABORT, 'GraphPolicyViolation: trend_deteriorating threshold exceeded')
        END;
END;

MIGRATE
    # Add language column to existing DBs — fails silently on new DBs (already in schema).
    sqlite3 "$WV_DB" "ALTER TABLE file_metrics ADD COLUMN language TEXT NOT NULL DEFAULT '';" 2>/dev/null || true
}

# Migrate policy trigger to language-aware COALESCE threshold lookup.
# DROP + CREATE is required — CREATE TRIGGER IF NOT EXISTS does not replace
# existing triggers, so existing DBs loaded before this code landed keep the
# old single-threshold version until this migration runs.
# Also seeds per-language threshold rows (INSERT OR IGNORE — idempotent).
db_migrate_language_trigger() {
    sqlite3 "$WV_DB" <<'MIGRATE' 2>/dev/null || true
INSERT OR IGNORE INTO policy_thresholds(key, value) VALUES ('mccabe_max_py', 25);
INSERT OR IGNORE INTO policy_thresholds(key, value) VALUES ('mccabe_max_sh', 100);
INSERT OR IGNORE INTO policy_thresholds(key, value) VALUES ('mccabe_max_ts', 15);

DROP TRIGGER IF EXISTS nodes_policy_check;

CREATE TRIGGER nodes_policy_check
BEFORE UPDATE OF status ON nodes
WHEN NEW.status = 'done' AND OLD.status = 'active'
BEGIN
        SELECT CASE
                WHEN EXISTS (
                        SELECT 1 FROM node_files nf
                        JOIN file_metrics fm ON fm.path = nf.path
                        WHERE nf.node_id = NEW.id
                            AND fm.mccabe_max > COALESCE(
                                (SELECT value FROM policy_thresholds WHERE key = 'mccabe_max_' || fm.language),
                                (SELECT value FROM policy_thresholds WHERE key = 'mccabe_max')
                            )
                ) THEN RAISE(ABORT, 'GraphPolicyViolation: mccabe_max threshold exceeded')
                WHEN EXISTS (
                        SELECT 1 FROM node_files nf
                        JOIN file_trend ft ON ft.path = nf.path
                        WHERE nf.node_id = NEW.id
                            AND ft.direction = 'deteriorating'
                            AND (SELECT value FROM policy_thresholds WHERE key = 'trend_deteriorating') >= 1
                ) THEN RAISE(ABORT, 'GraphPolicyViolation: trend_deteriorating threshold exceeded')
        END;
END;
MIGRATE
}

# Migrate to add quality_exempt table and update nodes_policy_check trigger to
# respect exempt path patterns. DROP + CREATE required — IF NOT EXISTS does not replace.
db_migrate_quality_exempt() {
    sqlite3 "$WV_DB" <<'MIGRATE' 2>/dev/null || true
CREATE TABLE IF NOT EXISTS quality_exempt (
    path_pattern TEXT PRIMARY KEY,
    reason       TEXT NOT NULL DEFAULT ''
);

DROP TRIGGER IF EXISTS nodes_policy_check;

CREATE TRIGGER nodes_policy_check
BEFORE UPDATE OF status ON nodes
WHEN NEW.status = 'done' AND OLD.status = 'active'
BEGIN
        SELECT CASE
                WHEN EXISTS (
                        SELECT 1 FROM node_files nf
                        JOIN file_metrics fm ON fm.path = nf.path
                        WHERE nf.node_id = NEW.id
                            AND fm.mccabe_max > COALESCE(
                                (SELECT value FROM policy_thresholds WHERE key = 'mccabe_max_' || fm.language),
                                (SELECT value FROM policy_thresholds WHERE key = 'mccabe_max')
                            )
                            AND NOT EXISTS (
                                SELECT 1 FROM quality_exempt qe
                                WHERE nf.path LIKE
                                    CASE WHEN qe.path_pattern LIKE '%/'
                                         THEN qe.path_pattern || '%'
                                         ELSE qe.path_pattern
                                    END
                            )
                ) THEN RAISE(ABORT, 'GraphPolicyViolation: mccabe_max threshold exceeded')
                WHEN EXISTS (
                        SELECT 1 FROM node_files nf
                        JOIN file_trend ft ON ft.path = nf.path
                        WHERE nf.node_id = NEW.id
                            AND ft.direction = 'deteriorating'
                            AND (SELECT value FROM policy_thresholds WHERE key = 'trend_deteriorating') >= 1
                            AND NOT EXISTS (
                                SELECT 1 FROM quality_exempt qe
                                WHERE nf.path LIKE
                                    CASE WHEN qe.path_pattern LIKE '%/'
                                         THEN qe.path_pattern || '%'
                                         ELSE qe.path_pattern
                                    END
                            )
                ) THEN RAISE(ABORT, 'GraphPolicyViolation: trend_deteriorating threshold exceeded')
        END;
END;
MIGRATE
}

# _policy_trigger_sql — SINGLE SOURCE OF TRUTH for the nodes_policy_check trigger.
#
# The trigger had been hand-copied across several migrations (policy_tables,
# language_trigger, quality_exempt); each DROP+CREATE that omitted a clause would
# silently disable a shipped gate. This emitter collapses those copies to one
# definition. New gate clauses are added HERE only, and exactly one migration —
# the latest, db_migrate_test_gate — recreates the trigger from it. Earlier
# migrations' inline copies are harmlessly overwritten because all migrations run
# in sequence on every db_ensure and this one runs last. The invariant that all
# three clauses fire is pinned by test_policy_trigger.
#
# Clauses (all share the quality_exempt guard):
#   1. mccabe_max breach (per-language threshold)            — always active
#   2. trend deteriorating (gated by trend_deteriorating>=1) — off by default
#   3. test red/stale     (gated by test_gate>=2 i.e. block) — off by default
_policy_trigger_sql() {
    cat <<'TRIGGER'
DROP TRIGGER IF EXISTS nodes_policy_check;

CREATE TRIGGER nodes_policy_check
BEFORE UPDATE OF status ON nodes
WHEN NEW.status = 'done' AND OLD.status = 'active'
BEGIN
        SELECT CASE
                WHEN EXISTS (
                        SELECT 1 FROM node_files nf
                        JOIN file_metrics fm ON fm.path = nf.path
                        WHERE nf.node_id = NEW.id
                            AND fm.mccabe_max > COALESCE(
                                (SELECT value FROM policy_thresholds WHERE key = 'mccabe_max_' || fm.language),
                                (SELECT value FROM policy_thresholds WHERE key = 'mccabe_max')
                            )
                            AND NOT EXISTS (
                                SELECT 1 FROM quality_exempt qe
                                WHERE nf.path LIKE
                                    CASE WHEN qe.path_pattern LIKE '%/'
                                         THEN qe.path_pattern || '%'
                                         ELSE qe.path_pattern
                                    END
                            )
                ) THEN RAISE(ABORT, 'GraphPolicyViolation: mccabe_max threshold exceeded')
                WHEN EXISTS (
                        SELECT 1 FROM node_files nf
                        JOIN file_trend ft ON ft.path = nf.path
                        WHERE nf.node_id = NEW.id
                            AND ft.direction = 'deteriorating'
                            AND (SELECT value FROM policy_thresholds WHERE key = 'trend_deteriorating') >= 1
                            AND NOT EXISTS (
                                SELECT 1 FROM quality_exempt qe
                                WHERE nf.path LIKE
                                    CASE WHEN qe.path_pattern LIKE '%/'
                                         THEN qe.path_pattern || '%'
                                         ELSE qe.path_pattern
                                    END
                            )
                ) THEN RAISE(ABORT, 'GraphPolicyViolation: trend_deteriorating threshold exceeded')
                WHEN EXISTS (
                        SELECT 1 FROM node_files nf
                        JOIN file_test_status fts ON fts.path = nf.path
                        WHERE nf.node_id = NEW.id
                            AND fts.state IN ('red', 'stale')
                            AND (SELECT value FROM policy_thresholds WHERE key = 'test_gate') >= 2
                            -- Node-type exemption: non-code nodes are never test-gated,
                            -- even if they accrue node_files. COALESCE so NULL-type
                            -- (legacy/context) nodes are still gated, not exempted.
                            AND COALESCE(json_extract(NEW.metadata, '$.type'), '') NOT IN ('finding', 'epic', 'session_history')
                            AND NOT EXISTS (
                                SELECT 1 FROM quality_exempt qe
                                WHERE nf.path LIKE
                                    CASE WHEN qe.path_pattern LIKE '%/'
                                         THEN qe.path_pattern || '%'
                                         ELSE qe.path_pattern
                                    END
                            )
                ) THEN RAISE(ABORT, 'GraphPolicyViolation: test_gate red/stale result')
        END;
END;
TRIGGER
}

# Migrate to add file_test_status + test_gate threshold and arm the trigger's
# third (test-correctness) clause. Inert by default: test_gate=0 (off). This is
# the authoritative trigger (re)creation — it runs last in db_ensure, so its
# emitter output is the final trigger state for both fresh and existing DBs.
db_migrate_test_gate() {
    sqlite3 "$WV_DB" <<'MIGRATE' 2>/dev/null || true
CREATE TABLE IF NOT EXISTS file_test_status (
    path  TEXT PRIMARY KEY,
    state TEXT NOT NULL DEFAULT 'unknown'
);

INSERT OR IGNORE INTO policy_thresholds(key, value) VALUES ('test_gate', 0);
MIGRATE
    _policy_trigger_sql | sqlite3 "$WV_DB" 2>/dev/null || true
}

# Migrate to add chunks table + FTS5 + sync triggers for semantic search.
# Safe to run repeatedly — CREATE IF NOT EXISTS throughout.
db_migrate_chunks() {
    local fts5_available
    fts5_available=$(sqlite3 "$WV_DB" "SELECT sqlite_compileoption_used('ENABLE_FTS5');" 2>/dev/null || echo "0")

    sqlite3 "$WV_DB" <<'MIGRATE' 2>/dev/null || true
CREATE TABLE IF NOT EXISTS chunks (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    file       TEXT    NOT NULL,
    line_start INTEGER NOT NULL,
    line_end   INTEGER NOT NULL,
    content    TEXT    NOT NULL,
    embedding  BLOB,
    indexed_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_chunks_file ON chunks(file);
MIGRATE

    if [ "$fts5_available" = "1" ]; then
        sqlite3 "$WV_DB" <<'MIGRATE_FTS' 2>/dev/null || true
CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
    content,
    file UNINDEXED,
    line_start UNINDEXED,
    line_end UNINDEXED,
    content=chunks,
    content_rowid=id
);

CREATE TRIGGER IF NOT EXISTS chunks_ai AFTER INSERT ON chunks BEGIN
    INSERT INTO chunks_fts(rowid, content, file, line_start, line_end)
    VALUES (new.id, new.content, new.file, new.line_start, new.line_end);
END;

CREATE TRIGGER IF NOT EXISTS chunks_ad AFTER DELETE ON chunks BEGIN
    INSERT INTO chunks_fts(chunks_fts, rowid, content, file, line_start, line_end)
    VALUES ('delete', old.id, old.content, old.file, old.line_start, old.line_end);
END;

CREATE TRIGGER IF NOT EXISTS chunks_au AFTER UPDATE ON chunks BEGIN
    INSERT INTO chunks_fts(chunks_fts, rowid, content, file, line_start, line_end)
    VALUES ('delete', old.id, old.content, old.file, old.line_start, old.line_end);
    INSERT INTO chunks_fts(rowid, content, file, line_start, line_end)
    VALUES (new.id, new.content, new.file, new.line_start, new.line_end);
END;
MIGRATE_FTS
    fi
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

# Rebuild FTS silently on load (called after importing selective state.sql
# which excludes FTS tables).  Uses the existing migrate + rebuild path.
db_rebuild_fts() {
    db_migrate_fts5
    sqlite3 -cmd ".timeout 5000" "$WV_DB" \
        "INSERT INTO nodes_fts(nodes_fts) VALUES('rebuild');" 2>/dev/null || true
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
                    db_migrate_edge_type_enum
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
            # Delegate to cmd_load: atomic temp-DB import avoids CREATE TABLE
            # conflicts that occur when db_init runs before importing state.sql
            # (SQLite .dump uses plain CREATE TABLE, not CREATE TABLE IF NOT EXISTS)
            echo -e "${YELLOW}Weave database not found at $WV_DB${NC}" >&2
            cmd_load
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

    db_stamp_repo_owner

    local schema_lock="$WV_HOT_ZONE/.schema.lock"
    if command -v flock >/dev/null 2>&1; then
        exec {schema_lock_fd}>"$schema_lock"
        flock -w 10 "$schema_lock_fd" || {
            echo -e "${RED}Error: timed out waiting for Weave schema migration lock${NC}" >&2
            exec {schema_lock_fd}>&-
            return 1
        }
    fi

    db_migrate_edge_type_enum
    db_migrate_policy_tables
    db_migrate_language_trigger
    db_migrate_quality_exempt
    db_migrate_chunks
    db_migrate_fts5_learning
    db_migrate_finding_promoted_at
    db_migrate_test_results
    # MUST run last: re-creates nodes_policy_check from the single-source emitter
    # so the authoritative trigger (incl. the test clause) is the final state.
    db_migrate_test_gate

    if command -v flock >/dev/null 2>&1; then
        flock -u "$schema_lock_fd" 2>/dev/null || true
        exec {schema_lock_fd}>&-
    fi

    # Check DB size once per process-tree — export so pipe subshells inherit the flag.
    # Destructive prune requires explicit opt-in: WV_AUTO_PRUNE=1.
    # WV_DISABLE_AUTOPRUNE=1 kept for backward compat (sync uses it).
    if [ -z "${_WV_SIZE_CHECKED:-}" ] && [ -f "$WV_DB" ] && [ -z "${WV_DISABLE_AUTOPRUNE:-}" ]; then
        export _WV_SIZE_CHECKED=1
        local db_size
        db_size=$(stat -c%s "$WV_DB" 2>/dev/null || stat -f%z "$WV_DB" 2>/dev/null || echo 0)
        if [ "$db_size" -gt "$WV_MAX_DB_SIZE" ] 2>/dev/null; then
            if [ "${WV_AUTO_PRUNE:-0}" != "1" ]; then
                # Warn only — no destructive action without opt-in.
                echo "wv: database is $(( db_size / 1048576 ))MB (limit $(( WV_MAX_DB_SIZE / 1048576 ))MB) — run 'wv prune --age=7d' or set WV_AUTO_PRUNE=1 to auto-prune" >&2
            else
                echo "wv: database is $(( db_size / 1048576 ))MB (limit $(( WV_MAX_DB_SIZE / 1048576 ))MB), auto-pruning..." >&2
                # Inline aggressive prune — archive done nodes >24h.
                # Dedup: skip IDs already in today's archive file.
                local archive_dir="$WEAVE_DIR/archive"
                mkdir -p "$archive_dir"
                local archive_file="$archive_dir/$(date +%Y-%m-%d).jsonl"
                local already_archived=""
                if [ -f "$archive_file" ]; then
                    already_archived=$(jq -r '.id' "$archive_file" 2>/dev/null | sort -u | tr '\n' ',' | sed 's/,$//')
                fi
                local exclude_clause=""
                if [ -n "$already_archived" ]; then
                    exclude_clause=" AND id NOT IN ($(echo "$already_archived" | sed "s/,/','/g; s/^/'/; s/$/'/"  ))"
                fi
                sqlite3 -json "$WV_DB" "SELECT * FROM nodes WHERE status='done' AND updated_at < datetime('now', '-24 hours')${exclude_clause}" 2>/dev/null \
                    | jq -c '.[]' >> "$archive_file" 2>/dev/null || true
                sqlite3 "$WV_DB" ".timeout 5000
                    DELETE FROM edges WHERE source IN (SELECT id FROM nodes WHERE status='done' AND updated_at < datetime('now', '-24 hours'))
                       OR target IN (SELECT id FROM nodes WHERE status='done' AND updated_at < datetime('now', '-24 hours'));
                    DELETE FROM node_files WHERE node_id IN (SELECT id FROM nodes WHERE status='done' AND updated_at < datetime('now', '-24 hours'));
                    DELETE FROM nodes WHERE status='done' AND updated_at < datetime('now', '-24 hours');
                    VACUUM;
                " 2>/dev/null
                local _prune_rc=$?
                if [ "$_prune_rc" -ne 0 ]; then
                    echo "wv: auto-prune failed (database locked?)" >&2
                fi
                # If DB still over cap, only evict chunks if doing so would actually bring it under limit.
                # Chunks are a re-creatable index but evicting them when graph itself is the bloat is
                # pointless — it destroys search without freeing enough space.
                local db_size_after
                db_size_after=$(stat -c%s "$WV_DB" 2>/dev/null || stat -f%z "$WV_DB" 2>/dev/null || echo 0)
                if [ "$db_size_after" -gt "$WV_MAX_DB_SIZE" ] 2>/dev/null; then
                    local chunks_bytes
                    chunks_bytes=$(sqlite3 "$WV_DB" ".timeout 5000
                        SELECT COALESCE(SUM(length(content) + COALESCE(length(embedding), 0) + 50), 0) FROM chunks;" 2>/dev/null || echo 0)
                    if [ "$(( db_size_after - chunks_bytes ))" -le "$WV_MAX_DB_SIZE" ] 2>/dev/null; then
                        echo "wv: node prune insufficient ($(( db_size_after / 1048576 ))MB), evicting chunks index..." >&2
                        sqlite3 "$WV_DB" ".timeout 5000
                            DELETE FROM chunks;
                            INSERT INTO chunks_fts(chunks_fts) VALUES('rebuild');
                            VACUUM;
                        " 2>/dev/null || echo "wv: chunks eviction failed (database locked?)" >&2
                        echo "wv: chunks index evicted — re-run wv index to restore search" >&2
                    else
                        echo "wv: database over limit ($(( db_size_after / 1048576 ))MB) — run 'wv prune --age=7d' to free space" >&2
                    fi
                fi
                # Clear entire context cache after auto-prune (can't track specific affected nodes)
                rm -rf "$WV_HOT_ZONE/context_cache" 2>/dev/null || true
                echo "wv: context cache cleared after auto-prune" >&2
            fi
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

# db_query_json_v2 — lean JSON shape for --json-v2 flag:
#   - metadata promoted from escaped string to nested object
#   - created_at / updated_at omitted
#   - null/empty fields omitted
db_query_json_v2() {
    db_ensure
    local raw
    raw=$(sqlite3 -json -cmd ".timeout 5000" "$WV_DB" "$1") || return $?
    [ -z "$raw" ] && echo "[]" && return
    echo "$raw" | jq '[.[] | . + (
        if .metadata and (.metadata | type) == "string"
        then {metadata: (.metadata | fromjson? // {})}
        else {}
        end
    ) | del(.created_at, .updated_at)
      | with_entries(select(.value != null and .value != ""))]'
}
