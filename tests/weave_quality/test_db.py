"""Tests for weave_quality.db schema, lifecycle, and staleness."""

# pylint: disable=missing-class-docstring,missing-function-docstring,redefined-outer-name

from __future__ import annotations

import sqlite3
from collections.abc import Generator
from pathlib import Path

import pytest

from weave_quality.db import (
    begin_scan,
    bulk_upsert_co_changes,
    bulk_upsert_file_entries,
    bulk_upsert_file_state,
    bulk_upsert_git_stats,
    file_changed,
    finish_scan,
    get_ck_metrics,
    get_co_changes,
    get_file_entries,
    get_file_state,
    get_git_stats,
    init_db,
    is_stale,
    latest_scan,
    previous_scan,
    staleness_info,
    top_hotspots,
    upsert_ck_metrics,
    upsert_file_entry,
    upsert_git_stats,
)
from weave_quality.models import (
    CKMetrics,
    CoChange,
    FileEntry,
    FileState,
    GitStats,
)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture()
def db(tmp_path: Path) -> Generator[sqlite3.Connection, None, None]:
    """Fresh quality.db in a temp directory."""
    conn = init_db(hot_zone=str(tmp_path))
    yield conn
    conn.close()


# ---------------------------------------------------------------------------
# Schema
# ---------------------------------------------------------------------------


class TestSchema:
    def test_init_creates_tables(self, db: sqlite3.Connection) -> None:
        tables = {
            row[0]
            for row in db.execute(
                "SELECT name FROM sqlite_master WHERE type='table'"
            ).fetchall()
        }
        expected = {"scan_meta", "files", "file_metrics", "git_stats",
                    "co_change", "file_state"}
        assert expected.issubset(tables)

    def test_init_idempotent(self, db: sqlite3.Connection, tmp_path: Path) -> None:
        # db fixture ensures first init_db ran; second call tests idempotency
        _ = db
        conn2 = init_db(hot_zone=str(tmp_path))
        tables = {
            row[0]
            for row in conn2.execute(
                "SELECT name FROM sqlite_master WHERE type='table'"
            ).fetchall()
        }
        assert "scan_meta" in tables
        conn2.close()

    def test_foreign_keys_on(self, db: sqlite3.Connection) -> None:
        val = db.execute("PRAGMA foreign_keys").fetchone()[0]
        assert val == 1


# ---------------------------------------------------------------------------
# Scan lifecycle
# ---------------------------------------------------------------------------


class TestScanLifecycle:
    def test_begin_scan_returns_id(self, db: sqlite3.Connection) -> None:
        sid = begin_scan(db, "abc123")
        assert sid >= 1

    def test_latest_scan(self, db: sqlite3.Connection) -> None:
        begin_scan(db, "abc123")
        sm = latest_scan(db)
        assert sm is not None
        assert sm.git_head == "abc123"

    def test_previous_scan_none(self, db: sqlite3.Connection) -> None:
        begin_scan(db, "abc123")
        assert previous_scan(db) is None

    def test_previous_scan_exists(self, db: sqlite3.Connection) -> None:
        begin_scan(db, "head1")
        begin_scan(db, "head2")
        prev = previous_scan(db)
        assert prev is not None
        assert prev.git_head == "head1"

    def test_finish_scan(self, db: sqlite3.Connection) -> None:
        sid = begin_scan(db, "abc123")
        finish_scan(db, sid, files_count=42, duration_ms=500)
        sm = latest_scan(db)
        assert sm is not None
        assert sm.files_count == 42
        assert sm.duration_ms == 500

    def test_retention_prunes_old(self, db: sqlite3.Connection) -> None:
        begin_scan(db, "head1")
        begin_scan(db, "head2")
        begin_scan(db, "head3")
        # Only 2 scans retained (newest)
        count = db.execute("SELECT COUNT(*) FROM scan_meta").fetchone()[0]
        assert count == 2
        sm = latest_scan(db)
        assert sm is not None
        assert sm.git_head == "head3"

    def test_cascade_deletes_files(self, db: sqlite3.Connection) -> None:
        sid1 = begin_scan(db, "head1")
        upsert_file_entry(db, FileEntry(path="a.py", scan_id=sid1, loc=10))
        db.commit()
        begin_scan(db, "head2")
        begin_scan(db, "head3")
        # scan1 pruned, its files should be gone
        rows = db.execute(
            "SELECT * FROM files WHERE scan_id = ?", (sid1,)
        ).fetchall()
        assert len(rows) == 0


# ---------------------------------------------------------------------------
# files table
# ---------------------------------------------------------------------------


class TestFileEntries:
    def test_upsert_and_get(self, db: sqlite3.Connection) -> None:
        sid = begin_scan(db, "abc123")
        fe = FileEntry(path="src/a.py", scan_id=sid, language="python",
                       loc=100, complexity=5.0, functions=3, avg_fn_len=12.0)
        upsert_file_entry(db, fe)
        db.commit()
        results = get_file_entries(db, sid)
        assert len(results) == 1
        assert results[0].path == "src/a.py"
        assert results[0].avg_fn_len == 12.0

    def test_bulk_upsert(self, db: sqlite3.Connection) -> None:
        sid = begin_scan(db, "abc123")
        entries = [
            FileEntry(path="a.py", scan_id=sid, loc=10),
            FileEntry(path="b.py", scan_id=sid, loc=20),
            FileEntry(path="c.py", scan_id=sid, loc=30),
        ]
        bulk_upsert_file_entries(db, entries)
        results = get_file_entries(db, sid)
        assert len(results) == 3
        assert sum(e.loc for e in results) == 60

    def test_get_by_path(self, db: sqlite3.Connection) -> None:
        sid = begin_scan(db, "abc123")
        upsert_file_entry(db, FileEntry(path="a.py", scan_id=sid, loc=10))
        upsert_file_entry(db, FileEntry(path="b.py", scan_id=sid, loc=20))
        db.commit()
        results = get_file_entries(db, sid, path="a.py")
        assert len(results) == 1
        assert results[0].loc == 10

    def test_upsert_updates_existing(self, db: sqlite3.Connection) -> None:
        sid = begin_scan(db, "abc123")
        upsert_file_entry(db, FileEntry(path="a.py", scan_id=sid, loc=10))
        upsert_file_entry(db, FileEntry(path="a.py", scan_id=sid, loc=99))
        db.commit()
        results = get_file_entries(db, sid)
        assert len(results) == 1
        assert results[0].loc == 99


# ---------------------------------------------------------------------------
# file_metrics (CK EAV)
# ---------------------------------------------------------------------------


class TestCKMetrics:
    def test_upsert_and_get(self, db: sqlite3.Connection) -> None:
        sid = begin_scan(db, "abc123")
        ck = CKMetrics(path="a.py", scan_id=sid,
                       metrics={"wmc": 5.0, "cbo": 3.0})
        upsert_ck_metrics(db, ck)
        db.commit()
        got = get_ck_metrics(db, sid, "a.py")
        assert got is not None
        assert got.metrics["wmc"] == 5.0

    def test_get_missing(self, db: sqlite3.Connection) -> None:
        sid = begin_scan(db, "abc123")
        got = get_ck_metrics(db, sid, "nonexistent.py")
        assert got is None


# ---------------------------------------------------------------------------
# git_stats (NOT scan-versioned)
# ---------------------------------------------------------------------------


class TestGitStats:
    def test_upsert_and_get(self, db: sqlite3.Connection) -> None:
        gs = GitStats(path="a.py", churn=42, authors=3, age_days=100, hotspot=0.85)
        upsert_git_stats(db, gs)
        db.commit()
        results = get_git_stats(db, path="a.py")
        assert len(results) == 1
        assert results[0].churn == 42

    def test_bulk_upsert(self, db: sqlite3.Connection) -> None:
        stats = [
            GitStats(path="a.py", churn=10, hotspot=0.9),
            GitStats(path="b.py", churn=5, hotspot=0.3),
        ]
        bulk_upsert_git_stats(db, stats)
        results = get_git_stats(db)
        assert len(results) == 2

    def test_top_hotspots(self, db: sqlite3.Connection) -> None:
        stats = [
            GitStats(path="hot.py", churn=100, hotspot=0.95),
            GitStats(path="warm.py", churn=50, hotspot=0.6),
            GitStats(path="cold.py", churn=2, hotspot=0.0),
        ]
        bulk_upsert_git_stats(db, stats)
        top = top_hotspots(db, top_n=2)
        assert len(top) == 2
        assert top[0].path == "hot.py"
        assert top[1].path == "warm.py"


# ---------------------------------------------------------------------------
# co_change
# ---------------------------------------------------------------------------


class TestCoChange:
    def test_bulk_upsert_and_get(self, db: sqlite3.Connection) -> None:
        pairs = [
            CoChange(path_a="a.py", path_b="b.py", count=5),
            CoChange(path_a="a.py", path_b="c.py", count=3),
        ]
        bulk_upsert_co_changes(db, pairs)
        results = get_co_changes(db, path="a.py")
        assert len(results) == 2

    def test_bulk_replaces(self, db: sqlite3.Connection) -> None:
        bulk_upsert_co_changes(db, [CoChange("a.py", "b.py", 5)])
        bulk_upsert_co_changes(db, [CoChange("x.py", "y.py", 1)])
        # Second call clears first
        all_pairs = get_co_changes(db, top_n=100)
        assert len(all_pairs) == 1
        assert all_pairs[0].path_a == "x.py"


# ---------------------------------------------------------------------------
# file_state
# ---------------------------------------------------------------------------


class TestFileState:
    def test_upsert_and_get(self, db: sqlite3.Connection) -> None:
        fs = FileState(path="a.py", mtime=1700000000, git_blob="abc123")
        bulk_upsert_file_state(db, [fs])
        got = get_file_state(db, "a.py")
        assert got is not None
        assert got.mtime == 1700000000

    def test_get_missing(self, db: sqlite3.Connection) -> None:
        assert get_file_state(db, "nope.py") is None

    def test_file_changed_never_scanned(self, db: sqlite3.Connection) -> None:
        assert file_changed(db, "new.py", 100, "blob") is True

    def test_file_changed_by_blob(self, db: sqlite3.Connection) -> None:
        bulk_upsert_file_state(db, [
            FileState(path="a.py", mtime=100, git_blob="aaa"),
        ])
        assert file_changed(db, "a.py", 100, "aaa") is False
        assert file_changed(db, "a.py", 100, "bbb") is True

    def test_file_changed_by_mtime(self, db: sqlite3.Connection) -> None:
        bulk_upsert_file_state(db, [
            FileState(path="a.py", mtime=100, git_blob=""),
        ])
        assert file_changed(db, "a.py", 100, "") is False
        assert file_changed(db, "a.py", 200, "") is True


# ---------------------------------------------------------------------------
# Staleness
# ---------------------------------------------------------------------------


class TestStaleness:
    def test_stale_no_scan(self, db: sqlite3.Connection) -> None:
        assert is_stale(db, "abc123") is True

    def test_not_stale_same_head(self, db: sqlite3.Connection) -> None:
        begin_scan(db, "abc123")
        assert is_stale(db, "abc123") is False

    def test_stale_head_moved(self, db: sqlite3.Connection) -> None:
        begin_scan(db, "abc123")
        assert is_stale(db, "def456") is True

    def test_staleness_info_no_scan(self, db: sqlite3.Connection) -> None:
        info = staleness_info(db, "abc123")
        assert info["stale"] is True
        assert info["reason"] == "no_scan_data"

    def test_staleness_info_head_moved(self, db: sqlite3.Connection) -> None:
        begin_scan(db, "abc123ff" * 5)  # 40 char sha
        info = staleness_info(db, "def456ff" * 5)
        assert info["stale"] is True
        assert info["reason"] == "head_moved"

    def test_staleness_info_fresh(self, db: sqlite3.Connection) -> None:
        begin_scan(db, "abc123")
        info = staleness_info(db, "abc123")
        assert info["stale"] is False
