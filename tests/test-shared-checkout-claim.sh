#!/usr/bin/env bash
# test-shared-checkout-claim.sh — one claimed session per checkout (wv-1da341,
# owner ruling 2026-11-11 on wv-24ab9d).
#
# Two sessions that each hold a claim in one checkout can overwrite each other's
# uncommitted edits: the edit guard checks the claim, not whose change a file
# holds. wv work and wv add --status=active refuse a new claim while another
# live agent session in the checkout holds one. Each condition alone admits: a
# crashed peer's claim, a claimless live peer, a claim synced from another host,
# and a peer in a linked worktree (its own hot zone and graph).
#
# The peer is a renamed sleep (comm "codex") with its cwd in the checkout, as in
# tests/test-concurrent-session.sh; identities are pinned with WV_AGENT_ID.
set -uo pipefail
export WV_CALL_SOURCE=test
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WV="$ROOT/scripts/wv"
# shellcheck source=tests/lib/fake-agent-bin.sh
source "$ROOT/tests/lib/fake-agent-bin.sh"
run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }

if [ ! -d /proc ]; then
    echo "SKIP: /proc not available (Linux-only detector)"
    echo "Results: 0/0 passed"; exit 0
fi

T=$(mktemp -d /tmp/wv-shared-checkout-XXXXXX)
PEER_PID=""
stop_peer() { [ -z "$PEER_PID" ] || { kill "$PEER_PID" 2>/dev/null; wait "$PEER_PID" 2>/dev/null; }; PEER_PID=""; }
trap 'stop_peer; rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/cfg"
fake_agent_bin "$T/bin/codex"
unset WV_HOT_ZONE WV_DB WV_SESSION_ID GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
export WV_CONFIG_DIR="$T/cfg" WV_AUTO_SYNC=0 WV_AUTO_CHECKPOINT=0 WV_REQUIRE_LEARNING=0 WV_RUN_CACHE=0
HU="$(hostname)-$(whoami)"
ME="claude-$HU-h1111111111111111"
PEER="codex-$HU-h2222222222222222"

REPO="$T/repo"
git init -q -b main "$REPO"
git -C "$REPO" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false commit -q --allow-empty -m base
cd "$REPO" || exit 1
export WV_PROJECT_DIR="$REPO" WV_HOT_ZONE="$T/hot" WV_DB="$T/hot/brain.db"
"$WV" init >/dev/null 2>&1
mine=$("$WV" add "mine" --force 2>/dev/null | tail -1)
peer_node=$("$WV" add "peer work" --force 2>/dev/null | tail -1)
target=$("$WV" add "target" --force 2>/dev/null | tail -1)
[[ "$target" =~ ^wv-[0-9a-f]{6}$ ]] || { echo "  ✗ fixture: nodes were not created ($target)"; exit 1; }
WV_AGENT_ID="$PEER" "$WV" work "$peer_node" >/dev/null 2>&1
WV_AGENT_ID="$ME" "$WV" work "$mine" >/dev/null 2>&1   # before any live peer
check "fixture: the peer holds its claim" \
    "$("$WV" show "$peer_node" --json 2>/dev/null | jq -r '.metadata | (if type=="string" then fromjson else . end) | .claimed_by')" "$PEER"

start_peer() { (cd "$1" && exec "$T/bin/codex" 300) & PEER_PID=$!; sleep 0.3; }
claim() { WV_AGENT_ID="$ME" "$WV" work "$1" 2>&1; }
holder() { "$WV" show "$1" --json 2>/dev/null | jq -r '.metadata | (if type=="string" then fromjson else . end) | .claimed_by // ""'; }

echo "=== a live peer with a claim in this checkout ==="
start_peer "$REPO"
out=$(claim "$target"); rc=$?
check "wv work is refused" "$rc" "1"
check "the refusal names the peer's claim" "$(grep -cF -- "claimed: $peer_node ($PEER)" <<< "$out")" "1"
check "and gives the worktree command" "$(grep -c 'git worktree add -b' <<< "$out")" "1"
check "the node stays unclaimed" "$(holder "$target")" ""
before=$("$WV" list --json 2>/dev/null | jq length)
WV_AGENT_ID="$ME" "$WV" add "new active work" --status=active --force >/dev/null 2>&1; rc=$?
check "wv add --status=active is refused" "$rc" "1"
check "and creates no node" "$("$WV" list --json 2>/dev/null | jq length)" "$before"
check "a node this session already holds is not refused" "$(claim "$mine" >/dev/null; echo $?)" "0"

echo "=== each condition alone admits ==="
stop_peer
check "a crashed peer (claim, no process): admitted" "$(claim "$target" >/dev/null; echo $?)" "0"
"$WV" update "$target" --status=todo >/dev/null 2>&1
"$WV" update "$target" --remove-key=claimed_by >/dev/null 2>&1
start_peer "$REPO"
WV_AGENT_ID="$PEER" "$WV" update "$peer_node" --status=todo >/dev/null 2>&1
"$WV" update "$peer_node" --remove-key=claimed_by >/dev/null 2>&1
check "a live peer with no claim: admitted" "$(claim "$target" >/dev/null; echo $?)" "0"
"$WV" update "$target" --status=todo >/dev/null 2>&1
"$WV" update "$target" --remove-key=claimed_by >/dev/null 2>&1
WV_AGENT_ID="codex-otherhost-$(whoami)-h3333333333333333" "$WV" work "$peer_node" >/dev/null 2>&1
check "a claim synced from another host: admitted" "$(claim "$target" >/dev/null; echo $?)" "0"
stop_peer

echo "=== a peer in a linked worktree ==="
"$WV" update "$target" --status=todo >/dev/null 2>&1
"$WV" update "$target" --remove-key=claimed_by >/dev/null 2>&1
for wt in "$T/repo-wt" "$REPO/.worktrees/peer"; do
    git -C "$REPO" worktree add -q -b "peer-$RANDOM" "$wt" HEAD 2>/dev/null
    # Its own exported zone, as a worktree session has: a bare assignment after
    # unset is not exported, and wv then placed the zone live (wv-e200f6).
    ( cd "$wt" && unset WV_DB && export WV_PROJECT_DIR="$wt" WV_HOT_ZONE="$T/hot-$RANDOM" \
        && "$WV" init >/dev/null 2>&1 \
        && wt_node=$("$WV" add "wt work" --force 2>/dev/null | tail -1) \
        && WV_AGENT_ID="$PEER" "$WV" work "$wt_node" >/dev/null 2>&1 )
    start_peer "$wt"
    check "a claimed live peer in a linked worktree (${wt#"$T"/}): admitted" "$(claim "$target" >/dev/null; echo $?)" "0"
    stop_peer
    "$WV" update "$target" --status=todo >/dev/null 2>&1
    "$WV" update "$target" --remove-key=claimed_by >/dev/null 2>&1
done

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
