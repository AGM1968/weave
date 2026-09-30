#!/usr/bin/env bash
# wv-checkpoint-ci.sh — decide whether a weave-authored checkpoint/sync commit
# may safely carry GitHub's native [skip ci] push-skip marker.
#
# wv-e937f8 (external audit, earth-engine-analysis dev.3 session, cross-
# referenced against this repo's own wv-4637d2-equivalent history): GitHub
# applies [skip ci] to the WHOLE PUSH when the marker appears in the commit
# at the push's TIP, not just that commit's own diff. Every checkpoint site
# below stages `.weave/` only, so the checkpoint's OWN diff is always
# .weave-only — but if the checkpoint lands on top of already-unpushed
# non-.weave/ work (a real code/doc commit still waiting to be pushed),
# reinstating the marker silently skips CI for that work too the moment this
# checkpoint becomes the push tip. Reproduced live in this repo's own
# history: commit ec4eea5c ("auto-checkpoint ... [skip ci]") landed directly
# on top of 42f8e759 (real code+tests) and both were pushed together.
#
# wv-f76ac9's CI paths-ignore snippet fixes this from the CONSUMER's
# workflow-rule side (keys on changed files, robust to token placement).
# This fixes the marker at the source, for repos that haven't adopted that
# snippet or whose CI still greps the message.
#
# wv-822bea/wv-179c49 (distribution re-audit of wv-e937f8): the first cut
# above had three residual gaps, all in the direction of applying [skip ci]
# when it was NOT actually safe to:
#   1. Hardcoded "origin/$branch" instead of resolving the branch's actual
#      configured upstream via @{u} — wrong for a differently-named remote
#      branch or a non-origin remote.
#   2. Defaulted to " [skip ci]" whenever the upstream didn't resolve (new
#      branch, never pushed, or any other lookup failure). That's backwards:
#      a brand-new branch's first push sends its ENTIRE history as the push
#      tip's range, so a real code commit sitting under a [skip-ci-marked]
#      checkpoint gets silently skipped on that very first push — the exact
#      failure mode this function exists to prevent. Reproduced live in this
#      repo: a fresh branch + a real commit + no upstream both produced a
#      marker under the old logic.
#   3. Used the endpoint `git diff upstream..HEAD --name-only`, which shows
#      only the NET difference between two trees — a file added by one
#      unpushed commit and removed by a later one in the same range vanishes
#      from that diff entirely, even though non-.weave/ work did happen in
#      the range. `git log --name-only` over the same range lists every path
#      touched by any commit in it, which is what "does this range carry
#      non-.weave/ work" actually means.
# All three point the same direction: an inspection that can't prove the
# range is .weave/-only must fail toward NOT skipping CI, not toward
# skipping it — a spuriously-run CI check costs nothing but a bit of compute,
# a spuriously-skipped one silently hides a real regression from review.

# wv_checkpoint_ci_marker <git-root>
#   Echoes " [skip ci]" (leading space, ready to append to a commit subject)
#   only when the upstream resolves AND every path touched anywhere in the
#   unpushed range (@{u}..HEAD) is under .weave/. Echoes "" (empty) — no
#   marker, CI runs normally — when the range carries any non-.weave/ path,
#   when @{u} doesn't resolve (no remote, branch never pushed, no upstream
#   configured), or on any git inspection failure. Never fails the caller.
wv_checkpoint_ci_marker() {
    local git_root="$1"
    local upstream nonweave
    upstream=$(git -C "$git_root" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || echo "")
    if [ -z "$upstream" ]; then
        # No configured upstream (new/never-pushed branch, or none set) —
        # can't bound the range that would be pushed, so can't prove it's
        # .weave/-only. Fail toward running CI, not skipping it.
        echo ""
        return
    fi
    if ! git -C "$git_root" rev-parse --verify -q "$upstream" >/dev/null 2>&1; then
        # Upstream is configured but doesn't resolve locally (stale
        # tracking ref, not yet fetched) — same fail-safe direction.
        echo ""
        return
    fi
    local log_output log_rc
    # --no-renames: a source file moved into .weave/ listed only its new path,
    # so the range read as .weave/-only and CI was skipped (wv-581bb0).
    log_output=$(git -C "$git_root" log --format= --name-only --no-renames "$upstream..HEAD" 2>/dev/null)
    log_rc=$?
    if [ "$log_rc" -ne 0 ]; then
        # git log itself failed (bad range, corrupt repo, ...) — can't prove
        # .weave/-only, fail toward running CI.
        echo ""
        return
    fi
    nonweave=$(printf '%s\n' "$log_output" | grep -v '^\.weave/' | grep -v '^$' || true)
    if [ -n "$nonweave" ]; then
        echo ""
    else
        echo " [skip ci]"
    fi
}

# ── Graph state vs configuration (wv-2e6341) ──────────────────────────────────
# Checkpoint and sync commits carry the graph: files wv rewrites on its own as
# the graph changes. Everything else under .weave/ -- test-map.conf,
# quality.conf, patterns/, causal-cutover, evidence/ -- is configuration someone
# edits on purpose, and a change there selects pre-commit suites of its own.
# Staging all of .weave/ swept an in-progress test-map row into a
# 'session-start state' commit that skipped every one of those gates. This list
# is an allowlist: a new file wv writes stays uncommitted (and the stop hook
# says so) until it is added here, which is the safe direction.
WV_GRAPH_STATE_PATHS=(
    .weave/state.sql
    .weave/nodes.jsonl
    .weave/edges.jsonl
    .weave/deltas
    .weave/trails.md
    .weave/breadcrumbs.md
    .weave/runtime.md
    .weave/quality-adjudications.jsonl
)

# wv_stage_graph_state <git-root>
#   Stages additions, changes and deletions under the graph-state paths only.
#   A path is passed to git add when it is tracked, or on disk and not ignored:
#   one unmatched pathspec makes git add stage nothing, and an ignored one
#   makes it fail after staging the rest.
wv_stage_graph_state() {
    local git_root="$1" path present=()
    for path in "${WV_GRAPH_STATE_PATHS[@]}"; do
        if [ -n "$(git -C "$git_root" ls-files -- "$path" 2>/dev/null | head -1)" ] \
           || { [ -e "$git_root/$path" ] && ! git -C "$git_root" check-ignore -q -- "$path" 2>/dev/null; }; then
            present+=("$path")
        fi
    done
    [ "${#present[@]}" -gt 0 ] || return 0
    git -C "$git_root" add -A -- "${present[@]}"
}

# wv_staged_non_graph_state <git-root>
#   Prints staged paths that are not graph state, one per line: caller work,
#   including .weave/ configuration. A checkpoint that finds any must not
#   commit, or it absorbs that work.
wv_staged_non_graph_state() {
    local staged
    # --no-renames: a caller file moved into .weave/ must still show its removal.
    staged=$(git -C "$1" diff --cached --name-only --no-renames 2>/dev/null) || return 0
    wv_non_graph_state_paths <<< "$staged"
}

# wv_prepush_gate_installed — true when git will run a Weave pre-push hook in
# this repository (core.hooksPath respected). The two-tier gate (wv-862ac0)
# defers [heavy] suites to that hook only when this holds, and wv done treats a
# heavy suite with no fresh row as deferred rather than stale only when it
# holds, so both sides of the deferral answer the question the same way.
wv_prepush_gate_installed() {
    local hook
    hook="$(git rev-parse --git-path hooks 2>/dev/null)/pre-push"
    [ -f "$hook" ] && grep -q "Weave pre-push" "$hook" 2>/dev/null
}

# wv_non_graph_state_paths — filter repo-relative paths on stdin to those
# outside graph state, by the same allowlist. The pre-push gate (wv-862ac0)
# classifies a pushed range's files with it, so its idea of "graph state" is
# the one pre-commit and the checkpoint sites use.
wv_non_graph_state_paths() {
    local path prefix
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        for prefix in "${WV_GRAPH_STATE_PATHS[@]}"; do
            if [ "$path" = "$prefix" ] || [[ "$path" == "$prefix"/* ]]; then
                continue 2
            fi
        done
        printf '%s\n' "$path"
    done
}
