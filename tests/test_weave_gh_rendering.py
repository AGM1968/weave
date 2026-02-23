"""Tests for weave_gh.rendering — body rendering, Mermaid graphs, close comments."""

from __future__ import annotations

from typing import Any
from unittest.mock import patch


from weave_gh.models import Edge, WeaveNode
from weave_gh.rendering import (
    MERMAID_NODE_THRESHOLD,
    _mermaid_id,
    _mermaid_label,
    build_close_comment,
    content_hash,
    render_issue_body,
    render_mermaid_graph,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _node(
    id: str = "abc123",
    text: str = "Test node",
    status: str = "todo",
    alias: str | None = None,
    **meta: object,
) -> WeaveNode:
    return WeaveNode(id=id, text=text, status=status, metadata=dict(meta), alias=alias)


# ---------------------------------------------------------------------------
# content_hash
# ---------------------------------------------------------------------------


class TestContentHash:
    def test_deterministic(self) -> None:
        assert content_hash("hello") == content_hash("hello")

    def test_different_inputs(self) -> None:
        assert content_hash("a") != content_hash("b")

    def test_length(self) -> None:
        assert len(content_hash("any string")) == 12

    def test_hex_chars(self) -> None:
        h = content_hash("test")
        assert all(c in "0123456789abcdef" for c in h)


# ---------------------------------------------------------------------------
# Mermaid helpers
# ---------------------------------------------------------------------------


class TestMermaidId:
    def test_replaces_hyphens(self) -> None:
        assert _mermaid_id("abc-def-123") == "abc_def_123"

    def test_no_hyphens_unchanged(self) -> None:
        assert _mermaid_id("abc123") == "abc123"


class TestMermaidLabel:
    def test_truncates_long_text(self) -> None:
        long_text = "x" * 100
        result = _mermaid_label(long_text)
        # 60 chars + 2 for quotes
        assert len(result) == 62

    def test_escapes_brackets(self) -> None:
        result = _mermaid_label("array[0]")
        assert "[" not in result
        assert "]" not in result
        assert "(0)" in result

    def test_escapes_quotes(self) -> None:
        result = _mermaid_label('say "hello"')
        assert '"' not in result.strip('"')  # outer quotes are fine

    def test_wraps_in_quotes(self) -> None:
        result = _mermaid_label("simple")
        assert result.startswith('"')
        assert result.endswith('"')


# ---------------------------------------------------------------------------
# render_mermaid_graph
# ---------------------------------------------------------------------------


class TestRenderMermaidGraph:
    def test_empty_children(self) -> None:
        parent = _node(id="p1", text="Epic")
        assert render_mermaid_graph(parent, [], {}, []) == ""

    def test_basic_graph(self) -> None:
        parent = _node(id="p1", text="Epic", type="epic")
        c1 = _node(id="c1", text="Task 1", status="todo")
        c2 = _node(id="c2", text="Task 2", status="done")
        nodes = {"p1": parent, "c1": c1, "c2": c2}

        result = render_mermaid_graph(parent, ["c1", "c2"], nodes, [])
        assert "graph TD" in result
        assert "p1" in result
        assert "c1" in result
        assert "c2" in result
        assert ":::done" in result
        assert ":::todo" in result

    def test_blocking_edges(self) -> None:
        parent = _node(id="p1", text="Epic", type="epic")
        c1 = _node(id="c1", text="Task 1")
        c2 = _node(id="c2", text="Task 2")
        nodes = {"p1": parent, "c1": c1, "c2": c2}
        edges = [Edge(source="c1", target="c2", edge_type="blocks")]

        result = render_mermaid_graph(parent, ["c1", "c2"], nodes, edges)
        assert "blocks" in result
        assert "c1" in result.split("blocks")[0]  # c1 on left of blocks

    def test_active_status_styling(self) -> None:
        parent = _node(id="p1", text="Epic")
        c1 = _node(id="c1", text="Active task", status="active")
        nodes = {"p1": parent, "c1": c1}

        result = render_mermaid_graph(parent, ["c1"], nodes, [])
        assert ":::active" in result

    def test_threshold_filtering(self) -> None:
        """When > threshold children, only non-done are shown."""
        parent = _node(id="p1", text="Big Epic")
        nodes = {"p1": parent}
        child_ids = []

        # Create threshold + 5 children, all done except 2
        for i in range(MERMAID_NODE_THRESHOLD + 5):
            cid = f"c{i}"
            status = "todo" if i < 2 else "done"
            nodes[cid] = _node(id=cid, text=f"Task {i}", status=status)
            child_ids.append(cid)

        result = render_mermaid_graph(parent, child_ids, nodes, [])
        # Only the 2 non-done children should appear
        assert "c0" in result
        assert "c1" in result
        # Done children should be filtered out
        assert "c5" not in result

    def test_all_done_keeps_full_graph(self) -> None:
        """When > threshold and all done, keep full graph (not a summary stub)."""
        parent = _node(id="p1", text="Done Epic")
        nodes = {"p1": parent}
        child_ids = []
        for i in range(MERMAID_NODE_THRESHOLD + 1):
            cid = f"c{i}"
            nodes[cid] = _node(id=cid, text=f"Task {i}", status="done")
            child_ids.append(cid)

        result = render_mermaid_graph(parent, child_ids, nodes, [])
        assert ":::done" in result
        assert "classDef done" in result
        # All children should be present in the full graph
        for i in range(MERMAID_NODE_THRESHOLD + 1):
            assert f"c{i}" in result

    def test_unresolved_children_skipped(self) -> None:
        parent = _node(id="p1", text="Epic")
        nodes = {"p1": parent}
        # Child IDs that don't exist in nodes_by_id
        result = render_mermaid_graph(parent, ["missing1", "missing2"], nodes, [])
        assert result == ""

    def test_alias_in_labels(self) -> None:
        parent = _node(id="p1", text="Epic with long name", alias="my-epic")
        c1 = _node(
            id="c1", text="Very long child task name", status="todo", alias="child-1"
        )
        c2 = _node(id="c2", text="Another child task", status="done")
        nodes = {"p1": parent, "c1": c1, "c2": c2}
        result = render_mermaid_graph(parent, ["c1", "c2"], nodes, [])
        assert '"my-epic"' in result  # Parent uses alias
        assert '"child-1"' in result  # Child with alias
        assert '"Another child task"' in result  # Child without alias uses text


# ---------------------------------------------------------------------------
# render_issue_body (requires mocking data.py functions)
# ---------------------------------------------------------------------------


class TestRenderIssueBody:
    @patch("weave_gh.rendering.get_children", return_value=[])
    @patch("weave_gh.rendering.get_blockers", return_value=[])
    @patch("weave_gh.rendering.get_parent", return_value=None)
    def test_basic_body(
        self, mock_parent: Any, mock_blockers: Any, mock_children: Any
    ) -> None:
        node = _node(id="abc123", text="Test task", type="task", priority=2)
        nodes = {"abc123": node}
        edges: list[Edge] = []

        body = render_issue_body(node, nodes, edges)
        assert "WEAVE:BEGIN" in body
        assert "WEAVE:END" in body
        assert "abc123" in body
        assert "Task" in body
        assert "P2" in body

    @patch("weave_gh.rendering.get_children", return_value=[])
    @patch("weave_gh.rendering.get_blockers", return_value=[])
    @patch("weave_gh.rendering.get_parent", return_value=None)
    def test_with_alias(
        self, mock_parent: Any, mock_blockers: Any, mock_children: Any
    ) -> None:
        node = _node(id="a1", text="Long task name", alias="short-name", type="task")
        body = render_issue_body(node, {"a1": node}, [])
        assert "**Alias:** `short-name`" in body

    @patch("weave_gh.rendering.get_children", return_value=[])
    @patch("weave_gh.rendering.get_blockers", return_value=[])
    @patch("weave_gh.rendering.get_parent", return_value=None)
    def test_without_alias(
        self, mock_parent: Any, mock_blockers: Any, mock_children: Any
    ) -> None:
        node = _node(id="a2", text="Task without alias")
        body = render_issue_body(node, {"a2": node}, [])
        assert "Alias" not in body

    @patch("weave_gh.rendering.get_children", return_value=[])
    @patch("weave_gh.rendering.get_blockers", return_value=[])
    @patch("weave_gh.rendering.get_parent", return_value="parent1")
    def test_with_parent(
        self, mock_parent: Any, mock_blockers: Any, mock_children: Any
    ) -> None:
        node = _node(id="c1", text="Child task")
        parent = _node(id="parent1", text="Parent epic", gh_issue=10)
        nodes = {"c1": node, "parent1": parent}

        body = render_issue_body(node, nodes, [])
        assert "Part of" in body
        assert "#10" in body

    @patch("weave_gh.rendering.get_children", return_value=[])
    @patch("weave_gh.rendering.get_blockers", return_value=["b1"])
    @patch("weave_gh.rendering.get_parent", return_value=None)
    def test_with_blockers(
        self, mock_parent: Any, mock_blockers: Any, mock_children: Any
    ) -> None:
        node = _node(id="n1", text="Blocked task")
        blocker = _node(id="b1", text="Dependency", gh_issue=5)
        nodes = {"n1": node, "b1": blocker}

        body = render_issue_body(node, nodes, [])
        assert "Blocked by" in body
        assert "#5" in body

    @patch("weave_gh.rendering.get_children", return_value=[])
    @patch("weave_gh.rendering.get_blockers", return_value=[])
    @patch("weave_gh.rendering.get_parent", return_value=None)
    def test_with_description(
        self, mock_parent: Any, mock_blockers: Any, mock_children: Any
    ) -> None:
        node = _node(id="n1", text="Task", description="Build the widget")
        nodes = {"n1": node}

        body = render_issue_body(node, nodes, [])
        assert "## Goal" in body
        assert "Build the widget" in body

    @patch("weave_gh.rendering.get_children", return_value=["c1", "c2"])
    @patch("weave_gh.rendering.get_blockers", return_value=[])
    @patch("weave_gh.rendering.get_parent", return_value=None)
    def test_with_children_checkboxes(
        self, mock_parent: Any, mock_blockers: Any, mock_children: Any
    ) -> None:
        parent = _node(id="ep1", text="Epic", type="epic")
        c1 = _node(id="c1", text="Task 1", status="done")
        c2 = _node(id="c2", text="Task 2", status="todo")
        nodes = {"ep1": parent, "c1": c1, "c2": c2}

        body = render_issue_body(parent, nodes, [])
        assert "## Tasks" in body
        assert "[x] Task 1" in body
        assert "[ ] Task 2" in body

    @patch("weave_gh.rendering.get_children", return_value=["c1"])
    @patch("weave_gh.rendering.get_blockers", return_value=[])
    @patch("weave_gh.rendering.get_parent", return_value=None)
    def test_with_children_renders_mermaid_for_task_parent(
        self, mock_parent: Any, mock_blockers: Any, mock_children: Any
    ) -> None:
        parent = _node(id="t1", text="Task parent")
        child = _node(id="c1", text="Task child", status="todo")
        nodes = {"t1": parent, "c1": child}

        body = render_issue_body(parent, nodes, [])
        assert "## Dependency Graph" in body
        assert "```mermaid" in body

    @patch("weave_gh.rendering.get_children", return_value=[])
    @patch("weave_gh.rendering.get_blockers", return_value=[])
    @patch("weave_gh.rendering.get_parent", return_value=None)
    def test_content_hash_in_markers(
        self, mock_parent: Any, mock_blockers: Any, mock_children: Any
    ) -> None:
        node = _node(id="n1", text="Task")
        nodes = {"n1": node}

        body = render_issue_body(node, nodes, [])
        # Hash should be in the BEGIN marker
        assert "hash=" in body
        # Hash should be 12 hex chars
        import re

        m = re.search(r"hash=([a-f0-9]+)", body)
        assert m is not None
        assert len(m.group(1)) == 12


# ---------------------------------------------------------------------------
# build_close_comment
# ---------------------------------------------------------------------------


class TestBuildCloseComment:
    def test_basic_close(self) -> None:
        node = _node(id="n1", text="Done task", status="done")
        comment = build_close_comment(node)
        assert "Completed" in comment
        assert "n1" in comment

    def test_with_learnings(self) -> None:
        node = _node(
            id="n1",
            text="Task",
            status="done",
            decision="Use REST",
            pitfall="Auth was tricky",
        )
        comment = build_close_comment(node)
        assert "Learnings" in comment
        assert "Decision" in comment
        assert "Use REST" in comment
        assert "Pitfall" in comment

    @patch(
        "weave_gh.rendering.build_commit_links",
        return_value="\n**Commits:**\n- `abc1234` fix stuff",
    )
    def test_with_commit_links(self, mock_commits: Any) -> None:
        node = _node(id="n1", text="Task", status="done")
        comment = build_close_comment(node, repo_url="https://github.com/u/r")
        assert "Commits" in comment
