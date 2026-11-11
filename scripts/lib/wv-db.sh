#!/bin/bash
# wv-db.sh — Database initialization, migrations, queries
#
# Sourced by: wv entry point (after wv-config.sh)
# Dependencies: wv-config.sh (for WV_DB, WV_HOT_ZONE, WEAVE_DIR, etc.)

# ═══════════════════════════════════════════════════════════════════════════
# Database Initialization
# ═══════════════════════════════════════════════════════════════════════════

# db_stamp_repo_owner <repo> — record <repo> as the hot zone's owning
# repository in .repo_root. db_ensure passes REPO_ROOT; wv init passes the
# owner it can name (wv-29e416).
db_stamp_repo_owner() {
    local repo="${1:-}"
    [ -n "$repo" ] || return 0
    [ -n "${WV_HOT_ZONE:-}" ] || return 0

    local owner_file canonical_repo_root
    owner_file=$(resolve_hot_zone_owner_file "$WV_HOT_ZONE")
    [ -n "$owner_file" ] || return 0

    canonical_repo_root=$(canonicalize_runtime_path "$repo")
    hot_zone_ensure "$WV_HOT_ZONE" || return 0
    # .gate_pool (wv-7061a0): the commit gate's suite pool that ran this wv,
    # so a pool's leak guard can tell a zone its own suites made in the live
    # root from a sibling pool's. Written before .repo_root: the guard judges
    # a zone only once .repo_root exists, and must then find the tag.
    if [ -n "${WV_GATE_POOL_TAG:-}" ]; then
        printf '%s\n' "$WV_GATE_POOL_TAG" > "${owner_file%/*}/.gate_pool" 2>/dev/null || true
    fi
    printf '%s\n' "$canonical_repo_root" > "$owner_file" 2>/dev/null || true
    chmod 600 "$owner_file" 2>/dev/null || true
}

db_init() {
    # Security: hot zone may be under /dev/shm or /tmp (shared-mount parents).
    # Create 700/600 so other local users cannot read the graph. `umask 077`
    # covers the DB file; explicit chmod covers existing dirs that predate
    # this change. See security review L5 (2026-04-19). hot_zone_ensure
    # refuses a base another user could control, and never chmods one; the
    # chmod below touches only the per-repo leaf, which a verified base
    # guarantees is ours (wv-80be32).
    #
    # Do not create $WEAVE_DIR here. db_init backs both explicit initialization
    # and read-ish paths like `wv health`, `wv status`, and session-start
    # hooks. Auto-creating the repo's .weave directory here would opt
    # uninitialized repositories into Weave just by inspecting them.
    local prev_umask
    prev_umask=$(umask)
    umask 077
    if ! hot_zone_ensure "$WV_HOT_ZONE"; then
        umask "$prev_umask"
        return 1
    fi
    chmod 700 "$WV_HOT_ZONE" 2>/dev/null || true
    umask "$prev_umask"
    validate_hot_size
    # A fresh file may reuse a removed file's inode: its schema stamp is not
    # evidence of anything (wv-048429).
    rm -f "$WV_DB.ensured" 2>/dev/null || true

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
-- Uses porter stemmer + unicode for better search quality. alias is indexed
-- so an exact alias finds its node even when no alias word is in the text
-- (wv-92b72c); db_migrate_fts5 upgrades a three-column index in place.
CREATE VIRTUAL TABLE IF NOT EXISTS nodes_fts USING fts5(
    id, text, metadata, alias,
    content=nodes,
    content_rowid=rowid,
    tokenize='porter unicode61'
);

-- Keep FTS in sync with nodes table
CREATE TRIGGER IF NOT EXISTS nodes_ai AFTER INSERT ON nodes BEGIN
    INSERT INTO nodes_fts(rowid, id, text, metadata, alias)
    VALUES (new.rowid, new.id, new.text, new.metadata, new.alias);
END;

CREATE TRIGGER IF NOT EXISTS nodes_ad AFTER DELETE ON nodes BEGIN
    INSERT INTO nodes_fts(nodes_fts, rowid, id, text, metadata, alias)
    VALUES ('delete', old.rowid, old.id, old.text, old.metadata, old.alias);
END;

CREATE TRIGGER IF NOT EXISTS nodes_au AFTER UPDATE ON nodes BEGIN
    INSERT INTO nodes_fts(nodes_fts, rowid, id, text, metadata, alias)
    VALUES ('delete', old.rowid, old.id, old.text, old.metadata, old.alias);
    INSERT INTO nodes_fts(rowid, id, text, metadata, alias)
    VALUES (new.rowid, new.id, new.text, new.metadata, new.alias);
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

-- quality_config_sig: which .weave/quality.conf the two tables above were
-- projected from. It lives HERE, inside the database it describes, so the memo
-- and the projection share one lifetime and cannot disagree.
--
-- wv-785ba1: the signature used to be a file beside the DB
-- ($WV_HOT_ZONE/.quality_conf_sig), on the reasoning that "a rebuilt brain.db
-- loses it and reloads". A sibling file survives the database. A hot zone whose
-- brain.db was rebuilt kept a stamp asserting freshness over an empty
-- quality_exempt, so wv done hard-blocked on a path quality.conf had explicitly
-- exempted -- the same false GraphPolicyViolation wv-6657dd set out to prevent,
-- reached by losing the table instead of by editing the file. Dropping the DB
-- now drops the claim about it.
CREATE TABLE IF NOT EXISTS quality_config_sig (
    id        INTEGER PRIMARY KEY CHECK (id = 1),
    signature TEXT NOT NULL
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

EOF
    # The close-policy trigger (nodes_policy_check) is created only from its
    # single-source emitter, so a fresh DB has the complete trigger immediately
    # rather than after the next db_ensure migration pass. (The heredoc above is
    # an unquoted <<EOF — it cannot call a function mid-body, hence this follow-up.)
    _policy_trigger_sql | sqlite3 "$WV_DB" 2>/dev/null || true
    # The heredoc's own status is not the test: on a SQLite without FTS5 its FTS
    # statements fail while the rest succeeds. What must hold is a database that
    # opens and has the core table (wv-b98794).
    if ! sqlite3 -cmd ".timeout 5000" "$WV_DB" "SELECT COUNT(*) FROM nodes;" >/dev/null 2>&1; then
        echo "wv: could not create the Weave database at $WV_DB" >&2
        return 1
    fi
    # Writer lineage lives in a migration rather than the schema heredoc above so
    # that a fresh database and a migrated one produce identical CREATE TABLE
    # text — see db_migrate_lineage for why that matters to state.sql.
    #
    # Propagated explicitly rather than left to `set -e`: a database initialised
    # without the lineage columns cannot sync, and a caller that runs with -e
    # disabled would otherwise carry on with one that reported failure.
    db_migrate_lineage || return 1
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
#
# The rebuild below recreates edges from a hardcoded CREATE TABLE carrying only
# the six columns db_init declares. The writer-lineage pair is NOT declared
# there — db_migrate_lineage appends it with ALTER TABLE — so on a database that
# predates the resolves CHECK but has already been lineage-migrated, the rebuild
# dropped lineage_actor and lineage_seq from edges and left the pair verdict at
# 'repairable', where sync and commit-refs cannot persist (wv-419ba1).
#
# Nothing repaired it inside that process: db_ensure runs db_migrate_lineage
# BEFORE this function, and the pre-v1.2 hot-zone migration call site never runs
# the lineage migration at all. A later db_ensure does repair it, which is why
# this is latent rather than a permanent outage, and why it was never confirmed
# as the trigger for the consumer loss report.
#
# The columns are restored by calling db_migrate_lineage, not by declaring them
# in the CREATE TABLE above: sqlite stores the statement text verbatim and
# state.sql is byte-compared by the auto_sync no-op guard, so a hand-written
# equivalent differing by one space would churn every sync forever. Values are
# carried across explicitly, because the restore appends columns at their
# defaults and a legacy database's lineage bookkeeping is real data.
db_migrate_edge_type_enum() {
    db_migrate_edges

    local edges_sql
    edges_sql=$(sqlite3 "$WV_DB" "SELECT sql FROM sqlite_master WHERE type='table' AND name='edges';" 2>/dev/null || true)
    if [[ "$edges_sql" == *"'resolves'"* ]]; then
        return 0
    fi

    # Snapshot the lineage pair before the rebuild destroys it. Only a canonical
    # pair is carried across; a partial or reversed shape has no values worth
    # preserving and db_migrate_lineage repairs what it can afterwards. The
    # backup is dropped unconditionally below — a survivor would land in
    # state.sql and become part of the portable graph.
    local _edge_lineage_carry=0
    if [ "$(db_lineage_shape edges)" = "canonical" ]; then
        _edge_lineage_carry=1
    fi
    sqlite3 "$WV_DB" "DROP TABLE IF EXISTS _wv_edges_lineage_carry;" 2>/dev/null || true
    if [ "$_edge_lineage_carry" = "1" ]; then
        sqlite3 "$WV_DB" "CREATE TABLE _wv_edges_lineage_carry AS
            SELECT source, target, type, lineage_actor, lineage_seq FROM edges;" 2>/dev/null \
            || _edge_lineage_carry=0
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

    # Re-append the writer-lineage pair through the canonical ALTER TABLE path,
    # so the stored CREATE TABLE text is byte-identical to a normally-migrated
    # database. Unconditional and idempotent: it is a no-op when the pair is
    # already canonical, and repairs nodes too if that is what it finds.
    db_migrate_lineage || {
        sqlite3 "$WV_DB" "DROP TABLE IF EXISTS _wv_edges_lineage_carry;" 2>/dev/null || true
        return 1
    }

    if [ "$_edge_lineage_carry" = "1" ]; then
        sqlite3 "$WV_DB" "
UPDATE edges SET
    lineage_actor = COALESCE((SELECT c.lineage_actor FROM _wv_edges_lineage_carry c
                              WHERE c.source = edges.source AND c.target = edges.target
                                AND c.type = edges.type), lineage_actor),
    lineage_seq   = COALESCE((SELECT c.lineage_seq   FROM _wv_edges_lineage_carry c
                              WHERE c.source = edges.source AND c.target = edges.target
                                AND c.type = edges.type), lineage_seq);" 2>/dev/null || true
    fi
    sqlite3 "$WV_DB" "DROP TABLE IF EXISTS _wv_edges_lineage_carry;" 2>/dev/null || true
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

# Writer lineage lives in scripts/lib/wv-db-lineage.sh: db_lineage_shape,
# db_lineage_pair_verdict, db_migrate_lineage and their helpers. wv doctor
# consults the same classifier, so it is a module rather than a section here.
# Located from this file rather than from $WV_LIB_DIR: tests source wv-db.sh
# directly, without wv-config.sh, and a module that only resolves under the full
# entry point is a module the suites cannot reach.
_WV_DB_SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_WV_DB_SRC_DIR/wv-db-lineage.sh"

# db_tombstone_sql KIND ID [LINEAGE_SEQ] [LINEAGE_ACTOR] — SQL for a cross-machine
# deletion tombstone (epic delta-causality, wv-0d5e07). Called by wv delete and
# wv prune in place of the machine-local .weave/.prune_epoch. KIND is 'node' or
# 'edge'; ID is the node id, or the "source:target:type" identity for an edge
# (the join key wv-delta-v2-replay.py::_apply_delete also tombstones on).
#
# (LINEAGE_SEQ, LINEAGE_ACTOR) is the deleted row's own lineage at delete time —
# the highest lineage that row can carry — so any delta that later replays its
# creation or an earlier patch lands at or below the tombstone and
# _reconcile_tombstones (and the v1 replay guard) removes it, while a recreate
# stamped after the delete carries a strictly greater lineage and survives. Both
# compare (seq, actor) tuples, so the actor must be the ROW's: the deleting
# agent's actor beside the row's seq let a row whose actor sorts after it outrank
# its own tombstone (wv-f01b33). Callers pass the deleter's actor only for a row
# that carried none. Omitted args fall to the pre-cutover floor (0, ''). ON
# CONFLICT keeps the higher (seq, actor) so a re-delete never regresses an
# existing tombstone.
db_tombstone_sql() {
    local kind="$1" ident="$2" lseq="${3:-0}" lactor="${4:-}"
    [ "$kind" = "node" ] || [ "$kind" = "edge" ] || return 1
    [ -n "$ident" ] || return 1
    [[ "$lseq" =~ ^[0-9]+$ ]] || lseq=0
    local esc_id esc_actor
    if command -v sql_escape >/dev/null 2>&1; then
        esc_id=$(sql_escape "$ident"); esc_actor=$(sql_escape "$lactor")
    else
        esc_id=${ident//\'/\'\'}; esc_actor=${lactor//\'/\'\'}
    fi
    printf '%s\n' "INSERT INTO tombstones(kind, id, lineage_seq, lineage_actor)
        VALUES ('$kind', '$esc_id', $lseq, '$esc_actor')
        ON CONFLICT(kind, id) DO UPDATE SET
            lineage_seq = excluded.lineage_seq,
            lineage_actor = excluded.lineage_actor
        WHERE (excluded.lineage_seq, excluded.lineage_actor)
            > (tombstones.lineage_seq, tombstones.lineage_actor);"
}

db_write_tombstone() {
    local sql
    sql=$(db_tombstone_sql "$@") || return 1
    db_query "$sql"
}

# db_capture_tombstones NODE_ID — print the tombstones a removal of NODE_ID must
# write, one "kind<TAB>ident<TAB>lineage_seq" line for the node and one per
# incident edge. Run it BEFORE the DELETEs: each line carries the highest lineage
# that row held. The one capture shared by wv delete and wv prune (wv-99c85a),
# so a change to tombstone semantics cannot reach only one of them and reopen
# wv-0d5e07's resurrection bug.
db_capture_tombstones() {
    local node_id="$1" esc seq es et ety eseq edges
    [ -n "$node_id" ] || return 1
    if command -v sql_escape >/dev/null 2>&1; then esc=$(sql_escape "$node_id"); else esc=${node_id//\'/\'\'}; fi
    # The row's own (seq, actor): reconcile and replay compare (seq, actor)
    # tuples, so stamping the deleter's actor beside the row's seq let a row
    # whose actor sorts after the deleter's outrank its own tombstone
    # (wv-f01b33). The tab-separated lines carry the actor as a fourth column.
    local row nactor eactor
    row=$(db_query "SELECT COALESCE(lineage_seq,0) || char(9) || COALESCE(lineage_actor,'') FROM nodes WHERE id='$esc';") || return 1
    IFS=$'\t' read -r seq nactor <<< "$row"
    edges=$(db_query "SELECT source, target, type, COALESCE(lineage_seq,0), COALESCE(lineage_actor,'') FROM edges WHERE source='$esc' OR target='$esc';") || return 1
    printf 'node\t%s\t%s\t%s\n' "$node_id" "${seq:-0}" "${nactor:-}"
    while IFS='|' read -r es et ety eseq eactor; do
        [ -n "$es" ] || continue
        printf 'edge\t%s:%s:%s\t%s\t%s\n' "$es" "$et" "$ety" "${eseq:-0}" "${eactor:-}"
    done <<< "$edges"
}

# Build tombstone statements so a removal can commit them in its own transaction.
db_tombstones_sql() {
    local actor="$1" kind ident seq row_actor
    while IFS=$'\t' read -r kind ident seq row_actor; do
        [ -n "$kind" ] || continue
        # The row's own actor when captured (wv-f01b33); ACTOR only for a row
        # that carried none.
        db_tombstone_sql "$kind" "$ident" "${seq:-0}" "${row_actor:-$actor}" || return 1
    done
}

# db_write_tombstones ACTOR — write db_capture_tombstones output from stdin.
db_write_tombstones() {
    local sql
    sql=$(db_tombstones_sql "$1") || return 1
    db_query "$sql"
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

    # wv-92b72c: an index built before alias joined it has three columns, and
    # CREATE ... IF NOT EXISTS below would keep it -- and would keep three-column
    # sync triggers too, even over a table dropped and recreated with four,
    # whose 'delete' then omits alias and corrupts the external-content index.
    # Shape digits: table present, alias column present, stale triggers.
    # Stale when the table lacks alias ("10?") or any sync trigger does
    # ("??N", N>0). Drop table and triggers and let the CREATE below build the
    # current form, all in one transaction, then rebuild: the index is
    # external-content over nodes, so nothing is lost and no write slips
    # between a dropped trigger and its replacement.
    local fts_shape fts_begin="" fts_commit="" fts_rebuild="" fts_bail=""
    fts_shape=$(sqlite3 "$WV_DB" "SELECT (SELECT COUNT(*) FROM sqlite_master WHERE name='nodes_fts')
        || (SELECT COUNT(*) FROM pragma_table_info('nodes_fts') WHERE name='alias')
        || (SELECT COUNT(*) FROM sqlite_master WHERE type='trigger'
            AND name IN ('nodes_ai','nodes_ad','nodes_au') AND sql NOT LIKE '%alias%');" 2>/dev/null || echo "")
    if [[ "$fts_shape" == 10? ]] || [[ "$fts_shape" =~ ^..[1-9] ]]; then
        fts_begin="BEGIN IMMEDIATE;
DROP TRIGGER IF EXISTS nodes_ai;
DROP TRIGGER IF EXISTS nodes_ad;
DROP TRIGGER IF EXISTS nodes_au;
DROP TABLE IF EXISTS nodes_fts;"
        fts_rebuild="INSERT INTO nodes_fts(nodes_fts) VALUES('rebuild');"
        fts_commit="COMMIT;"
        # The CLI runs on past a failed statement, so a failed CREATE would
        # still reach COMMIT with the old index dropped. -bail stops at the
        # error and the open transaction rolls back on exit.
        fts_bail="-bail"
    fi

    # Create FTS5 table and triggers if they don't exist
    # shellcheck disable=SC2086  # $fts_bail is empty or one flag
    sqlite3 $fts_bail "$WV_DB" <<MIGRATE 2>/dev/null || true
$fts_begin
-- FTS5 full-text search index
CREATE VIRTUAL TABLE IF NOT EXISTS nodes_fts USING fts5(
    id, text, metadata, alias,
    content=nodes,
    content_rowid=rowid,
    tokenize='porter unicode61'
);

-- Keep FTS in sync with nodes table
CREATE TRIGGER IF NOT EXISTS nodes_ai AFTER INSERT ON nodes BEGIN
    INSERT INTO nodes_fts(rowid, id, text, metadata, alias)
    VALUES (new.rowid, new.id, new.text, new.metadata, new.alias);
END;

CREATE TRIGGER IF NOT EXISTS nodes_ad AFTER DELETE ON nodes BEGIN
    INSERT INTO nodes_fts(nodes_fts, rowid, id, text, metadata, alias)
    VALUES ('delete', old.rowid, old.id, old.text, old.metadata, old.alias);
END;

CREATE TRIGGER IF NOT EXISTS nodes_au AFTER UPDATE ON nodes BEGIN
    INSERT INTO nodes_fts(nodes_fts, rowid, id, text, metadata, alias)
    VALUES ('delete', old.rowid, old.id, old.text, old.metadata, old.alias);
    INSERT INTO nodes_fts(rowid, id, text, metadata, alias)
    VALUES (new.rowid, new.id, new.text, new.metadata, new.alias);
END;
$fts_rebuild
$fts_commit
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
WHERE COALESCE(json_extract(metadata, '$.node_kind'), json_extract(metadata, '$.type')) = 'finding'
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
MIGRATE
    # Add language column to existing DBs — fails silently on new DBs (already in schema).
    sqlite3 "$WV_DB" "ALTER TABLE file_metrics ADD COLUMN language TEXT NOT NULL DEFAULT '';" 2>/dev/null || true
}

# Seed the per-language McCabe threshold rows (INSERT OR IGNORE — idempotent).
# The language-aware trigger clause itself comes from _policy_trigger_sql.
db_migrate_language_trigger() {
    sqlite3 "$WV_DB" <<'MIGRATE' 2>/dev/null || true
INSERT OR IGNORE INTO policy_thresholds(key, value) VALUES ('mccabe_max_py', 25);
INSERT OR IGNORE INTO policy_thresholds(key, value) VALUES ('mccabe_max_sh', 100);
INSERT OR IGNORE INTO policy_thresholds(key, value) VALUES ('mccabe_max_ts', 15);
MIGRATE
}

# Migrate to add the quality_exempt table. The trigger's exempt guard comes
# from _policy_trigger_sql, which db_migrate_test_gate applies last.
db_migrate_quality_exempt() {
    sqlite3 "$WV_DB" <<'MIGRATE' 2>/dev/null || true
CREATE TABLE IF NOT EXISTS quality_exempt (
    path_pattern TEXT PRIMARY KEY,
    reason       TEXT NOT NULL DEFAULT ''
);

-- quality_config_sig: which .weave/quality.conf the two tables above were
-- projected from. It lives HERE, inside the database it describes, so the memo
-- and the projection share one lifetime and cannot disagree.
--
-- wv-785ba1: the signature used to be a file beside the DB
-- ($WV_HOT_ZONE/.quality_conf_sig), on the reasoning that "a rebuilt brain.db
-- loses it and reloads". A sibling file survives the database. A hot zone whose
-- brain.db was rebuilt kept a stamp asserting freshness over an empty
-- quality_exempt, so wv done hard-blocked on a path quality.conf had explicitly
-- exempted -- the same false GraphPolicyViolation wv-6657dd set out to prevent,
-- reached by losing the table instead of by editing the file. Dropping the DB
-- now drops the claim about it.
CREATE TABLE IF NOT EXISTS quality_config_sig (
    id        INTEGER PRIMARY KEY CHECK (id = 1),
    signature TEXT NOT NULL
);
MIGRATE
}

# Close-policy clauses — SINGLE SOURCE OF TRUTH for both the nodes_policy_check
# trigger and the close receipt (_policy_close_receipt_sql).
#
# Each fragment is written against NEW and OLD. Inside the trigger those are the
# row images; in the receipt they are CTEs holding the same images (the proposed
# metadata and the current row), so both evaluate literally the same text. The
# trigger had been hand-copied across several migrations, and a DROP+CREATE that
# omitted a clause silently disabled a shipped gate; a verdict reconstructed by
# re-running similar queries after the abort drifted the same way (wv-d7cd88).
#
# Clauses, in the order both consumers evaluate them:
#   0. completion scope integrity                            — only with --completion-files
#   1. mccabe_max breach (per-language threshold)            — always active
#   2. trend deteriorating (gated by trend_deteriorating>=1) — off by default
#   3. test red/stale     (gated by test_gate>=2 i.e. block) — off by default
# Clauses 1-3 share the completion-scope filter and the quality_exempt guard.

# Clause 0 splits three ways so the receipt can say which: a scope with no usable
# shape (input validation), one without a fresh attempt identity, and one naming
# a file the node never touched.
_policy_scope_malformed_sql() {
    cat <<'SQL'
json_type(NEW.metadata, '$.completion_scope.files') != 'array'
                         OR json_array_length(NEW.metadata, '$.completion_scope.files') = 0
                         OR EXISTS (
                             SELECT 1 FROM json_each(NEW.metadata, '$.completion_scope.files') scoped
                             WHERE scoped.type != 'text' OR scoped.value = '')
SQL
}

_policy_scope_stale_attempt_sql() {
    cat <<'SQL'
COALESCE(json_extract(NEW.metadata, '$.completion_scope.attempt_id'), '') = ''
                         OR json_extract(NEW.metadata, '$.completion_scope.attempt_id') IS json_extract(OLD.metadata, '$.completion_scope.attempt_id')
SQL
}

_policy_scope_unattributed_sql() {
    cat <<'SQL'
EXISTS (
                             SELECT 1 FROM json_each(NEW.metadata, '$.completion_scope.files') scoped
                             WHERE NOT EXISTS (SELECT 1 FROM node_files nf WHERE nf.node_id=NEW.id AND nf.path=scoped.value))
SQL
}

_policy_scope_invalid_sql() {
    cat <<SQL
json_type(NEW.metadata, '\$.completion_scope.files') IS NOT NULL
                     AND (($(_policy_scope_malformed_sql))
                          OR ($(_policy_scope_stale_attempt_sql))
                          OR $(_policy_scope_unattributed_sql))
SQL
}

# Whether quality_exempt pattern qe covers the node file nf. A pattern ending in
# / is a directory prefix.
_policy_exempt_match_sql() {
    cat <<'SQL'
nf.path LIKE
                                    CASE WHEN qe.path_pattern LIKE '%/'
                                         THEN qe.path_pattern || '%'
                                         ELSE qe.path_pattern
                                    END
SQL
}

# The filter and guard clauses 1-3 share: only files inside the completion scope
# (when one is set), and never a path quality_exempt covers. With "exempt" the
# guard inverts to only the paths quality_exempt covers: the breaches the
# exemption let through, which the close records as its bypass (wv-ef00f7).
_policy_file_guard_sql() {
    local exists="NOT EXISTS"
    [ "${1:-}" = "exempt" ] && exists="EXISTS"
    cat <<SQL
AND (json_type(NEW.metadata, '\$.completion_scope.files') IS NULL
                                 OR nf.path IN (SELECT value FROM json_each(NEW.metadata, '\$.completion_scope.files')))
                            AND $exists (
                                SELECT 1 FROM quality_exempt qe
                                WHERE $(_policy_exempt_match_sql)
                            )
SQL
}

_policy_mccabe_limit_sql() {
    echo "COALESCE((SELECT value FROM policy_thresholds WHERE key = 'mccabe_max_' || fm.language), (SELECT value FROM policy_thresholds WHERE key = 'mccabe_max'))"
}

# _policy_file_mccabe <quality_db> <scan_id> <path> — "<cc> <language>": the
# file's largest function complexity in that quality scan and the language
# that picks its limit, as wv done writes them into file_metrics for the
# mccabe clause. scripts/gate-preflight.sh reads the same pair (wv-b7fdee).
_policy_file_mccabe() {
    local path_esc lang val
    path_esc=$(printf '%s' "$3" | sed "s/'/''/g")
    case "$3" in
        *.py)       lang="py" ;;
        *.sh)       lang="sh" ;;
        *.ts|*.tsx) lang="ts" ;;
        *)          lang=""   ;;
    esac
    val=$(sqlite3 -batch -cmd ".timeout 3000" "$1" \
        "SELECT COALESCE(CAST(MAX(value) AS INTEGER), 0) FROM file_metrics WHERE path='$path_esc' AND scan_id=$2 AND metric LIKE 'fn_cc:%';" 2>/dev/null) || val=""
    printf '%s %s\n' "${val:-0}" "$lang"
}

# Row sources: FROM ... WHERE for the files that breach each clause. An
# optional "exempt" selects the breaching files quality_exempt covers instead.
_policy_mccabe_rows_sql() {
    cat <<SQL
FROM node_files nf
                        JOIN file_metrics fm ON fm.path = nf.path
                        WHERE nf.node_id = NEW.id
                            AND fm.mccabe_max > $(_policy_mccabe_limit_sql)
                            $(_policy_file_guard_sql "${1:-}")
SQL
}

_policy_trend_rows_sql() {
    cat <<SQL
FROM node_files nf
                        JOIN file_trend ft ON ft.path = nf.path
                        WHERE nf.node_id = NEW.id
                            AND ft.direction = 'deteriorating'
                            AND (SELECT value FROM policy_thresholds WHERE key = 'trend_deteriorating') >= 1
                            $(_policy_file_guard_sql "${1:-}")
SQL
}

# Node-type exemption: non-code nodes are never test-gated, even if they accrue
# node_files. COALESCE so NULL-type (legacy/context) nodes are still gated.
_policy_test_rows_sql() {
    cat <<SQL
FROM node_files nf
                        JOIN file_test_status fts ON fts.path = nf.path
                        WHERE nf.node_id = NEW.id
                            AND fts.state IN ('red', 'stale')
                            AND (SELECT value FROM policy_thresholds WHERE key = 'test_gate') >= 2
                            AND COALESCE(json_extract(NEW.metadata, '\$.node_kind'), json_extract(NEW.metadata, '\$.type'), '') NOT IN ('finding', 'epic', 'session_history')
                            $(_policy_file_guard_sql "${1:-}")
SQL
}

# _policy_trigger_sql — the nodes_policy_check trigger, assembled from the clause
# fragments above. Exactly one migration, the latest (db_migrate_test_gate),
# applies it, and db_init applies it for a fresh DB. The trigger is the backstop:
# cmd_done decides from the receipt first and never issues a close the receipt
# denies, so the trigger firing on a cmd_done close means the two disagreed.
_policy_trigger_sql() {
    cat <<TRIGGER
DROP TRIGGER IF EXISTS nodes_policy_check;

CREATE TRIGGER nodes_policy_check
BEFORE UPDATE OF status ON nodes
WHEN NEW.status = 'done' AND OLD.status = 'active'
BEGIN
        SELECT CASE
                WHEN $(_policy_scope_invalid_sql)
                     THEN RAISE(ABORT, 'GraphPolicyViolation: invalid completion scope')
                WHEN EXISTS (SELECT 1 $(_policy_mccabe_rows_sql)
                ) THEN RAISE(ABORT, 'GraphPolicyViolation: mccabe_max threshold exceeded')
                WHEN EXISTS (SELECT 1 $(_policy_trend_rows_sql)
                ) THEN RAISE(ABORT, 'GraphPolicyViolation: trend_deteriorating threshold exceeded')
                WHEN EXISTS (SELECT 1 $(_policy_test_rows_sql)
                ) THEN RAISE(ABORT, 'GraphPolicyViolation: test_gate red/stale result')
        END;
END;
TRIGGER
}

# The values each clause decides on, as the receipt records them. Evaluated
# over one breaching row of that clause's row source (nf, fm/ft/fts).
_policy_mccabe_clause_sql() {
    cat <<SQL
json_object(
            'threshold', CASE WHEN EXISTS (SELECT 1 FROM policy_thresholds WHERE key = 'mccabe_max_' || fm.language)
                              THEN 'mccabe_max_' || fm.language ELSE 'mccabe_max' END,
            'limit', $(_policy_mccabe_limit_sql), 'actual', fm.mccabe_max, 'path', nf.path)
SQL
}

_policy_trend_clause_sql() {
    cat <<'SQL'
json_object(
            'threshold', 'trend_deteriorating',
            'limit', (SELECT value FROM policy_thresholds WHERE key = 'trend_deteriorating'),
            'actual', 1, 'path', nf.path, 'direction', ft.direction)
SQL
}

_policy_test_clause_sql() {
    cat <<'SQL'
json_object(
            'threshold', 'test_gate',
            'limit', (SELECT value FROM policy_thresholds WHERE key = 'test_gate'),
            'actual', 1, 'path', nf.path, 'state', fts.state)
SQL
}

# _policy_close_receipt_sql <escaped-node-id> <proposed-metadata-expr>
#
# One SELECT yielding the close receipt: NULL when every clause allows, else the
# first denying clause as {"rule", "decision", "clause": {...}} — the rule is a
# contracts/policy-rules-v1.json rule_id and clause carries the values the
# decision was made on (threshold key, limit, actual, path, state or direction).
# The receipt is the decision, not a diagnosis of one: cmd_done evaluates it in
# the same write transaction as the close and guards the UPDATE on it, so it
# names exactly the state the close was judged against. A non-Bash owner of the
# transaction produces the same receipt from the same clauses; nothing parses
# the trigger's error text. The proposed-metadata expression is evaluated
# against the current row, as the UPDATE would evaluate it. Like the trigger's
# WHEN, it judges only an active->done close: a todo or blocked node closed
# directly is not gated, and a receipt that denied it would be stricter than
# the backstop it is meant to agree with.
_policy_close_receipt_sql() {
    local id="$1" proposed="$2"
    cat <<SQL
WITH "NEW"(id, metadata) AS (SELECT id, $proposed FROM nodes WHERE id = '$id'),
     "OLD"(id, metadata, status) AS (SELECT id, metadata, status FROM nodes WHERE id = '$id')
SELECT COALESCE(
    CASE WHEN $(_policy_scope_invalid_sql) THEN json_object(
        'rule', 'completion_scope_integrity', 'decision', 'deny',
        'clause', json_object('threshold', 'completion_scope', 'reason',
            CASE WHEN $(_policy_scope_malformed_sql) THEN 'malformed_scope'
                 WHEN $(_policy_scope_stale_attempt_sql) THEN 'stale_attempt'
                 ELSE 'unattributed_file' END))
    END,
    (SELECT json_object(
        'rule', 'close_complexity_ceiling', 'decision', 'deny', 'clause', $(_policy_mccabe_clause_sql))
     $(_policy_mccabe_rows_sql)
     ORDER BY nf.path LIMIT 1),
    (SELECT json_object(
        'rule', 'close_trend_not_deteriorating', 'decision', 'deny', 'clause', $(_policy_trend_clause_sql))
     $(_policy_trend_rows_sql)
     ORDER BY nf.path LIMIT 1),
    (SELECT json_object(
        'rule', 'close_tests_not_red', 'decision', 'deny', 'clause', $(_policy_test_clause_sql))
     $(_policy_test_rows_sql)
     ORDER BY nf.path LIMIT 1)
) AS receipt
FROM "NEW", "OLD"
WHERE OLD.status = 'active'
SQL
}

# _policy_close_bypass_sql <escaped-node-id> <proposed-metadata-expr>
#
# The exemptions a close relied on: one row per clause 1-3 whose only breaching
# files are ones quality_exempt covers, as {"rule", "bypass", "clause"} where
# bypass is quality_exempt:<pattern> and clause holds the same values a deny
# would have. It uses the receipt's row sources with the exempt guard inverted,
# so it cannot name a breach the trigger would judge differently. Meaningful
# only when the receipt allows (a denying clause has a non-exempt breach, and
# the close does not happen); _done_close_txn reads it only then. Without it an
# exempted close was indistinguishable from one no clause examined (wv-ef00f7).
_policy_close_bypass_sql() {
    local id="$1" proposed="$2" pattern
    pattern="(SELECT qe.path_pattern FROM quality_exempt qe WHERE $(_policy_exempt_match_sql) ORDER BY qe.path_pattern LIMIT 1)"
    cat <<SQL
WITH "NEW"(id, metadata) AS (SELECT id, $proposed FROM nodes WHERE id = '$id'),
     "OLD"(id, metadata, status) AS (SELECT id, metadata, status FROM nodes WHERE id = '$id'),
     bypassed(b) AS (
    SELECT (SELECT json_object('rule', 'close_complexity_ceiling', 'bypass', 'quality_exempt:' || $pattern,
                               'clause', $(_policy_mccabe_clause_sql))
            $(_policy_mccabe_rows_sql exempt)
            ORDER BY nf.path LIMIT 1) FROM "NEW", "OLD"
    UNION ALL
    SELECT (SELECT json_object('rule', 'close_trend_not_deteriorating', 'bypass', 'quality_exempt:' || $pattern,
                               'clause', $(_policy_trend_clause_sql))
            $(_policy_trend_rows_sql exempt)
            ORDER BY nf.path LIMIT 1) FROM "NEW", "OLD"
    UNION ALL
    SELECT (SELECT json_object('rule', 'close_tests_not_red', 'bypass', 'quality_exempt:' || $pattern,
                               'clause', $(_policy_test_clause_sql))
            $(_policy_test_rows_sql exempt)
            ORDER BY nf.path LIMIT 1)
    FROM "NEW", "OLD"
)
SELECT b AS bypass FROM bypassed, "OLD"
WHERE b IS NOT NULL AND OLD.status = 'active'
SQL
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

# Rebuild FTS5 index from existing nodes (for migration or repair).
#
# Covers BOTH search tables, not just nodes_fts (wv-ddb359: a prior version
# only rebuilt nodes_fts, so a corrupted nodes_learning_fts had no repair
# path short of hand-dropping it). The two tables need different repair
# strategies because of how each stores content:
#   - nodes_fts is an EXTERNAL CONTENT table (content=nodes) -- its rows are
#     virtual, re-derived from the nodes table on demand, so the FTS5
#     'rebuild' special command is sufficient and cheap.
#   - nodes_learning_fts is a plain (non external-content) FTS5 table -- it
#     owns its row data in its own shadow _content table, so 'rebuild' only
#     re-derives the index FROM that shadow table and would preserve any
#     corruption living there. DROP + recreate (db_migrate_fts5_learning is
#     idempotent: CREATE IF NOT EXISTS + backfill from nodes.metadata) is the
#     repair that actually fixed this in production.
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

    # Create the table and triggers, or upgrade a three-column index to the
    # current shape (wv-92b72c), before rebuilding: CREATE IF NOT EXISTS alone
    # would rebuild an old index without its alias column.
    db_migrate_fts5

    sqlite3 "$WV_DB" <<'REINDEX'
-- Rebuild entire index (FTS5 special command for content tables)
INSERT INTO nodes_fts(nodes_fts) VALUES('rebuild');
REINDEX

    local count
    count=$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM nodes_fts;")
    echo "Indexed $count nodes" >&2

    sqlite3 "$WV_DB" "DROP TABLE IF EXISTS nodes_learning_fts;" 2>/dev/null || true
    db_migrate_fts5_learning

    local learning_count
    learning_count=$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM nodes_learning_fts;" 2>/dev/null || echo 0)
    echo "Indexed $learning_count learning entries" >&2
}

# Rebuild FTS silently on load (called after importing selective state.sql
# which excludes FTS tables).  Uses the existing migrate + rebuild path.
db_rebuild_fts() {
    db_migrate_fts5 || return 1
    if ! sqlite3 -cmd ".timeout 5000" "$WV_DB" \
        "INSERT INTO nodes_fts(nodes_fts) VALUES('rebuild');"; then
        echo "Error: could not rebuild the node search index" >&2
        return 1
    fi
    # The plain integrity check does not compare an external-content index
    # against nodes; a missing document can pass it and break the next UPDATE.
    sqlite3 -cmd ".timeout 5000" "$WV_DB" \
        "INSERT INTO nodes_fts(nodes_fts,rank) VALUES('integrity-check',1);"
}

# ═══════════════════════════════════════════════════════════════════════════
# Database Ensure (with the graph size warning)
# ═══════════════════════════════════════════════════════════════════════════

# _wv_db_ensure_key — what db_ensure memoises: the DB path and its inode. A
# replaced file (wv init --force, or a load replacing a corrupt one; another
# process may do either mid-command) has a new inode, so it is ensured again.
# A load that restores into the live file keeps the inode and clears the memo.
_wv_db_ensure_key() {
    local ino
    ino=$(stat -c %i "$WV_DB" 2>/dev/null || stat -f %i "$WV_DB" 2>/dev/null) || return 1
    printf '%s|%s' "$WV_DB" "$ino"
}

# _wv_db_schema_stamp — one checksum over what db_ensure's migrations depend on
# and produce: the DB path and inode, the two files that define every
# migration (this one and wv-db-lineage.sh), and the full schema text. Any of
# them changing -- a CLI upgrade or edit, a replaced DB file, an out-of-band
# schema change such as an older wv rebuilding the policy trigger -- changes
# the stamp. Fails (prints nothing) when any input cannot be read.
_wv_db_schema_stamp() {
    local ino schema
    ino=$(stat -c %i "$WV_DB" 2>/dev/null || stat -f %i "$WV_DB" 2>/dev/null) || return 1
    [ -f "$_WV_DB_SRC_DIR/wv-db.sh" ] && [ -f "$_WV_DB_SRC_DIR/wv-db-lineage.sh" ] || return 1
    schema=$(sqlite3 -cmd ".timeout 5000" "$WV_DB" \
        "SELECT type, name, tbl_name, COALESCE(sql, '') FROM sqlite_master ORDER BY type, name;" 2>/dev/null) \
        || return 1
    [ -n "$schema" ] || return 1
    { printf '%s|%s\n%s\n' "$WV_DB" "$ino" "$schema"
      cat "$_WV_DB_SRC_DIR/wv-db.sh" "$_WV_DB_SRC_DIR/wv-db-lineage.sh"; } | cksum
}

# _wv_db_stamp_current — true when $WV_DB.ensured holds the stamp this DB and
# this code produce now, i.e. some process already ran these migrations
# against this exact schema and nothing has changed it since.
_wv_db_stamp_current() {
    local want have=""
    [ -f "$WV_DB.ensured" ] || return 1
    want=$(_wv_db_schema_stamp) || return 1
    [ -n "$want" ] || return 1
    read -r have < "$WV_DB.ensured" 2>/dev/null || return 1
    [ "$have" = "$want" ]
}

# _wv_db_schema_missing — print each schema object the migrations create that is
# absent (type:name, one per line); empty output means complete. The FTS objects
# are expected only where SQLite has FTS5, as their migrations skip otherwise.
# The migrations swallow their own sqlite3 errors (2>/dev/null || true), so this
# is the only evidence that they all took effect: a stamp written over one that
# failed certified the gap to every later process (wv-e90d62).
_wv_db_schema_missing() {
    sqlite3 -cmd ".timeout 5000" "$WV_DB" "
        WITH want(key, fts) AS (VALUES
            ('table:nodes', 0), ('table:edges', 0), ('table:policy_thresholds', 0),
            ('table:node_files', 0), ('table:file_metrics', 0), ('table:file_trend', 0),
            ('table:quality_exempt', 0), ('table:quality_config_sig', 0),
            ('table:chunks', 0), ('table:test_results', 0), ('table:file_test_status', 0),
            ('trigger:nodes_policy_check', 0),
            ('table:nodes_learning_fts', 1), ('trigger:nodes_learning_ai', 1),
            ('trigger:nodes_learning_ad', 1), ('trigger:nodes_learning_au', 1),
            ('table:chunks_fts', 1), ('trigger:chunks_ai', 1),
            ('trigger:chunks_ad', 1), ('trigger:chunks_au', 1))
        SELECT key FROM want
        WHERE (fts = 0 OR sqlite_compileoption_used('ENABLE_FTS5'))
          AND key NOT IN (SELECT type || ':' || name FROM sqlite_master)
        ORDER BY key;" 2>/dev/null || echo "unreadable"
}

# _wv_db_ensure_failed — record that this process could not open the graph.
# Test hook (wv-90083c): a command that prints its 2>/dev/null-silenced or
# empty-default report after this must exit nonzero, and the suite that holds
# every command to that needs to see the failure whatever the caller did with
# db_ensure's message. Inert unless WV_TEST_MODE=1 and WV_TEST_DB_ENSURE_LOG set.
_wv_db_ensure_failed() {
    [ "${WV_TEST_MODE:-}" = "1" ] && [ -n "${WV_TEST_DB_ENSURE_LOG:-}" ] \
        && printf '%s\n' "$WV_DB" >> "$WV_TEST_DB_ENSURE_LOG" 2>/dev/null
    return 0
}

# wv_require_graph — db_ensure for a command that reports from the graph, with
# the refusal said aloud (wv-90083c). Callers must check it: main runs the
# dispatch as `_wv_dispatch "$@" || rc=$?`, which suspends errexit for every
# command, so a bare db_ensure that fails lets the report print empty counts.
# Every db_query runs db_ensure first, so a graph db_ensure refuses is one these
# commands cannot read; cmd_health, which probes such a graph directly, has its
# own rule.
wv_require_graph() {
    db_ensure && return 0
    echo -e "${RED}Error: cannot open the graph database ($WV_DB); not reporting from it${NC}" >&2
    return 1
}

db_ensure() {
    # Per-process fast path (wv-3d6ed0). Without it every db_query re-ran the
    # migration probes below, each its own sqlite3, at ~220ms per query; the
    # flag was set and never read. Not exported: a nested wv is another process
    # and ensures for itself. Code that rebuilds the DB under the same path
    # clears _WV_DB_READY (cmd_init, cmd_load, selftest).
    if [ -n "${_WV_DB_READY:-}" ] && [ -f "$WV_DB" ] \
        && [ "$_WV_DB_READY" = "$(_wv_db_ensure_key)" ]; then
        return 0
    fi
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
                if hot_zone_ensure "${WV_DB%/*}" && cp "$old_global_db" "$WV_DB" 2>/dev/null; then
                    echo -e "${GREEN}✓ Migrated $old_nodes nodes to $WV_DB${NC}" >&2
                    echo -e "${YELLOW}Old database kept at $old_global_db — remove manually when ready${NC}" >&2
                    # Run schema migrations on the copied DB
                    db_migrate_edges
                    db_migrate_edge_type_enum
                    db_migrate_alias
                    db_migrate_virtual_columns
                    db_migrate_fts5
                    _WV_DB_READY=$(_wv_db_ensure_key) || _WV_DB_READY=""
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
            cmd_load || { _wv_db_ensure_failed; return 1; }
        else
            db_init || { _wv_db_ensure_failed; return 1; }
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

    db_stamp_repo_owner "${REPO_ROOT:-}"

    # Cross-process fast path (wv-048429). The first ensure in every wv process
    # ran all ten migrations (~170ms of sqlite3 calls) even when another process
    # had just run them against the same schema. The stamp is checked in one
    # query; a mismatch or any read failure falls through to the migrations.
    # Not covered: a data row a migration seeds (the test_gate threshold) and
    # something later deletes without touching the schema -- it is re-seeded
    # the next time the stamp changes, not on every call.
    if _wv_db_stamp_current; then
        _WV_DB_READY=$(_wv_db_ensure_key) || _WV_DB_READY=""
        _wv_db_size_check
        return 0
    fi

    local schema_lock="$WV_HOT_ZONE/.schema.lock"
    if command -v flock >/dev/null 2>&1; then
        exec {schema_lock_fd}>"$schema_lock"
        flock -w 10 "$schema_lock_fd" || {
            echo -e "${RED}Error: timed out waiting for Weave schema migration lock${NC}" >&2
            exec {schema_lock_fd}>&-
            _wv_db_ensure_failed
            return 1
        }
        # Check again under the lock (ultrareview #4574): processes that raced
        # at a cold start all found no stamp and queued here; the first one
        # migrated and stamped, so the rest have nothing left to do.
        if _wv_db_stamp_current; then
            flock -u "$schema_lock_fd" 2>/dev/null || true
            exec {schema_lock_fd}>&-
            _WV_DB_READY=$(_wv_db_ensure_key) || _WV_DB_READY=""
            _wv_db_size_check
            return 0
        fi
    fi

    # Existing hot-zone databases pass through db_ensure rather than db_init or
    # cmd_load. Run the same lineage migration here so upgrading the CLI repairs
    # a supported partial schema before any graph query or mutation reaches it.
    # Failure is explicit: continuing would leave sync and commit-refs unable to
    # persist, and the lock must be released before returning to the caller.
    if ! db_migrate_lineage; then
        if command -v flock >/dev/null 2>&1; then
            flock -u "$schema_lock_fd" 2>/dev/null || true
            exec {schema_lock_fd}>&-
        fi
        return 1
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

    # Stamp under the lock, so no process reads a stamp for a half-migrated
    # schema. A stamp that cannot be computed is removed, never left stale, and
    # a schema missing an object the migrations create is not stamped at all,
    # so the next process migrates again (wv-e90d62).
    local _stamp
    if [ -z "$(_wv_db_schema_missing)" ] \
        && _stamp=$(_wv_db_schema_stamp) && [ -n "$_stamp" ] \
        && printf '%s\n' "$_stamp" > "$WV_DB.ensured.$$" 2>/dev/null; then
        mv -f "$WV_DB.ensured.$$" "$WV_DB.ensured" 2>/dev/null || rm -f "$WV_DB.ensured.$$" "$WV_DB.ensured"
    else
        rm -f "$WV_DB.ensured.$$" "$WV_DB.ensured" 2>/dev/null || true
    fi

    if command -v flock >/dev/null 2>&1; then
        flock -u "$schema_lock_fd" 2>/dev/null || true
        exec {schema_lock_fd}>&-
    fi
    _WV_DB_READY=$(_wv_db_ensure_key) || _WV_DB_READY=""
    _wv_db_size_check
}

# _wv_db_graph_bytes <file-size> — bytes the graph occupies in brain.db, leaving
# out the code-search index (wv index: chunks, its FTS shadow tables and
# idx_chunks_file), which wv prune cannot shrink and wv index rebuilds
# (wv-dc5486). dbstat walks only the graph's own b-trees (~20ms); a sqlite3
# built without it falls back to the file size less the index's row payload,
# an overestimate, so the fallback can warn early but never prunes for the index.
_wv_db_graph_bytes() {
    local file_size="$1" bytes
    bytes=$(sqlite3 -cmd ".timeout 5000" "$WV_DB" "SELECT COALESCE(SUM(pgsize), 0) FROM dbstat
        WHERE aggregate = TRUE AND name IN (SELECT name FROM sqlite_master WHERE rootpage > 0
            AND name != 'chunks' AND name NOT LIKE 'chunks\_%' ESCAPE '\' AND name != 'idx_chunks_file');" 2>/dev/null)
    if [[ "$bytes" =~ ^[0-9]+$ ]]; then
        echo "$bytes"
        return 0
    fi
    bytes=$(sqlite3 -cmd ".timeout 5000" "$WV_DB" \
        "SELECT COALESCE(SUM(length(content) + COALESCE(length(embedding), 0)), 0) FROM chunks;" 2>/dev/null)
    [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
    echo $(( file_size > bytes ? file_size - bytes : 0 ))
}

# _wv_db_size_check — once per process tree (the flag is exported so pipe
# subshells inherit it), warn about a graph over WV_MAX_DB_SIZE.
# The graph is judged, not the file: the code index can be most of the file,
# and pruning nodes for it deleted graph work that freed nothing (wv-dc5486).
# It only warns. WV_AUTO_PRUNE=1 used to run 'wv prune --age=24h' from
# whichever command tripped the check; under the prune policy a prune is
# explicit (typed, or the release step) with a 30-day default, so the switch
# is retired and announces that it does not prune (owner ruling 2026-11-10, wv-ee5690).
# WV_DISABLE_AUTOPRUNE=1 still skips the check (sync and suites set it).
_wv_db_size_check() {
    [ -z "${_WV_SIZE_CHECKED:-}" ] && [ -f "$WV_DB" ] && [ -z "${WV_DISABLE_AUTOPRUNE:-}" ] || return 0
    export _WV_SIZE_CHECKED=1
    local db_size graph_bytes limit_mb
    db_size=$(stat -c%s "$WV_DB" 2>/dev/null || stat -f%z "$WV_DB" 2>/dev/null || echo 0)
    # The graph is part of the file, so a file under the limit needs no query.
    [ "$db_size" -gt "$WV_MAX_DB_SIZE" ] 2>/dev/null || return 0
    graph_bytes=$(_wv_db_graph_bytes "$db_size")
    [ "$graph_bytes" -gt "$WV_MAX_DB_SIZE" ] 2>/dev/null || return 0
    limit_mb=$(( WV_MAX_DB_SIZE / 1048576 ))
    echo "wv: graph data is $(( graph_bytes / 1048576 ))MB (limit ${limit_mb}MB) — preview with 'wv prune --dry-run', then run 'wv prune'" >&2
    if [ "${WV_AUTO_PRUNE:-0}" = "1" ]; then
        echo "wv: WV_AUTO_PRUNE is retired and does not prune; a prune runs only when you type it (wv guide --procedure=prune-policy)" >&2
    fi
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# Query Helpers
# ═══════════════════════════════════════════════════════════════════════════

# SQL reaches sqlite3 on stdin, never as an argument: Linux caps one argument at
# 131,072 bytes, and a prune's tombstone SQL (853,597 bytes for 615 nodes) failed
# at execve with E2BIG while its smaller DELETEs ran, so the tombstones were lost
# and every fresh load resurrected the pruned nodes (wv-aec7de, wv-5e5f18).
# -bail keeps the argument form's contract: stop at the first error, exit nonzero.
db_query() {
    db_ensure || return 1
    printf '%s\n' "$1" | sqlite3 -batch -bail -cmd ".timeout 5000" "$WV_DB"
}

# sqlite3 -json prints nothing, not [], for zero rows. Callers then hand jq
# empty input, and a --json command printed nothing at all (wv-fea2e9), so an
# empty result is [] here, as db_query_json_v2 already does.
db_query_json() {
    db_ensure || return 1
    local raw
    raw=$(printf '%s\n' "$1" | sqlite3 -json -bail -cmd ".timeout 5000" "$WV_DB") || return $?
    printf '%s\n' "${raw:-[]}"
}

# wv_kind_sql [alias] — the SQL expression for a node's kind (ontology S1,
# wv-f7dfd3): metadata.node_kind, then its one-release mirror metadata.type, so
# a graph the backfill has not reached reads as it did before. Every query that
# branches on kind uses this rather than the type column or '$.type'.
wv_kind_sql() {
    local m="${1:+$1.}metadata"
    printf "COALESCE(json_extract(%s, '\$.node_kind'), json_extract(%s, '\$.type'))" "$m" "$m"
}

# _wv_finding_prefix_sql <alias> — the node's text opens with a finding or gap
# prefix (finding(, Finding:, gap( ...). Read alongside the kind while open
# finding( nodes are still typed task (ontology D2).
_wv_finding_prefix_sql() {
    local t="ltrim($1.text)"
    printf "(%s LIKE 'finding(%%' OR %s LIKE 'finding:%%' OR %s LIKE 'gap(%%' OR %s LIKE 'gap:%%')" "$t" "$t" "$t" "$t"
}

# wv_edge_violations_sql <candidates-select> — the edge invariants (ontology S2,
# wv-76b361; contracts/edge-types-v1.json, pinned by tests/test-edge-invariants.sh).
# <candidates-select> yields (source, target, type): one proposed edge for wv link
# and wv block, or every stored edge for wv doctor, so the write-time refusal and
# the report judge by the same query. One row per broken invariant, as
# (invariant, source, target, type). Acyclicity asks whether the target already
# reaches the source over edges of the same type, which for a stored edge means
# it lies on a cycle. A tie on created_at is not backwards. supersedes runs old
# -> new, except that a source whose superseded_by names the target declares
# the direction itself (crystallize dedup, resolve --winner with an older winner).
wv_edge_violations_sql() {
    cat <<SQL
WITH RECURSIVE cand(source, target, type) AS ($1),
reach(type, start, node) AS (
    SELECT type, target, target FROM cand WHERE type IN ('blocks', 'implements')
    UNION
    SELECT r.type, r.start, e.target FROM reach r
    JOIN edges e ON e.source = r.node AND e.type = r.type
)
SELECT 'no_self_edge' AS invariant, c.source AS source, c.target AS target, c.type AS type
FROM cand c WHERE c.source = c.target
UNION ALL
SELECT 'endpoints_exist', c.source, c.target, c.type FROM cand c
WHERE NOT EXISTS (SELECT 1 FROM nodes WHERE id = c.source)
   OR NOT EXISTS (SELECT 1 FROM nodes WHERE id = c.target)
UNION ALL
SELECT 'acyclic', c.source, c.target, c.type FROM cand c
WHERE c.type IN ('blocks', 'implements') AND c.source != c.target
  AND EXISTS (SELECT 1 FROM reach r WHERE r.type = c.type AND r.start = c.target AND r.node = c.source)
UNION ALL
SELECT 'target_newer_or_declared', c.source, c.target, c.type
FROM cand c JOIN nodes s ON s.id = c.source JOIN nodes t ON t.id = c.target
WHERE c.type = 'supersedes' AND c.source != c.target AND t.created_at < s.created_at
  AND COALESCE(json_extract(s.metadata, '\$.superseded_by'), '') != t.id
UNION ALL
SELECT 'memory_superseded_by', c.source, c.target, c.type
FROM cand c JOIN nodes s ON s.id = c.source JOIN nodes t ON t.id = c.target
WHERE c.type = 'supersedes' AND $(wv_kind_sql s) = 'memory'
  AND COALESCE(json_extract(s.metadata, '\$.superseded_by'), '') != t.id
UNION ALL
SELECT 'finding_endpoint', c.source, c.target, c.type
FROM cand c JOIN nodes s ON s.id = c.source JOIN nodes t ON t.id = c.target
WHERE c.type = 'resolves'
  AND COALESCE($(wv_kind_sql s), '') != 'finding' AND COALESCE($(wv_kind_sql t), '') != 'finding'
  AND NOT $(_wv_finding_prefix_sql s) AND NOT $(_wv_finding_prefix_sql t)
UNION ALL
SELECT 'source_newer', c.source, c.target, c.type
FROM cand c JOIN nodes s ON s.id = c.source JOIN nodes t ON t.id = c.target
WHERE c.type = 'addresses' AND s.created_at < t.created_at
SQL
}

# wv_pitfall_resolver_edges_sql — (pitfall, resolver) pairs, the one definition
# of "this pitfall is addressed" for audit-pitfalls, health, status and prune. A
# node that addresses or implements the pitfall is the edge's source; one that
# replaces it through supersedes is the target, since the target replaces the
# source (contracts/edge-types-v1.json). Those readers took the supersedes
# target as the addressed pitfall, the edge read backwards (wv-76b361).
wv_pitfall_resolver_edges_sql() {
    cat <<'SQL'
SELECT target AS pitfall, source AS resolver FROM edges WHERE type IN ('addresses', 'implements')
UNION ALL
SELECT source AS pitfall, target AS resolver FROM edges WHERE type = 'supersedes'
SQL
}

# wv_edge_violation <source> <target> <type> — the invariants one proposed edge
# would break, space-separated (empty when none). IDs must be validated first.
# Returns nonzero when the graph could not be read, so a caller fails closed.
wv_edge_violation() {
    local out
    out=$(db_query "SELECT DISTINCT invariant FROM ($(wv_edge_violations_sql \
        "SELECT '$1', '$2', '$3'"));" 2>&1) || {
        echo -e "${RED}Error: could not check the edge's invariants: $out${NC}" >&2
        return 1
    }
    printf '%s' "$out" | tr '\n' ' ' | sed 's/ $//'
}

# wv_parked_predicate <alias> — CANONICAL "parked": metadata.deferred with a
# deferred_reason. A parked node keeps status todo by design (the 2.0 plan parks
# work by flag and resumes it by clearing the flag); wv_blocking_reason keeps it
# out of ready, close-children counts it as accounted, and the node-state check
# does not ask its status to change (wv-5515e9).
wv_parked_predicate() {
    local n="${1:-n}"
    cat <<SQL
(json_extract(${n}.metadata, '\$.deferred') IN (1, 'true')
 AND COALESCE(json_extract(${n}.metadata, '\$.deferred_reason'), '') != '')
SQL
}

# wv_deferral_divergent_sql <alias> — the node-state divergence that wv doctor
# (node-state) and pattern-audit Check 6 both report: todo, carrying deferral
# metadata, not parked, and with no open blocks edge, so its status claims a
# readiness its metadata denies. One definition, so the two reports cannot
# disagree on which nodes they count.
wv_deferral_divergent_sql() {
    local n="${1:-n}"
    cat <<SQL
(${n}.status = 'todo'
  AND $(wv_deferral_metadata_predicate "$n")
  AND NOT $(wv_parked_predicate "$n")
  AND NOT EXISTS (
      SELECT 1 FROM edges _de JOIN nodes _db ON _de.source = _db.id
      WHERE _de.target = ${n}.id AND _de.type = 'blocks' AND _db.status != 'done'))
SQL
}

# wv_unaccounted_child_sql <child-alias> <parent-id-expr> — the child is open and
# nothing accounts for it: not parked (metadata.deferred with a deferred_reason),
# not linked by a resolves edge, and with no other implements parent still open.
# wv done refuses to close a parent over such a child; wv doctor lists closed
# parents that already have one (ontology S2, 2.0 plan ordering rule 4).
wv_unaccounted_child_sql() {
    local c="$1" p="$2"
    cat <<SQL
($c.status != 'done'
  AND NOT $(wv_parked_predicate "$c")
  AND NOT EXISTS (SELECT 1 FROM edges r WHERE r.type = 'resolves' AND (r.source = $c.id OR r.target = $c.id))
  AND NOT EXISTS (SELECT 1 FROM edges o JOIN nodes op ON op.id = o.target
                  WHERE o.type = 'implements' AND o.source = $c.id AND o.target != $p AND op.status != 'done'))
SQL
}

# db_query_json_v2 — lean JSON shape for --json-v2 flag:
#   - metadata promoted from escaped string to nested object
#   - created_at / updated_at omitted
#   - lineage_actor / lineage_seq omitted: replay bookkeeping, not graph meaning,
#     and lineage_seq=0 on a backfilled row would survive the empty-value filter
#     and appear in every consumer record (weave_gh, the active-node hook, MCP)
#   - null/empty fields omitted
db_query_json_v2() {
    db_ensure || return 1
    local raw
    raw=$(sqlite3 -json -cmd ".timeout 5000" "$WV_DB" "$1") || return $?
    [ -z "$raw" ] && echo "[]" && return
    echo "$raw" | jq '[.[] | . + (
        if .metadata and (.metadata | type) == "string"
        then {metadata: (.metadata | fromjson? // {})}
        else {}
        end
    ) | del(.created_at, .updated_at, .lineage_actor, .lineage_seq)
      | with_entries(select(.value != null and .value != ""))]'
}

# wv_deferral_metadata_predicate — CANONICAL definition of "node carries ACTIVE
# deferral METADATA" (the representation that must be reconciled to status). Echoes a
# SQL boolean for the given node alias. ONE definition shared by the read predicate
# (wv_blocking_reason) AND the enforcement guard (pattern-audit Check 6, wv doctor
# node-state) so the deferral keys cannot drift between reader and checker — the very
# dual-representation bug this guards against, applied to itself. Keys: deferred=true,
# blocked_until in the future, or blocked_on set.
wv_deferral_metadata_predicate() {
    local n="${1:-n}"
    cat <<SQL
( json_extract(${n}.metadata, '\$.deferred') IN (1, 'true')
  OR ( json_extract(${n}.metadata, '\$.blocked_until') IS NOT NULL
       AND date(json_extract(${n}.metadata, '\$.blocked_until')) > date('now') )
  OR ( json_extract(${n}.metadata, '\$.blocked_on') IS NOT NULL
       AND json_extract(${n}.metadata, '\$.blocked_on') != '' ) )
SQL
}

# wv_blocking_reason — SINGLE SOURCE OF TRUTH for "is this node blocked / not ready".
# Echoes a SQL expression (usable in SELECT or WHERE) yielding the REASON a node is
# not ready under the UNIFIED blocking signal, or NULL when it is ready:
#   'status'   — explicit blocked / blocked-external status
#   'deferral' — active deferral metadata (see wv_deferral_metadata_predicate)
#   'edge'     — an inbound non-done blocks edge
# Shared by cmd_ready (exclude where reason IS NOT NULL) and cmd_context (surface the
# reason + a blocked flag) so the CLI and weave-runtime read ONE signal rather than the
# metadata-vs-edge dual representation (wv-f752a5). Pass the table alias of the node row
# (default 'n'). Precedence: status > deferral > edge.
wv_blocking_reason() {
    local n="${1:-n}"
    local _defer
    _defer=$(wv_deferral_metadata_predicate "$n")
    cat <<SQL
CASE
    WHEN ${n}.status IN ('blocked', 'blocked-external') THEN 'status'
    WHEN ${_defer} THEN 'deferral'
    WHEN EXISTS (
        SELECT 1 FROM edges _be JOIN nodes _bn ON _be.source = _bn.id
        WHERE _be.target = ${n}.id AND _be.type = 'blocks' AND _bn.status != 'done'
    ) THEN 'edge'
    ELSE NULL
END
SQL
}
