"""Live progress notifications posted to GitHub issues from CLI hooks."""

from __future__ import annotations

import json
import subprocess

from weave_gh import log
from weave_gh.cli import gh_cli, wv_cli
from weave_gh.data import get_repo


def notify(node_id: str, event: str, repo: str = "", **kwargs: str) -> None:
    """Post a live progress comment to the linked GitHub issue.

    Events: 'work' (claimed), 'done' (completed), 'block' (blocked).
    """
    if not repo:
        try:
            repo = get_repo()
        except (OSError, subprocess.CalledProcessError):
            log.warning("Cannot detect repo for notification")
            return

    # Get node metadata to find gh_issue
    try:
        raw = wv_cli("show", node_id, "--json", check=False)
        if not raw:
            return
        data = json.loads(raw)
        # wv show --json returns a list, not a dict
        if isinstance(data, list):
            if not data:
                return
            data = data[0]
        meta_raw = data.get("metadata", "{}")
        meta = json.loads(meta_raw) if isinstance(meta_raw, str) else meta_raw
        gh_num = meta.get("gh_issue")
        if not gh_num:
            return
    except (json.JSONDecodeError, subprocess.CalledProcessError, OSError):
        return

    gh_num = int(gh_num)

    if event == "work":
        comment = (
            f"🤖 AI agent claimed this task — working now.\n\n"
            f"*Weave node `{node_id}` → active*"
        )
        # Add weave:active label
        try:
            gh_cli(
                "issue",
                "edit",
                str(gh_num),
                "--repo",
                repo,
                "--add-label",
                "weave:active",
                check=True,
            )
        except subprocess.CalledProcessError as exc:
            log.warning(
                "Failed to add weave:active label to GH #%d: %s",
                gh_num,
                exc.stderr or exc,
            )

    elif event == "done":
        learning = kwargs.get("learning", "")
        comment = f"✅ Completed. Weave node `{node_id}` closed."
        if learning:
            comment += f"\n\n**Learning:** {learning}"
        # Remove weave:active label
        try:
            gh_cli(
                "issue",
                "edit",
                str(gh_num),
                "--repo",
                repo,
                "--remove-label",
                "weave:active",
                check=True,
            )
        except subprocess.CalledProcessError as exc:
            log.warning(
                "Failed to remove weave:active label from GH #%d: %s",
                gh_num,
                exc.stderr or exc,
            )

    elif event == "block":
        blocker = kwargs.get("blocker", "?")
        comment = f"🚫 Blocked by `{blocker}`.\n\n*Weave node `{node_id}` → blocked*"
        try:
            gh_cli(
                "issue",
                "edit",
                str(gh_num),
                "--repo",
                repo,
                "--add-label",
                "weave:blocked",
                check=True,
            )
        except subprocess.CalledProcessError as exc:
            log.warning(
                "Failed to add weave:blocked label to GH #%d: %s",
                gh_num,
                exc.stderr or exc,
            )

    else:
        log.warning("Unknown notify event: %s", event)
        return

    try:
        gh_cli(
            "issue",
            "comment",
            str(gh_num),
            "--repo",
            repo,
            "--body",
            comment,
            check=True,
        )
    except subprocess.CalledProcessError as exc:
        log.warning(
            "Failed to post %s notification to GH #%d: %s",
            event,
            gh_num,
            exc.stderr or exc,
        )
    log.info("  📣 Posted %s notification to GH #%d", event, gh_num)
