#!/usr/bin/env bash
# Regression tests for the opt-in Delta v2 operation writer.

set -euo pipefail

export WV_CALL_SOURCE=test

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib/wv-delta.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
DB="$TMP/delta-v2.db"
OUT="$TMP/out"

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
    created_at INTEGER DEFAULT (strftime('%s','now')),
    updated_at INTEGER DEFAULT (strftime('%s','now'))
);
CREATE TABLE edges(
    source TEXT,
    target TEXT,
    type TEXT,
    weight REAL,
    context TEXT,
    created_at INTEGER DEFAULT (strftime('%s','now')),
    PRIMARY KEY(source, target, type)
);"
wv_delta_init "$DB"

sqlite3 "$DB" "INSERT INTO nodes(id,text,status,metadata,created_at,updated_at) VALUES('wv-v2','v2 node','todo','{}',100,100);"
wv_delta_reset "$DB"
sqlite3 "$DB" "UPDATE nodes SET status='active', metadata='{\"claimed_by\":\"agent-a\",\"risk_level\":\"high\"}', updated_at=101 WHERE id='wv-v2';"

written=$(wv_delta_v2_write_operations "$DB" "$OUT" "agent-a")
[ "$written" = "1" ] && ok "writer emits one semantic node patch" || bad "writer emits one semantic node patch"

op=$(find "$OUT" -name '*.json' -type f | sort | sed -n 1p)
[ -n "$op" ] && [ -s "$op" ] && ok "operation JSON sidecar exists" || bad "operation JSON sidecar exists"

node "$ROOT/tests/validate-ipc-contract.mjs" >/dev/null
node - "$op" <<'NODE'
const fs = require("fs");
const crypto = require("crypto");
const op = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const hasLoneSurrogate = value => {
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if (code >= 0xd800 && code <= 0xdbff) {
      const next = value.charCodeAt(index + 1);
      if (!(next >= 0xdc00 && next <= 0xdfff)) return true;
      index += 1;
    } else if (code >= 0xdc00 && code <= 0xdfff) return true;
  }
  return false;
};
const canonical = value => {
  if (value === null) return "null";
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (typeof value === "object") return `{${Object.keys(value).sort().map(key => {
    if (hasLoneSurrogate(key)) throw new Error("bad key");
    return `${JSON.stringify(key)}:${canonical(value[key])}`;
  }).join(",")}}`;
  if (typeof value === "number") {
    if (!Number.isSafeInteger(value) || Object.is(value, -0)) throw new Error("bad number");
    return String(value);
  }
  if (typeof value === "string") {
    if (hasLoneSurrogate(value)) throw new Error("bad string");
    return JSON.stringify(value);
  }
  if (typeof value === "boolean") return JSON.stringify(value);
  throw new Error(`bad type ${typeof value}`);
};
const preimage = structuredClone(op);
delete preimage.operation_sha256;
const expectedHash = crypto.createHash("sha256").update(canonical(preimage), "utf8").digest("hex");
if (op.operation_sha256 !== expectedHash) throw new Error("operation hash mismatch");
const fields = op.payload.mutation.fields;
if (fields.status.expected !== "todo" || fields.status.value !== "active") throw new Error("bad status patch");
if (fields.claimed_by.expected !== null || fields.claimed_by.value !== "agent-a") throw new Error("bad claim patch");
if (fields.risk_level.expected !== "none" || fields.risk_level.value !== "high") throw new Error("bad risk patch");
NODE
ok "operation hash and typed field patches match contract"

first_hash=$(sha256sum "$op" | awk '{print $1}')
rm -rf "$OUT"
written_again=$(wv_delta_v2_write_operations "$DB" "$OUT" "agent-a")
op_again=$(find "$OUT" -name '*.json' -type f | sort | sed -n 1p)
second_hash=$(sha256sum "$op_again" | awk '{print $1}')
[ "$written_again" = "1" ] && [ "$first_hash" = "$second_hash" ] \
  && ok "operation identity and bytes are stable for unchanged change row" \
  || bad "operation identity and bytes are stable for unchanged change row"

wv_delta_reset "$DB"
sqlite3 "$DB" "UPDATE nodes SET updated_at=102 WHERE id='wv-v2';"
rm -rf "$OUT"
written_noop=$(wv_delta_v2_write_operations "$DB" "$OUT" "agent-a")
[ "$written_noop" = "0" ] && [ ! -d "$OUT" -o -z "$(find "$OUT" -type f -print -quit 2>/dev/null)" ] \
  && ok "an updated_at-only touch emits no Delta v2 operation" \
  || bad "an updated_at-only touch emits no Delta v2 operation"

wv_delta_reset "$DB"
sqlite3 "$DB" "UPDATE nodes SET text='revised body', updated_at=103 WHERE id='wv-v2';"
rm -rf "$OUT"
written_text=$(wv_delta_v2_write_operations "$DB" "$OUT" "agent-a")
text_op=$(find "$OUT" -name '*.json' -type f | sort | sed -n 1p)
text_fields=$(python3 -c "import json,sys; print(','.join(sorted(json.load(open(sys.argv[1]))['payload']['mutation']['fields'])))" "$text_op" 2>/dev/null || echo "")
[ "$written_text" = "1" ] && [ "$text_fields" = "text" ] \
  && ok "a text column edit emits a node_patch over text" \
  || bad "a text column edit emits a node_patch over text (wrote=$written_text fields=$text_fields)"

# node_create / node_delete / edge_* coverage
wv_delta_reset "$DB"
rm -rf "$OUT"
sqlite3 "$DB" "
INSERT INTO nodes(id,text,status,metadata,created_at,updated_at) VALUES('wv-src','src','todo','{}',110,110);
INSERT INTO nodes(id,text,status,metadata,created_at,updated_at) VALUES('wv-dst','dst','todo','{}',110,110);
INSERT INTO edges(source,target,type,weight,context,created_at) VALUES('wv-src','wv-dst','relates_to',0.8,'{}',110);
DELETE FROM nodes WHERE id='wv-v2';
"
sqlite3 "$DB" "UPDATE edges SET weight=1.5 WHERE source='wv-src';"
sqlite3 "$DB" "DELETE FROM edges WHERE source='wv-src';"
written_all=$(wv_delta_v2_write_operations "$DB" "$OUT" "agent-a")
mapfile -t kinds < <(find "$OUT" -name '*.json' -type f | sort |
  xargs -r -n1 python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['payload']['mutation']['kind'])" | sort -u)
have() { grep -qx "$1" <<< "$(printf '%s\n' "${kinds[@]}")"; }
have node_create && have node_delete && have edge_create && have edge_patch && have edge_delete \
  && ok "writer emits node_create/node_delete/edge_create/edge_patch/edge_delete" \
  || bad "writer emits every op kind (got: ${kinds[*]})"
wt=$(find "$OUT" -name '*.json' -type f | sort |
  xargs -r -n1 python3 -c "import json,sys; o=json.load(open(sys.argv[1])); m=o['payload']['mutation']; print(m.get('fields',{}).get('weight',{}).get('value','') if m['kind']=='edge_patch' else '')" | tr -d '\n')
[ "$wt" = "1.5" ] && ok "edge weight travels as a canonical decimal string" || bad "edge weight travels as a canonical decimal string (got $wt)"
node "$ROOT/tests/validate-ipc-contract.mjs" >/dev/null
while IFS= read -r f; do
  node -e "const Ajv=require('$ROOT/mcp/node_modules/ajv/dist/2020.js').default; const fs=require('fs');
    const ajv=new Ajv({strict:true,allErrors:true});
    ajv.addSchema(JSON.parse(fs.readFileSync('$ROOT/contracts/delta-operation-v2.schema.json')));
    const v=ajv.getSchema('https://weave.dev/contracts/delta-operation-v2.schema.json');
    if(!v(JSON.parse(fs.readFileSync(process.argv[1])))) { console.error(ajv.errorsText(v.errors)); process.exit(1); }" "$f" || bad "emitted op $f fails the v2 schema"
done < <(find "$OUT" -name '*.json' -type f)
ok "every emitted op validates against delta-operation-v2.schema.json"

# Restore wv-v2 for any later assertions and reset tracking.
sqlite3 "$DB" "INSERT INTO nodes(id,text,status,metadata,created_at,updated_at) VALUES('wv-v2','v2 node','active','{\"claimed_by\":\"agent-a\",\"risk_level\":\"high\"}',104,104);"
wv_delta_reset "$DB"
rm -rf "$OUT"

# wv-99c85a item 3: a caller-allocated lineage seq (7th arg) is what the ops carry,
# so auto_sync's v1 changeset and its v2 sidecars share one number by construction.
sqlite3 "$DB" "UPDATE nodes SET text='seq probe', updated_at=105 WHERE id='wv-v2';"
wv_delta_v2_write_operations "$DB" "$OUT" "agent-a" "" "" "" 42 >/dev/null
seq_op=$(find "$OUT" -name '*.json' -type f | sort | sed -n 1p)
seq_got=$(python3 -c "import json,sys; o=json.load(open(sys.argv[1])); print(o['payload']['lineage']['seq'], o['actor_sequence'])" "$seq_op" 2>/dev/null || echo "")
[ "$seq_got" = "42 42" ] && ok "a caller-allocated lineage seq is the seq every op carries" \
  || bad "a caller-allocated lineage seq is the seq every op carries (got '$seq_got')"

# wv-99c85a item 4: the schema forbids a node_patch holding both metadata and a
# sugar field. Control: the metadata-only op the writer emits validates.
wv_delta_reset "$DB"
rm -rf "$OUT"
sqlite3 "$DB" "UPDATE nodes SET metadata=json_set(metadata,'$.note','x'), updated_at=106 WHERE id='wv-v2';"
wv_delta_v2_write_operations "$DB" "$OUT" "agent-a" >/dev/null
meta_op=$(find "$OUT" -name '*.json' -type f | sort | sed -n 1p)
schema_verdicts=$(node -e "const Ajv=require('$ROOT/mcp/node_modules/ajv/dist/2020.js').default; const fs=require('fs');
  const ajv=new Ajv({strict:true,allErrors:true});
  ajv.addSchema(JSON.parse(fs.readFileSync('$ROOT/contracts/delta-operation-v2.schema.json')));
  const v=ajv.getSchema('https://weave.dev/contracts/delta-operation-v2.schema.json');
  const op=JSON.parse(fs.readFileSync(process.argv[1]));
  const out=[Object.keys(op.payload.mutation.fields).join('+'), v(op)];
  for (const [k, p] of [['claimed_by', {expected: 'agent-a', value: null}], ['risk_level', {expected: 'high', value: 'low'}]]) {
    const both=structuredClone(op); both.payload.mutation.fields[k]=p; out.push(v(both));
  }
  console.log(out.join(' '));" "$meta_op" 2>&1)
[ "$schema_verdicts" = "metadata true false false" ] \
  && ok "schema admits a metadata-only node_patch and refuses metadata with claimed_by or risk_level" \
  || bad "schema admits a metadata-only node_patch and refuses metadata with claimed_by or risk_level (got '$schema_verdicts')"

# wv-99c85a item 1: replay refuses a non-finite weight, so the writer must not
# emit one; a poisoned op would roll back every clone's v2 batch.
wv_delta_reset "$DB"
rm -rf "$OUT"
sqlite3 "$DB" "INSERT INTO edges(source,target,type,weight,context,created_at) VALUES('wv-src','wv-dst','blocks',9e999,'{}',120);"
if wv_delta_v2_write_operations "$DB" "$OUT" "agent-a" >/dev/null 2>&1; then
  bad "writer refuses a non-finite edge weight"
else
  ok "writer refuses a non-finite edge weight"
fi
sqlite3 "$DB" "DELETE FROM edges WHERE type='blocks';"
wv_delta_reset "$DB"
rm -rf "$OUT"

CLI_REPO="$TMP/cli-repo"
CLI_HOT="$TMP/cli-hot"
mkdir -p "$CLI_REPO"
(
  cd "$CLI_REPO"
  git init -q
  git config user.email test@example.com
  git config user.name Tester
  WV_HOT_ZONE="$CLI_HOT" WV_AUTO_CHECKPOINT=0 "$ROOT/scripts/wv" init >/dev/null
  # Capture, then match: `| grep -o | sed -n 1p` under pipefail returns the
  # writer's SIGPIPE 141 the moment head leaves (wv-a70659).
  cli_add_out=$(
    WV_HOT_ZONE="$CLI_HOT" WV_AUTO_CHECKPOINT=0 "$ROOT/scripts/wv" add "cli delta v2" \
      --status=todo --criteria="c" --risks=low
  )
  cli_node=""
  [[ "$cli_add_out" =~ (wv-[a-f0-9]{6}) ]] && cli_node="${BASH_REMATCH[1]}"
  # Delta v2 sidecars are on by default post-cutover (S4 wv-806a6b), so the
  # `wv add` above already emitted one. Clear the catalog and count only what
  # the single update below produces.
  rm -rf "$CLI_REPO/.weave/deltas"
  WV_HOT_ZONE="$CLI_HOT" WV_AUTO_CHECKPOINT=0 WV_SYNC_INTERVAL=0 \
    "$ROOT/scripts/wv" update "$cli_node" --status=active --metadata '{"claimed_by":"agent-a","risk_level":"high"}' >/dev/null
)
cli_ops=$(find "$CLI_REPO/.weave/deltas" -path '*/v2/*.json' -type f | wc -l | tr -d ' ')
[ "$cli_ops" = "1" ] \
  && ok "default CLI auto_sync emits one Delta v2 sidecar per change" \
  || bad "default CLI auto_sync emits one Delta v2 sidecar per change"

# ─────────────────────────────────────────────────────────────────────────────
# wv-4a05e7: actor_sequence must survive a hot-zone wipe. The tmpfs
# _warp_changes.id restarts at 1 on every `wv load` rebuild; the durable seed
# comes from the committed v2 catalog and the graph lineage_seq high-water, so
# the second emission must land strictly above the first.
seq_of() { basename "$1" | sed -E 's/^0*([0-9]+)-.*/\1/'; }

DUR_REPO="$TMP/dur-repo"
DUR_HOT="$TMP/dur-hot"
mkdir -p "$DUR_REPO"
(
  cd "$DUR_REPO"
  git init -q
  git config user.email test@example.com
  git config user.name Tester
  common=(WV_HOT_ZONE="$DUR_HOT" WV_AUTO_CHECKPOINT=0 WV_SYNC_INTERVAL=0 WV_DELTA_V2_WRITE=1)
  env "${common[@]}" "$ROOT/scripts/wv" init >/dev/null
  n1=$(env "${common[@]}" "$ROOT/scripts/wv" add "durable one" --status=todo --criteria=c --risks=low | grep -o 'wv-[a-f0-9]\{6\}' | sed -n 1p)
  n2=$(env "${common[@]}" "$ROOT/scripts/wv" add "durable two" --status=todo --criteria=c --risks=low | grep -o 'wv-[a-f0-9]\{6\}' | sed -n 1p)
  env "${common[@]}" "$ROOT/scripts/wv" update "$n1" --status=active --metadata '{"claimed_by":"agent-a"}' >/dev/null
  # Destroy the hot zone: brain.db, sqlite_sequence and all, exactly as a reboot
  # or `wv hotzone gc` would. Rebuild it from committed state.
  rm -rf "$DUR_HOT"
  env "${common[@]}" "$ROOT/scripts/wv" load >/dev/null 2>&1
  env "${common[@]}" "$ROOT/scripts/wv" update "$n2" --status=active --metadata '{"claimed_by":"agent-a"}' >/dev/null
)
# Every add and update now emits a v2 sidecar (node_create / node_patch), so the
# stream carries one op per mutation. The invariant under test is that the
# post-wipe op's actor_sequence lands strictly above every pre-wipe op's — the
# tmpfs _warp_changes.id restarts at 1, the seed does not.
mapfile -t dur_ops < <(find "$DUR_REPO/.weave/deltas" -path '*/v2/*.json' -type f | sort -V)
last_before=$(seq_of "${dur_ops[-2]}")
last_after=$(seq_of "${dur_ops[-1]}")
prev=0; monotonic=1
for opf in "${dur_ops[@]}"; do
  cur=$(seq_of "$opf"); [ "$cur" -gt "$prev" ] || monotonic=0; prev=$cur
done
if [ "${#dur_ops[@]}" -ge 4 ] && [ "$monotonic" = "1" ] && [ "$last_after" -gt "$last_before" ]; then
  ok "actor_sequence climbs monotonically across a hot-zone wipe (last $last_before -> $last_after)"
else
  bad "actor_sequence climbs monotonically across a hot-zone wipe (ops=${#dur_ops[@]} monotonic=$monotonic $last_before -> $last_after)"
fi

# wv-4a05e7 criterion 4: two actors that never observe each other cannot mint
# the same (actor_id, actor_sequence). Seeded from the same catalog they may
# reach the same sequence number; the actor_id component is what keeps the pair
# unique.
SPLIT_DB="$TMP/split.db"
SPLIT_OUT="$TMP/split-out"
sqlite3 "$SPLIT_DB" "
CREATE TABLE nodes(id TEXT PRIMARY KEY, text TEXT, status TEXT DEFAULT 'ready',
    metadata TEXT DEFAULT '{}', alias TEXT UNIQUE,
    created_at INTEGER DEFAULT 0, updated_at INTEGER DEFAULT 0);
CREATE TABLE edges(source TEXT, target TEXT, type TEXT, weight REAL, context TEXT,
    created_at INTEGER DEFAULT 0, PRIMARY KEY(source,target,type));"
wv_delta_init "$SPLIT_DB"
sqlite3 "$SPLIT_DB" "INSERT INTO nodes(id,text,status) VALUES('wv-split','x','todo');"
wv_delta_reset "$SPLIT_DB"
sqlite3 "$SPLIT_DB" "UPDATE nodes SET status='active' WHERE id='wv-split';"
wv_delta_v2_write_operations "$SPLIT_DB" "$SPLIT_OUT/a" "actor-a" "$SPLIT_OUT/root" >/dev/null
wv_delta_v2_write_operations "$SPLIT_DB" "$SPLIT_OUT/b" "actor-b" "$SPLIT_OUT/root" >/dev/null
a_op=$(find "$SPLIT_OUT/a" -name '*.json'); b_op=$(find "$SPLIT_OUT/b" -name '*.json')
a_seq=$(seq_of "$a_op"); b_seq=$(seq_of "$b_op")
a_id=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['actor_id'])" "$a_op")
b_id=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['actor_id'])" "$b_op")
a_oid=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['operation_id'])" "$a_op")
b_oid=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['operation_id'])" "$b_op")
[ "$a_seq" = "$b_seq" ] && [ "$a_id" != "$b_id" ] && [ "$a_oid" != "$b_oid" ] \
  && ok "unrelated actors share a sequence number but not (actor_id, actor_sequence) or operation_id" \
  || bad "unrelated actors share a sequence number but not (actor_id, actor_sequence) or operation_id (a=$a_id:$a_seq b=$b_id:$b_seq)"

echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
