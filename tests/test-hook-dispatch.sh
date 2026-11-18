#!/usr/bin/env bash
# Focused regression coverage for the host-neutral hook dispatch facade.
set -euo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
# Every check below is silent, so a failure used to leave an empty log: the
# rc.13 verify aggregate recorded exit 1 with no output at all. Name the line.
trap 'echo "hook dispatch: FAILED at line $LINENO: $BASH_COMMAND" >&2' ERR

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WV="$PROJECT_ROOT/scripts/wv"
TEST_DIR="$(mktemp -d)"

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

export WV_PROJECT_DIR="$TEST_DIR"
export WEAVE_DIR="$TEST_DIR/.weave"
export WV_HOT_ZONE="$TEST_DIR/hz"
export WV_DB="$TEST_DIR/hz/brain.db"
export WV_REQUIRE_LEARNING=0

cd "$TEST_DIR"
git init -q
"$WV" init >/dev/null

"$WV" hook dispatch --event=SessionStart --json </dev/null | jq -e \
    '.decision == "allow" and (.active_node? == null)' >/dev/null

if printf '%s' '{"tool_name":"Edit","tool_input":{"file_path":"README.md"}}' \
    | "$WV" hook dispatch --event=PreToolUse --json >/dev/null; then
    echo "PreToolUse allowed an edit without an active node" >&2
    exit 1
fi

# The hook-events-v1 kinds are the neutral entry and route to the same handlers
# as the host aliases (wv-b25ebb): before_edit refuses what PreToolUse refuses.
"$WV" hook dispatch --event=session_start --json </dev/null | jq -e \
    '.decision == "allow" and .event == "SessionStart"' >/dev/null
if printf '%s' '{"tool_name":"Edit","tool_input":{"file_path":"README.md"}}' \
    | "$WV" hook dispatch --event=before_edit --json >/dev/null; then
    echo "before_edit allowed an edit without an active node" >&2
    exit 1
fi
if "$WV" hook dispatch --event=tool_call --json </dev/null 2>"$TEST_DIR/kind.err"; then
    echo "hook dispatch accepted an event name outside the contract and the alias table" >&2
    exit 1
fi
grep -q "hook-events-v1 kind" "$TEST_DIR/kind.err"

# stdout carries only the new id; the "✓ wv-…: text" line is on stderr.
# Merging them with 2>&1 made the last line a race between the two streams,
# and under load it was the ✓ line, which then never matched active_node:
# the rc.13 verify aggregate and the commit gate both failed this way.
node=$("$WV" add "Hook dispatch fixture" --status=active \
    --criteria="fixture" --risks=low --force 2>"$TEST_DIR/add.err" | tail -1)

# expect_active <event> <payload>: the decision must be allow and name $node.
# The JSON is captured first and printed on a mismatch, so a refusal shows its
# reason instead of a bare exit 1.
expect_active() {
    local out
    out=$(printf '%s' "$2" | "$WV" hook dispatch --event="$1" --json 2>"$TEST_DIR/dispatch.err") || true
    if ! jq -e --arg node "$node" '.decision == "allow" and .active_node == $node' >/dev/null <<< "$out"; then
        echo "hook dispatch: $1 expected allow for $node, got: $out" >&2
        sed 's/^/  stderr: /' "$TEST_DIR/dispatch.err" >&2
        return 1
    fi
}
expect_active PreToolUse '{"tool_name":"Edit","tool_input":{"file_path":"README.md"}}'
expect_active PostToolUse "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$TEST_DIR/README.md\"}}"
expect_active before_edit '{"tool_name":"Edit","tool_input":{"file_path":"README.md"}}'
expect_active after_edit "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$TEST_DIR/README.md\"}}"
grep -qx "README.md" <<< "$(sqlite3 "$WV_DB" "SELECT path FROM node_files WHERE node_id='$node';")"

"$WV" update "$node" --status=done >/dev/null
"$WV" hook dispatch --event=Stop --json </dev/null | jq -e '.decision == "allow"' >/dev/null
"$WV" hook dispatch --event=session_stop --json </dev/null | jq -e '.decision == "allow" and .event == "Stop"' >/dev/null
"$WV" hook dispatch --event=session_end --json </dev/null | jq -e '.decision == "allow" and .event == "SessionEnd"' >/dev/null
"$WV" hook dispatch --event=recovery --json </dev/null | jq -e '.decision == "allow" and .event == "PreCompact"' >/dev/null

echo "hook dispatch: passed"
