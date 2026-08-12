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
    log_output=$(git -C "$git_root" log --format= --name-only "$upstream..HEAD" 2>/dev/null)
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
