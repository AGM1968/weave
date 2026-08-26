#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# test-coaching-fixtures.sh — the frozen Phase 0 coaching cases.
#
# Phase 0 has no planner, so nothing here replays one. What it proves is that
# the frozen cases are schema-valid and internally coherent: an incoherent case
# is worse than no case, because Phase 1 would be built to satisfy it and the
# error would arrive wearing a passing test.
#
# The harness fails closed. Every validator run is checked for a terminator line
# and a zero exit; a crashed or missing validator is a failure, never a pass.
#
# Exit codes: 0 all checks pass, 1 otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES="$ROOT/tests/fixtures/coaching/v1"
FIXTURE_SCANNER="$SCRIPT_DIR/lib/coaching-fixture-scan.py"
GUIDE_SCANNER="$SCRIPT_DIR/lib/coaching-guide-scan.py"
CATALOG="$ROOT/contracts/violation-vocabulary-v1.json"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
TESTS_RUN=0; TESTS_PASSED=0; TESTS_FAILED=0
pass() { TESTS_RUN=$((TESTS_RUN+1)); TESTS_PASSED=$((TESTS_PASSED+1)); echo -e "  ${GREEN}✓${NC} $1"; }
fail() { TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAILED=$((TESTS_FAILED+1)); echo -e "  ${RED}✗${NC} $1"; [ -n "${2:-}" ] && echo "$2"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "=== frozen coaching fixtures ==="
echo ""

for required in "$FIXTURE_SCANNER" "$GUIDE_SCANNER" "$FIXTURES/cases.json"; do
    if [ ! -e "$required" ]; then
        fail "fixtures and validators are present" "    missing: $required"
        echo "Results: $TESTS_PASSED/$TESTS_RUN passed"; exit 1
    fi
done

# Deliberately not a command substitution: a status set inside $(...) dies with
# the subshell, which is how a crashed validator reads as clean.
run_fixture_scan() { (cd "$ROOT" && python3 "$FIXTURE_SCANNER") > "$TMP/out" 2>&1; }
run_guide_scan() { python3 "$GUIDE_SCANNER" "$1" "$CATALOG" > "$TMP/out" 2>&1; }
terminated() { grep -q '^COUNT ' "$TMP/out"; }

# ── every frozen document validates against its schema ────────────────────────
if [ ! -d "$ROOT/mcp/node_modules/ajv" ]; then
    echo "  SKIP: ajv not installed (run npm install in mcp/)"
else
    node --input-type=module - "$ROOT" > "$TMP/ajv" 2>&1 <<'JS'
import fs from "node:fs";
import path from "node:path";
import Ajv2020 from "./mcp/node_modules/ajv/dist/2020.js";

const [root] = process.argv.slice(2);
const ajv = new Ajv2020({strict: true, allErrors: true});
const promotion = ajv.compile(JSON.parse(fs.readFileSync(`${root}/contracts/coaching-promotion-v1.schema.json`)));
const dir = `${root}/tests/fixtures/coaching/v1/cases`;
let checked = 0;
for (const name of fs.readdirSync(dir).sort()) {
  if (!name.endsWith(".json")) continue;
  const doc = JSON.parse(fs.readFileSync(path.join(dir, name)));
  if (!promotion(doc)) console.log(`PROBLEM ${name}: ${ajv.errorsText(promotion.errors)}`);
  checked += 1;
}
console.log(`COUNT ${checked}`);
JS
    ajv_status=$?
    if [ "$ajv_status" -ne 0 ] || ! grep -q '^COUNT ' "$TMP/ajv"; then
        fail "frozen cases validate against the promotion schema" \
            "    validator exited $ajv_status without a COUNT line:
$(sed 's/^/    /' "$TMP/ajv")"
    else
        problems=$(grep '^PROBLEM' "$TMP/ajv" || true)
        if [ -z "$problems" ]; then
            pass "frozen cases validate against the promotion schema ($(awk '/^COUNT/{print $2}' "$TMP/ajv") documents)"
        else
            fail "frozen cases validate against the promotion schema" "$(printf '%s\n' "$problems" | sed 's/^PROBLEM /    /')"
        fi
    fi
fi

# ── the cases say what cases.json claims they say ─────────────────────────────
run_fixture_scan; status=$?
if [ "$status" -ne 0 ] || ! terminated; then
    fail "frozen cases are internally coherent" \
        "    scanner exited $status without a COUNT line:
$(sed 's/^/    /' "$TMP/out")"
else
    problems=$(grep '^PROBLEM' "$TMP/out" || true)
    if [ -z "$problems" ]; then
        pass "frozen cases are internally coherent ($(awk '/^COUNT/{print $2}' "$TMP/out") planner cases)"
    else
        fail "frozen cases are internally coherent" "$(printf '%s\n' "$problems" | sed 's/^PROBLEM /    /')"
    fi
fi

# ── negative controls on the coherence scanner ────────────────────────────────
# Each mutates one frozen case in a scratch copy of the repo tree and requires
# the scanner to name the damage. A scanner that stopped checking passes the
# happy path above and fails every one of these.
expect_fixture_problem() {
    local label="$1" fragment="$2" mutate="$3" work="$TMP/work"
    rm -rf "$work"; mkdir -p "$work/tests/lib" "$work/contracts"
    cp -r "$FIXTURES" "$work/tests/fixtures-tmp"
    mkdir -p "$work/tests/fixtures/coaching"
    mv "$work/tests/fixtures-tmp" "$work/tests/fixtures/coaching/v1"
    cp "$FIXTURE_SCANNER" "$work/tests/lib/"
    cp "$CATALOG" "$work/contracts/"
    ( cd "$work" && python3 - "$mutate" <<'PY'
import json, sys
from pathlib import Path
which = sys.argv[1]
cases = Path("tests/fixtures/coaching/v1/cases")
if which == "lose-evidence":
    p = cases / "merge-across-rules.plan.json"
    d = json.loads(p.read_text()); d["candidates"][0]["occurrences"][0]["detectors"].pop()
    p.write_text(json.dumps(d, indent=2))
elif which == "forge-id":
    p = cases / "merge-across-rules.plan.json"
    d = json.loads(p.read_text()); d["candidates"][0]["promotion_id"] = "cp-" + "0" * 64
    p.write_text(json.dumps(d, indent=2))
elif which == "merged-alone":
    p = cases / "distinct-anchors-stay-distinct.plan.json"
    d = json.loads(p.read_text()); d["candidates"][0]["occurrences"][0]["merged"] = True
    p.write_text(json.dumps(d, indent=2))
elif which == "incomplete-carries-evidence":
    p = cases / "incomplete-blocks-promotion.input.json"
    d = json.loads(p.read_text())
    source = json.loads((cases / "merge-across-rules.input.json").read_text())
    d["observations"] = source["observations"][:1]
    p.write_text(json.dumps(d, indent=2))
elif which == "unmerge-the-flip-base":
    p = cases / "merge-across-rules.plan.json"
    d = json.loads(p.read_text()); d["candidates"][0]["occurrences"][0]["merged"] = False
    p.write_text(json.dumps(d, indent=2))
PY
    ) || { fail "$label" "    could not build the mutated case"; return; }
    ( cd "$work" && python3 tests/lib/coaching-fixture-scan.py ) > "$TMP/out" 2>&1
    local mutated_status=$?
    if [ "$mutated_status" -ne 0 ] || ! terminated; then
        fail "$label" "    scanner crashed (exit $mutated_status) instead of reporting the defect"
        return
    fi
    if grep -qF -- "$fragment" "$TMP/out"; then
        pass "$label"
    else
        fail "$label" "    expected a problem mentioning: $fragment
$(sed 's/^/    /' "$TMP/out")"
    fi
}

expect_fixture_problem "a plan may not lose qf-* evidence" "loses qf-* evidence" lose-evidence
expect_fixture_problem "promotion_id must match its derivation" "does not match its specified derivation" forge-id
expect_fixture_problem "merged requires more than one detector record" "claims merged with one detector" merged-alone
expect_fixture_problem "incomplete may not carry observations" "may not carry observations" incomplete-carries-evidence
expect_fixture_problem "the flip pair must actually flip" "must merge in the base case" unmerge-the-flip-base

# ── guide resolution cases ────────────────────────────────────────────────────
override="$TMP/override"; mkdir -p "$override"
cp "$ROOT/scripts/weave_quality/guides/_clean.md" "$ROOT/scripts/weave_quality/guides/_incomplete.md" \
   "$ROOT/scripts/weave_quality/guides/_uncoached.md" "$override/"
cp "$FIXTURES/guides/project-override/swallowed-exception.python.md" "$override/"
run_guide_scan "$override"; status=$?
if [ "$status" -ne 0 ] || ! terminated; then
    fail "a valid project override resolves" "    scanner exited $status without a COUNT line"
elif grep -q '^PROBLEM' "$TMP/out"; then
    fail "a valid project override resolves" "$(grep '^PROBLEM' "$TMP/out" | sed 's/^PROBLEM /    /')"
else
    pass "a valid project override resolves"
fi

broken="$TMP/broken"; mkdir -p "$broken"
cp "$override/_clean.md" "$override/_incomplete.md" "$override/_uncoached.md" "$broken/"
cp "$FIXTURES/guides/invalid-override/swallowed-exception.python.md" "$broken/"
run_guide_scan "$broken"; status=$?
if [ "$status" -ne 0 ] || ! terminated; then
    fail "an invalid project override is rejected" "    scanner exited $status without a COUNT line"
elif grep -q 'corrective_move is required' "$TMP/out"; then
    pass "an invalid project override is rejected"
else
    fail "an invalid project override is rejected" \
        "    the broken override validated; it must fail closed, not fall through to the package guide"
fi

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
[ "$TESTS_FAILED" -eq 0 ]
