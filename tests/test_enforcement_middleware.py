"""Tests for EnforcementMiddleware — gating via on_tool_call."""
from __future__ import annotations

from unittest.mock import MagicMock, patch

from runtime.enforcement import CheckResult
from runtime.middleware.base import MiddlewareContext, MiddlewareStack, ToolCallAction
from runtime.middleware.enforcement import EnforcementMiddleware
from runtime.tools.base import EnforcementClass, ToolRegistry
from runtime.types import ToolCall


# ── Fixtures ─────────────────────────────────────────────────────────────


def _make_ctx() -> MiddlewareContext:
    return MiddlewareContext(turn_number=1, has_active_node=True)


def _make_tc(name: str = "bash") -> ToolCall:
    return ToolCall(id="tc-1", name=name, input={"command": "echo hi"})


def _make_registry(gate_map: dict[str, EnforcementClass] | None = None) -> ToolRegistry:
    """Build a ToolRegistry with a mock gate_for method."""
    reg = MagicMock(spec=ToolRegistry)
    gate_map = gate_map or {}
    reg.gate_for.side_effect = lambda name: gate_map.get(name, EnforcementClass.BOOTSTRAP)
    return reg


# ── Protocol compliance ──────────────────────────────────────────────────


class TestProtocolCompliance:
    """EnforcementMiddleware satisfies the Middleware protocol."""

    def test_name_property(self) -> None:
        mw = EnforcementMiddleware(MagicMock(spec=ToolRegistry))
        assert mw.name == "enforcement"

    def test_before_query_noop(self) -> None:
        mw = EnforcementMiddleware(MagicMock(spec=ToolRegistry))
        ctx = _make_ctx()
        # Should not raise
        mw.before_query(ctx)

    def test_after_query_noop(self) -> None:
        mw = EnforcementMiddleware(MagicMock(spec=ToolRegistry))
        ctx = _make_ctx()
        mw.after_query(ctx, None)


# ── Gate behavior ────────────────────────────────────────────────────────


class TestBootstrapGate:
    """BOOTSTRAP tools are never blocked."""

    def test_bootstrap_proceeds(self) -> None:
        reg = _make_registry({"wv_status": EnforcementClass.BOOTSTRAP})
        mw = EnforcementMiddleware(reg)
        action = mw.on_tool_call(_make_ctx(), _make_tc("wv_status"))
        assert action.proceed is True


class TestGraphRepairGate:
    """GRAPH_REPAIR tools require an active node."""

    @patch("runtime.middleware.enforcement.enforcement.require_active_node")
    def test_active_node_allows(self, mock_check: MagicMock) -> None:
        mock_check.return_value = CheckResult(ok=True)
        reg = _make_registry({"bash": EnforcementClass.GRAPH_REPAIR})
        mw = EnforcementMiddleware(reg)
        action = mw.on_tool_call(_make_ctx(), _make_tc("bash"))
        assert action.proceed is True
        mock_check.assert_called_once()

    @patch("runtime.middleware.enforcement.enforcement.require_active_node")
    def test_no_active_node_blocks(self, mock_check: MagicMock) -> None:
        mock_check.return_value = CheckResult(ok=False, reason="No active node")
        reg = _make_registry({"bash": EnforcementClass.GRAPH_REPAIR})
        mw = EnforcementMiddleware(reg)
        action = mw.on_tool_call(_make_ctx(), _make_tc("bash"))
        assert action.proceed is False
        assert "No active node" in action.block_reason


class TestExecuteGate:
    """EXECUTE tools require clear context."""

    @patch("runtime.middleware.enforcement.enforcement.require_clear_context")
    def test_clear_context_allows(self, mock_check: MagicMock) -> None:
        mock_check.return_value = CheckResult(ok=True)
        reg = _make_registry({"write_file": EnforcementClass.EXECUTE})
        mw = EnforcementMiddleware(reg)
        action = mw.on_tool_call(_make_ctx(), _make_tc("write_file"))
        assert action.proceed is True

    @patch("runtime.middleware.enforcement.enforcement.require_clear_context")
    def test_blocked_context_blocks(self, mock_check: MagicMock) -> None:
        mock_check.return_value = CheckResult(ok=False, reason="Node is blocked")
        reg = _make_registry({"write_file": EnforcementClass.EXECUTE})
        mw = EnforcementMiddleware(reg)
        action = mw.on_tool_call(_make_ctx(), _make_tc("write_file"))
        assert action.proceed is False
        assert "blocked" in action.block_reason.lower()


class TestCloseGate:
    """CLOSE tools require clear context (same as EXECUTE)."""

    @patch("runtime.middleware.enforcement.enforcement.require_clear_context")
    def test_close_uses_clear_context(self, mock_check: MagicMock) -> None:
        mock_check.return_value = CheckResult(ok=True)
        reg = _make_registry({"wv_done": EnforcementClass.CLOSE})
        mw = EnforcementMiddleware(reg)
        action = mw.on_tool_call(_make_ctx(), _make_tc("wv_done"))
        assert action.proceed is True
        mock_check.assert_called_once()


# ── Stack integration ────────────────────────────────────────────────────


class TestStackIntegration:
    """EnforcementMiddleware works correctly inside MiddlewareStack."""

    @patch("runtime.middleware.enforcement.enforcement.require_active_node")
    def test_stack_blocks_tool(self, mock_check: MagicMock) -> None:
        mock_check.return_value = CheckResult(ok=False, reason="No active node")
        reg = _make_registry({"bash": EnforcementClass.GRAPH_REPAIR})
        mw = EnforcementMiddleware(reg)
        stack = MiddlewareStack([mw])
        ctx = _make_ctx()
        tc = _make_tc("bash")
        action = stack.run_on_tool_call(ctx, tc)
        assert not action.proceed
        assert "No active node" in action.block_reason

    @patch("runtime.middleware.enforcement.enforcement.require_active_node")
    def test_stack_allows_tool(self, mock_check: MagicMock) -> None:
        mock_check.return_value = CheckResult(ok=True)
        reg = _make_registry({"bash": EnforcementClass.GRAPH_REPAIR})
        mw = EnforcementMiddleware(reg)
        stack = MiddlewareStack([mw])
        ctx = _make_ctx()
        tc = _make_tc("bash")
        action = stack.run_on_tool_call(ctx, tc)
        assert action.proceed

    def test_enforcement_before_other_middleware(self) -> None:
        """Enforcement middleware at index 0 blocks before later middleware runs."""
        call_order: list[str] = []

        class TrackingMiddleware:
            @property
            def name(self) -> str:
                return "tracker"

            def before_query(self, ctx: MiddlewareContext) -> None:
                pass

            def after_query(self, ctx: MiddlewareContext, outcome: object) -> None:
                pass

            def on_tool_call(self, ctx: MiddlewareContext, tool_call: ToolCall) -> ToolCallAction:
                call_order.append("tracker")
                return ToolCallAction(proceed=True)

        reg = _make_registry({"bash": EnforcementClass.GRAPH_REPAIR})
        enf = EnforcementMiddleware(reg)
        tracker = TrackingMiddleware()

        with patch("runtime.middleware.enforcement.enforcement.require_active_node") as mock_check:
            mock_check.return_value = CheckResult(ok=False, reason="blocked")
            stack = MiddlewareStack([enf, tracker])
            ctx = _make_ctx()
            action = stack.run_on_tool_call(ctx, _make_tc("bash"))

        assert not action.proceed
        # Tracker should NOT have been called — enforcement blocked first
        assert "tracker" not in call_order


# ── Tools property ───────────────────────────────────────────────────────


class TestToolsProperty:
    """The tools reference can be swapped for live registry updates."""

    def test_tools_setter(self) -> None:
        reg1 = _make_registry()
        reg2 = _make_registry()
        mw = EnforcementMiddleware(reg1)
        assert mw.tools is reg1
        mw.tools = reg2
        assert mw.tools is reg2
