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
# Results are keyed in the verification ledger on the pushed files' contents,
# so a retried push of the same content reuses its green rows.
#
# Skip with: git push --no-verify (never in this repository: CLAUDE.md rule 8)

# Stale-copy guard (wv-98f12b): see pre-commit-weave.sh.
_wv_hook_src="$(git rev-parse --show-toplevel 2>/dev/null)/scripts/hooks/pre-push-weave.sh"
if [ -z "${WV_HOOK_REEXEC:-}" ] && [ -f "$_wv_hook_src" ] && ! cmp -s "$_wv_hook_src" "$0"; then
    echo "Weave pre-push: installed hook differs from scripts/hooks/pre-push-weave.sh — running the source (refresh with ./install.sh)" >&2
    export WV_HOOK_REEXEC=1
    exec bash "$_wv_hook_src" "$@"
fi

hook_progress() {
    [ "${WV_HOOK_PROGRESS:-1}" = "0" ] && return 0
    printf '%s\n' "Weave pre-push: $1" >&2
}

# hook_duration_ms <start_nanos> — see pre-commit-weave.sh.
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

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
WV="$(command -v wv 2>/dev/null || echo "$REPO_ROOT/scripts/wv")"
[ -x "$WV" ] || exit 0
# No test map, no [heavy] section: nothing was deferred, nothing to gate.
grep -q '^\[heavy\]' "$REPO_ROOT/.weave/test-map.conf" 2>/dev/null || exit 0

# Libraries beside this hook first (scripts/hooks/../lib, the source a checkout
# runs), then the repository's, then the installed ones: the gate never mixes
# this hook with libraries of another version when its own are at hand.
for _pp_lib in wv-checkpoint-ci.sh wv-gate-pool.sh; do
    for _pp_cand in "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/../lib" \
        "$REPO_ROOT/scripts/lib" "$HOME/.local/lib/weave/lib"; do
        if [ -f "$_pp_cand/$_pp_lib" ]; then
            # shellcheck source=/dev/null
            source "$_pp_cand/$_pp_lib"
            break
        fi
    done
done
if ! command -v run_hook_suites >/dev/null 2>&1 || ! command -v gate_pool_estimates >/dev/null 2>&1 \
    || ! command -v gate_pool_launch_order >/dev/null 2>&1 || ! command -v wv_non_graph_state_paths >/dev/null 2>&1; then
    echo "✗ Weave pre-push: the gate libraries (wv-gate-pool.sh, wv-checkpoint-ci.sh) were not found — refresh with ./install.sh" >&2
    exit 1
fi

# ── What is being pushed ──────────────────────────────────────────────────────
# stdin: "<local ref> <local sha> <remote ref> <remote sha>" per ref. $1 is the
# remote's name, used to exclude what it already has when the remote sha is
# unknown here (a new branch, or a remote tip never fetched).
_pp_zero="0000000000000000000000000000000000000000"
_pp_head=$(git rev-parse HEAD 2>/dev/null || echo "")
_pp_files=""        # files of the refs that owe heavy suites
_pp_any_files=""    # set when any pushed ref carries non-graph changes

# _pp_heavy_for <files> — the heavy suites these files select, one per line.
_pp_heavy_for() {
    local json
    json=$("$WV" impact --suites --files="$(printf '%s\n' "$1" | paste -sd ',' -)" 2>/dev/null) || return 1
    jq -r '.[] | select(.tier == "heavy") | .name' <<< "$json" 2>/dev/null
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
    _pp_ref_files=$(git log --format= --name-only --no-renames "$_pp_lsha" --not "${_pp_excl[@]}" 2>/dev/null \
        | sort -u | wv_non_graph_state_paths)
    [ -n "$_pp_ref_files" ] || continue
    _pp_any_files=1
    _pp_ref_heavy=$(_pp_heavy_for "$_pp_ref_files") || {
        echo "✗ Weave pre-push: could not resolve the suites for $_pp_lref (wv impact --suites failed)" >&2
        exit 1
    }
    [ -n "$_pp_ref_heavy" ] || continue
    # The sha on stdin is what the ref points at: for an annotated tag that is
    # the tag object, never equal to HEAD. Compare the commit it names.
    _pp_commit=$(git rev-parse --verify --quiet "${_pp_lsha}^{commit}" 2>/dev/null || echo "$_pp_lsha")
    if [ "$_pp_commit" != "$_pp_head" ]; then
        echo "✗ Weave pre-push: $_pp_lref is not HEAD, and the heavy tier it owes ($(paste -sd ',' - <<< "$_pp_ref_heavy" | sed 's/,/, /g')) runs from the working tree." >&2
        echo "  Check out that commit and push it from there, so what is tested is what is pushed." >&2
        exit 1
    fi
    _pp_files=$(printf '%s\n%s\n' "$_pp_files" "$_pp_ref_files" | sed '/^$/d' | sort -u)
done

[ -n "$_pp_any_files" ] || exit 0
if [ -z "$_pp_files" ]; then
    hook_progress "no heavy-tier suite selected by the pushed commits"
    exit 0
fi
_pc_files_csv=$(printf '%s\n' "$_pp_files" | paste -sd ',' -)
_pp_heavy_json=$("$WV" impact --suites --files="$_pc_files_csv" 2>/dev/null) || {
    echo "✗ Weave pre-push: could not resolve the suites for the pushed files (wv impact --suites failed)" >&2
    exit 1
}
_pp_heavy_json=$(jq -c '[.[] | select(.tier == "heavy")]' <<< "$_pp_heavy_json" 2>/dev/null) || {
    echo "✗ Weave pre-push: could not read the suite selection" >&2
    exit 1
}
_pp_heavy_names=$(jq -r '[.[].name] | join(", ")' <<< "$_pp_heavy_json")

# ── The tree must be the tip ─────────────────────────────────────────────────
_pp_dirty=$(git diff --name-only HEAD 2>/dev/null | wv_non_graph_state_paths)
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
_pp_gate_finish() {
    local rc=$?
    "$WV" test-record gate --gate --exit="$rc" --duration="$(hook_duration_ms "$_pp_gate_t0")" \
        --suites="$(jq -r '[.[].name] | join(",")' <<< "$_pp_heavy_json" 2>/dev/null)" >/dev/null 2>&1 || true
    return "$rc"
}
trap _pp_gate_finish EXIT

_pp_heavy_json=$(gate_pool_estimates "$_pp_heavy_json")
hook_progress "heavy tier for ${_pp_head:0:9}: $_pp_heavy_names"

_pc_pool_context=prepush
_pc_pool_reuse=worktree
_pp_launch=$(gate_pool_launch_order "$_pp_heavy_json")
run_hook_suites <<< "$_pp_launch"
hook_progress "heavy tier green for ${_pp_head:0:9}"
exit 0
