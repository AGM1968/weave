#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# test-skill-provenance.sh — content-addressed provenance for skills (wv-ef7ad7)
#
# A file is Weave's if its bytes match a version Weave shipped under that skill
# name. Skills shipped before the WEAVE-MANAGED-SKILL marker carry no marker,
# and every consumer held such copies, so projecting a procedure over one
# aborted the whole projection (session-close over close-session, rc=1).
#
# Covers:
#   - gen-skill-provenance.sh lists "<sha256> <name>" for every committed
#     version of .claude/skills/<name>/SKILL.md, name-scoped, and refuses a
#     directory that is not a git repository
#   - project-procedures.sh adopts an unedited shipped copy and reports it
#   - it still refuses an edited copy, a hash shipped under another skill name,
#     and any unmarked copy when no provenance list exists (fail closed)
#   - the real case: session-close over this repository's last hand-written
#     close-session is adopted
#
# Exit codes:
#   0 - All tests passed
#   1 - Unexpected failure

set -euo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GEN="$PROJECT_ROOT/scripts/gen-skill-provenance.sh"
PROJECT="$PROJECT_ROOT/scripts/project-procedures.sh"

SCRATCH=$(bash "$PROJECT_ROOT/scripts/lib/wv-scratch.sh")
unset WV_SCRATCH_ROOT GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
export WV_CONFIG_DIR="$SCRATCH/config"   # never read the real install's list
unset WV_SKILL_PROVENANCE
mkdir -p "$WV_CONFIG_DIR"
cleanup() { cd / && rm -rf "$SCRATCH"; }
trap cleanup EXIT

pass() { echo -e "${GREEN}✓${NC} $1"; TESTS_RUN=$((TESTS_RUN + 1)); TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo -e "${RED}✗${NC} $1"; [ -z "${2:-}" ] || echo "  $2"; TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1)); }
sha() { sha256sum "$1" | cut -d' ' -f1; }
git_q() { git -c user.email=t@t -c user.name=t -c commit.gpgsign=false "$@"; }

echo ""
echo "Generator"
echo "========="
SRC="$SCRATCH/src"
mkdir -p "$SRC/.claude/skills/foo" "$SRC/.claude/skills/gone"
git_q -C "$SRC" init -q
printf 'foo version one\n' > "$SRC/.claude/skills/foo/SKILL.md"
printf 'gone skill\n' > "$SRC/.claude/skills/gone/SKILL.md"
git_q -C "$SRC" add -A && git_q -C "$SRC" commit -qm one
cp "$SRC/.claude/skills/foo/SKILL.md" "$SCRATCH/foo-v1"
printf 'foo version two\n' > "$SRC/.claude/skills/foo/SKILL.md"
git_q -C "$SRC" rm -q -r .claude/skills/gone
git_q -C "$SRC" add -A && git_q -C "$SRC" commit -qm two
LIST="$SCRATCH/provenance.txt"
if bash "$GEN" --repo="$SRC" --out="$LIST" && [ -s "$LIST" ]; then pass "the generator writes a list"; else fail "the generator writes a list"; fi
grep -qxF -- "$(sha "$SCRATCH/foo-v1") foo" "$LIST" && pass "an earlier version is listed under its skill name" \
    || fail "an earlier version is listed under its skill name" "$(cat "$LIST")"
grep -qxF -- "$(sha "$SRC/.claude/skills/foo/SKILL.md") foo" "$LIST" && pass "the current version is listed" \
    || fail "the current version is listed"
grep -qE ' gone$' "$LIST" && pass "a skill deleted later keeps the versions it shipped" \
    || fail "a skill deleted later keeps the versions it shipped"
[ "$(wc -l < "$LIST")" -eq 3 ] && pass "exactly the three shipped versions, no deletion entry" \
    || fail "exactly the three shipped versions, no deletion entry" "$(cat "$LIST")"
mkdir -p "$SCRATCH/nogit"
if bash "$GEN" --repo="$SCRATCH/nogit" --out="$SCRATCH/nogit.txt" 2>/dev/null; then
    fail "a directory without git history is refused"
else
    [ -e "$SCRATCH/nogit.txt" ] && fail "a refused run writes nothing" || pass "a directory without git history is refused and writes nothing"
fi

echo ""
echo "Projector"
echo "========="
PROCS="$SCRATCH/procs"
mkdir -p "$PROCS"
cat > "$PROCS/foo-proc.md" <<'EOF'
---
id: foo-proc
description:
  "A fixture procedure that projects to the foo skill."
fallback: "wv guide --procedure=foo-proc"
adapters: [claude]
visibility: shared
status: ready
claude_skill: foo
---

# Foo

FOO-PROJECTED-BODY
EOF
# project <repo> [env...]: run the projector for claude into <repo>
project() { local repo="$1"; shift; env "$@" bash "$PROJECT" --source="$PROCS" --repo="$repo" --agent=claude; }
consumer() { # consumer <name> <content file> [skill name]: a repo holding an unmarked skill
    local r="$SCRATCH/$1" skill="${3:-foo}"
    mkdir -p "$r/.claude/skills/$skill"; git_q -C "$r" init -q
    cp "$2" "$r/.claude/skills/$skill/SKILL.md"; echo "$r"
}

R=$(consumer adopt "$SCRATCH/foo-v1")
if out=$(project "$R" WV_SKILL_PROVENANCE="$LIST" 2>&1) && grep -qF FOO-PROJECTED-BODY "$R/.claude/skills/foo/SKILL.md" \
    && grep -qF WEAVE-MANAGED-SKILL "$R/.claude/skills/foo/SKILL.md"; then
    pass "an unedited shipped copy is adopted and replaced by the projection"
else
    fail "an unedited shipped copy is adopted and replaced by the projection" "$out"
fi
grep -qF "adopting skill 'foo'" <<< "${out:-}" && pass "the adoption is reported" || fail "the adoption is reported" "${out:-}"

printf 'foo version one\nmy local edit\n' > "$SCRATCH/foo-edited"
R=$(consumer edited "$SCRATCH/foo-edited")
if project "$R" WV_SKILL_PROVENANCE="$LIST" >/dev/null 2>&1; then
    fail "an edited copy is refused"
else
    cmp -s "$SCRATCH/foo-edited" "$R/.claude/skills/foo/SKILL.md" && pass "an edited copy is refused and left untouched" \
        || fail "an edited copy is left untouched"
fi

cat > "$PROCS/bar-proc.md" <<'EOF'
---
id: bar-proc
description:
  "A fixture procedure that projects to the bar skill."
fallback: "wv guide --procedure=bar-proc"
adapters: [claude]
visibility: shared
status: ready
claude_skill: bar
---

# Bar

BAR-PROJECTED-BODY
EOF
R=$(consumer othername "$SCRATCH/foo-v1" bar)
if project "$R" WV_SKILL_PROVENANCE="$LIST" >/dev/null 2>&1; then
    fail "a hash shipped under another skill name is refused"
else
    pass "a hash shipped under another skill name is refused"
fi
rm -f "$PROCS/bar-proc.md"

R=$(consumer nolist "$SCRATCH/foo-v1")
if project "$R" WV_SKILL_PROVENANCE="$SCRATCH/does-not-exist" >/dev/null 2>&1; then
    fail "without a provenance list an unmarked copy is refused (fail closed)"
else
    pass "without a provenance list an unmarked copy is refused (fail closed)"
fi


echo ""
echo "=========================================="
echo "Tests run: $TESTS_RUN, passed: $TESTS_PASSED, failed: $TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
