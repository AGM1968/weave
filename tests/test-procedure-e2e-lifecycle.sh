#!/usr/bin/env bash
# End-to-end procedure delivery lifecycle across the real user-facing seam:
#
#   install.sh  ->  installed wv-init-repo --agent=all  ->  source reinstall  ->  wv-init-repo --update
#
# The narrow projector test (test-procedure-lifecycle.sh) drives
# project-procedures.sh directly. That proves the projector, not the contract a
# real user touches: install.sh populates $CONFIG_DIR/procedures, the *installed*
# wv-init-repo binary projects from there, and wv guide --procedure resolves from
# the installed config — never from a source checkout. This battery exercises all
# three of those binaries together and asserts the two-phase upgrade boundary
# (install changes only CONFIG_DIR; consumer projections change only on --update)
# across every adapter (claude skill, codex contract, copilot instructions).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'cd /tmp; rm -rf "$TMP"' EXIT

SOURCE="$TMP/source"
CONFIG="$TMP/config"
BIN="$TMP/bin"
LIB="$TMP/lib"
REPO="$TMP/repo"

PASS=0
RUN=0
ok()   { RUN=$((RUN + 1)); PASS=$((PASS + 1)); echo "  ok: $1"; }
fail() { RUN=$((RUN + 1)); echo "  FAIL: $1" >&2; }
check(){ if eval "$2"; then ok "$1"; else fail "$1 [$2]"; fi; }

# Disposable full source tree so install.sh runs its normal local-source path
# without touching this checkout or the user's real install.
mkdir -p "$SOURCE" "$REPO"
cp -a "$ROOT/." "$SOURCE/"

# Fixture procedure declaring all three adapters. The version marker is embedded
# in BOTH the body (observable in the claude skill) AND the description (observable
# in the codex managed entry and copilot instruction line), so a refresh is
# verifiable on every adapter — not just claude.
FIX="$SOURCE/templates/procedures/zzz-s5-lifecycle.md"
write_fixture() { # version-marker
    printf '%s\n' '---' 'id: zzz-s5-lifecycle' "description: s5 e2e lifecycle fixture $1" \
        'fallback: "wv guide --procedure=zzz-s5-lifecycle"' 'adapters: [claude, codex, copilot]' \
        'visibility: shared' 'status: ready' 'claude_skill: zzz-s5-skill' \
        '---' "# $1" > "$FIX"
}
# Adapter projection probes for a given version marker.
codex_desc()   { jq -r '.procedures[]? | select(.id=="zzz-s5-lifecycle") | .description' "$REPO/.codex/weave.json"; }
copilot_line() { grep -F 'zzz-s5-lifecycle' "$REPO/.github/copilot-instructions.md" || true; }

install_local() {
    HOME="$TMP/home" WV_INSTALL_DIR="$BIN" WV_LIB_DIR="$LIB" WV_CONFIG_DIR="$CONFIG" \
        SKIP_AST_GREP=1 bash "$SOURCE/install.sh" --no-mcp --local-source="$SOURCE" >/dev/null
}

# Installed binaries, run with the installed config (never the source checkout).
init_repo() { HOME="$TMP/home" WV_CONFIG_DIR="$CONFIG" WV_LIB_DIR="$LIB" "$BIN/wv-init-repo" "$@"; }
guide()     { HOME="$TMP/home" WV_CONFIG_DIR="$CONFIG" WV_LIB_DIR="$LIB" "$BIN/wv" guide --procedure="$1"; }

# ── Phase 1: install populates the installed canonical config ──────────────────
echo "[phase 1] install.sh populates \$CONFIG_DIR/procedures"
write_fixture LIFECYCLE-V1
install_local
check "install copies fixture canonical body to CONFIG_DIR" "[ -f '$CONFIG/procedures/zzz-s5-lifecycle.md' ]"
check "install copies real session procedure to CONFIG_DIR" "[ -f '$CONFIG/procedures/session.md' ]"
check "install copies the projector to CONFIG_DIR"          "[ -x '$CONFIG/project-procedures.sh' ]"
check "installed wv-init-repo binary exists"                "[ -x '$BIN/wv-init-repo' ]"

# ── Phase 2: installed wv-init-repo --agent=all projects every adapter ─────────
echo "[phase 2] installed wv-init-repo --agent=all projects all three adapters"
( cd "$REPO" && git init -q && git config commit.gpgsign false )
( cd "$REPO" && init_repo --agent=all >/dev/null )
check "claude: fixture skill projected with v1 body" \
    "grep -qF 'LIFECYCLE-V1' '$REPO/.claude/skills/zzz-s5-skill/SKILL.md'"
check "claude: real session skill projected" \
    "[ -f '$REPO/.claude/skills/wv-session/SKILL.md' ]"
check "codex: fixture id present as managed entry with v1 description" \
    "[ \"\$(jq -r '[.procedures[]? | select(.id==\"zzz-s5-lifecycle\" and .managed==true)] | length' '$REPO/.codex/weave.json')\" = 1 ] && codex_desc | grep -qF 'LIFECYCLE-V1'"
check "copilot: fixture line present with v1 description" \
    "copilot_line | grep -qF 'LIFECYCLE-V1'"

# ── Phase 3: wv guide resolves from installed config, not the source checkout ──
echo "[phase 3] wv guide --procedure resolves from installed config"
check "wv guide returns installed v1 body" "guide zzz-s5-lifecycle | grep -qF 'LIFECYCLE-V1'"

# Edit the SOURCE body but do NOT reinstall: a guide pinned to source would now
# report v2. Resolution from the installed config keeps it at v1.
write_fixture LIFECYCLE-V2
check "wv guide still v1 before reinstall (reads installed config, not source)" \
    "guide zzz-s5-lifecycle | grep -qF 'LIFECYCLE-V1'"
check "wv guide does NOT leak the un-installed source v2" \
    "! guide zzz-s5-lifecycle | grep -qF 'LIFECYCLE-V2'"

# ── Phase 4: reinstall reaches only CONFIG_DIR; consumer projection unchanged ──
echo "[phase 4] reinstall updates CONFIG_DIR only; consumer projection unchanged until --update"
install_local
check "reinstall updates installed canonical body to v2" \
    "grep -qF 'LIFECYCLE-V2' '$CONFIG/procedures/zzz-s5-lifecycle.md'"
check "wv guide now returns v2 from installed config" \
    "guide zzz-s5-lifecycle | grep -qF 'LIFECYCLE-V2'"
check "consumer claude skill STILL v1 (no --update yet)" \
    "grep -qF 'LIFECYCLE-V1' '$REPO/.claude/skills/zzz-s5-skill/SKILL.md'"
check "consumer claude skill not yet showing v2" \
    "! grep -qF 'LIFECYCLE-V2' '$REPO/.claude/skills/zzz-s5-skill/SKILL.md'"
check "consumer codex description STILL v1 (no --update yet)" \
    "codex_desc | grep -qF 'LIFECYCLE-V1'"
check "consumer copilot line STILL v1 (no --update yet)" \
    "copilot_line | grep -qF 'LIFECYCLE-V1'"

# ── Phase 5: wv-init-repo --update refreshes the consumer projection ───────────
echo "[phase 5] wv-init-repo --agent=all --update refreshes consumer projection"
( cd "$REPO" && init_repo --agent=all --update >/dev/null )
check "consumer claude skill now v2 after --update" \
    "grep -qF 'LIFECYCLE-V2' '$REPO/.claude/skills/zzz-s5-skill/SKILL.md'"
check "consumer claude skill v1 body gone after --update" \
    "! grep -qF 'LIFECYCLE-V1' '$REPO/.claude/skills/zzz-s5-skill/SKILL.md'"
check "consumer codex description now v2 after --update" \
    "codex_desc | grep -qF 'LIFECYCLE-V2'"
check "consumer copilot line now v2 after --update" \
    "copilot_line | grep -qF 'LIFECYCLE-V2'"

# ── Phase 6: delete from source -> reinstall -> --update prunes every adapter ──
echo "[phase 6] deleting the canonical source prunes all three installed-adapter projections"
rm -f "$FIX"
install_local
check "reinstall removes fixture from installed config (deletion reconcile)" \
    "[ ! -e '$CONFIG/procedures/zzz-s5-lifecycle.md' ]"
check "wv guide now reports the procedure uninstalled" \
    "! guide zzz-s5-lifecycle >/dev/null 2>&1"
# Projections persist until the consumer runs --update (two-phase contract).
check "consumer claude skill persists until --update" \
    "[ -f '$REPO/.claude/skills/zzz-s5-skill/SKILL.md' ]"
( cd "$REPO" && init_repo --agent=all --update >/dev/null )
check "claude: stale managed skill pruned after --update" \
    "[ ! -e '$REPO/.claude/skills/zzz-s5-skill' ]"
check "codex: stale managed entry pruned after --update" \
    "[ \"\$(jq -r '[.procedures[]? | select(.id==\"zzz-s5-lifecycle\")] | length' '$REPO/.codex/weave.json')\" = 0 ]"
check "copilot: stale instruction line pruned after --update" \
    "[ -z \"\$(copilot_line)\" ]"

echo ""
echo "Results: $PASS/$RUN passed"
[ "$PASS" = "$RUN" ]
