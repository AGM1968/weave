"""Tests for weave_quality CLI commands.

Covers: hotspots, diff, promote, health-info, context-files, functions.
"""
# pylint: disable=missing-class-docstring,missing-function-docstring,redefined-outer-name,unused-argument

from __future__ import annotations

import argparse
import io
import json
import sqlite3
from collections.abc import Generator
from pathlib import Path
from unittest.mock import patch

import pytest

from weave_quality.__main__ import (
    _finding_id,
    cmd_context_files,
    cmd_diff,
    cmd_functions,
    cmd_health_info,
    cmd_hotspots,
    cmd_promote,
)
from weave_quality.db import (
    begin_scan,
    bulk_upsert_file_entries,
    bulk_upsert_function_cc,
    bulk_upsert_git_stats,
    finish_scan,
    init_db,
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
    path: str, churn: int = 50, hotspot: float = 0.0,
) -> GitStats:
    return GitStats(
        path=path,
        churn=churn,
        age_days=30,
        authors=2,
        hotspot=hotspot,
    )


def _populate_scan(
    conn: sqlite3.Connection, scan_id: int,  # pylint: disable=unused-argument
    entries: list[FileEntry], stats: list[GitStats],
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
        )
        result = cmd_hotspots(args)
        assert result == 1

    def test_no_scan_returns_error(self, db: sqlite3.Connection, tmp_path: Path) -> None:
        """hotspots with empty db returns error."""
        _ = db  # ensure DB is created
        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            top=10,
            json=False,
        )
        result = cmd_hotspots(args)
        assert result == 1

    def test_hotspots_text_output(
        self, db: sqlite3.Connection, tmp_path: Path, capsys: pytest.CaptureFixture[str],
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
        )
        result = cmd_hotspots(args)
        assert result == 0
        captured = capsys.readouterr()
        assert "a.py" in captured.err

    def test_hotspots_json_output(
        self, db: sqlite3.Connection, tmp_path: Path, capsys: pytest.CaptureFixture[str],
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
        self, db: sqlite3.Connection, tmp_path: Path, capsys: pytest.CaptureFixture[str],
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
        )
        result = cmd_diff(args)
        assert result == 1

    def test_single_scan_no_previous(
        self, db: sqlite3.Connection, tmp_path: Path, capsys: pytest.CaptureFixture[str],
    ) -> None:
        """diff with only one scan returns exit 0 with message."""
        scan_id = begin_scan(db, "abc123")
        finish_scan(db, scan_id, 5, 100)
        db.commit()
        db.close()

        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            json=False,
        )
        result = cmd_diff(args)
        assert result == 0
        captured = capsys.readouterr()
        assert "No previous scan" in captured.err

    def test_single_scan_json(
        self, db: sqlite3.Connection, tmp_path: Path, capsys: pytest.CaptureFixture[str],
    ) -> None:
        """diff --json with one scan returns null previous."""
        scan_id = begin_scan(db, "abc123")
        finish_scan(db, scan_id, 5, 100)
        db.commit()
        db.close()

        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            json=True,
        )
        result = cmd_diff(args)
        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert data["scan_previous"] is None
        assert data["scan_current"] == scan_id

    def test_diff_two_scans_no_change(
        self, db: sqlite3.Connection, tmp_path: Path, capsys: pytest.CaptureFixture[str],
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
        )
        result = cmd_diff(args)
        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert data["improved"] == []
        assert data["degraded"] == []
        assert data["new_files"] == []
        assert data["removed_files"] == []

    def test_diff_shows_degraded(
        self, db: sqlite3.Connection, tmp_path: Path, capsys: pytest.CaptureFixture[str],
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
        )
        result = cmd_diff(args)
        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert len(data["degraded"]) == 1
        assert data["degraded"][0]["path"] == "a.py"
        assert data["degraded"][0]["delta"] == 20.0

    def test_diff_shows_improved(
        self, db: sqlite3.Connection, tmp_path: Path, capsys: pytest.CaptureFixture[str],
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
        )
        result = cmd_diff(args)
        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert len(data["improved"]) == 1
        assert data["improved"][0]["path"] == "a.py"
        assert data["improved"][0]["delta"] == -20.0

    def test_diff_shows_new_files(
        self, db: sqlite3.Connection, tmp_path: Path, capsys: pytest.CaptureFixture[str],
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
        )
        result = cmd_diff(args)
        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert len(data["new_files"]) == 1
        assert data["new_files"][0]["path"] == "b.py"

    def test_diff_shows_removed_files(
        self, db: sqlite3.Connection, tmp_path: Path, capsys: pytest.CaptureFixture[str],
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
        )
        result = cmd_diff(args)
        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert "b.py" in data["removed_files"]

    def test_diff_quality_score_delta(
        self, db: sqlite3.Connection, tmp_path: Path, capsys: pytest.CaptureFixture[str],
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
        self, db: sqlite3.Connection, tmp_path: Path,
    ) -> None:
        """promote with empty db returns error."""
        _ = db
        args = _make_promote_args(str(tmp_path))
        result = cmd_promote(args)
        assert result == 1

    def test_no_parent_returns_error(
        self, db: sqlite3.Connection, tmp_path: Path,
    ) -> None:
        """promote without --parent returns error."""
        _ = db
        args = _make_promote_args(str(tmp_path), parent="")
        result = cmd_promote(args)
        assert result == 1

    def test_dry_run_no_wv_calls(
        self, db: sqlite3.Connection, tmp_path: Path,
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
        self, db: sqlite3.Connection, tmp_path: Path,
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
        self, db: sqlite3.Connection, tmp_path: Path,
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

        existing_node = json.dumps([{
            "id": "wv-exists",
            "text": "old finding",
            "metadata": json.dumps({"quality_finding_id": fid}),
        }])

        args = _make_promote_args(str(tmp_path), top=1, json_out=True)

        with patch("weave_quality.__main__._wv_cmd", return_value=(0, existing_node)):
            result = cmd_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert data["skipped"] == 1
        assert len(data["promoted"]) == 0

    def test_promote_json_schema(
        self, db: sqlite3.Connection, tmp_path: Path,
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
        self, tmp_path: Path, capsys: pytest.CaptureFixture[str],
    ) -> None:
        """health-info with no quality.db returns available=false."""
        args = _make_health_args(str(tmp_path / "nonexistent"))
        result = cmd_health_info(args)
        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert data["available"] is False

    def test_no_scan_returns_unavailable(
        self, db: sqlite3.Connection, tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """health-info with empty db returns available=false."""
        _ = db
        args = _make_health_args(str(tmp_path))
        result = cmd_health_info(args)
        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert data["available"] is False

    def test_with_scan_returns_score(
        self, db: sqlite3.Connection, tmp_path: Path,
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
        result = cmd_health_info(args)
        assert result == 0
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
        self, tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """context-files with no db returns empty quality list."""
        no_db_path = str(tmp_path / "nonexistent")
        args = _make_context_files_args(no_db_path)
        with patch("sys.stdin", io.StringIO("a.py\nb.py\n")):
            result = cmd_context_files(args)
        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert data["code_quality"] == []
        assert data["quality_as_of"] is None

    def test_no_scan_returns_empty(
        self, db: sqlite3.Connection, tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """context-files with empty db (no scan) returns empty."""
        _ = db
        args = _make_context_files_args(str(tmp_path))
        with patch("sys.stdin", io.StringIO("a.py\n")):
            result = cmd_context_files(args)
        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert data["code_quality"] == []
        assert data["quality_as_of"] is None

    def test_no_stdin_returns_empty(
        self, db: sqlite3.Connection, tmp_path: Path,
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
            result = cmd_context_files(args)
        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert data["code_quality"] == []

    def test_returns_quality_for_known_files(
        self, db: sqlite3.Connection, tmp_path: Path,
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
            result = cmd_context_files(args)
        assert result == 0
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
        self, db: sqlite3.Connection, tmp_path: Path,
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
            result = cmd_context_files(args)
        assert result == 0
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
        self, tmp_path: Path,
        capsys: pytest.CaptureFixture[str],  # noqa: ARG002
    ) -> None:
        """functions with no quality.db returns exit code 1."""
        args = _make_functions_args(str(tmp_path / "nonexistent"))
        result = cmd_functions(args)
        assert result == 1

    def test_no_scan_returns_error(
        self, db: sqlite3.Connection, tmp_path: Path,  # noqa: ARG002
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
        self, db: sqlite3.Connection, tmp_path: Path,
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
        self, db: sqlite3.Connection, tmp_path: Path,
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
        self, db: sqlite3.Connection, tmp_path: Path,
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
        self, db: sqlite3.Connection, tmp_path: Path,
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
        self, db: sqlite3.Connection, tmp_path: Path,
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
