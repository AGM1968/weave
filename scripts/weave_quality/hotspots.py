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

# NOTE: hotspot scores are min-max normalised per scan, so HOTSPOT_THRESHOLD
# is an *absolute* cutoff on a *relative* scale.  Adding or removing one
# extreme outlier file shifts all scores and can toggle files across the
# threshold without any code change.  This is acceptable for the two-repo
# calibration basis but may need a percentile-based threshold for larger,
# more heterogeneous repos.
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


def compute_hotspots(entries: list[FileEntry], stats: list[GitStats]) -> list[GitStats]:
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


def rank_hotspots(
    stats: list[GitStats], threshold: float = HOTSPOT_THRESHOLD, top_n: int = 10
) -> list[GitStats]:
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
            if (hi is None or cc <= hi) and cc >= lo:
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


def compute_quality_score(
    entries: list[FileEntry],
    stats: list[GitStats],
    fn_cc_list: list[FunctionCC] | None = None,
    scope: str = "production",
) -> int:
    """Compute quality score (0-100) using a graduated per-function model.

    Score components:
      1. Per-function CC penalty — 0.5/point over CC=10, cap 8/fn
      2. Essential complexity penalty — ev > 4 threshold, 0.5/point cap 3
      3. Hotspot penalty — 5 points per file above hotspot threshold
      4. Gini concentration penalty — 1 point per file with skewed CC dist

    Scope filtering is applied to entries, stats, and fn_cc so the score
    reflects only the requested file category.

    No density normalization: penalties are applied at face value so that
    repos with more absolute problems score lower, regardless of repo size.
    """
    # Scope filter entries
    scoped = [e for e in entries if _entry_in_scope(e, scope)]
    if not scoped:
        return 100

    scoped_paths = {e.path for e in scoped}
    fns = [f for f in (fn_cc_list or []) if f.path in scoped_paths]
    scoped_stats = [s for s in stats if s.path in scoped_paths]

    score = 100.0

    # 1. Per-function CC penalty (dispatch-exempt)
    for fn in fns:
        if fn.is_dispatch:
            continue
        if fn.complexity > 10:
            excess = fn.complexity - 10
            score -= min(excess * 0.5, 8.0)

    # 2. Essential complexity penalty (ev > 4 = McCabe "troublesome")
    for entry in scoped:
        if entry.essential_complexity > 4:
            score -= min((entry.essential_complexity - 4) * 0.5, 3.0)

    # 3. Hotspot penalty
    for stat in scoped_stats:
        if stat.hotspot > HOTSPOT_THRESHOLD:
            score -= 5

    # 4. Gini concentration penalty (per-file, threshold 0.7)
    # Minimum N=4: max Gini for N=3 is (N-1)/N = 0.667 < 0.7, so the threshold
    # is mathematically unreachable for 3-function files.  N=4 gives max 0.75.
    fns_by_path: dict[str, list[FunctionCC]] = {}
    for fn in fns:
        fns_by_path.setdefault(fn.path, []).append(fn)
    for path_fns in fns_by_path.values():
        if len(path_fns) >= 4 and cc_gini(path_fns) > 0.7:
            score -= 1.0

    return max(0, min(100, int(round(score))))


def _entry_in_scope(entry: FileEntry, scope: str) -> bool:
    """Check if a FileEntry matches the requested scope."""
    if scope == "all":
        return True
    return getattr(entry, "category", "production") == scope


# ---------------------------------------------------------------------------
# Summary report data
# ---------------------------------------------------------------------------


def hotspot_summary(
    entries: list[FileEntry],
    stats: list[GitStats],
    fn_cc_list: list[FunctionCC] | None = None,
    top_n: int = 10,
) -> dict[str, Any]:
    """Generate a hotspot summary report dict.

    Used by both CLI output and --json mode.
    """
    entry_by_path = {e.path: e for e in entries}
    ranked = rank_hotspots(stats, top_n=top_n)

    items = []
    for gs in ranked:
        entry = entry_by_path.get(gs.path)
        items.append(
            {
                "path": gs.path,
                "hotspot": gs.hotspot,
                "complexity": entry.complexity if entry else 0.0,
                "churn": gs.churn,
                "authors": gs.authors,
                "severity": classify_hotspot(gs.hotspot),
            }
        )

    return {
        "hotspots": items,
        "total_files": len(entries),
        "hotspot_count": sum(1 for s in stats if s.hotspot > HOTSPOT_THRESHOLD),
        "quality_score": compute_quality_score(entries, stats, fn_cc_list),
    }
