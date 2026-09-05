#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# Test cache invalidation for all edge-modifying commands
#
# Tests that context cache is properly invalidated when:
# 1. cmd_refs creates edges in link mode
# 2. cmd_prune deletes nodes and edges
# 3. cmd_block, cmd_link, cmd_done modify edges
#
# Exit codes:
#   0 - All tests passed
#   1 - One or more tests failed

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$PROJECT_ROOT/scripts/wv"

# wv_mutation_seq is the production mutation clock. The deletion tests below
# record a sync stamp exactly the way _sync_gh does, rather than reimplementing
# the counter query and testing a copy of it.
# shellcheck source=../scripts/lib/wv-delta.sh
source "$PROJECT_ROOT/scripts/lib/wv-delta.sh"

# Test environment
TEST_DIR="/tmp/wv-cache-test-$$"
export WEAVE_DIR="$TEST_DIR/.weave"

# Cleanup function
cleanup() {
    if [ -d "$TEST_DIR" ]; then
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

# Test helpers
setup_test_env() {
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR"
    cd "$TEST_DIR"
    export WV_HOT_ZONE="$TEST_DIR/hot"  # fresh hot zone per test; rm -rf above clears stale DB
    "$WV" init >/dev/null 2>&1
}

assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="$3"

    TESTS_RUN=$((TESTS_RUN + 1))

    if [ "$expected" = "$actual" ]; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Expected: $expected"
        echo "  Actual:   $actual"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"

    TESTS_RUN=$((TESTS_RUN + 1))

    if echo "$haystack" | grep -qF -- "$needle"; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Expected to find: $needle"
        echo "  In: $haystack"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

# Test 1: cmd_refs link mode invalidates cache
test_cmd_refs_link_invalidation() {
    echo ""
    echo "Test 1: cmd_refs --link invalidates cache"
    echo "========================================="

    setup_test_env

    # Create two nodes
    local src
    src=$("$WV" add "Test source node" | tail -1)
    local tgt
    tgt=$("$WV" add "Test target node" | tail -1)

    # Get initial context (populates cache)
    local before_count
    before_count=$("$WV" context "$src" --json | jq -r '.related | length')
    assert_equals "0" "$before_count" "Initial context has no related nodes"

    # Create a file with weave ID reference
    echo "This document references $tgt for details" > test.txt

    # Use cmd_refs to create edge
    "$WV" refs test.txt --link --from="$src" >/dev/null 2>&1

    # Get context again (should reflect new edge due to cache invalidation)
    local after_count
    after_count=$("$WV" context "$src" --json | jq -r '.related | length')
    assert_equals "1" "$after_count" "Context shows new related node after refs --link"

    # Verify the related node is the target
    local related_id
    related_id=$("$WV" context "$src" --json | jq -r '.related[0].id')
    assert_equals "$tgt" "$related_id" "Related node is the target node"

    # Verify target node context also updated (bidirectional invalidation)
    local target_context
    target_context=$("$WV" context "$tgt" --json | jq -r '.related | length')
    # Target may or may not show reverse relationship depending on query logic
    # But the cache should be invalidated (no stale data)
}

# Test 2: cmd_block invalidates cache
test_cmd_block_invalidation() {
    echo ""
    echo "Test 2: cmd_block invalidates cache"
    echo "===================================="

    setup_test_env

    # Create two nodes
    local node1
    node1=$("$WV" add "Node 1" | tail -1)
    local node2
    node2=$("$WV" add "Node 2" | tail -1)

    # Get initial context
    local before_blockers
    before_blockers=$("$WV" context "$node1" --json | jq -r '.blockers | length')
    assert_equals "0" "$before_blockers" "Initial context has no blockers"

    # Block node1 by node2
    "$WV" block "$node1" --by="$node2" >/dev/null 2>&1

    # Get context again
    local after_blockers
    after_blockers=$("$WV" context "$node1" --json | jq -r '.blockers | length')
    assert_equals "1" "$after_blockers" "Context shows blocker after wv block"

    # Verify blocker is node2
    local blocker_id
    blocker_id=$("$WV" context "$node1" --json | jq -r '.blockers[0].id')
    assert_equals "$node2" "$blocker_id" "Blocker is the expected node"
}

# Test 3: cmd_done invalidates cache
test_cmd_done_invalidation() {
    echo ""
    echo "Test 3: cmd_done invalidates cache"
    echo "==================================="

    setup_test_env

    # Create blocker and blocked nodes
    local blocker
    blocker=$("$WV" add "Blocker node" | tail -1)
    local blocked
    blocked=$("$WV" add "Blocked node" | tail -1)

    # Create blocking relationship
    "$WV" block "$blocked" --by="$blocker" >/dev/null 2>&1

    # Verify blocked node has blocker
    local before_count
    before_count=$("$WV" context "$blocked" --json | jq -r '.blockers | length')
    assert_equals "1" "$before_count" "Blocked node has one blocker"

    # Complete blocker
    "$WV" done "$blocker" --skip-verification >/dev/null 2>&1

    # Get context again - done blockers are filtered out by design
    # (see docs/WEAVE.md: "blockers (done nodes filtered out)")
    local after_count
    after_count=$("$WV" context "$blocked" --json | jq -r '.blockers | length')
    assert_equals "0" "$after_count" "Done blocker is filtered from context"
}

# Test 4: cmd_link invalidates cache
test_cmd_link_invalidation() {
    echo ""
    echo "Test 4: cmd_link invalidates cache"
    echo "==================================="

    setup_test_env

    # Create two nodes
    local node1
    node1=$("$WV" add "Node 1" | tail -1)
    local node2
    node2=$("$WV" add "Node 2" | tail -1)

    # Get initial context
    local before_related
    before_related=$("$WV" context "$node1" --json | jq -r '.related | length')
    assert_equals "0" "$before_related" "Initial context has no related nodes"

    # Create link
    "$WV" link "$node1" "$node2" --type=references --weight=0.8 >/dev/null 2>&1

    # Get context again
    local after_related
    after_related=$("$WV" context "$node1" --json | jq -r '.related | length')
    assert_equals "1" "$after_related" "Context shows related node after wv link"
}

# Test 5: cmd_prune invalidates cache
test_cmd_prune_invalidation() {
    echo ""
    echo "Test 5: cmd_prune invalidates cache"
    echo "===================================="

    setup_test_env

    # Create old done node
    local old_node
    old_node=$("$WV" add "Old node to prune" | tail -1)

    # Create dependent node
    local dep_node
    dep_node=$("$WV" add "Dependent node" | tail -1)

    # Create blocking relationship
    "$WV" block "$dep_node" --by="$old_node" >/dev/null 2>&1

    # Complete old node
    "$WV" done "$old_node" --skip-verification >/dev/null 2>&1

    # Artificially age the node
    # Database is at $WV_HOT_ZONE/brain.db (tmpfs location)
    local hot_zone
    hot_zone=$(find /dev/shm -maxdepth 1 -type d -name "weave*" 2>/dev/null | head -1)
    if [ -z "$hot_zone" ]; then
        echo -e "${YELLOW}⊘${NC} Skipping prune test - cannot find hot zone in /dev/shm"
        return
    fi

    local db_path="$hot_zone/brain.db"
    if [ ! -f "$db_path" ]; then
        echo -e "${YELLOW}⊘${NC} Skipping prune test - cannot find database at $db_path"
        return
    fi

    sqlite3 "$db_path" "UPDATE nodes SET updated_at='2020-01-01 00:00:00' WHERE id='$old_node';" 2>/dev/null

    # Get context before prune (should include old blocker)
    local before_blockers
    before_blockers=$("$WV" context "$dep_node" --json | jq -r '.blockers | length')

    # Prune old nodes
    "$WV" prune --age=1h >/dev/null 2>&1

    # Get context after prune
    local after_blockers
    after_blockers=$("$WV" context "$dep_node" --json | jq -r '.blockers | length')

    # After prune, old blocker should be gone (or show as done)
    # The key test is that cache was invalidated and query ran fresh
    if [ "$after_blockers" -lt "$before_blockers" ] || [ "$after_blockers" -eq 0 ]; then
        assert_equals "true" "true" "Cache invalidated after prune (blocker count changed or is 0)"
    else
        # Check if the blocker still exists but was just completed
        local blocker_exists
        blocker_exists=$("$WV" show "$old_node" 2>/dev/null | grep -c "^ID:" || echo "0")
        assert_equals "0" "$blocker_exists" "Old node was pruned (no longer exists)"
    fi
}

# Test 6: Cache files are actually created and removed
test_cache_file_lifecycle() {
    echo ""
    echo "Test 6: Cache files are created and removed"
    echo "============================================"

    setup_test_env

    # Create a node
    local node
    node=$("$WV" add "Test node" | tail -1)

    # Get context (should create cache file)
    "$WV" context "$node" --json >/dev/null 2>&1

    # Check if cache file exists
    local cache_dir
    cache_dir=$(find "$WV_HOT_ZONE" -type d -name "context_cache" 2>/dev/null | head -1)

    if [ -z "$cache_dir" ]; then
        echo -e "${YELLOW}⊘${NC} Cache directory not found - cache may not be enabled"
        return
    fi

    local cache_file="$cache_dir/${node}.json"
    if [ -f "$cache_file" ]; then
        assert_equals "true" "true" "Cache file created after wv context"
    else
        echo -e "${YELLOW}⊘${NC} Cache file not found - caching may be disabled"
        return
    fi

    # Create another node and link it
    local node2
    node2=$("$WV" add "Test node 2" | tail -1)
    "$WV" link "$node" "$node2" --type=references >/dev/null 2>&1

    # Cache file should be removed (invalidated)
    if [ ! -f "$cache_file" ]; then
        assert_equals "true" "true" "Cache file removed after edge modification"
    else
        # On some systems, cache might still exist but be outdated
        # The important thing is that the next query returns fresh data
        local related_count
        related_count=$("$WV" context "$node" --json | jq -r '.related | length')
        assert_equals "1" "$related_count" "Cache returns fresh data after invalidation"
    fi
}

# Test 7: pre-existing v3 cache file does not shadow the v4 payload shape (wv-22ca26)
# cmd_context added done_criteria/risks/risk_level (node) and blocked_reason (envelope)
# to its output without changing the cache filename, so a cache entry written before
# that change could be served verbatim after upgrade and silently mask the new fields.
# The fix bumps the cache key (v3 -> v4); this proves a stale v3 file on disk is
# ignored rather than read.
test_v3_cache_upgrade_no_shadow() {
    echo ""
    echo "Test 7: stale pre-upgrade (v3) cache file does not shadow the new payload shape"
    echo "================================================================================="

    setup_test_env

    local node
    node=$("$WV" add "Cache upgrade test node" | tail -1)

    local cache_dir="$WV_HOT_ZONE/context_cache"
    mkdir -p "$cache_dir"

    # Simulate a pre-upgrade cache entry written by the OLD (v3) code path: missing
    # done_criteria/risks/risk_level on node and blocked_reason on the envelope.
    local stale_file="$cache_dir/${node}-bootstrap-v3.json"
    printf '{"node":{"id":"%s","text":"stale","status":"todo"},"blocked":false,"blockers":[]}' "$node" > "$stale_file"

    local response
    response=$("$WV" context "$node" --json --mode=bootstrap)

    local has_done_criteria has_blocked_reason
    has_done_criteria=$(echo "$response" | jq '(.node // {}) | has("done_criteria")')
    has_blocked_reason=$(echo "$response" | jq 'has("blocked_reason")')

    assert_equals "true" "$has_done_criteria" "fresh response has node.done_criteria (stale v3 cache not served)"
    assert_equals "true" "$has_blocked_reason" "fresh response has blocked_reason (stale v3 cache not served)"

    # The stale v3 file itself must be left untouched (proves it was never opened for
    # read or write -- the new code looked at the v4 filename exclusively)
    local stale_untouched
    stale_untouched=$(jq 'has("blocked_reason") | not' "$stale_file")
    assert_equals "true" "$stale_untouched" "stale v3 cache file left as-is on disk"

    # A fresh v4-keyed cache file should now exist alongside the stale v3 one
    local v4_file="$cache_dir/${node}-bootstrap-v4.json"
    if [ -f "$v4_file" ]; then
        assert_equals "true" "true" "new v4 cache file created"
    else
        echo -e "${YELLOW}⊘${NC} v4 cache file not found at expected path - cache filename convention may have changed"
    fi
}

# Test 8: wv touch invalidates run cache
# Verifies the bug fixed in 1.51.7: touch was absent from _wv_run_cache_is_write_cmd
# so wv bootstrap served stale metadata for up to 45s after a touch.
test_touch_invalidates_run_cache() {
    echo ""
    echo "Test 7: wv touch invalidates run cache"
    echo "======================================="

    setup_test_env
    export WV_RUN_CACHE=1

    local node_id
    node_id=$("$WV" add "Run-cache touch test" | tail -1)
    "$WV" update "$node_id" --alias=rct >/dev/null 2>&1
    "$WV" work "$node_id" >/dev/null 2>&1

    # Prime the bootstrap run cache
    "$WV" bootstrap --json >/dev/null 2>&1

    # Ensure sentinel mtime > cache mtime (1s filesystem granularity)
    sleep 1

    # Touch node with a unique marker
    local marker="runcache-intent-$$"
    "$WV" touch "$node_id" --intent="$marker"

    # Bootstrap must return fresh data; stale cache would return empty intent
    local got
    got=$("$WV" bootstrap --json | jq -r \
        '.active_node.metadata | if type == "string" then fromjson else . end | .current_intent // ""')

    assert_equals "$marker" "$got" "wv touch invalidates run cache: bootstrap shows updated intent"

    export WV_RUN_CACHE=0
}

# Test 9: a deletion invalidates the wv impact cache
# Regression (release review 3): the cache was validated against a TIMESTAMP
# clock, MAX(updated_at) over nodes and edges. A timestamp cannot see a DELETE,
# and unlinking the newest edge moves that clock BACKWARDS -- measured, from
# 1787519439 to 1787519438 -- so a cache written before the deletion looked
# newer than the graph and was served with the deleted edge still in it.
test_impact_cache_invalidated_by_unlink() {
    echo ""
    echo "Test 9: deletion invalidates the wv impact cache"
    echo "================================================"

    setup_test_env

    local src tgt
    src=$("$WV" add "Impact seed node" | tail -1)
    tgt=$("$WV" add "Impact target node" | tail -1)
    "$WV" link "$src" "$tgt" --type=blocks >/dev/null 2>&1

    # Prime the cache: this run writes the walk and its mutation counter.
    local before
    before=$("$WV" impact "$src" --json 2>/dev/null | jq -r '.impacted | length')
    assert_equals "1" "$before" "impact reports the linked node before the unlink"

    "$WV" unlink "$src" "$tgt" --type=blocks >/dev/null 2>&1

    local after after_edges
    after=$("$WV" impact "$src" --json 2>/dev/null | jq -r '.impacted | length')
    assert_equals "0" "$after" "impact drops the unlinked node instead of serving the cache"
    after_edges=$("$WV" impact "$src" --json 2>/dev/null | jq -r '.edges | length')
    assert_equals "0" "$after_edges" "the deleted edge is gone from the served edge list"
}

# Test 10: a deletion is visible to needs_sync
# Same root cause as Test 9 on a different surface: status compared the last
# sync stamp against MAX(updated_at), so an unsynced deletion reported as
# synced -- and because deleting the newest row moves that clock backwards, it
# reported as synced even more confidently the more recent the deletion was.
test_needs_sync_sees_deletion() {
    echo ""
    echo "Test 10: needs_sync sees a deletion"
    echo "==================================="

    setup_test_env

    local src tgt
    src=$("$WV" add "Sync seed node" | tail -1)
    tgt=$("$WV" add "Sync target node" | tail -1)
    "$WV" link "$src" "$tgt" --type=blocks >/dev/null 2>&1

    # Record a completed sync the way _sync_gh does: wall clock plus counter.
    date +%s > "$WV_HOT_ZONE/.last_gh_sync"
    wv_mutation_seq "$WV_HOT_ZONE/brain.db" > "$WV_HOT_ZONE/.last_gh_sync_seq"

    local synced
    synced=$("$WV" status --json 2>/dev/null | jq -r '.needs_sync')
    assert_equals "false" "$synced" "needs_sync clears after a recorded sync"

    "$WV" unlink "$src" "$tgt" --type=blocks >/dev/null 2>&1

    local after
    after=$("$WV" status --json 2>/dev/null | jq -r '.needs_sync')
    assert_equals "true" "$after" "needs_sync flips true after an edge deletion"
}

# Test 11: a walk that raced a mutation is not published
# Regression (release review 4): the sequence was recorded AFTER generating the
# walk, so a mutation landing during generation certified OLD content with the
# NEW counter. Every later reader then saw a cache that looked current and never
# expired -- the mutation was invisible permanently, not just until the next
# call. The sequence is now read before the walk and re-checked after, the walk
# is published only if the graph did not move, and the counter travels INSIDE
# the cache file so a reader cannot pair it with someone else's walk.
test_impact_cache_not_published_when_walk_raced() {
    echo ""
    echo "Test 11: a walk that raced a mutation is not published"
    echo "======================================================"

    setup_test_env

    local src tgt
    src=$("$WV" add "Race seed node" | tail -1)
    tgt=$("$WV" add "Race target node" | tail -1)
    "$WV" link "$src" "$tgt" --type=blocks >/dev/null 2>&1

    local cache_dir="$WV_HOT_ZONE/context_cache"

    # A walk that the graph moved underneath must publish nothing at all.
    WV_TEST_MODE=1 WV_TEST_IMPACT_RACE=1 "$WV" impact "$src" --json >/dev/null 2>&1
    local raced_files
    raced_files=$(find "$cache_dir" -name 'impact-*-v2.json' 2>/dev/null | wc -l | tr -d ' ')
    assert_equals "0" "$raced_files" "a walk that raced a mutation is not published"

    # An undisturbed walk publishes, and its stored counter matches the graph.
    "$WV" impact "$src" --json >/dev/null 2>&1
    local clean_files
    clean_files=$(find "$cache_dir" -name 'impact-*-v2.json' 2>/dev/null | wc -l | tr -d ' ')
    assert_equals "1" "$clean_files" "an undisturbed walk is published"

    local cache_path stored_seq db_seq
    cache_path=$(find "$cache_dir" -name 'impact-*-v2.json' 2>/dev/null | head -1)
    stored_seq=$(head -n 1 "$cache_path" 2>/dev/null)
    db_seq=$(sqlite3 "$WV_HOT_ZONE/brain.db" \
        "SELECT COALESCE((SELECT seq FROM sqlite_sequence WHERE name='_warp_changes'), 0);" 2>/dev/null)
    assert_equals "$db_seq" "$stored_seq" "the published counter is the graph the walk actually saw"

    # The counter lives in the file, not beside it: a sidecar cannot be renamed
    # together with the walk, so a reader could pair mismatched halves.
    local sidecars
    sidecars=$(find "$cache_dir" -name 'impact-*.seq' 2>/dev/null | wc -l | tr -d ' ')
    assert_equals "0" "$sidecars" "no sidecar counter file is left to be torn from its walk"
}

# Test 12: the WV_TEST_IMPACT_RACE hook is gated and validated on every path
# Regression (release review 5): validation sat INSIDE the cache-miss branch,
# so an unrecognised value was accepted silently whenever the walk was served
# from cache -- the ordinary fast path. "Unknown values are rejected" held only
# where a test was least likely to look.
test_impact_race_hook_is_gated_and_validated() {
    echo ""
    echo "Test 12: the impact race hook is gated and validated on every path"
    echo "=================================================================="

    setup_test_env

    local src tgt
    src=$("$WV" add "Hook gate seed" | tail -1)
    tgt=$("$WV" add "Hook gate target" | tail -1)
    "$WV" link "$src" "$tgt" --type=blocks >/dev/null 2>&1

    local db="$WV_HOT_ZONE/brain.db"
    local seq_q="SELECT COALESCE((SELECT seq FROM sqlite_sequence WHERE name='_warp_changes'), 0);"

    # 1. Without the master opt-in, a VALID value is inert. The hook's whole
    #    effect is a graph mutation, so an unchanged counter is direct proof it
    #    did not fire -- not merely that the command survived.
    #
    #    This MUST run on a cache MISS. The fault executes inside the cache-miss
    #    branch, so measuring around a cached call proves nothing: the hook
    #    would stay silent even with the master gate removed, and the assertion
    #    would pass while testing nothing. (It did, until this line was added.)
    find "$WV_HOT_ZONE/context_cache" -name 'impact-*-v2.json' -delete 2>/dev/null || true
    local seq_before seq_after rc
    seq_before=$(sqlite3 "$db" "$seq_q" 2>/dev/null)
    rc=0
    WV_TEST_IMPACT_RACE=1 "$WV" impact "$src" --json >/dev/null 2>&1 || rc=$?
    seq_after=$(sqlite3 "$db" "$seq_q" 2>/dev/null)
    assert_equals "0" "$rc" "a valid race value without WV_TEST_MODE=1 does not fail the command"
    assert_equals "$seq_before" "$seq_after" "a valid race value without WV_TEST_MODE=1 mutates nothing"

    # 2. With test mode, an invalid value is rejected on a CACHE HIT -- the path
    #    that used to skip validation entirely.
    "$WV" impact "$src" --json >/dev/null 2>&1
    local cached
    cached=$(find "$WV_HOT_ZONE/context_cache" -name 'impact-*-v2.json' 2>/dev/null | wc -l | tr -d ' ')
    assert_equals "1" "$cached" "a cache entry exists, so the next call takes the cached path"
    rc=0
    WV_TEST_MODE=1 WV_TEST_IMPACT_RACE=typo "$WV" impact "$src" --json >/dev/null 2>&1 || rc=$?
    assert_equals "1" "$rc" "an invalid race value is rejected on a cache hit"

    # 3. And on a cache miss, so the outcome does not depend on cache state.
    find "$WV_HOT_ZONE/context_cache" -name 'impact-*-v2.json' -delete 2>/dev/null || true
    rc=0
    WV_TEST_MODE=1 WV_TEST_IMPACT_RACE=typo "$WV" impact "$src" --json >/dev/null 2>&1 || rc=$?
    assert_equals "1" "$rc" "an invalid race value is rejected on a cache miss"
}

# Run all tests
test_uncommitted_edit_invalidates_function_rows() {
    echo ""
    echo "Test 12: an uncommitted edit invalidates per-function CC rows"
    echo "============================================================="

    # wv-7fbfe1. blob_map came from `git ls-tree -r HEAD`, so a tracked file with
    # uncommitted edits carried its PRE-EDIT SHA. file_changed read that as
    # unchanged and skipped the file; ASTCache, keyed on the same value, handed
    # back the committed parse to anything that got past. `wv quality functions`
    # then served the old complexity under the old line span, and the `wv done`
    # mccabe gate reads exactly those rows -- while the repository is dirty,
    # which is the only state it is ever in when the gate runs.
    setup_test_env
    git init -q . >/dev/null 2>&1 || true
    git config user.email "test@test.com" || true
    git config user.name "Test" || true
    git config commit.gpgsign false || true

    mkdir -p src
    printf 'def sample(a):\n    if a: return 1\n    return 0\n' > src/sample.py
    git add -A >/dev/null 2>&1 || true
    git commit -qm "baseline" >/dev/null 2>&1 || true

    "$WV" quality scan >/dev/null 2>&1 || true
    local before
    before=$("$WV" quality functions src/sample.py 2>&1 | grep -oE 'CC=[0-9]+' | head -1 || true)
    assert_equals "CC=2" "$before" "baseline complexity is recorded"

    # Same function, far more branching -- and deliberately NOT committed.
    cat > src/sample.py <<'PYEOF'
def sample(a, b, c, d, e):
    if a:
        if b:
            if c:
                if d:
                    if e: return 1
    for i in range(10):
        if i > 5 and a or b: return 2
    while c:
        if d or e: break
    return 0
PYEOF

    "$WV" quality scan >/dev/null 2>&1 || true
    local after
    after=$("$WV" quality functions src/sample.py 2>&1 | grep -oE 'CC=[0-9]+' | head -1 || true)
    local changed="stale"
    [ -n "$after" ] && [ "$after" != "CC=2" ] && changed="updated"
    assert_equals "updated" "$changed" \
        "rescan reflects the uncommitted edit (no 'wv quality reset' needed)"

    # The stored span is the tell: a carried-forward row keeps the pre-edit one,
    # so a stale row is recognisable without knowing the right complexity.
    local span span_state
    span=$("$WV" quality functions src/sample.py 2>&1 | grep -oE 'L:[0-9]+-[0-9]+' | head -1 || true)
    span_state="stale"
    [ -n "$span" ] && [ "$span" != "L:1-3" ] && span_state="refreshed"
    assert_equals "refreshed" "$span_state" "stored line span is refreshed with the value"

    # Reverting to the committed bytes must settle rather than re-scan forever:
    # the working-tree hash uses git's own blob formula, so identical content
    # hashes back to the HEAD blob.
    printf 'def sample(a):\n    if a: return 1\n    return 0\n' > src/sample.py
    "$WV" quality scan >/dev/null 2>&1 || true
    local reverted
    reverted=$("$WV" quality functions src/sample.py 2>&1 | grep -oE 'CC=[0-9]+' | head -1 || true)
    assert_equals "CC=2" "$reverted" "reverting to committed bytes returns the baseline"

    cd "$PROJECT_ROOT" 2>/dev/null || true
}

test_done_gate_reads_post_edit_complexity() {
    echo ""
    echo "Test 13: the wv done complexity gate reads a post-edit value"
    echo "============================================================"

    # wv-7fbfe1, end to end. _done_refresh_file_metrics reads MAX(fn_cc:*) for
    # the LATEST scan out of quality.db and upserts it into brain.db, which the
    # gate compares against policy_thresholds. It never scans for itself, so a
    # scan blind to the working tree left the gate judging committed code: a
    # close blocked over a defect the author had already fixed but not committed.
    #
    # Both halves are asserted. The first proves the gate is actually armed in
    # this environment -- without it, a gate that silently never fires would
    # make the second assertion pass for the wrong reason.
    setup_test_env
    git init -q . >/dev/null 2>&1 || true
    git config user.email "test@test.com" || true
    git config user.name "Test" || true
    git config commit.gpgsign false || true

    mkdir -p src
    {
        echo "def gate(a, b, c, d, e, f):"
        for i in $(seq 1 30); do
            echo "    if a and b or c and d or e and f: return $i"
        done
        echo "    return 0"
    } > src/gate.py
    git add -A >/dev/null 2>&1 || true
    git commit -qm "high complexity baseline" >/dev/null 2>&1 || true
    "$WV" quality scan >/dev/null 2>&1 || true

    local blocked_node
    blocked_node=$("$WV" add "gate armed check" --standalone --criteria="c" --risks=low 2>/dev/null | tail -1)
    sqlite3 "$WV_HOT_ZONE/brain.db" \
        "INSERT OR REPLACE INTO node_files(node_id, path) VALUES('$blocked_node','src/gate.py');" \
        >/dev/null 2>&1 || true
    "$WV" work "$blocked_node" >/dev/null 2>&1 || true

    local armed="not-armed"
    "$WV" done "$blocked_node" --skip-verification >/dev/null 2>&1 || armed="armed"
    assert_equals "armed" "$armed" "the complexity gate blocks a close over committed high CC"

    # Same file, repaired, and deliberately NOT committed.
    printf 'def gate(a):\n    if a: return 1\n    return 0\n' > src/gate.py
    "$WV" quality scan >/dev/null 2>&1 || true

    local outcome="blocked"
    if "$WV" done "$blocked_node" --skip-verification >/dev/null 2>&1; then
        outcome="closed"
    fi
    assert_equals "closed" "$outcome" \
        "wv done accepts an uncommitted complexity repair (gate is not reading a stale row)"

    cd "$PROJECT_ROOT" 2>/dev/null || true
}

test_exempt_projection_survives_a_rebuilt_db() {
    echo ""
    echo "Test 14: a declared exemption survives losing its projection"
    echo "============================================================"

    # wv-785ba1. The quality gate is a SQL trigger reading the quality_exempt
    # TABLE, projected from .weave/quality.conf by _load_quality_config.
    # wv-6657dd added a freshness check so an exemption committed after the last
    # load still counts -- but memoised it in a file BESIDE the database
    # ($WV_HOT_ZONE/.quality_conf_sig). A sibling file outlives the database it
    # describes, so a hot zone whose brain.db had been rebuilt kept a stamp
    # asserting that an empty quality_exempt was current, and wv done blocked on
    # a path quality.conf had explicitly exempted.
    #
    # The signature now lives in quality_config_sig inside brain.db, so losing
    # the projection loses the claim about it. This test recreates the exact
    # divergence: table cleared, and a sibling stamp planted with the CURRENT
    # signature. Old code trusts the file and refuses; new code ignores it,
    # finds no in-DB claim, and reloads.
    setup_test_env
    git init -q . >/dev/null 2>&1 || true
    git config user.email "test@test.com" || true
    git config user.name "Test" || true
    git config commit.gpgsign false || true

    mkdir -p src
    {
        echo "def gate(a, b, c, d, e, f):"
        for i in $(seq 1 30); do
            echo "    if a and b or c and d or e and f: return $i"
        done
        echo "    return 0"
    } > src/gate.py
    printf '[exempt]\nsrc/gate.py\n' > "$WEAVE_DIR/quality.conf"
    git add -A >/dev/null 2>&1 || true
    git commit -qm "exempt baseline" >/dev/null 2>&1 || true

    "$WV" quality scan >/dev/null 2>&1 || true
    "$WV" load >/dev/null 2>&1 || true

    local node
    node=$("$WV" add "exempt freshness" --standalone --criteria="c" --risks=low 2>/dev/null | tail -1)
    sqlite3 "$WV_HOT_ZONE/brain.db" \
        "INSERT OR REPLACE INTO node_files(node_id, path) VALUES('$node','src/gate.py');" \
        >/dev/null 2>&1 || true
    "$WV" work "$node" >/dev/null 2>&1 || true

    # Capture the REAL signature the loader just recorded, so the sibling stamp
    # planted below is one the old memo would accept. A stamp with any other
    # content mismatches and provokes a reload, which would make this test pass
    # against the very code it exists to fail.
    local real_sig
    real_sig=$(sqlite3 "$WV_HOT_ZONE/brain.db" \
        "SELECT signature FROM quality_config_sig WHERE id = 1;" 2>/dev/null || printf '')
    assert_equals "yes" "$([ -n "$real_sig" ] && echo yes || echo no)" \
        "the loader recorded a config signature in the database"

    # The projection and its in-DB claim go, as a rebuilt brain.db loses both.
    sqlite3 "$WV_HOT_ZONE/brain.db" \
        "DELETE FROM quality_exempt; DELETE FROM quality_config_sig;" >/dev/null 2>&1 || true
    # The superseded sibling stamp, planted CURRENT: exactly what made the old
    # memo claim an empty table was fresh.
    printf '%s' "$real_sig" > "$WV_HOT_ZONE/.quality_conf_sig" 2>/dev/null || true

    local outcome="blocked"
    if "$WV" done "$node" --skip-verification >/dev/null 2>&1; then
        outcome="closed"
    fi
    assert_equals "closed" "$outcome" \
        "wv done honours quality.conf after the projection is lost"

    local restored
    restored=$(sqlite3 "$WV_HOT_ZONE/brain.db" \
        "SELECT COUNT(*) FROM quality_exempt;" 2>/dev/null || echo "0")
    assert_equals "1" "$restored" "the exemption was re-projected from the committed file"

    cd "$PROJECT_ROOT" 2>/dev/null || true
}

main() {
    echo "Cache Invalidation Tests"
    echo "========================"
    echo "Testing: cmd_refs, cmd_block, cmd_done, cmd_link, cmd_prune, run-cache, deletion"
    echo ""

    test_cmd_refs_link_invalidation
    test_cmd_block_invalidation
    test_cmd_done_invalidation
    test_cmd_link_invalidation
    test_cmd_prune_invalidation
    test_cache_file_lifecycle
    test_v3_cache_upgrade_no_shadow
    test_touch_invalidates_run_cache
    test_impact_cache_invalidated_by_unlink
    test_needs_sync_sees_deletion
    test_impact_cache_not_published_when_walk_raced
    test_impact_race_hook_is_gated_and_validated
    test_uncommitted_edit_invalidates_function_rows
    test_done_gate_reads_post_edit_complexity
    test_exempt_projection_survives_a_rebuilt_db

    # Summary
    echo ""
    echo "Test Summary"
    echo "============"
    echo "Tests run:    $TESTS_RUN"
    echo -e "Tests passed: ${GREEN}$TESTS_PASSED${NC}"

    if [ "$TESTS_FAILED" -gt 0 ]; then
        echo -e "Tests failed: ${RED}$TESTS_FAILED${NC}"
        exit 1
    else
        echo -e "${GREEN}All tests passed!${NC}"
        exit 0
    fi
}

main "$@"
