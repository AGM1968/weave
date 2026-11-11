#!/usr/bin/env python3
"""Classify measured route reach from strace logs (wv-be5057).

Reads <dir>/<suite-stem>.trace, written by tests/lib/route-reach-measure.sh,
for every suite in <row-file> and writes <dir>/reach.json: per suite, the
command modules a process EXECUTED (reach), the ones only byte readers opened,
and the wv subcommands the suite ran (the route-evidence guard re-checks those
statically).

An open counts as reach unless the opening process was running a byte reader
(awk, grep, md5sum, cp, tar, git, python3, ...): copy and hash readers route by
execution (panel wv-e96c65 q2). Unknown programs count as reach, so an unlisted
reader can only keep a suite routed. Under strace -f a child's own lines can be
printed before its parent's clone() line, so the program at an open is the pid's
last execve BEFORE that line, else its parent's at the fork; a one-pass "exe of
the pid so far" mapping misattributes the autoload stub scan's awk to wv.

Usage: route-reach-classify.py <dir> <row-file> [module ...]
"""
from __future__ import annotations

import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

LINE = re.compile(r"^(\d+)\s+(\w+)\((.*)\)\s+=\s+(-?\d+)")
EXEC = re.compile(r'^"([^"]*)", \[(.*?)\](?:, |$)')
STR = re.compile(r'"((?:[^"\\]|\\.)*)"')
OPEN = re.compile(r'"([^"]*wv-cmd-([a-z]+)\.sh)"')
READERS = {
    "awk", "gawk", "mawk", "grep", "egrep", "rg", "ugrep", "md5sum", "sha256sum", "sha1sum",
    "cksum", "cp", "tar", "git", "python3", "python", "cat", "sed", "diff", "cmp", "head",
    "tail", "wc", "rsync", "install", "jq", "find", "file", "stat", "ln", "mv", "shellcheck",
}
DEFAULT_MODULES = ["doctor", "health", "help", "orient", "ops"]
FORKS = ("clone", "clone3", "fork", "vfork")


def wv_cmds(argv: list[str]) -> set[str]:
    """The subcommand a wv argv runs, plus --help when one is passed."""
    args = argv[1:]
    cmds = {"--help"} if any(a in ("--help", "-h") for a in args) else set()
    for arg in args:
        if arg in ("--version", "-V", "version"):
            cmds.add(arg if arg == "version" else "--version")
            break
        if not arg.startswith("-"):
            cmds.add(arg)
            break
    return cmds


@dataclass
class Lineage:
    """Process lineage from one trace: each pid's execs and the fork that made it."""

    execs: dict[int, list[tuple[int, str]]] = field(default_factory=dict)
    parent: dict[int, int] = field(default_factory=dict)
    forked_at: dict[int, int] = field(default_factory=dict)

    def program_at(self, pid: int, line_no: int) -> str:
        """The program pid was running at line_no."""
        for _ in range(64):
            before = [name for at, name in self.execs.get(pid, []) if at < line_no]
            if before:
                return before[-1]
            if pid not in self.parent:
                break
            pid, line_no = self.parent[pid], self.forked_at[pid]
        return "?"


def classify(trace: Path, modules: list[str]) -> dict[str, object]:
    """One suite's reach, byte-only reads, readers and wv commands."""
    lineage = Lineage()
    opens: list[tuple[int, int, str]] = []
    cmds: set[str] = set()
    lines = trace.read_text(encoding="utf-8", errors="replace").splitlines() if trace.exists() else []
    for number, line in enumerate(lines):
        match = LINE.match(line)
        if not match:
            continue
        pid, call, args, ret = int(match[1]), match[2], match[3], int(match[4])
        if call in FORKS:
            lineage.parent[ret], lineage.forked_at[ret] = pid, number
        elif call == "execve" and (exe := EXEC.match(args)):
            name = Path(exe[1]).name
            lineage.execs.setdefault(pid, []).append((number, name))
            if name == "wv":
                cmds |= wv_cmds(STR.findall(exe[2]))
        elif call == "openat" and (opened := OPEN.search(args)) and opened[2] in modules:
            opens.append((number, pid, opened[2]))
    reach: set[str] = set()
    read: set[str] = set()
    readers: dict[str, set[str]] = {}
    for number, pid, module in opens:
        program = lineage.program_at(pid, number)
        executed = program not in READERS
        (reach if executed else read).add(module)
        readers.setdefault(module, set()).add(("exec:" if executed else "") + program)
    return {"traced": trace.exists(), "reach": sorted(reach), "byte_read_only": sorted(read - reach),
            "readers": {k: sorted(v) for k, v in readers.items()}, "wv_cmds": sorted(cmds)}


def reach_of(record: dict[str, object]) -> list[str]:
    """The modules a classified record reached."""
    reach = record["reach"]
    return reach if isinstance(reach, list) else []


def main() -> int:
    """Classify every suite in the row file and print per-module reach counts."""
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    out, row = Path(sys.argv[1]), Path(sys.argv[2])
    modules = sys.argv[3:] or DEFAULT_MODULES
    # A module is a family name (doctor, orient), the part OPEN captures from
    # wv-cmd-<family>.sh. A path given instead matched nothing and reported
    # "0 reach" for every suite, a false result (wv-49e5df, 2026-11-07).
    bad = [m for m in modules if not re.fullmatch(r"[a-z]+", m)]
    if bad:
        print(f"route-reach-classify: modules are family names such as doctor or orient, not {' '.join(bad)}",
              file=sys.stderr)
        return 2
    suites = [line.strip() for line in row.read_text(encoding="utf-8").splitlines() if line.strip()]
    result = {suite: classify(out / f"{Path(suite).stem}.trace", modules) for suite in suites}
    (out / "reach.json").write_text(json.dumps(result, indent=1) + "\n", encoding="utf-8")
    for module in modules:
        count = sum(module in reach_of(v) for v in result.values())
        print(f"{module}: {count} reach / {len(result)}")
    untraced = [s for s, v in result.items() if not v["traced"]]
    if untraced:
        print("PROBLEM no trace for: " + " ".join(untraced))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
