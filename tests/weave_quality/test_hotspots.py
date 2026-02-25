"""Tests for weave_quality.hotspots -- hotspot scoring engine."""

# pylint: disable=missing-class-docstring,missing-function-docstring

from __future__ import annotations

from weave_quality.hotspots import (
    HOTSPOT_THRESHOLD,
    CC_CRITICAL,
    CC_WARNING,
    classify_complexity,
    classify_hotspot,
    compute_hotspots,
    compute_quality_score,
    hotspot_summary,
    rank_hotspots,
    _normalize_values,
)
from weave_quality.models import FileEntry, GitStats


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _entry(filepath: str = "test.py", complexity: int = 10, loc: int = 100) -> FileEntry:
    return FileEntry(
        path=filepath,
        scan_id=1,
        language="python",
        loc=loc,
        functions=5,
        complexity=complexity,
        max_nesting=3,
        avg_fn_len=10.0,
    )


def _stats(filepath: str = "test.py", churn: int = 50, hotspot: float = 0.0) -> GitStats:
    return GitStats(
        path=filepath,
        churn=churn,
        age_days=30,
        authors=2,
        hotspot=hotspot,
    )


# ---------------------------------------------------------------------------
# Normalization
# ---------------------------------------------------------------------------


class TestNormalize:
    def test_basic(self) -> None:
        result = _normalize_values([0, 50, 100])
        assert result == [0.0, 0.5, 1.0]

    def test_single_value(self) -> None:
        result = _normalize_values([42])
        assert result == [0.0]

    def test_all_same(self) -> None:
        result = _normalize_values([5, 5, 5])
        assert all(v == 0.0 for v in result)

    def test_empty(self) -> None:
        result = _normalize_values([])
        assert result == []

    def test_negative_values(self) -> None:
        result = _normalize_values([-10, 0, 10])
        assert result[0] == 0.0
        assert result[2] == 1.0


# ---------------------------------------------------------------------------
# Hotspot computation
# ---------------------------------------------------------------------------


class TestComputeHotspots:
    def test_basic_scoring(self) -> None:
        entries = [_entry("a.py", complexity=30), _entry("b.py", complexity=5)]
        stats = [_stats("a.py", churn=100), _stats("b.py", churn=10)]
        result = compute_hotspots(entries, stats)
        # a.py has max complexity AND max churn -> score = 1.0 * 1.0 = 1.0
        a_stats = next(s for s in result if s.path == "a.py")
        b_stats = next(s for s in result if s.path == "b.py")
        assert a_stats.hotspot == 1.0
        assert b_stats.hotspot == 0.0  # min of both

    def test_no_entries(self) -> None:
        result = compute_hotspots([], [])
        assert not result

    def test_single_file(self) -> None:
        entries = [_entry("a.py", complexity=10)]
        stats = [_stats("a.py", churn=50)]
        result = compute_hotspots(entries, stats)
        # Single file: normalized to 0 -> hotspot = 0
        assert result[0].hotspot == 0.0

    def test_unmatched_stats_ignored(self) -> None:
        entries = [_entry("a.py", complexity=10)]
        stats = [_stats("a.py", churn=50), _stats("orphan.py", churn=100)]
        result = compute_hotspots(entries, stats)
        # Only a.py should be processed
        assert len(result) == 2

    def test_hotspot_updates_in_place(self) -> None:
        entries = [_entry("a.py", complexity=30), _entry("b.py", complexity=5)]
        stats = [_stats("a.py", churn=100), _stats("b.py", churn=10)]
        compute_hotspots(entries, stats)
        # Verify the original stats objects are updated
        assert stats[0].hotspot == 1.0


# ---------------------------------------------------------------------------
# Ranking
# ---------------------------------------------------------------------------


class TestRankHotspots:
    def test_rank_above_threshold(self) -> None:
        stats = [
            _stats("a.py", hotspot=0.9),
            _stats("b.py", hotspot=0.3),
            _stats("c.py", hotspot=0.7),
        ]
        ranked = rank_hotspots(stats, threshold=0.5)
        assert len(ranked) == 2
        assert ranked[0].path == "a.py"
        assert ranked[1].path == "c.py"

    def test_top_n(self) -> None:
        stats = [
            _stats("a.py", hotspot=0.9),
            _stats("b.py", hotspot=0.8),
            _stats("c.py", hotspot=0.7),
        ]
        ranked = rank_hotspots(stats, threshold=0.0, top_n=2)
        assert len(ranked) == 2

    def test_empty_input(self) -> None:
        assert rank_hotspots([], threshold=0.0) == []


# ---------------------------------------------------------------------------
# Classification
# ---------------------------------------------------------------------------


class TestClassification:
    def test_complexity_critical(self) -> None:
        assert classify_complexity(CC_CRITICAL) == "critical"
        assert classify_complexity(CC_CRITICAL + 1) == "critical"

    def test_complexity_warning(self) -> None:
        assert classify_complexity(CC_WARNING) == "warning"
        assert classify_complexity(CC_CRITICAL - 1) == "warning"

    def test_complexity_ok(self) -> None:
        assert classify_complexity(CC_WARNING - 1) == "ok"
        assert classify_complexity(0) == "ok"

    def test_hotspot_critical(self) -> None:
        assert classify_hotspot(0.8) == "critical"
        assert classify_hotspot(1.0) == "critical"

    def test_hotspot_warning(self) -> None:
        assert classify_hotspot(HOTSPOT_THRESHOLD + 0.01) == "warning"
        assert classify_hotspot(0.7) == "warning"

    def test_hotspot_ok(self) -> None:
        assert classify_hotspot(0.0) == "ok"
        assert classify_hotspot(HOTSPOT_THRESHOLD - 0.01) == "ok"


# ---------------------------------------------------------------------------
# Quality score
# ---------------------------------------------------------------------------


class TestQualityScore:
    def test_perfect_score(self) -> None:
        entries = [_entry("a.py", complexity=5)]
        stats = [_stats("a.py", hotspot=0.0)]
        score = compute_quality_score(entries, stats)
        assert score == 100

    def test_deductions_for_hotspots(self) -> None:
        entries = [_entry("a.py", complexity=5)]
        stats = [_stats("a.py", hotspot=0.9)]
        score = compute_quality_score(entries, stats)
        assert score < 100

    def test_deductions_for_critical_complexity(self) -> None:
        entries = [_entry("a.py", complexity=CC_CRITICAL + 1)]
        stats = [_stats("a.py", hotspot=0.0)]
        score = compute_quality_score(entries, stats)
        assert score < 100

    def test_score_floor_at_zero(self) -> None:
        # Many hotspots and critical files
        entries = [_entry(f"f{i}.py", complexity=50) for i in range(30)]
        stats = [_stats(f"f{i}.py", hotspot=1.0) for i in range(30)]
        score = compute_quality_score(entries, stats)
        assert score >= 0

    def test_empty_inputs(self) -> None:
        score = compute_quality_score([], [])
        assert score == 100


# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------


class TestHotspotSummary:
    def test_summary_structure(self) -> None:
        entries = [_entry("a.py", complexity=20), _entry("b.py", complexity=5)]
        stats = [_stats("a.py", churn=100, hotspot=0.8), _stats("b.py", churn=10, hotspot=0.1)]
        result = hotspot_summary(entries, stats)
        assert "quality_score" in result
        assert "total_files" in result
        assert "hotspot_count" in result
        assert "hotspots" in result
        assert isinstance(result["hotspots"], list)

    def test_summary_top_n(self) -> None:
        entries = [_entry(f"f{i}.py") for i in range(10)]
        stats = [_stats(f"f{i}.py", hotspot=0.6 + i * 0.01) for i in range(10)]
        result = hotspot_summary(entries, stats, top_n=3)
        assert len(result["hotspots"]) <= 3
