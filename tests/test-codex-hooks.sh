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

printf '1..%d\n' "$total"
printf 'Results: %d/%d passed\n' "$pass" "$total"
test "$pass" -eq "$total"
