#!/usr/bin/env bash
# test-prune-policy.sh — the prune policy (owner ruling 2026-11-10, wv-3937eb).
#
# Pins: prune refuses from a hook; the default age is 30 days; a prune keeps
# findings and memories, epics/plans/decisions, unresolved pitfalls, nodes a live
# node references (inbound edge, or id in text or metadata) and nodes with an
# open or unverifiable GitHub issue; --dry-run names what each rule kept; the
# kept nodes survive a real prune and the plain aged node does not.
set -u
export WV_TEST_SUITE=1
export WV_CALL_SOURCE=test
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$REPO_ROOT/scripts/wv"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
export WV_HOT_ZONE="$TEST_DIR/hot"
WV_DB="$WV_HOT_ZONE/brain.db"
export WEAVE_DIR="$TEST_DIR/.weave"
export WV_PROJECT_DIR="$TEST_DIR"
export WV_AGENT_ID="prune-policy-test-agent"
export WV_REQUIRE_LEARNING=0 WV_AUTO_CHECKPOINT=0 WV_SYNC_INTERVAL=0 WV_DISABLE_AUTOPRUNE=1
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
mkdir -p "$WV_HOT_ZONE" "$WEAVE_DIR" "$TEST_DIR/bin"
cd "$TEST_DIR" || exit 1
git init -q && git config user.email t@t && git config user.name t && git config commit.gpgsign false

# A fake gh: issue 7 is open, issue 8 is closed, anything else is unanswerable.
cat > "$TEST_DIR/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
    "repo view") echo "t/t" ;;
    "issue view") case "$3" in 7) echo OPEN ;; 8) echo CLOSED ;; *) exit 1 ;; esac ;;
    *) exit 1 ;;
esac
GH
chmod +x "$TEST_DIR/bin/gh"
export PATH="$TEST_DIR/bin:$PATH"

pass=0; run=0
ok()  { echo "  ✓ $1"; pass=$((pass + 1)); run=$((run + 1)); }
bad() { echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; run=$((run + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }
has()   { if grep -qF -- "$2" <<< "$3"; then ok "$1"; else bad "$1" "no [$2] in: $3"; fi; }
q() { sqlite3 "$WV_DB" "$1"; }
alive() { q "SELECT count(*) FROM nodes WHERE id='$1';"; }

"$WV" init >/dev/null 2>&1
OLD="datetime('now','-40 days')"
NEW="datetime('now','-10 days')"
q "BEGIN;
INSERT INTO nodes(id,text,status,metadata,created_at,updated_at) VALUES
 ('wv-live00','task(live): still open and cites wv-cited0 in its text','todo','{}',$OLD,$OLD),
 ('wv-plain0','task(plain): aged done, nothing keeps it','done','{}',$OLD,$OLD),
 ('wv-young0','task(young): done ten days ago','done','{}',$NEW,$NEW),
 ('wv-find00','task text without prefix','done','{\"node_kind\":\"finding\"}',$OLD,$OLD),
 ('wv-fpref0','finding(x): kept by its text prefix','done','{}',$OLD,$OLD),
 ('wv-memo00','memory text','done','{\"node_kind\":\"memory\"}',$OLD,$OLD),
 ('wv-epic00','epic(x): kept','done','{}',$OLD,$OLD),
 ('wv-plan00','plan text','done','{\"node_kind\":\"plan\"}',$OLD,$OLD),
 ('wv-decis0','decision(x): kept','done','{}',$OLD,$OLD),
 ('wv-pitf00','task(pitfall): unresolved pitfall','done','{\"pitfall\":\"never do x\"}',$OLD,$OLD),
 ('wv-edged0','task(edged): a live node points at it','done','{}',$OLD,$OLD),
 ('wv-cited0','task(cited): a live node names it in text','done','{}',$OLD,$OLD),
 ('wv-meta00','task(meta): a live node names it in metadata','done','{}',$OLD,$OLD),
 ('wv-chain0','task(chain): referenced only by another candidate','done','{}',$OLD,$OLD),
 ('wv-chain1','task(chain): the other candidate','done','{}',$OLD,$OLD),
 ('wv-ghopen','task(gh): issue 7 is open','done','{\"gh_issue\":7}',$OLD,$OLD),
 ('wv-ghshut','task(gh): issue 8 is closed','done','{\"gh_issue\":8}',$OLD,$OLD),
 ('wv-ghunkn','task(gh): issue 9 cannot be checked','done','{\"gh_issue\":9}',$OLD,$OLD);
UPDATE nodes SET metadata='{\"learning_overlap_noted\":\"wv-meta00\"}' WHERE id='wv-live00';
INSERT INTO edges(source,target,type) VALUES ('wv-live00','wv-edged0','blocks'),('wv-chain1','wv-chain0','relates_to');
COMMIT;" || { echo "could not plant the fixture"; exit 1; }
"$WV" sync >/dev/null 2>&1
total=$(q "SELECT count(*) FROM nodes;")

echo "a hook cannot prune"
out=$(WV_CALL_SOURCE=hook "$WV" prune --age=1h 2>&1); rc=$?
check "prune from a hook exits nonzero" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
has "...naming the rule" "does not run from a hook" "$out"
check "...and removed nothing" "$total" "$(q "SELECT count(*) FROM nodes;")"

echo "dry run with the default age"
out=$("$WV" prune --dry-run 2>&1); rc=$?
check "dry run exits 0" "0" "$rc"
has "the plain aged node is a candidate" "wv-plain0" "$out"
has "the closed-issue node is a candidate" "wv-ghshut" "$out"
has "the chain pair, referenced only by each other, are candidates" "wv-chain0" "$out"
check "the ten-day-old node is not (default age is 30 days)" "0" "$(grep -c wv-young0 <<< "$out")"
has "kept: finding or memory" "finding or memory: 3" "$out"
has "kept: epic, plan or decision" "epic, plan or decision: 3" "$out"
has "kept: unresolved pitfall" "unresolved pitfall: 1" "$out"
has "kept: referenced by a live node" "referenced by a live node: 3" "$out"
has "kept: open or unverified issue" "open or unverified GitHub issue: 2" "$out"
check "...and the dry run removed nothing" "$total" "$(q "SELECT count(*) FROM nodes;")"

echo "the prune"
out=$("$WV" prune 2>&1); rc=$?
check "prune exits 0" "0" "$rc"
has "it reports the count" "Pruned 4 nodes" "$out"
check "the plain aged node is gone" "0" "$(alive wv-plain0)"
check "the closed-issue node is gone" "0" "$(alive wv-ghshut)"
check "the chain pair are gone" "0" "$(q "SELECT count(*) FROM nodes WHERE id IN ('wv-chain0','wv-chain1');")"
check "each has a tombstone" "4" "$(q "SELECT count(*) FROM tombstones WHERE kind='node' AND id IN ('wv-plain0','wv-ghshut','wv-chain0','wv-chain1');")"
for id in wv-young0 wv-find00 wv-fpref0 wv-memo00 wv-epic00 wv-plan00 wv-decis0 wv-pitf00 wv-edged0 wv-cited0 wv-meta00 wv-ghopen wv-ghunkn wv-live00; do
    check "$id stays" "1" "$(alive "$id")"
done
check "the live node's edge stays" "1" "$(q "SELECT count(*) FROM edges WHERE target='wv-edged0';")"

echo "tombstone compaction"
# Three tombstones by hand: seq 3 (old and below the watermark), seq 7 (above the
# 90-day floor), seq 0 (pre-cutover, age unknown). The floor comes from a v2
# delta directory dated long ago whose highest seq is 5; its sidecar names our
# agent so the roster accounts for it.
q "INSERT OR REPLACE INTO tombstones(kind,id,lineage_seq,lineage_actor) VALUES
   ('node','wv-old003',3,'$WV_AGENT_ID'),('node','wv-new007',7,'$WV_AGENT_ID'),('node','wv-pre000',0,'');"
mkdir -p "$WEAVE_DIR/deltas/2025-01-01/v2"
printf '{"format":"weave.delta.v2","actor_id":"%s"}\n' "$WV_AGENT_ID" > "$WEAVE_DIR/deltas/2025-01-01/v2/000000000005-floor.json"
tomb_total=$(q "SELECT count(*) FROM tombstones;")
# The prune above wrote tombstones at the fixture's own lineage seqs, which wv
# sync stamped small, so they too sit below the planted floor: the expected
# count is every tombstone under the policy predicate, not the one hand row.
expect_n=$(q "SELECT count(*) FROM tombstones WHERE lineage_seq > 0 AND lineage_seq < 10 AND lineage_seq <= 5;")
above_floor=$(q "SELECT count(*) FROM tombstones WHERE lineage_seq > 5;")
out=$("$WV" prune --compact-tombstones --dry-run 2>&1); rc=$?
check "compaction is off by default" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
has "...naming the knob" "WV_TOMBSTONE_COMPACTION" "$out"
out=$(WV_TOMBSTONE_COMPACTION=1 "$WV" prune --compact-tombstones --dry-run 2>&1); rc=$?
check "with no roster: refuses" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
has "...because a writer is unaccounted" "does not account" "$out"
mkdir -p "$WEAVE_DIR/clones"
printf 'id %s\nconfirmed 2026-11-10\n' "$WV_AGENT_ID" > "$WEAVE_DIR/clones/here.roster"
out=$(WV_TOMBSTONE_COMPACTION=1 "$WV" prune --compact-tombstones --dry-run 2>&1); rc=$?
check "a roster without a watermark: refuses" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
has "...naming the clone" "unwatermarked here" "$out"
printf 'id %s\nconfirmed 2026-11-10\nwatermark 10\n' "$WV_AGENT_ID" > "$WEAVE_DIR/clones/here.roster"
out=$(WV_TOMBSTONE_COMPACTION=1 "$WV" prune --compact-tombstones --dry-run 2>&1); rc=$?
check "dry run exits 0" "0" "$rc"
has "...reporting the watermark and the floor" "lowest clone watermark 10; 90-day floor at lineage seq 5" "$out"
has "...and would compact every tombstone below both" "Would compact $expect_n tombstone" "$out"
check "...the hand-planted old one among them" "1" "$([ "$expect_n" -ge 1 ] && echo 1 || echo 0)"
check "...removing nothing" "$tomb_total" "$(q "SELECT count(*) FROM tombstones;")"
out=$(WV_TOMBSTONE_COMPACTION=1 "$WV" prune --compact-tombstones 2>&1); rc=$?
check "compaction exits 0" "0" "$rc"
has "...and reports it" "Compacted $expect_n tombstone" "$out"
check "the old tombstone below the watermark and the floor is gone" "0" "$(q "SELECT count(*) FROM tombstones WHERE id='wv-old003';")"
check "the tombstone above the floor stays" "1" "$(q "SELECT count(*) FROM tombstones WHERE id='wv-new007';")"
check "the seq-0 tombstone stays" "1" "$(q "SELECT count(*) FROM tombstones WHERE id='wv-pre000';")"
check "every tombstone above the floor stays" "$above_floor" "$(q "SELECT count(*) FROM tombstones WHERE lineage_seq > 5;")"
check "nothing below the floor and the watermark remains" "0" "$(q "SELECT count(*) FROM tombstones WHERE lineage_seq > 0 AND lineage_seq < 10 AND lineage_seq <= 5;")"
printf 'id %s\nconfirmed 2026-11-10\nwatermark 2\n' "$WV_AGENT_ID" > "$WEAVE_DIR/clones/here.roster"
q "INSERT INTO tombstones(kind,id,lineage_seq,lineage_actor) VALUES ('node','wv-old004',4,'$WV_AGENT_ID');"
out=$(WV_TOMBSTONE_COMPACTION=1 "$WV" prune --compact-tombstones 2>&1); rc=$?
check "a watermark below the tombstone keeps it" "1" "$(q "SELECT count(*) FROM tombstones WHERE id='wv-old004';")"
has "...and says there is nothing to compact" "No tombstone to compact" "$out"

echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
