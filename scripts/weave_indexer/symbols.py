"""Definition table for exact name lookup in wv search --code (wv-35b5bd).

Each indexed file contributes the names it defines: shell functions, Python
functions and classes, and TypeScript/JavaScript functions, classes and arrow
functions bound to a const. Rows live in brain.db's code_symbols table, a
derived cache beside chunks in the hot zone; it is never part of the graph's
durable tables.

Line-oriented on purpose: one regular expression per language over each line,
the same reach as the 50-line chunks, with no parser dependency. A definition a
pattern misses is simply absent, and the lookup says so rather than guessing.
"""

from __future__ import annotations

import re
import sqlite3

_SHELL = (
    # The body opens on the definition line ({ or a subshell's (): 2,818 of this
    # repository's shell definitions do, and the only bare "name()" lines were
    # Python calls inside heredocs (conn.close()), which this excludes. Bash
    # allows "." and ":" in a function name, so they stay.
    re.compile(r"^\s*function\s+([A-Za-z_][A-Za-z0-9_:.-]*)\s*(?:\(\s*\))?\s*[{(]"),
    re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_:.-]*)\s*\(\s*\)\s*[{(]"),
)
_PYTHON = (
    (re.compile(r"^\s*(?:async\s+)?def\s+([A-Za-z_]\w*)\s*\("), "function"),
    (re.compile(r"^\s*class\s+([A-Za-z_]\w*)\s*[(:]"), "class"),
)
_SCRIPT = (
    (re.compile(r"^\s*(?:export\s+)?(?:default\s+)?(?:async\s+)?function\s*\*?\s+"
                r"([A-Za-z_$][\w$]*)\s*[(<]"), "function"),
    (re.compile(r"^\s*(?:export\s+)?(?:default\s+)?(?:abstract\s+)?class\s+([A-Za-z_$][\w$]*)\b"), "class"),
    (re.compile(r"^\s*(?:export\s+)?const\s+([A-Za-z_$][\w$]*)\s*(?::[^=]+)?=\s*(?:async\s+)?"
                r"(?:\([^)]*\)|[A-Za-z_$][\w$]*)\s*(?::[^=]+)?=>"), "function"),
)
_SHELL_EXTS = frozenset({".sh", ".bash"})
_PY_EXTS = frozenset({".py"})
_SCRIPT_EXTS = frozenset({".ts", ".tsx", ".js", ".mjs", ".cjs"})

SCHEMA = (
    "CREATE TABLE IF NOT EXISTS code_symbols ("
    " name TEXT NOT NULL, file TEXT NOT NULL, line INTEGER NOT NULL, kind TEXT NOT NULL,"
    " PRIMARY KEY (name, file, line))"
)
_INDEX = "CREATE INDEX IF NOT EXISTS code_symbols_file ON code_symbols(file)"


def _language(ext: str) -> str | None:
    if ext in _SHELL_EXTS:
        return "shell"
    if ext in _PY_EXTS:
        return "python"
    if ext in _SCRIPT_EXTS:
        return "script"
    return None


def _match_line(language: str, line: str) -> tuple[str, str] | None:
    if language == "shell":
        for pattern in _SHELL:
            found = pattern.match(line)
            if found:
                return found.group(1), "function"
        return None
    for pattern, kind in _PYTHON if language == "python" else _SCRIPT:
        found = pattern.match(line)
        if found:
            return found.group(1), kind
    return None


def extract(ext: str, text: str) -> list[tuple[str, int, str]]:
    """(name, 1-based line, kind) for each definition in text, by the file's index extension."""
    language = _language(ext)
    if language is None:
        return []
    out: list[tuple[str, int, str]] = []
    for number, line in enumerate(text.splitlines(), 1):
        found = _match_line(language, line)
        if found:
            out.append((found[0], number, found[1]))
    return out


def replace_symbols(
    conn: sqlite3.Connection,
    rows: list[tuple[str, str, int, str]],
    files: set[str],
    scope: str | None,
) -> None:
    """Replace the definitions of the walked files and evict those under scope.

    Mirrors the chunk upsert (wv-31d0d0): files walked are rewritten, files in
    scope that the walk no longer saw are dropped, nothing outside scope moves.
    """
    conn.execute(SCHEMA)
    conn.execute(_INDEX)
    for f in files:
        conn.execute("DELETE FROM code_symbols WHERE file = ?", (f,))
    conn.executemany(
        "INSERT OR IGNORE INTO code_symbols(name, file, line, kind) VALUES (?, ?, ?, ?)", rows
    )
    if scope is None:
        return
    prefix = f"{scope}/" if scope else ""
    stale = [
        r[0] for r in conn.execute("SELECT DISTINCT file FROM code_symbols").fetchall()
        if r[0] not in files and (r[0] == scope or r[0].startswith(prefix))
    ]
    for f in stale:
        conn.execute("DELETE FROM code_symbols WHERE file = ?", (f,))
