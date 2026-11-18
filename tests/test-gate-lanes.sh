#!/usr/bin/env bash
# Candidate lanes, the mechanism (S2b, wv-7ee8fe, epic wv-d67163; boundary
# rules 1, 2 and 4, wv-ecf877).
#
# HEAD's protected gate (S2a) judges every commit. When the commit changes a
# gate file (an enforcement path in HEAD's scripts/hooks/gate-roles.json),
# that file also runs as written, in its own lane: HEAD's scripts/ with only
# that file staged. Every lane must admit. Pinned here, in a fixture whose HEAD
# carries this checkout's scripts/:
#   - a changed gate file runs as written, in its own lane;
#   - a lane reuses recorded suite results unless it changes the code that runs
#     suites, and records nothing itself; that code includes every library
#     loaded into the hook's shell, derived here from the hook (R3, wv-838349);
#   - external enforcement files each run their own check (R-a, W3, W6, N6);
#   - a candidate that stalls is bounded and leaves evidence.
# The role-contract invariants (D3, D4, R1, N1, R2, N2, S2c, repair records,
# retirement, HEAD's contract) are in test-gate-roles.sh: the compiled gate
# plan keeps those and retires this mechanism (wv-7e8216, wv-518c6c).
export WV_TEST_SUITE=1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
run=0; pass=0
# shellcheck source=tests/fixtures/gate-lanes/setup.sh
source "$SCRIPT_DIR/fixtures/gate-lanes/setup.sh" || exit 1

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
check "...and its gate record carries no lane fields (wv-3dbc11)" "false false false" \
    "$(tail -1 "$WV_GATE_LOG" | jq -r '"\(has("lanes")) \(has("lanes_ms")) \(has("protected_ms"))"')"
# The hook reads the host's PSI at the gate's start and end (wv-58b10e); a
# kernel without PSI records none.
check "...and the host's CPU and IO stall over the gate where the kernel has PSI" \
    "$([ -r /proc/pressure/cpu ] && [ -r /proc/pressure/io ] && echo true || echo false)" \
    "$(tail -1 "$WV_GATE_LOG" | jq -r '.pressure | type == "object" and has("cpu_some_share") and has("io_some_ms")')"

echo "a changed gate file runs as written, in its own lane"
reset_all; fresh scripts/lib/wv-cache.sh
_gl_suites=$(lines "$WV_SUITE_LOG"); _gl_gates=$(lines "$WV_GATE_LOG")
gate
check "a harmless edit to a gate file is admitted" "0" "$RC"
has "...after its lane admitted it" "$OUT" "candidate lanes: 1 of 1 admitted"
hasnt "...claiming no run it cannot show (R2)" "$OUT" "as written in"
hasre "...timing that lane on its own, as reusing" "$OUT" "candidate lane scripts/lib/wv-cache\.sh: reused HEAD's suite results from [0-9]+ shared suite slot\(s\) in [0-9]+ms$"
check "...reusing the suite the protected lane just ran" "1" "$(runs probe)"
check "...with one suite ledger row, the protected lane's" "$((_gl_suites + 1))" "$(lines "$WV_SUITE_LOG")"
check "...and one gate record" "$((_gl_gates + 1))" "$(lines "$WV_GATE_LOG")"
# The lane writes no suite row, so the gate record is where its time lives
# (wv-3dbc11, wv-241d5f): the ms the hook printed, and the pass before it.
_gl_ms=$(printf '%s\n' "$OUT" | sed -n 's/.*candidate lane scripts\/lib\/wv-cache\.sh: .* in \([0-9]*\)ms$/\1/p' | tail -1)
check "...recording that lane in the gate record, as printed" "scripts/lib/wv-cache.sh true 0 ${_gl_ms:-unprinted}" \
    "$(tail -1 "$WV_GATE_LOG" | jq -r '.lanes | if length == 1 then .[0] | "\(.path) \(.reused) \(.rc) \(.ms)" else "lanes: \(length)" end')"
check "...with the lanes' wall and the protected pass before them" "true" \
    "$(tail -1 "$WV_GATE_LOG" | jq -r '.lanes_ms >= .lanes[0].ms and .protected_ms >= 0
        and .lanes_started_ms == .started_ms + .protected_ms and .protected_ms + .lanes_ms <= .duration_ms + 1')"

echo "time the host spends suspended is not a lane's cost (wv-b17a85)"
# Every nanosecond reading of this date is an hour later than the last, as if
# the host hibernated between any two; the supervisor's monotonic clock is not
# moved, and the lane's time is its reading.
_gl_date=$(command -v date)
mkdir -p "$T/jumpbin"
cat > "$T/jumpbin/date" <<JUMP_EOF
#!/bin/sh
[ "\$1" = +%s%N ] || exec "$_gl_date" "\$@"
n=\$(( \$(cat "$T/jumps" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$T/jumps"
echo \$(( \$("$_gl_date" +%s%N) + n * 3600000000000 ))
JUMP_EOF
chmod +x "$T/jumpbin/date"
reset_all; fresh scripts/lib/wv-cache.sh
PATH="$T/jumpbin:$PATH" gate
check "a gate whose wall clock jumps an hour per reading is admitted" "0" "$RC"
check "(control) the wall clock did jump: the gate read it, an hour a reading" "true" \
    "$([ "$(cat "$T/jumps" 2>/dev/null || echo 0)" -ge 2 ] && echo true || echo false)"
check "...yet the lane's time is its monotonic reading, under an hour" "true" \
    "$(tail -1 "$WV_GATE_LOG" | jq -r '.lanes | length == 1 and .[0].ms < 3600000 and .[0].clock == "monotonic"')"
check "...and so are the lanes' total and the gate's, each naming its clock (wv-b17a85)" "true" \
    "$(tail -1 "$WV_GATE_LOG" | jq -r '.duration_ms < 3600000 and .lanes_ms < 3600000 and .clock == "monotonic"')"
check "...as is each suite row the gate wrote" "true" \
    "$(tail -1 "$WV_SUITE_LOG" | jq -r '.duration_ms < 3600000 and .clock == "monotonic"')"
rm -f "$T/jumps"

reset_all; fresh scripts/lib/wv-gate-pool.sh
_gl_suites=$(lines "$WV_SUITE_LOG")
gate
check "an edit to the code that runs suites is admitted" "0" "$RC"
check "...and its lane runs the suite again, reusing nothing" "2" "$(runs probe)"
hasre "...timing that lane on its own, as a rerun" "$OUT" "candidate lane scripts/lib/wv-gate-pool\.sh: reran its suites from [0-9]+ shared suite slot\(s\) in [0-9]+ms$"
check "...while recording only the protected lane's row" "$((_gl_suites + 1))" "$(lines "$WV_SUITE_LOG")"
check "...and the gate record names that lane as a rerun" "scripts/lib/wv-gate-pool.sh false" \
    "$(tail -1 "$WV_GATE_LOG" | jq -r '.lanes[0] | "\(.path) \(.reused)"')"

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
check "...each timed on its own line" "3" "$(grep -cE "candidate lane scripts/lib/[a-z-]+\.sh: reused HEAD's suite results from [0-9]+ shared suite slot\(s\) in [0-9]+ms$" <<< "$OUT")"
# The lanes draw on one gate-wide budget rather than each taking the bound
# (wv-d7af8d) or a fixed share of it (wv-428a92): every lane names the same 4
# slots, and the gate record says which scheduler ran them.
check "...sharing the bound: all three lanes draw on the same 4 slots" "4 4 4" \
    "$(grep -oE "candidate lane scripts/lib/[a-z-]+\.sh: reused HEAD's suite results from [0-9]+" <<< "$OUT" | grep -oE '[0-9]+$' | paste -sd ' ')"
check "...and the gate record names the shared-slot scheduler for each lane" "shared-slots shared-slots shared-slots" \
    "$(tail -1 "$WV_GATE_LOG" | jq -r '[.lanes[].scheduler] | join(" ")')"

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
# shellcheck source=tests/fixtures/gate-lanes/external-guard.sh
source "$SCRIPT_DIR/fixtures/gate-lanes/external-guard.sh" || exit 1
_eg_plant "$T/one/tree"
OUT=$(env -u WV_LIB_DIR -u WV_CLI bash "$T/one/tree/$HOOK" 2>&1); RC=$?
check "a lane that froze another tree is refused" "1" "$RC"
has "...saying so" "$OUT" "not the protected lane's"
_eg_check "$T/one/tree"

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
