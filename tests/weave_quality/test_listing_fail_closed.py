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
import subprocess
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
from weave_quality.listing import directory_entries, iter_tree, repo_files
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


@pytest.mark.skipif(not ast_grep_bin(), reason="ast-grep not installed")
def test_code_rule_scan_refuses_an_unreadable_file_of_its_language(tmp_path: Path) -> None:
    """wv-0da129: ast-grep skips an unreadable file with no message and exit 0.

    Its skippedFileCount also counts empty and binary files, which are
    readable and must not refuse the scan; the control holds both.
    """
    target = tmp_path / "src"
    target.mkdir()
    (target / "a.py").write_text("x()\n")
    (target / "empty.py").write_text("")
    (target / "blob.py").write_bytes(bytes(range(256)) * 16)
    rule = tmp_path / "bare-call.yaml"
    rule.write_text(CODE_RULE)
    found = _run_pattern_rule("bare-call", rule, target, 1, target, "python")
    assert [f.path for f in found] == ["a.py"]  # control: empty and binary skips are not refused
    shut = target / "shut.py"
    shut.write_text("x()\n")
    shut.chmod(0)
    try:
        with pytest.raises(PatternRuleExecutionError, match="could not read, so the scan is incomplete"):
            _run_pattern_rule("bare-call", rule, target, 1, target, "python")
        # A file of another language is not the rule's concern.
        shut.chmod(0o644)
        (target / "notes.sh").write_text("echo\n")
        (target / "notes.sh").chmod(0)
        assert [f.path for f in _run_pattern_rule("bare-call", rule, target, 1, target, "python")] \
            == ["a.py", "shut.py"]
    finally:
        shut.chmod(0o644)
        if (target / "notes.sh").exists():
            (target / "notes.sh").chmod(0o644)


@pytest.mark.skipif(not ast_grep_bin(), reason="ast-grep not installed")
def test_code_rule_findings_do_not_follow_ast_grep_completion_order(tmp_path: Path) -> None:
    """ast-grep reports files in the order its parallel workers finish, which
    varied run to run, so the assertion above flaked under a loaded gate
    (wv-d94b8a). Fed ast-grep's own output in reverse, the result is the same."""
    target = tmp_path / "src"
    target.mkdir()
    for name in ("a.py", "b.py"):
        (target / name).write_text("x()\nx()\n")
    rule = tmp_path / "bare-call.yaml"
    rule.write_text(CODE_RULE)
    real_run = subprocess.run
    captured: list[subprocess.CompletedProcess[str]] = []

    # Both wrappers stand in for the scanner's own subprocess.run call and
    # forward its keyword arguments, check= among them, unchanged.
    def capture(*args: object, **kwargs: object) -> subprocess.CompletedProcess[str]:
        proc = real_run(*args, **kwargs)  # type: ignore[call-overload]  # pylint: disable=subprocess-run-check
        if "scan" in list(args[0]):  # type: ignore[call-overload]
            captured.append(proc)
        return proc

    with patch("weave_quality.__main__.subprocess.run", side_effect=capture):
        forward = _run_pattern_rule("bare-call", rule, target, 1, target, "python")
    assert [(f.path, f.line) for f in forward] == [("a.py", 1), ("a.py", 2), ("b.py", 1), ("b.py", 2)]
    scan = captured[-1]
    reversed_out = json.dumps(list(reversed(json.loads(scan.stdout))))

    def replay(*args: object, **kwargs: object) -> subprocess.CompletedProcess[str]:
        if "scan" in list(args[0]):  # type: ignore[call-overload]
            return subprocess.CompletedProcess(scan.args, scan.returncode, reversed_out, scan.stderr)
        return real_run(*args, **kwargs)  # type: ignore[call-overload]  # pylint: disable=subprocess-run-check

    with patch("weave_quality.__main__.subprocess.run", side_effect=replay):
        backward = _run_pattern_rule("bare-call", rule, target, 1, target, "python")
    assert [(f.path, f.line) for f in backward] == [(f.path, f.line) for f in forward]


@pytest.mark.skipif(not ast_grep_bin(), reason="ast-grep not installed")
def test_code_rule_scan_in_a_repository_follows_what_ast_grep_walks(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Inside a repository ast-grep honours .gitignore and skips hidden
    directories, so an unreadable file there is not refused; one it walks is.
    A hook's GIT_DIR must not point the listing at another repository."""
    for key in list(os.environ):
        if key.startswith("GIT_"):
            monkeypatch.delenv(key)
    target = tmp_path / "repo"
    (target / ".hidden").mkdir(parents=True)
    subprocess.run(["git", "init", "-q", str(target)], check=True)
    (target / ".gitignore").write_text("ignored.py\n")
    (target / "a.py").write_text("x()\n")
    (target / "empty.py").write_text("")  # a skip ast-grep counts, so the check runs
    locked = [target / "ignored.py", target / ".hidden" / "h.py"]
    for path in locked:
        path.write_text("x()\n")
        path.chmod(0)
    rule = tmp_path / "bare-call.yaml"
    rule.write_text(CODE_RULE)
    monkeypatch.setenv("GIT_DIR", str(tmp_path / "elsewhere"))
    try:
        found = _run_pattern_rule("bare-call", rule, target, 1, target, "python")
        assert [f.path for f in found] == ["a.py"]  # control
        shut = target / "shut.py"
        shut.write_text("x()\n")
        shut.chmod(0)
        locked.append(shut)
        with pytest.raises(PatternRuleExecutionError, match="1 file"):
            _run_pattern_rule("bare-call", rule, target, 1, target, "python")
    finally:
        for path in locked:
            path.chmod(0o644)


def _prose_repo(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> tuple[Path, Path]:
    """A repository with a tracked, an untracked and an ignored finding."""
    for key in list(os.environ):
        if key.startswith("GIT_"):
            monkeypatch.delenv(key)
    target = tmp_path / "repo"
    (target / "build").mkdir(parents=True)
    subprocess.run(["git", "init", "-q", str(target)], check=True)
    (target / ".gitignore").write_text("build/\n")
    (target / "tracked.md").write_text("a genuine claim\n")
    subprocess.run(["git", "-C", str(target), "add", "tracked.md", ".gitignore"], check=True)
    (target / "untracked.md").write_text("another genuine claim\n")
    (target / "build" / "out.md").write_text("a genuine build artefact\n")
    rule = tmp_path / "emphasis.yaml"
    rule.write_text(PROSE_RULE)
    # A hook's GIT_DIR must not point the listing at another repository.
    monkeypatch.setenv("GIT_DIR", str(tmp_path / "elsewhere"))
    return target, rule


def test_prose_scan_in_a_repository_reads_gits_set_not_ignored_trees(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A root prose scan walked every ignored tree once per rule: 1,965 files
    read to scan 247 here, over 11 minutes, with the ignored trees' findings
    reported (wv-c309a8). Inside a repository the set is git's: tracked plus
    untracked, not ignored. Scope claims and prose shape read the same set."""
    target, rule = _prose_repo(tmp_path, monkeypatch)
    found = sorted(f.path for f in run_prose_rule("emphasis", rule, target, 1, target))
    assert found == ["tracked.md", "untracked.md"]
    assert [p.name for p in markdown_files(target)] == ["tracked.md", "untracked.md"]
    for name in ("tracked.md", "untracked.md"):
        (target / name).unlink()
    # Only the ignored tree holds markdown now: nothing in scope, nothing read.
    assert prose_rule_out_of_scope(rule, target, target) is True
    assert run_prose_rule("emphasis", rule, target, 1, target) == []


def test_repository_listing_refuses_an_unreadable_untracked_directory(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, locked: list[Path],
) -> None:
    """git lists past an untracked directory it cannot open with a warning and
    exit 0; the listing must refuse, not report clean (wv-4852bd)."""
    target, rule = _prose_repo(tmp_path, monkeypatch)
    (target / "shut").mkdir()
    (target / "shut" / "b.md").write_text("a genuine claim\n")
    assert "shut/b.md" in {f.path for f in run_prose_rule("emphasis", rule, target, 1, target)}
    lock(locked, target / "shut")
    with pytest.raises(OSError, match="could not open directory"):
        repo_files(target)
    with pytest.raises(PatternRuleExecutionError, match="cannot list target"):
        run_prose_rule("emphasis", rule, target, 1, target)
    assert prose_rule_out_of_scope(rule, target, target) is False


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


# ── coaching evidence: the default-rule inventory ───────────────────────────


def test_coaching_manifest_refuses_an_unlistable_rule_directory(tmp_path: Path, locked: list[Path]) -> None:
    from weave_quality.coaching_evidence import _package_rule_manifest  # pylint: disable=import-outside-toplevel  # noqa: PLC0415
    copied = tmp_path / "default_patterns"
    copied.mkdir()
    for path in directory_entries(REPO_ROOT / "scripts" / "weave_quality" / "default_patterns"):
        (copied / path.name).write_bytes(path.read_bytes())
    _package_rule_manifest(copied)  # control
    # Searchable but not listable: the manifest still reads by name, so only
    # the listing can fail. glob read it as empty and blamed the manifest.
    copied.chmod(0o311)
    locked.append(copied)
    with pytest.raises(PermissionError):
        _package_rule_manifest(copied)


# ── the E6 implementation closure and graph snapshot ────────────────────────

# The evidence runners and the release aggregate do not ship, so neither do
# these tests (wv-43d08d).
