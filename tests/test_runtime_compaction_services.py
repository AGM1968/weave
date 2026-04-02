"""Focused tests for extracted compaction services."""
from __future__ import annotations

from runtime.services.compaction_policy import CompactionConfig, CompactionEngine
from runtime.services.full_compaction import compact
from runtime.services.tool_context import age_tool_result_message
from runtime.types import Message, ToolCall, ToolResult


def test_compaction_policy_engine_uses_thresholds() -> None:
    """Compaction policy stays responsible for soft/hard threshold decisions."""
    engine = CompactionEngine(config=CompactionConfig(soft_threshold=50, hard_threshold=100))
    messages = [Message(role="assistant", content="x" * 500)]

    assert engine.should_compact(messages)
    assert engine.must_compact(messages)


def test_full_compaction_preserves_only_wv_tool_results() -> None:
    """Full compaction keeps graph-mutating tool history while dropping unrelated tool results."""
    messages = [
        Message(role="user", content="start"),
        Message(role="assistant", content="reply-1"),
        Message(
            role="assistant",
            content="doing tools",
            tool_calls=[
                ToolCall(id="tc-wv", name="wv_update", input={"id": "wv-1"}),
                ToolCall(id="tc-read", name="read", input={"path": "README.md"}),
            ],
        ),
        Message(
            role="tool_result",
            content=[
                ToolResult(id="tc-wv", content="wv ok"),
                ToolResult(id="tc-read", content="read ok"),
            ],
        ),
    ]
    messages.extend(
        Message(role="assistant", content=f"reply-{idx}")
        for idx in range(2, 10)
    )

    compacted = compact(messages, keep_turns=6)
    tool_results = [
        msg for msg in compacted if msg.role == "tool_result" and isinstance(msg.content, list)
    ]

    assert len(tool_results) == 1
    preserved_results = tool_results[0].content
    assert isinstance(preserved_results, list)
    assert all(isinstance(result, ToolResult) for result in preserved_results)
    assert [result.id for result in preserved_results] == ["tc-wv"]


def test_age_tool_result_message_trims_old_large_non_wv_results() -> None:
    """Tool-result aging should replace old large non-Weave results with previews."""
    msg = Message(
        role="tool_result",
        content=[ToolResult(id="tc-read", content="x" * 240)],
        metadata={"turn": 1},
    )

    aged = age_tool_result_message(msg, current_turn=5)

    assert aged == 1
    assert isinstance(msg.content, list)
    assert "[aged result:" in msg.content[0].content
    assert msg.metadata["aged_tool_results"] == 1


def test_age_tool_result_message_keeps_wv_results() -> None:
    """Weave tool results stay verbatim even after the aging threshold."""
    msg = Message(
        role="tool_result",
        content=[ToolResult(id="tc-wv", content="x" * 240)],
        metadata={"turn": 1, "wv_tool_ids": ["tc-wv"]},
    )

    aged = age_tool_result_message(msg, current_turn=9)

    assert aged == 0
    assert isinstance(msg.content, list)
    assert msg.content[0].content == "x" * 240


def test_compaction_engine_reports_aged_results() -> None:
    """Compaction metrics should surface how many tool results were aged this pass."""
    messages = [
        Message(role="user", content="start"),
        Message(role="assistant", content="reply-1"),
        Message(
            role="tool_result",
            content=[ToolResult(id="tc-read", content="x" * 260)],
            metadata={"turn": 1},
        ),
    ]
    messages.extend(Message(role="assistant", content=f"reply-{idx}") for idx in range(2, 11))
    engine = CompactionEngine(config=CompactionConfig(soft_threshold=50, hard_threshold=1_000))

    result = engine.run(messages, current_turn=6)

    assert result.compacted
    assert result.aged_results == 1
