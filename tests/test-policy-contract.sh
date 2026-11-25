#!/usr/bin/env bash
# Policy-rules contract (wv-f4a297): what may refuse a Weave operation, where it
# is enforced, and what is not a policy decision. Each negative control mutates
# a scratch copy of the tree, never the real one.

# shellcheck source=tests/lib/sed-inplace.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/sed-inplace.sh"  # sed -i is GNU-only (wv-076a98)
set -euo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$ROOT/scripts/weave_policy.py"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
run=0
ok()  { echo "  ✓ $1"; pass=$((pass + 1)); run=$((run + 1)); }
bad() { echo "  ✗ $1"; run=$((run + 1)); }

# A scratch tree holding exactly what the checker reads.
fresh() {
  rm -rf "$TMP/t"
  mkdir -p "$TMP/t/scripts" "$TMP/t/.claude"
  cp -r "$ROOT/contracts" "$TMP/t/contracts"
  cp -r "$ROOT/scripts/lib" "$ROOT/scripts/cmd" "$TMP/t/scripts/"
  cp "$ROOT/scripts/wv" "$TMP/t/scripts/wv"
  cp -r "$ROOT/scripts/hooks" "$TMP/t/scripts/hooks"
  cp -r "$ROOT/.claude/hooks" "$TMP/t/.claude/hooks"
}
passes() {  # passes <label>: validation must still succeed
  if python3 "$TOOL" validate --root "$TMP/t" --contract "$TMP/t/contracts/policy-rules-v1.json" \
      --schema "$TMP/t/contracts/policy-rules-v1.schema.json" >/dev/null 2>&1; then
    ok "$1"
  else
    bad "$1"
  fi
}
check() {  # check <expected-substring> <label>: validation must fail naming it
  local out
  if out=$(python3 "$TOOL" validate --root "$TMP/t" --contract "$TMP/t/contracts/policy-rules-v1.json" \
      --schema "$TMP/t/contracts/policy-rules-v1.schema.json" 2>&1); then
    bad "$2 (validation passed)"
  elif grep -qF -- "$1" <<< "$out"; then
    ok "$2"
  else
    bad "$2 (failed without naming it)"; sed -n '1,3p' <<< "$out" >&2
  fi
}
edit_contract() {  # edit_contract <python expression over c>
  python3 - "$TMP/t/contracts/policy-rules-v1.json" "$1" <<'PY'
import json, sys
path, expr = sys.argv[1], sys.argv[2]
c = json.load(open(path))
exec(expr)
json.dump(c, open(path, "w"), indent=2)
PY
}

if python3 "$TOOL" validate --json > "$TMP/report.json"; then
  ok "the contract validates against the code as it stands"
else
  bad "the contract validates against the code as it stands"; jq -r '.errors[]' "$TMP/report.json" >&2
fi
jq -e '.detected.sqlite_trigger > 0 and .detected.host_hook > 0 and .detected.git_hook > 0 and .detected.emitted_verdicts > 0' \
  "$TMP/report.json" >/dev/null \
  && ok "the completeness scan finds sites in every detectable class (it is not vacuously valid)" \
  || bad "the completeness scan finds sites in every detectable class (it is not vacuously valid)"

fresh; printf "SELECT RAISE(ABORT, 'GraphPolicyViolation: new unclaimed gate');\n" >> "$TMP/t/scripts/lib/wv-db.sh"
check "SQLite abort claimed by no rule" "a new SQLite abort that no rule claims fails validation"

# A hook no site claims: stop-check.sh now holds a claimed denial near its end
# (wv-c7d114), inside whose anchor window an appended line would fall.
fresh; printf 'jq -n %s\n' "'{\"hookSpecificOutput\":{\"permissionDecision\":\"deny\"}}'" >> "$TMP/t/.claude/hooks/session-end-sync.sh"
check "hook denial claimed by no rule" "a new hook denial that no rule claims fails validation"

# GIT HOOKS ARE A PROVEN OWNER (wv-3477f0): a git hook refuses by exiting
# non-zero, and every such exit must be claimed by a rule or a category.
fresh; printf '[ -f /nonexistent ] && exit 1\n' >> "$TMP/t/scripts/hooks/pre-commit-weave.sh"
check "git hook refusal claimed by no rule" "a new pre-commit refusal that no rule claims fails validation"
# The final launch-order refusal has a declared anchor; plant this distinct
# refusal beyond its window, not accidentally inside the declared site's span.
fresh; { printf '    :\n%.0s' $(seq 1 12); printf 'if false; then\n    exit "$rc"\nfi\n'; } \
  >> "$TMP/t/scripts/hooks/pre-push-weave.sh"
check "git hook refusal claimed by no rule" "a variable-status exit in pre-push is a refusal too"
# Planted in a function of its own, past the anchor window of every claimed site.
fresh; { printf '_probe() {\n'; printf '    :\n%.0s' $(seq 1 12); printf '    some_step || exit 1\n}\n'; } \
  >> "$TMP/t/scripts/lib/wv-gate-pool.sh"
check "git hook refusal claimed by no rule" "the suite pool the hooks source is scanned as well"
fresh; printf 'echo "(exit $rc, 3s)"\nexit 0\n' >> "$TMP/t/scripts/hooks/pre-commit-weave.sh"
passes "an exit status quoted in a message, and exit 0, are not refusals"
# Source-only blocks never ship (wv-1c1e15), so the contract, which ships, does
# not claim what they refuse; their markers must still balance.
fresh; printf '# BEGIN source-only: probe\n[ -f /nonexistent ] && exit 1\n# END source-only\n' >> "$TMP/t/scripts/hooks/pre-push-weave.sh"
passes "a refusal inside a source-only block is outside the contract, as it is outside the release"
fresh; printf '# BEGIN source-only: probe\n' >> "$TMP/t/scripts/hooks/pre-push-weave.sh"
check "is never closed" "an unclosed source-only block fails validation instead of hiding the rest of the hook"
fresh; sed_inplace 's/Continue that work as yourself:/Carry on as yourself:/' "$TMP/t/scripts/hooks/pre-commit-weave.sh"
check "occurs 0 time(s)" "the commit-admission site moving away from its anchor fails validation"

fresh; printf '_probe() {\n    wv_attempt_emit policy_verdict \\\n        rule=invented_rule decision=deny\n}\n' >> "$TMP/t/scripts/cmd/wv-cmd-graph.sh"
check "does not declare" "an emitted verdict naming an undeclared rule fails validation"

# Command gates are anchored on their emit, so rewording a message is harmless
# and dropping the emit is not: the gate would decide again without a trace.
fresh; sed_inplace -e '/wv_policy_verdict block_graph_acyclic deny/{' -e x -e '/^done$/{' -e x -e b -e '}' \
  -e 's/.*/done/' -e x -e d -e '}' \
  "$TMP/t/scripts/cmd/wv-cmd-graph.sh"
check "occurs 2 time(s)" "a gate that stops emitting its verdict fails validation instead of going quiet"

fresh; sed_inplace 's/GraphPolicyViolation: test_gate red\/stale result/GraphPolicyViolation: tests red/' "$TMP/t/scripts/lib/wv-db.sh"
check "occurs 0 time(s)" "an enforcement site whose code moved fails validation instead of pointing at nothing"

fresh; edit_contract 'c["rules"][0]["applies_to"] = [{"kind": "operation", "operation": "no-such-op"}]'
check "is not in the capability registry" "applicability must name an operation the capability registry declares"

fresh; edit_contract 'c["rules"][-1]["applies_to"] = [{"kind": "transition", "field": "status", "from": "active", "to": "shipped", "via": ["done"]}]'
check "is not declared by the node field registry" "a transition must use status values the node field registry declares"

fresh; edit_contract 'c["verdict_fold"][0]["verdict"] = "block"'
check "decision enum" "the decision fold must land exactly on the verdict schema's enum"

# A function name that also satisfies the rule_id pattern, so the schema admits
# it and only the identity-independence check can refuse it.
fresh; edit_contract '
r = next(r for r in c["rules"] if r["sites"][0].get("function") == "wv_repository_require_owned")
r["rule_id"] = "wv_repository_require_owned"'
check "rule_id equals its site's function name" "a rule may not take its identity from the function that enforces it"

fresh; edit_contract 'c["undeclared"] = True'
check "undeclared" "the schema refuses a field it does not define"

fresh; edit_contract 'c["completeness"]["declared_only"] = []'
check "completeness must classify every enforcement owner" "every enforcement owner is declared proven or declared-only"

fresh; sed_inplace -e '/wv_policy_verdict block_graph_acyclic deny/{' -e x -e '/^done$/{' -e x -e b -e '}' \
  -e 's/.*/done/' -e x -e 's/wv_policy_verdict block_graph_acyclic deny/wv_policy_verdict block_graph_acyclic advisory/' -e '}' \
  "$TMP/t/scripts/cmd/wv-cmd-graph.sh"
check "which declares" "an emitted decision the rule does not declare fails validation"

fresh; printf '_probe() {\n    wv_policy_refusal expected_conflict "probe"\n}\n' >> "$TMP/t/scripts/cmd/wv-cmd-graph.sh"
check "refusal from a site the contract does not declare" "a refusal emitted from an undeclared site fails validation"

fresh; printf '_probe() {\n    wv_policy_refusal policy_ish "probe"\n}\n' >> "$TMP/t/scripts/cmd/wv-cmd-graph.sh"
check "is not declared" "a refusal naming an undeclared category fails validation"

fresh; edit_contract '
r = next(r for r in c["rules"] if r["rule_id"] == "reconstruct_never_overwrites")
r["sites"][0]["anchor"] = "refusing to overwrite"'
check "is not anchored on its verdict emit" "a command gate must be declared at its verdict emit, not at its message"

# The journal schema restates two vocabularies this contract owns. JSON Schema
# cannot reference across files here, so equality is enforced instead.
python3 - "$ROOT" <<'PY' && ok "the journal schema's decision and category enums are the contract's" \
  || bad "the journal schema's decision and category enums are the contract's"
import json, sys
from pathlib import Path
root = Path(sys.argv[1])
contract = json.loads((root / "contracts/policy-rules-v1.json").read_text())
journal = json.loads((root / "contracts/attempt-journal-v1.schema.json").read_text())["properties"]
assert set(journal["decision"]["enum"]) == set(contract["rule_decisions"])
assert set(journal["category"]["enum"]) == {c["category"] for c in contract["non_policy_categories"]}
PY

python3 - "$ROOT" <<'PY' && ok "policy identity is distinct from the capability registry's and ignores formatting" \
  || bad "policy identity is distinct from the capability registry's and ignores formatting"
import json, shutil, sys, tempfile
from pathlib import Path
root = Path(sys.argv[1])
sys.path.append(str(root / "scripts"))
from weave_policy import contract_identity
from weave_registry import contract_identity as registry_identity
base = contract_identity()
assert base["identity_sha256"] != registry_identity()["identity_sha256"]
with tempfile.TemporaryDirectory() as d:
    copy = Path(d) / "c.json"
    copy.write_text(json.dumps(json.loads((root / "contracts/policy-rules-v1.json").read_text()), indent=4))
    assert contract_identity(copy)["identity_sha256"] == base["identity_sha256"]
    doc = json.loads(copy.read_text()); doc["rules"][0]["summary"] += " (edited)"
    copy.write_text(json.dumps(doc))
    assert contract_identity(copy)["identity_sha256"] != base["identity_sha256"]
PY

# APPLICABILITY PROJECTION (wv-f3cb5e). The shell a call uses to resolve its
# applicable rule set is generated from the contract and must not drift from it.
python3 "$TOOL" check >/dev/null 2>&1 && ok "scripts/lib/wv-policy-rules.sh matches the contract" \
  || bad "scripts/lib/wv-policy-rules.sh matches the contract"
fresh
edit_contract 'c["rules"][0]["summary"] += " (edited)"'
if python3 "$TOOL" check --contract "$TMP/t/contracts/policy-rules-v1.json" \
    --schema "$TMP/t/contracts/policy-rules-v1.schema.json" >/dev/null 2>&1; then
  bad "a contract edit without regeneration is caught"
else
  ok "a contract edit without regeneration is caught"
fi
applies() { bash -c 'source "$1/scripts/lib/wv-policy-rules.sh"; _wv_policy_applicable "$2" "${3:-}"' _ "$ROOT" "$@"; }
case " $(applies update) " in *" close_complexity_ceiling "*) ok "a transition applies to the operations it names via" ;;
  *) bad "a transition applies to the operations it names via" ;; esac
case " $(applies "done") " in *" edit_requires_active_node "*|*" close_requires_committed_work "*)
  bad "host_event rules stay out of the in-call set" ;; *) ok "host_event rules stay out of the in-call set" ;; esac
case " $(applies repo-class set) " in *" owned_override_requires_acknowledgement "*) ok "a suboperation scope applies to its suboperation" ;;
  *) bad "a suboperation scope applies to its suboperation" ;; esac
[ -z "$(applies repo-class audit)" ] && ok "and not to its siblings" || bad "and not to its siblings"
fresh
edit_contract 'c["rules"][[r["rule_id"] for r in c["rules"]].index("close_tests_not_red")]["applies_to"][0]["via"] = ["no-such-op"]'
check "transition via no-such-op" "a transition via an unknown operation is rejected"

# DENOMINATOR BOUNDARY (wv-bd3041). Pre-invocation hook denials are outside the
# wv-call denominator by declaration; the declaration may not reach in-call
# decisions, and no hook may write the attempt journal.
python3 - "$ROOT/contracts/policy-rules-v1.json" <<'PY' && ok "the contract declares the hook exclusion and who decided it" \
  || bad "the contract declares the hook exclusion and who decided it"
import json, sys
d = json.load(open(sys.argv[1]))["denominator"]
assert d["unit"] == "wv_call" and d["requires_event"] == "call_started"
assert [(e["kind"], e["decided_by"]) for e in d["excluded_scopes"]] == [("host_event", "wv-bd3041"), ("git_event", "wv-3477f0")]
PY
# A git-hook rule decides outside any wv call: only a git_hook site may enforce
# its git_event scope, it may not also be an in-call gate, and git hooks are
# held to the same no-journal rule as host hooks.
fresh; edit_contract '
r = next(r for r in c["rules"] if r["rule_id"] == "commit_admission")
r["sites"] = [dict(s, owner="host_hook") for s in r["sites"]]'
check "an excluded git_event scope with no git_hook site" "a git_event scope must be enforced by a git_hook site"
fresh; edit_contract '
r = next(r for r in c["rules"] if r["rule_id"] == "commit_admission")
r["sites"].append({"owner": "command_gate", "path": "scripts/cmd/wv-cmd-graph.sh", "anchor": "wv_policy_verdict block_graph_acyclic"})'
check "outside the denominator but enforced in-call" "a git-hook rule may not also be an in-call gate"
fresh; edit_contract 'c["denominator"]["excluded_scopes"].append(dict(c["denominator"]["excluded_scopes"][0], kind="mystery_event"))'
check "which no out-of-call owner decides" "an exclusion must name a kind some out-of-call owner decides"
fresh; printf 'WV_ATTEMPT_JOURNAL=/tmp/x wv status\n' >> "$TMP/t/scripts/hooks/pre-push-weave.sh"
check "a hook writes the attempt journal" "a git hook that writes the attempt journal fails validation"
case " $(bash -c 'source "$1/scripts/lib/wv-policy-rules.sh"; _wv_policy_applicable "$2"' _ "$ROOT" "done") " in
  *" commit_admission "*|*" push_requires_settled_e6_debt "*) bad "git_event rules stay out of the in-call set" ;;
  *) ok "git_event rules stay out of the in-call set" ;; esac
fresh; edit_contract 'c["denominator"]["excluded_scopes"].append(dict(c["denominator"]["excluded_scopes"][0], kind="operation"))'
check "which decide inside a wv call" "an exclusion cannot reach scopes that decide inside a wv call"
fresh; edit_contract '
r = next(r for r in c["rules"] if r["rule_id"] == "edit_requires_active_node")
r["sites"].append({"owner": "command_gate", "path": "scripts/cmd/wv-cmd-graph.sh", "anchor": "wv_policy_verdict block_graph_acyclic"})'
check "outside the denominator but enforced in-call" "a rule outside the denominator may not also be an in-call gate"
fresh; printf 'WV_ATTEMPT_JOURNAL=/tmp/x wv status\n' >> "$TMP/t/.claude/hooks/stop-check.sh"
check "a hook writes the attempt journal" "a hook that writes the attempt journal fails validation"

# EVERY CLOSE IS JUDGED BY THE RECEIPT (wv-957fc8). A close written as a bare
# UPDATE reaches the trigger with no receipt, so its refusal carries no verdict.
fresh; printf '_probe() {\n    db_query "UPDATE nodes SET status = '"'"'done'"'"' WHERE id='"'"'x'"'"';"\n}\n' >> "$TMP/t/scripts/cmd/wv-cmd-graph.sh"
check "bypasses the close receipt" "a close written as a bare UPDATE fails validation"

# wv-664b7f: a hook-owned rule names itself when its hook decides, with a
# decision it declares, from a line a declared site claims.
fresh; sed_inplace '/_hc_observe no_busy_wait_polling deny/d' "$TMP/t/scripts/lib/wv-pre-tool-use.sh"
check "no_busy_wait_polling: its hook decides without naming it" "a hook rule that stops observing itself fails validation"
fresh; sed_inplace 's/_hc_observe read_size_budget deny/_hc_observe orphan_prevention deny/' "$TMP/t/scripts/lib/wv-hook-common.sh"
check "observes orphan_prevention, which no host_hook site enforces" "a hook observing an in-call rule fails validation"
fresh; sed_inplace 's/_hc_observe claim_premortem_advisory advisory/_hc_observe claim_premortem_advisory deny/' "$TMP/t/scripts/lib/wv-pre-tool-use.sh"
check "observes deny for claim_premortem_advisory" "a hook observing an undeclared decision fails validation"

echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
