#!/usr/bin/env bash
# Weave reference-transaction hook: publish only the tree the pre-commit gate
# judged (R1, wv-5f9d1c, epic wv-d67163).
#
# A plain `git commit` holds no lock on the index while its pre-commit hook
# runs, and reads the index again after the hook returns. A file staged in that
# window -- after the gate's last comparison, while it records its result --
# was committed without being judged. No check inside pre-commit can close it,
# because git reads the index after the hook has exited.
#
# git runs this hook for every reference update, with the state ("prepared",
# "committed" or "aborted") as $1 and "<old> <new> <ref>" lines on stdin. In
# "prepared" the commit object already exists and nothing has moved, so its
# tree can be compared with what the gate judged, and a non-zero exit aborts the
# update: git commit then fails and HEAD stays where it was.
#
# The pre-commit gate leaves its record for the git process that ran it, as
# <git-path weave-gate>/admitted-<pid>, holding the judged tree and that
# process's start time. Only that process's transactions are checked: any other
# ref update (fetch, checkout, branch, rebase, a suite's own repositories) finds
# no record and passes. A record whose start time does not match belongs to an
# earlier process with the same pid and is dropped. Hooks can be bypassed
# (--no-verify, core.hooksPath); this binds the gate's own admission, nothing
# more.

state=${1:-}
dir=$(git rev-parse --git-path weave-gate 2>/dev/null) || dir=""
rec="$dir/admitted-$PPID"
if [ -z "$dir" ] || [ ! -f "$rec" ]; then
    cat >/dev/null
    exit 0
fi
input=$(cat)
judged=$(sed -n 's/^tree=//p' "$rec" 2>/dev/null)
started=$(sed -n 's/^start=//p' "$rec" 2>/dev/null)
now=$(ps -o lstart= -p "$PPID" 2>/dev/null | sed 's/^ *//; s/ *$//')
if [ -z "$started" ] || [ "$started" != "$now" ]; then
    # Another process once had this pid: not this commit's record.
    rm -f "$rec"
    exit 0
fi

published=false
while read -r _old new _ref; do
    case "$new" in
        ''|0000000000000000000000000000000000000000|ref:*) continue ;;
    esac
    [ "$(git cat-file -t "$new" 2>/dev/null)" = commit ] || continue
    published=true
    [ "$state" = prepared ] || continue
    tree=$(git rev-parse --verify --quiet "${new}^{tree}" 2>/dev/null) || tree=""
    if [ -z "$judged" ] || [ "$tree" != "$judged" ]; then
        echo "✗ Weave: the commit's tree (${tree:-unreadable}) is not the tree the pre-commit gate judged (${judged:-none recorded}): the index changed after the gate admitted it. Nothing was committed; re-run the commit." >&2
        exit 1
    fi
done <<< "$input"

# The transaction that published (or failed to publish) the commit ends the
# record; others in the same process (AUTO_MERGE and the like) leave it.
if [ "$state" != prepared ] && [ "$published" = true ]; then
    rm -f "$rec"
fi
exit 0
