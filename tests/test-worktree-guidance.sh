#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# A linked worktree keeps its own graph (owner decision wv-d88fed). The two
# refusals an agent meets there say so and name the main checkout (wv-ca1f94):
# wv's refusal of a foreign hot-zone override, and the agent edit guard with no
# active node. An unrelated repository's refusal is unchanged.
set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WV="$ROOT/scripts/wv"
run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
has() { if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1" "missing [$3] in: $(tr '\n' ' ' <<< "$2" | cut -c1-300)"; fi; }
lacks() { if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1" "unexpected [$3]"; fi; }
TMP=$(mktemp -d /tmp/wv-worktree-guidance-XXXXXX)
trap 'git -C "$TMP/main" worktree prune >/dev/null 2>&1; rm -rf "$TMP"' EXIT

repo() {
    mkdir -p "$1"
    git -C "$1" init -q . && git -C "$1" config user.email t@t && git -C "$1" config user.name t
    git -C "$1" -c core.hooksPath=/dev/null commit -q --allow-empty -m init
}
M="$TMP/main"; repo "$M"
mkdir -p "$TMP/cfg"
(cd "$M" && WEAVE_DIR="$M/.weave" WV_HOT_ZONE="$TMP/hot-main" WV_CONFIG_DIR="$TMP/cfg" "$WV" init) </dev/null >/dev/null 2>&1
[ -f "$TMP/hot-main/.repo_root" ] && ok "the main checkout's zone records its owner" || bad "the main checkout's zone records its owner"
W="$TMP/wt"; git -C "$M" worktree add -q "$W" -b side >/dev/null 2>&1
U="$TMP/other"; repo "$U"
main_real=$(cd "$M" && pwd -P)

echo "=== wv refuses the main checkout's zone, and says why ==="
out=$(cd "$W" && WV_HOT_ZONE="$TMP/hot-main" WV_CONFIG_DIR="$TMP/cfg" "$WV" status 2>&1 </dev/null); rc=$?
[ "$rc" -ne 0 ] && ok "a linked worktree is refused the main checkout's zone" || bad "a linked worktree is refused the main checkout's zone" "rc=$rc"
has "the refusal names it a linked worktree of the main checkout" "$out" "linked worktree of $main_real"
has "and tells the agent to load and claim in the worktree" "$out" "wv load, then wv work <id>"
out=$(cd "$U" && WV_HOT_ZONE="$TMP/hot-main" WV_CONFIG_DIR="$TMP/cfg" "$WV" status 2>&1 </dev/null); rc=$?
[ "$rc" -ne 0 ] && ok "an unrelated repository is refused too" || bad "an unrelated repository is refused too" "rc=$rc"
lacks "its refusal carries no worktree note" "$out" "linked worktree"
has "and keeps the plain advice" "$out" "unset WV_HOT_ZONE WV_DB to use this repository's graph"

echo "=== the edit guard says the same with no active node ==="
guard() {  # guard <dir> — run the edit guard's active-node check there
    (cd "$1" && WV_HOT_ZONE="$2" WV_CONFIG_DIR="$TMP/cfg" WEAVE_DIR="$1/.weave" WV="$WV" bash -c '
        . "$0/scripts/lib/wv-hook-common.sh" >/dev/null 2>&1
        _hc_check_active_node' "$ROOT" 2>&1 </dev/null)
}
(cd "$W" && WEAVE_DIR="$W/.weave" WV_HOT_ZONE="$TMP/hot-wt" WV_CONFIG_DIR="$TMP/cfg" "$WV" init) </dev/null >/dev/null 2>&1
out=$(guard "$W" "$TMP/hot-wt")
has "in a linked worktree the guard blocks with no active node" "$out" "No active Weave node found"
has "and says the worktree keeps its own graph" "$out" "This is a linked worktree of $main_real"
out=$(guard "$M" "$TMP/hot-main")
has "in the main checkout the guard blocks too" "$out" "No active Weave node found"
lacks "with no worktree note" "$out" "linked worktree"

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
