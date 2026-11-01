#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# Gate provisioning S4 (wv-0ee3f4), transition rule 5: every route's mode is
# visible and countable. Each gate record carries provisioning {suite: mode},
# reused receipts included, and wv analyze gates and wv doctor count the routes
# whose newest record ran them in checkout mode.
set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WV="$ROOT/scripts/wv"
run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }
TMP=$(mktemp -d /tmp/wv-gate-provisioning-report-XXXXXX)
trap 'rm -rf "$TMP"' EXIT

echo "=== the pool names each selected route's mode ==="
modes() {  # modes <provision-json> <suites-csv>
    bash -c '. "$1/scripts/lib/wv-gate-pool.sh" >/dev/null 2>&1; _GATE_PROVISION="$2"; gate_pool_suite_modes "$3"' \
        _ "$ROOT" "$1" "$2"
}
check "a declared suite is frozen, an undeclared one checkout" \
    "$(modes '{"policy":{"suites":{"tests/a.sh":{}}},"default_mode":"checkout"}' tests/a.sh,tests/b.sh)" \
    "tests/a.sh=frozen,tests/b.sh=checkout"
check "no declaration: every route takes the default mode" \
    "$(modes '{"policy":null,"default_mode":"checkout"}' tests/a.sh)" "tests/a.sh=checkout"
check "before the declaration is read there is nothing to report" "$(modes '' tests/a.sh)" ""
for hook in pre-commit-weave.sh pre-push-weave.sh; do
    grep -q -- '--suite-modes="$(gate_pool_suite_modes ' "$ROOT/scripts/hooks/$hook" &&
        ok "$hook passes the route modes to its gate record" || bad "$hook passes the route modes to its gate record"
done

echo "=== the gate record carries them ==="
R="$TMP/repo"; mkdir -p "$R" "$TMP/cfg"
git -C "$R" init -q . && git -C "$R" config user.email t@t && git -C "$R" config user.name t
w() { (cd "$R" && WEAVE_DIR="$R/.weave" WV_HOT_ZONE="$TMP/hot" WV_CONFIG_DIR="$TMP/cfg" \
        WV_SUITE_LOG="$TMP/suite_runs.jsonl" WV_GATE_LOG="$TMP/gate_runs.jsonl" "$WV" "$@") </dev/null; }
w init >/dev/null 2>&1
record() { w test-record gate --gate --exit=0 --duration=10 --execution-mode="$1" --suites="$2" --suite-modes="$3" >/dev/null 2>&1; }
# An older record without per-route modes, then two that carry them.
record mixed tests/a.sh,tests/b.sh ""
record mixed tests/a.sh,tests/b.sh,tests/c.sh "tests/a.sh=frozen,tests/b.sh=checkout,tests/c.sh=checkout,junk"
record mixed tests/b.sh "tests/b.sh=frozen"
check "the record maps each route to its mode, dropping a malformed entry" \
    "$(sed -n 2p "$TMP/gate_runs.jsonl" | jq -c '.provisioning')" \
    '{"tests/a.sh":"frozen","tests/b.sh":"checkout","tests/c.sh":"checkout"}'
check "a record without modes stays without them" "$(sed -n 1p "$TMP/gate_runs.jsonl" | jq 'has("provisioning")')" "false"

echo "=== wv analyze gates and wv doctor count checkout routes ==="
report=$(w analyze gates --json 2>/dev/null | jq -c '.provisioning')
check "routes take their newest recorded mode" "$(jq -c '{routes, frozen, checkout, checkout_routes}' <<< "$report")" \
    '{"routes":3,"frozen":2,"checkout":1,"checkout_routes":["tests/c.sh"]}'
check "records without modes are counted, not guessed" "$(jq -c '[.gates_recorded, .gates_without_record]' <<< "$report")" "[2,1]"
doctor=$(w doctor --json 2>/dev/null | jq -r '.checks[] | select(.check == "gate provisioning") | "\(.status) \(.detail)"')
case "$doctor" in
    "pass 3 route(s): 2 frozen, 1 in checkout mode (tests/c.sh); declare"*) ok "wv doctor reports the checkout routes" ;;
    *) bad "wv doctor reports the checkout routes" "$doctor" ;;
esac

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
