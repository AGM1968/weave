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

# pylint: disable=too-many-lines

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
import unicodedata
from fnmatch import fnmatch
from pathlib import Path
from typing import NoReturn, TypedDict
import tempfile

from weave_quality.ast_cache import ASTCache
from weave_quality.bash_ast_grep import analyze_bash_file_best, ast_grep_available, batch_cc_lines
from weave_quality.bash_heuristic import detect_bash
from weave_quality.classification import classify_file, load_classify_overrides
from weave_quality.external_tools import ast_grep_bin
from weave_quality.typescript_parser import analyze_typescript_file
from weave_quality.db import (
    ADJUDICATION_NUDGE_SCANS,
    adjudicate_pattern_finding,
    begin_pattern_run,
    begin_scan,
    bulk_upsert_co_changes,
    bulk_upsert_file_entries,
    bulk_upsert_function_cc,
    bulk_upsert_git_stats,
    db_exists,
    db_path,
    file_changed,
    finish_pattern_run,
    finish_scan,
    get_all_trend_directions,
    get_file_entries,
    get_git_stats,
    init_db,
    latest_pattern_run,
    latest_scan,
    pattern_adjudication_report,
    pattern_finding_states,
    pattern_findings_summary,
    pattern_rule_runs,
    previous_scan,
    record_pattern_rule_failure,
    record_pattern_rule_success,
    replace_pattern_scan_results,
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
from weave_quality.prose_rules import (
    PROSE_LANGUAGES,
    PatternRuleExecutionError,
    PatternRuleValidationError,
    load_prose_rule,
    run_prose_rule,
    validate_pattern_rule,
)
from weave_quality.python_parser import analyze_python_file

log = logging.getLogger(__name__)

__all__ = ["cmd_findings_promote"]

_VERSION_FILE = Path(__file__).parent.parent / "lib" / "VERSION"
_SCANNER_VERSION = _VERSION_FILE.read_text().strip() if _VERSION_FILE.exists() else ""
_MSG_NO_DB = "No quality.db found. Run 'wv quality scan' first."
_MSG_NO_SCAN = "No scan data. Run 'wv quality scan' first."
_MSG_NO_PATTERN_SCAN = "No pattern scan data. Run 'wv quality patterns scan' first."
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

    Uses the given path, or WV_REPO_ROOT_OVERRIDE env, or REPO_ROOT env, or
    git rev-parse. Critical: when run from earth-engine-analysis/, scanner
    must target THAT repo, not memory-system/ where wv is installed.

    wv-20adef (external code review round 2): the bash `wv` entry point's
    own wv-config.sh UNCONDITIONALLY reassigns REPO_ROOT from
    `git rev-parse --show-toplevel` (the CURRENT PROCESS's cwd), regardless
    of whatever value the parent process already set it to -- so a caller
    like the MCP server's internal `wv quality patterns report` call, which
    sets REPO_ROOT via subprocess env specifically to steer repo resolution
    somewhere other than its own cwd, gets silently overridden before this
    function ever sees it (report never receives an explicit path argument
    for repo-resolution purposes at all -- see cmd_patterns_list's own
    comment in the MCP server). WV_REPO_ROOT_OVERRIDE is never touched by
    wv-config.sh, so a caller that needs to steer repo resolution past that
    reassignment sets THIS instead, checked first.
    """
    if path:
        return str(Path(path).resolve())

    override = os.environ.get("WV_REPO_ROOT_OVERRIDE", "")
    if override:
        return override

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
    repo = Path(_resolve_repo(None))
    conn = init_db(args.hot_zone)
    run = latest_pattern_run(conn)
    if run is None:
        conn.close()
        print(_MSG_NO_PATTERN_SCAN, file=sys.stderr)
        return 1

    conf_disabled = _disabled_patterns(repo / ".weave" / "quality.conf")
    try:
        rules = _load_pattern_rules(repo, conf_disabled)
    except PatternRuleValidationError as exc:
        conn.close()
        return _pattern_rule_error(exc, args.json)
    receipts = {str(row["rule_id"]): row for row in pattern_rule_runs(conn, run.id)}
    summary = pattern_findings_summary(conn, run.id)
    current_hashes = {
        rule_id: _pattern_definition_hash(rule_path) for rule_id, rule_path, _ in rules
    }
    incomplete = [
        rule_id
        for rule_id, definition_hash in current_hashes.items()
        if (receipt := receipts.get(rule_id)) is None
        or receipt["status"] != "success"
        or receipt["definition_hash"] != definition_hash
    ]
    incomplete.extend(
        str(row["rule_id"])
        for row in summary
        if str(row["rule_id"]) not in current_hashes
    )
    conn.close()

    if incomplete:
        detail = (
            "pattern findings are not a complete successful snapshot for active rules: "
            + ", ".join(sorted(set(incomplete)))
            + "; run: wv quality patterns scan"
        )
        if args.json:
            print(json.dumps({"error": "incomplete_pattern_scan", "detail": detail}))
        else:
            print(f"Error: {detail}", file=sys.stderr)
        return 1

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
) -> list[tuple[str, Path, str]]:
    """Return [(rule_id, rule_path, language)] for all active pattern rules.

    Loads from:
      1. _DEFAULT_PATTERNS_DIR (built-in curated rules)
      2. <repo>/.weave/patterns/managed/*.yaml (projected by wv init-repo)
      3. <repo>/.weave/patterns/*.yaml (user-defined rules)
    Rules whose id appears in conf_disabled are skipped.

    language is captured here from validate_pattern_rule's own return value
    (it already reads and parses the file to validate it) instead of being
    re-derived later by a separate rule_language(rule_path) call. A second,
    unguarded read raced a rule file that vanished or became unreadable
    between validation and classification: rule_language() swallows OSError
    into "", which silently misclassified an already-validated prose rule as
    a code rule -- one that could then be dropped from `rules` entirely
    before ever reaching the per-rule execution boundary that would
    otherwise record a failed receipt (see wv-dc2e44).
    """
    rules: list[tuple[str, Path, str]] = []
    patterns_dir = repo / ".weave" / "patterns"
    seen: dict[str, Path] = {}
    for rule_dir in (
        _DEFAULT_PATTERNS_DIR,
        patterns_dir / "managed",
        patterns_dir,
    ):
        if not rule_dir.is_dir():
            continue
        for yf in sorted(rule_dir.glob("*.yaml")):
            rule_id = yf.stem
            language = validate_pattern_rule(yf, rule_id)
            if rule_id in conf_disabled:
                continue
            if rule_id in seen:
                raise PatternRuleValidationError(
                    f"duplicate pattern id {rule_id!r}: {seen[rule_id]} and {yf}"
                )
            seen[rule_id] = yf
            rules.append((rule_id, yf, language))
    return rules


def _shadowed_managed_pattern_ids(repo: Path) -> list[str]:
    """Return rule ids a project-local rule is currently shadowing.

    install.sh's managed-pattern reconcile writes <repo>/.weave/patterns/managed/.overridden
    whenever a same-named .weave/patterns/<id>.yaml exists, so the managed
    (often refined) version was never distributed into the repo. That is
    almost always a completed promotion round-trip where the local copy
    should be deleted — surface it instead of leaving it silent.
    """
    overridden_file = repo / ".weave" / "patterns" / "managed" / ".overridden"
    if not overridden_file.is_file():
        return []
    ids = []
    for line in overridden_file.read_text(encoding="utf-8").splitlines():
        name = line.strip()
        if name.endswith(".yaml"):
            ids.append(name[: -len(".yaml")])
    return ids


def _pattern_rule_error(exc: PatternRuleValidationError, json_out: bool) -> int:
    """Report an invalid pattern definition without presenting it as active."""
    if json_out:
        print(json.dumps({"error": "invalid_pattern_rule", "detail": str(exc)}))
    else:
        print(f"patterns: invalid rule: {exc}", file=sys.stderr)
    return 1


def _non_directory_repo_root_error(repo: Path, json_out: bool) -> int | None:
    """Reject a `path` argument that resolves to something other than a
    directory, returning an exit code to return immediately -- or None
    when `repo` is fine (an existing directory).

    wv-5b9f55 finding 9 (external code review): unlike scan/report,
    where `path` names a scan TARGET within a fixed repo (a single file
    is a legitimate target there), list/validate resolve `path` as the
    REPOSITORY ROOT itself -- _candidate_pattern_files/_load_pattern_rules
    both build `repo / ".weave" / "patterns"` and simply skip it via
    `rule_dir.is_dir()` when it isn't a directory, silently falling back
    to built-in rules only. That produced a misleadingly clean "validate"
    result (or an incomplete "list") with no indication the project's own
    custom/managed rules were never even looked for -- failing loudly
    here instead.

    wv-210ec4 (external code review round 2): the original check
    exempted a MISSING or broken-symlink path from this contract
    (`repo.exists()` is False for both, same as it is for a fresh, never-
    created directory) on the theory that "doesn't exist" was a separate,
    pre-existing concern -- but the MCP contract documents `path` as
    "must be a directory" unconditionally, and a missing/broken root is
    exactly the misleading-clean-result trap this function exists to
    close: a typo'd or stale path still silently validated built-ins
    only, indistinguishable from a project with no custom rules at all.
    `not repo.is_dir()` covers missing, broken-symlink, and non-directory
    file in one check -- `_resolve_repo`'s own fallbacks (explicit path,
    REPO_ROOT env, git root, cwd) always resolve to a real existing
    directory in ordinary use, so this only ever fires for a genuinely
    bad explicit `path` argument.

    wv-0065a6 (external code review round 3, finding 8): `repo.is_dir()`
    itself raises PermissionError/OSError (not just returns False) when a
    parent directory in `repo`'s own path is unreadable -- e.g. a repo
    root sitting behind a chmod-000 ancestor -- producing an uncaught
    traceback instead of this function's own promised structured JSON
    error. Treated the same as "not a directory": we genuinely can't
    confirm `repo` is usable either way.
    """
    try:
        repo_is_dir = repo.is_dir()
    except OSError as exc:
        detail = f"{repo} could not be accessed ({exc.strerror or exc}) -- check its permissions"
        if json_out:
            print(json.dumps({"error": "invalid_repo_root", "detail": detail}))
        else:
            print(f"patterns: {detail}", file=sys.stderr)
        return 1
    if not repo_is_dir:
        detail = (
            f"{repo} is not a directory -- list/validate resolve `path` as the "
            "repository ROOT (the base for .weave/patterns/), not a scan target "
            "file; pass the repository directory instead"
        )
        if json_out:
            print(json.dumps({"error": "invalid_repo_root", "detail": detail}))
        else:
            print(f"patterns: {detail}", file=sys.stderr)
        return 1
    return None


def _pattern_definition_hash(rule_path: Path) -> str:
    """Return the stable content hash used to bind execution receipts."""
    return hashlib.sha256(rule_path.read_bytes()).hexdigest()


def _normalise_finding_identity_text(value: str) -> str:
    """Normalize prose/code fragments without depending on source line layout."""
    return " ".join(unicodedata.normalize("NFKC", value).split())


def _attach_pattern_finding_identities(
    findings: list[PatternFinding], target: Path, repo: Path
) -> None:
    """Bind findings to rule, path, normalized match, and source-line context.

    A source-read failure (deleted mid-scan, permission denied, ...) is
    NOT swallowed here -- it propagates to the caller (cmd_patterns_scan),
    which runs this inside the same per-rule PatternRuleExecutionError
    boundary as rule execution itself, so it becomes a recorded failed
    receipt. Silently falling back to an empty source previously let a
    finding whose context could never actually be read still get recorded
    as a successful, correctly-identified finding.
    """
    source_cache: dict[str, list[str]] = {}
    for finding in findings:
        source = target / finding.path if target.is_dir() else target
        cache_key = str(source)
        if cache_key not in source_cache:
            source_cache[cache_key] = source.read_text(
                encoding="utf-8", errors="replace"
            ).splitlines()
        lines = source_cache[cache_key]
        context = lines[finding.line - 1] if 0 < finding.line <= len(lines) else finding.match_text
        # os.path.abspath, not Path.resolve() -- resolve() follows symlinks,
        # which would key a symlinked file's finding identity/report path on
        # its target's location rather than the name it was actually scanned
        # under, and could fold a real file and a symlink to it into a
        # collision (or split one file's own identity across two labels).
        try:
            finding.path = (
                Path(os.path.abspath(str(source)))
                .relative_to(Path(os.path.abspath(str(repo))))
                .as_posix()
            )
        except ValueError:
            # Outside repo (a test fixture, or any --path pointed elsewhere):
            # the target-relative label alone (e.g. "a.md") isn't a stable
            # identity -- two distinct files under different external
            # targets can share it, colliding their finding_key and
            # adjudication history. Use the lexical absolute source path
            # instead; _report_scope scopes reports against this same form.
            finding.path = Path(os.path.abspath(str(source))).as_posix()
        normalized_match = _normalise_finding_identity_text(finding.match_text)
        finding.context_text = _normalise_finding_identity_text(context)
        identity = json.dumps(
            [finding.rule_id, finding.path, normalized_match, finding.context_text],
            ensure_ascii=False,
            separators=(",", ":"),
        )
        finding.finding_key = "qf-" + hashlib.sha256(identity.encode("utf-8")).hexdigest()


def _pattern_execution_error(exc: PatternRuleExecutionError, json_out: bool) -> int:
    """Report a rule execution failure without replacing prior findings."""
    if json_out:
        print(json.dumps({"error": "pattern_rule_execution_failed", "detail": str(exc)}))
    else:
        print(f"patterns: rule execution failed: {exc}", file=sys.stderr)
    return 1


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


def _validate_ast_grep_match(match: dict[str, object], rule_path: Path, target: Path) -> None:
    """Validate one ast-grep JSON match record before path/range handling.

    A malformed record -- from a backend bug, or a crafted/corrupted
    process substitution -- must fail closed as PatternRuleExecutionError,
    not escape as an uncaught AttributeError/TypeError/ValueError from a
    downstream .get()/int() call, and not silently resolve an empty "file"
    field to Path("") == "." (which can pass the directory-target
    containment check when cwd happens to equal the target, creating a
    phantom finding at that path). line/column are optional (default 0,
    matching the original relaxed .get(key, 0) reads) but must be
    nonnegative integers -- excluding bool, which is an int subclass in
    Python -- when present. A NUL byte in "file" passes every check above
    (nonempty string, lexical abspath/relative_to containment) but later
    raises ValueError ("embedded null byte") the first time something
    actually opens the path (e.g. Path.read_text() during finding-identity
    attachment) -- reject it here instead, at the same boundary as every
    other malformed-record case.
    """

    def fail(detail: str) -> NoReturn:
        raise PatternRuleExecutionError(
            f"{rule_path}: ast-grep returned a malformed match record for {target}: {detail}"
        )

    file_field = match.get("file")
    if not isinstance(file_field, str) or not file_field:
        fail("file must be a nonempty string")
    if "\x00" in file_field:
        fail("file must not contain a NUL byte")
    rng = match.get("range")
    if not isinstance(rng, dict):
        fail("range must be an object")
    start = rng.get("start")
    if not isinstance(start, dict):
        fail("range.start must be an object")
    for key in ("line", "column"):
        value = start.get(key, 0)
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            fail(f"range.start.{key} must be a nonnegative integer")
    text = match.get("text", "")
    if not isinstance(text, str):
        fail("text must be a string")


def _run_pattern_rule(
    rule_id: str, rule_path: Path, target: Path, scan_id: int, repo: Path, language: str
) -> list[PatternFinding]:
    """Run one rule file on target; return PatternFinding list.

    language is the caller's already-validated classification (see
    _load_pattern_rules), not re-derived here -- a second rule_language()
    read at execution time could race a rule file that vanishes between
    validation and this call, silently reclassifying an already-validated
    prose rule as code instead of surfacing the read failure as a proper
    execution error.
    """
    if language in PROSE_LANGUAGES:
        return run_prose_rule(rule_id, rule_path, target, scan_id, repo)

    ast_grep = ast_grep_bin()
    if not ast_grep:
        return []
    cmd = [ast_grep, "scan", "--rule", str(rule_path), "--json", str(target)]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=60, check=False)
    except subprocess.TimeoutExpired as exc:
        raise PatternRuleExecutionError(
            f"{rule_path}: ast-grep timed out scanning {target}"
        ) from exc
    if proc.returncode not in (0, 1):
        detail = proc.stderr.strip()[:500] or f"exit {proc.returncode}"
        raise PatternRuleExecutionError(f"{rule_path}: ast-grep failed on {target}: {detail}")
    if not proc.stdout.strip():
        return []
    try:
        matches = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise PatternRuleExecutionError(
            f"{rule_path}: ast-grep returned malformed JSON for {target}"
        ) from exc
    if not isinstance(matches, list):
        raise PatternRuleExecutionError(
            f"{rule_path}: ast-grep returned non-list JSON for {target}"
        )
    findings: list[PatternFinding] = []
    for match in matches:
        if not isinstance(match, dict):
            raise PatternRuleExecutionError(
                f"{rule_path}: ast-grep returned an invalid match record for {target}"
            )
        _validate_ast_grep_match(match, rule_path, target)
        rng = match["range"]
        start = rng["start"]
        match_path = Path(str(match["file"]))
        # os.path.abspath (not .resolve(), which would follow symlinks and
        # relabel a result under its target's real location) normalizes away
        # "." / ".." components before the containment check below --
        # relative_to() alone does a purely lexical prefix comparison, so an
        # unnormalized "target/../sibling/x.py" would pass containment
        # against "target" despite lexically escaping it.
        norm_match = Path(os.path.abspath(str(match_path)))
        norm_target = Path(os.path.abspath(str(target)))
        if target.is_dir():
            try:
                display_path = str(norm_match.relative_to(norm_target))
            except ValueError as exc:
                raise PatternRuleExecutionError(
                    f"{rule_path}: ast-grep returned a file outside target {target}: {match_path}"
                ) from exc
        else:
            # A single-file target has no containment relationship to check
            # via relative_to -- the result must name that exact file, not
            # merely share its basename with a different file elsewhere.
            if norm_match != norm_target:
                raise PatternRuleExecutionError(
                    f"{rule_path}: ast-grep returned a file outside target {target}: {match_path}"
                )
            display_path = norm_target.name
        findings.append(
            PatternFinding(
                path=display_path,
                scan_id=scan_id,
                rule_id=rule_id,
                line=int(start.get("line", 0)) + 1,
                col=int(start.get("column", 0)),
                match_text=str(match.get("text", "")),
                severity="warning",
            )
        )
    return findings


def cmd_patterns_scan(args: argparse.Namespace) -> int:
    """Run all active pattern rules and store findings."""
    repo = Path(_resolve_repo(None))
    conn = init_db(args.hot_zone)

    conf_disabled = _disabled_patterns(repo / ".weave" / "quality.conf")
    try:
        rules = _load_pattern_rules(repo, conf_disabled)
    except PatternRuleValidationError as exc:
        conn.close()
        return _pattern_rule_error(exc, args.json)
    prose_rules = [
        (rule_id, rule_path, language)
        for rule_id, rule_path, language in rules
        if language in PROSE_LANGUAGES
    ]
    code_rules = [
        (rule_id, rule_path, language)
        for rule_id, rule_path, language in rules
        if language not in PROSE_LANGUAGES
    ]
    if code_rules and not ast_grep_available():
        print(
            f"patterns: skipping {len(code_rules)} code rule(s) "
            "(ast-grep not found; run ./install.sh); prose rules still run",
            file=sys.stderr,
        )
        rules = prose_rules

    # Canonicalize and validate the target before the no-rules branch below
    # -- a zero-rule invocation (every rule disabled, or only code rules
    # exist and ast-grep is unavailable) must still reject a nonexistent
    # target rather than reporting success.
    target, canonical_target = _canonicalize_target(repo, getattr(args, "path", None))
    if not target.exists():
        conn.close()
        return _pattern_execution_error(
            PatternRuleExecutionError(f"target does not exist: {target}"), args.json
        )

    if not rules:
        # Every invocation gets its own pattern_runs lifecycle row, even a
        # zero-rule one -- otherwise report/list keep presenting an earlier
        # target's scope, and this successful invocation is simply absent
        # from lifecycle history (see wv-40d3d6).
        run_id = begin_pattern_run(conn, git_head_sha(repo), canonical_target)
        finish_pattern_run(conn, run_id, files_count=0, duration_ms=0)
        conn.close()
        msg = "No pattern rules found."
        print(
            json.dumps(
                {
                    "rules": 0,
                    "rules_run": 0,
                    "findings": 0,
                    "by_rule": {},
                    "matches": [],
                }
            )
            if args.json
            else msg
        )
        return 0

    # Pattern scans get their own lifecycle id, independent of scan_meta (the
    # complexity-scan sequence) -- a rescan or an unrelated `wv quality scan`
    # must not collide with or prune this invocation's findings.
    run_id = begin_pattern_run(conn, git_head_sha(repo), canonical_target)
    started = time.time()

    all_findings: list[PatternFinding] = []
    successful_runs: list[dict[str, object]] = []
    for rule_id, rule_path, language in rules:
        # "" default -- if _pattern_definition_hash itself fails below (the
        # rule file vanished between discovery and here), the except clause
        # still has SOME value to record a failed receipt with.
        definition_hash = ""
        try:
            # Hashing is inside the boundary too: a rule that disappears
            # after _load_pattern_rules discovered it (deleted mid-scan)
            # must record a failed receipt, not escape here uncaught before
            # a single try/except in this loop has even started watching.
            definition_hash = _pattern_definition_hash(rule_path)
            found = _run_pattern_rule(rule_id, rule_path, target, run_id, repo, language)
            # Identity attachment reads each finding's source file and
            # builds a Path from a backend-derived path string -- kept
            # inside this same failure boundary (not run once for the
            # whole scan afterward) so a path a validated-but-still-bad
            # backend result produces (or any other OS/Path failure here)
            # becomes a PatternRuleExecutionError and a recorded failed
            # receipt for the rule that actually produced it, instead of an
            # uncaught exception that leaves the run unfinished with no
            # receipt and silently drops every finding gathered so far.
            _attach_pattern_finding_identities(found, target, repo)
        except PatternRuleExecutionError as exc:
            record_pattern_rule_failure(
                conn,
                run_id,
                rule_id,
                definition_hash,
                str(rule_path),
                canonical_target,
                str(exc),
            )
            conn.close()
            return _pattern_execution_error(exc, args.json)
        except (OSError, ValueError) as exc:
            wrapped = PatternRuleExecutionError(
                f"{rule_path}: failed to prepare or execute rule against {target}: {exc}"
            )
            record_pattern_rule_failure(
                conn,
                run_id,
                rule_id,
                definition_hash,
                str(rule_path),
                canonical_target,
                str(wrapped),
            )
            conn.close()
            return _pattern_execution_error(wrapped, args.json)
        # Recorded immediately (not only via the batched
        # replace_pattern_scan_results call below) so this rule's
        # successful, zero-hit-or-not receipt survives a LATER rule's
        # failure in the same scan -- otherwise a completed rule is
        # reported "not_run", indistinguishable from never having executed,
        # whenever any later rule in the same invocation fails.
        record_pattern_rule_success(
            conn, run_id, rule_id, definition_hash, str(rule_path), canonical_target, len(found)
        )
        all_findings.extend(found)
        successful_runs.append(
            {
                "rule_id": rule_id,
                "definition_hash": definition_hash,
                "rule_path": str(rule_path),
                "target": canonical_target,
                "hits": len(found),
                "ran_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
            }
        )

    # wv-c71833: snapshot each rule's own raw match count before the
    # same-start-location collision suppression below can shrink it. This
    # is distinct from and unaffected by that suppression -- it is what the
    # rule itself matched -- and is surfaced in the scan output (raw_hits)
    # so a rule that loses every match to a higher-maturity rule at the
    # same (path, line, col) still shows evidence of having matched
    # something, instead of reading identically to a genuine zero-hit rule.
    raw_hits_by_rule = {str(run["rule_id"]): int(str(run["hits"])) for run in successful_runs}

    # wv-19bc39 (external code review round 3 re-audit): two different rule
    # ids can each independently flag the identical (path, line, col) -- the
    # audit's own reproduction had a built-in and a project-local prose rule
    # both firing on the same comma-plus-"so" text, inflating the scan total
    # and adjudication/waiver tracking with what is, from a reader's
    # perspective, one finding counted twice. Keyed on (path, line, col)
    # only, not match_text -- the two colliding rules captured slightly
    # different surrounding text at the SAME start position in the audit's
    # own repro. Deliberately narrow: does not attempt to merge findings
    # whose spans overlap at DIFFERENT start columns (a fuzzier, unrelated
    # problem) -- only an exact (path, line, col) collision counts.
    # Higher-maturity rule wins (promotable > observed > candidate); code
    # rules and ties fall back to rule_id order for a deterministic pick.
    # This only trims the STORED/REPORTED finding set -- each rule's own
    # per-rule "hits" receipt (record_pattern_rule_success, already written
    # above) is unaffected and still counts every match that rule itself
    # produced, independent of what any other rule also matched at the same
    # spot; that is an intrinsic property of the rule, not a duplicate.
    if len(all_findings) > 1:
        rule_maturity: dict[str, str] = {}
        for maturity_rule_id, maturity_rule_path, maturity_language in rules:
            if maturity_language in PROSE_LANGUAGES:
                try:
                    parsed_rule = load_prose_rule(maturity_rule_path, maturity_rule_id)
                except (PatternRuleValidationError, OSError, ValueError):
                    continue
                rule_maturity[maturity_rule_id] = str(parsed_rule.get("maturity", "candidate"))
        maturity_rank = {"promotable": 2, "observed": 1, "candidate": 0}
        by_span: dict[tuple[str, int, int], list[PatternFinding]] = {}
        for pf in all_findings:
            by_span.setdefault((pf.path, pf.line, pf.col), []).append(pf)
        if any(len(group) > 1 for group in by_span.values()):
            deduped: list[PatternFinding] = []
            for group in by_span.values():
                group.sort(
                    key=lambda f: (
                        -maturity_rank.get(rule_maturity.get(f.rule_id, "candidate"), 0),
                        f.rule_id,
                    )
                )
                deduped.append(group[0])
            all_findings = deduped

    # wv-c71833: the receipt's persisted "hits" must agree with what this
    # same invocation reports in by_rule and stores in pattern_findings --
    # otherwise `patterns scan`, `patterns list`, and a rule's own receipt
    # read as three different counts for the same run. Overwrite each
    # successful run's hits from the (possibly deduped) all_findings that
    # actually landed in the store; raw_hits_by_rule (captured above, before
    # dedup) still carries what the rule itself matched for the scan output.
    final_hits_by_rule: dict[str, int] = {}
    for pf in all_findings:
        final_hits_by_rule[pf.rule_id] = final_hits_by_rule.get(pf.rule_id, 0) + 1
    for run in successful_runs:
        run["hits"] = final_hits_by_rule.get(str(run["rule_id"]), 0)

    replace_pattern_scan_results(conn, run_id, all_findings, successful_runs)
    finish_pattern_run(
        conn,
        run_id,
        files_count=len({finding.path for finding in all_findings}),
        duration_ms=int((time.time() - started) * 1000),
    )
    finding_states = {
        str(row["finding_key"]): row
        for row in pattern_finding_states(
            conn, sorted({finding.finding_key for finding in all_findings})
        )
    }
    conn.close()

    summary = {r: sum(1 for f in all_findings if f.rule_id == r) for r, _, _ in rules}
    # wv-c71833: by_rule (== stored receipt hits == patterns list count for
    # this scan) vs. what each rule itself matched before same-start-location
    # collision suppression -- only present as its own key so by_rule's
    # values keep meaning exactly one thing (the reported/stored count).
    raw_hits = {r: raw_hits_by_rule.get(r, 0) for r, _, _ in rules}
    total = len(all_findings)

    matches = [
        {
            "rule_id": finding.rule_id,
            "path": finding.path,
            "line": finding.line,
            "col": finding.col + 1,
            "match_text": finding.match_text,
            "severity": finding.severity,
            "finding_key": finding.finding_key,
            "disposition": finding_states[finding.finding_key]["disposition"],
            "scan_count": finding_states[finding.finding_key]["scan_count"],
        }
        for finding in sorted(
            all_findings,
            key=lambda finding: (finding.rule_id, finding.path, finding.line, finding.col),
        )
    ]
    if args.json:
        print(
            json.dumps(
                {
                    "rules": len(rules),
                    "rules_run": len(rules),
                    "findings": total,
                    "by_rule": summary,
                    "raw_hits": raw_hits,
                    "matches": matches,
                }
            )
        )
    else:
        print(f"Pattern scan complete: {len(rules)} rules, {total} findings")
        for rule_id, count in sorted(summary.items(), key=lambda x: -x[1]):
            raw = raw_hits.get(rule_id, count)
            suffix = (
                f"  ({raw} matched, {raw - count} suppressed as same-position duplicate)"
                if raw > count
                else ""
            )
            print(f"  {rule_id}: {count}{suffix}")
            for finding in matches:
                if finding["rule_id"] == rule_id:
                    match_text = str(finding["match_text"]).replace("\n", " ")
                    print(
                        f"    {finding['path']}:{finding['line']}:{finding['col']}: "
                        f"[{finding['rule_id']}/{finding['severity']}] {match_text}"
                    )
    return 0


def cmd_patterns_adjudicate(args: argparse.Namespace) -> int:
    """Apply a human disposition to one stable pattern finding identity."""
    conn = init_db(args.hot_zone)
    row = adjudicate_pattern_finding(
        conn, args.finding_key, args.disposition, getattr(args, "note", None)
    )
    if row is None:
        conn.close()
        detail = f"unknown pattern finding key: {args.finding_key}"
        if args.json:
            print(json.dumps({"error": "pattern_finding_not_found", "detail": detail}))
        else:
            print(f"Error: {detail}", file=sys.stderr)
        return 1
    report = pattern_adjudication_report(conn)
    conn.close()
    payload = {"finding": row, "report": report}
    if args.json:
        print(json.dumps(payload))
    else:
        print(
            f"Adjudicated {row['finding_key']}: {row['disposition']} "
            f"({row['rule_id']} {row['path']})"
        )
    return 0


def _canonicalize_target(repo: Path, raw: str | None) -> tuple[Path, str]:
    """Resolve a raw CLI path argument against cwd, then relativize to repo.

    Returns (absolute lexical Path, canonical repo-relative posix string --
    or an absolute string when the target is outside repo, e.g. a test
    fixture). Shared by cmd_patterns_scan (to pick the scan target) and
    cmd_patterns_report (to interpret an explicit `--path` the same way) --
    an explicit CLI argument is cwd-relative like any other path argument,
    unlike a *stored* scan target, which cmd_patterns_scan already wrote out
    canonicalized and so is used as-is (see _report_scope).

    Absolute via os.path.abspath, not Path.resolve() -- resolve() follows
    symlinks, which would make a symlinked target's canonical label (and
    thus its paths: matching and report scoping) reflect where the symlink
    points rather than the name the caller actually asked for.
    """
    target = Path(os.path.abspath(raw)) if raw else repo
    try:
        canonical = target.relative_to(repo).as_posix()
    except ValueError:
        # Outside repo (e.g. a test fixture) -- keep an absolute label rather
        # than raising; scans/reports against synthetic targets are still valid.
        canonical = str(target)
    return target, canonical


def _report_scope(repo: Path, target_str: str | None) -> tuple[str | None, str | None]:
    """Resolve a stored scan target to (display label, repo-relative path-prefix filter).

    The label is the raw target string (matching how `list` shows "last
    scanned: <target>"); the filter is None -- meaning report everything,
    unscoped -- only when there's no known target yet, or the target IS the
    repo root (a "." prefix would reject every finding instead of admitting
    all of them). A target outside the repo (e.g. an explicit `--path`
    elsewhere, or a test fixture) still gets a filter: its lexical absolute
    path, matching how _attach_pattern_finding_identities identifies
    findings under it.

    `patterns scan` now stores a canonical repo-relative posix string (see
    cmd_patterns_scan) -- that's used directly rather than re-resolved
    against the current process cwd, which is what made a stored relative
    target resolve differently depending on where `report` was later
    invoked from. An absolute target_str (an explicit `--path` argument, or
    a receipt written before this fix) is still resolved against repo for
    backward compatibility.
    """
    if not target_str:
        return None, None
    candidate = Path(target_str)
    if candidate.is_absolute():
        # Legacy absolute receipt (written before targets were canonicalized)
        # -- os.path.abspath, not .resolve(), so this stays consistent with
        # the lexical (non-symlink-following) paths used everywhere else.
        try:
            rel = (
                Path(os.path.abspath(target_str))
                .relative_to(Path(os.path.abspath(str(repo))))
                .as_posix()
            )
        except ValueError:
            # Genuinely outside repo -- scope by the same lexical absolute
            # path findings under it were identified by, instead of
            # dropping the filter and reporting everything unscoped.
            rel = Path(os.path.abspath(target_str)).as_posix()
    else:
        rel = candidate.as_posix()
    return target_str, None if rel == "." else rel


def cmd_patterns_report(args: argparse.Namespace) -> int:
    """Report per-rule precision and recurring waiver clusters, scoped to a target."""
    repo = Path(_resolve_repo(None))
    conn = init_db(args.hot_zone)
    run = latest_pattern_run(conn)
    # The run row itself names the scope, not a receipt derived from it -- an
    # interrupted or zero-rule run still has a target on pattern_runs even
    # with no (or zero) per-rule receipts, so deriving scope from the first
    # receipt would silently fall back to an unscoped report for those runs.
    last_scan_target = run.target if run is not None else None
    explicit_path = getattr(args, "path", None)
    target_str: str | None
    if explicit_path:
        # A CLI argument is cwd-relative like any other path argument --
        # canonicalize it the same way cmd_patterns_scan canonicalizes its
        # own target, instead of treating it as already repo-relative (only
        # the STORED last_scan_target actually is).
        _, target_str = _canonicalize_target(repo, str(explicit_path))
    else:
        target_str = last_scan_target
    scope_label, scope_prefix = _report_scope(repo, target_str)
    report = pattern_adjudication_report(conn, path_prefix=scope_prefix)
    conn.close()
    report["scope"] = scope_label
    if args.json:
        print(json.dumps(report))
        return 0
    if not report["by_rule"]:
        msg = "No pattern findings have been observed."
        if scope_label is not None:
            msg = f"No pattern findings have been observed under {scope_label}."
        print(msg)
        return 0
    scope_suffix = f" (scope: {scope_label})" if scope_label is not None else ""
    print(f"Pattern adjudication report{scope_suffix}:")
    by_rule = report["by_rule"]
    assert isinstance(by_rule, dict)
    needs_adjudication: list[str] = []
    for rule_id, summary in by_rule.items():
        assert isinstance(summary, dict)
        precision = summary["decided_precision"]
        precision_text = "unavailable" if precision is None else f"{float(precision):.3f}"
        actionable = summary["actionable_rate"]
        actionable_text = (
            "unavailable" if actionable is None else f"{float(actionable):.3f}"
        )
        nudge = ""
        if summary.get("needs_adjudication"):
            needs_adjudication.append(rule_id)
            nudge = " [needs adjudication]"
        print(
            f"  {rule_id}: decided_precision={precision_text} "
            f"actionable_rate={actionable_text} "
            f"decided_count={summary['decided_count']} "
            f"findings={summary['findings']} occurrences={summary['occurrences']} "
            f"unresolved={summary['unresolved']}{nudge}"
        )
    if needs_adjudication:
        print(
            f"Needs adjudication (0 decided across >= {ADJUDICATION_NUDGE_SCANS} "
            f"scans of occurrence): {', '.join(needs_adjudication)}"
        )
    waivers = report["recurring_waivers"]
    assert isinstance(waivers, list)
    print(f"Recurring waivers: {len(waivers)}")
    for waiver in waivers:
        assert isinstance(waiver, dict)
        print(
            f"  {waiver['finding_key']} {waiver['rule_id']} {waiver['path']} "
            f"scans={waiver['scan_count']}"
        )
    return 0


_PROSE_SCHEMA_KINDS = ("lexicon", "motif", "density", "regex")
_PROSE_SCHEMA_MATCH_SCOPES = ("line", "paragraph", "document")
_PROSE_SCHEMA_MATURITIES = ("candidate", "observed", "promotable")
_PROSE_SCHEMA_OPTIONAL_KEYS = (
    "exempt",
    "paths",
    "min_count",
    "require_no_digit_within",
    "positive_controls",
    "negative_controls",
    "severity",
    "policy",
    "provenance",
    "message",
)


class _RuleSchemaInfo(TypedDict):
    """Coverage-relevant fields for one validated prose rule.

    Kept out of the JSON-serializable result entries (a plain dict[str,
    object]) and tracked separately by id(entry) instead -- so a rule
    invalidated by a later id-collision check is trivially excluded from
    coverage just by not being looked up, with nothing to pop/clean up.
    """

    kind: str
    match_scope: str
    maturity: str | None
    keys: list[str]


def _candidate_pattern_files(repo: Path) -> list[Path]:
    """Return every *.yaml candidate across all three rule tiers, duplicates and all.

    Unlike `_load_pattern_rules` (which fails closed on the first invalid
    file, and treats a same-id collision across tiers as fatal), this
    enumerates every file so `validate` can report every rule's own status
    in one pass instead of one-fix-rerun-repeat.
    """
    patterns_dir = repo / ".weave" / "patterns"
    files: list[Path] = []
    for rule_dir in (_DEFAULT_PATTERNS_DIR, patterns_dir / "managed", patterns_dir):
        if rule_dir.is_dir():
            files.extend(sorted(rule_dir.glob("*.yaml")))
    return files


def cmd_patterns_validate(args: argparse.Namespace) -> int:
    """Validate every candidate rule independently and report schema coverage.

    `list`/`scan` fail closed on the first invalid rule file, which turns
    fixing several broken rules into a one-at-a-time loop. This validates
    each candidate on its own so every error surfaces in one pass, plus a
    coverage summary of which documented prose schema kind/match_scope/
    maturity/optional-key values are actually exercised by the valid ones --
    catching schema surface that's documented but dead.
    """
    repo = Path(_resolve_repo(getattr(args, "path", None)))
    error_code = _non_directory_repo_root_error(repo, args.json)
    if error_code is not None:
        return error_code
    try:
        files = _candidate_pattern_files(repo)
    except OSError as exc:
        # wv-0065a6 (external code review round 3, finding 8): repo itself
        # passed _non_directory_repo_root_error's check above, but a
        # *tier* directory under it (e.g. .weave/patterns/ made
        # unreadable, not just missing) can still raise PermissionError
        # out of rule_dir.is_dir()/.glob() -- an uncaught traceback
        # instead of the structured error this command otherwise
        # promises. A genuinely ABSENT tier directory still stays a
        # silent, valid skip (rule_dir.is_dir() returning False, not
        # raising) -- only inaccessibility is treated as an error.
        detail = f"could not enumerate pattern rule directories under {repo} ({exc.strerror or exc})"
        if args.json:
            print(json.dumps({"error": "invalid_repo_root", "detail": detail}))
        else:
            print(f"patterns: {detail}", file=sys.stderr)
        return 1

    results: list[dict[str, object]] = []
    schema_by_id: dict[int, _RuleSchemaInfo] = {}
    all_valid = True
    for rule_path in files:
        rule_id = rule_path.stem
        entry: dict[str, object] = {"rule_id": rule_id, "path": str(rule_path)}
        try:
            language = validate_pattern_rule(rule_path, rule_id)
            entry["status"] = "valid"
            entry["language"] = language
            if language in PROSE_LANGUAGES:
                rule = load_prose_rule(rule_path, rule_id)
                schema_by_id[id(entry)] = {
                    "kind": str(rule.get("kind", "")),
                    "match_scope": str(rule.get("match_scope", "")),
                    "maturity": str(rule["maturity"]) if "maturity" in rule else None,
                    "keys": [key for key in _PROSE_SCHEMA_OPTIONAL_KEYS if key in rule],
                }
        except PatternRuleValidationError as exc:
            entry["status"] = "invalid"
            entry["error"] = str(exc)
            all_valid = False
        results.append(entry)

    # The real loader (_load_pattern_rules) rejects a same-id rule appearing
    # in more than one tier/file. Cross-check ALL candidates here -- not
    # just the ones that independently validated -- because if one of two
    # same-id files happens to be malformed, the loader fails on ITS error
    # first, but the otherwise-valid copy is just as unusable once that's
    # fixed; flag the collision now instead of only surfacing it in a later
    # validate run. A malformed entry keeps its own parse error with the
    # collision appended, rather than losing it.
    by_id: dict[str, list[dict[str, object]]] = {}
    for entry in results:
        by_id.setdefault(str(entry["rule_id"]), []).append(entry)
    for rule_id, entries in by_id.items():
        if len(entries) < 2:
            continue
        all_paths = sorted(str(e["path"]) for e in entries)
        for entry in entries:
            others = [p for p in all_paths if p != entry["path"]]
            collision = f"duplicate pattern id {rule_id!r} also defined in: " + ", ".join(others)
            if entry["status"] == "valid":
                entry["status"] = "invalid"
                entry.pop("language", None)
                schema_by_id.pop(id(entry), None)
                entry["error"] = collision
            else:
                entry["error"] = f"{entry['error']} (also: {collision})"
        all_valid = False

    # Coverage reflects entries still valid AFTER collision invalidation --
    # computing it from the first pass would count a rule's kind/scope/
    # maturity/keys as "exercised" even though it ended up invalid.
    kinds_seen: set[str] = set()
    scopes_seen: set[str] = set()
    maturities_seen: set[str] = set()
    keys_seen: set[str] = set()
    for entry in results:
        if entry["status"] != "valid":
            continue
        schema = schema_by_id.get(id(entry))
        if schema is None:
            continue
        kinds_seen.add(schema["kind"])
        scopes_seen.add(schema["match_scope"])
        if schema["maturity"] is not None:
            maturities_seen.add(schema["maturity"])
        keys_seen.update(schema["keys"])

    coverage = {
        "kinds": {kind: kind in kinds_seen for kind in _PROSE_SCHEMA_KINDS},
        "match_scopes": {
            scope: scope in scopes_seen for scope in _PROSE_SCHEMA_MATCH_SCOPES
        },
        "maturities": {
            maturity: maturity in maturities_seen for maturity in _PROSE_SCHEMA_MATURITIES
        },
        "optional_keys": {key: key in keys_seen for key in _PROSE_SCHEMA_OPTIONAL_KEYS},
    }
    payload: dict[str, object] = {
        "rules": results,
        "coverage": coverage,
        "valid": all_valid,
    }
    if args.json:
        print(json.dumps(payload))
        return 0 if all_valid else 1

    for entry in results:
        if entry["status"] == "valid":
            print(f"  {entry['rule_id']:40s} [{entry['language']}] valid")
        else:
            print(f"  {entry['rule_id']:40s} INVALID: {entry['error']}")
    print()
    print("Prose schema coverage (valid rules only):")
    for group_name, group in (
        ("kind", coverage["kinds"]),
        ("match_scope", coverage["match_scopes"]),
        ("maturity", coverage["maturities"]),
        ("optional key", coverage["optional_keys"]),
    ):
        assert isinstance(group, dict)
        used = sorted(name for name, present in group.items() if present)
        missing = sorted(name for name, present in group.items() if not present)
        summary = f"  {group_name}: {len(used)}/{len(group)} exercised"
        if missing:
            summary += f", unused: {', '.join(missing)}"
        print(summary)
    return 0 if all_valid else 1


def cmd_patterns_list(args: argparse.Namespace) -> int:
    """List active rules with last-scan hit counts."""
    repo = Path(_resolve_repo(getattr(args, "path", None)))
    error_code = _non_directory_repo_root_error(repo, args.json)
    if error_code is not None:
        return error_code
    conn = init_db(args.hot_zone)
    run = latest_pattern_run(conn)

    try:
        conf_disabled = _disabled_patterns(repo / ".weave" / "quality.conf")
        rules = _load_pattern_rules(repo, conf_disabled)
    except PatternRuleValidationError as exc:
        conn.close()
        return _pattern_rule_error(exc, args.json)
    except OSError as exc:
        # wv-731450 (external code review round 3 re-audit of wv-0065a6):
        # unlike validate's _candidate_pattern_files (guarded), list reads
        # .weave/quality.conf via _disabled_patterns and the tier
        # directories via _load_pattern_rules BEFORE the try block that
        # was only guarding PatternRuleValidationError -- an inaccessible
        # (not just absent) .weave/ still raised an uncaught
        # PermissionError here, the same trap wv-0065a6 closed for
        # validate. A genuinely ABSENT quality.conf/tier directory stays a
        # silent, valid skip (conf_path.exists()/rule_dir.is_dir()
        # returning False, not raising) -- only inaccessibility is an
        # error.
        conn.close()
        detail = f"could not enumerate pattern rule directories under {repo} ({exc.strerror or exc})"
        if args.json:
            print(json.dumps({"error": "invalid_repo_root", "detail": detail}))
        else:
            print(f"patterns: {detail}", file=sys.stderr)
        return 1

    receipts = (
        {str(row["rule_id"]): row for row in pattern_rule_runs(conn, run.id)}
        if run is not None
        else {}
    )
    conn.close()

    try:
        rule_states: list[dict[str, object]] = []
        for rule_id, rule_path, _ in rules:
            receipt = receipts.get(rule_id)
            current_hash = _pattern_definition_hash(rule_path)
            if receipt is None or receipt["definition_hash"] != current_hash:
                state: dict[str, object] = {"status": "not_run", "hits": None}
            else:
                state = {"status": receipt["status"], "hits": receipt["hits"]}
                if receipt["error"]:
                    state["error"] = receipt["error"]
            rule_states.append({"rule_id": rule_id, "path": str(rule_path), **state})

        active_ids = {rule_id for rule_id, _, _ in rules}
        shadowed_ids = [
            rule_id
            for rule_id in _shadowed_managed_pattern_ids(repo)
            if rule_id in active_ids
        ]
    except OSError as exc:
        # Same boundary, the two reads that happen after rules are
        # loaded: _pattern_definition_hash's read_bytes() (a rule file
        # made unreadable between load and hashing) and
        # _shadowed_managed_pattern_ids' is_file()/read_text() on
        # .weave/patterns/managed/.overridden.
        detail = f"could not read pattern metadata under {repo} ({exc.strerror or exc})"
        if args.json:
            print(json.dumps({"error": "invalid_repo_root", "detail": detail}))
        else:
            print(f"patterns: {detail}", file=sys.stderr)
        return 1
    # Advisory only, always on stderr (in both --json and text mode) so it never
    # changes the shape of the stdout payload for existing consumers.
    for rule_id in shadowed_ids:
        # wv-8d16bd (external code review round 3 re-audit): deleting the
        # local copy alone does NOT resync the managed version -- the
        # reconcile that would copy it back into .weave/patterns/managed/
        # only runs on 'wv init-repo --update', not automatically. Deleting
        # without rerunning it drops the rule entirely (24 rules -> 23 in
        # the reported audit), worse than the shadow it "fixed". Name the
        # required follow-up so this warning's own advice is complete.
        print(
            f"⚠ {rule_id}: .weave/patterns/{rule_id}.yaml shadows an available "
            "managed rule of the same id (never applied) — delete the local "
            "copy AND run 'wv init-repo --update' to sync the managed "
            "version, if this was a completed promotion",
            file=sys.stderr,
        )

    if args.json:
        print(json.dumps(rule_states))
    else:
        if not rules:
            print("No active pattern rules.")
            return 0
        # The run row itself names the scope, not a receipt derived from it
        # -- an interrupted or zero-rule run still has a target on
        # pattern_runs even with no per-rule receipts to read it from.
        scan_target = run.target if run is not None else None
        header = f"Active pattern rules ({len(rules)})"
        if scan_target is not None:
            header += f", last scanned: {scan_target}"
        print(f"{header}:")
        for (rule_id, rule_path, _), state in zip(rules, rule_states):
            if rule_path.parent == _DEFAULT_PATTERNS_DIR:
                src = "default"
            elif rule_path.parent.name == "managed":
                src = "managed"
            else:
                src = "custom"
            hits = state["hits"] if state["hits"] is not None else "-"
            print(f"  {rule_id:40s} [{src}] status={state['status']} hits={hits}")
    return 0


def cmd_patterns(args: argparse.Namespace) -> int:
    """Dispatch pattern scan, adjudication, reporting, and promotion commands."""
    sub = getattr(args, "patterns_command", None)
    if sub == "scan":
        return cmd_patterns_scan(args)
    if sub == "list":
        return cmd_patterns_list(args)
    if sub == "promote":
        return _cmd_promote_patterns(args)
    if sub == "adjudicate":
        return cmd_patterns_adjudicate(args)
    if sub == "report":
        return cmd_patterns_report(args)
    if sub == "validate":
        return cmd_patterns_validate(args)
    print(
        "Usage: wv quality patterns {scan,list,adjudicate,report,validate,promote}",
        file=sys.stderr,
    )
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

    pat_adjudicate_p = patterns_sub.add_parser(
        "adjudicate", help="Apply a human disposition to a stable finding key"
    )
    pat_adjudicate_p.add_argument("finding_key", help="Stable qf-* key from pattern scan output")
    pat_adjudicate_p.add_argument(
        "disposition",
        choices=("accepted_defect", "false_positive", "waived", "unresolved"),
    )
    pat_adjudicate_p.add_argument("--note", help="Human rationale or waiver reference")
    pat_adjudicate_p.add_argument("--json", action="store_true", help="JSON output")

    pat_report_p = patterns_sub.add_parser(
        "report", help="Report per-rule precision and recurring waivers"
    )
    pat_report_p.add_argument(
        "path",
        nargs="?",
        help="Scope report to this target (default: last scan's target)",
    )
    pat_report_p.add_argument("--json", action="store_true", help="JSON output")

    pat_validate_p = patterns_sub.add_parser(
        "validate",
        help="Validate every candidate rule independently and report schema coverage",
    )
    pat_validate_p.add_argument("path", nargs="?", help="Repo path (default: repo root)")
    pat_validate_p.add_argument("--json", action="store_true", help="JSON output")

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
