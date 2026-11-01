#!/usr/bin/env bash
# Policy totality (wv-53d00c, epic task wv-dbf2d8). Every mutation-class
# operation in the capability registry resolves, against the policy contract, to
# covered, declared ungated, or a declared gap naming the node that closes it,
# and coverage is only what attempt journals show was decided. The journals are
# produced here by driving tests/test-policy-gates.sh and tests/test-policy-cells.sh,
# and the host-hook observations by tests/test-policy-hooks.sh (in parallel, in
# separate repositories), never read from a file that could predate the code it
# describes.
set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POLICY="$ROOT/scripts/weave_policy.py"
CONTRACT="$ROOT/contracts/policy-rules-v1.json"
REGISTRY="$ROOT/contracts/command-capabilities.json"
run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
TMP=$(mktemp -d /tmp/wv-policy-totality-XXXXXX)
trap 'rm -rf "$TMP"' EXIT
SUMMARY="${POLICY_TOTALITY_SUMMARY:-$ROOT/build/policy-totality.json}"

echo "=== drive the gates and read what they decided ==="
JOURNAL="$TMP/gates.jsonl"
CELLS="$TMP/cells.jsonl"
POLICY_GATES_JOURNAL="$JOURNAL" bash "$ROOT/tests/test-policy-gates.sh" >"$TMP/gates.log" 2>&1 </dev/null &
gates_pid=$!
POLICY_CELLS_JOURNAL="$CELLS" bash "$ROOT/tests/test-policy-cells.sh" >"$TMP/cells.log" 2>&1 </dev/null &
cells_pid=$!
HOOKS="$TMP/hooks.jsonl"
POLICY_HOOKS_OBSERVATIONS="$HOOKS" bash "$ROOT/tests/test-policy-hooks.sh" >"$TMP/hooks.log" 2>&1 </dev/null &
hooks_pid=$!
for suite in gates cells hooks; do
    pid_var="${suite}_pid"
    if wait "${!pid_var}"; then
        ok "the $suite suite ran green ($(tail -1 "$TMP/$suite.log"))"
    else
        bad "the $suite suite ran green" "$(grep '✗' "$TMP/$suite.log" | sed -n '1,5p')"
    fi
done
python3 "$POLICY" totality "$JOURNAL" "$CELLS" --hook-observations "$HOOKS" --summary "$SUMMARY" >"$TMP/report.json"
rc=$?
if [ "$rc" = "0" ] && jq -e '.passed' "$TMP/report.json" >/dev/null; then
    ok "the contract's coverage declarations hold against the observed journal"
else
    bad "the contract's coverage declarations hold against the observed journal" "$(jq -c '.errors[:5]' "$TMP/report.json")"
fi
cmp -s "$TMP/report.json" "$SUMMARY" && ok "the durable summary is written ($SUMMARY)" ||
    bad "the durable summary is written ($SUMMARY)"
registered=$(jq '[.commands[] | select(.evidence_class=="mutation_attempt")] | length' "$REGISTRY")
checked=$(jq '.counts.enumerated' "$TMP/report.json")
resolved=$(jq '.counts.covered + .counts.ungated + .counts.gap' "$TMP/report.json")
[ "$registered" = "$checked" ] && [ "$checked" = "$resolved" ] &&
    ok "all $registered mutation-class registry operations are enumerated and resolved" ||
    bad "all mutation-class registry operations are enumerated and resolved" "registry=$registered checked=$checked resolved=$resolved"
jq -e '.operations.covered | map(.operation) | index("block")' "$TMP/report.json" >/dev/null &&
    ok "an operation whose every rule was decided is covered" ||
    bad "an operation whose every rule was decided is covered" "$(jq -c '.operations.covered' "$TMP/report.json")"
# wv-49b339 and wv-664b7f: every rule of every owner is exercised, command and
# SQLite gates through the journals and host hooks through their observations.
# Git-hook rules have no evidence channel by declaration (wv-3477f0): they are
# outside evidence, and exactly they are, so the state cannot hide anything else.
open_rules=$(jq -r '[.rules | to_entries[] | select(.value.state != "exercised" and .value.state != "outside_evidence") | .key] | join(",")' "$TMP/report.json")
outside=$(jq -r '[.rules | to_entries[] | select(.value.state == "outside_evidence") | .key] | sort | join(",")' "$TMP/report.json")
git_only=$(jq -r '[.rules[] | select([.sites[].owner] | unique == ["git_hook"]) | .rule_id] | sort | join(",")' "$ROOT/contracts/policy-rules-v1.json")
[ -n "$git_only" ] && [ "$outside" = "$git_only" ] && ok "outside evidence is exactly the git-hook-only rules ($outside)" ||
    bad "outside evidence is exactly the git-hook-only rules" "outside=$outside git_only=$git_only"
[ -z "$open_rules" ] && ok "every declared rule is exercised, whatever enforces it" ||
    bad "every declared rule is exercised, whatever enforces it" "open: $open_rules"
jq -e '.complete' "$TMP/report.json" >/dev/null && ok "policy totality is complete: no gap is declared or needed" ||
    bad "policy totality is complete: no gap is declared or needed" "$(jq -c '{counts, errors}' "$TMP/report.json")"
[ "$(jq '.counts.gap' "$TMP/report.json")" = "0" ] && [ "$(jq '.counts.uncovered' "$TMP/report.json")" = "0" ] &&
    ok "no operation is a gap: every rule a wv call can meet has been decided" ||
    bad "no operation is a gap: every rule a wv call can meet has been decided" "$(jq -c '.operations.gap' "$TMP/report.json")"
jq -e '.operations.covered | map(.operation) | (index("ship-agent") and index("done") and index("sync"))' "$TMP/report.json" >/dev/null &&
    ok "ship-agent is covered by the rules it runs in-process" ||
    bad "ship-agent is covered by the rules it runs in-process"
jq -e '.complete == (.counts.gap == 0 and ([.rules[] | select(.state=="gap")] | length) == 0)' "$TMP/report.json" >/dev/null &&
    ok "complete is false exactly while a gap is declared" || bad "complete is false exactly while a gap is declared"

# expect_error <label> <pattern> <totality-args...>
expect_error() {
    local label="$1" pattern="$2" out
    shift 2
    out=$(python3 "$POLICY" totality "$@" 2>&1)
    local rc=$?
    if [ "$rc" != "0" ] && jq -e --arg p "$pattern" '.errors | map(select(test($p))) | length > 0' <<< "$out" >/dev/null 2>&1; then
        ok "$label"
    else
        bad "$label" "rc=$rc $(jq -c '.errors[:3]' <<< "$out" 2>/dev/null || echo "$out" | sed -n '1,3p')"
    fi
}
contract_with() {  # contract_with <jq-filter> -> path of a modified contract copy
    local path="$TMP/contract-$RANDOM.json"
    jq "$1" "$CONTRACT" > "$path"
    echo "$path"
}

echo "=== the check fails closed ==="
# Tripwire: a verdict whose emission disappears is a missing cell, whatever the
# source still says.
cat "$JOURNAL" "$CELLS" | jq -c 'select(.rule != "sync_shrink_floor")' > "$TMP/no-shrink-verdict.jsonl"
expect_error "deleting a verdict emission turns the check red" "rule sync_shrink_floor has no observed verdict" \
    "$TMP/no-shrink-verdict.jsonl"
expect_error "no journal at all proves no coverage" "has no observed verdict"
expect_error "an operation with no rule and no declaration is silently uncovered" \
    "operation unlink has no applicable rule and is not declared ungated" \
    "$JOURNAL" "$CELLS" --contract "$(contract_with '.coverage.ungated |= map(select(.operation != "unlink"))')"
expect_error "an operation declared ungated that a rule governs is a contradiction" \
    "operation delete is declared ungated" \
    "$JOURNAL" --contract "$(contract_with '.coverage.ungated += [{"operation":"delete","reason":"a deliberately wrong declaration"}]')"
expect_error "a gap for a rule already exercised is stale" "rule block_graph_acyclic is fully exercised but still declared a gap" \
    "$JOURNAL" --contract "$(contract_with '.coverage.gaps += [{"rule":"block_graph_acyclic","reason":"a deliberately stale gap","node":"wv-000000"}]')"
jq '.commands += [{"operation":"mystery","evidence_class":"unknown","cache":{},"mutation_targets":[]}]' "$REGISTRY" > "$TMP/registry-bad.json"
expect_error "a registry entry that cannot be classified fails closed" "registry entry [0-9]+ cannot be classified" \
    "$JOURNAL" --registry "$TMP/registry-bad.json"
echo "not json" > "$TMP/registry-broken.json"
expect_error "an unreadable registry fails closed" "capability registry cannot be enumerated" \
    "$JOURNAL" --registry "$TMP/registry-broken.json"
jq -c '.policy_identity = "sha256:0000"' "$JOURNAL" > "$TMP/other-identity.jsonl"
expect_error "a journal from another contract identity proves nothing" "recorded under policy identity sha256:0000" \
    "$TMP/other-identity.jsonl"

# Hook evidence is judged as strictly as the journal: a lost hook observation is
# a missing cell, and an observation that names a call or a non-hook rule, or
# carries another contract, proves nothing.
python3 "$POLICY" totality "$JOURNAL" "$CELLS" --hook-observations <(jq -c 'select(.rule != "no_busy_wait_polling")' "$HOOKS") >"$TMP/out.json" 2>&1
jq -e '.passed == false and (.errors | map(select(test("rule no_busy_wait_polling has no observed verdict"))) | length == 1)' "$TMP/out.json" >/dev/null &&
    ok "a hook that stops observing its rule turns the check red" ||
    bad "a hook that stops observing its rule turns the check red" "$(jq -c '.errors[:3]' "$TMP/out.json")"
expect_error "a hook observation carrying a call id is refused" "not a hook observation" \
    "$JOURNAL" "$CELLS" --hook-observations <(jq -c '. + {call_id: "c1"}' "$HOOKS")
expect_error "a hook observation of an in-call rule is refused" "which no host hook enforces" \
    "$JOURNAL" "$CELLS" --hook-observations <(head -1 "$HOOKS" | jq -c '.rule = "orphan_prevention"')
expect_error "a hook observation from another contract proves nothing" "observed under policy identity" \
    "$JOURNAL" "$CELLS" --hook-observations <(head -1 "$HOOKS" | jq -c '.policy_identity = "sha256:" + ("0" * 64)')

echo "=== a fully exercised contract is complete ==="
# A one-rule contract and one-operation registry: exercising both of the rule's
# cells make the operation covered and the report complete.
jq '.rules |= map(select(.rule_id == "block_graph_acyclic")) | .coverage = {"ungated": [], "gaps": []}' \
    "$CONTRACT" > "$TMP/mini-contract.json"
jq '.commands |= map(select(.operation == "block" or .evidence_class != "mutation_attempt"))' \
    "$REGISTRY" > "$TMP/mini-registry.json"
identity="sha256:$(python3 "$POLICY" identity --contract "$TMP/mini-contract.json" | jq -r .identity_sha256)"
printf '%s\n' "{\"event\":\"call_started\",\"call_id\":\"c1\",\"policy_identity\":\"$identity\"}" \
    "{\"event\":\"policy_verdict\",\"call_id\":\"c1\",\"policy_identity\":\"$identity\",\"rule\":\"block_graph_acyclic\",\"decision\":\"deny\"}" \
    "{\"event\":\"policy_verdict\",\"call_id\":\"c1\",\"policy_identity\":\"$identity\",\"rule\":\"block_graph_acyclic\",\"decision\":\"allow\"}" \
    > "$TMP/mini.jsonl"
out=$(python3 "$POLICY" totality "$TMP/mini.jsonl" --contract "$TMP/mini-contract.json" --registry "$TMP/mini-registry.json")
if [ $? = 0 ] && jq -e '.complete and .counts.covered == 1 and .counts.enumerated == 1' <<< "$out" >/dev/null; then
    ok "every cell observed and nothing declared: complete"
else
    bad "every cell observed and nothing declared: complete" "$(jq -c '{complete, counts, errors}' <<< "$out")"
fi
head -1 "$TMP/mini.jsonl" > "$TMP/mini-empty.jsonl"
expect_error "the same contract without the verdict is not" "rule block_graph_acyclic has no observed verdict" \
    "$TMP/mini-empty.jsonl" --contract "$TMP/mini-contract.json" --registry "$TMP/mini-registry.json"

echo "=== wired into make check ==="
# The release projection ships only templates/Makefile.template, the consumer
# wv-* workflow targets, which wv-init-repo may install as a root Makefile. A
# tree whose Makefile defines no check target has nothing to wire this into.
if ! grep -q '^check:' "$ROOT/Makefile" 2>/dev/null; then
    echo "  - this tree's Makefile has no check target (release projection); not asserted"
elif make_plan=$(make -C "$ROOT" -n check 2>/dev/null) && grep -q "test-policy-totality.sh" <<< "$make_plan"; then
    ok "make check runs this suite"
else
    bad "make check runs this suite"
fi

echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
