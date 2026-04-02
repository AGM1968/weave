"""Focused tests for shared prompt-cache request shaping."""
from __future__ import annotations

import asyncio
from types import SimpleNamespace
from typing import Any
from unittest.mock import AsyncMock, patch

from runtime.providers.anthropic import AnthropicProvider
from runtime.providers.openai import _to_api_tools
from runtime.services.prompt_cache import apply_anthropic_prompt_cache, build_anthropic_system_blocks
from runtime.types import Message


def test_apply_anthropic_prompt_cache_marks_latest_message_and_last_tool() -> None:
    """Anthropic cache policy should mark the newest prompt boundary and tool list."""
    messages: list[dict[str, Any]] = [
        {"role": "user", "content": "earlier"},
        {"role": "assistant", "content": [{"type": "text", "text": "latest"}]},
    ]
    tools: list[dict[str, Any]] = [
        {"name": "z-last", "input_schema": {}},
        {"name": "a-first", "input_schema": {}},
    ]

    cached_messages, cached_tools = apply_anthropic_prompt_cache(messages, tools)

    assert "cache_control" not in messages[-1]["content"][-1]
    assert cached_messages[-1]["content"][-1]["cache_control"] == {"type": "ephemeral"}
    assert cached_tools[-1]["cache_control"] == {"type": "ephemeral"}


def test_build_anthropic_system_blocks_preserves_system_cache_breakpoint() -> None:
    """Anthropic system prompts should continue to use the shared ephemeral breakpoint."""
    assert build_anthropic_system_blocks("system prompt") == [{
        "type": "text",
        "text": "system prompt",
        "cache_control": {"type": "ephemeral"},
    }]


def test_openai_tools_are_sorted_for_prefix_stability() -> None:
    """OpenAI tool serialization should be deterministic across equivalent tool sets."""
    tools = [
        {"name": "zeta", "description": "later", "input_schema": {}},
        {"name": "alpha", "description": "earlier", "input_schema": {}},
    ]

    api_tools = _to_api_tools(tools)

    assert [tool["function"]["name"] for tool in api_tools] == ["alpha", "zeta"]


def test_anthropic_provider_chat_uses_prompt_cache_policy() -> None:
    """AnthropicProvider.chat should send cached system/tools/latest-message boundaries."""
    async def _run() -> None:
        fake_response = SimpleNamespace(
            content=[SimpleNamespace(type="text", text="ok")],
            stop_reason="end_turn",
            model="claude-sonnet-4-6",
            usage=SimpleNamespace(
                input_tokens=1,
                output_tokens=2,
                cache_read_input_tokens=3,
                cache_creation_input_tokens=4,
            ),
        )
        fake_client = SimpleNamespace(messages=SimpleNamespace(create=AsyncMock()))

        with (
            patch("runtime.providers.anthropic._anthropic.AsyncAnthropic", return_value=fake_client),
            patch(
                "runtime.providers.anthropic.with_retry",
                new=AsyncMock(return_value=fake_response),
            ) as retry_mock,
        ):
            provider = AnthropicProvider(api_key="test-key")
            response = await provider.chat(
                system="system prompt",
                messages=[Message(role="user", content="latest user message")],
                tools=[{"name": "status", "description": "show status", "input_schema": {}}],
                max_tokens=256,
            )

        await_args = retry_mock.await_args
        assert await_args is not None
        kwargs = await_args.kwargs
        assert kwargs["system"][0]["cache_control"] == {"type": "ephemeral"}
        assert kwargs["messages"][-1]["content"][-1]["cache_control"] == {"type": "ephemeral"}
        assert kwargs["tools"][-1]["cache_control"] == {"type": "ephemeral"}
        assert response.usage.cache_read_tokens == 3
        assert response.usage.cache_creation_tokens == 4

    asyncio.run(_run())
