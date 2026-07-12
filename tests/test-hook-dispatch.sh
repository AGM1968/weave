#!/usr/bin/env bash
# Focused regression coverage for the host-neutral hook dispatch facade.
set -euo pipefail

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

node=$("$WV" add "Hook dispatch fixture" --status=active \
    --criteria="fixture" --risks=low --force 2>&1 | tail -1)

printf '%s' '{"tool_name":"Edit","tool_input":{"file_path":"README.md"}}' \
    | "$WV" hook dispatch --event=PreToolUse --json \
    | jq -e --arg node "$node" '.decision == "allow" and .active_node == $node' >/dev/null

printf '%s' "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$TEST_DIR/README.md\"}}" \
    | "$WV" hook dispatch --event=PostToolUse --json \
    | jq -e --arg node "$node" '.decision == "allow" and .active_node == $node' >/dev/null
sqlite3 "$WV_DB" "SELECT path FROM node_files WHERE node_id='$node';" | grep -qx "README.md"

"$WV" update "$node" --status=done >/dev/null
"$WV" hook dispatch --event=Stop --json </dev/null | jq -e '.decision == "allow"' >/dev/null

echo "hook dispatch: passed"
