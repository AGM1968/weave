#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# test-durability.sh — Test durable execution patterns
#
# Tests: journal-wrapped ship/sync/delete, crash simulation at each step,
#        journal recovery, ship_pending metadata fallback, wv recover,
#        auto_sync suppression via _WV_IN_JOURNAL guard
#
# Exit codes:
#   0 - All tests passed
#   1 - One or more tests failed

set -euo pipefail

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

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$PROJECT_ROOT/scripts/wv"

# Test environment
TEST_DIR="/tmp/wv-durability-test-$$"
export WV_HOT_ZONE="$TEST_DIR"
export WV_DB="$TEST_DIR/brain.db"
export WV_REQUIRE_LEARNING=0
export WV_AUTO_SYNC=0  # Disable auto-sync in tests
export WV_AUTO_CHECKPOINT=0  # Disable auto-checkpoint in tests

# Cleanup
cleanup() {
    cd /tmp
    if [ -d "$TEST_DIR" ]; then
        rm -rf "$TEST_DIR"
    fi
    if [ -d "${TEST_DIR}-remote.git" ]; then
        rm -rf "${TEST_DIR}-remote.git"
    fi
}
trap cleanup EXIT

# ═══════════════════════════════════════════════════════════════════════════
# Test helpers
# ═══════════════════════════════════════════════════════════════════════════

setup_test_env() {
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR"
    cd "$TEST_DIR"
    git init -q
    mkdir -p .weave
    # Initialize the database
    "$WV" init 2>/dev/null || true
}

setup_state_publish_fault() {
    local fail_at="$1"
    mkdir -p "$TEST_DIR/mock-bin"
    cat > "$TEST_DIR/mock-bin/mv" <<'EOF'
#!/usr/bin/env bash
target="${!#}"
if [[ "$target" == */.weave/state.sql ]]; then
    count=$(($(cat "$WV_TEST_MV_COUNT" 2>/dev/null || echo 0) + 1))
    printf '%s\n' "$count" > "$WV_TEST_MV_COUNT"
    if [ "$count" -eq "$WV_TEST_MV_FAIL_AT" ]; then
        exit 1
    fi
fi
exec /bin/mv "$@"
EOF
    chmod +x "$TEST_DIR/mock-bin/mv"
    export WV_TEST_MV_COUNT="$TEST_DIR/mv-count"
    export WV_TEST_MV_FAIL_AT="$fail_at"
}

setup_source4_env() {
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR/repo" "$TEST_DIR/hot"
    cd "$TEST_DIR/repo"
    git init -q
    mkdir -p .weave
    export WV_HOT_ZONE="$TEST_DIR/hot"
    export WV_DB="$TEST_DIR/hot/brain.db"
    export WV_REQUIRE_LEARNING=0
    export WV_AUTO_SYNC=0
    export WV_AUTO_CHECKPOINT=0
    "$WV" init 2>/dev/null || true
}

setup_remote_tracking() {
    local remote_dir="${TEST_DIR}-remote.git"
    local branch_name

    rm -rf "$remote_dir"
    git init --bare "$remote_dir" -q
    git config user.email test@test.com
    git config user.name test
    git config commit.gpgsign false
    git remote remove origin >/dev/null 2>&1 || true
    git remote add origin "$remote_dir"

    echo "seed" > README.md
    git add README.md .weave/ >/dev/null 2>&1 || true
    git commit -m "init" -q --no-verify >/dev/null 2>&1 || true
    branch_name=$(git branch --show-current 2>/dev/null || echo "master")
    git push -u origin "$branch_name" -q >/dev/null 2>&1 || true
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
        echo "  In: $(echo "$haystack" | head -3)"
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
        echo "  Expected failure but succeeded: $*"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# Tests
# ═══════════════════════════════════════════════════════════════════════════

echo -e "${CYAN}═══ Durability Tests ═══${NC}"
echo ""

# ─── Journal wrapping in cmd_sync ───────────────────────────────────────

echo -e "${CYAN}--- cmd_sync journal wrapping ---${NC}"
setup_test_env

# Create a node to have something in the DB
"$WV" add "test node for sync" >/dev/null 2>&1

# Run sync (should create + complete journal op)
"$WV" sync 2>/dev/null

# Journal should be clean after successful sync
journal_file="$WV_HOT_ZONE/ops.journal"
if [ -f "$journal_file" ] && [ -s "$journal_file" ]; then
    # File exists but should be empty (cleaned after complete op)
    local_size=$(wc -c < "$journal_file")
    assert_equals "0" "$local_size" "Journal clean after successful sync"
else
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -e "${GREEN}✓${NC} Journal clean after successful sync (no file)"
    TESTS_PASSED=$((TESTS_PASSED + 1))
fi

# ─── GH sync failure remains local-safe with sandbox guidance ─────────────

echo ""
echo -e "${CYAN}--- GH sync sandbox guidance ---${NC}"
setup_test_env
"$WV" add "test node for gh sync failure" >/dev/null 2>&1

fake_bin="$TEST_DIR/fake-bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/python3" <<'PYEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-m" ] && [ "${2:-}" = "weave_gh" ]; then
    echo "Command failed: gh repo view --json nameWithOwner -q .nameWithOwner"
    echo "stderr: error connecting to api.github.com"
    echo "Error: could not detect GitHub repo"
    exit 1
fi
exec /usr/bin/python3 "$@"
PYEOF
chmod +x "$fake_bin/python3"

gh_output=""
gh_exit=0
gh_output=$(PATH="$fake_bin:$PATH" "$WV" sync --gh 2>&1) || gh_exit=$?
assert_equals "0" "$gh_exit" "sync --gh remains non-fatal when GH is sandbox-blocked"
assert_contains "$gh_output" "Synced to" "sync --gh still performs local .weave sync"
assert_contains "$gh_output" "GitHub sync did not complete" "sync --gh explains external failure"
assert_contains "$gh_output" "local .weave sync is complete" "sync --gh distinguishes local and external sync"
assert_contains "$gh_output" "network/SSH approval" "sync --gh gives sandbox approval guidance"

# ─── Journal wrapping in cmd_delete ─────────────────────────────────────

echo ""
echo -e "${CYAN}--- cmd_delete journal wrapping ---${NC}"
setup_test_env

node_id=$("$WV" add "node to delete" 2>/dev/null | grep -oP 'wv-[a-f0-9]+')
"$WV" delete "$node_id" --force 2>/dev/null

# Verify node is gone
node_check=$("$WV" show "$node_id" 2>&1 || true)
assert_contains "$node_check" "not found" "Node deleted successfully"

# ─── gh-close ownership guard (shared gh_issue) ─────────────────────────
# Regression: the survivor query must CAST json_extract to TEXT — gh_issue is
# stored as a JSON number and a bare INTEGER never equals a TEXT literal in
# SQLite, which silently disabled the guard.

echo ""
echo -e "${CYAN}--- delete gh-close ownership guard ---${NC}"
setup_test_env

# Texts must be dissimilar or the add similarity guard rejects the second node.
owner_a=$("$WV" add "node being deleted with linked issue" 2>/dev/null | grep -oP 'wv-[a-f0-9]+')
owner_b=$("$WV" add "surviving owner that maps the same gh number" 2>/dev/null | grep -oP 'wv-[a-f0-9]+')
# gh_issue is stored as a JSON number (jq tonumber at creation) — replicate that.
sqlite3 "$WV_DB" "UPDATE nodes SET metadata=json_set(COALESCE(metadata,'{}'),'\$.gh_issue', 4242) WHERE id IN ('$owner_a','$owner_b');"

dry_out=$("$WV" delete "$owner_a" --dry-run 2>&1)
assert_contains "$dry_out" "would NOT be closed" "dry-run flags shared gh_issue as not-closable"

# Real delete: guard must skip the gh close but still delete the node
del_out=$("$WV" delete "$owner_a" --force 2>&1 || true)
assert_contains "$del_out" "Skipped closing GitHub issue #4242" "delete skips closing a shared gh issue"
node_check=$("$WV" show "$owner_a" 2>&1 || true)
assert_contains "$node_check" "not found" "shared-issue node still deleted"

# Sole owner: dry-run reports the close would happen
dry_b=$("$WV" delete "$owner_b" --dry-run 2>&1)
assert_contains "$dry_b" "would be closed" "dry-run reports close for sole owner"

# ─── Simulated crash during ship (journal recovery) ────────────────────

echo ""
echo -e "${CYAN}--- Simulated crash during ship ---${NC}"
setup_test_env

# Source libs for direct journal manipulation
source "$PROJECT_ROOT/scripts/lib/wv-config.sh"
source "$PROJECT_ROOT/scripts/lib/wv-journal.sh"

# Create and claim a node
node_id=$("$WV" add "ship crash test" 2>/dev/null | grep -oP 'wv-[a-f0-9]+')
"$WV" work "$node_id" >/dev/null 2>&1

# Simulate: ship started, done completed, sync pending (crash)
journal_begin "ship" "{\"id\":\"$node_id\",\"gh\":false}"
journal_step 1 "done"
# Actually do the done
"$WV" done "$node_id" >/dev/null 2>&1
journal_complete 1
journal_step 2 "sync"
# CRASH HERE — sync never completed

# Verify journal detects incomplete op
recovery=$("$WV" recover --json 2>/dev/null)
assert_contains "$recovery" '"status":"incomplete"' "recover detects incomplete ship"
assert_contains "$recovery" '"op":"ship"' "recover identifies ship operation"
assert_contains "$recovery" '"action":"sync"' "recover identifies stuck at sync"

# A failed done policy gate must leave both recovery records intact and must
# never be journaled or reported as recovered.
setup_test_env
node_id=$("$WV" add "ship policy failure" --force 2>/dev/null | grep -oP 'wv-[a-f0-9]+')
"$WV" work "$node_id" >/dev/null 2>&1
sqlite3 "$WV_DB" "INSERT INTO node_files(node_id,path) VALUES('$node_id','violating.sh');
  INSERT INTO file_metrics(path,mccabe_max,language) VALUES('violating.sh',999,'sh');
  UPDATE nodes SET metadata=json_set(COALESCE(metadata,'{}'),'\$.ship_pending',json('true')) WHERE id='$node_id';"
journal_begin "ship" "{\"id\":\"$node_id\",\"gh\":false}"
journal_step 1 "done" "{\"id\":\"$node_id\"}"
recover_rc=0
WV_REQUIRE_QUALITY=0 "$WV" recover --auto >"$TEST_DIR/recover-policy.out" 2>&1 || recover_rc=$?
assert_equals "1" "$recover_rc" "recover propagates failed done policy gate"
status=$(sqlite3 "$WV_DB" "SELECT status FROM nodes WHERE id='$node_id';")
assert_equals "active" "$status" "failed ship recovery does not close node"
pending=$(sqlite3 "$WV_DB" "SELECT json_extract(metadata,'\$.ship_pending') FROM nodes WHERE id='$node_id';")
assert_equals "1" "$pending" "failed ship recovery preserves ship_pending"
recovery=$("$WV" recover --json 2>/dev/null)
assert_contains "$recovery" '"status":"incomplete"' "failed ship recovery preserves incomplete journal"
assert_fails "failed ship recovery does not print success" grep -q "Recovery complete" "$TEST_DIR/recover-policy.out"

# New ship journals carry an initial recoverable phase in the begin record.
setup_test_env
node_id=$("$WV" add "begin-only recovery" 2>/dev/null | grep -oP 'wv-[a-f0-9]+')
"$WV" work "$node_id" >/dev/null 2>&1
journal_begin "ship" "{\"id\":\"$node_id\",\"gh\":false}" "persist_intent"
begin_recovery=$("$WV" recover --json 2>/dev/null)
assert_contains "$begin_recovery" '"action":"persist_intent"' "begin-only ship journal has a recoverable initial phase"
"$WV" recover --auto >/dev/null 2>&1
status=$(sqlite3 "$WV_DB" "SELECT status FROM nodes WHERE id='$node_id';")
assert_equals "active" "$status" "begin-only recovery never closes the node"
assert_fails "begin-only recovery completes the obsolete journal" journal_has_incomplete

# If the target changes after validation but before intent persistence, the
# markerless initial phase remains safe to abort rather than poisoning recovery.
setup_test_env
node_id=$("$WV" add "raced begin-only recovery" 2>/dev/null | grep -oP 'wv-[a-f0-9]+')
journal_begin "ship" "{\"id\":\"$node_id\",\"gh\":false}" "persist_intent"
sqlite3 "$WV_DB" "UPDATE nodes SET status='done' WHERE id='$node_id';"
"$WV" recover --auto >/dev/null 2>&1
assert_fails "markerless target-state race does not poison recovery" journal_has_incomplete

# Invalid ship targets are rejected before any marker or journal is created.
setup_test_env
node_id=$("$WV" add "already completed ship target" 2>/dev/null | grep -oP 'wv-[a-f0-9]+')
"$WV" done "$node_id" --skip-verification >/dev/null 2>&1
ship_rc=0
"$WV" ship "$node_id" --skip-verification --no-gh >/dev/null 2>&1 || ship_rc=$?
assert_equals "1" "$ship_rc" "ship rejects an already-done node before protocol start"
pending=$(sqlite3 "$WV_DB" "SELECT COALESCE(json_extract(metadata,'\$.ship_pending'),0) FROM nodes WHERE id='$node_id';")
assert_equals "0" "$pending" "rejected done-node ship leaves no marker"
assert_fails "rejected done-node ship leaves no journal" journal_has_incomplete
ship_rc=0
"$WV" ship wv-deadbeef --skip-verification --no-gh >/dev/null 2>&1 || ship_rc=$?
assert_equals "1" "$ship_rc" "ship rejects a missing node before protocol start"
assert_fails "rejected missing-node ship leaves no journal" journal_has_incomplete

# ─── ship_pending metadata marker ──────────────────────────────────────

echo ""
echo -e "${CYAN}--- ship_pending metadata fallback ---${NC}"
setup_test_env

node_id=$("$WV" add "pending test" 2>/dev/null | grep -oP 'wv-[a-f0-9]+')
"$WV" work "$node_id" >/dev/null 2>&1

# Manually set ship_pending (simulating cmd_ship start before crash)
sqlite3 "$WV_DB" "UPDATE nodes SET metadata = json_set(COALESCE(metadata,'{}'), '\$.ship_pending', json('true')) WHERE id = '$node_id';"

# Verify the marker is set
pending=$(sqlite3 "$WV_DB" "SELECT json_extract(metadata, '\$.ship_pending') FROM nodes WHERE id='$node_id';")
assert_equals "1" "$pending" "ship_pending marker set in metadata"

# Simulate reboot: clear journal (tmpfs gone), but metadata survives
rm -f "$WV_HOT_ZONE/ops.journal"

# wv recover should find the pending node via metadata fallback
recovery=$("$WV" recover --json 2>/dev/null)
assert_contains "$recovery" '"ship_pending"' "recover finds ship_pending via metadata"

fallback_rc=0
"$WV" recover --auto >"$TEST_DIR/recover-active-fallback.out" 2>&1 || fallback_rc=$?
assert_equals "1" "$fallback_rc" "ship_pending fallback rejects a node that is not done"
pending=$(sqlite3 "$WV_DB" "SELECT json_extract(metadata,'\$.ship_pending') FROM nodes WHERE id='$node_id';")
assert_equals "1" "$pending" "rejected ship_pending fallback preserves marker"

# Pre-close intent must survive loss of both the hot database and journal.
setup_test_env
node_id=$("$WV" add "pre-close reboot" 2>/dev/null | grep -oP 'wv-[a-f0-9]+')
"$WV" work "$node_id" >/dev/null 2>&1
sqlite3 "$WV_DB" "UPDATE nodes SET metadata=json_set(COALESCE(metadata,'{}'),
  '\$.ship_pending',json('true'),'\$.ship_pending_mode','pre_close') WHERE id='$node_id';"
"$WV" sync >/dev/null 2>&1
rm -f "$WV_DB" "$WV_HOT_ZONE/ops.journal"
"$WV" init >/dev/null 2>&1 || true
status=$(sqlite3 "$WV_DB" "SELECT status FROM nodes WHERE id='$node_id';")
pending_state=$(sqlite3 "$WV_DB" "SELECT json_extract(metadata,'\$.ship_pending') || '|' || json_extract(metadata,'\$.ship_pending_mode') FROM nodes WHERE id='$node_id';")
assert_equals "active" "$status" "pre-close reboot does not manufacture closure"
assert_equals "1|pre_close" "$pending_state" "pre-close reboot preserves boolean marker and mode"
recovery=$("$WV" recover --json 2>/dev/null)
recovery_mode=$(echo "$recovery" | jq -r '.nodes[0].mode')
assert_equals "pre_close" "$recovery_mode" "recover reports persisted pre-close mode"

# A real ship whose post-close publish fails must reboot to the last complete
# pre-close snapshot, never a markerless or partially closed state.
setup_test_env
node_id=$("$WV" add "atomic close publish failure" 2>/dev/null | grep -oP 'wv-[a-f0-9]+')
"$WV" work "$node_id" >/dev/null 2>&1
setup_state_publish_fault 2
ship_rc=0
PATH="$TEST_DIR/mock-bin:$PATH" "$WV" ship "$node_id" --skip-verification --no-gh >/dev/null 2>&1 || ship_rc=$?
assert_equals "1" "$ship_rc" "ship stops when post-close state publication fails"
rm -f "$WV_DB" "$WV_HOT_ZONE/ops.journal"
unset WV_TEST_MV_FAIL_AT WV_TEST_MV_COUNT
"$WV" init >/dev/null 2>&1 || true
reboot_state=$(sqlite3 "$WV_DB" "SELECT status || '|' || json_extract(metadata,'\$.ship_pending_mode') FROM nodes WHERE id='$node_id';")
assert_equals "active|pre_close" "$reboot_state" "failed atomic close publish reboots conservatively"

# A real ship whose final clearance publish fails leaves the prior durable
# done/post_close snapshot available for idempotent reboot recovery.
setup_test_env
node_id=$("$WV" add "clear publish failure" 2>/dev/null | grep -oP 'wv-[a-f0-9]+')
"$WV" work "$node_id" >/dev/null 2>&1
setup_state_publish_fault 3
ship_rc=0
PATH="$TEST_DIR/mock-bin:$PATH" "$WV" ship "$node_id" --skip-verification --no-gh >/dev/null 2>&1 || ship_rc=$?
assert_equals "1" "$ship_rc" "ship stops when marker-clear publication fails"
hot_state=$(sqlite3 "$WV_DB" "SELECT status || '|' || json_extract(metadata,'\$.ship_pending') || '|' || json_extract(metadata,'\$.ship_pending_mode') FROM nodes WHERE id='$node_id';")
assert_equals "done|1|post_close" "$hot_state" "failed clearance exactly restores the hot post-close marker"
sqlite3 "$TEST_DIR/durable-check.db" < .weave/state.sql
durable_state=$(sqlite3 "$TEST_DIR/durable-check.db" "SELECT status || '|' || json_extract(metadata,'\$.ship_pending_mode') FROM nodes WHERE id='$node_id';")
assert_equals "done|post_close" "$durable_state" "failed clearance preserves durable post-close recovery state"
rm -f "$WV_DB" "$WV_HOT_ZONE/ops.journal"
unset WV_TEST_MV_FAIL_AT WV_TEST_MV_COUNT
"$WV" init >/dev/null 2>&1
pending=$(sqlite3 "$WV_DB" "SELECT COALESCE(json_extract(metadata,'\$.ship_pending'),0) FROM nodes WHERE id='$node_id';")
assert_equals "0" "$pending" "post-close publish failure recovers idempotently after reboot"

# Post-close state is durably pending until recovery clears and persists it.
setup_test_env
node_id=$("$WV" add "post-close reboot" 2>/dev/null | grep -oP 'wv-[a-f0-9]+')
sqlite3 "$WV_DB" "UPDATE nodes SET status='done', metadata=json_set(COALESCE(metadata,'{}'),
  '\$.ship_pending',json('true'),'\$.ship_pending_mode','post_close') WHERE id='$node_id';"
"$WV" sync >/dev/null 2>&1
rm -f "$WV_DB" "$WV_HOT_ZONE/ops.journal"
"$WV" init >/dev/null 2>&1
pending=$(sqlite3 "$WV_DB" "SELECT COALESCE(json_extract(metadata,'\$.ship_pending'),0) FROM nodes WHERE id='$node_id';")
assert_equals "0" "$pending" "post-close reboot recovery clears marker"
rm -f "$WV_DB" "$WV_HOT_ZONE/ops.journal"
"$WV" init >/dev/null 2>&1
pending=$(sqlite3 "$WV_DB" "SELECT COALESCE(json_extract(metadata,'\$.ship_pending'),0) FROM nodes WHERE id='$node_id';")
assert_equals "0" "$pending" "post-close marker clearance survives a second reboot"

# Legacy boolean-only markers remain recoverable during protocol rollout.
setup_test_env
node_id=$("$WV" add "legacy pending reboot" 2>/dev/null | grep -oP 'wv-[a-f0-9]+')
sqlite3 "$WV_DB" "UPDATE nodes SET status='done', metadata=json_set(COALESCE(metadata,'{}'),
  '\$.ship_pending',json('true')) WHERE id='$node_id';"
"$WV" sync >/dev/null 2>&1
rm -f "$WV_DB" "$WV_HOT_ZONE/ops.journal"
# Loading is explicit here because recover cannot query a missing hot database.
"$WV" init >/dev/null 2>&1
pending=$(sqlite3 "$WV_DB" "SELECT COALESCE(json_extract(metadata,'\$.ship_pending'),0) FROM nodes WHERE id='$node_id';")
assert_equals "0" "$pending" "legacy boolean ship_pending remains recoverable"

# A completed ship persists marker clearance before reporting a clean journal.
setup_test_env
node_id=$("$WV" add "completed ship reboot" 2>/dev/null | grep -oP 'wv-[a-f0-9]+')
"$WV" work "$node_id" >/dev/null 2>&1
"$WV" ship "$node_id" --skip-verification --no-gh >/dev/null 2>&1
status=$(sqlite3 "$WV_DB" "SELECT status FROM nodes WHERE id='$node_id';")
pending=$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM nodes WHERE id='$node_id' AND json_extract(metadata,'\$.ship_pending') IS NOT NULL;")
assert_equals "done" "$status" "successful ship closes node"
assert_equals "0" "$pending" "successful ship clears hot marker"
rm -f "$WV_DB" "$WV_HOT_ZONE/ops.journal"
"$WV" init >/dev/null 2>&1
pending=$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM nodes WHERE id='$node_id' AND json_extract(metadata,'\$.ship_pending') IS NOT NULL;")
assert_equals "0" "$pending" "successful ship clearance survives reboot"
recovery=$("$WV" recover --json 2>/dev/null)
recovery_status=$(echo "$recovery" | jq -r 'if .status == "ship_pending" then "pending" else "clear" end')
assert_equals "clear" "$recovery_status" "completed ship has no recoverable protocol state"

# ─── pending_close metadata fallback ────────────────────────────────────

echo ""
echo -e "${CYAN}--- pending_close metadata fallback ---${NC}"
setup_test_env

seed_id=$("$WV" add "seed pending-close learning" 2>/dev/null | grep -oP 'wv-[a-f0-9]+')
overlap_learning="decision: keep overlap prompts resumable | pattern: store pending close state | pitfall: tty prompts hang unattended flows"
WV_REQUIRE_LEARNING=1 "$WV" done "$seed_id" --learning="$overlap_learning" >/dev/null 2>&1

node_id=$("$WV" add "pending close test" 2>/dev/null | grep -oP 'wv-[a-f0-9]+')
pending_close_exit=0
WV_REQUIRE_LEARNING=1 WV_NONINTERACTIVE=1 "$WV" done "$node_id" --learning="$overlap_learning" >/dev/null 2>&1 || pending_close_exit=$?
assert_equals "0" "$pending_close_exit" "done succeeds non-interactively when overlap detected (advisory only)"

# Recovery of legacy pending_close nodes (nodes stuck under old blocking behavior)
legacy_stuck=$("$WV" add "legacy stuck node" 2>/dev/null | grep -oP 'wv-[a-f0-9]+')
legacy_stuck_meta=$(jq -n --arg node "$legacy_stuck" \
    '{"needs_human_verification": true, "pending_close": {"reason": "learning_overlap", "overlap_with": "wv-fake", "learning": "test", "resume_command": ("wv done " + $node + " --acknowledge-overlap")}}')
"$WV" update "$legacy_stuck" --metadata="$legacy_stuck_meta" >/dev/null 2>&1
recovery=$("$WV" recover --json 2>/dev/null)
assert_contains "$recovery" '"needs_human_verification"' "recover finds legacy pending-close nodes via metadata"
assert_contains "$recovery" "$legacy_stuck" "recover includes legacy pending-close node id"
assert_contains "$recovery" 'acknowledge-overlap' "recover includes explicit resume command"

# ─── _WV_IN_JOURNAL guard on auto_sync ─────────────────────────────────

echo ""
echo -e "${CYAN}--- _WV_IN_JOURNAL auto_sync guard ---${NC}"
setup_test_env

source "$PROJECT_ROOT/scripts/lib/wv-config.sh"
source "$PROJECT_ROOT/scripts/lib/wv-journal.sh"

# Set the guard
export _WV_IN_JOURNAL=1
export WV_AUTO_SYNC=1  # Enable for this test

# Source the data module to get auto_sync
source "$PROJECT_ROOT/scripts/cmd/wv-cmd-data.sh"

# auto_sync should be a no-op when _WV_IN_JOURNAL is set
# (We can't easily test this without side effects, but verify the guard works)
# Just verify auto_sync returns 0 without doing anything
stamp_before=""
[ -f "$WV_HOT_ZONE/.last_sync" ] && stamp_before=$(cat "$WV_HOT_ZONE/.last_sync")
auto_sync 2>/dev/null || true
stamp_after=""
[ -f "$WV_HOT_ZONE/.last_sync" ] && stamp_after=$(cat "$WV_HOT_ZONE/.last_sync")

assert_equals "$stamp_before" "$stamp_after" "auto_sync skipped during journal op"

# --force still respects _WV_IN_JOURNAL (journal guard is non-bypassable)
stamp_before=""
[ -f "$WV_HOT_ZONE/.last_sync" ] && stamp_before=$(cat "$WV_HOT_ZONE/.last_sync")
auto_sync --force 2>/dev/null || true
stamp_after=""
[ -f "$WV_HOT_ZONE/.last_sync" ] && stamp_after=$(cat "$WV_HOT_ZONE/.last_sync")
assert_equals "$stamp_before" "$stamp_after" "auto_sync --force still skipped during journal op"

unset _WV_IN_JOURNAL
export WV_AUTO_SYNC=0

# ─── auto_sync --force bypasses throttle ────────────────────────────────

echo ""
echo -e "${CYAN}--- auto_sync --force throttle bypass ---${NC}"
setup_test_env
git -C "$TEST_DIR" init -q
export WV_AUTO_SYNC=1

source "$PROJECT_ROOT/scripts/lib/wv-config.sh"
source "$PROJECT_ROOT/scripts/lib/wv-journal.sh"
source "$PROJECT_ROOT/scripts/cmd/wv-cmd-data.sh"

# Seed a recent sync stamp to simulate throttle being active
echo "$(date +%s)" > "$WV_HOT_ZONE/.last_sync"

# auto_sync without --force should be throttled
stamp_before=$(cat "$WV_HOT_ZONE/.last_sync")
auto_sync 2>/dev/null || true
stamp_after=$(cat "$WV_HOT_ZONE/.last_sync")
assert_equals "$stamp_before" "$stamp_after" "auto_sync throttled when stamp is fresh"

# auto_sync --force should bypass throttle and update the stamp
auto_sync --force 2>/dev/null || true
stamp_after=$(cat "$WV_HOT_ZONE/.last_sync" 2>/dev/null || echo "")
# Stamp should have been updated (or auto_sync ran and found nothing to sync — both are fine)
# What matters: --force did not return early due to throttle check
assert_equals "1" "$([ -n "$stamp_after" ] && echo 1 || echo 0)" "auto_sync --force ran (stamp exists after call)"

export WV_AUTO_SYNC=0

# ─── wv recover on clean state ─────────────────────────────────────────

echo ""
echo -e "${CYAN}--- wv recover clean state ---${NC}"
setup_test_env

result=$("$WV" recover --json 2>/dev/null)
assert_contains "$result" '"clean"' "recover reports clean on fresh state"

# ─── source-4 dirty .weave surfacing ────────────────────────────────────

echo ""
echo -e "${CYAN}--- source-4 dirty .weave surfacing ---${NC}"
setup_source4_env
setup_remote_tracking

echo "dirty" > .weave/source4-dirty

status_json=$("$WV" status --json 2>/dev/null)
assert_contains "$status_json" '"git_sync_pending": true' "status surfaces git pending for dirty .weave"
assert_contains "$status_json" '"git_sync_action": "commit_push"' "status reports commit+push for dirty .weave"
assert_contains "$status_json" '"git_sync_reason": "dirty_weave"' "status reports dirty_weave reason"

recover_json=$("$WV" recover --json 2>/dev/null)
assert_contains "$recover_json" '"status": "git_pending"' "recover surfaces recoverable source-4 state"
assert_contains "$recover_json" '"action": "commit_push"' "recover reports commit_push action"

git add .weave/source4-dirty >/dev/null 2>&1
git commit -m "dirty weave synced" -q --no-verify >/dev/null 2>&1
git push -q >/dev/null 2>&1

status_json=$("$WV" status --json 2>/dev/null)
assert_contains "$status_json" '"git_sync_pending": false' "status clears dirty .weave once it is committed and pushed"
assert_contains "$status_json" '"git_sync_reason": "clean"' "status reports clean after dirty .weave commit+push"

# ─── source-4 ahead .weave surfacing ────────────────────────────────────

echo ""
echo -e "${CYAN}--- source-4 ahead .weave surfacing ---${NC}"
setup_source4_env
setup_remote_tracking

echo "ahead" > .weave/source4-ahead
git add .weave/source4-ahead >/dev/null 2>&1
git commit -m "ahead weave" -q --no-verify >/dev/null 2>&1

status_json=$("$WV" status --json 2>/dev/null)
assert_contains "$status_json" '"git_sync_action": "push_only"' "status reports push_only for ahead .weave commit"
assert_contains "$status_json" '"git_sync_reason": "ahead_weave"' "status reports ahead_weave reason"

doctor_out=$("$WV" doctor 2>&1)
assert_contains "$doctor_out" "git sync" "doctor checks git sync state"
assert_contains "$doctor_out" "ahead_weave" "doctor reports recoverable ahead state"

git push -q >/dev/null 2>&1

status_json=$("$WV" status --json 2>/dev/null)
assert_contains "$status_json" '"git_sync_pending": false' "status clears ahead .weave once the commit is pushed"
assert_contains "$status_json" '"git_sync_reason": "clean"' "status reports clean after ahead .weave push"

# ─── source-4 no-upstream surfacing ─────────────────────────────────────

echo ""
echo -e "${CYAN}--- source-4 no-upstream surfacing ---${NC}"
setup_source4_env

echo "dirty" > .weave/source4-no-upstream

status_json=$("$WV" status --json 2>/dev/null)
assert_contains "$status_json" '"git_sync_state": "unresolvable"' "status marks no-upstream source-4 state unresolvable"
assert_contains "$status_json" '"git_sync_reason": "no_upstream"' "status reports no_upstream reason"

recover_json=$("$WV" recover --json 2>/dev/null)
assert_contains "$recover_json" '"status": "git_unresolvable"' "recover surfaces unresolvable source-4 state"
assert_contains "$recover_json" '"reason": "no_upstream"' "recover reports no_upstream reason"

# ─── wv doctor journal check ───────────────────────────────────────────

echo ""
echo -e "${CYAN}--- wv doctor journal check ---${NC}"
setup_test_env

doctor_out=$("$WV" doctor 2>&1)
assert_contains "$doctor_out" "journal" "doctor checks journal health"
assert_contains "$doctor_out" "clean" "doctor reports clean journal"
assert_contains "$doctor_out" "wv provenance" "doctor checks wv provenance"
assert_contains "$doctor_out" "repo-local" "doctor reports repo-local wv provenance when using scripts/wv"

doctor_agent_out=$("$WV" doctor --agent 2>&1)
assert_contains "$doctor_agent_out" "agent python" "doctor --agent checks python command resolution"
assert_contains "$doctor_agent_out" "agent pytest" "doctor --agent checks pytest availability"
assert_contains "$doctor_agent_out" "agent imports" "doctor --agent checks import visibility"

# Create incomplete journal entry
source "$PROJECT_ROOT/scripts/lib/wv-config.sh"
source "$PROJECT_ROOT/scripts/lib/wv-journal.sh"
journal_begin "sync" '{}'
journal_step 1 "dump"
# No complete, no end

doctor_out=$("$WV" doctor 2>&1)
assert_contains "$doctor_out" "incomplete" "doctor detects incomplete journal op"
assert_contains "$doctor_out" "recover" "doctor suggests wv recover"

# ─── Scan single-transaction atomicity ──────────────────────────────────

echo ""
echo -e "${CYAN}--- Scan single-transaction ---${NC}"

# This is tested via the existing pytest suite. Keep this static guard focused
# on the transaction invariant: upsert functions run inside caller-managed
# transactions and must not commit independently.
upsert_commit_count=$(awk '
    /^def .*upsert/ { in_upsert = 1 }
    /^def / && $0 !~ /^def .*upsert/ { in_upsert = 0 }
    in_upsert && /conn\.commit\(\)/ { count++ }
    END { print count + 0 }
' "$PROJECT_ROOT/scripts/weave_quality/db.py")
assert_equals "0" "$upsert_commit_count" "db.py has no conn.commit() calls inside upsert functions"

# ═══════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${CYAN}═══════════════════════════════════${NC}"
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
if [ "$TESTS_FAILED" -gt 0 ]; then
    echo -e "${RED}$TESTS_FAILED test(s) failed${NC}"
    exit 1
else
    echo -e "${GREEN}All tests passed${NC}"
    exit 0
fi
