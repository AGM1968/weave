"""Tests for --scope= flag on cmd_hotspots and cmd_diff."""
# pylint: disable=missing-class-docstring,missing-function-docstring,redefined-outer-name

from __future__ import annotations

import argparse
import json
import sqlite3
from collections.abc import Generator
from pathlib import Path

import pytest

from weave_quality.__main__ import cmd_diff, cmd_hotspots
from weave_quality.db import (
    begin_scan,
    bulk_upsert_file_entries,
    bulk_upsert_git_stats,
    finish_scan,
    init_db,
)
from weave_quality.hotspots import compute_hotspots
from weave_quality.models import FileEntry, GitStats


# ---------------------------------------------------------------------------
# Fixtures / helpers
# ---------------------------------------------------------------------------


@pytest.fixture()
def db(tmp_path: Path) -> Generator[sqlite3.Connection, None, None]:
    """Fresh quality.db in a temp directory."""
    conn = init_db(hot_zone=str(tmp_path))
    yield conn
    conn.close()


def _entry(
    path: str,
    scan_id: int,
    category: str = "production",
    complexity: float = 10.0,
    loc: int = 100,
) -> FileEntry:
    return FileEntry(
        path=path,
        scan_id=scan_id,
        language="python",
        loc=loc,
        complexity=complexity,
        functions=5,
        max_nesting=3,
        avg_fn_len=10.0,
        category=category,
    )


def _stats(path: str, churn: int = 50) -> GitStats:
    return GitStats(
        path=path,
        churn=churn,
        age_days=30,
        authors=2,
        hotspot=0.0,  # will be overwritten by compute_hotspots
    )


def _populate_scan(
    conn: sqlite3.Connection,
    scan_id: int,  # pylint: disable=unused-argument
    entries: list[FileEntry],
    stats: list[GitStats],
) -> None:
    """Populate a scan with entries and git stats.

    Note: compute_hotspots uses min-max normalization, so entries need different
    complexity/churn values to produce non-zero hotspot scores.
    """
    bulk_upsert_file_entries(conn, entries)
    compute_hotspots(entries, stats)
    bulk_upsert_git_stats(conn, stats)
    conn.commit()


def _hotspots_args(
    hot_zone: str,
    scope: str = "production",
    top: int = 10,
    use_json: bool = True,
) -> argparse.Namespace:
    return argparse.Namespace(
        hot_zone=hot_zone,
        top=top,
        json=use_json,
        scope=scope,
    )


def _diff_args(
    hot_zone: str,
    scope: str = "production",
    use_json: bool = True,
) -> argparse.Namespace:
    return argparse.Namespace(
        hot_zone=hot_zone,
        json=use_json,
        scope=scope,
    )


# ---------------------------------------------------------------------------
# Tests: cmd_hotspots --scope
# ---------------------------------------------------------------------------


class TestCmdHotspotsScope:
    def test_scope_production_filters_out_test_entries(
        self, db: sqlite3.Connection, tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """scope=production excludes test-category entries from hotspot ranking.

        Entries need distinct complexity+churn so min-max normalization produces
        a non-zero hotspot for the high-value file.
        """
        scan_id = begin_scan(db, "abc123")
        # Distinct complexity and churn to ensure variance for hotspot calculation
        entries = [
            _entry("src/app.py", scan_id, category="production", complexity=100.0),
            _entry("tests/test_app.py", scan_id, category="test", complexity=10.0),
        ]
        stats = [
            _stats("src/app.py", churn=100),
            _stats("tests/test_app.py", churn=10),
        ]
        _populate_scan(db, scan_id, entries, stats)
        finish_scan(db, scan_id, 2, 100)
        db.close()

        args = _hotspots_args(str(tmp_path), scope="production")
        result = cmd_hotspots(args)
        assert result == 0

        data = json.loads(capsys.readouterr().out)
        paths = [h["path"] for h in data["hotspots"]]
        # src/app.py has the highest complexity+churn and is production-scoped
        assert "src/app.py" in paths
        # test-category file must not appear under scope=production
        assert "tests/test_app.py" not in paths

    def test_scope_all_includes_all_categories(
        self, db: sqlite3.Connection, tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """scope=all keeps entries from every category."""
        scan_id = begin_scan(db, "abc123")
        # Use distinct values so both high-churn files get non-zero hotspot scores
        entries = [
            _entry("src/app.py", scan_id, category="production", complexity=100.0),
            _entry("tests/test_app.py", scan_id, category="test", complexity=80.0),
            _entry("scripts/run.sh", scan_id, category="script", complexity=5.0),
        ]
        stats = [
            _stats("src/app.py", churn=100),
            _stats("tests/test_app.py", churn=80),
            _stats("scripts/run.sh", churn=5),
        ]
        _populate_scan(db, scan_id, entries, stats)
        finish_scan(db, scan_id, 3, 100)
        db.close()

        args = _hotspots_args(str(tmp_path), scope="all")
        result = cmd_hotspots(args)
        assert result == 0

        data = json.loads(capsys.readouterr().out)
        paths = [h["path"] for h in data["hotspots"]]
        # Both high-scoring files must appear under scope=all
        assert "src/app.py" in paths
        assert "tests/test_app.py" in paths

    def test_scope_test_includes_only_test_entries(
        self, db: sqlite3.Connection, tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """scope=test keeps only test-category entries.

        The production file has higher complexity+churn so it would dominate if
        scope filtering were absent.
        """
        scan_id = begin_scan(db, "abc123")
        entries = [
            _entry("src/app.py", scan_id, category="production", complexity=100.0),
            _entry("tests/test_app.py", scan_id, category="test", complexity=10.0),
        ]
        stats = [
            _stats("src/app.py", churn=100),
            _stats("tests/test_app.py", churn=10),
        ]
        _populate_scan(db, scan_id, entries, stats)
        finish_scan(db, scan_id, 2, 100)
        db.close()

        args = _hotspots_args(str(tmp_path), scope="test")
        result = cmd_hotspots(args)
        assert result == 0

        data = json.loads(capsys.readouterr().out)
        paths = [h["path"] for h in data["hotspots"]]
        # Production entry must not appear under scope=test
        assert "src/app.py" not in paths

    def test_scope_production_default(
        self, db: sqlite3.Connection, tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """Default scope (production) filters test-category entries."""
        scan_id = begin_scan(db, "abc123")
        entries = [
            _entry("src/main.py", scan_id, category="production", complexity=100.0),
            _entry("tests/test_main.py", scan_id, category="test", complexity=10.0),
        ]
        stats = [
            _stats("src/main.py", churn=100),
            _stats("tests/test_main.py", churn=10),
        ]
        _populate_scan(db, scan_id, entries, stats)
        finish_scan(db, scan_id, 2, 100)
        db.close()

        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            top=10,
            json=True,
            scope="production",
        )
        result = cmd_hotspots(args)
        assert result == 0

        data = json.loads(capsys.readouterr().out)
        paths = [h["path"] for h in data["hotspots"]]
        assert "src/main.py" in paths
        assert "tests/test_main.py" not in paths


# ---------------------------------------------------------------------------
# Tests: cmd_diff --scope
# ---------------------------------------------------------------------------


class TestCmdDiffScope:
    def test_scope_production_filters_test_entries(
        self, db: sqlite3.Connection, tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """scope=production causes diff to ignore test-category files."""
        # Scan 1
        s1 = begin_scan(db, "abc123")
        entries1 = [
            _entry("src/app.py", s1, category="production", complexity=10.0),
            _entry("tests/test_app.py", s1, category="test", complexity=10.0),
        ]
        stats1 = [
            _stats("src/app.py", churn=5),
            _stats("tests/test_app.py", churn=5),
        ]
        _populate_scan(db, s1, entries1, stats1)
        finish_scan(db, s1, 2, 100)

        # Scan 2: test file complexity increases significantly, production unchanged
        s2 = begin_scan(db, "abc456")
        entries2 = [
            _entry("src/app.py", s2, category="production", complexity=10.0),
            _entry("tests/test_app.py", s2, category="test", complexity=50.0),
        ]
        stats2 = [
            _stats("src/app.py", churn=5),
            _stats("tests/test_app.py", churn=5),
        ]
        _populate_scan(db, s2, entries2, stats2)
        finish_scan(db, s2, 2, 100)
        db.close()

        args = _diff_args(str(tmp_path), scope="production")
        result = cmd_diff(args)
        assert result == 0

        data = json.loads(capsys.readouterr().out)
        # test_app.py degraded but must not appear under scope=production
        degraded_paths = [d["path"] for d in data["degraded"]]
        assert "tests/test_app.py" not in degraded_paths
        assert data["improved"] == []

    def test_scope_all_includes_test_entries_in_diff(
        self, db: sqlite3.Connection, tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """scope=all includes test-category files in the diff report."""
        # Scan 1
        s1 = begin_scan(db, "abc123")
        entries1 = [
            _entry("src/app.py", s1, category="production", complexity=10.0),
            _entry("tests/test_app.py", s1, category="test", complexity=10.0),
        ]
        stats1 = [
            _stats("src/app.py", churn=5),
            _stats("tests/test_app.py", churn=5),
        ]
        _populate_scan(db, s1, entries1, stats1)
        finish_scan(db, s1, 2, 100)

        # Scan 2: test file complexity increases significantly
        s2 = begin_scan(db, "abc456")
        entries2 = [
            _entry("src/app.py", s2, category="production", complexity=10.0),
            _entry("tests/test_app.py", s2, category="test", complexity=50.0),
        ]
        stats2 = [
            _stats("src/app.py", churn=5),
            _stats("tests/test_app.py", churn=5),
        ]
        _populate_scan(db, s2, entries2, stats2)
        finish_scan(db, s2, 2, 100)
        db.close()

        args = _diff_args(str(tmp_path), scope="all")
        result = cmd_diff(args)
        assert result == 0

        data = json.loads(capsys.readouterr().out)
        degraded_paths = [d["path"] for d in data["degraded"]]
        assert "tests/test_app.py" in degraded_paths

    def test_scope_production_quality_score_excludes_test_files(
        self, db: sqlite3.Connection, tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """quality_score in diff output reflects only the scoped entries."""
        # Scan 1: one production file
        s1 = begin_scan(db, "abc123")
        entries1 = [
            _entry("src/app.py", s1, category="production", complexity=10.0),
        ]
        stats1 = [_stats("src/app.py", churn=5)]
        _populate_scan(db, s1, entries1, stats1)
        finish_scan(db, s1, 1, 100)

        # Scan 2: same production file
        s2 = begin_scan(db, "abc456")
        entries2 = [
            _entry("src/app.py", s2, category="production", complexity=10.0),
        ]
        stats2 = [_stats("src/app.py", churn=5)]
        _populate_scan(db, s2, entries2, stats2)
        finish_scan(db, s2, 1, 100)
        db.close()

        args = _diff_args(str(tmp_path), scope="production")
        result = cmd_diff(args)
        assert result == 0

        data = json.loads(capsys.readouterr().out)
        assert "quality_score_current" in data
        assert "quality_score_previous" in data
        assert isinstance(data["quality_score_current"], int)
        assert isinstance(data["quality_score_previous"], int)
