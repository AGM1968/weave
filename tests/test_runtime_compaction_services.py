"""Focused tests for extracted compaction services."""
from __future__ import annotations

from unittest.mock import MagicMock

from runtime.services.compaction_dispatcher import CompactionDispatcher
from runtime.services.compaction_policy import CompactionConfig, CompactionEngine
from runtime.services.full_compaction import compact, extract_working_memory
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


# ── Layer 4: extract_working_memory ──────────────────────────────────────────
# PASS: extracts active node, modified files, last commit, last learning
# FAIL: AttributeError on str-typed tc.input; empty result on empty messages


def _msg_with_call(name: str, **kwargs: object) -> Message:
    """Helper: assistant message with a single tool call."""
    return Message(
        role="assistant",
        content="",
        tool_calls=[ToolCall(id="x", name=name, input=dict(kwargs))],
    )


def test_extract_working_memory_active_node() -> None:
    """PASS: wv_work tool call sets active_node in summary."""
    msgs = [_msg_with_call("wv_work", node_id="wv-abc1")]
    result = extract_working_memory(msgs)
    assert "wv-abc1" in result, f"FAIL — active node missing from: {result!r}"


def test_extract_working_memory_modified_files() -> None:
    """PASS: edit/write tool calls populate Modified line."""
    msgs = [
        _msg_with_call("edit", path="runtime/foo.py"),
        _msg_with_call("write", file_path="runtime/bar.py"),
    ]
    result = extract_working_memory(msgs)
    assert "runtime/foo.py" in result, f"FAIL — edit path missing: {result!r}"
    assert "runtime/bar.py" in result, f"FAIL — write path missing: {result!r}"


def test_extract_working_memory_last_commit() -> None:
    """PASS: git commit bash call extracts commit message fragment."""
    msgs = [_msg_with_call("bash", command='git commit -m "feat: add foo bar"')]
    result = extract_working_memory(msgs)
    assert "feat: add foo bar" in result, f"FAIL — commit message missing: {result!r}"


def test_extract_working_memory_learning() -> None:
    """PASS: wv_done learning string appears in summary."""
    msgs = [_msg_with_call("wv_done", node_id="wv-xyz9", learning="decision: used FTS5 | pattern: always cap")]
    result = extract_working_memory(msgs)
    assert "decision: used FTS5" in result, f"FAIL — learning missing: {result!r}"


def test_extract_working_memory_str_input_guard() -> None:
    """PASS: tc.input as str (not dict) does not raise AttributeError."""
    msg = Message(
        role="assistant",
        content="",
        tool_calls=[ToolCall(id="y", name="bash", input="raw string input")],  # type: ignore[arg-type]
    )
    result = extract_working_memory([msg])  # must not raise
    assert isinstance(result, str), "FAIL — result must be a string"


def test_extract_working_memory_empty_messages() -> None:
    """PASS: empty message list returns a non-empty fallback string."""
    result = extract_working_memory([])
    assert result, "FAIL — empty input should return fallback message"
    assert "No structural" in result, f"FAIL — unexpected fallback: {result!r}"


def test_extract_working_memory_capped_at_500_chars() -> None:
    """PASS: output is never longer than 500 characters."""
    msgs = [_msg_with_call("edit", path="x" * 200) for _ in range(10)]
    result = extract_working_memory(msgs)
    assert len(result) <= 500, f"FAIL — summary too long: {len(result)} chars"


# ── Layer 4 (wire): CompactionDispatcher injects summary via session ──────────


def test_dispatcher_calls_record_compaction_summary_when_session_provided() -> None:
    """PASS: run() calls session.record_compaction_summary() when session is given."""
    cfg = CompactionConfig(soft_threshold=1, hard_threshold=10)
    disp = CompactionDispatcher(cfg)
    messages = [
        Message(role="user", content="x" * 20),
        *[Message(role="assistant", content=f"reply {i}") for i in range(15)],
    ]
    fake_session = MagicMock()
    disp.run(messages, session=fake_session)
    assert fake_session.record_compaction_summary.called, (
        "FAIL — record_compaction_summary not called with session"
    )


def test_dispatcher_no_session_does_not_raise() -> None:
    """PASS: run() without session parameter completes silently (no AttributeError)."""
    cfg = CompactionConfig(soft_threshold=1, hard_threshold=10)
    disp = CompactionDispatcher(cfg)
    messages = [
        Message(role="user", content="x" * 20),
        *[Message(role="assistant", content=f"reply {i}") for i in range(15)],
    ]
    result = disp.run(messages)  # no session kwarg
    assert result.compacted, "FAIL — expected compaction to run"
