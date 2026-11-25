#!/usr/bin/env bash
# wv-test-ratchet.sh — advisory count of net test lines per commit (wv-1163f5).
#
# Test code grew from 37.6k to 104.7k lines between June and November 2026,
# 3.2 lines added for each removed (guidance doc rec 2, gap 2). This reports the
# staged commit's net test lines on every commit that touches tests and flags a
# commit over the budget, asking for a one-line justification on its node. It
# never refuses: the binding is advisory (policy rule test_line_ratchet_advisory)
# and moves to enforced only by owner ruling after a month of data, which git
# history can recompute at any time, so nothing is logged here.
#
# A test path is anything under tests/, a test_* file, or a *.test.ts file. A
# rename counts only the lines its content changed (git diff -M), so moving a
# suite is not growth. Binary files count nothing.

# wv_test_line_count — "<added> <deleted> <files>" over the staged test paths.
wv_test_line_count() {
    local added=0 deleted=0 files=0 a d path
    while IFS=$'\t' read -r -d '' a d path; do
        # A rename's numstat record leaves the path empty and is followed by
        # the old and the new path, each NUL-terminated; the new path decides.
        if [ -z "$path" ]; then
            IFS= read -r -d '' path || break
            IFS= read -r -d '' path || break
        fi
        case "$path" in
            tests/* | test_* | */test_* | *.test.ts) ;;
            *) continue ;;
        esac
        files=$((files + 1))
        [ "$a" = "-" ] && continue
        added=$((added + a))
        deleted=$((deleted + d))
    done < <(git diff --cached --numstat -M -z 2>/dev/null)
    echo "$added $deleted $files"
}

# wv_test_line_advisory — print the advisory for the staged commit to stdout.
# Prints nothing when the commit touches no test path. Always returns 0.
wv_test_line_advisory() {
    local budget="${WV_GATE_TEST_LINE_BUDGET:-150}" added deleted files net
    case "$budget" in '' | *[!0-9]*) budget=150 ;; esac
    read -r added deleted files < <(wv_test_line_count)
    [ "${files:-0}" -gt 0 ] || return 0
    net=$((added - deleted))
    echo "Weave pre-commit: test lines in this commit: +$added -$deleted over $files file(s), net $net (advisory budget +$budget, wv-1163f5)"
    if [ "$net" -gt "$budget" ]; then
        echo "⚠ net test lines are over the advisory budget; this commit is not refused. Record one line on why on its node:"
        echo "    wv update <node> --metadata='{\"test_lines_justification\":\"<why these tests are needed>\"}'"
    fi
    return 0
}
