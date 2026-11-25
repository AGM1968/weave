#!/usr/bin/env bash
# PreToolUse hook: Claude Code adapter for the Bash duplicate and busy-wait
# lock. The guard is wv_ptu_dedup_guard in scripts/lib/wv-pre-tool-use.sh, with
# the lock lifecycle documented there; bash-dedup-post.sh releases the lock.
# Codex reaches the same guard and its release through wv hook dispatch
# (wv-594381).
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
# The directory without forking: these run on every tool call.
HOOK_DIR="${BASH_SOURCE[0]:-$0}"
case "$HOOK_DIR" in */*) HOOK_DIR="${HOOK_DIR%/*}" ;; *) HOOK_DIR=. ;; esac
# Nearest copy first; a copy that fails to load falls through to the next.
for _ptu_dir in "$HOOK_DIR/../lib" "$HOOK_DIR/../../scripts/lib" "${HOME}/.config/weave/lib"; do
    [ -r "$_ptu_dir/wv-pre-tool-use.sh" ] || continue
    # shellcheck source=/dev/null
    . "$_ptu_dir/wv-pre-tool-use.sh" 2>/dev/null && declare -F wv_ptu_dedup_guard >/dev/null && break
    unset _WV_PRE_TOOL_USE_LOADED
done
declare -F wv_ptu_dedup_guard >/dev/null || exit 0
wv_ptu_dedup_guard "$INPUT"
exit $?
