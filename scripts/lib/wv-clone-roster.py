#!/usr/bin/env python3
"""Clone roster (Stage B prerequisite 4, wv-6e44d9).

An acknowledgement only speaks for the clone that writes it, so Stage B needs
to know which clones exist. Catalog actors cannot say: a session-suffixed actor
is new every agent session, one checkout holds many actors, and one coarse
<harness>-<host>-<user> writes from every checkout on its host. The roster is
therefore declared by the operator, one committed file per clone, and the
catalog is used only as evidence: an actor in it that no rostered clone
accounts for means a writer nobody declared, and compaction must refuse.

Roster file: .weave/clones/<clone>.roster, where <clone> names the clone.
One directive per line; blank lines and lines starting with # are ignored.

    prefix <coarse actor>   accounts for <coarse actor> itself and for
                            <coarse actor>-h<16 hex> and -s<1-12 alnum>, the
                            current and the earlier session-suffixed forms
    id <actor>              accounts for exactly <actor> (a WV_AGENT_ID)
    confirmed <YYYY-MM-DD>  the date the operator last confirmed this clone;
                            exactly one per file
    watermark <seq>         the highest lineage seq this clone has acknowledged
                            loading (prune policy wv-3937eb); at most one per
                            file. Tombstone compaction needs one on every clone
                            and compacts below the lowest.

Accounting by declared prefixes, and the 21-day staleness warning, are owner
rulings (2026-11-07 and 2026-11-05). Staleness never expires or retires a
clone and never changes the exit status. Two clones may declare the same
prefix: two checkouts on one host share it.

Actors are read from v2 sidecars (actor_id), from the weave-lineage header of
v1 deltas, and failing that from a v1 filename
(<sec>-<subsec>-<seq>-<actor>-<pid>.sql, or the older <epoch>-<actor>.sql). A
delta whose actor cannot be read is unattributed and refuses too: an
undeclared writer the check cannot name is still an undeclared writer.

Usage:
  wv-clone-roster.py actors WEAVE_DIR          catalog census: "<files> <actor>"
  wv-clone-roster.py check WEAVE_DIR [--today=YYYY-MM-DD]
      exit 0  every catalog actor is accounted for (stale warnings on stderr)
      exit 1  unaccounted actors or unattributed deltas, listed on stdout as
              "unaccounted <actor> <files> <example path>" and
              "unattributed <path>"
      exit 2  the roster is missing a field or malformed; nothing is judged
  wv-clone-roster.py watermark WEAVE_DIR
      exit 0  prints the lowest watermark across every rostered clone
      exit 1  no clone is rostered, or a clone has no watermark (named on
              stdout as "unwatermarked <clone>")
      exit 2  the roster is malformed; nothing is judged
"""
from __future__ import annotations

import json
import os
import re
import sys
from datetime import date
from typing import NamedTuple

STALE_DAYS = 21
CLONE_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
SESSION_SUFFIX = r"-(?:h[0-9a-f]{16}|s[A-Za-z0-9]{1,12})"
LINEAGE_HEADER = re.compile(rb"/\* weave-lineage seq=[0-9]+ actor=(.*?) \*/")
V1_NAMES = (
    re.compile(r"^[0-9]+-[0-9]+-[0-9]+-(.+)-[0-9]+\.sql$"),
    re.compile(r"^[0-9]+-(.+?)\.sql$"),
)


class RosterError(Exception):
    """A roster file that cannot be trusted; the check refuses to judge."""


class Clone(NamedTuple):
    """One declared clone."""

    name: str
    prefixes: tuple[str, ...]
    ids: tuple[str, ...]
    confirmed: date
    watermark: int | None = None


def _directive(where: str, line: str) -> tuple[str, str | date | int]:
    """One roster line as (directive, value), or RosterError."""
    parts = line.split()
    if len(parts) != 2:
        raise RosterError(f"{where}: expected '<directive> <value>', got '{line}'")
    key, value = parts
    if key in ("prefix", "id"):
        return key, value
    if key == "watermark":
        if not value.isdigit():
            raise RosterError(f"{where}: bad watermark '{value}' (a lineage seq, digits only)")
        return key, int(value)
    if key != "confirmed":
        raise RosterError(f"{where}: unknown directive '{key}'")
    try:
        return key, date.fromisoformat(value)
    except ValueError as exc:
        raise RosterError(f"{where}: bad date '{value}'") from exc


def _parse_roster_file(path: str, name: str) -> Clone:
    prefixes: list[str] = []
    ids: list[str] = []
    confirmed: list[date] = []
    watermarks: list[int] = []
    with open(path, encoding="utf-8") as fh:
        for lineno, raw in enumerate(fh, 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            key, value = _directive(f"{path}:{lineno}", line)
            if isinstance(value, date):
                confirmed.append(value)
            elif isinstance(value, int):
                watermarks.append(value)
            else:
                (prefixes if key == "prefix" else ids).append(value)
    if not prefixes and not ids:
        raise RosterError(f"{path}: declares no prefix and no id")
    if len(confirmed) != 1:
        raise RosterError(f"{path}: needs exactly one 'confirmed' line, has {len(confirmed)}")
    if len(watermarks) > 1:
        raise RosterError(f"{path}: at most one 'watermark' line, has {len(watermarks)}")
    return Clone(name, tuple(prefixes), tuple(ids), confirmed[0],
                 watermarks[0] if watermarks else None)


def read_roster(weave_dir: str) -> list[Clone]:
    """Every clone declared under WEAVE_DIR/clones, or RosterError."""
    root = os.path.join(weave_dir, "clones")
    if not os.path.isdir(root):
        return []
    clones = []
    for entry in sorted(os.listdir(root)):
        if entry.startswith(".") or not entry.endswith(".roster"):
            continue
        name = entry[: -len(".roster")]
        if not CLONE_NAME.fullmatch(name):
            raise RosterError(f"{root}/{entry}: bad clone name '{name}'")
        clones.append(_parse_roster_file(os.path.join(root, entry), name))
    return clones


def _v2_actor(path: str) -> str | None:
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, ValueError):
        return None
    actor = doc.get("actor_id") if isinstance(doc, dict) else None
    return actor if isinstance(actor, str) and actor else None


def _v1_actor(path: str, filename: str) -> str | None:
    try:
        with open(path, "rb") as fh:
            match = LINEAGE_HEADER.search(fh.read())
    except OSError:
        return None
    if match:
        actor = match.group(1).decode("utf-8", "replace")
        return actor or None
    for pattern in V1_NAMES:
        named = pattern.match(filename)
        if named:
            return named.group(1)
    return None


def catalog_actors(weave_dir: str) -> tuple[dict[str, list[str]], list[str]]:
    """Map actor -> delta paths (relative to WEAVE_DIR), plus unattributed paths."""
    actors: dict[str, list[str]] = {}
    unattributed: list[str] = []
    base = os.path.join(weave_dir, "deltas")
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = sorted(d for d in dirnames if not d.startswith("."))
        in_v2 = os.path.basename(dirpath) == "v2"
        for filename in sorted(filenames):
            path = os.path.join(dirpath, filename)
            if in_v2 and filename.endswith(".json"):
                actor = _v2_actor(path)
            elif not in_v2 and filename.endswith(".sql"):
                actor = _v1_actor(path, filename)
            else:
                continue
            rel = os.path.relpath(path, weave_dir)
            if actor is None:
                unattributed.append(rel)
            else:
                actors.setdefault(actor, []).append(rel)
    return actors, unattributed


def accounts_for(clone: Clone, actor: str) -> bool:
    """True when CLONE's declaration covers ACTOR."""
    if actor in clone.ids:
        return True
    return any(re.fullmatch(re.escape(p) + f"(?:{SESSION_SUFFIX})?", actor) for p in clone.prefixes)


def cmd_actors(weave_dir: str) -> int:
    """Print the catalog census, most files first."""
    actors, unattributed = catalog_actors(weave_dir)
    for actor, paths in sorted(actors.items(), key=lambda kv: (-len(kv[1]), kv[0])):
        print(f"{len(paths)} {actor}")
    if unattributed:
        print(f"{len(unattributed)} (unattributed)")
    return 0


def cmd_check(weave_dir: str, today: date) -> int:
    """Refuse (1) on any undeclared writer; warn on stale clones; 2 on a bad roster."""
    try:
        clones = read_roster(weave_dir)
    except (RosterError, OSError, UnicodeDecodeError) as exc:
        print(f"wv: clone roster unreadable, nothing judged: {exc}", file=sys.stderr)
        return 2
    for clone in clones:
        age = (today - clone.confirmed).days
        if age >= STALE_DAYS:
            print(f"wv: warning: clone '{clone.name}' last confirmed {clone.confirmed} "
                  f"({age} days); confirm it or remove its roster file", file=sys.stderr)
    actors, unattributed = catalog_actors(weave_dir)
    refused = 0
    for actor in sorted(actors):
        if not any(accounts_for(c, actor) for c in clones):
            paths = actors[actor]
            print(f"unaccounted {actor} {len(paths)} {paths[0]}")
            refused += 1
    for path in unattributed:
        print(f"unattributed {path}")
        refused += 1
    return 1 if refused else 0


def cmd_watermark(weave_dir: str) -> int:
    """Print the lowest watermark (0); 1 when a clone lacks one or none is rostered."""
    try:
        clones = read_roster(weave_dir)
    except (RosterError, OSError, UnicodeDecodeError) as exc:
        print(f"wv: clone roster unreadable, nothing judged: {exc}", file=sys.stderr)
        return 2
    if not clones:
        print("wv: no clone is rostered under .weave/clones; nothing may compact", file=sys.stderr)
        return 1
    missing = [c.name for c in clones if c.watermark is None]
    for name in missing:
        print(f"unwatermarked {name}")
    if missing:
        return 1
    print(min(c.watermark for c in clones if c.watermark is not None))
    return 0


def main(argv: list[str]) -> int:
    """Dispatch the subcommands documented in the module docstring."""
    if len(argv) >= 2 and argv[0] == "actors":
        return cmd_actors(argv[1])
    if len(argv) == 2 and argv[0] == "watermark":
        return cmd_watermark(argv[1])
    if len(argv) >= 2 and argv[0] == "check":
        today = date.today()
        for arg in argv[2:]:
            if arg.startswith("--today="):
                try:
                    today = date.fromisoformat(arg.split("=", 1)[1])
                except ValueError:
                    print(f"wv: bad --today '{arg}'", file=sys.stderr)
                    return 2
            else:
                print(f"wv: unknown argument '{arg}'", file=sys.stderr)
                return 2
        return cmd_check(argv[1], today)
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
