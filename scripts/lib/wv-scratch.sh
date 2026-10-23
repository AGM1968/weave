#!/usr/bin/env bash
# Bulky test/capture scratch, not live graph placement (wv-b6cd56).
# Source and call wv_scratch_create, or execute this file. stdout is a unique
# owned directory; diagnostics go to stderr. The caller removes ONLY that child.
wv_scratch_create() {
    local root minimum available
    root="${WV_SCRATCH_ROOT:-${TMPDIR:-${XDG_CACHE_HOME:-$HOME/.cache}/weave/scratch}}"
    minimum="${WV_SCRATCH_MIN_KB:-1048576}"
    case "$minimum" in
        ''|*[!0-9]*) echo "Weave scratch: WV_SCRATCH_MIN_KB must be a nonnegative integer" >&2; return 1 ;;
    esac
    mkdir -p -- "$root" || return 1
    root=$(cd -- "$root" && pwd -P) || return 1
    available=$(set -o pipefail; LC_ALL=C df -Pk "$root" | awk 'NR == 2 {print $4}') || {
        echo "Weave scratch: cannot inspect filesystem capacity at $root" >&2
        return 1
    }
    case "$available" in
        ''|*[!0-9]*) echo "Weave scratch: cannot inspect filesystem capacity at $root" >&2; return 1 ;;
    esac
    echo "Weave scratch: root=$root available_kib=$available minimum_kib=$minimum (preflight, not a reservation)" >&2
    if ! [ "$available" -ge "$minimum" ]; then
        echo "Weave scratch: insufficient capacity before expensive work; set WV_SCRATCH_ROOT to a filesystem with more space" >&2
        return 1
    fi
    mktemp -d "$root/wv-scratch.XXXXXX"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    wv_scratch_create
fi
