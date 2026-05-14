#!/usr/bin/env bash
# test-core.sh — Test core Weave commands
#
# Tests: init, add, done, list, show, ready, status
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
TEST_DIR="/tmp/wv-core-test-$$"
export WV_HOT_ZONE="$TEST_DIR"
export WV_DB="$TEST_DIR/brain.db"
export WV_REQUIRE_LEARNING=0
export WV_RUN_CACHE=0
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

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"

    TESTS_RUN=$((TESTS_RUN + 1))

    if ! echo "$haystack" | grep -qF -- "$needle"; then
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
# Test: init
# ============================================================================
test_init() {
    echo ""
    echo "Test: wv init"
    echo "============="

    setup_test_env

    # Test init creates database
    local output
    output=$("$WV" init 2>&1)
    assert_contains "$output" "Initialized Weave" "init outputs success message"
    assert_success "init creates database file" test -f "$WV_DB"

    # Test init is idempotent (empty DB)
    output=$("$WV" init 2>&1)
    assert_contains "$output" "Initialized Weave" "init is idempotent on empty DB"
}

test_init_recovery() {
    echo ""
    echo "Test: wv init recovery"
    echo "======================"

    # Set up isolated test env with git repo (needed for WEAVE_DIR resolution)
    local INIT_TEST_DIR
    INIT_TEST_DIR=$(mktemp -d)
    local OLD_HOT="$WV_HOT_ZONE"
    local OLD_DB="$WV_DB"
    local OLD_PROJECT="${WV_PROJECT_DIR:-}"
    export WV_HOT_ZONE="$INIT_TEST_DIR/hot"
    export WV_DB="$WV_HOT_ZONE/brain.db"
    export WV_PROJECT_DIR="$INIT_TEST_DIR"

    cd "$INIT_TEST_DIR"
    git init -q

    # Create initial state: init, add nodes, sync
    "$WV" init >/dev/null 2>&1
    "$WV" add "Recovery test node" >/dev/null 2>&1
    "$WV" add "Another node" >/dev/null 2>&1
    "$WV" sync >/dev/null 2>&1
    assert_success "state.sql created by sync" test -f "$INIT_TEST_DIR/.weave/state.sql"

    # Simulate reboot: wipe hot zone (DB gone, state.sql remains)
    rm -rf "$WV_HOT_ZONE"

    # wv init should auto-recover
    local output
    output=$("$WV" init 2>&1)
    assert_contains "$output" "Recovered" "init detects reboot and recovers"
    assert_contains "$output" "2 nodes" "init reports recovered node count"
    assert_success "DB restored after recovery" test -f "$WV_DB"

    # Verify data survived
    output=$("$WV" list --all 2>&1)
    assert_contains "$output" "Recovery test node" "recovered data is accessible"

    # Test guard: init with existing data should fail
    output=$("$WV" init 2>&1 || true)
    assert_contains "$output" "already exists" "init refuses to overwrite existing data"

    # Test --force bypasses guard
    output=$("$WV" init --force 2>&1)
    assert_contains "$output" "Initialized Weave" "init --force reinitializes"

    # Restore original env
    export WV_HOT_ZONE="$OLD_HOT"
    export WV_DB="$OLD_DB"
    if [ -n "$OLD_PROJECT" ]; then
        export WV_PROJECT_DIR="$OLD_PROJECT"
    else
        unset WV_PROJECT_DIR
    fi
    cd /tmp
    rm -rf "$INIT_TEST_DIR"
}

test_leaked_env_overrides_are_ignored_across_repos() {
    echo ""
    echo "Test: leaked WV_HOT_ZONE/WV_DB overrides are ignored across repos"
    echo "==============================================================="

    local source_repo target_repo old_hot old_db old_project
    source_repo=$(mktemp -d)
    target_repo=$(mktemp -d)
    old_hot="${WV_HOT_ZONE:-}"
    old_db="${WV_DB:-}"
    old_project="${WV_PROJECT_DIR:-}"

    cd "$source_repo"
    git init -q
    export WV_HOT_ZONE="$source_repo/hot"
    export WV_DB="$WV_HOT_ZONE/brain.db"
    export WV_PROJECT_DIR="$source_repo"

    "$WV" init >/dev/null 2>&1
    "$WV" add "Source repo node" >/dev/null 2>&1
    assert_success "custom hot zone records owning repo" test -f "$source_repo/hot/.repo_root"

    cd "$target_repo"
    git init -q

    local target_hot target_db output source_target_count target_target_count
    target_hot=$(env -u WV_HOT_ZONE -u WV_DB -u WV_PROJECT_DIR WEAVE_DIR="$target_repo/.weave" \
        bash -c "source '$PROJECT_ROOT/scripts/lib/wv-resolve-runtime.sh'; resolve_repo_hot_zone \"\$(resolve_hot_zone)\" '$target_repo'" 2>/dev/null)
    target_db="$target_hot/brain.db"

    output=$("$WV" add "Target repo node" 2>&1)
    assert_contains "$output" "ignoring leaked WV_HOT_ZONE/WV_DB override" \
        "foreign repo warns when leaked WV overrides are ignored"

    source_target_count=$(sqlite3 "$source_repo/hot/brain.db" "SELECT COUNT(*) FROM nodes WHERE text='Target repo node';" 2>/dev/null || echo "0")
    target_target_count=$(sqlite3 "$target_db" "SELECT COUNT(*) FROM nodes WHERE text='Target repo node';" 2>/dev/null || echo "0")
    assert_equals "0" "$source_target_count" \
        "leaked overrides do not write into the source repo DB"
    assert_equals "1" "$target_target_count" \
        "leaked overrides fall back to the target repo DB"

    export WV_HOT_ZONE="$old_hot"
    export WV_DB="$old_db"
    if [ -n "$old_project" ]; then
        export WV_PROJECT_DIR="$old_project"
    else
        unset WV_PROJECT_DIR
    fi

    cd /tmp
    rm -rf "$source_repo" "$target_repo"
}

# ============================================================================
# Test: add
# ============================================================================
test_add() {
    echo ""
    echo "Test: wv add"
    echo "============"

    setup_test_env
    "$WV" init >/dev/null 2>&1

    # Basic add
    local output id
    output=$("$WV" add "Test task one" 2>&1)
    assert_contains "$output" "wv-" "add outputs node ID"

    # Extract ID from output (last line)
    id=$(echo "$output" | tail -1)
    assert_contains "$id" "wv-" "add returns bare ID on last line"

    # Direct add-to-active must carry the same planning metadata that wv work
    # would require on the claim path.
    assert_fails "add --status=active requires claim-ready metadata" "$WV" add "Active task" --status=active

    # Add with active status + claim-ready metadata
    output=$("$WV" add "Active task" --status=active --criteria="tests pass|docs updated" --risks=low 2>&1)
    id=$(echo "$output" | tail -1)
    local show_output
    show_output=$("$WV" show "$id" 2>&1)
    assert_contains "$show_output" "active" "add --status sets correct status"

    # Add with metadata
    output=$("$WV" add "Task with metadata" --metadata='{"priority":1,"type":"bug"}' 2>&1)
    id=$(echo "$output" | tail -1)
    show_output=$("$WV" show "$id" --json 2>&1)
    # Metadata is JSON-encoded in the output, so quotes are escaped
    assert_contains "$show_output" 'priority' "add --metadata stores JSON"
    assert_contains "$show_output" 'bug' "add --metadata stores all fields"

    # Add with --standalone persists durable standalone intent
    output=$("$WV" add "Standalone task" --standalone 2>&1)
    id=$(echo "$output" | tail -1)
    show_output=$("$WV" show "$id" --json 2>&1)
    local standalone_meta
    standalone_meta=$(echo "$show_output" | jq -r '.[0].metadata | fromjson | .standalone' 2>/dev/null)
    assert_equals "true" "$standalone_meta" "add --standalone stores standalone intent"

    # Add fails without text
    assert_fails "add requires text" "$WV" add

    # Add fails with invalid metadata JSON
    assert_fails "add rejects invalid JSON metadata" "$WV" add "Bad metadata" --metadata='not-json'

    # --risks=<level> must always seed both risk_level AND risks:[] so the
    # pre-claim hook's has("risks") check passes on immediate claim.
    local risk_id risk_meta
    for level in none low medium high critical; do
        risk_id=$("$WV" add "risks=$level" --risks="$level" 2>&1 | tail -1)
        risk_meta=$("$WV" show "$risk_id" --json | jq -r '.[0].metadata')
        assert_contains "$risk_meta" "\"risk_level\":\"$level\"" "--risks=$level sets risk_level"
        assert_contains "$risk_meta" '"risks":[]' "--risks=$level seeds empty risks list"
    done
}

# ============================================================================
# Test: done
# ============================================================================
test_done() {
    echo ""
    echo "Test: wv done"
    echo "============="

    setup_test_env
    "$WV" init >/dev/null 2>&1

    # Create a node
    local id
    id=$("$WV" add "Task to complete" 2>&1 | tail -1)

    # Mark done
    local output
    output=$("$WV" done "$id" 2>&1)
    assert_contains "$output" "Closed" "done outputs completion message"

    # Verify status changed
    local show_output
    show_output=$("$WV" show "$id" 2>&1)
    assert_contains "$show_output" "done" "done sets status to done"

    # Done with learning
    id=$("$WV" add "Task with learning" 2>&1 | tail -1)
    output=$("$WV" done "$id" --learning="pattern: always test your code" 2>&1)
    assert_contains "$output" "Closed" "done with learning succeeds"

    # Verify learning was captured in metadata
    local show_meta
    show_meta=$("$WV" show "$id" --json 2>&1)
    assert_contains "$show_meta" "always test your code" "done --learning stores in metadata"

    # Done on non-existent node fails
    assert_fails "done on non-existent node fails" "$WV" done "wv-0000"

    # Learning gate: wv done requires --learning or --skip-verification
    id=$("$WV" add "Task needing learning" 2>&1 | tail -1)
    assert_fails "done rejects bare close when learning required" \
        env WV_REQUIRE_LEARNING=1 "$WV" done "$id"

    # Same node succeeds with --skip-verification
    local sv_exit=0
    WV_REQUIRE_LEARNING=1 "$WV" done "$id" --skip-verification >/dev/null 2>&1 || sv_exit=$?
    assert_equals "0" "$sv_exit" "done accepts --skip-verification"

    # Finding nodes require structured finding metadata before close
    local finding_id finding_output
    finding_id=$("$WV" add "Finding needing schema" --metadata='{"type":"finding"}' 2>&1 | tail -1)
    assert_fails "done rejects incomplete finding metadata" \
        env WV_REQUIRE_LEARNING=1 "$WV" done "$finding_id" --skip-verification

    "$WV" update "$finding_id" --metadata='{"type":"finding","finding":{"violation_type":"R10:open_node_at_end","root_cause":"bootstrap omitted active-node type","proposed_fix":"record active_node_type in session_start metadata","confidence":0.92,"fixable":"yes"}}' >/dev/null 2>&1
    assert_fails "done rejects invalid finding metadata types" \
        env WV_REQUIRE_LEARNING=1 "$WV" done "$finding_id" --skip-verification

    "$WV" update "$finding_id" --metadata='{"type":"finding","finding":{"violation_type":"R10:open_node_at_end","root_cause":"bootstrap omitted active-node type","proposed_fix":"record active_node_type in session_start metadata","confidence":"high","fixable":true}}' >/dev/null 2>&1
    finding_output=$(WV_REQUIRE_LEARNING=1 "$WV" done "$finding_id" --skip-verification 2>&1)
    assert_contains "$finding_output" "Closed" "done accepts complete finding metadata"

    # Non-interactive overlap: close proceeds and skips overlap advisory writes entirely
    local seed_id overlap_id overlap_learning overlap_exit overlap_output overlap_meta
    overlap_learning="decision: keep overlap prompts resumable | pattern: store pending close state | pitfall: tty prompts hang unattended flows"
    seed_id=$("$WV" add "Seed overlap learning" 2>&1 | tail -1)
    WV_REQUIRE_LEARNING=1 "$WV" done "$seed_id" --learning="$overlap_learning" >/dev/null 2>&1

    overlap_id=$("$WV" add "Overlap advisory" 2>&1 | tail -1)
    overlap_exit=0
    overlap_output=$(WV_REQUIRE_LEARNING=1 WV_NONINTERACTIVE=1 "$WV" done "$overlap_id" --learning="$overlap_learning" 2>&1) || overlap_exit=$?
    assert_equals "0" "$overlap_exit" "done succeeds non-interactively when overlap detected"
    assert_not_contains "$overlap_output" "Overlap noted in metadata" "done skips overlap advisory output in non-interactive mode"

    overlap_meta=$("$WV" show "$overlap_id" --json 2>&1)
    assert_not_contains "$overlap_meta" "learning_overlap_noted" "done skips learning_overlap_noted metadata in non-interactive mode"
    assert_contains "$overlap_meta" '"status":"done"' "node is closed despite overlap"

    local finding_overlap_id finding_overlap_exit finding_overlap_output finding_overlap_meta
    finding_overlap_id=$("$WV" add "Finding overlap advisory" --metadata='{"type":"finding","verification":{"method":"test","result":"pass"},"finding":{"violation_type":"schema_enforcement_test","root_cause":"runtime wv_done wrapper validates finding metadata types and presence before allowing close","proposed_fix":"agents must set confidence as one of high|medium|low (string) and fixable as boolean before closing a finding node","confidence":"high","fixable":true}}' 2>&1 | tail -1)
    finding_overlap_exit=0
    finding_overlap_output=$(WV_REQUIRE_LEARNING=1 WV_NONINTERACTIVE=1 "$WV" done "$finding_overlap_id" --learning="$overlap_learning" 2>&1) || finding_overlap_exit=$?
    assert_equals "0" "$finding_overlap_exit" "done succeeds for finding nodes when overlap is advisory"
    assert_contains "$finding_overlap_output" "Closed" "finding overlap advisory still closes the node"
    finding_overlap_meta=$("$WV" show "$finding_overlap_id" --json 2>&1)
    assert_contains "$finding_overlap_meta" '"status":"done"' "finding node is closed despite overlap"
    assert_not_contains "$finding_overlap_meta" "learning_overlap_noted" "finding close also skips overlap advisory metadata in non-interactive mode"

    local ship_id ship_exit ship_output ship_meta ship_remote ship_status
    local ship_repo ship_hot old_hot old_db old_project old_pwd
    ship_repo="$TEST_DIR/ship-repo"
    ship_hot="$TEST_DIR/ship-hot"
    ship_remote="$TEST_DIR/ship-remote.git"
    old_hot="$WV_HOT_ZONE"
    old_db="$WV_DB"
    old_project="${WV_PROJECT_DIR:-}"
    old_pwd="$PWD"

    rm -rf "$ship_repo" "$ship_hot" "$ship_remote"
    mkdir -p "$ship_repo" "$ship_hot"
    cd "$ship_repo"
    git init -q
    export WV_HOT_ZONE="$ship_hot"
    export WV_DB="$ship_hot/brain.db"
    export WV_PROJECT_DIR="$ship_repo"
    "$WV" init >/dev/null 2>&1

    git config user.email "test@example.com"
    git config user.name "Weave Test"
    git init --bare -q "$ship_remote"
    git remote add origin "$ship_remote"
    git add . >/dev/null 2>&1 || true
    git commit -m "test baseline" --allow-empty >/dev/null 2>&1 || true
    git push -u origin HEAD >/dev/null 2>&1

    ship_id=$("$WV" add "Ship overlap parity" 2>&1 | tail -1)
    ship_exit=0
    ship_output=$(WV_REQUIRE_LEARNING=1 WV_NONINTERACTIVE=1 "$WV" ship "$ship_id" --learning="$overlap_learning" --no-overlap-check 2>&1) || ship_exit=$?
    assert_equals "0" "$ship_exit" "ship accepts --no-overlap-check"
    ship_meta=$("$WV" show "$ship_id" --json 2>&1)
    assert_contains "$ship_meta" '"status":"done"' "ship still closes the node with --no-overlap-check"
    assert_not_contains "$ship_meta" "learning_overlap_noted" "ship forwards no-overlap-check to done"

    ship_status=$("$WV" status --json 2>&1)
    assert_contains "$ship_status" '"git_sync_pending": true' "ship leaves pending remote sync surfaced in status"
    assert_contains "$ship_status" '"git_sync_reason": "dirty_weave"' "ship status reports dirty_weave after local-only completion"

    git remote remove origin >/dev/null 2>&1 || true
    local ship_local_id ship_local_exit ship_local_meta ship_local_status
    ship_local_id=$("$WV" add "Ship local complete" 2>&1 | tail -1)
    ship_local_exit=0
    WV_REQUIRE_LEARNING=1 WV_NONINTERACTIVE=1 "$WV" ship "$ship_local_id" --learning="$overlap_learning" --no-overlap-check >/dev/null 2>&1 || ship_local_exit=$?
    assert_equals "0" "$ship_local_exit" "ship succeeds without an upstream"
    ship_local_meta=$("$WV" show "$ship_local_id" --json 2>&1)
    assert_contains "$ship_local_meta" '"status":"done"' "ship still closes the node without an upstream"
    ship_local_status=$("$WV" status --json 2>&1)
    assert_contains "$ship_local_status" '"git_sync_pending": true' "status surfaces pending git sync without an upstream"
    assert_contains "$ship_local_status" '"git_sync_reason": "no_upstream"' "status reports no_upstream after local-only ship"

    cd "$old_pwd"
    export WV_HOT_ZONE="$old_hot"
    export WV_DB="$old_db"
    if [ -n "$old_project" ]; then
        export WV_PROJECT_DIR="$old_project"
    else
        unset WV_PROJECT_DIR
    fi

    # --acknowledge-overlap still clears legacy pending_close state (backward compat)
    local legacy_id legacy_meta legacy_exit legacy_output
    legacy_id=$("$WV" add "Legacy stuck node" 2>&1 | tail -1)
    legacy_meta=$(jq -n --arg node "$legacy_id" \
        '{"needs_human_verification": true, "pending_close": {"reason": "learning_overlap", "overlap_with": "wv-fake", "learning": "test", "created_at": "2026-01-01T00:00:00Z", "resume_command": ("wv done " + $node + " --acknowledge-overlap")}}')
    "$WV" update "$legacy_id" --metadata="$legacy_meta" >/dev/null 2>&1
    legacy_exit=0
    legacy_output=$(WV_REQUIRE_LEARNING=1 WV_NONINTERACTIVE=1 "$WV" done "$legacy_id" --acknowledge-overlap 2>&1) || legacy_exit=$?
    assert_equals "0" "$legacy_exit" "done clears legacy pending_close with --acknowledge-overlap"
    assert_contains "$legacy_output" "Closed" "acknowledge-overlap closes legacy stuck node"
}

test_done_stores_commit_hashes() {
    echo ""
    echo "Test: wv done stores attributed commit hashes"
    echo "==========================================="

    setup_test_env
    "$WV" init >/dev/null 2>&1
    git config user.name "Weave Test"
    git config user.email "weave-test@example.com"

    local id output node_json stored_commit stored_first head_sha
    id=$("$WV" add "Commit-linked close" 2>&1 | tail -1)
    "$WV" work "$id" >/dev/null 2>&1

    echo "tracked" > commit-linked.txt
    git add commit-linked.txt
    git commit -m "feat: commit-linked close" -m "Weave-ID: $id" -q

    output=$(WV_REQUIRE_LEARNING=1 "$WV" done "$id" --learning="decision: commit before done | pattern: use Weave-ID trailers for commit attribution | pitfall: unattributed commits never reach node metadata" 2>&1)
    assert_contains "$output" "Closed" "done succeeds when the work commit is attributed"

    head_sha=$(git rev-parse HEAD)
    node_json=$("$WV" show "$id" --json 2>&1)
    stored_commit=$(echo "$node_json" | jq -r '.[0].metadata | fromjson | .commit // empty' 2>/dev/null || echo "")
    stored_first=$(echo "$node_json" | jq -r '.[0].metadata | fromjson | .commits[0] // empty' 2>/dev/null || echo "")
    assert_equals "$head_sha" "$stored_commit" "done stores the primary commit hash in metadata"
    assert_equals "$head_sha" "$stored_first" "done stores the commit hash array in metadata"
}

test_done_prefers_implementation_commit_over_checkpoint() {
    echo ""
    echo "Test: wv done prefers implementation commit over checkpoint"
    echo "========================================================="

    setup_test_env
    "$WV" init >/dev/null 2>&1
    git config user.name "Weave Test"
    git config user.email "weave-test@example.com"

    local id output node_json stored_commit stored_first stored_second impl_sha checkpoint_sha
    id=$("$WV" add "Commit precedence close" 2>&1 | tail -1)
    "$WV" work "$id" >/dev/null 2>&1

    echo "tracked" > commit-precedence.txt
    git add commit-precedence.txt
    git commit -m "feat: implementation commit" -m "Weave-ID: $id" -q
    impl_sha=$(git rev-parse HEAD)

    git commit --allow-empty -m "chore(weave): auto-checkpoint 15:32 [skip ci]" -m "Weave-ID: $id" -q
    checkpoint_sha=$(git rev-parse HEAD)

    output=$(WV_REQUIRE_LEARNING=1 "$WV" done "$id" --learning="decision: keep work commits primary | pattern: relegate auto-checkpoints behind implementation commits | pitfall: raw git log order can promote checkpoint noise" 2>&1)
    assert_contains "$output" "Closed" "done succeeds when checkpoint and implementation commits are both attributed"

    node_json=$("$WV" show "$id" --json 2>&1)
    stored_commit=$(echo "$node_json" | jq -r '.[0].metadata | fromjson | .commit // empty' 2>/dev/null || echo "")
    stored_first=$(echo "$node_json" | jq -r '.[0].metadata | fromjson | .commits[0] // empty' 2>/dev/null || echo "")
    stored_second=$(echo "$node_json" | jq -r '.[0].metadata | fromjson | .commits[1] // empty' 2>/dev/null || echo "")
    assert_equals "$impl_sha" "$stored_commit" "done keeps the implementation commit as primary metadata"
    assert_equals "$impl_sha" "$stored_first" "done orders implementation commit first in commits metadata"
    assert_equals "$checkpoint_sha" "$stored_second" "done retains checkpoint commit as secondary attribution"
}

# ============================================================================
# Test: work
# ============================================================================
test_work() {
    echo ""
    echo "Test: wv work"
    echo "============="

    setup_test_env
    "$WV" init >/dev/null 2>&1

    # Create a node
    local id
    id=$("$WV" add "Task to work on" 2>&1 | tail -1)

    # Claim work
    local output
    output=$("$WV" work "$id" 2>&1)
    assert_contains "$output" "Claimed" "work outputs claim message"
    assert_contains "$output" "WV_ACTIVE=$id" "work shows export command"

    # Verify status changed to active
    local show_output
    show_output=$("$WV" show "$id" 2>&1)
    assert_contains "$show_output" "active" "work sets status to active"

    # Work --quiet outputs only export
    output=$("$WV" work "$id" --quiet 2>&1)
    assert_equals "export WV_ACTIVE=$id" "$output" "work --quiet outputs only export"

    # Context uses WV_ACTIVE when set
    export WV_ACTIVE="$id"
    output=$("$WV" context --json 2>&1)
    assert_contains "$output" "\"id\": \"$id\"" "context uses WV_ACTIVE"
    unset WV_ACTIVE

    # Context surfaces linked finding metadata via resolves edge
    local finding_id
    finding_id=$("$WV" add "Investigate open-node false positive" --metadata='{"type":"finding","finding":{"violation_type":"R10:open_node_at_end","root_cause":"bootstrap omitted active-node type","proposed_fix":"record active_node_type in session_start metadata","confidence":"high","fixable":true}}' 2>&1 | tail -1)
    "$WV" link "$id" "$finding_id" --type=resolves >/dev/null 2>&1
    output=$("$WV" context "$id" --json 2>&1)
    assert_contains "$output" "\"finding\"" "context includes finding block when resolves edge exists"
    assert_contains "$output" "\"violation_type\": \"R10:open_node_at_end\"" "context finding includes violation type"

    # Context falls back to primary node from wv work
    output=$("$WV" context --json 2>&1)
    assert_contains "$output" "\"id\": \"$id\"" "context falls back to primary node"

    # Context without primary or WV_ACTIVE shows usage
    rm -f "$WV_HOT_ZONE/primary" 2>/dev/null || true
    output=$("$WV" context --json 2>&1 || true)
    assert_contains "$output" "wv work" "context without ID suggests wv work"

    # Work on non-existent node fails
    assert_fails "work on non-existent node fails" "$WV" work "wv-0000"
}

# ============================================================================
# Test: list
# ============================================================================
test_list() {
    echo ""
    echo "Test: wv list"
    echo "============="

    setup_test_env
    "$WV" init >/dev/null 2>&1

    # Create nodes with different statuses
    local id1 id2 id3
    id1=$("$WV" add "Todo task" --status=todo 2>&1 | tail -1)
    id2=$("$WV" add "Active task" --status=active --criteria="tests pass" --risks=low 2>&1 | tail -1)
    id3=$("$WV" add "Done task" --status=done 2>&1 | tail -1)

    # Default list excludes done
    local output
    output=$("$WV" list 2>&1)
    assert_contains "$output" "$id1" "list shows todo nodes"
    assert_contains "$output" "$id2" "list shows active nodes"
    assert_not_contains "$output" "$id3" "list excludes done nodes by default"

    # List --all includes done
    output=$("$WV" list --all 2>&1)
    assert_contains "$output" "$id3" "list --all includes done nodes"

    # List --json outputs JSON array
    output=$("$WV" list --json 2>&1)
    assert_contains "$output" "[" "list --json outputs JSON array"
    assert_contains "$output" '"id"' "list --json includes id field"

    # List with status filter
    output=$("$WV" list --status=active 2>&1)
    assert_contains "$output" "$id2" "list --status=active shows active"
    assert_not_contains "$output" "$id1" "list --status=active excludes todo"
}

# ============================================================================
# Test: show
# ============================================================================
test_show() {
    echo ""
    echo "Test: wv show"
    echo "============="

    setup_test_env
    "$WV" init >/dev/null 2>&1

    # Create a node with metadata
    local id
    id=$("$WV" add "Show test node" --metadata='{"priority":2,"type":"feature"}' 2>&1 | tail -1)

    # Basic show
    local output
    output=$("$WV" show "$id" 2>&1)
    assert_contains "$output" "$id" "show displays node ID"
    assert_contains "$output" "Show test node" "show displays node text"
    assert_contains "$output" "todo" "show displays status"

    # Show --json
    output=$("$WV" show "$id" --json 2>&1)
    assert_contains "$output" '"id"' "show --json has id field"
    assert_contains "$output" '"text"' "show --json has text field"
    assert_contains "$output" '"status"' "show --json has status field"
    assert_contains "$output" 'metadata' "show --json has metadata field"

    # Show non-existent node returns error
    assert_fails "show non-existent node fails" "$WV" show "wv-0000"

    # Show without ID fails
    assert_fails "show without ID fails" "$WV" show

    # current_intent round-trip: set via wv update, visible in wv show, survives wv load
    local intent_id
    intent_id=$("$WV" add "Intent test node" 2>&1 | tail -1)
    "$WV" update "$intent_id" --metadata='{"current_intent":"testing intent persistence"}' >/dev/null 2>&1
    output=$("$WV" show "$intent_id" 2>&1)
    assert_contains "$output" "Intent:" "current_intent appears as Intent: in wv show"
    assert_contains "$output" "testing intent persistence" "current_intent value shown in wv show"
    # Simulate wv load round-trip (dump + reload from state.sql)
    "$WV" sync >/dev/null 2>&1 || true
    output=$("$WV" show "$intent_id" 2>&1)
    assert_contains "$output" "testing intent persistence" "current_intent survives sync/load round-trip"
}

# ============================================================================
# Test: ready
# ============================================================================
test_ready() {
    echo ""
    echo "Test: wv ready"
    echo "=============="

    setup_test_env
    "$WV" init >/dev/null 2>&1

    # Create unblocked nodes
    local id1 id2 id3
    id1=$("$WV" add "Ready task 1" 2>&1 | tail -1)
    id2=$("$WV" add "Ready task 2" 2>&1 | tail -1)

    # Create a blocked node
    id3=$("$WV" add "Blocked task" 2>&1 | tail -1)
    "$WV" block "$id3" --by="$id1" >/dev/null 2>&1

    # Ready shows unblocked nodes
    local output
    output=$("$WV" ready 2>&1)
    assert_contains "$output" "$id1" "ready shows unblocked node"
    assert_contains "$output" "$id2" "ready shows second unblocked node"
    assert_not_contains "$output" "$id3" "ready excludes blocked node"

    # Ready --json outputs JSON
    output=$("$WV" ready --json 2>&1)
    assert_contains "$output" "[" "ready --json outputs JSON array"

    # Ready --count outputs count only
    output=$("$WV" ready --count 2>&1)
    assert_equals "2" "$output" "ready --count returns correct count"

    # Complete a blocker and verify blocked node becomes ready
    "$WV" done "$id1" >/dev/null 2>&1
    output=$("$WV" ready 2>&1)
    assert_contains "$output" "$id3" "ready shows newly unblocked node"
}

# ============================================================================
# Test: status
# ============================================================================
test_status() {
    echo ""
    echo "Test: wv status"
    echo "==============="

    setup_test_env
    "$WV" init >/dev/null 2>&1

    # Create some nodes
    "$WV" add "Task 1" --status=todo >/dev/null 2>&1
    "$WV" add "Task 2" --status=active --criteria="status shows active work" --risks=low >/dev/null 2>&1
    local id3
    id3=$("$WV" add "Task 3" 2>&1 | tail -1)
    "$WV" done "$id3" >/dev/null 2>&1

    # Status shows summary
    local output
    output=$("$WV" status 2>&1)
    assert_contains "$output" "active" "status shows active count"
    assert_contains "$output" "ready" "status shows ready count"
    assert_contains "$output" "blocked" "status shows blocked count"

    # Status shows active work prominently
    assert_contains "$output" "Task 2" "status highlights active work"
}

# ============================================================================
# Test: update --metadata merge (SQL json_patch port; H1.T2)
# ============================================================================
# Regression for the silent-fallback bug where jq merge failure caused the new
# metadata to overwrite the stored value, wiping existing keys. Exercises the
# conditions listed in PROPOSAL-wv-post-split-hardening Target 3.
test_stale_active_marker() {
    echo ""
    echo "Test: stale-active marker (A1)"
    echo "=============================="

    setup_test_env
    "$WV" init >/dev/null 2>&1

    local fresh_id stale_id
    fresh_id=$("$WV" add "fresh active task" --status=active --criteria="fresh node visible in status" --risks=low 2>&1 | tail -1)
    stale_id=$("$WV" add "stale active task" --status=active --criteria="stale node visible in status" --risks=low 2>&1 | tail -1)

    # Backdate the stale node 25 hours via direct sqlite3
    sqlite3 "$WV_DB" "UPDATE nodes SET updated_at = datetime('now', '-25 hours') WHERE id='$stale_id';"

    local status_out ready_out
    status_out=$("$WV" status 2>&1)
    assert_contains "$status_out" "1 stale" "status reports 1 stale active node"

    ready_out=$("$WV" ready 2>&1)
    assert_contains "$ready_out" "Stale active" "ready output includes stale-active section"
    assert_contains "$ready_out" "$stale_id" "stale section lists the stale node id"
    assert_contains "$ready_out" "[stale" "stale entry carries [stale Nd] marker"
    assert_not_contains "$ready_out" "$fresh_id" "fresh active node not listed in stale section"

    # JSON status carries the field
    local status_json
    status_json=$("$WV" status --json 2>&1)
    local stale_json
    stale_json=$(echo "$status_json" | jq -r '.stale')
    assert_equals "1" "$stale_json" "status --json includes stale count"

    # Bootstrap mode suppresses the listing but keeps the count
    local boot_out
    boot_out=$("$WV" status --mode=bootstrap 2>&1)
    assert_contains "$boot_out" "1 stale" "bootstrap mode keeps stale count in status"
    local ready_boot
    ready_boot=$("$WV" ready --mode=bootstrap 2>&1)
    assert_not_contains "$ready_boot" "Stale active" "bootstrap mode suppresses stale listing in ready"
}

test_ready_relevance_boost() {
    echo ""
    echo "Test: ready relevance boost via touched_files (B1)"
    echo "=================================================="

    setup_test_env
    "$WV" init >/dev/null 2>&1

    local _repo_root _repo_hash ring_dir ring_file
    _repo_root=$(git rev-parse --show-toplevel)
    _repo_hash=$(echo "$_repo_root" | md5sum | cut -c1-8)
    ring_dir="/dev/shm/weave/${_repo_hash}"
    ring_file="$ring_dir/recent-edits.txt"
    mkdir -p "$ring_dir"
    rm -f "$ring_file"

    # Two ready nodes: B has touched_files matching what we'll edit, A does not.
    # Sleep 1s between adds so created_at timestamps differ — SQLite has 1-second
    # granularity; same-second nodes fall back to id ASC tiebreaker which is non-deterministic.
    local node_a node_b
    node_a=$("$WV" add "Task A no overlap" 2>&1 | tail -1)
    sleep 1
    node_b=$("$WV" add "Task B with overlap" 2>&1 | tail -1)
    "$WV" update "$node_b" --metadata='{"touched_files":["scripts/foo.sh"]}' >/dev/null 2>&1

    # Without ring: default ordering (A created first).
    local default_first
    default_first=$("$WV" ready --json 2>&1 | jq -r '.[0].id')
    assert_equals "$node_a" "$default_first" "ready uses created_at order without ring"

    # With ring containing scripts/foo.sh: B floats to top.
    echo "scripts/foo.sh" > "$ring_file"
    local boosted_first
    boosted_first=$("$WV" ready --json 2>&1 | jq -r '.[0].id')
    assert_equals "$node_b" "$boosted_first" "ready boosts node whose touched_files overlaps ring"

    # Text output shows [touched N] marker on boosted node.
    local text_out
    text_out=$("$WV" ready 2>&1)
    assert_contains "$text_out" "[touched 1]" "ready text output marks relevance count"

    # Empty ring file: behaves as if no ring (default order).
    : > "$ring_file"
    default_first=$("$WV" ready --json 2>&1 | jq -r '.[0].id')
    assert_equals "$node_a" "$default_first" "ready falls back to default order with empty ring"

    rm -f "$ring_file"
}

test_done_contradiction() {
    echo ""
    echo "Test: done contradiction detection (A3)"
    echo "======================================="

    setup_test_env
    "$WV" init >/dev/null 2>&1

    # FTS5 search uses first 3 words of length >4 with AND semantics.
    # Both learnings must share those terms; polarity is computed across the full text.
    # Shared search terms: "decision Poetry Python" (both nodes); polarities differ.
    local seed_id
    seed_id=$("$WV" add "Seed Poetry decision" 2>&1 | tail -1)
    WV_REQUIRE_LEARNING=1 "$WV" done "$seed_id" \
        --learning="decision Poetry Python projects always prefer use it" \
        >/dev/null 2>&1

    # Same-polarity follow-up (positive vs positive) should NOT trigger contradiction.
    local same_id same_meta
    same_id=$("$WV" add "Same direction Poetry note" 2>&1 | tail -1)
    WV_REQUIRE_LEARNING=1 "$WV" done "$same_id" \
        --learning="decision Poetry Python projects always keep using it should" \
        >/dev/null 2>&1
    same_meta=$("$WV" show "$same_id" --json 2>&1)
    assert_contains "$same_meta" "learning_overlap_noted" \
        "same-direction overlap is recorded as overlap (FTS5 match fired)"
    assert_not_contains "$same_meta" "learning_contradiction_noted" \
        "same-polarity overlap does not flag contradiction"

    # Opposite-polarity (negative: avoid/never/do not) SHOULD trigger contradiction.
    local opp_id opp_out opp_meta
    opp_id=$("$WV" add "Opposite Poetry pitfall" 2>&1 | tail -1)
    opp_out=$(WV_REQUIRE_LEARNING=1 "$WV" done "$opp_id" \
        --learning="decision Poetry Python projects avoid never adopt do not" 2>&1)
    assert_contains "$opp_out" "Closed" "opposite-polarity learning still closes node (advisory not blocking)"
    opp_meta=$("$WV" show "$opp_id" --json 2>&1)
    assert_contains "$opp_meta" "learning_contradiction_noted" \
        "opposite-polarity overlap records learning_contradiction_noted in metadata"
    assert_contains "$opp_meta" "learning_overlap_noted" \
        "contradiction also keeps learning_overlap_noted (overlap is the basis)"

    # --no-overlap-check bypasses entirely (no metadata field written)
    local skip_id skip_meta
    skip_id=$("$WV" add "Skip overlap check" 2>&1 | tail -1)
    WV_REQUIRE_LEARNING=1 "$WV" done "$skip_id" \
        --learning="decision Poetry Python projects avoid never adopt" \
        --no-overlap-check >/dev/null 2>&1
    skip_meta=$("$WV" show "$skip_id" --json 2>&1)
    assert_not_contains "$skip_meta" "learning_contradiction_noted" \
        "--no-overlap-check skips contradiction detection entirely"
    assert_not_contains "$skip_meta" "learning_overlap_noted" \
        "--no-overlap-check skips overlap detection entirely"
}

test_update_metadata_merge() {
    echo ""
    echo "Test: wv update --metadata merge"
    echo "================================"

    setup_test_env
    "$WV" init >/dev/null 2>&1

    local id1 id2 id3 meta
    # Case A — node with no initial metadata: first update stores the new blob.
    id1=$("$WV" add "no initial meta" 2>&1 | tail -1)
    "$WV" update "$id1" --metadata='{"k":"v"}' >/dev/null 2>&1
    meta=$("$WV" show "$id1" --json | jq -r '.[0].metadata')
    assert_contains "$meta" '"k":"v"' "merge: empty → new key stored"

    # Case B — existing key preserved, new key added.
    id2=$("$WV" add "existing meta" --criteria="c1" 2>&1 | tail -1)
    "$WV" update "$id2" --metadata='{"extra":"z"}' >/dev/null 2>&1
    meta=$("$WV" show "$id2" --json | jq -r '.[0].metadata')
    assert_contains "$meta" 'done_criteria' "merge: existing key preserved"
    assert_contains "$meta" '"extra":"z"' "merge: new key added"

    # Case C — payload with unicode, apostrophe, and literal '||' does not trip
    # a silent fallback (the old code's jq || echo fallback would have nuked
    # done_criteria on any jq failure).
    id3=$("$WV" add "stress payload" --criteria="c1" 2>&1 | tail -1)
    "$WV" update "$id3" --metadata='{"note":"O'\''Donovan → test || foo"}' >/dev/null 2>&1
    meta=$("$WV" show "$id3" --json | jq -r '.[0].metadata')
    assert_contains "$meta" 'done_criteria' "merge: stress payload preserves existing key"
    assert_contains "$meta" "O'Donovan" "merge: apostrophe round-trips"
    assert_contains "$meta" '||' "merge: literal || survives"

    # Case D — invalid JSON is rejected loudly; stored metadata is unchanged.
    local id4 before after
    id4=$("$WV" add "invalid json rejected" --criteria="c1" 2>&1 | tail -1)
    before=$("$WV" show "$id4" --json | jq -r '.[0].metadata')
    if "$WV" update "$id4" --metadata='{"bad": syntax}' >/dev/null 2>&1; then
        echo -e "${RED}✗${NC} invalid JSON should have been rejected"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        TESTS_RUN=$((TESTS_RUN + 1))
    else
        echo -e "${GREEN}✓${NC} invalid JSON rejected with non-zero exit"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        TESTS_RUN=$((TESTS_RUN + 1))
    fi
    after=$("$WV" show "$id4" --json | jq -r '.[0].metadata')
    assert_equals "$before" "$after" "rejected update leaves metadata untouched"

    # Case E — immediate update-then-claim sequence (the primary Target 1
    # friction). After setting done_criteria via --metadata, wv work must pass
    # the pre-claim readiness check on the very next invocation.
    local id5
    id5=$("$WV" add "claim readiness" 2>&1 | tail -1)
    "$WV" update "$id5" --metadata='{"done_criteria":"c","risks":[],"risk_level":"low"}' >/dev/null 2>&1
    meta=$("$WV" show "$id5" --json | jq -r '.[0].metadata')
    assert_contains "$meta" '"done_criteria":"c"' "update-then-claim: done_criteria visible immediately"

    # Case F — split-form metadata is accepted instead of falling through to
    # "no updates specified".
    local id6
    id6=$("$WV" add "split-form metadata" 2>&1 | tail -1)
    "$WV" update "$id6" --metadata '{"split":true}' >/dev/null 2>&1
    meta=$("$WV" show "$id6" --json | jq -r '.[0].metadata')
    assert_contains "$meta" '"split":true' "split-form --metadata merges JSON"

    # Case G — file-backed metadata avoids shell-quoting hazards for larger JSON.
    local id7 meta_file
    id7=$("$WV" add "file metadata" 2>&1 | tail -1)
    meta_file=$(mktemp)
    printf '%s\n' '{"from_file":{"path":"ok","count":2}}' > "$meta_file"
    "$WV" update "$id7" --metadata-file "$meta_file" >/dev/null 2>&1
    rm -f "$meta_file"
    meta=$("$WV" show "$id7" --json | jq -r '.[0].metadata')
    assert_contains "$meta" '"from_file"' "--metadata-file merges JSON from file"
    assert_contains "$meta" '"count":2' "--metadata-file preserves nested values"

    # Case H — missing split-form value should produce an actionable diagnostic.
    local id8 missing_value_output
    id8=$("$WV" add "missing metadata value" 2>&1 | tail -1)
    if missing_value_output=$("$WV" update "$id8" --metadata 2>&1); then
        echo -e "${RED}✗${NC} missing split-form metadata value should fail"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        TESTS_RUN=$((TESTS_RUN + 1))
    else
        echo -e "${GREEN}✓${NC} missing split-form metadata value rejected"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        TESTS_RUN=$((TESTS_RUN + 1))
        assert_contains "$missing_value_output" "--metadata requires a JSON argument" "missing split-form metadata shows actionable error"
        assert_contains "$missing_value_output" "--metadata-file <path>" "missing split-form metadata suggests safer input"
    fi

    # Case I — subcommand help is reachable from `wv update --help` and advertises
    # both metadata forms.
    local update_help
    update_help=$("$WV" update --help 2>&1)
    assert_contains "$update_help" "Usage: wv update <id>" "wv update --help shows subcommand usage"
    assert_contains "$update_help" "--metadata <json>" "wv update --help documents split-form metadata"
    assert_contains "$update_help" "--metadata-file <path>" "wv update --help documents safer file-backed metadata"
}

test_help_surfaces() {
    echo ""
    echo "Test: CLI help surfaces"
    echo "======================="

    setup_test_env
    "$WV" init >/dev/null 2>&1

    local root_help
    root_help=$("$WV" --help 2>&1)

    local expected_commands=(
        init add delete done ship batch-done bulk-update work preflight recover bootstrap
        overview cache pending-close ready list show status update touch allowed-tools quick
        block link unlink resolve related edges path tree plan enrich-topology context search
        reindex learnings breadcrumbs digest session-summary audit-pitfalls edge-types init-repo
        doctor selftest mcp-status health guide prune clean-ghosts compact refs import quality
        findings analyze batch sync load
    )

    local cmd
    for cmd in "${expected_commands[@]}"; do
        assert_contains "$root_help" "$cmd" "root help lists $cmd"
    done
    assert_contains "$root_help" "wv help <command>" "root help documents focused help entrypoint"
    assert_contains "$root_help" "wv <command> --help" "root help documents per-command help flag"

    local show_help
    show_help=$("$WV" show --help 2>&1)
    assert_contains "$show_help" "Usage: wv show <id>" "show --help prints focused usage"
    assert_not_contains "$show_help" "invalid node ID or alias" "show --help bypasses ID validation errors"

    local link_help
    link_help=$("$WV" link --help 2>&1)
    assert_contains "$link_help" "Usage: wv link <from-id> <to-id>" "link --help prints focused usage"
    assert_not_contains "$link_help" "Error: usage" "link --help no longer falls through to validation error text"

    local work_help
    work_help=$("$WV" help work 2>&1)
    assert_contains "$work_help" "Usage: wv work <id>" "wv help work prints focused usage"
    assert_contains "$work_help" "allowed tool list" "wv help work includes command summary"

    local quality_scan_help
    quality_scan_help=$("$WV" help quality scan 2>&1)
    assert_contains "$quality_scan_help" "Usage: wv quality scan" "nested help delegates to quality scan help"
}

# ============================================================================
# Test: orphan prevention
# ============================================================================
test_orphan_prevention() {
    echo ""
    echo "Test: orphan prevention"
    echo "======================="

    setup_test_env
    "$WV" init >/dev/null 2>&1

    # Create an epic (type=epic in metadata) as root
    local epic_id
    epic_id=$("$WV" add "Root epic" --metadata='{"type":"epic"}' 2>&1 | tail -1)
    assert_contains "$epic_id" "wv-" "epic created successfully"

    # With an active epic, adding a task without --parent must fail
    local output
    output=$("$WV" add "Orphan task attempt" 2>&1 || true)
    assert_contains "$output" "--parent" "orphan guard fires when active epic exists"
    assert_contains "$output" "Error" "orphan guard prints error message"

    # Verify the node was rolled back (guard deletes node on error)
    # Note: the add output WILL contain wv-XXXX from the creation step before rollback.
    # The correct check is that the node doesn't appear in the list after the failed add.
    local list_output
    list_output=$("$WV" list 2>&1)
    assert_not_contains "$list_output" "Orphan task attempt" "orphan guard rolls back the node"

    # With --parent specified, add succeeds
    local child_id
    child_id=$("$WV" add "Linked child task" --parent="$epic_id" 2>&1 | tail -1)
    assert_contains "$child_id" "wv-" "add with --parent succeeds"

    # With --force, add succeeds even without --parent
    local forced_id
    forced_id=$("$WV" add "Force-created task" --force 2>&1 | tail -1)
    assert_contains "$forced_id" "wv-" "add with --force bypasses orphan guard"

    # No active epics — task allowed without --parent (the gap that let wv-2efef5 exist)
    # Mark the epic done so no active epics remain
    "$WV" done "$epic_id" >/dev/null 2>&1
    local free_id
    free_id=$("$WV" add "No-parent task when no active epics" 2>&1 | tail -1)
    assert_contains "$free_id" "wv-" "add without --parent allowed when no active epics exist"
}

# ============================================================================
# Test: findings promote
# ============================================================================
test_findings_promote() {
    echo ""
    echo "Test: wv findings promote"
    echo "========================="

    setup_test_env
    "$WV" init >/dev/null 2>&1

    local source_id parent_id output all_nodes
    source_id=$("$WV" add "Investigate install hook drift" 2>&1 | tail -1)
    "$WV" done "$source_id" \
        --learning="pitfall: hooks copied by install.sh but not wired into settings.json; add settings wiring in install.sh" \
        >/dev/null 2>&1

    output=$(WV_CLI="$WV" PATH="$PROJECT_ROOT/scripts:$PATH" "$WV" findings promote --json 2>&1)
    assert_contains "$output" '"candidates"' "findings promote defaults to dry-run candidates"
    assert_contains "$output" "$source_id" "findings promote reports source node"
    assert_fails "findings promote --apply requires parent" "$WV" findings promote --apply

    parent_id=$("$WV" add "Review promoted historical findings" 2>&1 | tail -1)
    output=$(WV_CLI="$WV" PATH="$PROJECT_ROOT/scripts:$PATH" \
        "$WV" findings promote --apply --parent="$parent_id" --json 2>&1)
    assert_contains "$output" '"promoted"' "findings promote apply returns promoted nodes"
    assert_contains "$output" "$parent_id" "findings promote apply reports parent"

    all_nodes=$("$WV" list --all --json 2>&1)
    assert_contains "$all_nodes" 'historical_finding_id' "promoted finding stores idempotency metadata"
    assert_contains "$all_nodes" '"type\": \"finding\"' "promoted finding is stored as finding node"
}

# ============================================================================
# Test: policy trigger — done gate on mccabe_max breach
# ============================================================================
test_policy_trigger() {
    echo ""
    echo "Test: policy trigger — done gate on metric and trend breaches"
    echo "============================================================"

    setup_test_env
    "$WV" init >/dev/null 2>&1

    # Seed a file_metrics fixture table (owned by weave_quality in production;
    # created here as a minimal stub so the trigger join has data to read).
    sqlite3 "$WV_DB" <<'SQL'
CREATE TABLE IF NOT EXISTS file_metrics (
    path        TEXT PRIMARY KEY,
    mccabe_max  INTEGER NOT NULL DEFAULT 0,
    gini        REAL    NOT NULL DEFAULT 0.0
);
SQL

    # --- Case 1: node with a breaching file should NOT be closeable ---
    local breach_id
    breach_id=$("$WV" add "Node with complex file" 2>&1 | tail -1)
    "$WV" work "$breach_id" >/dev/null 2>&1

    # WV_REQUIRE_QUALITY=0 bypasses P2 refresh so we can seed file_metrics directly.
    sqlite3 "$WV_DB" <<SQL
INSERT OR REPLACE INTO file_metrics(path, mccabe_max) VALUES ('src/complex.py', 20);
INSERT OR REPLACE INTO node_files(node_id, path) VALUES ('$breach_id', 'src/complex.py');
SQL

    local breach_out
    breach_out=$(WV_REQUIRE_QUALITY=0 "$WV" done "$breach_id" 2>&1 || true)
    assert_contains "$breach_out" "GraphPolicyViolation" \
        "done is blocked when mccabe_max exceeds threshold"

    local breach_status
    breach_status=$(sqlite3 "$WV_DB" "SELECT status FROM nodes WHERE id='$breach_id';")
    assert_equals "active" "$breach_status" \
        "node remains active after trigger abort"

    # --- Case 4: trigger payload is JSON with required keys ---
    local payload_valid
    payload_valid=$(echo "$breach_out" | grep -o '{[^}]*}' | head -1 | python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read().strip())
    keys = {'error','threshold','actual','path'}
    print('True' if keys.issubset(d.keys()) else 'False: missing '+str(keys-d.keys()))
except Exception as e:
    print('False: '+str(e))
" 2>/dev/null || echo "False: python3 unavailable")
    assert_equals "True" "$payload_valid" \
        "trigger abort payload is JSON with error/threshold/actual/path keys"

    local breach_threshold
    breach_threshold=$(echo "$breach_out" | grep -o '"threshold":"[^"]*"' | head -1 | cut -d '"' -f4)
    assert_equals "mccabe_max" "$breach_threshold" \
        "mccabe policy violation payload names the breached threshold"

    # --- Case 2: node whose file is within threshold closes normally ---
    local clean_id
    clean_id=$("$WV" add "Node with clean file" 2>&1 | tail -1)
    "$WV" work "$clean_id" >/dev/null 2>&1

    sqlite3 "$WV_DB" <<SQL
INSERT OR REPLACE INTO file_metrics(path, mccabe_max) VALUES ('src/simple.py', 5);
INSERT OR REPLACE INTO node_files(node_id, path) VALUES ('$clean_id', 'src/simple.py');
SQL

    local clean_out
    clean_out=$(WV_REQUIRE_QUALITY=0 "$WV" done "$clean_id" 2>&1)
    assert_contains "$clean_out" "Closed" \
        "done succeeds when mccabe_max is within threshold"

    # --- Case 3: FTS search still works after trigger addition (no regression) ---
    local search_id
    search_id=$("$WV" add "Policy trigger regression check node" 2>&1 | tail -1)
    WV_REQUIRE_QUALITY=0 "$WV" done "$search_id" >/dev/null 2>&1
    local search_out
    search_out=$("$WV" search "regression check" 2>&1)
    assert_contains "$search_out" "regression" \
        "FTS search unaffected by policy trigger (no AFTER UPDATE regression)"

    # --- Case 5: deteriorating trend can be promoted to a hard gate ---
    sqlite3 "$WV_DB" <<'SQL'
INSERT OR REPLACE INTO policy_thresholds(key, value) VALUES ('trend_deteriorating', 1);
SQL

    local trend_id
    trend_id=$("$WV" add "Node with deteriorating trend" 2>&1 | tail -1)
    "$WV" work "$trend_id" >/dev/null 2>&1

    sqlite3 "$WV_DB" <<SQL
INSERT OR REPLACE INTO file_metrics(path, mccabe_max) VALUES ('src/trending.py', 5);
INSERT OR REPLACE INTO file_trend(path, direction) VALUES ('src/trending.py', 'deteriorating');
INSERT OR REPLACE INTO node_files(node_id, path) VALUES ('$trend_id', 'src/trending.py');
SQL

    local trend_out
    trend_out=$(WV_REQUIRE_QUALITY=0 "$WV" done "$trend_id" 2>&1 || true)
    assert_contains "$trend_out" "GraphPolicyViolation" \
        "done is blocked when deteriorating trend gate is enabled"
    assert_contains "$trend_out" '"path":"src/trending.py"' \
        "trend policy violation payload includes the blocking path"
    assert_contains "$trend_out" '"direction":"deteriorating"' \
        "trend policy violation payload includes the trend direction"

    local trend_threshold
    trend_threshold=$(echo "$trend_out" | grep -o '"threshold":"[^"]*"' | head -1 | cut -d '"' -f4)
    assert_equals "trend_deteriorating" "$trend_threshold" \
        "trend policy violation payload names the breached threshold"

    local trend_status
    trend_status=$(sqlite3 "$WV_DB" "SELECT status FROM nodes WHERE id='$trend_id';")
    assert_equals "active" "$trend_status" \
        "node remains active after trend trigger abort"
}

test_trend_signal_wiring() {
    echo ""
    echo "Test: P5b — file_trend table and _done_refresh_trend_signals"
    echo "============================================================="

    setup_test_env
    "$WV" init >/dev/null 2>&1

    # --- Case 1: file_trend table exists after wv init ---
    local table_exists
    table_exists=$(sqlite3 "$WV_DB" \
        "SELECT name FROM sqlite_master WHERE type='table' AND name='file_trend';" 2>/dev/null)
    assert_equals "file_trend" "$table_exists" \
        "file_trend table exists after wv init"

    # --- Case 2: WV_REQUIRE_QUALITY=0 skips trend refresh silently ---
    local skip_id
    skip_id=$("$WV" add "Trend skip test node" 2>&1 | tail -1)
    "$WV" work "$skip_id" >/dev/null 2>&1
    sqlite3 "$WV_DB" <<SQL
INSERT OR IGNORE INTO node_files(node_id, path) VALUES ('$skip_id', 'src/trend_file.py');
SQL
    local skip_out
    skip_out=$(WV_REQUIRE_QUALITY=0 "$WV" done "$skip_id" --skip-verification 2>&1)
    assert_contains "$skip_out" "Closed" \
        "wv done succeeds with trend refresh skipped (WV_REQUIRE_QUALITY=0)"

    local trend_count
    trend_count=$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM file_trend;" 2>/dev/null)
    assert_equals "0" "$trend_count" \
        "file_trend remains empty when WV_REQUIRE_QUALITY=0"

    # --- Case 3: migration path also creates file_trend ---
    local migrated_db
    migrated_db=$(mktemp /tmp/wv-migtest-XXXXXX.db)
    sqlite3 "$migrated_db" <<'SQL'
CREATE TABLE IF NOT EXISTS nodes (id TEXT PRIMARY KEY, text TEXT, status TEXT,
    metadata TEXT DEFAULT '{}', created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP);
CREATE TABLE IF NOT EXISTS edges (source TEXT, target TEXT, type TEXT);
SQL
    WV_DB="$migrated_db" bash -c "
        source '$PROJECT_ROOT/scripts/lib/wv-db.sh'
        db_migrate_policy_tables
    " 2>/dev/null
    local mig_table
    mig_table=$(sqlite3 "$migrated_db" \
        "SELECT name FROM sqlite_master WHERE type='table' AND name='file_trend';" 2>/dev/null)
    rm -f "$migrated_db"
    assert_equals "file_trend" "$mig_table" \
        "file_trend table created by db_migrate_policy_tables on existing DB"
}

test_chunk_store_schema() {
    echo ""
    echo "Test: chunk store — schema and migration"
    echo "========================================"

    setup_test_env
    "$WV" init >/dev/null 2>&1

    # --- Case 1: chunks table exists after wv init ---
    local table_exists
    table_exists=$(sqlite3 "$WV_DB" \
        "SELECT name FROM sqlite_master WHERE type='table' AND name='chunks';" 2>/dev/null)
    assert_equals "chunks" "$table_exists" \
        "chunks table exists after wv init"

    # --- Case 2: chunks_fts virtual table exists ---
    local fts_exists
    fts_exists=$(sqlite3 "$WV_DB" \
        "SELECT name FROM sqlite_master WHERE type='table' AND name='chunks_fts';" 2>/dev/null)
    assert_equals "chunks_fts" "$fts_exists" \
        "chunks_fts virtual table exists after wv init"

    # --- Case 3: insert + FTS trigger fires ---
    sqlite3 "$WV_DB" <<'SQL'
INSERT INTO chunks(file, line_start, line_end, content)
VALUES ('src/foo.py', 1, 10, 'def compute_trend_direction(values):');
SQL
    local fts_hit
    fts_hit=$(sqlite3 "$WV_DB" \
        "SELECT COUNT(*) FROM chunks_fts WHERE chunks_fts MATCH 'compute_trend_direction';" 2>/dev/null)
    assert_equals "1" "$fts_hit" \
        "chunks_fts FTS5 trigger indexes inserted chunk content"

    # --- Case 4: migration creates chunks table on existing DB ---
    local migrated_db
    migrated_db=$(mktemp /tmp/wv-chunktest-XXXXXX.db)
    sqlite3 "$migrated_db" <<'SQL'
CREATE TABLE IF NOT EXISTS nodes (id TEXT PRIMARY KEY, text TEXT, status TEXT,
    metadata TEXT DEFAULT '{}', created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP);
CREATE TABLE IF NOT EXISTS edges (source TEXT, target TEXT, type TEXT);
SQL
    WV_DB="$migrated_db" bash -c "
        source '$PROJECT_ROOT/scripts/lib/wv-db.sh'
        db_migrate_chunks
    " 2>/dev/null
    local mig_table
    mig_table=$(sqlite3 "$migrated_db" \
        "SELECT name FROM sqlite_master WHERE type='table' AND name='chunks';" 2>/dev/null)
    rm -f "$migrated_db"
    assert_equals "chunks" "$mig_table" \
        "chunks table created by db_migrate_chunks on existing DB"
}

test_wv_index_command() {
    echo ""
    echo "Test: wv index — file walker, chunking, FTS population"
    echo "========================================================"

    setup_test_env
    "$WV" init >/dev/null 2>&1

    # --- Case 1: basic indexing produces chunks ---
    mkdir -p "$TEST_DIR/src"
    printf '%s\n' $(seq 1 60 | awk '{print "x = " $1}') > "$TEST_DIR/src/sample.py"
    local idx_out
    idx_out=$("$WV" index "$TEST_DIR/src" --no-embed --ext=.py 2>&1)
    local chunk_count
    chunk_count=$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM chunks;" 2>/dev/null)
    assert_success "wv index populates chunks table" test "$chunk_count" -gt 0

    # --- Case 2: JSON output has expected keys ---
    "$WV" index "$TEST_DIR/src" --no-embed --ext=.py --json > "$TEST_DIR/idx.json" 2>&1
    local has_files has_chunks
    has_files=$(jq -r 'has("files")' "$TEST_DIR/idx.json" 2>/dev/null || echo "false")
    has_chunks=$(jq -r 'has("chunks")' "$TEST_DIR/idx.json" 2>/dev/null || echo "false")
    assert_equals "true" "$has_files" \
        "wv index --json output has 'files' key"
    assert_equals "true" "$has_chunks" \
        "wv index --json output has 'chunks' key"

    # --- Case 3: indexed content is FTS searchable ---
    sqlite3 "$WV_DB" "DELETE FROM chunks;" 2>/dev/null
    printf 'def unique_sentinel_function_abc():\n    pass\n' > "$TEST_DIR/src/sentinel.py"
    "$WV" index "$TEST_DIR/src" --no-embed --ext=.py >/dev/null 2>&1
    local fts_hit
    fts_hit=$(sqlite3 "$WV_DB" \
        "SELECT COUNT(*) FROM chunks_fts WHERE chunks_fts MATCH 'unique_sentinel_function_abc';" 2>/dev/null)
    assert_equals "1" "$fts_hit" \
        "wv index content is FTS5 searchable via chunks_fts"

    # --- Case 4: re-indexing same file replaces chunks (no duplicates) ---
    local before_count after_count
    before_count=$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM chunks WHERE file LIKE '%sentinel.py';" 2>/dev/null)
    "$WV" index "$TEST_DIR/src" --no-embed --ext=.py >/dev/null 2>&1
    after_count=$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM chunks WHERE file LIKE '%sentinel.py';" 2>/dev/null)
    assert_equals "$before_count" "$after_count" \
        "re-indexing same file replaces chunks (no duplicates)"
}

test_wv_search_code() {
    echo ""
    echo "Test: wv search --code — hybrid code search via weave_search"
    echo "=============================================================="

    setup_test_env
    "$WV" init >/dev/null 2>&1

    # Seed a sentinel function so FTS can find it
    mkdir -p "$TEST_DIR/src"
    printf 'def sentinel_hybrid_search_fn():\n    """Return cosine embedding distance.\"\"\"\n    pass\n' \
        > "$TEST_DIR/src/sentinel.py"
    "$WV" index "$TEST_DIR/src" --no-embed --ext=.py >/dev/null 2>&1

    # --- Case 1: --code routes to Python and returns JSON results ---
    local search_json
    search_json=$("$WV" search --code sentinel_hybrid_search_fn --json --mode=fts 2>/dev/null)
    local result_count
    result_count=$(echo "$search_json" | jq '.results | length' 2>/dev/null || echo "0")
    assert_success "wv search --code finds indexed content" test "$result_count" -gt 0

    # --- Case 2: JSON result contains required fields ---
    local has_file has_score has_snippet has_source
    has_file=$(echo "$search_json" | jq -r '.results[0] | has("file")' 2>/dev/null || echo "false")
    has_score=$(echo "$search_json" | jq -r '.results[0] | has("score")' 2>/dev/null || echo "false")
    has_snippet=$(echo "$search_json" | jq -r '.results[0] | has("snippet")' 2>/dev/null || echo "false")
    has_source=$(echo "$search_json" | jq -r '.results[0] | has("source")' 2>/dev/null || echo "false")
    assert_equals "true" "$has_file"    "wv search --code JSON has 'file' field"
    assert_equals "true" "$has_score"   "wv search --code JSON has 'score' field"
    assert_equals "true" "$has_snippet" "wv search --code JSON has 'snippet' field"
    assert_equals "true" "$has_source"  "wv search --code JSON has 'source' field"

    # --- Case 3: JSON output reports readiness diagnostics ---
    local chunks_ready readiness_has_quality readiness_has_node_files
    chunks_ready=$(echo "$search_json" | jq -r '.readiness.chunks.ready' 2>/dev/null || echo "false")
    readiness_has_quality=$(echo "$search_json" | jq -r '.readiness | has("quality_db")' 2>/dev/null || echo "false")
    readiness_has_node_files=$(echo "$search_json" | jq -r '.readiness | has("node_files")' 2>/dev/null || echo "false")
    assert_equals "true" "$chunks_ready" "wv search --code readiness marks indexed chunks ready"
    assert_equals "true" "$readiness_has_quality" "wv search --code JSON has quality_db readiness"
    assert_equals "true" "$readiness_has_node_files" "wv search --code JSON has node_files readiness"

    # --- Case 4: empty chunks report readiness instead of silent [] ---
    local empty_db="$TEST_DIR/empty.db"
    sqlite3 "$empty_db" "CREATE TABLE chunks (id INTEGER PRIMARY KEY); CREATE TABLE node_files (node_id TEXT, path TEXT);" 2>/dev/null
    local empty_out
    empty_out=$(WV_DB="$empty_db" "$WV" search --code nosuchterm --json --mode=fts 2>/dev/null || echo '{}')
    assert_equals "0" "$(echo "$empty_out" | jq -r '.results | length' 2>/dev/null || echo 1)" \
        "wv search --code with empty db returns zero results"
    assert_equals "false" "$(echo "$empty_out" | jq -r '.readiness.chunks.ready' 2>/dev/null || echo true)" \
        "wv search --code with empty db reports chunks not ready"
    assert_equals "empty" "$(echo "$empty_out" | jq -r '.readiness.chunks.status' 2>/dev/null || echo unknown)" \
        "wv search --code with empty db reports empty chunk readiness"

    # --- Case 5: custom WV_DB stays quiet and avoids graph-table pollution ---
    local custom_db="$TEST_DIR/custom-search.db"
    sqlite3 "$custom_db" "CREATE TABLE chunks (id INTEGER PRIMARY KEY); CREATE TABLE node_files (node_id TEXT, path TEXT);" 2>/dev/null
    local custom_out custom_edges
    custom_out=$(WV_DB="$custom_db" "$WV" search --code nosuchterm --json --mode=fts 2>&1 || true)
    custom_edges=$(sqlite3 "$custom_db" \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='edges';" 2>/dev/null || echo "0")
    assert_not_contains "$custom_out" "Parse error near line" \
        "wv search --code with custom WV_DB skips graph migration noise"
    assert_equals "0" "$custom_edges" \
        "wv search --code with custom WV_DB does not create graph tables"
}

test_preflight_policy_readiness() {
    echo ""
    echo "Test: wv preflight policy_readiness"
    echo "==================================="

    setup_test_env
    "$WV" init >/dev/null 2>&1

    # --- Case 1: node without tracked files is not policy-sensitive ---
    local idle_id idle_json
    idle_id=$("$WV" add "Idle policy preflight node" 2>&1 | tail -1)
    "$WV" work "$idle_id" >/dev/null 2>&1
    idle_json=$("$WV" preflight "$idle_id" 2>/dev/null)
    assert_equals "false" "$(echo "$idle_json" | jq -r '.policy_readiness.policy_sensitive' 2>/dev/null || echo true)" \
        "wv preflight reports nodes without tracked files as not policy-sensitive"
    assert_equals "false" "$(echo "$idle_json" | jq -r '.policy_readiness.blocking' 2>/dev/null || echo true)" \
        "wv preflight does not block when no tracked files exist"

    # --- Case 2: tracked files without quality.db block policy-sensitive completion ---
    local blocked_id blocked_json
    blocked_id=$("$WV" add "Blocked policy preflight node" 2>&1 | tail -1)
    "$WV" work "$blocked_id" >/dev/null 2>&1
    sqlite3 "$WV_DB" "INSERT OR IGNORE INTO node_files(node_id, path) VALUES ('$blocked_id', 'src/policy.py');"
    blocked_json=$("$WV" preflight "$blocked_id" 2>/dev/null)
    assert_equals "true" "$(echo "$blocked_json" | jq -r '.policy_readiness.policy_sensitive' 2>/dev/null || echo false)" \
        "wv preflight marks tracked-file nodes as policy-sensitive"
    assert_equals "true" "$(echo "$blocked_json" | jq -r '.policy_readiness.blocking' 2>/dev/null || echo false)" \
        "wv preflight blocks policy-sensitive completion when quality.db is missing"
    assert_equals "missing" "$(echo "$blocked_json" | jq -r '.policy_readiness.quality.status' 2>/dev/null || echo unknown)" \
        "wv preflight reports missing quality prerequisites"

    # --- Case 3: quality scan data clears the policy_readiness block ---
    sqlite3 "$WV_HOT_ZONE/quality.db" "CREATE TABLE scan_meta (id INTEGER PRIMARY KEY); INSERT INTO scan_meta(id) VALUES (1);" 2>/dev/null
    local ready_json
    ready_json=$("$WV" preflight "$blocked_id" 2>/dev/null)
    assert_equals "true" "$(echo "$ready_json" | jq -r '.policy_readiness.ready' 2>/dev/null || echo false)" \
        "wv preflight marks policy readiness ready once quality scan data exists"
    assert_equals "false" "$(echo "$ready_json" | jq -r '.policy_readiness.blocking' 2>/dev/null || echo true)" \
        "wv preflight clears the policy block once quality scan data exists"
}

test_p2_quality_refresh() {
    echo ""
    echo "Test: P2 — file_metrics refresh on wv done"
    echo "==========================================="

    setup_test_env
    "$WV" init >/dev/null 2>&1

    # --- Case 1: quality.db absent + node_files pre-seeded → loud failure ---
    local noq_id
    noq_id=$("$WV" add "Node needing quality check" 2>&1 | tail -1)
    "$WV" work "$noq_id" >/dev/null 2>&1

    # Seed node_files directly so P2 has paths to check but no quality.db exists.
    sqlite3 "$WV_DB" <<SQL
INSERT OR IGNORE INTO node_files(node_id, path) VALUES ('$noq_id', 'src/feature.py');
SQL

    local noq_out noq_rc
    noq_out=$("$WV" done "$noq_id" 2>&1 || true)
    noq_rc=$("$WV" show "$noq_id" --json 2>/dev/null | jq -r '.status' 2>/dev/null || echo "active")
    assert_contains "$noq_out" "quality.db not found" \
        "wv done fails loudly when quality.db is absent and node_files is non-empty"
    assert_equals "active" "$noq_rc" \
        "node stays active when quality.db is absent"

    # --- Case 2: quality.db with no scans → loud failure ---
    local noscan_id
    noscan_id=$("$WV" add "Node needing scan data" 2>&1 | tail -1)
    "$WV" work "$noscan_id" >/dev/null 2>&1

    sqlite3 "$WV_DB" <<SQL
INSERT OR IGNORE INTO node_files(node_id, path) VALUES ('$noscan_id', 'src/feature.py');
SQL

    # Create quality.db with schema but no scan rows.
    local quality_db="$WV_HOT_ZONE/quality.db"
    sqlite3 "$quality_db" "CREATE TABLE IF NOT EXISTS scan_meta (id INTEGER PRIMARY KEY, scanned_at TEXT, git_head TEXT, files_count INTEGER, duration_ms INTEGER, scanner_version TEXT);"
    sqlite3 "$quality_db" "CREATE TABLE IF NOT EXISTS files (path TEXT, scan_id INTEGER, complexity REAL, PRIMARY KEY(path, scan_id));"

    local noscan_out noscan_rc
    noscan_out=$("$WV" done "$noscan_id" 2>&1 || true)
    noscan_rc=$("$WV" show "$noscan_id" --json 2>/dev/null | jq -r '.status' 2>/dev/null || echo "active")
    assert_contains "$noscan_out" "no scan data" \
        "wv done fails loudly when quality.db exists but has no scans"
    assert_equals "active" "$noscan_rc" \
        "node stays active when quality.db has no scan data"

    # --- Case 3: quality.db present + mccabe within threshold → close succeeds and
    #             file_metrics in brain.db is populated from quality.db ---
    sqlite3 "$quality_db" "INSERT INTO scan_meta(id, scanned_at, git_head) VALUES(1, '2026-01-01T00:00:00', 'abc1234');"
    sqlite3 "$quality_db" "INSERT INTO files(path, scan_id, complexity) VALUES('src/feature.py', 1, 8.0);"

    local ok_id
    ok_id=$("$WV" add "Node with quality data" 2>&1 | tail -1)
    "$WV" work "$ok_id" >/dev/null 2>&1

    sqlite3 "$WV_DB" <<SQL
INSERT OR IGNORE INTO node_files(node_id, path) VALUES ('$ok_id', 'src/feature.py');
SQL

    local ok_out
    ok_out=$("$WV" done "$ok_id" 2>&1)
    assert_contains "$ok_out" "Closed" \
        "wv done succeeds when quality.db has scan data within threshold"

    local refreshed_max
    refreshed_max=$(sqlite3 "$WV_DB" "SELECT mccabe_max FROM file_metrics WHERE path='src/feature.py';")
    assert_equals "8" "$refreshed_max" \
        "file_metrics in brain.db populated from quality.db complexity"
}

test_trend_soft_warning() {
    echo ""
    echo "Test: P5c — soft warning on deteriorating complexity trend"
    echo "=========================================================="

    setup_test_env
    "$WV" init >/dev/null 2>&1

    local quality_db="$WV_HOT_ZONE/quality.db"
    sqlite3 "$quality_db" <<'SQL'
CREATE TABLE IF NOT EXISTS scan_meta (
    id INTEGER PRIMARY KEY,
    scanned_at TEXT,
    git_head TEXT,
    files_count INTEGER,
    duration_ms INTEGER,
    scanner_version TEXT
);
CREATE TABLE IF NOT EXISTS files (
    path TEXT,
    scan_id INTEGER,
    complexity REAL,
    PRIMARY KEY(path, scan_id)
);
CREATE TABLE IF NOT EXISTS complexity_trend (
    path TEXT NOT NULL,
    scan_id INTEGER NOT NULL,
    complexity REAL,
    essential REAL,
    PRIMARY KEY(path, scan_id)
);
INSERT INTO scan_meta(id, scanned_at, git_head) VALUES
    (1, '2026-01-01T00:00:00', 'abc1234'),
    (2, '2026-01-02T00:00:00', 'def5678');
INSERT INTO files(path, scan_id, complexity) VALUES
    ('src/deteriorating.py', 2, 12.0),
    ('src/stable.py', 2, 12.0),
    ('src/refactored.py', 2, 10.0);
INSERT INTO complexity_trend(path, scan_id, complexity, essential) VALUES
    ('src/deteriorating.py', 1, 10.0, 1.0),
    ('src/deteriorating.py', 2, 12.0, 2.0),
    ('src/stable.py', 1, 12.0, 1.0),
    ('src/stable.py', 2, 12.0, 1.0),
    ('src/refactored.py', 1, 14.0, 3.0),
    ('src/refactored.py', 2, 10.0, 1.0);
SQL

    local parent warning_learning
    parent=$("$WV" add "Trend parent" 2>&1 | tail -1)
    warning_learning="decision: run make check | pattern: make check covers trend warnings | pitfall: watch deteriorating files before close"

    local det_id det_out det_trend
    det_id=$("$WV" add "Deteriorating trend node" 2>&1 | tail -1)
    "$WV" link "$det_id" "$parent" --type=implements >/dev/null 2>&1
    "$WV" work "$det_id" >/dev/null 2>&1
    sqlite3 "$WV_DB" "INSERT OR IGNORE INTO node_files(node_id, path) VALUES ('$det_id', 'src/deteriorating.py');"
    det_out=$("$WV" done "$det_id" --learning="$warning_learning" 2>&1)
    assert_contains "$det_out" "Complexity trend deteriorating: src/deteriorating.py" \
        "wv done warns when a touched file trend is deteriorating"
    det_trend=$(sqlite3 "$WV_DB" "SELECT direction FROM file_trend WHERE path='src/deteriorating.py';" 2>/dev/null)
    assert_equals "deteriorating" "$det_trend" \
        "file_trend stores deteriorating direction for warned path"

    local stable_id stable_out stable_trend
    stable_id=$("$WV" add "Stable trend node" 2>&1 | tail -1)
    "$WV" link "$stable_id" "$parent" --type=implements >/dev/null 2>&1
    "$WV" work "$stable_id" >/dev/null 2>&1
    sqlite3 "$WV_DB" "INSERT OR IGNORE INTO node_files(node_id, path) VALUES ('$stable_id', 'src/stable.py');"
    stable_out=$("$WV" done "$stable_id" --learning="$warning_learning" 2>&1)
    assert_not_contains "$stable_out" "Complexity trend" \
        "wv done stays quiet for stable trend paths"
    stable_trend=$(sqlite3 "$WV_DB" "SELECT direction FROM file_trend WHERE path='src/stable.py';" 2>/dev/null)
    assert_equals "stable" "$stable_trend" \
        "file_trend stores stable direction without warning"

    local ref_id ref_out ref_trend
    ref_id=$("$WV" add "Refactored trend node" 2>&1 | tail -1)
    "$WV" link "$ref_id" "$parent" --type=implements >/dev/null 2>&1
    "$WV" work "$ref_id" >/dev/null 2>&1
    sqlite3 "$WV_DB" "INSERT OR IGNORE INTO node_files(node_id, path) VALUES ('$ref_id', 'src/refactored.py');"
    ref_out=$("$WV" done "$ref_id" --learning="$warning_learning" 2>&1)
    assert_not_contains "$ref_out" "Complexity trend" \
        "wv done stays quiet for refactored trend paths"
    ref_trend=$(sqlite3 "$WV_DB" "SELECT direction FROM file_trend WHERE path='src/refactored.py';" 2>/dev/null)
    assert_equals "refactored" "$ref_trend" \
        "file_trend stores refactored direction without warning"
}

test_allowed_tools() {
    echo ""
    echo "Test: wv allowed-tools command and work/done flag support"
    echo "=========================================================="

    setup_test_env
    "$WV" init >/dev/null 2>&1

    # --- Case 1: node with no allowed_tools ---
    local node_id
    node_id=$("$WV" add "Test allowed-tools node" 2>&1 | tail -1)

    local text_out json_out
    text_out=$("$WV" allowed-tools "$node_id" 2>&1)
    assert_contains "$text_out" "no allowed_tools" \
        "allowed-tools text output: reports no tools set"

    json_out=$("$WV" allowed-tools "$node_id" --json 2>&1)
    assert_equals "null" "$json_out" \
        "allowed-tools --json: null when unset"

    # --- Case 2: wv work --allowed-tools sets metadata ---
    "$WV" work "$node_id" --allowed-tools=read,grep,bash >/dev/null 2>&1

    local work_tools
    work_tools=$("$WV" allowed-tools "$node_id" --json 2>&1)
    assert_equals '["read","grep","bash"]' "$work_tools" \
        "wv work --allowed-tools persists tool list as JSON array"

    # --- Case 3: wv done --allowed-tools updates the list at close time ---
    WV_REQUIRE_QUALITY=0 "$WV" done "$node_id" --allowed-tools=read,write >/dev/null 2>&1

    local done_tools
    done_tools=$(sqlite3 "$WV_DB" "SELECT json_extract(metadata, '\$.allowed_tools') FROM nodes WHERE id='$node_id';")
    assert_equals '["read","write"]' "$done_tools" \
        "wv done --allowed-tools overwrites tool list at close time"

    # --- Case 4: allowed-tools on missing node exits non-zero ---
    local bad_out bad_rc
    bad_rc=0
    bad_out=$("$WV" allowed-tools "wv-000000" 2>&1) || bad_rc=$?
    assert_equals "1" "$bad_rc" \
        "allowed-tools on missing node exits 1"
    assert_contains "$bad_out" "not found" \
        "allowed-tools on missing node prints error"

    # --- Case 5: node with no --allowed-tools on wv work stays null ---
    local clean_id
    clean_id=$("$WV" add "Clean node no tools" 2>&1 | tail -1)
    "$WV" work "$clean_id" >/dev/null 2>&1
    local clean_tools
    clean_tools=$("$WV" allowed-tools "$clean_id" --json 2>&1)
    assert_equals "null" "$clean_tools" \
        "wv work without --allowed-tools leaves allowed_tools unset"
}

# ============================================================================
# Main
# ============================================================================
main() {
    echo "========================================"
    echo "Weave Core Command Tests"
    echo "========================================"

    test_init
    test_init_recovery
    test_leaked_env_overrides_are_ignored_across_repos
    test_add
    test_orphan_prevention
    test_done
    test_done_stores_commit_hashes
    test_findings_promote
    test_work
    test_list
    test_show
    test_ready
    test_status
    test_stale_active_marker
    test_policy_trigger
    test_trend_signal_wiring
    test_chunk_store_schema
    test_wv_index_command
    test_wv_search_code
    test_preflight_policy_readiness
    test_p2_quality_refresh
    test_trend_soft_warning
    test_allowed_tools
    test_ready_relevance_boost
    test_done_contradiction
    test_update_metadata_merge
    test_help_surfaces

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
