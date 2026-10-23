#!/usr/bin/env python3
"""Find docs that call a graph node open when the graph says it is done.

A document that cites a node restates that node's status in prose, and nothing
derives one from the other: the node closes and the sentence keeps saying
"tracked as" or "pending". wv-38b7df recorded the gap and a scan on 2026-09-22
(wv-5a87b2) measured it at ten instances across nine docs, one of them
introduced the same day by closing the node the doc cited. This reports those
sentences so a machine catches the next one instead of a reader.

Status comes from the graph, never from the document, and the status column
and its closed value come from contracts/node-field-registry-v1.json rather
than a copy here: a scanner that restated the status vocabulary would be one
more instance of the drift it looks for. The scan is advisory: it exits 0
unless --strict is given.

Three shapes are exempt because they are historical by design, not drift:
  - docs/findings/, whose files are dated records of what was true then;
  - a provenance-trailer entry, "<Label>: wv-xxxxxx (YYYY-MM-DD) ...";
  - a sentence that already says the work closed, or is in the past tense.
"""
from __future__ import annotations

import argparse
import json
import re
import sqlite3
import sys
from pathlib import Path
from typing import Any
from collections.abc import Iterator

NODE_ID = re.compile(r"\bwv-[0-9a-f]{6}\b")
# Present-tense assertions that the cited node is not finished.
OPEN_PHRASE = re.compile(
    r"\b(?:tracked (?:as|in|by|under)"
    r"|(?:remains?|is|are|still) (?:open|pending|blocked|todo|unclaimed)"
    r"|blocked (?:on|by)"
    r"|not yet (?:done|landed|closed|implemented|run)"
    r"|(?:implementation|work|review) pending"
    r"|awaiting|in flight|owns closing|open follow-?up)\b",
    re.I,
)
# Anything in the same window saying the work already finished, or narrating
# it in the past, means the sentence is not asserting a current open state.
CLOSED_MARKER = re.compile(
    r"\b(?:closed|closes|landed|implemented|resolved|since|then|stayed|was|were"
    r"|historical|superseded|retired|as of \d{4}-\d{2}-\d{2})\b",
    re.I,
)
TRAILER_ENTRY = re.compile(r"^[A-Z][\w ()/+-]*: `?wv-[0-9a-f]{6}`? \(\d{4}-\d{2}-\d{2}\)")
EXEMPT_DIRS = ("docs/findings/",)
# A block ends at a blank line, a heading or a new list item, so one bullet's
# past tense cannot excuse the next bullet's open claim.
BLOCK_START = re.compile(r"^\s*(?:$|#|[-*+] |\d+\. )")
# A claim is judged within its own clause: "implemented under wv-A; parent
# wv-B remains open" is one closed and one open citation, not two closed ones.
CLAUSE_END = re.compile(r"[.;!?](?=\s|$)")


def blocks(text: str) -> Iterator[tuple[int, str]]:
    """Yield (first_line_number, block_text) for each block of the document."""
    start = 1
    current: list[str] = []
    for number, line in enumerate(text.split("\n"), 1):
        if BLOCK_START.match(line) and current:
            yield start, "\n".join(current)
            start = number
            current = []
        if line.strip():
            if not current:
                start = number
            current.append(line)
    if current:
        yield start, "\n".join(current)


def clause_around(body: str, pos: int) -> str:
    lo = max((m.end() for m in CLAUSE_END.finditer(body, 0, pos)), default=0)
    hi = next((m.start() for m in CLAUSE_END.finditer(body, pos)), len(body))
    return " ".join(body[lo:hi].split())


FIELD_REGISTRY = Path(__file__).resolve().parents[2] / "contracts/node-field-registry-v1.json"
CLOSED_STATUS = "done"


def status_column() -> str:
    """The nodes column holding status, and proof the closed value still exists."""
    field = json.loads(FIELD_REGISTRY.read_text(encoding="utf-8"))["fields"]["status"]
    storage: str = field["storage"]
    kind, _, column = storage.partition(":")
    if kind != "column" or not re.fullmatch(r"[a-z_]+", column):
        raise SystemExit(f"{FIELD_REGISTRY.name}: status is no longer a plain column "
                         f"({field['storage']}); update this scanner")
    if CLOSED_STATUS not in field["value"]["enum"]:
        raise SystemExit(f"{FIELD_REGISTRY.name}: status enum no longer contains "
                         f"'{CLOSED_STATUS}'; update this scanner")
    return column


def load_status(db: Path) -> dict[str, str]:
    column = status_column()
    with sqlite3.connect(f"file:{db}?mode=ro", uri=True) as conn:
        return dict(conn.execute(f"SELECT id, {column} FROM nodes"))


def scan(root: Path, status: dict[str, str]) -> dict[str, Any]:
    drift = []
    scanned = cited_done = 0
    for path in sorted((root / "docs").glob("**/*.md")):
        rel = path.relative_to(root).as_posix()
        if rel.startswith(EXEMPT_DIRS):
            continue
        scanned += 1
        text = path.read_text(encoding="utf-8", errors="replace")
        for first_line, body in blocks(text):
            # An entry wraps, so its cited ids often sit on continuation lines;
            # the entry is recognised by its first line.
            if TRAILER_ENTRY.match(body.split("\n", 1)[0].lstrip("> ")):
                continue
            for match in NODE_ID.finditer(body):
                if status.get(match.group(0)) != CLOSED_STATUS:
                    continue
                cited_done += 1
                clause = clause_around(body, match.start())
                phrase = OPEN_PHRASE.search(clause)
                if not phrase or CLOSED_MARKER.search(clause):
                    continue
                drift.append({
                    "file": rel, "line": first_line + body.count("\n", 0, match.start()),
                    "id": match.group(0), "phrase": phrase.group(0), "excerpt": clause[:160],
                })
    return {"scanned_files": scanned, "cited_done": cited_done, "drift": drift}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo-root", type=Path, default=Path("."))
    ap.add_argument("--db", type=Path, required=True,
                    help="graph database to resolve node status from, e.g. $(wv hotzone --db)")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--strict", action="store_true", help="exit 1 when drift is found")
    args = ap.parse_args()

    report = scan(args.repo_root.resolve(), load_status(args.db))
    if args.json:
        json.dump(report, sys.stdout, indent=1)
        print()
    else:
        for item in report["drift"]:
            print(f"{item['file']}:{item['line']}: {item['id']} is done but cited as "
                  f"'{item['phrase']}'")
        print(f"{len(report['drift'])} citation(s) call a done node open "
              f"({report['cited_done']} done-node citations in {report['scanned_files']} docs)")
    return 1 if args.strict and report["drift"] else 0


if __name__ == "__main__":
    sys.exit(main())
