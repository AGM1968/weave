"""Prose-register pattern backend for `wv quality patterns` (stdlib-only).

Runs lexicon/motif/regex rules over Markdown and plain-text files and returns
PatternFinding rows under the same contract as __main__._run_pattern_rule.
Rules use a small YAML subset because this package declares zero Python
dependencies and must not import PyYAML; parse_flat_rule() raises on nested
mappings rather than misreading them.
"""

from __future__ import annotations

import re
from fnmatch import fnmatch
from pathlib import Path
from typing import Iterator

from weave_quality.models import PatternFinding

PROSE_LANGUAGES = {"prose", "markdown"}
_TEXT_SUFFIXES = {".md", ".markdown", ".rst", ".txt"}
_SKIP_PARTS = {".git", "node_modules", ".venv", "venv", "archive", "__pycache__"}

_LANG_RE = re.compile(r"^language:\s*([A-Za-z0-9_-]+)", re.MULTILINE)


def rule_language(rule_path: Path) -> str:
    """Return the rule's language field, lowercased, or an empty string."""
    try:
        match = _LANG_RE.search(rule_path.read_text(encoding="utf-8"))
    except OSError:
        return ""
    return match.group(1).lower() if match else ""


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

    for lineno, raw in enumerate(
        rule_path.read_text(encoding="utf-8").splitlines(), start=1
    ):
        line = raw.split("#", 1)[0].rstrip()
        if not line.strip():
            continue
        stripped = line.strip()

        if scalar_key is not None and line[0] in " \t":
            scalar_parts.append(stripped)
            continue
        if scalar_key is not None:
            data[scalar_key] = " ".join(scalar_parts)
            scalar_key = None
            scalar_parts = []

        if stripped.startswith("- "):
            if current_list is None:
                raise ValueError(f"{rule_path.name}:{lineno}: list item outside a list")
            current_list.append(stripped[2:].strip().strip("'\""))
            continue
        if line[0] in " \t":
            raise ValueError(
                f"{rule_path.name}:{lineno}: nested mapping unsupported in prose rules"
            )
        key, sep, value = line.partition(":")
        if not sep:
            raise ValueError(f"{rule_path.name}:{lineno}: expected 'key: value'")
        key = key.strip()
        value = value.strip().strip("'\"")
        if value in {">", ">-", "|", "|-"}:
            scalar_key = key
            scalar_parts = []
            current_list = None
        elif value:
            data[key] = value
            current_list = None
        else:
            current_list = []
            data[key] = current_list

    if scalar_key is not None:
        data[scalar_key] = " ".join(scalar_parts)
    return data


def _iter_text_files(target: Path, include: list[str]) -> list[Path]:
    if target.is_file():
        return [target] if target.suffix.lower() in _TEXT_SUFFIXES else []
    files: list[Path] = []
    for path in sorted(target.rglob("*")):
        if not path.is_file() or path.suffix.lower() not in _TEXT_SUFFIXES:
            continue
        if _SKIP_PARTS.intersection(path.parts):
            continue
        rel = str(path.relative_to(target))
        if include and not any(fnmatch(rel, glob) for glob in include):
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


def _lexicon_findings(text: str, rule: dict[str, object]) -> list[tuple[int, int, str]]:
    terms = _string_list(rule, "terms")
    exempt = [item.lower() for item in _string_list(rule, "exempt")]
    if not terms:
        return []
    rx = _word_regex(terms)
    out: list[tuple[int, int, str]] = []
    for lineno, line in enumerate(text.splitlines(), start=1):
        lowered = line.lower()
        spans = [
            (pos, pos + len(exemption))
            for exemption in exempt
            for pos in _find_all(lowered, exemption)
        ]
        for match in rx.finditer(line):
            if any(start <= match.start() and match.end() <= end for start, end in spans):
                continue
            out.append((lineno, match.start(), line.strip()[:200]))
    return out


def _motif_findings(text: str, rule: dict[str, object]) -> list[tuple[int, int, str]]:
    terms = _string_list(rule, "terms")
    if not terms:
        return []
    window = int(str(rule.get("near_window", 80)))
    min_count = int(str(rule.get("min_count", 3)))
    lines = text.splitlines()
    out: list[tuple[int, int, str]] = []

    for term in terms:
        rx = _word_regex([term])
        hits = [
            (lineno, match)
            for lineno, line in enumerate(lines, start=1)
            for match in rx.finditer(line)
        ]
        if len(hits) < min_count:
            continue
        for lineno, match in hits:
            line = lines[lineno - 1]
            lo = max(0, match.start() - window)
            hi = min(len(line), match.end() + window)
            if not re.search(r"\d", line[lo:hi]):
                out.append((lineno, match.start(), line.strip()[:200]))
    return sorted(out)


def _regex_findings(text: str, rule: dict[str, object]) -> list[tuple[int, int, str]]:
    out: list[tuple[int, int, str]] = []
    for pattern in _string_list(rule, "patterns"):
        rx = re.compile(pattern, re.IGNORECASE)
        for lineno, line in enumerate(text.splitlines(), start=1):
            for match in rx.finditer(line):
                out.append((lineno, match.start(), line.strip()[:200]))
    return out


_KIND_ENGINES = {
    "lexicon": _lexicon_findings,
    "motif": _motif_findings,
    "regex": _regex_findings,
}


def run_prose_rule(
    rule_id: str, rule_path: Path, target: Path, scan_id: int
) -> list[PatternFinding]:
    """Execute one prose rule over target; same contract as _run_pattern_rule."""
    try:
        rule = parse_flat_rule(rule_path)
    except (OSError, ValueError):
        return []
    engine = _KIND_ENGINES.get(str(rule.get("kind", "")))
    if engine is None:
        return []
    include = _string_list(rule, "paths")
    severity = str(rule.get("severity", "info"))
    findings: list[PatternFinding] = []
    for path in _iter_text_files(target, include):
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        rel = str(path.relative_to(target)) if target.is_dir() else path.name
        for lineno, col, match_text in engine(text, rule):
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
