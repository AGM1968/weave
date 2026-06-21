#!/usr/bin/env bash
# Installed canonical bodies update consumer projections only when projected.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
CONFIG="$TMP/config"
REPO="$TMP/repo"
mkdir -p "$CONFIG/procedures" "$REPO"
cp "$ROOT/scripts/project-procedures.sh" "$CONFIG/project-procedures.sh"
cp "$ROOT/scripts/gen-procedures.sh" "$CONFIG/gen-procedures.sh"
chmod +x "$CONFIG/project-procedures.sh" "$CONFIG/gen-procedures.sh"

write_procedure() {
    local body="$1"
    printf '%s\n' '---' 'id: session' 'description: Session' 'fallback: "wv guide --procedure=session"' \
        'adapters: [claude]' 'visibility: shared' 'claude_skill: wv-session' '---' "$body" > "$CONFIG/procedures/session.md"
}

write_procedure '# Version one'
WV_CONFIG_DIR="$CONFIG" "$CONFIG/project-procedures.sh" --repo="$REPO" --agent=claude
grep -qF '# Version one' "$REPO/.claude/skills/wv-session/SKILL.md"

# Install/update changes the canonical body only; the existing projection remains untouched.
write_procedure '# Version two'
grep -qF '# Version one' "$REPO/.claude/skills/wv-session/SKILL.md"

# init-repo --update's projector phase refreshes the consumer surface.
WV_CONFIG_DIR="$CONFIG" "$CONFIG/project-procedures.sh" --repo="$REPO" --agent=claude
grep -qF '# Version two' "$REPO/.claude/skills/wv-session/SKILL.md"

echo 'Results: 3/3 passed'
