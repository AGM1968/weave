"""Focused tests for the extracted bootstrap-context service."""
from __future__ import annotations

import json
from typing import cast

from runtime.services.bootstrap_context import BootstrapContextService
from runtime.wv_client import WvClient


class _ContextWv:
    def status(self) -> str:
        return "Work: 1 active, 2 ready, 0 blocked."

    def list_active(self) -> list[dict[str, str]]:
        return [
            {
                "id": "wv-1fa876",
                "text": "Task: align runtime grounding",
                "status": "active",
                "metadata": '{"done_criteria":"tests and docs updated"}',
            }
        ]

    def show(self, node_id: str) -> dict[str, str]:
        return {
            "id": node_id,
            "text": "Task: align runtime grounding",
            "status": "active",
            "metadata": '{"done_criteria":"tests and docs updated"}',
        }

    def context(self, node_id: str) -> dict[str, object]:
        return {
            "node": {"id": node_id},
            "blockers": [],
            "ancestors": [],
            "pitfalls": ["Do not drift from WORKFLOW.md"],
        }

    def ready(self, *, all_nodes: bool = False) -> list[dict[str, str]]:
        del all_nodes
        return [{"id": "wv-6f53b9", "text": "Phase 5 gate"}]

    def learnings(self, recent: int = 10) -> list[dict[str, str]]:
        del recent
        return [{
            "id": "wv-learning",
            "text": "Task title only",
            "metadata": json.dumps(
                {"learning": "decision: keep runtime aligned | pattern: sync docs with shipped behavior"}
            ),
        }]


class _FindingContextWv(_ContextWv):
    def context(self, node_id: str) -> dict[str, object]:
        ctx = super().context(node_id)
        ctx["finding"] = {
            "id": "wv-find01",
            "violation_type": "R10:open_node_at_end",
            "root_cause": "bootstrap text omitted active-node type",
            "proposed_fix": "record active_node_type in session_start metadata",
            "confidence": "high",
            "fixable": True,
        }
        return ctx


def test_bootstrap_context_service_builds_graph_snapshot() -> None:
    """BootstrapContextService preserves the existing graph snapshot contract."""
    service = BootstrapContextService(cast(WvClient, _ContextWv()))

    bootstrap = service.build_bootstrap_message()

    assert "<graph_context>" in bootstrap and "</graph_context>" in bootstrap
    assert "## Graph Status" in bootstrap
    assert "**Done when:** tests and docs updated" in bootstrap
    assert "## Ready Work (1 unblocked)" in bootstrap
    assert "decision: keep runtime aligned" in bootstrap


def test_bootstrap_context_service_includes_finding_handoff() -> None:
    service = BootstrapContextService(cast(WvClient, _FindingContextWv()))

    bootstrap = service.build_bootstrap_message()

    assert "**Finding handoff (wv-find01):**" in bootstrap
    assert "R10:open_node_at_end" in bootstrap
    assert "record active_node_type in session_start metadata" in bootstrap
