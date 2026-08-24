#!/usr/bin/env python3
"""Find grep invocations whose PATTERN is a shell expansion with no option barrier.

A value beginning with "-" is parsed as OPTIONS rather than as the pattern. In a
positive test that is a false negative; behind `!` it is a silent false PASS; in
production it silently takes the wrong branch.

Three things this has to get right, each of which hid real sites:

  ORDER      A barrier only counts BEFORE the pattern. `grep -q "$P" -- file`
             still parses a "-x" value as an option; the `--` arrives too late.
  CONTINUATION  A backslash-newline splits one invocation across physical lines.
             Scanning line-at-a-time missed those entirely.
  DISCOVERY  Shipped entry points (scripts/wv, scripts/wv-test, ...) have no .sh
             suffix. Selecting on the extension alone silently excluded them.

Barriers differ by command:
  grep      `--` ends option parsing; `-e`/`-f` bind the pattern.
  git grep  `--` separates PATHS, not options. Only `-e`/`-f` bind the pattern.

Ignores `--grep=` (a git log option), `ast-grep` (a different tool), a `$` inside
single quotes, and a trailing `$` end-anchor: none can become an option.
"""
import os
import re
import sys

EXPANSION = re.compile(r'\$\{?[A-Za-z_]')
GREP = re.compile(r'(?<![-\w])grep\b')
GIT_BEFORE = re.compile(r'\bgit\b[^|;&\n]*$')
BINDS_PATTERN = re.compile(r'^-[a-zA-Z]*[ef]$')
SHEBANG = re.compile(rb'^#!.*\b(?:ba|da|k|z)?sh\b')


def logical_lines(path):
    """Yield (first_physical_line_number, joined_line).

    A trailing backslash continues the command, so the invocation is only whole
    once the continuations are joined.
    """
    buf, start = "", None
    with open(path, errors='replace') as fh:
        for n, raw in enumerate(fh, 1):
            line = raw.rstrip('\n')
            if start is None:
                start = n
            if line.endswith('\\'):
                buf += line[:-1] + ' '
                continue
            yield start, buf + line
            buf, start = "", None
    if buf:
        yield start or 1, buf


def _cut_outside_quotes(text):
    """Truncate at the first |, ;, & or ) that is NOT inside quotes.

    Splitting blindly cut composite patterns such as "$a|$b" in half, which both
    truncated the report and hid the second half from tokenisation.
    """
    q = None
    for i, ch in enumerate(text):
        if q:
            if ch == q:
                q = None
        elif ch in '"\'':
            q = ch
        elif ch in '|;&)':
            return text[:i]
    return text


def invocations(line):
    for m in GREP.finditer(line):
        head, args = line[:m.start()], line[m.end():]
        yield bool(GIT_BEFORE.search(head)), _cut_outside_quotes(args)


def unsafe(line):
    hits = []
    for is_git, args in invocations(line):
        toks = re.findall(r'"[^"]*"|\'[^\']*\'|\S+', args)
        barrier = False
        pattern = None
        skip_next = False
        for t in toks:
            if skip_next:            # value of -e/-f: the pattern is bound
                barrier = True
                break
            if t == '--':
                # For git grep this separates PATHS and binds nothing.
                if not is_git:
                    barrier = True
                break
            if BINDS_PATTERN.match(t):
                skip_next = True
                continue
            if t.startswith('-'):
                continue
            pattern = t
            break
        if barrier or pattern is None or pattern.startswith("'"):
            continue
        if EXPANSION.search(pattern):
            hits.append(('git grep' if is_git else 'grep') + args.rstrip())
    return hits


def is_shell(path):
    if path.endswith('.sh'):
        return True
    if '.' in os.path.basename(path):
        return False
    try:
        with open(path, 'rb') as fh:
            return bool(SHEBANG.match(fh.readline()))
    except OSError:
        return False


def scan(roots):
    files = []
    for r in roots:
        if os.path.isfile(r):
            files.append(r)
        else:
            for d, _, fs in os.walk(r):
                # tests/fixtures/grep-safety holds deliberately unsafe examples:
                # they are this audit's evidence, not code that runs.
                if os.sep + 'fixtures' + os.sep in d + os.sep:
                    continue
                for f in fs:
                    p = os.path.join(d, f)
                    if is_shell(p):
                        files.append(p)
    out = []
    for f in sorted(set(files)):
        for n, line in logical_lines(f):
            if line.lstrip().startswith('#'):
                continue
            for h in unsafe(line):
                out.append((f, n, h.strip()))
    return out


if __name__ == '__main__':
    hits = scan(sys.argv[1:])
    for f, i, h in hits:
        print(f"{f}:{i}: {h[:100]}")
    print(f"--- {len(hits)} unsafe site(s)")
    sys.exit(1 if hits else 0)
