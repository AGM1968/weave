#!/usr/bin/env bash
# Stop hook: Claude Code adapter for the session-end guard. The guard is
# wv_stop_guard in scripts/lib/wv-lifecycle-end.sh; Codex reaches the same guard
# through wv hook dispatch --event=Stop --format=host (wv-25903d). It runs
# in-process here rather than through wv, which would add a wv start to every
# response.
#
# Hard block: an active node claimed by this agent, as {"decision":"block"}
# with exit 0. Soft warn on stderr: uncommitted changes, unpushed commits,
# unsaved weave state. No network calls.
# wv bash guard (wv-7257a8): bash >= 4 or a clear refusal. Identical in every executed entry point; master: scripts/lib/wv-bash-guard.sh.
_wv_bash_guard() {
    if [ -n "${WV_TEST_BASH_TOO_OLD:-}" ] && [ "${WV_TEST_MODE:-}" != 1 ]; then echo "wv: WV_TEST_BASH_TOO_OLD needs WV_TEST_MODE=1; ignoring it." >&2; fi
    if [ "${BASH_VERSINFO[0]:-0}" -ge 4 ] && ! { [ "${WV_TEST_MODE:-}" = 1 ] && [ "${WV_TEST_BASH_TOO_OLD:-}" = 1 ]; }; then
        unset WV_BASH_REEXEC
        return 0
    fi
    local b
    if [ -z "${WV_BASH_REEXEC:-}" ] && [ -f "$0" ]; then
        for b in ${WV_BASH:-} /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash /bin/bash; do
            # shellcheck disable=SC2016  # the child bash expands it
            if [ -x "$b" ] && [ "$("$b" -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null)" -ge 4 ] 2>/dev/null; then
                WV_BASH_REEXEC=1 WV_TEST_BASH_TOO_OLD='' exec "$b" "$0" "$@"
            fi
        done
    fi
    echo "wv: $0 needs bash 4 or newer but is running under bash ${BASH_VERSION:-unknown}." >&2
    echo "    On macOS /bin/bash is 3.2: install a newer one (brew install bash) or set WV_BASH to it." >&2
    exit 1
}
_wv_bash_guard "$@"
# end wv bash guard

INPUT=$(cat)
# The directory without forking: this runs after every response.
HOOK_DIR="${BASH_SOURCE[0]:-$0}"
case "$HOOK_DIR" in */*) HOOK_DIR="${HOOK_DIR%/*}" ;; *) HOOK_DIR=. ;; esac
# Nearest copy first; a copy that fails to load falls through to the next.
for _le_dir in "$HOOK_DIR/../lib" "$HOOK_DIR/../../scripts/lib" "${HOME}/.config/weave/lib"; do
    [ -r "$_le_dir/wv-lifecycle-end.sh" ] || continue
    # shellcheck source=/dev/null
    . "$_le_dir/wv-lifecycle-end.sh" 2>/dev/null && declare -F wv_stop_guard >/dev/null && break
    unset _WV_LIFECYCLE_END_LOADED
done
# No guard loaded (missing or half-installed lib, e.g. mid ./install.sh from
# another session): never pass silently (wv-c7d114). Block once, so the agent
# checks its active work by hand; the retry carries stop_hook_active=true and
# is allowed with a warning, so a broken install cannot trap a session. Plain
# shell only: whatever broke the lib may have broken jq too.
if ! declare -F wv_stop_guard >/dev/null; then
    echo "weave stop guard: wv-lifecycle-end.sh could not be loaded from $HOOK_DIR/../lib, $HOOK_DIR/../../scripts/lib or ${HOME}/.config/weave/lib; active work was not checked (re-run ./install.sh)" >&2
    case "$INPUT" in
        *'"stop_hook_active"'*:*true*) exit 0 ;;
    esac
    printf '%s\n' '{"decision":"block","reason":"The Weave stop guard could not load wv-lifecycle-end.sh, so active work was not checked. Run wv status: close or hand off any active node you own, then stop again (the next stop is allowed). Re-run ./install.sh to repair the guard."}'
    exit 0
fi
wv_stop_guard "$INPUT"
exit $?
