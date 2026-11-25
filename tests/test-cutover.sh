#!/usr/bin/env bash
# test-cutover.sh — cmd_cutover (wv-2448dd) stamps .weave/causal-cutover, the
# one operation in the delta path that can lose data: once committed, every
# v1 SQL delta with no lineage header becomes permanently unreplayable. It had
# zero dedicated test coverage (surfaced by the rc.11 command-surface battery's
# coverage guard and by pattern-audit Check 1's cache-classification check,
# both failing on the "cutover" dispatch entry) despite that risk profile.
# Covers: refuses at lineage_seq 0, stamps at >=1, --json shapes for both,
# re-stamp without --force is a no-op that leaves the marker untouched,
# --force restamps at the current high-water, the active-claim coordination
# gate and its --force override, and the interactive confirmation prompt.

set -eu
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
export WV_CALL_SOURCE=test

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$REPO_ROOT/scripts/wv"

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
export WV_HOT_ZONE="$TEST_DIR/hot"
WV_DB="$TEST_DIR/hot/brain.db"
export WEAVE_DIR="$TEST_DIR/.weave"
export WV_PROJECT_DIR="$TEST_DIR"
export WV_AGENT_ID="cutover-test-agent"
export WV_REQUIRE_LEARNING=0
export WV_AUTO_CHECKPOINT=0
export WV_NONINTERACTIVE=1
mkdir -p "$WV_HOT_ZONE" "$WEAVE_DIR"
cd "$TEST_DIR"
git init -q 2>/dev/null || true
git config user.email "cutover@test.local" 2>/dev/null || true
git config user.name "cutover" 2>/dev/null || true

pass=0; run=0
ok()  { echo "  ✓ $1"; pass=$((pass + 1)); run=$((run + 1)); }
bad() { echo "  ✗ $1"; run=$((run + 1)); }
marker="$WEAVE_DIR/causal-cutover"

"$WV" init >/dev/null 2>&1

# ─────────────────────────────────────────────────────────────────────────
echo "--- refuses at lineage_seq 0 ---"
rc=0
out=$("$WV" cutover --yes 2>&1) || rc=$?
[ "$rc" -ne 0 ] && [ ! -f "$marker" ] \
    && ok "refuses when lineage high-water is 0, writes no marker" \
    || bad "should refuse at lineage_seq 0 (rc=$rc, marker exists=$([ -f "$marker" ] && echo yes || echo no))"

rc=0
json_out=$("$WV" cutover --yes --json 2>/dev/null) || rc=$?
[ "$rc" -ne 0 ] && [ -z "$json_out" ] \
    && ok "--json also refuses at lineage_seq 0 with no stdout payload" \
    || bad "--json path did not refuse cleanly at lineage_seq 0 (rc=$rc out=$json_out)"

# ─────────────────────────────────────────────────────────────────────────
echo "--- do tracked work to advance lineage ---"
id1_out=$("$WV" add "cutover node one" --status=active --criteria=c --risks=low 2>&1)
id1=$(sed -nE '/^✓ (wv-[a-f0-9]{6}): /{s/^✓ (wv-[a-f0-9]{6}): .*/\1/p;q;}' <<< "$id1_out")
"$WV" "done" "$id1" --skip-verification >/dev/null 2>&1 || true
"$WV" sync >/dev/null 2>&1
seq_now=$(sqlite3 "$WV_DB" "SELECT COALESCE(MAX(lineage_seq),0) FROM nodes;" 2>/dev/null || echo 0)
[ "${seq_now:-0}" -ge 1 ] 2>/dev/null \
    && ok "tracked work advanced lineage_seq to $seq_now" \
    || bad "fixture setup did not advance lineage_seq (got '$seq_now')"

# ─────────────────────────────────────────────────────────────────────────
echo "--- stamps at lineage_seq >= 1 ---"
rc=0
out=$("$WV" cutover --yes 2>&1) || rc=$?
[ "$rc" -eq 0 ] && [ -f "$marker" ] \
    && ok "stamps the marker when lineage high-water is >= 1" \
    || bad "should have stamped (rc=$rc, marker exists=$([ -f "$marker" ] && echo yes || echo no)): $out"

schema_ok=$(python3 -c "
import json
try:
    d = json.load(open('$marker'))
    ok = (d.get('schema') == 'weave.causal-cutover.v1'
          and isinstance(d.get('lineage_seq'), int) and d['lineage_seq'] >= 1
          and isinstance(d.get('actor'), str) and d.get('actor')
          and isinstance(d.get('created_at'), str))
    print('yes' if ok else 'no')
except Exception as e:
    print('no')
" 2>/dev/null)
[ "$schema_ok" = "yes" ] \
    && ok "marker carries schema/lineage_seq/actor/created_at" \
    || bad "marker JSON shape is wrong: $(cat "$marker" 2>/dev/null)"

stamped_seq=$(sed -n 's/.*"lineage_seq"[[:space:]]*:[[:space:]]*\([0-9]\{1,\}\).*/\1/p' "$marker" 2>/dev/null | head -1)

# ─────────────────────────────────────────────────────────────────────────
echo "--- --json stamped shape ---"
rm -f "$marker"
rc=0
json_out=$("$WV" cutover --yes --json 2>/dev/null) || rc=$?
status_field=$(printf '%s' "$json_out" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
[ "$rc" -eq 0 ] && [ "$status_field" = "stamped" ] \
    && ok "--json reports status=stamped on a fresh stamp" \
    || bad "--json stamped shape wrong (rc=$rc status='$status_field'): $json_out"

# ─────────────────────────────────────────────────────────────────────────
echo "--- re-stamp without --force is a no-op ---"
before_mtime=$(stat -c '%Y' "$marker" 2>/dev/null || stat -f '%m' "$marker" 2>/dev/null)
rc=0
out=$("$WV" cutover --yes 2>&1) || rc=$?
after_mtime=$(stat -c '%Y' "$marker" 2>/dev/null || stat -f '%m' "$marker" 2>/dev/null)
[ "$rc" -eq 0 ] && [ "$before_mtime" = "$after_mtime" ] \
    && ok "re-running without --force leaves the existing marker untouched" \
    || bad "re-stamp without --force should be a no-op (rc=$rc, mtime $before_mtime -> $after_mtime)"

rc=0
json_out=$("$WV" cutover --yes --json 2>/dev/null) || rc=$?
status_field=$(printf '%s' "$json_out" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
[ "$rc" -eq 0 ] && [ "$status_field" = "exists" ] \
    && ok "--json reports status=exists when already stamped" \
    || bad "--json exists shape wrong (rc=$rc status='$status_field'): $json_out"

# ─────────────────────────────────────────────────────────────────────────
echo "--- --force restamps at the current high-water ---"
id2_out=$("$WV" add "cutover node two" --status=active --criteria=c --risks=low 2>&1)
id2=$(sed -nE '/^✓ (wv-[a-f0-9]{6}): /{s/^✓ (wv-[a-f0-9]{6}): .*/\1/p;q;}' <<< "$id2_out")
"$WV" "done" "$id2" --skip-verification >/dev/null 2>&1 || true
"$WV" sync >/dev/null 2>&1
rc=0
out=$("$WV" cutover --yes --force 2>&1) || rc=$?
new_seq=$(sed -n 's/.*"lineage_seq"[[:space:]]*:[[:space:]]*\([0-9]\{1,\}\).*/\1/p' "$marker" 2>/dev/null | head -1)
[ "$rc" -eq 0 ] && [ -n "$new_seq" ] && [ "$new_seq" -gt "$stamped_seq" ] 2>/dev/null \
    && ok "--force restamps at a higher lineage_seq ($stamped_seq -> $new_seq)" \
    || bad "--force restamp did not advance lineage_seq (rc=$rc, $stamped_seq -> $new_seq)"

# ─────────────────────────────────────────────────────────────────────────
echo "--- active-claim coordination gate ---"
rm -f "$marker"
id3_out=$("$WV" add "claimed during cutover attempt" --status=todo --criteria=c --risks=low 2>&1)
id3=$(sed -nE '/^✓ (wv-[a-f0-9]{6}): /{s/^✓ (wv-[a-f0-9]{6}): .*/\1/p;q;}' <<< "$id3_out")
"$WV" work "$id3" >/dev/null 2>&1
"$WV" sync >/dev/null 2>&1
rc=0
out=$("$WV" cutover --yes 2>&1) || rc=$?
[ "$rc" -ne 0 ] && [ ! -f "$marker" ] \
    && ok "refuses while a node is claimed, writes no marker" \
    || bad "should refuse while a node is claimed (rc=$rc): $out"

rc=0
out=$("$WV" cutover --yes --force 2>&1) || rc=$?
[ "$rc" -eq 0 ] && [ -f "$marker" ] \
    && ok "--force overrides the active-claim coordination gate" \
    || bad "--force should override the claim gate (rc=$rc): $out"
"$WV" "done" "$id3" --skip-verification >/dev/null 2>&1 || true

# ─────────────────────────────────────────────────────────────────────────
echo "--- interactive confirmation prompt ---"
rm -f "$marker"
rc=0
out=$(printf 'no\n' | "$WV" cutover 2>&1) || rc=$?
[ "$rc" -ne 0 ] && [ ! -f "$marker" ] && grep -qi "abort" <<< "$out" \
    && ok "declining the interactive prompt aborts without stamping" \
    || bad "declining the prompt should abort cleanly (rc=$rc): $out"

rc=0
out=$(printf 'yes\n' | "$WV" cutover 2>&1) || rc=$?
[ "$rc" -eq 0 ] && [ -f "$marker" ] \
    && ok "confirming the interactive prompt stamps the marker" \
    || bad "confirming the prompt should stamp (rc=$rc): $out"

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
