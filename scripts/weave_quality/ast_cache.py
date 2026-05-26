"""Persistent AST analysis result cache keyed by git blob SHA.

Stores per-file analysis results (FileEntry metrics, CKMetrics, FunctionCC list)
in .weave/ast_cache.db — gitignored and NOT wiped by wv quality reset.

Cache key: (blob_sha, scanner_version)
  blob_sha       — git object SHA; changes when file content changes
  scanner_version — invalidates cache when algorithm changes

On a cold full scan, every file is analysed normally and results are written to
cache. On a subsequent full scan (e.g. after wv quality reset) with unchanged
files, results are read from cache — skipping ast.parse() entirely.

Thread safety: ASTCache must only be used from one thread. In cmd_scan,
_scan_files runs on the main thread; background git threads don't touch it.
"""

from __future__ import annotations

import json
import sqlite3
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .models import CKMetrics, FileEntry, FunctionCC


@dataclass
class _CachedEntry:
    entry_fields: dict[str, Any]
    ck_metrics: dict[str, float] | None
    fn_cc_fields: list[dict[str, Any]]


_SCHEMA = """
CREATE TABLE IF NOT EXISTS ast_result_cache (
    blob_sha        TEXT NOT NULL,
    scanner_version TEXT NOT NULL,
    entry_json      TEXT NOT NULL,
    ck_json         TEXT,
    fn_cc_json      TEXT NOT NULL,
    cached_at       INTEGER NOT NULL,
    PRIMARY KEY (blob_sha, scanner_version)
);
"""

_PRUNE_DAYS = 90


class ASTCache:
    """Read-through cache for Python AST analysis results.

    Usage:
        cache = ASTCache.open(repo_root, scanner_version)
        result = cache.get(blob_sha)
        if result is None:
            entry, ck, fn_cc = analyze_python_file(...)
            cache.put(blob_sha, entry, ck, fn_cc)
        cache.close()
    """

    def __init__(self, conn: sqlite3.Connection, scanner_version: str) -> None:
        self._conn = conn
        self._version = scanner_version
        self._hits = 0
        self._misses = 0

    @classmethod
    def open(cls, repo_root: str | Path, scanner_version: str) -> "ASTCache":
        """Open (or create) the cache DB at {repo_root}/.weave/ast_cache.db."""
        db_path = Path(repo_root) / ".weave" / "ast_cache.db"
        db_path.parent.mkdir(parents=True, exist_ok=True)
        conn = sqlite3.connect(str(db_path), timeout=5)
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute(_SCHEMA)
        conn.commit()
        return cls(conn, scanner_version)

    def get(
        self, blob_sha: str, path: str, scan_id: int, category: str
    ) -> tuple[FileEntry, CKMetrics | None, list[FunctionCC]] | None:
        """Return cached result for blob_sha, or None on miss.

        Reconstructs FileEntry/CKMetrics/FunctionCC with the caller-supplied
        path, scan_id, and category (derived at scan time, not stored).
        """
        if not blob_sha:
            return None
        row = self._conn.execute(
            "SELECT entry_json, ck_json, fn_cc_json FROM ast_result_cache"
            " WHERE blob_sha = ? AND scanner_version = ?",
            (blob_sha, self._version),
        ).fetchone()
        if row is None:
            self._misses += 1
            return None

        self._hits += 1
        entry_fields = json.loads(row[0])
        ck_data: dict[str, float] | None = json.loads(row[1]) if row[1] else None
        fn_cc_data: list[dict[str, Any]] = json.loads(row[2])

        entry = FileEntry(
            path=path,
            scan_id=scan_id,
            language="python",
            category=category,
            **entry_fields,
        )
        ck = (
            CKMetrics(path=path, scan_id=scan_id, metrics=ck_data)
            if ck_data is not None
            else None
        )
        fn_cc = [
            FunctionCC(path=path, scan_id=scan_id, **f)
            for f in fn_cc_data
        ]
        return entry, ck, fn_cc

    def put(
        self,
        blob_sha: str,
        entry: FileEntry,
        ck: CKMetrics | None,
        fn_cc: list[FunctionCC],
    ) -> None:
        """Write analysis result to cache (INSERT OR REPLACE)."""
        if not blob_sha:
            return
        entry_fields = {
            "loc": entry.loc,
            "complexity": entry.complexity,
            "functions": entry.functions,
            "max_nesting": entry.max_nesting,
            "avg_fn_len": entry.avg_fn_len,
            "essential_complexity": entry.essential_complexity,
            "indent_sd": entry.indent_sd,
        }
        ck_data = ck.metrics if ck is not None else None
        fn_cc_data = [
            {
                "function_name": f.function_name,
                "line_start": f.line_start,
                "line_end": f.line_end,
                "complexity": f.complexity,
                "essential_complexity": f.essential_complexity,
                "is_dispatch": f.is_dispatch,
            }
            for f in fn_cc
        ]
        self._conn.execute(
            "INSERT OR REPLACE INTO ast_result_cache"
            " (blob_sha, scanner_version, entry_json, ck_json, fn_cc_json, cached_at)"
            " VALUES (?, ?, ?, ?, ?, ?)",
            (
                blob_sha,
                self._version,
                json.dumps(entry_fields),
                json.dumps(ck_data) if ck_data is not None else None,
                json.dumps(fn_cc_data),
                int(time.time()),
            ),
        )

    def flush(self) -> None:
        """Commit all pending writes."""
        self._conn.commit()

    def prune(self) -> int:
        """Remove cache entries older than _PRUNE_DAYS. Returns rows deleted."""
        cutoff = int(time.time()) - _PRUNE_DAYS * 86400
        cur = self._conn.execute(
            "DELETE FROM ast_result_cache WHERE cached_at < ?", (cutoff,)
        )
        self._conn.commit()
        return cur.rowcount

    def close(self) -> None:
        """Flush and close the cache connection."""
        self._conn.commit()
        self._conn.close()

    @property
    def hits(self) -> int:
        """Cache hits since this instance was created."""
        return self._hits

    @property
    def misses(self) -> int:
        """Cache misses since this instance was created."""
        return self._misses
