"""Prose-register pattern backend for `wv quality patterns` (stdlib-only).

Runs lexicon/motif/regex rules over Markdown and plain-text files and returns
PatternFinding rows under the same contract as __main__._run_pattern_rule.
Rules use a small YAML subset because this package declares zero Python
dependencies and must not import PyYAML; parse_flat_rule() raises on nested
mappings rather than misreading them.
"""

# pylint: disable=too-many-lines

from __future__ import annotations

from bisect import bisect_right
from dataclasses import dataclass
import json
import os
import re
from fnmatch import fnmatch
from pathlib import Path
from typing import Iterator

from weave_quality.models import PatternFinding

PROSE_LANGUAGES = {"prose", "markdown"}
_TEXT_SUFFIXES = {".md", ".markdown", ".rst", ".txt"}
_SKIP_PARTS = {".git", "node_modules", ".venv", "venv", "archive", "__pycache__"}

_LANG_RE = re.compile(r"^language:\s*([A-Za-z0-9_-]+)", re.MULTILINE)
_ID_RE = re.compile(r"^id:\s*([A-Za-z0-9_-]+)\s*$", re.MULTILINE)
# CommonMark tolerates at most 3 leading spaces before an ATX heading's "#"
# run (0-3, same limit as blockquote/fence markers), and the run may be
# followed by either whitespace OR end-of-line -- a bare "#" alone on a
# line is a valid (empty) heading, not plain text needing a trailing space
# to be recognized.
_MARKDOWN_HEADING_RE = re.compile(r"^ {0,3}#{1,6}(?:[ \t]|$)")
# CommonMark: 0-3 leading spaces, an unordered marker or a 1-9 digit ordinal,
# then EITHER 1+ spaces/tabs and the item's content, OR nothing at all (a
# "blank" item -- the marker alone on the line). The trailing alternation
# keeps group(1) a plain string ("" for a blank item) either way, instead of
# None, so callers never need to special-case which branch matched.
_MARKDOWN_LIST_RE = re.compile(r"^ {0,3}(?:[-*+]|\d{1,9}[.)])(?:[ \t]+|(?=$))(.*)$")
# The ordinal itself, checked separately from _MARKDOWN_LIST_RE: CommonMark
# lets an ordered list item interrupt an open PARAGRAPH only when it starts
# at 1 AND is non-blank -- any other starting number, or a blank first item,
# is ordinary continuation text instead (its digits/marker stay literal, not
# a real list marker that splits the paragraph). Neither restriction applies
# when nothing is open to interrupt, or when the marker just extends an
# already-open list -- see _paragraph_interrupt_kind.
_MARKDOWN_ORDERED_START_RE = re.compile(r"^ {0,3}(\d{1,9})[.)]")
# A line of 3+ matching -, _, or * characters (0-3 leading spaces, each
# optionally followed by spaces/tabs) is a thematic break -- it always
# interrupts a paragraph, including one open inside a blockquote.
_THEMATIC_BREAK_RE = re.compile(
    r"^ {0,3}(?:-[ \t]*){3,}$|^ {0,3}(?:_[ \t]*){3,}$|^ {0,3}(?:\*[ \t]*){3,}$"
)
# CommonMark tolerates at most 3 leading spaces before a blockquote marker
# (at each nesting level _dequote strips) -- 4+ makes it indented code, not
# a blockquote, even when what follows looks like one.
_MARKDOWN_QUOTE_RE = re.compile(r"^ {0,3}>\s?(.*)$")
# Just the leading-spaces-plus-">" portion, with no optional trailing
# whitespace consumed -- used by _strip_one_quote_prefix, which needs to
# inspect that next character itself (space vs tab are NOT interchangeable:
# see its own docstring) rather than let a blanket "\\s?" swallow it
# unconditionally the way _MARKDOWN_QUOTE_RE's single combined group does.
_MARKDOWN_QUOTE_MARKER_RE = re.compile(r"^ {0,3}>")
# CommonMark tolerates at most 3 leading spaces before a fence marker
# (after any quote prefixes _dequote already stripped) -- 4+ is indented
# code, a different construct. group(1) is still just the backtick/tilde
# run (the space prefix is outside the capturing group).
_FENCE_OPEN_RE = re.compile(r"^ {0,3}(`{3,}|~{3,})")
# CommonMark HTML blocks, types 1-6 -- these interrupt an open paragraph
# (including one open inside a blockquote) the same as a heading or
# thematic break, and are STATEFUL: once opened, they continue through
# their own type-specific terminator condition (see _HtmlBlockState /
# _advance_html_block_state), not just their opening line. Open patterns
# are checked against the dequoted probe, same reasoning as the
# heading/break/list checks: a nested "> <div>" is recognized as an HTML
# block start the same way a bare one is. Each type is a SEPARATE compiled
# pattern (rather than one combined alternation) for two reasons: the
# state machine needs to know which specific type opened, to pick the
# right terminator, and case-insensitivity is a per-type grammar detail
# (types 1 and 6 match tag NAMES case-insensitively; types 2-5's literal
# openers/closers -- "<!--", "<?", "<!", "<![CDATA[" -- are case-sensitive
# per the CommonMark spec, notably CDATA's own uppercase "CDATA" token).
_HTML_BLOCK_TYPE1_OPEN_RE = re.compile(
    r"^ {0,3}<(?:script|pre|style|textarea)(?:[\s>]|$)", re.IGNORECASE
)
_HTML_BLOCK_TYPE1_CLOSE_RE = re.compile(r"</(?:script|pre|style|textarea)>", re.IGNORECASE)
_HTML_BLOCK_TYPE2_OPEN_RE = re.compile(r"^ {0,3}<!--")
_HTML_BLOCK_TYPE2_CLOSE_RE = re.compile(r"-->")
_HTML_BLOCK_TYPE3_OPEN_RE = re.compile(r"^ {0,3}<\?")
_HTML_BLOCK_TYPE3_CLOSE_RE = re.compile(r"\?>")
_HTML_BLOCK_TYPE4_OPEN_RE = re.compile(r"^ {0,3}<![A-Za-z]")
_HTML_BLOCK_TYPE4_CLOSE_RE = re.compile(r">")
_HTML_BLOCK_TYPE5_OPEN_RE = re.compile(r"^ {0,3}<!\[CDATA\[")
_HTML_BLOCK_TYPE5_CLOSE_RE = re.compile(r"\]\]>")
_HTML_BLOCK_TAGS_TYPE6 = (
    r"address|article|aside|base|basefont|blockquote|body|caption|center|"
    r"col|colgroup|dd|details|dialog|dir|div|dl|dt|fieldset|figcaption|"
    r"figure|footer|form|frame|frameset|h[1-6]|head|header|hr|html|iframe|"
    r"legend|li|link|main|menu|menuitem|nav|noframes|ol|optgroup|option|p|"
    r"param|search|section|summary|table|tbody|td|tfoot|th|thead|title|tr|"
    r"track|ul"
)
# The tag name must be followed by whitespace, '>', an exact self-closing
# '/>', or end-of-line -- NOT a bare '/' on its own (that's a malformed
# tag, e.g. "<div/not-a-tag", not CommonMark's self-closing form).
_HTML_BLOCK_TYPE6_OPEN_RE = re.compile(
    rf"^ {{0,3}}</?(?:{_HTML_BLOCK_TAGS_TYPE6})(?:[ \t]|/>|>|$)", re.IGNORECASE
)
# Ordered (type, open_re, close_re) triples -- checked in CommonMark's own
# numeric priority order, first match wins. close_re is None for type 6:
# it has no regex terminator of its own, only the blank-line/container-end
# rule _advance_html_block_state applies uniformly to types 6 and 7.
_HTML_BLOCK_OPENERS: tuple[tuple[int, re.Pattern[str], re.Pattern[str] | None], ...] = (
    (1, _HTML_BLOCK_TYPE1_OPEN_RE, _HTML_BLOCK_TYPE1_CLOSE_RE),
    (2, _HTML_BLOCK_TYPE2_OPEN_RE, _HTML_BLOCK_TYPE2_CLOSE_RE),
    (3, _HTML_BLOCK_TYPE3_OPEN_RE, _HTML_BLOCK_TYPE3_CLOSE_RE),
    (4, _HTML_BLOCK_TYPE4_OPEN_RE, _HTML_BLOCK_TYPE4_CLOSE_RE),
    (5, _HTML_BLOCK_TYPE5_OPEN_RE, _HTML_BLOCK_TYPE5_CLOSE_RE),
    (6, _HTML_BLOCK_TYPE6_OPEN_RE, None),
)
# CommonMark HTML block type 7: a complete open or closing tag (any tag
# name, not just the type-6 list above), alone on a line with nothing but
# whitespace around it. Unlike types 1-6, type 7 CANNOT interrupt an open
# paragraph -- it can only start a block when nothing is open yet. Like
# type 6, it has no regex terminator: it continues until a blank line.
# CommonMark explicitly excludes OPEN tags named pre/script/style/textarea
# from type 7 (those are type-1 openers, or -- like "<script/>", which
# type 1 also rejects since '/' isn't an allowed character after the tag
# name -- ordinary inline raw HTML within a normal paragraph, not a leaf
# block of their own); a CLOSING tag of those same names stays eligible.
_HTML_ATTR = r"""[A-Za-z_:][-A-Za-z0-9_.:]*(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"'=<>`]+))?"""
_HTML_BLOCK_TYPE7_OPEN_TAG_RE = re.compile(
    rf"^ {{0,3}}<([A-Za-z][-A-Za-z0-9]*)(?:\s+{_HTML_ATTR})*\s*/?>\s*$"
)
_HTML_BLOCK_TYPE7_CLOSE_TAG_RE = re.compile(r"^ {0,3}</[A-Za-z][-A-Za-z0-9]*\s*>\s*$")
_HTML_BLOCK_TYPE7_EXCLUDED_OPEN_TAGS = {"pre", "script", "style", "textarea"}


def _html_type7_start_matches(probe: str) -> bool:
    """CommonMark type 7 start condition, honoring the pre/script/style/
    textarea open-tag exclusion (see the constants above)."""
    open_match = _HTML_BLOCK_TYPE7_OPEN_TAG_RE.match(probe)
    if open_match is not None:
        return open_match.group(1).lower() not in _HTML_BLOCK_TYPE7_EXCLUDED_OPEN_TAGS
    return _HTML_BLOCK_TYPE7_CLOSE_TAG_RE.match(probe) is not None
_VERBATIM_EXEMPT_START_RE = re.compile(r"<!--\s*wv-quality:verbatim-start\s*-->")
_VERBATIM_EXEMPT_END_RE = re.compile(r"<!--\s*wv-quality:verbatim-end\s*-->")


class PatternRuleValidationError(ValueError):
    """A pattern definition cannot be loaded safely."""


class PatternRuleExecutionError(RuntimeError):
    """A valid pattern definition could not complete its target scan."""


@dataclass(frozen=True)
class _ScanLine:
    """One matchable line or reflowed paragraph with source-line offsets.

    `index` is this unit's position in document order -- collapsing (see
    _collapse_overlapping_spans) needs a stable, cheap ordering key that
    doesn't depend on object identity/memory address.
    """

    text: str
    starts: tuple[tuple[int, int, int], ...]
    index: int

    def source_position(self, offset: int) -> tuple[int, int]:
        """Map a reflowed match offset back to its source line and column."""
        positions = [start for start, _, _ in self.starts]
        index = max(0, bisect_right(positions, offset) - 1)
        start, lineno, source_col = self.starts[index]
        return lineno, source_col + max(0, offset - start)


def rule_language(rule_path: Path) -> str:
    """Return the rule's language field, lowercased, or an empty string."""
    try:
        match = _LANG_RE.search(rule_path.read_text(encoding="utf-8"))
    except OSError:
        return ""
    return match.group(1).lower() if match else ""


def _strip_yaml_comment(raw: str, rule_path: Path, lineno: int) -> str:
    """Strip an unquoted YAML comment and reject unmatched scalar quotes."""
    stripped = raw.lstrip()
    if stripped.startswith("#"):
        return ""
    if stripped.startswith("- "):
        scalar = stripped[2:].lstrip()
    elif ":" in stripped:
        scalar = stripped.partition(":")[2].lstrip()
    else:
        scalar = stripped
    quote = scalar[0] if scalar.startswith(("'", '"')) else ""
    scalar_start = raw.find(scalar) if scalar else len(raw)
    index = scalar_start
    while index < len(raw):
        char = raw[index]
        if quote == "'" and char == "'" and index + 1 < len(raw) and raw[index + 1] == "'":
            index += 2
            continue
        if quote == '"' and char == "\\":
            index += 2
            continue
        if quote and char == quote:
            if index == scalar_start:
                pass
            else:
                quote = ""
        elif char == "#" and not quote and (index == 0 or raw[index - 1].isspace()):
            return raw[:index].rstrip()
        index += 1
    if quote:
        raise ValueError(f"{rule_path.name}:{lineno}: unmatched {quote} quote")
    return raw.rstrip()


def _parse_scalar(value: str, rule_path: Path, lineno: int) -> str:
    """Parse one scalar from the supported YAML subset."""
    value = value.strip()
    if not value:
        return ""
    if value[0] == "'":
        parsed: list[str] = []
        index = 1
        while index < len(value):
            if value[index] != "'":
                parsed.append(value[index])
                index += 1
                continue
            if index + 1 < len(value) and value[index + 1] == "'":
                parsed.append("'")
                index += 2
                continue
            if value[index + 1 :].strip():
                raise ValueError(
                    f"{rule_path.name}:{lineno}: content after quoted scalar"
                )
            return "".join(parsed)
        raise ValueError(f"{rule_path.name}:{lineno}: unmatched ' quote")
    if value[0] == '"':
        try:
            parsed_value = json.loads(value)
        except json.JSONDecodeError as exc:
            raise ValueError(
                f"{rule_path.name}:{lineno}: invalid double-quoted scalar"
            ) from exc
        if not isinstance(parsed_value, str):
            raise ValueError(f"{rule_path.name}:{lineno}: expected string scalar")
        return parsed_value
    if re.search(r":\s", value):
        raise ValueError(
            f"{rule_path.name}:{lineno}: unquoted ': ' is not valid in a plain scalar"
        )
    return value


def parse_flat_rule(rule_path: Path) -> dict[str, object]:
    """Parse the flat YAML subset prose rules use.

    Supports `key: value`, `key:` followed by `- item` lines, and simple
    `key: >-` / `key: |` block scalars. Raises ValueError on indentation that
    implies nested mappings.
    """
    data: dict[str, object] = {}
    current_list: list[str] | None = None
    scalar_key: str | None = None
    scalar_parts: list[str] = []
    plain_scalar_key: str | None = None
    plain_scalar_parts: list[str] = []

    for lineno, raw in enumerate(
        rule_path.read_text(encoding="utf-8").splitlines(), start=1
    ):
        if scalar_key is not None and (not raw or raw[0] in " \t"):
            if raw.strip():
                scalar_parts.append(raw.strip())
            continue
        if plain_scalar_key is not None and (not raw or raw[0] in " \t"):
            continuation = _strip_yaml_comment(raw, rule_path, lineno).strip()
            if not continuation:
                continue
            if re.search(r":\s", continuation):
                raise ValueError(
                    f"{rule_path.name}:{lineno}: nested mapping unsupported; "
                    "quote or fold a plain scalar containing ': '"
                )
            plain_scalar_parts.append(continuation)
            continue
        line = _strip_yaml_comment(raw, rule_path, lineno)
        if not line.strip():
            continue
        stripped = line.strip()

        if scalar_key is not None:
            data[scalar_key] = " ".join(scalar_parts)
            scalar_key = None
            scalar_parts = []
        if plain_scalar_key is not None:
            data[plain_scalar_key] = " ".join(plain_scalar_parts)
            plain_scalar_key = None
            plain_scalar_parts = []

        if stripped.startswith("- "):
            if current_list is None:
                raise ValueError(f"{rule_path.name}:{lineno}: list item outside a list")
            item = _parse_scalar(stripped[2:], rule_path, lineno)
            if not item:
                raise ValueError(f"{rule_path.name}:{lineno}: empty list item")
            current_list.append(item)
            continue
        if line[0] in " \t":
            raise ValueError(
                f"{rule_path.name}:{lineno}: nested mapping unsupported in prose rules"
            )
        key, sep, value = line.partition(":")
        if not sep:
            raise ValueError(f"{rule_path.name}:{lineno}: expected 'key: value'")
        key = key.strip()
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_-]*", key):
            raise ValueError(f"{rule_path.name}:{lineno}: invalid key {key!r}")
        value = _parse_scalar(value, rule_path, lineno)
        if key in data:
            raise ValueError(f"{rule_path.name}:{lineno}: duplicate key {key!r}")
        if value in {">", ">-", "|", "|-"}:
            scalar_key = key
            scalar_parts = []
            current_list = None
        elif value:
            data[key] = value
            plain_scalar_key = key
            plain_scalar_parts = [value]
            current_list = None
        else:
            current_list = []
            data[key] = current_list

    if scalar_key is not None:
        data[scalar_key] = " ".join(scalar_parts)
    if plain_scalar_key is not None:
        data[plain_scalar_key] = " ".join(plain_scalar_parts)
    return data


def _require_string(rule: dict[str, object], key: str) -> str:
    value = rule.get(key)
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"missing or empty {key!r}")
    return value


def _require_string_list(rule: dict[str, object], key: str) -> list[str]:
    value = rule.get(key)
    if not isinstance(value, list) or not value:
        raise ValueError(f"missing or empty {key!r} list")
    if not all(isinstance(item, str) and item.strip() for item in value):
        raise ValueError(f"{key!r} must contain nonempty strings")
    return value


def _default_match_scope(rule: dict[str, object]) -> str:
    """Preserve raw-line semantics for structural Markdown rules."""
    rule_id = str(rule.get("id", ""))
    return "line" if rule_id.startswith("markdown-") else "paragraph"


def _require_block_scalar(rule_path: Path, key: str) -> None:
    """Require canonical narrative metadata to use an explicit YAML block scalar."""
    text = rule_path.read_text(encoding="utf-8")
    match = re.search(
        rf"^{re.escape(key)}:\s*(>|>-|\||\|-)(?:\s+#.*)?$", text, re.MULTILINE
    )
    if match is None:
        raise ValueError(f"{key!r} must use a block scalar (>-, |-, >, or |)")


def _validate_control_examples(rule: dict[str, object]) -> None:
    """Prove definition-owned positive and negative examples against the matcher."""
    kind = str(rule["kind"])
    engine = _KIND_ENGINES[kind]
    for index, example in enumerate(_string_list(rule, "positive_controls"), start=1):
        if not engine(example, rule):
            raise ValueError(f"positive_controls item {index} does not produce a finding")
    for index, example in enumerate(_string_list(rule, "negative_controls"), start=1):
        if engine(example, rule):
            raise ValueError(f"negative_controls item {index} produces a finding")


def _validate_positive_int(rule: dict[str, object], key: str, default: int) -> None:
    """Require rule[key] (or default) to parse as a positive integer."""
    try:
        value = int(str(rule.get(key, default)))
    except ValueError as exc:
        raise ValueError(f"{key!r} must be an integer") from exc
    if value < 1:
        raise ValueError(f"{key!r} must be positive")


def _validate_maturity_and_controls(rule: dict[str, object], rule_path: Path) -> bool:
    """Validate the lifecycle/controls contract; return whether controls are required."""
    maturity = _require_string(rule, "maturity").lower() if "maturity" in rule else ""
    if maturity and maturity not in {"candidate", "observed", "promotable"}:
        raise ValueError(f"unsupported maturity {maturity!r}")
    if maturity:
        rule["maturity"] = maturity
    controls_required = maturity == "promotable"
    for optional_list in ("paths", "exempt"):
        if optional_list in rule:
            _require_string_list(rule, optional_list)
    if controls_required:
        _require_string_list(rule, "positive_controls")
        _require_string_list(rule, "negative_controls")
    else:
        for optional_control in ("positive_controls", "negative_controls"):
            if optional_control in rule:
                _require_string_list(rule, optional_control)
    for optional_scalar in ("severity", "policy", "maturity", "message", "provenance"):
        if optional_scalar in rule:
            _require_string(rule, optional_scalar)
    if controls_required:
        _require_block_scalar(rule_path, "provenance")
        _require_block_scalar(rule_path, "message")
    return controls_required


def load_prose_rule(rule_path: Path, expected_id: str | None = None) -> dict[str, object]:
    """Parse and validate one prose rule, raising with its source path."""
    try:
        rule = parse_flat_rule(rule_path)
        rule_id = _require_string(rule, "id")
        if expected_id is not None and rule_id != expected_id:
            raise ValueError(
                f"id {rule_id!r} does not match filename {expected_id!r}"
            )
        language = _require_string(rule, "language").lower()
        if language not in PROSE_LANGUAGES:
            raise ValueError(f"unsupported prose language {language!r}")
        kind = _require_string(rule, "kind").lower()
        matcher_key = "terms" if kind in {"lexicon", "motif", "density"} else "patterns"
        if kind not in _KIND_ENGINES:
            raise ValueError(f"unsupported prose kind {kind!r}")
        rule["kind"] = kind
        default_scope = _default_match_scope(rule)
        match_scope = str(rule.get("match_scope", default_scope))
        # density additionally accepts "document": pool every paragraph/line
        # unit in the file into one counting scope, instead of counting each
        # unit separately. No other kind gives match_scope a counting role.
        valid_scopes = {"line", "paragraph", "document"} if kind == "density" else {"line", "paragraph"}
        if match_scope not in valid_scopes:
            raise ValueError(f"unsupported match_scope {match_scope!r}")
        matchers = _require_string_list(rule, matcher_key)
        _validate_maturity_and_controls(rule, rule_path)
        rule["language"] = language
        rule["match_scope"] = match_scope
        if kind == "regex":
            for pattern in matchers:
                try:
                    re.compile(pattern)
                except re.error as exc:
                    raise ValueError(f"invalid regex {pattern!r}: {exc}") from exc
            _validate_positive_int(rule, "min_count", 1)
        if kind == "motif":
            if "near_window" in rule:
                # near_window was renamed to require_no_digit_within; accept
                # it as a deprecated alias so an external rule authored
                # against the old key doesn't validate while its digit
                # suppression silently goes inert.
                if "require_no_digit_within" in rule:
                    raise ValueError(
                        "'near_window' and 'require_no_digit_within' cannot both be "
                        "set ('near_window' is a deprecated alias for "
                        "'require_no_digit_within')"
                    )
                rule["require_no_digit_within"] = rule.pop("near_window")
            _validate_positive_int(rule, "min_count", 3)
            if "require_no_digit_within" in rule:
                _validate_positive_int(rule, "require_no_digit_within", 80)
        if kind == "density":
            _validate_positive_int(rule, "min_count", 3)
            terms_list = _string_list(rule, "terms")
            lowered_terms = [term.lower() for term in terms_list]
            if len(lowered_terms) != len(set(lowered_terms)):
                raise ValueError("density 'terms' must not contain duplicate values")
        if any(key in rule for key in ("positive_controls", "negative_controls")):
            _validate_control_examples(rule)
    except (OSError, ValueError) as exc:
        raise PatternRuleValidationError(f"{rule_path}: {exc}") from exc
    return rule


def validate_pattern_rule(rule_path: Path, expected_id: str) -> str:
    """Validate a prose or ast-grep rule and return its language."""
    try:
        text = rule_path.read_text(encoding="utf-8")
    except OSError as exc:
        raise PatternRuleValidationError(f"{rule_path}: {exc}") from exc

    id_match = _ID_RE.search(text)
    language = rule_language(rule_path)
    if id_match is None:
        raise PatternRuleValidationError(f"{rule_path}: missing or empty 'id'")
    if id_match.group(1) != expected_id:
        raise PatternRuleValidationError(
            f"{rule_path}: id {id_match.group(1)!r} does not match filename {expected_id!r}"
        )
    if not language:
        raise PatternRuleValidationError(f"{rule_path}: missing or empty 'language'")
    if language in PROSE_LANGUAGES:
        load_prose_rule(rule_path, expected_id)
    elif not re.search(r"^rule:\s*$\n(?:[ \t]+\S.*\n?)+", text, re.MULTILINE):
        raise PatternRuleValidationError(
            f"{rule_path}: code rule requires a nonempty nested 'rule' mapping"
        )
    return language


def _lexical_abspath(path: Path) -> Path:
    """Absolute path with '.'/'..' normalized, WITHOUT resolving symlinks.

    Path.resolve() always follows symlinks, which is wrong here: paths:
    matching and finding identity must key off the path a rule author and
    the directory walk actually see, not where a symlink happens to point.
    Resolving would make a symlinked file match (or miss) paths: based on
    its target's location, and could scan the same real file twice under
    two different directory-walk entries (a symlink and its target).
    """
    return Path(os.path.abspath(str(path)))


def _repo_relative_posix(path: Path, repo: Path) -> str:
    """Return path relative to repo as a posix string, or its lexical absolute form if outside."""
    path_abs = _lexical_abspath(path)
    try:
        return path_abs.relative_to(_lexical_abspath(repo)).as_posix()
    except ValueError:
        return path_abs.as_posix()


def _iter_text_files(target: Path, include: list[str], repo: Path) -> list[Path]:
    """List candidate files under target, filtered by paths: globs.

    `paths:` globs are always matched against the file's path relative to
    `repo`, never to `target` -- otherwise the same glob matches or misses
    depending on whether the scan was invoked against the repo root, a
    subdirectory, or a single file (the target and repo coincide only for a
    repo-root scan). A single-file target is filtered too, instead of
    bypassing `paths:` entirely.
    """
    if target.is_file():
        if target.suffix.lower() not in _TEXT_SUFFIXES:
            return []
        if include and not any(
            fnmatch(_repo_relative_posix(target, repo), glob) for glob in include
        ):
            return []
        return [target]
    files: list[Path] = []
    for path in sorted(target.rglob("*")):
        if not path.is_file() or path.suffix.lower() not in _TEXT_SUFFIXES:
            continue
        if _SKIP_PARTS.intersection(path.parts):
            continue
        if include and not any(
            fnmatch(_repo_relative_posix(path, repo), glob) for glob in include
        ):
            continue
        files.append(path)
    return files


def _word_regex(terms: list[str]) -> re.Pattern[str]:
    alts = "|".join(re.escape(term) for term in sorted(terms, key=len, reverse=True))
    return re.compile(rf"\b({alts})\b", re.IGNORECASE)


def _find_all(haystack: str, needle: str) -> Iterator[int]:
    pos = haystack.find(needle)
    while pos != -1:
        yield pos
        pos = haystack.find(needle, pos + 1)


def _string_list(rule: dict[str, object], key: str) -> list[str]:
    value = rule.get(key)
    if not isinstance(value, list):
        return []
    return [str(item) for item in value]


_Span = tuple["_ScanLine", int, int, str]


def _collapse_overlapping_spans(hits: list[_Span]) -> list[_Span]:
    """Collapse same-rule findings whose reflowed spans overlap into one.

    A rule with several patterns/terms that can match the same underlying
    text (e.g. two regex patterns in one rule both firing inside the same
    phrase, or a density rule whose terms are substrings of each other)
    otherwise reports it twice for a single defect -- confirmed in the wild
    scanning gnssir-proxy-scorer.md. Collapsing operates on each unit's own
    reflowed-text offsets (not physical line/column, which is only computed
    afterwards via source_position) so an overlap that crosses a
    soft-wrapped physical line within one paragraph unit is still caught.
    Hits are ordered by unit (document order), then leftmost, then longest;
    a later hit that starts before the *running cluster's* end is folded
    into that cluster rather than kept as a second finding -- the cluster's
    end is extended by every hit folded into it (not just the first kept
    hit's own end), so a transitive chain (A overlaps B, B overlaps C, A
    does not overlap C) still collapses to one finding, not two: comparing
    only against the last *kept* hit would forget C overlaps B once B itself
    got dropped. Units are compared by `.index`, not object identity -- a
    multi-pattern engine (e.g. regex, one _scan_lines() call per pattern)
    produces a fresh _ScanLine per call for the same document position, so
    `is` would never consider them the same unit even though `.index`
    deterministically does for one (text, rule).
    """
    ordered = sorted(hits, key=lambda hit: (hit[0].index, hit[1], -(hit[2] - hit[1])))
    kept: list[_Span] = []
    cluster_unit: int | None = None
    cluster_end = -1
    for scan_line, start, end, match_text in ordered:
        if kept and scan_line.index == cluster_unit and start < cluster_end:
            cluster_end = max(cluster_end, end)
            continue
        kept.append((scan_line, start, end, match_text))
        cluster_unit = scan_line.index
        cluster_end = end
    return kept


def _strip_one_quote_prefix(
    line: str, remainder: str, prior_tab_consumed: int
) -> tuple[str, int] | None:
    """Strip exactly one leading blockquote marker (0-3 spaces then ">")
    and its optional single trailing space/tab from `remainder`.

    Returns (new_remainder, virtual_offset), or None when no marker prefix
    is present at all. virtual_offset is 1 when the optional trailing
    whitespace consumed was a TAB, else 0.

    A literal space there is fully consumed like any ordinary character --
    1 physical character removed, 1 visual column accounted for, no
    residual. A TAB cannot be treated the same way: CommonMark expands it
    to the next 4-column tab stop, and only the FIRST of the resulting
    columns belongs to the marker itself -- the rest stays as the
    container's own content indentation (e.g. "># hidden" is different
    from ">\\thidden", where the tab's remaining width still counts toward
    whether "hidden" is indented code). A tab is one atomic character, so
    it can't be partially removed the way a fraction of a space run could
    be -- it stays as the first character of `new_remainder` UNCHANGED,
    and the caller must account for the one already-consumed virtual
    column separately (see _relative_visual_column's virtual_offset
    parameter) whenever it measures indentation relative to this
    remainder; a raw suffix of the original line is not, by itself,
    enough metadata to recover that column.

    `line` (the full physical line `remainder` is a suffix of) and
    `prior_tab_consumed` are needed for wv-ac22a5 finding 7 (external
    code review): a residual leading tab left behind by a PRIOR level's
    own strip is never itself a quote-marker match
    (`_MARKDOWN_QUOTE_MARKER_RE` requires literal SPACE characters, and a
    tab is a different character entirely) -- left unhandled,
    ">\\t> ```" stopped recognizing depth at 1 even though a genuine
    second "> " marker sits well within the tab's own residual visual
    width. `prior_tab_consumed` is exactly the delta the IMMEDIATELY
    PRECEDING call returned (0 or 1, never the caller's own accumulated
    running total across multiple levels -- a residual tab's true
    native width depends only on ITS OWN physical position in `line`
    and how much of ITS OWN span the marker directly before it already
    spent, never on some EARLIER, already fully-retired tab's unrelated
    contribution; using the accumulated sum here would under-count the
    residual for a second (or deeper) consecutive tab-terminated level).
    Materializing just that leading tab into its true residual width
    (_materialize_quote_tab's own approach, reused here for the
    recursive case it can't reach) lets the ordinary marker regex see it
    as ordinary optional whitespace, exactly as CommonMark already
    allows before any blockquote marker. The synthetic spaces are never
    real characters to strip from `remainder` -- when the match succeeds
    it always consumes ALL of them (a fixed-length leading run, either
    short enough for `{0,3}` to match whole or long enough to fail
    entirely) -- so mapping the match back to `remainder` only ever
    strips the 1 real tab character plus whatever real characters
    (literal spaces, then ">") follow it.
    """
    probe = remainder
    tab_residual = 0
    if probe[:1] == "\t":
        tab_residual = _relative_visual_column(line, remainder, 1, prior_tab_consumed)
        probe = (" " * tab_residual) + remainder[1:]
    marker_match = _MARKDOWN_QUOTE_MARKER_RE.match(probe)
    if marker_match is None:
        return None
    if tab_residual:
        literal_chars_matched = marker_match.end() - tab_residual
        remainder = remainder[1 + literal_chars_matched :]
    else:
        remainder = remainder[marker_match.end() :]
    rest = remainder
    if rest[:1] == "\t":
        return rest, 1
    if rest[:1] == " ":
        return rest[1:], 0
    return rest, 0


def _dequote(line: str) -> tuple[str, int, int]:
    """Strip every leading blockquote prefix, returning (content, depth,
    virtual_offset).

    depth is the number of nested ">" levels stripped -- callers use it to
    detect a blockquote entry/exit/depth-change as a block boundary (inline
    parsing, and a nested fence's own scope, cannot cross into or out of a
    container). content is the dequoted probe text used for fence checks: a
    fence marker nested under a blockquote ("> ```lang") must be recognized
    as a fence the same way a bare one is, and ALL nested levels are
    stripped, not just one -- a doubly-nested quote ("> > ```lang") left a
    single strip with a literal "> ```lang" that _FENCE_OPEN_RE never
    matches. virtual_offset is the extra visual columns already consumed
    by the LAST level's own marker whitespace, when a partially-stripped
    tab was left behind (see _strip_one_quote_prefix) -- NOT a sum across
    every level: wv-ac22a5 finding 7 (external code review) made a
    tab-terminated level able to be immediately followed by a FURTHER
    quote marker rather than always ending the loop, so an EARLIER
    level's own residual tab can now be fully consumed/retired (no
    longer physically present anywhere in `content`) before the loop
    ends -- summing its now-irrelevant contribution on top of a later,
    still-actually-present tab's own would double the correction content
    doesn't need. Only the MOST RECENT delta can still describe a tab
    genuinely sitting at content[0] (or 0, when content has none at
    all); callers measuring `content`'s own indentation via the
    _relative_visual_* family must pass it through as that family's
    virtual_offset parameter, or a residual tab's leftover columns get
    double-counted as if the marker had never touched them at all.

    Deliberately does NOT strip indentation the way a blanket .strip()
    would -- CommonMark allows a fence opener at most 3 leading spaces
    (after any quote prefixes); 4+ is an indented code block, a DIFFERENT
    construct that must not be misrecognized as a fence just because
    dequoting erased the distinction. Each level's optional trailing
    space/tab is consumed the same way _strip_one_quote_prefix is (at
    most one), so any further indentation inside a quote (or, with no
    quote at all, the line's own leading whitespace) survives into
    `content` for the caller to check.
    """
    remainder = line
    depth = 0
    virtual_offset = 0
    while True:
        stripped = _strip_one_quote_prefix(line, remainder, virtual_offset)
        if stripped is None:
            return remainder, depth, virtual_offset
        depth += 1
        remainder, virtual_offset = stripped


def _dequote_exactly(line: str, levels: int) -> tuple[str, int]:
    """Strip EXACTLY `levels` leading blockquote prefixes -- no more.

    Unlike _dequote (fully recursive: strips every level it can), this
    stops after `levels`, leaving any FURTHER ">" as literal content. Used
    by an active leaf block (see _advance_html_block_state) to compute its
    own container-relative view: a block that opened at quote_depth N owns
    exactly N levels of quote prefix as its container -- a DEEPER ">" on a
    later line is verbatim block content (e.g. a literal ">" character
    inside an HTML comment), not a further container prefix to consume.
    Fully dequoting past N would make such a line look blank when it
    isn't, or hide real terminator text inside what's left.

    Returns (content, virtual_offset) -- see _dequote's own virtual_offset
    for what it means and why a raw suffix alone can't stand in for it.

    Callers must only pass `levels <= the line's own full _dequote depth`
    -- guaranteed by the caller already having checked quote_depth >=
    state.quote_depth before calling this, so every one of the `levels`
    strips is guaranteed to find a matching prefix.
    """
    remainder = line
    virtual_offset = 0
    for _ in range(levels):
        stripped = _strip_one_quote_prefix(line, remainder, virtual_offset)
        assert stripped is not None  # caller guarantees enough levels
        remainder, virtual_offset = stripped
    return remainder, virtual_offset


def _fence_probe_text(line: str) -> str:
    """Return line content with every leading blockquote prefix stripped."""
    return _dequote(line)[0]


def _valid_fence_open_match(probe: str) -> re.Match[str] | None:
    """Match a valid CommonMark fence opener at the start of `probe`, or None.

    _FENCE_OPEN_RE alone recognizes the marker run (0-3 leading spaces then
    3+ backticks or tildes) but not CommonMark's extra constraint on
    backtick fences specifically: the rest of the line (the info string)
    must not itself contain a backtick, or it would be ambiguous with an
    inline code span (e.g. "``` aa ```" is not a valid opener). Tilde
    fences have no such restriction -- their info string may contain
    backticks freely.
    """
    match = _FENCE_OPEN_RE.match(probe)
    if match is None:
        return None
    if match.group(1)[0] == "`" and "`" in probe[match.end() :]:
        return None
    return match


@dataclass
class _ListItemContext:
    """Tracks the currently open list item's own container identity.

    A continuation line belongs to this item only if it shares the SAME
    quote_depth the item's own marker line had (CommonMark: a list item's
    constituent lines all share its container prefix -- a different depth
    means a different container entirely, not this item continuing) AND,
    for an explicitly-marked ("quote") continuation line, is indented at
    least content_col COLUMNS (tab-expanded, see _visual_column -- NOT a
    raw character count) within that quote-depth-relative view (the
    marker's own visual width -- e.g. column 2 for "- ", column 3 for
    "1. ", but a tab in the marker's own padding can reach further). An
    UNMARKED ("lazy") continuation line needs no indentation of its own
    beyond that same membership check (see _pop_unowned_list_frames,
    which the caller always runs first) -- has_paragraph does not gate
    whether the line belongs to the item, only whether it CONTINUES an
    already-open paragraph or STARTS a fresh one within the item (see
    _list_item_continuation): "- outer\\n  -\\n    hidden\\n" -- "hidden"
    is indented enough to belong to the empty nested item, so it opens
    that item's own first paragraph, exactly as if it were the marker
    line's own first-line content. "-\\nvisible\\n" is different only
    because "visible" (column 0) is NOT indented enough to belong to the
    empty item at all -- membership excludes it before has_paragraph is
    ever consulted, making it a separate, unrelated paragraph instead.
    """

    quote_depth: int
    content_col: int
    has_paragraph: bool


@dataclass
class _FenceState:
    """Mutable fenced-code-block tracking shared by _advance_fence_state.

    list_content_col is the enclosing list item's own content_col (see
    _ListItemContext) if the fence opened while one was active, else
    None -- mirrors _HtmlBlockState.list_content_col: a fence owned by a
    list item ends when the item itself does (insufficient indentation
    for a non-blank line), the same as any other content of that item,
    not only via an explicit closing marker or quote-depth outdent.
    """

    char: str = ""
    length: int = 0
    quote_depth: int = 0
    list_content_col: int | None = None

    @property
    def open(self) -> bool:
        """True while inside an unclosed fence (a char is currently set)."""
        return bool(self.char)


def _advance_fence_state(
    state: _FenceState,
    quote_depth: int,
    probe: str,
    line: str,
    list_content_col: int | None,
    virtual_offset: int = 0,
    opener_probe: str | None = None,
) -> tuple[bool, bool]:
    """Advance fenced-code-block tracking for one line.

    Returns (in_code, just_opened) -- in_code is True when this line is
    fenced content or is itself the opening/closing fence marker; just_opened
    is True only on the line that opened the fence (callers that reflow
    paragraphs flush on this transition). Mutates `state` in place.

    A fence nested under a blockquote is scoped to the quote depth it
    opened at -- CommonMark code fences cannot be lazily continued, so an
    outdented line (lower quote_depth than the fence's own) means the
    blockquote containing it ended, and with it the still-open fence,
    WITHOUT an explicit closing marker. That outdented line is NOT fenced
    content (in_code=False) -- previously fence state tracked char/length
    only, so it survived past the container that opened it and swallowed
    unrelated prose after the blockquote ended.

    A deeper-nested line (quote_depth greater than the fence's own) is the
    opposite case: it's still INSIDE the fence's container, so it stays
    fenced content unconditionally -- the extra ">" is part of the fenced
    text verbatim, not markup introducing a nested blockquote with its own
    closer. An explicit close marker only counts at exactly the fence's
    own opening depth; checking the close pattern regardless of depth
    let a coincidental fence-shaped line one level deeper falsely end the
    outer fence and expose its remaining content as prose.

    A fence owned by a list item (list_content_col is not None on the
    OPENING call) additionally ends whenever a later non-blank line at
    the fence's own quote_depth is indented less than that content_col --
    e.g. a sibling list marker at column 0 -- BEFORE even checking
    whether it happens to look like a valid closing marker: a line that
    has already left the item isn't inside the fence's container at all
    anymore, so a coincidental fence-shaped match there doesn't close
    it, the same as it doesn't reopen a nested blockquote in the
    quote-depth-outdent case just above. Falls through the same way:
    the ending line may itself open something new at the outer level.

    virtual_offset is `probe`'s own _dequote virtual_offset (see there) --
    passed through to the indentation check below so a residual
    partially-consumed tab in `probe` isn't counted as if it started
    fresh at this container's own column 0.

    opener_probe (see _item_relative_view), when given, is used INSTEAD
    of `probe` for the closing-marker check (item-relative, keyed off
    the fence's OWN state.list_content_col) and the fresh-opener check
    below (item-relative, keyed off the caller's list_content_col
    argument) -- CommonMark requires a list-owned fence's own closer/
    opener to be recognized relative to the item's margin, not the bare
    quote-relative `probe` alone (see _item_relative_view). Defaults to
    `probe` itself, preserving prior behavior for a non-list-owned
    check, or a caller (_open_list_item) that already passes an
    item-relative `probe` directly for the item's own marker line.
    """
    if state.open:
        if quote_depth < state.quote_depth:
            # The container that opened this fence just ended without an
            # explicit closing marker (CommonMark fences don't lazily
            # continue past their container). Clear it, then fall through
            # to the normal opener check below instead of returning here --
            # THIS SAME physical line can simultaneously open a NEW fence in
            # the outer container (e.g. a line that both ends a blockquote
            # and starts a root-level fence). Returning unconditionally
            # here missed that: the line was never evaluated as a possible
            # opener at its own (lower) depth at all.
            state.char = ""
            state.length = 0
            state.quote_depth = 0
            state.list_content_col = None
        elif quote_depth == state.quote_depth:
            # An ASCII-blank probe is valid fence content on its own --
            # CommonMark decides list-item continuation from the NEXT
            # non-blank line's indentation, never from a blank line by
            # itself (see _ListItemContext) -- so a blank line must never
            # be read as "insufficiently indented" and close the fence
            # early. Only a non-blank line's own indentation can end a
            # list-owned fence this way, matching this function's own
            # docstring above.
            ends_via_indent = (
                state.list_content_col is not None
                and not _is_ascii_blank(probe)
                and _relative_visual_indent_width(line, probe, virtual_offset)
                < state.list_content_col
            )
            if ends_via_indent:
                state.char = ""
                state.length = 0
                state.quote_depth = 0
                state.list_content_col = None
                # Falls through, same reasoning as the outdent case above.
            else:
                # The closer's own "<=3 leading spaces" requirement is
                # relative to the fence's CONTAINER -- for a list-owned
                # fence that's the item's own margin (state's OWN
                # list_content_col, not the caller's opener_probe: that
                # reflects the CALLER's current context, which may not
                # be this fence's owner in every case, e.g. a deeper
                # nested item's own fence still open while a shallower
                # ancestor is what currently owns this line) -- see
                # _item_relative_view. Not list-owned (list_content_col
                # is None): still needs wv-98984a's quote-tab-residual
                # materialization -- see _structural_match_view.
                closer_probe = _structural_match_view(
                    line, probe, state.list_content_col, virtual_offset
                )
                closer_re = rf"^ {{0,3}}{re.escape(state.char)}{{{state.length},}}\s*$"
                if re.match(closer_re, closer_probe):
                    state.char = ""
                    state.length = 0
                    state.quote_depth = 0
                    state.list_content_col = None
                return True, False
        else:
            return True, False
    fence_match = _valid_fence_open_match(opener_probe if opener_probe is not None else probe)
    if fence_match:
        state.char = fence_match.group(1)[0]
        state.length = len(fence_match.group(1))
        state.quote_depth = quote_depth
        state.list_content_col = list_content_col
        return True, True
    return False, False


@dataclass
class _HtmlBlockState:
    """Mutable CommonMark HTML-block tracking, analogous to _FenceState.

    Unlike a fence (one open/close char+length pair), an HTML block's
    continuation rule depends on which of the 7 start conditions opened
    it: types 1-5 continue through their own terminator regex (checked
    anywhere on the line, not just at its start); types 6 and 7 have no
    terminator regex at all -- they continue until a blank line (or their
    container ends, same as every type). terminator is None for an active
    type-6/7 block, distinguishing it from "nothing open" (`active`).

    list_content_col is the enclosing list item's own content_col (see
    _ListItemContext) if the block opened while one was active, else
    None -- a block owned by a list item ends when the item itself does
    (insufficient indentation for a non-blank line), the same as any
    other content of that item; a block with no owning item is scoped to
    quote_depth alone.
    """

    active: bool = False
    terminator: re.Pattern[str] | None = None
    quote_depth: int = 0
    list_content_col: int | None = None


def _try_open_html_block(
    state: _HtmlBlockState,
    quote_depth: int,
    probe: str,
    _container: str,
    list_content_col: int | None,
    opener_probe: str | None = None,
    type7_no_open_paragraph: bool = True,
) -> bool:
    """Try to open a new HTML block from `probe`; returns whether one did.

    Factored out of _advance_html_block_state so a list item's own FIRST
    line of content (probe already stripped of both quote prefix and the
    marker itself, checked directly against this) can also start an HTML
    block, not just a line whose leaf-block content happens to begin at
    column 0 of a fresh physical line -- CommonMark: a list item's content
    is itself a leaf/container block start, checked exactly like a bare
    one after its container markers are stripped.

    opener_probe (see _item_relative_view), when given, is used INSTEAD
    of `probe` for the types 1-6 (and, since wv-5ef426 finding 2, type 7)
    opener match -- a list-owned CONTINUATION line (unlike the item's own
    marker line, whose caller already passes an item-relative `probe`
    directly) needs its own margin folded out the same way before an
    opener at "<=3 leading spaces relative to the item" can be
    recognized. Defaults to `probe`, preserving prior behavior when
    there's no owning item to fold out.

    type7_no_open_paragraph (see _no_open_paragraph_to_protect, wv-1ccd09)
    is the CALLER's own fully-resolved answer to "is there nothing -- no
    root/quote paragraph, no owned item's paragraph, and no just-popped
    item a lazy reattachment would still protect -- standing in the way
    of type 7 opening here". Type 7 (a bare, complete open/close tag)
    cannot interrupt ANY open paragraph. Resolved by the caller, not
    re-derived here from `_container`/list_content_col alone, because the
    "just-popped but still laziness-protected" case (wv-1ccd09) needs
    information (the pre-pop stack) this function was never given.
    """
    match_probe = opener_probe if opener_probe is not None else probe
    for _html_type, open_re, close_re in _HTML_BLOCK_OPENERS:
        if not open_re.match(match_probe):
            continue
        if _html_type == 2 and (
            _VERBATIM_EXEMPT_START_RE.search(probe) or _VERBATIM_EXEMPT_END_RE.search(probe)
        ):
            # This module's own verbatim marker is syntactically a type-2
            # HTML comment, but is deliberately never treated as a real
            # HTML block -- see _paragraph_interrupt_kind's prior
            # docstring note (now here): the marker's own line must stay
            # ordinary inline text so _verbatim_exempt_lines' masking (a
            # marker merely MENTIONED inside real code must not activate
            # it) keeps working, and so the marker itself is never hidden
            # as suppressed HTML-block content either.
            continue
        state.quote_depth = quote_depth
        state.list_content_col = list_content_col
        if close_re is not None and close_re.search(probe):
            # Opens and terminates on the same physical line (e.g. a
            # one-line "<!-- comment -->") -- this line is still HTML
            # content, but nothing carries forward to the next line.
            state.active = False
            state.terminator = None
        else:
            state.active = True
            state.terminator = close_re
        return True
    if type7_no_open_paragraph and _html_type7_start_matches(match_probe):
        # Type 7 cannot interrupt an open paragraph (see this function's
        # own docstring for what type7_no_open_paragraph resolves) and,
        # like type 6, ends at a blank line rather than a terminator
        # regex -- self-terminating is meaningless for it (an open/close
        # tag alone on a line has nothing further to search for).
        state.active = True
        state.terminator = None
        state.quote_depth = quote_depth
        state.list_content_col = list_content_col
        return True
    return False


def _advance_html_block_state(
    state: _HtmlBlockState,
    quote_depth: int,
    probe: str,
    line: str,
    container: str,
    list_content_col: int | None,
    opener_probe: str | None = None,
    type7_no_open_paragraph: bool = True,
) -> tuple[bool, bool]:
    """Advance CommonMark HTML-block tracking for one line.

    Returns (in_html, just_opened) -- in_html is True when this line is
    HTML-block content (including its own opening or terminating line);
    just_opened is True only on the line that opened the block (callers
    that reflow paragraphs flush on this transition, same as
    _advance_fence_state's just_opened). Mutates `state` in place.

    Checked by both consumers BEFORE _paragraph_interrupt_kind is even
    called, exactly parallel to _advance_fence_state -- HTML block
    detection (open AND continuation) is entirely self-contained here,
    not part of the paragraph-interrupt classifier.

    Quoted HTML blocks are scoped to the quote depth they opened at, the
    same as a fence (see _advance_fence_state's own docstring for the
    full reasoning): an outdented line means the container that opened
    the block just ended, closing it WITHOUT its own terminator, and
    falls through to a fresh opener check at the new (lower) depth on
    that SAME line. A deeper-nested line stays block content
    unconditionally -- the extra ">" is verbatim, not a new container.

    A block owned by a list item (list_content_col is not None on the
    OPENING call -- see _HtmlBlockState) additionally ends whenever a
    later non-blank line is indented less than that content_col -- e.g. a
    sibling list marker at column 0, or any other line that isn't part of
    the owning item anymore. Falls through the same way an outdent does:
    the ending line may itself open something new at the outer level.
    """
    if state.active:
        if quote_depth < state.quote_depth:
            state.active = False
            state.terminator = None
            state.quote_depth = 0
            state.list_content_col = None
            # Fall through to the opener check below -- this line may
            # simultaneously close the block (container ended) AND open a
            # new one at its own, shallower depth.
        else:
            # The block's own container is exactly state.quote_depth
            # levels of quote prefix -- strip EXACTLY that many (not the
            # fully-recursive `probe`, which may have stripped further,
            # unrelated levels this line happens to also carry). A DEEPER
            # ">" beyond the block's own depth is literal block content
            # (e.g. a literal ">" inside an HTML comment), not another
            # container prefix, and must not be mistaken for a blank line
            # or hidden from a terminator search.
            block_relative, block_virtual_offset = _dequote_exactly(line, state.quote_depth)
            if _is_ascii_blank(block_relative):
                if state.terminator is None:
                    # type 6/7: no terminator regex, ends at a blank line
                    # (the blank line itself isn't block content).
                    state.active = False
                    state.quote_depth = 0
                    state.list_content_col = None
                    return False, False
                return True, False  # types 1-5: a blank line is ordinary content
            ends_via_indent = state.list_content_col is not None and (
                _relative_visual_indent_width(line, block_relative, block_virtual_offset)
                < state.list_content_col
            )
            if ends_via_indent:
                state.active = False
                state.terminator = None
                state.quote_depth = 0
                state.list_content_col = None
                # Falls through to the opener check below, same reasoning
                # as the outdent case above -- this line ends the owning
                # item (and so the block it owned), but may itself open
                # something new.
            else:
                if state.terminator is not None and state.terminator.search(block_relative):
                    state.active = False
                    state.terminator = None
                    state.quote_depth = 0
                    state.list_content_col = None
                return True, False
    if _try_open_html_block(
        state, quote_depth, probe, container, list_content_col, opener_probe, type7_no_open_paragraph
    ):
        return True, True
    return False, False


def _advance_block_states(
    fence_state: _FenceState,
    html_state: _HtmlBlockState,
    quote_depth: int,
    probe: str,
    line: str,
    container: str,
    list_content_col: int | None = None,
    virtual_offset: int = 0,
    opener_probe: str | None = None,
    type7_no_open_paragraph: bool = True,
) -> tuple[bool, bool]:
    """Advance fenced-code and HTML-block tracking together for one line.

    The two are mutually exclusive at any given moment -- real CommonMark
    checks fenced code and HTML block as separate, ordered leaf-block-start
    conditions, so a line can never belong to both at once. Whichever
    state is ALREADY active continues exclusively (its own continuation
    content -- e.g. a "```"-looking line inside an active HTML block, or
    an HTML-looking line inside an open fence -- must never be
    reinterpreted as the OTHER construct's opener); when neither is
    active, fenced code is checked first (its real CommonMark priority),
    then HTML block only if no fence opened here.

    list_content_col (see _HtmlBlockState / _FenceState) is the currently
    open list item's own content_col, if any -- passed through to a
    newly-opened fence or HTML block so it also ends when that item
    does, not just via quote-depth outdent (or, for a fence, an explicit
    closing marker). virtual_offset is `probe`'s own _dequote virtual_offset
    -- passed to _advance_fence_state's own indentation check (the HTML
    path recomputes its own via _dequote_exactly instead, since its
    container-relative view is scoped to state.quote_depth, which may
    differ from `probe`'s full depth).

    Returns (in_block, just_opened) -- the union of whichever construct's
    own signature applies; callers that already treat "in fenced code" as
    a single opaque "skip this line" signal need nothing more specific.

    opener_probe (see _item_relative_view) is passed through to both
    the fence and HTML opener checks -- a list-owned continuation line's
    own leaf-block opener must be recognized relative to the item's
    margin, not `probe`'s bare quote-relative view alone.

    type7_no_open_paragraph (wv-5ef426 finding 2, generalized by wv-1ccd09)
    is the caller's own fully-resolved "nothing protects this line from a
    type-7 interrupt" answer (see _no_open_paragraph_to_protect) -- passed
    through to the HTML path alone (see _try_open_html_block): type 7
    cannot interrupt any open paragraph, list-owned, root-level, or just-
    popped-but-still-laziness-protected, unlike a fence (no such
    restriction at all) or types 1-6 (already unconditional here too).
    """
    if html_state.active:
        return _advance_html_block_state(
            html_state,
            quote_depth,
            probe,
            line,
            container,
            list_content_col,
            opener_probe,
            type7_no_open_paragraph,
        )
    fence_in_code, just_opened_fence = _advance_fence_state(
        fence_state, quote_depth, probe, line, list_content_col, virtual_offset, opener_probe
    )
    if fence_in_code:
        return True, just_opened_fence
    return _advance_html_block_state(
        html_state,
        quote_depth,
        probe,
        line,
        container,
        list_content_col,
        opener_probe,
        type7_no_open_paragraph,
    )


_BACKTICK_RUN_RE = re.compile(r"`+")


def _mask_inline_code(line: str, open_run_len: int = 0) -> tuple[str, int, bool, str]:
    """Replace CommonMark inline-code span content with a neutral filler.

    Approximates CommonMark's inline-code rule: an opening run of N
    backticks is closed by the next run of exactly N backticks; an opening
    run with no matching close anywhere in the document is literal text, not
    a code span. Used to keep a verbatim-marker directive from being
    recognized when it's merely being *mentioned* inside inline code (e.g.
    documentation about the marker itself), not written as a real
    standalone directive line.

    open_run_len carries an unmatched opening backtick run's length in from
    a previous physical line in the same paragraph (0 if none) -- CommonMark
    code spans may cross physical lines, and their content (including the
    embedded line break) must stay masked on every line they touch, not just
    the line the opening run appears on. Returns (masked_line, open_run_len,
    incoming_closed, literal_replay):
      - open_run_len is the run length to carry into the next line (0 once
        nothing is left open at the end of this line).
      - incoming_closed is True iff the run carried IN (the `open_run_len`
        argument) found its matching close on this line -- distinct from the
        returned open_run_len, which may already reflect a brand NEW run
        opened later on this same line. A caller tracking a buffer of lines
        under the incoming run needs to know it closed even when a fresh one
        immediately reopens, or it can't tell "the old span legitimately
        ended here" from "still the same unresolved span, unrelated to any
        new backticks later on this line".
      - literal_replay is what to use INSTEAD of masked_line if the run left
        open at the end of this call (open_run_len above) never closes: the
        text up to where that unresolved run started stays exactly as
        masked_line already has it (a run that closed earlier on THIS same
        line, or one carried in from an earlier line, is proven code either
        way and must stay masked even if a later, separate run on this line
        never resolves) -- only the unresolved run's own suffix reverts to
        raw. Equals masked_line when open_run_len is 0 (nothing pending).
    Callers must reset open_run_len to 0 at block boundaries (blank lines,
    fences, indented code, headings, list items, blockquote depth changes)
    -- a code span cannot cross those.
    """
    out = list(line)
    pos = 0
    incoming_closed = False
    if open_run_len:
        close = re.search(rf"(?<!`)`{{{open_run_len}}}(?!`)", line)
        if close is None:
            # Still inside the open span for its entire length on this
            # line -- if it never closes, none of this line was ever code.
            return "\0" * len(line), open_run_len, False, line
        for i in range(close.end()):
            out[i] = "\0"
        pos = close.end()
        open_run_len = 0
        incoming_closed = True
    if "`" not in line[pos:]:
        resolved = "".join(out)
        return resolved, 0, incoming_closed, resolved
    masked_until = pos
    for run in _BACKTICK_RUN_RE.finditer(line, pos):
        if run.start() < masked_until:
            continue  # inside an already-masked span
        run_len = len(run.group(0))
        close = re.search(rf"(?<!`)`{{{run_len}}}(?!`)", line[run.end():])
        if close is None:
            # Unmatched on this line -- may still close on a later physical
            # line, so mask speculatively through EOL and carry the run
            # length forward. If THIS run never closes, only its own
            # suffix (from run.start() onward) reverts to literal --
            # everything before it (including an incoming run that DID
            # close earlier on this same line) stays masked/proven.
            for i in range(run.start(), len(line)):
                out[i] = "\0"
            masked = "".join(out)
            literal_replay = masked[: run.start()] + line[run.start() :]
            return masked, run_len, incoming_closed, literal_replay
        span_end = run.end() + close.end()
        for i in range(run.start(), span_end):
            out[i] = "\0"
        masked_until = span_end
    resolved = "".join(out)
    return resolved, 0, incoming_closed, resolved


def _quote_depth_is_boundary(quote_depth: int, prior_quote_depth: int) -> bool:
    """Shared by both _scan_lines and _verbatim_exempt_lines: an explicit
    ">" line always states its own nesting depth -- entering deeper (a
    child blockquote) or leaving shallower is a genuine block change and
    starts a fresh container/paragraph unit, but two consecutive explicit
    quote lines at the SAME depth are the ordinary (non-lazy) continuation
    of one blockquote paragraph and must not be split apart.
    """
    return quote_depth != prior_quote_depth


def _is_ascii_blank(text: str) -> bool:
    """CommonMark: a blank line contains nothing, or only spaces/tabs.

    NOT text.strip() (used previously) or a bare regex \\s class -- both
    also treat other Unicode whitespace (e.g. NBSP, U+00A0) as blank,
    which CommonMark does not: an NBSP-only line is a non-blank line
    consisting of one non-space character, not a paragraph/block boundary.
    """
    return text.strip(" \t") == ""


def _visual_column(text: str, char_index: int) -> int:
    """CommonMark's visual column reached after `text[:char_index]`.

    A tab advances to the NEXT multiple of 4 (a tab stop), not one
    column like every other character -- "\\t" alone reaches column 4,
    "-\\t" reaches column 4 too (the "-" takes column 1, then the tab
    jumps from 1 to the next stop). Used for STRUCTURAL indentation
    comparisons (list-item content columns, continuation indentation)
    -- never for source-position character offsets, which count raw
    characters regardless of what column they visually land on.
    """
    col = 0
    for ch in text[:char_index]:
        col += 4 - (col % 4) if ch == "\t" else 1
    return col


def _char_index_for_column(text: str, target_col: int) -> int:
    """Inverse of _visual_column: the character index at which the visual
    column first reaches (or would need to pass) `target_col`.

    Used to convert a structural content_col (a visual column) back into
    a character offset for slicing/extraction -- content_col itself must
    never be used as a character index directly when tabs are involved.
    Callers only pass a `target_col` already known to be <= this text's
    own indent width, so the loop always finds an exact or overshooting
    match before falling off the end. Most callers want the CONTAINER-
    RELATIVE variant, _char_index_for_relative_column, below.
    """
    col = 0
    for i, ch in enumerate(text):
        if col >= target_col:
            return i
        col += 4 - (col % 4) if ch == "\t" else 1
    return len(text)


def _relative_visual_column(
    line: str, stripped: str, char_index: int, virtual_offset: int = 0
) -> int:
    """CommonMark visual column of `stripped[:char_index]`'s end, with tab
    stops ABSOLUTE across the full physical `line` -- NOT restarted at
    zero where `stripped` begins.

    `stripped` must be a suffix of `line` (_dequote's probe, or a
    quote-depth-relative view via _dequote_exactly). A container prefix
    (blockquote markers, list marker padding) was physically present at
    some nonzero column, and a tab inside `stripped` advances relative
    to THAT true position -- e.g. "> -\\titem": the tab sits at physical
    column 3 (after "> " at columns 0-1 and "-" at column 2), so it
    advances only to column 4, not to column 4 as measured from a
    fictitious column 0 within the 2-space-narrower "-\\titem" alone
    (which would already BE column 4, coincidentally the same answer
    only because the prefix here happens to be short -- a longer or
    tab-containing prefix would diverge). The result is still
    container-RELATIVE (the prefix's own absolute width is subtracted
    back out) -- only the intermediate tab-stop arithmetic needs the
    absolute view; source-position character offsets are unaffected and
    stay computed separately, never through this function.

    virtual_offset (see _dequote/_dequote_exactly) is the number of
    visual columns a partially-consumed tab already contributed to some
    quote marker ABOVE `stripped`'s own start -- `stripped` still
    contains that tab character whole (it can't be half-stripped), so the
    raw prefix-relative arithmetic above overcounts its full tab-stop
    width by exactly that many columns unless subtracted back out here.
    0 for any `stripped` that came from a plain space-only prefix (or no
    quote prefix at all), the overwhelmingly common case.
    """
    prefix_width = len(line) - len(stripped)
    return (
        _visual_column(line, prefix_width + char_index)
        - _visual_column(line, prefix_width)
        - virtual_offset
    )


def _relative_visual_indent_width(line: str, stripped: str, virtual_offset: int = 0) -> int:
    """Container-relative visual column of `stripped`'s first non-space/
    non-tab character -- see _relative_visual_column."""
    indent_chars = len(stripped) - len(stripped.lstrip(" \t"))
    return _relative_visual_column(line, stripped, indent_chars, virtual_offset)


def _char_index_for_relative_column(
    line: str, stripped: str, target_col: int, virtual_offset: int = 0
) -> int:
    """Inverse of _relative_visual_column: the character index WITHIN
    `stripped` at which its container-relative visual column first
    reaches `target_col`."""
    prefix_width = len(line) - len(stripped)
    absolute_target = _visual_column(line, prefix_width) + target_col + virtual_offset
    return _char_index_for_column(line, absolute_target) - prefix_width


def _item_relative_view(
    line: str, probe: str, content_col: int | None, virtual_offset: int = 0
) -> str:
    """Consume content_col's own worth of indentation from `probe`
    (already quote-dequoted), returning the item-relative remainder.

    CommonMark checks a list item's OWN leaf-block openers and closers
    (a fence, an HTML block) relative to the item's own margin, not the
    quote-relative view alone: an opener/closer genuinely valid at 0-3
    columns WITHIN the item (e.g. a continuation line's own "```" right
    at the item's content_col) looks like it's indented content_col+
    columns from `probe`'s own zero point once the item's margin is
    folded in -- which is 4+ for any real item, wrongly failing
    CommonMark's "<=3 leading spaces" leaf-block-open/close requirement
    and leaving the opener/closer unrecognized as prose or fenced
    content it shouldn't be.

    Returns `probe` unchanged when content_col is None -- nothing owns
    this line, so it's already correctly quote-relative with nothing
    further to consume.

    Tab-safe in the same sense _char_index_for_column already is: a tab
    straddling the cut is consumed WHOLE (never split mid-character),
    the same accepted imprecision _open_list_item's own marker-content
    extraction already has for a marker whose own padding contains one.
    """
    if content_col is None:
        return probe
    return probe[_char_index_for_relative_column(line, probe, content_col, virtual_offset) :]


def _materialize_quote_tab(line: str, probe: str, virtual_offset: int) -> str:
    """Materialize a quote-residual leading tab in `probe` into literal
    spaces, for STRUCTURAL regex matching only (heading/break/list-
    marker/fence/HTML opener AND closer patterns, which all require
    LITERAL space characters -- "^ {0,3}..." -- to recognize <=3 columns
    of leading indentation; a raw tab is never read as indentation by
    them at all, only as an instant disqualifier).

    _dequote's virtual_offset (see there) already repairs COLUMN
    arithmetic (_relative_visual_column and friends) for a partially-
    consumed blockquote tab -- but it leaves the tab CHARACTER itself
    untouched in `probe` (a tab can't be split mid-character), so a
    structural regex matching probe's raw text directly never sees the
    RESIDUAL columns that same tab still represents beyond the quote
    marker's own consumption: ">\\t- item" -- the tab's own visual width
    from ITS OWN physical column is 3, 1 of which belongs to the quote
    marker (virtual_offset), leaving 2 residual columns before "- item"
    -- well within CommonMark's "<=3" leaf-block-start allowance, but
    unrecognized as indentation at all by a bare regex, which only ever
    sees ONE raw tab character sitting directly against the marker.

    Returns `probe` UNCHANGED whenever there is nothing to materialize:
    virtual_offset <= 0 (no partially-consumed tab at all) or `probe`
    doesn't start with a tab -- _dequote only ever leaves AT MOST one
    such residual tab, as probe[0], and only when virtual_offset > 0
    (see _strip_one_quote_prefix: a residual tab breaks any FURTHER
    quote-marker match, so it can never end up buried mid-probe, and a
    fully-consumed space prefix never sets virtual_offset at all).

    Only the LEADING tab is replaced -- any further raw whitespace or
    content after it is untouched, exactly as literal leading
    indentation already is. NOT source-position safe: the returned
    string may be LONGER than `probe` (one tab character becomes 0-3
    space characters) -- a caller matching a POSITION-sensitive regex
    (list-marker content extraction, e.g. _open_list_item's own
    structural_delta parameter) against this view must translate any
    resulting match position back by
    (len(materialized) - len(probe)) before using it against `probe`/
    `line`; a caller only checking match-or-not, or extracting a
    captured GROUP (a substring, position-independent), needs no
    translation at all.
    """
    if virtual_offset <= 0 or not probe.startswith("\t"):
        return probe
    residual = _relative_visual_column(line, probe, 1, virtual_offset)
    return (" " * residual) + probe[1:]


def _structural_match_view(
    line: str, probe: str, list_content_col: int | None, virtual_offset: int = 0
) -> str:
    """The correct view of `probe` for STRUCTURAL regex matching (fence/
    HTML opener and closer, list-marker, heading, break) -- item-relative
    (_item_relative_view) when the line is list-owned (list_content_col
    is not None), else quote-tab-residual-materialized
    (_materialize_quote_tab) when it isn't.

    The two folding layers are selected here, not composed -- but a
    residual quote-tab on a line that's ALSO list-owned (e.g. a quoted
    list item whose own continuation line's OWN quote marker happens to
    end in a tab) needs no separate handling anyway: _item_relative_view
    slices `probe` at content_col's own char index, computed via
    _char_index_for_relative_column, which already folds virtual_offset
    into the ABSOLUTE target column it searches for -- the residual tab
    (always probe[0], a single atomic character) sits entirely BEFORE
    that slice point for any real item (content_col is always >= 2, a
    bare "-" item's own minimum), so it's always consumed as part of
    "content_col's worth of indentation" and never survives into the
    sliced remainder to need materializing at all. Verified by
    construction across the content_col/virtual_offset extremes (a
    tight content_col=2 item, and the maximum possible residual of 3)
    -- wv-98984a's own closing review raised this as a plausible gap;
    confirmed NOT a real one before writing this comment, not assumed.
    """
    if list_content_col is not None:
        return _item_relative_view(line, probe, list_content_col, virtual_offset)
    return _materialize_quote_tab(line, probe, virtual_offset)


def _paragraph_interrupt_kind(
    line: str,
    probe: str,
    quote_depth: int,
    container: str,
    virtual_offset: int = 0,
    list_content_col: int | None = None,
    list_has_paragraph: bool = False,
) -> str:
    """Classify one line against CommonMark's paragraph-interrupt rules.

    Shared by _scan_lines (paragraph reflow) and _verbatim_exempt_lines
    (inline-code-span boundary tracking) so both agree on exactly the same
    set of lines that can or cannot interrupt -- or lazily continue -- an
    open paragraph. Each used to approximate this independently, and could
    disagree on where a boundary actually falls. Callers are expected to
    have already handled fenced-code continuation via _advance_fence_state
    before calling this; it classifies only what's left.

    Returns one of:
      "blank"   -- an empty (or whitespace-only) CONTAINER-RELATIVE line --
                   checked against `probe`, not the raw line, so an
                   explicit quote marker with nothing else on it
                   ("> " alone) is blank too, the same as CommonMark's own
                   "blockquote containing a blank line" rule. Always a
                   boundary.
      "code"    -- 4+ leading spaces or a leading tab, with NO paragraph
                   currently open to continue (container == "", or a list
                   item at list_content_col with list_has_paragraph
                   False): indented code. CommonMark: indentation can
                   START a code block, but cannot INTERRUPT an
                   already-open paragraph -- with a paragraph open, the
                   same line classifies "lazy" instead, preserving it as
                   ordinary continuation text.
      "heading" -- an ATX heading. Always a boundary.
      "break"   -- a thematic break. Always a boundary.
      "list"    -- a list item ELIGIBLE to start or extend a list: always
                   eligible when nothing is open (container == "") or a
                   list is already open (container == "list") -- including
                   one nested inside a blockquote, at any depth. Eligible
                   to INTERRUPT an open paragraph (container in
                   ("plain", "quote")) only when unordered, or ordered
                   starting at 1, AND non-blank (a marker with no content
                   at all). CommonMark: an out-of-range ordered start, or a
                   blank first item, cannot interrupt a paragraph -- such a
                   line classifies "quote"/"lazy" instead, its marker kept
                   as ordinary text rather than being read as a real one.
      "quote"   -- an explicit ">"-prefixed line, at `quote_depth`, that
                   isn't itself a heading/break/eligible-list start.
      "lazy"    -- everything else: an unmarked line -- including a
                   non-interrupting list marker, and indentation with a
                   paragraph already open -- that continues whatever
                   paragraph (if any) is currently open, or starts a fresh
                   one if nothing was (container == "").

    Note: HTML block starts are NOT classified here, unlike heading/break/
    list -- they're stateful (a block continues across multiple lines
    until its own type-specific terminator, see _HtmlBlockState /
    _advance_html_block_state), so opener detection lives entirely in that
    state machine, checked by callers BEFORE this classifier is even
    invoked -- exactly parallel to how fenced-code detection (also
    stateful) is handled by _advance_fence_state, never by this function.

    Every check below -- indentation included -- runs against `probe` (the
    fully quote-dequoted line), not the raw `line`: CommonMark measures a
    block start's indentation, and recognizes a heading/break/list marker,
    relative to the CONTAINER a line is part of, i.e. after any blockquote
    prefixes are stripped, not from the true start of the raw physical
    line. A marker nested inside a blockquote (a heading, a thematic
    break, a list item, or 4+ content spaces of indentation, all AFTER the
    ">" prefix) is recognized the same way a bare one is, in the same
    coordinate system -- and, for heading/break/list, takes priority over
    the generic "quote" fallback: any of them interrupts its enclosing
    quoted paragraph the same as any other paragraph.

    list_content_col (see _item_relative_view), when this line is still
    owned by an open list item (container == "list", membership already
    established by the caller -- see _pop_unowned_list_frames), is that
    item's own content_col: the blank and indented-code checks below run
    against the item-relative view instead of the bare quote-relative
    `probe` alone -- CommonMark measures a list item's own indented-code
    threshold relative to the item's margin, the same reasoning
    _item_relative_view already established for fence/HTML opener/closer
    detection (see wv-ef574e) -- an item-relative code start at 4+
    columns WITHIN the item looks like content_col+4 columns from
    `probe`'s own zero point otherwise, wrongly failing CommonMark's own
    "<=3 leading spaces" leaf-block-start requirement and leaving it
    unrecognized as ordinary lazy prose text instead (wv-5ef426 finding
    1). None (the default) preserves prior root/quote-relative behavior
    exactly. Deliberately NOT extended to the heading/break/list checks
    just below (they stay on the bare `probe`, matching prior behavior
    exactly): recognizing THOSE relative to an item's margin is a real,
    separate gap (an item-owned heading/break/nested-list-marker beyond
    3 raw columns is equally unrecognized today) -- still out of scope,
    unrelated to this function's own classification.

    wv-784f03 (external code review round 3, finding 1): a DIFFERENT gap
    this docstring used to conflate with the one above has since been
    fixed -- every "heading"/"break"-kind dispatch (_scan_lines,
    _scan_lines_raw, _verbatim_container_transition) used to
    unconditionally discard list_stack even when a partial nested-list
    pop left a surviving OUTER owner, the same ownership-destroying bug
    already fixed for "code" in each of those. All three now
    preserve/restore that surviving owner instead.
    """
    structural_probe = _structural_match_view(line, probe, list_content_col, virtual_offset)
    if _is_ascii_blank(structural_probe):
        return "blank"
    if structural_probe.startswith("    ") or structural_probe.startswith("\t"):
        no_open_paragraph = container == "" if list_content_col is None else not list_has_paragraph
        return "code" if no_open_paragraph else "lazy"
    # wv-98984a: heading/break/list-marker recognition also needs the
    # quote-tab-residual materialization when NOT list-owned --
    # structural_probe already IS that materialized view in this case
    # (_structural_match_view only applies item-relative folding when
    # list_content_col is not None) -- but deliberately keeps using the
    # bare, un-folded `probe` when list-owned, matching wv-5ef426's own
    # deliberate decision not to extend ITEM-relative recognition to
    # these three checks (see this function's own docstring above).
    quote_tab_probe = structural_probe if list_content_col is None else probe
    if _MARKDOWN_HEADING_RE.match(quote_tab_probe):
        return "heading"
    if _THEMATIC_BREAK_RE.match(quote_tab_probe):
        return "break"
    list_match = _MARKDOWN_LIST_RE.match(quote_tab_probe)
    if list_match is not None:
        interrupting_paragraph = container in ("plain", "quote")
        if not interrupting_paragraph:
            return "list"
        ordered_match = _MARKDOWN_ORDERED_START_RE.match(quote_tab_probe)
        starts_at_one = ordered_match is None or ordered_match.group(1) == "1"
        if starts_at_one and list_match.group(1).strip():
            return "list"
    if quote_depth > 0:
        return "quote"
    return "lazy"


def _verbatim_container_transition(
    fence_state: _FenceState,
    html_state: _HtmlBlockState,
    kind: str,
    line: str,
    probe: str,
    quote_depth: int,
    container: str,
    list_stack: list[_ListItemContext],
    prior_quote_depth: int,
    virtual_offset: int = 0,
) -> tuple[str, int, bool, bool]:
    """Compute _verbatim_exempt_lines' next (container, prior_quote_depth,
    resets_span, opened_html_from_list) from one line's kind -- mirrors
    _scan_lines' own container transitions exactly (see each kind's own
    reasoning there, including _ListItemContext/_open_list_item/
    _list_item_continuation/_restore_owned_list_stack), just without a
    paragraph to build: this only tracks which span-masking boundary
    state applies, never actual reflowed content.

    `list_stack` is mutated in place (pushed/popped/cleared) rather than
    threaded through the return value -- the caller already holds the
    same list reference, and every enclosing ancestor frame (not just
    the innermost item) must survive a transition that doesn't truly end
    the list, the same as _scan_lines' own stack.
    """
    if kind == "blank":
        _, container = _restore_owned_list_stack(list_stack, clear_has_paragraph=True)
        return container, 0, True, False
    if kind in ("heading", "break"):
        # wv-784f03 (external code review round 3, finding 1): this
        # docstring used to claim a genuine "heading"/"break" kind can
        # only ever reach this point already unowned -- false. That
        # reasoning conflated two separate things: _paragraph_interrupt_
        # kind's heading/break RECOGNITION does stay on the bare
        # quote-relative probe when list-owned (still true, still out of
        # scope -- see its own docstring), but the caller's pre-call pop
        # (_pop_unowned_list_frames, same as "code" just below) can leave
        # a surviving OUTER owner after only a PARTIAL pop even when the
        # line in front of it classifies as "heading"/"break". Mirrors
        # "code"'s own branch: ends the owning item's CURRENTLY open
        # paragraph, never the item itself.
        if list_stack:
            list_stack[-1].has_paragraph = False
            return "list", 0, True, False
        list_stack.clear()
        return "", 0, True, False
    if kind == "code":
        if list_stack:
            # wv-ac22a5 finding 6 (external code review): item-relative
            # indented code (wv-5ef426 finding 1) ends the OWNING item's
            # CURRENTLY open paragraph, not the item itself -- list_stack
            # is truthy here only when the caller's own pre-call pop
            # left an owning item in place (see _verbatim_exempt_lines),
            # so unconditionally clearing unconditionally destroyed a
            # still-legitimately-open item's identity, and a LATER item-
            # owned HTML/fence block on a following line became falsely
            # root-owned with no indentation-based ending, silently
            # swallowing all remaining content to EOF. Mirrors
            # _scan_lines_raw's own owns_line-aware "code" dispatch.
            list_stack[-1].has_paragraph = False
            return "list", 0, True, False
        return "", 0, True, False
    if kind == "list":
        # A list marker always starts its OWN block/paragraph -- even two
        # consecutive items are separate blocks in CommonMark, so a span
        # can never cross INTO one -- but unlike code/blank/heading/
        # break, what it starts is an open container ("list", mirroring
        # _scan_lines), not a fresh "" state: a following lazy
        # continuation line of THIS item's own paragraph must not be
        # treated as its own boundary too, or a multiline code span
        # opened on the marker line and closed on its own continuation
        # line gets wrongly split apart.
        # wv-98984a: a marker immediately preceded by a residual quote-
        # tab (">\t- item") is unrecognizable against probe's own
        # literal tab character -- match against the materialized view
        # instead (a no-op when there's nothing to materialize), and
        # translate the resulting position back for _open_list_item.
        structural = _materialize_quote_tab(line, probe, virtual_offset)
        list_match = _MARKDOWN_LIST_RE.match(structural)
        assert list_match is not None  # kind=="list" implies a marker match
        # A list item's own first-line content is itself a leaf-block
        # start position (see _open_list_item) -- a fence or HTML opener
        # there owns a block that must suppress marker-search the same
        # as any other, not treat the marker line's own text as
        # searchable.
        new_ctx, _content, _source_col, opened_html_from_list = _open_list_item(
            fence_state,
            html_state,
            list_match,
            line,
            probe,
            quote_depth,
            virtual_offset,
            len(structural) - len(probe),
        )
        # list_stack is already trimmed to its owning ancestor chain --
        # the caller pops unowned frames (see _pop_unowned_list_frames)
        # before this line's kind is even known -- so nesting the new
        # item under whatever survives, instead of discarding it, is
        # exactly the fix that pop exists for.
        #
        # wv-ac22a5 finding 5 (external code review): a nested marker
        # always interrupts the SURVIVING parent's own currently-open
        # paragraph the same way a blank line or newly-opened leaf block
        # does (see _scan_lines' identical _restore_owned_list_stack(
        # clear_has_paragraph=True) call for its own "list" dispatch) --
        # left uncleared here, a stale has_paragraph=True on the parent
        # wrongly vetoes a LATER parent-owned type-7 HTML block once the
        # nested item ends (type 7 "may not interrupt a paragraph" reads
        # a paragraph as still open that closed the instant this nested
        # item opened).
        if list_stack:
            list_stack[-1].has_paragraph = False
        list_stack.append(new_ctx)
        return "list", 0, True, opened_html_from_list
    if container == "list" and kind in ("quote", "lazy"):
        assert list_stack
        while True:
            continuation = _list_item_continuation(
                list_stack[-1], kind, line, probe, quote_depth, virtual_offset
            )
            if continuation is not None:
                list_stack[-1].has_paragraph = True
                return container, prior_quote_depth, False, False
            # THIS item's own continuation fails -- pop just it (an
            # OUTER ancestor may still be legitimately open, see
            # _pop_unowned_list_frames) and reclassify the SAME
            # physical line fresh against whatever survives, instead of
            # reusing the kind computed under the frame that just
            # ended: _paragraph_interrupt_kind is container-sensitive
            # (code vs lazy in particular). Bounded: each failed
            # attempt pops one frame, so this terminates in at most
            # len(list_stack) + 1 iterations. Since wv-9d8474,
            # kind=="lazy" can no longer reach this pop at all (see
            # _list_item_continuation) -- only a "quote" depth/indent
            # mismatch still can.
            list_stack.pop()
            container = "list" if list_stack else ""
            kind = _paragraph_interrupt_kind(
                line,
                probe,
                quote_depth,
                container,
                virtual_offset,
                list_stack[-1].content_col if list_stack else None,
                list_stack[-1].has_paragraph if list_stack else False,
            )
            if not (container == "list" and kind in ("quote", "lazy")):
                break
        # Every enclosing item was exhausted without one continuing --
        # list_stack/container are already [] / "" (kind can only
        # remain "quote"/"lazy" while container == "list", so the loop
        # above only stops this way once the stack is fully empty).
        # `kind` may now be "code" (mirrors the top-level "code" dispatch
        # above) or still "lazy" (falls through to the ordinary lazy
        # tail below, same as an originally-unowned line would).
        if kind == "code":
            return "", 0, True, False
    if kind == "quote":
        # See _quote_depth_is_boundary: a depth change is a genuine block
        # change and must reset an inline span crossing between its
        # lines; same depth is ordinary paragraph continuation.
        # container != "list" here (already handled above), so
        # list_stack is already empty by the established invariant.
        resets_span = _quote_depth_is_boundary(quote_depth, prior_quote_depth)
        return "quote", quote_depth, resets_span, False
    # "lazy": an unmarked line -- CommonMark lazy continuation: it
    # continues an already-open quote/plain paragraph without needing
    # its own marker, so this is a boundary only when nothing was open
    # to continue at all. container != "list" here (already handled
    # above), so list_stack is already empty.
    resets_span = container == ""
    if container == "":
        container = "plain"
    return container, prior_quote_depth, resets_span, False


def _verbatim_exempt_lines(source_lines: list[str]) -> set[int]:
    """Return 1-indexed lines an author has explicitly opted out of every rule.

    A paired HTML-comment marker (`<!-- wv-quality:verbatim-start -->` ...
    `<!-- wv-quality:verbatim-end -->`) exempts the bracketed range from
    every prose rule kind, unlike a rule's own `exempt:` term list (which
    only suppresses that one rule) or the fence/blockquote detection below
    (which is automatic and code-fence-shaped). This is for verbatim quoted
    source text that isn't fenced code but must still stay unchanged -- e.g.
    a tool's plain-text output sample quoted in a doc, whose differing
    register would otherwise trip a rule. Deliberately explicit opt-in: the
    scanner has no way to infer "this prose is a quotation" on its own. An
    unterminated start marker exempts through end of file rather than
    raising -- this runs over arbitrary target documents, not rule
    definitions, so it must not turn a missing close marker into a scan
    failure.

    Markers are only recognized outside fenced or indented code, and outside
    inline code spans on an otherwise-plain line -- otherwise a doc's own
    fenced *example* of the marker, or an inline-code *mention* of it
    (documentation about this feature), would itself activate it, exempting
    everything through EOF since the example has no matching end marker
    either. A start/end pair may still share one line (e.g. to exempt one
    inline term); once active, an already-open range keeps exempting
    subsequent lines regardless of their own code-fence state, symmetric
    with how a "start" seen inside code never opens one in the first place.

    An opening backtick run with no matching close ANYWHERE in the rest of
    the paragraph is, per CommonMark, literal text -- not a code span --
    but _mask_inline_code can't know that in advance without look-ahead, so
    it masks speculatively and this function buffers (rather than
    immediately committing) every line touched while a run is still
    unresolved. Once the run closes, or a block boundary passes without one,
    the buffered lines are replayed: as their real masked text if it
    closed, or as fully literal (unmasked) text if it never did -- a marker
    that was merely mentioned after a stray, never-closed backtick must
    still activate normally instead of being hidden by speculative masking
    that turned out to be wrong. A boundary is a blank line, fenced or
    indented code, a heading, a list item, or a blockquote depth change --
    inline parsing cannot cross any of those, only paragraph continuation
    lines within the SAME block.

    A single physical line can both close the incoming run AND open a
    brand-new unresolved one (e.g. "` more text `" continuing a prior
    unclosed backtick, then opening another) -- _mask_inline_code reports
    this via incoming_closed, distinct from the open_run_len it returns for
    the new run. Everything buffered before that line is flushed as MASKED
    (the incoming run really did close, so it really was code) before the
    new run starts its own, separate buffering.
    """
    exempt: set[int] = set()
    active = False
    fence_state = _FenceState()
    html_state = _HtmlBlockState()
    open_run_len = 0
    prior_quote_depth = 0
    # Logical container ("", "quote", "list", "plain") mirroring
    # _scan_lines' paragraph tracking -- distinct from raw quote_depth,
    # since CommonMark allows a blockquote paragraph to continue via an
    # unmarked ("lazy") line with no ">" at all; a raw depth-changed check
    # alone would treat that continuation as a block boundary and wrongly
    # reset carry state.
    container = ""
    # The currently open list items' own container identity, deepest
    # last (see _ListItemContext) -- empty whenever container != "list".
    # Mirrors _scan_lines' own stack tracking so a directive inside
    # HTML/fence content owned by a list item (or mentioned merely
    # inside a real inline code span within one) is masked/exempted the
    # same way in both, and so an outer item reclaims content whose
    # nested list already ended, instead of it being owned by nothing.
    list_stack: list[_ListItemContext] = []
    # Lines seen since a speculatively-open backtick run started -- held
    # back from exempt/active until we know whether it closes (then it
    # really was a code span, so replay each line's own masked form) or a
    # block boundary passes first (then replay literal_replay instead --
    # NOT the fully raw line, which would also unmask any PROVEN portion
    # of this same line that closed an earlier, unrelated incoming run --
    # see _mask_inline_code's literal_replay).
    pending: list[tuple[int, str, str]] = []  # (lineno, literal_replay, masked_line)

    def commit(lineno: int, masked: str) -> None:
        nonlocal active
        if not active and _VERBATIM_EXEMPT_START_RE.search(masked):
            active = True
        if active:
            exempt.add(lineno)
            if _VERBATIM_EXEMPT_END_RE.search(masked):
                active = False

    def flush_pending_as_masked() -> None:
        for pend_lineno, _pend_literal, pend_masked in pending:
            commit(pend_lineno, pend_masked)
        pending.clear()

    def flush_pending_as_literal() -> None:
        for pend_lineno, pend_literal, _pend_masked in pending:
            commit(pend_lineno, pend_literal)
        pending.clear()

    for lineno, line in enumerate(source_lines, start=1):
        probe, quote_depth, virtual_offset = _dequote(line)
        # Captured BEFORE the pop below -- see the wv-5ef426 finding-3
        # restoration check further down, once `kind` is known: a frame
        # popped ONLY for insufficient indentation (never a quote_depth
        # mismatch, always a hard boundary either way) may still need to
        # be put back for a genuinely lazy continuation line.
        pre_pop_stack = list(list_stack)
        pre_pop_top = pre_pop_stack[-1] if pre_pop_stack else None
        # Membership checked BEFORE it's passed into block detection --
        # see _pop_unowned_list_frames -- so an outdented opener doesn't
        # inherit stale list ownership (same reasoning as _scan_lines).
        # Pops as many nested frames as no longer own this line, letting
        # an enclosing outer item reclaim content whose own nested list
        # already ended.
        had_list = container == "list"
        _pop_unowned_list_frames(list_stack, quote_depth, line, probe, virtual_offset)
        owns_line = bool(list_stack)
        if had_list and not owns_line:
            # The WHOLE list ended, not just its innermost item -- keep
            # container in sync with the now-empty stack before it's used
            # below (both for this call and for kind classification).
            container = ""
        # An item-owned continuation line's own leaf-block opener must be
        # checked relative to the item's margin, not `probe`'s bare
        # quote-relative view -- see _item_relative_view. Also folds in
        # wv-98984a's quote-tab-residual materialization when NOT
        # list-owned -- see _structural_match_view.
        opener_probe = _structural_match_view(
            line, probe, list_stack[-1].content_col if owns_line else None, virtual_offset
        )
        in_block, just_opened = _advance_block_states(
            fence_state,
            html_state,
            quote_depth,
            probe,
            line,
            container if owns_line or not had_list else "",
            list_stack[-1].content_col if owns_line else None,
            virtual_offset,
            opener_probe,
            _no_open_paragraph_to_protect(container, owns_line, list_stack, pre_pop_top, quote_depth),
        )
        if in_block:
            # Opaque HTML/fence content (list-owned or not) -- container
            # and list_stack are left COMPLETELY untouched here, unlike
            # the old code=="code" routing this replaced: a list-owned
            # block's ownership must survive through to whatever line
            # ends it, so a later lazy line can still reattach to the
            # item's own paragraph (see _scan_lines' identical need). A
            # marker merely mentioned inside this content is never a
            # real directive; an already-active exemption still covers
            # it, matching how fenced code has always behaved.
            if just_opened:
                if owns_line:
                    # The item's identity survives (see above) but its
                    # CURRENTLY open paragraph doesn't -- a newly-opened
                    # leaf block ends it the same way a blank line does
                    # (see _scan_lines' identical fix), or a later
                    # insufficiently-indented line could wrongly lazily
                    # "continue" a paragraph that already ended before
                    # this block opened.
                    list_stack[-1].has_paragraph = False
                if open_run_len:
                    flush_pending_as_literal()
                    open_run_len = 0
            if active:
                exempt.add(lineno)
            continue

        kind = _paragraph_interrupt_kind(
            line,
            probe,
            quote_depth,
            container,
            virtual_offset,
            list_stack[-1].content_col if owns_line else None,
            list_stack[-1].has_paragraph if owns_line else False,
        )
        kind, list_stack, container = _reattach_lazy_owner_if_dropped(
            kind, list_stack, container, pre_pop_top, pre_pop_stack, quote_depth
        )

        # See _verbatim_container_transition for the full per-kind
        # reasoning -- it mirrors _scan_lines' own container transitions
        # exactly, minus the paragraph-building this function has none of.
        # list_stack is mutated in place by this call, not reassigned.
        container, prior_quote_depth, resets_span, opened_html_from_list = (
            _verbatim_container_transition(
                fence_state,
                html_state,
                kind,
                line,
                probe,
                quote_depth,
                container,
                list_stack,
                prior_quote_depth,
                virtual_offset,
            )
        )

        if resets_span and open_run_len:
            # Block boundary -- an inline code span cannot cross it, so any
            # speculatively-open run from a prior line never really closed.
            flush_pending_as_literal()
            open_run_len = 0

        if opened_html_from_list:
            continue

        if kind in ("code", "blank"):
            if kind == "blank":
                commit(lineno, line)
            elif active:
                exempt.add(lineno)
            continue

        had_open_run = bool(open_run_len)
        masked, open_run_len, incoming_closed, literal_replay = _mask_inline_code(
            line, open_run_len
        )
        if had_open_run and incoming_closed:
            # The run open coming into this line closed HERE -- everything
            # buffered before it really was inside the span, so it stays
            # masked (never becomes literal just because it spanned lines).
            # Checked independently of whether a NEW run also opens later
            # on this same line (open_run_len below may still be nonzero).
            flush_pending_as_masked()
        if open_run_len:
            # Still (or newly) unresolved -- hold this line back. Buffers
            # literal_replay, not the raw line -- if this line ALSO closed
            # an incoming run before the new unresolved one starts, that
            # proven-masked prefix must survive even if the new run never
            # closes (see _mask_inline_code).
            pending.append((lineno, literal_replay, masked))
            continue
        commit(lineno, masked)

    # EOF reached with an unresolved run -- it never closed.
    flush_pending_as_literal()
    return exempt


def _scan_lines_raw(source_lines: list[str], rule: dict[str, object]) -> list[_ScanLine]:
    """Line-scope path: one _ScanLine per raw source line, unreflowed.

    Structural Markdown rules (markdown-* ids) declare match_scope: line to
    keep exact source-line text, so unlike the paragraph path this never
    rewrites a line's content -- it only ever drops whole lines that
    shouldn't be matched at all:
      - lines inside a fenced code block, including one nested a level under
        a blockquote ("> ```lang", e.g. a verbatim-quoted tool-output
        sample), so example/quoted code isn't scanned as prose;
      - a line that names the rule's own id (schema docs, this rule's own
        provenance/message, an audit writeup) -- documentation ABOUT the
        rule is not a defect instance of it;
      - a line inside an explicit `wv-quality:verbatim-start`/`-end` marker
        pair (see _verbatim_exempt_lines) -- an author's opt-in for verbatim
        quoted text that isn't fenced code but must stay unchanged;
      - a line inside an active HTML block (_HtmlBlockState), the same as
        the paragraph-scope path -- raw HTML content is opaque here too,
        not a structural Markdown line a match_scope: line rule should see,
        including one owned by a list item's own first-line content (e.g.
        "- <div>").

    This path never reflows a paragraph, so it doesn't need most of
    _scan_lines' own container tracking (quote/plain paragraph identity)
    -- but it DOES need to track an open list item's own identity
    (_ListItemContext), for exactly one purpose: telling a newly-opened
    HTML/fence block whether it's list-owned, so a later sibling item or
    insufficiently-indented line correctly ends it (see
    _list_ctx_owns_line) instead of leaving it active indefinitely.
    """
    rule_id = str(rule.get("id", ""))
    verbatim_exempt = _verbatim_exempt_lines(source_lines)
    out: list[_ScanLine] = []
    fence_state = _FenceState()
    html_state = _HtmlBlockState()
    container = ""
    # Open list items, deepest last -- see _scan_lines' identical stack
    # for the full nested-list reasoning (_pop_unowned_list_frames /
    # _restore_owned_list_stack).
    list_stack: list[_ListItemContext] = []
    for lineno, line in enumerate(source_lines, start=1):
        if lineno in verbatim_exempt:
            container = ""
            list_stack = []
            continue
        probe, quote_depth, virtual_offset = _dequote(line)
        # Captured BEFORE the pop below -- see _reattach_lazy_owner_if_dropped
        # (wv-5ef426 finding 3), consulted once `kind` is known.
        pre_pop_stack = list(list_stack)
        pre_pop_top = pre_pop_stack[-1] if pre_pop_stack else None
        had_list = container == "list"
        _pop_unowned_list_frames(list_stack, quote_depth, line, probe, virtual_offset)
        owns_line = bool(list_stack)
        if had_list and not owns_line:
            container = ""
        # An item-owned continuation line's own leaf-block opener must be
        # checked relative to the item's margin, not `probe`'s bare
        # quote-relative view -- see _item_relative_view. Also folds in
        # wv-98984a's quote-tab-residual materialization when NOT
        # list-owned -- see _structural_match_view.
        opener_probe = _structural_match_view(
            line, probe, list_stack[-1].content_col if owns_line else None, virtual_offset
        )
        in_block, just_opened = _advance_block_states(
            fence_state,
            html_state,
            quote_depth,
            probe,
            line,
            container if owns_line or not had_list else "",
            list_stack[-1].content_col if owns_line else None,
            virtual_offset,
            opener_probe,
            _no_open_paragraph_to_protect(container, owns_line, list_stack, pre_pop_top, quote_depth),
        )
        if just_opened and owns_line:
            # A newly-opened, list-owned leaf block ends the item's
            # CURRENTLY open paragraph -- see _scan_lines' identical fix
            # -- or a later insufficiently-indented line could wrongly
            # lazily "continue" a paragraph that already ended before
            # this block opened.
            list_stack[-1].has_paragraph = False
        if in_block:
            continue
        kind = _paragraph_interrupt_kind(
            line,
            probe,
            quote_depth,
            container,
            virtual_offset,
            list_stack[-1].content_col if owns_line else None,
            list_stack[-1].has_paragraph if owns_line else False,
        )
        kind, list_stack, container = _reattach_lazy_owner_if_dropped(
            kind, list_stack, container, pre_pop_top, pre_pop_stack, quote_depth
        )
        if kind == "list":
            # wv-98984a: a marker immediately preceded by a residual
            # quote-tab is unrecognizable against probe's own literal
            # tab character -- match against the materialized view
            # instead (a no-op when there's nothing to materialize).
            structural = _materialize_quote_tab(line, probe, virtual_offset)
            list_match = _MARKDOWN_LIST_RE.match(structural)
            assert list_match is not None  # kind=="list" implies a marker match
            new_ctx, _content, _source_col, opened_block = _open_list_item(
                fence_state,
                html_state,
                list_match,
                line,
                probe,
                quote_depth,
                virtual_offset,
                len(structural) - len(probe),
            )
            # list_stack is already trimmed to its owning ancestor chain
            # (the pop above ran against this SAME marker line) -- nest
            # the new item under whatever survives instead of discarding
            # it, same as _verbatim_container_transition's "list" case.
            #
            # wv-ac22a5 finding 5 (external code review): a nested marker
            # always interrupts the SURVIVING parent's own currently-open
            # paragraph, same as _scan_lines' own "list" dispatch -- left
            # uncleared, a stale has_paragraph=True on the parent wrongly
            # vetoes a LATER parent-owned type-7 HTML block once the
            # nested item ends.
            if list_stack:
                list_stack[-1].has_paragraph = False
            list_stack.append(new_ctx)
            container = "list"
            if opened_block:
                continue
        elif container == "list" and kind in ("quote", "lazy"):
            assert list_stack
            while True:
                continuation = _list_item_continuation(
                    list_stack[-1], kind, line, probe, quote_depth, virtual_offset
                )
                if continuation is not None:
                    list_stack[-1].has_paragraph = True
                    break
                # This item's own continuation fails -- pop just it and
                # reclassify the SAME physical line fresh against
                # whatever ancestor survives, same reasoning as
                # _scan_lines' identical retry (an outer item may still
                # be legitimately open; `kind` is container-sensitive
                # and must not stay stale once the container changes).
                # Since wv-9d8474, kind=="lazy" can no longer reach this
                # pop at all (see _list_item_continuation) -- only a
                # "quote" depth/indent mismatch still can.
                list_stack.pop()
                container = "list" if list_stack else ""
                kind = _paragraph_interrupt_kind(
                    line,
                    probe,
                    quote_depth,
                    container,
                    virtual_offset,
                    list_stack[-1].content_col if list_stack else None,
                    list_stack[-1].has_paragraph if list_stack else False,
                )
                if not (container == "list" and kind in ("quote", "lazy")):
                    break
        elif kind == "blank":
            # Ends the CURRENT paragraph, but not necessarily the
            # enclosing list item -- see _scan_lines' identical
            # reasoning. list_stack survives; only the innermost item's
            # has_paragraph clears.
            if list_stack:
                list_stack[-1].has_paragraph = False
                container = "list"
            else:
                container = ""
        elif kind == "code" and list_stack:
            # wv-ac22a5 finding 6 (external code review): item-relative
            # indented code (wv-5ef426 finding 1) ends the OWNING item's
            # CURRENTLY open paragraph, not the item itself -- this
            # branch was MISSING entirely (kind == "code" fell into the
            # generic "else" below, unconditionally clearing list_stack
            # the same way genuinely-unowned code correctly does), so a
            # LATER item-owned HTML/fence block on a following line
            # became falsely root-owned with no indentation-based
            # ending, silently swallowing all remaining content to EOF.
            # Mirrors _scan_lines' own owns_line-aware "code" dispatch.
            list_stack[-1].has_paragraph = False
            container = "list"
        elif kind in ("heading", "break") and list_stack:
            # wv-784f03 (external code review round 3, finding 1): this
            # kind used to fall into the generic "else" below, which
            # unconditionally clears list_stack -- but the pop above
            # (_pop_unowned_list_frames) may have left a surviving OUTER
            # owner after only a PARTIAL pop, the same as "code" just
            # above. Discarding it here corrupted `had_list` for the
            # NEXT line (container=="" while list_stack was actually
            # still non-empty going into this branch, before we clear
            # it below) -- a heading/break ends the owning item's
            # CURRENTLY open paragraph, never the item itself.
            list_stack[-1].has_paragraph = False
            container = "list"
        else:
            container = ""
            list_stack = []
        # Standalone identifier match, not a substring -- a short rule id
        # like "ai" must not self-exempt unrelated text that merely contains
        # it (e.g. "We maintain this.").
        if rule_id and re.search(rf"\b{re.escape(rule_id)}\b", line):
            continue
        out.append(_ScanLine(line, ((0, lineno, 0),), len(out)))
    return out


def _list_ctx_owns_line(
    list_ctx: _ListItemContext | None,
    quote_depth: int,
    line: str,
    probe: str,
    virtual_offset: int = 0,
) -> bool:
    """Whether the CURRENTLY open list item still owns this physical line,
    checked BEFORE any block-opener detection runs on it.

    A caller about to try opening an HTML/fence block needs to know
    whether to attribute it to the list item (list_content_col) or treat
    it as unowned/at the outer level -- passing the item's content_col
    unconditionally, without first confirming the CURRENT line is still
    indented enough to belong to it, is exactly how an outdented root
    opener (e.g. a "<script>" or "<span>" at column 0 right after a list
    item) ends up wrongly attributed to a list item it no longer belongs
    to: its own first unindented body line then "correctly" ends the
    block via the list-owned insufficient-indentation rule, even though
    the block was never really the list's to own in the first place.

    Uses the SAME membership rule _list_item_continuation applies to an
    explicitly-marked ("quote"-shaped) continuation line: matching
    quote_depth, indented at least content_col columns. A genuinely lazy
    (unmarked) line's own eventual kind is decided later by the
    classifier -- if this call says "not owned" for one, that's harmless:
    _list_item_continuation still separately allows lazy continuation
    regardless of indentation, and passing list_content_col=None into
    block detection has no effect on a line no block ever opens from.
    """
    if list_ctx is None or quote_depth != list_ctx.quote_depth:
        return False
    return _relative_visual_indent_width(line, probe, virtual_offset) >= list_ctx.content_col


def _pop_unowned_list_frames(
    list_stack: list[_ListItemContext],
    quote_depth: int,
    line: str,
    probe: str,
    virtual_offset: int = 0,
) -> None:
    """Pop nested list-item frames off the stack, innermost first, that no
    longer own this physical line -- see _ListItemContext for the
    membership rule (_list_ctx_owns_line: same quote_depth, indented at
    least content_col columns). Mutates `list_stack` in place; whichever
    frame survives on top afterward (if any) is the innermost item still
    enclosing this line.

    A single scalar list_ctx has no such fallback: once a nested list's
    own marker replaces it, content that stops belonging to the nested
    item (because its own list ended) has nowhere to reattach, even
    though it still belongs to the OUTER item that opened the nested
    list in the first place -- this is what lets that content wrongly
    end up owned by no container at all. Popping one frame at a time and
    rechecking the next lets an outer item reclaim it instead.

    Never pops for a blank probe -- CommonMark decides list-item
    continuation from the NEXT non-blank line's indentation, never from
    a blank line by itself (see _advance_html_block_state's identical
    ends_via_indent exemption). A blank line's own lack of indentation
    (typically 0, well under any real content_col) must not pop a frame
    that a later, sufficiently-indented line would still reattach to.
    """
    if _is_ascii_blank(probe):
        return
    while list_stack and not _list_ctx_owns_line(
        list_stack[-1], quote_depth, line, probe, virtual_offset
    ):
        list_stack.pop()


def _restore_owned_list_stack(
    preserved: list[_ListItemContext], clear_has_paragraph: bool = False
) -> tuple[list[_ListItemContext], str]:
    """Returns the (list_stack, container) pair to restore after a
    flush()-triggering transition (a newly-opened block, a blank line,
    or a new nested list marker) that ends, at most, the innermost
    item's CURRENTLY open paragraph -- never the enclosing item(s)
    themselves. `preserved` is the list_stack already trimmed to its
    owning frames (via _pop_unowned_list_frames) BEFORE the transition;
    flush() itself always resets the live list_stack to [] as a side
    effect of emitting a paragraph, so this is what undoes that reset
    for every surviving ancestor frame at once, not just the innermost.
    Pass clear_has_paragraph=True for the blank-line/newly-opened-block/
    new-nested-item case: the paragraph ends, even though the item(s)
    don't.
    """
    if not preserved:
        return [], ""
    if clear_has_paragraph:
        preserved[-1].has_paragraph = False
    return preserved, "list"


def _reattach_lazy_owner_if_dropped(
    kind: str,
    list_stack: list[_ListItemContext],
    container: str,
    pre_pop_top: _ListItemContext | None,
    pre_pop_stack: list[_ListItemContext],
    quote_depth: int,
) -> tuple[str, list[_ListItemContext], str]:
    """wv-5ef426 finding 3: _pop_unowned_list_frames (already run by the
    caller, before `kind` was known) pops an item whose CURRENT line no
    longer meets its own indentation requirement -- correct for
    structural/opener purposes (a fresh marker, or a leaf-block opener,
    really does need to see this container as already ended, or it
    nests under the wrong ancestor -- see _pop_unowned_list_frames' own
    docstring) but WRONG for a genuinely lazy (unmarked, non-interrupting)
    continuation line: CommonMark laziness lets such a line continue an
    item's ALREADY-OPEN paragraph regardless of its own indentation, the
    same as it does for a bare "plain"/"quote" paragraph (see
    _paragraph_interrupt_kind's own container == "" gate) -- but by the
    time `kind` is classified, `container` has ALREADY been reset by the
    premature pop, so nothing distinguishes this line from a genuinely
    fresh, unrelated top-level one, and the popped _ListItemContext has
    nowhere left to reattach to once a LATER line needs it (e.g. its own
    item-relative HTML/fence opener).

    Detected only once `kind` resolves to something an open paragraph
    would have protected anyway: "code" (indentation that LOOKS like a
    fresh code block only because `container` was wrongly reset to "" --
    see _paragraph_interrupt_kind's own container=="" gate, which an
    open paragraph would normally have defeated), "lazy", or a "quote"
    at the item's OWN already-established quote_depth (see wv-f32f1b
    below -- that specific case, guarded by the same
    `pre_pop_top.quote_depth == quote_depth` check this whole branch
    already requires, is not a genuine depth transition at all, just
    this line's own residual quote marker at the depth already in
    effect). Never blank/heading/break/list, which legitimately end (or,
    for "list", replace) the item regardless of what "protected" it --
    `kind` already reflects that classification, computed at container
    == "" once the pop reset it, where every marker/heading/break is
    unconditionally interrupting (see _paragraph_interrupt_kind).

    wv-f32f1b (external code review round 3, finding 2): a "quote"-kind
    line used to bypass this function entirely on the theory that it
    "keeps its own real, un-waived indentation requirement in
    _list_item_continuation" -- true only when quote_depth is actually
    CHANGING (entering/leaving a further nested blockquote, a genuine
    block boundary). At the SAME quote_depth the item itself already
    established, a "quote" classification is just this line's own
    literal ">" marker being visible again after the pop reset
    `container` to "" (see _paragraph_interrupt_kind's own
    `if quote_depth > 0: return "quote"` fallback) -- laziness still
    protects the deepest open paragraph exactly as it does for "lazy",
    and the popped item's identity was still being discarded here
    instead of reattached to it, same as wv-a7a166's original code/lazy
    fix.

    Returns (kind, list_stack, container). Only ever reattaches the
    ENTIRE pre_pop_stack (never a partial slice) -- if it was consistent
    before the pop (each ancestor already validated on an earlier line),
    it stays consistent restored whole. Reattaches whenever the pop
    actually removed the DEEPEST frame (`pre_pop_top`) -- whether that
    left the stack FULLY empty or a shallower ancestor still owns the
    line (`list_stack[-1] is not pre_pop_top`): CommonMark laziness
    protects the deepest open paragraph regardless of which ancestor's
    own indentation the line happens to satisfy, so a surviving outer
    ancestor must never pre-empt reattaching the popped inner one (wv-
    a7a166, external code review round 2 -- the original `not list_stack`
    guard only handled the fully-emptied case, silently discarding a
    still-laziness-protected inner paragraph whenever an outer ancestor
    survived on its own). When no pop of the deepest frame happened at
    all, `list_stack[-1] is pre_pop_top` and this is correctly a no-op --
    the ordinary continuation path already has it. Callers must reassign
    all three return values, not rely on in-place mutation -- list_stack
    may be substituted wholesale with pre_pop_stack.
    """
    if kind in ("code", "lazy", "quote") and _pre_pop_top_still_protects_paragraph(
        pre_pop_top, quote_depth, list_stack
    ):
        return "lazy", pre_pop_stack, "list"
    return kind, list_stack, container


def _pre_pop_top_still_protects_paragraph(
    pre_pop_top: _ListItemContext | None,
    quote_depth: int,
    list_stack: list[_ListItemContext],
) -> bool:
    """True when the popped item's own open paragraph still needs
    reattaching -- see _reattach_lazy_owner_if_dropped's docstring for the
    full CommonMark-laziness rationale each conjunct here protects.
    """
    if pre_pop_top is None or not pre_pop_top.has_paragraph:
        return False
    if pre_pop_top.quote_depth != quote_depth:
        return False
    return not list_stack or list_stack[-1] is not pre_pop_top


def _no_open_paragraph_to_protect(
    container: str,
    owns_line: bool,
    list_stack: list[_ListItemContext],
    pre_pop_top: _ListItemContext | None,
    quote_depth: int,
) -> bool:
    """Whether NOTHING currently protects this line from a construct that
    cannot interrupt an open paragraph -- CommonMark HTML type 7 (see
    _try_open_html_block's own type7_no_open_paragraph parameter) is the
    only such construct today. True only when there is no root/quote
    paragraph open (container == ""), no OWNED list item with its own
    open paragraph, AND no just-popped item whose open paragraph
    _reattach_lazy_owner_if_dropped would still reattach once `kind` is
    known.

    wv-1ccd09 (external code review finding 1): block detection
    (_advance_block_states, called BEFORE _paragraph_interrupt_kind and
    so before _reattach_lazy_owner_if_dropped ever runs) previously only
    saw the POST-pop state -- a line that _pop_unowned_list_frames just
    popped for insufficient indentation looks identical to one that was
    never owned at all (container == "" either way), wrongly treating a
    still-laziness-protected line (the popped item's OWN paragraph was
    open, and would be reattached to once `kind` resolves to "lazy") as
    eligible to open a fresh type-7 block instead of lazily continuing
    that paragraph as plain text. Mirrors _reattach_lazy_owner_if_dropped's
    own reattachment condition exactly, checked here BEFORE block
    detection runs instead of only after kind classification -- the two
    checks must never drift apart, or a line could be vetoed by one and
    reattached by the other.

    wv-1ccd09 round 2 (external code review): the original version only
    consulted `pre_pop_top` when `owns_line` was False (list_stack fully
    emptied) -- a PARTIAL pop, where a shallower outer ancestor survives
    and owns_line is True, skipped the pre_pop_top check entirely and
    fell straight to `not list_stack[-1].has_paragraph`, checking only
    the SURVIVING ancestor's own paragraph state and ignoring the just-
    popped DEEPER item's still-open one. CommonMark laziness protects
    the deepest open paragraph regardless of which ancestor's own
    indentation the line happens to satisfy -- pending_reattachment is
    now checked first, unconditionally on owns_line, exactly mirroring
    _reattach_lazy_owner_if_dropped's own (identically widened) guard.
    """
    pending_reattachment = (
        pre_pop_top is not None
        and pre_pop_top.has_paragraph
        and pre_pop_top.quote_depth == quote_depth
        and (not list_stack or list_stack[-1] is not pre_pop_top)
    )
    if pending_reattachment:
        return False
    if owns_line:
        return not list_stack[-1].has_paragraph
    return container == ""


def _lazy_paragraph_content(line: str, probe: str, quote_depth: int) -> tuple[str, int]:
    """Content/source_col for a "lazy" kind line NOT continuing a list
    item (container != "list", handled separately by
    _list_item_continuation) -- a quote_depth > 0 line still needs its
    container marker(s) stripped (the raw line's own ">" is a container
    marker, not literal paragraph text); quote_depth == 0 keeps the raw
    line verbatim (blockquote/plain lazy continuation preserves
    incidental whitespace literally, unlike a list item's own
    continuation, which left-strips it).

    wv-191cc0 (external code review): a single-level _MARKDOWN_QUOTE_RE
    match against the raw `line` used to stand in for dequoting here --
    correct at quote_depth == 1 (one strip either way) but wrong at
    quote_depth >= 2 (reachable: _paragraph_interrupt_kind classifies a
    fully-dequoted, deeply-indented line as "lazy" -- not "quote" --
    whenever a quote paragraph is ALREADY open, since its code/lazy
    check runs before its quote_depth>0 check), leaving every deeper
    ">" marker as literal paragraph text. `probe` is already this line's
    full _dequote(line) result for `quote_depth` levels -- use it (and
    its own raw offset into `line`) directly instead of rematching.
    """
    if quote_depth > 0:
        return probe, len(line) - len(probe)
    return line, 0


def _list_item_continuation(
    list_ctx: _ListItemContext,
    kind: str,
    line: str,
    probe: str,
    quote_depth: int,
    virtual_offset: int = 0,
) -> tuple[str, int] | None:
    """Decide whether a "quote" or "lazy" kind line belongs to the
    currently open list item, and extract its content/source column if
    so. Returns None when the line does NOT belong to this item -- see
    _ListItemContext for the membership rules (quote_depth match +
    content_col indentation). The caller always runs
    _pop_unowned_list_frames against this SAME line before calling here
    (see _scan_lines / _scan_lines_raw / _verbatim_container_transition),
    so a "lazy" kind line reaching this point has already passed that
    same membership check -- it can no longer fail here (wv-9d8474):
    has_paragraph only decides whether the extracted content CONTINUES
    an already-open paragraph or STARTS a fresh one within the item, not
    whether the line belongs to it.

    virtual_offset is `probe`'s own _dequote virtual_offset -- see
    _relative_visual_column.
    """
    if kind == "quote":
        if quote_depth != list_ctx.quote_depth:
            return None
        if _relative_visual_indent_width(line, probe, virtual_offset) < list_ctx.content_col:
            return None
        # quote_depth matches the item's own, so probe (fully dequoted) IS
        # already this item's own container-relative view -- slice off
        # exactly content_col COLUMNS, tab-expanded and measured absolute
        # across `line` then converted back to container-relative (not
        # .lstrip(), which would also eat any further, genuinely literal
        # indentation beyond it, and not a raw content_col character
        # slice, which would misplace the cut whenever a tab is
        # involved, and not a probe-relative-from-zero tab expansion,
        # which would misplace it again whenever the stripped prefix's
        # own width isn't a multiple of 4 -- see _relative_visual_column).
        char_idx = _char_index_for_relative_column(
            line, probe, list_ctx.content_col, virtual_offset
        )
        content = probe[char_idx:]
        source_col = (len(line) - len(probe)) + char_idx
        return content, source_col
    # kind == "lazy": the caller has already confirmed this line belongs
    # to list_ctx (see this function's docstring), so it always succeeds
    # here -- has_paragraph=False (right after a blank line, right after
    # a leaf block just opened, or an empty item's own first
    # continuation, e.g. "- outer\n  -\n    hidden\n") means this line
    # STARTS a fresh paragraph within the item instead of continuing one
    # (mirrors _open_list_item's own first-line handling), rather than
    # signalling the item ended. The caller sets has_paragraph = True on
    # a successful return either way, so a fresh start and an ordinary
    # continuation are indistinguishable from here on -- both just add
    # one more line to whatever paragraph is currently accumulating.
    if quote_depth > 0:
        # wv-ac22a5 finding 3 (external code review round 3): rematching
        # `line` against the single-level _MARKDOWN_QUOTE_RE (as this
        # used to) only strips ONE ">" regardless of quote_depth, same
        # bug _lazy_paragraph_content had before wv-191cc0 -- `probe` is
        # already this line's full _dequote(line) result for
        # quote_depth levels (see this function's own docstring), so use
        # it and its own raw offset into `line` directly instead.
        content = probe.lstrip()
    else:
        content = line.lstrip()
    source_col = len(line) - len(content) if content else len(line)
    return content, source_col


def _open_list_item(
    fence_state: _FenceState,
    html_state: _HtmlBlockState,
    list_match: re.Match[str],
    line: str,
    probe: str,
    quote_depth: int,
    virtual_offset: int = 0,
    structural_delta: int = 0,
) -> tuple[_ListItemContext, str, int, bool]:
    """Build a new list item's own context, and try opening a fenced-code
    or HTML block from the item's own first-line content -- a list item's
    content is a leaf-block start position in its own right, checked the
    same way a bare line is, through the SAME shared fence/HTML
    arbitration (_advance_block_states) every other opener check uses,
    not a narrower HTML-only check.

    virtual_offset is `probe`'s own _dequote virtual_offset -- see
    _relative_visual_column -- needed so a marker preceded by a
    partially-consumed quote tab gets the right content_col.

    structural_delta (wv-98984a) is nonzero when `list_match` was
    matched against `_materialize_quote_tab(line, probe, virtual_offset)`
    instead of `probe` itself -- a marker immediately preceded by a
    residual quote-tab (e.g. ">\\t- item") is unrecognizable against
    `probe`'s own literal tab character, so the caller matches against
    the materialized (0-3 literal spaces, possibly a different LENGTH
    than `probe`) view instead. `list_match`'s own start(1) is then
    relative to that view, not `probe`, and must be translated back by
    this many characters (len(materialized) - len(probe)) before any
    position math against `probe`/`line` (source_col, content_col) is
    valid; group(1) needs no such translation (a captured STRING, not a
    position). 0 (the default) preserves prior behavior for a marker
    matched directly against `probe`.

    Returns (list_ctx, content, source_col, opened_block) -- opened_block
    is True when the item's own content started a fence or HTML block
    (state already mutated accordingly, list_content_col included for
    HTML -- a fence has no such ownership tracking yet, not exercised by
    any known case); the caller must not append content to the paragraph
    in that case, just record the item and move on to the next line.
    """
    content = list_match.group(1)
    match_start = list_match.start(1) - structural_delta
    source_col = (len(line) - len(probe)) + match_start
    list_ctx = _ListItemContext(
        quote_depth=quote_depth,
        # content_col is a STRUCTURAL, container-relative visual column
        # (tab-expanded ABSOLUTE across `line`, see
        # _relative_visual_column -- NOT probe-relative-from-zero, which
        # would misplace a tab in the marker's own padding whenever the
        # stripped prefix's own width isn't a multiple of 4) used only
        # for indentation comparisons -- source_col above stays a raw
        # character offset, used only for source-position reporting; the
        # two must never be conflated.
        content_col=_relative_visual_column(line, probe, match_start, virtual_offset),
        has_paragraph=False,  # corrected below, once opened_block is known
    )
    opened_block = False
    if content:
        opened_block, _just_opened = _advance_block_states(
            fence_state, html_state, quote_depth, content, line, "", list_ctx.content_col
        )
    # A leaf block (fence/HTML, including a one-line self-closing one)
    # does not create an open PARAGRAPH -- has_paragraph is true only
    # when content is real, non-block prose actually available for a
    # later line to lazily continue through _list_item_continuation.
    # Setting it from bare content alone (the prior version of this fix)
    # was too broad: an insufficiently-indented line after a completed
    # leaf block would wrongly be treated as continuing a paragraph that
    # was never there.
    list_ctx.has_paragraph = bool(content) and not opened_block
    return list_ctx, content, source_col, opened_block


def _scan_lines(  # pylint: disable=too-many-statements
    text: str, rule: dict[str, object]
) -> list[_ScanLine]:
    """Return raw lines or Markdown prose paragraphs with source mappings."""
    source_lines = text.splitlines()
    default_scope = _default_match_scope(rule)
    if str(rule.get("match_scope", default_scope)) == "line":
        return _scan_lines_raw(source_lines, rule)

    verbatim_exempt = _verbatim_exempt_lines(source_lines)
    out: list[_ScanLine] = []
    paragraph: list[tuple[int, str, int]] = []
    container = ""
    # Mirrors _verbatim_exempt_lines' own prior_quote_depth tracking (see
    # _quote_depth_is_boundary) -- an explicit ">" line at a DIFFERENT
    # depth than the currently-open quote paragraph is a genuine block
    # change (entering or leaving a nested blockquote), not the ordinary
    # continuation of one paragraph, and must flush into its own unit.
    prior_quote_depth = 0
    # Open list items, deepest last (see _ListItemContext) -- empty
    # whenever container != "list". A single scalar can only ever
    # remember the INNERMOST item; once a nested list ends, content that
    # still belongs to the OUTER item that opened it needs that item's
    # own frame still on the stack to reattach to (see
    # _pop_unowned_list_frames).
    list_stack: list[_ListItemContext] = []
    fence_state = _FenceState()
    html_state = _HtmlBlockState()

    def flush() -> None:
        nonlocal container, prior_quote_depth, list_stack
        if not paragraph:
            return
        parts: list[str] = []
        starts: list[tuple[int, int, int]] = []
        offset = 0
        for lineno, line, source_col in paragraph:
            if parts:
                parts.append(" ")
                offset += 1
            starts.append((offset, lineno, source_col))
            parts.append(line)
            offset += len(line)
        out.append(_ScanLine("".join(parts), tuple(starts), len(out)))
        paragraph.clear()
        container = ""
        prior_quote_depth = 0
        list_stack = []

    for lineno, line in enumerate(source_lines, start=1):
        if lineno in verbatim_exempt:
            flush()
            continue
        # Dequote every blockquote level before the fence/HTML check, same
        # as the line-scope path -- otherwise a blockquoted fence or HTML
        # block ("> ```lang", "> <div>") isn't recognized at all, and its
        # "content" lines get scanned as quoted prose instead of skipped.
        # quote_depth also scopes both to their opening container (see
        # _advance_fence_state / _advance_html_block_state) -- either
        # closes when the blockquote itself ends (an outdent), not only on
        # an explicit closing marker/terminator at the same depth.
        probe, quote_depth, virtual_offset = _dequote(line)
        # Captured BEFORE the pop below -- see _reattach_lazy_owner_if_dropped
        # (wv-5ef426 finding 3), consulted once `kind` is known.
        pre_pop_stack = list(list_stack)
        pre_pop_top = pre_pop_stack[-1] if pre_pop_stack else None
        # Membership checked BEFORE it's passed into block detection --
        # see _pop_unowned_list_frames -- not stale content_col
        # unconditionally: an outdented line (e.g. a root HTML opener
        # right after a list item) no longer belongs to the innermost
        # item, so a new block it opens must not inherit that item's
        # ownership. Pops as many nested frames as no longer own this
        # line -- an enclosing OUTER item (still on the stack below the
        # one just popped) reclaims it instead of "container" reverting
        # to "" the instant the deepest item's own list ends.
        had_list = container == "list"
        _pop_unowned_list_frames(list_stack, quote_depth, line, probe, virtual_offset)
        owns_line = bool(list_stack)
        if had_list and not owns_line:
            # The WHOLE stack ended, not just its innermost item.
            container = ""
        # wv-a7a166 round 2 (external code review): a PARTIAL pop just
        # above -- SOME outer ancestor survives (list_stack is non-empty)
        # -- used to be flushed EAGERLY here, before `kind` was even
        # known, on the theory that the just-popped INNERMOST frame's own
        # open paragraph was already a complete, closed block the moment
        # it stopped owning this line. That's wrong whenever this line
        # turns out to be a genuinely lazy ("code"/"lazy" kind)
        # continuation: CommonMark laziness protects the DEEPEST open
        # paragraph regardless of which ancestor's own indentation the
        # line happens to satisfy, so the popped item's paragraph is
        # often not closed at all -- it's exactly what this line should
        # keep extending. Eagerly flushing it here pre-empted
        # _reattach_lazy_owner_if_dropped (below, once `kind` is known)
        # from ever getting the chance to reattach `pre_pop_stack`
        # instead, wrongly splitting one legal CommonMark paragraph into
        # two. No flush happens here anymore: _reattach_lazy_owner_if_dropped
        # now reattaches the full pre_pop_stack on a partial pop too (not
        # only a fully-emptied one), and every kind that's genuinely a
        # hard boundary ("blank", "list", "heading", "break", a mismatched
        # "quote") already flush()es unconditionally in its own dispatch
        # below, so the popped paragraph is never lost -- only ever
        # emitted at the right point, once `kind` actually resolves.
        # Saved before flush() (which clears list_stack unconditionally
        # whenever it emits a paragraph) so a newly-opened, list-owned
        # block can have ownership of every surviving ancestor restored
        # right after -- a block opening does not end the list ITEM
        # (only, if anything, its currently open paragraph), so a later
        # line must still be able to reattach to it once the block
        # itself ends.
        owning_stack = list_stack if owns_line else []
        # An item-owned continuation line's own leaf-block opener must be
        # checked relative to the item's margin, not `probe`'s bare
        # quote-relative view -- see _item_relative_view. Also folds in
        # wv-98984a's quote-tab-residual materialization when NOT
        # list-owned -- see _structural_match_view.
        opener_probe = _structural_match_view(
            line, probe, list_stack[-1].content_col if owns_line else None, virtual_offset
        )
        in_block, just_opened = _advance_block_states(
            fence_state,
            html_state,
            quote_depth,
            probe,
            line,
            container if owns_line or not had_list else "",
            list_stack[-1].content_col if owns_line else None,
            virtual_offset,
            opener_probe,
            _no_open_paragraph_to_protect(container, owns_line, list_stack, pre_pop_top, quote_depth),
        )
        if just_opened:
            flush()
            # clear_has_paragraph=True: a newly-opened leaf block ends the
            # item's CURRENTLY open paragraph the same way a blank line
            # does (see _restore_owned_list_stack) -- without this, a
            # later insufficiently-indented line could wrongly lazily
            # "continue" a paragraph that already ended before this block
            # opened.
            list_stack, container = _restore_owned_list_stack(
                owning_stack, clear_has_paragraph=True
            )
        if in_block:
            continue

        # kind decides interrupt/continue vs. a fresh block boundary the
        # same way _verbatim_exempt_lines does (see
        # _paragraph_interrupt_kind) -- content extraction below still
        # matches its own regex, against whichever text keeps the right
        # markers literal: quote content extraction uses the raw line,
        # exactly-one-level-stripped (a nested quote keeps its inner ">"
        # markers literal in the reflowed paragraph), while list content
        # extraction uses `probe` (fully dequoted) so a list nested inside
        # a blockquote -- at any depth -- extracts the same as a bare one.
        kind = _paragraph_interrupt_kind(
            line,
            probe,
            quote_depth,
            container,
            virtual_offset,
            list_stack[-1].content_col if owns_line else None,
            list_stack[-1].has_paragraph if owns_line else False,
        )
        kind, list_stack, container = _reattach_lazy_owner_if_dropped(
            kind, list_stack, container, pre_pop_top, pre_pop_stack, quote_depth
        )
        owns_line = bool(list_stack)

        if kind == "blank":
            # A blank line ends the CURRENT paragraph, but not
            # necessarily the enclosing list item(s) -- CommonMark allows
            # a blank line inside an item, followed by more
            # sufficiently-indented content that still belongs to it (see
            # _pop_unowned_list_frames, consulted again on the next
            # line). Saved across flush() the same way a newly-opened
            # block's ownership is, just above.
            reopening_stack = list_stack
            flush()
            list_stack, container = _restore_owned_list_stack(
                reopening_stack, clear_has_paragraph=True
            )
            continue

        if kind == "code":
            if owns_line:
                # wv-5ef426 finding 1: an item-relative indented-code
                # block (4+ columns beyond the OWNING item's own margin,
                # with no paragraph currently open in it to protect it --
                # see _paragraph_interrupt_kind's list_content_col gate)
                # ends that item's CURRENTLY open paragraph the same way
                # a newly-opened leaf block or a blank line does, but not
                # the item itself -- see _restore_owned_list_stack.
                owning_stack = list_stack
                flush()
                list_stack, container = _restore_owned_list_stack(
                    owning_stack, clear_has_paragraph=True
                )
            else:
                # Genuinely unowned indented code (container == "" was
                # required to reach this kind at all otherwise -- see
                # _paragraph_interrupt_kind) never coexists with an open
                # list item, so no ownership to preserve here.
                flush()
            continue

        if kind == "list":
            # wv-98984a: a marker immediately preceded by a residual
            # quote-tab is unrecognizable against probe's own literal
            # tab character -- match against the materialized view
            # instead (a no-op when there's nothing to materialize).
            structural = _materialize_quote_tab(line, probe, virtual_offset)
            list_match = _MARKDOWN_LIST_RE.match(structural)
            assert list_match is not None  # kind=="list" implies a marker match
            # list_stack is already trimmed to this marker's own owning
            # ancestor chain (the pop above ran against this SAME line,
            # before its kind was even known) -- preserve those ancestors
            # across flush() (which would otherwise unconditionally wipe
            # the stack) so the new item nests under them instead of
            # discarding them, the fix _pop_unowned_list_frames exists
            # for.
            preserved_ancestors = list_stack
            flush()
            list_stack, container = _restore_owned_list_stack(
                preserved_ancestors, clear_has_paragraph=True
            )
            container = "list"
            # NOT line.index(content): if content duplicates a structural
            # marker elsewhere on the line (e.g. "1. 1" -- the captured
            # "1" also matches the ordinal's own digit), index() would
            # return that marker's position instead of the captured
            # content's real one -- see _open_list_item.
            new_ctx, content, source_col, opened_block = _open_list_item(
                fence_state,
                html_state,
                list_match,
                line,
                probe,
                quote_depth,
                virtual_offset,
                len(structural) - len(probe),
            )
            list_stack.append(new_ctx)
            if opened_block:
                continue
            # A blank/empty item ("-" alone) seeds NO paragraph at all --
            # nothing for a later lazy line to continue (see
            # _ListItemContext) -- so nothing is appended for it either;
            # flush() on an empty `paragraph` is already a safe no-op.
            if content:
                paragraph.append((lineno, content, source_col))
            continue

        if container == "list" and kind in ("quote", "lazy"):
            assert list_stack
            attached = False
            while True:
                continuation = _list_item_continuation(
                    list_stack[-1], kind, line, probe, quote_depth, virtual_offset
                )
                if continuation is not None:
                    content, source_col = continuation
                    paragraph.append((lineno, content, source_col))
                    list_stack[-1].has_paragraph = True
                    attached = True
                    break
                # THIS item's own continuation fails -- pop just it (an
                # OUTER ancestor may still be legitimately open, see
                # _pop_unowned_list_frames) and reclassify the SAME
                # physical line fresh against whatever survives, instead
                # of reusing the kind computed under the frame that just
                # ended: _paragraph_interrupt_kind is container-
                # sensitive (code vs lazy in particular) -- a "quote"
                # line whose depth/indent no longer matches this item
                # must be reclassified once nothing owns it, or it
                # wrongly reflows as prose instead of being dropped as
                # indented code. Since wv-9d8474, kind=="lazy" can no
                # longer reach this pop at all (see
                # _list_item_continuation) -- an owned-but-paragraph-less
                # lazy line now always attaches as a fresh paragraph
                # instead of falling through to here. Bounded: each
                # failed attempt pops one frame, so this terminates in at
                # most len(list_stack) + 1 iterations.
                #
                # wv-a7a166 (external code review finding 2): popping the
                # failing frame alone, with no flush(), let its own
                # accumulated paragraph text keep growing in `paragraph`
                # even once a DIFFERENT (surviving ancestor) item starts
                # receiving new content on the next successful iteration
                # -- CommonMark treats the popped item's paragraph as a
                # COMPLETE, already-closed block the instant it stops
                # owning this line, distinct from whatever the surviving
                # ancestor accumulates next (which starts fresh per
                # wv-9d8474 if that ancestor's own paragraph was already
                # closed). Flush only when there was something of the
                # popped item's OWN to separate out -- skipping the
                # surviving-stack save/restore entirely when nothing
                # needs flushing keeps this identical to the pre-fix
                # behavior for the (far more common) has_paragraph=False
                # pop.
                popped = list_stack.pop()
                if popped.has_paragraph:
                    surviving = list_stack
                    flush()
                    list_stack, container = _restore_owned_list_stack(
                        surviving, clear_has_paragraph=False
                    )
                else:
                    container = "list" if list_stack else ""
                kind = _paragraph_interrupt_kind(
                    line,
                    probe,
                    quote_depth,
                    container,
                    virtual_offset,
                    list_stack[-1].content_col if list_stack else None,
                    list_stack[-1].has_paragraph if list_stack else False,
                )
                if not (container == "list" and kind in ("quote", "lazy")):
                    break
            if attached:
                continue
            # Every enclosing item was exhausted without one continuing
            # -- list_stack/container are already [] / "" (kind can only
            # remain "quote"/"lazy" while container == "list", so the
            # loop above only stops this way once the stack is fully
            # empty). `kind` is the freshly reclassified value for
            # whatever's left, which the branches below now use instead
            # of a stale one computed under a container that no longer
            # applies.
            flush()
            if kind == "code":
                continue

        if kind == "quote":
            # wv-191cc0 (external code review): re-matching `line` here
            # with the single-level _MARKDOWN_QUOTE_RE discarded
            # _dequote's own recursive result -- for a depth>=2 quote
            # ("> > target"), that regex only strips the FIRST ">",
            # leaving every deeper marker as literal paragraph text
            # ("> target" instead of "target"). `probe` (from _dequote(
            # line) at the top of this loop) is already this exact
            # line's fully quote-dequoted content for `quote_depth`
            # levels -- use it, and its own raw offset into `line`,
            # instead of rematching. Identical to depth==1 (a single
            # strip either way), a strict fix for depth>=2.
            content = probe
            source_col = len(line) - len(probe)
            # See _quote_depth_is_boundary: a depth change (entering or
            # leaving a nested blockquote) is a genuine block change and
            # starts its own paragraph unit, same as switching from a
            # different container kind.
            if container not in {"", "quote"} or _quote_depth_is_boundary(
                quote_depth, prior_quote_depth
            ):
                flush()
            container = "quote"
            prior_quote_depth = quote_depth
            paragraph.append((lineno, content, source_col))
            continue

        if kind in ("heading", "break") or "|" in line:
            # wv-784f03 (external code review round 3, finding 1): flush()
            # unconditionally resets list_stack to [] as a side effect of
            # emitting a paragraph -- but a partial nested-list pop (via
            # _pop_unowned_list_frames, run against this SAME line before
            # `kind` was even known) can leave a surviving OUTER owner in
            # list_stack. Preserve/restore it across flush() the same way
            # the "code" and "list" kind dispatches already do, instead
            # of discarding the owning ancestor chain.
            owning_stack = list_stack
            flush()
            list_stack, container = _restore_owned_list_stack(
                owning_stack, clear_has_paragraph=True
            )
            out.append(_ScanLine(line, ((0, lineno, 0),), len(out)))
            continue

        # kind == "lazy" with container != "list" (that combination was
        # already handled above): continues whatever quote/plain paragraph
        # is already open without its own marker -- CommonMark lazy
        # continuation, including a non-interrupting ordered item (its
        # digits/delimiter stay literal text, not a real list marker) and
        # indentation that couldn't interrupt an open paragraph. container
        # is already "quote"/"plain" (continue it as-is) or "" (nothing
        # open -- starts a fresh "plain" paragraph instead).
        if container == "":
            container = "plain"
        content, source_col = _lazy_paragraph_content(line, probe, quote_depth)
        paragraph.append((lineno, content, source_col))
    flush()
    return out


def _lexicon_findings(text: str, rule: dict[str, object]) -> list[_Span]:
    terms = _string_list(rule, "terms")
    exempt = [item.lower() for item in _string_list(rule, "exempt")]
    if not terms:
        return []
    rx = _word_regex(terms)
    out: list[_Span] = []
    for scan_line in _scan_lines(text, rule):
        line = scan_line.text
        lowered = line.lower()
        spans = [
            (pos, pos + len(exemption))
            for exemption in exempt
            for pos in _find_all(lowered, exemption)
        ]
        for match in rx.finditer(line):
            if any(start <= match.start() and match.end() <= end for start, end in spans):
                continue
            out.append((scan_line, match.start(), match.end(), match.group(0)))
    return out


def _motif_findings(text: str, rule: dict[str, object]) -> list[_Span]:
    """Flag terms that recur at least min_count times across the target.

    Digit-proximity suppression (skip hits with a nearby digit, on the theory
    that a nearby number is the local evidence the term is vouching for) is
    opt-in via require_no_digit_within: a window in characters. Rules that
    don't set it get plain frequency motif matching with no suppression.
    """
    terms = _string_list(rule, "terms")
    if not terms:
        return []
    min_count = int(str(rule.get("min_count", 3)))
    digit_window_raw = rule.get("require_no_digit_within")
    digit_window = int(str(digit_window_raw)) if digit_window_raw is not None else None
    lines = _scan_lines(text, rule)
    out: list[_Span] = []

    for term in terms:
        rx = _word_regex([term])
        hits = [
            (scan_line, match)
            for scan_line in lines
            for match in rx.finditer(scan_line.text)
        ]
        if len(hits) < min_count:
            continue
        for scan_line, match in hits:
            if digit_window is not None:
                line = scan_line.text
                lo = max(0, match.start() - digit_window)
                hi = min(len(line), match.end() + digit_window)
                if re.search(r"\d", line[lo:hi]):
                    continue
            out.append((scan_line, match.start(), match.end(), match.group(0)))
    return out


def _density_findings(text: str, rule: dict[str, object]) -> list[_Span]:
    """Flag literal terms that co-occur at least min_count times within a scope.

    Unlike regex (fires per match, no aggregation) or motif (word-boundary
    matching excludes punctuation, and counts one term against the whole
    file), density matches terms literally — so punctuation like an em dash
    is a valid term — and counts every configured term together within one
    scope. match_scope selects both the underlying text unit (same reflow
    _scan_lines gives the other kinds) and the counting boundary: paragraph
    counts each unit separately; document pools every unit in the file into
    one scope. This is the "rule of three" / em-dash-overuse shape.

    Overlapping raw hits (e.g. terms "foo" and "foobar" both matching inside
    "foobar", or a duplicate term) are collapsed to their physical spans
    *before* the min_count threshold is applied within each scope -- counting
    raw hits first (and collapsing only afterwards, as run_prose_rule's final
    pass does for every kind) would let a rule requiring N occurrences fire
    on fewer than N physical occurrences of text.
    """
    terms = _string_list(rule, "terms")
    if not terms:
        return []
    min_count = int(str(rule.get("min_count", 3)))
    default_scope = _default_match_scope(rule)
    match_scope = str(rule.get("match_scope", default_scope))
    units = _scan_lines(text, rule)
    scopes = [units] if match_scope == "document" else [[unit] for unit in units]

    out: list[_Span] = []
    for scope in scopes:
        raw_hits: list[_Span] = []
        for scan_line in scope:
            line = scan_line.text
            lowered = line.lower()
            for term in terms:
                for pos in _find_all(lowered, term.lower()):
                    raw_hits.append((scan_line, pos, pos + len(term), line[pos : pos + len(term)]))
        collapsed = _collapse_overlapping_spans(raw_hits)
        if len(collapsed) < min_count:
            continue
        out.extend(collapsed)
    return out


def _regex_findings(text: str, rule: dict[str, object]) -> list[_Span]:
    out: list[_Span] = []
    exemptions = [item.lower() for item in _string_list(rule, "exempt")]
    min_count = int(str(rule.get("min_count", 1)))
    for pattern in _string_list(rule, "patterns"):
        rx = re.compile(pattern, re.IGNORECASE)
        hits: list[tuple[_ScanLine, re.Match[str]]] = []
        for scan_line in _scan_lines(text, rule):
            line = scan_line.text
            lowered = line.lower()
            exempt_spans = [
                (pos, pos + len(exemption))
                for exemption in exemptions
                for pos in _find_all(lowered, exemption)
            ]
            for match in rx.finditer(line):
                if any(start <= match.start() and match.end() <= end for start, end in exempt_spans):
                    continue
                hits.append((scan_line, match))
        if len(hits) < min_count:
            continue
        for scan_line, match in hits:
            out.append((scan_line, match.start(), match.end(), match.group(0)))
    return out


_KIND_ENGINES = {
    "lexicon": _lexicon_findings,
    "motif": _motif_findings,
    "density": _density_findings,
    "regex": _regex_findings,
}


def run_prose_rule(
    rule_id: str, rule_path: Path, target: Path, scan_id: int, repo: Path | None = None
) -> list[PatternFinding]:
    """Execute one prose rule over target; same contract as _run_pattern_rule.

    `repo` scopes the rule's `paths:` globs -- they always match against the
    file's path relative to `repo`, never to `target`, so a rule's `paths:`
    means the same thing whether the scan targets the repo root, a
    subdirectory, or one file. Defaults to target's containing directory
    (or target itself, if target is already a directory) for callers
    (tests) that don't have a real repo root to pass.
    """
    rule = load_prose_rule(rule_path, rule_id)
    engine = _KIND_ENGINES.get(str(rule.get("kind", "")))
    assert engine is not None
    include = _string_list(rule, "paths")
    severity = str(rule.get("severity", "info"))
    findings: list[PatternFinding] = []
    effective_repo = repo if repo is not None else (target if target.is_dir() else target.parent)
    for path in _iter_text_files(target, include, effective_repo):
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError as exc:
            raise PatternRuleExecutionError(f"{rule_path}: cannot read target {path}: {exc}") from exc
        rel = str(path.relative_to(target)) if target.is_dir() else path.name
        for scan_line, start, _end, match_text in _collapse_overlapping_spans(engine(text, rule)):
            lineno, col = scan_line.source_position(start)
            findings.append(
                PatternFinding(
                    path=rel,
                    scan_id=scan_id,
                    rule_id=rule_id,
                    line=lineno,
                    col=col,
                    match_text=match_text,
                    severity=severity,
                )
            )
    return findings
