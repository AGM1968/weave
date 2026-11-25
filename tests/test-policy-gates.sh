#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# Command gates leave evidence (wv-9de5c5). A denied call, an override, an
# advisory and a refusal that is not a policy decision each write a distinct,
# schema-valid journal event bound to the call that made it, so none of them
# is indistinguishable from a call no rule examined.
#
# Static coverage of every declared gate is scripts/weave_policy.py's job
# (tests/test-policy-contract.sh). This suite drives a representative set end to
# end; the per-rule allow/deny/advisory/bypass matrix belongs to policy totality.
set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WV="$ROOT/scripts/wv"
run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
TEST_DIR=$(mktemp -d /tmp/wv-policy-gates-XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT
export WEAVE_DIR="$TEST_DIR/.weave" WV_HOT_ZONE="$TEST_DIR/hot" WV_CONFIG_DIR="$TEST_DIR/config"
export WV_REQUIRE_QUALITY=0
mkdir -p "$WV_CONFIG_DIR"
cd "$TEST_DIR" || exit 1
git init -q . && git config user.email t@t && git config user.name t && git config commit.gpgsign false
"$WV" init >/dev/null 2>&1
# POLICY_GATES_JOURNAL keeps the journal past this suite's exit, so the policy
# totality check (tests/test-policy-totality.sh) can read what it exercised.
JOURNAL="${POLICY_GATES_JOURNAL:-$TEST_DIR/attempts.jsonl}"
: > "$JOURNAL"

# expect <label> <operation> <event> <rule-or-category> <decision|-> <bypass|->
# The last event of that kind, for that operation and that rule or category,
# must match exactly, and must be bound to a call_id this journal also recorded
# as call_started. Keyed on the rule: since wv-15422b every applicable gate
# records its allow, so the last event of a kind is usually another rule's.
expect() {
    local label="$1" op="$2" event="$3" name="$4" decision="$5" bypass="$6" got
    got=$(jq -r --arg op "$op" --arg ev "$event" --arg name "$name" '
        select(.operation==$op and .event==$ev and (.rule // .category)==$name)
        | [(.rule // .category), (.decision // "-"), (.bypass // "-"), .call_id] | @tsv' "$JOURNAL" | tail -1)
    local want_prefix
    want_prefix=$(printf '%s\t%s\t%s' "$name" "$decision" "$bypass")
    case "$got" in
        "$want_prefix"$'\t'*)
            local call="${got##*$'\t'}"
            if jq -e --arg c "$call" 'select(.event=="call_started" and .call_id==$c)' "$JOURNAL" >/dev/null; then
                ok "$label"
            else
                bad "$label" "verdict call_id $call has no call_started"
            fi ;;
        *) bad "$label" "expected [$want_prefix], got [$got]" ;;
    esac
}
j() { WV_ATTEMPT_JOURNAL="$JOURNAL" "$WV" "$@" >/dev/null 2>&1; }

echo "=== command gates leave evidence ==="
epic=$("$WV" add "gates epic" --metadata='{"type":"epic"}' --force 2>/dev/null | tail -1)
j add "orphaned task text"
expect "an orphan add is denied by orphan_prevention" add policy_verdict orphan_prevention deny -
j add "forced orphan text" --force
expect "a forced orphan records the bypass, not silence" add policy_verdict orphan_prevention allow --force
j add "standalone orphan text" --standalone
expect "--standalone is named as the bypass it is" add policy_verdict orphan_prevention allow --standalone
child=$("$WV" add "gates child alpha" --parent="$epic" 2>/dev/null | tail -1)
# With an epic open, orphan prevention refuses a parentless add before dedup
# runs; quick applies dedup with no bypass, so it reaches the gate directly.
j quick "gates child alpha"
expect "a duplicate is denied" quick policy_verdict add_duplicate_check deny -
j block "$child" --by="$child"
expect "a self-block is denied" block policy_verdict block_graph_acyclic deny -
sibling=$("$WV" add "gates child beta" --parent="$epic" 2>/dev/null | tail -1)
j block "$sibling" --by="$child"
expect "a block that closes no cycle is allowed" block policy_verdict block_graph_acyclic allow -
j delete "$epic"
expect "deleting a parent is denied" delete policy_verdict delete_preserves_children deny -
j work wv-ffffff
expect "claiming an unknown node is input validation, not a denial" work non_policy_refusal input_validation - -
"$WV" update "$child" --metadata='{"claimed_by":"another-agent"}' >/dev/null 2>&1
j work "$child"
expect "a lost claim is an expected conflict, not a denial" work non_policy_refusal expected_conflict - -
j work "$child" --force
expect "a takeover records the override" work policy_verdict claim_ownership allow --force
# Session identity (wv-99978b). WV_SESSION_ID pins a session whatever runs the
# suite; set but empty, it is a declared session that cannot be verified.
sess=$("$WV" add "session claims" --force 2>/dev/null | tail -1)
WV_SESSION_IDENTITY=1 WV_SESSION_ID='' j work "$sess"
expect "a claim under an unverifiable session is denied" work policy_verdict claim_ownership deny -
"$WV" update "$sess" --metadata='{"claimed_by":"another-agent"}' >/dev/null 2>&1
WV_SESSION_IDENTITY=1 WV_SESSION_ID=gates1 j work "$sess" --continue
expect "--continue on another actor's claim is denied" work policy_verdict claim_ownership deny --continue
coarse=$(env -u WV_AGENT_ID bash -c "source '$ROOT/scripts/lib/wv-resolve-runtime.sh'; resolve_agent_coarse_id")
"$WV" update "$sess" --metadata="{\"claimed_by\":\"$coarse\"}" >/dev/null 2>&1
WV_SESSION_IDENTITY=1 WV_SESSION_ID=gates1 j work "$sess" --continue
expect "--continue of the actor's own coarse claim records the override" work policy_verdict claim_ownership allow --continue
j "done" "$child" --skip-verification
expect "a close without a learning names its bypass" "done" policy_verdict close_requires_learning allow --skip-verification
j work "$child"
expect "claiming a done node without --reopen is denied" work policy_verdict reopen_requires_explicit_intent deny -
j work "$child" --reopen
expect "an explicit reopen is recorded" work policy_verdict reopen_requires_explicit_intent allow --reopen
j "done" "$child" --skip-verification
j "done" "$child" --skip-verification
expect "closing a closed node is an expected conflict" "done" non_policy_refusal expected_conflict - -

# Advisory is its own outcome: a close whose learning overlaps an earlier one
# proceeds, and records advisory rather than allow.
first=$("$WV" add "overlap first node" --parent="$epic" 2>/dev/null | tail -1)
"$WV" work "$first" >/dev/null 2>&1
"$WV" "done" "$first" --learning="pattern: quartz lanterns guide the harbour ferry at dusk" >/dev/null 2>&1
second=$("$WV" add "overlap second node" --parent="$epic" 2>/dev/null | tail -1)
"$WV" work "$second" >/dev/null 2>&1
j "done" "$second" --learning="pattern: quartz lanterns guide the harbour ferry at dusk"
expect "an overlapping learning is advisory, distinct from allow" "done" policy_verdict learning_overlap_advisory advisory -

echo "=== SQLite-owned close rules leave the decision's own receipt ==="
# wv-d7cd88: the close transaction evaluates the clauses and records the receipt
# it decided on. Nothing is re-derived after the fact, so loosening every policy
# input between the decision and the report cannot change the recorded verdict.
DB="$WV_HOT_ZONE/brain.db"
sq() { sqlite3 -cmd ".timeout 5000" "$DB" "$1"; }
# close_clause <label> <rule> <jq-clause-check> <setup-sql-with-@ID@> [done-env...]
close_clause() {
    local label="$1" rule="$2" check="$3" setup="$4" node out
    shift 4
    node=$("$WV" add "sqlite clause $rule" --parent="$epic" 2>/dev/null | tail -1)
    "$WV" work "$node" >/dev/null 2>&1
    sq "${setup//@ID@/$node}"
    out=$(env WV_ATTEMPT_JOURNAL="$JOURNAL" "$@" "$WV" "done" "$node" --skip-verification 2>&1)
    expect "$label" "done" policy_verdict "$rule" deny -
    local clause
    clause=$(jq -c --arg r "$rule" 'select(.event=="policy_verdict" and .rule==$r) | .clause' "$JOURNAL" | tail -1)
    if jq -e "$check" <<< "$clause" >/dev/null; then
        ok "$rule records the values it decided on"
    else
        bad "$rule records the values it decided on" "$clause"
    fi
    [ "$(sq "SELECT status FROM nodes WHERE id='$node';")" = "active" ] &&
        ok "$rule leaves the node active" || bad "$rule leaves the node active"
    case "$out" in *'"threshold":'*) ok "$rule still prints the human payload" ;;
        *) bad "$rule still prints the human payload" "$out" ;; esac
    LAST_NODE="$node"
}
close_clause "a complex file denies the close" close_complexity_ceiling \
    '.threshold=="mccabe_max_py" and .limit==25 and .actual==30 and .path=="src/complex.py"' \
    "INSERT OR REPLACE INTO file_metrics(path,mccabe_max,language) VALUES('src/complex.py',30,'py');
     INSERT OR REPLACE INTO node_files(node_id,path) VALUES('@ID@','src/complex.py');"
close_clause "a deteriorating trend denies the close" close_trend_not_deteriorating \
    '.threshold=="trend_deteriorating" and .direction=="deteriorating" and .path=="src/trend.py"' \
    "UPDATE policy_thresholds SET value=1 WHERE key='trend_deteriorating';
     INSERT OR REPLACE INTO file_trend(path,direction) VALUES('src/trend.py','deteriorating');
     INSERT OR REPLACE INTO node_files(node_id,path) VALUES('@ID@','src/trend.py');"
sq "UPDATE policy_thresholds SET value=0 WHERE key='trend_deteriorating';"
close_clause "a red test denies the close" close_tests_not_red \
    '.threshold=="test_gate" and .state=="red" and .limit==2 and .path=="src/red.py"' \
    "UPDATE policy_thresholds SET value=2 WHERE key='test_gate';
     INSERT OR REPLACE INTO file_test_status(path,state) VALUES('src/red.py','red');
     INSERT OR REPLACE INTO node_files(node_id,path) VALUES('@ID@','src/red.py');"
sq "UPDATE policy_thresholds SET value=0 WHERE key='test_gate';"

# The race: every threshold, the trend and test gates and a catch-all exemption
# move between the decision and the report. A reporter that re-queried would
# now find no clause at all, or the wrong one.
close_clause "policy moving after the decision does not rewrite it" close_complexity_ceiling \
    '.threshold=="mccabe_max_py" and .limit==25 and .actual==30' \
    "INSERT OR REPLACE INTO file_metrics(path,mccabe_max,language) VALUES('src/raced.py',30,'py');
     INSERT OR REPLACE INTO node_files(node_id,path) VALUES('@ID@','src/raced.py');" \
    WV_TEST_MODE=1 WV_TEST_POLICY_RACE=1
[ "$(sq "SELECT value FROM policy_thresholds WHERE key='mccabe_max_py';")" = "1000000000.0" ] &&
    ok "the race seam really moved policy before the report" ||
    bad "the race seam really moved policy before the report"
sq "DELETE FROM quality_exempt WHERE reason='WV_TEST_POLICY_RACE';
    UPDATE policy_thresholds SET value=25 WHERE key='mccabe_max_py';
    UPDATE policy_thresholds SET value=15 WHERE key IN ('mccabe_max','mccabe_max_ts');
    UPDATE policy_thresholds SET value=100 WHERE key='mccabe_max_sh';"

# The seam's own gating (tests/wv-test-hooks.registry): inert without the master
# opt-in, and an unrecognised value refuses the close instead of being ignored.
n=$("$WV" add "race seam gating probe" --parent="$epic" 2>/dev/null | tail -1)
"$WV" work "$n" >/dev/null 2>&1
bogus=$(WV_TEST_MODE=1 WV_TEST_POLICY_RACE=yes "$WV" "done" "$n" --skip-verification 2>&1)
if [ "$(sq "SELECT status FROM nodes WHERE id='$n';")" = "active" ] && [[ "$bogus" == *"not a recognised value"* ]]; then
    ok "an unrecognised WV_TEST_POLICY_RACE value refuses the close"
else
    bad "an unrecognised WV_TEST_POLICY_RACE value refuses the close" "$bogus"
fi
ungated=$(env -u WV_TEST_MODE WV_TEST_POLICY_RACE=1 "$WV" "done" "$n" --skip-verification 2>&1)
if [ "$(sq "SELECT status FROM nodes WHERE id='$n';")" = "done" ] && [[ "$ungated" == *"ignoring it"* ]] &&
    [ "$(sq "SELECT value FROM policy_thresholds WHERE key='mccabe_max_py';")" = "25.0" ]; then
    ok "without WV_TEST_MODE=1 the seam is ignored with a warning and moves nothing"
else
    bad "without WV_TEST_MODE=1 the seam is ignored with a warning and moves nothing" "$ungated"
fi

# The trigger is a backstop that can only agree. For each clause, a raw UPDATE
# that skips the receipt must be refused by the trigger for the same rule.
declare -A abort_for=(
    [close_complexity_ceiling]="mccabe_max threshold exceeded"
    [completion_scope_integrity]="invalid completion scope"
)
raw=$(sq "UPDATE nodes SET status='done' WHERE id='$LAST_NODE';" 2>&1)
case "$raw" in *"${abort_for[close_complexity_ceiling]}"*) ok "the trigger refuses what the receipt denied, for the same clause" ;;
    *) bad "the trigger refuses what the receipt denied, for the same clause" "$raw" ;; esac

# Completion-scope reasons are only reachable by a scope that changed under the
# close, so the receipt is driven directly with the proposed metadata.
receipt_for() {
    local proposed="$1"
    sq "$(bash -c 'source "$1/scripts/lib/wv-db.sh" >/dev/null 2>&1; _policy_close_receipt_sql "$2" "$3"' _ "$ROOT" "$LAST_NODE" "$proposed");"
}
got=$(receipt_for "json_set(metadata, '\$.completion_scope', json('{\"files\":[\"src/never.py\"],\"attempt_id\":\"a1\"}'))")
[ "$(jq -r '.rule + "/" + .clause.reason' <<< "$got")" = "completion_scope_integrity/unattributed_file" ] &&
    ok "a scope naming a file the node never touched is a policy deny" || bad "unattributed scope receipt" "$got"
got=$(receipt_for "json_set(metadata, '\$.completion_scope', json('{\"files\":[],\"attempt_id\":\"a1\"}'))")
[ "$(jq -r '.clause.reason' <<< "$got")" = "malformed_scope" ] &&
    ok "an empty scope is classified as malformed, i.e. input validation" || bad "malformed scope receipt" "$got"
raw=$(sq "UPDATE nodes SET status='done', metadata=json_set(metadata,'\$.completion_scope',json('{\"files\":[],\"attempt_id\":\"a1\"}')) WHERE id='$LAST_NODE';" 2>&1)
case "$raw" in *"${abort_for[completion_scope_integrity]}"*) ok "the trigger refuses the malformed scope the receipt denied" ;;
    *) bad "the trigger refuses the malformed scope the receipt denied" "$raw" ;; esac

# A trigger stricter than the receipt is a disagreement, not a decision: it is
# recorded as infrastructure failure and the node stays active. (A separately
# named trigger, because every db_ensure re-applies nodes_policy_check.)
sq "DELETE FROM file_metrics WHERE path='src/raced.py';
    CREATE TRIGGER test_disagreeing_backstop BEFORE UPDATE OF status ON nodes
    WHEN NEW.status='done' AND OLD.status='active'
    BEGIN SELECT RAISE(ABORT, 'GraphPolicyViolation: disagreeing backstop'); END;"
j "done" "$LAST_NODE" --skip-verification
expect "a trigger refusing a close the receipt allowed is infrastructure failure" "done" non_policy_refusal infrastructure_failure - -
if [ "$(sq "SELECT status FROM nodes WHERE id='$LAST_NODE';")" = "active" ]; then
    ok "the disagreeing close did not commit"
else
    bad "the disagreeing close did not commit"
fi
sq "DROP TRIGGER test_disagreeing_backstop;"
if [ "$(grep -c 'CREATE TRIGGER.*nodes_policy_check' "$ROOT/scripts/lib/wv-db.sh")" = "1" ]; then
    ok "the trigger has exactly one definition, the one the receipt shares"
else
    bad "the trigger has exactly one definition, the one the receipt shares"
fi

echo "=== every close path is judged by the same receipt ==="
# wv-957fc8: update, bulk-update, quick and resolve used to write status='done'
# with a bare UPDATE, so the trigger was the only judge and its refusal left
# nothing but error text. Each now closes through the receipt transaction.
complex_node() {  # complex_node <text> -> an active node touching a file over the ceiling
    local n path="src/$RANDOM$RANDOM.py"
    n=$("$WV" add "$1" --parent="$epic" 2>/dev/null | tail -1)
    "$WV" work "$n" >/dev/null 2>&1
    sq "INSERT OR REPLACE INTO file_metrics(path,mccabe_max,language) VALUES('$path',40,'py');
        INSERT OR REPLACE INTO node_files(node_id,path) VALUES('$n','$path');"
    echo "$n"
}
refused_close() {  # refused_close <label> <operation> <node>
    expect "$1" "$2" policy_verdict close_complexity_ceiling deny -
    if [ "$(sq "SELECT status FROM nodes WHERE id='$3';")" = "active" ]; then
        ok "$2 left the refused node active"
    else
        bad "$2 left the refused node active"
    fi
}
n=$(complex_node "update close probe")
j update "$n" --status=done
refused_close "wv update --status=done is judged by the receipt" update "$n"
n=$(complex_node "bulk close probe")
echo "[{\"id\":\"$n\",\"status\":\"done\"}]" > "$TEST_DIR/bulk.json"
WV_ATTEMPT_JOURNAL="$JOURNAL" "$WV" bulk-update < "$TEST_DIR/bulk.json" >/dev/null 2>&1
refused_close "wv bulk-update is judged by the receipt" bulk-update "$n"
loser=$(complex_node "resolve loser probe")
winner=$("$WV" add "resolve winner probe" --parent="$epic" 2>/dev/null | tail -1)
sq "INSERT INTO edges(source,target,type,weight,created_at) VALUES('$winner','$loser','contradicts',1.0,CURRENT_TIMESTAMP);"
j resolve "$winner" "$loser" --winner="$winner"
refused_close "wv resolve is judged by the receipt" resolve "$loser"
[ "$(sq "SELECT COUNT(*) FROM edges WHERE type='contradicts' AND source='$winner' AND target='$loser';")" = "1" ] &&
    ok "a refused resolve leaves the contradiction in place" ||
    bad "a refused resolve leaves the contradiction in place"
# quick creates and closes in one call, and without the Weave git hooks it
# attributes no files, so no clause can deny it here. A backstop stricter than
# the receipt proves the route instead: a bare UPDATE would fail with only error
# text, while the receipt transaction records the disagreement.
sq "CREATE TRIGGER test_quick_backstop BEFORE UPDATE OF status ON nodes
    WHEN NEW.status='done' AND OLD.status='active' AND NEW.text='quick close probe'
    BEGIN SELECT RAISE(ABORT, 'GraphPolicyViolation: quick backstop'); END;"
j quick "quick close probe"
expect "wv quick's close runs in the receipt transaction" quick non_policy_refusal infrastructure_failure - -
[ "$(sq "SELECT status FROM nodes WHERE text='quick close probe';")" = "active" ] &&
    ok "quick left the refused node active" || bad "quick left the refused node active"
sq "DROP TRIGGER test_quick_backstop;"
# The receipt judges only active->done, as the trigger's WHEN does: a todo
# node closed directly was never gated and must not start being denied.
t=$("$WV" add "todo close probe" --parent="$epic" 2>/dev/null | tail -1)
sq "INSERT OR REPLACE INTO node_files(node_id,path) VALUES('$t','src/complex.py');"
j "done" "$t" --skip-verification
[ "$(sq "SELECT status FROM nodes WHERE id='$t';")" = "done" ] &&
    ok "a todo node closes without the active-close gate, as the trigger allows" ||
    bad "a todo node closes without the active-close gate, as the trigger allows"

echo "=== a close through quality_exempt records its bypass ==="
# wv-ef00f7: a breach on an exempt path used to pass silently, so an exempted
# close was indistinguishable from one no clause examined. It now records the
# rule's allow with bypass=quality_exempt:<pattern>, like a command-gate override.
printf '\n[exempt]\nsrc/exempt/\n' >> "$WEAVE_DIR/quality.conf"
# The next close resyncs the changed quality.conf, which also drops metrics
# already stored under the exempt path, so it runs before any breach is seeded.
n=$("$WV" add "exempt config load" --parent="$epic" 2>/dev/null | tail -1)
"$WV" work "$n" >/dev/null 2>&1; "$WV" "done" "$n" --skip-verification >/dev/null 2>&1
[ "$(sq "SELECT COUNT(*) FROM quality_exempt WHERE path_pattern='src/exempt/';")" = "1" ] &&
    ok "the exempt pattern is loaded" || bad "the exempt pattern is loaded"
# rule_event <operation> <rule> -> "decision bypass path call_id" of the last such verdict
rule_event() {
    jq -r --arg op "$1" --arg r "$2" 'select(.operation==$op and .event=="policy_verdict" and .rule==$r)
        | [.decision, (.bypass // "-"), (.clause.path // "-"), .call_id] | join(" ")' "$JOURNAL" | tail -1
}
exempt_node() {  # exempt_node <text> <setup-sql-with-@ID@> -> an active node
    local n
    n=$("$WV" add "$1" --parent="$epic" 2>/dev/null | tail -1)
    "$WV" work "$n" >/dev/null 2>&1
    sq "${2//@ID@/$n}"
    echo "$n"
}
n=$(exempt_node "exempt complexity probe" \
    "INSERT OR REPLACE INTO file_metrics(path,mccabe_max,language) VALUES('src/exempt/big.py',40,'py');
     INSERT OR REPLACE INTO node_files(node_id,path) VALUES('@ID@','src/exempt/big.py');")
j "done" "$n" --skip-verification
[ "$(sq "SELECT status FROM nodes WHERE id='$n';")" = "done" ] &&
    ok "an exempt-only breach still closes" || bad "an exempt-only breach still closes"
got=$(rule_event "done" close_complexity_ceiling)
[ "${got% *}" = "allow quality_exempt:src/exempt/ src/exempt/big.py" ] &&
    ok "an exempt-only breach records allow naming the exempt pattern" ||
    bad "an exempt-only breach records allow naming the exempt pattern" "$got"
clause=$(jq -c 'select(.event=="policy_verdict" and .rule=="close_complexity_ceiling" and .decision=="allow") | .clause' "$JOURNAL" | tail -1)
jq -e '.threshold=="mccabe_max_py" and .limit==25 and .actual==40' <<< "$clause" >/dev/null &&
    ok "the bypass records the values the clause would have denied on" ||
    bad "the bypass records the values the clause would have denied on" "$clause"
# A non-exempt breach alongside an exempt one denies with the same receipt, and
# records no allow: the close did not happen.
n=$(exempt_node "mixed exempt probe" \
    "INSERT OR REPLACE INTO file_metrics(path,mccabe_max,language) VALUES('src/exempt/big.py',40,'py'),('src/plain.py',40,'py');
     INSERT OR REPLACE INTO node_files(node_id,path) VALUES('@ID@','src/exempt/big.py'),('@ID@','src/plain.py');")
j "done" "$n" --skip-verification
got=$(rule_event "done" close_complexity_ceiling)
[ "${got% *}" = "deny - src/plain.py" ] &&
    ok "a non-exempt breach still denies with the same receipt" ||
    bad "a non-exempt breach still denies with the same receipt" "$got"
call="${got##* }"
if jq -e --arg c "$call" 'select(.call_id==$c and .decision=="allow" and (.rule // "" | test("^close_(complexity|trend|tests)")))' "$JOURNAL" >/dev/null; then
    bad "a denied close records no exempt allow"
else
    ok "a denied close records no exempt allow"
fi
[ "$(sq "SELECT status FROM nodes WHERE id='$n';")" = "active" ] &&
    ok "the mixed node stays active" || bad "the mixed node stays active"
# Every clause and every close path: a trend breach on an exempt path closed by
# wv update records under update.
sq "UPDATE policy_thresholds SET value=1 WHERE key='trend_deteriorating';"
n=$(exempt_node "exempt trend probe" \
    "INSERT OR REPLACE INTO file_trend(path,direction) VALUES('src/exempt/t.py','deteriorating');
     INSERT OR REPLACE INTO node_files(node_id,path) VALUES('@ID@','src/exempt/t.py');")
j update "$n" --status=done
got=$(rule_event update close_trend_not_deteriorating)
[ "${got% *}" = "allow quality_exempt:src/exempt/ src/exempt/t.py" ] &&
    ok "an exempt trend breach closed by update records its bypass" ||
    bad "an exempt trend breach closed by update records its bypass" "$got"
sq "UPDATE policy_thresholds SET value=0 WHERE key='trend_deteriorating';"
# A close with no breach at all records no close-rule verdict: allow means an
# exemption was used, not that a clause looked.
n=$(exempt_node "clean close probe" "SELECT 1;")
j "done" "$n" --skip-verification
call=$(jq -r 'select(.operation=="done" and .event=="call_started") | .call_id' "$JOURNAL" | tail -1)
if jq -e --arg c "$call" 'select(.call_id==$c and .event=="policy_verdict" and (.rule // "" | test("^close_(complexity|trend|tests)")))' "$JOURNAL" >/dev/null; then
    bad "a clean close records no exemption bypass"
else
    ok "a clean close records no exemption bypass"
fi
# The bypass reads the receipt's own row sources with the guard inverted.
# Captured, then matched: piped straight into grep -q under pipefail, a writer
# still printing when grep matched took SIGPIPE and this failed intermittently
# under the parallel pre-push gate (wv-29452e).
bypass_def=$(bash -c 'source "$1/scripts/lib/wv-db.sh" >/dev/null 2>&1; declare -f _policy_close_bypass_sql' _ "$ROOT")
if grep -q '_policy_mccabe_rows_sql exempt' <<< "$bypass_def"; then
    ok "the bypass shares the trigger's clause source"
else
    bad "the bypass shares the trigger's clause source"
fi

echo "=== a pre-invocation hook denial is outside the wv-call denominator ==="
# wv-bd3041: the contract excludes host_event decisions from the denominator.
# A real hook denial must leave no wv call row, the journal must still pass the
# denominator check, and a row synthesized for one must fail it.
HOOK_J="$TEST_DIR/hook-journal.jsonl"
WV_ATTEMPT_JOURNAL="$HOOK_J" "$WV" status >/dev/null 2>&1
before=$(( $(wc -l < "$HOOK_J") ))
echo '{"tool_name":"Edit","tool_input":{"file_path":"'"$HOME"'/.local/bin/wv"}}' |
    WV_ATTEMPT_JOURNAL="$HOOK_J" bash "$ROOT/.claude/hooks/pre-action.sh" >/dev/null 2>&1
hook_rc=$?
[ "$hook_rc" = "2" ] && ok "the hook really denied the edit" || bad "the hook really denied the edit" "rc=$hook_rc"
if jq -e 'select(.rule=="edit_source_not_installed_copy" or .rule=="edit_requires_active_node")' "$HOOK_J" >/dev/null; then
    bad "the hook denial wrote no wv call row"
else
    ok "the hook denial wrote no wv call row"
fi
new_started=$(( $(tail -n +"$((before + 1))" "$HOOK_J" | jq -r 'select(.event=="call_started") | .call_id' | wc -l) ))
new_ids=$(( $(tail -n +"$((before + 1))" "$HOOK_J" | jq -r '.call_id' | sort -u | wc -l) ))
[ "$new_started" = "$new_ids" ] && ok "any wv call the hook launched is a real call with its own call_started ($new_started)" ||
    bad "any wv call the hook launched is a real call with its own call_started" "$new_started started, $new_ids ids"
if report=$(python3 "$ROOT/scripts/weave_policy.py" denominator "$HOOK_J"); then
    ok "the journal passes the denominator check"
else
    bad "the journal passes the denominator check" "$(jq -c .errors <<< "$report")"
fi
if out=$(python3 "$ROOT/scripts/weave_policy.py" denominator "$JOURNAL"); then
    ok "every real gate verdict this suite produced is inside the denominator ($(jq -r .counted_calls <<< "$out") calls)"
else
    bad "every real gate verdict this suite produced is inside the denominator" "$(jq -c .errors <<< "$out")"
fi
[ "$(jq -r '.excluded_scopes | join(",")' <<< "$report")" = "git_event,host_event" ] &&
    ok "the report states the exclusion it counted under" || bad "the report states the exclusion it counted under"
# Forgeries: the hook denial folded in under a synthesized call_id, first with
# no call_started, then with one manufactured for it.
forged='{"event":"policy_verdict","call_id":"hook-synth-1","rule":"edit_source_not_installed_copy","decision":"deny","would_violate_invariant":"yes"}'
{ cat "$HOOK_J"; echo "$forged"; } > "$TEST_DIR/forged-1.jsonl"
if out=$(python3 "$ROOT/scripts/weave_policy.py" denominator "$TEST_DIR/forged-1.jsonl"); then
    bad "a verdict under a synthesized call_id fails the check"
else
    case "$out" in *"has no call_started"*) ok "a verdict under a synthesized call_id fails the check" ;;
        *) bad "a verdict under a synthesized call_id fails the check" "$(jq -c .errors <<< "$out")" ;; esac
fi
{ cat "$HOOK_J"; echo '{"event":"call_started","call_id":"hook-synth-1"}'; echo "$forged"; } > "$TEST_DIR/forged-2.jsonl"
if out=$(python3 "$ROOT/scripts/weave_policy.py" denominator "$TEST_DIR/forged-2.jsonl"); then
    bad "a hook denial dressed as a wv call fails the check"
else
    case "$out" in *"only a pre-invocation hook enforces"*) ok "a hook denial dressed as a wv call fails the check" ;;
        *) bad "a hook denial dressed as a wv call fails the check" "$(jq -c .errors <<< "$out")" ;; esac
fi

echo "=== every event is schema-valid ==="
if python3 "$ROOT/tests/lib/journal-validate.py" "$JOURNAL" 2>"$TEST_DIR/schema.err"; then
    ok "all $(( $(wc -l < "$JOURNAL") )) events validate against the attempt-journal schema"
else
    bad "all events validate against the attempt-journal schema" "$(head -3 "$TEST_DIR/schema.err")"
fi
if jq -e 'select(.event=="non_policy_refusal" and has("decision"))' "$JOURNAL" >/dev/null; then
    bad "a non-policy refusal carries no policy decision"
else
    ok "a non-policy refusal carries no policy decision"
fi

echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
