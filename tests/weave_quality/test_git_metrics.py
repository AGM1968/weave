"""Tests for weave_quality.git_metrics functions.

Runs against the real git repo (memory-system) for integration tests.
API convention: all functions take (repo, filepath) positional args.
"""

# pylint: disable=missing-class-docstring,missing-function-docstring,too-few-public-methods

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
    _compute_ownership,
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


# ---------------------------------------------------------------------------
# Ownership metrics (Sprint 2)
# ---------------------------------------------------------------------------


def _make_git_log(*commits: tuple[str, str]) -> str:
    """Build synthetic git log output for a single target file.

    Each commit is (author_name, filepath_that_was_changed).
    Format matches what _batch_git_stats / _compute_ownership expect.
    """
    lines = []
    for author, filepath in commits:
        lines.append(f"COMMIT_SEP\t{author}\t2024-01-01T00:00:00+00:00")
        lines.append(filepath)
    return "\n".join(lines)


class TestComputeOwnership:
    def test_solo_developer(self) -> None:
        """Single author → full ownership, no minor contributors."""
        git_log = _make_git_log(
            ("Alice", "src/foo.py"),
            ("Alice", "src/foo.py"),
            ("Alice", "src/foo.py"),
        )
        frac, minor = _compute_ownership(
            "src/foo.py", {"Alice"}, 3, git_log)
        assert frac == 1.0
        assert minor == 0

    def test_d5_two_authors_no_minor_flagged(self) -> None:
        """D5: only flag minor contributors when authors >= 3."""
        git_log = _make_git_log(
            ("Alice", "src/foo.py"),
            ("Alice", "src/foo.py"),
            ("Bob",   "src/foo.py"),
            ("Bob",   "src/foo.py"),
        )
        # 2 authors → below D5 threshold, minor_contributors must be 0
        frac, minor = _compute_ownership(
            "src/foo.py", {"Alice", "Bob"}, 4, git_log)
        assert minor == 0  # D5: < 3 authors → no flag
        assert 0.4 <= frac <= 0.6  # roughly equal split

    def test_three_authors_95_5_ownership(self) -> None:
        """95/5/0 split: one minor contributor (author with <5% of commits)."""
        # 20 commits: 19 Alice, 1 Bob, 0 Carol (not counted if no commits)
        commits = [("Alice", "src/foo.py")] * 19 + [("Bob", "src/foo.py")] * 1
        # Carol touched a different file
        commits += [("Carol", "src/other.py")]
        git_log = _make_git_log(*commits)
        frac, minor = _compute_ownership(
            "src/foo.py", {"Alice", "Bob"}, 20, git_log)
        # Bob has 1/20 = 5% → exactly at boundary; threshold is < 5% so not minor
        # Alice has 19/20 = 95%
        assert frac == pytest.approx(19 / 20)
        assert minor == 0  # authors < 3 in this file's commit history

    def test_three_authors_genuine_minor(self) -> None:
        """3 authors, one with < 5%: should flag as minor contributor."""
        # 100 commits: 90 Alice, 9 Bob, 1 Carol
        commits = ([("Alice", "src/foo.py")] * 90
                   + [("Bob",   "src/foo.py")] * 9
                   + [("Carol", "src/foo.py")] * 1)
        git_log = _make_git_log(*commits)
        frac, minor = _compute_ownership(
            "src/foo.py", {"Alice", "Bob", "Carol"}, 100, git_log)
        # Carol: 1/100 = 1% < 5% threshold → minor
        assert frac == pytest.approx(0.90)
        assert minor == 1  # Carol is the minor contributor

    def test_zero_commits_returns_full_ownership(self) -> None:
        frac, minor = _compute_ownership("x.py", set(), 0, "")
        assert frac == 1.0
        assert minor == 0

    def test_ownership_stored_in_git_stats_model(self) -> None:
        """GitStats model carries ownership fields with correct defaults."""
        gs = GitStats(path="x.py")
        assert gs.ownership_fraction == 0.0
        assert gs.minor_contributors == 0

        gs2 = GitStats(
            path="y.py", churn=10, authors=3,
            ownership_fraction=0.75, minor_contributors=1,
        )
        d = gs2.to_dict()
        assert d["ownership_fraction"] == 0.75
        assert d["minor_contributors"] == 1

        gs3 = GitStats.from_dict(d)
        assert gs3.ownership_fraction == 0.75
        assert gs3.minor_contributors == 1
