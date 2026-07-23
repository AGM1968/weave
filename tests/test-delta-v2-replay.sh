#!/usr/bin/env bash
# Regression tests for the non-dispatched Delta v2 replay/audit evaluator.

set -euo pipefail

export WV_CALL_SOURCE=test

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPLAY="$ROOT/scripts/lib/wv-delta-v2-replay.py"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
DB="$TMP/replay.db"
OPS="$TMP/ops"
mkdir -p "$OPS"

pass=0
run=0
ok() { echo "  ✓ $1"; pass=$((pass + 1)); run=$((run + 1)); }
bad() { echo "  ✗ $1"; run=$((run + 1)); }

sqlite3 "$DB" "
CREATE TABLE nodes(
    id TEXT PRIMARY KEY,
    text TEXT,
    status TEXT DEFAULT 'ready',
    metadata TEXT DEFAULT '{}',
    alias TEXT UNIQUE,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
);
INSERT INTO nodes(id,text,status,metadata,created_at,updated_at)
VALUES
  ('wv-replay','replay target','todo','{}','2026-07-19 00:00:00','2026-07-19 00:00:00'),
  ('wv-satisfied','already target','active','{\"claimed_by\":\"agent-a\",\"risk_level\":\"high\"}','2026-07-19 00:00:00','2026-07-19 00:00:00'),
  ('wv-conflict','conflict target','done','{}','2026-07-19 00:00:00','2026-07-19 00:00:00');
"

python3 - "$OPS" <<'PY'
import hashlib
import json
import pathlib
import sys
import uuid

out = pathlib.Path(sys.argv[1])


def canonical(value):
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
        return "{" + ",".join(canonical(str(key)) + ":" + canonical(value[key]) for key in sorted(value)) + "}"
    raise TypeError(type(value).__name__)


def write(name, node_id, fields, op_id=None, mutate=None):
    doc = {
        "format": "weave.delta.v2",
        "operation_id": op_id or str(uuid.uuid5(uuid.NAMESPACE_URL, name)),
        "actor_id": "agent-a",
        "actor_sequence": len(list(out.glob("*.json"))) + 1,
        "canonicalization": "weave.canonical-json.v1",
        "payload": {
            "entity": {"kind": "node", "id": node_id},
            "mutation": {"kind": "node_patch", "fields": fields},
        },
    }
    doc["operation_sha256"] = hashlib.sha256(canonical(doc).encode()).hexdigest()
    if mutate:
        mutate(doc)
    (out / name).write_text(canonical(doc) + "\n", encoding="utf-8")
    return doc


applied = write("01-applied.json", "wv-replay", {
    "status": {"expected": "todo", "value": "active"},
    "claimed_by": {"expected": None, "value": "agent-a"},
    "risk_level": {"expected": "none", "value": "high"},
})
(out / "02-duplicate.json").write_text(canonical(applied) + "\n", encoding="utf-8")
write("03-satisfied.json", "wv-satisfied", {
    "status": {"expected": "todo", "value": "active"},
    "claimed_by": {"expected": None, "value": "agent-a"},
    "risk_level": {"expected": "none", "value": "high"},
})
write("04-conflict.json", "wv-conflict", {
    "status": {"expected": "todo", "value": "active"},
})
write("05-bad-hash.json", "wv-conflict", {
    "status": {"expected": "done", "value": "active"},
}, mutate=lambda doc: doc.update(operation_sha256="a" * 64))
write("06-unsupported.json", "wv-conflict", {
    "status": {"expected": "done", "value": "active"},
}, mutate=lambda doc: doc.update(format="weave.delta.v3"))
write("07-same-id-different-hash.json", "wv-conflict", {
    "status": {"expected": "done", "value": "active"},
}, op_id=applied["operation_id"])
PY

result=$(python3 "$REPLAY" "$DB" "$OPS"/01-applied.json "$OPS"/02-duplicate.json "$OPS"/03-satisfied.json "$OPS"/04-conflict.json "$OPS"/05-bad-hash.json "$OPS"/06-unsupported.json "$OPS"/07-same-id-different-hash.json)

assert_disp() {
    local path="$1" expected="$2" message="$3"
    local actual
    actual=$(printf '%s' "$result" | jq -r --arg path "$path" '.results[] | select(.path == $path) | .disposition')
    [ "$actual" = "$expected" ] && ok "$message" || bad "$message"
}

assert_disp "$OPS/01-applied.json" "applied" "replay applies valid field-level CAS"
assert_disp "$OPS/02-duplicate.json" "duplicate" "replay deduplicates same operation_id and hash"
assert_disp "$OPS/03-satisfied.json" "already_satisfied" "replay reports already-satisfied patches"
assert_disp "$OPS/04-conflict.json" "precondition_conflict" "replay reports CAS precondition conflicts"
assert_disp "$OPS/05-bad-hash.json" "integrity_failed" "replay rejects invalid operation hashes"
assert_disp "$OPS/06-unsupported.json" "unsupported_version" "replay reports unsupported versions"
assert_disp "$OPS/07-same-id-different-hash.json" "identity_hash_mismatch" "replay hard-fails same-id/different-hash"

state=$(sqlite3 "$DB" "SELECT status || '|' || json_extract(metadata,'$.claimed_by') || '|' || json_extract(metadata,'$.risk_level') FROM nodes WHERE id='wv-replay';")
[ "$state" = "active|agent-a|high" ] && ok "candidate DB contains applied semantic fields" || bad "candidate DB contains applied semantic fields"

conflict_state=$(sqlite3 "$DB" "SELECT status FROM nodes WHERE id='wv-conflict';")
[ "$conflict_state" = "done" ] && ok "conflicted and invalid operations leave candidate DB unchanged" || bad "conflicted and invalid operations leave candidate DB unchanged"

sqlite3 "$DB" "
INSERT INTO nodes(id,text,status,metadata,created_at,updated_at)
VALUES ('wv-123abc','contract fixture target','todo','{}','2026-07-19 00:00:00','2026-07-19 00:00:00');
"
fixture_result=$(python3 "$REPLAY" "$DB" "$ROOT/tests/fixtures/ipc/v1/durability/delta-operation-v2.json")
fixture_disp=$(printf '%s' "$fixture_result" | jq -r '.results[0].disposition')
[ "$fixture_disp" = "applied" ] && ok "replay accepts shipped Delta v2 contract fixture" || bad "replay accepts shipped Delta v2 contract fixture"

echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
