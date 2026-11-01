#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# risk_level has one authority (wv-c0c51e): contracts/node-field-registry-v1.json.
# The CLI accepted 'critical', which the Delta v2 writer rejects and the replayer
# treats as a hard integrity failure, so every later update of such a node fell
# back to an SQL-only delta with only a stderr warning. The CLI now refuses any
# value the contract does not admit, on every path that stores metadata.
set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WV="$ROOT/scripts/wv"
run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; return 0; }
TMP=$(mktemp -d /tmp/wv-risk-level-XXXXXX)
trap 'rm -rf "$TMP"' EXIT

echo "=== one authority ==="
contract=$(jq -r '.fields.risk_level.value.enum | sort | join(" ")' "$ROOT/contracts/node-field-registry-v1.json")
cli=$(bash -c '. "$1/scripts/lib/wv-validate.sh" >/dev/null 2>&1; printf "%s\n" $VALID_RISK_LEVELS' _ "$ROOT" | sort | paste -sd' ')
writer=$(grep -oE '^RISK_LEVELS = \{[^}]*\}' "$ROOT/scripts/lib/wv-delta.sh" | grep -oE '"[a-z]+"' | tr -d '"' | sort | paste -sd' ')
replayer=$(grep -oE '^RISK_LEVELS = \{[^}]*\}' "$ROOT/scripts/lib/wv-delta-v2-replay.py" | grep -oE '"[a-z]+"' | tr -d '"' | sort | paste -sd' ')
[ -n "$contract" ] && [ "$cli" = "$contract" ] && ok "the CLI enum is the contract's ($contract)" ||
    bad "the CLI enum is the contract's" "contract=[$contract] cli=[$cli]"
[ "$writer" = "$contract" ] && ok "the Delta v2 writer enforces the contract's enum" ||
    bad "the Delta v2 writer enforces the contract's enum" "writer=[$writer]"
[ "$replayer" = "$contract" ] && ok "the Delta v2 replayer enforces the contract's enum" ||
    bad "the Delta v2 replayer enforces the contract's enum" "replayer=[$replayer]"
if grep -rqE 'risk_level"?: *"[^"]*critical' "$ROOT/.claude/skills" "$ROOT/templates" 2>/dev/null; then
    bad "no skill or template tells an agent to write risk_level critical"
else
    ok "no skill or template tells an agent to write risk_level critical"
fi

echo "=== every write path refuses a value outside it ==="
R="$TMP/repo"; mkdir -p "$R" "$TMP/cfg"
git -C "$R" init -q . && git -C "$R" config user.email t@t && git -C "$R" config user.name t
w() { (cd "$R" && WEAVE_DIR="$R/.weave" WV_HOT_ZONE="$TMP/hot" WV_CONFIG_DIR="$TMP/cfg" "$WV" "$@"); }
DB="$TMP/hot/brain.db"
w init >/dev/null 2>&1
count() { sqlite3 "$DB" "SELECT COUNT(*) FROM nodes;"; }
before=$(count)
out=$(w add "critical via flag" --standalone --risks=critical 2>&1); rc=$?
[ "$rc" != 0 ] && [ "$(count)" = "$before" ] && [[ "$out" == *"--risks must be one of none|low|medium|high"* ]] &&
    ok "wv add --risks=critical is refused and stores nothing" || bad "wv add --risks=critical is refused and stores nothing" "rc=$rc $out"
out=$(w add "critical via metadata" --standalone --metadata='{"risk_level":"critical"}' 2>&1); rc=$?
[ "$rc" != 0 ] && [ "$(count)" = "$before" ] && [[ "$out" == *"risk_level must be one of"* ]] &&
    ok "wv add --metadata risk_level=critical is refused" || bad "wv add --metadata risk_level=critical is refused" "rc=$rc $out"
id=$(w add "a high-risk node" --standalone --risks=high 2>/dev/null | grep -oE 'wv-[a-f0-9]{6}' | sed -n 1p)
[ "$(sqlite3 "$DB" "SELECT json_extract(metadata,'\$.risk_level') FROM nodes WHERE id='$id';")" = high ] &&
    ok "a contract value is stored" || bad "a contract value is stored"
out=$(w update "$id" --metadata='{"risk_level":"critical"}' 2>&1); rc=$?
[ "$rc" != 0 ] && [ "$(sqlite3 "$DB" "SELECT json_extract(metadata,'\$.risk_level') FROM nodes WHERE id='$id';")" = high ] &&
    ok "wv update --metadata risk_level=critical is refused and changes nothing" || bad "wv update --metadata risk_level=critical is refused" "rc=$rc $out"
echo '{"risk_level":"critical"}' > "$TMP/meta.json"
out=$(w update "$id" --metadata-file="$TMP/meta.json" 2>&1); rc=$?
[ "$rc" != 0 ] && ok "wv update --metadata-file risk_level=critical is refused" || bad "wv update --metadata-file risk_level=critical is refused" "rc=$rc $out"
out=$(w update "$id" --metadata='{"note":"unrelated"}' 2>&1); rc=$?
[ "$rc" = 0 ] && ok "a patch that does not touch risk_level is unaffected" || bad "a patch that does not touch risk_level is unaffected" "$out"

echo "=== a legacy value is why the migration was needed ==="
# Sidecars are written when deltas are staged, which wv update does through its
# auto-sync, so a step is judged on the combined output of the update and a sync.
# step_warns <wv-args...>: 0 when that step fell back to an SQL-only delta.
step_warns() { local out; out=$( { w "$@"; w sync; } 2>&1 ); [[ "$out" == *"sidecar write failed"* ]]; }
sync_warns() { step_warns status; }
legacy=$(w add "legacy critical node" --standalone --risks=low 2>/dev/null | grep -oE 'wv-[a-f0-9]{6}' | sed -n 1p)
sync_warns && bad "a clean baseline syncs with its sidecar" || ok "a clean baseline syncs with its sidecar"
# Plant the value the CLI used to accept, as the 25 migrated nodes carried it.
# Whether the next sidecar degrades depends on the node's delta history (a
# sugar patch reads the enum, a re-emitted node_create does not), so the
# defect itself is not asserted here; what is asserted is that the migration
# and every later update of the node write clean sidecars.
sqlite3 "$DB" "UPDATE nodes SET metadata=json_set(metadata,'\$.risk_level','critical') WHERE id='$legacy';"
sync_warns >/dev/null || true
# The migration records its provenance, which also makes it a full metadata
# patch rather than a sugar patch that would read the old value.
step_warns update "$legacy" --metadata='{"risk_level":"high","risk_level_migrated_from":"critical"}' &&
    bad "the migration itself syncs with a clean sidecar" || ok "the migration itself syncs with a clean sidecar"
[ "$(sqlite3 "$DB" "SELECT json_extract(metadata,'\$.risk_level') || '/' || json_extract(metadata,'\$.risk_level_migrated_from') FROM nodes WHERE id='$legacy';")" = "high/critical" ] &&
    ok "the migration keeps its provenance" || bad "the migration keeps its provenance"
step_warns update "$legacy" --metadata='{"claimed_by":"someone"}' >/dev/null || true
step_warns update "$legacy" --remove-key=claimed_by && bad "migrated, the node round-trips the same claim release with no sidecar failure" ||
    ok "migrated, the node round-trips the same claim release with no sidecar failure"

echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
