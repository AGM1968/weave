"""Focused tests for extracted tool execution service."""
from __future__ import annotations

import json

from runtime.hooks import LintAfterEditHook
from runtime.services.tools import ToolExecutor
from runtime.services.tools.budget import cap_tool_output
from runtime.tools.base import Tool, ToolRegistry
from runtime.types import ToolCall


def test_tool_executor_returns_unknown_tool_error() -> None:
    """ToolExecutor preserves ToolRegistry unknown-tool behavior."""
    executor = ToolExecutor(ToolRegistry([]), [])

    result = executor.execute(ToolCall(id="tc-1", name="unknown", input={}))

    assert result.is_error
    assert "unknown tool" in result.content


def test_tool_executor_applies_after_tool_feedback() -> None:
    """ToolExecutor appends hook feedback after a successful tool run."""
    hook = LintAfterEditHook()
    executor = ToolExecutor(
        ToolRegistry([
            Tool(
                "edit",
                "desc",
                {"type": "object", "properties": {}},
                lambda _inp: "ok",
            )
        ]),
        [hook],
    )

    result = executor.execute(ToolCall(id="tc-1", name="edit", input={"path": "foo.py"}))

    assert result.content.startswith("ok")


def test_tool_executor_accepts_turn_number_without_changing_result_shape() -> None:
    """ToolExecutor should support turn-aware callers without changing ToolResult payloads."""
    executor = ToolExecutor(
        ToolRegistry([
            Tool(
                "read",
                "desc",
                {"type": "object", "properties": {}},
                lambda _inp: "ok",
            )
        ]),
        [],
    )

    result = executor.execute(ToolCall(id="tc-1", name="read", input={"path": "README.md"}), turn_number=4)

    assert result.id == "tc-1"
    assert result.content == "ok"
    assert not result.is_error


def test_cap_tool_output_preserves_json_array_shape_when_truncated() -> None:
    """Large JSON-array tool output should stay parseable after truncation."""
    content = json.dumps(
        [{"id": f"wv-{index:06d}", "text": "x" * 40} for index in range(30)],
        indent=2,
    )

    capped = cap_tool_output(content, 400)
    parsed = json.loads(capped)

    assert isinstance(parsed, list)
    assert parsed
    assert len(parsed) < 30
