"""Git-derived metrics for Weave quality.

Extracts churn, age, authors, and co-change data via subprocess + git CLI.
Zero external dependencies beyond Python stdlib.

Design decisions (from PROPOSAL-wv-quality.md):
  - D3: Co-change window = last 6 months or 500 commits, whichever is less.
  - Git stats are NOT scan-versioned -- always represent current state.
  - Co-change pairs are stored as (path_a, path_b, count) in a separate table.
"""

from __future__ import annotations

import logging
import subprocess
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

from .models import CoChange, FileState, GitStats

log = logging.getLogger(__name__)

# D3: bounded window for co-change analysis
_CO_CHANGE_MAX_COMMITS = 500

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _git(args: list[str], cwd: str | Path) -> str:
    """Run a git command, return stdout. Returns empty string on failure."""
    try:
        result = subprocess.run(
            ["git"] + args,
            cwd=str(cwd),
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        if result.returncode != 0:
            return ""
        return result.stdout.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return ""


def git_head_sha(repo: str | Path) -> str:
    """Get the current HEAD SHA."""
    return _git(["rev-parse", "HEAD"], cwd=repo)


def git_blob_sha(repo: str | Path, filepath: str) -> str:
    """Get the blob SHA for a file at HEAD (empty string if untracked)."""
    return _git(["rev-parse", f"HEAD:{filepath}"], cwd=repo)


# ---------------------------------------------------------------------------
# Per-file metrics -> GitStats
# ---------------------------------------------------------------------------


def file_churn(repo: str | Path, filepath: str) -> int:
    """Total commit count touching this file."""
    out = _git(["rev-list", "--count", "HEAD", "--", filepath], cwd=repo)
    try:
        return int(out)
    except ValueError:
        return 0


def file_age_days(repo: str | Path, filepath: str) -> int:
    """Days since last modification (matches git_stats.age_days in proposal)."""
    out = _git(["log", "-1", "--format=%aI", "--", filepath], cwd=repo)
    if not out:
        return 0
    try:
        last_date = datetime.fromisoformat(out.strip())
        delta = datetime.now(timezone.utc) - last_date
        return max(0, delta.days)
    except (ValueError, TypeError):
        return 0


def file_authors(repo: str | Path, filepath: str) -> int:
    """Distinct author count for this file."""
    out = _git(["log", "--format=%aN", "--", filepath], cwd=repo)
    if not out:
        return 0
    authors = set(line.strip() for line in out.split("\n") if line.strip())
    return len(authors)


def build_git_stats(repo: str | Path, filepath: str) -> GitStats:
    """Build a complete GitStats record for a file.

    The hotspot field is left at 0.0 -- it's computed by the hotspots engine
    after combining with static complexity metrics.
    """
    return GitStats(
        path=filepath,
        churn=file_churn(repo, filepath),
        authors=file_authors(repo, filepath),
        age_days=file_age_days(repo, filepath),
        hotspot=0.0,  # Set by hotspots engine
    )


# ---------------------------------------------------------------------------
# Co-change analysis (D3: bounded window)
# ---------------------------------------------------------------------------


def compute_co_changes(repo: str | Path, top_n: int = 5) -> list[CoChange]:
    """Compute co-change pairs across the repo.

    D3 decision: bounded to last 500 commits or 6 months, whichever is less.
    Returns the top_n pairs by co-change count.
    """
    # Get SHAs within the bounded window
    sha_out = _git(
        ["log", f"-{_CO_CHANGE_MAX_COMMITS}", "--since=6 months ago",
         "--format=%H"],
        cwd=repo,
    )
    if not sha_out:
        return []

    shas = [s.strip() for s in sha_out.split("\n") if s.strip()]
    if not shas:
        return []

    # For each commit, collect all changed files
    pair_counts: Counter[tuple[str, str]] = Counter()
    for sha in shas:
        files_out = _git(["diff-tree", "--no-commit-id", "--name-only", "-r", sha], cwd=repo)
        if not files_out:
            continue
        files = sorted(set(f.strip() for f in files_out.split("\n") if f.strip()))
        # Generate all pairs (sorted to ensure path_a < path_b)
        for i, file_a in enumerate(files):
            for file_b in files[i + 1:]:
                pair_counts[(file_a, file_b)] += 1

    # Return top pairs
    return [
        CoChange(path_a=a, path_b=b, count=c)
        for (a, b), c in pair_counts.most_common(top_n)
    ]


def file_co_changes(repo: str | Path, filepath: str, top_n: int = 5) -> list[str]:
    """Files most frequently changed in the same commits as filepath.

    Returns up to top_n file paths, excluding filepath itself.
    D3: bounded to last 500 commits or 6 months window.
    """
    sha_out = _git(
        ["log", f"-{_CO_CHANGE_MAX_COMMITS}", "--since=6 months ago",
         "--format=%H", "--", filepath],
        cwd=repo,
    )
    if not sha_out:
        return []

    shas = [s.strip() for s in sha_out.split("\n") if s.strip()]
    if not shas:
        return []

    co_files: Counter[str] = Counter()
    for sha in shas:
        files_out = _git(["diff-tree", "--no-commit-id", "--name-only", "-r", sha], cwd=repo)
        if files_out:
            for f in files_out.split("\n"):
                f = f.strip()
                if f and f != filepath:
                    co_files[f] += 1

    return [f for f, _ in co_files.most_common(top_n)]


# ---------------------------------------------------------------------------
# File state for incremental scanning
# ---------------------------------------------------------------------------


def build_file_state(repo: str | Path, filepath: str) -> FileState:
    """Build a FileState record for incremental scan tracking."""
    full_path = Path(repo) / filepath
    mtime = int(full_path.stat().st_mtime) if full_path.exists() else 0
    blob = git_blob_sha(repo, filepath)
    return FileState(path=filepath, mtime=mtime, git_blob=blob)


# ---------------------------------------------------------------------------
# Batch operations
# ---------------------------------------------------------------------------


def enrich_all_git_stats(repo: str | Path,
                         file_paths: list[str]) -> list[GitStats]:
    """Build GitStats for a list of file paths.

    Logs progress every 50 files for large repos.
    """
    total = len(file_paths)
    results: list[GitStats] = []
    for i, fp in enumerate(file_paths):
        if total > 50 and (i + 1) % 50 == 0:
            log.info("Git stats: %d/%d files", i + 1, total)
        results.append(build_git_stats(repo, fp))
    return results
