"""Tests for turn-efficiency interventions (SearchEfficiencyHook + R8 + environment block)."""

from __future__ import annotations

from pathlib import Path
from unittest.mock import patch

from runtime.context import _build_environment_block
from runtime.hooks import OpenNodeHook, SearchEfficiencyHook
from runtime.compliance import ToolEvent, _r8_search_efficiency


# ── SearchEfficiencyHook tests ───────────────────────────────────────────────


class TestSearchEfficiencyHook:
    """Verify SearchEfficiencyHook detects grep cascading and turn inflation."""

    def _make_hook(self) -> SearchEfficiencyHook:
        hook = SearchEfficiencyHook()
        hook.on_prompt("test task")
        return hook

    def test_no_feedback_on_first_grep(self) -> None:
        hook = self._make_hook()
        result = hook.after_tool("grep", {"path": "src/foo.py"}, "match found", False)
        assert result is None

    def test_no_feedback_on_second_grep_same_path(self) -> None:
        hook = self._make_hook()
        hook.after_tool("grep", {"path": "src/foo.py"}, "match", False)
        result = hook.after_tool("grep", {"path": "src/foo.py"}, "match", False)
        assert result is None

    def test_cascade_feedback_on_third_grep_same_path(self) -> None:
        hook = self._make_hook()
        for _ in range(2):
            hook.after_tool("grep", {"path": "src/foo.py"}, "match", False)
        result = hook.after_tool("grep", {"path": "src/foo.py"}, "match", False)
        assert result is not None
        assert "[efficiency]" in result
        assert "src/foo.py" in result
        assert "3 times" in result

    def test_different_paths_no_cascade(self) -> None:
        hook = self._make_hook()
        for i in range(5):
            result = hook.after_tool("grep", {"path": f"src/file{i}.py"}, "match", False)
        assert result is None

    def test_empty_streak_feedback(self) -> None:
        hook = self._make_hook()
        hook.after_tool("grep", {"path": "a.py"}, "", False)
        hook.after_tool("grep", {"path": "b.py"}, "", False)
        result = hook.after_tool("grep", {"path": "c.py"}, "", False)
        assert result is not None
        assert "empty searches" in result

    def test_empty_streak_resets_on_hit(self) -> None:
        hook = self._make_hook()
        hook.after_tool("grep", {"path": "a.py"}, "", False)
        hook.after_tool("grep", {"path": "b.py"}, "", False)
        hook.after_tool("grep", {"path": "c.py"}, "found", False)
        result = hook.after_tool("grep", {"path": "d.py"}, "", False)
        assert result is None

    def test_turn_budget_warning(self) -> None:
        hook = self._make_hook()
        result = None
        for turn in range(12):
            result = hook.after_tool("grep", {"path": f"f{turn}.py"}, "ok", False)
            hook._turn = turn
            hook._last_turn = turn - 1
        # Trigger with turn >= 10
        hook._turn = 9
        hook._last_turn = 8
        hook._budget_warned = False
        result = hook.after_tool("grep", {"path": "final.py", "_turn": 10}, "ok", False)
        assert result is not None
        assert "Turn 10" in result

    def test_turn_budget_warns_once(self) -> None:
        hook = self._make_hook()
        hook._turn = 10
        hook._budget_warned = False
        hook.after_tool("grep", {"path": "a.py", "_turn": 10}, "ok", False)
        result = hook.after_tool("grep", {"path": "b.py", "_turn": 11}, "ok", False)
        assert result is None  # already warned

    def test_non_search_tool_no_feedback(self) -> None:
        hook = self._make_hook()
        for _ in range(5):
            result = hook.after_tool("read", {"path": "src/foo.py"}, "content", False)
        assert result is None

    def test_on_prompt_resets_state(self) -> None:
        hook = self._make_hook()
        for _ in range(3):
            hook.after_tool("grep", {"path": "src/foo.py"}, "match", False)
        hook.on_prompt("new task")
        result = hook.after_tool("grep", {"path": "src/foo.py"}, "match", False)
        assert result is None

    def test_glob_tracked_as_search(self) -> None:
        hook = self._make_hook()
        for _ in range(2):
            hook.after_tool("glob", {"path": "src/"}, "match", False)
        result = hook.after_tool("glob", {"path": "src/"}, "match", False)
        assert result is not None
        assert "[efficiency]" in result

    def test_before_tool_noop(self) -> None:
        hook = self._make_hook()
        hook.before_tool("grep", {"path": "src/foo.py"})

    def test_before_answer_returns_none(self) -> None:
        hook = self._make_hook()
        assert hook.before_answer() is None

    def test_bash_grep_counted_as_search(self) -> None:
        hook = self._make_hook()
        for _ in range(2):
            hook.after_tool("bash", {"command": "grep -n 'foo' src/bar.py"}, "match", False)
        result = hook.after_tool("bash", {"command": "grep -rn 'baz' src/bar.py"}, "m", False)
        assert result is not None
        assert "[efficiency]" in result
        assert "src/bar.py" in result

    def test_bash_grep_prefer_tool_hint_at_3(self) -> None:
        hook = self._make_hook()
        for i in range(3):
            result = hook.after_tool("bash", {"command": f"grep 'x' file{i}.py"}, "ok", False)
        assert result is not None
        assert "Prefer the grep() and read() tools" in result

    def test_bash_ls_counted_as_search(self) -> None:
        hook = self._make_hook()
        for _ in range(3):
            hook.after_tool("bash", {"command": "ls tests/"}, "file.py", False)
        result = hook.after_tool("bash", {"command": "ls tests/"}, "file.py", False)
        assert result is not None
        assert "tests/" in result

    def test_bash_non_search_not_counted(self) -> None:
        hook = self._make_hook()
        for _ in range(5):
            result = hook.after_tool("bash", {"command": "python -m pytest test.py"}, "ok", False)
        assert result is None


# ── R8 compliance rule tests ─────────────────────────────────────────────────


def _make_event(turn: int, name: str, path: str = ".", result: str = "ok") -> ToolEvent:
    return ToolEvent(
        turn=turn,
        name=name,
        input={"path": path},
        result=result,
        is_error=False,
        is_enforcement_block=False,
    )


class TestR8SearchEfficiency:
    """Verify _r8_search_efficiency compliance rule."""

    def test_no_violation_under_threshold(self) -> None:
        events = [_make_event(i, "grep", "src/foo.py") for i in range(3)]
        violations = _r8_search_efficiency(events)
        assert len(violations) == 0

    def test_violation_at_four_greps_same_path(self) -> None:
        events = [_make_event(i, "grep", "src/foo.py") for i in range(4)]
        violations = _r8_search_efficiency(events)
        assert len(violations) == 1
        assert "R8" in violations[0].rule
        assert "src/foo.py" in violations[0].message

    def test_different_paths_no_violation(self) -> None:
        events = [_make_event(i, "grep", f"src/file{i}.py") for i in range(10)]
        violations = _r8_search_efficiency(events)
        assert len(violations) == 0

    def test_glob_counts_too(self) -> None:
        events = [_make_event(i, "glob", "src/") for i in range(4)]
        violations = _r8_search_efficiency(events)
        assert len(violations) == 1

    def test_error_events_excluded(self) -> None:
        events = []
        for i in range(5):
            ev = _make_event(i, "grep", "src/foo.py")
            ev.is_error = True
            events.append(ev)
        violations = _r8_search_efficiency(events)
        assert len(violations) == 0

    def test_non_search_tools_ignored(self) -> None:
        events = [_make_event(i, "read", "src/foo.py") for i in range(10)]
        violations = _r8_search_efficiency(events)
        assert len(violations) == 0

    def test_violation_fires_once_per_path(self) -> None:
        events = [_make_event(i, "grep", "src/foo.py") for i in range(8)]
        violations = _r8_search_efficiency(events)
        assert len(violations) == 1  # fires at count==4, not again

    def test_violation_severity_is_warning(self) -> None:
        events = [_make_event(i, "grep", "src/foo.py") for i in range(4)]
        violations = _r8_search_efficiency(events)
        assert violations[0].severity == "warning"

    def test_bash_grep_counted_in_r8(self) -> None:
        events = [
            ToolEvent(turn=i, name="bash",
                      input={"command": f"grep -n 'pattern{i}' src/foo.py"},
                      result="match", is_error=False, is_enforcement_block=False)
            for i in range(4)
        ]
        violations = _r8_search_efficiency(events)
        assert len(violations) == 1
        assert "src/foo.py" in violations[0].message

    def test_bash_grep_mixed_with_grep_tool(self) -> None:
        events = [
            _make_event(0, "grep", "src/foo.py"),
            _make_event(1, "grep", "src/foo.py"),
            ToolEvent(turn=2, name="bash",
                      input={"command": "grep -rn 'x' src/foo.py"},
                      result="match", is_error=False, is_enforcement_block=False),
            ToolEvent(turn=3, name="bash",
                      input={"command": "grep -n 'y' src/foo.py"},
                      result="match", is_error=False, is_enforcement_block=False),
        ]
        violations = _r8_search_efficiency(events)
        assert len(violations) == 1

    def test_bash_non_search_ignored_in_r8(self) -> None:
        events = [
            ToolEvent(turn=i, name="bash",
                      input={"command": "python -m pytest tests/"},
                      result="ok", is_error=False, is_enforcement_block=False)
            for i in range(10)
        ]
        violations = _r8_search_efficiency(events)
        assert len(violations) == 0


# ── Environment block tests ──────────────────────────────────────────────────


class TestEnvironmentBlock:
    """Verify _build_environment_block injects CWD and hints."""

    def test_contains_working_directory(self, tmp_path: Path) -> None:
        block = _build_environment_block(tmp_path)
        assert "<environment>" in block
        assert str(tmp_path) in block

    def test_contains_no_cd_hint(self, tmp_path: Path) -> None:
        block = _build_environment_block(tmp_path)
        assert "Do not cd" in block

    def test_contains_pytest_hint(self, tmp_path: Path) -> None:
        block = _build_environment_block(tmp_path)
        assert "python -m pytest" in block

    def test_contains_git_hint(self, tmp_path: Path) -> None:
        block = _build_environment_block(tmp_path)
        assert "git add/commit/push" in block

    def test_git_branch_included_in_repo(self) -> None:
        """In the actual repo, git branch should be present."""
        repo = Path(__file__).resolve().parent.parent
        block = _build_environment_block(repo)
        assert "Git branch:" in block

    def test_git_branch_missing_outside_repo(self, tmp_path: Path) -> None:
        block = _build_environment_block(tmp_path)
        assert "Git branch:" not in block

    def test_handles_subprocess_failure(self, tmp_path: Path) -> None:
        with patch("runtime.context.subprocess.run", side_effect=FileNotFoundError):
            block = _build_environment_block(tmp_path)
        assert "<environment>" in block
        assert str(tmp_path) in block


# ── OpenNodeHook tests ───────────────────────────────────────────────────────


class TestOpenNodeHook:
    """Verify OpenNodeHook redirects when a claimed node is not closed."""

    def _make_hook(self) -> OpenNodeHook:
        hook = OpenNodeHook()
        hook.on_prompt("test task")
        return hook

    def test_no_redirect_when_no_nodes_claimed(self) -> None:
        hook = self._make_hook()
        assert hook.before_answer() is None

    def test_redirect_fires_when_node_open(self) -> None:
        hook = self._make_hook()
        hook.before_tool("wv_work", {"node_id": "wv-abcd"})
        msg = hook.before_answer()
        assert msg is not None
        assert "wv-abcd" in msg

    def test_redirect_is_one_shot(self) -> None:
        hook = self._make_hook()
        hook.before_tool("wv_work", {"node_id": "wv-abcd"})
        first = hook.before_answer()
        second = hook.before_answer()
        assert first is not None
        assert second is None  # one-shot prevents infinite loops

    def test_redirect_rearms_after_additional_tool_activity(self) -> None:
        hook = self._make_hook()
        hook.before_tool("wv_work", {"node_id": "wv-abcd"})
        first = hook.before_answer()
        hook.before_tool("read", {"path": "runtime/agent.py"})
        second = hook.before_answer()
        assert first is not None
        assert second is not None
        assert "wv-abcd" in second

    def test_no_redirect_after_wv_done(self) -> None:
        hook = self._make_hook()
        hook.before_tool("wv_work", {"node_id": "wv-abcd"})
        hook.after_tool("wv_done", {"node_id": "wv-abcd"}, "done", False)
        assert hook.before_answer() is None

    def test_wv_batch_done_clears_nodes(self) -> None:
        hook = self._make_hook()
        hook.before_tool("wv_work", {"node_id": "wv-aaaa"})
        hook.before_tool("wv_work", {"node_id": "wv-bbbb"})
        hook.after_tool("wv_batch_done", {"ids": ["wv-aaaa", "wv-bbbb"]}, "done", False)
        assert hook.before_answer() is None

    def test_errored_wv_work_still_tracked(self) -> None:
        # before_tool fires before we know if the tool errored;
        # track the claim even on error — safer than missing an open node
        hook = self._make_hook()
        hook.before_tool("wv_work", {"node_id": "wv-abcd"})
        # simulate tool error: after_tool with is_error=True, wv_done not called
        hook.after_tool("wv_work", {"node_id": "wv-abcd"}, "", True)
        msg = hook.before_answer()
        assert msg is not None
        assert "wv-abcd" in msg

    def test_errored_wv_done_leaves_node_open(self) -> None:
        hook = self._make_hook()
        hook.before_tool("wv_work", {"node_id": "wv-abcd"})
        hook.after_tool("wv_done", {"node_id": "wv-abcd"}, "", True)  # error
        msg = hook.before_answer()
        assert msg is not None  # node should still be considered open

    def test_seed_active_nodes_fires_redirect_for_continuation_session(self) -> None:
        # Simulate a node claimed in a previous session — seed without wv_work
        hook = self._make_hook()
        hook.seed_active_nodes(["wv-prev1", "wv-prev2"])
        msg = hook.before_answer()
        assert msg is not None
        assert "wv-prev1" in msg

    def test_seed_active_nodes_does_not_duplicate(self) -> None:
        hook = self._make_hook()
        hook.seed_active_nodes(["wv-abcd"])
        hook.before_tool("wv_work", {"node_id": "wv-abcd"})  # same node via wv_work
        assert len(hook._claimed) == 1  # no duplicate entry

    def test_seed_active_nodes_cleared_by_wv_done(self) -> None:
        hook = self._make_hook()
        hook.seed_active_nodes(["wv-abcd"])
        hook.after_tool("wv_done", {"node_id": "wv-abcd"}, "done", False)
        assert hook.before_answer() is None
