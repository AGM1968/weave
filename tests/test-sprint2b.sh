#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# test-sprint2b.sh — Test Sprint 2b: Agent Orientation features
#
# Tests: breadcrumbs, digest, learnings filters/modes, write-time validation
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
TEST_DIR="/tmp/wv-sprint2b-test-$$"
export WV_HOT_ZONE="$TEST_DIR"
export WV_DB="$TEST_DIR/brain.db"
export WV_REQUIRE_LEARNING=0
export WV_PROJECT_DIR="$TEST_DIR"

cleanup() {
    if [ -d "$TEST_DIR" ]; then
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

setup_test_env() {
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR"
    export WV_PROJECT_DIR="$TEST_DIR"
    cd "$TEST_DIR"
}

# ---------------------------------------------------------------------------
# Test helpers (same pattern as other test suites)
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

assert_contains() {
    local haystack="$1" needle="$2" message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if grep -qF -- "$needle" <<<"$haystack"; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Expected to find: $needle"
        echo "  In: $(echo "$haystack" | sed -n '1,5p')"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if ! grep -qF -- "$needle" <<<"$haystack"; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Expected NOT to find: $needle"
        echo "  In: $(echo "$haystack" | sed -n '1,5p')"
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

node_id_from_output() {
    sed -n 's/.*\(wv-[0-9a-f]\{6\}\).*/\1/p' | tail -1
}

# ═══════════════════════════════════════════════════════════════════════════
# Test: Digest command
# ═══════════════════════════════════════════════════════════════════════════

test_digest() {
    echo ""
    echo "=== Digest ==="

    setup_test_env
    $WV init >/dev/null 2>&1

    # Create some nodes to get meaningful stats
    local id1 id2 id3 id4
    id1=$($WV add "Task one" 2>&1 | node_id_from_output)
    id2=$($WV add "Task two" 2>&1 | node_id_from_output)
    id3=$($WV add "Task three" 2>&1 | node_id_from_output)
    id4=$($WV add "Active task" 2>&1 | node_id_from_output)
    $WV work "$id4" >/dev/null 2>&1

    # Text format
    local output
    output=$($WV digest 2>/dev/null)
    assert_contains "$output" "nodes" "digest shows node count"
    assert_contains "$output" "active" "digest shows active count"
    assert_contains "$output" "ready" "digest shows ready count"

    # JSON format
    local json_output
    json_output=$($WV digest --json 2>/dev/null)

    TESTS_RUN=$((TESTS_RUN + 1))
    if echo "$json_output" | jq '.' >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} digest --json is valid JSON"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} digest --json is valid JSON"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi

    assert_contains "$json_output" '"nodes"' "digest JSON has nodes field"
    assert_contains "$json_output" '"active"' "digest JSON has active field"
    assert_contains "$json_output" '"ready"' "digest JSON has ready field"
    assert_contains "$json_output" '"blocked"' "digest JSON has blocked field"
    assert_contains "$json_output" '"done"' "digest JSON has done field"
    assert_contains "$json_output" '"alerts"' "digest JSON has alerts field"
    assert_contains "$json_output" '"issues"' "digest JSON has issues object"

    # JSON values are reasonable
    local node_count
    node_count=$(echo "$json_output" | jq '.nodes' 2>/dev/null)
    assert_equals "4" "$node_count" "digest JSON shows correct total nodes"

    local active_count
    active_count=$(echo "$json_output" | jq '.active' 2>/dev/null)
    assert_equals "1" "$active_count" "digest JSON shows correct active count"
}

# ═══════════════════════════════════════════════════════════════════════════
# Test: Breadcrumbs command
# ═══════════════════════════════════════════════════════════════════════════

test_breadcrumbs() {
    echo ""
    echo "=== Breadcrumbs ==="

    setup_test_env
    $WV init >/dev/null 2>&1

    # Create some test data
    $WV add "Active work item" >/dev/null 2>&1
    local id1
    id1=$($WV add "Working on this" 2>&1 | node_id_from_output)
    $WV work "$id1" >/dev/null 2>&1

    # Show with no breadcrumbs
    local show_output
    show_output=$($WV breadcrumbs show 2>/dev/null)
    assert_contains "$show_output" "No trails found" "show without saved breadcrumbs says none"

    # Save breadcrumbs
    assert_success "breadcrumbs save succeeds" "$WV" breadcrumbs save

    # Show saved breadcrumbs
    show_output=$($WV breadcrumbs show 2>/dev/null)
    assert_contains "$show_output" "Session Trails" "show has header"
    assert_contains "$show_output" "Health" "show has health section"

    # Save with message
    assert_success "breadcrumbs save with message" "$WV" breadcrumbs save --message="Test checkpoint"
    show_output=$($WV breadcrumbs show 2>/dev/null)
    assert_contains "$show_output" "Test checkpoint" "show includes custom message"
    assert_contains "$show_output" "Notes" "show has Notes section for message"

    # Clear breadcrumbs
    local clear_output
    clear_output=$($WV breadcrumbs clear 2>/dev/null)
    assert_contains "$clear_output" "cleared" "clear confirms deletion"

    # Show after clear
    show_output=$($WV breadcrumbs show 2>/dev/null)
    assert_contains "$show_output" "No trails found" "show after clear says none"

    # Invalid action
    assert_fails "breadcrumbs with invalid action fails" "$WV" breadcrumbs invalid_action

    # Persistence guard: breadcrumbs save must NOT create .weave/ in uninitialized dir
    local uninitialized_dir
    uninitialized_dir=$(mktemp -d)
    (
        cd "$uninitialized_dir"
        git init -q
        git config user.email "t@t.com"
        git config user.name "T"
        git config commit.gpgsign false
        export WV_HOT_ZONE="$uninitialized_dir"
        export WV_DB="$uninitialized_dir/brain.db"
        export WEAVE_DIR="$uninitialized_dir/.weave"
        "$WV" breadcrumbs save --message="should not persist" 2>/dev/null || true
        # .weave/ must NOT exist — hot zone is empty and repo is uninitialized
        if [ -d "$uninitialized_dir/.weave" ]; then
            exit 1
        fi
        exit 0
    )
    local bc_guard_result=$?
    rm -rf "$uninitialized_dir"
    assert_equals "0" "$bc_guard_result" "breadcrumbs save: no .weave/ created in uninitialized repo"

    # wv doctor from outside any git repo must not produce false hook-drift warning
    # (REPO_ROOT==$HOME guard in wv-config.sh prevents WEAVE_DIR=~/.weave → source_hooks_dir=~/.claude/hooks)
    local outside_dir
    outside_dir=$(mktemp -d)
    local drift_out
    # Without the suite's override: that hot zone belongs to the fixture repo and
    # wv refuses it from anywhere else (wv-5e804e).
    drift_out=$(cd "$outside_dir" && env -u WV_HOT_ZONE -u WV_DB "$WV" doctor 2>&1 | grep "hook drift" || true)
    rm -rf "$outside_dir"
    assert_not_contains "$drift_out" "drifted:" "doctor from outside git repo: no false hook-drift warning"
    assert_contains "$drift_out" "hook drift" "doctor from outside git repo: hook drift check still runs"

    # wv-ddb359: doctor's FTS5 check must also probe nodes_learning_fts, not
    # just nodes_fts -- a corruption confined to the learning index was
    # previously invisible to both PRAGMA integrity_check and this check,
    # letting `wv doctor` report healthy while every `wv done` failed.
    local doctor_out
    doctor_out=$("$WV" doctor --json 2>/dev/null)
    assert_contains "$doctor_out" "FTS5 learning index" "doctor reports a dedicated FTS5 learning-index check"
    local learning_status
    learning_status=$(echo "$doctor_out" | jq -r '.checks[] | select(.check=="FTS5 learning index") | .status' 2>/dev/null)
    assert_equals "pass" "$learning_status" "FTS5 learning-index check passes on a healthy DB"

    # Simulate the actual corruption class: drop the learning index out from
    # under a live nodes table (structurally what a corrupted-but-page-valid
    # shadow index looks like -- base data intact, derived index gone/bad).
    # --repair must recreate it and report the repair, not just fail closed.
    sqlite3 "$WV_DB" "DROP TABLE IF EXISTS nodes_learning_fts;"
    local repair_out
    repair_out=$("$WV" doctor --repair --json 2>/dev/null)
    local repair_status repair_detail
    repair_status=$(echo "$repair_out" | jq -r '.checks[] | select(.check=="FTS5 learning index") | .status' 2>/dev/null)
    repair_detail=$(echo "$repair_out" | jq -r '.checks[] | select(.check=="FTS5 learning index") | .detail' 2>/dev/null)
    assert_equals "pass" "$repair_status" "doctor --repair recreates a dropped nodes_learning_fts"
    assert_contains "$repair_detail" "repaired" "doctor --repair reports the learning-index repair explicitly"

    local learning_exists
    learning_exists=$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='nodes_learning_fts';" 2>/dev/null)
    assert_equals "1" "$learning_exists" "nodes_learning_fts table exists again after doctor --repair"

    # wv-d2e6c6: the orphaned-index-entry class. A dropped table (above) is the
    # easy case. The failure that actually took out `wv done` graph-wide twice is
    # subtler: nodes_fts is external-content over a TEXT-primary-key table, so an
    # INSERT OR REPLACE -- what delta replay emits -- moves the node's implicit
    # rowid, and with recursive_triggers OFF the implicit delete never fires
    # nodes_ad. The index entry at the OLD rowid is stranded, and BOTH
    # PRAGMA integrity_check and FTS5 'integrity-check' still report ok.
    local orphan_target
    orphan_target=$(sqlite3 "$WV_DB" "SELECT id FROM nodes LIMIT 1;" 2>/dev/null)
    sqlite3 "$WV_DB" "INSERT OR REPLACE INTO nodes(id,text,status,metadata)
                      SELECT id,text,status,metadata FROM nodes WHERE id='$orphan_target';"

    local orphan_count fts_self_check
    orphan_count=$(sqlite3 "$WV_DB" \
        "CREATE VIRTUAL TABLE temp.t_fv USING fts5vocab(main, nodes_fts, instance);
         SELECT count(DISTINCT doc) FROM temp.t_fv WHERE doc NOT IN (SELECT rowid FROM nodes);" 2>/dev/null)
    assert_equals "1" "$orphan_count" "INSERT OR REPLACE strands an orphaned nodes_fts entry"

    # The probe doctor used to rely on: proves it cannot see this class.
    fts_self_check=$(sqlite3 "$WV_DB" "INSERT INTO nodes_fts(nodes_fts) VALUES('integrity-check');" 2>&1)
    assert_equals "" "$fts_self_check" "FTS5 'integrity-check' reports clean despite the orphan (why it is not a detector)"

    # doctor exits non-zero when a check fails -- which is the whole point here,
    # so tolerate it rather than letting set -e abort the suite.
    local orphan_out orphan_status orphan_detail
    orphan_out=$("$WV" doctor --json 2>/dev/null || true)
    orphan_status=$(echo "$orphan_out" | jq -r '.checks[] | select(.check=="FTS5 index") | .status' 2>/dev/null)
    orphan_detail=$(echo "$orphan_out" | jq -r '.checks[] | select(.check=="FTS5 index") | .detail' 2>/dev/null)
    assert_equals "fail" "$orphan_status" "doctor detects an orphaned nodes_fts entry"
    assert_contains "$orphan_detail" "orphaned" "doctor names the orphan class, not a generic corruption"

    local orphan_repair orphan_repair_status orphan_after
    orphan_repair=$("$WV" doctor --repair --json 2>/dev/null)
    orphan_repair_status=$(echo "$orphan_repair" | jq -r '.checks[] | select(.check=="FTS5 index") | .status' 2>/dev/null)
    assert_equals "pass" "$orphan_repair_status" "doctor --repair clears the orphaned entry"
    orphan_after=$(sqlite3 "$WV_DB" \
        "CREATE VIRTUAL TABLE temp.t_fv2 USING fts5vocab(main, nodes_fts, instance);
         SELECT count(DISTINCT doc) FROM temp.t_fv2 WHERE doc NOT IN (SELECT rowid FROM nodes);" 2>/dev/null)
    assert_equals "0" "$orphan_after" "no orphaned nodes_fts entries remain after repair"

    # Missing entries are the opposite divergence (wv-ccd364): neither the
    # self-check nor the orphan probe sees an empty external-content index.
    sqlite3 "$WV_DB" "INSERT INTO nodes_fts(nodes_fts) VALUES('delete-all');"
    local missing_out missing_status missing_rc=0
    missing_out=$("$WV" doctor --json 2>/dev/null) || missing_rc=$?
    missing_status=$(echo "$missing_out" | jq -r '.checks[] | select(.check=="FTS5 index") | .status')
    assert_equals "fail" "$missing_status" "doctor detects missing nodes_fts entries"
    assert_equals "1" "$missing_rc" "doctor refuses a graph with missing FTS entries"
    local missing_repair missing_repair_status content_rc=0 update_rc=0
    missing_repair=$("$WV" doctor --repair --json 2>/dev/null)
    missing_repair_status=$(echo "$missing_repair" | jq -r '.checks[] | select(.check=="FTS5 index") | .status')
    assert_equals "pass" "$missing_repair_status" "doctor --repair rebuilds missing nodes_fts entries"
    sqlite3 "$WV_DB" "INSERT INTO nodes_fts(nodes_fts,rank) VALUES('integrity-check',1);" 2>/dev/null || content_rc=$?
    assert_equals "0" "$content_rc" "repaired index agrees with node content"
    "$WV" update "$orphan_target" --text='repaired missing index control' >/dev/null 2>&1 || update_rc=$?
    assert_equals "0" "$update_rc" "node updates work after missing-entry repair"

    # wv-a77603: cross-agent install-drift advisory rides the bootstrap JSON that
    # every harness (Claude/Codex/Copilot) reads at session start. With no
    # source-path pointer _wv_source_drift no-ops (consumer-safe) and advisories
    # is an empty array. The config dir is stated, not assumed: inherited, the
    # developer's real pointer made this red whenever the checkout held an
    # uninstalled edit (wv-755543).
    local boot_adv empty_cfg drift_cfg drift_home
    empty_cfg=$(mktemp -d)
    boot_adv=$(WV_CONFIG_DIR="$empty_cfg" "$WV" bootstrap --json 2>/dev/null | jq -c '.advisories' 2>/dev/null)
    assert_equals "[]" "$boot_adv" "bootstrap exposes advisories array; clean when no source-path (consumer-safe no-op)"
    # ...and the same call does report drift when a pointer names a source tree
    # whose installed copies are missing, so the clean case is not vacuous.
    drift_cfg=$(mktemp -d); drift_home=$(mktemp -d)
    mkdir -p "$drift_cfg/src/scripts/cmd"
    echo 'edited' > "$drift_cfg/src/scripts/cmd/wv-cmd-probe.sh"
    printf '%s\n' "$drift_cfg/src" > "$drift_cfg/source-path"
    boot_adv=$(HOME="$drift_home" WV_CONFIG_DIR="$drift_cfg" "$WV" bootstrap --json 2>/dev/null | jq -c '.advisories' 2>/dev/null)
    assert_contains "$boot_adv" "install drift" "bootstrap reports install drift when a source-path pointer names drifted sources"
    rm -rf "$empty_cfg" "$drift_cfg" "$drift_home"
}

test_doctor_cold_start_hydrates() {
    echo ""
    echo "=== Doctor cold start ==="

    setup_test_env
    export WV_HOT_ZONE="$TEST_DIR/hotzone"
    unset WV_DB
    "$WV" init >/dev/null 2>&1
    "$WV" add "persisted cold-start fixture" >/dev/null 2>&1
    "$WV" sync >/dev/null 2>&1

    rm -rf "$WV_HOT_ZONE"
    local first_out first_rc=0 first_database first_hot_zone
    first_out=$("$WV" doctor --json 2>/dev/null) || first_rc=$?
    first_database=$(jq -r '.checks[] | select(.check=="database") | .status' <<<"$first_out")
    first_hot_zone=$(jq -r '.checks[] | select(.check=="hot zone") | .status' <<<"$first_out")

    rm -rf "$WV_HOT_ZONE"
    "$WV" status >/dev/null 2>&1
    local preceded_out preceded_rc=0 preceded_database preceded_hot_zone
    preceded_out=$("$WV" doctor --json 2>/dev/null) || preceded_rc=$?
    preceded_database=$(jq -r '.checks[] | select(.check=="database") | .status' <<<"$preceded_out")
    preceded_hot_zone=$(jq -r '.checks[] | select(.check=="hot zone") | .status' <<<"$preceded_out")

    assert_equals "$preceded_rc" "$first_rc" \
        "doctor exit status does not depend on a preceding hydrating command"
    assert_equals "pass" "$first_database" \
        "doctor first command hydrates and checks the committed database"
    assert_equals "$preceded_database" "$first_database" \
        "database verdict is identical before and after a preceding command"
    assert_equals "pass" "$first_hot_zone" \
        "doctor first command reports the hydrated hot zone"
    assert_equals "$preceded_hot_zone" "$first_hot_zone" \
        "hot-zone verdict is identical before and after a preceding command"

    export WV_HOT_ZONE="$TEST_DIR"
    export WV_DB="$TEST_DIR/brain.db"
}

# ═══════════════════════════════════════════════════════════════════════════
# Test: Learnings filters (--category, --grep, --recent)
# ═══════════════════════════════════════════════════════════════════════════

test_learnings_filters() {
    echo ""
    echo "=== Learnings Filters ==="

    setup_test_env
    $WV init >/dev/null 2>&1

    # Create nodes with various learning types via metadata
    local id1 id2 id3 id4
    id1=$($WV add "Auth implementation" --metadata='{"decision":"Use JWT tokens"}' 2>&1 | node_id_from_output)
    id2=$($WV add "Cache layer" --metadata='{"pattern":"Cache aside pattern"}' 2>&1 | node_id_from_output)
    id3=$($WV add "API design" --metadata='{"pitfall":"REST naming is tricky"}' 2>&1 | node_id_from_output)
    id4=$($WV add "DB migration" 2>&1 | node_id_from_output)

    # Mark all as done (id1-3 already have learning metadata, id4 gets --learning)
    $WV "done" "$id1" --no-warn >/dev/null 2>&1
    $WV "done" "$id2" --no-warn >/dev/null 2>&1
    $WV "done" "$id3" --no-warn >/dev/null 2>&1
    $WV "done" "$id4" --learning="Always backup first" --no-warn >/dev/null 2>&1

    # Basic learnings (no filter)
    local output
    output=$($WV learnings 2>/dev/null)
    assert_contains "$output" "JWT" "learnings shows decision content"
    assert_contains "$output" "Cache aside" "learnings shows pattern content"
    assert_contains "$output" "REST naming" "learnings shows pitfall content"
    assert_contains "$output" "backup" "learnings shows learning content"

    # Category filter: decision only
    output=$($WV learnings --category=decision 2>/dev/null)
    assert_contains "$output" "JWT" "category=decision shows decisions"
    assert_not_contains "$output" "Cache aside" "category=decision excludes patterns"

    # Category filter: pitfall only
    output=$($WV learnings --category=pitfall 2>/dev/null)
    assert_contains "$output" "REST naming" "category=pitfall shows pitfalls"
    assert_not_contains "$output" "JWT" "category=pitfall excludes decisions"

    # Category filter: pattern only
    output=$($WV learnings --category=pattern 2>/dev/null)
    assert_contains "$output" "Cache aside" "category=pattern shows patterns"

    # Invalid category
    local err_output
    err_output=$($WV learnings --category=invalid 2>&1 || true)
    assert_contains "$err_output" "invalid" "invalid category gives error"

    # Grep filter
    output=$($WV learnings --grep=JWT 2>/dev/null)
    assert_contains "$output" "JWT" "grep=JWT finds match"

    output=$($WV learnings --grep=backup 2>/dev/null)
    assert_contains "$output" "backup" "grep=backup finds match"

    # Recent limit
    output=$($WV learnings --recent=2 2>/dev/null)
    # Should show at most 2 results (exact content depends on order)
    local line_count
    line_count=$(echo "$output" | grep -c '─\|━\|ID:' || true)
    # Just check it doesn't error and produces output
    assert_success "learnings --recent=2 succeeds" "$WV" learnings --recent=2

    # Invalid recent
    err_output=$($WV learnings --recent=abc 2>&1 || true)
    assert_contains "$err_output" "number" "non-numeric --recent gives error"

    # JSON output
    local json_output
    json_output=$($WV learnings --json 2>/dev/null)
    TESTS_RUN=$((TESTS_RUN + 1))
    if echo "$json_output" | jq '.' >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} learnings --json is valid JSON"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} learnings --json is valid JSON"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi

    # Combined filters
    output=$($WV learnings --category=decision --grep=JWT 2>/dev/null)
    assert_contains "$output" "JWT" "combined category+grep works"
}

# ═══════════════════════════════════════════════════════════════════════════
# Test: Learnings mode-aware limits
# ═══════════════════════════════════════════════════════════════════════════

test_learnings_modes() {
    echo ""
    echo "=== Learnings Modes ==="

    setup_test_env
    $WV init >/dev/null 2>&1

    local id i json_output count
    for i in $(seq 1 12); do
        id=$($WV add "Learning node $i" --metadata="{\"learning\":\"Learning $i\"}" 2>&1 | node_id_from_output)
        $WV "done" "$id" --no-warn >/dev/null 2>&1
    done

    json_output=$($WV learnings --json --mode=bootstrap 2>/dev/null)
    count=$(echo "$json_output" | jq 'length')
    assert_equals "5" "$count" "bootstrap mode caps learnings at 5"

    json_output=$($WV learnings --json --mode=discover 2>/dev/null)
    count=$(echo "$json_output" | jq 'length')
    assert_equals "10" "$count" "discover mode caps learnings at 10"

    json_output=$(WV_AGENT=1 $WV learnings --json 2>/dev/null)
    count=$(echo "$json_output" | jq 'length')
    assert_equals "10" "$count" "agent mode auto-detect caps learnings at 10"

    json_output=$($WV learnings --json --mode=bootstrap --recent=7 2>/dev/null)
    count=$(echo "$json_output" | jq 'length')
    assert_equals "7" "$count" "explicit --recent overrides mode cap"

    json_output=$($WV learnings --json --mode=discover --grep='Learning node 1$' 2>/dev/null)
    count=$(echo "$json_output" | jq 'length')
    assert_equals "1" "$count" "discover mode applies grep before the cap"
}

# ═══════════════════════════════════════════════════════════════════════════
# Test: Write-time validation on done
# ═══════════════════════════════════════════════════════════════════════════

test_validation_on_done() {
    echo ""
    echo "=== Write-time Validation ==="

    setup_test_env
    $WV init >/dev/null 2>&1

    # Create an orphan node (no edges, no learning) and complete it
    local id1
    id1=$($WV add "Orphan task" 2>&1 | node_id_from_output)

    # Complete without learning — should show validation warnings on stderr
    local full_output
    full_output=$($WV "done" "$id1" 2>&1)
    assert_contains "$full_output" "learning" "done without learning shows learning warning"
    assert_contains "$full_output" "Orphan" "done without edges shows orphan warning"

    # Create a linked node with learning — should NOT warn
    setup_test_env
    $WV init >/dev/null 2>&1
    local parent child
    parent=$($WV add "Parent" 2>&1 | node_id_from_output)
    child=$($WV add "Child" 2>&1 | node_id_from_output)
    $WV link "$child" "$parent" --type=implements >/dev/null 2>&1

    local done_output
    done_output=$($WV "done" "$child" --learning="Learned something" 2>&1)
    assert_not_contains "$done_output" "No learning" "done with learning suppresses learning warning"
    assert_not_contains "$done_output" "Orphan" "done with edges suppresses orphan warning"

    # Test --no-warn suppresses all warnings
    setup_test_env
    $WV init >/dev/null 2>&1
    local orphan
    orphan=$($WV add "Another orphan" 2>&1 | node_id_from_output)

    done_output=$($WV "done" "$orphan" --no-warn 2>&1)
    assert_not_contains "$done_output" "Validation" "done --no-warn suppresses all warnings"
    assert_not_contains "$done_output" "learning" "done --no-warn suppresses learning warning"
}

# ═══════════════════════════════════════════════════════════════════════════
# Test: Breadcrumbs content with rich data
# ═══════════════════════════════════════════════════════════════════════════

test_breadcrumbs_rich() {
    echo ""
    echo "=== Breadcrumbs (rich data) ==="

    setup_test_env
    $WV init >/dev/null 2>&1

    # Create a blocked node (wv block sets status=blocked AND creates edge)
    local blocker blocked
    blocker=$($WV add "Blocker task" 2>&1 | node_id_from_output)
    blocked=$($WV add "Blocked task" 2>&1 | node_id_from_output)
    $WV block "$blocked" --by="$blocker" >/dev/null 2>&1

    # Create a node with learning (via metadata since done doesn't support --decision)
    local done_id
    done_id=$($WV add "Completed work" --metadata='{"decision":"Important decision"}' 2>&1 | node_id_from_output)
    $WV "done" "$done_id" --no-warn >/dev/null 2>&1

    # Create an active node
    local active_id
    active_id=$($WV add "Working now" 2>&1 | node_id_from_output)
    $WV work "$active_id" >/dev/null 2>&1

    # Save breadcrumbs
    $WV breadcrumbs save >/dev/null 2>&1
    local output
    output=$($WV breadcrumbs show 2>/dev/null)

    assert_contains "$output" "Active Work" "breadcrumbs shows Active Work section"
    assert_contains "$output" "Working now" "breadcrumbs shows active node text"
    assert_contains "$output" "Health" "breadcrumbs shows Health section"
    assert_contains "$output" "Blocked" "breadcrumbs shows Blocked section"
}

# ═══════════════════════════════════════════════════════════════════════════
# Test: Digest alerts
# ═══════════════════════════════════════════════════════════════════════════

test_digest_alerts() {
    echo ""
    echo "=== Digest Alerts ==="

    setup_test_env
    $WV init >/dev/null 2>&1

    # Create an open node with a pitfall but no addressing edge.
    # Must stay open (not done) — done-node pitfalls are captured learnings, not unaddressed debt.
    local id1
    id1=$($WV add "Task with pitfall" --metadata='{"pitfall":"Something bad"}' 2>&1 | node_id_from_output)

    local json_output
    json_output=$($WV digest --json 2>/dev/null)
    local pitfall_count
    pitfall_count=$(echo "$json_output" | jq '.issues.unaddressed_pitfalls' 2>/dev/null)
    assert_equals "1" "$pitfall_count" "digest detects unaddressed pitfall"

    # Text output should show alert
    local text_output
    text_output=$($WV digest 2>/dev/null)
    assert_contains "$text_output" "pitfall" "digest text shows pitfall alert"
}

test_agent_python_resolution_is_side_effect_free() {
    echo ""
    echo "=== Agent Python Resolution Is Side-Effect-Free ==="

    setup_test_env
    mkdir -p "$TEST_DIR/fake-bin" "$TEST_DIR/modules" .venv/bin
    printf '%s\n' '[project]' 'name = "fixture"' > pyproject.toml
    touch uv.lock
    # Model the cross-namespace SSD case: the virtualenv exists on disk but its
    # interpreter target is unavailable in this mount namespace.
    ln -s /unavailable/host-python .venv/bin/python3
    cat > "$TEST_DIR/fake-bin/poetry" <<'POETRYFAKE'
#!/usr/bin/env bash
touch "$POETRY_WAS_INVOKED"
exit 99
POETRYFAKE
    chmod +x "$TEST_DIR/fake-bin/poetry"
    printf '%s\n' 'print("module ran")' > "$TEST_DIR/modules/resolver_probe.py"

    local resolved output expected_system_python marker="$TEST_DIR/poetry-invoked"
    expected_system_python=$(PATH="$TEST_DIR/fake-bin:/usr/bin:/bin" command -v python3)
    resolved=$(REPO_ROOT="$TEST_DIR" PATH="$TEST_DIR/fake-bin:/usr/bin:/bin" \
        bash -c 'source "$1"; source "$2"; _bootstrap_python_command' _ \
        "$PROJECT_ROOT/scripts/lib/wv-resolve-runtime.sh" \
        "$PROJECT_ROOT/scripts/cmd/wv-cmd-python.sh")
    assert_equals "$expected_system_python" "$resolved" \
        "uv repository with unavailable virtualenv falls back to an existing interpreter"

    output=$(REPO_ROOT="$TEST_DIR" POETRY_WAS_INVOKED="$marker" \
        PATH="$TEST_DIR/fake-bin:/usr/bin:/bin" \
        bash -c 'source "$1"; source "$2"; _wv_agent_python_exec_module resolver_probe "$3"' _ \
        "$PROJECT_ROOT/scripts/lib/wv-resolve-runtime.sh" \
        "$PROJECT_ROOT/scripts/cmd/wv-cmd-python.sh" "$TEST_DIR/modules")
    assert_equals "module ran" "$output" \
        "agent module executes without invoking a repository package manager"
    assert_equals "false" "$([ -e "$marker" ] && echo true || echo false)" \
        "read-only agent module resolution does not invoke Poetry"

    rm -f uv.lock .venv/bin/python3
    touch poetry.lock
    cat > .venv/bin/python3 <<'PYTHONFAKE'
#!/usr/bin/env bash
exec /usr/bin/python3 "$@"
PYTHONFAKE
    chmod +x .venv/bin/python3
    resolved=$(REPO_ROOT="$TEST_DIR" PATH="$TEST_DIR/fake-bin:/usr/bin:/bin" \
        bash -c 'source "$1"; source "$2"; _bootstrap_python_command' _ \
        "$PROJECT_ROOT/scripts/lib/wv-resolve-runtime.sh" \
        "$PROJECT_ROOT/scripts/cmd/wv-cmd-python.sh")
    assert_equals "$TEST_DIR/.venv/bin/python3" "$resolved" \
        "Poetry repository uses its existing virtualenv interpreter directly"
}

# ═══════════════════════════════════════════════════════════════════════════
# Run all tests
# ═══════════════════════════════════════════════════════════════════════════

main() {
    echo "Sprint 2b: Agent Orientation Tests"
    echo "════════════════════════════════════"

    test_digest
    test_breadcrumbs
    test_doctor_cold_start_hydrates
    test_doctor_claim_ownership
    test_learnings_filters
    test_learnings_modes
    test_validation_on_done
    test_breadcrumbs_rich
    test_digest_alerts
    test_agent_python_resolution_is_side_effect_free

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

test_doctor_claim_ownership() {
    setup_test_env
    git init -q
    "$WV" init >/dev/null 2>&1
    local db before out detail rc mode
    db=$("$WV" hotzone db)
    sqlite3 "$db" "INSERT INTO nodes(id,text,status,metadata) VALUES
      ('wv-aa0001','historical','active','{\"claimed_by\":\"human-old-host-user\"}'),
      ('wv-aa0002','parallel','active','{\"claimed_by\":\"codex-other-host-user\"}'),
      ('wv-aa0003','own','active',json_object('claimed_by','custom''current actor')),
      ('wv-aa0004','unclaimed','active','{}'),
      ('wv-aa0005','todo','todo','{\"claimed_by\":\"foreign-todo\"}');"
    "$WV" reindex >/dev/null 2>&1
    before=$(sqlite3 "$db" 'SELECT id,status,metadata FROM nodes ORDER BY id;')
    for mode in '' '--repair'; do
        rc=0
        out=$(WV_AGENT_ID="custom'current actor" "$WV" doctor --json $mode 2>/dev/null) || rc=$?
        detail=$(jq -r '.checks[] | select(.check=="claim ownership") | .detail' <<<"$out")
        assert_equals "0" "$rc" "foreign ownership is advisory ($mode)"
        assert_equals "warn" "$(jq -r '.checks[] | select(.check=="claim ownership") | .status' <<<"$out")" "foreign ownership warns ($mode)"
        assert_contains "$detail" "custom'current actor" "current custom actor is explicit ($mode)"
        assert_contains "$detail" 'wv-aa0001: human-old-host-user' "historical holder listed exactly ($mode)"
        assert_contains "$detail" 'wv-aa0002: codex-other-host-user' "legitimate parallel holder listed exactly ($mode)"
        assert_not_contains "$detail" 'wv-aa0003' "own claim excluded ($mode)"
        assert_not_contains "$detail" 'wv-aa0004' "unclaimed active excluded ($mode)"
        assert_not_contains "$detail" 'wv-aa0005' "foreign todo excluded ($mode)"
        assert_equals "$before" "$(sqlite3 "$db" 'SELECT id,status,metadata FROM nodes ORDER BY id;')" "doctor never mutates claim state ($mode)"
    done
    out=$(WV_AGENT_ID="custom'current actor" "$WV" doctor 2>/dev/null)
    assert_contains "$out" 'wv-aa0001: human-old-host-user' 'text doctor lists foreign ownership'
    sqlite3 "$db" "UPDATE nodes SET status='done' WHERE id IN ('wv-aa0001','wv-aa0002');"
    out=$(WV_AGENT_ID="custom'current actor" "$WV" doctor --json 2>/dev/null)
    assert_equals 'pass' "$(jq -r '.checks[] | select(.check=="claim ownership") | .status' <<<"$out")" 'no foreign claims is healthy'
    # Fail the required ownership read through the public CLI, not a private helper.
    mkdir -p "$TEST_DIR/bin"
    local real_sqlite
    real_sqlite=$(command -v sqlite3)
    cat > "$TEST_DIR/bin/sqlite3" <<'SQLITE'
#!/usr/bin/env bash
# db_query sends SQL on stdin (wv-aec7de): read it when the last argument is the DB file.
sql=""; from_stdin=0
if [ "$#" -gt 0 ] && [ -f "${!#}" ]; then sql=$(cat); from_stdin=1; fi
for arg in "$@" "$sql"; do
    if [[ "$arg" == SELECT* && "$arg" == *claimed_by* && "$arg" == *"FROM nodes"* && "$arg" == *active* ]]; then
        echo 'injected ownership read failure' >&2
        exit 1
    fi
done
[ "$from_stdin" = 1 ] && exec "$REAL_SQLITE" "$@" <<< "$sql"
exec "$REAL_SQLITE" "$@"
SQLITE
    chmod +x "$TEST_DIR/bin/sqlite3"
    out=$(PATH="$TEST_DIR/bin:$PATH" REAL_SQLITE="$real_sqlite" "$WV" doctor --json 2>/dev/null || true)
    detail=$(jq -r '.checks[] | select(.check=="claim ownership") | .detail' <<<"$out")
    assert_contains "$detail" 'unavailable' 'failed required ownership read is explicit'
    assert_equals 'warn' "$(jq -r '.checks[] | select(.check=="claim ownership") | .status' <<<"$out")" 'failed required read is not healthy'
}

main "$@"
