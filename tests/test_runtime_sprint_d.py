"""Sprint D tests — ToolResultBudget, schema-aware truncation.

Covers:
  - ToolResultBudget per-tool-class limits and global fallback
  - JSON array truncation preserves parseable structure
  - JSON object truncation preserves structure (keys, valid JSON)
  - Plain text truncation at newline boundaries
  - cap_tool_output dispatches to correct strategy
  - ToolExecutor applies per-tool budgets
"""
from __future__ import annotations

import json

from runtime.services.tools.budget import (
    ToolResultBudget,
    cap_tool_output,
    truncate_json_array,
    truncate_json_object,
)


# ── ToolResultBudget ─────────────────────────────────────────────────────────


class TestToolResultBudget:
    def test_read_tool_budget(self) -> None:
        budget = ToolResultBudget()
        assert budget.limit_for("read") == 8_000

    def test_bash_tool_budget(self) -> None:
        budget = ToolResultBudget()
        assert budget.limit_for("bash") == 4_000

    def test_wv_prefix_match(self) -> None:
        budget = ToolResultBudget()
        assert budget.limit_for("wv_list") == 2_000
        assert budget.limit_for("wv_search") == 2_000
        assert budget.limit_for("wv_tree") == 4_000  # tree is larger

    def test_grep_glob_budgets(self) -> None:
        budget = ToolResultBudget()
        assert budget.limit_for("grep") == 8_000
        assert budget.limit_for("glob") == 8_000

    def test_unknown_tool_gets_global_fallback(self) -> None:
        budget = ToolResultBudget()
        assert budget.limit_for("edit") == 80_000
        assert budget.limit_for("create") == 80_000
        assert budget.limit_for("some_custom_tool") == 80_000

    def test_custom_budgets(self) -> None:
        budget = ToolResultBudget(per_tool={"foo": 500}, global_cap=1000)
        assert budget.limit_for("foo") == 500
        assert budget.limit_for("bar") == 1000

    def test_frozen(self) -> None:
        budget = ToolResultBudget()
        try:
            budget.global_limit = 999  # type: ignore[misc]
            assert False, "Should raise"
        except AttributeError:
            pass


# ── JSON array truncation ────────────────────────────────────────────────────


class TestJsonArrayTruncation:
    def test_small_array_unchanged(self) -> None:
        content = json.dumps([1, 2, 3])
        result = truncate_json_array(content, 10_000)
        assert json.loads(result) == [1, 2, 3]

    def test_large_array_truncated_at_element_boundary(self) -> None:
        items = [{"id": f"wv-{i:04d}", "text": "x" * 40} for i in range(50)]
        content = json.dumps(items)
        result = truncate_json_array(content, 500)
        parsed = json.loads(result)
        assert isinstance(parsed, list)
        assert 0 < len(parsed) < 50
        # Verify each kept item is a complete dict
        for item in parsed:
            assert "id" in item
            assert "text" in item

    def test_result_is_valid_json(self) -> None:
        content = json.dumps(list(range(1000)))
        result = truncate_json_array(content, 200)
        parsed = json.loads(result)
        assert isinstance(parsed, list)


# ── JSON object truncation ───────────────────────────────────────────────────


class TestJsonObjectTruncation:
    def test_small_object_unchanged(self) -> None:
        content = json.dumps({"a": 1, "b": 2})
        result = truncate_json_object(content, 10_000)
        assert json.loads(result) == {"a": 1, "b": 2}

    def test_large_object_truncated_to_valid_json(self) -> None:
        obj = {f"key_{i}": "x" * 200 for i in range(20)}
        content = json.dumps(obj)
        result = truncate_json_object(content, 500)
        parsed = json.loads(result)
        assert isinstance(parsed, dict)
        assert len(parsed) < 20

    def test_preserves_short_keys_drops_long_values(self) -> None:
        obj = {"id": "abc", "name": "short", "content": "x" * 5000}
        content = json.dumps(obj)
        result = truncate_json_object(content, 200)
        parsed = json.loads(result)
        assert isinstance(parsed, dict)
        # Short keys should survive, long value should be truncated or dropped
        assert "id" in parsed

    def test_result_is_always_valid_json(self) -> None:
        obj = {"k1": "v" * 100, "k2": "w" * 100, "k3": "x" * 100}
        content = json.dumps(obj)
        result = truncate_json_object(content, 150)
        parsed = json.loads(result)
        assert isinstance(parsed, dict)


# ── Plain text truncation ────────────────────────────────────────────────────


class TestPlainTextTruncation:
    def test_short_text_unchanged(self) -> None:
        result = cap_tool_output("hello world", 10_000)
        assert result == "hello world"

    def test_truncated_at_newline(self) -> None:
        lines = "\n".join(f"line {i}" for i in range(100))
        result = cap_tool_output(lines, 200)
        assert "[Output truncated" in result
        # Should end at a newline boundary, not mid-line
        body = result.split("\n\n[Output truncated")[0]
        assert not body.endswith("e ")  # not mid-word

    def test_trailer_included(self) -> None:
        content = "x" * 10_000
        result = cap_tool_output(content, 500)
        assert "[Output truncated" in result
        assert "Use a more specific query" in result


# ── cap_tool_output dispatch ─────────────────────────────────────────────────


class TestCapToolOutputDispatch:
    def test_dispatches_to_json_array(self) -> None:
        content = json.dumps(list(range(1000)))
        result = cap_tool_output(content, 200)
        parsed = json.loads(result)
        assert isinstance(parsed, list)

    def test_dispatches_to_json_object(self) -> None:
        obj = {f"k{i}": "v" * 200 for i in range(20)}
        content = json.dumps(obj)
        result = cap_tool_output(content, 500)
        parsed = json.loads(result)
        assert isinstance(parsed, dict)

    def test_dispatches_to_plain_text(self) -> None:
        content = "plain text\n" * 1000
        result = cap_tool_output(content, 200)
        assert "[Output truncated" in result

    def test_no_truncation_when_within_limit(self) -> None:
        content = "short"
        result = cap_tool_output(content, 10_000)
        assert result == "short"


# ── ToolExecutor integration ─────────────────────────────────────────────────


class TestToolExecutorBudgetIntegration:
    def test_wv_tool_uses_class_budget(self) -> None:
        """wv_list output exceeding 2K class budget gets truncated."""
        from runtime.services.tools import ToolExecutor
        from runtime.tools.base import Tool, ToolRegistry
        from runtime.types import ToolCall

        big_output = json.dumps([{"id": f"wv-{i:04d}", "text": "x" * 100} for i in range(100)])
        executor = ToolExecutor(
            ToolRegistry([Tool("wv_list", "desc", {"type": "object"}, lambda _: big_output)]),
            [],
        )
        result = executor.execute(ToolCall(id="tc-1", name="wv_list", input={}))
        # Output should be truncated below the original size
        assert len(result.content) < len(big_output)
        # But still be valid JSON
        parsed = json.loads(result.content)
        assert isinstance(parsed, list)
        assert len(parsed) < 100

    def test_edit_tool_uses_global_cap(self) -> None:
        """edit tool has no class budget — uses global 80K cap."""
        from runtime.services.tools import ToolExecutor
        from runtime.tools.base import Tool, ToolRegistry
        from runtime.types import ToolCall

        small_output = "ok"
        executor = ToolExecutor(
            ToolRegistry([Tool("edit", "desc", {"type": "object"}, lambda _: small_output)]),
            [],
        )
        result = executor.execute(ToolCall(id="tc-1", name="edit", input={}))
        assert result.content == "ok"  # no truncation needed
