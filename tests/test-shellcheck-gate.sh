#!/usr/bin/env bash
# The pre-commit shellcheck gate's policy across a transition (epic wv-d67163).
#
# The commit is linted under the union of what HEAD and the index each select,
# so it cannot narrow the policy that judges it:
#   - F1 (wv-5ba258): a side with no .weave/shellcheck.conf contributes the
#     fixed patterns, so adopting a scope that excludes scripts/, or deleting
#     HEAD's declaration, still lints what the undeclared side lints.
#   - F2 (wv-e929cf): each run sees one rc, the nearest one in its own
#     frozen tree (nested files included, nothing merged), and nothing from
#     HOME, XDG_CONFIG_HOME, directories above the temp dir, SHELLCHECK_OPTS
#     or an untracked working-tree rc.
# The hook runs from this checkout against a fixture repository, as
# tests/test-gate-snapshot.sh runs it.
set -uo pipefail
export WV_TEST_SUITE=1
export WV_CALL_SOURCE=test

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS="$ROOT/scripts/hooks"

run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }
has()   { if grep -qF -- "$3" <<< "$2"; then ok "$1"; else bad "$1" "missing [$3] in: $(tail -5 <<< "$2")"; fi; }
hasnt() { if grep -qF -- "$3" <<< "$2"; then bad "$1" "unexpected [$3]"; else ok "$1"; fi; }

if ! command -v shellcheck >/dev/null 2>&1; then
    echo "test-shellcheck-gate: shellcheck unavailable — skipped"
    exit 0
fi

T=$(mktemp -d /tmp/wv-shellcheck-gate-XXXXXX)
trap 'rm -rf "$T"' EXIT
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
unset WV_GATE_BASE WV_GATE_TREE WV_GATE_PHASE WV_GATE_ID WV_GATE_CONTEXT WV_HOOK_REEXEC SHELLCHECK_OPTS
mkdir -p "$T/bin" "$T/cfg"
ln -s "$ROOT/scripts/wv" "$T/bin/wv"
export PATH="$T/bin:$PATH" WV_LIB_DIR="$ROOT/scripts"
export WV_HOT_ZONE="$T" WV_DB="$T/brain.db" WV_CONFIG_DIR="$T/cfg" WV_PROJECT_DIR="$T/work"
export WV_SUITE_LOG="$T/suite_runs.jsonl" WV_GATE_LOG="$T/gate_runs.jsonl"
export WV_AUTO_SYNC=0 WV_AUTO_CHECKPOINT=0 WV_REQUIRE_LEARNING=0 WV_RUN_CACHE=0

W="$T/work"
git init -q -b main "$W"; cd "$W" || exit 1
git config user.name "Gate Test"; git config user.email gate@example.com; git config commit.gpgsign false
mkdir -p scripts tools .weave
printf '#!/bin/bash\necho ok\n' > scripts/x.sh
printf '#!/bin/bash\necho ok\n' > tools/t.sh
git add -A && git -c core.hooksPath=/dev/null commit -q -m fixture
wv add "shellcheck gate fixture node" --status=active --force --criteria="c1|c2" --risks=low >/dev/null 2>&1

# precommit [VAR=value...] — the hook, with any environment overrides.
precommit() { OUT=$(env "$@" bash "$HOOKS/pre-commit-weave.sh" 2>&1); RC=$?; }
land() { git add -A && git -c core.hooksPath=/dev/null commit -q -m "$1"; }
# A finding at --severity=warning: SC2046, an unquoted command substitution.
plant() { printf '#!/bin/bash\necho $(ls)\n' > "$1"; git add -f "$1"; }
clean() { git reset -q; git checkout -q -- . 2>/dev/null; git clean -qfd 2>/dev/null; mkdir -p .weave; }
EXCLUDE_SCRIPTS=$'[scope]\nmode = derived\n[exclude]\nscripts/\n'

echo "F1: an undeclared side lints by the fixed patterns (wv-5ba258)"
plant scripts/x.sh; precommit
check "(control) no declaration anywhere: a scripts/ finding is refused" "1" "$RC"
has "...by shellcheck" "$OUT" "SC2046"
clean

printf '%s' "$EXCLUDE_SCRIPTS" > .weave/shellcheck.conf; git add -f .weave/shellcheck.conf
plant scripts/x.sh; precommit
check "adopting a scope that excludes scripts/ still lints scripts/ in that commit" "1" "$RC"
has "...under HEAD's fixed patterns" "$OUT" "SC2046"
clean

printf '%s' "$EXCLUDE_SCRIPTS" > .weave/shellcheck.conf; git add -f .weave/shellcheck.conf; land "adopt"
plant scripts/x.sh; precommit
check "(control) once both sides exclude scripts/, a scripts/ file is not linted" "0" "$RC"
hasnt "...no finding" "$OUT" "SC2046"
clean

git rm -q --cached .weave/shellcheck.conf; rm -f .weave/shellcheck.conf
plant scripts/x.sh; precommit
check "deleting HEAD's declaration lints scripts/ under the index's fixed patterns" "1" "$RC"
has "...by shellcheck" "$OUT" "SC2046"
clean

plant tools/t.sh; git rm -q --cached .weave/shellcheck.conf; precommit
check "(control) ...and HEAD's declaration still applies alongside: tools/ is linted" "1" "$RC"
has "...by shellcheck" "$OUT" "SC2046"
clean

echo "F2: configuration comes from each frozen tree, whole, and nowhere else (wv-e929cf)"
# Back to no declaration: scripts/*.sh is linted by the fixed patterns.
git rm -q .weave/shellcheck.conf; land "drop the scope"
rc() { printf '%s\n' "$2" > "$1"; git add -f "$1"; }
plant scripts/x.sh; precommit
check "(control) no rc anywhere: the finding is refused" "1" "$RC"
clean

rc .shellcheckrc 'disable=SC2046'; land "root rc"
plant scripts/x.sh; precommit
check "(control) a tracked root rc applies" "0" "$RC"
clean

rc scripts/.shellcheckrc 'disable=SC2016'; land "nested rc"
plant scripts/x.sh; precommit
check "the nearest rc wins whole: a nested rc hides the root's suppression" "1" "$RC"
has "...so the finding is refused" "$OUT" "SC2046"
clean

rc scripts/.shellcheckrc 'disable=SC2046'; rc .shellcheckrc 'disable=SC2016'; land "nested suppression only"
plant scripts/x.sh; precommit
check "a nested rc in both trees applies to the files under it" "0" "$RC"
clean
git rm -q scripts/.shellcheckrc; rc .shellcheckrc 'disable=SC2016'; land "no suppression anywhere"

rc scripts/.shellcheckrc 'disable=SC2046'; plant scripts/x.sh; precommit
check "a nested suppression staged with the code it suppresses is refused" "1" "$RC"
has "...under HEAD's configuration" "$OUT" "under HEAD's shellcheck configuration"
clean

rc scripts/shellcheckrc 'disable=SC2046'; land "undotted nested rc"
plant scripts/x.sh; precommit
check "the undotted name counts as an rc" "0" "$RC"
clean
rc scripts/.shellcheckrc 'disable=SC2016'; land "both names in one directory"
plant scripts/x.sh; precommit
check ".shellcheckrc takes precedence over shellcheckrc in one directory" "1" "$RC"
clean
git rm -q scripts/.shellcheckrc scripts/shellcheckrc; land "only the root rc, suppressing nothing"

plant scripts/x.sh; precommit SHELLCHECK_OPTS="-e SC2046"
check "SHELLCHECK_OPTS cannot relax it" "1" "$RC"
clean

# R4 (wv-77b743): an rc held as a link is refused, not read as its pathname.
printf 'disable=SC2046\n' > lint.rc; git add lint.rc; git rm -q --cached .shellcheckrc; rm -f .shellcheckrc
ln -s lint.rc .shellcheckrc; git add .shellcheckrc
plant scripts/x.sh; precommit
check "a staged rc held as a link refuses the commit" "1" "$RC"
has "...saying it is not a regular file" "$OUT" "is not a regular file"
rm -f .shellcheckrc lint.rc; clean

# With no rc in either tree, nothing stops shellcheck's own search: the gate
# must stop it, or a user rc or one above the temp directory applies.
git rm -q .shellcheckrc; land "no tracked rc"
mkdir -p "$T/home/.config" "$T/xdg" "$T/tmp-parent/inner"
printf 'disable=SC2046\n' > "$T/home/.shellcheckrc"
printf 'disable=SC2046\n' > "$T/xdg/shellcheckrc"
printf 'disable=SC2046\n' > "$T/tmp-parent/.shellcheckrc"
plant scripts/x.sh
precommit HOME="$T/home"
check "a user rc in HOME cannot relax the gate" "1" "$RC"
precommit XDG_CONFIG_HOME="$T/xdg"
check "a user rc in XDG_CONFIG_HOME cannot relax it" "1" "$RC"
precommit TMPDIR="$T/tmp-parent/inner"
check "an rc above the gate's temp directory cannot relax it" "1" "$RC"
clean
printf 'disable=SC2046\n' > .shellcheckrc
plant scripts/x.sh; precommit
check "an untracked working-tree rc is not configuration" "1" "$RC"
has "...the finding is refused" "$OUT" "SC2046"
rm -f .shellcheckrc; clean

# wv-cb632d: candidate lanes run this hook at once, and shellcheck on a large
# suite peaks at 1.6 GB, so lanes take turns through the lock gate_lanes_run
# names. Each lane still lints in full; a finding is still refused.
echo "lanes take turns at shellcheck (wv-cb632d)"
if command -v flock >/dev/null 2>&1; then
    L="$T/sc.lock"
    real_sc=$(command -v shellcheck)
    # A shellcheck that records whether the lock variable reached it.
    printf '#!/bin/sh\necho "${WV_GATE_SC_LOCK-unset}" >> %q\nexec %q "$@"\n' "$T/sc-env" "$real_sc" > "$T/bin/shellcheck"
    chmod +x "$T/bin/shellcheck"
    elapsed_ms() { echo $(( ($(date +%s%N) - $1) / 1000000 )); }
    printf '#!/bin/bash\necho ok2\n' > scripts/x.sh; git add scripts/x.sh
    t0=$(date +%s%N); precommit WV_GATE_SC_LOCK="$L"; free_ms=$(elapsed_ms "$t0")
    check "(control) with the lock free the lane's shellcheck passes" "0" "$RC"
    flock "$L" sleep 4 & holder=$!
    sleep 0.3
    t0=$(date +%s%N); precommit WV_GATE_SC_LOCK="$L"; held_ms=$(elapsed_ms "$t0")
    wait "$holder"
    check "with the lock held by another lane, the shellcheck waits for it, then passes" "0 yes" \
        "$RC $([ $((held_ms - free_ms)) -ge 2500 ] && echo yes || echo "no (free ${free_ms}ms, held ${held_ms}ms)")"
    : > "$T/sc-env"
    precommit WV_GATE_SC_LOCK="$L"
    check "...and the lock variable reaches no process the hook starts" "unset" "$(sort -u "$T/sc-env")"
    clean
    plant scripts/x.sh; precommit WV_GATE_SC_LOCK="$L"
    check "a finding is still refused under the lock" "1" "$RC"
    has "...by shellcheck" "$OUT" "SC2046"
    clean
    rm -f "$T/bin/shellcheck"
else
    echo "  (flock unavailable: the hook runs shellcheck unserialised, as before)"
fi

echo ""
echo "test-shellcheck-gate: $pass/$run passed"
[ "$pass" -eq "$run" ]
