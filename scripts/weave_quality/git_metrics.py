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


def batch_blob_shas(repo: str | Path) -> dict[str, str]:
    """Get blob SHAs for all tracked files in one git call.

    D3 decision: parse default ls-tree output for git version compatibility.
    Format: '<mode> <type> <sha>\\t<path>'

    Edge cases:
    - Empty repos (no HEAD): _git returns "", blob_map is empty.
    - Submodules: listed with type 'commit', won't match file paths.
    - Untracked files: not in ls-tree output, get("path", "") returns "".
    """
    out = _git(["ls-tree", "-r", "HEAD"], cwd=repo)
    blob_map: dict[str, str] = {}
    if not out:
        return blob_map
    for line in out.split("\n"):
        if "\t" not in line:
            continue
        meta, path = line.split("\t", 1)
        parts = meta.split()
        if len(parts) >= 3:
            blob_map[path] = parts[2]
    return blob_map


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


def _parse_co_change_log(
    log_output: str,
) -> tuple[Counter[tuple[str, str]], dict[str, Counter[str]]]:
    """Parse batched git log into co-change pair counts and per-file co-change maps.

    Returns:
        pair_counts: Counter of (path_a, path_b) sorted pairs across all commits.
        per_file: dict mapping each filepath to a Counter of co-changed files.

    Both structures are derived from a single parse pass so compute_co_changes
    and file_co_changes share the same data without additional subprocess calls.
    """
    pair_counts: Counter[tuple[str, str]] = Counter()
    per_file: dict[str, Counter[str]] = {}
    current_files: list[str] = []

    def _flush() -> None:
        files = sorted(set(current_files))
        for i, file_a in enumerate(files):
            for file_b in files[i + 1:]:
                pair_counts[(file_a, file_b)] += 1
        # Build per-file co-change map
        for f in files:
            if f not in per_file:
                per_file[f] = Counter()
            for other in files:
                if other != f:
                    per_file[f][other] += 1

    for line in log_output.split("\n"):
        if line.startswith("COMMIT_SEP"):
            _flush()
            current_files = []
        elif line.strip():
            current_files.append(line.strip())

    _flush()  # final commit
    return pair_counts, per_file


def compute_co_changes(repo: str | Path, top_n: int = 5) -> list[CoChange]:
    """Compute co-change pairs across the repo.

    D3 decision: bounded to last 500 commits or 6 months, whichever is less.
    D4 decision: --no-merges excludes merge commits that inflate pairs.
    Returns the top_n pairs by co-change count.

    Performance: single git log call replaces N per-SHA diff-tree calls
    (was ~500 subprocess spawns, now 1).
    """
    out = _git(
        ["log", f"-{_CO_CHANGE_MAX_COMMITS}", "--since=6 months ago",
         "--no-merges", "--format=COMMIT_SEP%n", "--name-only"],
        cwd=repo,
    )
    if not out:
        return []

    pair_counts, _per_file = _parse_co_change_log(out)
    # Cache per-file data for file_co_changes
    _co_change_cache[str(repo)] = _per_file

    return [
        CoChange(path_a=a, path_b=b, count=c)
        for (a, b), c in pair_counts.most_common(top_n)
    ]


# Module-level cache: populated by compute_co_changes, consumed by file_co_changes.
# Cleared implicitly when module reloads (per-process lifetime).
_co_change_cache: dict[str, dict[str, Counter[str]]] = {}


def file_co_changes(repo: str | Path, filepath: str, top_n: int = 5) -> list[str]:
    """Files most frequently changed in the same commits as filepath.

    Returns up to top_n file paths, excluding filepath itself.
    D3: bounded to last 500 commits or 6 months window.

    Performance: derives from compute_co_changes result when available,
    avoiding additional subprocess calls. Falls back to a single git log
    call if the cache is empty (e.g. called standalone).
    """
    repo_key = str(repo)

    # Try cached data from compute_co_changes
    if repo_key in _co_change_cache:
        co_files = _co_change_cache[repo_key].get(filepath, Counter())
        return [f for f, _ in co_files.most_common(top_n)]

    # Fallback: single git log call for this file's commits
    out = _git(
        ["log", f"-{_CO_CHANGE_MAX_COMMITS}", "--since=6 months ago",
         "--no-merges", "--format=COMMIT_SEP%n", "--name-only"],
        cwd=repo,
    )
    if not out:
        return []

    _, per_file = _parse_co_change_log(out)
    co_files = per_file.get(filepath, Counter())
    return [f for f, _ in co_files.most_common(top_n)]


# ---------------------------------------------------------------------------
# File state for incremental scanning
# ---------------------------------------------------------------------------


def build_file_state(
    repo: str | Path,
    filepath: str,
    blob_map: dict[str, str] | None = None,
) -> FileState:
    """Build a FileState record for incremental scan tracking.

    When blob_map is provided (from batch_blob_shas), avoids a subprocess call.
    """
    full_path = Path(repo) / filepath
    mtime = int(full_path.stat().st_mtime) if full_path.exists() else 0
    blob = blob_map.get(filepath, "") if blob_map else git_blob_sha(repo, filepath)
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

    # Parse: track churn, per-author commit counts, and last-modified date per file
    # author_counts doubles as ownership data — no re-parse needed.
    author_counts: dict[str, Counter[str]] = {}
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
            if fp not in author_counts:
                author_counts[fp] = Counter()
            if current_author:
                author_counts[fp][current_author] += 1
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

        # Derive ownership directly from author_counts — no re-parse
        counts = author_counts.get(fp, Counter())
        file_churn_count = sum(counts.values())
        ownership_fraction, minor_count = _compute_ownership_from_counts(counts)

        results[fp] = GitStats(
            path=fp,
            churn=file_churn_count,
            authors=len(counts),
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


def _compute_ownership_from_counts(
    author_counts: Counter[str],
) -> tuple[float, int]:
    """Compute ownership_fraction and minor_contributors from pre-built counts.

    D5 decision: minor_contributors only meaningful when authors >= 3.
    Returns (ownership_fraction, minor_contributors).
    Ownership fraction = 1.0 for single/zero-author files (no risk).
    """
    if not author_counts or len(author_counts) <= 1:
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
