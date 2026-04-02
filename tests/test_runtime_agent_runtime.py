"""Focused tests for AgentRuntime shared construction."""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from unittest.mock import MagicMock

from runtime.config import Config
from runtime.orchestration import AgentRuntime, AgentRuntimeConfig
from runtime.session import Session
from runtime.surfaces.sdk import SdkSurface
from runtime.wv_client import WvClient


def test_agent_runtime_create_agent_preserves_wv_bin_and_limits(tmp_path: Path) -> None:
    """Shared runtime builder should preserve Agent wiring used by all surfaces."""
    provider = MagicMock()
    provider.provider_name = "anthropic"
    provider.model = "claude-sonnet-4-6"
    fake_wv = MagicMock(spec=WvClient)
    fake_wv.wv_bin = "/tmp/custom-wv"

    runtime = AgentRuntime(
        provider=provider,
        tools=[],
        surface=SdkSurface(),
        config=AgentRuntimeConfig(max_tokens=123, max_turns=9, budget_usd=1.5),
        session=Session.new(tmp_path),
        wv_client=fake_wv,
        wv_bin=fake_wv.wv_bin,
    )

    agent = runtime.create_agent()

    assert agent.query_config.max_tokens == 123
    assert agent.query_config.max_turns == 9
    assert agent.budget_policy.budget_usd == 1.5
    assert agent._wv.wv_bin == "/tmp/custom-wv"  # pylint: disable=protected-access


def test_agent_runtime_default_tools_adds_session_tools_when_requested(tmp_path: Path) -> None:
    """Default tool composition should include session tools only when requested."""
    fake_wv = MagicMock(spec=WvClient)
    fake_wv.wv_bin = "wv"

    tools = AgentRuntime.default_tools(
        fake_wv,
        session_dir=tmp_path,
        include_code_tools=True,
        include_session_tools=True,
    )

    tool_names = {tool.name for tool in tools}

    assert "wv_status" in tool_names
    assert "read" in tool_names
    assert "session_search" in tool_names


@dataclass
class _FakeConfig:
    provider: str = "anthropic"
    provider_registry: object = object()
    model: str = "claude-sonnet-4-6"
    api_key: str | None = "test-key"
    base_url: str | None = None
    session_dir: Path = Path(".")
    max_tokens: int = 222
    max_turns: int = 11
    budget_usd: float = 3.25


def test_agent_runtime_build_dependencies_reuses_latest_session_and_preserves_jsonl_path(
    tmp_path: Path,
) -> None:
    """Shared entrypoint deps should resume the existing JSONL instead of creating a new one."""
    session_dir = tmp_path / "sessions"
    resumed = Session.new(session_dir)
    resumed.append(__import__("runtime.types", fromlist=["Message"]).Message(role="user", content="hi"), turn=1)
    cfg = Config.load()
    cfg.session_dir = session_dir
    cfg.max_tokens = 222
    cfg.max_turns = 11
    cfg.budget_usd = 3.25
    provider = MagicMock()
    provider.provider_name = "anthropic"
    provider.model = cfg.model

    deps = AgentRuntime.build_dependencies(
        cfg,
        continue_session="latest",
        include_code_tools=False,
        include_session_tools=False,
        provider_builder=MagicMock(return_value=provider),
    )

    assert deps.session.path == resumed.path
    assert deps.session.messages[-1].content == "hi"
    assert deps.config.max_tokens == 222
    assert deps.config.max_turns == 11
    assert deps.config.budget_usd == 3.25


def test_agent_runtime_build_dependencies_can_keep_weave_only_tools(tmp_path: Path) -> None:
    """Examples should be able to share runtime deps without pulling code/session tools."""
    cfg = Config.load()
    cfg.session_dir = tmp_path / "sessions"
    provider = MagicMock()
    provider.provider_name = "anthropic"
    provider.model = cfg.model

    deps = AgentRuntime.build_dependencies(
        cfg,
        include_code_tools=False,
        include_session_tools=False,
        provider_builder=MagicMock(return_value=provider),
    )

    tool_names = {tool.name for tool in deps.tools}

    assert "wv_status" in tool_names
    assert "read" not in tool_names
    assert "session_search" not in tool_names
