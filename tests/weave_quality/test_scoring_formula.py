"""Tests for the graduated per-function quality scoring formula.

Covers the compute_quality_score() signature:
  compute_quality_score(entries, stats, fn_cc_list=None, scope="production")

Formula:
  1. Per-function CC penalty: min((cc - 10) * 0.5, 8.0) per fn where cc > 10
  2. EV penalty: min((ev - 4) * 0.5, 3.0) per entry where ev > 4
  3. Hotspot penalty: -5 per stat where hotspot > HOTSPOT_THRESHOLD
  4. Gini penalty: -1.0 per file with >= 3 fns and gini > 0.7
  No density normalization — penalties applied at face value.
  Clamped to [0, 100], returned as int.
"""

# pylint: disable=missing-class-docstring,missing-function-docstring

from __future__ import annotations

from weave_quality.hotspots import HOTSPOT_THRESHOLD, compute_quality_score
from weave_quality.models import FileEntry, FunctionCC, GitStats


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _entry(
    path: str = "f.py", ev: float = 0.0, category: str = "production"
) -> FileEntry:
    return FileEntry(path=path, essential_complexity=ev, category=category)


def _stats(path: str = "f.py", hotspot: float = 0.0) -> GitStats:
    return GitStats(path=path, hotspot=hotspot)


def _fn(
    path: str = "f.py", name: str = "fn", cc: float = 5.0, is_dispatch: bool = False
) -> FunctionCC:
    return FunctionCC(
        path=path, function_name=name, complexity=cc, is_dispatch=is_dispatch
    )


# ---------------------------------------------------------------------------
# Baseline / empty inputs
# ---------------------------------------------------------------------------


class TestBaselineScore:
    def test_no_inputs_returns_100(self) -> None:
        assert compute_quality_score([], []) == 100

    def test_no_hotspots_no_issues_returns_100(self) -> None:
        entries = [_entry("a.py", ev=1.0), _entry("b.py", ev=2.0)]
        stats = [_stats("a.py", hotspot=0.0), _stats("b.py", hotspot=0.1)]
        assert compute_quality_score(entries, stats) == 100

    def test_fn_cc_none_no_per_function_penalty(self) -> None:
        entries = [_entry()]
        stats = [_stats()]
        score_default = compute_quality_score(entries, stats)
        score_none = compute_quality_score(entries, stats, fn_cc_list=None)
        assert score_default == score_none == 100

    def test_fn_cc_empty_list_no_penalty(self) -> None:
        assert compute_quality_score([], [], fn_cc_list=[]) == 100


# ---------------------------------------------------------------------------
# Per-function CC penalty
# ---------------------------------------------------------------------------


class TestPerFunctionCCPenalty:
    def test_fn_cc_above_threshold_reduces_score(self) -> None:
        """A single function above CC=10 should reduce the score."""
        entries = [_entry("f.py")]
        fn_cc = [_fn("f.py", "big", cc=15.0)]
        score = compute_quality_score(entries, [], fn_cc_list=fn_cc)
        assert score < 100

    def test_fn_cc_at_threshold_no_penalty(self) -> None:
        entries = [_entry("f.py")]
        fn_cc = [_fn("f.py", "fn", cc=10.0)]
        score = compute_quality_score(entries, [], fn_cc_list=fn_cc)
        assert score == 100

    def test_fn_cc_below_threshold_no_penalty(self) -> None:
        entries = [_entry("f.py")]
        fn_cc = [_fn("f.py", "fn", cc=5.0)]
        score = compute_quality_score(entries, [], fn_cc_list=fn_cc)
        assert score == 100

    def test_penalty_capped_at_8_per_function(self) -> None:
        """CC=50 → (50-10)*0.5=20 → capped at 8. CC=200 also capped at 8."""
        entries = [_entry("f.py")]
        fn_cc_high = [_fn("f.py", "fn", cc=50.0)]
        fn_cc_extreme = [_fn("f.py", "fn", cc=200.0)]
        score_high = compute_quality_score(entries, [], fn_cc_list=fn_cc_high)
        score_extreme = compute_quality_score(entries, [], fn_cc_list=fn_cc_extreme)
        assert score_high == score_extreme == 92  # Both capped: 100 - 8 = 92

    def test_dispatch_functions_exempt(self) -> None:
        """Dispatch-tagged functions should not incur CC penalty."""
        entries = [_entry("f.py")]
        fn_cc = [_fn("f.py", "dispatch_fn", cc=30.0, is_dispatch=True)]
        score = compute_quality_score(entries, [], fn_cc_list=fn_cc)
        assert score == 100

    def test_multiple_functions_penalties_cumulate(self) -> None:
        entries = [_entry("f.py")]
        fn_cc = [_fn("f.py", "a", cc=15.0), _fn("f.py", "b", cc=20.0)]
        score = compute_quality_score(entries, [], fn_cc_list=fn_cc)
        assert score < 100


# ---------------------------------------------------------------------------
# EV (essential complexity) penalty
# ---------------------------------------------------------------------------


class TestEVPenalty:
    def test_ev_above_4_reduces_score(self) -> None:
        entries = [_entry("a.py", ev=8.0)]
        score = compute_quality_score(entries, [])
        assert score < 100

    def test_ev_at_threshold_no_penalty(self) -> None:
        entries = [_entry("a.py", ev=4.0)]
        score = compute_quality_score(entries, [])
        assert score == 100

    def test_ev_below_threshold_no_penalty(self) -> None:
        entries = [_entry("a.py", ev=2.0)]
        score = compute_quality_score(entries, [])
        assert score == 100

    def test_multiple_entries_ev_cumulate(self) -> None:
        entries = [_entry(f"f{i}.py", ev=6.0) for i in range(3)]
        score = compute_quality_score(entries, [])
        assert score < 100


# ---------------------------------------------------------------------------
# Hotspot penalty
# ---------------------------------------------------------------------------


class TestHotspotPenalty:
    def test_hotspot_above_threshold_reduces_score(self) -> None:
        entries = [_entry("a.py")]
        stats = [_stats("a.py", hotspot=0.8)]
        score = compute_quality_score(entries, stats)
        assert score < 100

    def test_hotspot_at_threshold_no_penalty(self) -> None:
        entries = [_entry("a.py")]
        stats = [_stats("a.py", hotspot=HOTSPOT_THRESHOLD)]
        score = compute_quality_score(entries, stats)
        assert score == 100

    def test_hotspot_below_threshold_no_penalty(self) -> None:
        entries = [_entry("a.py")]
        stats = [_stats("a.py", hotspot=0.3)]
        score = compute_quality_score(entries, stats)
        assert score == 100

    def test_multiple_hotspots_cumulate(self) -> None:
        entries = [_entry("a.py"), _entry("b.py")]
        stats = [_stats("a.py", hotspot=0.9), _stats("b.py", hotspot=0.7)]
        score = compute_quality_score(entries, stats)
        assert score < 100


# ---------------------------------------------------------------------------
# Gini concentration penalty
# ---------------------------------------------------------------------------


class TestGiniPenalty:
    def test_skewed_distribution_triggers_gini_penalty(self) -> None:
        """Gini > 0.7 adds a -1 point penalty per file."""
        entries = [_entry("a.py")]
        # Skewed: 1 big + 9 small → gini > 0.7 → -1 penalty
        fn_cc = [_fn("a.py", "big", cc=50.0)]
        fn_cc += [_fn("a.py", f"s_{i}", cc=1.0) for i in range(9)]
        score = compute_quality_score(entries, [], fn_cc_list=fn_cc)
        # Score should be < 100 (CC penalty + gini penalty)
        assert score < 100

    def test_uniform_distribution_no_gini_penalty(self) -> None:
        entries = [_entry("a.py")]
        fn_cc = [_fn("a.py", f"fn_{i}", cc=5.0) for i in range(5)]
        score = compute_quality_score(entries, [], fn_cc_list=fn_cc)
        assert score == 100

    def test_fewer_than_3_functions_no_gini(self) -> None:
        """Gini only applies to files with >= 3 functions."""
        entries = [_entry("a.py")]
        fn_cc = [_fn("a.py", "big", cc=50.0), _fn("a.py", "small", cc=1.0)]
        score = compute_quality_score(entries, [], fn_cc_list=fn_cc)
        # Only CC penalty, no Gini (< 3 fns)
        assert score < 100


# ---------------------------------------------------------------------------
# Scope filtering
# ---------------------------------------------------------------------------


class TestScopeFiltering:
    def test_production_scope_excludes_test_files(self) -> None:
        entries = [
            _entry("src/app.py", ev=6.0, category="production"),
            _entry("tests/test_app.py", ev=8.0, category="test"),
        ]
        score_prod = compute_quality_score(entries, [], scope="production")
        score_all = compute_quality_score(entries, [], scope="all")
        # Production scope should have higher score (fewer penalties)
        assert score_prod > score_all

    def test_scope_all_includes_everything(self) -> None:
        entries = [
            _entry("src/app.py", ev=6.0, category="production"),
            _entry("tests/test_app.py", ev=8.0, category="test"),
        ]
        score_all = compute_quality_score(entries, [], scope="all")
        assert score_all < 100

    def test_scope_filters_fn_cc(self) -> None:
        """fn_cc for test files should not affect production score."""
        entries = [
            _entry("src/app.py", category="production"),
            _entry("tests/test.py", category="test"),
        ]
        fn_cc = [_fn("tests/test.py", "test_fn", cc=30.0)]
        score = compute_quality_score(entries, [], fn_cc_list=fn_cc, scope="production")
        assert score == 100  # Test file CC doesn't affect production score

    def test_scope_filters_stats(self) -> None:
        """Hotspots in test files should not affect production score."""
        entries = [
            _entry("src/app.py", category="production"),
            _entry("tests/test.py", category="test"),
        ]
        stats = [_stats("tests/test.py", hotspot=0.9)]
        score = compute_quality_score(entries, stats, scope="production")
        assert score == 100


# ---------------------------------------------------------------------------
# No density normalization — penalties are absolute, not density-scaled
# ---------------------------------------------------------------------------


class TestNoPenaltyScaling:
    def test_single_problem_fn_still_penalises(self) -> None:
        """A single function over threshold incurs full penalty regardless of
        how many other functions are fine (no density dampening)."""
        entries = [_entry("f.py")]
        # 1 bad fn, 99 fine fns
        fn_cc = [_fn("f.py", "bad", cc=20.0)]
        fn_cc += [_fn("f.py", f"ok_{i}", cc=5.0) for i in range(99)]
        score = compute_quality_score(entries, [], fn_cc_list=fn_cc)
        # CC=20 → (20-10)*0.5=5 penalty → score=95 (not inflated by density norm)
        assert score == 95

    def test_many_problem_fns_cumulate_penalty(self) -> None:
        """Many functions over threshold accumulate penalty without scaling."""
        entries = [_entry("f.py")]
        fn_cc = [_fn("f.py", f"bad_{i}", cc=20.0) for i in range(10)]
        score = compute_quality_score(entries, [], fn_cc_list=fn_cc)
        # 10 fns, each CC=20 → (20-10)*0.5=5 each → 50 total → score=50
        assert score == 50


# ---------------------------------------------------------------------------
# Combined penalties
# ---------------------------------------------------------------------------


class TestCombinedPenalties:
    def test_all_penalties_combined(self) -> None:
        entries = [_entry("a.py", ev=5.0)]
        stats = [_stats("a.py", hotspot=0.9)]
        fn_cc = [_fn("a.py", "fn_a", cc=15.0), _fn("a.py", "fn_b", cc=50.0)]
        score = compute_quality_score(entries, stats, fn_cc_list=fn_cc)
        assert 0 <= score < 100

    def test_backward_compat_positional_args(self) -> None:
        """Existing callers passing only (entries, stats) still work."""
        entries = [_entry("a.py", ev=5.0)]
        stats = [_stats("a.py", hotspot=0.9)]
        score = compute_quality_score(entries, stats)
        assert isinstance(score, int)
        assert 0 <= score <= 100
