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
import bisect
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import logging
import os
import re
import shlex
import sqlite3
import subprocess
import sys
import time
import unicodedata
from fnmatch import fnmatch
from pathlib import Path
from typing import Any, NoReturn, TypedDict
import tempfile

from weave_quality.ast_cache import ASTCache
from weave_quality.bash_ast_grep import analyze_bash_file_best, ast_grep_available, batch_cc_lines
from weave_quality.bash_heuristic import detect_bash
from weave_quality.classification import classify_file, load_classify_overrides, load_score_baseline
from weave_quality.external_tools import ast_grep_bin
from weave_quality.typescript_parser import analyze_typescript_file
from weave_quality.db import (
    ADJUDICATION_NUDGE_SCANS,
    adjudicate_pattern_finding,
    finding_key_for,
    unique_finding_key_for,
    begin_pattern_run,
    begin_scan,
    bulk_upsert_co_changes,
    bulk_upsert_file_entries,
    bulk_upsert_function_cc,
    bulk_upsert_git_stats,
    db_exists,
    db_path,
    export_pattern_adjudications,
    file_changed,
    finish_pattern_run,
    finish_scan,
    get_all_trend_directions,
    get_file_entries,
    get_git_stats,
    init_db,
    import_pattern_adjudications,
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
    latest_scan_paths,
    worktree_drift,
)
from weave_quality.listing import directory_entries, repo_files
from weave_quality.git_metrics import (
    working_tree_blob_shas,
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
from weave_quality.models import CKMetrics, FileEntry, FunctionCC, GitStats, PatternFinding, ScanMeta
from weave_quality.prose_rules import (
    PROSE_LANGUAGES,
    PatternRuleExecutionError,
    PatternRuleValidationError,
    # Private by name, deliberate by use: `patterns show` exists to stop
    # consumers re-deriving the engine's matcher construction from the rule
    # YAML, so it has to report what the engine actually builds rather than a
    # second implementation that can drift from it.
    _repo_relative_posix,
    _string_list,
    _word_regex,
    load_prose_rule,
    CODE_LANGUAGE_SUFFIXES,
    code_rule_out_of_scope,
    prose_rule_out_of_scope,
    run_prose_rule,
    validate_pattern_rule,
)
from weave_quality.prose_shape import markdown_files, profile_texts
from weave_quality.python_parser import analyze_python_file

# Re-exported deliberately: rule loading now lives in pattern_loader so the
# evidence adapter can reach it without importing this module, but the names
# stay bound here because this module's own call sites -- and the tests that
# patch them -- resolve them through this namespace.
from weave_quality.pattern_loader import (
    _DEFAULT_PATTERNS_DIR,
    _disabled_patterns,
    _load_pattern_rules,
)

log = logging.getLogger(__name__)

__all__ = ["cmd_findings_promote"]

_VERSION_FILE = Path(__file__).parent.parent / "lib" / "VERSION"


def _scanner_identity() -> str:
    """The release version plus a digest of this package's own sources.

    Cached results and incremental scans are keyed on it, so a change to any
    analyzer invalidates them, not only a release bump: keyed on VERSION alone,
    a bash-parser fix kept serving results the old parser produced (wv-70c888).
    """
    digest = hashlib.sha256()
    for source in sorted(Path(__file__).parent.glob("*.py")):
        digest.update(source.name.encode())
        digest.update(source.read_bytes())
    version = _VERSION_FILE.read_text().strip() if _VERSION_FILE.exists() else ""
    return f"{version}+{digest.hexdigest()[:12]}"


_SCANNER_VERSION = _scanner_identity()
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


def _load_config_exempt(repo: str, section_name: str = "[pattern_exempt]") -> list[str]:
    """Path patterns of one quality.conf section, from .weave/quality.conf then
    quality.local.conf.

    The pattern scan reads [pattern_exempt]. It used to read [exempt]
    (wv-5278fe), but [exempt] holds complexity debt for the close gate, so a
    file exempted for its CC hid every pattern finding too: the rename-blind
    defect in wv-cmd-ops.sh was invisible to the scanner (wv-b60cd5). The two
    are separate keys now. Layering and matching are the close gate's
    (_parse_quality_conf_file in wv-cmd-data.sh): a pattern ending in / is a
    directory prefix, anything else one exact repo-relative path. The name uses
    an underscore because that parser only recognises [a-z_]+ section headers.
    """
    patterns: list[str] = []
    for name in ("quality.conf", "quality.local.conf"):
        conf = Path(repo) / ".weave" / name
        if not conf.is_file():
            continue
        section = ""
        for raw_line in conf.read_text().splitlines():
            line = raw_line.strip()
            if line.startswith("["):
                section = line.lower()
                continue
            if section != section_name:
                continue
            pattern = line.split("#", 1)[0].replace(" ", "")
            if pattern and pattern not in patterns:
                patterns.append(pattern)
    return patterns


def _is_exempt(rel_path: str, patterns: list[str]) -> bool:
    return any(
        rel_path.startswith(p) if p.endswith("/") else rel_path == p for p in patterns
    )


def _finding_repo_path(finding_path: str, target: Path, repo: Path) -> str:
    """A finding's path is relative to the scan target; exemptions are relative
    to the repository."""
    base = Path(os.path.abspath(str(target)))
    full = base / finding_path if base.is_dir() else base
    return os.path.relpath(str(full), os.path.abspath(str(repo))).replace(os.sep, "/")


def _resolve_repo(path: str | None) -> str:
    """Resolve the target repository root.

    Uses the given path, or WV_REPO_ROOT_OVERRIDE env, or REPO_ROOT env, or
    git rev-parse. Critical: when run from a consumer repository, scanner
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
            # -z: unquoted names; the default C-quotes non-ASCII paths (wv-99c85a).
            ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
            capture_output=True,
            text=True,
            check=True,
            cwd=repo,
        )
        candidates = [p for p in result.stdout.split("\0") if p]
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


def _worktree_drift(
    conn: sqlite3.Connection, repo: str, paths: list[str] | None = None
) -> dict[str, list[str]]:
    """Files whose content differs from what the latest scan read (wv-fe9a6a).

    Candidates come from `_discover_files` so freshness judges exactly the set
    a scan would read: a gitignored or [exclude]d path is never "unscanned".
    With `paths`, only those are judged, which is what the wv done gate asks.
    """
    discovered = _discover_files(repo, exclude_globs=_load_config_excludes(repo))
    scanned = latest_scan_paths(conn)
    if paths is not None:
        wanted = set(paths)
        discovered = [p for p in discovered if p in wanted]
        scanned = [p for p in scanned if p in wanted]
    blob_map = working_tree_blob_shas(repo, include=discovered)
    return worktree_drift(conn, repo, discovered, blob_map, scanned)


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
    prev_scan: ScanMeta,
    files_unchanged: list[str],
    classify_overrides: dict[str, list[str]] | None,
) -> list[FileEntry]:
    """Carry FileEntry and file_metrics rows forward from prev_scan for unchanged files."""
    prev_entries = get_file_entries(conn, prev_scan.id)
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
                (prev_scan.id, rel_path),
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
    baseline_note: str = "",
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
    if baseline_note:
        print(f"  {baseline_note}", file=sys.stderr)


def score_baseline_note(repo: str | Path, score: int) -> str:
    """One line placing a score against the [baseline] in quality.conf.

    Empty when no baseline is recorded, so a repository that never accepted a
    score is not told it has one (wv-0f2438).
    """
    baseline = load_score_baseline(str(repo))
    if baseline is None:
        return ""
    base_score, ruling, reason = baseline
    ruling_part = f" ({ruling})" if ruling else ""
    reason_part = f": {reason}" if reason else ""
    if score == base_score:
        return (f"Note: {score}/100 is the accepted baseline{ruling_part}{reason_part}. "
                "Not a regression; it moves when thresholds are recalibrated.")
    direction = "above" if score > base_score else "below"
    return f"Note: {direction} the accepted baseline of {base_score}/100{ruling_part}."


# ---------------------------------------------------------------------------
# Scan command
# ---------------------------------------------------------------------------


def _scan_paths(args: argparse.Namespace) -> tuple[str, Path]:
    """Separate the scan target from the repository owning the selected DB."""
    selected_repo = getattr(args, "repo", None)
    raw_target = args.path or selected_repo or _resolve_repo(None)
    if not raw_target:
        raise ValueError("no repository selected; run wv from the target repository")
    target = Path(raw_target).resolve()
    if not target.is_file() and not target.is_dir():
        raise ValueError(f"scan target does not exist: {target}")
    if selected_repo:
        repo = Path(selected_repo).resolve()
    else:
        directory = target.parent if target.is_file() else target
        try:
            result = subprocess.run(
                ["git", "rev-parse", "--show-toplevel"], cwd=directory,
                capture_output=True, text=True, check=True,
            )
            repo = Path(result.stdout.strip()).resolve()
        except (OSError, subprocess.CalledProcessError):
            repo = directory
    if not target.is_relative_to(repo):
        raise ValueError(
            f"scan target {target} is outside selected repository {repo}; "
            "run wv from the target repository to select its database"
        )
    return str(repo), target


def _partition_scan_files(
    conn: sqlite3.Connection, repo: str, all_files: list[str],
    selected: set[str], blob_map: dict[str, str],
) -> tuple[list[str], list[str]]:
    """Choose files to analyze or carry forward, refreshing all on version drift."""
    prev_for_version = previous_scan(conn)
    previous_paths = (
        {e.path for e in get_file_entries(conn, prev_for_version.id)}
        if prev_for_version is not None else set()
    )
    version_changed = (
        prev_for_version is not None
        and _SCANNER_VERSION
        and prev_for_version.scanner_version != _SCANNER_VERSION
    )
    if version_changed and prev_for_version is not None:
        log.info(
            "Scanner version changed (%s → %s); forcing full re-scan",
            prev_for_version.scanner_version or "unknown",
            _SCANNER_VERSION,
        )

    files_to_scan: list[str] = []
    files_unchanged: list[str] = []
    for rel_path in all_files:
        if rel_path not in selected and not version_changed:
            files_unchanged.append(rel_path)
            continue
        abs_path = os.path.join(repo, rel_path)
        try:
            mtime = int(os.path.getmtime(abs_path))
        except OSError:
            mtime = 0
        if (version_changed or rel_path not in previous_paths
                or file_changed(conn, rel_path, mtime, blob_map.get(rel_path, ""))):
            files_to_scan.append(rel_path)
        else:
            files_unchanged.append(rel_path)
    return files_to_scan, files_unchanged


def cmd_scan(args: argparse.Namespace) -> int:
    """Execute wv quality scan."""
    try:
        repo, target = _scan_paths(args)
    except (OSError, ValueError) as error:
        if args.json:
            print(json.dumps({"error": "invalid_scan_target", "detail": str(error)}))
        else:
            print(f"quality scan: {error}", file=sys.stderr)
        return 1
    conn = init_db(args.hot_zone)
    start_time = time.monotonic()

    cli_excludes: list[str] = getattr(args, "exclude", [])
    all_files = _discover_files(repo, exclude_globs=_load_config_excludes(repo) + cli_excludes)
    selected = {p for p in all_files if (Path(repo) / p).is_relative_to(target)}

    head = git_head_sha(repo)
    scan_id = begin_scan(conn, head, scanner_version=_SCANNER_VERSION)

    # Working-tree SHAs, not HEAD's: an uncommitted edit has to be visible
    # to both file_changed and the AST cache (wv-7fbfe1).
    # Untracked files are hashed too, or they fall back to mtime (wv-fe9a6a).
    blob_map = working_tree_blob_shas(repo, include=all_files)
    files_to_scan, files_unchanged = _partition_scan_files(
        conn, repo, all_files, selected, blob_map,
    )

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
    # A scoped refresh retains prior out-of-scope rows, not unscanned files.
    finish_scan(conn, scan_id, len(entries), duration_ms,
                bash_cc_backend=bash_backend, ts_cc_backend=ts_backend)
    conn.commit()
    conn.close()

    summary = hotspot_summary(entries, git_stats, all_fn_cc)
    score = summary.get("quality_score", 100)
    baseline_note = score_baseline_note(repo, score) if isinstance(score, int) else ""

    if args.json:
        category_counts = dict(Counter(e.category for e in entries))
        print(json.dumps({
            "scan_id": scan_id,
            "git_head": head,
            "target": target.relative_to(repo).as_posix(),
            "files_scanned": len(selected),
            "files_total": len(entries),
            "files_changed": len(files_to_scan),
            "languages": lang_counts,
            "category_counts": category_counts,
            "duration_ms": duration_ms,
            "hotspots_above_threshold": summary.get("hotspot_count", 0),
            "quality_score": score,
            "baseline_note": baseline_note,
            "bash_cc_backend": bash_backend,
            "ts_cc_backend": ts_backend,
        }))
    else:
        print(f"Scanning {target} (repository {repo})...", file=sys.stderr)
        _print_scan_result(lang_counts, files_to_scan, duration_ms, summary,
                           bash_cc_backend=bash_backend, ts_cc_backend=ts_backend,
                           baseline_note=baseline_note)

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


def cmd_freshness(args: argparse.Namespace) -> int:
    """Execute wv quality freshness -- did the latest scan read these files?

    Prints {"stale", "changed", "unscanned", "deleted"} as JSON. Judges content
    only, not HEAD: a commit that changes no scanned byte leaves every metric
    true. Exit 0 whether fresh or stale; nonzero only when it cannot answer.
    """
    if not db_exists(args.hot_zone):
        print(_MSG_NO_DB, file=sys.stderr)
        return 1
    conn = init_db(args.hot_zone)
    try:
        if latest_scan(conn) is None:
            print(_MSG_NO_SCAN, file=sys.stderr)
            return 1
        repo = _resolve_repo(args.repo)
        drift = _worktree_drift(conn, repo, list(args.paths) if args.paths else None)
    finally:
        conn.close()
    print(json.dumps({"stale": any(drift.values()), **drift}))
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

    # Staleness warning. Drift is only worth computing for a scan at HEAD: one
    # behind HEAD is already stale (wv-fe9a6a).
    scan_now = latest_scan(conn)
    drift = None
    if scan_now is not None and not scan_now.is_stale(current_head):
        drift = _worktree_drift(conn, _resolve_repo(None))
    stale = staleness_info(conn, current_head, drift)

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
        elif stale.get("stale") and stale.get("reason") == "worktree_changed":
            n = sum(len(stale.get(k, [])) for k in ("changed", "unscanned", "deleted"))
            print(
                f"[WARN] {n} file(s) changed since the scan "
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


def _delta_of(item: dict[str, object]) -> float:
    """Sort key for a categorized change: its rounded complexity delta."""
    delta = item["delta"]
    if not isinstance(delta, (int, float)):
        raise TypeError(f"change item delta is {type(delta).__name__}, not a number")
    return float(delta)


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

    improved.sort(key=_delta_of)
    degraded.sort(key=_delta_of, reverse=True)
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


def _cmd_promote_patterns_canonical(args: argparse.Namespace) -> int:
    """Canonical mode: reviewed accepted evidence -> canonical type=finding nodes.

    Defaults to dry-run. Apply consumes the exact reviewed plan BYTES rather than
    recomputing a plan: a plan recomputed at apply time can differ from the one a
    human reviewed, and then the review approved something else.
    """
    # Lazy: coaching_evidence imports back from this module, so a top-level
    # import here would close the cycle at import time.
    from .coaching_apply import ApplyError, apply_plan, default_runner  # noqa: PLC0415  # pylint: disable=import-outside-toplevel
    from .coaching_evidence import EvidenceError, build_promotion_input  # noqa: PLC0415  # pylint: disable=import-outside-toplevel

    if args.apply and args.dry_run:
        print("Error: --apply and --dry-run are mutually exclusive.", file=sys.stderr)
        return 2

    repo = Path(_resolve_repo(None))

    if args.apply:
        if not args.plan_file:
            print("Error: --apply requires --plan-file=<reviewed plan>.", file=sys.stderr)
            return 2
        try:
            plan_bytes = Path(args.plan_file).read_bytes()
        except OSError as exc:
            print(f"Error: cannot read {args.plan_file}: {exc}", file=sys.stderr)
            return 1
        # review_parent comes from the plan. An acquisition argument that
        # disagrees is a conflict, not an override: apply must act on the scope
        # that was actually reviewed.
        try:
            planned_parent = json.loads(plan_bytes)["scope"]["review_parent"]
        except (json.JSONDecodeError, KeyError, TypeError) as exc:
            print(f"Error: {args.plan_file} is not a promotion plan ({exc}).", file=sys.stderr)
            return 1
        if args.parent and args.parent != planned_parent:
            print(
                f"Error: --parent={args.parent} conflicts with the reviewed plan's "
                f"review_parent {planned_parent}.",
                file=sys.stderr,
            )
            return 2
        try:
            result = apply_plan(
                plan_bytes, run=default_runner, metadata_writer=_write_metadata_patch
            )
        except ApplyError as exc:
            payload = {"error": exc.code, "detail": str(exc)}
            print(json.dumps(payload) if args.json else f"Error: {exc}", file=sys.stderr)
            return 1
        print(json.dumps(result) if args.json else _format_apply(result))
        return 0

    catalog = _load_catalog(repo)
    if catalog is None:
        return 1

    scope = {"target": ".", "review_parent": args.parent}
    try:
        document = build_promotion_input(
            repo, catalog, scope, hot_zone=args.hot_zone, language=args.language or None
        )
    except EvidenceError as exc:
        payload = {"error": exc.code, "detail": str(exc)}
        print(json.dumps(payload) if args.json else f"Error: {exc}", file=sys.stderr)
        return 1

    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from weave_coaching import plan_promotions  # noqa: PLC0415  # pylint: disable=import-outside-toplevel

    plan = plan_promotions(document)
    if args.json:
        print(json.dumps(plan, indent=2))
    else:
        print(_format_plan(plan))
    # An incomplete snapshot is a non-success exit even though the response is
    # well formed: the caller must not read "no candidates" as "nothing to fix".
    return 0 if plan["snapshot"]["state"] == "complete" else 1


def cmd_coaching_render(args: argparse.Namespace) -> int:
    """Render coaching for finding nodes — the one renderer every surface shares.

    `wv findings list --detail`, the `ready` digest, and context/discovery all
    call this rather than formatting finding metadata themselves. Three surfaces
    growing three dialects of the same coaching is the fragmentation this slice
    exists to remove, so the projection is bounded here and embedded there.
    """
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from weave_coaching import view  # noqa: PLC0415  # pylint: disable=import-outside-toplevel

    from .guides import GuideError, resolve  # noqa: PLC0415  # pylint: disable=import-outside-toplevel

    code, out = _wv_cmd("findings", "list", "--all", "--json")
    if code != 0:
        print(f"Error: could not read findings: {out}", file=sys.stderr)
        return 1
    try:
        nodes = json.loads(out) if out else []
    except json.JSONDecodeError as exc:
        print(f"Error: findings list returned malformed JSON: {exc}", file=sys.stderr)
        return 1

    wanted = {n.strip() for n in args.node_ids.split(",") if n.strip()} if args.node_ids else None

    repo = Path(_resolve_repo(None))
    catalog = _load_catalog(repo)
    if catalog is None:
        return 1

    findings: list[dict[str, Any]] = []
    guides: dict[str, dict[str, Any]] = {}
    for node in nodes:
        metadata = _load_node_metadata_local(node)
        finding = metadata.get("finding") or {}
        violation_type = finding.get("violation_type")
        occurrences = (finding.get("quality") or {}).get("occurrences")
        if not violation_type or not occurrences:
            # A finding with no promoted occurrence set has nothing to coach
            # over. It stays in `findings list`; it is simply not a coaching block.
            continue
        if wanted is not None and str(node.get("id")) not in wanted:
            continue
        # One guide per type AND language: keyed by type alone, the last
        # finding resolved set the guide for every finding of that type, so a
        # language variant reached none or all of them (wv-60bf88).
        language = finding.get("guide", {}).get("language")
        guide_key = f"{violation_type}.{language}" if language else violation_type
        if guide_key not in guides:
            try:
                guides[guide_key] = resolve(violation_type, catalog, language, project_root=repo).content()
            except GuideError as exc:
                print(f"Error: {exc}", file=sys.stderr)
                return 1
        findings.append({
            "guide_key": guide_key,
            "violation_type": violation_type,
            "node_id": str(node.get("id")),
            "occurrences": occurrences,
            "policy": finding.get("policy"),
            "confidence": finding.get("confidence"),
        })

    limit = None if args.limit <= 0 else args.limit
    response = view.render_response(findings, guides, {"state": "complete"}, limit=limit)
    # Embedded in another surface, an empty projection must say nothing. Its
    # clean message is true of quality coaching and reads as a contradiction
    # when it lands directly under a list of findings that surface just printed.
    if args.embed and not response["blocks"]:
        return 0
    if args.json:
        print(json.dumps(response, indent=2))
    else:
        print(view.render_text(response), end="")
    return 0


def _load_node_metadata_local(node: dict[str, Any]) -> dict[str, Any]:
    metadata = node.get("metadata")
    if isinstance(metadata, str) and metadata:
        try:
            metadata = json.loads(metadata)
        except json.JSONDecodeError:
            return {}
    return metadata if isinstance(metadata, dict) else {}


def _load_catalog(repo: Path) -> dict[str, Any] | None:
    """The violation vocabulary with the repository's own project: types merged
    in (wv-60bf88), or None after printing why it cannot be read."""
    from .guides import GuideError, with_project_types  # noqa: PLC0415  # pylint: disable=import-outside-toplevel

    catalog_path = _contracts_dir() / "violation-vocabulary-v1.json"
    try:
        return with_project_types(json.loads(catalog_path.read_text(encoding="utf-8")), repo)
    except OSError as exc:
        print(f"Error: cannot read {catalog_path}: {exc}", file=sys.stderr)
    except GuideError as exc:
        print(f"Error: {exc}", file=sys.stderr)
    return None


def _contracts_dir() -> Path:
    """Where the machine-readable contracts live, source or installed.

    Installed mode resolves them beside the package under $LIB_DIR/contracts;
    a source checkout resolves them from the repository root.
    """
    installed = Path(__file__).resolve().parents[1] / "contracts"
    if (installed / "violation-vocabulary-v1.json").is_file():
        return installed
    return Path(__file__).resolve().parents[2] / "contracts"


def _write_metadata_patch(patch: dict[str, Any]) -> str:
    """Persist a metadata patch for `wv update --metadata-file`."""
    handle = tempfile.NamedTemporaryFile(
        "w", suffix=".json", delete=False, encoding="utf-8"
    )
    with handle:
        json.dump(patch, handle)
    return handle.name


def _format_plan(plan: dict[str, Any]) -> str:
    lines = [f"Promotion plan ({plan['snapshot']['state']})"]
    for cause in plan["snapshot"].get("causes", []):
        lines.append(f"  [{cause['reason']}] {cause.get('rule_id', '')} {cause.get('detail', '')}")
    for candidate in plan["candidates"]:
        count = len(candidate["occurrences"])
        lines.append(
            f"  {candidate['promotion_id'][:12]}...  {candidate['violation_type']} "
            f"({count} occurrence{'s' if count != 1 else ''})"
        )
    for rejected in plan.get("rejected", []):
        lines.append(f"  rejected [{rejected['reason']}] {rejected.get('rule_id', '')}")
    if not plan["candidates"]:
        lines.append("  no candidates")
    return "\n".join(lines)


def _format_apply(result: dict[str, Any]) -> str:
    lines = [f"Applied plan {result['reviewed_plan_sha256'][:12]}..."]
    for entry in result["applied"]:
        lines.append(f"  {entry['action']:9} {entry['node_id']}  {entry['promotion_id'][:12]}...")
    return "\n".join(lines)


def _cmd_promote_patterns(args: argparse.Namespace) -> int:
    """Promote pattern findings grouped by rule_id to Weave nodes."""
    if getattr(args, "canonical", False):
        return _cmd_promote_patterns_canonical(args)
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
    repo = _resolve_repo(None)
    freshness = staleness_info(conn, git_head_sha(repo), _worktree_drift(conn, repo))
    conn.close()

    score = compute_quality_score(entries, all_stats, all_fn_cc)
    hotspot_count = count_hotspots(entries, all_stats)

    print(
        json.dumps(
            {
                "available": True,
                "score": score,
                "baseline_note": score_baseline_note(repo, score),
                "hotspot_count": hotspot_count,
                "total_files": len(entries),
                "git_head": scan.git_head,
                "scanned_at": scan.scanned_at,
                "stale": freshness["stale"],
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




def _rule_source(rule_path: Path) -> str:
    """Where a rule's definition came from: default, managed, or custom.

    Single derivation shared by `patterns list` and `patterns scan` so the two
    cannot drift. Provenance is the context needed to judge a hit -- a shared
    core default carries a general lesson, a project-local rule is house style
    -- and scan is the command run in the edit-fix loop, so it has to carry the
    tag too rather than making the operator run list separately to get it.
    """
    if rule_path.parent == _DEFAULT_PATTERNS_DIR:
        return "default"
    if rule_path.parent.name == "managed":
        return "managed"
    return "custom"


def _shadowed_managed_pattern_ids(repo: Path) -> list[str]:
    """Return rule ids a project-local rule is currently shadowing.

    Prefer the installed managed inventory so a newly promoted rule is visible
    before the repository projection is refreshed. Fall back to reconcile's
    .overridden marker when installed assets are unavailable.
    """
    installed = _installed_managed_pattern_names()
    if installed:
        patterns_dir = repo / ".weave" / "patterns"
        return sorted(
            name.removesuffix(".yaml")
            for name in installed
            if (patterns_dir / name).is_file()
        )

    overridden_file = repo / ".weave" / "patterns" / "managed" / ".overridden"
    if not overridden_file.is_file():
        return []
    ids = []
    for line in overridden_file.read_text(encoding="utf-8").splitlines():
        name = line.strip()
        if name.endswith(".yaml"):
            ids.append(name[: -len(".yaml")])
    return ids


def _installed_managed_pattern_dir() -> Path:
    config_root = Path(os.environ.get("WV_CONFIG_DIR", Path.home() / ".config" / "weave"))
    return config_root / "quality-patterns" / "managed"


def _managed_pattern_manifest_names(path: Path) -> set[str]:
    if not path.is_file():
        return set()
    return {
        name
        for raw in path.read_text(encoding="utf-8").splitlines()
        if (name := raw.strip()).endswith(".yaml") and "/" not in name and ".." not in name
    }


def _installed_managed_pattern_names() -> set[str]:
    return _managed_pattern_manifest_names(_installed_managed_pattern_dir() / "manifest.txt")


def _stale_managed_pattern_ids(repo: Path) -> list[str]:
    """Return installed managed ids whose existing repo projection is stale."""
    managed_dir = repo / ".weave" / "patterns" / "managed"
    if not managed_dir.is_dir():
        return []
    installed_dir = _installed_managed_pattern_dir()
    installed = _installed_managed_pattern_names()
    if not installed:
        return []
    projected = _managed_pattern_manifest_names(managed_dir / ".manifest")
    overridden = _managed_pattern_manifest_names(managed_dir / ".overridden")
    stale = (projected | overridden) - installed
    for name in installed:
        if (repo / ".weave" / "patterns" / name).is_file():
            continue
        projected_rule = managed_dir / name
        installed_rule = installed_dir / name
        if (
            name not in projected
            or not projected_rule.is_file()
            or not installed_rule.is_file()
            or projected_rule.read_bytes() != installed_rule.read_bytes()
        ):
            stale.add(name)
    return sorted(name.removesuffix(".yaml") for name in stale)


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
    """Return the stable content hash used to bind execution receipts.

    Binds WORKING-TREE bytes as scan-receipt provenance. Promotion may use this
    digest for validation only after `coaching_evidence.rule_definition_bindings`
    proves the same bytes match target HEAD or the shipped package manifest.
    See docs/EVIDENCE-HASH-BINDING-CONTRACT.md; do not let direct
    receipt/worktree equality become a validation authority again.
    """
    return hashlib.sha256(rule_path.read_bytes()).hexdigest()


def _normalise_finding_identity_text(value: str) -> str:
    """Normalize prose/code fragments without depending on source line layout."""
    return " ".join(unicodedata.normalize("NFKC", value).split())


# Words kept on each side of a match in its identity anchor (wv-0f8658).
_ANCHOR_WORDS = 3


class _SourceWords:  # pylint: disable=too-few-public-methods
    """One source file's lines and words, with the paragraph each word is in."""

    def __init__(self, text: str) -> None:
        self.lines = text.splitlines()
        breaks = [m.start() for m in re.finditer(r"\n[ \t]*\n", text)]
        self.words = [(m.start(), m.end(), m.group(), bisect.bisect_right(breaks, m.start()))
                      for m in re.finditer(r"\S+", text)]
        self.word_starts = [word[0] for word in self.words]
        self.line_starts = [0]
        for line in text.splitlines(keepends=True):
            self.line_starts.append(self.line_starts[-1] + len(line))

    def anchor(self, line: int, col: int, match: str) -> str:
        """The words just before and just after a match at LINE:COL, within its paragraph.

        Whitespace-insensitive, so reflowing keeps it; bounded by blank
        lines, so moving or editing other paragraphs does not change it.
        """
        if not 0 < line < len(self.line_starts):
            return ""
        line_len = len(self.lines[line - 1]) if line <= len(self.lines) else 0
        offset = self.line_starts[line - 1] + min(max(col, 0), line_len)
        first = bisect.bisect_right(self.word_starts, offset) - 1
        if first < 0 or offset >= self.words[first][1]:
            first += 1
        if first >= len(self.words):
            return ""
        paragraph = self.words[first][3]
        after = first + max(1, len(match.split()))
        before = [w[2] for w in self.words[max(0, first - _ANCHOR_WORDS):first] if w[3] == paragraph]
        following = [w[2] for w in self.words[after:after + _ANCHOR_WORDS] if w[3] == paragraph]
        return (_normalise_finding_identity_text(" ".join(before)) + "\x1f"
                + _normalise_finding_identity_text(" ".join(following)))


def _finding_label(source: Path, repo: Path) -> str:
    """The path a finding is keyed and reported under."""
    # os.path.abspath, not Path.resolve() -- resolve() follows symlinks,
    # which would key a symlinked file's finding identity/report path on
    # its target's location rather than the name it was actually scanned
    # under, and could fold a real file and a symlink to it into a
    # collision (or split one file's own identity across two labels).
    try:
        return Path(os.path.abspath(str(source))).relative_to(Path(os.path.abspath(str(repo)))).as_posix()
    except ValueError:
        # Outside repo (a test fixture, or any --path pointed elsewhere):
        # the target-relative label alone (e.g. "a.md") isn't a stable
        # identity -- two distinct files under different external
        # targets can share it, colliding their finding_key and
        # adjudication history. Use the lexical absolute source path
        # instead; _report_scope scopes reports against this same form.
        return Path(os.path.abspath(str(source))).as_posix()


def _attach_pattern_finding_identities(
    findings: list[PatternFinding], target: Path, repo: Path
) -> None:
    """Bind findings to rule, path, normalized match and, when needed, anchor.

    A match whose text is unique in its file keeps the identity it always
    had (rule, path, match, ordinal 1), so edits around it and reflow leave
    its key alone. Several matches of the same text used to be told apart by
    ordinal alone, so repairing one renumbered every later one and each took
    its neighbour's verdict (wv-0f8658); they now carry their anchor (the
    words around the match) and an ordinal among matches sharing it.

    When a group grows or shrinks a finding's key changes form, and
    replace_pattern_scan_results carries its verdict across by content.
    Identity stays a function of the file alone, so a committed
    adjudication resolves the same on every clone.

    A source-read failure (deleted mid-scan, permission denied, ...) is
    NOT swallowed here -- it propagates to the caller (cmd_patterns_scan),
    which runs this inside the same per-rule PatternRuleExecutionError
    boundary as rule execution itself, so it becomes a recorded failed
    receipt. Silently falling back to an empty source previously let a
    finding whose context could never actually be read still get recorded
    as a successful, correctly-identified finding.
    """
    source_cache: dict[str, _SourceWords] = {}
    placed: list[tuple[PatternFinding, tuple[str, str, str], str]] = []
    group_sizes: dict[tuple[str, str, str], int] = {}
    for finding in findings:
        source = target / finding.path if target.is_dir() else target
        cache_key = str(source)
        if cache_key not in source_cache:
            source_cache[cache_key] = _SourceWords(source.read_text(encoding="utf-8", errors="replace"))
        words = source_cache[cache_key]
        lines = words.lines
        context = lines[finding.line - 1] if 0 < finding.line <= len(lines) else finding.match_text
        finding.path = _finding_label(source, repo)
        normalized_match = _normalise_finding_identity_text(finding.match_text)
        finding.context_text = _normalise_finding_identity_text(context)
        group = (finding.rule_id, finding.path, normalized_match)
        group_sizes[group] = group_sizes.get(group, 0) + 1
        placed.append((finding, group, words.anchor(finding.line, finding.col, normalized_match)))
    ordinals: dict[tuple[str, ...], int] = {}
    for finding, group, anchor in placed:
        if group_sizes[group] == 1:
            finding.finding_key = unique_finding_key_for(*group)
            continue
        anchored = (*group, anchor)
        ordinals[anchored] = ordinals.get(anchored, 0) + 1
        finding.finding_key = finding_key_for(*anchored, ordinals[anchored])


def _pattern_execution_error(exc: PatternRuleExecutionError, json_out: bool) -> int:
    """Report a rule execution failure without replacing prior findings."""
    if json_out:
        print(json.dumps({"error": "pattern_rule_execution_failed", "detail": str(exc)}))
    else:
        print(f"patterns: rule execution failed: {exc}", file=sys.stderr)
    return 1


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


# Dot-directories that hold code a pattern rule must see. ast-grep skips every
# hidden directory while walking a target, so each one is passed by name.
_SCANNED_DOT_DIRS = (".claude",)


def _ast_grep_files(target: Path) -> list[Path]:
    """The files ast-grep walks under directory TARGET, by its own rules.

    It honours .gitignore inside a repository, so there the set is git's
    (tracked plus untracked, not ignored): walking the tree instead stat'd
    every file under .venv once per rule, 8 s a rule on this repository.
    Outside a repository it is every file. Hidden entries are dropped
    except the dot-directories passed by name. The listing is repo_files,
    which prose rules share (wv-c309a8).
    """
    relative = repo_files(target)
    return [
        target / rel for rel in relative
        if not any(part.startswith(".") and part not in _SCANNED_DOT_DIRS for part in rel.parts)
    ]


def _unreadable_code_files(target: Path, language: str) -> list[Path]:
    """Files of LANGUAGE that ast-grep would scan under TARGET and cannot read.

    ast-grep skips an unreadable file without a message (wv-0da129). Empty,
    binary and oversized files, which it also skips, are readable and not
    reported. A language with no suffix map reports nothing: what it would
    scan is not known here.
    """
    suffixes = CODE_LANGUAGE_SUFFIXES.get(language)
    if suffixes is None:
        return []
    candidates = [target] if target.is_file() else _ast_grep_files(target)
    return sorted(
        path for path in candidates
        if path.suffix.lower() in suffixes and path.is_file() and not os.access(path, os.R_OK)
    )


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
    cmd = [ast_grep, "scan", "--rule", str(rule_path), "--json", "--inspect", "summary", str(target)]
    # ast-grep skips dot-directories when it walks a directory, so no bash rule
    # ever reached .claude/hooks/*.sh (wv-b60cd5). Naming the directory makes
    # ast-grep scan it; hidden trees in general (.git, .venv) stay unscanned.
    for dot_dir in _SCANNED_DOT_DIRS:
        if target.is_dir() and (target / dot_dir).is_dir():
            cmd.append(str(target / dot_dir))
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=60, check=False)
    except subprocess.TimeoutExpired as exc:
        raise PatternRuleExecutionError(
            f"{rule_path}: ast-grep timed out scanning {target}"
        ) from exc
    if proc.returncode not in (0, 1):
        detail = proc.stderr.strip()[:500] or f"exit {proc.returncode}"
        raise PatternRuleExecutionError(f"{rule_path}: ast-grep failed on {target}: {detail}")
    # A directory ast-grep cannot list is reported on stderr ("ERROR: <dir>:
    # Permission denied") while it exits 0 with whatever it did reach: a
    # partial scan that read as complete (wv-4852bd). Parse errors and binary
    # files print nothing there.
    unlisted = [line for line in proc.stderr.splitlines() if line.startswith("ERROR:")]
    if unlisted:
        raise PatternRuleExecutionError(
            f"{rule_path}: ast-grep could not read all of {target}: {unlisted[0][:300]}"
        )
    # An unreadable FILE is skipped with no message and exit 0, and the
    # summary's skippedFileCount also counts empty, binary and oversized files,
    # so a skip is only a hint (wv-0da129). Only then are the language's files
    # under the target checked, and the scan refused if one cannot be read.
    skipped = re.search(r"skippedFileCount=(\d+)", proc.stderr)
    if skipped and int(skipped.group(1)) > 0:
        unreadable = _unreadable_code_files(target, language)
        if unreadable:
            raise PatternRuleExecutionError(
                f"{rule_path}: ast-grep skipped {len(unreadable)} file(s) under {target} it could not "
                f"read, so the scan is incomplete: {unreadable[0]}"
            )
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
    # ast-grep scans files in parallel and reports them in completion order,
    # which varied run to run (3 of 60 on a two-file fixture), so a scan's
    # output did too. Report in path, line, column order (wv-d94b8a).
    findings.sort(key=lambda f: (f.path, f.line, f.col))
    return findings


class _ScanAborted(Exception):
    """A rule failed; its receipt is already recorded and the scan must stop."""

    def __init__(self, error: PatternRuleExecutionError) -> None:
        super().__init__(str(error))
        self.error = error


def _execute_pattern_rules(
    conn: sqlite3.Connection,
    rules: list[tuple[str, Path, str]],
    target: Path,
    run_id: int,
    repo: Path,
    canonical_target: str,
) -> tuple[list[PatternFinding], list[dict[str, object]]]:
    """Run every rule, writing a per-rule receipt as each one completes.

    Receipts are written immediately rather than only in the batched
    replace_pattern_scan_results call, so a completed rule's result survives a
    LATER rule's failure -- otherwise it reports "not_run", indistinguishable
    from never having executed. On failure the receipt is recorded and
    _ScanAborted is raised so the caller can close the connection and render
    the error.
    """
    all_findings: list[PatternFinding] = []
    successful_runs: list[dict[str, object]] = []
    exempt = _load_config_exempt(str(repo))
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
            if exempt:
                found = [
                    f for f in found
                    if not _is_exempt(_finding_repo_path(f.path, target, repo), exempt)
                ]
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
            raise _ScanAborted(exc) from exc
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
            raise _ScanAborted(wrapped) from exc
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
    return all_findings, successful_runs


def _suppress_same_span_findings(
    all_findings: list[PatternFinding],
    rules: list[tuple[str, Path, str]],
) -> list[PatternFinding]:
    """Collapse findings from different rules at the identical (path, line, col).

    Keyed on start position only, not match_text -- two rules flagging the same
    spot capture slightly different surrounding text. Higher maturity wins
    (promotable > observed > candidate); code rules and ties fall back to
    rule_id order for a deterministic pick. Deliberately narrow: spans that
    overlap at DIFFERENT start columns are a fuzzier, unrelated problem and are
    left alone.
    """
    if len(all_findings) <= 1:
        return all_findings
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
    if not any(len(group) > 1 for group in by_span.values()):
        return all_findings
    deduped: list[PatternFinding] = []
    for group in by_span.values():
        group.sort(
            key=lambda f: (
                -maturity_rank.get(rule_maturity.get(f.rule_id, "candidate"), 0),
                f.rule_id,
            )
        )
        deduped.append(group[0])
    return deduped


def cmd_patterns_scan(args: argparse.Namespace) -> int:
    """Run all active pattern rules and store findings."""
    repo = Path(_resolve_repo(None))
    conn = init_db(args.hot_zone)

    conf_disabled = _disabled_patterns(repo / ".weave" / "quality.conf")
    # Rules skipped for breaking the contract (wv-d0e4d6). Every report names
    # them, so a scan never reads as covering a rule it did not apply.
    invalid: list[tuple[str, Path, str]] = []
    try:
        rules = _load_pattern_rules(repo, conf_disabled, invalid)
    except PatternRuleValidationError as exc:
        conn.close()
        return _pattern_rule_error(exc, args.json)
    invalid_rules = _invalid_rule_entries(invalid)
    rules = _runnable_rules(rules)

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

    # Restore only an empty cache. Warm scans and a prior wv load must retain
    # local decisions that have not yet been exported by wv sync.
    if latest_pattern_run(conn) is None and not pattern_finding_states(conn):
        import_pattern_adjudications(conn, repo / ".weave" / "quality-adjudications.jsonl")

    if not rules:
        # Every invocation gets its own pattern_runs lifecycle row, even a
        # zero-rule one -- otherwise report/list keep presenting an earlier
        # target's scope, and this successful invocation is simply absent
        # from lifecycle history (see wv-40d3d6).
        run_id = begin_pattern_run(conn, git_head_sha(repo), canonical_target)
        finish_pattern_run(conn, run_id, files_count=0, duration_ms=0)
        conn.close()
        return _emit_no_rules_scan(args, invalid_rules)

    # Pattern scans get their own lifecycle id, independent of scan_meta (the
    # complexity-scan sequence) -- a rescan or an unrelated `wv quality scan`
    # must not collide with or prune this invocation's findings.
    run_id = begin_pattern_run(conn, git_head_sha(repo), canonical_target)
    started = time.time()

    try:
        all_findings, successful_runs = _execute_pattern_rules(
            conn, rules, target, run_id, repo, canonical_target
        )
    except _ScanAborted as aborted:
        conn.close()
        return _pattern_execution_error(aborted.error, args.json)

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
    all_findings = _suppress_same_span_findings(all_findings, rules)
    final_hits_by_rule = _reconcile_rule_hits(all_findings, successful_runs)

    replace_pattern_scan_results(conn, run_id, all_findings, successful_runs)
    finish_pattern_run(
        conn,
        run_id,
        files_count=len({finding.path for finding in all_findings}),
        duration_ms=int((time.time() - started) * 1000),
    )
    finding_states = _finding_states_for(conn, all_findings)
    conn.close()

    return _report_pattern_scan(
        args, rules, all_findings, finding_states, final_hits_by_rule, raw_hits_by_rule,
        target, repo, invalid_rules,
    )


def _report_pattern_scan(
    args: argparse.Namespace,
    rules: list[tuple[str, Path, str]],
    all_findings: list[PatternFinding],
    finding_states: dict[str, dict[str, object]],
    final_hits_by_rule: dict[str, int],
    raw_hits_by_rule: dict[str, int],
    target: Path,
    repo: Path,
    invalid_rules: list[dict[str, str]],
) -> int:
    """Build the per-rule counts and sources for a finished scan and render it.

    final_hits_by_rule is what was stored after same-span suppression;
    raw_hits_by_rule is what each rule matched before it.
    """
    summary = {r: final_hits_by_rule.get(r, 0) for r, _, _ in rules}
    # wv-c71833: by_rule (== stored receipt hits == patterns list count for
    # this scan) vs. what each rule itself matched before same-start-location
    # collision suppression -- only present as its own key so by_rule's
    # values keep meaning exactly one thing (the reported/stored count).
    raw_hits = {r: raw_hits_by_rule.get(r, 0) for r, _, _ in rules}
    rule_sources = {r: _rule_source(path) for r, path, _ in rules}
    return _emit_pattern_scan(
        args, rules, all_findings, finding_states, summary, raw_hits, rule_sources,
        _out_of_scope_rules(rules, summary, target, repo), invalid_rules,
    )


def _runnable_rules(rules: list[tuple[str, Path, str]]) -> list[tuple[str, Path, str]]:
    """Drop the code rules when ast-grep is missing, saying so; prose rules always run."""
    code_rules = [rule for rule in rules if rule[2] not in PROSE_LANGUAGES]
    if not code_rules or ast_grep_available():
        return rules
    print(
        f"patterns: skipping {len(code_rules)} code rule(s) "
        "(ast-grep not found; run ./install.sh); prose rules still run",
        file=sys.stderr,
    )
    return [rule for rule in rules if rule[2] in PROSE_LANGUAGES]


def _reconcile_rule_hits(
    all_findings: list[PatternFinding], successful_runs: list[dict[str, object]]
) -> dict[str, int]:
    """Set each run's stored hits to the findings that landed, and return them by rule.

    wv-c71833: the receipt's persisted "hits" must agree with what this
    same invocation reports in by_rule and stores in pattern_findings --
    otherwise `patterns scan`, `patterns list`, and a rule's own receipt
    read as three different counts for the same run. Overwrite each
    successful run's hits from the (possibly deduped) all_findings that
    actually landed in the store; the caller's raw_hits_by_rule (captured
    before dedup) still carries what the rule itself matched for the scan output.
    """
    final_hits_by_rule: dict[str, int] = {}
    for pf in all_findings:
        final_hits_by_rule[pf.rule_id] = final_hits_by_rule.get(pf.rule_id, 0) + 1
    for run in successful_runs:
        run["hits"] = final_hits_by_rule.get(str(run["rule_id"]), 0)
    return final_hits_by_rule


def _finding_states_for(
    conn: sqlite3.Connection, all_findings: list[PatternFinding]
) -> dict[str, dict[str, object]]:
    """The stored adjudication state of each finding this scan produced, by finding_key."""
    return {
        str(row["finding_key"]): row
        for row in pattern_finding_states(
            conn, sorted({finding.finding_key for finding in all_findings})
        )
    }


def _out_of_scope_rules(
    rules: list[tuple[str, Path, str]], summary: dict[str, int], target: Path, repo: Path
) -> list[str]:
    """Rules that found nothing because no file under the target is theirs to read.

    A rule with no eligible file under the target reported zero because it
    never ran, not because the file is clean: a prose rule outside its
    paths: (wv-33733d), a code rule with no file of its language (wv-76fc4a).
    Only computed for rules that found nothing, so a scan with findings pays
    nothing for it.
    """
    return sorted(
        rule_id
        for rule_id, rule_path, language in rules
        if not summary.get(rule_id)
        and (prose_rule_out_of_scope(rule_path, target, repo)
             if language in PROSE_LANGUAGES
             else code_rule_out_of_scope(language, target))
    )


def _invalid_rule_entries(invalid: list[tuple[str, Path, str]]) -> list[dict[str, str]]:
    """The loader's skipped rule files as report entries."""
    return [
        {"rule_id": rule_id, "path": str(rule_path), "error": error}
        for rule_id, rule_path, error in invalid
    ]


def _emit_no_rules_scan(args: argparse.Namespace, invalid_rules: list[dict[str, str]]) -> int:
    """Report a scan that had no rule to run, in the same shape as any other scan."""
    if args.json:
        print(
            json.dumps(
                {
                    "rules": 0,
                    "rules_run": 0,
                    "findings": 0,
                    "by_rule": {},
                    "matches": [],
                    "invalid_rules": invalid_rules,
                }
            )
        )
    else:
        print("No pattern rules found.")
        _print_invalid_rules(invalid_rules)
    return 0


def _print_invalid_rules(invalid_rules: list[dict[str, str]]) -> None:
    """Name each rule a text scan skipped as invalid (wv-d0e4d6)."""
    if not invalid_rules:
        return
    print(f"  {len(invalid_rules)} invalid rule file(s) not applied; fix or remove them:")
    for entry in invalid_rules:
        print(f"    {entry['path']}: {entry['error']}")


def _emit_pattern_scan(
    args: argparse.Namespace,
    rules: list[tuple[str, Path, str]],
    all_findings: list[PatternFinding],
    # One row per finding_key, as pattern_finding_states() returns them: the
    # body reads ["disposition"], ["scan_count"] and .get("disposition_source")
    # off each row, none of which a bare `object` value supports.
    finding_states: dict[str, dict[str, object]],
    summary: dict[str, int],
    raw_hits: dict[str, int],
    rule_sources: dict[str, str],
    out_of_scope: list[str] | None = None,
    invalid_rules: list[dict[str, str]] | None = None,
) -> int:
    """Render one scan's result as JSON or as the per-rule text report."""
    out_of_scope = out_of_scope or []
    invalid_rules = invalid_rules or []
    out_of_scope_set = set(out_of_scope)
    total = len(all_findings)
    matches = [
        {
            "rule_id": finding.rule_id,
            "source": rule_sources.get(finding.rule_id, "custom"),
            "path": finding.path,
            "line": finding.line,
            "col": finding.col + 1,
            "match_text": finding.match_text,
            "severity": finding.severity,
            "finding_key": finding.finding_key,
            "disposition": finding_states[finding.finding_key]["disposition"],
            # "path" when adjudicated at this exact location, "content" when the
            # verdict was inherited from the same finding elsewhere (Finding K).
            "disposition_source": finding_states[finding.finding_key].get(
                "disposition_source", "path"
            ),
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
                    "rule_sources": rule_sources,
                    # Rules whose paths: matched no file under the target. Their
                    # by_rule zero means "never ran", not "found nothing".
                    "out_of_scope": out_of_scope,
                    "matches": matches,
                    # Rule files skipped for breaking the rule contract; they
                    # are not in rules and found nothing because they never ran.
                    "invalid_rules": invalid_rules,
                }
            )
        )
    else:
        # The applied fraction is only claimed when something was skipped.
        # Both kinds of structural zero are counted: a prose rule outside its
        # paths: and a code rule with no file of its language (wv-76fc4a), so
        # "N of M applied" never asserts that a rule ran on files it cannot see.
        if out_of_scope_set:
            applied = len(rules) - len(out_of_scope_set)
            print(
                f"Pattern scan complete: {applied} of {len(rules)} prose/code rules "
                f"applied, {total} findings "
                f"({len(out_of_scope_set)} rule(s) out of scope for this target)"
            )
        else:
            print(f"Pattern scan complete: {len(rules)} rules, {total} findings")
        _print_invalid_rules(invalid_rules)
        for rule_id, count in sorted(summary.items(), key=lambda x: -x[1]):
            if rule_id in out_of_scope_set:
                print(
                    f"  {rule_id} [{rule_sources.get(rule_id, 'custom')}]: "
                    "n/a — no file under this target is in the rule's scope"
                )
                continue
            raw = raw_hits.get(rule_id, count)
            suffix = (
                f"  ({raw} matched, {raw - count} suppressed as same-position duplicate)"
                if raw > count
                else ""
            )
            print(f"  {rule_id} [{rule_sources.get(rule_id, 'custom')}]: {count}{suffix}")
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
    # The rates divide by different populations; name each denominator so a
    # durable actionable_rate cannot be read as a current-scan one (wv-7d2857).
    print(
        "  decided_precision is over findings in the current scan (decided_count);"
        " actionable_rate is over every durable disposition, repaired findings"
        " included (durable_decided_count)."
    )
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
            f"decided_count={summary['decided_count']} "
            f"actionable_rate={actionable_text} "
            f"durable_decided_count={summary['durable_decided_count']} "
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


_PROSE_SCHEMA_KINDS = ("lexicon", "motif", "density", "regex", "citation")
_PROSE_SCHEMA_MATCH_SCOPES = ("line", "paragraph", "heading", "document")
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
    "calibration_script",
    "calibration_command",
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
        # Raises OSError on a tier it cannot list; glob read one as empty.
        files.extend(directory_entries(rule_dir, "*.yaml"))
    return files


def _stray_yml_pattern_files(repo: Path) -> list[Path]:
    """Return every *.yml candidate across all three rule tiers.

    Only *.yaml is loaded, so a perfectly valid rule saved as .yml never
    runs. `_load_pattern_rules` (scan/list) warns about these; `validate`
    enumerated *.yaml alone, so the one command whose entire job is telling
    an author what is wrong with their rule files stayed silent about a file
    that was inert -- and still answered valid: true, exit 0.
    """
    patterns_dir = repo / ".weave" / "patterns"
    files: list[Path] = []
    for rule_dir in (_DEFAULT_PATTERNS_DIR, patterns_dir / "managed", patterns_dir):
        files.extend(directory_entries(rule_dir, "*.yml"))
    return files


def _flag_duplicate_rule_ids(
    results: list[dict[str, object]],
    schema_by_id: dict[int, _RuleSchemaInfo],
) -> bool:
    """Invalidate every entry sharing a rule id; return whether any collided.

    The real loader rejects a same-id rule appearing in more than one
    tier/file. Cross-check ALL candidates here -- not just the ones that
    independently validated -- because if one of two same-id files is
    malformed the loader fails on ITS error first, while the otherwise-valid
    copy is just as unusable once that is fixed. A malformed entry keeps its
    own parse error with the collision appended rather than losing it.
    """
    by_id: dict[str, list[dict[str, object]]] = {}
    for entry in results:
        by_id.setdefault(str(entry["rule_id"]), []).append(entry)
    collided = False
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
        collided = True
    return collided


def _prose_schema_coverage(
    results: list[dict[str, object]],
    schema_by_id: dict[int, _RuleSchemaInfo],
) -> dict[str, object]:
    """Which documented schema values the still-valid rules actually exercise.

    Computed from entries valid AFTER collision invalidation -- using the first
    pass would count a rule's kind/scope/maturity/keys as exercised even though
    it ended up invalid.
    """
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
    return {
        "kinds": {kind: kind in kinds_seen for kind in _PROSE_SCHEMA_KINDS},
        "match_scopes": {
            scope: scope in scopes_seen for scope in _PROSE_SCHEMA_MATCH_SCOPES
        },
        "maturities": {
            maturity: maturity in maturities_seen for maturity in _PROSE_SCHEMA_MATURITIES
        },
        "optional_keys": {key: key in keys_seen for key in _PROSE_SCHEMA_OPTIONAL_KEYS},
    }


def _report_calibration(entry: dict[str, object], rule: dict[str, object], repo: Path) -> None:
    """Expose a rule's rerun contract, and refuse one that cannot be rerun.

    The parser has already checked the reference's shape; here the repository
    is known, so a script that is not there makes the rule invalid rather than
    leaving a quotable number with nothing behind it (wv-335581).
    """
    if "calibration_script" not in rule:
        return
    script = str(rule["calibration_script"])
    if not (repo / script).is_file():
        raise PatternRuleValidationError(
            f"{entry['path']}: calibration_script {script!r} does not exist under {repo}"
        )
    command = str(rule["calibration_command"])
    entry["calibration"] = {
        "script": script,
        "command": command,
        "rerun": f"cd {shlex.quote(str(repo))} && {command}",
    }


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
        strays = _stray_yml_pattern_files(repo)
    except OSError as exc:
        # wv-0065a6 (external code review round 3, finding 8): repo itself
        # passed _non_directory_repo_root_error's check above, but a
        # *tier* directory under it (e.g. .weave/patterns/ made
        # unreadable, not just missing) raises PermissionError out of the
        # listing -- an uncaught traceback instead of the structured error
        # this command otherwise promises. A genuinely ABSENT tier
        # directory still stays a silent, valid skip; only inaccessibility
        # is an error. glob never raised here: it read an unlistable tier
        # as empty, so this branch only fired for an unsearchable parent
        # (wv-4852bd).
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
                _report_calibration(entry, rule, repo)
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
    if _flag_duplicate_rule_ids(results, schema_by_id):
        all_valid = False

    # Appended after the collision check on purpose: a stray shares its stem
    # with the .yaml beside it in the common "renamed a copy" case, and that is
    # not the cross-tier id collision _flag_duplicate_rule_ids exists to catch.
    for stray in strays:
        results.append(
            {
                "rule_id": stray.stem,
                "path": str(stray),
                "status": "ignored",
                "error": (
                    "rule files must use the .yaml extension; rename it to "
                    f"{stray.with_suffix('.yaml').name} for it to be loaded"
                ),
            }
        )
        all_valid = False

    # Coverage reflects entries still valid AFTER collision invalidation --
    # computing it from the first pass would count a rule's kind/scope/
    # maturity/keys as "exercised" even though it ended up invalid.
    coverage = _prose_schema_coverage(results, schema_by_id)
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
            calibration = entry.get("calibration")
            if isinstance(calibration, dict):
                print(f"  {'':40s} calibration rerun: {calibration['rerun']}")
        elif entry["status"] == "ignored":
            print(f"  {entry['rule_id']:40s} IGNORED: {entry['error']}")
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

    receipts: dict[str, dict[str, object]] = (
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
        stale_ids = _stale_managed_pattern_ids(repo)
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
    if stale_ids:
        print(
            "⚠ managed pattern projection is stale for "
            f"{', '.join(stale_ids)} — run 'wv init-repo --update' before scanning",
            file=sys.stderr,
        )
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
            src = _rule_source(rule_path)
            hits = state["hits"] if state["hits"] is not None else "-"
            print(f"  {rule_id:40s} [{src}] status={state['status']} hits={hits}")
    return 0


def _rule_matcher_spec(rule: dict[str, object]) -> dict[str, object]:
    """What a rule actually searches for, as the ENGINE searches for it.

    Consumers reimplement this from the rule YAML because nothing exposes it,
    and two unrelated consumer repositories each got it
    wrong in a different way. The failures are worth naming, because each one
    is a thing the YAML alone cannot tell you:

      citation carries no searchable text at all. Its `terms:` are check-mode
      selectors -- load_prose_rule constrains them to exactly
      {unresolved-author-date, cited-reference-missing-year} -- handed to a
      resolver. A decoder that treats them as terms emits
      `\\bunresolved-author-date\\b`, which matched 0 times in 986,291 words of
      peer-reviewed corpus and printed as "neither corpus": a false verdict
      shaped exactly like a real measurement. `expressions` is None here, and
      the reason travels with it.

      EVERY prose kind is case-insensitive, regex included. lexicon and motif
      get it from _word_regex, density from lowercasing both sides, and regex
      from _regex_findings compiling each pattern with re.IGNORECASE -- so a
      pattern written \\bdue to the fact that\\b matches "DUE TO THE FACT THAT"
      too. Decoding any of them case-sensitively undercounts every
      sentence-initial hit: 10% of prose-ai-vocabulary's true rate in that same
      corpus, and every regex rule's rate in the first pass of the 2026-09-02
      calibration, which this surface reported as "matched verbatim".

      density is a lowercased SUBSTRING scan with no word boundary at all
      (_density_findings), which is what lets an em dash be a valid term. A
      decoder that word-bounds it inverts the result: `\\b—\\b` needs a word
      character on both sides of an em dash and so matches almost nothing.

    And a match is not a finding. density and motif carry min_count, motif adds
    require_no_digit_within suppression, so a raw count answers "how often does
    this construction appear" (the rate question both consumers were asking)
    and not "how many findings would the engine report".
    """
    kind = str(rule.get("kind", ""))
    scope = str(rule.get("match_scope", ""))
    spec: dict[str, object] = {"kind": kind, "match_scope": scope}

    if kind == "citation":
        spec["expressions"] = None
        spec["reason"] = "citation rules carry check modes, not searchable text"
        spec["checks"] = [str(t) for t in _string_list(rule, "terms")]
        return spec

    if kind == "regex":
        spec["expressions"] = [str(p) for p in _string_list(rule, "patterns")]
        spec["flags"] = ["IGNORECASE"]
        spec["semantics"] = "regex, case-insensitive"
    elif kind in {"lexicon", "motif"}:
        terms = [str(t) for t in _string_list(rule, "terms")]
        if kind == "lexicon":
            # One alternation, longest-first -- the engine's own construction.
            spec["expressions"] = [_word_regex(terms).pattern]
        else:
            spec["expressions"] = [_word_regex([t]).pattern for t in terms]
        spec["flags"] = ["IGNORECASE"]
        spec["semantics"] = "word-bounded alternation, case-insensitive"
    elif kind == "density":
        spec["expressions"] = [str(t) for t in _string_list(rule, "terms")]
        spec["flags"] = ["LOWERCASE_SUBSTRING"]
        spec["semantics"] = (
            "literal substring on lowercased text, no word boundary"
        )
    else:  # pragma: no cover -- load_prose_rule rejects unknown kinds first
        spec["expressions"] = None
        spec["reason"] = f"unsupported kind {kind!r}"
        return spec

    for key in ("min_count", "require_no_digit_within"):
        if key in rule:
            spec[key] = rule[key]
    if kind in {"density", "motif"} or "min_count" in rule:
        spec["note"] = "match count is not a violation count"
    return spec


def _show_error(kind: str, detail: str, json_out: bool) -> int:
    """One structured-or-plain error shape for every `patterns show` refusal."""
    if json_out:
        print(json.dumps({"error": kind, "detail": detail}))
    else:
        print(f"patterns: {detail}", file=sys.stderr)
    return 1


def _show_rule_row(
    rule_id: str, rule_path: Path, language: str, repo: Path
) -> dict[str, object]:
    """One rule's published matcher, or why it has none."""
    row: dict[str, object] = {
        "id": rule_id,
        "language": language,
        "source": _repo_relative_posix(rule_path, repo),
    }
    if language not in PROSE_LANGUAGES:
        # ast-grep rules carry a nested rule: mapping, not expressions.
        row["kind"] = "ast-grep"
        row["expressions"] = None
        row["reason"] = "code rules are ast-grep patterns, not regexes"
        return row
    row.update(_rule_matcher_spec(load_prose_rule(rule_path, rule_id)))
    return row


def _row_strings(row: dict[str, object], field: str) -> list[str]:
    """A row field as printable strings. Rows carry object values, so a caller
    that iterates one directly is trusting a shape the type does not state."""
    value = row.get(field)
    return [str(item) for item in value] if isinstance(value, (list, tuple)) else []


def _print_rule_row(row: dict[str, object]) -> None:
    """Human rendering: expressions, their flags, or the reason there are none."""
    print(f"{row['id']}  [{row['kind']}]  {row['source']}")
    exprs = row.get("expressions")
    if exprs is None:
        print(f"    (no searchable expressions) {row.get('reason', '')}")
        checks = _row_strings(row, "checks")
        if checks:
            print(f"    checks: {', '.join(checks)}")
        print()
        return
    flags = _row_strings(row, "flags")
    suffix = f"  [{', '.join(flags)}]" if flags else ""
    for expr in _row_strings(row, "expressions"):
        print(f"    {expr}{suffix}")
    if row.get("note"):
        print(f"    note: {row['note']}")
    print()


def cmd_patterns_show(args: argparse.Namespace) -> int:
    """Emit what each rule searches for, so a consumer need not guess."""
    repo = Path(_resolve_repo(getattr(args, "path", None)))
    error_code = _non_directory_repo_root_error(repo, args.json)
    if error_code is not None:
        return error_code

    wanted = getattr(args, "rule_id", None)
    if wanted is None and not getattr(args, "all", False):
        return _show_error("no_rule_selected", "give a rule id or --all", args.json)

    try:
        conf_disabled = _disabled_patterns(repo / ".weave" / "quality.conf")
        rules = _load_pattern_rules(repo, conf_disabled)
    except PatternRuleValidationError as exc:
        return _pattern_rule_error(exc, args.json)
    except OSError as exc:
        return _show_error(
            "invalid_repo_root",
            f"could not enumerate pattern rule directories under {repo} "
            f"({exc.strerror or exc})",
            args.json,
        )

    try:
        out = [
            _show_rule_row(rule_id, rule_path, language, repo)
            for rule_id, rule_path, language in rules
            if wanted is None or rule_id == wanted
        ]
    except PatternRuleValidationError as exc:
        return _pattern_rule_error(exc, args.json)

    if wanted is not None and not out:
        return _show_error("unknown_rule", f"no rule {wanted!r} in {repo}", args.json)

    if args.json:
        print(json.dumps({"repo": str(repo), "rules": out}, indent=2))
        return 0
    for row in out:
        _print_rule_row(row)
    return 0


def cmd_prose_shape(args: argparse.Namespace) -> int:
    """Report sentence shape, and the movement a repair sweep produced."""
    repo = Path(_resolve_repo(None))
    target = Path(getattr(args, "path", None) or repo)
    if not target.is_absolute():
        target = (Path.cwd() / target).resolve()
    if not target.exists():
        return _show_error("target_missing", f"no such path: {target}", args.json)

    texts: list[str] = []
    try:
        files = markdown_files(target)
        texts = [f.read_text(encoding="utf-8", errors="replace") for f in files]
    except OSError as exc:
        return _show_error(
            "target_unreadable",
            f"cannot read {exc.filename or target} ({exc.strerror or exc})",
            args.json,
        )
    if not files:
        return _show_error(
            "no_markdown", f"no .md files under {target}", args.json
        )

    current = profile_texts(texts)
    payload: dict[str, object] = {
        "target": str(target),
        "files": len(files),
        "current": current,
    }
    # The printed table reads these, not payload: values recovered from a
    # dict[str, object] have lost the shape the profile actually has.
    comparison: tuple[dict[str, float | int], dict[str, float | int], dict[str, float | int]] | None = None

    baseline_ref = getattr(args, "baseline", None)
    if baseline_ref:
        # SAME FILE SET ON BOTH SIDES. Profiling every file now against only the
        # files that existed then would fold "documents added" into the delta and
        # read it as shape movement -- the same asymmetry that put a rule's
        # provenance at 26.9 words against 21.1. Files added since the baseline
        # are counted and excluded, not silently included on one side.
        before_texts: list[str] = []
        after_texts: list[str] = []
        added = 0
        for f in files:
            rel = _repo_relative_posix(f, repo)
            proc = subprocess.run(
                ["git", "show", f"{baseline_ref}:{rel}"],
                cwd=str(repo), capture_output=True, text=True, check=False,
            )
            if proc.returncode != 0:
                added += 1
                continue
            before_texts.append(proc.stdout)
            after_texts.append(f.read_text(encoding="utf-8", errors="replace"))
        if not before_texts:
            return _show_error(
                "baseline_empty",
                f"no file under {target} exists at {baseline_ref}",
                args.json,
            )
        before = profile_texts(before_texts)
        after = profile_texts(after_texts)
        delta: dict[str, float | int] = {
            key: round(float(value) - float(before[key]), 4)
            for key, value in after.items()
        }
        comparison = (before, after, delta)
        payload["compared_files"] = len(before_texts)
        payload["added_since_baseline"] = added
        payload["baseline"] = {"ref": baseline_ref, "profile": before}
        payload["after"] = after
        payload["delta"] = delta

    if args.json:
        print(json.dumps(payload, indent=2))
        return 0

    print(f"{len(files)} markdown file(s) under {target}")
    if comparison is not None:
        base, after, delta = comparison
        note = (
            f", {payload['added_since_baseline']} added since and excluded"
            if payload["added_since_baseline"]
            else ""
        )
        print(
            f"  {payload['compared_files']} present at {baseline_ref}{note}\n"
        )
        print(f"  {'metric':14} {'before':>10} {'after':>10} {'delta':>10}")
        print("  " + "-" * 48)
        for key, value in after.items():
            print(f"  {key:14} {base[key]:>10} {value:>10} {delta[key]:>+10}")
        print(
            "\n  A split-only sweep shows coord_pct falling with subord_pct and\n"
            "  phrase_pct flat, sentences up, and words unchanged: joins became\n"
            "  full stops rather than another relationship."
        )
    else:
        for key, value in current.items():
            print(f"  {key:14} {value}")
    return 0


def cmd_patterns(args: argparse.Namespace) -> int:
    """Dispatch pattern scan, adjudication, reporting, and promotion commands."""
    sub = getattr(args, "patterns_command", None)
    if sub == "scan":
        return cmd_patterns_scan(args)
    if sub == "list":
        return cmd_patterns_list(args)
    if sub == "show":
        return cmd_patterns_show(args)
    if sub == "promote":
        return _cmd_promote_patterns(args)
    if sub == "adjudicate":
        return cmd_patterns_adjudicate(args)
    if sub == "report":
        return cmd_patterns_report(args)
    if sub == "validate":
        return cmd_patterns_validate(args)
    print(
        "Usage: wv quality patterns {scan,list,show,adjudicate,report,validate,promote}",
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


def cmd_adjudications_export(args: argparse.Namespace) -> int:
    """Export only durable human adjudications for wv sync."""
    conn = init_db(args.hot_zone)
    try:
        export_pattern_adjudications(conn, Path(args.path))
    finally:
        conn.close()
    return 0


def cmd_adjudications_import(args: argparse.Namespace) -> int:
    """Import durable human adjudications for wv load."""
    path = Path(args.path)
    if not path.exists():
        return 0
    conn = init_db(args.hot_zone)
    try:
        import_pattern_adjudications(conn, path)
    finally:
        conn.close()
    return 0


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def _add_pattern_and_prose_parsers(sub: Any) -> None:
    """The patterns group with its subcommands, prose-shape and coaching.

    Split out of main() only for length. Registration order is help order, so
    the block is called where it used to sit and stays in its original order.
    """
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

    shape_p = sub.add_parser(
        "prose-shape", help="Sentence shape of a document set, and its movement"
    )
    shape_p.add_argument("path", nargs="?", help="File or directory (default: repo root)")
    shape_p.add_argument("--baseline", help="git ref to compare the same paths against")
    shape_p.add_argument("--json", action="store_true", help="JSON output")

    pat_show_p = patterns_sub.add_parser(
        "show", help="Show what a rule searches for, as the engine searches for it"
    )
    pat_show_p.add_argument("rule_id", nargs="?", help="Rule id (omit with --all)")
    pat_show_p.add_argument(
        "--all", action="store_true", help="Every active rule"
    )
    pat_show_p.add_argument("--path", help="Repo path (default: repo root)")
    pat_show_p.add_argument("--json", action="store_true", help="JSON output")

    pat_promote_p = patterns_sub.add_parser(
        "promote", help="Promote findings as Weave nodes"
    )
    pat_promote_p.add_argument("--parent", required=True, help="Parent node ID")
    pat_promote_p.add_argument("--json", action="store_true", help="JSON output")
    pat_promote_p.add_argument(
        "--dry-run", action="store_true", help="Show what would be created"
    )
    # Canonical mode. Legacy aggregate promotion is unchanged without --canonical,
    # so an existing caller cannot be moved onto the new lifecycle by accident.
    pat_promote_p.add_argument(
        "--canonical",
        action="store_true",
        help="Promote accepted quality evidence into canonical type=finding nodes",
    )
    pat_promote_p.add_argument(
        "--apply",
        action="store_true",
        help="Apply a reviewed plan (canonical mode; requires --plan-file)",
    )
    pat_promote_p.add_argument(
        "--plan-file",
        default="",
        help="The reviewed plan bytes to apply, exactly as produced by dry-run",
    )
    pat_promote_p.add_argument(
        "--language", default="", help="Language hint for guide resolution"
    )

    coaching_p = sub.add_parser(
        "coaching", help="Render the shared coaching projection for finding nodes"
    )
    coaching_p.add_argument("--node-ids", default="", help="Comma-separated finding node ids")
    coaching_p.add_argument("--json", action="store_true", help="Complete JSON envelope")
    coaching_p.add_argument(
        "--embed", action="store_true",
        help="Print nothing when there is nothing to coach (for embedding in another surface)",
    )
    coaching_p.add_argument(
        "--limit", type=int, default=3,
        help="Occurrences shown per block in text mode; 0 shows every occurrence",
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
    scan_parser.add_argument("--repo", help="Repository owning the selected hot zone")
    scan_parser.add_argument("--json", action="store_true", help="JSON output")
    scan_parser.add_argument(
        "--exclude",
        action="append",
        default=[],
        help="Exclude files matching glob (repeatable)",
    )

    # freshness
    freshness_parser = sub.add_parser(
        "freshness", help="Files whose content changed since the latest scan (JSON)"
    )
    freshness_parser.add_argument(
        "paths", nargs="*", help="Repo-relative paths to judge (default: every scannable file)"
    )
    freshness_parser.add_argument("--repo", default=None, help="Repository root")

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
        "--violation-type",
        default="",
        help="File every promoted finding under this catalogued violation_type "
        "(contracts/violation-vocabulary-v1.json); uncatalogued values are refused",
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

    adjudications_export = sub.add_parser("adjudications-export", help=argparse.SUPPRESS)
    adjudications_export.add_argument("path")
    adjudications_import = sub.add_parser("adjudications-import", help=argparse.SUPPRESS)
    adjudications_import.add_argument("path")

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

    _add_pattern_and_prose_parsers(sub)

    args = parser.parse_args()

    if args.verbose:
        logging.basicConfig(level=logging.DEBUG)
    else:
        logging.basicConfig(level=logging.WARNING)

    _dispatch = {
        "scan": cmd_scan,
        "hotspots": cmd_hotspots,
        "freshness": cmd_freshness,
        "diff": cmd_diff,
        "promote": cmd_promote,
        "findings-promote": cmd_findings_promote,
        "functions": cmd_functions,
        "reset": cmd_reset,
        "adjudications-export": cmd_adjudications_export,
        "adjudications-import": cmd_adjudications_import,
        "structural-search": cmd_structural_search,
        "coaching": cmd_coaching_render,
        "patterns": cmd_patterns,
        "prose-shape": cmd_prose_shape,
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
