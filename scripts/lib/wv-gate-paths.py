#!/usr/bin/env python3
"""Advisory literal-path inspection; never execute or expand a routed script."""

from __future__ import annotations

from pathlib import Path, PurePosixPath
import re
import shlex
import subprocess
import sys


def declared_scripts(text: str) -> set[str]:
    """Inventory route values, defaults and scanner keys; tiers/inputs are not routes."""
    suites: set[str] = set()
    section = ""
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("["):
            section = line.split("]", 1)[0][1:]
        elif section not in {"heavy", "inputs"}:
            if "=" in line:
                key, value = line.split("=", 1)
                suites.update(key.split() if section == "scanners" else value.split())
            elif section == "default":
                suites.update(line.split())
    return suites


def literal_paths(text: str) -> set[str]:
    """Recognise literal shell arguments/assignments, not computed paths or comments."""
    paths: set[str] = set()
    lexer = shlex.shlex(text, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    for token in lexer:
        token = re.sub(r"^[A-Za-z_][A-Za-z_0-9]*=", "", token)
        if (not token or token.startswith(("/", "~", "-"))
                or any(char in token for char in "$`*?[]")):
            continue
        if "/" not in token and not token.startswith("."):
            continue
        if ".." in PurePosixPath(token).parts or ":" in token:
            continue
        paths.add(str(PurePosixPath(token)))
    return paths


DECLARATION = ".weave/gate-provision.json"
CHECK_IGNORE_RULE = re.compile(r"^(?P<rule>.*?:\d+:(?P<pattern>.*))\t")


def declaration_findings(repo: Path) -> list[str]:
    """The gate reads its declaration from commits only, so an ignored one never lands (wv-bca9ec)."""
    result = subprocess.run(["git", "-C", str(repo), "check-ignore", "-v", "--", DECLARATION],
                            capture_output=True, check=False)
    if result.returncode == 1:
        return []  # not ignored, or already tracked
    if result.returncode != 0:
        raise OSError(result.stderr.decode(errors="replace").strip())
    match = CHECK_IGNORE_RULE.match(result.stdout.decode(errors="replace"))
    if match is None or match["pattern"].startswith("!"):
        return []  # -v also reports the negation rule that keeps it
    return [f"{DECLARATION} is ignored by {match['rule']}, so git add skips it and the gate never "
            f"reads it; add the line !{DECLARATION} to .gitignore"]


def suite_entry(repo: Path, suite: str) -> str | set[str]:
    """One routed script's literal paths, or why they cannot be read."""
    script = repo / suite
    if not script.resolve().is_relative_to(repo) or not script.is_file():
        return f"{suite}: routed script unavailable for literal-path inspection"
    try:
        return literal_paths(script.read_text())
    except (OSError, UnicodeError, ValueError) as error:
        return f"{suite}: literal-path inspection unavailable: {error}"


def ignored_paths(repo: Path, paths: list[str]) -> set[str]:
    """One git check-ignore over every path (wv-d737f9): git judges each on its own."""
    if not paths:
        return set()
    result = subprocess.run(["git", "-C", str(repo), "check-ignore", "--stdin", "-z"],
                            input=b"".join(path.encode() + b"\0" for path in paths),
                            capture_output=True, check=False)
    if result.returncode not in (0, 1):
        raise OSError(result.stderr.decode(errors="replace").strip())
    return {raw.decode() for raw in result.stdout.split(b"\0") if raw}


def suite_findings(entries: list[tuple[str, str | set[str]]], ignored: set[str]) -> list[str]:
    """Per suite in sorted order: its unreadable note, or each ignored literal path."""
    findings: list[str] = []
    for suite, outcome in entries:
        if isinstance(outcome, str):
            findings.append(outcome)
        else:
            findings.extend(f"{suite}: references ignored path {path}"
                            for path in sorted(outcome) if path in ignored)
    return findings


def inspect(repo: Path) -> list[str]:
    """Return nonblocking findings; Git decides whether a literal path is ignored."""
    conf = repo / ".weave/test-map.conf"
    if not conf.exists() and not conf.is_symlink():
        return []
    if not conf.resolve().is_relative_to(repo):
        return ["test-map.conf is outside the repository; literal-path inspection unavailable"]
    # Asking git once and reporting per suite in sorted order gives what one
    # call per suite gave, without ~165 git processes.
    entries = [(suite, suite_entry(repo, suite)) for suite in sorted(declared_scripts(conf.read_text()))]
    ignored = ignored_paths(repo, sorted(set().union(
        *(paths for _, paths in entries if isinstance(paths, set)))))
    return declaration_findings(repo) + suite_findings(entries, ignored)


def main() -> int:
    """Shared text report for doctor and the installed initializer."""
    try:
        findings = inspect(Path(sys.argv[1]).resolve())
    except (OSError, UnicodeError, ValueError) as error:
        print(f"routed-script literal-path inspection unavailable: {error}", file=sys.stderr)
        return 1
    if findings:
        print("; ".join(findings) + "; advisory only; computed paths are not evaluated")
    return 0


if __name__ == "__main__":
    sys.exit(main())
