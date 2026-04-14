#!/bin/bash
# PostToolUse hook: Release or promote bash-dedup locks after a Bash command.
#
# Foreground commands: clear ALL matching locks immediately (command is done).
# Background commands: promote ALL matching locks from phase=pending to phase=running,
#   storing the backgroundTaskId in the lock (line 4) so that PreToolUse can use
#   fuser/lsof on the task output file to detect completion rather than waiting
#   for TTL to expire.
#
# Lock file format after promotion (4 lines):
#   line 1: original epoch from PreToolUse (preserved)
#   line 2: "running"
#   line 3: original command (preserved)
#   line 4: backgroundTaskId (e.g. "b10rim7fu"; empty string if unknown)
#
# PreToolUse globs /tmp/claude-*/*/tasks/<taskId>.output and checks fuser/lsof
# to detect when the background subprocess has released the file.
#
# "ALL matching" matters because a compound command (e.g. "wv sync && git push")
# can match multiple lock-key patterns. PreToolUse creates only one lock (first
# match), but this hook clears/promotes all matches for defensive correctness.

set -e

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

[[ "$TOOL" != "Bash" && "$TOOL" != "run_in_terminal" ]] && exit 0

# Always read RESPONSE_OUT — used for background fallback detection.
RESPONSE_OUT=$(echo "$INPUT" | jq -r '.tool_response.output // ""' 2>/dev/null)

# Detect background execution.
# Primary signal: tool_input.run_in_background field.
# Fallback: response output contains Claude Code's background task header
#   (occurs when run_in_background was not set explicitly but Claude Code
#   still ran the command in background via its own heuristics).
RUN_IN_BG=$(echo "$INPUT" | jq -r '.tool_input.run_in_background // false' 2>/dev/null)
if [[ "$RUN_IN_BG" != "true" ]]; then
    [[ "$RESPONSE_OUT" == *"Command running in background with ID:"* ]] && RUN_IN_BG="true"
fi

# Extract background task ID for liveness checking.
# For explicit run_in_background=true: tool_response.backgroundTaskId is populated;
#   tool_response.output is null (the "Output is being written to:" message is shown
#   in the conversation UI but is not in the raw tool_response JSON).
# For implicit background (fallback path): extract task ID from response output text.
_TASK_ID=""
if [[ "$RUN_IN_BG" == "true" ]]; then
    _TASK_ID=$(echo "$INPUT" | jq -r '.tool_response.backgroundTaskId // ""' 2>/dev/null)
    # Fallback: parse from response output text (implicit background path)
    if [[ -z "$_TASK_ID" ]]; then
        _TASK_ID=$(echo "$RESPONSE_OUT" \
            | sed -n 's/.*running in background with ID: \([^ .]*\).*/\1/p' \
            2>/dev/null || echo "")
    fi
    # Validate: task IDs are alphanumeric; reject anything suspicious
    [[ "$_TASK_ID" =~ ^[a-z0-9]+$ ]] || _TASK_ID=""
fi

CMD=$(echo "$INPUT" | jq -r '.tool_input.command // .tool_input.cmd // empty' 2>/dev/null)
[[ -z "$CMD" ]] && exit 0

# ── Portable repo hash (md5sum → md5 → sha256sum → fallback) ─────────────────

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
# Use echo to match hash convention in bash-dedup.sh and all other hooks
REPO_HASH=$(
    echo "$REPO_ROOT" | md5sum    2>/dev/null | cut -c1-8 ||
    echo "$REPO_ROOT" | md5       2>/dev/null | cut -c1-8 ||
    echo "$REPO_ROOT" | sha256sum 2>/dev/null | cut -c1-8 ||
    echo "default"
)
LOCK_DIR="/tmp/weave-bash-locks/${REPO_HASH}"

# ── Helper: process one lock key ──────────────────────────────────────────────
# For foreground: clears the lock (command is done).
# For background: promotes pending→running and stores backgroundTaskId so
#   PreToolUse can do fuser/lsof liveness checks on the task output file.

_handle_lock() {
    local key="$1" pattern="$2"
    [[ "$CMD" =~ $pattern ]] || return 0

    local lock_file="${LOCK_DIR}/${key}.lock"
    [[ -f "$lock_file" ]] || return 0

    if [[ "$RUN_IN_BG" == "true" ]]; then
        # Promote: rewrite lock with phase=running, preserving original epoch and cmd.
        # Store backgroundTaskId on line 4 for fuser-based liveness checking.
        local epoch cmd_line
        epoch=$(sed -n '1p' "$lock_file" 2>/dev/null || date +%s)
        cmd_line=$(sed -n '3p' "$lock_file" 2>/dev/null || echo "$CMD")
        # Guard: old 2-line format — cmd is on line 2, no phase line
        if [[ ! "$epoch" =~ ^[0-9]+$ ]]; then
            epoch=$(date +%s)
            cmd_line=$(sed -n '2p' "$lock_file" 2>/dev/null || echo "$CMD")
        fi
        printf '%s\nrunning\n%s\n%s\n' "$epoch" "$cmd_line" "${_TASK_ID}" \
            > "$lock_file" 2>/dev/null || true
    else
        rm -f "$lock_file" 2>/dev/null || true
    fi
}

# ── Process all lock-key patterns ─────────────────────────────────────────────
# Patterns must stay in sync with bash-dedup.sh.

_handle_lock "make-build" "(^|[;[:space:]])(make[[:space:]]+(check|test|build)|make[[:space:]]*$)"
_handle_lock "wv-sync"    "(^|[[:space:]]*[;&|]+[[:space:]]*)wv[[:space:]]+sync"
_handle_lock "git-push"   "(^|[[:space:]]*[;&|]+[[:space:]]*)git[[:space:]]+push"
_handle_lock "install"    "(^|[[:space:]])\.\/install\.sh"
_handle_lock "npm-build"  "npm[[:space:]]+(run|test|build|install)"
_handle_lock "pytest"     "poetry[[:space:]]+run[[:space:]]+pytest"

exit 0
