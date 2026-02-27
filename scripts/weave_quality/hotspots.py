"""Hotspot engine -- normalize(complexity) x normalize(churn).

Academic foundation: Adam Tornhill, "Software Design X-Rays" (2018).

A file that is both complex AND frequently changed is where bugs live.
This is the core scoring model for wv quality.

Thresholds (D2=Option A, hardcoded for v1.7.0):
  - Hotspot threshold: 0.5 (files above this are flagged)
  - CC critical: 30
  - CC warning: 15
"""

from __future__ import annotations

import logging
from typing import Any

from .models import FileEntry, FunctionCC, GitStats

log = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# D2 decision: hardcoded thresholds (Option A)
# ---------------------------------------------------------------------------

HOTSPOT_THRESHOLD = 0.5
CC_CRITICAL = 30
CC_WARNING = 15


# ---------------------------------------------------------------------------
# Normalization
# ---------------------------------------------------------------------------


def _normalize_values(values: list[float]) -> list[float]:
    """Min-max normalize a list of values to [0, 1].

    Returns all zeros if max == min (no variance).
    """
    if not values:
        return []
    lo = min(values)
    hi = max(values)
    if hi == lo:
        return [0.0] * len(values)
    return [(v - lo) / (hi - lo) for v in values]


# ---------------------------------------------------------------------------
# Hotspot computation
# ---------------------------------------------------------------------------


def compute_hotspots(entries: list[FileEntry],
                     stats: list[GitStats]) -> list[GitStats]:
    """Compute hotspot scores and update GitStats in place.

    Formula: hotspot = normalize(complexity) x normalize(churn)

    Requirements:
      - entries: FileEntry objects with complexity values (from parsers)
      - stats: GitStats objects with churn values (from git_metrics)

    Returns the updated GitStats list with hotspot scores filled in.
    Only files present in BOTH entries and stats get scored.
    """
    if not entries or not stats:
        return stats

    # Index by path
    entry_by_path = {e.path: e for e in entries}
    stats_by_path = {s.path: s for s in stats}

    # Find common paths (files with both static + git metrics)
    common_paths = sorted(set(entry_by_path.keys()) & set(stats_by_path.keys()))
    if not common_paths:
        return stats

    # Extract raw values for normalization
    complexities = [entry_by_path[p].complexity for p in common_paths]
    churns = [float(stats_by_path[p].churn) for p in common_paths]

    # Normalize independently
    norm_complexity = _normalize_values(complexities)
    norm_churn = _normalize_values(churns)

    # Compute hotspot = normalized_complexity x normalized_churn
    for i, path in enumerate(common_paths):
        score = norm_complexity[i] * norm_churn[i]
        stats_by_path[path].hotspot = round(score, 4)

    return stats


def rank_hotspots(stats: list[GitStats],
                  threshold: float = HOTSPOT_THRESHOLD,
                  top_n: int = 10) -> list[GitStats]:
    """Return top N hotspots above threshold, ranked by score descending."""
    above = [s for s in stats if s.hotspot > threshold]
    above.sort(key=lambda s: s.hotspot, reverse=True)
    return above[:top_n]


# ---------------------------------------------------------------------------
# CC Gini coefficient (complexity concentration)
# ---------------------------------------------------------------------------


def cc_gini(functions: list[FunctionCC]) -> float:
    """Gini coefficient of per-function CC values for a file.

    0.0 = all functions have equal CC (uniform complexity).
    1.0 = one function holds all complexity (maximum concentration).

    Returns 0.0 for files with 0 or 1 functions.
    """
    n = len(functions)
    if n <= 1:
        return 0.0
    ccs = sorted(f.complexity for f in functions)
    total = sum(ccs)
    if total == 0:
        return 0.0
    cumulative = sum((2 * (i + 1) - n - 1) * cc for i, cc in enumerate(ccs))
    return cumulative / (n * total)


# ---------------------------------------------------------------------------
# CC histogram (distribution buckets)
# ---------------------------------------------------------------------------

CC_HISTOGRAM_BUCKETS = [(1, 5), (6, 10), (11, 20), (21, None)]
CC_HISTOGRAM_LABELS = ["1-5", "6-10", "11-20", "21+"]


def cc_histogram(functions: list[FunctionCC]) -> list[int]:
    """Count functions per CC bucket: [1-5, 6-10, 11-20, 21+]."""
    counts = [0] * len(CC_HISTOGRAM_BUCKETS)
    for f in functions:
        cc = int(f.complexity)
        for i, (lo, hi) in enumerate(CC_HISTOGRAM_BUCKETS):
            if hi is None or cc <= hi:
                if cc >= lo:
                    counts[i] += 1
                    break
    return counts


# ---------------------------------------------------------------------------
# Severity classification
# ---------------------------------------------------------------------------


def classify_complexity(complexity: float) -> str:
    """Classify a file's complexity into severity level.

    Based on D2 thresholds (hardcoded, Option A):
      - critical: CC >= 30
      - warning: CC >= 15
      - ok: CC < 15
    """
    if complexity >= CC_CRITICAL:
        return "critical"
    if complexity >= CC_WARNING:
        return "warning"
    return "ok"


def classify_hotspot(hotspot: float) -> str:
    """Classify a hotspot score into severity level."""
    if hotspot > 0.75:
        return "critical"
    if hotspot > HOTSPOT_THRESHOLD:
        return "warning"
    return "ok"


# ---------------------------------------------------------------------------
# Quality score computation
# ---------------------------------------------------------------------------


def compute_quality_score(entries: list[FileEntry],
                          stats: list[GitStats]) -> int:
    """Compute an overall quality score (0-100).

    Score formula:
      - Start at 100
      - Deduct for each hotspot above threshold
      - Deduct for each file above CC critical
      - Deduct for each file above CC warning (smaller deduction)

    Clamped to [0, 100].
    """
    if not entries:
        return 100

    score = 100.0

    # Hotspot deductions
    hotspot_count = sum(1 for s in stats if s.hotspot > HOTSPOT_THRESHOLD)
    score -= hotspot_count * 5  # 5 points per hotspot

    # Complexity deductions
    for entry in entries:
        if entry.complexity >= CC_CRITICAL:
            score -= 3  # 3 points per critical file
        elif entry.complexity >= CC_WARNING:
            score -= 1  # 1 point per warning file

    return max(0, min(100, int(round(score))))


# ---------------------------------------------------------------------------
# Summary report data
# ---------------------------------------------------------------------------


def hotspot_summary(entries: list[FileEntry],
                    stats: list[GitStats],
                    top_n: int = 10) -> dict[str, Any]:
    """Generate a hotspot summary report dict.

    Used by both CLI output and --json mode.
    """
    entry_by_path = {e.path: e for e in entries}
    ranked = rank_hotspots(stats, top_n=top_n)

    items = []
    for gs in ranked:
        entry = entry_by_path.get(gs.path)
        items.append({
            "path": gs.path,
            "hotspot": gs.hotspot,
            "complexity": entry.complexity if entry else 0.0,
            "churn": gs.churn,
            "authors": gs.authors,
            "severity": classify_hotspot(gs.hotspot),
        })

    return {
        "hotspots": items,
        "total_files": len(entries),
        "hotspot_count": sum(1 for s in stats if s.hotspot > HOTSPOT_THRESHOLD),
        "quality_score": compute_quality_score(entries, stats),
    }
