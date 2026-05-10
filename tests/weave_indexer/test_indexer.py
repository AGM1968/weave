"""Tests for weave_indexer — chunking, storage, and CLI."""

# pylint: disable=missing-class-docstring,missing-function-docstring,redefined-outer-name,unused-argument

from __future__ import annotations

import json
import sqlite3
import struct
from pathlib import Path

import pytest

from weave_indexer.__main__ import _chunk_file, _try_encode, _upsert_chunks, main


@pytest.fixture()
def tmp_db(tmp_path: Path) -> Path:
    db = tmp_path / "brain.db"
    conn = sqlite3.connect(str(db))
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
        CREATE INDEX idx_chunks_file ON chunks(file);
        CREATE VIRTUAL TABLE chunks_fts USING fts5(
            content, file UNINDEXED, line_start UNINDEXED, line_end UNINDEXED,
            content=chunks, content_rowid=id
        );
        CREATE TRIGGER chunks_ai AFTER INSERT ON chunks BEGIN
            INSERT INTO chunks_fts(rowid, content, file, line_start, line_end)
            VALUES (NEW.id, NEW.content, NEW.file, NEW.line_start, NEW.line_end);
        END;
    """)
    conn.commit()
    conn.close()
    return db


class TestChunkFile:
    def test_single_chunk(self, tmp_path: Path) -> None:
        f = tmp_path / "a.py"
        f.write_text("\n".join(f"line{i}" for i in range(10)))
        chunks = list(_chunk_file(f, chunk_size=50, overlap=5))
        assert len(chunks) == 1
        ls, le, content = chunks[0]
        assert ls == 1
        assert le == 10
        assert "line0" in content

    def test_overlap_produces_multiple_chunks(self, tmp_path: Path) -> None:
        f = tmp_path / "a.py"
        f.write_text("\n".join(f"line{i}" for i in range(100)))
        chunks = list(_chunk_file(f, chunk_size=50, overlap=10))
        assert len(chunks) > 1
        # First chunk starts at 1
        assert chunks[0][0] == 1
        # Line numbers are 1-based
        assert chunks[0][1] == 50

    def test_empty_file(self, tmp_path: Path) -> None:
        f = tmp_path / "empty.py"
        f.write_text("")
        chunks = list(_chunk_file(f, chunk_size=50, overlap=5))
        assert not chunks

    def test_missing_file(self, tmp_path: Path) -> None:
        f = tmp_path / "missing.py"
        chunks = list(_chunk_file(f, chunk_size=50, overlap=5))
        assert not chunks


class TestTryEncode:
    def test_returns_none_list_on_failure(self) -> None:
        # model2vec not installed in test env → falls back to None list
        blobs = _try_encode(["hello world"], model_name="nonexistent/model")
        assert blobs == [None]
        assert len(blobs) == 1

    def test_length_matches_input(self) -> None:
        texts = ["a", "b", "c"]
        blobs = _try_encode(texts, model_name="nonexistent/model")
        assert len(blobs) == 3


class TestUpsertChunks:
    def test_inserts_chunks(self, tmp_db: Path) -> None:
        chunks = [("src/foo.py", 1, 10, "content here")]
        blobs: list[bytes | None] = [None]
        _upsert_chunks(str(tmp_db), chunks, blobs)
        conn = sqlite3.connect(str(tmp_db))
        rows = conn.execute("SELECT file, line_start, line_end FROM chunks").fetchall()
        conn.close()
        assert rows == [("src/foo.py", 1, 10)]

    def test_replaces_existing_chunks_for_file(self, tmp_db: Path) -> None:
        chunks1 = [("src/foo.py", 1, 10, "old content")]
        blobs: list[bytes | None] = [None]
        _upsert_chunks(str(tmp_db), chunks1, blobs)
        chunks2 = [("src/foo.py", 1, 5, "new content"), ("src/foo.py", 6, 10, "new content 2")]
        blobs2: list[bytes | None] = [None, None]
        _upsert_chunks(str(tmp_db), chunks2, blobs2)
        conn = sqlite3.connect(str(tmp_db))
        rows = conn.execute("SELECT count(*) FROM chunks WHERE file='src/foo.py'").fetchone()
        conn.close()
        assert rows[0] == 2

    def test_stores_embedding_blob(self, tmp_db: Path) -> None:
        vec = [1.0, 2.0, 3.0]
        blob = struct.pack(f"{len(vec)}f", *vec)
        chunks = [("src/foo.py", 1, 10, "content")]
        _upsert_chunks(str(tmp_db), chunks, [blob])
        conn = sqlite3.connect(str(tmp_db))
        row = conn.execute("SELECT embedding FROM chunks").fetchone()
        conn.close()
        assert row[0] == blob

    def test_fts_searchable_after_insert(self, tmp_db: Path) -> None:
        chunks = [("src/bar.py", 1, 5, "def unique_function_xyz():")]
        _upsert_chunks(str(tmp_db), chunks, [None])
        conn = sqlite3.connect(str(tmp_db))
        rows = conn.execute(
            "SELECT rowid FROM chunks_fts WHERE chunks_fts MATCH 'unique_function_xyz'"
        ).fetchall()
        conn.close()
        assert len(rows) == 1


class TestMain:
    def test_no_db_exits_nonzero(self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.delenv("WV_DB", raising=False)
        rc = main(["--no-embed", str(tmp_path)])
        assert rc == 1

    def test_missing_db_exits_nonzero(self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("WV_DB", str(tmp_path / "nonexistent.db"))
        rc = main(["--no-embed", str(tmp_path)])
        assert rc == 1

    def test_empty_dir_returns_zero(self, tmp_path: Path, tmp_db: Path, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("WV_DB", str(tmp_db))
        rc = main(["--no-embed", str(tmp_path)])
        assert rc == 0

    def test_indexes_py_file(self, tmp_path: Path, tmp_db: Path, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("WV_DB", str(tmp_db))
        (tmp_path / "sample.py").write_text("\n".join(f"x = {i}" for i in range(10)))
        rc = main(["--no-embed", "--ext=.py", str(tmp_path)])
        assert rc == 0
        conn = sqlite3.connect(str(tmp_db))
        count = conn.execute("SELECT count(*) FROM chunks").fetchone()[0]
        conn.close()
        assert count > 0

    def test_json_output(
        self, tmp_path: Path, tmp_db: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
    ) -> None:
        monkeypatch.setenv("WV_DB", str(tmp_db))
        (tmp_path / "sample.py").write_text("x = 1\n")
        rc = main(["--no-embed", "--ext=.py", "--json", str(tmp_path)])
        assert rc == 0
        out = capsys.readouterr().out
        data = json.loads(out)
        assert "files" in data
        assert "chunks" in data
        assert "embedded" in data

    def test_excludes_dot_git(self, tmp_path: Path, tmp_db: Path, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("WV_DB", str(tmp_db))
        git_dir = tmp_path / ".git"
        git_dir.mkdir()
        (git_dir / "config").write_text("x = 1\n")
        (tmp_path / "real.py").write_text("y = 2\n")
        monkeypatch.setenv("WV_DB", str(tmp_db))
        main(["--no-embed", "--ext=.py", str(tmp_path)])
        conn = sqlite3.connect(str(tmp_db))
        files = [r[0] for r in conn.execute("SELECT DISTINCT file FROM chunks").fetchall()]
        conn.close()
        assert not any(".git" in f for f in files)
        assert any("real.py" in f for f in files)
