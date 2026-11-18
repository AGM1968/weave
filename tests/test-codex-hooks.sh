#!/usr/bin/env bash
set -euo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)

export WV_CALL_SOURCE=test

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WV="$ROOT/scripts/wv"
TEST_DIR=$(mktemp -d)
REPO="$TEST_DIR/repo"
HOT="$TEST_DIR/hot"
trap 'cd /tmp; rm -rf "$TEST_DIR"' EXIT

mkdir -p "$REPO/.weave" "$HOT"
git -C "$REPO" init -q
git -C "$REPO" config user.email hooks@test.local
git -C "$REPO" config user.name hooks
cd "$REPO"

export WV_PROJECT_DIR="$REPO"
export WEAVE_DIR="$REPO/.weave"
export WV_HOT_ZONE="$HOT"
export WV_DB="$HOT/brain.db"
export WV_REQUIRE_LEARNING=0
export WV_RUN_CACHE=0
# Session-local state is per owner (wv-43d6be): pin one owner, whatever
# session runs this suite.
export WV_AGENT_ID=test-codex-hooks-agent
OWN="$HOT/owners/$WV_AGENT_ID"
mkdir -p "$OWN"

pass=0
total=0
check() {
    local description="$1"
    shift
    total=$((total + 1))
    if "$@"; then
        pass=$((pass + 1))
        printf 'ok %d - %s\n' "$total" "$description"
    else
        printf 'not ok %d - %s\n' "$total" "$description"
    fi
}

# _jq_ok — run inside check(): a bare `jq -e ... >/dev/null <<<"$var"` argument
# list redirects check()'s own stdout (the ok/not ok line), not just jq's,
# because the redirection binds to the whole `check ...` command. Confining
# jq's own stdin/stdout inside this function keeps check()'s printf visible.
_jq_ok() {
    local input="$1" filter="$2"
    shift 2
    jq -e "$@" "$filter" <<<"$input" >/dev/null 2>&1
}

"$WV" init >/dev/null

set +e
missing_output=$(printf '%s' '{"tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n*** Update File: src/a.py\n*** End Patch"}}' \
    | "$WV" hook dispatch --event=PreToolUse --json)
missing_rc=$?
set -e
check "PreToolUse blocks apply_patch without an active node" \
    test "$missing_rc" -eq 1
check "missing-node decision has stable JSON" _jq_ok "$missing_output" \
    '.decision == "block" and .event == "PreToolUse" and (.reason | contains("No active Weave node"))'

node_id=$("$WV" add "Codex hook fixture" --status=active \
    --criteria="edit guard works|paths are attributed" --risks=low --force --json \
    | jq -r '.id')

allow_output=$(printf '%s' '{"tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n*** Update File: src/a.py\n*** End Patch"}}' \
    | "$WV" hook dispatch --event=PreToolUse --json)
# $id below is a jq variable, not a shell expansion.
# shellcheck disable=SC2016
check "PreToolUse allows apply_patch with an active node" _jq_ok "$allow_output" \
    '.decision == "allow" and .active_node == $id' --arg id "$node_id"

post_output=$(printf '%s' '{"tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n*** Update File: src/a.py\n*** Add File: src/b.py\n*** End Patch"},"tool_response":{"success":true}}' \
    | "$WV" hook dispatch --event=PostToolUse --json)
check "PostToolUse returns an allow decision" _jq_ok "$post_output" \
    '.decision == "allow" and .event == "PostToolUse"'
check "PostToolUse attributes every apply_patch path" \
    test "$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM node_files WHERE node_id='$node_id' AND path IN ('src/a.py','src/b.py');")" -eq 2

printf '%s' '{"tool_name":"Write","tool_input":{"file_path":"src/failed.py"},"tool_response":{"success":false}}' \
    | "$WV" hook dispatch --event=PostToolUse --json >/dev/null
check "PostToolUse does not attribute a failed edit" \
    test "$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM node_files WHERE node_id='$node_id' AND path='src/failed.py';")" -eq 0

set +e
stop_output=$(printf '%s' '{}' | "$WV" hook dispatch --event=Stop --json)
stop_rc=$?
set -e
check "Stop blocks while a node remains active" test "$stop_rc" -eq 1
# $id below is a jq variable, not a shell expansion.
# shellcheck disable=SC2016
check "Stop decision names the active node" _jq_ok "$stop_output" \
    '.decision == "block" and .active_node == $id' --arg id "$node_id"

session_output=$(printf '%s' '{}' | "$WV" hook dispatch --event=SessionStart --json)
# $id below is a jq variable, not a shell expansion.
# shellcheck disable=SC2016
check "SessionStart returns stable active-node JSON" _jq_ok "$session_output" \
    '.decision == "allow" and .event == "SessionStart" and .active_node == $id' --arg id "$node_id"

# ── PreToolUse: installed-path guard blocks edits to ~/.local/bin or ~/.local/lib/weave,
# parity with Claude's pre-action.sh (_hc_check_installed_path). apply_patch headers have
# no file_path/filePath field, so this scans every path _hook_input_paths can extract.
printf 'execute' > "$OWN/.session_phase"
set +e
installed_output=$(printf '%s' '{"tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n*** Update File: /fake/.local/lib/weave/cmd/wv-cmd-hook.sh\n*** End Patch"}}' \
    | "$WV" hook dispatch --event=PreToolUse --json)
installed_rc=$?
set -e
check "PreToolUse blocks edits to the installed Weave copy" test "$installed_rc" -eq 1
check "installed-path decision names the offending path" _jq_ok "$installed_output" \
    '.decision == "block" and (.reason | contains(".local/lib/weave"))'
# The payloads here are the shape Codex sends: tool_name apply_patch with the
# patch as tool_input.command (codex-rs core/src/tools/handlers/apply_patch.rs,
# rust-v0.146.0, for both PreToolUse and PostToolUse). patchText/patch are kept
# as legacy shapes; one case pins that they still parse (wv-d3eb63).
set +e
printf '%s' '{"tool_name":"apply_patch","tool_input":{"patchText":"*** Begin Patch\n*** Update File: /fake/.local/bin/wv\n*** End Patch"}}' \
    | "$WV" hook dispatch --event=PreToolUse --json >/dev/null
legacy_rc=$?
set -e
check "the legacy patchText shape still meets the installed-copy guard" test "$legacy_rc" -eq 1

# ── The same patch in Copilot CLI's shape (wv-c95723): tool_name Edit with the
# patch document as the bare tool_input string (owner canary on Copilot CLI
# 1.0.112, 2026-11-17). Dispatch reads it as the apply_patch observation, so
# the same guards judge it; it used to be refused as malformed even with a claim.
copilot_patch() {
    jq -cn --arg p "$1" '{hook_event_name:"PreToolUse",tool_name:"Edit",tool_use_id:"custom_call_1",tool_input:$p}'
}
# The SessionStart checks above made the fixture node a previous session's
# claim, which the stale-node guard refuses; claim it in this one.
"$WV" work "$node_id" >/dev/null 2>&1
set +e
cp_allow=$(copilot_patch $'*** Begin Patch\n*** Add File: src/c.py\n+alpha\n*** End Patch\n' \
    | "$WV" hook dispatch --event=PreToolUse --json)
set -e
# $id below is a jq variable, not a shell expansion.
# shellcheck disable=SC2016
check "a Copilot CLI string patch is admitted with an active node" _jq_ok "$cp_allow" \
    '.decision == "allow" and .active_node == $id' --arg id "$node_id"
copilot_patch $'*** Begin Patch\n*** Add File: src/c.py\n+alpha\n*** End Patch\n' \
    | jq -c '.hook_event_name = "PostToolUse" | .tool_result = {result_type:"success"}' \
    | "$WV" hook dispatch --event=PostToolUse --json >/dev/null
check "PostToolUse attributes a Copilot CLI string patch's path" \
    test "$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM node_files WHERE node_id='$node_id' AND path='src/c.py';")" -eq 1
set +e
cp_installed=$(copilot_patch $'*** Begin Patch\n*** Update File: /fake/.local/bin/wv\n*** End Patch\n' \
    | "$WV" hook dispatch --event=PreToolUse --json)
cp_installed_rc=$?
cp_text=$(copilot_patch 'not a patch' | "$WV" hook dispatch --event=PreToolUse --json)
cp_text_rc=$?
set -e
check "a Copilot CLI string patch meets the installed-copy guard" test "$cp_installed_rc" -eq 1
check "installed-copy decision for the string patch names the path" _jq_ok "$cp_installed" \
    '.decision == "block" and (.reason | contains(".local/bin/wv"))'
check "a string tool_input that is not a patch is still refused" test "$cp_text_rc" -eq 1
check "the refusal names the malformed payload" _jq_ok "$cp_text" \
    '.decision == "block" and (.reason | contains("tool_input must be an object"))'

# A string patch into a second Weave checkout is judged by that checkout's
# graph, not the cwd's claim (wv-455739), as a Codex apply_patch is.
Q="$TEST_DIR/other"
mkdir -p "$Q/src"
q_env() { (cd "$Q" && env -u WV_HOT_ZONE -u WV_DB -u WV_PROJECT_DIR -u WEAVE_DIR "$@"); }
git -C "$Q" init -q
# Under the gate's test mode the default placement sits inside
# WV_TEST_HOT_ZONE_ROOT, whose tmp/ parent wv will not create (wv-80be32).
[ -z "${WV_TEST_HOT_ZONE_ROOT:-}" ] || (umask 077 && mkdir -p "$WV_TEST_HOT_ZONE_ROOT/tmp")
q_env "$WV" init >/dev/null 2>&1
Q_ZONE=$(dirname "$(q_env "$WV" hotzone db 2>/dev/null)")
case "$Q_ZONE" in /tmp/weave-*/?*) trap 'cd /tmp; rm -rf "$TEST_DIR" "$Q_ZONE"' EXIT ;; esac
check "fixture: the second checkout has its own graph" test -s "$Q_ZONE/brain.db"
set +e
cp_other=$(copilot_patch "*** Begin Patch"$'\n'"*** Update File: $Q/src/q.py"$'\n'"*** End Patch"$'\n' \
    | "$WV" hook dispatch --event=PreToolUse --json)
cp_other_rc=$?
set -e
check "a string patch into another checkout with no claim there is refused" test "$cp_other_rc" -eq 1
check "the refusal is that checkout's missing claim" _jq_ok "$cp_other" \
    '.decision == "block" and (.reason | contains("No active Weave node"))'

# ── SessionStart: stamps .session_epoch and resets phase to discover, mirroring
# .claude/hooks/session-start-context.sh so stale-node detection has a baseline.
"$WV" hook dispatch --event=SessionStart --json <<<'{}' >/dev/null
check "SessionStart writes .session_epoch" test -f "$HOT/.session_epoch"
check "SessionStart resets phase to discover" \
    test "$(cat "$OWN/.session_phase" 2>/dev/null)" = "discover"

# ── SessionStart parity (wv-a523de): the command .codex/hooks.json runs and the
# Claude adapter run one session start and emit the same hookSpecificOutput. A
# planted sentinel with no stop record, while a node is active, is a session
# that died mid-turn: both must report it, which the old Codex path never did.
_ss_payload='{"session_id":"parity","source":"startup","hook_event_name":"SessionStart"}'
_plant_crash() {
    printf '{"ts":"2026-01-01T00:00:00Z","active":[],"pid":1}' > "$HOT/.session_sentinel"
    rm -f "$HOT/.session_laststop" "$HOT/.session_heartbeat"
}
_plant_crash
codex_ss=$(printf '%s' "$_ss_payload" | "$WV" hook dispatch --event=SessionStart --format=host) || true
_plant_crash
claude_ss=$(printf '%s' "$_ss_payload" | bash "$ROOT/.claude/hooks/session-start-context.sh") || true
check "Codex SessionStart emits the host hookSpecificOutput object" _jq_ok "$codex_ss" \
    '.hookSpecificOutput.hookEventName == "SessionStart" and (keys == ["hookSpecificOutput"])'
check "Codex SessionStart reports the crashed session" _jq_ok "$codex_ss" \
    '.hookSpecificOutput.additionalContext | contains("CRASH DETECTED")'
check "Codex SessionStart carries the compact policy line first" _jq_ok "$codex_ss" \
    '.hookSpecificOutput.additionalContext | test("^Weave: [0-9]+ active, [0-9]+ ready, [0-9]+ blocked \\| policy=")'
codex_ctx=$(jq -r '.hookSpecificOutput.additionalContext' <<<"$codex_ss")
claude_ctx=$(jq -r '.hookSpecificOutput.additionalContext' <<<"$claude_ss")
check "Claude adapter and Codex command produce the same context" \
    test "$codex_ctx" = "$claude_ctx"
# A mismatch failed once inside the gate and never standalone (wv-a420cb):
# print both sides so the next occurrence names the line that moved.
if [ "$codex_ctx" != "$claude_ctx" ]; then
    diff <(printf '%s\n' "$codex_ctx") <(printf '%s\n' "$claude_ctx") \
        | sed 's/^/#   /' || true
fi

# ── PreToolUse: discover-phase blocks edits even with an active node ──
set +e
discover_output=$(printf '%s' '{"tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n*** Update File: src/c.py\n*** End Patch"}}' \
    | "$WV" hook dispatch --event=PreToolUse --json)
discover_rc=$?
set -e
check "PreToolUse blocks apply_patch during discover phase" test "$discover_rc" -eq 1
check "discover-phase decision names the phase" _jq_ok "$discover_output" \
    '.decision == "block" and (.reason | contains("discover"))'

# ── PreToolUse: an active node that predates this session (session_epoch) is
# rejected until re-claimed — the wv-cd13b5 orphan-node scenario.
printf 'execute' > "$OWN/.session_phase"
sqlite3 "$WV_DB" "UPDATE nodes SET updated_at = datetime('now', '-1 hour') WHERE id='$node_id';"
set +e
stale_reclaim_output=$(printf '%s' '{"tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n*** Update File: src/d.py\n*** End Patch"}}' \
    | "$WV" hook dispatch --event=PreToolUse --json)
stale_reclaim_rc=$?
set -e
check "PreToolUse blocks apply_patch when the active node predates this session" \
    test "$stale_reclaim_rc" -eq 1
# $id below is a jq variable, not a shell expansion.
# shellcheck disable=SC2016
check "stale-reclaim decision names the active node" _jq_ok "$stale_reclaim_output" \
    '.decision == "block" and .active_node == $id and (.reason | contains("Stale active node not claimed this session"))' --arg id "$node_id"

# Touching updated_at forward (what a re-claim does) clears the staleness gate.
sqlite3 "$WV_DB" "UPDATE nodes SET updated_at = datetime('now') WHERE id='$node_id';"
set +e
reclaimed_output=$(printf '%s' '{"tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n*** Update File: src/d.py\n*** End Patch"}}' \
    | "$WV" hook dispatch --event=PreToolUse --json)
reclaimed_rc=$?
set -e
check "PreToolUse allows apply_patch once the active node is fresh again" \
    test "$reclaimed_rc" -eq 0

# ── PreToolUse: real graph blockers/contradictions must deny dispatch, matching
# Claude's pre-action.sh after active-node and stale-node checks.
"$WV" update "$node_id" --status=done >/dev/null

blocked_node=$("$WV" add "Blocked Codex hook fixture" --status=active \
    --criteria="dispatch denies blocked work" --risks=low --force --json \
    | jq -r '.id')
blocker_node=$("$WV" add "Blocking prerequisite fixture" --status=todo \
    --criteria="prerequisite remains open" --risks=low --force --json \
    | jq -r '.id')
"$WV" link "$blocker_node" "$blocked_node" --type=blocks >/dev/null
set +e
blocked_output=$(printf '%s' '{"tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n*** Update File: src/blocked.py\n*** End Patch"}}' \
    | "$WV" hook dispatch --event=PreToolUse --json)
blocked_rc=$?
set -e
check "PreToolUse blocks apply_patch when the active node has an incomplete blocker" \
    test "$blocked_rc" -eq 1
# $id below is a jq variable, not a shell expansion.
# shellcheck disable=SC2016
check "blocked-node decision names the active node" _jq_ok "$blocked_output" \
    '.decision == "block" and .active_node == $id and (.reason | contains("This node is blocked by"))' --arg id "$blocked_node"

"$WV" update "$blocked_node" --status=done >/dev/null
contradicted_node=$("$WV" add "Contradicted Codex hook fixture" --status=active \
    --criteria="dispatch denies contradictions" --risks=low --force --json \
    | jq -r '.id')
contradictor_node=$("$WV" add "Contradicting fixture" --status=todo \
    --criteria="conflict remains unresolved" --risks=low --force --json \
    | jq -r '.id')
"$WV" link "$contradictor_node" "$contradicted_node" --type=contradicts >/dev/null
set +e
contradicted_output=$(printf '%s' '{"tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n*** Update File: src/contradicted.py\n*** End Patch"}}' \
    | "$WV" hook dispatch --event=PreToolUse --json)
contradicted_rc=$?
set -e
check "PreToolUse blocks apply_patch when the active node has a contradiction" \
    test "$contradicted_rc" -eq 1
# $id below is a jq variable, not a shell expansion.
# shellcheck disable=SC2016
check "contradiction decision names the active node" _jq_ok "$contradicted_output" \
    '.decision == "block" and .active_node == $id and (.reason | contains("Contradictions detected"))' --arg id "$contradicted_node"
"$WV" update "$contradicted_node" --status=done >/dev/null

# ── PreToolUse: when multiple nodes are active, dispatch must check the primary
# node selected by wv work/primary, not whichever active node list returns first.
primary_blocked_node=$("$WV" add "Primary blocked Codex hook fixture" --status=active \
    --criteria="primary blocked work is enforced" --risks=low --force --json \
    | jq -r '.id')
primary_blocker_node=$("$WV" add "Primary blocking prerequisite fixture" --status=todo \
    --criteria="primary prerequisite remains open" --risks=low --force --json \
    | jq -r '.id')
"$WV" link "$primary_blocker_node" "$primary_blocked_node" --type=blocks >/dev/null
primary_clean_node=$("$WV" add "Secondary clean Codex hook fixture" --status=active \
    --criteria="clean secondary must not mask primary" --risks=low --force --json \
    | jq -r '.id')
printf '%s' "$primary_blocked_node" > "$OWN/primary"
set +e
primary_blocked_output=$(printf '%s' '{"tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n*** Update File: src/primary-blocked.py\n*** End Patch"}}' \
    | "$WV" hook dispatch --event=PreToolUse --json)
primary_blocked_rc=$?
set -e
check "PreToolUse blocks the primary active node even when another active node is clean" \
    test "$primary_blocked_rc" -eq 1
# $id below is a jq variable, not a shell expansion.
# shellcheck disable=SC2016
check "multi-active block decision names the primary node" _jq_ok "$primary_blocked_output" \
    '.decision == "block" and .active_node == $id and (.reason | contains("This node is blocked by"))' --arg id "$primary_blocked_node"
"$WV" update "$primary_blocked_node" --status=done >/dev/null
"$WV" update "$primary_clean_node" --status=done >/dev/null

# ── PreToolUse: dispatch intentionally re-checks graph policy on context-stamp
# hits, because it can be the only active policy gate in mixed-host sessions.
stamped_node=$("$WV" add "Stamped Codex hook fixture" --status=active \
    --criteria="stamp does not skip dispatch graph policy" --risks=low --force --json \
    | jq -r '.id')
stamped_blocker_node=$("$WV" add "Stamped blocking prerequisite fixture" --status=todo \
    --criteria="late blocker remains open" --risks=low --force --json \
    | jq -r '.id')
printf '%s' "$stamped_node" > "$OWN/primary"
touch "$OWN/.context_checked_${stamped_node}"
"$WV" link "$stamped_blocker_node" "$stamped_node" --type=blocks >/dev/null
set +e
stamped_output=$(printf '%s' '{"tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n*** Update File: src/stamped.py\n*** End Patch"}}' \
    | "$WV" hook dispatch --event=PreToolUse --json)
stamped_rc=$?
set -e
check "PreToolUse re-checks blockers even when the context stamp exists" \
    test "$stamped_rc" -eq 1
# $id below is a jq variable, not a shell expansion.
# shellcheck disable=SC2016
check "stamp-hit block decision names the active node" _jq_ok "$stamped_output" \
    '.decision == "block" and .active_node == $id and (.reason | contains("This node is blocked by"))' --arg id "$stamped_node"
"$WV" update "$stamped_node" --status=done >/dev/null

# --- dispatch/normalize fail-closed alignment on malformed hook fixtures (wv-692c2d) ---
# For every malformed PreToolUse event: normalize must fail closed (exit 2)
# AND dispatch must block (exit 1). Advisory/lifecycle events keep dispatch's
# deliberate fail-open posture, asserted separately below.
HOOK_FIXTURE="$ROOT/tests/fixtures/hook-normalization/malformed-events.json"
while IFS=$'\t' read -r event_id host raw_kind payload; do
    set +e
    printf '%s' "$payload" | "$WV" hook normalize --host="$host" --event="$raw_kind" >/dev/null 2>&1
    normalize_rc=$?
    dispatch_output=$(printf '%s' "$payload" | "$WV" hook dispatch --event="$raw_kind" --json 2>/dev/null)
    dispatch_rc=$?
    set -e
    check "$event_id: normalize fails closed and dispatch blocks" \
        bash -c "[ '$normalize_rc' -eq 2 ] && [ '$dispatch_rc' -eq 1 ]"
    check "$event_id: dispatch decision is a malformed-payload block" \
        _jq_ok "$dispatch_output" '.decision == "block" and (.reason | contains("payload malformed"))'
done < <(jq -r '.malformed_events[]
    | select(.raw_event_kind == "PreToolUse")
    | [.event_id, .host, .raw_event_kind, (.raw_payload | tojson)] | @tsv' "$HOOK_FIXTURE")

set +e
lifecycle_output=$(printf 'not json' | "$WV" hook dispatch --event=Stop --json 2>/dev/null)
lifecycle_rc=$?
set -e
check "advisory events keep fail-open on invalid JSON (infrastructure posture)" \
    bash -c "[ '$lifecycle_rc' -eq 0 ]"
check "fail-open decision is hook_error, not allow-by-classification" \
    _jq_ok "$lifecycle_output" '.decision == "hook_error"'

set +e
empty_output=$("$WV" hook dispatch --event=PreToolUse --json </dev/null 2>/dev/null)
empty_rc=$?
set -e
check "empty stdin remains a manual-invocation no-op on PreToolUse" \
    bash -c "[ '$empty_rc' -eq 0 ]"
check "empty-stdin decision is allow" _jq_ok "$empty_output" '.decision == "allow"'

# ── PreToolUse parity (wv-d3fbcb): the command .codex/hooks.json runs and the
# Claude adapter that decides first in dispatch's order run one guard and
# answer identically: exit status, stdout (deny JSON) and stderr (block reason).
# --format=host is what Codex reads; it honours only exit 2 with a stderr reason
# or exit 0 with deny JSON, never the --json exit 1 (wv-5b774a).
_parity() {  # _parity <label> <hook> <payload> <expected exit>; sets PARITY_OUT
    local label="$1" hook="$2" payload="$3" want="$4" c_out c_rc d_rc
    set +e
    c_out=$(bash "$ROOT/.claude/hooks/$hook" 2>"$TEST_DIR/claude.err" < <(printf '%s' "$payload"))
    c_rc=$?
    PARITY_OUT=$(printf '%s' "$payload" | "$WV" hook dispatch --event=PreToolUse --format=host 2>"$TEST_DIR/codex.err")
    d_rc=$?
    set -e
    check "$label: the Codex command exits $want" test "$d_rc" = "$want"
    check "$label: the Claude adapter exits the same" test "$c_rc" = "$d_rc"
    check "$label: same stdout" test "$c_out" = "$PARITY_OUT"
    check "$label: same stderr" cmp -s "$TEST_DIR/claude.err" "$TEST_DIR/codex.err"
}
_bash_payload() { jq -cn --arg c "$1" --arg cwd "$REPO" '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}'; }
printf 'execute' > "$OWN/.session_phase"
rm -f "$HOT/.session_epoch" "$OWN/primary"

_parity "edit with no active node" pre-action.sh \
    '{"tool_name":"Edit","tool_input":{"file_path":"src/p.py","old_string":"a","new_string":"b"}}' 2
check "edit with no active node: the block carries its reason on stderr" \
    grep -q "No active Weave node" "$TEST_DIR/codex.err"

bare_node=$("$WV" add "Parity claim probe" --force --json | jq -r '.id')
_parity "claim of an unplanned node" pre-claim-skills.sh "$(_bash_payload "wv work $bare_node")" 0
# $id below is a jq variable, not a shell expansion.
# shellcheck disable=SC2016
check "claim of an unplanned node: the deny is the claim preflight" _jq_ok "$PARITY_OUT" \
    '.hookSpecificOutput.permissionDecision == "deny"
     and (.hookSpecificOutput.permissionDecisionReason | startswith("Claim preflight for " + $id))' --arg id "$bare_node"

close_node=$("$WV" add "Parity close probe" --status=active --criteria="c1" --risks=low --force \
    --metadata='{"commit":"0000000"}' --json | jq -r '.id')
_parity "close without verification evidence" pre-close-verification.sh "$(_bash_payload "wv done $close_node")" 0
# $id below is a jq variable, not a shell expansion.
# shellcheck disable=SC2016
check "close without verification evidence: the deny is the close verification" _jq_ok "$PARITY_OUT" \
    '.hookSpecificOutput.permissionDecision == "deny"
     and (.hookSpecificOutput.permissionDecisionReason | startswith("Run: wv done " + $id))' --arg id "$close_node"
"$WV" update "$close_node" --status=done >/dev/null

_parity "a command no guard governs" pre-action.sh "$(_bash_payload "ls")" 0
check "a command no guard governs: allowed with no output" test -z "$PARITY_OUT"

# A patch is not a command (wv-d3eb63). Codex's apply_patch carries its text in
# tool_input.command, the field the claim and close guards read a shell command
# from, so a patch to a note that mentions claiming or closing a node must not
# be judged as that command. In Claude Code those guards only ever saw Bash.
mention_node=$("$WV" add "Patch mention probe" --status=active --criteria="c1" --risks=low --force \
    --metadata='{"commit":"0000000"}' --json | jq -r '.id')
_patch_payload() { jq -cn --arg p "$1" --arg cwd "$REPO" '{tool_name:"apply_patch",tool_input:{command:$p},cwd:$cwd}'; }
for mention in "wv done $mention_node" "wv work $bare_node"; do
    set +e
    mention_out=$(_patch_payload "*** Begin Patch
*** Update File: docs/notes.md
@@
+Run $mention to continue.
*** End Patch" | "$WV" hook dispatch --event=PreToolUse --format=host 2>/dev/null)
    mention_rc=$?
    set -e
    check "a patch mentioning '${mention% wv-*}' is allowed" test "$mention_rc" -eq 0
    check "a patch mentioning '${mention% wv-*}' is not denied" test -z "$mention_out"
done
"$WV" update "$mention_node" --status=done >/dev/null

# ── PostToolUse (wv-594381): the guards Claude Code's PostToolUse hooks call
# in-process, run by the command .codex/hooks.json registers (--format=host).
# Codex reports an apply_patch result as a string (ApplyPatchToolOutput).
attr_node=$("$WV" add "Patch attribution probe" --status=active --criteria="c1" --risks=low --force --json | jq -r '.id')
set +e
attr_out=$(_patch_payload "*** Begin Patch
*** Update File: src/real-a.py
*** Add File: src/real-b.py
*** Delete File: src/real-c.py
*** End Patch" | jq -c '. + {tool_response:"Success. Updated the following files:\nM src/real-a.py"}' \
    | "$WV" hook dispatch --event=PostToolUse --format=host 2>/dev/null)
attr_rc=$?
set -e
check "PostToolUse --format=host exits 0" test "$attr_rc" -eq 0
check "PostToolUse --format=host prints nothing when no guard advises" test -z "$attr_out"
check "PostToolUse attributes every path of a real Codex patch" \
    test "$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM node_files WHERE node_id='$attr_node' AND path IN ('src/real-a.py','src/real-b.py','src/real-c.py');")" -eq 3
# $id below is a jq variable, not a shell expansion.
# shellcheck disable=SC2016
check "PostToolUse keeps the node's touched_files list for Codex too" \
    _jq_ok "$("$WV" show "$attr_node" --json)" \
    '(.metadata | fromjson | .touched_files) as $t | ["src/real-a.py","src/real-b.py","src/real-c.py"] - $t == []'
check "PostToolUse records the edits in the session's recent-edits ring" \
    grep -qx "src/real-c.py" "$HOT/recent-edits.txt"
"$WV" update "$attr_node" --status=done >/dev/null

# The wv budget tally counts Codex's wv calls as it counts Claude's.
budget_file="$HOT/session-budget.json"
rm -f "$budget_file"
_bash_payload "wv status" | jq -c '. + {tool_response:{output:"status text"}}' \
    | "$WV" hook dispatch --event=PostToolUse --format=host >/dev/null 2>&1 || true
check "PostToolUse tallies a Codex wv call" test "$(jq -r '.calls // 0' "$budget_file" 2>/dev/null)" = "1"

# Advisory parity: the Claude adapter and the Codex command emit the same
# hookSpecificOutput for the same payload.
budget_payload=$(_bash_payload "wv ready" | jq -c '. + {tool_response:{stdout:"ready list",stderr:""}}')
rm -f "$budget_file"
claude_adv=$(printf '%s' "$budget_payload" | WV_BUDGET_THRESHOLD=1 bash "$ROOT/.claude/hooks/wv-budget-tally.sh" 2>/dev/null) || true
rm -f "$budget_file"
codex_adv=$(printf '%s' "$budget_payload" | WV_BUDGET_THRESHOLD=1 "$WV" hook dispatch --event=PostToolUse --format=host 2>/dev/null) || true
check "a budget advisory reaches Codex as hookSpecificOutput.additionalContext" _jq_ok "$codex_adv" \
    '.hookSpecificOutput.hookEventName == "PostToolUse" and (.hookSpecificOutput.additionalContext | contains("wv called 1x"))'
check "the Claude adapter and the Codex command emit the same advisory" test "$claude_adv" = "$codex_adv"
rm -f "$budget_file"

# Bash dedup now runs for Codex too: PreToolUse dispatch takes the lock last,
# after every other guard has allowed the call, and PostToolUse dispatch
# releases it once the command has run (wv-594381).
dedup_locks="/tmp/weave-bash-locks-$(id -u)/$(echo "$REPO" | md5sum | cut -c1-8)"
rm -rf "$dedup_locks"
_bash_payload "make check" | "$WV" hook dispatch --event=PreToolUse --format=host >/dev/null 2>&1 || true
check "PreToolUse dispatch takes the dedup lock" test -e "$dedup_locks/make-build.lock"
dup_out=$(_bash_payload "make check" | "$WV" hook dispatch --event=PreToolUse --format=host 2>/dev/null) || true
check "a duplicate in-flight command is denied for Codex" _jq_ok "$dup_out" \
    '.hookSpecificOutput.permissionDecision == "deny" and (.hookSpecificOutput.permissionDecisionReason | startswith("Duplicate command blocked"))'
_bash_payload "make check" | jq -c '. + {tool_response:{output:"ok",exit_code:0}}' \
    | "$WV" hook dispatch --event=PostToolUse --format=host >/dev/null 2>&1 || true
check "PostToolUse dispatch releases the dedup lock" test ! -e "$dedup_locks/make-build.lock"
# A lock whose PostToolUse never came (crash, hard block) is cleared by the
# next SessionStart, from the directory PreToolUse wrote it in: the hook's
# repo hash once dropped echo's newline and cleared a directory nothing
# writes (wv-1ba440).
_bash_payload "make check" | "$WV" hook dispatch --event=PreToolUse --format=host >/dev/null 2>&1 || true
check "an orphaned dedup lock is left by PreToolUse alone" test -e "$dedup_locks/make-build.lock"
printf '%s' '{}' | "$WV" hook dispatch --event=SessionStart --json >/dev/null 2>&1 || true
check "SessionStart clears the orphaned dedup lock" test ! -e "$dedup_locks/make-build.lock"
rm -rf "$dedup_locks"

# ── Stop, SessionEnd and PreCompact (wv-25903d): the guard Claude Code's
# stop-check.sh runs in-process, run by the commands .codex/hooks.json registers.
# Codex honours a Stop block only as {"decision":"block"} with exit 0 (or exit
# 2 with a stderr reason); exit 1 reads as a failed hook (wv-5b774a).
stop_node=$("$WV" add "Codex stop fixture" --status=active --criteria="c1" --risks=low --force --json | jq -r '.id')
rm -f "$HOT/.stop_check_lock"
set +e
codex_stop=$(printf '%s' '{"session_id":"s","hook_event_name":"Stop","stop_hook_active":false}' \
    | "$WV" hook dispatch --event=Stop --format=host 2>/dev/null)
codex_stop_rc=$?
set -e
check "Stop --format=host exits 0 when it blocks" test "$codex_stop_rc" -eq 0
check "Stop --format=host blocks as decision JSON Codex honours" _jq_ok "$codex_stop" \
    '.decision == "block" and (.reason | contains("active node(s) still open"))'
rm -f "$HOT/.stop_check_lock"
claude_stop=$(printf '%s' '{"session_id":"s","hook_event_name":"Stop","stop_hook_active":false}' \
    | bash "$ROOT/.claude/hooks/stop-check.sh" 2>/dev/null) || true
check "Claude's stop-check and Codex's Stop dispatch give the same decision" \
    test "$(jq -c . <<<"$claude_stop")" = "$(jq -c . <<<"$codex_stop")"
check "a Stop the host is already continuing from is not blocked again" \
    test -z "$(printf '%s' '{"stop_hook_active":true}' | "$WV" hook dispatch --event=Stop --format=host 2>/dev/null)"
"$WV" update "$stop_node" --status=todo >/dev/null 2>&1
"$WV" update "$node_id" --status=todo >/dev/null 2>&1
for leftover in $("$WV" list --status=active --json 2>/dev/null | jq -r '.[].id'); do
    "$WV" update "$leftover" --status=todo >/dev/null 2>&1
done
rm -f "$HOT/.stop_check_lock"
check "Stop --format=host prints nothing with no active node" \
    test -z "$(printf '%s' '{"stop_hook_active":false}' | "$WV" hook dispatch --event=Stop --format=host 2>/dev/null)"

compact_out=$(printf '%s' '{"hook_event_name":"PreCompact","trigger":"auto"}' \
    | "$WV" hook dispatch --event=PreCompact --format=host 2>/dev/null) || true
# shellcheck disable=SC2016  # $1/$2 expand in the bash -c child, passed as positional arguments
check "PreCompact dispatch prints the pre-compact snapshot" \
    bash -c '[[ "$1" == "Weave state (pre-compact snapshot):"* ]]' _ "$compact_out"
compact_json=$(printf '%s' '{"hook_event_name":"PreCompact"}' | "$WV" hook dispatch --event=PreCompact --json 2>/dev/null) || true
check "PreCompact --json carries the snapshot as context" _jq_ok "$compact_json" \
    '.decision == "allow" and .event == "PreCompact" and (.context | startswith("Weave state"))'

touch "$HOT/.session_sentinel"
session_end_out=$(printf '%s' '{"hook_event_name":"SessionEnd","reason":"other"}' \
    | "$WV" hook dispatch --event=SessionEnd --format=host 2>/dev/null) || true
check "SessionEnd --format=host prints nothing" test -z "$session_end_out"
check "SessionEnd dispatch clears the crash sentinel" test ! -e "$HOT/.session_sentinel"
touch "$HOT/.session_sentinel"
"$WV" hook dispatch --event=SessionEnd --format=host </dev/null >/dev/null 2>&1 || true
check "an empty-stdin SessionEnd is a manual no-op" test -e "$HOT/.session_sentinel"

printf '1..%d\n' "$total"
printf 'Results: %d/%d passed\n' "$pass" "$total"
test "$pass" -eq "$total"
