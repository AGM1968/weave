"""Data fetching — Weave nodes, GitHub issues, and edges."""

from __future__ import annotations

import hashlib
import json
import os
import re
import stat
import subprocess
import sys
from pathlib import Path
from typing import Any

from weave_gh.cli import _run, gh_cli, wv_cli
from weave_gh.models import (
    NODE_ID_RE,
    NODE_STATUSES,
    Edge,
    GitHubIssue,
    WeaveNode,
    parse_gh_issue,
)


def get_repo() -> str:
    """Get the GitHub repo name (owner/repo)."""
    return gh_cli("repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner")


def get_repo_url() -> str:
    """Get the GitHub repo URL for commit links."""
    return gh_cli("repo", "view", "--json", "url", "-q", ".url", check=False) or ""


class NodeFetchError(RuntimeError):
    """``wv list`` failed, so the node list cannot be trusted as complete.

    An empty list stands for an empty graph: Phase 2 would then create a Weave
    node for every open issue (wv-0d2d25). An empty graph prints ``[]``.
    """


def get_weave_nodes() -> list[WeaveNode]:
    """Fetch all Weave nodes; raises :class:`NodeFetchError` on failure."""
    try:
        raw = wv_cli("list", "--all", "--json-v2")
        data = json.loads(raw)
    except (subprocess.CalledProcessError, OSError) as e:
        raise NodeFetchError(f"wv list failed: {e}") from e
    except json.JSONDecodeError as e:
        raise NodeFetchError(f"could not parse wv list output: {e}") from e
    if not isinstance(data, list):
        raise NodeFetchError("wv list did not return a JSON array")

    nodes = []
    for index, item in enumerate(data):
        try:
            nodes.append(_parse_node_row(item))
        except ValueError as e:
            raise NodeFetchError(f"wv list row {index} is malformed: {e}") from e
    ids = [n.id for n in nodes]
    if len(set(ids)) != len(ids):
        raise NodeFetchError(
            f"wv list repeated {len(ids) - len(set(ids))} node id(s)"
        )
    return nodes


def _require_str(row: dict[str, Any], key: str, *, optional: bool = False) -> str | None:
    """Return ``row[key]`` if it is a string; ValueError otherwise.

    With ``optional``, a missing key or null reads as None.
    """
    value = row.get(key)
    if value is None and optional:
        return None
    if not isinstance(value, str):
        raise ValueError(f"{key!r} is {type(value).__name__}, expected str")
    return value


def _parse_node_row(item: Any) -> WeaveNode:
    """Convert one ``wv list --json-v2`` row, raising ValueError on any schema
    or contract fault (wv-1d88c3, wv-e869e3). Metadata is checked too: a node
    whose metadata failed to parse used to sync with ``{}``, which drops its
    gh_issue mapping, and a malformed gh_issue was coerced (``true`` is #1) or
    raised an untyped error after GitHub writes had begun."""
    if not isinstance(item, dict):
        raise ValueError(f"row is {type(item).__name__}, expected object")
    node_id = _require_str(item, "id") or ""
    if not NODE_ID_RE.fullmatch(node_id):
        raise ValueError(f"'id' is {node_id!r}, expected wv-<4-6 hex>")
    status = _require_str(item, "status")
    if status not in NODE_STATUSES:
        raise ValueError(f"{node_id} has status {status!r}, expected one of {NODE_STATUSES}")
    meta_raw = item.get("metadata")
    if meta_raw is None or meta_raw == "":
        meta: dict[str, Any] = {}
    elif isinstance(meta_raw, dict):
        meta = meta_raw
    elif isinstance(meta_raw, str):
        try:
            meta = json.loads(meta_raw)
        except json.JSONDecodeError as e:
            raise ValueError(f"metadata of {node_id} is not JSON: {e}") from e
        if not isinstance(meta, dict):
            raise ValueError(f"metadata of {node_id} is not a JSON object")
    else:
        raise ValueError(f"metadata of {node_id} is {type(meta_raw).__name__}")
    try:
        gh_issue = parse_gh_issue(meta.get("gh_issue"))
    except ValueError as e:
        raise ValueError(f"{node_id}: {e}") from e
    if gh_issue is not None:
        meta = {**meta, "gh_issue": gh_issue}
    return WeaveNode(
        id=node_id,
        text=_require_str(item, "text") or "",
        status=status,
        metadata=meta,
        alias=_require_str(item, "alias", optional=True) or None,
    )


# Room for issues created between the count query and the list fetch. A fetch
# that fills the limit is treated as truncated, never as complete.
_GH_ISSUE_HEADROOM = 500

_ISSUE_COUNT_QUERY = (
    "query($owner: String!, $name: String!) "
    "{ repository(owner: $owner, name: $name) { issues { totalCount } } }"
)


class IssueFetchError(RuntimeError):
    """The issue list could not be proven complete.

    Every sync phase treats an issue missing from the list as one that does not
    exist: a node whose issue was dropped gets a duplicate created, and fast
    sync's done-node drift selection loses open issues (wv-0d2d25). So an
    incomplete list must stop the sync before any GitHub write.

    ``transport`` is True when a ``gh`` command failed to execute: it exited
    nonzero or could not start. That covers network, auth and sandbox faults,
    which ``wv sync --gh`` keeps non-fatal (wv-5a949b), but it is not proof of
    one: a malformed argument or API error is classified the same way. When
    False, ``gh`` succeeded and its answer failed an integrity or schema check,
    which ``wv sync --gh`` reports as a failure (wv-820b76, wv-1d88c3).
    """

    def __init__(self, message: str, *, transport: bool = False) -> None:
        super().__init__(message)
        self.transport = transport


def get_github_issue_count(repo: str) -> int:
    """Return the repository's total issue count (open + closed, no PRs)."""
    owner, _, name = repo.partition("/")
    try:
        raw = gh_cli(
            "api",
            "graphql",
            "-f",
            f"query={_ISSUE_COUNT_QUERY}",
            "-F",
            f"owner={owner}",
            "-F",
            f"name={name}",
            "--jq",
            ".data.repository.issues.totalCount",
        )
    except (subprocess.CalledProcessError, OSError) as e:
        raise IssueFetchError(
            f"could not count issues in {repo}: {e}", transport=True
        ) from e
    try:
        count = int(raw)
    except ValueError as e:
        raise IssueFetchError(f"issue count for {repo} is not a number: {raw!r}") from e
    if count < 0:
        # A negative count lets an empty listing pass the completeness check,
        # which is the duplicate-creation hazard of wv-0d2d25 (wv-e869e3).
        raise IssueFetchError(f"issue count for {repo} is negative: {count}")
    return count


def get_github_issues(repo: str) -> list[GitHubIssue]:
    """Fetch all GitHub issues (open + closed).

    Completeness is checked against an independent count, read before AND
    after the listing: raises :class:`IssueFetchError` when a count or the
    list fails, when a row fails the schema or repeats a number, when the list
    holds fewer distinct issues than either count, or when it fills the fetch
    limit. Length alone is not enough: ``[#2, #2]`` against a count of 2 hides
    a missing #1. One count is not enough either: count 2, then #3 is created,
    then ``[#3, #2]`` matches the stale count with #1 missing (wv-1d88c3).

    This proves cardinality, not membership: an issue leaving the repository
    while another arrives keeps both counts and can drop a listed issue. The
    sync looks up each node-mapped issue the list lacks with
    :func:`confirm_mapped_issues_absent` before writing (wv-e869e3).
    """
    total = get_github_issue_count(repo)
    limit = total + _GH_ISSUE_HEADROOM
    try:
        raw = gh_cli(
            "issue",
            "list",
            "--repo",
            repo,
            "--state",
            "all",
            "--limit",
            str(limit),
            "--json",
            "number,title,state,body,labels,assignees",
        )
        data: list[object] = json.loads(raw) if raw else []
    except (subprocess.CalledProcessError, OSError) as e:
        raise IssueFetchError(
            f"gh issue list failed for {repo}: {e}", transport=True
        ) from e
    except json.JSONDecodeError as e:
        raise IssueFetchError(f"could not parse gh issue list output: {e}") from e
    if not isinstance(data, list):
        raise IssueFetchError("gh issue list did not return a JSON array")
    issues: list[GitHubIssue] = []
    for index, row in enumerate(data):
        try:
            issues.append(_parse_issue_row(row))
        except ValueError as e:
            raise IssueFetchError(
                f"gh issue list row {index} is malformed: {e}"
            ) from e
    distinct = len({i.number for i in issues})
    if distinct != len(issues):
        raise IssueFetchError(
            f"gh issue list repeated {len(issues) - distinct} issue number(s) in {repo}"
        )
    if len(issues) >= limit:
        raise IssueFetchError(
            f"fetched {len(issues)} issues, filling the limit of {limit}; "
            "the list may be truncated"
        )
    total_after = get_github_issue_count(repo)
    if distinct < max(total, total_after):
        raise IssueFetchError(
            f"fetched {distinct} distinct issues in {repo}, but it counted {total} "
            f"before listing and {total_after} after; the list is incomplete"
        )
    return issues


_NOT_FOUND = "could not resolve to an issue"


def confirm_mapped_issues_absent(
    repo: str, nodes: list[WeaveNode], issues: list[GitHubIssue]
) -> None:
    """Look up each node-mapped issue the listing omitted.

    :func:`get_github_issues` proves the listing holds as many distinct issues
    as the repository counted, which is cardinality, not membership: an issue
    leaving the repository while another arrives keeps the count and can drop a
    mapped issue from the list. Phase 1 would then create a replacement. So a
    mapped number missing from the list is looked up, and raises
    :class:`IssueFetchError` if it is an issue in ``repo``. One reported
    missing, or one that is now a pull request or lives in another repository
    (transferred), is absent as before. Unmapped issues get no such check: an
    unmapped issue the list lacks is not imported by Phase 2 this run
    (wv-e869e3). Live syncs have no mapped issue missing, so this costs nothing
    on the normal path.
    """
    listed = {i.number for i in issues}
    missing = sorted({n.gh_issue for n in nodes if n.gh_issue is not None} - listed)
    for number in missing:
        result = _run(
            ["gh", "issue", "view", str(number), "--repo", repo, "--json", "url"],
            check=False,
        )
        if result.returncode != 0:
            if _NOT_FOUND in result.stderr.lower():
                continue
            raise IssueFetchError(
                f"could not look up mapped issue #{number} in {repo}: "
                f"{result.stderr.strip()}",
                transport=True,
            )
        try:
            url = json.loads(result.stdout)["url"]
        except (json.JSONDecodeError, KeyError, TypeError) as e:
            raise IssueFetchError(
                f"gh issue view #{number} returned no url: {result.stdout!r}"
            ) from e
        if isinstance(url, str) and url.lower().endswith(f"/{repo.lower()}/issues/{number}"):
            mappers = sorted(n.id for n in nodes if n.gh_issue == number)
            raise IssueFetchError(
                f"#{number} (mapped by {', '.join(mappers)}) exists in {repo} but "
                "the issue list omitted it; the list is not the repository's issue set"
            )


_ISSUE_STATES = ("OPEN", "CLOSED")


def _parse_issue_row(row: Any) -> GitHubIssue:
    """Convert one ``gh issue list --json`` row, raising ValueError on any
    schema fault (wv-1d88c3)."""
    if not isinstance(row, dict):
        raise ValueError(f"row is {type(row).__name__}, expected object")
    number = row.get("number")
    if not isinstance(number, int) or isinstance(number, bool):
        raise ValueError(f"'number' is {type(number).__name__}, expected int")
    if number < 1:
        raise ValueError(f"'number' is {number}, expected a positive int")
    state = _require_str(row, "state")
    if state not in _ISSUE_STATES:
        raise ValueError(f"#{number} has state {state!r}, expected one of {_ISSUE_STATES}")
    return GitHubIssue(
        number=number,
        title=_require_str(row, "title") or "",
        state=state,
        body=_require_str(row, "body", optional=True) or "",
        labels=_names(row, "labels", "name", number),
        assignees=_names(row, "assignees", "login", number),
    )


def _names(row: dict[str, Any], key: str, field: str, number: int) -> list[str]:
    """Extract ``row[key][*][field]``, which must be a list of objects each
    carrying a string ``field``."""
    entries = row.get(key)
    if not isinstance(entries, list):
        raise ValueError(f"#{number} {key!r} is {type(entries).__name__}, expected list")
    names = []
    for entry in entries:
        if not isinstance(entry, dict) or not isinstance(entry.get(field), str):
            raise ValueError(f"#{number} has a {key} entry without a string {field!r}")
        names.append(entry[field])
    return names


def _repo_hash() -> str:
    """Get the 8-char hash of the current repo root for per-repo DB namespace.

    Must match bash: echo "$REPO_ROOT" | md5sum | cut -c1-8
    Note: echo appends a newline, so we hash "path\\n" not "path".
    """
    try:
        repo_root = subprocess.check_output(
            ["git", "rev-parse", "--show-toplevel"],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return ""
    # echo adds trailing newline — match bash behavior exactly.
    # MD5 here is a filesystem namespace, not a security primitive.
    return hashlib.md5(  # noqa: S324
        (repo_root + "\n").encode(), usedforsecurity=False
    ).hexdigest()[:8]


class HotZoneConflictError(RuntimeError):
    """More than one hot zone holds a database for this repository.

    Mirrors resolve_hot_zone in scripts/lib/wv-resolve-runtime.sh, which makes
    wv refuse to run rather than pick one (wv-b831e3).
    """


def _hot_zone_root() -> str:
    """The WV_TEST_HOT_ZONE_ROOT prefix bash's _hot_zone_tmp_names applies."""
    test_root = os.environ.get("WV_TEST_HOT_ZONE_ROOT", "")
    if os.environ.get("WV_TEST_MODE") == "1" and test_root.startswith("/"):
        return test_root.rstrip("/")
    return ""


def _tmp_zone_names(uid: int) -> tuple[str, str]:
    """The /tmp zone's neutral and legacy names (wv-95bddf).

    Until every host runs a version that knows the neutral name, the legacy
    directory stays the physical one and the neutral name is at most a
    symlink to it. See _hot_zone_tmp_names in wv-resolve-runtime.sh.
    """
    root = _hot_zone_root()
    return f"{root}/tmp/weave-hotzone-{uid}", f"{root}/tmp/weave-codex-{uid}"


def _zone_populated(zone: str) -> bool:
    """True when ``zone`` holds a non-empty */brain.db, as bash's
    _hot_zone_populated tests."""
    try:
        entries = os.listdir(zone)
    except OSError:
        return False
    return any(_nonempty_file(f"{zone}/{e}/brain.db") for e in entries if not e.startswith("."))


def _zone_inventory(zone: str, other: str = "") -> list[str]:
    """Each populated */brain.db directory in ``zone`` with the repository
    its .repo_root names, as bash's _hot_zone_inventory lists them, marked
    when ``other`` holds a copy of the same repository (wv-a73141)."""
    try:
        entries = sorted(os.listdir(zone))
    except OSError:
        return []
    found = []
    for e in entries:
        d = f"{zone}/{e}"
        if e.startswith(".") or not _nonempty_file(f"{d}/brain.db"):
            continue
        try:
            owner = Path(d, ".repo_root").read_text(encoding="utf-8").strip()
        except OSError:
            owner = ""
        mark = (" [IN BOTH ZONES: reconcile, step 3]"
                if other and _nonempty_file(f"{other}/{e}/brain.db") else "")
        found.append(f"{d} ({owner or 'repository unknown'}){mark}")
    return found


def _linux_hot_zones(uid: int) -> tuple[list[str], bool]:
    """The /tmp zone, then the adopt-only legacy zones, as bash's
    _hot_zone_linux_zones lists them (WV_TEST_HOT_ZONE_ROOT included), and
    whether the /tmp zone's two names are separate directories that both
    hold databases (wv-95bddf)."""
    neutral, legacy = _tmp_zone_names(uid)
    conflict = False
    if os.path.islink(neutral):
        zones = [neutral]
    elif os.path.lexists(neutral):
        if os.path.isdir(legacy) and not os.path.islink(legacy):
            if not _zone_populated(neutral):
                # The legacy directory stays the authority (wv-6f2eed).
                zones = [legacy, neutral]
            else:
                zones = [neutral, legacy]
                conflict = _zone_populated(legacy)
        else:
            zones = [neutral]
    elif os.path.lexists(legacy):
        zones = [legacy]
    else:
        zones = [neutral]
    root = _hot_zone_root()
    return zones + [f"{root}/dev/shm/weave", f"{root}/tmp/weave-{uid}"], conflict


def _runtime_hot_zone_base(uid: int | None, rhash: str) -> str:
    """The hot-zone base for this repository, as bash's resolve_hot_zone
    chooses it (owner ruling 2026-10-06, wv-b831e3).

    On Linux the zone already holding a non-empty brain.db for the repository
    wins, whichever it is; with none, the /tmp zone, for every process. An
    agent marker no longer decides, so start order cannot split the graph.
    Raises :class:`HotZoneConflictError` when more than one zone holds one.
    """
    if uid is None:
        return "/tmp/weave"
    if sys.platform == "darwin":
        return f"{os.environ.get('TMPDIR', '/tmp')}/weave-{uid}"
    zones, tmp_conflict = _linux_hot_zones(uid)
    if not rhash:
        return zones[0]
    if tmp_conflict:
        neutral, legacy = _tmp_zone_names(uid)
        found = ", ".join(_zone_inventory(neutral, legacy) + _zone_inventory(legacy, neutral))
        raise HotZoneConflictError(
            f"refusing to choose a hot zone: {neutral} and {legacy} are "
            "separate directories and both hold databases; until a relocation "
            f"the neutral name may only be a symlink to the legacy directory "
            f"(wv-95bddf). Databases found: {found}. Remove nothing yet: "
            "(1) stop every wv process; (2) back up every database listed, "
            "outside both zones, with sqlite3 <brain.db> \".backup '<file>'\" "
            "(never cp); (3) a repository in both zones has two copies that may "
            "have diverged, and syncing both does not merge them (wv-a73141): "
            "run wv hotzone diff <legacy copy> <neutral copy> and carry every "
            "change the legacy copy lacks into it with WV_HOT_ZONE=<legacy hash "
            "dir> wv ..., rerunning it until every difference left is one you "
            "chose to drop; (4) in each repository listed run WV_HOT_ZONE=<its "
            "hash dir, the legacy one if in both> wv sync; "
            f"(5) only then remove {neutral}"
        )
    holders = [z for z in zones if _nonempty_file(f"{z}/{rhash}/brain.db")]
    if len(holders) > 1:
        found = ", ".join(f"{z}/{rhash}/brain.db" for z in holders)
        raise HotZoneConflictError(
            f"refusing to choose a database: this repository has one in more "
            f"than one hot zone ({found}) (wv-b831e3). Remove nothing yet: the "
            "copies may have diverged, and syncing both does not merge them "
            "(wv-a73141): (1) stop every wv process; (2) back up each with "
            "sqlite3 <brain.db> \".backup '<file>'\" (never cp); (3) run wv "
            "hotzone diff <copy you keep> <other copy> and carry every change "
            f"the kept copy lacks into it with WV_HOT_ZONE=<zone>/{rhash} wv ..., "
            "rerunning it until every difference left is one you chose to drop; "
            f"(4) WV_HOT_ZONE=<zone of the kept copy>/{rhash} wv sync, then "
            "remove the other"
        )
    return holders[0] if holders else zones[0]


def _nonempty_file(path: str) -> bool:
    """True for a regular file with content, as bash's ``[ -s ]`` tests: an
    empty brain.db is what sqlite3 leaves after opening a guessed path."""
    try:
        return os.stat(path).st_size > 0
    except OSError:
        return False


class HotZoneUnsafeError(RuntimeError):
    """The hot zone sits in a base directory another local user could control.

    Mirrors hot_zone_check in scripts/lib/wv-resolve-runtime.sh (wv-80be32):
    every shared-parent base must be a real directory owned by this uid with no
    group or other write, or the one exact alias a rename migration allows.
    """


def _hot_zone_bases(uid: int | None) -> list[str]:
    """Shared-parent bases a hot zone can live in. Bash's list, plus the
    pre-v1.2 /tmp/weave and the uid-less names that only Python still probes.
    As in bash, WV_TEST_HOT_ZONE_BASE adds one under WV_TEST_MODE=1."""
    bases = ["/dev/shm/weave", "/tmp/weave", "/tmp/weave-codex"]
    if uid is not None:
        bases += [f"/tmp/weave-hotzone-{uid}", f"/tmp/weave-codex-{uid}", f"/tmp/weave-{uid}"]
        if sys.platform == "darwin":
            bases.append(f"{os.environ.get('TMPDIR', '/tmp')}/weave-{uid}")
    if uid is not None and os.environ.get("WV_TEST_HOT_ZONE_ROOT"):
        root = _hot_zone_root()
        bases += [*_tmp_zone_names(uid), f"{root}/dev/shm/weave", f"{root}/tmp/weave-{uid}"]
    test_base = os.environ.get("WV_TEST_HOT_ZONE_BASE", "")
    if os.environ.get("WV_TEST_MODE") == "1" and test_base.startswith("/"):
        bases.append(test_base)
    return [b.rstrip("/") for b in bases]


def _hot_zone_guarded_base(path: str, uid: int | None) -> str | None:
    """The guarded base ``path`` is or lies under; None for a directory the
    caller chose elsewhere."""
    path = path.rstrip("/")
    for base in _hot_zone_bases(uid):
        if path == base or path.startswith(base + "/"):
            return base
    return None


def _hot_zone_dir_problem(
    path: str, uid: int, alias_target: str | None = None
) -> str | None:
    """Why ``path`` may not be a hot-zone base, or None when it may (an absent
    path may). Never follows a link: a symlink passes only as the exact,
    uid-owned alias of a target that itself passes (wv-80be32)."""
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return None
    except OSError as e:
        return f"could not be inspected ({e.strerror})"
    if stat.S_ISLNK(st.st_mode):
        if alias_target is None:
            return "is a symlink"
        return _hot_zone_alias_problem(path, st, uid, alias_target)
    if not stat.S_ISDIR(st.st_mode):
        return "is not a directory"
    if st.st_uid != uid:
        return f"is owned by uid {st.st_uid}, not {uid}"
    if st.st_mode & 0o022:
        return f"is writable by group or others (mode {stat.S_IMODE(st.st_mode):o})"
    return None


def _hot_zone_alias_problem(
    path: str, link_st: os.stat_result, uid: int, alias_target: str
) -> str | None:
    """Why the symlink ``path`` is not the allowed alias of ``alias_target``."""
    if link_st.st_uid != uid:
        return f"is a symlink owned by uid {link_st.st_uid}, not {uid}"
    target = os.readlink(path)
    if target != alias_target:
        return f"is a symlink to {target}, not {alias_target}"
    try:
        target_st: os.stat_result | None = os.lstat(alias_target)
    except FileNotFoundError:
        # As bash: an absent target is for hot_zone_ensure to create.
        return None
    except OSError:
        target_st = None
    if target_st is None or not stat.S_ISDIR(target_st.st_mode):
        return f"is a symlink to {alias_target}, which is not a real directory"
    problem = _hot_zone_dir_problem(alias_target, uid)
    return f"is a symlink to {alias_target}, which {problem}" if problem else None


def _hot_zone_alias_target(base: str, uid: int) -> str | None:
    """The legacy directory when ``base`` is the neutral name: the one target
    it may be a symlink to (bash's _hot_zone_pair, wv-95bddf)."""
    for neutral, legacy in (_tmp_zone_names(uid), (f"/tmp/weave-hotzone-{uid}", f"/tmp/weave-codex-{uid}")):
        if base == neutral:
            return legacy
    return None


def _check_hot_zone(db_path: str, uid: int | None) -> None:
    """Raise :class:`HotZoneUnsafeError` when ``db_path``'s hot zone has a
    guarded base that fails :func:`_hot_zone_dir_problem`."""
    if uid is None:
        return
    base = _hot_zone_guarded_base(os.path.dirname(db_path), uid)
    if base is None:
        return
    problem = _hot_zone_dir_problem(base, uid, _hot_zone_alias_target(base, uid))
    if problem:
        raise HotZoneUnsafeError(
            f"refusing to use hot-zone base {base}: it {problem}; another local "
            "user who controls it could swap this repository's graph (wv-80be32)"
        )


def _resolve_db_path() -> str:
    """Resolve the Weave DB path, refusing one in an unsafe base."""
    uid = os.getuid() if hasattr(os, "getuid") else None
    db = _resolve_db_candidate(uid)
    _check_hot_zone(db, uid)
    return db


def _resolve_db_candidate(uid: int | None) -> str:
    """The DB path bash's resolve_db gives: WV_DB, else WV_HOT_ZONE/brain.db,
    else this repository's placement (:func:`_runtime_hot_zone_base`). There
    is no fallthrough to other candidates: a second path is a second graph."""
    db = os.environ.get("WV_DB", "")
    if db:
        return db
    hot_zone = os.environ.get("WV_HOT_ZONE", "")
    if hot_zone:
        return str(Path(hot_zone) / "brain.db")
    rhash = _repo_hash()
    base = _runtime_hot_zone_base(uid, rhash)
    return f"{base}/{rhash}/brain.db" if rhash else f"{base}/brain.db"


def get_edges_for_node(node_id: str) -> list[Edge]:
    """Get all edges involving a node (via direct DB query for speed)."""
    db = _resolve_db_path()
    if not Path(db).exists():
        return []
    if not _is_valid_node_id(node_id):
        return []
    try:
        result = _run(
            [
                "sqlite3",
                "-json",
                db,
                f"SELECT source, target, type, weight FROM edges "
                f"WHERE source='{node_id}' OR target='{node_id}';",
            ],
            check=False,
        )
        if not result.stdout.strip():
            return []
        data = json.loads(result.stdout)
        return [
            Edge(
                source=e["source"],
                target=e["target"],
                edge_type=e["type"],
                weight=float(e.get("weight", 1.0)),
            )
            for e in data
        ]
    except (json.JSONDecodeError, KeyError):
        return []


def get_edges_for_nodes(node_ids: list[str]) -> list[Edge]:
    """Get all edges involving any of the given nodes (batch query for Mermaid)."""
    if not node_ids:
        return []
    db = _resolve_db_path()
    if not Path(db).exists():
        return []
    # Build IN clause with properly quoted IDs (safe: IDs are wv-xxxxxx hex format)
    quoted = ",".join(f"'{nid}'" for nid in node_ids if _is_valid_node_id(nid))
    if not quoted:
        return []
    try:
        result = _run(
            [
                "sqlite3",
                "-json",
                db,
                f"SELECT source, target, type, weight FROM edges "
                f"WHERE source IN ({quoted}) OR target IN ({quoted});",
            ],
            check=False,
        )
        if not result.stdout.strip():
            return []
        data = json.loads(result.stdout)
        return [
            Edge(
                source=e["source"],
                target=e["target"],
                edge_type=e["type"],
                weight=float(e.get("weight", 1.0)),
            )
            for e in data
        ]
    except (json.JSONDecodeError, KeyError):
        return []


def _is_valid_node_id(node_id: str) -> bool:
    """Validate node ID format (wv-xxxxxx+) to prevent SQL injection."""
    return bool(re.match(r"^wv-[a-f0-9]{4,64}$", node_id))


def get_children(node_id: str, all_edges: list[Edge] | None = None) -> list[str]:
    """Get child node IDs (nodes that implement this node)."""
    edges = all_edges or get_edges_for_node(node_id)
    return [
        e.source for e in edges if e.target == node_id and e.edge_type == "implements"
    ]


def get_blockers(node_id: str, all_edges: list[Edge] | None = None) -> list[str]:
    """Get blocker node IDs (nodes that block this node)."""
    edges = all_edges or get_edges_for_node(node_id)
    return [e.source for e in edges if e.target == node_id and e.edge_type == "blocks"]


def get_parent(node_id: str, all_edges: list[Edge] | None = None) -> str | None:
    """Get parent node ID (target of 'implements' edge from this node)."""
    edges = all_edges or get_edges_for_node(node_id)
    for e in edges:
        if e.source == node_id and e.edge_type == "implements":
            return e.target
    return None


def compute_impacted_node_ids(
    focus_id: str,
    *,
    all_edges: list[Edge] | None = None,
) -> set[str]:
    """Return the set of node IDs whose rendered GH body may depend on focus_id.

    The fast-path candidate selector uses this to bound Phase 1 to:

    - the focus node itself,
    - its direct parent (checklist + Mermaid),
    - its direct children (status rolls up into focus body),
    - blockers that point at the focus and blockers the focus points at
      (both directions affect the rendered "Blocked by" / "Blocks" lines).

    Sibling nodes are excluded — the parent re-render pulls their statuses
    via its own edge lookup, so we do not need to touch them individually.
    """
    edges = all_edges if all_edges is not None else get_edges_for_node(focus_id)
    impacted: set[str] = {focus_id}
    for e in edges:
        if e.edge_type == "implements":
            if e.source == focus_id:
                impacted.add(e.target)  # parent
            elif e.target == focus_id:
                impacted.add(e.source)  # child
        elif e.edge_type == "blocks":
            if focus_id in (e.source, e.target):
                impacted.add(e.source)
                impacted.add(e.target)
    return impacted
