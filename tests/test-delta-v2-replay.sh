#!/usr/bin/env bash
# Regression tests for the Delta v2 replay/CAS evaluator (dispatched by wv load).

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
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    lineage_actor TEXT NOT NULL DEFAULT '',
    lineage_seq INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE edges(
    source TEXT, target TEXT, type TEXT,
    weight REAL, context TEXT,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    lineage_actor TEXT NOT NULL DEFAULT '',
    lineage_seq INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY(source, target, type)
);
INSERT INTO nodes(id,text,status,metadata,created_at,updated_at,lineage_actor,lineage_seq) VALUES
  ('wv-replay','replay target','todo','{}','2026-07-19 00:00:00','2026-07-19 00:00:00','',0),
  ('wv-satisfied','already target','active','{\"claimed_by\":\"agent-a\",\"risk_level\":\"high\"}','2026-07-19 00:00:00','2026-07-19 00:00:00','agent-a',5),
  ('wv-conflict','conflict target','done','{}','2026-07-19 00:00:00','2026-07-19 00:00:00','',0),
  ('wv-text','old text','todo','{}','2026-07-19 00:00:00','2026-07-19 00:00:00','',0),
  ('wv-del','doomed','todo','{}','2026-07-19 00:00:00','2026-07-19 00:00:00','agent-a',3),
  ('wv-newer','survives stale delete','todo','{}','2026-07-19 00:00:00','2026-07-19 00:00:00','agent-z',10),
  ('wv-alias-target','already exists','todo','{}','2026-07-19 00:00:00','2026-07-19 00:00:00','agent-z',10),
  ('wv-alias-holder','holds the alias','todo','{}','2026-07-19 00:00:00','2026-07-19 00:00:00','agent-z',10);
UPDATE nodes SET alias='contested' WHERE id='wv-alias-holder';
INSERT INTO edges(source,target,type,weight,context,lineage_actor,lineage_seq) VALUES
  ('wv-replay','wv-satisfied','relates_to',1.0,'{}','',0);
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
        return "{" + ",".join(canonical(str(k)) + ":" + canonical(value[k]) for k in sorted(value)) + "}"
    raise TypeError(type(value).__name__)


def write(name, entity, mutation, seq, actor="agent-a", op_id=None, mutate=None):
    payload = {"entity": entity, "lineage": {"seq": seq, "actor": actor}, "mutation": mutation}
    doc = {
        "format": "weave.delta.v2",
        "operation_id": op_id or str(uuid.uuid5(uuid.NAMESPACE_URL, name)),
        "actor_id": actor,
        "actor_sequence": seq,
        "canonicalization": "weave.canonical-json.v1",
        "payload": payload,
    }
    doc["operation_sha256"] = hashlib.sha256(canonical(doc).encode()).hexdigest()
    if mutate:
        mutate(doc)
    (out / name).write_text(canonical(doc) + "\n", encoding="utf-8")
    return doc


node = lambda i: {"kind": "node", "id": i}
edge = lambda s, t, y: {"kind": "edge", "source": s, "target": t, "type": y}

applied = write("01-node-patch.json", node("wv-replay"), {"kind": "node_patch", "fields": {
    "status": {"expected": "todo", "value": "active"},
    "claimed_by": {"expected": None, "value": "agent-a"},
    "risk_level": {"expected": "none", "value": "high"},
}}, seq=2)
(out / "02-duplicate.json").write_text(canonical(applied) + "\n", encoding="utf-8")
write("03-satisfied.json", node("wv-satisfied"), {"kind": "node_patch", "fields": {
    "status": {"expected": "todo", "value": "active"},
    "claimed_by": {"expected": None, "value": "agent-a"},
    "risk_level": {"expected": "none", "value": "high"},
}}, seq=6)
write("04-conflict.json", node("wv-conflict"), {"kind": "node_patch", "fields": {
    "status": {"expected": "todo", "value": "active"},
}}, seq=6)
write("05-text.json", node("wv-text"), {"kind": "node_patch", "fields": {
    "text": {"expected": "old text", "value": "new text"},
}}, seq=6)
write("06-node-create.json", node("wv-brand-new"), {"kind": "node_create", "row": {
    "text": "fresh", "status": "todo", "metadata": {}, "alias": None, "created_at": "2026-07-20 00:00:00",
}}, seq=6)
write("07-node-delete.json", node("wv-del"), {"kind": "node_delete"}, seq=4)
write("08-recreate-superseded.json", node("wv-del"), {"kind": "node_create", "row": {
    "text": "zombie", "status": "todo", "metadata": {}, "alias": None, "created_at": "2026-07-20 00:00:00",
}}, seq=2)
write("09-stale-delete.json", node("wv-newer"), {"kind": "node_delete"}, seq=4)
# wv-29f6b2: a node_patch whose `expected` still matches but whose lineage is
# BELOW the row's own must be refused, never applied -- applying it would also
# regress lineage_seq and re-open the row to every stale v1 delta. wv-newer is
# `todo` at lineage (10, agent-z); this seq-5 patch expects `todo`. Seq
# deliberately differs from 09-stale-delete's (round 4 finding 3): these are
# two INDEPENDENT stale-write fixtures against the same target, not a
# same-batch delete+patch pair -- sharing a lineage would make the ambiguity
# detector correctly flag them as colliding non-chainable ops instead of
# letting each be refused on its own (real) staleness.
write("13-stale-lineage-patch.json", node("wv-newer"), {"kind": "node_patch", "fields": {
    "status": {"expected": "todo", "value": "blocked"},
}}, seq=5)
# The alias pre-clear a node_create issues must be lineage-guarded on the
# TARGET row too, not just applied then refused: wv-alias-target exists at
# (10, agent-z). This create at (3, agent-a) is going to be refused by its own
# guard -- it must not, on the way there, steal 'contested' off wv-alias-holder.
write("14-alias-steal-refused.json", node("wv-alias-target"), {"kind": "node_create", "row": {
    "text": "stale steal attempt", "status": "todo", "metadata": {}, "alias": "contested",
    "created_at": "2026-07-19 00:00:00",
}}, seq=3, actor="agent-a")
write("10-edge-patch.json", edge("wv-replay", "wv-satisfied", "relates_to"),
      {"kind": "edge_patch", "fields": {"weight": {"expected": "1.0", "value": "2.0"}}}, seq=6)
write("11-edge-create.json", edge("wv-conflict", "wv-text", "relates_to"),
      {"kind": "edge_create", "row": {"weight": "1.0", "context": "{}", "created_at": "2026-07-20 00:00:00"}}, seq=6)
write("12-edge-delete.json", edge("wv-replay", "wv-satisfied", "relates_to"),
      {"kind": "edge_delete"}, seq=7)

write("50-bad-hash.json", node("wv-conflict"), {"kind": "node_patch", "fields": {
    "status": {"expected": "done", "value": "active"},
}}, seq=6, mutate=lambda d: d.update(operation_sha256="a" * 64))
write("51-unsupported.json", node("wv-conflict"), {"kind": "node_patch", "fields": {
    "status": {"expected": "done", "value": "active"},
}}, seq=6, mutate=lambda d: d.update(format="weave.delta.v3"))
write("52-identity-mismatch.json", node("wv-conflict"), {"kind": "node_patch", "fields": {
    "status": {"expected": "done", "value": "blocked"},
}}, seq=6, op_id=applied["operation_id"])
write("60-pre-cutover.json", node("wv-replay"), {"kind": "node_patch", "fields": {
    "status": {"expected": "todo", "value": "blocked"},
}}, seq=3)
PY

disp() {
    printf '%s' "$1" | jq -r --arg p "$2" '.results[] | select(.path == $p) | .disposition'
}
assert_disp() {
    [ "$(disp "$1" "$OPS/$2")" = "$3" ] && ok "$4" || bad "$4 (got $(disp "$1" "$OPS/$2"))"
}

happy=$(python3 "$REPLAY" "$DB" \
    "$OPS"/01-node-patch.json "$OPS"/02-duplicate.json "$OPS"/03-satisfied.json \
    "$OPS"/04-conflict.json "$OPS"/05-text.json "$OPS"/06-node-create.json \
    "$OPS"/07-node-delete.json "$OPS"/08-recreate-superseded.json "$OPS"/09-stale-delete.json \
    "$OPS"/10-edge-patch.json "$OPS"/11-edge-create.json "$OPS"/12-edge-delete.json \
    "$OPS"/13-stale-lineage-patch.json "$OPS"/14-alias-steal-refused.json) || true

assert_disp "$happy" 01-node-patch.json applied "node_patch applies field-level CAS"
assert_disp "$happy" 02-duplicate.json duplicate "same operation_id + hash is a duplicate"
assert_disp "$happy" 03-satisfied.json already_satisfied "target already holds the new values"
assert_disp "$happy" 04-conflict.json precondition_conflict "expected preimage mismatch is reported, not applied"
assert_disp "$happy" 05-text.json applied "node_patch covers the text column"
assert_disp "$happy" 06-node-create.json applied "node_create inserts an absent node"
assert_disp "$happy" 07-node-delete.json applied "node_delete removes the row and writes a tombstone"
assert_disp "$happy" 08-recreate-superseded.json skipped_superseded "a create below the tombstone lineage does not resurrect"
assert_disp "$happy" 09-stale-delete.json precondition_conflict "a stale delete cannot remove a causally-newer row"
assert_disp "$happy" 13-stale-lineage-patch.json precondition_conflict "a stale-lineage node_patch is refused even when its expected preimage matches (wv-29f6b2)"
assert_disp "$happy" 14-alias-steal-refused.json precondition_conflict "a stale node_create whose own guard refuses is not applied"
assert_disp "$happy" 10-edge-patch.json applied "edge_patch applies weight/context CAS"
assert_disp "$happy" 11-edge-create.json applied "edge_create inserts an absent edge"
assert_disp "$happy" 12-edge-delete.json applied "edge_delete removes the edge and writes a tombstone"

aborted=$(printf '%s' "$happy" | jq -r '.aborted')
[ "$aborted" = "false" ] && ok "a batch of normal dispositions commits" || bad "a batch of normal dispositions commits"

state=$(sqlite3 "$DB" "SELECT status || '|' || json_extract(metadata,'\$.claimed_by') || '|' || json_extract(metadata,'\$.risk_level') || '|' || lineage_seq || '|' || lineage_actor FROM nodes WHERE id='wv-replay';")
[ "$state" = "active|agent-a|high|2|agent-a" ] && ok "applied node_patch stamps semantic fields and lineage" || bad "applied node_patch stamps semantic fields and lineage (got $state)"
[ "$(sqlite3 "$DB" "SELECT text FROM nodes WHERE id='wv-text';")" = "new text" ] && ok "text column mutation lands" || bad "text column mutation lands"
[ "$(sqlite3 "$DB" "SELECT count(*) FROM nodes WHERE id='wv-del';")" = "0" ] && ok "deleted node stays deleted" || bad "deleted node stays deleted"
[ "$(sqlite3 "$DB" "SELECT lineage_seq FROM tombstones WHERE kind='node' AND id='wv-del';")" = "4" ] && ok "node tombstone records the delete lineage" || bad "node tombstone records the delete lineage"
[ "$(sqlite3 "$DB" "SELECT status FROM nodes WHERE id='wv-conflict';")" = "done" ] && ok "conflicted op leaves its target unchanged" || bad "conflicted op leaves its target unchanged"
[ "$(sqlite3 "$DB" "SELECT weight FROM edges WHERE source='wv-conflict';")" = "1.0" ] && ok "edge_create lands" || bad "edge_create lands"
[ "$(sqlite3 "$DB" "SELECT count(*) FROM edges WHERE source='wv-replay';")" = "0" ] && ok "edge_delete lands" || bad "edge_delete lands"
newer=$(sqlite3 "$DB" "SELECT status || '|' || lineage_seq || '|' || lineage_actor FROM nodes WHERE id='wv-newer';")
[ "$newer" = "todo|10|agent-z" ] && ok "a stale-lineage patch neither mutates nor regresses the row (wv-29f6b2)" || bad "stale-lineage patch left wv-newer as $newer"
holder_alias=$(sqlite3 "$DB" "SELECT COALESCE(alias,'NULL') FROM nodes WHERE id='wv-alias-holder';")
target_alias=$(sqlite3 "$DB" "SELECT COALESCE(alias,'NULL') FROM nodes WHERE id='wv-alias-target';")
target_text=$(sqlite3 "$DB" "SELECT text FROM nodes WHERE id='wv-alias-target';")
[ "$holder_alias" = "contested" ] && [ "$target_alias" = "NULL" ] && [ "$target_text" = "already exists" ] \
    && ok "a refused node_create's alias pre-clear does not steal the alias off the causally newer holder" \
    || bad "alias pre-clear leaked: holder='$holder_alias' target_alias='$target_alias' target_text='$target_text'"

# ─────────────────────────────────────────────────────────────────────────────
# wv-4448a2 review round 2, finding 1: the guard above only checked whether the
# incoming create beats its TARGET row. wv-alias-target above already exists,
# so that case is covered -- but the holder is a DIFFERENT row from the
# target, and an ABSENT target says nothing about the holder's own lineage.
# wv-absent-alias-target below never existed before this op: prove a stale
# create for a target that does not exist yet still cannot steal a causally
# newer holder's alias.
sqlite3 "$DB" "INSERT INTO nodes(id,text,alias,created_at,updated_at,lineage_actor,lineage_seq) VALUES('wv-absent-holder','holds it',NULL,100,100,'agent-z',10);
UPDATE nodes SET alias='uncontested-until-now' WHERE id='wv-absent-holder';"
python3 - "$OPS" <<'PY'
import hashlib, json, pathlib, sys
out = pathlib.Path(sys.argv[1])
def canonical(v):
    if v is None: return "null"
    if isinstance(v, bool): return "true" if v else "false"
    if isinstance(v, int): return str(v)
    if isinstance(v, str): return json.dumps(v, ensure_ascii=False, separators=(",", ":"))
    if isinstance(v, list): return "[" + ",".join(canonical(i) for i in v) + "]"
    if isinstance(v, dict): return "{" + ",".join(canonical(str(k)) + ":" + canonical(v[k]) for k in sorted(v)) + "}"
    raise TypeError(type(v))
payload = {"entity": {"kind": "node", "id": "wv-absent-alias-target"},
           "lineage": {"seq": 3, "actor": "agent-a"},
           "mutation": {"kind": "node_create", "row": {
               "text": "stale absent-target create", "status": "todo", "metadata": {},
               "alias": "uncontested-until-now", "created_at": "2026-07-19 00:00:00"}}}
doc = {"format": "weave.delta.v2", "operation_id": "33333333-3333-1333-8333-333333333333",
       "actor_id": "agent-a", "actor_sequence": 3,
       "canonicalization": "weave.canonical-json.v1", "payload": payload}
doc["operation_sha256"] = hashlib.sha256(canonical(doc).encode()).hexdigest()
(out / "15-absent-target-alias-steal.json").write_text(json.dumps(doc) + "\n", encoding="utf-8")
PY
absent=$(python3 "$REPLAY" "$DB" "$OPS/15-absent-target-alias-steal.json")
absent_disp=$(disp "$absent" "$OPS/15-absent-target-alias-steal.json")
absent_holder_alias=$(sqlite3 "$DB" "SELECT COALESCE(alias,'NULL') FROM nodes WHERE id='wv-absent-holder';")
absent_target_alias=$(sqlite3 "$DB" "SELECT COALESCE(alias,'NULL') FROM nodes WHERE id='wv-absent-alias-target';")
[ "$absent_disp" = "applied" ] && [ "$absent_holder_alias" = "uncontested-until-now" ] && [ "$absent_target_alias" = "NULL" ] \
    && ok "an absent-target node_create cannot steal a causally newer holder's alias (wv-4448a2 review round 2)" \
    || bad "absent-target alias steal (disp=$absent_disp holder='$absent_holder_alias' target='$absent_target_alias')"

for spec in "50-bad-hash.json:integrity_failed:bad hash" "51-unsupported.json:unsupported_version:unknown format" "52-identity-mismatch.json:identity_hash_mismatch:same id different hash"; do
    file=${spec%%:*}; rest=${spec#*:}; want=${rest%%:*}; label=${rest#*:}
    before=$(sqlite3 "$DB" "SELECT status FROM nodes WHERE id='wv-conflict';")
    res=$(python3 "$REPLAY" "$DB" "$OPS/01-node-patch.json" "$OPS/$file" 2>/dev/null) && rc=0 || rc=$?
    got=$(disp "$res" "$OPS/$file")
    ab=$(printf '%s' "$res" | jq -r '.aborted')
    after=$(sqlite3 "$DB" "SELECT status FROM nodes WHERE id='wv-conflict';")
    [ "$got" = "$want" ] && [ "$ab" = "true" ] && [ "$rc" = "2" ] && [ "$before" = "$after" ] \
        && ok "$label rolls back the whole batch and exits 2" \
        || bad "$label rolls back the whole batch and exits 2 (disp=$got aborted=$ab rc=$rc)"
done

pre=$(python3 "$REPLAY" "$DB" --cutover-seq 8 "$OPS/60-pre-cutover.json")
assert_disp "$pre" 60-pre-cutover.json skipped_pre_cutover "lineage below the causal cutover is skipped"

strict=$(python3 "$REPLAY" "$DB" --strict "$OPS/04-conflict.json" 2>/dev/null) || true
[ "$(printf '%s' "$strict" | jq -r '.aborted')" = "true" ] \
    && ok "--strict promotes precondition_conflict to a batch abort" \
    || bad "--strict promotes precondition_conflict to a batch abort"

sqlite3 "$DB" "INSERT INTO nodes(id,text,status,metadata,created_at,updated_at) VALUES('wv-123abc','contract fixture target','todo','{}','2026-07-19 00:00:00','2026-07-19 00:00:00');"
fixture=$(python3 "$REPLAY" "$DB" "$ROOT/tests/fixtures/ipc/v1/durability/delta-operation-v2.json")
[ "$(printf '%s' "$fixture" | jq -r '.results[0].disposition')" = "applied" ] \
    && ok "replay accepts the shipped Delta v2 contract fixture" \
    || bad "replay accepts the shipped Delta v2 contract fixture"

# ─────────────────────────────────────────────────────────────────────────────
# wv-4448a2 review round 2, finding 2: every op in one emission shares a
# single lineage tuple by design (wv-cdb45a/wv-4a05e7), so a batch can
# legitimately contain a causal CHAIN for one entity -- op N's `expected`
# equals op N-1's `value`. The loader used to process op_paths in a single
# linear pass sorted by filename (UUID, not causal order): a chain's LATER
# link applied before its EARLIER one conflicts (its `expected` does not yet
# match) and, in the original design, that disposition was final -- silently
# freezing the entity at an intermediate value. Proven with a deliberately
# REVERSED UUID order (the later link's file sorts first): the fixed-point
# retry must still converge to the chain's true final value regardless.
CHAIN_DB="$TMP/chain.db"
sqlite3 "$CHAIN_DB" "
CREATE TABLE nodes(id TEXT PRIMARY KEY, text TEXT, status TEXT DEFAULT 'ready', metadata TEXT DEFAULT '{}', alias TEXT UNIQUE, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP, lineage_actor TEXT NOT NULL DEFAULT '', lineage_seq INTEGER NOT NULL DEFAULT 0);
CREATE TABLE edges(source TEXT, target TEXT, type TEXT, weight REAL, context TEXT, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, lineage_actor TEXT NOT NULL DEFAULT '', lineage_seq INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(source, target, type));
INSERT INTO nodes(id,text,created_at,updated_at,lineage_actor,lineage_seq) VALUES('wv-chain','A','2026-07-19 00:00:00','2026-07-19 00:00:00','',0);
"
CHAIN_OPS="$TMP/chain-ops"
mkdir -p "$CHAIN_OPS"
python3 - "$CHAIN_OPS" <<'PY'
import hashlib, json, pathlib, sys
out = pathlib.Path(sys.argv[1])
def canonical(v):
    if v is None: return "null"
    if isinstance(v, bool): return "true" if v else "false"
    if isinstance(v, int): return str(v)
    if isinstance(v, str): return json.dumps(v, ensure_ascii=False, separators=(",", ":"))
    if isinstance(v, list): return "[" + ",".join(canonical(i) for i in v) + "]"
    if isinstance(v, dict): return "{" + ",".join(canonical(str(k)) + ":" + canonical(v[k]) for k in sorted(v)) + "}"
    raise TypeError(type(v))
def write(name, expected, value, opid):
    payload = {"entity": {"kind": "node", "id": "wv-chain"}, "lineage": {"seq": 9, "actor": "agent-a"},
               "mutation": {"kind": "node_patch", "fields": {"text": {"expected": expected, "value": value}}}}
    doc = {"format": "weave.delta.v2", "operation_id": opid, "actor_id": "agent-a", "actor_sequence": 9,
           "canonicalization": "weave.canonical-json.v1", "payload": payload}
    doc["operation_sha256"] = hashlib.sha256(canonical(doc).encode()).hexdigest()
    (out / f"000000000009-{opid}.json").write_text(json.dumps(doc) + "\n", encoding="utf-8")
# Deliberately reversed: the LAST link's uuid ("11...") sorts before the
# FIRST link's ("99...") under a plain filename sort.
write("chain", "A", "B", "99999999-9999-1999-8999-999999999999")
write("chain", "B", "C", "77777777-7777-1777-8777-777777777777")
write("chain", "C", "D", "11111111-1111-1111-8111-111111111111")
PY
chain_paths=$(find "$CHAIN_OPS" -name '*.json' | LC_ALL=C sort)
chain_result=$(python3 "$REPLAY" "$CHAIN_DB" $chain_paths)
chain_final=$(sqlite3 "$CHAIN_DB" "SELECT text FROM nodes WHERE id='wv-chain';")
chain_applied=$(printf '%s' "$chain_result" | jq -r '[.results[].disposition] | map(select(.=="applied")) | length')
[ "$chain_final" = "D" ] && [ "$chain_applied" = "3" ] \
    && ok "a same-entity causal chain converges to its true final value under adversarially reversed UUID order (wv-4448a2 review round 2)" \
    || bad "reverse-UUID chain convergence (final='$chain_final' applied=$chain_applied result=$chain_result)"

# ─────────────────────────────────────────────────────────────────────────────
# wv-4448a2 review round 3, finding 3: alias arbitration against the REAL
# production constraint. Every DB above uses `alias TEXT UNIQUE`, a plain
# column constraint. The actual schema (scripts/lib/wv-db.sh) is a PARTIAL
# unique index -- alias IS NOT NULL AND status != 'done' -- so a done row's
# alias is never enforced unique at all. Built fresh here so a bug the
# plain-UNIQUE fixtures above cannot see is not concealed here too.
PARTIAL_DB="$TMP/partial.db"
sqlite3 "$PARTIAL_DB" "
CREATE TABLE nodes(id TEXT PRIMARY KEY, text TEXT, status TEXT DEFAULT 'ready', metadata TEXT DEFAULT '{}', alias TEXT, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP, lineage_actor TEXT NOT NULL DEFAULT '', lineage_seq INTEGER NOT NULL DEFAULT 0);
CREATE UNIQUE INDEX idx_nodes_alias ON nodes(alias) WHERE alias IS NOT NULL AND status != 'done';
CREATE TABLE edges(source TEXT, target TEXT, type TEXT, weight REAL, context TEXT, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, lineage_actor TEXT NOT NULL DEFAULT '', lineage_seq INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(source, target, type));
INSERT INTO nodes(id,text,status,alias,created_at,updated_at,lineage_actor,lineage_seq) VALUES
  ('wv-p3-done-holder','closed row','done','reusable',100,100,'agent-z',10),
  ('wv-p3-fresh','fresh target','todo',NULL,1,1,'',0),
  ('wv-p3-old-holder','stale holder','todo','claimed',100,100,'agent-z',1),
  ('wv-p3-patch-target','patch target','todo',NULL,50,50,'',0),
  ('wv-p3-newer-holder','fresh holder','todo','contested',100,100,'agent-z',99),
  ('wv-p3-patch-target2','patch target 2','todo',NULL,50,50,'',0),
  ('wv-p3-active-holder','active holder','todo','samealias',100,100,'agent-z',1),
  ('wv-p3-reactivate','closed then reopened','done','samealias',50,50,'',0);
"
PARTIAL_OPS="$TMP/partial-ops"
mkdir -p "$PARTIAL_OPS"
python3 - "$PARTIAL_OPS" <<'PY'
import hashlib, json, pathlib, sys, uuid
out = pathlib.Path(sys.argv[1])
def canonical(v):
    if v is None: return "null"
    if isinstance(v, bool): return "true" if v else "false"
    if isinstance(v, int): return str(v)
    if isinstance(v, str): return json.dumps(v, ensure_ascii=False, separators=(",", ":"))
    if isinstance(v, list): return "[" + ",".join(canonical(i) for i in v) + "]"
    if isinstance(v, dict): return "{" + ",".join(canonical(str(k)) + ":" + canonical(v[k]) for k in sorted(v)) + "}"
    raise TypeError(type(v))
def write(name, entity, mutation, seq, actor="agent-a"):
    payload = {"entity": entity, "lineage": {"seq": seq, "actor": actor}, "mutation": mutation}
    doc = {"format": "weave.delta.v2", "operation_id": str(uuid.uuid5(uuid.NAMESPACE_URL, name)),
           "actor_id": actor, "actor_sequence": seq,
           "canonicalization": "weave.canonical-json.v1", "payload": payload}
    doc["operation_sha256"] = hashlib.sha256(canonical(doc).encode()).hexdigest()
    (out / f"{name}.json").write_text(json.dumps(doc) + "\n", encoding="utf-8")
node = lambda i: {"kind": "node", "id": i}

# 3b: a done node's alias is not a real holder -- a fresh node_create can
# take the same alias text uncontested.
write("p3-a-done-not-holder", node("wv-p3-fresh"),
      {"kind": "node_create", "row": {"text": "fresh target", "status": "todo", "metadata": {}, "alias": "reusable", "created_at": 1}},
      seq=5)

# 3a path 1: node_patch changing alias to a value held by a causally-OLDER
# holder must clear it and land the new value (direct repro of the original
# `UNIQUE constraint failed: nodes.alias`, now fixed).
write("p3-b-patch-steal-older", node("wv-p3-patch-target"),
      {"kind": "node_patch", "fields": {"alias": {"expected": None, "value": "claimed"}}},
      seq=5)

# 3a reverse guard: cannot steal off a causally-NEWER holder -- drops to
# NULL, no IntegrityError, no batch abort.
write("p3-c-patch-cannot-steal-newer", node("wv-p3-patch-target2"),
      {"kind": "node_patch", "fields": {"alias": {"expected": None, "value": "contested"}}},
      seq=5)

# 3a entry path 2: alias UNCHANGED but status leaves 'done' -- the row is
# newly entering the partial index and must arbitrate against a live holder.
write("p3-d-reactivate-arbitrates", node("wv-p3-reactivate"),
      {"kind": "node_patch", "fields": {"status": {"expected": "done", "value": "todo"}}},
      seq=5)
PY

p3_result=$(python3 "$REPLAY" "$PARTIAL_DB" \
    "$PARTIAL_OPS/p3-a-done-not-holder.json" \
    "$PARTIAL_OPS/p3-b-patch-steal-older.json" \
    "$PARTIAL_OPS/p3-c-patch-cannot-steal-newer.json" \
    "$PARTIAL_OPS/p3-d-reactivate-arbitrates.json") || true

p3_disp() { disp "$p3_result" "$PARTIAL_OPS/$1"; }

[ "$(p3_disp p3-a-done-not-holder.json)" = "applied" ] \
    && ok "v2 node_create: a done node's alias is not a real holder (round 3 finding 3b)" \
    || bad "v2 node_create done-holder exemption (disp=$(p3_disp p3-a-done-not-holder.json))"
p3a_done_holder=$(sqlite3 "$PARTIAL_DB" "SELECT COALESCE(alias,'NULL') FROM nodes WHERE id='wv-p3-done-holder';")
p3a_fresh=$(sqlite3 "$PARTIAL_DB" "SELECT COALESCE(alias,'NULL') FROM nodes WHERE id='wv-p3-fresh';")
[ "$p3a_done_holder" = "reusable" ] && [ "$p3a_fresh" = "reusable" ] \
    && ok "v2 node_create: done holder keeps its alias, fresh node also gets it, no contention" \
    || bad "v2 done-holder coexistence (done='$p3a_done_holder' fresh='$p3a_fresh')"

[ "$(p3_disp p3-b-patch-steal-older.json)" = "applied" ] \
    && ok "v2 node_patch alias arbitration exists and applies (round 3 finding 3a)" \
    || bad "v2 node_patch alias arbitration (disp=$(p3_disp p3-b-patch-steal-older.json))"
p3b_old_holder=$(sqlite3 "$PARTIAL_DB" "SELECT COALESCE(alias,'NULL') FROM nodes WHERE id='wv-p3-old-holder';")
p3b_patched=$(sqlite3 "$PARTIAL_DB" "SELECT COALESCE(alias,'NULL') FROM nodes WHERE id='wv-p3-patch-target';")
p3b_holder_lineage=$(sqlite3 "$PARTIAL_DB" "SELECT lineage_seq || ',' || lineage_actor FROM nodes WHERE id='wv-p3-old-holder';")
[ "$p3b_old_holder" = "NULL" ] && [ "$p3b_patched" = "claimed" ] && [ "$p3b_holder_lineage" = "5,agent-a" ] \
    && ok "v2 node_patch clears a causally-older holder, lands the new alias, and stamps the holder's lineage (round 3 finding 3a/3c)" \
    || bad "v2 node_patch steal (old_holder='$p3b_old_holder' patched='$p3b_patched' holder_lineage='$p3b_holder_lineage')"

[ "$(p3_disp p3-c-patch-cannot-steal-newer.json)" = "applied" ] \
    && ok "v2 node_patch losing an alias contest still applies (no IntegrityError abort)" \
    || bad "v2 node_patch contest-loss disposition (disp=$(p3_disp p3-c-patch-cannot-steal-newer.json))"
p3c_newer_holder=$(sqlite3 "$PARTIAL_DB" "SELECT COALESCE(alias,'NULL') FROM nodes WHERE id='wv-p3-newer-holder';")
p3c_patched=$(sqlite3 "$PARTIAL_DB" "SELECT COALESCE(alias,'NULL') FROM nodes WHERE id='wv-p3-patch-target2';")
[ "$p3c_newer_holder" = "contested" ] && [ "$p3c_patched" = "NULL" ] \
    && ok "v2 node_patch cannot steal an alias off a causally-newer holder (round 3 finding 3a reverse guard)" \
    || bad "v2 node_patch reverse guard (newer_holder='$p3c_newer_holder' patched='$p3c_patched')"

[ "$(p3_disp p3-d-reactivate-arbitrates.json)" = "applied" ] \
    && ok "v2 node_patch done->active reentry applies" \
    || bad "v2 node_patch done->active reentry disposition (disp=$(p3_disp p3-d-reactivate-arbitrates.json))"
p3d_active_holder=$(sqlite3 "$PARTIAL_DB" "SELECT COALESCE(alias,'NULL') FROM nodes WHERE id='wv-p3-active-holder';")
p3d_reactivate_alias=$(sqlite3 "$PARTIAL_DB" "SELECT COALESCE(alias,'NULL') FROM nodes WHERE id='wv-p3-reactivate';")
p3d_reactivate_status=$(sqlite3 "$PARTIAL_DB" "SELECT status FROM nodes WHERE id='wv-p3-reactivate';")
[ "$p3d_active_holder" = "NULL" ] && [ "$p3d_reactivate_alias" = "samealias" ] && [ "$p3d_reactivate_status" = "todo" ] \
    && ok "v2 node_patch: a done->active status transition with an unchanged alias arbitrates against a live holder (round 3 finding 3a, entry path 2)" \
    || bad "v2 done->active reentry arbitration (active_holder='$p3d_active_holder' alias='$p3d_reactivate_alias' status='$p3d_reactivate_status')"

# ─────────────────────────────────────────────────────────────────────────────
# wv-4448a2 review round 4, finding 3: target_wins was computed in
# _apply_node_create but never gated the holder query/clear -- only the LATER
# precondition_conflict return did, by which point a losing create had
# already cleared and re-stamped a causally-newer holder's alias. A conflict
# disposition must have no side effects. Direct repro of the reviewer's exact
# scenario: incoming (5,a) loses to an existing target at (20,z); the alias
# holder at (1,a) must be untouched.
R4_DB="$TMP/r4.db"
sqlite3 "$R4_DB" "
CREATE TABLE nodes(id TEXT PRIMARY KEY, text TEXT, status TEXT DEFAULT 'ready', metadata TEXT DEFAULT '{}', alias TEXT UNIQUE, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP, lineage_actor TEXT NOT NULL DEFAULT '', lineage_seq INTEGER NOT NULL DEFAULT 0);
CREATE TABLE edges(source TEXT, target TEXT, type TEXT, weight REAL, context TEXT, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, lineage_actor TEXT NOT NULL DEFAULT '', lineage_seq INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(source, target, type));
INSERT INTO nodes(id,text,status,alias,created_at,updated_at,lineage_actor,lineage_seq) VALUES
  ('wv-r4-target','existing target','todo',NULL,10,10,'z',20),
  ('wv-r4-holder','alias holder','todo','contested-r4',5,5,'a',1);
"
R4_OPS="$TMP/r4-ops"
mkdir -p "$R4_OPS"
python3 - "$R4_OPS" <<'PY'
import hashlib, json, pathlib, sys
out = pathlib.Path(sys.argv[1])
def canonical(v):
    if v is None: return "null"
    if isinstance(v, bool): return "true" if v else "false"
    if isinstance(v, int): return str(v)
    if isinstance(v, str): return json.dumps(v, ensure_ascii=False, separators=(",", ":"))
    if isinstance(v, list): return "[" + ",".join(canonical(i) for i in v) + "]"
    if isinstance(v, dict): return "{" + ",".join(canonical(str(k)) + ":" + canonical(v[k]) for k in sorted(v)) + "}"
    raise TypeError(type(v))
payload = {"entity": {"kind": "node", "id": "wv-r4-target"},
           "lineage": {"seq": 5, "actor": "a"},
           "mutation": {"kind": "node_create", "row": {
               "text": "stale losing create", "status": "todo", "metadata": {},
               "alias": "contested-r4", "created_at": 1}}}
doc = {"format": "weave.delta.v2", "operation_id": "44444444-4444-1444-8444-444444444444",
       "actor_id": "a", "actor_sequence": 5,
       "canonicalization": "weave.canonical-json.v1", "payload": payload}
doc["operation_sha256"] = hashlib.sha256(canonical(doc).encode()).hexdigest()
(out / "r4-losing-create.json").write_text(json.dumps(doc) + "\n", encoding="utf-8")
PY
r4_result=$(python3 "$REPLAY" "$R4_DB" "$R4_OPS/r4-losing-create.json") || true
r4_disp=$(disp "$r4_result" "$R4_OPS/r4-losing-create.json")
r4_holder=$(sqlite3 "$R4_DB" "SELECT COALESCE(alias,'NULL') || '|' || lineage_seq || '|' || lineage_actor FROM nodes WHERE id='wv-r4-holder';")
[ "$r4_disp" = "precondition_conflict" ] && [ "$r4_holder" = "contested-r4|1|a" ] \
    && ok "a v2 node_create that loses its own guard has no side effect on an alias holder (round 4 finding 3)" \
    || bad "target_wins not gating holder clear (disp=$r4_disp holder='$r4_holder')"

# ─────────────────────────────────────────────────────────────────────────────
# wv-4448a2 review round 4, finding 6: _apply_node_patch/_apply_edge_patch
# returned already_satisfied without advancing the row's own lineage when
# every field already matched. A value-identical op at a HIGH seq was then
# acknowledged without recording that seq, leaving the row's lineage exactly
# where it was -- a stale delete below the new op's lineage but above the
# row's un-advanced one could still remove it afterward.
R4B_DB="$TMP/r4b.db"
sqlite3 "$R4B_DB" "
CREATE TABLE nodes(id TEXT PRIMARY KEY, text TEXT, status TEXT DEFAULT 'ready', metadata TEXT DEFAULT '{}', alias TEXT UNIQUE, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP, lineage_actor TEXT NOT NULL DEFAULT '', lineage_seq INTEGER NOT NULL DEFAULT 0);
CREATE TABLE edges(source TEXT, target TEXT, type TEXT, weight REAL, context TEXT, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, lineage_actor TEXT NOT NULL DEFAULT '', lineage_seq INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(source, target, type));
INSERT INTO nodes(id,text,status,created_at,updated_at,lineage_actor,lineage_seq) VALUES
  ('wv-r4b-node','already there','active',1,1,'z',3);
"
R4B_OPS="$TMP/r4b-ops"
mkdir -p "$R4B_OPS"
python3 - "$R4B_OPS" <<'PY'
import hashlib, json, pathlib, sys
out = pathlib.Path(sys.argv[1])
def canonical(v):
    if v is None: return "null"
    if isinstance(v, bool): return "true" if v else "false"
    if isinstance(v, int): return str(v)
    if isinstance(v, str): return json.dumps(v, ensure_ascii=False, separators=(",", ":"))
    if isinstance(v, list): return "[" + ",".join(canonical(i) for i in v) + "]"
    if isinstance(v, dict): return "{" + ",".join(canonical(str(k)) + ":" + canonical(v[k]) for k in sorted(v)) + "}"
    raise TypeError(type(v))
def write(name, opid, seq):
    payload = {"entity": {"kind": "node", "id": "wv-r4b-node"}, "lineage": {"seq": seq, "actor": "z"},
               "mutation": {"kind": "node_patch", "fields": {"status": {"expected": "active", "value": "active"}}}}
    doc = {"format": "weave.delta.v2", "operation_id": opid, "actor_id": "z", "actor_sequence": seq,
           "canonicalization": "weave.canonical-json.v1", "payload": payload}
    doc["operation_sha256"] = hashlib.sha256(canonical(doc).encode()).hexdigest()
    (out / name).write_text(json.dumps(doc) + "\n", encoding="utf-8")
write("r4b-already-satisfied.json", "55555555-5555-1555-8555-555555555555", 10)
PY
r4b_result=$(python3 "$REPLAY" "$R4B_DB" "$R4B_OPS/r4b-already-satisfied.json") || true
r4b_disp=$(disp "$r4b_result" "$R4B_OPS/r4b-already-satisfied.json")
r4b_lineage=$(sqlite3 "$R4B_DB" "SELECT lineage_seq || ',' || lineage_actor FROM nodes WHERE id='wv-r4b-node';")
[ "$r4b_disp" = "already_satisfied" ] && [ "$r4b_lineage" = "10,z" ] \
    && ok "already_satisfied node_patch still advances the row's lineage (round 4 finding 6)" \
    || bad "already_satisfied lineage stamp (disp=$r4b_disp lineage='$r4b_lineage')"
# A stale seq-5 delete, below the new op's lineage but above the row's OLD
# (3,z), must now be refused: the already_satisfied stamp above already
# advanced the row past it.
sqlite3 "$R4B_DB" "DELETE FROM nodes WHERE id='wv-r4b-node' AND (lineage_seq = 0 OR (lineage_seq, lineage_actor) <= (5,'z'));"
r4b_survived=$(sqlite3 "$R4B_DB" "SELECT COUNT(*) FROM nodes WHERE id='wv-r4b-node';")
[ "$r4b_survived" = "1" ] \
    && ok "a stale delete the already_satisfied stamp already superseded is refused" \
    || bad "stale delete after already_satisfied stamp (survived=$r4b_survived)"
# The lineage must never REGRESS: an already_satisfied op below the row's
# current lineage leaves it untouched.
sqlite3 "$R4B_DB" "UPDATE nodes SET lineage_seq=99, lineage_actor='later' WHERE id='wv-r4b-node';"
R4B_OPS2="$TMP/r4b-ops2"
mkdir -p "$R4B_OPS2"
python3 - "$R4B_OPS2" <<'PY'
import hashlib, json, pathlib, sys
out = pathlib.Path(sys.argv[1])
def canonical(v):
    if v is None: return "null"
    if isinstance(v, bool): return "true" if v else "false"
    if isinstance(v, int): return str(v)
    if isinstance(v, str): return json.dumps(v, ensure_ascii=False, separators=(",", ":"))
    if isinstance(v, list): return "[" + ",".join(canonical(i) for i in v) + "]"
    if isinstance(v, dict): return "{" + ",".join(canonical(str(k)) + ":" + canonical(v[k]) for k in sorted(v)) + "}"
    raise TypeError(type(v))
payload = {"entity": {"kind": "node", "id": "wv-r4b-node"}, "lineage": {"seq": 10, "actor": "z"},
           "mutation": {"kind": "node_patch", "fields": {"status": {"expected": "active", "value": "active"}}}}
doc = {"format": "weave.delta.v2", "operation_id": "66666666-6666-1666-8666-666666666666",
       "actor_id": "z", "actor_sequence": 10,
       "canonicalization": "weave.canonical-json.v1", "payload": payload}
doc["operation_sha256"] = hashlib.sha256(canonical(doc).encode()).hexdigest()
(out / "r4b-behind.json").write_text(json.dumps(doc) + "\n", encoding="utf-8")
PY
r4b2_result=$(python3 "$REPLAY" "$R4B_DB" "$R4B_OPS2/r4b-behind.json") || true
r4b2_disp=$(disp "$r4b2_result" "$R4B_OPS2/r4b-behind.json")
r4b2_lineage=$(sqlite3 "$R4B_DB" "SELECT lineage_seq || ',' || lineage_actor FROM nodes WHERE id='wv-r4b-node';")
[ "$r4b2_disp" = "already_satisfied" ] && [ "$r4b2_lineage" = "99,later" ] \
    && ok "already_satisfied never regresses a row's lineage below what it already has" \
    || bad "already_satisfied regression guard (disp=$r4b2_disp lineage='$r4b2_lineage')"

# ─────────────────────────────────────────────────────────────────────────────
# wv-4448a2 review round 4, finding 4: two ops sharing ONE (entity, lineage)
# that do NOT chain (both assume the SAME starting state) are order-dependent
# -- exactly one silently wins by file-order luck, discarding the other with
# no trace. This is not hypothetical: this repository's own wv-806a6b lost a
# full learning/decision/pattern/pitfall payload to precisely this shape (a
# rich `wv done --learning=...` metadata replace raced a bare status=done
# patch into one throttled sync batch; the bare one won, recovered from git
# history and reapplied at a fresh lineage). Direct repro of that shape:
# both ops expect status='active' (neither depends on the other's result);
# one carries a learning payload, one does not.
R4C_DB="$TMP/r4c.db"
sqlite3 "$R4C_DB" "
CREATE TABLE nodes(id TEXT PRIMARY KEY, text TEXT, status TEXT DEFAULT 'ready', metadata TEXT DEFAULT '{}', alias TEXT UNIQUE, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP, lineage_actor TEXT NOT NULL DEFAULT '', lineage_seq INTEGER NOT NULL DEFAULT 0);
CREATE TABLE edges(source TEXT, target TEXT, type TEXT, weight REAL, context TEXT, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, lineage_actor TEXT NOT NULL DEFAULT '', lineage_seq INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(source, target, type));
INSERT INTO nodes(id,text,status,metadata,created_at,updated_at,lineage_actor,lineage_seq) VALUES ('wv-806-repro','re-baseline task','active','{}',1,1,'',0);
"
R4C_OPS="$TMP/r4c-ops"
mkdir -p "$R4C_OPS"
python3 - "$R4C_OPS" <<'PY'
import hashlib, json, pathlib, sys
out = pathlib.Path(sys.argv[1])
def canonical(v):
    if v is None: return "null"
    if isinstance(v, bool): return "true" if v else "false"
    if isinstance(v, int): return str(v)
    if isinstance(v, str): return json.dumps(v, ensure_ascii=False, separators=(",", ":"))
    if isinstance(v, list): return "[" + ",".join(canonical(i) for i in v) + "]"
    if isinstance(v, dict): return "{" + ",".join(canonical(str(k)) + ":" + canonical(v[k]) for k in sorted(v)) + "}"
    raise TypeError(type(v))
def write(name, opid, fields):
    payload = {"entity": {"kind": "node", "id": "wv-806-repro"}, "lineage": {"seq": 27, "actor": "agent-a"},
               "mutation": {"kind": "node_patch", "fields": fields}}
    doc = {"format": "weave.delta.v2", "operation_id": opid, "actor_id": "agent-a", "actor_sequence": 27,
           "canonicalization": "weave.canonical-json.v1", "payload": payload}
    doc["operation_sha256"] = hashlib.sha256(canonical(doc).encode()).hexdigest()
    (out / name).write_text(json.dumps(doc) + "\n", encoding="utf-8")
write("aaaaaaaa-repro.json", "aaaaaaaa-0000-1000-8000-000000000001",
      {"status": {"expected": "active", "value": "done"},
       "metadata": {"expected": {}, "value": {"learning": "rich payload"}}})
# "z" is not a hex digit -- operation_id must match UUID_RE, so the second
# op's id uses "e" (still sorts after "aaaaaaaa"). An earlier version of
# this fixture used a literal "zzzzzzzz" id, which validate_op() rejects;
# that defect was itself masked until round 4 finding 2 made
# _detect_lineage_collisions call validate_op at all.
write("zzzzzzzz-repro.json", "eeeeeeee-0000-1000-8000-000000000002",
      {"status": {"expected": "active", "value": "done"}})
PY
r4c_result=$(python3 "$REPLAY" "$R4C_DB" "$R4C_OPS/aaaaaaaa-repro.json" "$R4C_OPS/zzzzzzzz-repro.json") || true
r4c_disp_a=$(disp "$r4c_result" "$R4C_OPS/aaaaaaaa-repro.json")
r4c_disp_z=$(disp "$r4c_result" "$R4C_OPS/zzzzzzzz-repro.json")
r4c_state=$(sqlite3 "$R4C_DB" "SELECT status || '|' || metadata FROM nodes WHERE id='wv-806-repro';")
[ "$r4c_disp_a" = "ambiguous_same_lineage" ] && [ "$r4c_disp_z" = "ambiguous_same_lineage" ] \
    && ok "two non-chaining same-lineage ops are both flagged ambiguous_same_lineage, not silently resolved by file order (round 4 finding 4)" \
    || bad "collision not detected (disp_a=$r4c_disp_a disp_z=$r4c_disp_z)"
[ "$r4c_state" = "active|{}" ] \
    && ok "neither op in a detected collision is applied -- the row is left untouched, not silently mutated to whichever won file order" \
    || bad "collision leaked a mutation: state='$r4c_state'"

# The reverse-UUID CHAIN test above (wv-chain, A->B->C->D) must still
# converge normally: a genuine chain has DIFFERENT expected values per link,
# so it is never mistaken for a collision by this detector.
[ "$chain_final" = "D" ] \
    && ok "the ambiguity detector does not false-positive on a genuine causal chain (distinct expected values per link)" \
    || bad "chain regressed by collision detector (final='$chain_final')"

# A repeated operation_id (the SAME op appearing twice, e.g. a legitimate
# retry) must be classified as duplicate/applied, never ambiguous_same_lineage
# -- it is not a second op racing the first.
r4d_result=$(python3 "$REPLAY" "$DB" "$OPS/01-node-patch.json" "$OPS/02-duplicate.json")
r4d_disp01=$(disp "$r4d_result" "$OPS/01-node-patch.json")
r4d_disp02=$(disp "$r4d_result" "$OPS/02-duplicate.json")
[ "$r4d_disp01" != "ambiguous_same_lineage" ] && [ "$r4d_disp02" = "duplicate" ] \
    && ok "a repeated operation_id is still classified as a duplicate, not a collision" \
    || bad "duplicate misclassified as collision (disp01=$r4d_disp01 disp02=$r4d_disp02)"

# ─────────────────────────────────────────────────────────────────────────────
# wv-4448a2 review round 4 verdict 2, finding 2: _detect_lineage_collisions
# read ops without calling validate_op, so a bad-hash (tampered/corrupt) op
# sharing an (entity, lineage) group with a legitimate sibling was
# classified ambiguous_same_lineage (soft, no rollback) instead of
# integrity_failed (hard, rolls back and exits non-zero) -- bypassing the
# SAME hash check every other op in the batch is held to. Direct repro: one
# valid op and one bad-hash op sharing entity+lineage.
R4E_DB="$TMP/r4e.db"
sqlite3 "$R4E_DB" "
CREATE TABLE nodes(id TEXT PRIMARY KEY, text TEXT, status TEXT DEFAULT 'ready', metadata TEXT DEFAULT '{}', alias TEXT UNIQUE, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP, lineage_actor TEXT NOT NULL DEFAULT '', lineage_seq INTEGER NOT NULL DEFAULT 0);
CREATE TABLE edges(source TEXT, target TEXT, type TEXT, weight REAL, context TEXT, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, lineage_actor TEXT NOT NULL DEFAULT '', lineage_seq INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(source, target, type));
INSERT INTO nodes(id,text,status,metadata,created_at,updated_at,lineage_actor,lineage_seq) VALUES ('wv-r4e','validation bypass target','active','{}',1,1,'',0);
"
R4E_OPS="$TMP/r4e-ops"
mkdir -p "$R4E_OPS"
python3 - "$R4E_OPS" <<'PY'
import hashlib, json, pathlib, sys
out = pathlib.Path(sys.argv[1])
def canonical(v):
    if v is None: return "null"
    if isinstance(v, bool): return "true" if v else "false"
    if isinstance(v, int): return str(v)
    if isinstance(v, str): return json.dumps(v, ensure_ascii=False, separators=(",", ":"))
    if isinstance(v, list): return "[" + ",".join(canonical(i) for i in v) + "]"
    if isinstance(v, dict): return "{" + ",".join(canonical(str(k)) + ":" + canonical(v[k]) for k in sorted(v)) + "}"
    raise TypeError(type(v))
def make(opid, status_value):
    payload = {"entity": {"kind": "node", "id": "wv-r4e"}, "lineage": {"seq": 11, "actor": "agent-a"},
               "mutation": {"kind": "node_patch", "fields": {"status": {"expected": "active", "value": status_value}}}}
    doc = {"format": "weave.delta.v2", "operation_id": opid, "actor_id": "agent-a", "actor_sequence": 11,
           "canonicalization": "weave.canonical-json.v1", "payload": payload}
    doc["operation_sha256"] = hashlib.sha256(canonical(doc).encode()).hexdigest()
    return doc
valid = make("11111111-2222-1000-8000-000000000001", "done")
(out / "r4e-valid.json").write_text(json.dumps(valid) + "\n", encoding="utf-8")
tampered = make("22222222-3333-1000-8000-000000000002", "blocked")
tampered["operation_sha256"] = "a" * 64
(out / "r4e-badhash.json").write_text(json.dumps(tampered) + "\n", encoding="utf-8")
PY
r4e_result=$(python3 "$REPLAY" "$R4E_DB" "$R4E_OPS/r4e-valid.json" "$R4E_OPS/r4e-badhash.json" 2>/dev/null) || true
r4e_disp_valid=$(disp "$r4e_result" "$R4E_OPS/r4e-valid.json")
r4e_disp_bad=$(disp "$r4e_result" "$R4E_OPS/r4e-badhash.json")
r4e_aborted=$(printf '%s' "$r4e_result" | jq -r '.aborted')
[ "$r4e_disp_bad" = "integrity_failed" ] && [ "$r4e_aborted" = "true" ] \
    && ok "a bad-hash op sharing a lineage group with a valid op still gets integrity_failed and aborts the batch (round 4 finding 2)" \
    || bad "validation bypassed by collision grouping (disp_valid=$r4e_disp_valid disp_bad=$r4e_disp_bad aborted=$r4e_aborted)"

# ─────────────────────────────────────────────────────────────────────────────
# wv-4448a2 review round 4 verdict 2, finding 3: the collision detector only
# checked patch/patch field-name overlap, missing two real shapes.
#
# (a) node_create carries no expected/value chain at all -- two creates for
# the SAME id+lineage are order-dependent by construction, not just
# undetected by the field-overlap check. Proven both orderings converge to
# ambiguous_same_lineage now, instead of whichever file sorts first winning.
R4F_OPS="$TMP/r4f-ops"
mkdir -p "$R4F_OPS"
python3 - "$R4F_OPS" <<'PY'
import hashlib, json, pathlib, sys
out = pathlib.Path(sys.argv[1])
def canonical(v):
    if v is None: return "null"
    if isinstance(v, bool): return "true" if v else "false"
    if isinstance(v, int): return str(v)
    if isinstance(v, str): return json.dumps(v, ensure_ascii=False, separators=(",", ":"))
    if isinstance(v, list): return "[" + ",".join(canonical(i) for i in v) + "]"
    if isinstance(v, dict): return "{" + ",".join(canonical(str(k)) + ":" + canonical(v[k]) for k in sorted(v)) + "}"
    raise TypeError(type(v))
def write(name, opid, text):
    payload = {"entity": {"kind": "node", "id": "wv-r4f"}, "lineage": {"seq": 6, "actor": "agent-a"},
               "mutation": {"kind": "node_create", "row": {"text": text, "status": "todo", "metadata": {}, "alias": None, "created_at": 1}}}
    doc = {"format": "weave.delta.v2", "operation_id": opid, "actor_id": "agent-a", "actor_sequence": 6,
           "canonicalization": "weave.canonical-json.v1", "payload": payload}
    doc["operation_sha256"] = hashlib.sha256(canonical(doc).encode()).hexdigest()
    (out / name).write_text(json.dumps(doc) + "\n", encoding="utf-8")
write("r4f-b.json", "33333333-4444-1000-8000-000000000001", "B")
write("r4f-c.json", "44444444-5555-1000-8000-000000000002", "C")
PY
R4F_DB1="$TMP/r4f1.db"
sqlite3 "$R4F_DB1" "CREATE TABLE nodes(id TEXT PRIMARY KEY, text TEXT, status TEXT DEFAULT 'ready', metadata TEXT DEFAULT '{}', alias TEXT UNIQUE, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP, lineage_actor TEXT NOT NULL DEFAULT '', lineage_seq INTEGER NOT NULL DEFAULT 0); CREATE TABLE edges(source TEXT, target TEXT, type TEXT, weight REAL, context TEXT, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, lineage_actor TEXT NOT NULL DEFAULT '', lineage_seq INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(source, target, type));"
r4f_result1=$(python3 "$REPLAY" "$R4F_DB1" "$R4F_OPS/r4f-b.json" "$R4F_OPS/r4f-c.json") || true
r4f_disp_b1=$(disp "$r4f_result1" "$R4F_OPS/r4f-b.json")
r4f_disp_c1=$(disp "$r4f_result1" "$R4F_OPS/r4f-c.json")
r4f_state1=$(sqlite3 "$R4F_DB1" "SELECT COUNT(*) FROM nodes WHERE id='wv-r4f';")
R4F_DB2="$TMP/r4f2.db"
sqlite3 "$R4F_DB2" "CREATE TABLE nodes(id TEXT PRIMARY KEY, text TEXT, status TEXT DEFAULT 'ready', metadata TEXT DEFAULT '{}', alias TEXT UNIQUE, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP, lineage_actor TEXT NOT NULL DEFAULT '', lineage_seq INTEGER NOT NULL DEFAULT 0); CREATE TABLE edges(source TEXT, target TEXT, type TEXT, weight REAL, context TEXT, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, lineage_actor TEXT NOT NULL DEFAULT '', lineage_seq INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(source, target, type));"
r4f_result2=$(python3 "$REPLAY" "$R4F_DB2" "$R4F_OPS/r4f-c.json" "$R4F_OPS/r4f-b.json") || true
r4f_disp_b2=$(disp "$r4f_result2" "$R4F_OPS/r4f-b.json")
r4f_disp_c2=$(disp "$r4f_result2" "$R4F_OPS/r4f-c.json")
r4f_state2=$(sqlite3 "$R4F_DB2" "SELECT COUNT(*) FROM nodes WHERE id='wv-r4f';")
[ "$r4f_disp_b1" = "ambiguous_same_lineage" ] && [ "$r4f_disp_c1" = "ambiguous_same_lineage" ] && [ "$r4f_state1" = "0" ] \
    && [ "$r4f_disp_b2" = "ambiguous_same_lineage" ] && [ "$r4f_disp_c2" = "ambiguous_same_lineage" ] && [ "$r4f_state2" = "0" ] \
    && ok "two node_creates for the same id+lineage are flagged ambiguous_same_lineage in BOTH file orders, not order-dependently applied (round 4 finding 3a)" \
    || bad "create/create collision order-dependent (order1: b=$r4f_disp_b1 c=$r4f_disp_c1 rows=$r4f_state1; order2: b=$r4f_disp_b2 c=$r4f_disp_c2 rows=$r4f_state2)"

# (b) `metadata` (whole replace) and `claimed_by`/`risk_level` (sugar keys)
# mutate the SAME physical metadata column under DIFFERENT field names --
# comparing literal key names missed this. This is the exact shape that
# cost wv-806a6b its learning payload. Proven both orderings now refuse
# rather than silently merge-or-lose depending on which file sorts first.
R4G_OPS="$TMP/r4g-ops"
mkdir -p "$R4G_OPS"
python3 - "$R4G_OPS" <<'PY'
import hashlib, json, pathlib, sys
out = pathlib.Path(sys.argv[1])
def canonical(v):
    if v is None: return "null"
    if isinstance(v, bool): return "true" if v else "false"
    if isinstance(v, int): return str(v)
    if isinstance(v, str): return json.dumps(v, ensure_ascii=False, separators=(",", ":"))
    if isinstance(v, list): return "[" + ",".join(canonical(i) for i in v) + "]"
    if isinstance(v, dict): return "{" + ",".join(canonical(str(k)) + ":" + canonical(v[k]) for k in sorted(v)) + "}"
    raise TypeError(type(v))
def write(name, opid, fields):
    payload = {"entity": {"kind": "node", "id": "wv-r4g"}, "lineage": {"seq": 12, "actor": "agent-a"},
               "mutation": {"kind": "node_patch", "fields": fields}}
    doc = {"format": "weave.delta.v2", "operation_id": opid, "actor_id": "agent-a", "actor_sequence": 12,
           "canonicalization": "weave.canonical-json.v1", "payload": payload}
    doc["operation_sha256"] = hashlib.sha256(canonical(doc).encode()).hexdigest()
    (out / name).write_text(json.dumps(doc) + "\n", encoding="utf-8")
write("r4g-meta.json", "55555555-6666-1000-8000-000000000001",
      {"metadata": {"expected": {"foo": 1}, "value": {"foo": 1, "bar": 2}}})
write("r4g-claimed.json", "66666666-7777-1000-8000-000000000002",
      {"claimed_by": {"expected": None, "value": "agent-x"}})
PY
mkdb_r4g() {
    sqlite3 "$1" "
CREATE TABLE nodes(id TEXT PRIMARY KEY, text TEXT, status TEXT DEFAULT 'ready', metadata TEXT DEFAULT '{}', alias TEXT UNIQUE, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP, lineage_actor TEXT NOT NULL DEFAULT '', lineage_seq INTEGER NOT NULL DEFAULT 0);
CREATE TABLE edges(source TEXT, target TEXT, type TEXT, weight REAL, context TEXT, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, lineage_actor TEXT NOT NULL DEFAULT '', lineage_seq INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(source, target, type));
INSERT INTO nodes(id,text,status,metadata,created_at,updated_at,lineage_actor,lineage_seq) VALUES ('wv-r4g','sugar overlap','active','{\"foo\":1}',1,1,'',0);
"
}
R4G_DB1="$TMP/r4g1.db"; mkdb_r4g "$R4G_DB1"
r4g_result1=$(python3 "$REPLAY" "$R4G_DB1" "$R4G_OPS/r4g-meta.json" "$R4G_OPS/r4g-claimed.json") || true
r4g_disp_meta1=$(disp "$r4g_result1" "$R4G_OPS/r4g-meta.json")
r4g_disp_claimed1=$(disp "$r4g_result1" "$R4G_OPS/r4g-claimed.json")
r4g_state1=$(sqlite3 "$R4G_DB1" "SELECT metadata FROM nodes WHERE id='wv-r4g';")
R4G_DB2="$TMP/r4g2.db"; mkdb_r4g "$R4G_DB2"
r4g_result2=$(python3 "$REPLAY" "$R4G_DB2" "$R4G_OPS/r4g-claimed.json" "$R4G_OPS/r4g-meta.json") || true
r4g_disp_meta2=$(disp "$r4g_result2" "$R4G_OPS/r4g-meta.json")
r4g_disp_claimed2=$(disp "$r4g_result2" "$R4G_OPS/r4g-claimed.json")
r4g_state2=$(sqlite3 "$R4G_DB2" "SELECT metadata FROM nodes WHERE id='wv-r4g';")
[ "$r4g_disp_meta1" = "ambiguous_same_lineage" ] && [ "$r4g_disp_claimed1" = "ambiguous_same_lineage" ] && [ "$r4g_state1" = '{"foo":1}' ] \
    && [ "$r4g_disp_meta2" = "ambiguous_same_lineage" ] && [ "$r4g_disp_claimed2" = "ambiguous_same_lineage" ] && [ "$r4g_state2" = '{"foo":1}' ] \
    && ok "a whole-metadata replace and a claimed_by sugar patch on the same entity+lineage collide in BOTH orders instead of silently merging or losing a field (round 4 finding 3b)" \
    || bad "metadata/sugar collision order-dependent (order1: meta=$r4g_disp_meta1 claimed=$r4g_disp_claimed1 state='$r4g_state1'; order2: meta=$r4g_disp_meta2 claimed=$r4g_disp_claimed2 state='$r4g_state2')"

# Every collision result now carries operation_id like every other
# disposition (round 5 finding: collision results omitted it, unlike normal
# results) -- a caller correlating results back to its own request-by-id had
# no way to match a collision up.
r4g_opid_meta=$(printf '%s' "$r4g_result1" | jq -r --arg p "$R4G_OPS/r4g-meta.json" '.results[] | select(.path == $p) | .operation_id')
[ "$r4g_opid_meta" = "55555555-6666-1000-8000-000000000001" ] \
    && ok "an ambiguous_same_lineage result carries operation_id like every other disposition (round 5)" \
    || bad "ambiguous_same_lineage result missing/wrong operation_id (got '$r4g_opid_meta')"

# ─────────────────────────────────────────────────────────────────────────────
# wv-4448a2 review round 5. Round 4's collision detector over-corrected: ANY
# group mixing a create with a patch was flagged ambiguous_same_lineage,
# including a legitimate create-then-patch chain within one emission (e.g. a
# single throttled auto_sync batching `wv add` immediately followed by `wv
# claim`/`wv touch` on the row it just created). Distinguish that chain from
# two genuinely competing creates.
R5A_OPS="$TMP/r5a-ops"
mkdir -p "$R5A_OPS"
python3 - "$R5A_OPS" <<'PY'
import hashlib, json, pathlib, sys
out = pathlib.Path(sys.argv[1])
def canonical(v):
    if v is None: return "null"
    if isinstance(v, bool): return "true" if v else "false"
    if isinstance(v, int): return str(v)
    if isinstance(v, str): return json.dumps(v, ensure_ascii=False, separators=(",", ":"))
    if isinstance(v, list): return "[" + ",".join(canonical(i) for i in v) + "]"
    if isinstance(v, dict): return "{" + ",".join(canonical(str(k)) + ":" + canonical(v[k]) for k in sorted(v)) + "}"
    raise TypeError(type(v))
def write(name, opid, mutation):
    payload = {"entity": {"kind": "node", "id": "wv-r5a"}, "lineage": {"seq": 30, "actor": "agent-a"},
               "mutation": mutation}
    doc = {"format": "weave.delta.v2", "operation_id": opid, "actor_id": "agent-a", "actor_sequence": 30,
           "canonicalization": "weave.canonical-json.v1", "payload": payload}
    doc["operation_sha256"] = hashlib.sha256(canonical(doc).encode()).hexdigest()
    (out / name).write_text(json.dumps(doc) + "\n", encoding="utf-8")
write("r5a-create.json", "77777777-1111-1000-8000-000000000001", {"kind": "node_create", "row": {
    "text": "fresh from one batch", "status": "todo", "metadata": {}, "alias": None,
    "created_at": "2026-09-05 00:00:00",
}})
write("r5a-patch.json", "88888888-2222-1000-8000-000000000002", {"kind": "node_patch", "fields": {
    "status": {"expected": "todo", "value": "active"},
}})
PY
mkdb_r5a() {
    sqlite3 "$1" "
CREATE TABLE nodes(id TEXT PRIMARY KEY, text TEXT, status TEXT DEFAULT 'ready', metadata TEXT DEFAULT '{}', alias TEXT UNIQUE, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP, lineage_actor TEXT NOT NULL DEFAULT '', lineage_seq INTEGER NOT NULL DEFAULT 0);
CREATE TABLE edges(source TEXT, target TEXT, type TEXT, weight REAL, context TEXT, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, lineage_actor TEXT NOT NULL DEFAULT '', lineage_seq INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(source, target, type));
"
}
R5A_DB1="$TMP/r5a1.db"; mkdb_r5a "$R5A_DB1"
r5a_result1=$(python3 "$REPLAY" "$R5A_DB1" "$R5A_OPS/r5a-create.json" "$R5A_OPS/r5a-patch.json") || true
r5a_disp_create1=$(disp "$r5a_result1" "$R5A_OPS/r5a-create.json")
r5a_disp_patch1=$(disp "$r5a_result1" "$R5A_OPS/r5a-patch.json")
r5a_state1=$(sqlite3 "$R5A_DB1" "SELECT status FROM nodes WHERE id='wv-r5a';")
R5A_DB2="$TMP/r5a2.db"; mkdb_r5a "$R5A_DB2"
r5a_result2=$(python3 "$REPLAY" "$R5A_DB2" "$R5A_OPS/r5a-patch.json" "$R5A_OPS/r5a-create.json") || true
r5a_disp_create2=$(disp "$r5a_result2" "$R5A_OPS/r5a-create.json")
r5a_disp_patch2=$(disp "$r5a_result2" "$R5A_OPS/r5a-patch.json")
r5a_state2=$(sqlite3 "$R5A_DB2" "SELECT status FROM nodes WHERE id='wv-r5a';")
[ "$r5a_disp_create1" = "applied" ] && [ "$r5a_disp_patch1" = "applied" ] && [ "$r5a_state1" = "active" ] \
    && [ "$r5a_disp_create2" = "applied" ] && [ "$r5a_disp_patch2" = "applied" ] && [ "$r5a_state2" = "active" ] \
    && ok "a node_create followed by a node_patch on the row it just created converges to the patched state in BOTH file orders, not flagged ambiguous_same_lineage (round 5)" \
    || bad "create-then-patch chain misclassified (order1: create=$r5a_disp_create1 patch=$r5a_disp_patch1 state=$r5a_state1; order2: create=$r5a_disp_create2 patch=$r5a_disp_patch2 state=$r5a_state2)"

# Two competing creates for the same id+lineage are still, correctly, a
# collision -- this must not regress from the fix above.
R5A2_OPS="$TMP/r5a2-ops"
mkdir -p "$R5A2_OPS"
python3 - "$R5A2_OPS" <<'PY'
import hashlib, json, pathlib, sys
out = pathlib.Path(sys.argv[1])
def canonical(v):
    if v is None: return "null"
    if isinstance(v, bool): return "true" if v else "false"
    if isinstance(v, int): return str(v)
    if isinstance(v, str): return json.dumps(v, ensure_ascii=False, separators=(",", ":"))
    if isinstance(v, list): return "[" + ",".join(canonical(i) for i in v) + "]"
    if isinstance(v, dict): return "{" + ",".join(canonical(str(k)) + ":" + canonical(v[k]) for k in sorted(v)) + "}"
    raise TypeError(type(v))
def write(name, opid, text):
    payload = {"entity": {"kind": "node", "id": "wv-r5a2"}, "lineage": {"seq": 31, "actor": "agent-a"},
               "mutation": {"kind": "node_create", "row": {
                   "text": text, "status": "todo", "metadata": {}, "alias": None,
                   "created_at": "2026-09-05 00:00:00"}}}
    doc = {"format": "weave.delta.v2", "operation_id": opid, "actor_id": "agent-a", "actor_sequence": 31,
           "canonicalization": "weave.canonical-json.v1", "payload": payload}
    doc["operation_sha256"] = hashlib.sha256(canonical(doc).encode()).hexdigest()
    (out / name).write_text(json.dumps(doc) + "\n", encoding="utf-8")
write("r5a2-first.json", "99999999-3333-1000-8000-000000000001", "first create")
write("r5a2-second.json", "99999999-4444-1000-8000-000000000002", "second create")
PY
R5A2_DB="$TMP/r5a2-competing.db"
sqlite3 "$R5A2_DB" "
CREATE TABLE nodes(id TEXT PRIMARY KEY, text TEXT, status TEXT DEFAULT 'ready', metadata TEXT DEFAULT '{}', alias TEXT UNIQUE, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP, lineage_actor TEXT NOT NULL DEFAULT '', lineage_seq INTEGER NOT NULL DEFAULT 0);
CREATE TABLE edges(source TEXT, target TEXT, type TEXT, weight REAL, context TEXT, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, lineage_actor TEXT NOT NULL DEFAULT '', lineage_seq INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(source, target, type));
"
r5a2_result=$(python3 "$REPLAY" "$R5A2_DB" "$R5A2_OPS/r5a2-first.json" "$R5A2_OPS/r5a2-second.json") || true
r5a2_disp_first=$(disp "$r5a2_result" "$R5A2_OPS/r5a2-first.json")
r5a2_disp_second=$(disp "$r5a2_result" "$R5A2_OPS/r5a2-second.json")
r5a2_rows=$(sqlite3 "$R5A2_DB" "SELECT COUNT(*) FROM nodes WHERE id='wv-r5a2';")
[ "$r5a2_disp_first" = "ambiguous_same_lineage" ] && [ "$r5a2_disp_second" = "ambiguous_same_lineage" ] && [ "$r5a2_rows" = "0" ] \
    && ok "two competing node_creates for the same id+lineage still collide (round 5 fix did not regress round 4 finding 3a)" \
    || bad "competing creates no longer flagged as a collision (first=$r5a2_disp_first second=$r5a2_disp_second rows=$r5a2_rows)"

# A valid multi-field patch chain (both links touch text AND status) was
# rejected outright because len(keys_i) != 1 compared ALL shared columns at
# once instead of each column's own expected/value transition (round 5
# finding).
R5B_OPS="$TMP/r5b-ops"
mkdir -p "$R5B_OPS"
python3 - "$R5B_OPS" <<'PY'
import hashlib, json, pathlib, sys
out = pathlib.Path(sys.argv[1])
def canonical(v):
    if v is None: return "null"
    if isinstance(v, bool): return "true" if v else "false"
    if isinstance(v, int): return str(v)
    if isinstance(v, str): return json.dumps(v, ensure_ascii=False, separators=(",", ":"))
    if isinstance(v, list): return "[" + ",".join(canonical(i) for i in v) + "]"
    if isinstance(v, dict): return "{" + ",".join(canonical(str(k)) + ":" + canonical(v[k]) for k in sorted(v)) + "}"
    raise TypeError(type(v))
def write(name, opid, fields):
    payload = {"entity": {"kind": "node", "id": "wv-r5b"}, "lineage": {"seq": 32, "actor": "agent-a"},
               "mutation": {"kind": "node_patch", "fields": fields}}
    doc = {"format": "weave.delta.v2", "operation_id": opid, "actor_id": "agent-a", "actor_sequence": 32,
           "canonicalization": "weave.canonical-json.v1", "payload": payload}
    doc["operation_sha256"] = hashlib.sha256(canonical(doc).encode()).hexdigest()
    (out / name).write_text(json.dumps(doc) + "\n", encoding="utf-8")
write("r5b-link1.json", "aaaaaaaa-5555-1000-8000-000000000001", {
    "text": {"expected": "A", "value": "B"},
    "status": {"expected": "todo", "value": "active"},
})
write("r5b-link2.json", "bbbbbbbb-6666-1000-8000-000000000002", {
    "text": {"expected": "B", "value": "C"},
    "status": {"expected": "active", "value": "done"},
})
PY
mkdb_r5b() {
    sqlite3 "$1" "
CREATE TABLE nodes(id TEXT PRIMARY KEY, text TEXT, status TEXT DEFAULT 'ready', metadata TEXT DEFAULT '{}', alias TEXT UNIQUE, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP, lineage_actor TEXT NOT NULL DEFAULT '', lineage_seq INTEGER NOT NULL DEFAULT 0);
CREATE TABLE edges(source TEXT, target TEXT, type TEXT, weight REAL, context TEXT, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, lineage_actor TEXT NOT NULL DEFAULT '', lineage_seq INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(source, target, type));
INSERT INTO nodes(id,text,status,metadata,created_at,updated_at,lineage_actor,lineage_seq) VALUES ('wv-r5b','A','todo','{}',1,1,'',0);
"
}
R5B_DB1="$TMP/r5b1.db"; mkdb_r5b "$R5B_DB1"
r5b_result1=$(python3 "$REPLAY" "$R5B_DB1" "$R5B_OPS/r5b-link1.json" "$R5B_OPS/r5b-link2.json") || true
r5b_disp1_1=$(disp "$r5b_result1" "$R5B_OPS/r5b-link1.json")
r5b_disp1_2=$(disp "$r5b_result1" "$R5B_OPS/r5b-link2.json")
r5b_state1=$(sqlite3 "$R5B_DB1" "SELECT text || '|' || status FROM nodes WHERE id='wv-r5b';")
R5B_DB2="$TMP/r5b2.db"; mkdb_r5b "$R5B_DB2"
r5b_result2=$(python3 "$REPLAY" "$R5B_DB2" "$R5B_OPS/r5b-link2.json" "$R5B_OPS/r5b-link1.json") || true
r5b_disp2_1=$(disp "$r5b_result2" "$R5B_OPS/r5b-link1.json")
r5b_disp2_2=$(disp "$r5b_result2" "$R5B_OPS/r5b-link2.json")
r5b_state2=$(sqlite3 "$R5B_DB2" "SELECT text || '|' || status FROM nodes WHERE id='wv-r5b';")
[ "$r5b_disp1_1" = "applied" ] && [ "$r5b_disp1_2" = "applied" ] && [ "$r5b_state1" = "C|done" ] \
    && [ "$r5b_disp2_1" = "applied" ] && [ "$r5b_disp2_2" = "applied" ] && [ "$r5b_state2" = "C|done" ] \
    && ok "a two-field (text+status) patch chain converges to the final link's values in BOTH file orders, not flagged ambiguous_same_lineage (round 5)" \
    || bad "multi-field patch chain misclassified (order1: l1=$r5b_disp1_1 l2=$r5b_disp1_2 state=$r5b_state1; order2: l1=$r5b_disp2_1 l2=$r5b_disp2_2 state=$r5b_state2)"

# Genuinely colliding multi-field patches (both links assume the SAME
# starting state) must still be caught -- this must not regress either.
R5B2_OPS="$TMP/r5b2-ops"
mkdir -p "$R5B2_OPS"
python3 - "$R5B2_OPS" <<'PY'
import hashlib, json, pathlib, sys
out = pathlib.Path(sys.argv[1])
def canonical(v):
    if v is None: return "null"
    if isinstance(v, bool): return "true" if v else "false"
    if isinstance(v, int): return str(v)
    if isinstance(v, str): return json.dumps(v, ensure_ascii=False, separators=(",", ":"))
    if isinstance(v, list): return "[" + ",".join(canonical(i) for i in v) + "]"
    if isinstance(v, dict): return "{" + ",".join(canonical(str(k)) + ":" + canonical(v[k]) for k in sorted(v)) + "}"
    raise TypeError(type(v))
def write(name, opid, fields):
    payload = {"entity": {"kind": "node", "id": "wv-r5b2"}, "lineage": {"seq": 33, "actor": "agent-a"},
               "mutation": {"kind": "node_patch", "fields": fields}}
    doc = {"format": "weave.delta.v2", "operation_id": opid, "actor_id": "agent-a", "actor_sequence": 33,
           "canonicalization": "weave.canonical-json.v1", "payload": payload}
    doc["operation_sha256"] = hashlib.sha256(canonical(doc).encode()).hexdigest()
    (out / name).write_text(json.dumps(doc) + "\n", encoding="utf-8")
write("r5b2-a.json", "cccccccc-7777-1000-8000-000000000001", {
    "text": {"expected": "A", "value": "B"},
    "status": {"expected": "todo", "value": "active"},
})
write("r5b2-b.json", "dddddddd-8888-1000-8000-000000000002", {
    "text": {"expected": "A", "value": "Z"},
    "status": {"expected": "todo", "value": "blocked"},
})
PY
R5B2_DB="$TMP/r5b2-colliding.db"
sqlite3 "$R5B2_DB" "
CREATE TABLE nodes(id TEXT PRIMARY KEY, text TEXT, status TEXT DEFAULT 'ready', metadata TEXT DEFAULT '{}', alias TEXT UNIQUE, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP, lineage_actor TEXT NOT NULL DEFAULT '', lineage_seq INTEGER NOT NULL DEFAULT 0);
CREATE TABLE edges(source TEXT, target TEXT, type TEXT, weight REAL, context TEXT, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, lineage_actor TEXT NOT NULL DEFAULT '', lineage_seq INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(source, target, type));
INSERT INTO nodes(id,text,status,metadata,created_at,updated_at,lineage_actor,lineage_seq) VALUES ('wv-r5b2','A','todo','{}',1,1,'',0);
"
r5b2_result=$(python3 "$REPLAY" "$R5B2_DB" "$R5B2_OPS/r5b2-a.json" "$R5B2_OPS/r5b2-b.json") || true
r5b2_disp_a=$(disp "$r5b2_result" "$R5B2_OPS/r5b2-a.json")
r5b2_disp_b=$(disp "$r5b2_result" "$R5B2_OPS/r5b2-b.json")
r5b2_state=$(sqlite3 "$R5B2_DB" "SELECT text || '|' || status FROM nodes WHERE id='wv-r5b2';")
[ "$r5b2_disp_a" = "ambiguous_same_lineage" ] && [ "$r5b2_disp_b" = "ambiguous_same_lineage" ] && [ "$r5b2_state" = "A|todo" ] \
    && ok "two multi-field patches that both assume the SAME starting state still collide (round 5 fix did not regress genuine collisions)" \
    || bad "genuinely colliding multi-field patches no longer caught (a=$r5b2_disp_a b=$r5b2_disp_b state=$r5b2_state)"

# The envelope's actor_id/actor_sequence must match payload.lineage -- a
# hash-valid op (operation_sha256 is self-consistent over whatever
# payload.lineage says) previously stamped a row with a counterfeit lineage
# tuple the envelope never actually claimed (round 5 finding).
R5C_OPS="$TMP/r5c-ops"
mkdir -p "$R5C_OPS"
python3 - "$R5C_OPS" <<'PY'
import hashlib, json, pathlib, sys
out = pathlib.Path(sys.argv[1])
def canonical(v):
    if v is None: return "null"
    if isinstance(v, bool): return "true" if v else "false"
    if isinstance(v, int): return str(v)
    if isinstance(v, str): return json.dumps(v, ensure_ascii=False, separators=(",", ":"))
    if isinstance(v, list): return "[" + ",".join(canonical(i) for i in v) + "]"
    if isinstance(v, dict): return "{" + ",".join(canonical(str(k)) + ":" + canonical(v[k]) for k in sorted(v)) + "}"
    raise TypeError(type(v))
payload = {"entity": {"kind": "node", "id": "wv-r5c"}, "lineage": {"seq": 999, "actor": "payload-z"},
           "mutation": {"kind": "node_patch", "fields": {"status": {"expected": "todo", "value": "active"}}}}
doc = {"format": "weave.delta.v2", "operation_id": "eeeeeeee-9999-1000-8000-000000000001",
       "actor_id": "agent-a", "actor_sequence": 1,
       "canonicalization": "weave.canonical-json.v1", "payload": payload}
doc["operation_sha256"] = hashlib.sha256(canonical(doc).encode()).hexdigest()
(out / "r5c-mismatch.json").write_text(json.dumps(doc) + "\n", encoding="utf-8")
PY
R5C_DB="$TMP/r5c.db"
sqlite3 "$R5C_DB" "
CREATE TABLE nodes(id TEXT PRIMARY KEY, text TEXT, status TEXT DEFAULT 'ready', metadata TEXT DEFAULT '{}', alias TEXT UNIQUE, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP, lineage_actor TEXT NOT NULL DEFAULT '', lineage_seq INTEGER NOT NULL DEFAULT 0);
CREATE TABLE edges(source TEXT, target TEXT, type TEXT, weight REAL, context TEXT, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, lineage_actor TEXT NOT NULL DEFAULT '', lineage_seq INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(source, target, type));
INSERT INTO nodes(id,text,status,metadata,created_at,updated_at,lineage_actor,lineage_seq) VALUES ('wv-r5c','x','todo','{}',1,1,'',0);
"
r5c_result=$(python3 "$REPLAY" "$R5C_DB" "$R5C_OPS/r5c-mismatch.json") || true
r5c_disp=$(disp "$r5c_result" "$R5C_OPS/r5c-mismatch.json")
r5c_lineage=$(sqlite3 "$R5C_DB" "SELECT lineage_seq || ',' || lineage_actor FROM nodes WHERE id='wv-r5c';")
[ "$r5c_disp" = "integrity_failed" ] && [ "$r5c_lineage" = "0," ] \
    && ok "an envelope actor_id/actor_sequence that disagrees with payload.lineage is rejected as integrity_failed, not stamped onto the row (round 5)" \
    || bad "lineage/envelope mismatch not rejected (disp=$r5c_disp lineage=$r5c_lineage)"

# ─────────────────────────────────────────────────────────────────────────────
# wv-4448a2 review round 5 (bash/sqlite re-investigation). Round 5's
# create+patch bypass (r5a above) let ANY create+patch pair through
# unconditionally -- against an entity that ALREADY EXISTED before this
# batch, the create is itself a lineage-guarded overwrite (not a fresh
# INSERT), so a patch computed against the pre-batch state has no real
# dependency on the create at all. Must collide in BOTH file orders instead
# of resolving to whichever op's value happened to land last.
R5D_OPS="$TMP/r5d-ops"
mkdir -p "$R5D_OPS"
python3 - "$R5D_OPS" <<'PY'
import hashlib, json, pathlib, sys
out = pathlib.Path(sys.argv[1])
def canonical(v):
    if v is None: return "null"
    if isinstance(v, bool): return "true" if v else "false"
    if isinstance(v, int): return str(v)
    if isinstance(v, str): return json.dumps(v, ensure_ascii=False, separators=(",", ":"))
    if isinstance(v, list): return "[" + ",".join(canonical(i) for i in v) + "]"
    if isinstance(v, dict): return "{" + ",".join(canonical(str(k)) + ":" + canonical(v[k]) for k in sorted(v)) + "}"
    raise TypeError(type(v))
def write(name, opid, mutation):
    payload = {"entity": {"kind": "node", "id": "wv-r5d"}, "lineage": {"seq": 40, "actor": "agent-a"},
               "mutation": mutation}
    doc = {"format": "weave.delta.v2", "operation_id": opid, "actor_id": "agent-a", "actor_sequence": 40,
           "canonicalization": "weave.canonical-json.v1", "payload": payload}
    doc["operation_sha256"] = hashlib.sha256(canonical(doc).encode()).hexdigest()
    (out / name).write_text(json.dumps(doc) + "\n", encoding="utf-8")
write("r5d-create.json", "11110000-1111-1000-8000-000000000001", {"kind": "node_create", "row": {
    "text": "from the create", "status": "todo", "metadata": {}, "alias": None,
    "created_at": "2026-09-05 00:00:00",
}})
write("r5d-patch.json", "11110000-2222-1000-8000-000000000002", {"kind": "node_patch", "fields": {
    "text": {"expected": "pre-batch value", "value": "from the patch"},
}})
PY
mkdb_r5d() {
    sqlite3 "$1" "
CREATE TABLE nodes(id TEXT PRIMARY KEY, text TEXT, status TEXT DEFAULT 'ready', metadata TEXT DEFAULT '{}', alias TEXT UNIQUE, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP, lineage_actor TEXT NOT NULL DEFAULT '', lineage_seq INTEGER NOT NULL DEFAULT 0);
CREATE TABLE edges(source TEXT, target TEXT, type TEXT, weight REAL, context TEXT, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, lineage_actor TEXT NOT NULL DEFAULT '', lineage_seq INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(source, target, type));
INSERT INTO nodes(id,text,status,metadata,created_at,updated_at,lineage_actor,lineage_seq) VALUES ('wv-r5d','pre-batch value','todo','{}',1,1,'agent-z',10);
"
}
R5D_DB1="$TMP/r5d1.db"; mkdb_r5d "$R5D_DB1"
r5d_result1=$(python3 "$REPLAY" "$R5D_DB1" "$R5D_OPS/r5d-create.json" "$R5D_OPS/r5d-patch.json") || true
r5d_disp1_c=$(disp "$r5d_result1" "$R5D_OPS/r5d-create.json")
r5d_disp1_p=$(disp "$r5d_result1" "$R5D_OPS/r5d-patch.json")
r5d_state1=$(sqlite3 "$R5D_DB1" "SELECT text FROM nodes WHERE id='wv-r5d';")
R5D_DB2="$TMP/r5d2.db"; mkdb_r5d "$R5D_DB2"
r5d_result2=$(python3 "$REPLAY" "$R5D_DB2" "$R5D_OPS/r5d-patch.json" "$R5D_OPS/r5d-create.json") || true
r5d_disp2_c=$(disp "$r5d_result2" "$R5D_OPS/r5d-create.json")
r5d_disp2_p=$(disp "$r5d_result2" "$R5D_OPS/r5d-patch.json")
r5d_state2=$(sqlite3 "$R5D_DB2" "SELECT text FROM nodes WHERE id='wv-r5d';")
[ "$r5d_disp1_c" = "ambiguous_same_lineage" ] && [ "$r5d_disp1_p" = "ambiguous_same_lineage" ] && [ "$r5d_state1" = "pre-batch value" ] \
    && [ "$r5d_disp2_c" = "ambiguous_same_lineage" ] && [ "$r5d_disp2_p" = "ambiguous_same_lineage" ] && [ "$r5d_state2" = "pre-batch value" ] \
    && ok "a create+patch pair against an EXISTING row whose patch expected does not match the create's row collides in BOTH file orders, not order-dependently resolved (round 5 review)" \
    || bad "create+patch dependency mismatch not caught (order1: create=$r5d_disp1_c patch=$r5d_disp1_p state=$r5d_state1; order2: create=$r5d_disp2_c patch=$r5d_disp2_p state=$r5d_state2)"

# A patch immediately followed by a delete on the same (entity, lineage) is
# a legitimate sequential edit within one throttled batch -- delete's own
# apply guard (_apply_delete) is lineage-only, no per-field precondition, so
# it must actually delete the row regardless of which file the dispatcher
# tries first. Previously ANY delete paired with anything was forced into
# ambiguous_same_lineage, excluding BOTH ops from dispatch entirely and
# leaving the row alive in both orders.
R5E_OPS="$TMP/r5e-ops"
mkdir -p "$R5E_OPS"
python3 - "$R5E_OPS" <<'PY'
import hashlib, json, pathlib, sys
out = pathlib.Path(sys.argv[1])
def canonical(v):
    if v is None: return "null"
    if isinstance(v, bool): return "true" if v else "false"
    if isinstance(v, int): return str(v)
    if isinstance(v, str): return json.dumps(v, ensure_ascii=False, separators=(",", ":"))
    if isinstance(v, list): return "[" + ",".join(canonical(i) for i in v) + "]"
    if isinstance(v, dict): return "{" + ",".join(canonical(str(k)) + ":" + canonical(v[k]) for k in sorted(v)) + "}"
    raise TypeError(type(v))
def write(name, opid, mutation):
    payload = {"entity": {"kind": "node", "id": "wv-r5e"}, "lineage": {"seq": 41, "actor": "agent-a"},
               "mutation": mutation}
    doc = {"format": "weave.delta.v2", "operation_id": opid, "actor_id": "agent-a", "actor_sequence": 41,
           "canonicalization": "weave.canonical-json.v1", "payload": payload}
    doc["operation_sha256"] = hashlib.sha256(canonical(doc).encode()).hexdigest()
    (out / name).write_text(json.dumps(doc) + "\n", encoding="utf-8")
write("r5e-patch.json", "22220000-1111-1000-8000-000000000001", {"kind": "node_patch", "fields": {
    "status": {"expected": "todo", "value": "active"},
}})
write("r5e-delete.json", "22220000-2222-1000-8000-000000000002", {"kind": "node_delete"})
PY
mkdb_r5e() {
    sqlite3 "$1" "
CREATE TABLE nodes(id TEXT PRIMARY KEY, text TEXT, status TEXT DEFAULT 'ready', metadata TEXT DEFAULT '{}', alias TEXT UNIQUE, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP, lineage_actor TEXT NOT NULL DEFAULT '', lineage_seq INTEGER NOT NULL DEFAULT 0);
CREATE TABLE edges(source TEXT, target TEXT, type TEXT, weight REAL, context TEXT, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, lineage_actor TEXT NOT NULL DEFAULT '', lineage_seq INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(source, target, type));
INSERT INTO nodes(id,text,status,metadata,created_at,updated_at,lineage_actor,lineage_seq) VALUES ('wv-r5e','doomed','todo','{}',1,1,'agent-z',5);
"
}
R5E_DB1="$TMP/r5e1.db"; mkdb_r5e "$R5E_DB1"
r5e_result1=$(python3 "$REPLAY" "$R5E_DB1" "$R5E_OPS/r5e-patch.json" "$R5E_OPS/r5e-delete.json") || true
r5e_disp1_p=$(disp "$r5e_result1" "$R5E_OPS/r5e-patch.json")
r5e_disp1_d=$(disp "$r5e_result1" "$R5E_OPS/r5e-delete.json")
r5e_rows1=$(sqlite3 "$R5E_DB1" "SELECT COUNT(*) FROM nodes WHERE id='wv-r5e';")
R5E_DB2="$TMP/r5e2.db"; mkdb_r5e "$R5E_DB2"
r5e_result2=$(python3 "$REPLAY" "$R5E_DB2" "$R5E_OPS/r5e-delete.json" "$R5E_OPS/r5e-patch.json") || true
r5e_disp2_p=$(disp "$r5e_result2" "$R5E_OPS/r5e-patch.json")
r5e_disp2_d=$(disp "$r5e_result2" "$R5E_OPS/r5e-delete.json")
r5e_rows2=$(sqlite3 "$R5E_DB2" "SELECT COUNT(*) FROM nodes WHERE id='wv-r5e';")
[ "$r5e_disp1_p" != "ambiguous_same_lineage" ] && [ "$r5e_disp1_d" != "ambiguous_same_lineage" ] && [ "$r5e_rows1" = "0" ] \
    && [ "$r5e_disp2_p" != "ambiguous_same_lineage" ] && [ "$r5e_disp2_d" != "ambiguous_same_lineage" ] && [ "$r5e_rows2" = "0" ] \
    && ok "a patch+delete pair on the same (entity, lineage) actually deletes the row in BOTH file orders, not left ambiguous and alive (round 5 review)" \
    || bad "patch+delete pair did not converge to deleted (order1: patch=$r5e_disp1_p delete=$r5e_disp1_d rows=$r5e_rows1; order2: patch=$r5e_disp2_p delete=$r5e_disp2_d rows=$r5e_rows2)"

# Three patches whose expected/value pairs form a CYCLE on one column
# (A->B->C->A) have every PAIR's expected value distinct, so pairwise
# comparison alone never flags them -- but _apply_node_patch's
# already-satisfied shortcut matches on VALUE alone with no `expected`
# check, so whichever cycle member is dispatched first and happens to find
# the row already holding ITS value gets silently marked satisfied without
# verifying its own precondition, dropping it from the chain. Must be
# flagged ambiguous_same_lineage (an acyclic-graph violation), not left to
# resolve to a different surviving value depending on file order.
R5F_OPS="$TMP/r5f-ops"
mkdir -p "$R5F_OPS"
python3 - "$R5F_OPS" <<'PY'
import hashlib, json, pathlib, sys
out = pathlib.Path(sys.argv[1])
def canonical(v):
    if v is None: return "null"
    if isinstance(v, bool): return "true" if v else "false"
    if isinstance(v, int): return str(v)
    if isinstance(v, str): return json.dumps(v, ensure_ascii=False, separators=(",", ":"))
    if isinstance(v, list): return "[" + ",".join(canonical(i) for i in v) + "]"
    if isinstance(v, dict): return "{" + ",".join(canonical(str(k)) + ":" + canonical(v[k]) for k in sorted(v)) + "}"
    raise TypeError(type(v))
def write(name, opid, fields):
    payload = {"entity": {"kind": "node", "id": "wv-r5f"}, "lineage": {"seq": 42, "actor": "agent-a"},
               "mutation": {"kind": "node_patch", "fields": fields}}
    doc = {"format": "weave.delta.v2", "operation_id": opid, "actor_id": "agent-a", "actor_sequence": 42,
           "canonicalization": "weave.canonical-json.v1", "payload": payload}
    doc["operation_sha256"] = hashlib.sha256(canonical(doc).encode()).hexdigest()
    (out / name).write_text(json.dumps(doc) + "\n", encoding="utf-8")
write("r5f-p1.json", "33330000-1111-1000-8000-000000000001", {"text": {"expected": "A", "value": "B"}})
write("r5f-p2.json", "33330000-2222-1000-8000-000000000002", {"text": {"expected": "B", "value": "C"}})
write("r5f-p3.json", "33330000-3333-1000-8000-000000000003", {"text": {"expected": "C", "value": "A"}})
PY
mkdb_r5f() {
    sqlite3 "$1" "
CREATE TABLE nodes(id TEXT PRIMARY KEY, text TEXT, status TEXT DEFAULT 'ready', metadata TEXT DEFAULT '{}', alias TEXT UNIQUE, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP, lineage_actor TEXT NOT NULL DEFAULT '', lineage_seq INTEGER NOT NULL DEFAULT 0);
CREATE TABLE edges(source TEXT, target TEXT, type TEXT, weight REAL, context TEXT, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, lineage_actor TEXT NOT NULL DEFAULT '', lineage_seq INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(source, target, type));
INSERT INTO nodes(id,text,status,metadata,created_at,updated_at,lineage_actor,lineage_seq) VALUES ('wv-r5f','A','todo','{}',1,1,'agent-z',1);
"
}
R5F_DB1="$TMP/r5f1.db"; mkdb_r5f "$R5F_DB1"
r5f_result1=$(python3 "$REPLAY" "$R5F_DB1" "$R5F_OPS/r5f-p1.json" "$R5F_OPS/r5f-p2.json" "$R5F_OPS/r5f-p3.json") || true
r5f_disp1_1=$(disp "$r5f_result1" "$R5F_OPS/r5f-p1.json")
r5f_disp1_2=$(disp "$r5f_result1" "$R5F_OPS/r5f-p2.json")
r5f_disp1_3=$(disp "$r5f_result1" "$R5F_OPS/r5f-p3.json")
r5f_state1=$(sqlite3 "$R5F_DB1" "SELECT text FROM nodes WHERE id='wv-r5f';")
R5F_DB2="$TMP/r5f2.db"; mkdb_r5f "$R5F_DB2"
r5f_result2=$(python3 "$REPLAY" "$R5F_DB2" "$R5F_OPS/r5f-p3.json" "$R5F_OPS/r5f-p2.json" "$R5F_OPS/r5f-p1.json") || true
r5f_disp2_1=$(disp "$r5f_result2" "$R5F_OPS/r5f-p1.json")
r5f_disp2_2=$(disp "$r5f_result2" "$R5F_OPS/r5f-p2.json")
r5f_disp2_3=$(disp "$r5f_result2" "$R5F_OPS/r5f-p3.json")
r5f_state2=$(sqlite3 "$R5F_DB2" "SELECT text FROM nodes WHERE id='wv-r5f';")
[ "$r5f_disp1_1" = "ambiguous_same_lineage" ] && [ "$r5f_disp1_2" = "ambiguous_same_lineage" ] && [ "$r5f_disp1_3" = "ambiguous_same_lineage" ] && [ "$r5f_state1" = "A" ] \
    && [ "$r5f_disp2_1" = "ambiguous_same_lineage" ] && [ "$r5f_disp2_2" = "ambiguous_same_lineage" ] && [ "$r5f_disp2_3" = "ambiguous_same_lineage" ] && [ "$r5f_state2" = "A" ] \
    && ok "a 3-way cyclic expected/value chain (A->B->C->A) is flagged ambiguous_same_lineage in BOTH file orders, not order-dependently resolved to a different surviving value (round 5 review)" \
    || bad "cyclic patch chain not caught (order1: p1=$r5f_disp1_1 p2=$r5f_disp1_2 p3=$r5f_disp1_3 state=$r5f_state1; order2: p1=$r5f_disp2_1 p2=$r5f_disp2_2 p3=$r5f_disp2_3 state=$r5f_state2)"

# An operation_id reused with a DIFFERENT hash (tampering/corruption) must
# reach evaluate()'s own hard `identity_hash_mismatch` check even when a
# third, unrelated op shares its (entity, lineage) group and would
# otherwise collide with it -- not be swept into the group's soft
# ambiguous_same_lineage classification, which never rolls back.
R5G_OPS="$TMP/r5g-ops"
mkdir -p "$R5G_OPS"
python3 - "$R5G_OPS" <<'PY'
import hashlib, json, pathlib, sys
out = pathlib.Path(sys.argv[1])
def canonical(v):
    if v is None: return "null"
    if isinstance(v, bool): return "true" if v else "false"
    if isinstance(v, int): return str(v)
    if isinstance(v, str): return json.dumps(v, ensure_ascii=False, separators=(",", ":"))
    if isinstance(v, list): return "[" + ",".join(canonical(i) for i in v) + "]"
    if isinstance(v, dict): return "{" + ",".join(canonical(str(k)) + ":" + canonical(v[k]) for k in sorted(v)) + "}"
    raise TypeError(type(v))
def write(name, opid, value):
    payload = {"entity": {"kind": "node", "id": "wv-r5g"}, "lineage": {"seq": 43, "actor": "agent-a"},
               "mutation": {"kind": "node_patch", "fields": {"status": {"expected": "todo", "value": value}}}}
    doc = {"format": "weave.delta.v2", "operation_id": opid, "actor_id": "agent-a", "actor_sequence": 43,
           "canonicalization": "weave.canonical-json.v1", "payload": payload}
    doc["operation_sha256"] = hashlib.sha256(canonical(doc).encode()).hexdigest()
    (out / name).write_text(json.dumps(doc) + "\n", encoding="utf-8")
SAME_ID = "44440000-1111-1000-8000-000000000001"
write("r5g-a.json", SAME_ID, "active")
write("r5g-b.json", SAME_ID, "blocked")
write("r5g-c.json", "44440000-2222-1000-8000-000000000002", "done")
PY
R5G_DB="$TMP/r5g.db"
sqlite3 "$R5G_DB" "
CREATE TABLE nodes(id TEXT PRIMARY KEY, text TEXT, status TEXT DEFAULT 'ready', metadata TEXT DEFAULT '{}', alias TEXT UNIQUE, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP, lineage_actor TEXT NOT NULL DEFAULT '', lineage_seq INTEGER NOT NULL DEFAULT 0);
CREATE TABLE edges(source TEXT, target TEXT, type TEXT, weight REAL, context TEXT, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, lineage_actor TEXT NOT NULL DEFAULT '', lineage_seq INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(source, target, type));
INSERT INTO nodes(id,text,status,metadata,created_at,updated_at,lineage_actor,lineage_seq) VALUES ('wv-r5g','x','todo','{}',1,1,'',0);
"
r5g_result=$(python3 "$REPLAY" "$R5G_DB" "$R5G_OPS/r5g-a.json" "$R5G_OPS/r5g-b.json" "$R5G_OPS/r5g-c.json") || true
r5g_disp_a=$(disp "$r5g_result" "$R5G_OPS/r5g-a.json")
r5g_disp_b=$(disp "$r5g_result" "$R5G_OPS/r5g-b.json")
r5g_aborted=$(printf '%s' "$r5g_result" | jq -r '.aborted')
[ "$r5g_disp_a" != "ambiguous_same_lineage" ] && [ "$r5g_disp_b" = "identity_hash_mismatch" ] && [ "$r5g_aborted" = "true" ] \
    && ok "a duplicate operation_id with a different hash is still identity_hash_mismatch (hard abort), not downgraded to ambiguous_same_lineage by an unrelated third colliding op (round 5 review)" \
    || bad "identity/hash mismatch downgraded (a=$r5g_disp_a b=$r5g_disp_b aborted=$r5g_aborted)"

# ─────────────────────────────────────────────────────────────────────────────
# Deep-review finding: two ops touching the EXACT SAME set of fields with the
# EXACT SAME expected/value transition on every one (distinct operation_id,
# e.g. independently re-derived by repair tooling) are semantically the same
# write -- applying either converges to the identical state, so the other is
# a harmless already_satisfied, not a real ambiguity. Must NOT be flagged
# ambiguous_same_lineage.
R5H_OPS="$TMP/r5h-ops"
mkdir -p "$R5H_OPS"
python3 - "$R5H_OPS" <<'PY'
import hashlib, json, pathlib, sys
out = pathlib.Path(sys.argv[1])
def canonical(v):
    if v is None: return "null"
    if isinstance(v, bool): return "true" if v else "false"
    if isinstance(v, int): return str(v)
    if isinstance(v, str): return json.dumps(v, ensure_ascii=False, separators=(",", ":"))
    if isinstance(v, list): return "[" + ",".join(canonical(i) for i in v) + "]"
    if isinstance(v, dict): return "{" + ",".join(canonical(str(k)) + ":" + canonical(v[k]) for k in sorted(v)) + "}"
    raise TypeError(type(v))
def write(name, opid, fields):
    payload = {"entity": {"kind": "node", "id": "wv-r5h"}, "lineage": {"seq": 50, "actor": "agent-a"},
               "mutation": {"kind": "node_patch", "fields": fields}}
    doc = {"format": "weave.delta.v2", "operation_id": opid, "actor_id": "agent-a", "actor_sequence": 50,
           "canonicalization": "weave.canonical-json.v1", "payload": payload}
    doc["operation_sha256"] = hashlib.sha256(canonical(doc).encode()).hexdigest()
    (out / name).write_text(json.dumps(doc) + "\n", encoding="utf-8")
fields = {
    "status": {"expected": "todo", "value": "active"},
    "text": {"expected": "before", "value": "after"},
}
write("r5h-dup1.json", "55550000-1111-1000-8000-000000000001", fields)
write("r5h-dup2.json", "55550000-2222-1000-8000-000000000002", fields)
PY
R5H_DB="$TMP/r5h.db"
sqlite3 "$R5H_DB" "
CREATE TABLE nodes(id TEXT PRIMARY KEY, text TEXT, status TEXT DEFAULT 'ready', metadata TEXT DEFAULT '{}', alias TEXT UNIQUE, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP, lineage_actor TEXT NOT NULL DEFAULT '', lineage_seq INTEGER NOT NULL DEFAULT 0);
CREATE TABLE edges(source TEXT, target TEXT, type TEXT, weight REAL, context TEXT, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, lineage_actor TEXT NOT NULL DEFAULT '', lineage_seq INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(source, target, type));
INSERT INTO nodes(id,text,status,metadata,created_at,updated_at,lineage_actor,lineage_seq) VALUES ('wv-r5h','before','todo','{}',1,1,'agent-z',10);
"
r5h_result=$(python3 "$REPLAY" "$R5H_DB" "$R5H_OPS/r5h-dup1.json" "$R5H_OPS/r5h-dup2.json") || true
r5h_disp1=$(disp "$r5h_result" "$R5H_OPS/r5h-dup1.json")
r5h_disp2=$(disp "$r5h_result" "$R5H_OPS/r5h-dup2.json")
r5h_state=$(sqlite3 "$R5H_DB" "SELECT text || '|' || status FROM nodes WHERE id='wv-r5h';")
{ [ "$r5h_disp1" = "applied" ] && [ "$r5h_disp2" = "already_satisfied" ]; } || \
    { [ "$r5h_disp2" = "applied" ] && [ "$r5h_disp1" = "already_satisfied" ]; } \
    && [ "$r5h_state" = "after|active" ] \
    && ok "two ops sharing an identical (expected, value) transition on the exact same field set converge -- not flagged ambiguous_same_lineage (deep-review finding)" \
    || bad "identical-content ops misclassified (disp1=$r5h_disp1 disp2=$r5h_disp2 state=$r5h_state)"

# The wv-806a6b shape must still collide even though a re-derivation shares
# one field's exact (expected, value) -- covered already above by the R4C
# fixture (round 4 finding 4); this just documents the boundary the R5H fix
# must respect: matching on a SHARED column is not enough, the full field
# sets must match too.

# ─────────────────────────────────────────────────────────────────────────────
# Dispatched path: `wv load` applies committed v2 operation sidecars (wv-ba9dc8).
REPO="$TMP/dispatch-repo"
HOT="$TMP/dispatch-hot"
mkdir -p "$REPO"
(
  cd "$REPO"
  git init -q
  git config user.email test@example.com
  git config user.name Tester
  common=(WV_HOT_ZONE="$HOT" WV_AUTO_CHECKPOINT=0 WV_SYNC_INTERVAL=0)
  env "${common[@]}" "$ROOT/scripts/wv" init >/dev/null
  tgt=$(env "${common[@]}" "$ROOT/scripts/wv" add "dispatch target" --status=todo --criteria=c --risks=low | grep -o 'wv-[a-f0-9]\{6\}' | sed -n 1p)
  env "${common[@]}" "$ROOT/scripts/wv" sync >/dev/null 2>&1 || true
  echo "$tgt" > "$TMP/tgt-id"
)
TGT=$(cat "$TMP/tgt-id")
V2DIR="$REPO/.weave/deltas/$(date +%F)/v2"
mkdir -p "$V2DIR"

python3 - "$V2DIR" "$TGT" <<'PY'
import hashlib, json, pathlib, sys, uuid
out, tgt = pathlib.Path(sys.argv[1]), sys.argv[2]


def canonical(v):
    if v is None: return "null"
    if isinstance(v, bool): return "true" if v else "false"
    if isinstance(v, int): return str(v)
    if isinstance(v, str): return json.dumps(v, ensure_ascii=False, separators=(",", ":"))
    if isinstance(v, list): return "[" + ",".join(canonical(x) for x in v) + "]"
    if isinstance(v, dict):
        return "{" + ",".join(canonical(str(k)) + ":" + canonical(v[k]) for k in sorted(v)) + "}"
    raise TypeError(type(v).__name__)


def emit(name, payload, seq=999999):
    doc = {
        "format": "weave.delta.v2",
        "operation_id": str(uuid.uuid5(uuid.NAMESPACE_URL, name)),
        "actor_id": "dispatch-test",
        "actor_sequence": seq,
        "canonicalization": "weave.canonical-json.v1",
        "payload": payload,
    }
    doc["operation_sha256"] = hashlib.sha256(canonical(doc).encode()).hexdigest()
    (out / f"{seq:012d}-{doc['operation_id']}.json").write_text(canonical(doc) + "\n")


emit("dispatch-patch", {
    "entity": {"kind": "node", "id": tgt},
    "lineage": {"seq": 999999, "actor": "dispatch-test"},
    "mutation": {"kind": "node_patch", "fields": {"status": {"expected": "todo", "value": "blocked"}}},
})
PY

rm -rf "$HOT"
load_err=$(cd "$REPO" && WV_HOT_ZONE="$HOT" WV_AUTO_CHECKPOINT=0 "$ROOT/scripts/wv" load 2>&1 >/dev/null)
status_after=$(cd "$REPO" && WV_HOT_ZONE="$HOT" WV_AUTO_CHECKPOINT=0 "$ROOT/scripts/wv" show "$TGT" --json 2>/dev/null | jq -r '.status')
[ "$status_after" = "blocked" ] && ok "wv load applies a committed v2 node_patch sidecar" || bad "wv load applies a committed v2 node_patch sidecar (status=$status_after)"
grep -q "Delta v2 replay:" <<< "$load_err" && ok "wv load reports v2 dispositions on stderr" || bad "wv load reports v2 dispositions on stderr"

# Hard failure: a corrupt v2 op rolls back and, under strict, fails the load.
printf '{"format":"weave.delta.v2","garbage":true}\n' > "$V2DIR/000000999998-corrupt.json"
rm -rf "$HOT"
strict_rc=0
(cd "$REPO" && WV_HOT_ZONE="$HOT" WV_AUTO_CHECKPOINT=0 WV_DELTA_V2_STRICT=1 "$ROOT/scripts/wv" load >/dev/null 2>&1) || strict_rc=$?
[ "$strict_rc" -ne 0 ] && ok "WV_DELTA_V2_STRICT=1 fails the load on a corrupt v2 op" || bad "WV_DELTA_V2_STRICT=1 fails the load on a corrupt v2 op"
rm -rf "$HOT"
lax_rc=0
(cd "$REPO" && WV_HOT_ZONE="$HOT" WV_AUTO_CHECKPOINT=0 "$ROOT/scripts/wv" load >/dev/null 2>&1) || lax_rc=$?
[ "$lax_rc" -eq 0 ] && ok "without strict, a corrupt v2 op warns but the load still succeeds" || bad "without strict, a corrupt v2 op warns but the load still succeeds (rc=$lax_rc)"

echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
