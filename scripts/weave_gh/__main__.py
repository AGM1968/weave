"""CLI entry point for Weave ↔ GitHub sync.

Usage:
  python -m weave_gh                              # Full bidirectional sync
  python -m weave_gh --dry-run                    # Preview without changes
  python -m weave_gh --notify <node-id> <event>   # Post live progress comment
"""

from __future__ import annotations

import argparse
import fcntl
import logging
import os
import subprocess
import sys
import tempfile
from pathlib import Path

from weave_gh import log
from weave_gh.data import get_repo, get_repo_url, get_weave_nodes, get_github_issues
from weave_gh.labels import ensure_labels
from weave_gh.models import SyncStats
from weave_gh.notify import notify
from weave_gh.phases import (
    refresh_parent_body,
    sync_closed_to_weave,
    sync_github_to_weave,
    sync_weave_to_github,
)
from weave_gh.cli import wv_cli


def main() -> None:
    """CLI entry point for sync and notification commands."""
    parser = argparse.ArgumentParser(description="Sync Weave ↔ GitHub Issues")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Preview without changes",
    )
    parser.add_argument(
        "--notify",
        nargs=2,
        metavar=("NODE_ID", "EVENT"),
        help="Post live progress comment (events: work, done, block)",
    )
    parser.add_argument("--learning", help="Learning text for done notification")
    parser.add_argument(
        "--blocker",
        help="Blocker node ID for block notification",
    )
    parser.add_argument(
        "--refresh-parent",
        metavar="NODE_ID",
        help="Refresh parent epic body after child status change",
    )
    parser.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help="Debug logging",
    )
    args = parser.parse_args()

    level = logging.DEBUG if args.verbose else logging.INFO
    logging.basicConfig(
        level=level,
        format="%(message)s",
        stream=sys.stderr,
    )

    # Refresh parent mode (lightweight, no lock needed)
    if args.refresh_parent:
        refresh_parent_body(args.refresh_parent, dry_run=args.dry_run)
        return

    # Notification mode
    if args.notify:
        node_id, event = args.notify
        kwargs: dict[str, str] = {}
        if args.learning:
            kwargs["learning"] = args.learning
        if args.blocker:
            kwargs["blocker"] = args.blocker
        notify(node_id, event, **kwargs)
        return

    # Full sync mode
    _run_full_sync(dry_run=args.dry_run)


def _acquire_sync_lock() -> object:
    """Acquire an exclusive lock to prevent concurrent syncs.

    Returns the open file handle (keeps lock alive until process exits).
    """
    lock_dir = Path(tempfile.gettempdir()) / "weave"
    lock_dir.mkdir(exist_ok=True)
    lock_path = lock_dir / "sync.lock"
    fh = open(lock_path, "w", encoding="utf-8")  # noqa: SIM115  # pylint: disable=consider-using-with
    try:
        fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        log.error("Another sync is already running (lock: %s)", lock_path)
        sys.exit(1)
    return fh


def _run_full_sync(*, dry_run: bool = False) -> None:
    """Execute the three-phase bidirectional sync."""
    _sync_lock = _acquire_sync_lock()  # noqa: F841 — held for process lifetime
    # Prevent auto-prune during sync (wv CLI calls would trigger db_ensure)
    os.environ["WV_DISABLE_AUTOPRUNE"] = "1"
    log.info("🔄 Syncing Weave ↔ GitHub...")

    try:
        repo = get_repo()
    except (OSError, subprocess.CalledProcessError):
        log.error("Error: could not detect GitHub repo")
        sys.exit(1)
    log.info("   Repo: %s", repo)

    repo_url = get_repo_url()

    # Ensure labels exist
    log.info("🏷️  Ensuring labels...")
    ensure_labels(repo)

    # Fetch both sides
    log.info("📋 Fetching Weave nodes...")
    nodes = get_weave_nodes()
    log.info("   Found %d nodes", len(nodes))

    log.info("📋 Fetching GitHub issues...")
    issues = get_github_issues(repo)
    log.info("   Found %d GitHub issues", len(issues))

    nodes_by_id = {n.id: n for n in nodes}
    stats = SyncStats()

    # Phase 1: Weave → GitHub
    log.info("")
    log.info("🔍 Phase 1: Weave → GitHub...")
    issues = sync_weave_to_github(
        nodes,
        issues,
        repo,
        repo_url,
        nodes_by_id,
        stats,
        dry_run=dry_run,
    )

    # Phase 2: GitHub → Weave (re-fetch nodes after phase 1 updates)
    log.info("")
    log.info("🔍 Phase 2: GitHub → Weave...")
    nodes = get_weave_nodes()
    nodes = sync_github_to_weave(
        nodes,
        issues,
        repo,
        stats,
        dry_run=dry_run,
    )

    # Phase 3: Closed GH issues → Weave
    log.info("")
    log.info("🔍 Phase 3: Closed GH issues → Weave...")
    nodes = get_weave_nodes()
    sync_closed_to_weave(nodes, issues, stats, dry_run=dry_run)

    # Persist
    if not dry_run:
        wv_cli("sync", check=False)

    log.info("")
    log.info("════════════════════════════════════════")
    log.info("✅ Sync complete! %s", stats.summary())
    log.info("   Repo: %s", repo)
    log.info("════════════════════════════════════════")


if __name__ == "__main__":
    main()
