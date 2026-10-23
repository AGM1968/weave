"""Directory listings that decide enforcement fail closed (wv-4852bd, wv-c6c7cf).

On Python 3.13 pathlib's glob reads a mode-000 directory as empty and rglob
walks past an unreadable subtree; ast-grep reports an unlistable directory on
stderr and exits 0. Every site below decided what gets enforced from such a
listing. These tests use real permissions, not a mocked PermissionError: the
earlier mocks made glob raise an exception it never raises, so they passed
against the fail-open code. Each failure case has a healthy control beside it.
Skipped as root, which reads a mode-000 directory anyway.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import sys
from collections.abc import Iterator
from pathlib import Path
from types import ModuleType
from unittest.mock import patch

import pytest

from weave_quality.__main__ import (
    _candidate_pattern_files,
    _run_pattern_rule,
    cmd_patterns_scan,
    cmd_prose_shape,
)
from weave_quality.db import init_db
from weave_quality.external_tools import ast_grep_bin
from weave_quality.listing import directory_entries, iter_tree
from weave_quality.pattern_loader import _load_pattern_rules
from weave_quality.prose_rules import (
    PatternRuleExecutionError,
    PatternRuleValidationError,
    code_rule_out_of_scope,
    prose_rule_out_of_scope,
    run_prose_rule,
)
from weave_quality.prose_shape import markdown_files

pytestmark = pytest.mark.skipif(
    hasattr(os, "geteuid") and os.geteuid() == 0, reason="root reads a mode-000 directory"
)

REPO_ROOT = Path(__file__).resolve().parents[2]

PROSE_RULE = """\
id: emphasis
language: prose
kind: lexicon
severity: info
terms:
  - genuine
"""

CODE_RULE = """\
id: bare-call
language: python
rule:
  pattern: x()
message: a bare call
severity: info
"""


@pytest.fixture
def locked() -> Iterator[list[Path]]:
    """Directories to make mode 000 for one test, restored afterwards."""
    dirs: list[Path] = []
    yield dirs
    for d in dirs:
        d.chmod(0o755)


def lock(locked: list[Path], directory: Path) -> None:
    directory.chmod(0)
    locked.append(directory)


def _module(name: str, path: Path) -> ModuleType:
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


# ── the helpers ─────────────────────────────────────────────────────────────


def test_directory_entries_absent_is_empty_unlistable_raises(tmp_path: Path, locked: list[Path]) -> None:
    assert directory_entries(tmp_path / "absent", "*.yaml") == []
    (tmp_path / "file").write_text("x")
    assert directory_entries(tmp_path / "file", "*.yaml") == []
    d = tmp_path / "rules"
    d.mkdir()
    (d / "a.yaml").write_text("x")
    (d / "b.yml").write_text("x")
    assert directory_entries(d, "*.yaml") == [d / "a.yaml"]
    lock(locked, d)
    assert list(d.glob("*.yaml")) == []  # the defect this module exists for
    with pytest.raises(PermissionError):
        directory_entries(d, "*.yaml")


def test_iter_tree_raises_on_an_unreadable_subtree(tmp_path: Path, locked: list[Path]) -> None:
    (tmp_path / "ok").mkdir()
    (tmp_path / "ok" / "a.md").write_text("x")
    (tmp_path / "deep").mkdir()
    (tmp_path / "deep" / "b.md").write_text("x")
    assert sorted(p.name for p in iter_tree(tmp_path)) == ["a.md", "b.md", "deep", "ok"]
    lock(locked, tmp_path / "deep")
    assert "b.md" not in {p.name for p in tmp_path.rglob("*")}  # rglob walks past it
    with pytest.raises(PermissionError):
        list(iter_tree(tmp_path))


# ── rule tiers ──────────────────────────────────────────────────────────────


def _repo_with_rule(tmp_path: Path, tier: str) -> Path:
    repo = tmp_path / "repo"
    rule_dir = repo / ".weave" / "patterns" / tier if tier else repo / ".weave" / "patterns"
    rule_dir.mkdir(parents=True)
    (rule_dir / "local-emphasis.yaml").write_text(PROSE_RULE.replace("id: emphasis", "id: local-emphasis"))
    return repo


@pytest.mark.parametrize("tier", ["", "managed"])
def test_rule_loader_refuses_an_unlistable_tier(tmp_path: Path, locked: list[Path], tier: str) -> None:
    repo = _repo_with_rule(tmp_path, tier)
    ids = {rule_id for rule_id, _, _ in _load_pattern_rules(repo, set())}
    assert "local-emphasis" in ids  # control
    lock(locked, repo / ".weave" / "patterns" / tier if tier else repo / ".weave" / "patterns")
    with pytest.raises(PatternRuleValidationError, match="cannot be listed"):
        _load_pattern_rules(repo, set())


def test_patterns_scan_refuses_an_unlistable_tier(
    tmp_path: Path, locked: list[Path], capsys: pytest.CaptureFixture[str]
) -> None:
    repo = _repo_with_rule(tmp_path, "")
    (repo / "doc.md").write_text("clean prose\n")
    hotzone = tmp_path / "hz"
    init_db(hot_zone=str(hotzone)).close()
    args = argparse.Namespace(hot_zone=str(hotzone), path=str(repo), json=True)
    lock(locked, repo / ".weave" / "patterns")
    with patch("weave_quality.__main__._resolve_repo", return_value=str(repo)):
        assert cmd_patterns_scan(args) == 1
    payload = json.loads(capsys.readouterr().out)
    assert payload["error"] == "invalid_pattern_rule"
    assert "cannot be listed" in payload["detail"]


def test_patterns_validate_tier_listing_raises(tmp_path: Path, locked: list[Path]) -> None:
    # The leaf tier: locking its parent made the old is_dir() raise for the
    # tier under it by accident, which hid that glob never did.
    repo = _repo_with_rule(tmp_path, "managed")
    assert any(p.name == "local-emphasis.yaml" for p in _candidate_pattern_files(repo))
    lock(locked, repo / ".weave" / "patterns" / "managed")
    with pytest.raises(PermissionError):
        _candidate_pattern_files(repo)


# ── prose scans and out-of-scope claims ─────────────────────────────────────


def _docs(tmp_path: Path) -> tuple[Path, Path]:
    target = tmp_path / "docs"
    (target / "open").mkdir(parents=True)
    (target / "open" / "a.md").write_text("plain words\n")
    (target / "shut").mkdir()
    (target / "shut" / "b.md").write_text("a genuine claim\n")
    rule = tmp_path / "emphasis.yaml"
    rule.write_text(PROSE_RULE)
    return target, rule


def test_prose_rule_scan_refuses_an_unlistable_directory(tmp_path: Path, locked: list[Path]) -> None:
    target, rule = _docs(tmp_path)
    found = run_prose_rule("emphasis", rule, target, 1, target)
    assert [f.path for f in found] == ["shut/b.md"]  # control
    lock(locked, target / "shut")
    with pytest.raises(PatternRuleExecutionError, match="cannot list target"):
        run_prose_rule("emphasis", rule, target, 1, target)


def test_prose_out_of_scope_is_not_claimed_over_an_unlistable_directory(
    tmp_path: Path, locked: list[Path]
) -> None:
    target, rule = _docs(tmp_path)
    (target / "open" / "a.md").unlink()
    (target / "open" / "a.py").write_text("x = 1\n")
    (target / "shut" / "b.md").unlink()
    assert prose_rule_out_of_scope(rule, target, target) is True  # control: no .md at all
    (target / "shut" / "b.md").write_text("a genuine claim\n")
    lock(locked, target / "shut")
    assert prose_rule_out_of_scope(rule, target, target) is False


def test_code_out_of_scope_is_not_claimed_over_an_unlistable_directory(
    tmp_path: Path, locked: list[Path]
) -> None:
    (tmp_path / "open").mkdir()
    (tmp_path / "open" / "notes.md").write_text("x\n")
    (tmp_path / "shut").mkdir()
    assert code_rule_out_of_scope("python", tmp_path) is True  # control: no .py
    (tmp_path / "shut" / "m.py").write_text("x()\n")
    lock(locked, tmp_path / "shut")
    assert code_rule_out_of_scope("python", tmp_path) is False


@pytest.mark.skipif(not ast_grep_bin(), reason="ast-grep not installed")
def test_code_rule_scan_refuses_an_unlistable_directory(tmp_path: Path, locked: list[Path]) -> None:
    target = tmp_path / "src"
    (target / "open").mkdir(parents=True)
    (target / "open" / "a.py").write_text("x()\n")
    (target / "shut").mkdir()
    (target / "shut" / "b.py").write_text("x()\n")
    rule = tmp_path / "bare-call.yaml"
    rule.write_text(CODE_RULE)
    found = _run_pattern_rule("bare-call", rule, target, 1, target, "python")
    assert sorted(f.path for f in found) == ["open/a.py", "shut/b.py"]  # control
    lock(locked, target / "shut")
    with pytest.raises(PatternRuleExecutionError, match="could not read all of"):
        _run_pattern_rule("bare-call", rule, target, 1, target, "python")


# ── prose shape ─────────────────────────────────────────────────────────────


def test_prose_shape_reports_an_unlistable_directory(
    tmp_path: Path, locked: list[Path], capsys: pytest.CaptureFixture[str]
) -> None:
    target, _ = _docs(tmp_path)
    assert [p.name for p in markdown_files(target)] == ["a.md", "b.md"]  # control
    lock(locked, target / "shut")
    with pytest.raises(PermissionError):
        markdown_files(target)
    args = argparse.Namespace(path=str(target), json=True, baseline=None)
    with patch("weave_quality.__main__._resolve_repo", return_value=str(tmp_path)):
        assert cmd_prose_shape(args) != 0
    assert json.loads(capsys.readouterr().out)["error"] == "target_unreadable"


# ── the policy contract's source scan ───────────────────────────────────────


def test_policy_scan_reports_an_unlistable_directory(tmp_path: Path, locked: list[Path]) -> None:
    policy = _module("weave_policy_under_test", REPO_ROOT / "scripts" / "weave_policy.py")
    (tmp_path / "scripts" / "lib").mkdir(parents=True)
    (tmp_path / "scripts" / "lib" / "a.sh").write_text("echo a\n")
    checker = policy.Checker.__new__(policy.Checker)
    errors: list[str] = []
    sources: dict[str, object] = {}
    checker.root, checker.errors, checker.sources = tmp_path, errors, sources
    assert [rel for rel, _ in checker.files(("scripts/lib/*.sh",))] == ["scripts/lib/a.sh"]  # control
    assert checker.errors == []
    lock(locked, tmp_path / "scripts" / "lib")
    assert list(checker.files(("scripts/lib/*.sh",))) == []
    assert any("cannot be listed" in e for e in checker.errors)


# ── the E6 implementation closure and graph snapshot ────────────────────────


def test_e6_closure_and_snapshot_refuse_an_unlistable_directory(tmp_path: Path, locked: list[Path]) -> None:
    e6 = _module("e6_durability_under_test", REPO_ROOT / "scripts" / "weave_evidence" / "e6_durability.py")
    for rel in e6.EXPLICIT_IMPLEMENTATION_SOURCES:
        (tmp_path / rel).parent.mkdir(parents=True, exist_ok=True)
        (tmp_path / rel).write_text("x\n")
    for sub in ("scripts/lib", "scripts/cmd"):
        (tmp_path / sub).mkdir(parents=True, exist_ok=True)
        (tmp_path / sub / "m.sh").write_text("echo\n")
    (tmp_path / ".weave" / "deep").mkdir(parents=True)
    (tmp_path / ".weave" / "deep" / "state.sql").write_text("x\n")
    paths = {row["path"] for row in e6.implementation_sources(tmp_path)}
    assert {"scripts/lib/m.sh", "scripts/cmd/m.sh"} <= paths  # control
    assert [f["path"] for f in e6.graph_snapshot(tmp_path)["files"]] == [".weave/deep/state.sql"]
    lock(locked, tmp_path / "scripts" / "cmd")
    with pytest.raises(e6.BatteryError, match="cannot list"):
        e6.implementation_sources(tmp_path)
    lock(locked, tmp_path / ".weave" / "deep")
    with pytest.raises(e6.BatteryError, match="cannot list"):
        e6.graph_snapshot(tmp_path)
