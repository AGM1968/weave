#!/usr/bin/env python3
"""Migrate existing learnings: parse inline markers into top-level metadata keys.

Parses the pipe-delimited learning field (e.g. "decision: X | pattern: Y | pitfall: Z")
into top-level metadata keys {decision, pattern, pitfall}. The raw learning string is
preserved for backward compatibility.

Usage:
    python3 scripts/migrate-learnings.py [--dry-run] [--verbose]
"""

import json
import os
import re
import sqlite3
import sys

JUNK_PATTERNS = [
    re.compile(r"^closed via (gh|github) issue", re.I),
    re.compile(r"^knowledge captured", re.I),
    re.compile(r"^trivial fix$", re.I),
]

MARKER_RE = re.compile(r"^(decision|pattern|pitfall):\s*(.+)", re.I)


def parse_learning(text: str) -> dict:
    """Parse inline markers from learning text into structured dict."""
    parts: dict[str, str] = {}
    if not text:
        return parts

    # Normalize semicolons before marker keywords to pipes
    normalized = re.sub(r";\s*(decision|pattern|pitfall):", r" | \1:", text, flags=re.I)
    segments = re.split(r"\s*\|\s*", normalized)
    last_key = None

    for seg in segments:
        seg = seg.strip()
        if not seg:
            continue
        m = MARKER_RE.match(seg)
        if m:
            key = m.group(1).lower()
            parts[key] = m.group(2).strip()
            last_key = key
        elif last_key and last_key in parts:
            parts[last_key] += " | " + seg
    return parts


def is_junk(text: str) -> bool:
    """Check if learning text is a known junk/template pattern."""
    return any(p.match(text) for p in JUNK_PATTERNS)


def main():
    dry_run = "--dry-run" in sys.argv
    verbose = "--verbose" in sys.argv

    db_path = os.environ.get("WV_DB")
    if not db_path:
        hot_zone = os.environ.get("WV_HOT_ZONE", "/dev/shm/weave")
        # Find the DB with the most nodes (the active project DB)
        if os.path.isdir(hot_zone):
            best_path = None
            best_count = 0
            for d in os.listdir(hot_zone):
                candidate = os.path.join(hot_zone, d, "brain.db")
                if os.path.exists(candidate):
                    try:
                        c = sqlite3.connect(candidate)
                        count = c.execute("SELECT COUNT(*) FROM nodes").fetchone()[0]
                        c.close()
                        if count > best_count:
                            best_count = count
                            best_path = candidate
                    except Exception:
                        pass
            db_path = best_path
    if not db_path or not os.path.exists(db_path):
        print("Error: cannot find brain.db. Set WV_DB or ensure hot zone is active.", file=sys.stderr)
        sys.exit(1)

    print(f"Database: {db_path}")
    if dry_run:
        print("DRY RUN — no changes will be written\n")

    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row

    rows = conn.execute(
        "SELECT id, metadata FROM nodes WHERE status = 'done'"
    ).fetchall()

    stats = {
        "total": len(rows),
        "migrated": 0,
        "already_has_keys": 0,
        "junk_marked": 0,
        "unstructured": 0,
        "no_learning": 0,
    }

    for row in rows:
        nid = row["id"]
        raw_meta = row["metadata"] or "{}"
        try:
            meta = json.loads(raw_meta)
        except (json.JSONDecodeError, TypeError):
            meta = {}

        learning = meta.get("learning", "")
        has_top_keys = any(meta.get(k) for k in ("decision", "pattern", "pitfall"))

        if has_top_keys:
            stats["already_has_keys"] += 1
            continue

        if not learning:
            stats["no_learning"] += 1
            continue

        # Mark junk learnings
        if is_junk(learning):
            if meta.get("learning_hygiene") != 0:
                meta["learning_hygiene"] = 0
                stats["junk_marked"] += 1
                if verbose:
                    print(f"  JUNK {nid}: {learning[:60]}")
                if not dry_run:
                    conn.execute(
                        "UPDATE nodes SET metadata = ? WHERE id = ?",
                        (json.dumps(meta, ensure_ascii=False), nid),
                    )
            continue

        # Parse inline markers
        parsed = parse_learning(learning)
        if not parsed:
            stats["unstructured"] += 1
            continue

        # Merge parsed keys into metadata
        changed = False
        for key in ("decision", "pattern", "pitfall"):
            if key in parsed and not meta.get(key):
                meta[key] = parsed[key]
                changed = True

        if changed:
            stats["migrated"] += 1
            if verbose:
                print(f"  MIGRATE {nid}:")
                for k in ("decision", "pattern", "pitfall"):
                    if k in parsed:
                        print(f"    {k}: {parsed[k][:80]}")
            if not dry_run:
                conn.execute(
                    "UPDATE nodes SET metadata = ? WHERE id = ?",
                    (json.dumps(meta, ensure_ascii=False), nid),
                )
        else:
            stats["unstructured"] += 1

    if not dry_run:
        conn.commit()
    conn.close()

    print("\nResults:")
    print(f"  Total done nodes:    {stats['total']}")
    print(f"  Migrated:            {stats['migrated']}")
    print(f"  Already had keys:    {stats['already_has_keys']}")
    print(f"  Junk marked (→ 0):   {stats['junk_marked']}")
    print(f"  Unstructured (skip): {stats['unstructured']}")
    print(f"  No learning:         {stats['no_learning']}")

    if dry_run:
        print("\nRe-run without --dry-run to apply changes.")


if __name__ == "__main__":
    main()
