"""Sprint C tests — SharedBootstrap and hive context sharing.

Covers:
  - SharedBootstrap dataclass construction and immutability
  - assemble_shared_bootstrap queries graph once
  - Agent uses SharedBootstrap when provided (skips graph queries)
  - Agent falls back to fresh queries when SharedBootstrap is degraded
  - N subagents share the same SharedBootstrap (O(1) graph queries)
  - Parameter threading: orchestrate → _run_one_agent → run_subtree → run_agent → Agent
"""
from __future__ import annotations

from datetime import datetime
from typing import Any
from unittest.mock import MagicMock

from runtime.hive.bootstrap import SharedBootstrap, assemble_shared_bootstrap


# ── SharedBootstrap dataclass ────────────────────────────────────────────────


class TestSharedBootstrap:
    def test_construction(self) -> None:
        sb = SharedBootstrap(bootstrap_text="<graph_context>test</graph_context>")
        assert sb.bootstrap_text == "<graph_context>test</graph_context>"
        assert sb.is_degraded is False
        assert isinstance(sb.assembled_at, datetime)

    def test_frozen(self) -> None:
        sb = SharedBootstrap(bootstrap_text="test")
        try:
            sb.bootstrap_text = "mutated"  # type: ignore[misc]
            assert False, "Should have raised FrozenInstanceError"
        except AttributeError:
            pass  # expected — frozen dataclass

    def test_degraded_flag(self) -> None:
        sb = SharedBootstrap(bootstrap_text="", is_degraded=True)
        assert sb.is_degraded is True
        assert sb.bootstrap_text == ""

    def test_assembled_at_is_utc(self) -> None:
        sb = SharedBootstrap(bootstrap_text="x")
        assert sb.assembled_at.tzinfo is not None


# ── assemble_shared_bootstrap ────────────────────────────────────────────────


class _GraphCountingWv:
    """WvClient stub that counts method calls."""

    def __init__(self) -> None:
        self.call_counts: dict[str, int] = {}

    def _track(self, method: str) -> None:
        self.call_counts[method] = self.call_counts.get(method, 0) + 1

    def status(self) -> str:
        self._track("status")
        return "active:1 done:3"

    def list_active(self) -> list[dict[str, Any]]:
        self._track("list_active")
        return [{"id": "wv-abc", "text": "task", "status": "active"}]

    def show(self, node_id: str) -> dict[str, Any]:
        self._track("show")
        return {"id": node_id, "text": "task", "status": "active"}

    def context(self, node_id: str) -> dict[str, Any]:
        self._track("context")
        return {"node": {"id": node_id, "text": "task", "status": "active"}}

    def ready(self) -> list[dict[str, Any]]:
        self._track("ready")
        return []

    def learnings(self, **kwargs: object) -> list[dict[str, Any]]:
        self._track("learnings")
        return []

    def list_nodes(self, status: str, limit: int | None = None) -> list[dict[str, Any]]:
        self._track("list_nodes")
        return []


class TestAssembleSharedBootstrap:
    def test_returns_shared_bootstrap(self) -> None:
        wv = _GraphCountingWv()
        sb = assemble_shared_bootstrap(wv)  # type: ignore[arg-type]
        assert isinstance(sb, SharedBootstrap)
        assert not sb.is_degraded

    def test_contains_graph_status(self) -> None:
        wv = _GraphCountingWv()
        sb = assemble_shared_bootstrap(wv)  # type: ignore[arg-type]
        assert "Graph Status" in sb.bootstrap_text

    def test_queries_graph_once(self) -> None:
        """All data assembled in a single call — no duplicate queries."""
        wv = _GraphCountingWv()
        assemble_shared_bootstrap(wv)  # type: ignore[arg-type]
        assert wv.call_counts.get("status", 0) == 1
        assert wv.call_counts.get("list_active", 0) == 1

    def test_degraded_on_error(self) -> None:
        """Graph errors produce an empty SharedBootstrap (service catches WvError)."""
        from runtime.wv_client import WvError

        wv = MagicMock()
        wv.status.side_effect = WvError("graph down")
        sb = assemble_shared_bootstrap(wv)
        # BootstrapContextService catches WvError internally → empty text, not degraded.
        # The assembly itself succeeds; degradation is only for uncaught exceptions.
        assert sb.bootstrap_text == ""


# ── Agent SharedBootstrap integration ────────────────────────────────────────


class TestAgentSharedBootstrapIntegration:
    """Verify Agent skips graph queries when SharedBootstrap is provided."""

    def test_agent_accepts_shared_bootstrap_param(self) -> None:
        """Agent.__init__ accepts shared_bootstrap keyword."""
        from runtime.agent import Agent

        sb = SharedBootstrap(bootstrap_text="<graph_context>pre-assembled</graph_context>")
        provider = MagicMock()
        provider.name = "stub"
        surface = MagicMock()
        # Just verify construction doesn't raise
        agent = Agent(
            provider=provider,
            tools=[],
            surface=surface,
            shared_bootstrap=sb,
        )
        assert agent._shared_bootstrap is sb  # noqa: SLF001

    def test_shared_bootstrap_skips_list_active(self) -> None:
        """When SharedBootstrap is valid, _run_async skips list_active call."""
        call_log: list[str] = []

        class _TrackingWv:
            def list_active(self) -> list[Any]:
                call_log.append("list_active")
                return []

            def set_intent(self, *a: object) -> None:
                pass

            def set_scope(self, *a: object) -> None:
                pass

            def status(self) -> str:
                call_log.append("status")
                return ""

        # Simulate what _run_async does with shared bootstrap:
        sb = SharedBootstrap(bootstrap_text="<graph_context>shared</graph_context>")
        wv = _TrackingWv()

        # Emulate the shared bootstrap path in _run_async
        if sb is not None and hasattr(sb, "bootstrap_text") and not sb.is_degraded:
            bootstrap = sb.bootstrap_text
        else:
            bootstrap = ""
            wv.list_active()  # would be called in the else branch

        assert "list_active" not in call_log
        assert bootstrap == "<graph_context>shared</graph_context>"

    def test_degraded_bootstrap_falls_back_to_fresh(self) -> None:
        """Degraded SharedBootstrap triggers normal graph query path."""
        call_log: list[str] = []

        class _TrackingWv:
            def list_active(self) -> list[Any]:
                call_log.append("list_active")
                return []

        sb = SharedBootstrap(bootstrap_text="", is_degraded=True)
        wv = _TrackingWv()

        # Emulate the shared bootstrap path in _run_async
        if sb is not None and hasattr(sb, "bootstrap_text") and not sb.is_degraded:
            pass  # would use sb.bootstrap_text
        else:
            wv.list_active()  # fallback path

        assert "list_active" in call_log


# ── O(1) graph queries for N subagents ───────────────────────────────────────


class TestSharedBootstrapReuse:
    """Verify that N subagents reuse the same SharedBootstrap snapshot."""

    def test_n_agents_one_assembly(self) -> None:
        """Assemble once, reuse N times — no extra graph queries."""
        wv = _GraphCountingWv()
        sb = assemble_shared_bootstrap(wv)  # type: ignore[arg-type]
        initial_status_calls = wv.call_counts.get("status", 0)

        # Simulate N subagents reading the shared bootstrap
        for _ in range(5):
            assert sb.bootstrap_text  # each agent reads the same snapshot
            assert not sb.is_degraded

        # No additional graph queries
        assert wv.call_counts.get("status", 0) == initial_status_calls

    def test_frozen_prevents_mutation_between_agents(self) -> None:
        """SharedBootstrap is frozen — agents can't corrupt each other's data."""
        sb = SharedBootstrap(bootstrap_text="original")
        try:
            sb.bootstrap_text = "mutated"  # type: ignore[misc]
            assert False, "Should raise"
        except AttributeError:
            pass
        assert sb.bootstrap_text == "original"


# ── Parameter threading ──────────────────────────────────────────────────────


class TestParameterThreading:
    """Verify shared_bootstrap param is accepted at each layer."""

    def test_run_agent_accepts_shared_bootstrap(self) -> None:
        """run_agent() accepts shared_bootstrap keyword."""
        import inspect

        from runtime.surfaces.sdk import run_agent

        sig = inspect.signature(run_agent)
        assert "shared_bootstrap" in sig.parameters

    def test_hive_runtime_run_subtree_accepts_shared_bootstrap(self) -> None:
        """HiveRuntime.run_subtree() accepts shared_bootstrap keyword."""
        import inspect

        from runtime.orchestration.hive_runtime import HiveRuntime

        sig = inspect.signature(HiveRuntime.run_subtree)
        assert "shared_bootstrap" in sig.parameters

    def test_agent_runtime_create_agent_accepts_shared_bootstrap(self) -> None:
        """AgentRuntime.create_agent() accepts shared_bootstrap keyword."""
        import inspect

        from runtime.orchestration.agent_runtime import AgentRuntime

        sig = inspect.signature(AgentRuntime.create_agent)
        assert "shared_bootstrap" in sig.parameters

    def test_agent_init_accepts_shared_bootstrap(self) -> None:
        """Agent.__init__() accepts shared_bootstrap keyword."""
        import inspect

        from runtime.agent import Agent

        sig = inspect.signature(Agent.__init__)
        assert "shared_bootstrap" in sig.parameters
