# pylint: disable=missing-class-docstring,missing-function-docstring,redefined-outer-name,import-outside-toplevel
"""Tests for weave_search — fts_search, vector_search, hybrid_search."""

import builtins
import io
import json
import sqlite3
import struct
import sys
from pathlib import Path

import pytest

from weave_search.__main__ import (
    _build_fts_expr,
    fts_search,
    hybrid_search,
    main,
    vector_search,
)


# ── fixtures ──────────────────────────────────────────────────────────────────

def _make_db(path: str) -> None:
    """Create a minimal brain.db with chunks + chunks_fts for testing."""
    conn = sqlite3.connect(path)
    conn.executescript("""
        CREATE TABLE chunks (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            file       TEXT    NOT NULL,
            line_start INTEGER NOT NULL,
            line_end   INTEGER NOT NULL,
            content    TEXT    NOT NULL,
            embedding  BLOB,
            indexed_at DATETIME DEFAULT CURRENT_TIMESTAMP
        );
        CREATE INDEX IF NOT EXISTS idx_chunks_file ON chunks(file);
        CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
            content,
            file UNINDEXED,
            line_start UNINDEXED,
            line_end UNINDEXED,
            content=chunks,
            content_rowid=id
        );
        CREATE TRIGGER IF NOT EXISTS chunks_ai AFTER INSERT ON chunks BEGIN
            INSERT INTO chunks_fts(rowid, content, file, line_start, line_end)
            VALUES (new.id, new.content, new.file, new.line_start, new.line_end);
        END;
    """)
    conn.commit()
    conn.close()


def _fake_embedding(value: float, dim: int = 8) -> bytes:
    """Return a normalised float32 BLOB for testing cosine similarity."""
    vec = [value] * dim
    norm = sum(x * x for x in vec) ** 0.5
    vec = [x / norm for x in vec]
    return struct.pack(f"{dim}f", *vec)


@pytest.fixture()
def db_path(tmp_path: Path) -> str:
    p = str(tmp_path / "brain.db")
    _make_db(p)
    conn = sqlite3.connect(p)
    conn.executemany(
        "INSERT INTO chunks(file, line_start, line_end, content, embedding) VALUES (?, ?, ?, ?, ?)",
        [
            ("src/foo.py",  1, 10, "def cosine_similarity(a, b): return dot(a, b)", _fake_embedding(1.0)),
            ("src/bar.py", 11, 20, "class BM25Ranker: rank documents by term frequency", _fake_embedding(0.5)),
            ("src/baz.sh", 21, 30, "sqlite3 chunks SELECT embedding FROM chunks", _fake_embedding(0.1)),
        ],
    )
    conn.commit()
    conn.close()
    return p


# ── _build_fts_expr ───────────────────────────────────────────────────────────

class TestBuildFtsExpr:
    def test_single_word_phrase(self) -> None:
        expr = _build_fts_expr("cosine")
        assert expr == '"cosine"'

    def test_multi_word_or_tokens(self) -> None:
        expr = _build_fts_expr("cosine similarity bm25")
        assert " OR " in expr
        assert '"cosine"' in expr

    def test_strips_fts_special_chars(self) -> None:
        expr = _build_fts_expr("foo(bar):baz")
        assert "(" not in expr
        assert ")" not in expr

    def test_stopwords_removed(self) -> None:
        expr = _build_fts_expr("the and for cosine")
        assert "cosine" in expr
        assert '"the"' not in expr


# ── fts_search ────────────────────────────────────────────────────────────────

class TestFtsSearch:
    def test_returns_results(self, db_path: str) -> None:
        results = fts_search("cosine", db_path)
        assert len(results) >= 1
        assert results[0].file == "src/foo.py"

    def test_result_fields_present(self, db_path: str) -> None:
        results = fts_search("frequency", db_path)
        assert len(results) >= 1
        r = results[0]
        assert r.file
        assert r.line_start > 0
        assert r.line_end >= r.line_start
        assert r.content
        assert r.score > 0
        assert r.source == "fts"

    def test_snippet_truncates(self, db_path: str) -> None:
        results = fts_search("cosine", db_path)
        assert len(results[0].snippet) <= 200

    def test_missing_db_returns_empty(self) -> None:
        results = fts_search("query", "/nonexistent/path.db")
        assert results == []

    def test_no_match_returns_empty(self, db_path: str) -> None:
        results = fts_search("xyznotaword", db_path)
        assert results == []

    def test_limit_respected(self, db_path: str) -> None:
        results = fts_search("sqlite", db_path, limit=1)
        assert len(results) <= 1


# ── vector_search ─────────────────────────────────────────────────────────────

class TestVectorSearch:
    def test_returns_empty_without_model2vec(self, db_path: str) -> None:
        # model2vec may or may not be available; either 0 or >0 results is valid
        results = vector_search("cosine similarity", db_path, limit=5)
        assert isinstance(results, list)
        if results:
            r = results[0]
            assert r.source == "vector"
            assert -1.0 <= r.score <= 1.0

    def test_missing_db_returns_empty(self) -> None:
        results = vector_search("query", "/nonexistent/path.db")
        assert not results

    def test_skips_model_import_when_no_embeddings(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        db_path = str(tmp_path / "no-embed.db")
        _make_db(db_path)
        conn = sqlite3.connect(db_path)
        conn.execute(
            "INSERT INTO chunks(file, line_start, line_end, content, embedding) VALUES (?, ?, ?, ?, ?)",
            ("src/no_embed.py", 1, 3, "def no_embed(): pass", None),
        )
        conn.commit()
        conn.close()

        imports: list[str] = []
        real_import = builtins.__import__

        def tracking_import(name, global_ns=None, local_ns=None, fromlist=(), level=0):
            if name in {"numpy", "model2vec"}:
                imports.append(name)
            return real_import(name, global_ns, local_ns, fromlist, level)

        monkeypatch.setattr(builtins, "__import__", tracking_import)

        results = vector_search("no_embed", db_path, limit=5)

        assert not results
        assert not imports


# ── hybrid_search ─────────────────────────────────────────────────────────────

class TestHybridSearch:
    def test_returns_results(self, db_path: str) -> None:
        results = hybrid_search("cosine similarity", db_path, limit=5)
        assert isinstance(results, list)
        # Should always have FTS results even if vector not available
        assert len(results) >= 1

    def test_rrf_score_positive(self, db_path: str) -> None:
        results = hybrid_search("cosine similarity", db_path, limit=5)
        for r in results:
            assert r.score > 0

    def test_source_is_hybrid(self, db_path: str) -> None:
        results = hybrid_search("cosine", db_path, limit=5)
        for r in results:
            assert r.source == "hybrid"

    def test_result_fields(self, db_path: str) -> None:
        results = hybrid_search("bm25 rank", db_path, limit=5)
        for r in results:
            assert r.file
            assert r.line_start > 0
            assert r.snippet

    def test_limit_respected(self, db_path: str) -> None:
        results = hybrid_search("cosine", db_path, limit=1)
        assert len(results) <= 1

    def test_skips_vector_import_when_chunks_schema_invalid(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        db_path = str(tmp_path / "minimal.db")
        conn = sqlite3.connect(db_path)
        conn.execute("CREATE TABLE chunks (id INTEGER PRIMARY KEY)")
        conn.commit()
        conn.close()

        imports: list[str] = []
        real_import = builtins.__import__

        def tracking_import(name, global_ns=None, local_ns=None, fromlist=(), level=0):
            if name in {"numpy", "model2vec"}:
                imports.append(name)
            return real_import(name, global_ns, local_ns, fromlist, level)

        monkeypatch.setattr(builtins, "__import__", tracking_import)

        results = hybrid_search("query", db_path, limit=5)

        assert not results
        assert not imports


# ── main CLI ──────────────────────────────────────────────────────────────────

class TestMain:
    def test_json_output_schema(self, db_path: str) -> None:
        old = sys.stdout
        sys.stdout = io.StringIO()
        rc = main(["cosine", f"--db={db_path}", "--json"])
        output = sys.stdout.getvalue()
        sys.stdout = old
        assert rc == 0
        data = json.loads(output)
        assert isinstance(data, dict)
        assert "results" in data
        assert "readiness" in data
        assert isinstance(data["results"], list)
        if data["results"]:
            assert "file" in data["results"][0]
            assert "line_start" in data["results"][0]
            assert "line_end" in data["results"][0]
            assert "score" in data["results"][0]
            assert "snippet" in data["results"][0]
            assert "source" in data["results"][0]

    def test_missing_db_returns_error(self) -> None:
        rc = main(["query", "--db=/nonexistent/brain.db"])
        assert rc == 1

    def test_fts_mode(self, db_path: str) -> None:
        old = sys.stdout
        sys.stdout = io.StringIO()
        rc = main(["sqlite", f"--db={db_path}", "--mode=fts", "--json"])
        output = sys.stdout.getvalue()
        sys.stdout = old
        assert rc == 0
        data = json.loads(output)
        assert isinstance(data, dict)
        assert isinstance(data["results"], list)
