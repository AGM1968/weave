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
#   WV_BUDGET_THRESHOLD   — total wv call count that triggers broad advisory (default 20)
#   WV_LIST_THRESHOLD     — wv list call count that triggers list-specific advisory (default 5)
#   WV_BUDGET_DIR         — override budget dir (default /dev/shm/weave/<hash>)

set -e

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
[[ "$TOOL" != "Bash" ]] && exit 0

CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[[ -z "$CMD" ]] && exit 0

# Only count `wv ...` invocations (with or without ./scripts/ prefix). Anchored
# to command-start or after a pipe/semicolon so we do not match `find ... wv*`.
echo "$CMD" | grep -qE '(^|[;&|][[:space:]]*)(\./scripts/)?wv[[:space:]]' || exit 0

# Detect `wv list` specifically (flags allowed after; subcommands like `wv listen` excluded).
IS_LIST=false
echo "$CMD" | grep -qE '(^|[;&|][[:space:]]*)(\./scripts/)?wv[[:space:]]+list([[:space:]]|$)' && IS_LIST=true

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
LIST_CALLS=$(echo "$PRIOR" | jq -r '.list_calls // 0' 2>/dev/null || echo 0)
LIST_ADVISED=$(echo "$PRIOR" | jq -r '.list_advised // false' 2>/dev/null || echo false)
NEW_CALLS=$((CALLS + 1))
NEW_BYTES=$((TOTAL + BYTES))
NEW_LIST_CALLS="$LIST_CALLS"
[[ "$IS_LIST" = true ]] && NEW_LIST_CALLS=$((LIST_CALLS + 1))

THRESHOLD="${WV_BUDGET_THRESHOLD:-20}"
LIST_THRESHOLD="${WV_LIST_THRESHOLD:-5}"

# Suppression: still tally, but never advise.
if [[ "${WV_NONINTERACTIVE:-0}" = "1" ]] || [[ "${WV_BUDGET_DISABLE:-0}" = "1" ]]; then
    ADVISED=true
    LIST_ADVISED=true
fi

ADVISORY=""

# List-specific advisory fires first (lower threshold, more targeted message).
if [[ "$NEW_LIST_CALLS" -ge "$LIST_THRESHOLD" ]] && [[ "$LIST_ADVISED" != "true" ]]; then
    ADVISORY="wv list called ${NEW_LIST_CALLS}x this session — prefer targeted reads: wv show <id> | wv ready | wv query <preds> | wv search <topic>. Use wv list --all only for intentional full enumeration."
    LIST_ADVISED=true
fi

# Broad advisory for overall wv call volume (appended if both fire in same call).
if [[ "$NEW_CALLS" -ge "$THRESHOLD" ]] && [[ "$ADVISED" != "true" ]]; then
    KB=$((NEW_BYTES / 1024))
    BROAD="wv called ${NEW_CALLS}x this session (~${KB}KB returned). Consider --mode=execute or narrower queries (wv show <id>, wv learnings --query=<term>) to keep context lean."
    ADVISORY="${ADVISORY:+${ADVISORY} | }${BROAD}"
    ADVISED=true
fi

# Persist updated tally.
jq -n \
    --argjson calls "$NEW_CALLS" \
    --argjson bytes "$NEW_BYTES" \
    --argjson advised "$ADVISED" \
    --argjson list_calls "$NEW_LIST_CALLS" \
    --argjson list_advised "$LIST_ADVISED" \
    '{calls:$calls, bytes:$bytes, advised:$advised, list_calls:$list_calls, list_advised:$list_advised}' \
    > "$BUDGET_FILE" 2>/dev/null || true

if [[ -n "$ADVISORY" ]]; then
    jq -n --arg msg "$ADVISORY" '{additionalContext: $msg}'
fi

exit 0
