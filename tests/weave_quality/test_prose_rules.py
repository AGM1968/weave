"""Prose-rule backend invariants."""

# pylint: disable=missing-function-docstring,too-many-lines

from __future__ import annotations

from pathlib import Path

import pytest

from weave_quality.prose_rules import (
    PatternRuleValidationError,
    _dequote,
    _scan_lines,
    _verbatim_exempt_lines,
    load_prose_rule,
    parse_flat_rule,
    rule_language,
    run_prose_rule,
    validate_pattern_rule,
)

DEFAULT_PATTERNS = Path(__file__).parents[2] / "scripts" / "weave_quality" / "default_patterns"
MANAGED_PATTERNS = Path(__file__).parents[2] / "templates" / "quality-patterns" / "managed"


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


def test_parser_preserves_quoted_hash_and_normalizes_fields(tmp_path: Path) -> None:
    rule_path = _write(
        tmp_path / "heading.yaml",
        "id: heading\nlanguage: PROSE\nkind: REGEX\npatterns:\n  - '^# heading$'\n",
    )
    rule = load_prose_rule(rule_path, "heading")
    assert rule["language"] == "prose"
    assert rule["kind"] == "regex"
    assert rule["patterns"] == ["^# heading$"]


def test_heading_match_scope_validates_and_scans_heading_content(tmp_path: Path) -> None:
    rule_path = _write(
        tmp_path / "heading.yaml",
        "id: heading\nlanguage: prose\nkind: regex\nmatch_scope: heading\n"
        "patterns:\n  - '^What\\b'\n",
    )
    rule = load_prose_rule(rule_path, "heading")
    assert rule["match_scope"] == "heading"
    doc = _write(
        tmp_path / "headings.md",
        "What prose does not count.\n\n## What each sensor senses\n\n"
        "> ### What quoted heading means ###\n\n## `What hidden code means`\n",
    )

    found = run_prose_rule("heading", rule_path, doc, scan_id=1)
    assert [(item.line, item.col, item.match_text) for item in found] == [
        (3, 3, "What"),
        (5, 6, "What"),
    ]


def test_parser_accepts_plain_scalar_continuation_and_list_comments(
    tmp_path: Path,
) -> None:
    rule_path = _write(
        tmp_path / "plain.yaml",
        """\
id: plain
language: prose
kind: regex
provenance: Reviewer said "prefer measured claims" and
  the follow-up retained the source evidence.
patterns:
  # Keep this comment with the rule rationale.
  - 'measured # claim'
""",
    )
    rule = load_prose_rule(rule_path, "plain")
    assert rule["provenance"] == (
        'Reviewer said "prefer measured claims" and the follow-up retained the source evidence.'
    )
    assert rule["patterns"] == ["measured # claim"]


def test_parser_decodes_double_quoted_escapes(tmp_path: Path) -> None:
    rule_path = _write(
        tmp_path / "escaped.yaml",
        'id: escaped\nlanguage: prose\nkind: regex\npatterns:\n  - "\\\\bterm\\\\b"\n',
    )
    assert load_prose_rule(rule_path, "escaped")["patterns"] == [r"\bterm\b"]


@pytest.mark.parametrize(
    "line",
    [
        "message: 'unterminated",
        "message: 'first' 'second'",
        "provenance: client language: vouching",
        "patterns:\n  - 'unterminated",
    ],
)
def test_parser_rejects_malformed_plain_and_quoted_scalars(
    tmp_path: Path, line: str
) -> None:
    body = f"id: broken\nlanguage: prose\nkind: regex\n{line}\npatterns:\n  - valid\n"
    with pytest.raises(PatternRuleValidationError):
        validate_pattern_rule(_write(tmp_path / "broken.yaml", body), "broken")


@pytest.mark.parametrize("continuation", ["language", "move", "framing"])
def test_validation_rejects_unquoted_multiline_scalar(
    tmp_path: Path, continuation: str
) -> None:
    rule = _write(
        tmp_path / "broken.yaml",
        f"""\
id: broken
language: prose
kind: regex
provenance: first line
  {continuation}: an unquoted continuation
patterns:
  - 'broken'
""",
    )
    with pytest.raises(PatternRuleValidationError, match=r"broken\.yaml:5: nested"):
        validate_pattern_rule(rule, "broken")


@pytest.mark.parametrize("field", ["provenance", "message"])
def test_controlled_rule_requires_block_scalar_metadata(tmp_path: Path, field: str) -> None:
    metadata = {
        "provenance": "provenance: |-\n  Reviewed production finding.",
        "message": "message: |-\n  Replace the phrase with measured evidence.",
    }
    metadata[field] = f"{field}: unquoted metadata"
    rule = _write(
        tmp_path / "controlled.yaml",
        "id: controlled\nlanguage: prose\nkind: regex\nmaturity: promotable\n"
        f"{metadata['provenance']}\n{metadata['message']}\n"
        "patterns:\n  - '\\bflagged\\b'\n"
        "positive_controls:\n  - 'flagged wording'\n"
        "negative_controls:\n  - 'measured wording'\n",
    )
    with pytest.raises(
        PatternRuleValidationError,
        match=rf"controlled\.yaml: '{field}' must use a block scalar",
    ):
        validate_pattern_rule(rule, "controlled")


@pytest.mark.parametrize("missing", ["positive_controls", "negative_controls"])
def test_promotable_rule_requires_both_control_sets(tmp_path: Path, missing: str) -> None:
    controls = {
        "positive_controls": "positive_controls:\n  - 'flagged wording'\n",
        "negative_controls": "negative_controls:\n  - 'measured wording'\n",
    }
    controls[missing] = ""
    rule = _write(
        tmp_path / "promotable.yaml",
        "id: promotable\nlanguage: prose\nkind: regex\nmaturity: promotable\n"
        "provenance: |-\n  Reviewed production finding.\n"
        "message: |-\n  Replace the phrase.\npatterns:\n  - '\\bflagged\\b'\n"
        f"{controls['positive_controls']}{controls['negative_controls']}",
    )
    with pytest.raises(PatternRuleValidationError, match=missing):
        validate_pattern_rule(rule, "promotable")


@pytest.mark.parametrize(
    ("control", "example", "error"),
    [
        ("positive_controls", "measured wording", "does not produce"),
        ("negative_controls", "flagged wording", "produces a finding"),
    ],
)
def test_control_examples_must_agree_with_production_matcher(
    tmp_path: Path, control: str, example: str, error: str
) -> None:
    rule = _write(
        tmp_path / "candidate.yaml",
        "id: candidate\nlanguage: prose\nkind: regex\nmaturity: candidate\n"
        "patterns:\n  - '\\bflagged\\b'\n"
        f"{control}:\n  - '{example}'\n",
    )
    with pytest.raises(PatternRuleValidationError, match=error):
        validate_pattern_rule(rule, "candidate")


def test_candidate_may_carry_one_control_without_promotable_metadata(tmp_path: Path) -> None:
    rule = _write(
        tmp_path / "candidate.yaml",
        "id: candidate\nlanguage: prose\nkind: regex\nmaturity: candidate\n"
        "patterns:\n  - '\\bflagged\\b'\npositive_controls:\n  - 'flagged wording'\n",
    )
    assert validate_pattern_rule(rule, "candidate") == "prose"


@pytest.mark.parametrize("maturity", ["Promotable", "promotabl"])
def test_maturity_is_normalized_and_unknown_values_are_rejected(
    tmp_path: Path, maturity: str
) -> None:
    rule = _write(
        tmp_path / "rule.yaml",
        f"id: rule\nlanguage: prose\nkind: regex\nmaturity: {maturity}\n"
        "provenance: |-\n  Reviewed.\nmessage: |-\n  Replace it.\n"
        "patterns:\n  - flagged\npositive_controls:\n  - flagged\n"
        "negative_controls:\n  - measured\n",
    )
    if maturity == "Promotable":
        assert load_prose_rule(rule, "rule")["maturity"] == "promotable"
    else:
        with pytest.raises(PatternRuleValidationError, match="unsupported maturity"):
            validate_pattern_rule(rule, "rule")


@pytest.mark.parametrize(
    ("body", "error"),
    [
        ("", "missing or empty 'id'"),
        ("id: wrong\nlanguage: prose\nkind: regex\npatterns:\n  - x\n", "does not match filename"),
        ("id: rule\nlanguage: prose\nkind: regex\npatterns:\n", "missing or empty 'patterns'"),
        ("id: rule\nlanguage: prose\nkind: unknown\nterms:\n  - x\n", "unsupported prose kind"),
        ("id: rule\nlanguage: prose\nkind: regex\npatterns:\n  - '[broken'\n", "invalid regex"),
    ],
)
def test_validation_rejects_invalid_rule_shapes(
    tmp_path: Path, body: str, error: str
) -> None:
    with pytest.raises(PatternRuleValidationError, match=error):
        validate_pattern_rule(_write(tmp_path / "rule.yaml", body), "rule")


@pytest.mark.parametrize("key", ["paths", "exempt"])
def test_validation_rejects_scalar_optional_lists(tmp_path: Path, key: str) -> None:
    body = (
        "id: rule\nlanguage: prose\nkind: regex\npatterns:\n  - measured\n"
        f"{key}: docs/*.md\n"
    )
    with pytest.raises(PatternRuleValidationError, match=key):
        validate_pattern_rule(_write(tmp_path / "rule.yaml", body), "rule")


def test_load_prose_rule_accepts_valid_zero_finding_rule(tmp_path: Path) -> None:
    rule_path = _write(tmp_path / "emphasis.yaml", LEXICON_RULE)
    rule = load_prose_rule(rule_path, "emphasis")
    doc = _write(tmp_path / "doc.md", "A specific measured claim.\n")
    assert rule["kind"] == "lexicon"
    assert not run_prose_rule("emphasis", rule_path, doc, scan_id=1)


def test_default_prose_rules_parse_and_execute(tmp_path: Path) -> None:
    doc = _write(
        tmp_path / "doc.md",
        "A genuine claim, so the reader waits.\n"
        "The metric was measured at 5/min.\n\n"
        "A measured response.\n"
        "Another measured response.\n",
    )
    rule_paths = sorted(DEFAULT_PATTERNS.glob("prose-*.yaml"))

    assert [path.stem for path in rule_paths] == [
        "prose-emphasis-hedge",
        "prose-register-review",
    ]
    for rule_path in rule_paths:
        assert validate_pattern_rule(rule_path, rule_path.stem) == "prose"
        assert parse_flat_rule(rule_path)["language"] == "prose"
        assert run_prose_rule(rule_path.stem, rule_path, doc, scan_id=1)

    for rule_path in sorted(DEFAULT_PATTERNS.glob("*.yaml")):
        assert validate_pattern_rule(rule_path, rule_path.stem)


def test_managed_pattern_manifest_is_complete_and_rules_are_executable(
    tmp_path: Path,
) -> None:
    manifest = (MANAGED_PATTERNS / "manifest.txt").read_text(encoding="utf-8").splitlines()
    rule_paths = sorted(MANAGED_PATTERNS.glob("*.yaml"))
    assert manifest == [path.name for path in rule_paths]

    examples = {
        "markdown-bold-label-metadata": "**Endpoint:** `https://example.test`\n",
        "markdown-bare-url": "Source: https://example.test/long/path\n",
        "markdown-citation-integrity": (
            "The method follows (Jiménez et al., 2023).\n\n"
            "## References\nRussell, A. (2014). Soil moisture.\n"
        ),
        "markdown-split-code-span": "The `scripts/\n",
        "prose-ai-vocabulary": "This pivotal result decorates the claim.\n",
        "prose-em-dash-density": "One—two—three—four linked asides.\n",
        "prose-filler-phrases": "In order to proceed, measure the input.\n",
        "prose-rhetorical-heading": "## What each sensor senses\n",
        "prose-retrospective-announcement": "The endpoint now exists.\n",
        "prose-self-attested-virtue": "This gives an honest interval.\n",
        "prose-significance-heading": "## The conversion, and where its error comes from\n",
        "prose-verification-reassurance": "The result was measured carefully.\n",
        "prose-work-context-leakage": "This session produced the result.\n",
    }
    for rule_path in rule_paths:
        assert validate_pattern_rule(rule_path, rule_path.stem) == "prose"
        doc = _write(tmp_path / f"{rule_path.stem}.md", examples[rule_path.stem])
        assert run_prose_rule(rule_path.stem, rule_path, doc, scan_id=1)


def test_managed_rules_own_positive_and_hard_negative_controls() -> None:
    for rule_path in MANAGED_PATTERNS.glob("*.yaml"):
        rule = load_prose_rule(rule_path, rule_path.stem)
        assert isinstance(rule["positive_controls"], list) and rule["positive_controls"]
        assert isinstance(rule["negative_controls"], list) and rule["negative_controls"]
        # Validation executes every example through the production matcher.
        assert validate_pattern_rule(rule_path, rule_path.stem) == "prose"


def test_citation_integrity_resolves_multiple_author_date_citations(tmp_path: Path) -> None:
    rule_path = MANAGED_PATTERNS / "markdown-citation-integrity.yaml"
    doc = _write(
        tmp_path / "citations.md",
        "Evidence agrees (Jiménez et al., 2023; Russell, 2014; Nkobane, 2014).\n\n"
        "## References\n"
        "Jiménez, A. et al. (2023). Soil moisture.\n\n"
        "Russell, A. (2014). Calibration.\n\n"
        "Nkobane, M. Calibration without a date.\n",
    )

    found = run_prose_rule(rule_path.stem, rule_path, doc, scan_id=1)
    assert [(item.line, item.col, item.match_text) for item in found] == [
        (1, 54, "Nkobane, 2014"),
        (8, 0, "Nkobane"),
    ]


def test_citation_integrity_ignores_complete_entries_and_code(tmp_path: Path) -> None:
    rule_path = MANAGED_PATTERNS / "markdown-citation-integrity.yaml"
    doc = _write(
        tmp_path / "citations.md",
        "Evidence agrees (Jiménez et al., 2023) and not `(Missing, 2022)`.\n\n"
        "## References\n"
        "Jiménez, A. et al. (2023). Soil moisture.\n",
    )
    assert not run_prose_rule(rule_path.stem, rule_path, doc, scan_id=1)


@pytest.mark.parametrize(
    "heading",
    ["Sources", "10. Sources", "Bibliography", "Works cited", "Literature cited", "Reference list"],
)
def test_citation_integrity_recognizes_conventional_reference_headings(
    tmp_path: Path, heading: str
) -> None:
    rule_path = MANAGED_PATTERNS / "markdown-citation-integrity.yaml"
    doc = _write(
        tmp_path / "citations.md",
        f"Evidence agrees (O'Donovan et al., 2023).\n\n## {heading}\n"
        "O'Donovan, P. et al. (2023). Soil moisture.\n",
    )
    assert not run_prose_rule(rule_path.stem, rule_path, doc, scan_id=1)


def test_citation_integrity_bounds_reference_section_and_scans_later_body(
    tmp_path: Path,
) -> None:
    rule_path = MANAGED_PATTERNS / "markdown-citation-integrity.yaml"
    doc = _write(
        tmp_path / "citations.md",
        "Evidence agrees (Yue et al., 2019).\n\n## 10. Sources\n"
        "Yue, J. et al. (2019). Soil moisture.\n\n"
        "## Annex A. Review\nYue's method was discussed.\n"
        "A later claim remains unresolved (Missing, 2024).\n",
    )
    found = run_prose_rule(rule_path.stem, rule_path, doc, scan_id=1)
    assert [(item.line, item.match_text) for item in found] == [(8, "Missing, 2024")]


@pytest.mark.parametrize("token", ["D1.2", "D4.5", "P29", "wv-e321fd", "mo"])
def test_citation_integrity_rejects_code_like_pseudo_authors(
    tmp_path: Path, token: str
) -> None:
    rule_path = MANAGED_PATTERNS / "markdown-citation-integrity.yaml"
    doc = _write(
        tmp_path / "citations.md",
        f"Tracked as ({token}, 2026).\n\n## References\n",
    )
    assert not run_prose_rule(rule_path.stem, rule_path, doc, scan_id=1)


def test_rhetorical_heading_reports_one_finding_for_wh_question(tmp_path: Path) -> None:
    rule_path = MANAGED_PATTERNS / "prose-rhetorical-heading.yaml"
    doc = _write(tmp_path / "heading.md", "## Why does the estimate fail?\n")
    found = run_prose_rule(rule_path.stem, rule_path, doc, scan_id=1)
    assert len(found) == 1


def test_causal_so_claim_covers_openers_excludes_so_that_and_reflows(tmp_path: Path) -> None:
    rule_path = DEFAULT_PATTERNS / "prose-register-review.yaml"
    doc = _write(
        tmp_path / "causal.md",
        "Passed, so any warning is unrelated.\n"
        "Passed, so none remained. Passed, so no retry ran.\n"
        "Passed, so an alert was unnecessary. Passed, so the workflow continued.\n"
        "The gate waits, so that every receipt is durable.\n"
        "Passed, so the\nnetwork-density check continued.\n",
    )
    found = run_prose_rule(rule_path.stem, rule_path, doc, scan_id=1)
    assert [finding.line for finding in found] == [1, 2, 2, 3, 3, 5]


def test_number_free_verification_measures_repetition_not_document_numbers(
    tmp_path: Path,
) -> None:
    # Engine coverage only: the former built-in rule was withdrawn after its
    # first closed adjudication measured 0/14 precision on methods prose.
    # Keep the motif/digit-window contract tested without presenting that
    # uncalibrated term list as an active default.
    rule_path = _rule(
        tmp_path,
        "id: verification-test\nlanguage: prose\nkind: motif\nmin_count: 3\n"
        "require_no_digit_within: 80\nterms:\n  - measured\n",
    )
    unsupported = _write(
        tmp_path / "unsupported.md",
        "Measured output was reported. Measured output was reviewed. "
        "Measured output was retained.\n",
    )
    supported = _write(
        tmp_path / "supported.md",
        "Measured output was 5/min. Measured error was 2%. "
        "Measured coverage was 30 days.\n",
    )
    assert len(run_prose_rule("verification-test", rule_path, unsupported, scan_id=1)) == 3
    assert not run_prose_rule("verification-test", rule_path, supported, scan_id=1)


def test_prose_matchers_exclude_inline_code_spans(tmp_path: Path) -> None:
    emphasis = DEFAULT_PATTERNS / "prose-emphasis-hedge.yaml"
    casual = DEFAULT_PATTERNS / "prose-register-review.yaml"
    verification = _rule(
        tmp_path,
        "id: verification-test\nlanguage: prose\nkind: motif\nmin_count: 3\n"
        "require_no_digit_within: 80\nterms:\n  - measured\n",
    )
    doc = _write(
        tmp_path / "inline.md",
        "Keep `actually`, `passed, so hidden`, and `measured measured measured` as examples. "
        "Actually revise prose that passed, so continue with a measured result, then measured output, "
        "then another measured result.\n",
    )

    assert [finding.match_text for finding in run_prose_rule(
        emphasis.stem, emphasis, doc, scan_id=1
    )] == ["Actually"]
    assert [finding.match_text for finding in run_prose_rule(
        casual.stem, casual, doc, scan_id=1
    )] == [", so continue"]
    assert len(run_prose_rule("verification-test", verification, doc, scan_id=1)) == 3


def test_multiline_inline_code_is_excluded_but_unmatched_backtick_is_literal(
    tmp_path: Path,
) -> None:
    rule_path = DEFAULT_PATTERNS / "prose-emphasis-hedge.yaml"
    doc = _write(
        tmp_path / "multiline.md",
        "A span starts `actually\nand stays actually hidden` before actually prose.\n\n"
        "An unmatched `actually remains literal.\n",
    )

    found = run_prose_rule(rule_path.stem, rule_path, doc, scan_id=1)
    assert [(finding.line, finding.match_text) for finding in found] == [
        (2, "actually"),
        (4, "actually"),
    ]


def test_inline_code_mask_preserves_source_position_after_span(tmp_path: Path) -> None:
    rule_path = DEFAULT_PATTERNS / "prose-emphasis-hedge.yaml"
    doc = _write(tmp_path / "position.md", "Prefix `actually` then clearly revise.\n")

    found = run_prose_rule(rule_path.stem, rule_path, doc, scan_id=1)
    assert [(finding.line, finding.col, finding.match_text) for finding in found] == [
        (1, 23, "clearly")
    ]


@pytest.mark.parametrize(
    "source, expected",
    [
        ("## `passed, so hidden`\n", []),
        ("| case | `passed, so hidden` |\n", []),
        ("## `passed, so hidden` passed, so visible\n", [(1, 29, ", so visible")]),
        (
            "| code | `passed, so hidden` | prose | passed, so visible |\n",
            [(1, 45, ", so visible")],
        ),
    ],
)
def test_inline_code_is_masked_in_headings_and_table_rows(
    tmp_path: Path,
    source: str,
    expected: list[tuple[int, int, str]],
) -> None:
    rule_path = DEFAULT_PATTERNS / "prose-register-review.yaml"
    doc = _write(tmp_path / "contexts.md", source)

    found = run_prose_rule(rule_path.stem, rule_path, doc, scan_id=1)
    assert [
        (finding.line, finding.col, finding.match_text) for finding in found
    ] == expected


def test_regex_rule_exempts_legitimate_compound_terms(tmp_path: Path) -> None:
    rule_path = MANAGED_PATTERNS / "prose-self-attested-virtue.yaml"
    doc = _write(
        tmp_path / "terms.md",
        "An honest broker serves the honest-but-curious protocol. "
        "This is an honest estimate.\n",
    )
    found = run_prose_rule(rule_path.stem, rule_path, doc, scan_id=1)
    assert len(found) == 1
    assert found[0].match_text == "honest"


def test_prose_regex_matches_across_soft_wrap_and_maps_source_line(tmp_path: Path) -> None:
    rule_path = MANAGED_PATTERNS / "prose-filler-phrases.yaml"
    doc = _write(tmp_path / "wrapped.md", "The method runs in\norder to preserve evidence.\n")
    found = run_prose_rule(rule_path.stem, rule_path, doc, scan_id=1)
    assert [(finding.line, finding.col) for finding in found] == [(1, 16)]


def test_line_scoped_structural_rule_does_not_reflow(tmp_path: Path) -> None:
    rule_path = MANAGED_PATTERNS / "markdown-split-code-span.yaml"
    doc = _write(tmp_path / "split.md", "The `scripts/\nworker.py` path.\n")
    found = run_prose_rule(rule_path.stem, rule_path, doc, scan_id=1)
    assert [finding.line for finding in found] == [1, 2]


def test_legacy_markdown_rule_defaults_to_line_scope(tmp_path: Path) -> None:
    rule_path = _write(
        tmp_path / "markdown-legacy.yaml",
        "id: markdown-legacy\nlanguage: prose\nkind: regex\n"
        "patterns:\n  - '^[^`]*`[^`]*$'\n",
    )
    doc = _write(tmp_path / "legacy.md", "The `scripts/\nworker.py` path.\n")
    assert [
        finding.line
        for finding in run_prose_rule("markdown-legacy", rule_path, doc, scan_id=1)
    ] == [1, 2]


def test_line_scope_skips_fenced_code_including_blockquote_nested(tmp_path: Path) -> None:
    rule_path = _write(
        tmp_path / "markdown-legacy.yaml",
        "id: markdown-legacy\nlanguage: prose\nkind: regex\n"
        "patterns:\n  - '`[a-z]+`'\n",
    )
    doc = _write(
        tmp_path / "legacy.md",
        "before `x`\n"
        "```text\n"
        "inside `fence` still code\n"
        "```\n"
        "> ```text\n"
        "> inside `quoted` still code\n"
        "> ```\n"
        "after `y`\n",
    )
    found = run_prose_rule("markdown-legacy", rule_path, doc, scan_id=1)
    assert [finding.line for finding in found] == [1, 8]


def test_line_scope_self_exempts_lines_naming_the_rule_id(tmp_path: Path) -> None:
    rule_path = _write(
        tmp_path / "markdown-legacy.yaml",
        "id: markdown-legacy\nlanguage: prose\nkind: regex\n"
        "patterns:\n  - '`[a-z]+`'\n",
    )
    doc = _write(
        tmp_path / "legacy.md",
        "See the `markdown-legacy` rule for why this line is exempt.\n"
        "But `y` here is still flagged.\n",
    )
    found = run_prose_rule("markdown-legacy", rule_path, doc, scan_id=1)
    assert [finding.line for finding in found] == [2]


def test_line_scope_self_exempt_is_a_whole_identifier_not_a_substring(
    tmp_path: Path,
) -> None:
    """A short rule id like "ai" must not exempt unrelated text that merely
    contains it as a substring (e.g. "maintain")."""
    rule_path = _write(
        tmp_path / "ai.yaml",
        "id: ai\nlanguage: prose\nkind: regex\npatterns:\n  - 'maintain'\n",
    )
    doc = _write(tmp_path / "doc.md", "We maintain this.\n")
    found = run_prose_rule("ai", rule_path, doc, scan_id=1)
    assert [finding.line for finding in found] == [1]


def test_verbatim_marker_exempts_line_scope_rule(tmp_path: Path) -> None:
    rule_path = _write(
        tmp_path / "markdown-legacy.yaml",
        "id: markdown-legacy\nlanguage: prose\nkind: regex\n"
        "patterns:\n  - '`[a-z]+`'\n",
    )
    doc = _write(
        tmp_path / "legacy.md",
        "before `x`\n"
        "<!-- wv-quality:verbatim-start -->\n"
        "quoted tool output with `backticks` stays put\n"
        "<!-- wv-quality:verbatim-end -->\n"
        "after `y`\n",
    )
    found = run_prose_rule("markdown-legacy", rule_path, doc, scan_id=1)
    assert [finding.line for finding in found] == [1, 5]


def test_verbatim_marker_exempts_paragraph_scope_rule_regardless_of_kind(
    tmp_path: Path,
) -> None:
    doc = _write(
        tmp_path / "doc.md",
        "A genuine gain up front.\n"
        "\n"
        "<!-- wv-quality:verbatim-start -->\n"
        "This quoted passage is actually genuine verbatim source text.\n"
        "<!-- wv-quality:verbatim-end -->\n"
        "\n"
        "It actually improved later.\n",
    )
    found = run_prose_rule("emphasis", _rule(tmp_path, LEXICON_RULE), doc, scan_id=1)
    assert [finding.line for finding in found] == [1, 7]


def test_verbatim_marker_unterminated_exempts_through_end_of_file(
    tmp_path: Path,
) -> None:
    doc = _write(
        tmp_path / "doc.md",
        "A genuine gain up front.\n"
        "<!-- wv-quality:verbatim-start -->\n"
        "It actually improved later, but this is quoted.\n",
    )
    found = run_prose_rule("emphasis", _rule(tmp_path, LEXICON_RULE), doc, scan_id=1)
    assert [finding.line for finding in found] == [1]


def test_verbatim_marker_same_line_start_and_end(tmp_path: Path) -> None:
    doc = _write(
        tmp_path / "doc.md",
        "<!-- wv-quality:verbatim-start -->actually<!-- wv-quality:verbatim-end -->\n"
        "It actually improved later.\n",
    )
    found = run_prose_rule("emphasis", _rule(tmp_path, LEXICON_RULE), doc, scan_id=1)
    assert [finding.line for finding in found] == [2]


def test_verbatim_marker_shown_as_a_fenced_example_does_not_leak_through_eof(
    tmp_path: Path,
) -> None:
    """A doc's own fenced *example* of the marker syntax (documentation about
    this feature) must not activate it -- the example has no matching end
    marker, so an unguarded activation would exempt everything through EOF."""
    doc = _write(
        tmp_path / "doc.md",
        "```text\n"
        "<!-- wv-quality:verbatim-start -->\n"
        "```\n"
        "\n"
        "This prose is actually genuine and should still be scanned.\n",
    )
    found = run_prose_rule("emphasis", _rule(tmp_path, LEXICON_RULE), doc, scan_id=1)
    assert [finding.line for finding in found] == [5, 5]


def test_verbatim_marker_mentioned_as_inline_code_does_not_leak_through_eof(
    tmp_path: Path,
) -> None:
    """Mentioning the marker syntax as inline code (documentation about this
    feature) must not activate it either -- same failure mode as the fenced
    example, just via a different Markdown code construct."""
    doc = _write(
        tmp_path / "doc.md",
        "Use `<!-- wv-quality:verbatim-start -->` to open a range.\n"
        "This prose is actually genuine and should still be scanned.\n",
    )
    found = run_prose_rule("emphasis", _rule(tmp_path, LEXICON_RULE), doc, scan_id=1)
    assert [finding.line for finding in found] == [2, 2]

    # A real standalone marker (no inline code involved) still works.
    doc2 = _write(
        tmp_path / "doc2.md",
        "<!-- wv-quality:verbatim-start -->\n"
        "This is actually genuine verbatim source text.\n"
        "<!-- wv-quality:verbatim-end -->\n",
    )
    assert not run_prose_rule("emphasis", _rule(tmp_path, LEXICON_RULE), doc2, scan_id=1)


def test_verbatim_marker_mentioned_inside_a_multiline_inline_code_span_does_not_activate(
    tmp_path: Path,
) -> None:
    """A CommonMark inline-code span can cross physical lines -- its content
    (including the embedded marker text) must stay masked on every line it
    touches, not just the line the opening backtick run appears on, or a
    marker merely mentioned inside a multiline span would wrongly activate
    and exempt the rest of the document through EOF."""
    doc = _write(
        tmp_path / "doc.md",
        "Use ``code\n"
        "<!-- wv-quality:verbatim-start -->\n"
        "still code`` here.\n"
        "\n"
        "This prose should be scanned and is actually genuine.\n",
    )
    found = run_prose_rule("emphasis", _rule(tmp_path, LEXICON_RULE), doc, scan_id=1)
    assert [finding.line for finding in found] == [5, 5]


def test_verbatim_marker_multiline_span_still_closes_on_a_matching_run(
    tmp_path: Path,
) -> None:
    """A genuine standalone marker AFTER a multiline span closes still
    activates normally -- the carried-forward state must reset to 0 once the
    span's matching close run is found."""
    doc = _write(
        tmp_path / "doc.md",
        "Use ``code\n"
        "still code`` here.\n"
        "<!-- wv-quality:verbatim-start -->\n"
        "This quoted passage is actually genuine verbatim source text.\n"
        "<!-- wv-quality:verbatim-end -->\n"
        "It actually improved later.\n",
    )
    found = run_prose_rule("emphasis", _rule(tmp_path, LEXICON_RULE), doc, scan_id=1)
    assert [finding.line for finding in found] == [6]


def test_verbatim_marker_after_a_never_closing_backtick_still_activates(
    tmp_path: Path,
) -> None:
    """An opening backtick run with no matching close ANYWHERE in the
    paragraph is, per CommonMark, literal text -- not a code span. The
    scanner can't know that in advance without look-ahead, so it masks
    speculatively; once the paragraph ends (a blank line, here) without a
    close ever appearing, the speculatively-masked lines must be replayed
    as literal text, or a real marker after a stray backtick is silently
    swallowed."""
    doc = _write(
        tmp_path / "doc.md",
        "A malformed unmatched backtick `\n"
        "<!-- wv-quality:verbatim-start -->\n"
        "This should be exempt and is actually genuine.\n"
        "<!-- wv-quality:verbatim-end -->\n"
        "\n"
        "This prose should be scanned and is actually genuine.\n",
    )
    found = run_prose_rule("emphasis", _rule(tmp_path, LEXICON_RULE), doc, scan_id=1)
    assert [finding.line for finding in found] == [6, 6]


def test_verbatim_marker_after_a_stray_backtick_interrupted_by_a_heading_still_activates(
    tmp_path: Path,
) -> None:
    """A heading starts a new block -- inline parsing (and so a backtick
    span search) cannot cross into or out of it. A stray unmatched
    backtick on one line must not treat a matching backtick TWO blocks
    later (past an intervening heading) as its partner; the heading must
    reset the speculative span, or a real marker after it gets swallowed
    by a false multi-block "code span"."""
    doc = _write(
        tmp_path / "doc.md",
        "A stray `\n"
        "# Heading\n"
        "<!-- wv-quality:verbatim-start -->\n"
        "`\n"
        "This should be exempt.\n"
        "<!-- wv-quality:verbatim-end -->\n",
    )
    exempt = _verbatim_exempt_lines(doc.read_text(encoding="utf-8").splitlines())
    assert exempt == {3, 4, 5, 6}


def test_verbatim_marker_stays_masked_when_a_line_both_closes_and_reopens_a_span(
    tmp_path: Path,
) -> None:
    """A single physical line can both close the incoming span AND open a
    brand-new unresolved one. The marker here is genuinely inside the
    FIRST (validly closed) span and must stay masked -- flushing the
    entire buffer as literal just because a NEW span also opened on the
    closing line would wrongly activate it."""
    doc = _write(
        tmp_path / "doc.md",
        "Use `\n"
        "<!-- wv-quality:verbatim-start -->\n"
        "` then stray `\n"
        "Ordinary prose\n",
    )
    exempt = _verbatim_exempt_lines(doc.read_text(encoding="utf-8").splitlines())
    assert exempt == set()


def test_marker_inside_a_proven_span_stays_masked_even_when_the_reopener_never_closes(
    tmp_path: Path,
) -> None:
    """The close/reopen line's PREFIX (through the incoming closer) is
    proven code, distinct from its unresolved SUFFIX (the new opener).
    Buffering the whole raw line for replay-if-never-closed would also
    unmask the already-proven prefix -- including a marker genuinely
    inside it -- just because the unrelated trailing opener never found
    its own partner."""
    doc = _write(
        tmp_path / "doc.md",
        "Use `\n"
        "prefix <!-- wv-quality:verbatim-start -->` trailing `\n",
    )
    exempt = _verbatim_exempt_lines(doc.read_text(encoding="utf-8").splitlines())
    assert exempt == set()


def test_verbatim_marker_recognized_inside_a_doubly_nested_blockquote_fence(
    tmp_path: Path,
) -> None:
    """_fence_probe_text must strip every nested blockquote level, not just
    one -- a fenced *example* of the marker two blockquote levels deep is
    still a fenced example (documentation about the feature), and must not
    activate it."""
    doc = _write(
        tmp_path / "doc.md",
        "> > ```text\n"
        "> > <!-- wv-quality:verbatim-start -->\n"
        "> > ```\n"
        "This prose should still be scanned and is actually genuine.\n",
    )
    found = run_prose_rule("emphasis", _rule(tmp_path, LEXICON_RULE), doc, scan_id=1)
    assert [finding.line for finding in found] == [4, 4]


def test_unclosed_nested_blockquote_fence_closes_on_outdent(tmp_path: Path) -> None:
    """A fenced block nested inside a blockquote implicitly ends when the
    blockquote itself ends -- CommonMark code fences cannot be lazily
    continued, so an outdented line (no longer inside the blockquote) is
    not fenced content even without an explicit closing fence marker.
    Fence state that tracks only char/length (not the container depth it
    opened at) survives past the blockquote and swallows unrelated prose
    after it as if it were still fenced."""
    doc = _write(
        tmp_path / "doc.md",
        "> > ```text\n"
        "> > quoted code\n"
        "This prose is actually genuine.\n",
    )
    found = run_prose_rule("emphasis", _rule(tmp_path, LEXICON_RULE), doc, scan_id=1)
    assert [finding.line for finding in found] == [3, 3]


def test_unclosed_nested_blockquote_fence_closes_on_outdent_line_scope(
    tmp_path: Path,
) -> None:
    """Same outdent-closes-the-fence semantics apply to the line-scope
    (match_scope: line) path, not just paragraph reflow."""
    rule_path = _write(
        tmp_path / "markdown-legacy.yaml",
        "id: markdown-legacy\nlanguage: prose\nkind: regex\n"
        "patterns:\n  - 'forbidden phrase'\n",
    )
    doc = _write(
        tmp_path / "doc.md",
        "> > ```text\n"
        "> > forbidden phrase\n"
        "forbidden phrase\n",
    )
    found = run_prose_rule("markdown-legacy", rule_path, doc, scan_id=1)
    assert [finding.line for finding in found] == [3]


def test_line_scope_skips_html_block_content_like_paragraph_scope_does() -> None:
    """match_scope: line rules must advance HTML block state too, not
    just fenced-code state -- a structural rule shouldn't see raw HTML
    content that paragraph-scope rules already correctly suppress."""
    lines = _scan_lines(
        "<script>\nhidden\n</script>\nvisible\n", {"id": "x", "match_scope": "line"}
    )
    assert [scan_line.text for scan_line in lines] == ["visible"]


def test_paragraph_scope_skips_blockquoted_fenced_code_like_line_scope_does(
    tmp_path: Path,
) -> None:
    """Paragraph mode must dequote before checking for a fence, the same way
    line mode already does -- otherwise a blockquoted fence isn't recognized
    as a fence at all, and its "content" lines get scanned as quoted prose."""
    doc = _write(
        tmp_path / "doc.md",
        "> ```text\n"
        "> forbidden phrase\n"
        "> ```\n"
        "\n"
        "This prose is actually genuine.\n",
    )
    rule = """\
id: forbidden
language: prose
kind: regex
patterns:
  - forbidden phrase
"""
    assert not run_prose_rule("forbidden", _rule(tmp_path, rule), doc, scan_id=1)


def test_deeper_nested_quote_line_stays_fenced_content_not_a_false_closer(
    tmp_path: Path,
) -> None:
    """A fence opened at quote depth 1 is not closed by a fence-shaped line
    at depth 2 -- the extra ">" is part of the fenced text verbatim (a
    nested blockquote marker mentioned inside the fence), not markup
    introducing a container with its own closer. Checking the close
    pattern regardless of depth let a coincidental fence-shaped line one
    level deeper falsely end the outer fence and expose the remaining
    fenced content as prose."""
    doc = _write(
        tmp_path / "doc.md",
        "> ```\n"
        "> > ```\n"
        "> forbidden phrase\n"
        "> ```\n",
    )
    rule = """\
id: forbidden
language: prose
kind: regex
patterns:
  - forbidden phrase
"""
    assert not run_prose_rule("forbidden", _rule(tmp_path, rule), doc, scan_id=1)


def test_outdent_that_closes_a_quoted_fence_can_open_a_root_fence_same_line(
    tmp_path: Path,
) -> None:
    """An outdent that closes the blockquote containing an unclosed fence
    can, on that SAME physical line, also open a new root-level fence --
    CommonMark evaluates the line as a fresh opener in its own (now outer)
    container once the old one's gone, not as pure non-fenced prose.
    _advance_fence_state previously returned immediately after clearing the
    old fence state, without ever checking whether the line itself matched
    a fence opener; the new fence -- and the "forbidden phrase" content
    inside it -- was exposed as ordinary prose instead of staying fenced."""
    doc = _write(
        tmp_path / "doc.md",
        "> ```\n"
        "```\n"
        "forbidden phrase\n"
        "```\n",
    )
    rule = """\
id: forbidden
language: prose
kind: regex
patterns:
  - forbidden phrase
"""
    assert not run_prose_rule("forbidden", _rule(tmp_path, rule), doc, scan_id=1)


def test_four_space_indented_backticks_are_indented_code_not_a_fence_opener(
    tmp_path: Path,
) -> None:
    """CommonMark allows at most 3 leading spaces before a fence opener --
    4+ is an indented code block, a DIFFERENT construct. Blanket-stripping
    indentation before the fence check erased that distinction, so a
    4-space-indented backtick run falsely opened a fence that never
    closed, swallowing the rest of the document as code."""
    doc = _write(
        tmp_path / "doc.md",
        "    ```\ngenuine prose\n",
    )
    found = run_prose_rule("emphasis", _rule(tmp_path, LEXICON_RULE), doc, scan_id=1)
    assert [finding.line for finding in found] == [2]


def test_four_space_indented_backticks_are_indented_code_line_scope(
    tmp_path: Path,
) -> None:
    """Same indented-code-not-a-fence distinction for the line-scope path."""
    rule_path = _write(
        tmp_path / "markdown-legacy.yaml",
        "id: markdown-legacy\nlanguage: prose\nkind: regex\n"
        "patterns:\n  - genuine\n",
    )
    doc = _write(
        tmp_path / "doc.md",
        "    ```\ngenuine prose\n",
    )
    found = run_prose_rule("markdown-legacy", rule_path, doc, scan_id=1)
    assert [finding.line for finding in found] == [2]


def test_four_space_indented_blockquote_marker_is_not_a_fence_opener(
    tmp_path: Path,
) -> None:
    """CommonMark allows at most 3 leading spaces before a blockquote marker
    too -- a 4-space-indented '>' is indented code, not a quote. Previously
    _MARKDOWN_QUOTE_RE allowed unlimited leading whitespace, so this line
    dequoted into a bogus fence opener that swallowed the genuinely quoted
    "forbidden phrase" on the following real (0-space) blockquote lines as
    fenced content."""
    doc = _write(
        tmp_path / "doc.md",
        "    > ```\n"
        "> forbidden phrase\n"
        "> ```\n",
    )
    rule = """\
id: forbidden
language: prose
kind: regex
patterns:
  - forbidden phrase
"""
    found = run_prose_rule("forbidden", _rule(tmp_path, rule), doc, scan_id=1)
    assert [finding.line for finding in found] == [2]


def test_backtick_in_backtick_fence_info_string_is_not_a_valid_opener(
    tmp_path: Path,
) -> None:
    """CommonMark forbids a backtick anywhere in a backtick fence's info
    string -- it would be ambiguous with an inline code span, so a line
    like "``` aa ```" never opens a fence at all. _FENCE_OPEN_RE matched on
    the marker run alone, so this line falsely opened an unclosed fence
    that swallowed the genuine "forbidden phrase" prose after it."""
    doc = _write(
        tmp_path / "doc.md",
        "``` aa ```\nforbidden phrase\n",
    )
    rule = """\
id: forbidden
language: prose
kind: regex
patterns:
  - forbidden phrase
"""
    found = run_prose_rule("forbidden", _rule(tmp_path, rule), doc, scan_id=1)
    assert [finding.line for finding in found] == [2]


def test_zero_to_three_space_indented_fence_still_opens_and_closes(
    tmp_path: Path,
) -> None:
    """The 0-3 space tolerance must still recognize a genuinely
    slightly-indented fence, not just reject 4+."""
    doc = _write(
        tmp_path / "doc.md",
        "  ```text\n  forbidden phrase\n  ```\n\nThis prose is actually genuine.\n",
    )
    rule = """\
id: forbidden
language: prose
kind: regex
patterns:
  - forbidden phrase
"""
    assert not run_prose_rule("forbidden", _rule(tmp_path, rule), doc, scan_id=1)


def test_blockquote_paragraph_supports_lazy_continuation(tmp_path: Path) -> None:
    """CommonMark allows a blockquote paragraph to continue on a line with
    no ">" prefix at all. Treating that as a fresh, separate paragraph
    loses the text adjacency a rule matching across the line boundary
    depends on."""
    doc = _write(tmp_path / "doc.md", "> in order\nto proceed\n")
    rule = """\
id: joined
language: prose
kind: regex
patterns:
  - in order to proceed
"""
    found = run_prose_rule("joined", _rule(tmp_path, rule), doc, scan_id=1)
    assert len(found) == 1


def test_backtick_span_survives_a_lazy_blockquote_continuation(tmp_path: Path) -> None:
    """A raw blockquote-depth drop via lazy continuation (a line with no
    ">" at all) must not be treated as an inline-span boundary -- fenced
    blocks can't lazily continue (unaffected by this fix), but an ordinary
    backtick span inside a paragraph can, the same as CommonMark's own
    inline parsing crossing a lazy-continued paragraph line."""
    doc = _write(
        tmp_path / "doc.md",
        "> Use `code\n"
        "still <!-- wv-quality:verbatim-start --> code` here.\n",
    )
    exempt = _verbatim_exempt_lines(doc.read_text(encoding="utf-8").splitlines())
    assert exempt == set()


def test_thematic_break_interrupts_a_quoted_paragraph() -> None:
    """A thematic break interrupts an open paragraph -- including one open
    inside a blockquote -- the same as CommonMark's own block rules.
    Treating it as ordinary lazy-continuation text merged unrelated content
    across a genuine block boundary into one paragraph/finding."""
    lines = _scan_lines("> in order\n---\nto proceed\n", {"id": "test"})
    assert [scan_line.text for scan_line in lines] == ["in order", "---", "to proceed"]


def test_indentation_cannot_interrupt_an_open_quoted_paragraph() -> None:
    """Indentation can START an indented code block, but cannot INTERRUPT an
    already-open paragraph -- a 4-space-indented line right after an open
    blockquote paragraph is CommonMark lazy continuation, not a fresh code
    block that silently drops the paragraph's remaining text."""
    lines = _scan_lines("> in order\n    to proceed\n", {"id": "test"})
    assert len(lines) == 1
    assert "in order" in lines[0].text
    assert "to proceed" in lines[0].text


def test_non_1_ordered_item_does_not_interrupt_an_open_quoted_paragraph() -> None:
    """CommonMark: only an ordered list item starting at 1 can interrupt a
    paragraph -- any other starting number is ordinary continuation text
    (its digits and delimiter stay literal), not a real list marker that
    splits the paragraph in two."""
    lines = _scan_lines("> in order\n2. to proceed\n", {"id": "test"})
    assert len(lines) == 1
    assert lines[0].text == "in order 2. to proceed"


def test_list_item_interrupts_a_quoted_paragraph() -> None:
    """A list marker nested inside a blockquote ("> 1. after") is checked
    against the fully-dequoted probe the same as a heading or thematic
    break, so it interrupts the quoted paragraph into a separate list unit
    instead of being merged as ordinary quote-continuation text."""
    lines = _scan_lines("> before\n> 1. after\n", {"id": "test"})
    assert [scan_line.text for scan_line in lines] == ["before", "after"]


def test_lazy_list_continuation_strips_every_quote_level() -> None:
    """wv-ac22a5 finding 3 (external code review round 3): a list item
    nested two blockquote levels deep had its lazy continuation
    rematched against the raw line with the single-level
    _MARKDOWN_QUOTE_RE, stripping only the outer ">" and leaving the
    inner one as literal paragraph text ("item >       target" instead
    of "item target"). The continuation must use the already
    fully-dequoted probe, the same fix _lazy_paragraph_content already
    got for the non-list lazy path (wv-191cc0)."""
    lines = _scan_lines("> > - item\n> >       target\n", {"id": "test"})
    assert [scan_line.text for scan_line in lines] == ["item target"]


_PARTIAL_POP_HEADING_REPRO = "- outer\n  - inner\n    text\n  # heading\n  <div>\n  hidden\n- sibling\n"
_PARTIAL_POP_BREAK_REPRO = "- outer\n  - inner\n    text\n  ---\n  <div>\n  hidden\n- sibling\n"


@pytest.mark.parametrize("text", [_PARTIAL_POP_HEADING_REPRO, _PARTIAL_POP_BREAK_REPRO])
def test_partial_pop_heading_or_break_preserves_the_surviving_list_ancestor(text: str) -> None:
    """wv-784f03 (external code review round 3, finding 1): a heading or
    thematic break inside a nested list item only partially pops the
    list stack (the outer item survives, only the inner one ends) --
    but the dispatch called flush() unconditionally, which resets
    list_stack to [] as a side effect of emitting a paragraph. The
    following HTML block (<div>) then opened as ROOT-owned instead of
    outer-owned, so it never ended at "- sibling" -- silently
    swallowing it (and everything after) to EOF. CommonMark (verified
    against markdown-it) keeps the heading/break and <div> inside the
    outer item, then ends the HTML block at "- sibling"."""
    lines = _scan_lines(text, {"id": "test"})
    assert [scan_line.text for scan_line in lines] == [
        "outer",
        "inner text",
        text.splitlines()[3],
        "sibling",
    ]


@pytest.mark.parametrize("text", [_PARTIAL_POP_HEADING_REPRO, _PARTIAL_POP_BREAK_REPRO])
def test_partial_pop_heading_or_break_preserves_list_ownership_at_line_scope(text: str) -> None:
    """Same finding-1 fix, the match_scope: line path (_scan_lines_raw):
    that dispatch's generic "else" fallback unconditionally cleared
    list_stack for heading/break kind too, corrupting the NEXT line's
    own container tracking (container=="" while list_stack was still
    genuinely non-empty) -- "sibling" must still surface as its own,
    correctly list-owned line, not get swallowed into a falsely
    root-owned HTML block."""
    lines = _scan_lines(text, {"id": "test", "match_scope": "line"})
    assert [scan_line.text for scan_line in lines][-1] == "- sibling"


def test_quoted_continuation_after_partial_pop_restores_the_deepest_owner() -> None:
    """wv-f32f1b (external code review round 3, finding 2): a quote-
    marked continuation line at the item's own already-established
    quote_depth (not a genuine depth transition) used to bypass
    _reattach_lazy_owner_if_dropped entirely -- only "code"/"lazy" kinds
    were normalized to "lazy" there, so "after" (still carrying its own
    literal ">" marker at depth 1, the same depth already in effect)
    attached to the SURVIVING outer item via _list_item_continuation's
    own quote branch instead of reattaching to the just-popped INNER
    item's still-open paragraph. The later <div> then opened with the
    wrong owner and swallowed "sibling" to EOF instead of ending before
    it. CommonMark (verified against markdown-it) merges "after" into
    the deepest open paragraph and ends the HTML block at "sibling"."""
    text = "> - outer\n>   - inner\n>     inner text\n>   after\n>     <div>\n>     hidden\n>   sibling\n"
    lines = _scan_lines(text, {"id": "test"})
    assert [scan_line.text for scan_line in lines] == ["outer", "inner inner text after", "sibling"]


def test_quoted_continuation_after_partial_pop_at_line_scope_reaches_the_final_line() -> None:
    """Same finding-2 fix, the match_scope: line path -- _scan_lines_raw
    shares _reattach_lazy_owner_if_dropped with the paragraph path, so
    fixing the shared function covers this consumer too; "sibling"
    (the final physical line) must still surface, not be swallowed."""
    text = "> - outer\n>   - inner\n>     inner text\n>   after\n>     <div>\n>     hidden\n>   sibling\n"
    lines = _scan_lines(text, {"id": "test", "match_scope": "line"})
    assert [scan_line.text for scan_line in lines][-1] == ">   sibling"


def test_fresh_ordered_list_may_start_at_a_number_other_than_one() -> None:
    """CommonMark's start==1 restriction applies only when a list item
    would INTERRUPT an already-open paragraph -- a fresh list (nothing open
    yet) may start at any number, and its digits/delimiter are read as a
    real marker, not literal continuation text."""
    lines = _scan_lines("2. first\n   continuation\n", {"id": "test"})
    assert [scan_line.text for scan_line in lines] == ["first continuation"]


def test_ordinary_ordered_list_items_do_not_restart_the_restriction() -> None:
    """The start==1 restriction is about interrupting a PARAGRAPH, not about
    extending an already-open list -- an ordinary "1. / 2. / 3." list must
    not merge its later items into one literal-text blob."""
    lines = _scan_lines("1. first\n2. second\n3. third\n", {"id": "test"})
    assert [scan_line.text for scan_line in lines] == ["first", "second", "third"]


def test_blank_first_list_item_does_not_interrupt_an_open_paragraph() -> None:
    """A list marker with no content at all ("-" alone) is a blank first
    item -- CommonMark: a blank first item cannot interrupt an open
    paragraph, so it stays ordinary continuation text rather than being
    read as a real (empty) list item that splits the paragraph."""
    lines = _scan_lines("before\n- \nafter\n", {"id": "test"})
    assert len(lines) == 1
    assert lines[0].text.split() == ["before", "-", "after"]


def test_verbatim_span_cannot_cross_a_quoted_list_boundary() -> None:
    """An inline code span speculatively open across a genuine quoted-list
    boundary must not be allowed to swallow it -- an unresolved backtick
    from the quoted paragraph reverts to literal at the list item, so a
    verbatim-exempt marker written there is still recognized as real,
    literal text, not masked-away code."""
    lines = (
        "> before `unclosed\n"
        "> 1. <!-- wv-quality:verbatim-start --> after\n"
        "> 1. <!-- wv-quality:verbatim-end --> done\n"
    ).splitlines()
    exempt = _verbatim_exempt_lines(lines)
    assert exempt == {2, 3}


def test_html_block_interrupts_a_quoted_paragraph() -> None:
    """A CommonMark type-6 HTML block start (e.g. "<div>") is checked
    against the fully-dequoted probe the same as a heading, so it
    interrupts a quoted paragraph into a separate unit instead of being
    merged as ordinary quote-continuation text. The block is STATEFUL
    (_HtmlBlockState/_advance_html_block_state): it continues -- and its
    own content is suppressed from prose scanning, the same as fenced
    code -- through the blank line that ends a type-6 block; "after"
    only becomes its own unit once the block has actually closed."""
    lines = _scan_lines("> before\n<div>\ncontent\n\nafter\n", {"id": "test"})
    assert [scan_line.text for scan_line in lines] == ["before", "after"]


def test_html_block_with_no_terminating_blank_line_extends_through_eof() -> None:
    """A type-6/7 HTML block with NO blank line before EOF never closes --
    everything after its opener, including text that looks like it should
    be ordinary prose, stays suppressed as the block's own (unterminated)
    content. This is real CommonMark behavior, not a bug: a document
    author who opens such a block must close it with a blank line."""
    lines = _scan_lines("> before\n<div>\nafter\n", {"id": "test"})
    assert [scan_line.text for scan_line in lines] == ["before"]


def test_html_comment_interrupts_like_any_other_html_block() -> None:
    """A genuine (non-marker) HTML comment is a type-2 HTML block start and
    interrupts an open paragraph the same as any other HTML block type --
    only this module's OWN wv-quality:verbatim marker comment is exempted
    from that (see test_verbatim_marker_stays_masked_when_a_line_both_closes_and_reopens_a_span
    and friends, which depend on the marker NOT being block-level). This
    one-line comment opens and closes ("-->") on the same physical line,
    so it's a self-contained, fully-suppressed unit -- both scanners treat
    an HTML block's own lines as opaque, the same as a fenced code block,
    not as a separate prose scan unit of their own."""
    lines = _scan_lines("before\n<!-- a normal comment -->\nafter\n", {"id": "test"})
    assert [scan_line.text for scan_line in lines] == ["before", "after"]


def test_html_type7_tag_alone_on_a_line_does_not_interrupt_an_open_paragraph() -> None:
    """CommonMark HTML block type 7 (a complete tag alone on its own line,
    for any tag name) cannot interrupt an already-open paragraph -- unlike
    types 1-6, it can only START a block when nothing is open yet."""
    lines = _scan_lines("before\n<span>\nafter\n", {"id": "test"})
    assert len(lines) == 1
    assert lines[0].text == "before <span> after"


def test_html_type7_tag_alone_on_a_line_starts_a_fresh_block() -> None:
    """The same type-7 tag, with nothing open before it, DOES start its own
    (suppressed, blank-terminated) block -- the restriction is specifically
    about interrupting, not about type 7 never being recognized at all."""
    lines = _scan_lines("<span>\n\nafter\n", {"id": "test"})
    assert [scan_line.text for scan_line in lines] == ["after"]


def test_verbatim_span_cannot_cross_an_html_block_boundary() -> None:
    """An inline code span speculatively open across a genuine HTML block
    boundary must not be allowed to swallow it -- an unresolved backtick
    reverts to literal at the HTML block start, so a verbatim-exempt
    marker written after the block properly closes (a blank line ends
    this type-6 block) is still recognized as real, literal text."""
    lines = (
        "> before `unclosed\n"
        "<div>\n"
        "\n"
        "<!-- wv-quality:verbatim-start --> after\n"
        "<!-- wv-quality:verbatim-end --> done\n"
    ).splitlines()
    exempt = _verbatim_exempt_lines(lines)
    assert exempt == {4, 5}


def test_verbatim_marker_inside_an_active_html_comment_is_not_a_real_directive() -> None:
    """A marker written on its own line is still just CONTENT of an
    already-open (not yet terminated) type-2 HTML comment block -- it must
    not be read as a real directive, the same as one merely MENTIONED
    inside a genuine inline code span isn't."""
    lines = "<!--\n<!-- wv-quality:verbatim-start -->\n-->\nafter\n".splitlines()
    exempt = _verbatim_exempt_lines(lines)
    assert exempt == set()


def test_html_type1_block_continues_through_its_own_terminator() -> None:
    """A type-1 block (script/pre/style/textarea) continues through its
    OWN terminator regex ("</script>" etc.), not a blank line -- the
    body and closing tag are both suppressed HTML content, and only the
    line after the terminator resumes ordinary prose scanning."""
    lines = _scan_lines(
        "<script>\nin order\nto proceed\n</script>\nafter\n", {"id": "test"}
    )
    assert [scan_line.text for scan_line in lines] == ["after"]


def test_quoted_html_block_ends_when_its_quote_container_ends() -> None:
    """An HTML block opened inside a blockquote is scoped to the quote
    depth it opened at, the same as a fence (_advance_fence_state) --
    outdenting out of the blockquote ends the block WITHOUT its own
    terminator/blank line, and the outdented line resumes ordinary
    (unsuppressed) scanning."""
    lines = _scan_lines("> <div>\n> content\nafter\n", {"id": "test"})
    assert [scan_line.text for scan_line in lines] == ["after"]


def test_active_html_block_does_not_over_dequote_a_deeper_quote_marker() -> None:
    """A block opened at quote_depth 1 owns exactly one level of ">" as
    its container prefix -- a SECOND ">" on a later line is literal
    block content (e.g. inside an HTML comment), not a further container
    prefix to strip. Fully dequoting it (as _dequote would) makes the
    line look blank when it isn't, falsely ending a type-6/7 block; here
    it must stay active straight through to EOF, suppressing "visible"
    too, the same as any other unterminated block."""
    lines = _scan_lines("> <div>\n> >\n> visible\n", {"id": "test"})
    assert not lines


def test_active_html_block_blank_check_is_ascii_only() -> None:
    """CommonMark blank lines contain only spaces/tabs -- an NBSP-only
    line is a single non-space character, not blank, so it does not end
    a type-6/7 block. The block therefore stays active through EOF."""
    lines = _scan_lines("<div>\n \nvisible\n", {"id": "test"})
    assert not lines


def test_html_type7_excludes_script_open_tag() -> None:
    """CommonMark explicitly excludes pre/script/style/textarea OPEN tags
    from type 7 -- "<script/>" is not type 1 either (a bare "/" isn't an
    allowed character after the tag name there), so it's ordinary inline
    raw HTML within an ordinary paragraph, not a suppressed leaf block."""
    lines = _scan_lines("<script/>\nvisible\n", {"id": "test"})
    assert len(lines) == 1
    assert lines[0].text == "<script/> visible"


def test_html_type7_still_accepts_a_script_closing_tag() -> None:
    """The pre/script/style/textarea exclusion applies to OPEN tags only
    -- a closing tag of those same names remains type-7-eligible."""
    lines = _scan_lines("</script>\n\nafter\n", {"id": "test"})
    assert [scan_line.text for scan_line in lines] == ["after"]


def test_html_type7_ordinary_tag_still_starts_a_block() -> None:
    """The exclusion is scoped to exactly the four named tags -- any
    other tag name is unaffected and still starts a type-7 block."""
    lines = _scan_lines("<span/>\n\nafter\n", {"id": "test"})
    assert [scan_line.text for scan_line in lines] == ["after"]


def test_html_type6_tag_list_includes_search() -> None:
    """"search" belongs to CommonMark's current type-6 block-tag set and
    must interrupt a paragraph the same as any other listed tag."""
    lines = _scan_lines("before\n<search>\nafter\n", {"id": "test"})
    assert [scan_line.text for scan_line in lines] == ["before"]


def test_html_type5_cdata_opener_is_case_sensitive() -> None:
    """CommonMark's CDATA opener token is the literal, uppercase "CDATA" --
    unlike type-1/type-6 tag NAMES (genuinely case-insensitive), a
    lowercase "<![cdata[" is not a valid type-5 opener at all and stays
    ordinary text."""
    lines = _scan_lines("before\n<![cdata[\nafter\n", {"id": "test"})
    assert len(lines) == 1
    assert lines[0].text == "before <![cdata[ after"


def test_html_type6_bare_slash_without_a_close_angle_is_not_an_opener() -> None:
    """A type-6 tag name must be followed by whitespace, '>', an exact
    self-closing '/>', or end-of-line -- a bare '/' not immediately
    followed by '>' is a malformed tag, not CommonMark's self-closing
    form, and must not interrupt a paragraph."""
    lines = _scan_lines("before\n<div/not-a-tag\nafter\n", {"id": "test"})
    assert len(lines) == 1
    assert lines[0].text == "before <div/not-a-tag after"


def test_html_type6_legit_self_closing_tag_still_interrupts() -> None:
    """A genuinely self-closing type-6 tag ("<div/>") is unaffected by the
    bare-slash fix -- it still interrupts a paragraph normally."""
    lines = _scan_lines("before\n<div/>\nafter\n", {"id": "test"})
    assert [scan_line.text for scan_line in lines] == ["before"]


def test_list_source_column_survives_a_duplicated_ordinal_digit() -> None:
    """Content source-column mapping must use the list marker's own
    structural regex offset (dequoted-prefix width + list_match.start(1)),
    not line.index(content) -- searching for the captured text would
    instead find the ordinal's OWN digit ("1.") when the captured content
    happens to equal it ("1"), reporting the wrong column."""
    lines = _scan_lines("1. 1\n", {"id": "test"})
    assert lines[0].source_position(0) == (1, 3)


def test_quoted_list_source_column_accounts_for_the_quote_prefix_too() -> None:
    """The same duplicated-ordinal-digit case, now nested inside a
    blockquote -- the fix must add back the width of whatever quote
    prefix dequoting stripped, not just the in-probe offset."""
    lines = _scan_lines("> 1. 1\n", {"id": "test"})
    assert lines[0].source_position(0) == (1, 5)


def test_quote_source_column_uses_the_structural_capture_offset() -> None:
    """Quote content source-column mapping must use the quote marker's own
    capture offset (quote_match.start(1)), not line.index(content)."""
    lines = _scan_lines("> text\n", {"id": "test"})
    assert lines[0].source_position(0) == (1, 2)


def test_quoted_lazy_source_column_uses_the_structural_capture_offset() -> None:
    """A quote_depth > 0 line reached via kind=="lazy" (container-relative
    indentation that can't interrupt, see _paragraph_interrupt_kind) must
    map its content's source column the same structural way as kind ==
    "quote" does -- not by searching for the captured text in the line."""
    lines = _scan_lines("> before\n>     text\n", {"id": "test"})
    assert lines[0].source_position(len("before ")) == (2, 2)


def test_increasing_quote_depth_starts_a_new_paragraph_unit() -> None:
    """A nested blockquote ("> >") is a child container, not the ordinary
    continuation of the outer quote's paragraph -- entering it must flush
    the outer paragraph into its own unit instead of merging the two.

    wv-191cc0 (external code review): the second unit's content is
    "after", not "> after" -- see test_quote_depth_two_content_is_fully_
    dequoted for why a depth>=2 quote's content must come from
    _dequote's own recursive result, not a single-level rematch of the
    raw line."""
    lines = _scan_lines("> before\n> > after\n", {"id": "test"})
    assert [scan_line.text for scan_line in lines] == ["before", "after"]


def test_decreasing_quote_depth_starts_a_new_paragraph_unit() -> None:
    """Leaving a nested blockquote is a block change symmetric with
    entering one -- the outdented line starts its own unit rather than
    merging into the still-open nested paragraph.

    wv-191cc0 (external code review): the first unit's content is
    "before", not "> before" -- same fix as the increasing-depth case
    above, applied to a depth>=2 line's OWN content, not just a later
    lazy continuation of it."""
    lines = _scan_lines("> > before\n> after\n", {"id": "test"})
    assert [scan_line.text for scan_line in lines] == ["before", "after"]


def test_same_quote_depth_stays_one_paragraph() -> None:
    """Two consecutive explicit quote lines at the SAME depth are the
    ordinary way to write one blockquote paragraph -- not a boundary."""
    lines = _scan_lines("> before\n> after\n", {"id": "test"})
    assert [scan_line.text for scan_line in lines] == ["before after"]


def test_quote_depth_two_content_is_fully_dequoted() -> None:
    """wv-191cc0 (external code review): kind=="quote" paragraph
    extraction used to rematch the raw line with the single-level
    _MARKDOWN_QUOTE_RE, capturing everything after the FIRST ">" --
    including a second, still-literal ">" marker -- instead of using
    _dequote's own recursive result already computed for this line.
    ">    > target" is depth 2 (confirmed via markdown-it's CommonMark
    renderer); content must be "target", not "> target", and its source
    column must land on the raw line's own "t", not one column short of
    it (the old code's start(1) pointed at the SECOND ">" itself)."""
    lines = _scan_lines(">    > target\n", {"id": "test"})
    assert [scan_line.text for scan_line in lines] == ["target"]
    assert lines[0].source_position(0) == (1, 7)


def test_indentation_relative_to_the_quote_container_cannot_interrupt() -> None:
    """CommonMark measures a block start's indentation relative to the
    CONTAINER (after the ">" prefix is stripped), not the raw physical
    line -- 4+ content spaces after the quote marker is indented-code
    territory, which cannot interrupt (or start a heading inside) an
    already-open quoted paragraph, so it lazily continues instead."""
    lines = _scan_lines("> before\n>     # after\n", {"id": "test"})
    assert len(lines) == 1
    assert lines[0].text.split() == ["before", "#", "after"]


def test_bare_atx_heading_is_recognized() -> None:
    """A "#" alone on a line, with nothing after it, is a valid (empty)
    ATX heading per CommonMark -- it must interrupt an open paragraph the
    same as "# text" does, not require trailing whitespace to recognize."""
    lines = _scan_lines("> before\n#\nafter\n", {"id": "test"})
    assert [scan_line.text for scan_line in lines] == ["before", "#", "after"]


def test_verbatim_span_cannot_cross_a_quote_depth_boundary() -> None:
    """An inline code span speculatively open across a genuine quote-depth
    change must not be allowed to swallow it -- entering a nested
    blockquote reverts an unresolved backtick to literal, so a
    verbatim-exempt marker written there is still recognized as real."""
    lines = (
        "> before `unclosed\n"
        "> > <!-- wv-quality:verbatim-start --> after\n"
        "> > <!-- wv-quality:verbatim-end --> done\n"
    ).splitlines()
    exempt = _verbatim_exempt_lines(lines)
    assert exempt == {2, 3}


def test_explicit_empty_quote_line_ends_the_paragraph() -> None:
    """A line that is only a blockquote marker ("> " alone) has non-blank
    RAW text but a blank container-relative probe -- CommonMark treats an
    empty line inside a blockquote as blank, ending the paragraph, so a
    following unmarked line cannot lazily continue across it."""
    lines = _scan_lines("> before\n>\nafter\n", {"id": "test"})
    assert [scan_line.text for scan_line in lines] == ["before", "after"]


def test_verbatim_span_cannot_cross_an_empty_quote_line() -> None:
    """An inline code span speculatively open across an empty quote line
    must not be allowed to swallow it -- the empty line is blank (a full
    boundary), so an unresolved backtick reverts to literal there, and a
    verbatim-exempt marker written after it is still recognized as real."""
    lines = "> `\n>\n<!-- wv-quality:verbatim-start -->\n`\n".splitlines()
    exempt = _verbatim_exempt_lines(lines)
    assert exempt == {3, 4}


def test_quoted_list_item_continues_across_its_own_quote_prefix() -> None:
    """A list nested inside a blockquote can have its own item paragraph
    continued by a further ">"-prefixed line at the same nesting -- this
    is the list item's own paragraph continuing, not a fresh/different
    quote interrupting it, so it stays one unit."""
    lines = _scan_lines("> 1. in order\n>    to proceed\n", {"id": "test"})
    assert [scan_line.text for scan_line in lines] == ["in order to proceed"]


def test_top_level_list_item_continues_with_no_leading_indentation() -> None:
    """CommonMark's lazy continuation applies to list items the same as it
    does to blockquotes -- a nonblank, non-interrupting line continues an
    open list-item paragraph even with zero leading indentation, not only
    when raw-indented under the marker."""
    lines = _scan_lines("- in order\nto proceed\n", {"id": "test"})
    assert [scan_line.text for scan_line in lines] == ["in order to proceed"]


def test_multiline_verbatim_span_survives_inside_a_list_item_paragraph() -> None:
    """_verbatim_exempt_lines must track 'open paragraph inside a list
    item' the same way _scan_lines does -- clearing container to "" on
    every "list" classification (instead of "list") made a lazy
    continuation line look like its own fresh boundary, splitting a
    genuine multiline inline-code span and falsely activating a marker
    that's really still inside it."""
    lines = (
        "- use `code\n"
        "  <!-- wv-quality:verbatim-start --> code`\n"
    ).splitlines()
    exempt = _verbatim_exempt_lines(lines)
    assert exempt == set()


def test_root_blockquote_ends_a_preceding_list_item_instead_of_merging() -> None:
    """A quote-marked line only continues a list item at the SAME
    quote_depth the item's own marker had -- a root-level ">" line
    (depth 1) after an unquoted item (depth 0) is a depth mismatch, a
    genuinely different container, and ends the item instead of merging
    into it as if it were ordinary continuation text."""
    lines = _scan_lines("- item\n> quote\n", {"id": "test"})
    assert [scan_line.text for scan_line in lines] == ["item", "quote"]


def test_list_item_continuation_strips_every_quote_level_it_shares() -> None:
    """A list item opened at quote_depth N continues correctly when a
    later line is ALSO at depth N -- every quote level is stripped (via
    the already-fully-dequoted probe), not just one, and the item's own
    content_col is sliced off on top of that, leaving no residual '>'
    or marker-relative indentation in the reflowed content."""
    lines = _scan_lines("> > - item\n> >   target\n", {"id": "test"})
    assert [scan_line.text for scan_line in lines] == ["item target"]


def test_empty_list_item_seeds_no_paragraph_for_a_later_line_to_continue() -> None:
    """A blank/empty list item ("-" alone) has no open paragraph -- a
    following unmarked line is a fresh, separate paragraph (not merged,
    and not indented as if continuing a nonexistent item paragraph)."""
    lines = _scan_lines("-\nvisible\n", {"id": "test"})
    assert [scan_line.text for scan_line in lines] == ["visible"]
    assert lines[0].source_position(0) == (2, 0)


def test_html_opener_as_a_list_items_own_content_starts_an_owned_block() -> None:
    """A list item's own first-line content is itself a leaf-block start
    position, checked exactly like a bare line after container markers
    (the list marker included) are stripped -- an HTML opener there
    starts a block owned by the item, suppressing its own body ("hidden")
    the same as a bare opener would, not ordinary list-paragraph text."""
    lines = _scan_lines("- <div>\n  hidden\n\nvisible\n", {"id": "test"})
    assert [scan_line.text for scan_line in lines] == ["visible"]


def test_html_block_owned_by_a_list_item_ends_when_a_sibling_item_starts() -> None:
    """Quote depth alone cannot represent a block's owning container --
    a block opened inside one list item must end when a SIBLING item
    starts (insufficient indentation for the new item's own marker),
    not stay active waiting for a blank line that may never come."""
    lines = _scan_lines("- item\n  <div>\n- visible\n", {"id": "test"})
    assert [scan_line.text for scan_line in lines] == ["item", "visible"]


def test_list_content_column_expands_tabs_to_commonmark_stops() -> None:
    """A tab in a list marker's own padding advances to the next 4-column
    tab stop, not one character -- "-\\t<div>" places content at COLUMN 4,
    not character offset 2. A 2-space continuation line (visual column 2)
    therefore does NOT meet that column, ending the HTML sub-block it
    would otherwise wrongly be absorbed into -- but the item's own
    content was consumed entirely by that block (a leaf block, not
    prose), so it never opened a paragraph or list_ctx.has_paragraph
    (see wv-580e3f); the insufficiently-indented line ends the list item
    outright and becomes an ordinary (raw-indentation-preserving) plain
    paragraph instead of a lazily-continued, left-stripped list item."""
    lines = _scan_lines("-\t<div>\n  forbidden\nvisible\n", {"id": "test"})
    assert [scan_line.text for scan_line in lines] == ["  forbidden visible"]


def test_outdented_root_html_opener_does_not_inherit_stale_list_ownership() -> None:
    """List membership is checked BEFORE it's passed into block-opener
    detection -- an unindented HTML opener right after a list item has
    already left the item (insufficient indentation), so the block it
    starts must be unowned (ends via its own terminator/blank-EOF rule,
    not the list's insufficient-indentation rule), and the list item
    itself correctly ends as its own separate unit."""
    lines = _scan_lines(
        "- item\n<script>\nforbidden\n</script>\nvisible\n", {"id": "test"}
    )
    assert [
        (scan_line.source_position(0)[0], scan_line.text) for scan_line in lines
    ] == [(1, "item"), (5, "visible")]


def test_outdented_type7_opener_stays_a_lazy_continuation_not_a_block() -> None:
    """CORRECTED (wv-1ccd09, external code review finding 1): this test's
    own ORIGINAL premise was itself wrong -- "an outdented '<span>' no
    longer belongs to the list item, so it must be evaluated as if
    nothing were open" conflated STRUCTURAL container-popping with
    PARAGRAPH-open state. CommonMark's own rule for type 7 ("may not
    interrupt a paragraph") is about the PARAGRAPH, not the container:
    once "item"'s paragraph is open, an insufficiently-indented "<span>"
    is a LAZY CONTINUATION of it regardless of the list item's own
    structural indentation requirement no longer being met -- laziness
    is exactly what lets an unmarked line continue an open paragraph
    with NO indentation at all. Since type 7 is excluded from the small
    set of constructs CommonMark actually lets interrupt a paragraph
    (thematic break, ATX heading, fenced code, HTML types 1-6, an
    eligible list marker), "<span>" never gets a chance to open a fresh
    block here -- it, and "forbidden" after it, are simply MORE text in
    the SAME already-open paragraph, all the way until something that
    genuinely interrupts (or a blank line) appears."""
    lines = _scan_lines("- item\n<span>\nforbidden\n", {"id": "test"})
    assert [scan_line.text for scan_line in lines] == ["item <span> forbidden"]


def test_outdented_root_html_opener_inside_a_blockquote_ends_a_nested_list() -> None:
    """The same stale-ownership defect reproduces inside a blockquote: a
    line can remain at the SAME quote depth as the list yet still have
    outdented from the list's own indentation -- quote depth alone
    doesn't establish list membership, only content_col does."""
    lines = _scan_lines(
        "> - item\n> <script>\n> forbidden\n> </script>\n> visible\n", {"id": "test"}
    )
    assert [
        (scan_line.source_position(0)[0], scan_line.text) for scan_line in lines
    ] == [(1, "item"), (5, "visible")]


def test_line_scope_suppresses_list_owned_html_content() -> None:
    """match_scope: line rules must skip HTML content owned by a list
    item's own first-line opener, the same as paragraph scope does --
    _scan_lines_raw needs its own _ListItemContext tracking, not just
    fence-in-code awareness, to know the block is list-owned at all."""
    lines = _scan_lines(
        "- <!--\n  forbidden\n  -->\nvisible\n", {"id": "test", "match_scope": "line"}
    )
    assert [(scan_line.source_position(0)[0], scan_line.text) for scan_line in lines] == [
        (4, "visible")
    ]


def test_directive_inside_list_owned_html_is_not_a_real_marker() -> None:
    """_verbatim_exempt_lines needs the same list-item tracking _scan_lines
    has -- a wv-quality directive written inside HTML content owned by a
    list item's own opener is still just raw HTML content, not an active
    marker, and must not exempt anything through EOF."""
    text = "- <script>\n  <!-- wv-quality:verbatim-start -->\n  </script>\nvisible\n"
    assert _verbatim_exempt_lines(text.splitlines()) == set()
    lines = _scan_lines(text, {"id": "test"})
    assert [(scan_line.source_position(0)[0], scan_line.text) for scan_line in lines] == [
        (4, "visible")
    ]


def test_fence_in_a_list_items_own_content_starts_an_owned_block() -> None:
    """The list-opener leaf-block check must also try a fence opener, not
    just HTML -- reusing the shared fence/HTML arbitration
    (_advance_block_states) rather than a narrower HTML-only helper."""
    lines = _scan_lines("- ```\n  hidden\n  ```\nvisible\n", {"id": "test"})
    assert [scan_line.text for scan_line in lines] == ["visible"]


def test_verbatim_marker_inside_a_list_owned_fence_is_not_a_real_directive() -> None:
    """The same fence-in-list-content fix must apply to inline-mask
    tracking too -- a marker inside a list-owned fence is masked, the
    same as one inside any other fenced code."""
    text = "- ```\n  <!-- wv-quality:verbatim-start -->\n  ```\nvisible\n"
    assert _verbatim_exempt_lines(text.splitlines()) == set()


def test_list_item_content_that_opens_a_leaf_block_has_no_open_paragraph() -> None:
    """A leaf block (fence/HTML, including a one-line self-closing one)
    does not create an open paragraph -- an insufficiently-indented
    following line has no item paragraph to lazily continue, so it ends
    the item outright and becomes an ordinary plain paragraph (raw
    indentation preserved), not a left-stripped list continuation."""
    lines = _scan_lines("- <!-- x -->\n visible\n", {"id": "test"})
    assert len(lines) == 1
    assert lines[0].text == " visible"
    assert lines[0].source_position(0) == (2, 0)


def test_list_tab_stops_stay_absolute_across_a_stripped_quote_prefix() -> None:
    """CommonMark tab stops are absolute across the physical line -- they
    do not restart at zero where a blockquote prefix was stripped. "> -"
    puts the marker at physical column 2; a tab right after it reaches
    physical column 4 (only 1 column short of the next stop), so the
    item's OWN container-relative content_col is 2 (4 minus the "> "
    prefix's own 2-column width), not 4 as a probe-relative-from-zero
    computation would give. A 2-space continuation line meets exactly
    that column and merges into the item's own paragraph."""
    lines = _scan_lines("> -\titem\n>   continuation\n", {"id": "test"})
    assert [scan_line.text for scan_line in lines] == ["item continuation"]


def test_list_tab_stops_stay_absolute_for_html_ownership_too() -> None:
    """The same absolute-tab-stop fix applies to HTML block ownership --
    a wrong (probe-relative) content_col would misjudge whether the
    block's own body lines are sufficiently indented to still belong to
    the item, either wrongly ending it early or wrongly keeping content
    (and a directive inside it) suppressed past where it should end."""
    text = (
        "> -\t<script>\n"
        ">   <!-- wv-quality:verbatim-start -->\n"
        ">   </script>\n"
        "> visible\n"
    )
    assert _verbatim_exempt_lines(text.splitlines()) == set()
    lines = _scan_lines(text, {"id": "test"})
    assert [scan_line.text for scan_line in lines] == ["visible"]


def test_raw_scope_nested_list_marker_clears_the_surviving_parents_paragraph() -> None:
    """wv-ac22a5 finding 5 (external code review) fixed a stale
    has_paragraph=True on the SURVIVING PARENT ("outer") once a nested
    item opens -- correct as far as it went, but wv-1ccd09 round 2
    (external code review, finding 2) found a DEEPER reason "<span>"
    must NOT open as its own HTML block here: "inner" (the just-POPPED
    innermost item, content_col 4) still has its OWN open paragraph
    ("inner" itself, its first line) when "  <span>" (only 2 columns)
    arrives -- CommonMark laziness protects that paragraph regardless of
    which ancestor's indentation the line satisfies (verified against
    markdown-it: "<span>"/"after" render as literal continuation text of
    "inner"'s own paragraph, never as a block). This test's own premise
    was wrong until wv-1ccd09 round 2 -- "<span>" stays ordinary
    (unconsumed) lazy text in line scope, exactly like every other raw
    source line, not a suppressed HTML block."""
    text = "- outer\n  - inner\n  <span>\n  after\n"
    lines = _scan_lines(text, {"id": "test", "match_scope": "line"})
    assert [(scan_line.source_position(0)[0], scan_line.text) for scan_line in lines] == [
        (1, "- outer"),
        (2, "  - inner"),
        (3, "  <span>"),
        (4, "  after"),
    ]


def test_verbatim_nested_list_marker_clears_the_surviving_parents_paragraph() -> None:
    """The same wv-1ccd09 round 2 correction applies to inline-mask/
    verbatim tracking (see test_raw_scope_nested_list_marker_clears_the_
    surviving_parents_paragraph's updated docstring for the full
    reasoning): "<span>" is protected by "inner"'s own still-open
    paragraph and never opens as a real HTML block, so the
    "<!-- wv-quality:verbatim-start -->" marker on the next line IS a
    genuine, activating directive -- not inert content of a foreign
    tag -- exempting itself and the "hidden" line that follows it."""
    text = "- outer\n  - inner\n  <span>\n  <!-- wv-quality:verbatim-start -->\n  hidden\n"
    assert _verbatim_exempt_lines(text.splitlines()) == {4, 5}


def test_raw_scope_item_owned_code_preserves_ownership_for_a_later_block() -> None:
    """wv-ac22a5 finding 6 (external code review), exercised through
    match_scope: line: _scan_lines_raw had NO dedicated "code" dispatch
    at all -- kind == "code" fell into the generic unowned-clearing
    branch regardless of whether a list item actually owned the line,
    so a later item-owned HTML block became falsely root-owned with no
    indentation-based ending, silently swallowing every remaining line
    through EOF instead of ending cleanly at the next sibling. Confirmed
    against pre-fix behavior: lines 4-7 (the div's own content, plus
    "sibling"/"more" entirely) vanished from the output; correctly
    preserved, only the div's own (suppressed) content is missing."""
    text = "- first\n\n      hidden\n  <div>\n  visible-inside\n- sibling\n  more\n"
    lines = _scan_lines(text, {"id": "test", "match_scope": "line"})
    assert [scan_line.source_position(0)[0] for scan_line in lines] == [1, 2, 3, 6, 7]


def test_verbatim_item_owned_code_preserves_ownership_for_a_later_block() -> None:
    """The same finding-6 fix applies to _verbatim_container_transition.
    "first"'s own content_col is 2; a 4-space-indented marker line right
    after the item-relative code line is only 2 columns relative to a
    correctly-preserved item (an ordinary lazy continuation, examined
    for the marker) but reads as a full 4 columns -- indented code -- if
    list_stack was wrongly cleared to root by the "code" dispatch
    (unowned "code"-kind lines are never examined for the marker at
    all, per test_owned_paragraphless_lazy_line_activates_a_verbatim_marker's
    identical reasoning). Confirmed against pre-fix behavior: the marker
    was wrongly inert (exempt == set()); correctly recognized, it
    activates through EOF."""
    text = "- first\n\n      hidden\n    <!-- wv-quality:verbatim-start -->\n    visible\n"
    assert _verbatim_exempt_lines(text.splitlines()) == {4, 5}


def test_raw_scope_unowned_indented_code_still_clears_the_stack() -> None:
    """Regression guard for the finding-6 fix: indented code that is
    genuinely NOT item-relative (past the blank line ending the item's
    own last paragraph, and not reachable by any surviving item's own
    content_col) must still end the list outright, the same as before
    the fix -- the new "code" branch only preserves ownership, it must
    never manufacture it."""
    text = "- item\n\nnot item-relative, just a paragraph:\n\n    code\nafter\n"
    lines = _scan_lines(text, {"id": "test", "match_scope": "line"})
    assert [scan_line.text for scan_line in lines] == [
        "- item",
        "",
        "not item-relative, just a paragraph:",
        "",
        "    code",
        "after",
    ]


def test_tab_immediately_after_a_quote_marker_leaves_residual_indentation() -> None:
    """A tab right after ">" expands to the next 4-column tab stop --
    physical column 1 to column 4, a 3-column span. Only the FIRST of
    those columns belongs to the quote marker's own optional whitespace;
    the other 2 stay as the quote's own content indentation. Combined
    with 2 further literal spaces, "hidden" sits at 4 columns of
    container-relative indentation -- indented code, dropped entirely --
    leaving "visible" as the only reflowed paragraph. A prior version
    consumed the whole tab as the marker's own whitespace (losing the
    residual columns), misclassifying "hidden" as ordinary quote
    continuation text that "visible" then lazily merged into."""
    lines = _scan_lines(">\t  hidden\nvisible\n", {"id": "test"})
    assert [scan_line.text for scan_line in lines] == ["visible"]


def test_directive_after_a_tab_residual_indented_code_line_is_real() -> None:
    """Same fix, exercised through the verbatim-marker path: a directive
    on the line after tab-residual indented code is a genuine marker
    (the indented-code line itself was never real prose to hide inside
    of)."""
    text = ">\t  hidden\n<!-- wv-quality:verbatim-start -->\nvisible\n"
    assert _verbatim_exempt_lines(text.splitlines()) == {2, 3}


def test_blank_line_inside_a_list_item_preserves_ownership_for_a_later_block() -> None:
    """A blank line ends the item's CURRENT paragraph, not the item
    itself -- a later sufficiently-indented block (here, an HTML opener)
    still belongs to it, and a sibling marker still correctly ends both
    the block and the item once it actually appears."""
    lines = _scan_lines("- item\n\n  <div>\n  hidden\n- visible\n", {"id": "test"})
    assert [scan_line.text for scan_line in lines] == ["item", "visible"]


def test_blank_line_preserved_ownership_works_for_line_scope_too() -> None:
    """The same blank-preserves-ownership fix applies to match_scope: line
    -- line 5 (the sibling marker) must not be swallowed as if it were
    still inside the (already blank-interrupted, then re-owned) block."""
    lines = _scan_lines(
        "- item\n\n  <div>\n  hidden\n- visible\n", {"id": "test", "match_scope": "line"}
    )
    assert [(scan_line.source_position(0)[0], scan_line.text) for scan_line in lines] == [
        (1, "- item"),
        (2, ""),
        (5, "- visible"),
    ]


def test_blank_line_preserved_ownership_for_directive_masking_too() -> None:
    """The same fix applies to inline-mask tracking -- a directive on the
    SIBLING item (after the blank-interrupted, list-owned block ends) is
    a real marker, not swallowed as if still inside that block."""
    text = "- item\n\n  <div>\n  hidden\n- <!-- wv-quality:verbatim-start -->\nvisible\n"
    assert _verbatim_exempt_lines(text.splitlines()) == {5, 6}


def test_nested_list_reattaches_to_outer_item_once_the_inner_list_ends() -> None:
    """A single scalar list_ctx can only remember the INNERMOST item --
    once "- inner" replaces "- outer" wholesale, "<div>" (indented just
    enough for "outer", not "inner") has no container left to belong to
    at all. The list-context STACK fixes this: popping "inner" (it
    doesn't own a 2-space-indented line) leaves "outer" still on the
    stack underneath, sufficiently indented to reclaim the block."""
    text = "- outer\n  - inner\n\n  <div>\n  hidden\n- visible\n"
    lines = _scan_lines(text, {"id": "test"})
    assert [scan_line.text for scan_line in lines] == ["outer", "inner", "visible"]


def test_nested_list_reattachment_works_for_line_scope_too() -> None:
    """The same outer-item reattachment applies to match_scope: line --
    the owned HTML block's lines (4-5) are dropped, and the sibling
    marker (6) survives as its own line, not swallowed as leftover
    "inner" or block content."""
    text = "- outer\n  - inner\n\n  <div>\n  hidden\n- visible\n"
    lines = _scan_lines(text, {"id": "test", "match_scope": "line"})
    assert [(scan_line.source_position(0)[0], scan_line.text) for scan_line in lines] == [
        (1, "- outer"),
        (2, "  - inner"),
        (3, ""),
        (6, "- visible"),
    ]


def test_nested_list_reattachment_for_directive_masking_too() -> None:
    """The same fix applies to inline-mask tracking -- a directive
    written as the outer item's own reclaimed block content (line 4,
    only 2-space indented -- short of "inner"'s own content_col but not
    "outer"'s) is a real marker, exempting through EOF since it has no
    matching end marker."""
    text = "- outer\n  - inner\n\n  <!-- wv-quality:verbatim-start -->\n  hidden\n- visible\n"
    assert _verbatim_exempt_lines(text.splitlines()) == {4, 5, 6}


def test_indented_line_reclassifies_from_lazy_to_code_once_its_item_ends() -> None:
    """A line failing list-item continuation must be reclassified fresh
    under the container it actually ends up in, not left as whatever
    kind ("lazy") was computed under the container BEFORE the failure
    was discovered. "    hidden" is 4-space indented -- classified
    "lazy" only because a list was still open (container == "list");
    once that ownership check fails and nothing is left open at all,
    the SAME line is genuine indented code (container == ""), which
    must be dropped, not reflowed as if it had lazily continued a
    paragraph that was never actually open (the item's own paragraph
    already ended via the blank line before it)."""
    text = "123456789. item\n\n    hidden\nvisible\n"
    lines = _scan_lines(text, {"id": "test"})
    assert [scan_line.text for scan_line in lines] == ["item", "visible"]


def test_reclassification_pops_only_the_failing_item_not_every_ancestor() -> None:
    """The same reclassify-after-pop fix must retry against a SURVIVING
    outer ancestor, not wipe the whole stack the instant the innermost
    item's own continuation fails. "outer" has an open paragraph; "-"
    nested under it is a blank item with none; "    hidden" is indented
    enough to structurally belong to the blank inner item.

    DELIBERATE behavior change from this test's original assertion
    (["outer"], dropping "hidden" as indented code): per CommonMark
    0.31.2, the bare "-" under "outer" is actually a level-2 setext
    heading underline for "outer", not a nested empty list item at all
    (this scanner has no setext support, so it doesn't reproduce that
    parse), and "hidden" is matchable prose either way -- it must not
    be silently dropped. wv-9d8474 fixes exactly this: "hidden" is
    indentation-owned by the (here, empty) inner item, so it starts
    that item's own fresh paragraph instead of being treated as the
    item having ended, and it survives as its own reflowed unit rather
    than being corrupted into "outer"'s paragraph or dropped as code.
    See test_owned_paragraphless_lazy_line_with_unambiguous_nested_item
    for the same fix exercised via a marker ("*") CommonMark can't
    read as a setext underline, isolating the fix from that ambiguity."""
    text = "- outer\n  -\n    hidden\n"
    lines = _scan_lines(text, {"id": "test"})
    assert [scan_line.text for scan_line in lines] == ["outer", "hidden"]


def test_reclassification_works_for_line_scope_too() -> None:
    """The same reclassify-after-pop fix applies to match_scope: line --
    unlike the paragraph path, raw mode still emits every line
    regardless of kind, but its container/list_stack bookkeeping must
    stay correct so a LATER line's fence/HTML ownership isn't computed
    against a stale, already-ended item."""
    text = "123456789. item\n\n    hidden\nvisible\n"
    lines = _scan_lines(text, {"id": "test", "match_scope": "line"})
    assert [(scan_line.source_position(0)[0], scan_line.text) for scan_line in lines] == [
        (1, "123456789. item"),
        (2, ""),
        (3, "    hidden"),
        (4, "visible"),
    ]


def test_owned_paragraphless_lazy_line_starts_fresh_paragraph_after_blank() -> None:
    """wv-9d8474: a lazy continuation line that IS indentation-owned by
    the open item but has no currently open paragraph to continue
    (has_paragraph False, here because a blank line just cleared it)
    must start a FRESH paragraph within the same item, not be dropped
    as indented code or wrongly reflowed with its literal indentation
    still attached (the old has_paragraph gate popped the item entirely
    here, so "second" fell through to the generic plain-paragraph lazy
    path, which keeps quote_depth==0 text raw/unstripped)."""
    text = "- first\n\n  second\n"
    lines = _scan_lines(text, {"id": "test"})
    assert [scan_line.text for scan_line in lines] == ["first", "second"]


def test_owned_paragraphless_lazy_line_survives_across_a_list_owned_html_block() -> None:
    """The same fix must hold once the item's own fresh paragraph is
    itself interrupted by a list-owned HTML block: "second" opens a
    fresh paragraph after the blank line, the block then closes it
    again (list-owned leaf blocks already clear has_paragraph, see
    _open_list_item), and "visible" opens a new sibling item entirely.
    "hidden" (opaque HTML content) never reaches the scanner at all."""
    text = "- first\n\n  second\n\n  <div>\n  hidden\n- visible\n"
    lines = _scan_lines(text, {"id": "test"})
    assert [scan_line.text for scan_line in lines] == ["first", "second", "visible"]


def test_owned_paragraphless_lazy_line_with_unambiguous_nested_item() -> None:
    """Same shape as
    test_reclassification_pops_only_the_failing_item_not_every_ancestor,
    but nested under "*" instead of "-" -- per the CommonMark spec, a
    bare "-" under an open paragraph deterministically forms a setext
    heading underline, not an empty nested item (the ambiguity is only
    in THIS SCANNER's own simplified model, which has no setext support
    at all), so "*" isolates this fix from that scanner-model gap
    entirely -- a bare "*" has no setext-underline reading in CommonMark
    either: "hidden" is indentation-owned by the empty inner "*" item
    and opens its own fresh paragraph, the same as the "-" case."""
    text = "- outer\n  *\n    hidden\n"
    lines = _scan_lines(text, {"id": "test"})
    assert [scan_line.text for scan_line in lines] == ["outer", "hidden"]


def test_owned_paragraphless_lazy_line_works_for_line_scope_too() -> None:
    """The same fix applies to match_scope: line -- raw mode already
    emits "second" either way (it never drops based on kind), so the
    observable difference is downstream: under the old has_paragraph
    gate, the item was wrongly popped entirely at "second", so by the
    time "<div>" opened it was no longer attributed to the item
    (list_content_col=None) and the type-6 HTML block had no owning
    item left to end it -- it would only end at a blank line or EOF,
    wrongly swallowing "- visible" too. With the fix, the item survives
    through "second", so the block is correctly recognized as
    list-owned and ends the moment "- visible" is no longer indented
    enough to belong to it (see _HtmlBlockState.list_content_col)."""
    text = "- first\n\n  second\n\n  <div>\n  hidden\n- visible\n"
    lines = _scan_lines(text, {"id": "test", "match_scope": "line"})
    assert [(scan_line.source_position(0)[0], scan_line.text) for scan_line in lines] == [
        (1, "- first"),
        (2, ""),
        (3, "  second"),
        (4, ""),
        (7, "- visible"),
    ]


def test_owned_paragraphless_lazy_line_activates_a_verbatim_marker() -> None:
    """The same fix applies to inline-mask/verbatim-marker tracking: a
    verbatim-start marker written on an owned-but-paragraph-less lazy
    line (here, the empty nested item's own first continuation) must
    still be recognized. Under the old has_paragraph gate this line
    reclassified all the way down to "code" (once the whole list_stack
    was wrongly popped), and "code"-kind lines are never examined for
    the marker at all unless a region is ALREADY active -- so the
    marker could never activate. ("prefix " keeps each marker line from
    also being read as its own HTML-comment block opener, isolating
    this from _item_relative_view/wv-ef574e entirely.)"""
    text = (
        "- outer\n"
        "  -\n"
        "    prefix <!-- wv-quality:verbatim-start -->\n"
        "    hidden\n"
        "    prefix <!-- wv-quality:verbatim-end -->\n"
        "- visible\n"
    )
    assert _verbatim_exempt_lines(text.splitlines()) == {3, 4, 5}


def test_reclassification_for_directive_masking_too() -> None:
    """The same reclassify-after-pop fix applies to inline-mask
    tracking -- a directive written on a line that reclassifies from
    "lazy" to "code" once its list item ends must be treated as inert
    code content (never examined for the marker at all), not as a real
    directive merely because the container was still "list" when its
    kind was first (wrongly) computed."""
    text = "123456789. item\n\n    <!-- wv-quality:verbatim-start -->\nvisible\n"
    assert _verbatim_exempt_lines(text.splitlines()) == set()


def test_item_owned_html_opener_recognized_on_a_continuation_line() -> None:
    """A list-owned CONTINUATION line's own leaf-block opener must be
    checked relative to the ITEM's margin, not the bare quote-relative
    probe: "    <div>" is 4-space indented, exactly at a "10. " item's
    own content_col -- 0 columns relative to the item, but 4 raw
    columns from probe's own zero point, which alone would exceed
    CommonMark's "<=3 leading spaces" leaf-block-open requirement and
    leave the opener unrecognized, wrongly merging it into the item's
    paragraph text instead of opening an opaque HTML block."""
    text = "10. item\n    <div>\n    hidden\n- visible\n"
    lines = _scan_lines(text, {"id": "test"})
    assert [scan_line.text for scan_line in lines] == ["item", "visible"]


def test_item_owned_html_opener_works_for_line_scope_too() -> None:
    """The same item-relative opener fix applies to match_scope: line --
    the owned HTML block's lines (2-3) are dropped."""
    text = "10. item\n    <div>\n    hidden\n- visible\n"
    lines = _scan_lines(text, {"id": "test", "match_scope": "line"})
    assert [(scan_line.source_position(0)[0], scan_line.text) for scan_line in lines] == [
        (1, "10. item"),
        (4, "- visible"),
    ]


def test_item_owned_html_opener_for_directive_masking_too() -> None:
    """The same item-relative opener fix applies to inline-mask
    tracking -- a directive that WOULD open a type-2-shaped HTML
    comment is deliberately exempted from HTML-block recognition (see
    _try_open_html_block), so it's examined as ordinary text instead
    and activates normally; the item-relative fix is what lets this
    continuation line be examined as list content at all instead of
    being merged as raw lazy text."""
    text = "10. item\n    <!-- wv-quality:verbatim-start -->\n    hidden\n- visible\n"
    assert _verbatim_exempt_lines(text.splitlines()) == {2, 3, 4}


def test_item_owned_fence_closer_recognized_at_the_items_own_margin() -> None:
    """A list-owned fence's CLOSING marker must also be checked relative
    to the item's margin: "    ```" (4-space indent, matching a "10. "
    item's own content_col) is a valid 0-relative closer, but without
    the item-relative view it looks like 4 raw leading spaces from
    probe's own zero point -- exceeding "<=3" and leaving the fence
    open through EOF (or until an unrelated later outdent), swallowing
    unrelated content after it as more fenced text. A directive placed
    right after the intended close proves whether it actually closed
    there: examined (real) only if the closer was recognized."""
    text = "10. ```\n    hidden\n    ```\n    <!-- wv-quality:verbatim-start -->\nvisible\n"
    assert _verbatim_exempt_lines(text.splitlines()) == {4, 5}


def test_item_owned_fence_closer_recognized_with_a_wider_marker() -> None:
    """wv-ef574e's own repro: a list-owned fence's closing marker need
    not repeat the opener's exact char count -- CommonMark only requires
    the closer's run to be AT LEAST as long, using the same char -- and
    the item-relative view (not a bare quote-relative probe) is what
    lets a WIDER closer ("~~~~", 4 tildes) still be recognized at the
    item's own margin against a narrower opener ("~~~", 3 tildes) opened
    directly on the "10. " marker line: content_col is 4, and the closer
    here sits at exactly that 0-relative column. Once the fence closes,
    "visible" (indentation-owned but paragraph-less, see wv-9d8474)
    starts a fresh paragraph within the SAME item, and "- sibling" opens
    an unrelated sibling item -- proving the fence actually closed
    rather than swallowing both as more fenced content through EOF."""
    text = "10. ~~~\n    hidden\n    ~~~~\n    visible\n- sibling\n"
    lines = _scan_lines(text, {"id": "test"})
    assert [scan_line.text for scan_line in lines] == ["visible", "sibling"]


def test_item_owned_fence_closer_with_a_wider_marker_works_for_line_scope_too() -> None:
    """The same wider-marker item-relative closer fix applies to
    match_scope: line -- the fenced lines (1-3) are dropped, and the two
    surviving physical lines are attributed to their real source rows."""
    text = "10. ~~~\n    hidden\n    ~~~~\n    visible\n- sibling\n"
    lines = _scan_lines(text, {"id": "test", "match_scope": "line"})
    assert [(scan_line.source_position(0)[0], scan_line.text) for scan_line in lines] == [
        (4, "    visible"),
        (5, "- sibling"),
    ]


def test_item_owned_fence_closer_with_a_wider_marker_for_directive_masking_too() -> None:
    """The same wider-marker item-relative closer fix applies to
    inline-mask tracking -- a directive placed right after the wider
    closer is a genuine marker only if the fence actually closed there,
    same proof strategy as
    test_item_owned_fence_closer_recognized_at_the_items_own_margin."""
    text = "10. ~~~\n    hidden\n    ~~~~\n    <!-- wv-quality:verbatim-start -->\nvisible\n"
    assert _verbatim_exempt_lines(text.splitlines()) == {4, 5}


def test_item_relative_indented_code_is_dropped_not_lazily_reflowed() -> None:
    """wv-5ef426 finding 1: content indented 4+ COLUMNS BEYOND an owning
    item's own margin (6 raw spaces here, 4 relative to "- "'s content_col
    of 2), with no paragraph currently open in the item to protect it
    (the blank line closed it), is genuine indented code -- CommonMark:
    indentation can START a code block, but never interrupts an
    already-open paragraph. _paragraph_interrupt_kind's leading-space
    check used to gate "code" on container == "" alone, so ANY list-owned
    line (container == "list") fell through to "lazy" regardless of how
    deeply indented, exposing "hidden" as ordinary matchable prose
    instead of excluding it the same way root-level indented code
    already is."""
    lines = _scan_lines("- first\n\n      hidden\n- sibling\n", {"id": "test"})
    assert [scan_line.text for scan_line in lines] == ["first", "sibling"]


def test_item_relative_indented_code_for_directive_masking_too() -> None:
    """The same item-relative code fix applies to inline-mask tracking --
    a directive written on an item-relative indented-code line is inert
    code content, never examined for the marker at all (unlike a "lazy"
    line, which IS examined)."""
    text = "- first\n\n      <!-- wv-quality:verbatim-start -->\n- sibling\n"
    assert _verbatim_exempt_lines(text.splitlines()) == set()


def test_item_owned_type7_html_recognized_after_an_open_paragraph_closes() -> None:
    """wv-5ef426 finding 2: HTML type 7 (a bare, complete open/close tag)
    still tested the raw quote-relative `probe` and hard-required
    container == "" in _try_open_html_block, unlike types 1-6 (which
    already used opener_probe correctly) -- so a paragraph-less
    list-owned continuation line (the blank line closed "first"'s own
    paragraph) could never open one: "<span>" is not one of the type-6
    block-level tags, so it falls through to type 7's own bare-tag
    check, item-relative 0-3 columns within the "10. " item (content_col
    4) -- 4 raw columns from probe's own zero point otherwise, wrongly
    exceeding "<=3" and leaving "<span> hidden" exposed as prose."""
    lines = _scan_lines("10. first\n\n    <span>\n    hidden\n- sibling\n", {"id": "test"})
    assert [scan_line.text for scan_line in lines] == ["first", "sibling"]


def test_item_owned_type7_html_works_for_line_scope_too() -> None:
    """The same item-relative type-7 fix applies to match_scope: line --
    the owned HTML block's lines (3-4) are dropped."""
    text = "10. first\n\n    <span>\n    hidden\n- sibling\n"
    lines = _scan_lines(text, {"id": "test", "match_scope": "line"})
    assert [(scan_line.source_position(0)[0], scan_line.text) for scan_line in lines] == [
        (1, "10. first"),
        (2, ""),
        (5, "- sibling"),
    ]


def test_item_owned_type7_html_for_directive_masking_too() -> None:
    """The same item-relative type-7 fix applies to inline-mask tracking
    -- a directive placed right after the item-owned block ends (at the
    sibling item) is a genuine marker only if the block actually opened
    and later closed there, same proof strategy as the fence/HTML-6
    tests above."""
    text = "10. first\n\n    <span>\n    hidden\n- <!-- wv-quality:verbatim-start -->\nvisible\n"
    assert _verbatim_exempt_lines(text.splitlines()) == {5, 6}


def test_type7_veto_survives_a_pop_via_pending_reattachment() -> None:
    """wv-1ccd09 (external code review finding 1): _pop_unowned_list_frames
    pops "before"'s item (0 columns, insufficient for content_col=2)
    BEFORE block detection runs -- the OLD type-7 gate only saw the
    POST-pop container=="" state and wrongly treated that as "nothing
    open", letting "<span>" open a fresh (and wrong) HTML block that
    then swallowed "after" as its own content. CommonMark: type 7 may
    never interrupt a paragraph, and "before"'s own paragraph is still
    laziness-protected at this exact point (see
    _reattach_lazy_owner_if_dropped, which _no_open_paragraph_to_protect
    mirrors) -- "<span>" and "after" must lazily continue it as ordinary
    text instead, and "- sibling" (a genuine list marker, which CAN
    interrupt a paragraph) correctly starts a fresh item afterward."""
    lines = _scan_lines("- before\n<span>\nafter\n- sibling\n", {"id": "test"})
    assert [scan_line.text for scan_line in lines] == ["before <span> after", "sibling"]


def test_type7_veto_survives_a_pop_for_line_scope_too() -> None:
    """The same pending-reattachment fix applies to match_scope: line --
    since "<span>" never actually opens as a block, none of these lines
    are opaque content to drop; all four survive unreflowed."""
    text = "- before\n<span>\nafter\n- sibling\n"
    lines = _scan_lines(text, {"id": "test", "match_scope": "line"})
    assert [(scan_line.source_position(0)[0], scan_line.text) for scan_line in lines] == [
        (1, "- before"),
        (2, "<span>"),
        (3, "after"),
        (4, "- sibling"),
    ]


def test_partial_pop_reattaches_the_popped_items_own_paragraph() -> None:
    """wv-a7a166 round 2 (external code review finding 1): "inner"'s own
    item (content_col 4) is popped when "  after" (2 columns) fails its
    membership check, but OUTER (content_col 2) survives -- a PARTIAL
    pop. "after" is still a genuine CommonMark lazy continuation of
    "inner"'s own already-open paragraph -- laziness protects the
    DEEPEST open paragraph regardless of which ancestor's own
    indentation the line happens to satisfy (verified against
    markdown-it: "inner"/"inner text"/"after" render as one single
    paragraph). wv-a7a166's OWN original fix (d46faea3) got this
    backwards: it eagerly flushed the popped item's paragraph before
    `kind` was even known, encoding its own bug's unfixed 4-unit output
    as "expected" -- must reflow as 3 distinct blocks, "after" merged
    into "inner"'s own paragraph, not the surviving OUTER item's."""
    text = "- outer\n  - inner\n    inner text\n  after\n- sibling\n"
    lines = _scan_lines(text, {"id": "test"})
    assert [scan_line.text for scan_line in lines] == [
        "outer",
        "inner inner text after",
        "sibling",
    ]


def test_partial_pop_flush_does_not_disturb_the_fully_emptied_case() -> None:
    """The partial-pop flush must stay scoped to "some ancestor
    survives" -- when NOTHING survives the pop (list_stack fully
    empties), _reattach_lazy_owner_if_dropped is the one that decides
    whether the popped item's own paragraph gets reattached (continuing
    it) or genuinely ends; flushing unconditionally here would pre-empt
    that and wrongly split an otherwise-legal lazy continuation. Same
    repro wv-5ef426 finding 3 already covers, re-asserted here as a
    regression guard against widening finding 2's own fix too far."""
    lines = _scan_lines("- first\nsecond\n- sibling\n", {"id": "test"})
    assert [scan_line.text for scan_line in lines] == ["first second", "sibling"]


def test_legal_unindented_lazy_continuation_reattaches_its_popped_item() -> None:
    """wv-5ef426 finding 3: _pop_unowned_list_frames pops a list-item
    frame purely on indentation, BEFORE `kind` is known -- correct for
    structural/opener purposes, but wrong for a genuinely lazy
    (unmarked, non-interrupting) continuation line: CommonMark laziness
    lets such a line continue an item's ALREADY-OPEN paragraph
    regardless of its own indentation. "second" (column 0, item
    content_col 2) used to permanently pop and discard "first"'s
    _ListItemContext instead of merging into its open paragraph -- see
    the next test for the further consequence (a LATER line's own
    item-relative recognition, with nothing left to reattach to)."""
    lines = _scan_lines("- first\nsecond\n- sibling\n", {"id": "test"})
    assert [scan_line.text for scan_line in lines] == ["first second", "sibling"]


def test_reattached_item_still_recognizes_its_own_owned_html_block() -> None:
    """The reattached item's own margin must still govern a LATER line's
    item-relative HTML-block recognition -- without reattachment,
    "<div>" opens as an UNOWNED (root-relative, list_content_col=None)
    block instead: still recognized here only by coincidence (2 raw
    columns happens to satisfy the root "<=3" rule too), but with no
    owning content_col to end it via indentation, it swallows
    "- sibling" and "  more" as more opaque HTML content all the way to
    EOF instead of correctly ending where the sibling item starts."""
    text = "- first\nsecond\n  <div>\n  hidden\n- sibling\n  more\n"
    lines = _scan_lines(text, {"id": "test", "match_scope": "line"})
    assert [(scan_line.source_position(0)[0], scan_line.text) for scan_line in lines] == [
        (1, "- first"),
        (2, "second"),
        (5, "- sibling"),
        (6, "  more"),
    ]


def test_reattached_item_owned_block_for_directive_masking_too() -> None:
    """The same reattachment fix applies to inline-mask tracking -- a
    directive placed right after the reattached item's own owned HTML
    block ends (at the sibling item) is a genuine marker only if the
    block was recognized as item-owned (and so correctly ended there)
    in the first place."""
    text = "- first\nsecond\n  <div>\n  hidden\n- <!-- wv-quality:verbatim-start -->\nvisible\n"
    assert _verbatim_exempt_lines(text.splitlines()) == {5, 6}


def test_quote_tab_residual_recognizes_a_nested_list_marker() -> None:
    """wv-98984a: a partially-consumed blockquote tab leaves a literal
    tab character in `probe` (_dequote can't split it mid-character),
    but the structural regexes (_MARKDOWN_LIST_RE included) only ever
    recognize LITERAL leading spaces -- so the RESIDUAL visual columns
    that same tab still represents beyond the quote marker's own
    consumption (_dequote's virtual_offset) never materialize as
    recognizable indentation, and a marker genuinely valid at 0-3
    residual columns goes unrecognized entirely: ">\\t- item" -- the
    tab's own visual width from its own physical column is 3, 1 of
    which belongs to the quote marker, leaving 2 residual columns
    before "- item", well within CommonMark's "<=3" allowance."""
    lines = _scan_lines(">\t- item\n", {"id": "test"})
    assert [scan_line.text for scan_line in lines] == ["item"]


def test_quote_tab_residual_source_position_stays_on_raw_characters() -> None:
    """The materialized view exists ONLY for regex recognition -- source
    positions must still point at the REAL character offset in the raw
    line, not at some position within the (possibly longer, since one
    tab character can become up to 3 space characters) materialized
    string _open_list_item's structural_delta parameter translates
    away."""
    text = ">\t- item\n"
    lines = _scan_lines(text, {"id": "test"})
    lineno, col = lines[0].source_position(0)[0], lines[0].source_position(0)[1]
    assert (lineno, col) == (1, 4)
    assert text.splitlines()[lineno - 1][col : col + len(lines[0].text)] == "item"


def test_quote_tab_residual_works_for_line_scope_too() -> None:
    """The same quote-tab-residual fix applies to match_scope: line --
    the raw physical line survives unreflowed, same as any other."""
    lines = _scan_lines(">\t- item\n", {"id": "test", "match_scope": "line"})
    assert [(scan_line.source_position(0)[0], scan_line.text) for scan_line in lines] == [
        (1, ">\t- item")
    ]


def test_quote_tab_residual_for_directive_masking_too() -> None:
    """The same quote-tab-residual fix applies to inline-mask tracking --
    a directive written as a recognized nested list item's own content
    (not merely mentioned inside excluded text) activates normally."""
    text = ">\t- <!-- wv-quality:verbatim-start -->\nvisible\n>\t- <!-- wv-quality:verbatim-end -->\n"
    assert _verbatim_exempt_lines(text.splitlines()) == {1, 2, 3}


def test_quote_tab_residual_permits_a_fence_opener() -> None:
    """The same fix applies to a fence opener -- ">\\t```" must be
    recognized as a fence, not indented code or literal prose, so its
    own content is excluded and a directive inside it stays inert. Every
    line shares the SAME quote marker (quote_depth stays 1 throughout)
    -- an outdented line would end the fence via the PRE-EXISTING (and
    unrelated) quote-depth-outdent rule instead of proving anything
    about this fix."""
    lines = _scan_lines(">\t```\n>\tcode\n>\t```\n", {"id": "test"})
    assert [scan_line.text for scan_line in lines] == []
    text = ">\t```\n>\t<!-- wv-quality:verbatim-start -->\n>\t```\n>\tafter\n"
    assert _verbatim_exempt_lines(text.splitlines()) == set()


def test_quote_tab_residual_permits_an_html_opener() -> None:
    """The same fix applies to an HTML block opener -- ">\\t<div>" must
    be recognized as an HTML block, so its own content is excluded from
    prose (a blank line ends a type-6 block, same as any other -- see
    _advance_html_block_state)."""
    lines = _scan_lines(">\t<div>\n>\thidden\n\nvisible\n", {"id": "test"})
    assert [scan_line.text for scan_line in lines] == ["visible"]


def test_quote_tab_residual_at_the_three_column_boundary_still_permits_structure() -> None:
    """Three leading spaces before the quote marker push the tab to
    start exactly at a tab-stop-aligned column, giving it its own full
    4-column width -- 1 of which belongs to the quote marker, leaving
    the maximum possible residual (3) before the marker. Still within
    CommonMark's "<=3" allowance, so the nested item is still
    recognized."""
    lines = _scan_lines("   >\t- item\n", {"id": "test"})
    assert [scan_line.text for scan_line in lines] == ["item"]


def test_quote_tab_residual_beyond_three_columns_remains_indented_code() -> None:
    """One more literal space after the same 3-column-residual tab pushes
    the total residual to 4 -- genuine indented code, not a false-
    positive list marker: the line must be dropped, not misread as an
    item just because A tab was involved somewhere in its prefix."""
    lines = _scan_lines("   >\t item\n", {"id": "test"})
    assert [scan_line.text for scan_line in lines] == []


def test_dequote_recognizes_a_second_quote_marker_within_a_tab_residual() -> None:
    """wv-53537c finding 7 (external code review): _MARKDOWN_QUOTE_MARKER_RE
    only matches literal SPACE characters, so a residual tab left behind
    by _strip_one_quote_prefix (e.g. ">\\t") permanently blocked _dequote's
    own recursive loop from ever finding a FURTHER "> " marker sitting
    well within that tab's own residual visual width (always <=3
    columns, comfortably inside CommonMark's own "0-3 spaces before a
    quote marker" allowance) -- ">\\t> content" stopped at depth 1 with
    a literal "> content" left as unrecognized quote body, instead of
    depth 2 with clean "content". Confirmed against pre-fix (HEAD)
    behavior: depth stayed 1."""
    assert _dequote(">\t> content") == ("content", 2, 0)


def test_dequote_second_marker_repro_recognizes_a_fence_at_depth_two() -> None:
    """The exact repro from the external review: a fence opener nested
    two quote levels deep, the second reachable only through a residual
    tab, must be recognized as fenced code (excluded from paragraph
    output) rather than flattened into one lazy-continued prose
    paragraph containing a stray "> " marker. Confirmed against pre-fix
    (HEAD) behavior: one merged paragraph, "> \\`\\`\\` > code > \\`\\`\\`"."""
    lines = _scan_lines(">\t> ```\n>\t> code\n>\t> ```\n", {"id": "test"})
    assert [scan_line.text for scan_line in lines] == []


def test_dequote_second_marker_repro_works_for_line_scope_too() -> None:
    """The same fix applies to match_scope: line -- fenced content stays
    excluded there too, same as the single-level precedent
    (test_quote_tab_residual_permits_a_fence_opener)."""
    lines = _scan_lines(
        ">\t> ```\n>\t> code\n>\t> ```\n", {"id": "test", "match_scope": "line"}
    )
    assert [scan_line.text for scan_line in lines] == []


def test_dequote_second_marker_repro_keeps_a_directive_inert_inside_the_fence() -> None:
    """The same fix applies to inline-mask/verbatim tracking -- a
    directive written as the fence's own body content, two quote levels
    deep via a residual tab, stays inert (it's fenced code, not a real
    directive), same as the single-level precedent
    (test_quote_tab_residual_permits_a_fence_opener)."""
    text = ">\t> ```\n>\t> <!-- wv-quality:verbatim-start -->\n>\t> ```\n>\t> after\n"
    assert _verbatim_exempt_lines(text.splitlines()) == set()


def test_dequote_recognizes_a_third_quote_marker_across_two_residual_tabs() -> None:
    """The fix must apply recursively, not just once: each of two
    consecutive tab-terminated levels leaves its OWN residual (the
    second tab's residual must be computed from ITS OWN physical
    position and consumption, never the first (already fully-retired)
    tab's unrelated contribution summed on top -- see _dequote's own
    updated virtual_offset contract)."""
    assert _dequote(">\t>\t> content") == ("content", 3, 0)
    lines = _scan_lines(">\t>\t> ```\n>\t>\t> code\n>\t>\t> ```\n", {"id": "test"})
    assert [scan_line.text for scan_line in lines] == []


def test_dequote_second_marker_still_respects_the_three_column_budget() -> None:
    """A residual tab's own width is always <=3 -- but ADDITIONAL literal
    whitespace between the tab and the next ">" still counts toward the
    same "0-3 spaces" budget as any ordinary quote marker's leading
    whitespace. Within budget (2 residual + 1 literal == 3), the second
    marker is recognized; one more literal space pushes the total to 4,
    correctly rejecting it as a further quote marker (the residual tab
    stays unconsumed, exactly as a too-far-indented ordinary marker
    attempt already does with no tab involved at all)."""
    assert _dequote(">\t > content") == ("content", 2, 0)
    assert _dequote(">\t  > content") == ("\t  > content", 1, 1)


def test_dequote_bare_leading_tab_with_no_marker_anywhere_is_not_a_quote() -> None:
    """Regression guard: a line that starts with a tab but never actually
    contains a blockquote marker at all (not even a first-level one)
    must stay unquoted -- the fix must not manufacture a marker out of
    ordinary tab-indented content just because SOME tab is present."""
    assert _dequote("\tnot quoted at all") == ("\tnot quoted at all", 0, 0)


def test_dequote_residual_tab_with_no_second_marker_stays_at_depth_one() -> None:
    """Regression guard: the fix only extends recognition to a GENUINE
    further marker -- ordinary prose right after a residual tab (no
    second ">" present) must still end dequoting at depth 1 with the
    tab preserved verbatim, exactly as before the fix."""
    assert _dequote(">\tordinary prose, not a marker") == (
        "\tordinary prose, not a marker",
        1,
        1,
    )


def test_bare_list_owned_fence_closes_when_a_sibling_item_starts() -> None:
    """An unclosed fence must close when its containing list item ends --
    _FenceState needs list ownership the same way _HtmlBlockState
    already has it, or a sibling item is wrongly swallowed as more
    fenced content through EOF."""
    lines = _scan_lines("- ```\n- visible\n", {"id": "test"})
    assert [scan_line.text for scan_line in lines] == ["visible"]


def test_list_owned_fence_started_after_item_prose_closes_the_same_way() -> None:
    """The same ownership fix applies when the fence starts on the item's
    OWN continuation line (not its marker line) -- both cases must end
    at the sibling item, not just the marker-line-opens-directly case."""
    lines = _scan_lines("- item\n  ```\n- visible\n", {"id": "test"})
    assert [scan_line.text for scan_line in lines] == ["item", "visible"]


def test_directive_after_a_sibling_item_ends_a_list_owned_fence_is_real() -> None:
    """Once the sibling item ends the list-owned fence, a directive
    written on it is a genuine marker, not swallowed as more fenced
    content -- the fence is no longer open by that point."""
    text = "- ```\n- <!-- wv-quality:verbatim-start -->\nvisible\n"
    assert _verbatim_exempt_lines(text.splitlines()) == {2, 3}


def test_stale_has_paragraph_does_not_leak_list_ownership_past_a_leaf_block() -> None:
    """A leaf block opening after existing item prose must clear
    has_paragraph, not just flush the paragraph text -- otherwise a later
    insufficiently-indented line wrongly "continues" the item (kept
    ownership alive with the item's own content_col), which in turn lets
    a STILL LATER, properly-indented line get wrongly attributed back to
    that same stale item instead of starting fresh at the outer level.

    Structure: "item" is a paragraph inside the list item; "<!-- x -->"
    is a one-line HTML block owned by that item; " visible" (1-space
    indent, short of the item's 2-column content_col) ends the item and
    starts a ROOT paragraph; "  <div>" (2-space indent) interrupts that
    root paragraph and starts a ROOT (not list-owned) HTML block; the
    final directive line is raw HTML content continuing that root block
    and must not activate."""
    text = "- item\n  <!-- x -->\n visible\n  <div>\n- <!-- wv-quality:verbatim-start -->\n"
    assert _verbatim_exempt_lines(text.splitlines()) == set()


def test_blank_line_inside_a_list_owned_fence_does_not_close_it() -> None:
    """A blank line is valid fenced content -- CommonMark decides list-item
    continuation from the NEXT non-blank line's indentation, never from a
    blank line by itself. _advance_fence_state's ends_via_indent check must
    not fire on a blank probe, or the fence closes early and both the
    blank line and the still-fenced content after it leak out as prose."""
    lines = _scan_lines("- ```\n\n  hidden\n- visible\n", {"id": "test"})
    assert [scan_line.text for scan_line in lines] == ["visible"]


def test_directive_inside_a_blank_preserved_list_owned_fence_is_not_real() -> None:
    """Same fix, exercised through the verbatim-marker path: a directive
    written on a still-fenced line (reached only via a blank line that
    must not have closed the fence) stays inert fenced content, not a
    real marker."""
    text = "- ```\n\n  <!-- wv-quality:verbatim-start -->\n- visible\n"
    assert _verbatim_exempt_lines(text.splitlines()) == set()


def test_paths_glob_is_repo_relative_regardless_of_scan_target(tmp_path: Path) -> None:
    """paths: is authored repo-relative -- it must match the same way whether
    the scan targets the repo root, the docs/ subdirectory, or the file
    itself, instead of being re-interpreted relative to the scan target."""
    repo = tmp_path
    docs = repo / "docs"
    docs.mkdir()
    doc = _write(docs / "a.md", "A genuine result.\n")
    rule = """\
id: emphasis
language: prose
kind: lexicon
paths:
  - "docs/*.md"
terms:
  - genuine
"""
    rule_path = _rule(tmp_path, rule)

    whole_repo = run_prose_rule("emphasis", rule_path, repo, scan_id=1, repo=repo)
    assert [f.path for f in whole_repo] == ["docs/a.md"]

    subdir = run_prose_rule("emphasis", rule_path, docs, scan_id=1, repo=repo)
    assert [f.path for f in subdir] == ["a.md"]  # display path is target-relative

    single_file = run_prose_rule("emphasis", rule_path, doc, scan_id=1, repo=repo)
    assert len(single_file) == 1  # paths: still applies to a single-file target


def test_paths_glob_matches_the_lexical_path_not_a_symlinks_resolved_target(
    tmp_path: Path,
) -> None:
    """paths: must match the file's own (lexical) scanned location, not
    where a symlink resolves to -- resolving would make an intended lexical
    match miss, and could double-select one real file reached via two
    different directory-walk entries (a symlink and its target)."""
    repo = tmp_path
    real_dir = repo / "real"
    real_dir.mkdir()
    real_file = real_dir / "a.md"
    real_file.write_text("A genuine result.\n")
    docs = repo / "docs"
    docs.mkdir()
    (docs / "link.md").symlink_to(real_file)

    rule_via_symlink = """\
id: emphasis
language: prose
kind: lexicon
paths:
  - "docs/*.md"
terms:
  - genuine
"""
    rule_path = _rule(tmp_path, rule_via_symlink)
    # The glob names the symlink's own lexical location -- it must match,
    # even though the symlink's target lives elsewhere.
    found = run_prose_rule("emphasis", rule_path, repo, scan_id=1, repo=repo)
    assert [f.path for f in found] == ["docs/link.md"]

    rule_via_real = rule_via_symlink.replace('"docs/*.md"', '"real/*.md"')
    rule_path2 = _rule(tmp_path, rule_via_real)
    # The glob names the real file's location -- exactly one match, not one
    # per directory-walk entry that happens to resolve to the same file.
    found2 = run_prose_rule("emphasis", rule_path2, repo, scan_id=1, repo=repo)
    assert [f.path for f in found2] == ["real/a.md"]


def test_overlapping_pattern_hits_within_one_rule_collapse_to_one_finding(
    tmp_path: Path,
) -> None:
    """Two patterns in one rule matching inside the same phrase (confirmed in
    the wild scanning gnssir-proxy-scorer.md) must not double-count it."""
    rule_path = _write(
        tmp_path / "rule.yaml",
        "id: rule\nlanguage: prose\nkind: regex\n"
        "patterns:\n"
        "  - 'in order to'\n"
        "  - 'order to'\n",
    )
    doc = _write(tmp_path / "doc.md", "We did this in order to succeed.\n")
    found = run_prose_rule("rule", rule_path, doc, scan_id=1)
    assert len(found) == 1
    assert found[0].match_text == "in order to"


def test_overlap_collapse_is_transitive_across_a_chain(tmp_path: Path) -> None:
    """A overlaps B, B overlaps C, but A does not overlap C directly --
    comparing only against the last *kept* hit (instead of tracking the
    running cluster's extent) would forget the A-B-C chain is one
    connected cluster once B itself gets dropped, and wrongly emit two
    findings (A and C) instead of one."""
    rule_path = _write(
        tmp_path / "rule.yaml",
        "id: rule\nlanguage: prose\nkind: regex\n"
        "patterns:\n"
        "  - 'PQRSTU'\n"
        "  - 'STUVWX'\n"
        "  - 'WXYZ'\n",
    )
    doc = _write(tmp_path / "doc.md", "PQRSTUVWXYZ\n")
    found = run_prose_rule("rule", rule_path, doc, scan_id=1)
    assert len(found) == 1
    assert found[0].match_text == "PQRSTU"


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("- The method runs in\n  order to preserve evidence.\n", (1, 18)),
        ("> The method runs in\n> order to preserve evidence.\n", (1, 18)),
    ],
)
def test_soft_wrap_matching_inside_markdown_containers(
    tmp_path: Path, text: str, expected: tuple[int, int]
) -> None:
    rule_path = MANAGED_PATTERNS / "prose-filler-phrases.yaml"
    doc = _write(tmp_path / "container.md", text)
    found = run_prose_rule(rule_path.stem, rule_path, doc, scan_id=1)
    assert [(finding.line, finding.col) for finding in found] == [expected]


@pytest.mark.parametrize(
    "text",
    [
        "    in order to remain code\n",
        "```text\nin order to remain code\n~~~\nstill code\n```\n",
    ],
)
def test_reflow_excludes_indented_and_fenced_code(tmp_path: Path, text: str) -> None:
    rule_path = MANAGED_PATTERNS / "prose-filler-phrases.yaml"
    doc = _write(tmp_path / "code.md", text)
    assert not run_prose_rule(rule_path.stem, rule_path, doc, scan_id=1)


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
require_no_digit_within: 20
terms:
  - measured
"""


def test_motif_number_proximity_and_floor(tmp_path: Path) -> None:
    doc = _write(
        tmp_path / "doc.md",
        "The rate was measured at 5.2/min.\n\nA measured, careful approach.\n",
    )
    rule = _rule(tmp_path, MOTIF_RULE)
    found = run_prose_rule("numberfree", rule, doc, scan_id=1)
    assert [finding.line for finding in found] == [3]

    single = _write(tmp_path / "single.md", "A measured, careful approach.\n")
    assert not run_prose_rule("numberfree", rule, single, scan_id=1)


def test_motif_uses_numeric_evidence_across_soft_wrap(tmp_path: Path) -> None:
    doc = _write(
        tmp_path / "wrapped.md",
        "The first result was measured\nat 5.2 percent.\n\n"
        "The second result was measured\nwithout reported evidence.\n",
    )
    found = run_prose_rule("numberfree", _rule(tmp_path, MOTIF_RULE), doc, scan_id=1)
    assert [finding.line for finding in found] == [4]


MOTIF_RULE_NO_DIGIT_FILTER = """\
id: numberfree_nofilter
language: prose
kind: motif
min_count: 2
terms:
  - measured
"""


def test_motif_digit_suppression_is_opt_in(tmp_path: Path) -> None:
    """Without require_no_digit_within, digit-adjacent hits are not suppressed."""
    doc = _write(
        tmp_path / "doc.md",
        "The rate was measured at 5.2/min.\n\nA measured, careful approach.\n",
    )
    rule = _rule(tmp_path, MOTIF_RULE_NO_DIGIT_FILTER)
    found = run_prose_rule("numberfree_nofilter", rule, doc, scan_id=1)
    assert [finding.line for finding in found] == [1, 3]


def test_motif_near_window_is_accepted_as_a_deprecated_alias(tmp_path: Path) -> None:
    """near_window was renamed to require_no_digit_within; an external rule
    still using the old key must not silently lose digit suppression."""
    legacy_rule = MOTIF_RULE.replace("require_no_digit_within: 20", "near_window: 20")
    rule = load_prose_rule(_rule(tmp_path, legacy_rule), "numberfree")
    assert rule["require_no_digit_within"] == "20"
    assert "near_window" not in rule


def test_motif_near_window_and_require_no_digit_within_together_is_rejected(
    tmp_path: Path,
) -> None:
    both = MOTIF_RULE + "near_window: 20\n"
    with pytest.raises(PatternRuleValidationError, match="near_window"):
        load_prose_rule(_rule(tmp_path, both), "numberfree")


DENSITY_PARAGRAPH_RULE = """\
id: em-dash-overuse
language: prose
kind: density
min_count: 3
terms:
  - "—"
"""


def test_density_matches_punctuation_terms_motif_cannot_reach(tmp_path: Path) -> None:
    """An em dash is non-word on both sides, so \\b...\\b (motif) never
    matches it. density uses literal substring matching instead."""
    doc = _write(
        tmp_path / "doc.md",
        "One—two—three—four dashes in a single paragraph.\n",
    )
    found = run_prose_rule("em-dash-overuse", _rule(tmp_path, DENSITY_PARAGRAPH_RULE), doc, scan_id=1)
    assert len(found) == 3
    assert all(finding.match_text == "—" for finding in found)


def test_density_paragraph_scope_counts_each_paragraph_separately(tmp_path: Path) -> None:
    rule = _rule(tmp_path, DENSITY_PARAGRAPH_RULE)

    below = _write(
        tmp_path / "below.md",
        "One—two dashes here.\n\nAnother—paragraph—with—three now.\n",
    )
    found = run_prose_rule("em-dash-overuse", rule, below, scan_id=1)
    # First paragraph has 1 (< 3, suppressed); second has 3 (>= 3, all reported).
    assert [finding.line for finding in found] == [3, 3, 3]


DENSITY_DOCUMENT_RULE = """\
id: em-dash-overuse-doc
language: prose
kind: density
min_count: 3
match_scope: document
terms:
  - "—"
"""


def test_density_document_scope_pools_every_paragraph(tmp_path: Path) -> None:
    """Each paragraph alone stays under min_count, but the file-wide total
    reaches it — only expressible with match_scope: document."""
    doc = _write(
        tmp_path / "doc.md",
        "First—aside.\n\nSecond—aside.\n\nThird—aside.\n",
    )
    rule = _rule(tmp_path, DENSITY_DOCUMENT_RULE)
    found = run_prose_rule("em-dash-overuse-doc", rule, doc, scan_id=1)
    assert [finding.line for finding in found] == [1, 3, 5]

    paragraph_scoped = _rule(tmp_path, DENSITY_PARAGRAPH_RULE)
    assert not run_prose_rule("em-dash-overuse", paragraph_scoped, doc, scan_id=1)


def test_density_min_count_must_be_a_positive_integer(tmp_path: Path) -> None:
    bad_rule = DENSITY_PARAGRAPH_RULE.replace("min_count: 3", "min_count: 0")
    with pytest.raises(PatternRuleValidationError, match="min_count"):
        load_prose_rule(_rule(tmp_path, bad_rule), "em-dash-overuse")


def test_density_overlapping_terms_collapse_before_thresholding(tmp_path: Path) -> None:
    """"foobar" raw-matches both "foo" and "foobar" -- two raw hits, but only
    one physical occurrence. A min_count: 2 rule must not fire on it."""
    rule = """\
id: foo-density
language: prose
kind: density
min_count: 2
terms:
  - foo
  - foobar
"""
    doc = _write(tmp_path / "doc.md", "A single foobar appears here.\n")
    assert not run_prose_rule("foo-density", _rule(tmp_path, rule), doc, scan_id=1)

    # Two genuinely separate occurrences still meet the floor.
    doc2 = _write(tmp_path / "doc2.md", "A foobar, and another foobar too.\n")
    found = run_prose_rule("foo-density", _rule(tmp_path, rule), doc2, scan_id=1)
    assert len(found) == 2


def test_density_rejects_duplicate_terms(tmp_path: Path) -> None:
    bad_rule = DENSITY_PARAGRAPH_RULE.replace(
        'terms:\n  - "—"\n', 'terms:\n  - "—"\n  - "—"\n'
    )
    with pytest.raises(PatternRuleValidationError, match="duplicate"):
        load_prose_rule(_rule(tmp_path, bad_rule), "em-dash-overuse")


def test_document_match_scope_rejected_for_non_density_kinds(tmp_path: Path) -> None:
    rule = """\
id: bad-scope
language: prose
kind: regex
match_scope: document
patterns:
  - foo
"""
    with pytest.raises(PatternRuleValidationError, match="match_scope"):
        load_prose_rule(_rule(tmp_path, rule), "bad-scope")


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


REGEX_FLOOR_RULE = """\
id: floored
language: prose
kind: regex
min_count: 2
patterns:
  - '\\bso\\b'
"""


def test_regex_min_count_floors_per_pattern(tmp_path: Path) -> None:
    rule = _rule(tmp_path, REGEX_FLOOR_RULE)

    below = _write(tmp_path / "below.md", "It rained, so the model failed.\n")
    assert not run_prose_rule("floored", rule, below, scan_id=1)

    at_floor = _write(
        tmp_path / "at_floor.md",
        "It rained, so the model failed. So the run was voided.\n",
    )
    found = run_prose_rule("floored", rule, at_floor, scan_id=1)
    assert [finding.line for finding in found] == [1, 1]


def test_regex_rule_without_min_count_is_unaffected(tmp_path: Path) -> None:
    """min_count defaults to 1 for regex, preserving fire-on-every-match behavior."""
    rule = load_prose_rule(_rule(tmp_path, REGEX_RULE), "casual")
    assert rule.get("min_count") is None


REGEX_INVALID_MIN_COUNT_RULE = """\
id: badcount
language: prose
kind: regex
min_count: 0
patterns:
  - '\\bso\\b'
"""


def test_regex_min_count_must_be_a_positive_integer(tmp_path: Path) -> None:
    with pytest.raises(PatternRuleValidationError, match="min_count"):
        load_prose_rule(_rule(tmp_path, REGEX_INVALID_MIN_COUNT_RULE), "badcount")
