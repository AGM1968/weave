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
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
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

# A command taking one input kept the first or the last of several and ran on
# it alone, reporting that as the whole result (wv-51bd63). The message must be
# the parser's refusal, not a later error that happens to quote the name, and
# the batch, plan and trails files must be untouched.
printf 'add "batch one" --standalone\n' > "$TMP/one.txt"
printf 'add "batch two" --standalone\n' > "$TMP/two.txt"
printf '# Plan\n\n## Sprint 1: S\n\n- [ ] Task one\n' > "$TMP/one.md"
cp "$TMP/one.md" "$TMP/two.md"
printf '# A\n' > "$R/A.md"; printf '# B\n' > "$R/B.md"
files() { cat "$R/.weave/trails.md" 2>/dev/null | cksum; [ -e "$TMP/hot/quality.db" ] && echo quality.db; }
extra() {
    local label="$1" name="$2" before out rc
    shift 2
    before="$(state) $(files)"
    out=$(w "$@" 2>&1 </dev/null); rc=$?
    if [ "$rc" != 0 ] && [ "$(state) $(files)" = "$before" ] && [[ "$out" == *"unknown argument '$name'"* ]]; then
        ok "$label"
    else
        bad "$label" "rc=$rc changed=$([ "$(state) $(files)" = "$before" ] && echo no || echo yes) $(echo "$out" | tail -2)"
    fi
}

echo "=== a second input to a one-input command is refused ==="
extra "wv batch <f> <f>"            "$TMP/two.txt" batch "$TMP/one.txt" "$TMP/two.txt"
extra "wv batch --dryrun <f>"       "--dryrun"     batch --dryrun "$TMP/one.txt"
extra "wv plan <f> <f>"             "$TMP/two.md"  plan "$TMP/one.md" "$TMP/two.md" --sprint=1
extra "wv plan --dryrun <f>"        "--dryrun"     plan --dryrun "$TMP/one.md" --sprint=1
extra "wv trails save --message x"  "--message"    trails save --message "lost"
extra "wv trails capsule <id> <id>" "$b"           trails capsule "$a" "$b" --json='{}'
extra "wv trails show save"         "save"         trails show save
extra "wv unarchive <id> <id>"      "$b"           unarchive "$a" "$b"
extra "wv refs -t x -t y"           "-t"           refs -t "first wv-000001" -t "second wv-000002"
extra "wv refs -t x <y>"            "second"       refs -t "first" second
extra "wv refs --bogus"             "--bogus"      refs --bogus -t "text"
extra "wv context <id> <id>"        "$b"           context "$a" "$b" --json
extra "wv tree <id> <id>"           "$b"           tree "$a" "$b"
extra "wv tree --root=<id> <id>"    "$b"           tree --root="$a" "$b"
for sub in scan list report validate; do
    extra "wv quality patterns $sub A B" "B.md" quality patterns "$sub" A.md B.md
done
extra "wv quality patterns show r1 r2" "r2" quality patterns show r1 r2

echo "=== the forms in use still work ==="
out=$(w trails save --message="kept" 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q kept "$R/.weave/trails.md" &&
    ok "wv trails save --message= still saves" || bad "wv trails save --message= still saves" "rc=$rc $out"
out=$(w batch "$TMP/one.txt" 2>&1 </dev/null); rc=$?
[ "$rc" = 0 ] && [ "$(q "SELECT COUNT(*) FROM nodes WHERE text LIKE '%batch one%'")" = 1 ] &&
    ok "wv batch <file> still runs it" || bad "wv batch <file> still runs it" "rc=$rc $out"
out=$(w context "$a" --json 2>&1); rc=$?
[ "$rc" = 0 ] && [[ "$out" == *"$a"* ]] && ok "wv context <id> still works" || bad "wv context <id> still works" "rc=$rc"
out=$(w refs -t "see $a" --json 2>&1 </dev/null); rc=$?
[ "$rc" = 0 ] && ok "wv refs -t <text> still works" || bad "wv refs -t <text> still works" "rc=$rc $out"
out=$(w quality patterns scan A.md 2>&1); rc=$?
[ "$rc" = 0 ] && ok "wv quality patterns scan <path> still works" ||
    bad "wv quality patterns scan <path> still works" "rc=$rc $(echo "$out" | tail -2)"
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

# Read paths too (wv-016983, wv-d1e926). 23 of them dropped an option no arm
# read and printed their default output as if it had been honoured: 'wv tree
# --mermiad' drew the tree, 'wv ready --impact' (the flag is --with-impact)
# listed ready work with no impact and exit 0. The command set is every
# observation in the capability registry, so a new read command is covered
# without editing this list.
echo "=== a read command refuses an option it does not read ==="
mapfile -t _obs < <(jq -r '.commands[] | select(.evidence_class == "observation")
    | [.operation, (.suboperation // "")] | join(" ")' "$ROOT/contracts/command-capabilities.json" | sort -u)
[ "${#_obs[@]}" -gt 20 ] && ok "the registry names the read commands (${#_obs[@]})" \
    || bad "the registry names the read commands" "${#_obs[@]}"
_lenient=()
for _cmd in "${_obs[@]}"; do
    # shellcheck disable=SC2086  # an operation and its suboperation are two words
    out=$(w $_cmd --zz-unknown-option 2>&1); rc=$?
    # shellcheck disable=SC2086
    out2=$(w $_cmd "$a" --zz-unknown-option 2>&1); rc2=$?
    { [ "$rc" != 0 ] && [ "$rc2" != 0 ]; } || _lenient+=("$_cmd")
done
[ "${#_lenient[@]}" = 0 ] && ok "every read command refuses an unknown option, with or without an id" \
    || bad "every read command refuses an unknown option, with or without an id" "accepted by: ${_lenient[*]}"
out=$(w ready --impact 2>&1); rc=$?
[ "$rc" != 0 ] && [[ "$out" == *"'--impact'"* ]] && ok "wv ready --impact names the option it refuses" \
    || bad "wv ready --impact names the option it refuses" "rc=$rc $out"
out=$(w tree --mermiad 2>&1); rc=$?
[ "$rc" != 0 ] && [[ "$out" == *"'--mermiad'"* ]] && ok "wv tree --mermiad names the option it refuses" \
    || bad "wv tree --mermiad names the option it refuses" "rc=$rc $out"
out=$(w ready --json --with-impact 2>&1); rc=$?
[ "$rc" = 0 ] && ok "(control) wv ready --with-impact still runs" || bad "(control) wv ready --with-impact still runs" "rc=$rc"
out=$(w config list --show-origin 2>&1); rc=$?
[ "$rc" = 0 ] && ok "(control) wv config list --show-origin still runs" \
    || bad "(control) wv config list --show-origin still runs" "rc=$rc"
# --help as the first argument is the dispatcher's; after an id it is refused
# with a pointer to it. A cmd_help call in each parser would make commands in
# other modules reach wv-cmd-ops.sh, which measured route retirements rely on
# them not doing (test-map-coverage).
out=$(w show --help 2>&1); rc=$?
[ "$rc" = 0 ] && ok "(control) wv show --help prints help" || bad "(control) wv show --help prints help" "rc=$rc"
out=$(w show "$a" --help 2>&1); rc=$?
[ "$rc" != 0 ] && [[ "$out" == *"wv show --help"* ]] && ok "--help after an id is refused, pointing at wv show --help" \
    || bad "--help after an id is refused, pointing at wv show --help" "rc=$rc $out"

# 'wv add --criteria=a --criteria=b' kept only b and printed the plain success
# line, so the first criterion vanished unseen (wv-776e45). A repeated flag is
# either accumulated or refused naming the pipe form, and wv add says how many
# criteria it stored so a drop shows where it happens.
echo "=== repeated --criteria is kept or refused, and the stored count is reported ==="
out=$(w add "two criteria" --standalone "--criteria=first" "--criteria=second" 2>&1); rc=$?
crit=$(q "SELECT json_extract(metadata, '\$.done_criteria') FROM nodes WHERE text='two criteria'")
if [ "$rc" = 0 ] && [ "$crit" = '["first","second"]' ]; then
    ok "repeated --criteria keeps both criteria"
elif [ "$rc" != 0 ] && [ -z "$crit" ] && [[ "$out" == *"c1|c2"* ]]; then
    ok "repeated --criteria is refused naming the pipe-separated form"
else
    bad "repeated --criteria is kept or refused" "rc=$rc stored=${crit:-none} $(echo "$out" | tail -2)"
fi
out=$(w add "three criteria" --standalone "--criteria=a|b|c" 2>&1); rc=$?
[ "$rc" = 0 ] && [[ "$out" == *"3 done criteria stored"* ]] &&
    ok "wv add reports how many criteria it stored" ||
    bad "wv add reports how many criteria it stored" "rc=$rc $(echo "$out" | tail -2)"

# wv-26fd0b: a caller needing a few nodes names them, rather than reading all.
echo "=== wv list --ids lists exactly the named nodes ==="
w "done" "$b" --skip-verification >/dev/null 2>&1
c=$(new "node c")
out=$(w list --ids="$a,$b" --json-v2 2>/dev/null); rc=$?
got=$(jq -r '[.[].id] | sort | join(",")' <<< "$out" 2>/dev/null)
want=$(printf '%s\n%s\n' "$a" "$b" | sort | paste -sd, -)
[ "$rc" = 0 ] && [ "$got" = "$want" ] && ok "--ids returns the named nodes, a done one included, and no other" \
    || bad "--ids returns the named nodes, a done one included, and no other" "rc=$rc got=$got want=$want (c=$c)"
refused "--ids refuses an entry that is not a node id" "x;drop" list "--ids=$a,x;drop"
out=$(w list --ids= 2>&1); rc=$?
[ "$rc" != 0 ] && [[ "$out" == *"at least one node id"* ]] && ok "--ids with no id is an error, not every node" \
    || bad "--ids with no id is an error, not every node" "rc=$rc $(echo "$out" | tail -1)"

echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
