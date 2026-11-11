#!/usr/bin/env bash
# test-lineage-publish.sh -- the live graph equals its own reload after every
# mutating command (wv-61e13b, wv-851fb4).
#
# Lineage is stamped only when a change is published (wv_lineage_stamp in
# auto_sync). Writes left the live graph behind what a reload derives, so the
# next reload or flush, possibly a hook's inside an E5 capture window, moved the
# composite causal identity:
#   - wv work never published its claim (wv-61e13b);
#   - wv delete wrote the tombstone at the deleted row's own lineage, while the
#     published v2 delete op carries the emission seq that replay raises it to
#     (wv-61e13b);
#   - any write within WV_SYNC_INTERVAL (60 s) of the last publish was skipped
#     by the throttle, and block, link, unlink and resolve never published at
#     all (wv-851fb4; the throttle is gone).
# Each case compares lineage, tombstones and the change tracker before and
# after wv load, in a scratch repository.

set -u
while IFS= read -r _v; do unset "$_v"; done < <(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p')
export WV_TEST_SUITE=1
export WV_CALL_SOURCE=test

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WV="$(cd "$SCRIPT_DIR/.." && pwd)/scripts/wv"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export WV_CONFIG_DIR="$T/cfg" WV_PROJECT_DIR="$T/repo" WEAVE_DIR="$T/repo/.weave" WV_HOT_ZONE="$T/hot"
export WV_AGENT_ID="lineage-test" WV_REQUIRE_LEARNING=0 WV_AUTO_CHECKPOINT=0 WV_NONINTERACTIVE=1
# The retired throttle's old default: a config that still sets it must not hold
# any write back.
export WV_SYNC_INTERVAL=60
mkdir -p "$WV_CONFIG_DIR" "$T/repo" "$WV_HOT_ZONE"; chmod 700 "$WV_HOT_ZONE"
cd "$T/repo" && git init -q

pass=0; run=0
check() { local msg="$1"; shift; run=$((run + 1)); if "$@"; then echo "  ✓ $msg"; pass=$((pass + 1)); else echo "  ✗ $msg"; fi; }
db() { echo "$WV_HOT_ZONE/brain.db"; }
# The lineage-bearing state a reload rebuilds: every node's and edge's lineage,
# and every tombstone.
lineage_state() {
    sqlite3 "$(db)" "SELECT 'n', id, lineage_seq, lineage_actor FROM nodes ORDER BY id;
                     SELECT 'e', source, target, type, lineage_seq, lineage_actor FROM edges ORDER BY 1,2,3,4;
                     SELECT 't', kind, id, lineage_seq, lineage_actor FROM tombstones ORDER BY kind, id;"
}
# Tracked changes that would publish something (a stamp's own trigger rows,
# which change no field, would publish nothing).
real_pending() {
    sqlite3 "$(db)" "SELECT COUNT(*) FROM _warp_changes WHERE operation != 'UPDATE'
        OR json_extract(old_data,'\$.status') IS NOT json_extract(new_data,'\$.status')
        OR json_extract(old_data,'\$.metadata') IS NOT json_extract(new_data,'\$.metadata')
        OR json_extract(old_data,'\$.text') IS NOT json_extract(new_data,'\$.text')
        OR json_extract(old_data,'\$.alias') IS NOT json_extract(new_data,'\$.alias');"
}
reload_keeps_lineage() {
    local before after
    before=$(lineage_state); "$WV" load >/dev/null 2>&1; after=$(lineage_state)
    [ "$before" = "$after" ] || { diff <(echo "$before") <(echo "$after") | sed 's/^/      /'; return 1; }
}
add_node() { "$WV" add "$1" --criteria=c --risks=low --standalone 2>/dev/null; }

"$WV" init >/dev/null 2>&1
A=$(add_node "lineage probe a"); B=$(add_node "lineage probe b")
C=$(add_node "lineage probe c"); D=$(add_node "lineage probe d")
"$WV" sync >/dev/null 2>&1

echo "--- a claim publishes itself ---"
# A write just before the claim: under the old throttle the claim was skipped.
"$WV" update "$A" --metadata='{"note":"just before the claim"}' >/dev/null 2>&1
out=$("$WV" work "$A" --quiet 2>/dev/null)
check "a claim right after another write leaves nothing to publish" test "$(real_pending)" -eq 0
check "--quiet stdout is only the export line" test "$out" = "export WV_ACTIVE=$A"
check "a reload after the claim keeps every lineage" reload_keeps_lineage
check "--json stdout is one JSON object" bash -c "'$WV' work '$A' --json 2>/dev/null | jq -e '.status == \"active\"' >/dev/null"

echo "--- a delete's tombstone carries the lineage its op published ---"
# Back to back with an update: under the old throttle neither was published.
"$WV" update "$A" --status=todo >/dev/null 2>&1
"$WV" delete "$B" --force --no-gh >/dev/null 2>&1
check "an update then a delete leave nothing to publish" test "$(real_pending)" -eq 0
check "the tombstone exists" test "$(sqlite3 "$(db)" "SELECT COUNT(*) FROM tombstones WHERE id='$B';")" -eq 1
check "a reload after the delete keeps every lineage and tombstone" reload_keeps_lineage

echo "--- edge commands publish (they never did) ---"
"$WV" block "$C" --by="$D" >/dev/null 2>&1
check "block leaves nothing to publish" test "$(real_pending)" -eq 0
check "a reload after block keeps every lineage" reload_keeps_lineage
"$WV" link "$C" "$D" --type=relates_to >/dev/null 2>&1
check "link leaves nothing to publish" test "$(real_pending)" -eq 0
check "a reload after link keeps every lineage" reload_keeps_lineage
"$WV" unlink "$C" "$D" --type=relates_to >/dev/null 2>&1
check "unlink leaves nothing to publish" test "$(real_pending)" -eq 0
check "a reload after unlink keeps every lineage" reload_keeps_lineage

echo ""
echo "$pass/$run passed"
[ "$pass" -eq "$run" ]
