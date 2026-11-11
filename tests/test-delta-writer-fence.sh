#!/usr/bin/env bash
# test-delta-writer-fence.sh -- Stage B prerequisite 5 (wv-aac412) of
# docs/PROPOSAL-delta-retention.md: every state.sql writer refuses a database
# loaded before a compaction in the tree, and wv load recovers its unsynced
# work.
#
# The stale clone is made the way a pull would make it: a peer edits a node,
# syncs, then compacts (deletes the delta files that carried the edit and
# leaves a seq-floor record); the clone receives the peer's state.sql and the
# record but keeps its live database. The peer's edit now exists only in that
# state.sql, so any dump from the clone's database would erase it.
#
# GIT_* is unset first: an exported GIT_DIR would point the scratch
# repositories at the real one (wv-8f1da6).

set -u
while IFS= read -r _v; do unset "$_v"; done < <(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p')
export WV_TEST_SUITE=1
export WV_CALL_SOURCE=test

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$REPO_ROOT/scripts/wv"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export WV_CONFIG_DIR="$T/cfg"
export WV_AGENT_ID="fence-test"
export WV_REQUIRE_LEARNING=0
export WV_AUTO_CHECKPOINT=0
export WV_NONINTERACTIVE=1
export WV_SYNC_INTERVAL=0
mkdir -p "$WV_CONFIG_DIR"

pass=0; run=0
ok()  { echo "  ✓ $1"; pass=$((pass + 1)); run=$((run + 1)); }
bad() { echo "  ✗ $1"; run=$((run + 1)); }
check() { local msg="$1"; shift; if "$@"; then ok "$msg"; else bad "$msg"; fi; }

# use DIR -- point wv at the repository DIR with its own hot zone.
use() {
    export WV_PROJECT_DIR="$1" WEAVE_DIR="$1/.weave" WV_HOT_ZONE="$1/.hot"
    unset WV_DB
    mkdir -p "$WV_HOT_ZONE"; chmod 700 "$WV_HOT_ZONE"
    cd "$1" || exit 1
}
db() { echo "$WV_HOT_ZONE/brain.db"; }
text_of() { sqlite3 "$(db)" "SELECT text FROM nodes WHERE id = '$1';"; }
deltas() { find "$WEAVE_DIR/deltas" -type f | LC_ALL=C sort; }
lib() { bash -c "source '$REPO_ROOT/scripts/lib/wv-delta.sh' && $1"; }
add_node() { "$WV" add "$1" --criteria=c --risks=low 2>&1 | sed -nE 's/^✓ (wv-[a-f0-9]{6}): .*/\1/p' | head -1; }

# ── library ─────────────────────────────────────────────────────────────────
echo "--- fence predicate ---"
L="$T/lib"; mkdir -p "$L/.weave"
sqlite3 "$L/db" "CREATE TABLE nodes(id TEXT);"
check "no compaction records: open, even for a database without the table" \
    lib "wv_compaction_fence '$L/db' '$L/.weave'"
lib "wv_lineage_seq_floor_record '$L/.weave' 20261101T000000Z-a 10"
out=$(lib "wv_compaction_fence '$L/db' '$L/.weave'"); rc=$?
check "a record and no absorbed table: fenced, naming the record" \
    test "$rc" -ne 0 -a "$out" = "20261101T000000Z-a"
lib "wv_compaction_mark_absorbed '$L/db' \"\$(wv_compaction_epochs '$L/.weave')\""
check "after the mark: open" lib "wv_compaction_fence '$L/db' '$L/.weave'"
lib "wv_lineage_seq_floor_record '$L/.weave' 20261031T000000Z-b 20"
out=$(lib "wv_compaction_fence '$L/db' '$L/.weave'"); rc=$?
check "a record merged in later, even with an older stamp: fenced on that one only" \
    test "$rc" -ne 0 -a "$out" = "20261031T000000Z-b"
out=$(lib "wv_compaction_fence '$L/missing.db' '$L/.weave'"); rc=$?
check "an unreadable database is fenced" test "$rc" -ne 0 -a -n "$out"

# ── fixture: a clone and a peer that compacts ───────────────────────────────
echo "--- fixture ---"
R="$T/clone"; mkdir -p "$R"; use "$R"
git init -q && git config user.email t@t && git config user.name t
"$WV" init >/dev/null 2>&1
N_PEER=$(add_node "peer target")
N_LOCAL=$(add_node "local target")
N_GONE=$(add_node "to delete")
"$WV" sync >/dev/null 2>&1
"$WV" load >/dev/null 2>&1

P="$T/peer"; cp -a "$R" "$P"; rm -rf "$P/.hot"; use "$P"
"$WV" load >/dev/null 2>&1
before_peer=$(deltas)
"$WV" update "$N_PEER" --text="peer edit" >/dev/null 2>&1
"$WV" sync >/dev/null 2>&1
# Compaction: the files that carried the edit go, a floor record stays.
comm -13 <(printf '%s\n' "$before_peer") <(deltas) | xargs -r rm -f
lib "wv_lineage_seq_floor_record '$WEAVE_DIR' 20261106T000000Z-peer \"\$(wv_lineage_seq_base '$(db)' '$WEAVE_DIR/deltas')\""
check "peer: the edit is in its state.sql and in no delta" bash -c \
    "grep -q 'peer edit' '$P/.weave/state.sql' && ! grep -rq 'peer edit' '$P/.weave/deltas'"

# The pull: the clone's tree takes the peer's state and record; its database
# does not move.
use "$R"
cp "$P/.weave/state.sql" "$P/.weave/nodes.jsonl" "$P/.weave/edges.jsonl" "$R/.weave/"
mkdir -p "$R/.weave/compaction"; cp "$P/.weave/compaction/"*.seq-floor "$R/.weave/compaction/"
cp "$R/.weave/state.sql" "$T/pulled.sql"
check "clone: its database is stale (no peer edit)" test "$(text_of "$N_PEER")" = "peer target"

# ── each writer refuses ─────────────────────────────────────────────────────
echo "--- writers ---"
d0=$(deltas)
out=$("$WV" update "$N_LOCAL" --text="local edit" 2>&1)
check "auto_sync: state.sql is not written" cmp -s "$R/.weave/state.sql" "$T/pulled.sql"
check "...it says why, naming the compaction" grep -q "20261106T000000Z-peer" <<< "$out"
check "...and the change is published as a delta" bash -c \
    "comm -13 <(printf '%s\n' \"\$1\") <(find '$R/.weave/deltas' -type f | LC_ALL=C sort) | xargs -r grep -l 'local edit' | grep -q ." _ "$d0"

d1=$(deltas); rc=0
out=$(WV_AUTO_SYNC=0 "$WV" update "$N_LOCAL" --text="unsynced edit" 2>&1 && "$WV" sync 2>&1) || rc=$?
check "wv sync: refused" test "$rc" -ne 0
check "...state.sql is not written" cmp -s "$R/.weave/state.sql" "$T/pulled.sql"
check "...and nothing is emitted" test "$(deltas)" = "$d1"

WV_AUTO_SYNC=0 "$WV" delete "$N_GONE" --force >/dev/null 2>&1
check "removal re-dump: state.sql is not written" cmp -s "$R/.weave/state.sql" "$T/pulled.sql"

# ── recovery ────────────────────────────────────────────────────────────────
echo "--- recovery ---"
"$WV" load >"$T/load.out" 2>&1
check "wv load keeps the peer's edit" test "$(text_of "$N_PEER")" = "peer edit"
check "...and the clone's unsynced edit" test "$(text_of "$N_LOCAL")" = "unsynced edit"
check "...and its unsynced deletion" test -z "$(sqlite3 "$(db)" "SELECT id FROM nodes WHERE id = '$N_GONE';")"
rc=0; "$WV" sync >/dev/null 2>&1 || rc=$?
check "after the reload wv sync writes again" test "$rc" -eq 0
check "...a state.sql holding both edits" bash -c \
    "grep -q 'peer edit' '$R/.weave/state.sql' && grep -q 'unsynced edit' '$R/.weave/state.sql'"
rm -rf "$R/.hot"; "$WV" load >/dev/null 2>&1
check "...that a cold load reproduces" test "$(text_of "$N_PEER")/$(text_of "$N_LOCAL")" = "peer edit/unsynced edit"

echo ""
echo "$pass/$run passed"
[ "$pass" -eq "$run" ]
