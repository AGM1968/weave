#!/usr/bin/env bash
# test-prune-bulk-tombstones.sh — a large prune keeps its tombstones (wv-aec7de).
#
# On 2026-11-09 a session-end prune selected 615 done nodes. Its DELETEs ran, but
# its tombstone SQL (853,597 bytes) went to sqlite3 as one command-line argument,
# over Linux's 131,072-byte cap: execve failed, the return code was ignored, and
# every fresh load then resurrected the pruned nodes from their creation deltas
# (wv-5e5f18). Pinned here:
#   - a prune of 700 aged done nodes with edges writes one tombstone per node and
#     per incident edge, in the same transaction as the DELETEs;
#   - a fresh reload from the committed .weave/ does not resurrect any of them and
#     is acknowledged;
#   - a prune whose transaction is refused deletes nothing and exits nonzero, and
#     the archive rows it wrote neither block the next prune nor repeat.
set -u
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
export WV_CALL_SOURCE=test
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$REPO_ROOT/scripts/wv"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
export WV_HOT_ZONE="$TEST_DIR/hot"
WV_DB="$WV_HOT_ZONE/brain.db"   # derived by wv; not exported (see test-tombstone-reconcile.sh)
export WEAVE_DIR="$TEST_DIR/.weave"
export WV_PROJECT_DIR="$TEST_DIR"
export WV_AGENT_ID="prune-bulk-test-agent"
export WV_REQUIRE_LEARNING=0 WV_AUTO_CHECKPOINT=0 WV_SYNC_INTERVAL=0 WV_DISABLE_AUTOPRUNE=1
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
mkdir -p "$WV_HOT_ZONE" "$WEAVE_DIR"
cd "$TEST_DIR" || exit 1
git init -q && git config user.email t@t && git config user.name t && git config commit.gpgsign false

pass=0; run=0
ok()  { echo "  ✓ $1"; pass=$((pass + 1)); run=$((run + 1)); }
bad() { echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; run=$((run + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }
q() { sqlite3 "$WV_DB" "$1"; }

"$WV" init >/dev/null 2>&1
N=700
# 700 done nodes, closed three days ago, each linked to the next: 699 edges, plus
# one keeper (recently touched, not prunable) every pruned node relates to, so
# each pruned node has incident edges and the tombstone SQL is large.
{
    echo "BEGIN;"
    echo "INSERT INTO nodes(id,text,status,metadata,created_at,updated_at) VALUES('wv-keep00','keeper','todo','{}',datetime('now'),datetime('now'));"
    for i in $(seq 1 $N); do
        printf "INSERT INTO nodes(id,text,status,metadata,created_at,updated_at) VALUES('wv-p%05d','pruned node %d with a body long enough to look like real node text','done','{\"learning\":\"x\"}',datetime('now','-4 days'),datetime('now','-3 days'));\n" "$i" "$i"
        printf "INSERT INTO edges(source,target,type) VALUES('wv-p%05d','wv-keep00','relates_to');\n" "$i"
        [ "$i" -lt $N ] && printf "INSERT INTO edges(source,target,type) VALUES('wv-p%05d','wv-p%05d','relates_to');\n" "$i" $((i + 1))
    done
    echo "COMMIT;"
} | sqlite3 "$WV_DB" || { echo "could not plant the fixture"; exit 1; }
"$WV" sync >/dev/null 2>&1
# One more pruned node closed with an explicit completion scope, its create and its
# close in separate deltas, as wv-237d25's were: after the prune its node_files are
# gone, so a replay that reaches its close fails the close-policy trigger unless
# tombstones hold during v1 replay (wv-c14ccf).
q "INSERT INTO nodes(id,text,status,metadata,created_at,updated_at) VALUES('wv-pscope','scoped close','active','{}',datetime('now','-4 days'),datetime('now','-4 days'));
   INSERT INTO node_files(node_id,path) VALUES('wv-pscope','src/a.py'),('wv-pscope','src/b.py');"
"$WV" sync >/dev/null 2>&1
q "UPDATE nodes SET status='done', updated_at=datetime('now','-3 days'),
     metadata='{\"learning\":\"x\",\"completion_scope\":{\"files\":[\"src/a.py\",\"src/b.py\"],\"attempt_id\":\"scope-1\"}}'
   WHERE id='wv-pscope';"
"$WV" sync >/dev/null 2>&1
check "(fixture) the scoped node closed live, its scope attributed" "done" "$(q "SELECT status FROM nodes WHERE id='wv-pscope';")"
check "(fixture) creation deltas were emitted" "yes" "$([ -n "$(find "$WEAVE_DIR/deltas" -type f 2>/dev/null | head -1)" ] && echo yes || echo no)"
git add -A && git commit -q -m "fixture" >/dev/null 2>&1
edges_before=$(q "SELECT count(*) FROM edges WHERE source LIKE 'wv-p%' OR target LIKE 'wv-p%';")
tomb_before=$(q "SELECT count(*) FROM tombstones;")

echo "a refused prune deletes nothing"
q "CREATE TRIGGER planted_refuse BEFORE INSERT ON tombstones BEGIN SELECT RAISE(ABORT, 'planted refusal'); END;"
out=$("$WV" prune --age=48h 2>&1); rc=$?
check "prune exits nonzero when its transaction is refused" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
check "...and every node is still there" "$((N + 1))" "$(q "SELECT count(*) FROM nodes WHERE id LIKE 'wv-p%';")"
check "...with every edge" "$edges_before" "$(q "SELECT count(*) FROM edges WHERE source LIKE 'wv-p%' OR target LIKE 'wv-p%';")"
check "...and no tombstone" "$tomb_before" "$(q "SELECT count(*) FROM tombstones;")"
grep -q "nothing pruned" <<< "$out" && ok "...saying nothing was pruned" || bad "...saying nothing was pruned" "$out"
q "DROP TRIGGER planted_refuse;"

echo "a prune of $((N + 1)) nodes"
# Pruned by an agent whose id sorts BEFORE the rows' actor: a tombstone stamped
# with the deleter's actor beside the row's seq lost the (seq, actor) comparison
# and the row outranked its own tombstone on reload (wv-f01b33).
out=$(WV_AGENT_ID=a-pruner "$WV" prune --age=48h 2>&1); rc=$?
check "prune succeeds" "0" "$rc"
check "every pruned node is gone" "0" "$(q "SELECT count(*) FROM nodes WHERE id LIKE 'wv-p%';")"
check "...and the keeper stays" "1" "$(q "SELECT count(*) FROM nodes WHERE id='wv-keep00';")"
check "one tombstone per pruned node" "$((N + 1))" "$(q "SELECT count(*) FROM tombstones WHERE kind='node' AND id LIKE 'wv-p%';")"
check "...and per incident edge" "$edges_before" "$(q "SELECT count(*) FROM tombstones WHERE kind='edge' AND (id LIKE 'wv-p%' OR id LIKE '%:wv-p%');")"
check "each tombstone carries its row's own actor, not the pruner's" "0" "$(q "SELECT count(*) FROM tombstones WHERE id LIKE '%wv-p%' AND lineage_actor = 'a-pruner';")"
arch="$WEAVE_DIR/archive/$(date +%Y-%m-%d).jsonl"
check "today's archive holds each pruned node once, refused run included" "$((N + 1)) $((N + 1))" \
    "$(jq -r 'select(.id | startswith("wv-p")) | .id' "$arch" | wc -l | tr -d ' ') $(jq -r 'select(.id | startswith("wv-p")) | .id' "$arch" | sort -u | wc -l | tr -d ' ')"
"$WV" sync >/dev/null 2>&1
git add -A && git commit -q -m "after prune" >/dev/null 2>&1

echo "a fresh reload"
rm -rf "$WV_HOT_ZONE"; mkdir -p "$WV_HOT_ZONE"
out=$("$WV" load 2>&1)
check "resurrects no pruned node" "0" "$(q "SELECT count(*) FROM nodes WHERE id LIKE 'wv-p%';")"
check "...keeps the keeper" "1" "$(q "SELECT count(*) FROM nodes WHERE id='wv-keep00';")"
check "...and is acknowledged" "0" "$(grep -c 'not acknowledged' <<< "$out")"

echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
