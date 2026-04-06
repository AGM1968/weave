"""Focused tests for query-layer config and budget interfaces."""
from __future__ import annotations

import pytest

from runtime.query import BudgetPolicy, BudgetTracker, QueryConfig
from runtime.types import Response, StopReason, Usage


def _response(inp: int = 10, out: int = 5, cost_in: float = 3.0, cost_out: float = 15.0) -> Response:
    return Response(
        content="done",
        tool_calls=[],
        stop_reason=StopReason.END_TURN,
        usage=Usage(
            input_tokens=inp,
            output_tokens=out,
            input_cost_per_mtok=cost_in,
            output_cost_per_mtok=cost_out,
        ),
    )


def test_query_config_accepts_valid_values() -> None:
    QueryConfig(max_tokens=512, max_turns=3).validate()


@pytest.mark.parametrize("turns", [0, -1])
def test_query_config_rejects_invalid_turns(turns: int) -> None:
    with pytest.raises(ValueError, match="max_turns"):
        QueryConfig(max_tokens=512, max_turns=turns).validate()


def test_query_config_rejects_invalid_tokens() -> None:
    with pytest.raises(ValueError, match="max_tokens"):
        QueryConfig(max_tokens=0, max_turns=3).validate()


def test_budget_policy_rejects_non_positive_budget() -> None:
    with pytest.raises(ValueError, match="budget_usd"):
        BudgetPolicy(budget_usd=0.0).validate()


def test_budget_tracker_accumulates_usage() -> None:
    tracker = BudgetTracker()
    tracker.record(_response())

    assert tracker.total_input_tokens == 10
    assert tracker.total_output_tokens == 5
    assert tracker.total_cost_usd > 0.0


def test_cost_usd_includes_cache_tokens() -> None:
    """Cache-read (10% of input rate) and cache-creation (25%) must be included."""
    base = Usage(
        input_tokens=100,
        output_tokens=50,
        input_cost_per_mtok=3.0,
        output_cost_per_mtok=15.0,
    )
    with_cache = Usage(
        input_tokens=100,
        output_tokens=50,
        cache_read_tokens=1000,
        cache_creation_tokens=200,
        input_cost_per_mtok=3.0,
        output_cost_per_mtok=15.0,
    )
    # Cache should add: 1000 * 3.0 * 0.10 / 1e6 + 200 * 3.0 * 0.25 / 1e6
    expected_delta = 1000 * 3.0 * 0.10 / 1_000_000 + 200 * 3.0 * 0.25 / 1_000_000
    assert with_cache.cost_usd == pytest.approx(base.cost_usd + expected_delta)
    assert expected_delta > 0  # sanity: cache cost is non-zero


def test_cost_usd_zero_cache_tokens_unchanged() -> None:
    """When cache tokens are 0, cost matches the old input+output formula."""
    u = Usage(
        input_tokens=500,
        output_tokens=200,
        input_cost_per_mtok=15.0,
        output_cost_per_mtok=75.0,
    )
    expected = 500 * 15.0 / 1_000_000 + 200 * 75.0 / 1_000_000
    assert u.cost_usd == pytest.approx(expected)


def _cached_response(
    inp: int = 1, out: int = 100,
    cache_read: int = 10000, cache_create: int = 500,
) -> Response:
    """Response with Anthropic-style prompt caching."""
    return Response(
        content="ok",
        tool_calls=[],
        stop_reason=StopReason.END_TURN,
        usage=Usage(
            input_tokens=inp,
            output_tokens=out,
            cache_read_tokens=cache_read,
            cache_creation_tokens=cache_create,
            input_cost_per_mtok=3.0,
            output_cost_per_mtok=15.0,
        ),
    )


def test_cache_creation_prevents_false_diminishing() -> None:
    """cache_creation_tokens should count as new material in the delta.

    With Anthropic caching, input_tokens is often 1-3 (cache misses only).
    Without counting cache_creation, small-output editing turns falsely
    trigger diminishing returns.
    """
    tracker = BudgetTracker()
    # First turn: large setup to exceed min total
    tracker.record(_cached_response(out=2000, cache_create=2000))
    # Two turns with small output but meaningful cache_creation (>500)
    tracker.record(_cached_response(out=150, cache_create=600))
    tracker.record(_cached_response(out=150, cache_create=600))
    # input+output delta would be ~151 (below 500), but cache_creation
    # pushes it to ~751 — should NOT fire diminishing.
    assert not tracker.is_diminishing()


def test_cache_read_does_not_affect_diminishing() -> None:
    """cache_read_tokens (reused context) should NOT prevent diminishing.

    Only new material matters — huge cache reads with tiny output and
    no cache creation should still trigger diminishing.
    """
    tracker = BudgetTracker()
    # First turn: enough to exceed min total
    tracker.record(_cached_response(out=2000, cache_create=2000))
    # 9 more turns (need pass_count=10): huge cache_read but tiny output
    for _ in range(9):
        tracker.record(_cached_response(out=100, cache_read=20000, cache_create=0))
    # delta ≈ 101, well below 500 — diminishing should fire
    assert tracker.is_diminishing()


def test_zero_cache_diminishing_unchanged() -> None:
    """When cache tokens are 0 (non-Anthropic providers), behavior is unchanged."""
    tracker = BudgetTracker()
    for _ in range(10):
        tracker.record(_response(inp=1000, out=1000))
    # Large deltas — not diminishing
    assert not tracker.is_diminishing()

    tracker2 = BudgetTracker()
    # 8 large turns to build up count, then 2 small
    for _ in range(8):
        tracker2.record(_response(inp=500, out=500))
    tracker2.record(_response(inp=10, out=100))
    tracker2.record(_response(inp=10, out=100))
    # delta ≈ 110, below 500 — should fire
    assert tracker2.is_diminishing()


def test_budget_tracker_detects_budget_exceeded() -> None:
    tracker = BudgetTracker()
    tracker.record(_response(inp=100, out=50))

    assert tracker.exceeded(BudgetPolicy(budget_usd=0.0001))
