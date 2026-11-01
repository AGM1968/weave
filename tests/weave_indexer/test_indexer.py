"""Tests for weave_indexer — chunking, storage, and CLI."""

# pylint: disable=missing-class-docstring,missing-function-docstring,redefined-outer-name,unused-argument

from __future__ import annotations

import json
import os
import sqlite3
import struct
import subprocess
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


def _git_repo(root: Path) -> Path:
    root.mkdir(parents=True)
    subprocess.run(["git", "init", "-q"], cwd=root, check=True, capture_output=True)
    (root / "a.py").write_text("a = 1\n")
    (root / "sub").mkdir()
    (root / "sub" / "b.py").write_text("b = 1\n")
    return root


def _indexed(db: Path) -> set[str]:
    conn = sqlite3.connect(str(db))
    files = {r[0] for r in conn.execute("SELECT DISTINCT file FROM chunks").fetchall()}
    conn.close()
    return files


class TestIndexScope:
    """wv-31d0d0: root selection, stored paths and eviction stay inside the walk."""

    def test_default_root_is_the_repository_not_the_hot_zone(
        self, tmp_path: Path, tmp_db: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        # wv always exports WV_HOT_ZONE, so defaulting to it indexed tmpfs.
        repo = _git_repo(tmp_path / "repo")
        (tmp_path / "hot").mkdir()
        monkeypatch.setenv("WV_DB", str(tmp_db))
        monkeypatch.setenv("WV_HOT_ZONE", str(tmp_path / "hot"))
        monkeypatch.chdir(repo / "sub")
        assert main(["--no-embed", "--ext=.py"]) == 0
        assert _indexed(tmp_db) == {"a.py", "sub/b.py"}

    def test_subdir_index_keeps_other_chunks_and_repo_relative_paths(
        self, tmp_path: Path, tmp_db: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        repo = _git_repo(tmp_path / "repo")
        monkeypatch.setenv("WV_DB", str(tmp_db))
        main(["--no-embed", "--ext=.py", str(repo)])
        main(["--no-embed", "--ext=.py", str(repo / "sub")])
        assert _indexed(tmp_db) == {"a.py", "sub/b.py"}

    def test_subdir_index_evicts_only_inside_the_subtree(
        self, tmp_path: Path, tmp_db: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        repo = _git_repo(tmp_path / "repo")
        (repo / "sub" / "c.py").write_text("c = 1\n")
        monkeypatch.setenv("WV_DB", str(tmp_db))
        main(["--no-embed", "--ext=.py", str(repo)])
        (repo / "sub" / "c.py").unlink()
        main(["--no-embed", "--ext=.py", str(repo / "sub")])
        assert _indexed(tmp_db) == {"a.py", "sub/b.py"}

    def test_empty_walk_still_evicts_its_subtree(
        self, tmp_path: Path, tmp_db: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        repo = _git_repo(tmp_path / "repo")
        monkeypatch.setenv("WV_DB", str(tmp_db))
        main(["--no-embed", "--ext=.py", str(repo)])
        (repo / "sub" / "b.py").unlink()
        assert main(["--no-embed", "--ext=.py", str(repo / "sub")]) == 0
        assert _indexed(tmp_db) == {"a.py"}

    def test_excluded_name_above_the_repo_does_not_hide_it(
        self, tmp_path: Path, tmp_db: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        # Exclusions matched absolute path parts, so a checkout under build/
        # or venv*/ indexed nothing.
        repo = _git_repo(tmp_path / "build" / "repo")
        monkeypatch.setenv("WV_DB", str(tmp_db))
        main(["--no-embed", "--ext=.py", str(repo)])
        assert _indexed(tmp_db) == {"a.py", "sub/b.py"}


class TestGitFileSet:
    """wv-cfff36: the index holds the files git counts as the project, not every file on disk."""

    def test_ignored_files_are_not_indexed(
        self, tmp_path: Path, tmp_db: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        # The live leak: a scratch copy excluded through .git/info/exclude, not .gitignore.
        repo = _git_repo(tmp_path / "repo")
        (repo / ".gitignore").write_text("ignored.py\n")
        (repo / "ignored.py").write_text("x = 1\n")
        (repo / "scratch" / "copy").mkdir(parents=True)
        (repo / "scratch" / "copy" / "a.py").write_text("a = 1\n")
        (repo / ".git" / "info" / "exclude").write_text("/scratch/\n")
        monkeypatch.setenv("WV_DB", str(tmp_db))
        main(["--no-embed", "--ext=.py", str(repo)])
        assert _indexed(tmp_db) == {"a.py", "sub/b.py"}

    def test_tracked_and_untracked_files_are_both_indexed(
        self, tmp_path: Path, tmp_db: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        # _git_repo commits nothing; add one so both halves of the listing are exercised.
        repo = _git_repo(tmp_path / "repo")
        subprocess.run(["git", "add", "a.py"], cwd=repo, check=True, capture_output=True)
        monkeypatch.setenv("WV_DB", str(tmp_db))
        main(["--no-embed", "--ext=.py", str(repo)])
        assert _indexed(tmp_db) == {"a.py", "sub/b.py"}

    def test_a_hook_environment_does_not_redirect_the_listing(
        self, tmp_path: Path, tmp_db: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        # Under another repository's GIT_DIR, git reads that repository's ignore
        # rules, so this repository's excluded scratch file would be indexed.
        repo = _git_repo(tmp_path / "repo")
        (repo / "scratch.py").write_text("s = 1\n")
        (repo / ".git" / "info" / "exclude").write_text("/scratch.py\n")
        other = _git_repo(tmp_path / "other")
        monkeypatch.setenv("GIT_DIR", str(other / ".git"))
        monkeypatch.setenv("GIT_INDEX_FILE", str(other / ".git" / "index"))
        monkeypatch.setenv("WV_DB", str(tmp_db))
        main(["--no-embed", "--ext=.py", str(repo)])
        assert _indexed(tmp_db) == {"a.py", "sub/b.py"}

    def test_extensionless_scripts_index_by_shebang(
        self, tmp_path: Path, tmp_db: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        repo = _git_repo(tmp_path / "repo")
        (repo / "tool").write_text("#!/usr/bin/env bash\necho hi\n")
        (repo / "pytool").write_text("#!/usr/bin/python3 -I\nprint(1)\n")
        (repo / "VERSION").write_text("1.0\n")
        (repo / "data").write_text("#!not a script\n")
        monkeypatch.setenv("WV_DB", str(tmp_db))
        main(["--no-embed", "--ext=.sh,.py", str(repo)])
        assert _indexed(tmp_db) == {"a.py", "sub/b.py", "tool", "pytool"}
        main(["--no-embed", "--ext=.py", str(repo)])
        assert _indexed(tmp_db) == {"a.py", "sub/b.py", "pytool"}

    def test_outside_git_every_file_is_walked(
        self, tmp_path: Path, tmp_db: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        plain = tmp_path / "plain"
        (plain / "sub").mkdir(parents=True)
        (plain / "a.py").write_text("a = 1\n")
        (plain / "sub" / "b.py").write_text("b = 1\n")
        monkeypatch.setenv("GIT_CEILING_DIRECTORIES", str(tmp_path))
        monkeypatch.setenv("WV_DB", str(tmp_db))
        main(["--no-embed", "--ext=.py", str(plain)])
        assert _indexed(tmp_db) == {"a.py", "sub/b.py"}


# wv-c6c7cf: outside git the candidate walk used rglob, which walked past a
# directory it could not list without a word, so the index was partial and
# nothing said so. One unreadable directory need not stop the index; it is named.
@pytest.mark.skipif(getattr(os, "geteuid", lambda: 1)() == 0, reason="root reads a mode-000 directory")
def test_candidates_outside_git_name_an_unlistable_directory(
    tmp_path: Path, capsys: pytest.CaptureFixture[str],
) -> None:
    from weave_indexer.__main__ import _candidates  # pylint: disable=import-outside-toplevel
    (tmp_path / "open").mkdir()
    (tmp_path / "open" / "a.py").write_text("x = 1\n")
    (tmp_path / "shut").mkdir()
    (tmp_path / "shut" / "b.py").write_text("y = 2\n")
    (tmp_path / "shut").chmod(0)
    try:
        found = {p.relative_to(tmp_path).as_posix() for p in _candidates(tmp_path)}
    finally:
        (tmp_path / "shut").chmod(0o755)
    assert "open/a.py" in found  # the readable part is still indexed
    assert "shut/b.py" not in found
    err = capsys.readouterr().err
    assert "cannot list" in err and "shut" in err
