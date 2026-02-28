"""Tests for weave_quality.hotspots -- hotspot scoring engine."""

# pylint: disable=missing-class-docstring,missing-function-docstring

from __future__ import annotations

from weave_quality.hotspots import (
    CC_HISTOGRAM_LABELS,
    HOTSPOT_THRESHOLD,
    CC_CRITICAL,
    CC_WARNING,
    cc_gini,
    cc_histogram,
    classify_complexity,
    classify_hotspot,
    compute_hotspots,
    compute_quality_score,
    hotspot_summary,
    rank_hotspots,
    _normalize_values,
)
from weave_quality.models import FileEntry, FunctionCC, GitStats


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
#
# CONVENTION (wv-07a641): compute_hotspots uses min-max normalization, so
# absolute scores depend on the dataset. Safe assertion patterns:
#   - 2-element fixtures: min=0.0, max=1.0 are guaranteed by the math
#   - N>2 elements: assert relative ordering (a > b) or thresholds (x > 0.5)
#   - Pre-set values via _stats(hotspot=X) bypass normalization — safe to ==
# Never hardcode intermediate normalized values from _stats() in assertions.
# ---------------------------------------------------------------------------


class TestComputeHotspots:
    def test_basic_scoring(self) -> None:
        entries = [_entry("a.py", complexity=30), _entry("b.py", complexity=5)]
        stats = [_stats("a.py", churn=100), _stats("b.py", churn=10)]
        result = compute_hotspots(entries, stats)
        # 2-element fixture: min-max guarantees max=1.0, min=0.0
        a_stats = next(s for s in result if s.path == "a.py")
        b_stats = next(s for s in result if s.path == "b.py")
        assert a_stats.hotspot == 1.0
        assert b_stats.hotspot == 0.0

    def test_no_entries(self) -> None:
        result = compute_hotspots([], [])
        assert not result

    def test_single_file(self) -> None:
        entries = [_entry("a.py", complexity=10)]
        stats = [_stats("a.py", churn=50)]
        result = compute_hotspots(entries, stats)
        # Single file: normalized to 0 -> hotspot = 0
        assert result[0].hotspot == 0.0

    def test_three_files_relative_ordering(self) -> None:
        """With N>2 files, assert relative ordering not exact scores."""
        entries = [
            _entry("high.py", complexity=50),
            _entry("mid.py", complexity=25),
            _entry("low.py", complexity=5),
        ]
        stats = [
            _stats("high.py", churn=100),
            _stats("mid.py", churn=50),
            _stats("low.py", churn=10),
        ]
        result = compute_hotspots(entries, stats)
        by_path = {s.path: s for s in result}
        # Relative ordering is stable regardless of fixture size
        assert by_path["high.py"].hotspot > by_path["mid.py"].hotspot
        assert by_path["mid.py"].hotspot > by_path["low.py"].hotspot
        # Boundary values still hold for N>2
        assert by_path["high.py"].hotspot == 1.0  # max is always 1.0
        assert by_path["low.py"].hotspot == 0.0   # min is always 0.0

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


# ---------------------------------------------------------------------------
# CC Gini coefficient
# ---------------------------------------------------------------------------


def _fn(name: str, cc: float) -> FunctionCC:
    return FunctionCC(path="test.py", function_name=name, complexity=cc)


class TestCCGini:
    def test_empty(self) -> None:
        assert cc_gini([]) == 0.0

    def test_single_function(self) -> None:
        assert cc_gini([_fn("f", 10)]) == 0.0

    def test_uniform_cc(self) -> None:
        fns = [_fn(f"f{i}", 5) for i in range(10)]
        assert cc_gini(fns) == 0.0

    def test_one_monster(self) -> None:
        """One CC=50 function + ten CC=1 functions → high Gini."""
        fns = [_fn("monster", 50)] + [_fn(f"f{i}", 1) for i in range(10)]
        gini = cc_gini(fns)
        assert gini > 0.6

    def test_moderate_spread(self) -> None:
        """CC values 1..5 → moderate Gini."""
        fns = [_fn(f"f{i}", i + 1) for i in range(5)]
        gini = cc_gini(fns)
        assert 0.1 < gini < 0.5

    def test_bounded_zero_to_one(self) -> None:
        """Gini is always in [0, 1)."""
        fns = [_fn("a", 100)] + [_fn(f"f{i}", 1) for i in range(100)]
        gini = cc_gini(fns)
        assert 0.0 <= gini < 1.0


# ---------------------------------------------------------------------------
# CC histogram
# ---------------------------------------------------------------------------


class TestCCHistogram:
    def test_empty(self) -> None:
        assert cc_histogram([]) == [0, 0, 0, 0]

    def test_all_simple(self) -> None:
        fns = [_fn(f"f{i}", 2) for i in range(5)]
        hist = cc_histogram(fns)
        assert hist == [5, 0, 0, 0]

    def test_all_buckets(self) -> None:
        fns = [_fn("a", 3), _fn("b", 8), _fn("c", 15), _fn("d", 25)]
        hist = cc_histogram(fns)
        assert hist == [1, 1, 1, 1]

    def test_bucket_labels(self) -> None:
        assert len(CC_HISTOGRAM_LABELS) == 4

    def test_boundary_values(self) -> None:
        """CC=5 → bucket 0, CC=6 → bucket 1, CC=10 → bucket 1, CC=11 → bucket 2."""
        fns = [_fn("a", 5), _fn("b", 6), _fn("c", 10), _fn("d", 11)]
        hist = cc_histogram(fns)
        assert hist == [1, 2, 1, 0]
