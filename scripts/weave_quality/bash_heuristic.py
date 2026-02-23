"""Bash source analysis -- regex heuristics only.

No ast equivalent exists for Bash. All metrics are regex-based.
Patterns from PROPOSAL-wv-quality.md Heuristic Parsers section.

Produces:
  - FileEntry: loc, complexity (cyclomatic proxy), functions, max_nesting, avg_fn_len
  - No CKMetrics (OO metrics not applicable to Bash)
"""

from __future__ import annotations

import logging
import re
from pathlib import Path

from .models import FileEntry

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


def _find_function_ranges(lines: list[str]) -> list[tuple[int, int]]:
    """Find (start, end) line ranges for Bash functions.

    Uses brace matching to find function body boundaries.
    """
    ranges: list[tuple[int, int]] = []
    i = 0
    while i < len(lines):
        if _FUNC_PATTERN.match(lines[i]):
            start = i
            # Find the opening brace
            brace_depth = 0
            found_open = False
            for j in range(i, len(lines)):
                brace_depth += lines[j].count("{") - lines[j].count("}")
                if "{" in lines[j]:
                    found_open = True
                if found_open and brace_depth <= 0:
                    ranges.append((start, j))
                    break
            else:
                # No matching close brace found; use rest of file
                ranges.append((start, len(lines) - 1))
        i += 1
    return ranges


def analyze_bash_source(source: str, filepath: str,
                        scan_id: int = 0) -> FileEntry:
    """Analyze Bash source code string.

    Returns a FileEntry with heuristic-derived metrics.
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

    # Function count and lengths
    func_ranges = _find_function_ranges(lines)
    functions = len(func_ranges)

    avg_fn_len = 0.0
    if func_ranges:
        lengths = [end - start + 1 for start, end in func_ranges]
        avg_fn_len = sum(lengths) / len(lengths)

    # Max nesting
    max_nesting = _count_nesting(lines)

    return FileEntry(
        path=filepath,
        scan_id=scan_id,
        language="bash",
        loc=loc,
        complexity=float(complexity),
        functions=functions,
        max_nesting=max_nesting,
        avg_fn_len=avg_fn_len,
    )


def analyze_bash_file(filepath: str | Path,
                      scan_id: int = 0) -> FileEntry:
    """Analyze a Bash source file.

    Returns a FileEntry with heuristic metrics.
    """
    path = Path(filepath)
    try:
        source = path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        log.warning("Cannot read %s: %s", filepath, exc)
        return FileEntry(path=str(filepath), scan_id=scan_id, language="bash")

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
