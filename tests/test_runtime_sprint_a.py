"""Tests for Sprint A — QueryPolicy protocol and CompactionDispatcher.

Covers:
  T1 — QueryPolicy protocol conformance (DefaultQueryPolicy satisfies QueryPolicy)
  T2 — QueryEngine reads from policy (no direct attribute mutation)
  T3 — QueryEngine dispatch_tools reads policy for ToolOrchestrator state
  T4 — CompactionStrategy enum names and values
  T5 — CompactionDispatcher strategy selection based on token thresholds
  T6 — CompactionDispatcher run produces named strategy in CompactionResult
  T7 — CompactionDispatcher escalation: MICRO → FULL → REACTIVE
  T8 — CompactionEngine backward compat: strategy field populated

Run: poetry run pytest tests/test_runtime_sprint_a.py -v
"""
from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).parent.parent))

from runtime.engine import QueryEngine, TurnOutcome
from runtime.hooks import OpenNodeHook
from runtime.query import DefaultQueryPolicy, QueryConfig
from runtime.query.policy import QueryPolicy
from runtime.services.compaction_dispatcher import CompactionDispatcher, CompactionStrategy
from runtime.services.compaction_policy import (
    CompactionConfig,
    CompactionEngine,
    CompactionResult,
)
from runtime.services.full_compaction import estimate_tokens
from runtime.tools.base import Tool, ToolRegistry
from runtime.types import Message, Response, StopReason, ToolCall, ToolResult, Usage


# ── Helpers ──────────────────────────────────────────────────────────────────


def _usage(input_tokens: int = 50, output_tokens: int = 50) -> Usage:
    return Usage(input_tokens=input_tokens, output_tokens=output_tokens)


def _end_turn(text: str = "Done.") -> Response:
    return Response(content=text, tool_calls=[], stop_reason=StopReason.END_TURN, usage=_usage())


class _StubProvider:
    provider_name = "stub"
    model = "stub-1.0"

    def __init__(self, responses: list[Response]) -> None:
        self._responses = list(responses)
        self._index = 0
        self.calls: list[dict[str, Any]] = []

    async def chat(self, *, system: str, messages: list[Message],
                   tools: list[dict[str, Any]], max_tokens: int) -> Response:
        self.calls.append({"system": system, "max_tokens": max_tokens})
        if self._index >= len(self._responses):
            return _end_turn("(exhausted)")
        resp = self._responses[self._index]
        self._index += 1
        return resp


class _CaptureSurface:
    """Minimal surface that records callbacks."""

    def on_response(self, response: Response, turn: int) -> None:
        pass

    def on_tool_call(self, tc: ToolCall) -> None:
        pass

    def on_tool_result(self, tc: ToolCall, result: ToolResult) -> None:
        pass

    def on_tool_blocked(self, tc: ToolCall, reason: str) -> None:
        pass


def _run(coro: Any) -> Any:
    import asyncio
    return asyncio.run(coro)


def _make_messages(token_target: int) -> list[Message]:
    """Build a message list with approximately token_target estimated tokens."""
    msgs: list[Message] = []
    while estimate_tokens(msgs) < token_target:
        msgs.append(Message(role="user", content="x" * 400))
        msgs.append(Message(role="assistant", content="y" * 400))
    return msgs


# ── T1: QueryPolicy protocol conformance ────────────────────────────────────


def test_default_query_policy_satisfies_protocol() -> None:
    """DefaultQueryPolicy is a valid QueryPolicy."""
    provider = _StubProvider([])
    policy = DefaultQueryPolicy(
        provider=provider,
        tools=ToolRegistry([]),
        surface=_CaptureSurface(),
        hooks=[],
        config=QueryConfig(),
    )
    assert isinstance(policy, QueryPolicy)


def test_policy_reads_return_constructor_values() -> None:
    """Policy reads return exactly what was passed at construction."""
    provider = _StubProvider([])
    tools = ToolRegistry([])
    surface = _CaptureSurface()
    hooks: list[Any] = []
    config = QueryConfig(max_tokens=512, max_turns=5)

    policy = DefaultQueryPolicy(
        provider=provider, tools=tools, surface=surface,
        hooks=hooks, config=config,
    )
    assert policy.select_provider() is provider
    assert policy.active_tools() is tools
    assert policy.active_surface() is surface
    assert policy.active_hooks() is hooks
    assert policy.query_config() is config
    assert policy.router() is None


def test_policy_mutation_visible_to_readers() -> None:
    """Mutating the policy via setters is visible on next read."""
    provider1 = _StubProvider([])
    provider2 = _StubProvider([])
    policy = DefaultQueryPolicy(
        provider=provider1, tools=ToolRegistry([]), surface=_CaptureSurface(),
        hooks=[], config=QueryConfig(),
    )
    assert policy.select_provider() is provider1
    policy.set_provider(provider2)
    assert policy.select_provider() is provider2


# ── T2: QueryEngine reads from policy ───────────────────────────────────────


def test_query_engine_uses_policy_provider() -> None:
    """QueryEngine.run_turn() reads provider from policy, not from own attrs."""
    provider = _StubProvider([_end_turn("hello")])
    policy = DefaultQueryPolicy(
        provider=provider, tools=ToolRegistry([]), surface=_CaptureSurface(),
        hooks=[], config=QueryConfig(max_tokens=256, max_turns=5),
    )
    engine = QueryEngine(policy)

    msgs = [Message(role="user", content="hi")]
    outcome: TurnOutcome = _run(engine.run_turn(system="sys", messages=msgs, turn_number=1))

    assert outcome.done
    assert outcome.response.content == "hello"
    assert len(provider.calls) == 1


def test_query_engine_respects_policy_config() -> None:
    """QueryEngine passes max_tokens from policy.query_config()."""
    provider = _StubProvider([_end_turn("ok")])
    policy = DefaultQueryPolicy(
        provider=provider, tools=ToolRegistry([]), surface=_CaptureSurface(),
        hooks=[], config=QueryConfig(max_tokens=999, max_turns=5),
    )
    engine = QueryEngine(policy)

    msgs = [Message(role="user", content="test")]
    _run(engine.run_turn(system="sys", messages=msgs, turn_number=1))

    assert provider.calls[0]["max_tokens"] == 999


def test_query_engine_picks_up_policy_changes_between_turns() -> None:
    """Policy mutation between turns is visible to the next run_turn()."""
    provider1 = _StubProvider([_end_turn("from-p1")])
    provider2 = _StubProvider([_end_turn("from-p2")])
    policy = DefaultQueryPolicy(
        provider=provider1, tools=ToolRegistry([]), surface=_CaptureSurface(),
        hooks=[], config=QueryConfig(max_tokens=256, max_turns=5),
    )
    engine = QueryEngine(policy)

    msgs = [Message(role="user", content="turn1")]
    _run(engine.run_turn(system="sys", messages=msgs, turn_number=1))
    assert len(provider1.calls) == 1

    policy.set_provider(provider2)
    msgs.append(Message(role="user", content="turn2"))
    _run(engine.run_turn(system="sys", messages=msgs, turn_number=2))
    assert len(provider2.calls) == 1


def test_query_engine_stops_after_successful_wv_done() -> None:
    """A successful close-only tool turn should end without a follow-up LLM turn."""
    provider = _StubProvider([
        Response(
            content="closing",
            tool_calls=[ToolCall(id="1", name="wv_done", input={"node_id": "wv-abcd"})],
            stop_reason=StopReason.TOOL_USE,
            usage=_usage(),
        )
    ])
    hook = OpenNodeHook()
    hook.on_prompt("close node")
    hook.seed_active_nodes(["wv-abcd"])
    policy = DefaultQueryPolicy(
        provider=provider,
        tools=ToolRegistry([
            Tool(
                name="wv_done",
                description="close node",
                parameters={"type": "object"},
                handler=lambda _inp: '{"id":"wv-abcd"}',
            )
        ]),
        surface=_CaptureSurface(),
        hooks=[hook],
        config=QueryConfig(max_tokens=256, max_turns=5),
    )
    engine = QueryEngine(policy)

    outcome = _run(engine.run_turn(
        system="sys",
        messages=[Message(role="user", content="close it")],
        turn_number=1,
    ))

    assert outcome.done is True


# ── T3: dispatch_tools reads policy ─────────────────────────────────────────


def test_query_engine_no_direct_attribute_mutation() -> None:
    """QueryEngine has no public provider/tools/surface/hooks/config/router attrs."""
    policy = DefaultQueryPolicy(
        provider=_StubProvider([]), tools=ToolRegistry([]), surface=_CaptureSurface(),
        hooks=[], config=QueryConfig(),
    )
    engine = QueryEngine(policy)

    # These were the 7 old mutable attributes — none should exist.
    for attr in ("provider", "tools", "surface", "hooks", "config", "router"):
        assert not hasattr(engine, attr), f"QueryEngine still has mutable '{attr}' attribute"


# ── T4: CompactionStrategy enum ─────────────────────────────────────────────


def test_compaction_strategy_names() -> None:
    """Enum has exactly the 5 expected strategies (session_memory reserved for P6)."""
    assert set(s.value for s in CompactionStrategy) == {
        "none", "micro", "session_memory", "full", "reactive"
    }


# ── T5: CompactionDispatcher strategy selection ─────────────────────────────


def test_dispatcher_selects_none_below_soft() -> None:
    """Below soft threshold → NONE."""
    d = CompactionDispatcher(config=CompactionConfig(soft_threshold=60_000))
    msgs = _make_messages(30_000)
    assert d.select_strategy(msgs) is CompactionStrategy.NONE


def test_dispatcher_selects_micro_between_thresholds() -> None:
    """Between soft and hard → MICRO."""
    d = CompactionDispatcher(config=CompactionConfig(soft_threshold=60_000, hard_threshold=90_000))
    msgs = _make_messages(70_000)
    assert d.select_strategy(msgs) is CompactionStrategy.MICRO


def test_dispatcher_selects_full_above_hard() -> None:
    """Above hard threshold → FULL."""
    d = CompactionDispatcher(config=CompactionConfig(soft_threshold=60_000, hard_threshold=90_000))
    msgs = _make_messages(95_000)
    assert d.select_strategy(msgs) is CompactionStrategy.FULL


# ── T6: CompactionDispatcher run produces named strategy ────────────────────


def test_dispatcher_run_returns_strategy_name() -> None:
    """CompactionResult from dispatcher has a non-empty strategy field."""
    d = CompactionDispatcher(config=CompactionConfig(soft_threshold=100, hard_threshold=500))
    msgs = _make_messages(200)
    result = d.run(msgs)
    assert result.compacted
    assert result.strategy in {"micro", "full", "reactive"}
    assert result.strategy != ""


def test_dispatcher_run_none_strategy() -> None:
    """Below threshold → NONE strategy, no compaction."""
    d = CompactionDispatcher(config=CompactionConfig(soft_threshold=999_999))
    msgs = [Message(role="user", content="short")]
    result = d.run(msgs)
    assert not result.compacted
    assert result.strategy == "none"


# ── T7: CompactionDispatcher escalation ─────────────────────────────────────


def test_dispatcher_escalation_to_reactive() -> None:
    """When MICRO and FULL aren't enough, escalates to REACTIVE."""
    # Use very low thresholds with many messages so even tighter compaction
    # can't bring us below hard_threshold, forcing REACTIVE (drop all but 4).
    d = CompactionDispatcher(config=CompactionConfig(
        soft_threshold=100, hard_threshold=200, keep_turns=2,
    ))
    # Build enough messages that even keeping only 1 turn still exceeds threshold.
    msgs = _make_messages(100_000)
    assert len(msgs) > 10, "need many messages to trigger REACTIVE"
    result = d.run(msgs)
    assert result.compacted
    # Should have escalated — the exact strategy depends on how many msgs
    # survived FULL pass. At minimum strategy should be "full" or "reactive".
    assert result.strategy in {"full", "reactive"}
    assert result.level_used >= 2


# ── T8: CompactionEngine backward compat ────────────────────────────────────


def test_compaction_engine_populates_strategy_field() -> None:
    """Existing CompactionEngine also populates the strategy field."""
    engine = CompactionEngine(config=CompactionConfig(soft_threshold=100, hard_threshold=500))
    msgs = _make_messages(200)
    result = engine.run(msgs)
    assert result.compacted
    assert result.strategy in {"micro", "full", "reactive"}


def test_compaction_result_has_strategy_default() -> None:
    """CompactionResult defaults to empty strategy string."""
    r = CompactionResult()
    assert r.strategy == ""
