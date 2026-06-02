#!/usr/bin/env bash
# test-graph.sh — Test Weave graph commands
#
# Tests: block, link, resolve, related, edges, path
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

# Test environment
TEST_DIR="/tmp/wv-graph-test-$$"
export WV_HOT_ZONE="$TEST_DIR"
export WV_DB="$TEST_DIR/brain.db"
export WV_REQUIRE_LEARNING=0
export WV_PROJECT_DIR="$TEST_DIR"

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
    export WV_PROJECT_DIR="$TEST_DIR"
    cd "$TEST_DIR"
    git init -q
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

    if echo "$haystack" | grep -qF "$needle"; then
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

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"

    TESTS_RUN=$((TESTS_RUN + 1))

    if ! echo "$haystack" | grep -qF "$needle"; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Expected NOT to find: $needle"
        echo "  In: $haystack"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

assert_jq_true() {
    local json_input="$1"
    local jq_expr="$2"
    local message="$3"

    TESTS_RUN=$((TESTS_RUN + 1))

    if printf '%s' "$json_input" | jq -e "$jq_expr" >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}✗${NC} $message"
        echo "  jq expr failed: $jq_expr"
        echo "  JSON: $json_input"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

assert_success() {
    local message="$1"
    shift

    TESTS_RUN=$((TESTS_RUN + 1))

    if "$@" >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Command failed: $*"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

assert_fails() {
    local message="$1"
    shift

    TESTS_RUN=$((TESTS_RUN + 1))

    if ! "$@" >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Expected command to fail: $*"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

# ============================================================================
# Test: block
# ============================================================================
test_block() {
    echo ""
    echo "Test: wv block"
    echo "=============="

    setup_test_env

    # Create two nodes
    local blocker target
    blocker=$("$WV" add "Blocker task" --force 2>&1 | tail -1)
    target=$("$WV" add "Target task" --force 2>&1 | tail -1)

    # Block target by blocker
    local output
    output=$("$WV" block "$target" --by="$blocker" 2>&1)
    assert_contains "$output" "blocked by" "block outputs confirmation"

    # Verify target status changed to blocked
    local status
    status=$("$WV" show "$target" --json 2>&1)
    assert_contains "$status" '"status":"blocked"' "block sets status to blocked"

    # Verify blocker appears in ready list (not blocked)
    output=$("$WV" ready 2>&1)
    assert_contains "$output" "$blocker" "blocker is in ready list"
    assert_not_contains "$output" "$target" "blocked node not in ready list"

    # Block requires both arguments
    assert_fails "block requires target ID" "$WV" block
    assert_fails "block requires --by argument" "$WV" block "$target"

    # Block prevents self-blocking
    assert_fails "block prevents self-blocking" "$WV" block "$blocker" --by="$blocker"

    # Block prevents circular blocking
    assert_fails "block prevents circular blocking" "$WV" block "$blocker" --by="$target"
}

# ============================================================================
# Test: link
# ============================================================================
test_link() {
    echo ""
    echo "Test: wv link"
    echo "============="

    setup_test_env

    # Create nodes
    local from to
    from=$("$WV" add "Source node" --force 2>&1 | tail -1)
    to=$("$WV" add "Target node" --force 2>&1 | tail -1)

    # Create a link
    local output
    output=$("$WV" link "$from" "$to" --type=implements 2>&1)
    assert_contains "$output" "Linked" "link outputs confirmation"
    assert_contains "$output" "implements" "link shows edge type"

    # Verify link exists via edges command
    output=$("$WV" edges "$from" 2>&1)
    assert_contains "$output" "$to" "link appears in edges"
    assert_contains "$output" "implements" "edge type appears in edges"

    # Link with weight
    output=$("$WV" link "$from" "$to" --type=relates_to --weight=0.5 2>&1)
    assert_contains "$output" "weight: 0.5" "link shows custom weight"

    # Link requires both nodes
    assert_fails "link requires from ID" "$WV" link
    assert_fails "link requires to ID" "$WV" link "$from"

    # Link requires --type
    assert_fails "link requires --type argument" "$WV" link "$from" "$to"

    # Link validates edge type
    assert_fails "link rejects invalid edge type" "$WV" link "$from" "$to" --type=invalid

    # Link validates nodes exist
    assert_fails "link fails for non-existent source" "$WV" link "wv-0000" "$to" --type=relates_to
    assert_fails "link fails for non-existent target" "$WV" link "$from" "wv-0000" --type=relates_to

    # Link validates weight range
    assert_fails "link rejects weight > 1" "$WV" link "$from" "$to" --type=relates_to --weight=1.5
    assert_fails "link rejects negative weight" "$WV" link "$from" "$to" --type=relates_to --weight=-0.5
}

# ============================================================================
# Test: resolve
# ============================================================================
test_resolve() {
    echo ""
    echo "Test: wv resolve"
    echo "================"

    setup_test_env

    # Create contradicting nodes
    local node1 node2
    node1=$("$WV" add "Approach A" --force 2>&1 | tail -1)
    node2=$("$WV" add "Approach B" --force 2>&1 | tail -1)

    # Create contradiction edge
    "$WV" link "$node1" "$node2" --type=contradicts >/dev/null 2>&1

    # Resolve with winner
    local output
    output=$("$WV" resolve "$node1" "$node2" --winner="$node1" --rationale="A is better" 2>&1)
    assert_contains "$output" "supersedes" "resolve --winner creates supersedes"
    assert_contains "$output" "$node1" "resolve shows winner"

    # Verify loser is marked done
    local loser_status
    loser_status=$("$WV" show "$node2" --json 2>&1)
    assert_contains "$loser_status" '"status":"done"' "resolve marks loser as done"

    # Test merge resolution
    setup_test_env
    node1=$("$WV" add "Idea X" --force 2>&1 | tail -1)
    node2=$("$WV" add "Idea Y" --force 2>&1 | tail -1)
    "$WV" link "$node1" "$node2" --type=contradicts >/dev/null 2>&1

    output=$("$WV" resolve "$node1" "$node2" --merge 2>&1)
    assert_contains "$output" "merged" "resolve --merge creates merged node"

    # Both original nodes should be done
    local n1_status n2_status
    n1_status=$("$WV" show "$node1" --json 2>&1)
    n2_status=$("$WV" show "$node2" --json 2>&1)
    assert_contains "$n1_status" '"status":"done"' "merge marks node1 done"
    assert_contains "$n2_status" '"status":"done"' "merge marks node2 done"

    # Test defer resolution
    setup_test_env
    node1=$("$WV" add "Option 1" --force 2>&1 | tail -1)
    node2=$("$WV" add "Option 2" --force 2>&1 | tail -1)
    "$WV" link "$node1" "$node2" --type=contradicts >/dev/null 2>&1

    output=$("$WV" resolve "$node1" "$node2" --defer 2>&1)
    assert_contains "$output" "deferred" "resolve --defer works"
    assert_contains "$output" "related" "defer converts to relates_to"

    # Resolve requires mode
    setup_test_env
    node1=$("$WV" add "A" --force 2>&1 | tail -1)
    node2=$("$WV" add "B" --force 2>&1 | tail -1)
    assert_fails "resolve requires resolution mode" "$WV" resolve "$node1" "$node2"

    # Winner must be one of the nodes
    assert_fails "resolve requires valid winner" "$WV" resolve "$node1" "$node2" --winner="wv-0000"
}

# ============================================================================
# Test: related
# ============================================================================
test_related() {
    echo ""
    echo "Test: wv related"
    echo "================"

    setup_test_env

    # Create nodes with relationships
    local epic feature1 feature2
    epic=$("$WV" add "Epic" --force 2>&1 | tail -1)
    feature1=$("$WV" add "Feature 1" --force 2>&1 | tail -1)
    feature2=$("$WV" add "Feature 2" --force 2>&1 | tail -1)

    # Create edges
    "$WV" link "$feature1" "$epic" --type=implements >/dev/null 2>&1
    "$WV" link "$feature2" "$epic" --type=implements >/dev/null 2>&1
    "$WV" link "$feature1" "$feature2" --type=relates_to >/dev/null 2>&1

    # Related shows all relationships
    local output
    output=$("$WV" related "$epic" 2>&1)
    assert_contains "$output" "$feature1" "related shows feature1"
    assert_contains "$output" "$feature2" "related shows feature2"

    # Related with --type filter
    output=$("$WV" related "$epic" --type=implements 2>&1)
    assert_contains "$output" "implements" "related --type filters by type"

    # Related with --direction filter
    output=$("$WV" related "$feature1" --direction=outbound 2>&1)
    assert_contains "$output" "$epic" "related --direction=outbound shows targets"

    output=$("$WV" related "$epic" --direction=inbound 2>&1)
    assert_contains "$output" "$feature1" "related --direction=inbound shows sources"

    # Related --json
    output=$("$WV" related "$epic" --json 2>&1)
    assert_contains "$output" "[" "related --json outputs JSON array"

    # Related requires node ID
    assert_fails "related requires node ID" "$WV" related

    # Related fails for non-existent node
    assert_fails "related fails for non-existent node" "$WV" related "wv-0000"
}

# ============================================================================
# Test: edges
# ============================================================================
test_edges() {
    echo ""
    echo "Test: wv edges"
    echo "=============="

    setup_test_env

    # Create nodes with edges
    local node1 node2 node3
    node1=$("$WV" add "Node 1" --force 2>&1 | tail -1)
    node2=$("$WV" add "Node 2" --force 2>&1 | tail -1)
    node3=$("$WV" add "Node 3" --force 2>&1 | tail -1)

    # Create various edges
    "$WV" link "$node1" "$node2" --type=implements >/dev/null 2>&1
    "$WV" link "$node1" "$node3" --type=relates_to >/dev/null 2>&1
    "$WV" block "$node2" --by="$node3" >/dev/null 2>&1

    # Edges shows all edges for a node
    local output
    output=$("$WV" edges "$node1" 2>&1)
    assert_contains "$output" "$node2" "edges shows target node"
    assert_contains "$output" "implements" "edges shows edge type"
    assert_contains "$output" "relates_to" "edges shows multiple types"

    # Edges with --type filter
    output=$("$WV" edges "$node1" --type=implements 2>&1)
    assert_contains "$output" "implements" "edges --type filters results"
    assert_not_contains "$output" "relates_to" "edges --type excludes other types"

    # Edges --json
    output=$("$WV" edges "$node1" --json 2>&1)
    assert_contains "$output" "[" "edges --json outputs JSON"

    # Edges requires node ID
    assert_fails "edges requires node ID" "$WV" edges

    # Edges fails for non-existent node
    assert_fails "edges fails for non-existent node" "$WV" edges "wv-0000"

    # Edges validates edge type
    assert_fails "edges rejects invalid edge type" "$WV" edges "$node1" --type=invalid
}

# ============================================================================
# Test: path
# ============================================================================
test_path() {
    echo ""
    echo "Test: wv path"
    echo "============="

    setup_test_env

    # Create a dependency chain: task <- feature <- epic
    local epic feature task
    epic=$("$WV" add "Epic" --force 2>&1 | tail -1)
    feature=$("$WV" add "Feature" --force 2>&1 | tail -1)
    task=$("$WV" add "Task" --force 2>&1 | tail -1)

    # Create blocking edges (emulates dependency chain)
    "$WV" block "$feature" --by="$epic" >/dev/null 2>&1
    "$WV" block "$task" --by="$feature" >/dev/null 2>&1

    # Path shows ancestry chain
    local output
    output=$("$WV" path "$task" 2>&1)
    assert_contains "$output" "Epic" "path includes root"
    assert_contains "$output" "Feature" "path includes intermediate"
    assert_contains "$output" "Task" "path includes leaf"

    # Path --format=chain shows as arrows
    output=$("$WV" path "$task" --format=chain 2>&1)
    assert_contains "$output" "→" "path --format=chain uses arrows"

    # Path requires node ID
    assert_fails "path requires node ID" "$WV" path

    # Path fails for non-existent node
    assert_fails "path fails for non-existent node" "$WV" path "wv-0000"
}

# ============================================================================
# Test: impact
# ============================================================================
test_impact() {
    echo ""
    echo "Test: wv impact"
    echo "==============="

    # --- fixture 1: single seed, forward ---
    setup_test_env
    local seed dep1
    seed=$("$WV" add "Seed task" --force 2>&1 | tail -1)
    dep1=$("$WV" add "Dep of seed" --force 2>&1 | tail -1)
    "$WV" block "$dep1" --by="$seed" >/dev/null 2>&1

    local out
    out=$("$WV" impact "$seed" 2>&1)
    assert_contains "$out" "Dep of seed" "single-seed: forward traversal finds dep"
    assert_contains "$out" "impacted" "single-seed: summary line present"

    # --- fixture 2: multi-seed ---
    setup_test_env
    local s1 s2 dep2
    s1=$("$WV" add "Seed 1" --force 2>&1 | tail -1)
    s2=$("$WV" add "Seed 2" --force 2>&1 | tail -1)
    dep2=$("$WV" add "Shared dep" --force 2>&1 | tail -1)
    "$WV" block "$dep2" --by="$s1" >/dev/null 2>&1
    "$WV" block "$dep2" --by="$s2" >/dev/null 2>&1

    out=$("$WV" impact "$s1" "$s2" 2>&1)
    assert_contains "$out" "Shared dep" "multi-seed: shared dep found"

    # --- fixture 3: cycle guard ---
    setup_test_env
    local ca cb
    ca=$("$WV" add "Cycle A" --force 2>&1 | tail -1)
    cb=$("$WV" add "Cycle B" --force 2>&1 | tail -1)
    "$WV" block "$cb" --by="$ca" >/dev/null 2>&1
    "$WV" link "$ca" "$cb" --type=implements >/dev/null 2>&1

    out=$("$WV" impact "$ca" 2>&1)
    assert_contains "$out" "impacted" "cycle: completes without infinite loop"

    # --- fixture 4: archived-seed error ---
    setup_test_env
    assert_fails "archived (nonexistent) seed: impact errors" "$WV" impact "wv-dead00"

    # --- fixture 5: done intermediate is transparent ---
    setup_test_env
    local root mid leaf
    root=$("$WV" add "Root todo" --force 2>&1 | tail -1)
    mid=$("$WV" add "Mid done" --force 2>&1 | tail -1)
    leaf=$("$WV" add "Leaf todo" --force 2>&1 | tail -1)
    "$WV" block "$mid" --by="$root" >/dev/null 2>&1
    "$WV" block "$leaf" --by="$mid" >/dev/null 2>&1
    "$WV" done "$mid" --learning="decision: test" >/dev/null 2>&1

    out=$("$WV" impact "$root" --include-done 2>&1)
    assert_contains "$out" "Leaf todo" "done-intermediate: leaf reachable via done mid with --include-done"

    # --- fixture 6: done seed + fwd direction → error ---
    setup_test_env
    local dseed dchild
    dseed=$("$WV" add "Done seed" --force 2>&1 | tail -1)
    dchild=$("$WV" add "Child of done" --force 2>&1 | tail -1)
    "$WV" block "$dchild" --by="$dseed" >/dev/null 2>&1
    "$WV" done "$dseed" --learning="decision: test" >/dev/null 2>&1

    assert_fails "done-seed+fwd: errors on done seed with default direction" "$WV" impact "$dseed"

    out=$("$WV" impact "$dseed" --direction=rev 2>&1)
    assert_success "done-seed+rev: succeeds with --direction=rev" "$WV" impact "$dseed" --direction=rev

    # --- fixture 7: contradicts edge excluded from traversal ---
    setup_test_env
    local base contra
    base=$("$WV" add "Base node" --force 2>&1 | tail -1)
    contra=$("$WV" add "Contradicts node" --force 2>&1 | tail -1)
    "$WV" link "$base" "$contra" --type=contradicts >/dev/null 2>&1

    out=$("$WV" impact "$base" 2>&1)
    assert_not_contains "$out" "Contradicts node" "contradicts-edge: node excluded from traversal"

    # --- fixture 8: file-to-test map (--json returns affected_suites) ---
    setup_test_env
    local fnode
    fnode=$("$WV" add "File-mapped node" --force 2>&1 | tail -1)
    # inject touched_files into metadata
    "$WV" update "$fnode" --metadata='{"touched_files":["scripts/cmd/wv-cmd-graph.sh"]}' >/dev/null 2>&1
    # create a test-map.conf so _impact_suites_for_files has something to read
    mkdir -p "$TEST_DIR/.weave"
    printf '[map]\nscripts/cmd/wv-cmd-graph.sh = tests/test-graph.sh\n' > "$TEST_DIR/.weave/test-map.conf"

    local dep_f
    dep_f=$("$WV" add "Dep for file node" --force 2>&1 | tail -1)
    "$WV" block "$dep_f" --by="$fnode" >/dev/null 2>&1
    "$WV" update "$dep_f" --metadata='{"touched_files":["scripts/cmd/wv-cmd-graph.sh"]}' >/dev/null 2>&1

    # quality fixture for --quality path: one scanned file + git stats
    local quality_db
    quality_db="$TEST_DIR/quality.db"
    sqlite3 "$quality_db" <<'SQL'
CREATE TABLE IF NOT EXISTS scan_meta (
    id INTEGER PRIMARY KEY,
    scanned_at TEXT NOT NULL,
    git_head TEXT NOT NULL,
    files_count INTEGER,
    duration_ms INTEGER,
    scanner_version TEXT DEFAULT '',
    bash_cc_backend TEXT DEFAULT 'regex',
    ts_cc_backend TEXT DEFAULT 'unavailable'
);
CREATE TABLE IF NOT EXISTS files (
    path TEXT NOT NULL,
    scan_id INTEGER NOT NULL,
    language TEXT,
    loc INTEGER,
    complexity REAL,
    functions INTEGER,
    max_nesting INTEGER,
    avg_fn_len REAL,
    essential_complexity REAL,
    indent_sd REAL,
    category TEXT DEFAULT 'production',
    PRIMARY KEY(path, scan_id)
);
CREATE TABLE IF NOT EXISTS git_stats (
    path TEXT PRIMARY KEY,
    churn INTEGER,
    authors INTEGER,
    age_days INTEGER,
    hotspot REAL,
    ownership_fraction REAL,
    minor_contributors INTEGER
);
INSERT INTO scan_meta(id, scanned_at, git_head, files_count, duration_ms) VALUES
    (1, '2026-05-28T00:00:00', 'quality-fixture-head', 1, 100);
INSERT INTO files(
    path, scan_id, language, loc, complexity, functions,
    max_nesting, avg_fn_len, essential_complexity, indent_sd, category
) VALUES
    ('scripts/cmd/wv-cmd-graph.sh', 1, 'sh', 120, 23.0, 6, 2, 12.0, 1.0, 1.5, 'production');
INSERT INTO git_stats(path, churn, authors, age_days, hotspot, ownership_fraction, minor_contributors) VALUES
    ('scripts/cmd/wv-cmd-graph.sh', 11, 2, 10, 0.75, 0.9, 0);
SQL

    local jout
    jout=$("$WV" impact "$fnode" --json 2>&1)
    assert_contains "$jout" "affected_suites" "file-to-test: --json output has affected_suites key"
    assert_contains "$jout" "test-graph.sh" "file-to-test: correct suite mapped from touched_files"
    assert_jq_true "$jout" '.impacted | length > 0' "risk: impacted list present"
    assert_jq_true "$jout" '.impacted[0] | has("risk_score") and has("risk_factors")' "risk: risk fields present in impacted node"
    assert_jq_true "$jout" '.impacted[0].risk_score >= 0 and .impacted[0].risk_score <= 1' "risk: risk_score bounded to [0,1]"
    assert_jq_true "$jout" '.impacted[0].risk_factors.blocks_count >= 0 and .impacted[0].risk_factors.blocks_count <= 0.3' "risk: blocks_count contribution bounded"
    assert_jq_true "$jout" '.impacted[0].risk_factors.missing_criteria == 0.25' "risk: missing_criteria contributes 0.25 when done_criteria absent"
    assert_jq_true "$jout" '.impacted[0] | has("code_quality") | not' "quality: code_quality absent without --quality"

    local jout_quality
    jout_quality=$("$WV" impact "$fnode" --json --quality 2>&1)
    assert_not_contains "$jout_quality" "Warning: --quality not implemented" "quality: --quality no longer warns as unimplemented"
    assert_jq_true "$jout_quality" '.impacted | length > 0' "quality: impacted list present with --quality"
    assert_jq_true "$jout_quality" '.impacted[0] | has("code_quality") and has("quality_as_of")' "quality: fields present with --quality"
    assert_jq_true "$jout_quality" '.impacted[0].code_quality | type == "array"' "quality: code_quality is array"
    assert_jq_true "$jout_quality" '.impacted[0].code_quality | length >= 1' "quality: fixture returns at least one code_quality item"
    assert_jq_true "$jout_quality" '.impacted[0].quality_as_of == "quality-fixture-head"' "quality: quality_as_of sourced from latest scan"
    assert_jq_true "$jout_quality" '.impacted[0].code_quality[0].path == "scripts/cmd/wv-cmd-graph.sh"' "quality: fixture path propagated"
    assert_jq_true "$jout_quality" '.impacted[0].code_quality[0].complexity == 23' "quality: fixture complexity propagated"
    assert_jq_true "$jout_quality" '.impacted[0].code_quality[0].hotspot == 0.75' "quality: fixture hotspot propagated"

    local jout_plain_after_quality
    jout_plain_after_quality=$("$WV" impact "$fnode" --json 2>&1)
    assert_jq_true "$jout_plain_after_quality" '.impacted[0] | has("code_quality") | not' "quality cache parity: plain output stays quality-free after quality run"

    # --help output
    out=$("$WV" impact --help 2>&1)
    assert_contains "$out" "direction" "impact --help: shows --direction flag"
    assert_contains "$out" "depth" "impact --help: shows --depth flag"
    assert_contains "$out" "files" "impact --help: shows --files flag"

    # --- fixture 9: --files seed enrichment ---
    setup_test_env

    local fnode_a fnode_b fnode_dep
    fnode_a=$("$WV" add "File-seeded node A" --force 2>&1 | tail -1)
    fnode_b=$("$WV" add "File-seeded node B (unrelated file)" --force 2>&1 | tail -1)
    fnode_dep=$("$WV" add "Dep of file-seeded A" --force 2>&1 | tail -1)
    "$WV" block "$fnode_dep" --by="$fnode_a" >/dev/null 2>&1
    "$WV" update "$fnode_a" --metadata='{"touched_files":["scripts/probe/alpha.sh"]}' >/dev/null 2>&1
    "$WV" update "$fnode_b" --metadata='{"touched_files":["scripts/probe/beta.sh"]}' >/dev/null 2>&1

    # Known file resolves to correct seed node
    out=$("$WV" impact --files=scripts/probe/alpha.sh 2>&1)
    assert_contains "$out" "File-seeded node A" "files: known file finds seed node as root"
    assert_contains "$out" "Dep of file-seeded A" "files: dep of file-seeded node appears in impacted"

    # JSON: seeds list reflects resolved node IDs
    local jfiles
    jfiles=$("$WV" impact --files=scripts/probe/alpha.sh --json 2>&1)
    assert_jq_true "$jfiles" '.seeds | length == 1' "files JSON: exactly one seed resolved"
    assert_jq_true "$jfiles" '.seeds[0].node_id == "'"$fnode_a"'"' "files JSON: seed matches the node with that touched_file"

    # Multiple files → union of seeds
    local jmulti
    jmulti=$("$WV" impact --files=scripts/probe/alpha.sh,scripts/probe/beta.sh --json 2>&1)
    assert_jq_true "$jmulti" '.seeds | length == 2' "files JSON: two files → two seeds"

    # Canonical attribution table → seed resolution without touched_files metadata.
    local fnode_nf fnode_nf_dep jnodefiles
    fnode_nf=$("$WV" add "File-seeded via node_files" --force 2>&1 | tail -1)
    fnode_nf_dep=$("$WV" add "Dep of node_files seed" --force 2>&1 | tail -1)
    "$WV" block "$fnode_nf_dep" --by="$fnode_nf" >/dev/null 2>&1
    sqlite3 "$WV_DB" "INSERT OR IGNORE INTO node_files(node_id, path) VALUES ('$fnode_nf', 'scripts/probe/node-files.sh');" 2>/dev/null
    jnodefiles=$("$WV" impact --files=scripts/probe/node-files.sh --json 2>&1)
    assert_jq_true "$jnodefiles" '.seeds | length == 1' "files JSON: node_files attribution resolves one seed"
    assert_jq_true "$jnodefiles" '.seeds[0].node_id == "'"$fnode_nf"'"' "files JSON: node_files seed matches attributed node"
    assert_jq_true "$jnodefiles" '.impacted | map(.node_id) | index("'"$fnode_nf_dep"'") != null' "files JSON: node_files seed traverses graph dependencies"

    # Duplicate attribution via node_files + metadata must dedupe to one seed.
    "$WV" update "$fnode_nf" --metadata='{"touched_files":["scripts/probe/node-files.sh"]}' >/dev/null 2>&1
    jnodefiles=$("$WV" impact --files=scripts/probe/node-files.sh --json 2>&1)
    assert_jq_true "$jnodefiles" '.seeds | length == 1' "files JSON: node_files plus metadata duplicate dedupes"

    # Unknown file → no graph seed: must WARN (not a bland "0 impacted" that reads
    # as "safe") and still surface affected suites via test-map.conf (wv-70ea8e).
    out=$("$WV" impact --files=no/such/file.py 2>&1)
    assert_contains "$out" "blast radius unknown" "files: unknown path warns instead of silent 0-impacted"
    assert_success "files: unknown path exits 0" "$WV" impact --files=no/such/file.py

    # Unknown file JSON → structured empty + graph_seed_matched flag + suites key
    local jempty
    jempty=$("$WV" impact --files=no/such/file.py --json 2>&1)
    assert_jq_true "$jempty" '.seeds | length == 0' "files JSON: unknown path has empty seeds"
    assert_jq_true "$jempty" '.impacted | length == 0' "files JSON: unknown path has empty impacted"
    assert_jq_true "$jempty" '.graph_seed_matched == false' "files JSON: graph_seed_matched=false when no node owns the file"
    assert_jq_true "$jempty" '.affected_suites | type == "array"' "files JSON: affected_suites present even with no graph seed"

    # Mapped-but-unattributed file: no node owns it, but test-map.conf maps a suite.
    # The suite must still surface — this is the wv-70ea8e false-0-impacted fix.
    mkdir -p "$TEST_DIR/.weave"
    printf '[map]\nscripts/probe/orphan.sh = tests/test-probe.sh\n' > "$TEST_DIR/.weave/test-map.conf"
    out=$("$WV" impact --files=scripts/probe/orphan.sh 2>&1)
    assert_contains "$out" "test-probe.sh" "files: mapped-but-unattributed file surfaces its suite via test-map.conf"
    local jorphan
    jorphan=$("$WV" impact --files=scripts/probe/orphan.sh --json 2>&1)
    assert_jq_true "$jorphan" '.affected_suites | map(.name) | index("tests/test-probe.sh") != null' "files JSON: mapped suite present in affected_suites despite no graph seed"
}

# ============================================================================
# Main
# ============================================================================
main() {
    echo "========================================"
    echo "Weave Graph Command Tests"
    echo "========================================"

    test_block
    test_link
    test_resolve
    test_related
    test_edges
    test_path
    test_impact

    echo ""
    echo "========================================"
    echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
    echo "========================================"

    if [ "$TESTS_FAILED" -gt 0 ]; then
        echo -e "${RED}$TESTS_FAILED test(s) failed${NC}"
        exit 1
    else
        echo -e "${GREEN}All tests passed${NC}"
        exit 0
    fi
}

main "$@"
