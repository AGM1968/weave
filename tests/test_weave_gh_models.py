"""Tests for weave_gh.models — dataclass properties and SyncStats."""

from __future__ import annotations


from weave_gh.models import Edge, GitHubIssue, SyncStats, WeaveNode


# ---------------------------------------------------------------------------
# WeaveNode properties
# ---------------------------------------------------------------------------


class TestWeaveNodeGhIssue:
    def test_gh_issue_present(self) -> None:
        node = WeaveNode(id="n1", text="t", status="todo", metadata={"gh_issue": 42})
        assert node.gh_issue == 42

    def test_gh_issue_string_coerced(self) -> None:
        node = WeaveNode(id="n1", text="t", status="todo", metadata={"gh_issue": "7"})
        assert node.gh_issue == 7

    def test_gh_issue_missing(self) -> None:
        node = WeaveNode(id="n1", text="t", status="todo")
        assert node.gh_issue is None

    def test_gh_issue_none_explicit(self) -> None:
        node = WeaveNode(id="n1", text="t", status="todo", metadata={"gh_issue": None})
        assert node.gh_issue is None


class TestWeaveNodePriority:
    def test_default_priority(self) -> None:
        node = WeaveNode(id="n1", text="t", status="todo")
        assert node.priority == 2

    def test_explicit_priority(self) -> None:
        node = WeaveNode(id="n1", text="t", status="todo", metadata={"priority": 1})
        assert node.priority == 1

    def test_string_priority_coerced(self) -> None:
        node = WeaveNode(id="n1", text="t", status="todo", metadata={"priority": "3"})
        assert node.priority == 3


class TestWeaveNodeType:
    def test_default_type(self) -> None:
        node = WeaveNode(id="n1", text="t", status="todo")
        assert node.node_type == "task"

    def test_explicit_type(self) -> None:
        node = WeaveNode(id="n1", text="t", status="todo", metadata={"type": "epic"})
        assert node.node_type == "epic"


class TestWeaveNodeDescription:
    def test_default_empty(self) -> None:
        node = WeaveNode(id="n1", text="t", status="todo")
        assert node.description == ""

    def test_explicit(self) -> None:
        node = WeaveNode(
            id="n1",
            text="t",
            status="todo",
            metadata={"description": "Build the thing"},
        )
        assert node.description == "Build the thing"


class TestWeaveNodeNoSync:
    def test_default_false(self) -> None:
        node = WeaveNode(id="n1", text="t", status="todo")
        assert node.no_sync is False

    def test_explicit_true(self) -> None:
        node = WeaveNode(id="n1", text="t", status="todo", metadata={"no_sync": True})
        assert node.no_sync is True

    def test_truthy_not_true(self) -> None:
        """no_sync requires literal True, not just truthy."""
        node = WeaveNode(id="n1", text="t", status="todo", metadata={"no_sync": "yes"})
        assert node.no_sync is False


class TestWeaveNodeIsTest:
    def test_not_test(self) -> None:
        node = WeaveNode(id="n1", text="t", status="todo")
        assert node.is_test is False

    def test_is_test(self) -> None:
        node = WeaveNode(id="n1", text="t", status="todo", metadata={"type": "test"})
        assert node.is_test is True


class TestWeaveNodeLearningParts:
    def test_empty(self) -> None:
        node = WeaveNode(id="n1", text="t", status="done")
        assert node.learning_parts() == {}

    def test_all_parts(self) -> None:
        node = WeaveNode(
            id="n1",
            text="t",
            status="done",
            metadata={
                "decision": "Use SQLite",
                "pattern": "Singleton",
                "pitfall": "Race conditions",
                "learning": "Always lock",
            },
        )
        parts = node.learning_parts()
        assert parts == {
            "decision": "Use SQLite",
            "pattern": "Singleton",
            "pitfall": "Race conditions",
            "learning": "Always lock",
        }

    def test_partial(self) -> None:
        node = WeaveNode(
            id="n1",
            text="t",
            status="done",
            metadata={"pitfall": "Overengineering"},
        )
        assert node.learning_parts() == {"pitfall": "Overengineering"}

    def test_falsy_values_excluded(self) -> None:
        node = WeaveNode(
            id="n1",
            text="t",
            status="done",
            metadata={"decision": "", "pitfall": "X"},
        )
        assert node.learning_parts() == {"pitfall": "X"}


# ---------------------------------------------------------------------------
# GitHubIssue
# ---------------------------------------------------------------------------


class TestGitHubIssue:
    def test_defaults(self) -> None:
        issue = GitHubIssue(number=1, title="Bug", state="OPEN")
        assert issue.body == ""
        assert issue.labels == []

    def test_full(self) -> None:
        issue = GitHubIssue(
            number=42,
            title="Feature",
            state="CLOSED",
            body="description",
            labels=["bug", "P1"],
        )
        assert issue.number == 42
        assert issue.state == "CLOSED"
        assert "bug" in issue.labels


# ---------------------------------------------------------------------------
# Edge
# ---------------------------------------------------------------------------


class TestEdge:
    def test_defaults(self) -> None:
        edge = Edge(source="a", target="b", edge_type="blocks")
        assert edge.weight == 1.0

    def test_custom_weight(self) -> None:
        edge = Edge(source="a", target="b", edge_type="implements", weight=0.5)
        assert edge.weight == 0.5


# ---------------------------------------------------------------------------
# SyncStats
# ---------------------------------------------------------------------------


class TestSyncStats:
    def test_no_changes(self) -> None:
        stats = SyncStats()
        assert stats.summary() == "no changes"

    def test_single_operation(self) -> None:
        stats = SyncStats(created_gh=3)
        assert stats.summary() == "GH created: 3"

    def test_multiple_operations(self) -> None:
        stats = SyncStats(created_gh=2, closed_gh=1, updated_gh=5)
        summary = stats.summary()
        assert "GH created: 2" in summary
        assert "GH closed: 1" in summary
        assert "GH updated: 5" in summary
        # Verify separator
        assert " | " in summary

    def test_all_operations(self) -> None:
        stats = SyncStats(
            created_gh=1,
            closed_gh=2,
            reopened_gh=3,
            updated_gh=4,
            created_wv=5,
            closed_wv=6,
            already_synced=7,
            skipped=8,
        )
        summary = stats.summary()
        assert summary.count("|") == 7  # 8 parts, 7 separators

    def test_zero_operations_omitted(self) -> None:
        stats = SyncStats(created_gh=1, skipped=2)
        summary = stats.summary()
        assert "GH closed" not in summary
        assert "GH created: 1" in summary
        assert "skipped: 2" in summary
