#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

"$ROOT/scripts/gen-procedures.sh" --check >/dev/null
printf '%s\n' '---' 'id: session' 'description: Session' 'fallback: "wv guide --procedure=session"' 'adapters: [claude]' 'claude_skill: wv-session' '---' '# Body' > "$TMP/session.md"
"$ROOT/scripts/gen-procedures.sh" --source="$TMP" --check >/dev/null
printf '%s\n' '#!/usr/bin/env bash' > "$TMP/check.sh"
chmod +x "$TMP/check.sh"
printf '%s\n' '---' 'id: session' 'description: Session' 'fallback: "wv guide --procedure=session"' 'adapters: [claude, codex, copilot]' 'visibility: shared' 'claude_skill: wv-session' 'resources:' '  - path: check.sh' '    executable: true' '---' '# Body' > "$TMP/session.md"
REPO="$TMP/repo"
mkdir -p "$REPO"
bash "$ROOT/scripts/project-procedures.sh" --source="$TMP" --repo="$REPO"
[ -f "$REPO/.claude/skills/wv-session/SKILL.md" ]
[ -x "$REPO/.claude/skills/wv-session/check.sh" ]
[ "$(jq -r '.procedures[0].fallback' "$REPO/.codex/weave.json")" = 'wv guide --procedure=session' ]
grep -qF 'wv guide --procedure=session' "$REPO/.github/copilot-instructions.md"
printf '%s\n' '---' 'id: repair' 'description: Repair' 'fallback: "wv guide --procedure=repair"' 'adapters: [copilot]' 'visibility: shared' '---' '# Body' > "$TMP/repair.md"
bash "$ROOT/scripts/project-procedures.sh" --source="$TMP" --repo="$REPO"
grep -qF 'wv guide --procedure=session' "$REPO/.github/copilot-instructions.md"
grep -qF 'wv guide --procedure=repair' "$REPO/.github/copilot-instructions.md"
FILTERED="$TMP/filtered"
mkdir -p "$FILTERED"
bash "$ROOT/scripts/project-procedures.sh" --source="$TMP" --repo="$FILTERED" --agent=codex
[ -f "$FILTERED/.codex/weave.json" ]
[ ! -e "$FILTERED/.claude" ]
[ ! -e "$FILTERED/.github" ]

# Block-style (prettier-wrapped) description must project non-empty into every adapter.
WRAP="$TMP/wrap"
WREPO="$TMP/wreprepo"
mkdir -p "$WRAP" "$WREPO"
printf '%s\n' '---' 'id: wrapped' 'description:' '  "Wrapped desc first line' '  second line here"' \
    'fallback: "wv guide --procedure=wrapped"' 'adapters: [claude, codex, copilot]' 'visibility: shared' 'claude_skill: wv-wrapped' '---' '# Body' > "$WRAP/wrapped.md"
bash "$ROOT/scripts/project-procedures.sh" --source="$WRAP" --repo="$WREPO"
grep -qF 'Wrapped desc first line second line here' "$WREPO/.claude/skills/wv-wrapped/SKILL.md"
[ "$(jq -r '.procedures[0].description' "$WREPO/.codex/weave.json")" = 'Wrapped desc first line second line here' ]
grep -qF 'Wrapped desc first line second line here' "$WREPO/.github/copilot-instructions.md"
printf '%s\n' 'Results: 14/14 passed'
