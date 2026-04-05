#!/bin/bash
# PostToolUse hook: Release bash-dedup lock when a foreground command completes.
#
# For background commands (run_in_background=true) we do NOT clear the lock here —
# the background task is still running. The TTL in bash-dedup.sh handles expiry.

set -e

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

[[ "$TOOL" != "Bash" && "$TOOL" != "run_in_terminal" ]] && exit 0

# Do not clear lock for background commands — they are still running
RUN_IN_BG=$(echo "$INPUT" | jq -r '.tool_input.run_in_background // false' 2>/dev/null)
[[ "$RUN_IN_BG" == "true" ]] && exit 0

CMD=$(echo "$INPUT" | jq -r '.tool_input.command // .tool_input.cmd // empty' 2>/dev/null)
[[ -z "$CMD" ]] && exit 0

LOCK_KEY=""
if [[ "$CMD" =~ (^|[;[:space:]])(make[[:space:]]+(check|test|build)|make[[:space:]]*$) ]]; then
    LOCK_KEY="make-build"
elif [[ "$CMD" =~ wv[[:space:]]+sync ]]; then
    LOCK_KEY="wv-sync"
elif [[ "$CMD" =~ git[[:space:]]+push ]]; then
    LOCK_KEY="git-push"
elif [[ "$CMD" =~ (^|[[:space:]])\.\/install\.sh ]]; then
    LOCK_KEY="install"
elif [[ "$CMD" =~ npm[[:space:]]+(run|test|build|install) ]]; then
    LOCK_KEY="npm-build"
elif [[ "$CMD" =~ poetry[[:space:]]+run[[:space:]]+pytest ]]; then
    LOCK_KEY="pytest"
fi

[[ -z "$LOCK_KEY" ]] && exit 0

# ── Portable repo hash (md5sum → md5 → sha256sum → fallback) ─────────────────

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
REPO_HASH=$(
    printf '%s' "$REPO_ROOT" | md5sum    2>/dev/null | cut -c1-8 ||
    printf '%s' "$REPO_ROOT" | md5       2>/dev/null | cut -c1-8 ||
    printf '%s' "$REPO_ROOT" | sha256sum 2>/dev/null | cut -c1-8 ||
    echo "default"
)
LOCK_FILE="/tmp/weave-bash-locks/${REPO_HASH}/${LOCK_KEY}.lock"

rm -f "$LOCK_FILE" 2>/dev/null || true
exit 0
