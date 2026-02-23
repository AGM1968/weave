"""Tests for weave_gh.phases — sync logic, reopen guards, and marker matching."""

from __future__ import annotations

import subprocess
from unittest.mock import patch

from weave_gh.models import GitHubIssue, SyncStats, WeaveNode
from weave_gh.phases import (
    _handle_existing_issue,
    _was_closed_by_weave,
    _WEAVE_CLOSE_MARKER,
    sync_github_to_weave,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _node(
    node_id: str,
    text: str = "Test node",
    status: str = "todo",
    gh_issue: int | None = None,
    **meta: object,
) -> WeaveNode:
    metadata: dict[str, object] = {**meta}
    if gh_issue is not None:
        metadata["gh_issue"] = gh_issue
    return WeaveNode(id=node_id, text=text, status=status, metadata=metadata)


def _issue(
    number: int,
    title: str = "Test issue",
    state: str = "OPEN",
    body: str = "",
    labels: list[str] | None = None,
) -> GitHubIssue:
    return GitHubIssue(
        number=number,
        title=title,
        state=state,
        body=body,
        labels=labels or ["weave-synced"],
    )


# Patches to prevent real CLI calls in _handle_existing_issue
_PHASE_PATCHES = [
    "weave_gh.phases.get_edges_for_node",
    "weave_gh.phases.render_issue_body",
    "weave_gh.phases.should_update_body",
    "weave_gh.phases.get_labels_for_node",
    "weave_gh.phases.sync_issue_labels",
    "weave_gh.phases.gh_cli",
    "weave_gh.phases.build_close_comment",
    "weave_gh.phases._backfill_gh_issue",
]


# ---------------------------------------------------------------------------
# _was_closed_by_weave — Weave close marker detection
# ---------------------------------------------------------------------------


class TestWasClosedByWeave:
    """The _was_closed_by_weave helper checks the last GH comment for the marker."""

    def test_detects_weave_close_comment(self) -> None:
        """Should return True when last comment has the Weave close marker."""
        with patch(
            "weave_gh.phases.gh_cli",
            return_value=f"{_WEAVE_CLOSE_MARKER} `wv-abcd` closed.",
        ):
            assert _was_closed_by_weave(100, "owner/repo") is True

    def test_no_weave_marker(self) -> None:
        """Should return False when last comment is a human comment."""
        with patch(
            "weave_gh.phases.gh_cli",
            return_value="Closing this as won't fix.",
        ):
            assert _was_closed_by_weave(100, "owner/repo") is False

    def test_empty_comments(self) -> None:
        """Should return False when issue has no comments."""
        with patch("weave_gh.phases.gh_cli", return_value=""):
            assert _was_closed_by_weave(100, "owner/repo") is False

    def test_api_error_fails_open(self) -> None:
        """Should return False on API errors (fail-open allows reopen)."""
        with patch(
            "weave_gh.phases.gh_cli",
            side_effect=subprocess.SubprocessError("API error"),
        ):
            assert _was_closed_by_weave(100, "owner/repo") is False


# ---------------------------------------------------------------------------
# Phase 1: Reopen guard — done_gh_issues prevents phantom reopens
# ---------------------------------------------------------------------------


class TestReopenGuard:
    """The done_gh_issues guard should block reopens when another node is done."""

    def _call(
        self,
        node: WeaveNode,
        issue: GitHubIssue,
        stats: SyncStats,
        done_gh_issues: set[int] | None = None,
        was_closed_by_weave: bool = False,
    ) -> None:
        issues_by_num = {issue.number: issue}
        nodes_by_id = {node.id: node}
        with patch.multiple(
            "weave_gh.phases",
            get_edges_for_node=lambda _: [],
            render_issue_body=lambda *a, **k: "",
            should_update_body=lambda *a: False,
            get_labels_for_node=lambda _: [],
            sync_issue_labels=lambda *a, **k: None,
            gh_cli=lambda *a, **k: "",
            build_close_comment=lambda *a, **k: "close",
            _backfill_gh_issue=lambda *a, **k: None,
            _was_closed_by_weave=lambda *a: was_closed_by_weave,
        ):
            _handle_existing_issue(
                node,
                issue.number,
                issues_by_num,
                nodes_by_id,
                "owner/repo",
                "https://github.com/owner/repo",
                stats,
                done_gh_issues=done_gh_issues,
            )

    def test_phantom_todo_blocked_by_done_sibling(self) -> None:
        """A phantom todo node should NOT reopen an issue if a done node owns it."""
        phantom = _node("wv-aaaa", status="todo", gh_issue=100)
        issue = _issue(100, state="CLOSED")
        stats = SyncStats()

        # done_gh_issues contains 100 (the real done node has this gh_issue)
        self._call(phantom, issue, stats, done_gh_issues={100})

        assert stats.reopened_gh == 0
        assert stats.skipped == 1
        assert issue.state == "CLOSED"  # not mutated

    def test_legit_todo_reopens_when_no_done_sibling(self) -> None:
        """A real todo node should reopen a closed issue (no done sibling)."""
        node = _node("wv-bbbb", status="todo", gh_issue=200)
        issue = _issue(200, state="CLOSED")
        stats = SyncStats()

        self._call(node, issue, stats, done_gh_issues=set())

        assert stats.reopened_gh == 1
        assert issue.state == "OPEN"  # mutated by reopen

    def test_reopen_guard_with_none(self) -> None:
        """When done_gh_issues is None, reopen proceeds normally."""
        node = _node("wv-cccc", status="active", gh_issue=300)
        issue = _issue(300, state="CLOSED")
        stats = SyncStats()

        self._call(node, issue, stats, done_gh_issues=None)

        assert stats.reopened_gh == 1

    def test_done_node_closes_open_issue(self) -> None:
        """A done node should close its open GH issue (not reopen)."""
        node = _node("wv-dddd", status="done", gh_issue=400)
        issue = _issue(400, state="OPEN")
        stats = SyncStats()

        self._call(node, issue, stats, done_gh_issues={400})

        assert stats.closed_gh == 1
        assert issue.state == "CLOSED"

    def test_done_node_already_closed_is_noop(self) -> None:
        """A done node with already-closed issue is just already_synced."""
        node = _node("wv-eeee", status="done", gh_issue=500)
        issue = _issue(500, state="CLOSED")
        stats = SyncStats()

        self._call(node, issue, stats, done_gh_issues={500})

        assert stats.reopened_gh == 0
        assert stats.closed_gh == 0
        assert stats.already_synced == 1

    def test_weave_closed_issue_not_reopened(self) -> None:
        """An issue closed by Weave should NOT be reopened even if node is active.

        Scenario: developer completes work and commits, but forgets `wv done`.
        The node is still active, but `wv done` or a previous sync already
        closed the GH issue (leaving a Weave close marker comment).
        Sync should skip the reopen and suggest `wv done` instead.
        """
        node = _node("wv-hhhh", status="active", gh_issue=800)
        issue = _issue(800, state="CLOSED")
        stats = SyncStats()

        self._call(
            node, issue, stats,
            done_gh_issues=set(),
            was_closed_by_weave=True,
        )

        assert stats.reopened_gh == 0
        assert stats.skipped == 1
        assert issue.state == "CLOSED"  # not mutated

    def test_human_closed_issue_reopened(self) -> None:
        """An issue closed by a human SHOULD be reopened if node is still open.

        Scenario: someone manually closes a GH issue, but the Weave node is
        still todo/active. Sync should reopen it because the work isn't done.
        """
        node = _node("wv-iiii", status="todo", gh_issue=900)
        issue = _issue(900, state="CLOSED")
        stats = SyncStats()

        self._call(
            node, issue, stats,
            done_gh_issues=set(),
            was_closed_by_weave=False,
        )

        assert stats.reopened_gh == 1
        assert issue.state == "OPEN"  # mutated by reopen

    def test_closed_issue_body_still_updated(self) -> None:
        """A closed issue whose body changed should still get updated.

        Scenario: wv done closes the GH issue directly, then wv sync --gh
        runs. The body (checkboxes, Mermaid) should be refreshed even though
        the issue is already closed.
        """
        node = _node("wv-gggg", status="done", gh_issue=700)
        issue = _issue(700, state="CLOSED", body="old body")
        stats = SyncStats()
        issues_by_num = {700: issue}
        nodes_by_id = {node.id: node}

        gh_calls: list[tuple[object, ...]] = []

        def mock_gh_cli(*args: object, **_kwargs: object) -> str:
            gh_calls.append(args)
            return ""

        with patch.multiple(
            "weave_gh.phases",
            get_edges_for_node=lambda _: [],
            render_issue_body=(
                lambda *a, **k: "<!-- WEAVE:BEGIN hash=abc123 -->\nnew\n<!-- WEAVE:END -->"
            ),
            should_update_body=lambda *a: True,  # body changed
            extract_human_content=lambda _: "",
            compose_issue_body=lambda h, w: w,
            get_labels_for_node=lambda _: [],
            sync_issue_labels=lambda *a, **k: None,
            gh_cli=mock_gh_cli,
            build_close_comment=lambda *a, **k: "close",
            _backfill_gh_issue=lambda *a, **k: None,
            _was_closed_by_weave=lambda *a: False,
        ):
            _handle_existing_issue(
                node,
                700,
                issues_by_num,
                nodes_by_id,
                "owner/repo",
                "https://github.com/owner/repo",
                stats,
                done_gh_issues={700},
            )

        # Body should have been updated even though issue was closed
        assert stats.updated_gh == 1
        edit_calls = [c for c in gh_calls if "edit" in c]
        assert len(edit_calls) == 1
        # Should NOT try to close again (already closed)
        assert stats.closed_gh == 0

    def test_dry_run_reopen(self) -> None:
        """In dry-run, reopen should be counted but not executed."""
        node = _node("wv-ffff", status="todo", gh_issue=600)
        issue = _issue(600, state="CLOSED")
        stats = SyncStats()
        issues_by_num = {600: issue}
        nodes_by_id = {node.id: node}

        with patch.multiple(
            "weave_gh.phases",
            get_edges_for_node=lambda _: [],
            render_issue_body=lambda *a, **k: "",
            should_update_body=lambda *a: False,
            get_labels_for_node=lambda _: [],
            sync_issue_labels=lambda *a, **k: None,
            gh_cli=lambda *a, **k: "",
            build_close_comment=lambda *a, **k: "close",
            _backfill_gh_issue=lambda *a, **k: None,
            _was_closed_by_weave=lambda *a: False,
        ):
            _handle_existing_issue(
                node,
                600,
                issues_by_num,
                nodes_by_id,
                "owner/repo",
                "https://github.com/owner/repo",
                stats,
                done_gh_issues=set(),
                dry_run=True,
            )

        assert stats.reopened_gh == 1
        assert issue.state == "CLOSED"  # not mutated in dry-run


# ---------------------------------------------------------------------------
# Phase 1: Body marker fallback matching (dual format)
# ---------------------------------------------------------------------------


class TestBodyMarkerMatching:
    """Phase 1 body search should match both Weave ID marker formats."""

    def _find_match(self, node_id: str, issue_body: str) -> int | None:
        """Simulate the Phase 1 body marker search logic."""
        marker_bold = f"**Weave ID:** `{node_id}`"
        marker_plain = f"**Weave ID**: `{node_id}`"
        if marker_bold in issue_body or marker_plain in issue_body:
            return 1  # matched
        return None

    def test_bold_colon_format(self) -> None:
        """Bold colon variant **Weave ID:** should match."""
        body = "Some text\n**Weave ID:** `wv-1234`\nMore text"
        assert self._find_match("wv-1234", body) == 1

    def test_plain_colon_format(self) -> None:
        """Plain colon variant **Weave ID**: should match."""
        body = "Some text\n**Weave ID**: `wv-1234`\nMore text"
        assert self._find_match("wv-1234", body) == 1

    def test_no_match(self) -> None:
        """Different node ID should not match."""
        body = "Some text\n**Weave ID:** `wv-9999`\nMore text"
        assert self._find_match("wv-1234", body) is None

    def test_partial_id_no_match(self) -> None:
        """wv-123 should NOT match wv-1234."""
        body = "**Weave ID:** `wv-1234`"
        assert self._find_match("wv-123", body) is None


# ---------------------------------------------------------------------------
# Phase 2: Body marker dedup guard (dual format)
# ---------------------------------------------------------------------------


class TestPhase2BodyMarkerDedup:
    """Phase 2 should skip creating nodes when body contains known Weave IDs."""

    def test_skips_bold_colon_marker(self) -> None:
        """Issue with bold-colon Weave ID marker should not create a node."""
        nodes = [_node("wv-aaaa", gh_issue=10)]
        issue = _issue(
            99,
            title="Untracked issue",
            state="OPEN",
            body="**Weave ID:** `wv-aaaa`",
        )
        stats = SyncStats()

        sync_github_to_weave(nodes, [issue], "repo", stats, dry_run=True)

        assert stats.created_wv == 0

    def test_skips_plain_colon_marker(self) -> None:
        """Issue with plain-colon Weave ID marker should not create a node."""
        nodes = [_node("wv-bbbb", gh_issue=20)]
        issue = _issue(
            99,
            title="Untracked issue",
            state="OPEN",
            body="**Weave ID**: `wv-bbbb`",
        )
        stats = SyncStats()

        sync_github_to_weave(nodes, [issue], "repo", stats, dry_run=True)

        assert stats.created_wv == 0

    def test_creates_when_no_marker(self) -> None:
        """Issue without any Weave ID marker should create a new node."""
        nodes = [_node("wv-cccc", gh_issue=30)]
        issue = _issue(
            99,
            title="Brand new issue",
            state="OPEN",
            body="No weave references here",
        )
        stats = SyncStats()

        sync_github_to_weave(nodes, [issue], "repo", stats, dry_run=True)

        assert stats.created_wv == 1

    def test_skips_tracked_by_gh_issue(self) -> None:
        """Issues already tracked by metadata.gh_issue should be skipped."""
        nodes = [_node("wv-dddd", gh_issue=99)]
        issue = _issue(99, title="Already tracked", state="OPEN")
        stats = SyncStats()

        sync_github_to_weave(nodes, [issue], "repo", stats, dry_run=True)

        assert stats.created_wv == 0

    def test_skips_closed_untracked(self) -> None:
        """Closed GH issues with no Weave node should be skipped."""
        nodes: list[WeaveNode] = []
        issue = _issue(99, title="Old closed", state="CLOSED")
        stats = SyncStats()

        sync_github_to_weave(nodes, [issue], "repo", stats, dry_run=True)

        assert stats.created_wv == 0
        assert stats.skipped == 1
