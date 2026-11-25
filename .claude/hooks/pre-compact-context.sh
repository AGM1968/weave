#!/usr/bin/env bash
# PreCompact hook: Claude Code adapter for the graph-state checkpoint commit and
# the compact work snapshot (~100-200 tokens) printed before conversation
# compaction. The implementation is wv_pre_compact_context in
# scripts/lib/wv-lifecycle-end.sh; Codex reaches the same function through wv
# hook dispatch --event=PreCompact --format=host (wv-25903d). It runs in-process
# here, as stop-check.sh does, so the wv it resolves is the one the hook pairs
# with and no wv start is added.

# The payload is not read by the snapshot; never wait on a terminal for it.
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

INPUT='{}'
[ -t 0 ] || INPUT=$(cat)
HOOK_DIR="${BASH_SOURCE[0]:-$0}"
case "$HOOK_DIR" in */*) HOOK_DIR="${HOOK_DIR%/*}" ;; *) HOOK_DIR=. ;; esac
# Nearest copy first; a copy that fails to load falls through to the next.
for _le_dir in "$HOOK_DIR/../lib" "$HOOK_DIR/../../scripts/lib" "${HOME}/.config/weave/lib"; do
    [ -r "$_le_dir/wv-lifecycle-end.sh" ] || continue
    # shellcheck source=/dev/null
    . "$_le_dir/wv-lifecycle-end.sh" 2>/dev/null && declare -F wv_pre_compact_context >/dev/null && break
    unset _WV_LIFECYCLE_END_LOADED
done
declare -F wv_pre_compact_context >/dev/null || exit 0
# Compaction must go ahead even when the snapshot cannot be built.
wv_pre_compact_context "$INPUT" || true
exit 0
