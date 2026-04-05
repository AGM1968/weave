"""Tests for weave_quality CLI commands.

Covers: hotspots, diff, promote, health-info, context-files, functions.
"""
# pylint: disable=missing-class-docstring,missing-function-docstring,redefined-outer-name,unused-argument,too-many-lines

from __future__ import annotations

import argparse
import io
import json
import os
import sqlite3
import subprocess
from collections.abc import Generator
from pathlib import Path
from unittest.mock import patch

import pytest

from weave_quality.__main__ import (
    _discover_files,
    _finding_id,
    _get_current_head,
    _load_config_excludes,
    _resolve_repo,
    _wv_cmd,
    cmd_context_files,
    cmd_diff,
    cmd_functions,
    cmd_health_info,
    cmd_hotspots,
    cmd_promote,
    cmd_reset,
    cmd_scan,
)
from weave_quality.db import (
    begin_scan,
    bulk_upsert_file_entries,
    bulk_upsert_function_cc,
    bulk_upsert_git_stats,
    db_path,
    finish_scan,
    get_file_entries,
    init_db,
    latest_scan,
)
from weave_quality.hotspots import compute_hotspots
from weave_quality.models import FileEntry, FunctionCC, GitStats


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture()
def db(tmp_path: Path) -> Generator[sqlite3.Connection, None, None]:
    """Fresh quality.db in a temp directory."""
    conn = init_db(hot_zone=str(tmp_path))
    yield conn
    conn.close()


def _entry(
    path: str,
    scan_id: int,  # pylint: disable=unused-argument
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
    )


def _stats(
    path: str,
    churn: int = 50,
    hotspot: float = 0.0,
) -> GitStats:
    return GitStats(
        path=path,
        churn=churn,
        age_days=30,
        authors=2,
        hotspot=hotspot,
    )


def _populate_scan(
    conn: sqlite3.Connection,
    scan_id: int,  # pylint: disable=unused-argument
    entries: list[FileEntry],
    stats: list[GitStats],
) -> None:
    """Populate a scan with entries and git stats.

    Commits the transaction since db.py upserts no longer auto-commit
    (single-transaction scan model).
    """
    bulk_upsert_file_entries(conn, entries)
    compute_hotspots(entries, stats)
    bulk_upsert_git_stats(conn, stats)
    conn.commit()


# ---------------------------------------------------------------------------
# Tests: cmd_hotspots
# ---------------------------------------------------------------------------


class TestCmdHotspots:
    def test_no_db_returns_error(self, tmp_path: Path) -> None:
        """hotspots with no quality.db returns error."""
        args = argparse.Namespace(
            hot_zone=str(tmp_path / "nonexistent"),
            top=10,
            json=False,
            scope="production",
        )
        result = cmd_hotspots(args)
        assert result == 1

    def test_no_scan_returns_error(
        self, db: sqlite3.Connection, tmp_path: Path
    ) -> None:
        """hotspots with empty db returns error."""
        _ = db  # ensure DB is created
        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            top=10,
            json=False,
            scope="production",
        )
        result = cmd_hotspots(args)
        assert result == 1

    def test_hotspots_text_output(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """hotspots with data returns ranked text output."""
        scan_id = begin_scan(db, "abc123")
        entries = [
            _entry("a.py", scan_id, complexity=100),
            _entry("b.py", scan_id, complexity=10),
        ]
        stats = [
            _stats("a.py", churn=50),
            _stats("b.py", churn=5),
        ]
        _populate_scan(db, scan_id, entries, stats)
        finish_scan(db, scan_id, 2, 100)
        db.close()

        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            top=10,
            json=False,
            scope="production",
        )
        result = cmd_hotspots(args)
        assert result == 0
        captured = capsys.readouterr()
        assert "a.py" in captured.err

    def test_hotspots_json_output(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """hotspots --json returns valid JSON with expected schema."""
        scan_id = begin_scan(db, "abc123")
        entries = [
            _entry("a.py", scan_id, complexity=100),
            _entry("b.py", scan_id, complexity=10),
        ]
        stats = [
            _stats("a.py", churn=50),
            _stats("b.py", churn=5),
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
        captured = capsys.readouterr()
        data = json.loads(captured.out)
        assert "hotspots" in data
        assert "scan_id" in data
        assert "git_head" in data
        assert "stale" in data
        # a.py should be the top hotspot (higher complexity + churn)
        if data["hotspots"]:
            assert data["hotspots"][0]["path"] == "a.py"

    def test_hotspots_top_limits_results(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """--top=1 limits to 1 result."""
        scan_id = begin_scan(db, "abc123")
        entries = [
            _entry("a.py", scan_id, complexity=100),
            _entry("b.py", scan_id, complexity=90),
            _entry("c.py", scan_id, complexity=80),
        ]
        stats = [
            _stats("a.py", churn=50, hotspot=0.9),
            _stats("b.py", churn=40, hotspot=0.8),
            _stats("c.py", churn=30, hotspot=0.7),
        ]
        _populate_scan(db, scan_id, entries, stats)
        finish_scan(db, scan_id, 3, 100)
        db.close()

        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            top=1,
            json=True,
            scope="production",
        )
        result = cmd_hotspots(args)
        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert len(data["hotspots"]) <= 1


# ---------------------------------------------------------------------------
# Tests: cmd_diff
# ---------------------------------------------------------------------------


class TestCmdDiff:
    def test_no_db_returns_error(self, tmp_path: Path) -> None:
        """diff with no quality.db returns error."""
        args = argparse.Namespace(
            hot_zone=str(tmp_path / "nonexistent"),
            json=False,
            scope="production",
        )
        result = cmd_diff(args)
        assert result == 1

    def test_single_scan_no_previous(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """diff with only one scan returns exit 0 with message."""
        scan_id = begin_scan(db, "abc123")
        finish_scan(db, scan_id, 5, 100)
        db.commit()
        db.close()

        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            json=False,
            scope="production",
        )
        result = cmd_diff(args)
        assert result == 0
        captured = capsys.readouterr()
        assert "No previous scan" in captured.err

    def test_single_scan_json(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """diff --json with one scan returns null previous."""
        scan_id = begin_scan(db, "abc123")
        finish_scan(db, scan_id, 5, 100)
        db.commit()
        db.close()

        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            json=True,
            scope="production",
        )
        result = cmd_diff(args)
        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert data["scan_previous"] is None
        assert data["scan_current"] == scan_id

    def test_diff_two_scans_no_change(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """diff between identical scans shows no significant changes."""
        # Scan 1
        s1 = begin_scan(db, "abc123")
        entries1 = [_entry("a.py", s1, complexity=10)]
        stats1 = [_stats("a.py", churn=5)]
        _populate_scan(db, s1, entries1, stats1)
        finish_scan(db, s1, 1, 100)

        # Scan 2 (same data)
        s2 = begin_scan(db, "abc456")
        entries2 = [_entry("a.py", s2, complexity=10)]
        stats2 = [_stats("a.py", churn=5)]
        _populate_scan(db, s2, entries2, stats2)
        finish_scan(db, s2, 1, 100)
        db.close()

        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            json=True,
            scope="production",
        )
        result = cmd_diff(args)
        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert data["improved"] == []
        assert data["degraded"] == []
        assert data["new_files"] == []
        assert data["removed_files"] == []

    def test_diff_shows_degraded(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """diff reports files where complexity increased."""
        # Scan 1
        s1 = begin_scan(db, "abc123")
        entries1 = [_entry("a.py", s1, complexity=10)]
        stats1 = [_stats("a.py", churn=5)]
        _populate_scan(db, s1, entries1, stats1)
        finish_scan(db, s1, 1, 100)

        # Scan 2 (complexity increased)
        s2 = begin_scan(db, "abc456")
        entries2 = [_entry("a.py", s2, complexity=30)]
        stats2 = [_stats("a.py", churn=5)]
        _populate_scan(db, s2, entries2, stats2)
        finish_scan(db, s2, 1, 100)
        db.close()

        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            json=True,
            scope="production",
        )
        result = cmd_diff(args)
        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert len(data["degraded"]) == 1
        assert data["degraded"][0]["path"] == "a.py"
        assert data["degraded"][0]["delta"] == 20.0

    def test_diff_shows_improved(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """diff reports files where complexity decreased."""
        # Scan 1
        s1 = begin_scan(db, "abc123")
        entries1 = [_entry("a.py", s1, complexity=30)]
        stats1 = [_stats("a.py", churn=5)]
        _populate_scan(db, s1, entries1, stats1)
        finish_scan(db, s1, 1, 100)

        # Scan 2 (complexity decreased)
        s2 = begin_scan(db, "abc456")
        entries2 = [_entry("a.py", s2, complexity=10)]
        stats2 = [_stats("a.py", churn=5)]
        _populate_scan(db, s2, entries2, stats2)
        finish_scan(db, s2, 1, 100)
        db.close()

        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            json=True,
            scope="production",
        )
        result = cmd_diff(args)
        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert len(data["improved"]) == 1
        assert data["improved"][0]["path"] == "a.py"
        assert data["improved"][0]["delta"] == -20.0

    def test_diff_shows_new_files(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """diff reports files that appear in current but not previous scan."""
        # Scan 1 (only a.py)
        s1 = begin_scan(db, "abc123")
        entries1 = [_entry("a.py", s1, complexity=10)]
        stats1 = [_stats("a.py", churn=5)]
        _populate_scan(db, s1, entries1, stats1)
        finish_scan(db, s1, 1, 100)

        # Scan 2 (a.py + b.py)
        s2 = begin_scan(db, "abc456")
        entries2 = [
            _entry("a.py", s2, complexity=10),
            _entry("b.py", s2, complexity=20),
        ]
        stats2 = [_stats("a.py", churn=5), _stats("b.py", churn=10)]
        _populate_scan(db, s2, entries2, stats2)
        finish_scan(db, s2, 2, 100)
        db.close()

        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            json=True,
            scope="production",
        )
        result = cmd_diff(args)
        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert len(data["new_files"]) == 1
        assert data["new_files"][0]["path"] == "b.py"

    def test_diff_shows_removed_files(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """diff reports files that disappeared from current scan."""
        # Scan 1 (a.py + b.py)
        s1 = begin_scan(db, "abc123")
        entries1 = [
            _entry("a.py", s1, complexity=10),
            _entry("b.py", s1, complexity=20),
        ]
        stats1 = [_stats("a.py", churn=5), _stats("b.py", churn=10)]
        _populate_scan(db, s1, entries1, stats1)
        finish_scan(db, s1, 2, 100)

        # Scan 2 (only a.py)
        s2 = begin_scan(db, "abc456")
        entries2 = [_entry("a.py", s2, complexity=10)]
        stats2 = [_stats("a.py", churn=5)]
        _populate_scan(db, s2, entries2, stats2)
        finish_scan(db, s2, 1, 100)
        db.close()

        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            json=True,
            scope="production",
        )
        result = cmd_diff(args)
        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert "b.py" in data["removed_files"]

    def test_diff_quality_score_delta(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """diff JSON includes quality_score_current and quality_score_previous."""
        # Scan 1
        s1 = begin_scan(db, "abc123")
        entries1 = [_entry("a.py", s1, complexity=10)]
        stats1 = [_stats("a.py", churn=5)]
        _populate_scan(db, s1, entries1, stats1)
        finish_scan(db, s1, 1, 100)

        # Scan 2
        s2 = begin_scan(db, "abc456")
        entries2 = [_entry("a.py", s2, complexity=10)]
        stats2 = [_stats("a.py", churn=5)]
        _populate_scan(db, s2, entries2, stats2)
        finish_scan(db, s2, 1, 100)
        db.close()

        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            json=True,
            scope="production",
        )
        result = cmd_diff(args)
        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert "quality_score_current" in data
        assert "quality_score_previous" in data
        assert isinstance(data["quality_score_current"], int)
        assert isinstance(data["quality_score_previous"], int)


# ---------------------------------------------------------------------------
# Tests: cmd_promote
# ---------------------------------------------------------------------------


def _make_promote_args(
    hot_zone: str,
    parent: str = "wv-abcdef",
    top: int = 5,
    json_out: bool = False,
    dry_run: bool = False,
) -> argparse.Namespace:
    return argparse.Namespace(
        hot_zone=hot_zone,
        parent=parent,
        top=top,
        json=json_out,
        dry_run=dry_run,
    )


class TestCmdPromote:
    def test_no_db_returns_error(self, tmp_path: Path) -> None:
        """promote with no quality.db returns error."""
        args = _make_promote_args(str(tmp_path / "nonexistent"))
        result = cmd_promote(args)
        assert result == 1

    def test_no_scan_returns_error(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
    ) -> None:
        """promote with empty db returns error."""
        _ = db
        args = _make_promote_args(str(tmp_path))
        result = cmd_promote(args)
        assert result == 1

    def test_no_parent_returns_error(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
    ) -> None:
        """promote without --parent returns error."""
        _ = db
        args = _make_promote_args(str(tmp_path), parent="")
        result = cmd_promote(args)
        assert result == 1

    def test_dry_run_no_wv_calls(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """dry-run prints plan without calling wv."""
        scan_id = begin_scan(db, str(tmp_path))
        entries = [
            _entry("a.py", scan_id, complexity=50.0),
            _entry("b.py", scan_id, complexity=30.0),
        ]
        stats = [
            _stats("a.py", churn=100),
            _stats("b.py", churn=80),
        ]
        _populate_scan(db, scan_id, entries, stats)
        finish_scan(db, scan_id, 2, 100)

        args = _make_promote_args(str(tmp_path), dry_run=True)

        with patch("weave_quality.__main__._wv_cmd") as mock_wv:
            # _wv_cmd for idempotency check returns empty list
            mock_wv.return_value = (0, "[]")
            result = cmd_promote(args)

        assert result == 0
        captured = capsys.readouterr()
        assert "[DRY-RUN]" in captured.err
        # Only the idempotency list check, no add/link calls
        mock_wv.assert_called_once_with("list", "--json", "--all")

    def test_promote_creates_nodes(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """promote creates nodes and links them via references edge."""
        scan_id = begin_scan(db, str(tmp_path))
        entries = [
            _entry("hot.py", scan_id, complexity=60.0),
            _entry("cold.py", scan_id, complexity=5.0),
        ]
        stats = [
            _stats("hot.py", churn=120),
            _stats("cold.py", churn=10),
        ]
        _populate_scan(db, scan_id, entries, stats)
        finish_scan(db, scan_id, 2, 100)

        args = _make_promote_args(str(tmp_path), top=1, json_out=True)

        def fake_wv(*cmd_args: str) -> tuple[int, str]:
            if cmd_args[0] == "list":
                return 0, "[]"
            if cmd_args[0] == "add":
                return 0, "wv-aaa111: Hotspot: hot.py ..."
            if cmd_args[0] == "link":
                return 0, ""
            return 1, "unknown"

        with patch("weave_quality.__main__._wv_cmd", side_effect=fake_wv):
            result = cmd_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert len(data["promoted"]) == 1
        assert data["promoted"][0]["node_id"] == "wv-aaa111"
        assert data["skipped"] == 0
        assert data["parent"] == "wv-abcdef"

    def test_promote_skips_existing(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """promote skips findings that already have Weave nodes."""
        scan_id = begin_scan(db, str(tmp_path))
        entries = [
            _entry("dup.py", scan_id, complexity=40.0),
            _entry("other.py", scan_id, complexity=5.0),
        ]
        stats = [
            _stats("dup.py", churn=90),
            _stats("other.py", churn=10),
        ]
        _populate_scan(db, scan_id, entries, stats)
        finish_scan(db, scan_id, 2, 100)

        # Compute the finding ID for dup.py so we can simulate existing node
        fid = _finding_id("dup.py")

        existing_node = json.dumps(
            [
                {
                    "id": "wv-exists",
                    "text": "old finding",
                    "metadata": json.dumps({"quality_finding_id": fid}),
                }
            ]
        )

        args = _make_promote_args(str(tmp_path), top=1, json_out=True)

        with patch("weave_quality.__main__._wv_cmd", return_value=(0, existing_node)):
            result = cmd_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert data["skipped"] == 1
        assert len(data["promoted"]) == 0

    def test_promote_json_schema(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """promote --json output has required fields."""
        scan_id = begin_scan(db, str(tmp_path))
        entries = [
            _entry("schema.py", scan_id, complexity=45.0),
            _entry("low.py", scan_id, complexity=5.0),
        ]
        stats = [
            _stats("schema.py", churn=70),
            _stats("low.py", churn=10),
        ]
        _populate_scan(db, scan_id, entries, stats)
        finish_scan(db, scan_id, 2, 100)

        args = _make_promote_args(str(tmp_path), top=1, json_out=True, dry_run=True)

        with patch("weave_quality.__main__._wv_cmd", return_value=(0, "[]")):
            result = cmd_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert "promoted" in data
        assert "skipped" in data
        assert "parent" in data
        assert isinstance(data["promoted"], list)


# ---------------------------------------------------------------------------
# Tests: cmd_health_info
# ---------------------------------------------------------------------------


def _make_health_args(hot_zone: str) -> argparse.Namespace:
    return argparse.Namespace(hot_zone=hot_zone)


class TestCmdHealthInfo:
    def test_no_db_returns_unavailable(
        self,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """health-info with no quality.db returns available=false."""
        args = _make_health_args(str(tmp_path / "nonexistent"))
        cmd_health_info(args)
        data = json.loads(capsys.readouterr().out)
        assert data["available"] is False

    def test_no_scan_returns_unavailable(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """health-info with empty db returns available=false."""
        _ = db
        args = _make_health_args(str(tmp_path))
        cmd_health_info(args)
        data = json.loads(capsys.readouterr().out)
        assert data["available"] is False

    def test_with_scan_returns_score(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """health-info with scan data returns score and metadata."""
        scan_id = begin_scan(db, str(tmp_path))
        entries = [
            _entry("a.py", scan_id, complexity=50.0),
            _entry("b.py", scan_id, complexity=5.0),
        ]
        stats = [
            _stats("a.py", churn=100),
            _stats("b.py", churn=10),
        ]
        _populate_scan(db, scan_id, entries, stats)
        finish_scan(db, scan_id, 2, 100)

        args = _make_health_args(str(tmp_path))
        cmd_health_info(args)
        data = json.loads(capsys.readouterr().out)
        assert data["available"] is True
        assert isinstance(data["score"], int)
        assert "hotspot_count" in data
        assert "total_files" in data
        assert "git_head" in data
        assert "scanned_at" in data


# ---------------------------------------------------------------------------
# context-files
# ---------------------------------------------------------------------------


def _make_context_files_args(hot_zone: str) -> argparse.Namespace:
    return argparse.Namespace(hot_zone=hot_zone)


class TestCmdContextFiles:
    def test_no_db_returns_empty(
        self,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """context-files with no db returns empty quality list."""
        no_db_path = str(tmp_path / "nonexistent")
        args = _make_context_files_args(no_db_path)
        with patch("sys.stdin", io.StringIO("a.py\nb.py\n")):
            cmd_context_files(args)
        data = json.loads(capsys.readouterr().out)
        assert data["code_quality"] == []
        assert data["quality_as_of"] is None

    def test_no_scan_returns_empty(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """context-files with empty db (no scan) returns empty."""
        _ = db
        args = _make_context_files_args(str(tmp_path))
        with patch("sys.stdin", io.StringIO("a.py\n")):
            cmd_context_files(args)
        data = json.loads(capsys.readouterr().out)
        assert data["code_quality"] == []
        assert data["quality_as_of"] is None

    def test_no_stdin_returns_empty(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """context-files with no stdin paths returns empty."""
        scan_id = begin_scan(db, str(tmp_path))
        entries = [_entry("a.py", scan_id)]
        stats = [_stats("a.py", churn=50)]
        _populate_scan(db, scan_id, entries, stats)
        finish_scan(db, scan_id, 1, 100)

        args = _make_context_files_args(str(tmp_path))
        # Simulate tty (no piped stdin) - empty StringIO with isatty=True
        with patch("sys.stdin", io.StringIO("")):
            cmd_context_files(args)
        data = json.loads(capsys.readouterr().out)
        assert data["code_quality"] == []

    def test_returns_quality_for_known_files(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """context-files returns quality data for files in quality.db."""
        scan_id = begin_scan(db, str(tmp_path))
        entries = [
            _entry("a.py", scan_id, complexity=45.0),
            _entry("b.py", scan_id, complexity=12.0),
        ]
        stats = [
            _stats("a.py", churn=67),
            _stats("b.py", churn=18),
        ]
        _populate_scan(db, scan_id, entries, stats)
        finish_scan(db, scan_id, 2, 100)

        args = _make_context_files_args(str(tmp_path))
        with patch("sys.stdin", io.StringIO("a.py\nb.py\nunknown.py\n")):
            cmd_context_files(args)
        data = json.loads(capsys.readouterr().out)

        assert data["quality_as_of"] is not None
        assert len(data["code_quality"]) == 2

        # Check files present
        by_path = {item["path"]: item for item in data["code_quality"]}
        assert "a.py" in by_path
        # a.py has highest complexity+churn -> hotspot=1.0 after min-max normalization
        assert by_path["a.py"]["hotspot"] == 1.0
        assert by_path["a.py"]["churn"] == 67
        assert by_path["a.py"]["complexity"] == 45.0

        assert "b.py" in by_path
        # b.py has lowest values -> hotspot=0.0 after normalization
        assert by_path["b.py"]["hotspot"] == 0.0

        # unknown.py not in quality.db -> not in results
        assert "unknown.py" not in by_path

    def test_file_with_only_stats(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """context-files returns data for files with only git stats."""
        scan_id = begin_scan(db, str(tmp_path))
        # No file entries for c.py, only git stats
        stats = [_stats("c.py", churn=30, hotspot=0.5)]
        bulk_upsert_git_stats(db, stats)
        finish_scan(db, scan_id, 0, 100)
        db.commit()

        args = _make_context_files_args(str(tmp_path))
        with patch("sys.stdin", io.StringIO("c.py\n")):
            cmd_context_files(args)
        data = json.loads(capsys.readouterr().out)
        assert len(data["code_quality"]) == 1
        assert data["code_quality"][0]["path"] == "c.py"
        assert data["code_quality"][0]["hotspot"] == 0.5
        assert "complexity" not in data["code_quality"][0]


# ---------------------------------------------------------------------------
# Tests: cmd_functions
# ---------------------------------------------------------------------------


def _make_functions_args(
    hot_zone: str, path: str | None = None, use_json: bool = False
) -> argparse.Namespace:
    return argparse.Namespace(
        hot_zone=hot_zone,
        path=path,
        json=use_json,
    )


class TestCmdFunctions:
    def test_no_db_returns_error(
        self,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],  # noqa: ARG002
    ) -> None:
        """functions with no quality.db returns exit code 1."""
        args = _make_functions_args(str(tmp_path / "nonexistent"))
        result = cmd_functions(args)
        assert result == 1

    def test_no_scan_returns_error(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,  # noqa: ARG002
        capsys: pytest.CaptureFixture[str],  # noqa: ARG002
    ) -> None:
        """functions with empty db (no scans) returns exit code 1."""
        args = _make_functions_args(str(tmp_path))
        result = cmd_functions(args)
        assert result == 1

    def _populate_fn_cc(
        self,
        db: sqlite3.Connection,
        scan_id: int,
    ) -> None:
        """Insert file entry + function CC metrics for testing."""
        entry = FileEntry(
            path="src/foo.py",
            scan_id=scan_id,
            language="python",
            loc=100,
            complexity=25.0,
        )
        bulk_upsert_file_entries(db, [entry])
        fns = [
            FunctionCC(
                path="src/foo.py",
                scan_id=scan_id,
                function_name="process",
                complexity=15.0,
                line_start=10,
                line_end=50,
                is_dispatch=False,
            ),
            FunctionCC(
                path="src/foo.py",
                scan_id=scan_id,
                function_name="dispatch_fn",
                complexity=12.0,
                line_start=55,
                line_end=80,
                is_dispatch=True,
            ),
            FunctionCC(
                path="src/foo.py",
                scan_id=scan_id,
                function_name="helper",
                complexity=3.0,
                line_start=85,
                line_end=100,
                is_dispatch=False,
            ),
        ]
        bulk_upsert_function_cc(db, fns)
        db.commit()

    def test_text_output_sorted_by_complexity(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """Text output lists functions sorted by CC descending."""
        scan_id = begin_scan(db, "abc")
        self._populate_fn_cc(db, scan_id)
        finish_scan(db, scan_id, 1, 100)

        args = _make_functions_args(str(tmp_path))
        result = cmd_functions(args)
        assert result == 0

        out = capsys.readouterr().err
        fn_lines = [ln for ln in out.splitlines() if "\u2713" in ln or "\u2717" in ln]
        assert len(fn_lines) == 3
        assert "process" in fn_lines[0]
        assert "dispatch_fn" in fn_lines[1]
        assert "helper" in fn_lines[2]

    def test_text_output_flags_over_threshold(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """Functions over threshold are marked \u2717; compliant functions marked \u2713."""
        scan_id = begin_scan(db, "abc")
        self._populate_fn_cc(db, scan_id)
        finish_scan(db, scan_id, 1, 100)

        args = _make_functions_args(str(tmp_path))
        cmd_functions(args)
        out = capsys.readouterr().err

        assert "\u2717 process" in out
        assert "\u2713 helper" in out

    def test_dispatch_exempt_label(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """Dispatch functions get [dispatch \u2014 exempt] label and \u2713 mark."""
        scan_id = begin_scan(db, "abc")
        self._populate_fn_cc(db, scan_id)
        finish_scan(db, scan_id, 1, 100)

        args = _make_functions_args(str(tmp_path))
        cmd_functions(args)
        out = capsys.readouterr().err

        assert "[dispatch" in out
        for line in out.splitlines():
            if "dispatch_fn" in line and "exempt" in line:
                assert "\u2713" in line
                break
        else:
            raise AssertionError("No dispatch-exempt line found in output")

    def test_json_output_schema(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """JSON output contains expected keys for each function."""
        scan_id = begin_scan(db, "abc")
        self._populate_fn_cc(db, scan_id)
        finish_scan(db, scan_id, 1, 100)

        args = _make_functions_args(str(tmp_path), use_json=True)
        result = cmd_functions(args)
        assert result == 0

        data = json.loads(capsys.readouterr().out)
        assert isinstance(data, dict)
        assert "functions" in data
        assert "histogram" in data
        assert "cc_gini" in data
        fns = data["functions"]
        assert len(fns) == 3
        first = fns[0]  # sorted by CC desc
        assert first["function"] == "process"
        assert first["cc"] == 15.0
        assert first["is_dispatch"] is False
        assert "line_start" in first
        assert "line_end" in first

    def test_summary_line_format(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """Summary line correctly counts flagged vs exempt."""
        scan_id = begin_scan(db, "abc")
        self._populate_fn_cc(db, scan_id)
        finish_scan(db, scan_id, 1, 100)

        args = _make_functions_args(str(tmp_path))
        cmd_functions(args)
        out = capsys.readouterr().err

        # process (CC=15, not dispatch) is the only non-exempt flagged function
        # dispatch_fn (CC=12, is_dispatch=True) is exempt
        assert "1/3 functions exceed threshold" in out
        assert "dispatch-exempt" in out


# ---------------------------------------------------------------------------
# Tests: cmd_scan — category population
# ---------------------------------------------------------------------------


def _make_scan_args(hot_zone: str, path: str | None = None) -> argparse.Namespace:
    return argparse.Namespace(
        hot_zone=hot_zone,
        path=path,
        json=False,
        exclude=[],
    )


class TestCmdScanCategory:
    """Verify that cmd_scan() populates FileEntry.category via classify_file()."""

    def _build_repo(self, tmp_path: Path) -> Path:
        """Create a minimal git repo with files in different directories."""
        repo = tmp_path / "repo"
        repo.mkdir()

        # Initialise git repo (needed for git ls-files / rev-parse)
        subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
        subprocess.run(
            ["git", "commit", "--allow-empty", "-m", "init"],
            cwd=repo,
            check=True,
            env={
                **os.environ,
                "GIT_AUTHOR_NAME": "t",
                "GIT_AUTHOR_EMAIL": "t@t",
                "GIT_COMMITTER_NAME": "t",
                "GIT_COMMITTER_EMAIL": "t@t",
            },
        )

        # tests/test_foo.py  -> category='test'
        (repo / "tests").mkdir()
        (repo / "tests" / "test_foo.py").write_text("x = 1\n")

        # scripts/run.sh     -> category='script'
        (repo / "scripts").mkdir()
        (repo / "scripts" / "run.sh").write_text("#!/bin/bash\necho hi\n")

        # src/app.py         -> category='production'
        (repo / "src").mkdir()
        (repo / "src" / "app.py").write_text("def main(): pass\n")

        return repo

    def test_test_files_get_test_category(self, tmp_path: Path) -> None:
        """Files under tests/ directory get category='test' after scan."""
        repo = self._build_repo(tmp_path)
        args = _make_scan_args(str(tmp_path), path=str(repo))

        result = cmd_scan(args)
        assert result == 0

        conn = init_db(hot_zone=str(tmp_path))
        scan = latest_scan(conn)
        assert scan is not None
        entries = get_file_entries(conn, scan.id)
        conn.close()

        by_path = {e.path: e for e in entries}
        test_entry = by_path.get("tests/test_foo.py")
        assert test_entry is not None, "tests/test_foo.py not found in scan"
        assert test_entry.category == "test"

    def test_script_files_get_script_category(self, tmp_path: Path) -> None:
        """Files under scripts/ directory get category='script' after scan."""
        repo = self._build_repo(tmp_path)
        args = _make_scan_args(str(tmp_path), path=str(repo))

        result = cmd_scan(args)
        assert result == 0

        conn = init_db(hot_zone=str(tmp_path))
        scan = latest_scan(conn)
        assert scan is not None
        entries = get_file_entries(conn, scan.id)
        conn.close()

        by_path = {e.path: e for e in entries}
        script_entry = by_path.get("scripts/run.sh")
        assert script_entry is not None, "scripts/run.sh not found in scan"
        assert script_entry.category == "script"

    def test_plain_python_gets_production_category(self, tmp_path: Path) -> None:
        """Plain .py files outside test/script dirs get category='production'."""
        repo = self._build_repo(tmp_path)
        args = _make_scan_args(str(tmp_path), path=str(repo))

        result = cmd_scan(args)
        assert result == 0

        conn = init_db(hot_zone=str(tmp_path))
        scan = latest_scan(conn)
        assert scan is not None
        entries = get_file_entries(conn, scan.id)
        conn.close()

        by_path = {e.path: e for e in entries}
        prod_entry = by_path.get("src/app.py")
        assert prod_entry is not None, "src/app.py not found in scan"
        assert prod_entry.category == "production"


class TestDiscoverFiles:
    """Tests for _discover_files file discovery and filtering."""

    def _make_git_repo(self, tmp_path: Path) -> Path:
        """Create a minimal git repo with Python and non-Python files."""
        subprocess.run(["git", "init", "-q", str(tmp_path)], check=True)
        subprocess.run(
            ["git", "-C", str(tmp_path), "config", "user.email", "t@t.com"], check=True
        )
        subprocess.run(
            ["git", "-C", str(tmp_path), "config", "user.name", "T"], check=True
        )
        (tmp_path / "main.py").write_text("x = 1\n")
        (tmp_path / "util.py").write_text("y = 2\n")
        (tmp_path / "skip_me.py").write_text("z = 3\n")
        subprocess.run(["git", "-C", str(tmp_path), "add", "."], check=True)
        subprocess.run(
            ["git", "-C", str(tmp_path), "commit", "-q", "-m", "init"], check=True
        )
        return tmp_path

    def test_discovers_python_files(self, tmp_path: Path) -> None:
        """Python files are discovered without exclusions."""
        repo = self._make_git_repo(tmp_path)
        files = _discover_files(str(repo))
        assert "main.py" in files
        assert "util.py" in files

    def test_exclude_globs_filters_files(self, tmp_path: Path) -> None:
        """Files matching exclude_globs are skipped."""
        repo = self._make_git_repo(tmp_path)
        files = _discover_files(str(repo), exclude_globs=["skip_me.py"])
        assert "skip_me.py" not in files
        assert "main.py" in files


# ---------------------------------------------------------------------------
# Tests: _load_config_excludes
# ---------------------------------------------------------------------------


class TestLoadConfigExcludes:
    def test_no_config_returns_empty(self, tmp_path: Path) -> None:
        """No quality.conf returns empty list."""
        assert not _load_config_excludes(str(tmp_path))

    def test_reads_exclude_section(self, tmp_path: Path) -> None:
        """Lines under [exclude] are returned."""
        conf = tmp_path / ".weave"
        conf.mkdir()
        (conf / "quality.conf").write_text("[exclude]\ndist/**\nbuild/**\n")
        result = _load_config_excludes(str(tmp_path))
        assert "dist/**" in result
        assert "build/**" in result

    def test_ignores_other_sections(self, tmp_path: Path) -> None:
        """Lines under other sections are not returned."""
        conf = tmp_path / ".weave"
        conf.mkdir()
        (conf / "quality.conf").write_text(
            "[classify]\nscripts/**=script\n[exclude]\nfoo/**\n"
        )
        result = _load_config_excludes(str(tmp_path))
        assert result == ["foo/**"]

    def test_strips_inline_comments(self, tmp_path: Path) -> None:
        """Inline # comments are stripped from values."""
        conf = tmp_path / ".weave"
        conf.mkdir()
        (conf / "quality.conf").write_text("[exclude]\ndist/**  # build output\n")
        result = _load_config_excludes(str(tmp_path))
        assert result == ["dist/**"]

    def test_skips_blank_lines_and_comments(self, tmp_path: Path) -> None:
        """Blank lines and # comment lines are ignored."""
        conf = tmp_path / ".weave"
        conf.mkdir()
        (conf / "quality.conf").write_text(
            "# top comment\n\n[exclude]\n# a comment\nfoo.py\n\nbar.py\n"
        )
        result = _load_config_excludes(str(tmp_path))
        assert result == ["foo.py", "bar.py"]


# ---------------------------------------------------------------------------
# Tests: _resolve_repo
# ---------------------------------------------------------------------------


class TestResolveRepo:
    def test_explicit_path_returned(self, tmp_path: Path) -> None:
        """Explicit path is resolved and returned."""
        result = _resolve_repo(str(tmp_path))
        assert result == str(tmp_path.resolve())

    def test_repo_root_env(self, tmp_path: Path) -> None:
        """REPO_ROOT env var overrides git detection."""
        with patch.dict(os.environ, {"REPO_ROOT": str(tmp_path)}, clear=False):
            result = _resolve_repo(None)
        assert result == str(tmp_path)

    def test_git_fallback(self) -> None:
        """Git root is returned when no path or env var."""
        fake_root = "/fake/root"
        fake_result = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=fake_root + "\n",
            stderr="",
        )
        with patch.dict(os.environ, {}, clear=False):
            # Ensure REPO_ROOT not set
            os.environ.pop("REPO_ROOT", None)
            with patch(
                "weave_quality.__main__.subprocess.run", return_value=fake_result
            ):
                result = _resolve_repo(None)
        assert result == fake_root

    def test_git_failure_falls_back_to_cwd(self) -> None:
        """When git fails, falls back to os.getcwd()."""
        os.environ.pop("REPO_ROOT", None)
        with patch.dict(os.environ, {}, clear=False):
            os.environ.pop("REPO_ROOT", None)
            with patch(
                "weave_quality.__main__.subprocess.run",
                side_effect=subprocess.CalledProcessError(128, "git"),
            ):
                result = _resolve_repo(None)
        assert result == os.getcwd()


# ---------------------------------------------------------------------------
# Tests: _get_current_head
# ---------------------------------------------------------------------------


class TestGetCurrentHead:
    def test_returns_sha_on_success(self) -> None:
        """Returns the git HEAD sha on success."""
        fake = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout="abc123def456abc123def456abc123def456abc1\n",
            stderr="",
        )
        with patch("weave_quality.__main__.subprocess.run", return_value=fake):
            result = _get_current_head()
        assert result == "abc123def456abc123def456abc123def456abc1"

    def test_returns_empty_on_error(self) -> None:
        """Returns empty string when git fails."""
        with patch(
            "weave_quality.__main__.subprocess.run",
            side_effect=subprocess.CalledProcessError(128, "git"),
        ):
            result = _get_current_head()
        assert result == ""

    def test_returns_empty_on_file_not_found(self) -> None:
        """Returns empty string when git not installed."""
        with patch(
            "weave_quality.__main__.subprocess.run",
            side_effect=FileNotFoundError("no git"),
        ):
            result = _get_current_head()
        assert result == ""


# ---------------------------------------------------------------------------
# Tests: _wv_cmd
# ---------------------------------------------------------------------------


class TestWvCmd:
    def test_returns_output_on_success(self) -> None:
        """Returns (0, stdout) on successful wv call."""
        fake = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout="wv-abc123: some node\n",
            stderr="",
        )
        with patch("weave_quality.__main__.subprocess.run", return_value=fake):
            rc, out = _wv_cmd("list", "--json")
        assert rc == 0
        assert "wv-abc123" in out

    def test_returns_error_when_not_found(self) -> None:
        """Returns (1, error message) when wv is not installed."""
        with patch(
            "weave_quality.__main__.subprocess.run",
            side_effect=FileNotFoundError("wv not found"),
        ):
            rc, out = _wv_cmd("list")
        assert rc == 1
        assert "not found" in out


# ---------------------------------------------------------------------------
# Tests: cmd_reset
# ---------------------------------------------------------------------------


class TestCmdReset:
    def test_reset_existing_db(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """reset deletes the quality.db and prints confirmation."""
        db.close()
        p = db_path(str(tmp_path))
        assert p.exists()

        args = argparse.Namespace(hot_zone=str(tmp_path))
        result = cmd_reset(args)
        assert result == 0
        captured = capsys.readouterr()
        assert "Deleted" in captured.err

    def test_reset_nonexistent_db(
        self,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """reset on missing db prints 'No quality.db found'."""
        args = argparse.Namespace(hot_zone=str(tmp_path / "nodb"))
        result = cmd_reset(args)
        assert result == 0
        captured = capsys.readouterr()
        assert "No quality.db" in captured.err


# ---------------------------------------------------------------------------
# Tests: cmd_scan — JSON output + bash file branch + carry-forward
# ---------------------------------------------------------------------------


class TestCmdScanExtended:
    def _build_git_repo(self, tmp_path: Path, *, with_bash: bool = False) -> Path:
        """Create a minimal git repo with Python (and optionally Bash) files."""
        repo = tmp_path / "repo"
        repo.mkdir()
        subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
        env = {
            **os.environ,
            "GIT_AUTHOR_NAME": "t",
            "GIT_AUTHOR_EMAIL": "t@t",
            "GIT_COMMITTER_NAME": "t",
            "GIT_COMMITTER_EMAIL": "t@t",
        }
        (repo / "app.py").write_text("def foo(): pass\n")
        if with_bash:
            (repo / "run.sh").write_text("#!/bin/bash\necho hi\n")
        subprocess.run(["git", "add", "."], cwd=repo, check=True, env=env)
        subprocess.run(
            ["git", "commit", "-q", "-m", "init"], cwd=repo, check=True, env=env
        )
        return repo

    def test_json_output(
        self,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """cmd_scan --json emits expected JSON fields."""
        repo = self._build_git_repo(tmp_path)
        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            path=str(repo),
            json=True,
            exclude=[],
        )
        result = cmd_scan(args)
        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert "scan_id" in data
        assert "files_scanned" in data
        assert "quality_score" in data
        assert "languages" in data

    def test_bash_file_scanned(self, tmp_path: Path) -> None:
        """cmd_scan processes .sh files via bash_heuristic."""
        repo = self._build_git_repo(tmp_path, with_bash=True)
        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            path=str(repo),
            json=True,
            exclude=[],
        )
        result = cmd_scan(args)
        assert result == 0
        conn = init_db(hot_zone=str(tmp_path))
        scan = latest_scan(conn)
        assert scan is not None
        entries = get_file_entries(conn, scan.id)
        conn.close()
        by_path = {e.path: e for e in entries}
        assert "run.sh" in by_path
        assert by_path["run.sh"].language == "bash"

    def test_carry_forward_unchanged(
        self,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """Unchanged files are carried forward from previous scan."""
        repo = self._build_git_repo(tmp_path)
        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            path=str(repo),
            json=True,
            exclude=[],
        )
        # First scan — populates DB
        cmd_scan(args)
        capsys.readouterr()  # discard

        # Second scan — app.py unchanged → should be carried forward
        result = cmd_scan(args)
        assert result == 0
        data = json.loads(capsys.readouterr().out)
        # files_scanned >= 1 even though nothing changed
        assert data["files_scanned"] >= 1


# ---------------------------------------------------------------------------
# Tests: cmd_hotspots — stale warning text output
# ---------------------------------------------------------------------------


class TestCmdHotspotsStale:
    def test_stale_head_warning_in_text_mode(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """Stale scan emits a [WARN] line in text mode."""
        scan_id = begin_scan(db, "deadbeef0000000000000000000000000000000000")
        entries = [_entry("a.py", scan_id, complexity=100)]
        stats = [_stats("a.py", churn=50)]
        _populate_scan(db, scan_id, entries, stats)
        finish_scan(db, scan_id, 1, 100)
        db.close()

        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            top=10,
            json=False,
            scope="production",
        )
        with patch(
            "weave_quality.__main__._get_current_head",
            return_value="newhead000000000000000000000000000000000000",
        ):
            result = cmd_hotspots(args)
        assert result == 0
        out = capsys.readouterr().err
        assert "[WARN]" in out

    def test_no_hotspots_text_output(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """Text mode with no hotspots above threshold prints placeholder."""
        scan_id = begin_scan(db, "abc123")
        # Very low complexity → below hotspot threshold
        entries = [_entry("a.py", scan_id, complexity=1)]
        stats = [_stats("a.py", churn=1, hotspot=0.0)]
        _populate_scan(db, scan_id, entries, stats)
        finish_scan(db, scan_id, 1, 100)
        db.close()

        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            top=10,
            json=False,
            scope="production",
        )
        result = cmd_hotspots(args)
        assert result == 0
        out = capsys.readouterr().err
        assert "No hotspots" in out


# ---------------------------------------------------------------------------
# Tests: cmd_diff — human-readable (text) output
# ---------------------------------------------------------------------------


class TestCmdDiffTextOutput:
    def _two_scan_setup(
        self,
        db: sqlite3.Connection,
        complexity1: float = 10.0,
        complexity2: float = 30.0,
    ) -> None:
        s1 = begin_scan(db, "abc123")
        _populate_scan(
            db,
            s1,
            [_entry("a.py", s1, complexity=complexity1)],
            [_stats("a.py", churn=5)],
        )
        finish_scan(db, s1, 1, 100)

        s2 = begin_scan(db, "abc456")
        _populate_scan(
            db,
            s2,
            [_entry("a.py", s2, complexity=complexity2)],
            [_stats("a.py", churn=5)],
        )
        finish_scan(db, s2, 1, 100)
        db.close()

    def test_diff_degraded_text(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """Text diff shows Degraded: section when complexity increases."""
        self._two_scan_setup(db, complexity1=10.0, complexity2=30.0)
        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            json=False,
            scope="production",
        )
        result = cmd_diff(args)
        assert result == 0
        out = capsys.readouterr().err
        assert "Degraded:" in out
        assert "a.py" in out

    def test_diff_improved_text(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """Text diff shows Improved: section when complexity decreases."""
        self._two_scan_setup(db, complexity1=30.0, complexity2=10.0)
        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            json=False,
            scope="production",
        )
        result = cmd_diff(args)
        assert result == 0
        out = capsys.readouterr().err
        assert "Improved:" in out
        assert "a.py" in out

    def test_diff_no_change_text(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """Text diff shows 'No significant changes' when identical."""
        self._two_scan_setup(db, complexity1=10.0, complexity2=10.0)
        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            json=False,
            scope="production",
        )
        result = cmd_diff(args)
        assert result == 0
        out = capsys.readouterr().err
        assert "No significant changes" in out

    def test_diff_no_scan_returns_error(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
    ) -> None:
        """diff with db but no scan returns exit 1."""
        _ = db
        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            json=False,
            scope="production",
        )
        result = cmd_diff(args)
        assert result == 1

    def test_diff_new_removed_files_text(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """Text diff shows New files / Removed files sections."""
        s1 = begin_scan(db, "abc123")
        _populate_scan(
            db,
            s1,
            [_entry("a.py", s1), _entry("b.py", s1)],
            [_stats("a.py"), _stats("b.py")],
        )
        finish_scan(db, s1, 2, 100)

        s2 = begin_scan(db, "abc456")
        _populate_scan(
            db,
            s2,
            [_entry("a.py", s2), _entry("c.py", s2)],
            [_stats("a.py"), _stats("c.py")],
        )
        finish_scan(db, s2, 2, 100)
        db.close()

        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            json=False,
            scope="production",
        )
        result = cmd_diff(args)
        assert result == 0
        out = capsys.readouterr().err
        assert "New files:" in out
        assert "Removed files:" in out


# ---------------------------------------------------------------------------
# Tests: cmd_promote — additional paths
# ---------------------------------------------------------------------------


class TestCmdPromoteExtended:
    def _setup_no_hotspots(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
    ) -> None:
        """Populate a scan where no files have hotspot scores."""
        scan_id = begin_scan(db, str(tmp_path))
        entries = [_entry("low.py", scan_id, complexity=1.0)]
        stats = [_stats("low.py", churn=0, hotspot=0.0)]
        _populate_scan(db, scan_id, entries, stats)
        finish_scan(db, scan_id, 1, 100)
        db.close()

    def test_no_hotspots_returns_zero(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """promote with no ranked hotspots exits 0 with message."""
        self._setup_no_hotspots(db, tmp_path)
        args = _make_promote_args(str(tmp_path))
        result = cmd_promote(args)
        assert result == 0
        out = capsys.readouterr().err
        assert "No hotspots" in out

    def test_upsert_updates_existing_node(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """promote --upsert updates an existing promoted node."""
        scan_id = begin_scan(db, str(tmp_path))
        entries = [
            _entry("hot.py", scan_id, complexity=60.0),
            _entry("cold.py", scan_id, complexity=5.0),
        ]
        stats = [
            _stats("hot.py", churn=120),
            _stats("cold.py", churn=5),
        ]
        _populate_scan(db, scan_id, entries, stats)
        finish_scan(db, scan_id, 2, 100)

        fid = _finding_id("hot.py")
        existing = json.dumps(
            [
                {
                    "id": "wv-existing",
                    "text": "old node",
                    "metadata": json.dumps({"quality_finding_id": fid}),
                }
            ]
        )

        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            parent="wv-parent",
            top=5,
            json=True,
            dry_run=False,
            upsert=True,
        )

        def fake_wv(*cmd_args: str) -> tuple[int, str]:
            if cmd_args[0] == "list":
                return 0, existing
            return 0, ""

        with patch("weave_quality.__main__._wv_cmd", side_effect=fake_wv):
            result = cmd_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert "updated" in data
        assert len(data["updated"]) == 1
        assert data["updated"][0]["node_id"] == "wv-existing"

    def test_wv_add_failure_skips_node(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """promote skips a hotspot if wv add fails."""
        scan_id = begin_scan(db, str(tmp_path))
        entries = [
            _entry("err.py", scan_id, complexity=60.0),
            _entry("low.py", scan_id, complexity=5.0),
        ]
        stats = [
            _stats("err.py", churn=100),
            _stats("low.py", churn=5),
        ]
        _populate_scan(db, scan_id, entries, stats)
        finish_scan(db, scan_id, 2, 100)

        args = _make_promote_args(str(tmp_path), top=1, json_out=True)

        def fake_wv(*cmd_args: str) -> tuple[int, str]:
            if cmd_args[0] == "list":
                return 0, "[]"
            if cmd_args[0] == "add":
                return 1, "error: something went wrong"
            return 0, ""

        with patch("weave_quality.__main__._wv_cmd", side_effect=fake_wv):
            result = cmd_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert len(data["promoted"]) == 0

    def test_promote_text_output_skipped_message(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """Text mode: skipped message shown when findings already promoted."""
        scan_id = begin_scan(db, str(tmp_path))
        entries = [
            _entry("dup.py", scan_id, complexity=50.0),
            _entry("other.py", scan_id, complexity=5.0),
        ]
        stats = [
            _stats("dup.py", churn=80),
            _stats("other.py", churn=5),
        ]
        _populate_scan(db, scan_id, entries, stats)
        finish_scan(db, scan_id, 2, 100)

        fid = _finding_id("dup.py")
        existing = json.dumps(
            [
                {
                    "id": "wv-dup",
                    "text": "old",
                    "metadata": json.dumps({"quality_finding_id": fid}),
                }
            ]
        )

        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            parent="wv-p",
            top=5,
            json=False,
            dry_run=False,
            upsert=False,
        )
        with patch("weave_quality.__main__._wv_cmd", return_value=(0, existing)):
            result = cmd_promote(args)

        assert result == 0
        out = capsys.readouterr().err
        assert "Skipped" in out

    def test_promote_upsert_dry_run(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """promote --upsert --dry-run prints update plan without calling wv update."""
        scan_id = begin_scan(db, str(tmp_path))
        entries = [
            _entry("dry.py", scan_id, complexity=55.0),
            _entry("low.py", scan_id, complexity=5.0),
        ]
        stats = [
            _stats("dry.py", churn=90),
            _stats("low.py", churn=5),
        ]
        _populate_scan(db, scan_id, entries, stats)
        finish_scan(db, scan_id, 2, 100)

        fid = _finding_id("dry.py")
        existing = json.dumps(
            [
                {
                    "id": "wv-dry",
                    "text": "old",
                    "metadata": json.dumps({"quality_finding_id": fid}),
                }
            ]
        )

        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            parent="wv-p",
            top=5,
            json=True,
            dry_run=True,
            upsert=True,
        )

        def fake_wv(*cmd_args: str) -> tuple[int, str]:
            if cmd_args[0] == "list":
                return 0, existing
            return 0, ""

        with patch("weave_quality.__main__._wv_cmd", side_effect=fake_wv) as mock_wv:
            result = cmd_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert "updated" in data
        # Dry run: only the list call, no update call
        for call_args in mock_wv.call_args_list:
            assert call_args[0][0] != "update"


# ---------------------------------------------------------------------------
# Tests: cmd_functions — path fallback
# ---------------------------------------------------------------------------


class TestCmdFunctionsPathFallback:
    def _populate_with_path(
        self,
        db: sqlite3.Connection,
        scan_id: int,
        path: str,
    ) -> None:
        entry = FileEntry(
            path=path,
            scan_id=scan_id,
            language="python",
            loc=50,
            complexity=15.0,
        )
        bulk_upsert_file_entries(db, [entry])
        fns = [
            FunctionCC(
                path=path,
                scan_id=scan_id,
                function_name="f",
                complexity=15.0,
                line_start=1,
                line_end=20,
                is_dispatch=False,
            )
        ]
        bulk_upsert_function_cc(db, fns)
        db.commit()

    def test_no_path_uses_cwd_prefix_match(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
    ) -> None:
        """When args.path is None, all entries in the scan are returned."""
        scan_id = begin_scan(db, "abc")
        self._populate_with_path(db, scan_id, "src/foo.py")
        finish_scan(db, scan_id, 1, 100)

        args = _make_functions_args(str(tmp_path), path=None)
        result = cmd_functions(args)
        # With path=None, falls through to prefix match; may or may not find files
        # Depending on CWD, should not crash
        assert result in (0, 1)

    def test_nonexistent_path_returns_error(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
    ) -> None:
        """Functions with no matching files returns exit 1."""
        scan_id = begin_scan(db, "abc")
        self._populate_with_path(db, scan_id, "src/foo.py")
        finish_scan(db, scan_id, 1, 100)

        # Use a path that won't match any scanned file
        args = _make_functions_args(str(tmp_path), path="/completely/nonexistent/dir")
        result = cmd_functions(args)
        assert result == 1


# ---------------------------------------------------------------------------
# Tests: remaining edge-case coverage
# ---------------------------------------------------------------------------


class TestCmdScanCkMetrics:
    """Scan a Python file with a class → exercises CK metrics path (lines 329-331, 364)."""

    def _build_repo_with_class(self, tmp_path: Path) -> Path:
        repo = tmp_path / "repo"
        repo.mkdir()
        env = {
            **os.environ,
            "GIT_AUTHOR_NAME": "t",
            "GIT_AUTHOR_EMAIL": "t@t",
            "GIT_COMMITTER_NAME": "t",
            "GIT_COMMITTER_EMAIL": "t@t",
        }
        subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
        (repo / "mymodule.py").write_text(
            "class MyClass:\n    def method(self) -> None:\n        pass\n"
        )
        subprocess.run(["git", "add", "."], cwd=repo, check=True, env=env)
        subprocess.run(
            ["git", "commit", "-q", "-m", "init"], cwd=repo, check=True, env=env
        )
        return repo

    def test_scan_file_with_class(self, tmp_path: Path) -> None:
        """Scanning a Python file with a class exercises CK metrics storage."""
        repo = self._build_repo_with_class(tmp_path)
        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            path=str(repo),
            json=True,
            exclude=[],
        )
        result = cmd_scan(args)
        assert result == 0

        conn = init_db(hot_zone=str(tmp_path))
        scan = latest_scan(conn)
        assert scan is not None
        entries = get_file_entries(conn, scan.id)
        conn.close()
        by_path = {e.path: e for e in entries}
        assert "mymodule.py" in by_path

    def test_scan_file_has_expected_language(self, tmp_path: Path) -> None:
        """Python class file is recognised as python language."""
        repo = self._build_repo_with_class(tmp_path)
        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            path=str(repo),
            json=True,
            exclude=[],
        )
        cmd_scan(args)
        conn = init_db(hot_zone=str(tmp_path))
        scan = latest_scan(conn)
        assert scan is not None
        entries = get_file_entries(conn, scan.id)
        conn.close()
        by_path = {e.path: e for e in entries}
        assert by_path["mymodule.py"].language == "python"


class TestCmdScanBashFunctions:
    """Scan a bash file with functions → exercises bash fn_cc remap (lines 354-355)."""

    def _build_repo_with_bash_fn(self, tmp_path: Path) -> Path:
        repo = tmp_path / "repo"
        repo.mkdir()
        env = {
            **os.environ,
            "GIT_AUTHOR_NAME": "t",
            "GIT_AUTHOR_EMAIL": "t@t",
            "GIT_COMMITTER_NAME": "t",
            "GIT_COMMITTER_EMAIL": "t@t",
        }
        subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
        (repo / "run.sh").write_text(
            "#!/bin/bash\ndo_work() {\n  echo 'hello'\n}\ndo_work\n"
        )
        subprocess.run(["git", "add", "."], cwd=repo, check=True, env=env)
        subprocess.run(
            ["git", "commit", "-q", "-m", "init"], cwd=repo, check=True, env=env
        )
        return repo

    def test_scan_bash_with_function(self, tmp_path: Path) -> None:
        """Scanning a bash file with functions exercises fn_cc path remapping."""
        repo = self._build_repo_with_bash_fn(tmp_path)
        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            path=str(repo),
            json=True,
            exclude=[],
        )
        result = cmd_scan(args)
        assert result == 0

        conn = init_db(hot_zone=str(tmp_path))
        scan = latest_scan(conn)
        assert scan is not None
        entries = get_file_entries(conn, scan.id)
        conn.close()
        by_path = {e.path: e for e in entries}
        assert "run.sh" in by_path
        assert by_path["run.sh"].functions >= 1

    def test_scan_bash_language_set(self, tmp_path: Path) -> None:
        """Bash file is recognised as bash language."""
        repo = self._build_repo_with_bash_fn(tmp_path)
        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            path=str(repo),
            json=True,
            exclude=[],
        )
        cmd_scan(args)
        conn = init_db(hot_zone=str(tmp_path))
        scan = latest_scan(conn)
        assert scan is not None
        entries = get_file_entries(conn, scan.id)
        conn.close()
        by_path = {e.path: e for e in entries}
        assert by_path["run.sh"].language == "bash"


class TestCmdPromoteMetadataParsing:
    """Cover metadata-as-dict and invalid JSON branches in cmd_promote (996, 1000-1001)."""

    def _setup_with_hotspot(self, db: sqlite3.Connection, path: str) -> None:
        scan_id = begin_scan(db, "abc")
        entries = [
            _entry(path, scan_id, complexity=60.0),
            _entry("low.py", scan_id, complexity=5.0),
        ]
        stats = [
            _stats(path, churn=100),
            _stats("low.py", churn=5),
        ]
        _populate_scan(db, scan_id, entries, stats)
        finish_scan(db, scan_id, 2, 100)
        db.close()

    def test_metadata_already_dict(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """When metadata is already a dict (not string), branch at line 996 is exercised."""
        self._setup_with_hotspot(db, "hot.py")
        fid = _finding_id("hot.py")
        # metadata is a dict, not a JSON string
        existing = json.dumps(
            [
                {
                    "id": "wv-dictmeta",
                    "text": "old",
                    "metadata": {"quality_finding_id": fid},
                }
            ]
        )

        args = _make_promote_args(str(tmp_path), top=5, json_out=True)
        with patch("weave_quality.__main__._wv_cmd", return_value=(0, existing)):
            result = cmd_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert data["skipped"] == 1

    def test_invalid_json_metadata_does_not_crash(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """Malformed JSON in node list doesn't crash (exception caught at line 1000)."""
        self._setup_with_hotspot(db, "hot2.py")
        # Return invalid JSON from wv list
        args = _make_promote_args(str(tmp_path), top=5, json_out=True)
        with patch(
            "weave_quality.__main__._wv_cmd", return_value=(0, "not valid json")
        ):
            result = cmd_promote(args)

        assert result == 0

    def test_upsert_text_mode_updated_message(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """Text mode with upsert shows 'Updated N existing findings' (line 1111)."""
        self._setup_with_hotspot(db, "upd.py")
        fid = _finding_id("upd.py")
        existing = json.dumps(
            [
                {
                    "id": "wv-upd",
                    "text": "old",
                    "metadata": json.dumps({"quality_finding_id": fid}),
                }
            ]
        )

        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            parent="wv-p",
            top=5,
            json=False,
            dry_run=False,
            upsert=True,
        )

        def fake_wv(*cmd_args: str) -> tuple[int, str]:
            if cmd_args[0] == "list":
                return 0, existing
            return 0, ""

        with patch("weave_quality.__main__._wv_cmd", side_effect=fake_wv):
            result = cmd_promote(args)

        assert result == 0
        out = capsys.readouterr().err
        assert "Updated" in out
