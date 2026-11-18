#!/usr/bin/env python3
"""Pre-commit prose gate: refuse markdown that introduces new pattern findings.

Compares each staged markdown file's STAGED BLOB against its HEAD baseline and
reports only what the diff added. Pre-existing findings never block: this repo
carries them by the hundred (82 `, so` hits in CHANGELOG.md alone), and a gate
that fails on inherited debt is a gate that gets bypassed.

Blocking is scoped by rule SOURCE, not severity -- every rule in the corpus is
`info`, so severity cannot separate a rendering defect from house style:

  managed + custom -> BLOCK. The curated AI-tell corpus (prose-ai-vocabulary,
      prose-em-dash-density, prose-self-attested-virtue, markdown-split-code-span
      and peers) plus this project's own rules.
  default          -> ADVISE. prose-register-review and prose-emphasis-hedge fire
      on ordinary technical prose; blocking on them would train the bypass reflex.

Findings are matched by `finding_key`, which is derived from the scanned PATH and
the match, but NOT from the line number: shifting a line keeps its key, so a
reflow does not read as a new finding. A match repeated in the file also carries
the words around it in its paragraph (wv-0f8658), so rewriting those makes it a
new finding, while moving or reflowing it does not. Because the key is path-dependent, both
versions of a file must be scanned at the SAME path or nothing ever matches --
so each version is copied to one shared scratch path and scanned in turn.

Usage: prose-gate.py <staged-dir> <head-dir> <path> [<path> ...]

Both directories hold materialised blobs under the repo-relative path. A path
absent from <head-dir> is a new file and baselines to empty.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

BLOCKING_SOURCES = {"managed", "custom"}

# Coaching guides are exempt. The coaching-guide contract REQUIRES a `## Why`
# section, and `prose-rhetorical-heading` (managed, so blocking) fires on exactly
# that heading -- both the existing swallowed-exception guide and any new one
# carry the hit. A new file has no HEAD baseline, so every finding in it reads as
# new, and the gate would refuse every guide anyone ever writes. The conflict is
# between two project contracts rather than a defect in the prose, so it is
# scoped here by path instead of by weakening the rule for every document.
EXEMPT_PREFIXES = ("scripts/weave_quality/guides/", ".weave/guides/")


def scan(path: Path) -> dict[str, Any] | None:
    """Run the pattern scanner over one file. None if it could not be scanned."""
    wv = os.environ.get("WV_BIN") or "wv"
    try:
        proc = subprocess.run(
            [wv, "quality", "patterns", "scan", str(path), "--json"], check=False,
            capture_output=True,
            text=True,
            timeout=120,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    try:
        report = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return None
    # The scanner reports its own failure as JSON on stdout, {"error": ...} with
    # exit 1. That body has no matches, so it read as a clean scan and the gate
    # passed every file it could not scan (wv-4dcf9c). Only a successful run
    # with a scan's shape is a report.
    if (proc.returncode != 0 or not isinstance(report, dict) or "error" in report
            or not isinstance(report.get("matches"), list)
            or not isinstance(report.get("by_rule"), dict)):
        return None
    return report


def keyed(report: dict[str, Any] | None) -> tuple[dict[str, dict[str, Any]], dict[str, int]]:
    """Split a report into keyed matches and per-rule counts."""
    if not report:
        return {}, {}
    matches = {}
    for m in report.get("matches", []) or []:
        key = m.get("finding_key")
        if key:
            matches[key] = m
    counts = {k: v for k, v in (report.get("by_rule") or {}).items() if v}
    return matches, counts


def source_of(report: dict[str, Any] | None, rule: str) -> str:
    """Name where a rule's configuration came from in a scan report ('default' when unrecorded)."""
    if not report:
        return "default"
    source = (report.get("rule_sources") or {}).get(rule, "default")
    return str(source)


def main(argv: list[str]) -> int:
    """Run the prose gate over staged paths against their HEAD versions; nonzero blocks the commit."""
    if len(argv) < 4:
        print(__doc__, file=sys.stderr)
        return 2
    staged_dir, head_dir, paths = Path(argv[1]), Path(argv[2]), argv[3:]

    blocking: list[str] = []
    advisory: list[str] = []
    invalid: dict[str, str] = {}

    work = Path(tempfile.mkdtemp(prefix="wv-prose-scan."))
    try:
        rc = compare(staged_dir, head_dir, paths, work, blocking, advisory, invalid)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print_invalid_rules(invalid)
    if rc:
        return rc

    return print_findings(blocking, advisory)


def print_invalid_rules(invalid: dict[str, str]) -> None:
    """Name the rule files the scanner skipped as invalid; every other rule still ran (wv-d0e4d6)."""
    if not invalid:
        return
    print("", file=sys.stderr)
    print(f"! prose gate: {len(invalid)} rule file(s) are invalid and were not applied:", file=sys.stderr)
    for path, error in sorted(invalid.items()):
        print(f"  {path}: {error}", file=sys.stderr)
    print("  Every other rule ran. Fix or remove them: wv quality patterns validate", file=sys.stderr)


def compare(
    staged_dir: Path,
    head_dir: Path,
    paths: list[str],
    work: Path,
    blocking: list[str],
    advisory: list[str],
    invalid: dict[str, str] | None = None,
) -> int:
    """Scan each staged prose file and its HEAD version, sorting new findings into blocking and advisory lists.

    Rule files the scanner skipped as invalid are collected into `invalid`, path to error.
    """
    for rel in paths:
        if rel.startswith(EXEMPT_PREFIXES):
            continue
        staged_file = staged_dir / rel
        if not staged_file.is_file():
            # Fails closed: a staged path we cannot read is a gate we cannot run.
            print(
                f"x prose gate: staged blob for {rel} was not materialised",
                file=sys.stderr,
            )
            return 1

        # One scratch path, scanned twice. finding_key is path-derived, so the
        # baseline and the candidate must occupy the same path to be comparable.
        scan_at = work / rel
        scan_at.parent.mkdir(parents=True, exist_ok=True)

        head_file = head_dir / rel
        before = None
        if head_file.is_file():
            shutil.copyfile(head_file, scan_at)
            before = scan(scan_at)

        shutil.copyfile(staged_file, scan_at)
        after = scan(scan_at)
        if after is None:
            print(f"x prose gate: could not scan staged {rel}", file=sys.stderr)
            return 1

        if invalid is not None:
            collect_invalid_rules(after, invalid)
        sort_new_findings(rel, before, after, blocking, advisory)

    return 0


def collect_invalid_rules(report: dict[str, Any], invalid: dict[str, str]) -> None:
    """Add the rule files a scan skipped as invalid to `invalid`, path to error (wv-d0e4d6)."""
    for entry in report.get("invalid_rules") or []:
        if isinstance(entry, dict):
            invalid[str(entry.get("path", "?"))] = str(entry.get("error", ""))


def sort_new_findings(
    rel: str,
    before: dict[str, Any] | None,
    after: dict[str, Any],
    blocking: list[str],
    advisory: list[str],
) -> None:
    """Append each finding in `after` that `before` lacks to blocking or advisory, by its rule's source."""
    after_keys, after_counts = keyed(after)
    before_keys, before_counts = keyed(before)

    seen_rules = set()
    for key, m in after_keys.items():
        if key in before_keys:
            continue
        rule = m.get("rule_id", "?")
        seen_rules.add(rule)
        src = m.get("source") or source_of(after, rule)
        line = f"  {rel}:{m.get('line', '?')}:{m.get('col', '?')}: [{rule}/{src}] {m.get('match_text', '')}"
        (blocking if src in BLOCKING_SOURCES else advisory).append(line)

    # Rules that reported a count but no keyed match still need comparing.
    for rule, count in after_counts.items():
        if rule in seen_rules:
            continue
        delta = count - before_counts.get(rule, 0)
        if delta <= 0:
            continue
        src = source_of(after, rule)
        line = f"  {rel}: [{rule}/{src}] {delta} new finding(s)"
        (blocking if src in BLOCKING_SOURCES else advisory).append(line)


def print_findings(blocking: list[str], advisory: list[str]) -> int:
    """Print advisory and blocking findings to stderr and return 1 if anything blocks."""
    if advisory:
        print("", file=sys.stderr)
        print("! prose gate (advisory) — new default-rule findings:", file=sys.stderr)
        for line in advisory:
            print(line, file=sys.stderr)
        print(
            "  Not blocking. Coaching: wv quality patterns show <rule>",
            file=sys.stderr,
        )

    if blocking:
        print("", file=sys.stderr)
        print("x prose gate: STAGED content introduces new findings:", file=sys.stderr)
        for line in blocking:
            print(line, file=sys.stderr)
        print("", file=sys.stderr)
        print("  These are the bytes being committed — the working tree may differ.", file=sys.stderr)
        print("  Managed and custom rules block; pre-existing findings do not.", file=sys.stderr)
        print("  Inspect with: wv quality patterns scan <file>", file=sys.stderr)
        print("", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
