"""Prose-rule backend invariants."""

# pylint: disable=missing-function-docstring

from __future__ import annotations

from pathlib import Path

import pytest

from weave_quality.prose_rules import parse_flat_rule, rule_language, run_prose_rule

DEFAULT_PATTERNS = Path(__file__).parents[2] / "scripts" / "weave_quality" / "default_patterns"


def _write(path: Path, text: str) -> Path:
    path.write_text(text, encoding="utf-8")
    return path


def _rule(tmp_path: Path, body: str) -> Path:
    return _write(tmp_path / "rule.yaml", body)


LEXICON_RULE = """\
id: emphasis
language: prose
kind: lexicon
severity: info
terms:
  - genuine
  - actually
exempt:
  - real-time
"""


def test_rule_language_reads_field(tmp_path: Path) -> None:
    assert rule_language(_rule(tmp_path, LEXICON_RULE)) == "prose"
    assert rule_language(_write(tmp_path / "c.yaml", "id: x\nlanguage: python\n")) == "python"


def test_parse_flat_rule_rejects_nesting(tmp_path: Path) -> None:
    bad = _write(tmp_path / "n.yaml", "rule:\n  any:\n    - pattern: x\n")
    with pytest.raises(ValueError, match="nested"):
        parse_flat_rule(bad)


def test_parse_flat_rule_accepts_block_scalar(tmp_path: Path) -> None:
    parsed = parse_flat_rule(
        _write(tmp_path / "m.yaml", "id: x\nmessage: >-\n  folded\n  text\nkind: regex\n")
    )
    assert parsed["message"] == "folded text"
    assert parsed["kind"] == "regex"


def test_default_prose_rules_parse_and_execute(tmp_path: Path) -> None:
    doc = _write(
        tmp_path / "doc.md",
        "A genuine claim, so the reader waits.\n"
        "The metric was measured at 5/min.\n"
        "A measured response.\n"
        "Another measured response.\n",
    )
    rule_paths = sorted(DEFAULT_PATTERNS.glob("prose-*.yaml"))

    assert [path.stem for path in rule_paths] == [
        "prose-casual-register",
        "prose-emphasis-hedge",
        "prose-number-free-verification",
    ]
    for rule_path in rule_paths:
        assert parse_flat_rule(rule_path)["language"] == "prose"
        assert run_prose_rule(rule_path.stem, rule_path, doc, scan_id=1)


def test_lexicon_hits_and_exemption(tmp_path: Path) -> None:
    doc = _write(
        tmp_path / "doc.md",
        "A genuine gain.\nThe real-time feed works.\nIt actually improved.\n",
    )
    found = run_prose_rule("emphasis", _rule(tmp_path, LEXICON_RULE), doc, scan_id=1)
    assert [(finding.line, finding.rule_id) for finding in found] == [
        (1, "emphasis"),
        (3, "emphasis"),
    ]
    assert all(finding.severity == "info" for finding in found)


MOTIF_RULE = """\
id: numberfree
language: prose
kind: motif
min_count: 2
near_window: 20
terms:
  - measured
"""


def test_motif_number_proximity_and_floor(tmp_path: Path) -> None:
    doc = _write(
        tmp_path / "doc.md",
        "The rate was measured at 5.2/min.\nA measured, careful approach.\n",
    )
    rule = _rule(tmp_path, MOTIF_RULE)
    found = run_prose_rule("numberfree", rule, doc, scan_id=1)
    assert [finding.line for finding in found] == [2]

    single = _write(tmp_path / "single.md", "A measured, careful approach.\n")
    assert not run_prose_rule("numberfree", rule, single, scan_id=1)


REGEX_RULE = """\
id: casual
language: prose
kind: regex
patterns:
  - ',\\s+so\\s+(?:the|it)\\b'
"""


def test_regex_kind_and_directory_walk(tmp_path: Path) -> None:
    docs = tmp_path / "docs"
    docs.mkdir()
    _write(docs / "a.md", "It rained, so the model failed.\n")
    _write(docs / "b.py", "x = 1  # , so the linter ignores code files\n")
    found = run_prose_rule("casual", _rule(tmp_path, REGEX_RULE), tmp_path, scan_id=1)
    assert [(finding.path, finding.line) for finding in found] == [("docs/a.md", 1)]
