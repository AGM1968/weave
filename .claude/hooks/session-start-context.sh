#!/bin/bash
# SessionStart hook: Inject active work context
# Provides compressed Weave status at session start

set -e

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/../../scripts/lib/wv-resolve-project.sh" || exit 0

# Check if wv is available
if [ ! -x "$WV" ]; then
    echo "wv CLI not found"
    exit 0
fi

# Ensure DB is loaded
"$WV" load >/dev/null 2>&1 || true

# Get compressed work status using wv status (already formatted)
STATUS=$("$WV" status 2>/dev/null || echo "Work: 0 active, 0 ready, 0 blocked.")
CONTEXT="$STATUS"

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
