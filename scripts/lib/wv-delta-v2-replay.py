#!/usr/bin/env python3
"""Non-dispatched Delta v2 replay/audit evaluator.

This is intentionally not wired into `wv load`. It validates Delta v2 operation
sidecars and applies the current node_patch subset to a candidate SQLite graph.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sqlite3
import sys
from pathlib import Path
from typing import Any


STATUSES = {"todo", "ready", "active", "blocked", "done"}
RISK_LEVELS = {"none", "low", "medium", "high"}
FIELDS = {"status", "claimed_by", "risk_level"}
UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
SHA_RE = re.compile(r"^[a-f0-9]{64}$")


class IntegrityError(ValueError):
    pass


class UnsupportedVersion(ValueError):
    pass


def canonical(value: Any) -> str:
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
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def read_op(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise IntegrityError(str(exc)) from exc
    if not isinstance(value, dict):
        raise IntegrityError("operation must be an object")
    return value


def validate_op(op: dict[str, Any]) -> None:
    if op.get("format") != "weave.delta.v2":
        raise UnsupportedVersion("unsupported format")
    if op.get("canonicalization") != "weave.canonical-json.v1":
        raise UnsupportedVersion("unsupported canonicalization")
    if not isinstance(op.get("operation_id"), str) or not UUID_RE.match(op["operation_id"]):
        raise IntegrityError("invalid operation_id")
    if not isinstance(op.get("actor_id"), str) or not op["actor_id"]:
        raise IntegrityError("invalid actor_id")
    if (
        not isinstance(op.get("actor_sequence"), int)
        or isinstance(op.get("actor_sequence"), bool)
        or op["actor_sequence"] < 0
    ):
        raise IntegrityError("invalid actor_sequence")
    if not isinstance(op.get("operation_sha256"), str) or not SHA_RE.match(op["operation_sha256"]):
        raise IntegrityError("invalid operation_sha256")
    payload = op.get("payload")
    if not isinstance(payload, dict):
        raise IntegrityError("invalid payload")
    entity = payload.get("entity")
    mutation = payload.get("mutation")
    if (
        not isinstance(entity, dict)
        or entity.get("kind") != "node"
        or not isinstance(entity.get("id"), str)
        or not entity["id"]
    ):
        raise IntegrityError("invalid entity")
    if not isinstance(mutation, dict) or mutation.get("kind") != "node_patch":
        raise UnsupportedVersion("unsupported mutation")
    fields = mutation.get("fields")
    if not isinstance(fields, dict) or not fields:
        raise IntegrityError("invalid fields")
    if set(fields) - FIELDS:
        raise UnsupportedVersion("unsupported field")
    for field, patch in fields.items():
        if not isinstance(patch, dict) or set(patch) != {"expected", "value"}:
            raise IntegrityError(f"invalid {field} patch")
        validate_field_value(field, patch["expected"])
        validate_field_value(field, patch["value"])

    preimage = dict(op)
    del preimage["operation_sha256"]
    if sha256_text(canonical(preimage)) != op["operation_sha256"]:
        raise IntegrityError("operation hash mismatch")


def validate_field_value(field: str, value: Any) -> None:
    if field == "status" and value not in STATUSES:
        raise IntegrityError("invalid status value")
    if field == "claimed_by" and not (value is None or (isinstance(value, str) and value)):
        raise IntegrityError("invalid claimed_by value")
    if field == "risk_level" and value not in RISK_LEVELS:
        raise IntegrityError("invalid risk_level value")


def metadata_from_raw(raw: str | None) -> dict[str, Any]:
    if not raw:
        return {}
    try:
        value = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    return value if isinstance(value, dict) else {}


def current_fields(conn: sqlite3.Connection, node_id: str) -> dict[str, Any] | None:
    row = conn.execute("SELECT status, metadata FROM nodes WHERE id = ?", (node_id,)).fetchone()
    if row is None:
        return None
    metadata = metadata_from_raw(row[1])
    claimed = metadata.get("claimed_by")
    risk = metadata.get("risk_level", "none")
    return {
        "status": row[0],
        "claimed_by": claimed if isinstance(claimed, str) and claimed else None,
        "risk_level": risk if isinstance(risk, str) and risk in RISK_LEVELS else "none",
    }


def apply_op(conn: sqlite3.Connection, op: dict[str, Any]) -> str:
    node_id = op["payload"]["entity"]["id"]
    fields = op["payload"]["mutation"]["fields"]
    current = current_fields(conn, node_id)
    if current is None:
        return "precondition_conflict"
    if all(current[field] == patch["value"] for field, patch in fields.items()):
        return "already_satisfied"
    if any(current[field] != patch["expected"] for field, patch in fields.items()):
        return "precondition_conflict"

    row = conn.execute("SELECT metadata FROM nodes WHERE id = ?", (node_id,)).fetchone()
    metadata = metadata_from_raw(row[0])
    sets: list[str] = []
    params: list[Any] = []
    if "status" in fields:
        sets.append("status = ?")
        params.append(fields["status"]["value"])
    if "claimed_by" in fields:
        value = fields["claimed_by"]["value"]
        if value is None:
            metadata.pop("claimed_by", None)
        else:
            metadata["claimed_by"] = value
    if "risk_level" in fields:
        value = fields["risk_level"]["value"]
        if value == "none":
            metadata.pop("risk_level", None)
        else:
            metadata["risk_level"] = value
    if "claimed_by" in fields or "risk_level" in fields:
        sets.append("metadata = ?")
        params.append(json.dumps(metadata, sort_keys=True, separators=(",", ":")))
    sets.append("updated_at = CURRENT_TIMESTAMP")
    params.append(node_id)
    conn.execute(f"UPDATE nodes SET {', '.join(sets)} WHERE id = ?", params)
    return "applied"


def evaluate(db_path: Path, op_paths: list[Path]) -> list[dict[str, Any]]:
    conn = sqlite3.connect(str(db_path))
    conn.execute("BEGIN")
    seen: dict[str, str] = {}
    results: list[dict[str, Any]] = []
    try:
        for path in op_paths:
            result: dict[str, Any] = {"path": str(path)}
            try:
                op = read_op(path)
                op_id = str(op.get("operation_id", ""))
                op_hash = str(op.get("operation_sha256", ""))
                result["operation_id"] = op_id
                validate_op(op)
                if op_id in seen:
                    result["disposition"] = (
                        "duplicate" if seen[op_id] == op_hash else "identity_hash_mismatch"
                    )
                else:
                    seen[op_id] = op_hash
                    result["disposition"] = apply_op(conn, op)
            except UnsupportedVersion as exc:
                result["disposition"] = "unsupported_version"
                result["reason"] = str(exc)
            except (IntegrityError, sqlite3.Error) as exc:
                result["disposition"] = "integrity_failed"
                result["reason"] = str(exc)
            results.append(result)
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()
    return results


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("db", type=Path, help="candidate SQLite graph database")
    parser.add_argument("operations", nargs="+", type=Path, help="Delta v2 operation JSON files")
    args = parser.parse_args(argv)
    results = evaluate(args.db, args.operations)
    print(json.dumps({"results": results}, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
