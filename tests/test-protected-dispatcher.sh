#!/usr/bin/env bash
# The protected dispatcher (S2a, wv-1f98b6, epic wv-d67163; boundary rule 3,
# wv-ecf877).
#
# Where HEAD carries scripts/hooks, pre-commit and pre-push run HEAD's committed
# scripts/ tree from a private copy: the hook, the suite pool, the libraries,
# wv with its router, and the python checkers. Pinned here, in a fixture whose
# HEAD carries this checkout's scripts/:
#   - an unstaged edit to the pool, a helper library, wv or the hook itself,
#     or another wv earlier on PATH, cannot weaken or skip the gate. Each tamper is also run once with the
#     working tree as the gate, to show it would have worked there;
#   - a staged edit to the dispatcher is judged by HEAD's;
#   - python checkers never import a module planted in the working tree or on
#     PYTHONPATH (module import control), and WV_LIB_DIR does not reach wv;
#   - a link in scripts/ is refused on the candidate side and never followed
#     at HEAD;
#   - a repository whose HEAD has no hook (a consumer) runs the installed copy,
#     and that copy no longer hops to a working-tree hook.
# shellcheck source=tests/lib/sed-inplace.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/sed-inplace.sh"  # sed -i is GNU-only (wv-076a98)
set -uo pipefail
export WV_TEST_SUITE=1
export WV_CALL_SOURCE=test

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }
has()   { if grep -qF -- "$3" <<< "$2"; then ok "$1"; else bad "$1" "missing [$3] in: $(tail -5 <<< "$2")"; fi; }
hasnt() { if grep -qF -- "$3" <<< "$2"; then bad "$1" "unexpected [$3]"; else ok "$1"; fi; }

T=$(mktemp -d /tmp/wv-protected-dispatcher-XXXXXX)
trap 'rm -rf "$T"' EXIT
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
unset WV_GATE_BASE WV_GATE_TREE WV_GATE_PHASE WV_GATE_ID WV_GATE_CONTEXT WV_HOOK_REEXEC
unset PYTHONPATH
newrepo() {
    git init -q -b main "$1"
    git -C "$1" config user.name "Gate Test"; git -C "$1" config user.email gate@example.com
    git -C "$1" config commit.gpgsign false; git -C "$1" config tag.gpgSign false
}

mkdir -p "$T/bin" "$T/cfg" "$T/marks"
ln -s "$ROOT/scripts/wv" "$T/bin/wv"
export PATH="$T/bin:$PATH" WV_LIB_DIR="$ROOT/scripts"
export WV_HOT_ZONE="$T" WV_DB="$T/brain.db" WV_CONFIG_DIR="$T/cfg" WV_PROJECT_DIR="$T/work"
export WV_SUITE_LOG="$T/suite_runs.jsonl" WV_GATE_LOG="$T/gate_runs.jsonl"
export WV_AUTO_SYNC=0 WV_AUTO_CHECKPOINT=0 WV_REQUIRE_LEARNING=0 WV_RUN_CACHE=0
MARK="$T/marks"; W="$T/work"

newrepo "$W"; cd "$W" || exit 1
git init -q --bare "$T/remote.git"; git remote add origin "$T/remote.git"
# This checkout's tracked scripts/, as the fixture's committed gate.
_pd_skip=()
git -C "$ROOT" ls-files -z -- scripts "${_pd_skip[@]}" \
    | tar -C "$ROOT" --null -T - -cf - | tar -xf -
# This synthetic repository holds only scripts/; external cases declare their own roles later.
jq '.enforcement = ["scripts/"] | .invoking |= map(select(startswith("scripts/")))
    | .entry_points |= with_entries(select(.key | startswith("scripts/"))) | .shared = []' \
    scripts/hooks/gate-roles.json > "$T/fixture-roles.json" &&
    cat "$T/fixture-roles.json" > scripts/hooks/gate-roles.json
mkdir -p src tests .weave
cat > tests/test-probe.sh <<PROBE_EOF
#!/bin/sh
echo run >> "$MARK/probe"
echo "\${WV_HOOK_REEXEC:-unset}" > "$MARK/reexec"
[ -f "$MARK/fail" ] && exit 1
exit 0
PROBE_EOF
cat > tests/test-heavy.sh <<HEAVY_EOF
#!/bin/sh
echo run >> "$MARK/heavy"
[ -f "$MARK/heavy-fail" ] && exit 1
exit 0
HEAVY_EOF
chmod +x tests/test-probe.sh tests/test-heavy.sh
cat > .weave/test-map.conf <<'MAP_EOF'
[map]
src/a.sh = tests/test-probe.sh
src/b.sh = tests/test-heavy.sh
scripts/ = tests/test-probe.sh
docs/ = tests/test-probe.sh
tests/test-probe.sh = tests/test-probe.sh
tests/test-heavy.sh = tests/test-heavy.sh
[heavy]
tests/test-heavy.sh
MAP_EOF
printf '#!/bin/sh\necho a\n' > src/a.sh
printf '#!/bin/sh\necho b\n' > src/b.sh
git add -A && git -c core.hooksPath=/dev/null commit -q -m fixture
wv add "protected dispatcher fixture node" --status=active --force --criteria="c1|c2" --risks=low >/dev/null 2>&1
# The installed copy, as install.sh writes it: the entry point git runs, and
# the recovery module beside it where this checkout has one (wv-669900; the
# name is assembled because the release strips that file).
install -m 755 "$ROOT/scripts/hooks/pre-commit-weave.sh" .git/hooks/pre-commit
_pd_rec=pre-commit-"recovery.sh"
[ ! -f "$ROOT/scripts/hooks/$_pd_rec" ] || install -m 644 "$ROOT/scripts/hooks/$_pd_rec" ".git/hooks/$_pd_rec"

commit_nohook() { git add -A && git -c core.hooksPath=/dev/null commit -q -m "$1"; }
runs() { if [ -f "$MARK/$1" ]; then wc -l < "$MARK/$1" | tr -d ' '; else echo 0; fi; }
reset_marks() { rm -f "$MARK/probe" "$MARK/heavy" "$MARK/fail" "$MARK/heavy-fail" "$MARK/imported" "$MARK/reexec"; }
# Each run stages new bytes: the pool reuses a green result for content it has
# already seen, and a reused probe would not run.
n=0
stage_src() { n=$((n+1)); printf '#!/bin/sh\necho a-%s\n' "$n" > src/a.sh; git add src/a.sh; }
# gate — the installed copy, as git runs it. unguarded — the working tree's
# scripts/ as the gate, which is what ran before S2a: the installed copy hopped
# to it. Built as a lane the way the hook builds one, from the working tree.
gate() { OUT=$(./.git/hooks/pre-commit 2>&1); RC=$?; }
# lane <base> — the working tree's scripts/, including the fixture's own contract.
lane() {
    rm -rf "${T:?}/lane"; mkdir -p "$T/lane/tree"; cp -a scripts "$T/lane/tree/"
    printf '%s\n' "$1" > "$T/lane/weave-gate-lane"
}
unguarded() {
    lane "$(git rev-parse HEAD)"
    OUT=$(env -u WV_LIB_DIR -u WV_CLI bash "$T/lane/tree/scripts/hooks/pre-commit-weave.sh" 2>&1); RC=$?
}
restore() { git checkout -q HEAD -- scripts; git clean -qfd -- scripts; }

echo "control: the committed gate runs"
reset_marks; stage_src; gate
check "(control) a clean commit is admitted" "0" "$RC"
check "...after running the routed suite" "1" "$(runs probe)"
check "...which inherited no hook marker from the gate" "unset" "$(cat "$MARK/reexec" 2>/dev/null)"
reset_marks; touch "$MARK/fail"; stage_src; gate
check "(control) a failing suite refuses the commit" "1" "$RC"
# wv-9da519: the lane needs scripts/wv as well as the hook, so a commit that
# drops scripts/wv would hand the next commit to the installed copy. It is
# enforcement, and deleting it needs a retirement record HEAD does not hold.
git reset -q HEAD -- src/a.sh; git checkout -q -- src/a.sh
git rm -q scripts/wv; reset_marks; gate
check "a commit deleting scripts/wv is refused" "1" "$RC"
# Whichever check refuses first (a gate file naming the missing path, or the
# deletion without a retirement record), the refusal names scripts/wv.
if grep -qE 'scripts/wv.*refusing|deleting enforcement scripts/wv' <<< "$OUT"; then
    ok "...by the protected gate, naming scripts/wv"
else
    bad "...by the protected gate, naming scripts/wv" "$(tail -3 <<< "$OUT")"
fi
git reset -q HEAD -- scripts/wv; restore

echo "an unstaged edit to the dispatcher cannot weaken or skip the gate"
# tamper <name> <file> <text> — append <text> to a working-tree dispatcher file,
# then judge a commit with a failing suite: protected, then unguarded.
tamper() {
    local name=$1 file=$2 text=$3
    restore; printf '%s\n' "$text" >> "$file"
    reset_marks; touch "$MARK/fail"; stage_src; gate
    check "$name: the commit is still refused" "1" "$RC"
    check "...after the suite ran" "1" "$(runs probe)"
    reset_marks; touch "$MARK/fail"; unguarded
    check "(control) $name: with the working tree as the gate, the tamper admits it" "0" "$RC"
    if [ "$RC" -ne 0 ]; then printf '%s\n' "$OUT"; fi
    restore
}
tamper "the pool's runner returns success" scripts/lib/wv-gate-pool.sh 'run_hook_suites() { cat >/dev/null; return 0; }'
tamper "the snapshot helper lists nothing staged" scripts/lib/wv-gate-snapshot.sh 'gate_changed() { return 0; }'
restore
# The hook itself: the tamper must come before the gate runs, so it replaces
# the second line rather than appending.
sed_inplace '2i\
exit 0' scripts/hooks/pre-commit-weave.sh
reset_marks; touch "$MARK/fail"; stage_src; gate
check "the working tree's hook exits 0 at the top: the commit is still refused" "1" "$RC"
reset_marks; touch "$MARK/fail"; unguarded
check "(control) with the working tree as the gate, it admits" "0" "$RC"
restore
# wv's router: an impact command that selects nothing.
mv scripts/wv scripts/wv.real
printf '#!/bin/sh\ncase "$1" in impact) echo "[]"; exit 0 ;; esac\nexec "$(dirname "$0")/wv.real" "$@"\n' > scripts/wv
chmod +x scripts/wv
reset_marks; touch "$MARK/fail"; stage_src; gate
check "wv's router selects nothing in the working tree: the commit is still refused" "1" "$RC"
check "...after the suite ran" "1" "$(runs probe)"
reset_marks; touch "$MARK/fail"; unguarded
check "(control) with the working tree as the gate, no suite runs" "0" "$(runs probe)"
rm -f scripts/wv.real; restore
# The installed wv on PATH was the old gate's router.
printf '#!/bin/sh
case "$1" in impact) echo "[]"; exit 0 ;; esac
exec "%s/scripts/wv" "$@"
' "$ROOT" > "$T/bin/wv.stub"
chmod +x "$T/bin/wv.stub"; mv "$T/bin/wv.stub" "$T/bin/wv"
reset_marks; touch "$MARK/fail"; stage_src; gate
check "a wv earlier on PATH that selects nothing: the commit is still refused" "1" "$RC"
check "...after the suite ran" "1" "$(runs probe)"
rm -f "$T/bin/wv"; ln -s "$ROOT/scripts/wv" "$T/bin/wv"

echo "a staged edit to the dispatcher is judged by HEAD's"
printf '%s\n' 'run_hook_suites() { cat >/dev/null; return 0; }' >> scripts/lib/wv-gate-pool.sh
git add scripts/lib/wv-gate-pool.sh
reset_marks; touch "$MARK/fail"; gate
check "a staged pool that skips suites: HEAD's pool runs them and the commit is refused" "1" "$RC"
check "...after the suite ran" "1" "$(runs probe)"
git reset -q -- scripts; restore

echo "module import control"
cat > scripts/json.py <<JSON_EOF
open("$MARK/imported", "w").write("working tree")
raise SystemExit(0)
JSON_EOF
mkdir -p "$T/pypath" docs
cp scripts/json.py "$T/pypath/json.py"
reset_marks; printf '# Notes\n\nPlain text %s.\n' "$n" > docs/notes.md; git add docs/notes.md; gate
rm -f scripts/json.py
# wv's inline python ran with the caller's PYTHONPATH and with the repository
# root, its working directory, first on sys.path.
reset_marks; OUT=$(PYTHONPATH="$T/pypath" ./.git/hooks/pre-commit 2>&1)
check "a module planted on PYTHONPATH is not imported" "no" "$([ -f "$MARK/imported" ] && echo yes || echo no)"
reset_marks; PYTHONPATH="$T/pypath" wv analyze suites --json >/dev/null 2>&1
check "(control) a wv run with that PYTHONPATH imports it" "yes" "$([ -f "$MARK/imported" ] && echo yes || echo no)"
cp "$T/pypath/json.py" json.py
reset_marks; gate
check "a module planted at the repository root is not imported" "no" "$([ -f "$MARK/imported" ] && echo yes || echo no)"
reset_marks; wv analyze suites --json >/dev/null 2>&1
check "(control) a wv run in the repository imports it" "yes" "$([ -f "$MARK/imported" ] && echo yes || echo no)"
rm -f json.py; git reset -q -- docs; rm -rf docs
reset_marks; stage_src; OUT=$(WV_LIB_DIR="$T/nolib" WV_CLI="$T/nolib/wv" ./.git/hooks/pre-commit 2>&1); RC=$?
check "WV_LIB_DIR and WV_CLI in the environment do not reach the committed wv" "0" "$RC"
check "...which routed the suite" "1" "$(runs probe)"

echo "links are never followed"
# Not a .sh file: shellcheck's own link refusal (R4) would catch that one.
ln -s ../src/a.sh scripts/linked; git add scripts/linked
reset_marks; stage_src; gate
check "a staged link under scripts/ is refused" "1" "$RC"
has "...naming it" "$OUT" "the staged scripts/ holds a link or submodule (scripts/linked)"
git reset -q -- scripts; rm -f scripts/linked
ln -s ../../src/a.sh scripts/lib/linked.sh; commit_nohook "a link at HEAD (bypassed)"
reset_marks; stage_src; gate
check "a link in HEAD's scripts/ refuses rather than being followed" "1" "$RC"
has "...naming it" "$OUT" "HEAD's scripts/ holds a link or submodule (scripts/lib/linked.sh)"
git rm -q scripts/lib/linked.sh; commit_nohook "drop the link"

echo "the protected lane judges the commit its gate came from"
lane 0000000000000000000000000000000000000000
OUT=$(env -u WV_LIB_DIR -u WV_CLI bash "$T/lane/tree/scripts/hooks/pre-commit-weave.sh" 2>&1); RC=$?
check "a lane whose gate came from another commit refuses" "1" "$RC"
has "...saying HEAD moved" "$OUT" "HEAD moved between copying its committed gate"

echo "pre-push runs HEAD's committed gate"
install -m 755 "$ROOT/scripts/hooks/pre-push-weave.sh" .git/hooks/pre-push
git reset -q; git -c core.hooksPath=/dev/null push -q origin main 2>/dev/null
printf '#!/bin/sh\necho b-1\n' > src/b.sh; commit_nohook "b owes heavy"
reset_marks; touch "$MARK/heavy-fail"
OUT=$(git push -q origin main 2>&1); RC=$?
check "(control) a failing heavy suite refuses the push" "1" "$RC"
check "...after it ran" "1" "$(runs heavy)"
sed_inplace '2i\
exit 0' scripts/hooks/pre-push-weave.sh
reset_marks; touch "$MARK/heavy-fail"
OUT=$(git push -q origin main 2>&1); RC=$?
check "the working tree's pre-push exits 0 at the top: the push is still refused" "1" "$RC"
reset_marks; touch "$MARK/heavy-fail"
lane "$(git rev-parse HEAD)"
OUT=$(env -u WV_LIB_DIR -u WV_CLI bash "$T/lane/tree/scripts/hooks/pre-push-weave.sh" origin "$T/remote.git" \
    < <(git rev-parse HEAD | sed 's/.*/refs\/heads\/main & refs\/heads\/main 0000000000000000000000000000000000000000/') 2>&1); RC=$?
check "(control) with the working tree as the gate, it admits" "0" "$RC"
restore
reset_marks
OUT=$(git push -q origin main 2>&1); RC=$?
check "(control) the push passes once the suite does" "0" "$RC"
rm -f .git/hooks/pre-push

echo "the recovery module beside the installed copy (wv-669900)"
# A fixture module, so these cases hold where this checkout has none (the
# release strips it): it says when it is read and defines the entry point the
# dispatcher calls. Recovery itself is covered by the recovery suite.
_pd_base=$(git rev-parse HEAD)
_pd_mod=scripts/hooks/$_pd_rec
_pd_beside=.git/hooks/$_pd_rec
_pd_saved=0; if [ -f "$_pd_beside" ]; then cp "$_pd_beside" "$T/beside.saved"; _pd_saved=1; fi
printf '# shellcheck shell=bash\n_pcr_main() { echo "fixture recovery read" >&2; return 0; }\n' > "$_pd_mod"
commit_nohook "fixture recovery module"
install -m 644 "$_pd_mod" "$_pd_beside"
reset_marks; stage_src; gate
check "(control) HEAD tracks the module and the copy beside the hook matches: admitted" "0" "$RC"
has "...after the dispatcher read the module" "$OUT" "fixture recovery read"
hasnt "...without a stale-copy notice" "$OUT" "this copy differs from it"
rm -f "$_pd_beside"; reset_marks; stage_src; gate
check "a missing module beside the hook is refused where HEAD tracks it" "1" "$RC"
has "...naming the missing module" "$OUT" "the recovery module is missing beside this hook"
check "...before any suite ran" "0" "$(runs probe)"
printf '# no entry point\n' > "$_pd_beside"; stage_src; gate
check "a module without the recovery entry point is refused" "1" "$RC"
has "...as one that could not be loaded" "$OUT" "could not load the recovery module"
has "...with the stale-copy notice" "$OUT" "this copy differs from it"
cp "$_pd_mod" "$_pd_beside"; printf '# local edit\n' >> "$_pd_beside"; reset_marks; stage_src; gate
check "a module differing from HEAD's still loads: admitted" "0" "$RC"
has "...with the stale-copy notice" "$OUT" "this copy differs from it"
# A release build: the module and its role are gone, as build-release.sh
# projects them.
git rm -q "$_pd_mod"
jq --arg m "$_pd_mod" '.invoking -= [$m] | del(.entry_points[$m])' scripts/hooks/gate-roles.json > "$T/norec-roles" \
    && cat "$T/norec-roles" > scripts/hooks/gate-roles.json
commit_nohook "no recovery module"
printf '# shellcheck shell=bash\n_pcr_main() { echo "fixture recovery read" >&2; return 0; }\n' > "$_pd_beside"
reset_marks; stage_src; gate
check "where HEAD has no module (a release build), the commit is admitted" "0" "$RC"
hasnt "...and the copy beside the hook is never read" "$OUT" "fixture recovery read"
rm -f "$_pd_beside"; reset_marks; stage_src; gate
check "...nor is its absence refused" "0" "$RC"
git checkout -q "$_pd_base" -- scripts; commit_nohook "restore the fixture's scripts"
if [ "$_pd_saved" = 1 ]; then cp "$T/beside.saved" "$_pd_beside"; fi
reset_marks; stage_src; gate
check "(control) restored, the commit is admitted" "0" "$RC"

echo "declared enforcement outside scripts/ runs from the protected copy"
# These are fixture files, not dependencies on the dev-only source suites.
# Assemble their names so the release closure scan does not mistake them for
# dependencies that would be missing in the public projection.
_pd_memory=tests/test-memory-projection-"parity.sh"
_pd_refs=tests/test-shipped-test-"refs.sh"
_pd_pattern=tests/lib/release-leak-"pattern.ere"
mkdir -p tests/lib
printf 'release-policy\n' > build-release.sh
printf 'memory-policy\n' > "$_pd_memory"
printf 'reject-policy\n' > "$_pd_pattern"
# The hook's real release caller hands the checker a private copy of its own
# policy (R-a, wv-a75d98): HEAD's bytes, never the working tree's, and not the
# parity checker, which belongs to another check.
cat > "$_pd_refs" <<'EXTERNAL_EOF'
#!/usr/bin/env bash
set -eu
[ "${1:-}" = --scan ] || exit 0
policy=$4
grep -qx release-policy "$policy/build-release.sh"
grep -qx reject-policy "$policy/tests/lib/release-leak-"pattern.ere
if [ -e "$policy/tests/test-memory-projection-"parity.sh ]; then
    echo 'external fixture saw another check'"'"'s file' >&2
    exit 1
fi
subject=$(git show "$WV_GATE_TREE:src/a.sh")
if grep -q BUG <<< "$subject"; then
    echo 'external fixture rejected defect' >&2
    exit 1
fi
echo 'external fixture accepted subject' >&2
EXTERNAL_EOF
jq --arg m "$_pd_memory" --arg c "$_pd_refs" --arg p "$_pd_pattern" \
    '.enforcement += ["build-release.sh", $m, $c, $p]' \
    scripts/hooks/gate-roles.json > "$T/external-roles"
mv "$T/external-roles" scripts/hooks/gate-roles.json
commit_nohook "external enforcement fixture"
# A staged tests/ path switches the release leak guard on.
stage_leak() { stage_src; printf '%s\n' "$n" > tests/leak-trigger.txt; git add tests/leak-trigger.txt; }
reset_marks; stage_leak; gate
check "the declared external files reach the check that reads them" "0" "$RC"
has "...and its external checker ran" "$OUT" "external fixture accepted subject"
# Both the checker and its policy dependencies are weakened in the worktree.
# The staged subject still has to meet HEAD's policy, not those weaker bytes.
printf '#!/bin/sh\nexit 0\n' > "$_pd_refs"
printf 'weakened\n' > build-release.sh
printf 'weakened\n' > "$_pd_memory"
printf 'weakened\n' > "$_pd_pattern"
stage_leak; printf '# BUG\n' >> src/a.sh; git add src/a.sh; gate
check "unstaged external checker and policy edits cannot admit a defect" "1" "$RC"
has "...refused by the protected external checker" "$OUT" "external fixture rejected defect"
stage_leak; gate
check "those unstaged edits do not break a healthy staged subject" "0" "$RC"
git reset -q -- tests/leak-trigger.txt; rm -f tests/leak-trigger.txt
restore
ln -sf ../../src/a.sh "$_pd_refs"
commit_nohook "external enforcement link (bypassed)"
stage_src; gate
check "an external enforcement link is refused, not followed" "1" "$RC"
has "...by the protected-copy check" "$OUT" "is not a regular file"

echo "consumers: no committed hook, the installed copy runs itself"
# consumer_env <repo> — the repository's own hot zone and a claimed node. Sharing
# the work fixture's zone made wv refuse it as another repository's, so the gate
# failed before any suite ran and an expected refusal passed for that reason.
# The installed copy in .git/hooks finds its libraries where install.sh puts
# them, ~/.local/lib/weave/lib: a private HOME holds this checkout's there. The
# caller's HOME made these cases run whatever Weave that HOME had installed,
# and a gate run with none refused for want of libraries, which the expected
# refusal below could not tell from a failing suite.
consumer_env() {
    export HOME="$T/home"
    mkdir -p "$HOME/.local/lib/weave" && ln -sfn "$ROOT/scripts/lib" "$HOME/.local/lib/weave/lib"
    export WV_HOT_ZONE="$T/hz-$(basename "$1")" WV_DB="$T/hz-$(basename "$1")/brain.db" WV_PROJECT_DIR="$1"
    mkdir -p "$WV_HOT_ZONE"
    wv add "consumer fixture node" --status=active --force --criteria="c1|c2" --risks=low >/dev/null 2>&1
}
C="$T/consumer"; newrepo "$C"; cd "$C" || exit 1; consumer_env "$C"
mkdir -p src tests .weave scripts/hooks
cp "$W/tests/test-probe.sh" tests/
printf '[map]\nsrc/ = tests/test-probe.sh\n' > .weave/test-map.conf
printf '#!/bin/sh\necho c\n' > src/c.sh
git add -A && git -c core.hooksPath=/dev/null commit -q -m consumer
install -m 755 "$ROOT/scripts/hooks/pre-commit-weave.sh" .git/hooks/pre-commit
# An untracked working-tree hook: the stale-copy hop used to run it.
printf '#!/usr/bin/env bash\necho "working-tree hook ran"\nexit 0\n' > scripts/hooks/pre-commit-weave.sh
reset_marks; touch "$MARK/fail"; printf '#!/bin/sh\necho c2\n' > src/c.sh; git add src/c.sh
OUT=$(./.git/hooks/pre-commit 2>&1); RC=$?
check "the installed copy gates a consumer commit itself" "1" "$RC"
check "...by running the routed suite" "1" "$(runs probe)"
hasnt "...and never runs a working-tree hook" "$OUT" "working-tree hook ran"
hasnt "...nor a committed-gate copy" "$OUT" "committed gate"

# wv-9da519 (rc.14 consumer audit K1): wv init-repo --update seeds the hook
# sources into a consumer's scripts/hooks/, and the consumer tracks them. HEAD
# then carried scripts/hooks/<hook>.sh, the hooks took the protected lane, and
# refused every commit and push because no scripts/wv sits beside the hook. The
# first commit after the upgrade passed (HEAD did not track them yet), so a
# one-commit canary missed it: this case commits twice and pushes.
echo "consumers: tracked hook sources without scripts/wv take the consumer lane"
V="$T/vendoring"; newrepo "$V"; cd "$V" || exit 1; consumer_env "$V"
git init -q --bare "$T/vendoring.git"; git remote add origin "$T/vendoring.git"
mkdir -p src tests .weave scripts/hooks
cp "$W/tests/test-probe.sh" tests/
printf '[map]\nsrc/ = tests/test-probe.sh\n' > .weave/test-map.conf
printf '#!/bin/sh\necho v\n' > src/v.sh
git add -A && git -c core.hooksPath=/dev/null commit -q -m consumer
install -m 755 "$ROOT/scripts/hooks/pre-commit-weave.sh" .git/hooks/pre-commit
install -m 755 "$ROOT/scripts/hooks/pre-push-weave.sh" .git/hooks/pre-push
install -m 755 "$ROOT/scripts/hooks/pre-commit-weave.sh" scripts/hooks/pre-commit-weave.sh
install -m 755 "$ROOT/scripts/hooks/pre-push-weave.sh" scripts/hooks/pre-push-weave.sh
reset_marks; printf '#!/bin/sh\necho v1\n' > src/v.sh; git add -A
OUT=$(git commit -q -m "vendor the hook sources" 2>&1); RC=$?
check "the commit that starts tracking the hook sources is admitted" "0" "$RC"
reset_marks; touch "$MARK/fail"; printf '#!/bin/sh\necho v2\n' > src/v.sh; git add src/v.sh
OUT=$(./.git/hooks/pre-commit 2>&1); RC=$?
check "the next commit is gated by the installed copy, which refuses a failing suite" "1" "$RC"
check "...because the suite ran" "1" "$(runs probe)"
hasnt "...not refused for a missing scripts/wv" "$OUT" "no scripts/wv beside its hook"
reset_marks; printf '#!/bin/sh\necho v3\n' > src/v.sh; git add src/v.sh
OUT=$(git commit -q -m "second commit after vendoring" 2>&1); RC=$?
check "a healthy second commit is admitted" "0" "$RC"
OUT=$(git push -q origin main 2>&1); RC=$?
check "the push after it is admitted" "0" "$RC"
hasnt "...and pre-push did not refuse for a missing scripts/wv" "$OUT" "no scripts/wv beside its hook"
# wv-376de3 (audit K3): a consumer whose installed libraries are missing was
# told to run ./install.sh, which exists only in Weave's own tree.
printf '#!/bin/sh\necho v4\n' > src/v.sh; git add src/v.sh
OUT=$(HOME="$T/no-install" ./.git/hooks/pre-commit 2>&1); RC=$?
check "a consumer with no installed libraries is refused" "1" "$RC"
has "...and told the consumer's refresh" "$OUT" "refresh with wv self-update, then wv init-repo --update"
hasnt "...not ./install.sh" "$OUT" "./install.sh"
git reset -q -- src/v.sh

# wv-ec7b2b (rc.15 consumer rollout): a hook installed before wv-9da519 built a
# lane from a HEAD that tracked the hook sources without scripts/wv and refused
# with a message naming neither cause nor remedy. The current dispatcher never
# builds that lane; the refusal is reached only from such a lane, so it is
# exercised here by hand: the hook run from a lane copy with no scripts/wv.
echo "a lane copy without scripts/wv says why and what to run"
LANE="$T/stale-lane"; mkdir -p "$LANE/tree/scripts/hooks"
printf '%s\n' "$(git rev-parse HEAD)" > "$LANE/weave-gate-lane"
install -m 755 "$ROOT/scripts/hooks/pre-commit-weave.sh" "$LANE/tree/scripts/hooks/pre-commit-weave.sh"
install -m 755 "$ROOT/scripts/hooks/pre-push-weave.sh" "$LANE/tree/scripts/hooks/pre-push-weave.sh"
printf '#!/bin/sh\necho v5\n' > src/v.sh; git add src/v.sh
OUT=$(bash "$LANE/tree/scripts/hooks/pre-commit-weave.sh" 2>&1); RC=$?
check "pre-commit from such a lane refuses" "1" "$RC"
has "...naming the missing scripts/wv" "$OUT" "no scripts/wv beside its hook"
has "...the cause" "$OUT" "installed hook predates the fix"
has "...and the remedy" "$OUT" "wv init-repo --update"
OUT=$(bash "$LANE/tree/scripts/hooks/pre-push-weave.sh" origin "$T/vendoring.git" </dev/null 2>&1); RC=$?
check "pre-push from such a lane refuses" "1" "$RC"
has "...with the same remedy" "$OUT" "wv init-repo --update"
git reset -q -- src/v.sh

echo
echo "protected dispatcher: $pass/$run passed"
[ "$pass" -eq "$run" ]
