#!/usr/bin/env bash
# Procedure visibility contract: only shared procedures project into consumer
# adapter surfaces; default is local; a sparse [local] override can only narrow.
# shellcheck source=tests/lib/sed-inplace.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/sed-inplace.sh"  # sed -i is GNU-only (wv-076a98)
set -euo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)

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
sed_inplace '/^adapters:/a\
claude_skill: wv-deflocal' "$SRC/deflocal.md"
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

# 6. A local-visibility procedure remains available to wv guide but never
# projects to a consumer adapter. Built synthetically rather than read from
# templates/procedures/local-development.md: that file is stripped from the
# public projection, and this suite is retained there, so pointing at it made a
# shipped test depend on a file the release deliberately removes. The property
# under test is the visibility rule, not that one particular document.
LOCAL_SRC="$TMP/local-src"; R3="$TMP/r3"; mkdir -p "$LOCAL_SRC" "$R3"
cat > "$LOCAL_SRC/local-only.md" <<'LOCALPROC'
---
id: local-only
description: "A development procedure that must never reach a consumer adapter."
fallback: "wv guide --procedure=local-only"
adapters: [codex]
visibility: local
status: ready
---

# Local Only

Run `wv <command>` locally.
LOCALPROC
bash "$ROOT/scripts/gen-procedures.sh" --source="$LOCAL_SRC" --check >/dev/null
bash "$ROOT/scripts/project-procedures.sh" --source="$LOCAL_SRC" --repo="$R3" --agent=codex
[ ! -e "$R3/.codex/weave.json" ] || [ "$(jq -r '[.procedures[].id] | index("local-only")' "$R3/.codex/weave.json")" = "null" ]

# 7. gen-procedures rejects an invalid visibility value.
mkproc bad '[codex]' 'visibility: public'
if bash "$ROOT/scripts/gen-procedures.sh" --source="$SRC" --check >/dev/null 2>&1; then
    echo "invalid visibility value unexpectedly passed validation" >&2
    exit 1
fi

echo 'Results: 15/15 passed'
