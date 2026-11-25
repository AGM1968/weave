#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# status has one authority (wv-38825f): contracts/node-field-registry-v1.json.
# The CLI writes blocked-external, which the contract, the Delta v2 schema, the
# writer and the replayer did not admit, so every move into or out of it fell
# back to an SQL-only delta with only a stderr warning (2026-10-26: wv-6fc913
# lost its v2 sidecar). Same class as risk_level (wv-c0c51e). The writer, the
# replayer and the schema enforce the contract's enum exactly; every status the
# CLI can write must be in it ('ready' stays: recorded E6 evidence carries it).
set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WV="$ROOT/scripts/wv"
run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; return 0; }
TMP=$(mktemp -d /tmp/wv-status-authority-XXXXXX)
trap 'rm -rf "$TMP"' EXIT

echo "=== one authority ==="
contract=$(jq -r '.fields.status.value.enum | sort | join(" ")' "$ROOT/contracts/node-field-registry-v1.json")
schema=$(jq -r '."$defs".status_value.enum | sort | join(" ")' "$ROOT/contracts/delta-operation-v2.schema.json")
cli=$(bash -c '. "$1/scripts/lib/wv-validate.sh" >/dev/null 2>&1; printf "%s\n" $VALID_STATUSES' _ "$ROOT" | sort | paste -sd' ' -)
writer=$(grep -oE '^STATUSES = \{[^}]*\}' "$ROOT/scripts/lib/wv-delta.sh" | grep -oE '"[a-z-]+"' | tr -d '"' | sort | paste -sd' ' -)
replayer=$(grep -oE '^STATUSES = \{[^}]*\}' "$ROOT/scripts/lib/wv-delta-v2-replay.py" | grep -oE '"[a-z-]+"' | tr -d '"' | sort | paste -sd' ' -)
[ -n "$contract" ] && [ "$schema" = "$contract" ] && ok "the Delta v2 schema's status enum is the contract's ($contract)" ||
    bad "the Delta v2 schema's status enum is the contract's" "contract=[$contract] schema=[$schema]"
[ "$writer" = "$contract" ] && ok "the Delta v2 writer enforces the contract's enum" ||
    bad "the Delta v2 writer enforces the contract's enum" "writer=[$writer]"
[ "$replayer" = "$contract" ] && ok "the Delta v2 replayer enforces the contract's enum" ||
    bad "the Delta v2 replayer enforces the contract's enum" "replayer=[$replayer]"
outside=""
for s in $cli; do [[ " $contract " == *" $s "* ]] || outside="$outside $s"; done
[ -n "$cli" ] && [ -z "$outside" ] && ok "every status the CLI writes is in the contract ($cli)" ||
    bad "every status the CLI writes is in the contract" "outside:[$outside]"

echo "=== a move into and out of blocked-external keeps its sidecar ==="
R="$TMP/repo"; mkdir -p "$R" "$TMP/cfg"
git -C "$R" init -q . && git -C "$R" config user.email t@t && git -C "$R" config user.name t
w() { (cd "$R" && WEAVE_DIR="$R/.weave" WV_HOT_ZONE="$TMP/hot" WV_CONFIG_DIR="$TMP/cfg" "$WV" "$@"); }
w init >/dev/null 2>&1
# Sidecars are written when deltas are staged, which wv update does through its
# auto-sync, so a step is judged on the combined output of the update and a sync.
step_warns() { local out; out=$( { w "$@"; w sync; } 2>&1 ); [[ "$out" == *"sidecar write failed"* ]]; }
sidecars() { grep -l "$1" "$R"/.weave/deltas/*/v2/*.json 2>/dev/null | wc -l; }
id=$(w add "held outside the project" --standalone 2>/dev/null | grep -oE 'wv-[a-f0-9]{6}' | sed -n 1p)
step_warns status && bad "a clean baseline syncs with its sidecar" || ok "a clean baseline syncs with its sidecar"
step_warns update "$id" --status=blocked-external &&
    bad "todo -> blocked-external writes its sidecar" || ok "todo -> blocked-external writes its sidecar"
[ "$(sidecars '"value":"blocked-external"')" -ge 1 ] && ok "the sidecar carries the blocked-external patch" ||
    bad "the sidecar carries the blocked-external patch"
# Whether the release is written as a status patch or a re-emitted node_create
# depends on the node's delta history (here it is a node_create at todo), so
# only that it writes cleanly is asserted; the patch above and the create
# below are the cases the unfixed enums refused.
step_warns update "$id" --status=todo &&
    bad "blocked-external -> todo writes its sidecar" || ok "blocked-external -> todo writes its sidecar"
created=$( { w add "born held" --standalone --status=blocked-external; w sync; } 2>&1 )
[[ "$created" != *"sidecar write failed"* ]] && ok "a node created blocked-external writes its sidecar" ||
    bad "a node created blocked-external writes its sidecar" "$created"

echo "=== a failed sidecar names its cause ==="
# Plant a status no layer admits, so the writer refuses; the warning must carry
# the writer's error line, not only the outcome (wv-38825f).
odd=$(w add "odd status" --standalone 2>/dev/null | grep -oE 'wv-[a-f0-9]{6}' | sed -n 1p)
w sync >/dev/null 2>&1
sqlite3 "$TMP/hot/brain.db" "UPDATE nodes SET status='no-such-status' WHERE id='$odd';"
warned=$(w sync 2>&1)
[[ "$warned" == *"sidecar write failed (ValueError: "*"status must be a stable lifecycle value)"* ]] &&
    ok "the warning names the writer's error" || bad "the warning names the writer's error" "$warned"
[[ "$warned" != *"Traceback"* ]] && ok "the traceback is folded into the one-line cause" ||
    bad "the traceback is folded into the one-line cause"

echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
