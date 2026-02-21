"""Structured issue body rendering, Mermaid graphs, and close comments."""

from __future__ import annotations

import hashlib
import subprocess

from weave_gh.cli import _run
from weave_gh.data import get_blockers, get_children, get_edges_for_nodes, get_parent
from weave_gh.models import Edge, WeaveNode

# Max children before Mermaid graph switches from full to filtered
MERMAID_NODE_THRESHOLD = 15


# ---------------------------------------------------------------------------
# Content hashing
# ---------------------------------------------------------------------------


def content_hash(text: str) -> str:
    """SHA256 hash of text, truncated to 12 chars."""
    return hashlib.sha256(text.encode()).hexdigest()[:12]


# ---------------------------------------------------------------------------
# Issue body rendering
# ---------------------------------------------------------------------------


def render_issue_body(
    node: WeaveNode,
    nodes_by_id: dict[str, WeaveNode],
    edges: list[Edge],
    *,
    include_mermaid: bool = True,
) -> str:
    """Render structured issue body with WEAVE:BEGIN/END markers.

    Human content above the markers is preserved on update.
    """
    lines: list[str] = []

    # Context header
    lines.append("## Context")
    lines.append("")

    type_str = node.node_type.capitalize() if node.node_type else "Task"
    priority_str = f"P{node.priority}"
    context_line = (
        f"**Weave ID:** `{node.id}` | **Type:** {type_str}"
        f" | **Priority:** {priority_str}"
    )
    if node.alias:
        context_line += f" | **Alias:** `{node.alias}`"
    lines.append(context_line)

    # Parent link
    parent_id = get_parent(node.id, edges)
    if parent_id and parent_id in nodes_by_id:
        parent = nodes_by_id[parent_id]
        parent_gh = parent.gh_issue
        if parent_gh:
            lines.append(f"**Part of:** #{parent_gh} ({parent.text})")
        else:
            lines.append(f"**Part of:** {parent.text} (`{parent_id}`)")

    # Blockers
    blocker_ids = get_blockers(node.id, edges)
    if blocker_ids:
        blocker_parts = []
        for bid in blocker_ids:
            if bid in nodes_by_id:
                b = nodes_by_id[bid]
                if b.gh_issue:
                    blocker_parts.append(f"#{b.gh_issue} ({b.text})")
                else:
                    blocker_parts.append(f"{b.text} (`{bid}`)")
        if blocker_parts:
            lines.append(f"**Blocked by:** {', '.join(blocker_parts)}")

    lines.append("")

    # Goal / description
    if node.description:
        lines.append("## Goal")
        lines.append("")
        lines.append(node.description)
        lines.append("")

    # Children with checkboxes (for epics/features)
    child_ids = get_children(node.id, edges)
    if child_ids:
        lines.append("## Tasks")
        lines.append("")
        for cid in child_ids:
            if cid in nodes_by_id:
                child = nodes_by_id[cid]
                check = "x" if child.status == "done" else " "
                gh_ref = f" (#{child.gh_issue})" if child.gh_issue else ""
                lines.append(f"- [{check}] {child.text}{gh_ref}")
            else:
                lines.append(f"- [ ] `{cid}` (unresolved)")
        lines.append("")

        # Mermaid graph for epics with children
        if include_mermaid and node.node_type in ("epic", "feature"):
            mermaid = render_mermaid_graph(node, child_ids, nodes_by_id)
            if mermaid:
                lines.append("## Dependency Graph")
                lines.append("")
                lines.append("```mermaid")
                lines.append(mermaid)
                lines.append("```")
                lines.append("")

    body = "\n".join(lines)
    chash = content_hash(body)

    return f"<!-- WEAVE:BEGIN hash={chash} -->\n{body}<!-- WEAVE:END -->"


# ---------------------------------------------------------------------------
# Mermaid dependency graphs
# ---------------------------------------------------------------------------


def render_mermaid_graph(
    parent: WeaveNode,
    child_ids: list[str],
    nodes_by_id: dict[str, WeaveNode],
    edges: list[Edge] | None = None,
) -> str:
    """Render Mermaid dependency graph for an epic/feature node.

    Switches to filtered view if > MERMAID_NODE_THRESHOLD children.
    """
    if not child_ids:
        return ""

    # Filter to only children that exist in the graph
    children = [nodes_by_id[cid] for cid in child_ids if cid in nodes_by_id]
    if not children:
        return ""

    # If too many children, show only non-done + their deps (but keep full graph when all done)
    if len(children) > MERMAID_NODE_THRESHOLD:
        active_children = [c for c in children if c.status != "done"]
        if active_children:
            children = active_children

    child_set = {c.id for c in children}

    # Fetch inter-child edges: use provided edges if given, else batch-fetch from DB
    # (The parent's per-node edges don't include child-to-child edges)
    child_edges = edges if edges is not None else get_edges_for_nodes(list(child_set))

    lines = ["graph TD"]

    # Style classes for status
    lines.append("    classDef done fill:#2da44e,stroke:#1a7f37,color:white")
    lines.append("    classDef active fill:#bf8700,stroke:#9a6700,color:white")
    lines.append("    classDef blocked fill:#cf222e,stroke:#a40e26,color:white")
    lines.append("    classDef todo fill:#656d76,stroke:#424a53,color:white")
    lines.append("")

    # Parent node
    pid = _mermaid_id(parent.id)
    lines.append(f"    {pid}[{_mermaid_label(parent.alias or parent.text)}]")

    # Child nodes with status styling
    for child in children:
        cid = _mermaid_id(child.id)
        status_class = (
            child.status if child.status in ("done", "active", "blocked") else "todo"
        )
        label = _mermaid_label(child.alias or child.text)
        lines.append(f"    {cid}[{label}]:::{status_class}")

    lines.append("")

    # Edges: parent → children (implements)
    for child in children:
        cid = _mermaid_id(child.id)
        lines.append(f"    {pid} --> {cid}")

    # Edges: inter-child blocks (from batch-fetched child edges)
    for edge in child_edges:
        if (
            edge.edge_type == "blocks"
            and edge.source in child_set
            and edge.target in child_set
        ):
            lines.append(
                f"    {_mermaid_id(edge.source)}"
                f" -.->|blocks| {_mermaid_id(edge.target)}"
            )

    return "\n".join(lines)


def _mermaid_id(node_id: str) -> str:
    """Convert a node ID to a valid Mermaid identifier."""
    return node_id.replace("-", "_")


def _mermaid_label(text: str) -> str:
    """Escape text for Mermaid label, truncated."""
    text = text[:60]
    # Escape special Mermaid chars
    text = text.replace('"', "'").replace("[", "(").replace("]", ")")
    return f'"{text}"'


# ---------------------------------------------------------------------------
# Close comments with learnings
# ---------------------------------------------------------------------------


def build_close_comment(
    node: WeaveNode,
    repo_url: str = "",
) -> str:
    """Build a close comment with learnings and commit links."""
    parts = [f"Completed. Weave node `{node.id}` closed."]

    learnings = node.learning_parts()
    if learnings:
        parts.append("")
        parts.append("**Learnings:**")
        for key, val in learnings.items():
            parts.append(f"- **{key.capitalize()}:** {val}")

    # Commit links
    commit_section = build_commit_links(node.id, repo_url)
    if commit_section:
        parts.append(commit_section)

    return "\n".join(parts)


def build_commit_links(node_id: str, repo_url: str = "") -> str:
    """Find git commits mentioning this node ID and format as markdown links."""
    try:
        result = _run(
            [
                "git",
                "log",
                "--format=%H",
                f"--grep={node_id}",
                "--since=90 days ago",
            ],
            check=False,
        )
        shas = result.stdout.strip().split("\n") if result.stdout.strip() else []
        # Fallback: search by Weave-ID trailer
        if not shas:
            result = _run(
                [
                    "git",
                    "log",
                    "--format=%H",
                    f"--grep=Weave-ID: {node_id}",
                    "--since=90 days ago",
                ],
                check=False,
            )
            shas = result.stdout.strip().split("\n") if result.stdout.strip() else []
    except (OSError, subprocess.SubprocessError):
        return ""

    if not shas or shas == [""]:
        return ""

    lines = ["", "**Commits:**"]
    for sha in shas[:10]:
        short = sha[:7]
        try:
            subj = _run(
                ["git", "log", "--format=%s", "-1", sha],
                check=False,
            ).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            subj = ""
        if repo_url:
            lines.append(f"- [`{short}`]({repo_url}/commit/{sha}) {subj}")
        else:
            lines.append(f"- `{short}` {subj}")

    return "\n".join(lines)
