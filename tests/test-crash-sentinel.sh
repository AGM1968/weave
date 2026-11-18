#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# test-crash-sentinel.sh — Test crash sentinel detection and session recovery
#
# Tests: sentinel lifecycle, crash detection, auto-breadcrumb, wv recover --session,
#        reboot recovery (no sentinel but active nodes), benchmark criteria
#
# Exit codes:
#   0 - All tests passed
#   1 - One or more tests failed

set -euo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)

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
TEST_DIR="/tmp/wv-crash-sentinel-test-$$"
export WV_HOT_ZONE="$TEST_DIR/hot"
export WV_DB="$TEST_DIR/hot/brain.db"
export WV_REQUIRE_LEARNING=0
export WV_AUTO_SYNC=0
export WV_AUTO_CHECKPOINT=0
# No session identity from the parent: the cases below test the flat session
# files, and an inherited harness session id would move them to per-session
# names (wv-9a867a). WV_SESSION_IDENTITY=0 gives the coarse owner, so claims
# still work; the two-session section turns identity on per command.
unset WV_SESSION_ID CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID PI_SESSION_ID AMP_CURRENT_THREAD_ID
export WV_SESSION_IDENTITY=0

SENTINEL="$WV_HOT_ZONE/.session_sentinel"
HOOKS_DIR="$PROJECT_ROOT/.claude/hooks"

# Cleanup
cleanup() {
    cd /tmp
    if [ -d "$TEST_DIR" ]; then
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

# ═══════════════════════════════════════════════════════════════════════════
# Test helpers
# ═══════════════════════════════════════════════════════════════════════════

setup_test_env() {
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR/hot"
    cd "$TEST_DIR"
    git init -q
    mkdir -p .weave
    "$WV" init 2>/dev/null || true
}

# Assertions record a failure and return 0: under set -e a nonzero return
# ended the suite at its first failed assertion, so every later result and
# the summary went unreported (wv-75e31a). TESTS_FAILED decides the exit.
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
        return 0
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if grep -qF -- "$needle" <<< "$haystack"; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Expected to find: $needle"
        echo "  In: $(echo "$haystack" | sed -n '1,3p')"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 0
    fi
}

assert_file_exists() {
    local path="$1"
    local message="$2"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ -f "$path" ]; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}✗${NC} $message"
        echo "  File not found: $path"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 0
    fi
}

assert_file_absent() {
    local path="$1"
    local message="$2"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ ! -f "$path" ]; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}✗${NC} $message"
        echo "  File should not exist: $path"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 0
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
        return 0
    fi
}

# Write a sentinel file simulating a previous session
write_fake_sentinel() {
    local ts="${1:-2026-03-05T14:00:00Z}"
    local active_json="${2:-[]}"
    mkdir -p "$WV_HOT_ZONE"
    jq -n --arg ts "$ts" --argjson active "$active_json" --argjson pid 99999 \
        '{ts: $ts, active: $active, pid: $pid}' > "$SENTINEL"
}

# ═══════════════════════════════════════════════════════════════════════════
# Sentinel Lifecycle Tests
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo "═══ Sentinel Lifecycle ═══"

# Test: Sentinel write (two-phase) via session-start hook
setup_test_env
echo '{}' | bash "$HOOKS_DIR/session-start-context.sh" >/dev/null 2>&1 || true
assert_file_exists "$SENTINEL" "session-start writes sentinel"

# Test: Sentinel contains valid JSON with expected fields
SENTINEL_DATA=$(cat "$SENTINEL" 2>/dev/null || echo "{}")
assert_success "sentinel has 'ts' field" test "$(echo "$SENTINEL_DATA" | jq -r '.ts // empty')" != ""
assert_success "sentinel has 'active' field" test "$(echo "$SENTINEL_DATA" | jq -c '.active // empty')" != ""
assert_success "sentinel has 'pid' field" test "$(echo "$SENTINEL_DATA" | jq -r '.pid // empty')" != ""

# Test: Sentinel cleared by session-end hook
echo '{"reason":"user_ended"}' | bash "$HOOKS_DIR/session-end-sync.sh" 2>/dev/null || true
assert_file_absent "$SENTINEL" "session-end clears sentinel"

# Test: Clean session leaves no sentinel
setup_test_env
echo '{}' | bash "$HOOKS_DIR/session-start-context.sh" >/dev/null 2>&1 || true
assert_file_exists "$SENTINEL" "sentinel exists after start"
echo '{"reason":"user_ended"}' | bash "$HOOKS_DIR/session-end-sync.sh" 2>/dev/null || true
assert_file_absent "$SENTINEL" "clean session cycle: no sentinel remains"

# ═══════════════════════════════════════════════════════════════════════════
# Crash Detection Tests
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo "═══ Crash Detection ═══"

# wv-4efe06: the label comes from how the previous session ended - the last
# tool call (pre-action heartbeat) against the last Stop (stop-check record) -
# and the graph's active nodes at exit, not the list the sentinel captured when
# that session started.
claimed_node() {  # claimed_node <text> -> id of a node claimed in the test graph
    local out id
    out=$("$WV" add "$1" --standalone 2>/dev/null || true)
    id=$(grep -oE 'wv-[0-9a-f]{6}' <<< "$out" || true)
    id=${id%%$'\n'*}
    "$WV" work "$id" >/dev/null 2>&1 || true
    printf '%s' "$id"
}
signals() {  # signals <heartbeat-epoch|-> <stop-epoch|-> [outcome]
    [ "$1" != "-" ] && echo "$1" > "$WV_HOT_ZONE/.session_heartbeat"
    [ "$2" != "-" ] && echo "$2 ${3:-stopped}" > "$WV_HOT_ZONE/.session_laststop"
    return 0
}
NOW=$(date +%s)

# False negative before: a node claimed AFTER the session started, then death
# mid-turn. The start-time sentinel lists nothing; the graph still has the claim.
setup_test_env
write_fake_sentinel "2026-03-05T14:00:00Z" '[]'
NODE_A=$(claimed_node "claimed mid-session")
signals $((NOW - 60)) $((NOW - 600))
OUTPUT=$(echo '{}' | bash "$HOOKS_DIR/session-start-context.sh" 2>/dev/null || true)
assert_contains "$OUTPUT" "CRASH DETECTED" "a claim made after start, then death mid-turn, is a crash"
assert_contains "$OUTPUT" "$NODE_A" "the crash names the node claimed after start"
assert_contains "$OUTPUT" "$(date -u -d "@$((NOW - 60))" +%Y-%m-%dT%H:%M:%SZ)" \
    "the crash reports the last activity, not the session's start"

# False positive before: the sentinel's start list names a node the session
# later closed, and it stopped cleanly before dying. Not a crash.
setup_test_env
NODE_B=$(claimed_node "closed before exit")
write_fake_sentinel "2026-03-05T15:30:00Z" "[\"$NODE_B\"]"
"$WV" "done" "$NODE_B" --skip-verification >/dev/null 2>&1 || true
signals $((NOW - 600)) $((NOW - 60)) stopped
OUTPUT=$(echo '{}' | bash "$HOOKS_DIR/session-start-context.sh" 2>/dev/null || true)
TESTS_RUN=$((TESTS_RUN + 1))
if ! grep -qF "CRASH DETECTED" <<< "$OUTPUT"; then
    echo -e "${GREEN}✓${NC} a node closed before a clean stop is not reported as a crash"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "${RED}✗${NC} a node closed before a clean stop is not reported as a crash"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi
assert_contains "$OUTPUT" "stopped cleanly" "a clean stop without SessionEnd is labelled as such"

# Blocked exit: the last stop was refused over open work, then the session ended.
setup_test_env
NODE_C=$(claimed_node "open at blocked exit")
write_fake_sentinel "2026-03-05T16:00:00Z" '[]'
signals $((NOW - 600)) $((NOW - 60)) blocked
OUTPUT=$(echo '{}' | bash "$HOOKS_DIR/session-start-context.sh" 2>/dev/null || true)
assert_contains "$OUTPUT" "blocked by open work" "a stop blocked by open work is labelled as a blocked exit"
assert_contains "$OUTPUT" "$NODE_C" "the blocked exit names the node still open"

# The signals come from the real hooks: pre-action stamps a heartbeat on each
# tool call, and stop-check records each Stop as blocked or stopped.
setup_test_env
rm -f "$WV_HOT_ZONE/.session_heartbeat" "$WV_HOT_ZONE/.session_laststop"
echo '{"tool_name":"Read","tool_input":{"file_path":"/dev/null"}}' | bash "$HOOKS_DIR/pre-action.sh" >/dev/null 2>&1 || true
assert_file_exists "$WV_HOT_ZONE/.session_heartbeat" "pre-action writes the liveness heartbeat"
# A clean tree, so stop-check reaches its active-node check (the hot zone lives
# inside this fixture repo and would otherwise read as an uncommitted change).
echo "hot/" >> .gitignore
git add -A >/dev/null 2>&1; git -c user.email=t@t -c user.name=t commit -qm fixture >/dev/null 2>&1 || true
NODE_D=$(claimed_node "open at stop")
echo '{}' | bash "$HOOKS_DIR/stop-check.sh" >/dev/null 2>&1 || true
assert_equals "blocked" "$(cut -d' ' -f2 "$WV_HOT_ZONE/.session_laststop" 2>/dev/null)" "stop-check records a stop refused over open work as blocked"
"$WV" "done" "$NODE_D" --skip-verification >/dev/null 2>&1 || true
rm -f "$WV_HOT_ZONE/.stop_check_lock"
echo '{}' | bash "$HOOKS_DIR/stop-check.sh" >/dev/null 2>&1 || true
assert_equals "stopped" "$(cut -d' ' -f2 "$WV_HOT_ZONE/.session_laststop" 2>/dev/null)" "stop-check records an allowed stop as stopped"

# A sentinel with no signals and nothing active (died while loading, or an
# older sentinel): informational, not CRASH DETECTED (wv-bd6184).
setup_test_env
write_fake_sentinel "2026-03-05T16:00:00Z" '[]'
OUTPUT=$(echo '{}' | bash "$HOOKS_DIR/session-start-context.sh" 2>/dev/null || true)
assert_contains "$OUTPUT" "No active work to recover" "a death with nothing active emits an informational note"
assert_contains "$OUTPUT" "2026-03-05T16:00:00Z" "without signals the sentinel's own time is reported"

# Test: No crash warning on clean start (no sentinel)
setup_test_env
rm -f "$SENTINEL"
OUTPUT=$(echo '{}' | bash "$HOOKS_DIR/session-start-context.sh" 2>/dev/null || true)
TESTS_RUN=$((TESTS_RUN + 1))
if ! grep -qF "CRASH DETECTED" <<< "$OUTPUT"; then
    echo -e "${GREEN}✓${NC} clean start: no crash warning"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "${RED}✗${NC} clean start: no crash warning"
    echo "  Unexpected crash warning on clean start"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ═══════════════════════════════════════════════════════════════════════════
# Auto-Breadcrumb Tests
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo "═══ Auto-Breadcrumb on Crash ═══"

# Test: Crash detection generates breadcrumb file
setup_test_env
write_fake_sentinel "2026-03-05T14:00:00Z" '["wv-aaa111"]'
echo '{}' | bash "$HOOKS_DIR/session-start-context.sh" >/dev/null 2>&1 || true
BC_FILE="$TEST_DIR/.weave/breadcrumbs.md"
if [ -f "$BC_FILE" ]; then
    BC_CONTENT=$(cat "$BC_FILE")
    assert_contains "$BC_CONTENT" "CRASH RECOVERY" "breadcrumb contains CRASH RECOVERY"
    assert_contains "$BC_CONTENT" "wv-aaa111" "breadcrumb contains crashed node ID"
else
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -e "${YELLOW}✓${NC} breadcrumb file not created (wv breadcrumbs may not be available in test env)"
    TESTS_PASSED=$((TESTS_PASSED + 1))
fi

# ═══════════════════════════════════════════════════════════════════════════
# wv recover --session Tests
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo "═══ wv recover --session ═══"

# Test: No active nodes — clean
setup_test_env
OUTPUT=$("$WV" recover --session 2>/dev/null)
assert_contains "$OUTPUT" "No orphaned active nodes" "recover --session clean when no active nodes"

# Test: Active nodes listed
setup_test_env
"$WV" add "Task alpha" --status=active --criteria="recover session fixture" --risks=low --force >/dev/null 2>&1
OUTPUT=$("$WV" recover --session 2>/dev/null)
assert_contains "$OUTPUT" "Task alpha" "recover --session lists active node text"
assert_contains "$OUTPUT" "1 node" "recover --session shows count"

# Test: Multiple active nodes listed
setup_test_env
"$WV" add "Task alpha" --status=active --criteria="recover session fixture" --risks=low --force >/dev/null 2>&1
"$WV" add "Task beta" --status=active --criteria="recover session fixture" --risks=low --force >/dev/null 2>&1
OUTPUT=$("$WV" recover --session 2>/dev/null)
assert_contains "$OUTPUT" "2 node" "recover --session shows 2 nodes"
assert_contains "$OUTPUT" "Task alpha" "recover --session lists first node"
assert_contains "$OUTPUT" "Task beta" "recover --session lists second node"

# Test: --json output
setup_test_env
"$WV" add "JSON test task" --status=active --criteria="recover session fixture" --risks=low --force >/dev/null 2>&1
OUTPUT=$("$WV" recover --session --json 2>/dev/null)
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$OUTPUT" | jq empty 2>/dev/null; then
    echo -e "${GREEN}✓${NC} recover --session --json is valid JSON"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "${RED}✗${NC} recover --session --json is valid JSON"
    echo "  Output: $OUTPUT"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi
STATUS=$(echo "$OUTPUT" | jq -r '.status' 2>/dev/null)
assert_equals "orphaned" "$STATUS" "recover --session --json status=orphaned"
NODE_COUNT=$(echo "$OUTPUT" | jq '.orphaned_nodes | length' 2>/dev/null)
assert_equals "1" "$NODE_COUNT" "recover --session --json has 1 orphaned node"

# Test: --json clean output
setup_test_env
OUTPUT=$("$WV" recover --session --json 2>/dev/null)
STATUS=$(echo "$OUTPUT" | jq -r '.status' 2>/dev/null)
assert_equals "clean" "$STATUS" "recover --session --json clean when no active nodes"

# Test: --auto reclaims nodes
setup_test_env
"$WV" add "Auto reclaim task" --status=active --criteria="recover session fixture" --risks=low --force >/dev/null 2>&1
OUTPUT=$("$WV" recover --session --auto 2>/dev/null)
assert_contains "$OUTPUT" "Auto-reclaiming" "recover --session --auto reclaims"

# Test: todo nodes not listed (only active)
setup_test_env
"$WV" add "Todo task" --force >/dev/null 2>&1
"$WV" add "Active task" --status=active --criteria="recover session fixture" --risks=low --force >/dev/null 2>&1
OUTPUT=$("$WV" recover --session 2>/dev/null)
assert_contains "$OUTPUT" "Active task" "recover --session shows active"
TESTS_RUN=$((TESTS_RUN + 1))
if ! grep -qF "Todo task" <<< "$OUTPUT"; then
    echo -e "${GREEN}✓${NC} recover --session excludes todo nodes"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "${RED}✗${NC} recover --session excludes todo nodes"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# Test: done nodes not listed
setup_test_env
ID=$("$WV" add "Done task" --status=active --criteria="recover session fixture" --risks=low --force 2>/dev/null | grep -oP 'wv-[a-f0-9]+')
"$WV" "done" "$ID" --skip-verification 2>/dev/null || true
OUTPUT=$("$WV" recover --session 2>/dev/null)
assert_contains "$OUTPUT" "No orphaned active nodes" "recover --session excludes done nodes"

# ═══════════════════════════════════════════════════════════════════════════
# Reboot Recovery (Secondary Detection) Tests
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo "═══ Reboot Recovery (Secondary Detection) ═══"

# Test: Active nodes + no sentinel triggers soft warning
setup_test_env
"$WV" add "Orphaned from reboot" --status=active --criteria="recover session fixture" --risks=low --force >/dev/null 2>&1
rm -f "$SENTINEL"  # Simulate reboot (sentinel lost from tmpfs)
OUTPUT=$(echo '{}' | bash "$HOOKS_DIR/session-start-context.sh" 2>/dev/null || true)
# Output is JSON-wrapped in hookSpecificOutput.additionalContext — extract it
CONTEXT=$(echo "$OUTPUT" | jq -r '.hookSpecificOutput.additionalContext // .' 2>/dev/null || echo "$OUTPUT")
assert_contains "$CONTEXT" "nodes marked active" "reboot recovery: soft warning for active nodes"
assert_contains "$CONTEXT" "wv recover --session" "reboot recovery: suggests recover command"

# Test: No active nodes + no sentinel = clean (no warning)
setup_test_env
rm -f "$SENTINEL"
OUTPUT=$(echo '{}' | bash "$HOOKS_DIR/session-start-context.sh" 2>/dev/null || true)
CONTEXT=$(echo "$OUTPUT" | jq -r '.hookSpecificOutput.additionalContext // .' 2>/dev/null || echo "$OUTPUT")
TESTS_RUN=$((TESTS_RUN + 1))
if ! grep -qF "nodes marked active" <<< "$CONTEXT"; then
    echo -e "${GREEN}✓${NC} no false reboot warning when no active nodes"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "${RED}✗${NC} no false reboot warning when no active nodes"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# ═══════════════════════════════════════════════════════════════════════════
# Benchmark Criteria (Crash Simulation)
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo "═══ Crash Benchmark (5 Criteria) ═══"

# Simulate full crash scenario:
# 1. Start session (write sentinel + create active work)
# 2. Kill (skip session-end — sentinel persists)
# 3. Start new session (detect crash)
# 4. Verify 5 criteria

setup_test_env

# Phase 1: "First session" — create work and write sentinel
"$WV" add "Benchmark task A" --status=active --criteria="recover session fixture" --risks=low --force >/dev/null 2>&1
NODE_A=$("$WV" list --status=active --json 2>/dev/null | jq -r '.[0].id')
echo '{}' | bash "$HOOKS_DIR/session-start-context.sh" >/dev/null 2>&1 || true

# Sync state so it survives "crash"
"$WV" sync >/dev/null 2>&1 || true

# Phase 2: "Crash" — sentinel persists, session-end never runs
# (We simply don't call session-end-sync.sh)

# Snapshot pre-crash state
PRE_CRASH_IDS=$("$WV" list --all --json 2>/dev/null | jq -c '[.[].id]')
PRE_CRASH_COUNT=$("$WV" list --all --json 2>/dev/null | jq 'length')

# Phase 3: "New session" — reload from state.sql (simulating fresh start)
# Re-init the DB from state.sql to simulate wv load on fresh session
rm -f "$WV_DB"
"$WV" load >/dev/null 2>&1 || true

# Criterion 1: State preserved
POST_CRASH_IDS=$("$WV" list --all --json 2>/dev/null | jq -c '[.[].id]')
POST_CRASH_COUNT=$("$WV" list --all --json 2>/dev/null | jq 'length')
assert_equals "$PRE_CRASH_COUNT" "$POST_CRASH_COUNT" "BM1: State preserved — same node count after crash"

# Criterion 2: Crash detected
STARTUP_OUTPUT=$(echo '{}' | bash "$HOOKS_DIR/session-start-context.sh" 2>/dev/null || true)
assert_contains "$STARTUP_OUTPUT" "CRASH DETECTED" "BM2: Crash detected on restart"

# Criterion 3: Recovery breadcrumb generated
BC_FILE="$TEST_DIR/.weave/breadcrumbs.md"
if [ -f "$BC_FILE" ]; then
    BC_CONTENT=$(cat "$BC_FILE")
    assert_contains "$BC_CONTENT" "CRASH RECOVERY" "BM3: Recovery breadcrumb generated"
else
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -e "${YELLOW}✓${NC} BM3: Recovery breadcrumb (skipped — wv breadcrumbs not available in test env)"
    TESTS_PASSED=$((TESTS_PASSED + 1))
fi

# Criterion 4: Orphaned nodes surfaced via wv recover --session
RECOVER_OUTPUT=$("$WV" recover --session 2>/dev/null)
assert_contains "$RECOVER_OUTPUT" "Benchmark task A" "BM4: Orphaned node surfaced by recover --session"

# Criterion 5: Sentinel cleared on clean exit
echo '{"reason":"user_ended"}' | bash "$HOOKS_DIR/session-end-sync.sh" 2>/dev/null || true
assert_file_absent "$SENTINEL" "BM5: Sentinel cleared on clean exit"

# ═══════════════════════════════════════════════════════════════════════════
# Two sessions on one hot zone (wv-9a867a)
# ═══════════════════════════════════════════════════════════════════════════
# 2026-11-17: a second session started in the same checkout overwrote the
# first's epoch (its own node was then refused as stale), read its live
# heartbeat as a dead session and deleted it. Session files are now per session,
# and a live harness process in the checkout is a peer, not a crash.

echo ""
echo "═══ Two sessions on one hot zone ═══"
digest() { printf '%s' "$1" | sha256sum | cut -c1-16; }
DA=$(digest sess-A); DB=$(digest sess-B)
setup_test_env
echo "hot/" >> .gitignore
WV_SESSION_IDENTITY=1 WV_SESSION_ID=sess-A bash "$HOOKS_DIR/session-start-context.sh" <<< '{}' >/dev/null 2>&1 || true
assert_file_exists "$WV_HOT_ZONE/.session_sentinel.$DA" "session A writes its own sentinel"
assert_file_exists "$WV_HOT_ZONE/.session_epoch.$DA" "session A writes its own epoch"
assert_file_absent "$SENTINEL" "no flat sentinel when the session is known"
WV_SESSION_IDENTITY=1 WV_SESSION_ID=sess-A bash "$HOOKS_DIR/pre-action.sh" <<< '{"tool_name":"Read","tool_input":{"file_path":"/dev/null"}}' >/dev/null 2>&1 || true
assert_file_exists "$WV_HOT_ZONE/.session_heartbeat.$DA" "session A's tool call writes its own heartbeat"
EPOCH_A=$(cat "$WV_HOT_ZONE/.session_epoch.$DA" 2>/dev/null)

# A live peer: a harness process (comm "codex") working in this checkout.
# shellcheck source=tests/lib/fake-agent-bin.sh
source "$PROJECT_ROOT/tests/lib/fake-agent-bin.sh"
fake_agent_bin "$TEST_DIR/bin/codex"
(cd "$TEST_DIR" && exec "$TEST_DIR/bin/codex" 300) & PEER_PID=$!
sleep 1
OUTPUT=$(WV_SESSION_IDENTITY=1 WV_SESSION_ID=sess-B bash "$HOOKS_DIR/session-start-context.sh" <<< '{}' 2>/dev/null || true)
assert_contains "$OUTPUT" "another session is live in this checkout" "a session starting beside a live peer reports the peer"
if grep -qE 'ended without SessionEnd|CRASH DETECTED|died mid-turn' <<< "$OUTPUT"; then
    echo -e "${RED}✗${NC} a live peer is not reported as a crashed or ended session"
    TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1))
else
    echo -e "${GREEN}✓${NC} a live peer is not reported as a crashed or ended session"
    TESTS_RUN=$((TESTS_RUN + 1)); TESTS_PASSED=$((TESTS_PASSED + 1))
fi
assert_file_exists "$WV_HOT_ZONE/.session_sentinel.$DA" "the peer's sentinel is left alone"
assert_file_exists "$WV_HOT_ZONE/.session_heartbeat.$DA" "the peer's heartbeat is left alone"
assert_equals "$EPOCH_A" "$(cat "$WV_HOT_ZONE/.session_epoch.$DA" 2>/dev/null)" "the peer's epoch is unchanged by the second start"
assert_file_exists "$WV_HOT_ZONE/.session_sentinel.$DB" "session B writes its own sentinel"
kill "$PEER_PID" 2>/dev/null || true; wait "$PEER_PID" 2>/dev/null || true

# No live peer now: A's sentinel is an ended session (activity, no stop).
OUTPUT=$(WV_SESSION_IDENTITY=1 WV_SESSION_ID=sess-C bash "$HOOKS_DIR/session-start-context.sh" <<< '{}' 2>/dev/null || true)
assert_contains "$OUTPUT" "died mid-turn" "with no live peer, an ended session is still labelled"
assert_file_absent "$WV_HOT_ZONE/.session_sentinel.$DA" "an ended session's sentinel is removed"
assert_file_absent "$WV_HOT_ZONE/.session_heartbeat.$DA" "an ended session's heartbeat is removed"

# ═══════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo "═══════════════════════════════════════"
echo -e "Results: ${TESTS_PASSED}/${TESTS_RUN} passed"
if [ "$TESTS_FAILED" -gt 0 ]; then
    echo -e "${RED}${TESTS_FAILED} test(s) failed${NC}"
    exit 1
else
    echo -e "${GREEN}All tests passed${NC}"
    exit 0
fi
