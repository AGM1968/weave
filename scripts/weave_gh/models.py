"""Data models for Weave ↔ GitHub sync."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any


@dataclass
class WeaveNode:
    """A node in the Weave graph."""

    id: str
    text: str
    status: str
    metadata: dict[str, Any] = field(default_factory=dict)
    alias: str | None = None

    @property
    def gh_issue(self) -> int | None:
        """Linked GitHub issue number, or None."""
        v = self.metadata.get("gh_issue")
        return int(v) if v is not None else None

    @property
    def priority(self) -> int:
        """Node priority (1-4, default 2)."""
        return int(self.metadata.get("priority", 2))

    @property
    def node_type(self) -> str:
        """Node type (task, feature, epic, bug, etc.)."""
        explicit = self.metadata.get("type")
        if explicit:
            return str(explicit)
        if self.text.startswith("Epic:"):
            return "epic"
        if self.text.startswith("Feature:"):
            return "feature"
        return "task"

    @property
    def description(self) -> str:
        """Node description from metadata."""
        return str(self.metadata.get("description", ""))

    @property
    def no_sync(self) -> bool:
        """Whether this node is excluded from GH sync."""
        return self.metadata.get("no_sync", False) is True

    @property
    def is_test(self) -> bool:
        """Whether this is a test artifact node."""
        return self.node_type == "test"

    def learning_parts(self) -> dict[str, str]:
        """Extract decision/pattern/pitfall/learning from metadata."""
        parts: dict[str, str] = {}
        for key in ("decision", "pattern", "pitfall", "learning"):
            val = self.metadata.get(key)
            if val:
                parts[key] = str(val)
        return parts


@dataclass
class GitHubIssue:
    """A GitHub issue with its metadata."""

    number: int
    title: str
    state: str  # "OPEN" or "CLOSED"
    body: str = ""
    labels: list[str] = field(default_factory=list)


@dataclass
class Edge:
    """A directed edge between two Weave nodes."""

    source: str
    target: str
    edge_type: str
    weight: float = 1.0


@dataclass
class SyncStats:
    """Counters for sync operations."""

    created_gh: int = 0
    closed_gh: int = 0
    reopened_gh: int = 0
    updated_gh: int = 0
    created_wv: int = 0
    closed_wv: int = 0
    already_synced: int = 0
    skipped: int = 0

    def summary(self) -> str:
        """Return a compact summary of all sync operations."""
        parts = []
        if self.created_gh:
            parts.append(f"GH created: {self.created_gh}")
        if self.closed_gh:
            parts.append(f"GH closed: {self.closed_gh}")
        if self.reopened_gh:
            parts.append(f"GH reopened: {self.reopened_gh}")
        if self.updated_gh:
            parts.append(f"GH updated: {self.updated_gh}")
        if self.created_wv:
            parts.append(f"Weave created: {self.created_wv}")
        if self.closed_wv:
            parts.append(f"Weave closed: {self.closed_wv}")
        if self.already_synced:
            parts.append(f"already synced: {self.already_synced}")
        if self.skipped:
            parts.append(f"skipped: {self.skipped}")
        return " | ".join(parts) if parts else "no changes"
