"""Focused tests for shared runtime session lifecycle policy."""
from __future__ import annotations

import subprocess
from pathlib import Path
from typing import Any, cast

from runtime.services.session_lifecycle import (
    QuitDecision,
    RuntimeSessionLifecycle,
    SessionLifecycleWvClient,
)
from runtime.session import Session
from runtime.wv_client import WvError


class _FakeWv:
    def __init__(self) -> None:
        self.updated: list[tuple[str, dict[str, object]]] = []
        self.saved_breadcrumbs: list[str] = []
        self.sync_calls: list[bool] = []
        self.active_nodes: list[dict[str, object]] = [
            {"id": "wv-123abc", "text": "carryover task", "status": "active"},
        ]

    def list_active(self) -> list[dict[str, object]]:
        return list(self.active_nodes)

    def update(self, node_id: str, **kwargs: object) -> dict[str, Any]:
        self.updated.append((node_id, dict(kwargs)))
        return {"id": node_id, "status": "todo"}

    def breadcrumbs(self, action: str = "show", *, message: str | None = None) -> str:
        if action == "save" and message:
            self.saved_breadcrumbs.append(message)
        return ""

    def sync(self, *, gh: bool = True) -> dict[str, Any]:
        self.sync_calls.append(gh)
        if gh:
            raise WvError("gh sync failed")
        return {"ok": True}


def test_start_new_session_records_start(tmp_path: Path) -> None:
    recorded: list[Path] = []
    current = Session.new(tmp_path)
    lifecycle = RuntimeSessionLifecycle(
        cast(SessionLifecycleWvClient, _FakeWv()),
        workspace=tmp_path,
        record_session_start=lambda session: recorded.append(cast(Session, session).path),
    )

    transition = lifecycle.start_new_session(current)

    assert transition.session is not None
    assert transition.clear_chat is True
    assert transition.messages == []
    assert transition.notice.startswith("Started new session:")
    assert recorded == [transition.session.path]


def test_continue_session_returns_saved_history(tmp_path: Path) -> None:
    current = Session.new(tmp_path)
    saved = Session.new(tmp_path)
    saved.append(cast(Any, type("Msg", (), {"role": "user", "content": "saved", "tool_calls": [], "metadata": {}})()), 0)

    lifecycle = RuntimeSessionLifecycle(
        cast(SessionLifecycleWvClient, _FakeWv()),
        workspace=tmp_path,
        record_session_start=lambda _session: None,
    )

    transition = lifecycle.continue_session(current, str(saved.path))

    assert transition.session is not None
    assert len(transition.messages) == 1
    assert str(transition.messages[0].content) == "saved"
    assert "Continued session:" in transition.notice


def test_quit_hygiene_warns_on_dirty_graph(tmp_path: Path) -> None:
    lifecycle = RuntimeSessionLifecycle(
        cast(SessionLifecycleWvClient, _FakeWv()),
        workspace=tmp_path,
        record_session_start=lambda _session: None,
    )

    def _git_output(args: list[str]) -> str | None:
        mapping = {
            ("rev-parse", "--show-toplevel"): str(tmp_path),
            ("status", "--porcelain"): " M runtime/app.py\n M .weave/state.sql",
            ("rev-list", "--count", "@{u}..HEAD"): "0",
        }
        return mapping.get(tuple(args))

    state = lifecycle.quit_hygiene_state(_git_output)
    assert state is not None
    assert state[0] == "warn"
    assert "wv sync --gh" in state[1]


def test_decide_quit_blocks_or_warns_then_exits(tmp_path: Path) -> None:
    lifecycle = RuntimeSessionLifecycle(
        cast(SessionLifecycleWvClient, _FakeWv()),
        workspace=tmp_path,
        record_session_start=lambda _session: None,
    )

    def _clean_git(_args: list[str]) -> str | None:
        return None

    first = lifecycle.decide_quit(
        agent_running=True,
        quit_warning_armed=False,
        git_output=_clean_git,
    )
    assert isinstance(first, QuitDecision)
    assert first.warning_armed is True
    assert first.exit_requested is False

    second = lifecycle.decide_quit(
        agent_running=True,
        quit_warning_armed=True,
        git_output=_clean_git,
    )
    assert second.exit_requested is True
    assert second.handoff_active_node is True


def test_handoff_active_node_releases_claim_and_saves_breadcrumb(tmp_path: Path) -> None:
    wv = _FakeWv()
    lifecycle = RuntimeSessionLifecycle(
        cast(SessionLifecycleWvClient, wv),
        workspace=tmp_path,
        record_session_start=lambda _session: None,
    )

    lifecycle.handoff_active_node()

    assert wv.updated == [("wv-123abc", {"remove_key": "claimed_by"})]
    assert wv.saved_breadcrumbs
    assert "wv-123abc" in wv.saved_breadcrumbs[-1]


def test_run_session_end_falls_back_to_local_sync(tmp_path: Path) -> None:
    wv = _FakeWv()

    def _runner(*args: object, **kwargs: object) -> subprocess.CompletedProcess[str]:
        command = list(cast(list[str], args[0]))
        assert kwargs["cwd"] == tmp_path
        return subprocess.CompletedProcess(command, 0, stdout="", stderr="wv-close: sync failed")

    calls: list[str] = []
    lifecycle = RuntimeSessionLifecycle(
        cast(SessionLifecycleWvClient, wv),
        workspace=tmp_path,
        record_session_start=lambda _session: None,
        runner=_runner,
    )

    messages = lifecycle.run_session_end(lambda: calls.append("compliance"))

    assert calls == ["compliance"]
    assert wv.sync_calls == [True, False]
    assert messages == [
        "wv-close: sync failed",
        "Graph synced locally (GH sync failed).",
    ]
