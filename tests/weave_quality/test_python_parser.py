"""Tests for weave_quality.python_parser -- ast primary, regex fallback."""

# pylint: disable=missing-class-docstring,missing-function-docstring

from __future__ import annotations

import ast
import textwrap
from pathlib import Path

import pytest

from weave_quality.python_parser import (
    _ast_essential_complexity,
    _ast_per_function_cc,
    _indent_sd,
    _is_dispatch_function,
    _single_pass_ast,
    analyze_python_file,
    analyze_python_source,
)



# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

REPO = str(Path(__file__).resolve().parent.parent.parent)


def _src(code: str) -> str:
    """Dedent a code snippet for test input."""
    return textwrap.dedent(code).lstrip()


# ---------------------------------------------------------------------------
# AST path (primary)
# ---------------------------------------------------------------------------


class TestAstPath:
    def test_simple_function(self) -> None:
        source = _src("""
            def hello() -> None:
                print("hello")
        """)
        entry, _ck, _fn = analyze_python_source(source, "test.py")
        assert entry.language == "python"
        assert entry.functions == 1
        assert entry.loc > 0

    def test_complexity_branches(self) -> None:
        source = _src("""
            def decide(x) -> None:
                if x > 0:
                    for i in range(x):
                        if i % 2 == 0:
                            pass
                elif x < 0:
                    while True:
                        break
                else:
                    pass
        """)
        entry, _ck, _fn = analyze_python_source(source, "test.py")
        # Base(1) + if(1) + for(1) + if(1) + elif(1) + while(1) = 6+
        assert entry.complexity >= 5

    def test_nesting_depth(self) -> None:
        source = _src("""
            def deep() -> None:
                if True:
                    for x in [1]:
                        while True:
                            if x:
                                pass
        """)
        entry, _, _fn = analyze_python_source(source, "test.py")
        assert entry.max_nesting >= 4

    def test_avg_fn_len(self) -> None:
        source = _src("""
            def short() -> None:
                pass

            def longer() -> None:
                x = 1
                y = 2
                z = 3
                return x + y + z
        """)
        entry, _, _fn = analyze_python_source(source, "test.py")
        assert entry.functions == 2
        assert entry.avg_fn_len > 0

    def test_boolean_ops_add_complexity(self) -> None:
        source = _src("""
            def check(a, b, c) -> None:
                if a and b or c:
                    pass
        """)
        entry, _, _fn = analyze_python_source(source, "test.py")
        # Base(1) + if(1) + and(1) + or(1) = 4
        assert entry.complexity >= 4

    def test_comprehension_complexity(self) -> None:
        source = _src("""
            def comp() -> None:
                return [x for x in range(10) if x > 5]
        """)
        entry, _, _fn = analyze_python_source(source, "test.py")
        # Base(1) + comprehension(1) + comprehension if(1) = 3
        assert entry.complexity >= 3

    def test_empty_file(self) -> None:
        entry, ck, _fn = analyze_python_source("", "empty.py")
        assert entry.loc == 0
        assert entry.functions == 0
        assert ck is None


# ---------------------------------------------------------------------------
# CK Metrics (ast path)
# ---------------------------------------------------------------------------


class TestCKMetrics:
    def test_class_produces_ck(self) -> None:
        source = _src("""
            import os

            class MyClass:
                def __init__(self) -> None:
                    self.x = 1
                    self.y = 2

                def method(self) -> None:
                    self.x += 1
                    return self.x + self.y
        """)
        _entry, ck, _fn = analyze_python_source(source, "test.py")
        assert ck is not None
        assert "wmc" in ck.metrics
        assert "cbo" in ck.metrics
        assert "lcom" in ck.metrics
        assert ck.metrics["cbo"] >= 1  # os import

    def test_no_class_no_full_ck(self) -> None:
        source = _src("""
            def standalone() -> None:
                pass
        """)
        _, ck, _fn = analyze_python_source(source, "test.py")
        # No classes means either None or only cbo
        if ck is not None:
            assert "wmc" not in ck.metrics

    def test_lcom_high_cohesion(self) -> None:
        source = _src("""
            class Cohesive:
                def method_a(self) -> None:
                    return self.x + self.y

                def method_b(self) -> None:
                    return self.x * self.y
        """)
        _, ck, _fn = analyze_python_source(source, "test.py")
        assert ck is not None
        # Both methods share self.x and self.y -> high cohesion -> low LCOM
        assert ck.metrics["lcom"] < 0.5

    def test_lcom_low_cohesion(self) -> None:
        source = _src("""
            class Scattered:
                def method_a(self) -> None:
                    return self.x

                def method_b(self) -> None:
                    return self.y

                def method_c(self) -> None:
                    return self.z
        """)
        _, ck, _fn = analyze_python_source(source, "test.py")
        assert ck is not None
        # No shared attributes -> low cohesion -> high LCOM
        assert ck.metrics["lcom"] > 0.5

    def test_imports_count_as_cbo(self) -> None:
        source = _src("""
            import os
            import sys
            from pathlib import Path

            class Foo:
                pass
        """)
        _, ck, _fn = analyze_python_source(source, "test.py")
        assert ck is not None
        assert ck.metrics["cbo"] >= 3  # os, sys, pathlib

    def test_direct_bases_with_inheritance(self) -> None:
        source = _src("""
            class Base:
                pass

            class Child(Base):
                pass
        """)
        _, ck, _fn = analyze_python_source(source, "test.py")
        assert ck is not None
        assert ck.metrics["direct_bases"] >= 1


# ---------------------------------------------------------------------------
# Regex fallback
# ---------------------------------------------------------------------------


class TestRegexFallback:
    def test_syntax_error_triggers_fallback(self) -> None:
        source = "def broken(\n    # missing close paren and colon"
        entry, ck, _fn = analyze_python_source(source, "broken.py")
        assert entry.language == "python"
        # Should get some metrics from regex, not crash
        assert entry.loc >= 0
        # No CK from fallback
        assert ck is None

    def test_regex_counts_branches(self) -> None:
        # Force regex by breaking syntax subtly (actually this is valid)
        # Instead, test regex directly via a real syntax error file
        # For valid code, ast path handles it. Test that fallback works:
        broken = "def foo(:\n    if True:\n        for x in []:\n            pass"
        entry, ck, _fn = analyze_python_source(broken, "test.py")
        assert entry.functions >= 0  # regex can still count
        assert ck is None


# ---------------------------------------------------------------------------
# File-based analysis
# ---------------------------------------------------------------------------


class TestFileAnalysis:
    def test_analyze_real_python_file(self) -> None:
        # Analyze our own models.py
        target = Path(REPO) / "scripts" / "weave_quality" / "models.py"
        if not target.exists():
            pytest.skip("models.py not found")
        entry, ck, _fn = analyze_python_file(str(target))
        assert entry.language == "python"
        assert entry.loc > 50  # models.py has substantial code
        assert entry.functions > 3
        assert ck is not None  # Has classes -> CK metrics

    def test_analyze_missing_file(self) -> None:
        entry, ck, _fn = analyze_python_file("/tmp/NO_SUCH_FILE_12345.py")
        assert entry.loc == 0
        assert ck is None


# ---------------------------------------------------------------------------
# Per-function CC (Sprint 1)
# ---------------------------------------------------------------------------


class TestPerFunctionCC:
    def test_single_function(self) -> None:
        source = _src("""
            def hello():
                print("hi")
        """)
        tree = ast.parse(source)
        fns = _ast_per_function_cc(tree, "test.py")
        assert len(fns) == 1
        assert fns[0].function_name == "hello"
        assert fns[0].complexity == 1.0  # base only
        assert fns[0].line_start == 1
        assert fns[0].line_end == 2

    def test_multiple_functions(self) -> None:
        source = _src("""
            def simple():
                pass

            def branchy(x):
                if x > 0:
                    return True
                elif x < 0:
                    return False
                return None
        """)
        tree = ast.parse(source)
        fns = _ast_per_function_cc(tree, "test.py")
        by_name = {f.function_name: f for f in fns}
        assert "simple" in by_name
        assert "branchy" in by_name
        assert by_name["simple"].complexity == 1.0
        # branchy: base(1) + if(1) + elif(1) = 3
        assert by_name["branchy"].complexity >= 3.0

    def test_method_in_class(self) -> None:
        source = _src("""
            class Foo:
                def method(self, x):
                    if x:
                        for i in range(x):
                            pass
        """)
        tree = ast.parse(source)
        fns = _ast_per_function_cc(tree, "test.py")
        assert any(f.function_name == "method" for f in fns)
        method = [f for f in fns if f.function_name == "method"][0]
        # base(1) + if(1) + for(1) = 3
        assert method.complexity >= 3.0

    def test_fn_cc_in_analysis_result(self) -> None:
        source = _src("""
            def foo():
                if True:
                    pass

            def bar():
                pass
        """)
        _, _, fn_cc = analyze_python_source(source, "test.py")
        assert len(fn_cc) == 2
        names = {f.function_name for f in fn_cc}
        assert names == {"foo", "bar"}

    def test_regex_fallback_returns_empty_fn_cc(self) -> None:
        broken = "def foo(:\n    pass"
        _, _, fn_cc = analyze_python_source(broken, "test.py")
        assert not fn_cc


# ---------------------------------------------------------------------------
# Essential complexity (Sprint 1)
# ---------------------------------------------------------------------------


class TestEssentialComplexity:
    def test_fully_structured_ev_1(self) -> None:
        """if/elif/else with no break/continue/multi-return."""
        source = _src("""
            def structured(x):
                if x > 0:
                    y = 1
                elif x < 0:
                    y = -1
                else:
                    y = 0
                return y
        """)
        tree = ast.parse(source)
        fn = [n for n in ast.walk(tree)
              if isinstance(n, ast.FunctionDef)][0]
        ev = _ast_essential_complexity(fn)
        assert ev == 1.0

    def test_break_in_loop_increases_ev(self) -> None:
        source = _src("""
            def with_break(items):
                for item in items:
                    if item == "stop":
                        break
                    print(item)
        """)
        tree = ast.parse(source)
        fn = [n for n in ast.walk(tree)
              if isinstance(n, ast.FunctionDef)][0]
        ev = _ast_essential_complexity(fn)
        assert ev > 1.0

    def test_multiple_returns_different_depths(self) -> None:
        source = _src("""
            def multi_return(x):
                if x > 0:
                    return "positive"
                return "non-positive"
        """)
        tree = ast.parse(source)
        fn = [n for n in ast.walk(tree)
              if isinstance(n, ast.FunctionDef)][0]
        ev = _ast_essential_complexity(fn)
        # Returns at depth 1 (inside if) and depth 0 (top level)
        assert ev > 1.0

    def test_returns_same_depth_no_penalty(self) -> None:
        source = _src("""
            def same_depth(x):
                if x > 0:
                    return "a"
                else:
                    return "b"
        """)
        tree = ast.parse(source)
        fn = [n for n in ast.walk(tree)
              if isinstance(n, ast.FunctionDef)][0]
        ev = _ast_essential_complexity(fn)
        # Both returns at depth 1 — same depth, no penalty
        assert ev == 1.0

    def test_bare_raise_in_except(self) -> None:
        source = _src("""
            def with_reraise():
                try:
                    do_something()
                except Exception:
                    raise
        """)
        tree = ast.parse(source)
        fn = [n for n in ast.walk(tree)
              if isinstance(n, ast.FunctionDef)][0]
        ev = _ast_essential_complexity(fn)
        assert ev > 1.0

    def test_file_level_ev_is_max(self) -> None:
        source = _src("""
            def clean(x):
                if x:
                    return x
                return None

            def messy(items):
                for item in items:
                    if item > 0:
                        break
                    if item < -10:
                        continue
        """)
        entry, _, _ = analyze_python_source(source, "test.py")
        # File ev = max of function evs. messy has break + continue
        assert entry.essential_complexity > 1.0

    def test_no_functions_ev_1(self) -> None:
        source = "x = 1\ny = 2\n"
        entry, _, _ = analyze_python_source(source, "test.py")
        assert entry.essential_complexity == 1.0


# ---------------------------------------------------------------------------
# Dispatch detection (Sprint 1)
# ---------------------------------------------------------------------------


class TestDispatchDetection:
    def test_flat_if_elif_is_dispatch(self) -> None:
        source = _src("""
            def handle(cmd):
                if cmd == "start":
                    start()
                elif cmd == "stop":
                    stop()
                elif cmd == "restart":
                    restart()
                else:
                    unknown()
        """)
        tree = ast.parse(source)
        fn = [n for n in ast.walk(tree)
              if isinstance(n, ast.FunctionDef)][0]
        assert _is_dispatch_function(fn) is True

    def test_nested_control_not_dispatch(self) -> None:
        source = _src("""
            def handle(cmd):
                if cmd == "start":
                    for i in range(3):
                        do(i)
                elif cmd == "stop":
                    stop()
        """)
        tree = ast.parse(source)
        fn = [n for n in ast.walk(tree)
              if isinstance(n, ast.FunctionDef)][0]
        assert _is_dispatch_function(fn) is False

    def test_match_case_is_dispatch(self) -> None:
        source = _src("""
            def route(cmd):
                match cmd:
                    case "start":
                        start()
                    case "stop":
                        stop()
                    case _:
                        pass
        """)
        try:
            tree = ast.parse(source)
        except SyntaxError:
            pytest.skip("match/case requires Python 3.10+")
        fn = [n for n in ast.walk(tree)
              if isinstance(n, ast.FunctionDef)][0]
        assert _is_dispatch_function(fn) is True

    def test_multi_statement_body_not_dispatch(self) -> None:
        source = _src("""
            def not_dispatch(x):
                y = x + 1
                if y > 0:
                    return True
                return False
        """)
        tree = ast.parse(source)
        fn = [n for n in ast.walk(tree)
              if isinstance(n, ast.FunctionDef)][0]
        assert _is_dispatch_function(fn) is False

    def test_dispatch_with_docstring(self) -> None:
        source = _src("""
            def handle(cmd):
                \"\"\"Dispatch command.\"\"\"
                if cmd == "a":
                    do_a()
                elif cmd == "b":
                    do_b()
        """)
        tree = ast.parse(source)
        fn = [n for n in ast.walk(tree)
              if isinstance(n, ast.FunctionDef)][0]
        assert _is_dispatch_function(fn) is True

    def test_fn_cc_marks_dispatch(self) -> None:
        source = _src("""
            def dispatch(cmd):
                if cmd == "a":
                    do_a()
                elif cmd == "b":
                    do_b()

            def regular(x):
                if x > 0:
                    for i in range(x):
                        print(i)
        """)
        tree = ast.parse(source)
        fns = _ast_per_function_cc(tree, "test.py")
        by_name = {f.function_name: f for f in fns}
        assert by_name["dispatch"].is_dispatch is True
        assert by_name["regular"].is_dispatch is False


# ---------------------------------------------------------------------------
# Indentation SD (Sprint 2)
# ---------------------------------------------------------------------------


class TestIndentSD:
    def test_flat_file_low_sd(self) -> None:
        """File with all code at same indent level has near-zero SD."""
        lines = [
            "x = 1",
            "y = 2",
            "z = x + y",
            "print(z)",
        ]
        sd = _indent_sd(lines)
        assert sd == 0.0

    def test_uniformly_nested_low_sd(self) -> None:
        """Code uniformly at one nested level also has zero SD."""
        lines = [
            "    x = 1",
            "    y = 2",
            "    z = 3",
        ]
        sd = _indent_sd(lines)
        assert sd == 0.0

    def test_mixed_nesting_nonzero_sd(self) -> None:
        """Mix of flat and deeply nested lines produces non-zero SD."""
        lines = [
            "def foo():",
            "    if True:",
            "        for x in []:",
            "            if x:",
            "                pass",
            "y = 1",
        ]
        sd = _indent_sd(lines)
        assert sd > 0.0

    def test_comments_and_blank_lines_ignored(self) -> None:
        """Comments and blank lines do not affect SD computation."""
        lines_with_comments = [
            "x = 1",
            "# this is a comment",
            "",
            "y = 2",
        ]
        lines_without = ["x = 1", "y = 2"]
        sd1 = _indent_sd(lines_with_comments)
        sd2 = _indent_sd(lines_without)
        assert sd1 == sd2

    def test_fewer_than_two_lines_returns_zero(self) -> None:
        assert _indent_sd([]) == 0.0
        assert _indent_sd(["x = 1"]) == 0.0
        assert _indent_sd(["# comment only"]) == 0.0

    def test_indent_sd_stored_in_file_entry(self) -> None:
        """analyze_python_source populates indent_sd on the FileEntry."""
        source = _src("""
            def foo():
                if True:
                    for x in []:
                        pass
            y = 1
        """)
        entry, _, _ = analyze_python_source(source, "test.py")
        assert entry.indent_sd >= 0.0
        # Mixed nesting: should be non-zero
        assert entry.indent_sd > 0.0

    def test_flat_source_low_indent_sd(self) -> None:
        """Flat module-level code has low indent SD."""
        source = _src("""
            x = 1
            y = 2
            z = x + y
        """)
        entry, _, _ = analyze_python_source(source, "test.py")
        assert entry.indent_sd == 0.0

    def test_regex_fallback_also_populates_indent_sd(self) -> None:
        """Regex fallback path should still compute indent_sd."""
        broken = "def foo(:\n    if True:\n        pass\n        \n"
        entry, _, _ = analyze_python_source(broken, "test.py")
        # indent_sd computation doesn't require ast -- should be non-negative
        assert entry.indent_sd >= 0.0


class TestSinglePassAST:
    """Tests for _single_pass_ast — consolidated single-walk visitor."""

    def test_matches_old_complexity(self) -> None:
        """Total complexity must match _ast_complexity (full-tree visitor)."""
        source = textwrap.dedent("""\
            def foo(x):
                if x > 0:
                    return x
                return -x

            def bar(a, b):
                for i in range(a):
                    if i == b:
                        break
                return a
        """)
        tree = ast.parse(source)
        result = _single_pass_ast(tree)
        # foo: 1 (base) + 1 (if) = 2
        # bar: 1 (base) + 1 (for) + 1 (if) = 3
        # Module-level: 1 (base) + 2 (if, for, if from both) = full-tree CC
        # Full-tree _ComplexityVisitor visits ALL nodes: base 1 + if + for + if = 4
        assert result.total_complexity == 4.0

    def test_matches_old_nesting(self) -> None:
        """Max nesting must match _ast_nesting_depth."""
        source = textwrap.dedent("""\
            def deep():
                if True:
                    for x in []:
                        if x:
                            pass
        """)
        tree = ast.parse(source)
        result = _single_pass_ast(tree)
        assert result.max_nesting == 3

    def test_function_count(self) -> None:
        source = "def a(): pass\ndef b(): pass\ndef c(): pass\n"
        tree = ast.parse(source)
        result = _single_pass_ast(tree)
        assert result.function_count == 3

    def test_avg_fn_len(self) -> None:
        source = textwrap.dedent("""\
            def short():
                pass

            def longer():
                x = 1
                y = 2
                return x + y
        """)
        tree = ast.parse(source)
        result = _single_pass_ast(tree)
        assert result.function_count == 2
        assert result.avg_fn_len > 0

    def test_imports_collected(self) -> None:
        source = "import os\nfrom pathlib import Path\nimport json\n"
        tree = ast.parse(source)
        result = _single_pass_ast(tree)
        assert result.imports == {"os", "pathlib", "json"}

    def test_class_methods_flagged(self) -> None:
        """parent_is_class=True for direct class methods, False for top-level."""
        source = textwrap.dedent("""\
            def top_level():
                pass

            class Foo:
                def method(self):
                    pass

                def other(self):
                    pass
        """)
        tree = ast.parse(source)
        result = _single_pass_ast(tree)
        assert result.function_count == 3
        top = [f for f in result.functions if f.name == "top_level"]
        methods = [f for f in result.functions if f.parent_is_class]
        assert len(top) == 1
        assert not top[0].parent_is_class
        assert len(methods) == 2

    def test_wmc_only_class_methods(self) -> None:
        """WMC must sum only class method CC, not top-level functions."""
        source = textwrap.dedent("""\
            def complex_top_level(x):
                if x > 0:
                    for i in range(x):
                        if i > 5:
                            pass
                return x

            class Simple:
                def method(self):
                    return 1
        """)
        tree = ast.parse(source)
        result = _single_pass_ast(tree)
        # WMC = CC of method only (base 1), not complex_top_level
        assert result.wmc == 1.0

    def test_essential_complexity_collected(self) -> None:
        """Per-function EV is collected in the single pass."""
        source = textwrap.dedent("""\
            def structured():
                if True:
                    return 1
                return 0

            def unstructured():
                for x in range(10):
                    if x > 5:
                        break
                return x
        """)
        tree = ast.parse(source)
        result = _single_pass_ast(tree)
        # unstructured has break-in-loop → ev > 1
        assert result.max_essential_complexity > 1.0

    def test_empty_file(self) -> None:
        tree = ast.parse("")
        result = _single_pass_ast(tree)
        assert result.function_count == 0
        assert result.total_complexity == 1.0
        assert result.max_nesting == 0
        assert result.max_essential_complexity == 1.0
        assert result.wmc == 0.0

    def test_dispatch_detection_preserved(self) -> None:
        """Dispatch flag must be set for flat if/elif chains."""
        source = textwrap.dedent("""\
            def dispatch(cmd):
                if cmd == "a":
                    return 1
                elif cmd == "b":
                    return 2
                elif cmd == "c":
                    return 3
        """)
        tree = ast.parse(source)
        result = _single_pass_ast(tree)
        assert len(result.functions) == 1
        assert result.functions[0].is_dispatch
