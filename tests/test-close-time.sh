#!/usr/bin/env bash
# "done" is an argument to the wv helper below, never the loop keyword.
# shellcheck disable=SC1010
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# wv show --close-time derives when a node closed from the committed graph
# history, rather than storing a second timestamp (wv-90036a). updated_at moves
# on any later edit and the delta log is netted and compacted, so the close is
# the newest commit whose .weave/nodes.jsonl shows the node done while its
# parent shows it open, and the close time is the node's updated_at there.
set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
export WV_REQUIRE_LEARNING=0 WV_REQUIRE_QUALITY=0 WV_AUTO_CHECKPOINT=0 WV_RUN_CACHE=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WV="$ROOT/scripts/wv"
run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }
TMP=$(mktemp -d /tmp/wv-close-time-XXXXXX)
trap 'rm -rf "$TMP"' EXIT

R="$TMP/repo"; mkdir -p "$R" "$TMP/cfg"
git -C "$R" init -q . && git -C "$R" config user.email t@t && git -C "$R" config user.name t
git -C "$R" config commit.gpgsign false
# The attributes a Weave repository carries (install.sh's managed block): its
# -diff makes git treat nodes.jsonl as binary, which the history walk must read.
grep -m1 '^\.weave/nodes\.jsonl ' "$ROOT/install.sh" > "$R/.gitattributes"
DB="$TMP/hot/brain.db"
w() { (cd "$R" && WEAVE_DIR="$R/.weave" WV_HOT_ZONE="$TMP/hot" WV_CONFIG_DIR="$TMP/cfg" "$WV" "$@") </dev/null; }
add() { w add "$@" --standalone 2>/dev/null | grep -oE 'wv-[a-f0-9]{6}' | sed -n 1p; }
close() { w done "$1" --skip-verification --no-warn >/dev/null 2>&1; }
# snapshot — dump the graph to .weave/ and commit it, as a checkpoint does
snapshot() {
    w sync >/dev/null 2>&1
    git -C "$R" add -f .weave/nodes.jsonl >/dev/null 2>&1
    git -C "$R" -c core.hooksPath=/dev/null commit -q --allow-empty -m "snapshot $1" >/dev/null 2>&1
}
updated() { sqlite3 "$DB" "SELECT updated_at FROM nodes WHERE id='$1';"; }
ct() { w show "$1" --close-time --json 2>/dev/null | jq -c '.close_time'; }
w init >/dev/null 2>&1

edited=$(add "closed, then edited"); twice=$(add "closed, reopened, closed again"); pruned=$(add "closed, pruned, restored")
open=$(add "still open")
snapshot "all open"
sleep 1.1
close "$edited"; close "$pruned"; close "$twice"
closed_edited=$(updated "$edited"); closed_pruned=$(updated "$pruned")
quick=$(add "created and closed between snapshots"); close "$quick"; closed_quick=$(updated "$quick")
snapshot "closes"
closes_commit=$(git -C "$R" log -1 --format=%h -- .weave/nodes.jsonl)
sleep 1.1
w update "$edited" --metadata='{"later":"an edit after the close"}' >/dev/null 2>&1
snapshot "an edit after the close"

echo "=== the close, not the last edit ==="
[ "$(updated "$edited")" != "$closed_edited" ] && ok "a later edit moved updated_at (the finding's premise)" ||
    bad "a later edit moved updated_at (the finding's premise)"
check "close time is the close transaction's timestamp" "$(ct "$edited" | jq -r '.closed_at')" "$closed_edited"
check "and falls inside its window" "$(ct "$edited" | jq -r '.within_window')" "true"
check "a node created and closed between snapshots still derives" "$(ct "$quick" | jq -r '.closed_at')" "$closed_quick"

echo "=== a prune and restore is not a close ==="
# A snapshot without the node (wv prune archived it), then one with it back.
grep -vF "\"id\":\"$pruned\"" "$R/.weave/nodes.jsonl" > "$TMP/pruned.jsonl"
cp "$R/.weave/nodes.jsonl" "$TMP/full.jsonl"
cp "$TMP/pruned.jsonl" "$R/.weave/nodes.jsonl"
git -C "$R" add -f .weave/nodes.jsonl && git -C "$R" -c core.hooksPath=/dev/null commit -qm "pruned" >/dev/null 2>&1
sleep 1.1
cp "$TMP/full.jsonl" "$R/.weave/nodes.jsonl"
git -C "$R" add -f .weave/nodes.jsonl && git -C "$R" -c core.hooksPath=/dev/null commit -qm "restored" >/dev/null 2>&1
# The restored line carries the same updated_at as the real close, so the
# timestamp alone cannot tell them apart: the commit and the window do.
check "the restore is skipped for the real close" "$(ct "$pruned" | jq -r '"\(.closed_at) \(.commit) \(.within_window)"')" \
    "$closed_pruned $closes_commit true"

echo "=== the latest close counts ==="
sleep 1.1
w work "$twice" --reopen >/dev/null 2>&1
snapshot "reopened"
sleep 1.1
close "$twice"; closed_twice=$(updated "$twice")
snapshot "closed again"
check "a reopened node reports its second close" "$(ct "$twice" | jq -r '.closed_at')" "$closed_twice"

echo "=== what it cannot know, it says ==="
check "an open node is not closed" "$(ct "$open" | jq -r '.reason')" "not closed"
late=$(add "closed, not yet committed"); close "$late"
[[ "$(ct "$late" | jq -r '.reason')" == "no committed snapshot"* ]] && ok "a close no snapshot holds yet is unknown, not guessed" ||
    bad "a close no snapshot holds yet is unknown, not guessed" "$(ct "$late")"
check "plain --json keeps its shape" "$(w show "$edited" --json 2>/dev/null | jq 'has("close_time")')" "false"
check "--json-v2 (the MCP weave_show shape) carries it too" \
    "$(w show "$edited" --json-v2 --close-time 2>/dev/null | jq -r '.[0].close_time.closed_at')" "$closed_edited"
[[ "$(w show "$edited" --close-time 2>&1)" == *"Closed:   $closed_edited UTC"* ]] && ok "the text view prints the derived close" ||
    bad "the text view prints the derived close" "$(w show "$edited" --close-time 2>&1 | grep Closed)"

echo "=== who acted: --actors reads the Delta v2 log (wv-8c24e6) ==="
# Graph state keeps only the last writer, and a closed node keeps no claimed_by;
# the append-only operation log keeps one actor per operation.
as() { local a="$1"; shift; (export WV_AGENT_ID="$a"; w "$@"); }
multi=$(as actor-a add "touched by three actors" --standalone 2>/dev/null | grep -oE 'wv-[a-f0-9]{6}' | sed -n 1p)
as actor-a sync >/dev/null 2>&1
as actor-b work "$multi" >/dev/null 2>&1; as actor-b sync >/dev/null 2>&1
as actor-c work "$multi" --force >/dev/null 2>&1
as actor-c done "$multi" --skip-verification --no-warn >/dev/null 2>&1; as actor-c sync >/dev/null 2>&1
act() { w show "$1" --actors --json 2>/dev/null | jq -c '.actors'; }
check "the creator is the first operation's actor" "$(act "$multi" | jq -r '.created_by.actor')" "actor-a"
check "the claim is the transition into active" "$(act "$multi" | jq -r '[.claimed_by[].actor] | join(",")')" "actor-b"
check "the closer is the actor of the transition into done" "$(act "$multi" | jq -r '.closed_by.actor')" "actor-c"
check "every actor stays on record" "$(act "$multi" | jq -r '[.events[].actor] | unique | join(",")')" "actor-a,actor-b,actor-c"
as actor-a work "$multi" --reopen --force >/dev/null 2>&1; as actor-a sync >/dev/null 2>&1
as actor-a done "$multi" --skip-verification --no-warn >/dev/null 2>&1; as actor-a sync >/dev/null 2>&1
check "after a reopen, the latest close counts" "$(act "$multi" | jq -r '.closed_by.actor')" "actor-a"
check "and the earlier claim is still listed" "$(act "$multi" | jq -r '[.claimed_by[].actor] | join(",")')" "actor-b,actor-a"
# Every write auto-syncs, so the no-operation case is history written with the
# v2 writer off, which is what all history before the cutover looks like.
prev2=$( (export WV_DELTA_V2_WRITE=0; w add "written with the v2 writer off" --standalone 2>/dev/null) | grep -oE 'wv-[a-f0-9]{6}' | sed -n 1p)
check "a node with no v2 operation says so" "$(act "$prev2" | jq -r '.reason')" "no Delta v2 operation names this node"
check "plain --json keeps its shape without --actors" "$(w show "$multi" --json 2>/dev/null | jq 'has("actors")')" "false"
check "--json-v2 carries it too" "$(w show "$multi" --json-v2 --actors 2>/dev/null | jq -r '.[0].actors.closed_by.actor')" "actor-a"
[[ "$(w show "$multi" --actors 2>&1)" == *"closed by actor-a"* ]] && ok "the text view names the closer" ||
    bad "the text view names the closer" "$(w show "$multi" --actors 2>&1 | grep Actors)"

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
