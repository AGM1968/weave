"""Bash CC analysis using ast-grep (tree-sitter AST).

Replaces the regex branch-counting in bash_heuristic._function_cc with
accurate AST-level node counting. Eliminates two known heuristic biases:
  - case arms: regex counted +1 for 'case' keyword; AST counts each case_item arm
  - &&/|| in strings: regex had 18.6% false-positive rate; AST ignores string content

Falls back to bash_heuristic when ast-grep binary is absent.
"""

from __future__ import annotations

import json
import logging
import subprocess
from pathlib import Path

from .bash_heuristic import (
    _count_nesting,
    _find_function_ranges,
    _function_name,
    _indent_sd,
    analyze_bash_source,
)
from .external_tools import ast_grep_bin
from .models import FileEntry, FunctionCC

log = logging.getLogger(__name__)

_RULE_FILE = Path(__file__).parent / "rules" / "bash_cc.yaml"


def _parse_ast_grep_output(stdout: str, filepaths: list[str]) -> dict[str, list[int]] | None:
    """Parse ast-grep JSON output into a per-file map of CC line numbers.

    Used by both single-file and batch paths. Returns None on parse error.
    """
    if not stdout.strip():
        return {fp: [] for fp in filepaths}
    try:
        matches = json.loads(stdout)
    except json.JSONDecodeError:
        return None
    if not isinstance(matches, list):
        return None

    result: dict[str, list[int]] = {fp: [] for fp in filepaths}
    for m in matches:
        fp = m.get("file", "")
        rng = m.get("range", {})
        line = rng.get("start", {}).get("line")
        if fp in result and isinstance(line, int):
            result[fp].append(line)
    for fp in result:
        result[fp].sort()
    return result


def _cc_lines_from_ast_grep(filepath: str) -> list[int] | None:
    """Run ast-grep on a bash file; return sorted 0-indexed line numbers of CC nodes.

    Returns None if ast-grep is absent, errors, or times out.
    Exit 1 from ast-grep means no matches (not an error).
    """
    ast_grep = ast_grep_bin()
    if not ast_grep:
        return None
    cmd = [ast_grep, "scan", "--rule", str(_RULE_FILE), "--json", filepath]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=30, check=False)
    except subprocess.TimeoutExpired:
        log.warning("ast-grep timed out on %s", filepath)
        return None

    if proc.returncode == 2 or (proc.returncode not in (0, 1) and not proc.stdout.strip()):
        log.warning("ast-grep error on %s: %s", filepath, proc.stderr.strip()[:200])
        return None

    parsed = _parse_ast_grep_output(proc.stdout, [filepath])
    if parsed is None:
        log.warning("ast-grep JSON parse error on %s", filepath)
        return None
    return parsed.get(filepath, [])


def batch_cc_lines(filepaths: list[str]) -> dict[str, list[int]] | None:
    """Run ast-grep ONCE on all filepaths; return per-file CC line map.

    Reduces N subprocess spawns to 1 for a full scan.
    Returns None if ast-grep is absent or times out; callers fall back per-file.
    Files with no matches get an empty list (not None).
    """
    ast_grep = ast_grep_bin()
    if not filepaths or not ast_grep:
        return None
    cmd = [ast_grep, "scan", "--rule", str(_RULE_FILE), "--json"] + filepaths
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=120, check=False)
    except subprocess.TimeoutExpired:
        log.warning("ast-grep batch timed out (%d files)", len(filepaths))
        return None

    if proc.returncode == 2 or (proc.returncode not in (0, 1) and not proc.stdout.strip()):
        log.warning("ast-grep batch error: %s", proc.stderr.strip()[:200])
        return None

    parsed = _parse_ast_grep_output(proc.stdout, filepaths)
    if parsed is None:
        log.warning("ast-grep batch JSON parse error")
        return None
    return parsed


def analyze_bash_source_ast_grep(
    source: str,
    filepath: str,
    scan_id: int = 0,
    cc_lines: list[int] | None = None,
) -> tuple[FileEntry, list[FunctionCC]] | None:
    """Analyze Bash source using ast-grep for CC.

    Returns (FileEntry, list[FunctionCC]) or None when ast-grep is unavailable.
    Caller should fall back to analyze_bash_source from bash_heuristic.

    When cc_lines is provided (from batch_cc_lines), skips the subprocess call.

    All non-CC metrics (nesting, indent_sd, loc, avg_fn_len) keep the
    existing heuristic — they are not biased by the branch-counting issue.
    Function boundary detection also reuses _find_function_ranges from
    bash_heuristic; only the per-branch count inside each function changes.
    """
    if cc_lines is None:
        cc_lines = _cc_lines_from_ast_grep(filepath)
    if cc_lines is None:
        return None

    lines = source.splitlines()
    non_empty = [ln for ln in lines if ln.strip() and not ln.strip().startswith("#")]
    loc = len(non_empty)

    # File-level CC: base 1 + all branch nodes in file
    complexity = 1 + len(cc_lines)

    # Per-function CC
    func_ranges = _find_function_ranges(lines)
    functions = len(func_ranges)

    avg_fn_len = 0.0
    fn_cc_list: list[FunctionCC] = []
    if func_ranges:
        lengths = [end - start + 1 for start, end in func_ranges]
        avg_fn_len = sum(lengths) / len(lengths)

        for start, end in func_ranges:
            # Branch nodes whose start line falls within this function (0-indexed)
            fn_branches = sum(1 for ln in cc_lines if start <= ln <= end)
            name = _function_name(lines[start])
            fn_cc_list.append(
                FunctionCC(
                    path=filepath,
                    scan_id=scan_id,
                    function_name=name,
                    line_start=start + 1,  # 1-indexed for display
                    line_end=end + 1,
                    complexity=float(1 + fn_branches),
                )
            )

    entry = FileEntry(
        path=filepath,
        scan_id=scan_id,
        language="bash",
        loc=loc,
        complexity=float(complexity),
        functions=functions,
        max_nesting=_count_nesting(lines),
        avg_fn_len=avg_fn_len,
        indent_sd=_indent_sd(lines),
    )
    return entry, fn_cc_list


def ast_grep_available() -> bool:
    """Return True if the ast-grep binary is available to Weave."""
    return ast_grep_bin() is not None


def analyze_bash_file_best(
    filepath: str,
    scan_id: int = 0,
    batch_cc: dict[str, list[int]] | None = None,
) -> tuple[FileEntry, list[FunctionCC], str]:
    """Analyze a bash file using the best available backend.

    Returns (FileEntry, list[FunctionCC], backend_name).
    backend_name is 'ast-grep' or 'regex'.

    When batch_cc is provided (from batch_cc_lines), uses pre-computed CC lines
    instead of spawning a subprocess per file.
    """
    try:
        source = Path(filepath).read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        log.warning("Could not read %s: %s", filepath, exc)
        source = ""

    pre_cc = batch_cc.get(filepath) if batch_cc is not None else None
    result = analyze_bash_source_ast_grep(source, filepath, scan_id, cc_lines=pre_cc)
    if result is not None:
        entry, fn_cc = result
        return entry, fn_cc, "ast-grep"

    entry, fn_cc = analyze_bash_source(source, filepath, scan_id)
    return entry, fn_cc, "regex"
