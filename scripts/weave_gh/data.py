"""Data fetching — Weave nodes, GitHub issues, and edges."""

from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
from pathlib import Path

from weave_gh import log
from weave_gh.cli import _run, gh_cli, wv_cli
from weave_gh.models import Edge, GitHubIssue, WeaveNode


def get_repo() -> str:
    """Get the GitHub repo name (owner/repo)."""
    return gh_cli("repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner")


def get_repo_url() -> str:
    """Get the GitHub repo URL for commit links."""
    return gh_cli("repo", "view", "--json", "url", "-q", ".url", check=False) or ""


def get_weave_nodes() -> list[WeaveNode]:
    """Fetch all Weave nodes."""
    raw = wv_cli("list", "--all", "--json", check=False)
    if not raw or raw == "[]":
        return []
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        log.warning("Failed to parse wv list output")
        return []

    nodes = []
    for item in data:
        meta_raw = item.get("metadata", "{}")
        if isinstance(meta_raw, str):
            try:
                meta = json.loads(meta_raw)
            except (json.JSONDecodeError, ValueError):
                meta = {}
        else:
            meta = meta_raw if isinstance(meta_raw, dict) else {}
        nodes.append(
            WeaveNode(
                id=item["id"],
                text=item["text"],
                status=item["status"],
                metadata=meta,
                alias=item.get("alias") or None,
            )
        )
    return nodes


_GH_ISSUE_LIMIT = 5000


def get_github_issues(repo: str) -> list[GitHubIssue]:
    """Fetch all GitHub issues (open + closed)."""
    raw = gh_cli(
        "issue",
        "list",
        "--repo",
        repo,
        "--state",
        "all",
        "--limit",
        str(_GH_ISSUE_LIMIT),
        "--json",
        "number,title,state,body,labels",
        check=False,
    )
    if not raw or raw == "[]":
        return []
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        log.warning("Failed to parse gh issue list output")
        return []
    if len(data) >= _GH_ISSUE_LIMIT:
        log.warning(
            "⚠️  Fetched %d issues (hit limit %d) — some issues may be missing. "
            "Increase _GH_ISSUE_LIMIT if sync mismatches occur.",
            len(data),
            _GH_ISSUE_LIMIT,
        )
    return [
        GitHubIssue(
            number=i["number"],
            title=i["title"],
            state=i["state"],
            body=i.get("body") or "",
            labels=[lb["name"] for lb in i.get("labels", [])],
        )
        for i in data
    ]


def _repo_hash() -> str:
    """Get the 8-char hash of the current repo root for per-repo DB namespace.

    Must match bash: echo "$REPO_ROOT" | md5sum | cut -c1-8
    Note: echo appends a newline, so we hash "path\\n" not "path".
    """
    try:
        repo_root = subprocess.check_output(
            ["git", "rev-parse", "--show-toplevel"],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return ""
    # echo adds trailing newline — match bash behavior exactly
    return hashlib.md5((repo_root + "\n").encode()).hexdigest()[:8]


def _resolve_db_path() -> str:
    """Resolve Weave DB path, checking multiple candidate locations."""
    db = os.environ.get("WV_DB", "")
    if db and Path(db).exists():
        return db
    # Try per-repo namespaced hot zone locations
    rhash = _repo_hash()
    candidates = []
    if rhash:
        candidates += [
            f"/dev/shm/weave/{rhash}/brain.db",
            f"/tmp/weave/{rhash}/brain.db",
        ]
    # Legacy global fallbacks (pre-v1.2 installs)
    candidates += ["/dev/shm/weave/brain.db", "/tmp/weave/brain.db"]
    for candidate in candidates:
        if Path(candidate).exists():
            return candidate
    # Default to namespaced path if available
    if rhash:
        return db or f"/dev/shm/weave/{rhash}/brain.db"
    return db or "/dev/shm/weave/brain.db"


def get_edges_for_node(node_id: str) -> list[Edge]:
    """Get all edges involving a node (via direct DB query for speed)."""
    db = _resolve_db_path()
    if not Path(db).exists():
        return []
    if not _is_valid_node_id(node_id):
        return []
    try:
        result = _run(
            [
                "sqlite3",
                "-json",
                db,
                f"SELECT source, target, type, weight FROM edges "
                f"WHERE source='{node_id}' OR target='{node_id}';",
            ],
            check=False,
        )
        if not result.stdout.strip():
            return []
        data = json.loads(result.stdout)
        return [
            Edge(
                source=e["source"],
                target=e["target"],
                edge_type=e["type"],
                weight=float(e.get("weight", 1.0)),
            )
            for e in data
        ]
    except (json.JSONDecodeError, KeyError):
        return []


def get_edges_for_nodes(node_ids: list[str]) -> list[Edge]:
    """Get all edges involving any of the given nodes (batch query for Mermaid)."""
    if not node_ids:
        return []
    db = _resolve_db_path()
    if not Path(db).exists():
        return []
    # Build IN clause with properly quoted IDs (safe: IDs are wv-xxxxxx hex format)
    quoted = ",".join(f"'{nid}'" for nid in node_ids if _is_valid_node_id(nid))
    if not quoted:
        return []
    try:
        result = _run(
            [
                "sqlite3",
                "-json",
                db,
                f"SELECT source, target, type, weight FROM edges "
                f"WHERE source IN ({quoted}) OR target IN ({quoted});",
            ],
            check=False,
        )
        if not result.stdout.strip():
            return []
        data = json.loads(result.stdout)
        return [
            Edge(
                source=e["source"],
                target=e["target"],
                edge_type=e["type"],
                weight=float(e.get("weight", 1.0)),
            )
            for e in data
        ]
    except (json.JSONDecodeError, KeyError):
        return []


def _is_valid_node_id(node_id: str) -> bool:
    """Validate node ID format (wv-xxxxxx+) to prevent SQL injection."""
    return bool(re.match(r"^wv-[a-f0-9]{4,64}$", node_id))


def get_children(node_id: str, all_edges: list[Edge] | None = None) -> list[str]:
    """Get child node IDs (nodes that implement this node)."""
    edges = all_edges or get_edges_for_node(node_id)
    return [
        e.source for e in edges if e.target == node_id and e.edge_type == "implements"
    ]


def get_blockers(node_id: str, all_edges: list[Edge] | None = None) -> list[str]:
    """Get blocker node IDs (nodes that block this node)."""
    edges = all_edges or get_edges_for_node(node_id)
    return [e.source for e in edges if e.target == node_id and e.edge_type == "blocks"]


def get_parent(node_id: str, all_edges: list[Edge] | None = None) -> str | None:
    """Get parent node ID (target of 'implements' edge from this node)."""
    edges = all_edges or get_edges_for_node(node_id)
    for e in edges:
        if e.source == node_id and e.edge_type == "implements":
            return e.target
    return None
