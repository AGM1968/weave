"""Structural digest cache for Phase 1 body-render skipping.

Phase C of PROPOSAL-wv-gh-sync-fast-path.md.

The cache stores a per-issue digest of the structural inputs that feed
``render_issue_body`` (node fields, parent, blockers, children statuses).
When the current digest matches the cached digest, the body is guaranteed
to render identically — so the expensive render + ``should_update_body``
diff can be skipped entirely.

Cache lives in ``<repo_root>/.weave/sync-digest-cache.json`` to avoid a
mid-release DB migration. A ``schema`` field invalidates the entire cache
when the digest format changes.
"""

from __future__ import annotations

import hashlib
import json
import logging
import subprocess
from pathlib import Path
from typing import Any

from weave_gh.data import get_blockers, get_children, get_parent
from weave_gh.models import Edge, WeaveNode

log = logging.getLogger("weave-sync")

# Bump when the digest format or the set of inputs changes.
# Invalidates every existing cache entry on next sync.
DIGEST_SCHEMA = 1

_CACHE_FILENAME = "sync-digest-cache.json"


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


def cache_path() -> Path | None:
    """Resolve the cache file path: ``<repo_root>/.weave/<filename>``."""
    root = _repo_root()
    if root is None:
        return None
    return root / ".weave" / _CACHE_FILENAME


def compute_structural_digest(
    node: WeaveNode,
    nodes_by_id: dict[str, WeaveNode],
    edges: list[Edge],
) -> str:
    """Hash the structural inputs that affect rendered issue body.

    The fields chosen mirror what :func:`weave_gh.rendering.render_issue_body`
    actually reads: node identity/status/priority/alias/description/type,
    the parent's text + gh_issue, every blocker's id/status/text/gh_issue,
    and every child's id/status/text/gh_issue. Mermaid output is a pure
    function of children + their statuses, so it does not need a separate
    input.
    """
    parts: list[Any] = [
        node.id,
        node.text,
        node.status,
        node.priority,
        node.alias,
        node.description,
        node.node_type,
        node.gh_issue,
    ]

    parent_id = get_parent(node.id, all_edges=edges)
    if parent_id and parent_id in nodes_by_id:
        p = nodes_by_id[parent_id]
        parts.append(("parent", p.id, p.text, p.gh_issue))
    else:
        parts.append(("parent", None))

    blocker_ids = sorted(get_blockers(node.id, all_edges=edges))
    blockers_repr: list[tuple[str, str, str, int | None]] = []
    for bid in blocker_ids:
        if bid in nodes_by_id:
            b = nodes_by_id[bid]
            blockers_repr.append((b.id, b.status, b.text, b.gh_issue))
        else:
            blockers_repr.append((bid, "unknown", "", None))
    parts.append(("blockers", blockers_repr))

    child_ids = sorted(get_children(node.id, all_edges=edges))
    children_repr: list[tuple[str, str, str, int | None]] = []
    for cid in child_ids:
        if cid in nodes_by_id:
            c = nodes_by_id[cid]
            children_repr.append((c.id, c.status, c.text, c.gh_issue))
        else:
            children_repr.append((cid, "unknown", "", None))
    parts.append(("children", children_repr))

    payload = json.dumps(parts, sort_keys=True, default=str)
    return hashlib.sha256(payload.encode()).hexdigest()[:16]


def load_cache(path: Path | None = None) -> dict[str, Any]:
    """Load the cache file. Returns empty cache on missing/corrupt/schema-bump."""
    if path is None:
        path = cache_path()
    if path is None or not path.exists():
        return {"schema": DIGEST_SCHEMA, "entries": {}}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {"schema": DIGEST_SCHEMA, "entries": {}}
    if not isinstance(data, dict) or data.get("schema") != DIGEST_SCHEMA:
        # Schema bump invalidates the whole cache.
        return {"schema": DIGEST_SCHEMA, "entries": {}}
    if not isinstance(data.get("entries"), dict):
        return {"schema": DIGEST_SCHEMA, "entries": {}}
    return data


def save_cache(cache: dict[str, Any], path: Path | None = None) -> None:
    """Persist cache atomically (write to tmp + rename)."""
    if path is None:
        path = cache_path()
    if path is None:
        return
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(path.suffix + ".tmp")
        tmp.write_text(json.dumps(cache, sort_keys=True), encoding="utf-8")
        tmp.replace(path)
    except OSError as e:
        log.warning("  ⚠ Could not persist digest cache: %s", e)


def is_cache_hit(
    cache: dict[str, Any],
    gh_issue: int,
    node_id: str,
    digest: str,
) -> bool:
    """Return True iff cache has a matching entry for this issue+node+digest."""
    entries = cache.get("entries", {})
    entry = entries.get(str(gh_issue))
    if not isinstance(entry, dict):
        return False
    return entry.get("node_id") == node_id and entry.get("digest") == digest


def update_cache(
    cache: dict[str, Any],
    gh_issue: int,
    node_id: str,
    digest: str,
) -> None:
    """Record a successful sync entry in the in-memory cache."""
    entries = cache.setdefault("entries", {})
    entries[str(gh_issue)] = {"node_id": node_id, "digest": digest}
