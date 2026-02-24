"""quality.db schema, lifecycle, and staleness detection.

SQLite DB at $WV_HOT_ZONE/quality.db -- flat sibling to brain.db.
Never synced to git, never tracked, fully rebuildable from source + git.

Schema (from PROPOSAL-wv-quality.md):
  - scan_meta: scan run metadata + staleness tracking
  - files: static analysis per file per scan (loc, complexity, functions, etc.)
  - file_metrics: CK-suite EAV metrics per file per scan (wmc, cbo, dit, rfc, lcom)
  - git_stats: git-derived metrics per file, NOT scan-versioned (churn, authors, age, hotspot)
  - co_change: co-change pairs (files that frequently change together)
  - file_state: incremental scan state (mtime, git_blob SHA)

Retention: 2 scans (current + previous). Older scans auto-deleted.
Staleness: tracked via scan_meta.git_head vs current HEAD SHA.
Recovery: delete quality.db entirely (wv quality reset).
"""

from __future__ import annotations

import logging
import os
import sqlite3
import time
from pathlib import Path
from typing import Any

from .models import CKMetrics, CoChange, FileEntry, FileState, GitStats, ScanMeta

log = logging.getLogger(__name__)

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
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    scanned_at  TEXT NOT NULL,
    git_head    TEXT NOT NULL,
    files_count INTEGER,
    duration_ms INTEGER
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

-- Indexes for common queries
CREATE INDEX IF NOT EXISTS idx_files_scan ON files(scan_id);
CREATE INDEX IF NOT EXISTS idx_files_complexity ON files(complexity DESC);
CREATE INDEX IF NOT EXISTS idx_fm_scan ON file_metrics(scan_id);
CREATE INDEX IF NOT EXISTS idx_gs_hotspot ON git_stats(hotspot DESC);
"""

# Maximum number of scans to retain (current + previous)
_MAX_SCANS = 2


# ---------------------------------------------------------------------------
# Database lifecycle
# ---------------------------------------------------------------------------


def _resolve_db_path(hot_zone: str | None = None) -> Path:
    """Resolve quality.db path from WV_HOT_ZONE or explicit path."""
    if hot_zone:
        return Path(hot_zone) / "quality.db"

    env_hz = os.environ.get("WV_HOT_ZONE", "")
    if env_hz:
        return Path(env_hz) / "quality.db"

    # Fallback: /dev/shm/weave or /tmp/weave
    base = "/dev/shm/weave" if Path("/dev/shm").exists() else "/tmp/weave"
    return Path(base) / "quality.db"


def init_db(hot_zone: str | None = None) -> sqlite3.Connection:
    """Initialise quality.db, creating schema if needed.

    Returns an open connection. The caller is responsible for closing it.
    """
    resolved = _resolve_db_path(hot_zone)
    resolved.parent.mkdir(parents=True, exist_ok=True)

    conn = sqlite3.connect(str(resolved))
    conn.row_factory = sqlite3.Row
    conn.executescript(_SCHEMA)
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


def begin_scan(conn: sqlite3.Connection, git_head: str) -> int:
    """Record a new scan, prune old scans beyond retention limit.

    Returns the new scan_id.
    """
    cur = conn.execute(
        "INSERT INTO scan_meta (scanned_at, git_head) VALUES (?, ?)",
        (time.strftime("%Y-%m-%dT%H:%M:%S"), git_head),
    )
    scan_id = cur.lastrowid
    assert scan_id is not None

    # Prune scans beyond retention (keep newest _MAX_SCANS)
    # CASCADE deletes orphaned files + file_metrics rows
    conn.execute(
        """DELETE FROM scan_meta WHERE id NOT IN (
            SELECT id FROM scan_meta ORDER BY id DESC LIMIT ?
        )""",
        (_MAX_SCANS,),
    )
    conn.commit()
    log.debug("Scan %d started (head=%s)", scan_id, git_head[:8])
    return scan_id


def finish_scan(conn: sqlite3.Connection, scan_id: int,
                files_count: int, duration_ms: int) -> None:
    """Finalise a scan with counts and duration."""
    conn.execute(
        "UPDATE scan_meta SET files_count = ?, duration_ms = ? WHERE id = ?",
        (files_count, duration_ms, scan_id),
    )
    conn.commit()


def latest_scan(conn: sqlite3.Connection) -> ScanMeta | None:
    """Get the most recent scan metadata, or None."""
    row = conn.execute(
        "SELECT * FROM scan_meta ORDER BY id DESC LIMIT 1"
    ).fetchone()
    if not row:
        return None
    return ScanMeta(
        id=row["id"],
        scanned_at=row["scanned_at"],
        git_head=row["git_head"],
        files_count=row["files_count"] or 0,
        duration_ms=row["duration_ms"] or 0,
    )


def previous_scan(conn: sqlite3.Connection) -> ScanMeta | None:
    """Get the second-most-recent scan (for delta reports), or None."""
    rows = conn.execute(
        "SELECT * FROM scan_meta ORDER BY id DESC LIMIT 2"
    ).fetchall()
    if len(rows) < 2:
        return None
    row = rows[1]
    return ScanMeta(
        id=row["id"],
        scanned_at=row["scanned_at"],
        git_head=row["git_head"],
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
        """INSERT INTO files (path, scan_id, language, loc, complexity,
            functions, max_nesting, avg_fn_len)
        VALUES (:path, :scan_id, :language, :loc, :complexity,
            :functions, :max_nesting, :avg_fn_len)
        ON CONFLICT(path, scan_id) DO UPDATE SET
            language=excluded.language, loc=excluded.loc,
            complexity=excluded.complexity, functions=excluded.functions,
            max_nesting=excluded.max_nesting, avg_fn_len=excluded.avg_fn_len
        """,
        d,
    )


def bulk_upsert_file_entries(conn: sqlite3.Connection,
                             entries: list[FileEntry]) -> None:
    """Insert/update a batch of file entries. Commits once at end."""
    for entry in entries:
        upsert_file_entry(conn, entry)
    conn.commit()


def get_file_entries(conn: sqlite3.Connection, scan_id: int,
                     path: str | None = None) -> list[FileEntry]:
    """Retrieve file entries for a scan, optionally filtered by path."""
    if path:
        rows = conn.execute(
            "SELECT * FROM files WHERE scan_id = ? AND path = ?",
            (scan_id, path),
        ).fetchall()
    else:
        rows = conn.execute(
            "SELECT * FROM files WHERE scan_id = ?", (scan_id,),
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


def get_ck_metrics(conn: sqlite3.Connection, scan_id: int,
                   path: str) -> CKMetrics | None:
    """Get CK metrics for a file in a scan."""
    rows = conn.execute(
        "SELECT * FROM file_metrics WHERE scan_id = ? AND path = ?",
        (scan_id, path),
    ).fetchall()
    return CKMetrics.from_rows([dict(r) for r in rows])


# ---------------------------------------------------------------------------
# git_stats CRUD (NOT scan-versioned)
# ---------------------------------------------------------------------------


def upsert_git_stats(conn: sqlite3.Connection, stats: GitStats) -> None:
    """Insert or update git stats for a file."""
    d = stats.to_dict()
    conn.execute(
        """INSERT INTO git_stats (path, churn, authors, age_days, hotspot)
        VALUES (:path, :churn, :authors, :age_days, :hotspot)
        ON CONFLICT(path) DO UPDATE SET
            churn=excluded.churn, authors=excluded.authors,
            age_days=excluded.age_days, hotspot=excluded.hotspot
        """,
        d,
    )


def bulk_upsert_git_stats(conn: sqlite3.Connection,
                          stats_list: list[GitStats]) -> None:
    """Insert/update a batch of git stats. Commits once at end."""
    for stats in stats_list:
        upsert_git_stats(conn, stats)
    conn.commit()


def get_git_stats(conn: sqlite3.Connection,
                  path: str | None = None) -> list[GitStats]:
    """Get git stats, optionally for a single file."""
    if path:
        rows = conn.execute(
            "SELECT * FROM git_stats WHERE path = ?", (path,),
        ).fetchall()
    else:
        rows = conn.execute("SELECT * FROM git_stats").fetchall()
    return [GitStats.from_dict(dict(r)) for r in rows]


def top_hotspots(conn: sqlite3.Connection, top_n: int = 10) -> list[GitStats]:
    """Get top N files by hotspot score from git_stats."""
    rows = conn.execute(
        """SELECT * FROM git_stats
           WHERE hotspot > 0
           ORDER BY hotspot DESC LIMIT ?""",
        (top_n,),
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


def bulk_upsert_co_changes(conn: sqlite3.Connection,
                           pairs: list[CoChange]) -> None:
    """Replace all co-change pairs. Clears old data first."""
    conn.execute("DELETE FROM co_change")
    for cc in pairs:
        upsert_co_change(conn, cc)
    conn.commit()


def get_co_changes(conn: sqlite3.Connection,
                   path: str | None = None,
                   top_n: int = 10) -> list[CoChange]:
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
    return [CoChange(path_a=r["path_a"], path_b=r["path_b"], count=r["count"])
            for r in rows]


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


def bulk_upsert_file_state(conn: sqlite3.Connection,
                           states: list[FileState]) -> None:
    """Insert/update a batch of file states. Commits once at end."""
    for fs in states:
        upsert_file_state(conn, fs)
    conn.commit()


def get_file_state(conn: sqlite3.Connection, path: str) -> FileState | None:
    """Get file state for a path, or None if not tracked."""
    row = conn.execute(
        "SELECT * FROM file_state WHERE path = ?", (path,),
    ).fetchone()
    if not row:
        return None
    return FileState.from_dict(dict(row))


def file_changed(conn: sqlite3.Connection, path: str,
                 current_mtime: int, current_blob: str) -> bool:
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


def staleness_info(conn: sqlite3.Connection,
                   current_head: str) -> dict[str, Any]:
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
