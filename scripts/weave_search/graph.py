"""Graph enrichment for weave_search results.

Attaches Weave node context (active nodes touching a file) and quality.db
churn scores to search results. Optional — gracefully no-ops when brain.db
or quality.db are unavailable or lack the expected tables.
"""

from __future__ import annotations

import sqlite3
from dataclasses import dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from weave_search.__main__ import SearchResult


@dataclass
class FileContext:
    """Weave context for a file returned in search results."""

    weave_nodes: list[dict[str, str]] = field(default_factory=list)
    churn: int | None = None
    hotspot: float | None = None


def enrich_results(
    results: list[SearchResult],
    brain_db: str,
    quality_db: str | None = None,
) -> dict[str, FileContext]:
    """Return a FileContext per unique file in results.

    Queries brain.db for active/blocked/todo nodes that touch each file
    (via node_files). Queries quality.db git_stats for churn and hotspot
    scores. Missing tables or DBs produce empty FileContext entries rather
    than raising.
    """
    files = {r.file for r in results}
    ctx: dict[str, FileContext] = {f: FileContext() for f in files}

    if not files:
        return ctx

    _attach_weave_nodes(ctx, brain_db)

    if quality_db and Path(quality_db).exists():
        _attach_quality(ctx, quality_db)

    return ctx


def _attach_weave_nodes(ctx: dict[str, FileContext], brain_db: str) -> None:
    """Populate weave_nodes for each file from brain.db node_files + nodes."""
    if not Path(brain_db).exists():
        return
    try:
        conn = sqlite3.connect(brain_db)
        try:
            placeholders = ",".join("?" * len(ctx))
            rows = conn.execute(
                f"""
                SELECT DISTINCT nf.path, n.id, n.text, n.status
                FROM node_files nf
                JOIN nodes n ON nf.node_id = n.id
                WHERE nf.path IN ({placeholders})
                  AND n.status IN ('active', 'blocked', 'todo')
                ORDER BY nf.path, n.status, n.id
                """,
                list(ctx.keys()),
            ).fetchall()
        finally:
            conn.close()
    except sqlite3.OperationalError:
        return

    for path, node_id, text, status in rows:
        if path in ctx:
            ctx[path].weave_nodes.append({"id": node_id, "text": text, "status": status})


def _attach_quality(ctx: dict[str, FileContext], quality_db: str) -> None:
    """Populate churn and hotspot from quality.db git_stats."""
    try:
        conn = sqlite3.connect(quality_db)
        try:
            placeholders = ",".join("?" * len(ctx))
            rows = conn.execute(
                f"SELECT path, churn, hotspot FROM git_stats WHERE path IN ({placeholders})",
                list(ctx.keys()),
            ).fetchall()
        finally:
            conn.close()
    except sqlite3.OperationalError:
        return

    for path, churn, hotspot in rows:
        if path in ctx:
            ctx[path].churn = churn
            ctx[path].hotspot = hotspot
