#!/usr/bin/env bash
# Stage B prerequisite 3, ruling A (wv-83defa, suite wv-e63fe3): Delta v2 creates
# and patches are never deletable, because conflict detection reads all of them.
#
# Pins the B1-B5 and B7 breaks from the 2026-11-06 sweep
# (docs/findings/judge-stage-b-conflict-evidence-2026-11-06) against the real
# evaluator `wv load` runs. Each case evaluates a full catalog and the catalog
# minus files the first-draft rule would allow deleting (rule (a): after an
# acknowledged load, delete any emission that holds no lost write). It asserts
# the report or the graph changes, by value. The converse: deleting only
# node_delete/edge_delete operations leaves the lost-write report and the
# durable state (nodes, edges, tombstones) identical.
#
# B6 (metadata vs claimed_by fork on one column) is a detection gap without any
# deletion and belongs to wv-cf6f29, not here.

set -euo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
export WV_CALL_SOURCE=test

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "=== Stage B ruling A: creates and patches are detector inputs ==="

python3 -I - "$ROOT" "$TMP" <<'PY'
import hashlib
import importlib.util
import json
import pathlib
import shutil
import sqlite3
import sys
import uuid

ROOT = pathlib.Path(sys.argv[1])
TMP = pathlib.Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("replay", ROOT / "scripts/lib/wv-delta-v2-replay.py")
R = importlib.util.module_from_spec(spec)
spec.loader.exec_module(R)

DDL = """
CREATE TABLE nodes(id TEXT PRIMARY KEY, text TEXT, status TEXT DEFAULT 'todo', metadata TEXT DEFAULT '{}',
    alias TEXT UNIQUE, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    lineage_actor TEXT NOT NULL DEFAULT '', lineage_seq INTEGER NOT NULL DEFAULT 0);
CREATE TABLE edges(source TEXT, target TEXT, type TEXT, weight REAL, context TEXT,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP, lineage_actor TEXT NOT NULL DEFAULT '',
    lineage_seq INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(source, target, type));
"""

passed = 0
ran = 0
counter = 0


def check(cond, label, detail=""):
    global passed, ran
    ran += 1
    if cond:
        passed += 1
        print(f"  ✓ {label}")
    else:
        print(f"  ✗ {label}" + (f": {detail}" if detail else ""))


def canonical(v):
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, str):
        return json.dumps(v, ensure_ascii=False, separators=(",", ":"))
    if isinstance(v, list):
        return "[" + ",".join(canonical(x) for x in v) + "]"
    if isinstance(v, dict):
        return "{" + ",".join(canonical(str(k)) + ":" + canonical(v[k]) for k in sorted(v)) + "}"
    raise TypeError(type(v).__name__)


def op(name, entity, mutation, seq, actor="agent-a"):
    doc = {
        "format": "weave.delta.v2",
        "operation_id": str(uuid.uuid5(uuid.NAMESPACE_URL, "ruling-a-" + name)),
        "actor_id": actor, "actor_sequence": seq, "canonicalization": "weave.canonical-json.v1",
        "payload": {"entity": entity, "lineage": {"seq": seq, "actor": actor}, "mutation": mutation},
    }
    doc["operation_sha256"] = hashlib.sha256(canonical(doc).encode()).hexdigest()
    return name, doc


def node(node_id):
    return {"kind": "node", "id": node_id}


def edge(src, dst, typ):
    return {"kind": "edge", "source": src, "target": dst, "type": typ}


def patch(field, expected, value):
    return {"kind": "node_patch", "fields": {field: {"expected": expected, "value": value}}}


def create(text):
    return {"kind": "node_create", "row": {"text": text, "status": "todo", "metadata": {}, "alias": None,
                                           "created_at": "2026-07-19 00:00:00"}}


def fresh_db(rows):
    global counter
    counter += 1
    db = TMP / f"g{counter}.db"
    conn = sqlite3.connect(db)
    conn.executescript(DDL)
    conn.executemany(
        "INSERT INTO nodes(id,text,status,metadata,lineage_actor,lineage_seq) VALUES (?,?,?,?,?,?)", rows)
    conn.commit()
    conn.close()
    return db


def snapshot(db):
    conn = sqlite3.connect(db)
    out = {
        "nodes": conn.execute(
            "SELECT id,status,text,metadata,lineage_seq,lineage_actor FROM nodes ORDER BY id").fetchall(),
        "edges": conn.execute(
            "SELECT source,target,type,weight,context,lineage_seq,lineage_actor FROM edges "
            "ORDER BY source,target,type").fetchall(),
        "tombstones": [],
    }
    if conn.execute("SELECT 1 FROM sqlite_master WHERE name='tombstones'").fetchone():
        out["tombstones"] = conn.execute(
            "SELECT kind,id,lineage_seq,lineage_actor FROM tombstones ORDER BY kind,id").fetchall()
    conn.close()
    return out


def evaluate(db, ops, keep):
    global counter
    counter += 1
    d = TMP / f"ops{counter}"
    d.mkdir()
    paths = []
    for name, doc in ops:
        if name in keep:
            p = d / (name + ".json")
            p.write_text(canonical(doc) + "\n", encoding="utf-8")
            paths.append(p)
    res = R.evaluate(db, sorted(paths))
    lost = [(w["entity"], w["field"], w["differs"]) for w in res["lost_writes"]]
    holders = {w["operation_id"] for w in res["lost_writes"]}
    disp = {pathlib.Path(r["path"]).stem: r["disposition"] for r in res["results"]}
    return {"lost": lost, "raw_lost": res["lost_writes"], "holders": holders, "disp": disp,
            "state": snapshot(db), "aborted": res["aborted"]}


def compare(rows, ops, deleted):
    names = {n for n, _ in ops}
    full = evaluate(fresh_db(rows), ops, names)
    sub = evaluate(fresh_db(rows), ops, names - set(deleted))
    return full, sub


def rule_a_allows(full, ops, deleted):
    """First-draft rule: after an acknowledged load, an emission holding no lost write may go."""
    ids = {doc["operation_id"] for n, doc in ops if n in deleted}
    return not (ids & full["holders"])


BASE, MAIN, BRANCH = {"a": 1}, {"a": 1, "p": "main"}, {"a": 1, "p": "branch"}

# --- B1: metadata fork; deleting the winner erases the report --------------
print("=== B1 delete the winning sibling of a metadata fork ===")
rows = [("wv-fork", "fork", "todo", json.dumps(MAIN), "agent-a", 10)]
ops = [op("fork-main", node("wv-fork"), patch("metadata", BASE, MAIN), 10),
       op("fork-branch", node("wv-fork"), patch("metadata", BASE, BRANCH), 9)]
full, sub = compare(rows, ops, ["fork-main"])
check(full["lost"] == [("wv-fork", "metadata", ["p"])], "full catalog reports the metadata fork", full["lost"])
check(full["disp"] == {"fork-main": "already_satisfied", "fork-branch": "precondition_conflict"},
      "the winner is satisfied and the losing branch refused", full["disp"])
check(rule_a_allows(full, ops, ["fork-main"]), "rule (a) allows deleting the winner (it holds no lost write)")
check(sub["lost"] == [], "after the deletion the lost write is no longer reported", sub["lost"])
check(sub["lost"] != full["lost"], "the first-draft rule (ack-then-delete) changes the report on a metadata fork")

# --- B2: status re-entry ---------------------------------------------------
print("=== B2 delete the op that re-entered a status ===")
rows = [("wv-seq", "seq", "done", "{}", "agent-a", 5)]
ops = [op("seq-create", node("wv-seq"), create("seq"), 1),
       op("seq-1", node("wv-seq"), patch("status", "todo", "blocked"), 2),
       op("seq-2", node("wv-seq"), patch("status", "blocked", "todo"), 3),
       op("seq-3", node("wv-seq"), patch("status", "todo", "active"), 4)]
full, sub = compare(rows, ops, ["seq-2"])
check(full["lost"] == [], "full lifecycle reports no lost write", full["lost"])
check(rule_a_allows(full, ops, ["seq-2"]), "rule (a) allows deleting the re-entry op")
check(sub["lost"] == [("wv-seq", "status", {"current": "done", "value": "blocked"}),
                      ("wv-seq", "status", {"current": "done", "value": "active"})],
      "after the deletion an ordinary lifecycle reports two phantom losses", sub["lost"])

# --- B3: later edit past a fork ---------------------------------------------
print("=== B3 delete the edit that put a fork in the past ===")
LATER = {"a": 1, "p": "main", "q": 1}
rows = [("wv-past", "past", "todo", json.dumps(LATER), "agent-a", 12)]
ops = [op("past-main", node("wv-past"), patch("metadata", BASE, MAIN), 10),
       op("past-branch", node("wv-past"), patch("metadata", BASE, BRANCH), 9),
       op("past-later", node("wv-past"), patch("metadata", MAIN, LATER), 12)]
full, sub = compare(rows, ops, ["past-later"])
check(full["lost"] == [], "a fork edited past is not reported", full["lost"])
check(rule_a_allows(full, ops, ["past-later"]), "rule (a) allows deleting the later edit")
# past-main's own change (p: main) is still in the row, so only the branch
# side is named (wv-cf6f29); before that fix both sides were.
check(sub["lost"] == [("wv-past", "metadata", ["p", "q"])],
      "after the deletion the past conflict is reported again", sub["lost"])

# --- B4: op built on a refused value ----------------------------------------
print("=== B4 delete the op that built on a refused value ===")
rows = [("wv-stale", "c", "todo", "{}", "agent-a", 2)]
ops = [op("stale-0", node("wv-stale"), patch("text", "a", "z"), 1),
       op("stale-1", node("wv-stale"), patch("text", "a", "b"), 1, actor="agent-b"),
       op("stale-2", node("wv-stale"), patch("text", "b", "c"), 2)]
full, sub = compare(rows, ops, ["stale-2"])
check(full["lost"] == [], "a refused value that was built on is not reported", full["lost"])
check(rule_a_allows(full, ops, ["stale-2"]), "rule (a) allows deleting the satisfied op")
check(sub["lost"] == [("wv-stale", "text", {"current": "c", "value": "z"}),
                      ("wv-stale", "text", {"current": "c", "value": "b"})],
      "after the deletion two phantom losses appear", sub["lost"])

# --- B5: late peer op after the winner was deleted --------------------------
print("=== B5 late peer op after the winner was deleted ===")
rows = [("wv-late", "late", "todo", json.dumps(MAIN), "agent-a", 10)]
winner = [op("late-main", node("wv-late"), patch("metadata", BASE, MAIN), 10)]
peer = [op("late-peer", node("wv-late"), patch("metadata", BASE, BRANCH), 9, actor="agent-b")]
before = evaluate(fresh_db(rows), winner, {"late-main"})
check(before["lost"] == [] and rule_a_allows(before, winner, ["late-main"]),
      "with no peer yet, rule (a) allows deleting the winner", before["lost"])
full, sub = compare(rows, winner + peer, ["late-main"])
check(full["lost"] == [("wv-late", "metadata", ["p"])], "with the winner kept, the late peer is reported",
      full["lost"])
check(sub["disp"].get("late-peer") == "precondition_conflict" and sub["lost"] == [],
      "with the winner deleted, the peer is refused and never reported", (sub["disp"], sub["lost"]))

# --- B7: same-lineage collision ---------------------------------------------
print("=== B7 delete one member of a same-lineage collision ===")
rows = [("wv-amb", "amb", "todo", json.dumps(BASE), "agent-a", 4)]
ops = [op("amb-1", node("wv-amb"), patch("metadata", BASE, {"a": 1, "learning": "one"}), 5),
       op("amb-2", node("wv-amb"), patch("metadata", BASE, {"a": 1, "learning": "two"}), 5)]
full, sub = compare(rows, ops, ["amb-2"])
check(full["disp"] == {"amb-1": "ambiguous_same_lineage", "amb-2": "ambiguous_same_lineage"},
      "both members of the collision are refused", full["disp"])
check(rule_a_allows(full, ops, ["amb-2"]), "rule (a) allows deleting a collision member")
check(full["state"]["nodes"][0][3] == '{"a": 1}', "full catalog leaves the row untouched",
      full["state"]["nodes"])
check(sub["state"]["nodes"][0][3] == '{"a":1,"learning":"one"}' and sub["disp"].get("amb-1") == "applied",
      "after the deletion the survivor applies and the graph changes", (sub["disp"], sub["state"]["nodes"]))

# --- Converse: delete operations alone are removable ------------------------
print("=== deleting only delete operations changes nothing ===")
rows = [("wv-fk", "fork", "todo", json.dumps(MAIN), "agent-a", 10),
        ("wv-anchor", "anchor", "todo", "{}", "agent-a", 1),
        ("wv-held", "held", "todo", "{}", "agent-z", 10)]
ops = [
    op("gone-create", node("wv-gone"), create("gone"), 1),
    op("gone-patch", node("wv-gone"), patch("status", "todo", "active"), 2),
    op("gone-delete", node("wv-gone"), {"kind": "node_delete"}, 3),
    op("edge-create", edge("wv-anchor", "wv-fk", "relates_to"),
       {"kind": "edge_create", "row": {"weight": "1.0", "context": "{}", "created_at": "2026-07-20 00:00:00"}}, 2),
    op("edge-delete", edge("wv-anchor", "wv-fk", "relates_to"), {"kind": "edge_delete"}, 3),
    op("stale-delete", node("wv-held"), {"kind": "node_delete"}, 4),
    op("fk-main", node("wv-fk"), patch("metadata", BASE, MAIN), 10),
    op("fk-branch", node("wv-fk"), patch("metadata", BASE, BRANCH), 9),
]
names = {n for n, _ in ops}
deletes = [n for n, doc in ops if doc["payload"]["mutation"]["kind"] in ("node_delete", "edge_delete")]
check(deletes == ["gone-delete", "edge-delete", "stale-delete"], "the catalog holds node and edge deletes", deletes)

# Durable state is what the full catalog produced, as state.sql would hold it.
seed = fresh_db(rows)
first = evaluate(seed, ops, names)
check(first["disp"].get("gone-delete") == "applied" and first["disp"].get("edge-delete") == "applied"
      and first["disp"].get("stale-delete") == "precondition_conflict",
      "deletes apply, and a stale delete is refused", first["disp"])
check(first["lost"] == [("wv-fk", "metadata", ["p"])], "the catalog carries a live lost write", first["lost"])
check([r[0] for r in first["state"]["nodes"]] == ["wv-anchor", "wv-fk", "wv-held"]
      and first["state"]["edges"] == []
      and first["state"]["tombstones"] == [("edge", "wv-anchor:wv-fk:relates_to", 3, "agent-a"),
                                           ("node", "wv-gone", 3, "agent-a")],
      "durable state holds tombstones, not the deleted rows", first["state"])

subsets = [[d] for d in deletes] + [deletes]
for removed in subsets:
    a = TMP / f"a{counter}.db"
    b = TMP / f"b{counter}.db"
    shutil.copy(seed, a)
    shutil.copy(seed, b)
    keep_all = evaluate(a, ops, names)
    keep_sub = evaluate(b, ops, names - set(removed))
    check(keep_sub["raw_lost"] == keep_all["raw_lost"],
          f"removing {removed} leaves the lost-write report identical", (keep_all["lost"], keep_sub["lost"]))
    check(keep_sub["state"] == keep_all["state"],
          f"removing {removed} leaves nodes, edges and tombstones identical",
          (keep_all["state"], keep_sub["state"]))

# --- A create is a detector input too -----------------------------------------
# The re-entry test counts the status a node was created with, so the create
# in the B2 lifecycle is what makes todo "written twice". Deleting it alone,
# under the same rule (a), turns the final todo->active refusal into a loss.
print("=== a create is a detector input: deleting it adds a phantom loss ===")
rows = [("wv-seq", "seq", "done", "{}", "agent-a", 5)]
ops = [op("cr-create", node("wv-seq"), create("seq"), 1),
       op("cr-1", node("wv-seq"), patch("status", "todo", "blocked"), 2),
       op("cr-2", node("wv-seq"), patch("status", "blocked", "todo"), 3),
       op("cr-3", node("wv-seq"), patch("status", "todo", "active"), 4)]
full, sub = compare(rows, ops, ["cr-create"])
check(full["lost"] == [] and rule_a_allows(full, ops, ["cr-create"]),
      "full lifecycle reports nothing and rule (a) allows deleting the create", full["lost"])
check(sub["lost"] == [("wv-seq", "status", {"current": "done", "value": "active"})],
      "after deleting the create, todo->active is reported as lost", sub["lost"])

print(f"Results: {passed}/{ran} passed")
sys.exit(0 if passed == ran else 1)
PY
