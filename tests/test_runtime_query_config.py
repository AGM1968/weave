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


def test_budget_tracker_detects_budget_exceeded() -> None:
    tracker = BudgetTracker()
    tracker.record(_response(inp=100, out=50))

    assert tracker.exceeded(BudgetPolicy(budget_usd=0.0001))
