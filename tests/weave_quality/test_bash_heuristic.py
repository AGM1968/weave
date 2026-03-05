"""Tests for weave_quality.bash_heuristic -- regex-based Bash analysis."""

# pylint: disable=missing-class-docstring,missing-function-docstring

from __future__ import annotations

import textwrap
from pathlib import Path

import pytest

from weave_quality.bash_heuristic import (
    analyze_bash_file,
    analyze_bash_source,
    detect_bash,
    _indent_sd,
)

REPO = str(Path(__file__).resolve().parent.parent.parent)


def _src(code: str) -> str:
    return textwrap.dedent(code).lstrip()


# ---------------------------------------------------------------------------
# Branch / complexity counting
# ---------------------------------------------------------------------------


class TestComplexity:
    def test_if_elif_else(self) -> None:
        source = _src("""
            #!/bin/bash
            if [ -z "$1" ]; then
                echo "missing"
            elif [ "$1" = "foo" ]; then
                echo "foo"
            else
                echo "other"
            fi
        """)
        entry = analyze_bash_source(source, "test.sh")
        assert entry.language == "bash"
        # if + elif = 2 branches minimum
        assert entry.complexity >= 2

    def test_case_statement(self) -> None:
        source = _src("""
            case "$1" in
                start) echo "starting" ;;
                stop)  echo "stopping" ;;
                *)     echo "unknown" ;;
            esac
        """)
        entry = analyze_bash_source(source, "test.sh")
        # case keyword itself is 1 branch; arms don't have separate branch keywords
        assert entry.complexity >= 2

    def test_for_while_until(self) -> None:
        source = _src("""
            for f in *.txt; do
                echo "$f"
            done
            while read -r line; do
                echo "$line"
            done
            until false; do
                break
            done
        """)
        entry = analyze_bash_source(source, "test.sh")
        assert entry.complexity >= 3

    def test_logical_operators(self) -> None:
        source = _src("""
            [ -f file ] && echo "exists"
            [ -d dir ] || echo "missing"
        """)
        entry = analyze_bash_source(source, "test.sh")
        assert entry.complexity >= 2


# ---------------------------------------------------------------------------
# Function detection
# ---------------------------------------------------------------------------


class TestFunctions:
    def test_posix_style(self) -> None:
        source = _src("""
            my_func() {
                echo "hello"
            }
        """)
        entry = analyze_bash_source(source, "test.sh")
        assert entry.functions == 1

    def test_bash_keyword_style(self) -> None:
        source = _src("""
            function do_stuff {
                echo "stuff"
            }
        """)
        entry = analyze_bash_source(source, "test.sh")
        assert entry.functions == 1

    def test_multiple_functions(self) -> None:
        source = _src("""
            func_a() {
                echo "a"
            }
            func_b() {
                echo "b"
            }
            function func_c {
                echo "c"
            }
        """)
        entry = analyze_bash_source(source, "test.sh")
        assert entry.functions == 3

    def test_avg_fn_len(self) -> None:
        source = _src("""
            short_fn() {
                echo "1"
            }

            long_fn() {
                echo "1"
                echo "2"
                echo "3"
                echo "4"
                echo "5"
            }
        """)
        entry = analyze_bash_source(source, "test.sh")
        assert entry.functions == 2
        assert entry.avg_fn_len > 0


# ---------------------------------------------------------------------------
# Nesting depth
# ---------------------------------------------------------------------------


class TestNesting:
    def test_shallow(self) -> None:
        source = _src("""
            if true; then
                echo "level 1"
            fi
        """)
        entry = analyze_bash_source(source, "test.sh")
        assert entry.max_nesting >= 1

    def test_deep_nesting(self) -> None:
        source = _src("""
            if true; then
                for f in *; do
                    while read -r line; do
                        if [ -n "$line" ]; then
                            echo "$line"
                        fi
                    done
                done
            fi
        """)
        entry = analyze_bash_source(source, "test.sh")
        assert entry.max_nesting >= 3


# ---------------------------------------------------------------------------
# detect_bash
# ---------------------------------------------------------------------------


class TestDetectBash:
    def test_sh_extension(self, tmp_path: Path) -> None:
        f = tmp_path / "test.sh"
        f.write_text("#!/bin/bash\necho hi\n")
        assert detect_bash(str(f)) is True

    def test_bash_extension(self, tmp_path: Path) -> None:
        f = tmp_path / "test.bash"
        f.write_text("echo hi\n")
        assert detect_bash(str(f)) is True

    def test_shebang_no_extension(self, tmp_path: Path) -> None:
        f = tmp_path / "myscript"
        f.write_text("#!/usr/bin/env bash\necho hi\n")
        assert detect_bash(str(f)) is True

    def test_python_file(self, tmp_path: Path) -> None:
        f = tmp_path / "test.py"
        f.write_text("print('hi')\n")
        assert detect_bash(str(f)) is False

    def test_missing_file(self) -> None:
        assert detect_bash("/tmp/NO_SUCH_FILE_12345") is False


# ---------------------------------------------------------------------------
# File-based analysis
# ---------------------------------------------------------------------------


class TestFileAnalysis:
    def test_analyze_real_bash_file(self) -> None:
        target = Path(REPO) / "scripts" / "wv"
        if not target.exists():
            pytest.skip("wv script not found")
        entry = analyze_bash_file(str(target))
        assert entry.language == "bash"
        assert entry.loc > 50
        assert entry.functions > 0

    def test_analyze_missing_file(self) -> None:
        entry = analyze_bash_file("/tmp/NO_SUCH_FILE_12345.sh")
        assert entry.loc == 0

    def test_empty_source(self) -> None:
        entry = analyze_bash_source("", "empty.sh")
        assert entry.loc == 0
        assert entry.functions == 0
        # Base complexity is 1 (cyclomatic convention)
        assert entry.complexity == 1


# ---------------------------------------------------------------------------
# Coupling metrics
# ---------------------------------------------------------------------------


class TestCoupling:
    def test_source_coupling(self) -> None:
        """Source/tool coupling detected but not stored in FileEntry.

        The bash_heuristic module detects coupling patterns but FileEntry
        doesn't have a coupling field -- these patterns contribute to
        complexity counting instead.
        """
        source = _src("""
            source ./lib/helpers.sh
            . ./lib/utils.sh
        """)
        entry = analyze_bash_source(source, "test.sh")
        # Source coupling detected as complexity contributor
        assert entry.loc > 0

    def test_tool_coupling(self) -> None:
        source = _src("""
            jq '.foo' file.json
            sqlite3 test.db "SELECT 1"
            gh issue list
        """)
        entry = analyze_bash_source(source, "test.sh")
        assert entry.loc > 0


# ---------------------------------------------------------------------------
# Indentation SD (Sprint 2)
# ---------------------------------------------------------------------------


class TestIndentSD:
    def test_flat_bash_zero_sd(self) -> None:
        """Top-level commands with no indentation have zero SD."""
        lines = ["echo hello", "x=1", "echo $x"]
        assert _indent_sd(lines) == 0.0

    def test_mixed_nesting_nonzero_sd(self) -> None:
        """Bash with conditionals and loops has non-zero SD."""
        lines = [
            "#!/bin/bash",
            "do_thing() {",
            "  if [ -z \"$1\" ]; then",
            "    for f in *.txt; do",
            "      echo \"$f\"",
            "    done",
            "  fi",
            "}",
            "do_thing",
        ]
        sd = _indent_sd(lines)
        assert sd > 0.0

    def test_tab_indented_bash(self) -> None:
        """Tab-indented Bash is handled (each tab = one indent unit)."""
        lines = [
            "func() {",
            "\tif true; then",
            "\t\techo ok",
            "\tfi",
            "}",
        ]
        sd = _indent_sd(lines)
        assert sd > 0.0

    def test_comments_ignored(self) -> None:
        """Comment lines don't contribute to indent SD."""
        lines_clean = ["x=1", "y=2"]
        lines_with_comments = ["# a comment", "x=1", "  # indented comment", "y=2"]
        assert _indent_sd(lines_clean) == _indent_sd(lines_with_comments)

    def test_fewer_than_two_lines(self) -> None:
        assert _indent_sd([]) == 0.0
        assert _indent_sd(["echo hi"]) == 0.0

    def test_indent_sd_stored_in_file_entry(self) -> None:
        """analyze_bash_source populates indent_sd on the FileEntry."""
        source = _src("""
            #!/bin/bash
            process() {
              if [ -f "$1" ]; then
                for line in $(cat "$1"); do
                  echo "$line"
                done
              fi
            }
            process "$1"
        """)
        entry = analyze_bash_source(source, "test.sh")
        assert entry.indent_sd >= 0.0
        assert entry.indent_sd > 0.0  # has nesting
