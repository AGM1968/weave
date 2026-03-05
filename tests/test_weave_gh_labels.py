"""Tests for weave_gh.labels — label constants and pure label operations."""

from __future__ import annotations


from weave_gh.labels import (
    ENSURE_LABELS,
    PRIORITY_LABELS,
    STATUS_LABELS,
    TYPE_LABELS,
    get_labels_for_node,
    parse_gh_labels_to_metadata,
)
from weave_gh.models import WeaveNode


# ---------------------------------------------------------------------------
# Label constant integrity
# ---------------------------------------------------------------------------


class TestLabelConstants:
    def test_status_labels_have_color(self) -> None:
        for status, (name, color) in STATUS_LABELS.items():
            assert name.startswith("weave:"), f"{status} label should start with weave:"
            assert len(color) == 6, f"{status} color should be 6 hex chars"

    def test_priority_labels_complete(self) -> None:
        """All priorities 0–4 should map to P1–P4."""
        for p in range(5):
            assert p in PRIORITY_LABELS
            assert PRIORITY_LABELS[p].startswith("P")

    def test_type_labels_cover_common_types(self) -> None:
        for t in ("bug", "feature", "epic", "task"):
            assert t in TYPE_LABELS

    def test_ensure_labels_includes_weave_synced(self) -> None:
        names = [name for name, _, _ in ENSURE_LABELS]
        assert "weave-synced" in names

    def test_ensure_labels_all_have_color_and_desc(self) -> None:
        for name, color, desc in ENSURE_LABELS:
            assert len(color) == 6, f"{name} color should be 6 hex chars"
            assert len(desc) > 0, f"{name} should have a description"


# ---------------------------------------------------------------------------
# get_labels_for_node (pure function)
# ---------------------------------------------------------------------------


class TestGetLabelsForNode:
    def test_basic_task(self) -> None:
        node = WeaveNode(id="n1", text="t", status="todo")
        labels = get_labels_for_node(node)
        assert "weave-synced" in labels
        assert "task" in labels
        assert "P2" in labels

    def test_epic_p1(self) -> None:
        node = WeaveNode(
            id="n1",
            text="t",
            status="todo",
            metadata={"type": "epic", "priority": 1},
        )
        labels = get_labels_for_node(node)
        assert "epic" in labels
        assert "P1" in labels
        assert "weave-synced" in labels

    def test_active_status_label(self) -> None:
        node = WeaveNode(id="n1", text="t", status="active")
        labels = get_labels_for_node(node)
        assert "weave:active" in labels

    def test_blocked_status_label(self) -> None:
        node = WeaveNode(id="n1", text="t", status="blocked")
        labels = get_labels_for_node(node)
        assert "weave:blocked" in labels

    def test_done_no_status_label(self) -> None:
        """Done nodes should NOT have weave:active or weave:blocked."""
        node = WeaveNode(id="n1", text="t", status="done")
        labels = get_labels_for_node(node)
        assert "weave:active" not in labels
        assert "weave:blocked" not in labels

    def test_bug_type_maps_to_bug_label(self) -> None:
        node = WeaveNode(
            id="n1",
            text="t",
            status="todo",
            metadata={"type": "bug"},
        )
        labels = get_labels_for_node(node)
        assert "bug" in labels

    def test_fix_type_maps_to_bug_label(self) -> None:
        """'fix' type should map to 'bug' label."""
        node = WeaveNode(
            id="n1",
            text="t",
            status="todo",
            metadata={"type": "fix"},
        )
        labels = get_labels_for_node(node)
        assert "bug" in labels

    def test_feature_maps_to_enhancement(self) -> None:
        node = WeaveNode(
            id="n1",
            text="t",
            status="todo",
            metadata={"type": "feature"},
        )
        labels = get_labels_for_node(node)
        assert "enhancement" in labels

    def test_unknown_type_defaults_to_task(self) -> None:
        node = WeaveNode(
            id="n1",
            text="t",
            status="todo",
            metadata={"type": "unknown_type"},
        )
        labels = get_labels_for_node(node)
        assert "task" in labels

    def test_all_priorities(self) -> None:
        for p in range(5):
            node = WeaveNode(
                id="n1",
                text="t",
                status="todo",
                metadata={"priority": p},
            )
            labels = get_labels_for_node(node)
            expected = PRIORITY_LABELS[p]
            assert expected in labels, f"Priority {p} should map to {expected}"


# ---------------------------------------------------------------------------
# parse_gh_labels_to_metadata (pure function)
# ---------------------------------------------------------------------------


class TestParseGhLabelsToMetadata:
    def test_priority_extraction(self) -> None:
        meta = parse_gh_labels_to_metadata(["P1", "weave-synced"])
        assert meta["priority"] == 1

    def test_priority_p4(self) -> None:
        meta = parse_gh_labels_to_metadata(["P4"])
        assert meta["priority"] == 4

    def test_type_from_bug(self) -> None:
        meta = parse_gh_labels_to_metadata(["bug"])
        assert meta["type"] == "bug"

    def test_type_from_enhancement(self) -> None:
        meta = parse_gh_labels_to_metadata(["enhancement"])
        assert meta["type"] == "feature"

    def test_type_from_epic(self) -> None:
        meta = parse_gh_labels_to_metadata(["epic"])
        assert meta["type"] == "epic"

    def test_no_matching_labels(self) -> None:
        meta = parse_gh_labels_to_metadata(["random-label", "another"])
        assert meta == {}

    def test_empty_labels(self) -> None:
        meta = parse_gh_labels_to_metadata([])
        assert meta == {}

    def test_combined(self) -> None:
        meta = parse_gh_labels_to_metadata(["P2", "enhancement", "weave-synced"])
        assert meta["priority"] == 2
        assert meta["type"] == "feature"

    def test_first_priority_wins(self) -> None:
        """If multiple priority labels, the first one should win."""
        meta = parse_gh_labels_to_metadata(["P3", "P1"])
        assert meta["priority"] == 3
