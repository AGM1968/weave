#!/usr/bin/env python3
"""Propose a gate provisioning declaration from a repository's lockfiles.

Gate provisioning S4 (wv-0ee3f4). Prints a version-3 declaration for
.weave/gate-provision.json, built from the lockfiles in the working tree and
checked by the gate's own loader before it is printed, so a proposal is never
one the gate would refuse. It never writes the declaration: adopting a suite is
the repository's decision (transition rule 1), so wv init-repo stores the
proposal beside it for review. A manifest with no lockfile is reported on
stderr, not proposed: an unlocked dependency set is not a toolchain (Open
Decision 5). Prints nothing when there is nothing to propose.

Usage: wv-gate-propose.py <repo-root>
"""
from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path
from typing import Any

SKIP_DIRS = {"node_modules", "vendor", "target", "dist", "build", "venv"}


def loader() -> Any:
    """The gate's loader, beside this file, so validation is the gate's own."""
    spec = importlib.util.spec_from_file_location("wv_gate_suite", Path(__file__).with_name("wv-gate-suite.py"))
    if spec is None or spec.loader is None:
        raise RuntimeError("wv-gate-suite.py not found beside wv-gate-propose.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def candidate_dirs(root: Path) -> list[str]:
    """The repository root and its visible top-level directories."""
    dirs = ["."]
    for child in sorted(root.iterdir()):
        if child.is_dir() and not child.name.startswith(".") and child.name not in SKIP_DIRS:
            dirs.append(child.name)
    return dirs


def joined(directory: str, name: str) -> str:
    """A repository-relative path to name inside directory."""
    return name if directory == "." else f"{directory}/{name}"


def recipe_name(kind: str, directory: str) -> str:
    """The recipe's name: the kind, suffixed by its directory below the root."""
    return kind if directory == "." else f"{kind}-{directory}"


def python_recipe(kind: str, directory: str, lock: str) -> dict[str, Any]:
    """A private environment from a Poetry or uv lock, as the self-host recipe builds it."""
    env = "{work}/.venv" if directory == "." else f"{{work}}/{directory}/.venv"
    if kind == "python-poetry":
        sync = 'export PATH="$VIRTUAL_ENV/bin:$PATH"; exec poetry sync --no-root --no-interaction'
        run: list[Any] = [["python3", "-m", "venv", "--without-pip", env], ["bash", "-c", sync]]
        recipe: dict[str, Any] = {"tools": ["poetry"], "run": run}
    else:
        recipe = {"tools": ["uv"], "run": ["uv", "sync", "--frozen", "--no-install-project"],
                  "env": {"UV_PROJECT_ENVIRONMENT": env, "UV_CACHE_DIR": "{cache}/uv"}}
    recipe.update({"inputs": [joined(directory, "pyproject.toml"), joined(directory, lock)],
                   "provides": {"VIRTUAL_ENV": env, "PATH": f"{env}/bin"},
                   "outputs": [joined(directory, ".venv")]})
    if directory != ".":
        recipe["cwd"] = directory
    return recipe


NODE_LOCKS = {
    "package-lock.json": ("node-npm", ["npm"], ["npm", "ci", "--ignore-scripts", "--no-audit", "--no-fund"]),
    "pnpm-lock.yaml": ("node-pnpm", ["pnpm"], ["pnpm", "install", "--frozen-lockfile", "--ignore-scripts"]),
    "yarn.lock": ("node-yarn", ["yarn"], ["yarn", "install", "--frozen-lockfile", "--ignore-scripts"]),
}


def detect(root: Path) -> tuple[dict[str, Any], list[str]]:
    """Recipes for each locked toolchain, and notes for each unlocked one."""
    recipes: dict[str, Any] = {}
    notes: list[str] = []
    for directory in candidate_dirs(root):
        base = root / directory
        if (base / "pyproject.toml").is_file():
            for lock, kind in (("poetry.lock", "python-poetry"), ("uv.lock", "python-uv")):
                if (base / lock).is_file():
                    recipes[recipe_name(kind, directory)] = python_recipe(kind, directory, lock)
                    break
            else:
                notes.append(f"{joined(directory, 'pyproject.toml')} has no poetry.lock or uv.lock: not proposed")
        if (base / "requirements.txt").is_file() and not (base / "pyproject.toml").is_file():
            notes.append(f"{joined(directory, 'requirements.txt')} is a name-and-version list, not a lock:"
                         " not proposed (it needs a captured resolution)")
        if (base / "package.json").is_file():
            for lock, (kind, tools, run) in NODE_LOCKS.items():
                if (base / lock).is_file():
                    recipe: dict[str, Any] = {"tools": ["node", *tools], "run": run,
                                              "inputs": [joined(directory, "package.json"), joined(directory, lock)]}
                    if directory != ".":
                        recipe["cwd"] = directory
                    recipes[recipe_name(kind, directory)] = recipe
                    break
            else:
                notes.append(f"{joined(directory, 'package.json')} has no lockfile: not proposed")
        if (base / "Cargo.lock").is_file() and (base / "Cargo.toml").is_file():
            manifest = joined(directory, "Cargo.toml")
            recipes[recipe_name("rust-cargo", directory)] = {
                "tools": ["cargo", "rustc"], "inputs": [manifest, joined(directory, "Cargo.lock")],
                "run": ["cargo", "fetch", "--locked", "--manifest-path", manifest]}
    return recipes, notes


def mapped_suites(root: Path) -> list[str]:
    """Suites .weave/test-map.conf routes to, that exist; else the scaffolded runner."""
    suites: list[str] = []
    test_map = root / ".weave" / "test-map.conf"
    if test_map.is_file():
        for line in test_map.read_text(encoding="utf-8", errors="replace").splitlines():
            line = line.split("#", 1)[0]
            if "=" not in line:
                continue
            for suite in line.split("=", 1)[1].split():
                if suite not in suites and (root / suite).is_file():
                    suites.append(suite)
    if not suites and (root / "scripts" / "test-impacted.sh").is_file():
        suites.append("scripts/test-impacted.sh")
    return suites


def main() -> int:
    """Print the proposal for the repository named on the command line."""
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    root = Path(sys.argv[1]).resolve()
    recipes, notes = detect(root)
    suites = mapped_suites(root)
    for note in notes:
        print(f"gate-provision proposal: {note}", file=sys.stderr)
    if not recipes or not suites:
        return 0
    document = {"version": 3, "default": {"mode": "checkout"}, "recipes": recipes,
                "suites": {suite: {"recipes": list(recipes)} for suite in suites}}
    loader().declaration_policy(json.loads(json.dumps(document)))
    print(json.dumps(document, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
