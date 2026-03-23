"""Security regression tests for runtime/tools/code.py Sprint 1 fixes.

Covers:
  C1 — Shell injection: bash tool with shell=True → shlex.split()+shell=False
  C2 — Path traversal: all 6 file tools reject paths outside workspace
  C3 — ReDoS: grep returns error within 5s on catastrophic backtracking pattern

Run: poetry run pytest tests/test_runtime_security.py -v
"""
from __future__ import annotations

import sys
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent.parent))

from runtime.tools.base import ToolRegistry
from runtime.tools.code import make_code_tools
from runtime.types import ToolCall


# ── Fixtures ──────────────────────────────────────────────────────────────────

@pytest.fixture(scope="module")
def reg() -> ToolRegistry:
    return ToolRegistry(make_code_tools())


def call(reg: ToolRegistry, name: str, **kwargs: object) -> str:
    result = reg.execute(ToolCall(id="t", name=name, input=dict(kwargs)))
    return result.content


# ── C1 — Shell injection ──────────────────────────────────────────────────────

MARKER = Path("/tmp/_wv_security_test_marker")


@pytest.fixture(autouse=True)
def cleanup_marker():
    MARKER.unlink(missing_ok=True)
    yield
    MARKER.unlink(missing_ok=True)


class TestBashInjection:
    """Semicolon / pipe / && payloads must NOT execute a second command."""

    def test_semicolon_injection(self, reg: ToolRegistry) -> None:
        call(reg, "bash", command=f"echo hello; touch {MARKER}")
        assert not MARKER.exists(), "semicolon allowed second command to execute"

    def test_ampersand_injection(self, reg: ToolRegistry) -> None:
        call(reg, "bash", command=f"echo hello && touch {MARKER}")
        assert not MARKER.exists(), "&& allowed second command to execute"

    def test_pipe_injection(self, reg: ToolRegistry) -> None:
        # pipe becomes literal argv token — touch receives it as filename arg
        call(reg, "bash", command=f"echo x | touch {MARKER}")
        assert not MARKER.exists(), "pipe allowed second command to execute"

    def test_backtick_injection(self, reg: ToolRegistry) -> None:
        # backtick is a literal char in argv, not shell expansion
        call(reg, "bash", command=f"echo `touch {MARKER}`")
        assert not MARKER.exists(), "backtick caused command substitution"

    def test_dollar_injection(self, reg: ToolRegistry) -> None:
        # $(...) is literal in argv without shell=True
        call(reg, "bash", command=f"echo $(touch {MARKER})")
        assert not MARKER.exists(), "$() caused command substitution"

    def test_empty_command_returns_error(self, reg: ToolRegistry) -> None:
        out = call(reg, "bash", command="")
        assert out.startswith("Error:"), f"empty command should error, got: {out!r}"

    def test_legitimate_command_still_works(self, reg: ToolRegistry) -> None:
        out = call(reg, "bash", command="echo hello")
        assert "hello" in out, f"legitimate command failed: {out!r}"


# ── C2 — Path traversal ───────────────────────────────────────────────────────

OUTSIDE_PATHS = [
    "/etc/passwd",
    "/tmp/evil_traversal_test.txt",
    "/root/.ssh/id_rsa",
]

TRAVERSAL_PATHS = [
    "../../../etc/passwd",
    "../../../../../../etc/shadow",
]


class TestPathTraversal:
    """All 6 file tools must reject paths outside the workspace."""

    @pytest.mark.parametrize("path", OUTSIDE_PATHS + TRAVERSAL_PATHS)
    def test_read_blocks_outside(self, reg: ToolRegistry, path: str) -> None:
        out = call(reg, "read", path=path)
        assert out.startswith("Error:"), f"read allowed outside path {path!r}: {out!r}"

    @pytest.mark.parametrize("path", OUTSIDE_PATHS)
    def test_write_blocks_outside(self, reg: ToolRegistry, path: str) -> None:
        out = call(reg, "write", path=path, content="pwned")
        assert out.startswith("Error:"), f"write allowed outside path {path!r}: {out!r}"

    @pytest.mark.parametrize("path", OUTSIDE_PATHS + TRAVERSAL_PATHS)
    def test_edit_blocks_outside(self, reg: ToolRegistry, path: str) -> None:
        out = call(reg, "edit", path=path, old_string="x", new_string="y")
        assert out.startswith("Error:"), f"edit allowed outside path {path!r}: {out!r}"

    @pytest.mark.parametrize("path", ["/etc", "/tmp", "/root"])
    def test_glob_blocks_outside(self, reg: ToolRegistry, path: str) -> None:
        out = call(reg, "glob", pattern="*", path=path)
        assert out.startswith("Error:"), f"glob allowed outside path {path!r}: {out!r}"

    @pytest.mark.parametrize("path", ["/etc", "/tmp"])
    def test_grep_blocks_outside(self, reg: ToolRegistry, path: str) -> None:
        out = call(reg, "grep", pattern="root", path=path)
        assert out.startswith("Error:"), f"grep allowed outside path {path!r}: {out!r}"

    @pytest.mark.parametrize("path", ["/etc", "/tmp", "/root"])
    def test_ls_blocks_outside(self, reg: ToolRegistry, path: str) -> None:
        out = call(reg, "ls", path=path)
        assert out.startswith("Error:"), f"ls allowed outside path {path!r}: {out!r}"

    def test_workspace_read_allowed(self, reg: ToolRegistry) -> None:
        """Legitimate workspace reads must still work."""
        out = call(reg, "read", path="runtime/__init__.py")
        assert not out.startswith("Error:"), f"workspace read blocked: {out!r}"

    def test_workspace_ls_allowed(self, reg: ToolRegistry) -> None:
        out = call(reg, "ls", path="runtime")
        assert not out.startswith("Error:"), f"workspace ls blocked: {out!r}"

    def test_workspace_glob_allowed(self, reg: ToolRegistry) -> None:
        out = call(reg, "glob", pattern="*.py", path="runtime")
        assert not out.startswith("Error:"), f"workspace glob blocked: {out!r}"


# ── C3 — Regex DoS ────────────────────────────────────────────────────────────

class TestReDoS:
    """Catastrophic backtracking must return an error within the 5s timeout."""

    REDOS_PATTERN = r"(a+)+\$"   # exponential on 'aaa...b'

    def test_redos_returns_error(self, reg: ToolRegistry) -> None:
        """ReDoS pattern against 60 'a's must error, not hang."""
        workspace_bait = Path("runtime/_redos_bait.txt")
        workspace_bait.write_text("a" * 60 + "b")
        try:
            out = call(reg, "grep", pattern=self.REDOS_PATTERN,
                       path="runtime", glob="_redos_bait.txt")
        finally:
            workspace_bait.unlink(missing_ok=True)

        assert out.startswith("Error:"), f"ReDoS grep should error, got: {out!r}"
        assert "timed out" in out.lower(), f"error should mention timeout: {out!r}"

    def test_redos_respects_timeout(self, reg: ToolRegistry) -> None:
        """The timeout must fire within 6s (5s limit + 1s headroom)."""
        workspace_bait = Path("runtime/_redos_bait2.txt")
        workspace_bait.write_text("a" * 60 + "b")
        try:
            t0 = time.monotonic()
            call(reg, "grep", pattern=self.REDOS_PATTERN,
                 path="runtime", glob="_redos_bait2.txt")
            elapsed = time.monotonic() - t0
        finally:
            workspace_bait.unlink(missing_ok=True)

        assert elapsed < 6.5, f"grep took {elapsed:.1f}s — timeout did not fire"

    def test_normal_grep_still_works(self, reg: ToolRegistry) -> None:
        """A safe pattern on real files must return results, not time out."""
        out = call(reg, "grep", pattern=r"def \w+", path="runtime", glob="*.py")
        assert not out.startswith("Error:"), f"normal grep errored: {out!r}"
        assert "(no matches)" not in out, "expected function definitions in runtime/*.py"
