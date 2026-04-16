"""Tests for WeaveGraphMiddleware — active-node sync and open-node closeout."""

from __future__ import annotations

from unittest.mock import MagicMock


from runtime.middleware.base import MiddlewareContext, MiddlewareStack, ToolCallAction
from runtime.middleware.graph import WeaveGraphMiddleware, _OPEN_NODE_CLOSEOUT_TURN


def _ctx(
    *,
    turn: int = 1,
    max_turns: int = 25,
    messages: list | None = None,
) -> MiddlewareContext:
    return MiddlewareContext(
        turn_number=turn,
        max_turns=max_turns,
        messages=messages if messages is not None else [],
    )


def _make_wv(active: list[dict] | None = None) -> MagicMock:
    wv = MagicMock()
    wv.list_active.return_value = active or []
    wv.set_intent = MagicMock()
    return wv


# ── name ─────────────────────────────────────────────────────────────────


class TestName:
    def test_name(self) -> None:
        mw = WeaveGraphMiddleware(_make_wv(), [])
        assert mw.name == "weave_graph"


# ── before_query: active-node sync ───────────────────────────────────────


class TestActiveNodeSync:
    def test_updates_ctx_with_active_nodes(self) -> None:
        wv = _make_wv([{"id": "wv-aaa", "text": "t", "status": "active"}])
        mw = WeaveGraphMiddleware(wv, [])
        ctx = _ctx()
        mw.before_query(ctx)
        assert ctx.has_active_node is True
        assert ctx.active_node_ids == ["wv-aaa"]

    def test_updates_ctx_no_active(self) -> None:
        wv = _make_wv([])
        mw = WeaveGraphMiddleware(wv, [])
        ctx = _ctx()
        mw.before_query(ctx)
        assert ctx.has_active_node is False
        assert ctx.active_node_ids == []

    def test_uses_cached_active_first_call(self) -> None:
        wv = _make_wv()
        mw = WeaveGraphMiddleware(wv, [])
        cached = [{"id": "wv-cached", "text": "t", "status": "active"}]
        mw.set_cached_active(cached)
        ctx = _ctx()
        mw.before_query(ctx)
        assert ctx.active_node_ids == ["wv-cached"]
        wv.list_active.assert_not_called()

    def test_fresh_query_after_cache_consumed(self) -> None:
        wv = _make_wv([{"id": "wv-fresh", "text": "t", "status": "active"}])
        mw = WeaveGraphMiddleware(wv, [])
        mw.set_cached_active([{"id": "wv-cached", "text": "t", "status": "active"}])
        ctx1 = _ctx()
        mw.before_query(ctx1)  # consumes cache
        ctx2 = _ctx(turn=2)
        mw.before_query(ctx2)  # fresh query
        assert ctx2.active_node_ids == ["wv-fresh"]
        wv.list_active.assert_called_once()

    def test_list_active_error_defaults_empty(self) -> None:
        """list_active() failure is caught — active nodes default to empty."""
        wv = _make_wv()
        wv.list_active.side_effect = RuntimeError("wv not available")
        mw = WeaveGraphMiddleware(wv, [])
        ctx = _ctx()
        mw.before_query(ctx)
        assert ctx.has_active_node is False
        assert ctx.active_node_ids == []


# ── before_query: hook seeding ───────────────────────────────────────────


class TestHookSeeding:
    def test_seeds_hooks_on_first_sync(self) -> None:
        wv = _make_wv([{"id": "wv-aaa", "text": "t", "status": "active"}])
        hook = MagicMock()
        hook.seed_active_nodes = MagicMock()
        mw = WeaveGraphMiddleware(wv, [hook])
        ctx = _ctx()
        mw.before_query(ctx)
        hook.seed_active_nodes.assert_called_once_with(["wv-aaa"])

    def test_does_not_seed_twice(self) -> None:
        wv = _make_wv([{"id": "wv-aaa", "text": "t", "status": "active"}])
        hook = MagicMock()
        hook.seed_active_nodes = MagicMock()
        mw = WeaveGraphMiddleware(wv, [hook])
        mw.before_query(_ctx())
        mw.before_query(_ctx(turn=2))
        hook.seed_active_nodes.assert_called_once()

    def test_no_seed_when_messages_present(self) -> None:
        """Hooks are NOT seeded when messages already exist (normal flow)."""
        from runtime.types import user_message

        wv = _make_wv([{"id": "wv-aaa", "text": "t", "status": "active"}])
        hook = MagicMock()
        hook.seed_active_nodes = MagicMock()
        mw = WeaveGraphMiddleware(wv, [hook])
        ctx = _ctx(messages=[user_message("boot message")])
        mw.before_query(ctx)
        hook.seed_active_nodes.assert_not_called()

    def test_sets_hook_scope(self) -> None:
        from runtime.types import user_message

        wv = _make_wv([{"id": "wv-bbb", "text": "t", "status": "active"}])
        hook = MagicMock()
        hook.set_scope = MagicMock()
        mw = WeaveGraphMiddleware(wv, [hook])
        ctx = _ctx(messages=[user_message("do the thing")])
        mw.before_query(ctx)
        hook.set_scope.assert_called_once_with("wv-bbb")


# ── before_query: set_intent ─────────────────────────────────────────────


class TestSetIntent:
    def test_sets_intent_from_last_user_message(self) -> None:
        from runtime.types import user_message

        wv = _make_wv([{"id": "wv-ccc", "text": "t", "status": "active"}])
        mw = WeaveGraphMiddleware(wv, [])
        ctx = _ctx(messages=[user_message("fix the bug")])
        mw.before_query(ctx)
        wv.set_intent.assert_called_once_with("wv-ccc", "fix the bug")

    def test_no_intent_when_no_messages(self) -> None:
        wv = _make_wv([{"id": "wv-ddd", "text": "t", "status": "active"}])
        mw = WeaveGraphMiddleware(wv, [])
        ctx = _ctx(messages=[])
        mw.before_query(ctx)
        wv.set_intent.assert_not_called()


# ── before_query: open-node closeout nudge ───────────────────────────────


class TestOpenNodeCloseout:
    def test_no_nudge_early_turn(self) -> None:
        wv = _make_wv([{"id": "wv-eee", "text": "t", "status": "active"}])
        mw = WeaveGraphMiddleware(wv, [])
        ctx = _ctx(turn=3, messages=[])
        mw.before_query(ctx)
        assert len(ctx.messages) == 0

    def test_nudge_at_threshold(self) -> None:
        wv = _make_wv([{"id": "wv-fff", "text": "t", "status": "active"}])
        mw = WeaveGraphMiddleware(wv, [])
        ctx = _ctx(turn=_OPEN_NODE_CLOSEOUT_TURN, messages=[])
        mw.before_query(ctx)
        assert len(ctx.messages) == 1
        assert "active node still open past midpoint" in ctx.messages[0].content

    def test_nudge_includes_node_ids(self) -> None:
        wv = _make_wv([{"id": "wv-ggg", "text": "t", "status": "active"}])
        mw = WeaveGraphMiddleware(wv, [])
        ctx = _ctx(turn=_OPEN_NODE_CLOSEOUT_TURN, messages=[])
        mw.before_query(ctx)
        assert "wv-ggg" in ctx.messages[0].content

    def test_nudge_injected_once(self) -> None:
        wv = _make_wv([{"id": "wv-hhh", "text": "t", "status": "active"}])
        mw = WeaveGraphMiddleware(wv, [])
        ctx1 = _ctx(turn=_OPEN_NODE_CLOSEOUT_TURN, messages=[])
        mw.before_query(ctx1)
        assert len(ctx1.messages) == 1

        ctx2 = _ctx(turn=_OPEN_NODE_CLOSEOUT_TURN + 1, messages=[])
        mw.before_query(ctx2)
        assert len(ctx2.messages) == 0

    def test_nudge_records_session_event(self) -> None:
        session = MagicMock()
        wv = _make_wv([{"id": "wv-iii", "text": "t", "status": "active"}])
        mw = WeaveGraphMiddleware(wv, [], session=session)
        ctx = _ctx(turn=_OPEN_NODE_CLOSEOUT_TURN, messages=[])
        mw.before_query(ctx)
        session.record_event.assert_called_once_with(
            "open_node_closeout",
            metadata={"turn": _OPEN_NODE_CLOSEOUT_TURN},
        )

    def test_no_nudge_when_no_active_node(self) -> None:
        wv = _make_wv([])
        mw = WeaveGraphMiddleware(wv, [])
        ctx = _ctx(turn=_OPEN_NODE_CLOSEOUT_TURN, messages=[])
        mw.before_query(ctx)
        assert len(ctx.messages) == 0


# ── on_tool_call: no-op ─────────────────────────────────────────────────


class TestOnToolCall:
    def test_always_proceeds(self) -> None:
        mw = WeaveGraphMiddleware(_make_wv(), [])
        tc = MagicMock()
        result = mw.on_tool_call(_ctx(), tc)
        assert isinstance(result, ToolCallAction)
        assert result.proceed is True


# ── after_query: no-op ──────────────────────────────────────────────────


class TestAfterQuery:
    def test_after_query_is_noop(self) -> None:
        """after_query() does nothing — graph sync is purely before_query."""
        wv = _make_wv([{"id": "wv-noop", "text": "t", "status": "active"}])
        mw = WeaveGraphMiddleware(wv, [])
        ctx = _ctx()
        mw.before_query(ctx)  # populate state
        wv.list_active.reset_mock()
        mw.after_query(ctx, outcome=None)
        wv.list_active.assert_not_called()  # no re-sync


# ── stack integration ────────────────────────────────────────────────────


class TestStackIntegration:
    def test_graph_sync_in_stack(self) -> None:
        wv = _make_wv([{"id": "wv-jjj", "text": "t", "status": "active"}])
        mw = WeaveGraphMiddleware(wv, [])
        stack = MiddlewareStack([mw])
        ctx = _ctx()
        stack.run_before_query(ctx)
        assert ctx.has_active_node is True
        assert ctx.active_node_ids == ["wv-jjj"]
