"""Apply a reviewed canonical promotion plan to the graph.

The only module in the coaching slice with graph mutation authority, and it
exercises it exclusively through the authoritative CLI -- `wv add`, `wv update`,
`wv link` -- never by writing the database. The command runner is injected so
the whole applier is testable without a live graph and so a caller can audit
exactly which mutations were attempted.

Two hazards shape the design, both observed in the code this replaces:

**RFC 7396 merge semantics.** `wv update --metadata[-file]` stores
`json_patch(COALESCE(metadata,'{}'), <patch>)`, which is a recursive merge:
a key absent from the patch SURVIVES, and only an explicit null removes it. A
plan whose occurrence set shrank -- an ambiguity flip is the ordinary case --
would otherwise leave stale `finding.quality` fields behind, and the node would
then describe evidence the reviewed plan does not contain. So the patch this
module builds carries an explicit null for every owned key present on the node
and absent from the plan, nested keys included.

**Unchecked mutation results.** The historical applier issues its `link` calls
and discards both return codes, so a node with missing edges reports success.
Every result here is checked, and a retry repairs the same node rather than
creating a second one.

Idempotency is decided by promotion identity, never by text matching:

    0 nodes  -> create, then link
    1 node   -> update in place, then repair missing links
    >1 nodes -> fail closed and mutate nothing

A partially created node is never deleted as rollback. Deleting it would
discard a real audit record and, if the failure was transient, lose the only
evidence that the attempt happened; the next run repairs it instead.
"""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
from typing import Any, Callable, Iterable

# The metadata projection this applier owns. Anything outside these paths on a
# finding node belongs to someone else (a reviewer's note, another tool's
# annotation) and is never nulled, never overwritten, and never read for
# decisions.
OWNED_PATHS: tuple[tuple[str, ...], ...] = (
    ("type",),
    ("finding",),
    ("coaching",),
)

Runner = Callable[..., "tuple[int, str]"]


class ApplyError(Exception):
    """The plan cannot be applied safely. Nothing was mutated for this candidate."""

    def __init__(self, message: str, code: str) -> None:
        super().__init__(message)
        self.code = code


def default_runner(*args: str) -> tuple[int, str]:
    """Run the real `wv` CLI. Injected so tests never touch a live graph."""
    env = {**os.environ, "WV_CALL_SOURCE": "sync"}
    try:
        result = subprocess.run(
            [os.environ.get("WV_CLI", "wv"), *args],
            capture_output=True,
            text=True,
            check=False,
            env=env,
        )
    except FileNotFoundError:
        return 1, "wv command not found"
    return result.returncode, (result.stdout or "").strip()


def plan_digest(plan_bytes: bytes) -> str:
    """The sha256 of the exact reviewed plan bytes apply consumed."""
    return hashlib.sha256(plan_bytes).hexdigest()


def _merge_patch(current: Any, desired: Any) -> Any:
    """An RFC 7396 patch taking `current` to exactly `desired`.

    Keys present in `current` and absent from `desired` become explicit nulls,
    recursively. Without this a shrinking plan leaves stale nested state behind
    and the node silently describes more evidence than the plan holds.
    """
    if not isinstance(current, dict) or not isinstance(desired, dict):
        return desired

    patch: dict[str, Any] = {}
    for key, desired_value in desired.items():
        current_value = current.get(key)
        if isinstance(desired_value, dict) and isinstance(current_value, dict):
            nested = _merge_patch(current_value, desired_value)
            if nested:
                patch[key] = nested
        elif current_value != desired_value:
            patch[key] = desired_value
    for key in current:
        if key not in desired:
            patch[key] = None
    return patch


def owned_projection(metadata: dict[str, Any]) -> dict[str, Any]:
    """The part of a node's metadata this applier is responsible for."""
    projection: dict[str, Any] = {}
    for path in OWNED_PATHS:
        cursor: Any = metadata
        for segment in path:
            if not isinstance(cursor, dict) or segment not in cursor:
                cursor = None
                break
            cursor = cursor[segment]
        if cursor is not None:
            target = projection
            for segment in path[:-1]:
                target = target.setdefault(segment, {})
            target[path[-1]] = cursor
    return projection


def metadata_patch(current_metadata: dict[str, Any], desired: dict[str, Any]) -> dict[str, Any]:
    """The patch to send to `wv update`, scoped to the owned projection.

    Only the owned subtrees are diffed, so metadata another tool wrote to the
    same node survives untouched -- it is neither carried into the patch nor
    nulled out of existence.
    """
    # Both arguments are dicts, so _merge_patch takes its mapping branch and
    # returns the dict it builds; its `Any` return exists for the recursive
    # scalar case, which is unreachable from here.
    patch: dict[str, Any] = _merge_patch(owned_projection(current_metadata), desired)
    return patch


def _node_metadata(node: dict[str, Any]) -> dict[str, Any]:
    metadata = node.get("metadata")
    if isinstance(metadata, str) and metadata:
        try:
            metadata = json.loads(metadata)
        except json.JSONDecodeError:
            return {}
    return metadata if isinstance(metadata, dict) else {}


def find_by_promotion_id(promotion_id: str, run: Runner) -> list[dict[str, Any]]:
    """Every finding node already carrying this promotion identity.

    Identity, never text: two candidates can render identical text while being
    different promotions, and a promotion's text changes whenever its guide does.
    """
    code, out = run("findings", "list", "--all", "--json")
    if code != 0:
        raise ApplyError(f"could not read existing findings: {out}", "read_failed")
    try:
        nodes = json.loads(out) if out else []
    except json.JSONDecodeError as exc:
        raise ApplyError(f"findings list returned malformed JSON: {exc}", "read_failed") from None

    matches = []
    for node in nodes:
        metadata = _node_metadata(node)
        quality = (metadata.get("finding") or {}).get("quality") or {}
        if quality.get("promotion_id") == promotion_id:
            matches.append({**node, "metadata": metadata})
    return matches


def _created_node_id(output: str) -> str | None:
    for word in output.split():
        candidate = word.rstrip(":")
        if candidate.startswith("wv-") and len(candidate) == 9:
            return candidate
    return None


def existing_edges(node_id: str, run: Runner) -> set[tuple[str, str]]:
    """(target, type) pairs already leaving this node."""
    code, out = run("edges", node_id, "--json")
    if code != 0:
        raise ApplyError(f"could not read edges for {node_id}: {out}", "read_failed")
    try:
        rows = json.loads(out) if out else list[dict[str, str]]()
    except json.JSONDecodeError as exc:
        raise ApplyError(f"edges returned malformed JSON: {exc}", "read_failed") from None
    return {
        (str(row.get("target")), str(row.get("type")))
        for row in rows
        if str(row.get("source")) == node_id
    }


def _ensure_links(
    node_id: str, links: Iterable[tuple[str, str]], run: Runner
) -> list[tuple[str, str]]:
    """Create any missing edge, checking every result. Returns what it repaired."""
    present = existing_edges(node_id, run)
    repaired: list[tuple[str, str]] = []
    for target, edge_type in links:
        if (target, edge_type) in present:
            continue
        code, out = run("link", node_id, target, f"--type={edge_type}")
        if code != 0:
            raise ApplyError(
                f"could not link {node_id} --{edge_type}--> {target}: {out}", "link_failed"
            )
        repaired.append((target, edge_type))
    return repaired


def candidate_metadata(candidate: dict[str, Any], digest: str) -> dict[str, Any]:
    """The owned projection a promoted finding carries."""
    finding = {
        "violation_type": candidate["violation_type"],
        "root_cause": candidate["root_cause"],
        "proposed_fix": candidate["proposed_fix"],
        "policy": candidate["policy"],
        "guide": candidate["guide"],
        "quality": {
            "promotion_id": candidate["promotion_id"],
            "occurrences": candidate["occurrences"],
        },
    }
    for optional in ("confidence", "fixable"):
        if optional in candidate:
            finding[optional] = candidate[optional]
    if "rule_definition_bindings" in candidate:
        finding["quality"]["rule_definition_bindings"] = candidate["rule_definition_bindings"]
    return {
        "type": "finding",
        "finding": finding,
        # The exact bytes apply consumed. A plan recomputed at apply time that
        # differs from the reviewed one is a blocking tripwire, so the record
        # has to say which bytes were actually reviewed.
        "coaching": {"reviewed_plan_sha256": digest},
    }


def candidate_text(candidate: dict[str, Any]) -> str:
    """The node text for a promoted candidate, counting its occurrences."""
    count = len(candidate["occurrences"])
    noun = "occurrence" if count == 1 else "occurrences"
    return f"Finding: {candidate['violation_type']} ({count} {noun})"


def apply_candidate(
    candidate: dict[str, Any],
    review_parent: str,
    digest: str,
    run: Runner,
    metadata_writer: Callable[[dict[str, Any]], str],
) -> dict[str, Any]:
    """Create or update the one node this candidate owns."""
    promotion_id = candidate["promotion_id"]
    matches = find_by_promotion_id(promotion_id, run)

    if len(matches) > 1:
        raise ApplyError(
            f"{len(matches)} nodes already carry promotion_id {promotion_id} "
            f"({', '.join(sorted(str(m['id']) for m in matches))}); refusing to guess which "
            "one is canonical",
            "ambiguous_promotion_id",
        )

    desired = candidate_metadata(candidate, digest)
    links = [(review_parent, "references")]

    if not matches:
        code, out = run(
            "add", candidate_text(candidate), f"--metadata={json.dumps(desired)}", "--force"
        )
        if code != 0:
            raise ApplyError(f"could not create finding node: {out}", "create_failed")
        node_id = _created_node_id(out)
        if not node_id:
            raise ApplyError(f"could not read the created node id from: {out}", "create_failed")
        # A link failure here leaves a real node with a missing edge. It is NOT
        # deleted: the next run finds it by promotion_id and repairs the edge.
        repaired = _ensure_links(node_id, links, run)
        return {"node_id": node_id, "action": "create", "links_repaired": repaired}

    node = matches[0]
    node_id = str(node["id"])
    patch = metadata_patch(node["metadata"], desired)
    if patch:
        code, out = run("update", node_id, f"--metadata-file={metadata_writer(patch)}")
        if code != 0:
            raise ApplyError(f"could not update {node_id}: {out}", "update_failed")
    repaired = _ensure_links(node_id, links, run)
    return {
        "node_id": node_id,
        "action": "update" if patch else "unchanged",
        "links_repaired": repaired,
    }


def apply_plan(
    plan_bytes: bytes,
    run: Runner = default_runner,
    metadata_writer: Callable[[dict[str, Any]], str] | None = None,
) -> dict[str, Any]:
    """Apply the exact reviewed plan bytes.

    The bytes are the unit, not a re-derived plan: apply consumes what review
    saw, and its digest travels into every node it touches.
    """
    if metadata_writer is None:  # pragma: no cover - exercised through the CLI
        raise ApplyError("apply requires a metadata writer", "usage")

    plan = json.loads(plan_bytes)
    if plan.get("format") != "weave.coaching-promotion-plan.v1":
        raise ApplyError(f"not a promotion plan: {plan.get('format')!r}", "usage")
    if plan.get("snapshot", {}).get("state") != "complete":
        raise ApplyError("an incomplete snapshot may not be applied", "incomplete_snapshot")

    # Derived from the plan, never from an acquisition argument: apply must act
    # on the scope that was reviewed.
    review_parent = plan["scope"]["review_parent"]
    digest = plan_digest(plan_bytes)

    results: list[dict[str, Any]] = []
    for candidate in plan.get("candidates", []):
        results.append(
            {
                "promotion_id": candidate["promotion_id"],
                **apply_candidate(candidate, review_parent, digest, run, metadata_writer),
            }
        )
    return {"reviewed_plan_sha256": digest, "review_parent": review_parent, "applied": results}
