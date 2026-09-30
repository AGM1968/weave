#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# Write-path commands apply or refuse every argument (wv-86a96a).
#
# Their parsers skipped an argument no branch matched and still printed the
# success line, so a typo lost data silently: 'wv done <id> --learnings=...'
# closed the node without the learning, 'wv add ... --criterias=...' created a
# node without criteria. wv update was fixed first (wv-51605f); every other
# write path now refuses an unknown option or a stray positional before it
# writes. wv add and wv quick still join bare words into the node text.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WV="$ROOT/scripts/wv"
run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
TMP=$(mktemp -d /tmp/wv-cli-args-XXXXXX)
trap 'rm -rf "$TMP"' EXIT

R="$TMP/repo"; mkdir -p "$R" "$TMP/cfg"
git -C "$R" init -q . && git -C "$R" config user.email t@t && git -C "$R" config user.name t
w() { (cd "$R" && WEAVE_DIR="$R/.weave" WV_HOT_ZONE="$TMP/hot" WV_CONFIG_DIR="$TMP/cfg" \
    WV_REQUIRE_LEARNING=0 WV_AUTO_CHECKPOINT=0 "$WV" "$@"); }
DB="$TMP/hot/brain.db"
w init >/dev/null 2>&1
q() { sqlite3 "$DB" "$1"; }
new() { w add "$1" --standalone 2>/dev/null | grep -oE 'wv-[a-f0-9]{6}' | sed -n 1p; }
a=$(new "node a"); b=$(new "node b")
[ -n "$a" ] && [ -n "$b" ] && ok "fixture nodes created" || bad "fixture nodes created"
state() { q "SELECT (SELECT COUNT(*) FROM nodes)||'/'||(SELECT COUNT(*) FROM edges)||'/'||(SELECT group_concat(id||':'||status||':'||metadata,';') FROM (SELECT * FROM nodes ORDER BY id))"; }

# refused <label> <expected-name-in-message> <wv-args...> — fails, names the
# argument, and leaves every node and edge as it was.
refused() {
    local label="$1" name="$2" before out rc
    shift 2
    before=$(state)
    out=$(w "$@" 2>&1); rc=$?
    if [ "$rc" != 0 ] && [ "$(state)" = "$before" ] && [[ "$out" == *"'$name'"* ]]; then
        ok "$label"
    else
        bad "$label" "rc=$rc changed=$([ "$(state)" = "$before" ] && echo no || echo yes) $(echo "$out" | tail -2)"
    fi
}

echo "=== an unknown option is refused before anything is written ==="
refused "wv add"   "--criterias=a|b" add "typo node" --standalone "--criterias=a|b"
refused "wv quick" "--bogus-flag"    quick "quick node" --bogus-flag
refused "wv done"  "--learnings=x"   "done" "$a" --skip-verification "--learnings=x"
refused "wv work"  "--bogus-flag"    work "$a" --bogus-flag
refused "wv block" "--bogus-flag"    block "$a" --by="$b" --bogus-flag
refused "wv link"  "--bogus-flag"    link "$a" "$b" --type=relates_to --bogus-flag
refused "wv touch" "--bogus-flag"    touch "$a" --metadata='{"k":1}' --bogus-flag
refused "wv ship"  "--bogus-flag"    ship "$a" --skip-verification --bogus-flag

echo "=== and so is a stray positional ==="
refused "wv done <id> <extra>"   "extra" "done" "$a" extra --skip-verification
refused "wv work <id> <extra>"   "extra" work "$a" extra
refused "wv block <id> <extra>"  "extra" block "$a" extra --by="$b"
refused "wv link <a> <b> <extra>" "extra" link "$a" "$b" extra --type=relates_to
refused "wv touch <id> <extra>"  "extra" touch "$a" extra --metadata='{"k":1}'

echo "=== the forms in use still work ==="
out=$(w add bare words join --standalone 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(q "SELECT COUNT(*) FROM nodes WHERE text='bare words join'")" = 1 ] &&
    ok "wv add joins bare words into the text" || bad "wv add joins bare words into the text" "rc=$rc $out"
out=$(w link "$a" "$b" --type=relates_to 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(q "SELECT COUNT(*) FROM edges WHERE source='$a' AND target='$b'")" = 1 ] &&
    ok "wv link with known options" || bad "wv link with known options" "rc=$rc $out"
c=$(new "node c")
out=$(w ship "$c" --skip-verification --no-gh 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(q "SELECT status FROM nodes WHERE id='$c'")" = "done" ] &&
    ok "wv ship accepts --no-gh (GitHub sync is already off by default)" ||
    bad "wv ship accepts --no-gh (GitHub sync is already off by default)" "rc=$rc $out"

echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
