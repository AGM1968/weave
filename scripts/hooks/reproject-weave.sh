#!/usr/bin/env bash
# Weave re-projection hook, installed as post-rewrite and post-merge: after a
# rebase or merge, ask the graph whether the committed .weave/ snapshot still
# carries the operations committed with it (wv-6729a0).
#
# .gitattributes merges .weave/state.sql with merge=ours, so a rebase keeps
# upstream's snapshot and a merge keeps this side's, while both sides'
# operations travel. The graph decides and acts: wv recover --reproject runs the
# projection verdict and, only when the snapshot lags, rebuilds it (wv load,
# wv sync) and commits graph state alone as a new commit. This hook only asks.
# It never fails the rebase or merge; pre-push still refuses a lagging snapshot.
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

case "$(basename "$0")" in
    post-rewrite)
        # $1 is rebase or amend; stdin lists the rewritten commits. An amend
        # merges nothing.
        cat >/dev/null
        [ "${1:-}" = rebase ] || exit 0
        event=rebase ;;
    post-merge) event=merge ;;
    *) exit 0 ;;
esac
root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -d "$root/.weave" ] || exit 0
WV=$(command -v wv 2>/dev/null) || WV="$HOME/.local/bin/wv"
[ -x "$WV" ] || exit 0
[ "${WV_CALL_SOURCE:-}" = "test" ] || export WV_CALL_SOURCE=hook
"$WV" recover --reproject --event="$event" || true
exit 0
