#!/usr/bin/env bash
# Repository-owned procedures (wv-fc71f0, memory graduation S1): a repository
# authors procedures in .weave/procedures under the package contract. They
# project into that repository only, replace a package procedure of the same id
# there, are read first by wv guide --procedure, and wv doctor reports a stale
# projection, since projection is explicit (owner and judge panel,
# docs/findings/judge-repo-procedures-2026-10-30/).
set -euo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
export WV_CALL_SOURCE=test

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WV="$ROOT/scripts/wv"
TMP=$(mktemp -d)
trap 'cd /tmp; rm -rf "$TMP"' EXIT
export WV_HOT_ZONE="$TMP/hotzone"
export WV_CONFIG_DIR="$TMP/config"
CONFIG="$WV_CONFIG_DIR"
A="$TMP/repo-a"
B="$TMP/repo-b"

TESTS=0
PASSED=0
check() { # message command...
    local message="$1"; shift
    TESTS=$((TESTS + 1))
    if "$@" >/dev/null 2>&1; then PASSED=$((PASSED + 1)); else echo "FAIL: $message" >&2; fi
}
contains() { grep -qF -- "$2" <<< "$1"; }
lacks() { ! grep -qF -- "$2" <<< "$1"; }

mkdir -p "$CONFIG/procedures" "$CONFIG/lib" "$A/.weave/procedures" "$B/.weave"
cp "$ROOT/scripts/project-procedures.sh" "$ROOT/scripts/gen-procedures.sh" "$CONFIG/"
cp "$ROOT/scripts/lib/wv-repository-class.sh" "$CONFIG/lib/"
cp "$ROOT/scripts/lib/wv-skill-retirement.sh" "$CONFIG/lib/"
chmod +x "$CONFIG/project-procedures.sh" "$CONFIG/gen-procedures.sh"

procedure() { # dir id skill body [visibility]
    printf '%s\n' '---' "id: $2" "description: $2 procedure" "fallback: \"wv guide --procedure=$2\"" \
        'adapters: [claude, codex, copilot]' "visibility: ${5:-shared}" "claude_skill: $3" '---' "$4" > "$1/$2.md"
}
project() { WV_CONFIG_DIR="$CONFIG" "$CONFIG/project-procedures.sh" --repo="$1" --agent=all; }
refused() { ! "$@"; }
guide() { (cd "$1" && "$WV" guide --procedure="$2") 2>&1; }
doctor_json() { (cd "$1" && "$WV" doctor --json 2>/dev/null) || true; }
doctor_check() { doctor_json "$1" | jq -c '[.checks[] | select(.check == "repo-procedures")][0] // null'; }

procedure "$CONFIG/procedures" verify wv-verify '# Package verify'
procedure "$CONFIG/procedures" session wv-session '# Package session'
procedure "$A/.weave/procedures" verify wv-verify '# Repo A verify: vitest and tsc'
procedure "$A/.weave/procedures" house-lesson wv-house-lesson '# Repo A house lesson'

# Projection: repository procedures reach the repository's own surfaces, and a
# repository procedure replaces the package one of the same id.
check "projector accepts repo procedures" project "$A"
check "a repo procedure projects to its Claude skill" grep -qF '# Repo A house lesson' "$A/.claude/skills/wv-house-lesson/SKILL.md"
check "a repo procedure replaces the package skill body" grep -qF '# Repo A verify' "$A/.claude/skills/wv-verify/SKILL.md"
check "the replaced package body is not projected" lacks "$(cat "$A/.claude/skills/wv-verify/SKILL.md")" '# Package verify'
check "package procedures still project beside repo ones" grep -qF '# Package session' "$A/.claude/skills/wv-session/SKILL.md"
check "repo procedure is a managed Codex entry" jq -e '[.procedures[] | select(.id == "house-lesson" and .managed)] | length == 1' "$A/.codex/weave.json"
check "a replaced id has one Codex entry" jq -e '[.procedures[] | select(.id == "verify")] | length == 1' "$A/.codex/weave.json"
check "repo procedure is indexed for Copilot" grep -qF 'house-lesson' "$A/.github/copilot-instructions.md"

# Another repository on the machine sees the package only.
check "projector runs in a second repo" project "$B"
check "second repo gets the package verify" grep -qF '# Package verify' "$B/.claude/skills/wv-verify/SKILL.md"
check "second repo does not get repo A's procedure" test ! -e "$B/.claude/skills/wv-house-lesson"

# wv guide reads the repository's procedure first, then the installed one.
out=$(guide "$A" verify || true)
check "wv guide prints the repo procedure" contains "$out" '# Repo A verify'
out=$(guide "$A" house-lesson || true)
check "wv guide finds a repo-only procedure" contains "$out" '# Repo A house lesson'
out=$(guide "$A" session || true)
check "wv guide falls back to the package for other ids" contains "$out" '# Package session'
out=$(guide "$B" verify || true)
check "another repo's wv guide prints the package procedure" contains "$out" '# Package verify'
out=$(guide "$B" house-lesson || true)
check "another repo cannot read repo A's procedure" contains "$out" "unknown procedure 'house-lesson'"

# Default visibility is local for every source (owner): a repo procedure with
# no visibility field is readable through wv guide but not projected.
printf '%s\n' '---' 'id: quiet' 'description: quiet' 'fallback: "wv guide --procedure=quiet"' \
    'adapters: [claude]' 'claude_skill: wv-quiet' '---' '# Quiet body' > "$A/.weave/procedures/quiet.md"
check "projector accepts a local repo procedure" project "$A"
check "a local repo procedure is not projected" test ! -e "$A/.claude/skills/wv-quiet"
out=$(guide "$A" quiet || true)
check "a local repo procedure is readable through wv guide" contains "$out" '# Quiet body'
rm "$A/.weave/procedures/quiet.md"

# Doctor: current, then stale after an edit, then current after re-projection.
check "projector re-runs" project "$A"
d=$(doctor_check "$A")
check "doctor passes current repo procedures" contains "$d" '"status":"pass"'
check "doctor lists the replaced package procedure" contains "$d" 'replacing package: verify'
procedure "$A/.weave/procedures" house-lesson wv-house-lesson '# Repo A house lesson, revised'
d=$(doctor_check "$A")
check "doctor warns on a stale projection" contains "$d" '"status":"warn"'
check "doctor names the stale surface" contains "$d" '.claude/skills'
check "doctor does not write the projection" grep -qxF '# Repo A house lesson' "$A/.claude/skills/wv-house-lesson/SKILL.md"
check "projector refreshes" project "$A"
d=$(doctor_check "$A")
check "doctor passes after re-projection" contains "$d" '"status":"pass"'
check "doctor is silent where a repo authors no procedures" test "$(doctor_check "$B")" = null

# wv-5505c2: a repository with no procedures of its own (the usual consumer) still
# has the package procedures projected, and doctor compares them: an install that
# changed a package procedure without wv init-repo --update left them stale and
# doctor silent.
package_check() { doctor_json "$1" | jq -c '[.checks[] | select(.check == "procedure-projections")][0] // null'; }
d=$(package_check "$B")
check "doctor passes current package projections in a repo without its own procedures" contains "$d" '"status":"pass"'
procedure "$CONFIG/procedures" session wv-session '# Package session, revised by an install'
d=$(package_check "$B")
check "doctor warns when a package procedure changed and the repo was not re-projected" contains "$d" '"status":"warn"'
check "...naming the stale surface" contains "$d" '.claude/skills'
check "...without writing it" lacks "$(cat "$B/.claude/skills/wv-session/SKILL.md")" 'revised by an install'
check "projector refreshes the second repo" project "$B"
d=$(package_check "$B")
check "doctor passes after the repo is re-projected" contains "$d" '"status":"pass"'
procedure "$CONFIG/procedures" session wv-session '# Package session'
check "projector restores the second repo" project "$B"
# A third repository gets a hot zone of its own: the suite's shared one stays
# bound to repo A, which the cases below still use.
C="$TMP/repo-c"; mkdir -p "$C/.weave"; git -C "$C" init -q
(umask 077 && mkdir -p "$TMP/hotzone-c")
check "doctor is silent in a repo with no managed projection at all" \
    test "$(WV_HOT_ZONE="$TMP/hotzone-c" package_check "$C")" = null

# Contract failures: an invalid repo procedure is an error, never a fallback.
printf '%s\n' '---' 'id: verify' 'description: broken' '---' '# no adapters' > "$A/.weave/procedures/verify.md"
out=$(guide "$A" verify || true)
check "wv guide refuses an invalid repo procedure" contains "$out" 'fail the procedure contract'
check "wv guide does not fall back to the package copy" lacks "$out" '# Package verify'
check "projector refuses an invalid repo procedure" refused project "$A"
check "the refused projection left the old skill" grep -qF '# Repo A verify' "$A/.claude/skills/wv-verify/SKILL.md"
d=$(doctor_check "$A")
check "doctor fails an invalid repo procedure" contains "$d" '"status":"fail"'
procedure "$A/.weave/procedures" verify wv-verify '# Repo A verify: vitest and tsc'

# A file named other than its id is refused, so wv guide can find it by name.
procedure "$A/.weave/procedures" misnamed wv-misnamed '# body'
mv "$A/.weave/procedures/misnamed.md" "$A/.weave/procedures/other-name.md"
check "validator refuses a file not named after its id" refused "$CONFIG/gen-procedures.sh" --source="$A/.weave/procedures" --check
rm "$A/.weave/procedures/other-name.md"

# Two procedures may not claim one skill across the sources.
procedure "$A/.weave/procedures" clash wv-session '# claims the package skill name'
check "projector refuses a skill name shared across sources" refused project "$A"
rm "$A/.weave/procedures/clash.md"

echo "Results: $PASSED/$TESTS passed"
[ "$PASSED" -eq "$TESTS" ]
