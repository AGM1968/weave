"""Tests for LintAfterEditMiddleware and SearchEfficiencyMiddleware.

Mirrors the hook-based tests in test_runtime_efficiency.py but exercises
the middleware protocol surface (on_tool_result, before_query, snapshot).
"""
from __future__ import annotations

from unittest.mock import patch

from runtime.middleware.base import MiddlewareContext, MiddlewareStack
from runtime.middleware.lint import LintAfterEditMiddleware
from runtime.middleware.search_efficiency import SearchEfficiencyMiddleware
from runtime.types import ToolCall, ToolResult


def _ctx() -> MiddlewareContext:
    return MiddlewareContext(messages=[], turn_number=0)


def _tc(name: str, inp: dict | None = None) -> ToolCall:
    return ToolCall(id="tc-1", name=name, input=inp or {})


def _result(content: str = "ok", *, is_error: bool = False) -> ToolResult:
    return ToolResult(id="tc-1", content=content, is_error=is_error)


# ── LintAfterEditMiddleware ──────────────────────────────────────────────────


class TestLintAfterEditMiddleware:
    """Verify lint middleware fires on write/edit for .py files only."""

    def test_non_write_tool_no_feedback(self) -> None:
        mw = LintAfterEditMiddleware()
        fb = mw.on_tool_result(_ctx(), _tc("grep", {"path": "src/foo.py"}), _result())
        assert fb is None

    def test_non_python_file_no_feedback(self) -> None:
        mw = LintAfterEditMiddleware()
        fb = mw.on_tool_result(_ctx(), _tc("write", {"path": "src/foo.rs"}), _result())
        assert fb is None

    def test_error_result_no_feedback(self) -> None:
        mw = LintAfterEditMiddleware()
        fb = mw.on_tool_result(
            _ctx(), _tc("edit", {"path": "src/foo.py"}), _result(is_error=True),
        )
        assert fb is None

    def test_lint_clean_no_feedback(self) -> None:
        mw = LintAfterEditMiddleware()
        mock_proc = type("P", (), {"stdout": "All checks passed\n", "returncode": 0})()
        with patch("runtime.middleware.lint.subprocess.run", return_value=mock_proc):
            fb = mw.on_tool_result(_ctx(), _tc("write", {"path": "src/foo.py"}), _result())
        assert fb is None

    def test_lint_issues_returned(self) -> None:
        mw = LintAfterEditMiddleware()
        mock_proc = type("P", (), {"stdout": "src/foo.py:10: E501 line too long\n", "returncode": 1})()
        with patch("runtime.middleware.lint.subprocess.run", return_value=mock_proc):
            fb = mw.on_tool_result(_ctx(), _tc("edit", {"path": "src/foo.py"}), _result())
        assert fb is not None
        assert "Lint issues" in fb
        assert "E501" in fb

    def test_ruff_fallback_when_make_unavailable(self) -> None:
        mw = LintAfterEditMiddleware()
        ruff_proc = type("P", (), {"stdout": "src/foo.py:5: W291\n", "returncode": 1})()

        def side_effect(cmd, **_kwargs):
            if cmd[0] == "make":
                raise FileNotFoundError
            return ruff_proc

        with patch("runtime.middleware.lint.subprocess.run", side_effect=side_effect):
            fb = mw.on_tool_result(_ctx(), _tc("write", {"path": "src/foo.py"}), _result())
        assert fb is not None
        assert "W291" in fb

    def test_stack_integration(self) -> None:
        """Lint middleware works through the MiddlewareStack."""
        mw = LintAfterEditMiddleware()
        stack = MiddlewareStack()
        stack.add(mw)
        mock_proc = type("P", (), {"stdout": "src/f.py:1: E302\n", "returncode": 1})()
        with patch("runtime.middleware.lint.subprocess.run", return_value=mock_proc):
            feedbacks = stack.run_on_tool_result(
                _ctx(), _tc("edit", {"path": "src/f.py"}), _result(),
            )
        assert len(feedbacks) == 1
        assert "E302" in feedbacks[0]


# ── SearchEfficiencyMiddleware ───────────────────────────────────────────────


class TestSearchEfficiencyMiddleware:
    """Verify SearchEfficiencyMiddleware detects inefficiencies via on_tool_result."""

    def _make_mw(self) -> SearchEfficiencyMiddleware:
        mw = SearchEfficiencyMiddleware()
        mw.before_query(_ctx())
        return mw

    def test_no_feedback_on_first_grep(self) -> None:
        mw = self._make_mw()
        fb = mw.on_tool_result(_ctx(), _tc("grep", {"path": "src/foo.py"}), _result())
        assert fb is None

    def test_no_feedback_on_second_grep_same_path(self) -> None:
        mw = self._make_mw()
        mw.on_tool_result(_ctx(), _tc("grep", {"path": "src/foo.py"}), _result())
        fb = mw.on_tool_result(_ctx(), _tc("grep", {"path": "src/foo.py"}), _result())
        assert fb is None

    def test_cascade_feedback_on_third_grep_same_path(self) -> None:
        mw = self._make_mw()
        for _ in range(2):
            mw.on_tool_result(_ctx(), _tc("grep", {"path": "src/foo.py"}), _result())
        fb = mw.on_tool_result(_ctx(), _tc("grep", {"path": "src/foo.py"}), _result())
        assert fb is not None
        assert "[efficiency]" in fb
        assert "src/foo.py" in fb
        assert "3 times" in fb

    def test_different_paths_no_cascade(self) -> None:
        mw = self._make_mw()
        fb = None
        for i in range(5):
            fb = mw.on_tool_result(_ctx(), _tc("grep", {"path": f"src/file{i}.py"}), _result())
        assert fb is None

    def test_empty_streak_feedback(self) -> None:
        mw = self._make_mw()
        mw.on_tool_result(_ctx(), _tc("grep", {"path": "a.py"}), _result(""))
        mw.on_tool_result(_ctx(), _tc("grep", {"path": "b.py"}), _result(""))
        fb = mw.on_tool_result(_ctx(), _tc("grep", {"path": "c.py"}), _result(""))
        assert fb is not None
        assert "empty searches" in fb

    def test_empty_streak_resets_on_hit(self) -> None:
        mw = self._make_mw()
        mw.on_tool_result(_ctx(), _tc("grep", {"path": "a.py"}), _result(""))
        mw.on_tool_result(_ctx(), _tc("grep", {"path": "b.py"}), _result(""))
        mw.on_tool_result(_ctx(), _tc("grep", {"path": "c.py"}), _result("found"))
        fb = mw.on_tool_result(_ctx(), _tc("grep", {"path": "d.py"}), _result(""))
        assert fb is None

    def test_turn_budget_warning(self) -> None:
        mw = self._make_mw()
        mw._turn = 9
        mw._last_turn = 8
        mw._budget_warned = False
        fb = mw.on_tool_result(
            _ctx(), _tc("grep", {"path": "final.py", "_turn": 10}), _result(),
        )
        assert fb is not None
        assert "Turn 10" in fb

    def test_turn_budget_warns_once(self) -> None:
        mw = self._make_mw()
        mw._turn = 10
        mw._budget_warned = False
        mw.on_tool_result(_ctx(), _tc("grep", {"path": "a.py", "_turn": 10}), _result())
        fb = mw.on_tool_result(_ctx(), _tc("grep", {"path": "b.py", "_turn": 11}), _result())
        assert fb is None

    def test_non_search_tool_no_feedback(self) -> None:
        mw = self._make_mw()
        for _ in range(5):
            fb = mw.on_tool_result(_ctx(), _tc("read", {"path": "src/foo.py"}), _result())
        assert fb is None

    def test_before_query_resets_state(self) -> None:
        mw = self._make_mw()
        for _ in range(3):
            mw.on_tool_result(_ctx(), _tc("grep", {"path": "src/foo.py"}), _result())
        mw.before_query(_ctx())
        fb = mw.on_tool_result(_ctx(), _tc("grep", {"path": "src/foo.py"}), _result())
        assert fb is None

    def test_glob_tracked_as_search(self) -> None:
        mw = self._make_mw()
        for _ in range(2):
            mw.on_tool_result(_ctx(), _tc("glob", {"path": "src/"}), _result())
        fb = mw.on_tool_result(_ctx(), _tc("glob", {"path": "src/"}), _result())
        assert fb is not None
        assert "[efficiency]" in fb

    def test_bash_grep_counted_as_search(self) -> None:
        mw = self._make_mw()
        for _ in range(2):
            mw.on_tool_result(
                _ctx(), _tc("bash", {"command": "grep -n 'foo' src/bar.py"}), _result(),
            )
        fb = mw.on_tool_result(
            _ctx(), _tc("bash", {"command": "grep -rn 'baz' src/bar.py"}), _result(),
        )
        assert fb is not None
        assert "[efficiency]" in fb
        assert "src/bar.py" in fb

    def test_bash_grep_prefer_tool_hint_at_3(self) -> None:
        mw = self._make_mw()
        fb = None
        for i in range(3):
            fb = mw.on_tool_result(
                _ctx(), _tc("bash", {"command": f"grep 'x' file{i}.py"}), _result(),
            )
        assert fb is not None
        assert "Prefer the grep() and read() tools" in fb

    def test_bash_non_search_not_counted(self) -> None:
        mw = self._make_mw()
        for _ in range(5):
            fb = mw.on_tool_result(
                _ctx(), _tc("bash", {"command": "python -m pytest test.py"}), _result(),
            )
        assert fb is None

    def test_snapshot_clean_state(self) -> None:
        mw = self._make_mw()
        snap = mw.snapshot()
        assert snap.turn == 0
        assert snap.empty_streak == 0
        assert snap.bash_search_count == 0
        assert snap.is_thrashing is False
        assert snap.cascade_paths == {}

    def test_snapshot_reflects_activity(self) -> None:
        mw = self._make_mw()
        for _ in range(3):
            mw.on_tool_result(_ctx(), _tc("grep", {"path": "src/foo.py"}), _result())
        snap = mw.snapshot()
        assert snap.cascade_paths["src/foo.py"] == 3
        assert snap.is_thrashing is True

    def test_stack_integration(self) -> None:
        """SearchEfficiency works through MiddlewareStack."""
        mw = self._make_mw()
        stack = MiddlewareStack()
        stack.add(mw)
        for _ in range(3):
            stack.run_on_tool_result(
                _ctx(), _tc("grep", {"path": "src/x.py"}), _result(),
            )
        feedbacks = stack.run_on_tool_result(
            _ctx(), _tc("grep", {"path": "src/x.py"}), _result(),
        )
        assert len(feedbacks) == 1
        assert "4 times" in feedbacks[0]
