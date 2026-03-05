"""Label constants and management for GitHub issues."""

from __future__ import annotations

from typing import Any

from weave_gh import log
from weave_gh.cli import gh_cli
from weave_gh.models import WeaveNode

# ---------------------------------------------------------------------------
# Label constants
# ---------------------------------------------------------------------------

# Status labels synced to GitHub
STATUS_LABELS: dict[str, tuple[str, str]] = {
    # status: (label_name, color_hex)
    "active": ("weave:active", "0e8a16"),
    "blocked": ("weave:blocked", "d93f0b"),
}

# Type → GitHub label mapping
TYPE_LABELS: dict[str, str] = {
    "bug": "bug",
    "fix": "bug",
    "feature": "enhancement",
    "epic": "epic",
    "task": "task",
    "audit": "maintenance",
    "learning": "documentation",
}

PRIORITY_LABELS: dict[int, str] = {
    0: "P1",
    1: "P1",
    2: "P2",
    3: "P3",
    4: "P4",
}

# Labels we ensure exist on the repo
ENSURE_LABELS: list[tuple[str, str, str]] = [
    ("P1", "d73a4a", "Priority 1 (critical)"),
    ("P2", "e4e669", "Priority 2 (normal)"),
    ("P3", "0e8a16", "Priority 3 (low)"),
    ("P4", "c5def5", "Priority 4 (backlog)"),
    ("task", "1d76db", "General task"),
    ("bug", "d73a4a", "Bug report"),
    ("enhancement", "a2eeef", "Feature request"),
    ("epic", "7057ff", "Epic — multi-task initiative"),
    ("maintenance", "fbca04", "Maintenance / audit work"),
    ("documentation", "0075ca", "Documentation"),
    ("weave-synced", "bfdadc", "Synced from/to Weave"),
    ("weave:active", "0e8a16", "Weave node is actively being worked on"),
    ("weave:blocked", "d93f0b", "Weave node is blocked by another"),
]


# ---------------------------------------------------------------------------
# Label operations
# ---------------------------------------------------------------------------


def ensure_labels(repo: str) -> None:
    """Create all required labels on the repo (idempotent)."""
    for name, color, desc in ENSURE_LABELS:
        gh_cli(
            "label",
            "create",
            name,
            "--repo",
            repo,
            "--color",
            color,
            "--description",
            desc,
            check=False,
        )


def get_labels_for_node(node: WeaveNode) -> list[str]:
    """Compute the set of labels a node should have on GitHub."""
    labels = ["weave-synced"]

    # Type label
    type_label = TYPE_LABELS.get(node.node_type, "task")
    labels.append(type_label)

    # Priority label
    priority_label = PRIORITY_LABELS.get(node.priority, "P2")
    labels.append(priority_label)

    # Status label (only for active/blocked — not for todo/done)
    if node.status in STATUS_LABELS:
        labels.append(STATUS_LABELS[node.status][0])

    return labels


def sync_issue_labels(
    issue_num: int,
    desired_labels: list[str],
    current_labels: list[str],
    repo: str,
    *,
    dry_run: bool = False,
) -> bool:
    """Add missing labels and remove stale status labels. Returns True if changed."""
    current_set = set(current_labels)
    desired_set = set(desired_labels)

    to_add = desired_set - current_set
    # Only remove STATUS labels that shouldn't be there — don't touch other labels
    status_label_names = {v[0] for v in STATUS_LABELS.values()}
    to_remove = (current_set & status_label_names) - desired_set

    changed = False
    for label in to_add:
        if dry_run:
            log.info("  [dry-run] Would add label '%s' to #%d", label, issue_num)
        else:
            gh_cli(
                "issue",
                "edit",
                str(issue_num),
                "--repo",
                repo,
                "--add-label",
                label,
                check=False,
            )
        changed = True

    for label in to_remove:
        if dry_run:
            log.info("  [dry-run] Would remove label '%s' from #%d", label, issue_num)
        else:
            gh_cli(
                "issue",
                "edit",
                str(issue_num),
                "--repo",
                repo,
                "--remove-label",
                label,
                check=False,
            )
        changed = True

    return changed


def parse_gh_labels_to_metadata(labels: list[str]) -> dict[str, Any]:
    """Parse GitHub labels into Weave metadata fields."""
    meta: dict[str, Any] = {}

    # Priority from P1-P4 labels
    for label in labels:
        if label in ("P1", "P2", "P3", "P4"):
            meta["priority"] = int(label[1])
            break

    # Type from type labels
    reverse_type: dict[str, str] = {}
    for wtype, glabel in TYPE_LABELS.items():
        reverse_type.setdefault(glabel, wtype)
    for label in labels:
        if label in reverse_type:
            meta["type"] = reverse_type[label]
            break

    return meta
