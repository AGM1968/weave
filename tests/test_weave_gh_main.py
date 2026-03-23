"""Tests for weave_gh.__main__ — CLI entry point and sync orchestration."""

# pylint: disable=missing-class-docstring,missing-function-docstring

from __future__ import annotations

import subprocess
import sys
from typing import Any
from unittest.mock import MagicMock, patch

import pytest

from weave_gh.models import GitHubIssue, WeaveNode
from weave_gh.__main__ import (
    _acquire_sync_lock,
    _run_full_sync,
    main,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _node(node_id: str, status: str = "todo", gh_issue: int | None = None) -> WeaveNode:
    meta: dict[str, Any] = {}
    if gh_issue is not None:
        meta["gh_issue"] = gh_issue
    return WeaveNode(id=node_id, text="Test node", status=status, metadata=meta)


def _issue(number: int, state: str = "OPEN") -> GitHubIssue:
    return GitHubIssue(
        number=number, title="Test issue", state=state, body="",
        labels=["weave-synced"],
    )


def _full_sync_patches(**overrides: Any) -> Any:
    """Return patch.multiple context for _run_full_sync."""
    base: dict[str, Any] = {
        "get_repo": lambda: "owner/repo",
        "get_repo_url": lambda: "https://github.com/owner/repo",
        "ensure_labels": lambda *_a, **_k: None,
        "get_weave_nodes": lambda: [],
        "get_github_issues": lambda *_a: [],
        "sync_weave_to_github": lambda *_a, **_k: [],
        "sync_github_to_weave": lambda *_a, **_k: [],
        "sync_closed_to_weave": lambda *_a, **_k: None,
        "wv_cli": lambda *_a, **_k: "",
        "_acquire_sync_lock": lambda: MagicMock(),
    }
    base.update(overrides)
    return patch.multiple("weave_gh.__main__", **base)


# ---------------------------------------------------------------------------
# _acquire_sync_lock
# ---------------------------------------------------------------------------


class TestAcquireSyncLock:
    def test_acquires_lock_successfully(self, tmp_path: Any) -> None:
        """Lock is acquired when no other process holds it."""
        with patch("weave_gh.__main__.tempfile.gettempdir", return_value=str(tmp_path)):
            fh = _acquire_sync_lock()
        assert fh is not None
        fh.close()  # type: ignore[union-attr]

    def test_exits_when_lock_already_held(self, tmp_path: Any) -> None:
        """Exits with SystemExit when the lock is already held."""
        with patch("weave_gh.__main__.tempfile.gettempdir", return_value=str(tmp_path)), \
             patch("weave_gh.__main__.fcntl.flock", side_effect=OSError("locked")):
            with pytest.raises(SystemExit):
                _acquire_sync_lock()


# ---------------------------------------------------------------------------
# _run_full_sync
# ---------------------------------------------------------------------------


class TestRunFullSync:
    def test_runs_all_three_phases(self) -> None:
        """Full sync calls all 3 phases in order."""
        calls: list[str] = []
        nodes = [_node("wv-a")]
        issues = [_issue(1)]

        with _full_sync_patches(
            get_weave_nodes=lambda: nodes,
            get_github_issues=lambda *_a: issues,
            sync_weave_to_github=(
                lambda *_a, **_k: (calls.append("phase1"), issues)[1]
            ),
            sync_github_to_weave=(
                lambda *_a, **_k: (calls.append("phase2"), nodes)[1]
            ),
            sync_closed_to_weave=(
                lambda *_a, **_k: calls.append("phase3")
            ),
        ):
            _run_full_sync()

        assert calls == ["phase1", "phase2", "phase3"]

    def test_dry_run_skips_wv_sync(self) -> None:
        """Dry-run mode does not call wv_cli('sync')."""
        wv_calls: list[object] = []
        with _full_sync_patches(
            wv_cli=lambda *_a, **_k: wv_calls.append(_a) or "",
        ):
            _run_full_sync(dry_run=True)

        sync_calls = [c for c in wv_calls if c and c[0] == "sync"]
        assert not sync_calls

    def test_non_dry_run_calls_wv_sync(self) -> None:
        """Non-dry-run calls wv_cli('sync') after phases."""
        wv_calls: list[object] = []
        with _full_sync_patches(
            wv_cli=lambda *_a, **_k: wv_calls.append(_a) or "",
        ):
            _run_full_sync(dry_run=False)

        sync_calls = [c for c in wv_calls if c and c[0] == "sync"]
        assert len(sync_calls) == 1

    def test_get_repo_error_exits(self) -> None:
        """Exits if get_repo raises CalledProcessError."""
        with _full_sync_patches(
            get_repo=MagicMock(
                side_effect=subprocess.CalledProcessError(1, "gh")
            ),
        ):
            with pytest.raises(SystemExit):
                _run_full_sync()


# ---------------------------------------------------------------------------
# main() — CLI arg dispatch
# ---------------------------------------------------------------------------


class TestMain:
    def test_refresh_parent_mode(self) -> None:
        """--refresh-parent dispatches to refresh_parent_body."""
        rp_calls: list[object] = []
        with patch.object(
            sys, "argv", ["weave_gh", "--refresh-parent", "wv-epic"]
        ), patch("weave_gh.__main__.refresh_parent_body",
                 side_effect=lambda *_a, **_k: rp_calls.append(_a)):
            main()

        assert len(rp_calls) == 1
        assert rp_calls[0][0] == "wv-epic"

    def test_notify_mode(self) -> None:
        """--notify dispatches to notify()."""
        notify_calls: list[object] = []
        with patch.object(
            sys, "argv", ["weave_gh", "--notify", "wv-abc", "done"]
        ), patch("weave_gh.__main__.notify",
                 side_effect=lambda *_a, **_k: notify_calls.append((_a, _k))):
            main()

        assert len(notify_calls) == 1
        assert notify_calls[0][0][0] == "wv-abc"
        assert notify_calls[0][0][1] == "done"

    def test_notify_with_learning_and_blocker(self) -> None:
        """--notify passes learning and blocker kwargs to notify()."""
        notify_calls: list[tuple[object, ...]] = []
        with patch.object(
            sys, "argv", [
                "weave_gh", "--notify", "wv-xyz", "block",
                "--learning", "some learning",
                "--blocker", "wv-blk",
            ]
        ), patch("weave_gh.__main__.notify",
                 side_effect=lambda *_a, **_k: notify_calls.append((_a, _k))):
            main()

        assert notify_calls[0][1].get("learning") == "some learning"
        assert notify_calls[0][1].get("blocker") == "wv-blk"

    def test_full_sync_mode(self) -> None:
        """Default mode calls _run_full_sync."""
        sync_calls: list[object] = []
        with patch.object(sys, "argv", ["weave_gh"]), patch(
            "weave_gh.__main__._run_full_sync",
            side_effect=lambda *_a, **_k: sync_calls.append(_a),
        ):
            main()

        assert len(sync_calls) == 1

    def test_dry_run_flag_forwarded(self) -> None:
        """--dry-run flag is forwarded to _run_full_sync."""
        sync_calls: list[dict[str, object]] = []
        with patch.object(sys, "argv", ["weave_gh", "--dry-run"]), patch(
            "weave_gh.__main__._run_full_sync",
            side_effect=lambda *, dry_run=False: sync_calls.append({"dry_run": dry_run}),
        ):
            main()

        assert sync_calls[0]["dry_run"] is True
