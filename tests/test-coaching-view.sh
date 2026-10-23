#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# test-coaching-view.sh — the shared coaching view.
#
# Two questions, deliberately asked separately. The Python scanner asks whether
# the view BEHAVES correctly -- true totals under sampling, the two occurrence
# shapes, incomplete outranking findings, refusals it must not paper over. Ajv
# then asks whether what it produced is a valid coaching-response-v1 envelope.
# A view can be schema-valid and still lie about how many occurrences it found.
#
# Fails closed: a scanner or validator that dies without its terminator line is
# a failure, never a pass.
#
# Exit codes: 0 all checks pass, 1 otherwise.

set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCANNER="$SCRIPT_DIR/lib/coaching-view-scan.py"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
TESTS_RUN=0; TESTS_PASSED=0; TESTS_FAILED=0
pass() { TESTS_RUN=$((TESTS_RUN+1)); TESTS_PASSED=$((TESTS_PASSED+1)); echo -e "  ${GREEN}✓${NC} $1"; }
fail() { TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAILED=$((TESTS_FAILED+1)); echo -e "  ${RED}✗${NC} $1"; [ -n "${2:-}" ] && echo "$2"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "=== coaching view ==="
echo ""

if [ ! -f "$SCANNER" ]; then
    fail "view scanner is present" "    missing: $SCANNER"
    echo "Results: $TESTS_PASSED/$TESTS_RUN passed"; exit 1
fi

(cd "$ROOT" && python3 "$SCANNER" "$TMP/rendered") > "$TMP/out" 2>&1
status=$?
if [ "$status" -ne 0 ] || ! grep -q '^COUNT ' "$TMP/out"; then
    fail "view renders every scenario" "    scanner exited $status without a COUNT line:
$(sed 's/^/    /' "$TMP/out")"
    echo ""; echo "Results: $TESTS_PASSED/$TESTS_RUN passed"; exit 1
fi

problems=$(grep '^PROBLEM' "$TMP/out" || true)
if [ -z "$problems" ]; then
    pass "view behaviour holds ($(awk '/^COUNT/{print $2}' "$TMP/out") scenarios)"
else
    fail "view behaviour holds" "$(printf '%s\n' "$problems" | sed 's/^PROBLEM /    /')"
fi

if [ ! -d "$ROOT/mcp/node_modules/ajv" ]; then
    echo "  SKIP: ajv not installed (run npm install in mcp/)"
else
    node --input-type=module - "$ROOT" "$TMP/rendered" > "$TMP/ajv" 2>&1 <<'JS'
import fs from "node:fs";
import path from "node:path";
import Ajv2020 from "./mcp/node_modules/ajv/dist/2020.js";

const [root, dir] = process.argv.slice(2);
const ajv = new Ajv2020({strict: true, allErrors: true});
const response = ajv.compile(JSON.parse(
  fs.readFileSync(`${root}/contracts/coaching-response-v1.schema.json`)));

let checked = 0;
for (const name of fs.readdirSync(dir).sort()) {
  if (!name.endsWith(".json")) continue;
  const doc = JSON.parse(fs.readFileSync(path.join(dir, name)));
  if (!response(doc)) console.log(`PROBLEM ${name}: ${ajv.errorsText(response.errors)}`);
  checked += 1;
}

// A rendered response that has stopped being checkable is the real risk here,
// so prove the schema still refuses the shapes the view must never emit.
const clean = JSON.parse(fs.readFileSync(path.join(dir, "clean.json")));
const withFindings = JSON.parse(fs.readFileSync(path.join(dir, "with-findings.json")));

const cleanWithBlocks = structuredClone(clean);
cleanWithBlocks.blocks = structuredClone(withFindings.blocks);
if (response(cleanWithBlocks)) console.log("PROBLEM schema accepted a clean state carrying blocks");

const findingsClaimingClean = structuredClone(withFindings);
findingsClaimingClean.clean_message = "all good";
if (response(findingsClaimingClean)) console.log("PROBLEM schema accepted findings claiming cleanliness");

const lineOnFileShape = structuredClone(withFindings);
lineOnFileShape.blocks[0].occurrences[0].shape = "file";
if (response(lineOnFileShape)) console.log("PROBLEM schema accepted a file-shaped occurrence carrying a line");

const noProvenance = structuredClone(withFindings);
delete noProvenance.blocks[0].occurrences[0].detectors;
if (response(noProvenance)) console.log("PROBLEM schema accepted an occurrence with no detector provenance");

console.log(`COUNT ${checked}`);
JS
    ajv_status=$?
    if [ "$ajv_status" -ne 0 ] || ! grep -q '^COUNT ' "$TMP/ajv"; then
        fail "rendered responses validate against coaching-response-v1" \
            "    validator exited $ajv_status without a COUNT line:
$(sed 's/^/    /' "$TMP/ajv")"
    else
        problems=$(grep '^PROBLEM' "$TMP/ajv" || true)
        if [ -z "$problems" ]; then
            pass "rendered responses validate, and the schema still refuses the forbidden shapes ($(awk '/^COUNT/{print $2}' "$TMP/ajv") envelopes)"
        else
            fail "rendered responses validate against coaching-response-v1" \
                "$(printf '%s\n' "$problems" | sed 's/^PROBLEM /    /')"
        fi
    fi
fi

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
[ "$TESTS_FAILED" -eq 0 ]
