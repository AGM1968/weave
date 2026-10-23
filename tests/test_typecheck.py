"""Public typecheck gate: preserve mapped strict checks after mypy retirement."""

import os
from pathlib import Path
import subprocess
import sys


def test_typecheck_rejects_type_errors_and_missing_strict_annotations(tmp_path: Path) -> None:
    """A valid typed file passes; each migrated policy rejects its counterexample."""
    root = Path(__file__).resolve().parents[1]
    probe = tmp_path / "probe.py"
    env = {**os.environ, "PYREFLY_CONFIG": str(root / "pyproject.toml")}
    command = ["make", "typecheck", f"PYTHON={sys.executable}", f"PYFILES={probe}"]
    probe.write_text(
        "from collections.abc import Callable\n"
        "from typing_extensions import override\n"
        "values: list[int] = []\ndef identity(value: int) -> int:\n    return value\n"
        "callback: Callable[[int], int] = lambda value: value + 1\n"
        "class Parent:\n    def value(self) -> int:\n        return 1\n"
        "class Child(Parent):\n    @override\n    def value(self) -> int:\n        return 2\n",
        encoding="utf-8",
    )
    clean = subprocess.run(command, cwd=root, env=env, capture_output=True, text=True, check=False)
    assert clean.returncode == 0, clean.stdout + clean.stderr

    probe.write_text(
        "from typing import Any, cast\n"
        "wrong: int = 'not an int'\n"
        "empty = []\n"
        "def parameter(value) -> int:\n    return 1\n"
        "def result(value: int):\n    return value\n"
        "def generic(value: list) -> None:\n    pass\n"
        "def unchecked(value: Any) -> int:\n    return value\n"
        "def casted(value: int) -> int:\n    return cast(int, value)\n"
        "decorator: Any = lambda value: value\n"
        "@decorator\ndef decorated() -> int:\n    return 1\n"
        "unused: int = 1  # type: ignore\n"
        "ambiguous = lambda argument: argument\n"
        "class Parent:\n    def value(self) -> int:\n        return 1\n"
        "class Child(Parent):\n    def value(self) -> int:\n        return 2\n",
        encoding="utf-8",
    )
    rejected = subprocess.run(command, cwd=root, env=env, capture_output=True, text=True, check=False)
    output = rejected.stdout + rejected.stderr
    assert rejected.returncode != 0, output
    for diagnostic in (
        "bad-assignment", "implicit-any-parameter", "unannotated-return",
        "implicit-any-type-argument", "no-any-return-explicit", "redundant-cast",
        "untyped-function-decorator", "unused-type-ignore", "implicit-any-empty-container",
        "missing-override-decorator", "implicit-any-lambda",
    ):
        assert f"[{diagnostic}]" in output, output
