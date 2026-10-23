#!/usr/bin/env bash
# test-removal-redump.sh — wv delete and wv prune re-dump state.sql only when
# the dump is this repository's graph and holds everything the removal kept
# (wv-5d5ef2).
#
# Both commands re-dump state.sql straight after removing nodes so wv load
# cannot resurrect them (wv-0d5e07). They wrote the dump with neither of the
# guards sync applies: the MCP test teardown deleted a node from a 5-node
# throwaway DB (WV_DB override) while its working directory was inside the
# repository, and a 1698-node state.sql was replaced with the 5-node dump.
#
# Exit codes:
#   0 - All tests passed
#   1 - One or more tests failed

set -eu
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
export WV_CALL_SOURCE=test
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WV="$(cd "$SCRIPT_DIR/.." && pwd)/scripts/wv"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
export WV_AGENT_ID="removal-redump-test-agent"
export WV_REQUIRE_LEARNING=0
export WV_AUTO_CHECKPOINT=0
unset WV_DB

pass=0; run=0
ok()  { echo "  ✓ $1"; pass=$((pass + 1)); run=$((run + 1)); }
bad() { echo "  ✗ $1"; run=$((run + 1)); }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
nodes_in() { grep -c '^INSERT INTO nodes' "$1" 2>/dev/null || true; }

# The repository: its own hot zone, four nodes, a committed-style state.sql.
REPO="$TEST_DIR/repo"
mkdir -p "$REPO/hot"
cd "$REPO"
git init -q
export WV_HOT_ZONE="$REPO/hot"
# Not exported: wv derives .weave/ from the working directory, as it does for
# the MCP suite's calls; an exported WEAVE_DIR would make any override an
# explicit pair (wv-7ab3cd).
WEAVE_DIR="$REPO/.weave"
export WV_PROJECT_DIR="$REPO"
"$WV" init >/dev/null 2>&1
R1=$("$WV" add "repo node one" --standalone | tail -1)
R2=$("$WV" add "repo node two" --standalone | tail -1)
R3=$("$WV" add "repo node three" --standalone | tail -1)
"$WV" add "repo node four" --standalone >/dev/null
"$WV" sync >/dev/null 2>&1
check "setup: the repository's state.sql holds its 4 nodes" test "$(nodes_in "$WEAVE_DIR/state.sql")" = 4

# A throwaway graph outside the repository, reached by WV_DB override, set up
# the way the MCP suite does: initialised in its own directory (no owner is
# recorded), then used only from inside the repository, so wv honours the
# override rather than discarding it as a leak from another repository.
X="$TEST_DIR/throwaway"
mkdir -p "$X"
(cd "$X" && env -u WEAVE_DIR -u WV_PROJECT_DIR WV_HOT_ZONE="$X" WV_DB="$X/brain.db" "$WV" init >/dev/null 2>&1)
x_add() { WV_HOT_ZONE="$X" WV_DB="$X/brain.db" "$WV" add "$1" --standalone | tail -1; }
X1=$(x_add "throwaway delete target")
X2=$(x_add "throwaway prune target")
sqlite3 "$X/brain.db" "UPDATE nodes SET status='done', updated_at=datetime('now','-30 days') WHERE id='$X2';"
cp "$WEAVE_DIR/state.sql" "$TEST_DIR/state.before"

echo "=== a WV_DB override never reaches the repository's .weave/ ==="
WV_HOT_ZONE="$X" WV_DB="$X/brain.db" "$WV" delete "$X1" --force >/dev/null 2>&1 || true
check "delete from the override removed the throwaway node" \
    test "$(sqlite3 "$X/brain.db" "SELECT COUNT(*) FROM nodes WHERE id='$X1';")" = 0
check "delete from the override left state.sql byte-identical" cmp -s "$TEST_DIR/state.before" "$WEAVE_DIR/state.sql"
WV_HOT_ZONE="$X" WV_DB="$X/brain.db" "$WV" prune --age=1d >/dev/null 2>&1 || true
check "prune from the override removed the old done node" \
    test "$(sqlite3 "$X/brain.db" "SELECT COUNT(*) FROM nodes WHERE id='$X2';")" = 0
check "prune from the override left state.sql byte-identical" cmp -s "$TEST_DIR/state.before" "$WEAVE_DIR/state.sql"
check "no throwaway node reached the repository's archive" \
    sh -c "! grep -rqs -e '$X1' -e '$X2' '$WEAVE_DIR/archive'"

echo "=== an override paired with an explicit WEAVE_DIR is its own graph ==="
# test-data.sh runs this way: a test DB with its own .weave/. The archive and
# the re-dump belong there, and the repository's state.sql is not touched.
Y="$TEST_DIR/paired"
mkdir -p "$Y/.weave"
y_env() { env WV_HOT_ZONE="$Y" WV_DB="$Y/brain.db" WEAVE_DIR="$Y/.weave" "$@"; }
y_env "$WV" init >/dev/null 2>&1
Y1=$(y_env "$WV" add "paired delete target" --standalone | tail -1)
y_env "$WV" add "paired survivor" --standalone >/dev/null
y_env "$WV" delete "$Y1" --force >/dev/null 2>&1 || true
check "the paired delete archived the node in its own .weave/" grep -rqs -e "$Y1" -- "$Y/.weave/archive"
check "the paired delete re-dumped its own state.sql" test "$(nodes_in "$Y/.weave/state.sql")" = 1
check "the paired delete left the repository's state.sql byte-identical" cmp -s "$TEST_DIR/state.before" "$WEAVE_DIR/state.sql"

echo "=== a normal delete re-dumps without the node ==="
"$WV" delete "$R1" --force >/dev/null 2>&1
check "state.sql drops the deleted node" sh -c "! grep -q \"^INSERT INTO nodes VALUES('\$1'\" \"\$2\"" _ "$R1" "$WEAVE_DIR/state.sql"
check "state.sql holds the other 3 nodes" test "$(nodes_in "$WEAVE_DIR/state.sql")" = 3
check "state.sql carries the deletion tombstone" grep -q -e "^INSERT INTO tombstones.*$R1" -- "$WEAVE_DIR/state.sql"

echo "=== a DB missing more than the removal took does not overwrite ==="
# The live DB loses R2 behind wv's back (a partial or stale DB); deleting R3
# must not publish a dump that also drops R2.
sqlite3 "$WV_HOT_ZONE/brain.db" "DELETE FROM nodes WHERE id='$R2';"
cp "$WEAVE_DIR/state.sql" "$TEST_DIR/state.before-partial"
err=$("$WV" delete "$R3" --force 2>&1 >/dev/null || true)
check "the re-dump is refused and state.sql kept" cmp -s "$TEST_DIR/state.before-partial" "$WEAVE_DIR/state.sql"
check "the refusal says why" sh -c "printf '%s' \"\$1\" | grep -q 'state.sql kept'" _ "$err"

echo "=== a rejected delete keeps the whole graph operation intact ==="
# Fresh graphs keep one failed attempt from satisfying another's preconditions.
# Fail each stage: stopping only after the node DELETE loses earlier edge/file
# deletions; continuing after an earlier error can delete the node anyway.
for table in edges node_files nodes tombstones; do
    D="$TEST_DIR/refused-$table"
    mkdir -p "$D"
    d_env() { env WV_PROJECT_DIR="$D" WEAVE_DIR="$D/.weave" WV_HOT_ZONE="$D/hot" WV_DB="$D/hot/brain.db" "$@"; }
    d_env "$WV" init >/dev/null 2>&1
    target=$(d_env "$WV" add "delete failure target" --standalone 2>/dev/null | tail -1)
    peer=$(d_env "$WV" add "delete failure survivor" --standalone 2>/dev/null | tail -1)
    d_env "$WV" link "$target" "$peer" --type=relates_to >/dev/null 2>&1
    d_env "$WV" touch "$target" --files=src/target.sh >/dev/null 2>&1
    d_env "$WV" sync >/dev/null 2>&1
    cp "$D/.weave/state.sql" "$D/before.sql"
    operation=DELETE
    [ "$table" != tombstones ] || operation=INSERT
    sqlite3 "$D/hot/brain.db" "CREATE TRIGGER test_delete_refused BEFORE $operation ON $table
        BEGIN SELECT RAISE(ABORT, 'simulated $table delete failure'); END;"
    rc=0
    out=$(d_env "$WV" delete "$target" --no-gh 2>&1) || rc=$?
    check "$table refusal returns failure" test "$rc" != 0
    check "$table refusal prints no deletion success" sh -c '! printf "%s" "$1" | grep -q "Deleted:"' _ "$out"
    rows=$(sqlite3 "$D/hot/brain.db" "SELECT
        (SELECT count(*) FROM nodes) || '|' ||
        (SELECT count(*) FROM edges) || '|' ||
        (SELECT count(*) FROM node_files) || '|' ||
        (SELECT count(*) FROM tombstones);")
    check "$table refusal preserves nodes, edges, files and no tombstones" test "$rows" = '2|1|1|0'
    [ "$rows" = '2|1|1|0' ] || echo "    observed nodes|edges|files|tombstones: $rows"
    check "$table refusal leaves portable state unchanged" cmp -s "$D/before.sql" "$D/.weave/state.sql"
    sqlite3 "$D/hot/brain.db" "DROP TRIGGER test_delete_refused;"
    rc=0
    d_env "$WV" delete "$target" --no-gh >/dev/null 2>&1 || rc=$?
    check "$table retry succeeds after removing the fault" test "$rc" = 0
    rows=$(sqlite3 "$D/hot/brain.db" "SELECT
        (SELECT count(*) FROM nodes) || '|' ||
        (SELECT count(*) FROM edges) || '|' ||
        (SELECT count(*) FROM node_files) || '|' ||
        (SELECT count(*) FROM tombstones);")
    check "$table retry removes target and links, keeps peer and writes tombstones" test "$rows" = '1|0|0|2'
done

if [ "$(id -u)" != 0 ]; then
    echo "=== portable-state refusal is not a successful deletion ==="
    target=$(d_env "$WV" add 'portable deletion target' --standalone 2>/dev/null | tail -1)
    d_env "$WV" sync >/dev/null 2>&1
    cp "$D/.weave/state.sql" "$D/before-portable.sql"
    chmod 500 "$D/.weave"
    rc=0
    out=$(d_env "$WV" delete "$target" --no-gh 2>&1) || rc=$?
    chmod 700 "$D/.weave"
    check "portable-state refusal returns failure" test "$rc" != 0
    check "portable-state refusal prints no deletion success" sh -c '! printf "%s" "$1" | grep -q "Deleted:"' _ "$out"
    check "portable-state refusal preserves previous snapshot" cmp -s "$D/before-portable.sql" "$D/.weave/state.sql"
    check "portable-state refusal retains the local deletion tombstone" test "$(sqlite3 "$D/hot/brain.db" "SELECT count(*) FROM tombstones WHERE kind='node' AND id='$target';")" = 1
    check "portable-state refusal names the recovery command" sh -c 'printf "%s" "$1" | grep -q "wv sync"' _ "$out"
    d_env "$WV" sync >/dev/null 2>&1
    check "sync recovers durable deletion after permission repair" sh -c '! grep -q "^INSERT INTO nodes VALUES('\''$1'\''" "$2" && grep -q "^INSERT INTO tombstones.*$1" "$2"' _ "$target" "$D/.weave/state.sql"
fi

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
