"""Tests for weave_quality.git_metrics functions.

Runs against the real git repo (memory-system) for integration tests.
API convention: all functions take (repo, filepath) positional args.
"""

# pylint: disable=missing-class-docstring,missing-function-docstring

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

from weave_quality.git_metrics import (
    build_file_state,
    build_git_stats,
    compute_co_changes,
    file_age_days,
    file_authors,
    file_churn,
    file_co_changes,
    git_blob_sha,
    git_head_sha,
)
from weave_quality.models import FileState, GitStats


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# The repo root -- used as first positional arg (repo) for all functions
REPO = str(Path(__file__).resolve().parent.parent.parent)


def _in_git_repo() -> bool:
    """Check we're inside a real git repo."""
    try:
        subprocess.run(
            ["git", "rev-parse", "--git-dir"],
            cwd=REPO, capture_output=True, check=True,
        )
        return True
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False


need_git: pytest.MarkDecorator = pytest.mark.skipif(
    not _in_git_repo(), reason="No git repo found"
)


# ---------------------------------------------------------------------------
# git helpers
# ---------------------------------------------------------------------------


class TestGitHelpers:
    @need_git
    def test_git_head_sha_length(self) -> None:
        sha = git_head_sha(REPO)
        assert len(sha) == 40
        assert all(c in "0123456789abcdef" for c in sha)

    @need_git
    def test_git_blob_sha_known_file(self) -> None:
        # README.md should always exist in this repo
        sha = git_blob_sha(REPO, "README.md")
        assert len(sha) == 40

    @need_git
    def test_git_blob_sha_missing_file(self) -> None:
        sha = git_blob_sha(REPO, "DOES_NOT_EXIST_12345.xyz")
        assert sha == ""


# ---------------------------------------------------------------------------
# Per-file stats
# ---------------------------------------------------------------------------


class TestPerFileStats:
    @need_git
    def test_file_churn_positive(self) -> None:
        # install.sh has many commits
        c = file_churn(REPO, "install.sh")
        assert c > 0

    @need_git
    def test_file_churn_missing(self) -> None:
        c = file_churn(REPO, "NO_SUCH_FILE.txt")
        assert c == 0

    @need_git
    def test_file_authors_positive(self) -> None:
        a = file_authors(REPO, "install.sh")
        assert a >= 1

    @need_git
    def test_file_age_days_positive(self) -> None:
        d = file_age_days(REPO, "install.sh")
        assert d >= 0


# ---------------------------------------------------------------------------
# build_git_stats
# ---------------------------------------------------------------------------


class TestBuildGitStats:
    @need_git
    def test_returns_git_stats_instance(self) -> None:
        gs = build_git_stats(REPO, "install.sh")
        assert isinstance(gs, GitStats)
        assert gs.path == "install.sh"
        assert gs.churn > 0

    @need_git
    def test_missing_file(self) -> None:
        gs = build_git_stats(REPO, "NO_SUCH_FILE.txt")
        assert gs.churn == 0


# ---------------------------------------------------------------------------
# build_file_state
# ---------------------------------------------------------------------------


class TestBuildFileState:
    @need_git
    def test_returns_file_state(self) -> None:
        fs = build_file_state(REPO, "install.sh")
        assert isinstance(fs, FileState)
        assert fs.path == "install.sh"
        assert fs.mtime > 0
        assert len(fs.git_blob) == 40


# ---------------------------------------------------------------------------
# Co-change
# ---------------------------------------------------------------------------


class TestCoChanges:
    @need_git
    def test_compute_co_changes_returns_list(self) -> None:
        pairs = compute_co_changes(REPO)
        assert isinstance(pairs, list)
        # May or may not have results, but should not crash

    @need_git
    def test_file_co_changes_returns_list(self) -> None:
        files = file_co_changes(REPO, "install.sh")
        assert isinstance(files, list)
        # file_co_changes returns list[str] not list[CoChange]
        for f in files:
            assert isinstance(f, str)
