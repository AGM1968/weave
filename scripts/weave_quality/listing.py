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
import subprocess
from collections.abc import Iterator
from fnmatch import fnmatchcase
from pathlib import Path

# A hook's GIT_DIR or GIT_INDEX_FILE would make git list another repository.
GIT_LOCATION_VARS = ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR")


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


def repo_files(target: Path) -> list[Path]:
    """The files under directory TARGET a scan should read, as paths relative to it.

    Inside a repository that is git's set: tracked plus untracked, not ignored.
    Walking instead read every ignored tree once per rule -- build output, a
    virtualenv, an agent's session store -- and a root prose scan of this
    repository read 1,965 files to scan 247, over 11 minutes (wv-c309a8).
    Outside a repository it is every path the walk yields.

    Fails closed like iter_tree: git skips an untracked directory it cannot
    open with only a warning, so that warning raises OSError rather than let
    a rule report clean over files it never read (wv-4852bd).
    """
    env = {key: value for key, value in os.environ.items() if key not in GIT_LOCATION_VARS}
    env["LC_ALL"] = "C"  # the warning below is matched in English
    try:
        listing = subprocess.run(
            ["git", "-c", "core.quotePath=false", "-C", str(target),
             "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
            capture_output=True, text=True, env=env, check=False,
        )
    except FileNotFoundError:
        listing = None
    if listing is None or listing.returncode != 0:
        return [path.relative_to(target) for path in iter_tree(target)]
    for line in listing.stderr.splitlines():
        if "could not open directory" in line:
            raise OSError(f"git could not list {target}: {line.strip()}")
    return [Path(name) for name in listing.stdout.split("\0") if name]
