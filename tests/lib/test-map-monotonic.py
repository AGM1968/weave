#!/usr/bin/env python3
"""Refuse test-map edits that reduce suites selected for a tracked path."""

from __future__ import annotations

import argparse
import fnmatch
import subprocess
from pathlib import Path


def parse_map(path: Path) -> tuple[dict[str, set[str]], list[tuple[str, set[str]]], set[str]]:
    exact: dict[str, set[str]] = {}
    patterns: list[tuple[str, set[str]]] = []
    defaults: set[str] = set()
    in_default = False
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.lstrip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("["):
            in_default = line == "[default]"
            continue
        if "=" not in line:
            if in_default:
                defaults.update(line.split())
            continue
        key, value = (part.strip() for part in line.split("=", 1))
        suites = set(value.split())
        if key == "*":
            defaults.update(suites)
        elif key.endswith("/") or any(char in key for char in "*?["):
            patterns.append((key, suites))
        else:
            exact[key] = suites
    return exact, patterns, defaults


def heuristic(path: str) -> set[str]:
    if path.startswith("scripts/cmd/wv-cmd-") and path.endswith(".sh"):
        name = Path(path).stem.removeprefix("wv-cmd-")
        return {f"tests/test-{name}.sh"}
    if (path.startswith("scripts/lib/") and path.endswith(".sh")) or path == "scripts/wv":
        return {"tests/test-hooks.sh", "tests/test-graph.sh"}
    if path.startswith("scripts/hooks/"):
        return {"tests/test-hooks.sh"}
    if path.startswith("tests/test-") and path.endswith(".sh"):
        return {path}
    return set()


def selected(path: str, mapping: tuple[dict[str, set[str]], list[tuple[str, set[str]]], set[str]]) -> set[str]:
    exact, patterns, defaults = mapping
    suites = set(exact.get(path, set()))
    for pattern, mapped in patterns:
        if (pattern.endswith("/") and path.startswith(pattern)) or (
            not pattern.endswith("/") and fnmatch.fnmatchcase(path, pattern)
        ):
            suites.update(mapped)
    return suites or heuristic(path) or defaults


def tracked_paths(repo: Path) -> set[str]:
    result = subprocess.run(
        ["git", "ls-files"], cwd=repo, check=True, capture_output=True, text=True
    )
    return set(result.stdout.splitlines())


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("before", type=Path)
    parser.add_argument("after", type=Path)
    parser.add_argument("--repo", type=Path, required=True)
    args = parser.parse_args()

    before = parse_map(args.before)
    after = parse_map(args.after)
    paths = tracked_paths(args.repo) | set(before[0]) | set(after[0])
    problems = []
    for path in sorted(paths):
        missing = selected(path, before) - selected(path, after)
        if missing:
            problems.append(f"PROBLEM {path}: routing lost {', '.join(sorted(missing))}")
    print(f"COUNT {len(paths)} paths compared")
    print("\n".join(problems))
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
