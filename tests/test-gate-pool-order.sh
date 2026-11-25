#!/usr/bin/env bash
# Suite launch order and the candidate lanes' share of the pool bound
# (wv-d7af8d). Units of scripts/lib/wv-gate-pool.sh and wv-gate-lanes.sh:
#   - suites launch longest first, unmeasured counted as longest; no cheap
#     suite jumps ahead (cheap-first measured worse, wv-ab1889);
#   - candidate lanes draw suites from one gate-wide budget of WV_GATE_JOBS
#     slots (wv-428a92): never more at once, a freed slot goes to a suite
#     waiting in any lane, a dead or interrupted holder frees its slot, and
#     the wait is not counted as the suite's cost;
#   - hook_gate_jobs takes a lane's bound before WV_GATE_JOBS.
set -uo pipefail
export WV_TEST_SUITE=1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/bounded.sh"  # timeout(1) is GNU-only; macOS has none (wv-412db3)
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# wv_now: a validated clock; BSD date may print %N literally (wv-43082a).
# shellcheck source=../scripts/lib/wv-resolve-runtime.sh
. "$ROOT/scripts/lib/wv-resolve-runtime.sh"

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

echo "launch order: longest first, unmeasured first (wv-ab1889)"
check "no cheap-first threshold remains" "unset" "${GATE_POOL_FAST_S-unset}"
check "mixed costs" "c a e d b" "$(order '[{"name":"a","last_cost_s":300},{"name":"b","last_cost_s":5},{"name":"c","last_cost_s":0},{"name":"d","last_cost_s":20},{"name":"e","last_cost_s":21}]')"
check "a 20s suite does not jump ahead of a 21s one" "y x" "$(order '[{"name":"y","last_cost_s":21},{"name":"x","last_cost_s":20}]')"
check "an unmeasured suite counts as longest" "u s f" "$(order '[{"name":"s","last_cost_s":30},{"name":"u"},{"name":"f","last_cost_s":3}]')"
check "with no cheap suite the order is the same" "u a b" "$(order '[{"name":"b","last_cost_s":40},{"name":"u","last_cost_s":0},{"name":"a","last_cost_s":90}]')"
check "the index keeps the selection order" "0 1 2" "$(gate_pool_launch_order '[{"name":"a","last_cost_s":90},{"name":"b","last_cost_s":40},{"name":"c","last_cost_s":2}]' | cut -f1 | paste -sd ' ' -)"

echo "candidate lanes share one budget of slots (wv-428a92)"
SUP="$ROOT/scripts/lib/wv-gate-supervisor.py"
ST=$(mktemp -d)
gate_lanes_slots "$ST/s2" 2
check "the budget is one slot file per job" "0 1" "$(ls "$ST/s2" | paste -sd ' ' -)"
# slot_job <slots> <name> <seconds> [stop-file] — one supervised suite stand-in
# taking a slot, logging its start and end in epoch ns to $ST/events.
slot_job() {
    WV_GATE_SLOTS="$1" WV_GATE_SLOT_STAMP="$ST/$2.stamp" WV_GATE_SLOT_STOP="${4:-}" \
        python3 -I "$SUP" "$2" 60 bash -c '
            . "$4/scripts/lib/wv-resolve-runtime.sh"
            echo "S $(wv_now ns) $1" >> "$2/events"
            sleep "$3"
            echo "E $(wv_now ns) $1" >> "$2/events"' _ "$2" "$ST" "$3" "$ROOT"
}
# peak [prefix] — the most jobs (whose names start with prefix) running at once.
peak() {
    sort -k2,2n "$ST/events" | awk -v p="${1:-}" 'index($3, p) == 1 {
        n += ($1 == "S") ? 1 : -1; if (n > m) m = n } END { print m + 0 }'
}
: > "$ST/events"
for j in a1 a2 a3 b1 b2 b3; do slot_job "$ST/s2" "$j" 0.4 & done; wait
check "six jobs from two lanes on 2 slots: at most 2 ran at once, and 2 did (actual overlap)" "2" "$(peak)"
check "...and every job ran" "6" "$(grep -c '^E ' "$ST/events")"
# Asymmetric lanes: lane a has one short suite, lane b three long ones. With
# fixed shares b would run its three one at a time on its single job; with a
# shared budget the slot a frees goes to b, so b's own suites overlap.
: > "$ST/events"
slot_job "$ST/s2" a-short 0.2 &
for j in 1 2 3; do slot_job "$ST/s2" "b-long$j" 0.8 & done; wait
check "asymmetric lanes: the long lane takes the slot the short one freed (b overlaps itself)" "2" "$(peak b-)"
check "...still never more than 2 at once" "2" "$(peak)"
stamp=$(cat "$ST/a-short.stamp" 2>/dev/null)
check "a holder stamps the slot it took and when, in epoch ns" "yes" \
    "$([[ "$stamp" =~ ^[01]\ [0-9]{18,}$ ]] && echo yes || echo no)"
rc=0; out=$(WV_GATE_SLOTS="$ST/s2" WV_GATE_SLOT_STAMP="$ST/env.stamp" WV_GATE_SLOT_STOP="$ST/nostop" \
    python3 -I "$SUP" env 60 bash -c 'echo "${WV_GATE_SLOTS-unset} ${WV_GATE_SLOT_STAMP-unset} ${WV_GATE_SLOT_STOP-unset}"') || rc=$?
check "the slot settings do not reach the command, so a gate it runs budgets on its own" "0 unset unset unset" "$rc $out"

echo "a dead or interrupted slot holder never strands the budget"
gate_lanes_slots "$ST/s1" 1
# Worker failure: the holder is SIGKILLed; the kernel drops its flock.
WV_GATE_SLOTS="$ST/s1" WV_GATE_SLOT_STAMP="$ST/k.stamp" \
    python3 -I "$SUP" holder 60 bash -c 'echo $$ > "$1"; exec sleep 30' _ "$ST/k.child" &
kpid=$!
for _ in $(seq 100); do [ -s "$ST/k.child" ] && break; sleep 0.05; done
WV_GATE_SLOTS="$ST/s1" WV_GATE_SLOT_STAMP="$ST/w.stamp" python3 -I "$SUP" waiter 60 touch "$ST/w.ran" &
wpid=$!
sleep 0.3
check "(control) the waiter has not started while the slot is held" "no" "$([ -e "$ST/w.ran" ] && echo yes || echo no)"
kill -KILL "$kpid"; wait "$kpid" 2>/dev/null
kill -KILL "$(cat "$ST/k.child")" 2>/dev/null || true
t0=$(wv_now ns); rc=0; wait "$wpid" || rc=$?
check "a SIGKILLed holder frees its slot: the waiter runs, within 5s" "0 yes yes" \
    "$rc $([ -e "$ST/w.ran" ] && echo yes || echo no) $([ $(( ($(wv_now ns) - t0) / 1000000 )) -lt 5000 ] && echo yes || echo no)"
# Interruption while waiting: TERM before a slot is held runs nothing.
WV_GATE_SLOTS="$ST/s1" WV_GATE_SLOT_STAMP="$ST/h.stamp" python3 -I "$SUP" holder 60 sleep 1.5 &
hpid=$!
for _ in $(seq 100); do [ -s "$ST/h.stamp" ] && break; sleep 0.05; done
WV_GATE_SLOTS="$ST/s1" WV_GATE_SLOT_STAMP="$ST/t.stamp" python3 -I "$SUP" term 60 touch "$ST/t.ran" &
tpid=$!
WV_GATE_SLOTS="$ST/s1" WV_GATE_SLOT_STAMP="$ST/p.stamp" WV_GATE_SLOT_STOP="$ST/stop" \
    python3 -I "$SUP" stopped 60 touch "$ST/p.ran" &
ppid_=$!
sleep 0.3
kill -TERM "$tpid"; rc=0; wait "$tpid" || rc=$?
check "TERM while waiting: exit 143, the command never ran, no slot stamped" "143 no no" \
    "$rc $([ -e "$ST/t.ran" ] && echo yes || echo no) $([ -e "$ST/t.stamp" ] && echo yes || echo no)"
: > "$ST/stop"; rc=0; wait "$ppid_" || rc=$?
check "the pool's stop flag while waiting: exit 125 (not started), the command never ran" "125 no" \
    "$rc $([ -e "$ST/p.ran" ] && echo yes || echo no)"
wait "$hpid"
rc=0; out=$(WV_GATE_SLOTS="$ST/s1" WV_GATE_SLOT_STAMP="$ST/after.stamp" bounded 5 python3 -I "$SUP" after 60 echo ran) || rc=$?
check "after all of that the one slot is free again (nothing leaked)" "0 ran" "$rc $out"
# The deadline bounds the command, not the wait for a slot.
WV_GATE_SLOTS="$ST/s1" WV_GATE_SLOT_STAMP="$ST/d1.stamp" python3 -I "$SUP" holder 60 sleep 1.5 &
hpid=$!
for _ in $(seq 100); do [ -s "$ST/d1.stamp" ] && break; sleep 0.05; done
rc=0; WV_GATE_SLOTS="$ST/s1" WV_GATE_SLOT_STAMP="$ST/d2.stamp" python3 -I "$SUP" quick 1 true 2>/dev/null || rc=$?
check "a 1s deadline is not spent waiting 1.5s for the slot" "0" "$rc"
wait "$hpid"

echo "the pool under shared slots: the wait is not the suite's cost, and a stopped waiter is not a failure"
mkdir -p "$ST/repo/tests"; git -C "$ST/repo" init -q
printf '#!/bin/sh\necho "${WV_GATE_SLOTS-unset} ${WV_GATE_SLOT_STAMP-unset} ${WV_GATE_SLOT_STOP-unset}" > %q\n' \
    "$ST/seen" > "$ST/repo/tests/test-quick.sh"
cat > "$ST/wv-stub" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$ST/calls.log"
case "\$1" in test-status) exit 1 ;; *) exit 0 ;; esac
STUB
chmod +x "$ST/wv-stub"
WV_GATE_SLOTS="$ST/s1" WV_GATE_SLOT_STAMP="$ST/pool-h.stamp" python3 -I "$SUP" holder 60 sleep 1.5 &
hpid=$!
for _ in $(seq 100); do [ -s "$ST/pool-h.stamp" ] && break; sleep 0.05; done
: > "$ST/calls.log"
rc=0; out=$(
    export REPO_ROOT="$ST/repo" WV="$ST/wv-stub" WV_GATE_JOBS=2 WV_GATE_SLOTS="$ST/s1"
    _pc_pool_reuse=off
    hook_duration_ms() { local t1; t1=$(wv_now ns); echo $(( (t1 - $1) / 1000000 )); }
    git -C "$REPO_ROOT" add -A
    export WV_GATE_TREE=$(git -C "$REPO_ROOT" write-tree)
    unset WV_GATE_BASE
    run_hook_suites <<< "0	tests/test-quick.sh	1" 2>&1) || rc=$?
wait "$hpid"
dur=$(sed -n 's/^test-record tests\/test-quick.sh .*--duration=\([0-9]*\).*/\1/p' "$ST/calls.log")
check "a suite that waited 1.5s for its slot passes" "0" "$rc"
check "...and is recorded from when it took the slot, well under the wait" "yes" \
    "$([ -n "$dur" ] && [ "$dur" -lt 1000 ] && echo yes || echo "no (duration=${dur:-none})")"
check "...and the suite itself never sees the slot settings" "unset unset unset" "$(cat "$ST/seen" 2>/dev/null)"
# Boundary rule 4: a lane runs this pool against HEAD's other gate files, so
# against a supervisor that may pass every variable through. The pool's own
# command must still keep the slot settings out of the suite, or a frozen
# suite's execution environment differs from the one its plan described
# (2026-11-03, the wv-gate-pool.sh lane of wv-428a92's first gate).
rm -f "$ST/seen"
rc=0; (
    export REPO_ROOT="$ST/repo" WV="$ST/wv-stub" WV_GATE_JOBS=1 WV_GATE_SLOTS="$ST/s1"
    _pc_pool_reuse=off _pc_pool_record=0
    gate_run_bounded() { shift 2; "$@"; }   # a supervisor that strips nothing
    git -C "$REPO_ROOT" add -A
    export WV_GATE_TREE=$(git -C "$REPO_ROOT" write-tree)
    unset WV_GATE_BASE
    run_hook_suites <<< "0	tests/test-quick.sh	1"
) >/dev/null 2>&1 || rc=$?
check "...even under a supervisor that passes every variable through" "0 unset unset unset" "$rc $(cat "$ST/seen" 2>/dev/null)"
# A waiter the stop flag turned back (rc "skip") is listed as not run, not
# FAILED, is never recorded, and does not fail the pool by itself.
skip_case() (
    _pc_out_dir="$ST/reap"; rm -rf "$_pc_out_dir"; mkdir -p "$_pc_out_dir"
    _pc_q_suite=([0]=tests/test-fails.sh [1]=tests/test-waited.sh) _pc_run_pid=([0]=1 [1]=2)
    _pc_q_mode=([0]=checkout [1]=checkout)
    _pc_run_done=() _pc_run_dur=() _pc_run_start=() _pc_run_end=() _pc_pool_failed=0 skipped=""
    hook_progress() { echo "$*"; }
    printf '3 10 1 2\n' > "$_pc_out_dir/0.rc"; printf 'skip 0 - -\n' > "$_pc_out_dir/1.rc"
    WV="$ST/wv-stub"; : > "$ST/calls.log"
    _pc_reap; _pc_record_all
    echo "failed=$_pc_pool_failed stop=$([ -e "$_pc_out_dir/stop" ] && echo yes || echo no) skipped=[$skipped]"
    echo "recorded=$(grep -c '^test-record' "$ST/calls.log")"
)
out=$(skip_case)
check "a failure raises the stop flag for waiters" "failed=1 stop=yes skipped=[tests/test-waited.sh]" "$(grep '^failed=' <<< "$out")"
check "...the stopped waiter is not reported FAILED" "0" "$(grep -c 'FAILED tests/test-waited.sh' <<< "$out")"
check "...and only the suite that ran is recorded" "recorded=1" "$(grep '^recorded=' <<< "$out")"

# elapsed_in_range <report> — "yes" when the supervisor's report is
# "<ms> monotonic" for the 0.2 s command below, else what it holds.
elapsed_in_range() {
    if [[ "$1" =~ ^([0-9]+)\ monotonic$ ]] && [ "${BASH_REMATCH[1]}" -ge 150 ] && [ "${BASH_REMATCH[1]}" -lt 5000 ]; then
        echo yes
    else
        echo "no (${1:-none})"
    fi
}
# suspend_supervisor_cases — the supervisor's elapsed report (wv-b17a85).
suspend_supervisor_cases() {
    local rc=0 out
    out=$(WV_GATE_ELAPSED="$ST/el" python3 -I "$SUP" el 60 bash -c 'sleep 0.2; echo "${WV_GATE_ELAPSED-unset}"') || rc=$?
    check "the supervisor reports the command's monotonic elapsed ms, and the setting does not reach the command" "0 unset yes" \
        "$rc $out $(elapsed_in_range "$(cat "$ST/el" 2>/dev/null)")"
    rc=0; WV_GATE_ELAPSED="$ST/no-such-dir/el" python3 -I "$SUP" el 60 sh -c 'exit 3' 2>/dev/null || rc=$?
    check "an elapsed report it cannot write never changes the command's status" "3" "$rc"
}
echo "time the host spends suspended is not suite time (wv-b17a85)"
# The supervisor times the command on the monotonic clock, which stops while
# the host is suspended, and the pool records that reading. The wall clock
# counts a suspend: here it reports two hours, as across a hibernation.
suspend_supervisor_cases
# suspended_pool [nosupervisor] — one suite through the pool, the wall clock
# reporting a two-hour suspend; prints the recorded duration.
suspended_pool() {
    : > "$ST/calls.log"
    (
        export REPO_ROOT="$ST/repo" WV="$ST/wv-stub" WV_GATE_JOBS=1
        unset WV_GATE_SLOTS WV_GATE_BASE
        _pc_pool_reuse=off
        hook_duration_ms() { echo 7200000; }
        [ "${1:-}" != nosupervisor ] || gate_run_bounded() { shift 2; "$@"; }
        git -C "$REPO_ROOT" add -A
        export WV_GATE_TREE=$(git -C "$REPO_ROOT" write-tree)
        run_hook_suites <<< "0	tests/test-quick.sh	1"
    ) >/dev/null 2>&1
    sed -n 's/^test-record tests\/test-quick.sh .*--duration=\([0-9]*\).*/\1/p' "$ST/calls.log"
}
dur=$(suspended_pool)
check "a suite whose wall time spans a suspend is recorded on the monotonic clock" "yes" \
    "$(if [ -n "$dur" ] && [ "$dur" -lt 7200000 ]; then echo yes; else echo "no (duration=${dur:-none})"; fi)"
check "(control) with no monotonic reading the pool falls back to the wall clock" "7200000" "$(suspended_pool nosupervisor)"
rm -rf "$ST"

echo "the pool bound takes a lane's bound first"
check "WV_GATE_JOBS alone" "3" "$(WV_GATE_JOBS=3 hook_gate_jobs)"
check "a lane's bound wins over WV_GATE_JOBS" "1" "$(WV_GATE_JOBS=3 WV_GATE_LANE_JOBS=1 hook_gate_jobs)"
check "neither set: 4" "4" "$(env -u WV_GATE_JOBS -u WV_GATE_LANE_JOBS bash -c '. "$1/scripts/lib/wv-gate-pool.sh"; hook_gate_jobs' _ "$ROOT")"

echo "a lane's pool settings do not reach a gate its suite runs (nested boundary, wv-6900e1)"
# A candidate lane's pool records nothing and reuses nothing (_pc_pool_record=0,
# _pc_pool_reuse=off), set as shell variables. A suite it runs may run a gate
# of its own (test-prepush-gate.sh drives the real pre-push hook), whose pool
# must record as usual: the pre-push hook sets _pc_pool_reuse itself but not
# _pc_pool_record, so an exported value would decide it. 2026-10-15: a test
# driver exporting both made test-prepush-gate.sh fail 6 assertions; only
# _pc_pool_record=0 mattered.
# Canonical from the start: the scratch allocator returns physical paths, and
# macOS TMPDIR (/var/folders) is a symlink to /private/var (wv-e6ca42).
NT=$(mktemp -d); NT=$(cd "$NT" && pwd -P)
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
# A suite whose passed checks are named after ENOSPC failed for another reason (wv-9cc226).
printf 'echo "  ✓ ENOSPC still fails the pool"; echo "  ✗ an unrelated check" >&2; exit 1\n' > "$NT/outer/tests/test-named.sh"
rc=0; out=$(scratch_pool test-named.sh) || rc=$?
check "a check named after ENOSPC fails the pool" "1" "$rc"
check "but is not labelled a storage failure" "no" "$([[ "$out" == *"RESOURCE:"* ]] && echo yes || echo no)"
# Keep-going is the pool's own control; a suite never sees it (wv-9cc226).
printf '[ -z "${WV_GATE_KEEP_GOING+x}" ] || { echo "saw WV_GATE_KEEP_GOING=$WV_GATE_KEEP_GOING"; exit 1; }\n' > "$NT/outer/tests/test-keepgoing.sh"
rc=0; out=$(WV_GATE_KEEP_GOING=1 scratch_pool test-keepgoing.sh) || rc=$?
check "a suite run under a keep-going pool does not see WV_GATE_KEEP_GOING" "0" "$rc"
rc=0; WV_GATE_KEEP_GOING=1 bash "$NT/outer/tests/test-keepgoing.sh" >/dev/null || rc=$?
check "(control) the probe refuses when the variable reaches it" "1" "$rc"

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
    out=$(bounded 15 bash -c '
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
# Keyed on the supervisor's own platform (python's), not bash's OSTYPE, which
# the macOS emulation fakes while python stays on Linux.
if [ "$(python3 -c 'import sys; print(sys.platform)')" = darwin ]; then
    # Stated residual (wv-412db3), as test-gate-recovery states for recovery:
    # on macOS the supervisor watches a private process group, and a daemon
    # that leaves it with setsid() escapes by definition; it is never sent
    # TERM, so its TERM-created child never exists. Linux owns descendants
    # as a subreaper and reaps both. Asserted so a change in either direction
    # is seen, then the escaped daemon is ended here.
    check "macOS: the setsid daemon escapes the group (stated residual)" "1" "$alive"
    check "macOS: ...so it was never sent TERM and made no child" "1" "$(wc -l < "$NT/daemon.pids" | tr -d ' ')"
    while read -r pid; do kill -KILL "$pid" 2>/dev/null || true; done < "$NT/daemon.pids"
else
    check "the detached daemon and its TERM-created child are both reaped" "0" "$alive"
    check "the TERM-created child actually ran" "2" "$(wc -l < "$NT/daemon.pids" | tr -d ' ')"
fi

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
rc=0; out=$(bounded 10 bash -c '
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
# macOS refuses killpg with EPERM once every member of the group has exited and
# only the unreaped root zombie is left; Linux signals it. Every gate suite and
# candidate lane on macOS then ended as status 2, whatever the suite returned
# (wv-5ab927, "Operation not permitted" on the macOS probe).
mac_killpg_supervisor() {
    python3 -c '
import os
import runpy
import subprocess
import sys
real_killpg = os.killpg
def mac_killpg(pgid, sig):
    rows = subprocess.run(["ps", "-axo", "pgid=,stat="], capture_output=True, text=True).stdout
    if not any(r.split()[0] == str(pgid) and not r.split()[1].startswith("Z") for r in rows.splitlines() if len(r.split()) == 2):
        raise PermissionError(1, "Operation not permitted")
    real_killpg(pgid, sig)
os.killpg = mac_killpg
module = runpy.run_path(sys.argv[1])
sys.platform = "darwin"
sys.argv = sys.argv[1:]
sys.exit(module["main"]())
' "$ROOT/scripts/lib/wv-gate-supervisor.py" "$@"
}
rc=0; out=$(mac_killpg_supervisor mac-success 5 sh -c 'printf mac-ran' 2>&1) || rc=$?
check "with macOS killpg semantics a finished command returns its own success" "0:mac-ran" "$rc:$out"
rc=0; out=$(mac_killpg_supervisor mac-failure 5 sh -c 'exit 37' 2>&1) || rc=$?
check "...and its own failure, not an ownership refusal" "37" "$rc"
# The failure report replays the harness's own refusal, which matches none of
# the suite markers (✗/FAIL/Error); on macOS it read as a bare exit 2.
printf '%s\n' "ok line" "gate supervisor: ownership/launch failed: [Errno 1] Operation not permitted (status 2)" \
    "usage: wv-gate-suite.py" "wv-gate-suite.py: error: unrecognized arguments: --x" > "$NT/refusal.out"
excerpt=$(_pc_failure_excerpt "$NT/refusal.out")
check "the failure report replays a supervisor refusal and an argparse error" "yes" \
    "$([[ "$excerpt" == *"gate supervisor: ownership/launch failed"* && "$excerpt" == *"error: unrecognized arguments"* && "$excerpt" != *"ok line"* ]] && echo yes || echo no)"
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

echo "the gate's python runs on a stock macOS python3 (3.9, wv-1d6c1e)"
# A hook runs whichever python3 its PATH finds first; on macOS /usr/bin/python3
# is 3.9, where an X | Y annotation is evaluated at def time and raises unless
# the module defers annotations. Checked on every python, run under 3.9 when
# one is installed.
py39_out=$(python3 -I - "$ROOT"/scripts/lib/*.py <<'PY'
import ast, sys
for path in sys.argv[1:]:
    tree = ast.parse(open(path, encoding="utf-8").read())
    deferred = any(isinstance(n, ast.ImportFrom) and n.module == "__future__"
                   and any(a.name == "annotations" for a in n.names) for n in tree.body)
    for node in ast.walk(tree):
        anns = []
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            a = node.args
            anns = [x.annotation for x in a.posonlyargs + a.args + a.kwonlyargs if x.annotation]
            anns += [x.annotation for x in (a.vararg, a.kwarg) if x is not None and x.annotation]
            anns += [node.returns] if node.returns else []
        elif isinstance(node, ast.AnnAssign):
            anns = [node.annotation]
        if not deferred and any(isinstance(m, ast.BinOp) and isinstance(m.op, ast.BitOr)
                                for x in anns for m in ast.walk(x)):
            print(f"{path.rsplit('/', 1)[-1]}:{node.lineno}")
PY
)
check "no scripts/lib python evaluates an X | Y annotation at import" "" "$py39_out"
py39=$(command -v python3.9 || { command -v uv >/dev/null 2>&1 && uv python find 3.9 2>/dev/null; } || true)
if [ -n "$py39" ] && [ -x "$py39" ]; then
    rc=0; out=$("$py39" -I "$SUP" probe 30 /bin/echo supervised-ok 2>&1) || rc=$?
    check "the supervisor runs a command under python 3.9" "0 supervised-ok" "$rc $(tail -1 <<< "$out")"
    # Frozen suite inputs hash with wv-gate-suite.digest; hashlib.file_digest
    # is 3.11+ (Mac run 44882350355).
    rc=0; out=$("$py39" -I - "$ROOT/scripts/lib/wv-gate-suite.py" "$SUP" <<'PY' 2>&1
import hashlib, importlib.util, pathlib, sys
spec = importlib.util.spec_from_file_location("wv_gate_suite", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
sys.modules["wv_gate_suite"] = mod
spec.loader.exec_module(mod)
path = pathlib.Path(sys.argv[2])
print(mod.digest(path) == hashlib.sha256(path.read_bytes()).hexdigest())
PY
) || rc=$?
    check "wv-gate-suite hashes frozen inputs under python 3.9" "0 True" "$rc $(tail -1 <<< "$out")"
else
    echo "  - skip: no python 3.9 here for the supervisor run (the annotation check above still ran)"
fi

echo "shared-helper refusals identify their failing operation and status"
rc=0; out=$(jq() { return 73; }; gate_pool_launch_order '[]' 2>&1) || rc=$?
check "unreadable launch selection fails" "1" "$rc"
check "unreadable launch selection names operation and original status" "yes" \
    "$([[ "$out" == *"gate_pool_launch_order"* && "$out" == *"status 73"* ]] && echo yes || echo no)"
printf 'not a tar archive\n' > "$NT/bad.tar"
# The status this host's tar gives a non-archive: GNU tar 2, bsdtar 1 (Mac
# round 3, wv-412db3). The helper must pass on whichever it got.
mkdir -p "$NT/tar-probe"; tar_st=0; tar -xf "$NT/bad.tar" -C "$NT/tar-probe" 2>/dev/null || tar_st=$?
rc=0; out=$(_gate_lane_build "$NT/bad-lane" "$NT/bad.tar" scripts/fixture 2>&1) || rc=$?
check "failed lane extraction refuses" "1" "$rc"
check "(control) this host's tar refuses a non-archive" "yes" "$([ "$tar_st" -ne 0 ] && echo yes || echo no)"
check "failed lane extraction names operation and the tar's own status" "yes" \
    "$([[ "$out" == *"extract"* && "$out" == *"status $tar_st)"* ]] && echo yes || echo no)"
rm -rf "$NT"

echo ""
echo "gate pool order: $pass/$run passed"
[ "$pass" -eq "$run" ]
