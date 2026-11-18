#!/usr/bin/env bash
# Weave pre-push hook: the heavy tier of the commit gate (wv-862ac0).
#
# A suite in the [heavy] section of .weave/test-map.conf does not run in the
# blocking pre-commit gate. This hook runs every heavy suite that ANY commit
# being pushed selects, against the pushed tip, and refuses the push until each
# is green (owner decision 2026-09-26: gate the tip, run here, explicit list).
# Intermediate local commits may be heavy-red; what leaves the machine is not.
#
# The suites run from the working tree, so the tree must BE the tip: the pushed
# ref must be HEAD and no tracked file outside graph state may differ from it.
# Self-hosting suites run frozen and may reuse exact-input green rows.
# Consumer checkout suites preserve their mutable tools and always rerun;
# their labelled outcomes are history, never reusable readiness (wv-68eb9a).
#
# Skip with: git push --no-verify (never in this repository: CLAUDE.md rule 8)

hook_progress() {
    [ "${WV_HOOK_PROGRESS:-1}" = "0" ] && return 0
    printf '%s\n' "Weave pre-push: $1" >&2
}


# PROTECTED DISPATCHER (S2a, wv-1f98b6): see pre-commit-weave.sh. Where HEAD
# carries this hook, the push gate is HEAD's committed scripts/ tree run from a
# private copy, never the working tree or this installed copy. Every commit
# that put it there was admitted by the protected pre-commit gate. stdin, the
# pushed refs, passes through to it unread.
# A protected lane is this hook run from a copy the block below made: it sits
# at <dir>/tree/scripts/hooks/ beside <dir>/weave-gate-lane, which names the
# commit the copy came from. A file, not an environment variable, so nothing
# the gate runs (suites, the commits their fixtures make) inherits the mark.
_PP_LANE_BASE=""
_wv_lane_file="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." 2>/dev/null && pwd)/weave-gate-lane"
if [ -f "$_wv_lane_file" ]; then
    _PP_LANE_BASE=$(cat "$_wv_lane_file" 2>/dev/null) || _PP_LANE_BASE=""
    if [ -z "$_PP_LANE_BASE" ]; then
        echo "✗ Weave pre-push: could not read the committed gate's lane mark ($_wv_lane_file) — refusing" >&2
        exit 1
    fi
    # Read only by older hooks' stale-copy guard: nothing this gate runs needs it.
    unset WV_HOOK_REEXEC
fi
if [ -z "$_PP_LANE_BASE" ]; then
    _wv_base=$(git rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null) || _wv_base=""
    _wv_self=""
    # A committed gate is the hook AND the wv it runs (wv-9da519): a consumer
    # tracking the hook sources wv init-repo seeds has no scripts/wv and takes
    # the installed copy's lane. pre-commit-weave.sh says why in full.
    if [ -n "$_wv_base" ] && ! _wv_self=$(git ls-tree "$_wv_base" -- scripts/hooks/pre-push-weave.sh scripts/wv 2>/dev/null); then
        echo "✗ Weave pre-push: could not read HEAD's tree to find its committed gate — refusing" >&2
        exit 1
    fi
    [ "$(grep -cE $'\t(scripts/hooks/pre-push-weave\\.sh|scripts/wv)$' <<< "$_wv_self" || true)" = 2 ] || _wv_self=""
    if [ -n "$_wv_self" ]; then
        if ! _wv_ls=$(git ls-tree -r "$_wv_base" -- scripts 2>/dev/null); then
            echo "✗ Weave pre-push: could not list HEAD's scripts/, the committed gate — refusing" >&2
            exit 1
        fi
        _wv_odd=$(grep -v -e '^100644 ' -e '^100755 ' <<< "$_wv_ls" || true)
        if [ -n "$_wv_odd" ]; then
            echo "✗ Weave pre-push: HEAD's scripts/ holds a link or submodule ($(head -1 <<< "$_wv_odd" | cut -f2)), which the protected gate does not follow — refusing" >&2
            exit 1
        fi
        _wv_d=$(mktemp -d "${TMPDIR:-/tmp}/wv-gate-dispatch.XXXXXX" 2>/dev/null) || _wv_d=""
        if [ -z "$_wv_d" ] || [ ! -d "$_wv_d" ]; then
            echo "✗ Weave pre-push: could not create a directory for HEAD's committed gate — refusing" >&2
            exit 1
        fi
        trap 'rm -rf "${_wv_d:?}"' EXIT
        trap 'exit 130' INT TERM HUP
        if ! git archive --format=tar -o "$_wv_d/gate.tar" "$_wv_base" -- scripts 2>/dev/null \
            || ! mkdir "$_wv_d/tree" || ! tar -xf "$_wv_d/gate.tar" -C "$_wv_d/tree" 2>/dev/null \
            || [ ! -f "$_wv_d/tree/scripts/hooks/pre-push-weave.sh" ]; then
            echo "✗ Weave pre-push: could not copy HEAD's committed gate (scripts/ at ${_wv_base:0:12}) — refusing" >&2
            exit 1
        fi
        # The stale-copy guard's notice (wv-98f12b), kept: a copy that differs
        # from HEAD's still runs this fetch, so it should be refreshed.
        if ! cmp -s "$_wv_d/tree/scripts/hooks/pre-push-weave.sh" "$0"; then
            echo "Weave pre-push: running HEAD's committed gate (scripts/ at ${_wv_base:0:12}); this copy differs from it (refresh with ./install.sh)" >&2
        fi
        if ! printf '%s\n' "$_wv_base" > "$_wv_d/weave-gate-lane" 2>/dev/null; then
            echo "✗ Weave pre-push: could not mark the copy of HEAD's committed gate — refusing" >&2
            exit 1
        fi
        WV_HOOK_REEXEC=1 \
            env -u WV_LIB_DIR -u WV_CLI bash "$_wv_d/tree/scripts/hooks/pre-push-weave.sh" "$@"
        exit $?
    fi
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
# The refresh a message names (wv-376de3); pre-commit-weave.sh says why.
_pp_refresh_cmd() {
    if [ "$(git ls-tree HEAD -- install.sh scripts/wv 2>/dev/null | wc -l)" -eq 2 ]; then
        printf './install.sh'
    else
        printf 'wv self-update, then wv init-repo --update'
    fi
}
# In the protected lane, wv, the libraries and the E6 validator come from the
# copy this hook runs from and nowhere else (_PP_SCRIPTS).
if [ -n "$_PP_LANE_BASE" ]; then
    _PP_SCRIPTS=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd) || _PP_SCRIPTS=""
    if [ -z "$_PP_SCRIPTS" ] || [ ! -x "$_PP_SCRIPTS/wv" ]; then
        # Cause and remedy in the message (wv-ec7b2b); pre-commit-weave.sh says why.
        echo "✗ Weave pre-push: the committed gate has no scripts/wv beside its hook (lane from $_PP_LANE_BASE) — refusing" >&2
        echo "  cause: HEAD tracks scripts/hooks/*-weave.sh without scripts/wv, and the installed hook predates the fix that runs such a repository on the installed gate" >&2
        echo "  remedy: wv self-update, then wv init-repo --update (refreshes .git/hooks), then retry the push" >&2
        exit 1
    fi
    _pp_lib_cands=("$_PP_SCRIPTS/lib")
else
    # HEAD has no committed gate (a consumer): the gate is the one this hook
    # ships with, beside it, never the repository's working tree (S2b review
    # N1, wv-c424ed).
    _PP_SCRIPTS=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd) || _PP_SCRIPTS=""
    _pp_lib_cands=("$_PP_SCRIPTS/lib" "$HOME/.local/lib/weave/lib")
fi
# stdin is read once, here: the E6 debt check below and the heavy-tier loop
# further down both need every pushed ref.
_pp_stdin=$(cat)


if [ -n "$_PP_LANE_BASE" ]; then
    # Without the caller's python import environment: see pre-commit-weave.sh.
    WV="$_PP_SCRIPTS/../wv-gate"
    if ! printf '#!/bin/sh\nexec env -u PYTHONPATH -u PYTHONHOME -u PYTHONUSERBASE -u PYTHONSTARTUP PYTHONSAFEPATH=1 "%s/wv" "$@"\n' \
            "$_PP_SCRIPTS" > "$WV" 2>/dev/null || ! chmod +x "$WV" 2>/dev/null; then
        echo "✗ Weave pre-push: could not prepare the committed wv — refusing" >&2
        exit 1
    fi
else
    WV="$(command -v wv 2>/dev/null || true)"
fi
[ -x "$WV" ] || exit 0
# Tag this hook's wv calls as hook traffic, keeping a test run's tag (wv-f47c10;
# see pre-commit-weave.sh).
[ "${WV_CALL_SOURCE:-}" = "test" ] || export WV_CALL_SOURCE=hook
# Projection verdict (wv-65cd02), in every Weave repository, so before the
# test-map and [heavy] handling below: a rebase or merge can keep another
# copy's .weave/state.sql while both sides' operations travel, publishing a
# snapshot that lacks operations committed with it. The graph decides (wv
# status, reason projection_lags_operations); this hook asks and refuses. The
# verdict is about HEAD's committed snapshot, so a ref pushed from another
# commit is reported as unchecked, not refused.
if [ -d "$REPO_ROOT/.weave" ]; then
    _pp_proj_head=$(git rev-parse --verify --quiet HEAD 2>/dev/null) || _pp_proj_head=""
    _pp_proj_asked=false
    while read -r _pp_lref _pp_lsha _pp_rref _pp_rsha; do
        [ -n "${_pp_lsha:-}" ] || continue
        [ "$_pp_lsha" = "0000000000000000000000000000000000000000" ] && continue
        if [ "$_pp_lsha" != "$_pp_proj_head" ]; then
            # Only a ref whose pushed range adds graph operations is worth a
            # word: a tag or a code-only branch carries nothing to check.
            if [ -n "${_pp_rsha:-}" ] && [ "$_pp_rsha" != "0000000000000000000000000000000000000000" ] \
                && ! git diff --quiet "$_pp_rsha" "$_pp_lsha" -- .weave/deltas 2>/dev/null; then
                echo "⚠ Weave pre-push: $_pp_lref adds graph operations but is not the checked-out commit, so its .weave/state.sql was not checked against them" >&2
            fi
            continue
        fi
        [ "$_pp_proj_asked" = false ] || continue
        _pp_proj_asked=true
        _pp_proj=$("$WV" status --json 2>/dev/null) || _pp_proj=""
        _pp_proj_reason=$(jq -r '.git_sync_reason // ""' <<< "$_pp_proj" 2>/dev/null) || _pp_proj_reason=""
        case "$_pp_proj_reason" in
            projection_lags_operations|projection_unverifiable)
                echo "✗ Weave pre-push: $_pp_lref at ${_pp_lsha:0:12} is not pushed ($_pp_proj_reason):" >&2
                echo "  $(jq -r '.git_sync_hint // ""' <<< "$_pp_proj" 2>/dev/null)" >&2
                exit 1 ;;
        esac
    done <<< "$_pp_stdin"
fi
# A map that is there but cannot be read -- unreadable, a dangling symlink, or
# inside a .weave/ that cannot be searched -- is not "no map": read that way,
# the push went out with no heavy suite run (wv-b02828). Inline, before the
# libraries load, as wv_config_read does it. Whether anything was deferred is
# not the tip's map to say: each pushed commit owes what its own gate deferred,
# under its own map and its parents' (R2, wv-418d4c), which is decided below.
_pp_map="$REPO_ROOT/.weave/test-map.conf"
if [ -e "$_pp_map" ] || [ -L "$_pp_map" ]; then
    _pp_map_text=$(cat -- "$_pp_map" 2>/dev/null) || {
        echo "✗ Weave pre-push: .weave/test-map.conf exists but cannot be read, so the heavy tier this push owes is unknown" >&2
        exit 1
    }
elif [ -e "$REPO_ROOT/.weave" ] && ! { [ -d "$REPO_ROOT/.weave" ] && [ -x "$REPO_ROOT/.weave" ]; }; then
    echo "✗ Weave pre-push: .weave/ cannot be searched, so whether a test map exists is unknown" >&2
    exit 1
fi

# Libraries beside this hook first (scripts/hooks/../lib, the source a checkout
# runs), then the repository's, then the installed ones: the gate never mixes
# this hook with libraries of another version when its own are at hand.
for _pp_lib in wv-checkpoint-ci.sh wv-gate-pool.sh wv-gate-hold.sh wv-clock.sh; do
    for _pp_cand in "${_pp_lib_cands[@]}"; do
        if [ -f "$_pp_cand/$_pp_lib" ]; then
            # shellcheck source=/dev/null
            source "$_pp_cand/$_pp_lib"
            break
        fi
    done
done
if ! command -v run_hook_suites >/dev/null 2>&1 || ! command -v gate_pool_estimates >/dev/null 2>&1 \
    || ! command -v gate_pool_launch_order >/dev/null 2>&1 || ! command -v wv_non_graph_state_paths >/dev/null 2>&1 \
    || ! command -v gate_pool_require_present >/dev/null 2>&1 || ! command -v wv_clock_since >/dev/null 2>&1 \
    || ! command -v gate_pool_execution_mode >/dev/null 2>&1; then
    echo "✗ Weave pre-push: the gate libraries (wv-gate-pool.sh, wv-checkpoint-ci.sh) were not found — refresh with $(_pp_refresh_cmd)" >&2
    exit 1
fi

# ── One gate at a time per checkout (wv-c5500d) ── A push restarted by a new
# session ran a second heavy tier beside the first (2026-11-08). The outcome is
# recorded for the next session to read: running now, passed or failed (with
# the suites that failed) when this shell exits, whichever path it takes.
if ! command -v wv_gate_hold_acquire >/dev/null 2>&1 || ! command -v wv_gate_hold_foreign_status >/dev/null 2>&1; then
    echo "✗ Weave pre-push: the gate lock library (wv-gate-hold.sh) was not found — refresh with $(_pp_refresh_cmd)" >&2
    exit 1
fi
_pp_subject=$(awk 'NF >= 2 { printf "%s%s %.9s", (n++ ? ", " : ""), $1, $2 }' <<< "$_pp_stdin")
wv_gate_hold_acquire pre-push "$_pp_subject" || exit 1
# ── A gate running in another worktree of this repository (wv-33cf11) ── Each
# worktree has its own lock, so the one above never sees a peer's: a push from
# a linked worktree published beneath the main worktree's running gate
# (2026-11-17, 231f12018), the cross-worktree half of wv-44d74b. The hold
# library judges the holder (pid plus start time); this hook asks it after
# taking its own lock, so two worktrees pushing at once both refuse rather
# than both pass. A dead holder's leftover record reads as nothing.
_pp_foreign=$(wv_gate_hold_foreign_status "$REPO_ROOT")
if [ -n "$_pp_foreign" ]; then
    echo "✗ Weave pre-push: a $(jq -r '.kind // "gate"' <<< "$_pp_foreign" 2>/dev/null) gate held by $(jq -r '.agent_id // "unknown"' <<< "$_pp_foreign" 2>/dev/null) is running in another worktree of this repository (pid $(jq -r '.pid // "?"' <<< "$_pp_foreign" 2>/dev/null), since $(jq -r '.started_at // "?"' <<< "$_pp_foreign" 2>/dev/null)); this push is not sent beneath it." >&2
    echo "  Wait for that gate to finish, then fetch, rebase onto the remote and push again." >&2
    wv_gate_hold_release
    exit 1
fi
_pp_hold_finish() {
    local rc="$1"
    if [ "$rc" = 0 ]; then
        wv_gate_push_outcome passed "" 0
    else
        wv_gate_push_outcome failed "${_GATE_POOL_FAILED:-}" "$rc"
    fi
    wv_gate_hold_release
    return "$rc"
}
wv_gate_push_outcome running "$_pp_subject"
trap '_pp_hold_finish $?' EXIT

# ── What is being pushed ──────────────────────────────────────────────────────
# stdin: "<local ref> <local sha> <remote ref> <remote sha>" per ref. $1 is the
# remote's name, used to exclude what it already has when the remote sha is
# unknown here (a new branch, or a remote tip never fetched).
_pp_zero="0000000000000000000000000000000000000000"
# Record what this push publishes before the gate runs for minutes, so no
# checkpoint amends a commit in flight (wv-13db30). Best-effort, never refuses.
if command -v wv_push_inflight_record >/dev/null 2>&1; then
    # shellcheck disable=SC2046  # one word per pushed commit
    wv_push_inflight_record "$REPO_ROOT" $(awk -v z="$_pp_zero" 'NF >= 2 && $2 != z { print $2 }' <<< "$_pp_stdin")
fi
_pp_head=$(git rev-parse HEAD 2>/dev/null || echo "")
gate_pool_execution_mode "$_pp_head"
# The protected lane gates the commit its gate was copied from (S2a).
if [ -n "$_PP_LANE_BASE" ] && [ "$_pp_head" != "$_PP_LANE_BASE" ]; then
    echo "✗ Weave pre-push: HEAD moved between copying its committed gate ($_PP_LANE_BASE) and gating the push (${_pp_head:-none}) — refusing; re-run the push" >&2
    exit 1
fi
_pp_files=""        # files of the refs that owe heavy suites
_pp_any_files=""    # set when any pushed ref carries non-graph changes

_pp_heavy_all='[]'  # the heavy suites every pushed commit owes, as selection JSON

# _pp_heavy_maps <commit>... — true when the map of any named commit, or of
# any of its parents, has a [heavy] section: only then can a commit have
# deferred a suite. One cat-file batch for every map; a commit without one
# answers "missing", which is no map. A header is recognised as the router
# reads it, after leading whitespace (wv-cmd-graph.sh): matching only an
# unindented one let an indented [heavy] erase what was owed (review N3,
# wv-ee5e36). A map that cannot be read is an error, not a map without one.
_pp_heavy_maps() {
    local -a ids=()
    local blobs b listed
    # Listed on its own first: piped into tr and sort, a failed rev-list left
    # an empty list, read as no map, and the push skipped what it owed
    # (follow-up review F2, wv-6b31d9).
    listed=$(git rev-list --no-walk=unsorted --parents "$@" 2>/dev/null) || return 2
    mapfile -t ids < <(tr ' ' '\n' <<< "$listed" | sort -u)
    wait $! || return 2
    [ "${#ids[@]}" -gt 0 ] || return 1
    blobs=$(printf '%s:.weave/test-map.conf\n' "${ids[@]}" \
        | git cat-file --batch-check='%(objectname) %(objecttype)' 2>/dev/null) || return 2
    local text
    for b in $(awk '$2 == "blob" { print $1 }' <<< "$blobs" | sort -u); do
        text=$(git cat-file blob "$b" 2>/dev/null) || return 2
        grep -qE '^[[:space:]]*\[heavy\]' <<< "$text" && return 0
    done
    return 1
}

# _pp_commit_heavy <commit> — the heavy suites this commit owes, as selection
# JSON: the files it changes, routed by its own map and each parent's, the way
# its pre-commit gate routed them before deferring the heavy ones (R2,
# wv-418d4c). The tip's map alone forgot a suite a baseline route selected, or
# one a commit routed and a later one unrouted.
_pp_commit_heavy() {
    local c=$1 files parents p json
    local -a revs=(--map-rev="$c")
    files=$(git diff-tree --root -m -r --no-commit-id --name-only --no-renames "$c" 2>/dev/null) || return 1
    files=$(sort -u <<< "$files" | wv_non_graph_state_paths)
    if [ -z "$files" ]; then echo '[]'; return 0; fi
    parents=$(git rev-parse "$c^@" 2>/dev/null) || return 1
    for p in $parents; do revs+=(--map-rev="$p"); done
    json=$("$WV" impact --suites --files="$(paste -sd ',' - <<< "$files")" "${revs[@]}" 2>/dev/null) || return 1
    jq -c '[.[] | select(.tier == "heavy")]' <<< "$json"
}

# Each ref is judged on its own (ultrareview #4575): only a ref whose own
# commits owe a heavy suite must be the checked-out tip, so pushing a second
# ref that owes nothing is not refused. Several refs owing suites must all be
# HEAD, since one working tree can only test one tip.
while read -r _pp_lref _pp_lsha _pp_rref _pp_rsha; do
    [ -n "$_pp_lsha" ] || continue
    [ "$_pp_lsha" = "$_pp_zero" ] && continue          # a deletion pushes nothing
    if [ "$_pp_rsha" != "$_pp_zero" ] && git cat-file -e "${_pp_rsha}^{commit}" 2>/dev/null; then
        _pp_excl=("$_pp_rsha")
    else
        _pp_excl=("--remotes=${1:-origin}")
        # No remote-tracking ref under that name (a URL remote, or one never
        # fetched) makes the exclusion empty: every commit reachable from the
        # ref then counts as pushed. That over-selects -- slow, never unsafe --
        # so it is reported rather than guessed around.
        if [ -z "$(git for-each-ref --count=1 "refs/remotes/${1:-origin}/" 2>/dev/null)" ]; then
            hook_progress "no remote-tracking refs for '${1:-origin}': every commit reachable from $_pp_lref counts as pushed"
        fi
    fi
    # Every file any pushed commit touched, not just the tip diff: a suite a
    # commit selected is owed even if a later commit reverted the file.
    # Read separately: filtering a failed listing makes it look like no work.
    _pp_ref_files=$(git log --format= --name-only --no-renames "$_pp_lsha" --not "${_pp_excl[@]}" 2>/dev/null) || {
        echo "✗ Weave pre-push: could not list the files $_pp_lref pushes" >&2
        exit 1
    }
    _pp_ref_files=$(sort -u <<< "$_pp_ref_files" | wv_non_graph_state_paths)
    [ -n "$_pp_ref_files" ] || continue
    _pp_any_files=1
    _pp_commits=$(git rev-list "$_pp_lsha" --not "${_pp_excl[@]}" 2>/dev/null) || {
        echo "✗ Weave pre-push: could not list the commits $_pp_lref pushes" >&2
        exit 1
    }
    _pp_rc=0
    # shellcheck disable=SC2086  # a commit list, split on purpose
    _pp_heavy_maps $_pp_commits || _pp_rc=$?
    [ "$_pp_rc" -le 1 ] || {
        echo "✗ Weave pre-push: could not read the test maps of the commits $_pp_lref pushes" >&2
        exit 1
    }
    [ "$_pp_rc" -eq 0 ] || continue
    _pp_ref_json='[]'
    for _pp_c in $_pp_commits; do
        _pp_c_json=$(_pp_commit_heavy "$_pp_c") || {
            echo "✗ Weave pre-push: could not resolve the suites for $_pp_lref (commit ${_pp_c:0:12}, wv impact --suites failed)" >&2
            exit 1
        }
        _pp_ref_json=$(jq -c --slurpfile c <(printf '%s' "$_pp_c_json") '. + $c[0]' <<< "$_pp_ref_json") || exit 1
    done
    _pp_ref_heavy=$(jq -r '[.[].name] | unique | .[]' <<< "$_pp_ref_json")
    [ -n "$_pp_ref_heavy" ] || continue
    # One entry per heavy suite per pushed commit: a long unpushed branch grows
    # this past the argv limit, so it travels as a file (wv-200d36).
    _pp_heavy_all=$(jq -c --slurpfile c <(printf '%s' "$_pp_ref_json") '. + $c[0]' <<< "$_pp_heavy_all") || exit 1
    # The sha on stdin is what the ref points at: for an annotated tag that is
    # the tag object, never equal to HEAD. Compare the commit it names.
    _pp_commit=$(git rev-parse --verify --quiet "${_pp_lsha}^{commit}" 2>/dev/null || echo "$_pp_lsha")
    if [ "$_pp_commit" != "$_pp_head" ]; then
        echo "✗ Weave pre-push: $_pp_lref is not HEAD, and the heavy tier it owes ($(paste -sd ',' - <<< "$_pp_ref_heavy" | sed 's/,/, /g')) runs from the working tree." >&2
        echo "  Check out that commit and push it from there, so what is tested is what is pushed." >&2
        exit 1
    fi
    _pp_files=$(printf '%s\n%s\n' "$_pp_files" "$_pp_ref_files" | sed '/^$/d' | sort -u)
done <<< "$_pp_stdin"

[ -n "$_pp_any_files" ] || exit 0
if [ -z "$_pp_files" ]; then
    hook_progress "no heavy-tier suite selected by the pushed commits"
    exit 0
fi
_pc_files_csv=$(printf '%s\n' "$_pp_files" | paste -sd ',' -)
# One entry per suite: declared if any commit's route declared it.
_pp_heavy_json=$(jq -c 'group_by(.name) | map(.[0] + {declared: (map(if has("declared") then .declared else true end) | any)})' \
    <<< "$_pp_heavy_all" 2>/dev/null) || {
    echo "✗ Weave pre-push: could not read the suite selection" >&2
    exit 1
}
# A heavy suite the pushed tip lacks is not a passed one (R3, wv-fb861c). The
# tip is HEAD here, and what excuses or stands in for an owed suite is what it
# holds: an untracked retirement catalogue or an untracked copy of a deleted
# suite is the working tree's, not the pushed tree's (review N4, wv-87032c).
# The suite still runs from the working tree, which the tracked-file check
# below holds to the tip.
_pp_tip_file() { # _pp_tip_file <path> — 0 a regular file in HEAD, 1 none, 2 other
    local entry
    entry=$(git ls-tree HEAD -- "$1" 2>/dev/null) || return 2
    [ -n "$entry" ] || return 1
    case "$entry" in
        "100644 blob "*|"100755 blob "*) return 0 ;;
        *) return 2 ;;
    esac
}
_pp_suite_present() {
    local rc=0
    _pp_tip_file "$1" || rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    [ -f "$REPO_ROOT/$1" ] && return 0
    return 2
}
_pp_retired=""
_pp_rc=0; _pp_tip_file .weave/test-map-retired.conf || _pp_rc=$?
case "$_pp_rc" in
    0) _pp_retired=$(git cat-file blob HEAD:.weave/test-map-retired.conf 2>/dev/null) || {
           echo "✗ Weave pre-push: could not read the pushed tree's retirement catalogue (.weave/test-map-retired.conf)" >&2
           exit 1; } ;;
    1) ;;
    *) echo "✗ Weave pre-push: the pushed tree's .weave/test-map-retired.conf is not a regular file" >&2
       exit 1 ;;
esac
_pp_heavy_json=$(gate_pool_require_present "$_pp_heavy_json" _pp_suite_present "$_pp_retired") || exit 1
_pp_heavy_names=$(jq -r '[.[].name] | join(", ")' <<< "$_pp_heavy_json")

# ── The tree must be the tip ─────────────────────────────────────────────────
# The comparison is taken on its own: piped into the filter, a failed git diff
# read as a clean tree (wv-6b31d9).
_pp_diff=$(git diff --name-only HEAD 2>/dev/null) || {
    echo "✗ Weave pre-push: could not compare the working tree with the pushed tip" >&2
    exit 1
}
_pp_dirty=$(wv_non_graph_state_paths <<< "$_pp_diff")
if [ -n "$_pp_dirty" ]; then
    echo "✗ Weave pre-push: tracked files differ from the pushed tip, so the heavy tier would not test what is pushed:" >&2
    printf '%s\n' "$_pp_dirty" | head -5 | sed 's/^/    /' >&2
    echo "  Commit or stash them, then push again." >&2
    exit 1
fi

# ── Run the heavy tier ────────────────────────────────────────────────────────
export WV_GATE_PHASE=pre-push
WV_GATE_ID="pp-$(date +%s%N 2>/dev/null || date +%s)-$$"
export WV_GATE_ID
_pp_gate_t0=$(date +%s%N 2>/dev/null || echo 0)
wv_clock_ms _pp_gate_c0 _pp_gate_k0 2>/dev/null || _pp_gate_k0=unknown
_pp_gate_pressure0=$(gate_pressure_totals 2>/dev/null)
_pp_gate_finish() {
    local rc=$? suites ms=0 clock=unknown
    suites=$(jq -r '[.[].name] | join(",")' <<< "$_pp_heavy_json" 2>/dev/null)
    wv_clock_since ms clock "${_pp_gate_c0:-}" "$_pp_gate_k0" 2>/dev/null || clock=unknown
    "$WV" test-record gate --gate --exit="$rc" --duration="$ms" --clock="$clock" \
        --execution-mode="${WV_GATE_EXECUTION_MODE:-}" \
        --suite-modes="$(gate_pool_suite_modes "$suites")" \
        --suites="$suites" \
        --started-ms="$(_pc_ns_to_ms "$_pp_gate_t0" 2>/dev/null)" \
        --pressure-start="$_pp_gate_pressure0" --pressure-end="$(gate_pressure_totals 2>/dev/null)" \
        >/dev/null 2>&1 || true
    _pp_hold_finish "$rc"
}
trap _pp_gate_finish EXIT

_pp_heavy_json=$(gate_pool_estimates "$_pp_heavy_json")
hook_progress "heavy tier for ${_pp_head:0:9}: $_pp_heavy_names"

_pc_pool_context=prepush
_pc_pool_reuse=worktree
# No gate base (wv-bab095): a push can carry several refs with no single base,
# and no heavy suite makes a transition check, so the suites judge the tip with
# HEAD as their base. An inherited WV_GATE_BASE must not stand in for one. A
# transition check moved to the heavy tier needs a base per ref first.
unset WV_GATE_BASE
_pp_launch=$(gate_pool_launch_order "$_pp_heavy_json") || exit 1
run_hook_suites <<< "$_pp_launch"
hook_progress "heavy tier green for ${_pp_head:0:9}"
exit 0
