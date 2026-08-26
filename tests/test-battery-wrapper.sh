#!/bin/bash
# Suite-driven wv calls are tagged test so call-stats retro reads exclude them.
export WV_CALL_SOURCE=test
# test-battery-wrapper.sh — Tier 0 acceptance gate for the Tier 2 restricted-SSH
# wrapper (scripts/wv-battery-wrapper). Drives the wrapper directly via
# $SSH_ORIGINAL_COMMAND (no SSH needed) and asserts the SPEC §9 security
# contract: malicious / malformed scenario ids are REFUSED with no fixture
# created and no live-graph touch; a known-good id RUNS and returns a
# schema-valid envelope. Resolves gap3 (injection) regression coverage.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WRAPPER="$REPO_ROOT/scripts/wv-battery-wrapper"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
ok() {
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "  ${GREEN}✓${NC} $1"
}
fail() {
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -e "  ${RED}✗${NC} $1 — $2"
}

# ─── Fixture scenario manifest (one known-good scenario) ──────────────────────
MANIFEST_DIR="$(mktemp -d /tmp/battery-manifest-XXXXXX)"
printf '{"id":"graph-tree-truncation","tier":"live","setup":"fixture_over_50_nodes"}\n' \
    >"$MANIFEST_DIR/scenarios.jsonl"
export WV_BATTERY_SCENARIOS="$MANIFEST_DIR"

# Marker path used to prove command substitution / chaining never executes.
PWNED="$MANIFEST_DIR/PWNED"

# Run the wrapper with a given $SSH_ORIGINAL_COMMAND; capture stdout + rc.
# Each run uses its own TMPDIR so we can assert no fixture leaks on refusal.
run_wrapper() {
    local cmd="$1"
    RUN_TMP="$(mktemp -d /tmp/battery-run-XXXXXX)"
    OUT="$(SSH_ORIGINAL_COMMAND="$cmd" TMPDIR="$RUN_TMP" bash "$WRAPPER" 2>/dev/null)"
    RC=$?
    return 0
}

# Assert a refusal: non-zero rc, JSON error on stdout, no fixture dir created.
assert_refused() {
    local label="$1" cmd="$2"
    run_wrapper "$cmd"
    local leaked
    leaked="$(find "$RUN_TMP" -maxdepth 1 -name 'wv-battery-*' 2>/dev/null | wc -l)"
    if [ "$RC" -ne 0 ] \
        && echo "$OUT" | jq -e '.error' >/dev/null 2>&1 \
        && [ "$leaked" -eq 0 ] \
        && [ ! -e "$PWNED" ]; then
        ok "$label"
    else
        fail "$label" "rc=$RC leaked=$leaked pwned=$([ -e "$PWNED" ] && echo yes || echo no) out=$OUT"
    fi
    rm -rf "$RUN_TMP"
}

echo "── Tier 0: malicious / malformed scenario ids must be refused ──"
assert_refused "T1  command chaining"        'graph-tree-truncation; rm -rf ~'
assert_refused "T2  command substitution \$()" '$(touch '"$PWNED"')'
assert_refused "T3  command substitution backtick" '`touch '"$PWNED"'`'
assert_refused "T4  path traversal"          '../../etc/passwd'
assert_refused "T5  nested traversal"        'id/../../../foo'
assert_refused "T6  too many tokens"         'a b c'
assert_refused "T7  uppercase"               'UPPER'
assert_refused "T8  embedded space token"    'has space'
assert_refused "T9  pipe metachar"           'foo|bar'
assert_refused "T10 over-length (65 chars)"  "$(printf 'a%.0s' {1..65})"
assert_refused "T11 well-formed but unknown" 'not-a-real-scenario'
assert_refused "T12 empty command"           ''

echo "── Tier 0: fail-closed configuration ──"
# Unknown scenario when manifest dir is unset → refuse "not configured".
run_wrapper_noscen() {
    RUN_TMP="$(mktemp -d /tmp/battery-run-XXXXXX)"
    OUT="$(SSH_ORIGINAL_COMMAND="graph-tree-truncation" TMPDIR="$RUN_TMP" \
        WV_BATTERY_SCENARIOS="" bash "$WRAPPER" 2>/dev/null)"
    RC=$?
    rm -rf "$RUN_TMP"
}
run_wrapper_noscen
{ [ "$RC" -ne 0 ] && echo "$OUT" | jq -e '.error' >/dev/null 2>&1; } \
    && ok "T13 fail-closed when manifest unconfigured" \
    || fail "T13 manifest-unset not refused" "rc=$RC out=$OUT"

echo "── Tier 0: known-good id runs and returns a schema-valid envelope ──"
run_wrapper "graph-tree-truncation"
if [ "$RC" -eq 0 ] \
    && echo "$OUT" | jq -e '.schema == "battery-envelope.v1"' >/dev/null 2>&1 \
    && echo "$OUT" | jq -e '.scenario_id == "graph-tree-truncation"' >/dev/null 2>&1 \
    && echo "$OUT" | jq -e '.tier == "live"' >/dev/null 2>&1 \
    && echo "$OUT" | jq -e 'has("result") and has("graph_commit") and (.toolchain.wv_version != null) and (.toolchain.contract_version == "battery-envelope.v1")' >/dev/null 2>&1; then
    ok "T14 good id → valid envelope"
else
    fail "T14 envelope invalid" "rc=$RC out=$OUT"
fi
rm -rf "$RUN_TMP"

# Envelope must NOT leak forbidden fields (redaction allowlist).
run_wrapper "graph-tree-truncation"
if echo "$OUT" | jq -e 'has("prompt") or has("transcript") or has("token") or has("api_key")' >/dev/null 2>&1; then
    fail "T15 redaction" "envelope contains a forbidden field: $OUT"
else
    ok "T15 envelope carries no prompt/transcript/token/api_key"
fi
rm -rf "$RUN_TMP"

# Optional second token (provider profile) accepted when well-formed. This is a
# graph-only transport run, so the envelope's provider_profile is null regardless.
run_wrapper "graph-tree-truncation openai-compatible"
{ [ "$RC" -eq 0 ] && echo "$OUT" | jq -e '.provider_profile == null' >/dev/null 2>&1; } \
    && ok "T16 well-formed second token accepted; transport envelope provider_profile=null" \
    || fail "T16 provider profile" "rc=$RC out=$OUT"
rm -rf "$RUN_TMP"

# Bad provider profile (second token) rejected.
assert_refused "T17 malformed provider profile" 'graph-tree-truncation bad;profile'

# Canonical battery-envelope.v1 field contract (mirrors weave-runtime
# tests/evals/schema/envelope.v1.json): all required keys present, no key outside
# the allowlist (redaction guard), toolchain pinned.
run_wrapper "graph-tree-truncation"
_allowed='["schema","scenario_id","tier","provider_profile","endpoint_kind","model_id","model_quant","backend","result","compliance","assertions_skipped","toolchain","runtime_commit","graph_commit","started_at","finished_at","session_ref"]'
if echo "$OUT" | jq -e --argjson allowed "$_allowed" '
        ((["schema","scenario_id","tier","provider_profile","endpoint_kind","model_id","result","toolchain","started_at","finished_at"] - keys) | length == 0)
        and ([keys[] | select(. as $k | $allowed | index($k) | not)] | length == 0)
        and (.toolchain | has("python") and has("os_arch") and (.contract_version == "battery-envelope.v1"))
    ' >/dev/null 2>&1; then
    ok "T18 envelope conforms to canonical battery-envelope.v1 field contract"
else
    fail "T18 envelope field contract" "out=$OUT"
fi
rm -rf "$RUN_TMP"

rm -rf "$MANIFEST_DIR"

echo ""
echo "════════════════════════════════════════"
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
if [ "$TESTS_PASSED" -eq "$TESTS_RUN" ]; then
    echo -e "${GREEN}ALL TESTS PASSED${NC}"
else
    echo -e "${RED}SOME TESTS FAILED${NC}"
    exit 1
fi
