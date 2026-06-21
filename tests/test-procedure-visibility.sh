#!/usr/bin/env bash
# Procedure visibility contract: only shared procedures project into consumer
# adapter surfaces; default is local; a sparse [local] override can only narrow.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
SRC="$TMP/src"
mkdir -p "$SRC"

mkproc() { # name adapters visibility_line
    local name="$1" adapters="$2" vis="$3"
    {
        printf '%s\n' '---' "id: $name" "description: $name proc" \
            "fallback: \"wv guide --procedure=$name\"" "adapters: $adapters"
        [ -n "$vis" ] && printf '%s\n' "$vis"
        printf '%s\n' '---' "# $name body"
    } > "$SRC/$name.md"
}

# 1. Default (no visibility field) is local -> never projected.
mkproc deflocal '[claude, codex, copilot]' ''
# Default-local still needs a claude_skill to satisfy the contract validator.
sed -i '/^adapters:/a claude_skill: wv-deflocal' "$SRC/deflocal.md"
# 2. Explicit shared -> projects everywhere.
mkproc shared1 '[codex, copilot]' 'visibility: shared'
# 3. Explicit local -> skipped even with adapters declared.
mkproc local1 '[codex, copilot]' 'visibility: local'

R1="$TMP/r1"; mkdir -p "$R1"
bash "$ROOT/scripts/project-procedures.sh" --source="$SRC" --repo="$R1"

# shared1 projected to codex + copilot
[ "$(jq -r '[.procedures[].id] | index("shared1")' "$R1/.codex/weave.json")" != "null" ]
grep -qF 'wv guide --procedure=shared1' "$R1/.github/copilot-instructions.md"
# deflocal (default local) and local1 NOT projected anywhere
[ ! -e "$R1/.claude/skills/wv-deflocal" ]
[ "$(jq -r '[.procedures[].id] | index("deflocal")' "$R1/.codex/weave.json")" = "null" ]
[ "$(jq -r '[.procedures[].id] | index("local1")' "$R1/.codex/weave.json")" = "null" ]
grep -qF 'deflocal' "$R1/.github/copilot-instructions.md" && { echo "deflocal leaked to copilot" >&2; exit 1; } || true
grep -qF 'local1' "$R1/.github/copilot-instructions.md" && { echo "local1 leaked to copilot" >&2; exit 1; } || true

# 4. Demotion after a prior projection removes stale consumer entries.
mkdir -p "$R1/.weave"
printf '%s\n' '[local]' 'shared1' > "$R1/.weave/procedures-visibility.conf"
bash "$ROOT/scripts/project-procedures.sh" --source="$SRC" --repo="$R1"
[ "$(jq -r '[.procedures[].id] | index("shared1")' "$R1/.codex/weave.json")" = "null" ]
! grep -qF 'wv guide --procedure=shared1' "$R1/.github/copilot-instructions.md"

# 5. Narrowing override: demote a shared procedure to local for THIS repo.
R2="$TMP/r2"; mkdir -p "$R2/.weave"
printf '%s\n' '[local]' 'shared1   # not for this repo''s consumers' > "$R2/.weave/procedures-visibility.conf"
bash "$ROOT/scripts/project-procedures.sh" --source="$SRC" --repo="$R2"
[ ! -e "$R2/.codex/weave.json" ] || [ "$(jq -r '[.procedures[].id] | index("shared1")' "$R2/.codex/weave.json")" = "null" ]
[ ! -e "$R2/.github/copilot-instructions.md" ] || ! grep -qF 'wv guide --procedure=shared1' "$R2/.github/copilot-instructions.md"

# 6. gen-procedures rejects an invalid visibility value.
mkproc bad '[codex]' 'visibility: public'
if bash "$ROOT/scripts/gen-procedures.sh" --source="$SRC" --check >/dev/null 2>&1; then
    echo "invalid visibility value unexpectedly passed validation" >&2
    exit 1
fi

echo 'Results: 10/10 passed'
