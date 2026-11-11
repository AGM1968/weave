#!/usr/bin/env bash
# Sourced by test-gate-lanes.sh. R-a of the lane review (wv-a75d98): the four
# external enforcement files are absent from the gate's envelope and copied
# only for the check that reads each. Kept out of the suite itself because the
# release strips these paths.

_eg_files=(build-release.sh tests/lib/release-leak-pattern.ere tests/test-shipped-test-refs.sh
    tests/test-memory-projection-parity.sh)

# _eg_plant <tree> — what a builder older than wv-a75d98 left in the envelope.
_eg_plant() {
    local f
    for f in "${_eg_files[@]}"; do
        mkdir -p "$(dirname "$1/$f")" && printf 'old builder copy\n' > "$1/$f"
    done
}

# _eg_check <tree> — the hook removed them before anything ran, and only the
# reviewed gate files name them.
_eg_check() {
    check "an external file an older builder left in the envelope is removed before anything runs (R-a)" "" \
        "$(cd "$1" && ls "${_eg_files[@]}" 2>/dev/null)"
    # The hook runs each one only through the check that declares it.
    check "the hook runs an external file only from a check's private copy" "" \
        "$(grep -nE '_PC_SCRIPTS/\.\./(tests|build-release)' "$ROOT/$HOOK")"
}
