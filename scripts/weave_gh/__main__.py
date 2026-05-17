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
import signal
import subprocess
import sys
import tempfile
from pathlib import Path

from weave_gh import log
from weave_gh.data import get_repo, get_repo_url, get_weave_nodes, get_github_issues
from weave_gh.digest_cache import load_cache, save_cache
from weave_gh.repair_checkpoint import (
    RECOMMENDED_REPAIR_CMD,
    clear_checkpoint,
    load_checkpoint,
    save_checkpoint,
)
from weave_gh.labels import ensure_labels
from weave_gh.models import Mode, SyncStats
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
        "--mode",
        choices=[m.value for m in Mode],
        default=Mode.FULL.value,
        help=(
            "Sync mode: fast (scoped to focus node, routine close), full "
            "(exhaustive, default), repair (operator recovery, exhaustive "
            "with future resume checkpoints)."
        ),
    )
    parser.add_argument(
        "--node",
        metavar="NODE_ID",
        help=(
            "Focus node for --mode=fast candidate selection. Defaults to "
            "$WV_ACTIVE; if unset, fast mode degrades to the union of "
            "impacted sets for all currently active nodes."
        ),
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
    _run_full_sync(
        dry_run=args.dry_run,
        mode=Mode.parse(args.mode),
        focus_node_id=args.node or os.getenv("WV_ACTIVE"),
    )


def _acquire_sync_lock() -> object:
    """Acquire an exclusive lock to prevent concurrent syncs.

    Writes the current PID to the lock file so stale locks (from dead
    processes) can be detected and recovered automatically.

    Returns the open file handle (keeps lock alive until process exits).
    """
    lock_dir = Path(tempfile.gettempdir()) / "weave"
    lock_dir.mkdir(exist_ok=True)
    lock_path = lock_dir / "sync.lock"

    def _try_acquire(path: Path) -> object:
        # Avoid truncating the holder PID before we actually own the flock.
        fh = open(path, "a+", encoding="utf-8")  # noqa: SIM115  # pylint: disable=consider-using-with
        try:
            fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            fh.close()
            return None
        fh.seek(0)
        fh.truncate()
        fh.write(str(os.getpid()))
        fh.flush()
        return fh

    fh = _try_acquire(lock_path)
    if fh is not None:
        return fh

    # Lock held — check if the holder is still alive
    holder_pid: int | None = None
    try:
        holder_pid = int(lock_path.read_text(encoding="utf-8").strip())
        os.kill(holder_pid, 0)  # signal 0: existence check only
        log.error("Another sync is already running (pid %d, lock: %s)", holder_pid, lock_path)
        sys.exit(1)
    except (ValueError, FileNotFoundError):
        log.warning("Stale lock file (unreadable pid), recovering...")
    except ProcessLookupError:
        log.warning("Stale lock detected (pid %d no longer running), recovering...", holder_pid)
    except PermissionError:
        # Process exists but owned by another user — treat as live
        log.error("Another sync is already running (lock: %s)", lock_path)
        sys.exit(1)

    # Stale — unlink and retry once (safe: flock released when holder died)
    try:
        lock_path.unlink()
    except FileNotFoundError:
        pass
    fh = _try_acquire(lock_path)
    if fh is not None:
        return fh
    log.error("Could not acquire sync lock after stale recovery (lock: %s)", lock_path)
    sys.exit(1)


def _run_full_sync(
    *,
    dry_run: bool = False,
    mode: Mode = Mode.FULL,
    focus_node_id: str | None = None,
) -> None:
    """Execute the bidirectional sync.

    - ``FULL`` and ``REPAIR``: run all three phases over the entire graph.
    - ``FAST``: run only Phase 1 over the bounded candidate set produced by
      :func:`weave_gh.phases.select_candidates`. Phases 2 and 3 are skipped
      because they iterate every GitHub issue / Weave node and would defeat
      the bounded-cost guarantee of fast mode.
    """
    _sync_lock = _acquire_sync_lock()  # noqa: F841 — held for process lifetime
    # Prevent auto-prune during sync (wv CLI calls would trigger db_ensure)
    os.environ["WV_DISABLE_AUTOPRUNE"] = "1"
    _log_mode_banner(mode)

    # Phase D: repair-mode checkpoint. Loaded for REPAIR; signal handlers
    # warn operators that the run was interrupted and can be resumed.
    repair_checkpoint = load_checkpoint() if mode is Mode.REPAIR else None
    if repair_checkpoint is not None and repair_checkpoint.get("processed"):
        log.info(
            "   Resuming from checkpoint — %d node(s) already processed.",
            len(repair_checkpoint["processed"]),
        )
    if mode is Mode.REPAIR:
        _install_interrupt_handler()
    log.info("🔄 Syncing Weave ↔ GitHub...")
    if mode is Mode.FAST and focus_node_id:
        log.info("   Focus: %s", focus_node_id)

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
    stats = SyncStats(mode=mode, total_nodes=len(nodes), candidates=len(nodes))

    # Phase 1: Weave → GitHub
    log.info("")
    log.info("🔍 Phase 1: Weave → GitHub...")
    stats.current_phase = "phase-1-weave-to-github"
    digest_cache = load_cache()
    issues = sync_weave_to_github(
        nodes,
        issues,
        repo,
        repo_url,
        nodes_by_id,
        stats,
        dry_run=dry_run,
        mode=mode,
        focus_node_id=focus_node_id,
        cache=digest_cache,
        checkpoint=repair_checkpoint,
    )
    if not dry_run:
        save_cache(digest_cache)
        if mode is Mode.REPAIR and repair_checkpoint is not None:
            # Persist final checkpoint state — cleared after Phase 3 success.
            save_checkpoint(repair_checkpoint)

    if mode is Mode.FAST:
        log.info(
            "⏭  Skipping Phase 2 and Phase 3 — fast mode bounds work to the "
            "focus impacted set. Run --mode=full for full reconcile."
        )
    else:
        # Phase 2: GitHub → Weave (re-fetch nodes after phase 1 updates)
        log.info("")
        log.info("🔍 Phase 2: GitHub → Weave...")
        stats.current_phase = "phase-2-github-to-weave"
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
        stats.current_phase = "phase-3-closed-to-weave"
        nodes = get_weave_nodes()
        sync_closed_to_weave(nodes, issues, stats, dry_run=dry_run)

    stats.current_phase = "complete"

    # Repair-mode succeeded end-to-end — drop the resume checkpoint.
    if mode is Mode.REPAIR and not dry_run:
        clear_checkpoint()

    # Persist
    if not dry_run:
        wv_cli("sync", check=False)

    log.info("")
    log.info("════════════════════════════════════════")
    log.info("✅ Sync complete! %s", stats.summary())
    log.info("   %s", stats.progress())
    log.info("   Repo: %s", repo)
    log.info("════════════════════════════════════════")


def _log_mode_banner(mode: Mode) -> None:
    """Print an upfront explanation for non-fast modes."""
    if mode is Mode.FAST:
        return
    if mode is Mode.FULL:
        log.info(
            "ℹ️  Running FULL sync — exhaustive reconcile across the whole "
            "graph. For routine close paths use --mode=fast."
        )
        return
    if mode is Mode.REPAIR:
        log.info(
            "🛠  Running REPAIR sync — operator-grade recovery with resume "
            "checkpoints. Re-run `%s` after a timeout/interrupt to resume "
            "from the last processed node.",
            RECOMMENDED_REPAIR_CMD,
        )


def _install_interrupt_handler() -> None:
    """Install SIGINT/SIGTERM handlers that emit the repair-resume hint.

    The handler is best-effort: it prints to stderr and re-raises the default
    behaviour so the process still exits.
    """

    def _handler(signum, _frame):  # type: ignore[no-untyped-def]
        sig_name = signal.Signals(signum).name if hasattr(signal, "Signals") else str(signum)
        sys.stderr.write(
            f"\n⚠  Repair sync interrupted ({sig_name}). "
            f"Re-run `{RECOMMENDED_REPAIR_CMD}` to resume from the last "
            "processed node.\n",
        )
        sys.stderr.flush()
        # Restore default handler and re-raise so normal exit semantics apply.
        signal.signal(signum, signal.SIG_DFL)
        os.kill(os.getpid(), signum)

    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            signal.signal(sig, _handler)
        except (ValueError, OSError):
            # Non-main thread or unsupported signal — skip silently.
            pass


if __name__ == "__main__":
    main()
