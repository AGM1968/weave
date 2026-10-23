#!/usr/bin/env bash
# Suite launch order and the candidate lanes' share of the pool bound
# (wv-d7af8d). Units of scripts/lib/wv-gate-pool.sh and wv-gate-lanes.sh:
#   - suites measured at GATE_POOL_FAST_S (20s) or less launch first, each
#     group longest first, unmeasured counted as longest in the slow group;
#   - lanes running together split WV_GATE_JOBS, the remainder to the first,
#     never holding more than it between them and each holding at least one;
#   - hook_gate_jobs takes a lane's share before WV_GATE_JOBS.
set -uo pipefail
export WV_TEST_SUITE=1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }

hook_progress() { :; }
hook_duration_ms() { echo 0; }
# shellcheck source=../scripts/lib/wv-gate-pool.sh
. "$ROOT/scripts/lib/wv-gate-pool.sh"
# shellcheck source=../scripts/lib/wv-gate-lanes.sh
. "$ROOT/scripts/lib/wv-gate-lanes.sh"

order() { gate_pool_launch_order "$1" | cut -f2 | paste -sd ' ' -; }

echo "launch order: the fast group first, each group longest first"
check "the threshold is 20s" "20" "$GATE_POOL_FAST_S"
check "mixed costs" "d b c a e" "$(order '[{"name":"a","last_cost_s":300},{"name":"b","last_cost_s":5},{"name":"c","last_cost_s":0},{"name":"d","last_cost_s":20},{"name":"e","last_cost_s":21}]')"
check "20s is fast, 21s is not" "x y" "$(order '[{"name":"y","last_cost_s":21},{"name":"x","last_cost_s":20}]')"
check "an unmeasured suite is slow and goes first among the slow" "f u s" "$(order '[{"name":"s","last_cost_s":30},{"name":"u"},{"name":"f","last_cost_s":3}]')"
check "with no fast suite the order is longest first, as before" "u a b" "$(order '[{"name":"b","last_cost_s":40},{"name":"u","last_cost_s":0},{"name":"a","last_cost_s":90}]')"
check "the index keeps the selection order" "2 0 1" "$(gate_pool_launch_order '[{"name":"a","last_cost_s":90},{"name":"b","last_cost_s":40},{"name":"c","last_cost_s":2}]' | cut -f1 | paste -sd ' ' -)"

echo "lane shares of the pool bound"
budgets() { local i out=""; for ((i = 0; i < $2; i++)); do out+="$(gate_lanes_job_budget "$1" "$2" "$i") "; done; echo "${out% }"; }
check "4 jobs, 1 lane" "4" "$(budgets 4 1)"
check "4 jobs, 2 lanes" "2 2" "$(budgets 4 2)"
check "4 jobs, 3 lanes: the remainder to the first" "2 1 1" "$(budgets 4 3)"
check "4 jobs, 4 lanes" "1 1 1 1" "$(budgets 4 4)"
check "4 jobs, 6 lanes: 4 run together, one job each" "1 1 1 1 1 1" "$(budgets 4 6)"
check "1 job, 3 lanes" "1 1 1" "$(budgets 1 3)"
check "6 jobs, 4 lanes" "2 2 1 1" "$(budgets 6 4)"
# Lanes running together never hold more than the bound: with fewer lanes
# than jobs all run at once; with more, each holds one.
over=0
for j in 1 2 3 4 5 6 8; do for l in 1 2 3 4 5 7 9; do
    together=$(( l < j ? l : j )); sum=0; min=99
    for ((i = 0; i < together; i++)); do b=$(gate_lanes_job_budget "$j" "$l" "$i"); sum=$((sum + b)); [ "$b" -lt "$min" ] && min=$b; done
    { [ "$sum" -le "$j" ] && [ "$min" -ge 1 ]; } || over=$((over + 1))
done; done
check "over 49 combinations no set of lanes running together exceeds the bound or holds none" "0" "$over"

echo "the pool bound takes a lane's share first"
check "WV_GATE_JOBS alone" "3" "$(WV_GATE_JOBS=3 hook_gate_jobs)"
check "a lane share wins over WV_GATE_JOBS" "1" "$(WV_GATE_JOBS=3 WV_GATE_LANE_JOBS=1 hook_gate_jobs)"
check "neither set: 4" "4" "$(env -u WV_GATE_JOBS -u WV_GATE_LANE_JOBS bash -c '. "$1/scripts/lib/wv-gate-pool.sh"; hook_gate_jobs' _ "$ROOT")"

echo "a lane's pool settings do not reach a gate its suite runs (nested boundary, wv-6900e1)"
# A candidate lane's pool records nothing and reuses nothing (_pc_pool_record=0,
# _pc_pool_reuse=off), set as shell variables. A suite it runs may run a gate
# of its own (test-prepush-gate.sh drives the real pre-push hook), whose pool
# must record as usual: the pre-push hook sets _pc_pool_reuse itself but not
# _pc_pool_record, so an exported value would decide it. 2026-10-15: a test
# driver exporting both made test-prepush-gate.sh fail 6 assertions; only
# _pc_pool_record=0 mattered.
NT=$(mktemp -d)
mkdir -p "$NT/outer/tests" "$NT/inner/tests"
git -C "$NT/outer" init -q
git -C "$NT/inner" init -q
cat > "$NT/wv-stub" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$NT/calls.log"
case "\$1" in test-status) exit 1 ;; *) exit 0 ;; esac
STUB
chmod +x "$NT/wv-stub"
printf '#!/bin/sh\nexit 0\n' > "$NT/inner/tests/test-inner.sh"
# The outer suite runs a nested pool the way the pre-push hook does: it sets
# its own reuse mode and leaves recording to the default.
cat > "$NT/outer/tests/test-nested.sh" <<NESTED
#!/usr/bin/env bash
export REPO_ROOT="$NT/inner" WV="$NT/wv-stub"
hook_progress() { :; }
hook_duration_ms() { echo 0; }
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/wv-gate-pool.sh"
_pc_pool_reuse=worktree
git -C "\$REPO_ROOT" add -A
export WV_GATE_TREE=\$(git -C "\$REPO_ROOT" write-tree)
unset WV_GATE_BASE
run_hook_suites <<< "0	tests/test-inner.sh	1"
NESTED
# lane_pool [export] — the outer pool with a lane's settings, as shell
# variables (the hook's form), or exported (the leak), running the outer suite.
lane_pool() {
    : > "$NT/calls.log"
    (
        export REPO_ROOT="$NT/outer" WV="$NT/wv-stub" WV_GATE_JOBS=1
        hook_progress() { :; }
        hook_duration_ms() { echo 0; }
        # shellcheck source=../scripts/lib/wv-gate-pool.sh
        source "$ROOT/scripts/lib/wv-gate-pool.sh"
        _pc_pool_record=0 _pc_pool_reuse=off
        [ "${1:-}" = export ] && export _pc_pool_record _pc_pool_reuse
        git -C "$REPO_ROOT" add -A
        export WV_GATE_TREE=$(git -C "$REPO_ROOT" write-tree)
        unset WV_GATE_BASE
        run_hook_suites <<< "0	tests/test-nested.sh	1"
    ) >/dev/null 2>&1
}
lane_pool
check "the nested gate's pool records its suite" "1" "$(grep -c '^test-record tests/test-inner.sh' "$NT/calls.log")"
check "...while the lane's own pool records nothing" "0" "$(grep -c '^test-record tests/test-nested.sh' "$NT/calls.log")"
lane_pool export
check "(control) exported, the lane's setting reaches the nested pool, which records nothing" "0" \
    "$(grep -c '^test-record tests/test-inner.sh' "$NT/calls.log")"

echo "scratch capacity, ownership and resource diagnostics through the real pool"
mkdir -p "$NT/disk root" "$NT/fallback"
printf 'unrelated\n' > "$NT/disk root/brain.db"
cat > "$NT/outer/tests/test-scratch.sh" <<PROBE
printf '%s\n' "\$TMPDIR" > "$NT/where"
[ -z "\${WV_SCRATCH_ROOT+x}" ] || exit 41
mkdir "\$TMPDIR/leftover"
PROBE
printf 'echo "No space left on device" >&2; exit 3\n' > "$NT/outer/tests/test-full.sh"
printf 'echo "policy refusal" >&2; exit 3\n' > "$NT/outer/tests/test-refusal.sh"
scratch_pool() {
    (
        export REPO_ROOT="$NT/outer" WV="$NT/wv-stub" WV_GATE_JOBS=1
        export WV_SCRATCH_ROOT="$NT/disk root" TMPDIR="$NT/fallback"
        unset PYTHONDONTWRITEBYTECODE
        _pc_pool_record=0 _pc_pool_reuse=off
        git -C "$REPO_ROOT" add -A
        export WV_GATE_TREE=$(git -C "$REPO_ROOT" write-tree)
        unset WV_GATE_BASE
        run_hook_suites <<< "0	tests/$1	1"
    ) 2>&1
}
rc=0; out=$(WV_SCRATCH_MIN_KB=999999999999 scratch_pool test-scratch.sh) || rc=$?
check "low capacity refuses the pool" "1" "$rc"
check "no suite starts on capacity refusal" "no" "$([ -e "$NT/where" ] && echo yes || echo no)"
check "capacity refusal names the reason" "yes" "$([[ "$out" == *"insufficient capacity before expensive work"* ]] && echo yes || echo no)"
rc=0; out=$(scratch_pool test-scratch.sh) || rc=$?
check "a configured root runs the suite, without leaking the override" "0" "$rc"
where=$(cat "$NT/where" 2>/dev/null)
check "suite TMPDIR is inside the explicit root, not the fallback" "yes" "$([[ "$where" == "$NT/disk root/"* ]] && echo yes || echo no)"
check "owned leftovers are removed" "no" "$([ -d "$where" ] && echo yes || echo no)"
check "unrelated graph sentinel survives" "unrelated" "$(cat "$NT/disk root/brain.db")"
rc=0; out=$(scratch_pool test-full.sh) || rc=$?
check "ENOSPC still fails the pool" "1" "$rc"
check "failed output carries a resource diagnostic" "yes" "$([[ "$out" == *"RESOURCE: failed suite output reports exhausted storage"* ]] && echo yes || echo no)"
rc=0; out=$(scratch_pool test-refusal.sh) || rc=$?
check "ordinary refusal still fails the pool" "1" "$rc"
check "ordinary refusal is not labelled ENOSPC" "no" "$([[ "$out" == *"RESOURCE:"* ]] && echo yes || echo no)"

printf 'value = 37\n' > "$NT/outer/shared_fixture.py"
printf 'PYTHONPATH=%q python3 -c %q\n' "$NT/outer" \
    'import shared_fixture; assert shared_fixture.value == 37' > "$NT/outer/tests/test-import.sh"
rc=0; out=$(scratch_pool test-import.sh) || rc=$?
check "a suite can import its source fixture" "0" "$rc"
check "imports do not create a cache in the shared source tree" "no" \
    "$([ -d "$NT/outer/__pycache__" ] && echo yes || echo no)"

echo "bounded suites report the live tree and stop owned processes, not siblings"
cat > "$NT/outer/tests/test-hung.sh" <<HUNG
trap '' TERM
sleep 120 &
printf '%s %s\n' "\$\$" "\$!" > "$NT/hung.pids"
wait
HUNG
sleep 120 & sentinel=$!
for jobs in 1 2; do
    rm -f "$NT/hung.pids" "$NT/where"
    rc=0
    out=$(timeout -k 2 15 bash -c '
        source "$1/scripts/lib/wv-gate-pool.sh"
        hook_progress() { :; }; hook_duration_ms() { echo 0; }
        REPO_ROOT=$2/outer WV=$2/wv-stub
        WV_SCRATCH_ROOT=$2/disk\ root TMPDIR=$2/fallback
        WV_GATE_JOBS=$3 WV_GATE_TIMEOUT=1
        _pc_pool_record=0 _pc_pool_reuse=off
        git -C "$REPO_ROOT" add -A
        export WV_GATE_TREE=$(git -C "$REPO_ROOT" write-tree)
        unset WV_GATE_BASE
        run_hook_suites <<< $'"'"'0\ttests/test-hung.sh\t1\n1\ttests/test-scratch.sh\t1'"'"'
    ' _ "$ROOT" "$NT" "$jobs" 2>&1) || rc=$?
    check "$jobs job(s): a hung suite fails the pool, not the outer safety bound" "1" "$rc"
    check "$jobs job(s): timeout names the suite and elapsed time" "yes" \
        "$([[ "$out" == *"TIMEOUT tests/test-hung.sh"* && "$out" == *"elapsed="* ]] && echo yes || echo no)"
    # A deadline can expire during snapshot setup, before the shell starts.
    # Require the active process diagnostic here; exercise a known live shell
    # and its child directly below, without racing dependency/tool startup.
    check "$jobs job(s): diagnostic contains active command and wait state" "yes" \
        "$([[ "$out" == *"test-hung.sh"* && "$out" == *"WCHAN"* ]] && echo yes || echo no)"
    alive=0
    for pid in $(cat "$NT/hung.pids" 2>/dev/null); do
        kill -0 "$pid" 2>/dev/null && alive=$((alive + 1))
    done
    check "$jobs job(s): TERM-resistant suite and its child are reaped" "0" "$alive"
    check "$jobs job(s): unrelated process survives" "yes" "$(kill -0 "$sentinel" 2>/dev/null && echo yes || echo no)"
    # Dispose the unfixed control's survivors without touching any real suite.
    for pid in $(cat "$NT/hung.pids" 2>/dev/null); do kill -KILL "$pid" 2>/dev/null || true; done
done
kill "$sentinel" 2>/dev/null || true
wait "$sentinel" 2>/dev/null || true

rm -f "$NT/hung.pids"
rc=0; out=$(gate_run_bounded live-hung-suite 1 bash "$NT/outer/tests/test-hung.sh" 2>&1) || rc=$?
check "a live suite timeout preserves status 124" "124" "$rc"
check "the live suite actually started its child" "yes" "$([ -s "$NT/hung.pids" ] && echo yes || echo no)"
check "a live timeout reports the child's PID, command and wait state" "yes" \
    "$([[ -s "$NT/hung.pids" && "$out" == *"$(awk '{print $2}' "$NT/hung.pids")"* && "$out" == *"sleep 120"* && "$out" == *"WCHAN"* ]] && echo yes || echo no)"
alive=0
for pid in $(cat "$NT/hung.pids" 2>/dev/null); do
    kill -0 "$pid" 2>/dev/null && alive=$((alive + 1))
done
check "the live timeout reaps the resistant suite and its child" "0" "$alive"

echo "ownership survives root exit, daemonization and nested supervisors"
cat > "$NT/daemon.py" <<'DAEMON'
import os
from pathlib import Path
import signal
import sys
import time

mark = Path(sys.argv[1])
if os.fork():
    while not mark.exists():
        time.sleep(0.01)
    sys.exit(0)
os.setsid()
if os.fork():
    os._exit(0)
mark.write_text(str(os.getpid()) + "\n", encoding="utf-8")

def late_child(_signum, _frame):
    if os.fork() == 0:
        os.setsid()
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        with mark.open("a", encoding="utf-8") as stream:
            stream.write(str(os.getpid()) + "\n")
        time.sleep(120)
        os._exit(0)
    os._exit(0)

signal.signal(signal.SIGTERM, late_child)
time.sleep(120)
DAEMON
printf 'python3 %q %q\n' "$NT/daemon.py" "$NT/daemon.pids" > "$NT/outer/tests/test-daemon.sh"
rc=0; out=$(scratch_pool test-daemon.sh) || rc=$?
check "an ordinary root exit keeps its result while draining a double-forked daemon" "0" "$rc"
alive=0
while read -r pid; do kill -0 "$pid" 2>/dev/null && alive=$((alive + 1)); done < "$NT/daemon.pids"
check "the detached daemon and its TERM-created child are both reaped" "0" "$alive"
check "the TERM-created child actually ran" "2" "$(wc -l < "$NT/daemon.pids" | tr -d ' ')"

cat > "$NT/nested-cancel.sh" <<NESTED_CANCEL
source "$ROOT/scripts/lib/wv-gate-pool.sh"
hook_progress() { :; }; hook_duration_ms() { echo 0; }
REPO_ROOT="$NT/outer" WV="$NT/wv-stub"
WV_GATE_TIMEOUT=120 WV_GATE_JOBS=1
WV_SCRATCH_ROOT="$NT/disk root" TMPDIR="$NT/fallback"
_pc_pool_record=0 _pc_pool_reuse=off
git -C "\$REPO_ROOT" add -A
export WV_GATE_TREE=\$(git -C "\$REPO_ROOT" write-tree)
unset WV_GATE_BASE
run_hook_suites <<< "0	tests/test-hung.sh	1"
NESTED_CANCEL
# This probe concerns nested supervision, not snapshot provisioning. Start
# the inner supervisor directly so the outer one-second deadline exercises
# its live descendants rather than racing clone/toolchain setup. The next
# cancellation probe still drives the complete pool and waits for its suite.
cat > "$NT/nested-timeout.sh" <<NESTED_TIMEOUT
source "$ROOT/scripts/lib/wv-gate-pool.sh"
gate_run_bounded inner-suite 120 bash "$NT/outer/tests/test-hung.sh"
NESTED_TIMEOUT
rm -f "$NT/hung.pids"
rc=0; out=$(gate_run_bounded nested-lane 1 bash "$NT/nested-timeout.sh" 2>&1) || rc=$?
check "an outer deadline fails even when an inner suite owns a separate session" "124" "$rc"
check "outer timeout reports the inner suite command" "yes" \
    "$([[ "$out" == *"test-hung.sh"* && -s "$NT/hung.pids" ]] && echo yes || echo no)"
alive=0
for pid in $(cat "$NT/hung.pids" 2>/dev/null); do kill -0 "$pid" 2>/dev/null && alive=$((alive + 1)); done
check "outer cleanup reaps the inner suite and its TERM-resistant child" "0" "$alive"

rm -f "$NT/hung.pids"
rc=0; out=$(timeout -k 2 10 bash -c '
    bash "$1/nested-cancel.sh" & pool=$!
    for ((n=0; n<200; n++)); do
        [ -s "$1/hung.pids" ] && break
        sleep 0.01
    done
    [ -s "$1/hung.pids" ] || exit 91
    kill -TERM "$pool"; wait "$pool"; result=$?
    alive=0
    for pid in $(cat "$1/hung.pids"); do kill -0 "$pid" 2>/dev/null && alive=$((alive + 1)); done
    printf "pool_exit=%s survivors=%s\n" "$result" "$alive"
' _ "$NT" 2>&1) || rc=$?
check "cancelling a serial pool finishes without the outer safety deadline" "0" "$rc"
check "cancellation refuses and reaps the actual suite processes" "yes" \
    "$([[ "$out" == *"pool_exit=130 survivors=0"* ]] && echo yes || echo no)"

echo "the macOS process-group backend remains executable (portable path, not a native Mac test)"
portable_supervisor() {
    python3 -c '
import runpy
import sys
module = runpy.run_path(sys.argv[1])
sys.platform = "darwin"
sys.argv = sys.argv[1:]
sys.exit(module["main"]())
' "$ROOT/scripts/lib/wv-gate-supervisor.py" "$@"
}
rc=0; out=$(portable_supervisor portable-success 5 sh -c 'printf portable-ran' 2>&1) || rc=$?
check "the portable backend launches and returns a successful command" "0:portable-ran" "$rc:$out"
rc=0; out=$(portable_supervisor portable-failure 5 sh -c 'exit 37' 2>&1) || rc=$?
check "the portable backend preserves a nonzero command result" "37" "$rc"
sleep 120 & sentinel=$!
rm -f "$NT/hung.pids"
rc=0; out=$(portable_supervisor portable-hang 1 bash "$NT/outer/tests/test-hung.sh" 2>&1) || rc=$?
check "the portable backend times out a TERM-resistant command" "124" "$rc"
check "portable timeout reports the command and its weaker containment boundary" "yes" \
    "$([[ "$out" == *"TIMEOUT portable-hang"* && "$out" == *"sleep 120"* && "$out" == *"detached descendants are not owned"* ]] && echo yes || echo no)"
alive=0
for pid in $(cat "$NT/hung.pids" 2>/dev/null); do
    state=$(ps -o stat= -p "$pid" 2>/dev/null)
    case "$state" in ''|Z*) ;; *) alive=$((alive + 1)) ;; esac
done
check "the portable backend leaves no live private-group member" "0" "$alive"
check "portable cleanup preserves an unrelated same-command process" "yes" "$(kill -0 "$sentinel" 2>/dev/null && echo yes || echo no)"
kill "$sentinel" 2>/dev/null || true
wait "$sentinel" 2>/dev/null || true

echo "shared-helper refusals identify their failing operation and status"
rc=0; out=$(jq() { return 73; }; gate_pool_launch_order '[]' 2>&1) || rc=$?
check "unreadable launch selection fails" "1" "$rc"
check "unreadable launch selection names operation and original status" "yes" \
    "$([[ "$out" == *"gate_pool_launch_order"* && "$out" == *"status 73"* ]] && echo yes || echo no)"
printf 'not a tar archive\n' > "$NT/bad.tar"
rc=0; out=$(_gate_lane_build "$NT/bad-lane" "$NT/bad.tar" scripts/fixture 2>&1) || rc=$?
check "failed lane extraction refuses" "1" "$rc"
check "failed lane extraction names operation and status" "yes" \
    "$([[ "$out" == *"extract"* && "$out" == *"status 2"* ]] && echo yes || echo no)"
rm -rf "$NT"

echo ""
echo "gate pool order: $pass/$run passed"
[ "$pass" -eq "$run" ]
