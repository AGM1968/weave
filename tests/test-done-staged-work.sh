#!/usr/bin/env bash
# "done" is an argument to the wv helper below, never the loop keyword.
# shellcheck disable=SC1010
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# wv done refuses while files outside graph state are staged but not committed
# (wv-b026bb). A refused commit leaves its files staged; closing over them left
# the retried commit with no active claim, and only wv work --reopen undid it.
set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
export WV_REQUIRE_LEARNING=0 WV_REQUIRE_QUALITY=0 WV_AUTO_CHECKPOINT=0 WV_RUN_CACHE=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WV="$ROOT/scripts/wv"
run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }
has() { if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1" "missing [$3] in: $2"; fi; }
TMP=$(mktemp -d /tmp/wv-done-staged-XXXXXX)
trap 'rm -rf "$TMP"' EXIT

R="$TMP/repo"; mkdir -p "$R" "$TMP/cfg"
git -C "$R" init -q . && git -C "$R" config user.email t@t && git -C "$R" config user.name t
git -C "$R" config commit.gpgsign false
w() { (cd "$R" && WEAVE_DIR="$R/.weave" WV_HOT_ZONE="$TMP/hot" WV_CONFIG_DIR="$TMP/cfg" "$WV" "$@") </dev/null; }
add() { w add "$@" --standalone 2>/dev/null | grep -oE 'wv-[a-f0-9]{6}' | sed -n 1p; }
state() { w show "$1" --json 2>/dev/null | jq -r '.status'; }
commit() { git -C "$R" -c core.hooksPath=/dev/null commit -qm "$1" >/dev/null 2>&1; }
w init >/dev/null 2>&1
echo base > "$R/base.txt"; git -C "$R" add base.txt; commit base

echo "=== staged work: the close is refused and the node stays active ==="
node=$(add "work whose commit was refused"); w work "$node" >/dev/null 2>&1
echo change > "$R/work.txt"; git -C "$R" add work.txt
rc=0; out=$(w done "$node" --skip-verification --no-warn 2>&1) || rc=$?
check "wv done exits nonzero over staged work" "$rc" "1"
check "the node stays active" "$(state "$node")" "active"
has "the refusal names the staged file" "$out" "work.txt"
has "the refusal names --force" "$out" "wv done $node --force"
has "the refusal names --reopen for the reverse case" "$out" "wv work <id> --reopen"

echo "=== once committed, the same close succeeds ==="
commit work
rc=0; w done "$node" --skip-verification --no-warn >/dev/null 2>&1 || rc=$?
check "wv done closes after the commit" "$rc" "0"
check "the node is done" "$(state "$node")" "done"

echo "=== graph state alone does not block ==="
graph=$(add "only graph state staged"); w work "$graph" >/dev/null 2>&1
w sync >/dev/null 2>&1; git -C "$R" add -f .weave/nodes.jsonl
rc=0; w done "$graph" --skip-verification --no-warn >/dev/null 2>&1 || rc=$?
check "staged .weave/nodes.jsonl is not caller work" "$rc" "0"
check "the node is done" "$(state "$graph")" "done"
commit graph

echo "=== --force closes anyway ==="
forced=$(add "closed over staged work on purpose"); w work "$forced" >/dev/null 2>&1
echo other > "$R/other.txt"; git -C "$R" add other.txt
rc=0; w done "$forced" --skip-verification --no-warn --force >/dev/null 2>&1 || rc=$?
check "wv done --force closes over staged work" "$rc" "0"
check "the node is done" "$(state "$forced")" "done"
check "the staged file is left staged" "$(git -C "$R" diff --cached --name-only -- other.txt)" "other.txt"

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
