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

op=$(find "$OUT" -name '*.json' -type f | sort | head -1)
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
op_again=$(find "$OUT" -name '*.json' -type f | sort | head -1)
second_hash=$(sha256sum "$op_again" | awk '{print $1}')
[ "$written_again" = "1" ] && [ "$first_hash" = "$second_hash" ] \
  && ok "operation identity and bytes are stable for unchanged change row" \
  || bad "operation identity and bytes are stable for unchanged change row"

wv_delta_reset "$DB"
sqlite3 "$DB" "UPDATE nodes SET text='non semantic text edit', updated_at=102 WHERE id='wv-v2';"
rm -rf "$OUT"
written_text=$(wv_delta_v2_write_operations "$DB" "$OUT" "agent-a")
[ "$written_text" = "0" ] && [ ! -d "$OUT" -o -z "$(find "$OUT" -type f -print -quit 2>/dev/null)" ] \
  && ok "non-semantic node updates do not emit Delta v2 operations" \
  || bad "non-semantic node updates do not emit Delta v2 operations"

CLI_REPO="$TMP/cli-repo"
CLI_HOT="$TMP/cli-hot"
mkdir -p "$CLI_REPO"
(
  cd "$CLI_REPO"
  git init -q
  git config user.email test@example.com
  git config user.name Tester
  WV_HOT_ZONE="$CLI_HOT" WV_AUTO_CHECKPOINT=0 "$ROOT/scripts/wv" init >/dev/null
  cli_node=$(
    WV_HOT_ZONE="$CLI_HOT" WV_AUTO_CHECKPOINT=0 "$ROOT/scripts/wv" add "cli delta v2" --status=todo --criteria="c" --risks=low \
      | grep -o 'wv-[a-f0-9]\{6\}' \
      | head -1
  )
  WV_HOT_ZONE="$CLI_HOT" WV_AUTO_CHECKPOINT=0 WV_SYNC_INTERVAL=0 WV_DELTA_V2_WRITE=1 \
    "$ROOT/scripts/wv" update "$cli_node" --status=active --metadata '{"claimed_by":"agent-a","risk_level":"high"}' >/dev/null
)
cli_ops=$(find "$CLI_REPO/.weave/deltas" -path '*/v2/*.json' -type f | wc -l | tr -d ' ')
[ "$cli_ops" = "1" ] \
  && ok "opt-in CLI auto_sync emits one Delta v2 sidecar" \
  || bad "opt-in CLI auto_sync emits one Delta v2 sidecar"

echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
