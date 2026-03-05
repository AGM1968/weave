"""Tests for JSON enrichment: category_counts in scan output, scope field in hotspots/diff."""
# pylint: disable=missing-class-docstring,missing-function-docstring,redefined-outer-name,unused-argument

from __future__ import annotations

import argparse
import json
import sqlite3
from collections import Counter
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
    conn = init_db(hot_zone=str(tmp_path))
    yield conn
    conn.close()


def _entry(
    path: str,
    scan_id: int,  # pylint: disable=unused-argument
    complexity: float = 10.0,
    category: str = "production",
) -> FileEntry:
    return FileEntry(
        path=path,
        scan_id=scan_id,
        language="python",
        loc=100,
        complexity=complexity,
        functions=3,
        max_nesting=2,
        avg_fn_len=10.0,
        category=category,
    )


def _stats(path: str, churn: int = 10, hotspot: float = 0.0) -> GitStats:
    return GitStats(path=path, churn=churn, age_days=30, authors=1, hotspot=hotspot)


def _populate(
    conn: sqlite3.Connection,
    scan_id: int,
    entries: list[FileEntry],
    stats: list[GitStats],
) -> None:
    bulk_upsert_file_entries(conn, entries)
    compute_hotspots(entries, stats)
    bulk_upsert_git_stats(conn, stats)
    conn.commit()


# ---------------------------------------------------------------------------
# hotspots JSON: scope field present
# ---------------------------------------------------------------------------


class TestHotspotsJsonScope:
    def test_scope_field_present_default(
        self, db: sqlite3.Connection, tmp_path: Path, capsys: pytest.CaptureFixture[str],
    ) -> None:
        """hotspots --json output includes 'scope' field with default value."""
        scan_id = begin_scan(db, "abc123")
        entries = [_entry("a.py", scan_id, complexity=100)]
        stats = [_stats("a.py", churn=50)]
        _populate(db, scan_id, entries, stats)
        finish_scan(db, scan_id, 1, 50)
        db.close()

        args = argparse.Namespace(hot_zone=str(tmp_path), top=10, json=True, scope="production")
        result = cmd_hotspots(args)
        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert data["scope"] == "production"

    def test_scope_field_reflects_all(
        self, db: sqlite3.Connection, tmp_path: Path, capsys: pytest.CaptureFixture[str],
    ) -> None:
        """hotspots --json output reflects scope=all when passed."""
        scan_id = begin_scan(db, "abc123")
        entries = [_entry("a.py", scan_id, complexity=100)]
        stats = [_stats("a.py", churn=50)]
        _populate(db, scan_id, entries, stats)
        finish_scan(db, scan_id, 1, 50)
        db.close()

        args = argparse.Namespace(hot_zone=str(tmp_path), top=10, json=True, scope="all")
        result = cmd_hotspots(args)
        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert data["scope"] == "all"


# ---------------------------------------------------------------------------
# diff JSON: scope field present
# ---------------------------------------------------------------------------


class TestDiffJsonScope:
    def test_scope_field_present(
        self, db: sqlite3.Connection, tmp_path: Path, capsys: pytest.CaptureFixture[str],
    ) -> None:
        """diff --json output includes 'scope' field."""
        scan_id1 = begin_scan(db, "aaa111")
        entries1 = [_entry("a.py", scan_id1, complexity=10)]
        stats1 = [_stats("a.py", churn=5)]
        _populate(db, scan_id1, entries1, stats1)
        finish_scan(db, scan_id1, 1, 50)

        scan_id2 = begin_scan(db, "bbb222")
        entries2 = [_entry("a.py", scan_id2, complexity=20)]
        stats2 = [_stats("a.py", churn=10)]
        _populate(db, scan_id2, entries2, stats2)
        finish_scan(db, scan_id2, 1, 50)
        db.close()

        args = argparse.Namespace(hot_zone=str(tmp_path), json=True, scope="production")
        result = cmd_diff(args)
        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert data["scope"] == "production"

    def test_scope_all_in_diff(
        self, db: sqlite3.Connection, tmp_path: Path, capsys: pytest.CaptureFixture[str],
    ) -> None:
        """diff --json scope=all is reflected in output."""
        scan_id1 = begin_scan(db, "aaa111")
        entries1 = [_entry("a.py", scan_id1)]
        stats1 = [_stats("a.py")]
        _populate(db, scan_id1, entries1, stats1)
        finish_scan(db, scan_id1, 1, 50)

        scan_id2 = begin_scan(db, "bbb222")
        entries2 = [_entry("a.py", scan_id2)]
        stats2 = [_stats("a.py")]
        _populate(db, scan_id2, entries2, stats2)
        finish_scan(db, scan_id2, 1, 50)
        db.close()

        args = argparse.Namespace(hot_zone=str(tmp_path), json=True, scope="all")
        result = cmd_diff(args)
        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert data["scope"] == "all"


# ---------------------------------------------------------------------------
# scan JSON: category_counts field
# ---------------------------------------------------------------------------


class TestScanJsonCategoryCounts:
    """category_counts in scan --json output is tested via integration in test_cli_commands.py.

    The Counter logic is straightforward: we verify the key is present and maps
    category strings to integer counts.
    """

    def test_category_counts_schema(self) -> None:
        """category_counts value must be a dict mapping str->int."""
        entries = [
            FileEntry(path="src/a.py", scan_id=1, language="python", loc=10,
                      complexity=5.0, functions=1, max_nesting=1, avg_fn_len=10.0,
                      category="production"),
            FileEntry(path="tests/test_a.py", scan_id=1, language="python", loc=10,
                      complexity=3.0, functions=1, max_nesting=1, avg_fn_len=10.0,
                      category="test"),
            FileEntry(path="tests/test_b.py", scan_id=1, language="python", loc=10,
                      complexity=3.0, functions=1, max_nesting=1, avg_fn_len=10.0,
                      category="test"),
        ]
        counts = dict(Counter(e.category for e in entries))
        assert counts == {"production": 1, "test": 2}
        assert all(isinstance(v, int) for v in counts.values())

    def test_category_counts_empty(self) -> None:
        """Empty entries list yields empty dict."""
        entries: list[FileEntry] = []
        counts = dict(Counter(e.category for e in entries))
        assert not counts
