"""CLI entry point for wv index — chunk code files and store in brain.db.

Usage:
  python -m weave_indexer [path]                 # Index path (default: the repository root)
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
import subprocess
import sys
from pathlib import Path
from typing import Iterator

from weave_indexer import symbols

_DEFAULT_EXTS = frozenset({
    ".py", ".ts", ".tsx", ".js", ".jsx",
    ".sh", ".bash",
    ".go", ".rs", ".c", ".cpp", ".h",
    ".md",
})

_EXCLUDE_DIRS = frozenset({
    ".git", ".weave", "__pycache__", "node_modules",
    ".venv", "venv", "dist", "build", "archive",
})

_DEFAULT_CHUNK_LINES = 50
_DEFAULT_OVERLAP_LINES = 10
_DEFAULT_MODEL = "minishlab/potion-code-16M"


# Interpreter named on an extensionless file's shebang -> the extension it indexes as.
_SHEBANG_EXTS = {"sh": ".sh", "bash": ".sh", "python": ".py", "python3": ".py"}

# A hook's GIT_DIR or GIT_INDEX_FILE would point git at another repository.
_GIT_LOCATION_VARS = ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR")


def _git(args: list[str], cwd: Path) -> str | None:
    """Run git in cwd's own repository; None when git is missing or cwd is outside one."""
    env = {k: v for k, v in os.environ.items() if k not in _GIT_LOCATION_VARS}
    try:
        return subprocess.run(
            ["git", *args], cwd=cwd, env=env, capture_output=True, text=True, check=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError):
        return None


def _is_excluded(part: str) -> bool:
    return part in _EXCLUDE_DIRS or part.startswith("venv")


def _index_ext(path: Path) -> str:
    """The extension a file indexes as: its suffix, else the one its shebang implies."""
    if path.suffix:
        return path.suffix
    try:
        with path.open("rb") as fh:
            first = fh.readline(256).decode("utf-8", errors="replace")
    except OSError:
        return ""
    if not first.startswith("#!"):
        return ""
    words = first[2:].split()
    if words and Path(words[0]).name == "env":
        words = [w for w in words[1:] if not w.startswith("-")]
    return _SHEBANG_EXTS.get(Path(words[0]).name, "") if words else ""


def _candidates(root: Path) -> Iterator[Path]:
    """Files under root that git counts as the project: tracked plus untracked, not ignored.

    Walking the filesystem indexed ignored scratch copies of the repository,
    which outnumbered the real source three to one (wv-cfff36). Outside git,
    every file under root.
    """
    listing = _git(["ls-files", "-z", "--cached", "--others", "--exclude-standard"], root)
    if listing is None:
        # rglob walked past a directory it could not list without a word, so
        # the index was partial and said nothing (wv-c6c7cf). One unreadable
        # directory need not stop the index; it must be named.
        def _unlisted(exc: OSError) -> None:
            print(f"wv index: cannot list {exc.filename}: {exc.strerror or exc}; its files are not indexed",
                  file=sys.stderr)
        for dirpath, dirnames, filenames in os.walk(root, onerror=_unlisted):
            yield from (Path(dirpath) / name for name in dirnames + filenames)
        return
    for rel in sorted(set(listing.split("\0")) - {""}):
        yield root / rel


def _walk_files(root: Path, exts: frozenset[str], base: Path | None = None) -> Iterator[Path]:
    """Yield indexable files under root.

    Exclusions match path parts relative to `base` (default: root), never the
    absolute path: a checkout under build/ or venv*/ indexed nothing (wv-31d0d0).
    """
    base = base or root
    for p in _candidates(root):
        if p.is_file() and _index_ext(p) in exts:
            if not any(_is_excluded(part) for part in p.relative_to(base).parts):
                yield p


def _resolve_scope(path: str | None) -> tuple[Path, Path]:
    """Return (root, base): the directory to walk, and the one paths are stored against.

    base is the git toplevel containing root, so a chunk's file is repo-relative
    whichever directory was indexed. Without a path, root is that toplevel of
    the cwd: the old default, WV_HOT_ZONE, is always set by wv and indexed tmpfs
    (wv-31d0d0). Outside git, root and base are the given directory.
    """
    start = Path(path or ".").resolve()
    probe = start if start.is_dir() else start.parent
    top = (_git(["rev-parse", "--show-toplevel"], probe) or "").strip()
    base = Path(top).resolve() if top else start
    return (start if path else base), base


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
    scope: str | None = None,
) -> int:
    """Clear existing chunks for each file, insert new ones, evict stale files in scope.

    `scope` is the walked directory relative to the stored paths' base ("" for
    all of it). Only files inside it are evicted: evicting everything not in
    this walk deleted the whole index whenever a subdirectory was indexed
    (wv-31d0d0). None evicts nothing. Returns the number of stale files evicted.
    """
    conn = sqlite3.connect(db_path)
    evicted = 0
    try:
        files = {c[0] for c in chunks}
        for f in files:
            conn.execute("DELETE FROM chunks WHERE file = ?", (f,))
        conn.executemany(
            "INSERT INTO chunks(file, line_start, line_end, content, embedding)"
            " VALUES (?, ?, ?, ?, ?)",
            [(c[0], c[1], c[2], c[3], blobs[i]) for i, c in enumerate(chunks)],
        )
        # Evict chunks not in this walk: covers deleted files, excluded dirs, and ext changes.
        if scope is not None:
            walked = {c[0] for c in chunks}
            prefix = f"{scope}/" if scope else ""
            rows = conn.execute("SELECT DISTINCT file FROM chunks").fetchall()
            stale = [
                r[0] for r in rows
                if r[0] not in walked and (r[0] == scope or r[0].startswith(prefix))
            ]
            for f in stale:
                conn.execute("DELETE FROM chunks WHERE file = ?", (f,))
            evicted = len(stale)
        conn.commit()
    finally:
        conn.close()
    return evicted


def _file_symbols(path: Path, rel: str) -> list[tuple[str, str, int, str]]:
    """(name, file, line, kind) rows for the definitions in one walked file."""
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return []
    return [(name, rel, line, kind) for name, line, kind in symbols.extract(_index_ext(path), text)]


def _write_symbols(
    db_path: str, rows: list[tuple[str, str, int, str]], walked: set[str], scope: str
) -> None:
    """Rewrite the definition table for this walk (wv-35b5bd), in one transaction."""
    conn = sqlite3.connect(db_path)
    try:
        symbols.replace_symbols(conn, rows, walked, scope)
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

    root, base = _resolve_scope(args.path)
    scope = "" if root == base else root.relative_to(base).as_posix()
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
    walked: set[str] = set()
    defs: list[tuple[str, str, int, str]] = []
    for fpath in _walk_files(root, exts, base):
        rel = fpath.relative_to(base).as_posix()
        walked.add(rel)
        for ls, le, content in _chunk_file(fpath, args.chunk_size, args.overlap):
            all_chunks.append((rel, ls, le, content))
        defs.extend(_file_symbols(fpath, rel))
    _write_symbols(db_path, defs, walked, scope)

    if not all_chunks:
        # An empty walk still proves its subtree holds nothing: evict it.
        evicted = _upsert_chunks(db_path, [], [], scope=scope)
        msg = {"files": 0, "chunks": 0, "embedded": False, "evicted": evicted}
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

    evicted = _upsert_chunks(db_path, all_chunks, blobs, scope=scope)

    file_count = len({c[0] for c in all_chunks})
    msg = {"files": file_count, "chunks": len(all_chunks), "embedded": embedded, "evicted": evicted}

    if args.json_out:
        print(json.dumps(msg))
    else:
        embed_note = "with embeddings" if embedded else "no embeddings (model unavailable)"
        evict_note = f", evicted {evicted} stale file(s)" if evicted else ""
        print(f"Indexed {file_count} file(s), {len(all_chunks)} chunk(s) — {embed_note}{evict_note}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
