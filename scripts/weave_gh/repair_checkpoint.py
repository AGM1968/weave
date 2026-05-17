"""Resume checkpoint for ``--mode=repair`` (Phase D).

A long repair-grade sync may be interrupted by timeout, Ctrl-C, or a crash.
The checkpoint records which candidate nodes have already been processed so
that a follow-up ``wv sync --gh --mode=repair`` resumes from where it stopped
instead of redoing the entire walk.

State lives at ``<repo_root>/.weave/repair-checkpoint.json`` (gitignored).
On clean completion the file is removed; if it exists at the start of a
repair run, every node whose id is in ``processed`` is skipped.
"""

from __future__ import annotations

import json
import logging
import subprocess
import time
from pathlib import Path
from typing import Any

log = logging.getLogger("weave-sync")

# Bump when the checkpoint schema changes — invalidates existing files.
CHECKPOINT_SCHEMA = 1

_CHECKPOINT_FILENAME = "repair-checkpoint.json"

# Recommended command shown by signal handlers and recovery surfaces.
RECOMMENDED_REPAIR_CMD = "wv sync --gh --mode=repair"


def _repo_root() -> Path | None:
    """Return the git repo root, or None if not in a repo."""
    try:
        out = subprocess.check_output(
            ["git", "rev-parse", "--show-toplevel"],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None
    return Path(out) if out else None


def checkpoint_path() -> Path | None:
    """Resolve the checkpoint file path: ``<repo_root>/.weave/<filename>``."""
    root = _repo_root()
    if root is None:
        return None
    return root / ".weave" / _CHECKPOINT_FILENAME


def new_checkpoint() -> dict[str, Any]:
    """Return a fresh, empty checkpoint dict."""
    return {
        "schema": CHECKPOINT_SCHEMA,
        "started_at": time.time(),
        "processed": [],
    }


def load_checkpoint(path: Path | None = None) -> dict[str, Any]:
    """Load checkpoint from disk; return empty checkpoint on missing/corrupt/schema-mismatch."""
    if path is None:
        path = checkpoint_path()
    if path is None or not path.exists():
        return new_checkpoint()
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return new_checkpoint()
    if not isinstance(data, dict) or data.get("schema") != CHECKPOINT_SCHEMA:
        return new_checkpoint()
    if not isinstance(data.get("processed"), list):
        return new_checkpoint()
    return data


def save_checkpoint(
    checkpoint: dict[str, Any], path: Path | None = None
) -> None:
    """Persist checkpoint atomically (tmp file + replace)."""
    if path is None:
        path = checkpoint_path()
    if path is None:
        return
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(path.suffix + ".tmp")
        tmp.write_text(json.dumps(checkpoint, sort_keys=True), encoding="utf-8")
        tmp.replace(path)
    except OSError as e:
        log.warning("  ⚠ Could not persist repair checkpoint: %s", e)


def clear_checkpoint(path: Path | None = None) -> None:
    """Delete checkpoint after a clean repair run."""
    if path is None:
        path = checkpoint_path()
    if path is None:
        return
    try:
        path.unlink()
    except FileNotFoundError:
        pass
    except OSError as e:
        log.warning("  ⚠ Could not delete repair checkpoint: %s", e)


def processed_ids(checkpoint: dict[str, Any]) -> set[str]:
    """Return the set of node ids already processed in this repair run."""
    items = checkpoint.get("processed", [])
    return {str(x) for x in items if isinstance(x, str)}


def mark_processed(checkpoint: dict[str, Any], node_id: str) -> None:
    """Append a node id to the processed list (idempotent)."""
    items = checkpoint.setdefault("processed", [])
    if node_id not in items:
        items.append(node_id)
