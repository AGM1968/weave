#!/bin/bash
# PreToolUse hook: Block duplicate long-running Bash commands.
#
# When make check / wv sync --gh / git push / etc. go to background, Claude Code
# can issue the same command again before the first finishes. This hook maintains
# a per-repo lock file to detect and deny duplicates.
#
# Lock lifecycle:
#   PreToolUse  (this hook) — creates lock atomically, denies if already locked
#   PostToolUse (bash-dedup-post.sh) — clears lock on foreground completion
#   Liveness check — clears lock when recorded start time exceeds TTL (background)
#
# Concurrency safety: lock is acquired with set -o noclobber (atomic O_EXCL
# semantics). Two simultaneous PreToolUse calls cannot both succeed.
#
# Background limitation: background subprocess PID is not available at hook time.
# TTL is the only expiry mechanism for background commands. TTLs are deliberately
# generous — foreground commands are always cleared by bash-dedup-post.sh.

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
    TTL=1800     # 30 min — generous for slow CI machines / large test suites
elif [[ "$CMD" =~ wv[[:space:]]+sync ]]; then
    LOCK_KEY="wv-sync"
    TTL=300
elif [[ "$CMD" =~ git[[:space:]]+push ]]; then
    LOCK_KEY="git-push"
    TTL=120
elif [[ "$CMD" =~ (^|[[:space:]])\.\/install\.sh ]]; then
    LOCK_KEY="install"
    TTL=300
elif [[ "$CMD" =~ npm[[:space:]]+(run|test|build|install) ]]; then
    LOCK_KEY="npm-build"
    TTL=600
elif [[ "$CMD" =~ poetry[[:space:]]+run[[:space:]]+pytest ]]; then
    LOCK_KEY="pytest"
    TTL=300
fi

[[ -z "$LOCK_KEY" ]] && exit 0

# ── Portable repo hash (md5sum → md5 → sha256sum → fallback) ─────────────────

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
_hash_input="$REPO_ROOT"
REPO_HASH=$(
    printf '%s' "$_hash_input" | md5sum 2>/dev/null |  cut -c1-8 ||
    printf '%s' "$_hash_input" | md5    2>/dev/null |  cut -c1-8 ||
    printf '%s' "$_hash_input" | sha256sum 2>/dev/null | cut -c1-8 ||
    echo "default"
)
LOCK_DIR="/tmp/weave-bash-locks/${REPO_HASH}"
mkdir -p "$LOCK_DIR"
LOCK_FILE="${LOCK_DIR}/${LOCK_KEY}.lock"

# ── Check for existing lock (liveness: timestamp-based, TTL is fallback) ──────

if [[ -f "$LOCK_FILE" ]]; then
    # Read the start timestamp written when lock was acquired
    LOCK_START=$(head -1 "$LOCK_FILE" 2>/dev/null || echo "0")
    NOW=$(date +%s)
    # Guard: if LOCK_START is not a valid integer, treat as stale
    if [[ "$LOCK_START" =~ ^[0-9]+$ ]]; then
        LOCK_AGE=$(( NOW - LOCK_START ))
    else
        LOCK_AGE=$TTL  # force stale
    fi

    if [[ "$LOCK_AGE" -lt "$TTL" ]]; then
        PREV_CMD=$(tail -n +2 "$LOCK_FILE" 2>/dev/null | head -1 || echo "(unknown)")
        jq -n --arg key "$LOCK_KEY" --arg prev "$PREV_CMD" --argjson age "$LOCK_AGE" \
            '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":("Duplicate command blocked [\($key), \($age)s old]: already running — wait for the task-notification before re-issuing. Previous: \($prev)")}}'
        exit 0
    fi
    # Lock expired — clear stale lock before atomic acquisition
    rm -f "$LOCK_FILE"
fi

# ── Atomic lock acquisition (O_EXCL via noclobber — no TOCTOU) ────────────────
# set -o noclobber makes '>' fail if the file already exists. Two concurrent
# invocations racing here will have exactly one succeed and one fall through to
# the "already locked" denial path.

LOCK_CONTENT="$(date +%s)
${CMD}"

if (set -o noclobber; printf '%s\n' "$LOCK_CONTENT" > "$LOCK_FILE") 2>/dev/null; then
    exit 0  # Lock acquired — allow command
fi

# Race: another invocation just acquired the lock between our check and write
PREV_CMD=$(tail -n +2 "$LOCK_FILE" 2>/dev/null | head -1 || echo "(unknown)")
jq -n --arg key "$LOCK_KEY" --arg prev "$PREV_CMD" \
    '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":("Duplicate command blocked [\($key)]: just acquired by concurrent call — wait for the task-notification. Previous: \($prev)")}}'
exit 0
