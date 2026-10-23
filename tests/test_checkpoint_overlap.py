"""Checkpoint/operation overlap measurement.

The measurement exists because a checkpoint moving HEAD mid-operation has been
diagnosed from scratch more than once. It is only worth having if it separates
the two overlap kinds: a mutating command encloses the checkpoint it caused,
and counting that as a collision reports ~100% while saying nothing.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from typing import Any
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "profiling"))

from checkpoint_overlap import classification, report  # noqa: E402  # pylint: disable=wrong-import-position


def _git(repo: Path, *argv: str) -> None:
    subprocess.run(["git", *argv], cwd=repo, check=True, capture_output=True)


@pytest.fixture()
def repo_with_checkpoint(tmp_path: Path) -> tuple[Path, int]:
    """A repository whose HEAD commit is an auto-checkpoint, with its timestamp."""
    repo = tmp_path / "repo"
    repo.mkdir()
    _git(repo, "init", "-q")
    _git(repo, "config", "user.email", "t@t")
    _git(repo, "config", "user.name", "t")
    (repo / "f.txt").write_text("x", encoding="utf-8")
    _git(repo, "add", "-A")
    _git(repo, "-c", "core.hooksPath=/dev/null", "commit", "-qm", "chore(weave): auto-checkpoint 12:00")
    stamp = subprocess.run(["git", "log", "-1", "--format=%ct"], cwd=repo,
                           capture_output=True, text=True, check=True).stdout.strip()
    return repo, int(stamp)


def _log(path: Path, rows: list[dict[str, Any]]) -> Path:
    path.write_text("\n".join(json.dumps(r) for r in rows) + "\n", encoding="utf-8")
    return path


class TestClassification:
    def test_a_mutating_command_is_ambiguous(self) -> None:
        # It may have caused the checkpoint itself; without a pid we cannot say.
        assert classification("wv done") == "ambiguous"
        assert classification("wv sync") == "ambiguous"

    def test_a_read_only_command_cannot_have_caused_it(self) -> None:
        assert classification("wv context") == "necessarily_concurrent"
        assert classification("wv query") == "necessarily_concurrent"


class TestOverlap:
    def test_a_read_only_call_spanning_the_checkpoint_is_counted_concurrent(
        self, repo_with_checkpoint: tuple[Path, int], tmp_path: Path
    ) -> None:
        repo, stamp = repo_with_checkpoint
        log = _log(tmp_path / "calls.jsonl", [
            {"ts": stamp - 5, "elapsed_ms": 10_000, "cmd": "wv context", "source": "agent",
             "exit_status": 0},
        ])
        summary = report(repo, log, days=30)
        assert summary["checkpoints"] == 1
        assert summary["checkpoints_inside_a_read_only_call"] == 1
        assert summary["collisions"][0]["in_flight"][0]["kind"] == "necessarily_concurrent"

    def test_the_command_that_caused_it_is_not_counted_concurrent(
        self, repo_with_checkpoint: tuple[Path, int], tmp_path: Path
    ) -> None:
        """The whole point of the split: wv done encloses its own checkpoint."""
        repo, stamp = repo_with_checkpoint
        log = _log(tmp_path / "calls.jsonl", [
            {"ts": stamp - 5, "elapsed_ms": 10_000, "cmd": "wv done", "source": "agent",
             "exit_status": 0},
        ])
        summary = report(repo, log, days=30)
        assert summary["checkpoints_overlapping_a_call"] == 1
        assert summary["checkpoints_inside_a_read_only_call"] == 0

    def test_a_call_that_finished_before_the_checkpoint_does_not_overlap(
        self, repo_with_checkpoint: tuple[Path, int], tmp_path: Path
    ) -> None:
        repo, stamp = repo_with_checkpoint
        log = _log(tmp_path / "calls.jsonl", [
            {"ts": stamp - 600, "elapsed_ms": 1_000, "cmd": "wv context", "source": "agent",
             "exit_status": 0},
        ])
        summary = report(repo, log, days=30)
        assert summary["checkpoints_overlapping_a_call"] == 0

    def test_unusable_rows_are_reported_rather_than_dropped_silently(
        self, repo_with_checkpoint: tuple[Path, int], tmp_path: Path
    ) -> None:
        """A measurement that discards its own inputs quietly cannot be trusted
        about what it did not find."""
        repo, stamp = repo_with_checkpoint
        path = tmp_path / "calls.jsonl"
        path.write_text(
            json.dumps({"ts": stamp - 5, "elapsed_ms": 10_000, "cmd": "wv context"}) + "\n"
            + "{not json\n"
            + json.dumps({"cmd": "wv show"}) + "\n",
            encoding="utf-8",
        )
        summary = report(repo, path, days=30)
        assert summary["unusable_log_rows"] == 2
        assert summary["calls_considered"] == 1


class TestExposure:
    def test_exposure_uses_the_median_not_the_mean(
        self, tmp_path: Path
    ) -> None:
        """The mean is dragged up by idle gaps, which understates exposure during
        exactly the dense sessions where collisions happen."""
        repo = tmp_path / "r"
        repo.mkdir()
        _git(repo, "init", "-q")
        _git(repo, "config", "user.email", "t@t")
        _git(repo, "config", "user.name", "t")
        # Spaced deliberately: commits sharing a second give a zero median, which
        # is a different branch (asserted below) and would not test this one.
        # Relative to now: a fixed epoch aged out of the 30-day window and
        # failed from about 2026-09-17, unseen because nothing ran this file
        # (wv-840865).
        base = int(time.time()) - 2 * 86_400
        for i in range(4):
            (repo / f"f{i}").write_text("x", encoding="utf-8")
            _git(repo, "add", "-A")
            stamp = f"{base + i * 900} +0000"
            subprocess.run(
                ["git", "-c", "core.hooksPath=/dev/null", "commit", "-qm",
                 f"chore(weave): auto-checkpoint {i}"],
                cwd=repo, check=True, capture_output=True,
                env={**os.environ, "GIT_AUTHOR_DATE": stamp, "GIT_COMMITTER_DATE": stamp},
            )
        summary = report(repo, _log(tmp_path / "c.jsonl", []), days=30)
        exposure = summary.get("exposure")
        assert exposure is not None
        assert "median_interval_seconds" in exposure
        assert exposure["basis"].startswith("median")
        assert exposure["median_interval_seconds"] == 900
        # Every probability is a real fraction, never above certainty.
        assert all(0.0 <= p <= 1.0 for p in exposure["collision_probability"].values())
        assert exposure["collision_probability"]["90s"] == pytest.approx(0.1, abs=0.01)

    def test_a_failed_git_log_stops_the_report(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """wv-e07ee4: outside a repository git log fails; carrying on read its
        empty output as 'no checkpoints' and reported zero exposure."""
        monkeypatch.setenv("GIT_CEILING_DIRECTORIES", str(tmp_path))
        monkeypatch.delenv("GIT_DIR", raising=False)
        not_a_repo = tmp_path / "plain"
        not_a_repo.mkdir()
        with pytest.raises(SystemExit, match="git log failed in"):
            report(not_a_repo, _log(tmp_path / "c.jsonl", []), days=30)

    def test_an_over_wide_window_is_clamped_not_silently_empty(self, tmp_path: Path) -> None:
        """git returns NO commits for a window reaching before the epoch, which
        reads as 'no checkpoints' instead of 'bad window'."""
        repo = tmp_path / "wide"
        repo.mkdir()
        _git(repo, "init", "-q")
        _git(repo, "config", "user.email", "t@t")
        _git(repo, "config", "user.name", "t")
        (repo / "f").write_text("x", encoding="utf-8")
        _git(repo, "add", "-A")
        _git(repo, "-c", "core.hooksPath=/dev/null", "commit", "-qm",
             "chore(weave): auto-checkpoint x")
        summary = report(repo, _log(tmp_path / "c.jsonl", []), days=36500)
        assert summary["checkpoints"] == 1, "an over-wide window must not silently return nothing"
        assert summary["window_clamped"] is True

    def test_same_second_checkpoints_report_undefined_rather_than_divide(
        self, tmp_path: Path
    ) -> None:
        """A burst that shares a timestamp has no interval to reason from."""
        repo = tmp_path / "burst"
        repo.mkdir()
        _git(repo, "init", "-q")
        _git(repo, "config", "user.email", "t@t")
        _git(repo, "config", "user.name", "t")
        # One explicit second for the whole burst: three real commits crossed a
        # second boundary under load and failed make check (wv-dada89).
        stamp = f"{int(time.time()) - 86_400} +0000"
        for i in range(3):
            (repo / f"f{i}").write_text("x", encoding="utf-8")
            _git(repo, "add", "-A")
            subprocess.run(
                ["git", "-c", "core.hooksPath=/dev/null", "commit", "-qm",
                 f"chore(weave): auto-checkpoint {i}"],
                cwd=repo, check=True, capture_output=True,
                env={**os.environ, "GIT_AUTHOR_DATE": stamp, "GIT_COMMITTER_DATE": stamp},
            )
        summary = report(repo, _log(tmp_path / "c.jsonl", []), days=30)
        exposure = summary["exposure"]
        assert exposure["collision_probability"] == {}
        assert "undefined" in exposure["basis"]
