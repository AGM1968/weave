"""Tests for weave_quality.db schema, lifecycle, and staleness."""

# pylint: disable=missing-class-docstring,missing-function-docstring,redefined-outer-name,unused-argument,too-many-lines

from __future__ import annotations

import sqlite3
from collections.abc import Generator
from pathlib import Path

import pytest

from weave_quality.db import (
    ADJUDICATION_NUDGE_SCANS,
    _MAX_PATTERN_RUNS,
    PatternMigrationConflictError,
    adjudicate_pattern_finding,
    begin_pattern_run,
    begin_scan,
    bulk_insert_pattern_findings,
    bulk_upsert_co_changes,
    bulk_upsert_file_entries,
    bulk_upsert_file_state,
    bulk_upsert_function_cc,
    bulk_upsert_git_stats,
    file_changed,
    finish_pattern_run,
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
    pattern_adjudication_report,
    pattern_finding_states,
    pattern_findings_summary,
    pattern_rule_runs,
    previous_scan,
    query_pattern_findings,
    record_pattern_rule_failure,
    record_pattern_rule_success,
    replace_pattern_scan_results,
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
    PatternFinding,
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
        expected = {
            "scan_meta",
            "files",
            "file_metrics",
            "git_stats",
            "co_change",
            "file_state",
        }
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
        rows = db.execute("SELECT * FROM files WHERE scan_id = ?", (sid1,)).fetchall()
        assert len(rows) == 0


# ---------------------------------------------------------------------------
# files table
# ---------------------------------------------------------------------------


class TestFileEntries:
    def test_upsert_and_get(self, db: sqlite3.Connection) -> None:
        sid = begin_scan(db, "abc123")
        fe = FileEntry(
            path="src/a.py",
            scan_id=sid,
            language="python",
            loc=100,
            complexity=5.0,
            functions=3,
            avg_fn_len=12.0,
        )
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
        ck = CKMetrics(path="a.py", scan_id=sid, metrics={"wmc": 5.0, "cbo": 3.0})
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

    def test_top_hotspots_applies_threshold(self, db: sqlite3.Connection) -> None:
        # Regression (audit A2-1): query previously used WHERE hotspot > 0,
        # listing below-threshold files the scan summary never counted.
        stats = [
            GitStats(path="hot.py", churn=100, hotspot=0.95),
            GitStats(path="warm.py", churn=50, hotspot=0.6),
            GitStats(path="tepid.py", churn=20, hotspot=0.3),
            GitStats(path="cold.py", churn=2, hotspot=0.0),
        ]
        bulk_upsert_git_stats(db, stats)
        top = top_hotspots(db, top_n=10)
        assert [s.path for s in top] == ["hot.py", "warm.py"]
        top = top_hotspots(db, top_n=10, threshold=0.7)
        assert [s.path for s in top] == ["hot.py"]


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
        bulk_upsert_file_state(
            db,
            [
                FileState(path="a.py", mtime=100, git_blob="aaa"),
            ],
        )
        assert file_changed(db, "a.py", 100, "aaa") is False
        assert file_changed(db, "a.py", 100, "bbb") is True

    def test_file_changed_by_mtime(self, db: sqlite3.Connection) -> None:
        bulk_upsert_file_state(
            db,
            [
                FileState(path="a.py", mtime=100, git_blob=""),
            ],
        )
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
        self,
        db: sqlite3.Connection,
    ) -> None:
        cols = {r[1] for r in db.execute("PRAGMA table_info(files)").fetchall()}
        assert "essential_complexity" in cols
        assert "indent_sd" in cols

    def test_file_metrics_has_detail(
        self,
        db: sqlite3.Connection,
    ) -> None:
        cols = {r[1] for r in db.execute("PRAGMA table_info(file_metrics)").fetchall()}
        assert "detail" in cols

    def test_complexity_trend_table_exists(
        self,
        db: sqlite3.Connection,
    ) -> None:
        tables = {
            r[0]
            for r in db.execute(
                "SELECT name FROM sqlite_master WHERE type='table'"
            ).fetchall()
        }
        assert "complexity_trend" in tables

    def test_migration_idempotent(
        self,
        tmp_path: Path,
    ) -> None:
        """Running init_db twice on same DB doesn't fail."""
        conn1 = init_db(hot_zone=str(tmp_path))
        conn1.close()
        conn2 = init_db(hot_zone=str(tmp_path))
        cols = {r[1] for r in conn2.execute("PRAGMA table_info(files)").fetchall()}
        assert "essential_complexity" in cols
        conn2.close()

    def test_depth_fields_in_upsert(
        self,
        db: sqlite3.Connection,
    ) -> None:
        scan_id = begin_scan(db, "abc")
        entry = FileEntry(
            path="a.py",
            scan_id=scan_id,
            language="python",
            complexity=10.0,
            essential_complexity=3.0,
            indent_sd=1.5,
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
        self,
        db: sqlite3.Connection,
    ) -> None:
        scan_id = begin_scan(db, "abc")
        fns = [
            FunctionCC(
                path="a.py",
                scan_id=scan_id,
                function_name="foo",
                complexity=5.0,
                line_start=1,
                line_end=10,
                is_dispatch=False,
            ),
            FunctionCC(
                path="a.py",
                scan_id=scan_id,
                function_name="bar",
                complexity=12.0,
                line_start=15,
                line_end=40,
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
        self,
        db: sqlite3.Connection,
    ) -> None:
        scan_id = begin_scan(db, "abc")
        result = get_function_cc(db, scan_id, "nope.py")
        assert not result

    def test_upsert_updates_existing(
        self,
        db: sqlite3.Connection,
    ) -> None:
        scan_id = begin_scan(db, "abc")
        fn1 = FunctionCC(
            path="a.py",
            scan_id=scan_id,
            function_name="foo",
            complexity=5.0,
            line_start=1,
            line_end=10,
        )
        bulk_upsert_function_cc(db, [fn1])
        fn2 = FunctionCC(
            path="a.py",
            scan_id=scan_id,
            function_name="foo",
            complexity=8.0,
            line_start=1,
            line_end=15,
        )
        bulk_upsert_function_cc(db, [fn2])
        result = get_function_cc(db, scan_id, "a.py")
        assert len(result) == 1
        assert result[0].complexity == 8.0
        assert result[0].line_end == 15

    def test_fn_cc_isolated_from_ck(
        self,
        db: sqlite3.Connection,
    ) -> None:
        """fn_cc rows don't interfere with CK metric reads."""
        scan_id = begin_scan(db, "abc")
        ck = CKMetrics(
            path="a.py",
            scan_id=scan_id,
            metrics={"wmc": 10.0},
        )
        upsert_ck_metrics(db, ck)
        fn = FunctionCC(
            path="a.py",
            scan_id=scan_id,
            function_name="foo",
            complexity=5.0,
            line_start=1,
            line_end=10,
        )
        bulk_upsert_function_cc(db, [fn])
        db.commit()
        ck_back = get_ck_metrics(db, scan_id, "a.py")
        assert ck_back is not None
        # CK should NOT include fn_cc rows
        assert "fn_cc:foo@1" not in ck_back.metrics


# ---------------------------------------------------------------------------
# Complexity trend (Sprint 1)
# ---------------------------------------------------------------------------


class TestComplexityTrend:
    def test_upsert_and_query(
        self,
        db: sqlite3.Connection,
    ) -> None:
        scan_id = begin_scan(db, "abc")
        upsert_complexity_trend(db, "a.py", scan_id, 15.0, 3.0)
        db.commit()
        row = db.execute(
            "SELECT * FROM complexity_trend WHERE path = ? AND scan_id = ?",
            ("a.py", scan_id),
        ).fetchone()
        assert row is not None
        assert dict(row)["complexity"] == 15.0
        assert dict(row)["essential"] == 3.0

    def test_upsert_updates_existing(
        self,
        db: sqlite3.Connection,
    ) -> None:
        scan_id = begin_scan(db, "abc")
        upsert_complexity_trend(db, "a.py", scan_id, 10.0, 2.0)
        upsert_complexity_trend(db, "a.py", scan_id, 15.0, 3.0)
        db.commit()
        rows = db.execute(
            "SELECT * FROM complexity_trend WHERE path = ? AND scan_id = ?",
            ("a.py", scan_id),
        ).fetchall()
        assert len(rows) == 1
        assert dict(rows[0])["complexity"] == 15.0

    def test_multiple_scans(
        self,
        db: sqlite3.Connection,
    ) -> None:
        s1 = begin_scan(db, "aaa")
        upsert_complexity_trend(db, "a.py", s1, 20.0, 5.0)
        db.commit()
        s2 = begin_scan(db, "bbb")
        upsert_complexity_trend(db, "a.py", s2, 15.0, 3.0)
        db.commit()
        rows = db.execute(
            "SELECT complexity FROM complexity_trend WHERE path = ? ORDER BY scan_id",
            ("a.py",),
        ).fetchall()
        assert len(rows) == 2
        assert rows[0][0] == 20.0  # scan 1
        assert rows[1][0] == 15.0  # scan 2

    def test_cascade_delete(
        self,
        db: sqlite3.Connection,
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
            "SELECT scan_id FROM complexity_trend WHERE path = ?",
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

        rows = db.execute("SELECT * FROM files WHERE scan_id = ?", (s1,)).fetchall()
        assert len(rows) == 0, "scan-1 file row should be pruned after 3 scans"

    def test_complexity_trend_retains_five_scans(self, db: sqlite3.Connection) -> None:
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

    def test_scan_meta_retains_five_then_prunes(self, db: sqlite3.Connection) -> None:
        """Six scans: scan_meta should keep exactly 5 (oldest dropped)."""
        first = None
        for _, h in enumerate(["h1", "h2", "h3", "h4", "h5", "h6"]):
            sid = begin_scan(db, h)
            if first is None:
                first = sid
        count = db.execute("SELECT COUNT(*) FROM scan_meta").fetchone()[0]
        assert count == 5
        # Oldest scan should be gone
        gone = db.execute("SELECT * FROM scan_meta WHERE id = ?", (first,)).fetchall()
        assert len(gone) == 0

    def test_files_for_second_scan_survive(self, db: sqlite3.Connection) -> None:
        """After 3 scans, scan-2 (within files window) should still have files."""
        begin_scan(db, "s1")
        s2 = begin_scan(db, "s2")
        upsert_file_entry(db, FileEntry(path="b.py", scan_id=s2, loc=20))
        db.commit()
        begin_scan(db, "s3")

        rows = db.execute("SELECT * FROM files WHERE scan_id = ?", (s2,)).fetchall()
        assert len(rows) == 1, (
            "scan-2 files should survive (within _FILES_SCANS=2 window)"
        )


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


# ---------------------------------------------------------------------------
# Schema v3 migration (category column)
# ---------------------------------------------------------------------------


class TestSchemaV3:
    def test_new_db_has_category_column(
        self,
        db: sqlite3.Connection,
    ) -> None:
        """A freshly initialised DB has a category column in files."""
        cols = {r[1] for r in db.execute("PRAGMA table_info(files)").fetchall()}
        assert "category" in cols

    def test_category_default_is_production(
        self,
        db: sqlite3.Connection,
    ) -> None:
        """Inserting a file entry without specifying category gives 'production'."""
        sid = begin_scan(db, "abc123")
        upsert_file_entry(db, FileEntry(path="src/a.py", scan_id=sid, loc=10))
        db.commit()
        row = db.execute(
            "SELECT category FROM files WHERE path = ? AND scan_id = ?",
            ("src/a.py", sid),
        ).fetchone()
        assert row is not None
        assert row[0] == "production"

    def test_category_roundtrip(
        self,
        db: sqlite3.Connection,
    ) -> None:
        """category value set on FileEntry survives upsert and get."""
        sid = begin_scan(db, "abc123")
        entry = FileEntry(
            path="tests/test_foo.py",
            scan_id=sid,
            loc=50,
            category="test",
        )
        upsert_file_entry(db, entry)
        db.commit()
        results = get_file_entries(db, sid, path="tests/test_foo.py")
        assert len(results) == 1
        assert results[0].category == "test"

    def test_migration_adds_column_to_existing_db(
        self,
        tmp_path: Path,
    ) -> None:
        """Running init_db on a DB that lacks category column adds it."""
        # Bootstrap a DB without category (simulate pre-v3 DB).
        db_file = tmp_path / "quality.db"
        raw = sqlite3.connect(str(db_file))
        raw.executescript("""
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS scan_meta (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                scanned_at TEXT NOT NULL,
                git_head TEXT NOT NULL,
                files_count INTEGER,
                duration_ms INTEGER
            );
            CREATE TABLE IF NOT EXISTS files (
                path TEXT NOT NULL,
                scan_id INTEGER NOT NULL,
                language TEXT,
                loc INTEGER,
                complexity REAL,
                functions INTEGER,
                max_nesting INTEGER,
                avg_fn_len REAL,
                PRIMARY KEY(path, scan_id)
            );
        """)
        raw.commit()
        raw.close()

        # Now run init_db which should apply _migrate_v3
        conn = init_db(hot_zone=str(tmp_path))
        cols = {r[1] for r in conn.execute("PRAGMA table_info(files)").fetchall()}
        conn.close()
        assert "category" in cols

    def test_migration_idempotent(
        self,
        tmp_path: Path,
    ) -> None:
        """Running init_db twice on the same DB doesn't raise an error."""
        conn1 = init_db(hot_zone=str(tmp_path))
        conn1.close()
        conn2 = init_db(hot_zone=str(tmp_path))
        cols = {r[1] for r in conn2.execute("PRAGMA table_info(files)").fetchall()}
        conn2.close()
        assert "category" in cols


# ---------------------------------------------------------------------------
# Schema v5/v6/v7 migrations (bash_cc_backend, pattern_findings, ts_cc_backend)
# ---------------------------------------------------------------------------


class TestSchemaV5:
    def test_new_db_has_bash_cc_backend(self, db: sqlite3.Connection) -> None:
        cols = {r[1] for r in db.execute("PRAGMA table_info(scan_meta)").fetchall()}
        assert "bash_cc_backend" in cols

    def test_begin_scan_stores_backend(self, db: sqlite3.Connection) -> None:
        sid = begin_scan(db, "abc", bash_cc_backend="ast-grep")
        row = db.execute("SELECT bash_cc_backend FROM scan_meta WHERE id=?", (sid,)).fetchone()
        assert row[0] == "ast-grep"

    def test_latest_scan_returns_backend(self, db: sqlite3.Connection) -> None:
        begin_scan(db, "abc", bash_cc_backend="ast-grep")
        scan = latest_scan(db)
        assert scan is not None
        assert scan.bash_cc_backend == "ast-grep"

    def test_migration_adds_column_to_existing_db(self, tmp_path: Path) -> None:
        db_file = tmp_path / "quality.db"
        raw = sqlite3.connect(str(db_file))
        raw.executescript("""
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS scan_meta (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                scanned_at TEXT NOT NULL,
                git_head TEXT NOT NULL
            );
        """)
        raw.commit()
        raw.close()
        conn = init_db(hot_zone=str(tmp_path))
        cols = {r[1] for r in conn.execute("PRAGMA table_info(scan_meta)").fetchall()}
        conn.close()
        assert "bash_cc_backend" in cols


class TestSchemaV6:
    def test_new_db_has_pattern_findings_table(self, db: sqlite3.Connection) -> None:
        tables = {
            r[0]
            for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()
        }
        assert "pattern_findings" in tables

    def test_bulk_insert_and_query(self, db: sqlite3.Connection) -> None:
        sid = begin_pattern_run(db, "abc", ".")
        findings = [
            PatternFinding(path="a.py", scan_id=sid, rule_id="bare-except-pass",
                           line=10, col=0, match_text="except: pass", severity="warning"),
            PatternFinding(path="b.py", scan_id=sid, rule_id="subprocess-shell-true",
                           line=5, col=4, match_text="subprocess.run(x, shell=True)", severity="warning"),
        ]
        bulk_insert_pattern_findings(db, findings)
        db.commit()
        rows = query_pattern_findings(db, sid)
        assert len(rows) == 2
        paths = {r["path"] for r in rows}
        assert "a.py" in paths and "b.py" in paths

    def test_bulk_insert_replaces_existing_scan_findings(self, db: sqlite3.Connection) -> None:
        sid = begin_pattern_run(db, "abc", ".")
        bulk_insert_pattern_findings(
            db,
            [
                PatternFinding(path="a.py", scan_id=sid, rule_id="rule-A", line=1),
                PatternFinding(path="b.py", scan_id=sid, rule_id="rule-A", line=2),
            ],
        )

        bulk_insert_pattern_findings(
            db,
            [PatternFinding(path="c.py", scan_id=sid, rule_id="rule-B", line=3)],
        )

        rows = query_pattern_findings(db, sid)
        assert [(r["path"], r["rule_id"], r["line"]) for r in rows] == [
            ("c.py", "rule-B", 3)
        ]

    def test_query_filter_by_rule(self, db: sqlite3.Connection) -> None:
        sid = begin_pattern_run(db, "abc", ".")
        findings = [
            PatternFinding(path="a.py", scan_id=sid, rule_id="rule-A", line=1),
            PatternFinding(path="b.py", scan_id=sid, rule_id="rule-B", line=2),
        ]
        bulk_insert_pattern_findings(db, findings)
        db.commit()
        rows = query_pattern_findings(db, sid, rule_id="rule-A")
        assert len(rows) == 1
        assert rows[0]["rule_id"] == "rule-A"

    def test_summary_groups_by_rule(self, db: sqlite3.Connection) -> None:
        sid = begin_pattern_run(db, "abc", ".")
        findings = [
            PatternFinding(path="a.py", scan_id=sid, rule_id="rule-A", line=1),
            PatternFinding(path="b.py", scan_id=sid, rule_id="rule-A", line=2),
            PatternFinding(path="c.py", scan_id=sid, rule_id="rule-B", line=3),
        ]
        bulk_insert_pattern_findings(db, findings)
        db.commit()
        summary = pattern_findings_summary(db, sid)
        by_rule = {r["rule_id"]: r["hits"] for r in summary}
        assert by_rule["rule-A"] == 2
        assert by_rule["rule-B"] == 1

    def test_migration_creates_table_on_existing_db(self, tmp_path: Path) -> None:
        db_file = tmp_path / "quality.db"
        raw = sqlite3.connect(str(db_file))
        raw.executescript("""
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS scan_meta (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                scanned_at TEXT NOT NULL,
                git_head TEXT NOT NULL
            );
        """)
        raw.commit()
        raw.close()
        conn = init_db(hot_zone=str(tmp_path))
        tables = {
            r[0]
            for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()
        }
        conn.close()
        assert "pattern_findings" in tables

    def test_retention_prunes_pattern_findings(self, db: sqlite3.Connection) -> None:
        # pattern_findings is keyed off pattern_runs(id), independent of
        # scan_meta -- an unrelated complexity scan must not touch it.
        sid1 = begin_pattern_run(db, "aaa", ".")
        bulk_insert_pattern_findings(db, [
            PatternFinding(path="a.py", scan_id=sid1, rule_id="r", line=1)
        ])
        db.commit()
        begin_scan(db, "unrelated-complexity-scan")
        db.commit()
        remaining = {r[0] for r in db.execute("SELECT scan_id FROM pattern_findings").fetchall()}
        assert sid1 in remaining

        # pattern_runs has its own retention window (_MAX_PATTERN_RUNS=5),
        # decoupled from scan_meta's _MAX_SCANS/_FILES_SCANS.
        for i in range(5):
            run_id = begin_pattern_run(db, f"head{i}", ".")
            bulk_insert_pattern_findings(db, [
                PatternFinding(path=f"{i}.py", scan_id=run_id, rule_id="r", line=1)
            ])
            db.commit()
        remaining = {r[0] for r in db.execute("SELECT scan_id FROM pattern_findings").fetchall()}
        assert sid1 not in remaining


class TestSchemaV7:
    def test_new_db_has_ts_cc_backend(self, db: sqlite3.Connection) -> None:
        cols = {r[1] for r in db.execute("PRAGMA table_info(scan_meta)").fetchall()}
        assert "ts_cc_backend" in cols

    def test_begin_scan_stores_ts_backend(self, db: sqlite3.Connection) -> None:
        sid = begin_scan(db, "abc", ts_cc_backend="ast-grep")
        row = db.execute("SELECT ts_cc_backend FROM scan_meta WHERE id=?", (sid,)).fetchone()
        assert row[0] == "ast-grep"


class TestSchemaV8:
    def test_pattern_rule_receipts_distinguish_success_and_failure(
        self, db: sqlite3.Connection
    ) -> None:
        sid = begin_pattern_run(db, "abc", ".")
        replace_pattern_scan_results(
            db,
            sid,
            [],
            [
                {
                    "rule_id": "zero-hit",
                    "definition_hash": "abc123",
                    "rule_path": "/rules/zero-hit.yaml",
                    "target": "/repo/docs",
                    "hits": 0,
                    "ran_at": "2026-07-29T12:00:00",
                }
            ],
        )
        receipt = pattern_rule_runs(db, sid)[0]
        assert receipt["status"] == "success"
        assert receipt["hits"] == 0

        record_pattern_rule_failure(
            db,
            sid,
            "zero-hit",
            "def456",
            "/rules/zero-hit.yaml",
            "/repo/docs",
            "backend failed",
        )
        receipt = pattern_rule_runs(db, sid)[0]
        assert receipt["status"] == "failed"
        assert receipt["hits"] is None
        assert receipt["error"] == "backend failed"

    def test_record_pattern_rule_success_is_durable_before_the_scan_finishes(
        self, db: sqlite3.Connection
    ) -> None:
        """record_pattern_rule_success writes immediately (commits), unlike
        replace_pattern_scan_results' batched end-of-scan write -- a rule
        recorded this way must be queryable even if the caller never goes
        on to call replace_pattern_scan_results at all (e.g. a later rule
        in the same scan fails before that point is reached)."""
        sid = begin_pattern_run(db, "abc", ".")
        record_pattern_rule_success(
            db, sid, "rule-a", "hash-a", "/rules/rule-a.yaml", ".", 0,
        )
        receipt = pattern_rule_runs(db, sid)[0]
        assert receipt["status"] == "success"
        assert receipt["hits"] == 0
        assert receipt["error"] is None

        # Upsert semantics match record_pattern_rule_failure's.
        record_pattern_rule_success(
            db, sid, "rule-a", "hash-a2", "/rules/rule-a.yaml", ".", 3,
        )
        receipt = pattern_rule_runs(db, sid)[0]
        assert receipt["status"] == "success"
        assert receipt["hits"] == 3
        assert receipt["definition_hash"] == "hash-a2"

    def test_latest_scan_returns_ts_backend(self, db: sqlite3.Connection) -> None:
        begin_scan(db, "abc", ts_cc_backend="ast-grep")
        scan = latest_scan(db)
        assert scan is not None
        assert scan.ts_cc_backend == "ast-grep"

    def test_previous_scan_returns_ts_backend(self, db: sqlite3.Connection) -> None:
        begin_scan(db, "aaa", ts_cc_backend="ast-grep")
        begin_scan(db, "bbb", ts_cc_backend="unavailable")
        prev = previous_scan(db)
        assert prev is not None
        assert prev.ts_cc_backend == "ast-grep"

    def test_default_ts_backend_is_unavailable(self, db: sqlite3.Connection) -> None:
        begin_scan(db, "abc")
        scan = latest_scan(db)
        assert scan is not None
        assert scan.ts_cc_backend == "unavailable"

    def test_finish_scan_overwrites_ts_backend(self, db: sqlite3.Connection) -> None:
        """finish_scan ts_cc_backend param updates the placeholder set at begin_scan."""
        sid = begin_scan(db, "abc")  # default: 'unavailable'
        finish_scan(db, sid, files_count=5, duration_ms=100, ts_cc_backend="ast-grep")
        db.commit()
        scan = latest_scan(db)
        assert scan is not None
        assert scan.ts_cc_backend == "ast-grep"

    def test_finish_scan_ts_fallback_aggregate(self, db: sqlite3.Connection) -> None:
        """ast-grep+fallback written when some TS files succeeded, some did not."""
        sid = begin_scan(db, "abc")
        finish_scan(db, sid, files_count=3, duration_ms=50, ts_cc_backend="ast-grep+fallback")
        db.commit()
        scan = latest_scan(db)
        assert scan is not None
        assert scan.ts_cc_backend == "ast-grep+fallback"

    def test_migration_adds_column_to_existing_db(self, tmp_path: Path) -> None:
        db_file = tmp_path / "quality.db"
        raw = sqlite3.connect(str(db_file))
        raw.executescript("""
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS scan_meta (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                scanned_at TEXT NOT NULL,
                git_head TEXT NOT NULL,
                bash_cc_backend TEXT DEFAULT 'regex'
            );
        """)
        raw.commit()
        raw.close()
        conn = init_db(hot_zone=str(tmp_path))
        cols = {r[1] for r in conn.execute("PRAGMA table_info(scan_meta)").fetchall()}
        conn.close()
        assert "ts_cc_backend" in cols


class TestSchemaV9:
    def test_pre_v9_pattern_findings_migrates_before_key_index_creation(
        self, tmp_path: Path
    ) -> None:
        db_file = tmp_path / "quality.db"
        raw = sqlite3.connect(str(db_file))
        raw.executescript("""
            CREATE TABLE scan_meta (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                scanned_at TEXT NOT NULL,
                git_head TEXT NOT NULL
            );
            CREATE TABLE pattern_findings (
                id INTEGER PRIMARY KEY,
                scan_id INTEGER NOT NULL,
                path TEXT NOT NULL,
                rule_id TEXT NOT NULL,
                line INTEGER NOT NULL,
                col INTEGER DEFAULT 0,
                match_text TEXT,
                severity TEXT DEFAULT 'warning'
            );
        """)
        raw.close()

        conn = init_db(hot_zone=str(tmp_path))
        cols = {row[1] for row in conn.execute("PRAGMA table_info(pattern_findings)")}
        indexes = {
            row[1] for row in conn.execute("PRAGMA index_list(pattern_findings)")
        }
        conn.close()
        assert "finding_key" in cols
        assert "idx_pf_key" in indexes

    def test_disposition_and_recurrence_survive_scan_replacement_and_pruning(
        self, db: sqlite3.Connection
    ) -> None:
        sid1 = begin_pattern_run(db, "aaa", ".")
        finding = PatternFinding(
            path="docs/a.md",
            scan_id=sid1,
            rule_id="prose-test",
            line=2,
            match_text="genuine",
            finding_key="qf-stable",
            context_text="A genuine result.",
        )
        run = {
            "rule_id": "prose-test",
            "definition_hash": "abc123",
            "rule_path": "/rules/prose-test.yaml",
            "target": "/repo/docs",
            "hits": 1,
            "ran_at": "2026-07-30T12:00:00",
        }
        replace_pattern_scan_results(db, sid1, [finding], [run])
        row = adjudicate_pattern_finding(db, "qf-stable", "waived", "accepted wording")
        assert row is not None and row["disposition"] == "waived"

        sid2 = begin_pattern_run(db, "bbb", ".")
        finding.scan_id = sid2
        replace_pattern_scan_results(db, sid2, [finding], [run])
        # Replacing the same scan is not another recurrence.
        replace_pattern_scan_results(db, sid2, [finding], [run])
        # Replaying an older scan does not over-count or regress last_seen.
        finding.scan_id = sid1
        replace_pattern_scan_results(db, sid1, [finding], [run])
        begin_pattern_run(db, "ccc", ".")
        db.commit()

        state = pattern_finding_states(db, ["qf-stable"])[0]
        assert state["disposition"] == "waived"
        assert state["scan_count"] == 2
        assert state["first_seen_scan_id"] == sid1
        assert state["last_seen_scan_id"] == sid2
        history = db.execute(
            "SELECT disposition, note FROM pattern_finding_disposition_history "
            "WHERE finding_key = ?",
            ("qf-stable",),
        ).fetchall()
        assert [tuple(row) for row in history] == [("waived", "accepted wording")]
        report = pattern_adjudication_report(db)
        assert report["by_rule"]["prose-test"]["decided_precision"] == 1.0
        assert report["by_rule"]["prose-test"]["decided_count"] == 1
        assert report["recurring_waivers"][0]["scan_count"] == 2

    def test_adjudication_report_nudges_unresolved_recurring_rules(
        self, db: sqlite3.Connection
    ) -> None:
        """A rule with findings surviving ADJUDICATION_NUDGE_SCANS scans and
        zero human dispositions gets flagged -- zero decided_count is "no
        signal yet", not proof of low precision."""
        finding = PatternFinding(
            path="a.md",
            scan_id=0,
            rule_id="prose-test",
            finding_key="qf-unresolved",
            match_text="genuine",
            context_text="A genuine result.",
        )
        run = {
            "rule_id": "prose-test",
            "definition_hash": "abc123",
            "rule_path": "/rules/prose-test.yaml",
            "target": "/repo",
            "hits": 1,
            "ran_at": "2026-07-30T12:00:00",
        }
        for _ in range(ADJUDICATION_NUDGE_SCANS - 1):
            sid = begin_pattern_run(db, "aaa", ".")
            finding.scan_id = sid
            replace_pattern_scan_results(db, sid, [finding], [run])

        below_threshold = pattern_adjudication_report(db)
        assert below_threshold["by_rule"]["prose-test"]["needs_adjudication"] is False

        sid = begin_pattern_run(db, "aaa", ".")
        finding.scan_id = sid
        replace_pattern_scan_results(db, sid, [finding], [run])

        at_threshold = pattern_adjudication_report(db)
        summary = at_threshold["by_rule"]["prose-test"]
        assert summary["max_scan_count"] == ADJUDICATION_NUDGE_SCANS
        assert summary["needs_adjudication"] is True

        # A single disposition silences the nudge even though scan_count
        # keeps climbing -- there's human signal now.
        adjudicate_pattern_finding(db, "qf-unresolved", "waived")
        decided = pattern_adjudication_report(db)
        assert decided["by_rule"]["prose-test"]["needs_adjudication"] is False

    def test_adjudication_report_scopes_by_path_prefix(
        self, db: sqlite3.Connection
    ) -> None:
        sid = begin_pattern_run(db, "aaa", ".")
        docs_finding = PatternFinding(
            path="docs/a.md",
            scan_id=sid,
            rule_id="prose-test",
            finding_key="qf-docs",
            match_text="genuine",
            context_text="A genuine result.",
        )
        scripts_finding = PatternFinding(
            path="scripts/b.py",
            scan_id=sid,
            rule_id="prose-test",
            finding_key="qf-scripts",
            match_text="genuine",
            context_text="A genuine result.",
        )
        replace_pattern_scan_results(
            db, sid, [docs_finding, scripts_finding], []
        )
        adjudicate_pattern_finding(db, "qf-docs", "accepted_defect")
        adjudicate_pattern_finding(db, "qf-scripts", "false_positive")

        unscoped = pattern_adjudication_report(db)
        assert unscoped["by_rule"]["prose-test"]["decided_count"] == 2

        scoped = pattern_adjudication_report(db, path_prefix="docs")
        assert scoped["by_rule"]["prose-test"]["decided_count"] == 1
        assert scoped["by_rule"]["prose-test"]["decided_precision"] == 1.0

        exact_file_scope = pattern_adjudication_report(db, path_prefix="docs/a.md")
        assert exact_file_scope["by_rule"]["prose-test"]["decided_count"] == 1

        # A prefix that only shares characters (not a path segment) must not match --
        # "doc" should not pull in "docs/a.md".
        near_miss = pattern_adjudication_report(db, path_prefix="doc")
        assert not near_miss["by_rule"]

    def test_replacement_reconciles_disappeared_occurrence_without_losing_disposition(
        self, db: sqlite3.Connection
    ) -> None:
        sid1 = begin_pattern_run(db, "aaa", ".")
        finding = PatternFinding(
            path="a.md",
            scan_id=sid1,
            rule_id="r",
            finding_key="qf-reappears",
            match_text="match",
            context_text="context",
        )
        replace_pattern_scan_results(db, sid1, [finding], [])
        assert adjudicate_pattern_finding(db, finding.finding_key, "waived") is not None

        replace_pattern_scan_results(db, sid1, [], [])
        absent = pattern_finding_states(db, [finding.finding_key])[0]
        assert absent["scan_count"] == 0
        assert absent["first_seen_scan_id"] is None
        assert absent["last_seen_scan_id"] is None
        assert absent["disposition"] == "waived"
        assert pattern_adjudication_report(db)["finding_count"] == 0

        sid2 = begin_pattern_run(db, "bbb", ".")
        finding.scan_id = sid2
        replace_pattern_scan_results(db, sid2, [finding], [])
        reappeared = pattern_finding_states(db, [finding.finding_key])[0]
        assert reappeared["scan_count"] == 1
        assert reappeared["disposition"] == "waived"
        assert not pattern_adjudication_report(db)["recurring_waivers"]

    @pytest.mark.parametrize(
        "disposition",
        ["accepted_defect", "false_positive", "waived", "unresolved"],
    )
    def test_all_supported_dispositions_are_audited(
        self, db: sqlite3.Connection, disposition: str
    ) -> None:
        sid = begin_pattern_run(db, "aaa", ".")
        finding = PatternFinding(
            path="a.md",
            scan_id=sid,
            rule_id="r",
            finding_key="qf-one",
            context_text="context",
        )
        replace_pattern_scan_results(db, sid, [finding], [])
        assert adjudicate_pattern_finding(db, "qf-one", disposition) is not None
        history = db.execute(
            "SELECT disposition FROM pattern_finding_disposition_history"
        ).fetchone()
        assert history[0] == disposition


# Pre-v10 pattern_findings/pattern_rule_runs schema (FK'd to scan_meta),
# seeded with one finding + receipt under scan_id=1 -- shared by the
# interruption/migration fixtures below, since none of them can start from a
# live wv quality db (they need to construct a specific mid-migration state
# that init_db would never itself produce).
_TRUE_V9_SCHEMA_SQL = """
    CREATE TABLE scan_meta (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        scanned_at TEXT NOT NULL,
        git_head TEXT NOT NULL
    );
    CREATE TABLE pattern_findings (
        id INTEGER PRIMARY KEY,
        scan_id INTEGER NOT NULL,
        finding_key TEXT,
        path TEXT NOT NULL,
        rule_id TEXT NOT NULL,
        line INTEGER NOT NULL,
        col INTEGER DEFAULT 0,
        match_text TEXT,
        severity TEXT DEFAULT 'warning',
        FOREIGN KEY(scan_id) REFERENCES scan_meta(id) ON DELETE CASCADE
    );
    CREATE TABLE pattern_rule_runs (
        scan_id INTEGER NOT NULL,
        rule_id TEXT NOT NULL,
        definition_hash TEXT NOT NULL,
        rule_path TEXT NOT NULL,
        target TEXT NOT NULL,
        status TEXT NOT NULL,
        hits INTEGER,
        error TEXT,
        ran_at TEXT NOT NULL,
        FOREIGN KEY(scan_id) REFERENCES scan_meta(id) ON DELETE CASCADE,
        PRIMARY KEY(scan_id, rule_id)
    );
    CREATE TABLE pattern_finding_state (
        finding_key TEXT PRIMARY KEY,
        rule_id TEXT NOT NULL,
        path TEXT NOT NULL,
        match_text TEXT NOT NULL,
        context_text TEXT NOT NULL,
        first_seen_scan_id INTEGER,
        last_seen_scan_id INTEGER,
        scan_count INTEGER NOT NULL DEFAULT 1,
        disposition TEXT NOT NULL DEFAULT 'unresolved',
        note TEXT,
        adjudicated_at TEXT,
        updated_at TEXT NOT NULL
    );
    CREATE TABLE pattern_finding_occurrences (
        finding_key TEXT NOT NULL,
        scan_id INTEGER NOT NULL,
        PRIMARY KEY(finding_key, scan_id)
    );
    INSERT INTO scan_meta (id, scanned_at, git_head) VALUES (1, '2026-01-01T00:00:00', 'abc');
    INSERT INTO pattern_findings
        (scan_id, finding_key, path, rule_id, line, match_text)
        VALUES (1, 'qf-a', 'docs/a.md', 'r', 1, 'x');
    INSERT INTO pattern_rule_runs
        (scan_id, rule_id, definition_hash, rule_path, target, status, hits, ran_at)
        VALUES (1, 'r', 'hash', '/rules/r.yaml', 'docs', 'success', 1, '2026-01-01T00:00:00');
"""


class TestSchemaV10:
    def test_rebuild_recovers_a_backup_stranded_right_after_both_renames(
        self, tmp_path: Path
    ) -> None:
        """A crash right after both ALTER TABLE ... RENAME TO ..._v9
        statements (the old, non-atomic rebuild) leaves the live table names
        gone -- on restart _SCHEMA's CREATE TABLE IF NOT EXISTS silently
        recreates them fresh, already correctly FK'd to pattern_runs, which
        would make the ordinary FK-based rebuild check think nothing needs
        doing and strand the old rows in the _v9 backup forever."""
        db_file = tmp_path / "quality.db"
        raw = sqlite3.connect(str(db_file))
        raw.executescript(_TRUE_V9_SCHEMA_SQL)
        raw.executescript("""
            ALTER TABLE pattern_findings RENAME TO pattern_findings_v9;
            ALTER TABLE pattern_rule_runs RENAME TO pattern_rule_runs_v9;
        """)
        raw.close()

        conn = init_db(hot_zone=str(tmp_path))
        tables = {
            row[0]
            for row in conn.execute(
                "SELECT name FROM sqlite_master WHERE type = 'table'"
            ).fetchall()
        }
        findings = conn.execute("SELECT finding_key FROM pattern_findings").fetchall()
        receipts = conn.execute("SELECT rule_id FROM pattern_rule_runs").fetchall()
        conn.close()

        assert "pattern_findings_v9" not in tables
        assert "pattern_rule_runs_v9" not in tables
        assert [row[0] for row in findings] == ["qf-a"]
        assert [row[0] for row in receipts] == ["r"]

    def test_rebuild_repair_is_idempotent_when_the_copy_already_completed(
        self, tmp_path: Path
    ) -> None:
        """A crash after the INSERT...SELECT copy but before the DROP TABLE
        backup statements leaves BOTH the live table (already holding the
        copied rows) and the _v9 backup (still holding the same rows) --
        the repair merge must not duplicate them."""
        db_file = tmp_path / "quality.db"
        raw = sqlite3.connect(str(db_file))
        raw.executescript(_TRUE_V9_SCHEMA_SQL)
        raw.executescript("""
            ALTER TABLE pattern_findings RENAME TO pattern_findings_v9;
            ALTER TABLE pattern_rule_runs RENAME TO pattern_rule_runs_v9;
            CREATE TABLE pattern_runs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                started_at TEXT NOT NULL,
                git_head TEXT NOT NULL,
                target TEXT NOT NULL DEFAULT '.',
                files_count INTEGER,
                duration_ms INTEGER,
                finished_at TEXT
            );
            CREATE TABLE pattern_findings (
                id INTEGER PRIMARY KEY,
                scan_id INTEGER NOT NULL,
                finding_key TEXT,
                path TEXT NOT NULL,
                rule_id TEXT NOT NULL,
                line INTEGER NOT NULL,
                col INTEGER DEFAULT 0,
                match_text TEXT,
                severity TEXT DEFAULT 'warning',
                FOREIGN KEY(scan_id) REFERENCES pattern_runs(id) ON DELETE CASCADE
            );
            CREATE TABLE pattern_rule_runs (
                scan_id INTEGER NOT NULL,
                rule_id TEXT NOT NULL,
                definition_hash TEXT NOT NULL,
                rule_path TEXT NOT NULL,
                target TEXT NOT NULL,
                status TEXT NOT NULL,
                hits INTEGER,
                error TEXT,
                ran_at TEXT NOT NULL,
                FOREIGN KEY(scan_id) REFERENCES pattern_runs(id) ON DELETE CASCADE,
                PRIMARY KEY(scan_id, rule_id)
            );
            INSERT INTO pattern_findings
                (id, scan_id, finding_key, path, rule_id, line, col, match_text, severity)
                SELECT id, scan_id, finding_key, path, rule_id, line, col, match_text, severity
                FROM pattern_findings_v9;
            INSERT INTO pattern_rule_runs
                (scan_id, rule_id, definition_hash, rule_path, target, status, hits, error, ran_at)
                SELECT scan_id, rule_id, definition_hash, rule_path, target, status, hits, error, ran_at
                FROM pattern_rule_runs_v9;
        """)
        raw.close()

        conn = init_db(hot_zone=str(tmp_path))
        tables = {
            row[0]
            for row in conn.execute(
                "SELECT name FROM sqlite_master WHERE type = 'table'"
            ).fetchall()
        }
        findings = conn.execute("SELECT finding_key FROM pattern_findings").fetchall()
        receipts = conn.execute("SELECT rule_id FROM pattern_rule_runs").fetchall()
        conn.close()

        assert "pattern_findings_v9" not in tables
        assert "pattern_rule_runs_v9" not in tables
        assert [row[0] for row in findings] == ["qf-a"]
        assert [row[0] for row in receipts] == ["r"]

    def test_rebuild_handles_interruption_between_the_two_table_renames(
        self, tmp_path: Path
    ) -> None:
        """A crash between the two ALTER TABLE ... RENAME TO ..._v9
        statements strands only ONE table -- the other is still under its
        original name and old scan_meta-FK'd schema. Both must end up
        correctly rebuilt, not just the one the FK-based check happens to
        still recognize as needing work."""
        db_file = tmp_path / "quality.db"
        raw = sqlite3.connect(str(db_file))
        raw.executescript(_TRUE_V9_SCHEMA_SQL)
        raw.execute("ALTER TABLE pattern_findings RENAME TO pattern_findings_v9")
        raw.commit()
        raw.close()

        conn = init_db(hot_zone=str(tmp_path))
        tables = {
            row[0]
            for row in conn.execute(
                "SELECT name FROM sqlite_master WHERE type = 'table'"
            ).fetchall()
        }
        fk_rows = conn.execute("PRAGMA foreign_key_list(pattern_rule_runs)").fetchall()
        findings = conn.execute("SELECT finding_key FROM pattern_findings").fetchall()
        receipts = conn.execute("SELECT rule_id FROM pattern_rule_runs").fetchall()
        conn.close()

        assert "pattern_findings_v9" not in tables
        assert "pattern_rule_runs_v9" not in tables
        assert not any(row["table"] == "scan_meta" for row in fk_rows)
        assert [row[0] for row in findings] == ["qf-a"]
        assert [row[0] for row in receipts] == ["r"]

    def test_repair_preserves_a_distinct_finding_that_collides_on_id(
        self, tmp_path: Path
    ) -> None:
        """A stranded pattern_findings_v9 backup and the live table it was
        recreated alongside can legitimately hold DIFFERENT findings under
        the same id (id is a surrogate key, not a stable identity -- a
        fresh scan claimed id=1 for an unrelated finding after the old
        interrupted rebuild left the backup stranded). INSERT OR IGNORE
        would silently keep only the live row and then permanently lose
        the backup's when the backup is dropped -- the distinct backup row
        must survive under a fresh id instead."""
        db_file = tmp_path / "quality.db"
        raw = sqlite3.connect(str(db_file))
        raw.executescript(_TRUE_V9_SCHEMA_SQL)
        raw.executescript("""
            ALTER TABLE pattern_findings RENAME TO pattern_findings_v9;
            ALTER TABLE pattern_rule_runs RENAME TO pattern_rule_runs_v9;
            CREATE TABLE pattern_runs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                started_at TEXT NOT NULL,
                git_head TEXT NOT NULL,
                target TEXT NOT NULL DEFAULT '.',
                files_count INTEGER,
                duration_ms INTEGER,
                finished_at TEXT
            );
            CREATE TABLE pattern_findings (
                id INTEGER PRIMARY KEY,
                scan_id INTEGER NOT NULL,
                finding_key TEXT,
                path TEXT NOT NULL,
                rule_id TEXT NOT NULL,
                line INTEGER NOT NULL,
                col INTEGER DEFAULT 0,
                match_text TEXT,
                severity TEXT DEFAULT 'warning',
                FOREIGN KEY(scan_id) REFERENCES pattern_runs(id) ON DELETE CASCADE
            );
            CREATE TABLE pattern_rule_runs (
                scan_id INTEGER NOT NULL,
                rule_id TEXT NOT NULL,
                definition_hash TEXT NOT NULL,
                rule_path TEXT NOT NULL,
                target TEXT NOT NULL,
                status TEXT NOT NULL,
                hits INTEGER,
                error TEXT,
                ran_at TEXT NOT NULL,
                FOREIGN KEY(scan_id) REFERENCES pattern_runs(id) ON DELETE CASCADE,
                PRIMARY KEY(scan_id, rule_id)
            );
            -- A fresh pattern run (scan_id=2) claimed pattern_findings id=1
            -- for an UNRELATED finding after the interrupted rebuild
            -- stranded the backup -- the backup's own id=1 finding
            -- (scan_id=1, "qf-a") is a genuinely different row.
            INSERT INTO pattern_runs (id, started_at, git_head, target, finished_at)
                VALUES (2, '2026-02-01T00:00:00', 'def', '.', '2026-02-01T00:00:00');
            INSERT INTO pattern_findings
                (id, scan_id, finding_key, path, rule_id, line, match_text)
                VALUES (1, 2, 'qf-new', 'src/new.py', 'r', 1, 'y');
        """)
        raw.close()

        conn = init_db(hot_zone=str(tmp_path))
        tables = {
            row[0]
            for row in conn.execute(
                "SELECT name FROM sqlite_master WHERE type = 'table'"
            ).fetchall()
        }
        findings = {
            row["finding_key"]: row["path"]
            for row in conn.execute("SELECT finding_key, path FROM pattern_findings")
        }
        conn.close()

        assert "pattern_findings_v9" not in tables
        # Both the pre-existing live finding and the backup's distinct one
        # (reassigned a fresh id, since id=1 was already taken) survive.
        assert findings == {"qf-new": "src/new.py", "qf-a": "docs/a.md"}

    def test_repair_refuses_to_drop_a_backup_with_conflicting_rule_run_content(
        self, tmp_path: Path
    ) -> None:
        """(scan_id, rule_id) is pattern_rule_runs' real primary key --
        unlike pattern_findings.id, a content collision here means two
        different runs' receipts are being conflated, not a harmless
        reinsert. The repair must refuse to merge/drop rather than
        silently picking one receipt over the other."""
        db_file = tmp_path / "quality.db"
        raw = sqlite3.connect(str(db_file))
        raw.executescript(_TRUE_V9_SCHEMA_SQL)
        raw.executescript("""
            ALTER TABLE pattern_findings RENAME TO pattern_findings_v9;
            ALTER TABLE pattern_rule_runs RENAME TO pattern_rule_runs_v9;
            CREATE TABLE pattern_runs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                started_at TEXT NOT NULL,
                git_head TEXT NOT NULL,
                target TEXT NOT NULL DEFAULT '.',
                files_count INTEGER,
                duration_ms INTEGER,
                finished_at TEXT
            );
            CREATE TABLE pattern_findings (
                id INTEGER PRIMARY KEY,
                scan_id INTEGER NOT NULL,
                finding_key TEXT,
                path TEXT NOT NULL,
                rule_id TEXT NOT NULL,
                line INTEGER NOT NULL,
                col INTEGER DEFAULT 0,
                match_text TEXT,
                severity TEXT DEFAULT 'warning',
                FOREIGN KEY(scan_id) REFERENCES pattern_runs(id) ON DELETE CASCADE
            );
            CREATE TABLE pattern_rule_runs (
                scan_id INTEGER NOT NULL,
                rule_id TEXT NOT NULL,
                definition_hash TEXT NOT NULL,
                rule_path TEXT NOT NULL,
                target TEXT NOT NULL,
                status TEXT NOT NULL,
                hits INTEGER,
                error TEXT,
                ran_at TEXT NOT NULL,
                FOREIGN KEY(scan_id) REFERENCES pattern_runs(id) ON DELETE CASCADE,
                PRIMARY KEY(scan_id, rule_id)
            );
            INSERT INTO pattern_runs (id, started_at, git_head, target, finished_at)
                VALUES (1, '2026-01-01T00:00:00', 'abc', 'docs', '2026-01-01T00:00:00');
            -- Live receipt for (scan_id=1, rule_id='r') CONFLICTS with the
            -- backup's own receipt for the same key (different status).
            INSERT INTO pattern_rule_runs
                (scan_id, rule_id, definition_hash, rule_path, target, status, hits, ran_at)
                VALUES (1, 'r', 'hash', '/rules/r.yaml', 'docs', 'failed', NULL,
                        '2026-01-01T00:00:00');
        """)
        raw.close()

        with pytest.raises(PatternMigrationConflictError, match="conflict"):
            init_db(hot_zone=str(tmp_path))

        # The backup must still be there -- nothing was silently dropped.
        raw = sqlite3.connect(str(db_file))
        tables = {
            row[0]
            for row in raw.execute(
                "SELECT name FROM sqlite_master WHERE type = 'table'"
            ).fetchall()
        }
        raw.close()
        assert "pattern_rule_runs_v9" in tables

    def test_true_v9_backfill_preserves_the_receipt_target(self, tmp_path: Path) -> None:
        """A legacy id's real scan target lives on its pattern_rule_runs
        receipt (scan_meta never recorded one) -- hardcoding target='.'
        during backfill would silently turn a migrated scoped scan (of
        "docs", here) into a repo-root-scoped one now that report/list
        scope directly from pattern_runs.target (wv-40d3d6)."""
        db_file = tmp_path / "quality.db"
        raw = sqlite3.connect(str(db_file))
        raw.executescript(_TRUE_V9_SCHEMA_SQL)  # receipt target is 'docs'
        raw.close()

        conn = init_db(hot_zone=str(tmp_path))
        target = conn.execute("SELECT target FROM pattern_runs WHERE id = 1").fetchone()[0]
        conn.close()
        assert target == "docs"

    def test_true_v9_backfill_ignores_a_failed_receipts_target(self, tmp_path: Path) -> None:
        """Under v9's shared scan_id (complexity and pattern scans reused
        the same sequence), a root scan's successful findings could survive
        while a LATER, unrelated invocation reused the same scan_id and
        failed against a DIFFERENT target -- record_pattern_rule_failure's
        upsert deliberately preserves the earlier findings on failure. That
        failed receipt's target describes the later, unrelated attempt, not
        the run whose findings actually survived -- using it regardless of
        status would rescope root findings as if they were docs-scoped."""
        db_file = tmp_path / "quality.db"
        raw = sqlite3.connect(str(db_file))
        raw.executescript("""
            CREATE TABLE scan_meta (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                scanned_at TEXT NOT NULL,
                git_head TEXT NOT NULL
            );
            CREATE TABLE pattern_findings (
                id INTEGER PRIMARY KEY,
                scan_id INTEGER NOT NULL,
                finding_key TEXT,
                path TEXT NOT NULL,
                rule_id TEXT NOT NULL,
                line INTEGER NOT NULL,
                col INTEGER DEFAULT 0,
                match_text TEXT,
                severity TEXT DEFAULT 'warning',
                FOREIGN KEY(scan_id) REFERENCES scan_meta(id) ON DELETE CASCADE
            );
            CREATE TABLE pattern_rule_runs (
                scan_id INTEGER NOT NULL,
                rule_id TEXT NOT NULL,
                definition_hash TEXT NOT NULL,
                rule_path TEXT NOT NULL,
                target TEXT NOT NULL,
                status TEXT NOT NULL,
                hits INTEGER,
                error TEXT,
                ran_at TEXT NOT NULL,
                FOREIGN KEY(scan_id) REFERENCES scan_meta(id) ON DELETE CASCADE,
                PRIMARY KEY(scan_id, rule_id)
            );
            -- Root scan succeeded and stored a root finding.
            INSERT INTO pattern_findings
                (scan_id, finding_key, path, rule_id, line, match_text)
                VALUES (1, 'qf-root', 'src/root.py', 'r', 1, 'x');
            -- A LATER docs scan reused the same scan_id and failed --
            -- record_pattern_rule_failure's upsert overwrote the receipt
            -- with status='failed', target='docs', while preserving the
            -- root finding above untouched.
            INSERT INTO pattern_rule_runs
                (scan_id, rule_id, definition_hash, rule_path, target, status, error, ran_at)
                VALUES (1, 'r', 'hash', '/rules/r.yaml', 'docs', 'failed', 'boom',
                        '2026-01-02T00:00:00');
        """)
        raw.close()

        conn = init_db(hot_zone=str(tmp_path))
        target = conn.execute("SELECT target FROM pattern_runs WHERE id = 1").fetchone()[0]
        findings = conn.execute("SELECT path, finding_key FROM pattern_findings").fetchall()
        conn.close()
        assert target == "."
        assert [(row["path"], row["finding_key"]) for row in findings] == [
            ("src/root.py", "qf-root")
        ]

    def test_already_migrated_non_dot_mis_scoping_is_repaired_too(
        self, tmp_path: Path
    ) -> None:
        """The prior buggy release could already have persisted an
        INCORRECT non-'.' target (adopted from a later, unrelated failed
        receipt reusing the same v9 scan_id -- see wv-367b1c) before this
        fix shipped. A repair pass that only revisits rows currently
        sitting on '.' never examines that already-wrong 'docs' value --
        it must be reclassified from evidence regardless of its CURRENT
        target, not just when that happens to be the default."""
        conn = init_db(hot_zone=str(tmp_path))
        run_id = begin_pattern_run(conn, "abc", ".")
        finding = PatternFinding(
            path="src/root.py", scan_id=run_id, rule_id="r", finding_key="qf-root", line=1,
        )
        replace_pattern_scan_results(conn, run_id, [finding], [])
        finish_pattern_run(conn, run_id, files_count=1, duration_ms=10)
        # Simulate the OLD buggy migration's gap directly: a later, failed,
        # differently-targeted receipt got adopted as this run's target,
        # even though it has no successful evidence supporting "docs".
        conn.execute(
            "INSERT INTO pattern_rule_runs "
            "(scan_id, rule_id, definition_hash, rule_path, target, status, error, ran_at) "
            "VALUES (?, 'r', 'hash', '/rules/r.yaml', 'docs', 'failed', 'boom', "
            "'2026-01-02T00:00:00')",
            (run_id,),
        )
        conn.execute("UPDATE pattern_runs SET target = 'docs' WHERE id = ?", (run_id,))
        conn.commit()
        conn.close()

        conn = init_db(hot_zone=str(tmp_path))
        target = conn.execute(
            "SELECT target FROM pattern_runs WHERE id = ?", (run_id,)
        ).fetchone()[0]
        conn.close()
        assert target == "."

    def test_modern_failed_run_with_no_evidence_keeps_its_own_target(
        self, tmp_path: Path
    ) -> None:
        """A genuinely modern failed run (begin_pattern_run already recorded
        its real target correctly at creation time) publishes no findings
        or successful receipts under it -- it must be left untouched by
        reclassification, not rewritten to the conservative '.' fallback
        just because it has no successful-receipt evidence."""
        conn = init_db(hot_zone=str(tmp_path))
        run_id = begin_pattern_run(conn, "abc", "docs")
        record_pattern_rule_failure(
            conn, run_id, "r", "hash", "/rules/r.yaml", "docs", "boom",
        )
        conn.close()

        conn = init_db(hot_zone=str(tmp_path))
        target = conn.execute(
            "SELECT target FROM pattern_runs WHERE id = ?", (run_id,)
        ).fetchone()[0]
        conn.close()
        assert target == "docs"

    def test_already_migrated_dot_target_is_repaired_from_receipts(
        self, tmp_path: Path
    ) -> None:
        """An already-migrated row backfilled by the earlier buggy migration
        (which always hardcoded target='.') must be repaired from its
        receipts, not left silently repo-root-scoped."""
        conn = init_db(hot_zone=str(tmp_path))
        run_id = begin_pattern_run(conn, "abc", "docs")
        finding = PatternFinding(
            path="docs/a.md", scan_id=run_id, rule_id="r", finding_key="qf-a", line=1,
        )
        rule_run = {
            "rule_id": "r",
            "definition_hash": "hash",
            "rule_path": "/rules/r.yaml",
            "target": "docs",
            "hits": 1,
            "ran_at": "2026-01-01T00:00:00",
        }
        replace_pattern_scan_results(conn, run_id, [finding], [rule_run])
        finish_pattern_run(conn, run_id, files_count=1, duration_ms=10)
        # Simulate the earlier buggy migration's gap directly: the run's
        # target was hardcoded to '.' despite its receipt naming 'docs'.
        conn.execute("UPDATE pattern_runs SET target = '.' WHERE id = ?", (run_id,))
        conn.commit()
        conn.close()

        conn = init_db(hot_zone=str(tmp_path))
        target = conn.execute(
            "SELECT target FROM pattern_runs WHERE id = ?", (run_id,)
        ).fetchone()[0]
        conn.close()
        assert target == "docs"

    def test_occurrence_only_legacy_id_falls_back_to_dot_target(
        self, tmp_path: Path
    ) -> None:
        """A legacy id with no receipts at all (only a durable occurrence
        row survived v9 retention) has no target evidence to read -- it
        must fall back to '.', not raise or leave the row unreserved."""
        db_file = tmp_path / "quality.db"
        raw = sqlite3.connect(str(db_file))
        raw.executescript(_TRUE_V9_SCHEMA_SQL)
        raw.executescript("""
            DELETE FROM pattern_findings WHERE scan_id = 1;
            DELETE FROM pattern_rule_runs WHERE scan_id = 1;
            INSERT INTO pattern_finding_occurrences (finding_key, scan_id) VALUES ('qf-a', 1);
        """)
        raw.close()

        conn = init_db(hot_zone=str(tmp_path))
        target = conn.execute("SELECT target FROM pattern_runs WHERE id = 1").fetchone()[0]
        conn.close()
        assert target == "."

    def test_conflicting_receipt_targets_fall_back_to_dot_target(
        self, tmp_path: Path
    ) -> None:
        """Two receipts for the same legacy id that disagree on target
        (shouldn't happen in practice, but a defensively unioned legacy id
        must not silently pick one) fall back to '.' rather than guessing."""
        db_file = tmp_path / "quality.db"
        raw = sqlite3.connect(str(db_file))
        raw.executescript(_TRUE_V9_SCHEMA_SQL)
        raw.execute(
            "INSERT INTO pattern_rule_runs "
            "(scan_id, rule_id, definition_hash, rule_path, target, status, hits, ran_at) "
            "VALUES (1, 'r2', 'hash2', '/rules/r2.yaml', 'other', 'success', 1, "
            "'2026-01-01T00:00:00')"
        )
        raw.commit()
        raw.close()

        conn = init_db(hot_zone=str(tmp_path))
        target = conn.execute("SELECT target FROM pattern_runs WHERE id = 1").fetchone()[0]
        conn.close()
        assert target == "."

    def test_migration_reserves_ids_orphaned_in_occurrences_alone(
        self, tmp_path: Path
    ) -> None:
        """A finding's raw pattern_findings row and pattern_rule_runs receipt
        can already be pruned under v9 retention while its
        pattern_finding_occurrences rows (the durable scan_count evidence)
        remain. The migration must still reserve that scan_id in pattern_runs
        -- otherwise begin_pattern_run hands it back out to a brand new scan,
        and replace_pattern_scan_results deletes the old occurrence."""
        db_file = tmp_path / "quality.db"
        raw = sqlite3.connect(str(db_file))
        raw.executescript("""
            CREATE TABLE scan_meta (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                scanned_at TEXT NOT NULL,
                git_head TEXT NOT NULL
            );
            CREATE TABLE pattern_findings (
                id INTEGER PRIMARY KEY,
                scan_id INTEGER NOT NULL,
                finding_key TEXT,
                path TEXT NOT NULL,
                rule_id TEXT NOT NULL,
                line INTEGER NOT NULL,
                col INTEGER DEFAULT 0,
                match_text TEXT,
                severity TEXT DEFAULT 'warning',
                FOREIGN KEY(scan_id) REFERENCES scan_meta(id) ON DELETE CASCADE
            );
            CREATE TABLE pattern_rule_runs (
                scan_id INTEGER NOT NULL,
                rule_id TEXT NOT NULL,
                definition_hash TEXT NOT NULL,
                rule_path TEXT NOT NULL,
                target TEXT NOT NULL,
                status TEXT NOT NULL,
                hits INTEGER,
                error TEXT,
                ran_at TEXT NOT NULL,
                FOREIGN KEY(scan_id) REFERENCES scan_meta(id) ON DELETE CASCADE,
                PRIMARY KEY(scan_id, rule_id)
            );
            CREATE TABLE pattern_finding_state (
                finding_key TEXT PRIMARY KEY,
                rule_id TEXT NOT NULL,
                path TEXT NOT NULL,
                match_text TEXT NOT NULL,
                context_text TEXT NOT NULL,
                first_seen_scan_id INTEGER,
                last_seen_scan_id INTEGER,
                scan_count INTEGER NOT NULL DEFAULT 1,
                disposition TEXT NOT NULL DEFAULT 'unresolved',
                note TEXT,
                adjudicated_at TEXT,
                updated_at TEXT NOT NULL
            );
            CREATE TABLE pattern_finding_occurrences (
                finding_key TEXT NOT NULL,
                scan_id INTEGER NOT NULL,
                PRIMARY KEY(finding_key, scan_id)
            );
            -- pattern_findings/pattern_rule_runs for scan_id=1 are already
            -- pruned (empty) -- only the occurrence survives, as v9
            -- retention allows.
            INSERT INTO pattern_finding_occurrences (finding_key, scan_id)
                VALUES ('qf-old', 1);
            INSERT INTO pattern_finding_state
                (finding_key, rule_id, path, match_text, context_text,
                 first_seen_scan_id, last_seen_scan_id, scan_count,
                 disposition, updated_at)
                VALUES ('qf-old', 'r', 'a.md', 'x', 'x', 1, 1, 1,
                        'waived', '2026-01-01T00:00:00');
        """)
        raw.close()

        conn = init_db(hot_zone=str(tmp_path))
        reserved = {row[0] for row in conn.execute("SELECT id FROM pattern_runs")}
        assert 1 in reserved

        new_run_id = begin_pattern_run(conn, "new-head", ".")
        assert new_run_id != 1
        replace_pattern_scan_results(conn, new_run_id, [], [])

        old_occurrences = conn.execute(
            "SELECT scan_id FROM pattern_finding_occurrences WHERE finding_key = 'qf-old'"
        ).fetchall()
        assert [row[0] for row in old_occurrences] == [1]
        old_state = pattern_finding_states(conn, ["qf-old"])[0]
        assert old_state["scan_count"] == 1
        assert old_state["disposition"] == "waived"

    def test_repeated_failures_do_not_evict_the_last_successful_run(
        self, db: sqlite3.Connection
    ) -> None:
        """begin_pattern_run creates and (now) prunes a run before its rule
        loop executes -- a failed run is still committed as a row. Retention
        must count finished and unfinished runs in separate windows, or a
        chain of failures alone can prune away an earlier successful run's
        findings even though it was never touched by any of them."""
        good_run = begin_pattern_run(db, "good", ".")
        finding = PatternFinding(
            path="a.md", scan_id=good_run, rule_id="r", finding_key="qf-good", line=1,
        )
        replace_pattern_scan_results(db, good_run, [finding], [])
        finish_pattern_run(db, good_run, files_count=1, duration_ms=10)

        for i in range(_MAX_PATTERN_RUNS + 1):
            failed_run = begin_pattern_run(db, f"bad{i}", ".")
            record_pattern_rule_failure(
                db, failed_run, "r", "hash", "/rules/r.yaml", ".", "boom",
            )

        remaining = {
            r[0] for r in db.execute("SELECT scan_id FROM pattern_findings").fetchall()
        }
        assert good_run in remaining
        assert pattern_finding_states(db, ["qf-good"])[0]["scan_count"] == 1

    def test_true_v9_backfill_classifies_finished_at_from_evidence(
        self, tmp_path: Path
    ) -> None:
        """A pre-v10 database (pattern_findings/pattern_rule_runs still FK'd to
        scan_meta, no pattern_runs table at all) backfills one pattern_runs
        row per legacy scan_id. A legacy id with a real finding is finished;
        a legacy id that only ever has a failed receipt (every rule errored,
        nothing matched) is not a completed scan and must stay unfinished."""
        db_file = tmp_path / "quality.db"
        raw = sqlite3.connect(str(db_file))
        raw.executescript("""
            CREATE TABLE scan_meta (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                scanned_at TEXT NOT NULL,
                git_head TEXT NOT NULL
            );
            CREATE TABLE pattern_findings (
                id INTEGER PRIMARY KEY,
                scan_id INTEGER NOT NULL,
                finding_key TEXT,
                path TEXT NOT NULL,
                rule_id TEXT NOT NULL,
                line INTEGER NOT NULL,
                col INTEGER DEFAULT 0,
                match_text TEXT,
                severity TEXT DEFAULT 'warning',
                FOREIGN KEY(scan_id) REFERENCES scan_meta(id) ON DELETE CASCADE
            );
            CREATE TABLE pattern_rule_runs (
                scan_id INTEGER NOT NULL,
                rule_id TEXT NOT NULL,
                definition_hash TEXT NOT NULL,
                rule_path TEXT NOT NULL,
                target TEXT NOT NULL,
                status TEXT NOT NULL,
                hits INTEGER,
                error TEXT,
                ran_at TEXT NOT NULL,
                FOREIGN KEY(scan_id) REFERENCES scan_meta(id) ON DELETE CASCADE,
                PRIMARY KEY(scan_id, rule_id)
            );
            CREATE TABLE pattern_finding_state (
                finding_key TEXT PRIMARY KEY,
                rule_id TEXT NOT NULL,
                path TEXT NOT NULL,
                match_text TEXT NOT NULL,
                context_text TEXT NOT NULL,
                first_seen_scan_id INTEGER,
                last_seen_scan_id INTEGER,
                scan_count INTEGER NOT NULL DEFAULT 1,
                disposition TEXT NOT NULL DEFAULT 'unresolved',
                note TEXT,
                adjudicated_at TEXT,
                updated_at TEXT NOT NULL
            );
            CREATE TABLE pattern_finding_occurrences (
                finding_key TEXT NOT NULL,
                scan_id INTEGER NOT NULL,
                PRIMARY KEY(finding_key, scan_id)
            );
            -- scan_id=1: a real finding -- a completed, successful v9 scan.
            INSERT INTO pattern_findings
                (scan_id, finding_key, path, rule_id, line, match_text)
                VALUES (1, 'qf-hit', 'a.md', 'r', 1, 'x');
            INSERT INTO pattern_rule_runs
                (scan_id, rule_id, definition_hash, rule_path, target, status, hits, ran_at)
                VALUES (1, 'r', 'hash', '/rules/r.yaml', '.', 'success', 1, '2026-01-01T00:00:00');
            -- scan_id=2: every rule errored, nothing ever matched -- not a
            -- completed scan, even though it left a v9 receipt row.
            INSERT INTO pattern_rule_runs
                (scan_id, rule_id, definition_hash, rule_path, target, status, error, ran_at)
                VALUES (2, 'r', 'hash', '/rules/r.yaml', '.', 'failed', 'boom', '2026-01-01T00:00:00');
        """)
        raw.close()

        conn = init_db(hot_zone=str(tmp_path))
        rows = {
            row["id"]: row["finished_at"]
            for row in conn.execute("SELECT id, finished_at FROM pattern_runs")
        }
        assert rows[1] is not None
        assert rows[2] is None

    def test_already_migrated_buggy_v10_reclassifies_finished_at_from_evidence(
        self, tmp_path: Path
    ) -> None:
        """A database already migrated by the earlier buggy _migrate_v10 (one
        that only set finished_at on newly-INSERTed rows) has a pattern_runs
        row for a genuinely successful run sitting on finished_at = NULL.
        init_db must reclassify it from evidence so subsequent failures
        cannot evict it -- the exact regression this migration exists to
        prevent."""
        conn = init_db(hot_zone=str(tmp_path))
        good_run = begin_pattern_run(conn, "good", ".")
        finding = PatternFinding(
            path="a.md", scan_id=good_run, rule_id="r", finding_key="qf-good", line=1,
        )
        replace_pattern_scan_results(conn, good_run, [finding], [])
        # Simulate the earlier buggy migration's gap directly: a row with
        # legacy provenance (as a real v9-backfilled row would carry) sitting
        # on finished_at = NULL despite having real evidence attached.
        # origin='legacy' is set explicitly here because begin_pattern_run
        # above stamped 'native' -- this row stands in for a genuine legacy
        # backfill artifact, not an in-progress native invocation (which
        # test_native_partial_success_then_failure_stays_unfinished_across_reopen
        # covers separately and must NOT be reclassified this way).
        conn.execute(
            "UPDATE pattern_runs SET finished_at = NULL, origin = 'legacy' WHERE id = ?",
            (good_run,),
        )
        conn.commit()
        conn.close()

        conn = init_db(hot_zone=str(tmp_path))
        finished_at = conn.execute(
            "SELECT finished_at FROM pattern_runs WHERE id = ?", (good_run,)
        ).fetchone()[0]
        assert finished_at is not None

        for i in range(_MAX_PATTERN_RUNS + 1):
            failed_run = begin_pattern_run(conn, f"bad{i}", ".")
            record_pattern_rule_failure(
                conn, failed_run, "r", "hash", "/rules/r.yaml", ".", "boom",
            )

        remaining = {
            r[0] for r in conn.execute("SELECT scan_id FROM pattern_findings").fetchall()
        }
        assert good_run in remaining
        assert pattern_finding_states(conn, ["qf-good"])[0]["scan_count"] == 1

    def test_migration_reclassification_leaves_a_genuinely_unfinished_run_null(
        self, tmp_path: Path
    ) -> None:
        """A row with no findings, no occurrences, and no successful receipt
        (an interrupted run, or one where every rule failed) has no evidence
        of completion and must stay classified unfinished across an init_db
        re-run -- the reclassification pass must not blanket-mark every NULL
        row finished."""
        conn = init_db(hot_zone=str(tmp_path))
        failed_run = begin_pattern_run(conn, "bad", ".")
        record_pattern_rule_failure(
            conn, failed_run, "r", "hash", "/rules/r.yaml", ".", "boom",
        )
        conn.close()

        conn = init_db(hot_zone=str(tmp_path))
        finished_at = conn.execute(
            "SELECT finished_at FROM pattern_runs WHERE id = ?", (failed_run,)
        ).fetchone()[0]
        assert finished_at is None

    def test_native_partial_success_then_failure_stays_unfinished_across_reopen(
        self, tmp_path: Path
    ) -> None:
        """A NATIVE run (created by begin_pattern_run, not legacy-backfilled)
        where one rule's successful receipt was durably committed
        (record_pattern_rule_success, wv-29aeb0) before a LATER rule in the
        same invocation fails -- or the process crashes -- has real success
        evidence but was never finished via finish_pattern_run. Unlike a
        legacy-backfilled row, this run's finished_at must stay NULL across
        a database reopen: the evidence-based reclassification heuristic is
        only valid for origin='legacy' rows (see wv-033ec6). Before that
        fix, _migrate_v10 promoted this exact partial run to finished on
        every init_db() call."""
        conn = init_db(hot_zone=str(tmp_path))
        run_id = begin_pattern_run(conn, "head", "docs")
        record_pattern_rule_success(
            conn, run_id, "a", "ha", "/rules/a.yaml", "docs", 0,
        )
        record_pattern_rule_failure(
            conn, run_id, "b", "hb", "/rules/b.yaml", "docs", "boom",
        )
        assert (
            conn.execute(
                "SELECT finished_at FROM pattern_runs WHERE id = ?", (run_id,)
            ).fetchone()[0]
            is None
        )
        conn.close()

        conn = init_db(hot_zone=str(tmp_path))
        finished_at = conn.execute(
            "SELECT finished_at FROM pattern_runs WHERE id = ?", (run_id,)
        ).fetchone()[0]
        assert finished_at is None
        # Both immediately-committed receipts must still be intact -- this
        # regression is about lifecycle state, not receipt durability.
        receipts = {row["rule_id"]: row["status"] for row in pattern_rule_runs(conn, run_id)}
        assert receipts == {"a": "success", "b": "failed"}

    def test_origin_less_existing_native_row_is_not_promoted_to_finished(
        self, tmp_path: Path
    ) -> None:
        """The real upgrade shape wv-033ec6's own regression test doesn't
        exercise: a pattern_runs table that already exists WITHOUT an origin
        column (built by a pre-origin version of this migration) can hold a
        row that is actually a partial/interrupted NATIVE run, not a legacy
        backfill -- e.g. one immediate successful receipt committed, then a
        crash or a later rule's failure, before origin shipped. Defaulting
        every origin-less existing row to 'legacy' at ALTER time (the
        original bug) hands this row straight to the evidence-based
        finished_at reconstruction pass and promotes it to finished on the
        very next init_db(), even though finish_pattern_run never ran."""
        db_file = tmp_path / "quality.db"
        raw = sqlite3.connect(str(db_file))
        raw.executescript("""
            CREATE TABLE pattern_runs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                started_at TEXT NOT NULL,
                git_head TEXT NOT NULL,
                target TEXT NOT NULL DEFAULT '.',
                files_count INTEGER,
                duration_ms INTEGER,
                finished_at TEXT
            );
            CREATE TABLE pattern_findings (
                id INTEGER PRIMARY KEY,
                scan_id INTEGER NOT NULL,
                finding_key TEXT,
                path TEXT NOT NULL,
                rule_id TEXT NOT NULL,
                line INTEGER NOT NULL,
                col INTEGER DEFAULT 0,
                match_text TEXT,
                severity TEXT DEFAULT 'warning',
                FOREIGN KEY(scan_id) REFERENCES pattern_runs(id) ON DELETE CASCADE
            );
            CREATE TABLE pattern_rule_runs (
                scan_id INTEGER NOT NULL,
                rule_id TEXT NOT NULL,
                definition_hash TEXT NOT NULL,
                rule_path TEXT NOT NULL,
                target TEXT NOT NULL,
                status TEXT NOT NULL,
                hits INTEGER,
                error TEXT,
                ran_at TEXT NOT NULL,
                FOREIGN KEY(scan_id) REFERENCES pattern_runs(id) ON DELETE CASCADE,
                PRIMARY KEY(scan_id, rule_id)
            );
            -- id=1: a NATIVE run from before `origin` shipped -- one rule's
            -- success receipt durably committed (wv-29aeb0), then the
            -- invocation never finished (a later rule failed, or a crash).
            INSERT INTO pattern_runs (id, started_at, git_head, target, finished_at)
                VALUES (1, '2026-02-01T00:00:00', 'abc', '.', NULL);
            INSERT INTO pattern_rule_runs
                (scan_id, rule_id, definition_hash, rule_path, target, status, hits, ran_at)
                VALUES (1, 'a', 'ha', '/rules/a.yaml', '.', 'success', 0, '2026-02-01T00:00:00');
            INSERT INTO pattern_rule_runs
                (scan_id, rule_id, definition_hash, rule_path, target, status, error, ran_at)
                VALUES (1, 'b', 'hb', '/rules/b.yaml', '.', 'failed', 'boom', '2026-02-01T00:00:00');
        """)
        raw.close()

        conn = init_db(hot_zone=str(tmp_path))
        row = conn.execute(
            "SELECT finished_at, origin FROM pattern_runs WHERE id = 1"
        ).fetchone()
        conn.close()

        assert row["finished_at"] is None
        assert row["origin"] != "legacy"

    def test_omitted_origin_write_on_a_current_schema_db_is_not_promoted_to_finished(
        self, tmp_path: Path
    ) -> None:
        """A pre-origin or downgraded writer that INSERTs into pattern_runs
        without naming the origin column at all -- no ALTER involved, this
        is a plain insert against an ALREADY-current schema -- must not get
        the column's default silently mislabeled 'legacy'. One immediate
        success receipt (record_pattern_rule_success, wv-29aeb0) then a
        reopen must not promote the still-unfinished row to finished."""
        conn = init_db(hot_zone=str(tmp_path))
        conn.execute(
            "INSERT INTO pattern_runs (started_at, git_head, target) VALUES (?, ?, ?)",
            ("2026-02-01T00:00:00", "h", "docs"),
        )
        conn.commit()
        run_id = conn.execute(
            "SELECT id FROM pattern_runs WHERE started_at = '2026-02-01T00:00:00'"
        ).fetchone()[0]
        before = conn.execute(
            "SELECT origin, finished_at FROM pattern_runs WHERE id = ?", (run_id,)
        ).fetchone()
        assert before["origin"] != "legacy"
        assert before["finished_at"] is None

        record_pattern_rule_success(
            conn, run_id, "a", "ha", "/rules/a.yaml", "docs", 0,
        )
        conn.close()

        conn = init_db(hot_zone=str(tmp_path))
        after = conn.execute(
            "SELECT origin, finished_at FROM pattern_runs WHERE id = ?", (run_id,)
        ).fetchone()
        assert after["origin"] != "legacy"
        assert after["finished_at"] is None

    def test_deployed_db_with_stale_legacy_default_is_rebuilt_on_reopen(
        self, tmp_path: Path
    ) -> None:
        """CREATE TABLE IF NOT EXISTS never retrofits an EXISTING table's
        schema -- a database created by the immediately-preceding schema
        (origin column already present, but still defaulting to 'legacy')
        keeps that stale default forever unless explicitly rebuilt. An old
        writer that omits origin on such a database must not silently
        inherit 'legacy' and get promoted to finished from one receipt.
        Also verifies the rebuild preserves an existing row (its own
        'legacy' origin unchanged) and FK-referencing pattern_findings."""
        db_file = tmp_path / "quality.db"
        raw = sqlite3.connect(str(db_file))
        raw.executescript("""
            CREATE TABLE pattern_runs (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                started_at  TEXT NOT NULL,
                git_head    TEXT NOT NULL,
                target      TEXT NOT NULL DEFAULT '.',
                files_count INTEGER,
                duration_ms INTEGER,
                finished_at TEXT,
                origin      TEXT NOT NULL DEFAULT 'legacy'
            );
            CREATE TABLE pattern_findings (
                id INTEGER PRIMARY KEY,
                scan_id INTEGER NOT NULL,
                finding_key TEXT,
                path TEXT NOT NULL,
                rule_id TEXT NOT NULL,
                line INTEGER NOT NULL,
                col INTEGER DEFAULT 0,
                match_text TEXT,
                severity TEXT DEFAULT 'warning',
                FOREIGN KEY(scan_id) REFERENCES pattern_runs(id) ON DELETE CASCADE
            );
            CREATE TABLE pattern_rule_runs (
                scan_id INTEGER NOT NULL,
                rule_id TEXT NOT NULL,
                definition_hash TEXT NOT NULL,
                rule_path TEXT NOT NULL,
                target TEXT NOT NULL,
                status TEXT NOT NULL,
                hits INTEGER,
                error TEXT,
                ran_at TEXT NOT NULL,
                FOREIGN KEY(scan_id) REFERENCES pattern_runs(id) ON DELETE CASCADE,
                PRIMARY KEY(scan_id, rule_id)
            );
            -- A pre-existing, genuinely finished legacy run with a real
            -- finding attached -- must survive the rebuild untouched.
            INSERT INTO pattern_runs (id, started_at, git_head, target)
                VALUES (99, '2020-01-01T00:00:00', 'abc', '.');
            INSERT INTO pattern_findings
                (scan_id, finding_key, path, rule_id, line, match_text)
                VALUES (99, 'qf-old', 'a.md', 'r', 1, 'x');
        """)
        raw.close()

        conn = init_db(hot_zone=str(tmp_path))
        origin_col = next(
            row for row in conn.execute("PRAGMA table_info(pattern_runs)") if row["name"] == "origin"
        )
        assert origin_col["dflt_value"] == "'unknown'"

        # The pre-existing legacy row and its finding both survived the
        # rebuild unchanged -- only the table's DEFAULT clause changed.
        old_row = conn.execute("SELECT origin FROM pattern_runs WHERE id = 99").fetchone()
        assert old_row["origin"] == "legacy"
        assert conn.execute(
            "SELECT 1 FROM pattern_findings WHERE scan_id = 99"
        ).fetchone() is not None

        # An old writer that omits origin entirely on this now-rebuilt,
        # already-current-schema database must not silently get 'legacy'.
        conn.execute(
            "INSERT INTO pattern_runs (started_at, git_head, target) VALUES (?, ?, ?)",
            ("t", "h", "docs"),
        )
        conn.commit()
        run_id = conn.execute(
            "SELECT id FROM pattern_runs WHERE started_at = 't'"
        ).fetchone()[0]
        before = conn.execute(
            "SELECT origin, finished_at FROM pattern_runs WHERE id = ?", (run_id,)
        ).fetchone()
        assert before["origin"] == "unknown"
        assert before["finished_at"] is None
        record_pattern_rule_success(conn, run_id, "a", "ha", "/rules/a.yaml", "docs", 0)
        conn.close()

        conn = init_db(hot_zone=str(tmp_path))
        after = conn.execute(
            "SELECT origin, finished_at FROM pattern_runs WHERE id = ?", (run_id,)
        ).fetchone()
        assert after["origin"] == "unknown"
        assert after["finished_at"] is None

        # FK enforcement (including ON DELETE CASCADE) still works after
        # the rebuild -- confirms `foreign_keys` was correctly restored.
        conn.execute("DELETE FROM pattern_runs WHERE id = 99")
        conn.commit()
        assert conn.execute(
            "SELECT 1 FROM pattern_findings WHERE scan_id = 99"
        ).fetchone() is None
