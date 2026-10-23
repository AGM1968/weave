#!/usr/bin/env python3
"""Advisory literal-path inspection; never execute or expand a routed script."""

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


def inspect(repo: Path) -> list[str]:
    """Return nonblocking findings; Git decides whether a literal path is ignored."""
    conf = repo / ".weave/test-map.conf"
    if not conf.exists() and not conf.is_symlink():
        return []
    if not conf.resolve().is_relative_to(repo):
        return ["test-map.conf is outside the repository; literal-path inspection unavailable"]
    findings = []
    for suite in sorted(declared_scripts(conf.read_text())):
        script = repo / suite
        if not script.resolve().is_relative_to(repo) or not script.is_file():
            findings.append(f"{suite}: routed script unavailable for literal-path inspection")
            continue
        try:
            paths = literal_paths(script.read_text())
        except (OSError, UnicodeError, ValueError) as error:
            findings.append(f"{suite}: literal-path inspection unavailable: {error}")
            continue
        if not paths:
            continue
        result = subprocess.run(["git", "-C", str(repo), "check-ignore", "--stdin", "-z"],
                                input=b"".join(path.encode() + b"\0" for path in sorted(paths)),
                                capture_output=True, check=False)
        if result.returncode not in (0, 1):
            raise OSError(result.stderr.decode(errors="replace").strip())
        for raw in result.stdout.split(b"\0"):
            if raw:
                path = raw.decode()
                findings.append(f"{suite}: references ignored path {path}")
    return findings


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
