#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
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
export WV_AGENT_ID="test-core-agent"
# Isolate the durable suite-run log (LL2): wv test-record is always-on, so without
# this every test-record call here would pollute the real ~/.local/share log.
export WV_SUITE_LOG="$TEST_DIR/suite_runs.jsonl"

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

    if grep -qF -- "$needle" <<<"$haystack"; then
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

    if ! grep -qF -- "$needle" <<<"$haystack"; then
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

node_id_from_output() {
    sed -n 's/.*\(wv-[0-9a-f]\{6\}\).*/\1/p' | tail -1
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
    "$WV" add "Recovery test node" --force >/dev/null 2>&1
    "$WV" add "Another node" --force >/dev/null 2>&1
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
    "$WV" add "Source repo node" --force >/dev/null 2>&1
    assert_success "custom hot zone records owning repo" test -f "$source_repo/hot/.repo_root"

    cd "$target_repo"
    git init -q

    local target_hot target_db output source_target_count target_target_count
    target_hot=$(env -u WV_HOT_ZONE -u WV_DB -u WV_PROJECT_DIR WEAVE_DIR="$target_repo/.weave" \
        bash -c "source '$PROJECT_ROOT/scripts/lib/wv-resolve-runtime.sh'; resolve_repo_hot_zone \"\$(resolve_hot_zone)\" '$target_repo'" 2>/dev/null)
    target_db="$target_hot/brain.db"

    output=$("$WV" add "Target repo node" --force 2>&1)
    assert_contains "$output" "ignoring leaked WV_HOT_ZONE/WV_DB override" \
        "foreign repo warns when leaked WV overrides are ignored"

    local warn_count
    output=$(
        "$WV" status 2>&1
        "$WV" status 2>&1
    )
    warn_count=$(printf '%s' "$output" | grep -c "ignoring leaked WV_HOT_ZONE/WV_DB override" || true)
    assert_equals "1" "$warn_count" \
        "foreign repo warning is emitted once per shell session"

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
    # target_hot resolves to /dev/shm/weave/<hash> (outside temp dirs) — clean explicitly
    [ -n "${target_hot:-}" ] && rm -rf "$target_hot" 2>/dev/null || true
}

test_codex_runtime_uses_tmp_hot_zone() {
    echo ""
    echo "Test: Codex runtime uses persistent /tmp hot zone"
    echo "================================================"

    local repo hot expected_prefix
    repo=$(mktemp -d)
    cd "$repo"
    git init -q

    expected_prefix="/tmp/weave-codex-$(id -u)/"
    hot=$(env -u WV_HOT_ZONE -u WV_DB -u WV_PROJECT_DIR -u CODEX_THREAD_ID -u COPILOT_AGENT -u CLAUDE_CODE_SSE_PORT CODEX_CI=1 \
        bash -c "source '$PROJECT_ROOT/scripts/lib/wv-resolve-runtime.sh'; resolve_repo_hot_zone \"\$(resolve_hot_zone)\" '$repo'" 2>/dev/null)

    assert_contains "$hot" "$expected_prefix" \
        "Codex hot zone resolves under /tmp/weave-codex-\$uid"

    local hot_thread
    hot_thread=$(env -u WV_HOT_ZONE -u WV_DB -u WV_PROJECT_DIR -u CODEX_CI -u COPILOT_AGENT -u CLAUDE_CODE_SSE_PORT CODEX_THREAD_ID=thread-1 \
        bash -c "source '$PROJECT_ROOT/scripts/lib/wv-resolve-runtime.sh'; resolve_repo_hot_zone \"\$(resolve_hot_zone)\" '$repo'" 2>/dev/null)
    assert_contains "$hot_thread" "$expected_prefix" \
        "Codex hot zone resolves under /tmp/weave-codex-\$uid when CODEX_THREAD_ID is set"

    local hot_agent
    hot_agent=$(env -u WV_HOT_ZONE -u WV_DB -u WV_PROJECT_DIR -u CODEX_CI -u CODEX_THREAD_ID -u CLAUDE_CODE_SSE_PORT COPILOT_AGENT=1 \
        bash -c "source '$PROJECT_ROOT/scripts/lib/wv-resolve-runtime.sh'; resolve_repo_hot_zone \"\$(resolve_hot_zone)\" '$repo'" 2>/dev/null)
    assert_contains "$hot_agent" "$expected_prefix" \
        "Agent sandbox hot zone resolves under /tmp/weave-codex-\$uid when COPILOT_AGENT=1"

    local label
    label=$(env -u WV_HOT_ZONE -u WV_DB -u CODEX_THREAD_ID -u COPILOT_AGENT -u CLAUDE_CODE_SSE_PORT CODEX_CI=1 \
        bash -c "source '$PROJECT_ROOT/scripts/lib/wv-resolve-runtime.sh'; resolve_runtime_label" 2>/dev/null)
    assert_equals "codex" "$label" \
        "runtime label reports codex when CODEX_CI=1"

    local thread_label
    thread_label=$(env -u WV_HOT_ZONE -u WV_DB -u CODEX_CI -u COPILOT_AGENT -u CLAUDE_CODE_SSE_PORT CODEX_THREAD_ID=thread-1 \
        bash -c "source '$PROJECT_ROOT/scripts/lib/wv-resolve-runtime.sh'; resolve_runtime_label" 2>/dev/null)
    assert_equals "codex" "$thread_label" \
        "runtime label reports codex when CODEX_THREAD_ID is set"

    local agent_label
    agent_label=$(env -u WV_HOT_ZONE -u WV_DB -u CODEX_CI -u CODEX_THREAD_ID -u CLAUDE_CODE_SSE_PORT COPILOT_AGENT=1 \
        bash -c "source '$PROJECT_ROOT/scripts/lib/wv-resolve-runtime.sh'; resolve_runtime_label" 2>/dev/null)
    assert_equals "codex" "$agent_label" \
        "runtime label reports codex for agent sandbox sessions"

    rm -rf "$repo" "$hot" 2>/dev/null || true
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
    output=$("$WV" add "Test task one" --force 2>&1)
    assert_contains "$output" "wv-" "add outputs node ID"

    # Extract ID from output (last line)
    id=$(echo "$output" | node_id_from_output)
    assert_contains "$id" "wv-" "add returns bare ID on last line"

    # Direct add-to-active must carry the same planning metadata that wv work
    # would require on the claim path.
    assert_fails "add --status=active requires claim-ready metadata" "$WV" add "Active task" --status=active

    # Add with active status + claim-ready metadata
    output=$("$WV" add "Active task" --status=active --criteria="tests pass|docs updated" --risks=low --force 2>&1)
    id=$(echo "$output" | node_id_from_output)
    local show_output
    show_output=$("$WV" show "$id" 2>&1)
    assert_contains "$show_output" "active" "add --status sets correct status"

    # Add with metadata
    output=$("$WV" add "Task with metadata" --metadata='{"priority":1,"type":"bug"}' --force 2>&1)
    id=$(echo "$output" | node_id_from_output)
    show_output=$("$WV" show "$id" --json 2>&1)
    # Metadata is JSON-encoded in the output, so quotes are escaped
    assert_contains "$show_output" 'priority' "add --metadata stores JSON"
    assert_contains "$show_output" 'bug' "add --metadata stores all fields"

    # Add with --standalone persists durable standalone intent
    output=$("$WV" add "Standalone task" --standalone --force 2>&1)
    id=$(echo "$output" | node_id_from_output)
    show_output=$("$WV" show "$id" --json 2>&1)
    local standalone_meta
    standalone_meta=$(echo "$show_output" | jq -r '.metadata | fromjson | .standalone' 2>/dev/null)
    assert_equals "true" "$standalone_meta" "add --standalone stores standalone intent"

    # Add fails without text
    assert_fails "add requires text" "$WV" add

    # Add fails with invalid metadata JSON
    assert_fails "add rejects invalid JSON metadata" "$WV" add "Bad metadata" --metadata='not-json'

    # --risks=<level> must always seed both risk_level AND risks:[] so the
    # pre-claim hook's has("risks") check passes on immediate claim.
    local risk_id risk_meta
    for level in none low medium high critical; do
        risk_id=$("$WV" add "risks=$level" --risks="$level" --force 2>&1 | node_id_from_output)
        risk_meta=$("$WV" show "$risk_id" --json | jq -r '.metadata')
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
    id=$("$WV" add "Task to complete" --force 2>&1 | node_id_from_output)

    # Mark done
    local output
    output=$("$WV" done "$id" 2>&1)
    assert_contains "$output" "Closed" "done outputs completion message"

    # Verify status changed
    local show_output
    show_output=$("$WV" show "$id" 2>&1)
    assert_contains "$show_output" "done" "done sets status to done"

    # Done with learning
    id=$("$WV" add "Task with learning" --force 2>&1 | node_id_from_output)
    output=$("$WV" done "$id" --learning="pattern: always test your code" 2>&1)
    assert_contains "$output" "Closed" "done with learning succeeds"

    # Verify learning was captured in metadata
    local show_meta
    show_meta=$("$WV" show "$id" --json 2>&1)
    assert_contains "$show_meta" "always test your code" "done --learning stores in metadata"

    # Done with learning/evidence file inputs for agent-safe large text
    local learning_file evidence_file file_done_id file_done_output file_done_meta
    learning_file="$TEST_DIR/done-learning.txt"
    evidence_file="$TEST_DIR/done-evidence.txt"
    printf '%s\n' 'pattern: prefer file inputs for long agent learnings' > "$learning_file"
    printf '%s\n' '12 passed in agent-safe close flow' > "$evidence_file"

    file_done_id=$("$WV" add "Task with file inputs" --force 2>&1 | node_id_from_output)
    file_done_output=$("$WV" done "$file_done_id" --learning-file="$learning_file" --verification-method="make check" --verification-evidence-file="$evidence_file" 2>&1)
    assert_contains "$file_done_output" "Closed" "done accepts file-based learning/evidence inputs"

    file_done_meta=$("$WV" show "$file_done_id" --json 2>&1)
    assert_contains "$file_done_meta" "prefer file inputs for long agent learnings" "done --learning-file stores learning metadata"
    assert_contains "$file_done_meta" "12 passed in agent-safe close flow" "done --verification-evidence-file stores verification evidence"

    # Regression (audit A3-1): apostrophes in verification text must survive the
    # SQL round-trip — previously the metadata write failed silently and the
    # node still closed with no evidence stored.
    local apos_id apos_output apos_meta
    apos_id=$("$WV" add "Task with apostrophe evidence" --force 2>&1 | node_id_from_output)
    apos_output=$("$WV" done "$apos_id" --learning="pattern: escape user text in SQL" --verification-method="it's a manual check" --verification-evidence="user's apostrophe survives the round-trip" 2>&1)
    assert_contains "$apos_output" "Closed" "done with apostrophes in verification text succeeds"
    apos_meta=$("$WV" show "$apos_id" --json 2>&1)
    assert_contains "$apos_meta" "apostrophe survives the round-trip" "apostrophe verification evidence present after close"
    assert_contains "$apos_meta" "a manual check" "apostrophe verification method present after close"

    # Done on non-existent node fails
    assert_fails "done on non-existent node fails" "$WV" done "wv-0000"

    # Learning gate: wv done requires --learning or --skip-verification
    id=$("$WV" add "Task needing learning" --force 2>&1 | node_id_from_output)
    assert_fails "done rejects bare close when learning required" \
        env WV_REQUIRE_LEARNING=1 "$WV" done "$id"

    # Same node succeeds with --skip-verification
    local sv_exit=0
    WV_REQUIRE_LEARNING=1 "$WV" done "$id" --skip-verification >/dev/null 2>&1 || sv_exit=$?
    assert_equals "0" "$sv_exit" "done accepts --skip-verification"

    # Finding nodes: only violation_type (enum) required; rest optional
    local finding_id finding_output
    finding_id=$("$WV" add "Finding needing schema" --metadata='{"type":"finding"}' --force 2>&1 | sed -n 's/.*\(wv-[0-9a-f]\{6\}\).*/\1/p' | node_id_from_output)
    assert_fails "done rejects finding with no violation_type" \
        env WV_REQUIRE_LEARNING=1 "$WV" done "$finding_id" --skip-verification

    # Write-time enum guard (wv-dc9f3e): off-enum violation_type rejected at UPDATE,
    # not only at close — closes the gap that let invalid findings persist (wv-43f077).
    assert_fails "update rejects off-enum finding violation_type (write-time guard)" \
        "$WV" update "$finding_id" --metadata='{"finding":{"violation_type":"R10:open_node_at_end"}}'

    # Invalid value never got written, so the node still lacks a violation_type and done fails.
    assert_fails "done rejects finding with no valid violation_type" \
        env WV_REQUIRE_LEARNING=1 "$WV" done "$finding_id" --skip-verification

    # Minimal shape (violation_type only) accepted
    "$WV" update "$finding_id" --metadata='{"type":"finding","finding":{"violation_type":"repo:hygiene"}}' >/dev/null 2>&1
    finding_output=$(WV_REQUIRE_LEARNING=1 "$WV" done "$finding_id" --skip-verification 2>&1)
    assert_contains "$finding_output" "Closed" "done accepts finding with only violation_type (minimal shape)"

    # Full shape still accepted
    local finding_full_id finding_full_output
    finding_full_id=$("$WV" add "Finding full schema" --metadata='{"type":"finding","finding":{"violation_type":"test:gap","root_cause":"missing coverage","proposed_fix":"add test","confidence":"high","fixable":true}}' --force 2>&1 | sed -n 's/.*\(wv-[0-9a-f]\{6\}\).*/\1/p' | node_id_from_output)
    finding_full_output=$(WV_REQUIRE_LEARNING=1 "$WV" done "$finding_full_id" --skip-verification 2>&1)
    assert_contains "$finding_full_output" "Closed" "done accepts finding with full 5-field schema (backward compat)"

    # Optional fields present but invalid are still rejected
    local finding_bad_id
    finding_bad_id=$("$WV" add "Finding bad optional" --metadata='{"type":"finding","finding":{"violation_type":"repo:regression","confidence":0.92,"fixable":"yes"}}' --force 2>&1 | sed -n 's/.*\(wv-[0-9a-f]\{6\}\).*/\1/p' | node_id_from_output)
    assert_fails "done rejects finding with invalid optional field types" \
        env WV_REQUIRE_LEARNING=1 "$WV" done "$finding_bad_id" --skip-verification

    # Non-interactive overlap: close proceeds and skips overlap advisory writes entirely
    local seed_id overlap_id overlap_learning overlap_exit overlap_output overlap_meta
    overlap_learning="decision: keep overlap prompts resumable | pattern: store pending close state | pitfall: tty prompts hang unattended flows"
    seed_id=$("$WV" add "Seed overlap learning" --force 2>&1 | node_id_from_output)
    WV_REQUIRE_LEARNING=1 "$WV" done "$seed_id" --learning="$overlap_learning" >/dev/null 2>&1

    overlap_id=$("$WV" add "Overlap advisory" --force 2>&1 | node_id_from_output)
    overlap_exit=0
    overlap_output=$(WV_REQUIRE_LEARNING=1 WV_NONINTERACTIVE=1 "$WV" done "$overlap_id" --learning="$overlap_learning" 2>&1) || overlap_exit=$?
    assert_equals "0" "$overlap_exit" "done succeeds non-interactively when overlap detected"
    assert_not_contains "$overlap_output" "Overlap noted in metadata" "done skips overlap advisory output in non-interactive mode"

    overlap_meta=$("$WV" show "$overlap_id" --json 2>&1)
    assert_not_contains "$overlap_meta" "learning_overlap_noted" "done skips learning_overlap_noted metadata in non-interactive mode"
    assert_contains "$overlap_meta" '"status":"done"' "node is closed despite overlap"

    local finding_overlap_id finding_overlap_exit finding_overlap_output finding_overlap_meta
    finding_overlap_id=$("$WV" add "Finding overlap advisory" --metadata='{"type":"finding","verification":{"method":"test","result":"pass"},"finding":{"violation_type":"design:flaw","root_cause":"runtime wv_done wrapper validates finding metadata types and presence before allowing close","proposed_fix":"agents must set confidence as one of high|medium|low (string) and fixable as boolean before closing a finding node","confidence":"high","fixable":true}}' --force 2>&1 | sed -n 's/.*\(wv-[0-9a-f]\{6\}\).*/\1/p' | node_id_from_output)
    finding_overlap_exit=0
    finding_overlap_output=$(WV_REQUIRE_LEARNING=1 WV_NONINTERACTIVE=1 "$WV" done "$finding_overlap_id" --learning="$overlap_learning" 2>&1) || finding_overlap_exit=$?
    assert_equals "0" "$finding_overlap_exit" "done succeeds for finding nodes when overlap is advisory"
    assert_contains "$finding_overlap_output" "Closed" "finding overlap advisory still closes the node"
    finding_overlap_meta=$("$WV" show "$finding_overlap_id" --json 2>&1)
    assert_contains "$finding_overlap_meta" '"status":"done"' "finding node is closed despite overlap"
    assert_not_contains "$finding_overlap_meta" "learning_overlap_noted" "finding close also skips overlap advisory metadata in non-interactive mode"

    # source_node advisory: closing a node with open findings emits advisory
    local src_adv_id src_adv_finding src_adv_output
    src_adv_id=$("$WV" add "Source node with finding" --force 2>&1 | sed -n 's/.*\(wv-[0-9a-f]\{6\}\).*/\1/p' | node_id_from_output)
    "$WV" work "$src_adv_id" >/dev/null 2>&1
    src_adv_finding=$("$WV" add "Finding refs source" --standalone --force \
        --metadata="{\"type\":\"finding\",\"source_node\":\"$src_adv_id\",\"finding\":{\"violation_type\":\"repo:hygiene\"}}" \
        2>&1 | sed -n 's/.*\(wv-[0-9a-f]\{6\}\).*/\1/p' | node_id_from_output)
    src_adv_output=$(WV_REQUIRE_LEARNING=1 "$WV" done "$src_adv_id" --skip-verification 2>&1)
    assert_contains "$src_adv_output" "Open findings referencing this node" "done: advisory fires when open findings reference source_node"
    assert_contains "$src_adv_output" "$src_adv_finding" "done: advisory names the finding ID"
    assert_contains "$src_adv_output" "Closed" "done: still closes despite advisory"

    # No advisory when findings already closed
    local src_clean_id src_clean_finding src_clean_output
    src_clean_id=$("$WV" add "Source node no open findings" --standalone --force 2>&1 | sed -n 's/.*\(wv-[0-9a-f]\{6\}\).*/\1/p' | node_id_from_output)
    "$WV" work "$src_clean_id" >/dev/null 2>&1
    src_clean_finding=$("$WV" add "Closed finding refs source" --standalone --force \
        --metadata="{\"type\":\"finding\",\"source_node\":\"$src_clean_id\",\"finding\":{\"violation_type\":\"repo:hygiene\"}}" \
        2>&1 | sed -n 's/.*\(wv-[0-9a-f]\{6\}\).*/\1/p' | node_id_from_output)
    "$WV" work "$src_clean_finding" >/dev/null 2>&1
    WV_REQUIRE_LEARNING=1 "$WV" done "$src_clean_finding" --skip-verification >/dev/null 2>&1
    src_clean_output=$(WV_REQUIRE_LEARNING=1 "$WV" done "$src_clean_id" --skip-verification 2>&1)
    assert_not_contains "$src_clean_output" "Open findings" "done: no advisory when all referencing findings are closed"

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
    git config commit.gpgsign false
    git init --bare -q "$ship_remote"
    git remote add origin "$ship_remote"
    git add . >/dev/null 2>&1 || true
    git commit -m "test baseline" --allow-empty >/dev/null 2>&1 || true
    git push -u origin HEAD >/dev/null 2>&1

    ship_id=$("$WV" add "Ship overlap parity" --force 2>&1 | node_id_from_output)
    ship_exit=0
    ship_output=$(WV_REQUIRE_LEARNING=1 WV_NONINTERACTIVE=1 "$WV" ship "$ship_id" --learning="$overlap_learning" --no-overlap-check 2>&1) || ship_exit=$?
    assert_equals "0" "$ship_exit" "ship accepts --no-overlap-check"
    ship_meta=$("$WV" show "$ship_id" --json 2>&1)
    assert_contains "$ship_meta" '"status":"done"' "ship still closes the node with --no-overlap-check"
    assert_not_contains "$ship_meta" "learning_overlap_noted" "ship forwards no-overlap-check to done"

    ship_status=$("$WV" status --json 2>&1)
    assert_contains "$ship_status" '"git_sync_pending": true' "ship leaves pending remote sync surfaced in status"
    assert_contains "$ship_status" '"git_sync_reason": "dirty_weave"' "ship status reports dirty_weave after local-only completion"

    local ship_agent_id ship_agent_learning ship_agent_evidence ship_agent_exit ship_agent_output ship_agent_status ship_agent_doctor
    ship_agent_learning="$ship_repo/ship-agent-learning.txt"
    ship_agent_evidence="$ship_repo/ship-agent-evidence.txt"
    printf '%s\n' 'decision: keep ship-agent non-interactive | pattern: reuse cmd_ship internals | pitfall: wrappers drift when verification flags diverge' > "$ship_agent_learning"
    printf '%s\n' 'agent close verification passed' > "$ship_agent_evidence"

    ship_agent_id=$("$WV" add "Ship agent complete" --force 2>&1 | node_id_from_output)
    ship_agent_exit=0
    ship_agent_output=$("$WV" ship-agent "$ship_agent_id" --learning-file="$ship_agent_learning" --verification-method="make check" --verification-evidence-file="$ship_agent_evidence" --no-overlap-check --json 2>&1) || ship_agent_exit=$?
    assert_equals "0" "$ship_agent_exit" "ship-agent succeeds with file-backed learning and verification inputs"
    ship_agent_status=$(echo "$ship_agent_output" | jq -r '.status // empty')
    assert_equals "shipped" "$ship_agent_status" "ship-agent returns shipped status"
    ship_agent_doctor=$(echo "$ship_agent_output" | jq -r '.doctor.overall // empty')
    assert_equals "pass" "$ship_agent_doctor" "ship-agent includes passing doctor --agent result"
    assert_contains "$ship_agent_output" '"noninteractive": true' "ship-agent reports noninteractive mode in JSON"

    local ship_agent_meta
    ship_agent_meta=$("$WV" show "$ship_agent_id" --json 2>&1)
    assert_contains "$ship_agent_meta" '"status":"done"' "ship-agent closes the node"

    git remote remove origin >/dev/null 2>&1 || true
    local ship_local_id ship_local_exit ship_local_meta ship_local_status
    ship_local_id=$("$WV" add "Ship local complete" --force 2>&1 | node_id_from_output)
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
    legacy_id=$("$WV" add "Legacy stuck node" --force 2>&1 | node_id_from_output)
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
    git config commit.gpgsign false

    local id output node_json stored_commit stored_first head_sha
    id=$("$WV" add "Commit-linked close" --force 2>&1 | node_id_from_output)
    "$WV" work "$id" >/dev/null 2>&1

    echo "tracked" > commit-linked.txt
    git add commit-linked.txt
    git commit -m "feat: commit-linked close" -m "Weave-ID: $id" -q

    output=$(WV_REQUIRE_LEARNING=1 "$WV" done "$id" --learning="decision: commit before done | pattern: use Weave-ID trailers for commit attribution | pitfall: unattributed commits never reach node metadata" 2>&1)
    assert_contains "$output" "Closed" "done succeeds when the work commit is attributed"

    head_sha=$(git rev-parse HEAD)
    node_json=$("$WV" show "$id" --json 2>&1)
    stored_commit=$(echo "$node_json" | jq -r '.metadata | fromjson | .commit // empty' 2>/dev/null || echo "")
    stored_first=$(echo "$node_json" | jq -r '.metadata | fromjson | .commits[0] // empty' 2>/dev/null || echo "")
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
    git config commit.gpgsign false

    local id output node_json stored_commit stored_first stored_second impl_sha checkpoint_sha
    id=$("$WV" add "Commit precedence close" --force 2>&1 | node_id_from_output)
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
    stored_commit=$(echo "$node_json" | jq -r '.metadata | fromjson | .commit // empty' 2>/dev/null || echo "")
    stored_first=$(echo "$node_json" | jq -r '.metadata | fromjson | .commits[0] // empty' 2>/dev/null || echo "")
    stored_second=$(echo "$node_json" | jq -r '.metadata | fromjson | .commits[1] // empty' 2>/dev/null || echo "")
    assert_equals "$impl_sha" "$stored_commit" "done keeps the implementation commit as primary metadata"
    assert_equals "$impl_sha" "$stored_first" "done orders implementation commit first in commits metadata"
    assert_equals "$checkpoint_sha" "$stored_second" "done retains checkpoint commit as secondary attribution"
}

# ============================================================================
# Test: auto_checkpoint skips noise commit when HEAD == origin
# ============================================================================
test_auto_checkpoint_skip_at_origin() {
    echo ""
    echo "Test: auto_checkpoint skips commit when HEAD is already at origin"
    echo "=================================================================="

    local cp_repo cp_hot cp_remote
    cp_repo=$(mktemp -d "$TEST_DIR/cp-repo.XXXXXX")
    cp_hot=$(mktemp -d "$TEST_DIR/cp-hot.XXXXXX")
    cp_remote=$(mktemp -d "$TEST_DIR/cp-remote.XXXXXX")

    cd "$cp_repo"
    git init -q
    git config user.email "test@example.com"
    git config user.name "Weave Test"
    git config commit.gpgsign false

    export WV_HOT_ZONE="$cp_hot"
    export WV_DB="$cp_hot/brain.db"
    export WV_PROJECT_DIR="$cp_repo"
    "$WV" init >/dev/null 2>&1

    # Push initial state so HEAD == origin
    git init --bare -q "$cp_remote"
    git remote add origin "$cp_remote"
    git add . >/dev/null 2>&1 || true
    git commit -m "test baseline" --allow-empty >/dev/null 2>&1 || true
    git push -u origin HEAD -q >/dev/null 2>&1

    local before_sha
    before_sha=$(git rev-parse HEAD)

    # Trigger auto_checkpoint with zero throttle and pull disabled.
    # WV_CHECKPOINT_PULL=0 prevents network ops against the bare remote.
    # WV_CHECKPOINT_INTERVAL=0 bypasses the 10-minute checkpoint throttle.
    # WV_SYNC_INTERVAL=0 bypasses the sync throttle so auto_sync actually runs.
    local probe_id probe_out
    probe_out=$(WV_SYNC_INTERVAL=0 WV_CHECKPOINT_INTERVAL=0 WV_CHECKPOINT_PULL=0 \
        "$WV" add "cp-race probe" --force 2>&1)
    probe_id=$(echo "$probe_out" | node_id_from_output)

    local after_sha
    after_sha=$(git rev-parse HEAD)

    assert_equals "$before_sha" "$after_sha" \
        "auto_checkpoint skips commit when HEAD is already at origin (no noise before next real commit)"

    # Confirm the node was persisted to the DB — the add itself must complete even
    # when the checkpoint commit is suppressed.
    local probe_show
    probe_show=$("$WV" show "$probe_id" 2>&1)
    assert_contains "$probe_show" "cp-race probe" \
        "node added during suppressed checkpoint is accessible in DB"

    # Cleanup
    export WV_HOT_ZONE="$TEST_DIR"
    export WV_DB="$TEST_DIR/brain.db"
    export WV_PROJECT_DIR="$TEST_DIR"
    cd "$TEST_DIR"
    rm -rf "$cp_repo" "$cp_hot" "$cp_remote"
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
    id=$("$WV" add "Task to work on" --force 2>&1 | node_id_from_output)

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
    finding_id=$("$WV" add "Investigate open-node false positive" --metadata='{"type":"finding","finding":{"violation_type":"R10:open_node_at_end","root_cause":"bootstrap omitted active-node type","proposed_fix":"record active_node_type in session_start metadata","confidence":"high","fixable":true}}' --force 2>&1 | node_id_from_output)
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
    id1=$("$WV" add "Todo task" --status=todo --force 2>&1 | node_id_from_output)
    id2=$("$WV" add "Active task" --status=active --criteria="tests pass" --risks=low --force 2>&1 | node_id_from_output)
    id3=$("$WV" add "Done task" --status=done --force 2>&1 | node_id_from_output)

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
    output=$("$WV" list --json 2>/dev/null)
    assert_contains "$output" "[" "list --json outputs JSON array"
    assert_contains "$output" '"id"' "list --json includes id field"

    # Default list cap applies to JSON too, but must not be silent.
    for i in $(seq 1 55); do
        "$WV" add "Cap test $i" --status=todo --force >/dev/null 2>&1
    done
    local json_out json_err json_count
    json_out=$("$WV" list --json 2>"$TEST_DIR/list-json.err")
    json_err=$(cat "$TEST_DIR/list-json.err")
    json_count=$(echo "$json_out" | jq 'length' 2>/dev/null || echo 0)
    assert_equals "50" "$json_count" "list --json default cap returns 50 rows"
    assert_contains "$json_err" "use --all for full dump" "list --json capped output warns on stderr"
    json_count=$("$WV" list --json --all 2>/dev/null | jq 'length' 2>/dev/null || echo 0)
    assert_success "list --json --all returns more than capped default" test "$json_count" -gt 50

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
    id=$("$WV" add "Show test node" --metadata='{"priority":2,"type":"feature"}' --force 2>&1 | node_id_from_output)

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
    intent_id=$("$WV" add "Intent test node" --force 2>&1 | node_id_from_output)
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
    id1=$("$WV" add "Ready task 1" --force 2>&1 | node_id_from_output)
    id2=$("$WV" add "Ready task 2" --force 2>&1 | node_id_from_output)

    # Create a blocked node
    id3=$("$WV" add "Blocked task" --force 2>&1 | node_id_from_output)
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
    "$WV" add "Task 1" --status=todo --force >/dev/null 2>&1
    "$WV" add "Task 2" --status=active --criteria="status shows active work" --risks=low --force >/dev/null 2>&1
    local id3
    id3=$("$WV" add "Task 3" --force 2>&1 | node_id_from_output)
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

test_bootstrap_agent() {
    echo ""
    echo "Test: wv bootstrap-agent"
    echo "========================"

    setup_test_env
    "$WV" init >/dev/null 2>&1

    local active_id bootstrap_json minimal_json agent_wv agent_db readiness_state provenance
    active_id=$("$WV" add "Bootstrap agent task" --force 2>&1 | node_id_from_output)
    "$WV" work "$active_id" >/dev/null 2>&1

    bootstrap_json=$("$WV" bootstrap-agent --json 2>&1)
    assert_contains "$bootstrap_json" '"agent"' "bootstrap-agent returns agent block"
    assert_contains "$bootstrap_json" '"python_command":' "bootstrap-agent reports python command"

    agent_wv=$(echo "$bootstrap_json" | jq -r '.agent.wv_command // empty')
    assert_equals "$PROJECT_ROOT/scripts/wv" "$agent_wv" "bootstrap-agent prefers repo-local wv wrapper"

    agent_db=$(echo "$bootstrap_json" | jq -r '.agent.db_path // empty')
    assert_equals "$WV_DB" "$agent_db" "bootstrap-agent reports active db path"

    readiness_state=$(echo "$bootstrap_json" | jq -r '.agent.readiness.state // empty')
    assert_equals "ready" "$readiness_state" "bootstrap-agent reports ready state when command/db/python resolve"

    provenance=$(echo "$bootstrap_json" | jq -r '.agent.wv_provenance // empty')
    assert_equals "repo-local" "$provenance" "bootstrap-agent reports repo-local provenance when using scripts/wv"

    assert_equals "true" "$(echo "$bootstrap_json" | jq -r --arg wv "$PROJECT_ROOT/scripts/wv" '.agent.tools.warmup | index($wv + " index . --json") != null' 2>/dev/null || echo false)" \
        "bootstrap-agent exposes copy-pasteable index warm-up using resolved wv"
    assert_equals "true" "$(echo "$bootstrap_json" | jq -r --arg wv "$PROJECT_ROOT/scripts/wv" '.agent.tools.warmup | index($wv + " quality scan . --json") != null' 2>/dev/null || echo false)" \
        "bootstrap-agent exposes copy-pasteable quality warm-up using resolved wv"
    assert_equals "true" "$(echo "$bootstrap_json" | jq -r --arg wv "$PROJECT_ROOT/scripts/wv" '.agent.tools.code_search.command == ($wv + " search --code \"<query>\" --json")' 2>/dev/null || echo false)" \
        "bootstrap-agent documents code search entry point"
    assert_equals "true" "$(echo "$bootstrap_json" | jq -r '.agent.tools.ast_grep | has("ready")' 2>/dev/null || echo false)" \
        "bootstrap-agent reports ast-grep readiness without requiring availability"
    assert_equals "lite" "$(echo "$bootstrap_json" | jq -r '.agent.codex.mcp.recommended_scope // empty' 2>/dev/null || echo failed)" \
        "bootstrap-agent recommends lite MCP scope for Codex"
    assert_equals "$PROJECT_ROOT/scripts/wv work <id>" "$(echo "$bootstrap_json" | jq -r '.agent.codex.commands.claim // empty' 2>/dev/null || echo failed)" \
        "bootstrap-agent exposes Codex-safe claim command"
    assert_contains "$(echo "$bootstrap_json" | jq -r '.agent.codex.telemetry.call_log // empty' 2>/dev/null || echo '')" "wv_calls.jsonl" \
        "bootstrap-agent exposes telemetry call log path"
    assert_contains "$(echo "$bootstrap_json" | jq -r '.agent.codex.telemetry.enable_for_command // empty' 2>/dev/null || echo '')" "session-analysis" \
        "bootstrap-agent gives Codex telemetry enable command"
    assert_contains "$(echo "$bootstrap_json" | jq -r '.agent.codex.telemetry.analyze // empty' 2>/dev/null || echo '')" "analyze sessions --call-stats" \
        "bootstrap-agent gives Codex telemetry analyze command"
    assert_contains "$(echo "$bootstrap_json" | jq -r '.agent.codex.network_policy.github_sync // empty' 2>/dev/null || echo '')" "CLI only" \
        "bootstrap-agent marks GitHub sync as CLI-only for Codex"

    minimal_json=$(PATH="/usr/local/bin:/usr/bin:/bin" "$WV" bootstrap-agent --json 2>&1)
    assert_equals "ready" "$(echo "$minimal_json" | jq -r '.agent.readiness.state // empty' 2>/dev/null || echo failed)" \
        "bootstrap-agent resolves tools under Codex-style minimal PATH"
    assert_equals "$PROJECT_ROOT/scripts/wv index . --json" "$(echo "$minimal_json" | jq -r '.agent.tools.index.command // empty' 2>/dev/null || echo failed)" \
        "bootstrap-agent emits executable warm-up command under Codex-style minimal PATH"

    local fake_bin doctor_json codex_mcp_detail
    fake_bin="$TEST_DIR/fake-bin"
    mkdir -p "$fake_bin"
    cat > "$fake_bin/codex" <<'CODEXFAKE'
#!/usr/bin/env bash
if [ "$1" = "mcp" ] && [ "$2" = "list" ]; then
    printf '%s\n' 'Name        Command  Args'
    printf '%s\n' 'weave-lite  node     /tmp/weave/mcp/dist/index.js --scope=lite'
    printf '%s\n' 'weave       node     /tmp/weave/mcp/dist/index.js'
fi
CODEXFAKE
    chmod +x "$fake_bin/codex"
    doctor_json=$(PATH="$fake_bin:$PATH" "$WV" doctor --agent --json 2>&1)
    codex_mcp_detail=$(echo "$doctor_json" | jq -r '.checks[] | select(.check=="codex mcp") | .detail // empty' 2>/dev/null || echo "")
    assert_contains "$codex_mcp_detail" "stale full weave MCP" \
        "doctor --agent warns when stale full Codex MCP remains alongside lite"

    cat > "$fake_bin/codex" <<'CODEXFAKE'
#!/usr/bin/env bash
if [ "$1" = "mcp" ] && [ "$2" = "list" ]; then
    printf '%s\n' 'Name        Command  Args'
    printf '%s\n' 'weave-lite  node     /tmp/weave/mcp/dist/index.js --scope=lite'
fi
CODEXFAKE
    chmod +x "$fake_bin/codex"
    doctor_json=$(PATH="$fake_bin:$PATH" "$WV" doctor --agent --json 2>&1)
    codex_mcp_detail=$(echo "$doctor_json" | jq -r '.checks[] | select(.check=="codex mcp") | .detail // empty' 2>/dev/null || echo "")
    assert_contains "$codex_mcp_detail" "weave-lite registered" \
        "doctor --agent reports recommended Codex MCP scope"

    local codex_hooks_detail
    rm -rf .codex
    doctor_json=$("$WV" doctor --agent --json 2>&1)
    codex_hooks_detail=$(echo "$doctor_json" | jq -r '.checks[] | select(.check=="codex hooks") | .detail // empty' 2>/dev/null || echo "")
    assert_contains "$codex_hooks_detail" "no project Codex hooks" \
        "doctor --agent warns when Codex hooks are absent"

    mkdir -p .codex
    printf '%s\n' '{"hooks":{"SessionStart":[{}],"PreToolUse":[{}]}}' > .codex/hooks.json
    doctor_json=$("$WV" doctor --agent --json 2>&1)
    codex_hooks_detail=$(echo "$doctor_json" | jq -r '.checks[] | select(.check=="codex hooks") | .detail // empty' 2>/dev/null || echo "")
    assert_contains "$codex_hooks_detail" "stale, missing event(s)" \
        "doctor --agent warns when Codex hooks config is missing events"
    assert_contains "$codex_hooks_detail" "PostToolUse" \
        "doctor --agent names the missing Codex hook events"

    printf '%s\n' '{"hooks":{"SessionStart":[{}],"PreToolUse":[{}],"PostToolUse":[{}],"Stop":[{}]}}' > .codex/hooks.json
    doctor_json=$("$WV" doctor --agent --json 2>&1)
    codex_hooks_detail=$(echo "$doctor_json" | jq -r '.checks[] | select(.check=="codex hooks") | .detail // empty' 2>/dev/null || echo "")
    assert_contains "$codex_hooks_detail" "pending trust" \
        "doctor --agent reports pending-trust for a complete Codex hooks config"
    rm -rf .codex
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
    fresh_id=$("$WV" add "fresh active task" --status=active --criteria="fresh node visible in status" --risks=low --force 2>&1 | node_id_from_output)
    stale_id=$("$WV" add "stale active task" --status=active --criteria="stale node visible in status" --risks=low --force 2>&1 | node_id_from_output)

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
    node_a=$("$WV" add "Task A no overlap" --force 2>&1 | node_id_from_output)
    sleep 1
    node_b=$("$WV" add "Task B with overlap" --force 2>&1 | node_id_from_output)
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
    seed_id=$("$WV" add "Seed Poetry decision" --force 2>&1 | node_id_from_output)
    WV_REQUIRE_LEARNING=1 "$WV" done "$seed_id" \
        --learning="decision Poetry Python projects always prefer use it" \
        >/dev/null 2>&1

    # Same-polarity follow-up (positive vs positive) should NOT trigger contradiction.
    local same_id same_meta
    same_id=$("$WV" add "Same direction Poetry note" --force 2>&1 | node_id_from_output)
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
    opp_id=$("$WV" add "Opposite Poetry pitfall" --force 2>&1 | node_id_from_output)
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
    skip_id=$("$WV" add "Skip overlap check" --force 2>&1 | node_id_from_output)
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
    id1=$("$WV" add "no initial meta" --force 2>&1 | node_id_from_output)
    "$WV" update "$id1" --metadata='{"k":"v"}' >/dev/null 2>&1
    meta=$("$WV" show "$id1" --json | jq -r '.metadata')
    assert_contains "$meta" '"k":"v"' "merge: empty → new key stored"

    # Case B — existing key preserved, new key added.
    id2=$("$WV" add "existing meta" --criteria="c1" --force 2>&1 | node_id_from_output)
    "$WV" update "$id2" --metadata='{"extra":"z"}' >/dev/null 2>&1
    meta=$("$WV" show "$id2" --json | jq -r '.metadata')
    assert_contains "$meta" 'done_criteria' "merge: existing key preserved"
    assert_contains "$meta" '"extra":"z"' "merge: new key added"

    # Case C — payload with unicode, apostrophe, and literal '||' does not trip
    # a silent fallback (the old code's jq || echo fallback would have nuked
    # done_criteria on any jq failure).
    id3=$("$WV" add "stress payload" --criteria="c1" --force 2>&1 | node_id_from_output)
    "$WV" update "$id3" --metadata='{"note":"O'\''Donovan → test || foo"}' >/dev/null 2>&1
    meta=$("$WV" show "$id3" --json | jq -r '.metadata')
    assert_contains "$meta" 'done_criteria' "merge: stress payload preserves existing key"
    assert_contains "$meta" "O'Donovan" "merge: apostrophe round-trips"
    assert_contains "$meta" '||' "merge: literal || survives"

    # Case D — invalid JSON is rejected loudly; stored metadata is unchanged.
    local id4 before after
    id4=$("$WV" add "invalid json rejected" --criteria="c1" --force 2>&1 | node_id_from_output)
    before=$("$WV" show "$id4" --json | jq -r '.metadata')
    if "$WV" update "$id4" --metadata='{"bad": syntax}' >/dev/null 2>&1; then
        echo -e "${RED}✗${NC} invalid JSON should have been rejected"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        TESTS_RUN=$((TESTS_RUN + 1))
    else
        echo -e "${GREEN}✓${NC} invalid JSON rejected with non-zero exit"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        TESTS_RUN=$((TESTS_RUN + 1))
    fi
    after=$("$WV" show "$id4" --json | jq -r '.metadata')
    assert_equals "$before" "$after" "rejected update leaves metadata untouched"

    # Case E — immediate update-then-claim sequence (the primary Target 1
    # friction). After setting done_criteria via --metadata, wv work must pass
    # the pre-claim readiness check on the very next invocation.
    local id5
    id5=$("$WV" add "claim readiness" --force 2>&1 | node_id_from_output)
    "$WV" update "$id5" --metadata='{"done_criteria":"c","risks":[],"risk_level":"low"}' >/dev/null 2>&1
    meta=$("$WV" show "$id5" --json | jq -r '.metadata')
    assert_contains "$meta" '"done_criteria":"c"' "update-then-claim: done_criteria visible immediately"

    # Case F — split-form metadata is accepted instead of falling through to
    # "no updates specified".
    local id6
    id6=$("$WV" add "split-form metadata" --force 2>&1 | node_id_from_output)
    "$WV" update "$id6" --metadata '{"split":true}' >/dev/null 2>&1
    meta=$("$WV" show "$id6" --json | jq -r '.metadata')
    assert_contains "$meta" '"split":true' "split-form --metadata merges JSON"

    # Case G — file-backed metadata avoids shell-quoting hazards for larger JSON.
    local id7 meta_file
    id7=$("$WV" add "file metadata" --force 2>&1 | node_id_from_output)
    meta_file=$(mktemp)
    printf '%s\n' '{"from_file":{"path":"ok","count":2}}' > "$meta_file"
    "$WV" update "$id7" --metadata-file "$meta_file" >/dev/null 2>&1
    rm -f "$meta_file"
    meta=$("$WV" show "$id7" --json | jq -r '.metadata')
    assert_contains "$meta" '"from_file"' "--metadata-file merges JSON from file"
    assert_contains "$meta" '"count":2' "--metadata-file preserves nested values"

    # Case H — missing split-form value should produce an actionable diagnostic.
    local id8 missing_value_output
    id8=$("$WV" add "missing metadata value" --force 2>&1 | node_id_from_output)
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
        init add remember memory delete done ship ship-agent batch-done bulk-update work preflight recover bootstrap bootstrap-agent
        overview cache pending-close ready list show status update touch allowed-tools quick
        hook
        block link unlink resolve related edges path tree plan enrich-topology context discover search
        reindex learnings trails digest session-summary audit-pitfalls edge-types init-repo
        doctor selftest mcp-status health guide prune clean-ghosts compact refs import quality
        findings analyze batch sync load
        impact hotzone pattern-audit validate-finding test-record
    )

    local cmd
    for cmd in "${expected_commands[@]}"; do
        assert_contains "$root_help" "$cmd" "root help lists $cmd"
    done
    assert_contains "$root_help" "wv help <command>" "root help documents focused help entrypoint"
    assert_contains "$root_help" "wv <command> --help" "root help documents per-command help flag"
    assert_contains "$root_help" "Recall/render/scan/import graph memory" "root help summarizes all memory subcommands"

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

test_discover_cache_classification() {
    echo ""
    echo "Test: discover cache classification"
    echo "==================================="

    local classification
    classification=$(bash -c "
        source '$PROJECT_ROOT/scripts/lib/wv-cache.sh'
        if _wv_run_cache_is_exempt_cmd discover; then
            printf exempt
        elif _wv_run_cache_is_read_cmd discover; then
            printf read
        elif _wv_run_cache_is_write_cmd discover; then
            printf write
        else
            printf unclassified
        fi
    ")
    assert_equals "exempt" "$classification" "discover is classified as an exempt read"
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
    epic_id=$("$WV" add "Root epic" --metadata='{"type":"epic"}' --force 2>&1 | node_id_from_output)
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
    child_id=$("$WV" add "Linked child task" --parent="$epic_id" --force 2>&1 | node_id_from_output)
    assert_contains "$child_id" "wv-" "add with --parent succeeds"

    # With --force, add succeeds even without --parent
    local forced_id
    forced_id=$("$WV" add "Force-created task" --force 2>&1 | node_id_from_output)
    assert_contains "$forced_id" "wv-" "add with --force bypasses orphan guard"

    # No active epics — task allowed without --parent (the gap that let wv-2efef5 exist)
    # Mark the epic done so no active epics remain
    "$WV" done "$epic_id" >/dev/null 2>&1
    local free_id
    free_id=$("$WV" add "No-parent task when no active epics" --force 2>&1 | node_id_from_output)
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
    source_id=$("$WV" add "Investigate install hook drift" --force 2>&1 | node_id_from_output)
    "$WV" done "$source_id" \
        --learning="pitfall: hooks copied by install.sh but not wired into settings.json; add settings wiring in install.sh" \
        >/dev/null 2>&1

    output=$(WV_CLI="$WV" PATH="$PROJECT_ROOT/scripts:$PATH" "$WV" findings promote --json 2>&1)
    assert_contains "$output" '"candidates"' "findings promote defaults to dry-run candidates"
    assert_contains "$output" "$source_id" "findings promote reports source node"
    assert_fails "findings promote --apply requires parent" "$WV" findings promote --apply

    parent_id=$("$WV" add "Review promoted historical findings" --force 2>&1 | node_id_from_output)
    output=$(WV_CLI="$WV" PATH="$PROJECT_ROOT/scripts:$PATH" \
        "$WV" findings promote --apply --parent="$parent_id" --json 2>&1)
    assert_contains "$output" '"promoted"' "findings promote apply returns promoted nodes"
    assert_contains "$output" "$parent_id" "findings promote apply reports parent"

    all_nodes=$("$WV" list --all --json 2>/dev/null)
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
    language    TEXT    NOT NULL DEFAULT '',
    gini        REAL    NOT NULL DEFAULT 0.0
);
SQL

    # --- Case 1: node with a breaching file should NOT be closeable ---
    # mccabe_max=30 > mccabe_max_py=25 → blocks
    local breach_id
    breach_id=$("$WV" add "Node with complex file" --force 2>&1 | node_id_from_output)
    "$WV" work "$breach_id" >/dev/null 2>&1

    # WV_REQUIRE_QUALITY=0 bypasses P2 refresh so we can seed file_metrics directly.
    sqlite3 "$WV_DB" <<SQL
INSERT OR REPLACE INTO file_metrics(path, mccabe_max, language) VALUES ('src/complex.py', 30, 'py');
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
    assert_equals "mccabe_max_py" "$breach_threshold" \
        "mccabe policy violation payload names the breached threshold"

    # --- Case 2: node within threshold closes normally ---
    local clean_id
    clean_id=$("$WV" add "Node with clean file" --force 2>&1 | node_id_from_output)
    "$WV" work "$clean_id" >/dev/null 2>&1

    sqlite3 "$WV_DB" <<SQL
INSERT OR REPLACE INTO file_metrics(path, mccabe_max, language) VALUES ('src/simple.py', 5, 'py');
INSERT OR REPLACE INTO node_files(node_id, path) VALUES ('$clean_id', 'src/simple.py');
SQL

    local clean_out
    clean_out=$(WV_REQUIRE_QUALITY=0 "$WV" done "$clean_id" 2>&1)
    assert_contains "$clean_out" "Closed" \
        "done succeeds when per-language mccabe_max is within threshold"

    # --- Case 2b: bash file with CC=80 < mccabe_max_sh=100 → allowed ---
    local bash_id
    bash_id=$("$WV" add "Node with complex bash file within bash threshold" --force 2>&1 | node_id_from_output)
    "$WV" work "$bash_id" >/dev/null 2>&1
    sqlite3 "$WV_DB" <<SQL
INSERT OR REPLACE INTO file_metrics(path, mccabe_max, language) VALUES ('scripts/run.sh', 80, 'sh');
INSERT OR REPLACE INTO node_files(node_id, path) VALUES ('$bash_id', 'scripts/run.sh');
SQL
    local bash_ok_out
    bash_ok_out=$(WV_REQUIRE_QUALITY=0 "$WV" done "$bash_id" 2>&1)
    assert_contains "$bash_ok_out" "Closed" \
        "done succeeds for bash file with CC=80 < mccabe_max_sh=100"

    # --- Case 2c: bash file with CC=120 > mccabe_max_sh=100 → blocked ---
    local bash_breach_id
    bash_breach_id=$("$WV" add "Node with egregious bash file" --force 2>&1 | node_id_from_output)
    "$WV" work "$bash_breach_id" >/dev/null 2>&1
    sqlite3 "$WV_DB" <<SQL
INSERT OR REPLACE INTO file_metrics(path, mccabe_max, language) VALUES ('install.sh', 120, 'sh');
INSERT OR REPLACE INTO node_files(node_id, path) VALUES ('$bash_breach_id', 'install.sh');
SQL
    local bash_breach_out
    bash_breach_out=$(WV_REQUIRE_QUALITY=0 "$WV" done "$bash_breach_id" 2>&1 || true)
    assert_contains "$bash_breach_out" "GraphPolicyViolation" \
        "done is blocked for bash file with CC=120 > mccabe_max_sh=100"

    # --- Case 3: FTS search still works after trigger addition (no regression) ---
    local search_id
    search_id=$("$WV" add "Policy trigger regression check node" --force 2>&1 | node_id_from_output)
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
    trend_id=$("$WV" add "Node with deteriorating trend" --force 2>&1 | node_id_from_output)
    "$WV" work "$trend_id" >/dev/null 2>&1

    sqlite3 "$WV_DB" <<SQL
INSERT OR REPLACE INTO file_metrics(path, mccabe_max, language) VALUES ('src/trending.py', 5, 'py');
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

    # --- Case 6: exempt path is skipped by _done_refresh_file_metrics ---
    # Seed quality_exempt; then call _done_refresh via a real node + quality.db stub.
    sqlite3 "$WV_DB" "INSERT OR IGNORE INTO quality_exempt(path_pattern) VALUES('install.sh');" 2>/dev/null
    sqlite3 "$WV_DB" "INSERT OR IGNORE INTO quality_exempt(path_pattern) VALUES('archive/');" 2>/dev/null

    local exempt_in_table
    exempt_in_table=$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM quality_exempt;")
    assert_equals "2" "$exempt_in_table" \
        "quality_exempt table populated with 2 patterns"

    # File_metrics should NOT have install.sh after seeding + checking (gate skips it).
    # We seed file_metrics with a breaching value and confirm _is_quality_exempt logic:
    # gate won't block on exempt path even if file_metrics has a high value.
    local exempt_id
    exempt_id=$("$WV" add "Node touching exempt file" --force 2>&1 | node_id_from_output)
    "$WV" work "$exempt_id" >/dev/null 2>&1
    sqlite3 "$WV_DB" <<SQL
INSERT OR REPLACE INTO file_metrics(path, mccabe_max, language) VALUES ('install.sh', 168, 'sh');
INSERT OR REPLACE INTO node_files(node_id, path) VALUES ('$exempt_id', 'install.sh');
SQL
    local exempt_out
    exempt_out=$(WV_REQUIRE_QUALITY=0 "$WV" done "$exempt_id" 2>&1)
    assert_contains "$exempt_out" "Closed" \
        "done succeeds for exempt path (install.sh) even when file_metrics has CC=168 > sh=100"

    # --- Case 7: directory prefix exemption (archive/) blocks subtree ---
    local arch_id
    arch_id=$("$WV" add "Node touching archived test file" --force 2>&1 | node_id_from_output)
    "$WV" work "$arch_id" >/dev/null 2>&1
    sqlite3 "$WV_DB" <<SQL
INSERT OR REPLACE INTO file_metrics(path, mccabe_max, language) VALUES ('archive/tests/old_test.py', 89, 'py');
INSERT OR REPLACE INTO node_files(node_id, path) VALUES ('$arch_id', 'archive/tests/old_test.py');
SQL
    local arch_out
    arch_out=$(WV_REQUIRE_QUALITY=0 "$WV" done "$arch_id" 2>&1)
    assert_contains "$arch_out" "Closed" \
        "done succeeds for file under exempt directory prefix (archive/)"

    # --- Case 8: test_gate clause (P6b) — red/stale file blocks at test_gate>=block ---
    # NOTE: cases 1 (mccabe) and 5 (trend) above ran against THIS same trigger,
    # which is recreated from the single-source emitter by db_migrate_test_gate
    # (last migration). Their ABORT assertions are the regression tripwire proving
    # the emitter preserved clauses 1 and 2 while adding clause 3.
    # WV_REQUIRE_QUALITY=0 skips _done_refresh_test_status so the seeded state stands.
    sqlite3 "$WV_DB" "INSERT OR REPLACE INTO policy_thresholds(key, value) VALUES ('test_gate', 2);"
    local tg_id
    tg_id=$("$WV" add "Node with a red test file" --force 2>&1 | node_id_from_output)
    "$WV" work "$tg_id" >/dev/null 2>&1
    sqlite3 "$WV_DB" <<SQL
INSERT OR REPLACE INTO file_test_status(path, state) VALUES ('src/untested.py', 'red');
INSERT OR REPLACE INTO node_files(node_id, path) VALUES ('$tg_id', 'src/untested.py');
SQL
    local tg_out
    tg_out=$(WV_REQUIRE_QUALITY=0 "$WV" done "$tg_id" 2>&1 || true)
    assert_contains "$tg_out" "GraphPolicyViolation" \
        "done blocked when test_gate=block and a touched file is red"
    assert_contains "$tg_out" '"threshold":"test_gate"' \
        "test_gate violation payload names the test_gate threshold"
    assert_contains "$tg_out" '"state":"red"' \
        "test_gate violation payload includes the failing state"
    local tg_status
    tg_status=$(sqlite3 "$WV_DB" "SELECT status FROM nodes WHERE id='$tg_id';")
    assert_equals "active" "$tg_status" "node stays active after test_gate abort"

    # --- Case 8b: same red file is INERT when test_gate=off (default 0) ---
    sqlite3 "$WV_DB" "INSERT OR REPLACE INTO policy_thresholds(key, value) VALUES ('test_gate', 0);"
    local tg_out2
    tg_out2=$(WV_REQUIRE_QUALITY=0 "$WV" done "$tg_id" 2>&1)
    assert_contains "$tg_out2" "Closed" \
        "done succeeds on a red file when test_gate=off (gate inert by default)"

    # --- Case 8c: unknown test state never blocks, even at test_gate=block ---
    sqlite3 "$WV_DB" "INSERT OR REPLACE INTO policy_thresholds(key, value) VALUES ('test_gate', 2);"
    local tgu_id
    tgu_id=$("$WV" add "Node with unknown test file" --force 2>&1 | node_id_from_output)
    "$WV" work "$tgu_id" >/dev/null 2>&1
    sqlite3 "$WV_DB" <<SQL
INSERT OR REPLACE INTO file_test_status(path, state) VALUES ('src/unknownst.py', 'unknown');
INSERT OR REPLACE INTO node_files(node_id, path) VALUES ('$tgu_id', 'src/unknownst.py');
SQL
    local tgu_out
    tgu_out=$(WV_REQUIRE_QUALITY=0 "$WV" done "$tgu_id" 2>&1)
    assert_contains "$tgu_out" "Closed" \
        "done succeeds when test state is unknown (non-blocking) even at test_gate=block"

    # --- Case 9 (P6c): test_gate=warn emits advisory but does NOT block ---
    sqlite3 "$WV_DB" "INSERT OR REPLACE INTO policy_thresholds(key, value) VALUES ('test_gate', 1);"
    local warn_id
    warn_id=$("$WV" add "Node with red file at warn level" --force 2>&1 | node_id_from_output)
    "$WV" work "$warn_id" >/dev/null 2>&1
    sqlite3 "$WV_DB" <<SQL
INSERT OR REPLACE INTO file_test_status(path, state) VALUES ('src/warnme.py', 'red');
INSERT OR REPLACE INTO node_files(node_id, path) VALUES ('$warn_id', 'src/warnme.py');
SQL
    local warn_out
    warn_out=$(WV_REQUIRE_QUALITY=0 "$WV" done "$warn_id" --learning="x" 2>&1)
    assert_contains "$warn_out" "Closed" \
        "test_gate=warn does not block the close (advisory only)"
    assert_contains "$warn_out" "test_gate=warn" \
        "test_gate=warn emits a non-blocking advisory naming the unverified file"

    # --- Case 9b: --skip-verification suppresses the warn advisory ---
    local warn_id2
    warn_id2=$("$WV" add "Node with red file, skip-verification" --force 2>&1 | node_id_from_output)
    "$WV" work "$warn_id2" >/dev/null 2>&1
    sqlite3 "$WV_DB" <<SQL
INSERT OR REPLACE INTO file_test_status(path, state) VALUES ('src/skipme.py', 'red');
INSERT OR REPLACE INTO node_files(node_id, path) VALUES ('$warn_id2', 'src/skipme.py');
SQL
    local warn_out2
    warn_out2=$(WV_REQUIRE_QUALITY=0 "$WV" done "$warn_id2" --skip-verification 2>&1)
    assert_contains "$warn_out2" "Closed" \
        "--skip-verification still closes at test_gate=warn"
    assert_not_contains "$warn_out2" "test_gate=warn" \
        "--skip-verification suppresses the test_gate warn advisory"

    # --- Case 9c: node-type exemption — an epic with a red file closes even at block ---
    sqlite3 "$WV_DB" "INSERT OR REPLACE INTO policy_thresholds(key, value) VALUES ('test_gate', 2);"
    local epic_id
    epic_id=$("$WV" add "Epic touching a red file" --force 2>&1 | node_id_from_output)
    "$WV" work "$epic_id" >/dev/null 2>&1
    sqlite3 "$WV_DB" <<SQL
UPDATE nodes SET metadata=json_set(COALESCE(metadata,'{}'), '\$.type', 'epic') WHERE id='$epic_id';
INSERT OR REPLACE INTO file_test_status(path, state) VALUES ('src/epicfile.py', 'red');
INSERT OR REPLACE INTO node_files(node_id, path) VALUES ('$epic_id', 'src/epicfile.py');
SQL
    local epic_out
    epic_out=$(WV_REQUIRE_QUALITY=0 "$WV" done "$epic_id" --skip-verification 2>&1)
    assert_contains "$epic_out" "Closed" \
        "node-type exemption: an epic with a red touched file closes even at test_gate=block"

    # Restore default so later tests are unaffected.
    sqlite3 "$WV_DB" "INSERT OR REPLACE INTO policy_thresholds(key, value) VALUES ('test_gate', 0);"
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
    skip_id=$("$WV" add "Trend skip test node" --force 2>&1 | node_id_from_output)
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

    sqlite3 "$WV_DB" "DELETE FROM chunks;" 2>/dev/null
    PATH="/usr/local/bin:/usr/bin:/bin" "$WV" index "$TEST_DIR/src" --no-embed --ext=.py --json > "$TEST_DIR/idx-minimal-path.json" 2>&1
    assert_equals "true" "$(jq -r 'has("chunks")' "$TEST_DIR/idx-minimal-path.json" 2>/dev/null || echo false)" \
        "wv index resolves agent Python under Codex-style minimal PATH"

    # --- Case 4: re-indexing same file replaces chunks (no duplicates) ---
    local before_count after_count
    before_count=$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM chunks WHERE file LIKE '%sentinel.py';" 2>/dev/null)
    "$WV" index "$TEST_DIR/src" --no-embed --ext=.py >/dev/null 2>&1
    after_count=$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM chunks WHERE file LIKE '%sentinel.py';" 2>/dev/null)
    assert_equals "$before_count" "$after_count" \
        "re-indexing same file replaces chunks (no duplicates)"
}

test_wv_search_learning_fts() {
    echo ""
    echo "Test: wv search — FTS5 learning content indexing"
    echo "================================================="

    setup_test_env

    # Add a node with no learning content
    local plain_id
    plain_id=$("$WV" add "task: implement login form" --standalone --force 2>/dev/null | node_id_from_output)

    # Add a node with learning content in metadata
    local learning_id
    learning_id=$("$WV" add "task: auth middleware refactor" --standalone --force 2>/dev/null | node_id_from_output)
    "$WV" update "$learning_id" --metadata='{"decision":"chose JWT over session cookies for stateless auth","pattern":"middleware wraps all protected routes","pitfall":"forgetting to validate expiry","learning":"stateless auth reduces db roundtrips"}' 2>/dev/null || true

    # Give triggers a moment then reindex to backfill
    "$WV" reindex 2>/dev/null || true

    # Query for term that appears only in learning content (not in node text)
    local search_out
    search_out=$("$WV" search "stateless auth" 2>/dev/null || echo "")
    local found_learning
    found_learning=$(echo "$search_out" | grep -c "$learning_id" || true)
    assert_success "wv search finds nodes via learning content" \
        test "${found_learning:-0}" -gt 0

    # Query for term in node text — still works
    local text_out
    text_out=$("$WV" search "login form" 2>/dev/null || echo "")
    local found_plain
    found_plain=$(echo "$text_out" | grep -c "$plain_id" || true)
    assert_success "wv search still finds nodes via node text" \
        test "${found_plain:-0}" -gt 0

    # --learning filter returns only nodes with learning content
    local learning_filter_out
    learning_filter_out=$("$WV" search "middleware" --learning 2>/dev/null || echo "")
    local found_learning_filter
    found_learning_filter=$(echo "$learning_filter_out" | grep -c "$learning_id" || true)
    assert_success "wv search --learning finds node with learning content" \
        test "${found_learning_filter:-0}" -gt 0

    # --type filter runs without error
    local type_out
    type_out=$("$WV" search "auth" --type=task 2>/dev/null || echo "")
    assert_success "wv search --type=task runs without error" \
        test -n "$type_out"

    # --json output includes results from both tables
    local json_out
    json_out=$("$WV" search "JWT stateless" --json 2>/dev/null || echo "[]")
    local json_count
    json_count=$(echo "$json_out" | jq '. | length' 2>/dev/null || echo "0")
    assert_success "wv search --json with learning term returns results" \
        test "${json_count:-0}" -gt 0
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

    local minimal_path_json minimal_path_count
    minimal_path_json=$(PATH="/usr/local/bin:/usr/bin:/bin" "$WV" search --code sentinel_hybrid_search_fn --json --mode=fts 2>/dev/null)
    minimal_path_count=$(echo "$minimal_path_json" | jq '.results | length' 2>/dev/null || echo "0")
    assert_success "wv search --code resolves agent Python under Codex-style minimal PATH" test "$minimal_path_count" -gt 0

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
    assert_contains "$(echo "$empty_out" | jq -r '.readiness.chunks.hint' 2>/dev/null || echo '')" "wv index . --json" \
        "wv search --code with empty db suggests a copy-pasteable index command"
    assert_contains "$(echo "$empty_out" | jq -r '.readiness.node_files.hint' 2>/dev/null || echo '')" "wv touch <id> --files=src/file.py" \
        "wv search --code with empty db suggests a copy-pasteable file attribution command"
    assert_contains "$(echo "$empty_out" | jq -r '.readiness.quality_db.hint' 2>/dev/null || echo '')" "wv quality scan . --json" \
        "wv search --code with empty db suggests a copy-pasteable quality scan command"

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
    idle_id=$("$WV" add "Idle policy preflight node" --force 2>&1 | node_id_from_output)
    "$WV" work "$idle_id" >/dev/null 2>&1
    idle_json=$("$WV" preflight "$idle_id" 2>/dev/null)
    assert_equals "false" "$(echo "$idle_json" | jq -r '.policy_readiness.policy_sensitive' 2>/dev/null || echo true)" \
        "wv preflight reports nodes without tracked files as not policy-sensitive"
    assert_equals "false" "$(echo "$idle_json" | jq -r '.policy_readiness.blocking' 2>/dev/null || echo true)" \
        "wv preflight does not block when no tracked files exist"

    # --- Case 2: tracked files without quality.db block policy-sensitive completion ---
    local blocked_id blocked_json
    blocked_id=$("$WV" add "Blocked policy preflight node" --force 2>&1 | node_id_from_output)
    "$WV" work "$blocked_id" >/dev/null 2>&1
    sqlite3 "$WV_DB" "INSERT OR IGNORE INTO node_files(node_id, path) VALUES ('$blocked_id', 'src/policy.py');"
    blocked_json=$("$WV" preflight "$blocked_id" 2>/dev/null)
    assert_equals "true" "$(echo "$blocked_json" | jq -r '.policy_readiness.policy_sensitive' 2>/dev/null || echo false)" \
        "wv preflight marks tracked-file nodes as policy-sensitive"
    assert_equals "true" "$(echo "$blocked_json" | jq -r '.policy_readiness.blocking' 2>/dev/null || echo false)" \
        "wv preflight blocks policy-sensitive completion when quality.db is missing"
    assert_equals "missing" "$(echo "$blocked_json" | jq -r '.policy_readiness.quality.status' 2>/dev/null || echo unknown)" \
        "wv preflight reports missing quality prerequisites"
    assert_contains "$(echo "$blocked_json" | jq -r '.policy_readiness.hint' 2>/dev/null || echo '')" "wv quality scan . --json" \
        "wv preflight suggests a copy-pasteable quality scan command when policy readiness blocks"

    # --- Case 3: quality scan data clears the policy_readiness block ---
    sqlite3 "$WV_HOT_ZONE/quality.db" "CREATE TABLE scan_meta (id INTEGER PRIMARY KEY); INSERT INTO scan_meta(id) VALUES (1);" 2>/dev/null
    local ready_json
    ready_json=$("$WV" preflight "$blocked_id" 2>/dev/null)
    assert_equals "true" "$(echo "$ready_json" | jq -r '.policy_readiness.ready' 2>/dev/null || echo false)" \
        "wv preflight marks policy readiness ready once quality scan data exists"
    assert_equals "false" "$(echo "$ready_json" | jq -r '.policy_readiness.blocking' 2>/dev/null || echo true)" \
        "wv preflight clears the policy block once quality scan data exists"
}

test_bootstrap_quality_advisory() {
    echo ""
    echo "Test: wv bootstrap quality-scan advisory (wv-7fbc0f)"
    echo "===================================================="

    setup_test_env
    "$WV" init >/dev/null 2>&1

    # --- Case 1: active node, no tracked files → no quality advisory ---
    local idle_id idle_boot
    idle_id=$("$WV" add "Idle bootstrap node" --force 2>&1 | node_id_from_output)
    "$WV" work "$idle_id" >/dev/null 2>&1
    idle_boot=$("$WV" bootstrap --json 2>/dev/null)
    assert_equals "0" "$(echo "$idle_boot" | jq -r '[.advisories[] | select(startswith("quality scan needed"))] | length' 2>/dev/null || echo -1)" \
        "bootstrap emits no quality advisory when active node has no tracked files"

    # --- Case 2: tracked files + missing quality.db → advisory surfaces early ---
    sqlite3 "$WV_DB" "INSERT OR IGNORE INTO node_files(node_id, path) VALUES ('$idle_id', 'src/policy.py');"
    local blocked_boot
    blocked_boot=$("$WV" bootstrap --json 2>/dev/null)
    assert_equals "1" "$(echo "$blocked_boot" | jq -r '[.advisories[] | select(startswith("quality scan needed"))] | length' 2>/dev/null || echo -1)" \
        "bootstrap surfaces a quality-scan advisory when active node touches tracked files but quality.db is missing"
    assert_contains "$(echo "$blocked_boot" | jq -r '.advisories[] | select(startswith("quality scan needed"))' 2>/dev/null || echo '')" "wv quality scan ." \
        "quality advisory names the wv quality scan command"
    assert_contains "$(echo "$blocked_boot" | jq -r '.advisories[] | select(startswith("quality scan needed"))' 2>/dev/null || echo '')" "$idle_id" \
        "quality advisory names the active node id"

    # --- Case 3: scan data present → advisory clears ---
    sqlite3 "$WV_HOT_ZONE/quality.db" "CREATE TABLE scan_meta (id INTEGER PRIMARY KEY); INSERT INTO scan_meta(id) VALUES (1);" 2>/dev/null
    local cleared_boot
    cleared_boot=$("$WV" bootstrap --json 2>/dev/null)
    assert_equals "0" "$(echo "$cleared_boot" | jq -r '[.advisories[] | select(startswith("quality scan needed"))] | length' 2>/dev/null || echo -1)" \
        "bootstrap clears the quality advisory once a scan exists"
}

test_p2_quality_refresh() {
    echo ""
    echo "Test: P2 — file_metrics refresh on wv done"
    echo "==========================================="

    setup_test_env
    "$WV" init >/dev/null 2>&1

    # --- Case 1: quality.db absent + node_files pre-seeded → loud failure ---
    local noq_id
    noq_id=$("$WV" add "Node needing quality check" --force 2>&1 | node_id_from_output)
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
    noscan_id=$("$WV" add "Node needing scan data" --force 2>&1 | node_id_from_output)
    "$WV" work "$noscan_id" >/dev/null 2>&1

    sqlite3 "$WV_DB" <<SQL
INSERT OR IGNORE INTO node_files(node_id, path) VALUES ('$noscan_id', 'src/feature.py');
SQL

    # Create quality.db with schema but no scan rows.
    local quality_db="$WV_HOT_ZONE/quality.db"
    sqlite3 "$quality_db" "CREATE TABLE IF NOT EXISTS scan_meta (id INTEGER PRIMARY KEY, scanned_at TEXT, git_head TEXT, files_count INTEGER, duration_ms INTEGER, scanner_version TEXT);"
    sqlite3 "$quality_db" "CREATE TABLE IF NOT EXISTS file_metrics (path TEXT NOT NULL, scan_id INTEGER NOT NULL, metric TEXT NOT NULL, value REAL, detail TEXT, PRIMARY KEY(path, scan_id, metric));"

    local noscan_out noscan_rc
    noscan_out=$("$WV" done "$noscan_id" 2>&1 || true)
    noscan_rc=$("$WV" show "$noscan_id" --json 2>/dev/null | jq -r '.status' 2>/dev/null || echo "active")
    assert_contains "$noscan_out" "no scan data" \
        "wv done fails loudly when quality.db exists but has no scans"
    assert_equals "active" "$noscan_rc" \
        "node stays active when quality.db has no scan data"

    # --- Case 3: quality.db with fn_cc:* rows → mccabe_max = MAX per-function CC ---
    sqlite3 "$quality_db" "INSERT INTO scan_meta(id, scanned_at, git_head) VALUES(1, '2026-01-01T00:00:00', 'abc1234');"
    sqlite3 "$quality_db" <<'SQL'
INSERT INTO file_metrics(path, scan_id, metric, value) VALUES
    ('src/feature.py', 1, 'fn_cc:parse@10', 8.0),
    ('src/feature.py', 1, 'fn_cc:render@40', 5.0),
    ('src/feature.py', 1, 'fn_cc:validate@70', 3.0);
SQL

    local ok_id
    ok_id=$("$WV" add "Node with quality data" --force 2>&1 | node_id_from_output)
    "$WV" work "$ok_id" >/dev/null 2>&1

    sqlite3 "$WV_DB" <<SQL
INSERT OR IGNORE INTO node_files(node_id, path) VALUES ('$ok_id', 'src/feature.py');
SQL

    local ok_out
    ok_out=$("$WV" done "$ok_id" 2>&1)
    assert_contains "$ok_out" "Closed" \
        "wv done succeeds when per-function CC max is within threshold"

    local refreshed_max refreshed_lang
    refreshed_max=$(sqlite3 "$WV_DB" "SELECT mccabe_max FROM file_metrics WHERE path='src/feature.py';")
    refreshed_lang=$(sqlite3 "$WV_DB" "SELECT language FROM file_metrics WHERE path='src/feature.py';")
    assert_equals "8" "$refreshed_max" \
        "file_metrics in brain.db populated with MAX(fn_cc:*) per-function CC"
    assert_equals "py" "$refreshed_lang" \
        "file_metrics language set to 'py' for .py file"

    # --- Case 4: bash file (no fn_cc:* rows) gets mccabe_max=0, language='sh' ---
    local bash_id
    bash_id=$("$WV" add "Node touching bash file" --force 2>&1 | node_id_from_output)
    "$WV" work "$bash_id" >/dev/null 2>&1
    sqlite3 "$WV_DB" "INSERT OR IGNORE INTO node_files(node_id, path) VALUES ('$bash_id', 'scripts/run.sh');"
    local bash_out
    bash_out=$("$WV" done "$bash_id" 2>&1)
    assert_contains "$bash_out" "Closed" \
        "wv done succeeds for bash file with no fn_cc:* entries (mccabe_max=0)"
    local bash_max bash_lang
    bash_max=$(sqlite3 "$WV_DB" "SELECT mccabe_max FROM file_metrics WHERE path='scripts/run.sh';")
    bash_lang=$(sqlite3 "$WV_DB" "SELECT language FROM file_metrics WHERE path='scripts/run.sh';")
    assert_equals "0" "$bash_max" \
        "bash file gets mccabe_max=0 when no fn_cc:* metrics exist"
    assert_equals "sh" "$bash_lang" \
        "bash file language set to 'sh'"
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
    parent=$("$WV" add "Trend parent" --force 2>&1 | node_id_from_output)
    warning_learning="decision: run make check | pattern: make check covers trend warnings | pitfall: watch deteriorating files before close"

    local det_id det_out det_trend
    det_id=$("$WV" add "Deteriorating trend node" --force 2>&1 | node_id_from_output)
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
    stable_id=$("$WV" add "Stable trend node" --force 2>&1 | node_id_from_output)
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
    ref_id=$("$WV" add "Refactored trend node" --force 2>&1 | node_id_from_output)
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
    node_id=$("$WV" add "Test allowed-tools node" --force 2>&1 | node_id_from_output)

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
    clean_id=$("$WV" add "Clean node no tools" --force 2>&1 | node_id_from_output)
    "$WV" work "$clean_id" >/dev/null 2>&1
    local clean_tools
    clean_tools=$("$WV" allowed-tools "$clean_id" --json 2>&1)
    assert_equals "null" "$clean_tools" \
        "wv work without --allowed-tools leaves allowed_tools unset"
}

test_test_results_ledger() {
    echo ""
    echo "Test: test_results ledger + wv test-record (P6a)"
    echo "============================================================"

    setup_test_env
    "$WV" init >/dev/null 2>&1

    # --- migration provisions the table with the per-path 'path' column ---
    local has_table has_path
    has_table=$(sqlite3 "$WV_DB" "SELECT name FROM sqlite_master WHERE type='table' AND name='test_results';")
    assert_equals "test_results" "$has_table" "test_results table created by migration"
    has_path=$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM pragma_table_info('test_results') WHERE name='path';")
    assert_equals "1" "$has_path" "test_results has per-file 'path' column (P6b)"

    # --- one row per --files entry, each with that file's own fingerprint ---
    echo "alpha" > "$TEST_DIR/a.sh"
    echo "beta"  > "$TEST_DIR/b.sh"
    "$WV" test-record "tests/test-foo.sh" --files="a.sh,b.sh" --exit=0 >/dev/null 2>&1
    local row_count fp_a fp_b
    row_count=$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM test_results WHERE suite='tests/test-foo.sh';")
    assert_equals "2" "$row_count" "test-record writes one row per --files entry"
    fp_a=$(sqlite3 "$WV_DB" "SELECT fingerprint FROM test_results WHERE suite='tests/test-foo.sh' AND path='a.sh';")
    fp_b=$(sqlite3 "$WV_DB" "SELECT fingerprint FROM test_results WHERE suite='tests/test-foo.sh' AND path='b.sh';")
    assert_success "per-file fingerprint a.sh non-empty" test -n "$fp_a"
    assert_not_contains "$fp_a" "$fp_b" "distinct files get distinct fingerprints"

    # --- fingerprint == git blob hash (same pure function the consumer uses) ---
    local blob_a
    blob_a=$(cd "$TEST_DIR" && git hash-object a.sh)
    assert_equals "$blob_a" "$fp_a" "fingerprint is the file's git blob hash"

    # --- idempotent per (suite, path): re-record updates the row in place ---
    "$WV" test-record "tests/test-foo.sh" --files="a.sh" --exit=1 >/dev/null 2>&1
    local row_count2 ec_a
    row_count2=$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM test_results WHERE suite='tests/test-foo.sh';")
    assert_equals "2" "$row_count2" "re-record same (suite,path) upserts (no duplicate row)"
    ec_a=$(sqlite3 "$WV_DB" "SELECT exit_code FROM test_results WHERE suite='tests/test-foo.sh' AND path='a.sh';")
    assert_equals "1" "$ec_a" "latest outcome wins per (suite, path)"

    # --- fingerprint tracks content: editing the file updates the same row's fp ---
    echo "alpha-changed" > "$TEST_DIR/a.sh"
    "$WV" test-record "tests/test-foo.sh" --files="a.sh" --exit=0 >/dev/null 2>&1
    local fp_a2
    fp_a2=$(sqlite3 "$WV_DB" "SELECT fingerprint FROM test_results WHERE suite='tests/test-foo.sh' AND path='a.sh';")
    assert_not_contains "$fp_a" "$fp_a2" "fingerprint changes after content change (same row)"

    # --- non-numeric exit code is coerced to failure (1) ---
    "$WV" test-record "tests/test-bar.sh" --files="a.sh" --exit=abc >/dev/null 2>&1
    local ec_bad
    ec_bad=$(sqlite3 "$WV_DB" "SELECT exit_code FROM test_results WHERE suite='tests/test-bar.sh' AND path='a.sh';")
    assert_equals "1" "$ec_bad" "non-numeric exit code coerced to 1"

    # --- empty --files records a single sentinel row (path='') ---
    "$WV" test-record "tests/test-baz.sh" --exit=0 >/dev/null 2>&1
    local row_nofiles sentinel
    row_nofiles=$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM test_results WHERE suite='tests/test-baz.sh';")
    assert_equals "1" "$row_nofiles" "test-record with no --files records one sentinel row"
    sentinel=$(sqlite3 "$WV_DB" "SELECT path FROM test_results WHERE suite='tests/test-baz.sh';")
    assert_equals "" "$sentinel" "sentinel row has empty path"

    # --- missing suite arg errors ---
    local bad_rc
    bad_rc=0
    "$WV" test-record >/dev/null 2>&1 || bad_rc=$?
    assert_equals "1" "$bad_rc" "test-record without a suite arg exits 1"

    # --- duration_ms persisted (LL1): --duration stored; absent/garbage -> 0 ---
    local has_dur dur_stored dur_default dur_garbage
    has_dur=$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM pragma_table_info('test_results') WHERE name='duration_ms';")
    assert_equals "1" "$has_dur" "test_results has duration_ms column (LL1 migration)"
    "$WV" test-record "tests/test-dur.sh" --files="a.sh" --exit=0 --duration=4242 >/dev/null 2>&1
    dur_stored=$(sqlite3 "$WV_DB" "SELECT duration_ms FROM test_results WHERE suite='tests/test-dur.sh' AND path='a.sh';")
    assert_equals "4242" "$dur_stored" "--duration value persisted to the row"
    "$WV" test-record "tests/test-dur2.sh" --files="a.sh" --exit=0 >/dev/null 2>&1
    dur_default=$(sqlite3 "$WV_DB" "SELECT duration_ms FROM test_results WHERE suite='tests/test-dur2.sh' AND path='a.sh';")
    assert_equals "0" "$dur_default" "absent --duration defaults to 0"
    "$WV" test-record "tests/test-dur3.sh" --files="a.sh" --exit=0 --duration=abc >/dev/null 2>&1
    dur_garbage=$(sqlite3 "$WV_DB" "SELECT duration_ms FROM test_results WHERE suite='tests/test-dur3.sh' AND path='a.sh';")
    assert_equals "0" "$dur_garbage" "non-numeric --duration coerced to 0"

    # --- durable history survives a simulated wv load (LL2) ---
    # The disk JSONL log is independent of the tmpfs table: wiping the DB (what
    # wv load does) must not lose history.
    local log_lines_before log_lines_after
    log_lines_before=$(wc -l < "$WV_SUITE_LOG" 2>/dev/null | tr -d ' ')
    assert_success "suite history log written on disk" test -s "$WV_SUITE_LOG"
    rm -f "$WV_DB"   # simulate wv load wiping the tmpfs current-state table
    log_lines_after=$(wc -l < "$WV_SUITE_LOG" 2>/dev/null | tr -d ' ')
    assert_equals "$log_lines_before" "$log_lines_after" "history log survives a tmpfs DB wipe (wv load)"
    # one JSONL line per RUN (not per file): a 2-file run adds exactly 1 line
    local before2 after2
    "$WV" init >/dev/null 2>&1   # rebuild the wiped DB so test-record can upsert
    before2=$(wc -l < "$WV_SUITE_LOG" 2>/dev/null | tr -d ' ')
    "$WV" test-record "tests/test-run.sh" --files="a.sh,b.sh" --exit=0 --duration=10 >/dev/null 2>&1
    after2=$(wc -l < "$WV_SUITE_LOG" 2>/dev/null | tr -d ' ')
    assert_equals "$((before2 + 1))" "$after2" "one history line per RUN regardless of file count"
}

test_done_refresh_test_status() {
    echo ""
    echo "Test: _done_refresh_test_status — ledger -> file_test_status (P6b consumer)"
    echo "============================================================"

    setup_test_env
    "$WV" init >/dev/null 2>&1

    # test-map.conf: map the source file to a suite (the shared resolver reads this).
    mkdir -p "$TEST_DIR/.weave"
    printf '[map]\nsrc/foo.sh = tests/test-foo.sh\n' > "$TEST_DIR/.weave/test-map.conf"

    mkdir -p "$TEST_DIR/src"
    echo "green-content" > "$TEST_DIR/src/foo.sh"

    # Producer: record a green result for the current content.
    (cd "$TEST_DIR" && "$WV" test-record "tests/test-foo.sh" --files="src/foo.sh" --exit=0 >/dev/null 2>&1)

    # A node touching that path.
    local nid
    nid=$("$WV" add "Node touching tested file" --force 2>&1 | node_id_from_output)
    "$WV" work "$nid" >/dev/null 2>&1
    sqlite3 "$WV_DB" "INSERT OR REPLACE INTO node_files(node_id, path) VALUES ('$nid', 'src/foo.sh');"

    # Invoke the consumer directly (WV_REQUIRE_QUALITY default so it runs).
    run_refresh() {
        cd "$TEST_DIR" && WEAVE_DIR="$TEST_DIR/.weave" WV_DB="$WV_DB" bash -c "
            source '$PROJECT_ROOT/scripts/lib/wv-validate.sh'
            source '$PROJECT_ROOT/scripts/lib/wv-db.sh'
            source '$PROJECT_ROOT/scripts/cmd/wv-cmd-graph.sh'
            source '$PROJECT_ROOT/scripts/cmd/wv-cmd-ops.sh'
            source '$PROJECT_ROOT/scripts/cmd/wv-cmd-core.sh'
            _done_refresh_test_status '$1'
        " 2>/dev/null
    }

    # --- green: ledger fingerprint matches current content + exit 0 ---
    run_refresh "$nid"
    local st_green
    st_green=$(sqlite3 "$WV_DB" "SELECT state FROM file_test_status WHERE path='src/foo.sh';")
    assert_equals "green" "$st_green" "fresh pass (fp match + exit 0) -> green"

    # --- stale: content changes after the recorded run ---
    echo "edited-after-test" > "$TEST_DIR/src/foo.sh"
    run_refresh "$nid"
    local st_stale
    st_stale=$(sqlite3 "$WV_DB" "SELECT state FROM file_test_status WHERE path='src/foo.sh';")
    assert_equals "stale" "$st_stale" "content changed since recorded run -> stale"

    # --- red: re-record a failing run at the new content ---
    (cd "$TEST_DIR" && "$WV" test-record "tests/test-foo.sh" --files="src/foo.sh" --exit=1 >/dev/null 2>&1)
    run_refresh "$nid"
    local st_red
    st_red=$(sqlite3 "$WV_DB" "SELECT state FROM file_test_status WHERE path='src/foo.sh';")
    assert_equals "red" "$st_red" "fresh fail (fp match + exit !=0) -> red"

    # --- unknown: a path with no ledger row / no mapping ---
    local nid2
    nid2=$("$WV" add "Node touching unmapped file" --force 2>&1 | node_id_from_output)
    "$WV" work "$nid2" >/dev/null 2>&1
    sqlite3 "$WV_DB" "INSERT OR REPLACE INTO node_files(node_id, path) VALUES ('$nid2', 'src/nomapping.sh');"
    echo "x" > "$TEST_DIR/src/nomapping.sh"
    run_refresh "$nid2"
    local st_unknown
    st_unknown=$(sqlite3 "$WV_DB" "SELECT state FROM file_test_status WHERE path='src/nomapping.sh';")
    assert_equals "unknown" "$st_unknown" "no ledger result for the path -> unknown"
}

test_quality_config_thresholds() {
    echo ""
    echo "Test: .weave/quality.conf [thresholds] -> policy_thresholds (P6d durable config)"
    echo "============================================================"

    setup_test_env
    "$WV" init >/dev/null 2>&1
    "$WV" sync >/dev/null 2>&1   # create state.sql so wv load has something to restore

    mkdir -p "$TEST_DIR/.weave"
    cat > "$TEST_DIR/.weave/quality.conf" <<'CONF'
[exempt]
vendor/

[thresholds]
test_gate = 2            # block
mccabe_max_py = 30
bogus@key = 5
test_gate_bad = abc
CONF

    "$WV" load >/dev/null 2>&1

    # --- valid threshold rows applied (INSERT OR REPLACE over the seeded default) ---
    local tg mp
    tg=$(sqlite3 "$WV_DB" "SELECT CAST(value AS INTEGER) FROM policy_thresholds WHERE key='test_gate';")
    assert_equals "2" "$tg" "[thresholds] test_gate=2 applied durably on load"
    mp=$(sqlite3 "$WV_DB" "SELECT CAST(value AS INTEGER) FROM policy_thresholds WHERE key='mccabe_max_py';")
    assert_equals "30" "$mp" "[thresholds] overrides a seeded default (mccabe_max_py)"

    # --- malformed lines rejected (bad key chars, non-numeric value) ---
    local bogus badval
    bogus=$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM policy_thresholds WHERE key='bogus@key';")
    assert_equals "0" "$bogus" "[thresholds] rejects keys with invalid characters"
    badval=$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM policy_thresholds WHERE key='test_gate_bad';")
    assert_equals "0" "$badval" "[thresholds] rejects non-numeric values"

    # --- [exempt] still loads alongside [thresholds] ---
    local exempt
    exempt=$(sqlite3 "$WV_DB" "SELECT path_pattern FROM quality_exempt WHERE path_pattern='vendor/';")
    assert_equals "vendor/" "$exempt" "[exempt] still loads when [thresholds] is present"

    # --- O4b guard: test_gate=2 (block) in committed layer cannot be downgraded by local layer ---
    cat > "$TEST_DIR/.weave/quality.conf" <<'CONF2'
[thresholds]
test_gate = 2
CONF2
    cat > "$TEST_DIR/.weave/quality.local.conf" <<'CONF3'
[thresholds]
test_gate = 0
CONF3
    "$WV" load >/dev/null 2>&1
    local guarded_tg
    guarded_tg=$(sqlite3 "$WV_DB" "SELECT CAST(value AS INTEGER) FROM policy_thresholds WHERE key='test_gate';")
    assert_equals "2" "$guarded_tg" "O4b guard: local test_gate=0 cannot downgrade committed test_gate=2 (block)"

    # --- O4b: warn (test_gate=1) in committed layer IS overridable by local layer ---
    cat > "$TEST_DIR/.weave/quality.conf" <<'CONF4'
[thresholds]
test_gate = 1
CONF4
    cat > "$TEST_DIR/.weave/quality.local.conf" <<'CONF5'
[thresholds]
test_gate = 0
CONF5
    "$WV" load >/dev/null 2>&1
    local warn_overridden_tg
    warn_overridden_tg=$(sqlite3 "$WV_DB" "SELECT CAST(value AS INTEGER) FROM policy_thresholds WHERE key='test_gate';")
    assert_equals "0" "$warn_overridden_tg" "O4b: local can override test_gate=1 (warn) — only block is protected"

    # cleanup local conf
    rm -f "$TEST_DIR/.weave/quality.local.conf"
}

# ============================================================================
# Main
# ============================================================================
test_agent_identity_resolution() {
    echo ""
    echo "Test: agent identity resolution (wv-727175)"
    echo "==========================================="
    local L="$PROJECT_ROOT/scripts/lib/wv-resolve-runtime.sh"

    # 1. explicit WV_AGENT_ID always wins, even with harness markers present
    local id
    id=$(env CLAUDE_CODE_SSE_PORT=1 CODEX_CI=1 WV_AGENT_ID=explicit-id \
         bash -c "source '$L'; resolve_agent_id" 2>/dev/null)
    assert_equals "explicit-id" "$id" "explicit WV_AGENT_ID wins over markers"

    # 2. each harness yields a distinct identity prefix when exported alone
    local claude codex copilot human
    claude=$(env -u WV_AGENT_ID -u CODEX_THREAD_ID -u CODEX_CI -u COPILOT_AGENT \
             CLAUDE_CODE_SSE_PORT=1 bash -c "source '$L'; resolve_agent_id" 2>/dev/null)
    codex=$(env -u WV_AGENT_ID -u CLAUDE_CODE_SSE_PORT -u COPILOT_AGENT \
             CODEX_CI=1 bash -c "source '$L'; resolve_agent_id" 2>/dev/null)
    copilot=$(env -u WV_AGENT_ID -u CLAUDE_CODE_SSE_PORT -u CODEX_THREAD_ID -u CODEX_CI \
             COPILOT_AGENT=1 bash -c "source '$L'; resolve_agent_id" 2>/dev/null)
    human=$(env -u WV_AGENT_ID -u CLAUDE_CODE_SSE_PORT -u CODEX_THREAD_ID -u CODEX_CI -u COPILOT_AGENT \
             bash -c "source '$L'; resolve_agent_id" 2>/dev/null)
    assert_contains "$claude" "claude-" "claude marker -> claude- identity"
    assert_contains "$codex" "codex-" "codex marker -> codex- identity"
    assert_contains "$copilot" "copilot-" "copilot marker -> copilot- identity"

    # 3. human shell does not collapse onto an agent identity
    assert_contains "$human" "human-" "bare shell -> human- identity (not host-user)"
    local human_vs_claude="differ"
    [ "$human" = "$claude" ] && human_vs_claude="same"
    assert_equals "differ" "$human_vs_claude" "human identity differs from claude identity"

    # 4. ambiguous markers do not silently pretend certainty — a diagnostic is emitted
    local warn
    warn=$(env -u WV_AGENT_ID -u COPILOT_AGENT CLAUDE_CODE_SSE_PORT=1 CODEX_CI=1 \
           bash -c "source '$L'; resolve_agent_id >/dev/null" 2>&1)
    assert_contains "$warn" "ambiguous" "co-present markers emit an ambiguity diagnostic"
    assert_contains "$warn" "Set WV_AGENT_ID=codex-" "ambiguity diagnostic suggests a concrete WV_AGENT_ID"
}

test_delta_filename_carries_identity() {
    echo ""
    echo "Test: delta filenames carry the resolved agent identity (wv-727175)"
    echo "==================================================================="
    # Behavioral, not a source grep: auto_sync is disabled under a custom WV_DB
    # (the suite sets one), so run in an isolated hot-zone-only sandbox where real
    # delta changesets are emitted, then read the identity straight off the names.
    local sandbox; sandbox=$(mktemp -d)
    local -a E=(env -u WV_DB -u WV_DB_CUSTOM
                "WV_PROJECT_DIR=$sandbox" "WV_HOT_ZONE=$sandbox/hz"
                WV_REQUIRE_LEARNING=0 WV_AUTO_SYNC=1 WV_SYNC_INTERVAL=0)
    (
        cd "$sandbox" || exit 0
        git init -q
        "${E[@]}" WV_AGENT_ID=codex-deltabox "$WV" init >/dev/null 2>&1 || true
        "${E[@]}" WV_AGENT_ID=codex-deltabox "$WV" add "codex change" --force >/dev/null 2>&1 || true
        "${E[@]}" WV_AGENT_ID=claude-deltabox "$WV" add "claude change" --force >/dev/null 2>&1 || true
    ) || true
    local delta_names
    delta_names=$(find "$sandbox/.weave/deltas" -name '*.sql' 2>/dev/null \
        | while IFS= read -r f; do basename "$f"; done | tr '\n' ' ')
    assert_contains "$delta_names" "codex-deltabox" "codex delta filename carries codex identity"
    assert_contains "$delta_names" "claude-deltabox" "claude delta filename carries claude identity (distinct provenance)"
    rm -rf "$sandbox"
}

test_ready_filters_by_resolved_agent() {
    echo ""
    echo "Test: ready filters by resolved agent + cache is agent-keyed (wv-727175)"
    echo "======================================================================="
    setup_test_env
    "$WV" init >/dev/null 2>&1
    local id1
    id1=$("$WV" add "claimed by agentA" --force 2>&1 | node_id_from_output)
    "$WV" update "$id1" --metadata='{"claimed_by":"agentA"}' >/dev/null 2>&1

    # Cache ON: agentA warms the run cache, then agentB queries. A shared (non
    # agent-keyed) cache would leak agentA's filtered view to agentB. Identity in
    # the cache key must keep them separate.
    local seenA seenB seenBall
    seenA=$(WV_RUN_CACHE=1 WV_AGENT_ID=agentA "$WV" ready --count 2>/dev/null)
    seenB=$(WV_RUN_CACHE=1 WV_AGENT_ID=agentB "$WV" ready --count 2>/dev/null)
    seenBall=$(WV_RUN_CACHE=1 WV_AGENT_ID=agentB "$WV" ready --all --count 2>/dev/null)
    assert_equals "1" "$seenA" "agentA sees the node it claimed"
    assert_equals "0" "$seenB" "agentB does not see agentA's claim (cache not shared across agents)"
    assert_equals "1" "$seenBall" "agentB --all sees the node"
}

main() {
    echo "========================================"
    echo "Weave Core Command Tests"
    echo "========================================"

    test_init
    test_init_recovery
    test_leaked_env_overrides_are_ignored_across_repos
    test_codex_runtime_uses_tmp_hot_zone
    test_add
    test_orphan_prevention
    test_done
    test_done_stores_commit_hashes
    test_findings_promote
    test_auto_checkpoint_skip_at_origin
    test_work
    test_list
    test_show
    test_ready
    test_agent_identity_resolution
    test_delta_filename_carries_identity
    test_ready_filters_by_resolved_agent
    test_status
    test_bootstrap_agent
    test_stale_active_marker
    test_policy_trigger
    test_test_results_ledger
    test_done_refresh_test_status
    test_quality_config_thresholds
    test_trend_signal_wiring
    test_chunk_store_schema
    test_wv_index_command
    test_wv_search_learning_fts
    test_wv_search_code
    test_preflight_policy_readiness
    test_bootstrap_quality_advisory
    test_p2_quality_refresh
    test_trend_soft_warning
    test_allowed_tools
    test_ready_relevance_boost
    test_done_contradiction
    test_update_metadata_merge
    test_help_surfaces
    test_discover_cache_classification

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
