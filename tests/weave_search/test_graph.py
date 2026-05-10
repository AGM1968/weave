# pylint: disable=missing-class-docstring,missing-function-docstring,redefined-outer-name
"""Tests for weave_search.graph — enrich_results, _attach_weave_nodes, _attach_quality."""

import sqlite3
from pathlib import Path

import pytest

from weave_search.__main__ import SearchResult
from weave_search.graph import FileContext, enrich_results


# ── fixtures ──────────────────────────────────────────────────────────────────

def _make_brain_db(path: str) -> None:
    conn = sqlite3.connect(path)
    conn.executescript("""
        CREATE TABLE nodes (
            id TEXT PRIMARY KEY,
            text TEXT NOT NULL,
            status TEXT NOT NULL,
            metadata TEXT DEFAULT '{}',
            alias TEXT,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        );
        CREATE TABLE node_files (
            node_id TEXT NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
            path    TEXT NOT NULL,
            PRIMARY KEY (node_id, path)
        );
        CREATE TABLE chunks (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            file       TEXT    NOT NULL,
            line_start INTEGER NOT NULL,
            line_end   INTEGER NOT NULL,
            content    TEXT    NOT NULL,
            embedding  BLOB,
            indexed_at DATETIME DEFAULT CURRENT_TIMESTAMP
        );
    """)
    conn.commit()
    conn.close()


def _make_quality_db(path: str) -> None:
    conn = sqlite3.connect(path)
    conn.executescript("""
        CREATE TABLE git_stats (
            path    TEXT PRIMARY KEY,
            churn   INTEGER,
            authors INTEGER,
            age_days INTEGER,
            hotspot REAL
        );
    """)
    conn.commit()
    conn.close()


def _fake_result(chunk_id: int, file: str) -> SearchResult:
    return SearchResult(chunk_id, file, 1, 10, "content", 0.5, "fts")


@pytest.fixture()
def brain_db(tmp_path: Path) -> str:
    p = str(tmp_path / "brain.db")
    _make_brain_db(p)
    conn = sqlite3.connect(p)
    conn.executemany(
        "INSERT INTO nodes(id, text, status) VALUES (?, ?, ?)",
        [
            ("wv-aaa111", "fix: auth bug in src/auth.py", "active"),
            ("wv-bbb222", "feat: add login page", "todo"),
            ("wv-ccc333", "chore: update deps", "done"),
        ],
    )
    conn.executemany(
        "INSERT INTO node_files(node_id, path) VALUES (?, ?)",
        [
            ("wv-aaa111", "src/auth.py"),
            ("wv-bbb222", "src/auth.py"),
            ("wv-ccc333", "src/auth.py"),  # done — should be excluded
            ("wv-aaa111", "src/utils.py"),
        ],
    )
    conn.commit()
    conn.close()
    return p


@pytest.fixture()
def quality_db(tmp_path: Path) -> str:
    p = str(tmp_path / "quality.db")
    _make_quality_db(p)
    conn = sqlite3.connect(p)
    conn.executemany(
        "INSERT INTO git_stats(path, churn, authors, age_days, hotspot) VALUES (?, ?, ?, ?, ?)",
        [
            ("src/auth.py", 42, 3, 120, 0.85),
            ("src/utils.py", 7, 1, 30, 0.12),
        ],
    )
    conn.commit()
    conn.close()
    return p


# ── enrich_results ────────────────────────────────────────────────────────────

class TestEnrichResults:
    def test_returns_context_per_file(self, brain_db: str) -> None:
        results = [_fake_result(1, "src/auth.py"), _fake_result(2, "src/utils.py")]
        ctx = enrich_results(results, brain_db)
        assert set(ctx.keys()) == {"src/auth.py", "src/utils.py"}

    def test_empty_results_returns_empty(self, brain_db: str) -> None:
        ctx = enrich_results([], brain_db)
        assert ctx == {}

    def test_missing_brain_db_returns_empty_context(self) -> None:
        results = [_fake_result(1, "src/foo.py")]
        ctx = enrich_results(results, "/nonexistent/brain.db")
        assert "src/foo.py" in ctx
        assert ctx["src/foo.py"].weave_nodes == []

    def test_attaches_active_and_todo_nodes(self, brain_db: str) -> None:
        results = [_fake_result(1, "src/auth.py")]
        ctx = enrich_results(results, brain_db)
        node_ids = {n["id"] for n in ctx["src/auth.py"].weave_nodes}
        assert "wv-aaa111" in node_ids
        assert "wv-bbb222" in node_ids

    def test_excludes_done_nodes(self, brain_db: str) -> None:
        results = [_fake_result(1, "src/auth.py")]
        ctx = enrich_results(results, brain_db)
        node_ids = {n["id"] for n in ctx["src/auth.py"].weave_nodes}
        assert "wv-ccc333" not in node_ids

    def test_node_fields_present(self, brain_db: str) -> None:
        results = [_fake_result(1, "src/auth.py")]
        ctx = enrich_results(results, brain_db)
        node = ctx["src/auth.py"].weave_nodes[0]
        assert "id" in node
        assert "text" in node
        assert "status" in node

    def test_file_with_no_nodes_has_empty_list(self, brain_db: str) -> None:
        results = [_fake_result(1, "src/no-node-file.py")]
        ctx = enrich_results(results, brain_db)
        assert not ctx["src/no-node-file.py"].weave_nodes

    def test_attaches_churn_from_quality_db(self, brain_db: str, quality_db: str) -> None:
        results = [_fake_result(1, "src/auth.py")]
        ctx = enrich_results(results, brain_db, quality_db)
        assert ctx["src/auth.py"].churn == 42
        assert ctx["src/auth.py"].hotspot == pytest.approx(0.85, abs=0.01)

    def test_missing_quality_db_leaves_none(self, brain_db: str) -> None:
        results = [_fake_result(1, "src/auth.py")]
        ctx = enrich_results(results, brain_db, "/nonexistent/quality.db")
        assert ctx["src/auth.py"].churn is None
        assert ctx["src/auth.py"].hotspot is None

    def test_file_not_in_quality_db_leaves_none(self, brain_db: str, quality_db: str) -> None:
        results = [_fake_result(1, "src/new-file.py")]
        ctx = enrich_results(results, brain_db, quality_db)
        assert ctx["src/new-file.py"].churn is None

    def test_no_quality_db_arg_still_works(self, brain_db: str) -> None:
        results = [_fake_result(1, "src/auth.py")]
        ctx = enrich_results(results, brain_db)
        assert "src/auth.py" in ctx


# ── FileContext ───────────────────────────────────────────────────────────────

class TestFileContext:
    def test_defaults(self) -> None:
        fc = FileContext()
        assert not fc.weave_nodes
        assert fc.churn is None
        assert fc.hotspot is None

    def test_weave_nodes_mutable_per_instance(self) -> None:
        fc1 = FileContext()
        fc2 = FileContext()
        fc1.weave_nodes.append({"id": "wv-x", "text": "t", "status": "active"})
        assert not fc2.weave_nodes
