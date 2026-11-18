#!/usr/bin/env bash
# "done" is an argument to the wv helper below, never the loop keyword.
# shellcheck disable=SC1010
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# Every edge type carries a checked invariant (ontology S2, wv-76b361). The
# authority is contracts/edge-types-v1.json. wv link refuses an edge that breaks
# one, wv block refuses a blocks cycle of any length, wv doctor reports stored
# edges that break one (never refused on read, D4), and no close path closes a
# node over an open implements child that nothing accounts for.
set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
# Fixture rows are edited with sqlite3, which the run cache cannot see.
export WV_RUN_CACHE=0
export WV_REQUIRE_LEARNING=0 WV_REQUIRE_QUALITY=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WV="$ROOT/scripts/wv"
CONTRACT="$ROOT/contracts/edge-types-v1.json"
run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }
TMP=$(mktemp -d /tmp/wv-edge-invariants-XXXXXX)
trap 'rm -rf "$TMP"' EXIT

echo "=== one authority ==="
lib() { bash -c '. "$1/scripts/lib/wv-validate.sh" >/dev/null 2>&1; . "$1/scripts/lib/wv-db.sh" >/dev/null 2>&1; eval "$2"' _ "$ROOT" "$1"; }
check "the CLI edge types are the contract's, in order" \
    "$(lib 'echo $VALID_EDGE_TYPES')" "$(jq -r '.types | keys_unsorted | join(" ")' "$CONTRACT")"
for tool in weave_link weave_unlink; do
    mcp=$(awk -v t="name: \"$tool\"" 'index($0, t) {f=1} f && /enum: \[/ {e=1; next} e && /\]/ {exit} e' "$ROOT/mcp/src/index.ts" |
        grep -oE '"[a-z_]+"' | tr -d '"' | paste -sd' ')
    check "the MCP $tool edge types are the contract's" "$mcp" "$(jq -r '.types | keys_unsorted | join(" ")' "$CONTRACT")"
done
contract=$(jq -r '[.common[].id, (.types[].invariants[].id)] | unique | join(" ")' "$CONTRACT")
sql=$(lib 'wv_edge_violations_sql "SELECT 1, 2, 3"' | grep -oE "^SELECT '[a-z_]+'" | grep -oE "'[a-z_]+'" | tr -d "'" | sort -u | paste -sd' ')
check "the query checks exactly the contract's invariants" "$sql" "$contract"
hints=$(sed -n '/^_link_explain_violation()/,/^}/p' "$ROOT/scripts/cmd/wv-cmd-graph.sh" | grep -oE '^ +[a-z_]+\)' | tr -d ' )' | sort -u | paste -sd' ')
check "wv link explains every invariant it can refuse by" "$hints" "$contract"

R="$TMP/repo"; mkdir -p "$R" "$TMP/cfg"
git -C "$R" init -q . && git -C "$R" config user.email t@t && git -C "$R" config user.name t
w() { (cd "$R" && WEAVE_DIR="$R/.weave" WV_HOT_ZONE="$TMP/hot" WV_CONFIG_DIR="$TMP/cfg" "$WV" "$@") </dev/null; }
DB="$TMP/hot/brain.db"
w init >/dev/null 2>&1
add() { w add "$@" --standalone 2>/dev/null | grep -oE 'wv-[a-f0-9]{6}' | sed -n 1p; }
child() { w add "$1" --parent="$2" "${@:3}" 2>/dev/null | grep -oE 'wv-[a-f0-9]{6}' | sed -n 1p; }
age() { sqlite3 "$DB" "UPDATE nodes SET created_at='$2' WHERE id='$1';"; }
edges() { sqlite3 "$DB" "SELECT COUNT(*) FROM edges WHERE source='$1' AND target='$2' AND type='$3';"; }
status_of() { sqlite3 "$DB" "SELECT status FROM nodes WHERE id='$1';"; }
doctor_check() { w doctor --json 2>/dev/null | jq -r --arg c "$1" '.checks[] | select(.check == $c) | "\(.status) \(.detail)"'; }
# refused <label> <invariant> <from> <to> <type> — wv link exits nonzero, names
# the invariant, and stores nothing.
refused() {
    local out rc
    out=$(w link "$3" "$4" --type="$5" 2>&1); rc=$?
    if [ "$rc" -ne 0 ] && [[ "$out" == *"$2"* ]] && [ "$(edges "$3" "$4" "$5")" = "0" ]; then
        ok "$1"
    else
        bad "$1" "rc=$rc stored=$(edges "$3" "$4" "$5") out=$(head -2 <<< "$out" | tr '\n' ' ')"
    fi
}
admitted() {
    local out rc
    out=$(w link "$2" "$3" --type="$4" 2>&1); rc=$?
    if [ "$rc" -eq 0 ] && [ "$(edges "$2" "$3" "$4")" = "1" ]; then ok "$1"; else bad "$1" "rc=$rc out=$(head -2 <<< "$out" | tr '\n' ' ')"; fi
}

check "a clean graph passes the edge report" "$(doctor_check "edge invariants" | cut -d' ' -f1)" "pass"
check "a clean graph has no closed parent over an open child" "$(doctor_check "closed parents" | cut -d' ' -f1)" "pass"

echo "=== wv link refuses an edge that breaks its invariant ==="
old=$(add "an older decision"); new=$(add "a newer decision")
age "$old" "2026-01-01 00:00:00"; age "$new" "2026-02-01 00:00:00"
refused "a backwards supersedes (new -> old) is refused" target_newer_or_declared "$new" "$old" supersedes
admitted "supersedes old -> new is admitted" "$old" "$new" supersedes
older=$(add "an older winner"); newer=$(add "a newer loser")
age "$older" "2026-01-01 00:00:00"; age "$newer" "2026-02-01 00:00:00"
w update "$newer" --metadata="{\"superseded_by\":\"$older\"}" >/dev/null 2>&1
admitted "new -> old is admitted when the source's superseded_by declares it" "$newer" "$older" supersedes
mem_old=$(w remember "an older fact" 2>/dev/null | grep -oE 'wv-[a-f0-9]{6}' | sed -n 1p)
mem_new=$(w remember "a newer fact" 2>/dev/null | grep -oE 'wv-[a-f0-9]{6}' | sed -n 1p)
age "$mem_old" "2026-01-01 00:00:00"; age "$mem_new" "2026-02-01 00:00:00"
refused "a superseded memory must name its successor" memory_superseded_by "$mem_old" "$mem_new" supersedes
a=$(add "cycle a"); b=$(add "cycle b"); c=$(add "cycle c")
admitted "a blocks chain is admitted" "$a" "$b" blocks
w link "$b" "$c" --type=blocks >/dev/null 2>&1
refused "a blocks edge closing a three-node cycle is refused" acyclic "$c" "$a" blocks
refused "a self-edge is refused" no_self_edge "$a" "$a" relates_to
epic=$(add "an epic" --metadata='{"type":"epic"}')
kid=$(child "a child" "$epic")
refused "an implements edge closing a cycle is refused" acyclic "$epic" "$kid" implements
fix=$(add "fix(x): some work"); plain=$(add "task(x): other work")
refused "resolves between two non-findings is refused" finding_endpoint "$fix" "$plain" resolves
gap=$(add "finding(test:gap): a gap found")
admitted "resolves to a finding( node is admitted" "$fix" "$gap" resolves
typed=$(add "a promoted finding" --kind=finding)
admitted "resolves to a node of kind finding is admitted" "$plain" "$typed" resolves
pit=$(add "an older pitfall"); fixer=$(add "a newer fix")
age "$pit" "2026-01-01 00:00:00"; age "$fixer" "2026-02-01 00:00:00"
refused "addresses from the older node is refused" source_newer "$pit" "$fixer" addresses
admitted "addresses from the newer node is admitted" "$fixer" "$pit" addresses

echo "=== wv block refuses a cycle of any length ==="
x=$(add "block x"); y=$(add "block y"); z=$(add "block z")
w block "$y" --by="$x" >/dev/null 2>&1; w block "$z" --by="$y" >/dev/null 2>&1
out=$(w block "$x" --by="$z" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && [ "$(edges "$z" "$x" blocks)" = "0" ]; then ok "a three-node block cycle is refused"; else bad "a three-node block cycle is refused" "rc=$rc $out"; fi

echo "=== wv doctor reports stored violations ==="
p=$(add "planted old"); q=$(add "planted new")
age "$p" "2026-01-01 00:00:00"; age "$q" "2026-02-01 00:00:00"
sqlite3 "$DB" "INSERT INTO edges(source,target,type,weight,context) VALUES('$q','$p','supersedes',1.0,'{}');
               INSERT INTO edges(source,target,type,weight,context) VALUES('$z','$x','blocks',1.0,'{}');"
report=$(doctor_check "edge invariants")
check "the report warns" "${report%% *}" "warn"
[[ "$report" == *"target_newer_or_declared:$q->$p (supersedes)"* ]] && ok "the report names the planted backwards supersedes" ||
    bad "the report names the planted backwards supersedes" "$report"
[[ "$report" == *"acyclic:$z->$x (blocks)"* ]] && ok "the report names the planted blocks cycle" ||
    bad "the report names the planted blocks cycle" "$report"
w show "$p" >/dev/null 2>&1 && ok "reading a graph with violations still works (D4)" || bad "reading a graph with violations still works (D4)"
sqlite3 "$DB" "DELETE FROM edges WHERE (source='$q' AND target='$p') OR (source='$z' AND target='$x');"

echo "=== wv doctor names a dangling edge (wv-477035) ==="
check "a graph without dangling edges passes" "$(doctor_check "dangling edges" | cut -d' ' -f1)" "pass"
sqlite3 "$DB" "INSERT INTO edges(source,target,type,weight,context) VALUES('wv-000ghost','$p','implements',1.0,'{}');"
report=$(doctor_check "dangling edges")
[[ "$report" == "warn 1 edge(s)"*"wv-000ghost->$p (implements)"*"wv unlink"* ]] && ok "the report names the dangling edge and its remedy" ||
    bad "the report names the dangling edge and its remedy" "$report"
sqlite3 "$DB" "DELETE FROM edges WHERE source='wv-000ghost';"

echo "=== no close over an unaccounted open child ==="
close() { w done "$1" --skip-verification --no-warn 2>&1; }
par=$(add "parent with an open child" --metadata='{"type":"epic"}'); open=$(child "open child" "$par")
out=$(close "$par"); rc=$?
if [ "$rc" -ne 0 ] && [ "$(status_of "$par")" != "done" ] && [[ "$out" == *"$open"* ]]; then
    ok "wv done refuses a parent over an open child, and names it"
else
    bad "wv done refuses a parent over an open child, and names it" "rc=$rc status=$(status_of "$par") $(head -2 <<< "$out" | tr '\n' ' ')"
fi
out=$(w update "$par" --status=done 2>&1); rc=$?
[ "$rc" -ne 0 ] && [ "$(status_of "$par")" != "done" ] && ok "a close through wv update is refused too" ||
    bad "a close through wv update is refused too" "rc=$rc $(head -1 <<< "$out")"
w update "$open" --metadata='{"deferred":true}' >/dev/null 2>&1
close "$par" >/dev/null; check "a child parked without a reason still counts as open" "$(status_of "$par")" "todo"
w update "$open" --metadata='{"deferred_reason":"waits for the next release"}' >/dev/null 2>&1
close "$par" >/dev/null; check "a parked child (deferred with a reason) admits the close" "$(status_of "$par")" "done"
par=$(add "parent, child resolved" --metadata='{"type":"epic"}'); open=$(child "fix(y): open child" "$par")
w link "$open" "$gap" --type=resolves >/dev/null 2>&1
close "$par" >/dev/null; check "a child linked by resolves admits the close" "$(status_of "$par")" "done"
par=$(add "parent, child re-parented" --metadata='{"type":"epic"}'); open=$(child "moved child" "$par")
other=$(add "another open parent" --metadata='{"type":"epic"}')
w link "$open" "$other" --type=implements >/dev/null 2>&1
close "$par" >/dev/null; check "a child with another open parent admits the close" "$(status_of "$par")" "done"
par=$(add "parent, child closed" --metadata='{"type":"epic"}'); open=$(child "closed child" "$par")
close "$open" >/dev/null
close "$par" >/dev/null; check "a parent over closed children closes" "$(status_of "$par")" "done"
par=$(add "planted closed parent" --metadata='{"type":"epic"}'); open=$(child "stranded child" "$par")
sqlite3 "$DB" "UPDATE nodes SET status='done' WHERE id='$par';"
report=$(doctor_check "closed parents")
[[ "$report" == "warn "*"$par>$open"* ]] && ok "wv doctor lists a closed parent over an open child" ||
    bad "wv doctor lists a closed parent over an open child" "$report"

echo "=== writers keep the invariants ==="
win=$(add "the older winner"); lose=$(add "the newer loser")
age "$win" "2026-01-01 00:00:00"; age "$lose" "2026-02-01 00:00:00"
w resolve "$win" "$lose" --winner="$win" >/dev/null 2>&1
check "resolve --winner writes loser -> winner" "$(edges "$lose" "$win" supersedes)/$(edges "$win" "$lose" supersedes)" "1/0"
check "the loser records its replacement" "$(sqlite3 "$DB" "SELECT json_extract(metadata,'\$.superseded_by') FROM nodes WHERE id='$lose';")" "$win"
m1=$(add "merge one"); m2=$(add "merge two")
w resolve "$m1" "$m2" --merge >/dev/null 2>&1
merged=$(sqlite3 "$DB" "SELECT target FROM edges WHERE source='$m1' AND type='obsoletes';")
[ -n "$merged" ] && [ "$(edges "$m2" "$merged" obsoletes)" = "1" ] && ok "resolve --merge writes each original -> the merged node" ||
    bad "resolve --merge writes each original -> the merged node" "$(sqlite3 "$DB" "SELECT source||'->'||target FROM edges WHERE type='obsoletes';")"
if w resolve "$m1" "$m1" --defer >/dev/null 2>&1; then
    bad "a node cannot be resolved against itself"
else
    ok "a node cannot be resolved against itself"
fi
w remember "the successor fact" --supersedes="$mem_old" >/dev/null 2>&1
sqlite3 "$DB" "DELETE FROM edges WHERE type='blocks' AND source='$z' AND target='$x';"
check "every edge the writers produced keeps its invariant" "$(doctor_check "edge invariants" | cut -d' ' -f1)" "pass"

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
