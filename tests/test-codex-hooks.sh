#!/usr/bin/env bash
set -euo pipefail

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
missing_output=$(printf '%s' '{"tool_name":"apply_patch","tool_input":{"patchText":"*** Begin Patch\n*** Update File: src/a.py\n*** End Patch"}}' \
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

allow_output=$(printf '%s' '{"tool_name":"apply_patch","tool_input":{"patchText":"*** Begin Patch\n*** Update File: src/a.py\n*** End Patch"}}' \
    | "$WV" hook dispatch --event=PreToolUse --json)
# $id below is a jq variable, not a shell expansion.
# shellcheck disable=SC2016
check "PreToolUse allows apply_patch with an active node" _jq_ok "$allow_output" \
    '.decision == "allow" and .active_node == $id' --arg id "$node_id"

post_output=$(printf '%s' '{"tool_name":"apply_patch","tool_input":{"patchText":"*** Begin Patch\n*** Update File: src/a.py\n*** Add File: src/b.py\n*** End Patch"},"tool_response":{"success":true}}' \
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
printf 'execute' > "$HOT/.session_phase"
set +e
installed_output=$(printf '%s' '{"tool_name":"apply_patch","tool_input":{"patchText":"*** Begin Patch\n*** Update File: /fake/.local/lib/weave/cmd/wv-cmd-hook.sh\n*** End Patch"}}' \
    | "$WV" hook dispatch --event=PreToolUse --json)
installed_rc=$?
set -e
check "PreToolUse blocks edits to the installed Weave copy" test "$installed_rc" -eq 1
check "installed-path decision names the offending path" _jq_ok "$installed_output" \
    '.decision == "block" and (.reason | contains(".local/lib/weave"))'

# ── SessionStart: stamps .session_epoch and resets phase to discover, mirroring
# .claude/hooks/session-start-context.sh so stale-node detection has a baseline.
"$WV" hook dispatch --event=SessionStart --json <<<'{}' >/dev/null
check "SessionStart writes .session_epoch" test -f "$HOT/.session_epoch"
check "SessionStart resets phase to discover" \
    test "$(cat "$HOT/.session_phase" 2>/dev/null)" = "discover"

# ── PreToolUse: discover-phase blocks edits even with an active node ──
set +e
discover_output=$(printf '%s' '{"tool_name":"apply_patch","tool_input":{"patchText":"*** Begin Patch\n*** Update File: src/c.py\n*** End Patch"}}' \
    | "$WV" hook dispatch --event=PreToolUse --json)
discover_rc=$?
set -e
check "PreToolUse blocks apply_patch during discover phase" test "$discover_rc" -eq 1
check "discover-phase decision names the phase" _jq_ok "$discover_output" \
    '.decision == "block" and (.reason | contains("discover"))'

# ── PreToolUse: an active node that predates this session (session_epoch) is
# rejected until re-claimed — the wv-cd13b5 orphan-node scenario.
printf 'execute' > "$HOT/.session_phase"
sqlite3 "$WV_DB" "UPDATE nodes SET updated_at = datetime('now', '-1 hour') WHERE id='$node_id';"
set +e
stale_reclaim_output=$(printf '%s' '{"tool_name":"apply_patch","tool_input":{"patchText":"*** Begin Patch\n*** Update File: src/d.py\n*** End Patch"}}' \
    | "$WV" hook dispatch --event=PreToolUse --json)
stale_reclaim_rc=$?
set -e
check "PreToolUse blocks apply_patch when the active node predates this session" \
    test "$stale_reclaim_rc" -eq 1
# $id below is a jq variable, not a shell expansion.
# shellcheck disable=SC2016
check "stale-reclaim decision names the active node" _jq_ok "$stale_reclaim_output" \
    '.decision == "block" and .active_node == $id and (.reason | contains("predates"))' --arg id "$node_id"

# Touching updated_at forward (what a re-claim does) clears the staleness gate.
sqlite3 "$WV_DB" "UPDATE nodes SET updated_at = datetime('now') WHERE id='$node_id';"
set +e
reclaimed_output=$(printf '%s' '{"tool_name":"apply_patch","tool_input":{"patchText":"*** Begin Patch\n*** Update File: src/d.py\n*** End Patch"}}' \
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
blocked_output=$(printf '%s' '{"tool_name":"apply_patch","tool_input":{"patchText":"*** Begin Patch\n*** Update File: src/blocked.py\n*** End Patch"}}' \
    | "$WV" hook dispatch --event=PreToolUse --json)
blocked_rc=$?
set -e
check "PreToolUse blocks apply_patch when the active node has an incomplete blocker" \
    test "$blocked_rc" -eq 1
# $id below is a jq variable, not a shell expansion.
# shellcheck disable=SC2016
check "blocked-node decision names the active node" _jq_ok "$blocked_output" \
    '.decision == "block" and .active_node == $id and (.reason | contains("blocked by incomplete work"))' --arg id "$blocked_node"

"$WV" update "$blocked_node" --status=done >/dev/null
contradicted_node=$("$WV" add "Contradicted Codex hook fixture" --status=active \
    --criteria="dispatch denies contradictions" --risks=low --force --json \
    | jq -r '.id')
contradictor_node=$("$WV" add "Contradicting fixture" --status=todo \
    --criteria="conflict remains unresolved" --risks=low --force --json \
    | jq -r '.id')
"$WV" link "$contradictor_node" "$contradicted_node" --type=contradicts >/dev/null
set +e
contradicted_output=$(printf '%s' '{"tool_name":"apply_patch","tool_input":{"patchText":"*** Begin Patch\n*** Update File: src/contradicted.py\n*** End Patch"}}' \
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
printf '%s' "$primary_blocked_node" > "$HOT/primary"
set +e
primary_blocked_output=$(printf '%s' '{"tool_name":"apply_patch","tool_input":{"patchText":"*** Begin Patch\n*** Update File: src/primary-blocked.py\n*** End Patch"}}' \
    | "$WV" hook dispatch --event=PreToolUse --json)
primary_blocked_rc=$?
set -e
check "PreToolUse blocks the primary active node even when another active node is clean" \
    test "$primary_blocked_rc" -eq 1
# $id below is a jq variable, not a shell expansion.
# shellcheck disable=SC2016
check "multi-active block decision names the primary node" _jq_ok "$primary_blocked_output" \
    '.decision == "block" and .active_node == $id and (.reason | contains("blocked by incomplete work"))' --arg id "$primary_blocked_node"
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
printf '%s' "$stamped_node" > "$HOT/primary"
touch "$HOT/.context_checked_${stamped_node}"
"$WV" link "$stamped_blocker_node" "$stamped_node" --type=blocks >/dev/null
set +e
stamped_output=$(printf '%s' '{"tool_name":"apply_patch","tool_input":{"patchText":"*** Begin Patch\n*** Update File: src/stamped.py\n*** End Patch"}}' \
    | "$WV" hook dispatch --event=PreToolUse --json)
stamped_rc=$?
set -e
check "PreToolUse re-checks blockers even when the context stamp exists" \
    test "$stamped_rc" -eq 1
# $id below is a jq variable, not a shell expansion.
# shellcheck disable=SC2016
check "stamp-hit block decision names the active node" _jq_ok "$stamped_output" \
    '.decision == "block" and .active_node == $id and (.reason | contains("blocked by incomplete work"))' --arg id "$stamped_node"
"$WV" update "$stamped_node" --status=done >/dev/null

# --- dispatch/normalize fail-closed alignment on the E3 malformed fixtures (wv-692c2d) ---
# For every E3 malformed PreToolUse event: normalize must fail closed (exit 2)
# AND dispatch must block (exit 1). Advisory/lifecycle events keep dispatch's
# deliberate fail-open posture, asserted separately below.
E3_FIXTURE="$ROOT/tests/fixtures/rust-evidence/e3/harness-normalization.json"
while IFS=$'\t' read -r event_id host raw_kind payload; do
    set +e
    printf '%s' "$payload" | "$WV" hook normalize --host="$host" --event="$raw_kind" >/dev/null 2>&1
    normalize_rc=$?
    dispatch_output=$(printf '%s' "$payload" | "$WV" hook dispatch --event="$raw_kind" --json 2>/dev/null)
    dispatch_rc=$?
    set -e
    check "E3 $event_id: normalize fails closed and dispatch blocks" \
        bash -c "[ '$normalize_rc' -eq 2 ] && [ '$dispatch_rc' -eq 1 ]"
    check "E3 $event_id: dispatch decision is a malformed-payload block" \
        _jq_ok "$dispatch_output" '.decision == "block" and (.reason | contains("Malformed hook payload"))'
done < <(jq -r '.malformed_events[]
    | select(.raw_event_kind == "PreToolUse")
    | [.event_id, .host, .raw_event_kind, (.raw_payload | tojson)] | @tsv' "$E3_FIXTURE")

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

printf '1..%d\n' "$total"
printf 'Results: %d/%d passed\n' "$pass" "$total"
test "$pass" -eq "$total"
