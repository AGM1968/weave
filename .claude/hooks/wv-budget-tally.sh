#!/bin/bash
# PostToolUse hook: tally bytes returned by `wv` calls into a per-session
# budget file. After a threshold of calls, emit a one-shot advisory that
# the agent is calling wv broadly; suggest --mode=execute or narrower
# queries. Soft advisory via additionalContext — never blocks.
#
# Counter-weight A2 from PROPOSAL-wv-active-counterweight (BudgetMiddleware
# analogue). The runtime tracked per-call output bytes; this hook does the
# equivalent for sessions where wv is invoked via Bash.
#
# Suppression:
#   WV_NONINTERACTIVE=1  — skip advisory (still tally)
#   WV_BUDGET_DISABLE=1  — skip advisory (still tally)
#
# Tunables:
#   WV_BUDGET_THRESHOLD  — call count that triggers advisory (default 20)
#   WV_BUDGET_DIR        — override budget dir (default /dev/shm/weave/<hash>)

set -e

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
[[ "$TOOL" != "Bash" ]] && exit 0

CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[[ -z "$CMD" ]] && exit 0

# Only count `wv ...` invocations (with or without ./scripts/ prefix). Anchored
# to command-start or after a pipe/semicolon so we do not match `find ... wv*`.
echo "$CMD" | grep -qE '(^|[;&|][[:space:]]*)(\./scripts/)?wv[[:space:]]' || exit 0

# Per-repo budget file on tmpfs (matches the hot-zone naming used elsewhere).
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
REPO_HASH=$(echo "$REPO_ROOT" | md5sum 2>/dev/null | cut -c1-8 || echo "default")
[[ -z "$REPO_HASH" ]] && REPO_HASH="default"
BUDGET_DIR="${WV_BUDGET_DIR:-/dev/shm/weave/${REPO_HASH}}"
BUDGET_FILE="${BUDGET_DIR}/session-budget.json"
mkdir -p "$BUDGET_DIR" 2>/dev/null || exit 0

OUTPUT=$(echo "$INPUT" | jq -r '.tool_response.output // ""' 2>/dev/null)
BYTES=${#OUTPUT}

# Read prior tally (default zeros).
PRIOR=$(cat "$BUDGET_FILE" 2>/dev/null || echo '{}')
CALLS=$(echo "$PRIOR" | jq -r '.calls // 0' 2>/dev/null || echo 0)
TOTAL=$(echo "$PRIOR" | jq -r '.bytes // 0' 2>/dev/null || echo 0)
ADVISED=$(echo "$PRIOR" | jq -r '.advised // false' 2>/dev/null || echo false)
NEW_CALLS=$((CALLS + 1))
NEW_BYTES=$((TOTAL + BYTES))

THRESHOLD="${WV_BUDGET_THRESHOLD:-20}"

# Suppression: still tally, but never advise.
if [[ "${WV_NONINTERACTIVE:-0}" = "1" ]] || [[ "${WV_BUDGET_DISABLE:-0}" = "1" ]]; then
    ADVISED=true
fi

ADVISORY=""
if [[ "$NEW_CALLS" -ge "$THRESHOLD" ]] && [[ "$ADVISED" != "true" ]]; then
    KB=$((NEW_BYTES / 1024))
    ADVISORY="wv called ${NEW_CALLS}x this session (~${KB}KB returned). Consider --mode=execute or narrower queries (wv show <id>, wv learnings --query=<term>) to keep context lean."
    ADVISED=true
fi

# Persist updated tally.
jq -n \
    --argjson calls "$NEW_CALLS" \
    --argjson bytes "$NEW_BYTES" \
    --argjson advised "$ADVISED" \
    '{calls:$calls, bytes:$bytes, advised:$advised}' \
    > "$BUDGET_FILE" 2>/dev/null || true

if [[ -n "$ADVISORY" ]]; then
    jq -n --arg msg "$ADVISORY" '{additionalContext: $msg}'
fi

exit 0
