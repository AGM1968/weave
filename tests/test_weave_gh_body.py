"""Tests for weave_gh.body — WEAVE block extraction and body composition."""

from __future__ import annotations


from weave_gh.body import (
    compose_issue_body,
    extract_human_content,
    extract_weave_block,
    parse_gh_body_description,
    parse_issue_template_fields,
    should_update_body,
)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

SAMPLE_WEAVE_BLOCK = (
    "<!-- WEAVE:BEGIN hash=abc123def456 -->\n"
    "## Context\n\n"
    "Some weave content\n"
    "<!-- WEAVE:END -->"
)

SAMPLE_BODY_WITH_HUMAN = (
    "Human-written notes here.\n\n"
    "More context about this issue.\n\n" + SAMPLE_WEAVE_BLOCK
)

SAMPLE_BODY_WEAVE_ONLY = SAMPLE_WEAVE_BLOCK


# ---------------------------------------------------------------------------
# extract_weave_block
# ---------------------------------------------------------------------------


class TestExtractWeaveBlock:
    def test_extracts_hash_and_content(self) -> None:
        hash_val, content = extract_weave_block(SAMPLE_BODY_WEAVE_ONLY)
        assert hash_val == "abc123def456"
        assert content is not None
        assert "## Context" in content

    def test_with_human_content(self) -> None:
        hash_val, content = extract_weave_block(SAMPLE_BODY_WITH_HUMAN)
        assert hash_val == "abc123def456"
        assert content is not None
        assert "Human-written" not in content

    def test_no_weave_block(self) -> None:
        hash_val, content = extract_weave_block("Just a plain issue body.")
        assert hash_val is None
        assert content is None

    def test_empty_body(self) -> None:
        hash_val, content = extract_weave_block("")
        assert hash_val is None
        assert content is None

    def test_multiline_content(self) -> None:
        body = (
            "<!-- WEAVE:BEGIN hash=deadbeef1234 -->\n"
            "Line 1\n"
            "Line 2\n"
            "Line 3\n"
            "<!-- WEAVE:END -->"
        )
        hash_val, content = extract_weave_block(body)
        assert hash_val == "deadbeef1234"
        assert content is not None
        assert content.count("\n") == 3


# ---------------------------------------------------------------------------
# extract_human_content
# ---------------------------------------------------------------------------


class TestExtractHumanContent:
    def test_with_human_and_weave(self) -> None:
        result = extract_human_content(SAMPLE_BODY_WITH_HUMAN)
        assert "Human-written notes here." in result
        assert "More context" in result
        assert "WEAVE:BEGIN" not in result

    def test_weave_only(self) -> None:
        result = extract_human_content(SAMPLE_BODY_WEAVE_ONLY)
        assert result == ""

    def test_no_weave_block_preserves_body(self) -> None:
        result = extract_human_content("Legacy issue content\nwith multiple lines")
        assert "Legacy issue content" in result
        assert "with multiple lines" in result

    def test_empty_body(self) -> None:
        result = extract_human_content("")
        assert result == ""

    def test_whitespace_only(self) -> None:
        result = extract_human_content("   \n  \n  ")
        assert result == ""


# ---------------------------------------------------------------------------
# compose_issue_body
# ---------------------------------------------------------------------------


class TestComposeIssueBody:
    def test_with_human_content(self) -> None:
        result = compose_issue_body(
            "My notes", "<!-- WEAVE:BEGIN -->content<!-- WEAVE:END -->"
        )
        assert result.startswith("My notes")
        assert "WEAVE:BEGIN" in result
        assert "\n\n" in result  # double newline separator

    def test_without_human_content(self) -> None:
        weave = "<!-- WEAVE:BEGIN -->content<!-- WEAVE:END -->"
        result = compose_issue_body("", weave)
        assert result == weave

    def test_empty_string_human(self) -> None:
        weave = "<!-- WEAVE:BEGIN -->x<!-- WEAVE:END -->"
        result = compose_issue_body("", weave)
        assert result == weave


# ---------------------------------------------------------------------------
# should_update_body
# ---------------------------------------------------------------------------


class TestShouldUpdateBody:
    def test_no_existing_block(self) -> None:
        assert should_update_body("plain body", SAMPLE_WEAVE_BLOCK) is True

    def test_same_hash(self) -> None:
        assert should_update_body(SAMPLE_WEAVE_BLOCK, SAMPLE_WEAVE_BLOCK) is False

    def test_different_hash(self) -> None:
        other = "<!-- WEAVE:BEGIN hash=000000000000 -->\ndifferent\n<!-- WEAVE:END -->"
        assert should_update_body(SAMPLE_WEAVE_BLOCK, other) is True

    def test_both_empty(self) -> None:
        """No WEAVE block in new body, but existing also empty → still needs update."""
        assert should_update_body("", "some new content") is True


# ---------------------------------------------------------------------------
# parse_gh_body_description
# ---------------------------------------------------------------------------


class TestParseGhBodyDescription:
    def test_extracts_human_content(self) -> None:
        body = "Custom description\n\n" + SAMPLE_WEAVE_BLOCK
        result = parse_gh_body_description(body)
        assert result == "Custom description"

    def test_strips_legacy_preamble(self) -> None:
        body = (
            "**Weave ID**: abc123\n"
            "---\n"
            "*Synced from Weave*\n"
            "Actual description\n\n" + SAMPLE_WEAVE_BLOCK
        )
        result = parse_gh_body_description(body)
        assert "Weave ID" not in result
        assert "---" not in result
        assert "Synced from Weave" not in result
        assert "Actual description" in result

    def test_empty_body(self) -> None:
        assert parse_gh_body_description("") == ""

    def test_weave_only_body(self) -> None:
        assert parse_gh_body_description(SAMPLE_WEAVE_BLOCK) == ""

    def test_no_weave_block_returns_body(self) -> None:
        result = parse_gh_body_description("Plain issue text\nMore text")
        assert "Plain issue text" in result


# ---------------------------------------------------------------------------
# parse_issue_template_fields
# ---------------------------------------------------------------------------


class TestParseIssueTemplateFields:
    def test_parses_all_fields(self) -> None:
        body = "### Weave ID\n\nwv-abcd\n\n### Type\n\ntask\n\n### Description\n\nFix the bug"
        fields = parse_issue_template_fields(body)
        assert fields["weave id"] == "wv-abcd"
        assert fields["type"] == "task"
        assert fields["description"] == "Fix the bug"

    def test_skips_no_response(self) -> None:
        body = "### Weave ID\n\n_No response_\n\n### Type\n\nepic"
        fields = parse_issue_template_fields(body)
        assert "weave id" not in fields
        assert fields["type"] == "epic"

    def test_empty_body(self) -> None:
        assert parse_issue_template_fields("") == {}

    def test_multiline_description(self) -> None:
        body = "### Description\n\nLine 1\nLine 2\nLine 3"
        fields = parse_issue_template_fields(body)
        assert "Line 1" in fields["description"]
        assert "Line 3" in fields["description"]

    def test_priority_field(self) -> None:
        body = "### Priority\n\nP1 (high)\n\n### Type\n\nbug"
        fields = parse_issue_template_fields(body)
        assert fields["priority"] == "P1 (high)"
        assert fields["type"] == "bug"
