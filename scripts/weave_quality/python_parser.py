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
import math
import re
import sys
from pathlib import Path
from typing import Any, Optional, Tuple

from .models import ASTAnalysis, CKMetrics, FileEntry, FunctionCC, FunctionDetail

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

# Indent width for SD computation (PEP 8: 4 spaces)
_PYTHON_INDENT_WIDTH = 4


def _indent_sd(lines: list[str], indent_width: int = _PYTHON_INDENT_WIDTH) -> float:
    """Compute standard deviation of indentation levels across non-empty lines.

    Tornhill 2018: high indent_sd indicates 'islands of deep nesting'
    within otherwise flat files -- a structural complexity signal.

    Formula: stddev([indent_level(line) for non-empty non-comment lines])
    where indent_level = leading_spaces / indent_width.
    Returns 0.0 for files with fewer than 2 non-empty lines.
    """
    levels: list[float] = []
    for line in lines:
        stripped = line.lstrip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(line) - len(stripped)
        levels.append(indent / indent_width)
    if len(levels) < 2:
        return 0.0
    mean = sum(levels) / len(levels)
    variance = sum((x - mean) ** 2 for x in levels) / len(levels)
    return math.sqrt(variance)


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

    # Python 3.10+: each match_case arm is a decision point (+1 CC),
    # equivalent to elif in an if/elif chain.
    if sys.version_info >= (3, 10):
        visit_match_case = _enter_branch

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


def _ast_per_function_cc(
    tree: ast.Module, path: str, scan_id: int = 0,
) -> list[FunctionCC]:
    """Extract per-function cyclomatic complexity from AST.

    Walks top-level and method functions, computing CC for each.
    Also detects dispatch functions (flat if/elif or match/case).
    """
    results: list[FunctionCC] = []
    for node in ast.walk(tree):
        if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        visitor = _ComplexityVisitor()
        visitor.visit(node)
        line_end = getattr(node, "end_lineno", node.lineno) or node.lineno
        results.append(FunctionCC(
            path=path,
            scan_id=scan_id,
            function_name=node.name,
            line_start=node.lineno,
            line_end=line_end,
            complexity=float(visitor.complexity),
            is_dispatch=_is_dispatch_function(node),
        ))
    return results


def _is_dispatch_function(
    node: ast.FunctionDef | ast.AsyncFunctionDef,
) -> bool:
    """Detect dispatch functions exempt from CC threshold.

    D4: match/case + flat if/elif chains. A function is dispatch
    if its body is a single match statement or a single if/elif
    chain where no branch contains nested control flow.
    """
    body = node.body
    # Skip docstring
    if (body and isinstance(body[0], ast.Expr)
            and isinstance(body[0].value, ast.Constant)
            and isinstance(body[0].value.value, str)):
        body = body[1:]
    if len(body) != 1:
        return False

    stmt = body[0]

    # Match/case (Python 3.10+)
    if sys.version_info >= (3, 10) and isinstance(stmt, ast.Match):
        return True

    # Flat if/elif chain — no nested control flow in branches
    if isinstance(stmt, ast.If):
        return _is_flat_if_chain(stmt)

    return False


_control_flow: Tuple[type, ...] = (
    ast.If, ast.For, ast.While, ast.AsyncFor,
    ast.Try, ast.With, ast.AsyncWith,
)
if sys.version_info >= (3, 10):
    _control_flow = _control_flow + (ast.Match,)


def _is_flat_if_chain(node: ast.If) -> bool:
    """Check if an if/elif chain has no nested control flow."""
    # Check all branches (body + elif + else)
    branches: list[list[ast.stmt]] = [node.body]
    current = node
    while current.orelse:
        if (len(current.orelse) == 1
                and isinstance(current.orelse[0], ast.If)):
            current = current.orelse[0]
            branches.append(current.body)
        else:
            branches.append(current.orelse)
            break

    for branch in branches:
        for stmt in branch:
            if isinstance(stmt, _control_flow):
                return False
    return True


# ---------------------------------------------------------------------------
# Essential complexity (McCabe 1976, §III.C)
# ---------------------------------------------------------------------------


class _EssentialComplexityVisitor(ast.NodeVisitor):
    """Count non-reducible (unstructured) constructs in a function.

    ev(G) = count of constructs that break single-entry/single-exit:
      - break in for/while
      - continue inside nested conditional
      - multiple return statements at different nesting depths
      - bare raise in except handler

    For a fully structured function, ev = 1.
    """

    # pylint: disable=invalid-name,unused-argument  # ast.NodeVisitor requires PascalCase visit_* names

    def __init__(self) -> None:
        self._non_reducible = 0
        self._in_loop = False
        self._return_depths: list[int] = []
        self._depth = 0

    @property
    def essential_complexity(self) -> float:
        """Compute ev(G). Minimum is 1."""
        ev = 1 + self._non_reducible
        # Multiple returns at different depths = unstructured
        if len(set(self._return_depths)) > 1:
            ev += len(set(self._return_depths)) - 1
        return float(ev)

    def visit_FunctionDef(self, node: ast.FunctionDef) -> None:  # noqa: N802
        """Don't descend into nested functions."""

    visit_AsyncFunctionDef = visit_FunctionDef  # type: ignore[assignment]

    def visit_For(self, node: ast.For) -> None:  # noqa: N802
        """Track loop nesting depth for complexity accounting."""
        old = self._in_loop
        self._in_loop = True
        self._depth += 1
        self.generic_visit(node)
        self._depth -= 1
        self._in_loop = old

    visit_While = visit_For  # type: ignore[assignment]
    visit_AsyncFor = visit_For  # type: ignore[assignment]

    def visit_Break(self, node: ast.Break) -> None:  # noqa: N802
        """Count break as non-reducible when inside a loop."""
        if self._in_loop:
            self._non_reducible += 1

    def visit_Continue(self, node: ast.Continue) -> None:  # noqa: N802
        """Count continue as non-reducible when inside a nested loop."""
        if self._in_loop and self._depth > 1:
            self._non_reducible += 1

    def visit_Return(self, node: ast.Return) -> None:  # noqa: N802
        """Record current depth for multi-return unstructured-flow analysis."""
        self._return_depths.append(self._depth)

    def visit_If(self, node: ast.If) -> None:  # noqa: N802
        """Increment depth for conditional branch complexity."""
        self._depth += 1
        self.generic_visit(node)
        self._depth -= 1

    def visit_ExceptHandler(self, node: ast.ExceptHandler) -> None:  # noqa: N802
        """Count bare-raise in except handler as non-reducible."""
        # Check for bare raise in except
        for child in ast.walk(node):
            if isinstance(child, ast.Raise) and child.exc is None:
                self._non_reducible += 1
                break
        self.generic_visit(node)


def _ast_essential_complexity(
    node: ast.FunctionDef | ast.AsyncFunctionDef,
) -> float:
    """Compute essential complexity for a single function.

    Visit the function's body nodes directly — not the FunctionDef
    itself — because visit_FunctionDef intentionally stops recursion
    to prevent descending into nested functions.
    """
    visitor = _EssentialComplexityVisitor()
    for child in ast.iter_child_nodes(node):
        visitor.visit(child)
    return visitor.essential_complexity


def _ast_file_essential_complexity(tree: ast.Module) -> float:
    """Compute aggregate essential complexity for a file.

    Returns the maximum ev across all functions, or 1.0 if no
    functions exist (fully structured by default).
    """
    evs: list[float] = []
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            evs.append(_ast_essential_complexity(node))
    return max(evs) if evs else 1.0


def _single_pass_ast(tree: ast.Module) -> ASTAnalysis:
    """Collect all AST metrics in a single tree walk + per-function visitors.

    One ast.walk(tree) collects functions, imports, classes.
    Then per-function _ComplexityVisitor + _EssentialComplexityVisitor
    compute CC, nesting, and EV for each function.

    Eliminates ~4 redundant full-tree walks from the original 7-walk
    approach. The full-tree _ComplexityVisitor still runs once for
    total CC and max_nesting (which includes module-level branches).
    """
    func_nodes: list[ast.FunctionDef | ast.AsyncFunctionDef] = []
    imports: set[str] = set()
    class_nodes: list[ast.ClassDef] = []
    class_children: set[int] = set()

    # Single walk: collect functions, imports, classes
    for node in ast.walk(tree):
        if isinstance(node, ast.ClassDef):
            class_nodes.append(node)
            for child in ast.iter_child_nodes(node):
                if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)):
                    class_children.add(id(child))
        elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            func_nodes.append(node)
        elif isinstance(node, ast.Import):
            for alias in node.names:
                imports.add(alias.name.split(".")[0])
        elif isinstance(node, ast.ImportFrom):
            if node.module:
                imports.add(node.module.split(".")[0])

    # Full-tree CC + nesting (one visitor run — matches _ast_complexity/_ast_nesting_depth)
    full_visitor = _ComplexityVisitor()
    full_visitor.visit(tree)

    # Per-function CC + EV
    functions: list[FunctionDetail] = []
    for fn_node in func_nodes:
        cc_visitor = _ComplexityVisitor()
        cc_visitor.visit(fn_node)

        ev_visitor = _EssentialComplexityVisitor()
        for child in ast.iter_child_nodes(fn_node):
            ev_visitor.visit(child)

        line_end = getattr(fn_node, "end_lineno", fn_node.lineno) or fn_node.lineno
        functions.append(FunctionDetail(
            name=fn_node.name,
            line_start=fn_node.lineno,
            line_end=line_end,
            complexity=float(cc_visitor.complexity),
            essential_complexity=ev_visitor.essential_complexity,
            is_dispatch=_is_dispatch_function(fn_node),
            parent_is_class=id(fn_node) in class_children,
        ))

    return ASTAnalysis(
        total_complexity=float(full_visitor.complexity),
        max_nesting=full_visitor.max_nesting,
        functions=functions,
        imports=imports,
        class_nodes=class_nodes,
    )


def _ast_ck_metrics(tree: ast.Module, path: str,
                    scan_id: int = 0,
                    analysis: ASTAnalysis | None = None) -> CKMetrics | None:
    """Compute CK-suite metrics from AST.

    When analysis is provided (from _single_pass_ast), derives WMC, imports,
    and class nodes from it — eliminating redundant ast.walk passes.
    Falls back to standalone walks when analysis is None.

    Metrics (per PROPOSAL-wv-quality.md Academic Background):
      wmc: Weighted Methods per Class -- sum of CC per method across all classes
      cbo: Coupling Between Objects -- unique imports (module-level coupling)
      dit: Depth of Inheritance Tree -- max base class depth
      rfc: Response For Class -- method defs + Call nodes
      lcom: Lack of Cohesion in Methods -- 1 - (shared attrs / total attrs)
      noc: Number of Children -- needs cross-file scan, set to 0 here
    """
    if analysis is not None:
        classes = analysis.class_nodes
        imports = analysis.imports
    else:
        classes = [n for n in ast.walk(tree) if isinstance(n, ast.ClassDef)]
        imports = set()
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

    # WMC: derive from ASTAnalysis (correct: only class methods) or fallback
    if analysis is not None:
        wmc = analysis.wmc
    else:
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


# Result type: (FileEntry, CKMetrics | None, list[FunctionCC])
AnalysisResult = Tuple[FileEntry, Optional[CKMetrics], list[FunctionCC]]


def analyze_python_file(
    filepath: str | Path, scan_id: int = 0,
) -> AnalysisResult:
    """Analyze a Python source file.

    Returns (FileEntry, CKMetrics | None, list[FunctionCC]).
    Uses ast as primary path; falls back to regex on parse failure.
    """
    path = Path(filepath)
    try:
        source = path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        log.warning("Cannot read %s: %s", filepath, exc)
        return (
            FileEntry(path=str(filepath), scan_id=scan_id,
                      language="python"),
            None, [],
        )

    return analyze_python_source(source, str(filepath), scan_id)


def analyze_python_source(
    source: str, filepath: str, scan_id: int = 0,
) -> AnalysisResult:
    """Analyze Python source code (string).

    Primary path: ast.parse() for accurate metrics + CK suite.
    Fallback: regex heuristics if ast fails (no CK/ev in fallback).
    """
    lines = source.splitlines()
    non_empty = [
        ln for ln in lines
        if ln.strip() and not ln.strip().startswith("#")
    ]
    loc = len(non_empty)

    # Try ast path first (D1=Option B)
    try:
        tree = ast.parse(source, filename=filepath)
        analysis = _single_pass_ast(tree)

        # Convert FunctionDetail → FunctionCC for return contract
        fn_cc = [
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
            for f in analysis.functions
        ]

        ck = _ast_ck_metrics(tree, filepath, scan_id, analysis=analysis)
        indent_sd = _indent_sd(lines)

        entry = FileEntry(
            path=filepath,
            scan_id=scan_id,
            language="python",
            loc=loc,
            complexity=analysis.total_complexity,
            functions=analysis.function_count,
            max_nesting=analysis.max_nesting,
            avg_fn_len=analysis.avg_fn_len,
            essential_complexity=analysis.max_essential_complexity,
            indent_sd=indent_sd,
        )
        return entry, ck, fn_cc

    except (SyntaxError, ValueError, RecursionError):
        log.debug("ast.parse failed for %s, using regex fallback",
                  filepath)

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
        indent_sd=_indent_sd(lines),
    )
    return entry, None, []  # No CK/ev/fn_cc from regex path
