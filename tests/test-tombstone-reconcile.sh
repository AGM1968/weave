#!/usr/bin/env bash
# test-tombstone-reconcile.sh — cross-machine deletion tombstones (wv-0d5e07).
#
# wv delete / wv prune write a `tombstones` row (kind,id,lineage_seq,lineage_actor)
# in place of the gitignored, machine-local .weave/.prune_epoch. The row travels
# in state.sql; cmd_load's _reconcile_tombstones removes any node/edge the v1
# delta back-catalog resurrected at or below its tombstone lineage, while a
# genuine higher-lineage recreate survives, and — unlike the old epoch cutoff —
# an unrelated agent's not-yet-replayed work is never skipped.

set -eu
export WV_CALL_SOURCE=test

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$REPO_ROOT/scripts/wv"

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
export WV_HOT_ZONE="$TEST_DIR/hot"
# Deliberately NOT exporting WV_DB: a caller-supplied WV_DB sets WV_DB_CUSTOM=1,
# which disables auto_sync and therefore delta emission (test isolation guard).
# wv derives it as $WV_HOT_ZONE/brain.db (resolve_db); mirror that for asserts.
WV_DB="$WV_HOT_ZONE/brain.db"
export WEAVE_DIR="$TEST_DIR/.weave"
export WV_PROJECT_DIR="$TEST_DIR"
export WV_AGENT_ID="tombstone-test-agent"
export WV_REQUIRE_LEARNING=0
export WV_AUTO_CHECKPOINT=0
export WV_SYNC_INTERVAL=0   # emit a delta changeset on every auto_sync, no throttle
mkdir -p "$WV_HOT_ZONE" "$WEAVE_DIR"
cd "$TEST_DIR"
git init -q 2>/dev/null || true
git config user.email t@t 2>/dev/null || true
git config user.name t 2>/dev/null || true

pass=0; run=0
ok()  { echo "  ✓ $1"; pass=$((pass + 1)); run=$((run + 1)); }
bad() { echo "  ✗ $1"; run=$((run + 1)); }
node_present() { [ "$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM nodes WHERE id='$1';" 2>/dev/null || echo 0)" != "0" ]; }
fresh_reload() { rm -rf "$WV_HOT_ZONE"; mkdir -p "$WV_HOT_ZONE"; "$WV" load >/dev/null 2>&1; }

"$WV" init >/dev/null 2>&1

# ── Setup: three nodes, each with a committed creation delta ────────────────────
A=$("$WV" add "tombstone A — deleted, must not resurrect" --status=todo | tail -1)
B=$("$WV" add "tombstone B — survivor" --status=todo | tail -1)
"$WV" link "$A" "$B" --type=relates_to >/dev/null 2>&1 || true
"$WV" sync >/dev/null 2>&1

# Snapshot state.sql BEFORE node C exists — this is the "old clone" view.
cp "$WEAVE_DIR/state.sql" "$TEST_DIR/state.sql.pre-C"

C=$("$WV" add "tombstone C — unrelated, un-replayed work of another agent" --status=todo | tail -1)
"$WV" sync >/dev/null 2>&1
[ -n "$(find "$WEAVE_DIR/deltas" -name '*.sql' 2>/dev/null)" ] && ok "creation deltas were emitted to .weave/deltas" \
    || bad "creation deltas were emitted to .weave/deltas"

# Roll state.sql back so C lives ONLY in its delta file (not the snapshot), and
# drop C from the live DB too — C is now exactly "another agent's synced-but-not-
# yet-replayed-here" work.
cp "$TEST_DIR/state.sql.pre-C" "$WEAVE_DIR/state.sql"
sqlite3 "$WV_DB" "DELETE FROM nodes WHERE id='$C';"
# Clear the change tracker so this test-only surgery is not itself emitted as a
# propagating DELETE delta by the next auto_sync.
sqlite3 "$WV_DB" "DELETE FROM _warp_changes;" 2>/dev/null || true

# ── 1. wv delete writes a tombstone instead of .weave/.prune_epoch ─────────────
"$WV" delete "$A" --force --no-gh >/dev/null 2>&1
[ ! -e "$WEAVE_DIR/.prune_epoch" ] && ok "wv delete does not create .weave/.prune_epoch" \
    || bad "wv delete does not create .weave/.prune_epoch"
tomb_seq=$(sqlite3 "$WV_DB" "SELECT lineage_seq FROM tombstones WHERE kind='node' AND id='$A';" 2>/dev/null || echo "")
[ -n "$tomb_seq" ] && ok "wv delete records a node tombstone row" \
    || bad "wv delete records a node tombstone row"
edge_tombs=$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM tombstones WHERE kind='edge' AND (id LIKE '$A:%' OR id LIKE '%:$A:%');" 2>/dev/null || echo 0)
[ "${edge_tombs:-0}" -ge 1 ] && ok "wv delete records a tombstone for the incident edge" \
    || bad "wv delete records a tombstone for the incident edge (got $edge_tombs)"

# tombstones must be carried in the committed snapshot so a delete travels.
grep -q "INSERT INTO tombstones" "$WEAVE_DIR/state.sql" && ok "tombstone rows are dumped into state.sql" \
    || bad "tombstone rows are dumped into state.sql"

# ── 2. fresh reload: delta back-catalog cannot resurrect a tombstoned node ─────
fresh_reload
node_present "$B" && ok "reload: untouched node B still present" || bad "reload: untouched node B missing"
node_present "$A" && bad "reload: deleted node A was resurrected by its creation delta" \
    || ok "reload: _reconcile_tombstones removed the resurrected node A"

# ── 3. an unrelated agent's un-replayed delta is NOT skipped by a local delete ─
node_present "$C" && ok "reload: unrelated un-replayed node C was applied (no epoch-cutoff skip)" \
    || bad "reload: unrelated node C was wrongly skipped — .prune_epoch regression"

# ── 3b. wv prune also tombstones (not .prune_epoch) and the row survives reload ─
P=$("$WV" add "tombstone P — to be pruned" --status=todo | tail -1)
"$WV" done "$P" >/dev/null 2>&1
sqlite3 "$WV_DB" "UPDATE nodes SET updated_at = datetime('now','-72 hours') WHERE id='$P';"
"$WV" prune --age=48h >/dev/null 2>&1
[ ! -e "$WEAVE_DIR/.prune_epoch" ] && ok "wv prune does not create .weave/.prune_epoch" \
    || bad "wv prune does not create .weave/.prune_epoch"
[ -n "$(sqlite3 "$WV_DB" "SELECT 1 FROM tombstones WHERE kind='node' AND id='$P';")" ] \
    && ok "wv prune records a node tombstone row" || bad "wv prune records a node tombstone row"
fresh_reload
node_present "$P" && bad "reload: pruned node P was resurrected" \
    || ok "reload: pruned node P stays gone (tombstone enforced)"
node_present "$C" && ok "reload: node C still present after prune+reload" \
    || bad "reload: node C lost after prune+reload"

# ── 4. wv unarchive clears the deletion tombstone so a restore is not re-reaped ─
"$WV" unarchive "$B" >/dev/null 2>&1 || true   # B is live; exercises the no-op path
"$WV" delete "$C" --force --no-gh >/dev/null 2>&1
[ -n "$(sqlite3 "$WV_DB" "SELECT 1 FROM tombstones WHERE kind='node' AND id='$C';")" ] \
    && ok "wv delete tombstones C" || bad "wv delete tombstones C"
"$WV" unarchive "$C" >/dev/null 2>&1
node_present "$C" && ok "wv unarchive restores a deleted node" || bad "wv unarchive restores a deleted node"
cleared=$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM tombstones WHERE kind='node' AND id='$C';")
[ "$cleared" = "0" ] && ok "wv unarchive clears the node tombstone" \
    || bad "wv unarchive clears the node tombstone (rows left: $cleared)"

# ── 5. _reconcile_tombstones: a strictly-higher-lineage recreate still applies ──
# Direct predicate check — a resurrected row at or below the tombstone seq is
# removed; a recreate stamped above it survives; pre-cutover (seq 0) is removed.
sqlite3 "$WV_DB" <<'SQL'
INSERT INTO tombstones(kind,id,lineage_seq,lineage_actor) VALUES
    ('node','wv-recr',5,'agent-x'),
    ('node','wv-below',5,'agent-x'),
    ('node','wv-precut',5,'agent-x'),
    ('node','wv-tie-hi',5,'agent-m'),
    ('node','wv-tie-lo',5,'agent-m'),
    ('edge','wv-recr:wv-below:relates_to',5,'agent-x');
INSERT INTO nodes(id,text,status,metadata,lineage_seq,lineage_actor) VALUES
    ('wv-recr','higher-lineage recreate','todo','{}',9,'agent-y'),
    ('wv-below','stale replay at tombstone seq','todo','{}',5,'agent-x'),
    ('wv-precut','pre-cutover resurrection','todo','{}',0,''),
    ('wv-tie-hi','equal seq, higher actor recreate','todo','{}',5,'agent-z'),
    ('wv-tie-lo','equal seq, lower actor replay','todo','{}',5,'agent-a');
INSERT INTO edges(source,target,type,lineage_seq,lineage_actor) VALUES
    ('wv-recr','wv-below','relates_to',3,'agent-x');
SQL
( set +eu
  source "$REPO_ROOT/scripts/lib/wv-delta.sh" 2>/dev/null || true
  source "$REPO_ROOT/scripts/lib/wv-db.sh" 2>/dev/null || true
  source "$REPO_ROOT/scripts/cmd/wv-cmd-data.sh" 2>/dev/null || true
  _reconcile_tombstones "$WV_DB" ) >/dev/null 2>&1
node_present "wv-recr"   && ok "reconcile keeps a strictly-higher-lineage recreate" \
    || bad "reconcile wrongly removed a higher-lineage recreate"
node_present "wv-below"  && bad "reconcile left a stale replay at the tombstone seq" \
    || ok "reconcile removes a replay at the tombstone seq"
node_present "wv-precut" && bad "reconcile left a pre-cutover (seq 0) resurrection" \
    || ok "reconcile removes a pre-cutover (seq 0) resurrection"
[ -z "$(sqlite3 "$WV_DB" "SELECT 1 FROM edges WHERE source='wv-recr' AND target='wv-below';")" ] \
    && ok "reconcile removes a resurrected edge below its tombstone" \
    || bad "reconcile left a resurrected edge below its tombstone"
# Equal lineage_seq must resolve by lineage_actor -- the same (seq, actor)
# tuple order every write-arm guard uses -- not lineage_seq alone. A bare
# `lineage_seq <= tombstone.lineage_seq` deleted a valid recreate whenever it
# happened to share the tombstone's seq and land at a causally later actor.
node_present "wv-tie-hi" && ok "reconcile keeps an equal-seq recreate from a higher actor than the tombstone" \
    || bad "reconcile wrongly removed an equal-seq, higher-actor recreate"
node_present "wv-tie-lo" && bad "reconcile left an equal-seq replay from a lower-or-equal actor than the tombstone" \
    || ok "reconcile removes an equal-seq replay from a lower-or-equal actor than the tombstone"

# ── 6. db_write_tombstone / ON CONFLICT never regresses an existing tombstone ──
sqlite3 "$WV_DB" "INSERT INTO tombstones(kind,id,lineage_seq,lineage_actor) VALUES('node','wv-tstX',9,'agent-hi')
  ON CONFLICT(kind,id) DO UPDATE SET lineage_seq=excluded.lineage_seq;"
sqlite3 "$WV_DB" "INSERT INTO tombstones(kind,id,lineage_seq,lineage_actor) VALUES('node','wv-tstX',3,'agent-lo')
  ON CONFLICT(kind,id) DO UPDATE SET lineage_seq=excluded.lineage_seq, lineage_actor=excluded.lineage_actor
  WHERE (excluded.lineage_seq, excluded.lineage_actor) > (tombstones.lineage_seq, tombstones.lineage_actor);"
kept=$(sqlite3 "$WV_DB" "SELECT lineage_seq FROM tombstones WHERE kind='node' AND id='wv-tstX';")
[ "$kept" = "9" ] && ok "ON CONFLICT keeps the higher tombstone lineage" \
    || bad "ON CONFLICT keeps the higher tombstone lineage (got $kept)"

# ── 7. legacy .weave/.prune_epoch is honoured then migrated when a cutover exists
printf '%s\n' "$(date +%s)" > "$WEAVE_DIR/.prune_epoch"
printf '{"schema":"weave.causal-cutover.v1","lineage_seq":1,"actor":"x","created_at":"2026-01-01T00:00:00Z"}\n' > "$WEAVE_DIR/causal-cutover"
"$WV" load >/dev/null 2>&1
[ ! -e "$WEAVE_DIR/.prune_epoch" ] && ok "cmd_load migrates away a legacy .prune_epoch when a cutover marker exists" \
    || bad "cmd_load migrates away a legacy .prune_epoch when a cutover marker exists"

echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
