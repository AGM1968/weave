"""Bash source analysis -- regex heuristics only.

No ast equivalent exists for Bash. All metrics are regex-based.
Patterns from PROPOSAL-wv-quality.md Heuristic Parsers section.

Produces:
  - FileEntry: loc, complexity (cyclomatic proxy), functions, max_nesting, avg_fn_len
  - No CKMetrics (OO metrics not applicable to Bash)
"""

from __future__ import annotations

import logging
import math
import re
from pathlib import Path

from .models import FileEntry, FunctionCC

log = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Regex patterns (from PROPOSAL-wv-quality.md Heuristic Parsers)
# ---------------------------------------------------------------------------

# Cyclomatic complexity proxy
_BRANCH_PATTERN = re.compile(
    r"\b(if|elif|case|for|while|until)\b|&&|\|\|"
)

# Function detection: name() { or function name { or function name() {
_FUNC_PATTERN = re.compile(
    r"^\s*(?:function\s+(\w+)\s*(?:\(\))?\s*\{?|(\w+)\s*\(\)\s*\{?)"
)

# Source coupling
_SOURCE_PATTERN = re.compile(r"(?:source|\.)\s+[\"']?(\S+)")

# External tool coupling
_TOOL_PATTERN = re.compile(
    r"\b(sqlite3|curl|jq|gh|git|python3|sed|awk)\b"
)

# Bash indent width: 2 spaces (common convention)
_BASH_INDENT_WIDTH = 2


def _indent_sd(lines: list[str], indent_width: int = _BASH_INDENT_WIDTH) -> float:
    """Compute stddev of indentation levels across non-empty Bash lines.

    Uses the same formula as python_parser._indent_sd but with a 2-space
    default indent width. Especially useful for Bash where CC is regex-only.
    Returns 0.0 for files with fewer than 2 non-empty lines.
    """
    levels: list[float] = []
    for line in lines:
        stripped = line.lstrip()
        if not stripped or stripped.startswith("#"):
            continue
        raw = line[:len(line) - len(stripped)]
        # Handle tabs: each tab counts as one indent_width unit
        depth: float
        if "\t" in raw:
            depth = float(raw.count("\t"))
        else:
            depth = len(raw) / indent_width
        levels.append(depth)
    if len(levels) < 2:
        return 0.0
    mean = sum(levels) / len(levels)
    variance = sum((x - mean) ** 2 for x in levels) / len(levels)
    return math.sqrt(variance)


# ---------------------------------------------------------------------------
# Analysis
# ---------------------------------------------------------------------------


def _count_nesting(lines: list[str]) -> int:
    """Estimate max nesting depth from indentation.

    Bash uses varied indentation; we count tab or 2/4-space levels.
    """
    max_depth = 0
    for line in lines:
        stripped = line.lstrip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(line) - len(stripped)
        # Tabs count as 1 level each; spaces divided by detected indent width
        if "\t" in line[:indent]:
            depth = line[:indent].count("\t")
        else:
            # Detect indent unit: 2 or 4 spaces (default to 2 for Bash)
            depth = indent // 2
        max_depth = max(max_depth, depth)
    return max_depth


# Heredoc start: <<EOF, <<'EOF', <<"EOF", <<-EOF, etc.
_HEREDOC_START = re.compile(r"<<-?\s*['\"]?(\w+)['\"]?")

# Heredoc end: the delimiter alone on a line (possibly with leading tabs for <<-)
_HEREDOC_END_CACHE: dict[str, re.Pattern[str]] = {}


def _heredoc_end_pattern(delim: str) -> re.Pattern[str]:
    """Return a compiled regex for a heredoc end delimiter."""
    if delim not in _HEREDOC_END_CACHE:
        _HEREDOC_END_CACHE[delim] = re.compile(rf"^\t*{re.escape(delim)}\s*$")
    return _HEREDOC_END_CACHE[delim]


def _find_function_ranges(lines: list[str]) -> list[tuple[int, int]]:
    """Find (start, end) line ranges for Bash functions.

    Uses structural brace matching: only counts braces that appear as
    standalone structural elements, not braces inside strings, parameter
    expansions (``${var}``), jq expressions, or heredocs.

    Rules:
      - Opening brace: on the function definition line (``func() {``)
        or a standalone ``{`` line immediately after.
      - Closing brace: a line whose stripped content is just ``}``
        (the standard Bash convention for ending a function body).
      - One-liner functions (``func() { ...; }``) are detected when
        the definition line ends with ``}`` or ``; }`` after the opening
        brace — the function range is just that single line.
      - Nested function definitions (e.g. ``_helper() {`` inside
        ``cmd_foo() {``) increment depth so the outer function's
        closing ``}`` is found correctly.
      - Heredoc content (between ``<<EOF`` and ``EOF``) is skipped
        entirely to avoid counting ``}`` in JSON/YAML/text blocks.

    This avoids bugs where ``${var}``, ``"{"`` in strings, jq
    ``'. + {key: $v}'``, heredoc JSON content, or one-liner utility
    functions caused incorrect function boundaries.
    """
    ranges: list[tuple[int, int]] = []
    for i, line in enumerate(lines):
        if _FUNC_PATTERN.match(line):
            end = _find_function_end(lines, i)
            ranges.append((i, end))
    return ranges


def _find_function_end(lines: list[str], start: int) -> int:
    """Find the closing line of a function starting at ``start``.

    Returns the 0-indexed line number of the closing ``}``.
    """
    depth = 0
    found_open = False
    in_heredoc: str | None = None

    for j in range(start, len(lines)):
        stripped = lines[j].strip()

        # Skip heredoc content — } inside heredocs is not structural
        if in_heredoc is not None:
            if _heredoc_end_pattern(in_heredoc).match(lines[j]):
                in_heredoc = None
            continue

        # Check if this line starts a heredoc
        heredoc_match = _HEREDOC_START.search(lines[j])
        if heredoc_match:
            in_heredoc = heredoc_match.group(1)

        # Function definition line — count its opening brace
        if j == start:
            if "{" in stripped:
                depth += 1
                found_open = True
                # One-liner: func() { ...; } — both { and } on same line
                if stripped.endswith("}") or stripped.endswith("; }"):
                    return j
            continue

        # Line immediately after def may have standalone "{"
        if not found_open and stripped == "{":
            depth += 1
            found_open = True
            continue

        # Nested function definition — count opening brace
        if _FUNC_PATTERN.match(lines[j]):
            if "{" in stripped:
                depth += 1
            continue

        # Standalone closing brace — structural function close
        if stripped == "}":
            depth -= 1
            if found_open and depth <= 0:
                return j

    # No matching close brace found; use rest of file
    return len(lines) - 1


def _function_cc(lines: list[str], start: int, end: int) -> int:
    """Compute cyclomatic complexity proxy for a single function body."""
    cc = 1  # Base
    for line in lines[start:end + 1]:
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        cc += len(_BRANCH_PATTERN.findall(line))
    return cc


def _function_name(line: str) -> str:
    """Extract function name from a line matching _FUNC_PATTERN."""
    m = _FUNC_PATTERN.match(line)
    if not m:
        return "<unknown>"
    return m.group(1) or m.group(2) or "<unknown>"


def analyze_bash_source(source: str, filepath: str,
                        scan_id: int = 0) -> tuple[FileEntry, list[FunctionCC]]:
    """Analyze Bash source code string.

    Returns (FileEntry, list[FunctionCC]) with heuristic-derived metrics.
    """
    lines = source.splitlines()
    non_empty = [
        ln for ln in lines
        if ln.strip() and not ln.strip().startswith("#")
    ]
    loc = len(non_empty)

    # Cyclomatic complexity proxy: count branch keywords + logical operators
    complexity = 1  # Base
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        complexity += len(_BRANCH_PATTERN.findall(line))

    # Function count and lengths + per-function CC
    func_ranges = _find_function_ranges(lines)
    functions = len(func_ranges)

    avg_fn_len = 0.0
    fn_cc_list: list[FunctionCC] = []
    if func_ranges:
        lengths = [end - start + 1 for start, end in func_ranges]
        avg_fn_len = sum(lengths) / len(lengths)

        for start, end in func_ranges:
            name = _function_name(lines[start])
            cc = _function_cc(lines, start, end)
            fn_cc_list.append(FunctionCC(
                path=filepath,
                scan_id=scan_id,
                function_name=name,
                line_start=start + 1,  # 1-indexed
                line_end=end + 1,
                complexity=float(cc),
            ))

    # Max nesting
    max_nesting = _count_nesting(lines)

    entry = FileEntry(
        path=filepath,
        scan_id=scan_id,
        language="bash",
        loc=loc,
        complexity=float(complexity),
        functions=functions,
        max_nesting=max_nesting,
        avg_fn_len=avg_fn_len,
        indent_sd=_indent_sd(lines),
    )
    return entry, fn_cc_list


def analyze_bash_file(filepath: str | Path,
                      scan_id: int = 0) -> tuple[FileEntry, list[FunctionCC]]:
    """Analyze a Bash source file.

    Returns (FileEntry, list[FunctionCC]) with heuristic metrics.
    """
    path = Path(filepath)
    try:
        source = path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        log.warning("Cannot read %s: %s", filepath, exc)
        return FileEntry(path=str(filepath), scan_id=scan_id, language="bash"), []

    return analyze_bash_source(source, str(filepath), scan_id)


def detect_bash(filepath: str | Path) -> bool:
    """Heuristic to detect if a file is Bash/Shell script.

    Checks extension (.sh, .bash) or shebang line (#!/bin/bash, #!/bin/sh, etc.).
    """
    p = Path(filepath)
    if p.suffix in (".sh", ".bash"):
        return True

    # Check shebang
    try:
        with open(p, "r", encoding="utf-8", errors="replace") as f:
            first_line = f.readline(256)
        return bool(re.match(r"^#!\s*/(?:usr/)?(?:bin/)?(?:env\s+)?(?:ba)?sh\b",
                             first_line))
    except OSError:
        return False
