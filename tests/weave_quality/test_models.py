"""Tests for weave_quality.models dataclasses."""

# pylint: disable=missing-class-docstring,missing-function-docstring

from __future__ import annotations

from weave_quality.models import (
    CKMetrics,
    CoChange,
    FileEntry,
    FileState,
    GitStats,
    ProjectMetrics,
    ScanMeta,
)


# ---------------------------------------------------------------------------
# FileEntry
# ---------------------------------------------------------------------------


class TestFileEntry:
    def test_defaults(self) -> None:
        fe = FileEntry(path="foo.py")
        assert fe.language == "unknown"
        assert fe.complexity == 0.0
        assert fe.functions == 0
        assert fe.avg_fn_len == 0.0

    def test_to_dict_keys(self) -> None:
        fe = FileEntry(path="src/main.py", scan_id=1, language="python")
        d = fe.to_dict()
        assert set(d.keys()) == {
            "path", "scan_id", "language", "loc", "complexity",
            "functions", "max_nesting", "avg_fn_len",
        }
        assert d["path"] == "src/main.py"
        assert d["scan_id"] == 1

    def test_round_trip(self) -> None:
        fe = FileEntry(
            path="a.py",
            scan_id=2,
            language="python",
            loc=150,
            complexity=12.5,
            functions=8,
            max_nesting=4,
            avg_fn_len=15.3,
        )
        d = fe.to_dict()
        fe2 = FileEntry.from_dict(d)
        assert fe2.path == fe.path
        assert fe2.scan_id == fe.scan_id
        assert fe2.complexity == fe.complexity
        assert fe2.avg_fn_len == fe.avg_fn_len

    def test_from_dict_defaults(self) -> None:
        fe = FileEntry.from_dict({"path": "x.py"})
        assert fe.language == "unknown"
        assert fe.loc == 0


# ---------------------------------------------------------------------------
# CKMetrics
# ---------------------------------------------------------------------------


class TestCKMetrics:
    def test_to_rows(self) -> None:
        ck = CKMetrics(
            path="a.py", scan_id=1,
            metrics={"wmc": 5.0, "cbo": 3.0, "bogus": 99.0},
        )
        rows = ck.to_rows()
        names = {r["metric"] for r in rows}
        # bogus is filtered out
        assert "bogus" not in names
        assert "wmc" in names
        assert "cbo" in names
        assert all(r["path"] == "a.py" for r in rows)

    def test_from_rows_empty(self) -> None:
        assert CKMetrics.from_rows([]) is None

    def test_round_trip(self) -> None:
        ck = CKMetrics(
            path="b.py", scan_id=3,
            metrics={"wmc": 12.0, "rfc": 4.0, "lcom": 0.5},
        )
        rows = ck.to_rows()
        ck2 = CKMetrics.from_rows(rows)
        assert ck2 is not None
        assert ck2.path == "b.py"
        assert ck2.metrics["wmc"] == 12.0

    def test_valid_metrics_filter(self) -> None:
        ck = CKMetrics(
            path="c.py", scan_id=1,
            metrics={"wmc": 1.0, "invalid_metric": 2.0},
        )
        rows = ck.to_rows()
        assert len(rows) == 1
        assert rows[0]["metric"] == "wmc"


# ---------------------------------------------------------------------------
# GitStats
# ---------------------------------------------------------------------------


class TestGitStats:
    def test_defaults(self) -> None:
        gs = GitStats(path="foo.py")
        assert gs.churn == 0
        assert gs.hotspot == 0.0

    def test_round_trip(self) -> None:
        gs = GitStats(path="a.py", churn=42, authors=3, age_days=180, hotspot=0.85)
        d = gs.to_dict()
        gs2 = GitStats.from_dict(d)
        assert gs2.path == "a.py"
        assert gs2.churn == 42
        assert gs2.hotspot == 0.85


# ---------------------------------------------------------------------------
# CoChange
# ---------------------------------------------------------------------------


class TestCoChange:
    def test_creation(self) -> None:
        cc = CoChange(path_a="a.py", path_b="b.py", count=5)
        assert cc.count == 5

    def test_defaults(self) -> None:
        cc = CoChange(path_a="x.py", path_b="y.py")
        assert cc.count == 0


# ---------------------------------------------------------------------------
# FileState
# ---------------------------------------------------------------------------


class TestFileState:
    def test_defaults(self) -> None:
        fs = FileState(path="foo.py")
        assert fs.mtime == 0
        assert fs.git_blob == ""

    def test_round_trip(self) -> None:
        fs = FileState(path="a.py", mtime=1700000000, git_blob="abc123")
        d = fs.to_dict()
        fs2 = FileState.from_dict(d)
        assert fs2.path == "a.py"
        assert fs2.mtime == 1700000000
        assert fs2.git_blob == "abc123"


# ---------------------------------------------------------------------------
# ScanMeta
# ---------------------------------------------------------------------------


class TestScanMeta:
    def test_create(self) -> None:
        sm = ScanMeta.create(git_head="abc123", files_count=10, duration_ms=500)
        assert sm.git_head == "abc123"
        assert sm.files_count == 10
        assert sm.scanned_at != ""

    def test_is_stale_same_head(self) -> None:
        sm = ScanMeta(git_head="abc123")
        assert not sm.is_stale("abc123")

    def test_is_stale_different_head(self) -> None:
        sm = ScanMeta(git_head="abc123")
        assert sm.is_stale("def456")


# ---------------------------------------------------------------------------
# ProjectMetrics
# ---------------------------------------------------------------------------


class TestProjectMetrics:
    def test_empty(self) -> None:
        pm = ProjectMetrics.from_entries_and_stats([], [])
        assert pm.total_files == 0
        assert pm.avg_complexity == 0.0

    def test_aggregation(self) -> None:
        entries = [
            FileEntry(path="a.py", complexity=10.0, loc=100, functions=5),
            FileEntry(path="b.py", complexity=4.0, loc=50, functions=3),
        ]
        stats = [
            GitStats(path="a.py", churn=5, hotspot=0.9),
            GitStats(path="b.py", churn=15, hotspot=0.3),
        ]
        pm = ProjectMetrics.from_entries_and_stats(entries, stats, top_n=1)
        assert pm.total_files == 2
        assert pm.total_loc == 150
        assert pm.avg_complexity == 7.0
        assert pm.max_complexity == 10.0
        assert pm.avg_churn == 10.0
        assert len(pm.top_hotspots) == 1
        assert pm.top_hotspots[0][0] == "a.py"

    def test_hotspot_threshold(self) -> None:
        entries = [FileEntry(path="a.py", complexity=5.0)]
        stats = [GitStats(path="a.py", hotspot=0.3)]
        pm = ProjectMetrics.from_entries_and_stats(entries, stats, hotspot_threshold=0.5)
        assert pm.hotspot_count == 0

    def test_entries_without_stats(self) -> None:
        entries = [
            FileEntry(path="a.py", complexity=5.0, loc=100),
        ]
        pm = ProjectMetrics.from_entries_and_stats(entries, [])
        assert pm.total_files == 1
        assert pm.avg_churn == 0.0
