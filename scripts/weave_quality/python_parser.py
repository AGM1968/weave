"""Python source analysis -- ast primary, regex fallback.

D1 decision: Option B -- use ast (stdlib) as primary path. Regex fallback
activates internally when ast.parse() fails (syntax errors, encoding issues).
No separate python_heuristic.py file.

Produces:
  - FileEntry: loc, complexity (cyclomatic), functions, max_nesting, avg_fn_len
  - CKMetrics: wmc, cbo, dit, rfc, lcom (ast path only)
"""

from __future__ import annotations

import ast
import logging
import re
from pathlib import Path
from typing import Any

from .models import CKMetrics, FileEntry

log = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Regex fallback patterns (from PROPOSAL-wv-quality.md Heuristic Parsers)
# ---------------------------------------------------------------------------

# Cyclomatic complexity proxy
_BRANCH_PATTERN = re.compile(
    r"^\s*(if |elif |for |while |except |assert |and |or |\S+\s+if\s+)"
)

# Function detection
_FUNC_PATTERN = re.compile(r"^\s*def\s+(\w+)\s*\(")

# Class detection
_CLASS_PATTERN = re.compile(r"^\s*class\s+(\w+)")

# Import coupling
_IMPORT_PATTERN = re.compile(r"^\s*(?:import|from)\s+(\S+)")


# ---------------------------------------------------------------------------
# AST-backed analysis (primary path)
# ---------------------------------------------------------------------------


class _ComplexityVisitor(ast.NodeVisitor):
    """Walk AST to compute cyclomatic complexity and nesting depth."""

    def __init__(self) -> None:
        self.complexity = 1  # Base complexity
        self._depth = 0
        self.max_nesting = 0

    def _enter_branch(self, node: ast.AST) -> None:
        self.complexity += 1
        self._depth += 1
        self.max_nesting = max(self.max_nesting, self._depth)
        self.generic_visit(node)
        self._depth -= 1

    visit_If = _enter_branch
    visit_For = _enter_branch
    visit_While = _enter_branch
    visit_ExceptHandler = _enter_branch

    def visit_BoolOp(self, node: ast.BoolOp) -> None:  # noqa: N802  # pylint: disable=invalid-name
        """Count each and/or as a branch path."""
        self.complexity += len(node.values) - 1
        self.generic_visit(node)

    def visit_Assert(self, node: ast.Assert) -> None:  # noqa: N802  # pylint: disable=invalid-name
        """Count assert as a branch."""
        self.complexity += 1
        self.generic_visit(node)

    def visit_comprehension(self, node: ast.comprehension) -> None:
        """Count comprehensions and their if-clauses."""
        self.complexity += 1
        self.complexity += len(node.ifs)
        self.generic_visit(node)


def _ast_function_lengths(tree: ast.Module) -> list[int]:
    """Return line counts for each top-level and method function."""
    lengths: list[int] = []
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            # end_lineno requires Python 3.8+
            if hasattr(node, "end_lineno") and node.end_lineno is not None:
                lengths.append(node.end_lineno - node.lineno + 1)
    return lengths


def _ast_nesting_depth(tree: ast.Module) -> int:
    """Compute maximum nesting depth via AST walk."""
    visitor = _ComplexityVisitor()
    visitor.visit(tree)
    return visitor.max_nesting


def _ast_complexity(tree: ast.Module) -> float:
    """Compute total cyclomatic complexity via AST."""
    visitor = _ComplexityVisitor()
    visitor.visit(tree)
    return float(visitor.complexity)


def _ast_function_count(tree: ast.Module) -> int:
    """Count functions and methods."""
    count = 0
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            count += 1
    return count


def _ast_ck_metrics(tree: ast.Module, path: str,
                    scan_id: int = 0) -> CKMetrics | None:
    """Compute CK-suite metrics from AST.

    Only meaningful for files with classes. Returns None for files
    without class definitions.

    Metrics (per PROPOSAL-wv-quality.md Academic Background):
      wmc: Weighted Methods per Class -- sum of CC per method across all classes
      cbo: Coupling Between Objects -- unique imports (module-level coupling)
      dit: Depth of Inheritance Tree -- max base class depth
      rfc: Response For Class -- method defs + Call nodes
      lcom: Lack of Cohesion in Methods -- 1 - (shared attrs / total attrs)
      noc: Number of Children -- needs cross-file scan, set to 0 here
    """
    classes = [n for n in ast.walk(tree) if isinstance(n, ast.ClassDef)]

    # CK metrics require classes; skip for purely procedural files
    # But still compute cbo (module-level coupling) as it's useful
    imports: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                imports.add(alias.name.split(".")[0])
        elif isinstance(node, ast.ImportFrom):
            if node.module:
                imports.add(node.module.split(".")[0])

    if not classes:
        # No classes, but still report cbo for coupling analysis
        if imports:
            return CKMetrics(
                path=path, scan_id=scan_id,
                metrics={"cbo": float(len(imports))},
            )
        return None

    # WMC: sum of CC for all methods in all classes
    wmc = 0
    for cls_node in classes:
        for item in ast.walk(cls_node):
            if isinstance(item, (ast.FunctionDef, ast.AsyncFunctionDef)):
                visitor = _ComplexityVisitor()
                visitor.visit(item)
                wmc += visitor.complexity

    # DIT: depth of inheritance tree (max across all classes)
    dit = 0
    for cls_node in classes:
        depth = len(cls_node.bases)  # Direct base count (approximation)
        dit = max(dit, depth)

    # RFC: method definitions + Call nodes in all classes
    rfc = 0
    for cls_node in classes:
        for item in ast.walk(cls_node):
            if isinstance(item, (ast.FunctionDef, ast.AsyncFunctionDef)):
                rfc += 1
            elif isinstance(item, ast.Call):
                rfc += 1

    # LCOM: Lack of Cohesion in Methods
    # 1 - (methods_sharing_attrs / total_methods)
    lcom = _compute_lcom(classes)

    return CKMetrics(
        path=path, scan_id=scan_id,
        metrics={
            "wmc": float(wmc),
            "cbo": float(len(imports)),
            "dit": float(dit),
            "rfc": float(rfc),
            "lcom": lcom,
            "noc": 0.0,  # Requires cross-file analysis
        },
    )


def _compute_lcom(classes: list[ast.ClassDef]) -> float:
    """Compute LCOM (Lack of Cohesion in Methods).

    For each class, find which methods share instance attributes (self.x).
    LCOM = 1 - (pairs_sharing / total_pairs). Averaged across classes.
    Returns 0.0 if no classes or no methods.
    """
    if not classes:
        return 0.0

    lcom_values: list[float] = []
    for cls_node in classes:
        methods: list[set[str]] = []
        for item in ast.iter_child_nodes(cls_node):
            if isinstance(item, (ast.FunctionDef, ast.AsyncFunctionDef)):
                attrs: set[str] = set()
                for node in ast.walk(item):
                    if (isinstance(node, ast.Attribute)
                            and isinstance(node.value, ast.Name)
                            and node.value.id == "self"):
                        attrs.add(node.attr)
                methods.append(attrs)

        if len(methods) < 2:
            lcom_values.append(0.0)
            continue

        # Count pairs sharing at least one attribute
        total_pairs = 0
        sharing_pairs = 0
        for i, method_i in enumerate(methods):
            for method_j in methods[i + 1:]:
                total_pairs += 1
                if method_i & method_j:
                    sharing_pairs += 1

        if total_pairs == 0:
            lcom_values.append(0.0)
        else:
            lcom_values.append(1.0 - (sharing_pairs / total_pairs))

    return sum(lcom_values) / len(lcom_values) if lcom_values else 0.0


# ---------------------------------------------------------------------------
# Regex fallback (activates when ast.parse fails)
# ---------------------------------------------------------------------------


def _regex_analyze(source: str) -> dict[str, Any]:
    """Regex-based analysis fallback for files that fail ast.parse()."""
    lines = source.splitlines()
    non_empty = [ln for ln in lines if ln.strip() and not ln.strip().startswith("#")]

    complexity = 1  # Base
    functions = 0
    max_nesting = 0
    func_starts: list[int] = []
    imports: set[str] = set()

    for i, line in enumerate(lines):
        if _BRANCH_PATTERN.match(line):
            complexity += 1
        if _FUNC_PATTERN.match(line):
            functions += 1
            func_starts.append(i)
        if _IMPORT_PATTERN.match(line):
            m = _IMPORT_PATTERN.match(line)
            if m:
                imports.add(m.group(1).split(".")[0])

        # Nesting: count leading whitespace (assuming 4-space indent)
        stripped = line.lstrip()
        if stripped and not stripped.startswith("#"):
            indent = len(line) - len(stripped)
            level = indent // 4
            max_nesting = max(max_nesting, level)

    # Estimate average function length
    avg_fn_len = 0.0
    if func_starts:
        lengths: list[int] = []
        for idx, start in enumerate(func_starts):
            end = func_starts[idx + 1] if idx + 1 < len(func_starts) else len(lines)
            lengths.append(end - start)
        avg_fn_len = sum(lengths) / len(lengths) if lengths else 0.0

    return {
        "loc": len(non_empty),
        "complexity": float(complexity),
        "functions": functions,
        "max_nesting": max_nesting,
        "avg_fn_len": avg_fn_len,
    }


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def analyze_python_file(filepath: str | Path,
                        scan_id: int = 0) -> tuple[FileEntry, CKMetrics | None]:
    """Analyze a Python source file.

    Returns (FileEntry, CKMetrics or None).
    Uses ast as primary path; falls back to regex on parse failure.
    """
    path = Path(filepath)
    try:
        source = path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        log.warning("Cannot read %s: %s", filepath, exc)
        return FileEntry(path=str(filepath), scan_id=scan_id, language="python"), None

    return analyze_python_source(source, str(filepath), scan_id)


def analyze_python_source(source: str, filepath: str,
                          scan_id: int = 0) -> tuple[FileEntry, CKMetrics | None]:
    """Analyze Python source code (string).

    Primary path: ast.parse() for accurate metrics + CK suite.
    Fallback: regex heuristics if ast fails (no CK metrics in fallback).
    """
    lines = source.splitlines()
    non_empty = [ln for ln in lines if ln.strip() and not ln.strip().startswith("#")]
    loc = len(non_empty)

    # Try ast path first (D1=Option B)
    try:
        tree = ast.parse(source, filename=filepath)
        complexity = _ast_complexity(tree)
        functions = _ast_function_count(tree)
        max_nesting = _ast_nesting_depth(tree)

        fn_lengths = _ast_function_lengths(tree)
        avg_fn_len = sum(fn_lengths) / len(fn_lengths) if fn_lengths else 0.0

        ck = _ast_ck_metrics(tree, filepath, scan_id)

        entry = FileEntry(
            path=filepath,
            scan_id=scan_id,
            language="python",
            loc=loc,
            complexity=complexity,
            functions=functions,
            max_nesting=max_nesting,
            avg_fn_len=avg_fn_len,
        )
        return entry, ck

    except SyntaxError:
        log.debug("ast.parse failed for %s, using regex fallback", filepath)

    # Regex fallback
    result = _regex_analyze(source)
    entry = FileEntry(
        path=filepath,
        scan_id=scan_id,
        language="python",
        loc=loc,
        complexity=result["complexity"],
        functions=result["functions"],
        max_nesting=result["max_nesting"],
        avg_fn_len=result["avg_fn_len"],
    )
    return entry, None  # No CK metrics from regex path
