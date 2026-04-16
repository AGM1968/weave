"""Tests for BudgetMiddleware — budget, diminishing returns, wind-down nudge."""

from __future__ import annotations

from unittest.mock import MagicMock

import pytest

from runtime.middleware.base import MiddlewareContext, MiddlewareStack, StopAgent, ToolCallAction
from runtime.middleware.budget import BudgetMiddleware, _WIND_DOWN_RESERVE
from runtime.query.token_budget import BudgetPolicy, BudgetTracker


def _ctx(
    *,
    turn: int = 1,
    max_turns: int = 25,
    budget_usd: float = 5.0,
    cost: float = 0.0,
) -> MiddlewareContext:
    return MiddlewareContext(
        turn_number=turn,
        max_turns=max_turns,
        budget_usd=budget_usd,
        total_cost_usd=cost,
    )


def _mw(
    *,
    budget_usd: float = 5.0,
    cost: float = 0.0,
    session: MagicMock | None = None,
) -> tuple[BudgetMiddleware, BudgetTracker, MagicMock]:
    tracker = BudgetTracker(total_cost_usd=cost)
    policy = BudgetPolicy(budget_usd=budget_usd)
    surface = MagicMock()
    mw = BudgetMiddleware(tracker, policy, surface, session=session)
    return mw, tracker, surface


# ── name ─────────────────────────────────────────────────────────────────


class TestBudgetMiddlewareName:
    def test_name(self) -> None:
        mw, _, _ = _mw()
        assert mw.name == "budget"


# ── after_query: budget exceeded ─────────────────────────────────────────


class TestBudgetExceeded:
    def test_no_stop_when_under_budget(self) -> None:
        mw, _, surface = _mw(budget_usd=5.0, cost=2.0)
        mw.after_query(_ctx(), None)
        surface.on_budget_exceeded.assert_not_called()

    def test_stop_when_budget_exceeded(self) -> None:
        mw, tracker, surface = _mw(budget_usd=5.0)
        tracker.total_cost_usd = 5.0
        with pytest.raises(StopAgent, match="budget"):
            mw.after_query(_ctx(), None)
        surface.on_budget_exceeded.assert_called_once_with(5.0, 5.0)

    def test_stop_when_over_budget(self) -> None:
        mw, tracker, surface = _mw(budget_usd=5.0)
        tracker.total_cost_usd = 6.5
        with pytest.raises(StopAgent, match="budget"):
            mw.after_query(_ctx(), None)
        surface.on_budget_exceeded.assert_called_once_with(6.5, 5.0)


# ── after_query: diminishing returns ─────────────────────────────────────


class TestDiminishingReturns:
    def test_no_stop_when_not_diminishing(self) -> None:
        mw, tracker, _ = _mw(budget_usd=100.0)
        tracker.total_cost_usd = 1.0
        mw.after_query(_ctx(), None)

    def test_stop_when_diminishing(self) -> None:
        mw, tracker, _ = _mw(budget_usd=100.0)
        # Set up tracker to trigger diminishing returns
        tracker.continuation_count = 12
        tracker.last_delta_tokens = 100
        tracker._prev_delta_tokens = 100
        tracker._last_total_tokens = 5000
        tracker.total_input_tokens = 3000
        tracker.total_output_tokens = 1500
        tracker.total_cache_creation_tokens = 500
        with pytest.raises(StopAgent, match="diminishing_returns"):
            mw.after_query(_ctx(), None)

    def test_budget_checked_before_diminishing(self) -> None:
        """Budget exceeded takes priority over diminishing returns."""
        mw, tracker, surface = _mw(budget_usd=5.0)
        tracker.total_cost_usd = 5.0
        tracker.continuation_count = 12
        tracker.last_delta_tokens = 100
        tracker._prev_delta_tokens = 100
        tracker.total_input_tokens = 3000
        tracker.total_output_tokens = 1500
        tracker.total_cache_creation_tokens = 500
        with pytest.raises(StopAgent, match="budget"):
            mw.after_query(_ctx(), None)
        surface.on_budget_exceeded.assert_called_once()


# ── before_query: wind-down nudge ────────────────────────────────────────


class TestWindDown:
    def test_no_nudge_early_turn(self) -> None:
        mw, _, _ = _mw()
        ctx = _ctx(turn=5, max_turns=25)
        mw.before_query(ctx)
        assert len(ctx.messages) == 0

    def test_nudge_at_threshold_turn(self) -> None:
        mw, _, _ = _mw()
        threshold = 25 - _WIND_DOWN_RESERVE  # 22
        ctx = _ctx(turn=threshold, max_turns=25)
        mw.before_query(ctx)
        assert len(ctx.messages) == 1
        assert "turn budget almost exhausted" in ctx.messages[0].content

    def test_nudge_injected_once(self) -> None:
        mw, _, _ = _mw()
        threshold = 25 - _WIND_DOWN_RESERVE
        ctx1 = _ctx(turn=threshold, max_turns=25)
        mw.before_query(ctx1)
        assert len(ctx1.messages) == 1

        ctx2 = _ctx(turn=threshold + 1, max_turns=25)
        mw.before_query(ctx2)
        assert len(ctx2.messages) == 0

    def test_nudge_remaining_count(self) -> None:
        mw, _, _ = _mw()
        ctx = _ctx(turn=23, max_turns=25)
        mw.before_query(ctx)
        assert "3 turns left" in ctx.messages[0].content

    def test_nudge_records_session_event(self) -> None:
        session = MagicMock()
        mw, _, _ = _mw(session=session)
        threshold = 25 - _WIND_DOWN_RESERVE
        ctx = _ctx(turn=threshold, max_turns=25)
        mw.before_query(ctx)
        session.record_event.assert_called_once_with(
            "wind_down",
            metadata={"turn": threshold, "remaining": 25 - threshold + 1},
        )

    def test_no_nudge_when_max_turns_too_small(self) -> None:
        """If max_turns <= WIND_DOWN_RESERVE, skip nudge (no valid threshold)."""
        mw, _, _ = _mw()
        ctx = _ctx(turn=1, max_turns=3)
        mw.before_query(ctx)
        assert len(ctx.messages) == 0


# ── on_tool_call: no-op ─────────────────────────────────────────────────


class TestOnToolCall:
    def test_always_proceeds(self) -> None:
        mw, _, _ = _mw()
        tc = MagicMock()
        result = mw.on_tool_call(_ctx(), tc)
        assert isinstance(result, ToolCallAction)
        assert result.proceed is True


# ── stack integration ────────────────────────────────────────────────────


class TestStackIntegration:
    def test_budget_in_stack_stops_on_exceeded(self) -> None:
        mw, tracker, surface = _mw(budget_usd=5.0)
        tracker.total_cost_usd = 5.0
        stack = MiddlewareStack([mw])
        ctx = _ctx()
        with pytest.raises(StopAgent, match="budget"):
            stack.run_after_query(ctx, None)
        surface.on_budget_exceeded.assert_called_once()

    def test_budget_in_stack_wind_down(self) -> None:
        mw, _, _ = _mw()
        stack = MiddlewareStack([mw])
        threshold = 25 - _WIND_DOWN_RESERVE
        ctx = _ctx(turn=threshold, max_turns=25)
        stack.run_before_query(ctx)
        assert len(ctx.messages) == 1
        assert "turn budget almost exhausted" in ctx.messages[0].content
