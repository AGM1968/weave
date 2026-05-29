"""Tests for weave_quality.bash_ast_grep -- AST-grep CC backend.

Tests that require ast-grep are skipped when the binary is absent.
"""

# pylint: disable=missing-class-docstring,missing-function-docstring,too-few-public-methods

from __future__ import annotations

import textwrap
from pathlib import Path

import pytest

from weave_quality.bash_ast_grep import (
    analyze_bash_file_best,
    analyze_bash_source_ast_grep,
    ast_grep_available,
)
from weave_quality.external_tools import resolve_tool

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

AST_GREP = pytest.mark.skipif(
    not ast_grep_available(),
    reason="ast-grep not installed",
)


def _write_sh(tmp_path: Path, code: str, name: str = "test.sh") -> str:
    p = tmp_path / name
    p.write_text(textwrap.dedent(code).lstrip(), encoding="utf-8")
    return str(p)


def _src(code: str) -> str:
    return textwrap.dedent(code).lstrip()


# ---------------------------------------------------------------------------
# ast_grep_available
# ---------------------------------------------------------------------------


class TestAstGrepAvailable:
    def test_returns_bool(self) -> None:
        result = ast_grep_available()
        assert isinstance(result, bool)

    def test_resolve_tool_checks_common_user_bins(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        import weave_quality.external_tools as tools  # pylint: disable=import-outside-toplevel

        fake_home = tmp_path / "home"
        fake_bin = fake_home / ".cargo" / "bin"
        fake_bin.mkdir(parents=True)
        fake_tool = fake_bin / "ast-grep"
        fake_tool.write_text("#!/bin/sh\n", encoding="utf-8")
        fake_tool.chmod(0o755)

        monkeypatch.setattr(tools.shutil, "which", lambda _: None)
        monkeypatch.setattr(tools.Path, "home", lambda: fake_home)
        assert resolve_tool("ast-grep") == str(fake_tool)


# ---------------------------------------------------------------------------
# analyze_bash_file_best — backend selection
# ---------------------------------------------------------------------------


class TestAnalyzeBashFileBest:
    def test_returns_three_tuple(self, tmp_path: Path) -> None:
        fp = _write_sh(tmp_path, "echo hello\n")
        entry, fns, backend = analyze_bash_file_best(fp)
        assert entry is not None
        assert isinstance(fns, list)
        assert backend in ("ast-grep", "regex")

    def test_missing_file_does_not_raise(self, tmp_path: Path) -> None:
        fp = str(tmp_path / "nonexistent.sh")
        entry, _, backend = analyze_bash_file_best(fp)
        assert entry is not None
        assert backend in ("ast-grep", "regex")

    @AST_GREP
    def test_backend_is_ast_grep_when_available(self, tmp_path: Path) -> None:
        fp = _write_sh(tmp_path, "echo hello\n")
        _, _, backend = analyze_bash_file_best(fp)
        assert backend == "ast-grep"

    @AST_GREP
    def test_ast_grep_backend_with_branches(self, tmp_path: Path) -> None:
        """A file with real branches processes via ast-grep, not regex fallback."""
        src = _src("""
            check() {
              if [ "$1" = "yes" ]; then
                echo "ok"
              fi
            }
        """)
        fp = _write_sh(tmp_path, src)
        _, fn_cc, backend = analyze_bash_file_best(fp)
        assert backend == "ast-grep"
        assert len(fn_cc) == 1
        assert fn_cc[0].complexity == 2.0

    def test_regex_fallback_when_ast_grep_unavailable(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        import weave_quality.bash_ast_grep as mod  # pylint: disable=import-outside-toplevel
        monkeypatch.setattr(mod, "ast_grep_bin", lambda: None)
        fp = _write_sh(tmp_path, "x=1\n")
        _, _, backend = analyze_bash_file_best(fp)
        assert backend == "regex"


# ---------------------------------------------------------------------------
# analyze_bash_source_ast_grep — returns None when ast-grep unavailable
# ---------------------------------------------------------------------------


class TestAstGrepUnavailable:
    def test_returns_none_when_no_binary(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        import weave_quality.bash_ast_grep as mod  # pylint: disable=import-outside-toplevel
        monkeypatch.setattr(mod, "ast_grep_bin", lambda: None)
        fp = _write_sh(tmp_path, "echo hello\n")
        source = Path(fp).read_text(encoding="utf-8")
        assert analyze_bash_source_ast_grep(source, fp) is None

    def test_returns_none_when_rule_missing(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        import weave_quality.bash_ast_grep as mod  # pylint: disable=import-outside-toplevel
        monkeypatch.setattr(mod, "_RULE_FILE", tmp_path / "nonexistent.yaml")
        fp = _write_sh(tmp_path, "echo hello\n")
        source = Path(fp).read_text(encoding="utf-8")
        result = analyze_bash_source_ast_grep(source, fp)
        assert result is None


# ---------------------------------------------------------------------------
# analyze_bash_source_ast_grep — output shape
# ---------------------------------------------------------------------------


@AST_GREP
class TestOutputShape:
    def test_returns_tuple(self, tmp_path: Path) -> None:
        fp = _write_sh(tmp_path, "echo hello\n")
        result = analyze_bash_source_ast_grep(Path(fp).read_text(encoding="utf-8"), fp)
        assert result is not None
        entry, fn_cc = result
        assert entry.language == "bash"
        assert isinstance(fn_cc, list)

    def test_loc_nonzero(self, tmp_path: Path) -> None:
        fp = _write_sh(tmp_path, "x=1\ny=2\n")
        result = analyze_bash_source_ast_grep(Path(fp).read_text(encoding="utf-8"), fp)
        assert result is not None
        entry, _ = result
        assert entry.loc > 0

    def test_scan_id_propagated(self, tmp_path: Path) -> None:
        fp = _write_sh(tmp_path, "echo hi\n")
        result = analyze_bash_source_ast_grep(Path(fp).read_text(encoding="utf-8"), fp, scan_id=99)
        assert result is not None
        entry, _ = result
        assert entry.scan_id == 99

    def test_empty_file(self, tmp_path: Path) -> None:
        fp = _write_sh(tmp_path, "\n")
        result = analyze_bash_source_ast_grep(Path(fp).read_text(encoding="utf-8"), fp)
        assert result is not None
        entry, fns = result
        assert entry.functions == 0
        assert fns == []
        assert entry.complexity == 1.0


# ---------------------------------------------------------------------------
# CC counting accuracy vs regex heuristic
# ---------------------------------------------------------------------------


@AST_GREP
class TestCCAccuracy:
    def test_if_statement(self, tmp_path: Path) -> None:
        src = _src("""
            check() {
              if [ "$1" -gt 0 ]; then
                echo pos
              fi
            }
        """)
        fp = _write_sh(tmp_path, src)
        result = analyze_bash_source_ast_grep(src, fp)
        assert result is not None
        _, fn_cc = result
        assert len(fn_cc) == 1
        assert fn_cc[0].complexity == 2.0  # base(1) + if(1)

    def test_for_loop(self, tmp_path: Path) -> None:
        src = _src("""
            process() {
              for item in a b c; do
                echo "$item"
              done
            }
        """)
        fp = _write_sh(tmp_path, src)
        result = analyze_bash_source_ast_grep(src, fp)
        assert result is not None
        _, fn_cc = result
        assert fn_cc[0].complexity >= 2.0

    def test_while_loop(self, tmp_path: Path) -> None:
        src = _src("""
            countdown() {
              n=3
              while [ "$n" -gt 0 ]; do
                n=$((n - 1))
              done
            }
        """)
        fp = _write_sh(tmp_path, src)
        result = analyze_bash_source_ast_grep(src, fp)
        assert result is not None
        _, fn_cc = result
        assert fn_cc[0].complexity >= 2.0

    def test_logical_and(self, tmp_path: Path) -> None:
        src = _src("""
            check_and() {
              [ -f "$1" ] && echo "exists"
            }
        """)
        fp = _write_sh(tmp_path, src)
        result = analyze_bash_source_ast_grep(src, fp)
        assert result is not None
        _, fn_cc = result
        assert fn_cc[0].complexity >= 2.0

    def test_case_counts_all_arms_including_default(self, tmp_path: Path) -> None:
        """All case_item arms count +1 each, including the default *) arm.

        3 arms (one/two/*) → complexity == 1 + 3 = 4.
        """
        src = _src("""
            describe() {
              case "$1" in
                one) echo "one" ;;
                two) echo "two" ;;
                *) echo "other" ;;
              esac
            }
        """)
        fp = _write_sh(tmp_path, src)
        result = analyze_bash_source_ast_grep(src, fp)
        assert result is not None
        _, fn_cc = result
        assert fn_cc[0].complexity == 4.0  # base(1) + one(1) + two(1) + *(1)

    def test_elif_clause(self, tmp_path: Path) -> None:
        src = _src("""
            grade() {
              if [ "$1" -gt 90 ]; then
                echo A
              elif [ "$1" -gt 70 ]; then
                echo B
              else
                echo C
              fi
            }
        """)
        fp = _write_sh(tmp_path, src)
        result = analyze_bash_source_ast_grep(src, fp)
        assert result is not None
        _, fn_cc = result
        # base(1) + if(1) + elif(1) = 3
        assert fn_cc[0].complexity == 3.0

    def test_until_loop(self, tmp_path: Path) -> None:
        """until aliases to while_statement in tree-sitter-bash; still counted."""
        src = _src("""
            wait_done() {
              until [ -f /tmp/done ]; do
                sleep 1
              done
            }
        """)
        fp = _write_sh(tmp_path, src)
        result = analyze_bash_source_ast_grep(src, fp)
        assert result is not None
        _, fn_cc = result
        assert fn_cc[0].complexity == 2.0  # base(1) + until/while_statement(1)

    def test_c_style_for_loop(self, tmp_path: Path) -> None:
        src = _src("""
            count() {
              for ((i=0; i<10; i++)); do
                echo "$i"
              done
            }
        """)
        fp = _write_sh(tmp_path, src)
        result = analyze_bash_source_ast_grep(src, fp)
        assert result is not None
        _, fn_cc = result
        assert fn_cc[0].complexity == 2.0  # base(1) + c_style_for_statement(1)

    def test_select_statement(self, tmp_path: Path) -> None:
        """select aliases to for_statement in tree-sitter-bash; still counted."""
        src = _src("""
            choose() {
              select opt in one two three; do
                echo "$opt"
                break
              done
            }
        """)
        fp = _write_sh(tmp_path, src)
        result = analyze_bash_source_ast_grep(src, fp)
        assert result is not None
        _, fn_cc = result
        assert fn_cc[0].complexity == 2.0  # base(1) + select/for_statement(1)

    def test_file_level_complexity(self, tmp_path: Path) -> None:
        src = _src("""
            if [ -f /etc/hosts ]; then
              echo "found"
            fi
        """)
        fp = _write_sh(tmp_path, src)
        result = analyze_bash_source_ast_grep(src, fp)
        assert result is not None
        entry, _ = result
        assert entry.complexity >= 2.0

    def test_no_double_counting_across_functions(self, tmp_path: Path) -> None:
        """Branches in fn_a must not contaminate fn_b's count."""
        src = _src("""
            simple() {
              echo "no branches"
            }
            complex_fn() {
              if [ "$1" -gt 0 ]; then
                if [ "$1" -gt 10 ]; then
                  echo "big"
                fi
              fi
            }
        """)
        fp = _write_sh(tmp_path, src)
        result = analyze_bash_source_ast_grep(src, fp)
        assert result is not None
        _, fn_cc = result
        by_name = {f.function_name: f for f in fn_cc}
        assert "simple" in by_name
        assert "complex_fn" in by_name
        assert by_name["simple"].complexity == 1.0
        assert by_name["complex_fn"].complexity >= 3.0
