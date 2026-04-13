"""Sync phases: Weave→GitHub, GitHub→Weave, and closed sync."""

from __future__ import annotations

import getpass
import json
import os
import re
import socket
import subprocess
from functools import lru_cache

from weave_gh import log
from weave_gh.body import compose_issue_body, extract_human_content, should_update_body
from weave_gh.cli import _run, gh_cli, wv_cli
from weave_gh.data import _resolve_db_path, get_edges_for_node, get_parent, get_repo
from weave_gh.labels import (
    get_labels_for_node,
    parse_gh_labels_to_metadata,
    sync_issue_labels,
)
from weave_gh.models import GitHubIssue, SyncStats, WeaveNode
from weave_gh.rendering import build_close_comment, render_issue_body

from weave_gh.body import parse_gh_body_description, parse_issue_template_fields

# Marker left by both `wv done` and sync Phase 1 when closing a GH issue.
# Used to detect Weave-closed issues and prevent phantom reopens.
_WEAVE_CLOSE_MARKER = "Completed. Weave node"

# Cache of known-invalid assignee logins to avoid repeated failed API calls.
_invalid_assignees: set[str] = set()


@lru_cache(maxsize=1)
def _current_gh_login() -> str | None:
    """Return the authenticated GH login for this sync process, if available."""
    result = _run(["gh", "api", "user", "--jq", ".login"], check=False)
    if result.returncode != 0:
        return None
    login = result.stdout.strip()
    return login or None


def _desired_assignee_for_node(node: WeaveNode) -> str | None:
    """Resolve the GH assignee login to sync for a node.

    `claimed_by` is primarily a local lock identity (WV_AGENT_ID or hostname-user),
    not necessarily a GitHub login. For active local claims, map back to the
    authenticated GH user; for done nodes, skip assignee sync entirely.
    """
    if node.status == "done" or not node.claimed_by:
        return None

    local_agent_ids = {
        value
        for value in (
            os.getenv("WV_AGENT_ID"),
            f"{socket.gethostname()}-{getpass.getuser()}",
        )
        if value
    }
    if node.claimed_by in local_agent_ids:
        return _current_gh_login()
    return node.claimed_by


def _is_valid_assignee(login: str, repo: str) -> bool:
    """Return True if login is a valid assignee for repo (cached)."""
    if login in _invalid_assignees:
        return False
    result = _run(["gh", "api", f"repos/{repo}/assignees/{login}"], check=False)
    if result.returncode == 0:
        return True
    _invalid_assignees.add(login)
    log.warning(
        "  ⚠ %r is not a valid assignee for %s — skipping assignment", login, repo
    )
    return False


def _sync_assignee(
    gh_num: int,
    desired: str | None,
    current_assignees: list[str],
    repo: str,
    *,
    dry_run: bool = False,
) -> bool:
    """Sync a single assignee to a GH issue. Returns True if changed."""
    current = current_assignees[0] if current_assignees else None
    if desired == current:
        return False
    if dry_run:
        log.info(
            "  [dry-run] Would set assignee of #%d to %s", gh_num, desired or "(none)"
        )
        return True
    if desired:
        if not _is_valid_assignee(desired, repo):
            return False
        result = _run(
            [
                "gh",
                "issue",
                "edit",
                str(gh_num),
                "--repo",
                repo,
                "--add-assignee",
                desired,
            ],
            check=False,
        )
        if result.returncode != 0:
            log.warning(
                "  ⚠ Failed to assign #%d to %r: %s",
                gh_num,
                desired,
                result.stderr.strip(),
            )
            return False
        log.info("  👤 Assigned #%d to %s", gh_num, desired)
    elif current:
        result = _run(
            [
                "gh",
                "issue",
                "edit",
                str(gh_num),
                "--repo",
                repo,
                "--remove-assignee",
                current,
            ],
            check=False,
        )
        if result.returncode != 0:
            log.warning(
                "  ⚠ Failed to remove assignee %r from #%d: %s",
                current,
                gh_num,
                result.stderr.strip(),
            )
            return False
        log.info("  👤 Removed assignee %s from #%d", current, gh_num)
    return True


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _backfill_gh_issue(
    node: WeaveNode,
    gh_num: int,
    *,
    dry_run: bool = False,
    all_nodes: list[WeaveNode] | None = None,
) -> None:
    """Update node metadata with gh_issue reference (atomic key-set + in-memory).

    Includes dedup guard: if another node already claims this gh_issue number,
    skip the backfill to prevent duplicate mappings.
    """
    if dry_run:
        return

    # Dedup guard: check if another node already has this gh_issue
    if all_nodes is not None:
        existing = [n for n in all_nodes if n.gh_issue == gh_num and n.id != node.id]
        if existing:
            log.warning(
                "  ⚠️  Skipping backfill of gh_issue=%d to %s — already claimed by %s",
                gh_num,
                node.id,
                existing[0].id,
            )
            return

    # Atomic: json_set only touches the gh_issue key, no read-modify-write race
    db = _resolve_db_path()
    _run(
        [
            "sqlite3",
            db,
            f"UPDATE nodes SET metadata = json_set(metadata, '$.gh_issue', {int(gh_num)}) "
            f"WHERE id = '{node.id}';",
        ],
        check=False,
    )
    # Also update in-memory so later nodes see correct cross-references
    node.metadata["gh_issue"] = gh_num


def _was_closed_by_weave(issue_number: int, repo: str) -> bool:
    """Check if a GH issue was closed by Weave (not by a human).

    Looks at the last comment on the issue for the Weave close marker.
    Both ``wv done`` and sync Phase 1 leave a comment starting with
    "Completed. Weave node" when closing an issue.

    Returns True if the last comment contains the marker, False otherwise
    (including on API errors — fail-open means we allow the reopen).
    """
    try:
        output = gh_cli(
            "issue",
            "view",
            str(issue_number),
            "--repo",
            repo,
            "--json",
            "comments",
            "--jq",
            '.comments[-1].body // ""',
            check=False,
        )
        return _WEAVE_CLOSE_MARKER in output
    except (subprocess.SubprocessError, OSError):
        # Fail-open: if we can't check, allow the reopen
        return False


# ---------------------------------------------------------------------------
# Phase 1: Weave → GitHub
# ---------------------------------------------------------------------------


def sync_weave_to_github(  # noqa: C901
    nodes: list[WeaveNode],
    issues: list[GitHubIssue],
    repo: str,
    repo_url: str,
    nodes_by_id: dict[str, WeaveNode],
    stats: SyncStats,
    *,
    dry_run: bool = False,
) -> list[GitHubIssue]:
    """Create/update/close GitHub issues from Weave nodes.

    Returns updated issues list (including newly created).
    """
    issues_by_num: dict[int, GitHubIssue] = {i.number: i for i in issues}
    issues_by_title: dict[str, GitHubIssue] = {i.title: i for i in issues}

    # Detect duplicate gh_issue mappings (multiple nodes → same GH issue).
    # Keep the processing guard for all duplicate groups, but only warn when at
    # least one node is still live; done-only duplicates are historical noise.
    gh_to_nodes: dict[int, list[WeaveNode]] = {}
    for node in nodes:
        if node.gh_issue:
            gh_to_nodes.setdefault(node.gh_issue, []).append(node)
    duplicate_groups = {gh: dup_nodes for gh, dup_nodes in gh_to_nodes.items() if len(dup_nodes) > 1}
    warn_dupes = {
        gh: dup_nodes
        for gh, dup_nodes in duplicate_groups.items()
        if any(node.status != "done" for node in dup_nodes)
    }

    # Build set of gh_issue numbers where ANY node is done (prevents phantom reopens)
    done_gh_issues: set[int] = {
        n.gh_issue for n in nodes if n.gh_issue is not None and n.status == "done"
    }
    if warn_dupes:
        log.warning("⚠️  Duplicate gh_issue mappings detected (last writer wins):")
        for gh_num, dup_nodes in warn_dupes.items():
            log.warning("   #%d ← %s", gh_num, ", ".join(node.id for node in dup_nodes))
        log.warning(
            '   Fix with: sqlite3 $WV_DB "UPDATE nodes SET metadata'
            " = json_set(metadata, '$.gh_issue', CORRECT_NUM)"
            " WHERE id = 'NODE_ID'\"",
        )
        log.warning("")

    # Track which GH issues have already been processed (prevents duplicate overwrite)
    processed_gh: set[int] = set()

    for node in nodes:
        # Skip test nodes and no_sync nodes
        if node.is_test or node.no_sync:
            stats.skipped += 1
            continue

        # Find matching GH issue
        gh_match: int | None = None

        # Match by metadata.gh_issue first
        if node.gh_issue and node.gh_issue in issues_by_num:
            gh_match = node.gh_issue

        # Fallback: search by Weave ID field in body (handles both format variants)
        if gh_match is None:
            marker_bold = f"**Weave ID:** `{node.id}`"
            marker_plain = f"**Weave ID**: `{node.id}`"
            for issue in issues:
                if marker_bold in issue.body or marker_plain in issue.body:
                    gh_match = issue.number
                    break

        if gh_match is None:
            _handle_new_issue(
                node,
                nodes_by_id,
                issues,
                issues_by_num,
                issues_by_title,
                repo,
                repo_url,
                stats,
                all_nodes=nodes,
                dry_run=dry_run,
            )
        else:
            # Skip duplicate gh_issue mappings — only process first node per GH issue
            if gh_match in processed_gh and gh_match in duplicate_groups:
                log.info(
                    "  ⏭ Skipping %s — GH #%d already processed by another node",
                    node.id,
                    gh_match,
                )
                stats.skipped += 1
                continue
            processed_gh.add(gh_match)
            _handle_existing_issue(
                node,
                gh_match,
                issues_by_num,
                nodes_by_id,
                repo,
                repo_url,
                stats,
                all_nodes=nodes,
                done_gh_issues=done_gh_issues,
                dry_run=dry_run,
            )

    return issues


def _handle_new_issue(
    node: WeaveNode,
    nodes_by_id: dict[str, WeaveNode],
    issues: list[GitHubIssue],
    issues_by_num: dict[int, GitHubIssue],
    issues_by_title: dict[str, GitHubIssue],
    repo: str,
    repo_url: str,
    stats: SyncStats,
    *,
    all_nodes: list[WeaveNode] | None = None,
    dry_run: bool = False,
) -> None:
    """Handle a Weave node that has no matching GH issue."""
    if node.status not in ("todo", "active", "done", "blocked"):
        stats.skipped += 1
        return

    # Dedup guard: only backfill from title match if the GH issue has
    # the weave-synced label (prevents false matches on coincidental titles)
    if node.text in issues_by_title:
        existing = issues_by_title[node.text]
        if "weave-synced" in existing.labels:
            log.info(
                "  ⏭ Skipping %s — GH #%d already has same title (weave-synced)",
                node.id,
                existing.number,
            )
            _backfill_gh_issue(
                node, existing.number, dry_run=dry_run, all_nodes=all_nodes
            )
            stats.already_synced += 1
            return
        log.info(
            "  ℹ️  %s matches GH #%d by title but issue lacks weave-synced label — creating new",
            node.id,
            existing.number,
        )

    # Create new GH issue
    edges = get_edges_for_node(node.id)
    weave_body = render_issue_body(node, nodes_by_id, edges)
    labels = get_labels_for_node(node)

    if dry_run:
        log.info("  [dry-run] Would create GH issue: %s — %s", node.id, node.text)
        stats.created_gh += 1
        return

    # GitHub titles max 256 chars — truncate with ellipsis, full text goes in body
    gh_title = node.text if len(node.text) <= 256 else node.text[:253] + "..."
    log.info("  ➕ Creating GH issue: %s — %s", node.id, gh_title)

    label_args: list[str] = []
    for lb in labels:
        label_args.extend(["--label", lb])

    try:
        result = gh_cli(
            "issue",
            "create",
            "--repo",
            repo,
            "--title",
            gh_title,
            "--body",
            weave_body,
            *label_args,
        )
        # Extract issue number from URL
        num_match = re.search(r"/(\d+)$", result)
        if num_match:
            new_num = int(num_match.group(1))
            log.info("     ✓ Created: #%d", new_num)

            # Add to tracking
            new_issue = GitHubIssue(new_num, node.text, "OPEN", weave_body, labels)
            issues.append(new_issue)
            issues_by_num[new_num] = new_issue
            issues_by_title[node.text] = new_issue

            # Backfill metadata
            _backfill_gh_issue(node, new_num, all_nodes=all_nodes)
            stats.created_gh += 1

            desired_assignee = _desired_assignee_for_node(node)
            if desired_assignee:
                _sync_assignee(new_num, desired_assignee, [], repo)

            # If node already done, immediately close
            if node.status == "done":
                close_comment = build_close_comment(node, repo_url)
                gh_cli(
                    "issue",
                    "close",
                    str(new_num),
                    "--repo",
                    repo,
                    "--comment",
                    close_comment,
                    check=False,
                )
                # Update in-memory state to prevent stale data in later phases
                new_issue.state = "CLOSED"
                log.info("     🔒 Immediately closed (node already done)")
                stats.closed_gh += 1
        else:
            log.error("     ✗ Failed to parse issue number from: %s", result)
    except subprocess.CalledProcessError as e:
        log.error("     ✗ Failed to create issue: %s", e.stderr)


def _handle_existing_issue(
    node: WeaveNode,
    gh_match: int,
    issues_by_num: dict[int, GitHubIssue],
    nodes_by_id: dict[str, WeaveNode],
    repo: str,
    repo_url: str,
    stats: SyncStats,
    *,
    all_nodes: list[WeaveNode] | None = None,
    done_gh_issues: set[int] | None = None,
    dry_run: bool = False,
) -> None:
    """Handle a Weave node that already has a matching GH issue."""
    issue = issues_by_num[gh_match]

    about_to_close = node.status == "done" and issue.state == "OPEN"

    # Always update body if content changed — even for already-closed issues.
    # wv done closes GH issues directly but doesn't refresh the parent epic
    # body, so checkboxes and Mermaid graphs go stale. By updating bodies
    # unconditionally here, wv sync --gh catches up on any missed updates.
    edges = get_edges_for_node(node.id)

    # Guard: nodes re-imported from GitHub (source=github) have no children or
    # edges in the local graph. render_issue_body would produce a minimal
    # Context-only block, overwriting Tasks/Mermaid sections that were authored
    # on the issue (or generated by a previous sync when the node had children).
    # Skip body update for these nodes; label and status sync still proceed.
    _is_reimported = node.metadata.get("source") == "github"
    _has_children = any(
        e.target == node.id and e.edge_type == "implements" for e in edges
    )
    if _is_reimported and not _has_children:
        log.info(
            "  ⏭ Skipping body update for re-imported node %s (no children in graph)",
            node.id,
        )
    else:
        new_weave_block = render_issue_body(node, nodes_by_id, edges)

        if should_update_body(issue.body, new_weave_block):
            human_content = extract_human_content(issue.body)
            new_body = compose_issue_body(human_content, new_weave_block)

            if dry_run:
                log.info("  [dry-run] Would update body of #%d", gh_match)
            else:
                gh_cli(
                    "issue",
                    "edit",
                    str(gh_match),
                    "--repo",
                    repo,
                    "--body",
                    new_body,
                    check=False,
                )
                log.info("  📝 Updated body of #%d (%s)", gh_match, node.id)
            stats.updated_gh += 1

    # Sync labels
    desired_labels = get_labels_for_node(node)
    sync_issue_labels(
        gh_match,
        desired_labels,
        issue.labels,
        repo,
        dry_run=dry_run,
    )

    # Sync assignee: local claims map to the authenticated GH user.
    desired_assignee = _desired_assignee_for_node(node)
    if desired_assignee:
        _sync_assignee(
            gh_match, desired_assignee, issue.assignees, repo, dry_run=dry_run
        )

    # Status sync
    if about_to_close:
        close_comment = build_close_comment(node, repo_url)
        if dry_run:
            log.info("  [dry-run] Would close #%d", gh_match)
        else:
            gh_cli(
                "issue",
                "close",
                str(gh_match),
                "--repo",
                repo,
                "--comment",
                close_comment,
                check=False,
            )
            # Update in-memory state to prevent stale data in later phases
            issue.state = "CLOSED"
            log.info(
                "  🔒 Closing GH #%d (node %s is done)",
                gh_match,
                node.id,
            )
        stats.closed_gh += 1

    elif node.status != "done" and issue.state == "CLOSED":
        # Guard 1: don't reopen if ANY node with this gh_issue is done
        # (prevents phantom/duplicate todo nodes from reopening closed issues)
        if done_gh_issues and gh_match in done_gh_issues:
            log.info(
                "  ⏭ Skipping reopen of #%d — another node with this gh_issue is done"
                " (phantom node %s)",
                gh_match,
                node.id,
            )
            stats.skipped += 1
        # Guard 2: don't reopen if Weave itself closed the issue
        # (prevents phantom reopens when node is active but work was already done)
        elif _was_closed_by_weave(gh_match, repo):
            log.info(
                "  ⏭ Skipping reopen of #%d — closed by Weave"
                " (node %s still active; use `wv done %s` to close it)",
                gh_match,
                node.id,
                node.id,
            )
            stats.skipped += 1
        elif dry_run:
            log.info("  [dry-run] Would reopen #%d", gh_match)
            stats.reopened_gh += 1
        else:
            gh_cli(
                "issue",
                "reopen",
                str(gh_match),
                "--repo",
                repo,
                "--comment",
                f"Reopening — Weave node `{node.id}` is still open.",
                check=False,
            )
            # Update in-memory state so Phase 3 doesn't re-close
            issue.state = "OPEN"
            log.info(
                "  🔓 Reopening GH #%d (node %s is still open)",
                gh_match,
                node.id,
            )
            stats.reopened_gh += 1

    else:
        stats.already_synced += 1

    # Backfill gh_issue if matched by body search
    if node.gh_issue is None:
        _backfill_gh_issue(node, gh_match, dry_run=dry_run, all_nodes=all_nodes)


# ---------------------------------------------------------------------------
# Phase 2: GitHub → Weave
# ---------------------------------------------------------------------------


def sync_github_to_weave(
    nodes: list[WeaveNode],
    issues: list[GitHubIssue],
    _repo: str,
    stats: SyncStats,
    *,
    dry_run: bool = False,
) -> list[WeaveNode]:
    """Create Weave nodes from untracked GitHub issues.

    Args:
        _repo: Repository name (unused but kept for phase API consistency).

    Returns updated nodes list.
    """
    tracked_gh_nums = {n.gh_issue for n in nodes if n.gh_issue is not None}
    node_ids = {n.id for n in nodes}

    for issue in issues:
        # Skip test issues (labeled weave:test)
        if "weave:test" in issue.labels:
            stats.skipped += 1
            continue

        # Skip if already tracked by metadata.gh_issue
        if issue.number in tracked_gh_nums:
            continue

        # Skip if issue body contains a known Weave ID marker
        # Handle both format variants: **Weave ID:** `id` and **Weave ID**: `id`
        if any(
            f"**Weave ID:** `{nid}`" in issue.body
            or f"**Weave ID**: `{nid}`" in issue.body
            for nid in node_ids
        ):
            continue

        # New GH issue not in Weave
        if issue.state == "OPEN":
            # Parse GH labels into metadata
            meta = parse_gh_labels_to_metadata(issue.labels)
            meta["gh_issue"] = issue.number
            meta["source"] = "github"

            # Parse issue template form fields (### Type, ### Priority, etc.)
            form = parse_issue_template_fields(issue.body)
            if "type" in form:
                meta["type"] = form["type"]
            if "priority" in form:
                # Extract P-number: "P1 (high)" → 1
                p_match = re.match(r"P(\d)", form["priority"])
                if p_match:
                    meta["priority"] = int(p_match.group(1))

            # Parse description from body (template field or freeform)
            desc = form.get("description") or parse_gh_body_description(issue.body)
            if desc:
                meta["description"] = desc

            # Set claimed_by from first GH assignee
            if issue.assignees:
                meta["claimed_by"] = issue.assignees[0]

            if dry_run:
                log.info(
                    "  [dry-run] Would create Weave node for GH #%d — %s",
                    issue.number,
                    issue.title,
                )
                stats.created_wv += 1
                continue

            log.info(
                "  ➕ Creating Weave node for GH #%d — %s",
                issue.number,
                issue.title,
            )
            try:
                result = wv_cli(
                    "add",
                    issue.title,
                    f"--metadata={json.dumps(meta)}",
                    "--standalone",
                )
                new_id = result.strip().split("\n")[-1].strip()
                if new_id:
                    log.info("     ✓ Created: %s", new_id)
                    nodes.append(WeaveNode(new_id, issue.title, "todo", meta))
                    stats.created_wv += 1
            except subprocess.CalledProcessError as e:
                log.error("     ✗ Failed: %s", e.stderr)
        else:
            # Closed GH issue with no Weave node — skip
            stats.skipped += 1

    return nodes


# ---------------------------------------------------------------------------
# Phase 3: Closed GH issues → mark Weave nodes done
# ---------------------------------------------------------------------------


def sync_closed_to_weave(
    nodes: list[WeaveNode],
    issues: list[GitHubIssue],
    stats: SyncStats,
    *,
    dry_run: bool = False,
) -> None:
    """Close Weave nodes whose corresponding GH issues are closed."""
    issues_by_num = {i.number: i for i in issues}

    for node in nodes:
        if node.gh_issue and node.status != "done":
            issue = issues_by_num.get(node.gh_issue)
            if issue and issue.state == "CLOSED":
                if dry_run:
                    log.info(
                        "  [dry-run] Would close Weave %s (GH #%d is closed)",
                        node.id,
                        node.gh_issue,
                    )
                else:
                    log.info(
                        "  ✓ Closing Weave %s (GH #%d is closed)",
                        node.id,
                        node.gh_issue,
                    )
                    wv_cli(
                        "done",
                        node.id,
                        "--skip-verification",
                        "--acknowledge-overlap",
                        "--learning=closed via GH issue sync (Phase 3)",
                        check=False,
                    )
                stats.closed_wv += 1


# ---------------------------------------------------------------------------
# Targeted parent body refresh (called from wv done)
# ---------------------------------------------------------------------------


def refresh_parent_body(child_id: str, *, dry_run: bool = False) -> bool:
    """Refresh the parent epic's GH issue body after a child status change.

    Finds the parent of child_id, re-renders its body (checkboxes + Mermaid),
    and updates the GH issue if the content hash changed. Returns True if
    the parent was updated.
    """
    from weave_gh.data import get_weave_nodes  # pylint: disable=import-outside-toplevel

    # Find parent via implements edge
    parent_id = get_parent(child_id)
    if not parent_id:
        return False

    # Get all nodes to build nodes_by_id for rendering
    nodes = get_weave_nodes()
    nodes_by_id = {n.id: n for n in nodes}

    parent = nodes_by_id.get(parent_id)
    if not parent or not parent.gh_issue:
        return False

    try:
        repo = get_repo()
    except (OSError, subprocess.CalledProcessError):
        return False

    # Fetch just the parent's current GH issue body
    raw = gh_cli(
        "issue",
        "view",
        str(parent.gh_issue),
        "--repo",
        repo,
        "--json",
        "body",
        "-q",
        ".body",
        check=False,
    )
    if not raw:
        return False

    # Re-render and compare
    edges = get_edges_for_node(parent_id)
    new_weave_block = render_issue_body(parent, nodes_by_id, edges)

    if not should_update_body(raw, new_weave_block):
        return False

    human_content = extract_human_content(raw)
    new_body = compose_issue_body(human_content, new_weave_block)

    if dry_run:
        log.info("  [dry-run] Would refresh parent epic #%d", parent.gh_issue)
        return True

    gh_cli(
        "issue",
        "edit",
        str(parent.gh_issue),
        "--repo",
        repo,
        "--body",
        new_body,
        check=False,
    )
    log.info("  📝 Refreshed parent epic #%d (%s)", parent.gh_issue, parent_id)
    return True
