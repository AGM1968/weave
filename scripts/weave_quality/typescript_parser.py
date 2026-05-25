"""TypeScript quality scanner using ast-grep (tree-sitter-typescript).

Thin wrapper around ast-grep -- same FileEntry/FunctionCC output as python_parser.py.
Falls back gracefully when ast-grep is unavailable (returns None).

Two-pass approach:
  1. typescript_functions.yaml  -- function ranges + kinds
  2. typescript_cc.yaml         -- CC node line numbers

CC nodes are assigned to the innermost function whose range contains them.
"""

from __future__ import annotations

import json
import re
import shutil
import subprocess
from pathlib import Path
from typing import Any

from weave_quality.models import FileEntry, FunctionCC, FunctionDetail

_RULE_DIR = Path(__file__).parent / "rules"
_CC_RULE = _RULE_DIR / "typescript_cc.yaml"
_FN_RULE = _RULE_DIR / "typescript_functions.yaml"

_FN_NAME_RES: list[re.Pattern[str]] = [
    # named function: function foo(  /  async function foo(  /  function* foo(
    re.compile(r"(?:export\s+)?(?:default\s+)?(?:async\s+)?function\s*\*?\s*(\w+)\s*[(<]"),
    # named function expression: function foo(
    re.compile(r"function\s+(\w+)\s*\("),
    # method/accessor with modifiers: [static] [async|get|set|public|private|...] name(
    re.compile(
        r"(?:(?:async|get|set|static|override|public|private|protected|abstract|readonly)\s+)+"
        r"(\w+)\s*[(<\[]"
    ),
    # bare method name at start of text: name(  or  name<  (catches constructors + simple methods)
    re.compile(r"^(\w+)\s*[(<\[]"),
]

_METHOD_KEYWORDS = frozenset(
    ("async", "function", "get", "set", "static", "override", "public", "private",
     "protected", "abstract", "readonly")
)


def _fn_name(text: str) -> str:
    """Extract function name from ast-grep match text (no kind field available)."""
    for pat in _FN_NAME_RES:
        m = pat.match(text)
        if m:
            name = m.group(1)
            if name not in _METHOD_KEYWORDS:
                return name
    return "<anonymous>"


def _run_rule(rule_path: Path, filepath: str) -> list[dict[str, Any]] | None:
    """Run ast-grep scan with rule_path on filepath.

    Returns parsed JSON list, or None on hard error.
    Exit 1 with empty stdout = no matches (valid); exit 2 = error.
    """
    cmd = ["ast-grep", "scan", "--rule", str(rule_path), "--json", filepath]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=30, check=False)
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return None
    if proc.returncode == 2 or (proc.returncode not in (0, 1) and not proc.stdout.strip()):
        return None
    if not proc.stdout.strip():
        return []
    try:
        result = json.loads(proc.stdout)
        return result if isinstance(result, list) else None
    except json.JSONDecodeError:
        return None


def _parse_functions(matches: list[dict[str, Any]], filepath: str) -> list[FunctionDetail]:
    """Build FunctionDetail list from ast-grep function matches.

    Filters to multi-line functions (block bodies) only.
    One-line arrow functions like `x => expr` are excluded.
    ruleId 'typescript-methods' marks class method_definition nodes.
    """
    details: list[FunctionDetail] = []
    for m in matches:
        if m.get("file") != filepath:
            continue
        rng = m.get("range", {})
        start = rng.get("start", {})
        end = rng.get("end", {})
        line_start = start.get("line", 0) + 1  # 1-indexed
        line_end = end.get("line", 0) + 1
        if line_end <= line_start:
            continue  # skip one-liners
        text = str(m.get("text", ""))
        rule_id = str(m.get("ruleId", ""))
        name = _fn_name(text)
        parent_is_class = rule_id == "typescript-methods"
        details.append(
            FunctionDetail(
                name=name,
                line_start=line_start,
                line_end=line_end,
                complexity=1.0,
                essential_complexity=1.0,
                is_dispatch=False,
                parent_is_class=parent_is_class,
            )
        )
    return details


def analyze_typescript_file(
    filepath: str, scan_id: int = 0
) -> tuple[FileEntry, list[FunctionCC]] | None:
    """Analyse a TypeScript file via ast-grep.

    Returns (FileEntry, list[FunctionCC]) or None when ast-grep is unavailable.
    """
    if not shutil.which("ast-grep"):
        return None
    if not _CC_RULE.exists() or not _FN_RULE.exists():
        return None

    fn_matches = _run_rule(_FN_RULE, filepath)
    cc_matches = _run_rule(_CC_RULE, filepath)
    if fn_matches is None or cc_matches is None:
        return None

    functions = _parse_functions(fn_matches, filepath)

    cc_lines: list[int] = []
    for m in cc_matches:
        if m.get("file") == filepath:
            line = m.get("range", {}).get("start", {}).get("line", 0) + 1
            cc_lines.append(line)

    # Count LOC
    try:
        lines = Path(filepath).read_text(encoding="utf-8", errors="replace").splitlines()
        loc = len([ln for ln in lines if ln.strip()])
    except OSError:
        loc = 0

    # Assign CC nodes to functions (innermost first: sort by range width ascending)
    sorted_fns = sorted(functions, key=lambda f: f.line_end - f.line_start)
    assigned: set[int] = set()
    for fn in sorted_fns:
        fn_count = 0
        for i, ln in enumerate(cc_lines):
            if i not in assigned and fn.line_start <= ln <= fn.line_end:
                assigned.add(i)
                fn_count += 1
        fn.complexity = 1.0 + fn_count  # base + branches

    total_cc = 1.0 + len(cc_lines)
    max_nesting = 0  # not computed for TS
    avg_fn_len = (
        sum(f.line_end - f.line_start + 1 for f in functions) / len(functions)
        if functions else 0.0
    )

    entry = FileEntry(
        path=filepath,
        scan_id=scan_id,
        language="typescript",
        loc=loc,
        complexity=total_cc,
        functions=len(functions),
        max_nesting=max_nesting,
        avg_fn_len=avg_fn_len,
        essential_complexity=max(f.essential_complexity for f in functions) if functions else 1.0,
    )

    fn_cc_records: list[FunctionCC] = [
        FunctionCC(
            path=filepath,
            scan_id=scan_id,
            function_name=f.name,
            line_start=f.line_start,
            line_end=f.line_end,
            complexity=f.complexity,
            essential_complexity=f.essential_complexity,
            is_dispatch=f.is_dispatch,
        )
        for f in functions
    ]

    return entry, fn_cc_records
