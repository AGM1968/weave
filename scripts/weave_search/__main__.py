"""CLI entry point for wv search --code — hybrid code search over brain.db chunks.

Usage:
  python -m weave_search "query"                      # hybrid (FTS BM25 + cosine RRF)
  python -m weave_search "query" --mode=fts           # BM25 only
  python -m weave_search "query" --mode=vector        # cosine only
  python -m weave_search "query" --json               # JSON output
  python -m weave_search "query" --limit=20           # more results
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import sys
from dataclasses import dataclass
from pathlib import Path

_DEFAULT_MODEL = "minishlab/potion-code-16M"
_FTS_SPECIAL = re.compile(r'[()"\^*~:\-]')
_STOPWORDS = frozenset({
    "the", "and", "for", "not", "with", "this", "that", "from", "have",
    "are", "was", "but", "its", "into", "also", "when", "then",
})


@dataclass
class SearchResult:
    """One chunk returned by a search mode with its location and relevance score."""

    chunk_id: int
    file: str
    line_start: int
    line_end: int
    content: str
    score: float
    source: str

    @property
    def snippet(self) -> str:
        """First 200 chars of content with newlines collapsed."""
        return self.content[:200].replace("\n", " ")


VectorRow = tuple[int, str, int, int, str, bytes]


@dataclass
class ReadinessSignal:
    """Actionable readiness state for one code-search prerequisite."""

    ready: bool
    status: str
    detail: str
    hint: str | None = None
    count: int | None = None
    path: str | None = None

    def to_dict(self) -> dict[str, object]:
        """Serialize the signal for JSON output."""
        payload: dict[str, object] = {
            "ready": self.ready,
            "status": self.status,
            "detail": self.detail,
        }
        if self.hint is not None:
            payload["hint"] = self.hint
        if self.count is not None:
            payload["count"] = self.count
        if self.path is not None:
            payload["path"] = self.path
        return payload


@dataclass
class FilterResolution:
    """Resolved graph filter scope used to constrain code-search candidates."""

    expr: str
    node_ids: list[str]
    files: list[str]

    def to_dict(self) -> dict[str, object]:
        """Serialize filter diagnostics for JSON output."""
        return {
            "expr": self.expr,
            "matched_nodes": len(self.node_ids),
            "matched_files": len(self.files),
        }


def _normalize_repo_path(path: str) -> str:
    """Canonicalize repository-relative paths for chunks.file/node_files.path joins."""
    normalized = path.strip().replace("\\", "/")
    while normalized.startswith("./"):
        normalized = normalized[2:]
    if normalized.startswith("/"):
        normalized = normalized[1:]
    return normalized


def resolve_filter_scope(filter_expr: str, db_path: str) -> FilterResolution:
    """Resolve supported graph filter expressions into node IDs and node_files allowlist."""
    if not filter_expr:
        raise ValueError("empty filter expression")

    expr = filter_expr.strip()
    op = "exists"
    edge_type = ""
    if expr.startswith("edge-type!="):
        op = "not-exists"
        edge_type = expr[len("edge-type!="):].strip()
    elif expr.startswith("edge-type="):
        op = "exists"
        edge_type = expr[len("edge-type="):].strip()
    else:
        raise ValueError(
            f"unsupported filter '{filter_expr}'. Supported: edge-type=<type>, edge-type!=<type>"
        )

    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", edge_type):
        raise ValueError(f"invalid edge type in filter: {edge_type}")

    conn = sqlite3.connect(db_path)
    try:
        if op == "exists":
            node_rows = conn.execute(
                """
                SELECT n.id
                FROM nodes n
                WHERE EXISTS (
                    SELECT 1
                    FROM edges e
                    WHERE (e.source = n.id OR e.target = n.id) AND e.type = ?
                )
                """,
                (edge_type,),
            ).fetchall()
        else:
            node_rows = conn.execute(
                """
                SELECT n.id
                FROM nodes n
                WHERE NOT EXISTS (
                    SELECT 1
                    FROM edges e
                    WHERE (e.source = n.id OR e.target = n.id) AND e.type = ?
                )
                """,
                (edge_type,),
            ).fetchall()
    except sqlite3.OperationalError as exc:
        raise ValueError(
            "graph tables unavailable in current DB; ensure nodes/edges/node_files are present"
        ) from exc
    finally:
        conn.close()

    node_ids = [str(row[0]) for row in node_rows if row and row[0]]
    if not node_ids:
        return FilterResolution(expr=expr, node_ids=[], files=[])

    conn = sqlite3.connect(db_path)
    try:
        placeholders = ",".join("?" for _ in node_ids)
        file_rows = conn.execute(
            f"""
            SELECT DISTINCT path
            FROM node_files
            WHERE node_id IN ({placeholders})
              AND path IS NOT NULL
              AND path != ''
            """,
            tuple(node_ids),
        ).fetchall()
    except sqlite3.OperationalError as exc:
        raise ValueError(
            "node_files table unavailable in current DB; cannot build file allowlist"
        ) from exc
    finally:
        conn.close()

    files = sorted({_normalize_repo_path(str(row[0])) for row in file_rows if row and row[0]})
    return FilterResolution(expr=expr, node_ids=node_ids, files=files)


def _safe_scalar(conn: sqlite3.Connection, query: str) -> int | None:
    """Execute a scalar query and return the first column, or None on schema/runtime errors."""
    try:
        row = conn.execute(query).fetchone()
    except sqlite3.OperationalError:
        return None
    if not row:
        return None
    value = row[0]
    if value is None:
        return None
    return int(value)


def collect_readiness(db_path: str, quality_db: str | None = None) -> dict[str, ReadinessSignal]:
    """Inspect search prerequisites and return actionable readiness diagnostics."""
    readiness: dict[str, ReadinessSignal] = {}

    if not Path(db_path).exists():
        missing = ReadinessSignal(
            ready=False,
            status="missing",
            detail="brain.db not found",
            hint="Run `wv index .` from the repo root to build code-search chunks. Example: `wv index . --json`.",
            path=db_path,
        )
        readiness["chunks"] = missing
        readiness["node_files"] = ReadinessSignal(
            ready=False,
            status="missing",
            detail="brain.db not found, so node_files cannot be inspected",
            hint=(
                "After indexing, attribute files through the touched-files hook or run "
                "`wv touch <id> --files=src/file.py`."
            ),
            path=db_path,
        )
    else:
        conn = sqlite3.connect(db_path)
        try:
            chunk_count = _safe_scalar(conn, "SELECT COUNT(*) FROM chunks;")
            if chunk_count is None:
                readiness["chunks"] = ReadinessSignal(
                    ready=False,
                    status="missing",
                    detail="chunks table is missing from brain.db",
                    hint="Run `wv index .` to create and populate code-search chunks. Example: `wv index . --json`.",
                    path=db_path,
                )
            elif chunk_count == 0:
                readiness["chunks"] = ReadinessSignal(
                    ready=False,
                    status="empty",
                    detail="chunks table exists but has no indexed code",
                    hint="Run `wv index .` to populate code-search chunks. Example: `wv index . --json`.",
                    count=0,
                    path=db_path,
                )
            else:
                readiness["chunks"] = ReadinessSignal(
                    ready=True,
                    status="ready",
                    detail=f"{chunk_count} indexed chunk(s) available",
                    count=chunk_count,
                    path=db_path,
                )

            node_file_count = _safe_scalar(conn, "SELECT COUNT(*) FROM node_files;")
            if node_file_count is None:
                readiness["node_files"] = ReadinessSignal(
                    ready=False,
                    status="missing",
                    detail="node_files table is missing from brain.db",
                    hint=(
                        "Populate file attribution through touched-files hooks or run "
                        "`wv touch <id> --files=src/file.py` so --graph can attach Weave nodes."
                    ),
                    path=db_path,
                )
            elif node_file_count == 0:
                readiness["node_files"] = ReadinessSignal(
                    ready=False,
                    status="empty",
                    detail="node_files has no tracked file attributions",
                    hint=(
                        "Run edits through the touched-files hook or `wv touch <id> --files=src/file.py` "
                        "so --graph can attach Weave nodes."
                    ),
                    count=0,
                    path=db_path,
                )
            else:
                readiness["node_files"] = ReadinessSignal(
                    ready=True,
                    status="ready",
                    detail=f"{node_file_count} tracked file attribution(s) available",
                    count=node_file_count,
                    path=db_path,
                )
        finally:
            conn.close()

    quality_path = quality_db
    if not quality_path:
        readiness["quality_db"] = ReadinessSignal(
            ready=False,
            status="missing",
            detail="quality.db path not configured",
            hint="Run `wv quality scan .` for --graph context. Example: `wv quality scan . --json`.",
        )
        return readiness

    quality_file = Path(quality_path)
    if not quality_file.exists():
        readiness["quality_db"] = ReadinessSignal(
            ready=False,
            status="missing",
            detail="quality.db not found",
            hint="Run `wv quality scan .` for --graph context. Example: `wv quality scan . --json`.",
            path=quality_path,
        )
        return readiness

    conn = sqlite3.connect(quality_path)
    try:
        git_stats_count = _safe_scalar(conn, "SELECT COUNT(*) FROM git_stats;")
    finally:
        conn.close()

    if git_stats_count is None:
        readiness["quality_db"] = ReadinessSignal(
            ready=False,
            status="missing",
            detail="quality.db exists but git_stats is unavailable",
            hint="Run `wv quality scan .` for --graph context. Example: `wv quality scan . --json`.",
            path=quality_path,
        )
    elif git_stats_count == 0:
        readiness["quality_db"] = ReadinessSignal(
            ready=False,
            status="empty",
            detail="quality.db exists but has no git_stats rows",
            hint="Run `wv quality scan .` for --graph context. Example: `wv quality scan . --json`.",
            count=0,
            path=quality_path,
        )
    else:
        readiness["quality_db"] = ReadinessSignal(
            ready=True,
            status="ready",
            detail=f"{git_stats_count} git_stats row(s) available",
            count=git_stats_count,
            path=quality_path,
        )

    return readiness


def _print_readiness(readiness: dict[str, ReadinessSignal]) -> None:
    """Emit a concise readiness summary for text-mode callers."""
    print("Search readiness:")
    for key in ("chunks", "node_files", "quality_db"):
        signal = readiness[key]
        status = "ready" if signal.ready else signal.status
        print(f"  {key}: {status} — {signal.detail}")
        if signal.hint:
            print(f"    next: {signal.hint}")
    print()


def _build_fts_expr(query: str) -> str:
    """Build FTS5 MATCH expression: single token = phrase, multi = OR of quoted tokens."""
    clean = _FTS_SPECIAL.sub(" ", query)
    tokens = [t for t in clean.split() if len(t) > 2 and t.lower() not in _STOPWORDS]
    if not tokens:
        tokens = clean.split()[:3]
    if not tokens:
        return '""'
    if len(tokens) == 1:
        return f'"{tokens[0]}"'
    return " OR ".join(f'"{t}"' for t in tokens[:12])


def fts_search(
    query: str,
    db_path: str,
    limit: int = 10,
    allowed_files: set[str] | None = None,
) -> list[SearchResult]:
    """BM25 full-text search over chunks_fts. Returns results sorted best-first."""
    if not Path(db_path).exists():
        return []
    if allowed_files is not None and len(allowed_files) == 0:
        return []
    fts_expr = _build_fts_expr(query)
    conn = sqlite3.connect(db_path)
    try:
        if allowed_files:
            file_list = sorted(allowed_files)
            placeholders = ",".join("?" for _ in file_list)
            rows = conn.execute(
                f"""
                SELECT c.id, c.file, c.line_start, c.line_end, c.content,
                       bm25(chunks_fts) AS rank
                FROM chunks_fts f
                JOIN chunks c ON f.rowid = c.id
                WHERE chunks_fts MATCH ?
                  AND c.file IN ({placeholders})
                ORDER BY rank
                LIMIT ?
                """,
                (fts_expr, *file_list, limit),
            ).fetchall()
        else:
            rows = conn.execute(
                """
                SELECT c.id, c.file, c.line_start, c.line_end, c.content,
                       bm25(chunks_fts) AS rank
                FROM chunks_fts f
                JOIN chunks c ON f.rowid = c.id
                WHERE chunks_fts MATCH ?
                ORDER BY rank
                LIMIT ?
                """,
                (fts_expr, limit),
            ).fetchall()
    except sqlite3.OperationalError:
        return []
    finally:
        conn.close()
    # bm25() returns negative values — negate so higher=better
    return [
        SearchResult(r[0], r[1], r[2], r[3], r[4], -r[5], "fts")
        for r in rows
    ]


def _load_vector_rows(db_path: str) -> list[VectorRow]:
    """Return chunks with embeddings, or [] when the schema is missing vector prerequisites."""
    conn = sqlite3.connect(db_path)
    try:
        try:
            rows = conn.execute(
                "SELECT id, file, line_start, line_end, content, embedding"
                " FROM chunks WHERE embedding IS NOT NULL"
            ).fetchall()
        except sqlite3.OperationalError:
            return []
    finally:
        conn.close()

    typed_rows: list[VectorRow] = []
    for row in rows:
        if len(row) != 6:
            continue
        chunk_id, file_path, line_start, line_end, content, embedding = row
        if not isinstance(chunk_id, int):
            continue
        if not isinstance(file_path, str):
            continue
        if not isinstance(line_start, int):
            continue
        if not isinstance(line_end, int):
            continue
        if not isinstance(content, str):
            continue
        if not isinstance(embedding, bytes):
            continue
        typed_rows.append((chunk_id, file_path, line_start, line_end, content, embedding))

    return typed_rows


def vector_search(
    query: str,
    db_path: str,
    limit: int = 10,
    model_name: str = _DEFAULT_MODEL,
    allowed_files: set[str] | None = None,
) -> list[SearchResult]:
    """Cosine similarity search over stored chunk embeddings."""
    if not Path(db_path).exists():
        return []
    if allowed_files is not None and len(allowed_files) == 0:
        return []

    rows = _load_vector_rows(db_path)
    if not rows:
        return []
    if allowed_files:
        rows = [row for row in rows if _normalize_repo_path(row[1]) in allowed_files]
        if not rows:
            return []

    try:
        import numpy as np  # noqa: PLC0415  # pylint: disable=import-outside-toplevel
        from model2vec import StaticModel  # noqa: PLC0415  # pylint: disable=import-outside-toplevel
        model = StaticModel.from_pretrained(model_name)
        q_vec = model.encode([query])[0].astype(np.float32)
    except Exception:  # noqa: BLE001  # pylint: disable=broad-exception-caught
        return []

    dim = len(q_vec)
    q_norm = float(np.linalg.norm(q_vec))
    if q_norm == 0:
        return []

    valid = [r for r in rows if len(r[5]) // 4 == dim]
    if not valid:
        return []

    matrix = np.stack([np.frombuffer(r[5], dtype=np.float32) for r in valid])  # (N, dim)
    e_norms = np.linalg.norm(matrix, axis=1)  # (N,)
    nonzero = e_norms > 0
    if not np.any(nonzero):
        return []

    valid_rows = [r for r, ok in zip(valid, nonzero) if ok]
    scores = (matrix[nonzero] @ q_vec) / (e_norms[nonzero] * q_norm)  # (M,)

    k = min(limit, len(valid_rows))
    if k == 0:
        return []
    if k < len(valid_rows):
        top = np.argpartition(scores, -k)[-k:]
        order = top[np.argsort(scores[top])[::-1]]
    else:
        order = np.argsort(scores)[::-1]

    return [
        SearchResult(
            valid_rows[i][0], valid_rows[i][1], valid_rows[i][2],
            valid_rows[i][3], valid_rows[i][4], float(scores[i]), "vector",
        )
        for i in order
    ]


def hybrid_search(
    query: str,
    db_path: str,
    limit: int = 10,
    model_name: str = _DEFAULT_MODEL,
    rrf_k: int = 60,
    allowed_files: set[str] | None = None,
) -> list[SearchResult]:
    """RRF blend of FTS BM25 and cosine similarity — best of both retrieval modes."""
    fetch = limit * 3
    fts = fts_search(query, db_path, limit=fetch, allowed_files=allowed_files)
    vec = vector_search(
        query, db_path, limit=fetch, model_name=model_name, allowed_files=allowed_files
    )

    fts_rank = {r.chunk_id: i + 1 for i, r in enumerate(fts)}
    vec_rank = {r.chunk_id: i + 1 for i, r in enumerate(vec)}

    all_chunks: dict[int, SearchResult] = {}
    for r in fts:
        all_chunks[r.chunk_id] = r
    for r in vec:
        if r.chunk_id not in all_chunks:
            all_chunks[r.chunk_id] = r

    rrf_scores: dict[int, float] = {}
    for cid in all_chunks:
        score = 0.0
        if cid in fts_rank:
            score += 1.0 / (rrf_k + fts_rank[cid])
        if cid in vec_rank:
            score += 1.0 / (rrf_k + vec_rank[cid])
        rrf_scores[cid] = score

    top_ids = sorted(rrf_scores, key=lambda cid: rrf_scores[cid], reverse=True)[:limit]
    return [
        SearchResult(
            cid,
            all_chunks[cid].file,
            all_chunks[cid].line_start,
            all_chunks[cid].line_end,
            all_chunks[cid].content,
            rrf_scores[cid],
            "hybrid",
        )
        for cid in top_ids
    ]


def main(argv: list[str] | None = None) -> int:
    """Parse args and run the requested search mode."""
    parser = argparse.ArgumentParser(prog="wv search --code")
    parser.add_argument("query", help="Natural-language or code query")
    parser.add_argument("--db", default=None, help="brain.db path (default: $WV_DB)")
    parser.add_argument("--limit", type=int, default=10)
    parser.add_argument("--mode", choices=["hybrid", "fts", "vector"], default="hybrid")
    parser.add_argument("--model", default=_DEFAULT_MODEL)
    parser.add_argument(
        "--filter",
        default=None,
        help="Graph filter expression for candidate scoping (e.g. edge-type=blocks)",
    )
    parser.add_argument("--graph", action="store_true",
                        help="Attach Weave node context and quality churn to results")
    parser.add_argument("--quality-db", default=None,
                        help="quality.db path for churn scores (default: $WV_HOT_ZONE/quality.db)")
    parser.add_argument("--json", action="store_true", dest="json_out")
    args = parser.parse_args(argv)

    db_path = args.db or os.environ.get("WV_DB")
    if not db_path or not Path(db_path).exists():
        print("error: brain.db not found (set WV_DB or pass --db)", file=sys.stderr)
        return 1

    allowed_files: set[str] | None = None
    filter_resolution: FilterResolution | None = None
    if args.filter:
        try:
            # Phase 1 for --filter: parse + resolve to node/file scope.
            # Candidate enforcement is applied to all retrieval modes.
            filter_resolution = resolve_filter_scope(args.filter, db_path)
            allowed_files = set(filter_resolution.files)
        except ValueError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 1

    if args.mode == "fts":
        results = fts_search(args.query, db_path, args.limit, allowed_files=allowed_files)
    elif args.mode == "vector":
        results = vector_search(
            args.query, db_path, args.limit, args.model, allowed_files=allowed_files
        )
    else:
        results = hybrid_search(
            args.query, db_path, args.limit, args.model, allowed_files=allowed_files
        )

    hot_zone = os.environ.get("WV_HOT_ZONE", "")
    quality_db = args.quality_db or (f"{hot_zone}/quality.db" if hot_zone else None)
    readiness = collect_readiness(db_path, quality_db)

    graph_ctx = {}
    if args.graph and results:
        from weave_search.graph import enrich_results  # noqa: PLC0415  # pylint: disable=import-outside-toplevel
        graph_ctx = enrich_results(results, db_path, quality_db)

    if args.json_out:
        out = []
        for r in results:
            entry: dict[str, object] = {
                "file": r.file,
                "line_start": r.line_start,
                "line_end": r.line_end,
                "score": r.score,
                "snippet": r.snippet,
                "source": r.source,
            }
            if graph_ctx:
                fc = graph_ctx.get(r.file)
                entry["weave_nodes"] = fc.weave_nodes if fc else []
                entry["churn"] = fc.churn if fc else None
                entry["hotspot"] = fc.hotspot if fc else None
            out.append(entry)
        print(json.dumps({
            "results": out,
            **({"filter": filter_resolution.to_dict()} if filter_resolution else {}),
            "readiness": {key: signal.to_dict() for key, signal in readiness.items()},
        }))
        return 0

    if not results:
        if filter_resolution and not filter_resolution.files:
            print(
                "No code matches found: filter resolved to 0 allowlisted files "
                f"({filter_resolution.expr})"
            )
        else:
            print(f"No code matches found for: {args.query}")
        if filter_resolution:
            print(
                f"Filter: {filter_resolution.expr}  "
                f"[nodes={len(filter_resolution.node_ids)} files={len(filter_resolution.files)}]"
            )
        _print_readiness(readiness)
        return 0

    print(f"Code search: {args.query}  [{args.mode}]")
    print()
    if filter_resolution:
        print(
            f"Filter: {filter_resolution.expr}  "
            f"[nodes={len(filter_resolution.node_ids)} files={len(filter_resolution.files)}]"
        )
        print()
    if args.graph or any(not signal.ready for signal in readiness.values()):
        _print_readiness(readiness)
    for i, r in enumerate(results, 1):
        print(f"  {i:2}. {r.file}:{r.line_start}-{r.line_end}  [score={r.score:.4f}]")
        print(f"      {r.snippet[:120]}")
        if graph_ctx:
            fc = graph_ctx.get(r.file)
            if fc and fc.weave_nodes:
                node_summary = ", ".join(
                    f"{n['id']}({n['status']})" for n in fc.weave_nodes[:3]
                )
                print(f"      nodes: {node_summary}")
            if fc and fc.churn is not None:
                print(f"      churn: {fc.churn}  hotspot: {fc.hotspot:.3f}" if fc.hotspot else
                      f"      churn: {fc.churn}")
        print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
