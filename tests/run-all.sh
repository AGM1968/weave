#!/bin/bash
# run-all.sh — Master test runner for Weave CLI tests
#
# Run: bash tests/run-all.sh             (parallel, fast tier — ~400s wall time)
#      bash tests/run-all.sh --serial    (serial, for readable output)
#      bash tests/run-all.sh --suite=X   (single suite by name fragment)
# Exit: 0 if all suites pass, 1 if any fail

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Tag suite-driven wv calls so call-stats can separate them from real traffic.
# (config.env force-enables WV_CALL_LOG even under test env overrides, so suite
# runs DO write to the user's durable call log — tag them rather than pollute
# source=shell/agent.)
export WV_CALL_SOURCE=test

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Options — parallel is default; use --serial for readable output
VERBOSE=false
PARALLEL=true
SUITE_FILTER=""
INCLUDE_SLOW=false

while [ $# -gt 0 ]; do
    case "$1" in
        --verbose|-v)   VERBOSE=true ;;
        --parallel|-p)  PARALLEL=true ;;
        --serial|-s)    PARALLEL=false ;;
        --slow)         INCLUDE_SLOW=true ;;
        --suite=*)      SUITE_FILTER="${1#*=}" ;;
        --help|-h)
            echo "Usage: $0 [--serial] [--slow] [--verbose] [--suite=NAME]"
            echo ""
            echo "Options:"
            echo "  --serial, -s    Serial execution (readable output; default is parallel)"
            echo "  --verbose, -v   Show individual test output (implies --serial)"
            echo "  --suite=NAME    Run only specific suite (name fragment match)"
            echo ""
            echo "Default: parallel fast tier (~25s wall time)"
            exit 0
            ;;
    esac
    shift
done

[ "$VERBOSE" = true ] && PARALLEL=false

# Fast tier — runs by default (~25s parallel, ~880s serial)
declare -a FAST_SUITES=(
    "test-core.sh:Core Commands"
    "test-violation-vocabulary.sh:Violation Vocabulary Contract"
    "test-coaching-contracts.sh:Coaching Contract Schemas"
    "test-coaching-guides.sh:Coaching Guide Assets"
    "test-coaching-fixtures.sh:Coaching Frozen Fixtures"
    "test-coaching-purity.sh:Coaching Planner Purity"
    "test-coaching-view.sh:Coaching View"
    "test-memory.sh:Graph Memory Commands"
    "test-graph.sh:Graph Commands"
    "test-data.sh:Data Commands"
    "test-commit-refs.sh:Commit-Ref Provenance Sweep"
    "test-health.sh:Health Commands"
    "test-sprint2b.sh:Sprint 2b Commands"
    "test-sprint34.sh:Sprint 3+4 Commands"
    "test-stress.sh:Stress Tests"
    "test-hooks.sh:Hook Tests"
    "test-codex-hooks.sh:Codex Hook Dispatch Tests"
    "test-guide-procedure.sh:Procedure Guide Contract"
    "test-procedure-contracts.sh:Procedure Contract Validation"
    "test-procedure-lifecycle.sh:Procedure Delivery Lifecycle"
    "test-procedure-e2e-lifecycle.sh:Procedure E2E Delivery Lifecycle (install + init-repo + guide)"
    "test-procedure-install-reconcile.sh:Procedure Install Reconciliation"
    "test-procedure-projection-ownership.sh:Procedure Projection Ownership + Integrity"
    "test-procedure-visibility.sh:Procedure Visibility Contract"
    "test-hook-suite-cwd.sh:Hook Suite Deleted-CWD Regression"
    "test-init-repo.sh:Init-Repo Tests"
    "test-install-ast-grep.sh:Install ast-grep Opt-in Tests"
    "test-install-file.sh:Install File Atomic-Replace Tests"
    "test-install-provenance.sh:Install Provenance Tests"
    "test-concurrent-session.sh:Concurrent Session Detection Tests"
    "test-mcp-status-scopes.sh:MCP Status Scope Tests"
    "test-crash-sentinel.sh:Crash Sentinel Tests"
    "test-multi-agent.sh:Multi-Agent Tests"
    "test-delta-unit.sh:Delta Unit Tests"
    "test-delta-v2-writer.sh:Delta v2 Writer"
    "test-delta-v2-replay.sh:Delta v2 Replay Evaluator"
    "test-delta-catalog.sh:Delta Catalog Scanner"
    "test-tombstone-reconcile.sh:Deletion Tombstone Reconcile"
    "test-delta-replay-order.sh:Delta Replay Lineage Ordering"
    "test-cutover.sh:Causal Cutover Marker"
    "test-checkpoint-generation.sh:Checkpoint Generation Builder"
    "test-analyze.sh:Analyze Command Tests"
    "test-config.sh:Config Command Tests"
    "test-query.sh:Query Command Tests"
    "test-pattern-audit-check1.sh:Pattern-Audit Check 1 (cache classification, self-reference)"
    "test-pattern-audit-check6.sh:Pattern-Audit Check 6 (node-state invariant)"
    "test-pattern-audit-check7.sh:Pattern-Audit Check 7 (function tails)"
    "test-pattern-audit-check8.sh:Pattern-Audit Check 8 (quality DB owner)"
    "test-pattern-audit-check9.sh:Pattern-Audit Check 9 (memory authority owner)"
    "test-doctor-pattern-shadow.sh:Doctor Managed-Pattern-Rule Shadow Advisory"
    "test-doctor-closed-node-dirt.sh:Doctor Closed-Node Uncommitted-Dirt Attribution"
    "test-doctor-managed-pattern-completeness.sh:Doctor Managed-Pattern Completeness Advisory"
    "test-cmd-battery.sh:Command-Surface Battery"
    "test-schema-contract.sh:SQL-vs-Schema Contract"
    "test-mcp-parity.sh:MCP-vs-CLI Flag Parity"
    "test-agent-identity-parity.sh:Cross-Harness Agent-Identity Parity"
    "test-command-capabilities.sh:Command Capability Registry"
    "test-causal-identity.sh:Composite Causal Identity"
    "test-attempt-journal.sh:Attempt Journal"
    "test-telemetry-normalization.sh:Call-Log Operation Normalization"
    "test-output-budget.sh:Output Budget Golden Tests"
    "test-ipc-contract.sh:IPC Contract Validation"
    # Thirteen suites shipped to consumers with no aggregate -- source or
    # projection -- ever running them. Every one of them tests a shipped
    # surface, so all thirteen are classified retained-and-run rather than
    # stripped. test-durability.sh had been failing on a real defect the whole
    # time (the delta changeset was published before the state.sql rename that
    # acknowledges durability, so a refused acknowledgement was undone by
    # replay). release_aggregate.py now compares the projection's test files
    # against this list as SETS, so a suite added to tests/ and to neither
    # this list nor a build-release.sh strip list fails the release build.
    "test-assert-helper-safety.sh:Assertion Helper Option-Barrier Safety"
    "test-cache-invalidation.sh:Context Cache Invalidation"
    "test-durability.sh:Durable Execution and Recovery"
    "test-gh-issue-body-bug.sh:Parent-Add Child-ID Regression"
    "test-hook-common.sh:Shared Hook Library"
    "test-hook-dispatch.sh:Host-Neutral Hook Dispatch"
    "test-journal.sh:Operation Journal"
    "test-phase-fsm.sh:Session Phase State Machine"
    "test-quality.sh:Quality Scan and Reset"
    "test-test-hook-registry.sh:Production Fault-Injection Hook Inventory"
    "test-validate-finding.sh:Validate-Finding Golden Fixtures"
    "test-workflow-manifest.sh:Workflow Manifest Projections"
    "test-wv-flag-normalization.sh:Canonical Flag Telemetry Normalization"
)

# Slow tier — excluded by default; add with --slow (~200s, runs install+selftest)
declare -a SLOW_SUITES=(
)

declare -a SUITES=("${FAST_SUITES[@]}")
if [ "$INCLUDE_SLOW" = true ]; then
    SUITES+=("${SLOW_SUITES[@]}")
fi

# Results tracking
declare -A RESULTS
declare -A TIMES
TOTAL_PASSED=0
TOTAL_TESTS=0
FAILED_SUITES=()
# Suites this run actually EXECUTED, as opposed to the ones it declares. The
# release compares this set against the projection's test files, because the
# membership check upstream reads the declarations in this file and a runner
# that declares a suite and never runs it satisfies that check completely --
EXECUTED_SUITES=()

echo "═══════════════════════════════════════════════════════════════════════════"
echo -e "${CYAN}Weave CLI Test Suite${NC}"
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""

run_suite() {
    local script="$1"
    local name="$2"
    local start_time end_time duration
    local output exit_code
    
    start_time=$(date +%s)
    
    local passed tests
    if [ "$VERBOSE" = true ]; then
        echo -e "${CYAN}Running: $name${NC}"
        echo "─────────────────────────────────────────────────────────────────────────────"
        output=$(bash "$SCRIPT_DIR/$script" 2>&1) && exit_code=0 || exit_code=$?
        echo "$output"
        echo ""
    else
        output=$(bash "$SCRIPT_DIR/$script" 2>&1) && exit_code=0 || exit_code=$?
    fi
    EXECUTED_SUITES+=("$script")

    end_time=$(date +%s)
    duration=$((end_time - start_time))
    
    # Extract test counts from output (strip ANSI codes first).
    # Prefer "Results: X/Y passed" over "Tests: X | Passed: X | Failed: Y" —
    # tail -1 on the latter picks up "Failed: 0" as the test count.
    local clean_output
    clean_output=$(printf '%s' "$output" | sed 's/\x1b\[[0-9;]*m//g')
    if grep -qE "[0-9]+/[0-9]+ passed" <<<"$clean_output"; then
        local result_line result_numbers
        result_line=$(grep -E "[0-9]+/[0-9]+ passed" <<<"$clean_output" | tail -1)
        result_numbers=$(grep -oE '[0-9]+' <<<"$result_line")
        passed=${result_numbers%%$'\n'*}
        tests=$(sed -n '2p' <<<"$result_numbers")
    else
        passed=0
        tests=0
    fi
    
    RESULTS["$script"]="$passed/$tests"
    TIMES["$script"]="$duration"
    TOTAL_PASSED=$((TOTAL_PASSED + passed))
    TOTAL_TESTS=$((TOTAL_TESTS + tests))
    
    if [ "${exit_code:-0}" -ne 0 ]; then
        FAILED_SUITES+=("$name")
        echo -e "  ${RED}✗${NC} $name: $passed/$tests tests (${duration}s)"
        if [ "$VERBOSE" != true ]; then
            # Show failure output. awk, not `grep | head`: head leaves after ten
            # lines and the SIGPIPE that kills grep is this runner's own status
            # under `set -euo pipefail`, so reporting a failure could abort the
            # run that was reporting it.
            awk '/✗|FAIL|Error/ && shown < 10 { print "    " $0; shown++ }' <<<"$clean_output"
        fi
    else
        echo -e "  ${GREEN}✓${NC} $name: $passed/$tests tests (${duration}s)"
    fi
}

# Filter suites if requested
if [ -n "$SUITE_FILTER" ]; then
    FILTERED_SUITES=()
    for suite in "${SUITES[@]}"; do
        script="${suite%%:*}"
        name="${suite#*:}"
        if [[ "$script" == *"$SUITE_FILTER"* ]] || [[ "$name" == *"$SUITE_FILTER"* ]]; then
            FILTERED_SUITES+=("$suite")
        fi
    done
    if [ ${#FILTERED_SUITES[@]} -eq 0 ]; then
        echo -e "${RED}Error: No suites match '$SUITE_FILTER'${NC}"
        exit 1
    fi
    SUITES=("${FILTERED_SUITES[@]}")
fi

# Run suites
START_TIME=$(date +%s)

if [ "$PARALLEL" = true ]; then
    # Suites create isolated databases and temporary Git repositories. Launching
    # every suite at once exhausts sandbox resources and causes mid-suite exits.
    MAX_PARALLEL="${WV_TEST_JOBS:-4}"
    if ! [[ "$MAX_PARALLEL" =~ ^[1-9][0-9]*$ ]]; then
        echo -e "${RED}Error: WV_TEST_JOBS must be a positive integer${NC}" >&2
        exit 2
    fi
    echo -e "${YELLOW}Running ${#SUITES[@]} test suites in batches of $MAX_PARALLEL...${NC}"
    echo ""

    # Run bounded batches so resource-heavy suites cannot starve one another.
    run_id=$$
    for ((batch_start=0; batch_start<${#SUITES[@]}; batch_start+=MAX_PARALLEL)); do
        declare -a PIDS=()
        batch_end=$((batch_start + MAX_PARALLEL))
        [ "$batch_end" -gt "${#SUITES[@]}" ] && batch_end="${#SUITES[@]}"

        for ((i=batch_start; i<batch_end; i++)); do
            script="${SUITES[$i]%%:*}"
            (bash "$SCRIPT_DIR/$script" > "/tmp/wv-test-${run_id}-$script.out" 2>&1) &
            PIDS+=($!)
        done

        for ((i=batch_start; i<batch_end; i++)); do
            suite="${SUITES[$i]}"
            script="${suite%%:*}"
            name="${suite#*:}"
            pid="${PIDS[$((i - batch_start))]}"

            wait "$pid" && exit_code=0 || exit_code=$?
            EXECUTED_SUITES+=("$script")

            suite_log="/tmp/wv-test-${run_id}-$script.out"
            output=$(cat "$suite_log" 2>/dev/null || echo "")

            # Parse results (strip ANSI codes first). Normalize once, then match
            # on herestrings: `echo "$x" | grep -q` lets grep leave at its first
            # match while the writer is still writing, and the SIGPIPE that
            # follows becomes the pipeline's status under `set -o pipefail`.
            clean_output=$(printf '%s' "$output" | sed 's/\x1b\[[0-9;]*m//g')
            if grep -qE "[0-9]+/[0-9]+ passed" <<<"$clean_output"; then
                result_line=$(grep -E "[0-9]+/[0-9]+ passed" <<<"$clean_output" | tail -1)
                result_numbers=$(grep -oE '[0-9]+' <<<"$result_line")
                passed=${result_numbers%%$'\n'*}
                tests=$(sed -n '2p' <<<"$result_numbers")
            else
                passed=0
                tests=0
            fi

            TOTAL_PASSED=$((TOTAL_PASSED + passed))
            TOTAL_TESTS=$((TOTAL_TESTS + tests))

            if [ "$exit_code" -ne 0 ]; then
                FAILED_SUITES+=("$name")
                echo -e "  ${RED}✗${NC} $name: $passed/$tests tests"
                # A COUNT IS NOT A DIAGNOSIS. This deleted the suite's output and
                # printed only "45/46", so a single failing assertion inside a
                # release --verify could not be identified afterwards at all --
                # and a one-assertion failure is exactly the shape a flake takes.
                # The failing suite's full output is kept, and its failure lines
                # are shown here as the serial path already does. awk rather than
                # `grep | head`, because a reader that leaves early is the bug
                # this whole change is about.
                awk '/✗|FAIL|Error/ && shown < 10 { print "    " $0; shown++ }' <<<"$clean_output"
                failed_log="${WV_TEST_FAILED_LOG_DIR:-/tmp}/wv-test-failed-${run_id}-$script.out"
                if mv "$suite_log" "$failed_log" 2>/dev/null; then
                    echo "    full output: $failed_log"
                fi
            else
                echo -e "  ${GREEN}✓${NC} $name: $passed/$tests tests"
                rm -f "$suite_log"
            fi
        done
    done
else
    echo -e "${YELLOW}Running ${#SUITES[@]} test suites...${NC}"
    echo ""
    
    for suite in "${SUITES[@]}"; do
        script="${suite%%:*}"
        name="${suite#*:}"
        run_suite "$script" "$name"
    done
fi

END_TIME=$(date +%s)
TOTAL_TIME=$((END_TIME - START_TIME))

# Persist per-suite timing to .weave/test-times.json (serial mode only — parallel skips TIMES[])
if [ "$PARALLEL" = false ] && [ ${#TIMES[@]} -gt 0 ]; then
    _times_file="$(dirname "$SCRIPT_DIR")/.weave/test-times.json"
    _existing='{}'
    [ -f "$_times_file" ] && _existing=$(cat "$_times_file" 2>/dev/null || echo '{}')
    _updates=''
    for _script in "${!TIMES[@]}"; do
        _name=$(basename "$_script")
        _dur="${TIMES[$_script]}"
        _updates+=$(printf ',"%s":%s' "$_name" "$_dur")
    done
    # Merge: existing + updates (updates win on collision)
    printf '%s' "$_existing" | jq -r --argjson u "{${_updates#,}}" '. + $u' \
        > "$_times_file" 2>/dev/null || true
fi

# Summary
echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
echo -e "${CYAN}Summary${NC}"
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""
echo -e "  Total tests: ${GREEN}$TOTAL_PASSED${NC}/${YELLOW}$TOTAL_TESTS${NC} passed"
echo -e "  Total time:  ${TOTAL_TIME}s"
echo ""

# Machine-readable execution record. Unprefixed counts and colour make the
# summary above unreliable to parse; these lines are the contract the release
# reads. A suite appears here only if its process ran and returned a status.
echo "executed-suites-total: ${#EXECUTED_SUITES[@]}"
for _executed in "${EXECUTED_SUITES[@]}"; do
    echo "executed-suite: $_executed"
done
echo ""

if [ "$INCLUDE_SLOW" = false ] && [ ${#SLOW_SUITES[@]} -gt 0 ]; then
    echo -e "  ${YELLOW}Slow suites skipped:${NC} $(printf '%s ' "${SLOW_SUITES[@]}" | sed 's/:[^:]*//g')"
    echo -e "  Run with ${CYAN}--slow${NC} to include (adds ~200s)"
    echo ""
fi

if [ ${#FAILED_SUITES[@]} -gt 0 ]; then
    echo -e "  ${RED}Failed suites:${NC}"
    for suite in "${FAILED_SUITES[@]}"; do
        echo -e "    - $suite"
    done
    echo ""
    echo -e "${RED}FAILED${NC}"
    exit 1
else
    echo -e "${GREEN}ALL TESTS PASSED${NC}"
    exit 0
fi
