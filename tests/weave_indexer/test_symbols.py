"""Tests for the definition table wv index builds (wv-35b5bd)."""

# pylint: disable=missing-function-docstring,redefined-outer-name

from __future__ import annotations

import sqlite3
import subprocess
from pathlib import Path

import pytest

from weave_indexer import symbols
from weave_indexer.__main__ import main

_CHUNKS = """
CREATE TABLE chunks (
    id INTEGER PRIMARY KEY AUTOINCREMENT, file TEXT NOT NULL, line_start INTEGER NOT NULL,
    line_end INTEGER NOT NULL, content TEXT NOT NULL, embedding BLOB,
    indexed_at DATETIME DEFAULT CURRENT_TIMESTAMP);
"""


@pytest.fixture()
def repo(tmp_path: Path) -> Path:
    root = tmp_path / "repo"
    root.mkdir()
    subprocess.run(["git", "init", "-q"], cwd=root, check=True, capture_output=True)
    return root


@pytest.fixture()
def db(tmp_path: Path) -> Path:
    path = tmp_path / "brain.db"
    conn = sqlite3.connect(str(path))
    conn.executescript(_CHUNKS)
    conn.close()
    return path


def _rows(db: Path) -> set[tuple[str, str, int, str]]:
    conn = sqlite3.connect(str(db))
    rows = set(conn.execute("SELECT name, file, line, kind FROM code_symbols").fetchall())
    conn.close()
    return rows


def test_shell_definitions_with_and_without_the_function_keyword() -> None:
    text = "#!/bin/bash\nalpha() {\n  :\n}\nfunction beta {\n}\nfunction gamma() (\n)\n"
    assert symbols.extract(".sh", text) == [
        ("alpha", 2, "function"), ("beta", 5, "function"), ("gamma", 7, "function")]


def test_a_dotted_bash_function_name_is_kept() -> None:
    assert symbols.extract(".sh", "wv.helper() {\n}\n") == [("wv.helper", 1, "function")]


def test_a_call_is_not_a_shell_definition() -> None:
    # Python inside a heredoc: the only bare "name()" lines the repository had.
    text = "python3 - <<'PY'\nmain()\nconn.close()\nPY\nx=$(foo)\n"
    assert not symbols.extract(".sh", text)


def test_python_functions_and_classes() -> None:
    text = "class Foo(Base):\n    async def bar(self):\n        pass\ndef baz():\n    pass\n"
    assert symbols.extract(".py", text) == [
        ("Foo", 1, "class"), ("bar", 2, "function"), ("baz", 4, "function")]


def test_typescript_functions_classes_and_arrow_consts() -> None:
    text = ("export async function one(a: number): Promise<void> {}\n"
            "export class Two {}\n"
            "const three = async (x: string) => x;\n"
            "const notAFunction = 4;\n")
    assert symbols.extract(".ts", text) == [
        ("one", 1, "function"), ("Two", 2, "class"), ("three", 3, "function")]


def test_an_unknown_language_contributes_nothing() -> None:
    assert not symbols.extract(".md", "alpha() {\n")


def test_wv_index_builds_the_table_and_keeps_both_definitions_of_a_name(
    repo: Path, db: Path
) -> None:
    (repo / "a.sh").write_text("#!/bin/bash\ndup() {\n  :\n}\n")
    (repo / "b.sh").write_text("#!/bin/bash\n\ndup() {\n  :\n}\n")
    (repo / "tool").write_text("#!/usr/bin/env bash\nonly_here() {\n  :\n}\n")
    assert main([str(repo), "--db", str(db), "--no-embed"]) == 0
    assert _rows(db) == {
        ("dup", "a.sh", 2, "function"), ("dup", "b.sh", 3, "function"),
        ("only_here", "tool", 2, "function")}


def test_reindexing_follows_edits_and_deletions_inside_the_walk_only(
    repo: Path, db: Path
) -> None:
    (repo / "sub").mkdir()
    (repo / "keep.sh").write_text("kept() {\n}\n")
    (repo / "sub" / "x.sh").write_text("old_name() {\n}\n")
    (repo / "sub" / "gone.sh").write_text("gone() {\n}\n")
    assert main([str(repo), "--db", str(db), "--no-embed"]) == 0
    (repo / "sub" / "x.sh").write_text("\nnew_name() {\n}\n")
    (repo / "sub" / "gone.sh").unlink()
    assert main([str(repo / "sub"), "--db", str(db), "--no-embed"]) == 0
    assert _rows(db) == {("kept", "keep.sh", 1, "function"), ("new_name", "sub/x.sh", 2, "function")}
