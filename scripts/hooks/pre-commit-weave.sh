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

# PREFLIGHT (wv-b7fdee). scripts/gate-preflight.sh runs this gate over a
# temporary index holding the working change, so a refusal costs seconds
# instead of a gate run. It judges as for a commit, except that it reports a
# missing claim instead of refusing, runs only the selected light suites
# measured at WV_GATE_PREFLIGHT_FAST_S seconds or less unless
# WV_GATE_PREFLIGHT_SUITES=1, records no gate measurement, never enters
# recovery, and ends after the candidate lanes without binding a commit.
# Read once and unset, so a suite that tests this hook does not inherit it;
# the copies this hook runs itself (HEAD's, each lane's) are handed it.
_PC_PREFLIGHT=${WV_GATE_PREFLIGHT:-0}
_PC_PREFLIGHT_SUITES=${WV_GATE_PREFLIGHT_SUITES:-0}
_PC_PREFLIGHT_FAST_S=${WV_GATE_PREFLIGHT_FAST_S:-20}
unset WV_GATE_PREFLIGHT WV_GATE_PREFLIGHT_SUITES WV_GATE_PREFLIGHT_FAST_S
_pc_preflight() { [ "$_PC_PREFLIGHT" = 1 ]; }

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
# The lanes' shellcheck lock (wv-cb632d), read once and kept from every
# process this hook starts, so a gate a suite runs never inherits it
# (nested boundary, wv-6900e1).
_PC_SC_LOCK="${WV_GATE_SC_LOCK:-}"
unset WV_GATE_SC_LOCK
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

# Supported external execution paths (wv-732b60). Copying a path does not
# assign its role: the frozen authority's contract still decides enforcement.
# This installed envelope must remain usable when HEAD's role file is broken.
_PC_GATE_EXTERNAL=(tests/test-memory-projection-parity.sh tests/test-shipped-test-refs.sh
    tests/lib/release-leak-pattern.ere build-release.sh)

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
# dispatcher, recovery and candidate lanes: scripts/ only, from objects, never
# from the worktree or a contract that might need recovery. The external files
# are not in it (R-a of the lane review, wv-a75d98): each is copied for the
# one check that reads it (_pc_external_dir), so no other stage can depend on
# its bytes. An external path that is not a regular file is still refused.
_pc_gate_archive() {
    local tree=$1 out=$2 p entry listing
    local -a paths=(scripts)
    for p in "${_PC_GATE_EXTERNAL[@]}"; do
        entry=$(git --literal-pathspecs ls-tree --full-tree "$tree" -- "$p" 2>/dev/null) || return 1
        [ -n "$entry" ] || continue
        case "$entry" in
            '100644 blob '*|'100755 blob '*) ;;
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

if [ -z "$_PC_LANE_BASE" ]; then
    _wv_base=$(git rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null) || _wv_base=""
    _wv_self=""
    # A committed gate is the hook AND the wv it runs (wv-9da519). wv init-repo
    # --update seeds the hook sources into a consumer's scripts/hooks/; tracked
    # there, the hook alone selected this lane, which then refused every commit
    # for want of scripts/wv. A consumer without scripts/wv takes the installed
    # copy's lane below. Here, a commit deleting scripts/wv is refused.
    if [ -n "$_wv_base" ] && ! _wv_self=$(git ls-tree "$_wv_base" -- scripts/hooks/pre-commit-weave.sh scripts/wv 2>/dev/null); then
        echo "✗ Weave pre-commit: could not read HEAD's tree to find its committed gate — refusing" >&2
        exit 1
    fi
    [ "$(grep -cE $'\t(scripts/hooks/pre-commit-weave\\.sh|scripts/wv)$' <<< "$_wv_self" || true)" = 2 ] || _wv_self=""
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
        # Recovery (S2c) is a module installed beside this file (wv-669900),
        # read here and nowhere else. Where HEAD tracks it, a copy missing or
        # without its entry point refuses: running on without recovery would
        # hide the broken install. A tree without it (a public release build)
        # has no recovery, and HEAD's gate judges every commit.
        _wv_rec=$(dirname -- "$0")/pre-commit-recovery.sh
        _wv_rec_head=$_wv_d/tree/scripts/hooks/pre-commit-recovery.sh
        if [ -f "$_wv_rec_head" ] && [ ! -f "$_wv_rec" ]; then
            echo "✗ Weave pre-commit: the recovery module is missing beside this hook ($_wv_rec) — refusing (refresh with ./install.sh)" >&2
            exit 1
        fi
        # The stale-copy guard's notice (wv-98f12b), kept: a copy that differs
        # from HEAD's still runs this fetch, so it should be refreshed. The
        # recovery module beside it is part of the copy.
        if ! cmp -s "$_wv_d/tree/scripts/hooks/pre-commit-weave.sh" "$0" \
            || { [ -f "$_wv_rec_head" ] && ! cmp -s "$_wv_rec_head" "$_wv_rec"; }; then
            echo "Weave pre-commit: running HEAD's committed gate (scripts/ at ${_wv_base:0:12}); this copy differs from it (refresh with ./install.sh)" >&2
        fi
        if ! printf '%s\n' "$_wv_base" > "$_wv_d/weave-gate-lane" 2>/dev/null; then
            echo "✗ Weave pre-commit: could not mark the copy of HEAD's committed gate — refusing" >&2
            exit 1
        fi
        if [ -f "$_wv_rec_head" ]; then
            # shellcheck source=scripts/hooks/pre-commit-recovery.sh
            if ! . "$_wv_rec" || ! declare -F _pcr_main >/dev/null; then
                echo "✗ Weave pre-commit: could not load the recovery module ($_wv_rec) — refusing (refresh with ./install.sh)" >&2
                exit 1
            fi
            _pc_preflight || _pcr_main "$@"
        fi
        WV_HOOK_REEXEC=1 WV_GATE_PREFLIGHT="$_PC_PREFLIGHT" WV_GATE_PREFLIGHT_SUITES="$_PC_PREFLIGHT_SUITES" \
            WV_GATE_PREFLIGHT_FAST_S="$_PC_PREFLIGHT_FAST_S" \
            env -u WV_LIB_DIR -u WV_CLI bash "$_wv_d/tree/scripts/hooks/pre-commit-weave.sh" "$@"
        exit $?
    fi
fi

# Find wv. A missing wv is judged below, once the staged content is
# classified: it no longer admits a substantive commit unchecked (wv-68aeff).
# In the protected lane, wv, the libraries and the python checkers come from
# the copy this hook runs from and nowhere else (_PC_SCRIPTS).
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || exit 0)
# The refresh a message names (wv-376de3): ./install.sh exists only in Weave's
# own tree, read from HEAD like the lane (install.sh and scripts/wv tracked); a
# consumer refreshes its install, then its hooks, with wv. Inline, because the
# messages that need it are the ones for missing libraries.
_pc_refresh_cmd() {
    if [ "$(git ls-tree HEAD -- install.sh scripts/wv 2>/dev/null | wc -l)" -eq 2 ]; then
        printf './install.sh'
    else
        printf 'wv self-update, then wv init-repo --update'
    fi
}
if [ -n "$_PC_LANE_BASE" ]; then
    _PC_SCRIPTS=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd) || _PC_SCRIPTS=""
    if [ -z "$_PC_SCRIPTS" ] || [ ! -x "$_PC_SCRIPTS/wv" ]; then
        # Cause and remedy in the message (wv-ec7b2b): this shape is a lane built
        # from a HEAD that tracks scripts/hooks/*-weave.sh without scripts/wv, as a
        # hook seeded before rc.15 left consumers; the current dispatcher sends
        # that shape down the consumer lane (wv-9da519), so reaching here means
        # the installed hook predates it.
        echo "✗ Weave pre-commit: the committed gate has no scripts/wv beside its hook (lane from $_PC_LANE_BASE) — refusing" >&2
        echo "  cause: HEAD tracks scripts/hooks/*-weave.sh without scripts/wv, and the installed hook predates the fix that runs such a repository on the installed gate" >&2
        echo "  remedy: wv self-update, then wv init-repo --update (refreshes .git/hooks), then retry the commit" >&2
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
    # An older builder (an installed dispatcher from before wv-a75d98) put the
    # external files in the envelope. Remove them before anything runs, so the
    # envelope holds scripts/ whoever built it. A gate copy is extracted from
    # objects and has no .git; anything else is not this hook's to edit.
    for _wv_ext in "${_PC_GATE_EXTERNAL[@]}"; do
        [ ! -e "$_PC_SCRIPTS/../.git" ] || break
        if ! rm -f "$_PC_SCRIPTS/../$_wv_ext"; then
            echo "✗ Weave pre-commit: could not remove $_wv_ext from the committed gate's copy — refusing" >&2
            exit 1
        fi
    done
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
# The per-checkout gate lock (wv-c5500d) likewise.
for _pc_lib in wv-gate-snapshot.sh wv-gate-hold.sh; do
    for _pc_cand in "${_pc_lib_cands[@]}"; do
        if [ -n "$_pc_cand" ] && [ -f "$_pc_cand/$_pc_lib" ]; then
            # shellcheck source=/dev/null
            source "$_pc_cand/$_pc_lib"
            break
        fi
    done
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
    echo "✗ Weave pre-commit: the frozen-candidate library (wv-gate-snapshot.sh) was not found — refresh with $(_pc_refresh_cmd)" >&2
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
    if [ -n "$_PC_LANE_BASE" ] && ! WV_GATE_PREFLIGHT="$_PC_PREFLIGHT" \
        WV_GATE_PREFLIGHT_SUITES="$_PC_PREFLIGHT_SUITES" WV_GATE_PREFLIGHT_FAST_S="$_PC_PREFLIGHT_FAST_S" \
        gate_lanes_run "${_wv_lane_file%/*}"; then
        exit 1
    fi
    if _pc_preflight; then
        echo "✓ Weave preflight: the gate admits this change; nothing was committed" >&2
        exit 0
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

# _pc_external_dir <path>... — R-a of the lane review (wv-a75d98): a private
# directory holding exactly these external gate files as this lane runs them
# (HEAD's, or the execution tree's in recovery; a candidate lane's own file as
# frozen), with scripts/ beside them. It exists only while the one check that
# declares them runs, and no exported variable names it. Outside a protected
# lane there is no envelope: the files beside this hook, as before. Sets
# _PC_EXT_DIR; 1 when a copy cannot be made, and the caller refuses.
_PC_EXT_DIR=""
_pc_external_dir() {
    local p side blob rc tree mode
    _PC_EXT_DIR=""
    if [ -z "$_PC_LANE_BASE" ]; then
        _PC_EXT_DIR="$_PC_SCRIPTS/.."
        return 0
    fi
    _PC_EXT_DIR=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/wv-gate-ext.XXXXXX" 2>/dev/null) || _PC_EXT_DIR=""
    [ -n "$_PC_EXT_DIR" ] && [ -d "$_PC_EXT_DIR" ] || { _PC_EXT_DIR=""; return 1; }
    ln -s "$_PC_SCRIPTS" "$_PC_EXT_DIR/scripts" || return 1
    for p; do
        side=auth
        [ "$p" = "$_PC_CAND_PATH" ] && side=index
        rc=0; blob=$(gate_blob "$side" "$p") || rc=$?
        case "$rc" in
            0) ;;
            1) continue ;;
            *) return 1 ;;
        esac
        tree=$(gate_side_tree "$side") || return 1
        mode=$(git ls-tree --full-tree "$tree" -- "$p" 2>/dev/null) || return 1
        mkdir -p "$_PC_EXT_DIR/$(dirname "$p")" || return 1
        git cat-file blob "$blob" > "$_PC_EXT_DIR/$p" || return 1
        chmod "$([ "${mode%% *}" = 100755 ] && echo 700 || echo 600)" "$_PC_EXT_DIR/$p" || return 1
    done
}
_pc_external_drop() {
    if [ -n "$_PC_LANE_BASE" ] && [ -n "$_PC_EXT_DIR" ]; then rm -rf "$_PC_EXT_DIR"; fi
    _PC_EXT_DIR=""
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
        | select((.metadata.node_kind // .metadata.type) == "memory" and (.metadata.mem_status // "active") == "active")
        | {id, text, verified_at: .metadata.verified_at, hook: .metadata.hook, resident: .metadata.resident}] | sort_by(.id)'
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
        _pc_memory_roots=(.weave CLAUDE.md
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
        if ! _pc_external_dir tests/test-memory-projection-parity.sh; then
            _pc_external_drop; rm -rf "$_pc_memory_dir"
            echo "✗ memory parity: could not copy the parity checker for this check — refusing" >&2
            exit 1
        fi
        _pc_memory_rc=0
        bash "$_PC_EXT_DIR/tests/test-memory-projection-parity.sh" --subject "$_pc_memory_dir" || _pc_memory_rc=$?
        _pc_external_drop
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
    echo "Weave pre-commit: graph-state helper not found (wv-checkpoint-ci.sh) — every staged file is gated, graph state included; refresh with $(_pc_refresh_cmd)" >&2
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
_pc_gate_pressure0=$(gate_pressure_totals 2>/dev/null)
_pc_gate_suites=""
_pc_gate_estimate_ms=""
_pc_gate_finish() {
    local rc=$?
    "$WV" test-record gate --gate --exit="$rc" --duration="$(hook_duration_ms "$_pc_gate_t0")" \
        --execution-mode="${WV_GATE_EXECUTION_MODE:-}" \
        --suite-modes="$(gate_pool_suite_modes "$_pc_gate_suites")" \
        --estimate="$_pc_gate_estimate_ms" --suites="$_pc_gate_suites" \
        --started-ms="$(_pc_ns_to_ms "$_pc_gate_t0" 2>/dev/null)" \
        --lanes="${_GATE_LANES_RUNS:-}" --lanes-ms="${_GATE_LANES_MS:-}" \
        --lanes-started-ms="$([ -z "${_GATE_LANES_T0:-}" ] || _pc_ns_to_ms "$_GATE_LANES_T0" 2>/dev/null)" \
        --pressure-start="$_pc_gate_pressure0" --pressure-end="$(gate_pressure_totals 2>/dev/null)" \
        >/dev/null 2>&1 || true
    wv_gate_hold_release 2>/dev/null || true
    return "$rc"
}
[ -n "$_PC_CAND_PATH" ] || _pc_preflight || trap _pc_gate_finish EXIT

# ── One gate at a time per checkout (wv-c5500d) ── Past the .weave-only and
# checkpoint exits, so graph-state commits still pass while a push gate runs,
# and never in a candidate lane, which this gate starts itself. A preflight
# takes it too: it runs the same suites on the same scratch.
if [ -z "$_PC_CAND_PATH" ]; then
    if ! command -v wv_gate_hold_acquire >/dev/null 2>&1; then
        echo "✗ Weave pre-commit: the gate lock library (wv-gate-hold.sh) was not found — refresh with $(_pc_refresh_cmd)" >&2
        exit 1
    fi
    wv_gate_hold_acquire pre-commit "commit on $(git rev-parse --short HEAD 2>/dev/null || echo 'no HEAD')" || exit 1
fi

# Admission (execute phase only): an active node CLAIMED BY THE COMMITTING
# ACTOR. Counting every active node let one agent's claim admit another
# agent's, or a human's, commit (wv-99d559). The actor is resolved exactly as
# the Weave-ID trailers resolve it (wv list --claimed-by=current, i.e.
# resolve_agent_id from the committing process's environment), so admission
# and attribution follow one identity policy; they remain separate hooks and
# queries, not one transaction. Taking over someone else's node is
# `wv work <id> --force`, which the claim_ownership rule records.
# A failed listing reads as no claim: admission fails closed.
# Admission is SESSION-owned where the harness carries a session id (Claude
# Code, Codex): the identity is <harness>-<host>-<user>-s<sid12>, so two sessions
# of one harness no longer admit each other's commits, and a harness session
# whose id is missing fails the listing (wv-99978b). A human shell, Copilot, or
# WV_SESSION_IDENTITY=0 stays actor-owned; WV_AGENT_ID always wins.
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

# _pc_claim <when> — the claim check; a preflight reports a missing claim once
# instead of refusing, since it commits nothing and the rest of the gate still
# has refusals to find.
_pc_claim() {
    if ! _pc_preflight; then
        _pc_require_claim "$1"
    elif [ -z "${_PC_CLAIM_SEEN:-}" ]; then
        _PC_CLAIM_SEEN=1
        ( _pc_require_claim "$1" ) \
            || echo "⚠ Weave preflight: a commit now would be refused for want of a claim (above); the gate continues" >&2
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

# Python dev tools read the staged bytes and never execute them, so the
# checkout's own environment is no authority problem: the frozen tree is the
# input. In Weave's own tree (the protected lane) a tool is found in the
# repository's .venv first, where make check runs it, then on PATH. ruff sat
# behind `command -v ruff`, and with ruff only in .venv the lint step was
# skipped without a word on every commit (wv-e7a3b2). A consumer's pre-commit
# is unchanged: PATH only.
_pc_dev_tool() {  # _pc_dev_tool <name>: its command, or empty when none
    if [ -n "$_PC_LANE_BASE" ] && [ -x "$REPO_ROOT/.venv/bin/$1" ]; then
        printf '%s\n' "$REPO_ROOT/.venv/bin/$1"
    else
        command -v "$1" 2>/dev/null || true
    fi
}
_pc_declares() {  # _pc_declares <tool>: the staged tree configures it
    local _pc_cfg _pc_project
    for _pc_cfg in "$1.toml" ".$1.toml"; do
        [ -z "$(gate_ls index "$_pc_cfg" | tr -d '\0')" ] || return 0
    done
    # Captured first: grep -q ending a pipe early fails it under pipefail.
    _pc_project=$(gate_show index pyproject.toml 2>/dev/null) || return 1
    grep -q "^\[tool\.$1[].]" <<< "$_pc_project"
}
# In Weave's own tree a configured tool that cannot be found refuses: a
# skipped check is not a passed one.
_pc_dev_tool_missing() {  # _pc_dev_tool_missing <name>
    echo "✗ Weave pre-commit: this tree configures $1 but none was found in .venv/bin or on PATH — install the dev dependencies (poetry install)" >&2
    exit 1
}

if [ "${#STAGED_PY_FILES[@]}" -gt 0 ]; then
    _pc_ruff=$(_pc_dev_tool ruff)
    if [ -z "$_pc_ruff" ] && [ -n "$_PC_LANE_BASE" ] && _pc_declares ruff; then
        _pc_dev_tool_missing ruff
    fi
    if [ -n "$_pc_ruff" ]; then
        hook_progress "running ruff on staged Python files..."
        # Freeze both source and configuration (wv-3080d7). Keep Ruff's native
        # nested discovery/merging, but only repository-relative, regular,
        # tracked inheritance is authority. A root fallback prevents discovery
        # above the snapshot or in the user's configuration directory.
        # -I also prevents a working-tree module shadowing the parser itself.
        if ! RUFF_OUT=$(python3 -I - "$_pc_ruff" "$WV_GATE_TREE" "${STAGED_PY_FILES[@]}" 2>&1 <<'PY'
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
    ruff, tree, *paths = sys.argv[1:]
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
        sys.exit(subprocess.call([ruff, "check", "--no-fix", "--no-fix-only",
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

# Type check staged Python with pyrefly (wv-e7a3b2; owner ruling D4 on
# wv-80fa17): the staged files, as ruff runs, about 1.5 s on a typical set.
# 60543bb01 committed four pyrefly errors that only the next make check saw.
# The staged files are checked, not their unstaged importers: cross-file
# breakage stays with make check. Weave's own tree only, so a consumer's
# pre-commit is unchanged. The input is the frozen index, every tracked
# Python file and pyrefly configuration, so imports resolve against the
# commit's bytes; the interpreter beside the tool supplies site-packages.
if [ "${#STAGED_PY_FILES[@]}" -gt 0 ] && [ -n "$_PC_LANE_BASE" ] && _pc_declares pyrefly; then
    _pc_pyrefly=$(_pc_dev_tool pyrefly)
    [ -n "$_pc_pyrefly" ] || _pc_dev_tool_missing pyrefly
    _pc_pyrefly_py="$(dirname "$_pc_pyrefly")/python3"
    [ -x "$_pc_pyrefly_py" ] || _pc_pyrefly_py=$(command -v python3 2>/dev/null || true)
    hook_progress "running pyrefly on staged Python files..."
    _pc_pyrefly_dir=$(mktemp -d "${TMPDIR:-/tmp}/wv-pyrefly.XXXXXX" 2>/dev/null) || _pc_pyrefly_dir=""
    # Checked before any --prefix is built, as the prose gate does: an empty
    # value would materialise the index over the filesystem root.
    if [ -z "$_pc_pyrefly_dir" ] || [ ! -d "$_pc_pyrefly_dir" ]; then
        echo "✗ pyrefly: could not create a temp directory — refusing to commit unchecked content" >&2
        exit 1
    fi
    _pc_pyrefly_inputs=()
    while IFS= read -r -d '' _pc_f; do
        case "$_pc_f" in
            *.py|*.pyi|pyproject.toml|*/pyproject.toml|pyrefly.toml|*/pyrefly.toml)
                _pc_pyrefly_inputs+=("$_pc_f") ;;
        esac
    done < <(gate_ls index)
    wait $! || { rm -rf "$_pc_pyrefly_dir"; _pc_list_failed "files for the pyrefly check"; }
    if ! gate_materialise index "$_pc_pyrefly_dir" "${_pc_pyrefly_inputs[@]}"; then
        rm -rf "$_pc_pyrefly_dir"
        echo "✗ pyrefly: could not materialise the staged index — refusing to commit unchecked content" >&2
        exit 1
    fi
    _pc_pyrefly_args=(check)
    [ -z "$_pc_pyrefly_py" ] || _pc_pyrefly_args+=(--python-interpreter-path "$_pc_pyrefly_py")
    _pc_pyrefly_rc=0
    PYREFLY_OUT=$(cd "$_pc_pyrefly_dir" && "$_pc_pyrefly" "${_pc_pyrefly_args[@]}" \
        -- "${STAGED_PY_FILES[@]}" 2>&1) || _pc_pyrefly_rc=$?
    rm -rf "$_pc_pyrefly_dir"
    if [ "$_pc_pyrefly_rc" -ne 0 ]; then
        echo "" >&2
        echo "✗ pyrefly type errors in staged files:" >&2
        echo "$PYREFLY_OUT" >&2
        echo "" >&2
        echo "  Check with: make typecheck  (then re-stage)" >&2
        echo "" >&2
        exit 1
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
        # In a candidate lane it takes one of the gate's shared slots like a
        # suite (wv-428a92); outside a lane WV_GATE_SLOTS is unset and the stamp
        # is ignored.
        if ! WV_GATE_SLOT_STAMP="$_pc_pytest_work/slot" \
            gate_run_bounded "focused pytest" "${WV_GATE_TIMEOUT:-1800}" \
            env -u WV_CALL_LOG -u WV_GATE_LANE_JOBS -u WV_GATE_SLOTS -u WV_GATE_SLOT_STAMP -u WV_GATE_SLOT_STOP -u WV_SCRATCH_ROOT \
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
        # Candidate lanes run this hook at the same time, each linting every
        # staged shell file in full; shellcheck on tests/test-hooks.sh alone
        # peaks at 1.6 GB, so two lanes took an 8 GB host to 2.6 GB free
        # (wv-cb632d). gate_lanes_run names one lock for its lanes in
        # WV_GATE_SC_LOCK (read as _PC_SC_LOCK): each lane still runs all of
        # its shellcheck runs itself, one lane at a time. Without the lock (the
        # protected pass, which ends before lanes start, or a host without
        # flock) the run is as before.
        _pc_sc_lock=()
        [ -n "$_PC_SC_LOCK" ] && command -v flock >/dev/null 2>&1 \
            && _pc_sc_lock=(flock "$_PC_SC_LOCK")
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
            _pc_sc_one=$( cd "$_pc_sc_lint" && ${_pc_sc_lock[@]+"${_pc_sc_lock[@]}"} \
                env -u SHELLCHECK_OPTS shellcheck --severity=warning -- "${_pc_sc_group[@]}" 2>&1 ) && continue
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
    # A moved file baselines to its old path's HEAD bytes: the findings it
    # carried there are inherited, not added (wv-7f1794).
    declare -A _pc_md_from=()
    while IFS= read -r -d '' _pc_old && IFS= read -r -d '' _pc_new; do
        _pc_md_from["$_pc_new"]=$_pc_old
    done < <(gate_renamed)
    wait $! || _pc_list_failed "renames for the prose scan"
    for _pc_f in "${_pc_md_files[@]}"; do
        mkdir -p "$_pc_md_dir/head/$(dirname "$_pc_f")" 2>/dev/null || true
        gate_show base "${_pc_md_from[$_pc_f]:-$_pc_f}" > "$_pc_md_dir/head/$_pc_f" 2>/dev/null || \
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
    if ! _pc_external_dir build-release.sh tests/lib/release-leak-pattern.ere tests/test-shipped-test-refs.sh; then
        _pc_external_drop; rm -rf "$_pc_leak_dir"
        echo "✗ release leak guard: could not copy the release policy for this check — refusing to commit unchecked tests" >&2
        exit 1
    fi
    _pc_leak_rc=0
    bash "$_PC_EXT_DIR/tests/test-shipped-test-refs.sh" --scan "$_pc_leak_dir" \
        --policy "$_PC_EXT_DIR" || _pc_leak_rc=$?
    _pc_external_drop
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
        echo "✗ Weave pre-commit: the suite pool (wv-gate-pool.sh) was not found — refresh with $(_pc_refresh_cmd)" >&2
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
    # A preflight runs, by default, only the light suites the gate has
    # measured as quick; WV_GATE_PREFLIGHT_SUITES=1 runs every light one.
    if _pc_preflight && [ "$_PC_PREFLIGHT_SUITES" != 1 ]; then
        _pc_light_all=$(jq 'length' <<< "$_pc_suites_json" 2>/dev/null || echo 0)
        _pc_suites_json=$(jq -c --argjson s "$_PC_PREFLIGHT_FAST_S" \
            '[.[] | select((.last_cost_s // 0) > 0 and .last_cost_s <= $s)]' <<< "$_pc_suites_json" 2>/dev/null || echo '[]')
        hook_progress "preflight: $(jq 'length' <<< "$_pc_suites_json") of $_pc_light_all selected light suite(s) are measured at ${_PC_PREFLIGHT_FAST_S}s or less and run; --suites runs them all"
    fi
    _pc_light_count=$(printf '%s' "$_pc_suites_json" | jq 'length' 2>/dev/null || echo 0)
    if [ "${_pc_suite_count:-0}" -gt 0 ] && [ "${_pc_light_count:-0}" -eq 0 ] && _pc_preflight; then
        :
    elif [ "${_pc_suite_count:-0}" -gt 0 ] && [ "${_pc_light_count:-0}" -eq 0 ]; then
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
        _pc_claim "before the suites"
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
# phase -- another session's closing must not waive ownership.
_PC_REPO_HASH=$(echo "$REPO_ROOT" | md5sum | cut -c1-8)
_PC_HOT_ZONE="${WV_HOT_ZONE:-/dev/shm/weave/${_PC_REPO_HASH}}"
# The phase is this owner's (wv-43d6be); the root file is never read.
_PC_PHASE_FILE=""
if command -v resolve_phase_file >/dev/null 2>&1; then _PC_PHASE_FILE=$(resolve_phase_file "$_PC_HOT_ZONE") || true; fi
_PC_PHASE=$( [ -n "$_PC_PHASE_FILE" ] && cat "$_PC_PHASE_FILE" 2>/dev/null || echo "execute")

if [ "$_PC_PHASE" = "closing" ] && [ -z "$_PC_CAND_PATH" ] && ! _pc_preflight; then
    command -v wv_set_phase >/dev/null 2>&1 && { wv_set_phase "discover" "$_PC_HOT_ZONE" || true; }
fi

# Admission decides: the claim check again (_pc_require_claim, defined with
# its rationale before the suites), since a claim can change while they run.
_pc_claim "at admission"

_pc_admit
