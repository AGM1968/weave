#!/usr/bin/env bash
# test-sprint34.sh — Test Sprint 3+4 features
#
# Tests: wv tree, wv plan, aliases, learning quality scoring,
#        wv health --history, wv session-summary, wv learnings --dedup
#
# Exit codes:
#   0 - All tests passed
#   1 - One or more tests failed

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$PROJECT_ROOT/scripts/wv"

# Test environment
TEST_DIR="/tmp/wv-sprint34-test-$$"
export WV_HOT_ZONE="$TEST_DIR"
export WV_DB="$TEST_DIR/brain.db"

cleanup() {
    cd /tmp
    if [ -d "$TEST_DIR" ]; then
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

setup_test_env() {
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR/.weave"
    cd "$TEST_DIR"
    # Need git repo for WEAVE_DIR resolution
    git init -q
}

# ---------------------------------------------------------------------------
# Test helpers
# ---------------------------------------------------------------------------

assert_equals() {
    local expected="$1" actual="$2" message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$expected" = "$actual" ]; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Expected: $expected"
        echo "  Actual:   $actual"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

strip_ansi() {
    # Remove ANSI escape sequences for clean text comparison
    sed 's/\x1b\[[0-9;]*m//g'
}

assert_contains() {
    local haystack="$1" needle="$2" message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if echo "$haystack" | strip_ansi | grep -qF "$needle"; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Expected to find: $needle"
        echo "  In: $(echo "$haystack" | strip_ansi | head -5)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if ! echo "$haystack" | strip_ansi | grep -qF "$needle"; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Expected NOT to find: $needle"
        echo "  In: $(echo "$haystack" | strip_ansi | head -5)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_success() {
    local message="$1"; shift
    TESTS_RUN=$((TESTS_RUN + 1))
    if "$@" >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Command failed: $*"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_fails() {
    local message="$1"; shift
    TESTS_RUN=$((TESTS_RUN + 1))
    if ! "$@" >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Expected command to fail: $*"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_json_field() {
    local json="$1" field="$2" expected="$3" message="$4"
    local actual
    actual=$(echo "$json" | jq -r "$field" 2>/dev/null)
    assert_equals "$expected" "$actual" "$message"
}

# ═══════════════════════════════════════════════════════════════════════════
# Test: wv tree
# ═══════════════════════════════════════════════════════════════════════════

test_tree() {
    echo ""
    echo "=== wv tree ==="

    setup_test_env
    $WV init >/dev/null 2>&1

    # Create hierarchy: epic -> feature -> task
    local epic_id feature_id task1_id task2_id
    epic_id=$($WV add "Epic: Build auth system" 2>/dev/null | tail -1)
    feature_id=$($WV add "Feature: Login flow" 2>/dev/null | tail -1)
    task1_id=$($WV add "Task: Create login form" 2>/dev/null | tail -1)
    task2_id=$($WV add "Task: Add JWT tokens" 2>/dev/null | tail -1)

    # Link: feature implements epic, tasks implement feature
    $WV link "$feature_id" "$epic_id" --type=implements >/dev/null 2>&1
    $WV link "$task1_id" "$feature_id" --type=implements >/dev/null 2>&1
    $WV link "$task2_id" "$feature_id" --type=implements >/dev/null 2>&1

    # Basic tree output
    local tree_out
    tree_out=$($WV tree 2>&1)
    assert_contains "$tree_out" "Epic: Build auth system" "tree: shows epic root"
    assert_contains "$tree_out" "Feature: Login flow" "tree: shows feature child"
    assert_contains "$tree_out" "Task: Create login form" "tree: shows task grandchild"
    assert_contains "$tree_out" "Task: Add JWT tokens" "tree: shows second task"

    # JSON output
    local tree_json
    tree_json=$($WV tree --json 2>&1)
    local json_count
    json_count=$(echo "$tree_json" | jq 'length' 2>/dev/null)
    assert_equals "4" "$json_count" "tree --json: returns all 4 nodes"

    # Check depth field exists in JSON
    local has_depth
    has_depth=$(echo "$tree_json" | jq '.[0] | has("depth")' 2>/dev/null)
    assert_equals "true" "$has_depth" "tree --json: nodes have depth field"

    # Depth limit
    local tree_depth1
    tree_depth1=$($WV tree --depth=1 2>&1)
    assert_contains "$tree_depth1" "Epic: Build auth system" "tree --depth=1: shows root"
    assert_contains "$tree_depth1" "Feature: Login flow" "tree --depth=1: shows depth 1"
    assert_not_contains "$tree_depth1" "Task: Create login form" "tree --depth=1: hides depth 2"

    # Active filter — mark epic done, create a second active root
    $WV done "$epic_id" >/dev/null 2>&1
    local active_epic
    active_epic=$($WV add "Epic: Active project" 2>/dev/null | tail -1)

    local tree_active
    tree_active=$($WV tree --active 2>&1)
    assert_not_contains "$tree_active" "Epic: Build auth system" "tree --active: hides done epics"
    assert_contains "$tree_active" "Epic: Active project" "tree --active: shows non-done roots"

    # Orphan nodes (no implements edges) become roots
    local orphan_id
    orphan_id=$($WV add "Orphan task" 2>/dev/null | tail -1)
    local tree_orphan
    tree_orphan=$($WV tree 2>&1)
    assert_contains "$tree_orphan" "Orphan task" "tree: orphan nodes appear as roots"

    # Multiple roots displayed
    local root_count
    root_count=$(echo "$tree_orphan" | grep -c "Epic:\|Orphan" || true)
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$root_count" -ge 2 ]; then
        echo -e "${GREEN}✓${NC} tree: multiple roots displayed"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} tree: multiple roots displayed (got $root_count)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# Test: wv plan
# ═══════════════════════════════════════════════════════════════════════════

test_plan() {
    echo ""
    echo "=== wv plan ==="

    setup_test_env
    $WV init >/dev/null 2>&1

    # Create test markdown file
    cat > "$TEST_DIR/plan.md" << 'PLANEOF'
# My Project Plan

## Prioritized Backlog

Some intro text.

### Sprint 1: Quick Wins — ~2 hours

1. **Fix login bug** — Users can't log in
2. **Add logout button** — Missing from nav
3. Update footer text

After this sprint: login works.

### Sprint 2: New Features — ~4 hours

1. **Add user profiles** — Display name, avatar
2. **Add settings page** — Theme, notifications

---

## What We're NOT Doing
PLANEOF

    # Dry run — no nodes created
    local dry_out
    dry_out=$($WV plan "$TEST_DIR/plan.md" --sprint=1 --dry-run 2>&1)
    assert_contains "$dry_out" "Sprint 1" "plan --dry-run: shows sprint title"
    assert_contains "$dry_out" "Fix login bug" "plan --dry-run: lists task 1"
    assert_contains "$dry_out" "Add logout button" "plan --dry-run: lists task 2"
    assert_contains "$dry_out" "Update footer text" "plan --dry-run: lists task 3"
    assert_contains "$dry_out" "Tasks: 3" "plan --dry-run: correct task count"
    assert_contains "$dry_out" "Dry run" "plan --dry-run: shows dry run label"

    # Verify no nodes were created
    local node_count
    node_count=$($WV list --all --json 2>&1 | jq 'length' 2>/dev/null)
    assert_equals "0" "$node_count" "plan --dry-run: no nodes created"

    # Actual import
    local plan_out
    plan_out=$($WV plan "$TEST_DIR/plan.md" --sprint=1 2>&1)
    assert_contains "$plan_out" "Epic:" "plan: creates epic"
    assert_contains "$plan_out" "Task:" "plan: creates tasks"

    # Check nodes exist
    node_count=$($WV list --all --json 2>&1 | jq 'length' 2>/dev/null)
    assert_equals "4" "$node_count" "plan: created 1 epic + 3 tasks"

    # Bold markers stripped
    local tasks_json
    tasks_json=$($WV list --all --json 2>&1)
    local has_bold
    has_bold=$(echo "$tasks_json" | jq '[.[] | .text | contains("**")] | any' 2>/dev/null)
    assert_equals "false" "$has_bold" "plan: bold markers stripped from task text"

    # Sprint 2 import
    plan_out=$($WV plan "$TEST_DIR/plan.md" --sprint=2 2>&1)
    assert_contains "$plan_out" "Sprint 2" "plan: sprint 2 parsed"
    assert_contains "$plan_out" "Add user profiles" "plan: sprint 2 task 1"

    # Missing file
    local err_out
    err_out=$($WV plan "$TEST_DIR/nonexistent.md" --sprint=1 2>&1 || true)
    assert_contains "$err_out" "not found" "plan: error on missing file"

    # Missing sprint
    err_out=$($WV plan "$TEST_DIR/plan.md" --sprint=99 2>&1 || true)
    assert_contains "$err_out" "not found" "plan: error on missing sprint"

    # No sprint flag
    err_out=$($WV plan "$TEST_DIR/plan.md" 2>&1 || true)
    assert_contains "$err_out" "sprint=N required" "plan: error when no --sprint"

    # No file arg
    err_out=$($WV plan 2>&1 || true)
    assert_contains "$err_out" "file required" "plan: error when no file"

    # Section boundary: Sprint 2 stops at --- rule
    local sprint2_tasks
    sprint2_tasks=$($WV plan "$TEST_DIR/plan.md" --sprint=2 --dry-run 2>&1)
    assert_contains "$sprint2_tasks" "Tasks: 2" "plan: sprint 2 has 2 tasks (stops at ---)"
    assert_not_contains "$sprint2_tasks" "NOT Doing" "plan: doesn't bleed into next section"
}

# ═══════════════════════════════════════════════════════════════════════════
# Test: Human-readable aliases
# ═══════════════════════════════════════════════════════════════════════════

test_aliases() {
    echo ""
    echo "=== Aliases ==="

    setup_test_env
    $WV init >/dev/null 2>&1

    # Create node with alias
    local id1
    id1=$($WV add "Fix authentication bug" --alias=auth-bug 2>/dev/null | tail -1)
    assert_success "alias: node created with alias" test -n "$id1"

    # Show via alias
    local show_out
    show_out=$($WV show auth-bug 2>&1)
    assert_contains "$show_out" "Fix authentication bug" "alias: show resolves alias"
    assert_contains "$show_out" "auth-bug" "alias: show displays alias"

    # Show via original ID still works
    show_out=$($WV show "$id1" 2>&1)
    assert_contains "$show_out" "Fix authentication bug" "alias: show by ID still works"

    # Done via alias
    local id2
    id2=$($WV add "Deploy hotfix" --alias=deploy 2>/dev/null | tail -1)
    $WV done deploy >/dev/null 2>&1
    local status
    status=$($WV show "$id2" --json 2>&1 | jq -r '.[0].status' 2>/dev/null)
    assert_equals "done" "$status" "alias: done resolves alias"

    # Update via alias
    local id3
    id3=$($WV add "Refactor DB" --alias=refactor-db 2>/dev/null | tail -1)
    $WV update refactor-db --text="Refactor database layer" >/dev/null 2>&1
    local updated_text
    updated_text=$($WV show "$id3" --json 2>&1 | jq -r '.[0].text' 2>/dev/null)
    assert_equals "Refactor database layer" "$updated_text" "alias: update resolves alias"

    # Change alias
    $WV update "$id3" --alias=db-refactor >/dev/null 2>&1
    show_out=$($WV show db-refactor 2>&1)
    assert_contains "$show_out" "Refactor database layer" "alias: updated alias resolves"

    # Work via alias
    local id4
    id4=$($WV add "Write tests" --alias=tests 2>/dev/null | tail -1)
    $WV work tests >/dev/null 2>&1
    status=$($WV show "$id4" --json 2>&1 | jq -r '.[0].status' 2>/dev/null)
    assert_equals "active" "$status" "alias: work resolves alias"

    # Non-existent alias fails gracefully (exit 1, no crash)
    assert_fails "alias: non-existent alias fails gracefully" "$WV" show nonexistent-alias

    # Alias uniqueness — duplicate alias rejected
    $WV add "Duplicate task" --alias=tests 2>/dev/null || true
    local alias_count
    alias_count=$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM nodes WHERE alias='tests';" 2>/dev/null)
    assert_equals "1" "$alias_count" "alias: uniqueness enforced"

    # Block via alias
    local id5 id6
    id5=$($WV add "Blocker task" --alias=blocker 2>/dev/null | tail -1)
    id6=$($WV add "Blocked task" --alias=blocked 2>/dev/null | tail -1)
    $WV block blocked --by="$id5" >/dev/null 2>&1
    local blocked_status
    blocked_status=$($WV show "$id6" --json 2>&1 | jq -r '.[0].status' 2>/dev/null)
    assert_equals "blocked" "$blocked_status" "alias: block resolves alias"
}

# ═══════════════════════════════════════════════════════════════════════════
# Test: Learning quality scoring
# ═══════════════════════════════════════════════════════════════════════════

test_learning_quality() {
    echo ""
    echo "=== Learning Quality Scoring ==="

    setup_test_env
    $WV init >/dev/null 2>&1

    # No learning — no score
    local id1
    id1=$($WV add "Simple task" 2>/dev/null | tail -1)
    $WV done "$id1" >/dev/null 2>&1
    local score1
    score1=$($WV show "$id1" --json 2>&1 | jq -r '.[0].metadata | fromjson | .learning_quality // "null"' 2>/dev/null)
    assert_equals "null" "$score1" "quality: no learning = no score"

    # Short learning (>20 chars, no prefix, no code ref) = 1 point
    local id2
    id2=$($WV add "Task with short learning" 2>/dev/null | tail -1)
    $WV done "$id2" --learning="always check the edge cases first" >/dev/null 2>&1
    local score2
    score2=$($WV show "$id2" --json 2>&1 | jq -r '.[0].metadata | fromjson | .learning_quality' 2>/dev/null)
    assert_equals "1" "$score2" "quality: length >20 chars = 1 point"

    # Categorized prefix (pattern:) = +2, plus length >20 = +1 = 3
    local id3
    id3=$($WV add "Task with pattern learning" 2>/dev/null | tail -1)
    $WV done "$id3" --learning="pattern: Use recursive CTE for tree traversal in SQLite" >/dev/null 2>&1
    local score3
    score3=$($WV show "$id3" --json 2>&1 | jq -r '.[0].metadata | fromjson | .learning_quality' 2>/dev/null)
    assert_equals "3" "$score3" "quality: length + categorized prefix = 3"

    # All bonuses: prefix + length + code reference = 4
    local id4
    id4=$($WV add "Task with full quality" 2>/dev/null | tail -1)
    $WV done "$id4" --learning="pattern: Use validate_status() from wv-validate.sh for enum checking" >/dev/null 2>&1
    local score4
    score4=$($WV show "$id4" --json 2>&1 | jq -r '.[0].metadata | fromjson | .learning_quality' 2>/dev/null)
    assert_equals "4" "$score4" "quality: length + prefix + code ref = 4"

    # Pitfall prefix also scores +2
    local id5
    id5=$($WV add "Task with pitfall" 2>/dev/null | tail -1)
    $WV done "$id5" --learning="pitfall: Never use echo with arrays, causes word splitting" >/dev/null 2>&1
    local score5
    score5=$($WV show "$id5" --json 2>&1 | jq -r '.[0].metadata | fromjson | .learning_quality' 2>/dev/null)
    assert_equals "3" "$score5" "quality: pitfall prefix scores same as pattern"

    # --min-quality filter works
    local filtered
    filtered=$($WV learnings --min-quality=3 --json 2>&1)
    local filtered_count
    filtered_count=$(echo "$filtered" | jq 'length' 2>/dev/null)
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$filtered_count" -ge 2 ]; then
        echo -e "${GREEN}✓${NC} quality: --min-quality=3 filters correctly ($filtered_count results)"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} quality: --min-quality=3 should return ≥2 (got $filtered_count)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# Test: wv health --history
# ═══════════════════════════════════════════════════════════════════════════

test_health_history() {
    echo ""
    echo "=== Health History ==="

    setup_test_env
    $WV init >/dev/null 2>&1

    # No history yet
    local no_hist
    no_hist=$($WV health --history 2>&1)
    assert_contains "$no_hist" "No health history" "history: no log yet message"

    # Run health to generate log entries
    $WV health >/dev/null 2>&1
    $WV health >/dev/null 2>&1
    $WV health >/dev/null 2>&1

    # Log file has 3 entries
    local log_file="$TEST_DIR/.weave/health.log"
    local line_count
    line_count=$(wc -l < "$log_file" 2>/dev/null || echo 0)
    assert_equals "3" "$line_count" "history: 3 health calls = 3 log entries"

    # TSV format: timestamp\tscore\tnodes\tedges\torphans\tghosts
    local first_line
    first_line=$(head -1 "$log_file")
    local field_count
    field_count=$(echo "$first_line" | awk -F'\t' '{print NF}')
    assert_equals "6" "$field_count" "history: TSV has 6 fields"

    # --history shows entries
    local hist_out
    hist_out=$($WV health --history 2>&1)
    assert_contains "$hist_out" "Health History" "history: shows header"
    assert_contains "$hist_out" "Score" "history: shows column headers"

    # --history=2 limits output
    local hist_limited
    hist_limited=$($WV health --history=2 2>&1)
    assert_contains "$hist_limited" "last 2 of 3" "history: shows correct limit info"

    # --history --json
    local hist_json
    hist_json=$($WV health --history --json 2>&1)
    local json_count
    json_count=$(echo "$hist_json" | jq 'length' 2>/dev/null)
    assert_equals "3" "$json_count" "history --json: returns all 3 entries"

    # JSON has correct fields
    local has_fields
    has_fields=$(echo "$hist_json" | jq '[.[0] | has("timestamp", "score", "nodes", "edges", "orphans", "ghost_edges")] | all' 2>/dev/null)
    assert_equals "true" "$has_fields" "history --json: has all expected fields"

    # Score is a number
    local score_type
    score_type=$(echo "$hist_json" | jq '.[0].score | type' 2>/dev/null)
    assert_equals '"number"' "$score_type" "history --json: score is number"

    # Default limit is 10
    # Generate more entries
    for i in $(seq 1 12); do
        $WV health >/dev/null 2>&1
    done
    local default_hist
    default_hist=$($WV health --history --json 2>&1)
    local default_count
    default_count=$(echo "$default_hist" | jq 'length' 2>/dev/null)
    assert_equals "10" "$default_count" "history: default limit is 10"
}

# ═══════════════════════════════════════════════════════════════════════════
# Test: wv session-summary
# ═══════════════════════════════════════════════════════════════════════════

test_session_summary() {
    echo ""
    echo "=== Session Summary ==="

    setup_test_env
    $WV init >/dev/null 2>&1

    # No snapshot yet
    local no_snap
    no_snap=$($WV session-summary 2>&1)
    assert_contains "$no_snap" "No session snapshot" "session-summary: no snapshot message"

    # Create snapshot by calling _save_session_snapshot via load
    # We simulate this by creating the snapshot file directly
    local snapshot="$WV_HOT_ZONE/.session_snapshot"
    local now_ts
    now_ts=$(date -u +%s)
    # Snapshot: 0 total, 0 done, 0 learnings
    printf '%s\t%s\t%s\t%s\n' "$now_ts" "0" "0" "0" > "$snapshot"

    # Create and complete a node with learning
    local id1
    id1=$($WV add "Test task" 2>/dev/null | tail -1)
    $WV done "$id1" --learning="pattern: test pattern" >/dev/null 2>&1

    # Summary shows deltas
    local summary
    summary=$($WV session-summary 2>&1)
    assert_contains "$summary" "+1" "session-summary: shows +1 created"
    assert_contains "$summary" "1 completed" "session-summary: shows 1 completed"
    assert_contains "$summary" "1 captured" "session-summary: shows 1 learning"

    # JSON output
    local json_out
    json_out=$($WV session-summary --json 2>&1)
    assert_json_field "$json_out" ".nodes_created" "1" "session-summary --json: nodes_created=1"
    assert_json_field "$json_out" ".nodes_completed" "1" "session-summary --json: nodes_completed=1"
    assert_json_field "$json_out" ".learnings_captured" "1" "session-summary --json: learnings=1"

    # Duration field exists
    local has_duration
    has_duration=$(echo "$json_out" | jq 'has("duration")' 2>/dev/null)
    assert_equals "true" "$has_duration" "session-summary --json: has duration field"

    # Elapsed seconds is a number
    local elapsed_type
    elapsed_type=$(echo "$json_out" | jq '.elapsed_seconds | type' 2>/dev/null)
    assert_equals '"number"' "$elapsed_type" "session-summary --json: elapsed_seconds is number"

    # Multiple operations
    local id2 id3
    id2=$($WV add "Task 2" 2>/dev/null | tail -1)
    id3=$($WV add "Task 3" 2>/dev/null | tail -1)
    $WV done "$id2" >/dev/null 2>&1

    json_out=$($WV session-summary --json 2>&1)
    assert_json_field "$json_out" ".nodes_created" "3" "session-summary: 3 total created"
    assert_json_field "$json_out" ".nodes_completed" "2" "session-summary: 2 total completed"
}

# ═══════════════════════════════════════════════════════════════════════════
# Test: wv learnings --dedup
# ═══════════════════════════════════════════════════════════════════════════

test_learnings_dedup() {
    echo ""
    echo "=== Learning Deduplication ==="

    setup_test_env
    $WV init >/dev/null 2>&1

    # Empty — no learnings
    local empty_out
    empty_out=$($WV learnings --dedup 2>&1)
    assert_contains "$empty_out" "No learnings" "dedup: empty DB message"

    # Create identical learnings
    local id1 id2
    id1=$($WV add "Task A" 2>/dev/null | tail -1)
    $WV done "$id1" --learning="pattern: Always use recursive CTE for tree traversal in SQLite databases" >/dev/null 2>&1
    id2=$($WV add "Task B" 2>/dev/null | tail -1)
    $WV done "$id2" --learning="pattern: Always use recursive CTE for tree traversal in SQLite databases" >/dev/null 2>&1

    # Should detect duplicates
    local dedup_out
    dedup_out=$($WV learnings --dedup 2>&1)
    assert_contains "$dedup_out" "$id1" "dedup: shows first duplicate ID"
    assert_contains "$dedup_out" "$id2" "dedup: shows second duplicate ID"
    assert_contains "$dedup_out" "100%" "dedup: identical learnings = 100%"

    # JSON output
    local dedup_json
    dedup_json=$($WV learnings --dedup --json 2>&1)
    local pair_count
    pair_count=$(echo "$dedup_json" | jq 'length' 2>/dev/null)
    assert_equals "1" "$pair_count" "dedup --json: 1 duplicate pair"

    local sim
    sim=$(echo "$dedup_json" | jq '.[0].similarity' 2>/dev/null)
    assert_equals "100" "$sim" "dedup --json: similarity = 100"

    # Dissimilar learnings — should NOT be flagged
    local id3
    id3=$($WV add "Task C" 2>/dev/null | tail -1)
    $WV done "$id3" --learning="pitfall: Never use global variables for configuration management in large applications" >/dev/null 2>&1

    dedup_json=$($WV learnings --dedup --json 2>&1)
    pair_count=$(echo "$dedup_json" | jq 'length' 2>/dev/null)
    assert_equals "1" "$pair_count" "dedup: dissimilar learning not flagged (still 1 pair)"

    # Case insensitive
    local id4
    id4=$($WV add "Task D" 2>/dev/null | tail -1)
    $WV done "$id4" --learning="PATTERN: ALWAYS USE RECURSIVE CTE FOR TREE TRAVERSAL IN SQLITE DATABASES" >/dev/null 2>&1

    dedup_json=$($WV learnings --dedup --json 2>&1)
    pair_count=$(echo "$dedup_json" | jq 'length' 2>/dev/null)
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$pair_count" -ge 3 ]; then
        echo -e "${GREEN}✓${NC} dedup: case insensitive matching ($pair_count pairs)"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} dedup: case insensitive matching (expected ≥3 pairs, got $pair_count)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi

    # No duplicates scenario
    setup_test_env
    $WV init >/dev/null 2>&1
    local id5
    id5=$($WV add "Unique A" 2>/dev/null | tail -1)
    $WV done "$id5" --learning="decision: Chose PostgreSQL for relational data storage needs" >/dev/null 2>&1
    local id6
    id6=$($WV add "Unique B" 2>/dev/null | tail -1)
    $WV done "$id6" --learning="pitfall: Always sanitize user input before database queries" >/dev/null 2>&1

    local no_dup_out
    no_dup_out=$($WV learnings --dedup 2>&1)
    assert_contains "$no_dup_out" "No duplicate" "dedup: no duplicates found message"

    # JSON empty array when no dupes
    local no_dup_json
    no_dup_json=$($WV learnings --dedup --json 2>&1)
    assert_equals "[]" "$no_dup_json" "dedup --json: empty array when no duplicates"
}

# ═══════════════════════════════════════════════════════════════════════════
# Test: _resolve_first_id dispatch
# ═══════════════════════════════════════════════════════════════════════════

test_resolve_first_id() {
    echo ""
    echo "=== _resolve_first_id ==="

    setup_test_env
    $WV init >/dev/null 2>&1

    # Flags pass through correctly with alias resolution
    local id1
    id1=$($WV add "Learning test node" --alias=learn-test 2>/dev/null | tail -1)
    $WV done learn-test --learning="pattern: always test your code thoroughly" >/dev/null 2>&1

    # Verify the full learning was captured (not truncated by word splitting)
    local learning
    learning=$($WV show "$id1" --json 2>&1 | jq -r '.[0].metadata | fromjson | .learning' 2>/dev/null)
    assert_equals "pattern: always test your code thoroughly" "$learning" "resolve: --learning flag preserved through alias resolution"

    # Alias with flags after
    local id2
    id2=$($WV add "Flag test" --alias=flagtest 2>/dev/null | tail -1)
    local show_json
    show_json=$($WV show flagtest --json 2>&1)
    assert_contains "$show_json" "Flag test" "resolve: alias with --json flag works"

    # wv-xxxxxx ID bypasses alias resolution
    local id3
    id3=$($WV add "Direct ID test" 2>/dev/null | tail -1)
    local show_direct
    show_direct=$($WV show "$id3" 2>&1)
    assert_contains "$show_direct" "Direct ID test" "resolve: wv-xxxxxx ID works directly"
}

# ═══════════════════════════════════════════════════════════════════════════
# Test: Weave-ID trailers in auto-checkpoint commits
# ═══════════════════════════════════════════════════════════════════════════

test_checkpoint_trailers() {
    echo ""
    echo "--- Checkpoint Trailers ---"
    setup_test_env

    # Need an initial commit so git log works
    git commit --allow-empty -m "init" --no-verify -q

    # Disable throttle for all checkpoint tests
    export WV_CHECKPOINT_INTERVAL=0

    # Create an active node and trigger checkpoint
    local id1
    id1=$($WV add "Active work item" --status=active 2>/dev/null | tail -1)
    rm -f "$WV_HOT_ZONE/.last_checkpoint"
    $WV sync >/dev/null 2>&1

    # Check latest commit for Weave-ID trailer
    local commit_msg
    commit_msg=$(git log -1 --format='%B' 2>/dev/null)
    assert_contains "$commit_msg" "Weave-ID: $id1" "checkpoint: includes active node trailer"
    assert_contains "$commit_msg" "auto-checkpoint" "checkpoint: has auto-checkpoint prefix"

    # Create second active node — both should appear as trailers
    local id2
    id2=$($WV add "Second active item" --status=active 2>/dev/null | tail -1)
    rm -f "$WV_HOT_ZONE/.last_checkpoint"
    $WV sync >/dev/null 2>&1

    commit_msg=$(git log -1 --format='%B' 2>/dev/null)
    assert_contains "$commit_msg" "Weave-ID: $id1" "checkpoint: still includes first active node"
    assert_contains "$commit_msg" "Weave-ID: $id2" "checkpoint: includes second active node"

    # Complete one node — its trailer should disappear
    $WV done "$id1" >/dev/null 2>&1
    rm -f "$WV_HOT_ZONE/.last_checkpoint"
    $WV sync >/dev/null 2>&1

    commit_msg=$(git log -1 --format='%B' 2>/dev/null)
    assert_not_contains "$commit_msg" "Weave-ID: $id1" "checkpoint: completed node removed from trailers"
    assert_contains "$commit_msg" "Weave-ID: $id2" "checkpoint: remaining active node still in trailer"

    # No active nodes — no trailers
    $WV done "$id2" >/dev/null 2>&1
    $WV add "Just a todo" >/dev/null 2>&1  # status=todo, not active
    rm -f "$WV_HOT_ZONE/.last_checkpoint"
    $WV sync >/dev/null 2>&1

    commit_msg=$(git log -1 --format='%B' 2>/dev/null)
    assert_not_contains "$commit_msg" "Weave-ID:" "checkpoint: no trailers when no active nodes"

    unset WV_CHECKPOINT_INTERVAL
}

# ═══════════════════════════════════════════════════════════════════════════
# Run all tests
# ═══════════════════════════════════════════════════════════════════════════

main() {
    echo "Sprint 3+4: System Tests"
    echo "════════════════════════════════════"

    test_tree
    test_plan
    test_aliases
    test_learning_quality
    test_health_history
    test_session_summary
    test_learnings_dedup
    test_resolve_first_id
    test_checkpoint_trailers

    echo ""
    echo "════════════════════════════════════"
    echo -e "Results: ${TESTS_PASSED}/${TESTS_RUN} passed"

    if [ "$TESTS_FAILED" -gt 0 ]; then
        echo -e "${RED}${TESTS_FAILED} tests FAILED${NC}"
        exit 1
    else
        echo -e "${GREEN}ALL TESTS PASSED${NC}"
        exit 0
    fi
}

main "$@"
