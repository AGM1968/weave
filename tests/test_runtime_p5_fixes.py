"""Regression tests for P5 dogfood audit compaction bugs.

Covers:
  T1 — aged_results counts ALL aged messages from original list, including dropped (CompactionEngine)
  T2 — aged_results counts ALL aged messages from original list, including dropped (CompactionDispatcher)
  T3 — silent L3 skip: warning logged when ≤4 messages above hard_threshold (Engine)
  T4 — silent L3 skip: warning logged when ≤4 messages above hard_threshold (Dispatcher)
  T5 — agentic text-turn undercount: compact() counts tool-call messages as turns
  T6 — compact() early-exit guard allows compaction in tool-heavy sessions
  T7 — dropped_texts includes assistant messages with tool_calls for summarization

Run: poetry run pytest tests/test_runtime_p5_fixes.py -v
"""
from __future__ import annotations

import logging
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from runtime.services.compaction_dispatcher import CompactionDispatcher
from runtime.services.compaction_policy import CompactionConfig, CompactionEngine
from runtime.services.full_compaction import (
    _count_assistant_turns,
    compact,
)
from runtime.types import Message, ToolCall


# ── Helpers ──────────────────────────────────────────────────────────────────


def _msg(role: str, content: str, *, metadata: dict | None = None,
         tool_calls: list[ToolCall] | None = None) -> Message:
    """Create a test message with optional metadata and tool_calls."""
    return Message(
        role=role,
        content=content,
        metadata=metadata or {},
        tool_calls=tool_calls or [],
    )


def _big_msg(role: str, tokens: int, **kw) -> Message:
    """Create a message with approximately `tokens` estimated tokens."""
    return _msg(role, "x" * (tokens * 4), **kw)


def _tool_call_msg(content: str = "", tool_name: str = "bash") -> Message:
    """Create an assistant message with a tool call."""
    return Message(
        role="assistant",
        content=content,
        metadata={},
        tool_calls=[ToolCall(id=f"tc-{id(content)}", name=tool_name, input="{}")],
    )


def _build_agentic_session(turns: int) -> list[Message]:
    """Build a session with alternating user → assistant+tool → tool_result triples."""
    msgs: list[Message] = []
    for i in range(turns):
        msgs.append(_msg("user", f"Question {i} " + "x" * 200))
        msgs.append(_tool_call_msg(f"Let me check {i}", tool_name="bash"))
        msgs.append(_msg("tool_result", f"result {i} " + "y" * 200))
        msgs.append(_msg("assistant", f"Answer {i} " + "z" * 200))
    return msgs


# ── T1/T2: aged_results from post-compact result ────────────────────────────


def test_engine_aged_results_post_compact():
    """T1: CompactionEngine.aged_results counts ALL aged messages, including dropped ones.

    age_tool_results() mutates messages in-place; compaction then drops the early messages
    into the head. Counting from the original list (not result_messages) is the only way
    to capture aged counts for messages that are dropped — they won't appear in result_messages.
    """
    config = CompactionConfig(soft_threshold=500, hard_threshold=2000, keep_turns=2)
    engine = CompactionEngine(config=config)

    msgs: list[Message] = []
    for i in range(20):
        msgs.append(_msg("user", f"q{i} " + "x" * 200))
        msgs.append(_msg("assistant", f"a{i} " + "y" * 200))

    msgs[1].metadata["aged_tool_results"] = 3  # early — dropped by compaction
    msgs[3].metadata["aged_tool_results"] = 2  # early — dropped by compaction
    msgs[-1].metadata["aged_tool_results"] = 1  # recent — survives compaction

    result = engine.run(msgs)
    assert result.compacted
    # All three aged_tool_results entries are counted, including the dropped ones (G8 fix).
    assert result.aged_results == 6, (
        f"aged_results={result.aged_results} should be 3+2+1=6 (all original, not just survivors)"
    )


def test_dispatcher_aged_results_post_compact():
    """T2: CompactionDispatcher.aged_results counts ALL aged messages, including dropped ones."""
    config = CompactionConfig(soft_threshold=500, hard_threshold=2000, keep_turns=2)
    dispatcher = CompactionDispatcher(config=config)

    msgs: list[Message] = []
    for i in range(20):
        msgs.append(_msg("user", f"q{i} " + "x" * 200))
        msgs.append(_msg("assistant", f"a{i} " + "y" * 200))

    msgs[1].metadata["aged_tool_results"] = 3  # early — dropped by compaction
    msgs[3].metadata["aged_tool_results"] = 2  # early — dropped by compaction
    msgs[-1].metadata["aged_tool_results"] = 1  # recent — survives compaction

    result = dispatcher.run(msgs)
    assert result.compacted
    assert result.aged_results == 6, (
        f"aged_results={result.aged_results} should be 3+2+1=6 (all original, not just survivors)"
    )


# ── T3/T4: silent L3 skip produces warning ──────────────────────────────────


def test_engine_l3_skip_warning(caplog):
    """T3: CompactionEngine logs warning when L3 is skipped due to ≤4 messages."""
    config = CompactionConfig(soft_threshold=100, hard_threshold=500, keep_turns=1)
    engine = CompactionEngine(config=config)

    # 4 huge messages — after L1/L2, still above threshold but only ≤4 messages
    msgs = [_big_msg("user", 300), _big_msg("assistant", 300),
            _big_msg("user", 300), _big_msg("assistant", 300)]
    # Need enough messages to pass _MIN_MESSAGES guard in compact()
    prefix = [_msg("user", f"u{i}") for i in range(10)]
    # Add tool-call assistant messages to make enough turns
    for i in range(6):
        prefix.append(_tool_call_msg(f"tc{i}"))
    all_msgs = prefix + msgs

    with caplog.at_level(logging.WARNING):
        result = engine.run(all_msgs)

    if result.tokens_after >= config.hard_threshold and result.level_used < 3:
        assert "reactive level 3 skipped" in caplog.text.lower(), (
            "Expected warning about L3 skip when tokens still above hard_threshold"
        )


def test_dispatcher_l3_skip_warning(caplog):
    """T4: CompactionDispatcher logs warning when L3 is skipped due to ≤4 messages."""
    config = CompactionConfig(soft_threshold=100, hard_threshold=500, keep_turns=1)
    dispatcher = CompactionDispatcher(config=config)

    msgs = [_big_msg("user", 300), _big_msg("assistant", 300),
            _big_msg("user", 300), _big_msg("assistant", 300)]
    prefix = [_msg("user", f"u{i}") for i in range(10)]
    for i in range(6):
        prefix.append(_tool_call_msg(f"tc{i}"))
    all_msgs = prefix + msgs

    with caplog.at_level(logging.WARNING):
        result = dispatcher.run(all_msgs)

    if result.tokens_after >= config.hard_threshold and result.strategy != "reactive":
        assert "reactive level 3 skipped" in caplog.text.lower(), (
            "Expected warning about L3 skip when tokens still above hard_threshold"
        )


# ── T5/T6/T7: agentic text-turn undercount ──────────────────────────────────


def test_count_assistant_turns_includes_tool_calls():
    """T5: _count_assistant_turns counts messages with tool_calls as turns."""
    msgs = [
        _msg("user", "question"),
        _tool_call_msg("checking"),          # assistant with tool_calls
        _msg("tool_result", "result"),
        _msg("assistant", "final answer"),   # assistant without tool_calls
    ]
    count = _count_assistant_turns(msgs)
    assert count == 2, f"Expected 2 turns (1 tool-call + 1 text), got {count}"


def test_compact_fires_in_agentic_session():
    """T6: compact() actually compacts a tool-heavy session that would have
    been skipped under the old pure-text-turn counting."""
    # 8 agentic turns = 32 messages (user, assistant+tool, tool_result, assistant)
    msgs = _build_agentic_session(8)
    assert len(msgs) >= 12, "Sanity: enough messages to pass _MIN_MESSAGES"

    original_count = len(msgs)
    result = compact(msgs, keep_turns=3)
    assert len(result) < original_count, (
        f"Expected compaction to reduce {original_count} messages, got {len(result)}"
    )


def test_compact_preserves_tool_call_info_in_summary():
    """T7: dropped assistant messages with tool_calls are included in
    summarization (their tool names appear in the summary)."""
    msgs = _build_agentic_session(8)
    result = compact(msgs, keep_turns=2)

    # Find the compaction summary message
    summaries = [m for m in result if m.metadata.get("compacted")]
    assert summaries, "Expected a compaction summary message"
    summary_text = summaries[0].content
    assert isinstance(summary_text, str)
    # The summary should mention "bash" since that's our tool_call name
    assert "bash" in summary_text, (
        f"Summary should include tool names from dropped messages: {summary_text[:200]}"
    )


def test_count_assistant_turns_empty():
    """Edge case: no assistant messages returns 0."""
    msgs = [_msg("user", "hello"), _msg("user", "world")]
    assert _count_assistant_turns(msgs) == 0


def test_count_assistant_turns_mixed():
    """Mixed session with both text-only and tool-call assistant messages."""
    msgs = [
        _msg("user", "q1"),
        _tool_call_msg("tc1"),
        _msg("tool_result", "r1"),
        _msg("assistant", "a1"),
        _msg("user", "q2"),
        _tool_call_msg("tc2"),
        _msg("tool_result", "r2"),
        _tool_call_msg("tc3"),
        _msg("tool_result", "r3"),
        _msg("assistant", "a2"),
    ]
    # 4 assistant messages total: tc1, a1, tc2, tc3 — wait, a2 also
    # tc1, a1, tc2, tc3, a2 = 5
    assert _count_assistant_turns(msgs) == 5
