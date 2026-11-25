#!/usr/bin/env bash
# sed-inplace.sh -- edit one file in place with GNU or BSD sed (wv-076a98).
#
# `sed -i SCRIPT FILE` is GNU-only: BSD sed takes the argument after -i as the
# backup suffix, so SCRIPT is read as the file and FILE as the script ("invalid
# command code"). Suites source this file and call
#
#     sed_inplace [sed options] SCRIPT... FILE
#
# with exactly one FILE, last. The output goes to a temporary file and is then
# copied over FILE with cat, so FILE keeps its inode and mode (an executable
# fixture stays executable). A failing sed leaves FILE unchanged and returns
# sed's status. The script itself must be POSIX sed: check it with GNU
# `sed --posix`, which refuses GNU extensions (0,/re/ addresses, \n in a
# replacement, one-line a/i/c text).

sed_inplace() {
    if [ "$#" -lt 2 ]; then
        echo "sed_inplace: usage: sed_inplace [sed options] SCRIPT... FILE" >&2
        return 2
    fi
    local file="${!#}" tmp rc=0
    tmp=$(mktemp) || return 1
    sed "${@:1:$#-1}" "$file" > "$tmp" || rc=$?
    if [ "$rc" -eq 0 ]; then
        cat "$tmp" > "$file" || rc=$?
    fi
    rm -f "$tmp"
    return "$rc"
}
