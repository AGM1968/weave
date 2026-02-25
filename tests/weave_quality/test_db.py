"""Tests for weave_quality.db schema, lifecycle, and staleness."""

# pylint: disable=missing-class-docstring,missing-function-docstring,redefined-outer-name,unused-argument

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
    bulk_upsert_function_cc,
    bulk_upsert_git_stats,
    file_changed,
    finish_scan,
    get_ck_metrics,
    get_co_changes,
    get_file_entries,
    get_file_state,
    get_function_cc,
    get_git_stats,
    init_db,
    is_stale,
    compute_trend_direction,
    get_all_trend_directions,
    latest_scan,
    previous_scan,
    staleness_info,
    top_hotspots,
    upsert_ck_metrics,
    upsert_complexity_trend,
    upsert_file_entry,
    upsert_git_stats,
)
from weave_quality.models import (
    CKMetrics,
    CoChange,
    FileEntry,
    FileState,
    FunctionCC,
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
        # _MAX_SCANS = 5 — need 6 scans to trigger prune
        for _, h in enumerate(["h1", "h2", "h3", "h4", "h5", "h6"]):
            begin_scan(db, h)
        count = db.execute("SELECT COUNT(*) FROM scan_meta").fetchone()[0]
        assert count == 5
        sm = latest_scan(db)
        assert sm is not None
        assert sm.git_head == "h6"

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


# ---------------------------------------------------------------------------
# Schema v2 migration (Sprint 1)
# ---------------------------------------------------------------------------


class TestSchemaV2:
    def test_files_has_depth_columns(
        self, db: sqlite3.Connection,
    ) -> None:
        cols = {r[1] for r in db.execute(
            "PRAGMA table_info(files)").fetchall()}
        assert "essential_complexity" in cols
        assert "indent_sd" in cols

    def test_file_metrics_has_detail(
        self, db: sqlite3.Connection,
    ) -> None:
        cols = {r[1] for r in db.execute(
            "PRAGMA table_info(file_metrics)").fetchall()}
        assert "detail" in cols

    def test_complexity_trend_table_exists(
        self, db: sqlite3.Connection,
    ) -> None:
        tables = {
            r[0] for r in db.execute(
                "SELECT name FROM sqlite_master "
                "WHERE type='table'"
            ).fetchall()
        }
        assert "complexity_trend" in tables

    def test_migration_idempotent(
        self, tmp_path: Path,
    ) -> None:
        """Running init_db twice on same DB doesn't fail."""
        conn1 = init_db(hot_zone=str(tmp_path))
        conn1.close()
        conn2 = init_db(hot_zone=str(tmp_path))
        cols = {r[1] for r in conn2.execute(
            "PRAGMA table_info(files)").fetchall()}
        assert "essential_complexity" in cols
        conn2.close()

    def test_depth_fields_in_upsert(
        self, db: sqlite3.Connection,
    ) -> None:
        scan_id = begin_scan(db, "abc")
        entry = FileEntry(
            path="a.py", scan_id=scan_id,
            language="python", complexity=10.0,
            essential_complexity=3.0, indent_sd=1.5,
        )
        upsert_file_entry(db, entry)
        db.commit()
        rows = get_file_entries(db, scan_id, path="a.py")
        assert len(rows) == 1
        assert rows[0].essential_complexity == 3.0
        assert rows[0].indent_sd == 1.5


# ---------------------------------------------------------------------------
# Per-function CC storage (Sprint 1)
# ---------------------------------------------------------------------------


class TestFunctionCCStorage:
    def test_upsert_and_get(
        self, db: sqlite3.Connection,
    ) -> None:
        scan_id = begin_scan(db, "abc")
        fns = [
            FunctionCC(
                path="a.py", scan_id=scan_id,
                function_name="foo", complexity=5.0,
                line_start=1, line_end=10,
                is_dispatch=False,
            ),
            FunctionCC(
                path="a.py", scan_id=scan_id,
                function_name="bar", complexity=12.0,
                line_start=15, line_end=40,
                is_dispatch=True,
            ),
        ]
        bulk_upsert_function_cc(db, fns)
        result = get_function_cc(db, scan_id, "a.py")
        assert len(result) == 2
        by_name = {f.function_name: f for f in result}
        assert by_name["foo"].complexity == 5.0
        assert by_name["foo"].line_start == 1
        assert by_name["foo"].is_dispatch is False
        assert by_name["bar"].complexity == 12.0
        assert by_name["bar"].is_dispatch is True

    def test_get_empty(
        self, db: sqlite3.Connection,
    ) -> None:
        scan_id = begin_scan(db, "abc")
        result = get_function_cc(db, scan_id, "nope.py")
        assert not result

    def test_upsert_updates_existing(
        self, db: sqlite3.Connection,
    ) -> None:
        scan_id = begin_scan(db, "abc")
        fn1 = FunctionCC(
            path="a.py", scan_id=scan_id,
            function_name="foo", complexity=5.0,
            line_start=1, line_end=10,
        )
        bulk_upsert_function_cc(db, [fn1])
        fn2 = FunctionCC(
            path="a.py", scan_id=scan_id,
            function_name="foo", complexity=8.0,
            line_start=1, line_end=15,
        )
        bulk_upsert_function_cc(db, [fn2])
        result = get_function_cc(db, scan_id, "a.py")
        assert len(result) == 1
        assert result[0].complexity == 8.0
        assert result[0].line_end == 15

    def test_fn_cc_isolated_from_ck(
        self, db: sqlite3.Connection,
    ) -> None:
        """fn_cc rows don't interfere with CK metric reads."""
        scan_id = begin_scan(db, "abc")
        ck = CKMetrics(
            path="a.py", scan_id=scan_id,
            metrics={"wmc": 10.0},
        )
        upsert_ck_metrics(db, ck)
        fn = FunctionCC(
            path="a.py", scan_id=scan_id,
            function_name="foo", complexity=5.0,
            line_start=1, line_end=10,
        )
        bulk_upsert_function_cc(db, [fn])
        db.commit()
        ck_back = get_ck_metrics(db, scan_id, "a.py")
        assert ck_back is not None
        # CK should NOT include fn_cc rows
        assert "fn_cc:foo" not in ck_back.metrics


# ---------------------------------------------------------------------------
# Complexity trend (Sprint 1)
# ---------------------------------------------------------------------------


class TestComplexityTrend:
    def test_upsert_and_query(
        self, db: sqlite3.Connection,
    ) -> None:
        scan_id = begin_scan(db, "abc")
        upsert_complexity_trend(
            db, "a.py", scan_id, 15.0, 3.0)
        db.commit()
        row = db.execute(
            "SELECT * FROM complexity_trend "
            "WHERE path = ? AND scan_id = ?",
            ("a.py", scan_id),
        ).fetchone()
        assert row is not None
        assert dict(row)["complexity"] == 15.0
        assert dict(row)["essential"] == 3.0

    def test_upsert_updates_existing(
        self, db: sqlite3.Connection,
    ) -> None:
        scan_id = begin_scan(db, "abc")
        upsert_complexity_trend(
            db, "a.py", scan_id, 10.0, 2.0)
        upsert_complexity_trend(
            db, "a.py", scan_id, 15.0, 3.0)
        db.commit()
        rows = db.execute(
            "SELECT * FROM complexity_trend "
            "WHERE path = ? AND scan_id = ?",
            ("a.py", scan_id),
        ).fetchall()
        assert len(rows) == 1
        assert dict(rows[0])["complexity"] == 15.0

    def test_multiple_scans(
        self, db: sqlite3.Connection,
    ) -> None:
        s1 = begin_scan(db, "aaa")
        upsert_complexity_trend(db, "a.py", s1, 20.0, 5.0)
        db.commit()
        s2 = begin_scan(db, "bbb")
        upsert_complexity_trend(db, "a.py", s2, 15.0, 3.0)
        db.commit()
        rows = db.execute(
            "SELECT complexity FROM complexity_trend "
            "WHERE path = ? ORDER BY scan_id",
            ("a.py",),
        ).fetchall()
        assert len(rows) == 2
        assert rows[0][0] == 20.0  # scan 1
        assert rows[1][0] == 15.0  # scan 2

    def test_cascade_delete(
        self, db: sqlite3.Connection,
    ) -> None:
        """Pruning old scans cascades to complexity_trend."""
        s1 = begin_scan(db, "aaa")
        upsert_complexity_trend(db, "a.py", s1, 20.0, 5.0)
        db.commit()
        s2 = begin_scan(db, "bbb")
        upsert_complexity_trend(db, "a.py", s2, 18.0, 4.0)
        db.commit()
        # Need 6 scans total to push s1 beyond _MAX_SCANS=5
        for h in ["ccc", "ddd", "eee", "fff"]:
            begin_scan(db, h)
        rows = db.execute(
            "SELECT scan_id FROM complexity_trend "
            "WHERE path = ?",
            ("a.py",),
        ).fetchall()
        # s1 should be pruned (CASCADE via scan_meta), s2 remains
        scan_ids = {r[0] for r in rows}
        assert s1 not in scan_ids
        assert s2 in scan_ids


# ---------------------------------------------------------------------------
# Split retention: files/_MAX_SCANS=5 vs complexity_trend/_FILES_SCANS=2
# ---------------------------------------------------------------------------


class TestSplitRetention:
    """Sprint 3: files+file_metrics prune at _FILES_SCANS=2;
    complexity_trend retains up to _MAX_SCANS=5."""

    def test_files_pruned_at_two_scans(self, db: sqlite3.Connection) -> None:
        """After 3 scans, scan-1 files should be gone (files window = 2)."""
        s1 = begin_scan(db, "s1")
        upsert_file_entry(db, FileEntry(path="a.py", scan_id=s1, loc=10))
        db.commit()
        begin_scan(db, "s2")
        begin_scan(db, "s3")

        rows = db.execute(
            "SELECT * FROM files WHERE scan_id = ?", (s1,)
        ).fetchall()
        assert len(rows) == 0, "scan-1 file row should be pruned after 3 scans"

    def test_complexity_trend_retains_five_scans(
        self, db: sqlite3.Connection
    ) -> None:
        """complexity_trend keeps up to _MAX_SCANS=5 even when files are pruned."""
        scans = []
        for i, h in enumerate(["a", "b", "c", "d", "e"]):
            sid = begin_scan(db, h)
            upsert_complexity_trend(db, "x.py", sid, float(i), 1.0)
            db.commit()
            scans.append(sid)

        rows = db.execute(
            "SELECT scan_id FROM complexity_trend WHERE path = ? ORDER BY scan_id",
            ("x.py",),
        ).fetchall()
        # All 5 scans should be retained in complexity_trend
        assert len(rows) == 5, f"expected 5 trend rows, got {len(rows)}"

    def test_scan_meta_retains_five_then_prunes(
        self, db: sqlite3.Connection
    ) -> None:
        """Six scans: scan_meta should keep exactly 5 (oldest dropped)."""
        first = None
        for _, h in enumerate(["h1", "h2", "h3", "h4", "h5", "h6"]):
            sid = begin_scan(db, h)
            if first is None:
                first = sid
        count = db.execute(
            "SELECT COUNT(*) FROM scan_meta"
        ).fetchone()[0]
        assert count == 5
        # Oldest scan should be gone
        gone = db.execute(
            "SELECT * FROM scan_meta WHERE id = ?", (first,)
        ).fetchall()
        assert len(gone) == 0

    def test_files_for_second_scan_survive(self, db: sqlite3.Connection) -> None:
        """After 3 scans, scan-2 (within files window) should still have files."""
        begin_scan(db, "s1")
        s2 = begin_scan(db, "s2")
        upsert_file_entry(db, FileEntry(path="b.py", scan_id=s2, loc=20))
        db.commit()
        begin_scan(db, "s3")

        rows = db.execute(
            "SELECT * FROM files WHERE scan_id = ?", (s2,)
        ).fetchall()
        assert len(rows) == 1, "scan-2 files should survive (within _FILES_SCANS=2 window)"

# ---------------------------------------------------------------------------
# Trend direction computation
# ---------------------------------------------------------------------------

class TestComputeTrendDirection:
    """Unit tests for compute_trend_direction slope classification."""

    def test_stable_single_point(self) -> None:
        """Single data point returns stable."""
        assert compute_trend_direction([42.0]) == "stable"

    def test_stable_empty(self) -> None:
        """Empty list returns stable."""
        assert compute_trend_direction([]) == "stable"

    def test_stable_no_change(self) -> None:
        """Flat complexity series is stable."""
        assert compute_trend_direction([20.0, 20.0, 20.0]) == "stable"

    def test_stable_small_increase(self) -> None:
        """Tiny relative slope (< 3%) stays stable."""
        # +0.1 per scan relative to mean 100 = 0.1% -- well within stable band
        assert compute_trend_direction([100.0, 100.1, 100.2]) == "stable"

    def test_deteriorating_two_points(self) -> None:
        """Two points: clear upward slope marks deteriorating."""
        # slope = 10 / mean 15 = 67% per scan
        assert compute_trend_direction([10.0, 20.0]) == "deteriorating"

    def test_deteriorating_multi_scan(self) -> None:
        """Rising complexity over multiple scans is deteriorating."""
        assert compute_trend_direction([10.0, 15.0, 20.0, 25.0]) == "deteriorating"

    def test_refactored_two_points(self) -> None:
        """Two points: clear downward slope marks refactored."""
        assert compute_trend_direction([20.0, 10.0]) == "refactored"

    def test_refactored_multi_scan(self) -> None:
        """Falling complexity over multiple scans is refactored."""
        assert compute_trend_direction([80.0, 60.0, 40.0, 20.0]) == "refactored"

    def test_zero_mean_returns_stable(self) -> None:
        """Zero mean guard: no division by zero."""
        assert compute_trend_direction([0.0, 0.0]) == "stable"


class TestGetAllTrendDirections:
    """Integration tests for get_all_trend_directions against a real DB."""

    def test_empty_db_returns_empty(self, db: sqlite3.Connection) -> None:
        """No trend rows = empty dict."""
        result = get_all_trend_directions(db)
        assert result == {}

    def test_single_file_stable(self, db: sqlite3.Connection) -> None:
        """A file with identical complexity across scans is stable."""
        s1 = begin_scan(db, "h1")
        s2 = begin_scan(db, "h2")
        upsert_complexity_trend(db, "a.py", s1, 30.0, 2.0)
        upsert_complexity_trend(db, "a.py", s2, 30.0, 2.0)
        db.commit()
        result = get_all_trend_directions(db)
        assert result["a.py"] == "stable"

    def test_single_file_deteriorating(self, db: sqlite3.Connection) -> None:
        """A file with rising complexity is deteriorating."""
        s1 = begin_scan(db, "h1")
        s2 = begin_scan(db, "h2")
        upsert_complexity_trend(db, "a.py", s1, 10.0, 1.0)
        upsert_complexity_trend(db, "a.py", s2, 30.0, 3.0)
        db.commit()
        result = get_all_trend_directions(db)
        assert result["a.py"] == "deteriorating"

    def test_single_file_refactored(self, db: sqlite3.Connection) -> None:
        """A file with falling complexity is refactored."""
        s1 = begin_scan(db, "h1")
        s2 = begin_scan(db, "h2")
        upsert_complexity_trend(db, "a.py", s1, 50.0, 5.0)
        upsert_complexity_trend(db, "a.py", s2, 10.0, 1.0)
        db.commit()
        result = get_all_trend_directions(db)
        assert result["a.py"] == "refactored"

    def test_multiple_files_independent(self, db: sqlite3.Connection) -> None:
        """Different files can have different trend directions."""
        s1 = begin_scan(db, "h1")
        s2 = begin_scan(db, "h2")
        upsert_complexity_trend(db, "rising.py", s1, 10.0, 0.0)
        upsert_complexity_trend(db, "rising.py", s2, 40.0, 0.0)
        upsert_complexity_trend(db, "falling.py", s1, 80.0, 0.0)
        upsert_complexity_trend(db, "falling.py", s2, 20.0, 0.0)
        upsert_complexity_trend(db, "flat.py", s1, 25.0, 0.0)
        upsert_complexity_trend(db, "flat.py", s2, 25.0, 0.0)
        db.commit()
        result = get_all_trend_directions(db)
        assert result["rising.py"] == "deteriorating"
        assert result["falling.py"] == "refactored"
        assert result["flat.py"] == "stable"
