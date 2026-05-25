"""Tests for weave_quality.typescript_parser -- ast-grep CC scanner.

Tests that require ast-grep are skipped when the binary is absent.
"""

# pylint: disable=missing-class-docstring,missing-function-docstring,too-few-public-methods

from __future__ import annotations

import textwrap
from pathlib import Path

import pytest

from weave_quality.typescript_parser import (
    _fn_name,
    analyze_typescript_file,
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

AST_GREP = pytest.mark.skipif(
    not __import__("shutil").which("ast-grep"),
    reason="ast-grep not installed",
)


def _write_ts(tmp_path: Path, code: str, name: str = "test.ts") -> str:
    """Dedent code, write to tmp_path, return absolute filepath string."""
    p = tmp_path / name
    p.write_text(textwrap.dedent(code).lstrip(), encoding="utf-8")
    return str(p)


# ---------------------------------------------------------------------------
# _fn_name (pure unit tests — no ast-grep required)
# ---------------------------------------------------------------------------


class TestFnName:
    def test_function_declaration(self) -> None:
        assert _fn_name("function greet(name: string): string {") == "greet"

    def test_async_function(self) -> None:
        assert _fn_name("async function fetchData(): Promise<void> {") == "fetchData"

    def test_generator_function(self) -> None:
        assert _fn_name("function* generate(): Generator<number> {") == "generate"

    def test_export_default_function(self) -> None:
        assert _fn_name("export default function handler(req: Request) {") == "handler"

    def test_method_definition(self) -> None:
        assert _fn_name("greet(name: string): string {") == "greet"

    def test_async_method(self) -> None:
        assert _fn_name("async fetchData(): Promise<void> {") == "fetchData"

    def test_static_method(self) -> None:
        assert _fn_name("static create(): MyClass {") == "create"

    def test_private_method(self) -> None:
        assert _fn_name("private validate(x: number): boolean {") == "validate"

    def test_getter(self) -> None:
        assert _fn_name("get value(): number {") == "value"

    def test_setter(self) -> None:
        assert _fn_name("set value(v: number) {") == "value"

    def test_arrow_function_no_name(self) -> None:
        assert _fn_name("(a: number, b: number) => {") == "<anonymous>"

    def test_anonymous_function_expression(self) -> None:
        assert _fn_name("function(x: number) {") == "<anonymous>"

    def test_named_function_expression(self) -> None:
        assert _fn_name("function helper(x: number) {") == "helper"

    def test_constructor(self) -> None:
        assert _fn_name("constructor(private name: string) {") == "constructor"


# ---------------------------------------------------------------------------
# analyze_typescript_file — ast-grep required
# ---------------------------------------------------------------------------


class TestFallback:
    def test_missing_rule_files_returns_none(self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
        """When rule files are absent, returns None (graceful degradation)."""
        import weave_quality.typescript_parser as mod  # pylint: disable=import-outside-toplevel
        monkeypatch.setattr(mod, "_CC_RULE", tmp_path / "nonexistent_cc.yaml")
        monkeypatch.setattr(mod, "_FN_RULE", tmp_path / "nonexistent_fn.yaml")
        p = tmp_path / "f.ts"
        p.write_text("const x = 1;\n", encoding="utf-8")
        assert analyze_typescript_file(str(p)) is None


@AST_GREP
class TestFileEntry:
    def test_language_is_typescript(self, tmp_path: Path) -> None:
        fp = _write_ts(tmp_path, """
            function hello(): void {
              console.log("hi");
            }
        """)
        result = analyze_typescript_file(fp)
        assert result is not None
        entry, _ = result
        assert entry.language == "typescript"

    def test_loc_nonzero(self, tmp_path: Path) -> None:
        fp = _write_ts(tmp_path, """
            function hello(): void {
              console.log("hi");
            }
        """)
        result = analyze_typescript_file(fp)
        assert result is not None
        entry, _ = result
        assert entry.loc > 0

    def test_empty_file(self, tmp_path: Path) -> None:
        fp = _write_ts(tmp_path, "\n")
        result = analyze_typescript_file(fp)
        assert result is not None
        entry, fns = result
        assert entry.functions == 0
        assert fns == []
        assert entry.complexity == 1.0


@AST_GREP
class TestCCCounting:
    def test_if_statement(self, tmp_path: Path) -> None:
        fp = _write_ts(tmp_path, """
            function check(x: number): string {
              if (x > 0) {
                return "pos";
              }
              return "non-pos";
            }
        """)
        result = analyze_typescript_file(fp)
        assert result is not None
        _, fns = result
        assert len(fns) == 1
        assert fns[0].complexity == 2.0  # base(1) + if(1)

    def test_for_loop(self, tmp_path: Path) -> None:
        fp = _write_ts(tmp_path, """
            function sum(arr: number[]): number {
              let total = 0;
              for (let i = 0; i < arr.length; i++) {
                total += arr[i];
              }
              return total;
            }
        """)
        result = analyze_typescript_file(fp)
        assert result is not None
        _, fns = result
        assert fns[0].complexity >= 2.0

    def test_for_of_loop(self, tmp_path: Path) -> None:
        fp = _write_ts(tmp_path, """
            function process(items: string[]): void {
              for (const item of items) {
                console.log(item);
              }
            }
        """)
        result = analyze_typescript_file(fp)
        assert result is not None
        _, fns = result
        assert fns[0].complexity >= 2.0

    def test_while_loop(self, tmp_path: Path) -> None:
        fp = _write_ts(tmp_path, """
            function countdown(n: number): void {
              while (n > 0) {
                n--;
              }
            }
        """)
        result = analyze_typescript_file(fp)
        assert result is not None
        _, fns = result
        assert fns[0].complexity >= 2.0

    def test_ternary(self, tmp_path: Path) -> None:
        fp = _write_ts(tmp_path, """
            function sign(x: number): string {
              return x > 0 ? "pos" : "neg";
            }
        """)
        result = analyze_typescript_file(fp)
        assert result is not None
        _, fns = result
        assert fns[0].complexity >= 2.0

    def test_logical_and(self, tmp_path: Path) -> None:
        fp = _write_ts(tmp_path, """
            function inRange(x: number): boolean {
              return x > 0 && x < 100;
            }
        """)
        result = analyze_typescript_file(fp)
        assert result is not None
        _, fns = result
        assert fns[0].complexity >= 2.0

    def test_nullish_coalescing(self, tmp_path: Path) -> None:
        fp = _write_ts(tmp_path, """
            function withDefault(x: string | null): string {
              return x ?? "default";
            }
        """)
        result = analyze_typescript_file(fp)
        assert result is not None
        _, fns = result
        assert fns[0].complexity >= 2.0

    def test_switch_case(self, tmp_path: Path) -> None:
        fp = _write_ts(tmp_path, """
            function describe(n: number): string {
              switch (n) {
                case 1: return "one";
                case 2: return "two";
                default: return "other";
              }
            }
        """)
        result = analyze_typescript_file(fp)
        assert result is not None
        _, fns = result
        # 2 case_clause nodes (not default) + base = at least 3
        assert fns[0].complexity >= 3.0


@AST_GREP
class TestFunctionDetection:
    def test_named_function(self, tmp_path: Path) -> None:
        fp = _write_ts(tmp_path, """
            function greet(name: string): string {
              return `Hello ${name}`;
            }
        """)
        result = analyze_typescript_file(fp)
        assert result is not None
        _, fns = result
        assert len(fns) == 1
        assert fns[0].function_name == "greet"

    def test_class_method(self, tmp_path: Path) -> None:
        fp = _write_ts(tmp_path, """
            class Greeter {
              greet(name: string): string {
                return `Hi ${name}`;
              }
            }
        """)
        result = analyze_typescript_file(fp)
        assert result is not None
        _, fns = result
        names = [f.function_name for f in fns]
        assert "greet" in names

    def test_oneliner_arrow_excluded(self, tmp_path: Path) -> None:
        """Single-line arrow functions should not appear as tracked functions."""
        fp = _write_ts(tmp_path, """
            const add = (a: number, b: number) => a + b;
        """)
        result = analyze_typescript_file(fp)
        assert result is not None
        _, fns = result
        assert len(fns) == 0

    def test_multiline_arrow_included(self, tmp_path: Path) -> None:
        fp = _write_ts(tmp_path, """
            const process = (items: string[]): string[] => {
              return items.map(s => s.trim());
            };
        """)
        result = analyze_typescript_file(fp)
        assert result is not None
        _, fns = result
        assert len(fns) >= 1

    def test_multiple_functions(self, tmp_path: Path) -> None:
        fp = _write_ts(tmp_path, """
            function a(): void {
              console.log("a");
            }
            function b(): void {
              console.log("b");
            }
        """)
        result = analyze_typescript_file(fp)
        assert result is not None
        entry, fns = result
        assert entry.functions == 2
        names = {f.function_name for f in fns}
        assert "a" in names
        assert "b" in names

    def test_scan_id_propagated(self, tmp_path: Path) -> None:
        fp = _write_ts(tmp_path, """
            function hello(): void {
              console.log("hi");
            }
        """)
        result = analyze_typescript_file(fp, scan_id=42)
        assert result is not None
        entry, fns = result
        assert entry.scan_id == 42
        assert all(f.scan_id == 42 for f in fns)


@AST_GREP
class TestCCDistribution:
    def test_cc_assigned_to_correct_function(self, tmp_path: Path) -> None:
        """CC nodes inside function A don't contaminate function B's count."""
        fp = _write_ts(tmp_path, """
            function simple(): string {
              return "no branches";
            }
            function complex(x: number): string {
              if (x > 0) {
                if (x > 10) {
                  return "big";
                }
                return "small";
              }
              return "zero";
            }
        """)
        result = analyze_typescript_file(fp)
        assert result is not None
        _, fns = result
        by_name = {f.function_name: f for f in fns}
        assert "simple" in by_name
        assert "complex" in by_name
        assert by_name["simple"].complexity == 1.0
        assert by_name["complex"].complexity >= 3.0

    def test_three_ifs_gives_cc_four(self, tmp_path: Path) -> None:
        """Function with 3 if-statements has CC = 1 + 3 = 4."""
        fp = _write_ts(tmp_path, """
            function classify(x: number): string {
              if (x < 0) {
                return "negative";
              }
              if (x === 0) {
                return "zero";
              }
              if (x > 100) {
                return "big";
              }
              return "small";
            }
        """)
        result = analyze_typescript_file(fp)
        assert result is not None
        _, fns = result
        assert len(fns) == 1
        assert fns[0].complexity == 4.0


@AST_GREP
class TestConstructorDetection:
    def test_constructor_name_is_constructor(self, tmp_path: Path) -> None:
        """Class constructors must be named 'constructor', not '<anonymous>'."""
        fp = _write_ts(tmp_path, """
            class MyService {
              constructor(private name: string) {
                if (!name) {
                  throw new Error("name required");
                }
              }
            }
        """)
        result = analyze_typescript_file(fp)
        assert result is not None
        _, fns = result
        names = [f.function_name for f in fns]
        assert "constructor" in names
