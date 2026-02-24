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


def _batch_git_stats(repo: str | Path,
                     file_paths: list[str]) -> dict[str, GitStats]:
    """Build GitStats for all files in a single git log pass.

    Instead of 3 subprocess calls per file (N*3 total), uses ONE
    git log --name-only pass to extract churn, authors, and age.
    Reduces 432 subprocess calls to 1 for a 144-file repo.
    """
    target_files = set(file_paths)

    # Single pass: get all commits with author and date, plus changed files
    # Format: "COMMIT_SEP<tab>author<tab>date" followed by blank line + filenames
    out = _git(
        ["log", "--format=COMMIT_SEP\t%aN\t%aI", "--name-only"],
        cwd=repo,
    )
    if not out:
        return {
            fp: GitStats(path=fp, churn=0, authors=0, age_days=0, hotspot=0.0)
            for fp in file_paths
        }

    # Parse: track churn, authors, and last-modified date per file
    churn: dict[str, int] = {}
    authors: dict[str, set[str]] = {}
    last_date: dict[str, datetime] = {}

    current_author = ""
    current_date_str = ""

    for line in out.split("\n"):
        if line.startswith("COMMIT_SEP\t"):
            parts = line.split("\t", 2)
            current_author = parts[1] if len(parts) > 1 else ""
            current_date_str = parts[2] if len(parts) > 2 else ""
        elif line.strip():
            fp = line.strip()
            if fp not in target_files:
                continue
            churn[fp] = churn.get(fp, 0) + 1
            if current_author:
                if fp not in authors:
                    authors[fp] = set()
                authors[fp].add(current_author)
            # git log is reverse-chronological; first occurrence = most recent
            if fp not in last_date and current_date_str:
                try:
                    last_date[fp] = datetime.fromisoformat(current_date_str)
                except (ValueError, TypeError):
                    pass

    now = datetime.now(timezone.utc)
    results: dict[str, GitStats] = {}
    for fp in file_paths:
        age = 0
        if fp in last_date:
            delta = now - last_date[fp]
            age = max(0, delta.days)

        # Compute ownership metrics from per-author commit counts
        author_set = authors.get(fp, set())
        file_churn_count = churn.get(fp, 0)
        ownership_fraction, minor_count = _compute_ownership(
            fp, author_set, file_churn_count, out)

        results[fp] = GitStats(
            path=fp,
            churn=file_churn_count,
            authors=len(author_set),
            age_days=age,
            hotspot=0.0,
            ownership_fraction=ownership_fraction,
            minor_contributors=minor_count,
        )
    return results


# Minor contributor threshold: authors contributing < 5% of commits
_MINOR_THRESHOLD = 0.05
# D5: only meaningful when authors >= 3 (Tornhill recommendation)
_OWNERSHIP_MIN_AUTHORS = 3


def _compute_ownership(
    filepath: str,
    author_set: set[str],
    total_commits: int,
    git_log_out: str,
) -> tuple[float, int]:
    """Compute ownership_fraction and minor_contributors for a file.

    D5 decision: minor_contributors only meaningful when authors >= 3.
    Returns (ownership_fraction, minor_contributors).
    Ownership fraction = 1.0 for single-author files (no risk).
    """
    if total_commits == 0 or not author_set:
        return 1.0, 0

    if len(author_set) == 1:
        return 1.0, 0  # sole owner = full ownership, no minor contributors

    # Count commits per author for this file by re-parsing the log output
    author_counts: Counter[str] = Counter()
    current_author_local = ""
    in_file_commit = False

    for line in git_log_out.split("\n"):
        if line.startswith("COMMIT_SEP\t"):
            parts = line.split("\t", 2)
            current_author_local = parts[1] if len(parts) > 1 else ""
            in_file_commit = False
        elif line.strip() == filepath:
            in_file_commit = True
        elif line.strip() and in_file_commit:
            # Different file in same commit — reset flag
            in_file_commit = False
        elif in_file_commit and current_author_local:
            # Already counted via filepath match; use simpler approach below
            pass

    # Simpler and more accurate: count author occurrences in commits for this file
    # Re-walk: for each commit that touches filepath, count the author
    author_counts = Counter()
    cur_author = ""
    touched = False
    for line in git_log_out.split("\n"):
        if line.startswith("COMMIT_SEP\t"):
            if touched and cur_author:
                author_counts[cur_author] += 1
            parts = line.split("\t", 2)
            cur_author = parts[1] if len(parts) > 1 else ""
            touched = False
        elif line.strip() == filepath:
            touched = True
    # Flush last commit
    if touched and cur_author:
        author_counts[cur_author] += 1

    if not author_counts:
        return 1.0, 0

    top_author_commits = author_counts.most_common(1)[0][1]
    actual_total = sum(author_counts.values())
    ownership_frac = top_author_commits / actual_total if actual_total > 0 else 1.0

    # D5: only flag minor contributors when significant multi-author history
    if len(author_counts) < _OWNERSHIP_MIN_AUTHORS:
        minor_count = 0
    else:
        minor_count = sum(
            1 for cnt in author_counts.values()
            if (cnt / actual_total) < _MINOR_THRESHOLD
        )

    return ownership_frac, minor_count


def enrich_all_git_stats(repo: str | Path,
                         file_paths: list[str]) -> list[GitStats]:
    """Build GitStats for a list of file paths.

    Uses a single-pass batch strategy (1 subprocess call) instead of
    3 calls per file. Falls back to per-file mode on batch failure.
    """
    if not file_paths:
        return []

    try:
        batch = _batch_git_stats(repo, file_paths)
        return [batch[fp] for fp in file_paths if fp in batch]
    except (subprocess.SubprocessError, OSError, ValueError, KeyError):
        log.warning("Batch git stats failed, falling back to per-file mode")
        total = len(file_paths)
        results: list[GitStats] = []
        for i, fp in enumerate(file_paths):
            if total > 50 and (i + 1) % 50 == 0:
                log.info("Git stats: %d/%d files", i + 1, total)
            results.append(build_git_stats(repo, fp))
        return results
