"""CLI entry point for wv index — chunk code files and store in brain.db.

Usage:
  python -m weave_indexer [path]                 # Index path (default: WV_HOT_ZONE or .)
  python -m weave_indexer [path] --no-embed      # Skip embedding (FTS-only)
  python -m weave_indexer [path] --ext=.py,.ts   # Restrict file extensions
  python -m weave_indexer [path] --json          # JSON summary output

Embeddings are stored as raw float32 BLOBs (dim * 4 bytes).
Falls back to no-embed mode when model2vec is unavailable.
"""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import struct
import sys
from pathlib import Path
from typing import Iterator

_DEFAULT_EXTS = frozenset({
    ".py", ".ts", ".tsx", ".js", ".jsx",
    ".sh", ".bash",
    ".go", ".rs", ".c", ".cpp", ".h",
    ".md",
})

_EXCLUDE_DIRS = frozenset({".git", ".weave", "__pycache__", "node_modules", ".venv", "venv", "dist", "build"})

_DEFAULT_CHUNK_LINES = 50
_DEFAULT_OVERLAP_LINES = 10
_DEFAULT_MODEL = "minishlab/potion-code-16M"


def _walk_files(root: Path, exts: frozenset[str]) -> Iterator[Path]:
    for p in root.rglob("*"):
        if p.is_file() and p.suffix in exts:
            if not any(part in _EXCLUDE_DIRS for part in p.parts):
                yield p


def _chunk_file(path: Path, chunk_size: int, overlap: int) -> Iterator[tuple[int, int, str]]:
    """Yield (line_start_1based, line_end_1based, content) for each chunk."""
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return
    lines = text.splitlines()
    if not lines:
        return
    step = max(1, chunk_size - overlap)
    start = 0
    while start < len(lines):
        end = min(start + chunk_size, len(lines))
        yield start + 1, end, "\n".join(lines[start:end])
        if end >= len(lines):
            break
        start += step


def _try_encode(texts: list[str], model_name: str) -> list[bytes | None]:
    """Return BLOB bytes per text, or None list on failure."""
    try:
        from model2vec import StaticModel  # noqa: PLC0415  # pylint: disable=import-outside-toplevel
        model = StaticModel.from_pretrained(model_name)
        embeddings = model.encode(texts)  # shape (N, dim), float32
        return [struct.pack(f"{emb.size}f", *emb.flatten().tolist()) for emb in embeddings]
    except Exception:  # noqa: BLE001  # pylint: disable=broad-exception-caught
        return [None] * len(texts)


def _upsert_chunks(
    db_path: str,
    chunks: list[tuple[str, int, int, str]],
    blobs: list[bytes | None],
) -> None:
    """Clear existing chunks for each file, then insert new ones."""
    conn = sqlite3.connect(db_path)
    try:
        files = {c[0] for c in chunks}
        for f in files:
            conn.execute("DELETE FROM chunks WHERE file = ?", (f,))
        conn.executemany(
            "INSERT INTO chunks(file, line_start, line_end, content, embedding)"
            " VALUES (?, ?, ?, ?, ?)",
            [(c[0], c[1], c[2], c[3], blobs[i]) for i, c in enumerate(chunks)],
        )
        conn.commit()
    finally:
        conn.close()


def main(argv: list[str] | None = None) -> int:
    """Parse CLI args, chunk files, embed, and upsert into brain.db."""
    parser = argparse.ArgumentParser(prog="wv index")
    parser.add_argument("path", nargs="?", default=None, help="Root path to index")
    parser.add_argument("--db", default=None, help="brain.db path (default: $WV_DB)")
    parser.add_argument("--ext", default=None, help="Comma-separated extensions, e.g. .py,.ts")
    parser.add_argument("--chunk-size", type=int, default=_DEFAULT_CHUNK_LINES)
    parser.add_argument("--overlap", type=int, default=_DEFAULT_OVERLAP_LINES)
    parser.add_argument("--model", default=_DEFAULT_MODEL, help="Embedding model name")
    parser.add_argument("--no-embed", action="store_true", help="Skip embedding (FTS content only)")
    parser.add_argument("--json", action="store_true", dest="json_out")
    args = parser.parse_args(argv)

    root = Path(args.path or os.environ.get("WV_HOT_ZONE") or ".").resolve()
    db_path = args.db or os.environ.get("WV_DB")
    if not db_path:
        print("error: WV_DB not set and --db not provided", file=sys.stderr)
        return 1
    if not Path(db_path).exists():
        print(f"error: brain.db not found: {db_path}", file=sys.stderr)
        return 1

    exts = frozenset(args.ext.split(",")) if args.ext else _DEFAULT_EXTS

    # Collect and chunk
    all_chunks: list[tuple[str, int, int, str]] = []
    for fpath in _walk_files(root, exts):
        rel = str(fpath.relative_to(root))
        for ls, le, content in _chunk_file(fpath, args.chunk_size, args.overlap):
            all_chunks.append((rel, ls, le, content))

    if not all_chunks:
        msg = {"files": 0, "chunks": 0, "embedded": False}
        if args.json_out:
            print(json.dumps(msg))
        else:
            print("No files to index.")
        return 0

    # Embed
    embedded = False
    if args.no_embed:
        blobs: list[bytes | None] = [None] * len(all_chunks)
    else:
        texts = [c[3] for c in all_chunks]
        blobs = _try_encode(texts, args.model)
        embedded = blobs[0] is not None

    _upsert_chunks(db_path, all_chunks, blobs)

    file_count = len({c[0] for c in all_chunks})
    msg = {"files": file_count, "chunks": len(all_chunks), "embedded": embedded}

    if args.json_out:
        print(json.dumps(msg))
    else:
        embed_note = "with embeddings" if embedded else "no embeddings (model unavailable)"
        print(f"Indexed {file_count} file(s), {len(all_chunks)} chunk(s) — {embed_note}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
