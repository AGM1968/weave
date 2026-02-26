"""CLI entry point for weave_quality scanner.

Usage:
  python -m weave_quality scan [path]           # Full or incremental scan
  python -m weave_quality scan --json           # JSON summary output
  python -m weave_quality hotspots              # Ranked hotspot report
  python -m weave_quality diff                  # Delta report vs previous scan
  python -m weave_quality functions [path]      # Per-function CC report
  python -m weave_quality functions [path] --json
  python -m weave_quality promote --top=N       # Promote findings to Weave nodes
  python -m weave_quality reset                 # Delete quality.db

Invoked by the Bash wrapper: wv-cmd-quality.sh
"""

from __future__ import annotations

import argparse
import hashlib
import json
import logging
import os
import subprocess
import sys
import time
from fnmatch import fnmatch
from pathlib import Path

from weave_quality.bash_heuristic import analyze_bash_file, detect_bash
from weave_quality.db import (
    begin_scan,
    bulk_upsert_co_changes,
    bulk_upsert_file_entries,
    bulk_upsert_function_cc,
    bulk_upsert_git_stats,
    db_exists,
    db_path,
    file_changed,
    finish_scan,
    get_all_trend_directions,
    get_file_entries,
    get_git_stats,
    init_db,
    latest_scan,
    previous_scan,
    reset_db,
    get_function_cc,
    staleness_info,
    top_hotspots,
    upsert_ck_metrics,
    upsert_complexity_trend,
    upsert_file_state,
)
from weave_quality.git_metrics import (
    batch_blob_shas,
    build_file_state,
    compute_co_changes,
    enrich_all_git_stats,
    git_head_sha,
)
from weave_quality.hotspots import (
    classify_complexity,
    classify_hotspot,
    compute_hotspots,
    compute_quality_score,
    hotspot_summary,
)
from weave_quality.models import FileEntry, FunctionCC
from weave_quality.python_parser import analyze_python_file

log = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Path resolution
# ---------------------------------------------------------------------------


def _load_config_excludes(repo: str) -> list[str]:
    """Read default exclude globs from .weave/quality.conf.

    Format: one glob per line, # comments, blank lines ignored.
    Only lines under [exclude] section are read.
    """
    conf = Path(repo) / ".weave" / "quality.conf"
    if not conf.exists():
        return []
    excludes: list[str] = []
    in_section = False
    for raw_line in conf.read_text().splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("["):
            in_section = line.lower() == "[exclude]"
            continue
        if in_section:
            excludes.append(line)
    return excludes


def _resolve_repo(path: str | None) -> str:
    """Resolve the target repository root.

    Uses the given path, or REPO_ROOT env, or git rev-parse.
    Critical: when run from earth-engine-analysis/, scanner must target
    THAT repo, not memory-system/ where wv is installed.
    """
    if path:
        return str(Path(path).resolve())

    repo_root = os.environ.get("REPO_ROOT", "")
    if repo_root:
        return repo_root

    # Git root of CWD
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            check=True,
        )
        return result.stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return os.getcwd()


# ---------------------------------------------------------------------------
# File discovery
# ---------------------------------------------------------------------------


def _discover_files(repo: str, exclude_globs: list[str] | None = None) -> list[str]:
    """Discover Python and Bash files in the repo.

    Uses git ls-files if available (respects .gitignore),
    falls back to filesystem walk.

    Args:
        repo: Repository root path.
        exclude_globs: Optional list of glob patterns to exclude (e.g., 'venv_ee/*').
    """
    files: list[str] = []

    try:
        result = subprocess.run(
            ["git", "ls-files", "--cached", "--others", "--exclude-standard"],
            capture_output=True,
            text=True,
            check=True,
            cwd=repo,
        )
        candidates = result.stdout.strip().splitlines()
    except (subprocess.CalledProcessError, FileNotFoundError):
        # Fallback: walk filesystem
        candidates = []
        for root, dirs, filenames in os.walk(repo):
            # Skip hidden dirs and common non-source dirs
            dirs[:] = [
                d for d in dirs
                if not d.startswith(".")
                and d not in ("node_modules", "__pycache__", ".git", "venv", ".venv")
            ]
            for fn in filenames:
                rel = os.path.relpath(os.path.join(root, fn), repo)
                candidates.append(rel)

    for rel_path in candidates:
        abs_path = os.path.join(repo, rel_path)
        if not os.path.isfile(abs_path):
            continue
        # Apply exclude globs
        if exclude_globs:
            if any(fnmatch(rel_path, g) for g in exclude_globs):
                continue
        if rel_path.endswith(".py"):
            files.append(rel_path)
        elif detect_bash(abs_path):
            files.append(rel_path)

    return sorted(files)


# ---------------------------------------------------------------------------
# Scan command
# ---------------------------------------------------------------------------


def cmd_scan(args: argparse.Namespace) -> int:
    """Execute wv quality scan."""
    repo = _resolve_repo(args.path)
    hot_zone = args.hot_zone
    json_output = args.json

    # Initialize DB (uses WV_HOT_ZONE env or explicit --hot-zone)
    conn = init_db(hot_zone)

    start_time = time.monotonic()

    # Merge config + CLI excludes
    cli_excludes: list[str] = getattr(args, 'exclude', [])
    config_excludes = _load_config_excludes(repo)
    all_excludes = config_excludes + cli_excludes

    # Discover files
    all_files = _discover_files(repo, exclude_globs=all_excludes)

    # Begin scan
    head = git_head_sha(repo)
    scan_id = begin_scan(conn, head)

    # Determine which files need re-scanning (incremental)
    # Single git ls-tree call replaces N per-file git_blob_sha calls
    blob_map = batch_blob_shas(repo)
    files_to_scan: list[str] = []
    files_unchanged: list[str] = []

    for rel_path in all_files:
        abs_path = os.path.join(repo, rel_path)
        # Get mtime and blob for staleness check
        try:
            mtime = int(os.path.getmtime(abs_path))
        except OSError:
            mtime = 0
        blob = blob_map.get(rel_path, "")
        if file_changed(conn, rel_path, mtime, blob):
            files_to_scan.append(rel_path)
        else:
            files_unchanged.append(rel_path)

    # Parse changed files
    entries: list[FileEntry] = []
    ck_metrics_list = []
    lang_counts: dict[str, int] = {}

    all_fn_cc: list[FunctionCC] = []

    for rel_path in files_to_scan:
        abs_path = os.path.join(repo, rel_path)
        if rel_path.endswith(".py"):
            entry, ck, fn_cc = analyze_python_file(
                abs_path, scan_id)
            entry = FileEntry(
                path=rel_path,
                scan_id=scan_id,
                language=entry.language,
                loc=entry.loc,
                complexity=entry.complexity,
                functions=entry.functions,
                max_nesting=entry.max_nesting,
                avg_fn_len=entry.avg_fn_len,
                essential_complexity=entry.essential_complexity,
                indent_sd=entry.indent_sd,
            )
            entries.append(entry)
            if ck is not None:
                ck.path = rel_path
                ck.scan_id = scan_id
                ck_metrics_list.append(ck)
            # Remap fn_cc paths to relative
            for fc in fn_cc:
                fc.path = rel_path
                fc.scan_id = scan_id
            all_fn_cc.extend(fn_cc)
        else:
            entry = analyze_bash_file(abs_path, scan_id)
            entry = FileEntry(
                path=rel_path,
                scan_id=scan_id,
                language=entry.language,
                loc=entry.loc,
                complexity=entry.complexity,
                functions=entry.functions,
                max_nesting=entry.max_nesting,
                avg_fn_len=entry.avg_fn_len,
                indent_sd=entry.indent_sd,
            )
            entries.append(entry)

        lang = "python" if rel_path.endswith(".py") else "bash"
        lang_counts[lang] = lang_counts.get(lang, 0) + 1

    # Save static analysis results
    bulk_upsert_file_entries(conn, entries)
    for ck in ck_metrics_list:
        upsert_ck_metrics(conn, ck)
    if all_fn_cc:
        bulk_upsert_function_cc(conn, all_fn_cc)

    # Carry forward unchanged file entries from previous scan
    prev = previous_scan(conn)
    if prev is not None and files_unchanged:
        prev_entries = get_file_entries(conn, prev.id)
        prev_by_path = {e.path: e for e in prev_entries}
        carried: list[FileEntry] = []
        for rel_path in files_unchanged:
            prev_e = prev_by_path.get(rel_path)
            if prev_e:
                carried.append(FileEntry(
                    path=prev_e.path,
                    scan_id=scan_id,
                    language=prev_e.language,
                    loc=prev_e.loc,
                    complexity=prev_e.complexity,
                    functions=prev_e.functions,
                    max_nesting=prev_e.max_nesting,
                    avg_fn_len=prev_e.avg_fn_len,
                    essential_complexity=(
                        prev_e.essential_complexity),
                    indent_sd=prev_e.indent_sd,
                ))
        if carried:
            bulk_upsert_file_entries(conn, carried)
            entries.extend(carried)
            # Carry forward file_metrics (fn_cc + CK rows) for unchanged files
            carried_paths = [c.path for c in carried]
            for rel_path in carried_paths:
                fm_rows = conn.execute(
                    "SELECT path, metric, value, detail FROM file_metrics"
                    " WHERE scan_id = ? AND path = ?",
                    (prev.id, rel_path),
                ).fetchall()
                for row in fm_rows:
                    conn.execute(
                        "INSERT OR IGNORE INTO file_metrics"
                        " (path, scan_id, metric, value, detail)"
                        " VALUES (?, ?, ?, ?, ?)",
                        (row[0], scan_id, row[1], row[2], row[3]),
                    )

    # Record complexity trend for all entries (for trend analysis)
    for e in entries:
        upsert_complexity_trend(
            conn, e.path, scan_id,
            e.complexity, e.essential_complexity)

    # Update file state for incremental tracking
    for rel_path in files_to_scan:
        fs = build_file_state(repo, rel_path, blob_map=blob_map)
        upsert_file_state(conn, fs)

    # Git metrics (computed globally, not scan-versioned)
    git_stats = enrich_all_git_stats(repo, [e.path for e in entries] + files_unchanged)
    co_changes = compute_co_changes(repo)

    # Compute hotspots
    all_scanned_entries = entries
    if git_stats:
        compute_hotspots(all_scanned_entries, git_stats)

    # Save git-derived data
    bulk_upsert_git_stats(conn, git_stats)
    bulk_upsert_co_changes(conn, co_changes)

    # Finish scan
    duration_ms = int((time.monotonic() - start_time) * 1000)
    finish_scan(conn, scan_id, len(entries) + len(files_unchanged), duration_ms)

    # Single commit point — entire scan is atomic
    conn.commit()
    conn.close()

    # Generate summary
    summary = hotspot_summary(all_scanned_entries, git_stats)

    if json_output:
        output = {
            "scan_id": scan_id,
            "git_head": head,
            "files_scanned": len(entries) + len(files_unchanged),
            "files_changed": len(files_to_scan),
            "languages": lang_counts,
            "duration_ms": duration_ms,
            "hotspots_above_threshold": summary.get("hotspot_count", 0),
            "quality_score": summary.get("quality_score", 100),
        }
        print(json.dumps(output))
    else:
        print(f"Scanning {repo}...", file=sys.stderr)
        for lang, count in sorted(lang_counts.items()):
            changed = sum(
                1 for f in files_to_scan
                if (f.endswith(".py") and lang == "python")
                or (not f.endswith(".py") and lang == "bash")
            )
            print(
                f"  {lang.title()}: {count} files ({changed} changed since last scan)",
                file=sys.stderr,
            )
        print(f"  Duration: {duration_ms / 1000:.1f}s", file=sys.stderr)
        print(
            f"  Hotspots: {summary.get('hotspot_count', 0)} files above threshold",
            file=sys.stderr,
        )
        print(f"\nQuality score: {summary.get('quality_score', 100)}/100", file=sys.stderr)

    return 0


# ---------------------------------------------------------------------------
# Hotspots command
# ---------------------------------------------------------------------------


def _get_current_head() -> str:
    """Get current git HEAD SHA, or empty string if not in a repo."""
    try:
        result = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            capture_output=True, text=True, check=True,
        )
        return result.stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return ""


_CC_THRESHOLD = 10  # CC above this level is flagged in `wv quality functions`


def cmd_functions(args: argparse.Namespace) -> int:  # noqa: PLR0912
    """Per-function CC report for a file or directory."""
    hot_zone = getattr(args, "hot_zone", None)
    if not db_exists(hot_zone):
        print("No quality.db — run 'wv quality scan' first.", file=sys.stderr)
        return 1
    conn = init_db(hot_zone)
    scan = latest_scan(conn)
    if scan is None:
        print("No scan data available.", file=sys.stderr)
        conn.close()
        return 1

    # Resolve input path → list of file paths (relative, as stored in DB)
    root = Path(args.path) if hasattr(args, "path") and args.path else Path(".")
    root = root.resolve()

    # Collect all candidate paths from the scan that match the requested prefix
    all_entries = get_file_entries(conn, scan.id)
    cwd = Path.cwd()
    target_paths: list[str] = []
    for entry in all_entries:
        # entry.path is relative to repo root (which is cwd for wv quality)
        entry_abs = (cwd / entry.path).resolve()
        try:
            entry_abs.relative_to(root)
            target_paths.append(entry.path)
        except ValueError:
            # Check if single file was specified exactly
            if root == entry_abs:
                target_paths.append(entry.path)

    if not target_paths:
        # Fallback: treat root as a path prefix string match
        root_str = str(root.relative_to(cwd)) if root.is_relative_to(cwd) else str(root)
        for entry in all_entries:
            if entry.path.startswith(root_str):
                target_paths.append(entry.path)

    if not target_paths:
        print(f"No scanned files found under {root}", file=sys.stderr)
        conn.close()
        return 1

    # Gather per-function CC for each path
    all_fns: list[FunctionCC] = []
    for p in sorted(target_paths):
        all_fns.extend(get_function_cc(conn, scan.id, p))
    conn.close()

    all_fns.sort(key=lambda f: f.complexity, reverse=True)

    if getattr(args, "json", False):
        output = [
            {
                "path": fn.path,
                "function": fn.function_name,
                "cc": fn.complexity,
                "ev": getattr(fn, "essential", None),
                "line_start": fn.line_start,
                "line_end": fn.line_end,
                "is_dispatch": fn.is_dispatch,
            }
            for fn in all_fns
        ]
        print(json.dumps(output, indent=2))
        return 0

    # Text output
    header = f"Functions in {root} (CC threshold: {_CC_THRESHOLD}):"
    print(header)
    print()

    exceeds = [f for f in all_fns if f.complexity > _CC_THRESHOLD]
    exempt = [f for f in exceeds if f.is_dispatch]
    flagged = [f for f in exceeds if not f.is_dispatch]

    for fn in all_fns:
        mark = "✗" if (fn.complexity > _CC_THRESHOLD and not fn.is_dispatch) else "✓"
        dispatch_tag = "  [dispatch — exempt]" if fn.is_dispatch else ""
        line_range = f"L:{fn.line_start}-{fn.line_end}" if fn.line_start else ""
        ev_str = ""
        print(
            f"  {mark} {fn.function_name:<30} CC={int(fn.complexity):<5}"
            f"{ev_str}  {line_range}{dispatch_tag}"
        )

    print()
    total = len(all_fns)
    n_flagged = len(flagged)
    n_exempt = len(exempt)
    exempt_note = f" ({n_exempt} dispatch-exempt)" if n_exempt else ""
    print(f"  Summary: {n_flagged}/{total} functions exceed threshold{exempt_note}")
    return 0


def cmd_hotspots(args: argparse.Namespace) -> int:
    """Execute wv quality hotspots -- ranked hotspot report."""
    hot_zone = args.hot_zone
    top_n: int = args.top
    json_output: bool = args.json

    if not db_exists(hot_zone):
        print("No quality.db found. Run 'wv quality scan' first.", file=sys.stderr)
        return 1

    conn = init_db(hot_zone)
    current_head = _get_current_head()

    # Staleness warning
    stale = staleness_info(conn, current_head)

    # Get latest scan data
    scan = latest_scan(conn)
    if scan is None:
        conn.close()
        print("No scan data. Run 'wv quality scan' first.", file=sys.stderr)
        return 1

    # Fetch hotspots from git_stats
    ranked = top_hotspots(conn, top_n)

    # Fetch file entries for the latest scan (for complexity info)
    entries = get_file_entries(conn, scan.id)
    entry_by_path = {e.path: e for e in entries}

    # Trend directions from complexity_trend history
    trend_dirs = get_all_trend_directions(conn)

    conn.close()

    if json_output:
        items = []
        for gs in ranked:
            entry = entry_by_path.get(gs.path)
            cc = entry.complexity if entry else 0.0
            ev = entry.essential_complexity if entry else 0.0
            isd = round(entry.indent_sd, 2) if entry else 0.0
            items.append({
                "path": gs.path,
                "hotspot": gs.hotspot,
                "complexity": cc,
                "essential_complexity": ev,
                "indent_sd": isd,
                "churn": gs.churn,
                "authors": gs.authors,
                "ownership_fraction": round(gs.ownership_fraction, 2),
                "minor_contributors": gs.minor_contributors,
                "trend_direction": trend_dirs.get(gs.path, "stable"),
                "severity": classify_hotspot(gs.hotspot),
            })
        output = {
            "stale": stale.get("stale", False),
            "scan_id": scan.id,
            "git_head": scan.git_head,
            "hotspots": items,
        }
        if stale.get("stale"):
            output["staleness_reason"] = stale.get("reason", "unknown")
        print(json.dumps(output))
    else:
        if stale.get("stale") and stale.get("reason") == "head_moved":
            print(
                f"[WARN] Scan is behind HEAD "
                f"({stale['scan_head']}..{stale['current_head']}) "
                "-- run 'wv quality scan' to refresh\n",
                file=sys.stderr,
            )

        if not ranked:
            print("No hotspots found above threshold.", file=sys.stderr)
        else:
            print("Hotspots (complexity x churn):", file=sys.stderr)
            for i, gs in enumerate(ranked, 1):
                entry = entry_by_path.get(gs.path)
                cc = entry.complexity if entry else 0.0
                ev = entry.essential_complexity if entry else 0.0
                trend = trend_dirs.get(gs.path, "stable")
                trend_sym = {"deteriorating": "↑", "refactored": "↓"
                             }.get(trend, "~")
                ev_str = f"  ev={ev:.0f}" if ev > 0 else ""
                print(
                    f"  {i}. {gs.path:<50s} "
                    f"hotspot={gs.hotspot:.2f}  CC={cc:.0f}{ev_str}  "
                    f"churn={gs.churn}  authors={gs.authors}  "
                    f"trend={trend_sym}",
                    file=sys.stderr,
                )

    return 0


# ---------------------------------------------------------------------------
# Diff command
# ---------------------------------------------------------------------------


def cmd_diff(args: argparse.Namespace) -> int:
    """Execute wv quality diff -- delta report vs previous scan."""
    hot_zone = args.hot_zone
    json_output: bool = args.json

    if not db_exists(hot_zone):
        print("No quality.db found. Run 'wv quality scan' first.", file=sys.stderr)
        return 1

    conn = init_db(hot_zone)

    current = latest_scan(conn)
    if current is None:
        conn.close()
        print("No scan data. Run 'wv quality scan' first.", file=sys.stderr)
        return 1

    prev = previous_scan(conn)
    if prev is None:
        conn.close()
        if json_output:
            print(json.dumps({
                "scan_current": current.id,
                "scan_previous": None,
                "improved": [],
                "degraded": [],
                "new_files": [],
                "removed_files": [],
                "quality_score_current": 0,
                "quality_score_previous": None,
            }))
        else:
            print(
                "No previous scan to diff against. "
                "Run 'wv quality scan' again after making changes.",
                file=sys.stderr,
            )
        return 0

    # Get file entries for both scans
    current_entries = get_file_entries(conn, current.id)
    prev_entries = get_file_entries(conn, prev.id)

    # Get git stats for quality score calculation
    all_git_stats = get_git_stats(conn)

    # Trend directions for changed files
    trend_dirs = get_all_trend_directions(conn)

    conn.close()

    # Index by path
    cur_by_path = {e.path: e for e in current_entries}
    prev_by_path = {e.path: e for e in prev_entries}

    # Compute quality scores
    cur_score = compute_quality_score(current_entries, all_git_stats)
    prev_score = compute_quality_score(prev_entries, all_git_stats)

    # Categorize file changes
    all_paths = sorted(set(cur_by_path.keys()) | set(prev_by_path.keys()))
    improved: list[dict[str, object]] = []
    degraded: list[dict[str, object]] = []
    new_files: list[dict[str, object]] = []
    removed_files: list[str] = []

    for path in all_paths:
        cur_e = cur_by_path.get(path)
        prev_e = prev_by_path.get(path)

        if cur_e and not prev_e:
            new_files.append({
                "path": path,
                "complexity": cur_e.complexity,
                "severity": classify_complexity(cur_e.complexity),
            })
        elif prev_e and not cur_e:
            removed_files.append(path)
        elif cur_e and prev_e:
            delta = cur_e.complexity - prev_e.complexity
            if abs(delta) < 0.5:
                continue  # No significant change
            item = {
                "path": path,
                "complexity_current": cur_e.complexity,
                "complexity_previous": prev_e.complexity,
                "delta": round(delta, 1),
                "trend_direction": trend_dirs.get(path, "stable"),
            }
            if delta < 0:
                improved.append(item)
            else:
                degraded.append(item)

    # Sort by magnitude of change
    improved.sort(key=lambda x: x["delta"])  # type: ignore[arg-type,return-value]
    degraded.sort(key=lambda x: x["delta"], reverse=True)  # type: ignore[arg-type,return-value]

    if json_output:
        output = {
            "scan_current": current.id,
            "scan_previous": prev.id,
            "improved": improved,
            "degraded": degraded,
            "new_files": new_files,
            "removed_files": removed_files,
            "quality_score_current": cur_score,
            "quality_score_previous": prev_score,
        }
        print(json.dumps(output))
    else:
        print(
            f"Quality delta (scan #{current.id} vs #{prev.id}):\n",
            file=sys.stderr,
        )

        if degraded:
            print("Degraded:", file=sys.stderr)
            for item in degraded:
                trend = str(item.get("trend_direction", "stable"))
                trend_sym = {"deteriorating": " ↑", "refactored": " ↓"}.get(
                    trend, "")
                print(
                    f"  {item['path']}: complexity "
                    f"{item['complexity_previous']} -> {item['complexity_current']} "
                    f"(+{item['delta']}){trend_sym}",
                    file=sys.stderr,
                )

        if improved:
            print("Improved:", file=sys.stderr)
            for item in improved:
                trend = str(item.get("trend_direction", "stable"))
                trend_sym = {"deteriorating": " ↑", "refactored": " ↓"}.get(
                    trend, "")
                print(
                    f"  {item['path']}: complexity "
                    f"{item['complexity_previous']} -> {item['complexity_current']} "
                    f"({item['delta']}){trend_sym}",
                    file=sys.stderr,
                )

        if new_files:
            print("New files:", file=sys.stderr)
            for item in new_files:
                print(
                    f"  {item['path']}: complexity={item['complexity']} "
                    f"({item['severity']})",
                    file=sys.stderr,
                )

        if removed_files:
            print("Removed files:", file=sys.stderr)
            for path in removed_files:
                print(f"  {path}", file=sys.stderr)

        if not (degraded or improved or new_files or removed_files):
            print("No significant changes.", file=sys.stderr)

        score_delta = cur_score - prev_score
        sign = "+" if score_delta > 0 else ""
        print(
            f"\nNet quality change: {sign}{score_delta} points "
            f"({prev_score} -> {cur_score})",
            file=sys.stderr,
        )

    return 0


# ---------------------------------------------------------------------------
# Promote command
# ---------------------------------------------------------------------------


def _finding_id(path: str, metric: str = "hotspot") -> str:
    """Compute idempotency key for a quality finding.

    Returns sha256(path + ":" + metric)[:12] for use as quality_finding_id.
    """
    return hashlib.sha256(f"{path}:{metric}".encode()).hexdigest()[:12]


def _wv_cmd(*cmd_args: str) -> tuple[int, str]:
    """Run a wv CLI command, return (returncode, stdout)."""
    try:
        result = subprocess.run(
            ["wv", *cmd_args],
            capture_output=True, text=True, check=False,
        )
        return result.returncode, result.stdout.strip()
    except FileNotFoundError:
        return 1, "wv command not found"


def cmd_promote(args: argparse.Namespace) -> int:
    """Execute wv quality promote -- create Weave nodes from top findings."""
    hot_zone = args.hot_zone
    top_n: int = args.top
    parent: str = args.parent
    json_output: bool = args.json
    dry_run: bool = args.dry_run

    if not parent:
        print("Error: --parent=<node-id> is required.", file=sys.stderr)
        return 1

    if not db_exists(hot_zone):
        print("No quality.db found. Run 'wv quality scan' first.", file=sys.stderr)
        return 1

    conn = init_db(hot_zone)
    scan = latest_scan(conn)
    if scan is None:
        conn.close()
        print("No scan data. Run 'wv quality scan' first.", file=sys.stderr)
        return 1

    ranked = top_hotspots(conn, top_n)
    entries = get_file_entries(conn, scan.id)
    entry_by_path = {e.path: e for e in entries}
    conn.close()

    if not ranked:
        print("No hotspots above threshold to promote.", file=sys.stderr)
        return 0

    # Check for existing promoted nodes (idempotency / upsert)
    upsert: bool = getattr(args, "upsert", False)
    rc, existing_json = _wv_cmd("list", "--json", "--all")
    existing_findings: dict[str, str] = {}  # fid -> node_id
    if rc == 0 and existing_json:
        try:
            for node in json.loads(existing_json):
                meta_str = node.get("metadata", "{}")
                if isinstance(meta_str, str):
                    meta = json.loads(meta_str)
                else:
                    meta = meta_str
                fid = meta.get("quality_finding_id", "")
                if fid:
                    existing_findings[fid] = node["id"]
        except (json.JSONDecodeError, TypeError):
            pass

    promoted: list[dict[str, object]] = []
    updated: list[dict[str, object]] = []
    skipped = 0

    for gs in ranked:
        fid = _finding_id(gs.path)
        if fid in existing_findings:
            if not upsert:
                skipped += 1
                continue
            # Upsert: update existing node with fresh scan data
            existing_id = existing_findings[fid]
            entry = entry_by_path.get(gs.path)
            cc = entry.complexity if entry else 0.0
            severity = classify_hotspot(gs.hotspot)
            code_ref = {
                "path": gs.path,
                "hotspot": gs.hotspot,
                "complexity": cc,
                "churn": gs.churn,
                "authors": gs.authors,
                "severity": severity,
            }
            new_text = f"Hotspot: {gs.path} (CC={cc:.0f}, churn={gs.churn})"
            new_meta = json.dumps({
                "quality_finding_id": fid,
                "code_ref": code_ref,
                "type": "quality-finding",
            })
            if dry_run:
                print(f"[DRY-RUN] Would update {existing_id}: {new_text}", file=sys.stderr)
                upd = {"node_id": existing_id, "text": new_text,
                       "finding_id": fid, **code_ref}
                updated.append(upd)
                continue
            _wv_cmd("update", existing_id,
                    f"--text={new_text}", f"--metadata={new_meta}")
            print(f"Updated {existing_id}: \"{new_text}\"",
                  file=sys.stderr)
            upd = {"node_id": existing_id, "text": new_text,
                   "finding_id": fid, **code_ref}
            updated.append(upd)
            continue

        entry = entry_by_path.get(gs.path)
        cc = entry.complexity if entry else 0.0
        severity = classify_hotspot(gs.hotspot)
        text = f"Hotspot: {gs.path} (CC={cc:.0f}, churn={gs.churn})"

        code_ref = {
            "path": gs.path,
            "hotspot": gs.hotspot,
            "complexity": cc,
            "churn": gs.churn,
            "authors": gs.authors,
            "severity": severity,
        }
        metadata = {
            "quality_finding_id": fid,
            "code_ref": code_ref,
            "type": "quality-finding",
        }

        if dry_run:
            print(f"[DRY-RUN] Would create: {text}", file=sys.stderr)
            print(f"  -> references {parent}", file=sys.stderr)
            promoted.append({"text": text, "finding_id": fid, **code_ref})
            continue

        # Create the node via wv add (no --parent: avoids implements edge)
        meta_json = json.dumps(metadata)
        rc, out = _wv_cmd(
            "add", text,
            f"--metadata={meta_json}",
            "--force",
        )
        if rc != 0:
            print(f"Error creating node for {gs.path}: {out}", file=sys.stderr)
            continue

        # Extract node ID from output (format: "wv-XXXXXX: text")
        node_id = ""
        for word in out.split():
            if word.startswith("wv-"):
                node_id = word.rstrip(":")
                break

        if node_id:
            # Create references edge only (informational, per proposal §6)
            _wv_cmd("link", node_id, parent, "--type=references")
            print(f"Created {node_id}: \"{text}\"", file=sys.stderr)
            print(f"  -> references {parent}", file=sys.stderr)
            promoted.append({
                "node_id": node_id, "text": text,
                "finding_id": fid, **code_ref,
            })

    if json_output:
        result: dict[str, object] = {
            "promoted": promoted,
            "skipped": skipped,
            "parent": parent,
        }
        if updated:
            result["updated"] = updated
        print(json.dumps(result))
    else:
        if updated:
            print(f"Updated {len(updated)} existing findings with fresh data.", file=sys.stderr)
        if skipped > 0:
            print(f"Skipped {skipped} already-promoted findings.", file=sys.stderr)
        if not promoted and not updated and not dry_run:
            print("No new findings to promote.", file=sys.stderr)

    return 0


# ---------------------------------------------------------------------------
# Health info command (for wv health integration)
# ---------------------------------------------------------------------------


def cmd_health_info(args: argparse.Namespace) -> int:
    """Output compact quality summary for wv health integration.

    Always outputs JSON to stdout.  If quality.db is missing or empty,
    returns {"available": false} so the caller can show 'no scan data'.
    """
    hot_zone = args.hot_zone

    if not db_exists(hot_zone):
        print(json.dumps({"available": False}))
        return 0

    conn = init_db(hot_zone)
    scan = latest_scan(conn)
    if scan is None:
        conn.close()
        print(json.dumps({"available": False}))
        return 0

    entries = get_file_entries(conn, scan.id)
    all_stats = get_git_stats(conn)
    conn.close()

    score = compute_quality_score(entries, all_stats)
    hotspot_count = sum(1 for s in all_stats if s.hotspot > 0.5)

    print(json.dumps({
        "available": True,
        "score": score,
        "hotspot_count": hotspot_count,
        "total_files": len(entries),
        "git_head": scan.git_head,
        "scanned_at": scan.scanned_at,
    }))
    return 0


# ---------------------------------------------------------------------------
# Context files command (for wv context integration)
# ---------------------------------------------------------------------------


def cmd_context_files(args: argparse.Namespace) -> int:
    """Return quality data for specific files, for wv context enrichment.

    Reads file paths from stdin (one per line).  For each file that has
    quality data in quality.db, outputs its hotspot score, complexity,
    and churn.  Also includes ``quality_as_of`` (git HEAD at last scan)
    so consumers can judge freshness.

    Always outputs JSON.  If quality.db is missing/empty or no paths
    are provided, returns ``{"code_quality": [], "quality_as_of": null}``.
    """
    hot_zone = args.hot_zone

    # Read paths from stdin
    paths: list[str] = []
    if not sys.stdin.isatty():
        for line in sys.stdin:
            stripped = line.strip()
            if stripped:
                paths.append(stripped)

    if not paths or not db_exists(hot_zone):
        print(json.dumps({"code_quality": [], "quality_as_of": None}))
        return 0

    conn = init_db(hot_zone)
    scan = latest_scan(conn)
    if scan is None:
        conn.close()
        print(json.dumps({"code_quality": [], "quality_as_of": None}))
        return 0

    results: list[dict[str, object]] = []
    for p in paths:
        # Get static analysis entry
        entries = get_file_entries(conn, scan.id, path=p)
        # Get git stats (not scan-versioned)
        stats_list = get_git_stats(conn, path=p)

        entry = entries[0] if entries else None
        stats = stats_list[0] if stats_list else None

        # Only include files that have at least some data
        if entry is not None or stats is not None:
            item: dict[str, object] = {"path": p}
            if stats is not None:
                item["hotspot"] = round(stats.hotspot, 2)
                item["churn"] = stats.churn
            if entry is not None:
                item["complexity"] = entry.complexity
            results.append(item)

    conn.close()

    print(json.dumps({
        "code_quality": results,
        "quality_as_of": scan.git_head,
    }))
    return 0


# ---------------------------------------------------------------------------
# Reset command
# ---------------------------------------------------------------------------


def cmd_reset(args: argparse.Namespace) -> int:
    """Execute wv quality reset -- delete quality.db."""
    hot_zone = args.hot_zone
    p = db_path(hot_zone)
    if p.exists():
        reset_db(hot_zone)
        print(f"Deleted {p}", file=sys.stderr)
    else:
        print(f"No quality.db found at {p}", file=sys.stderr)
    return 0


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main() -> int:
    """CLI entry point for weave_quality scanner."""
    parser = argparse.ArgumentParser(
        prog="weave_quality",
        description="Weave code quality scanner",
    )
    parser.add_argument(
        "--hot-zone",
        dest="hot_zone",
        help="WV_HOT_ZONE directory (default: from env or /dev/shm/weave)",
    )
    parser.add_argument(
        "--verbose", "-v",
        action="store_true",
        help="Enable debug logging",
    )

    sub = parser.add_subparsers(dest="command")

    # scan
    scan_parser = sub.add_parser("scan", help="Scan codebase for quality metrics")
    scan_parser.add_argument("path", nargs="?", help="Path to scan (default: repo root)")
    scan_parser.add_argument("--json", action="store_true", help="JSON output")
    scan_parser.add_argument("--exclude", action="append", default=[],
                             help="Exclude files matching glob (repeatable)")

    # hotspots
    hotspots_parser = sub.add_parser("hotspots", help="Ranked hotspot report")
    hotspots_parser.add_argument("--top", type=int, default=10,
                                 help="Number of results (default: 10)")
    hotspots_parser.add_argument("--json", action="store_true", help="JSON output")

    # diff
    diff_parser = sub.add_parser("diff", help="Delta report vs previous scan")
    diff_parser.add_argument("--json", action="store_true", help="JSON output")

    # promote
    promote_parser = sub.add_parser("promote", help="Promote findings to Weave nodes")
    promote_parser.add_argument("--top", type=int, default=5,
                                help="Number of findings (default: 5)")
    promote_parser.add_argument("--parent", required=True,
                                help="Parent node ID to link via references")
    promote_parser.add_argument("--json", action="store_true",
                                help="JSON output")
    promote_parser.add_argument("--upsert", action="store_true",
                                help="Update existing findings with fresh data")
    promote_parser.add_argument("--dry-run", action="store_true", help="Show what would be created")

    # health-info (for wv health integration)
    sub.add_parser("health-info", help="Compact quality summary for wv health")

    # context-files (for wv context integration)
    sub.add_parser("context-files", help="Quality data for files (reads paths from stdin)")

    # functions
    functions_parser = sub.add_parser(
        "functions",
        help="Per-function CC report for a file or directory",
    )
    functions_parser.add_argument(
        "path",
        nargs="?",
        default=None,
        help="File or directory to report on (default: entire codebase)",
    )
    functions_parser.add_argument("--json", action="store_true", help="JSON output")

    # reset
    sub.add_parser("reset", help="Delete quality.db for recovery")

    args = parser.parse_args()

    if args.verbose:
        logging.basicConfig(level=logging.DEBUG)
    else:
        logging.basicConfig(level=logging.WARNING)

    if args.command == "scan":
        return cmd_scan(args)
    if args.command == "hotspots":
        return cmd_hotspots(args)
    if args.command == "diff":
        return cmd_diff(args)
    if args.command == "promote":
        return cmd_promote(args)
    if args.command == "health-info":
        return cmd_health_info(args)
    if args.command == "context-files":
        return cmd_context_files(args)
    if args.command == "functions":
        return cmd_functions(args)
    if args.command == "reset":
        return cmd_reset(args)
    parser.print_help()
    return 1


if __name__ == "__main__":
    sys.exit(main())
