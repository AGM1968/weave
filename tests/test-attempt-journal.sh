#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# The durable attempt journal: what was attempted, under which contract, against
# which causal state, and how it ended.
#
# The properties that matter are the ones a later reader cannot reconstruct:
# that call_started is durable BEFORE dispatch (so a killed call is visibly
# incomplete rather than absent), that every event carries the resolved
# classification rather than the command word, and that evidence mode fails the
# call closed rather than dropping a write it could not make.
set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$ROOT/scripts/wv"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
run=0; pass=0
ok() { run=$((run+1)); pass=$((pass+1)); echo -e "  ${GREEN}✓${NC} $1"; }
bad() { run=$((run+1)); echo -e "  ${RED}✗${NC} $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }
# Counts toward neither pass nor run: a host without an optional dev dependency
# is a narrower run, not a failing one.
skip() { echo -e "  ~ skipped: $1"; }

TEST_DIR=$(mktemp -d /tmp/wv-attempt-journal-XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT
export WEAVE_DIR="$TEST_DIR/.weave"
export WV_HOT_ZONE="$TEST_DIR/hot"
# config.env is sourced with `set -a` every invocation and beats an ambient
# export, so a suite without its own config dir reads the operator's knobs.
export WV_CONFIG_DIR="$TEST_DIR/config"; mkdir -p "$WV_CONFIG_DIR"
JOURNAL="$TEST_DIR/attempts.jsonl"
cd "$TEST_DIR" || exit 1
git init -q . >/dev/null 2>&1
git config user.email test@test.com; git config user.name Test; git config commit.gpgsign false
"$WV" init >/dev/null 2>&1

echo "=== attempt journal ==="

events() { jq -r '.event' < "$JOURNAL" | paste -sd, -; }
field() { jq -r --arg e "$1" --arg f "$2" 'select(.event==$e) | .[$f] | if type=="array" then join(" ") else tostring end' < "$JOURNAL" | tail -1; }

# OFF BY DEFAULT. Analytics may be enabled; evidence must be asked for.
rm -f "$JOURNAL"
"$WV" status >/dev/null 2>&1
[ -f "$JOURNAL" ] && bad "no journal is written unless one is asked for" || ok "no journal is written unless one is asked for"

# RESOLVED CLASSIFICATION. config get is a registry refinement: an observation,
# not the mutation its command-level row describes. The journal records what
# dispatch resolved so no reader re-derives it.
rm -f "$JOURNAL"
WV_ATTEMPT_JOURNAL="$JOURNAL" "$WV" config get session-analysis >/dev/null 2>&1
check "a call records started and completed" "call_started,call_completed" "$(events)"
check "the resolved suboperation is recorded" "get" "$(field call_started suboperation)"
check "the refinement's own evidence class is recorded" "observation" "$(field call_started evidence_class)"
check "an observation declares no mutation targets" "" "$(field call_started mutation_targets)"
identity=$(jq -r 'select(.event=="call_started") | .registry_identity' < "$JOURNAL" | tail -1)
case "$identity" in
    sha256:*) ok "every event carries the capability-registry identity" ;;
    *) bad "every event carries the capability-registry identity" "got [$identity]" ;;
esac
before=$(jq -r 'select(.event=="call_started") | .causal_identity_before.value' < "$JOURNAL" | tail -1)
after=$(jq -r 'select(.event=="call_completed") | .causal_identity_after.value' < "$JOURNAL" | tail -1)
case "$before" in sha256:*) ok "call_started carries the causal identity before the call" ;;
    *) bad "call_started carries the causal identity before the call" "got [$before]" ;; esac
check "an observation leaves the causal identity where it was" "$before" "$after"

# MUTATION DISPOSITION, derived from the two identities rather than declared.
rm -f "$JOURNAL"
WV_ATTEMPT_JOURNAL="$JOURNAL" "$WV" add "journal probe" --standalone >/dev/null 2>&1
# Since wv-15422b each of add's four gates records its allow on a clean call.
check "a mutation records its disposition" \
  "call_started,policy_verdict,policy_verdict,policy_verdict,policy_verdict,mutation_disposition,call_completed" "$(events)"
check "a mutation that changed the graph says so" "changed" "$(field mutation_disposition disposition)"
check "the mutation's targets come from the registry" "brain_db" "$(field mutation_disposition mutation_targets)"
check "the mutation's class comes from the registry" "mutation_attempt" "$(field mutation_disposition evidence_class)"

# A DENIED mutation is still an attempt, and its verdict attaches to the call.
rm -f "$JOURNAL"
WV_ATTEMPT_JOURNAL="$JOURNAL" "$WV" add "epic probe" --standalone --metadata='{"type":"epic"}' --status=active >/dev/null 2>&1
rm -f "$JOURNAL"
WV_ATTEMPT_JOURNAL="$JOURNAL" "$WV" add "orphan probe" >/dev/null 2>&1
denied_rc=$?
check "the orphan gate still denies" "1" "$denied_rc"
check "the denied call records a policy verdict" \
  "call_started,policy_verdict,policy_verdict,mutation_disposition,call_completed" "$(events)"
check "the verdict names its rule" "orphan_prevention" "$(field policy_verdict rule)"
check "the verdict is attached to the call it gated" \
  "$(jq -r 'select(.event=="call_started") | .call_id' < "$JOURNAL")" "$(field policy_verdict call_id)"
check "a denied mutation left the graph unchanged" "unchanged" "$(field mutation_disposition disposition)"

# CRASH. call_started is durable before dispatch, so a killed call is visibly
# incomplete instead of absent.
#
# The victim is killed as soon as its start event is durable, rather than after
# a fixed wait. The old form slept 2s and relied on `analyze sessions` still
# running, which it only was because WV_CALL_LOG is unset here: wv-cmd-analyze.sh
# then falls back to $HOME/.local/share/weave/wv_calls.jsonl, and on a developer
# machine that file had grown unbounded (402MB) because nothing rotated it. Once
# rotation bounds the log the command returns in milliseconds and the fixed wait
# kills a corpse, so the call completes and the case fails. Killing on the
# journal's own state removes both the sleep and the dependency on ambient size.
rm -f "$JOURNAL"
WV_ATTEMPT_JOURNAL="$JOURNAL" WV_CALL_LOG="$TEST_DIR/victim-calls.jsonl" \
    "$WV" analyze sessions >/dev/null 2>&1 &
victim=$!
for _ in $(seq 1 500); do
    [ -s "$JOURNAL" ] && grep -q '"call_started"' "$JOURNAL" 2>/dev/null && break
    kill -0 "$victim" 2>/dev/null || break
    sleep 0.01
done
kill -9 "$victim" 2>/dev/null
wait "$victim" 2>/dev/null
check "a killed call leaves exactly its start" "call_started" "$(events)"
check "the incomplete attempt says so" "incomplete" "$(field call_started disposition)"

# EVIDENCE MODE fails the call closed rather than dropping the write.
rm -f "$JOURNAL"
WV_EVIDENCE_MODE=1 "$WV" status >/dev/null 2>"$TEST_DIR/nopath.err"
check "evidence mode without a journal path fails the call" "1" "$?"
grep -q "requires WV_ATTEMPT_JOURNAL" "$TEST_DIR/nopath.err" \
  && ok "and says why" || bad "and says why" "$(cat "$TEST_DIR/nopath.err")"
WV_EVIDENCE_MODE=1 WV_ATTEMPT_JOURNAL=/proc/nowhere/attempts.jsonl "$WV" status >/dev/null 2>"$TEST_DIR/unwritable.err"
check "evidence mode with an unwritable journal fails the call" "1" "$?"
grep -q "attempt journal write failed" "$TEST_DIR/unwritable.err" \
  && ok "and names the path it could not write" || bad "and names the path it could not write" ""
WV_EVIDENCE_MODE=1 WV_ATTEMPT_JOURNAL="$JOURNAL" "$WV" status >/dev/null 2>&1
check "evidence mode with a writable journal runs normally" "0" "$?"

# Analytics stays opt-in and best-effort: an unwritable CALL LOG must not fail a
# call, or enabling analytics would change evidence semantics.
WV_CALL_LOG=/proc/nowhere/calls.jsonl "$WV" status >/dev/null 2>&1
check "an unwritable analytics call log does not fail the call" "0" "$?"

# SCHEMA. Every event validates against contracts/attempt-journal-v1.schema.json,
# executed by the same validator the capability registry uses -- including its
# keyword-coverage guard -- and independently by ajv. A corpus with all four
# event types is collected first, because a schema that only ever sees
# call_started proves nothing about the events that carry the decisions.
CORPUS="$TEST_DIR/corpus.jsonl"
rm -f "$JOURNAL"
WV_ATTEMPT_JOURNAL="$JOURNAL" "$WV" status >/dev/null 2>&1
WV_ATTEMPT_JOURNAL="$JOURNAL" "$WV" add "corpus probe" >/dev/null 2>&1
cp "$JOURNAL" "$CORPUS"
present=$(jq -r '.event' < "$CORPUS" | sort -u | paste -sd, -)
check "the corpus covers every event type" \
  "call_completed,call_started,mutation_disposition,policy_verdict" "$present"
if python3 "$ROOT/tests/lib/journal-validate.py" "$CORPUS" 2>"$TEST_DIR/schema.err"; then
    ok "every event validates against the schema"
else
    bad "every event validates against the schema" "$(head -3 "$TEST_DIR/schema.err")"
fi

# NEGATIVE CONTROLS. A validator that accepts everything would pass the check
# above without enforcing anything.
python3 - "$CORPUS" "$TEST_DIR" <<'PY'
import json, sys
from pathlib import Path
corpus, out = Path(sys.argv[1]), Path(sys.argv[2])
events = [json.loads(line) for line in corpus.read_text().splitlines() if line.strip()]
verdict = next(e for e in events if e["event"] == "policy_verdict")
started = next(e for e in events if e["event"] == "call_started")
forgeries = {
    "no-envelope": {k: v for k, v in verdict.items() if k not in {"registry_identity", "causal_identity_before"}},
    "unknown-event": {**started, "event": "call_maybe"},
    "verdict-without-invariant": {k: v for k, v in verdict.items() if k != "would_violate_invariant"},
    "verdict-without-rule": {k: v for k, v in verdict.items() if k != "rule"},
    # Complete in every other respect, so only "countable needs state complete"
    # can reject it.
    "countable-policy": {**next(e for e in events if e["event"] == "call_completed"),
                         "policy": {"state": "partial", "countable": True, "verdicts": 1,
                                    "applicable_rules": ["a", "b"], "evaluated_rules": ["a"], "reason": "x"}},
}
for name, event in forgeries.items():
    (out / f"forge-{name}.jsonl").write_text(json.dumps(event) + "\n")
print(" ".join(forgeries))
PY
for forgery in no-envelope unknown-event verdict-without-invariant verdict-without-rule countable-policy; do
    if python3 "$ROOT/tests/lib/journal-validate.py" "$TEST_DIR/forge-$forgery.jsonl" >/dev/null 2>&1; then
        bad "the schema rejects $forgery"
    else
        ok "the schema rejects $forgery"
    fi
done

if [ -d "$ROOT/mcp/node_modules/ajv" ]; then
    # From $ROOT: the ajv import is relative to the process cwd, and this suite
    # runs from its own temp repository.
    CORPUS="$CORPUS" TEST_DIR="$TEST_DIR" node --input-type=module - "$ROOT" --cwd "$ROOT" >"$TEST_DIR/ajv" 2>&1 <<'JS' || true
import fs from "node:fs";
const [root] = process.argv.slice(2);
const { default: Ajv2020 } = await import(`${root}/mcp/node_modules/ajv/dist/2020.js`);
const ajv = new Ajv2020({strict: true, allErrors: true});
const validate = ajv.compile(JSON.parse(fs.readFileSync(`${root}/contracts/attempt-journal-v1.schema.json`)));
const read = (p) => fs.readFileSync(p, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l));
const problems = [];
for (const event of read(process.env.CORPUS)) {
  if (!validate(event)) problems.push(`ajv rejects a real ${event.event}: ${ajv.errorsText(validate.errors)}`);
}
for (const name of ["no-envelope", "unknown-event", "verdict-without-invariant", "verdict-without-rule", "countable-policy"]) {
  for (const event of read(`${process.env.TEST_DIR}/forge-${name}.jsonl`)) {
    if (validate(event)) problems.push(`ajv accepts forgery ${name}`);
  }
}
console.log(problems.length ? problems.join("; ") : "agreed");
JS
    check "ajv reaches the same verdicts on the same events" "agreed" "$(cat "$TEST_DIR/ajv")"
else
    # Environment-dependent, so it counts toward neither pass nor run: ajv is a
    # dev dependency of this repository and absent from a fresh clone of the
    # public projection, which retains this suite. The schema's own keyword
    # coverage and the emitter's required-field checks above still run.
    skip "ajv cross-check (install with: npm --prefix mcp install)"
fi

# The emitter's required-field table and the schema must agree, or an event the
# emitter allows can still be unreadable to a consumer.
if python3 - "$ROOT" <<'PY'
import json, re, sys
from pathlib import Path
root = Path(sys.argv[1])
lib = (root / "scripts/lib/wv-attempt-journal.sh").read_text()
block = re.search(r"_wv_attempt_required_fields\(\) \{(.*?)\n\}", lib, re.S).group(1)
emitter = {
    event: set(fields.split())
    for event, fields in re.findall(r"\s+(\w+)\) printf '([^']*)'", block)
}
schema = json.loads((root / "contracts/attempt-journal-v1.schema.json").read_text())
declared = {}
for branch in schema["oneOf"]:
    event = branch["properties"]["event"]["const"]
    declared[event] = {name for name in branch["required"] if name != "event"}
raise SystemExit(0 if emitter == declared else 1)
PY
then
    ok "the emitter requires exactly what the schema requires"
else
    bad "the emitter requires exactly what the schema requires"
fi

# POLICY PROVENANCE. Silence is never an allow: a call is countable only when
# every rule the policy contract applies to its operation recorded a durable
# verdict, in evidence mode (wv-f3cb5e).
pol() { jq -r --arg f "$1" 'select(.event=="call_completed") | .policy[$f] | if type=="array" then join(" ") else tostring end' < "$JOURNAL" | tail -1; }
rm -f "$JOURNAL"
WV_ATTEMPT_JOURNAL="$JOURNAL" "$WV" status >/dev/null 2>&1
check "a call the contract applies no rule to has an empty applicable set" "" "$(pol applicable_rules)"
check "outside evidence mode even a complete call is not countable" "complete/false" "$(pol state)/$(pol countable)"
rm -f "$JOURNAL"
WV_ATTEMPT_JOURNAL="$JOURNAL" "$WV" add "policy probe" >/dev/null 2>&1
check "the applicable set comes from the policy contract" \
  "active_add_requires_claim_readiness add_duplicate_check orphan_prevention reconstruct_never_overwrites" \
  "$(pol applicable_rules)"
# Claim readiness allows (the add is not active) before orphan prevention denies.
check "the evaluated set is what the call recorded" "active_add_requires_claim_readiness orphan_prevention" \
  "$(pol evaluated_rules)"
check "a call whose applicable rules did not all speak is partial and not countable" "partial/false" \
  "$(pol state)/$(pol countable)"
check "the verdict count is recorded" "2" "$(pol verdicts)"
rm -f "$JOURNAL"
WV_EVIDENCE_MODE=1 WV_ATTEMPT_JOURNAL="$JOURNAL" "$WV" add "policy probe evidence" >/dev/null 2>&1
check "evidence mode does not make a partial call countable" "partial/false" "$(pol state)/$(pol countable)"
selfblock=$("$WV" add "self block probe" --force 2>/dev/null | tail -1)
rm -f "$JOURNAL"
WV_EVIDENCE_MODE=1 WV_ATTEMPT_JOURNAL="$JOURNAL" "$WV" block "$selfblock" --by="$selfblock" >/dev/null 2>&1
check "every applicable rule speaking, in evidence mode, is countable" "complete/true" "$(pol state)/$(pol countable)"
identity=$(jq -r 'select(.event=="call_started") | .policy_identity' < "$JOURNAL")
check "events bind the policy contract identity" \
  "sha256:$(python3 "$ROOT/scripts/weave_policy.py" identity | jq -r .identity_sha256)" "$identity"
[ "$identity" != "$(jq -r 'select(.event=="call_started") | .registry_identity' < "$JOURNAL")" ] &&
  ok "the policy identity is distinct from the registry identity" ||
  bad "the policy identity is distinct from the registry identity"

# Sets that disagree are never countable. Driven through the builder itself with
# a forged marker or journal, since a well-behaved call cannot produce either.
policy_with() {  # <operation> <marker-rules> <journal-rules>
    WV_EVIDENCE_MODE=1 WV_ATTEMPT_JOURNAL="$TEST_DIR/forge-journal.jsonl" bash -c '
        source "$1/scripts/lib/wv-policy-rules.sh"; source "$1/scripts/lib/wv-attempt-journal.sh"
        wv_attempt_context forged-call w t test r "$2" "" mutation_attempt "[]" "" "" null "" "" ""
        rm -f "$WV_ATTEMPT_JOURNAL" "$(_wv_attempt_verdict_marker)"
        for r in $3; do echo "$r" >> "$(_wv_attempt_verdict_marker)"; done
        for r in $4; do echo "{\"event\":\"policy_verdict\",\"call_id\":\"forged-call\",\"rule\":\"$r\"}" >> "$WV_ATTEMPT_JOURNAL"; done
        wv_attempt_policy_json' _ "$ROOT" "$1" "$2" "$3" | jq -r '"\(.state)/\(.countable)"'
}
mkdir -p "$WV_HOT_ZONE/attempt-verdicts"
check "matching sets, marker and journal agreeing, are countable" "complete/true" \
  "$(policy_with block block_graph_acyclic block_graph_acyclic)"
check "a verdict for a rule the operation does not carry is inconsistent" "inconsistent/false" \
  "$(policy_with block "block_graph_acyclic orphan_prevention" "block_graph_acyclic orphan_prevention")"
check "a marker naming a verdict the journal lacks is inconsistent" "inconsistent/false" \
  "$(policy_with block block_graph_acyclic "")"
check "a journal verdict the marker lost is inconsistent" "inconsistent/false" \
  "$(policy_with block "" block_graph_acyclic)"

# NEGATIVE CONTROLS on the marker. Each ends the call in evidence mode, and none
# leaves a countable row behind.
marker_rc=$(WV_EVIDENCE_MODE=1 WV_ATTEMPT_JOURNAL="$TEST_DIR/marker.jsonl" bash -c '
    source "$1/scripts/lib/wv-attempt-journal.sh"
    wv_attempt_context marker-call w t test r block "" mutation_attempt "[]" "" "" null "" "" ""
    wv_attempt_verdicts_claim
    chmod 444 "$(_wv_attempt_verdict_marker)"
    wv_attempt_emit policy_verdict rule=block_graph_acyclic decision=deny would_violate_invariant=yes
    echo survived' _ "$ROOT" 2>/dev/null; echo "rc=$?")
check "a suppressed marker write ends the call" "rc=1" "$marker_rc"
chmod 644 "$WV_HOT_ZONE/attempt-verdicts/marker-call" 2>/dev/null; rm -f "$WV_HOT_ZONE/attempt-verdicts/marker-call"
reset_rc=$(WV_EVIDENCE_MODE=1 WV_ATTEMPT_JOURNAL="$TEST_DIR/reset.jsonl" WV_HOT_ZONE="$TEST_DIR/reset-hot" bash -c '
    source "$1/scripts/lib/wv-attempt-journal.sh"
    wv_attempt_context reset-call w t test r block "" mutation_attempt "[]" "" "" null "" "" ""
    wv_attempt_verdicts_claim
    chmod 555 "$(dirname "$(_wv_attempt_verdict_marker)")"
    wv_attempt_verdicts_reset
    echo survived' _ "$ROOT" 2>/dev/null; echo "rc=$?")
chmod 755 "$TEST_DIR/reset-hot/attempt-verdicts" 2>/dev/null
check "a verdict reset that fails ends the call" "rc=1" "$reset_rc"
# A second call under an id another call holds: evidence mode refuses it before
# call_started, and analytics mode runs the command but writes nothing under it.
DUP="$TEST_DIR/dup.jsonl"
mkdir -p "$WV_HOT_ZONE/attempt-verdicts" && : > "$WV_HOT_ZONE/attempt-verdicts/held-call-id"
WV_EVIDENCE_MODE=1 WV_ATTEMPT_JOURNAL="$DUP" WV_CALL_ID=held-call-id "$WV" status >/dev/null 2>&1
check "a call_id held by another call is refused in evidence mode" "1" "$?"
WV_ATTEMPT_JOURNAL="$DUP" WV_CALL_ID=held-call-id "$WV" status >/dev/null 2>&1
check "in analytics mode the command still runs" "0" "$?"
check "and nothing is journaled under the shared id" "0" \
  "$(cat "$DUP" 2>/dev/null | grep -c '"call_id":"held-call-id"' || true)"
[ -f "$WV_HOT_ZONE/attempt-verdicts/held-call-id" ] && ok "the holder's marker is left intact" ||
  bad "the holder's marker is left intact"
rm -f "$WV_HOT_ZONE/attempt-verdicts/held-call-id"
check "no negative control produced a countable row" "" \
  "$(cat "$TEST_DIR"/marker.jsonl "$TEST_DIR"/reset.jsonl "$DUP" 2>/dev/null | jq -r 'select(.policy.countable==true) | .call_id')"
check "no call is ever recorded as allowed by default" "" \
  "$(jq -r 'select(.decision=="allow") | .event' < "$JOURNAL")"

# The verdict carries the full envelope: the first version of this journal let
# the gate assemble its own JSON, and every classification and identity field
# came out null.
nulls=$(jq -r 'select(.event=="policy_verdict")
  | [to_entries[] | select(.value == null or .value == "") | .key]
  | map(select(. != "workflow_id" and . != "suboperation" and . != "parent_call_id")) | join(",")' < "$JOURNAL")
check "the verdict carries a complete envelope" "" "$nulls"
check "the verdict names the invariant it protects" "yes" \
  "$(jq -r 'select(.event=="policy_verdict") | .would_violate_invariant' < "$JOURNAL")"

# FAIL CLOSED IS THE EMITTER'S. A gate cannot discard a failed verdict write,
# because the emitter ends the call itself -- the regression being pinned is a
# call site that wrote `2>/dev/null || true` and lost the decisive event.
verdict_rc=$(WV_EVIDENCE_MODE=1 WV_ATTEMPT_JOURNAL=/proc/nowhere/attempts.jsonl bash -c '
    . "'"$ROOT"'/scripts/lib/wv-attempt-journal.sh"
    wv_attempt_context c1 "" t1 test /repo add "" mutation_attempt "[]" sha256:x schema "null"
    wv_attempt_emit policy_verdict rule=r decision=deny would_violate_invariant=yes
    echo REACHED' 2>/dev/null; echo "rc=$?")
check "a verdict that cannot be written ends the call" "rc=1" "$verdict_rc"
check "no call site discards an emitter failure" "" \
  "$(grep -rn 'wv_attempt_emit' "$ROOT/scripts" | grep -E '\|\| *true|2>/dev/null' || true)"

# ── call identity under nesting ───────────────────────────────────────────────
#
# WV_CALL_ID is exported so a gate inside the call can attach a verdict to it,
# which means a wv launched underneath inherits it. Adopting it outright gave two
# call_started events one call_id and let the child's verdict-marker reset delete
# the parent's verdicts, so the parent reported "no verdict" for a call that had
# emitted one. WV_CALL_ID_OWNER separates an id a harness pinned for a root call
# from one a parent wv exported.

# A harness that pins an id for a root call still gets that id: the E5 probes do
# this to find their own rows, and a fix that broke it would be a different bug.
rm -f "$JOURNAL"
WV_ATTEMPT_JOURNAL="$JOURNAL" WV_CALL_ID=externally-pinned-root "$WV" status >/dev/null 2>&1
check "an externally supplied call id is honoured for a root call" "externally-pinned-root" \
  "$(jq -r 'select(.event=="call_started") | .call_id' < "$JOURNAL" | tail -1)"
check "a root call records no parent" "null" \
  "$(jq -r 'select(.event=="call_started") | .parent_call_id' < "$JOURNAL" | tail -1)"

# A nested call mints its own identity and names the one it inherited. The hook
# is a stand-in for the real path: wv quick commits, git runs the pre-commit
# hook, the hook calls wv.
rm -f "$JOURNAL"
mkdir -p "$TEST_DIR/nest-hooks"
cat > "$TEST_DIR/nest-hooks/pre-commit" <<NESTHOOK
#!/usr/bin/env bash
WV_ATTEMPT_JOURNAL="$JOURNAL" "$WV" status >/dev/null 2>&1 || true
exit 0
NESTHOOK
chmod +x "$TEST_DIR/nest-hooks/pre-commit"
git config core.hooksPath "$TEST_DIR/nest-hooks"
printf 'nested\n' > nested.txt; git add nested.txt >/dev/null 2>&1
# The pre-commit gate runs suites with GIT_CONFIG_KEY_0=core.hooksPath=/dev/null
# exported, which beats repository config in every git process the suite starts.
# A test whose subject is a hook must clear that or it silently tests nothing --
# and passes, because "no nested call" and "nested call with its own id" both
# leave one id per event.
env -u GIT_CONFIG_COUNT -u GIT_CONFIG_KEY_0 -u GIT_CONFIG_VALUE_0 \
    WV_ATTEMPT_JOURNAL="$JOURNAL" "$WV" quick "nested identity probe" >/dev/null 2>&1
git config --unset core.hooksPath
distinct_ids=$(jq -r 'select(.event=="call_started") | .call_id' < "$JOURNAL" | sort -u | wc -l)
started=$(jq -r 'select(.event=="call_started") | .call_id' < "$JOURNAL" | wc -l)
# Asserted, not assumed: if the hook did not run there is one call and every
# identity claim below is vacuously true.
check "the fixture actually nested a call inside a call" "2" "$started"
check "each nested call gets its own identity" "$started" "$distinct_ids"
nested_parent=$(jq -r 'select(.event=="call_started" and .operation=="status") | .parent_call_id' < "$JOURNAL" | tail -1)
outer_id=$(jq -r 'select(.event=="call_started" and .operation=="quick") | .call_id' < "$JOURNAL" | tail -1)
check "the nested call names the call it was launched under" "$outer_id" "$nested_parent"

# The point of the fix, not just its mechanism: a nested call must not be able to
# erase what the outer call recorded.
rm -f "$JOURNAL"
outer_verdicts=$(WV_ATTEMPT_JOURNAL="$JOURNAL" bash -c '
    . "'"$ROOT"'/scripts/lib/wv-attempt-journal.sh"
    wv_attempt_context outer-call "" t1 test /repo add "" mutation_attempt "[]" sha256:x schema "null" ""
    wv_attempt_emit policy_verdict rule=r decision=deny would_violate_invariant=yes >/dev/null
    # The nested call, with its own identity and the outer one as parent.
    (
      . "'"$ROOT"'/scripts/lib/wv-attempt-journal.sh"
      wv_attempt_context nested-call "" t1 test /repo status "" observation "[]" sha256:x schema "null" outer-call
      wv_attempt_verdicts_reset
    )
    wv_attempt_verdict_count')
check "a nested call cannot erase the outer call's verdicts" "1" "$outer_verdicts"

# Concurrent siblings under one parent: distinct identities, same parent.
rm -f "$JOURNAL"
for sibling in 1 2 3; do
  ( WV_ATTEMPT_JOURNAL="$JOURNAL" WV_CALL_ID=sibling-parent WV_CALL_ID_OWNER=999999 \
      "$WV" status >/dev/null 2>&1 ) &
done
wait
sibling_ids=$(jq -r 'select(.event=="call_started") | .call_id' < "$JOURNAL" | sort -u | wc -l)
sibling_parents=$(jq -r 'select(.event=="call_started") | .parent_call_id' < "$JOURNAL" | sort -u | paste -sd, -)
check "concurrent siblings each mint their own identity" "3" "$sibling_ids"
check "and all name the same parent" "sibling-parent" "$sibling_parents"

# A command that exits directly still completes: the finalizer is an EXIT trap
# rather than code after main, so a call that never returns to the caller is
# recorded rather than looking killed.
rm -f "$JOURNAL"
WV_ATTEMPT_JOURNAL="$JOURNAL" "$WV" config get definitely-not-a-key >/dev/null 2>&1 || true
check "a command that exits directly still records completion" "call_started,call_completed" "$(events)"

# SIGKILL leaves an attributable incomplete attempt, with the identity fields a
# reader needs to place it.
rm -f "$JOURNAL"
WV_ATTEMPT_JOURNAL="$JOURNAL" "$WV" analyze sessions >/dev/null 2>&1 &
killed=$!
# Kill once the call has journaled its start, not after a fixed delay: under
# load (parallel gate lanes) the call had not started within 2s and no journal
# existed (wv-c9d6b7). Bounded, so a call that never journals fails here.
timeout 60 bash -c 'until grep -qs "\"call_started\"" "$1"; do sleep 0.1; done' _ "$JOURNAL"
check "the call journaled its start before the kill" "0" "$?"
kill -9 "$killed" 2>/dev/null
check "...and was still running when killed" "0" "$?"
wait "$killed" 2>/dev/null
check "a SIGKILLed call leaves an attributable incomplete attempt" "incomplete" \
  "$(field call_started disposition)"
check "and the incomplete attempt still carries a parent field" "null" \
  "$(jq -r 'select(.event=="call_started") | .parent_call_id' < "$JOURNAL" | tail -1)"

# PARITY. A reader reconstructing the call tree from analytics and one from the
# journal must not disagree about which calls had parents.
rm -f "$JOURNAL"
PARITY_LOG="$TEST_DIR/parity-calls.jsonl"; rm -f "$PARITY_LOG"
WV_ATTEMPT_JOURNAL="$JOURNAL" WV_CALL_LOG="$PARITY_LOG" \
  WV_CALL_ID=parity-parent WV_CALL_ID_OWNER=999999 "$WV" status >/dev/null 2>&1
check "the analytics envelope carries the same parent as the journal" \
  "$(jq -r '.parent_call_id' < "$PARITY_LOG" | tail -1)" \
  "$(jq -r 'select(.event=="call_started") | .parent_call_id' < "$JOURNAL" | tail -1)"
check "and the same call id" \
  "$(jq -r '.call_id' < "$PARITY_LOG" | tail -1)" \
  "$(jq -r 'select(.event=="call_started") | .call_id' < "$JOURNAL" | tail -1)"

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
