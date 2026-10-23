#!/usr/bin/env bash
# wv-e07ee4: the Delta v2 replay's edge field validators had no negative test,
# so turning 'raise IntegrityError("invalid context value")' into 'pass' survived
# every suite (S0 re-measure 2026-09-28). A hash-valid edge_create carrying a
# bad field must be refused by that validator's own reason; a control op with
# the same shape and a valid value must apply, so a refusal means the field,
# not the fixture. Kept apart from test-delta-v2-replay.sh, whose bytes live
# E6 evidence pins.

set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
export WV_CALL_SOURCE=test

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPLAY="$ROOT/scripts/lib/wv-delta-v2-replay.py"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
run=0
ok() { echo "  ✓ $1"; pass=$((pass + 1)); run=$((run + 1)); }
bad() { echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; run=$((run + 1)); }

fresh_db() {
    rm -f "$TMP/graph.db"
    sqlite3 "$TMP/graph.db" "
CREATE TABLE edges(
    source TEXT, target TEXT, type TEXT,
    weight REAL, context TEXT,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    lineage_actor TEXT NOT NULL DEFAULT '',
    lineage_seq INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY(source, target, type)
);"
}

# make_op <out> <weight-json> <context-json>: a hash-valid edge_create, hashed
# with the replay's own canonicalization so only the field under test is wrong.
make_op() {
    python3 - "$REPLAY" "$1" "$2" "$3" <<'PY'
import importlib.util, json, sys

spec = importlib.util.spec_from_file_location("replay", sys.argv[1])
replay = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(replay)
op = {
    "actor_id": "agent-v",
    "actor_sequence": 7,
    "canonicalization": "weave.canonical-json.v1",
    "format": "weave.delta.v2",
    "operation_id": "3f2b6c1e-5d4a-5b7c-9e8f-0a1b2c3d4e5f",
    "payload": {
        "entity": {"kind": "edge", "source": "wv-a", "target": "wv-b", "type": "relates_to"},
        "lineage": {"actor": "agent-v", "seq": 7},
        "mutation": {"kind": "edge_create", "row": {
            "context": json.loads(sys.argv[4]),
            "created_at": "2026-09-29 00:00:00",
            "weight": json.loads(sys.argv[3]),
        }},
    },
}
op["operation_sha256"] = replay.sha256_text(replay.canonical(op))
with open(sys.argv[2], "w", encoding="utf-8") as fh:
    json.dump(op, fh)
PY
}

# expect <label> <weight-json> <context-json> <disposition> <reason> <edges-after>
expect() {
    local label="$1" weight="$2" context="$3" want_disp="$4" want_reason="$5" want_edges="$6"
    local out rc disp reason edges
    fresh_db
    make_op "$TMP/op.json" "$weight" "$context"
    out=$(python3 "$REPLAY" "$TMP/graph.db" "$TMP/op.json" 2>&1) && rc=0 || rc=$?
    disp=$(jq -r '.results[0].disposition' <<<"$out" 2>/dev/null)
    reason=$(jq -r '.results[0].reason // ""' <<<"$out" 2>/dev/null)
    edges=$(sqlite3 "$TMP/graph.db" 'SELECT count(*) FROM edges;')
    if [ "$disp" = "$want_disp" ] && [ "$reason" = "$want_reason" ] && [ "$edges" = "$want_edges" ]; then
        ok "$label"
    else
        bad "$label" "rc=$rc disposition=$disp reason='$reason' edges=$edges"
    fi
}

echo "Delta v2 replay edge field validation (wv-e07ee4)"
expect "control: a valid edge_create applies" '"1.0"' '"{\"summary\":\"ok\"}"' applied "" 1
expect "a non-string edge context is refused by name and writes nothing" '"1.0"' '5' \
    integrity_failed "invalid context value" 0
expect "a non-numeric edge weight is refused by name and writes nothing" '"heavy"' '"{}"' \
    integrity_failed "invalid weight value" 0

# wv-99c85a item 1: float() parses all of these; the schema's weight_value
# pattern admits none of them.
for w in inf nan +5 1_000 ' 5' '5\n'; do
    expect "float()-parsable weight '$w' outside the schema pattern is refused" \
        "\"$w\"" '"{}"' integrity_failed "invalid weight value" 0
done
expect "an exponent-form weight (what repr(float) emits) applies" '"1e-05"' '"{}"' applied "" 1
expect "a negative decimal weight applies" '"-0.5"' '"{}"' applied "" 1

# make_node_patch <out> <fields-json> [op-id]: a hash-valid node_patch.
make_node_patch() {
    python3 - "$REPLAY" "$1" "$2" "${3:-9a2b6c1e-5d4a-5b7c-9e8f-0a1b2c3d4e5f}" <<'PY'
import importlib.util, json, sys

spec = importlib.util.spec_from_file_location("replay", sys.argv[1])
replay = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(replay)
op = {
    "actor_id": "agent-v",
    "actor_sequence": 8,
    "canonicalization": "weave.canonical-json.v1",
    "format": "weave.delta.v2",
    "operation_id": sys.argv[4],
    "payload": {
        "entity": {"kind": "node", "id": "wv-a"},
        "lineage": {"actor": "agent-v", "seq": 8},
        "mutation": {"kind": "node_patch", "fields": json.loads(sys.argv[3])},
    },
}
op["operation_sha256"] = replay.sha256_text(replay.canonical(op))
with open(sys.argv[2], "w", encoding="utf-8") as fh:
    json.dump(op, fh)
PY
}

# check <label> <want-rc> <want-failures-jq> OPS...: the static --check pass.
check() {
    local label="$1" want_rc="$2" want="$3" out rc got
    shift 3
    out=$(python3 "$REPLAY" --check "$@" 2>&1) && rc=0 || rc=$?
    got=$(jq -c '[.failures[] | [(.path | split("/") | .[-1]), .disposition, .reason]]' <<<"$out" 2>/dev/null)
    if [ "$rc" = "$want_rc" ] && [ "$got" = "$want" ]; then
        ok "$label"
    else
        bad "$label" "rc=$rc failures=$got"
    fi
}

echo ""
echo "Delta v2 node_patch field combination (wv-99c85a item 4)"
make_node_patch "$TMP/meta-only.json" '{"metadata":{"expected":{},"value":{"k":1}}}'
make_node_patch "$TMP/meta-claim.json" \
    '{"metadata":{"expected":{},"value":{"k":1}},"claimed_by":{"expected":null,"value":"x"}}'
make_node_patch "$TMP/meta-risk.json" \
    '{"metadata":{"expected":{},"value":{"k":1}},"risk_level":{"expected":"none","value":"low"}}'
check "control: a metadata-only node_patch passes the static check" 0 '[]' "$TMP/meta-only.json"
check "metadata + claimed_by in one node_patch is refused" 2 \
    '[["meta-claim.json","integrity_failed","metadata patch cannot combine claimed_by/risk_level"]]' \
    "$TMP/meta-claim.json"
check "metadata + risk_level in one node_patch is refused" 2 \
    '[["meta-risk.json","integrity_failed","metadata patch cannot combine claimed_by/risk_level"]]' \
    "$TMP/meta-risk.json"

echo ""
echo "Delta v2 --check reports every hard failure, not the first (wv-99c85a item 2)"
make_op "$TMP/a-bad-weight.json" '"inf"' '"{}"'
make_node_patch "$TMP/b-good.json" '{"text":{"expected":"a","value":"b"}}' 1a2b6c1e-5d4a-5b7c-9e8f-0a1b2c3d4e5f
# Same operation_id as b-good, different payload: an identity_hash_mismatch.
make_node_patch "$TMP/c-dup.json" '{"text":{"expected":"a","value":"c"}}' 1a2b6c1e-5d4a-5b7c-9e8f-0a1b2c3d4e5f
check "a mixed catalog lists the bad weight and the identity mismatch, and exits 2" 2 \
    '[["a-bad-weight.json","integrity_failed","invalid weight value"],["c-dup.json","identity_hash_mismatch","operation_id 1a2b6c1e-5d4a-5b7c-9e8f-0a1b2c3d4e5f seen with a different hash"]]' \
    "$TMP/c-dup.json" "$TMP/a-bad-weight.json" "$TMP/b-good.json"

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ] && [ "$run" -gt 0 ]
