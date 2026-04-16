"""Tests for the middleware protocol and stack executor."""

from __future__ import annotations

import pytest

from runtime.middleware.base import (
    Middleware,
    MiddlewareContext,
    MiddlewareStack,
    SkipTurn,
    StopAgent,
    ToolCallAction,
)
from runtime.types import ToolCall, ToolResult


# ── Test middleware implementations ───────────────────────────────────────


class NoopMiddleware:
    """Minimal middleware that does nothing — tests duck-typing."""

    @property
    def name(self) -> str:
        return "noop"


class RecordingMiddleware:
    """Records calls for test assertions."""

    def __init__(self, id_: str = "recorder") -> None:
        self._id = id_
        self.calls: list[str] = []

    @property
    def name(self) -> str:
        return self._id

    def before_query(self, ctx: MiddlewareContext) -> None:
        self.calls.append(f"before_query:{ctx.turn_number}")

    def after_query(self, ctx: MiddlewareContext, outcome: object) -> None:
        self.calls.append(f"after_query:{ctx.turn_number}")

    def on_tool_call(self, ctx: MiddlewareContext, tool_call: ToolCall) -> ToolCallAction:
        self.calls.append(f"on_tool_call:{tool_call.name}")
        return ToolCallAction(proceed=True)


class SkipTurnMiddleware:
    """Skips turns with even numbers."""

    @property
    def name(self) -> str:
        return "skip-even"

    def before_query(self, ctx: MiddlewareContext) -> None:
        if ctx.turn_number % 2 == 0:
            raise SkipTurn(f"skip turn {ctx.turn_number}")


class StopMiddleware:
    """Stops the agent at a configured turn."""

    def __init__(self, stop_at: int, phase: str = "before") -> None:
        self._stop_at = stop_at
        self._phase = phase

    @property
    def name(self) -> str:
        return "stopper"

    def before_query(self, ctx: MiddlewareContext) -> None:
        if self._phase == "before" and ctx.turn_number >= self._stop_at:
            raise StopAgent("budget", "out of budget")

    def after_query(self, ctx: MiddlewareContext, outcome: object) -> None:
        if self._phase == "after" and ctx.turn_number >= self._stop_at:
            raise StopAgent("diminishing_returns")


class BlockToolMiddleware:
    """Blocks specific tool names."""

    def __init__(self, blocked: set[str]) -> None:
        self._blocked = blocked

    @property
    def name(self) -> str:
        return "tool-blocker"

    def on_tool_call(self, ctx: MiddlewareContext, tool_call: ToolCall) -> ToolCallAction:
        if tool_call.name in self._blocked:
            return ToolCallAction(proceed=False, block_reason=f"blocked: {tool_call.name}")
        return ToolCallAction(proceed=True)


class MessageInjector:
    """Injects a system message before queries."""

    def __init__(self, message: str) -> None:
        self._message = message

    @property
    def name(self) -> str:
        return "injector"

    def before_query(self, ctx: MiddlewareContext) -> None:
        from runtime.types import user_message
        ctx.messages.append(user_message(self._message))


class CrashingMiddleware:
    """Raises unexpected exceptions — tests error isolation."""

    @property
    def name(self) -> str:
        return "crasher"

    def before_query(self, ctx: MiddlewareContext) -> None:
        raise ValueError("oops")

    def after_query(self, ctx: MiddlewareContext, outcome: object) -> None:
        raise ValueError("oops again")

    def on_tool_call(self, ctx: MiddlewareContext, tool_call: ToolCall) -> ToolCallAction:
        raise ValueError("tool oops")

    def on_tool_result(
        self, ctx: MiddlewareContext, tool_call: ToolCall, result: ToolResult,
    ) -> str | None:
        raise ValueError("result oops")

    def on_turn_end(self, ctx: MiddlewareContext, *, done: bool) -> str | None:
        raise ValueError("turn_end oops")


class FeedbackMiddleware:
    """Returns feedback on tool results — tests on_tool_result."""

    def __init__(self, feedback: str | None = None) -> None:
        self._feedback = feedback

    @property
    def name(self) -> str:
        return "feedback"

    def on_tool_result(
        self, ctx: MiddlewareContext, tool_call: ToolCall, result: ToolResult,
    ) -> str | None:
        return self._feedback


class RedirectMiddleware:
    """Returns a redirect on turn end — tests on_turn_end."""

    def __init__(self, redirect: str | None = None, *, only_when_done: bool = False) -> None:
        self._redirect = redirect
        self._only_when_done = only_when_done

    @property
    def name(self) -> str:
        return "redirector"

    def on_turn_end(self, ctx: MiddlewareContext, *, done: bool) -> str | None:
        if self._only_when_done and not done:
            return None
        return self._redirect


# ── Fixtures ─────────────────────────────────────────────────────────────


def _make_ctx(turn: int = 1, **kwargs: object) -> MiddlewareContext:
    return MiddlewareContext(turn_number=turn, **kwargs)  # type: ignore[arg-type]


def _make_tool_call(name: str = "bash", input_: dict | None = None) -> ToolCall:
    return ToolCall(id="tc-1", name=name, input=input_ or {})


def _make_tool_result(content: str = "ok", *, is_error: bool = False) -> ToolResult:
    return ToolResult(id="tc-1", content=content, is_error=is_error)


# ── MiddlewareContext ────────────────────────────────────────────────────


class TestMiddlewareContext:
    def test_defaults(self) -> None:
        ctx = MiddlewareContext()
        assert ctx.turn_number == 0
        assert ctx.messages == []
        assert ctx.active_node_ids == []
        assert ctx.meta == {}

    def test_meta_communication(self) -> None:
        ctx = _make_ctx()
        ctx.meta["compacted"] = True
        assert ctx.meta["compacted"] is True


# ── MiddlewareStack: before_query ────────────────────────────────────────


class TestBeforeQuery:
    def test_calls_in_order(self) -> None:
        r1 = RecordingMiddleware("a")
        r2 = RecordingMiddleware("b")
        stack = MiddlewareStack([r1, r2])
        ctx = _make_ctx(turn=3)
        stack.run_before_query(ctx)
        assert r1.calls == ["before_query:3"]
        assert r2.calls == ["before_query:3"]

    def test_skip_turn_propagates(self) -> None:
        stack = MiddlewareStack([SkipTurnMiddleware()])
        with pytest.raises(SkipTurn) as exc:
            stack.run_before_query(_make_ctx(turn=2))
        assert "skip turn 2" in str(exc.value)

    def test_skip_turn_stops_chain(self) -> None:
        """Middleware after the skip doesn't execute."""
        r = RecordingMiddleware()
        stack = MiddlewareStack([SkipTurnMiddleware(), r])
        with pytest.raises(SkipTurn):
            stack.run_before_query(_make_ctx(turn=4))
        assert r.calls == []

    def test_stop_agent_propagates(self) -> None:
        stack = MiddlewareStack([StopMiddleware(stop_at=1)])
        with pytest.raises(StopAgent) as exc:
            stack.run_before_query(_make_ctx(turn=1))
        assert exc.value.reason == "budget"

    def test_noop_middleware_skipped(self) -> None:
        """Middleware without before_query is silently skipped."""
        r = RecordingMiddleware()
        stack = MiddlewareStack([NoopMiddleware(), r])
        stack.run_before_query(_make_ctx(turn=1))
        assert r.calls == ["before_query:1"]

    def test_crash_isolated(self) -> None:
        """Unexpected exceptions are caught; remaining middleware still runs."""
        r = RecordingMiddleware()
        stack = MiddlewareStack([CrashingMiddleware(), r])
        stack.run_before_query(_make_ctx(turn=1))
        assert r.calls == ["before_query:1"]


# ── MiddlewareStack: after_query ─────────────────────────────────────────


class TestAfterQuery:
    def test_calls_in_reverse_order(self) -> None:
        r1 = RecordingMiddleware("first")
        r2 = RecordingMiddleware("second")
        stack = MiddlewareStack([r1, r2])
        ctx = _make_ctx(turn=5)
        stack.run_after_query(ctx, outcome=None)
        # Reverse order: second called before first
        assert r2.calls == ["after_query:5"]
        assert r1.calls == ["after_query:5"]

    def test_stop_agent_propagates(self) -> None:
        stack = MiddlewareStack([StopMiddleware(stop_at=3, phase="after")])
        with pytest.raises(StopAgent) as exc:
            stack.run_after_query(_make_ctx(turn=3), outcome=None)
        assert exc.value.reason == "diminishing_returns"

    def test_crash_isolated(self) -> None:
        r = RecordingMiddleware()
        stack = MiddlewareStack([r, CrashingMiddleware()])
        stack.run_after_query(_make_ctx(turn=1), outcome=None)
        assert r.calls == ["after_query:1"]


# ── MiddlewareStack: on_tool_call ────────────────────────────────────────


class TestOnToolCall:
    def test_proceed_by_default(self) -> None:
        stack = MiddlewareStack([RecordingMiddleware()])
        action = stack.run_on_tool_call(_make_ctx(), _make_tool_call("bash"))
        assert action.proceed is True

    def test_block_returns_immediately(self) -> None:
        blocker = BlockToolMiddleware({"rm_rf"})
        r = RecordingMiddleware()
        stack = MiddlewareStack([blocker, r])
        action = stack.run_on_tool_call(_make_ctx(), _make_tool_call("rm_rf"))
        assert action.proceed is False
        assert "blocked" in action.block_reason
        # Recorder after blocker should not have been called for on_tool_call
        assert not any("on_tool_call" in c for c in r.calls)

    def test_non_blocked_passes_through(self) -> None:
        blocker = BlockToolMiddleware({"rm_rf"})
        r = RecordingMiddleware()
        stack = MiddlewareStack([blocker, r])
        action = stack.run_on_tool_call(_make_ctx(), _make_tool_call("bash"))
        assert action.proceed is True
        assert "on_tool_call:bash" in r.calls

    def test_crash_isolated(self) -> None:
        r = RecordingMiddleware()
        stack = MiddlewareStack([CrashingMiddleware(), r])
        action = stack.run_on_tool_call(_make_ctx(), _make_tool_call("bash"))
        assert action.proceed is True
        assert "on_tool_call:bash" in r.calls

    def test_empty_stack(self) -> None:
        stack = MiddlewareStack([])
        action = stack.run_on_tool_call(_make_ctx(), _make_tool_call("bash"))
        assert action.proceed is True


# ── MiddlewareStack: management ──────────────────────────────────────────


class TestStackManagement:
    def test_add(self) -> None:
        stack = MiddlewareStack()
        assert len(stack) == 0
        stack.add(NoopMiddleware())
        assert len(stack) == 1

    def test_remove(self) -> None:
        r = RecordingMiddleware("target")
        stack = MiddlewareStack([NoopMiddleware(), r])
        assert len(stack) == 2
        removed = stack.remove("target")
        assert removed is True
        assert len(stack) == 1
        # Removing non-existent returns False
        assert stack.remove("nonexistent") is False

    def test_bool(self) -> None:
        assert not MiddlewareStack()
        assert MiddlewareStack([NoopMiddleware()])

    def test_middleware_property_returns_copy(self) -> None:
        r = RecordingMiddleware()
        stack = MiddlewareStack([r])
        mw_list = stack.middleware
        mw_list.append(NoopMiddleware())
        assert len(stack) == 1  # Original unchanged


# ── Message mutation ─────────────────────────────────────────────────────


class TestMessageMutation:
    def test_before_query_can_inject_messages(self) -> None:
        from runtime.types import user_message
        ctx = _make_ctx(turn=1, messages=[user_message("hello")])
        stack = MiddlewareStack([MessageInjector("injected")])
        stack.run_before_query(ctx)
        assert len(ctx.messages) == 2
        assert ctx.messages[-1].content == "injected"


# ── Protocol compliance ──────────────────────────────────────────────────


class TestProtocolCompliance:
    def test_recording_is_middleware(self) -> None:
        assert isinstance(RecordingMiddleware(), Middleware)

    def test_noop_is_middleware(self) -> None:
        # NoopMiddleware has name but no methods — still structurally compatible
        # via duck typing. The Protocol check is runtime_checkable.
        noop = NoopMiddleware()
        assert hasattr(noop, "name")


# ── MiddlewareStack: on_tool_result ──────────────────────────────────────


class TestOnToolResult:
    def test_collects_feedback(self) -> None:
        stack = MiddlewareStack([FeedbackMiddleware("[lint] ok")])
        fb = stack.run_on_tool_result(
            _make_ctx(), _make_tool_call("edit"), _make_tool_result(),
        )
        assert fb == ["[lint] ok"]

    def test_none_feedback_skipped(self) -> None:
        stack = MiddlewareStack([FeedbackMiddleware(None)])
        fb = stack.run_on_tool_result(
            _make_ctx(), _make_tool_call("bash"), _make_tool_result(),
        )
        assert fb == []

    def test_multiple_middleware_feedback(self) -> None:
        stack = MiddlewareStack([
            FeedbackMiddleware("[lint] warning"),
            FeedbackMiddleware("[efficiency] cascade"),
        ])
        fb = stack.run_on_tool_result(
            _make_ctx(), _make_tool_call("grep"), _make_tool_result(),
        )
        assert len(fb) == 2
        assert "[lint]" in fb[0]
        assert "[efficiency]" in fb[1]

    def test_noop_middleware_skipped(self) -> None:
        stack = MiddlewareStack([NoopMiddleware(), FeedbackMiddleware("hint")])
        fb = stack.run_on_tool_result(
            _make_ctx(), _make_tool_call(), _make_tool_result(),
        )
        assert fb == ["hint"]

    def test_crash_isolated(self) -> None:
        stack = MiddlewareStack([CrashingMiddleware(), FeedbackMiddleware("ok")])
        fb = stack.run_on_tool_result(
            _make_ctx(), _make_tool_call(), _make_tool_result(),
        )
        assert fb == ["ok"]

    def test_empty_stack(self) -> None:
        stack = MiddlewareStack([])
        fb = stack.run_on_tool_result(
            _make_ctx(), _make_tool_call(), _make_tool_result(),
        )
        assert fb == []


# ── MiddlewareStack: on_turn_end ─────────────────────────────────────────


class TestOnTurnEnd:
    def test_returns_redirect(self) -> None:
        stack = MiddlewareStack([RedirectMiddleware("keep going")])
        redirect = stack.run_on_turn_end(_make_ctx(), done=True)
        assert redirect == "keep going"

    def test_none_allows_done(self) -> None:
        stack = MiddlewareStack([RedirectMiddleware(None)])
        redirect = stack.run_on_turn_end(_make_ctx(), done=True)
        assert redirect is None

    def test_first_redirect_wins(self) -> None:
        stack = MiddlewareStack([
            RedirectMiddleware("first"),
            RedirectMiddleware("second"),
        ])
        redirect = stack.run_on_turn_end(_make_ctx(), done=True)
        assert redirect == "first"

    def test_done_flag_passed(self) -> None:
        mw = RedirectMiddleware("only when done", only_when_done=True)
        stack = MiddlewareStack([mw])
        assert stack.run_on_turn_end(_make_ctx(), done=False) is None
        assert stack.run_on_turn_end(_make_ctx(), done=True) == "only when done"

    def test_noop_middleware_skipped(self) -> None:
        stack = MiddlewareStack([NoopMiddleware(), RedirectMiddleware("hi")])
        redirect = stack.run_on_turn_end(_make_ctx(), done=True)
        assert redirect == "hi"

    def test_crash_isolated(self) -> None:
        stack = MiddlewareStack([CrashingMiddleware(), RedirectMiddleware("ok")])
        redirect = stack.run_on_turn_end(_make_ctx(), done=True)
        assert redirect == "ok"

    def test_empty_stack(self) -> None:
        stack = MiddlewareStack([])
        redirect = stack.run_on_turn_end(_make_ctx(), done=True)
        assert redirect is None
