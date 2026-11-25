#!/usr/bin/env bash
# copy_tracked <repo> <dest> -- copy the repo's tracked files, as they are in
# the working tree, into <dest>. A tracked file deleted in the working tree is
# skipped (what GNU tar's --ignore-failed-read did); any other read or write
# failure fails the copy. bsdtar (macOS) has no --ignore-failed-read: with it the
# create step failed silently and the extract got an empty stream (wv-f8e26d).
copy_tracked() {
    local src="$1" dest="$2"
    [ -d "$src" ] && [ -d "$dest" ] || return 1
    dest=$(cd "$dest" && pwd) || return 1
    (
        set -o pipefail
        cd "$src" || exit 1
        # shellcheck disable=SC2016  # expanded by the inner shell
        git ls-files -z \
            | xargs -0 sh -c 'for f; do if [ -e "$f" ] || [ -L "$f" ]; then printf "%s\0" "$f"; fi; done' _ \
            | tar --null -T - -cf - \
            | tar -x -C "$dest"
    )
}
