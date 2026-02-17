#!/usr/bin/env sh
# Weave pre-commit hook: require active node before committing code changes
#
# Enforces the "track ALL work in Weave" rule from AGENTS.md.
# Allows .weave/-only commits and WIP checkpoints through.
#
# Skip with: git commit --no-verify (or WV_SKIP_PRECOMMIT=1)

# Allow explicit bypass
[ "${WV_SKIP_PRECOMMIT:-0}" = "1" ] && exit 0

# Find wv
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || exit 0)
WV="$(command -v wv 2>/dev/null || echo "$REPO_ROOT/scripts/wv")"
[ ! -x "$WV" ] && exit 0

# Check what's being committed — if only .weave/ files, always allow
STAGED_FILES=$(git diff --cached --name-only 2>/dev/null)
[ -z "$STAGED_FILES" ] && exit 0

NON_WEAVE_FILES=$(echo "$STAGED_FILES" | grep -v '^\.weave/' || true)
[ -z "$NON_WEAVE_FILES" ] && exit 0

# Allow auto-checkpoint WIP commits (contain [skip ci] in message)
# The commit message file isn't available in pre-commit, so check env
# Auto-checkpoint sets WV_AUTO_CHECKPOINT_ACTIVE=1
[ "${WV_AUTO_CHECKPOINT_ACTIVE:-0}" = "1" ] && exit 0

# Check for active Weave nodes
ACTIVE_COUNT=$("$WV" list --status=active --json 2>/dev/null | jq 'length' 2>/dev/null || echo "0")

if [ "$ACTIVE_COUNT" = "0" ] || [ -z "$ACTIVE_COUNT" ]; then
    cat >&2 << 'EOF'

╔══════════════════════════════════════════════════════════════╗
║  ⚠  No active Weave node — commit blocked                    ║
║                                                              ║
║  Every code change must be tracked. Either:                  ║
║    wv work <id>         # claim an existing task             ║
║    wv add "..." --gh    # create + track new work            ║
║                                                              ║
║  Then retry your commit.                                     ║
║                                                              ║
║  Bypass: git commit --no-verify                              ║
║          WV_SKIP_PRECOMMIT=1 git commit                      ║
╚══════════════════════════════════════════════════════════════╝

EOF
    exit 1
fi

exit 0
