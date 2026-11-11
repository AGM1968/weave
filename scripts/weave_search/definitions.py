"""Exact definition lookup ahead of ranked code search (wv-35b5bd).

A query that is one identifier is looked up by name in brain.db's code_symbols
table (built by wv index, weave_indexer/symbols.py) before BM25 or vector
ranking runs: every definition is returned, in file order. A name defined
nowhere says so; ranked results that follow are mentions, never offered as the
definition. An index built before the table existed reports the table as
missing instead of an empty answer.
"""

from __future__ import annotations

import re
import sqlite3
from dataclasses import dataclass, field
from typing import Literal

_IDENTIFIER = re.compile(r"^[A-Za-z_$][A-Za-z0-9_$:.-]*$")

DefinitionStatus = Literal["found", "none", "unavailable", "not_identifier"]


@dataclass
class Definition:
    """One place a name is defined."""

    file: str
    line: int
    kind: str


@dataclass
class DefinitionLookup:
    """The lookup's answer for one query."""

    name: str
    status: DefinitionStatus
    definitions: list[Definition] = field(default_factory=list)

    def to_dict(self) -> dict[str, object]:
        """JSON shape for --json output."""
        return {
            "name": self.name,
            "status": self.status,
            "definitions": [
                {"file": d.file, "line": d.line, "kind": d.kind} for d in self.definitions
            ],
        }


def is_identifier(query: str) -> bool:
    """A single name, not prose: the only queries the exact pass answers."""
    return bool(_IDENTIFIER.match(query.strip()))


def lookup(db_path: str, query: str) -> DefinitionLookup:
    """Every definition of the query's name, or why there is none."""
    name = query.strip()
    if not is_identifier(name):
        return DefinitionLookup(name, "not_identifier")
    try:
        conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    except sqlite3.Error:
        return DefinitionLookup(name, "unavailable")
    try:
        rows = conn.execute(
            "SELECT file, line, kind FROM code_symbols WHERE name = ? ORDER BY file, line",
            (name,),
        ).fetchall()
    except sqlite3.Error:
        return DefinitionLookup(name, "unavailable")
    finally:
        conn.close()
    if not rows:
        return DefinitionLookup(name, "none")
    return DefinitionLookup(name, "found", [Definition(f, ln, k) for f, ln, k in rows])


def format_text(result: DefinitionLookup) -> list[str]:
    """Lines printed ahead of ranked results; empty when the query is not a name."""
    if result.status == "not_identifier":
        return []
    if result.status == "unavailable":
        return [
            f"Definition of {result.name}: unknown, the definition table is not built"
            " (run wv index to build it)",
            "",
        ]
    if result.status == "none":
        return [f"Definition of {result.name}: none found; results below only mention it", ""]
    lines = [f"Definition of {result.name}:"]
    lines += [f"  {d.file}:{d.line}  [{d.kind}]" for d in result.definitions]
    lines.append("")
    return lines
