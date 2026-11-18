#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# A retired skill leaves the consumer too, but only Weave's own copy (wv-853052).
#
# Retiring a skill (ship-it by wv-e0cbe3, resolve-refs by wv-631bb6) stopped its
# delivery, but wv init-repo --update never removed the copy already in a
# consumer's .claude/skills, so every consumer kept a stale second source of
# rules that now live in a procedure. The removal is content-addressed: a copy
# goes only when its bytes match a version Weave shipped under that name.
#
# What this pins:
#   A. the lib: an unedited shipped copy is removed; an edited copy, shipped
#      bytes under another name, and any copy without a provenance list are
#      kept and reported (fail closed); files beside SKILL.md are never deleted;
#      a skill that is not retired is never touched
#   B. one list: the retired names live in wv-skill-retirement.sh only, and
#      install.sh, wv-init-repo and the projector all read it
#   C. end to end: wv init-repo --agent=claude --update removes the unedited
#      copy and keeps the edited one, saying which and why
set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$ROOT/scripts/lib/wv-skill-retirement.sh"

run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }
has() { if grep -qF -- "$2" <<<"$3"; then ok "$1"; else bad "$1" "missing [$2] in: ${3:0:400}"; fi; }

# The nested commit gate injects core.hooksPath=/dev/null through GIT_CONFIG_*;
# git bisect exports GIT_DIR. Neither may reach a scratch repository.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0

T=$(bash "$ROOT/scripts/lib/wv-scratch.sh") || exit 1
trap 'rm -rf "$T"' EXIT

# Real shipped bytes: the last committed version of each retired skill.
shipped_bytes() {
    local name="$1" rev
    rev=$(git -C "$ROOT" log -1 --format=%H --diff-filter=D -- ".claude/skills/$name/SKILL.md")
    [ -n "$rev" ] && git -C "$ROOT" show "$rev^:.claude/skills/$name/SKILL.md"
}
# A shipped copy has no history: the release projection is one commit. It
# judges removal on stand-in bytes; the source repo uses the real ones and
# fails without them (wv-c804fa).
printf -- '---\nname: ship-it\n---\nstand-in shipped bytes\n' > "$T/ship-it.md"
printf -- '---\nname: resolve-refs\n---\nstand-in shipped bytes\n' > "$T/resolve-refs.md"
standin=1
PROV="$T/provenance.txt"
printf '%s ship-it\n%s resolve-refs\n' \
    "$(sha256sum "$T/ship-it.md" | cut -d' ' -f1)" "$(sha256sum "$T/resolve-refs.md" | cut -d' ' -f1)" > "$PROV"
place() { mkdir -p "$1/$2"; cp "$3" "$1/$2/SKILL.md"; }
present() { [ -e "$1" ] && echo present || echo absent; }

echo "=== A. the lib ==="
# shellcheck source=scripts/lib/wv-skill-retirement.sh
source "$LIB"
S="$T/a/skills"
place "$S" ship-it "$T/ship-it.md"                       # unedited Weave copy
place "$S" resolve-refs "$T/resolve-refs.md"; echo "my note" >> "$S/resolve-refs/SKILL.md"   # edited
place "$S" breadcrumbs "$T/ship-it.md"                   # shipped bytes, wrong name
place "$S" weave "$T/ship-it.md"                         # not a retired name
out=$(wv_retire_skill_copies "$S" "$PROV")
check "an unedited shipped copy is removed, directory and all" "absent" "$(present "$S/ship-it")"
has   "its removal is reported" "ship-it: retired skill removed" "$out"
check "an edited copy is kept" "present" "$(present "$S/resolve-refs/SKILL.md")"
has   "an edited copy is reported" "resolve-refs: retired skill kept - its SKILL.md differs" "$out"
check "bytes shipped under another name do not count" "present" "$(present "$S/breadcrumbs/SKILL.md")"
check "a skill that is not retired is never touched" "present" "$(present "$S/weave/SKILL.md")"

S="$T/a2/skills"
place "$S" ship-it "$T/ship-it.md"; echo extra > "$S/ship-it/helper.sh"
out=$(wv_retire_skill_copies "$S" "$PROV")
check "a shipped SKILL.md beside other files is removed" "absent" "$(present "$S/ship-it/SKILL.md")"
check "the other files are kept" "present" "$(present "$S/ship-it/helper.sh")"
has   "and that is reported" "other files left in" "$out"

S="$T/a3/skills"
place "$S" ship-it "$T/ship-it.md"
out=$(wv_retire_skill_copies "$S" "$T/no-such-provenance.txt")
check "no provenance list: an unedited copy is still kept (fail closed)" "present" "$(present "$S/ship-it/SKILL.md")"
has   "no provenance list is reported" "no skill provenance list" "$out"

echo "=== B. one list ==="
check "install.sh carries no literal retired-skill list" "0" \
    "$(grep -cE '(breadcrumbs|epic-breakdown) .*(prove-it|unstuck)' "$ROOT/install.sh")"
check "install.sh seeds its CONFIG_DIR prune from the list" "1" \
    "$(grep -cF "_wv_sk_prev=\"\${WV_RETIRED_SKILLS[*]}\"" "$ROOT/install.sh")"
check "wv-init-repo sources the list" "1" \
    "$(grep -cxF "source \"\$SKILL_RETIREMENT_LIB\"" "$ROOT/install.sh")"
check "the projector shares the byte-identity test" "1" \
    "$(grep -cF "wv_skill_shipped_copy \"\$1\" \"\$2\" \"\$SKILL_PROVENANCE\"" "$ROOT/scripts/project-procedures.sh")"
deleted=$(git -C "$ROOT" log --diff-filter=D --name-only --format= -- '.claude/skills/*/SKILL.md' \
    | sed 's|.claude/skills/||; s|/SKILL.md||' | sort -u | tr '\n' ' ')
listed=" $(printf '%s\n' "${WV_RETIRED_SKILLS[@]}" | sort -u | tr '\n' ' ')"
# A subset, not equality: a skill is listed in the same commit that deletes
# it, so at pre-commit time it is listed before history shows the deletion
# (wv-262d14). The second check keeps the list from naming a live skill.
unlisted=""
for name in $deleted; do
    [ -f "$ROOT/.claude/skills/$name/SKILL.md" ] && continue  # deleted, later restored
    case "$listed" in *" $name "*) ;; *) unlisted="$unlisted $name" ;; esac
done
check "every skill deleted from history is on the list" "" "$unlisted"
live=""
for name in "${WV_RETIRED_SKILLS[@]}"; do
    if [ -f "$ROOT/.claude/skills/$name/SKILL.md" ]; then live="$live $name"; fi
done
check "no listed skill still has a SKILL.md in the tree" "" "$live"

echo "=== C. wv init-repo --update ==="
I="$T/install"
mkdir -p "$I/home" "$I/bin" "$I/lib" "$I/config"
if ! (cd "$ROOT" && HOME="$I/home" CLAUDE_CONFIG_DIR="$I/home/.claude" WV_INSTALL_DIR="$I/bin" \
        WV_LIB_DIR="$I/lib" WV_CONFIG_DIR="$I/config" bash "$ROOT/install.sh") > "$T/install.log" 2>&1; then
    bad "isolated install succeeds" "$(tail -5 "$T/install.log")"
    echo "Results: $pass/$run passed"; exit 1
fi
ok "isolated install succeeds"
# Stand-in bytes are no version this install's history holds; record them as
# shipped, as a release's history would. The source repo never takes this branch.
if [ "$standin" = 1 ]; then cat "$PROV" >> "$I/config/skill-provenance.txt"; fi
export WV_INSTALL_DIR="$I/bin" WV_LIB_DIR="$I/lib" WV_CONFIG_DIR="$I/config" PATH="$I/bin:$PATH"
export WV_HOT_ZONE="$T/hot" WV_DB="$T/hot/brain.db"
R="$T/consumer"
mkdir -p "$R" && git -C "$R" init -q && git -C "$R" config commit.gpgsign false
place "$R/.claude/skills" ship-it "$T/ship-it.md"
place "$R/.claude/skills" resolve-refs "$T/resolve-refs.md"; echo "local rule" >> "$R/.claude/skills/resolve-refs/SKILL.md"
out=$(cd "$R" && "$ROOT/scripts/wv" init-repo --agent=claude --update 2>&1); rc="$?"
check "init-repo --update succeeds" "0" "$rc"
check "the unedited retired copy is removed" "absent" "$(present "$R/.claude/skills/ship-it")"
check "the edited retired copy is kept" "present" "$(present "$R/.claude/skills/resolve-refs/SKILL.md")"
has   "init-repo names the removal" "ship-it: retired skill removed" "$out"
has   "init-repo names what it kept and why" "resolve-refs: retired skill kept" "$out"

echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
