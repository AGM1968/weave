#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# Metadata numbers must be integers (wv-855394). weave.canonical-json.v1 admits
# integer values only, so the Delta v2 sidecar encoder refuses a float and every
# later write to that node fell back to an SQL-only delta with only a stderr
# warning. The CLI accepted floats (wv-562ed6's gate baseline carried four). It
# now refuses a non-integer number on every path that stores metadata, judged by
# the parser the sidecar uses: 1.0 and 1e3 are floats there even though jq reads
# them as integers.
#
# The same paths must refuse a risk_level outside the contract (wv-c0c51e):
# wv touch and wv quick stored metadata with neither check.
set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WV="$ROOT/scripts/wv"
run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
TMP=$(mktemp -d /tmp/wv-canon-num-XXXXXX)
trap 'rm -rf "$TMP"' EXIT

R="$TMP/repo"; mkdir -p "$R" "$TMP/cfg"
git -C "$R" init -q . && git -C "$R" config user.email t@t && git -C "$R" config user.name t
w() { (cd "$R" && WEAVE_DIR="$R/.weave" WV_HOT_ZONE="$TMP/hot" WV_CONFIG_DIR="$TMP/cfg" "$WV" "$@"); }
DB="$TMP/hot/brain.db"
w init >/dev/null 2>&1
count() { sqlite3 "$DB" "SELECT COUNT(*) FROM nodes;"; }
meta() { sqlite3 "$DB" "SELECT metadata FROM nodes WHERE id='$1';"; }

id=$(w add "a node" --standalone 2>/dev/null | grep -oE 'wv-[a-f0-9]{6}' | sed -n 1p)
[ -n "$id" ] && ok "fixture node created" || bad "fixture node created"

echo "=== every write path refuses a non-integer number ==="
# refused <label> <json> — wv update --metadata=<json> fails and changes nothing.
refused() {
    local before out rc
    before=$(meta "$id")
    out=$(w update "$id" --metadata="$2" 2>&1); rc=$?
    [ "$rc" != 0 ] && [ "$(meta "$id")" = "$before" ] && [[ "$out" == *"integer"* ]] &&
        ok "wv update refuses $1" || bad "wv update refuses $1" "rc=$rc $out"
}
refused "a decimal"             '{"serial_p50_s":142.5}'
refused "1.0 (jq reads it as 1)" '{"n":1.0}'
refused "an exponent (1e3)"     '{"n":1e3}'
refused "a float nested in a list" '{"b":{"runs":[1,2.5]}}'

before=$(count)
out=$(w add "float via add" --standalone --metadata='{"x":0.5}' 2>&1); rc=$?
[ "$rc" != 0 ] && [ "$(count)" = "$before" ] &&
    ok "wv add refuses a float and stores nothing" || bad "wv add refuses a float and stores nothing" "rc=$rc $out"
echo '{"x":0.5}' > "$TMP/meta.json"
before=$(meta "$id")
out=$(w update "$id" --metadata-file="$TMP/meta.json" 2>&1); rc=$?
[ "$rc" != 0 ] && [ "$(meta "$id")" = "$before" ] &&
    ok "wv update --metadata-file refuses a float" || bad "wv update --metadata-file refuses a float" "rc=$rc $out"
before=$(meta "$id")
out=$(w touch "$id" --metadata='{"x":0.5}' 2>&1); rc=$?
[ "$rc" != 0 ] && [ "$(meta "$id")" = "$before" ] &&
    ok "wv touch refuses a float" || bad "wv touch refuses a float" "rc=$rc $out"
before=$(count)
out=$(w quick "float via quick" --metadata='{"x":0.5}' 2>&1); rc=$?
[ "$rc" != 0 ] && [ "$(count)" = "$before" ] &&
    ok "wv quick refuses a float and stores nothing" || bad "wv quick refuses a float and stores nothing" "rc=$rc $out"

echo "=== and a risk_level outside the contract ==="
before=$(meta "$id")
out=$(w touch "$id" --metadata='{"risk_level":"critical"}' 2>&1); rc=$?
[ "$rc" != 0 ] && [ "$(meta "$id")" = "$before" ] &&
    ok "wv touch refuses risk_level=critical" || bad "wv touch refuses risk_level=critical" "rc=$rc $out"
before=$(count)
out=$(w quick "critical via quick" --metadata='{"risk_level":"critical"}' 2>&1); rc=$?
[ "$rc" != 0 ] && [ "$(count)" = "$before" ] &&
    ok "wv quick refuses risk_level=critical" || bad "wv quick refuses risk_level=critical" "rc=$rc $out"

echo "=== canonical values still pass ==="
out=$(w update "$id" --metadata='{"serial_p50_ms":142500,"label":"142.5","ok":true,"none":null}' 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(sqlite3 "$DB" "SELECT json_extract(metadata,'\$.serial_p50_ms') FROM nodes WHERE id='$id';")" = 142500 ] &&
    ok "integers, decimal strings, booleans and null are stored" || bad "integers, decimal strings, booleans and null are stored" "rc=$rc $out"
# Sidecars are written when deltas are staged; judge the update plus a sync.
out=$( { w update "$id" --metadata='{"next":1}'; w sync; } 2>&1 )
[[ "$out" == *"sidecar write failed"* ]] && bad "the node's next write emits its v2 sidecar" "$out" ||
    ok "the node's next write emits its v2 sidecar"

echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
