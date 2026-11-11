#!/bin/bash
# wv-git-hook-signature.sh — one definition of "this installed git hook is
# Weave's" (wv-3a7368).
#
# The installers (install.sh, and the wv-init-repo it generates) refresh a
# Weave hook and place the pre-commit module beside it; wv doctor reports the
# same hooks. Each used to carry its own test, and doctor's matched only the
# current header, so a hook the installers refreshed as Weave's was called
# custom by doctor. All of them now ask this file. install.sh loads it from
# ./scripts/lib, wv-init-repo and wv doctor from the installed lib dir.
#
# Defines functions only: no exports, no other sources, safe to load anywhere.

# Stable Weave signatures, any hook: the header line of each hook Weave has
# shipped, the prepare-commit-msg trailer text, and the skip knob and
# hook-common load that an older pre-commit carried before its header changed.
WV_GIT_HOOK_SIGNATURE='# Weave (pre-commit|post-commit|prepare-commit|pre-push|reference-transaction)|Weave: append Weave-ID|WV_SKIP_PRECOMMIT|wv-hook-common'

# wv_git_hook_is_weave <file> [marker] — true when FILE is a Weave hook: it
# carries MARKER (the caller's current header, an extended regex) or any
# stable signature above. A missing file is not a Weave hook.
wv_git_hook_is_weave() {
    local file="$1" marker="${2:-}" pattern="$WV_GIT_HOOK_SIGNATURE"
    [ -f "$file" ] || return 1
    [ -n "$marker" ] && pattern="$marker|$pattern"
    grep -qE -- "$pattern" "$file" 2>/dev/null
}
