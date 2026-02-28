#!/bin/bash
# SessionEnd hook: Final sync before exit
# Syncs Weave state to git layer

set -e

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/../../scripts/lib/wv-resolve-project.sh" || exit 0

# Read input for reason
INPUT=$(cat)
REASON=$(echo "$INPUT" | jq -r '.reason // "unknown"')

cd "$WV_PROJECT_DIR" 2>/dev/null || exit 0

# Try to sync Weave (best effort)
if [ -x "$WV" ]; then
    "$WV" sync 2>/dev/null || true
fi

# Try to prune old nodes (best effort)
if [ -x "$WV" ]; then
    "$WV" prune --age=48h 2>/dev/null || true
fi

# Auto-commit .weave/ state to break drift cycle
# (prevents stop-check blocking on dirty .weave/ from sync/prune above)
git add .weave/ 2>/dev/null || true
if ! git diff --cached --quiet 2>/dev/null; then
    git commit -m "chore(weave): auto-checkpoint $(date +%H:%M) [skip ci]" --no-verify 2>/dev/null || true
fi

# Push to remote (best effort — stop-check already validates clean state)
git push 2>/dev/null || true

# Log session end
echo "[$(date -Iseconds)] Session ended: $REASON" >> .claude/session.log 2>/dev/null || true

exit 0
