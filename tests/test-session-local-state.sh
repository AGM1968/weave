#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# Session identity S2 (wv-43d6be): ownership-sensitive workflow state is per
# owner. Two sessions in one checkout share the hot zone and its database, but:
#   - each has its own primary node, phase and context stamps
#     ($hot_zone/owners/<resolved agent id>/), and the root files are never read
#   - only the caller's own active claims admit an edit
#   - an unverifiable session has no primary and is refused an edit
#   - a hook whose process lacks the harness session variable adopts the
#     payload's session_id and resolves the same owner as the shell
#   - the database stays shared: both sessions see every node
set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WV="$ROOT/scripts/wv"
run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
TMP=$(mktemp -d /tmp/wv-session-local-XXXXXX)
trap 'rm -rf "$TMP"' EXIT
R="$TMP/repo"; mkdir -p "$R" "$TMP/cfg"
git -C "$R" init -q . && git -C "$R" config user.email t@t && git -C "$R" config user.name t
export WV_ATTEMPT_JOURNAL="$TMP/journal.jsonl"
HOT="$TMP/hot"
HOST=$(hostname); ME=$(whoami)
dig() { printf '%s' "$1" | sha256sum | cut -c1-16; }

# as <env assignments...> -- <wv args...>: run wv with ONLY the given identity
# markers, whatever session runs this suite. Stdin passes through (hook payloads).
as() {
    local envs=()
    while [ "$1" != "--" ]; do envs+=("$1"); shift; done
    shift
    (cd "$R" && env -u WV_AGENT_ID -u CLAUDECODE -u AI_AGENT -u CLAUDE_CODE_SSE_PORT -u CLAUDE_CODE_SESSION_ID \
        -u CODEX_THREAD_ID -u CODEX_CI -u COPILOT_AGENT -u WV_SESSION_ID -u WV_SESSION_IDENTITY -u WV -u WV_CLI \
        -u WV_PRIMARY_FILE "${envs[@]}" WEAVE_DIR="$R/.weave" WV_HOT_ZONE="$HOT" WV_CONFIG_DIR="$TMP/cfg" \
        "$WV" "$@")
}
SID_A=aaaaaaaa-1111-2222-3333-444444444444
SID_B=bbbbbbbb-1111-2222-3333-444444444444
SID_C=cccccccc-1111-2222-3333-444444444444
A=(CLAUDECODE=1 "CLAUDE_CODE_SESSION_ID=$SID_A")
B=(CLAUDECODE=1 "CLAUDE_CODE_SESSION_ID=$SID_B")
OWNER_A="$HOT/owners/claude-$HOST-$ME-h$(dig "$SID_A")"
OWNER_B="$HOT/owners/claude-$HOST-$ME-h$(dig "$SID_B")"
node() { as -- add "$1" --standalone --criteria="c1" --risks=low </dev/null 2>/dev/null | grep -oE 'wv-[a-f0-9]{6}' | head -1; }
primary_of() { as "$@" -- status </dev/null 2>/dev/null | sed -n 's/^Primary: \(wv-[a-f0-9]*\).*/\1/p'; }
edit_payload() {
    jq -cn --arg sid "$1" --arg f "$R/file.txt" --arg cwd "$R" \
        '{session_id:$sid, cwd:$cwd, hook_event_name:"PreToolUse", tool_name:"Edit",
          tool_input:{file_path:$f, old_string:"a", new_string:"b"}}'
}
as -- init </dev/null >/dev/null 2>&1
echo a > "$R/file.txt"

echo "=== each session keeps its own primary node ==="
na=$(node "session A work"); nb=$(node "session B work")
as "${A[@]}" -- work "$na" </dev/null >/dev/null 2>&1
[ "$(cat "$OWNER_A/primary" 2>/dev/null)" = "$na" ] \
    && ok "session A's primary is written under its owner directory" || bad "A's owner primary" "$(ls -R "$HOT/owners" 2>&1)"
[ ! -e "$HOT/primary" ] && ok "the shared hot-zone root gets no primary file" || bad "no root primary file"
[ "$(primary_of "${A[@]}")" = "$na" ] && ok "session A reports its own claim as Primary" \
    || bad "A's Primary" "got: $(primary_of "${A[@]}")"
[ -z "$(primary_of "${B[@]}")" ] && ok "session B has no Primary while only A holds a claim" \
    || bad "B has no Primary" "got: $(primary_of "${B[@]}")"
as "${B[@]}" -- work "$nb" </dev/null >/dev/null 2>&1
[ "$(primary_of "${A[@]}")" = "$na" ] && [ "$(primary_of "${B[@]}")" = "$nb" ] \
    && ok "B's claim does not move A's Primary" || bad "Primary per session" "A=$(primary_of "${A[@]}") B=$(primary_of "${B[@]}")"
echo "$nb" > "$HOT/primary"
[ "$(primary_of "${A[@]}")" = "$na" ] && ok "a root-level primary file is never read" \
    || bad "root primary ignored" "got: $(primary_of "${A[@]}")"
rm -f "$HOT/primary"

echo "=== each session keeps its own phase ==="
[ "$(cat "$OWNER_A/.session_phase" 2>/dev/null)" = "execute" ] \
    && ok "wv work sets the claimer's phase to execute" || bad "A's phase" "$(cat "$OWNER_A/.session_phase" 2>&1)"
as "${B[@]}" -- "done" "$nb" --skip-verification --learning="pattern: test" </dev/null >/dev/null 2>&1
[ "$(cat "$OWNER_B/.session_phase" 2>/dev/null)" = "closing" ] \
    && ok "wv done sets the closer's phase to closing" || bad "B's phase" "$(cat "$OWNER_B/.session_phase" 2>&1)"
[ "$(cat "$OWNER_A/.session_phase" 2>/dev/null)" = "execute" ] \
    && ok "B's closing phase does not change A's" || bad "A's phase unchanged" "$(cat "$OWNER_A/.session_phase" 2>&1)"
[ ! -e "$HOT/.session_phase" ] && ok "the shared hot-zone root gets no phase file" || bad "no root phase file"

echo "=== only the caller's own claims admit an edit ==="
out=$(edit_payload "$SID_A" | as CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=$SID_A -- hook dispatch --event=PreToolUse --format=host 2>&1); rc=$?
[ "$rc" = 0 ] && ok "session A may edit under its own claim" || bad "A admitted" "rc=$rc $out"
[ -e "$OWNER_A/.context_checked_$na" ] && ok "A's context stamp is written under its owner directory" \
    || bad "A's stamp" "$(ls -a "$OWNER_A" 2>&1)"
# Session C is fresh (no phase file, so execute): admission alone decides.
out=$(edit_payload "$SID_C" | as CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=$SID_C -- hook dispatch --event=PreToolUse --format=host 2>&1); rc=$?
[ "$rc" = 2 ] && [[ "$out" == *"No active Weave node"* ]] \
    && ok "session C is refused an edit while only A holds a claim" || bad "C refused" "rc=$rc $out"
! compgen -G "$HOT/owners/*h$(dig "$SID_C")*" >/dev/null && ok "A's context stamp never appears as C's" \
    || bad "C has no stamp for A's node" "$(ls -aR "$HOT/owners")"

echo "=== a hook without the session variable adopts its payload's ==="
out=$(edit_payload "$SID_A" | as CLAUDECODE=1 -- hook dispatch --event=PreToolUse --format=host 2>&1); rc=$?
[ "$rc" = 0 ] && ok "payload session_id A resolves to A's owner and admits A's edit" || bad "payload adoption A" "rc=$rc $out"
out=$(edit_payload "$SID_C" | as CLAUDECODE=1 -- hook dispatch --event=PreToolUse --format=host 2>&1); rc=$?
[ "$rc" = 2 ] && [[ "$out" == *"No active Weave node"* ]] \
    && ok "payload session_id C does not borrow A's claim" || bad "payload adoption C" "rc=$rc $out"
out=$(edit_payload "$SID_C" | as CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=$SID_A -- hook dispatch --event=PreToolUse --format=host 2>&1); rc=$?
[ "$rc" = 0 ] && ok "a session id already in the environment wins over the payload" || bad "env wins" "rc=$rc $out"

echo "=== an unverifiable session has no primary and cannot edit ==="
[ -z "$(primary_of CLAUDECODE=1)" ] && ok "no session id: no Primary" || bad "unverified Primary" "got: $(primary_of CLAUDECODE=1)"
out=$(jq -cn --arg f "$R/file.txt" '{tool_name:"Edit", tool_input:{file_path:$f}}' \
    | as CLAUDECODE=1 -- hook dispatch --event=PreToolUse --format=host 2>&1); rc=$?
[ "$rc" = 2 ] && [[ "$out" == *"cannot verify"* ]] \
    && ok "no session id anywhere: the edit is refused and the cause named" || bad "unverified edit refused" "rc=$rc $out"
[ ! -d "$HOT/owners/_unverified" ] && ok "nothing is written for an unverifiable owner" || bad "no _unverified dir"

echo "=== status never reports another session's claim ==="
out=$(as CLAUDECODE=1 "CLAUDE_CODE_SESSION_ID=$SID_C" -- status </dev/null 2>&1)
[[ "$out" == *"none claimed by this session"* ]] && [[ "$out" != *"$na"* ]] \
    && ok "session C's status names no node while only A holds a claim" || bad "C status" "$out"
cjson=$(as CLAUDECODE=1 "CLAUDE_CODE_SESSION_ID=$SID_C" -- status --json </dev/null 2>/dev/null | jq -r '.current.id // empty' 2>/dev/null)
[ -z "$cjson" ] && ok "session C's status --json has no primary" || bad "C status --json" "got: $cjson"
rm -f "$OWNER_A/primary"
[ "$(as "${A[@]}" -- status </dev/null 2>/dev/null | sed -n 's/^Current: \(wv-[a-f0-9]*\).*/\1/p')" = "$na" ] \
    && ok "without its primary file, A's status falls back to A's own claim" \
    || bad "A fallback" "$(as "${A[@]}" -- status </dev/null 2>&1 | sed -n 2p)"

echo "=== the database stays shared ==="
seen=$(as "${B[@]}" -- list --all --json </dev/null 2>/dev/null | jq --arg a "$na" --arg b "$nb" '[.[] | select(.id == $a or .id == $b)] | length')
[ "$seen" = "2" ] && ok "session B sees A's node and its own in the one database" || bad "shared DB" "got: $seen"

echo "Results: $pass/$run passed"
[ "$pass" = "$run" ]
