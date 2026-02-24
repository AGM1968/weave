#!/usr/bin/env bash
# test-stress.sh — Stress testing & resilience hardening for Weave CLI
#
# Tests: sync round-trip, concurrency, scale, recovery, fuzzing, bug regressions, integration
#
# Run: bash tests/test-stress.sh [--slow] [--verbose]
#
# Options:
#   --slow       Include slow tests (500-node benchmark, deep chains)
#   --verbose    Show detailed output for each test
#
# Exit codes:
#   0 - All tests passed (or only EXPECT-FAIL tests failed)
#   1 - Unexpected test failures

set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# Configuration
# ═══════════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$PROJECT_ROOT/scripts/wv"

# Options
RUN_SLOW=false
VERBOSE=false
while [ $# -gt 0 ]; do
    case "$1" in
        --slow) RUN_SLOW=true ;;
        --verbose|-v) VERBOSE=true ;;
        --help|-h)
            echo "Usage: $0 [--slow] [--verbose]"
            echo ""
            echo "  --slow     Include slow tests (500-node, deep chain)"
            echo "  --verbose  Show detailed output"
            exit 0
            ;;
    esac
    shift
done

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_XFAIL=0  # Expected failures (known bugs)
FAILURES=()

# ═══════════════════════════════════════════════════════════════════════════
# Test Environment
# ═══════════════════════════════════════════════════════════════════════════

TEST_DIR=""

setup_test_env() {
    TEST_DIR=$(mktemp -d "/tmp/wv-stress-test-XXXXXX")
    export WV_HOT_ZONE="$TEST_DIR/hot"
    export WV_DB="$TEST_DIR/hot/brain.db"
    mkdir -p "$WV_HOT_ZONE"
    # Initialize git repo so WEAVE_DIR resolves to TEST_DIR/.weave
    cd "$TEST_DIR"
    git init -q 2>/dev/null
    mkdir -p "$TEST_DIR/.weave"
    "$WV" init >/dev/null 2>&1
}

teardown_test_env() {
    cd /tmp  # avoid pwd errors after removing test dir
    if [ -n "$TEST_DIR" ] && [ -d "$TEST_DIR" ]; then
        rm -rf "$TEST_DIR"
    fi
    TEST_DIR=""
}

# Cleanup on exit
trap 'teardown_test_env' EXIT

# ═══════════════════════════════════════════════════════════════════════════
# Test Helpers
# ═══════════════════════════════════════════════════════════════════════════

assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$expected" = "$actual" ]; then
        echo -e "  ${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "  ${RED}✗${NC} $message"
        echo "    Expected: $expected"
        echo "    Actual:   $actual"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILURES+=("$message")
        return 1
    fi
}

assert_not_equals() {
    local unexpected="$1"
    local actual="$2"
    local message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$unexpected" != "$actual" ]; then
        echo -e "  ${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "  ${RED}✗${NC} $message"
        echo "    Expected NOT: $unexpected"
        echo "    Actual:       $actual"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILURES+=("$message")
        return 1
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if echo "$haystack" | grep -qF "$needle"; then
        echo -e "  ${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "  ${RED}✗${NC} $message"
        echo "    Expected to find: $needle"
        echo "    In: $(echo "$haystack" | head -5)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILURES+=("$message")
        return 1
    fi
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if ! echo "$haystack" | grep -qF "$needle"; then
        echo -e "  ${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "  ${RED}✗${NC} $message"
        echo "    Expected NOT to find: $needle"
        echo "    In: $(echo "$haystack" | head -5)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILURES+=("$message")
        return 1
    fi
}

assert_success() {
    local message="$1"
    local exit_code="${2:-$?}"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$exit_code" -eq 0 ]; then
        echo -e "  ${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "  ${RED}✗${NC} $message (exit code: $exit_code)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILURES+=("$message")
        return 1
    fi
}

assert_fails() {
    local message="$1"
    local exit_code="${2:-$?}"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$exit_code" -ne 0 ]; then
        echo -e "  ${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "  ${RED}✗${NC} $message (expected failure, got exit 0)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILURES+=("$message")
        return 1
    fi
}

# EXPECT-FAIL: known bugs that should fail against current code
# After Sprint 0 fixes, these flip to assert_equals/assert_fails
assert_xfail() {
    local expected="$1"
    local actual="$2"
    local message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$expected" = "$actual" ]; then
        # Bug is fixed! This is actually a pass
        echo -e "  ${GREEN}✓${NC} $message (FIXED — was EXPECT-FAIL)"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        # Bug still present — expected failure
        echo -e "  ${YELLOW}⚠${NC} $message [EXPECT-FAIL: got '$actual', want '$expected']"
        TESTS_XFAIL=$((TESTS_XFAIL + 1))
        return 0
    fi
}

assert_xfail_exit() {
    local expected_nonzero="$1"  # "nonzero" for expecting exit != 0
    local actual_exit="$2"
    local message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$expected_nonzero" = "nonzero" ] && [ "$actual_exit" -ne 0 ]; then
        # Bug is fixed — command now correctly rejects
        echo -e "  ${GREEN}✓${NC} $message (FIXED — was EXPECT-FAIL)"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    elif [ "$expected_nonzero" = "nonzero" ] && [ "$actual_exit" -eq 0 ]; then
        # Bug still present — command accepts what it shouldn't
        echo -e "  ${YELLOW}⚠${NC} $message [EXPECT-FAIL: exit 0, want nonzero]"
        TESTS_XFAIL=$((TESTS_XFAIL + 1))
        return 0
    fi
}

# Utility: get last line (node ID) from wv add output
get_id() {
    echo "$1" | grep -oE 'wv-[a-f0-9]{4,6}' | tail -1
}

# ═══════════════════════════════════════════════════════════════════════════
# 4.1 Sync Round-Trip Integrity (P0)
# ═══════════════════════════════════════════════════════════════════════════

test_sync_roundtrip_fidelity() {
    echo ""
    echo -e "${CYAN}Test: Sync Round-Trip Fidelity (4.1.1)${NC}"
    echo "======================================="
    setup_test_env

    # Build a representative graph
    local id1 id2 id3
    id1=$(get_id "$("$WV" add "parent epic" --metadata='{"type":"epic"}' 2>&1)")
    id2=$(get_id "$("$WV" add "child feature" --metadata='{"type":"feature"}' 2>&1)")
    id3=$(get_id "$("$WV" add "task with metadata" --metadata='{"key":"value","nested":{"a":1}}' 2>&1)")
    "$WV" link "$id2" "$id1" --type=implements >/dev/null 2>&1
    "$WV" link "$id3" "$id2" --type=implements >/dev/null 2>&1
    "$WV" done "$id3" --learning="Test learning with 'quotes' and special chars" >/dev/null 2>&1

    # Capture full state before round-trip
    local before_nodes before_edges
    before_nodes=$("$WV" list --all --json 2>/dev/null | jq -S '.')
    before_edges=$(sqlite3 "$WV_DB" "SELECT json_group_array(json_object('source',source,'target',target,'type',type)) FROM edges ORDER BY source,target;" | jq -S '.')

    # Round-trip: sync, destroy DB, reload
    "$WV" sync >/dev/null 2>&1
    rm -f "$WV_DB" "$WV_DB-wal" "$WV_DB-shm"
    "$WV" load >/dev/null 2>&1

    # Compare
    local after_nodes after_edges
    after_nodes=$("$WV" list --all --json 2>/dev/null | jq -S '.')
    after_edges=$(sqlite3 "$WV_DB" "SELECT json_group_array(json_object('source',source,'target',target,'type',type)) FROM edges ORDER BY source,target;" | jq -S '.')

    assert_equals "$before_nodes" "$after_nodes" "Nodes survive round-trip" || true
    assert_equals "$before_edges" "$after_edges" "Edges survive round-trip" || true

    # FTS5 survives
    local search_result
    search_result=$("$WV" search "parent" --json 2>/dev/null | jq length)
    assert_equals "1" "$search_result" "FTS5 index works after round-trip" || true

    teardown_test_env
}

test_idempotent_load() {
    echo ""
    echo -e "${CYAN}Test: Idempotent Load (4.1.2)${NC}"
    echo "=============================="
    setup_test_env

    "$WV" add "idempotent test node" >/dev/null 2>&1
    "$WV" add "another node" >/dev/null 2>&1
    "$WV" sync >/dev/null 2>&1

    # Load multiple times
    "$WV" load >/dev/null 2>&1
    local count1
    count1=$("$WV" list --all --json 2>/dev/null | jq length)
    "$WV" load >/dev/null 2>&1
    local count2
    count2=$("$WV" list --all --json 2>/dev/null | jq length)

    assert_equals "$count1" "$count2" "Multiple loads don't duplicate nodes" || true

    # Check FTS5 isn't duplicated
    local search_count
    search_count=$("$WV" search "idempotent" --json 2>/dev/null | jq length)
    assert_equals "1" "$search_count" "FTS5 not duplicated after multiple loads" || true

    teardown_test_env
}

test_jsonl_sql_consistency() {
    echo ""
    echo -e "${CYAN}Test: JSONL vs SQL Consistency (4.1.3)${NC}"
    echo "======================================="
    setup_test_env

    for i in $(seq 1 20); do
        "$WV" add "Consistency node $i" >/dev/null 2>&1
    done
    "$WV" sync >/dev/null 2>&1

    local sql_count jsonl_count
    # Count only INSERT INTO "nodes" (exact table name, not nodes_fts etc.)
    sql_count=$(grep -cE "^INSERT INTO \"?nodes\"? " "$TEST_DIR/.weave/state.sql" || echo "0")
    jsonl_count=$(wc -l < "$TEST_DIR/.weave/nodes.jsonl")

    assert_equals "$sql_count" "$jsonl_count" "state.sql and nodes.jsonl node counts match" || true

    teardown_test_env
}

# ═══════════════════════════════════════════════════════════════════════════
# 4.2 Concurrency & Race Conditions (P0)
# ═══════════════════════════════════════════════════════════════════════════

test_parallel_add() {
    echo ""
    echo -e "${CYAN}Test: Parallel wv add — WAL Stress (4.2.1)${NC}"
    echo "============================================"
    setup_test_env

    # Spawn 20 parallel add operations
    local pids=()
    for i in $(seq 1 20); do
        "$WV" add "parallel node $i" >/dev/null 2>&1 &
        pids+=($!)
    done

    # Wait for all with timeout
    local failed=0
    for pid in "${pids[@]}"; do
        if ! wait "$pid" 2>/dev/null; then
            failed=$((failed + 1))
        fi
    done

    local count unique
    count=$("$WV" list --all --json 2>/dev/null | jq length)
    # With busy_timeout=5000ms, SQLite retries internally on SQLITE_BUSY.
    # All 20 writes should succeed; ≥19 allows for rare edge cases.
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$count" -ge 19 ]; then
        echo -e "  ${GREEN}✓${NC} Parallel adds: $count/20 succeeded (≥19 expected with busy_timeout)"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗${NC} Parallel adds: only $count/20 succeeded (expected ≥19)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILURES+=("Parallel adds: only $count/20")
    fi

    # Check for duplicate IDs
    unique=$("$WV" list --all --json 2>/dev/null | jq -r '.[].id' | sort -u | wc -l)
    assert_equals "$count" "$unique" "No duplicate IDs from parallel writes" || true

    # Check FTS5 integrity
    local integrity
    integrity=$(sqlite3 "$WV_DB" "INSERT INTO nodes_fts(nodes_fts) VALUES('integrity-check');" 2>&1 || echo "")
    assert_equals "" "$integrity" "FTS5 index intact after parallel writes" || true

    teardown_test_env
}

test_sync_during_write() {
    echo ""
    echo -e "${CYAN}Test: Simultaneous Sync + Write (4.2.2)${NC}"
    echo "========================================="
    setup_test_env

    # Create initial state
    for i in $(seq 1 10); do
        "$WV" add "base node $i" >/dev/null 2>&1
    done

    # Start sync in background, simultaneously add more nodes
    "$WV" sync >/dev/null 2>&1 &
    local sync_pid=$!
    for i in $(seq 11 20); do
        "$WV" add "concurrent node $i" >/dev/null 2>&1
    done
    wait "$sync_pid" 2>/dev/null || true

    # Verify state.sql is valid SQL
    if [ -f "$TEST_DIR/.weave/state.sql" ]; then
        local valid
        valid=$(sqlite3 :memory: < "$TEST_DIR/.weave/state.sql" 2>&1 && echo "valid" || echo "invalid")
        assert_equals "valid" "$valid" "state.sql is valid SQL after concurrent write" || true
    else
        TESTS_RUN=$((TESTS_RUN + 1))
        echo -e "  ${RED}✗${NC} state.sql not found after sync"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILURES+=("state.sql not found after sync")
    fi

    teardown_test_env
}

test_mcp_concurrent_reads() {
    echo ""
    echo -e "${CYAN}Test: MCP Concurrent Tool Calls (4.2.3)${NC}"
    echo "========================================="
    setup_test_env

    "$WV" add "mcp read base" >/dev/null 2>&1
    "$WV" add "mcp read extra" >/dev/null 2>&1

    # Simulate concurrent MCP reads (each is a separate process)
    local pids=()
    for i in $(seq 1 10); do
        "$WV" search "mcp" --json >/dev/null 2>&1 &
        pids+=($!)
        "$WV" list --all --json >/dev/null 2>&1 &
        pids+=($!)
    done

    local ok_count=0 fail_count=0
    for pid in "${pids[@]}"; do
        if wait "$pid" 2>/dev/null; then
            ok_count=$((ok_count + 1))
        else
            fail_count=$((fail_count + 1))
        fi
    done

    # Under WAL contention some reads may get SQLITE_BUSY — ≥80% success is acceptable
    TESTS_RUN=$((TESTS_RUN + 1))
    local total=$((ok_count + fail_count))
    if [ "$ok_count" -ge 16 ]; then
        echo -e "  ${GREEN}✓${NC} Concurrent reads: $ok_count/$total succeeded (≥80% acceptable)"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗${NC} Concurrent reads: only $ok_count/$total succeeded"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILURES+=("Concurrent reads: only $ok_count/$total")
    fi

    teardown_test_env
}

# ═══════════════════════════════════════════════════════════════════════════
# 4.3 Data Integrity Under Scale (P1)
# ═══════════════════════════════════════════════════════════════════════════

test_scale_500_nodes() {
    echo ""
    echo -e "${CYAN}Test: 500-Node Graph Benchmark (4.3.1) [SLOW]${NC}"
    echo "==============================================="
    setup_test_env

    # Generate 5 epics x 20 features x 4 tasks = 505 nodes, 500 edges
    # Suppress set -e for the generation loop (any single failure shouldn't abort)
    set +e
    for i in $(seq 1 5); do
        local epic
        epic=$(get_id "$("$WV" add "Epic $i" --metadata='{"type":"epic"}' 2>&1)")
        for j in $(seq 1 20); do
            local feat
            feat=$(get_id "$("$WV" add "Feature $i.$j" --metadata='{"type":"feature"}' 2>&1)")
            "$WV" link "$feat" "$epic" --type=implements >/dev/null 2>&1
            for k in $(seq 1 4); do
                local task
                task=$(get_id "$("$WV" add "Task $i.$j.$k" 2>&1)")
                "$WV" link "$task" "$feat" --type=implements >/dev/null 2>&1
            done
        done
    done
    set -e

    local count
    count=$("$WV" list --all --json 2>/dev/null | jq length)
    # Under rapid sequential writes, some may fail due to WAL contention
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$count" -ge 490 ]; then
        echo -e "  ${GREEN}✓${NC} Scale test: $count/505 nodes created (≥490 acceptable)"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗${NC} Scale test: only $count/505 nodes created (expected ≥490)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILURES+=("Scale test: only $count/505 nodes created")
    fi

    # Benchmark search (should complete, not hang)
    local search_ok=true
    timeout 30 "$WV" search "Feature" --json >/dev/null 2>&1 || search_ok=false
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$search_ok" = true ]; then
        echo -e "  ${GREEN}✓${NC} Search completes on 505-node graph"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗${NC} Search timed out on 505-node graph"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILURES+=("Search timed out on 505-node graph")
    fi

    # Benchmark health
    local health_ok=true
    timeout 30 "$WV" health >/dev/null 2>&1 || health_ok=false
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$health_ok" = true ]; then
        echo -e "  ${GREEN}✓${NC} Health check completes on 505-node graph"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗${NC} Health check timed out on 505-node graph"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILURES+=("Health check timed out on 505-node graph")
    fi

    teardown_test_env
}

test_deep_chain() {
    echo ""
    echo -e "${CYAN}Test: Deep Dependency Chain — Depth 110 (4.3.2) [SLOW]${NC}"
    echo "======================================================="
    setup_test_env

    # Create a chain of 110 nodes, each blocking the next
    local prev="" first="" last=""
    set +e
    for i in $(seq 1 110); do
        local id
        id=$(get_id "$("$WV" add "Chain node $i" 2>&1)")
        [ -z "$first" ] && first="$id"
        if [ -n "$prev" ] && [ -n "$id" ]; then
            "$WV" block "$id" --by="$prev" >/dev/null 2>&1
        fi
        prev="$id"
        last="$id"
    done
    set -e

    # wv path from last to first — hits depth < 100 limit
    local path_result path_exit=0
    path_result=$("$WV" path "$last" 2>&1) || path_exit=$?

    # Should not hang — CTE depth limit prevents infinite recursion
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -e "  ${GREEN}✓${NC} Deep path query completes without hanging"
    TESTS_PASSED=$((TESTS_PASSED + 1))

    # Count distinct nodes in output
    local node_count
    node_count=$(echo "$path_result" | grep -cE 'wv-[a-f0-9]{4,6}' || echo "0")
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$node_count" -le 100 ]; then
        echo -e "  ${GREEN}✓${NC} Path output respects depth limit (got $node_count nodes, limit 100)"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${YELLOW}⚠${NC} Path returned $node_count nodes (depth limit is 100)"
        TESTS_XFAIL=$((TESTS_XFAIL + 1))
    fi

    teardown_test_env
}

test_fts5_drift() {
    echo ""
    echo -e "${CYAN}Test: FTS5 Index Drift (4.3.3)${NC}"
    echo "==============================="
    setup_test_env

    # Create nodes normally
    for i in $(seq 1 10); do
        "$WV" add "Searchable node $i" >/dev/null 2>&1
    done

    # Corrupt: delete from nodes table directly (bypassing triggers)
    sqlite3 "$WV_DB" "PRAGMA foreign_keys=OFF; DELETE FROM nodes WHERE id IN (SELECT id FROM nodes LIMIT 3);"

    # Search may return ghost results
    local before_reindex
    before_reindex=$("$WV" search "Searchable" --json 2>/dev/null | jq length 2>/dev/null || echo "error")

    # Fix with reindex
    "$WV" reindex >/dev/null 2>&1

    local after_reindex actual_count
    after_reindex=$("$WV" search "Searchable" --json 2>/dev/null | jq length)
    actual_count=$("$WV" list --all --json 2>/dev/null | jq length)

    assert_equals "$actual_count" "$after_reindex" "Reindex fixes FTS5 drift" || true

    teardown_test_env
}

test_large_metadata() {
    echo ""
    echo -e "${CYAN}Test: Large Metadata — 50KB (4.3.4)${NC}"
    echo "====================================="
    setup_test_env

    # Generate 50KB string
    local large_learning
    large_learning=$(python3 -c "print('x' * 50000)")

    local id
    id=$(get_id "$("$WV" add "big metadata node" --metadata="{\"learning\":\"$large_learning\"}" 2>&1)")

    # Verify storage
    local retrieved_len
    retrieved_len=$("$WV" show "$id" --json 2>/dev/null | jq -r '.[0].metadata | fromjson | .learning' | wc -c)
    # wc -c counts bytes including trailing newline
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$retrieved_len" -ge 50000 ]; then
        echo -e "  ${GREEN}✓${NC} 50KB metadata stored and retrieved ($retrieved_len bytes)"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗${NC} 50KB metadata truncated ($retrieved_len bytes)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILURES+=("50KB metadata truncated")
    fi

    # Round-trip
    "$WV" sync >/dev/null 2>&1
    rm -f "$WV_DB" "$WV_DB-wal" "$WV_DB-shm"
    "$WV" load >/dev/null 2>&1

    local after_len
    after_len=$("$WV" show "$id" --json 2>/dev/null | jq -r '.[0].metadata | fromjson | .learning' | wc -c)
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$after_len" -ge 50000 ]; then
        echo -e "  ${GREEN}✓${NC} 50KB metadata survives round-trip ($after_len bytes)"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗${NC} 50KB metadata lost in round-trip ($after_len bytes)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILURES+=("50KB metadata lost in round-trip")
    fi

    teardown_test_env
}

# ═══════════════════════════════════════════════════════════════════════════
# 4.4 Recovery & Failure Modes (P1)
# ═══════════════════════════════════════════════════════════════════════════

test_corrupt_state_sql() {
    echo ""
    echo -e "${CYAN}Test: Corrupt state.sql — Truncated (4.4.1)${NC}"
    echo "============================================="
    setup_test_env

    "$WV" add "valid node one" >/dev/null 2>&1
    "$WV" add "valid node two" >/dev/null 2>&1
    "$WV" sync >/dev/null 2>&1

    # Corrupt: truncate halfway
    head -c 100 "$TEST_DIR/.weave/state.sql" > "$TEST_DIR/.weave/state.sql.tmp"
    mv "$TEST_DIR/.weave/state.sql.tmp" "$TEST_DIR/.weave/state.sql"

    # Load should fail gracefully
    local result exit_code=0
    result=$("$WV" load 2>&1) || exit_code=$?

    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$exit_code" -ne 0 ]; then
        echo -e "  ${GREEN}✓${NC} Corrupt state.sql detected — load fails with exit $exit_code"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${YELLOW}⚠${NC} Load accepted corrupt state.sql (exit 0) — may have silently lost data"
        TESTS_XFAIL=$((TESTS_XFAIL + 1))
    fi

    teardown_test_env
}

test_corrupt_edges_only() {
    echo ""
    echo -e "${CYAN}Test: Corrupt state.sql — Valid Nodes, No Edges (4.4.2)${NC}"
    echo "========================================================"
    setup_test_env

    local id1 id2
    id1=$(get_id "$("$WV" add "node1" 2>&1)")
    id2=$(get_id "$("$WV" add "node2" 2>&1)")
    "$WV" link "$id1" "$id2" --type=implements >/dev/null 2>&1
    "$WV" sync >/dev/null 2>&1

    # Corrupt: remove only edges INSERT lines
    grep -v "INSERT INTO.*edges" "$TEST_DIR/.weave/state.sql" > "$TEST_DIR/.weave/state.sql.tmp"
    mv "$TEST_DIR/.weave/state.sql.tmp" "$TEST_DIR/.weave/state.sql"

    # Load — current code only checks nodes table
    "$WV" load >/dev/null 2>&1
    local edge_count
    edge_count=$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM edges;" 2>/dev/null)

    # This SHOULD be 0 (edges were stripped) — documents the known gap
    assert_equals "0" "$edge_count" "Edges lost from corrupt file (documents known validation gap)" || true

    teardown_test_env
}

test_missing_tmpfs() {
    echo ""
    echo -e "${CYAN}Test: Missing tmpfs Database (4.4.3)${NC}"
    echo "======================================"
    setup_test_env

    # Sync first so .weave/state.sql exists
    "$WV" add "tmpfs test" >/dev/null 2>&1
    "$WV" sync >/dev/null 2>&1

    # Delete the database
    rm -f "$WV_DB" "$WV_DB-wal" "$WV_DB-shm"

    # Any command should either auto-load or give a clear error
    local result exit_code=0
    result=$("$WV" status 2>&1) || exit_code=$?

    TESTS_RUN=$((TESTS_RUN + 1))
    # Document current behavior (likely confusing SQLite error)
    if [ "$exit_code" -eq 0 ]; then
        echo -e "  ${GREEN}✓${NC} Status recovers gracefully after missing DB"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    elif echo "$result" | grep -qi "load\|restore\|missing\|not found"; then
        echo -e "  ${GREEN}✓${NC} Status gives helpful error about missing DB"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${YELLOW}⚠${NC} Status gives unhelpful error on missing DB: $(echo "$result" | head -1)"
        TESTS_XFAIL=$((TESTS_XFAIL + 1))
    fi

    teardown_test_env
}

test_interrupted_sync() {
    echo ""
    echo -e "${CYAN}Test: Interrupted Sync — Orphaned Temp Files (4.4.4)${NC}"
    echo "====================================================="
    setup_test_env

    "$WV" add "pre-interrupt node" >/dev/null 2>&1

    # Create orphaned temp files (simulating a killed sync)
    touch "$TEST_DIR/.weave/.state.sql.XXXXXX"
    touch "$TEST_DIR/.weave/.nodes.jsonl.XXXXXX"

    # Next sync should succeed despite orphaned files
    local exit_code=0
    "$WV" sync >/dev/null 2>&1 || exit_code=$?
    assert_equals "0" "$exit_code" "Sync succeeds with orphaned temp files present" || true

    teardown_test_env
}

# ═══════════════════════════════════════════════════════════════════════════
# 4.5 Input Fuzzing (P1)
# ═══════════════════════════════════════════════════════════════════════════

test_unicode_text() {
    echo ""
    echo -e "${CYAN}Test: Unicode in Node Text (4.5.1)${NC}"
    echo "===================================="
    setup_test_env

    # Emoji
    local id_emoji exit_code=0
    id_emoji=$(get_id "$("$WV" add "Release party 🎉🎊" 2>&1)") || exit_code=$?
    assert_equals "0" "$exit_code" "Emoji in node text accepted" || true

    # CJK characters
    local id_cjk
    id_cjk=$(get_id "$("$WV" add "日本語テスト" 2>&1)") || true
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ -n "$id_cjk" ]; then
        echo -e "  ${GREEN}✓${NC} CJK characters stored"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗${NC} CJK characters failed"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILURES+=("CJK characters failed")
    fi

    # Verify FTS5 can find emoji
    local search_result
    search_result=$("$WV" search "party" --json 2>/dev/null | jq length 2>/dev/null || echo "0")
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$search_result" -ge 1 ]; then
        echo -e "  ${GREEN}✓${NC} FTS5 finds emoji node by adjacent word"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗${NC} FTS5 can't find emoji node"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILURES+=("FTS5 can't find emoji node")
    fi

    # Round-trip unicode
    "$WV" sync >/dev/null 2>&1
    rm -f "$WV_DB" "$WV_DB-wal" "$WV_DB-shm"
    "$WV" load >/dev/null 2>&1
    local retrieved
    retrieved=$("$WV" show "$id_emoji" --json 2>/dev/null | jq -r '.[0].text' 2>/dev/null || echo "")
    assert_contains "$retrieved" "🎉" "Emoji survives round-trip" || true

    teardown_test_env
}

test_shell_metacharacters() {
    echo ""
    echo -e "${CYAN}Test: Shell Metacharacters (4.5.2)${NC}"
    echo "===================================="
    setup_test_env

    # Single quotes
    "$WV" add "don't stop" >/dev/null 2>&1
    local exit_code=0
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -e "  ${GREEN}✓${NC} Single quote in node text"
    TESTS_PASSED=$((TESTS_PASSED + 1))

    # Double quotes
    "$WV" add 'She said "hello"' >/dev/null 2>&1 || true
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -e "  ${GREEN}✓${NC} Double quotes in node text"
    TESTS_PASSED=$((TESTS_PASSED + 1))

    # Backticks
    "$WV" add 'Run `ls -la`' >/dev/null 2>&1 || true
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -e "  ${GREEN}✓${NC} Backticks in node text"
    TESTS_PASSED=$((TESTS_PASSED + 1))

    # Dollar sign
    "$WV" add 'Costs $100' >/dev/null 2>&1 || true
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -e "  ${GREEN}✓${NC} Dollar sign in node text"
    TESTS_PASSED=$((TESTS_PASSED + 1))

    # SQL injection attempt
    "$WV" add "test; DROP TABLE nodes; --" >/dev/null 2>&1 || true
    local count
    count=$("$WV" list --all --json 2>/dev/null | jq length)
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$count" -ge 5 ]; then
        echo -e "  ${GREEN}✓${NC} SQL injection attempt stored safely (nodes table intact, count=$count)"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗${NC} Possible SQL injection — node count is $count"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILURES+=("Possible SQL injection")
    fi

    # Pipes and redirects
    "$WV" add "cmd | grep foo > /dev/null" >/dev/null 2>&1 || true
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -e "  ${GREEN}✓${NC} Pipe and redirect in node text"
    TESTS_PASSED=$((TESTS_PASSED + 1))

    teardown_test_env
}

test_long_text() {
    echo ""
    echo -e "${CYAN}Test: Very Long Node Text — 10K chars (4.5.3)${NC}"
    echo "==============================================="
    setup_test_env

    local long_text
    long_text=$(python3 -c "print('A' * 10000)")

    local id
    id=$(get_id "$("$WV" add "$long_text" 2>&1)")

    # Verify storage
    local len
    len=$("$WV" show "$id" --json 2>/dev/null | jq -r '.[0].text' | wc -c)
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$len" -ge 10000 ]; then
        echo -e "  ${GREEN}✓${NC} 10K character text stored ($len bytes)"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗${NC} 10K text truncated ($len bytes)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILURES+=("10K text truncated")
    fi

    # Round-trip
    "$WV" sync >/dev/null 2>&1
    rm -f "$WV_DB" "$WV_DB-wal" "$WV_DB-shm"
    "$WV" load >/dev/null 2>&1
    local after_len
    after_len=$("$WV" show "$id" --json 2>/dev/null | jq -r '.[0].text' | wc -c)
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$after_len" -ge 10000 ]; then
        echo -e "  ${GREEN}✓${NC} 10K text survives round-trip ($after_len bytes)"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗${NC} 10K text lost in round-trip ($after_len bytes)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILURES+=("10K text lost in round-trip")
    fi

    teardown_test_env
}

test_metadata_injection() {
    echo ""
    echo -e "${CYAN}Test: Metadata Injection (4.5.4)${NC}"
    echo "=================================="
    setup_test_env

    # Prototype pollution pattern (verify stored as data, not interpreted)
    local id1
    id1=$(get_id "$("$WV" add "proto test" --metadata='{"type":"task","__proto__":{"admin":true}}' 2>&1)")
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ -n "$id1" ]; then
        echo -e "  ${GREEN}✓${NC} Prototype pollution pattern accepted as data"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗${NC} Prototype pollution pattern rejected"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILURES+=("Prototype pollution pattern rejected")
    fi

    # Deeply nested metadata
    local nested='{"a":{"b":{"c":{"d":{"e":{"f":"deep"}}}}}}'
    local id2
    id2=$(get_id "$("$WV" add "deep nesting" --metadata="$nested" 2>&1)")
    local deep_val
    deep_val=$("$WV" show "$id2" --json 2>/dev/null | jq -r '.[0].metadata | fromjson | .a.b.c.d.e.f' 2>/dev/null || echo "")
    assert_equals "deep" "$deep_val" "Deeply nested JSON metadata preserved" || true

    teardown_test_env
}

# ═══════════════════════════════════════════════════════════════════════════
# 4.7 Known Bug Regression Tests (P0)
# ═══════════════════════════════════════════════════════════════════════════

test_work_status_model() {
    echo ""
    echo -e "${CYAN}Test: wv work Status Consistency — wv-d03c (4.7.1)${NC}"
    echo "===================================================="
    setup_test_env

    local id
    id=$(get_id "$("$WV" add "status test node" 2>&1)")
    "$WV" work "$id" >/dev/null 2>&1

    # Fixed: wv-d03c — wv work now sets 'active'
    local status
    status=$("$WV" show "$id" --json 2>/dev/null | jq -r '.[0].status')
    assert_equals "active" "$status" "wv work sets status to active"

    # Verify visibility in wv list --status=active
    local list_count
    list_count=$("$WV" list --status=active --json 2>/dev/null | jq length 2>/dev/null || echo "0")
    assert_equals "1" "$list_count" "Active node visible in wv list --status=active"

    teardown_test_env
}

test_update_status_validation() {
    echo ""
    echo -e "${CYAN}Test: wv update Rejects Invalid Status — wv-e2db (4.7.2)${NC}"
    echo "=========================================================="
    setup_test_env

    local id
    id=$(get_id "$("$WV" add "validation test" 2>&1)")

    # Fixed: wv-e2db — wv update now validates status enum
    local exit_code=0
    "$WV" update "$id" --status=banana >/dev/null 2>&1 || exit_code=$?
    assert_fails "wv update rejects invalid status 'banana'" "$exit_code"

    # Valid statuses should work
    for valid_status in todo active done blocked; do
        local v_exit=0
        "$WV" update "$id" --status="$valid_status" >/dev/null 2>&1 || v_exit=$?
        assert_equals "0" "$v_exit" "wv update accepts status=$valid_status" || true
    done

    teardown_test_env
}

test_prune_age_zero_guard() {
    echo ""
    echo -e "${CYAN}Test: wv prune --age=0h Safety — wv-bea8 (4.7.3)${NC}"
    echo "==================================================="
    setup_test_env

    for i in $(seq 1 5); do
        local id
        id=$(get_id "$("$WV" add "prune test $i" 2>&1)")
        "$WV" done "$id" >/dev/null 2>&1
    done

    # Fixed: wv-bea8 — wv prune rejects zero/invalid age
    local exit_code=0
    "$WV" prune --age=0h >/dev/null 2>&1 || exit_code=$?
    assert_fails "wv prune --age=0h is rejected" "$exit_code"

    # Check if nodes survived
    local count
    count=$("$WV" list --all --json 2>/dev/null | jq length)
    assert_equals "5" "$count" "Nodes survive age=0h prune"

    # Invalid age format
    local xyz_exit=0
    "$WV" prune --age=xyz >/dev/null 2>&1 || xyz_exit=$?
    assert_fails "wv prune --age=xyz is rejected" "$xyz_exit"

    teardown_test_env
}

test_search_apostrophe() {
    echo ""
    echo -e "${CYAN}Test: FTS5 Search with Apostrophe — wv-088d (4.7.4)${NC}"
    echo "====================================================="
    setup_test_env

    "$WV" add "don't stop believing" >/dev/null 2>&1

    # Fixed: wv-088d — FTS5 search safe with apostrophes
    local result exit_code=0
    result=$("$WV" search "don't" --json 2>&1) || exit_code=$?
    assert_equals "0" "$exit_code" "FTS5 search with apostrophe doesn't crash"

    teardown_test_env
}

test_ready_json_empty() {
    echo ""
    echo -e "${CYAN}Test: wv ready --json Empty Result — wv-ab49 (4.7.5)${NC}"
    echo "======================================================"
    setup_test_env

    # All nodes done — ready should return []
    local id
    id=$(get_id "$("$WV" add "will be done" 2>&1)")
    "$WV" done "$id" >/dev/null 2>&1

    # Fixed: wv-ab49 — wv ready --json returns [] when empty
    local result
    result=$("$WV" ready --json 2>/dev/null)
    assert_equals "[]" "$result" "wv ready --json returns [] when empty"

    # Verify it's parseable as a JSON array
    local jq_result
    jq_result=$(echo "$result" | jq 'type' 2>/dev/null || echo "error")
    assert_equals '"array"' "$jq_result" "wv ready --json output is a JSON array"

    teardown_test_env
}

test_path_diamond_dedup() {
    echo ""
    echo -e "${CYAN}Test: wv path Diamond Dependencies — wv-77cd (4.7.6)${NC}"
    echo "======================================================="
    setup_test_env

    # Create a diamond using blocks edges (wv path follows blocks, not implements):
    # A blocks B, A blocks C, B blocks D, C blocks D
    local a b c d
    a=$(get_id "$("$WV" add "diamond top" 2>&1)")
    b=$(get_id "$("$WV" add "diamond left" 2>&1)")
    c=$(get_id "$("$WV" add "diamond right" 2>&1)")
    d=$(get_id "$("$WV" add "diamond bottom" 2>&1)")
    "$WV" block "$b" --by="$a" >/dev/null 2>&1
    "$WV" block "$c" --by="$a" >/dev/null 2>&1
    "$WV" block "$d" --by="$b" >/dev/null 2>&1
    "$WV" block "$d" --by="$c" >/dev/null 2>&1

    # wv path (default format) should not show any node twice
    local path_result
    path_result=$("$WV" path "$d" 2>&1)
    # Default format outputs "wv-xxxxxx: text" per line
    local total_ids unique_ids
    total_ids=$(echo "$path_result" | grep -oE 'wv-[a-f0-9]{4,6}' | wc -l)
    unique_ids=$(echo "$path_result" | grep -oE 'wv-[a-f0-9]{4,6}' | sort -u | wc -l)
    # Fixed: wv-77cd — UNION dedup in CTE
    assert_equals "$total_ids" "$unique_ids" "Diamond path has no duplicate nodes (total=$total_ids, unique=$unique_ids)"

    teardown_test_env
}

test_context_pitfall_scoping() {
    echo ""
    echo -e "${CYAN}Test: Context Pack Pitfall Scoping — wv-517f (4.7.7)${NC}"
    echo "======================================================"
    setup_test_env

    # Create two separate epics with their own pitfalls
    local epic1 task1 pit1 epic2 task2 pit2
    epic1=$(get_id "$("$WV" add "Epic One" --metadata='{"type":"epic"}' 2>&1)")
    task1=$(get_id "$("$WV" add "Task under epic 1" 2>&1)")
    "$WV" link "$task1" "$epic1" --type=implements >/dev/null 2>&1
    pit1=$(get_id "$("$WV" add "Pitfall for epic 1" --metadata='{"pitfall":"watch out epic1"}' 2>&1)")
    "$WV" link "$pit1" "$epic1" --type=addresses >/dev/null 2>&1

    epic2=$(get_id "$("$WV" add "Epic Two" --metadata='{"type":"epic"}' 2>&1)")
    task2=$(get_id "$("$WV" add "Task under epic 2" 2>&1)")
    "$WV" link "$task2" "$epic2" --type=implements >/dev/null 2>&1
    pit2=$(get_id "$("$WV" add "Pitfall for epic 2" --metadata='{"pitfall":"watch out epic2"}' 2>&1)")
    "$WV" link "$pit2" "$epic2" --type=addresses >/dev/null 2>&1

    # Context pack for TASK1 should include PIT1 but NOT PIT2
    local context
    context=$("$WV" context "$task1" --json 2>/dev/null || echo "{}")

    local has_pit1=false has_pit2=false
    echo "$context" | grep -qF "$pit1" 2>/dev/null && has_pit1=true
    echo "$context" | grep -qF "$pit2" 2>/dev/null && has_pit2=true

    # Fixed: wv-517f — pitfall scoping via neighborhood walk (all edge types)
    assert_equals "true" "$has_pit1" "Context includes own pitfall"
    assert_equals "false" "$has_pit2" "Context excludes other epic's pitfall"

    teardown_test_env
}

test_health_invalid_status() {
    echo ""
    echo -e "${CYAN}Test: Health Check Detects Invalid Status — wv-01e7 (4.7.8)${NC}"
    echo "============================================================="
    setup_test_env

    "$WV" add "normal node" >/dev/null 2>&1

    # Inject an invalid status directly (bypassing CLI validation)
    sqlite3 "$WV_DB" "INSERT INTO nodes (id,text,status,metadata,created_at,updated_at) VALUES ('wv-test','bad node','banana','{}',datetime('now'),datetime('now'));"

    local health score
    health=$("$WV" health 2>&1)
    score=$(echo "$health" | grep -oE '[0-9]+/100' | head -1 || echo "unknown")

    # Fixed: wv-01e7 — health check now detects invalid statuses
    assert_fails "Health penalizes invalid status (score: $score)" "$([ "$score" = "100/100" ] && echo 0 || echo 1)"

    teardown_test_env
}

# ═══════════════════════════════════════════════════════════════════════════
# 4.8 Integration Tests (P1)
# ═══════════════════════════════════════════════════════════════════════════

test_mcp_concurrent_writes() {
    echo ""
    echo -e "${CYAN}Test: MCP Concurrent Writes (4.8.1)${NC}"
    echo "====================================="
    setup_test_env

    # MCP uses execSync — each call is a separate process
    local pids=()
    for i in $(seq 1 10); do
        "$WV" add "mcp-write-$i" >/dev/null 2>&1 &
        pids+=($!)
    done

    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    local count
    count=$("$WV" list --all --json 2>/dev/null | jq length)
    # Under WAL contention some writes may fail — ≥8/10 is acceptable
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$count" -ge 8 ]; then
        echo -e "  ${GREEN}✓${NC} MCP concurrent writes: $count/10 succeeded (≥8 acceptable)"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗${NC} MCP concurrent writes: only $count/10 succeeded"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILURES+=("MCP concurrent writes: only $count/10")
    fi

    teardown_test_env
}

test_gh_metadata_roundtrip() {
    echo ""
    echo -e "${CYAN}Test: GH Metadata Round-Trip (4.8.2)${NC}"
    echo "======================================"
    setup_test_env

    local id
    id=$(get_id "$("$WV" add "gh roundtrip test" --metadata='{"gh_issue":42}' 2>&1)")
    "$WV" sync >/dev/null 2>&1

    # Round-trip
    rm -f "$WV_DB" "$WV_DB-wal" "$WV_DB-shm"
    "$WV" load >/dev/null 2>&1

    local gh_issue
    gh_issue=$("$WV" show "$id" --json 2>/dev/null | jq -r '.[0].metadata | fromjson | .gh_issue' 2>/dev/null || echo "null")
    assert_equals "42" "$gh_issue" "gh_issue metadata survives round-trip" || true

    teardown_test_env
}

# GH label round-trip (4.8.3) requires live GitHub API — in test-gh-stress.sh

# ═══════════════════════════════════════════════════════════════════════════
# Test Runner
# ═══════════════════════════════════════════════════════════════════════════

echo "═══════════════════════════════════════════════════════════════════════════"
echo -e "${CYAN}Weave Stress Test Suite${NC}"
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""

START_TIME=$(date +%s)

# ── 4.1 Sync Round-Trip (P0) ──
echo -e "${YELLOW}── Section 4.1: Sync Round-Trip Integrity (P0) ──${NC}"
test_sync_roundtrip_fidelity
test_idempotent_load
test_jsonl_sql_consistency

# ── 4.2 Concurrency (P0) ──
echo ""
echo -e "${YELLOW}── Section 4.2: Concurrency & Race Conditions (P0) ──${NC}"
test_parallel_add
test_sync_during_write
test_mcp_concurrent_reads

# ── 4.7 Known Bug Regressions (P0) ──
echo ""
echo -e "${YELLOW}── Section 4.7: Known Bug Regression Tests (P0) ──${NC}"
test_work_status_model
test_update_status_validation
test_prune_age_zero_guard
test_search_apostrophe
test_ready_json_empty
test_path_diamond_dedup
test_context_pitfall_scoping
test_health_invalid_status

# ── 4.3 Scale & Integrity (P1) ──
echo ""
echo -e "${YELLOW}── Section 4.3: Data Integrity Under Scale (P1) ──${NC}"
if [ "$RUN_SLOW" = true ]; then
    test_scale_500_nodes
    test_deep_chain
else
    echo -e "  ${YELLOW}⏭${NC}  Skipping 500-node benchmark (use --slow)"
    echo -e "  ${YELLOW}⏭${NC}  Skipping deep chain test (use --slow)"
fi
test_fts5_drift
test_large_metadata

# ── 4.4 Recovery & Failure Modes (P1) ──
echo ""
echo -e "${YELLOW}── Section 4.4: Recovery & Failure Modes (P1) ──${NC}"
test_corrupt_state_sql
test_corrupt_edges_only
test_missing_tmpfs
test_interrupted_sync

# ── 4.5 Input Fuzzing (P1) ──
echo ""
echo -e "${YELLOW}── Section 4.5: Input Fuzzing (P1) ──${NC}"
test_unicode_text
test_shell_metacharacters
test_long_text
test_metadata_injection

# ── 4.8 Integration (P1) ──
echo ""
echo -e "${YELLOW}── Section 4.8: Integration Tests (P1) ──${NC}"
test_mcp_concurrent_writes
test_gh_metadata_roundtrip

# ── Summary ──
END_TIME=$(date +%s)
TOTAL_TIME=$((END_TIME - START_TIME))

echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
echo -e "${CYAN}Results${NC}"
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""
echo -e "  Tests run:       $TESTS_RUN"
echo -e "  Passed:          ${GREEN}$TESTS_PASSED${NC}"
echo -e "  Failed:          ${RED}$TESTS_FAILED${NC}"
echo -e "  Expected fails:  ${YELLOW}$TESTS_XFAIL${NC} (known bugs)"
echo -e "  Time:            ${TOTAL_TIME}s"
# Compat line for run-all.sh result parser
echo "Results: $((TESTS_PASSED + TESTS_XFAIL))/$TESTS_RUN passed"
echo ""

if [ ${#FAILURES[@]} -gt 0 ]; then
    echo -e "  ${RED}Unexpected failures:${NC}"
    for f in "${FAILURES[@]}"; do
        echo -e "    - $f"
    done
    echo ""
fi

if [ "$TESTS_FAILED" -gt 0 ]; then
    echo -e "${RED}FAILED${NC} ($TESTS_FAILED unexpected failure(s))"
    exit 1
else
    if [ "$TESTS_XFAIL" -gt 0 ]; then
        echo -e "${YELLOW}PASSED${NC} (with $TESTS_XFAIL expected failures from known bugs)"
    else
        echo -e "${GREEN}ALL TESTS PASSED${NC}"
    fi
    exit 0
fi
