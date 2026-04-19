"""Tests for weave_gh.phases — sync logic, reopen guards, and marker matching."""

from __future__ import annotations

import json
import subprocess
from contextlib import contextmanager
from typing import Any, Generator
from unittest.mock import patch

from weave_gh.models import GitHubIssue, SyncStats, WeaveNode
from weave_gh.models import Edge
from weave_gh.phases import (
    _backfill_gh_issue,
    _current_gh_login,
    _desired_assignee_for_node,
    _handle_existing_issue,
    _handle_new_issue,
    _invalid_assignees,
    _is_valid_assignee,
    _sync_assignee,
    _was_closed_by_weave,
    _WEAVE_CLOSE_MARKER,
    refresh_parent_body,
    sync_closed_to_weave,
    sync_github_to_weave,
    sync_weave_to_github,
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

    def _with_patches(self, **overrides: Any) -> Any:
        """Return a patch.multiple context with sensible defaults, overridable per-test."""
        base: dict[str, Any] = {
            "get_edges_for_node": lambda _: [],
            "render_issue_body": lambda *_a, **_k: "",
            "should_update_body": lambda *_a: False,
            "get_labels_for_node": lambda _: [],
            "sync_issue_labels": lambda *_a, **_k: None,
            "gh_cli": lambda *_a, **_k: "",
            "build_close_comment": lambda *_a, **_k: "close",
            "_backfill_gh_issue": lambda *_a, **_k: None,
            "_was_closed_by_weave": lambda *_a: False,
        }
        base.update(overrides)
        return patch.multiple("weave_gh.phases", **base)

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
        with self._with_patches(
            _was_closed_by_weave=lambda *_a: was_closed_by_weave,
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

        with self._with_patches(
            render_issue_body=(
                lambda *_a, **_k: "<!-- WEAVE:BEGIN hash=abc123 -->\nnew\n<!-- WEAVE:END -->"
            ),
            should_update_body=lambda *_a: True,  # body changed
            extract_human_content=lambda _: "",
            compose_issue_body=lambda h, w: w,
            gh_cli=mock_gh_cli,
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
            render_issue_body=lambda *_a, **_k: "",
            should_update_body=lambda *_a: False,
            get_labels_for_node=lambda _: [],
            sync_issue_labels=lambda *_a, **_k: None,
            gh_cli=lambda *_a, **_k: "",
            build_close_comment=lambda *_a, **_k: "close",
            _backfill_gh_issue=lambda *_a, **_k: None,
            _was_closed_by_weave=lambda *_a: False,
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

    def _run(self, nodes: list[WeaveNode], issue: GitHubIssue) -> SyncStats:
        stats = SyncStats()
        sync_github_to_weave(nodes, [issue], "repo", stats, dry_run=True)
        return stats

    def test_skips_bold_colon_marker(self) -> None:
        """Issue with bold-colon Weave ID marker should not create a node."""
        nodes = [_node("wv-aaaa", gh_issue=10)]
        issue = _issue(99, title="Untracked issue", state="OPEN",
                       body="**Weave ID:** `wv-aaaa`")
        assert self._run(nodes, issue).created_wv == 0

    def test_skips_plain_colon_marker(self) -> None:
        """Issue with plain-colon Weave ID marker should not create a node."""
        nodes = [_node("wv-bbbb", gh_issue=20)]
        issue = _issue(99, title="Untracked issue", state="OPEN",
                       body="**Weave ID**: `wv-bbbb`")
        assert self._run(nodes, issue).created_wv == 0

    def test_creates_when_no_marker(self) -> None:
        """Issue without any Weave ID marker should create a new node."""
        nodes = [_node("wv-cccc", gh_issue=30)]
        issue = _issue(99, title="Brand new issue", state="OPEN",
                       body="No weave references here")
        assert self._run(nodes, issue).created_wv == 1

    def test_skips_tracked_by_gh_issue(self) -> None:
        """Issues already tracked by metadata.gh_issue should be skipped."""
        nodes = [_node("wv-dddd", gh_issue=99)]
        issue = _issue(99, title="Already tracked", state="OPEN")
        assert self._run(nodes, issue).created_wv == 0

    def test_skips_closed_untracked(self) -> None:
        """Closed GH issues with no Weave node should be skipped."""
        stats = self._run([], _issue(99, title="Old closed", state="CLOSED"))
        assert stats.created_wv == 0
        assert stats.skipped == 1


# ---------------------------------------------------------------------------
# refresh_parent_body — targeted parent epic body update
# ---------------------------------------------------------------------------


class TestRefreshParentBody:
    """refresh_parent_body updates the parent epic GH issue after child close."""

    @contextmanager
    def _with_repo(
        self, nodes: list[WeaveNode], **phase_overrides: Any
    ) -> Generator[None, None, None]:
        """Context manager: patch get_weave_nodes + get_repo plus any phases overrides."""
        patches: Any = phase_overrides
        with patch.multiple("weave_gh.phases", **patches), patch(
            "weave_gh.data.get_weave_nodes", return_value=nodes
        ), patch("weave_gh.phases.get_repo", return_value="owner/repo"):
            yield

    def test_updates_parent_body_when_hash_changed(self) -> None:
        """Should update parent GH issue when child status changes content hash."""
        parent = _node("wv-epic", text="Epic task", status="active", gh_issue=100)
        child = _node("wv-task", text="Child task", status="done", gh_issue=200)
        edge = Edge(source="wv-task", target="wv-epic", edge_type="implements")

        gh_edit_calls: list[tuple[object, ...]] = []

        def mock_gh_cli(*args: object, **_kw: object) -> str:
            gh_edit_calls.append(args)
            # gh issue view returns the existing body
            if "view" in args:
                return "<!-- WEAVE:BEGIN hash=aabb00112233 -->\nold\n<!-- WEAVE:END -->"
            return ""

        with self._with_repo(
            [parent, child],
            get_parent=lambda _child_id: "wv-epic",
            get_edges_for_node=lambda _nid: [edge],
            render_issue_body=lambda *_a, **_k: (
                "<!-- WEAVE:BEGIN hash=ccdd44556677 -->\nnew\n<!-- WEAVE:END -->"
            ),
            gh_cli=mock_gh_cli,
        ):
            result = refresh_parent_body("wv-task")

        assert result is True
        # Should have called gh issue view + gh issue edit
        edit_calls = [c for c in gh_edit_calls if "edit" in c]
        assert len(edit_calls) == 1

    def test_no_parent_returns_false(self) -> None:
        """Should return False when child has no parent."""
        with patch("weave_gh.phases.get_parent", return_value=None):
            assert refresh_parent_body("wv-orphan") is False

    def test_parent_without_gh_issue_returns_false(self) -> None:
        """Should return False when parent has no GH issue linked."""
        parent = _node("wv-epic", text="Epic", status="active")  # no gh_issue

        with patch(
            "weave_gh.phases.get_parent", return_value="wv-epic"
        ), patch(
            "weave_gh.data.get_weave_nodes",
            return_value=[parent],
        ):
            assert refresh_parent_body("wv-task") is False

    def test_no_update_when_hash_unchanged(self) -> None:
        """Should return False when body hash hasn't changed."""
        parent = _node("wv-epic", text="Epic", status="active", gh_issue=100)

        body = "<!-- WEAVE:BEGIN hash=aabb11223344 -->\nsame\n<!-- WEAVE:END -->"

        with self._with_repo(
            [parent],
            get_parent=lambda _: "wv-epic",
            get_edges_for_node=lambda _: [],
            render_issue_body=lambda *_a, **_k: body,
            gh_cli=lambda *_a, **_kw: body,
        ):
            assert refresh_parent_body("wv-task") is False

    def test_dry_run_does_not_edit(self) -> None:
        """Dry run should return True but not call gh issue edit."""
        parent = _node("wv-epic", text="Epic", status="active", gh_issue=100)
        child = _node("wv-task", text="Child", status="done", gh_issue=200)

        gh_calls: list[tuple[object, ...]] = []

        def mock_gh_cli(*args: object, **_kw: object) -> str:
            gh_calls.append(args)
            if "view" in args:
                return "<!-- WEAVE:BEGIN hash=aa0011223344 -->\nold\n<!-- WEAVE:END -->"
            return ""

        with self._with_repo(
            [parent, child],
            get_parent=lambda _: "wv-epic",
            get_edges_for_node=lambda _: [],
            render_issue_body=lambda *_a, **_k: (
                "<!-- WEAVE:BEGIN hash=bb0099887766 -->\nnew\n<!-- WEAVE:END -->"
            ),
            gh_cli=mock_gh_cli,
        ):
            result = refresh_parent_body("wv-task", dry_run=True)

        assert result is True
        edit_calls = [c for c in gh_calls if "edit" in c]
        assert len(edit_calls) == 0


# ---------------------------------------------------------------------------
# _sync_assignee — helper for Weave→GH assignee sync
# ---------------------------------------------------------------------------


class TestSyncAssignee:
    """_sync_assignee should add/remove/noop GH issue assignees."""

    def _ok_run(self, cmd: list[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
        """Stub _run that always succeeds."""
        return subprocess.CompletedProcess(cmd, returncode=0, stdout="", stderr="")

    def _fail_run(self, cmd: list[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
        """Stub _run that always fails."""
        return subprocess.CompletedProcess(cmd, returncode=1, stdout="", stderr="Not a collaborator")

    def test_noop_when_unchanged(self) -> None:
        """Should return False and not call _run when assignee already correct."""
        _invalid_assignees.discard("alice")
        calls: list[list[str]] = []
        with patch("weave_gh.phases._run", side_effect=lambda cmd, **_k: (calls.append(cmd), self._ok_run(cmd))[1]):
            changed = _sync_assignee(1, "alice", ["alice"], "owner/repo")
        assert changed is False
        assert not calls

    def test_add_assignee(self) -> None:
        """Should call gh issue edit --add-assignee when desired != current and user is valid."""
        _invalid_assignees.discard("alice")
        calls: list[list[str]] = []
        with patch("weave_gh.phases._run", side_effect=lambda cmd, **_k: (calls.append(cmd), self._ok_run(cmd))[1]):
            changed = _sync_assignee(1, "alice", [], "owner/repo")
        assert changed is True
        edit_call = next(c for c in calls if "edit" in c)
        assert "--add-assignee" in edit_call

    def test_add_assignee_invalid_user(self) -> None:
        """Should return False and not call edit when the user is not a valid collaborator."""
        _invalid_assignees.discard("ghost")
        calls: list[list[str]] = []
        with patch("weave_gh.phases._run", side_effect=lambda cmd, **_k: (calls.append(cmd), self._fail_run(cmd))[1]):
            changed = _sync_assignee(1, "ghost", [], "owner/repo")
        assert changed is False
        assert "ghost" in _invalid_assignees
        assert not any("edit" in c for c in calls)

    def test_add_assignee_edit_fails(self) -> None:
        """Should return False when user is valid but edit call fails."""
        _invalid_assignees.discard("alice")
        call_count = 0

        def _side_effect(cmd: list[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
            nonlocal call_count
            call_count += 1
            # First call: _is_valid_assignee succeeds; second call: edit fails
            if call_count == 1:
                return self._ok_run(cmd)
            return self._fail_run(cmd)

        with patch("weave_gh.phases._run", side_effect=_side_effect):
            changed = _sync_assignee(1, "alice", [], "owner/repo")
        assert changed is False

    def test_remove_assignee(self) -> None:
        """Should call gh issue edit --remove-assignee when desired is None."""
        calls: list[list[str]] = []
        with patch("weave_gh.phases._run", side_effect=lambda cmd, **_k: (calls.append(cmd), self._ok_run(cmd))[1]):
            changed = _sync_assignee(1, None, ["alice"], "owner/repo")
        assert changed is True
        assert any("--remove-assignee" in c for c in calls[0])

    def test_remove_assignee_fails(self) -> None:
        """Should return False when remove-assignee call fails."""
        with patch("weave_gh.phases._run", side_effect=lambda cmd, **_k: self._fail_run(cmd)):
            changed = _sync_assignee(1, None, ["alice"], "owner/repo")
        assert changed is False

    def test_dry_run_no_call(self) -> None:
        """Dry run should return True but not call _run."""
        calls: list[list[str]] = []
        with patch("weave_gh.phases._run", side_effect=lambda cmd, **_k: (calls.append(cmd), self._ok_run(cmd))[1]):
            changed = _sync_assignee(1, "alice", [], "owner/repo", dry_run=True)
        assert changed is True
        assert not calls


class TestIsValidAssignee:
    """_is_valid_assignee should check GH API and cache failures."""

    def test_valid_user_returns_true(self) -> None:
        """Returns True when gh api returns 0."""
        _invalid_assignees.discard("validuser")
        ok = subprocess.CompletedProcess([], returncode=0, stdout="", stderr="")
        with patch("weave_gh.phases._run", return_value=ok):
            assert _is_valid_assignee("validuser", "owner/repo") is True
        assert "validuser" not in _invalid_assignees

    def test_invalid_user_returns_false_and_caches(self) -> None:
        """Returns False when gh api returns non-zero, caches the login."""
        _invalid_assignees.discard("noone")
        fail = subprocess.CompletedProcess([], returncode=1, stdout="", stderr="Not Found")
        with patch("weave_gh.phases._run", return_value=fail):
            assert _is_valid_assignee("noone", "owner/repo") is False
        assert "noone" in _invalid_assignees

    def test_cached_invalid_skips_api_call(self) -> None:
        """Second call for a known-invalid user skips the API call."""
        _invalid_assignees.add("cached-bad")
        calls: list[object] = []
        with patch("weave_gh.phases._run", side_effect=lambda *a, **k: calls.append(a)):
            result = _is_valid_assignee("cached-bad", "owner/repo")
        assert result is False
        assert not calls


class TestDesiredAssigneeForNode:
    """Local claim IDs should resolve to a real GH login before sync."""

    def teardown_method(self) -> None:
        _current_gh_login.cache_clear()

    def test_done_node_skips_assignee_sync(self) -> None:
        """Done nodes should not drive assignee changes."""
        node = _node("wv-done", status="done", claimed_by="alice")
        assert _desired_assignee_for_node(node) is None

    def test_non_local_claim_is_used_verbatim(self) -> None:
        """Explicit collaborator logins should pass through unchanged."""
        node = _node("wv-active", status="active", claimed_by="alice")
        assert _desired_assignee_for_node(node) == "alice"

    def test_local_default_claim_maps_to_authenticated_login(self) -> None:
        """Default hostname-user claims should resolve to the current GH login."""
        _current_gh_login.cache_clear()
        ok = subprocess.CompletedProcess([], returncode=0, stdout="octocat\n", stderr="")
        with patch("weave_gh.phases.socket.gethostname", return_value="host"), patch(
            "weave_gh.phases.getpass.getuser", return_value="user"
        ), patch("weave_gh.phases._run", return_value=ok):
            node = _node("wv-local", status="active", claimed_by="host-user")
            assert _desired_assignee_for_node(node) == "octocat"


# ---------------------------------------------------------------------------
# Phase 2: GH→Weave sets claimed_by from assignees
# ---------------------------------------------------------------------------


class TestPhase2ClaimedBy:
    """Phase 2 should set claimed_by in metadata from GH issue assignees."""

    def test_sets_claimed_by_from_assignee(self) -> None:
        """A GH issue with an assignee should set claimed_by in the new node."""
        nodes: list[WeaveNode] = []
        issue = GitHubIssue(
            number=42,
            title="Assigned task",
            state="OPEN",
            body="",
            labels=["weave-synced"],
            assignees=["alice"],
        )
        stats = SyncStats()
        created_meta: list[dict[str, object]] = []

        def mock_wv_cli(*args: object, **_kw: object) -> str:
            # Capture --metadata arg to verify claimed_by is set
            args_list = list(args)
            for arg in args_list:
                if isinstance(arg, str) and arg.startswith("--metadata="):
                    created_meta.append(json.loads(arg[len("--metadata="):]))
            return "wv-test"

        with patch("weave_gh.phases.wv_cli", side_effect=mock_wv_cli):
            sync_github_to_weave(nodes, [issue], "owner/repo", stats)

        assert stats.created_wv == 1
        assert created_meta
        assert created_meta[0].get("claimed_by") == "alice"

    def test_no_claimed_by_when_no_assignee(self) -> None:
        """A GH issue with no assignees should not set claimed_by."""
        nodes: list[WeaveNode] = []
        issue = GitHubIssue(
            number=43, title="Unassigned", state="OPEN", body="", labels=["weave-synced"]
        )
        stats = SyncStats()
        created_meta: list[dict[str, object]] = []

        def mock_wv_cli(*args: object, **_kw: object) -> str:
            args_list = list(args)
            for arg in args_list:
                if isinstance(arg, str) and arg.startswith("--metadata="):
                    created_meta.append(json.loads(arg[len("--metadata="):]))
            return "wv-test"

        with patch("weave_gh.phases.wv_cli", side_effect=mock_wv_cli):
            sync_github_to_weave(nodes, [issue], "owner/repo", stats)

        assert stats.created_wv == 1
        assert created_meta
        assert "claimed_by" not in created_meta[0]


# ---------------------------------------------------------------------------
# _handle_new_issue — blocked status regression (phases.py:251)
# ---------------------------------------------------------------------------


class TestHandleNewIssueBlockedStatus:
    """Regression: blocked nodes must get GH issues created, not silently skipped."""

    def _call(
        self,
        node: WeaveNode,
        stats: SyncStats,
        created_gh_issues: list[str] | None = None,
    ) -> None:
        gh_calls: list[str] = created_gh_issues if created_gh_issues is not None else []
        with patch.multiple(
            "weave_gh.phases",
            get_edges_for_node=lambda _: [],
            render_issue_body=lambda *_a, **_k: "",
            get_labels_for_node=lambda _: [],
            sync_issue_labels=lambda *_a, **_k: None,
            _backfill_gh_issue=lambda *_a, **_k: None,
            gh_cli=lambda *_a, **_k: (
                gh_calls.append("create"),  # type: ignore[func-returns-value]
                "https://github.com/owner/repo/issues/999",
            )[1],
        ):
            _handle_new_issue(
                node,
                nodes_by_id={},
                issues=[],
                issues_by_num={},
                issues_by_title={},
                repo="owner/repo",
                repo_url="https://github.com/owner/repo",
                stats=stats,
                dry_run=False,
            )

    def test_blocked_node_creates_gh_issue(self) -> None:
        """A blocked node with no GH issue should have one created (regression #1392)."""
        node = _node("wv-blck", status="blocked")
        stats = SyncStats()
        calls: list[str] = []

        self._call(node, stats, created_gh_issues=calls)

        assert stats.skipped == 0
        assert stats.created_gh == 1

    def test_todo_node_creates_gh_issue(self) -> None:
        """todo nodes should continue to create GH issues."""
        node = _node("wv-todo", status="todo")
        stats = SyncStats()

        self._call(node, stats)

        assert stats.skipped == 0
        assert stats.created_gh == 1

    def test_unknown_status_still_skipped(self) -> None:
        """Unknown status values should still be skipped."""
        node = _node("wv-unkn", status="archived")
        stats = SyncStats()

        self._call(node, stats)

        assert stats.skipped == 1
        assert stats.created_gh == 0


# ---------------------------------------------------------------------------
# _backfill_gh_issue — dedup guard + in-memory update (lines 74-101)
# ---------------------------------------------------------------------------


class TestBackfillGhIssue:
    """_backfill_gh_issue updates metadata atomically with dedup guard."""

    def test_dry_run_is_noop(self) -> None:
        """In dry-run mode the function returns immediately without any side effects."""
        node = _node("wv-aaa1", gh_issue=None)
        with patch("weave_gh.phases._run") as mock_run:
            _backfill_gh_issue(node, 42, dry_run=True)
        mock_run.assert_not_called()
        assert node.metadata.get("gh_issue") is None

    def test_dedup_guard_skips_when_already_claimed(self) -> None:
        """Skips backfill when another node already claims the same gh_issue."""
        node = _node("wv-new1")
        other = _node("wv-old1", gh_issue=99)
        with patch("weave_gh.phases._run") as mock_run:
            _backfill_gh_issue(node, 99, all_nodes=[node, other])
        mock_run.assert_not_called()
        assert node.metadata.get("gh_issue") is None

    def test_done_only_duplicate_is_silent(self) -> None:
        """Historical done-only duplicates should skip backfill without warning."""
        node = _node("wv-newdone", status="done")
        other = _node("wv-olddone", status="done", gh_issue=99)
        with patch("weave_gh.phases._run") as mock_run, patch(
            "weave_gh.phases.log.warning"
        ) as warn:
            _backfill_gh_issue(node, 99, all_nodes=[node, other])
        mock_run.assert_not_called()
        warn.assert_not_called()
        assert node.metadata.get("gh_issue") is None

    def test_backfill_updates_in_memory(self) -> None:
        """Successful backfill updates node.metadata['gh_issue'] in-memory."""
        node = _node("wv-new2")
        with patch("weave_gh.phases._run"), patch(
            "weave_gh.phases._resolve_db_path", return_value="/tmp/test.db"
        ):
            _backfill_gh_issue(node, 77, all_nodes=[node])
        assert node.metadata["gh_issue"] == 77

    def test_backfill_no_all_nodes(self) -> None:
        """When all_nodes is None, dedup guard is skipped and backfill proceeds."""
        node = _node("wv-new3")
        with patch("weave_gh.phases._run"), patch(
            "weave_gh.phases._resolve_db_path", return_value="/tmp/test.db"
        ):
            _backfill_gh_issue(node, 55, all_nodes=None)
        assert node.metadata["gh_issue"] == 55


# ---------------------------------------------------------------------------
# sync_weave_to_github — Phase 1 main loop (lines 147-234)
# ---------------------------------------------------------------------------


class TestSyncWeaveToGithub:
    """sync_weave_to_github drives Phase 1: Weave→GitHub issue creation/update."""

    def _patches(self, **overrides: Any) -> Any:
        base: dict[str, Any] = {
            "get_edges_for_node": lambda _: [],
            "render_issue_body": lambda *_a, **_k: "",
            "should_update_body": lambda *_a: False,
            "get_labels_for_node": lambda _: [],
            "sync_issue_labels": lambda *_a, **_k: None,
            "gh_cli": lambda *_a, **_k: "",
            "build_close_comment": lambda *_a, **_k: "close",
            "_backfill_gh_issue": lambda *_a, **_k: None,
            "_was_closed_by_weave": lambda *_a: False,
            "extract_human_content": lambda _: "",
            "compose_issue_body": lambda h, w: w,
        }
        base.update(overrides)
        return patch.multiple("weave_gh.phases", **base)

    def test_duplicate_gh_issue_dedup_logs_skip(self) -> None:
        """When two nodes share a gh_issue, the second is skipped."""
        n1 = _node("wv-dup1", gh_issue=10)
        n2 = _node("wv-dup2", gh_issue=10)
        issue = _issue(10, state="OPEN")
        stats = SyncStats()

        with self._patches(), patch("weave_gh.phases.log.warning") as warn:
            sync_weave_to_github(
                [n1, n2], [issue],
                "owner/repo", "https://github.com/owner/repo",
                {n1.id: n1, n2.id: n2},
                stats,
            )

        assert stats.skipped >= 1
        assert any(
            "Duplicate gh_issue mappings detected" in str(call.args[0])
            for call in warn.call_args_list
        )

    def test_done_only_duplicate_gh_issue_is_silent(self) -> None:
        """Historical done-only duplicates should still dedup processing without warning."""
        n1 = _node("wv-done1", status="done", gh_issue=10)
        n2 = _node("wv-done2", status="done", gh_issue=10)
        issue = _issue(10, state="CLOSED")
        stats = SyncStats()

        with self._patches(), patch("weave_gh.phases.log.warning") as warn:
            sync_weave_to_github(
                [n1, n2], [issue],
                "owner/repo", "https://github.com/owner/repo",
                {n1.id: n1, n2.id: n2},
                stats,
            )

        assert stats.skipped >= 1
        assert not any(
            "Duplicate gh_issue mappings detected" in str(call.args[0])
            for call in warn.call_args_list
        )

    def test_no_gh_match_routes_to_handle_new(self) -> None:
        """Nodes without a GH issue are routed to _handle_new_issue (dry-run)."""
        node = _node("wv-newo", status="todo")
        stats = SyncStats()

        with self._patches():
            sync_weave_to_github(
                [node], [],
                "owner/repo", "https://github.com/owner/repo",
                {node.id: node},
                stats, dry_run=True,
            )

        assert stats.created_gh == 1

    def test_test_nodes_are_skipped(self) -> None:
        """Nodes with node_type='test' are always skipped."""
        node = WeaveNode(
            id="wv-test", text="Test", status="todo",
            metadata={"type": "test"},
        )
        stats = SyncStats()

        with self._patches():
            sync_weave_to_github(
                [node], [],
                "owner/repo", "https://github.com/owner/repo",
                {node.id: node},
                stats,
            )

        assert stats.skipped == 1

    def test_finding_nodes_are_skipped(self) -> None:
        """Nodes with node_type='finding' are skipped from GH sync.

        Findings are internal audit records. Bulk `wv findings promote`
        used to flood GH with hundreds of issues; the filter prevents
        recurrence.
        """
        node = WeaveNode(
            id="wv-finding", text="Finding: example", status="todo",
            metadata={"type": "finding", "finding": {"fixable": False}},
        )
        stats = SyncStats()

        with self._patches():
            sync_weave_to_github(
                [node], [],
                "owner/repo", "https://github.com/owner/repo",
                {node.id: node},
                stats,
            )

        assert stats.skipped == 1
        assert stats.created_gh == 0

    def test_gh_match_via_body_marker_routes_to_handle_existing(self) -> None:
        """Nodes matched via body marker are routed to _handle_existing_issue."""
        node = _node("wv-mark", status="active")
        issue = _issue(55, body=f"**Weave ID:** `{node.id}`")
        stats = SyncStats()

        with self._patches():
            sync_weave_to_github(
                [node], [issue],
                "owner/repo", "https://github.com/owner/repo",
                {node.id: node},
                stats,
            )

        assert stats.skipped == 0


# ---------------------------------------------------------------------------
# _handle_new_issue — dry-run + weave-synced skip + label/assignee args
# ---------------------------------------------------------------------------


class TestHandleNewIssuePaths:
    """Cover dry-run, weave-synced skip, label_args and assignee_args building."""

    def _call(
        self,
        node: WeaveNode,
        stats: SyncStats,
        issues_by_title: dict[str, GitHubIssue] | None = None,
        dry_run: bool = False,
        **gh_override: Any,
    ) -> None:
        defaults: dict[str, Any] = {
            "get_edges_for_node": lambda _: [],
            "render_issue_body": lambda *_a, **_k: "",
            "get_labels_for_node": lambda _: [],
            "sync_issue_labels": lambda *_a, **_k: None,
            "_backfill_gh_issue": lambda *_a, **_k: None,
            "gh_cli": lambda *_a, **_k: "",
        }
        defaults.update(gh_override)
        with patch.multiple("weave_gh.phases", **defaults):
            _handle_new_issue(
                node,
                nodes_by_id={},
                issues=[],
                issues_by_num={},
                issues_by_title=issues_by_title or {},
                repo="owner/repo",
                repo_url="https://github.com/owner/repo",
                stats=stats,
                dry_run=dry_run,
            )

    def test_dry_run_increments_count_without_gh_call(self) -> None:
        """Dry-run logs intent and increments created_gh without calling gh_cli."""
        node = _node("wv-dryy", status="todo")
        stats = SyncStats()
        gh_calls: list[object] = []
        self._call(
            node, stats, dry_run=True,
            gh_cli=lambda *_a, **_k: gh_calls.append(_a) or "",  # type: ignore[func-returns-value]
        )
        assert stats.created_gh == 1
        assert not gh_calls

    def test_weave_synced_title_match_backfills_and_returns(self) -> None:
        """If title matches a weave-synced issue, backfills gh_issue and skips creation."""
        node = _node("wv-titl", text="Existing task", status="todo")
        existing = _issue(77, title="Existing task", labels=["weave-synced"])
        stats = SyncStats()
        backfill_calls: list[object] = []

        with patch.multiple(
            "weave_gh.phases",
            get_edges_for_node=lambda _: [],
            render_issue_body=lambda *_a, **_k: "",
            get_labels_for_node=lambda _: [],
            sync_issue_labels=lambda *_a, **_k: None,
            gh_cli=lambda *_a, **_k: "",
            _backfill_gh_issue=lambda *_a, **_k: backfill_calls.append(_a),
        ):
            _handle_new_issue(
                node,
                nodes_by_id={},
                issues=[existing],
                issues_by_num={existing.number: existing},
                issues_by_title={"Existing task": existing},
                repo="owner/repo",
                repo_url="https://github.com/owner/repo",
                stats=stats,
                dry_run=False,
            )

        assert stats.already_synced == 1
        assert stats.created_gh == 0
        assert len(backfill_calls) == 1

    def test_done_only_title_match_duplicate_skips_silently(self) -> None:
        """Historical done-only title duplicates should not emit title-match/backfill chatter."""
        node = _node("wv-titl2", text="Existing task", status="done")
        claimant = _node("wv-claim", text="Existing task", status="done", gh_issue=77)
        existing = _issue(77, title="Existing task", labels=["weave-synced"])
        stats = SyncStats()
        backfill_calls: list[object] = []

        with patch.multiple(
            "weave_gh.phases",
            get_edges_for_node=lambda _: [],
            render_issue_body=lambda *_a, **_k: "",
            get_labels_for_node=lambda _: [],
            sync_issue_labels=lambda *_a, **_k: None,
            gh_cli=lambda *_a, **_k: "",
            _backfill_gh_issue=lambda *_a, **_k: backfill_calls.append(_a),
        ), patch("weave_gh.phases.log.info") as info:
            _handle_new_issue(
                node,
                nodes_by_id={},
                issues=[existing],
                issues_by_num={existing.number: existing},
                issues_by_title={"Existing task": existing},
                repo="owner/repo",
                repo_url="https://github.com/owner/repo",
                stats=stats,
                all_nodes=[node, claimant],
                dry_run=False,
            )

        assert stats.skipped == 1
        assert stats.already_synced == 0
        assert stats.created_gh == 0
        assert not backfill_calls
        assert not any("same title (weave-synced)" in str(call.args[0]) for call in info.call_args_list)

    def test_labels_passed_to_gh_cli_assignee_via_sync(self) -> None:
        """Labels are in gh issue create; assignee is synced post-creation, not in create args."""
        node = WeaveNode(
            id="wv-labl", text="Labelled", status="todo",
            metadata={"claimed_by": "alice"},
        )
        gh_args: list[tuple[object, ...]] = []
        sync_calls: list[tuple[object, ...]] = []
        stats = SyncStats()

        with patch.multiple(
            "weave_gh.phases",
            get_edges_for_node=lambda _: [],
            render_issue_body=lambda *_a, **_k: "",
            get_labels_for_node=lambda _: ["bug", "enhancement"],
            sync_issue_labels=lambda *_a, **_k: None,
            _backfill_gh_issue=lambda *_a, **_k: None,
            _sync_assignee=lambda *_a, **_k: sync_calls.append(_a),
            gh_cli=lambda *_a, **_k: (
                gh_args.append(_a),  # type: ignore[func-returns-value]
                "https://github.com/o/r/issues/1",
            )[1],
        ):
            _handle_new_issue(
                node,
                nodes_by_id={},
                issues=[],
                issues_by_num={},
                issues_by_title={},
                repo="owner/repo",
                repo_url="https://github.com/owner/repo",
                stats=stats,
                dry_run=False,
            )

        assert gh_args
        create_args = " ".join(str(a) for a in gh_args[0])
        assert "--label" in create_args
        assert "--assignee" not in create_args  # assignee not in create call
        assert len(sync_calls) == 1             # assignee synced post-creation

    def test_done_node_closes_issue_after_create(self) -> None:
        """If node is done, the newly created issue is immediately closed."""
        node = _node("wv-done", status="done")
        gh_calls: list[tuple[object, ...]] = []
        stats = SyncStats()

        with patch.multiple(
            "weave_gh.phases",
            get_edges_for_node=lambda _: [],
            render_issue_body=lambda *_a, **_k: "",
            get_labels_for_node=lambda _: [],
            sync_issue_labels=lambda *_a, **_k: None,
            _backfill_gh_issue=lambda *_a, **_k: None,
            build_close_comment=lambda *_a, **_k: "closed",
            gh_cli=lambda *_a, **_k: (
                gh_calls.append(_a),  # type: ignore[func-returns-value]
                "https://github.com/owner/repo/issues/42",
            )[1],
        ):
            _handle_new_issue(
                node,
                nodes_by_id={},
                issues=[],
                issues_by_num={},
                issues_by_title={},
                repo="owner/repo",
                repo_url="https://github.com/owner/repo",
                stats=stats,
                dry_run=False,
            )

        close_calls = [c for c in gh_calls if "close" in c]
        assert close_calls, "Expected a gh issue close call"
        assert stats.created_gh == 1


# ---------------------------------------------------------------------------
# _handle_existing_issue — reimported node skip + dry-run close + assignee sync
# ---------------------------------------------------------------------------


class TestHandleExistingIssuePaths:
    """Cover reimported node body skip, dry-run close, and assignee sync."""

    def _call(
        self,
        node: WeaveNode,
        issue: GitHubIssue,
        stats: SyncStats,
        dry_run: bool = False,
        **overrides: Any,
    ) -> None:
        base: dict[str, Any] = {
            "get_edges_for_node": lambda _: [],
            "render_issue_body": lambda *_a, **_k: "",
            "should_update_body": lambda *_a: False,
            "get_labels_for_node": lambda _: [],
            "sync_issue_labels": lambda *_a, **_k: None,
            "gh_cli": lambda *_a, **_k: "",
            "build_close_comment": lambda *_a, **_k: "close",
            "_backfill_gh_issue": lambda *_a, **_k: None,
            "_was_closed_by_weave": lambda *_a: False,
            "extract_human_content": lambda _: "",
            "compose_issue_body": lambda h, w: w,
        }
        base.update(overrides)
        with patch.multiple("weave_gh.phases", **base):
            _handle_existing_issue(
                node,
                issue.number,
                {issue.number: issue},
                {node.id: node},
                "owner/repo",
                "https://github.com/owner/repo",
                stats,
                dry_run=dry_run,
            )

    def test_reimported_node_skips_body_update(self) -> None:
        """Nodes with source=github and no children skip body rendering."""
        node = WeaveNode(
            id="wv-reimp", text="Re-imported", status="active",
            metadata={"source": "github", "gh_issue": 10},
        )
        issue = _issue(10, state="OPEN")
        stats = SyncStats()
        render_calls: list[object] = []

        self._call(
            node, issue, stats,
            render_issue_body=lambda *_a, **_k: render_calls.append(_a) or "",  # type: ignore[func-returns-value]
        )
        assert not render_calls

    def test_dry_run_close_increments_count(self) -> None:
        """Dry-run close increments closed_gh without calling gh_cli."""
        node = _node("wv-dryc", status="done", gh_issue=20)
        issue = _issue(20, state="OPEN")
        stats = SyncStats()
        gh_calls: list[object] = []

        self._call(
            node, issue, stats, dry_run=True,
            gh_cli=lambda *_a, **_k: (gh_calls.append(_a), "")[1],  # type: ignore[func-returns-value]
        )

        assert stats.closed_gh == 1
        close_calls = [c for c in gh_calls if "close" in str(c)]
        assert not close_calls

    def test_assignee_sync_called_when_claimed_by(self) -> None:
        """When node has claimed_by, _sync_assignee is called."""
        node = WeaveNode(
            id="wv-asgn", text="Assigned", status="active",
            metadata={"claimed_by": "alice", "gh_issue": 30},
        )
        issue = _issue(30, state="OPEN")
        stats = SyncStats()
        sync_calls: list[object] = []

        self._call(
            node, issue, stats,
            _sync_assignee=lambda *_a, **_k: (sync_calls.append(_a), False)[1],  # type: ignore[func-returns-value]
        )

        assert len(sync_calls) == 1

    def test_done_node_skips_assignee_sync_even_with_claimed_by(self) -> None:
        """Done nodes should not try to sync a GH assignee from stale claims."""
        node = WeaveNode(
            id="wv-doneasgn", text="Assigned", status="done",
            metadata={"claimed_by": "alice", "gh_issue": 31},
        )
        issue = _issue(31, state="OPEN")
        stats = SyncStats()
        sync_calls: list[object] = []

        self._call(
            node, issue, stats,
            _sync_assignee=lambda *_a, **_k: (sync_calls.append(_a), False)[1],  # type: ignore[func-returns-value]
        )

        assert not sync_calls

    def test_dry_run_body_update_increments_stats(self) -> None:
        """Dry-run body update increments updated_gh without gh_cli call."""
        node = _node("wv-bdyu", status="active", gh_issue=40)
        issue = _issue(40, state="OPEN", body="<!-- WEAVE:BEGIN hash=old -->\nold\n<!-- WEAVE:END -->")
        stats = SyncStats()
        gh_calls: list[object] = []

        self._call(
            node, issue, stats, dry_run=True,
            render_issue_body=lambda *_a, **_k: "<!-- WEAVE:BEGIN hash=new -->\nnew\n<!-- WEAVE:END -->",
            should_update_body=lambda *_a: True,
            extract_human_content=lambda _: "",
            compose_issue_body=lambda h, w: w,
            gh_cli=lambda *_a, **_k: (gh_calls.append(_a), "")[1],  # type: ignore[func-returns-value]
        )

        assert stats.updated_gh == 1
        edit_calls = [c for c in gh_calls if "edit" in str(c)]
        assert not edit_calls


# ---------------------------------------------------------------------------
# sync_github_to_weave — weave:test skip + type/priority parsing + error
# ---------------------------------------------------------------------------


class TestSyncGithubToWeavePaths:
    """Cover weave:test skip, type/priority template parsing, and wv_cli error."""

    def test_weave_test_label_skips_issue(self) -> None:
        """Issues labeled weave:test are skipped."""
        issue = GitHubIssue(
            number=11, title="Internal test", state="OPEN", body="",
            labels=["weave:test"],
        )
        stats = SyncStats()
        sync_github_to_weave([], [issue], "owner/repo", stats, dry_run=True)
        assert stats.created_wv == 0
        assert stats.skipped == 1

    def test_type_and_priority_parsed_from_template(self) -> None:
        """Type and priority from issue template form are added to metadata."""
        body = "### Type\n\nfeature\n\n### Priority\n\nP2 (medium)\n"
        issue = GitHubIssue(
            number=22, title="Feature request", state="OPEN",
            body=body, labels=["weave-synced"],
        )
        stats = SyncStats()
        created_meta: list[dict[str, object]] = []

        def mock_wv(*args: object, **_kw: object) -> str:
            for arg in args:
                if isinstance(arg, str) and arg.startswith("--metadata="):
                    created_meta.append(json.loads(arg[len("--metadata="):]))
            return "wv-new"

        with patch("weave_gh.phases.wv_cli", side_effect=mock_wv):
            sync_github_to_weave([], [issue], "owner/repo", stats)

        assert stats.created_wv == 1
        assert created_meta
        assert created_meta[0].get("type") == "feature"
        assert created_meta[0].get("priority") == 2

    def test_wv_cli_error_is_caught(self) -> None:
        """CalledProcessError from wv_cli is caught and node is not counted."""
        issue = GitHubIssue(
            number=33, title="Failing", state="OPEN", body="",
            labels=["weave-synced"],
        )
        stats = SyncStats()

        with patch(
            "weave_gh.phases.wv_cli",
            side_effect=subprocess.CalledProcessError(1, "wv", stderr="err"),
        ):
            sync_github_to_weave([], [issue], "owner/repo", stats)

        assert stats.created_wv == 0


# ---------------------------------------------------------------------------
# sync_closed_to_weave — Phase 3: close Weave nodes for closed GH issues
# ---------------------------------------------------------------------------


class TestSyncClosedToWeave:
    """sync_closed_to_weave marks Weave nodes done when GH issues are closed."""

    def test_closes_open_weave_node_for_closed_gh_issue(self) -> None:
        """Node with non-done status and closed GH issue gets closed."""
        node = _node("wv-todc", status="active", gh_issue=50)
        issue = _issue(50, state="CLOSED")
        stats = SyncStats()

        with patch("weave_gh.phases.wv_cli") as mock_wv:
            mock_wv.return_value = ""
            sync_closed_to_weave([node], [issue], stats)

        assert stats.closed_wv == 1
        mock_wv.assert_called_once_with(
            "done", "wv-todc", "--skip-verification", "--acknowledge-overlap",
            "--learning=closed via GH issue sync (Phase 3)",
            check=False,
        )

    def test_dry_run_increments_without_wv_call(self) -> None:
        """Dry-run increments closed_wv but does not call wv_cli."""
        node = _node("wv-dcdr", status="todo", gh_issue=51)
        issue = _issue(51, state="CLOSED")
        stats = SyncStats()

        with patch("weave_gh.phases.wv_cli") as mock_wv:
            sync_closed_to_weave([node], [issue], stats, dry_run=True)

        assert stats.closed_wv == 1
        mock_wv.assert_not_called()

    def test_already_done_node_not_closed_again(self) -> None:
        """Nodes already done are not closed again."""
        node = _node("wv-alrd", status="done", gh_issue=52)
        issue = _issue(52, state="CLOSED")
        stats = SyncStats()

        with patch("weave_gh.phases.wv_cli") as mock_wv:
            sync_closed_to_weave([node], [issue], stats)

        assert stats.closed_wv == 0
        mock_wv.assert_not_called()

    def test_open_gh_issue_not_closed(self) -> None:
        """Nodes linked to open GH issues are not closed."""
        node = _node("wv-open", status="active", gh_issue=53)
        issue = _issue(53, state="OPEN")
        stats = SyncStats()

        with patch("weave_gh.phases.wv_cli") as mock_wv:
            sync_closed_to_weave([node], [issue], stats)

        assert stats.closed_wv == 0
        mock_wv.assert_not_called()


# ---------------------------------------------------------------------------
# refresh_parent_body — error paths (lines 665-666, 677)
# ---------------------------------------------------------------------------


class TestRefreshParentBodyErrorPaths:
    """Cover get_repo exception and empty raw body paths."""

    def test_get_repo_exception_returns_false(self) -> None:
        """Returns False when get_repo raises CalledProcessError."""
        parent = _node("wv-repoerr", text="Epic", status="active", gh_issue=100)
        with patch("weave_gh.phases.get_parent", return_value="wv-repoerr"), patch(
            "weave_gh.data.get_weave_nodes", return_value=[parent]
        ), patch(
            "weave_gh.phases.get_repo",
            side_effect=subprocess.CalledProcessError(1, "gh"),
        ):
            result = refresh_parent_body("wv-child")
        assert result is False

    def test_empty_raw_body_returns_false(self) -> None:
        """Returns False when gh issue view returns empty body."""
        parent = _node("wv-emptbod", text="Epic", status="active", gh_issue=200)
        with patch("weave_gh.phases.get_parent", return_value="wv-emptbod"), patch(
            "weave_gh.data.get_weave_nodes", return_value=[parent]
        ), patch(
            "weave_gh.phases.get_repo", return_value="owner/repo"
        ), patch(
            "weave_gh.phases.gh_cli", return_value=""
        ):
            result = refresh_parent_body("wv-child")
        assert result is False
