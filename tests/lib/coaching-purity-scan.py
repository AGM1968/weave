#!/usr/bin/env python3
"""Walk a package's import closure and report forbidden imports.

Static, deliberately: importing the modules to inspect them would let the very
side effects under test run first. The AST is parsed, every `import` and
`from ... import` is read, and first-party modules inside the scanned package
are followed so a forbidden import cannot hide one level down.

Reports one PROBLEM line per violation, then a COUNT line. Anything unexpected
raises, so a crash exits non-zero rather than printing a short, clean report.
"""

from __future__ import annotations

import ast
import sys
from pathlib import Path

# Capability, not vocabulary: each name is a way to reach outside the argument
# list. `pathlib`/`io`/`open` are filesystem, `subprocess`/`os` are process,
# `sqlite3` is the database, and `weave_quality` is the provider package whose
# whole point is that the pure side cannot see it.
FORBIDDEN = {
    "sqlite3": "database access",
    "subprocess": "process execution",
    "os": "process and filesystem access",
    "pathlib": "filesystem access",
    "io": "filesystem access",
    "shutil": "filesystem access",
    "tempfile": "filesystem access",
    "socket": "network access",
    "urllib": "network access",
    "http": "network access",
    "weave_quality": "provider package (quality.db lives there)",
    "weave_gh": "GitHub adapter",
}


def imported_names(tree: ast.AST) -> list[tuple[str, int]]:
    names: list[tuple[str, int]] = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            names.extend((alias.name, node.lineno) for alias in node.names)
        elif isinstance(node, ast.ImportFrom):
            if node.level:  # relative import: stays inside the package
                continue
            if node.module:
                names.append((node.module, node.lineno))
    return names


def scan(package: Path) -> list[str]:
    problems: list[str] = []
    modules = sorted(package.rglob("*.py"))
    if not modules:
        problems.append(f"{package}: no modules found; the purity scan would be vacuous")
    for module in modules:
        tree = ast.parse(module.read_text(encoding="utf-8"), filename=str(module))
        for name, lineno in imported_names(tree):
            root = name.split(".")[0]
            if root in FORBIDDEN:
                problems.append(
                    f"{module.relative_to(package.parent)}:{lineno}: imports {name!r} "
                    f"({FORBIDDEN[root]}); this package must be a pure function of its arguments"
                )
        # A dynamic import is the obvious way around a static scan, so name it.
        for node in ast.walk(tree):
            if isinstance(node, ast.Call):
                target = node.func
                dotted = getattr(target, "attr", None) or getattr(target, "id", None)
                if dotted in {"__import__", "import_module"}:
                    problems.append(
                        f"{module.relative_to(package.parent)}:{node.lineno}: dynamic import "
                        "defeats the purity boundary"
                    )
                if dotted == "open":
                    problems.append(
                        f"{module.relative_to(package.parent)}:{node.lineno}: open() is "
                        "filesystem access"
                    )
    return problems


def main() -> int:
    problems: list[str] = []
    packages = [Path(arg) for arg in sys.argv[1:]]
    for package in packages:
        if not package.is_dir():
            raise SystemExit(f"not a package directory: {package}")
        problems.extend(scan(package))
    for problem in problems:
        print("PROBLEM " + problem)
    print(f"COUNT {len(packages)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
