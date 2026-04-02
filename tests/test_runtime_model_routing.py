"""Focused tests for extracted model routing service."""
from __future__ import annotations

from typing import Any

from runtime.providers.base import ModelProvider
from runtime.services.model_routing import CHEAP_TOOLS, ToolClassRouter
from runtime.types import Response, StopReason, Usage


class _StubProvider:
    def __init__(self, name: str) -> None:
        self.provider_name = name
        self.model = f"{name}-model"

    async def chat(
        self,
        *,
        system: str,  # noqa: ARG002
        messages: list[Any],  # noqa: ARG002
        tools: list[dict[str, Any]],  # noqa: ARG002
        max_tokens: int,  # noqa: ARG002
    ) -> Response:
        return Response(
            content="ok",
            tool_calls=[],
            stop_reason=StopReason.END_TURN,
            usage=Usage(input_tokens=1, output_tokens=1),
        )


def test_tool_class_router_routes_read_only_turns_to_cheap() -> None:
    """Shared routing service keeps current cheap-tool classification."""
    cheap: ModelProvider = _StubProvider("cheap")
    expensive: ModelProvider = _StubProvider("expensive")
    router = ToolClassRouter(cheap=cheap, expensive=expensive)

    router.record(["wv_status", "read", "glob"])

    assert router.select().provider_name == "cheap"


def test_cheap_tools_constant_exposes_expected_read_only_tools() -> None:
    """Compatibility shim preserves the current cheap-tool allowlist."""
    assert "wv_status" in CHEAP_TOOLS
    assert "read" in CHEAP_TOOLS
    assert "write" not in CHEAP_TOOLS
