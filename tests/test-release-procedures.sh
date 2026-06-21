#!/usr/bin/env bash
# End-to-end release artifact test: a local procedure body AND its declared
# resource files must be absent from the built public release; shared
# procedures must survive. Exercises build-release.sh's strip step for real.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROC_DIR="$ROOT/templates/procedures"
OUT=$(mktemp -d)

# Temporary fixtures injected into the real source tree (clearly prefixed),
# removed on exit even if the build or an assertion fails.
LOCAL_MD="$PROC_DIR/zzz-release-ittest-local.md"
LOCAL_ASSET="$PROC_DIR/zzz-release-ittest-asset.sh"
INVALID_MD="$PROC_DIR/zzz-release-ittest-invalid.md"
cleanup() { rm -f "$LOCAL_MD" "$LOCAL_ASSET" "$INVALID_MD"; rm -rf "$OUT"; }
trap cleanup EXIT

printf '%s\n' '#!/usr/bin/env bash' 'echo dev-only asset' > "$LOCAL_ASSET"
chmod +x "$LOCAL_ASSET"
printf '%s\n' '---' 'id: zzz-release-ittest-local' 'description: Dev-only release test procedure' \
    'fallback: "wv guide --procedure=zzz-release-ittest-local"' 'adapters: [claude, codex, copilot]' \
    'visibility: local' 'claude_skill: zzz-release-ittest' 'resources:' '  - path: zzz-release-ittest-asset.sh' \
    '    executable: true' '---' '# dev-only body' > "$LOCAL_MD"

NO_COLOR=1 "$ROOT/build-release.sh" --output="$OUT" > "$OUT/.build.log" 2>&1 || {
    echo "build-release failed:" >&2; tail -20 "$OUT/.build.log" >&2; exit 1; }

ARTIFACT="$OUT/templates/procedures"
# Local procedure body stripped from the release
[ ! -e "$ARTIFACT/zzz-release-ittest-local.md" ]
# Its declared resource stripped too (the gap this test guards)
[ ! -e "$ARTIFACT/zzz-release-ittest-asset.sh" ]
# Ready + shared procedures survive
[ -f "$ARTIFACT/quality-gate.md" ]
[ -f "$ARTIFACT/code-search.md" ]
# Draft shells (shared but status: draft) are stripped — only a placeholder
# body would otherwise ship to the public release.
[ ! -e "$ARTIFACT/session.md" ]
[ ! -e "$ARTIFACT/agent-memory.md" ]

# A release cannot bypass the contract validator: a shared procedure with an
# invalid status must fail rather than ship because it is merely "not draft".
printf '%s\n' '---' 'id: zzz-release-ittest-invalid' 'description: Invalid release fixture' \
    'fallback: "wv guide --procedure=zzz-release-ittest-invalid"' 'adapters: [codex]' \
    'visibility: shared' 'status: broken' '---' '# invalid body' > "$INVALID_MD"
if NO_COLOR=1 "$ROOT/build-release.sh" --output="$OUT/invalid" >/dev/null 2>&1; then
    echo "invalid procedure contract unexpectedly produced a release" >&2
    exit 1
fi
rm -f "$INVALID_MD"

echo 'Results: 7/7 passed'
