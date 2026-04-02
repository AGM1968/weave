"""Focused tests for HiveRuntime shared hive-agent construction."""
from __future__ import annotations

import asyncio
from pathlib import Path
from typing import Any
from unittest.mock import MagicMock

from runtime.config import Config
from runtime.orchestration import HiveRuntime
from runtime.surfaces.sdk import AgentResult
from runtime.wv_client import WvClient


def test_hive_runtime_build_agent_context_uses_unique_hot_zone_and_no_wv_db(tmp_path: Path) -> None:
    """HiveRuntime should preserve WV_HOT_ZONE isolation without overriding WV_DB."""
    cfg = Config.load()
    cfg.session_dir = tmp_path / "sessions"

    runtime = HiveRuntime(
        cfg=cfg,
        repo_root=tmp_path,
        wv_bin="wv",
        provider_builder=MagicMock(),
        tool_builder=MagicMock(return_value=[]),
        agent_runner=MagicMock(),
        wv_factory=MagicMock(),
    )

    context = runtime.build_agent_context(subtree="wv-epic-1", agent_id="agent-1")

    assert context.env["WV_AGENT_ID"] == "agent-1"
    assert "WV_HOT_ZONE" in context.env
    assert "WV_DB" not in context.env
    assert context.hot_zone.name == f"{tmp_path.name}-agent-1"
    assert context.session_dir == cfg.session_dir / "hive" / "agent-1"


def test_hive_runtime_run_subtree_reuses_shared_runtime_wiring(tmp_path: Path) -> None:
    """HiveRuntime should centralize provider/tool/session/wv wiring for hive agents."""
    cfg = Config.load()
    cfg.session_dir = tmp_path / "sessions"
    fake_provider = MagicMock()
    fake_wv = MagicMock(spec=WvClient)
    fake_wv.wv_bin = "/tmp/custom-wv"
    captured: dict[str, Any] = {}

    async def _runner(task: str, **kwargs: Any) -> AgentResult:
        captured["task"] = task
        captured.update(kwargs)
        return AgentResult(turns=2, total_cost_usd=0.02)

    runtime = HiveRuntime(
        cfg=cfg,
        repo_root=tmp_path,
        wv_bin="/tmp/custom-wv",
        provider_builder=MagicMock(return_value=fake_provider),
        tool_builder=MagicMock(return_value=[]),
        agent_runner=_runner,
        wv_factory=MagicMock(return_value=fake_wv),
    )

    result = asyncio.run(
        runtime.run_subtree(
            subtree="wv-epic-1",
            agent_id="agent-1",
            budget_usd=0.75,
            task="stub task",
        )
    )

    assert result.turns == 2
    assert captured["task"] == "stub task"
    assert captured["provider"] is fake_provider
    assert captured["tools"] == []
    assert captured["wv_client"] is fake_wv
    assert captured["max_turns"] == cfg.max_turns
    assert captured["max_tokens"] == cfg.max_tokens
    assert captured["budget_usd"] == 0.75
    assert captured["session"].path.parent == cfg.session_dir / "hive" / "agent-1"
