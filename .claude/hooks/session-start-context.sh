#!/bin/bash
# SessionStart hook: Inject active work context
# Provides compressed Weave status at session start
# Includes crash sentinel detection (v1.16.0)

set -e

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/../lib/wv-resolve-project.sh" 2>/dev/null || source "$HOOK_DIR/../../scripts/lib/wv-resolve-project.sh" || exit 0

# Check if wv is available
if [ ! -x "$WV" ]; then
    echo "wv CLI not found"
    exit 0
fi

# Resolve hot zone path (mirrors wv-config.sh logic)
_SS_REPO_HASH=$(echo "$WV_PROJECT_DIR" | md5sum | cut -c1-8)
_SS_HOT_ZONE="${WV_HOT_ZONE:-/dev/shm/weave/${_SS_REPO_HASH}}"
SENTINEL="${_SS_HOT_ZONE}/.session_sentinel"

# ── Clear stale bash-dedup locks from the previous session ────────────────────
# bash-dedup.sh uses the same repo hash to locate lock files. Any lock still
# present at SessionStart is orphaned (crash, hard-block with no PostToolUse,
# or session killed). Clear them all so this session starts with a clean slate.
_SS_DEDUP_DIR="/tmp/weave-bash-locks/${_SS_REPO_HASH}"
if [[ -d "$_SS_DEDUP_DIR" ]]; then
    rm -f "${_SS_DEDUP_DIR}"/*.lock 2>/dev/null || true
fi

# ── Harvest last prompt from most recent Claude JSONL (best-effort) ──
# Used to enrich crash/reboot recovery context with conversation intent.
_SS_LAST_PROMPT=""
_SS_CLAUDE_SLUG=$(echo "$WV_PROJECT_DIR" | tr '/' '-')
_SS_CLAUDE_DIR="$HOME/.claude/projects/${_SS_CLAUDE_SLUG}"
if [ -d "$_SS_CLAUDE_DIR" ]; then
    _SS_RECENT_JSONL=$(ls -t "$_SS_CLAUDE_DIR"/*.jsonl 2>/dev/null | head -1)
    if [ -n "$_SS_RECENT_JSONL" ]; then
        _SS_LAST_PROMPT=$(python3 - "$_SS_RECENT_JSONL" 2>/dev/null <<'PYEOF'
import json, sys
last_prompt = ""
last_user = ""
for line in open(sys.argv[1]):
    try:
        d = json.loads(line)
        if d.get("type") == "last-prompt":
            last_prompt = d.get("lastPrompt", "")
        elif d.get("role") == "user":
            content = d.get("message", {}).get("content", "")
            if isinstance(content, list):
                for c in content:
                    if isinstance(c, dict) and c.get("type") == "text":
                        t = c.get("text", "").strip()
                        if t and not t.startswith("<"):
                            last_user = t[:120]
    except Exception:
        pass
print((last_prompt or last_user)[:120])
PYEOF
        ) || _SS_LAST_PROMPT=""
    fi
fi

# ── Crash detection: check for previous session's sentinel ──
# Sentinel present = previous session did not call session-end-sync.sh
CRASH_WARNING=""
HAD_SENTINEL=false
if [ -f "$SENTINEL" ]; then
    HAD_SENTINEL=true
    CRASH_DATA=$(cat "$SENTINEL" 2>/dev/null || echo "{}")
    CRASH_TS=$(echo "$CRASH_DATA" | jq -r '.ts // "unknown"' 2>/dev/null || echo "unknown")
    CRASH_ACTIVE=$(echo "$CRASH_DATA" | jq -r '.active | join(", ")' 2>/dev/null || echo "unknown")

    _CRASH_MSG="CRASH RECOVERY: Session killed at ${CRASH_TS}. Active nodes at crash: ${CRASH_ACTIVE}."
    [ -n "$_SS_LAST_PROMPT" ] && _CRASH_MSG="${_CRASH_MSG} Last prompt: '${_SS_LAST_PROMPT}'"
    _CRASH_MSG="${_CRASH_MSG} Review and re-claim or close active nodes."

    # Auto-generate recovery breadcrumb
    "$WV" breadcrumbs save --message="$_CRASH_MSG" >/dev/null 2>&1 || true

    CRASH_WARNING="CRASH DETECTED: previous session ended abruptly at ${CRASH_TS}. Active at crash: ${CRASH_ACTIVE}."
    [ -n "$_SS_LAST_PROMPT" ] && CRASH_WARNING="${CRASH_WARNING} Last prompt: '${_SS_LAST_PROMPT}'"
    CRASH_WARNING="${CRASH_WARNING} Recovery breadcrumb saved."
fi

# ── Write minimal sentinel BEFORE wv load (crash-during-load detectable) ──
mkdir -p "$_SS_HOT_ZONE" 2>/dev/null || true
# Write session epoch for stale-node detection in pre-action.sh
date +%s > "${_SS_HOT_ZONE}/.session_epoch" 2>/dev/null || true
jq -n \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson pid $$ \
    '{ts: $ts, active: [], pid: $pid, phase: "loading"}' \
    > "$SENTINEL" 2>/dev/null || rm -f "$SENTINEL"

# Ensure DB is loaded
"$WV" load >/dev/null 2>&1 || true

# Commit any .weave/ state written during session-start (crash-recovery breadcrumbs,
# migrations). Without this, the stop-hook fires on the first response with
# "unsaved weave state" for changes the agent didn't cause.
(
    set +e
    cd "$WV_PROJECT_DIR" 2>/dev/null || exit 0
    git add .weave/ 2>/dev/null
    if ! git diff --cached --quiet -- .weave/ 2>/dev/null; then
        WV_AUTO_CHECKPOINT_ACTIVE=1 git commit -m "chore(weave): session-start state [skip ci]" 2>/dev/null
    fi
) || true

# ── Overwrite sentinel with full active node list ──
ACTIVE_IDS=$("$WV" list --status=active --json 2>/dev/null | jq -c '[.[].id]' 2>/dev/null || echo "[]")
jq -n \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson active "$ACTIVE_IDS" \
    --argjson pid $$ \
    '{ts: $ts, active: $active, pid: $pid}' \
    > "$SENTINEL" 2>/dev/null || rm -f "$SENTINEL"

# Get compressed work status using wv status (already formatted)
STATUS=$("$WV" status 2>/dev/null || echo "Work: 0 active, 0 ready, 0 blocked.")
CONTEXT="$STATUS"

# Prepend crash warning if detected
if [ -n "$CRASH_WARNING" ]; then
    CONTEXT="${CRASH_WARNING}
${CONTEXT}"
fi

# Secondary detection: active nodes but no sentinel at session start (reboot recovery)
ACTIVE_COUNT=$(echo "$ACTIVE_IDS" | jq 'length' 2>/dev/null || echo "0")
if [ "$ACTIVE_COUNT" -gt 0 ] && [ -z "$CRASH_WARNING" ] && [ "$HAD_SENTINEL" = false ]; then
    _REBOOT_NOTE="Note: ${ACTIVE_COUNT} nodes marked active from a previous session."
    [ -n "$_SS_LAST_PROMPT" ] && _REBOOT_NOTE="${_REBOOT_NOTE} Last prompt: '${_SS_LAST_PROMPT}'"
    _REBOOT_NOTE="${_REBOOT_NOTE} Run 'wv recover --session' to review."
    CONTEXT="${_REBOOT_NOTE}
${CONTEXT}"
fi

# Append health score (single line, best effort)
HEALTH_JSON=$("$WV" health --json 2>/dev/null || echo "")
if [ -n "$HEALTH_JSON" ]; then
    HEALTH_SCORE=$(echo "$HEALTH_JSON" | jq -r '.score // empty' 2>/dev/null || true)
    if [ -n "$HEALTH_SCORE" ]; then
        CONTEXT="${CONTEXT}
Health: ${HEALTH_SCORE}/100"
    fi
fi

# Surface stale breadcrumbs (>24h old) so they aren't silently forgotten
WEAVE_DIR="${WV_PROJECT_DIR}/.weave"
BC_FILE="${WEAVE_DIR}/breadcrumbs.md"
if [ -f "$BC_FILE" ]; then
    now=$(date +%s)
    mtime=$(stat -c %Y "$BC_FILE" 2>/dev/null || stat -f %m "$BC_FILE" 2>/dev/null || echo "$now")
    age_hours=$(( (now - mtime) / 3600 ))
    if [ "$age_hours" -gt 24 ]; then
        CONTEXT="${CONTEXT}
Breadcrumbs from ${age_hours}h ago — run 'wv breadcrumbs show' to review"
    fi
fi

# Output as JSON — use jq for safe string encoding (handles newlines in CONTEXT)
jq -n --arg ctx "$CONTEXT" '{
    hookSpecificOutput: {
        hookEventName: "SessionStart",
        additionalContext: $ctx
    }
}'

exit 0
