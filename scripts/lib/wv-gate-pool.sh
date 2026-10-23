#!/usr/bin/env bash
# wv-gate-pool.sh — the bounded parallel suite pool shared by the pre-commit
# and pre-push gates (wv-8138ec, wv-862ac0).
#
# Sourced by: scripts/hooks/pre-commit-weave.sh, scripts/hooks/pre-push-weave.sh
# The caller provides: hook_progress <msg>, hook_duration_ms <start_ns>,
# REPO_ROOT, WV, _pc_files_csv (the file set results are keyed on), and
# optionally _pc_pool_context (precommit|prepush, passed to suites as
# WV_GATE_CONTEXT), _pc_pool_reuse (staged|worktree, which content the
# ledger reuse check fingerprints; off, none: every suite runs) and
# _pc_pool_record (0: write no ledger rows; a candidate lane, S2b wv-7ee8fe).
# Entry point: run_hook_suites.

# Resolve beside this pool, including in a protected candidate tree.
# shellcheck source=scripts/lib/wv-scratch.sh
source "$(dirname "${BASH_SOURCE[0]}")/wv-scratch.sh"
_GATE_SUITE_LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
unset WV_GATE_EXECUTION_MODE

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
# WV_GATE_LANE_JOBS comes first: it is a candidate lane's share of the bound,
# set by gate_lanes_run (wv-d7af8d). A name of its own, because config.env,
# which the hook sources with set -a, could otherwise replace the share with
# the user's WV_GATE_JOBS; the suite worker strips it, so no suite inherits it.
hook_gate_jobs() {
    local j="${WV_GATE_LANE_JOBS:-${WV_GATE_JOBS:-4}}"
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
# gate_pool_require_present <suites-json> <present-fn> <retired-record-text>
# — the selection without the suites that may be absent, on stdout. present-fn
# <suite> answers 0 present, 1 absent, anything else unknown. A suggestion
# (declared false: the naming heuristic, a changed suite's own run) may be
# absent, and so may a declared suite the retirement record names; any other
# declared suite that is absent refuses the gate: a preserved route whose suite
# is gone is not a passed check (R3, wv-fb861c). A selection from a router that
# does not say counts every suite as declared. Exits 1 on a refusal; callers
# run it in a command substitution and must check its status.
gate_pool_require_present() {
    local json=$1 present=$2 retired=$3 name declared rc drop='[]'
    while IFS=$'\t' read -r name declared; do
        [ -n "$name" ] || continue
        rc=0; "$present" "$name" || rc=$?
        case "$rc" in
            0) continue ;;
            1) ;;
            *) echo "✗ Weave gate: $present $name (status $rc): cannot tell whether the selected suite is present — refusing" >&2
               exit 1 ;;
        esac
        if [ "$declared" = true ]; then
            if ! awk -v s="$name" '$0 !~ /^[[:space:]]*#/ && $2 == s { f = 1 } END { exit !f }' <<< "$retired"; then
                echo "✗ Weave gate: the test map selects $name, but the judged tree does not contain it — refusing rather than counting it as passed." >&2
                echo "  To delete a suite, first commit its retirement (.weave/test-map-retired.conf) with its routes removed, then delete it (wv-fb861c)." >&2
                exit 1
            fi
            hook_progress "selected suite $name is absent and retired; not run"
        else
            hook_progress "suggested suite $name does not exist; not run"
        fi
        drop=$(jq -c --arg n "$name" '. + [$n]' <<< "$drop") || { echo "gate_pool_require_present: build exclusions (status $?) — refusing" >&2; exit 1; }
    done < <(jq -r '.[] | [.name, (if has("declared") then .declared else true end | tostring)] | @tsv' <<< "$json")
    wait $! || { echo "gate_pool_require_present: could not read the suite selection (status $?) — refusing" >&2; exit 1; }
    jq -c --argjson d "$drop" 'map(select(.name as $n | $d | index($n) | not))' <<< "$json" \
        || { echo "gate_pool_require_present: filter selection (status $?) — refusing" >&2; exit 1; }
}

gate_pool_estimates() {
    local hist
    hist=$("$WV" analyze suites --json 2>/dev/null || echo '{}')
    jq -c --argjson h "$hist" '
        (($h.suites // []) | map({key: .suite, value: (((.recent_p50_ms // .p50_ms) // 0) / 1000 | floor)}) | from_entries) as $m
        | map(.last_cost_s = (if ($m[.name] // 0) > 0 then $m[.name] else (.last_cost_s // 0) end))' \
        <<< "$1" 2>/dev/null || printf '%s' "$1"
}

# gate_pool_launch_order <suites-json> — the "<idx>\t<suite>\t<cost_s>" lines
# run_hook_suites reads. Suites measured at GATE_POOL_FAST_S or less go first,
# then the rest; within each group longest first (unmeasured count as
# longest), so the slowest suite is not the one left running alone at the end.
# idx keeps the selection order for the replay. Callers feed it through a
# herestring, not <(...): `wait -n` in the pool can also be satisfied by a
# process substitution.
# Why the fast group first (wv-d7af8d): after a failure no new suite starts but
# running ones finish, so a cheap suite launched last reported its failure
# only after the long suites ended. 47 of 54 failed gates from 2026-10-01 to
# 10-14 failed on a suite with a median of 60s or less. Simulated on those and
# 234 green gates, 20s first cut failure verdicts by 43% for 4.4% longer green
# runs; 60s was a net loss. That is a simulation until gates measure it.
GATE_POOL_FAST_S=20
gate_pool_launch_order() {
    jq -r --argjson fast "$GATE_POOL_FAST_S" 'to_entries
        | sort_by((.value.last_cost_s // 0) as $c
            | [(if $c > 0 and $c <= $fast then 0 else 1 end), (if $c <= 0 then -1e9 else -$c end)])
        | .[] | [.key, .value.name, ((.value.last_cost_s // 0) | tostring)] | join("\t")' \
        <<< "$1" || { echo "gate_pool_launch_order: decode/order selection (status $?) — refusing" >&2; return 1; }
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

# ── Live hot-zone leak guard (wv-e200f6) ── The header above says every suite
# isolates itself. Two did not: their temp repositories ran wv with default
# placement, so each run left a per-repository directory in the LIVE hot zone,
# owned by a repository the suite's trap had already deleted (40 such orphans
# by 2026-10-07). The pool now checks the claim instead of assuming it: it
# lists the live zones' per-repository directories before the suites start,
# and fails the gate on any that appeared since and belongs to a temporary or
# vanished repository. A real repository on this host opening its zone
# meanwhile is not a leak and is not reported. Nothing is removed here.
#
# Ownership (wv-7061a0). Candidate lanes run their pools at the same time,
# and a before/after scan of the live root cannot tell this pool's zones from
# a sibling's: one lane refused a commit on a sibling's in-flight zones, gone
# minutes later. Each pool gives its suites a tag (WV_GATE_POOL_TAG) that wv
# stamps beside a zone's .repo_root, and judges only zones carrying its own
# tag; a sibling's are the sibling's to judge. A zone with no tag was made
# outside any gate pool (another session's suites), or by a suite that cleared
# its whole environment, and is reported without failing this gate, since
# nothing says it is this pool's. Placement is not moved: a private zone root
# per pool would also move suites that read this repository's own live graph
# (test-trailer-refs.sh audits a copy of it, and skips when it finds none).

# _pc_live_zones — each live hot-zone base once, by physical path: both names
# of the /tmp zone, /dev/shm/weave and /tmp/weave-<uid>. Under WV_TEST_MODE=1,
# WV_TEST_HOT_ZONE_ROOT prefixes them, as the resolver does, so a test of
# this guard never touches the real zone.
_pc_live_zones() {
    local root="" z
    if [ "${WV_TEST_MODE:-}" = "1" ] && [ "${WV_TEST_HOT_ZONE_ROOT:0:1}" = "/" ]; then
        root="${WV_TEST_HOT_ZONE_ROOT%/}"
    fi
    for z in "$root/tmp/weave-hotzone-$UID" "$root/tmp/weave-codex-$UID" \
             "$root/dev/shm/weave" "$root/tmp/weave-$UID"; do
        [ -d "$z" ] && (cd "$z" 2>/dev/null && pwd -P)
    done | LC_ALL=C sort -u
}

# _pc_zone_entries — every per-repository directory in the live zones, sorted.
# A herestring, not <(...): a process substitution can satisfy the pool's
# `wait -n` (see gate_pool_launch_order).
_pc_zone_entries() {
    local z d zones
    zones=$(_pc_live_zones)
    [ -n "$zones" ] || return 0
    while IFS= read -r z; do
        for d in "$z"/*/; do
            [ -d "$d" ] && printf '%s\n' "${d%/}"
        done
    done <<< "$zones" | LC_ALL=C sort
}

# _pc_zone_leaks <before> — each per-repository directory that appeared since
# the sorted list <before> and whose .repo_root names a repository that no
# longer exists or lives under the temp directory, with that owner, when its
# .gate_pool is this pool's tag (_pc_pool_tag). Untagged ones print with an
# "untagged" mark for the caller to report; another pool's are skipped. A
# zone with no .repo_root yet is not judged. wv init stamps one only when it
# can name the owner (WV_PROJECT_DIR or the working directory's git toplevel,
# wv-29e416); an init from outside any repository leaves it to the first later
# command's db_ensure.
_pc_zone_leaks() {
    local d owner tag tmp="${TMPDIR:-/tmp}"
    tmp="${tmp%/}"
    _pc_zone_entries | LC_ALL=C comm -13 "$1" - | while IFS= read -r d; do
        owner=$(cat "$d/.repo_root" 2>/dev/null)
        [ -n "$owner" ] || continue
        [ ! -d "$owner" ] || [[ "$owner" == "$tmp"/* || "$owner" == "${_pc_out_dir:-/nonexistent}"/* ]] || continue
        tag=$(cat "$d/.gate_pool" 2>/dev/null)
        if [ -z "$tag" ]; then
            printf 'untagged\t%s  (owner %s)\n' "$d" "$owner"
            continue
        fi
        [ "$tag" = "${_pc_pool_tag:-}" ] || continue
        printf '%s  (owner %s)\n' "$d" "$owner"
    done
}

# ── Real call-log leak guard (wv-6b0f57) ── config.env enables the user's
# durable call log for every wv process, and suites isolated the graph but not
# that: 12k+ rows from temp repositories by 2026-10-07, enough to rotate real
# history out. Every suite exports WV_TEST_SUITE=1, under which config.env
# cannot enable the log, and so does the worker below, for a suite that cannot
# carry it yet (test-call-log-isolation.sh names the exemptions; a suite run on
# its own is held to its export by that file's structural check). The gate
# checks the outcome: it notes the log before the suites start and fails on any
# row appended since that is tagged source=test or names a repository under the
# temp directory, which is how a suite escaping the marker shows. The user's
# own wv calls meanwhile are neither.

# _pc_inode <file> — its inode number, or 0. ls, not stat: the flags differ on
# macOS, where this pool also runs.
_pc_inode() {
    local out
    out=$(ls -di -- "$1" 2>/dev/null) || { echo 0; return; }
    echo "${out%% *}"
}

# _pc_call_log_mark — "<log>\t<inode>\t<bytes>" for the call log the user's
# config writes, or nothing when it is off. Asked of wv, so a gate nested in a
# suite (WV_TEST_SUITE=1) finds it off and checks nothing.
_pc_call_log_mark() {
    local log
    log=$("$WV" config get WV_CALL_LOG 2>/dev/null) || return 0
    [ -n "$log" ] || return 0
    printf '%s\t%s\t%s\n' "$log" "$(_pc_inode "$log")" "$(wc -c < "$log" 2>/dev/null || echo 0)"
}

# _pc_call_log_leaks <mark-file> — the rows a suite appended to the log since
# the mark: a count line, then up to five of them. A log rotated meanwhile is
# read from the mark on in <log>.1 and whole in <log>.
_pc_call_log_leaks() {
    local log ino size tmp="${TMPDIR:-/tmp}"
    IFS=$'\t' read -r log ino size < "$1" 2>/dev/null || return 0
    [ -n "$log" ] || return 0
    tmp="${tmp%/}/"
    {
        if [ "$ino" != "0" ] && [ "$(_pc_inode "$log")" = "$ino" ]; then
            tail -c +"$(( size + 1 ))" -- "$log"
        else
            [ "$ino" != "0" ] && [ "$(_pc_inode "$log.1")" = "$ino" ] && tail -c +"$(( size + 1 ))" -- "$log.1"
            cat -- "$log"
        fi
    } 2>/dev/null | jq -Rnr --arg tmp "$tmp" '
        [inputs | fromjson? // empty
         | select(.source == "test" or ((.repo_root // "") | startswith($tmp)))]
        | select(length > 0)
        | "\(length)", (.[:5][] | "\(.cmd)  (source \(.source), repo \(.repo_root))")' 2>/dev/null || true
}

# _pc_ns_to_ms <ns> — epoch milliseconds from a `date +%s%N` reading, or "-"
# where date has no %N (BSD prints a literal N) or the reading failed.
_pc_ns_to_ms() {
    case "$1" in ''|0|*[!0-9]*) echo - ;; *) echo $(( $1 / 1000000 )) ;; esac
}

# gate_run_bounded <label> <seconds> <command...> — used only in a worker
# subshell. The Python supervisor owns descendants on Linux, or a private
# process group on macOS; this worker forwards cancellation and awaits cleanup.
# Resolve beside the protected pool, never through the judged working tree.
gate_run_bounded() {
    local pid="" rc=0 saved cancelled=0
    saved=$(trap -p INT TERM HUP)
    trap 'cancelled=1; if [ -n "$pid" ]; then kill -TERM "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null; exit 143; fi' INT TERM HUP
    python3 -I "$(dirname "${BASH_SOURCE[0]}")/wv-gate-supervisor.py" "$@" &
    pid=$!
    if [ "$cancelled" -eq 1 ]; then
        kill -TERM "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        exit 143
    fi
    wait "$pid" || rc=$?
    trap - INT TERM HUP
    [ -z "$saved" ] || eval "$saved"
    return "$rc"
}

# _pc_suite_worker <idx> <suite> — background body. The rc file is written via
# rename so the parent never reads half a line. It holds "<rc> <ms> <start>
# <end>": the suite's start and exit in epoch ms, read here as it starts and
# exits (wv-4666cb). The suite log's ts is the drain time, written after the
# last suite ends, so a failure's own time can only come from these.
_pc_suite_worker() {
    local _w_t0 _w_t1 _w_rc
    local WV_GATE_EXECUTION_MODE="${_pc_q_mode[$1]}"
    local plan_args=()
    [ "$WV_GATE_EXECUTION_MODE" != frozen ] || plan_args=(--plan "$_pc_out_dir/plan.json")
    _w_t0=$(date +%s%N 2>/dev/null || echo 0)
    # Like gate_isolated, but clear the worker's own environment before the
    # supervisor forks, so its PID is also the PID cancellation can signal.
    unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_PREFIX GIT_COMMON_DIR \
        GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE
    # WV_GATE_CONTEXT lets a suite tell "you are the gate for a change that has
    # not landed" from "you are the full suite or a release gate". A suite that
    # cannot tell them apart has to pick one policy for a condition that is only
    # this caller's business in one of the two (wv-4ccafa).
    # WV_CALL_LOG is dropped: the hook sourced config.env with set -a, so it is
    # exported here, and a suite inheriting it has named the user's log as its
    # own; WV_TEST_SUITE=1 keeps only a log the environment chose (wv-6b0f57).
    # Imports read shared source; they must not write __pycache__ beside it.
    GIT_CONFIG_COUNT=1 \
        GIT_CONFIG_KEY_0=core.hooksPath \
        GIT_CONFIG_VALUE_0=/dev/null \
        WV_CALL_SOURCE=test \
        WV_TEST_SUITE=1 \
        PYTHONDONTWRITEBYTECODE=1 \
        WV_GATE_CONTEXT="${_pc_pool_context:-precommit}" \
        WV_GATE_BASE="$_pc_suite_base" \
        WV_GATE_POOL_TAG="$_pc_pool_tag" \
        TMPDIR="$_pc_out_dir/scratch" \
        gate_run_bounded "$2" "${WV_GATE_TIMEOUT:-1800}" \
        env -u WV_CALL_LOG -u WV_GATE_LANE_JOBS -u WV_SCRATCH_ROOT \
        "${_pc_snapshot_args[@]}" "${plan_args[@]}" \
        --work "$_pc_out_dir/scratch/$1" --provenance "$_pc_out_dir/$1.identity.json" \
        "$2" </dev/null >"$_pc_out_dir/$1.out" 2>&1
    _w_rc=$?
    if [ "$_w_rc" = 0 ] && [ "$WV_GATE_EXECUTION_MODE" = frozen ] \
        && ! jq -e --arg suite "$2" --slurpfile plan "$_pc_out_dir/plan.json" \
        '.suite == $suite and .tree == $plan[0].tree and .base == $plan[0].base
         and .execution_mode == "frozen" and .key == $plan[0].suites[$suite].key' "$_pc_out_dir/$1.identity.json" >/dev/null 2>&1; then
        echo "✗ frozen suite receipt does not match its planned inputs" >> "$_pc_out_dir/$1.out"
        _w_rc=1
    fi
    _w_t1=$(date +%s%N 2>/dev/null || echo 0)
    printf '%s %s %s %s\n' "$_w_rc" "$(hook_duration_ms "$_w_t0")" "$(_pc_ns_to_ms "$_w_t0")" "$(_pc_ns_to_ms "$_w_t1")" \
        > "$_pc_out_dir/$1.rc.tmp" && mv "$_pc_out_dir/$1.rc.tmp" "$_pc_out_dir/$1.rc"
}

# _pc_reap — note every finished suite and report it. Recording waits for
# _pc_record_all: the ledger lives in the live hot-zone DB, and a row written
# while a sibling is still running changes the graph under a suite that reads
# it (test-trailer-refs.sh hashes the live DB around its audit).
_pc_reap() {
    local i rc dur start end
    for i in "${!_pc_run_pid[@]}"; do
        [ -n "${_pc_run_done[$i]:-}" ] && continue
        [ -f "$_pc_out_dir/$i.rc" ] || continue
        read -r rc dur start end < "$_pc_out_dir/$i.rc"
        _pc_run_done[$i]="$rc"
        _pc_run_dur[$i]="$dur"
        _pc_run_start[$i]="$start"
        _pc_run_end[$i]="$end"
        if [ "$rc" = "0" ]; then
            hook_progress "passed ${_pc_q_suite[$i]} ($(( dur / 1000 ))s)"
        else
            hook_progress "FAILED ${_pc_q_suite[$i]} (exit $rc, $(( dur / 1000 ))s)"
            _pc_pool_failed=1
        fi
    done
}

# _pc_record_all — once no suite is running, record its immutable planned key
# and wall-clock cost, in selection order. A live edit cannot change the bytes
# this suite tested, or turn that result into certification of the new edit.
_pc_record_all() {
    local i est key mode
    local plan_args=()
    [ "${_pc_pool_record:-1}" = "0" ] && return 0
    for i in $(printf '%s\n' "${!_pc_run_done[@]}" | sort -n); do
        [ "${_pc_run_done[$i]}" = "lost" ] && continue
        est=""
        [ "${_pc_q_cost[$i]:-0}" -gt 0 ] 2>/dev/null && est=$(( _pc_q_cost[$i] * 1000 ))
        key=""
        mode=${_pc_q_mode[$i]}
        plan_args=()
        if [ "$mode" = frozen ]; then
            key=$(jq -r --arg s "${_pc_q_suite[$i]}" '.suites[$s].key' "$_pc_out_dir/plan.json")
            plan_args=(--snapshot-plan="$_pc_out_dir/plan.json")
        fi
        "$WV" test-record "${_pc_q_suite[$i]}" --files="${_pc_files_csv:-}" --exit="${_pc_run_done[$i]}" \
            --execution-mode="$mode" \
            --duration="${_pc_run_dur[$i]}" --estimate="$est" ${key:+--inputs-key="$key"} \
            "${plan_args[@]}" \
            --started-ms="${_pc_run_start[$i]:-}" --ended-ms="${_pc_run_end[$i]:-}" \
            --start-fingerprints="$_pc_out_dir/start.fps" >/dev/null 2>&1 || true
    done
}

# _pc_pool_kill — Ctrl-C reaches the hook but not the workers: bash starts
# background jobs with SIGINT ignored when job control is off, so an
# interrupted gate would leave its suites running. Workers forward TERM to
# their supervisors; wait until each has drained its owned descendants.
_pc_pool_kill() {
    local i
    for i in "${!_pc_run_pid[@]}"; do
        [ -n "${_pc_run_done[$i]:-}" ] && continue
        [ "${_pc_run_pid[$i]}" -gt 0 ] 2>/dev/null || continue
        kill -TERM "${_pc_run_pid[$i]}" 2>/dev/null || true
    done
    for i in "${!_pc_run_pid[@]}"; do
        wait "${_pc_run_pid[$i]}" 2>/dev/null || true
    done
}

# gate_pool_execution_mode <candidate-tree> — also called before hooks' early
# no-suite exits, so an unsupported declaration cannot slip into the base.
gate_pool_execution_mode() {
    # One loader owns both hooks' validation and per-suite adoption. It reads
    # protected Git blobs, never the checkout file or an inherited mode.
    local head args=()
    head=$(git -C "$REPO_ROOT" rev-parse --verify --quiet 'HEAD^{commit}') || head=""
    [ -z "$head" ] || args+=(--base "$head")
    if ! _GATE_PROVISION=$(python3 -I "$_GATE_SUITE_LIB/wv-gate-suite.py" \
        --declarations --policy "$_GATE_SUITE_LIB/wv-gate-provision.json" \
        --repo "$REPO_ROOT" --tree "$1" "${args[@]}"); then
        echo "✗ Weave gate: cannot inspect provisioning declaration — refusing before mode selection" >&2
        exit 1
    fi
    WV_GATE_EXECUTION_MODE=$(jq -r '
        if .policy == null then .default_mode
        elif (.policy.suites | length) == 0 then "checkout" else "mixed" end' <<< "$_GATE_PROVISION") || exit 1
    export WV_GATE_EXECUTION_MODE
}

# gate_pool_suite_mode <suite> — absent means checkout, never an installed
# default, except while bootstrapping the legacy self-host policy.
gate_pool_suite_mode() {
    jq -r --arg s "$1" '
        if .policy == null then .default_mode
        elif (.policy.suites | has($s)) then "frozen" else "checkout" end' <<< "$_GATE_PROVISION"
}

# run_hook_suites — reads "<idx>\t<suite>\t<cost_s>" lines (idx = selection
# order) from stdin in launch order, and exits 1 if any suite failed.
run_hook_suites() {
    local idx suite cost jobs i launched=0 failed_any=0 skipped="" rc
    local _pc_suite_tree="${WV_GATE_TREE:-}" _pc_suite_base="${WV_GATE_BASE:-}"
    local _pc_snapshot_args=() names=()
    # Hooks provide frozen identities. Standalone pools freeze once too; a
    # push judges HEAD, not an index left over from an enclosing commit gate.
    if [ "${_pc_pool_context:-precommit}" = prepush ]; then
        if ! _pc_suite_tree=$(git -C "$REPO_ROOT" rev-parse --verify 'HEAD^{tree}') \
            || ! _pc_suite_base=$(git -C "$REPO_ROOT" rev-parse --verify 'HEAD^{commit}'); then
            echo "✗ Weave gate: cannot freeze pushed suite inputs (git rev-parse failed) — refusing" >&2
            exit 1
        fi
    elif [ -z "$_pc_suite_tree" ]; then
        _pc_suite_tree=$(git -C "$REPO_ROOT" write-tree) || {
            echo "✗ Weave gate: cannot freeze staged suite inputs (git write-tree failed) — refusing" >&2
            exit 1
        }
    fi
    if [ -z "$_pc_suite_base" ]; then
        _pc_suite_base=$(git -C "$REPO_ROOT" rev-parse --verify --quiet 'HEAD^{commit}') || _pc_suite_base=""
    fi
    gate_pool_execution_mode "$_pc_suite_tree"
    hook_progress "execution mode: $WV_GATE_EXECUTION_MODE"
    _pc_snapshot_args=(python3 -I "$_GATE_SUITE_LIB/wv-gate-suite.py" --repo "$REPO_ROOT"
        --tree "$_pc_suite_tree" --mode auto --policy "$_GATE_SUITE_LIB/wv-gate-provision.json")
    [ -z "$_pc_suite_base" ] || _pc_snapshot_args+=(--base "$_pc_suite_base")
    [ -z "${_PC_EXEC_TREE:-}" ] || _pc_snapshot_args+=(--authority "$_PC_EXEC_TREE")
    # Sparse indexed arrays keyed by idx, not associative ones: those need bash 4
    # and this hook also runs under macOS /bin/bash 3.2.
    _pc_q_suite=() _pc_q_cost=() _pc_q_mode=() _pc_run_pid=() _pc_run_done=() _pc_run_dur=()
    _pc_run_start=() _pc_run_end=()
    local order=() cand=() cand_csv states reuse_t0 frozen_names=()
    while IFS=$'\t' read -r idx suite cost; do
        [ -n "$suite" ] || continue
        [ "$suite" = "tests/run-all.sh" ] && continue
        # A selected suite that is not there is not a passed one (R3,
        # wv-fb861c). The hooks drop absent suggestions and retired suites
        # first (gate_pool_require_present); anything absent here refuses.
        if ! git -C "$REPO_ROOT" cat-file -e "$_pc_suite_tree:$suite" 2>/dev/null; then
            echo "✗ Weave gate: the selected suite $suite does not exist — refusing rather than counting it as passed" >&2
            exit 1
        fi
        _pc_q_suite[$idx]="$suite"
        _pc_q_cost[$idx]="$cost"
        _pc_q_mode[$idx]=$(gate_pool_suite_mode "$suite") || exit 1
        [ "${_pc_q_mode[$idx]}" != frozen ] || frozen_names+=("$suite")
        cand+=("$idx")
    done
    [ "${#cand[@]}" -gt 0 ] || return 0
    # Describe before provisioning, then use that one frozen plan both for
    # reuse and execution. Legacy live-checkout keys cannot match these keys.
    # A missing ledger or an older CLI falls through to actual execution.
    cand_csv=$(printf '%s\n' "${frozen_names[@]}" | paste -sd ',' -)
    _pc_out_dir=$(wv_scratch_create) || {
        echo "✗ Weave gate: cannot create a suite output directory (status $?) — refusing" >&2
        exit 1
    }
    mkdir "$_pc_out_dir/scratch" || {
        echo "✗ Weave gate: cannot create private suite scratch (status $?) — refusing" >&2
        rm -rf "$_pc_out_dir"; exit 1
    }
    for idx in "${cand[@]}"; do names+=("${_pc_q_suite[$idx]}"); done
    if [ "${#frozen_names[@]}" -gt 0 ] && ! WV_GATE_CONTEXT="${_pc_pool_context:-precommit}" \
        PYTHONDONTWRITEBYTECODE=1 \
        env -u WV_CALL_LOG -u WV_GATE_LANE_JOBS -u WV_SCRATCH_ROOT \
        "${_pc_snapshot_args[@]}" --describe --work "$_pc_out_dir/scratch/description" \
        --provenance "$_pc_out_dir/plan.json" "${names[@]}"; then
        echo "✗ Weave gate: cannot establish frozen suite inputs — refusing" >&2
        rm -rf "$_pc_out_dir/scratch"
        exit 1
    fi
    reuse_t0=$(date +%s%N 2>/dev/null || echo 0)
    states=""
    if [ "${#frozen_names[@]}" -eq 0 ]; then
        hook_progress "checkout inputs are mutable: reuse disabled for ${#cand[@]} suite(s)"
    elif [ "${_pc_pool_reuse:-staged}" = "off" ]; then
        hook_progress "reuse off: ${#cand[@]} suite(s) run as this lane's code runs them"
    else
        states=$("$WV" test-status --inputs --suites="$cand_csv" \
            --snapshot-plan="$_pc_out_dir/plan.json" 2>/dev/null) || states=""
        hook_progress "reuse check: ${#cand[@]} suite(s) in $(hook_duration_ms "$reuse_t0")ms"
    fi
    for idx in "${cand[@]}"; do
        if [ "${_pc_q_mode[$idx]}" = frozen ] \
            && awk -F'\t' -v s="${_pc_q_suite[$idx]}" '$1 == "green" && $3 == s { f = 1 } END { exit !f }' <<< "$states"; then
            hook_progress "reusing fresh green result for ${_pc_q_suite[$idx]} (exact frozen execution inputs)"
            unset "_pc_q_suite[$idx]" "_pc_q_cost[$idx]"
            continue
        fi
        order+=("$idx")
    done
    [ "${#order[@]}" -gt 0 ] || { rm -rf "$_pc_out_dir"; return 0; }

    jobs=$(hook_gate_jobs)
    _pc_pool_failed=0
    # Preserve per-file readiness only for the frozen blobs actually tested.
    # test-record refuses freshness when the live bytes do not match these.
    : > "$_pc_out_dir/start.fps"
    local file blob
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        blob=$(git -C "$REPO_ROOT" rev-parse --verify "$_pc_suite_tree:$file" 2>/dev/null) || blob=missing
        printf '%s\t%s\n' "$blob" "$file" >> "$_pc_out_dir/start.fps"
    done < <(printf '%s\n' "${_pc_files_csv:-}" | tr ',' '\n')
    # The live zones and the user's call log before any suite runs (wv-e200f6,
    # wv-6b0f57), and the tag this pool's suites stamp on the zones they make
    # (wv-7061a0): its output directory is unique to it.
    _pc_pool_tag="wv-gate.${_pc_out_dir##*/}-$$"
    _pc_zone_entries > "$_pc_out_dir/zones.before"
    _pc_call_log_mark > "$_pc_out_dir/calllog.before"
    # Interrupted: note what already finished, stop the rest, and record the
    # finished results before leaving (ultrareview #4575) -- they are true of
    # this content, and a suite that was stopped is recorded as nothing.
    trap '_pc_reap; _pc_pool_kill; _pc_record_all; rm -rf "$_pc_out_dir/scratch"; exit 130' INT TERM HUP
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
        _pc_suite_worker "$idx" "${_pc_q_suite[$idx]}" &
        _pc_run_pid[$idx]=$!
        if [ "$jobs" -eq 1 ]; then
            # A child even when serial: cancellation can reach its supervisor.
            # Explicit wait keeps bash < 4.3 support without wait -n.
            wait "${_pc_run_pid[$idx]}" 2>/dev/null || true
            _pc_reap
        fi
    done
    while [ "${#_pc_run_done[@]}" -lt "$launched" ]; do
        wait -n 2>/dev/null
        rc=$?
        _pc_reap
        [ "$rc" = "127" ] && break
    done
    trap - INT TERM HUP

    # A worker that vanished without writing its result (killed from outside)
    # is a failure, never a pass.
    for i in "${!_pc_run_pid[@]}"; do
        if [ -z "${_pc_run_done[$i]:-}" ]; then
            _pc_run_done[$i]="lost"
            _pc_run_dur[$i]=0
        fi
    done
    # The call log is read before the ledger is written: the test-record calls
    # below are the pool's own, and inside a suite they are tagged test too.
    local rows
    rows=$(_pc_call_log_leaks "$_pc_out_dir/calllog.before")
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
            if grep -qiE 'No space left on device|database or disk is full|ENOSPC' "$_pc_out_dir/$i.out"; then
                echo "  RESOURCE: failed suite output reports exhausted storage; scratch=$_pc_out_dir/scratch" >&2
                df -Pk "$_pc_out_dir" >&2 || true
            fi
            sed 's/\x1b\[[0-9;]*m//g' "$_pc_out_dir/$i.out" \
                | awk '/^TIMEOUT / { diagnostic=1 } diagnostic { print "    " $0; next }
                    !/✓/ && /✗|FAIL|Error|Weave snapshot refused:/ && shown < 15 { print "    " $0; shown++ }' >&2
            echo "  full output: $_pc_out_dir/$i.out" >&2
        fi
    done
    local leaks untagged ran=""
    leaks=$(_pc_zone_leaks "$_pc_out_dir/zones.before")
    untagged=$(sed -n 's/^untagged\t//p' <<< "$leaks")
    leaks=$(grep -v '^untagged	' <<< "$leaks")
    for i in $(printf '%s\n' "${!_pc_run_pid[@]}" | sort -n); do
        ran="${ran:+$ran, }${_pc_q_suite[$i]}"
    done
    if [ -n "$rows" ]; then
        failed_any=1
        echo "" >&2
        echo "✗ suites wrote ${rows%%$'\n'*} row(s) to the user's call log $(cut -f1 "$_pc_out_dir/calllog.before") (wv-6b0f57):" >&2
        printf '%s\n' "$rows" | sed '1d; s/^/    /' >&2
        echo "  One of the suites this gate ran ($ran) ran wv without" >&2
        echo "  WV_TEST_SUITE=1, or with WV_CONFIG_DIR naming the user's own config:" >&2
        echo "  export WV_TEST_SUITE=1 at its top. Another session running suites at" >&2
        echo "  the same time would show here too. The rows already written stay." >&2
    fi
    if [ -n "$leaks" ]; then
        failed_any=1
        echo "" >&2
        echo "✗ a suite left hot-zone directories in the LIVE zone (wv-e200f6):" >&2
        printf '%s\n' "$leaks" | sed 's/^/    /' >&2
        echo "  One of the suites this gate ran ($ran) called wv in a temporary" >&2
        echo "  repository without isolating placement: give it WV_HOT_ZONE, or" >&2
        echo "  WV_TEST_MODE=1 WV_TEST_HOT_ZONE_ROOT=<its temp dir>. Each carries this" >&2
        echo "  pool's tag (wv-7061a0). wv hotzone gc removes orphans of deleted repositories." >&2
    fi
    if [ -n "$untagged" ]; then
        echo "" >&2
        echo "⚠ hot-zone directories of temporary repositories appeared in the LIVE zone while" >&2
        echo "  these suites ran, made outside any gate pool (no pool tag): another session's" >&2
        echo "  suites, or a suite that cleared its whole environment. Not counted against this" >&2
        echo "  gate (wv-7061a0):" >&2
        printf '%s\n' "$untagged" | sed 's/^/    /' >&2
    fi
    # Workers have finished: retain failure logs, never bulky fixture scratch.
    rm -rf "$_pc_out_dir/scratch"
    if [ "$failed_any" = "1" ]; then
        [ -n "$skipped" ] && echo "  not run after the failure: $skipped" >&2
        echo "" >&2
        exit 1
    fi
    rm -rf "$_pc_out_dir"
}
