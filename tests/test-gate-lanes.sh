#!/usr/bin/env bash
# Candidate lanes and the gate role contract (S2b, wv-7ee8fe, epic wv-d67163;
# boundary rules 1, 2 and 4, wv-ecf877).
#
# HEAD's protected gate (S2a) judges every commit. When the commit changes a
# gate file (an enforcement path in HEAD's scripts/hooks/gate-roles.json),
# that file also runs as written, in its own lane: HEAD's scripts/ with only
# that file staged. Every lane must admit. Pinned here, in a fixture whose HEAD
# carries this checkout's scripts/:
#   - a candidate gate that cannot admit its own commit is refused;
#   - D3 at the dispatcher layer: a new check and a weakened helper staged
#     together are refused, though one combined candidate lane admits them;
#   - D4: a check needing a helper changed in the same commit is refused until
#     the helper lands first;
#   - a lane reuses recorded suite results unless it changes the code that runs
#     suites, and records nothing itself; that code includes every library
#     loaded into the hook's shell, derived here from the hook (R3, wv-838349);
#   - HEAD's contract decides: deleting, narrowing or breaking it is refused,
#     and a dependency it does not declare, or cannot resolve, is refused;
#   - a new reference to gate code through REPO_ROOT, which is the working
#     tree rather than a lane's copy, is refused (R1, wv-23798e);
#   - a lane runs only the pre-commit hook, so a commit changing another
#     declared entry point is refused, never admitted as run (R2, wv-403fb5).
set -uo pipefail
export WV_TEST_SUITE=1
export WV_CALL_SOURCE=test
# Keep the inherited-budget scenario live in ordinary runs too; the one
# four-job case below must supply its own override (wv-6900e1).
export WV_GATE_JOBS=2

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }
has()   { if grep -qF -- "$3" <<< "$2"; then ok "$1"; else bad "$1" "missing [$3] in: $(tail -8 <<< "$2")"; fi; }
hasnt() { if grep -qF -- "$3" <<< "$2"; then bad "$1" "unexpected [$3]"; else ok "$1"; fi; }
hasre() { if grep -qE -- "$3" <<< "$2"; then ok "$1"; else bad "$1" "no line matching /$3/ in: $(tail -8 <<< "$2")"; fi; }

T=$(mktemp -d /tmp/wv-gate-lanes-XXXXXX)
trap 'rm -rf "$T"' EXIT
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
unset WV_GATE_BASE WV_GATE_TREE WV_GATE_PHASE WV_GATE_ID WV_GATE_CONTEXT WV_HOOK_REEXEC
unset PYTHONPATH

mkdir -p "$T/bin" "$T/cfg" "$T/marks"
ln -s "$ROOT/scripts/wv" "$T/bin/wv"
export PATH="$T/bin:$PATH" WV_LIB_DIR="$ROOT/scripts"
export WV_HOT_ZONE="$T" WV_DB="$T/brain.db" WV_CONFIG_DIR="$T/cfg" WV_PROJECT_DIR="$T/work"
export WV_SUITE_LOG="$T/suite_runs.jsonl" WV_GATE_LOG="$T/gate_runs.jsonl"
export WV_SCRATCH_ROOT="$T/scratch"
export WV_AUTO_SYNC=0 WV_AUTO_CHECKPOINT=0 WV_REQUIRE_LEARNING=0 WV_RUN_CACHE=0
MARK="$T/marks"; W="$T/work"

git init -q -b main "$W"; cd "$W" || exit 1
git config user.name "Gate Test"; git config user.email gate@example.com
git config commit.gpgsign false; git config tag.gpgSign false
_gl_skip=()
git -C "$ROOT" ls-files -z -- scripts "${_gl_skip[@]}" \
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
exit 0
PROBE_EOF
chmod +x tests/test-probe.sh
cat > .weave/test-map.conf <<'MAP_EOF'
[map]
src/a.sh = tests/test-probe.sh
scripts/ = tests/test-probe.sh
tests/test-probe.sh = tests/test-probe.sh
MAP_EOF
printf '#!/bin/sh\necho a\n' > src/a.sh
# A helper the fixture's checks use: strong at HEAD, it refuses a product
# carrying BUG in the frozen tree.
# The fixture copies modules with cross-file globals and local assignments.
# Declare its lint policy here: the source checkout's rc does not ship.
printf 'disable=SC2034,SC2155\n' > .shellcheckrc
cat > scripts/lib/wv-fixture-helper.sh <<'HELPER_EOF'
#!/usr/bin/env bash
fixture_src_ok() { ! git show "$WV_GATE_TREE:src/a.sh" 2>/dev/null | grep -q BUG; }
HELPER_EOF
git add -A && git -c core.hooksPath=/dev/null commit -q -m fixture
wv add "gate lanes fixture node" --status=active --force --criteria="c1|c2" --risks=low >/dev/null 2>&1
install -m 755 "$ROOT/scripts/hooks/pre-commit-weave.sh" .git/hooks/pre-commit

HOOK=scripts/hooks/pre-commit-weave.sh
HELPER=scripts/lib/wv-fixture-helper.sh
CONTRACT=scripts/hooks/gate-roles.json
gate() { OUT=$(./.git/hooks/pre-commit 2>&1); RC=$?; }
runs() { if [ -f "$MARK/$1" ]; then wc -l < "$MARK/$1" | tr -d ' '; else echo 0; fi; }
lines() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }
reset_all() { git reset -q; git checkout -q -- .; git clean -qfd -- scripts src; rm -f "$MARK/probe"; }
commit_nohook() { git add -A && git -c core.hooksPath=/dev/null commit -q -m "$1"; }
# Fresh bytes each time: the pool reuses a green result for content it has seen.
n=0
fresh() { n=$((n+1)); printf '# fixture edit %s\n' "$n" >> "$1"; git add "$1"; }
stage_src() { n=$((n+1)); printf '#!/bin/sh\necho a-%s\n' "$n" > src/a.sh; git add src/a.sh; }
# into_hook <file> — insert <file>'s lines into the staged hook, where every
# lane runs them: after the frozen candidate and the role contract, before
# admission.
into_hook() {
    awk -v f="$1" '/^# _pc_git_pid — the git process/ { while ((getline l < f) > 0) print l } { print }' \
        "$HOOK" > "$T/hook.new" && cat "$T/hook.new" > "$HOOK" && git add "$HOOK"
}
# combined — one lane holding every staged gate file at once: the weaker
# check the review declined (prototype "one collective lane").
combined() {
    rm -rf "${T:?}/comb"; mkdir -p "$T/comb/tree"
    git checkout-index -a -f --prefix="$T/comb/tree/" 2>/dev/null
    find "$T/comb/tree" -mindepth 1 -maxdepth 1 ! -name scripts -exec rm -rf {} +
    git rev-parse HEAD > "$T/comb/weave-gate-lane"
    printf 'path=*\ntree=%s\nreuse=0\n' "$(git write-tree)" > "$T/comb/weave-gate-candidate"
    OUT=$(env -u WV_LIB_DIR -u WV_CLI bash "$T/comb/tree/$HOOK" 2>&1); RC=$?
}

echo "readable changed paths do not depend on process-substitution wait bookkeeping"
_gl_unusual=$'scripts/lib/fixture\npath.sh'
printf '# fixture\n' > "$_gl_unusual"; git add "$_gl_unusual"
printf '%s\0' "$_gl_unusual" > "$T/expected-paths"
_gl_wait_rc=$(
    source "$ROOT/scripts/lib/wv-gate-snapshot.sh"
    source "$ROOT/scripts/lib/wv-gate-lanes.sh"
    gate_freeze || exit 8
    _GATE_ROLES_JSON=$(gate_show auth "$CONTRACT") || exit 8
    # Bash can lose an already completed producer's status. Do not turn
    # successful synchronous acquisition into unknown history (wv-5a776d).
    wait() { return 127; }
    rc=0; gate_lanes_changed > "$T/actual-paths" || rc=$?
    printf '%s\n' "$rc"
    rc=0; gate_entry_points_preflight >/dev/null || rc=$?
    printf '%s\n' "$rc"
)
check "changed paths and preflight succeed despite unavailable wait bookkeeping" $'0\n0' "$_gl_wait_rc"
cmp -s "$T/expected-paths" "$T/actual-paths"
check "...preserving the complete newline-containing enforcement path" "0" "$?"
_gl_partial_rc=$(
    source "$ROOT/scripts/lib/wv-gate-snapshot.sh"
    source "$ROOT/scripts/lib/wv-gate-lanes.sh"
    gate_freeze || exit 8
    _GATE_ROLES_JSON=$(gate_show auth "$CONTRACT") || exit 8
    git() {
        command git "$@" || return
        if [ "${1:-}" = diff-tree ]; then
            printf 'called\n' > "$T/failed-path-producer"
            return 73
        fi
    }
    rc=0; gate_entry_points_preflight > "$T/partial-paths" 2>/dev/null || rc=$?
    printf '%s\n' "$rc"
)
check "a real changed-path producer failure refuses preflight after valid output" "1" "$_gl_partial_rc"
check "...at the intended producer" "called" "$(cat "$T/failed-path-producer")"
check "...without publishing partial path output" "0" "$(wc -c < "$T/partial-paths" | tr -d ' ')"
git reset -q; rm -f "$_gl_unusual"

echo "control: no gate file changed, no lane"
reset_all; stage_src; gate
check "(control) a product commit is admitted" "0" "$RC"
# What refused it, if anything: a lane run of this suite once failed here with
# nothing to show why (wv-c909ff landing).
[ "$RC" = 0 ] || printf '%s\n' "$OUT" | tail -25 | sed 's/^/      | /'
hasnt "...and runs no candidate lane" "$OUT" "candidate lanes"
check "...after the routed suite ran once" "1" "$(runs probe)"

echo "a changed gate file runs as written, in its own lane"
reset_all; fresh scripts/lib/wv-cache.sh
_gl_suites=$(lines "$WV_SUITE_LOG"); _gl_gates=$(lines "$WV_GATE_LOG")
gate
check "a harmless edit to a gate file is admitted" "0" "$RC"
has "...after its lane admitted it" "$OUT" "candidate lanes: 1 of 1 admitted"
hasnt "...claiming no run it cannot show (R2)" "$OUT" "as written in"
hasre "...timing that lane on its own, as reusing" "$OUT" "candidate lane scripts/lib/wv-cache\.sh: reused HEAD's suite results with up to [0-9]+ suite job\(s\) in [0-9]+ms$"
check "...reusing the suite the protected lane just ran" "1" "$(runs probe)"
check "...with one suite ledger row, the protected lane's" "$((_gl_suites + 1))" "$(lines "$WV_SUITE_LOG")"
check "...and one gate record" "$((_gl_gates + 1))" "$(lines "$WV_GATE_LOG")"

reset_all; fresh scripts/lib/wv-gate-pool.sh
_gl_suites=$(lines "$WV_SUITE_LOG")
gate
check "an edit to the code that runs suites is admitted" "0" "$RC"
check "...and its lane runs the suite again, reusing nothing" "2" "$(runs probe)"
hasre "...timing that lane on its own, as a rerun" "$OUT" "candidate lane scripts/lib/wv-gate-pool\.sh: reran its suites with up to [0-9]+ suite job\(s\) in [0-9]+ms$"
check "...while recording only the protected lane's row" "$((_gl_suites + 1))" "$(lines "$WV_SUITE_LOG")"

echo "R3 (wv-838349): every library loaded into the hook's shell reruns its suites"
# Derived, not listed: the hook, followed through what each library it loads
# sources (or names in an assignment it then sources). The suites inherit that
# shell's environment, so each of these decides how suites run.
_gl_shell_libs=$(python3 -I - "$ROOT" <<'PY_EOF'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
lit = re.compile(r'"[^"\n]*/(wv-[A-Za-z0-9.-]+\.sh)"')
loads = re.compile(r'(^|[\s;&|(!])(source|\.)\s+"|^\s*[A-Za-z_][A-Za-z0-9_]*=')
todo, seen = ["scripts/hooks/pre-commit-weave.sh"], set()
while todo:
    rel = todo.pop()
    if rel in seen:
        continue
    seen.add(rel)
    for line in (root / rel).read_text(encoding="utf-8").splitlines():
        code = "" if line.lstrip().startswith("#") else line.split(" #", 1)[0]
        if loads.search(code):
            todo += [f"scripts/lib/{n}" for n in lit.findall(code) if (root / "scripts/lib" / n).is_file()]
print("\n".join(sorted(seen)))
PY_EOF
)
check "(control) the derivation finds the hook's own libraries" "1" \
    "$(grep -cx 'scripts/lib/wv-gate-pool.sh' <<< "$_gl_shell_libs")"
_gl_missing=$(grep -vxF -f <(jq -r '.invoking[]' "$ROOT/$CONTRACT") <<< "$_gl_shell_libs")
check "every library the hook's shell loads is invoking in the contract" "" "$_gl_missing"
_gl_hooks=$(cd "$ROOT" && ls scripts/hooks/*-weave.sh)
_gl_undeclared=$(grep -vxF -f <(jq -r '.entry_points | keys[]' "$ROOT/$CONTRACT") <<< "$_gl_hooks")
check "every hook under scripts/hooks/ is a declared entry point" "" "$_gl_undeclared"

reset_all
cat > tests/test-probe.sh <<PROBE_EOF
#!/bin/sh
echo run >> "$MARK/probe"
[ -z "\${FIXTURE_BREAK:-}" ] || { echo "probe: the hook's shell exported FIXTURE_BREAK" >&2; exit 1; }
exit 0
PROBE_EOF
commit_nohook "probe refuses an inherited FIXTURE_BREAK"
printf '\nexport FIXTURE_BREAK=1\n' >> scripts/lib/wv-config.sh; git add scripts/lib/wv-config.sh
gate
check "a hook-shell library that breaks the suites' environment is refused" "1" "$RC"
check "...because its lane reran the suite rather than reusing HEAD's result" "2" "$(runs probe)"
has "...in that library's lane" "$OUT" "the candidate version of scripts/lib/wv-config.sh does not admit"
git reset -q --hard HEAD~1; rm -f "$MARK/probe"

# The router is not invoking: suite selection runs fresh in every lane, from
# the lane's copy; only suite results are reused, keyed by suite and inputs.
reset_all
cat > tests/test-fail.sh <<'FAIL_EOF'
#!/bin/sh
exit 1
FAIL_EOF
chmod +x tests/test-fail.sh
commit_nohook "an unrouted failing suite"
_gl_router() {
    awk -v l="$1" '/^_impact_suites_for_files\(\) \{/ { print; print l; next } { print }' \
        scripts/cmd/wv-cmd-graph.sh > "$T/g.new" && cat "$T/g.new" > scripts/cmd/wv-cmd-graph.sh
    git add scripts/cmd/wv-cmd-graph.sh
}
_gl_router '    return 1'
gate
check "a router lane runs its router as written: a failing router is refused" "1" "$RC"
has "...in the router's lane" "$OUT" "the candidate version of scripts/cmd/wv-cmd-graph.sh does not admit"
reset_all
# shellcheck disable=SC2016  # the router's text, not this suite's expansion
_gl_router '    [ "${1:-}" = "--routes" ] || { echo '"'"'[{"name":"tests/test-fail.sh","last_cost_s":0,"tier":"light","declared":true}]'"'"'; return 0; }'
gate
check "...and a suite only the candidate router selects runs in its lane" "1" "$RC"
git reset -q --hard HEAD~1; rm -f "$MARK/probe"

reset_all; fresh scripts/lib/wv-cache.sh; fresh scripts/lib/wv-journal.sh; fresh scripts/lib/wv-resolve-project.sh
# This case exercises a four-job fixture, independently of its outer pool's
# budget; inheriting two jobs makes the sum below three, not four (wv-6900e1).
WV_GATE_JOBS=4 gate
check "three changed gate files are admitted" "0" "$RC"
has "...each in its own lane" "$OUT" "candidate lanes: 3 of 3 admitted"
check "...each timed on its own line" "3" "$(grep -cE "candidate lane scripts/lib/[a-z-]+\.sh: reused HEAD's suite results with up to [0-9]+ suite job\(s\) in [0-9]+ms$" <<< "$OUT")"
# The lanes split the fixture's pool bound rather than each taking it all
# (wv-d7af8d): three lanes run together, so their shares sum to 4.
check "...sharing the bound: three lanes hold 4 suite jobs between them" "4" \
    "$(grep -oE "candidate lane scripts/lib/[a-z-]+\.sh: reused HEAD's suite results with up to [0-9]+" <<< "$OUT" | grep -oE '[0-9]+$' | awk '{ s += $1 } END { print s }')"

echo "a candidate gate that cannot admit its own commit is refused"
reset_all
printf '%s\n' 'echo "✗ fixture: the candidate gate refuses" >&2; exit 1' > "$T/snip"
into_hook "$T/snip"
gate
check "a hook that refuses every commit is refused" "1" "$RC"
has "...in its lane" "$OUT" "the candidate version of $HOOK does not admit this commit"
has "...showing why" "$OUT" "fixture: the candidate gate refuses"

reset_all; git rm -q scripts/lib/wv-gate-pool.sh
gate
check "deleting a library the gate needs is refused" "1" "$RC"
has "...before a lane, requiring explicit retirement" "$OUT" "deleting enforcement scripts/lib/wv-gate-pool.sh needs a prior exact retirement record"

reset_all; git rm -q "$HOOK"
gate
check "deleting the gate's hook is refused" "1" "$RC"
has "...as a retirement, which needs a record" "$OUT" "deletes the gate's hook"

echo "D3: a new check and a weakened helper, staged together"
reset_all
cat > "$T/snip" <<'SNIP_EOF'
. "$_PC_SCRIPTS/lib/wv-fixture-helper.sh"
if ! fixture_src_ok; then echo "✗ fixture: src/a.sh carries BUG" >&2; exit 1; fi
SNIP_EOF
into_hook "$T/snip"
printf '#!/usr/bin/env bash\nfixture_src_ok() { return 0; }\n' > "$HELPER"; git add "$HELPER"
printf '#!/bin/sh\necho BUG\n' > src/a.sh; git add src/a.sh
combined
check "(control) one combined candidate lane admits the defect" "0" "$RC"
gate
check "per-file lanes refuse it" "1" "$RC"
has "...in the new check's lane, against HEAD's helper" "$OUT" "fixture: src/a.sh carries BUG"

echo "D4: a check needing a helper changed in the same commit"
reset_all
# shellcheck disable=SC2016  # the hook's text, not this suite's expansion
printf '%s\n' '. "$_PC_SCRIPTS/lib/wv-fixture-helper.sh"' 'fixture_new_check || exit 1' > "$T/snip"
into_hook "$T/snip"
printf 'fixture_new_check() { return 0; }\n' >> "$HELPER"; git add "$HELPER"
gate
check "is refused while the helper is staged with it" "1" "$RC"
has "...telling the author to land the helper first" "$OUT" "land that file first"
git reset -q -- "$HOOK"; git checkout -q -- "$HOOK"
gate
check "the helper alone is admitted" "0" "$RC"
commit_nohook "helper first"
into_hook "$T/snip"
gate
check "then the check that needs it is admitted" "0" "$RC"
git reset -q --hard HEAD~1; rm -f "$MARK/probe"

echo "R1 (wv-23798e): gate code named through REPO_ROOT is the working tree, not a lane's copy"
reset_all
# shellcheck disable=SC2016  # the hook's text, not this suite's expansion
printf '%s\n' '. "$REPO_ROOT/scripts/lib/wv-fixture-helper.sh"' \
    'if ! fixture_src_ok; then echo "✗ fixture: src/a.sh carries BUG" >&2; exit 1; fi' > "$T/snip"
into_hook "$T/snip"
printf '#!/usr/bin/env bash\nfixture_src_ok() { return 0; }\n' > "$HELPER"; git add "$HELPER"
printf '#!/bin/sh\necho BUG\n' > src/a.sh; git add src/a.sh
gate
check "a new check loading a weakened helper through REPO_ROOT is refused" "1" "$RC"
has "...as a new working-tree reference to gate code" "$OUT" "names scripts/lib/wv-fixture-helper.sh through REPO_ROOT"
reset_all
# shellcheck disable=SC2016
printf '%s\n' '. "$REPO_ROOT/scripts/lib"/wv-fixture-helper.sh' > "$T/snip"
into_hook "$T/snip"
gate
check "...and through a directory prefix" "1" "$RC"
has "...naming the prefix" "$OUT" "names scripts/lib through REPO_ROOT"
reset_all
# shellcheck disable=SC2016
printf '%s\n' '. "$REPO_ROOT"/scripts/lib/wv-fixture-helper.sh' > "$T/snip"
into_hook "$T/snip"
gate
check "...and with the variable quoted apart from the path" "1" "$RC"
has "...naming the helper" "$OUT" "names scripts/lib/wv-fixture-helper.sh through REPO_ROOT"
reset_all; fresh "$HOOK"
gate
check "(control) a changed hook naming gate code beside itself is admitted" "0" "$RC"
[ "$RC" = 0 ] || tail -15 <<< "$OUT" | sed 's/^/      | /'

echo "N1 (wv-c424ed): a HEAD fallback cannot be spent on an active load"
# HEAD carries an inert REPO_ROOT fallback, on a path no lane takes, as the
# hook's consumer branch did. The review moved it onto the lane's path and
# kept the count.
reset_all
# shellcheck disable=SC2016
printf '%s\n' 'if false; then _gl_fallback="$REPO_ROOT/scripts/lib"; fi' > "$T/snip"
into_hook "$T/snip"; commit_nohook "inert fallback"
_gl_n1_base=$(git rev-parse HEAD)
# shellcheck disable=SC2016
printf '%s\n' '. "$REPO_ROOT/scripts/lib"/wv-fixture-helper.sh' \
    'if ! fixture_src_ok; then echo "✗ fixture: src/a.sh carries BUG" >&2; exit 1; fi' > "$T/snip"
into_hook "$T/snip"
# shellcheck disable=SC2016
sed 's|_gl_fallback="$REPO_ROOT/scripts/lib"|_gl_fallback="$HOME/unused-fixture-lib"|' "$HOOK" > "$T/hook.new" \
    && cat "$T/hook.new" > "$HOOK" && git add "$HOOK"
check "(precondition) the fallback is gone from the staged hook" "0" \
    "$(git show ":$HOOK" | grep -c '_gl_fallback="\$REPO_ROOT')"
printf '#!/usr/bin/env bash\nfixture_src_ok() { return 0; }\n' > "$HELPER"; git add "$HELPER"
printf '#!/bin/sh\necho BUG\n' > src/a.sh; git add src/a.sh
gate
check "the review's substitution is refused" "1" "$RC"
has "...as a working-tree reference in a changed file" "$OUT" "A file this commit changes may name no gate code that way"
hasnt "...before any lane admits it" "$OUT" "2 of 2 admitted"
reset_all; fresh scripts/lib/wv-cache.sh
gate
check "(control) a commit leaving the file with HEAD's fallback alone is admitted" "0" "$RC"
reset_all; git reset -q --hard "$_gl_n1_base~1"; rm -f "$MARK/probe"

echo "R2 (wv-403fb5): a changed entry point other than pre-commit is refused"
for _gl_ev in pre-push prepare-commit-msg reference-transaction; do
    reset_all; fresh "scripts/hooks/$_gl_ev-weave.sh"
    gate
    check "a changed $_gl_ev hook is refused" "1" "$RC"
    has "...since no lane can run it" "$OUT" "changes the $_gl_ev hook (scripts/hooks/$_gl_ev-weave.sh)"
done
reset_all
sed '1a exit 1' scripts/hooks/pre-push-weave.sh > "$T/pp" && cat "$T/pp" > scripts/hooks/pre-push-weave.sh
git add scripts/hooks/pre-push-weave.sh
gate
check "the review's pre-push hook that exits at once is refused" "1" "$RC"
hasnt "...and not reported as an admitted lane" "$OUT" "1 of 1 admitted"
reset_all
jq 'del(.entry_points["scripts/hooks/pre-push-weave.sh"])' "$CONTRACT" > "$T/c.json" && cat "$T/c.json" > "$CONTRACT"
git add "$CONTRACT"
gate
check "dropping an entry point from the contract is refused" "1" "$RC"
has "...naming it" "$OUT" "drops scripts/hooks/pre-push-weave.sh"

echo "N2 (wv-3b601f): an entry point's event is part of its role"
reset_all
jq '.entry_points["scripts/hooks/pre-push-weave.sh"] = "pre-commit"' "$CONTRACT" > "$T/c.json" \
    && cat "$T/c.json" > "$CONTRACT"; git add "$CONTRACT"
gate
check "relabelling pre-push as pre-commit is refused" "1" "$RC"
has "...since only the hook a lane runs serves pre-commit" "$OUT" "staged gate role contract ($CONTRACT) is not valid"
# The review's second step, against a HEAD that already accepted the relabel.
commit_nohook "relabelled pre-push"
sed '1a exit 1' scripts/hooks/pre-push-weave.sh > "$T/pp" && cat "$T/pp" > scripts/hooks/pre-push-weave.sh
git add scripts/hooks/pre-push-weave.sh
gate
check "...and a HEAD carrying the relabel admits no broken pre-push" "1" "$RC"
hasnt "...as an admitted lane" "$OUT" "1 of 1 admitted"
reset_all; git reset -q --hard HEAD~1
jq '.entry_points["scripts/hooks/pre-push-weave.sh"] = "post-commit"' "$CONTRACT" > "$T/c.json" \
    && cat "$T/c.json" > "$CONTRACT"; git add "$CONTRACT"
gate
check "changing an entry point to another event is refused" "1" "$RC"
has "...naming both events" "$OUT" "changes the event of scripts/hooks/pre-push-weave.sh from pre-push to post-commit"
reset_all
jq '.entry_points["scripts/hooks/pre-push-weave.sh"] = "pre-psuh"' "$CONTRACT" > "$T/c.json" \
    && cat "$T/c.json" > "$CONTRACT"; git add "$CONTRACT"
gate
check "an event git does not have is refused" "1" "$RC"
has "...as an invalid contract" "$OUT" "staged gate role contract ($CONTRACT) is not valid"
reset_all
printf '#!/bin/sh\nexit 1\n' > scripts/hooks/commit-msg-weave.sh; chmod +x scripts/hooks/commit-msg-weave.sh
jq '.entry_points["scripts/hooks/commit-msg-weave.sh"] = "commit-msg"' "$CONTRACT" > "$T/c.json" \
    && cat "$T/c.json" > "$CONTRACT"; git add "$CONTRACT" scripts/hooks/commit-msg-weave.sh
gate
check "a new hook the commit declares for another event is refused" "1" "$RC"
has "...since no lane runs it" "$OUT" "changes the commit-msg hook (scripts/hooks/commit-msg-weave.sh)"

echo "S2c (wv-9a805a): a repair record committed first admits one exact entry-point change"
reset_all
RT=scripts/hooks/reference-transaction-weave.sh
_gl_s2c_head=$(git rev-parse HEAD)
# record <name> <path> <baseline> <replacement> [jq filter]
record() {
    local bm rm
    mkdir -p .weave/gate-repairs
    bm=$(git ls-tree HEAD -- "$2" | cut -d' ' -f1)
    rm=$(git ls-files --stage -- "$2" | cut -d' ' -f1)
    jq -n --arg p "$2" --arg o "$3" --arg n "$4" --arg bm "$bm" --arg rm "$rm" \
        '{version: 2, kind: "repair", path: $p, baseline: $o, replacement: $n,
          baseline_mode: $bm, replacement_mode: $rm,
          reason: "fixture repair", verification: "fixture suite"}' | jq "${5:-.}" \
        > ".weave/gate-repairs/$1.json"
}
commit_record() { git add .weave/gate-repairs && git -c core.hooksPath=/dev/null commit -q -m "record $1" -- .weave/gate-repairs; }
_gl_rt_a=$(git rev-parse "HEAD:$RT")
printf '# repaired\n' >> "$RT"; _gl_rt_b=$(git hash-object "$RT"); git add "$RT"
gate
check "(control) without a record the change is refused" "1" "$RC"
has "...printing the record that would admit it" "$OUT" "\"replacement\": \"$_gl_rt_b\""
# wv-c909ff: the verdict depends only on the staged paths and HEAD's records,
# so it comes before the protected pass: the routed probe never runs.
check "...before any routed suite runs" "0" "$(runs probe)"
record rt "$RT" "$_gl_rt_a" "$_gl_rt_b"; git add .weave/gate-repairs
gate
check "a record staged in the same commit admits nothing" "1" "$RC"
check "...refused before any routed suite runs" "0" "$(runs probe)"
git reset -q -- .weave/gate-repairs
record rt "$RT" "$_gl_rt_a" "$_gl_rt_a"; commit_record rt
record rt "$RT" "$_gl_rt_a" "$_gl_rt_b"; git add .weave/gate-repairs "$RT"
gate
check "a record at HEAD edited in the same commit to name these bytes admits nothing" "1" "$RC"
check "...refused before any routed suite runs" "0" "$(runs probe)"
git reset -q -- .weave/gate-repairs "$RT"; commit_record rt; git add "$RT"
gate
check "a record committed first admits that exact change" "0" "$RC"
has "...saying the hook was not run" "$OUT" "$RT is not run; this change to the reference-transaction hook is admitted by the repair record .weave/gate-repairs/rt.json"
has "...and that a record is not approval" "$OUT" "traceability, not approval"
hasnt "...building no lane for it" "$OUT" "candidate lanes:"
check "...after the protected pass ran its routed suite (the preflight admits nothing)" "1" "$(runs probe)"
check "...saying so once: the preflight decides the same way but reports nothing" "1" \
    "$(grep -c 'is not run; this change to the reference-transaction hook' <<< "$OUT")"
printf '# and more\n' >> "$RT"; git add "$RT"; rm -f "$MARK/probe"
gate
check "...but not other bytes" "1" "$RC"
check "...refused before any routed suite runs" "0" "$(runs probe)"
git checkout -q HEAD -- "$RT"; printf '# repaired\n' >> "$RT"; git add "$RT"
_gl_rec=$(git rev-parse HEAD)
git -c core.hooksPath=/dev/null commit -q -m "A to B" -- "$RT"
_gl_consuming_tree=$(git rev-parse HEAD:scripts)
# Distinguish the historical subtree from the later staged B subtree; hiding
# a shared tree would merely make the staged candidate unreadable too.
printf 'later context\n' > scripts/history-marker.txt
git add scripts/history-marker.txt
git -c core.hooksPath=/dev/null commit -q -m "later context" -- scripts/history-marker.txt
git show "$_gl_rec:$RT" > "$RT"; git -c core.hooksPath=/dev/null commit -q -m "B to A" -- "$RT"
printf '# repaired\n' >> "$RT"; git add "$RT"; rm -f "$MARK/probe"
gate
check "a record is consumed once its transition lands, even after A-B-A" "1" "$RC"
has "...asking for a new record" "$OUT" "To land this exact change, commit a repair record"
check "...refused before any routed suite runs" "0" "$(runs probe)"
# Follow-up review F1 (wv-a18f1e): the same history, truncated. A depth-1 clone
# holds the record as if added at its root, so the transitions that consumed
# it are not there to see. Driven through the resolver the gate calls, since a
# clone is another repository with no graph of its own here.
resolve_record() { # resolve_record <repo> <path> — gate_repair_record's status there
    ( cd "$1" || exit 9
      # shellcheck source=scripts/lib/wv-gate-snapshot.sh
      source "$ROOT/scripts/lib/wv-gate-snapshot.sh"
      # shellcheck source=scripts/lib/wv-gate-lanes.sh
      source "$ROOT/scripts/lib/wv-gate-lanes.sh"
      gate_freeze || exit 8
      gate_repair_record "$2" "${3:-repair}" >/dev/null 2>&1; echo $? )
}
check "(control) the resolver finds the record consumed in full history" "1" "$(resolve_record "$W" "$RT")"
# Only the disposable fixture's consuming subtree is hidden. HEAD and its
# installed gate remain readable; absence of an old subtree is not absence
# of the hook at that commit (wv-5df974).
_gl_object=".git/objects/${_gl_consuming_tree:0:2}/${_gl_consuming_tree:2}"
mv "$_gl_object" "$T/consuming-tree"
check "unreadable consumption history cannot revive a repair record" "2" "$(resolve_record "$W" "$RT")"
rm -f "$MARK/probe"
gate
check "the hook refuses unreadable consumption history" "1" "$RC"
has "...naming the unreadable repair history" "$OUT" "could not read the repair records"
check "...before any routed suite runs" "0" "$(runs probe)"
mv "$T/consuming-tree" "$_gl_object"
check "(control) restored history still reports the record consumed" "1" "$(resolve_record "$W" "$RT")"
git clone -q --depth 1 "file://$W" "$T/shallow"
printf '# repaired\n' >> "$T/shallow/$RT"; git -C "$T/shallow" add "$RT"
check "(precondition) the clone is shallow and holds the record" "true .weave/gate-repairs/rt.json" \
    "$(git -C "$T/shallow" rev-parse --is-shallow-repository) $(git -C "$T/shallow" ls-files .weave/gate-repairs)"
check "in a shallow clone the record's use cannot be established, so it admits nothing" "3" \
    "$(resolve_record "$T/shallow" "$RT")"
# The preflight the hook runs before any suite (wv-c909ff) reaches that
# verdict through the same resolver and refuses on it.
_gl_pre=$( cd "$T/shallow" || exit 9
    # shellcheck source=scripts/lib/wv-gate-snapshot.sh
    source "$ROOT/scripts/lib/wv-gate-snapshot.sh"
    # shellcheck source=scripts/lib/wv-gate-lanes.sh
    source "$ROOT/scripts/lib/wv-gate-lanes.sh"
    gate_freeze || exit 8
    gate_roles_check || exit 7
    gate_entry_points_preflight 2>&1; echo "rc=$?" )
has "...and the preflight refuses there, before any suite" "$_gl_pre" "history is shallow or partial"
hasre "...with a refusing status" "$_gl_pre" "^rc=1$"
git config uploadpack.allowFilter true
git clone -q --filter=blob:none "file://$W" "$T/partial" 2>/dev/null
printf '# repaired\n' >> "$T/partial/$RT"; git -C "$T/partial" add "$RT"
check "(precondition) the other clone is partial" "yes" \
    "$(git -C "$T/partial" config --get-regexp '^(extensions\.partialclone|remote\..*\.promisor)$' >/dev/null && echo yes)"
check "...nor in a partial clone, whose missing blobs read as absent paths" "3" \
    "$(resolve_record "$T/partial" "$RT")"
git reset -q --hard "$_gl_rec"
printf '# repaired\n' >> "$RT"; git add "$RT"
check "(control) a record nothing has used admits in full history" "0" "$(resolve_record "$W" "$RT")"
git reset -q --hard "$_gl_rec"
git rm -q "$RT"; git -c core.hooksPath=/dev/null commit -q -m "temporarily absent hook"
git show "$_gl_rec:$RT" > "$RT"; chmod +x "$RT"
git add "$RT"; git -c core.hooksPath=/dev/null commit -q -m "restore unused baseline"
printf '# repaired\n' >> "$RT"; git add "$RT"
check "an absent historical path does not make an unused record unreadable" "0" "$(resolve_record "$W" "$RT")"
git reset -q --hard "$_gl_rec"
git checkout -q -b side
printf '# repaired\n' >> "$RT"; git -c core.hooksPath=/dev/null commit -q -m "side: A to B" -- "$RT"
git checkout -q main; git -c core.hooksPath=/dev/null merge -q -s ours side -m "merge side, keeping A"
printf '# repaired\n' >> "$RT"; git add "$RT"; rm -f "$MARK/probe"
gate
check "...and when it landed on a branch merged back, keeping the baseline" "1" "$RC"
has "...asking for a new record" "$OUT" "To land this exact change, commit a repair record"
check "...refused before any routed suite runs" "0" "$(runs probe)"
git reset -q --hard "$_gl_rec"; git branch -q -D side
git rm -q --cached .weave/gate-repairs/rt.json
record rt "$RT" "$_gl_rt_a" "$_gl_rt_b" 'del(.verification)'
git add .weave/gate-repairs; git -c core.hooksPath=/dev/null commit -q -m "invalid record" -- .weave/gate-repairs
printf '# repaired\n' >> "$RT"; git add "$RT"; rm -f "$MARK/probe"
gate
check "a record without its verification admits nothing" "1" "$RC"
check "...refused before any routed suite runs" "0" "$(runs probe)"
git reset -q --hard "$_gl_s2c_head"; rm -rf .weave/gate-repairs

echo "repair v2 binds modes as well as blobs (wv-7205b0)"
# Equal blobs do not mean equal transitions: this record permits 755 -> 644,
# not an unchanged file in an unrelated commit.
_gl_mode_blob=$(git rev-parse "HEAD:$RT")
record mode "$RT" "$_gl_mode_blob" "$_gl_mode_blob" '.replacement_mode = "100644"'
commit_record mode
chmod -x "$RT"; git add "$RT"
check "(control) an unused mode-only record admits its exact transition" "0" "$(resolve_record "$W" "$RT")"
printf 'unrelated\n' > src/context.txt; git add src/context.txt
git -c core.hooksPath=/dev/null commit -q -m "unrelated context" -- src/context.txt
check "an unrelated same-blob commit does not consume a mode-only record" "0" "$(resolve_record "$W" "$RT")"
gate
check "the hook admits the still-unused mode-only record" "0" "$RC"
git -c core.hooksPath=/dev/null commit -q -m "mode A to B" -- "$RT"
_gl_mode_consumer=$(git rev-parse HEAD)
chmod +x "$RT"; git add "$RT"
git -c core.hooksPath=/dev/null commit -q -m "mode B to A" -- "$RT"
chmod -x "$RT"; git add "$RT"; rm -f "$MARK/probe"
gate
check "a mode-only A-B-A transition cannot reuse its record" "1" "$RC"
check "...refused before routed suites" "0" "$(runs probe)"
# Exercise the hook's mode-read error path without removing readable blobs.
# gate invokes the installed hook directly, so this private PATH wrapper is
# reachable; its marker proves the intended fault was actually injected.
_gl_real_git=$(command -v git)
cat > "$T/bin/git" <<MODE_GIT_EOF
#!/usr/bin/env bash
if [ "\$*" = "--no-replace-objects --literal-pathspecs ls-tree --full-tree $_gl_mode_consumer -- $RT" ]; then
    echo reached > "$MARK/mode-read-fault"
    exit 128
fi
exec "$_gl_real_git" "\$@"
MODE_GIT_EOF
chmod +x "$T/bin/git"
gate
rm -f "$T/bin/git"
check "(precondition) the historical mode read failed at the intended call" "reached" "$(cat "$MARK/mode-read-fault" 2>/dev/null)"
check "a failed mode read cannot revive a consumed record" "1" "$RC"
has "...reported as unreadable history" "$OUT" "could not read the repair records"
git reset -q --hard "$_gl_s2c_head"; rm -rf .weave/gate-repairs

printf '# mode-bound repair\n' >> "$RT"; git add "$RT"
record modes "$RT" "$_gl_mode_blob" "$(git hash-object "$RT")"
commit_record modes
check "(control) a content repair admits at its recorded mode" "0" "$(resolve_record "$W" "$RT")"
chmod -x "$RT"; git add "$RT"; rm -f "$MARK/probe"
gate
check "the same repair bytes at an unrecorded replacement mode are refused" "1" "$RC"
check "...refused before routed suites" "0" "$(runs probe)"
chmod +x "$RT"; git add "$RT"
# Existing v1 records stay in history, but cannot silently acquire inferred
# modes. A new, previously committed v2 record is required for admission.
jq '.version = 1 | del(.baseline_mode, .replacement_mode)' .weave/gate-repairs/modes.json > "$T/v1.json"
mv "$T/v1.json" .weave/gate-repairs/modes.json
commit_record v1
gate
check "a mode-less v1 repair record cannot authorize a future transition" "1" "$RC"
has "...printing a version-2 template" "$OUT" '"version": 2'
git reset -q --hard "$_gl_s2c_head"; rm -rf .weave/gate-repairs

PP=scripts/hooks/pre-push-weave.sh
_gl_pp_a=$(git rev-parse "HEAD:$PP")
printf '# repaired\n' >> "$PP"
record pp "$PP" "$_gl_pp_a" "$(git hash-object "$PP")"
commit_record pp; git add "$PP"
gate
check "(control) a recorded pre-push change naming no gate code through REPO_ROOT is admitted" "0" "$RC"
reset_all; git reset -q --hard "$_gl_s2c_head"; rm -rf .weave/gate-repairs
# A record does not excuse a working-tree reference: plant one, and check it
# is there, since the hook itself no longer carries any.
# shellcheck disable=SC2016  # the hook's text, not this suite's expansion
printf '%s\n' '_gl_planted="$REPO_ROOT/scripts/lib"' >> "$PP"
check "(precondition) the staged pre-push names gate code through REPO_ROOT" "1" \
    "$(grep -cF '"$REPO_ROOT/scripts/lib"' "$PP")"
record pp "$PP" "$_gl_pp_a" "$(git hash-object "$PP")"
commit_record pp; git add "$PP"
gate
check "a recorded change adding a REPO_ROOT gate reference is still refused" "1" "$RC"
has "...for that reference" "$OUT" "$PP names scripts/lib through REPO_ROOT"
reset_all; git reset -q --hard "$_gl_s2c_head"; rm -rf .weave/gate-repairs

echo "shared roles require exact records without replacing the candidate verdict"
_gl_record_start=$(git rev-parse HEAD)
reset_all
jq '.shared = ["src/a.sh"]' "$CONTRACT" > "$T/c.json"; cat "$T/c.json" > "$CONTRACT"; git add "$CONTRACT"
gate
check "a shared role outside enforcement is refused" "1" "$RC"
has "...rather than silently omitted" "$OUT" "shared path src/a.sh is not declared enforcement"
reset_all
jq '.shared = ["scripts/lib/no-shared-file.sh"]' "$CONTRACT" > "$T/c.json"; cat "$T/c.json" > "$CONTRACT"; git add "$CONTRACT"
gate
check "a missing shared file is refused" "1" "$RC"
has "...naming the missing shared file" "$OUT" "shared path scripts/lib/no-shared-file.sh is missing"
reset_all
jq '.shared = false' "$CONTRACT" > "$T/c.json"; cat "$T/c.json" > "$CONTRACT"; git add "$CONTRACT"
gate
check "a malformed shared field cannot mean no shared roles" "1" "$RC"
reset_all
cat > "$T/snip" <<'SHARED_EOF'
. "$_PC_SCRIPTS/lib/wv-fixture-helper.sh"
if ! fixture_src_ok; then echo 'fixture: baseline guard refuses BUG' >&2; exit 1; fi
SHARED_EOF
into_hook "$T/snip"
jq --arg p "$HELPER" '.shared = [$p] | .invoking += [$p]' "$CONTRACT" > "$T/c.json"
cat "$T/c.json" > "$CONTRACT"; commit_nohook "fixture shared role"
_gl_shared_blob=$(git rev-parse "HEAD:$HELPER")
fresh "$HELPER"; gate
check "a shared change without a record is refused" "1" "$RC"
check "...before any routed suite" "0" "$(runs probe)"
record shared "$HELPER" "$_gl_shared_blob" "$(git hash-object "$HELPER")"
git add .weave/gate-repairs; gate
check "a shared record staged alongside the change admits nothing" "1" "$RC"
commit_record shared; gate
check "a prior exact shared record admits a harmless change" "0" "$RC"
has "...while still judging the candidate lane" "$OUT" "candidate lanes: 1 of 1 admitted"
has "...with traceability, not approval" "$OUT" "shared change"
chmod +x "$HELPER"; git add "$HELPER"; gate
check "a shared record at a different mode admits nothing" "1" "$RC"
reset_all
printf '#!/usr/bin/env bash\nfixture_src_ok() { return 1; }\n' > "$HELPER"; git add "$HELPER"
record shared "$HELPER" "$_gl_shared_blob" "$(git hash-object "$HELPER")"
commit_record shared; gate
check "a recorded but broken shared candidate is refused" "1" "$RC"
has "...by its own lane, not replaced by the record" "$OUT" "candidate version of $HELPER does not admit"
reset_all
jq '.shared = []' "$CONTRACT" > "$T/c.json"; cat "$T/c.json" > "$CONTRACT"; git add "$CONTRACT"
gate
check "shared-to-enforcement demotion needs its own contract record" "1" "$RC"
record roles "$CONTRACT" "$(git rev-parse "HEAD:$CONTRACT")" "$(git hash-object "$CONTRACT")"
commit_record roles; gate
check "an exact prior contract record admits that demotion" "0" "$RC"
has "...with the contract record named" "$OUT" ".weave/gate-repairs/roles.json"
git reset -q --hard "$_gl_record_start"; rm -rf .weave/gate-repairs

echo "retirement records admit deletion only, once, with the baseline guard active"
reset_all
into_hook "$T/snip"; commit_nohook "fixture retiring guard"
_gl_retire_base=$(git rev-parse HEAD)
_gl_retire_blob=$(git rev-parse "HEAD:$HELPER")
git rm -q "$HELPER"; gate
check "an unrecorded enforcement deletion is refused" "1" "$RC"
check "...before any routed suite" "0" "$(runs probe)"
record retire "$HELPER" "$_gl_retire_blob" "" '.replacement_mode = "000000"'
commit_record retire; gate
check "a repair record cannot substitute for a retirement record" "1" "$RC"
record retire "$HELPER" "$_gl_retire_blob" "" '.kind = "retirement" | .replacement_mode = "000000"'
git add .weave/gate-repairs; gate
check "a retirement record staged with deletion admits nothing" "1" "$RC"
commit_record retire; gate
check "a prior exact retirement record admits deletion" "0" "$RC"
has "...explicitly naming retirement" "$OUT" "retirement record"
check "...after the protected routed suite ran" "1" "$(runs probe)"
printf '#!/bin/sh\necho BUG\n' > src/a.sh; git add src/a.sh; gate
check "retirement never bypasses the baseline subject check" "1" "$RC"
has "...with the baseline refusal preserved" "$OUT" "fixture: baseline guard refuses BUG"
git checkout -q HEAD -- src/a.sh
git show "$_gl_retire_base:$HELPER" > "$HELPER"
printf '\nfixture_src_ok() { return 1; }\n' >> "$HELPER"; git add "$HELPER"; gate
check "a retirement record does not excuse a broken rewrite" "1" "$RC"
has "...which still has its candidate lane" "$OUT" "candidate version of $HELPER does not admit"
git rm -q -f "$HELPER"; commit_nohook "fixture retired"
_gl_retire_tree=$(git rev-parse HEAD:scripts/lib)
git show "$_gl_retire_base:$HELPER" > "$HELPER"; commit_nohook "fixture restored"
# Keep the index's missing-helper subtree distinct from the historical one:
# hiding the latter must exercise history, not an unreadable candidate.
printf 'later tree\n' > scripts/lib/retire-later-fixture.txt
git add scripts/lib/retire-later-fixture.txt
git rm -q "$HELPER"
check "a retirement stays consumed after deletion and restoration" "1" "$(resolve_record "$W" "$HELPER" retirement)"
_gl_object=".git/objects/${_gl_retire_tree:0:2}/${_gl_retire_tree:2}"
mv "$_gl_object" "$T/retired-tree"
check "unreadable retirement history is unknown, never unused" "2" "$(resolve_record "$W" "$HELPER" retirement)"
mv "$T/retired-tree" "$_gl_object"
check "(control) readable retirement history remains consumed" "1" "$(resolve_record "$W" "$HELPER" retirement)"
_gl_consumed_rc=$(
    source "$ROOT/scripts/lib/wv-gate-snapshot.sh"
    source "$ROOT/scripts/lib/wv-gate-lanes.sh"
    gate_freeze || exit 8
    wait() { return 127; }
    rc=0; gate_repair_record "$HELPER" retirement >/dev/null 2>&1 || rc=$?
    printf '%s\n' "$rc"
)
check "readable consumed history survives unavailable wait bookkeeping" "1" "$_gl_consumed_rc"
# A listing can emit valid records and still fail. Consumption checks launch
# their own processes, so their status must not replace the listing's status.
_gl_listing_rc=$(
    cd "$W" || exit 9
    source "$ROOT/scripts/lib/wv-gate-snapshot.sh"
    source "$ROOT/scripts/lib/wv-gate-lanes.sh"
    gate_freeze || exit 8
    git() {
        if [ "${1:-}" = ls-tree ] && [ "${2:-}" = -r ] \
            && [ "${3:-}" = --full-tree ] && [ "${6:-}" = .weave/gate-repairs ]; then
            command git "$@" || return
            return 73
        fi
        command git "$@"
    }
    gate_repair_record "$HELPER" retirement >/dev/null 2>&1
    echo $?
)
check "a failed record listing stays unknown after consumption checks" "2" "$_gl_listing_rc"
git reset -q --hard "$_gl_record_start"; rm -rf .weave/gate-repairs

echo "HEAD's role contract decides"
reset_all; git rm -q "$CONTRACT"; stage_src
gate
check "deleting the contract is refused" "1" "$RC"
has "...as retiring the boundary" "$OUT" "removes the gate role contract"

reset_all; jq '.invoking -= ["scripts/wv"]' "$CONTRACT" > "$T/c.json" && cat "$T/c.json" > "$CONTRACT"; git add "$CONTRACT"
gate
check "dropping an invoking file is refused" "1" "$RC"
has "...naming it" "$OUT" "drops scripts/wv"

reset_all; jq '.enforcement = ["scripts/hooks/"]' "$CONTRACT" > "$T/c.json" && cat "$T/c.json" > "$CONTRACT"; git add "$CONTRACT"
gate
check "narrowing enforcement is refused" "1" "$RC"
has "...naming the prefix" "$OUT" "drops scripts/"

reset_all; printf '{\n' > "$CONTRACT"; git add "$CONTRACT"
gate
check "an invalid staged contract is refused" "1" "$RC"
has "...as invalid" "$OUT" "staged gate role contract ($CONTRACT) is not valid"

reset_all
# shellcheck disable=SC2016  # the hook's text, not this suite's expansion
printf '%s\n' ': "$REPO_ROOT/undeclared/thing"' > "$T/snip"; into_hook "$T/snip"
gate
check "a dependency the contract does not declare is refused" "1" "$RC"
has "...naming it" "$OUT" "names undeclared/thing (index), which HEAD's gate role contract does not declare"
jq '.external["undeclared/thing"] = "fixture"' "$CONTRACT" > "$T/c.json" && cat "$T/c.json" > "$CONTRACT"; git add "$CONTRACT"
gate
check "declaring it in the same commit does not admit it" "1" "$RC"

reset_all
# shellcheck disable=SC2016
printf '%s\n' ': "$REPO_ROOT/scripts/lib/no-such-file.sh"' > "$T/snip"; into_hook "$T/snip"
gate
check "an enforcement dependency that does not exist is refused" "1" "$RC"
has "...as unresolved" "$OUT" "scripts/lib/no-such-file.sh, an enforcement path the index tree does not have (unresolved)"

echo "enforcement declarations must fit the protected copy"
reset_all
jq '.enforcement += ["src/a.sh"]' "$CONTRACT" > "$T/c.json" && cat "$T/c.json" > "$CONTRACT"
git add "$CONTRACT"; gate
check "an existing root outside the supported copy is refused" "1" "$RC"
has "...naming the unsupported root" "$OUT" "unsupported enforcement root src/a.sh"

reset_all
jq '.enforcement += ["build-release.sh"]' "$CONTRACT" > "$T/c.json" && cat "$T/c.json" > "$CONTRACT"
git add "$CONTRACT"; gate
check "a supported but absent enforcement root is refused" "1" "$RC"
has "...naming the missing root" "$OUT" "enforcement root build-release.sh is missing"

reset_all
jq '.enforcement += ["scripts/../src/"]' "$CONTRACT" > "$T/c.json" && cat "$T/c.json" > "$CONTRACT"
git add "$CONTRACT"; gate
check "a noncanonical enforcement root is refused" "1" "$RC"
has "...as an invalid contract" "$OUT" "staged gate role contract ($CONTRACT) is not valid"

# These cases manufacture external policy files; they do not depend on the
# source-only checkers omitted from the public projection (wv-c79fc7).
# shellcheck source=tests/fixtures/gate-lanes/external-policy.sh
source "$SCRIPT_DIR/fixtures/gate-lanes/external-policy.sh" || exit 1

reset_all; git rm -q "$CONTRACT"; commit_nohook "contract gone"
stage_src; gate
check "a HEAD without a contract refuses every commit" "1" "$RC"
has "...saying so" "$OUT" "HEAD carries no gate role contract"
git reset -q --hard HEAD~1

echo "a candidate lane judges the protected lane's tree"
reset_all; fresh scripts/lib/wv-config.sh
# Archive the fixture's own contract with its scripts, not the checkout's production contract.
rm -rf "$T/one"; mkdir -p "$T/one/tree"; git archive HEAD scripts | tar -xf - -C "$T/one/tree"
git rev-parse HEAD > "$T/one/weave-gate-lane"
printf 'path=scripts/lib/wv-config.sh\ntree=%s\nreuse=1\n' "$(git rev-parse 'HEAD^{tree}')" > "$T/one/weave-gate-candidate"
OUT=$(env -u WV_LIB_DIR -u WV_CLI bash "$T/one/tree/$HOOK" 2>&1); RC=$?
check "a lane that froze another tree is refused" "1" "$RC"
has "...saying so" "$OUT" "not the protected lane's"

echo "a candidate that stalls before its suite pool is bounded and leaves evidence"
reset_all
cat > "$T/hung-candidate" <<HUNG_CANDIDATE
trap '' TERM
sleep 120 &
printf '%s %s\n' "\$\$" "\$!" > "$MARK/hung-candidate.pids"
wait
HUNG_CANDIDATE
into_hook "$T/hung-candidate"
# The outer guard also covers baseline linting/setup before the lane starts.
# It must not compete with the eight-second deadline under test.
OUT=$(WV_GATE_LANE_TIMEOUT=8 timeout -k 2 90 ./.git/hooks/pre-commit 2>&1); RC=$?
check "a hung candidate refuses, not the outer safety deadline" "1" "$RC"
has "...naming the candidate and timeout" "$OUT" "TIMEOUT candidate lane scripts/hooks/pre-commit-weave.sh"
has "...with the failed timeout status" "$OUT" "boundary rule 4, exit 124"
check "the candidate actually reached the hanging command" "yes" "$([ -s "$MARK/hung-candidate.pids" ] && echo yes || echo no)"
_gl_alive=0
for _gl_pid in $(cat "$MARK/hung-candidate.pids" 2>/dev/null); do
    kill -0 "$_gl_pid" 2>/dev/null && _gl_alive=$((_gl_alive + 1))
done
check "the candidate and its resistant child are reaped" "0" "$_gl_alive"
_gl_output=$(awk '/full output:/ { print $NF }' <<< "$OUT" | tail -1)
check "full failure output survives the dispatcher's cleanup" "yes" "$([ -f "$_gl_output" ] && echo yes || echo no)"
if [ -f "$_gl_output" ]; then
    has "...and retains the original timeout evidence" "$(cat "$_gl_output")" "TIMEOUT candidate lane scripts/hooks/pre-commit-weave.sh"
fi

reset_all
echo ""
echo "gate lanes: $pass/$run passed"
[ "$pass" -eq "$run" ]
