"""Focused tests for shared runtime startup/bootstrap lifecycle."""
from __future__ import annotations

import json
import subprocess
from pathlib import Path
from typing import Any, cast

from runtime.services.bootstrap_lifecycle import BootstrapWvClient
from runtime.services.bootstrap_lifecycle import RuntimeBootstrapService
from runtime.session import Session


class _FakeWv:
    def __init__(self) -> None:
        self.updated: list[tuple[str, dict[str, object]]] = []
        self._breadcrumbs = ""

    def status_counts(self) -> dict[str, object]:
        return {"active": 2, "ready": 5, "blocked": 1, "pending_close": 0}

    def list_active(self) -> list[dict[str, str]]:
        return [{"id": "wv-123abc", "text": "carryover task", "status": "active"}]

    def update(self, node_id: str, **kwargs: object) -> dict[str, str]:
        self.updated.append((node_id, dict(kwargs)))
        return {"id": node_id, "status": "todo"}

    def breadcrumbs(self, action: str = "show", *, message: str | None = None) -> str:
        assert action == "show"
        assert message is None
        return self._breadcrumbs


def _load_entries(path: Path) -> list[dict[str, Any]]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def test_record_session_start_writes_event(tmp_path: Path) -> None:
    session = Session.new(tmp_path)
    service = RuntimeBootstrapService(
        cast(BootstrapWvClient, _FakeWv()),
        workspace=tmp_path,
        wv_bin="wv",
        load_policy=lambda: "LOW",
    )

    service.record_session_start(session, model="claude-sonnet-4-6", provider="anthropic")

    entry = _load_entries(session.path)[0]
    metadata = entry["metadata"]
    assert metadata["event_type"] == "session_start"
    assert metadata["model"] == "claude-sonnet-4-6"
    assert metadata["provider"] == "anthropic"
    assert metadata["graph_active"] == 2
    assert metadata["graph_ready"] == 5
    assert metadata["graph_blocked"] == 1
    assert metadata["context_load_policy"] == "LOW"


def test_bootstrap_graph_prefers_make_target_and_resets_stale_nodes(tmp_path: Path) -> None:
    session = Session.new(tmp_path)
    wv = _FakeWv()
    calls: list[list[str]] = []

    def _runner(*args: object, **kwargs: object) -> subprocess.CompletedProcess[str]:
        command = list(cast(list[str], args[0]))
        calls.append(command)
        assert kwargs["cwd"] == tmp_path
        return subprocess.CompletedProcess(command, 0, stdout="Already up to date. Work: 0 active, 5 ready, 5 blocked.\n", stderr="")

    service = RuntimeBootstrapService(
        cast(BootstrapWvClient, wv),
        workspace=tmp_path,
        wv_bin="wv",
        load_policy=lambda: "MEDIUM",
        runner=_runner,
    )

    messages = service.bootstrap_graph(session)

    assert calls == [["make", "-s", "wv-bootstrap"]]
    assert messages[0] == "Graph: Already up to date. Work: 0 active, 5 ready, 5 blocked."
    assert "Reset inherited node wv-123abc" in messages[1]
    assert wv.updated == [("wv-123abc", {"status": "todo", "remove_key": "claimed_by"})]
    entries = _load_entries(session.path)
    assert entries[0]["metadata"]["event_type"] == "bootstrap"


def test_bootstrap_graph_falls_back_to_direct_wv_status(tmp_path: Path) -> None:
    session = Session.new(tmp_path)
    wv = _FakeWv()
    calls: list[list[str]] = []

    def _runner(*args: object, **kwargs: object) -> subprocess.CompletedProcess[str]:
        command = list(cast(list[str], args[0]))
        calls.append(command)
        if command[:2] == ["make", "-s"]:
            raise FileNotFoundError("make not found")
        if command == ["wv", "load"]:
            return subprocess.CompletedProcess(command, 0, stdout="", stderr="")
        if command == ["wv", "status"]:
            return subprocess.CompletedProcess(command, 0, stdout="Work: 0 active, 4 ready, 2 blocked.\n", stderr="")
        raise AssertionError(f"unexpected command: {command}")

    service = RuntimeBootstrapService(
        cast(BootstrapWvClient, wv),
        workspace=tmp_path,
        wv_bin="wv",
        load_policy=lambda: "HIGH",
        runner=_runner,
    )

    messages = service.bootstrap_graph(session)

    assert calls == [["make", "-s", "wv-bootstrap"], ["wv", "load"], ["wv", "status"]]
    assert messages[0] == "Graph: Work: 0 active, 4 ready, 2 blocked."


def test_on_session_start_records_recovery_and_breadcrumbs(tmp_path: Path) -> None:
    session = Session.new(tmp_path)
    wv = _FakeWv()
    wv._breadcrumbs = "Resume task wv-123abc"

    def _runner(*args: object, **kwargs: object) -> subprocess.CompletedProcess[str]:
        command = list(cast(list[str], args[0]))
        assert kwargs["cwd"] == tmp_path
        if command == ["wv", "recover", "--auto"]:
            return subprocess.CompletedProcess(command, 0, stdout="Recovered journal\n", stderr="")
        raise AssertionError(f"unexpected command: {command}")

    service = RuntimeBootstrapService(
        cast(BootstrapWvClient, wv),
        workspace=tmp_path,
        wv_bin="wv",
        load_policy=lambda: "LOW",
        runner=_runner,
    )

    messages = service.on_session_start(session)

    assert messages == [
        "Recovered from previous session: Recovered journal",
        "Prior session:\nResume task wv-123abc",
    ]
    entries = _load_entries(session.path)
    event_types = [entry["metadata"]["event_type"] for entry in entries]
    assert event_types == ["crash_recovery", "breadcrumbs"]
