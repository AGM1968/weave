#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# Node kind is a typed field (ontology S1, wv-f7dfd3). The authority is
# contracts/node-kinds-v1.json. The kind is stored in metadata.node_kind and
# mirrored to metadata.type for one release; every write path either sets both
# to one writable value or refuses, and a new node always leaves with a kind.
set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
# Fixture rows are inserted with sqlite3, which the run cache cannot see: every
# wv ready here must read the graph, not a listing cached before the insert.
export WV_RUN_CACHE=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WV="$ROOT/scripts/wv"
CONTRACT="$ROOT/contracts/node-kinds-v1.json"
run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }
TMP=$(mktemp -d /tmp/wv-node-kind-XXXXXX)
trap 'rm -rf "$TMP"' EXIT

echo "=== one authority ==="
lib() { bash -c '. "$1/scripts/lib/wv-validate.sh" >/dev/null 2>&1; eval "$2"' _ "$ROOT" "$1"; }
contract=$(jq -r '.kinds | sort | join(" ")' "$CONTRACT")
cli=$(lib 'printf "%s\n" $VALID_NODE_KINDS' | sort | paste -sd' ' -)
check "the CLI kind enum is the contract's" "$cli" "$contract"
contract=$(jq -r '.command_writable | sort | join(" ")' "$CONTRACT")
cli=$(lib 'printf "%s\n" $WRITABLE_NODE_KINDS' | sort | paste -sd' ' -)
check "the kinds a command may write are the contract's" "$cli" "$contract"
check "unknown is not command-writable" "$(jq -r '.command_writable | index("unknown")' "$CONTRACT")" "null"
mcp=$(sed -n '/^const NODE_KIND_SCHEMA_VALUES = \[/,/\] as const;/p' "$ROOT/mcp/src/index.ts" | grep -oE '"[a-z_]+"' | tr -d '"' | sort | paste -sd' ' -)
check "the MCP kind enum is the contract's" "$mcp" "$contract"
cli=$(lib 'jq -nr "$WV_KIND_JQ_DEFS wv_kinds[]"' | sort | paste -sd' ' -)
check "the backfill's kind list is the contract's" "$cli" "$(jq -r '.kinds | sort | join(" ")' "$CONTRACT")"
gh=$(grep -A2 '^NODE_KINDS = frozenset' "$ROOT/scripts/weave_gh/models.py" | grep -oE '"[a-z_]+"' | tr -d '"' | sort | paste -sd' ' -)
check "the weave_gh kind set is the contract's" "$gh" "$(jq -r '.command_writable | sort | join(" ")' "$CONTRACT")"
contract=$(jq -cS '.backfill.text_prefix' "$CONTRACT")
cli=$(lib 'jq -ncS "$WV_KIND_JQ_DEFS wv_kind_prefix_map"')
check "the prefix map is the contract's" "$cli" "$contract"

R="$TMP/repo"; mkdir -p "$R" "$TMP/cfg"
git -C "$R" init -q . && git -C "$R" config user.email t@t && git -C "$R" config user.name t
w() { (cd "$R" && WEAVE_DIR="$R/.weave" WV_HOT_ZONE="$TMP/hot" WV_CONFIG_DIR="$TMP/cfg" "$WV" "$@"); }
DB="$TMP/hot/brain.db"
w init >/dev/null 2>&1
count() { sqlite3 "$DB" "SELECT COUNT(*) FROM nodes;"; }
kind_of() { sqlite3 "$DB" "SELECT COALESCE(json_extract(metadata,'\$.node_kind'),'-') || '/' || COALESCE(type,'-') FROM nodes WHERE id='$1';"; }
add() { w add "$@" --standalone 2>/dev/null | grep -oE 'wv-[a-f0-9]{6}' | sed -n 1p; }

echo "=== wv add stores a kind on every node ==="
check "an epic( prefix creates an epic" "$(kind_of "$(add 'epic(x): a goal')")" "epic/epic"
check "a plan-family prefix creates a plan" "$(kind_of "$(add 'proposal(x): a design')")" "plan/plan"
check "a change-type prefix creates a task" "$(kind_of "$(add 'fix(x): a defect')")" "task/task"
check "finding( creates a task, not a finding (D2)" "$(kind_of "$(add 'finding(x): actionable')")" "task/task"
check "text with no prefix creates a task" "$(kind_of "$(add 'plain words')")" "task/task"
check "a word: prefix counts, in any case" "$(kind_of "$(add 'Epic: colon form')")" "epic/epic"
check "--kind is stored and mirrored" "$(kind_of "$(add 'epic(x): typed otherwise' --kind=decision)")" "decision/decision"
check "metadata type wins over the prefix" "$(kind_of "$(add 'task(x): typed' --metadata='{"type":"feature"}')")" "feature/feature"
check "metadata node_kind is mirrored to type" "$(kind_of "$(add 'something' --metadata='{"node_kind":"plan"}')")" "plan/plan"
before=$(count)
out=$(w add "unknown kind" --standalone --kind=unknown 2>&1); rc=$?
[ "$rc" != 0 ] && [ "$(count)" = "$before" ] && [[ "$out" == *"--kind must be one of"* ]] &&
    ok "--kind=unknown is refused and stores nothing" || bad "--kind=unknown is refused and stores nothing" "rc=$rc $out"
out=$(w add "legacy type" --standalone --metadata='{"type":"bug"}' 2>&1); rc=$?
[ "$rc" != 0 ] && [ "$(count)" = "$before" ] && [[ "$out" == *"node kind must be one of"* ]] &&
    ok "a type outside the enum is refused" || bad "a type outside the enum is refused" "rc=$rc $out"
out=$(w add "disagreeing" --standalone --kind=epic --metadata='{"type":"task"}' 2>&1); rc=$?
[ "$rc" != 0 ] && [ "$(count)" = "$before" ] && ok "--kind disagreeing with metadata type is refused" ||
    bad "--kind disagreeing with metadata type is refused" "rc=$rc $out"
out=$(w add "disagreeing" --standalone --metadata='{"type":"task","node_kind":"epic"}' 2>&1); rc=$?
[ "$rc" != 0 ] && [ "$(count)" = "$before" ] && ok "node_kind and type disagreeing is refused" ||
    bad "node_kind and type disagreeing is refused" "rc=$rc $out"

echo "=== wv update keeps node_kind and type together ==="
id=$(add 'task(x): to retype')
w update "$id" --kind=plan >/dev/null 2>&1
check "--kind sets both" "$(kind_of "$id")" "plan/plan"
w update "$id" --kind epic >/dev/null 2>&1
check "--kind <value> (space form) sets both" "$(kind_of "$id")" "epic/epic"
w update "$id" --metadata='{"type":"feature"}' >/dev/null 2>&1
check "a type patch is mirrored to node_kind" "$(kind_of "$id")" "feature/feature"
w update "$id" --metadata='{"node_kind":"task"}' >/dev/null 2>&1
check "a node_kind patch is mirrored to type" "$(kind_of "$id")" "task/task"
w update "$id" --kind=decision --metadata='{"note":"both"}' >/dev/null 2>&1
check "--kind joins a --metadata patch" "$(kind_of "$id")/$(sqlite3 "$DB" "SELECT json_extract(metadata,'\$.note') FROM nodes WHERE id='$id';")" "decision/decision/both"
w update "$id" --metadata='{"note":"unrelated"}' >/dev/null 2>&1
check "a patch not touching the kind leaves it" "$(kind_of "$id")" "decision/decision"
w update "$id" --text='epic(y): new text' >/dev/null 2>&1
check "new text does not re-derive the kind" "$(kind_of "$id")" "decision/decision"
for bad_args in "--kind=unknown" "--kind=bug" "--metadata={\"type\":null}" "--metadata={\"node_kind\":\"epic\",\"type\":\"task\"}" \
    "--remove-key=type" "--remove-key=node_kind"; do
    pre=$(kind_of "$id")
    out=$(w update "$id" "$bad_args" 2>&1); rc=$?
    [ "$rc" != 0 ] && [ "$(kind_of "$id")" = "$pre" ] && ok "wv update $bad_args is refused and changes nothing" ||
        bad "wv update $bad_args is refused and changes nothing" "rc=$rc $(kind_of "$id") $out"
done
pre=$(kind_of "$id")
out=$(w update "$id" --kind=epic --metadata='{"type":"task"}' 2>&1); rc=$?
[ "$rc" != 0 ] && [ "$(kind_of "$id")" = "$pre" ] && ok "--kind disagreeing with --metadata is refused" ||
    bad "--kind disagreeing with --metadata is refused" "rc=$rc $out"
bulk=$(add 'typed for bulk' --metadata='{"type":"task"}')
pre=$(kind_of "$bulk")
printf '[{"id":"%s","remove-keys":["type"]}]' "$bulk" > "$TMP/bulk.json"
out=$(w bulk-update < "$TMP/bulk.json" 2>&1); rc=$?
[ "$pre" != "-/-" ] && [ "$(kind_of "$bulk")" = "$pre" ] && ok "bulk-update cannot remove the kind" ||
    bad "bulk-update cannot remove the kind" "pre=$pre now=$(kind_of "$bulk") $out"

echo "=== the other write paths ==="
w touch "$id" --metadata='{"type":"plan"}' >/dev/null 2>&1
check "wv touch mirrors a type patch" "$(kind_of "$id")" "plan/plan"
pre=$(kind_of "$id")
out=$(w touch "$id" --metadata='{"type":"bug"}' 2>&1); rc=$?
[ "$rc" != 0 ] && [ "$(kind_of "$id")" = "$pre" ] && ok "wv touch refuses a type outside the enum" ||
    bad "wv touch refuses a type outside the enum" "rc=$rc $out"
mem=$(w remember "a fact worth keeping" --kind=feedback 2>/dev/null | grep -oE 'wv-[a-f0-9]{6}' | sed -n 1p)
check "wv remember stores node kind memory and keeps the memory category" \
    "$(kind_of "$mem")/$(sqlite3 "$DB" "SELECT json_extract(metadata,'\$.kind') FROM nodes WHERE id='$mem';")" "memory/memory/feedback"
q=$(w quick "epic(z): quick one" 2>&1 | grep -oE 'wv-[a-f0-9]{6}' | sed -n 1p)
check "wv quick stores a kind" "$(kind_of "$q")" "epic/epic"
m1=$(add 'claim one'); m2=$(add 'claim two')
w link "$m1" "$m2" --type=contradicts >/dev/null 2>&1
w resolve "$m1" "$m2" --merge >/dev/null 2>&1
merged=$(sqlite3 "$DB" "SELECT id FROM nodes WHERE text LIKE 'Merged:%' LIMIT 1;")
[ -n "$merged" ] && [ "$(sqlite3 "$DB" "SELECT json_valid(metadata) FROM nodes WHERE id='$merged';")" = 1 ] &&
    [ "$(kind_of "$merged")" = "task/task" ] && ok "wv resolve --merge creates a task with valid metadata" ||
    bad "wv resolve --merge creates a task with valid metadata" "merged=$merged $(sqlite3 "$DB" "SELECT metadata FROM nodes WHERE id='$merged';")"

echo "=== behaviour follows the kind, not the text ==="
# A fresh graph, so no epic from the cases above is open.
R2="$TMP/repo2"; mkdir -p "$R2"
git -C "$R2" init -q . && git -C "$R2" config user.email t@t && git -C "$R2" config user.name t
w2() { (cd "$R2" && WEAVE_DIR="$R2/.weave" WV_HOT_ZONE="$TMP/hot2" WV_CONFIG_DIR="$TMP/cfg" "$WV" "$@"); }
w2 init >/dev/null 2>&1
id2() { grep -oE 'wv-[a-f0-9]{6}' | sed -n 1p; }
not_epic=$(w2 add "epic(x): reads like an epic" --kind=task --standalone 2>/dev/null | id2)
out=$(w2 add "a parentless task" 2>&1); rc=$?
[ "$rc" = 0 ] && ok "an epic( node typed task does not arm the orphan guard" ||
    bad "an epic( node typed task does not arm the orphan guard" "rc=$rc $out"
real_epic=$(w2 add "task(x): reads like a task" --kind=epic 2>/dev/null | id2)
out=$(w2 add "another parentless task" 2>&1); rc=$?
[ "$rc" != 0 ] && [[ "$out" == *"$real_epic"* ]] && ok "a task( node typed epic arms the orphan guard" ||
    bad "a task( node typed epic arms the orphan guard" "rc=$rc $out"
listed=$(w2 add "finding(x): actionable" --standalone 2>/dev/null | id2)
hidden=$(w2 add "plain words" --kind=finding --standalone 2>/dev/null | id2)
ready2=$(w2 ready --all --json 2>/dev/null | jq -r '.[].id' | paste -sd' ' -)
[[ " $ready2 " == *" $listed "* ]] && [[ " $ready2 " != *" $hidden "* ]] &&
    ok "wv ready lists a finding( task and hides a finding-kind node with plain text" ||
    bad "wv ready lists a finding( task and hides a finding-kind node with plain text" "ready=[$ready2] listed=$listed hidden=$hidden"
# A row whose type an older wv left behind: node_kind decides, not the mirror.
sqlite3 "$TMP/hot2/brain.db" "INSERT INTO nodes (id, text, status, metadata) VALUES
    ('wv-0000c1', 'plain words', 'todo', '{\"node_kind\":\"finding\",\"type\":\"task\"}'),
    ('wv-0000c2', 'plain words', 'todo', '{\"node_kind\":\"task\",\"type\":\"memory\"}');"
ready2=$(w2 ready --all --json 2>/dev/null | jq -r '.[].id' | paste -sd' ' -)
[[ " $ready2 " != *" wv-0000c1 "* ]] && [[ " $ready2 " == *" wv-0000c2 "* ]] &&
    ok "wv ready reads node_kind over a disagreeing type" || bad "wv ready reads node_kind over a disagreeing type" "ready=[$ready2]"
check "wv query type=finding reads node_kind" "$(w2 query type=finding --format=json 2>/dev/null | jq -r '[.[].id] | sort | join(" ")')" "$(printf '%s\n' "$hidden" wv-0000c1 | sort | paste -sd' ' -)"
check "wv query type=epic selects by kind" "$(w2 query type=epic --format=json 2>/dev/null | jq -r '[.[].id] | join(" ")')" "$real_epic"
check "wv list --type=epic selects by kind" "$(w2 list --all --type=epic --json 2>/dev/null | jq -r '[.[].id] | join(" ")')" "$real_epic"

echo "=== wv kind backfill ==="
# Legacy rows, as an older wv left them: no node_kind, sometimes a type.
legacy() { sqlite3 "$DB" "INSERT INTO nodes (id, text, status, metadata, updated_at) VALUES ('$1', '$2', '$3', '$4', '2026-01-01 00:00:00');"; }
legacy wv-0000a1 'epic(x): legacy epic' todo '{}'
legacy wv-0000a2 'finding(x): actionable work' todo '{}'
legacy wv-0000a3 'no prefix at all' 'done' '{}'
legacy wv-0000a4 'typed bug' 'done' '{"type":"bug"}'
legacy wv-0000a5 'a memory' 'done' '{"type":"memory","kind":"project","mem_status":"active"}'
legacy wv-0000a6 'decide: which way' todo '{"priority":2}'
legacy wv-0000a7 'retyped by an older wv' 'done' '{"node_kind":"epic","type":"task"}'
ready_ids() { w ready --all --json 2>/dev/null | jq -r '.[].id' | sort | paste -sd' ' -; }
ready_before=$(ready_ids)
out=$(w kind backfill --json 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(kind_of wv-0000a1)" = "-/-" ] && ok "a dry run writes nothing" || bad "a dry run writes nothing" "rc=$rc $(kind_of wv-0000a1)"
check "the dry run counts the writes" "$(jq -r '.to_write' <<< "$out")" "7"
check "the dry run reports node_kind and type disagreeing" "$(jq -r '[.mirror_mismatches[] | "\(.id):\(.type)->\(.kind)"] | join(" ")' <<< "$out")" "wv-0000a7:task->epic"
check "the dry run reports a type outside the kinds" "$(jq -r '[.type_outside_kinds[].id] | join(" ")' <<< "$out")" "wv-0000a4"
check "the dry run reports a prefix naming another kind" "$(jq -r '[.disagreements[] | select(.id | startswith("wv-0000")) | "\(.id):\(.prefix)->\(.kind)"] | join(" ")' <<< "$out")" "wv-0000a2:finding->task"
check "the dry run reports wv ready unchanged" "$(jq -r '(.ready.added + .ready.removed) | length' <<< "$out")" "0"
out=$(w kind backfill --apply 2>&1); rc=$?
[ "$rc" = 0 ] && [[ "$out" == *"applied"* ]] && ok "--apply writes" || bad "--apply writes" "rc=$rc $out"
check "an epic( prefix backfills to epic" "$(kind_of wv-0000a1)" "epic/epic"
check "finding( backfills to task (D2)" "$(kind_of wv-0000a2)" "task/task"
check "no evidence backfills to unknown" "$(kind_of wv-0000a3)" "unknown/unknown"
check "a type outside the kinds backfills to task" "$(kind_of wv-0000a4)" "task/task"
check "metadata type wins and the memory category stays" \
    "$(kind_of wv-0000a5)/$(sqlite3 "$DB" "SELECT json_extract(metadata,'\$.kind') FROM nodes WHERE id='wv-0000a5';")" "memory/memory/project"
check "a decide: prefix backfills to decision and keeps other keys" \
    "$(kind_of wv-0000a6)/$(sqlite3 "$DB" "SELECT json_extract(metadata,'\$.priority') FROM nodes WHERE id='wv-0000a6';")" "decision/decision/2"
check "node_kind wins over a disagreeing type" "$(kind_of wv-0000a7)" "epic/epic"
check "the backfill leaves updated_at alone" "$(sqlite3 "$DB" "SELECT updated_at FROM nodes WHERE id='wv-0000a1';")" "2026-01-01 00:00:00"
check "wv ready lists the same nodes after the backfill" "$(ready_ids)" "$ready_before"
check "every node now carries a kind" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM nodes WHERE json_extract(metadata,'\$.node_kind') IS NULL OR json_extract(metadata,'\$.node_kind') IS NOT type;")" "0"
# A write publishes its delta; state.sql is rewritten only by sync, a
# checkpoint or a load (wv-8595fb), so the delta is what persists it.
grep -rqE 'wv-0000a1.*node_kind|node_kind.*wv-0000a1' "$R/.weave/deltas" 2>/dev/null && ok "the backfill is persisted to a published delta" ||
    bad "the backfill is persisted to a published delta"
check "a second backfill has nothing to write" "$(w kind backfill --json 2>/dev/null | jq -r '.to_write')" "0"
# A mapping that would change wv ready is refused before anything is written:
# a node_kind outside the kinds, over a memory type, is listed by ready today
# and would be hidden once the backfill types it memory.
legacy wv-0000b1 'odd row' todo '{"node_kind":"bogus","type":"memory"}'
legacy wv-0000b2 'epic(y): also untyped' todo '{}'
out=$(w kind backfill --apply 2>&1); rc=$?
[ "$rc" != 0 ] && [[ "$out" == *"would change wv ready"* ]] && [[ "$out" == *"- wv-0000b1"* ]] &&
    ok "--apply refuses a backfill that would change wv ready" || bad "--apply refuses a backfill that would change wv ready" "rc=$rc $out"
check "a refused backfill writes nothing" "$(kind_of wv-0000b1) $(kind_of wv-0000b2)" "bogus/memory -/-"

echo ""
echo "Results: $pass/$run passed"
[ "$pass" = "$run" ]
