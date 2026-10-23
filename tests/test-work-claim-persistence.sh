#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# wv work reports a claim only when the claim persisted (wv-03d775). The claim
# used to read changes() from a query whose failure it never checked, so a
# write that errored or rolled back (an FTS trigger error in the original
# report) left claim_changes empty, which is not "0", and the call printed
# "Claimed" and exited 0 with the node unchanged. Triggers stand in for the
# failing write here, because the defect is in how the result is read, not in
# what made the write fail.
set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WV="$ROOT/scripts/wv"
run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
TMP=$(mktemp -d /tmp/wv-work-claim-XXXXXX)
trap 'rm -rf "$TMP"' EXIT
R="$TMP/repo"; mkdir -p "$R" "$TMP/cfg"
git -C "$R" init -q . && git -C "$R" config user.email t@t && git -C "$R" config user.name t
export WV_ATTEMPT_JOURNAL="$TMP/journal.jsonl"
w() { (cd "$R" && WEAVE_DIR="$R/.weave" WV_HOT_ZONE="$TMP/hot" WV_CONFIG_DIR="$TMP/cfg" "$WV" "$@") </dev/null; }
DB="$TMP/hot/brain.db"
sq() { sqlite3 -cmd ".timeout 5000" "$DB" "$1"; }
w init >/dev/null 2>&1
node() { w add "$1" --standalone --criteria="c1" --risks=low --alias="$2" 2>/dev/null | grep -oE 'wv-[a-f0-9]{6}' | head -1; }
row() { sq "SELECT status || '|' || COALESCE(json_extract(metadata,'\$.claimed_by'),'') FROM nodes WHERE id='$1';"; }

# refused <label> <node> <expected-row> <wv work args...>
refused() {
    local label="$1" id="$2" want="$3" out rc
    shift 3
    out=$(w work "$id" "$@" 2>&1); rc=$?
    if [ "$rc" != 0 ] && [[ "$out" != *"Claimed"* ]] && [ "$(row "$id")" = "$want" ]; then
        ok "$label"
    else
        bad "$label" "rc=$rc row=$(row "$id") out=$(tr '\n' ' ' <<< "$out" | cut -c1-200)"
    fi
}

echo "=== a claim write that fails is not a claim ==="
a=$(node "claim write fails" claim-fails)
sq "CREATE TRIGGER test_claim_fails BEFORE UPDATE OF status ON nodes
    WHEN NEW.status='active' AND NEW.id='$a'
    BEGIN SELECT RAISE(ABORT, 'simulated FTS write failure'); END;"
refused "an aborted claim write exits nonzero, prints no Claimed, and leaves the node todo" "$a" "todo|"
if jq -e 'select(.event=="non_policy_refusal" and .category=="infrastructure_failure" and (.detail|startswith("claim did not persist")))' "$WV_ATTEMPT_JOURNAL" >/dev/null 2>&1; then
    ok "the failed claim is recorded as an infrastructure failure, not a decision"
else
    bad "the failed claim is recorded as an infrastructure failure, not a decision"
fi
out=$(w work "$a" --json 2>&1); rc=$?
[ "$rc" != 0 ] && [[ "$out" == *'"claim_not_persisted"'* ]] &&
    ok "--json reports claim_not_persisted" || bad "--json reports claim_not_persisted" "rc=$rc $out"
sq "DROP TRIGGER test_claim_fails;"

echo "=== the forced takeover checks its write too ==="
b=$(node "forced claim write fails" forced-fails)
sq "UPDATE nodes SET metadata=json_set(metadata,'\$.claimed_by','another-agent') WHERE id='$b';"
sq "CREATE TRIGGER test_force_fails BEFORE UPDATE OF status ON nodes
    WHEN NEW.status='active' AND NEW.id='$b'
    BEGIN SELECT RAISE(ABORT, 'simulated FTS write failure'); END;"
refused "a forced takeover whose write fails is not reported as a claim" "$b" "todo|another-agent" --force
sq "DROP TRIGGER test_force_fails;"

echo "=== success is read from the row, not assumed ==="
c=$(node "claim silently undone" claim-undone)
sq "CREATE TRIGGER test_claim_undone AFTER UPDATE OF status ON nodes
    WHEN NEW.status='active' AND NEW.id='$c'
    BEGIN UPDATE nodes SET status='todo', metadata=json_remove(metadata,'\$.claimed_by') WHERE id=NEW.id; END;"
refused "a write that reports a change but does not persist is not a claim" "$c" "todo|"
sq "DROP TRIGGER test_claim_undone;"

echo "=== an ordinary claim is unaffected ==="
out=$(w work "$c" 2>&1); rc=$?
[ "$rc" = 0 ] && [[ "$out" == *"Claimed: $c"* ]] && [[ "$(row "$c")" == active\|* ]] &&
    ok "a claim that persists is reported as claimed" || bad "a claim that persists is reported as claimed" "rc=$rc $out"

echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
