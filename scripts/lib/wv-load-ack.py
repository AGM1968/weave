#!/usr/bin/env python3
"""Load acknowledgement (Stage B prerequisite 1, wv-4e35c0).

A load is an attempt with a terminal state (wv-25e832 lesson 1): cmd_load
marks it begun once the new database is installed, then either complete or
failed. An acknowledgement is
written only on complete, that is when v2 had no hard disposition, v1 skipped
no corrupt file and rolled nothing back, delta classification succeeded, and
the catalog was the same after the load as before it.

The acknowledgement names what was absorbed as a checkpoint, not a commit: the
git tree id of the load's inputs, state.sql plus every file under deltas/, laid
out relative to the .weave directory. A clean tree's checkpoint is therefore
what a peer computes from the same commit, and a dirty tree still has one.
Blob ids come from the git index for files that match it and are hashed only
for modified or untracked files; outside a git repository every file is
hashed. The tree id is computed here, so nothing is written to .git.

The tables live in the local database only: dump_state_sql exports
WV_DURABLE_TABLES, so a checkpoint never travels in state.sql. Publication per
clone is prerequisite 4's (wv-6e44d9).

Usage:
  wv-load-ack.py digest WEAVE_DIR             print a digest of the catalog
  wv-load-ack.py begin DB                     mark the attempt begun, drop any ack
  wv-load-ack.py finish DB WEAVE_DIR DIGEST [REASON...]
                                              complete (exit 0, prints the
                                              checkpoint) or failed (exit 3)
  wv-load-ack.py show DB                      print the checkpoint, exit 1 if none
  wv-load-ack.py checkpoint WEAVE_DIR         print the checkpoint of the tree now
"""
from __future__ import annotations

import hashlib
import os
import sqlite3
import subprocess
import sys
from datetime import datetime, timezone

SCHEMA = """
CREATE TABLE IF NOT EXISTS _weave_load_attempt (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    state TEXT NOT NULL CHECK (state IN ('begun', 'complete', 'failed')),
    reasons TEXT NOT NULL DEFAULT '',
    at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS _weave_load_ack (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    checkpoint TEXT NOT NULL,
    files INTEGER NOT NULL,
    at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS _weave_load_ack_files (
    path TEXT PRIMARY KEY,
    blob TEXT NOT NULL
) WITHOUT ROWID;
"""


class CatalogError(Exception):
    """The load's inputs could not be listed or hashed consistently."""


# A directory: name to blob id (a file) or to another directory.
Tree = dict[str, "Tree | str"]


def _git(top: str, *args: str, stdin: bytes | None = None) -> bytes:
    # check=False: a failure is turned into CatalogError with git's message.
    proc = subprocess.run(["git", "-C", top, *args], input=stdin, check=False,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if proc.returncode != 0:
        raise CatalogError(f"git {args[0]}: {proc.stderr.decode(errors='replace').strip()}")
    return proc.stdout


def _git_top(weave_dir: str) -> str | None:
    # check=False: outside a work tree is an answer (None), not an error.
    proc = subprocess.run(["git", "-C", weave_dir, "rev-parse", "--is-inside-work-tree",
                           "--show-toplevel"], check=False,
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    lines = proc.stdout.decode().splitlines()
    if proc.returncode != 0 or len(lines) < 2 or lines[0] != "true":
        return None
    return os.path.realpath(lines[1])


def _walk(weave_dir: str) -> list[str]:
    """Regular files the load reads, relative to weave_dir."""
    out = []
    state = os.path.join(weave_dir, "state.sql")
    if os.path.isfile(state) and not os.path.islink(state):
        out.append("state.sql")

    def scan(full: str, rel: str) -> None:
        try:
            it = os.scandir(full)
        except FileNotFoundError:
            return
        with it:
            for entry in it:
                if entry.is_dir(follow_symlinks=False):
                    scan(entry.path, rel + entry.name + "/")
                elif entry.is_file(follow_symlinks=False):
                    out.append(rel + entry.name)

    scan(os.path.join(weave_dir, "deltas"), "deltas/")
    return out


def _blob_id(path: str, algo: str) -> str:
    with open(path, "rb") as fh:
        data = fh.read()
    h = hashlib.new(algo)
    h.update(b"blob %d\0" % len(data))
    h.update(data)
    return h.hexdigest()


def catalog(weave_dir: str) -> tuple[list[tuple[str, str]], str]:
    """Sorted (path, blob id) for every input of a load, and the hash algorithm."""
    weave_dir = os.path.realpath(weave_dir)
    if not os.path.isdir(weave_dir):
        raise CatalogError(f"no such directory: {weave_dir}")
    present = set(_walk(weave_dir))
    top = _git_top(weave_dir)
    blobs: dict[str, str] = {}
    algo = "sha1"
    if top is not None:
        fmt = _git(top, "rev-parse", "--show-object-format").decode().strip() or "sha1"
        algo = "sha256" if fmt == "sha256" else "sha1"
        rel = os.path.relpath(weave_dir, top)
        prefix = "" if rel == "." else rel + "/"
        specs = ["--", prefix + "state.sql", prefix + "deltas"]
        stale: set[str] = set()
        for rec in _git(top, "ls-files", "-s", "-z", *specs).split(b"\0"):
            if not rec:
                continue
            meta, path = rec.decode().split("\t", 1)
            _mode, oid, stage = meta.split()
            path = path[len(prefix):]
            if stage != "0":
                stale.add(path)
            else:
                blobs[path] = oid
        for cmd in (("diff-files", "--name-only", "-z"), ("ls-files", "-o", "-z")):
            for rec in _git(top, *cmd, *specs).split(b"\0"):
                if rec:
                    stale.add(rec.decode()[len(prefix):])
        stale |= present - blobs.keys()
        todo = sorted(p for p in stale if p in present)
        if todo:
            out = _git(top, "hash-object", "--no-filters", "--stdin-paths",
                       stdin="".join(os.path.join(weave_dir, p) + "\n" for p in todo).encode())
            for path, oid in zip(todo, out.decode().split()):
                blobs[path] = oid
        blobs = {p: o for p, o in blobs.items() if p in present}
    else:
        blobs = {p: _blob_id(os.path.join(weave_dir, p), algo) for p in present}
    if blobs.keys() != present:
        raise CatalogError("catalog changed while it was listed")
    return sorted(blobs.items(), key=lambda kv: kv[0].encode()), algo


def digest(entries: list[tuple[str, str]]) -> str:
    """A sha256 over the sorted (path, blob id) catalog, to compare before and after a load."""
    h = hashlib.sha256()
    for path, oid in entries:
        h.update(f"{oid} {path}\n".encode())
    return h.hexdigest()


def tree_id(entries: list[tuple[str, str]], algo: str) -> str:
    """The git tree id of entries (every file mode 100644), as git write-tree
    would compute it, without writing any object."""
    root: Tree = {}
    for path, oid in entries:
        node = root
        parts = path.split("/")
        for part in parts[:-1]:
            child = node.setdefault(part, {})
            if not isinstance(child, dict):
                raise CatalogError(f"{part} is both a file and a directory")
            node = child
        node[parts[-1]] = oid

    def build(node: Tree) -> str:
        items: list[tuple[bytes, bytes, bytes, bytes]] = []
        for name, val in node.items():
            if isinstance(val, dict):
                items.append((name.encode() + b"/", b"40000", name.encode(), bytes.fromhex(build(val))))
            else:
                items.append((name.encode(), b"100644", name.encode(), bytes.fromhex(val)))
        items.sort(key=lambda it: it[0])
        body = b"".join(mode + b" " + name + b"\0" + raw for _k, mode, name, raw in items)
        h = hashlib.new(algo)
        h.update(b"tree %d\0" % len(body))
        h.update(body)
        return h.hexdigest()

    return build(root)


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _connect(db: str) -> sqlite3.Connection:
    conn = sqlite3.connect(db, timeout=5.0, isolation_level=None)
    conn.executescript(SCHEMA)
    return conn


def _set_attempt(conn: sqlite3.Connection, state: str, reasons: str) -> None:
    conn.execute("INSERT OR REPLACE INTO _weave_load_attempt (id, state, reasons, at) "
                 "VALUES (1, ?, ?, ?)", (state, reasons, _now()))


def cmd_begin(db: str) -> int:
    """Mark the load attempt begun and drop any earlier acknowledgement."""
    conn = _connect(db)
    conn.execute("BEGIN IMMEDIATE")
    conn.execute("DELETE FROM _weave_load_ack")
    conn.execute("DELETE FROM _weave_load_ack_files")
    _set_attempt(conn, "begun", "")
    conn.execute("COMMIT")
    return 0


def cmd_finish(db: str, weave_dir: str, before: str, reasons: list[str]) -> int:
    """Complete the attempt and record its checkpoint (0), or mark it failed (3)."""
    reasons = [r for r in reasons if r]
    entries: list[tuple[str, str]] = []
    algo = "sha1"
    if not reasons:
        if not before:
            reasons.append("catalog unreadable before the load")
        else:
            try:
                entries, algo = catalog(weave_dir)
            except (CatalogError, OSError) as exc:
                reasons.append(f"catalog unreadable after the load: {exc}")
            else:
                if digest(entries) != before:
                    reasons.append("catalog changed during the load")
    conn = _connect(db)
    conn.execute("BEGIN IMMEDIATE")
    conn.execute("DELETE FROM _weave_load_ack")
    conn.execute("DELETE FROM _weave_load_ack_files")
    if reasons:
        _set_attempt(conn, "failed", "; ".join(reasons))
        conn.execute("COMMIT")
        print("; ".join(reasons), file=sys.stderr)
        return 3
    checkpoint = tree_id(entries, algo)
    conn.executemany("INSERT INTO _weave_load_ack_files (path, blob) VALUES (?, ?)", entries)
    conn.execute("INSERT INTO _weave_load_ack (id, checkpoint, files, at) VALUES (1, ?, ?, ?)",
                 (checkpoint, len(entries), _now()))
    _set_attempt(conn, "complete", "")
    conn.execute("COMMIT")
    print(checkpoint)
    return 0


def cmd_show(db: str) -> int:
    """Print the checkpoint of a completed load; 1 if there is none."""
    try:
        conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=5.0)
        row = conn.execute(
            "SELECT k.checkpoint FROM _weave_load_ack k JOIN _weave_load_attempt a "
            "ON a.id = 1 AND a.state = 'complete'").fetchone()
    except sqlite3.Error:
        return 1
    if not row:
        return 1
    print(row[0])
    return 0


def main(argv: list[str]) -> int:
    """Dispatch one subcommand; see the module docstring."""
    if not argv:
        print(__doc__, file=sys.stderr)
        return 2
    cmd, args = argv[0], argv[1:]
    try:
        if cmd == "digest" and len(args) == 1:
            print(digest(catalog(args[0])[0]))
            return 0
        if cmd == "checkpoint" and len(args) == 1:
            entries, algo = catalog(args[0])
            print(tree_id(entries, algo))
            return 0
        if cmd == "begin" and len(args) == 1:
            return cmd_begin(args[0])
        if cmd == "finish" and len(args) >= 3:
            return cmd_finish(args[0], args[1], args[2], args[3:])
        if cmd == "show" and len(args) == 1:
            return cmd_show(args[0])
    except (CatalogError, OSError, sqlite3.Error) as exc:
        print(f"wv-load-ack: {exc}", file=sys.stderr)
        return 1
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
