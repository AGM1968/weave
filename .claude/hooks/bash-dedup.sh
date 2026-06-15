#!/bin/bash
# PreToolUse hook: Block duplicate long-running Bash commands.
#
# When make check / wv sync --gh / git push / etc. go to background, Claude Code
# can issue the same command again before the first finishes. This hook maintains
# a per-repo lock file to detect and deny duplicates.
#
# Lock lifecycle:
#   PreToolUse  (this hook) — creates lock atomically with phase=pending, denies if locked
#   PostToolUse (bash-dedup-post.sh) — promotes background to phase=running; clears foreground
#   SessionStart (session-start-context.sh) — clears all locks (cross-session stale cleanup)
#   Liveness check — pending locks expire after GRACE_PERIOD; running locks expire after TTL
#
# Two-phase lock (fixes orphaned locks from hard-blocked tool calls):
#   pending — lock was created in PreToolUse but PostToolUse has not yet confirmed
#             that the tool actually ran. Expires after GRACE_PERIOD (120s).
#             Covers the window between a PreToolUse block (tool denied, PostToolUse
#             never fires) and the next attempt.
#   running — PostToolUse confirmed the tool started (background path only).
#             Expires after TTL. Foreground completions skip this state; PostToolUse
#             clears the lock directly.
#
# Why GRACE_PERIOD=120s: all foreground commands protected here complete in <90s
# (sync/push/install <60s; make check foreground ~90s). 120s gives 30s headroom.
# Background commands are promoted to "running" by PostToolUse within ~2s of
# launch, so GRACE_PERIOD is irrelevant for them.
#
# Concurrency safety: lock is acquired with set -o noclobber (atomic O_EXCL
# semantics). Two simultaneous PreToolUse calls cannot both succeed.
#
# Hook parallelism: Claude Code runs all matching PreToolUse hooks concurrently.
# If another hook hard-blocks the tool (exit 2), PostToolUse does not fire and
# the lock is orphaned. GRACE_PERIOD is the self-healing mechanism for this case.

set -e

GRACE_PERIOD=120   # seconds before a pending lock is treated as stale

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

[[ "$TOOL" != "Bash" && "$TOOL" != "run_in_terminal" ]] && exit 0

CMD=$(echo "$INPUT" | jq -r '.tool_input.command // .tool_input.cmd // empty' 2>/dev/null)
[[ -z "$CMD" ]] && exit 0

# ── Strip quoted argument regions before classifying ───────────────────────────
# A substring like `make check` inside `--learning="... make check passes ..."`
# must NOT trigger the make-build lock — the user is writing prose into a
# quoted argument, not invoking make. sed removes "..." and '...' regions so
# the regexes only see the outer shell syntax. Escaped quotes are rare in the
# commands we match; failing-closed (not matching) is safe.
CMD_STRIPPED=$(printf '%s' "$CMD" | sed -E 's/"[^"]*"//g; s/'"'"'[^'"'"']*'"'"'//g')

# ── Classify command and assign TTL (seconds) ──────────────────────────────────
# TTL applies to phase=running (background commands). Must reflect realistic
# worst-case completion time for each command type. All anchors use structural
# shell separators (^, ;, &, |, whitespace) — they are evaluated against
# CMD_STRIPPED, so substrings inside quoted arguments cannot match.

LOCK_KEY=""
TTL=0

# ── Busy-wait poller detection ─────────────────────────────────────────────────
# An `until …; do … sleep N; done` / `while …; do … sleep N; done` loop spawned
# to watch a backgrounded task is the anti-pattern this guard closes: it is not a
# classified expensive command, so without this check it sails past the lock and
# busy-waits (the v1.59.1 zombie-watcher regression). Detected on CMD_STRIPPED so
# the words "until"/"sleep" inside a quoted argument (prose) do not trigger it.
# The deny decision is gated on an actually-live background lock below, so a
# legitimate poll loop with nothing in flight is still allowed.
IS_POLLER=false
if [[ "$CMD_STRIPPED" =~ (^|[;&|[:space:]])(until|while)[[:space:]] ]] \
   && [[ "$CMD_STRIPPED" =~ (^|[;&|[:space:]])sleep[[:space:]] ]]; then
    IS_POLLER=true
fi

if [[ "$CMD_STRIPPED" =~ (^|[;[:space:]])(make[[:space:]]+(check|test|build)|make[[:space:]]*$) ]]; then
    LOCK_KEY="make-build"
    TTL=600      # 10 min — covers slow CI machines (local suite runs ~90s)
elif [[ "$CMD_STRIPPED" =~ (^|[[:space:]]*[;&|]+[[:space:]]*)wv[[:space:]]+sync ]]; then
    LOCK_KEY="wv-sync"
    TTL=60       # sync completes in <15s under normal conditions
elif [[ "$CMD_STRIPPED" =~ (^|[[:space:]]*[;&|]+[[:space:]]*)git[[:space:]]+commit ]]; then
    LOCK_KEY="git-commit"
    TTL=600      # pre-commit hook runs impact-selected test suites; p95 373s (test-core)
elif [[ "$CMD_STRIPPED" =~ (^|[[:space:]]*[;&|]+[[:space:]]*)git[[:space:]]+push ]]; then
    LOCK_KEY="git-push"
    TTL=60       # push to remote; allow up to 60s for slow connections
elif [[ "$CMD_STRIPPED" =~ (^|[[:space:]])\.\/install\.sh ]]; then
    LOCK_KEY="install"
    TTL=120      # first-run install can be slow; <2min in practice
elif [[ "$CMD_STRIPPED" =~ (^|[;[:space:]])npm[[:space:]]+(run|test|build|install) ]]; then
    LOCK_KEY="npm-build"
    TTL=300      # npm install can be slow on cold cache
elif [[ "$CMD_STRIPPED" =~ (^|[;[:space:]])poetry[[:space:]]+run[[:space:]]+pytest ]]; then
    LOCK_KEY="pytest"
    TTL=120      # test suite runs in <90s
fi

# A normal command with no lock key and not a poller: nothing to do.
[[ -z "$LOCK_KEY" && "$IS_POLLER" != "true" ]] && exit 0

# ── Portable repo hash (md5sum → md5 → sha256sum → fallback) ─────────────────

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
# Use echo (not printf) to match the newline convention used by all other hooks
# and wv-config.sh — they all hash "$REPO_ROOT\n". Diverging here causes a
# different hash and a different lock directory from the rest of the system.
REPO_HASH=$(
    echo "$REPO_ROOT" | md5sum    2>/dev/null | cut -c1-8 ||
    echo "$REPO_ROOT" | md5       2>/dev/null | cut -c1-8 ||
    echo "$REPO_ROOT" | sha256sum 2>/dev/null | cut -c1-8 ||
    echo "default"
)
LOCK_DIR="/tmp/weave-bash-locks/${REPO_HASH}"
mkdir -p "$LOCK_DIR"

# ── Live background-lock scan (shared by the poller guard) ──────────────────────
# Prints "<lock-key>|<original-cmd>" for the first running lock whose background
# task is still alive, else nothing. Liveness is the same signal the lock
# expiry uses: a running lock's task-output file still held by a process (fuser
# /lsof) means in-flight; once released the task has finished and the lock is
# treated as stale (skipped). With no task id (foreground) or no fuser/lsof,
# fall back to a generous age window so a fresh lock still reads as live.
_first_live_bg_lock() {
    local lf key phase epoch task_id cmd now age out claude_uid
    now=$(date +%s)
    claude_uid=$(id -u 2>/dev/null || echo "$UID")
    for lf in "$LOCK_DIR"/*.lock; do
        [[ -f "$lf" ]] || continue
        epoch=$(sed -n '1p' "$lf" 2>/dev/null || echo 0)
        phase=$(sed -n '2p' "$lf" 2>/dev/null || echo running)
        cmd=$(sed -n '3p'  "$lf" 2>/dev/null || echo "(unknown)")
        task_id=$(sed -n '4p' "$lf" 2>/dev/null || echo "")
        [[ "$phase" == "running" ]] || continue
        [[ "$epoch" =~ ^[0-9]+$ ]] || continue
        age=$(( now - epoch ))
        key="${lf##*/}"; key="${key%.lock}"
        if [[ "$task_id" =~ ^[a-z0-9]+$ ]]; then
            out=$(ls "/tmp/claude-${claude_uid}"/*/*/tasks/"${task_id}".output 2>/dev/null | head -1 || echo "")
            if [[ -n "$out" ]]; then
                if command -v fuser >/dev/null 2>&1; then
                    fuser "$out" >/dev/null 2>&1 || continue   # released → finished → stale
                elif command -v lsof >/dev/null 2>&1; then
                    lsof "$out" >/dev/null 2>&1 || continue
                elif [[ "$age" -ge 600 ]]; then
                    continue
                fi
                printf '%s|%s\n' "$key" "$cmd"
                return 0
            fi
        fi
        # No task id / output file gone: a recently-created running lock is
        # probably still live — use the age window.
        if [[ "$age" -lt 600 ]]; then
            printf '%s|%s\n' "$key" "$cmd"
            return 0
        fi
    done
    return 1
}

# ── Poller guard ────────────────────────────────────────────────────────────────
# Deny a busy-wait loop only while a tracked background task is actually live —
# that is exactly the regression (background a commit/make, then spawn a watcher
# loop instead of yielding for the completion notification). With nothing in
# flight the loop is allowed, so legitimate `until cond; do sleep; done` waits
# are unaffected.
if [[ "$IS_POLLER" == "true" ]]; then
    _live=$(_first_live_bg_lock || true)
    if [[ -n "$_live" ]]; then
        _lkey="${_live%%|*}"
        _lcmd="${_live#*|}"
        jq -n --arg key "$_lkey" --arg prev "$_lcmd" \
            '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":("Busy-wait poller blocked: a background [\($key)] task is still running. Do not poll it with until/while+sleep — yield the turn and the harness will send a task-notification when it completes. Running: \($prev)")}}'
        exit 0
    fi
    # No live background task — allow the loop. (If it also matched a lock key,
    # the loop form is pathological for that command; we still allow without
    # taking the key lock, which is harmless.)
    exit 0
fi

LOCK_FILE="${LOCK_DIR}/${LOCK_KEY}.lock"

# ── Check for existing lock ────────────────────────────────────────────────────
# Lock file format (4 lines):
#   line 1: epoch timestamp of lock creation
#   line 2: phase — "pending" or "running"
#   line 3: original command
#   line 4: backgroundTaskId (set by bash-dedup-post.sh on promotion to running;
#            empty string for foreground commands or when ID was unavailable)

if [[ -f "$LOCK_FILE" ]]; then
    LOCK_EPOCH=$(sed -n '1p' "$LOCK_FILE" 2>/dev/null || echo "0")
    LOCK_PHASE=$(sed -n '2p' "$LOCK_FILE" 2>/dev/null || echo "running")
    PREV_CMD=$(sed -n '3p'  "$LOCK_FILE" 2>/dev/null || echo "(unknown)")
    TASK_ID=$(sed -n '4p'   "$LOCK_FILE" 2>/dev/null || echo "")
    NOW=$(date +%s)

    # Guard: treat non-integer epoch as stale
    if [[ "$LOCK_EPOCH" =~ ^[0-9]+$ ]]; then
        LOCK_AGE=$(( NOW - LOCK_EPOCH ))
    else
        LOCK_AGE=$GRACE_PERIOD  # force stale
    fi

    # Backward compat: old 2-line format has cmd on line 2 (not a phase keyword).
    # Treat any unrecognised phase as "running" (conservative: use TTL).
    if [[ "$LOCK_PHASE" != "pending" && "$LOCK_PHASE" != "running" ]]; then
        PREV_CMD="$LOCK_PHASE"  # line 2 was the cmd in old format; capture before overwrite
        LOCK_PHASE="running"
    fi

    # ── Liveness check for running locks ──────────────────────────────────────
    # bash-dedup-post.sh stores the backgroundTaskId in lock line 4 on promotion.
    # Claude Code writes task output to: /tmp/claude-*/*/tasks/<taskId>.output
    # If no process has that file open (fuser/lsof), the background subprocess
    # has exited and the lock is stale — regardless of TTL.
    # Falls back to TTL if task ID unknown or fuser/lsof unavailable.
    if [[ "$LOCK_PHASE" == "running" && "$TASK_ID" =~ ^[a-z0-9]+$ ]]; then
        # Glob for the task output file — path is /tmp/claude-<uid>/<repo-slug>/<session>/tasks/<id>.output
        # Restrict to our own UID so cross-user TASK_ID collisions cannot
        # trick us into reading another user's output file (security L4).
        CLAUDE_UID=$(id -u 2>/dev/null || echo "$UID")
        OUTPUT_FILE=$(ls "/tmp/claude-${CLAUDE_UID}"/*/*/tasks/"${TASK_ID}".output 2>/dev/null | head -1 || echo "")
        if [[ -n "$OUTPUT_FILE" ]]; then
            if command -v fuser >/dev/null 2>&1; then
                # fuser exits 1 when no process has the file open
                fuser "$OUTPUT_FILE" >/dev/null 2>&1 || LOCK_AGE=$TTL
            elif command -v lsof >/dev/null 2>&1; then
                lsof "$OUTPUT_FILE" >/dev/null 2>&1 || LOCK_AGE=$TTL
            fi
            # No fuser/lsof: fall through to TTL-based check
        fi
        # Output file not found: task may not have written yet (very recent launch)
        # or file was cleaned up. Fall through to TTL — safe, conservative.
    fi

    if [[ "$LOCK_PHASE" == "pending" ]]; then
        THRESHOLD=$GRACE_PERIOD
        PHASE_LABEL="pending, blocked or slow-start"
    else
        THRESHOLD=$TTL
        PHASE_LABEL="running"
    fi

    if [[ "$LOCK_AGE" -lt "$THRESHOLD" ]]; then
        jq -n --arg key "$LOCK_KEY" --arg prev "$PREV_CMD" \
               --argjson age "$LOCK_AGE" --arg phase "$PHASE_LABEL" \
            '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":("Duplicate command blocked [\($key), \($age)s old, \($phase)]: already running — wait for the task-notification before re-issuing. Previous: \($prev)")}}'
        exit 0
    fi
    # Lock expired or stale pending — clear before atomic acquisition
    rm -f "$LOCK_FILE"
fi

# ── Atomic lock acquisition (O_EXCL via noclobber — no TOCTOU) ────────────────
# set -o noclobber makes '>' fail if the file already exists. Two concurrent
# invocations racing here will have exactly one succeed and one fall through to
# the "already locked" denial path.

LOCK_CONTENT="$(date +%s)
pending
${CMD}"

if (set -o noclobber; printf '%s\n' "$LOCK_CONTENT" > "$LOCK_FILE") 2>/dev/null; then
    exit 0  # Lock acquired — allow command
fi

# Race: another invocation just acquired the lock between our check and write
PREV_CMD=$(sed -n '3p' "$LOCK_FILE" 2>/dev/null || echo "(unknown)")
jq -n --arg key "$LOCK_KEY" --arg prev "$PREV_CMD" \
    '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":("Duplicate command blocked [\($key)]: just acquired by concurrent call — wait for the task-notification. Previous: \($prev)")}}'
exit 0
