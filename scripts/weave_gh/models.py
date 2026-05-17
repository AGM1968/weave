"""Data models for Weave ↔ GitHub sync."""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Any


class Mode(str, Enum):
    """Sync execution mode.

    - ``FAST``: scoped reconciliation for routine close paths (wv ship,
      session-end hooks). Phase A treats this as an alias of ``FULL``; the
      semantic split lands in Phase B.
    - ``FULL``: exhaustive Phase 1 reconciliation across the whole graph
      (current default, release-safe).
    - ``REPAIR``: operator-facing recovery surface. Phase A aliases ``FULL``;
      Phase D adds resume checkpoints.
    """

    FAST = "fast"
    FULL = "full"
    REPAIR = "repair"

    @classmethod
    def parse(cls, value: str | None) -> "Mode":
        """Return the Mode for ``value``, defaulting to FULL."""
        if value is None:
            return cls.FULL
        try:
            return cls(value)
        except ValueError as exc:
            valid = ", ".join(m.value for m in cls)
            raise ValueError(
                f"invalid sync mode {value!r}; expected one of: {valid}"
            ) from exc


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
        """Node priority (1-4, default 2). Non-numeric values fall back to 2."""
        try:
            return int(self.metadata.get("priority", 2))
        except (ValueError, TypeError):
            return 2

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
    def claimed_by(self) -> str | None:
        """Agent/user that claimed this node (WV_AGENT_ID or GH login)."""
        v = self.metadata.get("claimed_by")
        return str(v) if v is not None else None

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
    assignees: list[str] = field(default_factory=list)  # GH login names


@dataclass
class Edge:
    """A directed edge between two Weave nodes."""

    source: str
    target: str
    edge_type: str
    weight: float = 1.0


@dataclass
class SyncStats:  # pylint: disable=too-many-instance-attributes
    """Counters for sync operations."""

    created_gh: int = 0
    closed_gh: int = 0
    reopened_gh: int = 0
    updated_gh: int = 0
    created_wv: int = 0
    closed_wv: int = 0
    already_synced: int = 0
    skipped: int = 0
    # Phase C: count of nodes whose body render was skipped due to a
    # structural-digest cache hit (the rendered body would be identical).
    digest_skipped: int = 0
    # Phase D: count of nodes skipped on resume because a prior repair-mode
    # run already processed them (checkpoint hit).
    resumed_from: int = 0

    # Phase A progress counters — populated by the sync entrypoint so users
    # can see scope and progress even when no writes happen.
    mode: Mode = Mode.FULL
    total_nodes: int = 0
    candidates: int = 0
    processed: int = 0
    current_phase: str = ""

    def progress(self) -> str:
        """Return a compact progress line: mode, scope, processed counts."""
        return (
            f"mode={self.mode.value} "
            f"total={self.total_nodes} "
            f"candidates={self.candidates} "
            f"processed={self.processed} "
            f"updated={self.updated_gh} "
            f"skipped={self.skipped} "
            f"digest_hits={self.digest_skipped}"
            + (f" resumed_from={self.resumed_from}" if self.resumed_from else "")
            + (f" phase={self.current_phase}" if self.current_phase else "")
        )

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
        if self.digest_skipped:
            parts.append(f"digest cache hits: {self.digest_skipped}")
        if self.resumed_from:
            parts.append(f"resumed from checkpoint: {self.resumed_from}")
        if self.skipped:
            parts.append(f"skipped: {self.skipped}")
        body = " | ".join(parts) if parts else "no changes"
        return f"[{self.mode.value}] {body}"
