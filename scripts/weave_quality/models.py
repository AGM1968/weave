"""Data models for Weave quality metrics.

Zero external dependencies -- pure Python dataclasses.

Architecture matches the proposal's table separation:
  - FileEntry: static analysis per file per scan (maps to `files` table)
  - CKMetrics: class-level OO metrics per file per scan (maps to `file_metrics` EAV table)
  - GitStats: git-derived metrics per file, NOT scan-versioned (maps to `git_stats` table)
  - CoChange: co-change pairs (maps to `co_change` table)
  - FileState: incremental scan tracking (maps to `file_state` table)
  - ScanMeta: scan run metadata (maps to `scan_meta` table)
  - ProjectMetrics: aggregate view (computed, not stored)
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from typing import Any


@dataclass
class FileEntry:
    """Static analysis metrics for a single file (scan-versioned).

    Maps to the `files` table. One row per file per scan.
    """

    path: str
    scan_id: int = 0
    language: str = "unknown"
    loc: int = 0                  # Total lines of code
    complexity: float = 0.0       # Cyclomatic complexity proxy or ast CC
    functions: int = 0            # Number of functions/methods
    max_nesting: int = 0          # Deepest nesting level
    avg_fn_len: float = 0.0       # Average lines per function

    def to_dict(self) -> dict[str, Any]:
        """Serialise to a flat dict suitable for DB insertion."""
        return {
            "path": self.path,
            "scan_id": self.scan_id,
            "language": self.language,
            "loc": self.loc,
            "complexity": self.complexity,
            "functions": self.functions,
            "max_nesting": self.max_nesting,
            "avg_fn_len": self.avg_fn_len,
        }

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> FileEntry:
        """Reconstruct from a DB row dict."""
        return cls(
            path=d["path"],
            scan_id=int(d.get("scan_id", 0)),
            language=d.get("language", "unknown"),
            loc=int(d.get("loc", 0)),
            complexity=float(d.get("complexity", 0)),
            functions=int(d.get("functions", 0)),
            max_nesting=int(d.get("max_nesting", 0)),
            avg_fn_len=float(d.get("avg_fn_len", 0)),
        )


@dataclass
class CKMetrics:
    """CK-suite OO metrics for a single file (scan-versioned, EAV).

    Maps to the `file_metrics` EAV table. Only populated when ast parsing
    succeeds (Python files). Metrics: wmc, cbo, dit, rfc, lcom.
    """

    path: str
    scan_id: int = 0
    metrics: dict[str, float] = field(default_factory=dict)

    # Standard CK metric names
    VALID_METRICS = {"wmc", "cbo", "dit", "rfc", "lcom", "noc"}

    def to_rows(self) -> list[dict[str, Any]]:
        """Convert to list of EAV row dicts for DB insertion."""
        return [
            {"path": self.path, "scan_id": self.scan_id, "metric": k, "value": v}
            for k, v in self.metrics.items()
            if k in self.VALID_METRICS
        ]

    @classmethod
    def from_rows(cls, rows: list[dict[str, Any]]) -> CKMetrics | None:
        """Reconstruct from EAV rows (all for same path/scan_id)."""
        if not rows:
            return None
        first = rows[0]
        metrics = {r["metric"]: float(r["value"]) for r in rows}
        return cls(
            path=first["path"],
            scan_id=int(first.get("scan_id", 0)),
            metrics=metrics,
        )


@dataclass
class GitStats:
    """Git-derived metrics for a single file (NOT scan-versioned).

    Maps to the `git_stats` table. Computed from full git history,
    always represents current state. Updated globally on each scan.
    """

    path: str
    churn: int = 0                # Total commit count touching this file
    authors: int = 0              # Distinct author count
    age_days: int = 0             # Days since last modification
    hotspot: float = 0.0          # normalize(complexity) x normalize(churn)

    def to_dict(self) -> dict[str, Any]:
        """Serialise to a flat dict suitable for DB insertion."""
        return {
            "path": self.path,
            "churn": self.churn,
            "authors": self.authors,
            "age_days": self.age_days,
            "hotspot": self.hotspot,
        }

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> GitStats:
        """Reconstruct from a DB row dict."""
        return cls(
            path=d["path"],
            churn=int(d.get("churn", 0)),
            authors=int(d.get("authors", 0)),
            age_days=int(d.get("age_days", 0)),
            hotspot=float(d.get("hotspot", 0)),
        )


@dataclass
class CoChange:
    """Co-change pair: files that frequently change together in commits.

    Maps to the `co_change` table. NOT scan-versioned.
    """

    path_a: str
    path_b: str
    count: int = 0


@dataclass
class FileState:
    """Per-file state for incremental scanning.

    Maps to the `file_state` table. Tracks mtime and git blob SHA to
    skip unchanged files on subsequent scans.
    """

    path: str
    mtime: int = 0                # File modification time (epoch seconds)
    git_blob: str = ""            # git hash-object result (blob SHA)

    def to_dict(self) -> dict[str, Any]:
        """Serialize to plain dict."""
        return {
            "path": self.path,
            "mtime": self.mtime,
            "git_blob": self.git_blob,
        }

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> FileState:
        """Deserialize from plain dict."""
        return cls(
            path=d["path"],
            mtime=int(d.get("mtime", 0)),
            git_blob=d.get("git_blob", ""),
        )


@dataclass
class ScanMeta:
    """Metadata for a single quality scan run.

    Maps to the `scan_meta` table. Two scans retained (current + previous)
    to enable delta reports. Older scans deleted on each new scan.
    """

    id: int = 0
    scanned_at: str = ""          # ISO 8601 timestamp
    git_head: str = ""            # HEAD SHA at scan time
    files_count: int = 0
    duration_ms: int = 0

    @classmethod
    def create(cls, git_head: str, files_count: int = 0,
               duration_ms: int = 0) -> ScanMeta:
        """Create a new ScanMeta with current timestamp."""
        return cls(
            git_head=git_head,
            scanned_at=datetime.now().isoformat(),
            files_count=files_count,
            duration_ms=duration_ms,
        )

    def is_stale(self, current_head: str) -> bool:
        """Check if this scan is stale (HEAD has moved)."""
        return self.git_head != current_head


@dataclass
class ProjectMetrics:
    """Aggregate quality metrics for a project scan.

    Computed view -- not stored in DB. Combines data from files + git_stats.
    """

    total_files: int = 0
    total_loc: int = 0
    avg_complexity: float = 0.0
    max_complexity: float = 0.0
    avg_churn: float = 0.0
    hotspot_count: int = 0        # Files with hotspot > threshold
    top_hotspots: list[tuple[str, float]] = field(default_factory=list)

    @classmethod
    def from_entries_and_stats(
        cls,
        entries: list[FileEntry],
        stats: list[GitStats],
        hotspot_threshold: float = 0.5,
        top_n: int = 10,
    ) -> ProjectMetrics:
        """Compute aggregate metrics from file entries and git stats."""
        if not entries:
            return cls()

        complexities = [e.complexity for e in entries]
        stats_by_path = {s.path: s for s in stats}
        churns = [stats_by_path[e.path].churn for e in entries if e.path in stats_by_path]

        sorted_hotspots = sorted(stats, key=lambda s: s.hotspot, reverse=True)
        above_threshold = [s for s in sorted_hotspots if s.hotspot > hotspot_threshold]

        return cls(
            total_files=len(entries),
            total_loc=sum(e.loc for e in entries),
            avg_complexity=sum(complexities) / len(complexities),
            max_complexity=max(complexities),
            avg_churn=sum(churns) / len(churns) if churns else 0.0,
            hotspot_count=len(above_threshold),
            top_hotspots=[(s.path, s.hotspot) for s in sorted_hotspots[:top_n]],
        )
