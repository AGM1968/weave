"""Tests for the exact definition lookup ahead of ranked code search (wv-35b5bd)."""

# pylint: disable=missing-function-docstring,redefined-outer-name

from __future__ import annotations

import json
import os
import sqlite3
import subprocess
import sys
from pathlib import Path

import pytest

from weave_indexer.__main__ import main as index_main
from weave_search import definitions

_REPO = Path(__file__).resolve().parents[2]
# Five definitions burn-down sessions searched for on 2026-11-07, each a grep
# round before this lookup; before it, none was the first --code result.
_FIVE = {
    "cmd_done": "scripts/cmd/wv-cmd-core.sh",
    "wv_checkpoint_amendable": "scripts/lib/wv-checkpoint-ci.sh",
    "gate_roles_check": "scripts/lib/wv-gate-lanes.sh",
    "_done_store_learning": "scripts/cmd/wv-cmd-core.sh",
    "install_git_hook_module_from_repo": "install.sh",
}


def _empty_db(path: Path) -> Path:
    conn = sqlite3.connect(str(path))
    conn.executescript(
        "CREATE TABLE chunks (id INTEGER PRIMARY KEY AUTOINCREMENT, file TEXT NOT NULL,"
        " line_start INTEGER NOT NULL, line_end INTEGER NOT NULL, content TEXT NOT NULL,"
        " embedding BLOB, indexed_at DATETIME DEFAULT CURRENT_TIMESTAMP);"
    )
    conn.close()
    return path


@pytest.fixture(scope="module")
def repo_db(tmp_path_factory: pytest.TempPathFactory) -> Path:
    """This repository's scripts/ and install.sh, indexed into an otherwise empty DB."""
    db = _empty_db(tmp_path_factory.mktemp("defs") / "brain.db")
    # The installer copy first: indexing a tree's root evicts everything else
    # under that root's scope (""), so scripts/ (scope "scripts") goes second.
    tree = tmp_path_factory.mktemp("installer")
    subprocess.run(["git", "init", "-q"], cwd=tree, check=True, capture_output=True)
    (tree / "install.sh").write_text((_REPO / "install.sh").read_text(encoding="utf-8"))
    assert index_main([str(tree), "--db", str(db), "--no-embed"]) == 0
    assert index_main([str(_REPO / "scripts"), "--db", str(db), "--no-embed"]) == 0
    return db


def _line_of(path: Path, name: str) -> list[int]:
    lines = path.read_text(encoding="utf-8").splitlines()
    return [i for i, line in enumerate(lines, 1) if line.startswith(f"{name}() {{")]


@pytest.mark.parametrize("name", sorted(_FIVE))
def test_each_of_the_five_resolves_to_its_defining_line(repo_db: Path, name: str) -> None:
    result = definitions.lookup(str(repo_db), name)
    assert result.status == "found"
    expected_file = _FIVE[name]
    want = _line_of(_REPO / expected_file, name)
    assert want, f"{name} no longer defined in {expected_file}"
    got = [(d.file, d.line) for d in result.definitions]
    assert [line for f, line in got if f.endswith(Path(expected_file).name)] == want


def test_a_name_defined_twice_returns_every_definition(repo_db: Path) -> None:
    result = definitions.lookup(str(repo_db), "install_git_hook_module_from_repo")
    assert len(result.definitions) == 2


def test_a_name_defined_nowhere_says_so(repo_db: Path) -> None:
    result = definitions.lookup(str(repo_db), "no_such_definition_anywhere")
    assert (result.status, result.definitions) == ("none", [])
    assert "none found" in definitions.format_text(result)[0]


def test_a_db_without_the_table_reports_unavailable_not_none(tmp_path: Path) -> None:
    result = definitions.lookup(str(_empty_db(tmp_path / "brain.db")), "cmd_done")
    assert result.status == "unavailable"
    assert "not built" in definitions.format_text(result)[0]


def test_prose_queries_skip_the_exact_pass() -> None:
    assert not definitions.is_identifier("where is the gate role contract read")
    assert definitions.format_text(definitions.lookup("/nonexistent", "two words")) == []


def test_search_cli_puts_the_definition_first_in_text_and_json(repo_db: Path) -> None:
    # The package copy this test imported, so the CLI runs the code under test.
    env = {**os.environ, "PYTHONPATH": str(Path(definitions.__file__).resolve().parents[1])}
    base = [sys.executable, "-m", "weave_search", "gate_roles_check", "--db", str(repo_db),
            "--mode=fts", "--limit=1"]
    text = subprocess.run(base, env=env, capture_output=True, text=True, check=True).stdout
    assert text.splitlines()[0] == "Definition of gate_roles_check:"
    assert "scripts/lib/wv-gate-lanes.sh:" in text.splitlines()[1]
    out = json.loads(subprocess.run(base + ["--json"], env=env, capture_output=True, text=True,
                                    check=True).stdout)
    assert out["definition"]["status"] == "found"
