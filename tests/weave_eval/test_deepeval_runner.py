"""Tests for weave_eval.deepeval_runner."""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path

import pytest

from weave_eval.deepeval_runner import run


def _mk_db(path: str) -> None:
    conn = sqlite3.connect(path)
    conn.executescript(
        """
        CREATE TABLE chunks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            file TEXT NOT NULL,
            line_start INTEGER NOT NULL,
            line_end INTEGER NOT NULL,
            content TEXT NOT NULL,
            embedding BLOB
        );
        CREATE VIRTUAL TABLE chunks_fts USING fts5(
            content,
            file UNINDEXED,
            line_start UNINDEXED,
            line_end UNINDEXED,
            content=chunks,
            content_rowid=id
        );
        CREATE TRIGGER chunks_ai AFTER INSERT ON chunks BEGIN
            INSERT INTO chunks_fts(rowid, content, file, line_start, line_end)
            VALUES (new.id, new.content, new.file, new.line_start, new.line_end);
        END;

        CREATE TABLE nodes (id TEXT PRIMARY KEY, text TEXT, status TEXT, metadata TEXT);
        CREATE TABLE edges (source TEXT NOT NULL, target TEXT NOT NULL, type TEXT NOT NULL);
        CREATE TABLE node_files (node_id TEXT NOT NULL, path TEXT NOT NULL);
        """
    )
    conn.executemany(
        "INSERT INTO chunks(file, line_start, line_end, content) VALUES (?, ?, ?, ?)",
        [
            ("src/foo.py", 1, 15, "def authenticate_user(req): return req.user"),
            ("src/bar.py", 1, 20, "class BillingService: pass"),
            ("src/baz.py", 1, 8, "def cleanup_cache(): return True"),
        ],
    )
    conn.executemany(
        "INSERT INTO nodes(id, text, status, metadata) VALUES (?, ?, ?, ?)",
        [
            ("wv-a111", "A", "todo", "{}"),
            ("wv-b222", "B", "todo", "{}"),
            ("wv-c333", "C", "todo", "{}"),
        ],
    )
    conn.executemany(
        "INSERT INTO edges(source, target, type) VALUES (?, ?, ?)",
        [("wv-a111", "wv-b222", "blocks")],
    )
    conn.executemany(
        "INSERT INTO node_files(node_id, path) VALUES (?, ?)",
        [
            ("wv-a111", "src/foo.py"),
            ("wv-b222", "src/bar.py"),
            ("wv-c333", "src/baz.py"),
        ],
    )
    conn.commit()
    conn.close()


def _write_dataset(path: Path, payload: dict) -> None:
    path.write_text(json.dumps(payload), encoding="utf-8")


class TestDeepEvalRunner:
    def test_run_returns_summary_and_cases(self, tmp_path: Path) -> None:
        db = tmp_path / "brain.db"
        ds = tmp_path / "dataset.json"
        _mk_db(str(db))
        _write_dataset(
            ds,
            {
                "cases": [
                    {
                        "id": "blocks_auth",
                        "query": "authenticate billing",
                        "mode": "fts",
                        "filter": "edge-type=blocks",
                        "k": 5,
                        "expected_files": ["src/foo.py"],
                    }
                ]
            },
        )

        payload = run(str(ds), str(db))
        assert payload["summary"]["cases"] == 1
        assert payload["summary"]["filter_leakage_rate"] == 0.0
        assert payload["cases"][0]["matched_files"] == 2
        assert payload["cases"][0]["filter_leakage_count"] == 0

    def test_empty_allowlist_rate(self, tmp_path: Path) -> None:
        db = tmp_path / "brain.db"
        ds = tmp_path / "dataset.json"
        _mk_db(str(db))

        # Remove attribution rows to force matched_files=0 for filter cases.
        conn = sqlite3.connect(str(db))
        conn.execute("DELETE FROM node_files")
        conn.commit()
        conn.close()

        _write_dataset(
            ds,
            {
                "cases": [
                    {
                        "id": "no_files",
                        "query": "authenticate",
                        "mode": "fts",
                        "filter": "edge-type=blocks",
                        "expected_files": ["src/foo.py"],
                    }
                ]
            },
        )

        payload = run(str(ds), str(db))
        assert payload["summary"]["empty_allowlist_rate"] == 1.0
        assert payload["cases"][0]["empty_allowlist"] is True

    def test_precision_recall_bounded_with_duplicate_file_results(self, tmp_path: Path) -> None:
        """fts_search returns chunk-level results; same file from multiple chunks must not push recall > 1.0."""
        db = tmp_path / "brain.db"
        ds = tmp_path / "dataset.json"
        # Insert three chunks from the same file so fts returns it at ranks 1, 2, 3
        conn = sqlite3.connect(str(db))
        conn.executescript(
            """
            CREATE TABLE chunks (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                file TEXT NOT NULL,
                line_start INTEGER NOT NULL,
                line_end INTEGER NOT NULL,
                content TEXT NOT NULL,
                embedding BLOB
            );
            CREATE VIRTUAL TABLE chunks_fts USING fts5(
                content,
                file UNINDEXED,
                line_start UNINDEXED,
                line_end UNINDEXED,
                content=chunks,
                content_rowid=id
            );
            CREATE TRIGGER chunks_ai AFTER INSERT ON chunks BEGIN
                INSERT INTO chunks_fts(rowid, content, file, line_start, line_end)
                VALUES (new.id, new.content, new.file, new.line_start, new.line_end);
            END;
            CREATE TABLE nodes (id TEXT PRIMARY KEY, text TEXT, status TEXT, metadata TEXT);
            CREATE TABLE edges (source TEXT NOT NULL, target TEXT NOT NULL, type TEXT NOT NULL);
            CREATE TABLE node_files (node_id TEXT NOT NULL, path TEXT NOT NULL);
            """
        )
        conn.executemany(
            "INSERT INTO chunks(file, line_start, line_end, content) VALUES (?, ?, ?, ?)",
            [
                ("src/auth.py", 1, 10, "def authenticate_user(req): pass"),
                ("src/auth.py", 11, 20, "def authenticate_token(tok): pass"),
                ("src/auth.py", 21, 30, "def authenticate_session(s): pass"),
            ],
        )
        conn.commit()
        conn.close()
        _write_dataset(
            ds,
            {
                "cases": [
                    {
                        "id": "multi_chunk",
                        "query": "authenticate",
                        "mode": "fts",
                        "k": 5,
                        "expected_files": ["src/auth.py"],
                    }
                ]
            },
        )

        payload = run(str(ds), str(db))
        cm = payload["cases"][0]
        assert cm["recall_at_k"] is not None
        assert cm["recall_at_k"] <= 1.0, f"recall exceeded 1.0: {cm['recall_at_k']}"
        assert cm["precision_at_k"] <= 1.0, f"precision exceeded 1.0: {cm['precision_at_k']}"
        assert cm["hits"] == 1, f"hits should be 1 unique file, got {cm['hits']}"

    def test_invalid_filter_raises(self, tmp_path: Path) -> None:
        db = tmp_path / "brain.db"
        ds = tmp_path / "dataset.json"
        _mk_db(str(db))
        _write_dataset(
            ds,
            {
                "cases": [
                    {
                        "id": "bad_filter",
                        "query": "authenticate",
                        "mode": "fts",
                        "filter": "badexpr",
                        "expected_files": [],
                    }
                ]
            },
        )

        with pytest.raises(ValueError, match="unsupported filter"):
            run(str(ds), str(db))

    def test_empty_chunks_returns_warning(self, tmp_path: Path) -> None:
        db = tmp_path / "brain.db"
        ds = tmp_path / "dataset.json"
        _mk_db(str(db))

        # Clear chunks table so index appears unpopulated
        conn = __import__("sqlite3").connect(str(db))
        conn.execute("DELETE FROM chunks")
        conn.commit()
        conn.close()

        _write_dataset(ds, {"cases": [{"id": "x", "query": "auth", "mode": "fts", "expected_files": []}]})

        payload = run(str(ds), str(db))
        assert payload["warning"] == "chunks_empty"
        assert "wv index" in payload["hint"]
        assert payload["cases"] == []
