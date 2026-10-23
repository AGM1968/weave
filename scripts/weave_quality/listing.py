"""Directory listings that fail closed (wv-c6c7cf).

pathlib's glob and rglob report a directory they cannot list as one holding
nothing: on Python 3.13 a mode-000 rule tier globs to [], and rglob walks
past an unreadable subtree without a word. Wherever a listing decides what
gets enforced -- which rules load, which files a rule scans, whether a rule
was out of scope -- an empty answer from a failed listing passes silently.
These raise OSError instead, and leave each caller to say what failed.
"""

from __future__ import annotations

import os
from collections.abc import Iterator
from fnmatch import fnmatchcase
from pathlib import Path


def directory_entries(directory: Path, pattern: str = "*") -> list[Path]:
    """The entries of DIRECTORY whose names match PATTERN, sorted.

    A directory that is not there -- nothing at the path, or a file where it
    would be -- has no entries, as with glob. One that is there but cannot be
    listed raises OSError, and so does one whose existence cannot be checked
    because a parent cannot be searched: glob read both as empty.
    """
    try:
        names = os.listdir(directory)
    except (FileNotFoundError, NotADirectoryError):
        return []
    return sorted(directory / name for name in names if fnmatchcase(name, pattern))


def _raise(exc: OSError) -> None:
    raise exc


def iter_tree(root: Path) -> Iterator[Path]:
    """Every path under ROOT (not ROOT itself), as rglob("*") yields them.

    Raises OSError on any directory it cannot list, ROOT included. Lazy, so a
    caller that needs only the first match stops walking there. Symlinked
    directories are yielded, not entered, as rglob does on Python 3.13.
    """
    for dirpath, dirnames, filenames in os.walk(root, onerror=_raise):
        base = Path(dirpath)
        for name in dirnames:
            yield base / name
        for name in filenames:
            yield base / name
