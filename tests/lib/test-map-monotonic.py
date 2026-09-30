#!/usr/bin/env python3
"""Refuse test-map edits that reduce suites selected for a tracked path."""

from __future__ import annotations

import argparse
import fnmatch
import re
import subprocess
from pathlib import Path


def parse_map(path: Path) -> tuple[dict[str, set[str]], list[tuple[str, set[str]]], set[str], list[tuple[str, list[str]]]]:
    exact: dict[str, set[str]] = {}
    patterns: list[tuple[str, set[str]]] = []
    defaults: set[str] = set()
    # [scanners] (wv-b21ca8): suite = the globs it scans, applied additively,
    # mirroring _impact_suites_for_files. Not rows: the key is a suite.
    scanners: list[tuple[str, list[str]]] = []
    in_default = in_scanners = False
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.lstrip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("["):
            in_default = line == "[default]"
            in_scanners = line == "[scanners]"
            continue
        if in_scanners:
            if "=" in line:
                suite, scopes = (part.strip() for part in line.split("=", 1))
                scanners.append((suite, scopes.split()))
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
    return exact, patterns, defaults, scanners


def heuristic(path: str) -> set[str]:
    if path.startswith("scripts/cmd/wv-cmd-") and path.endswith(".sh"):
        name = Path(path).stem.removeprefix("wv-cmd-")
        return {f"tests/test-{name}.sh"}
    if (path.startswith("scripts/lib/") and path.endswith(".sh")) or path == "scripts/wv":
        return {"tests/test-hooks.sh", "tests/test-graph.sh"}
    if path.startswith("scripts/hooks/"):
        return {"tests/test-hooks.sh"}
    return set()


def selected(path: str, mapping: tuple[dict[str, set[str]], list[tuple[str, set[str]]], set[str], list[tuple[str, list[str]]]]) -> set[str]:
    return targeted(path, mapping) or mapping[2]


def targeted(path: str, mapping: tuple[dict[str, set[str]], list[tuple[str, set[str]]], set[str], list[tuple[str, list[str]]]]) -> set[str]:
    """Routing that names this path, excluding the catch-all fallback.

    The invariant is that a map edit must not silently remove a suite that was
    selected before. Applied to the full selection it also fires when a path
    moves from the [default] fallback to its first explicit row -- the default
    suites stop applying, which reads as a loss but is the opposite: they were
    a placeholder that tested nothing about the file, replaced by the suite
    that actually exercises it. Adding coverage must not be reported as
    removing it, so the comparison is over targeted routes only. A path that
    loses a real route still fails, because its targeted set shrinks to empty.
    """
    exact, patterns, _, scanners = mapping
    suites = set(exact.get(path, set()))
    for pattern, mapped in patterns:
        if (pattern.endswith("/") and path.startswith(pattern)) or (
            not pattern.endswith("/") and fnmatch.fnmatchcase(path, pattern)
        ):
            suites.update(mapped)
    # A changed suite runs itself unless its own exact row redirects it,
    # mirroring _impact_suites_for_files (wv-a8ab96).
    if path.startswith("tests/test-") and path.endswith(".sh") and path not in exact:
        suites.add(path)
    suites = suites or heuristic(path)
    # Scanners add on top of whatever the path already resolves to.
    for suite, scopes in scanners:
        if any(fnmatch.fnmatchcase(path, scope) for scope in scopes):
            suites.add(suite)
    return suites


def tracked_paths(repo: Path) -> set[str]:
    result = subprocess.run(
        ["git", "ls-files"], cwd=repo, check=True, capture_output=True, text=True
    )
    return set(result.stdout.splitlines())


RETIREMENT = re.compile(r"^(wv-[0-9a-f]{6}) +(\S+) *= *(\S.*)$")


def parse_retired(path: Path | None) -> list[tuple[str, str, list[str]]]:
    """Routes removed on measured evidence (wv-2d09a7).

    Each line is `<node> <suite> = <scope glob...>`: the node holds the
    evidence that the suite never catches a break in files matching the scope.
    A lost suite is accepted only for a path a line names; anything else still
    fails, and a line that does not parse is an error rather than a no-op.
    """
    if path is None or not path.exists():
        return []
    entries = []
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        match = RETIREMENT.match(line)
        if not match:
            raise SystemExit(f"ERROR {path}:{number}: expected '<wv-id> <suite> = <scope...>', got: {line}")
        entries.append((match.group(1), match.group(2), match.group(3).split()))
    return entries


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("before", type=Path)
    parser.add_argument("after", type=Path)
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--retired", type=Path)
    args = parser.parse_args()

    before = parse_map(args.before)
    after = parse_map(args.after)
    retired = parse_retired(args.retired)
    # A map key for a file that is neither tracked nor on disk routes nothing:
    # deleting a file together with its row is not a lost route (wv-56c823
    # retired a hook source and its row, and this reported it as one).
    paths = tracked_paths(args.repo) | {
        p for p in set(before[0]) | set(after[0]) if (args.repo / p).exists()
    }
    problems = []
    for path in sorted(paths):
        missing = targeted(path, before) - targeted(path, after)
        missing -= {
            suite for _, suite, scopes in retired
            if any(fnmatch.fnmatchcase(path, scope) for scope in scopes)
        }
        if missing:
            problems.append(f"PROBLEM {path}: routing lost {', '.join(sorted(missing))}")
    print(f"COUNT {len(paths)} paths compared")
    print("\n".join(problems))
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
