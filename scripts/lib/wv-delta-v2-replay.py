#!/usr/bin/env python3
"""Delta v2 replay/CAS evaluator.

Historically this was an offline audit tool. It is now the apply path dispatched
by `wv load` (epic delta-causality, wv-ba9dc8): it validates `weave.delta.v2`
operation sidecars and applies them to a SQLite graph under per-field
compare-and-set, ordered by the Lamport lineage each operation carries.

Correctness does not depend on replay order for a genuine causal CHAIN: every
operation names the preimage it was computed against (`expected`) and is
refused (`precondition_conflict`) rather than applied when the target holds
something else, and the multi-pass dispatch below retries a deferred op once
an earlier link in its chain has landed, converging to the same final state
regardless of file order. It DOES still matter for a genuine COLLISION --
two or more operations sharing one (entity, lineage) that do NOT chain (they
assume the SAME starting state rather than each other's result, e.g. two
`wv done --learning=...` metadata replacements racing into one throttled
sync batch): only one can ever apply, and which one is order-dependent. The
writer's own contract (wv-cdb45a/wv-4a05e7, enforced structurally since
wv_delta_compact_batch nets a batch to at most one v2 op per entity --
round 3/4 review) means this should never occur in a catalog emitted after
that fix landed; `_detect_lineage_collisions` below still catches it
explicitly rather than let a fresh producer or a hand-repaired sidecar
resolve it by silent file-order luck, the way it did historically (this
repository's own wv-806a6b lost a full learning/decision/pattern/pitfall
payload to exactly this collision, recovered from git history and
re-applied at a fresh, higher lineage -- round 4 finding 4).

Vocabulary (one per v1 changeset arm):

    node_create / node_patch / node_delete
    edge_create / edge_patch / edge_delete

Dispositions:

    applied                 the operation changed the graph
    already_satisfied       the target already holds the new value
    precondition_conflict   the target holds something other than `expected`
    ambiguous_same_lineage  two or more ops share (entity, lineage) and do not
                             chain -- neither is applied; a repair delta at a
                             fresh, higher lineage is required (round 4 finding 4)
    duplicate               operation_id already seen this batch, same hash
    identity_hash_mismatch  operation_id already seen, different hash (hard)
    integrity_failed        malformed / hash mismatch / SQL error (hard)
    unsupported_version     unknown format / canonicalization / mutation (hard)
    skipped_pre_cutover     lineage precedes the committed causal cutover
    skipped_superseded      a create whose lineage precedes the row's tombstone

A hard disposition rolls the whole batch back and exits non-zero, so the loader
does not commit a partially-applied v2 batch. `--strict` additionally treats
`precondition_conflict` and `ambiguous_same_lineage` as hard (used by
cross-machine convergence validation).

`--check OPS...` (first argument, no DB) runs only the static checks behind the
three hard dispositions over every op and exits 2 if any fails (`wv doctor`).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sqlite3
import sys
from pathlib import Path
from collections.abc import Callable
from typing import Any


STATUSES = {"todo", "ready", "active", "blocked", "blocked-external", "done"}
RISK_LEVELS = {"none", "low", "medium", "high"}
NODE_PATCH_FIELDS = {"status", "claimed_by", "risk_level", "text", "alias", "metadata"}
EDGE_PATCH_FIELDS = {"weight", "context"}
NODE_KINDS = {"node_create", "node_patch", "node_delete"}
EDGE_KINDS = {"edge_create", "edge_patch", "edge_delete"}
UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
SHA_RE = re.compile(r"^[a-f0-9]{64}$")
# contracts/delta-operation-v2.schema.json $defs.weight_value. float() alone also
# accepts inf/nan/+5/1_000/" 5 ", none of which the schema admits (wv-99c85a).
WEIGHT_RE = re.compile(r"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$")

HARD_DISPOSITIONS = {"identity_hash_mismatch", "integrity_failed", "unsupported_version"}

TOMBSTONES_DDL = """
CREATE TABLE IF NOT EXISTS tombstones (
    kind TEXT NOT NULL CHECK(kind IN ('node','edge')),
    id TEXT NOT NULL,
    lineage_seq INTEGER NOT NULL DEFAULT 0 CHECK(typeof(lineage_seq) = 'integer'),
    lineage_actor TEXT NOT NULL DEFAULT '' CHECK(typeof(lineage_actor) = 'text'),
    PRIMARY KEY (kind, id)
);
"""


class IntegrityError(ValueError):
    """Raised when an operation, or the graph it is replayed into, fails an integrity check."""


class UnsupportedVersion(ValueError):
    """Raised for an operation format, mutation kind or field this evaluator does not support."""


def canonical(value: Any) -> str:
    """Serialize a JSON-compatible value canonically (sorted keys, no whitespace) for hashing."""
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    if isinstance(value, list):
        return "[" + ",".join(canonical(item) for item in value) + "]"
    if isinstance(value, dict):
        return "{" + ",".join(
            f"{canonical(str(key))}:{canonical(value[key])}" for key in sorted(value.keys())
        ) + "}"
    raise IntegrityError(f"unsupported canonical value type: {type(value).__name__}")


def sha256_text(text: str) -> str:
    """Hex SHA-256 of a text's UTF-8 bytes."""
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def read_op(path: Path) -> dict[str, Any]:
    """Read one operation sidecar, which must be a JSON object."""
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise IntegrityError(str(exc)) from exc
    if not isinstance(value, dict):
        raise IntegrityError("operation must be an object")
    return value


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

def _require_int(value: Any, label: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        raise IntegrityError(f"invalid {label}")
    return value


def _validate_patch(patch: Any, field: str, validator: Callable[[str, Any], None]) -> None:
    if not isinstance(patch, dict) or set(patch) != {"expected", "value"}:
        raise IntegrityError(f"invalid {field} patch")
    validator(field, patch["expected"])
    validator(field, patch["value"])


def validate_node_field_value(field: str, value: Any) -> None:
    """Check a patched node field's value against that field's allowed values."""
    if field == "status":
        if value not in STATUSES:
            raise IntegrityError("invalid status value")
    elif field == "claimed_by":
        if not (value is None or (isinstance(value, str) and value)):
            raise IntegrityError("invalid claimed_by value")
    elif field == "risk_level":
        if value not in RISK_LEVELS:
            raise IntegrityError("invalid risk_level value")
    elif field == "text":
        if not (value is None or isinstance(value, str)):
            raise IntegrityError("invalid text value")
    elif field == "alias":
        if not (value is None or isinstance(value, str)):
            raise IntegrityError("invalid alias value")
    elif field == "metadata":
        if not isinstance(value, dict):
            raise IntegrityError("invalid metadata value")
    else:  # pragma: no cover - guarded by caller
        raise UnsupportedVersion(f"unsupported node field {field}")


def weight_str(value: Any) -> str | None:
    """Canonical decimal string for an edge weight (see weight_value in the schema)."""
    if value is None:
        return None
    try:
        return repr(float(value))
    except (TypeError, ValueError) as exc:
        raise IntegrityError("invalid weight value") from exc


def validate_edge_field_value(field: str, value: Any) -> None:
    """Check a patched edge field's value against that field's allowed values."""
    if field == "weight":
        if not (value is None or isinstance(value, str)):
            raise IntegrityError("invalid weight value")
        # fullmatch: re.match's "$" would still admit a trailing newline.
        if isinstance(value, str) and not WEIGHT_RE.fullmatch(value):
            raise IntegrityError("invalid weight value")
    elif field == "context":
        if not (value is None or isinstance(value, str)):
            raise IntegrityError("invalid context value")
    else:  # pragma: no cover - guarded by caller
        raise UnsupportedVersion(f"unsupported edge field {field}")


def validate_lineage(payload: dict[str, Any]) -> tuple[int, str]:
    """Return the payload's (seq, actor) lineage, which must hold exactly those two keys."""
    lineage = payload.get("lineage")
    if not isinstance(lineage, dict) or set(lineage) != {"seq", "actor"}:
        raise IntegrityError("invalid lineage")
    seq = _require_int(lineage.get("seq"), "lineage.seq")
    actor = lineage.get("actor")
    if not isinstance(actor, str):
        raise IntegrityError("invalid lineage.actor")
    return seq, actor


def _validate_envelope(op: dict[str, Any]) -> None:
    if op.get("format") != "weave.delta.v2":
        raise UnsupportedVersion("unsupported format")
    if op.get("canonicalization") != "weave.canonical-json.v1":
        raise UnsupportedVersion("unsupported canonicalization")
    if not isinstance(op.get("operation_id"), str) or not UUID_RE.match(op["operation_id"]):
        raise IntegrityError("invalid operation_id")
    if not isinstance(op.get("actor_id"), str) or not op["actor_id"]:
        raise IntegrityError("invalid actor_id")
    _require_int(op.get("actor_sequence"), "actor_sequence")
    if not isinstance(op.get("operation_sha256"), str) or not SHA_RE.match(op["operation_sha256"]):
        raise IntegrityError("invalid operation_sha256")


def _validate_entity(entity: dict[str, Any], kind: str) -> None:
    if kind in NODE_KINDS:
        if entity.get("kind") != "node" or set(entity) != {"kind", "id"} \
                or not isinstance(entity.get("id"), str) or not entity["id"]:
            raise IntegrityError("invalid node entity")
    elif kind in EDGE_KINDS:
        if entity.get("kind") != "edge" or set(entity) != {"kind", "source", "target", "type"} \
                or not all(isinstance(entity.get(k), str) and entity[k]
                           for k in ("source", "target", "type")):
            raise IntegrityError("invalid edge entity")
    else:
        raise UnsupportedVersion("unsupported mutation")


def _validate_create_mutation(mutation: dict[str, Any], kind: str) -> None:
    if set(mutation) != {"kind", "row"} or not isinstance(mutation.get("row"), dict):
        raise IntegrityError("invalid create mutation")
    row = mutation["row"]
    if kind == "node_create":
        if set(row) != {"text", "status", "metadata", "alias", "created_at"}:
            raise IntegrityError("invalid node_create row")
        for field in ("text", "status", "metadata", "alias"):
            validate_node_field_value(field, row[field])
    else:
        if set(row) != {"weight", "context", "created_at"}:
            raise IntegrityError("invalid edge_create row")
        for field in ("weight", "context"):
            validate_edge_field_value(field, row[field])
    _validate_timestamp(row["created_at"])


def _validate_patch_mutation(mutation: dict[str, Any], kind: str) -> None:
    if set(mutation) != {"kind", "fields"} or not isinstance(mutation.get("fields"), dict) \
            or not mutation["fields"]:
        raise IntegrityError("invalid patch mutation")
    fields = mutation["fields"]
    allowed = NODE_PATCH_FIELDS if kind == "node_patch" else EDGE_PATCH_FIELDS
    validator = validate_node_field_value if kind == "node_patch" else validate_edge_field_value
    if set(fields) - allowed:
        raise UnsupportedVersion("unsupported field")
    # A whole-metadata write already carries claimed_by/risk_level, so an op
    # holding both forms is ambiguous; _apply_node_patch would drop the sugar
    # write and still report `applied`. The writer emits one form or the other
    # (node_patch_fields), and the schema forbids the pair (wv-99c85a).
    if kind == "node_patch" and "metadata" in fields and fields.keys() & {"claimed_by", "risk_level"}:
        raise IntegrityError("metadata patch cannot combine claimed_by/risk_level")
    for field, patch in fields.items():
        _validate_patch(patch, field, validator)


def validate_op(op: dict[str, Any]) -> None:
    """Validate an operation's envelope, payload, lineage and hash before it may be applied."""
    _validate_envelope(op)

    payload = op.get("payload")
    if not isinstance(payload, dict):
        raise IntegrityError("invalid payload")
    entity = payload.get("entity")
    mutation = payload.get("mutation")
    if not isinstance(entity, dict) or not isinstance(mutation, dict):
        raise IntegrityError("invalid payload")
    lineage = validate_lineage(payload)
    # Round 5 finding: nothing previously required the payload's own lineage
    # to match the envelope's actor_id/actor_sequence -- a hash-valid op
    # (operation_sha256 is self-consistent over whatever payload.lineage
    # says) could claim any lineage tuple regardless of who actually wrote
    # it or when. The row would then be stamped with the spoofed lineage,
    # not the envelope's trustworthy actor_sequence/actor_id. The writer
    # (wv-delta.sh operation_for) always sets them equal; this only rejects
    # a forged/corrupted divergence between the two.
    if lineage != (op["actor_sequence"], op["actor_id"]):
        raise IntegrityError("lineage does not match envelope actor_id/actor_sequence")
    if set(payload) != {"entity", "mutation", "lineage"}:
        raise IntegrityError("unexpected payload keys")

    kind = mutation.get("kind")
    if not isinstance(kind, str):
        raise UnsupportedVersion("unsupported mutation")
    _validate_entity(entity, kind)

    if kind in ("node_create", "edge_create"):
        _validate_create_mutation(mutation, kind)
    elif kind in ("node_patch", "edge_patch"):
        _validate_patch_mutation(mutation, kind)
    elif set(mutation) != {"kind"}:  # delete
        raise IntegrityError("invalid delete mutation")

    preimage = dict(op)
    del preimage["operation_sha256"]
    if sha256_text(canonical(preimage)) != op["operation_sha256"]:
        raise IntegrityError("operation hash mismatch")


def _validate_timestamp(value: Any) -> None:
    if isinstance(value, bool) or not isinstance(value, (str, int)):
        raise IntegrityError("invalid created_at value")


# ---------------------------------------------------------------------------
# Current-state readers
# ---------------------------------------------------------------------------

def metadata_from_raw(raw: Any) -> dict[str, Any]:
    """Parse a node's stored metadata JSON, treating anything but an object as empty."""
    if not raw:
        return {}
    try:
        value = json.loads(raw)
    except (TypeError, json.JSONDecodeError):
        return {}
    return value if isinstance(value, dict) else {}


def _dumps(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def node_current_fields(conn: sqlite3.Connection, node_id: str) -> dict[str, Any] | None:
    """Return a node's current CAS-relevant fields, or None if the node does not exist."""
    row = conn.execute(
        "SELECT status, metadata, text, alias FROM nodes WHERE id = ?", (node_id,)
    ).fetchone()
    if row is None:
        return None
    metadata = metadata_from_raw(row[1])
    claimed = metadata.get("claimed_by")
    risk = metadata.get("risk_level", "none")
    return {
        "status": row[0],
        "metadata": metadata,
        "text": row[2],
        "alias": row[3],
        "claimed_by": claimed if isinstance(claimed, str) and claimed else None,
        "risk_level": risk if isinstance(risk, str) and risk in RISK_LEVELS else "none",
    }


def edge_current_fields(conn: sqlite3.Connection, key: tuple[str, str, str]) -> dict[str, Any] | None:
    """Return an edge's current weight and context, or None if the edge does not exist."""
    row = conn.execute(
        "SELECT weight, context FROM edges WHERE source = ? AND target = ? AND type = ?", key
    ).fetchone()
    if row is None:
        return None
    return {"weight": weight_str(row[0]), "context": row[1]}


def _row_lineage(conn: sqlite3.Connection, table: str, where: str, params: tuple[Any, ...]) -> tuple[int, str] | None:
    row = conn.execute(
        f"SELECT lineage_seq, lineage_actor FROM {table} WHERE {where}", params
    ).fetchone()
    if row is None:
        return None
    return int(row[0]), row[1] or ""


def _existing_row_lineage(conn: sqlite3.Connection, table: str, where: str,
                          params: tuple[Any, ...]) -> tuple[int, str]:
    """Lineage of a row the caller has just read as present.

    The callers read the row's fields first, on the same connection, and
    return early when it is missing, so a None here means the store changed
    under the read: refuse rather than compare against nothing (wv-4dcf9c).
    """
    lineage = _row_lineage(conn, table, where, params)
    if lineage is None:
        raise IntegrityError(f"{table} row read as present has no lineage")
    return lineage


def _tombstone_lineage(conn: sqlite3.Connection, kind: str, ident: str) -> tuple[int, str] | None:
    row = conn.execute(
        "SELECT lineage_seq, lineage_actor FROM tombstones WHERE kind = ? AND id = ?", (kind, ident)
    ).fetchone()
    if row is None:
        return None
    return int(row[0]), row[1] or ""


def _write_tombstone(conn: sqlite3.Connection, kind: str, ident: str, lineage: tuple[int, str]) -> None:
    conn.execute(
        "INSERT INTO tombstones(kind, id, lineage_seq, lineage_actor) VALUES (?, ?, ?, ?) "
        "ON CONFLICT(kind, id) DO UPDATE SET lineage_seq = excluded.lineage_seq, "
        "lineage_actor = excluded.lineage_actor "
        "WHERE (excluded.lineage_seq, excluded.lineage_actor) > "
        "(tombstones.lineage_seq, tombstones.lineage_actor)",
        (kind, ident, lineage[0], lineage[1]),
    )


# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------

def apply_op(conn: sqlite3.Connection, op: dict[str, Any], cutover_seq: int | None) -> str:
    """Apply one validated operation by mutation kind and return its outcome."""
    payload = op["payload"]
    mutation = payload["mutation"]
    kind = mutation["kind"]
    lineage = (payload["lineage"]["seq"], payload["lineage"]["actor"])

    if cutover_seq is not None and lineage[0] < cutover_seq:
        return "skipped_pre_cutover"

    if kind == "node_create":
        return _apply_node_create(conn, payload["entity"]["id"], mutation["row"], lineage)
    if kind == "node_patch":
        return _apply_node_patch(conn, payload["entity"]["id"], mutation["fields"], lineage)
    if kind == "node_delete":
        return _apply_delete(conn, "node", "nodes", "id = ?", (payload["entity"]["id"],),
                             payload["entity"]["id"], lineage)
    ent = payload["entity"]
    key = (ent["source"], ent["target"], ent["type"])
    ident = ":".join(key)
    if kind == "edge_create":
        return _apply_edge_create(conn, key, ident, mutation["row"], lineage)
    if kind == "edge_patch":
        return _apply_edge_patch(conn, key, mutation["fields"], lineage)
    if kind == "edge_delete":
        return _apply_delete(conn, "edge", "edges", "source = ? AND target = ? AND type = ?", key,
                             ident, lineage)
    raise UnsupportedVersion(f"unsupported mutation {kind}")  # pragma: no cover


def _lineage_after(candidate: tuple[int, str], current: tuple[int, str]) -> bool:
    # A row still at lineage_seq 0 is pre-cutover and always yields.
    return current[0] == 0 or candidate > current


def _apply_node_create(conn: sqlite3.Connection, node_id: str, row: dict[str, Any], lineage: tuple[int, str]) -> str:
    tomb = _tombstone_lineage(conn, "node", node_id)
    if tomb is not None and not lineage > tomb:
        return "skipped_superseded"
    current = node_current_fields(conn, node_id)
    row_lineage = None if current is None else _existing_row_lineage(conn, "nodes", "id = ?", (node_id,))
    # Does this create actually win against the target row? A nonexistent
    # target always yields (a plain INSERT); an existing one only yields under
    # the same guard the caller checks below. Computed up front because the
    # alias pre-clear -- ordinary cross-agent alias contention, not
    # corruption -- must not fire ahead of a create that is itself going to be
    # refused: SQLite's alias UNIQUE constraint would otherwise be the only
    # thing stopping a stale create from stealing a causally newer row's
    # alias, and unlike the v1 SQL path there is no separate lineage-guarded
    # UPDATE to leave the steal half-done -- here it is fully committed before
    # the create's own guard is even evaluated.
    target_wins = row_lineage is None or _lineage_after(lineage, row_lineage)
    # The holder clause is checked separately from target_wins: the holder of
    # a contested alias is a DIFFERENT row from the target (an absent target
    # says nothing about the holder), so gating the clear on target_wins alone
    # let an absent-target stale create steal a causally newer row's alias
    # outright. Only clear a holder that is itself behind this write; a
    # holder that survives means the incoming alias is still contested when
    # the row below is written.
    # The holder query and the pre-clear are scoped to status != 'done'
    # (round 3 finding 3b): production's actual constraint is the partial
    # index idx_nodes_alias ... WHERE alias IS NOT NULL AND status != 'done'
    # (scripts/lib/wv-db.sh), not a plain UNIQUE column -- a done node's
    # alias is never enforced unique at all, so it can never be a real
    # holder, and an incoming create whose own status is 'done' can never
    # actually collide with anyone either (skip the contest, keep the alias
    # unconditionally).
    #
    # Also gated on target_wins (round 4 finding 3): the comment above this
    # block always said the pre-clear "must not fire ahead of a create that
    # is itself going to be refused" but the code never actually checked
    # target_wins here -- only later, at the precondition_conflict return
    # below, by which point a losing create had already cleared and
    # re-stamped the holder's lineage. A conflict disposition must have no
    # side effects; a create whose OWN guard is about to refuse it has no
    # standing to arbitrate anyone else's alias either.
    effective_alias = row["alias"]
    if target_wins and effective_alias is not None and row["status"] != "done":
        holder_row = conn.execute(
            "SELECT id, lineage_seq, lineage_actor FROM nodes "
            "WHERE alias = ? AND id != ? AND status != 'done'",
            (effective_alias, node_id),
        ).fetchone()
        if holder_row is not None:
            holder_lineage = (holder_row[1], holder_row[2])
            if _lineage_after(lineage, holder_lineage):
                # The clear ALSO stamps the holder's own lineage (round 3
                # finding 3c): omitting this left a cleared holder still
                # carrying its OLD (lower) lineage, so a stale delta the
                # holder's own removal had already superseded could still
                # apply against it, since nothing recorded that the clear
                # had touched the row at all.
                conn.execute(
                    "UPDATE nodes SET alias = NULL, lineage_seq = ?, lineage_actor = ? WHERE id = ?",
                    (lineage[0], lineage[1], holder_row[0]),
                )
            else:
                # Holder wins the alias contest. The node itself still gets
                # created/updated below (its id does not collide with
                # anything) -- it just does not carry the alias it lost the
                # contest for, rather than hitting the UNIQUE constraint and
                # raising IntegrityError, a HARD disposition that would abort
                # this entire batch over an ordinary cross-agent collision.
                effective_alias = None
    metadata_text = _dumps(row["metadata"])
    if current is None:
        conn.execute(
            "INSERT INTO nodes(id, text, status, metadata, alias, created_at, updated_at, "
            "lineage_seq, lineage_actor) VALUES (?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP, ?, ?)",
            (node_id, row["text"], row["status"], metadata_text, effective_alias, row["created_at"],
             lineage[0], lineage[1]),
        )
        return "applied"
    same = (
        current["text"] == row["text"]
        and current["status"] == row["status"]
        and current["alias"] == row["alias"]
        and current["metadata"] == row["metadata"]
    )
    if same and row_lineage == lineage:
        return "already_satisfied"
    if not target_wins:
        return "precondition_conflict"
    conn.execute(
        "UPDATE nodes SET text = ?, status = ?, metadata = ?, alias = ?, created_at = ?, "
        "updated_at = CURRENT_TIMESTAMP, lineage_seq = ?, lineage_actor = ? WHERE id = ?",
        (row["text"], row["status"], metadata_text, effective_alias, row["created_at"],
         lineage[0], lineage[1], node_id),
    )
    return "applied"


def _apply_node_patch(conn: sqlite3.Connection, node_id: str, fields: dict[str, Any], lineage: tuple[int, str]) -> str:
    current = node_current_fields(conn, node_id)
    if current is None:
        return "precondition_conflict"
    row_lineage = _existing_row_lineage(conn, "nodes", "id = ?", (node_id,))
    if all(current[field] == patch["value"] for field, patch in fields.items()):
        # Already satisfied: no business field changes, but the row's own
        # lineage must still be advanced when this op is causally AFTER it
        # (round 4 finding 6) -- otherwise the row never records having
        # "seen" this write, and a stale op below this op's lineage but
        # above the row's un-advanced one (e.g. a delete) can still apply
        # later, silently reverting or removing a row this op already
        # accounted for. A row already at or beyond this op's own lineage is
        # left alone (never regress).
        if _lineage_after(lineage, row_lineage):
            conn.execute(
                "UPDATE nodes SET lineage_seq = ?, lineage_actor = ? WHERE id = ?",
                (lineage[0], lineage[1], node_id),
            )
        return "already_satisfied"
    # A patch must never apply against, or regress the lineage of, a row already
    # causally at or beyond a LATER emission. Without this a stale op (e.g. the
    # claimed_by patch `wv add` emits at lineage seq 1) rewrites a row `wv done`
    # advanced to seq 2 on a fresh clone whose state.sql is authoritative, and
    # drops lineage_seq back to 1 -- re-opening the row to every stale v1 delta.
    # Mirrors _apply_node_create's guard; same-emission ops (equal lineage) still
    # chain through the `expected` CAS below.
    if row_lineage is not None and row_lineage[0] != 0 and lineage < row_lineage:
        return "precondition_conflict"
    if any(current[field] != patch["expected"] for field, patch in fields.items()):
        return "precondition_conflict"

    # Alias arbitration (round 3 finding 3a): node_patch previously had ZERO
    # arbitration, so a patch landing an alias already held elsewhere hit the
    # UNIQUE constraint directly. Mirrors _apply_node_create's pre-clear,
    # scoped to the same partial index (alias IS NOT NULL AND status !=
    # 'done'). Two paths claim the index: (1) "alias" is in fields (an
    # outright alias change), or (2) alias is unchanged but status is
    # leaving 'done' -- the row is newly entering the partial index carrying
    # an alias it already held while done, uncontested only because 'done'
    # rows were never indexed. The reverse direction (entering 'done') needs
    # nothing: SQLite drops the row from the partial index on its own.
    # `write_alias` tracks what actually lands in the SET list below; CAS
    # checks above already ran against the untouched `fields`.
    write_alias: dict[str, object] | None = fields.get("alias")
    new_alias = write_alias["value"] if write_alias is not None else current["alias"]
    new_status = fields["status"]["value"] if "status" in fields else current["status"]
    old_status = current["status"]
    claims_index = (
        new_alias is not None
        and new_status != "done"
        and (write_alias is not None or old_status == "done")
    )
    if claims_index:
        holder_row = conn.execute(
            "SELECT id, lineage_seq, lineage_actor FROM nodes "
            "WHERE alias = ? AND id != ? AND status != 'done'",
            (new_alias, node_id),
        ).fetchone()
        if holder_row is not None:
            holder_lineage = (holder_row[1], holder_row[2])
            if _lineage_after(lineage, holder_lineage):
                conn.execute(
                    "UPDATE nodes SET alias = NULL, lineage_seq = ?, lineage_actor = ? WHERE id = ?",
                    (lineage[0], lineage[1], holder_row[0]),
                )
            else:
                # Holder wins. Force alias=NULL into the write regardless of
                # which path claimed the index: an outright change loses the
                # contest (same HARD-vs-CAS-conflict tradeoff as
                # _apply_node_create); a status-only entry (path 2) cannot
                # legally keep a now-contested alias it never re-asserted.
                write_alias = {"value": None}

    metadata = dict(current["metadata"])
    sets: list[str] = []
    params: list[Any] = []
    if "text" in fields:
        sets.append("text = ?")
        params.append(fields["text"]["value"])
    if "status" in fields:
        sets.append("status = ?")
        params.append(fields["status"]["value"])
    if write_alias is not None:
        sets.append("alias = ?")
        params.append(write_alias["value"])
    if "metadata" in fields:
        metadata = fields["metadata"]["value"]
        sets.append("metadata = ?")
        params.append(_dumps(metadata))
    else:
        touched_metadata = False
        if "claimed_by" in fields:
            touched_metadata = True
            value = fields["claimed_by"]["value"]
            if value is None:
                metadata.pop("claimed_by", None)
            else:
                metadata["claimed_by"] = value
        if "risk_level" in fields:
            touched_metadata = True
            value = fields["risk_level"]["value"]
            if value == "none":
                metadata.pop("risk_level", None)
            else:
                metadata["risk_level"] = value
        if touched_metadata:
            sets.append("metadata = ?")
            params.append(_dumps(metadata))
    sets.append("updated_at = CURRENT_TIMESTAMP")
    sets.append("lineage_seq = ?")
    params.append(lineage[0])
    sets.append("lineage_actor = ?")
    params.append(lineage[1])
    params.append(node_id)
    conn.execute(f"UPDATE nodes SET {', '.join(sets)} WHERE id = ?", params)
    return "applied"


def _apply_edge_create(conn: sqlite3.Connection, key: tuple[str, str, str], ident: str, row: dict[str, Any],
                       lineage: tuple[int, str]) -> str:
    tomb = _tombstone_lineage(conn, "edge", ident)
    if tomb is not None and not lineage > tomb:
        return "skipped_superseded"
    current = edge_current_fields(conn, key)
    weight_sql = None if row["weight"] is None else float(row["weight"])
    if current is None:
        conn.execute(
            "INSERT INTO edges(source, target, type, weight, context, created_at, "
            "lineage_seq, lineage_actor) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (*key, weight_sql, row["context"], row["created_at"], lineage[0], lineage[1]),
        )
        return "applied"
    row_lineage = _existing_row_lineage(conn, "edges", "source = ? AND target = ? AND type = ?", key)
    same = current["weight"] == weight_str(row["weight"]) and current["context"] == row["context"]
    if same and row_lineage == lineage:
        return "already_satisfied"
    if not _lineage_after(lineage, row_lineage):
        return "precondition_conflict"
    conn.execute(
        "UPDATE edges SET weight = ?, context = ?, created_at = ?, lineage_seq = ?, "
        "lineage_actor = ? WHERE source = ? AND target = ? AND type = ?",
        (weight_sql, row["context"], row["created_at"], lineage[0], lineage[1], *key),
    )
    return "applied"


def _apply_edge_patch(conn: sqlite3.Connection, key: tuple[str, str, str], fields: dict[str, Any],
                      lineage: tuple[int, str]) -> str:
    current = edge_current_fields(conn, key)
    if current is None:
        return "precondition_conflict"
    row_lineage = _existing_row_lineage(conn, "edges", "source = ? AND target = ? AND type = ?", key)
    if all(current[field] == patch["value"] for field, patch in fields.items()):
        # See _apply_node_patch (round 4 finding 6): advance the row's own
        # lineage even when no field value changes, so a stale op below this
        # op's lineage cannot apply later against a row that never recorded
        # having seen it.
        if _lineage_after(lineage, row_lineage):
            conn.execute(
                "UPDATE edges SET lineage_seq = ?, lineage_actor = ? "
                "WHERE source = ? AND target = ? AND type = ?",
                (lineage[0], lineage[1], *key),
            )
        return "already_satisfied"
    # See _apply_node_patch: a stale-lineage patch must not apply against or
    # regress a row already at a later emission.
    if row_lineage is not None and row_lineage[0] != 0 and lineage < row_lineage:
        return "precondition_conflict"
    if any(current[field] != patch["expected"] for field, patch in fields.items()):
        return "precondition_conflict"
    sets: list[str] = []
    params: list[Any] = []
    for field in ("weight", "context"):
        if field in fields:
            value = fields[field]["value"]
            if field == "weight" and value is not None:
                value = float(value)
            sets.append(f"{field} = ?")
            params.append(value)
    sets.append("lineage_seq = ?")
    params.append(lineage[0])
    sets.append("lineage_actor = ?")
    params.append(lineage[1])
    params.extend(key)
    conn.execute(
        f"UPDATE edges SET {', '.join(sets)} WHERE source = ? AND target = ? AND type = ?", params
    )
    return "applied"


def _apply_delete(conn: sqlite3.Connection, tomb_kind: str, table: str, where: str, params: tuple[Any, ...],
                  ident: str, lineage: tuple[int, str]) -> str:
    row_lineage = _row_lineage(conn, table, where, params)
    if row_lineage is None:
        _write_tombstone(conn, tomb_kind, ident, lineage)
        return "already_satisfied"
    if lineage >= row_lineage or row_lineage[0] == 0:
        conn.execute(f"DELETE FROM {table} WHERE {where}", params)
        _write_tombstone(conn, tomb_kind, ident, lineage)
        return "applied"
    return "precondition_conflict"


# ---------------------------------------------------------------------------
# Batch
# ---------------------------------------------------------------------------

def _entity_key(entity: dict[str, Any]) -> tuple[str, ...]:
    if entity.get("kind") == "node":
        return ("node", entity["id"])
    return ("edge", entity["source"], entity["target"], entity["type"])


# Physical write domain each patch field key actually touches (round 4
# finding 3): `metadata`, `claimed_by`, and `risk_level` are three DIFFERENT
# field keys that all mutate the SAME `metadata` column -- a whole-object
# replace via one key and a sugar patch via another are not comparable as a
# chain (their `expected` values are different representations of
# overlapping state), so an overlap here is always a collision regardless of
# value equality. `text`/`status`/`alias` (nodes) and `weight`/`context`
# (edges) each own their column outright.
_NODE_PATCH_COLUMN = {
    "text": "text", "status": "status", "alias": "alias",
    "metadata": "metadata", "claimed_by": "metadata", "risk_level": "metadata",
}
_EDGE_PATCH_COLUMN = {"weight": "weight", "context": "context"}


def _freeze(value: Any) -> Any:
    """Hashable form of a patch expected/value for use as a graph node key."""
    if isinstance(value, (dict, list)):
        return json.dumps(value, sort_keys=True, separators=(",", ":"))
    return value


def _has_cycle(edges: dict[Any, Any]) -> bool:
    # `edges` maps expected -> value for one column across every patch in a
    # group. Two ops sharing an identical `expected` are rejected earlier as
    # a fork (round 4 finding 4's original pairwise check), so every node has
    # out-degree <= 1 here -- a functional graph, which can only ever be
    # simple chains feeding into at most one cycle. Standard cycle walk:
    # follow each unvisited node's chain, and finding a node already on the
    # CURRENT walk means it closes a loop.
    visited: set[Any] = set()
    for start in edges:
        if start in visited:
            continue
        path: set[Any] = set()
        node = start
        while node in edges:
            if node in path:
                return True
            path.add(node)
            visited.add(node)
            node = edges[node]
    return False


def _create_field_value(kind: str, row: dict[str, Any], key: str) -> Any:
    # Mirrors node_current_fields'/edge_current_fields' normalization (the
    # replay-side "what does the row currently hold" reader) so a create's
    # `row` and a patch's `expected` for the same field are compared in the
    # SAME representation.
    if kind == "edge_create":
        return row.get(key)
    if key in ("text", "status", "alias"):
        return row.get(key)
    meta = row.get("metadata")
    meta = meta if isinstance(meta, dict) else dict[str, object]()
    if key == "metadata":
        return meta
    if key == "claimed_by":
        value = meta.get("claimed_by")
        return value if isinstance(value, str) and value else None
    if key == "risk_level":
        value = meta.get("risk_level", "none")
        return value if isinstance(value, str) and value in RISK_LEVELS else "none"
    return None  # pragma: no cover - guarded by NODE_PATCH_FIELDS/EDGE_PATCH_FIELDS


def _gather_lineage_entries(
    op_paths: list[Path],
) -> tuple[list[tuple[str, str, str, tuple[Any, ...], tuple[Any, ...], dict[str, Any] | None]], dict[str, set[str]]]:
    """Parse+validate every op for collision analysis.

    Every op is validated (hash, envelope, mutation shape) before it can ever
    be grouped for collision analysis (round 4 finding 2): read_op alone only
    checks that the file parses as a JSON object -- the hash check lives in
    validate_op, further down. Without calling it here too, a bad-hash op
    sitting in a group with a legitimate sibling was classified
    ambiguous_same_lineage (soft, no rollback) instead of integrity_failed
    (hard, rolls back and exits 2) -- a malformed/tampered operation
    bypassing the SAME check every other op in the batch is still held to. A
    validation failure here is not this function's concern to report; it
    falls through unclassified so evaluate()'s own normal dispatch loop calls
    validate_op again and reports it exactly as it always has.

    node_create/edge_create's `row` is also captured here (round 5 finding,
    not just patch `fields`), so the create/patch dependency check in
    `_create_patch_collision` has the create's actual field values to compare
    against a sibling patch's `expected`.
    """
    op_hashes: dict[str, set[str]] = {}
    entries: list[tuple[str, str, str, tuple[Any, ...], tuple[Any, ...], dict[str, Any] | None]] = []
    for path in op_paths:
        try:
            op = read_op(path)
            validate_op(op)
            payload = op["payload"]
            mutation = payload["mutation"]
            kind = mutation.get("kind")
            entity_key = _entity_key(payload["entity"])
            lineage = (payload["lineage"]["seq"], payload["lineage"]["actor"])
            op_id = str(op.get("operation_id", ""))
            op_hash = str(op.get("operation_sha256", ""))
            data: dict[str, Any] | None = None
            if kind in ("node_patch", "edge_patch"):
                data = mutation.get("fields")
                if not isinstance(data, dict):
                    continue
            elif kind in ("node_create", "edge_create"):
                data = mutation.get("row")
                if not isinstance(data, dict):
                    continue
            if op_id:
                op_hashes.setdefault(op_id, set()).add(op_hash)
            entries.append((str(path), op_id, str(kind), entity_key, lineage, data))
        except (IntegrityError, UnsupportedVersion):
            continue  # evaluate() re-validates and reports it
    return entries, op_hashes


def _group_by_lineage(
    entries: list[tuple[str, str, str, tuple[Any, ...], tuple[Any, ...], dict[str, Any] | None]],
    op_hashes: dict[str, set[str]],
) -> dict[tuple[Any, ...], list[tuple[str, str, str, dict[str, Any] | None]]]:
    """Group entries by (entity, lineage), excluding hash-mismatched op_ids.

    Round 5 finding: an operation_id reused with a DIFFERENT hash is
    tampering/corruption -- evaluate()'s own `seen` dedup classifies it as
    the HARD `identity_hash_mismatch` (rolls back the whole batch). That
    check never runs for an op this function has already swept into a group:
    if a THIRD, unrelated op happened to share the same (entity, lineage),
    the whole group -- mismatched pair included -- was downgraded to the
    SOFT `ambiguous_same_lineage` (no rollback), silently hiding a
    forged/corrupted operation behind an ordinary-looking causal conflict
    (reproduced with aborted=false). Deduplicated here, before any grouping,
    so a hash-mismatched op_id never enters collision analysis at all and
    always reaches evaluate()'s real, hard check instead.
    """
    mismatched_ids = {op_id for op_id, hashes in op_hashes.items() if len(hashes) > 1}
    groups: dict[tuple[Any, ...], list[tuple[str, str, str, dict[str, Any] | None]]] = {}
    for path_str, op_id, kind, entity_key, lineage, data in entries:
        if op_id and op_id in mismatched_ids:
            continue
        groups.setdefault((entity_key, lineage), []).append((path_str, op_id, kind, data))
    return groups


def _create_patch_collision(
    create_kind: str, create_row: Any, patch_fields: Any, kind_i: str, kind_j: str
) -> tuple[bool, str]:
    """A create paired with a patch on the SAME (entity, lineage).

    Round 5 finding: only a genuine causal chain if the patch's `expected`
    for every field it touches is exactly what the create's own `row` set --
    previously ANY create+patch pair was let through unconditionally, so
    against an entity that already existed (the create is itself a
    lineage-guarded overwrite, not a fresh INSERT) a patch computed against
    the PRE-batch state was treated as chaining off the create regardless.
    Proven: reversing file order flipped which of the create's or the
    patch's value survived.
    """
    mismatch = not isinstance(create_row, dict) or not isinstance(patch_fields, dict)
    if not mismatch:
        for key, patch in patch_fields.items():
            if not isinstance(patch, dict) or (
                _create_field_value(create_kind, create_row, key) != patch.get("expected")
            ):
                mismatch = True
                break
    if mismatch:
        return True, (
            f"kinds {kind_i}/{kind_j} share one (entity, lineage) but the "
            "patch's expected value does not match what the create's row "
            "sets -- not a causal chain"
        )
    return False, ""


def _patch_patch_collision(fields_i: dict[str, Any], fields_j: dict[str, Any],
                           column_map: dict[str, str]) -> tuple[bool, str]:
    """Two patches on the SAME (entity, lineage), checked column by column.

    Round 5 finding: comparing keys across ALL shared columns at once forced
    len(keys_i) == 1, rejecting any valid multi-field chain (e.g. text+status
    patched together twice) even when every shared column's own
    expected/value transition was perfectly consistent. Each column is an
    independent physical write domain (see _NODE_PATCH_COLUMN) -- check its
    own key-and-expected transition on its own, not lumped in with every
    other shared column.
    """
    cols_i = {c for f in fields_i if (c := column_map.get(f)) is not None}
    cols_j = {c for f in fields_j if (c := column_map.get(f)) is not None}

    # Deep-review finding: two ops are only a safe, semantically-identical
    # duplicate -- not a real collision -- if they touch the EXACT SAME set
    # of fields with the EXACT SAME expected/value transition on every one.
    # Matching on a merely SHARED column is not enough: this repository's
    # own wv-806a6b incident was exactly that shape -- a bare status=done
    # patch racing a rich status+metadata replace that happened to share the
    # identical status transition. node_patch applies every field in one op
    # atomically against a single shared precondition, so whichever op
    # "wins" the race decides the whole row: if the bare one won, the rich
    # payload's metadata field never landed at all, not even attempted --
    # letting the shared status match wave the pair through as harmless
    # would silently reopen that exact loss.
    if set(fields_i) == set(fields_j) and all(
        isinstance(fields_i[k], dict) and isinstance(fields_j[k], dict)
        and fields_i[k].get("expected") == fields_j[k].get("expected")
        and fields_i[k].get("value") == fields_j[k].get("value")
        for k in fields_i
    ):
        return False, ""

    for col in sorted(cols_i & cols_j):
        keys_i = {f for f in fields_i if column_map.get(f) == col}
        keys_j = {f for f in fields_j if column_map.get(f) == col}
        if keys_i != keys_j or len(keys_i) != 1:
            return True, (
                f"column {col!r} reached through different "
                f"field keys ({sorted(keys_i)} vs {sorted(keys_j)}) -- not comparable as a chain"
            )
        key = next(iter(keys_i))
        ei, ej = fields_i.get(key), fields_j.get(key)
        if (
            isinstance(ei, dict) and isinstance(ej, dict)
            and ei.get("expected") == ej.get("expected")
        ):
            return True, f"field '{key}' shares an identical expected value"
    return False, ""


def _pair_collision(
    kind_i: str, fields_i: Any, kind_j: str, fields_j: Any, column_map: dict[str, str]
) -> tuple[bool, str]:
    """Whether one (kind, fields) pair sharing an (entity, lineage) collides.

    (a) node_create/edge_create carries a `row`, not `expected`/`value`
        pairs -- there is no chain concept for it at all. Two creates for
        the SAME id+lineage are order-dependent by construction: whichever
        is dispatched first stamps the row's lineage to exactly this tuple,
        so the second's own target_wins guard (candidate > current, never
        true for an EQUAL tuple) permanently refuses it. Proven: reversing
        file order between two such creates flips which text value survives.
    (b) a delete paired with anything else is never a collision (round 5
        finding): _apply_delete's own guard is lineage-only -- no per-field
        `expected` precondition at all -- so it is inherently order-tolerant
        against anything else sharing its lineage; the tombstone it writes
        (and the tombstone/current-is-gone checks in _apply_node_create/
        _apply_node_patch) converge to the SAME end state regardless of
        which side of the pair runs first. Previously ANY mix with a delete
        was forced into a collision, excluding both ops from dispatch
        outright, so a legitimate patch-then-delete never ran its delete
        half and left the row alive in both orders.
    """
    is_create_i = kind_i in ("node_create", "edge_create")
    is_create_j = kind_j in ("node_create", "edge_create")
    is_patch_i = kind_i in ("node_patch", "edge_patch")
    is_patch_j = kind_j in ("node_patch", "edge_patch")
    if is_create_i and is_create_j:
        return True, (
            f"kinds {kind_i}/{kind_j} sharing one (entity, lineage) both create "
            "the row -- order-dependent, no expected-value chain"
        )
    if not (is_create_i or is_patch_i) or not (is_create_j or is_patch_j):
        return False, ""
    if is_create_i and is_patch_j:
        return _create_patch_collision(kind_i, fields_i, fields_j, kind_i, kind_j)
    if is_patch_i and is_create_j:
        return _create_patch_collision(kind_j, fields_j, fields_i, kind_i, kind_j)
    return _patch_patch_collision(fields_i, fields_j, column_map)


def _group_collision_note(
    members: list[tuple[str, str, str, dict[str, Any] | None]], column_map: dict[str, str]
) -> str:
    """Pairwise scan of a lineage group; empty string if no pair collides."""
    for i, (_, id_i, kind_i, fields_i) in enumerate(members):
        for _, id_j, kind_j, fields_j in members[i + 1:]:
            # A repeated operation_id is a legitimate duplicate/retry
            # (handled separately by evaluate()'s `seen` dedup), not a
            # collision -- it is not a SECOND op racing the first, it is the
            # SAME op encountered twice.
            if id_i and id_i == id_j:
                continue
            colliding, note = _pair_collision(kind_i, fields_i, kind_j, fields_j, column_map)
            if colliding:
                return note
    return ""


def _group_cycle_note(
    members: list[tuple[str, str, str, dict[str, Any] | None]], column_map: dict[str, str]
) -> str:
    """Detect a 3+-way cyclic expected/value chain the pairwise scan misses.

    Round 5 finding: the pairwise checks only ever compare TWO ops at a
    time, so a 3+-way CYCLE on one column (op A's expected == the group's
    actual starting value; op B's expected == A's value; op C's expected ==
    B's value; op A's value == C's expected again, closing the loop) has
    every pairwise `expected` distinct -- nothing flags it. But
    _apply_node_patch's/_apply_edge_patch's "already satisfied" shortcut
    matches on VALUE alone, with no `expected` check: whichever cycle member
    happens to be dispatched first and finds the row's CURRENT value already
    equal to ITS `value` (true for exactly one member of a closed loop back
    to the starting value) is marked satisfied without ever verifying its
    own `expected` -- silently dropping it from the chain and leaving the
    rest to resolve to a DIFFERENT final value than a full traversal would
    (proven: A->B->C->A settled on A in one file order, C in the other).
    Detected structurally instead of relying on dispatch to notice: build
    the expected->value graph per column across every patch in the group
    (out-degree <= 1 per node, since two ops sharing an `expected` were
    already caught by the pairwise scan) and walk it for a cycle.
    """
    columns: dict[str, dict[Any, Any]] = {}
    for _, _, member_kind, member_fields in members:
        if member_kind not in ("node_patch", "edge_patch") or not isinstance(member_fields, dict):
            continue
        for key, patch in member_fields.items():
            col = column_map.get(key)
            if col is None or not isinstance(patch, dict):
                continue
            columns.setdefault(col, {})[_freeze(patch.get("expected"))] = _freeze(patch.get("value"))
    for col, edges in columns.items():
        if _has_cycle(edges):
            return f"column {col!r} forms a cyclic expected/value chain -- not a valid causal order"
    return ""


def _detect_lineage_collisions(op_paths: list[Path]) -> dict[str, tuple[str, str]]:
    # Round 4 finding 4: a genuine causal CHAIN within one (entity, lineage)
    # group has each op's `expected` equal the PRECEDING op's `value` for
    # every field they share -- the multi-pass dispatch in evaluate() below
    # converges to the true final state regardless of file order. A
    # COLLISION is different in kind, not degree: two or more ops in the
    # SAME group have no such dependency -- both assume the identical
    # starting state (or, for create/delete, have no `expected` chain
    # concept at all). Exactly one can ever land; which one is pure
    # file-order luck, and the other is discarded with no trace it ever
    # existed. Detected up front, by group, rather than left to resolve
    # itself through the normal dispatch loop: every op in a colliding group
    # is refused outright (`ambiguous_same_lineage`), not silently split
    # into one applied / one precondition_conflict indistinguishable from an
    # ordinary stale write.
    #
    # `metadata`, `claimed_by`, and `risk_level` are three different field
    # KEYS that all mutate the physical `metadata` column (see
    # _NODE_PATCH_COLUMN) -- comparing literal key names missed a whole
    # metadata replace racing a claimed_by/risk_level sugar patch, the exact
    # shape that cost wv-806a6b its learning payload (round 4 finding 3b).
    # Grouping is by COLUMN: the same column reached through the SAME single
    # key on both sides can still form a genuine chain (checked by `expected`
    # equality); reached through DIFFERENT keys, the two `expected` values
    # are different representations of overlapping state and are never
    # comparable -- always a collision.
    #
    # See _gather_lineage_entries/_group_by_lineage for how ops are parsed
    # and grouped, _pair_collision (and its create/patch and patch/patch
    # helpers) for the pairwise same-lineage checks, and _group_cycle_note
    # for the acyclic-graph check a pairwise scan alone cannot see.
    entries, op_hashes = _gather_lineage_entries(op_paths)
    groups = _group_by_lineage(entries, op_hashes)

    collisions: dict[str, tuple[str, str]] = {}
    for (entity_key, lineage), members in groups.items():
        if len(members) < 2:
            continue
        column_map = _NODE_PATCH_COLUMN if entity_key[0] == "node" else _EDGE_PATCH_COLUMN
        note = _group_collision_note(members, column_map) or _group_cycle_note(members, column_map)
        if note:
            reason = (
                f"{len(members)} ops share entity={entity_key} lineage={lineage}: "
                f"{note} -- not a causal chain, a repair delta at a fresh, "
                "higher lineage is required"
            )
            for path_str, op_id, _kind, _fields in members:
                collisions[path_str] = (reason, op_id)
    return collisions


def evaluate(
    db_path: Path,
    op_paths: list[Path],
    cutover_seq: int | None = None,
    strict: bool = False,
) -> dict[str, Any]:
    """Replay operations into the graph in one transaction and return each one's outcome and whether it aborted."""
    # Multi-pass, fixed-point dispatch. Every op in one emission carries the
    # SAME lineage tuple by design (wv-cdb45a/wv-4a05e7's writer contract), so
    # a catalog can legitimately contain a genuine causal CHAIN for one entity
    # within a single batch (op N's `expected` equals op N-1's `value`) -- e.g.
    # several `wv touch` calls, or a multi-step `wv done`, throttled into one
    # auto_sync cycle. A single linear pass over op_paths sorted by filename
    # (UUID, not causal order) can apply the chain's LATER link before its
    # EARLIER one is even attempted: the later link's `expected` does not yet
    # match (the earlier hasn't landed), so it reports precondition_conflict
    # and, in the original single-pass design, that disposition was final --
    # silently freezing the entity at an intermediate value instead of the
    # true final one, with no error surfaced by default. Proven end-to-end
    # with adversarially reversed UUIDs, and independently confirmed already
    # present in this repository's own committed catalog (auto_sync throttling
    # batched several same-entity patches under one seq).
    #
    # The fix does not touch file order or add any new field to the wire
    # format: an op that conflicts is deferred, not finalized, and retried on
    # the next pass once some OTHER op in the same batch may have advanced the
    # row it depends on. The loop terminates the moment a full pass resolves
    # nothing further -- at most len(op_paths) passes, since every progressing
    # pass retires at least one path. Whatever is still precondition_conflict
    # at that fixed point is a REAL conflict (a genuinely stale precondition
    # against a properly later causal write, e.g. this repo's own existing
    # T04/T09/T13 conflict fixtures, each isolated with nothing else in their
    # batch that could ever resolve them) — not a batch-order artifact, and is
    # reported (or, under --strict, escalated) exactly as before.
    conn = sqlite3.connect(str(db_path))
    conn.executescript(TOMBSTONES_DDL)
    conn.execute("BEGIN")
    seen: dict[str, str] = {}
    results_by_path: dict[str, dict[str, Any]] = {}
    aborted = False
    try:  # pylint: disable=too-many-nested-blocks  # wv-237d25
        # Same-lineage collisions (round 4 finding 4) are resolved up front,
        # outside the fixed-point loop below: a colliding op has no
        # `expected` state it could ever converge to (that is what makes it
        # a collision, not a chain), so retrying it across passes would only
        # ever re-derive the same silent-order-dependent outcome the
        # dispatch loop's own convergence guarantee does not cover.
        collisions = _detect_lineage_collisions(op_paths)
        for path_str, (reason, op_id) in collisions.items():
            result = results_by_path.setdefault(path_str, {"path": path_str})
            result["disposition"] = "ambiguous_same_lineage"
            result["reason"] = reason
            # Round 5 finding: collision results omitted operation_id, unlike
            # every other disposition -- a caller correlating results back to
            # its own request-by-id has no way to match one up.
            if op_id:
                result["operation_id"] = op_id
        pending = [p for p in op_paths if str(p) not in collisions]
        while pending:
            still_pending: list[Path] = []
            made_progress = False
            for path in pending:
                result = results_by_path.setdefault(str(path), {"path": str(path)})
                try:
                    op = read_op(path)
                    op_id = str(op.get("operation_id", ""))
                    op_hash = str(op.get("operation_sha256", ""))
                    result["operation_id"] = op_id
                    validate_op(op)
                    if op_id in seen:
                        disp = "duplicate" if seen[op_id] == op_hash else "identity_hash_mismatch"
                    else:
                        disp = apply_op(conn, op, cutover_seq)
                        if disp == "precondition_conflict":
                            # Tentative: not yet recorded in `seen`, so this
                            # exact op_id can still be retried (and, once
                            # resolved, correctly caught as `duplicate` if a
                            # genuine repeat of it is encountered afterward).
                            result["disposition"] = disp
                            still_pending.append(path)
                            continue
                        seen[op_id] = op_hash
                except UnsupportedVersion as exc:
                    disp = "unsupported_version"
                    result["reason"] = str(exc)
                except (IntegrityError, sqlite3.Error) as exc:
                    disp = "integrity_failed"
                    result["reason"] = str(exc)
                result["disposition"] = disp
                made_progress = True
                if disp in HARD_DISPOSITIONS:
                    aborted = True
                    break
            if aborted:
                break
            if not made_progress:
                # Fixed point: nothing left in `still_pending` can ever apply
                # against what already committed this batch. Final.
                break
            pending = still_pending
        if not aborted and strict and any(
            r["disposition"] in ("precondition_conflict", "ambiguous_same_lineage")
            for r in results_by_path.values()
        ):
            aborted = True
        if aborted:
            conn.rollback()
        else:
            conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()
    results = [results_by_path[str(p)] for p in op_paths if str(p) in results_by_path]
    return {"results": results, "aborted": aborted}


def _summary(results: list[dict[str, Any]]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for result in results:
        counts[result["disposition"]] = counts.get(result["disposition"], 0) + 1
    return counts


def check(op_paths: list[Path]) -> dict[str, Any]:
    """Static pass over a catalog: every hard disposition decidable without a DB.

    evaluate() stops at the first hard failure and rolls the whole batch back,
    and `wv load` then warns and falls back to v1 unless WV_DELTA_V2_STRICT=1.
    One bad committed op therefore disables v2 replay on every clone, on every
    load, behind a warning scrolled past once. This is what `wv doctor` runs to
    make that state persistent-visible (wv-99c85a). It validates EVERY op, so a
    catalog with several bad ops lists them all, not just the first.
    """
    failures: list[dict[str, Any]] = []
    seen: dict[str, str] = {}
    for path in sorted(op_paths, key=lambda p: p.name):
        failure: dict[str, Any] = {"path": str(path)}
        try:
            op = read_op(path)
            op_id = str(op.get("operation_id", ""))
            op_hash = str(op.get("operation_sha256", ""))
            validate_op(op)
            if seen.setdefault(op_id, op_hash) != op_hash:
                failure["disposition"] = "identity_hash_mismatch"
                failure["reason"] = f"operation_id {op_id} seen with a different hash"
        except UnsupportedVersion as exc:
            failure.update(disposition="unsupported_version", reason=str(exc))
        except IntegrityError as exc:
            failure.update(disposition="integrity_failed", reason=str(exc))
        if "disposition" in failure:
            failures.append(failure)
    return {"checked": len(op_paths), "failures": failures}


def main(argv: list[str]) -> int:
    """Check operation files (--check) or replay them into a graph, printing the outcome as JSON."""
    if argv[:1] == ["--check"]:
        outcome = check([Path(p) for p in argv[1:]])
        print(json.dumps(outcome, sort_keys=True, separators=(",", ":")))
        return 2 if outcome["failures"] else 0
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("db", type=Path, help="SQLite graph database")
    parser.add_argument("operations", nargs="*", type=Path, help="Delta v2 operation JSON files")
    parser.add_argument("--cutover-seq", type=int, default=None,
                        help="skip operations whose lineage seq precedes this value")
    parser.add_argument("--strict", action="store_true",
                        help="treat precondition_conflict as a hard failure")
    # Intermixed: wv load passes "db --cutover-seq N ops...". Before Python 3.12
    # parse_args consumed both positionals at the first positional run and then
    # rejected the operations after the option, aborting every cutover replay on
    # 3.11 (wv-9d2036).
    args = parser.parse_intermixed_args(argv)
    outcome = evaluate(args.db, args.operations, cutover_seq=args.cutover_seq, strict=args.strict)
    outcome["summary"] = _summary(outcome["results"])
    print(json.dumps(outcome, sort_keys=True, separators=(",", ":")))
    return 2 if outcome["aborted"] else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
