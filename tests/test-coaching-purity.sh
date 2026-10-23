#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# test-coaching-purity.sh — the planner replays the frozen cases, and stays pure.
#
# Two invariants, and they support each other. The replay proves the planner
# produces exactly the frozen plans; the purity scan proves it did so from the
# document alone. Either without the other is weak: a planner that reads the
# database could still reproduce a fixture, and a pure module that computes the
# wrong plan is pure and useless.
#
# The purity boundary is why the Rust progression can advance at all — an
# offline shadow replays frozen cases only if replaying needs nothing but bytes.
#
# Exit codes: 0 all checks pass, 1 otherwise.

set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PURITY="$SCRIPT_DIR/lib/coaching-purity-scan.py"
PACKAGE="$ROOT/scripts/weave_coaching"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
TESTS_RUN=0; TESTS_PASSED=0; TESTS_FAILED=0
pass() { TESTS_RUN=$((TESTS_RUN+1)); TESTS_PASSED=$((TESTS_PASSED+1)); echo -e "  ${GREEN}✓${NC} $1"; }
fail() { TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAILED=$((TESTS_FAILED+1)); echo -e "  ${RED}✗${NC} $1"; [ -n "${2:-}" ] && echo "$2"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "=== coaching planner purity and replay ==="
echo ""

for required in "$PURITY" "$PACKAGE"; do
    if [ ! -e "$required" ]; then
        fail "planner and scanner are present" "    missing: $required"
        echo "Results: $TESTS_PASSED/$TESTS_RUN passed"; exit 1
    fi
done

terminated() { grep -q '^COUNT ' "$TMP/out"; }

# ── replay ────────────────────────────────────────────────────────────────────
(cd "$ROOT" && python3 - <<'PY'
import json, sys
sys.path.insert(0, "scripts")
from pathlib import Path
from weave_coaching import plan_promotions

cases = Path("tests/fixtures/coaching/v1/cases")
names = sorted(p.name[: -len(".input.json")] for p in cases.glob("*.input.json"))
for name in names:
    input_doc = json.loads((cases / f"{name}.input.json").read_text())
    got = plan_promotions(input_doc)
    want = json.loads((cases / f"{name}.plan.json").read_text())
    if got != want:
        print(f"PROBLEM {name}: planner output differs from the frozen plan")
    permuted = {
        **input_doc,
        "observations": list(reversed(input_doc["observations"])),
        "provider_rejections": list(reversed(input_doc["provider_rejections"])),
    }
    permuted["scope"] = dict(input_doc["scope"])
    permuted["scope"]["rule_ids"] = list(reversed(input_doc["scope"].get("rule_ids", [])))
    if plan_promotions(permuted) != got:
        print(f"PROBLEM {name}: provider ordering changes planner output")

merge = json.loads((cases / "merge-across-rules.input.json").read_text())
merge["observations"][1].pop("location", None)
location = plan_promotions(merge)["candidates"][0]["occurrences"][0].get("location")
if location is not None:
    print("PROBLEM merged observations with partial location evidence claim an agreed location")

off_catalog = json.loads((cases / "merge-across-rules.input.json").read_text())
off_catalog["rule_violation_types"] = {
    rule: "code:invented" for rule in off_catalog["rule_violation_types"]
}
off_catalog["resolved_guides"]["code:invented"] = off_catalog["resolved_guides"].pop(
    "code:swallowed-exception"
)
off_catalog_plan = plan_promotions(off_catalog)
if off_catalog_plan["candidates"] or not all(
    item["reason"] == "uncatalogued_violation_type"
    for item in off_catalog_plan.get("rejected", [])
):
    print("PROBLEM planner emitted or misclassified an off-catalog candidate")
print(f"COUNT {len(names)}")
PY
) > "$TMP/out" 2>&1
status=$?
if [ "$status" -ne 0 ] || ! terminated; then
    fail "planner replays every frozen case" "    replay exited $status without a COUNT line:
$(sed 's/^/    /' "$TMP/out")"
else
    problems=$(grep '^PROBLEM' "$TMP/out" || true)
    if [ -z "$problems" ]; then
        pass "planner replays every frozen case ($(awk '/^COUNT/{print $2}' "$TMP/out") cases)"
    else
        fail "planner replays every frozen case" "$(printf '%s\n' "$problems" | sed 's/^PROBLEM /    /')"
    fi
fi

# ── purity ────────────────────────────────────────────────────────────────────
python3 "$PURITY" "$PACKAGE" > "$TMP/out" 2>&1
status=$?
if [ "$status" -ne 0 ] || ! terminated; then
    fail "pure package imports nothing that reaches outside its arguments" \
        "    scanner exited $status without a COUNT line:
$(sed 's/^/    /' "$TMP/out")"
else
    problems=$(grep '^PROBLEM' "$TMP/out" || true)
    if [ -z "$problems" ]; then
        pass "pure package imports nothing that reaches outside its arguments"
    else
        fail "pure package imports nothing that reaches outside its arguments" \
            "$(printf '%s\n' "$problems" | sed 's/^PROBLEM /    /')"
    fi
fi

# ── negative controls on the purity scanner ───────────────────────────────────
# A scanner that stopped checking passes the case above and fails all of these.
expect_impurity() {
    local label="$1" fragment="$2" line="$3" work="$TMP/pkg"
    rm -rf "$work"; mkdir -p "$work/weave_coaching"
    cp "$PACKAGE"/*.py "$work/weave_coaching/"
    printf '%s\n' "$line" >> "$work/weave_coaching/planner.py"
    python3 "$PURITY" "$work/weave_coaching" > "$TMP/out" 2>&1
    local scan_status=$?
    if [ "$scan_status" -ne 0 ] || ! terminated; then
        fail "$label" "    scanner crashed (exit $scan_status) instead of reporting the import"
        return
    fi
    if grep -qF -- "$fragment" "$TMP/out"; then
        pass "$label"
    else
        fail "$label" "    expected a problem mentioning: $fragment
$(sed 's/^/    /' "$TMP/out")"
    fi
}

expect_impurity "a database import is refused" "database access" "import sqlite3"
expect_impurity "a filesystem import is refused" "filesystem access" "from pathlib import Path"
expect_impurity "a provider import is refused" "provider package" "from weave_quality import db"
expect_impurity "a subprocess import is refused" "process execution" "import subprocess"
expect_impurity "a dynamic import is refused" "dynamic import" "__import__('sqlite3')"
expect_impurity "a bare open() is refused" "open() is filesystem access" "open('/etc/hostname')"

# An empty package would make the scan vacuously clean; it must say so instead.
rm -rf "$TMP/empty"; mkdir -p "$TMP/empty"
python3 "$PURITY" "$TMP/empty" > "$TMP/out" 2>&1
if grep -q 'purity scan would be vacuous' "$TMP/out"; then
    pass "an empty package is reported, not passed"
else
    fail "an empty package is reported, not passed" \
        "    a scan with nothing to scan must not read as clean"
fi

# A missing package is refused by name and never reaches a COUNT line; without
# the check it fell through to the empty-package report above (wv-e07ee4).
python3 "$PURITY" "$TMP/definitely-absent" > "$TMP/out" 2>&1
if grep -q 'not a package directory' "$TMP/out" && ! terminated; then
    pass "a missing package fails closed"
else
    fail "a missing package fails closed" \
        "    a package path that does not exist must stop the scan"
fi

# ── the inner boundary ────────────────────────────────────────────────────────
# weave_quality/guides.py READS THE FILESYSTEM by design, so it is not held to
# the pure package's rules. It is held to one: guide resolution may not acquire
# the quality database. Only coaching_evidence may, and keeping that true is
# what stops "the provider owns quality.db" being a sentence rather than a fact.
python3 - "$ROOT" > "$TMP/out" 2>&1 <<'INNERPY'
import ast, sys
from pathlib import Path

module = Path(sys.argv[1]) / "scripts/weave_quality/guides.py"
if not module.is_file():
    print(f"PROBLEM {module} is missing")
else:
    tree = ast.parse(module.read_text(encoding="utf-8"), filename=str(module))
    for node in ast.walk(tree):
        names = []
        if isinstance(node, ast.Import):
            names = [alias.name for alias in node.names]
        elif isinstance(node, ast.ImportFrom):
            base = node.module or ""
            names = [base] + [f"{base}.{alias.name}" for alias in node.names]
        for name in names:
            root = name.split(".")[0]
            if root == "sqlite3" or name.split(".")[-1] == "db":
                print(f"PROBLEM guides.py:{node.lineno}: imports {name!r}; only "
                      "coaching_evidence may reach the quality database")
print("COUNT 1")
INNERPY
status=$?
if [ "$status" -ne 0 ] || ! terminated; then
    fail "guide resolution cannot reach the quality database" \
        "    inner-boundary scan exited $status without a COUNT line"
elif grep -q '^PROBLEM' "$TMP/out"; then
    fail "guide resolution cannot reach the quality database" \
        "$(grep '^PROBLEM' "$TMP/out" | sed 's/^PROBLEM /    /')"
else
    pass "guide resolution cannot reach the quality database"
fi

# ── the resolution chain ──────────────────────────────────────────────────────
(cd "$ROOT" && python3 tests/lib/coaching-resolution-scan.py) > "$TMP/out" 2>&1
status=$?
if [ "$status" -ne 0 ] || ! terminated; then
    fail "guide resolution follows its contract" \
        "    resolver scan exited $status without a COUNT line:
$(sed 's/^/    /' "$TMP/out")"
else
    problems=$(grep '^PROBLEM' "$TMP/out" || true)
    if [ -z "$problems" ]; then
        pass "guide resolution follows its contract ($(awk '/^COUNT/{print $2}' "$TMP/out") assertions)"
    else
        fail "guide resolution follows its contract" "$(printf '%s\n' "$problems" | sed 's/^PROBLEM /    /')"
    fi
fi

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
[ "$TESTS_FAILED" -eq 0 ]
