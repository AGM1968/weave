"""Phase 1 integration tests — verify the complete agent loop.

Tests:
1. Phase 1 module structure (all files exist, importable)
2. ModelProvider protocol satisfied by AnthropicProvider
3. Enforcement gate blocks mutations without active node
4. ToolRegistry dispatches correctly, captures errors
5. Agent runs with mock provider: single turn, no tool calls
6. python -m runtime --help exits 0
"""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock

# Ensure repo root is on path
sys.path.insert(0, str(Path(__file__).parent.parent))

PASS = 0
FAIL = 0


def ok(msg: str) -> None:
    global PASS
    PASS += 1
    print(f"  ✓ {msg}")


def fail(msg: str, exc: Exception | None = None) -> None:
    global FAIL
    FAIL += 1
    suffix = f": {exc}" if exc else ""
    print(f"  ✗ {msg}{suffix}")


def make_mock_provider(content: str = "Done.", tool_calls: list | None = None) -> MagicMock:
    from runtime.types import Response, StopReason, Usage
    p = MagicMock()
    p.model = "test"
    p.chat = AsyncMock(return_value=Response(
        content=content,
        tool_calls=tool_calls or [],
        stop_reason=StopReason.END_TURN if not tool_calls else StopReason.TOOL_USE,
        usage=Usage(input_tokens=10, output_tokens=5),
    ))
    return p


# ── 1. Module structure ───────────────────────────────────────────────────────
print("\nTest 1: Module structure")

MODULES = [
    "runtime.types",
    "runtime.wv_client",
    "runtime.enforcement",
    "runtime.providers.base",
    "runtime.providers.anthropic",
    "runtime.tools.base",
    "runtime.tools.code",
    "runtime.tools.weave",
    "runtime.agent",
    "runtime.main",
]
for mod in MODULES:
    try:
        __import__(mod)
        ok(f"import {mod}")
    except ImportError as e:
        fail(f"import {mod}", e)

# ── 2. Protocol check ─────────────────────────────────────────────────────────
print("\nTest 2: ModelProvider protocol")
try:
    from runtime.providers.anthropic import AnthropicProvider
    from runtime.providers.base import ModelProvider
    p = AnthropicProvider(api_key="test")
    assert isinstance(p, ModelProvider)
    ok("AnthropicProvider satisfies ModelProvider")
    assert p.model == "claude-sonnet-4-6"
    ok("default model is claude-sonnet-4-6")
except Exception as e:
    fail("protocol check", e)

# ── 3. Enforcement gate (isolated temp DB) ───────────────────────────────────
print("\nTest 3: Enforcement gate (no active node)")
try:
    import runtime.enforcement as enf
    from runtime.wv_client import WvClient, WvError

    _REPO_ROOT = Path(__file__).parent.parent
    _WV_SCRIPT = str(_REPO_ROOT / "scripts" / "wv")

    with tempfile.TemporaryDirectory() as td:
        env = {**os.environ, "WV_HOT_ZONE": td, "WV_DB": f"{td}/brain.db",
               "WV_NO_WARN": "1"}
        subprocess.run(["git", "init", "-q", td], check=True, capture_output=True)
        subprocess.run(
            [_WV_SCRIPT, "init"],
            cwd=td,  # WEAVE_DIR = td/.weave (empty, no state.sql)
            env={**env, "WV_HOT_ZONE": td},
            capture_output=True,
        )

        # Patched client that uses the isolated DB
        wv = WvClient(wv_bin=_WV_SCRIPT)

        def _patched_run(args: list[str]) -> str:
            r = subprocess.run(
                [_WV_SCRIPT, *args],
                capture_output=True, text=True, env=env, timeout=10,
                cwd=td,  # consistent with init — prevents live state.sql replay
            )
            if r.returncode != 0:
                raise WvError(f"wv {' '.join(args)}: {r.stderr.strip()}")
            return r.stdout.strip()

        wv.run = _patched_run  # type: ignore[method-assign]
        enf.set_client(wv)

        result = enf.require_active_node()
        assert not result.ok
        ok("gate returns ok=False when no active node")
        assert "wv_work" in result.reason or "No active" in result.reason
        ok("reason explains how to fix")
except Exception as e:
    fail("enforcement gate", e)

# ── 4. ToolRegistry ───────────────────────────────────────────────────────────
print("\nTest 4: ToolRegistry")
try:
    from runtime.tools.base import Tool, ToolRegistry
    from runtime.types import ToolCall

    def _noop(inp: dict) -> str:
        return "result"

    def _boom(inp: dict) -> str:
        raise ValueError("boom")

    tools = [
        Tool("safe", "desc", {"type": "object", "properties": {}, "required": []},
             _noop, mutating=False),
        Tool("danger", "desc", {"type": "object", "properties": {}, "required": []},
             _noop, mutating=True),
        Tool("failing", "desc", {"type": "object", "properties": {}, "required": []},
             _boom, mutating=False),
    ]
    reg = ToolRegistry(tools)

    assert not reg.is_mutating("safe")
    ok("safe tool not mutating")
    assert reg.is_mutating("danger")
    ok("danger tool is mutating")

    r = reg.execute(ToolCall(id="1", name="safe", input={}))
    assert not r.is_error and r.content == "result"
    ok("safe tool executes correctly")

    r2 = reg.execute(ToolCall(id="2", name="unknown", input={}))
    assert r2.is_error
    ok("unknown tool returns error result (no raise)")

    r3 = reg.execute(ToolCall(id="3", name="failing", input={}))
    assert r3.is_error and "boom" in r3.content
    ok("exception in handler captured as is_error ToolResult")

    defs = reg.definitions()
    assert all("name" in d and "input_schema" in d for d in defs)
    ok(f"definitions() returns {len(defs)} Anthropic-format schemas")
except Exception as e:
    fail("ToolRegistry", e)

# ── 5. Agent single turn ──────────────────────────────────────────────────────
print("\nTest 5: Agent single turn (no tool calls)")
try:
    from runtime.agent import Agent
    from runtime.tools.code import make_code_tools

    from runtime.surfaces.print import PrintSurface
    provider = make_mock_provider(content="Files listed.")
    agent = Agent(provider=provider, tools=make_code_tools(), surface=PrintSurface(), wv_bin="./scripts/wv")
    agent.run("list files in runtime/")

    assert provider.chat.called
    kwargs = provider.chat.call_args.kwargs
    assert "system" in kwargs and "Weave" in kwargs["system"]
    ok("Weave workflow rules injected into system prompt")
    messages = kwargs["messages"]
    assert any(m.role == "user" for m in messages)
    ok("user message added to conversation")
    ok("Agent ran single turn without error")
except Exception as e:
    fail("Agent single turn", e)

# ── 6. CLI entry point ────────────────────────────────────────────────────────
print("\nTest 6: CLI entry point (--help)")
try:
    r = subprocess.run(
        [sys.executable, "-m", "runtime", "--help"],
        capture_output=True, text=True,
        cwd=str(Path(__file__).parent.parent),
    )
    assert r.returncode == 0
    ok("python -m runtime --help exits 0")
    assert "task" in r.stdout and "model" in r.stdout
    ok("--help output includes 'task' and '--model'")
except Exception as e:
    fail("CLI --help", e)

# ── Results ───────────────────────────────────────────────────────────────────
print(f"\n{'=' * 40}")
print(f"Results: {PASS}/{PASS + FAIL} passed")
print("=" * 40)
if FAIL:
    print(f"✗ {FAIL} test(s) failed")
    sys.exit(1)
else:
    print("All Phase 1 tests passed")
