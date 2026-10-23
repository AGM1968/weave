#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# test-hot-zone-reconcile.sh — two copies of one repository's graph (wv-a73141)
#
# A repository with a database in two hot zones has copies that may have
# diverged. The old recovery advice was "sync every copy, then remove one",
# but a successful wv sync of each does not merge them: the second sync's
# state wins and wv load reports precondition conflicts for what it dropped.
# The case here is the one that review reproduced: the SAME node edited in
# both copies, one changing its metadata and the other its text.
#
# Covers:
#   - wv hotzone diff: identical copies exit 0; a divergent node exits 1 and
#     names it with the fields that differ; usage errors exit 2
#   - sync-only recovery loses an edit (the hazard the advice now guards)
#   - the advised procedure (backup, diff, carry the missing change into the
#     kept copy, sync it, remove the other) keeps both edits through a fresh load
#   - the refusal messages (bash) require a backup and wv hotzone diff, and mark
#     a repository found in both zones
#   - every table a sync keeps is compared: copies differing only in file
#     attribution (wv touch) or only in tombstones exit 1 and name the row; a
#     durable table with no comparison is refused (wv-4898f7)
#   - the diff runs from a repository whose placement is refused (whole-zone
#     and per-repository), with no override, touching no hot zone (wv-757de1)
#   - lineage is compared on tombstones, nodes and edges: a threshold, an
#     actor or a node lineage that flips the real reconciliation is reported
#     with both values (wv-60911e)
#   - unreadable files, non-graph databases and a lineage schema in one copy
#     only exit 2; a graph predating tombstones is still compared (wv-57ee72)
#   - the replay clock (MAX nodes.updated_at, read by the legacy-delta guard)
#     is reported when it differs; a real load of a legacy delta diverges
#     without a causal-cutover marker and agrees with one (wv-8d4f7d)
#
# Exit codes:
#   0 - All tests passed
#   1 - Unexpected failure

set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$ROOT/scripts/wv"
RESOLVER="$ROOT/scripts/lib/wv-resolve-runtime.sh"

run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }
has() { if [[ "$3" == *"$2"* ]]; then ok "$1"; else bad "$1" "expected to contain [$2], got [$3]"; fi; }
lacks() { if [[ "$3" != *"$2"* ]]; then ok "$1"; else bad "$1" "did not expect [$2] in [$3]"; fi; }

T=$(mktemp -d /tmp/wv-hot-zone-reconcile-XXXXXX)
trap 'rm -rf "$T"' EXIT
export WV_AUTO_CHECKPOINT=0

# fixture <name> — a repository whose one node exists in two hot zones, A and
# B, each copy edited differently: A adds metadata, B replaces the text.
fixture() {
    local d="$T/$1"
    mkdir -p "$d/repo"
    git -C "$d/repo" init -q
    git -C "$d/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    export WV_CONFIG_DIR="$d/cfg" WV_PROJECT_DIR="$d/repo"
    H=$(echo "$d/repo" | md5sum | cut -c1-8)
    A="$d/za/$H"; B="$d/zb/$H"
    cd "$d/repo" || exit 1
    WV_HOT_ZONE="$A" "$WV" init >/dev/null 2>&1
    local added
    added=$(WV_HOT_ZONE="$A" "$WV" add "original text" --standalone 2>&1)
    [[ "$added" =~ (wv-[0-9a-f]{6}) ]] && ID="${BASH_REMATCH[1]}"
    WV_HOT_ZONE="$A" "$WV" sync >/dev/null 2>&1
    mkdir -p "$B"
    sqlite3 "$A/brain.db" ".backup '$B/brain.db'"
    cp "$A/.repo_root" "$B/.repo_root"
}

edit_both() {
    WV_HOT_ZONE="$A" "$WV" update "$ID" --metadata='{"neutral_field":"kept"}' >/dev/null 2>&1
    WV_HOT_ZONE="$B" "$WV" update "$ID" --text="legacy text" >/dev/null 2>&1
}

# node_state — "text|neutral_field" of the node, read after a fresh load of
# .weave/ into a new hot zone, so it shows what the repository kept.
node_state() {
    local fresh="$T/fresh-$RANDOM"
    WV_HOT_ZONE="$fresh/$H" "$WV" load >/dev/null 2>&1
    WV_HOT_ZONE="$fresh/$H" "$WV" show "$ID" --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin); d = d[0] if isinstance(d, list) else d
m = d.get("metadata") or {}
m = json.loads(m) if isinstance(m, str) else m
print(d["text"] + "|" + str(m.get("neutral_field")))'
}

echo "== wv hotzone diff"
fixture diff
out=$("$WV" hotzone diff "$B/brain.db" "$A/brain.db"); rc=$?
check "identical copies exit 0" "0" "$rc"
has "and say so, naming every durable table" "identical: nodes edges node_files tombstones agree" "$out"
edit_both
out=$("$WV" hotzone diff "$B/brain.db" "$A/brain.db"); rc=$?
check "divergent copies exit 1" "1" "$rc"
has "the divergent node is named with both fields and its lineage" "differs:        node $ID (text metadata lineage " "$out"
out=$("$WV" hotzone diff "$B/brain.db" 2>&1); rc=$?
check "one argument is a usage error (exit 2)" "2" "$rc"
out=$("$WV" hotzone diff "$B/brain.db" "$T/missing.db" 2>&1); rc=$?
check "a missing database is a usage error (exit 2)" "2" "$rc"
check "and creates nothing" "absent" "$([ -e "$T/missing.db" ] && echo present || echo absent)"
before=$(sha256sum "$A/brain.db" "$B/brain.db")
"$WV" hotzone diff "$B/brain.db" "$A/brain.db" >/dev/null 2>&1
check "diff writes to neither database" "$before" "$(sha256sum "$A/brain.db" "$B/brain.db")"

echo "== every table a sync keeps is compared (wv-4898f7)"
# Nodes and edges identical, attribution different: the row a wv touch adds.
fixture files
WV_HOT_ZONE="$B" "$WV" touch "$ID" --files=important.py >/dev/null 2>&1
check "the touch row exists in B only" "0 1" \
    "$(sqlite3 "$A/brain.db" 'SELECT count(*) FROM node_files') $(sqlite3 "$B/brain.db" 'SELECT count(*) FROM node_files')"
out=$("$WV" hotzone diff "$A/brain.db" "$B/brain.db"); rc=$?
check "differing attribution exits 1" "1" "$rc"
has "and names the row" "only in second: file $ID important.py" "$out"
lacks "with nodes and edges identical" "node $ID" "$out"
# Keeping A after carrying the row in: the fresh load keeps the attribution.
WV_HOT_ZONE="$A" "$WV" touch "$ID" --files=important.py >/dev/null 2>&1
out=$("$WV" hotzone diff "$A/brain.db" "$B/brain.db"); rc=$?
check "carried into the kept copy, the copies agree" "0" "$rc"
WV_HOT_ZONE="$A" "$WV" sync >/dev/null 2>&1
rm -rf "$B"
check "and the synced state keeps the attribution" "1" \
    "$(grep -cF -- "INSERT INTO node_files VALUES('$ID','important.py')" "$T/files/repo/.weave/state.sql")"

# Nodes and edges identical, deletion intent different: a node added and
# deleted in one copy leaves a tombstone there and nothing else.
fixture tombs
X=$(WV_HOT_ZONE="$A" "$WV" add "short-lived" --standalone 2>&1)
[[ "$X" =~ (wv-[0-9a-f]{6}) ]] && X="${BASH_REMATCH[1]}"
WV_HOT_ZONE="$A" "$WV" delete "$X" --force --no-gh >/dev/null 2>&1
check "the tombstone exists in A only" "1 0" \
    "$(sqlite3 "$A/brain.db" "SELECT count(*) FROM tombstones WHERE id='$X'") $(sqlite3 "$B/brain.db" "SELECT count(*) FROM tombstones WHERE id='$X'")"
out=$("$WV" hotzone diff "$A/brain.db" "$B/brain.db"); rc=$?
check "differing tombstones exit 1" "1" "$rc"
has "and names the tombstone" "only in first:  tombstone node $X" "$out"
lacks "with nodes identical" "differs:        node" "$out"
lacks "and no node only in one copy" "only in first:  node" "$out"

# A durable table the diff has no comparison for is refused, never skipped.
out=$(bash -c 'source "$1"; WV_DURABLE_TABLES+=(invented_table); wv_graph_diff "$2" "$3"; echo "rc=$?"' \
    _ "$ROOT/scripts/lib/wv-graph-diff.sh" "$A/brain.db" "$B/brain.db" 2>&1)
has "an uncompared durable table exits 2" "rc=2" "$out"
has "and says why" "no comparison for durable table 'invented_table'" "$out"
# The list the diff walks is the list dump_state_sql exports.
dumped=$(bash -c 'source "$1/scripts/lib/wv-db.sh" 2>/dev/null; source "$1/scripts/cmd/wv-cmd-data.sh"; dump_state_sql "$2" /dev/stdout' \
    _ "$ROOT" "$A/brain.db" 2>/dev/null)
for t in nodes edges node_files tombstones; do
    has "dump_state_sql exports $t" "CREATE TABLE $t" "$dumped"
done

echo "== lineage decides what tombstones delete, so it is compared (wv-60911e)"
# lin_state <db> <node seq> <node actor> <tomb seq> <tomb actor> — set the
# node's lineage and its tombstone's in a scratch copy.
lin_state() {
    sqlite3 "$1" "UPDATE nodes SET lineage_seq = $2, lineage_actor = '$3' WHERE id = '$ID';
        INSERT OR REPLACE INTO tombstones (kind, id, lineage_seq, lineage_actor) VALUES ('node', '$ID', $4, '$5');"
}
# survives <db> — 1 when the node survives the real reconciliation on a copy.
survives() {
    local c="$T/reconcile-$RANDOM.db"
    sqlite3 "$1" ".backup '$c'"
    WV_DB="$c" bash -c 'source "$1/scripts/lib/wv-db.sh" 2>/dev/null; source "$1/scripts/lib/wv-delta.sh" 2>/dev/null
        source "$1/scripts/cmd/wv-cmd-data.sh"; _reconcile_tombstones "$2" >/dev/null 2>&1' _ "$ROOT" "$c"
    sqlite3 "$c" "SELECT count(*) FROM nodes WHERE id = '$ID';"
}
fixture lineage
lin_state "$A/brain.db" 15 a 10 a; lin_state "$B/brain.db" 15 a 20 a
out=$("$WV" hotzone diff "$A/brain.db" "$B/brain.db"); rc=$?
check "the same tombstone at thresholds 10 and 20 differs (exit 1)" "1" "$rc"
has "and both thresholds are reported" "differs:        tombstone node $ID (lineage 10:a vs 20:a)" "$out"
check "because reconciliation keeps the node at 15 in one copy only" "1 0" "$(survives "$A/brain.db") $(survives "$B/brain.db")"
lin_state "$A/brain.db" 10 aa 10 a; lin_state "$B/brain.db" 10 aa 10 b
out=$("$WV" hotzone diff "$A/brain.db" "$B/brain.db"); rc=$?
check "the same sequence with another actor differs (exit 1)" "1" "$rc"
has "and both actors are reported" "differs:        tombstone node $ID (lineage 10:a vs 10:b)" "$out"
check "because (10,aa) is above (10,a) and below (10,b)" "1 0" "$(survives "$A/brain.db") $(survives "$B/brain.db")"
lin_state "$A/brain.db" 15 a 20 a; lin_state "$B/brain.db" 25 a 20 a
out=$("$WV" hotzone diff "$A/brain.db" "$B/brain.db"); rc=$?
check "the same node content at another lineage differs (exit 1)" "1" "$rc"
has "and both node lineages are reported" "differs:        node $ID (lineage 15:a vs 25:a)" "$out"
check "because the tombstone at 20 deletes it in one copy only" "0 1" "$(survives "$A/brain.db") $(survives "$B/brain.db")"
lin_state "$B/brain.db" 15 a 20 a
out=$("$WV" hotzone diff "$A/brain.db" "$B/brain.db"); rc=$?
check "matching lineage everywhere compares identical" "0" "$rc"

echo "== an unreadable input is an error, never equality (wv-57ee72)"
printf 'not a database\n' > "$T/a.txt"; printf 'also not\n' > "$T/b.txt"
out=$("$WV" hotzone diff "$T/a.txt" "$T/b.txt" 2>&1); rc=$?
check "two text files exit 2" "2" "$rc"
has "and say the file is not readable as SQLite" "cannot read $T/a.txt as an SQLite database" "$out"
lacks "never identical" "identical" "$out"
sqlite3 "$T/other.db" "CREATE TABLE t(x); INSERT INTO t VALUES (1);"
out=$("$WV" hotzone diff "$A/brain.db" "$T/other.db" 2>&1); rc=$?
check "an SQLite database that is not a graph exits 2" "2" "$rc"
has "and says which table it lacks" "$T/other.db is not a Weave graph: it has no nodes table" "$out"
# A graph predating the optional tables stays comparable.
sqlite3 "$A/brain.db" ".backup '$T/old.db'"
sqlite3 "$T/old.db" "DROP TABLE tombstones;"
out=$("$WV" hotzone diff "$T/old.db" "$A/brain.db" 2>&1); rc=$?
check "a graph without tombstones is compared, not refused" "1" "$rc"
has "and the other copy's tombstone rows are the difference" "only in second: 1 tombstones row(s); the other database has no tombstones table" "$out"
# A graph predating lineage cannot be judged against one that has it.
sqlite3 "$A/brain.db" ".backup '$T/nolin.db'"
sqlite3 "$T/nolin.db" "DROP INDEX IF EXISTS idx_nodes_lineage; DROP INDEX IF EXISTS idx_edges_lineage;
    ALTER TABLE nodes DROP COLUMN lineage_seq; ALTER TABLE nodes DROP COLUMN lineage_actor;
    ALTER TABLE edges DROP COLUMN lineage_seq; ALTER TABLE edges DROP COLUMN lineage_actor;" 2>/dev/null
check "the fixture lost its lineage columns" "0" \
    "$(sqlite3 "$T/nolin.db" "SELECT count(*) FROM pragma_table_info('nodes') WHERE name LIKE 'lineage%'")"
out=$("$WV" hotzone diff "$T/nolin.db" "$A/brain.db" 2>&1); rc=$?
check "a copy without lineage against one with it exits 2" "2" "$rc"
has "and says why" "only one copy carries lineage" "$out"

echo "== the replay clock decides legacy replay, so it is compared (wv-8d4f7d)"
# Copies identical in content and lineage, differing only in updated_at: the
# loader's legacy-delta guard (wv-875c72) reads MAX(nodes.updated_at) and
# skips a pre-wv-875c72 INSERT OR REPLACE delta at or below it.
fixture clock
sqlite3 "$A/brain.db" "UPDATE nodes SET updated_at = 100;"
sqlite3 "$B/brain.db" "UPDATE nodes SET updated_at = 300;"
out=$("$WV" hotzone diff "$A/brain.db" "$B/brain.db"); rc=$?
check "copies differing only in the replay clock differ (exit 1)" "1" "$rc"
has "and both clocks are reported" "differs:        replay clock 100 vs 300" "$out"
lacks "with nothing else reported" "differs:        node" "$out"
CR="$T/clock/repo"
# The catalog holds only the legacy delta: any newer lineage-guarded delta for
# the node would replay after it and restore the text in both copies.
rm -rf "$CR/.weave/deltas"
mkdir -p "$CR/.weave/deltas/legacy"
printf "INSERT OR REPLACE INTO nodes (id, text, status, metadata, created_at, updated_at) VALUES ('%s', 'stale legacy text', 'todo', '{}', 200, 200);\n" \
    "$ID" > "$CR/.weave/deltas/legacy/200-legacy-node.sql"
# loaded_text <db> — the node's text after a fresh load of .weave/ whose
# state.sql is <db>'s export, with the legacy delta in the catalog.
loaded_text() {
    local fresh="$T/clockload-$RANDOM"
    bash -c 'source "$1/scripts/lib/wv-db.sh" 2>/dev/null; source "$1/scripts/cmd/wv-cmd-data.sh"
        dump_state_sql "$2" "$3"' _ "$ROOT" "$1" "$CR/.weave/state.sql" 2>/dev/null
    (cd "$CR" && WV_PROJECT_DIR="$CR" WV_HOT_ZONE="$fresh/$H" "$WV" load >/dev/null 2>&1)
    sqlite3 "$fresh/$H/brain.db" "SELECT text FROM nodes WHERE id = '$ID';"
}
check "without a cutover marker the copies load to different text" \
    "stale legacy text|original text" "$(loaded_text "$A/brain.db")|$(loaded_text "$B/brain.db")"
printf '{"lineage_seq": 1}\n' > "$CR/.weave/causal-cutover"
check "control: with a causal-cutover marker both load the same text" \
    "original text|original text" "$(loaded_text "$A/brain.db")|$(loaded_text "$B/brain.db")"
sqlite3 "$B/brain.db" "UPDATE nodes SET updated_at = 100;"
out=$("$WV" hotzone diff "$A/brain.db" "$B/brain.db"); rc=$?
check "equal clocks compare identical" "0" "$rc"

echo "== the diff runs where placement is refused (wv-757de1)"
# A repository whose database sits in both names of the /tmp zone: wv refuses
# to run, and the advised diff must still run there, with no override.
uid=$(id -u)
C="$T/conflict"; mkdir -p "$C/repo"
git -C "$C/repo" init -q
CH=$(echo "$C/repo" | md5sum | cut -c1-8)
Z="$C/z"; CN="$Z/tmp/weave-hotzone-$uid/$CH"; CL="$Z/tmp/weave-codex-$uid/$CH"
(umask 077 && mkdir -p "$Z/tmp/weave-hotzone-$uid" "$Z/tmp/weave-codex-$uid" "$CN" "$CL")
sqlite3 "$A/brain.db" ".backup '$CN/brain.db'"
sqlite3 "$A/brain.db" ".backup '$CL/brain.db'"
in_conflict() { (cd "$C/repo" && env -u WV_HOT_ZONE -u WV_DB WV_PROJECT_DIR="$C/repo" WV_CONFIG_DIR="$C/cfg" \
    WV_TEST_MODE=1 WV_TEST_HOT_ZONE_ROOT="$Z" "$WV" "$@" 2>&1); }
# A WAL database's reader may add the -wal/-shm SQLite needs beside it; the
# diff must create no directory or database and change no database's bytes.
zone_state() { find "$Z" ! -name '*-wal' ! -name '*-shm' | sort; sha256sum "$CN/brain.db" "$CL/brain.db"; }
before=$(zone_state)
out=$(in_conflict status); rc=$?
check "the repository's placement is refused (whole zone)" "1" "$rc"
has "with the conflict message" "both hold databases" "$out"
out=$(in_conflict hotzone diff "$CL/brain.db" "$CN/brain.db"); rc=$?
check "yet the advised diff runs there, with no override" "0" "$rc"
has "and compares the copies" "identical: nodes edges node_files tombstones agree" "$out"
check "touching no hot zone and writing neither copy" "$before" \
    "$(zone_state)"
# One repository in two zones (per-repository refusal), the same way.
rm -rf "$Z/tmp/weave-hotzone-$uid"
(umask 077 && mkdir -p "$Z/dev/shm/weave/$CH")
sqlite3 "$A/brain.db" ".backup '$Z/dev/shm/weave/$CH/brain.db'"
out=$(in_conflict status); rc=$?
check "the repository's placement is refused (one repo, two zones)" "1" "$rc"
has "with the per-repository message" "has one in more than one hot zone" "$out"
out=$(in_conflict hotzone diff "$CL/brain.db" "$Z/dev/shm/weave/$CH/brain.db"); rc=$?
check "and the advised diff runs there too" "0" "$rc"

echo "== sync-only recovery loses an edit (the old advice)"
fixture synconly; edit_both
WV_HOT_ZONE="$A" "$WV" sync >/dev/null 2>&1; rc_a=$?
WV_HOT_ZONE="$B" "$WV" sync >/dev/null 2>&1; rc_b=$?
check "both syncs succeed" "0 0" "$rc_a $rc_b"
rm -rf "$A"
check "yet after removing one copy only one edit survives" "legacy text|None" "$(node_state)"

echo "== the advised procedure keeps both edits"
fixture advised; edit_both
mkdir -p "$T/advised/backup"
sqlite3 "$A/brain.db" ".backup '$T/advised/backup/a.db'"
sqlite3 "$B/brain.db" ".backup '$T/advised/backup/b.db'"
check "backups are complete databases" "ok ok" \
    "$(sqlite3 "$T/advised/backup/a.db" 'PRAGMA quick_check') $(sqlite3 "$T/advised/backup/b.db" 'PRAGMA quick_check')"
out=$("$WV" hotzone diff "$B/brain.db" "$A/brain.db")
has "diff, keeping B, shows what B lacks" "node $ID (text metadata lineage " "$out"
WV_HOT_ZONE="$B" "$WV" update "$ID" --metadata='{"neutral_field":"kept"}' >/dev/null 2>&1
out=$("$WV" hotzone diff "$B/brain.db" "$A/brain.db")
has "after carrying the metadata, only the text B chose differs (and lineage)" "node $ID (text lineage " "$out"
WV_HOT_ZONE="$B" "$WV" sync >/dev/null 2>&1
rm -rf "$A"
check "after removing the other copy, both edits survive a fresh load" "legacy text|kept" "$(node_state)"

echo "== the refusals require a backup and a diff (bash)"
R="$T/msg"; uid=$(id -u)
N="$R/tmp/weave-hotzone-$uid"; L="$R/tmp/weave-codex-$uid"
(umask 077 && mkdir -p "$N/aaaa1111" "$L/aaaa1111" "$L/bbbb2222")
for f in "$N/aaaa1111" "$L/aaaa1111" "$L/bbbb2222"; do printf 'x' > "$f/brain.db"; done
out=$(WV_TEST_MODE=1 WV_TEST_HOT_ZONE_ROOT="$R" bash -c 'source "$1"; resolve_hot_zone "$2"' _ "$RESOLVER" "$T/diff/repo" 2>&1 >/dev/null)
has "whole-zone refusal requires a .backup" "\".backup '<file>'\" (never cp)" "$out"
has "and wv hotzone diff" "wv hotzone diff <legacy copy> <neutral copy>" "$out"
has "and marks the repository in both zones" "$N/aaaa1111  (repository unknown)  [IN BOTH ZONES" "$out"
lacks "but not one in a single zone" "bbbb2222  (repository unknown)  [IN BOTH" "$out"
lacks "and no longer says sync then remove" "Only when every one is synced" "$out"

R="$T/msg2"; rr="$T/msg2-repo"; rh=$(echo "$rr" | md5sum | cut -c1-8)
(umask 077 && mkdir -p "$R/tmp/weave-codex-$uid/$rh" "$R/dev/shm/weave/$rh")
printf 'x' > "$R/tmp/weave-codex-$uid/$rh/brain.db"; printf 'x' > "$R/dev/shm/weave/$rh/brain.db"
out=$(WV_TEST_MODE=1 WV_TEST_HOT_ZONE_ROOT="$R" bash -c 'source "$1"; resolve_hot_zone "$2"' _ "$RESOLVER" "$rr" 2>&1 >/dev/null)
has "per-repository refusal names both copies" "has one in more than one hot zone" "$out"
has "and requires a .backup" "\".backup '<file>'\" (never cp)" "$out"
has "and wv hotzone diff" "wv hotzone diff <copy you keep> <other copy>" "$out"
lacks "and no longer says keep the one you have been using" "Keep the one you have been using" "$out"

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ] && echo "All tests passed" || { echo "FAILED"; exit 1; }
