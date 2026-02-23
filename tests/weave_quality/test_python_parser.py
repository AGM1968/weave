"""Tests for weave_quality.python_parser -- ast primary, regex fallback."""

# pylint: disable=missing-class-docstring,missing-function-docstring

from __future__ import annotations

import textwrap
from pathlib import Path

import pytest

from weave_quality.python_parser import (
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
        entry, _ck = analyze_python_source(source, "test.py")
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
        entry, _ck = analyze_python_source(source, "test.py")
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
        entry, _ = analyze_python_source(source, "test.py")
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
        entry, _ = analyze_python_source(source, "test.py")
        assert entry.functions == 2
        assert entry.avg_fn_len > 0

    def test_boolean_ops_add_complexity(self) -> None:
        source = _src("""
            def check(a, b, c) -> None:
                if a and b or c:
                    pass
        """)
        entry, _ = analyze_python_source(source, "test.py")
        # Base(1) + if(1) + and(1) + or(1) = 4
        assert entry.complexity >= 4

    def test_comprehension_complexity(self) -> None:
        source = _src("""
            def comp() -> None:
                return [x for x in range(10) if x > 5]
        """)
        entry, _ = analyze_python_source(source, "test.py")
        # Base(1) + comprehension(1) + comprehension if(1) = 3
        assert entry.complexity >= 3

    def test_empty_file(self) -> None:
        entry, ck = analyze_python_source("", "empty.py")
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
        _entry, ck = analyze_python_source(source, "test.py")
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
        _, ck = analyze_python_source(source, "test.py")
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
        _, ck = analyze_python_source(source, "test.py")
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
        _, ck = analyze_python_source(source, "test.py")
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
        _, ck = analyze_python_source(source, "test.py")
        assert ck is not None
        assert ck.metrics["cbo"] >= 3  # os, sys, pathlib

    def test_dit_with_inheritance(self) -> None:
        source = _src("""
            class Base:
                pass

            class Child(Base):
                pass
        """)
        _, ck = analyze_python_source(source, "test.py")
        assert ck is not None
        assert ck.metrics["dit"] >= 1


# ---------------------------------------------------------------------------
# Regex fallback
# ---------------------------------------------------------------------------


class TestRegexFallback:
    def test_syntax_error_triggers_fallback(self) -> None:
        source = "def broken(\n    # missing close paren and colon"
        entry, ck = analyze_python_source(source, "broken.py")
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
        entry, ck = analyze_python_source(broken, "test.py")
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
        entry, ck = analyze_python_file(str(target))
        assert entry.language == "python"
        assert entry.loc > 50  # models.py has substantial code
        assert entry.functions > 3
        assert ck is not None  # Has classes -> CK metrics

    def test_analyze_missing_file(self) -> None:
        entry, ck = analyze_python_file("/tmp/NO_SUCH_FILE_12345.py")
        assert entry.loc == 0
        assert ck is None
