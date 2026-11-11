"""Tests for weave_gh.__main__ — CLI entry point and sync orchestration."""

# pylint: disable=missing-class-docstring,missing-function-docstring

from __future__ import annotations

import fcntl
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any, Callable, ParamSpec, TypedDict, TypeVar, Unpack, overload
from unittest.mock import MagicMock, patch

import pytest

from weave_gh.models import GitHubIssue, Mode, WeaveNode
from weave_gh.__main__ import (
    EXIT_INTEGRITY,
    EXIT_INTERNAL,
    _acquire_sync_lock,
    _entry,
    _log_mode_banner,
    _run_full_sync,
    main,
)
from weave_gh import data
from weave_gh.data import NodeFetchError
from weave_gh import __main__ as entry
from weave_gh.data import HotZoneUnsafeError


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_T = TypeVar("_T")
_P = ParamSpec("_P")
_R = TypeVar("_R")
_A = TypeVar("_A")
_B = TypeVar("_B")
_C = TypeVar("_C")


def _callback(_contract: Callable[_P, object], callback: Callable[_P, _R]) -> Callable[_P, _R]:
    """Give a fake the real callee's parameter contract without wrapping it."""
    return callback


@overload
def _positional_callback(
    _contract: Callable[[_A], object], callback: Callable[[_A], _R]
) -> Callable[[_A], _R]: ...


@overload
def _positional_callback(
    _contract: Callable[[_A, _B], object], callback: Callable[[_A, _B], _R]
) -> Callable[[_A, _B], _R]: ...


@overload
def _positional_callback(
    _contract: Callable[[_A, _B, _C], object], callback: Callable[[_A, _B, _C], _R]
) -> Callable[[_A, _B, _C], _R]: ...


def _positional_callback(_contract: object, callback: _T) -> _T:
    """Context for positional-only fakes, whose parameter names intentionally differ."""
    return callback


class _FullSyncOptions(TypedDict, total=False):
    """Keyword contract of _run_full_sync, retaining each field's own type."""

    dry_run: bool
    mode: Mode
    focus_node_id: str | None


def _logged(log: list[Any], entry: object, result: _T) -> _T:
    """Record entry in log and return result: the side effect a stub lambda needs."""
    log.append(entry)
    return result



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
        "ensure_labels": _callback(entry.ensure_labels, lambda *_a, **_k: None),
        "get_weave_nodes": lambda: [],
        "get_github_issues": _positional_callback(entry.get_github_issues, lambda *_a: []),
        "confirm_mapped_issues_absent": _positional_callback(entry.confirm_mapped_issues_absent, lambda *_a: None),
        "_check_hot_zone": lambda: "/nonexistent-zone/brain.db",
        "sync_weave_to_github": _callback(entry.sync_weave_to_github, lambda *_a, **_k: []),
        "sync_github_to_weave": _callback(entry.sync_github_to_weave, lambda *_a, **_k: []),
        "sync_closed_to_weave": _callback(entry.sync_closed_to_weave, lambda *_a, **_k: None),
        "wv_cli": _callback(entry.wv_cli, lambda *_a, **_k: ""),
        "_acquire_sync_lock": MagicMock,
    }
    base.update(overrides)
    return patch.multiple("weave_gh.__main__", **base)


# ---------------------------------------------------------------------------
# _acquire_sync_lock
# ---------------------------------------------------------------------------


class TestAcquireSyncLock:
    def test_acquires_lock_successfully(self, tmp_path: Any) -> None:
        """Lock is acquired when no other process holds it, beside the graph."""
        fh = _acquire_sync_lock(tmp_path)
        assert fh is not None
        assert (tmp_path / "sync.lock").read_text(encoding="utf-8") == str(os.getpid())
        fh.close()

    def test_contender_does_not_truncate_live_holder_pid(self, tmp_path: Any) -> None:
        """A losing contender must not blank the live holder PID file."""
        lock_path = tmp_path / "sync.lock"

        with open(lock_path, "w", encoding="utf-8") as holder:
            holder.write(str(os.getpid()))
            holder.flush()
            fcntl.flock(holder, fcntl.LOCK_EX | fcntl.LOCK_NB)

            with pytest.raises(SystemExit):
                _acquire_sync_lock(tmp_path)

            assert lock_path.read_text(encoding="utf-8") == str(os.getpid())

    def test_exits_when_lock_already_held(self, tmp_path: Any) -> None:
        """Exits with SystemExit when the lock is already held."""
        with patch("weave_gh.__main__.fcntl.flock", side_effect=OSError("locked")):
            with pytest.raises(SystemExit):
                _acquire_sync_lock(tmp_path)

    def test_syncs_of_different_graphs_do_not_exclude_each_other(self, tmp_path: Any) -> None:
        """wv-0ae4cb: one machine-wide lock made unrelated repositories' syncs
        refuse each other, and the refusal read as a pending network step."""
        zone_a, zone_b = tmp_path / "a", tmp_path / "b"
        zone_a.mkdir()
        zone_b.mkdir()
        held = _acquire_sync_lock(zone_a)
        try:
            other = _acquire_sync_lock(zone_b)
            other.close()
            with pytest.raises(SystemExit):
                _acquire_sync_lock(zone_a)
        finally:
            held.close()

    def test_unopenable_lock_is_a_clean_refusal(self, tmp_path: Any, caplog: Any) -> None:
        """A lock path that cannot be opened exits 1 with a message, not a traceback."""
        with pytest.raises(SystemExit) as exc:
            _acquire_sync_lock(tmp_path / "missing-zone")
        assert exc.value.code == 1
        assert "cannot open the sync lock" in caplog.text

    def test_full_sync_locks_beside_the_resolved_graph(self) -> None:
        """_run_full_sync takes the lock in the directory of the DB it syncs."""
        lock = MagicMock()
        with _full_sync_patches(_acquire_sync_lock=lock):
            _run_full_sync(mode=Mode.FULL)
        lock.assert_called_once_with(Path("/nonexistent-zone"))


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
            get_github_issues=_positional_callback(entry.get_github_issues, lambda *_a: issues),
            sync_weave_to_github=(
                _callback(entry.sync_weave_to_github, lambda *_a, **_k: _logged(calls, "phase1", issues))
            ),
            sync_github_to_weave=(
                _callback(entry.sync_github_to_weave, lambda *_a, **_k: _logged(calls, "phase2", nodes))
            ),
            sync_closed_to_weave=(
                _callback(entry.sync_closed_to_weave, lambda *_a, **_k: calls.append("phase3"))
            ),
        ):
            _run_full_sync()

        assert calls == ["phase1", "phase2", "phase3"]

    def test_dry_run_skips_wv_sync(self) -> None:
        """Dry-run mode does not call wv_cli('sync')."""
        wv_calls: list[tuple[Any, ...]] = []
        with _full_sync_patches(
            wv_cli=_callback(entry.wv_cli, lambda *_a, **_k: _logged(wv_calls, _a, "")),
        ):
            _run_full_sync(dry_run=True)

        sync_calls = [c for c in wv_calls if c and c[0] == "sync"]
        assert not sync_calls

    def test_non_dry_run_calls_wv_sync(self) -> None:
        """Non-dry-run calls wv_cli('sync') after phases."""
        wv_calls: list[tuple[Any, ...]] = []
        with _full_sync_patches(
            wv_cli=_callback(entry.wv_cli, lambda *_a, **_k: _logged(wv_calls, _a, "")),
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

    @pytest.mark.parametrize(
        ("count", "numbers", "headroom", "code"),
        [
            # the old fixed limit: 200 issues silently dropped
            (5200, list(range(5000, 0, -1)), 500, EXIT_INTEGRITY),
            # list fills the limit: may be truncated
            (3, [3, 2, 1], 0, EXIT_INTEGRITY),
            # right length, #1 missing behind a repeated #2 (wv-820b76)
            (2, [2, 2], 500, EXIT_INTEGRITY),
            # gh itself failed: a transport failure, kept non-fatal upstream
            (subprocess.CalledProcessError(1, "gh"), [1], 500, 1),
        ],
    )
    def test_incomplete_issue_fetch_aborts_before_any_write(
        self, count: Any, numbers: list[int], headroom: int, code: int
    ) -> None:
        """wv-0d2d25: an issue list that cannot be proven complete stops the
        sync before ensure_labels or any phase runs. An integrity refusal exits
        EXIT_INTEGRITY, which wv sync --gh fails on; a transport failure exits 1."""

        def fake_gh(*args: str, **_k: Any) -> str:
            if args[:2] == ("api", "graphql"):
                if isinstance(count, BaseException):
                    raise count
                return str(count)
            assert args[:2] == ("issue", "list"), args
            return json.dumps([
                {"number": n, "title": f"t{n}", "state": "CLOSED", "body": "",
                 "labels": [], "assignees": []}
                for n in numbers
            ])

        writes: list[str] = []
        with _full_sync_patches(
            get_github_issues=data.get_github_issues,
            ensure_labels=_callback(entry.ensure_labels, lambda *_a, **_k: writes.append("labels")),
            sync_weave_to_github=_callback(entry.sync_weave_to_github, lambda *_a, **_k: _logged(writes, "phase1", [])),
            sync_github_to_weave=_callback(entry.sync_github_to_weave, lambda *_a, **_k: _logged(writes, "phase2", [])),
            sync_closed_to_weave=_callback(entry.sync_closed_to_weave, lambda *_a, **_k: writes.append("phase3")),
        ), patch("weave_gh.data.gh_cli", side_effect=fake_gh), \
                patch("weave_gh.data._GH_ISSUE_HEADROOM", headroom):
            with pytest.raises(SystemExit) as exc:
                _run_full_sync(mode=Mode.FULL)

        assert exc.value.code == code
        assert writes == []

    @pytest.mark.parametrize(
        ("view", "code"),
        [
            # the omitted mapped issue is in the repository: wrong issue set
            (subprocess.CompletedProcess(
                [], 0, '{"url": "https://github.com/owner/repo/issues/9"}', ""
            ), EXIT_INTEGRITY),
            # the lookup itself failed: transport, kept non-fatal upstream
            (subprocess.CompletedProcess([], 1, "", "error connecting"), 1),
        ],
    )
    def test_omitted_mapped_issue_aborts_before_any_write(
        self, view: Any, code: int
    ) -> None:
        """wv-e869e3: equal counts with a swapped member drop a mapped issue
        from the list; Phase 1 would create its replacement. The lookup runs
        after both fetches and before ensure_labels."""

        mapped = WeaveNode("wv-aaa9", "t", "todo", {"gh_issue": 9})
        writes: list[str] = []
        with _full_sync_patches(
            get_weave_nodes=lambda: [mapped],
            get_github_issues=_positional_callback(entry.get_github_issues, lambda *_a: [_issue(1)]),
            confirm_mapped_issues_absent=data.confirm_mapped_issues_absent,
            ensure_labels=_callback(entry.ensure_labels, lambda *_a, **_k: writes.append("labels")),
            sync_weave_to_github=_callback(entry.sync_weave_to_github, lambda *_a, **_k: _logged(writes, "phase1", [])),
        ), patch("weave_gh.data._run", return_value=view):
            with pytest.raises(SystemExit) as exc:
                _run_full_sync(mode=Mode.FULL)

        assert exc.value.code == code
        assert writes == []

    @pytest.mark.parametrize("fail_on_call", [1, 2])
    def test_failed_node_fetch_aborts_before_next_write(self, fail_on_call: int) -> None:
        """wv-0d2d25: a failed wv list exits EXIT_INTEGRITY instead of syncing an empty
        graph. Call 1 is the initial fetch (nothing written yet); call 2 is the
        re-fetch before Phase 2, which must not run against an empty list."""

        fetches = {"n": 0}

        def nodes() -> list[WeaveNode]:
            fetches["n"] += 1
            if fetches["n"] == fail_on_call:
                raise NodeFetchError("wv list failed")
            return [_node("wv-a")]

        writes: list[str] = []
        with _full_sync_patches(
            get_weave_nodes=nodes,
            ensure_labels=_callback(entry.ensure_labels, lambda *_a, **_k: writes.append("labels")),
            sync_weave_to_github=_callback(entry.sync_weave_to_github, lambda *_a, **_k: _logged(writes, "phase1", [])),
            sync_github_to_weave=_callback(entry.sync_github_to_weave, lambda *_a, **_k: _logged(writes, "phase2", [])),
            sync_closed_to_weave=_callback(entry.sync_closed_to_weave, lambda *_a, **_k: writes.append("phase3")),
        ):
            with pytest.raises(SystemExit) as exc:
                _run_full_sync(mode=Mode.FULL)

        assert exc.value.code == EXIT_INTEGRITY
        assert writes == ([] if fail_on_call == 1 else ["labels", "phase1"])

    def test_fast_mode_skips_phase2_and_phase3(self) -> None:
        """FAST mode runs only Phase 1; Phases 2 and 3 are bypassed."""
        calls: list[str] = []
        nodes = [_node("wv-a")]
        issues = [_issue(1)]
        with _full_sync_patches(
            get_weave_nodes=lambda: nodes,
            get_github_issues=_positional_callback(entry.get_github_issues, lambda *_a: issues),
            sync_weave_to_github=(
                _callback(entry.sync_weave_to_github, lambda *_a, **_k: _logged(calls, "phase1", issues))
            ),
            sync_github_to_weave=(
                _callback(entry.sync_github_to_weave, lambda *_a, **_k: _logged(calls, "phase2", nodes))
            ),
            sync_closed_to_weave=(
                _callback(entry.sync_closed_to_weave, lambda *_a, **_k: calls.append("phase3"))
            ),
        ):
            _run_full_sync(mode=Mode.FAST, focus_node_id="wv-a")

        assert calls == ["phase1"]

    def test_fast_mode_forwards_focus_node_to_phase1(self) -> None:
        """FAST mode passes mode + focus_node_id into sync_weave_to_github."""
        captured: dict[str, object] = {}

        def _capture(*_a: Any, **kw: Any) -> list[Any]:
            captured.update(kw)
            return []

        with _full_sync_patches(
            get_weave_nodes=lambda: [_node("wv-a")],
            get_github_issues=_positional_callback(entry.get_github_issues, lambda *_a: []),
            sync_weave_to_github=_capture,
        ):
            _run_full_sync(mode=Mode.FAST, focus_node_id="wv-a")

        assert captured.get("mode") is Mode.FAST
        assert captured.get("focus_node_id") == "wv-a"

    def test_repair_mode_runs_all_phases(self) -> None:
        """REPAIR mode runs all three phases like FULL."""
        calls: list[str] = []
        with _full_sync_patches(
            get_weave_nodes=lambda: [_node("wv-a")],
            get_github_issues=_positional_callback(entry.get_github_issues, lambda *_a: [_issue(1)]),
            sync_weave_to_github=(
                _callback(entry.sync_weave_to_github, lambda *_a, **_k: _logged(calls, "phase1", [_issue(1)]))
            ),
            sync_github_to_weave=(
                _callback(entry.sync_github_to_weave, lambda *_a, **_k: _logged(calls, "phase2", [_node("wv-a")]))
            ),
            sync_closed_to_weave=(
                _callback(entry.sync_closed_to_weave, lambda *_a, **_k: calls.append("phase3"))
            ),
        ):
            _run_full_sync(mode=Mode.REPAIR)

        assert calls == ["phase1", "phase2", "phase3"]


# ---------------------------------------------------------------------------
# main() — CLI arg dispatch
# ---------------------------------------------------------------------------


class TestMain:
    def test_refresh_parent_mode(self) -> None:
        """--refresh-parent dispatches to refresh_parent_body."""
        rp_calls: list[tuple[Any, ...]] = []
        with patch.object(
            sys, "argv", ["weave_gh", "--refresh-parent", "wv-epic"]
        ), patch("weave_gh.__main__.refresh_parent_body",
                 side_effect=_callback(entry.refresh_parent_body, lambda *_a, **_k: rp_calls.append(_a))):
            main()

        assert len(rp_calls) == 1
        assert rp_calls[0][0] == "wv-epic"

    def test_notify_mode(self) -> None:
        """--notify dispatches to notify()."""
        notify_calls: list[tuple[Any, ...]] = []
        with patch.object(
            sys, "argv", ["weave_gh", "--notify", "wv-abc", "done"]
        ), patch("weave_gh.__main__.notify",
                 side_effect=_callback(entry.notify, lambda *_a, **_k: notify_calls.append((_a, _k)))):
            main()

        assert len(notify_calls) == 1
        assert notify_calls[0][0][0] == "wv-abc"
        assert notify_calls[0][0][1] == "done"

    def test_notify_with_learning_and_blocker(self) -> None:
        """--notify passes learning and blocker kwargs to notify()."""
        notify_calls: list[tuple[tuple[Any, ...], dict[str, Any]]] = []
        with patch.object(
            sys, "argv", [
                "weave_gh", "--notify", "wv-xyz", "block",
                "--learning", "some learning",
                "--blocker", "wv-blk",
            ]
        ), patch("weave_gh.__main__.notify",
                 side_effect=_callback(entry.notify, lambda *_a, **_k: notify_calls.append((_a, _k)))):
            main()

        assert notify_calls[0][1].get("learning") == "some learning"
        assert notify_calls[0][1].get("blocker") == "wv-blk"

    def test_full_sync_mode(self) -> None:
        """Default mode calls _run_full_sync."""
        sync_calls: list[object] = []

        def record_sync(*args: object, **_kwargs: Unpack[_FullSyncOptions]) -> None:
            sync_calls.append(args)

        with patch.object(sys, "argv", ["weave_gh"]), patch(
            "weave_gh.__main__._run_full_sync",
            side_effect=record_sync,
        ):
            main()

        assert len(sync_calls) == 1

    def test_dry_run_flag_forwarded(self) -> None:
        """--dry-run flag is forwarded to _run_full_sync."""
        sync_calls: list[_FullSyncOptions] = []

        def record_sync(**kwargs: Unpack[_FullSyncOptions]) -> None:
            sync_calls.append(kwargs)

        with patch.object(sys, "argv", ["weave_gh", "--dry-run"]), patch(
            "weave_gh.__main__._run_full_sync",
            side_effect=record_sync,
        ):
            main()

        assert sync_calls[0]["dry_run"] is True
        assert sync_calls[0]["mode"] is Mode.FAST

    def test_mode_flag_parsed(self) -> None:
        """--mode=fast|full|repair is parsed and forwarded to _run_full_sync."""
        for value, expected in [
            ("fast", Mode.FAST),
            ("full", Mode.FULL),
            ("repair", Mode.REPAIR),
        ]:
            sync_calls: list[Mode] = []

            def record_mode(  # pylint: disable=dangerous-default-value  # Early-bind this case's list.
                calls: list[Mode] = sync_calls, **kwargs: Unpack[_FullSyncOptions]
            ) -> None:
                calls.append(kwargs["mode"])

            with patch.object(sys, "argv", ["weave_gh", "--mode", value]), patch(
                "weave_gh.__main__._run_full_sync",
                side_effect=record_mode,
            ):
                main()
            assert sync_calls == [expected]

    def test_mode_invalid_value_rejected(self) -> None:
        """Invalid --mode values are rejected by argparse with SystemExit."""
        with patch.object(sys, "argv", ["weave_gh", "--mode", "turbo"]):
            with pytest.raises(SystemExit):
                main()

    def test_default_mode_is_fast(self) -> None:
        """Omitting --mode passes Mode.FAST to _run_full_sync."""
        sync_calls: list[Mode] = []

        def record_mode(  # pylint: disable=dangerous-default-value  # Early-bind this case's list.
            calls: list[Mode] = sync_calls, **kwargs: Unpack[_FullSyncOptions]
        ) -> None:
            calls.append(kwargs["mode"])

        with patch.object(sys, "argv", ["weave_gh"]), patch(
            "weave_gh.__main__._run_full_sync",
            side_effect=record_mode,
        ):
            main()
        assert sync_calls == [Mode.FAST]

    def test_node_flag_forwarded(self) -> None:
        """--node=<id> is forwarded as focus_node_id to _run_full_sync."""
        sync_calls: list[_FullSyncOptions] = []

        def record_sync(**kwargs: Unpack[_FullSyncOptions]) -> None:
            sync_calls.append(kwargs)

        with patch.object(sys, "argv", ["weave_gh", "--mode", "fast", "--node", "wv-abcd12"]), patch(
            "weave_gh.__main__._run_full_sync",
            side_effect=record_sync,
        ):
            main()
        assert sync_calls[0]["focus_node_id"] == "wv-abcd12"
        assert sync_calls[0]["mode"] is Mode.FAST

    def test_focus_node_falls_back_to_wv_active_env(self) -> None:
        """With no --node flag, $WV_ACTIVE supplies the focus."""
        sync_calls: list[_FullSyncOptions] = []

        def record_sync(**kwargs: Unpack[_FullSyncOptions]) -> None:
            sync_calls.append(kwargs)

        with patch.object(sys, "argv", ["weave_gh", "--mode", "fast"]), patch.dict(
            os.environ, {"WV_ACTIVE": "wv-deadbe"}, clear=False
        ), patch(
            "weave_gh.__main__._run_full_sync",
            side_effect=record_sync,
        ):
            main()
        assert sync_calls[0]["focus_node_id"] == "wv-deadbe"


# ---------------------------------------------------------------------------
# _log_mode_banner
# ---------------------------------------------------------------------------


class TestLogModeBanner:
    def test_fast_emits_no_banner(self, caplog: Any) -> None:
        caplog.set_level("INFO", logger="weave-sync")
        _log_mode_banner(Mode.FAST)
        assert caplog.text == ""

    def test_full_emits_banner(self, caplog: Any) -> None:
        caplog.set_level("INFO", logger="weave-sync")
        _log_mode_banner(Mode.FULL)
        assert "FULL sync" in caplog.text
        assert "--mode=fast" in caplog.text

    def test_repair_emits_banner(self, caplog: Any) -> None:
        caplog.set_level("INFO", logger="weave-sync")
        _log_mode_banner(Mode.REPAIR)
        assert "REPAIR sync" in caplog.text


# ---------------------------------------------------------------------------
# _entry
# ---------------------------------------------------------------------------


class TestEntry:
    """wv-e869e3: only a failed gh/wv command keeps exit 1, which wv sync --gh
    reads as a pending network step. Anything else exits EXIT_INTERNAL."""

    @pytest.mark.parametrize(
        "error", [ValueError("bad gh_issue"), KeyError("number"), TypeError("x")]
    )
    def test_unexpected_exception_exits_internal(self, error: Exception) -> None:
        with patch("weave_gh.__main__.main", side_effect=error), \
                pytest.raises(SystemExit) as exc:
            _entry()
        assert exc.value.code == EXIT_INTERNAL

    @pytest.mark.parametrize(
        "error", [subprocess.CalledProcessError(1, "gh"), OSError("no gh")]
    )
    def test_command_failure_propagates(self, error: Exception) -> None:
        with patch("weave_gh.__main__.main", side_effect=error), \
                pytest.raises(type(error)):
            _entry()

    def test_exit_codes_pass_through(self) -> None:
        with patch("weave_gh.__main__.main", side_effect=SystemExit(EXIT_INTEGRITY)), \
                pytest.raises(SystemExit) as exc:
            _entry()
        assert exc.value.code == EXIT_INTEGRITY

    def test_exit_codes_are_distinct(self) -> None:
        assert len({0, 1, EXIT_INTEGRITY, EXIT_INTERNAL}) == 4


class TestCheckHotZone:  # pylint: disable=too-few-public-methods
    """wv-80be32: a direct python -m weave_gh refuses an unsafe hot-zone base
    before any GitHub write, like wv does before weave_gh starts."""

    def test_unsafe_base_aborts_before_any_write(self) -> None:

        writes: list[str] = []
        with _full_sync_patches(
            _check_hot_zone=entry._check_hot_zone,  # pylint: disable=protected-access  # noqa: SLF001
            get_github_issues=_positional_callback(entry.get_github_issues, lambda *_a: _logged(writes, "fetch", [])),
            ensure_labels=_callback(entry.ensure_labels, lambda *_a, **_k: writes.append("labels")),
        ), patch(
            "weave_gh.__main__._resolve_db_path",
            side_effect=HotZoneUnsafeError("refusing to use hot-zone base /tmp/x"),
        ):
            with pytest.raises(SystemExit) as exc:
                _run_full_sync(mode=Mode.FULL)
        assert exc.value.code == EXIT_INTEGRITY
        assert writes == []
