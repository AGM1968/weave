"""Tests for CompactionMiddleware — before/after_query compaction scheduling."""
from __future__ import annotations

from unittest.mock import MagicMock

from runtime.middleware.base import MiddlewareContext, MiddlewareStack
from runtime.middleware.compaction import CompactionMiddleware
from runtime.services.compaction_dispatcher import CompactionDispatcher
from runtime.services.compaction_policy import CompactionResult
from runtime.types import EfficiencySnapshot, Message, ToolCall


# ── Fixtures ─────────────────────────────────────────────────────────────


def _make_ctx(turn: int = 1, messages: list[Message] | None = None) -> MiddlewareContext:
    return MiddlewareContext(
        turn_number=turn,
        messages=messages or [],
    )


def _make_dispatcher(
    must: bool = False,
    should: bool = False,
    compacted: bool = True,
) -> MagicMock:
    d = MagicMock(spec=CompactionDispatcher)
    d.must_compact.return_value = must
    d.should_compact.return_value = should
    d.run.return_value = CompactionResult(
        compacted=compacted,
        messages_before=20,
        messages_after=10,
        tokens_before=8000,
        tokens_after=4000,
        strategy="micro",
    )
    d.record_turn.return_value = None
    return d


def _make_surface() -> MagicMock:
    return MagicMock()


# ── Protocol compliance ──────────────────────────────────────────────────


class TestProtocolCompliance:
    def test_name(self) -> None:
        mw = CompactionMiddleware(_make_dispatcher(), _make_surface())
        assert mw.name == "compaction"

    def test_on_tool_call_proceeds(self) -> None:
        mw = CompactionMiddleware(_make_dispatcher(), _make_surface())
        tc = ToolCall(id="tc-1", name="bash", input={})
        action = mw.on_tool_call(_make_ctx(), tc)
        assert action.proceed is True


# ── before_query (hard threshold) ────────────────────────────────────────


class TestBeforeQuery:
    def test_no_compaction_when_below_hard(self) -> None:
        d = _make_dispatcher(must=False)
        mw = CompactionMiddleware(d, _make_surface())
        ctx = _make_ctx(turn=3, messages=[Message(role="user", content="hi")])
        mw.before_query(ctx)
        d.run.assert_not_called()

    def test_runs_compaction_when_above_hard(self) -> None:
        d = _make_dispatcher(must=True)
        session = MagicMock()
        mw = CompactionMiddleware(d, _make_surface(), session=session)
        msgs = [Message(role="user", content="hi")]
        ctx = _make_ctx(turn=5, messages=msgs)
        mw.before_query(ctx)
        d.run.assert_called_once_with(msgs, current_turn=5, session=session)

    def test_passes_messages_by_reference(self) -> None:
        """Compaction mutates messages in-place; middleware must pass the same list."""
        d = _make_dispatcher(must=True)
        mw = CompactionMiddleware(d, _make_surface())
        msgs = [Message(role="user", content="hi")]
        ctx = _make_ctx(messages=msgs)
        mw.before_query(ctx)
        assert d.run.call_args[0][0] is msgs


# ── after_query (soft threshold) ─────────────────────────────────────────


class TestAfterQuery:
    def test_records_turn(self) -> None:
        d = _make_dispatcher(should=False)
        mw = CompactionMiddleware(d, _make_surface())
        mw.after_query(_make_ctx(), None)
        d.record_turn.assert_called_once()

    def test_no_compaction_when_below_soft(self) -> None:
        d = _make_dispatcher(should=False)
        mw = CompactionMiddleware(d, _make_surface())
        mw.after_query(_make_ctx(), None)
        d.run.assert_not_called()

    def test_runs_compaction_when_above_soft(self) -> None:
        d = _make_dispatcher(should=True, compacted=True)
        surface = _make_surface()
        session = MagicMock()
        mw = CompactionMiddleware(d, surface, session=session)
        snap = EfficiencySnapshot(
            turn=3, cascade_paths={}, empty_streak=0,
            bash_search_count=0, is_thrashing=False,
        )
        mw.set_efficiency(snap)
        msgs = [Message(role="user", content="hi")]
        ctx = _make_ctx(turn=3, messages=msgs)
        mw.after_query(ctx, None)
        d.run.assert_called_once()
        assert d.run.call_args.kwargs["efficiency"] is snap

    def test_emits_surface_notification(self) -> None:
        d = _make_dispatcher(should=True, compacted=True)
        surface = _make_surface()
        mw = CompactionMiddleware(d, surface)
        mw.after_query(_make_ctx(turn=2), None)
        surface.on_response.assert_called_once()
        resp = surface.on_response.call_args[0][0]
        assert "Auto-compacted" in resp.content

    def test_records_session_event(self) -> None:
        d = _make_dispatcher(should=True, compacted=True)
        session = MagicMock()
        mw = CompactionMiddleware(d, _make_surface(), session=session)
        mw.after_query(_make_ctx(turn=4), None)
        session.record_event.assert_called_once_with(
            "compaction",
            metadata={
                "messages_before": 20,
                "messages_after": 10,
                "tokens_saved": 4000,
                "strategy": "micro",
                "aged_results": 0,
                "turn": 4,
            },
        )

    def test_session_event_propagates_aged_results(self) -> None:
        d = _make_dispatcher(should=True, compacted=True)
        d.run.return_value = CompactionResult(
            compacted=True,
            messages_before=20,
            messages_after=10,
            tokens_before=8000,
            tokens_after=4000,
            strategy="micro",
            aged_results=3,
        )
        session = MagicMock()
        mw = CompactionMiddleware(d, _make_surface(), session=session)
        mw.after_query(_make_ctx(turn=5), None)
        call_meta = session.record_event.call_args[1]["metadata"]
        assert call_meta["aged_results"] == 3

    def test_no_notification_when_not_compacted(self) -> None:
        d = _make_dispatcher(should=True, compacted=False)
        surface = _make_surface()
        mw = CompactionMiddleware(d, surface)
        mw.after_query(_make_ctx(), None)
        surface.on_response.assert_not_called()

    def test_no_session_event_without_session(self) -> None:
        d = _make_dispatcher(should=True, compacted=True)
        mw = CompactionMiddleware(d, _make_surface(), session=None)
        # Should not raise
        mw.after_query(_make_ctx(), None)


# ── Stack integration ────────────────────────────────────────────────────


class TestStackIntegration:
    def test_in_stack_before_query(self) -> None:
        d = _make_dispatcher(must=True)
        mw = CompactionMiddleware(d, _make_surface())
        stack = MiddlewareStack([mw])
        ctx = _make_ctx(messages=[Message(role="user", content="hi")])
        stack.run_before_query(ctx)
        d.run.assert_called_once()

    def test_in_stack_after_query(self) -> None:
        d = _make_dispatcher(should=True, compacted=True)
        surface = _make_surface()
        mw = CompactionMiddleware(d, surface)
        stack = MiddlewareStack([mw])
        stack.run_after_query(_make_ctx(), None)
        d.run.assert_called_once()
        surface.on_response.assert_called_once()


# ── Efficiency snapshot ──────────────────────────────────────────────────


class TestEfficiencySnapshot:
    def test_set_efficiency(self) -> None:
        d = _make_dispatcher(should=True)
        mw = CompactionMiddleware(d, _make_surface())
        snap = EfficiencySnapshot(
            turn=1, cascade_paths={}, empty_streak=0,
            bash_search_count=0, is_thrashing=False,
        )
        mw.set_efficiency(snap)
        mw.after_query(_make_ctx(), None)
        assert d.should_compact.call_args[0][1] is snap

    def test_none_efficiency_by_default(self) -> None:
        d = _make_dispatcher(should=True)
        mw = CompactionMiddleware(d, _make_surface())
        mw.after_query(_make_ctx(), None)
        assert d.should_compact.call_args[0][1] is None
