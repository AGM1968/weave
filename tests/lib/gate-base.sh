# shellcheck shell=bash
# gate-base.sh — the commit a gated candidate is judged against (wv-bab095).
#
# A check that compares a change with what came before it reads that "before"
# from history. In place, HEAD is the base: the candidate is the index or the
# tree, not yet a commit. In a snapshot (a detached worktree of a commit built
# from the index) HEAD is the candidate itself, so a check reading HEAD compares
# the candidate with itself and passes whatever it removed. The gate therefore
# names the base explicitly in WV_GATE_BASE, and a history-sensitive suite reads
# it from here instead of from HEAD.
#
# gate_base <repo> — print the base commit's OID.
#   WV_GATE_BASE set: it must name a commit in <repo> that is HEAD or an
#   ancestor of it. Anything else is an error, never a fallback to HEAD: a base
#   that does not resolve would otherwise quietly turn the check vacuous.
#   WV_GATE_BASE unset: HEAD, which is the base for an in-place run.
gate_base() {
    local repo=$1 base
    if [ -n "${WV_GATE_BASE+x}" ]; then
        if ! base=$(git -C "$repo" rev-parse --verify --quiet "${WV_GATE_BASE}^{commit}" 2>/dev/null) \
            || [ -z "$base" ]; then
            echo "gate base: WV_GATE_BASE='$WV_GATE_BASE' does not name a commit in $repo" >&2
            return 1
        fi
        if ! git -C "$repo" merge-base --is-ancestor "$base" HEAD 2>/dev/null; then
            echo "gate base: WV_GATE_BASE $base is not HEAD or an ancestor of HEAD in $repo" >&2
            return 1
        fi
    elif ! base=$(git -C "$repo" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null) \
        || [ -z "$base" ]; then
        echo "gate base: $repo has no HEAD commit to compare against" >&2
        return 1
    fi
    printf '%s\n' "$base"
}

# map_transition_check <repo> <scratch dir> — the test-map monotonicity check:
# every suite the base's map selected for a tracked path is still selected by
# the map in <repo>'s tree, unless .weave/test-map-retired.conf retires it.
# Prints the checker's findings; returns its verdict. The checker is the one
# beside this file, so a fixture repository needs no copy of it.
map_transition_check() {
    local repo=$1 scratch=$2 base
    base=$(gate_base "$repo") || return 1
    if ! git -C "$repo" show "$base:.weave/test-map.conf" > "$scratch/test-map.base.conf" 2>/dev/null; then
        echo "map transition: the base ${base:0:12} has no readable .weave/test-map.conf" >&2
        return 1
    fi
    python3 "$(dirname "${BASH_SOURCE[0]}")/test-map-monotonic.py" "$scratch/test-map.base.conf" \
        "$repo/.weave/test-map.conf" --repo "$repo" \
        --retired "$repo/.weave/test-map-retired.conf" 2>&1
}
