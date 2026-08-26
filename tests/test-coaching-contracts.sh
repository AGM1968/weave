#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# test-coaching-contracts.sh — the two coaching schemas and their golden fixtures.
#
# Validating the goldens only proves the schemas ACCEPT what we wrote. The forged
# cases below are the half that matters: each one is an invariant the slice
# depends on, and a schema that accepts the forgery has stopped enforcing it.
#
# Exit codes: 0 all checks pass, 1 otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
TESTS_RUN=0; TESTS_PASSED=0; TESTS_FAILED=0
pass() { TESTS_RUN=$((TESTS_RUN+1)); TESTS_PASSED=$((TESTS_PASSED+1)); echo -e "  ${GREEN}✓${NC} $1"; }
fail() { TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAILED=$((TESTS_FAILED+1)); echo -e "  ${RED}✗${NC} $1"; [ -n "${2:-}" ] && echo "$2"; }

echo "=== coaching contract schemas ==="
echo ""

if [ ! -d "$ROOT/mcp/node_modules/ajv" ]; then
    fail "Ajv validator is installed" "    missing: $ROOT/mcp/node_modules/ajv"
    echo "Results: $TESTS_PASSED/$TESTS_RUN passed"; exit 1
fi

# One node run reports every case; the shell decides pass/fail per reported line
# so a single schema break does not hide the others.
output=$(node --input-type=module - "$ROOT" <<'JS'
import fs from "node:fs";
import crypto from "node:crypto";
import Ajv2020 from "./mcp/node_modules/ajv/dist/2020.js";

const [root] = process.argv.slice(2);
const read = (p) => JSON.parse(fs.readFileSync(`${root}/${p}`));
const ajv = new Ajv2020({strict: true, allErrors: true});

const promotion = ajv.compile(read("contracts/coaching-promotion-v1.schema.json"));
const response = ajv.compile(read("contracts/coaching-response-v1.schema.json"));
const vocabulary = read("contracts/violation-vocabulary-v1.json");
const F = "tests/fixtures/coaching/v1";

const promotionSemantics = (doc) => {
  const errors = [];
  if (doc.format === "weave.coaching-promotion-input.v1") {
    const membership = new Set(doc.catalog_violation_types ?? []);
    for (const type of membership) {
      if (!(type in vocabulary.types)) errors.push(`input claims uncatalogued violation_type ${type}`);
    }
    for (const type of Object.values(doc.rule_violation_types ?? {})) {
      if (!membership.has(type)) errors.push(`rule mapping is absent from input catalog ${type}`);
    }
    for (const type of Object.keys(doc.resolved_guides ?? {})) {
      if (!membership.has(type)) errors.push(`resolved guide is absent from input catalog ${type}`);
    }
    if (doc.snapshot?.state === "complete") {
      const active = [...(doc.scope.rule_ids ?? [])].sort();
      const bound = Object.keys(doc.rule_definition_bindings ?? {}).sort();
      if (JSON.stringify(active) !== JSON.stringify(bound)) {
        errors.push("complete input does not bind exactly its active rule_ids");
      }
    }
    return errors;
  }
  if (doc.format !== "weave.coaching-promotion-plan.v1") return errors;
  const identities = new Set();
  for (const candidate of doc.candidates) {
    const material = [
      candidate.violation_type,
      candidate.guide.id,
      candidate.guide.language ?? null,
      doc.scope.target,
      doc.scope.review_parent,
      [...(doc.scope.rule_ids ?? [])].sort(),
    ];
    const expected = `cp-${crypto.createHash("sha256").update(JSON.stringify(material)).digest("hex")}`;
    if (candidate.promotion_id !== expected) errors.push(`bad promotion_id ${candidate.promotion_id}`);
    if (identities.has(expected)) errors.push(`duplicate conceptual promotion ${expected}`);
    identities.add(expected);
    if (!(candidate.violation_type in vocabulary.types)) errors.push(`uncatalogued violation_type ${candidate.violation_type}`);
    const detectorRules = [...new Set(candidate.occurrences.flatMap(
      occurrence => occurrence.detectors.map(detector => detector.rule_id)
    ))].sort();
    const boundRules = Object.keys(candidate.rule_definition_bindings ?? {}).sort();
    if (JSON.stringify(detectorRules) !== JSON.stringify(boundRules)) {
      errors.push("candidate bindings do not match contributing detector rules");
    }
    for (const occurrence of candidate.occurrences) {
      if (!occurrence.merged) continue;
      const ruleIds = occurrence.detectors.map((detector) => detector.rule_id);
      if (new Set(ruleIds).size !== ruleIds.length) errors.push("merged occurrence repeats a rule_id");
    }
  }
  return errors;
};

const validates = (validate, doc, semantic = () => []) => {
  if (!validate(doc)) return ajv.errorsText(validate.errors);
  const errors = semantic(doc);
  return errors.length ? errors.join("; ") : null;
};
const accepts = (name, validate, doc, semantic) => {
  const error = validates(validate, doc, semantic);
  if (!error) console.log(`PASS ${name}`);
  else console.log(`FAIL ${name}\n    ${error}`);
};
const rejects = (name, validate, doc, semantic) => {
  if (validates(validate, doc, semantic)) console.log(`PASS ${name}`);
  else console.log(`FAIL ${name}\n    schema accepted a payload it must reject`);
};

const input = read(`${F}/promotion-input.golden.json`);
const plan = read(`${F}/promotion-plan.golden.json`);
const clean = read(`${F}/response-complete-clean.json`);
const findings = read(`${F}/response-complete-with-findings.json`);
const incomplete = read(`${F}/response-incomplete.json`);

accepts("golden promotion input validates", promotion, input, promotionSemantics);
accepts("golden promotion plan validates", promotion, plan, promotionSemantics);
accepts("complete_clean response validates", response, clean);
accepts("complete_with_findings response validates", response, findings);
accepts("incomplete response validates", response, incomplete);

const fallbackPlan = structuredClone(plan);
fallbackPlan.candidates[0].guide = {
  id: "_uncoached",
  language: null,
  source: "fallback",
  missing_guide_id: "swallowed-exception",
  missing_violation_type: "code:swallowed-exception",
};
const fallbackMaterial = [
  "code:swallowed-exception", "_uncoached", null, "scripts", "wv-44e524",
  ["bare-except-pass", "python-broad-except"],
];
fallbackPlan.candidates[0].promotion_id = `cp-${crypto.createHash("sha256").update(JSON.stringify(fallbackMaterial)).digest("hex")}`;
accepts("fallback promotion plan validates and names the missing guide", promotion, fallbackPlan, promotionSemantics);

const fallbackResponse = structuredClone(findings);
fallbackResponse.blocks[0].guide = {
  ...fallbackResponse.blocks[0].guide,
  id: "_uncoached",
  source: "fallback",
  names_missing_guide: true,
  missing_guide_id: "swallowed-exception",
  missing_violation_type: "code:swallowed-exception",
};
accepts("fallback response names the missing guide", response, fallbackResponse);

// Identity invariants: line and column are display data. An anchor that carries
// them would make a pruned, layout-dependent field part of a durable identity.
const anchored = structuredClone(input);
anchored.format = "weave.coaching-promotion-plan.v1";
anchored.candidates = structuredClone(plan.candidates);
delete anchored.observations;
anchored.candidates[0].occurrences[0].anchor.line = 88;
rejects("anchor may not carry a line", promotion, anchored);

// qf-* evidence must stay well formed; a truncated key means a lost join back
// to the durable adjudication row.
const badKey = structuredClone(input);
badKey.observations[0].detector.finding_key = "qf-short";
rejects("malformed qf-* key is refused", promotion, badKey);

const noCatalogMembership = structuredClone(input);
delete noCatalogMembership.catalog_violation_types;
rejects("planner input must carry catalog membership", promotion, noCatalogMembership);

const noProviderRejections = structuredClone(input);
delete noProviderRejections.provider_rejections;
rejects("planner input must carry provider rejections explicitly", promotion, noProviderRejections);

const noDefinitionBindings = structuredClone(input);
delete noDefinitionBindings.rule_definition_bindings;
rejects("planner input must carry rule definition authority", promotion, noDefinitionBindings);

const missingActiveBinding = structuredClone(input);
delete missingActiveBinding.rule_definition_bindings["python-broad-except"];
rejects("complete input must bind every active rule", promotion, missingActiveBinding, promotionSemantics);

const forgedBindingAuthority = structuredClone(input);
forgedBindingAuthority.rule_definition_bindings["bare-except-pass"].reconstructible_from_commit = true;
rejects("package authority may not claim commit reconstructibility", promotion, forgedBindingAuthority);

const rejectionWithAnchor = structuredClone(input);
rejectionWithAnchor.provider_rejections[0].anchor = structuredClone(plan.rejected[0].anchor);
rejects("provider rejection may not precompute an anchor", promotion, rejectionWithAnchor);

const rejectionWithLocation = structuredClone(input);
rejectionWithLocation.provider_rejections[0].detector.location = {scan_id: 41, line: 88};
rejects("not_current provider rejection may not carry a location", promotion, rejectionWithLocation);

const forgedCatalogMembership = structuredClone(input);
forgedCatalogMembership.catalog_violation_types.push("code:invented");
rejects("input catalog membership must come from the canonical vocabulary", promotion, forgedCatalogMembership, promotionSemantics);

// Promotion must not emit a candidate with no remediation; a generic finding is
// the failure mode the whole slice exists to remove.
const noFix = structuredClone(plan);
delete noFix.candidates[0].proposed_fix;
rejects("candidate without a proposed fix is refused", promotion, noFix);

const lostCandidateBinding = structuredClone(plan);
delete lostCandidateBinding.candidates[0].rule_definition_bindings["python-broad-except"];
rejects("candidate must preserve every contributing rule authority", promotion, lostCandidateBinding, promotionSemantics);

// A detector record with no disposition cannot prove human acceptance.
const noDisposition = structuredClone(input);
delete noDisposition.observations[0].detector.disposition;
rejects("detector record without a disposition is refused", promotion, noDisposition);

for (const disposition of ["false_positive", "waived", "unresolved"]) {
  const notAccepted = structuredClone(input);
  notAccepted.observations[0].detector.disposition = disposition;
  rejects(`${disposition} evidence is not promotable`, promotion, notAccepted);
}

const incompleteInputWithEvidence = structuredClone(input);
incompleteInputWithEvidence.snapshot = {state: "incomplete", causes: [{reason: "receipt_failed", rule_id: "bare-except-pass"}]};
rejects("incomplete input may not carry observations", promotion, incompleteInputWithEvidence);

const incompleteInputWithRejection = structuredClone(input);
incompleteInputWithRejection.snapshot = {state: "incomplete", causes: [{reason: "receipt_failed", rule_id: "bare-except-pass"}]};
incompleteInputWithRejection.observations = [];
rejects("incomplete input may not carry provider rejections", promotion, incompleteInputWithRejection);

const incompletePlanWithCandidate = structuredClone(plan);
incompletePlanWithCandidate.snapshot = {state: "incomplete", causes: [{reason: "receipt_failed", rule_id: "bare-except-pass"}]};
rejects("incomplete plan may not carry candidates", promotion, incompletePlanWithCandidate);

const completeWithCause = structuredClone(input);
completeWithCause.snapshot.causes = [{reason: "receipt_failed", rule_id: "bare-except-pass"}];
rejects("complete snapshot may not carry incomplete causes", promotion, completeWithCause);

const mergedSingle = structuredClone(plan);
mergedSingle.candidates[0].occurrences[0].detectors.pop();
rejects("merged occurrence needs multiple detectors", promotion, mergedSingle, promotionSemantics);

const unmergedMultiple = structuredClone(plan);
unmergedMultiple.candidates[0].occurrences[0].merged = false;
rejects("unmerged occurrence may not combine detectors", promotion, unmergedMultiple, promotionSemantics);

const sameRuleMerge = structuredClone(plan);
sameRuleMerge.candidates[0].occurrences[0].detectors[1].rule_id = "bare-except-pass";
rejects("merged occurrence must combine different rules", promotion, sameRuleMerge, promotionSemantics);

const wrongPromotionId = structuredClone(plan);
wrongPromotionId.candidates[0].promotion_id = `cp-${"f".repeat(64)}`;
rejects("promotion id must match its conceptual identity", promotion, wrongPromotionId, promotionSemantics);

const duplicatePromotion = structuredClone(plan);
duplicatePromotion.candidates.push(structuredClone(duplicatePromotion.candidates[0]));
rejects("promotion plan may not repeat a conceptual identity", promotion, duplicatePromotion, promotionSemantics);

const offCatalog = structuredClone(plan);
offCatalog.candidates[0].violation_type = "not:catalogued";
rejects("canonical plan may not emit an off-catalog type", promotion, offCatalog, promotionSemantics);

// Fail-closed state rules.
const cleanWithBlock = structuredClone(clean);
cleanWithBlock.blocks = structuredClone(findings.blocks);
rejects("complete_clean with a block is refused", response, cleanWithBlock);

const cleanWithoutMessage = structuredClone(clean);
delete cleanWithoutMessage.clean_message;
rejects("complete_clean requires a qualified clean message", response, cleanWithoutMessage);

const cleanWithCause = structuredClone(clean);
cleanWithCause.causes = structuredClone(incomplete.causes);
rejects("complete_clean may not carry incomplete causes", response, cleanWithCause);

const incompleteNoCause = structuredClone(incomplete);
delete incompleteNoCause.causes;
rejects("incomplete without a typed cause is refused", response, incompleteNoCause);

const incompleteClaimingClean = structuredClone(incomplete);
incompleteClaimingClean.clean_message = "all good";
rejects("incomplete may not carry a clean message", response, incompleteClaimingClean);

const findingsClaimingClean = structuredClone(findings);
findingsClaimingClean.clean_message = "all good";
rejects("complete_with_findings may not carry a clean message", response, findingsClaimingClean);

const findingsWithCause = structuredClone(findings);
findingsWithCause.causes = structuredClone(incomplete.causes);
rejects("complete_with_findings may not carry incomplete causes", response, findingsWithCause);

const untypedCause = structuredClone(incomplete);
untypedCause.causes[0].code = "something-went-wrong";
rejects("untyped incomplete cause is refused", response, untypedCause);

// An occurrence line must carry the stored match or context: the whole listing
// contract is that content teaches and the detector message is secondary.
const noContent = structuredClone(findings);
delete noContent.blocks[0].occurrences[0].content;
rejects("occurrence line without content is refused", response, noContent);

const noDetector = structuredClone(findings);
delete noDetector.blocks[0].occurrences[0].detectors;
rejects("occurrence line without detector provenance is refused", response, noDetector);

const fileWithLine = structuredClone(findings);
fileWithLine.blocks[0].occurrences[0].shape = "file";
rejects("file occurrence may not carry a line", response, fileWithLine);

const locationWithoutLine = structuredClone(findings);
delete locationWithoutLine.blocks[0].occurrences[0].line;
rejects("location occurrence requires a line", response, locationWithoutLine);
JS
)

node_status=$?
if [ $node_status -ne 0 ]; then
    fail "schema validation harness runs" "    node exited $node_status"
    echo ""; echo "Results: $TESTS_PASSED/$TESTS_RUN passed"; exit 1
fi

while IFS= read -r line; do
    case "$line" in
        PASS\ *) pass "${line#PASS }" ;;
        FAIL\ *) fail "${line#FAIL }" ;;
        *) [ -n "$line" ] && echo "$line" ;;
    esac
done <<< "$output"

if [ "$TESTS_RUN" -ne 45 ]; then
    fail "schema harness reports every expected case" "    expected 45 case lines, got $TESTS_RUN"
fi

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
[ "$TESTS_FAILED" -eq 0 ]
