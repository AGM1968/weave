#!/usr/bin/env bash
# test-load-fts-rebuild.sh — wv load re-derives nodes_fts AFTER delta replay
# (wv-d2e6c6, fixed 8b01e9b14; this guard is wv-960a9e).
#
# nodes_fts is external-content over a TEXT-primary-key table. A replayed
# INSERT OR REPLACE for a node already imported from state.sql deletes the old
# row and inserts at a new rowid; with recursive_triggers OFF the implicit
# delete never fires nodes_ad, so the index keeps an entry at the old rowid.
# Neither PRAGMA integrity_check nor FTS5 'integrity-check' sees it, and it
# later surfaces as SQLITE_CORRUPT from the nodes_au trigger. The post-replay
# db_rebuild_fts in cmd_load clears it. test-sprint2b.sh covers doctor's
# detect/repair of an orphan made by hand; nothing drove the load path, and
# removing the rebuild left every load/replay suite green (cloud probe
# wv-0b9d5c, fts-4).

set -eu
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
export WV_AGENT_ID="load-fts-agent"
export WV_REQUIRE_LEARNING=0
export WV_AUTO_CHECKPOINT=0
mkdir -p "$WV_HOT_ZONE" "$WEAVE_DIR"
cd "$TEST_DIR"
git init -q 2>/dev/null || true

pass=0; run=0
ok()  { echo "  ✓ $1"; pass=$((pass + 1)); run=$((run + 1)); }
bad() { echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; run=$((run + 1)); }

orphans() {
    sqlite3 "$WV_DB" "CREATE VIRTUAL TABLE temp.v USING fts5vocab(main, nodes_fts, instance);
        SELECT count(DISTINCT doc) FROM temp.v WHERE doc NOT IN (SELECT rowid FROM nodes);" 2>/dev/null
}

echo "wv load: nodes_fts after delta replay (wv-960a9e)"
"$WV" init >/dev/null 2>&1
id=$("$WV" add "quokka original text" 2>/dev/null | grep -oE 'wv-[0-9a-f]{6}' | head -1)
"$WV" sync >/dev/null 2>&1   # state.sql carries the node; cmd_load replays only when it exists
[ -n "$id" ] && ok "fixture node created ($id)" || bad "fixture node created"

# A legacy-shape v1 delta that REPLACEs the node state.sql already holds.
D="$WEAVE_DIR/deltas/2026-01-01"
mkdir -p "$D"
# Headered and late: a headerless delta older than the checkpoint is skipped as
# legacy pre-checkpoint, which would make this test pass without replaying.
{ echo "/* weave-lineage seq=999 actor=zz */"
  printf "INSERT OR REPLACE INTO nodes(id,text,status,metadata,created_at,updated_at,lineage_seq,lineage_actor) VALUES('%s','wombat replaced text','todo','{}','2026-01-01 00:00:00','2026-01-01 00:00:00',999,'zz');\n" "$id"
} > "$D/9999999999-000000-000-zz-1.sql"

rm -rf "$WV_HOT_ZONE"; mkdir -p "$WV_HOT_ZONE"
"$WV" load >/dev/null 2>&1

[ "$(sqlite3 "$WV_DB" "SELECT text FROM nodes WHERE id='$id';" 2>/dev/null)" = "wombat replaced text" ] \
    && ok "the REPLACE delta was replayed (precondition)" \
    || bad "the REPLACE delta was replayed (precondition)" "text=$(sqlite3 "$WV_DB" "SELECT text FROM nodes WHERE id='$id';" 2>/dev/null)"
got=$(orphans)
[ "$got" = "0" ] && ok "no orphaned nodes_fts entry after the replay" \
    || bad "no orphaned nodes_fts entry after the replay" "orphaned docs: $got"
hits=$(sqlite3 "$WV_DB" "SELECT count(*) FROM nodes_fts WHERE nodes_fts MATCH 'wombat';" 2>/dev/null)
[ "$hits" = "1" ] && ok "the index finds the replayed text" \
    || bad "the index finds the replayed text" "MATCH 'wombat' hits: $hits"
stale=$(sqlite3 "$WV_DB" "SELECT count(*) FROM nodes_fts WHERE nodes_fts MATCH 'quokka';" 2>/dev/null)
[ "$stale" = "0" ] && ok "the index no longer returns the replaced text" \
    || bad "the index no longer returns the replaced text" "MATCH 'quokka' hits: $stale"

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
