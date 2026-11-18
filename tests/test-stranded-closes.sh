#!/usr/bin/env bash
# test-stranded-closes.sh -- wv doctor names a close older than a day that
# main's committed graph does not hold (wv-4a6d29).
#
# A close lives in the hot zone first and reaches main only through a commit on
# main carrying .weave/. Measured 2026-10-24: wv-43f077 closed on 05-19 and main
# showed it open until 05-22. Each path that keeps a close out is planted here:
# a session that closed and never committed .weave/, a side branch never merged,
# and a linked worktree with its own graph. Closes are aged by setting the node's
# updated_at, since a close is never after its node's last update.
#
# GIT_* is unset first: an exported GIT_DIR would point the scratch
# repositories at the real one (wv-8f1da6).

set -u
while IFS= read -r _v; do unset "$_v"; done < <(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p')
export WV_TEST_SUITE=1
export WV_CALL_SOURCE=test

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$REPO_ROOT/scripts/wv"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export WV_CONFIG_DIR="$T/cfg"
export WV_AGENT_ID="stranded-test"
export WV_REQUIRE_LEARNING=0
export WV_AUTO_CHECKPOINT=0
export WV_NONINTERACTIVE=1
mkdir -p "$WV_CONFIG_DIR"

pass=0; run=0
ok()  { echo "  ✓ $1"; pass=$((pass + 1)); run=$((run + 1)); }
bad() { echo "  ✗ $1"; [ -z "${2:-}" ] || echo "$2" | sed 's/^/      /'; run=$((run + 1)); }

# use <checkout> <hot zone>
use() {
    export WV_PROJECT_DIR="$1" WEAVE_DIR="$1/.weave" WV_HOT_ZONE="$2"
    unset WV_DB
    mkdir -p "$WV_HOT_ZONE"; chmod 700 "$WV_HOT_ZONE"
    cd "$1" || exit 1
}
# --force: the fixture texts are short and alike, and a near-duplicate refusal
# would print the matched node's id instead (wv-1e7e77).
add_node() { "$WV" add "$1" --force --criteria=c --risks=low 2>&1 | sed -nE 's/^✓ (wv-[a-f0-9]{6}): .*/\1/p' | head -1; }
close_node() { "$WV" update "$1" --status=done >/dev/null 2>&1; }
age() { sqlite3 "$WV_HOT_ZONE/brain.db" "UPDATE nodes SET updated_at = datetime('now', '-3 days') WHERE id = '$1';"; }
commit_graph() { "$WV" sync >/dev/null 2>&1; git add -A .weave >/dev/null 2>&1; git -c core.hooksPath=/dev/null commit -qm "$1" >/dev/null 2>&1; }
# The run cache keys on HEAD, not on the hot zone's database, so a doctor run
# after a graph write with no commit would replay the last answer.
line() { WV_RUN_CACHE=0 "$WV" doctor 2>&1 | grep 'stranded closes' | head -1; }
# reports <id> -- the doctor line warns (not ✓) and names <id>
reports() { local l; l=$(line); case "$l" in *"✓"*) ;; *"stranded closes: "*"$1"*) return 0 ;; esac; echo "$l"; return 1; }
clean() { local l; l=$(line); case "$l" in *"✓"*) return 0 ;; esac; echo "$l"; return 1; }
expect() {  # expect <message> <command...>
    local msg="$1" out; shift
    if out=$("$@"); then ok "$msg"; else bad "$msg" "$out"; fi
}

R="$T/repo"; mkdir -p "$R"; use "$R" "$T/hz-main"
git init -q -b main && git config user.email t@t && git config user.name t && git config commit.gpgsign false
"$WV" init >/dev/null 2>&1
A=$(add_node "alpha: committed on main")
B=$(add_node "bravo: session exits uncommitted")
C=$(add_node "charlie: side branch work")
D=$(add_node "delta: linked worktree work")
commit_graph fixture
for _id in "$A" "$B" "$C" "$D"; do
    [[ "$_id" =~ ^wv-[0-9a-f]{6}$ ]] || { echo "fixture: a node was not created"; exit 1; }
done
[ "$(printf '%s\n' "$A" "$B" "$C" "$D" | sort -u | wc -l)" -eq 4 ] || { echo "fixture: node ids repeat"; exit 1; }

echo "--- controls ---"
expect "no close at all: clean" clean
close_node "$A"; age "$A"; commit_graph "close A on main"
expect "an old close main has committed: clean" clean
close_node "$B"
expect "a close under a day old, not yet committed: clean" clean

echo "--- a session that closed and never committed .weave/ ---"
age "$B"
expect "an old close main's commits lack is named" reports "$B"
commit_graph "commit B"
expect "...and committing .weave/ on main clears it" clean

echo "--- a side branch never merged ---"
git checkout -q -b side
close_node "$C"; age "$C"; commit_graph "close C on side"
expect "an old close committed only on a side branch is named" reports "$C"
git checkout -q main && "$WV" load >/dev/null 2>&1
git -c core.hooksPath=/dev/null merge -q --no-edit side >/dev/null 2>&1
"$WV" load >/dev/null 2>&1
# nodes.jsonl merges as ours: the merge brings the close as deltas, and main's
# committed projection shows it once main syncs and commits.
expect "...and still named after the merge alone" reports "$C"
commit_graph "sync after merging side"
expect "...until main syncs and commits .weave/" clean

echo "--- a linked worktree with its own graph ---"
git worktree add -q -b wt "$T/wt" >/dev/null 2>&1
use "$T/wt" "$T/hz-wt"
"$WV" load >/dev/null 2>&1
close_node "$D"; age "$D"; commit_graph "close D in the worktree"
expect "an old close made in a linked worktree is named there" reports "$D"
use "$R" "$T/hz-main"
expect "...while main's own graph, which never closed it, is clean" clean

echo "--- no main to compare ---"
N="$T/trunk"; mkdir -p "$N"; use "$N" "$T/hz-trunk"
git init -q -b trunk && git config user.email t@t && git config user.name t && git config commit.gpgsign false
"$WV" init >/dev/null 2>&1
E=$(add_node "echo: trunk-only repository"); close_node "$E"; age "$E"
expect "a repository with neither main nor master: not reported" clean

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
