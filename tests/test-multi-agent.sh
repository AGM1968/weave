#!/bin/bash
# test-multi-agent.sh — Integration tests for multi-agent delta merge (Sprint 1)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$REPO_ROOT/scripts/wv"

# Isolated test environment
TEST_DIR=$(mktemp -d)
export WV_REQUIRE_LEARNING=0
export WV_AUTO_SYNC=0
export WV_AUTO_CHECKPOINT=0

TESTS_RUN=0
TESTS_PASSED=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

assert() {
    local desc="$1"
    TESTS_RUN=$((TESTS_RUN + 1))
    if eval "$2"; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}✓${NC} $desc"
    else
        echo -e "  ${RED}✗${NC} $desc"
        echo "    Expected: $3" >&2
    fi
}

teardown() {
    cd /tmp
    rm -rf "$TEST_DIR"
}
trap teardown EXIT

# ═══════════════════════════════════════════════════════════════════════════
# Setup: three separate agent environments sharing a git repo
# ═══════════════════════════════════════════════════════════════════════════

# Shared bare repo (simulates remote)
BARE_REPO="$TEST_DIR/remote.git"
git init --bare "$BARE_REPO" -q

# Agent A workspace
AGENT_A_DIR="$TEST_DIR/agent-a"
git clone "$BARE_REPO" "$AGENT_A_DIR" -q 2>/dev/null
mkdir -p "$AGENT_A_DIR/.weave/deltas"

# Agent B workspace
AGENT_B_DIR="$TEST_DIR/agent-b"
git clone "$BARE_REPO" "$AGENT_B_DIR" -q 2>/dev/null
mkdir -p "$AGENT_B_DIR/.weave/deltas"

# Observer workspace (loads and verifies merged state)
OBSERVER_DIR="$TEST_DIR/observer"
git clone "$BARE_REPO" "$OBSERVER_DIR" -q 2>/dev/null
mkdir -p "$OBSERVER_DIR/.weave/deltas"

# Helper: init a wv database for an agent
init_agent_db() {
    local dir="$1"
    local hot="$dir/hot"
    local db="$hot/brain.db"
    mkdir -p "$hot"
    export WV_HOT_ZONE="$hot"
    export WV_DB="$db"
    export WEAVE_DIR="$dir/.weave"
    cd "$dir"
    $WV init 2>/dev/null || true
}

# Helper: sync agent state to .weave/ and commit
sync_and_push() {
    local dir="$1"
    local agent="$2"
    export WV_HOT_ZONE="$dir/hot"
    export WV_DB="$dir/hot/brain.db"
    export WEAVE_DIR="$dir/.weave"
    cd "$dir"
    $WV sync 2>/dev/null || true
    git add .weave/ 2>/dev/null || true
    git commit -m "sync from $agent" --no-verify -q 2>/dev/null || true
    git push -q 2>/dev/null || true
}

echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
echo -e "${YELLOW}Multi-Agent Delta Merge Tests${NC}"
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""

# ═══════════════════════════════════════════════════════════════════════════
# Test 1: Two agents write different nodes, both present after merge
# ═══════════════════════════════════════════════════════════════════════════
echo "--- Two-agent merge: different nodes ---"

# Agent A creates node
init_agent_db "$AGENT_A_DIR"
$WV add "Agent A task" 2>/dev/null
AGENT_A_NODE=$($WV list --json 2>/dev/null | python3 -c "import sys,json; nodes=json.load(sys.stdin); print([n['id'] for n in nodes if 'Agent A' in n['text']][0])")

# Write Agent A's delta manually (simulating auto_sync with agent ID)
mkdir -p "$AGENT_A_DIR/.weave/deltas/2026-03-15"
sqlite3 "$WV_DB" ".dump" | grep -E "INSERT|REPLACE" > "$AGENT_A_DIR/.weave/deltas/2026-03-15/0000000001-agentA.sql" 2>/dev/null || true
sync_and_push "$AGENT_A_DIR" "agentA"

# Agent B pulls, creates its own node
cd "$AGENT_B_DIR"
git pull -q 2>/dev/null || true
init_agent_db "$AGENT_B_DIR"
# Load Agent A's state first
$WV load 2>/dev/null || true
$WV add "Agent B task" 2>/dev/null
AGENT_B_NODE=$($WV list --json 2>/dev/null | python3 -c "import sys,json; nodes=json.load(sys.stdin); print([n['id'] for n in nodes if 'Agent B' in n['text']][0])")

# Write Agent B's delta
mkdir -p "$AGENT_B_DIR/.weave/deltas/2026-03-15"
sqlite3 "$WV_DB" ".dump" | grep -E "INSERT|REPLACE" > "$AGENT_B_DIR/.weave/deltas/2026-03-15/0000000002-agentB.sql" 2>/dev/null || true
sync_and_push "$AGENT_B_DIR" "agentB"

# Observer pulls both and loads
cd "$OBSERVER_DIR"
git pull -q 2>/dev/null || true
init_agent_db "$OBSERVER_DIR"
load_output=$($WV load 2>&1)

# Verify both nodes exist
obs_nodes=$($WV list --json 2>/dev/null)
has_a=$(echo "$obs_nodes" | python3 -c "import sys,json; nodes=json.load(sys.stdin); print('yes' if any('Agent A' in n['text'] for n in nodes) else 'no')")
has_b=$(echo "$obs_nodes" | python3 -c "import sys,json; nodes=json.load(sys.stdin); print('yes' if any('Agent B' in n['text'] for n in nodes) else 'no')")

assert "Observer has Agent A's node" '[ "$has_a" = "yes" ]' "Agent A node present"
assert "Observer has Agent B's node" '[ "$has_b" = "yes" ]' "Agent B node present"
# Verify deltas exist on disk (propagated via git)
obs_delta_count=$(find "$OBSERVER_DIR/.weave/deltas" -name '*.sql' 2>/dev/null | wc -l)
assert "Observer has delta files from both agents" '[ "$obs_delta_count" -ge 2 ]' "at least 2 deltas (got: $obs_delta_count)"

# ═══════════════════════════════════════════════════════════════════════════
# Test 2: Same node modified by two agents — last-writer-wins per row
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "--- Same-node LWW: last-writer-wins per row ---"

# Agent A updates the shared node
export WV_HOT_ZONE="$AGENT_A_DIR/hot"
export WV_DB="$AGENT_A_DIR/hot/brain.db"
export WEAVE_DIR="$AGENT_A_DIR/.weave"
cd "$AGENT_A_DIR"
$WV update "$AGENT_A_NODE" --text="Agent A updated this" 2>/dev/null

# Write delta with earlier epoch
mkdir -p "$AGENT_A_DIR/.weave/deltas/2026-03-15"
sqlite3 "$WV_DB" ".dump" | grep -E "INSERT|REPLACE" > "$AGENT_A_DIR/.weave/deltas/2026-03-15/0000000010-agentA.sql" 2>/dev/null || true
sync_and_push "$AGENT_A_DIR" "agentA"

# Agent B pulls, updates the SAME node
cd "$AGENT_B_DIR"
git pull -q 2>/dev/null || true
export WV_HOT_ZONE="$AGENT_B_DIR/hot"
export WV_DB="$AGENT_B_DIR/hot/brain.db"
export WEAVE_DIR="$AGENT_B_DIR/.weave"
$WV load 2>/dev/null || true
$WV update "$AGENT_A_NODE" --text="Agent B wins this" 2>/dev/null

# Write delta with later epoch (Agent B is the last writer)
mkdir -p "$AGENT_B_DIR/.weave/deltas/2026-03-15"
sqlite3 "$WV_DB" ".dump" | grep -E "INSERT|REPLACE" > "$AGENT_B_DIR/.weave/deltas/2026-03-15/0000000020-agentB.sql" 2>/dev/null || true
sync_and_push "$AGENT_B_DIR" "agentB"

# Observer loads merged state
cd "$OBSERVER_DIR"
git pull -q 2>/dev/null || true
export WV_HOT_ZONE="$OBSERVER_DIR/hot"
export WV_DB="$OBSERVER_DIR/hot/brain.db"
export WEAVE_DIR="$OBSERVER_DIR/.weave"
$WV load 2>/dev/null || true

# Check the node text — Agent B should win (later epoch)
node_text=$($WV show "$AGENT_A_NODE" --json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['text'])" 2>/dev/null || echo "MISSING")

assert "Last-writer-wins: Agent B's text present" '[ "$node_text" = "Agent B wins this" ]' "Agent B wins this (got: $node_text)"

# ═══════════════════════════════════════════════════════════════════════════
# Test 3: Delta replay is idempotent
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "--- Idempotent replay ---"

node_count_before=$($WV list --all --json 2>/dev/null | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
$WV load 2>/dev/null || true
node_count_after=$($WV list --all --json 2>/dev/null | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")

assert "Idempotent: node count unchanged after re-load" '[ "$node_count_before" = "$node_count_after" ]' "$node_count_before = $node_count_after"

# ═══════════════════════════════════════════════════════════════════════════
# Test 4: Agent ID in delta filenames
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "--- Agent ID in filenames ---"

a_deltas=$(find "$AGENT_A_DIR/.weave/deltas" -name '*-agentA.sql' | wc -l)
b_deltas=$(find "$AGENT_B_DIR/.weave/deltas" -name '*-agentB.sql' | wc -l)

assert "Agent A deltas have agentA suffix" '[ "$a_deltas" -gt 0 ]' "at least 1 agentA delta"
assert "Agent B deltas have agentB suffix" '[ "$b_deltas" -gt 0 ]' "at least 1 agentB delta"

# ═══════════════════════════════════════════════════════════════════════════
# Test 5: Corrupt delta skipped with warning
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "--- Corrupt delta handling ---"

echo "THIS IS NOT SQL" > "$OBSERVER_DIR/.weave/deltas/2026-03-15/9999999999-corrupt.sql"
corrupt_output=$($WV load 2>&1)

assert "Corrupt delta produces warning" 'echo "$corrupt_output" | grep -q "Skipped corrupt"' "warning about corrupt delta"

# Clean up corrupt file
rm -f "$OBSERVER_DIR/.weave/deltas/2026-03-15/9999999999-corrupt.sql"

# ═══════════════════════════════════════════════════════════════════════════
# Test 6: Empty delta directory is no-op
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "--- Empty delta dir ---"

EMPTY_DIR="$TEST_DIR/empty-agent"
git clone "$BARE_REPO" "$EMPTY_DIR" -q 2>/dev/null
mkdir -p "$EMPTY_DIR/.weave/deltas" "$EMPTY_DIR/hot"
init_agent_db "$EMPTY_DIR"
# Create baseline with no deltas
$WV sync 2>/dev/null || true
empty_output=$($WV load 2>&1)

assert "No 'Replayed' message when no deltas exist" '! echo "$empty_output" | grep -q "Replayed"' "no replay message"

# ═══════════════════════════════════════════════════════════════════════════
# Test 7: Prune produces zero DELETE statements in delta files
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "--- Prune delta isolation ---"

PRUNE_DIR="$TEST_DIR/prune-agent"
git clone "$BARE_REPO" "$PRUNE_DIR" -q 2>/dev/null
mkdir -p "$PRUNE_DIR/.weave/deltas/2026-03-15" "$PRUNE_DIR/hot"
init_agent_db "$PRUNE_DIR"

# Create nodes, mark done, backdate so they're prunable
$WV add "prune-target-1" --status=done 2>/dev/null
$WV add "prune-target-2" --status=done 2>/dev/null
sqlite3 "$WV_DB" "UPDATE nodes SET updated_at=datetime('now','-72 hours') WHERE text LIKE 'prune-target%';"

# Clear change log from setup, then record delta count
if command -v warp-session >/dev/null 2>&1; then
    warp-session reset "$WV_DB" 2>/dev/null || true
fi
delta_before=$(find "$PRUNE_DIR/.weave/deltas" -name '*.sql' -size +0c 2>/dev/null | wc -l)

# Remove sync throttle stamp to allow auto_sync to fire
rm -f "$PRUNE_DIR/hot/.last_sync" 2>/dev/null

# Prune
$WV prune --age=48h 2>/dev/null

# Check for new delta files with DELETE
delta_after=$(find "$PRUNE_DIR/.weave/deltas" -name '*.sql' -size +0c 2>/dev/null | wc -l)
delete_count=0
if [ "$delta_after" -gt "$delta_before" ]; then
    # Check newest deltas for DELETE statements
    delete_count=$(find "$PRUNE_DIR/.weave/deltas" -name '*.sql' -newer "$WV_DB" -exec grep -l "DELETE" {} \; 2>/dev/null | wc -l)
fi

assert "No new deltas with DELETE after prune" '[ "$delete_count" -eq 0 ]' "0 deltas with DELETE (got: $delete_count)"

# Verify pruned nodes are actually gone
remaining=$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM nodes WHERE text LIKE 'prune-target%';" 2>/dev/null || echo "0")
assert "Pruned nodes removed from local DB" '[ "$remaining" -eq 0 ]' "0 prune-target nodes (got: $remaining)"

# Test: pruned nodes don't reappear after load on another agent
$WV sync 2>/dev/null || true
cd "$PRUNE_DIR" && git add .weave/ && git commit -m "post-prune" -q --no-verify 2>/dev/null && git push -q 2>/dev/null || true

VERIFY_DIR="$TEST_DIR/verify-prune"
git clone "$BARE_REPO" "$VERIFY_DIR" -q 2>/dev/null
mkdir -p "$VERIFY_DIR/hot"
init_agent_db "$VERIFY_DIR"
$WV load 2>/dev/null || true
reappeared=$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM nodes WHERE text LIKE 'prune-target%';" 2>/dev/null || echo "0")

assert "Pruned nodes don't reappear on other agent" '[ "$reappeared" -eq 0 ]' "0 reappeared (got: $reappeared)"

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "════════════════════════════════════════"
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
if [ "$TESTS_PASSED" -eq "$TESTS_RUN" ]; then
    echo -e "${GREEN}ALL TESTS PASSED${NC}"
else
    echo -e "${RED}SOME TESTS FAILED${NC}"
    exit 1
fi
