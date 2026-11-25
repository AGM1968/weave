#!/usr/bin/env bash
# dedup_lock_dir <repo-dir> [<session-key>] -- the bash-dedup lock directory a
# hook uses for <repo-dir>, derived the way the hooks derive it
# (scripts/lib/wv-pre-tool-use.sh, wv-session-start.sh): git's toplevel, which
# is a physical path, hashed with echo's newline through the product's
# portable md5sum, then resolve_bash_lock_dir. A fixture that hashed the
# directory as written named a different lock directory wherever the path
# runs through a symlink (macOS /tmp and $TMPDIR are links into /private), so
# its planted lock was never seen (wv-b3cb72). Prints nothing and fails when
# <repo-dir> is not a directory.
_DEDUP_LOCKS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
dedup_lock_dir() {
    local root
    [ -d "$1" ] || return 1
    root=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || root=$(cd "$1" && pwd -P) || return 1
    # shellcheck disable=SC2016  # the child bash expands it
    bash -c '. "$1/scripts/lib/wv-resolve-runtime.sh" || exit 1
        h=$(echo "$2" | md5sum | cut -c1-8)
        if [ -n "$3" ]; then resolve_bash_lock_dir "${h:-default}" "$3"; else resolve_bash_lock_dir "${h:-default}"; fi' \
        _ "$_DEDUP_LOCKS_ROOT" "$root" "${2:-}"
}
