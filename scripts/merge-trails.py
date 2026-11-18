#!/usr/bin/env python3
"""Git merge driver for .weave/trails.md (wv-8595fb).

Registered by wv-init-repo as merge.wv-trails.driver, called as
``merge-trails.py %O %A %B``; the result is written over %A.

trails.md holds three kinds of content (the writer is _trails_save in
scripts/cmd/wv-cmd-data.sh):

- notes: ``<!-- wv-note -->`` entries, newest first, closed by
  ``<!-- /wv-notes -->``; free-form, written by people and agents, and the only
  part a save cannot rebuild;
- generated sections (active, ready, blocked, learnings, health) ending in the
  ``<!-- wv-trails-complete -->`` sentinel line, rebuilt from the graph by
  every save;
- completion records, ``## <date> <time> — Completed <id>`` blocks that
  wv done appends after the sentinel.

The merge keeps every note and every completion record from both sides: the
union, each entry once, notes newest first and records oldest first. The
generated sections are ours; they describe the graph, which merges through
its own files, and the next save regenerates them. Notes are never capped
here; the save that follows applies the cap.

Exit 0 with the merged file written over %A; exit 1, leaving %A untouched,
when either side cannot be read as a trails file, which git reports as a
conflict.
"""
from __future__ import annotations

import re
import sys
from dataclasses import dataclass

NOTE = "<!-- wv-note -->"
NOTES_END = "<!-- /wv-notes -->"
SENTINEL = "<!-- wv-trails-complete -->"
COMPLETION = re.compile(r"^## (\d{4}-\d{2}-\d{2} \d{2}:\d{2}) (—|--) Completed ")
NOTE_STAMP = re.compile(r"^### (\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\s*$")


class NotTrails(Exception):
    """The text is not a trails file this driver can merge safely."""


@dataclass
class Trails:
    """One side of the merge, split into the parts the merge treats apart."""

    preamble: list[str]
    notes: list[str]
    generated: list[str]
    records: list[str]


def _strip_blank_edges(lines: list[str]) -> list[str]:
    while lines and not lines[0].strip():
        lines = lines[1:]
    while lines and not lines[-1].strip():
        lines = lines[:-1]
    return lines


def parse(text: str) -> Trails:
    """Split a trails file into preamble, notes, generated body and records."""
    lines = text.split("\n")
    sentinel = [i for i, line in enumerate(lines) if line.startswith(SENTINEL)]
    if len(sentinel) != 1:
        raise NotTrails("expected exactly one sentinel line")
    s = sentinel[0]
    head, tail = lines[: s + 1], lines[s + 1 :]

    # Completion records: everything after the sentinel, split on headings.
    records: list[str] = []
    current: list[str] | None = None
    for line in tail:
        if COMPLETION.match(line):
            if current is not None:
                records.append("\n".join(_strip_blank_edges(current)))
            current = [line]
        elif current is not None:
            current.append(line)
        elif line.strip():
            raise NotTrails("text after the sentinel that is not a completion record")
    if current is not None:
        records.append("\n".join(_strip_blank_edges(current)))

    # Notes: from "## Notes" to the LAST end marker (a note body never holds a
    # bare marker line; the writer indents one). No marker: no notes section.
    ends = [i for i, line in enumerate(head) if line == NOTES_END]
    notes: list[str] = []
    if ends:
        end = ends[-1]
        try:
            start = max(i for i in range(end) if head[i].strip() == "## Notes")
        except ValueError as exc:
            raise NotTrails("notes end marker without a Notes heading") from exc
        preamble = head[:start]
        body = head[start + 1 : end]
        generated = head[end + 1 :]
        entry: list[str] | None = None
        for line in body:
            if line == NOTE:
                if entry is not None:
                    notes.append("\n".join(_strip_blank_edges(entry)))
                entry = [line]
            elif entry is not None:
                entry.append(line)
            elif line.strip():
                raise NotTrails("note text outside a note entry")
        if entry is not None:
            notes.append("\n".join(_strip_blank_edges(entry)))
    else:
        # The generated sections start at the first "## " heading.
        first = next((i for i, line in enumerate(head) if line.startswith("## ")), s)
        preamble = head[:first]
        generated = head[first:]
    return Trails(
        preamble=_strip_blank_edges(preamble),
        notes=notes,
        generated=_strip_blank_edges(generated),
        records=records,
    )


def _note_key(entry: str) -> tuple[int, str]:
    """Dated notes sort newest first; undated ones after them."""
    for line in entry.split("\n")[1:3]:
        m = NOTE_STAMP.match(line)
        if m:
            return (0, m.group(1))
    return (1, "")


def _record_key(record: str) -> str:
    """A completion record's timestamp; parse() admits no record without one."""
    m = COMPLETION.match(record)
    return m.group(1) if m else ""


def _union(ours: list[str], theirs: list[str]) -> list[str]:
    merged = list(ours)
    seen = set(ours)
    for entry in theirs:
        if entry not in seen:
            seen.add(entry)
            merged.append(entry)
    return merged


def merge(ours_text: str, theirs_text: str) -> str:
    """Merge two trails files: union of notes and records, our generated part."""
    ours, theirs = parse(ours_text), parse(theirs_text)
    notes = _union(ours.notes, theirs.notes)
    dated = sorted((n for n in notes if _note_key(n)[0] == 0), key=lambda n: _note_key(n)[1], reverse=True)
    notes = dated + [n for n in notes if _note_key(n)[0] == 1]
    records = _union(ours.records, theirs.records)
    records.sort(key=_record_key)  # stable: the same minute keeps its order

    generated = list(ours.generated)
    if notes and not ours.notes:
        # The sentinel lists the sections the save wrote; Notes is one of them.
        last = generated[-1]
        prefix = SENTINEL + " sections="
        if last.startswith(prefix) and not last[len(prefix):].startswith("## Notes"):
            rest = last[len(prefix):]
            generated[-1] = prefix + "## Notes" + ("|" + rest if rest else "")

    out: list[str] = list(ours.preamble)
    if notes:
        out += ["", "## Notes", "", "\n\n".join(notes), "", NOTES_END]
    out += [""] + generated
    for record in records:
        out += ["", record]
    return "\n".join(out).lstrip("\n") + "\n"


def main(argv: list[str]) -> int:
    """Run as a git merge driver: <base> <ours> <theirs>, result over ours."""
    if len(argv) != 4:
        print("usage: merge-trails.py <base> <ours> <theirs>", file=sys.stderr)
        return 2
    _, _base, ours_path, theirs_path = argv
    try:
        with open(ours_path, encoding="utf-8") as fh:
            ours_text = fh.read()
        with open(theirs_path, encoding="utf-8") as fh:
            theirs_text = fh.read()
        merged = merge(ours_text, theirs_text)
    except (OSError, UnicodeDecodeError, NotTrails) as exc:
        print(f"merge-trails: {exc}; resolve .weave/trails.md by hand", file=sys.stderr)
        return 1
    with open(ours_path, "w", encoding="utf-8") as fh:
        fh.write(merged)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
