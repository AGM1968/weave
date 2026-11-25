#!/usr/bin/env bash
# "done" is an argument to the wv helper below, never the loop keyword.
# shellcheck disable=SC1010
# test-unblock-recompute.sh — every path that removes a blocks edge or a blocker
# node recomputes the stored status of the nodes it blocked (wv-81338c).
#
# On 2026-11-18 wv unlink of wv-694f1b's last open blocker left it 'blocked'
# with no blocker and out of wv ready. wv done already ran the recompute; wv
# unlink, wv delete, wv prune and wv clean-ghosts did not. Each now calls
# _recompute_blocked_targets on the targets it captured before the DELETE:
#   - unlink of the last open blocker moves the target to todo;
#   - unlink while another open blocker remains keeps it blocked;
#   - delete of a node's only open blocker moves it to todo;
#   - prune of a done blocker clears an already stale blocked status;
#   - clean-ghosts of a ghost blocker's edge moves the target to todo;
#   - a node set blocked by hand, with no blocks edge, is never touched.
export WV_CALL_SOURCE=test
set -uo pipefail
export WV_TEST_SUITE=1
# Fixture rows are edited with sqlite3, which the run cache cannot see.
export WV_RUN_CACHE=0
export WV_REQUIRE_LEARNING=0 WV_REQUIRE_QUALITY=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WV="$ROOT/scripts/wv"
run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }
TMP=$(mktemp -d /tmp/wv-unblock-recompute-XXXXXX)
trap 'rm -rf "$TMP"' EXIT

R="$TMP/repo"; mkdir -p "$R" "$TMP/cfg"
git -C "$R" init -q . && git -C "$R" config user.email t@t && git -C "$R" config user.name t
w() { (cd "$R" && WEAVE_DIR="$R/.weave" WV_HOT_ZONE="$TMP/hot" WV_CONFIG_DIR="$TMP/cfg" "$WV" "$@") </dev/null; }
DB="$TMP/hot/brain.db"
w init >/dev/null 2>&1
add() { w add "$@" --standalone 2>/dev/null | grep -oE 'wv-[a-f0-9]{6}' | sed -n 1p; }
status_of() { sqlite3 "$DB" "SELECT status FROM nodes WHERE id='$1';"; }
block() { w block "$1" --by="$2" >/dev/null 2>&1; }

echo "=== wv unlink ==="
a=$(add "unlink: a blocker"); b=$(add "unlink: a second blocker"); t=$(add "unlink: the blocked node")
block "$t" "$a"; block "$t" "$b"
check "(fixture) two open blockers leave the target blocked" "$(status_of "$t")" "blocked"
w unlink "$a" "$t" --type=blocks >/dev/null 2>&1
check "unlink with one open blocker left keeps the target blocked" "$(status_of "$t")" "blocked"
w unlink "$b" "$t" --type=blocks >/dev/null 2>&1
check "unlink of the last open blocker moves the target to todo" "$(status_of "$t")" "todo"
check "...and the target is in wv ready" \
    "$(w ready --json 2>/dev/null | jq -r --arg t "$t" '[.[] | select(.id == $t)] | length')" "1"

d=$(add "unlink: a done blocker"); o=$(add "unlink: an open blocker"); t2=$(add "unlink: blocked by both")
block "$t2" "$d"; block "$t2" "$o"
sqlite3 "$DB" "UPDATE nodes SET status='done' WHERE id='$d';"
w unlink "$o" "$t2" --type=blocks >/dev/null 2>&1
check "unlink leaving only a done blocker moves the target to todo" "$(status_of "$t2")" "todo"

echo "=== wv delete ==="
x=$(add "delete: the blocker"); t3=$(add "delete: the blocked node")
block "$t3" "$x"
check "(fixture) the target is blocked" "$(status_of "$t3")" "blocked"
w delete "$x" --force >/dev/null 2>&1
check "(fixture) the blocker is gone" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM nodes WHERE id='$x';")" "0"
check "delete of the only open blocker moves the target to todo" "$(status_of "$t3")" "todo"

y=$(add "delete: one blocker"); z=$(add "delete: the other blocker"); t4=$(add "delete: blocked by two")
block "$t4" "$y"; block "$t4" "$z"
w delete "$y" --force >/dev/null 2>&1
check "delete of one of two open blockers keeps the target blocked" "$(status_of "$t4")" "blocked"

echo "=== wv prune ==="
p=$(add "prune: a done blocker"); t5=$(add "prune: stale blocked node")
block "$t5" "$p"
# A done blocker that never ran the cascade: the stale state prune used to keep.
sqlite3 "$DB" "UPDATE nodes SET status='done', metadata=json_set(COALESCE(metadata,'{}'),'\$.learning','x'),
    updated_at=datetime('now','-3 days') WHERE id='$p';"
check "(fixture) the target is stale blocked" "$(status_of "$t5")" "blocked"
w prune --age=48h >/dev/null 2>&1
check "(fixture) the done blocker is pruned" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM nodes WHERE id='$p';")" "0"
check "prune of a done blocker moves the stale target to todo" "$(status_of "$t5")" "todo"

echo "=== wv clean-ghosts ==="
t6=$(add "ghosts: blocked by a ghost")
sqlite3 "$DB" "INSERT INTO edges(source,target,type) VALUES('wv-0ghost','$t6','blocks');
    UPDATE nodes SET status='blocked' WHERE id='$t6';"
w clean-ghosts >/dev/null 2>&1
check "(fixture) the ghost edge is gone" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM edges WHERE source='wv-0ghost';")" "0"
check "clean-ghosts of a ghost blocker moves the target to todo" "$(status_of "$t6")" "todo"

echo "=== a hand-set status is left alone ==="
h=$(add "manual: blocked by hand, no edge"); k=$(add "manual: unrelated blocker"); t7=$(add "manual: unrelated target")
w update "$h" --status=blocked >/dev/null 2>&1
block "$t7" "$k"
w unlink "$k" "$t7" --type=blocks >/dev/null 2>&1
check "an unrelated unlink does not touch a hand-set blocked node" "$(status_of "$h")" "blocked"

echo ""
echo "unblock recompute: $pass/$run passed"
[ "$pass" -eq "$run" ]
