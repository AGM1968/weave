"""Build a promotion input from durable adjudication state and a current scan.

This is the compatibility evidence adapter, and the ONLY coaching module allowed
to open `quality.db`. Everything downstream -- the planner, the view -- receives
values and cannot reach back here. That boundary is what lets an offline Rust
shadow replay the same cases: if planning needed a database, replaying it would
need one too.

Two tables answer two different questions, and conflating them is the mistake
this module exists to avoid:

* `pattern_finding_state` is durable. It holds the identity, the human
  disposition, and the recurrence count, and it survives pruning. It has no line
  and no column.
* `pattern_findings` is point-in-time. It holds the line and column of the
  latest runs and is pruned on the pattern window.

So an accepted defect is authoritative even when the current scan no longer
shows it -- and that is precisely the case that must NOT promote by default. An
accepted row with no observation in the current complete scan is classified
`not_current` and left for separate historical review, rather than promoted from
evidence nobody can currently see.
"""

from __future__ import annotations

import hashlib
import json
import re
import sqlite3
import subprocess
from pathlib import Path
from typing import Any

from . import guides
# The CLI's own definition of which rules are active, shared rather than
# re-derived: deriving it separately would let this adapter and the scan that
# produced the receipts disagree about the rule set they are discussing.
from .pattern_loader import _disabled_patterns, _load_pattern_rules
from .db import (
    db_path,
    init_db,
    latest_pattern_run,
    pattern_finding_states,
    pattern_rule_runs,
)

INPUT_FORMAT = "weave.coaching-promotion-input.v1"
CATALOG_VERSION = "weave.violation-vocabulary.v1"
ACCEPTED = "accepted_defect"
PACKAGE_MANIFEST_FORMAT = "weave.quality-default-patterns-manifest.v1"


class EvidenceError(Exception):
    """Evidence could not be gathered at all (no database, no scan)."""

    def __init__(self, message: str, code: str) -> None:
        super().__init__(message)
        self.code = code


_VIOLATION_TYPE_DECLARATION = re.compile(r"^violation_type:\s*(\S+)\s*$")


def _declared_violation_type(rule_path: Path) -> str | None:
    """Read one rule's top-level `violation_type:` declaration, if it has one.

    Read by line rather than through `prose_rules.parse_flat_rule`, which
    handles only the flat YAML subset prose rules use and raises on the nested
    `rule:` block every ast-grep rule has. Routing code rules through it left
    them all silently unmapped, which looked exactly like "no rule declares a
    type yet" -- so the whole promotion path produced zero candidates and no
    error.

    Column zero is the guard: block-scalar content is indented by definition, so
    a match at the start of a line cannot be text quoted inside another value.
    """
    try:
        text = rule_path.read_text(encoding="utf-8")
    except OSError:
        # A rule that cannot be read is the scan's problem, not ours: it becomes
        # a failed receipt and therefore an incomplete snapshot, which blocks
        # promotion on its own.
        return None
    for line in text.splitlines():
        match = _VIOLATION_TYPE_DECLARATION.match(line)
        if match:
            return match.group(1).strip("\"'")
    return None


def _rule_violation_types(rules: list[tuple[str, Path, str]]) -> dict[str, str]:
    """Read each active rule's declared `violation_type`.

    The mapping is rule-owned so a project-local rule works without editing a
    central file, and so changing the mapping stales that rule's receipt -- a
    semantic change to what the rule means -- while editing guide prose does
    not. A rule that declares nothing is simply absent here; the planner then
    rejects its observations by name rather than guessing a type for them.
    """
    mapping: dict[str, str] = {}
    for rule_id, rule_path, _language in rules:
        declared = _declared_violation_type(rule_path)
        if declared:
            mapping[rule_id] = declared
    return mapping


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _package_rule_manifest(default_dir: Path) -> tuple[dict[str, str], str]:
    """Load the shipped exact inventory that authorizes package default rules."""
    manifest_path = default_dir / "manifest.json"
    raw = manifest_path.read_bytes()
    value = json.loads(raw)
    if not isinstance(value, dict) or set(value) != {"format", "rules"}:
        raise ValueError("default pattern manifest must contain only format and rules")
    if value["format"] != PACKAGE_MANIFEST_FORMAT or not isinstance(value["rules"], dict):
        raise ValueError(f"default pattern manifest must use {PACKAGE_MANIFEST_FORMAT}")
    rules = value["rules"]
    on_disk = {path.name for path in default_dir.glob("*.yaml")}
    if set(rules) != on_disk:
        raise ValueError("default pattern manifest is not the exact .yaml inventory")
    for name, digest in rules.items():
        if Path(name).name != name or not name.endswith(".yaml"):
            raise ValueError(f"unsafe default pattern manifest entry {name!r}")
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise ValueError(f"invalid default pattern digest for {name!r}")
        if _sha256((default_dir / name).read_bytes()) != digest:
            raise ValueError(f"default pattern {name!r} differs from its manifest digest")
    return dict(rules), _sha256(raw)


def _head_blob(repo: Path, relative_path: str) -> tuple[str, bytes]:
    """Return target HEAD and one regular tracked blob, failing otherwise."""
    revision = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=repo, capture_output=True, text=True, check=False
    )
    if revision.returncode:
        raise ValueError("target repository has no HEAD commit")
    entry = subprocess.run(
        ["git", "ls-tree", "HEAD", "--", relative_path],
        cwd=repo,
        capture_output=True,
        text=True,
        check=False,
    )
    fields = entry.stdout.strip().split(None, 3)
    if entry.returncode or len(fields) != 4 or fields[1] != "blob" or fields[0] not in {"100644", "100755"}:
        raise ValueError(f"{relative_path} is not a regular tracked blob in target HEAD")
    blob = subprocess.run(
        ["git", "show", f"HEAD:{relative_path}"], cwd=repo, capture_output=True, check=False
    )
    if blob.returncode:
        raise ValueError(f"could not read target HEAD blob {relative_path}")
    return revision.stdout.strip(), blob.stdout


def rule_definition_bindings(
    repo: Path,
    rules: list[tuple[str, Path, str]],
) -> tuple[dict[str, str], dict[str, dict[str, Any]], list[dict[str, str]]]:
    """Bind active rules to package authority or reconstructible target HEAD.

    Scan receipts still record the bytes actually executed. Promotion may trust
    those receipts only when the same bytes are authorized here: package
    defaults by the shipped exact manifest, target rules by a regular HEAD blob.
    """
    current_hashes: dict[str, str] = {}
    bindings: dict[str, dict[str, Any]] = {}
    causes: list[dict[str, str]] = []
    default_dir = Path(__file__).parent / "default_patterns"
    try:
        package_rules, manifest_sha = _package_rule_manifest(default_dir)
        package_error = None
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        package_rules, manifest_sha, package_error = {}, "", str(exc)

    for rule_id, rule_path, _language in rules:
        package_rule = rule_path.parent == default_dir
        try:
            data = rule_path.read_bytes()
        except OSError as exc:
            reason = (
                "package_rule_not_manifest_bound" if package_rule else "repo_rule_not_at_head"
            )
            causes.append({"reason": reason, "rule_id": rule_id,
                           "detail": f"rule is unreadable: {exc}"})
            continue
        digest = _sha256(data)
        current_hashes[rule_id] = digest
        if package_rule:
            expected = package_rules.get(rule_path.name)
            if package_error or expected != digest:
                detail = package_error or f"{rule_path.name} differs from the shipped package manifest"
                causes.append({"reason": "package_rule_not_manifest_bound", "rule_id": rule_id,
                               "detail": detail})
                continue
            bindings[rule_id] = {
                "authority": "package_manifest",
                "asset": f"default_patterns/{rule_path.name}",
                "definition_sha256": digest,
                "manifest_sha256": manifest_sha,
                "reconstructible_from_commit": False,
            }
            continue
        try:
            relative = rule_path.relative_to(repo).as_posix()
            revision, head_data = _head_blob(repo, relative)
        except (ValueError, OSError) as exc:
            causes.append({"reason": "repo_rule_not_at_head", "rule_id": rule_id,
                           "detail": str(exc)})
            continue
        head_digest = _sha256(head_data)
        if head_digest != digest:
            causes.append({"reason": "repo_rule_not_at_head", "rule_id": rule_id,
                           "detail": f"{relative} working-tree bytes differ from target HEAD"})
            continue
        bindings[rule_id] = {
            "authority": "target_head",
            "path": relative,
            "revision": revision,
            "definition_sha256": digest,
            "reconstructible_from_commit": True,
        }
    return current_hashes, bindings, causes


def snapshot_state(
    conn: sqlite3.Connection,
    run_id: int,
    current_hashes: dict[str, str],
    authority_causes: list[dict[str, str]] | None = None,
) -> dict[str, Any]:
    """Fail-closed completeness for the current scan.

    Every active rule must have a successful receipt whose definition hash still
    matches the rule on disk. Anything else is an incomplete snapshot with typed
    causes -- never a clean one.
    """
    receipts = {str(row["rule_id"]): row for row in pattern_rule_runs(conn, run_id)}
    causes: list[dict[str, str]] = list(authority_causes or [])
    for rule_id, definition_hash in sorted(current_hashes.items()):
        receipt = receipts.get(rule_id)
        if receipt is None:
            causes.append({"reason": "receipt_missing", "rule_id": rule_id,
                           "detail": "no receipt for this rule in the current run"})
        elif receipt["status"] != "success":
            causes.append({"reason": "receipt_failed", "rule_id": rule_id,
                           "detail": str(receipt["error"] or "rule execution failed")})
        elif receipt["definition_hash"] != definition_hash:
            causes.append({"reason": "definition_hash_stale", "rule_id": rule_id,
                           "detail": "receipt predates the current rule definition"})
    for rule_id in sorted(set(receipts) - set(current_hashes)):
        causes.append({"reason": "rule_not_active", "rule_id": rule_id,
                       "detail": "receipt exists for a rule that is no longer active"})
    if causes:
        return {"state": "incomplete", "causes": causes}
    return {"state": "complete"}


def _current_locations(conn: sqlite3.Connection, run_id: int) -> dict[str, dict[str, int]]:
    """finding_key -> the location the current run observed it at.

    Display data only. A key absent here has no current observation, which is
    what `not_current` means.
    """
    locations: dict[str, dict[str, int]] = {}
    for row in conn.execute(
        "SELECT finding_key, line, col FROM pattern_findings WHERE scan_id = ? "
        "AND finding_key IS NOT NULL ORDER BY id",
        (run_id,),
    ).fetchall():
        key = str(row["finding_key"])
        if key in locations:
            # The scanner's qf-* identity includes a per-rule occurrence
            # ordinal, so it cannot legitimately emit one key twice in a run.
            # The table predates that invariant and has no UNIQUE constraint;
            # imported or directly-written state can therefore violate it.
            # Never turn that corruption into an arbitrary first-row location.
            raise EvidenceError(
                f"current scan {run_id} contains duplicate finding_key {key}",
                "duplicate_current_finding_key",
            )
        location = {"scan_id": run_id, "line": int(row["line"])}
        if row["col"]:
            location["column"] = int(row["col"])
        locations[key] = location
    return locations


def _observation(state: dict[str, Any], location: dict[str, int] | None) -> dict[str, Any]:
    """One raw observation: the planner normalizes, this does not.

    Emitting an anchor here would move normalization into the provider and leave
    every frozen planner case proving nothing about the planner.
    """
    detector: dict[str, Any] = {
        "rule_id": str(state["rule_id"]),
        "finding_key": str(state["finding_key"]),
        "disposition": str(state["disposition"]),
        "scan_count": int(state["scan_count"]),
    }
    if state.get("content_key"):
        detector["content_key"] = str(state["content_key"])
    observation = {
        "path": str(state["path"]),
        "match_text": str(state["match_text"]),
        "context_text": str(state["context_text"]),
        "detector": detector,
    }
    if location is not None:
        observation["location"] = location
    return observation


def _not_current(state: dict[str, Any]) -> dict[str, Any]:
    """Raw accepted evidence the current complete scan no longer observes.

    This is not an observation and cannot promote. It still crosses the pure
    planner boundary as raw path/match/context so the planner, not this provider,
    derives the conceptual anchor used in its reviewable rejection.
    """
    observation = _observation(state, None)
    return {
        "reason": "not_current",
        **observation,
        "detail": (
            "accepted durable row has no observation in the current complete scan; "
            "needs separate historical review"
        ),
    }


def build_promotion_input(
    repo: Path,
    catalog: dict[str, Any],
    scope: dict[str, Any],
    hot_zone: str | None = None,
    language: str | None = None,
) -> dict[str, Any]:
    """Assemble the promotion input document for a reviewed scope."""
    if not db_path(hot_zone).exists():
        raise EvidenceError("no quality database; run: wv quality patterns scan", "no_database")

    conn = init_db(hot_zone)
    try:
        run = latest_pattern_run(conn)
        if run is None:
            raise EvidenceError(
                "no pattern scan recorded; run: wv quality patterns scan", "no_scan"
            )

        rules = _load_pattern_rules(repo, _disabled_patterns(repo / ".weave" / "quality.conf"))
        current_hashes, definition_bindings, authority_causes = rule_definition_bindings(repo, rules)
        snapshot = snapshot_state(conn, run.id, current_hashes, authority_causes)
        mapping = _rule_violation_types(rules)

        # Default the scope to every ACTIVE rule, not to the mapped ones.
        # Defaulting to `mapping` made a rule that fired, was accepted, and
        # declared no violation_type vanish here -- indistinguishable from a
        # rule that never matched. It now reaches the planner, which rejects it
        # by name so the missing declaration is visible rather than silent.
        rule_ids = set(scope.get("rule_ids") or {rule_id for rule_id, _, _ in rules})
        observations: list[dict[str, Any]] = []
        provider_rejections: list[dict[str, Any]] = []
        if snapshot["state"] == "complete":
            locations = _current_locations(conn, run.id)
            for state in pattern_finding_states(conn):
                if state.get("disposition") != ACCEPTED:
                    continue
                if str(state["rule_id"]) not in rule_ids:
                    continue
                location = locations.get(str(state["finding_key"]))
                if location is None:
                    # Preserve the refusal instead of silently dropping the
                    # durable accepted finding. It remains raw provider data;
                    # the pure planner derives its anchor and canonical shape.
                    provider_rejections.append(_not_current(state))
                    continue
                observations.append(_observation(state, location))
    finally:
        conn.close()

    violation_types = sorted({mapping[o["detector"]["rule_id"]]
                              for o in observations
                              if o["detector"]["rule_id"] in mapping})
    resolved = guides.resolve_all(violation_types, catalog, language, project_root=repo)

    return {
        "format": INPUT_FORMAT,
        "scope": {**scope, "rule_ids": sorted(rule_ids)},
        "catalog_version": CATALOG_VERSION,
        "catalog_violation_types": sorted(catalog["types"]),
        "snapshot": snapshot,
        "observations": observations,
        "provider_rejections": provider_rejections,
        "rule_definition_bindings": {
            key: definition_bindings[key]
            for key in sorted(rule_ids & set(definition_bindings))
        },
        "rule_violation_types": dict(sorted(mapping.items())),
        "resolved_guides": resolved,
    }
