#!/usr/bin/env bash
# test-graph-persistence-ux.sh -- a graph write publishes only its delta, a
# branch switch is not refused over graph state, and concurrent trails notes
# merge (wv-8595fb).
#
# Owner ruling 2026-11-13: a write publishes its delta; the tracked
# state.sql, nodes.jsonl and edges.jsonl are rewritten by wv sync, a
# checkpoint or a load; a delta written on one branch replays on another after
# a switch; .weave/trails.md merges with the union of both sides' notes.
#
# Durability is checked, not assumed: the hot zone is thrown away and the graph
# is rebuilt from .weave/ alone.
#
# GIT_* is unset first: an exported GIT_DIR would point the scratch
# repositories at the real one (wv-8f1da6). The merge driver is configured for
# the one git call through GIT_CONFIG_*, never in a repository's config.

set -u
while IFS= read -r _v; do unset "$_v"; done < <(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p')
export WV_TEST_SUITE=1
export WV_CALL_SOURCE=test

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$REPO_ROOT/scripts/wv"
DRIVER="$REPO_ROOT/scripts/merge-trails.py"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export WV_CONFIG_DIR="$T/cfg" WV_AGENT_ID="persist-test" WV_REQUIRE_LEARNING=0
export WV_AUTO_CHECKPOINT=0 WV_NONINTERACTIVE=1 WV_LIB_DIR="$REPO_ROOT/scripts"
mkdir -p "$WV_CONFIG_DIR"

pass=0; run=0
ok()  { echo "  ✓ $1"; pass=$((pass + 1)); run=$((run + 1)); }
bad() { echo "  ✗ $1"; [ -z "${2:-}" ] || echo "$2" | sed 's/^/      /'; run=$((run + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected: $2"$'\n'"actual:   $3"; fi; }

R="$T/repo"; HZ="$T/hz"
mkdir -p "$R" "$HZ"; chmod 700 "$HZ"
export WV_PROJECT_DIR="$R" WEAVE_DIR="$R/.weave" WV_HOT_ZONE="$HZ"
cd "$R" || exit 1
git init -q -b main && git config user.email t@t && git config user.name t && git config commit.gpgsign false
gc() { git -c core.hooksPath=/dev/null "$@"; }
texts() { "$WV" list --all --json 2>/dev/null | jq -r '[.[].text] | sort | join(",")'; }
tracked_dirt() { git status --porcelain -- .weave/state.sql .weave/nodes.jsonl .weave/edges.jsonl; }
add() { "$WV" add "$1" --force --criteria=c --risks=low "${@:2}" 2>&1 | sed -nE 's/^✓ (wv-[a-f0-9]{6}): .*/\1/p' | head -1; }

echo "=== a new graph's first write carries its base ==="
"$WV" init >/dev/null 2>&1
SEED=$(add seed)
check "the first write wrote state.sql" yes "$([ -s .weave/state.sql ] && echo yes || echo no)"
gc add -A && gc commit -qm init
gc branch side
gc checkout -q side
add sidework >/dev/null
gc add -A && gc commit -qm side
gc checkout -q main

echo "=== writes publish deltas only ==="
before=$(( $(find .weave/deltas -name '*.sql' | wc -l) ))
ONE=$(add one)
"$WV" work "$ONE" >/dev/null 2>&1
"$WV" update "$ONE" --text="one, edited" >/dev/null 2>&1
"$WV" link "$ONE" "$SEED" --type=relates_to >/dev/null 2>&1
after=$(( $(find .weave/deltas -name '*.sql' | wc -l) ))
check "add, work, update and link leave no tracked graph file dirty" "" "$(tracked_dirt)"
check "each write published a delta" yes "$([ "$after" -gt "$before" ] && echo yes || echo no)"

echo "=== a branch switch keeps the graph ==="
out=$(gc checkout side 2>&1); rc=$?
check "checkout to a branch with other graph commits is not refused" 0 "$rc"
[ "$rc" -eq 0 ] || echo "$out" | sed 's/^/      /'
check "the live graph keeps both branches' work" "one, edited,seed,sidework" "$(texts)"
"$WV" load >/dev/null 2>&1
check "a load rewrites the bundle from the live graph" yes "$(grep -q "one, edited" .weave/state.sql && echo yes || echo no)"
gc checkout -q -- .weave/state.sql .weave/nodes.jsonl .weave/edges.jsonl
rm -rf "$HZ"; mkdir -p "$HZ"; chmod 700 "$HZ"
"$WV" load >/dev/null 2>&1
check "a reload from the other branch's files replays the uncommitted deltas" "one, edited,seed,sidework" "$(texts)"
gc checkout -q -- .weave/state.sql .weave/nodes.jsonl .weave/edges.jsonl
gc checkout -q main

echo "=== crash recovery from .weave/ alone ==="
TWO=$(add two)
"$WV" "done" "$TWO" >/dev/null 2>&1
check "still no tracked dirt before any sync" "" "$(tracked_dirt)"
rm -rf "$HZ"; mkdir -p "$HZ"; chmod 700 "$HZ"
"$WV" load >/dev/null 2>&1
check "a lost hot zone rebuilds every write from state.sql and the deltas" \
    "one, edited,seed,two" "$(texts)"
check "the closed node is still closed" "done" "$("$WV" show "$TWO" --json 2>/dev/null | jq -r .status)"
check "the edge survives" 1 "$("$WV" edges "$ONE" --json 2>/dev/null | jq '[.. | objects | select(.type? == "relates_to")] | length' 2>/dev/null || echo 0)"

echo "=== wv sync and the checkpoint rewrite the bundle ==="
gc add -A && gc commit -qm resync
THREE=$(add three)
check "a write after the commit leaves the bundle alone" "" "$(tracked_dirt)"
"$WV" sync >/dev/null 2>&1
check "wv sync rewrote state.sql" yes "$(grep -q "'three'" .weave/state.sql && echo yes || echo no)"
gc add -A && gc commit -qm sync
FOUR=$(WV_AUTO_CHECKPOINT=1 WV_CHECKPOINT_INTERVAL=0 add four)
check "the checkpoint committed a fresh bundle" yes \
    "$(git show HEAD:.weave/state.sql | grep -q "'four'" && echo yes || echo no)"
check "the checkpoint commit carries the delta too" yes \
    "$(git show --name-only --format= HEAD | grep -q '^.weave/deltas/' && echo yes || echo no)"
check "nothing is left dirty after the checkpoint" "" "$(tracked_dirt)"
: "$THREE" "$FOUR"

echo "=== trails notes merge ==="
"$WV" trails save --message="base note" >/dev/null 2>&1
gc add -A && gc commit -qm trails
gc checkout -q -b notes-a
"$WV" trails save --message="note from a" >/dev/null 2>&1
gc add .weave/trails.md && gc commit -qm a
gc checkout -q main
"$WV" trails save --message="note from main" >/dev/null 2>&1
gc add .weave/trails.md && gc commit -qm main
cat > "$T/attr" <<'EOF'
.weave/trails.md merge=wv-trails
EOF
mg() {
    git -c core.hooksPath=/dev/null -c core.attributesFile="$T/attr" \
        -c merge.wv-trails.driver="python3 '$1' %O %A %B" merge -q --no-edit notes-a >/dev/null 2>&1
}
mg "$DRIVER"; rc=$?
check "a concurrent trails note merges without a conflict" 0 "$rc"
notes=$(grep -c '^<!-- wv-note -->$' .weave/trails.md)
check "both sides' notes and the base note are kept" 3 "$notes"
check "the newest note comes first" yes \
    "$(awk '/^### /{print; exit}' .weave/trails.md | grep -q . && \
       [ "$(grep -n 'note from main' .weave/trails.md | cut -d: -f1)" -lt "$(grep -n 'note from a$' .weave/trails.md | cut -d: -f1)" ] && echo yes || echo no)"
"$WV" trails save --message="after the merge" >/dev/null 2>&1
check "the next save keeps the merged notes" 4 "$(grep -c '^<!-- wv-note -->$' .weave/trails.md)"
gc reset -q --hard HEAD~1
printf '#!/bin/sh\nexit 1\n' > "$T/fail.sh"
mg "$T/fail.sh"; rc=$?
check "a driver that cannot merge leaves a conflict, not a silent pick" 1 "$rc"
gc merge --abort >/dev/null 2>&1

echo "=== the driver refuses what it cannot read ==="
printf 'not a trails file\n' > "$T/x"; cp .weave/trails.md "$T/y"; cp "$T/y" "$T/y0"
python3 -I "$DRIVER" "$T/y" "$T/y" "$T/x" >/dev/null 2>&1; rc=$?
check "an unreadable side exits 1" 1 "$rc"
check "and leaves ours untouched" yes "$(cmp -s "$T/y" "$T/y0" && echo yes || echo no)"

echo ""
echo "graph persistence: $pass/$run passed"
[ "$pass" -eq "$run" ]
