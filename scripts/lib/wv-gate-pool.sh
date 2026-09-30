#!/usr/bin/env bash
# wv-gate-pool.sh — the bounded parallel suite pool shared by the pre-commit
# and pre-push gates (wv-8138ec, wv-862ac0).
#
# Sourced by: scripts/hooks/pre-commit-weave.sh, scripts/hooks/pre-push-weave.sh
# The caller provides: hook_progress <msg>, hook_duration_ms <start_ns>,
# REPO_ROOT, WV, _pc_files_csv (the file set results are keyed on), and
# optionally _pc_pool_context (precommit|prepush, passed to suites as
# WV_GATE_CONTEXT) and _pc_pool_reuse (staged|worktree, which content the
# ledger reuse check fingerprints). Entry point: run_hook_suites.

# ── Suite pool (wv-8138ec) ── The selected suites run concurrently, at most
# hook_gate_jobs at a time. Every suite already isolates itself (temp hot zone,
# temp repos, temp HOME): make check runs the same suites four at a time through
# tests/run-all.sh. What the pool must not share is the ledger, so workers only
# run the suite and write "<rc> <ms>" to a file; the parent alone calls
# test-record, one suite at a time, after the last suite has finished (the
# ledger is in the live DB, which some suites read). Output is captured per
# suite and replayed in selection order, not interleaved.

# hook_gate_jobs — the pool bound: WV_GATE_JOBS, else 4 (run-all.sh's default
# too). WV_GATE_JOBS=1 is the serial gate. `wait -n` needs bash 4.3, so an
# older bash (macOS /bin/bash 3.2) runs serially. Not run-all.sh's test-jobs
# knob: tests/test-test-hook-registry.sh reads any name with that prefix in
# production code as a test-injection hook, which this is not.
hook_gate_jobs() {
    local j="${WV_GATE_JOBS:-4}"
    case "$j" in
        ''|*[!0-9]*|0)
            echo "Weave gate: WV_GATE_JOBS='$j' is not a positive integer — using 4" >&2
            j=4 ;;
    esac
    if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]:-0}" -lt 3 ]; }; then
        j=1
    fi
    echo "$j"
}

# gate_pool_estimates <suites-json> — set each suite's last_cost_s from the
# durable suite log's median (wv-ffda33), not the tmpfs ledger's last run: wv
# load wipes that, and one run in either direction skews it (test-release was
# quoted at ~209s against a 362s average). The median of RECENT runs where the
# log has it, because an all-history median lags a growing suite (wv-8138ec).
# One definition for both gates (ultrareview #4575).
gate_pool_estimates() {
    local hist
    hist=$("$WV" analyze suites --json 2>/dev/null || echo '{}')
    jq -c --argjson h "$hist" '
        (($h.suites // []) | map({key: .suite, value: (((.recent_p50_ms // .p50_ms) // 0) / 1000 | floor)}) | from_entries) as $m
        | map(.last_cost_s = (if ($m[.name] // 0) > 0 then $m[.name] else (.last_cost_s // 0) end))' \
        <<< "$1" 2>/dev/null || printf '%s' "$1"
}

# gate_pool_launch_order <suites-json> — the "<idx>\t<suite>\t<cost_s>" lines
# run_hook_suites reads: longest first (unmeasured count as longest), so the
# slowest suite is not the one left running alone at the end; idx keeps the
# selection order for the replay. Callers feed it through a herestring, not
# <(...): `wait -n` in the pool can also be satisfied by a process substitution.
gate_pool_launch_order() {
    jq -r 'to_entries
        | sort_by(if (.value.last_cost_s // 0) <= 0 then -1e9 else -(.value.last_cost_s) end)
        | .[] | [.key, .value.name, ((.value.last_cost_s // 0) | tostring)] | join("\t")' \
        <<< "$1" 2>/dev/null
}

# gate_isolated <command...> — run a TEST process without the git variables that
# locate a repository. Git runs hooks with GIT_INDEX_FILE set (a temporary
# index for 'git commit -- <paths>' and -a), and a test that runs git in its own
# temp repository then read and wrote THIS commit's index: "Error building
# trees" (wv-34ef3d). The hook's own reads of the staged blobs keep them.
gate_isolated() {
    env -u GIT_INDEX_FILE -u GIT_DIR -u GIT_WORK_TREE -u GIT_PREFIX -u GIT_COMMON_DIR \
        -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_NAMESPACE "$@"
}

# _pc_suite_worker <idx> <suite> — background body. The rc file is written via
# rename so the parent never reads half a line.
_pc_suite_worker() {
    local _w_t0 _w_rc
    _w_t0=$(date +%s%N 2>/dev/null || echo 0)
    # WV_GATE_CONTEXT lets a suite tell "you are the gate for a change that has
    # not landed" from "you are the full suite or a release gate". A suite that
    # cannot tell them apart has to pick one policy for a condition that is only
    # this caller's business in one of the two (wv-4ccafa).
    GIT_CONFIG_COUNT=1 \
        GIT_CONFIG_KEY_0=core.hooksPath \
        GIT_CONFIG_VALUE_0=/dev/null \
        WV_CALL_SOURCE=test \
        WV_GATE_CONTEXT="${_pc_pool_context:-precommit}" \
        gate_isolated bash "$REPO_ROOT/$2" </dev/null >"$_pc_out_dir/$1.out" 2>&1
    _w_rc=$?
    printf '%s %s\n' "$_w_rc" "$(hook_duration_ms "$_w_t0")" > "$_pc_out_dir/$1.rc.tmp" \
        && mv "$_pc_out_dir/$1.rc.tmp" "$_pc_out_dir/$1.rc"
}

# _pc_reap — note every finished suite and report it. Recording waits for
# _pc_record_all: the ledger lives in the live hot-zone DB, and a row written
# while a sibling is still running changes the graph under a suite that reads
# it (test-trailer-refs.sh hashes the live DB around its audit).
_pc_reap() {
    local i rc dur
    for i in "${!_pc_run_pid[@]}"; do
        [ -n "${_pc_run_done[$i]:-}" ] && continue
        [ -f "$_pc_out_dir/$i.rc" ] || continue
        read -r rc dur < "$_pc_out_dir/$i.rc"
        _pc_run_done[$i]="$rc"
        _pc_run_dur[$i]="$dur"
        if [ "$rc" = "0" ]; then
            hook_progress "passed ${_pc_q_suite[$i]} ($(( dur / 1000 ))s)"
        else
            hook_progress "FAILED ${_pc_q_suite[$i]} (exit $rc, $(( dur / 1000 ))s)"
            _pc_pool_failed=1
        fi
    done
}

# _pc_record_all — once no suite is running, write each result to the ledger
# (P6a) with its wall-clock cost (LL1), in selection order. Best-effort, keyed on
# the staged files' fingerprint.
_pc_record_all() {
    local i est
    for i in $(printf '%s\n' "${!_pc_run_done[@]}" | sort -n); do
        [ "${_pc_run_done[$i]}" = "lost" ] && continue
        est=""
        [ "${_pc_q_cost[$i]:-0}" -gt 0 ] 2>/dev/null && est=$(( _pc_q_cost[$i] * 1000 ))
        "$WV" test-record "${_pc_q_suite[$i]}" --files="${_pc_files_csv:-}" --exit="${_pc_run_done[$i]}" \
            --duration="${_pc_run_dur[$i]}" --estimate="$est" >/dev/null 2>&1 || true
    done
}

# _pc_descendants <pid> — every process below pid, deepest first.
_pc_descendants() {
    local child
    for child in $(pgrep -P "$1" 2>/dev/null); do
        _pc_descendants "$child"
        echo "$child"
    done
}

# _pc_pool_kill — Ctrl-C reaches the hook but not the workers: bash starts
# background jobs with SIGINT ignored when job control is off, so an
# interrupted gate would leave its suites running. Terminate them explicitly,
# the whole tree: signalling only the worker and its direct children left the
# suite's own processes (wv, sqlite3, whole sub-runs) running as orphans. The
# tree is listed before anything is signalled, since a killed parent's
# children are re-parented and could no longer be found (ultrareview widening).
_pc_pool_kill() {
    local i pids
    for i in "${!_pc_run_pid[@]}"; do
        [ -n "${_pc_run_done[$i]:-}" ] && continue
        [ "${_pc_run_pid[$i]}" -gt 0 ] 2>/dev/null || continue
        pids="$(_pc_descendants "${_pc_run_pid[$i]}") ${_pc_run_pid[$i]}"
        # shellcheck disable=SC2086  # a pid list, split on purpose
        kill -TERM $pids 2>/dev/null || true
    done
}

# run_hook_suites — reads "<idx>\t<suite>\t<cost_s>" lines (idx = selection
# order) from stdin in launch order, and exits 1 if any suite failed.
run_hook_suites() {
    local idx suite cost jobs i launched=0 failed_any=0 skipped="" rc
    # Sparse indexed arrays keyed by idx, not associative ones: those need bash 4
    # and this hook also runs under macOS /bin/bash 3.2.
    _pc_q_suite=() _pc_q_cost=() _pc_run_pid=() _pc_run_done=() _pc_run_dur=()
    local order=()
    while IFS=$'\t' read -r idx suite cost; do
        [ -n "$suite" ] || continue
        [ "$suite" = "tests/run-all.sh" ] && continue
        # Heuristic may map to a suite that doesn't exist yet — skip rather than fail.
        [ -f "$REPO_ROOT/$suite" ] || continue
        # A deliberately pre-run suite may already certify these exact index blobs.
        # Reuse only an all-files fresh green result; test-status returns non-zero
        # for a missing/wiped ledger, a failed row, a stale fingerprint, or a
        # partial file set, and older installed wv versions do not know the
        # command — every one of those cases falls through to real execution.
        # staged (pre-commit): the index blobs about to be committed; worktree
        # (pre-push, which first requires the tracked tree to equal the tip):
        # the working-tree blobs, i.e. the pushed content.
        local _reuse_flag=--staged
        [ "${_pc_pool_reuse:-staged}" = "worktree" ] && _reuse_flag=""
        # shellcheck disable=SC2086  # an empty flag must vanish, not be ""
        if "$WV" test-status "$suite" --files="${_pc_files_csv:-}" $_reuse_flag --quiet >/dev/null 2>&1; then
            hook_progress "reusing fresh green result for $suite (exact ${_pc_pool_reuse:-staged} content)"
            continue
        fi
        _pc_q_suite[$idx]="$suite"
        _pc_q_cost[$idx]="$cost"
        order+=("$idx")
    done
    [ "${#order[@]}" -gt 0 ] || return 0

    jobs=$(hook_gate_jobs)
    _pc_out_dir=$(mktemp -d "${TMPDIR:-/tmp}/wv-gate.XXXXXX") || {
        echo "✗ Weave gate: cannot create a suite output directory" >&2
        exit 1
    }
    _pc_pool_failed=0
    # Interrupted: note what already finished, stop the rest, and record the
    # finished results before leaving (ultrareview #4575) -- they are true of
    # this content, and a suite that was stopped is recorded as nothing.
    trap '_pc_reap; _pc_pool_kill; _pc_record_all; exit 130' INT TERM
    [ "$jobs" -gt 1 ] && [ "${#order[@]}" -gt 1 ] && \
        hook_progress "running ${#order[@]} suites, up to $jobs at a time"
    for idx in "${order[@]}"; do
        # After a failure no new suite starts: the gate has its verdict, and the
        # suites already running are left to finish so their results are whole.
        if [ "$_pc_pool_failed" = "1" ]; then
            skipped="${skipped:+$skipped, }${_pc_q_suite[$idx]}"
            continue
        fi
        while [ $(( launched - ${#_pc_run_done[@]} )) -ge "$jobs" ]; do
            wait -n 2>/dev/null
            rc=$?
            _pc_reap
            [ "$rc" = "127" ] && break
        done
        [ "$_pc_pool_failed" = "1" ] && { skipped="${skipped:+$skipped, }${_pc_q_suite[$idx]}"; continue; }
        cost="${_pc_q_cost[$idx]}"
        # A suite with no recorded wall time must not announce "~0s": that reads as
        # a measurement of a fast suite, and an operator who then waits two minutes
        # for a silent gate concludes it hung and interrupts it, losing the commit.
        if [ -n "$cost" ] && [ "$cost" -gt 0 ] 2>/dev/null; then
            hook_progress "running ${_pc_q_suite[$idx]} (~${cost}s)..."
        else
            hook_progress "running ${_pc_q_suite[$idx]} (duration not yet measured)..."
        fi
        launched=$(( launched + 1 ))
        if [ "$jobs" -eq 1 ]; then
            # Serial: foreground, no `wait -n`, so it also runs under bash < 4.3.
            _pc_run_pid[$idx]=0
            _pc_suite_worker "$idx" "${_pc_q_suite[$idx]}"
            _pc_reap
        else
            _pc_suite_worker "$idx" "${_pc_q_suite[$idx]}" &
            _pc_run_pid[$idx]=$!
        fi
    done
    while [ "${#_pc_run_done[@]}" -lt "$launched" ]; do
        wait -n 2>/dev/null
        rc=$?
        _pc_reap
        [ "$rc" = "127" ] && break
    done
    trap - INT TERM

    # A worker that vanished without writing its result (killed from outside)
    # is a failure, never a pass.
    for i in "${!_pc_run_pid[@]}"; do
        if [ -z "${_pc_run_done[$i]:-}" ]; then
            _pc_run_done[$i]="lost"
            _pc_run_dur[$i]=0
        fi
    done
    _pc_record_all

    # Replay failures in selection order, with the lines that name the failing
    # assertions. The full output stays on disk; passing suites' output does not.
    for i in $(printf '%s\n' "${!_pc_run_pid[@]}" | sort -n); do
        [ "${_pc_run_done[$i]}" = "0" ] && continue
        failed_any=1
        echo "" >&2
        if [ "${_pc_run_done[$i]}" = "lost" ]; then
            echo "✗ ${_pc_q_suite[$i]} failed — it exited without reporting a result" >&2
        else
            echo "✗ ${_pc_q_suite[$i]} failed (exit ${_pc_run_done[$i]}) — run manually to see details:" >&2
        fi
        echo "  bash ${_pc_q_suite[$i]}" >&2
        if [ -s "$_pc_out_dir/$i.out" ]; then
            sed 's/\x1b\[[0-9;]*m//g' "$_pc_out_dir/$i.out" \
                | awk '!/✓/ && /✗|FAIL|Error/ && shown < 15 { print "    " $0; shown++ }' >&2
            echo "  full output: $_pc_out_dir/$i.out" >&2
        fi
    done
    if [ "$failed_any" = "1" ]; then
        [ -n "$skipped" ] && echo "  not run after the failure: $skipped" >&2
        echo "" >&2
        exit 1
    fi
    rm -rf "$_pc_out_dir"
}
