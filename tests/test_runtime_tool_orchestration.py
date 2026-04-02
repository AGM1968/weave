"""Focused tests for extracted tool orchestration service."""
from __future__ import annotations

from unittest.mock import patch

from runtime.enforcement import CheckResult
from runtime.hooks import HookToolBlocked
from runtime.services.tools import ToolOrchestrator
from runtime.tools.base import EnforcementClass, Tool, ToolRegistry
from runtime.types import ToolCall, ToolResult


class _CaptureSurface:
    def __init__(self) -> None:
        self.calls: list[str] = []
        self.results: list[tuple[str, bool]] = []
        self.blocked: list[tuple[str, str]] = []

    def on_tool_call(self, tc: ToolCall) -> None:
        self.calls.append(tc.name)

    def on_tool_result(self, tc: ToolCall, result: ToolResult) -> None:
        self.results.append((tc.name, result.is_error))

    def on_tool_blocked(self, tc: ToolCall, reason: str) -> None:
        self.blocked.append((tc.name, reason))


class _BlockingHook:
    def before_tool(self, name: str, inp: dict[str, object]) -> None:  # noqa: ARG002
        if name == "edit":
            raise HookToolBlocked("hook blocked edit")

    def after_tool(  # noqa: ARG002
        self, name: str, inp: dict[str, object], result: str, is_error: bool,
    ) -> str | None:
        return None

    def before_answer(self) -> str | None:
        return None

    def on_prompt(self, task: str) -> None:  # noqa: ARG002
        pass


def test_tool_orchestrator_blocks_execute_tools_via_clear_context() -> None:
    """EXECUTE/CLOSE tools stay blocked before execution and do not emit result callbacks."""
    surface = _CaptureSurface()
    orchestrator = ToolOrchestrator(
        ToolRegistry([
            Tool("exec-tool", "desc", {"type": "object", "properties": {}}, lambda _inp: "ok", gate=EnforcementClass.EXECUTE)
        ]),
        [],
        surface,
    )

    with patch(
        "runtime.services.tools.tool_orchestration.enforcement.require_clear_context",
        return_value=CheckResult(ok=False, reason="Node is blocked"),
    ):
        results = orchestrator.dispatch([ToolCall(id="tc-1", name="exec-tool", input={})])

    assert len(results) == 1
    assert results[0].is_error
    assert results[0].content == "Node is blocked"
    assert surface.calls == ["exec-tool"]
    assert surface.results == []
    assert surface.blocked == [("exec-tool", "Node is blocked")]


def test_tool_orchestrator_emits_hook_block_without_result_callback() -> None:
    """Hook-requested blocks preserve the blocked/not-result callback contract."""
    surface = _CaptureSurface()
    orchestrator = ToolOrchestrator(
        ToolRegistry([
            Tool("edit", "desc", {"type": "object", "properties": {}}, lambda _inp: "ok")
        ]),
        [_BlockingHook()],
        surface,
    )

    results = orchestrator.dispatch([ToolCall(id="tc-1", name="edit", input={"path": "foo.py"})])

    assert len(results) == 1
    assert results[0].is_error
    assert results[0].content == "hook blocked edit"
    assert surface.calls == ["edit"]
    assert surface.results == []
    assert surface.blocked == [("edit", "hook blocked edit")]
