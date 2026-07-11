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
from collections import Counter
import configparser
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import logging
import os
import sqlite3
import subprocess
import sys
import time
from fnmatch import fnmatch
from pathlib import Path
import tempfile

from weave_quality.ast_cache import ASTCache
from weave_quality.bash_ast_grep import analyze_bash_file_best, ast_grep_available, batch_cc_lines
from weave_quality.bash_heuristic import detect_bash
from weave_quality.classification import classify_file, load_classify_overrides
from weave_quality.external_tools import ast_grep_bin
from weave_quality.typescript_parser import analyze_typescript_file
from weave_quality.db import (
    begin_scan,
    bulk_insert_pattern_findings,
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
    pattern_findings_summary,
    previous_scan,
    reset_db,
    get_all_function_cc,
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
    CC_HISTOGRAM_LABELS,
    cc_gini,
    cc_histogram,
    classify_complexity,
    classify_hotspot,
    compute_hotspots,
    compute_quality_score,
    count_hotspots,
    hotspot_summary,
)
from weave_quality.findings import cmd_findings_promote
from weave_quality.models import CKMetrics, FileEntry, FunctionCC, GitStats, PatternFinding
from weave_quality.prose_rules import PROSE_LANGUAGES, rule_language, run_prose_rule
from weave_quality.python_parser import analyze_python_file

log = logging.getLogger(__name__)

__all__ = ["cmd_findings_promote"]

_VERSION_FILE = Path(__file__).parent.parent / "lib" / "VERSION"
_SCANNER_VERSION = _VERSION_FILE.read_text().strip() if _VERSION_FILE.exists() else ""
_MSG_NO_DB = "No quality.db found. Run 'wv quality scan' first."
_MSG_NO_SCAN = "No scan data. Run 'wv quality scan' first."
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
            # Strip inline comments (e.g. "dist/**  # build output" → "dist/**")
            line = line.split("#", 1)[0].strip()
            if line:
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
        cwd = os.getcwd()
        # Reject home dir — same boundary as wv-config.sh; scanner from ~ is meaningless.
        if cwd == os.path.expanduser("~") or cwd in ("/root",):
            return ""
        return cwd


# ---------------------------------------------------------------------------
# File discovery
# ---------------------------------------------------------------------------

# Extensions that can never be bash/shell scripts — skip shebang check entirely.
# Generated from observed repo noise (2945 .sql delta files alone caused ~0.36s
# overhead per incremental scan via unnecessary file opens in detect_bash).
_NON_SCRIPT_EXTS: frozenset[str] = frozenset(
    {
        "sql",
        "md",
        "json",
        "yaml",
        "yml",
        "toml",
        "cfg",
        "ini",
        "txt",
        "pdf",
        "png",
        "jpg",
        "jpeg",
        "gif",
        "svg",
        "ico",
        "csv",
        "html",
        "css",
        "xml",
        "rst",
        "lock",
        "log",
        "db",
        "jsonl",
        "tsv",
        "gitignore",
        "gitattributes",
        "prettierrc",
        "eslintrc",
        "shellcheckrc",
        "sembleignore",
        "properties",
    }
)


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
    except (subprocess.CalledProcessError, FileNotFoundError):  # pragma: no cover
        # Fallback: walk filesystem
        candidates = []
        for root, dirs, filenames in os.walk(repo):
            # Skip hidden dirs and common non-source dirs
            dirs[:] = [
                d
                for d in dirs
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
        if exclude_globs and any(fnmatch(rel_path, g) for g in exclude_globs):
            continue
        if rel_path.endswith(".py") or rel_path.endswith((".ts", ".tsx")):
            files.append(rel_path)
        else:
            # Fast-reject known non-script extensions before opening the file.
            dot = rel_path.rfind(".")
            if dot != -1 and rel_path[dot + 1 :].lower() in _NON_SCRIPT_EXTS:
                continue
            if detect_bash(abs_path):
                files.append(rel_path)

    return sorted(files)


# ---------------------------------------------------------------------------
# Scope filter
# ---------------------------------------------------------------------------


def _in_scope(entry: FileEntry, scope: str) -> bool:
    """Return True if entry falls within the given scope.

    Args:
        entry: A FileEntry with a ``category`` attribute (e.g. "production").
        scope: Target scope string. Pass ``"all"`` to include every category.

    Returns:
        True when ``scope == "all"`` or ``entry.category == scope``.
    """
    return scope in ("all", entry.category)


def _in_scope_path(
    path: str,
    scope: str,
    overrides: dict[str, list[str]] | None = None,
) -> bool:
    """Return True if a file path falls within the given scope.

    Classifies ``path`` via :func:`~weave_quality.classification.classify_file`
    and delegates to :func:`_in_scope`.

    Args:
        path: Relative path from the repo root (e.g. ``src/app.py``).
        scope: Target scope string. Pass ``"all"`` to include every category.
        overrides: Optional classification overrides dict (see
            :func:`~weave_quality.classification.load_classify_overrides`).

    Returns:
        True when the classified category matches ``scope``, or scope is ``"all"``.
    """
    category = classify_file(path, overrides)
    entry = FileEntry(path=path, category=category)
    return _in_scope(entry, scope)


# ---------------------------------------------------------------------------
# Scan helpers
# ---------------------------------------------------------------------------


def _scan_files(
    repo: str,
    files_to_scan: list[str],
    scan_id: int,
    classify_overrides: dict[str, list[str]] | None,
    blob_map: dict[str, str] | None = None,
    ast_cache: "ASTCache | None" = None,
) -> tuple[list[FileEntry], list[CKMetrics], list[FunctionCC], dict[str, int], str, str]:
    """Analyze each file and return (entries, ck_metrics_list, fn_cc_list, lang_counts,
    bash_backend, ts_backend).

    bash_backend: 'ast-grep' when all bash files used ast-grep,
                  'regex' when none did (binary absent), 'ast-grep+fallback' when mixed.
    ts_backend:   'ast-grep' when all TS files succeeded, 'unavailable' when none did,
                  'ast-grep+fallback' when some files fell back (returned None).
    """
    entries: list[FileEntry] = []
    ck_metrics_list: list[CKMetrics] = []
    all_fn_cc: list[FunctionCC] = []
    lang_counts: dict[str, int] = {}
    bash_backends_used: set[str] = set()
    ts_seen = 0
    ts_succeeded = 0

    # Pre-batch bash CC analysis: one ast-grep subprocess for all bash files
    # instead of one per file. Falls back gracefully per-file when batch fails.
    bash_abs_paths = [
        os.path.join(repo, rel)
        for rel in files_to_scan
        if not rel.endswith((".py", ".ts", ".tsx"))
    ]
    _batch_cc: dict[str, list[int]] | None = batch_cc_lines(bash_abs_paths) if bash_abs_paths else None

    for rel_path in files_to_scan:
        abs_path = os.path.join(repo, rel_path)
        if rel_path.endswith(".py"):
            category = classify_file(rel_path, classify_overrides)
            blob_sha = blob_map.get(rel_path, "") if blob_map else ""
            cached = ast_cache.get(blob_sha, rel_path, scan_id, category) if ast_cache else None
            if cached is not None:
                entry, ck, fn_cc = cached
            else:
                entry, ck, fn_cc = analyze_python_file(abs_path, scan_id)
                if ast_cache and blob_sha:
                    ast_cache.put(blob_sha, entry, ck, fn_cc)
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
                    category=category,
                )
            if ck is not None:
                ck.path = rel_path
                ck.scan_id = scan_id
                ck_metrics_list.append(ck)
            for fc in fn_cc:
                fc.path = rel_path
                fc.scan_id = scan_id
            all_fn_cc.extend(fn_cc)
            lang_counts["python"] = lang_counts.get("python", 0) + 1
        elif rel_path.endswith((".ts", ".tsx")):
            ts_seen += 1
            ts_result = analyze_typescript_file(abs_path, scan_id)
            if ts_result is None:
                log.warning("typescript_parser unavailable for %s — skipping", rel_path)
                continue
            ts_succeeded += 1
            entry, fn_cc = ts_result
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
                category=classify_file(rel_path, classify_overrides),
            )
            for fc in fn_cc:
                fc.path = rel_path
                fc.scan_id = scan_id
            all_fn_cc.extend(fn_cc)
            lang_counts["typescript"] = lang_counts.get("typescript", 0) + 1
        else:
            entry, fn_cc, _used_backend = analyze_bash_file_best(abs_path, scan_id, batch_cc=_batch_cc)
            bash_backends_used.add(_used_backend)
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
                category=classify_file(rel_path, classify_overrides),
            )
            for fc in fn_cc:
                fc.path = rel_path
                fc.scan_id = scan_id
            all_fn_cc.extend(fn_cc)
            lang_counts["bash"] = lang_counts.get("bash", 0) + 1
        entries.append(entry)

    if not bash_backends_used:
        # No bash files scanned this run (incremental — all unchanged).
        # Report the binary's availability as the effective backend.
        bash_backend_agg = "ast-grep (no changes)" if ast_grep_bin() else "regex (no changes)"
    elif bash_backends_used == {"regex"}:
        bash_backend_agg = "regex"
    elif bash_backends_used == {"ast-grep"}:
        bash_backend_agg = "ast-grep"
    else:
        bash_backend_agg = "ast-grep+fallback"

    if ts_seen == 0 or ts_succeeded == 0:
        ts_backend_agg = "unavailable"
    elif ts_succeeded == ts_seen:
        ts_backend_agg = "ast-grep"
    else:
        ts_backend_agg = "ast-grep+fallback"

    return entries, ck_metrics_list, all_fn_cc, lang_counts, bash_backend_agg, ts_backend_agg


def _carry_forward_unchanged(
    conn: sqlite3.Connection,
    scan_id: int,
    prev_scan: object,
    files_unchanged: list[str],
    classify_overrides: dict[str, list[str]] | None,
) -> list[FileEntry]:
    """Carry FileEntry and file_metrics rows forward from prev_scan for unchanged files."""
    prev_entries = get_file_entries(conn, prev_scan.id)  # type: ignore[attr-defined]
    prev_by_path = {e.path: e for e in prev_entries}
    carried: list[FileEntry] = []

    for rel_path in files_unchanged:
        prev_e = prev_by_path.get(rel_path)
        if not prev_e:
            continue
        carried.append(
            FileEntry(
                path=prev_e.path,
                scan_id=scan_id,
                language=prev_e.language,
                loc=prev_e.loc,
                complexity=prev_e.complexity,
                functions=prev_e.functions,
                max_nesting=prev_e.max_nesting,
                avg_fn_len=prev_e.avg_fn_len,
                essential_complexity=prev_e.essential_complexity,
                indent_sd=prev_e.indent_sd,
                category=classify_file(prev_e.path, classify_overrides),
            )
        )

    if carried:
        bulk_upsert_file_entries(conn, carried)
        carried_paths = [c.path for c in carried]
        for rel_path in carried_paths:
            fm_rows = conn.execute(
                "SELECT path, metric, value, detail FROM file_metrics"
                " WHERE scan_id = ? AND path = ?",
                (prev_scan.id, rel_path),  # type: ignore[attr-defined]
            ).fetchall()
            for row in fm_rows:
                conn.execute(
                    "INSERT OR IGNORE INTO file_metrics"
                    " (path, scan_id, metric, value, detail)"
                    " VALUES (?, ?, ?, ?, ?)",
                    (row[0], scan_id, row[1], row[2], row[3]),
                )

    return carried


def _print_scan_result(
    lang_counts: dict[str, int],
    files_to_scan: list[str],
    duration_ms: int,
    summary: dict[str, object],
    bash_cc_backend: str = "regex",
    ts_cc_backend: str = "unavailable",
) -> None:
    """Print human-readable scan summary to stderr."""
    for lang, count in sorted(lang_counts.items()):
        changed = sum(
            1
            for f in files_to_scan
            if (f.endswith(".py") and lang == "python")
            or (f.endswith((".ts", ".tsx")) and lang == "typescript")
            or (not f.endswith((".py", ".ts", ".tsx")) and lang == "bash")
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
    backend_parts = [f"bash={bash_cc_backend}"]
    if ts_cc_backend != "unavailable":
        backend_parts.append(f"ts={ts_cc_backend}")
    print(f"  CC backend: {', '.join(backend_parts)}", file=sys.stderr)
    print(f"\nQuality score: {summary.get('quality_score', 100)}/100", file=sys.stderr)


# ---------------------------------------------------------------------------
# Scan command
# ---------------------------------------------------------------------------


def cmd_scan(args: argparse.Namespace) -> int:
    """Execute wv quality scan."""
    repo = _resolve_repo(args.path)
    conn = init_db(args.hot_zone)
    start_time = time.monotonic()

    cli_excludes: list[str] = getattr(args, "exclude", [])
    all_files = _discover_files(repo, exclude_globs=_load_config_excludes(repo) + cli_excludes)

    head = git_head_sha(repo)
    scan_id = begin_scan(conn, head, scanner_version=_SCANNER_VERSION)

    prev_for_version = previous_scan(conn)
    version_changed = (
        prev_for_version is not None
        and _SCANNER_VERSION
        and prev_for_version.scanner_version != _SCANNER_VERSION
    )
    if version_changed:
        log.info(
            "Scanner version changed (%s → %s); forcing full re-scan",
            prev_for_version.scanner_version or "unknown",  # type: ignore[union-attr]
            _SCANNER_VERSION,
        )

    blob_map = batch_blob_shas(repo)
    files_to_scan: list[str] = []
    files_unchanged: list[str] = []
    for rel_path in all_files:
        abs_path = os.path.join(repo, rel_path)
        try:
            mtime = int(os.path.getmtime(abs_path))
        except OSError:
            mtime = 0
        if version_changed or file_changed(conn, rel_path, mtime, blob_map.get(rel_path, "")):
            files_to_scan.append(rel_path)
        else:
            files_unchanged.append(rel_path)

    classify_overrides = load_classify_overrides(repo)

    _cache = ASTCache.open(repo, _SCANNER_VERSION)

    # Overlap git work with file analysis: subprocess.run inside git calls releases
    # the GIL, so both futures run truly concurrently with _scan_files (CPU-bound).
    # all_files = files_to_scan + files_unchanged covers all paths — no need to
    # wait for _scan_files before starting git stats.
    with ThreadPoolExecutor(max_workers=2) as _git_pool:
        _git_stats_future = _git_pool.submit(enrich_all_git_stats, repo, all_files)
        _co_changes_future = _git_pool.submit(compute_co_changes, repo)

        entries, ck_metrics_list, all_fn_cc, lang_counts, bash_backend, ts_backend = _scan_files(
            repo, files_to_scan, scan_id, classify_overrides,
            blob_map=blob_map, ast_cache=_cache,
        )
    # Executor has shut down; futures are resolved.
    git_stats = _git_stats_future.result()
    co_changes = _co_changes_future.result()

    _cache.close()

    bulk_upsert_file_entries(conn, entries)
    for ck in ck_metrics_list:
        upsert_ck_metrics(conn, ck)
    if all_fn_cc:
        bulk_upsert_function_cc(conn, all_fn_cc)

    prev = previous_scan(conn)
    if prev is not None and files_unchanged:
        carried = _carry_forward_unchanged(
            conn, scan_id, prev, files_unchanged, classify_overrides
        )
        entries.extend(carried)

    for e in entries:
        upsert_complexity_trend(conn, e.path, scan_id, e.complexity, e.essential_complexity)
    for rel_path in files_to_scan:
        upsert_file_state(conn, build_file_state(repo, rel_path, blob_map=blob_map))
    if git_stats:
        compute_hotspots(entries, git_stats)
    bulk_upsert_git_stats(conn, git_stats)
    bulk_upsert_co_changes(conn, co_changes)

    # Reload fn_cc — includes carried-forward rows not in all_fn_cc
    all_fn_cc = get_all_function_cc(conn, scan_id)

    duration_ms = int((time.monotonic() - start_time) * 1000)
    # entries already includes carry-forward rows (extended above); use len(all_files)
    # to avoid double-counting files_unchanged.
    finish_scan(conn, scan_id, len(all_files), duration_ms,
                bash_cc_backend=bash_backend, ts_cc_backend=ts_backend)
    conn.commit()
    conn.close()

    summary = hotspot_summary(entries, git_stats, all_fn_cc)

    if args.json:
        category_counts = dict(Counter(e.category for e in entries))
        print(json.dumps({
            "scan_id": scan_id,
            "git_head": head,
            "files_scanned": len(all_files),
            "files_changed": len(files_to_scan),
            "languages": lang_counts,
            "category_counts": category_counts,
            "duration_ms": duration_ms,
            "hotspots_above_threshold": summary.get("hotspot_count", 0),
            "quality_score": summary.get("quality_score", 100),
            "bash_cc_backend": bash_backend,
            "ts_cc_backend": ts_backend,
        }))
    else:
        print(f"Scanning {repo}...", file=sys.stderr)
        _print_scan_result(lang_counts, files_to_scan, duration_ms, summary,
                           bash_cc_backend=bash_backend, ts_cc_backend=ts_backend)

    return 0


# ---------------------------------------------------------------------------
# Hotspots command
# ---------------------------------------------------------------------------


def _get_current_head() -> str:
    """Get current git HEAD SHA, or empty string if not in a repo."""
    try:
        result = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            check=True,
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

    # Compute distribution metrics
    hist = cc_histogram(all_fns)
    gini = round(cc_gini(all_fns), 2)

    if getattr(args, "json", False):
        output = {
            "functions": [
                {
                    "path": fn.path,
                    "function": fn.function_name,
                    "cc": fn.complexity,
                    "ev": fn.essential_complexity,
                    "line_start": fn.line_start,
                    "line_end": fn.line_end,
                    "is_dispatch": fn.is_dispatch,
                }
                for fn in all_fns
            ],
            "histogram": dict(zip(CC_HISTOGRAM_LABELS, hist)),
            "cc_gini": gini,
        }
        print(json.dumps(output, indent=2))
        return 0

    # Text output (stderr — stdout reserved for --json)
    header = f"Functions in {root} (CC threshold: {_CC_THRESHOLD}):"
    print(header, file=sys.stderr)
    print(file=sys.stderr)

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
            f"{ev_str}  {line_range}{dispatch_tag}",
            file=sys.stderr,
        )

    print(file=sys.stderr)
    total = len(all_fns)
    n_flagged = len(flagged)
    n_exempt = len(exempt)
    exempt_note = f" ({n_exempt} dispatch-exempt)" if n_exempt else ""
    print(
        f"  Summary: {n_flagged}/{total} functions exceed threshold{exempt_note}",
        file=sys.stderr,
    )

    # Distribution
    hist_parts = [f"{label}:{count}" for label, count in zip(CC_HISTOGRAM_LABELS, hist)]
    print(
        f"  Distribution: [{', '.join(hist_parts)}]  Gini={gini:.2f}", file=sys.stderr
    )
    return 0


def cmd_hotspots(args: argparse.Namespace) -> int:
    """Execute wv quality hotspots -- ranked hotspot report."""
    hot_zone = args.hot_zone
    top_n: int = args.top
    json_output: bool = args.json

    if not db_exists(hot_zone):
        print(_MSG_NO_DB, file=sys.stderr)
        return 1

    conn = init_db(hot_zone)
    current_head = _get_current_head()

    # Staleness warning
    stale = staleness_info(conn, current_head)

    # Get latest scan data
    scan = latest_scan(conn)
    if scan is None:
        conn.close()
        print(_MSG_NO_SCAN, file=sys.stderr)
        return 1

    # Fetch hotspots from git_stats
    ranked = top_hotspots(conn, top_n)

    # Fetch file entries for the latest scan (for complexity info)
    entries = get_file_entries(conn, scan.id)
    scope: str = args.scope
    entries = [e for e in entries if _in_scope(e, scope)]
    entry_by_path = {e.path: e for e in entries}

    # Filter ranked hotspots to only paths that are in scope.
    # When scope="all", every path passes through (including paths with no file entry).
    # For any other scope, restrict to paths present in the scoped entry set.
    if scope != "all":
        scoped_paths = set(entry_by_path.keys())
        ranked = [gs for gs in ranked if gs.path in scoped_paths]

    # Trend directions from complexity_trend history
    trend_dirs = get_all_trend_directions(conn)

    # Per-file Gini coefficient (complexity concentration)
    gini_by_path: dict[str, float] = {}
    for gs in ranked:
        fns = get_function_cc(conn, scan.id, gs.path)
        gini_by_path[gs.path] = round(cc_gini(fns), 2)

    conn.close()

    if json_output:
        items = []
        for gs in ranked:
            entry = entry_by_path.get(gs.path)
            cc = entry.complexity if entry else 0.0
            ev = entry.essential_complexity if entry else 0.0
            isd = round(entry.indent_sd, 2) if entry else 0.0
            items.append(
                {
                    "path": gs.path,
                    "hotspot": gs.hotspot,
                    "complexity": cc,
                    "essential_complexity": ev,
                    "indent_sd": isd,
                    "cc_gini": gini_by_path.get(gs.path, 0.0),
                    "churn": gs.churn,
                    "authors": gs.authors,
                    "ownership_fraction": round(gs.ownership_fraction, 2),
                    "minor_contributors": gs.minor_contributors,
                    "trend_direction": trend_dirs.get(gs.path, "stable"),
                    "severity": classify_hotspot(gs.hotspot),
                }
            )
        output = {
            "stale": stale.get("stale", False),
            "scan_id": scan.id,
            "git_head": scan.git_head,
            "scope": scope,
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
                trend_sym = {"deteriorating": "↑", "refactored": "↓"}.get(trend, "~")
                ev_str = f"  ev={ev:.0f}" if ev > 0 else ""
                gini = gini_by_path.get(gs.path, 0.0)
                gini_str = f"  gini={gini:.2f}" if gini > 0 else ""
                print(
                    f"  {i}. {gs.path:<50s} "
                    f"hotspot={gs.hotspot:.2f}  CC={cc:.0f}{ev_str}{gini_str}  "
                    f"churn={gs.churn}  authors={gs.authors}  "
                    f"trend={trend_sym}",
                    file=sys.stderr,
                )

    return 0


# ---------------------------------------------------------------------------
# Diff helpers
# ---------------------------------------------------------------------------


def _categorize_file_changes(
    cur_by_path: dict[str, FileEntry],
    prev_by_path: dict[str, FileEntry],
    trend_dirs: dict[str, str],
) -> tuple[
    list[dict[str, object]],
    list[dict[str, object]],
    list[dict[str, object]],
    list[str],
]:
    """Categorize file changes into improved, degraded, new_files, removed_files."""
    improved: list[dict[str, object]] = []
    degraded: list[dict[str, object]] = []
    new_files: list[dict[str, object]] = []
    removed_files: list[str] = []

    for path in sorted(set(cur_by_path.keys()) | set(prev_by_path.keys())):
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
                continue
            item: dict[str, object] = {
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

    improved.sort(key=lambda x: x["delta"])  # type: ignore[arg-type,return-value]
    degraded.sort(key=lambda x: x["delta"], reverse=True)  # type: ignore[arg-type,return-value]
    return improved, degraded, new_files, removed_files


def _print_diff_result(
    degraded: list[dict[str, object]],
    improved: list[dict[str, object]],
    new_files: list[dict[str, object]],
    removed_files: list[str],
    cur_score: float,
    prev_score: float,
    scan_current_id: int,
    scan_prev_id: int,
) -> None:
    """Print human-readable diff summary to stderr."""
    print(f"Quality delta (scan #{scan_current_id} vs #{scan_prev_id}):\n", file=sys.stderr)
    trend_sym_map = {"deteriorating": " ↑", "refactored": " ↓"}

    if degraded:
        print("Degraded:", file=sys.stderr)
        for item in degraded:
            trend_sym = trend_sym_map.get(str(item.get("trend_direction", "stable")), "")
            print(
                f"  {item['path']}: complexity "
                f"{item['complexity_previous']} -> {item['complexity_current']} "
                f"(+{item['delta']}){trend_sym}",
                file=sys.stderr,
            )
    if improved:
        print("Improved:", file=sys.stderr)
        for item in improved:
            trend_sym = trend_sym_map.get(str(item.get("trend_direction", "stable")), "")
            print(
                f"  {item['path']}: complexity "
                f"{item['complexity_previous']} -> {item['complexity_current']} "
                f"({item['delta']}){trend_sym}",
                file=sys.stderr,
            )
    if new_files:
        print("New files:", file=sys.stderr)
        for item in new_files:
            print(f"  {item['path']}: complexity={item['complexity']} ({item['severity']})", file=sys.stderr)
    if removed_files:
        print("Removed files:", file=sys.stderr)
        for path in removed_files:
            print(f"  {path}", file=sys.stderr)
    if not (degraded or improved or new_files or removed_files):
        print("No significant changes.", file=sys.stderr)

    score_delta = cur_score - prev_score
    sign = "+" if score_delta > 0 else ""
    print(f"\nNet quality change: {sign}{score_delta} points ({prev_score} -> {cur_score})", file=sys.stderr)


# ---------------------------------------------------------------------------
# Diff command
# ---------------------------------------------------------------------------


def cmd_diff(args: argparse.Namespace) -> int:
    """Execute wv quality diff -- delta report vs previous scan."""
    if not db_exists(args.hot_zone):
        print(_MSG_NO_DB, file=sys.stderr)
        return 1

    conn = init_db(args.hot_zone)
    current = latest_scan(conn)
    if current is None:
        conn.close()
        print(_MSG_NO_SCAN, file=sys.stderr)
        return 1

    prev = previous_scan(conn)
    if prev is None:
        conn.close()
        if args.json:
            print(json.dumps({
                "scan_current": current.id, "scan_previous": None,
                "improved": [], "degraded": [], "new_files": [], "removed_files": [],
                "quality_score_current": 0, "quality_score_previous": None,
            }))
        else:
            print(
                "No previous scan to diff against. "
                "Run 'wv quality scan' again after making changes.",
                file=sys.stderr,
            )
        return 0

    scope: str = args.scope
    current_entries = get_file_entries(conn, current.id)
    prev_entries = get_file_entries(conn, prev.id)
    cur_fn_cc = get_all_function_cc(conn, current.id)
    prev_fn_cc = get_all_function_cc(conn, prev.id)
    all_git_stats = get_git_stats(conn)
    trend_dirs = get_all_trend_directions(conn)
    conn.close()

    cur_by_path = {e.path: e for e in current_entries if _in_scope(e, scope)}
    prev_by_path = {e.path: e for e in prev_entries if _in_scope(e, scope)}
    cur_score = compute_quality_score(current_entries, all_git_stats, cur_fn_cc, scope=scope)
    prev_score = compute_quality_score(prev_entries, all_git_stats, prev_fn_cc, scope=scope)

    improved, degraded, new_files, removed_files = _categorize_file_changes(
        cur_by_path, prev_by_path, trend_dirs
    )

    if args.json:
        print(json.dumps({
            "scan_current": current.id,
            "scan_previous": prev.id,
            "scope": scope,
            "improved": improved,
            "degraded": degraded,
            "new_files": new_files,
            "removed_files": removed_files,
            "quality_score_current": cur_score,
            "quality_score_previous": prev_score,
            "bash_cc_backend_current": current.bash_cc_backend,
            "bash_cc_backend_previous": prev.bash_cc_backend,
        }))
    else:
        _print_diff_result(
            degraded, improved, new_files, removed_files,
            cur_score, prev_score, current.id, prev.id,
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
        env = {**os.environ, "WV_CALL_SOURCE": "sync"}
        result = subprocess.run(
            [os.environ.get("WV_CLI", "wv"), *cmd_args],
            capture_output=True,
            text=True,
            check=False,
            env=env,
        )
        return result.returncode, result.stdout.strip()
    except FileNotFoundError:
        return 1, "wv command not found"


def _load_existing_findings() -> dict[str, str]:
    """Return {quality_finding_id: node_id} for all existing promoted nodes."""
    rc, existing_json = _wv_cmd("list", "--json", "--all")
    findings: dict[str, str] = {}
    if rc != 0 or not existing_json:
        return findings
    try:
        for node in json.loads(existing_json):
            meta_str = node.get("metadata", "{}")
            meta = json.loads(meta_str) if isinstance(meta_str, str) else meta_str
            fid = meta.get("quality_finding_id", "")
            if fid:
                findings[fid] = node["id"]
    except (json.JSONDecodeError, TypeError):
        pass
    return findings


def _promote_upsert(
    existing_id: str,
    gs: GitStats,
    entry_by_path: dict[str, FileEntry],
    dry_run: bool,
) -> dict[str, object]:
    """Upsert an existing finding node with fresh scan data. Returns updated-entry dict."""
    entry = entry_by_path.get(gs.path)
    cc = entry.complexity if entry else 0.0
    severity = classify_hotspot(gs.hotspot)
    code_ref: dict[str, object] = {
        "path": gs.path, "hotspot": gs.hotspot, "complexity": cc,
        "churn": gs.churn, "authors": gs.authors, "severity": severity,
    }
    new_text = f"Hotspot: {gs.path} (CC={cc:.0f}, churn={gs.churn})"
    upd: dict[str, object] = {"node_id": existing_id, "text": new_text,
                               "finding_id": _finding_id(gs.path), **code_ref}
    if dry_run:
        print(f"[DRY-RUN] Would update {existing_id}: {new_text}", file=sys.stderr)
        return upd
    new_meta = json.dumps({"quality_finding_id": _finding_id(gs.path),
                           "code_ref": code_ref, "type": "quality-finding"})
    _wv_cmd("update", existing_id, f"--text={new_text}", f"--metadata={new_meta}")
    print(f'Updated {existing_id}: "{new_text}"', file=sys.stderr)
    return upd


def _promote_create(
    gs: GitStats,
    entry_by_path: dict[str, FileEntry],
    parent: str,
    dry_run: bool,
) -> dict[str, object] | None:
    """Create a new finding node. Returns promoted-entry dict, or None on failure."""
    entry = entry_by_path.get(gs.path)
    cc = entry.complexity if entry else 0.0
    severity = classify_hotspot(gs.hotspot)
    text = f"Hotspot: {gs.path} (CC={cc:.0f}, churn={gs.churn})"
    code_ref: dict[str, object] = {
        "path": gs.path, "hotspot": gs.hotspot, "complexity": cc,
        "churn": gs.churn, "authors": gs.authors, "severity": severity,
    }
    fid = _finding_id(gs.path)
    result: dict[str, object] = {"text": text, "finding_id": fid, **code_ref}
    if dry_run:
        print(f"[DRY-RUN] Would create: {text}", file=sys.stderr)
        print(f"  -> references {parent}", file=sys.stderr)
        return result
    create_meta = json.dumps({"quality_finding_id": fid, "code_ref": code_ref, "type": "quality-finding"})
    rc, out = _wv_cmd("add", text, f"--metadata={create_meta}", "--force")
    if rc != 0:
        print(f"Error creating node for {gs.path}: {out}", file=sys.stderr)
        return None
    node_id = next((w.rstrip(":") for w in out.split() if w.startswith("wv-")), "")
    if not node_id:
        return None
    _wv_cmd("link", node_id, parent, "--type=references")
    print(f'Created {node_id}: "{text}"', file=sys.stderr)
    print(f"  -> references {parent}", file=sys.stderr)
    return {"node_id": node_id, **result}


def _cmd_promote_patterns(args: argparse.Namespace) -> int:
    """Promote pattern findings grouped by rule_id to Weave nodes."""
    conn = init_db(args.hot_zone)
    scan = latest_scan(conn)
    if scan is None:
        conn.close()
        print(_MSG_NO_SCAN, file=sys.stderr)
        return 1

    summary = pattern_findings_summary(conn, scan.id)
    conn.close()

    if not summary:
        msg = "No pattern findings to promote. Run: wv quality patterns scan"
        print(json.dumps({"promoted": [], "skipped": 0}) if args.json else msg)
        return 0

    dry_run: bool = args.dry_run
    parent: str = args.parent
    existing_findings = _load_existing_findings()
    promoted: list[dict[str, object]] = []

    for row in summary:
        rule_id = str(row["rule_id"])
        count = row["hits"]
        fid = _finding_id(rule_id, metric="pattern")
        text = f"Pattern: {rule_id} ({count} findings)"
        meta = json.dumps({
            "quality_finding_id": fid,
            "code_ref": {"rule_id": rule_id, "count": count},
            "type": "quality-pattern-finding",
        })
        entry: dict[str, object] = {"rule_id": rule_id, "count": count, "finding_id": fid, "text": text}
        if fid in existing_findings:
            node_id = existing_findings[fid]
            if dry_run:
                print(f"[DRY-RUN] Would update {node_id}: {text}", file=sys.stderr)
            else:
                _wv_cmd("update", node_id, f"--text={text}", f"--metadata={meta}")
                print(f'Updated {node_id}: "{text}"', file=sys.stderr)
            promoted.append({"node_id": node_id, **entry})
            continue
        if dry_run:
            print(f"[DRY-RUN] Would create: {text}", file=sys.stderr)
            print(f"  -> references {parent}", file=sys.stderr)
        else:
            rc, out = _wv_cmd("add", text, f"--metadata={meta}", "--force")
            if rc != 0:
                print(f"Error creating node for {rule_id}: {out}", file=sys.stderr)
                continue
            node_id = next((w.rstrip(":") for w in out.split() if w.startswith("wv-")), "")
            if node_id:
                _wv_cmd("link", node_id, parent, "--type=references")
                print(f'Created {node_id}: "{text}"', file=sys.stderr)
                entry["node_id"] = node_id
        promoted.append(entry)

    if args.json:
        print(json.dumps({"promoted": promoted, "parent": parent}))
    return 0


def cmd_promote(args: argparse.Namespace) -> int:
    """Execute wv quality promote -- create Weave nodes from top findings."""
    parent: str = args.parent
    if not parent:
        print("Error: --parent=<node-id> is required.", file=sys.stderr)
        return 1
    if not db_exists(args.hot_zone):
        print(_MSG_NO_DB, file=sys.stderr)
        return 1

    if getattr(args, "from_patterns", False):
        return _cmd_promote_patterns(args)

    conn = init_db(args.hot_zone)
    scan = latest_scan(conn)
    if scan is None:
        conn.close()
        print(_MSG_NO_SCAN, file=sys.stderr)
        return 1

    ranked = top_hotspots(conn, args.top)
    entry_by_path = {e.path: e for e in get_file_entries(conn, scan.id)}
    conn.close()

    if not ranked:
        print("No hotspots above threshold to promote.", file=sys.stderr)
        return 0

    upsert: bool = getattr(args, "upsert", False)
    dry_run: bool = args.dry_run
    existing_findings = _load_existing_findings()
    promoted: list[dict[str, object]] = []
    updated: list[dict[str, object]] = []
    skipped = 0

    for gs in ranked:
        fid = _finding_id(gs.path)
        if fid in existing_findings:
            if not upsert:
                skipped += 1
                continue
            updated.append(_promote_upsert(existing_findings[fid], gs, entry_by_path, dry_run))
            continue
        result = _promote_create(gs, entry_by_path, parent, dry_run)
        if result is not None:
            promoted.append(result)

    if args.json:
        out: dict[str, object] = {"promoted": promoted, "skipped": skipped, "parent": parent}
        if updated:
            out["updated"] = updated
        print(json.dumps(out))
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


def cmd_health_info(args: argparse.Namespace) -> None:
    """Output compact quality summary for wv health integration.

    Always outputs JSON to stdout.  If quality.db is missing or empty,
    returns {"available": false} so the caller can show 'no scan data'.
    """
    hot_zone = args.hot_zone

    if not db_exists(hot_zone):
        print(json.dumps({"available": False}))
        return

    conn = init_db(hot_zone)
    scan = latest_scan(conn)
    if scan is None:
        conn.close()
        print(json.dumps({"available": False}))
        return

    entries = get_file_entries(conn, scan.id)
    all_stats = get_git_stats(conn)
    all_fn_cc = get_all_function_cc(conn, scan.id)
    conn.close()

    score = compute_quality_score(entries, all_stats, all_fn_cc)
    hotspot_count = count_hotspots(entries, all_stats)

    print(
        json.dumps(
            {
                "available": True,
                "score": score,
                "hotspot_count": hotspot_count,
                "total_files": len(entries),
                "git_head": scan.git_head,
                "scanned_at": scan.scanned_at,
            }
        )
    )


# ---------------------------------------------------------------------------
# Context files command (for wv context integration)
# ---------------------------------------------------------------------------


def cmd_context_files(args: argparse.Namespace) -> None:
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
        return

    conn = init_db(hot_zone)
    scan = latest_scan(conn)
    if scan is None:
        conn.close()
        print(json.dumps({"code_quality": [], "quality_as_of": None}))
        return

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

    print(
        json.dumps(
            {
                "code_quality": results,
                "quality_as_of": scan.git_head,
            }
        )
    )


# ---------------------------------------------------------------------------
# Patterns commands (wv quality patterns scan / list)
# ---------------------------------------------------------------------------

_DEFAULT_PATTERNS_DIR = Path(__file__).parent / "default_patterns"


def _load_pattern_rules(
    repo: Path, conf_disabled: set[str]
) -> list[tuple[str, Path]]:
    """Return [(rule_id, rule_path)] for all active pattern rules.

    Loads from:
      1. _DEFAULT_PATTERNS_DIR (built-in curated rules)
      2. <repo>/.weave/patterns/*.yaml (user-defined rules)
    Rules whose id appears in conf_disabled are skipped.
    """
    rules: list[tuple[str, Path]] = []
    for rule_dir in (_DEFAULT_PATTERNS_DIR, repo / ".weave" / "patterns"):
        if not rule_dir.is_dir():
            continue
        for yf in sorted(rule_dir.glob("*.yaml")):
            rule_id = yf.stem
            if rule_id not in conf_disabled:
                rules.append((rule_id, yf))
    return rules


def _disabled_patterns(conf_path: Path) -> set[str]:
    """Read [patterns] disabled = ... from quality.conf."""
    disabled: set[str] = set()
    if not conf_path.exists():
        return disabled
    cp = configparser.ConfigParser(inline_comment_prefixes=("#",), allow_no_value=True)
    cp.read(str(conf_path))
    raw = cp.get("patterns", "disabled", fallback="")
    for item in raw.replace(",", " ").split():
        if item.strip():
            disabled.add(item.strip())
    return disabled


def _run_pattern_rule(
    rule_id: str, rule_path: Path, target: Path, scan_id: int
) -> list[PatternFinding]:
    """Run one rule file on target; return PatternFinding list."""
    if rule_language(rule_path) in PROSE_LANGUAGES:
        return run_prose_rule(rule_id, rule_path, target, scan_id)

    ast_grep = ast_grep_bin()
    if not ast_grep:
        return []
    cmd = [ast_grep, "scan", "--rule", str(rule_path), "--json", str(target)]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=60, check=False)
    except subprocess.TimeoutExpired:
        log.warning("ast-grep timed out scanning %s with rule %s", target, rule_id)
        return []
    if proc.returncode == 2 or (proc.returncode not in (0, 1) and not proc.stdout.strip()):
        log.warning("ast-grep error for rule %s on %s: %s", rule_id, target, proc.stderr[:200])
        return []
    if not proc.stdout.strip():
        return []
    try:
        matches = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return []
    findings: list[PatternFinding] = []
    if isinstance(matches, list):
        for m in matches:
            rng = m.get("range", {})
            start = rng.get("start", {})
            findings.append(
                PatternFinding(
                    path=str(Path(m.get("file", "")).relative_to(target)
                              if target.is_dir() else Path(m.get("file", "")).name),
                    scan_id=scan_id,
                    rule_id=rule_id,
                    line=start.get("line", 0) + 1,
                    col=start.get("column", 0),
                    match_text=(m.get("text", "") or "")[:200],
                    severity="warning",
                )
            )
    return findings


def cmd_patterns_scan(args: argparse.Namespace) -> int:
    """Run all active pattern rules and store findings."""
    repo = Path(_resolve_repo(None))
    conn = init_db(args.hot_zone)
    scan = latest_scan(conn)
    if scan is None:
        print("No scan in DB — run: wv quality scan", file=sys.stderr)
        conn.close()
        return 1

    conf_disabled = _disabled_patterns(repo / ".weave" / "quality.conf")
    rules = _load_pattern_rules(repo, conf_disabled)
    prose_rules = [
        (rule_id, rule_path)
        for rule_id, rule_path in rules
        if rule_language(rule_path) in PROSE_LANGUAGES
    ]
    code_rules = [
        (rule_id, rule_path)
        for rule_id, rule_path in rules
        if rule_language(rule_path) not in PROSE_LANGUAGES
    ]
    if code_rules and not ast_grep_available():
        print(
            f"patterns: skipping {len(code_rules)} code rule(s) "
            "(ast-grep not found; run ./install.sh); prose rules still run",
            file=sys.stderr,
        )
        rules = prose_rules
    if not rules:
        msg = "No pattern rules found."
        print(json.dumps({"rules": 0, "findings": 0}) if args.json else msg)
        conn.close()
        return 0

    target = Path(getattr(args, "path", None) or repo)
    all_findings: list[PatternFinding] = []
    for rule_id, rule_path in rules:
        found = _run_pattern_rule(rule_id, rule_path, target, scan.id)
        all_findings.extend(found)

    # Normalise paths relative to repo
    for f in all_findings:
        try:
            f.path = str(Path(f.path))
        except ValueError:
            pass

    bulk_insert_pattern_findings(conn, all_findings)
    conn.close()

    summary = {r: sum(1 for f in all_findings if f.rule_id == r) for r, _ in rules}
    total = len(all_findings)

    if args.json:
        print(json.dumps({"rules_run": len(rules), "findings": total, "by_rule": summary}))
    else:
        print(f"Pattern scan complete: {len(rules)} rules, {total} findings")
        for rule_id, count in sorted(summary.items(), key=lambda x: -x[1]):
            print(f"  {rule_id}: {count}")
    return 0


def cmd_patterns_list(args: argparse.Namespace) -> int:
    """List active rules with last-scan hit counts."""
    repo = Path(_resolve_repo(getattr(args, "path", None)))
    conn = init_db(args.hot_zone)
    scan = latest_scan(conn)

    conf_disabled = _disabled_patterns(repo / ".weave" / "quality.conf")
    rules = _load_pattern_rules(repo, conf_disabled)

    if scan is not None:
        hits_by_rule = {
            r["rule_id"]: r["hits"]
            for r in pattern_findings_summary(conn, scan.id)
        }
    else:
        hits_by_rule = {}
    conn.close()

    if args.json:
        out = [
            {"rule_id": rid, "path": str(rpath), "hits": hits_by_rule.get(rid, 0)}
            for rid, rpath in rules
        ]
        print(json.dumps(out))
    else:
        if not rules:
            print("No active pattern rules.")
            return 0
        print(f"Active pattern rules ({len(rules)}):")
        for rule_id, rule_path in rules:
            hits = hits_by_rule.get(rule_id, 0)
            src = "default" if rule_path.parent == _DEFAULT_PATTERNS_DIR else "custom"
            print(f"  {rule_id:40s} [{src}] hits={hits}")
    return 0


def cmd_patterns(args: argparse.Namespace) -> int:
    """Dispatch patterns sub-commands (scan / list / promote)."""
    sub = getattr(args, "patterns_command", None)
    if sub == "scan":
        return cmd_patterns_scan(args)
    if sub == "list":
        return cmd_patterns_list(args)
    if sub == "promote":
        return _cmd_promote_patterns(args)
    print("Usage: wv quality patterns {scan,list,promote}", file=sys.stderr)
    return 1


# ---------------------------------------------------------------------------
# Reset command
# ---------------------------------------------------------------------------


def _structural_search_error(msg: dict[str, str], json_out: bool) -> int:
    """Print a structured error for structural-search and return 1."""
    if json_out:
        print(json.dumps(msg))
    else:
        print(f"Error: {msg.get('detail', msg.get('error', 'unknown'))}", file=sys.stderr)
    return 1


def cmd_structural_search(args: argparse.Namespace) -> int:
    """Execute wv quality structural-search — find code by structural AST pattern via ast-grep."""
    ast_grep = ast_grep_bin()
    if not ast_grep:
        if args.json:
            print(json.dumps({"error": "ast-grep not installed", "install": "./install.sh"}))
        else:
            print("structural_scan: disabled (ast-grep not found — run ./install.sh)", file=sys.stderr)
        return 1

    # ast-grep `run --pattern` has limited metavariable support for Python;
    # `scan --rule` (YAML) works correctly for all languages.
    rule_yaml = (
        f"id: structural-search\n"
        f"language: {args.lang}\n"
        f"rule:\n"
        f"  pattern: |\n"
        f"    {args.pattern}\n"
    )
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".yaml", delete=False, prefix="wv_ss_"
        ) as tf:
            tf.write(rule_yaml)
            rule_path = tf.name
    except OSError as exc:
        return _structural_search_error({"error": "temp file error", "detail": str(exc)}, args.json)

    cmd = [ast_grep, "scan", "--rule", rule_path, "--json", args.repo]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=30, check=False)
    except subprocess.TimeoutExpired:
        return _structural_search_error({"error": "timeout", "detail": "ast-grep exceeded 30s"}, args.json)
    finally:
        Path(rule_path).unlink(missing_ok=True)

    # Exit 2 (or empty stdout with non-empty stderr) = invalid pattern / hard error.
    # Exit 1 with valid JSON = no matches found (ast-grep convention).
    if proc.returncode == 2 or (proc.returncode != 0 and not proc.stdout.strip()):
        detail = proc.stderr.strip() or "unknown error"
        return _structural_search_error({"error": "invalid pattern or ast-grep error", "detail": detail}, args.json)

    matches: list[dict[str, object]] = []
    raw_out = proc.stdout.strip()
    if raw_out:
        try:
            parsed = json.loads(raw_out)
            if isinstance(parsed, list):
                for m in parsed:
                    rng = m.get("range", {})
                    start = rng.get("start", {})
                    matches.append({
                        "file": m.get("file", ""),
                        "line": start.get("line", 0) + 1,  # ast-grep is 0-indexed
                        "column": start.get("column", 0),
                        "match_text": m.get("text", ""),
                        "node_kind": m.get("kind", ""),
                        "rule_id": "structural-search",
                    })
        except json.JSONDecodeError:
            pass

    if args.json:
        print(json.dumps(matches))
    else:
        if not matches:
            print("No matches found.", file=sys.stderr)
        for m in matches:
            snippet = str(m["match_text"]).replace("\n", " ")[:80]
            print(f"{m['file']}:{m['line']}:{m['column']}: {snippet}")
    return 0


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


def main() -> int:  # pragma: no cover
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
        "--verbose",
        "-v",
        action="store_true",
        help="Enable debug logging",
    )

    sub = parser.add_subparsers(dest="command")

    # scan
    scan_parser = sub.add_parser("scan", help="Scan codebase for quality metrics")
    scan_parser.add_argument(
        "path", nargs="?", help="Path to scan (default: repo root)"
    )
    scan_parser.add_argument("--json", action="store_true", help="JSON output")
    scan_parser.add_argument(
        "--exclude",
        action="append",
        default=[],
        help="Exclude files matching glob (repeatable)",
    )

    # hotspots
    hotspots_parser = sub.add_parser("hotspots", help="Ranked hotspot report")
    hotspots_parser.add_argument(
        "--top", type=int, default=10, help="Number of results (default: 10)"
    )
    hotspots_parser.add_argument("--json", action="store_true", help="JSON output")
    hotspots_parser.add_argument(
        "--scope",
        default="production",
        choices=["production", "all", "test", "script", "generated"],
        help="File category scope (default: production)",
    )

    # diff
    diff_parser = sub.add_parser("diff", help="Delta report vs previous scan")
    diff_parser.add_argument("--json", action="store_true", help="JSON output")
    diff_parser.add_argument(
        "--scope",
        default="production",
        choices=["production", "all", "test", "script", "generated"],
        help="File category scope (default: production)",
    )

    # promote
    promote_parser = sub.add_parser("promote", help="Promote findings to Weave nodes")
    promote_parser.add_argument(
        "--top", type=int, default=5, help="Number of findings (default: 5)"
    )
    promote_parser.add_argument(
        "--parent", required=True, help="Parent node ID to link via references"
    )
    promote_parser.add_argument("--json", action="store_true", help="JSON output")
    promote_parser.add_argument(
        "--upsert", action="store_true", help="Update existing findings with fresh data"
    )
    promote_parser.add_argument(
        "--dry-run", action="store_true", help="Show what would be created"
    )
    promote_parser.add_argument(
        "--from-patterns",
        dest="from_patterns",
        action="store_true",
        help="Promote pattern findings instead of hotspots",
    )

    findings_promote_parser = sub.add_parser(
        "findings-promote",
        help="Promote historical learnings to Weave finding nodes",
    )
    findings_promote_parser.add_argument(
        "--top",
        type=int,
        default=5,
        help="Reviewed candidate window size (default: 5)",
    )
    findings_promote_parser.add_argument(
        "--since-days",
        type=int,
        default=30,
        help="Stale-signal gate: only promote learnings whose source node closed "
        "within N days (default: 30). 0 disables the gate (promote any age).",
    )
    findings_promote_parser.add_argument(
        "--parent", default="", help="Parent node ID to link via references"
    )
    findings_promote_parser.add_argument(
        "--json", action="store_true", help="JSON output"
    )
    findings_promote_parser.add_argument(
        "--dry-run", action="store_true", help="Show the reviewed candidate window"
    )
    findings_promote_parser.add_argument(
        "--apply",
        action="store_true",
        help="Create finding nodes from the reviewed window only",
    )
    findings_promote_parser.add_argument(
        "--include-guardrails",
        action="store_true",
        help="Include operational/reporting guardrails",
    )
    findings_promote_parser.add_argument(
        "--include-root-causes",
        action="store_true",
        help="Include validated explanatory root-cause insights",
    )
    findings_promote_parser.add_argument(
        "--include-tooling",
        action="store_true",
        help="Include Weave/runtime/tooling findings (internal use)",
    )

    # health-info (for wv health integration)
    sub.add_parser("health-info", help="Compact quality summary for wv health")

    # context-files (for wv context integration)
    sub.add_parser(
        "context-files", help="Quality data for files (reads paths from stdin)"
    )

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

    # structural-search
    ss_parser = sub.add_parser(
        "structural-search",
        help="Find code by structural AST pattern (requires ast-grep)",
    )
    ss_parser.add_argument("--pattern", required=True, help="ast-grep pattern")
    ss_parser.add_argument(
        "--lang",
        required=True,
        help="Language: python, bash, typescript, go, rust, ...",
    )
    ss_parser.add_argument(
        "--repo", default=".", help="Repository root to search (default: .)"
    )
    ss_parser.add_argument("--json", action="store_true", help="JSON output")

    # patterns
    patterns_parser = sub.add_parser(
        "patterns",
        help="Structural + prose pattern matching (code rules require ast-grep)",
    )
    patterns_sub = patterns_parser.add_subparsers(dest="patterns_command")

    pat_scan_p = patterns_sub.add_parser("scan", help="Run pattern rules and store findings")
    pat_scan_p.add_argument("path", nargs="?", help="Path to scan (default: repo root)")
    pat_scan_p.add_argument("--json", action="store_true", help="JSON output")

    pat_list_p = patterns_sub.add_parser("list", help="List active rules with hit counts")
    pat_list_p.add_argument("path", nargs="?", help="Repo path (default: repo root)")
    pat_list_p.add_argument("--json", action="store_true", help="JSON output")

    pat_promote_p = patterns_sub.add_parser(
        "promote", help="Promote findings as Weave nodes"
    )
    pat_promote_p.add_argument("--parent", required=True, help="Parent node ID")
    pat_promote_p.add_argument("--json", action="store_true", help="JSON output")
    pat_promote_p.add_argument(
        "--dry-run", action="store_true", help="Show what would be created"
    )

    args = parser.parse_args()

    if args.verbose:
        logging.basicConfig(level=logging.DEBUG)
    else:
        logging.basicConfig(level=logging.WARNING)

    _dispatch = {
        "scan": cmd_scan,
        "hotspots": cmd_hotspots,
        "diff": cmd_diff,
        "promote": cmd_promote,
        "findings-promote": cmd_findings_promote,
        "functions": cmd_functions,
        "reset": cmd_reset,
        "structural-search": cmd_structural_search,
        "patterns": cmd_patterns,
    }
    if args.command in _dispatch:
        return _dispatch[args.command](args)
    if args.command == "health-info":
        cmd_health_info(args)
        return 0
    if args.command == "context-files":
        cmd_context_files(args)
        return 0
    parser.print_help()
    return 1


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
