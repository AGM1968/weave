"""wv-76fc4a: two ways the quality tooling reported something it had not earned.

1. A code rule scanned against a target holding no file of its language reported
   a bare 0, indistinguishable from a clean scan. Only prose rules were
   classified out of scope.
2. A guide with a repeated section heading silently discarded the first body.
"""

from __future__ import annotations

# pylint: disable=missing-class-docstring,missing-function-docstring

import argparse
import json
from pathlib import Path
from unittest.mock import patch

import pytest

from weave_quality.__main__ import cmd_patterns_scan
from weave_quality.db import begin_scan, init_db
from weave_quality.guides import GuideError, parse_guide
from weave_quality.prose_rules import code_rule_out_of_scope


class TestCodeRuleOutOfScope:
    def test_a_python_rule_has_nothing_to_scan_in_a_markdown_file(self, tmp_path: Path) -> None:
        doc = tmp_path / "notes.md"
        doc.write_text("# notes\n")
        assert code_rule_out_of_scope("python", doc)

    def test_a_python_file_is_in_scope(self, tmp_path: Path) -> None:
        mod = tmp_path / "mod.py"
        mod.write_text("x = 1\n")
        assert not code_rule_out_of_scope("python", mod)

    def test_a_directory_is_in_scope_when_any_file_of_the_language_is_under_it(
        self, tmp_path: Path
    ) -> None:
        (tmp_path / "docs").mkdir()
        (tmp_path / "docs" / "a.md").write_text("a\n")
        assert code_rule_out_of_scope("bash", tmp_path)
        (tmp_path / "deep" / "er").mkdir(parents=True)
        (tmp_path / "deep" / "er" / "run.sh").write_text("echo\n")
        assert not code_rule_out_of_scope("bash", tmp_path)

    def test_a_language_it_does_not_know_is_never_claimed_out_of_scope(
        self, tmp_path: Path
    ) -> None:
        (tmp_path / "a.md").write_text("a\n")
        assert not code_rule_out_of_scope("cobol", tmp_path)

    def test_the_scan_names_a_code_rule_with_no_file_of_its_language(
        self, tmp_path: Path, capsys: pytest.CaptureFixture[str]
    ) -> None:
        doc = tmp_path / "notes.md"
        doc.write_text("# notes\n")
        rule = tmp_path / "rule.yml"
        rule.write_text("id: bare\nlanguage: python\n")
        conn = init_db(hot_zone=str(tmp_path))
        begin_scan(conn, "abc")
        conn.commit()
        conn.close()
        args = argparse.Namespace(hot_zone=str(tmp_path), path=str(doc), json=True)
        with (
            patch("weave_quality.__main__._resolve_repo", return_value=str(tmp_path)),
            patch("weave_quality.__main__._load_pattern_rules", return_value=[("bare", rule, "python")]),
            patch("weave_quality.__main__._run_pattern_rule", return_value=[]),
        ):
            assert cmd_patterns_scan(args) == 0
        assert json.loads(capsys.readouterr().out)["out_of_scope"] == ["bare"]


def _guide(tmp_path: Path, body: str, sections: str = "") -> Path:
    path = tmp_path / "sample.md"
    extra = f"sections: {sections}\n" if sections else ""
    path.write_text(
        "---\nid: sample\nviolation_type: prose:register\nsummary: A sample guide.\n"
        f"{extra}---\n\n{body}"
    )
    return path


class TestGuideDuplicateSections:
    def test_a_single_occurrence_of_each_section_parses(self, tmp_path: Path) -> None:
        guide = parse_guide(_guide(tmp_path, "## Why\n\nfirst\n\n## Corrective move\n\nfix\n"), "shipped")
        assert guide.sections["why"] == "first"

    def test_a_repeated_fixed_section_is_refused_not_overwritten(self, tmp_path: Path) -> None:
        body = "## Why\n\nfirst body\n\n## Corrective move\n\nfix\n\n## Why\n\nsecond body\n"
        with pytest.raises(GuideError, match="duplicate section 'Why'"):
            parse_guide(_guide(tmp_path, body), "shipped")

    def test_a_repeated_declared_section_is_refused(self, tmp_path: Path) -> None:
        body = ("## Why\n\nw\n\n## Corrective move\n\nc\n\n## The second form\n\none\n\n"
                "## The second form\n\ntwo\n")
        with pytest.raises(GuideError, match="duplicate section 'The second form'"):
            parse_guide(_guide(tmp_path, body, sections="The second form"), "shipped")


class TestGuideReportsEveryViolation:
    """wv-273b2d: a guide's faults surfaced one run at a time."""

    def test_three_faults_are_raised_together_in_file_order(self, tmp_path: Path) -> None:
        # A comma where | separates names, a section the body never declared,
        # and a missing required section.
        body = "## Why\n\nw\n\n## Exemplars\n\ne\n\n## Steps\n\ns\n\n## Extra\n\nx\n"
        with pytest.raises(GuideError) as raised:
            parse_guide(_guide(tmp_path, body, sections="Exemplars, Steps"), "project")
        errors = raised.value.errors
        assert raised.value.code == "guide_override_invalid"
        assert [e.split(": ", 1)[1].split(" ")[:3] for e in errors] == [
            ["unknown", "section", "'Exemplars'"],
            ["unknown", "section", "'Steps'"],
            ["unknown", "section", "'Extra'"],
            ["section", "corrective_move", "is"],
            ["frontmatter", "declares", "section"],
        ]
        assert str(raised.value) == "; ".join(errors)

    def test_a_single_fault_reads_as_before(self, tmp_path: Path) -> None:
        with pytest.raises(GuideError) as raised:
            parse_guide(_guide(tmp_path, "## Why\n\nw\n"), "shipped")
        assert raised.value.errors == ("sample.md: section corrective_move is required",)
        assert str(raised.value) == "sample.md: section corrective_move is required"
