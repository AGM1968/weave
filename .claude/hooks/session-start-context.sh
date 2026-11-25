#!/usr/bin/env bash
# SessionStart hook: Claude Code adapter over `wv hook dispatch --event=SessionStart`.
#
# Session start itself -- crash detection from the sentinel, the shrink guard,
# phase reset, wv load, the session-start checkpoint and the injected context --
# lives in scripts/lib/wv-session-start.sh, the one implementation every host
# runs (agnostic-cutover S4a, wv-a523de). Codex's .codex/hooks.json calls the
# same command. This adapter only resolves wv and pipes the host payload through;
# --format=host emits the hookSpecificOutput object Claude Code reads.
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

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# Resolve wv beside this hook first (checkout hook -> checkout wv, installed hook
# -> installed wv), so a suite driving the checkout never runs an older install.
source "$HOOK_DIR/../lib/wv-resolve-project.sh" 2>/dev/null \
    || source "$HOOK_DIR/../../scripts/lib/wv-resolve-project.sh" 2>/dev/null \
    || source "${HOME}/.config/weave/lib/wv-resolve-project.sh" 2>/dev/null \
    || exit 0
source "$HOOK_DIR/../lib/wv-hook-common.sh" 2>/dev/null \
    || source "$HOOK_DIR/../../scripts/lib/wv-hook-common.sh" 2>/dev/null \
    || source "${HOME}/.config/weave/lib/wv-hook-common.sh" 2>/dev/null \
    || true
command -v _hc_refresh >/dev/null 2>&1 && _hc_refresh

if [ ! -x "${WV:-}" ]; then
    echo "wv CLI not found"
    exit 0
fi
export WV WV_PROJECT_DIR

# This adapter only runs as a SessionStart hook, so it is always a real session
# start: an empty or terminal stdin still sends a payload, because dispatch
# reads empty stdin as a manual invocation and skips the session-start work.
payload='{}'
if [ ! -t 0 ]; then
    payload=$(cat)
    [ -n "$payload" ] || payload='{}'
fi

# Fail open: a session must start even when dispatch cannot run.
output=$(printf '%s' "$payload" | "$WV" hook dispatch --event=SessionStart --format=host 2>/dev/null) || true
if printf '%s' "$output" | jq -se 'length == 1 and (.[0] | .hookSpecificOutput.hookEventName == "SessionStart")' >/dev/null 2>&1; then
    printf '%s\n' "$output"
else
    jq -n '{hookSpecificOutput: {hookEventName: "SessionStart",
        additionalContext: "Weave: session start unavailable (wv hook dispatch failed); run wv bootstrap --json"}}'
fi
exit 0
