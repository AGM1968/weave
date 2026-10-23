#!/usr/bin/env bash
# test-delta-replay-order.sh — v1 SQL delta replay is ordered by lineage, not the
# wall-clock filename epoch (wv-5a2627).
#
# cmd_load used `find -printf %f | sort` — a lexical sort of variable-width epoch
# prefixes that a skewed machine files in the wrong place. For a guarded
# INSERT/UPDATE the per-row lineage guard makes the end state converge regardless
# of order, but an INSERT(seq=N) + DELETE(seq>N) pair diverges: replayed
# DELETE-first the row is recreated and survives; replayed in causal order it is
# gone. wv_delta_changeset now writes a `/* weave-lineage seq= actor= */` header and
# cmd_load sorts the replay by (seq, actor); a headerless legacy delta sorts
# first at seq 0.

set -eu
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
export WV_CALL_SOURCE=test

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$REPO_ROOT/scripts/wv"

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
export WV_HOT_ZONE="$TEST_DIR/hot"
WV_DB="$TEST_DIR/hot/brain.db"   # not exported — see test-tombstone-reconcile.sh
export WEAVE_DIR="$TEST_DIR/.weave"
export WV_PROJECT_DIR="$TEST_DIR"
export WV_AGENT_ID="replay-order-agent"
export WV_REQUIRE_LEARNING=0
export WV_AUTO_CHECKPOINT=0
mkdir -p "$WV_HOT_ZONE" "$WEAVE_DIR"
cd "$TEST_DIR"
git init -q 2>/dev/null || true

pass=0; run=0
ok()  { echo "  ✓ $1"; pass=$((pass + 1)); run=$((run + 1)); }
bad() { echo "  ✗ $1"; run=$((run + 1)); }
present() { [ "$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM nodes WHERE id='$1';" 2>/dev/null || echo 0)" != "0" ]; }
val() { sqlite3 "$WV_DB" "SELECT $2 FROM nodes WHERE id='$1';" 2>/dev/null || echo ""; }

"$WV" init >/dev/null 2>&1
"$WV" sync >/dev/null 2>&1   # materialise state.sql — cmd_load only replays deltas when it exists
D="$WEAVE_DIR/deltas/2026-01-01"
mkdir -p "$D"

node_insert() { # id seq actor text -> guarded INSERT (wv_delta_changeset shape)
    printf "INSERT INTO nodes(id,text,status,metadata,alias,created_at,updated_at,lineage_seq,lineage_actor) VALUES('%s','%s','todo','{}',NULL,'2026-01-01 00:00:00','2026-01-01 00:00:00',%s,'%s') ON CONFLICT(id) DO UPDATE SET text=excluded.text, lineage_seq=excluded.lineage_seq, lineage_actor=excluded.lineage_actor WHERE nodes.lineage_seq = 0 OR %s > nodes.lineage_seq OR (%s = nodes.lineage_seq AND '%s' > nodes.lineage_actor);\n" \
        "$1" "$4" "$2" "$3" "$2" "$2" "$3"
}

# ── INSERT(seq 3) at a LATE epoch, DELETE(seq 7) at an EARLY epoch ─────────────
# Filename sort → DELETE then INSERT → wv-ord resurrected.
# Lineage sort  → INSERT then DELETE → wv-ord gone (causally correct).
{ echo "/* weave-lineage seq=3 actor=aa */"; node_insert wv-ord 3 aa "ordered"; } > "$D/9999999999-000000-000-aa-1.sql"
{ echo "/* weave-lineage seq=7 actor=aa */"; echo "DELETE FROM nodes WHERE id='wv-ord' AND lineage_seq <= 7;"; } > "$D/1111111111-000000-000-aa-2.sql"

# ── variable-width epoch: OLD(seq 2) 11-digit epoch, NEW(seq 5) 10-digit ───────
# Lexical filename sort misorders the widths; lineage sort applies NEW last.
{ echo "/* weave-lineage seq=2 actor=aa */"; node_insert wv-vw 2 aa "OLD"; } > "$D/99999999999-000000-000-aa-3.sql"
{ echo "/* weave-lineage seq=5 actor=aa */"; node_insert wv-vw 5 aa "NEW"; } > "$D/10000000000-000000-000-aa-4.sql"

# ── headerless legacy delta — must still replay, sorts first at seq 0 ──────────
node_insert wv-leg 0 '' "legacy" > "$D/1000000000-000000-000-legacy-5.sql"

rm -rf "$WV_HOT_ZONE"; mkdir -p "$WV_HOT_ZONE"
"$WV" load >/dev/null 2>&1

present wv-leg && ok "headerless legacy delta still replays" || bad "headerless legacy delta was dropped"
present wv-ord && bad "INSERT+DELETE replayed out of causal order — node resurrected" \
    || ok "INSERT(seq 3) + DELETE(seq 7) replay in lineage order — node gone"
[ "$(val wv-vw text)" = "NEW" ] && ok "variable-width epochs: higher-lineage write wins" \
    || bad "variable-width epochs misordered (text=$(val wv-vw text))"

# ── the writer now emits a lineage header ─────────────────────────────────────
N=$("$WV" add "header emission check" --status=todo | tail -1)
export WV_SYNC_INTERVAL=0
"$WV" add "second" --status=todo >/dev/null 2>&1   # a mutation to force auto_sync
hdr_file=$(find "$WEAVE_DIR/deltas" -name '*.sql' -newer "$D/1000000000-000000-000-legacy-5.sql" 2>/dev/null | head -1)
if [ -n "$hdr_file" ] && head -n1 "$hdr_file" | grep -qE '^/[*] weave-lineage seq=[0-9]+ actor=[^ ]+ [*]/$'; then
    ok "wv_delta_changeset writes a /* weave-lineage */ header"
else
    bad "no lineage header in emitted delta ($hdr_file)"
fi

# ── existing replay still works end-to-end (regression) ───────────────────────
rm -rf "$WV_HOT_ZONE"; mkdir -p "$WV_HOT_ZONE"
"$WV" load >/dev/null 2>&1
present "$N" && ok "round-trip: a normally-synced node survives reload" \
    || bad "round-trip: node lost after reload"

echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
