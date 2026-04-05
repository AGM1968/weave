#!/bin/bash
# PreToolUse hook: Block duplicate long-running Bash commands.
#
# When make check / wv sync --gh / git push / etc. go to background, Claude Code
# can issue the same command again before the first finishes. This hook maintains
# a per-repo lock file to detect and deny duplicates.
#
# Lock lifecycle:
#   PreToolUse  (this hook) — creates lock, denies if already locked
#   PostToolUse (bash-dedup-post.sh) — clears lock on foreground completion
#   TTL expiry  — auto-clears stale locks for background commands

set -e

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

[[ "$TOOL" != "Bash" && "$TOOL" != "run_in_terminal" ]] && exit 0

CMD=$(echo "$INPUT" | jq -r '.tool_input.command // .tool_input.cmd // empty' 2>/dev/null)
[[ -z "$CMD" ]] && exit 0

# ── Classify command and assign TTL (seconds) ──────────────────────────────────

LOCK_KEY=""
TTL=0

if [[ "$CMD" =~ (^|[;[:space:]])(make[[:space:]]+(check|test|build)|make[[:space:]]*$) ]]; then
    LOCK_KEY="make-build"
    TTL=600
elif [[ "$CMD" =~ wv[[:space:]]+sync ]]; then
    LOCK_KEY="wv-sync"
    TTL=180
elif [[ "$CMD" =~ git[[:space:]]+push ]]; then
    LOCK_KEY="git-push"
    TTL=90
elif [[ "$CMD" =~ (^|[[:space:]])\.\/install\.sh ]]; then
    LOCK_KEY="install"
    TTL=180
elif [[ "$CMD" =~ npm[[:space:]]+(run|test|build|install) ]]; then
    LOCK_KEY="npm-build"
    TTL=300
elif [[ "$CMD" =~ poetry[[:space:]]+run[[:space:]]+pytest ]]; then
    LOCK_KEY="pytest"
    TTL=180
fi

[[ -z "$LOCK_KEY" ]] && exit 0

# ── Scope lock per repo to avoid cross-project interference ──────────────────

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
REPO_HASH=$(echo "$REPO_ROOT" | md5sum | cut -c1-8)
LOCK_DIR="/tmp/weave-bash-locks/${REPO_HASH}"
mkdir -p "$LOCK_DIR"
LOCK_FILE="${LOCK_DIR}/${LOCK_KEY}.lock"

# ── Check for existing lock ────────────────────────────────────────────────────

if [[ -f "$LOCK_FILE" ]]; then
    LOCK_AGE=$(( $(date +%s) - $(stat -c %Y "$LOCK_FILE" 2>/dev/null || echo 0) ))
    if [[ "$LOCK_AGE" -lt "$TTL" ]]; then
        PREV_CMD=$(head -1 "$LOCK_FILE" 2>/dev/null || echo "(unknown)")
        jq -n --arg key "$LOCK_KEY" --arg prev "$PREV_CMD" \
            '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":("Duplicate command blocked [\($key)]: already running — wait for the task-notification before re-issuing. Previous: \($prev)")}}'
        exit 0
    fi
    # Stale lock — clear it and continue
    rm -f "$LOCK_FILE"
fi

# ── Acquire lock ───────────────────────────────────────────────────────────────

printf '%s' "$CMD" > "$LOCK_FILE"
exit 0
