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
    raw = wv_cli("list", "--all", "--json-v2", check=False)
    if not raw or raw == "[]":
        return []
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        log.warning("Failed to parse wv list output")
        return []

    nodes = []
    for item in data:
        meta_raw = item.get("metadata") or {}
        if isinstance(meta_raw, dict):
            meta = meta_raw
        elif isinstance(meta_raw, str) and meta_raw.strip().startswith("{"):
            try:
                meta = json.loads(meta_raw)
            except (json.JSONDecodeError, ValueError):
                meta = {}
        else:
            meta = {}
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
        "number,title,state,body,labels,assignees",
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
            assignees=[a["login"] for a in i.get("assignees", [])],
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
    # echo adds trailing newline — match bash behavior exactly.
    # MD5 here is a filesystem namespace, not a security primitive.
    return hashlib.md5(  # noqa: S324
        (repo_root + "\n").encode(), usedforsecurity=False
    ).hexdigest()[:8]


def _is_codex_runtime() -> bool:
    """Detect sandboxed-runtime agent environments (name is historical).

    Codex, Copilot, AND Claude Code (CLAUDE_CODE_SSE_PORT) all hit the same
    constraint — /dev/shm is not reliably persisted between tool invocations —
    so all route to the shared /tmp/weave-codex-<uid> sandbox zone, NOT /dev/shm.
    The "codex" naming is from the Codex-first-class era, not a Codex-only marker.
    """
    return (
        bool(os.environ.get("CODEX_THREAD_ID"))
        or os.environ.get("CODEX_CI") == "1"
        or os.environ.get("COPILOT_AGENT") == "1"
        or bool(os.environ.get("CLAUDE_CODE_SSE_PORT"))
    )


def _is_container_runtime() -> bool:
    """Best-effort container detection aligned with bash runtime resolver."""
    if os.environ.get("CI"):
        return True
    if Path("/.dockerenv").exists() or Path("/run/.containerenv").exists():
        return True
    try:
        cgroup = Path("/proc/1/cgroup")
        if cgroup.exists():
            text = cgroup.read_text(encoding="utf-8", errors="ignore")
            return any(token in text for token in ("docker", "containerd", "podman"))
    except OSError:
        return False
    return False


def _runtime_hot_zone_base(uid: int | None) -> str:
    if _is_codex_runtime():
        return f"/tmp/weave-codex-{uid}" if uid is not None else "/tmp/weave-codex"
    # Follow an already-established codex zone even without the env signal, so a
    # process that lacks CLAUDE_CODE_SSE_PORT does not split-brain away from the
    # zone holding the live DB/phase. Filesystem signal both contexts see. (wv-d6af2f)
    codex_base = f"/tmp/weave-codex-{uid}" if uid is not None else "/tmp/weave-codex"
    if uid is not None and Path(codex_base).is_dir():
        return codex_base
    if _is_container_runtime():
        return f"/tmp/weave-{uid}" if uid is not None else "/tmp/weave"
    if Path("/dev/shm").exists() and os.access("/dev/shm", os.W_OK):
        return "/dev/shm/weave"
    return f"/tmp/weave-{uid}" if uid is not None else "/tmp/weave"


def _resolve_db_path() -> str:
    """Resolve Weave DB path, checking multiple candidate locations."""
    rhash = _repo_hash()
    uid = os.getuid() if hasattr(os, "getuid") else None
    runtime_base = _runtime_hot_zone_base(uid)

    db = os.environ.get("WV_DB", "")
    if db and Path(db).exists():
        return db

    hot_zone = os.environ.get("WV_HOT_ZONE", "")
    if hot_zone:
        hot_zone_db = str(Path(hot_zone) / "brain.db")
        if Path(hot_zone_db).exists():
            return hot_zone_db

    # Try per-repo namespaced hot zone locations
    candidates = []
    if rhash:
        candidates.append(f"{runtime_base}/{rhash}/brain.db")
        if uid is not None:
            candidates.append(f"/tmp/weave-codex-{uid}/{rhash}/brain.db")
            candidates.append(f"/tmp/weave-{uid}/{rhash}/brain.db")
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
        return db or f"{runtime_base}/{rhash}/brain.db"
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


def compute_impacted_node_ids(
    focus_id: str,
    *,
    all_edges: list[Edge] | None = None,
) -> set[str]:
    """Return the set of node IDs whose rendered GH body may depend on focus_id.

    The fast-path candidate selector uses this to bound Phase 1 to:

    - the focus node itself,
    - its direct parent (checklist + Mermaid),
    - its direct children (status rolls up into focus body),
    - blockers that point at the focus and blockers the focus points at
      (both directions affect the rendered "Blocked by" / "Blocks" lines).

    Sibling nodes are excluded — the parent re-render pulls their statuses
    via its own edge lookup, so we do not need to touch them individually.
    """
    edges = all_edges if all_edges is not None else get_edges_for_node(focus_id)
    impacted: set[str] = {focus_id}
    for e in edges:
        if e.edge_type == "implements":
            if e.source == focus_id:
                impacted.add(e.target)  # parent
            elif e.target == focus_id:
                impacted.add(e.source)  # child
        elif e.edge_type == "blocks":
            if focus_id in (e.source, e.target):
                impacted.add(e.source)
                impacted.add(e.target)
    return impacted
