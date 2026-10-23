#!/usr/bin/env bash
# Weave pre-commit hook: require active node before committing code changes
#
# Enforces the "track ALL work in Weave" rule from AGENTS.md.
# Allows graph-state-only commits and WIP checkpoints through.
#
# Skip with: git commit --no-verify (or WV_SKIP_PRECOMMIT=1)

hook_progress() {
    [ "${WV_HOOK_PROGRESS:-1}" = "0" ] && return 0
    printf '%s\n' "Weave pre-commit: $1" >&2
}

# hook_duration_ms <start_nanos> — wall-clock milliseconds elapsed since a
# `date +%s%N` timestamp (LL1). Returns 0 when nanosecond `date` is unavailable
# (literal "N" output) or the start is the 0 sentinel, so a ledger row never
# carries a bogus negative/garbage cost.
hook_duration_ms() {
    local _t0="$1" _t1 _d
    _t1=$(date +%s%N 2>/dev/null || echo 0)
    case "$_t0" in ''|*[!0-9]*) echo 0; return 0 ;; esac
    case "$_t1" in ''|*[!0-9]*) echo 0; return 0 ;; esac
    [ "$_t0" = "0" ] && { echo 0; return 0; }
    _d=$(( (_t1 - _t0) / 1000000 ))
    [ "$_d" -lt 0 ] && _d=0
    echo "$_d"
}

# The suite pool (run_hook_suites and its helpers) lives in
# scripts/lib/wv-gate-pool.sh, shared with the pre-push gate; it is sourced
# below with the other libraries.

# Prevent recursive hook execution when this hook launches test suites that
# perform their own git commits.
[ "${WV_PRECOMMIT_RUNNING:-0}" = "1" ] && exit 0

# Allow explicit bypass
[ "${WV_SKIP_PRECOMMIT:-0}" = "1" ] && exit 0

# PROTECTED DISPATCHER (S2a, wv-1f98b6; boundary rule 3, wv-ecf877). Where HEAD
# carries this hook (the Weave source repository), the gate is HEAD's committed
# scripts/ tree run from a private copy: this hook, the suite pool, the
# libraries, wv with its router, and the python checkers. It is never the
# working tree, where an unstaged edit could weaken or skip the gate. Nor is it
# this file, a copy install.sh took from some working tree; this file only
# fetches HEAD's. A staged change to the dispatcher is judged by HEAD's.
# git archive applies HEAD's own attributes, not the working tree's. The copy
# may hold no link or submodule, since the gate never follows one, and inherits
# no WV_LIB_DIR or WV_CLI, so wv finds its libraries beside itself.
# WV_HOOK_REEXEC stops the stale-copy hop (wv-98f12b) of hooks older than this,
# which would otherwise run the working tree. Consumer repositories and an unborn HEAD run this file: there, the
# installed dispatcher is the residual.
# A protected lane is this hook run from a copy the block below made: it sits
# at <dir>/tree/scripts/hooks/ beside <dir>/weave-gate-lane, which names the
# commit the copy came from. A file, not an environment variable, so nothing
# the gate runs (suites, the commits their fixtures make) inherits the mark.
_PC_LANE_BASE=""
_wv_lane_file="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." 2>/dev/null && pwd)/weave-gate-lane"
if [ -f "$_wv_lane_file" ]; then
    _PC_LANE_BASE=$(cat "$_wv_lane_file" 2>/dev/null) || _PC_LANE_BASE=""
    if [ -z "$_PC_LANE_BASE" ]; then
        echo "✗ Weave pre-commit: could not read the committed gate's lane mark ($_wv_lane_file) — refusing" >&2
        exit 1
    fi
    # Read only by older hooks' stale-copy guard: nothing this gate runs needs it.
    unset WV_HOOK_REEXEC
fi
# A candidate lane (S2b, wv-7ee8fe; boundary rule 4) is a protected lane whose
# copy holds one changed gate file as staged, beside a weave-gate-candidate
# mark naming that file, the frozen tree it must judge, and whether recorded
# suite results may be reused. It judges and refuses as written, but leaves
# every shared record to the protected lane that started it: no gate record,
# no suite ledger rows, no install self-heal, no phase change, no binding.
_PC_CAND_PATH="" _PC_CAND_TREE="" _PC_CAND_REUSE=""
_wv_cand_file="${_wv_lane_file%/*}/weave-gate-candidate"
if [ -n "$_PC_LANE_BASE" ] && [ -f "$_wv_cand_file" ]; then
    _PC_CAND_PATH=$(sed -n 's/^path=//p' "$_wv_cand_file" 2>/dev/null)
    _PC_CAND_TREE=$(sed -n 's/^tree=//p' "$_wv_cand_file" 2>/dev/null)
    _PC_CAND_REUSE=$(sed -n 's/^reuse=//p' "$_wv_cand_file" 2>/dev/null)
    if [ -z "$_PC_CAND_PATH" ] || [ -z "$_PC_CAND_TREE" ] || [ -z "$_PC_CAND_REUSE" ]; then
        echo "✗ Weave pre-commit: could not read the candidate lane's mark ($_wv_cand_file) — refusing" >&2
        exit 1
    fi
fi
# A recovery run (S2c, wv-0af8f0) is a protected lane whose code comes from a
# recorded replacement tree, named by a weave-gate-exec mark beside the lane
# mark. The lane mark still names HEAD's commit: history (record consumption, E6
# debt, the base a suite judges against) is HEAD's; the role contract and the
# candidate lanes come from the execution tree. The hook acknowledges the mark,
# and the dispatcher refuses a replacement that does not.
_PC_EXEC_TREE=""
_wv_exec_file="${_wv_lane_file%/*}/weave-gate-exec"
if [ -n "$_PC_LANE_BASE" ] && [ -f "$_wv_exec_file" ]; then
    _PC_EXEC_TREE=$(cat "$_wv_exec_file" 2>/dev/null) || _PC_EXEC_TREE=""
    if [ -z "$_PC_EXEC_TREE" ] || ! git rev-parse --verify --quiet "${_PC_EXEC_TREE}^{tree}" >/dev/null 2>&1; then
        echo "✗ Weave pre-commit: could not read the recovery run's execution tree mark ($_wv_exec_file) — refusing" >&2
        exit 1
    fi
fi

# RECOVERY (S2c, wv-0af8f0; docs/findings/gate-s2c-recovery-2026-10-14). When
# HEAD's committed gate refuses every commit, nothing committed can repair it:
# HEAD's gate judges the repair, the record that would admit it and the E6
# obligation alike. Only the installed copy runs this, before HEAD's gate is
# fetched, and it uses nothing from HEAD's scripts/ or the working tree.
#   R1  a commit adding one recovery record (and graph state besides) that
#       HEAD's gate refuses is admitted once this code has checked the record;
#   R2  a commit making exactly a live record's transitions that HEAD's gate
#       refuses is judged by the recorded replacement tree, run in full after a
#       negative control; its verdict binds.
# Both run HEAD's gate first, bounded and in its own process group, and act only
# on its refusal. The override is traceability, not approval (D3a): a prior
# record can override a healthy HEAD refusing a weakened replacement. Every
# admission is frozen, checked stable, logged (the row must be written) and
# bound to the committing git process here, never by a gate this code ran.
_PCR_TIMEOUT=${WV_GATE_RECOVERY_TIMEOUT:-900}
case "$_PCR_TIMEOUT" in ''|*[!0-9]*|0) _PCR_TIMEOUT=900 ;; esac
_PCR_GRACE=10
_PCR_DIR=".weave/gate-repairs"
# A copy of WV_GRAPH_STATE_PATHS (scripts/lib/wv-checkpoint-ci.sh): the
# installed copy loads no library. tests/test-gate-recovery.sh holds them equal.
_PCR_GRAPH_STATE=(.weave/state.sql .weave/nodes.jsonl .weave/edges.jsonl .weave/deltas
    .weave/trails.md .weave/breadcrumbs.md .weave/runtime.md .weave/quality-adjudications.jsonl)
_PCR_PGID="" _PCR_WHY="" _PCR_SHAPE="" _PCR_REC="" _PCR_JSON="" _PCR_TREE="" _PCR_BASE_TREE=""
_PCR_GITPID=""
_PCR_ROWS=()
# Supported external execution paths (wv-732b60). Copying a path does not
# assign its role: the frozen authority's contract still decides enforcement.
# This installed envelope must remain usable when HEAD's role file is broken.
_PC_GATE_EXTERNAL=(tests/test-memory-projection-parity.sh tests/test-shipped-test-refs.sh
    tests/lib/release-leak-pattern.ere build-release.sh)

_pcr_graph_state() {
    local p
    for p in "${_PCR_GRAPH_STATE[@]}"; do
        if [ "$1" = "$p" ] || [[ "$1" == "$p"/* ]]; then return 0; fi
    done
    return 1
}

# _pc_gate_path_ok <path> — canonical repository-relative path, without any
# empty, . or .. component, backslash or control character. Spaces are valid.
_pc_gate_path_ok() {
    local p=$1 c
    local -a parts=()
    [ -n "$p" ] || return 1
    case "$p" in /*|*/|*//*|*\\*) return 1 ;; esac
    [[ "$p" == *[[:cntrl:]]* ]] && return 1
    IFS=/ read -r -a parts <<< "$p"
    for c in "${parts[@]}"; do
        case "$c" in ''|.|..) return 1 ;; esac
    done
    return 0
}

# _pc_gate_archive <tree-ish> <tar> — the common execution envelope for the
# dispatcher, recovery and (once their caller is updated) candidate lanes.
# It copies the supported files from objects, never from the worktree or a
# contract that might need recovery. Missing external files are not invented;
# the role check must refuse declared enforcement that the authority lacks.
_pc_gate_archive() {
    local tree=$1 out=$2 p entry listing
    local -a paths=(scripts)
    for p in "${_PC_GATE_EXTERNAL[@]}"; do
        entry=$(git --literal-pathspecs ls-tree --full-tree "$tree" -- "$p" 2>/dev/null) || return 1
        [ -n "$entry" ] || continue
        case "$entry" in
            '100644 blob '*|'100755 blob '*) paths+=("$p") ;;
            *) echo "✗ Weave pre-commit: external gate path $p is not a regular file — refusing" >&2; return 1 ;;
        esac
    done
    listing=$(git --literal-pathspecs ls-tree -r "$tree" -- "${paths[@]}" 2>/dev/null) || return 1
    if [ -n "$(grep -v -e '^100644 ' -e '^100755 ' <<< "$listing")" ]; then
        echo "✗ Weave pre-commit: the gate copy contains a link or submodule; refusing to follow it" >&2
        return 1
    fi
    git --literal-pathspecs archive --format=tar -o "$out" "$tree" -- "${paths[@]}" 2>/dev/null
}

# Recovery's admission scope is installed code, not a broken HEAD's roles.
# The external paths are the F3/F4 enforcement boundary (wv-732b60); this does
# not permit recording arbitrary product changes as gate recovery.
_pcr_path_ok() {
    local p=$1 external
    _pc_gate_path_ok "$p" || return 1
    case "$p" in scripts/?*) return 0 ;; esac
    for external in "${_PC_GATE_EXTERNAL[@]}"; do
        [ "$p" = "$external" ] && return 0
    done
    return 1
}

# _pcr_entry <tree-ish> <path> — "<mode> <blob>" of a regular file listed at
# exactly <path>; 1 when absent or anything else (a link, a submodule, a tree).
_pcr_entry() {
    local line="" meta path mode type oid
    IFS= read -r -d '' line < <(git --literal-pathspecs ls-tree -z --full-tree "$1" -- "$2" 2>/dev/null) || true
    [ -n "$line" ] || return 1
    meta=${line%%$'\t'*}; path=${line#*$'\t'}
    read -r mode type oid <<< "$meta"
    [ "$path" = "$2" ] && [ "$type" = blob ] || return 1
    case "$mode" in 100644|100755) ;; *) return 1 ;; esac
    printf '%s %s\n' "$mode" "$oid"
}

# _pcr_record_rows <json> — validates a recovery record and fills _PCR_ROWS with
# "path<TAB>baseline_mode<TAB>baseline<TAB>replacement_mode<TAB>replacement".
# Checks against the trees are the caller's. 1 with _PCR_WHY on refusal.
_pcr_record_rows() {
    local hl rows line p bm bo rm ro
    _PCR_ROWS=()
    case "$(git rev-parse --show-object-format 2>/dev/null || echo sha1)" in
        sha256) hl=64 ;; *) hl=40 ;;
    esac
    if ! jq -e --argjson hl "$hl" '
        def oid: type == "string" and test("^[0-9a-f]{\($hl)}$");
        def mode: type == "string" and IN("100644", "100755");
        .version == 1 and .kind == "recovery"
        and (.reason | type == "string" and length > 0)
        and (.verification | type == "string" and length > 0)
        and (.paths | type == "object" and length > 0)
        and all(.paths[]; type == "object"
            and (.baseline_mode | mode) and (.replacement_mode | mode)
            and (.baseline | oid) and (.replacement | oid)
            and ([.baseline_mode, .baseline] != [.replacement_mode, .replacement]))' \
        >/dev/null 2>&1 <<< "$1"; then
        _PCR_WHY="the record is not a valid recovery record (version 1, kind recovery, non-empty reason and verification, and per path a baseline and replacement blob id with mode 100644 or 100755 that differ)"
        return 1
    fi
    rows=$(jq -r '.paths | to_entries[] | [.key, .value.baseline_mode, .value.baseline,
        .value.replacement_mode, .value.replacement] | @tsv' <<< "$1" 2>/dev/null) || {
        _PCR_WHY="could not read the record's paths"; return 1; }
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        IFS=$'\t' read -r p bm bo rm ro <<< "$line"
        if ! _pcr_path_ok "$p"; then
            _PCR_WHY="the record names $p, which is not a canonical path under scripts/ or an installed F3/F4 enforcement path"
            return 1
        fi
        if [ "$(git cat-file -t "$bo" 2>/dev/null)" != blob ] || [ "$(git cat-file -t "$ro" 2>/dev/null)" != blob ]; then
            _PCR_WHY="the record's baseline or replacement for $p does not name a blob in this repository"
            return 1
        fi
        _PCR_ROWS+=("$line")
    done <<< "$rows"
}

# _pcr_changes <from> <to> — "status<TAB>new mode<TAB>new blob<TAB>path" per
# changed path, renames off.
_pcr_changes() {
    local meta path nm no st
    while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
        read -r _ nm _ no st <<< "${meta#:}"
        printf '%s\t%s\t%s\t%s\n' "$st" "$nm" "$no" "$path"
    done < <(git diff-tree -r -z --no-renames --raw "$1" "$2" 2>/dev/null)
}

_pcr_kind() { git cat-file blob "$1" 2>/dev/null | jq -r 'if type == "object" then (.kind // "") else "" end' 2>/dev/null; }

# _pcr_shape — classifies the frozen transition: _PCR_SHAPE record (R1) or
# repair (R2) with _PCR_REC and _PCR_JSON, else empty. A transition that comes
# near (it touches a recovery record, or a record names some of its paths)
# leaves _PCR_WHY, shown if HEAD's gate refuses it.
_pcr_shape() {
    local changes line st nm no p n_rec=0 other="" all_gate=1 rec_kind
    local -a recs=() changed=()
    local -A want=()
    _PCR_SHAPE="" _PCR_REC="" _PCR_JSON="" _PCR_WHY=""
    changes=$(_pcr_changes "$_PCR_BASE_TREE" "$_PCR_TREE") || return 0
    [ -n "$changes" ] || return 0
    while IFS= read -r line; do
        IFS=$'\t' read -r st nm no p <<< "$line"
        changed+=("$p")
        want[$p]="$st $nm $no"
        _pcr_path_ok "$p" || all_gate=0
        case "$p" in
            "$_PCR_DIR"/*)
                n_rec=$((n_rec + 1)); recs+=("$p") ;;
            *) _pcr_graph_state "$p" || other=$p ;;
        esac
    done <<< "$changes"
    if [ "$n_rec" -gt 0 ]; then
        rec_kind=""
        for p in "${recs[@]}"; do
            read -r st nm no <<< "${want[$p]}"
            if [ "$st" != D ] && [ "$(_pcr_kind "$no")" = recovery ]; then rec_kind=1; fi
            no=$(git rev-parse -q --verify "$_PCR_BASE_TREE:$p" 2>/dev/null) || no=""
            if [ -n "$no" ] && [ "$(_pcr_kind "$no")" = recovery ]; then rec_kind=1; fi
        done
        [ -n "$rec_kind" ] || return 0
        read -r st nm no <<< "${want[${recs[0]}]}"
        if [ -n "$other" ]; then
            _PCR_WHY="a recovery record commit carries only the record and graph state, and this one also changes $other"
        elif [ "$n_rec" -ne 1 ]; then
            _PCR_WHY="a recovery record commit adds exactly one record, and this one changes $n_rec under $_PCR_DIR/"
        elif [ "$st" != A ]; then
            _PCR_WHY="a recovery record commit adds a new record; this one modifies or deletes ${recs[0]}"
        elif [ "$nm" != 100644 ] || [[ "${recs[0]}" != *.json ]] || [[ "${recs[0]#"$_PCR_DIR"/}" == */* ]]; then
            _PCR_WHY="a recovery record is a regular .json file directly under $_PCR_DIR/ (mode 100644), and ${recs[0]} is not"
        else
            _PCR_SHAPE=record _PCR_REC=${recs[0]}
            _PCR_JSON=$(git cat-file blob "$no" 2>/dev/null)
        fi
        return 0
    fi
    [ "$all_gate" = 1 ] || return 0
    # R2: a recovery record at HEAD naming exactly the changed paths, each at
    # the record's replacement mode and blob.
    local mode type oid rpath json names line2 bm bo rm ro ok
    while IFS= read -r -d '' line; do
        rpath=${line#*$'\t'}
        read -r mode type oid <<< "${line%%$'\t'*}"
        [ "$mode $type" = "100644 blob" ] && [[ "$rpath" == *.json ]] || continue
        json=$(git cat-file blob "$oid" 2>/dev/null) || continue
        [ "$(jq -r 'if type == "object" then (.kind // "") else "" end' <<< "$json" 2>/dev/null)" = recovery ] || continue
        names=$(jq -r '.paths | if type == "object" then keys[] else empty end' <<< "$json" 2>/dev/null) || continue
        ok=1
        for p in "${changed[@]}"; do grep -qxF -- "$p" <<< "$names" || ok=0; done
        while IFS= read -r p; do [ -n "${want[$p]+x}" ] || ok=0; done <<< "$names"
        if [ "$ok" = 1 ]; then
            while IFS= read -r line2; do
                IFS=$'\t' read -r p bm bo rm ro <<< "$line2"
                [ "${want[$p]}" = "M $rm $ro" ] || ok=0
            done < <(jq -r '.paths | to_entries[] | [.key, .value.baseline_mode, .value.baseline,
                .value.replacement_mode, .value.replacement] | map(tostring) | @tsv' <<< "$json" 2>/dev/null)
            if [ "$ok" = 1 ]; then
                _PCR_SHAPE=repair _PCR_REC=$rpath _PCR_JSON=$json _PCR_WHY=""
                return 0
            fi
            _PCR_WHY="the recovery record $rpath names this commit's paths, but not these modes and blobs"
        else
            for p in "${changed[@]}"; do
                if grep -qxF -- "$p" <<< "$names"; then
                    _PCR_WHY="the recovery record $rpath names $(paste -sd ' ' <<< "$names"), and this commit changes ${changed[*]}: a repair commit makes exactly the record's transitions"
                    break
                fi
            done
        fi
    done < <(git ls-tree -r -z --full-tree "$_PCR_BASE_TREE" -- "$_PCR_DIR" 2>/dev/null)
    return 0
}

# _pcr_consumed <since> <path> <bm> <bo> <rm> <ro> — rule 5's walk, comparing
# (mode, blob): some commit reachable from HEAD and not from the record's
# commit went from exactly the baseline pair to exactly the replacement pair
# against one of its parents. A commit leaving the pair unchanged is no
# transition, which a blob-only comparison misreads for a mode-only record.
# 0 consumed, 1 not, 2 could not tell.
_pcr_consumed() {
    local since=$1 path=$2 bm=$3 bo=$4 rm=$5 ro=$6 line c p i cm pm rc history objects
    local -a pairs=() objs=()
    # Acquire synchronously: Bash 5.2 can reap a process substitution and then
    # return -1 from its explicit wait (wv-5a776d; recovery wv-d3eb18).
    history=$(git --no-replace-objects rev-list --parents "$_wv_base" --not "$since" 2>/dev/null) || return 2
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        c=${line%% *}
        for p in ${line#"$c"}; do pairs+=("$c" "$p"); done
    done <<< "$history"
    [ "${#pairs[@]}" -gt 0 ] || return 1
    # The status is cat-file's and awk's, read from PIPESTATUS: this hook
    # does not run under pipefail.
    objects=$(
        for c in "${pairs[@]}"; do printf '%s:%s\n' "$c" "$path"; done \
            | git --no-replace-objects cat-file --batch-check='%(objectname)' 2>/dev/null \
            | awk '/^[0-9a-f]+$/ { print; next } { print "missing" }'
        st=("${PIPESTATUS[@]}"); [ "${st[1]}" = 0 ] && [ "${st[2]}" = 0 ]) || return 2
    mapfile -t objs <<< "$objects"
    [ "${#objs[@]}" -eq "${#pairs[@]}" ] || return 2
    for ((i = 0; i < ${#objs[@]}; i += 2)); do
        # batch-check answers "missing" both for a path the commit lacks and
        # for an object it cannot read; only the first is "no transition". A
        # found object prints its bare name; anything else (git echoes the
        # requested "<commit>:<path> missing", and a path may hold spaces) is
        # taken as missing and confirmed below.
        for c in "${pairs[i]}" "${pairs[i+1]}"; do
            [ "${objs[i]}" = missing ] || [ "${objs[i+1]}" = missing ] || break
            rc=0; _pcr_mode "$c" "$path" >/dev/null || rc=$?
            [ "$rc" -ne 2 ] || return 2
        done
        [ "${objs[i]}" = "$ro" ] && [ "${objs[i+1]}" = "$bo" ] || continue
        # Both sides hold the path (the blobs above say so), so a mode read
        # that fails or comes back empty is an unreadable history, never "not
        # this transition": that would revive a consumed record.
        rc=0; cm=$(_pcr_mode "${pairs[i]}" "$path") || rc=$?
        [ "$rc" -eq 0 ] || return 2
        rc=0; pm=$(_pcr_mode "${pairs[i+1]}" "$path") || rc=$?
        [ "$rc" -eq 0 ] || return 2
        [ "$cm" = "$rm" ] && [ "$pm" = "$bm" ] && return 0
    done
    return 1
}

# _pcr_mode <commit> <path> — the mode git lists for <path> in <commit>. 0
# printed, 1 absent, 2 git failed.
_pcr_mode() {
    local out
    out=$(git --no-replace-objects --literal-pathspecs ls-tree --full-tree "$1" -- "$2" 2>/dev/null) || return 2
    [ -n "$out" ] || return 1
    printf '%s\n' "${out%% *}"
}

# _pcr_stable — git still commits the frozen tree onto the frozen HEAD.
_pcr_stable() {
    [ "$(git write-tree 2>/dev/null)" = "$_PCR_TREE" ] \
        && [ "$(git rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null)" = "$_wv_base" ]
}

_pcr_kill() {
    [ -n "$_PCR_PGID" ] || return 0
    kill -KILL -- "-$_PCR_PGID" 2>/dev/null || true
    _PCR_PGID=""
}

# _pcr_run <out> <command...> — runs the command in its own session and process
# group, its output shown and kept in <out>. At the bound: TERM to the group,
# the grace, KILL, reap. The group is killed after a normal exit too, so nothing
# it left behind runs on; a child that left the group (its own setsid) is not
# contained. 124 at the bound.
_pcr_run() {
    local out=$1 pid ticks=0 g=0 rc
    shift
    setsid bash -c 'out=$1; shift; "$@" 2>&1 | tee "$out" >&2; exit "${PIPESTATUS[0]}"' _ "$out" "$@" &
    pid=$!
    _PCR_PGID=$pid
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$ticks" -ge $((_PCR_TIMEOUT * 5)) ]; then
            echo "✗ Weave pre-commit: the run did not finish within ${_PCR_TIMEOUT}s (WV_GATE_RECOVERY_TIMEOUT); stopping its process group" >&2
            kill -TERM -- "-$pid" 2>/dev/null || true
            while kill -0 -- "-$pid" 2>/dev/null && [ "$g" -lt $((_PCR_GRACE * 5)) ]; do sleep 0.2; g=$((g + 1)); done
            kill -KILL -- "-$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null
            _PCR_PGID=""
            return 124
        fi
        sleep 0.2
        ticks=$((ticks + 1))
    done
    wait "$pid"; rc=$?
    _pcr_kill
    return "$rc"
}

# _pcr_git_pid — as _pc_git_pid below: the git process running this hook.
_pcr_git_pid() {
    local pid=$PPID comm i
    for i in 1 2 3 4 5; do
        case "$pid" in ''|*[!0-9]*|0|1) return 1 ;; esac
        comm=$(ps -o comm= -p "$pid" 2>/dev/null | sed 's/^ *//; s/ *$//')
        case "$comm" in git|*/git) printf '%s\n' "$pid"; return 0 ;; esac
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    done
    return 1
}

# _pcr_prereqs — what recovery cannot admit without: jq, setsid, the Weave
# reference-transaction hook (git 2.28+) to bind the commit, and the git
# process to bind it to. The ordinary path continues check-then-use without a
# binding; recovery refuses.
_pcr_prereqs() {
    local v major minor hooks
    command -v jq >/dev/null 2>&1 || { _PCR_WHY="recovery needs jq"; return 1; }
    command -v setsid >/dev/null 2>&1 || { _PCR_WHY="recovery needs setsid (util-linux) to bound HEAD's gate"; return 1; }
    v=$(git version 2>/dev/null); v=${v#git version }
    major=${v%%.*}; minor=${v#*.}; minor=${minor%%.*}
    case "$major$minor" in ''|*[!0-9]*) _PCR_WHY="could not read the git version"; return 1 ;; esac
    if ! { [ "$major" -gt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -ge 28 ]; }; }; then
        _PCR_WHY="recovery binds the commit through the reference-transaction hook, which needs git 2.28+"
        return 1
    fi
    hooks=$(git rev-parse --git-path hooks 2>/dev/null) || hooks=""
    if [ -z "$hooks" ] || [ ! -x "$hooks/reference-transaction" ] \
        || ! grep -q "Weave reference-transaction" "$hooks/reference-transaction" 2>/dev/null; then
        _PCR_WHY="recovery binds the commit through the Weave reference-transaction hook, which is not installed (./install.sh)"
        return 1
    fi
    _PCR_GITPID=$(_pcr_git_pid) || { _PCR_WHY="no git process to bind the commit to (recovery runs only under git commit)"; return 1; }
}

# _pcr_log <trigger> <head status> [exec tree] [control] [verdict] — the
# durable gate-log row recording this admission decision (not a publication:
# the reference-transaction hook can still abort it). Where wv writes gate rows:
# WV_GATE_LOG, else beside WV_SUITE_LOG, config.env winning as it does for wv.
# Unlike wv's writer it fails, and the admission with it.
_pcr_log() {
    local cfg log suite repo
    cfg="${WV_CONFIG_DIR:-$HOME/.config/weave}/config.env"
    if [ "${WV_CALL_SOURCE:-}" = test ] && [ -z "${WV_SUITE_LOG:-}" ] && [ -z "${WV_GATE_LOG:-}" ]; then
        _PCR_WHY="a test run with no WV_GATE_LOG or WV_SUITE_LOG of its own has no durable gate log to record a recovery in"
        return 1
    fi
    # shellcheck source=/dev/null
    log=$( { [ -f "$cfg" ] && { set -a; . "$cfg"; set +a; }; } >/dev/null 2>&1
        suite=${WV_SUITE_LOG:-${WV_SUITE_LOG_DEFAULT:-$HOME/.local/share/weave/suite_runs.jsonl}}
        printf '%s\n' "${WV_GATE_LOG:-$(dirname "$suite")/gate_runs.jsonl}")
    repo=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)")
    if [ -z "$log" ] || ! mkdir -p "$(dirname "$log")" 2>/dev/null \
        || ! jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg repo "$repo" \
            --arg trigger "$1" --arg record "$_PCR_REC" --arg tree "$_PCR_TREE" --arg base "$_wv_base" \
            --arg head "$2" --arg exec "${3:-}" --arg control "${4:-}" --arg verdict "${5:-}" \
            '{ts: $ts, repo: $repo, phase: "recovery", trigger: $trigger, decision: "admit",
              record: $record, tree: $tree, base: $base, head_status: $head,
              exit: 0, duration_ms: 0, estimate_ms: null, suites: [], sha: $base}
             + (if $exec != "" then {exec_tree: $exec, control: $control, verdict: $verdict} else {} end)' \
            >> "$log" 2>/dev/null; then
        _PCR_WHY="could not write the recovery row to the gate log (${log:-unresolved}); a recovery is admitted only once it is recorded"
        return 1
    fi
}

# _pcr_bind — as _pc_bind below, written by this code for the frozen tree, last.
_pcr_bind() {
    local started dir
    started=$(ps -o lstart= -p "$_PCR_GITPID" 2>/dev/null | sed 's/^ *//; s/ *$//')
    dir=$(git rev-parse --git-path weave-gate 2>/dev/null)
    [ -n "$started" ] && [ -n "$dir" ] && mkdir -p "$dir" 2>/dev/null \
        && printf 'tree=%s\nstart=%s\nlanes=\n' "$_PCR_TREE" "$started" > "$dir/admitted-$_PCR_GITPID.tmp" 2>/dev/null \
        && mv -f "$dir/admitted-$_PCR_GITPID.tmp" "$dir/admitted-$_PCR_GITPID" 2>/dev/null
}

_pcr_unbind() {
    local dir
    [ -n "$_PCR_GITPID" ] || return 0
    dir=$(git rev-parse --git-path weave-gate 2>/dev/null) && rm -f "$dir/admitted-$_PCR_GITPID" 2>/dev/null
    return 0
}

# _pcr_refuse <message> <rc> — recovery does not admit: HEAD's refusal stands.
_pcr_refuse() {
    local rc=$2
    case "$rc" in ''|*[!0-9]*|0) rc=1 ;; esac
    _pcr_unbind
    echo "✗ Weave pre-commit: recovery does not admit this commit: $1 — refusing" >&2
    exit "$rc"
}

# _pcr_admit <notice> — stable, recorded, bound, in that order.
_pcr_admit() {
    _pcr_stable || _pcr_refuse "the index or HEAD changed during recovery, so git would commit something other than what was judged; re-run the commit" 1
    _pcr_bind || _pcr_refuse "could not bind this commit to the judged tree" 1
    echo "⚠ Weave pre-commit: $1 Records give traceability, not approval." >&2
    exit 0
}

# _pcr_validate — the shaped record, checked by this code before any gate
# runs (D4): well formed, canonical paths, blob objects, regular-file modes,
# and the trees hold exactly those modes and blobs: HEAD the baselines, and for
# R2 the frozen index the replacements. On failure the shape is dropped and
# _PCR_WHY says why; HEAD's gate then decides alone.
_pcr_validate() {
    local line p bm bo rm ro
    if ! _pcr_record_rows "$_PCR_JSON"; then
        _PCR_WHY="$_PCR_REC: $_PCR_WHY"; return 1
    fi
    for line in "${_PCR_ROWS[@]}"; do
        IFS=$'\t' read -r p bm bo rm ro <<< "$line"
        if [ "$(_pcr_entry "$_PCR_BASE_TREE" "$p")" != "$bm $bo" ]; then
            _PCR_WHY="$_PCR_REC names $p at $bm $bo, which is not HEAD's regular file there (a recovery record binds HEAD's current mode and bytes)"
            return 1
        fi
        if [ "$_PCR_SHAPE" = repair ] && [ "$(_pcr_entry "$_PCR_TREE" "$p")" != "$rm $ro" ]; then
            _PCR_WHY="the staged $p is not $_PCR_REC's replacement ($rm $ro)"
            return 1
        fi
    done
}

# _pcr_record_r1 <head rc> — R1 once HEAD's gate refused the record commit.
_pcr_record_r1() {
    local head=$1
    _pcr_stable || _pcr_refuse "the index or HEAD changed during recovery; re-run the commit" 1
    _pcr_log recovery-record "$head" || _pcr_refuse "$_PCR_WHY" 1
    _pcr_admit "HEAD's gate refused this commit (status $head); it is admitted by the recovery record $_PCR_REC it adds, which changes no gate and takes effect only on a later commit making exactly its transitions."
}

# _pcr_record_r2 <head rc> — R2 once HEAD's gate refused the repair commit.
_pcr_record_r2() {
    local head=$1 line p bm bo rm ro since rc idx exec d ctl blob ctl_res
    [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = false ] \
        && [ -z "$(git config --get-regexp '^(extensions\.partialclone|remote\..*\.promisor)$' 2>/dev/null)" ] \
        || _pcr_refuse "this clone's history is shallow or partial, so whether $_PCR_REC was already used cannot be established. Fetch the full history (git fetch --unshallow, or --refetch for a partial clone), then commit again" "$head"
    since=$(git --no-replace-objects log -1 --full-history --diff-filter=AM --format=%H "$_wv_base" -- "$_PCR_REC" 2>/dev/null)
    [ -n "$since" ] || _pcr_refuse "could not find the commit that recorded $_PCR_REC" 1
    for line in "${_PCR_ROWS[@]}"; do
        IFS=$'\t' read -r p bm bo rm ro <<< "$line"
        rc=0; _pcr_consumed "$since" "$p" "$bm" "$bo" "$rm" "$ro" || rc=$?
        case "$rc" in
            0) _pcr_refuse "$_PCR_REC was already used: a commit since it made its transition of $p, and a record admits once" "$head" ;;
            1) ;;
            *) _pcr_refuse "could not read the history that shows whether $_PCR_REC was used" 1 ;;
        esac
    done
    # The execution tree, built from objects: HEAD's tree with every recorded
    # path at its replacement. By the R2 shape it is the frozen tree itself.
    d=$_wv_d/recovery
    mkdir -p "$d/tmp" || _pcr_refuse "could not prepare the recovery run" 1
    idx=$d/exec.index
    GIT_INDEX_FILE=$idx git read-tree "$_PCR_BASE_TREE" 2>/dev/null || _pcr_refuse "could not build the execution tree" 1
    for line in "${_PCR_ROWS[@]}"; do
        IFS=$'\t' read -r p bm bo rm ro <<< "$line"
        GIT_INDEX_FILE=$idx git update-index --add --cacheinfo "$rm,$ro,$p" 2>/dev/null || _pcr_refuse "could not build the execution tree" 1
    done
    exec=$(GIT_INDEX_FILE=$idx git write-tree 2>/dev/null) || exec=""
    [ -n "$exec" ] && [ "$exec" = "$_PCR_TREE" ] || _pcr_refuse "the execution tree (${exec:-none}) is not the frozen tree" 1
    line=$(git ls-tree -r "$exec" -- scripts 2>/dev/null) || _pcr_refuse "could not list the execution tree's scripts/" 1
    if [ -n "$(grep -v -e '^100644 ' -e '^100755 ' <<< "$line")" ]; then
        _pcr_refuse "the execution tree's scripts/ holds a link or submodule, which the gate does not follow" "$head"
    fi
    if ! _pc_gate_archive "$exec" "$d/exec.tar" || ! mkdir "$d/run" "$d/run/tree" \
        || ! tar -xf "$d/exec.tar" -C "$d/run/tree" 2>/dev/null || [ ! -f "$d/run/tree/scripts/hooks/pre-commit-weave.sh" ] \
        || ! printf '%s\n' "$_wv_base" > "$d/run/weave-gate-lane" || ! printf '%s\n' "$exec" > "$d/run/weave-gate-exec"; then
        _pcr_refuse "could not copy the execution tree" 1
    fi
    _pcr_stable || _pcr_refuse "the index or HEAD changed during recovery; re-run the commit" 1
    # D3c, the negative control: the replacement run once on the frozen tree
    # with an invalid role contract must refuse with the invalid-role
    # diagnostic. It rules out a replacement that admits everything, nothing
    # more. It runs isolated: a private index, TMPDIR, an empty private hot
    # zone and database (so a replacement that writes the graph or the suite
    # ledger before refusing writes nothing shared), and private suite, gate
    # and call logs. Not isolated: git's object store (any object it writes is
    # unreferenced) and the binding record, which is cleared after it.
    ctl=$d/control
    mkdir -p "$ctl/tmp" "$ctl/zone" && chmod 700 "$ctl/zone" || _pcr_refuse "could not prepare the negative control" 1
    blob=$(printf '{"version": 0}\n' | git hash-object -w --stdin 2>/dev/null) || blob=""
    if [ -z "$blob" ] || ! GIT_INDEX_FILE=$ctl/index git read-tree "$_PCR_TREE" 2>/dev/null \
        || ! GIT_INDEX_FILE=$ctl/index git update-index --add --cacheinfo "100644,$blob,scripts/hooks/gate-roles.json" 2>/dev/null; then
        _pcr_refuse "could not prepare the negative control" 1
    fi
    echo "Weave pre-commit: recovery negative control: the replacement must refuse an invalid role contract" >&2
    rc=0
    _pcr_run "$ctl/out" env -u WV_LIB_DIR -u WV_CLI -u WV_PRECOMMIT_RUNNING -u WV_SKIP_PRECOMMIT \
        GIT_INDEX_FILE="$ctl/index" TMPDIR="$ctl/tmp" WV_HOT_ZONE="$ctl/zone" WV_DB="$ctl/zone/brain.db" \
        WV_SUITE_LOG="$ctl/suite_runs.jsonl" WV_GATE_LOG="$ctl/gate_runs.jsonl" WV_CALL_LOG="$ctl/wv_calls.jsonl" \
        WV_HOOK_REEXEC=1 \
        bash "$d/run/tree/scripts/hooks/pre-commit-weave.sh" "$@" || rc=$?
    _pcr_unbind
    if [ "$rc" -eq 0 ] || ! grep -qF "the staged gate role contract (scripts/hooks/gate-roles.json) is not valid" "$ctl/out" 2>/dev/null; then
        _pcr_refuse "the replacement did not refuse the negative control with the invalid-role diagnostic (status $rc)" "$head"
    fi
    ctl_res="refused (status $rc, invalid-role diagnostic)"
    _pcr_stable || _pcr_refuse "the index or HEAD changed during recovery; re-run the commit" 1
    echo "Weave pre-commit: recovery: running the replacement gate from execution tree ${exec:0:12} on this commit, suites rerun" >&2
    rc=0
    _pcr_run "$d/out" env -u WV_LIB_DIR -u WV_CLI WV_HOOK_REEXEC=1 \
        bash "$d/run/tree/scripts/hooks/pre-commit-weave.sh" "$@" || rc=$?
    _pcr_unbind
    [ "$rc" -eq 0 ] || _pcr_refuse "the replacement gate refused this commit (status $rc); its verdict binds" "$rc"
    grep -qxF -- "Weave pre-commit: recovery execution tree $exec acknowledged" "$d/out" 2>/dev/null \
        || _pcr_refuse "the replacement gate did not acknowledge the execution tree mark, so it may have judged other code" 1
    _pcr_stable || _pcr_refuse "the index or HEAD changed during recovery; re-run the commit" 1
    _pcr_log recovery-repair "$head" "$exec" "$ctl_res" admitted || _pcr_refuse "$_PCR_WHY" 1
    _pcr_admit "HEAD's gate refused this commit (status $head); it is admitted by the recovery record $_PCR_REC, judged by the replacement gate (execution tree ${exec:0:12}: negative control $ctl_res, verdict admitted)."
}

# _pcr_main <hook args...> — returns for every commit recovery does not shape;
# otherwise decides and exits.
_pcr_main() {
    local head_rc=0 out
    command -v jq >/dev/null 2>&1 || return 0
    _PCR_TREE=$(git write-tree 2>/dev/null) || return 0
    [ "$(git rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null)" = "$_wv_base" ] || return 0
    _PCR_BASE_TREE=$(git rev-parse --verify --quiet "$_wv_base^{tree}" 2>/dev/null) || return 0
    _pcr_shape
    if [ -n "$_PCR_SHAPE" ] && ! _pcr_validate; then _PCR_SHAPE=""; fi
    [ -n "$_PCR_SHAPE" ] || [ -n "$_PCR_WHY" ] || return 0
    if [ -z "$_PCR_SHAPE" ]; then
        # Near a recovery shape: HEAD's gate decides, unbounded, as for any
        # commit; if it refuses, say why recovery did not apply.
        env -u WV_LIB_DIR -u WV_CLI WV_HOOK_REEXEC=1 bash "$_wv_d/tree/scripts/hooks/pre-commit-weave.sh" "$@" || head_rc=$?
        [ "$head_rc" -eq 0 ] && exit 0
        echo "✗ Weave pre-commit: recovery does not apply: $_PCR_WHY" >&2
        exit "$head_rc"
    fi
    trap '_pcr_kill; exit 130' INT TERM HUP
    out=$_wv_d/head.out
    echo "Weave pre-commit: this commit has the recovery $([ "$_PCR_SHAPE" = record ] && echo "record (R1)" || echo "repair (R2)") shape ($_PCR_REC): running HEAD's gate first, bounded at ${_PCR_TIMEOUT}s" >&2
    _pcr_run "$out" env -u WV_LIB_DIR -u WV_CLI WV_HOOK_REEXEC=1 \
        bash "$_wv_d/tree/scripts/hooks/pre-commit-weave.sh" "$@" || head_rc=$?
    [ "$head_rc" -eq 0 ] && exit 0
    [ "$head_rc" -eq 124 ] && head_rc=timeout
    _pcr_prereqs || _pcr_refuse "$_PCR_WHY" 1
    _pcr_unbind
    if [ "$_PCR_SHAPE" = record ]; then
        _pcr_record_r1 "$head_rc" "$@"
    else
        _pcr_record_r2 "$head_rc" "$@"
    fi
}

if [ -z "$_PC_LANE_BASE" ]; then
    _wv_base=$(git rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null) || _wv_base=""
    _wv_self=""
    if [ -n "$_wv_base" ] && ! _wv_self=$(git ls-tree "$_wv_base" -- scripts/hooks/pre-commit-weave.sh 2>/dev/null); then
        echo "✗ Weave pre-commit: could not read HEAD's tree to find its committed gate — refusing" >&2
        exit 1
    fi
    if [ -n "$_wv_self" ]; then
        if ! _wv_ls=$(git ls-tree -r "$_wv_base" -- scripts 2>/dev/null); then
            echo "✗ Weave pre-commit: could not list HEAD's scripts/, the committed gate — refusing" >&2
            exit 1
        fi
        _wv_odd=$(grep -v -e '^100644 ' -e '^100755 ' <<< "$_wv_ls" || true)
        if [ -n "$_wv_odd" ]; then
            echo "✗ Weave pre-commit: HEAD's scripts/ holds a link or submodule ($(head -1 <<< "$_wv_odd" | cut -f2)), which the protected gate does not follow — refusing" >&2
            exit 1
        fi
        _wv_d=$(mktemp -d "${TMPDIR:-/tmp}/wv-gate-dispatch.XXXXXX" 2>/dev/null) || _wv_d=""
        if [ -z "$_wv_d" ] || [ ! -d "$_wv_d" ]; then
            echo "✗ Weave pre-commit: could not create a directory for HEAD's committed gate — refusing" >&2
            exit 1
        fi
        trap 'rm -rf "${_wv_d:?}"' EXIT
        trap 'exit 130' INT TERM HUP
        if ! _pc_gate_archive "$_wv_base" "$_wv_d/gate.tar" \
            || ! mkdir "$_wv_d/tree" || ! tar -xf "$_wv_d/gate.tar" -C "$_wv_d/tree" 2>/dev/null \
            || [ ! -f "$_wv_d/tree/scripts/hooks/pre-commit-weave.sh" ]; then
            echo "✗ Weave pre-commit: could not copy HEAD's committed gate (scripts/ at ${_wv_base:0:12}) — refusing" >&2
            exit 1
        fi
        # The stale-copy guard's notice (wv-98f12b), kept: a copy that differs
        # from HEAD's still runs this fetch, so it should be refreshed.
        if ! cmp -s "$_wv_d/tree/scripts/hooks/pre-commit-weave.sh" "$0"; then
            echo "Weave pre-commit: running HEAD's committed gate (scripts/ at ${_wv_base:0:12}); this copy differs from it (refresh with ./install.sh)" >&2
        fi
        if ! printf '%s\n' "$_wv_base" > "$_wv_d/weave-gate-lane" 2>/dev/null; then
            echo "✗ Weave pre-commit: could not mark the copy of HEAD's committed gate — refusing" >&2
            exit 1
        fi
        _pcr_main "$@"
        WV_HOOK_REEXEC=1 \
            env -u WV_LIB_DIR -u WV_CLI bash "$_wv_d/tree/scripts/hooks/pre-commit-weave.sh" "$@"
        exit $?
    fi
fi

# Find wv. A missing wv is judged below, once the staged content is
# classified: it no longer admits a substantive commit unchecked (wv-68aeff).
# In the protected lane, wv, the libraries and the python checkers come from
# the copy this hook runs from and nowhere else (_PC_SCRIPTS).
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || exit 0)
if [ -n "$_PC_LANE_BASE" ]; then
    _PC_SCRIPTS=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd) || _PC_SCRIPTS=""
    if [ -z "$_PC_SCRIPTS" ] || [ ! -x "$_PC_SCRIPTS/wv" ]; then
        echo "✗ Weave pre-commit: the committed gate has no scripts/wv beside its hook — refusing" >&2
        exit 1
    fi
    # The committed wv runs without the caller's python import environment.
    # Its inline python would otherwise import from PYTHONPATH, or from the
    # repository root it runs in (PYTHONSAFEPATH, python 3.11+).
    WV="$_PC_SCRIPTS/../wv-gate"
    if ! printf '#!/bin/sh\nexec env -u PYTHONPATH -u PYTHONHOME -u PYTHONUSERBASE -u PYTHONSTARTUP PYTHONSAFEPATH=1 "%s/wv" "$@"\n' \
            "$_PC_SCRIPTS" > "$WV" 2>/dev/null || ! chmod +x "$WV" 2>/dev/null; then
        echo "✗ Weave pre-commit: could not prepare the committed wv — refusing" >&2
        exit 1
    fi
    _pc_lib_cands=("$_PC_SCRIPTS/lib")
else
    # HEAD has no committed gate (a consumer, or an unborn branch): the gate is
    # the one this hook ships with, beside it, never the repository's working
    # tree. A file naming gate code through REPO_ROOT cannot change, because
    # in a candidate lane that reads the commit's bytes (S2b review N1,
    # wv-c424ed).
    _PC_SCRIPTS=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd) || _PC_SCRIPTS=""
    WV="$(command -v wv 2>/dev/null || true)"
    _pc_lib_cands=("$_PC_SCRIPTS/lib" "$HOME/.local/lib/weave/lib")
fi

# Tag this hook's wv calls as hook traffic (wv-f47c10). A commit from a Claude
# session inherits WV_CALL_SOURCE=agent, so without this the gate's calls were
# logged as agent calls: 27 of 41 counted rows in the e5-c02 capture. A test
# run's tag stays: the self-heal guard below and suite retro reads depend on it.
[ "${WV_CALL_SOURCE:-}" = "test" ] || export WV_CALL_SOURCE=hook

# Phase helper + enum (best effort): beside this hook (scripts/hooks/../lib),
# then the installed location. Without a lib dir wv_set_phase + validators
# silently vanish and the hook degrades to its weakest path — wrong phase
# resolution, no phase reset (finding wv-e754b0 O3). Beside this hook first, as
# pre-push and the suite pool below already do: a hook run from a checkout
# against another repository once gated with the INSTALLED helpers, so a
# source fix to wv-checkpoint-ci.sh never reached it (wv-29d13c). A copied
# .git/hooks entry has no ../lib and falls through to the installed one.
_PC_LIB_DIR=""
for _pc_cand in "${_pc_lib_cands[@]}"; do
    if [ -f "$_pc_cand/wv-config.sh" ]; then _PC_LIB_DIR="$_pc_cand"; break; fi
done
# The pool and the frozen candidate below: in the protected lane only the copy's
# lib, otherwise beside this hook, then the resolved and installed lib dirs.
if [ -n "$_PC_LANE_BASE" ]; then
    _pc_lib_cands=("$_PC_SCRIPTS/lib")
else
    _pc_lib_cands=("$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/../lib" \
        "$_PC_LIB_DIR" "$HOME/.local/lib/weave/lib")
fi
if [ -n "$_PC_LIB_DIR" ]; then
    source "$_PC_LIB_DIR/wv-validate.sh" 2>/dev/null || true
    source "$_PC_LIB_DIR/wv-config.sh" 2>/dev/null || true
    source "$_PC_LIB_DIR/wv-checkpoint-ci.sh" 2>/dev/null || true
    # Repo-declared shellcheck scope (wv-7608e6); its absence is checked where
    # a repository has declared one, never assumed away.
    source "$_PC_LIB_DIR/wv-shell-scope.sh" 2>/dev/null || true
fi
# The suite pool comes from beside THIS hook first (scripts/hooks/../lib, the
# source a checkout runs), so a hook run from a checkout never gates with an
# installed pool of a different version; a copied .git/hooks entry falls back
# to the resolved and installed lib dirs. Missing everywhere fails the gate at
# the call site, never silently skips suites.
for _pc_cand in "${_pc_lib_cands[@]}"; do
    if [ -n "$_pc_cand" ] && [ -f "$_pc_cand/wv-gate-pool.sh" ]; then
        source "$_pc_cand/wv-gate-pool.sh"
        break
    fi
done
# The frozen candidate (wv-8e34cd), found the same way and required the same
# way: without it the gate would read whatever the index holds at each step.
for _pc_cand in "${_pc_lib_cands[@]}"; do
    if [ -n "$_pc_cand" ] && [ -f "$_pc_cand/wv-gate-snapshot.sh" ]; then
        source "$_pc_cand/wv-gate-snapshot.sh"
        break
    fi
done

# Check what's being committed — ordinary graph state skips the code gate
# --no-renames throughout: rename detection lists only the new path, so a
# git mv hid the old path from routing and dropped the file from A/M filters
# (wv-29d13c).
# _pc_list_failed <what> — a staged listing that failed is not an empty one:
# read as empty, the hook exited 0 before routing, or a check skipped the
# files it never saw (wv-9c6ae1). Runs in the hook's own shell, so it ends it.
_pc_list_failed() {
    echo "✗ Weave pre-commit: could not list the staged files ($1) — refusing rather than checking nothing" >&2
    exit 1
}

# FROZEN CANDIDATE (wv-8e34cd). The base commit and the index tree are recorded
# once, here, and every check below reads them, never the live index, HEAD or
# the working tree. A plain `git commit` holds no lock on the index during this
# hook and re-reads it afterwards, so a file another process staged mid-gate
# was committed unjudged; _pc_admit refuses that. WV_GATE_BASE is the base a
# history-sensitive suite judges against (wv-bab095, tests/lib/gate-base.sh).
if ! command -v gate_freeze >/dev/null 2>&1; then
    echo "✗ Weave pre-commit: the frozen-candidate library (wv-gate-snapshot.sh) was not found — refresh with ./install.sh" >&2
    exit 1
fi
if ! gate_freeze; then
    echo "✗ Weave pre-commit: could not record the index as a tree or resolve HEAD (unmerged paths?) — refusing rather than judging a moving target" >&2
    exit 1
fi
if ! command -v gate_pool_execution_mode >/dev/null 2>&1; then
    echo "✗ Weave pre-commit: the execution-mode guard was not found — refusing" >&2
    exit 1
fi
gate_pool_execution_mode "$WV_GATE_TREE"
# The protected lane judges against the commit its gate was copied from (S2a).
if [ -n "$_PC_LANE_BASE" ] && [ "${WV_GATE_BASE:-}" != "$_PC_LANE_BASE" ]; then
    echo "✗ Weave pre-commit: HEAD moved between copying its committed gate ($_PC_LANE_BASE) and freezing the candidate (${WV_GATE_BASE:-none}) — refusing; re-run the commit" >&2
    exit 1
fi
# A recovery run says which code it is: the dispatcher refuses one that does
# not, since it would have judged with HEAD's scripts/ (S2c, wv-0af8f0). Not
# hook_progress, which WV_HOOK_PROGRESS=0 silences.
if [ -n "$_PC_EXEC_TREE" ]; then
    echo "Weave pre-commit: recovery execution tree $_PC_EXEC_TREE acknowledged" >&2
fi
# A candidate that will be the next protected gate may hold no link or
# submodule under scripts/: the gate refuses to follow one, so it would refuse
# every commit after this one.
if ! _pc_gate_ls=$(git ls-tree -r "$WV_GATE_TREE" -- scripts 2>/dev/null); then
    echo "✗ Weave pre-commit: could not list the staged scripts/ — refusing" >&2
    exit 1
fi
if grep -q $'\tscripts/hooks/pre-commit-weave.sh$' <<< "$_pc_gate_ls"; then
    _pc_gate_odd=$(grep -v -e '^100644 ' -e '^100755 ' <<< "$_pc_gate_ls" || true)
    if [ -n "$_pc_gate_odd" ]; then
        echo "✗ Weave pre-commit: the staged scripts/ holds a link or submodule ($(head -1 <<< "$_pc_gate_odd" | cut -f2)); the gate runs from a copy of scripts/ and never follows one — refusing" >&2
        exit 1
    fi
fi
# Every lane judges one frozen tree (S2b): a candidate lane that froze another
# saw an index that moved after the protected lane froze it.
if [ -n "$_PC_CAND_PATH" ] && [ "$WV_GATE_TREE" != "$_PC_CAND_TREE" ]; then
    echo "✗ Weave pre-commit: the candidate lane for $_PC_CAND_PATH froze tree $WV_GATE_TREE, not the protected lane's $_PC_CAND_TREE — refusing; re-run the commit" >&2
    exit 1
fi
# The role contract (S2b; boundary rules 1 and 2), checked in the protected
# lane before anything else is judged: HEAD's contract decides which changed
# files are judged in their own lanes, and the candidate cannot narrow it.
if [ -n "$_PC_LANE_BASE" ] && [ -z "$_PC_CAND_PATH" ]; then
    if [ ! -f "$_PC_SCRIPTS/lib/wv-gate-lanes.sh" ] || ! source "$_PC_SCRIPTS/lib/wv-gate-lanes.sh" \
        || ! command -v gate_roles_check >/dev/null 2>&1; then
        echo "✗ Weave pre-commit: the committed gate has no candidate-lane library (wv-gate-lanes.sh) — refusing" >&2
        exit 1
    fi
    if ! gate_roles_check; then
        echo "✗ Weave pre-commit: ${_GATE_ROLES_WHY:-the gate role contract could not be checked} — refusing" >&2
        exit 1
    fi
    # Rule 5 before any suite runs (wv-c909ff): whether a changed entry point
    # no lane can run has a live repair record depends only on the frozen
    # paths and HEAD's records, so a refusal is known now, not after the
    # protected pass. Admission (gate_lanes_run) decides again over the same
    # tree; this admits nothing.
    gate_entry_points_preflight || exit 1
fi
# _pc_git_pid — the git process running this hook: the parent, or the nearest
# git ancestor when a hook manager sits between them. Fails when none is found
# (the hook run by hand, as the tests do).
_pc_git_pid() {
    local pid=$PPID comm _i
    for _i in 1 2 3 4 5; do
        case "$pid" in ''|*[!0-9]*|0|1) return 1 ;; esac
        comm=$(ps -o comm= -p "$pid" 2>/dev/null | sed 's/^ *//; s/ *$//')
        case "$comm" in git|*/git) printf '%s\n' "$pid"; return 0 ;; esac
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    done
    return 1
}
# _pc_bind — leave the judged tree for the reference-transaction hook, which
# refuses to publish a commit whose tree differs (R1, wv-5f9d1c). A check here
# cannot do it: git reads the index after this hook exits, and the gate still
# records its result first. Keyed by the git process and its start time, so a
# later process given the same pid never inherits the record.
_pc_bind() {
    local gitpid started dir
    if ! command -v wv_reftx_gate_installed >/dev/null 2>&1 || ! wv_reftx_gate_installed; then
        hook_progress "admission is check-then-use here: no Weave reference-transaction hook (git 2.28+) binds the commit to the judged tree, so a file staged after this check could still be committed — run ./install.sh (this repository) or wv init-repo --update"
        return 0
    fi
    gitpid=$(_pc_git_pid) || return 0
    started=$(ps -o lstart= -p "$gitpid" 2>/dev/null | sed 's/^ *//; s/ *$//')
    dir=$(git rev-parse --git-path weave-gate 2>/dev/null)
    if [ -z "$started" ] || [ -z "$dir" ] || ! mkdir -p "$dir" 2>/dev/null \
        || ! printf 'tree=%s\nstart=%s\nlanes=%s\n' "$WV_GATE_TREE" "$started" "${_GATE_LANES_DONE:-}" \
            > "$dir/admitted-$gitpid.tmp" 2>/dev/null \
        || ! mv -f "$dir/admitted-$gitpid.tmp" "$dir/admitted-$gitpid" 2>/dev/null; then
        echo "✗ Weave pre-commit: could not record the judged tree for the reference-transaction hook, so the commit would not be bound to it — refusing" >&2
        exit 1
    fi
    # Records of commits that never reached a ref update (a commit-msg hook
    # refused, say) are dropped after a day.
    find "$dir" -maxdepth 1 -name 'admitted-*' -mmin +1440 -delete 2>/dev/null || true
}
# _pc_admit — the only way this hook admits a commit once the candidate is
# frozen: git must be about to commit exactly what was judged, and the
# reference-transaction hook holds it to that.
_pc_admit() {
    if ! gate_frozen_intact; then
        echo "✗ Weave pre-commit: the index or HEAD changed while the gate ran, so git would commit something other than what was checked — re-run the commit" >&2
        exit 1
    fi
    # Each changed gate file is then judged in its own lane (S2b); a
    # candidate lane leaves admission and its record to the protected lane.
    if [ -n "$_PC_CAND_PATH" ]; then
        exit 0
    fi
    if [ -n "$_PC_LANE_BASE" ] && ! gate_lanes_run "${_wv_lane_file%/*}"; then
        exit 1
    fi
    _pc_bind
    exit 0
}
# _pc_changed_lines <diff-filter> — the frozen transition's paths, one a line.
_pc_changed_lines() {
    local -a _paths=()
    mapfile -d '' -t _paths < <(gate_changed "$1")
    wait $! || return 1
    [ "${#_paths[@]}" -eq 0 ] || printf '%s\n' "${_paths[@]}"
}
STAGED_FILES=$(_pc_changed_lines '') || _pc_list_failed "the frozen candidate"
[ -z "$STAGED_FILES" ] && _pc_admit

# A commit cannot remove its own enforcement prerequisite (wv-49b687): where a
# tracked file switches a check on, the check applies when HEAD OR the index has
# it, so staging its deletion or edit with other content does not disable it
# for that same commit. The next commit is judged by what this one left. A side
# that cannot be read counts as having it: the check then runs.
_pc_tracked_at_head_or_index() {  # <path>
    local _side
    local -a _paths=()
    for _side in index base; do
        mapfile -d '' -t _paths < <(gate_ls "$_side" "$1")
        wait $! || return 0
        [ "${#_paths[@]}" -gt 0 ] && return 0
    done
    return 1
}

# Active-memory changes also change generated instructions (wv-ff0419).
# Run the configured parity check before graph-only/checkpoint exits, against
# the index: an unstaged render cannot make a stale committed projection pass.
# Ordinary task updates and candidate-memory imports keep their cheap bypass.
# Configured by HEAD's map or the staged one, so dropping the row in the same
# commit does not skip it (wv-49b687).
# The maps this commit is routed by, read once from the frozen sides. One that
# git cannot read, or holds as a link (whose blob is a pathname, not a map),
# refuses: read as empty it routed nothing (R4, wv-77b743).
_pc_maps=""
for _pc_side in index base; do
    _pc_rc=0
    _pc_map_text=$(gate_show "$_pc_side" .weave/test-map.conf 2>/dev/null) || _pc_rc=$?
    case "$_pc_rc" in
        0) _pc_maps+="$_pc_map_text"$'\n' ;;
        1) ;;
        3) echo "✗ Weave pre-commit: .weave/test-map.conf in the frozen $_pc_side is not a regular file — the gate does not follow links" >&2
           exit 1 ;;
        *) echo "✗ Weave pre-commit: could not read .weave/test-map.conf from the frozen $_pc_side" >&2
           exit 1 ;;
    esac
done
if grep -Fxq '.weave/nodes.jsonl' <<< "$STAGED_FILES" \
    && grep -qE '^[^#].*=.*tests/test-memory-projection-parity.sh' <<< "$_pc_maps"; then
    _pc_memory_filter='[.[] | .metadata |= (if type == "string" then fromjson else . // {} end)
        | select(.metadata.type == "memory" and (.metadata.mem_status // "active") == "active")
        | {id, text, verified_at: .metadata.verified_at}] | sort_by(.id)'
    _pc_old_memory=$(gate_show base .weave/nodes.jsonl 2>/dev/null | jq -sc "$_pc_memory_filter") || exit 1
    _pc_new_memory=$(gate_show index .weave/nodes.jsonl 2>/dev/null | jq -sc "$_pc_memory_filter") || exit 1
    if [ "$_pc_old_memory" != "$_pc_new_memory" ]; then
        hook_progress "active graph memory changed — checking staged projections"
        _pc_memory_dir=$(mktemp -d "${TMPDIR:-/tmp}/wv-memory.XXXXXX" 2>/dev/null) || _pc_memory_dir=""
        if [ -z "$_pc_memory_dir" ] || [ ! -d "$_pc_memory_dir" ]; then
            echo "✗ memory parity: could not create a frozen subject — refusing" >&2
            exit 1
        fi
        # Keep the entire graph, including delta catalog and replay markers.
        # A link would read mutable bytes outside this frozen subject.
        _pc_memory_roots=(.weave CLAUDE.md .claude/MEMORY.md .codex/MEMORY.md
            .github/copilot-instructions.md AGENTS.md .codex/weave.json)
        if ! _pc_memory_modes=$(git ls-tree -r "$WV_GATE_TREE" -- "${_pc_memory_roots[@]}" 2>/dev/null) \
            || grep -qvE '^100(644|755) blob ' <<< "$_pc_memory_modes"; then
            rm -rf "$_pc_memory_dir"
            echo "✗ memory parity: frozen graph and projections must be readable regular files — refusing" >&2
            exit 1
        fi
        _pc_memory_paths=()
        mapfile -d '' -t _pc_memory_paths < <(gate_ls index "${_pc_memory_roots[@]}")
        if ! wait $! || ! gate_materialise index "$_pc_memory_dir" "${_pc_memory_paths[@]}"; then
            rm -rf "$_pc_memory_dir"
            echo "✗ memory parity: could not materialise the frozen graph and projections — refusing" >&2
            exit 1
        fi
        _pc_memory_rc=0
        bash "$_PC_SCRIPTS/../tests/test-memory-projection-parity.sh" --subject "$_pc_memory_dir" || _pc_memory_rc=$?
        rm -rf "$_pc_memory_dir"
        if [ "$_pc_memory_rc" -ne 0 ]; then
            exit 1
        fi
    fi
fi

# Graph state (state.sql, nodes/edges jsonl, deltas, trails) is what wv writes
# as the graph changes, and it selects no suite. The rest of .weave/ --
# test-map.conf, quality.conf, patterns/, evidence/ -- is configuration someone
# edits on purpose, and its own test-map rows must fire: dropping every .weave/
# path let a map-only commit exit 0 with no suite (wv-a118d6). The allowlist is
# the one the checkpoint sites commit by (wv-2e6341), so the two cannot drift.
# NON_WEAVE_FILES keeps its name for the code below; it now means "staged files
# outside graph state".
if command -v wv_non_graph_state_paths >/dev/null 2>&1; then
    NON_WEAVE_FILES=$(wv_non_graph_state_paths <<< "$STAGED_FILES") || _pc_list_failed "graph-state classification"
else
    # Without the classifier nothing is graph state: every staged file is
    # gated. Treating all of .weave/ as graph state would pass configuration
    # (test-map.conf, quality.conf, shellcheck.conf) ungated (wv-68aeff).
    NON_WEAVE_FILES="$STAGED_FILES"
    echo "Weave pre-commit: graph-state helper not found (wv-checkpoint-ci.sh) — every staged file is gated, graph state included; refresh with ./install.sh" >&2
fi
# The only content admitted without a claim: graph state, as the classifier
# above decides it. The checkpointers commit exactly that and pass here; the
# WV_AUTO_CHECKPOINT_ACTIVE flag, WV_STYLE_COMMIT and the whitespace-only
# shortcut no longer admit anything (wv-68aeff): a flag is not authority, and
# git diff -w cannot show that Python indentation or whitespace inside a
# string left behaviour unchanged.
[ -z "$NON_WEAVE_FILES" ] && _pc_admit

# Substantive content with no wv to judge it: refused in a repository that
# tracks .weave/ (a Weave-managed one), admitted elsewhere (wv-68aeff).
# Managed means HEAD OR the index tracks it: judged by the index alone, a
# commit that stages the deletion of .weave/ removed its own enforcement
# prerequisite and passed (wv-49b687).
if [ ! -x "$WV" ]; then
    if _pc_tracked_at_head_or_index .weave; then
        echo "✗ Weave pre-commit: wv was not found (not on PATH, no scripts/wv), so this Weave-managed repository cannot check the staged changes." >&2
        echo "  Install or repair Weave (./install.sh in the Weave source, or the release installer), then retry; or commit only graph state." >&2
        exit 1
    fi
    _pc_admit
fi

# ── Gate measurement (wv-ffda33) ── Armed only past the early exits above, so
# .weave-only and checkpoint commits do not drown real gate times. Every suite
# record this gate writes carries WV_GATE_PHASE/WV_GATE_ID, and the EXIT trap
# writes one gate record -- wall time, the estimate it announced, the suites it
# selected, and how it ended -- on success and on every failure path alike.
export WV_GATE_PHASE=pre-commit
WV_GATE_ID="pc-$(date +%s%N 2>/dev/null || date +%s)-$$"
export WV_GATE_ID
_pc_gate_t0=$(date +%s%N 2>/dev/null || echo 0)
_pc_gate_suites=""
_pc_gate_estimate_ms=""
_pc_gate_finish() {
    local rc=$?
    "$WV" test-record gate --gate --exit="$rc" --duration="$(hook_duration_ms "$_pc_gate_t0")" \
        --execution-mode="${WV_GATE_EXECUTION_MODE:-}" \
        --estimate="$_pc_gate_estimate_ms" --suites="$_pc_gate_suites" \
        --started-ms="$(_pc_ns_to_ms "$_pc_gate_t0" 2>/dev/null)" >/dev/null 2>&1 || true
    return "$rc"
}
[ -n "$_PC_CAND_PATH" ] || trap _pc_gate_finish EXIT

# Admission (execute phase only): an active node CLAIMED BY THE COMMITTING
# ACTOR. Counting every active node let one agent's claim admit another
# agent's, or a human's, commit (wv-99d559). The actor is resolved exactly as
# the Weave-ID trailers resolve it (wv list --claimed-by=current, i.e.
# resolve_agent_id from the committing process's environment), so admission
# and attribution follow one identity policy; they remain separate hooks and
# queries, not one transaction. Taking over someone else's node is
# `wv work <id> --force`, which the claim_ownership rule records.
# A failed listing reads as no claim: admission fails closed.
# The guarantee is ACTOR-owned admission, not session isolation: sessions that
# resolve the same identity (one harness, host and user) admit each other's
# commits until each sets its own WV_AGENT_ID (wv-d7f53e).
# _pc_require_claim <when> — exits 1 unless the committing actor holds a
# claim. Called just before the suite pool, so a missing claim is not reported
# after the protected pass (wv-c909ff), and again at admission, which decides:
# a claim can be closed or taken over while the suites run.
# _pc_worktree_note — in a linked worktree (its git dir is not the common
# dir), says the worktree keeps its own graph: a claim in the main checkout
# does not admit a commit here (owner decision wv-d88fed). Prints nothing in
# an ordinary checkout or when git cannot answer.
_pc_worktree_note() {
    local gd common main
    gd=$(git rev-parse --absolute-git-dir 2>/dev/null) || return 0
    common=$(git rev-parse --git-common-dir 2>/dev/null) && common=$(cd "$common" 2>/dev/null && pwd -P) || return 0
    [ "$(cd "$gd" 2>/dev/null && pwd -P)" != "$common" ] || return 0
    main=$(git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')
    echo "   This is a linked worktree of:"
    echo "     ${main:-another checkout}"
    echo "   It keeps its own Weave graph, so a claim made there does not admit a commit"
    echo "   here. In this worktree run wv load, then claim:"
    echo "     wv work <id>  |  wv add \"...\" --status=active"
    echo ""
}

_pc_require_claim() {
    hook_progress "checking for an active Weave claim held by this actor ($1)..."
    # A failed listing still reads as no claim (fail closed), but the refusal
    # says so, so it is not mistaken for a missing claim.
    _pc_list_err=""
    _pc_active_json=$("$WV" list --status=active --json 2>/dev/null) \
        || { _pc_list_err="wv list --status=active exited $?"; _pc_active_json="[]"; }
    _pc_mine_json=$("$WV" list --status=active --claimed-by=current --json 2>/dev/null) \
        || { _pc_list_err="${_pc_list_err:+$_pc_list_err; }wv list --claimed-by=current exited $?"; _pc_mine_json="[]"; }
    ACTIVE_COUNT=$(jq 'length' <<<"$_pc_active_json" 2>/dev/null) || ACTIVE_COUNT=0
    _pc_mine_count=$(jq 'length' <<<"$_pc_mine_json" 2>/dev/null) || _pc_mine_count=0
    [ -z "$_pc_list_err" ] || echo "⚠  Weave pre-commit: could not list the active claims ($_pc_list_err) — read as none; retry the commit" >&2

    if [ "${ACTIVE_COUNT:-0}" != "0" ] && [ "${_pc_mine_count:-0}" = "0" ]; then
        _pc_actor=$(resolve_agent_id 2>/dev/null) || _pc_actor=""
        {
            echo ""
            echo "⚠  No active Weave node is claimed by ${_pc_actor:-this actor} — commit blocked."
            echo "   Admission needs a claim held by whoever commits; the active claims are:"
            jq -r '.[] | "     \(.id)  claimed by \((.metadata|(fromjson? // .)|.claimed_by) // "nobody")  \(.text[0:60])"' \
                <<<"$_pc_active_json" 2>/dev/null || true
            echo ""
            echo "   Continue that work as yourself:  wv work <id> --force   (recorded as a takeover)"
            echo "   Or claim your own:               wv work <id>  |  wv add \"...\" --status=active"
            echo ""
            _pc_worktree_note
        } >&2
        exit 1
    fi

    if [ "$ACTIVE_COUNT" = "0" ] || [ -z "$ACTIVE_COUNT" ]; then
        cat >&2 << 'EOF'

╔══════════════════════════════════════════════════════════════╗
║  ⚠  No active Weave node — commit blocked                    ║
║                                                              ║
║  Every code change must be tracked. Either:                  ║
║    wv work <id>         # claim an existing task             ║
║    wv add "..." --gh    # create + track new work            ║
║                                                              ║
║  Then retry your commit.                                     ║
║                                                              ║
║  Bypass: git commit --no-verify                              ║
║          WV_SKIP_PRECOMMIT=1 git commit                      ║
╚══════════════════════════════════════════════════════════════╝

EOF
        _pc_worktree_note >&2
        exit 1
    fi
}

# ── Install-drift advisory (cross-agent) ──
# Source admission does not deploy the working tree (wv-801b89). Drift stays
# visible, but installation is an explicit operation after source review.
if [ -z "$_PC_CAND_PATH" ] && command -v _wv_source_drift >/dev/null 2>&1; then
    if _pc_drift=$(_wv_source_drift); then
        echo "Weave pre-commit: install drift ($_pc_drift) — source checks continue without installing; run ./install.sh explicitly after reviewing the source when installation is intended." >&2
    fi
fi

# Run ruff linter on staged Python files (added/modified only — skip deletions)
_pc_py_paths=$(mktemp "${TMPDIR:-/tmp}/wv-ruff-paths.XXXXXX") || _pc_list_failed "Python files"
if ! gate_changed AM > "$_pc_py_paths"; then
    rm -f "$_pc_py_paths"
    _pc_list_failed "added and modified Python files"
fi
STAGED_PY_FILES=()
while IFS= read -r -d '' _pc_py; do
    case "$_pc_py" in
        .weave/*) ;;
        *.py) STAGED_PY_FILES+=("$_pc_py") ;;
    esac
done < "$_pc_py_paths"
rm -f "$_pc_py_paths"
if [ "${#STAGED_PY_FILES[@]}" -gt 0 ]; then
    if command -v ruff > /dev/null 2>&1; then
        hook_progress "running ruff on staged Python files..."
        # Freeze both source and configuration (wv-3080d7). Keep Ruff's native
        # nested discovery/merging, but only repository-relative, regular,
        # tracked inheritance is authority. A root fallback prevents discovery
        # above the snapshot or in the user's configuration directory.
        # -I also prevents a working-tree module shadowing the parser itself.
        if ! RUFF_OUT=$(python3 -I - "$WV_GATE_TREE" "${STAGED_PY_FILES[@]}" 2>&1 <<'PY'
import os
import posixpath
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path, PurePosixPath

def git(*args):
    return subprocess.check_output(["git", "--no-replace-objects", *args])

try:
    tree, *paths = sys.argv[1:]
    entries = {}
    for entry in git("ls-tree", "-r", "-z", "--full-tree", tree).split(b"\0"):
        if entry:
            meta, path = entry.split(b"\t", 1)
            entries[os.fsdecode(path)] = meta.split()
    with tempfile.TemporaryDirectory(prefix="wv-gate-ruff-") as scratch:
        root = Path(scratch) / "tree"
        root.mkdir()
        written, configs, visiting = {}, {}, set()

        def materialise(path):
            if path not in written:
                entry = entries.get(path)
                if not entry or entry[0] not in (b"100644", b"100755"):
                    raise ValueError(f"not a frozen regular file: {path}")
                data = git("cat-file", "blob", entry[2].decode())
                target = root / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
                target.chmod(0o755 if entry[0] == b"100755" else 0o644)
                written[path] = data
            return written[path]

        def config(path):
            if path in visiting:
                raise ValueError(f"configuration inheritance cycle: {path}")
            if path in configs:
                return configs[path]
            visiting.add(path)
            data = tomllib.loads(materialise(path).decode("utf-8"))
            is_project = PurePosixPath(path).name == "pyproject.toml"
            settings = data.get("tool", {}).get("ruff") if is_project else data
            if settings is not None:
                inherit = settings.get("extend")
                if inherit is not None:
                    if (not isinstance(inherit, str) or inherit.startswith(("/", "~"))
                            or "$" in inherit):
                        raise ValueError(f"inheritance must be repository-relative: {path}")
                    parent = posixpath.normpath(posixpath.join(posixpath.dirname(path), inherit))
                    if parent == ".." or parent.startswith("../"):
                        raise ValueError(f"inheritance escapes the frozen tree: {path}")
                    config(parent)
            visiting.remove(path)
            configs[path] = settings is not None
            return configs[path]

        # Import classification also needs unchanged modules and package
        # directories. Supply frozen context, but lint only the selected paths.
        for directory in {PurePosixPath(path).parent for path in entries}:
            (root / directory).mkdir(parents=True, exist_ok=True)
        for path, entry in entries.items():
            if path.endswith((".py", ".pyi")) and entry[0] in (b"100644", b"100755"):
                materialise(path)

        for path in paths:
            materialise(path)
            for directory in PurePosixPath(path).parents:
                # Ruff can infer target-version from a sibling pyproject even
                # when .ruff.toml or ruff.toml supplies the lint settings.
                project = str(directory / "pyproject.toml")
                if project in entries:
                    materialise(project)
                found = False
                for name in (".ruff.toml", "ruff.toml", "pyproject.toml"):
                    candidate = str(directory / name)
                    if candidate in entries and config(candidate):
                        found = True
                        break
                if found:
                    break
        if not any((root / name).exists() for name in (".ruff.toml", "ruff.toml")) \
                and not configs.get("pyproject.toml", False):
            (root / ".ruff.toml").write_text("", encoding="utf-8")
        env = os.environ.copy()
        env.pop("RUFF_OUTPUT_FILE", None)
        sys.exit(subprocess.call(["ruff", "check", "--no-fix", "--no-fix-only",
                 "--cache-dir", str(Path(scratch) / "cache"), "--", *paths], cwd=root, env=env))
except (OSError, ValueError, subprocess.CalledProcessError) as error:
    print(f"ruff frozen inputs: {error}", file=sys.stderr)
    sys.exit(2)
PY
        ); then
            echo "" >&2
            echo "✗ ruff lint errors in staged files:" >&2
            echo "$RUFF_OUT" >&2
            echo "" >&2
            echo "  Fix with: ruff check --fix <file>  (then re-stage)" >&2
            echo "" >&2
            exit 1
        fi
    fi
fi

# The weave_quality pytest suite asserts the managed-rule manifest is complete
# and that every managed rule carries an executable example, so a rule YAML is
# inside its scope even when no Python file changes. Keyed on staged .py alone,
# it never ran for a rule-only commit: prose-significance-scaffold was added
# with its manifest entry but no example, and sat failing until an unrelated
# Python change happened to stage alongside it.
_pc_amd=$(_pc_changed_lines AMD) || _pc_list_failed "added, modified and deleted files"
STAGED_QUALITY_RULES=$(grep -E '^(templates/quality-patterns|\.weave/patterns)/managed/' <<< "$_pc_amd" || true)
if [ "${#STAGED_PY_FILES[@]}" -gt 0 ] || [ -n "$STAGED_QUALITY_RULES" ]; then
    _pc_pytest_dirs=()
    if ! _pc_pytest_paths=$(git ls-tree -d --name-only "$WV_GATE_TREE" -- tests/weave_quality tests/weave_indexer); then
        echo "✗ Weave pre-commit: cannot list frozen focused pytest targets — refusing" >&2
        exit 1
    fi
    while IFS= read -r _pc_dir; do
        [ -z "$_pc_dir" ] || _pc_pytest_dirs+=("$_pc_dir")
    done <<< "$_pc_pytest_paths"
    if [ "${#_pc_pytest_dirs[@]}" -gt 0 ]; then
        _pc_pytest_mode=$(gate_pool_suite_mode tests/lib/run-pytest.sh) || exit 1
        hook_progress "running focused pytest checks (execution mode: $_pc_pytest_mode)..."
        _pc_pytest_work=$(wv_scratch_create) || {
            echo "✗ Weave pre-commit: cannot create focused pytest scratch — refusing" >&2
            exit 1
        }
        if [ "$_pc_pytest_mode" = checkout ]; then
            # Match consumer checkout execution, including an ignored venv or
            # an activated interpreter on PATH. No provisioning or reuse.
            _pc_pytest_python=python3
            [ ! -x "$REPO_ROOT/.venv/bin/python3" ] || _pc_pytest_python="$REPO_ROOT/.venv/bin/python3"
            _pc_pytest_command=("$_pc_pytest_python" -m pytest "${_pc_pytest_dirs[@]}" -q --tb=short -p no:cacheprovider)
        else
            _pc_pytest_args=(--repo "$REPO_ROOT" --tree "$WV_GATE_TREE" --mode auto
                --policy "$_PC_LIB_DIR/wv-gate-provision.json" --work "$_pc_pytest_work/run"
                --provenance "$_pc_pytest_work/identity.json")
            [ -z "${WV_GATE_BASE:-}" ] || _pc_pytest_args+=(--base "$WV_GATE_BASE")
            [ -z "$_PC_EXEC_TREE" ] || _pc_pytest_args+=(--authority "$_PC_EXEC_TREE")
            # Self-hosting keeps staged targets, locks and a fresh venv,
            # never the checkout's interpreter or mutable launcher.
            _pc_pytest_command=(python3 -I "$_PC_LIB_DIR/wv-gate-suite.py" "${_pc_pytest_args[@]}"
                tests/lib/run-pytest.sh "${_pc_pytest_dirs[@]}")
        fi
        if ! gate_run_bounded "focused pytest" "${WV_GATE_TIMEOUT:-1800}" \
            env -u WV_CALL_LOG -u WV_GATE_LANE_JOBS -u WV_SCRATCH_ROOT \
            -u GIT_INDEX_FILE -u GIT_DIR -u GIT_WORK_TREE -u GIT_PREFIX -u GIT_COMMON_DIR \
            -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_NAMESPACE \
            "${_pc_pytest_command[@]}"; then
            rm -rf "$_pc_pytest_work"
            echo "" >&2
            echo "✗ pytest tests failed — fix before committing." >&2
            exit 1
        fi
        rm -rf "$_pc_pytest_work"
    fi
fi

# Run shellcheck on the STAGED CONTENT of shell files.
#
# Lint is not reachable through impact-selected suite routing: shellcheck lives
# in `make check`, so a lint regression in a file the map DOES route stays
# invisible behind green suites (b3f84bbb introduced SC1090 in pre-action.sh,
# a mapped file whose suites all passed, and it went two commits unnoticed).
#
# THE BLOB, NOT THE WORKING TREE. Naming staged files and letting shellcheck
# read them off disk checks whatever is in the worktree, so a dirty index behind
# a clean worktree committed content that was never linted.
#
# NUL-SAFE END TO END. An earlier version piped `-z` output through `tr '\0'
# '\n'`, which throws the safety away at the first step: a path containing a
# newline was silently skipped. `xargs` then split paths on spaces, turning one
# real file into two nonexistent ones and blocking the commit for files that
# were fine. Paths are read into an array with `mapfile -d ''` and passed as
# arguments to the linter — no tr, no xargs, no word splitting.
#
# FAILS CLOSED. If the temp dir or the materialisation cannot be produced, the
# commit is refused. Warning and continuing turns the gate off silently, which
# is the failure mode this whole gate exists to prevent.
if command -v shellcheck >/dev/null 2>&1; then
    _pc_sc_all=()
    mapfile -d '' -t _pc_sc_all < <(gate_changed ACMR)
    wait $! || _pc_list_failed "files for shellcheck"
    _pc_sc_files=()
    _pc_sc_dir=""
    _pc_sc_lint=""
    _pc_sc_refuse() {
        [ -n "$_pc_sc_dir" ] && rm -rf "$_pc_sc_dir"
        [ -n "$_pc_sc_lint" ] && rm -rf "$_pc_sc_lint"
        echo "✗ shellcheck gate: $1 — refusing to commit unlinted content" >&2
        exit 1
    }
    # _pc_sc_materialise <index path>... -> the staged bytes under $_pc_sc_dir.
    # Called in this shell, never on the right of a pipe: there it would set
    # _pc_sc_dir and exit in a subshell, and a failure would pass.
    _pc_sc_materialise() {
        if [ -z "$_pc_sc_dir" ]; then
            _pc_sc_dir=$(mktemp -d "${TMPDIR:-/tmp}/wv-sc.XXXXXX" 2>/dev/null) || _pc_sc_dir=""
            # Checked BEFORE any --prefix is built: an empty value would make the
            # prefix "/" and materialise the index over the filesystem root.
            [ -n "$_pc_sc_dir" ] && [ -d "$_pc_sc_dir" ] || _pc_sc_refuse "could not create a temp directory"
        fi
        gate_materialise index "$_pc_sc_dir" "$@" \
            || _pc_sc_refuse "could not materialise the staged index"
    }
    # _pc_sc_select: append what the declaration last read selects among the
    # staged files (materialised bytes) to _pc_sc_files.
    _pc_sc_select() {
        local -a sel=()
        mapfile -d '' -t sel < <(printf '%s\0' "${_pc_sc_all[@]}" | wv_shell_scope_select "$_pc_sc_dir")
        wait "$!" || _pc_sc_refuse "selecting the declared scope failed"
        _pc_sc_files+=("${sel[@]}")
    }
    # REPO-DECLARED SCOPE (wv-b9ce14, wv-7608e6). A repository adopts it only
    # by a tracked .weave/shellcheck.conf; no other file of any name turns it
    # on. Its selection (extension or shebang, declared exclusions) runs over
    # the materialised staged bytes, so a shebang is the one being committed. A
    # repository without it keeps the fixed patterns below. A staged
    # declaration that cannot be read fails closed.
    # HEAD's declaration applies too when this commit deletes or edits it: the
    # commit is linted under the union of both selections, so it cannot narrow
    # or drop the scope that lints it (wv-49b687). A HEAD declaration this
    # library cannot read is applied with no exclusions, the strictest reading,
    # so it never blocks the commit that repairs it.
    # A side with no declaration has a policy too: the fixed patterns. Its
    # selection joins the union, so adopting a scope that excludes scripts/,
    # or deleting HEAD's declaration, still lints what the side without one
    # lints (wv-5ba258). Only both sides declaring leaves the patterns out.
    # _pc_sc_legacy: append the fixed patterns' selection to _pc_sc_files.
    _pc_sc_legacy() {
        local f
        for f in "${_pc_sc_all[@]}"; do
            case "$f" in
                scripts/*.sh|.claude/*.sh|install.sh|install-mcp.sh|build-release.sh|scripts/wv-battery-wrapper)
                    _pc_sc_files+=("$f") ;;
            esac
        done
    }
    # _pc_sc_blob <var> <side> <path> — set <var> to the frozen blob id, empty
    # when the side has none; a side that cannot be read refuses. In this
    # shell, never a command substitution, so the refusal ends the hook.
    _pc_sc_blob() {
        local _id rc=0
        _id=$(gate_blob "$2" "$3") || rc=$?
        [ "$rc" -ne 3 ] || _pc_sc_refuse "$3 in the frozen $2 is not a regular file (a link is not followed)"
        [ "$rc" -le 1 ] || _pc_sc_refuse "could not read $3 from the frozen $2"
        printf -v "$1" '%s' "$_id"
    }
    _pc_sc_blob _pc_sc_conf_index index .weave/shellcheck.conf
    _pc_sc_blob _pc_sc_conf_head base .weave/shellcheck.conf
    if [ "${#_pc_sc_all[@]}" -gt 0 ] && [ -n "$_pc_sc_conf_index$_pc_sc_conf_head" ]; then
        command -v wv_shell_scope_select >/dev/null 2>&1 \
            || _pc_sc_refuse ".weave/shellcheck.conf declares a scope, but this Weave install has no wv-shell-scope.sh (re-run install)"
        _pc_sc_materialise "${_pc_sc_all[@]}"
        if [ -n "$_pc_sc_conf_index" ]; then
            _pc_sc_materialise ".weave/shellcheck.conf"
            _pc_sc_why=$(wv_shell_scope_read_conf "$_pc_sc_dir/.weave/shellcheck.conf") \
                || _pc_sc_refuse "staged .weave/shellcheck.conf: $_pc_sc_why"
            wv_shell_scope_read_conf "$_pc_sc_dir/.weave/shellcheck.conf" >/dev/null
            _pc_sc_select
        fi
        if [ -n "$_pc_sc_conf_head" ] && [ "$_pc_sc_conf_head" != "$_pc_sc_conf_index" ]; then
            _pc_sc_head_conf=$(mktemp "${TMPDIR:-/tmp}/wv-sc-head.XXXXXX" 2>/dev/null) \
                || _pc_sc_refuse "could not create a temp file"
            git cat-file blob "$_pc_sc_conf_head" > "$_pc_sc_head_conf" 2>/dev/null \
                || { rm -f "$_pc_sc_head_conf"; _pc_sc_refuse "could not read HEAD's .weave/shellcheck.conf"; }
            if ! wv_shell_scope_read_conf "$_pc_sc_head_conf" >/dev/null; then
                printf '[scope]\nmode = derived\n' > "$_pc_sc_head_conf"
                wv_shell_scope_read_conf "$_pc_sc_head_conf" >/dev/null \
                    || { rm -f "$_pc_sc_head_conf"; _pc_sc_refuse "could not apply HEAD's .weave/shellcheck.conf"; }
            fi
            rm -f "$_pc_sc_head_conf"
            _pc_sc_select
        fi
        if [ -z "$_pc_sc_conf_index" ] || [ -z "$_pc_sc_conf_head" ]; then
            _pc_sc_legacy
        fi
        [ "${#_pc_sc_files[@]}" -eq 0 ] \
            || mapfile -d '' -t _pc_sc_files < <(printf '%s\0' "${_pc_sc_files[@]}" | LC_ALL=C sort -zu)
    else
        _pc_sc_legacy
        [ "${#_pc_sc_files[@]}" -eq 0 ] || _pc_sc_materialise "${_pc_sc_files[@]}"
    fi
    if [ "${#_pc_sc_files[@]}" -eq 0 ]; then
        [ -n "$_pc_sc_dir" ] && rm -rf "$_pc_sc_dir"
    else
        hook_progress "running shellcheck on ${#_pc_sc_files[@]} staged shell file(s)..."
        # CONFIGURATION FROM THE FROZEN TREES ONLY (wv-e929cf). shellcheck reads
        # the nearest .shellcheckrc or shellcheckrc above each file, else the
        # user's (~/.shellcheckrc, $XDG_CONFIG_HOME/shellcheckrc), and
        # SHELLCHECK_OPTS. Run from a temp dir, it took whatever sat above that
        # dir and in HOME, and never saw a nested rc. Now each file's nearest rc
        # is resolved in a frozen tree as shellcheck 0.10 resolves it
        # (.shellcheckrc before shellcheckrc in one directory; the nearest wins
        # whole, nothing merges), and it is the only rc the run can see: written
        # at the root of a lint directory holding nothing but the files, which
        # ends the search there on any shellcheck version. A file with no rc in
        # the tree gets an empty one. SHELLCHECK_OPTS is cleared.
        # The index's hierarchy, and HEAD's as well where it differs, so a
        # suppression cannot land with the code it suppresses (wv-49b687); every
        # run must pass. A working-tree rc that neither side tracks no longer
        # applies: the working tree is not what is committed.
        _pc_sc_rc_side=() _pc_sc_rc_path=() _pc_sc_rc_blob=()
        # _pc_sc_rcmap <side>: record every rc file of the side's frozen tree.
        _pc_sc_rcmap() {
            local _p
            local -a _all=()
            mapfile -d '' -t _all < <(gate_ls "$1")
            wait $! || _pc_sc_refuse "could not list the frozen $1 for its shellcheck configuration"
            for _p in "${_all[@]}"; do
                case "/$_p" in
                    */.shellcheckrc|*/shellcheckrc)
                        # Not _id: _pc_sc_blob's own local would take the value.
                        _pc_sc_blob _pc_sc_rcid "$1" "$_p"
                        [ -n "$_pc_sc_rcid" ] || _pc_sc_refuse "could not read $_p from the frozen $1"
                        _pc_sc_rc_side+=("$1"); _pc_sc_rc_path+=("$_p"); _pc_sc_rc_blob+=("$_pc_sc_rcid") ;;
                esac
            done
        }
        # _pc_sc_nearest <var> <side> <file>: set <var> to the blob of the rc
        # the linter would use for <file> in that tree, or "none".
        _pc_sc_nearest() {
            local _d=$3 _c _i
            while [ -n "$_d" ]; do
                case "$_d" in */*) _d=${_d%/*} ;; *) _d="" ;; esac
                for _c in "${_d:+$_d/}.shellcheckrc" "${_d:+$_d/}shellcheckrc"; do
                    for _i in "${!_pc_sc_rc_path[@]}"; do
                        if [ "${_pc_sc_rc_side[$_i]}" = "$2" ] && [ "${_pc_sc_rc_path[$_i]}" = "$_c" ]; then
                            printf -v "$1" '%s' "${_pc_sc_rc_blob[$_i]}"
                            return 0
                        fi
                    done
                done
            done
            printf -v "$1" '%s' none
        }
        _pc_sc_rcmap index
        _pc_sc_rcmap base
        # An rc file is configuration, not a script, even with a shebang: linted
        # from the lint directory it would configure the files beside it.
        _pc_sc_lintable=()
        for _pc_f in "${_pc_sc_files[@]}"; do
            case "/$_pc_f" in */.shellcheckrc|*/shellcheckrc) ;; *) _pc_sc_lintable+=("$_pc_f") ;; esac
        done
        _pc_sc_files=("${_pc_sc_lintable[@]}")
        # Each file's rc in each tree; the runs, one per distinct rc, index first.
        _pc_sc_key_index=() _pc_sc_key_base=() _pc_sc_keys=() _pc_sc_key_head_only=()
        for _pc_i in "${!_pc_sc_files[@]}"; do
            _pc_sc_nearest _pc_sc_k index "${_pc_sc_files[$_pc_i]}"; _pc_sc_key_index[$_pc_i]=$_pc_sc_k
            _pc_sc_nearest _pc_sc_k base "${_pc_sc_files[$_pc_i]}"; _pc_sc_key_base[$_pc_i]=$_pc_sc_k
        done
        for _pc_sc_k in ${_pc_sc_key_index[@]+"${_pc_sc_key_index[@]}"}; do
            case " ${_pc_sc_keys[*]-} " in *" $_pc_sc_k "*) ;; *) _pc_sc_keys+=("$_pc_sc_k"); _pc_sc_key_head_only+=(0) ;; esac
        done
        for _pc_sc_k in ${_pc_sc_key_base[@]+"${_pc_sc_key_base[@]}"}; do
            case " ${_pc_sc_keys[*]-} " in *" $_pc_sc_k "*) ;; *) _pc_sc_keys+=("$_pc_sc_k"); _pc_sc_key_head_only+=(1) ;; esac
        done
        # Files to lint and no run planned would pass unlinted.
        [ "${#_pc_sc_files[@]}" -eq 0 ] || [ "${#_pc_sc_keys[@]}" -gt 0 ] \
            || _pc_sc_refuse "no lint run was planned for the selected files"
        _pc_sc_lint=$(mktemp -d "${TMPDIR:-/tmp}/wv-sc-lint.XXXXXX" 2>/dev/null) || _pc_sc_lint=""
        [ -n "$_pc_sc_lint" ] && [ -d "$_pc_sc_lint" ] || _pc_sc_refuse "could not create a temp directory"
        [ "${#_pc_sc_files[@]}" -eq 0 ] || gate_materialise index "$_pc_sc_lint" "${_pc_sc_files[@]}" \
            || _pc_sc_refuse "could not materialise the staged index"
        _pc_sc_rc=0
        _pc_sc_out=""
        for _pc_sc_n in "${!_pc_sc_keys[@]}"; do
            _pc_sc_k=${_pc_sc_keys[$_pc_sc_n]}
            _pc_sc_group=()
            for _pc_i in "${!_pc_sc_files[@]}"; do
                if [ "${_pc_sc_key_index[$_pc_i]}" = "$_pc_sc_k" ] || [ "${_pc_sc_key_base[$_pc_i]}" = "$_pc_sc_k" ]; then
                    _pc_sc_group+=("${_pc_sc_files[$_pc_i]}")
                fi
            done
            if [ "$_pc_sc_k" = none ]; then
                : > "$_pc_sc_lint/.shellcheckrc"
            else
                git cat-file blob "$_pc_sc_k" > "$_pc_sc_lint/.shellcheckrc" 2>/dev/null \
                    || _pc_sc_refuse "could not read a shellcheck configuration from git"
            fi
            _pc_sc_one=$( cd "$_pc_sc_lint" && env -u SHELLCHECK_OPTS shellcheck --severity=warning -- "${_pc_sc_group[@]}" 2>&1 ) && continue
            _pc_sc_rc=1
            _pc_sc_out="$_pc_sc_one"
            [ "${_pc_sc_key_head_only[$_pc_sc_n]}" = 1 ] \
                && _pc_sc_out="$_pc_sc_out"$'\n'"  (under HEAD's shellcheck configuration: this commit changes it, so it is linted under both)"
            break
        done
        rm -rf "$_pc_sc_lint"
        rm -rf "$_pc_sc_dir"
        if [ "$_pc_sc_rc" -ne 0 ]; then
            echo "" >&2
            echo "✗ shellcheck findings in STAGED content:" >&2
            echo "$_pc_sc_out" >&2
            echo "" >&2
            echo "  These are the bytes being committed — the working tree may differ." >&2
            echo "  Fix, then re-stage. Project-wide suppressions live in .shellcheckrc" >&2
            echo "" >&2
            exit 1
        fi
    fi
fi

# Prose gate for staged markdown (wv-7816b4). Docs are not reachable through
# impact-selected suite routing -- most of docs/ maps to no suite at all -- so
# prose drift and markdown defects land unchecked. This session reflowed a doc
# to 100 columns, split `(kind, id, lineage_seq, lineage_actor)` across a line
# break inside a code span, and committed it; only a post-hoc scan caught it.
#
# THE BLOB, NOT THE WORKING TREE, for the same reason shellcheck above uses it.
#
# BASELINE-RELATIVE. Only findings the diff ADDS block. The repo carries
# hundreds of pre-existing hits (82 `, so` in CHANGELOG.md); failing on
# inherited debt would train the bypass reflex this gate exists to avoid.
#
# SOURCE-SCOPED. Every rule is `info` severity, so severity cannot separate a
# rendering defect from house style. Managed + custom rules (the curated AI-tell
# corpus) block; default rules advise.
#
# FAILS CLOSED on a materialisation it cannot produce, open on a missing
# scanner -- an unavailable optional tool must not wedge every commit.
_pc_md_all=()
mapfile -d '' -t _pc_md_all < <(gate_changed ACMR)
wait $! || _pc_list_failed "files for the prose scan"
_pc_md_files=()
for _pc_f in "${_pc_md_all[@]}"; do
    case "$_pc_f" in
        *.md) _pc_md_files+=("$_pc_f") ;;
    esac
done
# Source-only, like the evidence checks below: they run from the committed
# gate, so a hook whose HEAD carries none (a consumer) skips them rather than
# run checker bytes from the working tree (S2b review N1, wv-c424ed).
if [ "${#_pc_md_files[@]}" -gt 0 ] && [ -n "$_PC_LANE_BASE" ] && [ -f "$_PC_SCRIPTS/prose-gate.py" ]; then
    hook_progress "prose gate on ${#_pc_md_files[@]} staged markdown file(s)..."
    _pc_md_dir=$(mktemp -d "${TMPDIR:-/tmp}/wv-prose.XXXXXX" 2>/dev/null) || _pc_md_dir=""
    # Checked BEFORE any --prefix is built: an empty value would make the
    # prefix "/" and materialise the index over the filesystem root.
    if [ -z "$_pc_md_dir" ] || [ ! -d "$_pc_md_dir" ]; then
        echo "✗ prose gate: could not create a temp directory — refusing to commit unscanned content" >&2
        exit 1
    fi
    if ! mkdir -p "$_pc_md_dir/staged" || ! gate_materialise index "$_pc_md_dir/staged" "${_pc_md_files[@]}"; then
        rm -rf "$_pc_md_dir"
        echo "✗ prose gate: could not materialise the staged index — refusing to commit unscanned content" >&2
        exit 1
    fi
    # HEAD baseline. A path absent here is a new file and baselines to empty,
    # which prose-gate.py handles; an unborn HEAD leaves the dir empty entirely.
    for _pc_f in "${_pc_md_files[@]}"; do
        mkdir -p "$_pc_md_dir/head/$(dirname "$_pc_f")" 2>/dev/null || true
        gate_show base "$_pc_f" > "$_pc_md_dir/head/$_pc_f" 2>/dev/null || \
            rm -f "$_pc_md_dir/head/$_pc_f" 2>/dev/null || true
    done
    _pc_md_rc=0
    WV_BIN="$WV" python3 -E "$_PC_SCRIPTS/prose-gate.py" \
        "$_pc_md_dir/staged" "$_pc_md_dir/head" "${_pc_md_files[@]}" || _pc_md_rc=$?
    rm -rf "$_pc_md_dir"
    if [ "$_pc_md_rc" -ne 0 ]; then
        exit 1
    fi
fi


# ── Release leak guard (wv-4351d6) ──
# A shipped test that names a stripped Rust evidence path breaks
# tests/test-release.sh, yet a change to a test file selects only that file's
# own suite, so the check never ran on the commit that broke it (wv-eeaded).
# Where the repository carries the guard (the release builder's own source
# repository), any staged tests/ path or build-release.sh runs it against the
# STAGED index, not the working tree (wv-d6c692). Consumer repositories have no
# build-release.sh, so this is a no-op there.
#
# FAILS CLOSED on a materialisation it cannot produce, like the prose gate.
# The checker and builder count if HEAD or the index has them, so deletion
# cannot switch off this commit's check. Policy executes from the actual lane:
# HEAD normally, its single-file candidate overlay, or recovery's execution tree.
_pc_leak_hit=false
for _pc_f in "${_pc_md_all[@]}"; do
    case "$_pc_f" in tests/* | build-release.sh) _pc_leak_hit=true; break ;; esac
done
if [ "$_pc_leak_hit" = true ] && _pc_tracked_at_head_or_index build-release.sh \
    && _pc_tracked_at_head_or_index tests/test-shipped-test-refs.sh; then
    hook_progress "release leak guard on the staged tests/..."
    _pc_leak_dir=$(mktemp -d "${TMPDIR:-/tmp}/wv-leak.XXXXXX" 2>/dev/null) || _pc_leak_dir=""
    if [ -z "$_pc_leak_dir" ] || [ ! -d "$_pc_leak_dir" ]; then
        echo "✗ release leak guard: could not create a temp directory — refusing to commit unchecked tests" >&2
        exit 1
    fi
    _pc_leak_paths=()
    mapfile -d '' -t _pc_leak_paths < <(gate_ls index tests)
    if ! wait $! || ! gate_materialise index "$_pc_leak_dir" "${_pc_leak_paths[@]}"; then
        rm -rf "$_pc_leak_dir"
        echo "✗ release leak guard: could not materialise the staged index — refusing to commit unchecked tests" >&2
        exit 1
    fi
    _pc_leak_rc=0
    bash "$_PC_SCRIPTS/../tests/test-shipped-test-refs.sh" --scan "$_pc_leak_dir" \
        --policy "$_PC_SCRIPTS/.." || _pc_leak_rc=$?
    rm -rf "$_pc_leak_dir"
    if [ "$_pc_leak_rc" -ne 0 ]; then
        exit 1
    fi
fi

# Run fast shell workflow suites determined by wv impact --suites.
# Mapping is driven by .weave/test-map.conf + naming-convention heuristics.
# tests/run-all.sh is a meta-runner — skip it.
_pc_files_csv=$(printf '%s\n' "$NON_WEAVE_FILES" | paste -sd ',' -)
if [ -n "$_pc_files_csv" ]; then
    # The suite pool is required: without it a call below would print "command
    # not found" and the hook -- which does not run under set -e -- would carry
    # on and pass with no suite run (found by ultrareview follow-up).
    if ! command -v run_hook_suites >/dev/null 2>&1 || ! command -v gate_pool_estimates >/dev/null 2>&1 \
        || ! command -v gate_pool_launch_order >/dev/null 2>&1 || ! command -v gate_pool_require_present >/dev/null 2>&1; then
        echo "✗ Weave pre-commit: the suite pool (wv-gate-pool.sh) was not found — refresh with ./install.sh" >&2
        exit 1
    fi
    # A failed or unreadable selection refuses the commit, as pre-push does:
    # read as '[]' it ran no suite and passed (wv-cf48a9). The resolver's
    # stderr says why.
    # Routed by the maps git holds, the frozen index's and the base's, never
    # the working-tree file: an unstaged row removal skipped its suites, and
    # a staged one dropped its own route for the commit that made it (F5,
    # wv-fe8007). The union keeps both sides' routes across the transition.
    _pc_suites_json=$("$WV" impact --suites --files="$_pc_files_csv" \
        --map-rev="$WV_GATE_TREE" ${WV_GATE_BASE:+--map-rev="$WV_GATE_BASE"}) || {
        echo "✗ Weave pre-commit: could not resolve the suites for the staged files (wv impact --suites failed)" >&2
        exit 1
    }
    if ! jq -e 'type == "array"' <<< "$_pc_suites_json" >/dev/null 2>&1; then
        echo "✗ Weave pre-commit: could not read the suite selection" >&2
        exit 1
    fi
    # Every selected suite must be in the commit, or be a suggestion, or be
    # retired by a record HEAD already holds: retire a suite's routes in one
    # commit, delete it in a later one (R3, wv-fb861c). The pool executes the
    # frozen tree, so checkout absence cannot remove an owed check.
    _pc_suite_present() {
        local rc=0
        gate_blob index "$1" >/dev/null || rc=$?
        case "$rc" in
            0) return 0 ;;
            1) return 1 ;;
            *) return 2 ;;
        esac
    }
    _pc_rc=0
    _pc_retired=$(gate_show base .weave/test-map-retired.conf 2>/dev/null) || _pc_rc=$?
    if [ "$_pc_rc" -ne 0 ] && [ "$_pc_rc" -ne 1 ]; then
        echo "✗ Weave pre-commit: could not read .weave/test-map-retired.conf from the frozen base" >&2
        exit 1
    fi
    _pc_suites_json=$(gate_pool_require_present "$_pc_suites_json" _pc_suite_present "$_pc_retired") || exit 1
    _pc_suites_json=$(gate_pool_estimates "$_pc_suites_json")
    _pc_suite_count=$(printf '%s' "$_pc_suites_json" | jq 'length' 2>/dev/null || echo 0)
    # Push tier (wv-862ac0). A suite in the test map's [heavy] section is left
    # to the pre-push gate, which runs every heavy suite the pushed commits
    # select against the pushed tip and refuses the push until each is green.
    # Only when that gate is really installed in the hooks git will run: with
    # no Weave pre-push hook, deferring would mean the suite never runs, so it
    # runs here as it always did.
    _pc_heavy=$(jq -r '[.[] | select(.tier == "heavy") | .name] | join(", ")' <<< "$_pc_suites_json" 2>/dev/null || echo "")
    if [ -n "$_pc_heavy" ]; then
        # The same predicate wv done uses; an older library without it counts
        # as "not installed", which runs the heavy suites here -- the safe way.
        if command -v wv_prepush_gate_installed >/dev/null 2>&1 && wv_prepush_gate_installed; then
            hook_progress "deferred to the pre-push gate (heavy tier): $_pc_heavy"
            _pc_suites_json=$(jq -c '[.[] | select(.tier != "heavy")]' <<< "$_pc_suites_json" 2>/dev/null || echo '[]')
        else
            hook_progress "no Weave pre-push gate installed — running heavy-tier suites here: $_pc_heavy"
        fi
    fi
    _pc_light_count=$(printf '%s' "$_pc_suites_json" | jq 'length' 2>/dev/null || echo 0)
    if [ "${_pc_suite_count:-0}" -gt 0 ] && [ "${_pc_light_count:-0}" -eq 0 ]; then
        hook_progress "every selected suite is heavy-tier; nothing to run before commit"
    elif [ "${_pc_suite_count:-0}" -gt 0 ]; then
        _pc_gate_suites=$(printf '%s' "$_pc_suites_json" | jq -r '[.[].name] | join(",")' 2>/dev/null || echo "")
        _pc_selected=$(printf '%s' "$_pc_suites_json" | jq -r '[.[].name] | join(", ")' 2>/dev/null || echo "")
        _pc_selected_cost=$(printf '%s' "$_pc_suites_json" | jq '[.[].last_cost_s // 0] | add // 0' 2>/dev/null || echo 0)
        # Count suites with no recorded time so the total is not quoted as if it
        # covered them; an unmeasured suite contributes 0 and would silently
        # understate the wait.
        _pc_unmeasured=$(printf '%s' "$_pc_suites_json" | jq '[.[] | select((.last_cost_s // 0) <= 0)] | length' 2>/dev/null || echo 0)
        if [ "${_pc_unmeasured:-0}" -eq 0 ] 2>/dev/null; then
            # Only a fully measured total is recorded as the gate's estimate; a
            # partial sum would make the estimate error look better than it is.
            _pc_gate_estimate_ms=$(( ${_pc_selected_cost:-0} * 1000 ))
            hook_progress "impact-selected shell suites: $_pc_selected (~${_pc_selected_cost}s)"
        elif [ "${_pc_selected_cost:-0}" -gt 0 ] 2>/dev/null; then
            hook_progress "impact-selected shell suites: $_pc_selected (~${_pc_selected_cost}s measured, ${_pc_unmeasured} not yet measured)"
        else
            hook_progress "impact-selected shell suites: $_pc_selected (duration not yet measured)"
        fi
        # Suites inherit WV_GATE_BASE from gate_freeze: the base a
        # history-sensitive suite judges the candidate against (wv-bab095).
        # A candidate lane records nothing in the ledger, and reuses a recorded
        # result only when it leaves the code that runs suites as HEAD has it.
        if [ -n "$_PC_CAND_PATH" ]; then
            _pc_pool_record=0
            [ "$_PC_CAND_REUSE" = "1" ] || _pc_pool_reuse=off
        fi
        # A recovery run judges with code no recorded result was produced by:
        # every suite reruns (S2c, wv-0af8f0).
        [ -z "$_PC_EXEC_TREE" ] || _pc_pool_reuse=off
        _pc_launch=$(gate_pool_launch_order "$_pc_suites_json") || exit 1
        # The claim is checked before the suites, not only after them
        # (wv-c909ff), and after the cheap static checks above, whose fixtures
        # commit without one and read the claim refusal as "every check passed".
        _pc_require_claim "before the suites"
        run_hook_suites <<< "$_pc_launch"
    else
        # No suite matched any staged source file — the impact gate is inert for
        # this commit. Surface it so silent test-map rot becomes visible instead
        # of passing as if it were gated (add a glob/prefix or [default] entry to
        # .weave/test-map.conf, or run wv test-config to scaffold one).
        #
        # wv-734186: the message used to be identical whether .weave/test-map.conf
        # was entirely absent or present-but-non-matching -- a half-configured
        # gate looked exactly like an unconfigured one, and repeated on every
        # commit regardless. Distinguish the two, and name a sample of the
        # actual unmatched staged files (not just a count) in the second case.
        _pc_unmapped_count=$(printf '%s\n' "$NON_WEAVE_FILES" | grep -c . 2>/dev/null || echo 0)
        _pc_unmapped_sample=$(printf '%s\n' "$NON_WEAVE_FILES" | grep -v '^$' | head -3 | paste -sd ', ' -)
        if ! gate_blob index .weave/test-map.conf >/dev/null && ! gate_blob base .weave/test-map.conf >/dev/null; then
            echo "⚠ impact gate inert: no .weave/test-map.conf found — $_pc_unmapped_count staged file(s) unmapped, no suite ran." >&2
            echo "  Run 'wv test-config' to scaffold one, or add a glob/prefix/[default] entry (e.g. 'src/ = tests/...')." >&2
        else
            echo "⚠ impact gate inert: .weave/test-map.conf exists but matched none of $_pc_unmapped_count staged file(s), no suite ran." >&2
            echo "  Unmatched: $_pc_unmapped_sample" >&2
            echo "  Add a glob/prefix/[default] entry covering them (e.g. 'src/ = tests/...') to .weave/test-map.conf." >&2
        fi
    fi
fi


# Phase: closing records just-closed work and is bounded to one commit, after
# which the phase returns to discover. It is NOT an admission exemption
# (wv-68aeff): the graph commit that closing exists for is graph state and
# exited above, so what reaches here is substantive and needs a claim in every
# phase -- the phase is repository-shared, and another session's closing must
# not waive ownership.
_PC_REPO_HASH=$(echo "$REPO_ROOT" | md5sum | cut -c1-8)
_PC_HOT_ZONE="${WV_HOT_ZONE:-/dev/shm/weave/${_PC_REPO_HASH}}"
_PC_PHASE=$(cat "${_PC_HOT_ZONE}/.session_phase" 2>/dev/null || echo "execute")

if [ "$_PC_PHASE" = "closing" ] && [ -z "$_PC_CAND_PATH" ]; then
    command -v wv_set_phase >/dev/null 2>&1 && { wv_set_phase "discover" "$_PC_HOT_ZONE" || true; }
fi

# Admission decides: the claim check again (_pc_require_claim, defined with
# its rationale before the suites), since a claim can change while they run.
_pc_require_claim "at admission"

_pc_admit
