#!/usr/bin/env bash
# wv-gate-snapshot.sh — the frozen candidate the pre-commit gate judges
# (wv-8e34cd, epic wv-d67163).
#
# Sourced by: scripts/hooks/pre-commit-weave.sh
#
# The gate judges one transition: from the commit this one follows (the base)
# to the tree git is about to write (the index). Both are recorded once, as
# object ids, before any check runs, and every in-hook check reads them instead
# of the live index, HEAD or the working tree. A plain `git commit` holds no
# lock on the index while the hook runs and re-reads it afterwards, so a file
# another process staged mid-gate was committed without being judged; the
# admission check at the end refuses that.
#
#   gate_freeze               record WV_GATE_TREE and WV_GATE_BASE (exported)
#   gate_side_tree <side>     the tree of a side: base | index | auth, the
#                             tree the gate's code and role contract come
#                             from: a recovery run's execution tree
#                             (_PC_EXEC_TREE, S2c wv-0af8f0), else base.
#                             History is always base.
#   gate_blob <side> <path>   the blob id at <path>; 1 when the side has none
#   gate_show <side> <path>   the blob's bytes; 1 when the side has none
#   gate_changed <filter>     NUL-separated paths that differ base -> index
#   gate_ls <side> <path>...  NUL-separated blob paths under <path>s
#   gate_materialise <side> <dir> <path>...
#                             write the side's bytes of each path under <dir>
#   gate_frozen_intact        the index and HEAD are still what was frozen
#
# Every function returns nonzero on an error, distinct from "absent" where the
# caller must tell them apart (gate_blob, gate_show: 1 absent, 2 error,
# 3 not a regular file).

# The tree of an unborn branch's base: git's well-known empty tree, computed
# rather than written down.
_gate_empty_tree() {
    git hash-object -t tree /dev/null
}

# write-tree updates its index cache and requires an exclusive lock even for
# a reader. Observe the caller's index through an invocation-owned copy.
_gate_index_tree() {
    local index parent work rc=0
    index=$(git rev-parse --git-path index) || return 1
    parent=$(dirname "$index")
    [ -d "$parent" ] && [ -x "$parent" ] || return 1
    work=$(mktemp -d "${TMPDIR:-/tmp}/wv-gate-read-index.XXXXXX") || return 1
    if [ -f "$index" ]; then
        cp -- "$index" "$work/index" || rc=1
    elif [ -e "$index" ] || [ -L "$index" ]; then
        rc=1
    fi
    if [ "$rc" = 0 ]; then
        GIT_INDEX_FILE="$work/index" git write-tree || rc=$?
    fi
    rm -rf "$work"
    return "$rc"
}

# gate_freeze — the index as a tree, and HEAD's commit. git write-tree honours
# GIT_INDEX_FILE, which `git commit -a` and pathspec commits point at the index
# they will commit. On an unborn branch WV_GATE_BASE is unset, and a detached
# HEAD that does not resolve is an error. A branch ref that exists but is broken
# reads as unborn too (show-ref and for-each-ref answer it as they answer a
# missing one); git then refuses the commit itself, being unable to lock it.
gate_freeze() {
    local tree base
    tree=$(_gate_index_tree) && [ -n "$tree" ] || return 1
    if base=$(git rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null) && [ -n "$base" ]; then
        export WV_GATE_BASE="$base"
    else
        git symbolic-ref --quiet HEAD >/dev/null 2>&1 || return 1
        unset WV_GATE_BASE
    fi
    export WV_GATE_TREE="$tree"
}

gate_side_tree() {
    [ -n "${WV_GATE_TREE:-}" ] || return 1
    case "$1" in
        index) git rev-parse --verify --quiet "${WV_GATE_TREE}^{tree}" 2>/dev/null || return 1 ;;
        base)
            if [ -n "${WV_GATE_BASE:-}" ]; then
                git rev-parse --verify --quiet "${WV_GATE_BASE}^{tree}" 2>/dev/null || return 1
            else
                _gate_empty_tree
            fi ;;
        auth)
            if [ -n "${_PC_EXEC_TREE:-}" ]; then
                git rev-parse --verify --quiet "${_PC_EXEC_TREE}^{tree}" 2>/dev/null || return 1
            else
                gate_side_tree base
            fi ;;
        *) return 1 ;;
    esac
}

# gate_blob <side> <path> — ls-tree takes the path literally (no globbing) and
# answers an absent path with no output, so absence and failure stay apart. A
# directory or a submodule at <path> is not a blob: absent. A symbolic link is
# a blob holding a pathname, never the target's bytes, and the gate does not
# follow links: it is refused as non-regular (3), so a linked policy file cannot
# read as an empty one (R4, wv-77b743). (`local -` scopes pipefail to this
# function.)
gate_blob() {
    local - tree entry meta
    set -o pipefail
    tree=$(gate_side_tree "$1") || return 2
    # -z: without it ls-tree quotes an unusual path, which then never matches.
    entry=$(git ls-tree -z --full-tree "$tree" -- "$2" 2>/dev/null | tr '\0' '\n') || return 2
    [ -n "$entry" ] || return 1
    meta=${entry%%$'\t'*}
    [ "${entry#*$'\t'}" = "$2" ] || return 1
    case "$meta" in
        "100644 blob "* | "100755 blob "*) printf '%s\n' "${meta##* }" ;;
        *" blob "*) return 3 ;;
        *) return 1 ;;
    esac
}

gate_show() {
    local blob rc=0
    blob=$(gate_blob "$1" "$2") || rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    git cat-file blob "$blob" 2>/dev/null || return 2
}

# gate_changed <diff-filter or ''> — plumbing diff-tree never applies rename
# detection, so a move lists its removed path too (wv-29d13c).
gate_changed() {
    local base index
    base=$(gate_side_tree base) && index=$(gate_side_tree index) || return 1
    git diff-tree -r -z --name-only --no-renames ${1:+--diff-filter="$1"} \
        "$base" "$index" 2>/dev/null
}

gate_ls() {
    local tree side=$1
    shift
    tree=$(gate_side_tree "$side") || return 1
    git ls-tree -r -z --name-only --full-tree "$tree" -- "$@" 2>/dev/null
}

# gate_materialise <side> <dir> <path>... — through a private index, so the
# real one is neither read nor written. A path the side does not have fails
# the call: checkout-index reports it and exits nonzero.
gate_materialise() {
    local side=$1 dir=$2 tree idx rc=0
    shift 2
    [ "$#" -gt 0 ] || return 0
    tree=$(gate_side_tree "$side") || return 1
    # An empty <dir> would make the prefix "/".
    [ -n "$dir" ] && [ -d "$dir" ] || return 1
    idx=$(mktemp -d "${TMPDIR:-/tmp}/wv-gate-idx.XXXXXX" 2>/dev/null) && [ -n "$idx" ] || return 1
    if GIT_INDEX_FILE="$idx/index" git read-tree "$tree" 2>/dev/null; then
        printf '%s\0' "$@" | GIT_INDEX_FILE="$idx/index" \
            git checkout-index -f -z --stdin --prefix="$dir/" 2>/dev/null || rc=1
    else
        rc=1
    fi
    rm -rf "$idx"
    return "$rc"
}

# gate_frozen_intact — what git commits next is what the gate judged: the
# index still writes the frozen tree, and HEAD is still the frozen base.
gate_frozen_intact() {
    local now head
    [ -n "${WV_GATE_TREE:-}" ] || return 1
    now=$(_gate_index_tree) && [ "$now" = "$WV_GATE_TREE" ] || return 1
    head=$(git rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null) || head=""
    [ "$head" = "${WV_GATE_BASE:-}" ]
}
