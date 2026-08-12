"""quality.db schema, lifecycle, and staleness detection.

SQLite DB at $WV_HOT_ZONE/quality.db -- flat sibling to brain.db.
Never synced to git, never tracked, fully rebuildable from source + git.

Schema (originally from PROPOSAL-wv-quality.md; extended by migrations v2 and v3):
  - scan_meta: scan run metadata + staleness tracking
  - files: static analysis per file per scan (loc, complexity, functions, etc.)
  - file_metrics: CK-suite EAV metrics per file per scan (wmc, cbo, dit, rfc, lcom)
  - git_stats: git-derived metrics per file, NOT scan-versioned (churn, authors, age, hotspot)
  - co_change: co-change pairs (files that frequently change together)
  - file_state: incremental scan state (mtime, git_blob SHA)

Retention: 5 scans for trends (scan_meta, complexity_trend), 2 for raw data (files, file_metrics).
Staleness: tracked via scan_meta.git_head vs current HEAD SHA.
Recovery: delete quality.db entirely (wv quality reset).
"""

# pylint: disable=too-many-lines

from __future__ import annotations

import logging
import json
import os
import sqlite3
import time
from pathlib import Path
from typing import Any

from .hotspots import HOTSPOT_THRESHOLD
from .models import (
    CKMetrics,
    CoChange,
    FileEntry,
    FileState,
    FunctionCC,
    GitStats,
    PatternFinding,
    PatternRun,
    ScanMeta,
)

log = logging.getLogger(__name__)

_QUALITY_DB_NAME = "quality.db"

# ---------------------------------------------------------------------------
# Schema -- matches PROPOSAL-wv-quality.md exactly
# ---------------------------------------------------------------------------

_SCHEMA = """
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA foreign_keys = ON;
PRAGMA temp_store = MEMORY;

-- Scan metadata + staleness tracking
CREATE TABLE IF NOT EXISTS scan_meta (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    scanned_at      TEXT NOT NULL,
    git_head        TEXT NOT NULL,
    files_count     INTEGER,
    duration_ms     INTEGER,
    scanner_version TEXT DEFAULT '',
    bash_cc_backend TEXT DEFAULT 'regex',
    ts_cc_backend   TEXT DEFAULT 'unavailable'
);

-- Per-file metrics (latest scan only, previous kept for diff)
CREATE TABLE IF NOT EXISTS files (
    path        TEXT NOT NULL,
    scan_id     INTEGER NOT NULL,
    language    TEXT,
    loc         INTEGER,
    complexity  REAL,
    functions   INTEGER,
    max_nesting INTEGER,
    avg_fn_len  REAL,
    category    TEXT DEFAULT 'production',
    FOREIGN KEY(scan_id) REFERENCES scan_meta(id) ON DELETE CASCADE,
    PRIMARY KEY(path, scan_id)
);

-- Named metrics per file (CK suite only -- ast-derived, scan-versioned)
CREATE TABLE IF NOT EXISTS file_metrics (
    path        TEXT NOT NULL,
    scan_id     INTEGER NOT NULL,
    metric      TEXT NOT NULL,
    value       REAL,
    FOREIGN KEY(scan_id) REFERENCES scan_meta(id) ON DELETE CASCADE,
    PRIMARY KEY(path, scan_id, metric)
);

-- Git-derived (computed separately, language agnostic, always-current)
-- churn/authors/age_days live here only -- not duplicated in file_metrics
CREATE TABLE IF NOT EXISTS git_stats (
    path        TEXT PRIMARY KEY,
    churn       INTEGER,
    authors     INTEGER,
    age_days    INTEGER,
    hotspot     REAL
);

-- Co-change pairs (files that frequently change together in commits)
CREATE TABLE IF NOT EXISTS co_change (
    path_a      TEXT NOT NULL,
    path_b      TEXT NOT NULL,
    count       INTEGER,
    PRIMARY KEY(path_a, path_b)
);

-- Incremental scan state
CREATE TABLE IF NOT EXISTS file_state (
    path        TEXT PRIMARY KEY,
    mtime       INTEGER,
    git_blob    TEXT
);

-- Pattern-scan lifecycle: independent of scan_meta (the complexity-scan
-- sequence) so `wv quality patterns scan` gets its own identity instead of
-- reusing/fabricating a scan_meta row -- see begin_pattern_run.
-- finished_at is NULL until finish_pattern_run completes it; retention
-- (_prune_pattern_runs) counts finished and unfinished runs against
-- separate windows so a chain of failed scans can't evict an earlier
-- successful run's findings.
-- origin distinguishes a row begin_pattern_run created this run ('native')
-- from one _migrate_v10 backfilled from pre-pattern_runs v9 evidence
-- ('legacy', stamped explicitly at that backfill INSERT). Every other
-- writer -- an origin-less ALTERed-in row (see _migrate_v10), or ANY
-- insert (a pre-origin or downgraded writer, ad-hoc SQL) that omits the
-- column -- gets the column DEFAULT, 'unknown': ambiguous provenance, not
-- assumed legacy. The default is deliberately NOT 'legacy' -- a mixed-
-- version writer that doesn't know about `origin` yet can still insert an
-- interrupted/partial row on a CURRENT-schema database (the column
-- already exists, so no ALTER-time backfill is involved at all), and
-- defaulting that to 'legacy' would resurrect the exact promotion-to-
-- finished defect origin exists to prevent, just via a different writer
-- than the one already fixed (see wv-033ec6, wv-845388). Only 'legacy'
-- rows are eligible for _migrate_v10's evidence-based finished_at
-- reconstruction -- a native or unknown row's finished_at is set ONLY by
-- finish_pattern_run, never inferred from partial receipts (see
-- _pattern_run_has_finished_evidence).
CREATE TABLE IF NOT EXISTS pattern_runs (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    started_at  TEXT NOT NULL,
    git_head    TEXT NOT NULL,
    target      TEXT NOT NULL DEFAULT '.',
    files_count INTEGER,
    duration_ms INTEGER,
    finished_at TEXT,
    origin      TEXT NOT NULL DEFAULT 'unknown'
);

-- Structural pattern match findings (ast-grep + prose rules).
-- Pruned at _MAX_PATTERN_RUNS boundary; point-in-time data.
CREATE TABLE IF NOT EXISTS pattern_findings (
    id          INTEGER PRIMARY KEY,
    scan_id     INTEGER NOT NULL,
    finding_key TEXT,
    path        TEXT NOT NULL,
    rule_id     TEXT NOT NULL,
    line        INTEGER NOT NULL,
    col         INTEGER DEFAULT 0,
    match_text  TEXT,
    severity    TEXT DEFAULT 'warning',
    FOREIGN KEY(scan_id) REFERENCES pattern_runs(id) ON DELETE CASCADE
);

-- Receipts distinguish a successful zero-hit rule from not-run/failed.
CREATE TABLE IF NOT EXISTS pattern_rule_runs (
    scan_id          INTEGER NOT NULL,
    rule_id          TEXT NOT NULL,
    definition_hash  TEXT NOT NULL,
    rule_path        TEXT NOT NULL,
    target           TEXT NOT NULL,
    status           TEXT NOT NULL,
    hits             INTEGER,
    error            TEXT,
    ran_at           TEXT NOT NULL,
    FOREIGN KEY(scan_id) REFERENCES pattern_runs(id) ON DELETE CASCADE,
    PRIMARY KEY(scan_id, rule_id)
);

-- Stable identity and latest human disposition survive point-in-time finding pruning.
CREATE TABLE IF NOT EXISTS pattern_finding_state (
    finding_key        TEXT PRIMARY KEY,
    rule_id            TEXT NOT NULL,
    path               TEXT NOT NULL,
    match_text         TEXT NOT NULL,
    context_text       TEXT NOT NULL,
    first_seen_scan_id INTEGER,
    last_seen_scan_id  INTEGER,
    scan_count         INTEGER NOT NULL DEFAULT 1,
    disposition        TEXT NOT NULL DEFAULT 'unresolved'
                       CHECK(disposition IN ('accepted_defect', 'false_positive', 'waived', 'unresolved')),
    note               TEXT,
    adjudicated_at     TEXT,
    updated_at         TEXT NOT NULL
);

-- One row per finding identity and quality scan makes recurrence idempotent.
CREATE TABLE IF NOT EXISTS pattern_finding_occurrences (
    finding_key TEXT NOT NULL,
    scan_id     INTEGER NOT NULL,
    PRIMARY KEY(finding_key, scan_id)
);

CREATE TABLE IF NOT EXISTS pattern_finding_disposition_history (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    finding_key    TEXT NOT NULL,
    disposition    TEXT NOT NULL
                   CHECK(disposition IN ('accepted_defect', 'false_positive', 'waived', 'unresolved')),
    note           TEXT,
    adjudicated_at TEXT NOT NULL,
    FOREIGN KEY(finding_key) REFERENCES pattern_finding_state(finding_key)
);

-- Indexes for common queries
CREATE INDEX IF NOT EXISTS idx_files_scan ON files(scan_id);
CREATE INDEX IF NOT EXISTS idx_files_complexity ON files(complexity DESC);
CREATE INDEX IF NOT EXISTS idx_fm_scan ON file_metrics(scan_id);
CREATE INDEX IF NOT EXISTS idx_pf_scan ON pattern_findings(scan_id);
CREATE INDEX IF NOT EXISTS idx_pf_rule ON pattern_findings(rule_id);
CREATE INDEX IF NOT EXISTS idx_prr_scan ON pattern_rule_runs(scan_id);
CREATE INDEX IF NOT EXISTS idx_pfs_rule ON pattern_finding_state(rule_id);
CREATE INDEX IF NOT EXISTS idx_pfo_scan ON pattern_finding_occurrences(scan_id);
CREATE INDEX IF NOT EXISTS idx_pfdh_key ON pattern_finding_disposition_history(finding_key);
CREATE INDEX IF NOT EXISTS idx_gs_hotspot ON git_stats(hotspot DESC);
"""

# Maximum number of scans to retain (current + previous)
_MAX_SCANS = 5  # how many scans to retain in scan_meta / complexity_trend
_FILES_SCANS = 2  # how many scans to retain raw files + file_metrics (diff window)
_MAX_PATTERN_RUNS = 5  # how many pattern_runs to retain (independent of _MAX_SCANS)


# ---------------------------------------------------------------------------
# Database lifecycle
# ---------------------------------------------------------------------------


def _resolve_db_path(hot_zone: str | None = None) -> Path:
    """Resolve quality.db path from WV_HOT_ZONE or explicit path."""
    if hot_zone:
        return Path(hot_zone) / _QUALITY_DB_NAME

    env_hz = os.environ.get("WV_HOT_ZONE", "")
    if env_hz:
        return Path(env_hz) / _QUALITY_DB_NAME

    # Fallback: /dev/shm/weave or /tmp/weave
    base = "/dev/shm/weave" if Path("/dev/shm").exists() else "/tmp/weave"
    return Path(base) / _QUALITY_DB_NAME


def _migrate_v2(conn: sqlite3.Connection) -> None:
    """Idempotent v2 schema migration for depth metrics.

    Adds columns for essential_complexity, indent_sd, detail,
    and the complexity_trend table. Safe to run on v1 or v2 DBs.
    """
    # Check which columns already exist in files table
    cols = {r[1] for r in conn.execute("PRAGMA table_info(files)").fetchall()}
    if "essential_complexity" not in cols:
        conn.execute(
            "ALTER TABLE files ADD COLUMN essential_complexity REAL DEFAULT 0.0"
        )
    if "indent_sd" not in cols:
        conn.execute("ALTER TABLE files ADD COLUMN indent_sd REAL DEFAULT 0.0")

    # Add detail column to file_metrics for fn_cc metadata
    fm_cols = {r[1] for r in conn.execute("PRAGMA table_info(file_metrics)").fetchall()}
    if "detail" not in fm_cols:
        conn.execute("ALTER TABLE file_metrics ADD COLUMN detail TEXT")

    # Ownership fields in git_stats (Sprint 2)
    gs_cols = {r[1] for r in conn.execute("PRAGMA table_info(git_stats)").fetchall()}
    if "ownership_fraction" not in gs_cols:
        conn.execute(
            "ALTER TABLE git_stats ADD COLUMN ownership_fraction REAL DEFAULT 0.0"
        )
    if "minor_contributors" not in gs_cols:
        conn.execute(
            "ALTER TABLE git_stats ADD COLUMN minor_contributors INTEGER DEFAULT 0"
        )

    # Complexity trend table (one row per file per scan)
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS complexity_trend (
            path        TEXT NOT NULL,
            scan_id     INTEGER NOT NULL,
            complexity  REAL,
            essential   REAL,
            FOREIGN KEY(scan_id) REFERENCES scan_meta(id)
                ON DELETE CASCADE,
            PRIMARY KEY(path, scan_id)
        );
    """)
    conn.commit()


def _migrate_v3(conn: sqlite3.Connection) -> None:
    """Idempotent v3 schema migration: add category column to files table.

    Adds category TEXT DEFAULT 'production' to files. Safe to run on
    v1, v2, or v3 DBs.
    """
    cols = {r[1] for r in conn.execute("PRAGMA table_info(files)").fetchall()}
    if "category" not in cols:
        conn.execute("ALTER TABLE files ADD COLUMN category TEXT DEFAULT 'production'")
    conn.commit()


def _migrate_v4(conn: sqlite3.Connection) -> None:
    """Idempotent v4 schema migration: add scanner_version to scan_meta.

    Existing rows get an empty string default (treated as unknown version,
    triggering a full re-scan on the next scan run).
    """
    cols = {r[1] for r in conn.execute("PRAGMA table_info(scan_meta)").fetchall()}
    if "scanner_version" not in cols:
        conn.execute("ALTER TABLE scan_meta ADD COLUMN scanner_version TEXT DEFAULT ''")
    conn.commit()


def _migrate_v5(conn: sqlite3.Connection) -> None:
    """Idempotent v5 schema migration: add bash_cc_backend to scan_meta.

    Existing rows default to 'regex' (pre-ast-grep baseline).
    Kept separate from scanner_version to avoid colliding with the version
    equality check in cmd_scan() that triggers re-scans on version change.
    """
    cols = {r[1] for r in conn.execute("PRAGMA table_info(scan_meta)").fetchall()}
    if "bash_cc_backend" not in cols:
        conn.execute(
            "ALTER TABLE scan_meta ADD COLUMN bash_cc_backend TEXT DEFAULT 'regex'"
        )
    conn.commit()


def _migrate_v6(conn: sqlite3.Connection) -> None:
    """Idempotent v6 schema migration: add pattern_findings table.

    The table is also in the base _SCHEMA CREATE TABLE IF NOT EXISTS, so on
    fresh DBs the migration is a no-op. On existing DBs it creates the table.
    """
    tables = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()}
    if "pattern_findings" not in tables:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS pattern_findings (
                id          INTEGER PRIMARY KEY,
                scan_id     INTEGER NOT NULL,
                path        TEXT NOT NULL,
                rule_id     TEXT NOT NULL,
                line        INTEGER NOT NULL,
                col         INTEGER DEFAULT 0,
                match_text  TEXT,
                severity    TEXT DEFAULT 'warning',
                FOREIGN KEY(scan_id) REFERENCES scan_meta(id) ON DELETE CASCADE
            )
        """)
        conn.execute("CREATE INDEX IF NOT EXISTS idx_pf_scan ON pattern_findings(scan_id)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_pf_rule ON pattern_findings(rule_id)")
    conn.commit()


def _migrate_v7(conn: sqlite3.Connection) -> None:
    """Idempotent v7 schema migration: add ts_cc_backend to scan_meta.

    Existing rows default to 'unavailable' (TypeScript scanning added in v1.52).
    """
    cols = {r[1] for r in conn.execute("PRAGMA table_info(scan_meta)").fetchall()}
    if "ts_cc_backend" not in cols:
        conn.execute(
            "ALTER TABLE scan_meta ADD COLUMN ts_cc_backend TEXT DEFAULT 'unavailable'"
        )
    conn.commit()


def _migrate_v8(conn: sqlite3.Connection) -> None:
    """Idempotent v8 migration: add per-rule pattern execution receipts."""
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS pattern_rule_runs (
            scan_id          INTEGER NOT NULL,
            rule_id          TEXT NOT NULL,
            definition_hash  TEXT NOT NULL,
            rule_path        TEXT NOT NULL,
            target           TEXT NOT NULL,
            status           TEXT NOT NULL,
            hits             INTEGER,
            error            TEXT,
            ran_at           TEXT NOT NULL,
            FOREIGN KEY(scan_id) REFERENCES scan_meta(id) ON DELETE CASCADE,
            PRIMARY KEY(scan_id, rule_id)
        );
        CREATE INDEX IF NOT EXISTS idx_prr_scan ON pattern_rule_runs(scan_id);
    """)
    conn.commit()


def _migrate_v9(conn: sqlite3.Connection) -> None:
    """Add stable pattern identities, dispositions, and adjudication history."""
    cols = {r[1] for r in conn.execute("PRAGMA table_info(pattern_findings)").fetchall()}
    if "finding_key" not in cols:
        conn.execute("ALTER TABLE pattern_findings ADD COLUMN finding_key TEXT")
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS pattern_finding_state (
            finding_key        TEXT PRIMARY KEY,
            rule_id            TEXT NOT NULL,
            path               TEXT NOT NULL,
            match_text         TEXT NOT NULL,
            context_text       TEXT NOT NULL,
            first_seen_scan_id INTEGER,
            last_seen_scan_id  INTEGER,
            scan_count         INTEGER NOT NULL DEFAULT 1,
            disposition        TEXT NOT NULL DEFAULT 'unresolved'
                               CHECK(disposition IN ('accepted_defect', 'false_positive', 'waived', 'unresolved')),
            note               TEXT,
            adjudicated_at     TEXT,
            updated_at         TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS pattern_finding_occurrences (
            finding_key TEXT NOT NULL,
            scan_id     INTEGER NOT NULL,
            PRIMARY KEY(finding_key, scan_id)
        );
        CREATE TABLE IF NOT EXISTS pattern_finding_disposition_history (
            id             INTEGER PRIMARY KEY AUTOINCREMENT,
            finding_key    TEXT NOT NULL,
            disposition    TEXT NOT NULL
                           CHECK(disposition IN ('accepted_defect', 'false_positive', 'waived', 'unresolved')),
            note           TEXT,
            adjudicated_at TEXT NOT NULL,
            FOREIGN KEY(finding_key) REFERENCES pattern_finding_state(finding_key)
        );
        CREATE INDEX IF NOT EXISTS idx_pf_key ON pattern_findings(finding_key);
        CREATE INDEX IF NOT EXISTS idx_pfs_rule ON pattern_finding_state(rule_id);
        CREATE INDEX IF NOT EXISTS idx_pfo_scan ON pattern_finding_occurrences(scan_id);
        CREATE INDEX IF NOT EXISTS idx_pfdh_key ON pattern_finding_disposition_history(finding_key);
    """)
    conn.commit()


def _pattern_run_has_finished_evidence(conn: sqlite3.Connection, run_id: int) -> bool:
    """True if `run_id` has any evidence of a completed pattern-run scan.

    Used by _migrate_v10 to classify a pattern_runs row's finished_at when it
    can't rely on finish_pattern_run having been called (a legacy v9 backfill
    id, or a row a buggier earlier migration inserted without finished_at at
    all): a real finding, a durable occurrence, or at least one rule that
    completed successfully (even with zero hits) are all evidence the scan
    actually ran to completion. A scan_id with only failed receipts and none
    of these has no such evidence and must stay classified unfinished.

    Also checks the pattern_findings_v9/pattern_rule_runs_v9 backup tables
    (when present) -- this runs BEFORE
    _migrate_v10_repair_stranded_backups merges a backup stranded by an
    interrupted prior rebuild into the live tables, so evidence for a
    backup-only id would otherwise be invisible here.
    """
    for table, extra in (
        ("pattern_findings", ""),
        ("pattern_findings_v9", ""),
        ("pattern_finding_occurrences", ""),
        ("pattern_rule_runs", " AND status = 'success'"),
        ("pattern_rule_runs_v9", " AND status = 'success'"),
    ):
        try:
            row = conn.execute(
                f"SELECT 1 FROM {table} WHERE scan_id = ?{extra} LIMIT 1", (run_id,)
            ).fetchone()
        except sqlite3.OperationalError:
            continue  # no _v9 backup table -- the common case
        if row:
            return True
    return False


def _legacy_pattern_run_ids(conn: sqlite3.Connection) -> set[int]:
    """Union of scan_ids owed a pattern_runs reservation.

    Reads pattern_findings/pattern_rule_runs/pattern_finding_occurrences,
    and -- when present -- the pattern_findings_v9/pattern_rule_runs_v9
    backup tables stranded by an interrupted prior rebuild. An id found only
    in a backup must still be reserved before
    _migrate_v10_repair_stranded_backups can merge it into the live (FK'd
    to pattern_runs) tables.
    """
    tables = ["pattern_findings", "pattern_rule_runs", "pattern_finding_occurrences"]
    live_tables = {
        row[0]
        for row in conn.execute("SELECT name FROM sqlite_master WHERE type = 'table'").fetchall()
    }
    tables.extend(
        backup
        for backup in ("pattern_findings_v9", "pattern_rule_runs_v9")
        if backup in live_tables
    )
    union_sql = " UNION ".join(f"SELECT DISTINCT scan_id FROM {t}" for t in tables)
    return {row[0] for row in conn.execute(union_sql).fetchall()}


def _pattern_run_receipt_target(conn: sqlite3.Connection, run_id: int) -> str | None:
    """Return run_id's single agreed non-empty SUCCESSFUL receipt target, or
    None.

    Only status='success' receipts count as evidence of the run's real
    target -- under v9's shared scan_id (complexity scan and pattern scan
    reused the same id), a later, unrelated invocation could fail against a
    DIFFERENT target while record_pattern_rule_failure deliberately
    preserved the earlier successful run's findings. A failed receipt's
    target reflects that later, unrelated attempt, not the run whose
    findings actually survived -- using it regardless of status could
    rescope a root scan's surviving findings under whatever an unconnected
    later failure happened to be scoped to.

    None when run_id has no successful receipts at all (an occurrence-only
    legacy id, or one whose only evidence is a failed receipt) or its
    successful receipts disagree on target -- shouldn't happen in practice
    (one `patterns scan` invocation writes every rule's receipt with the
    same target) but a defensively unioned legacy id must not silently pick
    one of several disagreeing targets. Both cases fall back to the
    conservative root scope ('.') at the call site, never to an unrelated
    failed attempt's target. Checks pattern_rule_runs and, when present,
    the pattern_rule_runs_v9 backup table -- this runs before
    _migrate_v10_repair_stranded_backups merges a backup stranded by an
    interrupted prior rebuild into the live table, so a backup-only id's
    target would otherwise be invisible here.
    """
    targets: set[str] = set()
    for table in ("pattern_rule_runs", "pattern_rule_runs_v9"):
        try:
            rows = conn.execute(
                f"SELECT DISTINCT target FROM {table} "
                "WHERE scan_id = ? AND status = 'success' "
                "AND target IS NOT NULL AND target != ''",
                (run_id,),
            ).fetchall()
        except sqlite3.OperationalError:
            continue  # no _v9 backup table -- the common case
        targets.update(str(row[0]) for row in rows)
    return next(iter(targets)) if len(targets) == 1 else None


_PATTERN_FINDINGS_V10_COLS = "id, scan_id, finding_key, path, rule_id, line, col, match_text, severity"
_PATTERN_FINDINGS_V10_DDL = """
    CREATE TABLE pattern_findings (
        id          INTEGER PRIMARY KEY,
        scan_id     INTEGER NOT NULL,
        finding_key TEXT,
        path        TEXT NOT NULL,
        rule_id     TEXT NOT NULL,
        line        INTEGER NOT NULL,
        col         INTEGER DEFAULT 0,
        match_text  TEXT,
        severity    TEXT DEFAULT 'warning',
        FOREIGN KEY(scan_id) REFERENCES pattern_runs(id) ON DELETE CASCADE
    )
"""
_PATTERN_RULE_RUNS_V10_COLS = (
    "scan_id, rule_id, definition_hash, rule_path, target, status, hits, error, ran_at"
)
_PATTERN_RULE_RUNS_V10_DDL = """
    CREATE TABLE pattern_rule_runs (
        scan_id          INTEGER NOT NULL,
        rule_id          TEXT NOT NULL,
        definition_hash  TEXT NOT NULL,
        rule_path        TEXT NOT NULL,
        target           TEXT NOT NULL,
        status           TEXT NOT NULL,
        hits             INTEGER,
        error            TEXT,
        ran_at           TEXT NOT NULL,
        FOREIGN KEY(scan_id) REFERENCES pattern_runs(id) ON DELETE CASCADE,
        PRIMARY KEY(scan_id, rule_id)
    )
"""
# One (live table name, backup-columns, CREATE TABLE ddl) triple per table
# _migrate_v10_rebuild_pattern_tables rebuilds -- see there and
# _migrate_v10_repair_stranded_backups.
_PATTERN_V10_REBUILD_TABLES = (
    ("pattern_findings", _PATTERN_FINDINGS_V10_COLS, _PATTERN_FINDINGS_V10_DDL),
    ("pattern_rule_runs", _PATTERN_RULE_RUNS_V10_COLS, _PATTERN_RULE_RUNS_V10_DDL),
)


class PatternMigrationConflictError(RuntimeError):
    """A stranded _v9 backup row conflicts with a live row under the same
    meaningful key, and neither can be safely discarded automatically."""


def _backup_exists(conn: sqlite3.Connection, backup: str) -> bool:
    return (
        conn.execute(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", (backup,)
        ).fetchone()
        is not None
    )


def _merge_pattern_findings_backup(conn: sqlite3.Connection) -> None:
    """Merge pattern_findings_v9 into pattern_findings, preserving distinct
    finding identities on an id collision.

    pattern_findings.id is a local surrogate key -- nothing else references
    it; finding identity, adjudication, and occurrence tracking all key off
    finding_key instead (see pattern_finding_state/pattern_finding_occurrences).
    A plain `INSERT OR IGNORE ... SELECT` is only safe when a colliding id
    holds the SAME row twice (the idempotent already-copied case). If a
    fresh pattern run claimed that id for an unrelated finding in between an
    interrupted rebuild and this repair running, INSERT OR IGNORE would
    silently keep the live row and discard the backup's -- then the
    unconditional DROP TABLE that followed permanently lost it. Compares
    full row content on id collision instead: identical content is skipped
    (already merged), distinct content is inserted under a fresh id (the
    exact value was never meaningful) so neither finding is lost.
    """
    cols = ("scan_id", "finding_key", "path", "rule_id", "line", "col", "match_text", "severity")
    col_list = ", ".join(cols)
    for row in conn.execute(f"SELECT id, {col_list} FROM pattern_findings_v9").fetchall():
        existing = conn.execute(
            f"SELECT {col_list} FROM pattern_findings WHERE id = ?", (row["id"],)
        ).fetchone()
        if existing is None:
            conn.execute(
                f"INSERT INTO pattern_findings (id, {col_list}) "
                f"VALUES (?, {', '.join('?' for _ in cols)})",
                (row["id"], *(row[c] for c in cols)),
            )
        elif tuple(existing[c] for c in cols) != tuple(row[c] for c in cols):
            # Same id, DIFFERENT finding -- both are real; give the backup
            # row a fresh id instead of losing it.
            conn.execute(
                f"INSERT INTO pattern_findings ({col_list}) "
                f"VALUES ({', '.join('?' for _ in cols)})",
                tuple(row[c] for c in cols),
            )
        # else: identical content already present -- already merged, no-op.
    conn.execute("DROP TABLE pattern_findings_v9")


def _merge_pattern_rule_runs_backup(conn: sqlite3.Connection) -> None:
    """Merge pattern_rule_runs_v9 into pattern_rule_runs.

    Unlike pattern_findings.id, (scan_id, rule_id) is pattern_rule_runs'
    real primary key -- report/list read receipts by it, so a genuine
    content collision means two different runs' evidence is being
    conflated, not just a harmless reinsert. INSERT OR IGNORE would
    silently keep whichever row happened to already be live and this
    repair would then drop the backup, permanently discarding the other.
    Raises PatternMigrationConflictError and leaves the backup in place
    instead of guessing which receipt is right -- every init_db() call
    will keep raising until a human resolves it, which is the point: this
    should never happen in practice (the id-collision path in
    _merge_pattern_findings_backup handles the realistic case), so failing
    loudly is safer than a heuristic that might pick the wrong receipt.
    """
    cols = ("definition_hash", "rule_path", "target", "status", "hits", "error", "ran_at")
    col_list = ", ".join(cols)
    rows = conn.execute(
        f"SELECT scan_id, rule_id, {col_list} FROM pattern_rule_runs_v9"
    ).fetchall()
    conflicts = []
    for row in rows:
        existing = conn.execute(
            f"SELECT {col_list} FROM pattern_rule_runs WHERE scan_id = ? AND rule_id = ?",
            (row["scan_id"], row["rule_id"]),
        ).fetchone()
        if existing is not None and tuple(existing[c] for c in cols) != tuple(
            row[c] for c in cols
        ):
            conflicts.append((row["scan_id"], row["rule_id"]))
    if conflicts:
        raise PatternMigrationConflictError(
            "pattern_rule_runs_v9 backup has receipts for "
            f"{conflicts} that conflict with the live pattern_rule_runs table -- "
            "refusing to merge or drop the backup; needs manual inspection"
        )
    conn.execute(
        f"INSERT OR IGNORE INTO pattern_rule_runs (scan_id, rule_id, {col_list}) "
        f"SELECT scan_id, rule_id, {col_list} FROM pattern_rule_runs_v9"
    )
    conn.execute("DROP TABLE pattern_rule_runs_v9")


def _migrate_v10_repair_stranded_backups(conn: sqlite3.Connection) -> None:
    """Merge and drop a pattern_findings_v9/pattern_rule_runs_v9 stranded by
    an interruption during an earlier, non-atomic version of
    _migrate_v10_rebuild_pattern_tables.

    executescript() commits any pending transaction before running, and DDL
    auto-commits statement-by-statement under the default isolation level --
    so the old rename/create/copy/drop sequence was not atomic. A crash
    right after the rename left a live `pattern_findings` name gone; on
    restart _SCHEMA's `CREATE TABLE IF NOT EXISTS pattern_findings` then
    silently recreated it fresh, already correctly FK'd to pattern_runs --
    which makes the ordinary FK-based rebuild check below think nothing
    needs doing, stranding the old rows in `pattern_findings_v9` forever.

    Runs per table independently (a crash between the two ALTER RENAMEs can
    strand only one of them); each table's own merge function (see
    _merge_pattern_findings_backup / _merge_pattern_rule_runs_backup)
    decides how to handle a key collision, since pattern_findings.id and
    pattern_rule_runs' (scan_id, rule_id) have very different collision
    semantics. Must run AFTER _migrate_v10's legacy-id reservation
    (_legacy_pattern_run_ids already looks inside a stranded backup so
    those ids get reserved too), not before -- the merge INSERTs go into
    the live pattern_findings/pattern_rule_runs, which are FK'd to
    pattern_runs, and foreign_keys enforcement is ON for this connection
    (see _SCHEMA), so a scan_id with no pattern_runs row yet would fail the
    merge outright.
    """
    if _backup_exists(conn, "pattern_findings_v9"):
        _merge_pattern_findings_backup(conn)
    if _backup_exists(conn, "pattern_rule_runs_v9"):
        _merge_pattern_rule_runs_backup(conn)
    conn.commit()


def _migrate_v10_rebuild_pattern_tables(conn: sqlite3.Connection) -> None:
    """Rebuild pattern_findings/pattern_rule_runs off pattern_runs, atomically.

    Each table still FK'd to scan_meta (the complexity-scan sequence, from
    before pattern scans had their own identity) is renamed to a `_v9`
    backup, recreated against pattern_runs, refilled from the backup
    (preserving ids/scan_ids, so pattern_finding_occurrences/
    pattern_finding_state need no rewrite), and the backup dropped. A table
    already rebuilt (by a completed prior run of this function, or one whose
    FK was independently repaired) is left untouched.

    Unlike the old executescript()-based version, this drives the whole
    thing -- both tables and the resulting indexes -- through one explicit
    BEGIN/COMMIT with isolation_level temporarily disabled (so we control
    the transaction boundary by hand instead of Python's sqlite3 module
    auto-committing each DDL statement individually, which is its default
    behavior and defeats SQLite's own real transactional-DDL support). An
    interruption anywhere in this function now leaves the database exactly
    as it was before the call -- see _migrate_v10_repair_stranded_backups
    for recovering a database already left stranded by the old version.
    """
    prior_isolation = conn.isolation_level
    conn.isolation_level = None  # autocommit driver mode; we run BEGIN/COMMIT ourselves
    try:
        conn.execute("BEGIN")
        for table, cols, ddl in _PATTERN_V10_REBUILD_TABLES:
            fk_rows = conn.execute(f"PRAGMA foreign_key_list({table})").fetchall()
            if not any(row["table"] == "scan_meta" for row in fk_rows):
                continue
            backup = f"{table}_v9"
            conn.execute(f"ALTER TABLE {table} RENAME TO {backup}")
            conn.execute(ddl)
            conn.execute(f"INSERT INTO {table} ({cols}) SELECT {cols} FROM {backup}")
            conn.execute(f"DROP TABLE {backup}")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_pf_scan ON pattern_findings(scan_id)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_pf_rule ON pattern_findings(rule_id)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_pf_key ON pattern_findings(finding_key)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_prr_scan ON pattern_rule_runs(scan_id)")
        conn.commit()
    except BaseException:
        conn.rollback()
        raise
    finally:
        conn.isolation_level = prior_isolation


def _migrate_v10_rebuild_stale_origin_default(conn: sqlite3.Connection) -> None:
    """Rebuild pattern_runs when its `origin` column's DEFAULT is stale.

    `CREATE TABLE IF NOT EXISTS` never updates an existing table's schema
    -- a pattern_runs table created before the canonical schema's default
    changed from 'legacy' to 'unknown' (wv-4ebbc1) keeps that OLD 'legacy'
    default forever; the ALTER-added-column branch above only runs when
    `origin` is missing entirely, not when it already exists with a stale
    default. Every row already written carries its own explicit, correct
    `origin` value regardless of the table's default -- that's untouched
    here -- but a FUTURE writer that omits the column entirely (a
    pre-origin or downgraded writer, on this now-already-current-schema
    database) would still silently inherit 'legacy' from this table's own
    stale default, reopening the exact promotion-to-finished defect
    `origin` exists to prevent, reached via yet another writer path
    (wv-845388, wv-4ebbc1).

    SQLite has no ALTER TABLE ... ALTER COLUMN SET DEFAULT -- changing a
    column's default requires a full rebuild, following SQLite's own
    documented recipe for schema changes on a table with incoming FK
    references (pattern_findings/pattern_rule_runs both reference
    pattern_runs): build the replacement under a TEMPORARY name first,
    copy every row across unchanged, drop the ORIGINAL (not a renamed
    copy of it), then rename the replacement into the original's name.
    Two earlier, simpler-looking approaches were tried and rejected --
    both corrupt the database in ways only visible with real FK children
    present (which this repo's own test fixtures exercise):
      - Renaming pattern_runs itself out of the way, creating the fixed
        table under its final name, copying, then dropping the rename
        backup: SQLite treats DROPping a table that still has an
        INCOMING FK reference (even one that's been renamed away from)
        as deleting all its rows, which cascades -- silently wiping
        every pattern_findings/pattern_rule_runs row via their own
        ON DELETE CASCADE, even with `PRAGMA foreign_keys = OFF` set.
      - Suppressing SQLite's automatic FK-reference rewrite-on-rename
        (`PRAGMA legacy_alter_table = ON`) does not reliably apply
        together with `foreign_keys = OFF` -- combined, the referencing
        tables' FK clauses got REWRITTEN anyway, later failing with
        "no such table" once the renamed-away backup was dropped.
    Building the replacement under a fresh name and only ever DROPping
    the table that never had rows removed from under a live FK
    reference sidesteps both: nothing is ever renamed away WHILE still
    holding the rows a live FK still points at, and the final rename
    targets a name no live table currently holds. Run with
    `foreign_keys` off for the whole transaction (SQLite requires this
    pragma to be set outside any active transaction) and verified with
    `PRAGMA foreign_key_check` before committing.
    """
    table_info = conn.execute("PRAGMA table_info(pattern_runs)").fetchall()
    origin_col = next((row for row in table_info if row["name"] == "origin"), None)
    if origin_col is None or origin_col["dflt_value"] != "'legacy'":
        return  # column doesn't exist yet (handled above) or already current
    col_list = ", ".join(row["name"] for row in table_info)
    prior_isolation = conn.isolation_level
    conn.isolation_level = None  # autocommit driver mode; we run BEGIN/COMMIT ourselves
    # foreign_keys may only be toggled outside any active transaction --
    # must happen after switching to autocommit mode above, and before
    # BEGIN below.
    prior_fk = conn.execute("PRAGMA foreign_keys").fetchone()[0]
    conn.execute("PRAGMA foreign_keys = OFF")
    try:
        conn.execute("BEGIN")
        conn.execute("""
            CREATE TABLE pattern_runs_rebuilt (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                started_at  TEXT NOT NULL,
                git_head    TEXT NOT NULL,
                target      TEXT NOT NULL DEFAULT '.',
                files_count INTEGER,
                duration_ms INTEGER,
                finished_at TEXT,
                origin      TEXT NOT NULL DEFAULT 'unknown'
            )
        """)
        conn.execute(
            f"INSERT INTO pattern_runs_rebuilt ({col_list}) "
            f"SELECT {col_list} FROM pattern_runs"
        )
        conn.execute("DROP TABLE pattern_runs")
        conn.execute("ALTER TABLE pattern_runs_rebuilt RENAME TO pattern_runs")
        fk_violations = conn.execute("PRAGMA foreign_key_check").fetchall()
        if fk_violations:
            raise sqlite3.IntegrityError(
                f"pattern_runs origin-default rebuild left FK violations: {fk_violations}"
            )
        conn.commit()
    except BaseException:
        conn.rollback()
        raise
    finally:
        conn.isolation_level = prior_isolation
        conn.execute(f"PRAGMA foreign_keys = {prior_fk}")


def _migrate_v10(conn: sqlite3.Connection) -> None:
    """Give pattern scans an independent identity, decoupled from scan_meta.

    Prior schema FK'd pattern_findings/pattern_rule_runs to scan_meta(id) (the
    complexity-scan sequence). That forced `wv quality patterns scan` to
    reuse or fabricate a scan_meta row, so a rescan collided on that shared
    id (replace_pattern_scan_results wiped the prior invocation's occurrence
    history) and an unrelated `wv quality scan` pruned pattern data via
    scan_meta's own retention window. Rebuilds both tables against the new
    pattern_runs sequence, preserving existing rows -- and their `scan_id`
    values, so pattern_finding_occurrences/pattern_finding_state need no
    rewrite -- by backfilling one pattern_runs row per distinct legacy id.

    Legacy ids are reserved from pattern_finding_occurrences too, not just
    pattern_findings/pattern_rule_runs: under v9 retention a finding's raw
    row and receipt can be pruned while its occurrence rows (the durable
    scan_count/recurrence evidence) remain. Missing that union would leave
    such an id unreserved, so begin_pattern_run could hand it back out to a
    brand new run -- and replace_pattern_scan_results would then delete the
    old finding's occurrences for that id, silently zeroing its scan_count.
    This reservation pass runs unconditionally (not just when the FK still
    points at scan_meta) so it also repairs a database already migrated by
    an earlier version of this migration that had the same gap.
    """
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS pattern_runs (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            started_at  TEXT NOT NULL,
            git_head    TEXT NOT NULL,
            target      TEXT NOT NULL DEFAULT '.',
            files_count INTEGER,
            duration_ms INTEGER,
            finished_at TEXT,
            origin      TEXT NOT NULL DEFAULT 'unknown'
        );
    """)
    # A pattern_runs table created by an earlier version of this migration
    # (before finished_at/origin existed) needs the columns added before the
    # finished_at-aware backfill INSERT below can run against it.
    pr_cols = {row[1] for row in conn.execute("PRAGMA table_info(pattern_runs)").fetchall()}
    if "finished_at" not in pr_cols:
        conn.execute("ALTER TABLE pattern_runs ADD COLUMN finished_at TEXT")
    if "origin" not in pr_cols:
        # Every row that already exists at this point predates the origin
        # column -- but that population is NOT uniformly legacy: it mixes
        # true v9-derived backfills with NATIVE rows a pre-origin
        # begin_pattern_run inserted (between pattern_runs' introduction and
        # origin's), including a partial/interrupted one sitting on
        # finished_at = NULL. Defaulting them all to 'legacy' would hand an
        # interrupted native run straight to the evidence-based
        # reconstruction pass below and promote it to finished -- the exact
        # defect origin exists to prevent, just reached from the upgrade
        # path instead of a fresh insert. 'unknown' keeps such a row OUT of
        # that reconstruction (restricted to origin='legacy', see below)
        # rather than guessing; a genuine legacy backfill still gets
        # 'legacy' explicitly at INSERT time a few lines down, not via this
        # column's default.
        conn.execute("ALTER TABLE pattern_runs ADD COLUMN origin TEXT NOT NULL DEFAULT 'unknown'")
    _migrate_v10_rebuild_stale_origin_default(conn)
    # Includes ids only present in a pattern_findings_v9/pattern_rule_runs_v9
    # backup (stranded by an interrupted prior rebuild), so they get reserved
    # here too -- before _migrate_v10_repair_stranded_backups merges that
    # backup into the live, FK'd-to-pattern_runs tables below.
    legacy_ids = _legacy_pattern_run_ids(conn)
    existing_ids = {row[0] for row in conn.execute("SELECT id FROM pattern_runs").fetchall()}
    for legacy_id in sorted(legacy_ids - existing_ids):
        meta = conn.execute(
            "SELECT scanned_at, git_head FROM scan_meta WHERE id = ?", (legacy_id,)
        ).fetchone()
        started_at = meta["scanned_at"] if meta else time.strftime("%Y-%m-%dT%H:%M:%S")
        git_head = meta["git_head"] if meta else ""
        # A backfilled legacy id only counts as "finished" (successful) for
        # retention purposes when it has real v9 evidence attached -- a scan_id
        # that appears ONLY via a failed pattern_rule_runs receipt (every rule
        # errored, nothing ever matched) is not a completed scan and must stay
        # in the unfinished window like any other failed run.
        finished_at = started_at if _pattern_run_has_finished_evidence(conn, legacy_id) else None
        # A legacy id's real target lives on its receipts, not on scan_meta
        # (which never recorded one) -- `report`/`list` now scope directly
        # from pattern_runs.target (see wv-40d3d6), so hardcoding "." here
        # would silently turn every migrated scoped scan (e.g. of "docs")
        # into a repo-root-scoped one. Falls back to "." only for an
        # occurrence-only id (no receipts to read a target from at all) or
        # one whose receipts genuinely disagree.
        target = _pattern_run_receipt_target(conn, legacy_id) or "."
        # origin is stamped explicitly here, not left to the column default
        # (which is 'unknown' for the ALTER-added-column path above) -- this
        # row really is a v9-derived legacy backfill, so it must stay
        # eligible for the evidence-based finished_at reconstruction pass
        # below regardless of which branch added the origin column.
        conn.execute(
            "INSERT OR IGNORE INTO pattern_runs "
            "(id, started_at, git_head, target, finished_at, origin) "
            "VALUES (?, ?, ?, ?, ?, 'legacy')",
            (legacy_id, started_at, git_head, target, finished_at),
        )
    # A pattern_runs row that already existed before this migration ran --
    # backfilled by an earlier, buggier version of this same migration (one
    # that inserted legacy rows without setting finished_at at all) -- can be
    # sitting on finished_at = NULL despite having real v9 evidence attached.
    # Left alone, those rows fall into the small unfinished-run retention
    # window and get evicted by ordinary scan failures, silently deleting an
    # already-successful run's findings. Reclassify from the same evidence
    # used above; a genuinely interrupted/failed run has none and stays NULL.
    #
    # Restricted to origin='legacy': a 'native' row (begin_pattern_run
    # inserted it this run or an earlier one, after the origin column
    # shipped) or an 'unknown' row (origin-less at ALTER time, ambiguous
    # provenance -- see above) reaching this migration with finished_at
    # still NULL is, as far as this migration can tell, a genuinely
    # unfinished/interrupted/failed invocation -- e.g. a crash, or a later
    # rule's failure, between two of record_pattern_rule_success's immediate
    # per-rule receipt commits (see wv-29aeb0). Applying the same evidence
    # heuristic to it would promote that partial run to "finished" on the
    # next database open, even though finish_pattern_run never ran. Only a
    # legacy row -- whose finished_at was never meant to come from an
    # explicit finish_pattern_run call in the first place -- may have it
    # reconstructed from evidence.
    for row in conn.execute(
        "SELECT id, started_at FROM pattern_runs WHERE finished_at IS NULL AND origin = 'legacy'"
    ).fetchall():
        if row["id"] in existing_ids and _pattern_run_has_finished_evidence(conn, row["id"]):
            conn.execute(
                "UPDATE pattern_runs SET finished_at = ? WHERE id = ?",
                (row["started_at"], row["id"]),
            )
    # Likewise, an already-migrated row (backfilled by an earlier version of
    # this migration) can be sitting on the wrong scope: one buggy version
    # always hardcoded target="."; another used ANY receipt's target
    # (including a later, unrelated FAILED attempt reusing the same v9
    # scan_id -- see wv-367b1c) regardless of whether it actually described
    # the surviving findings. Reclassify every row with any evidence at all
    # (a finding, an occurrence, or a successful receipt) from that
    # evidence -- not just rows currently sitting on "." -- so a
    # previously-mis-scoped non-"." value gets corrected too, not just ever
    # revisited if it happened to already read ".". A row with NO evidence
    # of any kind is left untouched: that's a genuinely modern failed run
    # (begin_pattern_run already recorded its real target correctly at
    # creation time, and a clean failure publishes no findings/occurrences
    # under it to reclassify from), not a legacy-migration artifact.
    for row in conn.execute("SELECT id, target FROM pattern_runs").fetchall():
        if not _pattern_run_has_finished_evidence(conn, row["id"]):
            continue
        receipt_target = _pattern_run_receipt_target(conn, row["id"])
        correct_target = receipt_target if receipt_target is not None else "."
        if row["target"] != correct_target:
            conn.execute(
                "UPDATE pattern_runs SET target = ? WHERE id = ?",
                (correct_target, row["id"]),
            )
    conn.commit()

    # Every id a stranded backup could reference is now reserved in
    # pattern_runs above, so this merge into the live FK'd tables is safe.
    _migrate_v10_repair_stranded_backups(conn)
    # Rebuilds whichever of pattern_findings/pattern_rule_runs is still FK'd
    # to scan_meta, atomically -- see _migrate_v10_rebuild_pattern_tables.
    # A table already rebuilt is a fast no-op (one PRAGMA check).
    _migrate_v10_rebuild_pattern_tables(conn)


def init_db(hot_zone: str | None = None) -> sqlite3.Connection:
    """Initialise quality.db, creating schema if needed.

    Returns an open connection. The caller is responsible for closing it.
    """
    resolved = _resolve_db_path(hot_zone)
    resolved.parent.mkdir(parents=True, exist_ok=True)

    conn = sqlite3.connect(str(resolved))
    conn.row_factory = sqlite3.Row
    conn.executescript(_SCHEMA)
    _migrate_v2(conn)
    _migrate_v3(conn)
    _migrate_v4(conn)
    _migrate_v5(conn)
    _migrate_v6(conn)
    _migrate_v7(conn)
    _migrate_v8(conn)
    _migrate_v9(conn)
    _migrate_v10(conn)
    log.debug("quality.db initialised at %s", resolved)
    return conn


def db_path(hot_zone: str | None = None) -> Path:
    """Return the resolved quality.db path (may not exist yet)."""
    return _resolve_db_path(hot_zone)


def db_exists(hot_zone: str | None = None) -> bool:
    """Check whether quality.db exists."""
    return _resolve_db_path(hot_zone).exists()


def reset_db(hot_zone: str | None = None) -> None:
    """Delete quality.db entirely (wv quality reset)."""
    p = _resolve_db_path(hot_zone)
    if p.exists():
        p.unlink()
        log.info("Deleted quality.db at %s", p)


# ---------------------------------------------------------------------------
# Scan lifecycle
# ---------------------------------------------------------------------------


def begin_scan(
    conn: sqlite3.Connection,
    git_head: str,
    scanner_version: str = "",
    bash_cc_backend: str = "regex",
    ts_cc_backend: str = "unavailable",
) -> int:
    """Record a new scan, prune old scans beyond retention limit.

    Returns the new scan_id.
    """
    cur = conn.execute(
        "INSERT INTO scan_meta (scanned_at, git_head, scanner_version, bash_cc_backend, ts_cc_backend) "
        "VALUES (?, ?, ?, ?, ?)",
        (time.strftime("%Y-%m-%dT%H:%M:%S"), git_head, scanner_version, bash_cc_backend, ts_cc_backend),
    )
    scan_id = cur.lastrowid
    assert scan_id is not None

    # Step 1: Prune files + file_metrics to the diff window (_FILES_SCANS).
    # We do this explicitly because scan_meta now keeps more rows, so the
    # CASCADE on scan_meta won't fire for these tables until later.
    conn.execute(
        """DELETE FROM files WHERE scan_id NOT IN (
            SELECT id FROM scan_meta ORDER BY id DESC LIMIT ?
        )""",
        (_FILES_SCANS,),
    )
    conn.execute(
        """DELETE FROM file_metrics WHERE scan_id NOT IN (
            SELECT id FROM scan_meta ORDER BY id DESC LIMIT ?
        )""",
        (_FILES_SCANS,),
    )
    # pattern_findings/pattern_rule_runs are NOT pruned here -- they key off
    # pattern_runs(id), a sequence independent of scan_meta, so an unrelated
    # `wv quality scan` must not touch pattern-scan history. See
    # begin_pattern_run for their own retention window.
    # Step 2: Prune scan_meta to trend window (_MAX_SCANS).
    # CASCADE will drop any complexity_trend rows for the removed scans.
    conn.execute(
        """DELETE FROM scan_meta WHERE id NOT IN (
            SELECT id FROM scan_meta ORDER BY id DESC LIMIT ?
        )""",
        (_MAX_SCANS,),
    )
    log.debug("Scan %d started (head=%s)", scan_id, git_head[:8])
    return scan_id


def finish_scan(
    conn: sqlite3.Connection,
    scan_id: int,
    files_count: int,
    duration_ms: int,
    bash_cc_backend: str | None = None,
    ts_cc_backend: str | None = None,
) -> None:
    """Finalise a scan with counts and duration.

    bash_cc_backend / ts_cc_backend, if provided, overwrite the placeholder set at
    begin_scan time with the actual aggregate backend used across all files.
    """
    sets = ["files_count = ?", "duration_ms = ?"]
    params: list[object] = [files_count, duration_ms]
    if bash_cc_backend is not None:
        sets.append("bash_cc_backend = ?")
        params.append(bash_cc_backend)
    if ts_cc_backend is not None:
        sets.append("ts_cc_backend = ?")
        params.append(ts_cc_backend)
    params.append(scan_id)
    conn.execute(f"UPDATE scan_meta SET {', '.join(sets)} WHERE id = ?", params)


def latest_scan(conn: sqlite3.Connection) -> ScanMeta | None:
    """Get the most recent scan metadata, or None."""
    row = conn.execute("SELECT * FROM scan_meta ORDER BY id DESC LIMIT 1").fetchone()
    if not row:
        return None
    return ScanMeta(
        id=row["id"],
        scanned_at=row["scanned_at"],
        git_head=row["git_head"],
        files_count=row["files_count"] or 0,
        duration_ms=row["duration_ms"] or 0,
        scanner_version=row["scanner_version"] or "",
        bash_cc_backend=row["bash_cc_backend"] or "regex",
        ts_cc_backend=row["ts_cc_backend"] or "unavailable",
    )


def previous_scan(conn: sqlite3.Connection) -> ScanMeta | None:
    """Get the second-most-recent scan (for delta reports), or None."""
    rows = conn.execute("SELECT * FROM scan_meta ORDER BY id DESC LIMIT 2").fetchall()
    if len(rows) < 2:
        return None
    row = rows[1]
    return ScanMeta(
        id=row["id"],
        scanned_at=row["scanned_at"],
        git_head=row["git_head"],
        files_count=row["files_count"] or 0,
        duration_ms=row["duration_ms"] or 0,
        scanner_version=row["scanner_version"] or "",
        bash_cc_backend=row["bash_cc_backend"] or "regex",
        ts_cc_backend=row["ts_cc_backend"] or "unavailable",
    )


# ---------------------------------------------------------------------------
# Pattern-run lifecycle (independent of scan_meta -- see pattern_runs table)
# ---------------------------------------------------------------------------


def _prune_pattern_runs(conn: sqlite3.Connection) -> None:
    """Bound pattern_runs growth without evicting the last successful runs.

    Retention counts finished (finished_at IS NOT NULL, i.e. completed via
    finish_pattern_run) and unfinished (in-progress or failed) runs against
    SEPARATE _MAX_PATTERN_RUNS windows. A chain of failed `patterns scan`
    invocations only ever accumulates unfinished rows -- pruning them
    against their own window (instead of one shared window with finished
    runs) means N failures in a row can never evict an earlier successful
    run's findings just because it happens to sort before them by id.
    """
    conn.execute(
        """DELETE FROM pattern_runs WHERE finished_at IS NOT NULL AND id NOT IN (
            SELECT id FROM pattern_runs WHERE finished_at IS NOT NULL
            ORDER BY id DESC LIMIT ?
        )""",
        (_MAX_PATTERN_RUNS,),
    )
    conn.execute(
        """DELETE FROM pattern_runs WHERE finished_at IS NULL AND id NOT IN (
            SELECT id FROM pattern_runs WHERE finished_at IS NULL
            ORDER BY id DESC LIMIT ?
        )""",
        (_MAX_PATTERN_RUNS,),
    )


def begin_pattern_run(conn: sqlite3.Connection, git_head: str, target: str) -> int:
    """Record a new `patterns scan` run, prune old runs beyond retention.

    Returns the new pattern run id. Every `wv quality patterns scan`
    invocation calls this exactly once -- unlike the old scheme, it never
    reuses a prior run's id, so replace_pattern_scan_results never wipes
    another invocation's occurrence history. Pruning runs after the new
    (unfinished) row is inserted, using _prune_pattern_runs' split
    finished/unfinished windows -- a run that's about to fail only ever
    competes with other unfinished rows for its window, so it can never
    evict an earlier successful (finished) run to make room for itself.

    Always stamps origin='native' -- only finish_pattern_run may set this
    row's finished_at afterward; _migrate_v10's evidence-based finished_at
    reconstruction is restricted to origin='legacy' rows and must never
    promote a partial/interrupted native run to finished (see wv-033ec6).
    """
    cur = conn.execute(
        "INSERT INTO pattern_runs (started_at, git_head, target, origin) "
        "VALUES (?, ?, ?, 'native')",
        (time.strftime("%Y-%m-%dT%H:%M:%S"), git_head, target),
    )
    run_id = cur.lastrowid
    assert run_id is not None
    _prune_pattern_runs(conn)
    conn.commit()
    log.debug("Pattern run %d started (head=%s, target=%s)", run_id, git_head[:8], target)
    return run_id


def finish_pattern_run(
    conn: sqlite3.Connection, run_id: int, files_count: int, duration_ms: int
) -> None:
    """Finalise a pattern run with counts and duration, marking it completed."""
    conn.execute(
        "UPDATE pattern_runs SET files_count = ?, duration_ms = ?, finished_at = ? "
        "WHERE id = ?",
        (files_count, duration_ms, time.strftime("%Y-%m-%dT%H:%M:%S"), run_id),
    )
    _prune_pattern_runs(conn)
    conn.commit()


def latest_pattern_run(conn: sqlite3.Connection) -> PatternRun | None:
    """Get the most recent pattern run, or None if `patterns scan` never ran."""
    row = conn.execute("SELECT * FROM pattern_runs ORDER BY id DESC LIMIT 1").fetchone()
    if not row:
        return None
    return PatternRun(
        id=row["id"],
        started_at=row["started_at"],
        git_head=row["git_head"],
        target=row["target"] or ".",
        files_count=row["files_count"] or 0,
        duration_ms=row["duration_ms"] or 0,
    )


# ---------------------------------------------------------------------------
# files table CRUD
# ---------------------------------------------------------------------------


def upsert_file_entry(conn: sqlite3.Connection, entry: FileEntry) -> None:
    """Insert or update a file entry for a scan."""
    d = entry.to_dict()
    conn.execute(
        """INSERT INTO files (path, scan_id, language, loc,
            complexity, functions, max_nesting, avg_fn_len,
            essential_complexity, indent_sd, category)
        VALUES (:path, :scan_id, :language, :loc,
            :complexity, :functions, :max_nesting, :avg_fn_len,
            :essential_complexity, :indent_sd, :category)
        ON CONFLICT(path, scan_id) DO UPDATE SET
            language=excluded.language, loc=excluded.loc,
            complexity=excluded.complexity,
            functions=excluded.functions,
            max_nesting=excluded.max_nesting,
            avg_fn_len=excluded.avg_fn_len,
            essential_complexity=excluded.essential_complexity,
            indent_sd=excluded.indent_sd,
            category=excluded.category
        """,
        d,
    )


def bulk_upsert_file_entries(
    conn: sqlite3.Connection, entries: list[FileEntry]
) -> None:
    """Insert/update a batch of file entries."""
    for entry in entries:
        upsert_file_entry(conn, entry)


def get_file_entries(
    conn: sqlite3.Connection, scan_id: int, path: str | None = None
) -> list[FileEntry]:
    """Retrieve file entries for a scan, optionally filtered by path."""
    if path:
        rows = conn.execute(
            "SELECT * FROM files WHERE scan_id = ? AND path = ?",
            (scan_id, path),
        ).fetchall()
    else:
        rows = conn.execute(
            "SELECT * FROM files WHERE scan_id = ?",
            (scan_id,),
        ).fetchall()
    return [FileEntry.from_dict(dict(r)) for r in rows]


# ---------------------------------------------------------------------------
# file_metrics (CK EAV) CRUD
# ---------------------------------------------------------------------------


def upsert_ck_metrics(conn: sqlite3.Connection, ck: CKMetrics) -> None:
    """Insert or update CK metrics rows for a file."""
    for row in ck.to_rows():
        conn.execute(
            """INSERT INTO file_metrics (path, scan_id, metric, value)
            VALUES (:path, :scan_id, :metric, :value)
            ON CONFLICT(path, scan_id, metric) DO UPDATE SET value=excluded.value
            """,
            row,
        )


def get_ck_metrics(
    conn: sqlite3.Connection, scan_id: int, path: str
) -> CKMetrics | None:
    """Get CK metrics for a file in a scan.

    Excludes per-function CC rows (fn_cc:*) which share the same
    EAV table but are not CK-suite metrics.
    """
    rows = conn.execute(
        "SELECT * FROM file_metrics "
        "WHERE scan_id = ? AND path = ? AND metric NOT LIKE 'fn_cc:%'",
        (scan_id, path),
    ).fetchall()
    return CKMetrics.from_rows([dict(r) for r in rows])


# ---------------------------------------------------------------------------
# Per-function CC (EAV in file_metrics with detail column)
# ---------------------------------------------------------------------------


def upsert_function_cc(conn: sqlite3.Connection, fn: FunctionCC) -> None:
    """Insert or update per-function CC in file_metrics EAV."""
    row = fn.to_eav_row()
    conn.execute(
        """INSERT INTO file_metrics
            (path, scan_id, metric, value, detail)
        VALUES (:path, :scan_id, :metric, :value, :detail)
        ON CONFLICT(path, scan_id, metric) DO UPDATE SET
            value=excluded.value, detail=excluded.detail
        """,
        row,
    )


def bulk_upsert_function_cc(conn: sqlite3.Connection, fns: list[FunctionCC]) -> None:
    """Batch insert per-function CC rows."""
    for fn in fns:
        upsert_function_cc(conn, fn)


def get_function_cc(
    conn: sqlite3.Connection, scan_id: int, path: str
) -> list[FunctionCC]:
    """Get per-function CC entries for a file in a scan."""
    rows = conn.execute(
        """SELECT * FROM file_metrics
        WHERE scan_id = ? AND path = ? AND metric LIKE 'fn_cc:%'""",
        (scan_id, path),
    ).fetchall()
    return _rows_to_function_cc(rows)


def get_all_function_cc(conn: sqlite3.Connection, scan_id: int) -> list[FunctionCC]:
    """Get all per-function CC entries for a scan (all files)."""
    rows = conn.execute(
        """SELECT * FROM file_metrics
        WHERE scan_id = ? AND metric LIKE 'fn_cc:%'""",
        (scan_id,),
    ).fetchall()
    return _rows_to_function_cc(rows)


def _rows_to_function_cc(rows: list[Any]) -> list[FunctionCC]:
    """Convert DB rows to FunctionCC objects."""
    results: list[FunctionCC] = []
    for r in rows:
        d = dict(r)
        fn_name = d["metric"].removeprefix("fn_cc:").rsplit("@", 1)[0]
        detail = json.loads(d["detail"]) if d.get("detail") else {}
        results.append(
            FunctionCC(
                path=d["path"],
                scan_id=d["scan_id"],
                function_name=fn_name,
                complexity=float(d["value"]),
                line_start=detail.get("line_start", 0),
                line_end=detail.get("line_end", 0),
                essential_complexity=detail.get("essential_complexity", 1.0),
                is_dispatch=detail.get("is_dispatch", False),
            )
        )
    return results


# ---------------------------------------------------------------------------
# Complexity trend tracking
# ---------------------------------------------------------------------------


def upsert_complexity_trend(
    conn: sqlite3.Connection,
    path: str,
    scan_id: int,
    complexity: float,
    essential: float,
) -> None:
    """Record complexity snapshot for trend analysis."""
    conn.execute(
        """INSERT INTO complexity_trend
            (path, scan_id, complexity, essential)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(path, scan_id) DO UPDATE SET
            complexity=excluded.complexity,
            essential=excluded.essential
        """,
        (path, scan_id, complexity, essential),
    )


def compute_trend_direction(values: list[float]) -> str:
    """Classify trend direction from a list of ordered complexity values.

    Uses least-squares slope over the scan sequence (x = scan position 0..N-1).
    Relative slope (slope / mean) determines classification:
      > +3% per scan  -> 'deteriorating'
      < -3% per scan  -> 'refactored'
      otherwise       -> 'stable'

    Returns 'stable' when fewer than 2 data points are available.
    """
    n = len(values)
    if n < 2:
        return "stable"
    x_mean = (n - 1) / 2.0
    y_mean = sum(values) / n
    numerator = sum((i - x_mean) * (v - y_mean) for i, v in enumerate(values))
    denominator = sum((i - x_mean) ** 2 for i in range(n))
    if denominator == 0 or y_mean == 0:
        return "stable"
    rel_slope = (numerator / denominator) / y_mean
    if rel_slope > 0.03:
        return "deteriorating"
    if rel_slope < -0.03:
        return "refactored"
    return "stable"


def get_all_trend_directions(conn: sqlite3.Connection) -> dict[str, str]:
    """Compute trend direction for every file tracked in complexity_trend.

    Returns a dict mapping path -> 'deteriorating' | 'stable' | 'refactored'.
    Files with only one scan point are classified as 'stable'.
    """
    rows = conn.execute(
        """SELECT path, complexity FROM complexity_trend
           ORDER BY path, scan_id ASC"""
    ).fetchall()
    history: dict[str, list[float]] = {}
    for row in rows:
        path, complexity = row[0], float(row[1] or 0.0)
        history.setdefault(path, []).append(complexity)
    return {path: compute_trend_direction(vals) for path, vals in history.items()}


# ---------------------------------------------------------------------------
# git_stats CRUD (NOT scan-versioned)
# ---------------------------------------------------------------------------


def upsert_git_stats(conn: sqlite3.Connection, stats: GitStats) -> None:
    """Insert or update git stats for a file."""
    d = stats.to_dict()
    conn.execute(
        """INSERT INTO git_stats
            (path, churn, authors, age_days, hotspot,
             ownership_fraction, minor_contributors)
        VALUES
            (:path, :churn, :authors, :age_days, :hotspot,
             :ownership_fraction, :minor_contributors)
        ON CONFLICT(path) DO UPDATE SET
            churn=excluded.churn, authors=excluded.authors,
            age_days=excluded.age_days, hotspot=excluded.hotspot,
            ownership_fraction=excluded.ownership_fraction,
            minor_contributors=excluded.minor_contributors
        """,
        d,
    )


def bulk_upsert_git_stats(conn: sqlite3.Connection, stats_list: list[GitStats]) -> None:
    """Insert/update a batch of git stats."""
    for stats in stats_list:
        upsert_git_stats(conn, stats)


def get_git_stats(conn: sqlite3.Connection, path: str | None = None) -> list[GitStats]:
    """Get git stats, optionally for a single file."""
    if path:
        rows = conn.execute(
            "SELECT * FROM git_stats WHERE path = ?",
            (path,),
        ).fetchall()
    else:
        rows = conn.execute("SELECT * FROM git_stats").fetchall()
    return [GitStats.from_dict(dict(r)) for r in rows]


def top_hotspots(
    conn: sqlite3.Connection, top_n: int = 10, threshold: float = HOTSPOT_THRESHOLD
) -> list[GitStats]:
    """Get top N files above the hotspot threshold from git_stats."""
    rows = conn.execute(
        """SELECT * FROM git_stats
           WHERE hotspot > ?
           ORDER BY hotspot DESC LIMIT ?""",
        (threshold, top_n),
    ).fetchall()
    return [GitStats.from_dict(dict(r)) for r in rows]


# ---------------------------------------------------------------------------
# co_change CRUD
# ---------------------------------------------------------------------------


def upsert_co_change(conn: sqlite3.Connection, cc: CoChange) -> None:
    """Insert or update a co-change pair."""
    conn.execute(
        """INSERT INTO co_change (path_a, path_b, count)
        VALUES (?, ?, ?)
        ON CONFLICT(path_a, path_b) DO UPDATE SET count=excluded.count
        """,
        (cc.path_a, cc.path_b, cc.count),
    )


def bulk_upsert_co_changes(conn: sqlite3.Connection, pairs: list[CoChange]) -> None:
    """Replace all co-change pairs. Clears old data first."""
    conn.execute("DELETE FROM co_change")
    for cc in pairs:
        upsert_co_change(conn, cc)


def get_co_changes(
    conn: sqlite3.Connection, path: str | None = None, top_n: int = 10
) -> list[CoChange]:
    """Get co-change pairs, optionally involving a specific file."""
    if path:
        rows = conn.execute(
            """SELECT * FROM co_change
               WHERE path_a = ? OR path_b = ?
               ORDER BY count DESC LIMIT ?""",
            (path, path, top_n),
        ).fetchall()
    else:
        rows = conn.execute(
            "SELECT * FROM co_change ORDER BY count DESC LIMIT ?",
            (top_n,),
        ).fetchall()
    return [
        CoChange(path_a=r["path_a"], path_b=r["path_b"], count=r["count"]) for r in rows
    ]


# ---------------------------------------------------------------------------
# file_state CRUD (incremental scanning)
# ---------------------------------------------------------------------------


def upsert_file_state(conn: sqlite3.Connection, fs: FileState) -> None:
    """Insert or update file state for incremental tracking."""
    d = fs.to_dict()
    conn.execute(
        """INSERT INTO file_state (path, mtime, git_blob)
        VALUES (:path, :mtime, :git_blob)
        ON CONFLICT(path) DO UPDATE SET
            mtime=excluded.mtime, git_blob=excluded.git_blob
        """,
        d,
    )


def bulk_upsert_file_state(conn: sqlite3.Connection, states: list[FileState]) -> None:
    """Insert/update a batch of file states."""
    for fs in states:
        upsert_file_state(conn, fs)


def get_file_state(conn: sqlite3.Connection, path: str) -> FileState | None:
    """Get file state for a path, or None if not tracked."""
    row = conn.execute(
        "SELECT * FROM file_state WHERE path = ?",
        (path,),
    ).fetchone()
    if not row:
        return None
    return FileState.from_dict(dict(row))


def file_changed(
    conn: sqlite3.Connection, path: str, current_mtime: int, current_blob: str
) -> bool:
    """Check if a file has changed since last scan.

    Returns True if the file should be re-scanned.
    """
    fs = get_file_state(conn, path)
    if fs is None:
        return True  # Never scanned
    # Check blob SHA first (authoritative), fall back to mtime
    if current_blob and fs.git_blob:
        return current_blob != fs.git_blob
    return current_mtime != fs.mtime


# ---------------------------------------------------------------------------
# Staleness detection
# ---------------------------------------------------------------------------


def is_stale(conn: sqlite3.Connection, current_head: str) -> bool:
    """Check if the latest scan is stale (HEAD has moved since scan)."""
    scan = latest_scan(conn)
    if scan is None:
        return True  # No scan data = stale
    return scan.is_stale(current_head)


def staleness_info(conn: sqlite3.Connection, current_head: str) -> dict[str, Any]:
    """Return staleness details for reporting."""
    scan = latest_scan(conn)
    if scan is None:
        return {"stale": True, "reason": "no_scan_data", "scan": None}
    if scan.is_stale(current_head):
        return {
            "stale": True,
            "reason": "head_moved",
            "scan_head": scan.git_head[:8],
            "current_head": current_head[:8],
            "scan_time": scan.scanned_at,
        }
    return {
        "stale": False,
        "scan_head": scan.git_head[:8],
        "scan_time": scan.scanned_at,
        "files_count": scan.files_count,
    }


# ---------------------------------------------------------------------------
# pattern_findings CRUD
# ---------------------------------------------------------------------------


def bulk_insert_pattern_findings(
    conn: sqlite3.Connection, findings: list[PatternFinding]
) -> None:
    """Replace PatternFinding rows for the supplied scan IDs."""
    scan_ids = sorted({f.scan_id for f in findings})
    if scan_ids:
        conn.executemany(
            "DELETE FROM pattern_findings WHERE scan_id = ?",
            [(scan_id,) for scan_id in scan_ids],
        )
    conn.executemany(
        "INSERT INTO pattern_findings "
        "(scan_id, finding_key, path, rule_id, line, col, match_text, severity) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        [
            (
                f.scan_id, f.finding_key or None, f.path, f.rule_id,
                f.line, f.col, f.match_text, f.severity,
            )
            for f in findings
        ],
    )
    conn.commit()


def query_pattern_findings(
    conn: sqlite3.Connection,
    scan_id: int | None = None,
    rule_id: str | None = None,
    limit: int = 500,
) -> list[dict[str, object]]:
    """Return pattern findings as list of dicts, optionally filtered."""
    clauses: list[str] = []
    params: list[object] = []
    if scan_id is not None:
        clauses.append("scan_id = ?")
        params.append(scan_id)
    if rule_id is not None:
        clauses.append("rule_id = ?")
        params.append(rule_id)
    where = ("WHERE " + " AND ".join(clauses)) if clauses else ""
    rows = conn.execute(
        f"SELECT * FROM pattern_findings {where} ORDER BY rule_id, path, line LIMIT ?",
        params + [limit],
    ).fetchall()
    return [dict(r) for r in rows]


def pattern_findings_summary(
    conn: sqlite3.Connection, scan_id: int
) -> list[dict[str, object]]:
    """Return per-rule hit counts for a scan."""
    rows = conn.execute(
        "SELECT rule_id, COUNT(*) AS hits, MAX(severity) AS severity "
        "FROM pattern_findings WHERE scan_id = ? "
        "GROUP BY rule_id ORDER BY hits DESC",
        (scan_id,),
    ).fetchall()
    return [dict(r) for r in rows]


def replace_pattern_scan_results(
    conn: sqlite3.Connection,
    scan_id: int,
    findings: list[PatternFinding],
    runs: list[dict[str, object]],
) -> None:
    """Atomically replace findings and successful rule receipts for a scan."""
    old_keys = {
        str(row[0])
        for row in conn.execute(
            "SELECT finding_key FROM pattern_finding_occurrences WHERE scan_id = ?",
            (scan_id,),
        ).fetchall()
    }
    new_keys = {finding.finding_key for finding in findings}
    conn.execute("DELETE FROM pattern_findings WHERE scan_id = ?", (scan_id,))
    conn.execute("DELETE FROM pattern_rule_runs WHERE scan_id = ?", (scan_id,))
    conn.executemany(
        "INSERT INTO pattern_findings "
        "(scan_id, finding_key, path, rule_id, line, col, match_text, severity) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        [
            (
                f.scan_id, f.finding_key, f.path, f.rule_id,
                f.line, f.col, f.match_text, f.severity,
            )
            for f in findings
        ],
    )
    now = time.strftime("%Y-%m-%dT%H:%M:%S")
    conn.execute("DELETE FROM pattern_finding_occurrences WHERE scan_id = ?", (scan_id,))
    conn.executemany(
        "INSERT INTO pattern_finding_occurrences (finding_key, scan_id) "
        "VALUES (?, ?)",
        [(finding_key, scan_id) for finding_key in sorted(new_keys)],
    )
    conn.executemany(
        "INSERT INTO pattern_finding_state "
        "(finding_key, rule_id, path, match_text, context_text, first_seen_scan_id, "
        "last_seen_scan_id, scan_count, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?) "
        "ON CONFLICT(finding_key) DO UPDATE SET "
        "rule_id=excluded.rule_id, path=excluded.path, match_text=excluded.match_text, "
        "context_text=excluded.context_text, updated_at=excluded.updated_at",
        [
            (
                f.finding_key, f.rule_id, f.path, f.match_text, f.context_text,
                scan_id, scan_id, now,
            )
            for f in findings
        ],
    )
    conn.executemany(
        "UPDATE pattern_finding_state SET "
        "first_seen_scan_id=(SELECT MIN(scan_id) FROM pattern_finding_occurrences "
        "WHERE finding_key=?), "
        "last_seen_scan_id=(SELECT MAX(scan_id) FROM pattern_finding_occurrences "
        "WHERE finding_key=?), "
        "scan_count=(SELECT COUNT(*) FROM pattern_finding_occurrences WHERE finding_key=?) "
        "WHERE finding_key=?",
        [(finding_key,) * 4 for finding_key in sorted(old_keys | new_keys)],
    )
    conn.executemany(
        "INSERT INTO pattern_rule_runs "
        "(scan_id, rule_id, definition_hash, rule_path, target, status, hits, error, ran_at) "
        "VALUES (?, ?, ?, ?, ?, 'success', ?, NULL, ?)",
        [
            (
                scan_id,
                str(run["rule_id"]),
                str(run["definition_hash"]),
                str(run["rule_path"]),
                str(run["target"]),
                int(str(run["hits"])),
                str(run["ran_at"]),
            )
            for run in runs
        ],
    )
    conn.commit()


def pattern_finding_states(
    conn: sqlite3.Connection, finding_keys: list[str] | None = None
) -> list[dict[str, object]]:
    """Return durable finding identities and their latest dispositions."""
    if finding_keys is not None:
        if not finding_keys:
            return []
        placeholders = ",".join("?" for _ in finding_keys)
        rows = conn.execute(
            f"SELECT * FROM pattern_finding_state WHERE finding_key IN ({placeholders}) "
            "ORDER BY rule_id, path, finding_key",
            finding_keys,
        ).fetchall()
    else:
        rows = conn.execute(
            "SELECT * FROM pattern_finding_state ORDER BY rule_id, path, finding_key"
        ).fetchall()
    return [dict(row) for row in rows]


def adjudicate_pattern_finding(
    conn: sqlite3.Connection,
    finding_key: str,
    disposition: str,
    note: str | None = None,
) -> dict[str, object] | None:
    """Persist one human disposition and append its audit history."""
    if disposition not in {"accepted_defect", "false_positive", "waived", "unresolved"}:
        raise ValueError(f"unsupported pattern finding disposition: {disposition}")
    now = time.strftime("%Y-%m-%dT%H:%M:%S")
    cur = conn.execute(
        "UPDATE pattern_finding_state SET disposition = ?, note = ?, adjudicated_at = ? "
        "WHERE finding_key = ?",
        (disposition, note, now, finding_key),
    )
    if cur.rowcount == 0:
        conn.rollback()
        return None
    conn.execute(
        "INSERT INTO pattern_finding_disposition_history "
        "(finding_key, disposition, note, adjudicated_at) VALUES (?, ?, ?, ?)",
        (finding_key, disposition, note, now),
    )
    conn.commit()
    return pattern_finding_states(conn, [finding_key])[0]


# A rule that has racked up findings across this many scans without a single
# adjudicated disposition has zero human signal on whether it's worth
# keeping -- worth nudging a rule author to run `patterns adjudicate`,
# distinct from decided_precision (which is undefined, not low, at count 0).
ADJUDICATION_NUDGE_SCANS = 3


def pattern_adjudication_report(
    conn: sqlite3.Connection, path_prefix: str | None = None
) -> dict[str, object]:
    """Report per-rule precision and recurring waived finding identities.

    path_prefix, when given, scopes the report to findings whose (repo-
    relative, posix) path equals it or falls under it -- normally the last
    scan target, so precision reflects what that scan actually covered
    instead of every finding ever recorded across differently-scoped scans.
    None (the default) reports across all findings, unscoped.
    """
    rows = pattern_finding_states(conn)
    if path_prefix is not None:
        rows = [
            row
            for row in rows
            if str(row["path"]) == path_prefix
            or str(row["path"]).startswith(path_prefix + "/")
        ]
    # A disposition is durable, but its finding is current only when it
    # occurred in the newest completed scan whose target covered that path.
    # Looking only at scan_count keeps an edited-away key alive forever:
    # real rescans allocate a fresh pattern_runs id, so the old occurrence
    # remains historical even though the replacement scan no longer found
    # it. Keep that state for reattachment if the same key reappears, while
    # excluding it from today's precision denominator.
    completed_runs = conn.execute(
        "SELECT id, target FROM pattern_runs WHERE finished_at IS NOT NULL "
        "ORDER BY id DESC"
    ).fetchall()
    occurrences = {
        (int(row["scan_id"]), str(row["finding_key"]))
        for row in conn.execute(
            "SELECT scan_id, finding_key FROM pattern_finding_occurrences"
        ).fetchall()
    }

    def target_covers_path(target: str, path: str) -> bool:
        if target == ".":
            return not Path(path).is_absolute()
        return path == target or path.startswith(target.rstrip("/") + "/")

    def is_current(row: dict[str, object]) -> bool:
        path = str(row["path"])
        for run in completed_runs:
            if target_covers_path(str(run["target"]), path):
                return (int(run["id"]), str(row["finding_key"])) in occurrences
        # Preserve pre-pattern_runs/migrated state when no completed scan can
        # establish a newer truth for this path.
        return int(str(row["scan_count"])) > 0

    rows = [row for row in rows if is_current(row)]
    by_rule: dict[str, dict[str, object]] = {}
    recurring_waivers: list[dict[str, object]] = []
    for row in rows:
        if int(str(row["scan_count"])) == 0:
            continue
        rule_id = str(row["rule_id"])
        summary = by_rule.setdefault(
            rule_id,
            {
                "findings": 0,
                "occurrences": 0,
                "accepted_defects": 0,
                "false_positives": 0,
                "waived": 0,
                "unresolved": 0,
                "decided_count": 0,
                "decided_precision": None,
                "actionable_rate": None,
                "max_scan_count": 0,
                "needs_adjudication": False,
            },
        )
        summary["findings"] = int(str(summary["findings"])) + 1
        row_scan_count = int(str(row["scan_count"]))
        summary["occurrences"] = int(str(summary["occurrences"])) + row_scan_count
        summary["max_scan_count"] = max(int(str(summary["max_scan_count"])), row_scan_count)
        disposition = str(row["disposition"])
        field = {
            "accepted_defect": "accepted_defects",
            "false_positive": "false_positives",
            "waived": "waived",
            "unresolved": "unresolved",
        }[disposition]
        summary[field] = int(str(summary[field])) + 1
        if disposition != "unresolved":
            summary["decided_count"] = int(str(summary["decided_count"])) + 1
        if disposition == "waived" and int(str(row["scan_count"])) > 1:
            recurring_waivers.append(
                {
                    "finding_key": row["finding_key"],
                    "rule_id": rule_id,
                    "path": row["path"],
                    "match_text": row["match_text"],
                    "scan_count": row["scan_count"],
                    "note": row["note"],
                }
            )
    for summary in by_rule.values():
        decided = int(str(summary["decided_count"]))
        true_positives = int(str(summary["accepted_defects"])) + int(
            str(summary["waived"])
        )
        summary["decided_precision"] = true_positives / decided if decided else None
        summary["actionable_rate"] = (
            int(str(summary["accepted_defects"])) / decided if decided else None
        )
        summary["needs_adjudication"] = (
            decided == 0 and int(str(summary["max_scan_count"])) >= ADJUDICATION_NUDGE_SCANS
        )
    return {
        "by_rule": by_rule,
        "recurring_waivers": recurring_waivers,
        "finding_count": sum(int(str(row["scan_count"])) > 0 for row in rows),
    }


def record_pattern_rule_failure(
    conn: sqlite3.Connection,
    scan_id: int,
    rule_id: str,
    definition_hash: str,
    rule_path: str,
    target: str,
    error: str,
) -> None:
    """Record a failed attempt without deleting the previous findings."""
    conn.execute(
        "INSERT INTO pattern_rule_runs "
        "(scan_id, rule_id, definition_hash, rule_path, target, status, hits, error, ran_at) "
        "VALUES (?, ?, ?, ?, ?, 'failed', NULL, ?, ?) "
        "ON CONFLICT(scan_id, rule_id) DO UPDATE SET "
        "definition_hash=excluded.definition_hash, rule_path=excluded.rule_path, "
        "target=excluded.target, status='failed', hits=NULL, error=excluded.error, "
        "ran_at=excluded.ran_at",
        (
            scan_id,
            rule_id,
            definition_hash,
            rule_path,
            target,
            error,
            time.strftime("%Y-%m-%dT%H:%M:%S"),
        ),
    )
    conn.commit()


def record_pattern_rule_success(
    conn: sqlite3.Connection,
    scan_id: int,
    rule_id: str,
    definition_hash: str,
    rule_path: str,
    target: str,
    hits: int,
) -> None:
    """Durably record a successful rule execution as it finishes.

    Mirrors record_pattern_rule_failure's immediate-commit upsert, but for
    the success case -- called per-rule from cmd_patterns_scan's loop
    (not batched into the end-of-scan replace_pattern_scan_results call)
    so an earlier rule's successful, zero-hit-or-not receipt survives a
    LATER rule's failure in the same scan. Without this, a rule that
    completed successfully was reported as "not_run" (indistinguishable
    from never having executed at all) whenever a later rule in the same
    invocation failed, since replace_pattern_scan_results -- the only
    other writer of pattern_rule_runs for a success -- never ran at all on
    that early-return path. replace_pattern_scan_results still re-writes
    this same row at the end of a fully successful scan (redundant but
    harmless -- same data) alongside the findings snapshot, which stays
    batched/atomic and unpublished until the whole scan succeeds.
    """
    conn.execute(
        "INSERT INTO pattern_rule_runs "
        "(scan_id, rule_id, definition_hash, rule_path, target, status, hits, error, ran_at) "
        "VALUES (?, ?, ?, ?, ?, 'success', ?, NULL, ?) "
        "ON CONFLICT(scan_id, rule_id) DO UPDATE SET "
        "definition_hash=excluded.definition_hash, rule_path=excluded.rule_path, "
        "target=excluded.target, status='success', hits=excluded.hits, error=NULL, "
        "ran_at=excluded.ran_at",
        (
            scan_id,
            rule_id,
            definition_hash,
            rule_path,
            target,
            hits,
            time.strftime("%Y-%m-%dT%H:%M:%S"),
        ),
    )
    conn.commit()


def pattern_rule_runs(
    conn: sqlite3.Connection, scan_id: int
) -> list[dict[str, object]]:
    """Return the latest receipt per rule for the specified quality scan."""
    rows = conn.execute(
        "SELECT * FROM pattern_rule_runs WHERE scan_id = ? ORDER BY rule_id",
        (scan_id,),
    ).fetchall()
    return [dict(row) for row in rows]
