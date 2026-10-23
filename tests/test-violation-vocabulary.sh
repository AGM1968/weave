#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# test-violation-vocabulary.sh — contracts/violation-vocabulary-v1.json invariants.
#
# The catalog is the source of truth for finding.violation_type once the shell
# enum becomes a generated projection. Until that landing, the invariant that
# matters most is the compatibility one: the catalog must be a SUPERSET of the
# hand-written FINDING_VIOLATION_TYPES enum, or replacing the validator's source
# would retroactively invalidate finding nodes that are valid today.
#
# It also enforces the guide-basename hygiene the resolver depends on: a dotted
# basename would be read as a language variant, a nested one would not survive
# either installer's non-recursive enumeration, and the `_` prefix is reserved
# for the three presentation guides.
#
# Exit codes: 0 all checks pass, 1 otherwise.

set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CATALOG="$REPO_ROOT/contracts/violation-vocabulary-v1.json"
VALIDATE_LIB="$REPO_ROOT/scripts/lib/wv-validate.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
TESTS_RUN=0; TESTS_PASSED=0; TESTS_FAILED=0
pass() { TESTS_RUN=$((TESTS_RUN+1)); TESTS_PASSED=$((TESTS_PASSED+1)); echo -e "  ${GREEN}✓${NC} $1"; }
fail() { TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAILED=$((TESTS_FAILED+1)); echo -e "  ${RED}✗${NC} $1"; [ -n "${2:-}" ] && echo "$2"; }

echo "=== violation vocabulary contract ==="
echo ""

if [ ! -f "$CATALOG" ]; then
    fail "catalog is present" "    missing: $CATALOG"
    echo "Results: $TESTS_PASSED/$TESTS_RUN passed"; exit 1
fi

# The legacy enum is read from its definition rather than duplicated here: a
# copy would drift exactly as the docstring and fallback lists this slice already
# had to correct. Since the projection landed, wv-validate.sh keeps the
# hand-written set only as the `: "${FINDING_VIOLATION_TYPES:=...}"` fallback;
# the old `^FINDING_VIOLATION_TYPES=` read matched nothing, so the superset
# check below compared the catalog against an empty list (wv-8afd23).
# shellcheck disable=SC2016  # the pattern matches literal $ in the source text it reads
LEGACY_ENUM=$(sed -n 's/^: "\${FINDING_VIOLATION_TYPES:=\(.*\)}"$/\1/p' -- "$VALIDATE_LIB")
if [ -n "$LEGACY_ENUM" ]; then
    pass "the hand-written legacy enum is found in wv-validate.sh"
else
    fail "the hand-written legacy enum is found in wv-validate.sh" "    no FINDING_VIOLATION_TYPES fallback in $VALIDATE_LIB"
fi

# The shell projection is generated; a hand edit or a catalog change without a
# regeneration must fail here, since nothing else runs the generator's check.
if gen_out=$(bash "$REPO_ROOT/scripts/gen-violation-vocabulary.sh" --check 2>&1); then
    pass "wv-violation-vocabulary.gen.sh matches the catalog"
else
    fail "wv-violation-vocabulary.gen.sh matches the catalog" "    $gen_out"
fi

vv_pythonpath="$REPO_ROOT/scripts"
report=$(CATALOG="$CATALOG" LEGACY_ENUM="$LEGACY_ENUM" REPO_ROOT="$REPO_ROOT" PYTHONPATH="$vv_pythonpath" python3 - <<'PY'
import copy
import json
import os
import re
import sys

catalog = json.load(open(os.environ["CATALOG"], encoding="utf-8"))
legacy = os.environ["LEGACY_ENUM"].split()
root = os.environ["REPO_ROOT"]

def validate(candidate):
    problems = []
    if candidate.get("format") != "weave.violation-vocabulary.v1":
        problems.append(f"format must be weave.violation-vocabulary.v1, got {candidate.get('format')!r}")

    types = candidate.get("types")
    if not isinstance(types, dict) or not types:
        return ["types must be a non-empty object"]

    missing = [value for value in legacy if value not in types]
    if missing:
        problems.append("catalog is not a superset of FINDING_VIOLATION_TYPES: " + ", ".join(missing))

    rules = candidate.get("guide_basename_rules", {})
    basename_re = re.compile(rules.get("pattern", "^[a-z0-9]+(-[a-z0-9]+)*$"))
    reserved = rules.get("reserved_prefix", "_")
    windows_devices = {name.casefold() for name in rules.get("reserved_windows_devices", [])}
    required_windows_devices = {"con", "prn", "aux", "nul"} | {
        f"{prefix}{number}" for prefix in ("com", "lpt") for number in range(1, 10)
    }
    if windows_devices != required_windows_devices:
        problems.append("reserved_windows_devices must name the complete portable device-name set")

    seen = {}
    for name, entry in types.items():
        if not isinstance(entry, dict):
            problems.append(f"{name}: entry must be an object")
            continue
        guide = entry.get("guide")
        if not isinstance(guide, str) or basename_re.fullmatch(guide) is None:
            problems.append(f"{name}: guide basename {guide!r} violates {basename_re.pattern}")
            continue
        if guide.startswith(reserved):
            problems.append(f"{name}: guide basename {guide!r} claims the reserved {reserved!r} prefix")
        if "/" in guide or "." in guide:
            problems.append(f"{name}: guide basename {guide!r} must be flat and dot-free")
        folded = guide.casefold()
        if folded in windows_devices:
            problems.append(f"{name}: guide basename {guide!r} is a reserved Windows device name")
        if folded in seen:
            problems.append(f"{name}: guide basename collides case-insensitively with {seen[folded]}")
        seen[folded] = name
        if entry.get("status") not in ("legacy", "compatibility", "canonical"):
            problems.append(f"{name}: status must be legacy|compatibility|canonical")
        if not entry.get("summary"):
            problems.append(f"{name}: summary is required")

    compat = candidate.get("compatibility", {})
    if compat.get("absent_violation_type", {}).get("policy") != "readable":
        problems.append("compatibility.absent_violation_type.policy must be 'readable'")
    if compat.get("canonical_promotion_requires_catalogued_type") is not True:
        problems.append("canonical_promotion_requires_catalogued_type must be true")

    emitters = compat.get("emitters", [])
    expected_sites = {
        "scripts/weave_quality/findings.py::_historical_violation_type",
        "scripts/cmd/wv-cmd-core.sh::_memory_crystallize_finding",
        "wv update --metadata / wv add --metadata",
    }
    actual_sites = {emitter.get("site") for emitter in emitters if isinstance(emitter, dict)}
    if actual_sites != expected_sites or len(emitters) != len(expected_sites):
        problems.append(f"compatibility.emitters sites differ: {sorted(actual_sites)!r}")
    for emitter in emitters:
        catalogued = emitter.get("catalogued")
        if isinstance(catalogued, list):
            unknown = [value for value in catalogued if value not in types]
            if unknown:
                problems.append(f"{emitter.get('site')}: emits uncatalogued {', '.join(unknown)}")
        if "open_ended" in emitter and not emitter.get("policy"):
            problems.append(f"{emitter.get('site')}: an open-ended emitter needs an explicit policy")
    return problems

problems = validate(catalog)
for problem in problems:
    print("PROBLEM " + problem)
print(f"COUNT {len(catalog['types'])}")

def check(name, condition):
    print(("CHECK PASS " if condition else "CHECK FAIL ") + name)

from weave_quality.findings import _historical_violation_type

finite = {
    "defect": "historical:defect",
    "guardrail": "historical:guardrail",
    "root_cause": "historical:root_cause",
    "tooling": "historical:tooling",
}
check("historical finite signal mapping is exact", all(
    _historical_violation_type("learning", signal, "ordinary prose") == expected
    for signal, expected in finite.items()
) and _historical_violation_type("finding", "other", "ordinary prose") == "historical:finding"
  and _historical_violation_type("pitfall", "other", "ordinary prose") == "historical:pitfall"
  and _historical_violation_type("learning", "other", "ordinary prose") == "historical:learning-promotion")

r_value = _historical_violation_type("learning", "defect", "trigger R42:unsafe_call here")
historical_emitter = next(item for item in catalog["compatibility"]["emitters"] if "_historical_violation_type" in item["site"])
check("open-ended historical rule code is explicitly quarantined", r_value == "R42:unsafe_call" and bool(historical_emitter.get("policy")))

core = open(os.path.join(root, "scripts/cmd/wv-cmd-core.sh"), encoding="utf-8").read()
function = re.search(r"^_memory_crystallize_finding\(\) \{.*?^\}", core, re.MULTILINE | re.DOTALL)
check("memory-crystallize writer literal is exact", function is not None and function.group(0).count('violation_type: "memory_contradiction"') == 1)

expected_sites = {
    "scripts/weave_quality/findings.py::_historical_violation_type",
    "scripts/cmd/wv-cmd-core.sh::_memory_crystallize_finding",
    "wv update --metadata / wv add --metadata",
}
check("emitter inventory is the exact reviewed set", {item["site"] for item in catalog["compatibility"]["emitters"]} == expected_sites)

first_type = next(iter(catalog["types"]))
for name, guide in (("trailing-newline basename", "valid-name\n"), ("Windows device basename", "CON")):
    forged = copy.deepcopy(catalog)
    forged["types"][first_type]["guide"] = guide
    check(f"validator rejects {name}", bool(validate(forged)))

forged = copy.deepcopy(catalog)
del forged["types"]["historical:guardrail"]
check("validator rejects a missing finite emitter value", bool(validate(forged)))
PY
)
python_status=$?

if [ "$python_status" -ne 0 ]; then
    fail "catalog validator runs to completion" "    python exited $python_status"
    echo ""; echo "Results: $TESTS_PASSED/$TESTS_RUN passed"; exit 1
fi

problems=$(printf '%s\n' "$report" | grep '^PROBLEM' || true)
counts=$(printf '%s\n' "$report" | grep -c '^COUNT ' || true)
if [ -z "$problems" ] && [ "$counts" -eq 1 ]; then
    pass "catalog invariants hold ($(printf '%s\n' "$report" | sed -n 's/^COUNT //p') types)"
else
    fail "catalog invariants hold" "$(printf '%s\n' "$problems" | sed 's/^PROBLEM /    /')${problems:+$'\n'}    expected exactly one COUNT record, got $counts"
fi

checks=0
while IFS= read -r line; do
    case "$line" in
        "CHECK PASS "*) pass "${line#CHECK PASS }"; checks=$((checks+1)) ;;
        "CHECK FAIL "*) fail "${line#CHECK FAIL }"; checks=$((checks+1)) ;;
    esac
done <<< "$report"
if [ "$checks" -ne 7 ]; then
    fail "validator reports every expected check" "    expected 7 check records, got $checks"
fi

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
[ "$TESTS_FAILED" -eq 0 ]
