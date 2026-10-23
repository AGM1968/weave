#!/usr/bin/env python3
"""Find pipelines whose last stage exits early, in files that set pipefail.

`writer | grep -q PATTERN` under `set -o pipefail` returns 141, not 0, when the
pattern matches: grep exits at the first hit, the writer is killed by SIGPIPE,
and pipefail promotes that to the pipeline's status. A MATCH therefore reports
FAILURE. It is never a false pass -- only a false failure -- but it is a
timing-dependent one, because it needs the writer to still be writing when the
reader leaves. That is what made it present as a flake: wv-d91570 chased it as
the rc.12 "45 of 46" mystery before the shape was named.

The rule is structural, so safe shapes need no special-casing:

  unsafe  the LAST stage can exit before its input is consumed --
          grep -q/-l/-L/-m, head, sed with a q command, the read builtin.
  safe    the last stage consumes all input (wc, tail, sort, cat, awk, tr, jq,
          sed without q). It never leaves early, so the writer is never
          signalled. These are skipped because the rule does not match them,
          not because they are listed anywhere.
  safe    a herestring or redirect is not a pipeline at all: `grep -q X <<<"$v"`
          has no writer process to kill. That is also the fix for most sites --
          capture first, then match on the captured value.

Only files that set pipefail are scanned. Without it the pipeline reports the
last stage's own status and the bug cannot occur.
"""
import os
import re
import sys
from pathlib import Path
from collections.abc import Iterator

PIPEFAIL = re.compile(r'set\s+-[a-zA-Z]*o\s+pipefail|set\s+-o\s+pipefail')
SHEBANG = re.compile(rb'^#!.*\b(?:ba|da|k|z)?sh\b')

# A last stage that can leave before reading its input to the end.
EARLY_EXIT = (
    # grep -q/-l/-L anywhere in a bundle: -q, -qF, -rlF all leave on first match.
    re.compile(r"^!?\s*(?:\w+=\S+\s+)*grep\b(?=[^|]*\s-[a-zA-Z]*[qlL])"),
    # grep -m N stops after N matches.
    re.compile(r"^!?\s*(?:\w+=\S+\s+)*grep\b(?=[^|]*\s-[a-zA-Z]*m\s*\d)"),
    re.compile(r"^!?\s*(?:\w+=\S+\s+)*head\b"),
    # sed with a q command: 2q, ;q, 'q', $q -- q as a command, not inside a
    # regex or a replacement. Anchored on the delimiters a command can carry.
    re.compile(r"^!?\s*(?:\w+=\S+\s+)*sed\b(?=[^|]*(?:^|[;'\"\s\d$])q(?:[;'\"\s]|$))"),
    re.compile(r"^!?\s*read\b"),
)


def logical_lines(path: str) -> Iterator[tuple[int, str]]:
    """Yield (first_physical_line, joined_line).

    A trailing backslash continues the line, and so does a trailing single `|`:
    bash reads `producer |` then an indented `grep -q ...` as one pipeline.
    Joining only backslashes left every two-line early-exit pipeline unscanned,
    and one of them flaked the pre-push gate (wv-29452e).
    """
    buf = ""
    start: int | None = None
    with open(path, encoding='utf-8', errors='replace') as fh:
        for n, raw in enumerate(fh, 1):
            line = raw.rstrip('\n')
            if start is None:
                start = n
            if line.endswith('\\'):
                buf += line[:-1] + ' '
                continue
            code = strip_comment(line).rstrip()
            if code.endswith('|') and not code.endswith('||'):
                buf += code + ' '
                continue
            yield start, buf + line
            buf, start = "", None
    if buf:
        yield start or 1, buf


def split_top_level(text: str, seps: tuple[str, ...]) -> list[str]:
    """Split on `seps` that are outside quotes, parens and braces.

    Segmenting on a bare `;` cut sed -n '1p;q' in half, so the q command landed
    in its own fragment and the stage stopped looking like sed at all.
    """
    out: list[str] = []
    buf = ""
    quote: str | None = None
    depth = 0
    i = 0
    while i < len(text):
        ch = text[i]
        if quote:
            buf += ch
            if ch == quote:
                quote = None
            i += 1
            continue
        if ch in '"\'':
            quote = ch
            buf += ch
        elif ch in '([{':
            depth += 1
            buf += ch
        elif ch in ')]}':
            depth -= 1
            buf += ch
        elif depth == 0 and any(text.startswith(sep, i) for sep in seps):
            sep = next(sep for sep in seps if text.startswith(sep, i))
            out.append(buf)
            buf = ""
            i += len(sep)
            continue
        else:
            buf += ch
        i += 1
    out.append(buf)
    return out


def split_pipeline(text: str) -> list[str]:
    """Top-level pipeline stages, honouring quotes, parens and ||.

    A `|` inside 'a|b', inside $( ), or doubled as || is not a stage boundary.
    Splitting naively cut grep -E 'x|y' in half and invented stages.
    """
    stages: list[str] = []
    buf = ""
    quote: str | None = None
    depth = 0
    i = 0
    while i < len(text):
        ch = text[i]
        if quote:
            buf += ch
            if ch == quote:
                quote = None
            i += 1
            continue
        if ch in '"\'':
            quote = ch
            buf += ch
        elif ch in '([{':
            depth += 1
            buf += ch
        elif ch in ')]}':
            depth -= 1
            buf += ch
        elif ch == '|' and depth == 0:
            if i + 1 < len(text) and text[i + 1] == '|':
                buf += '||'
                i += 2
                continue
            stages.append(buf)
            buf = ""
        else:
            buf += ch
        i += 1
    stages.append(buf)
    return [s.strip() for s in stages]


def strip_comment(text: str) -> str:
    """Drop a trailing # comment that is not inside quotes.

    Without this the scanner read prose. `producer | sed 's/a/b/'  # no q
    command` matched the sed-with-q rule on the word "q" in the comment --
    a false positive produced by the scanner's own fixture.
    """
    quote: str | None = None
    for i, ch in enumerate(text):
        if quote:
            if ch == quote:
                quote = None
        elif ch in '"\'':
            quote = ch
        elif ch == '#' and (i == 0 or text[i - 1].isspace()):
            return text[:i]
    return text


def substitution_bodies(text: str) -> list[str]:
    """The bodies of every $( ) in text, nested ones included; not $(( )).

    split_pipeline treats a $( ) as one opaque stage, which is right for the
    outer pipeline -- but the pipeline INSIDE it was never looked at, and
    `x=$(writer | grep -q PAT && echo yes || echo no)` consumes exactly the
    status pipefail corrupts. It hid a real instance (found 2026-09-26 while
    widening the ultrareview fixes).
    """
    out: list[str] = []
    i = 0
    while True:
        j = text.find('$(', i)
        if j < 0:
            return out
        if text.startswith('$((', j):
            i = j + 3
            continue
        k, depth = j + 2, 1
        quote: str | None = None
        while k < len(text) and depth:
            ch = text[k]
            if quote:
                if ch == quote:
                    quote = None
            elif ch in '"\'':
                quote = ch
            elif ch == '(':
                depth += 1
            elif ch == ')':
                depth -= 1
            k += 1
        if depth == 0:
            body = text[j + 2:k - 1]
            out.append(body)
            out.extend(substitution_bodies(body))
        i = j + 2


def unsafe_stage(stage: str) -> bool:
    return any(p.search(stage) for p in EARLY_EXIT)


def scan_file(path: str) -> list[tuple[int, str]]:
    text = Path(path).read_text(encoding='utf-8', errors='replace')
    if not PIPEFAIL.search(text):
        return []
    hits: list[tuple[int, str]] = []
    for n, line in logical_lines(path):
        stripped = line.strip()
        if stripped.startswith('#') or '|' not in stripped:
            continue
        stripped = strip_comment(stripped).strip()
        if '|' not in stripped:
            continue
        found = False
        for text in [stripped] + substitution_bodies(stripped):
            for segment in split_top_level(text, ('&&', ';')):
                stages = split_pipeline(segment)
                if len(stages) < 2:
                    continue
                # Any reader stage, not only the last (wv-7699b4): in
                # `writer | grep -m1 | cut` grep still leaves early and the
                # writer still takes SIGPIPE; the stage after it changes nothing.
                if any(unsafe_stage(s) for s in stages[1:]):
                    hits.append((n, ' | '.join(s.strip() for s in stages)))
                    found = True
                    break
            if found:
                break
    return hits


def is_shell(path: str) -> bool:
    if path.endswith('.sh'):
        return True
    if '.' in os.path.basename(path):
        return False
    try:
        with open(path, 'rb') as fh:
            return bool(SHEBANG.match(fh.readline()))
    except OSError:
        return False


def scan(roots: list[str]) -> list[tuple[str, int, str]]:
    files: list[str] = []
    for r in roots:
        if os.path.isfile(r):
            files.append(r)
            continue
        for d, _, fs in os.walk(r):
            # fixtures/ holds deliberately unsafe examples: evidence, not code.
            if os.sep + 'fixtures' + os.sep in d + os.sep:
                continue
            for f in fs:
                p = os.path.join(d, f)
                if is_shell(p):
                    files.append(p)
    out: list[tuple[str, int, str]] = []
    for f in sorted(set(files)):
        for n, pipeline in scan_file(f):
            out.append((f, n, pipeline))
    return out


def main(argv: list[str]) -> int:
    """Report every hit in the given paths; exit 1 if there are any."""
    hits = scan(argv)
    for path, line, text in hits:
        print(f"{path}:{line}: {text[:120]}")
    print(f"--- {len(hits)} early-exit pipeline(s) under pipefail")
    return 1 if hits else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
