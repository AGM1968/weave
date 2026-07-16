#!/bin/bash
# run-all.sh — Master test runner for Weave CLI tests
#
# Run: bash tests/run-all.sh             (parallel, fast tier — ~400s wall time)
#      bash tests/run-all.sh --serial    (serial, for readable output)
#      bash tests/run-all.sh --slow      (include test-release.sh — ~600s)
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
            echo "  --slow          Include slow integration suites (test-release.sh ~200s)"
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
    "test-memory.sh:Graph Memory Commands"
    "test-graph.sh:Graph Commands"
    "test-data.sh:Data Commands"
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
    "test-release-procedures.sh:Release Artifact Procedure Stripping"
    "test-hook-suite-cwd.sh:Hook Suite Deleted-CWD Regression"
    "test-init-repo.sh:Init-Repo Tests"
    "test-install-ast-grep.sh:Install ast-grep Opt-in Tests"
    "test-install-file.sh:Install File Atomic-Replace Tests"
    "test-concurrent-session.sh:Concurrent Session Detection Tests"
    "test-workflow-surfaces.sh:Workflow Surface Tests"
    "test-crash-sentinel.sh:Crash Sentinel Tests"
    "test-multi-agent.sh:Multi-Agent Tests"
    "test-delta-unit.sh:Delta Unit Tests"
    "test-delta-catalog.sh:Delta Catalog Scanner"
    "test-checkpoint-generation.sh:Checkpoint Generation Builder"
    "test-battery-wrapper.sh:Tier2 Battery Wrapper Security (gap3)"
    "test-analyze.sh:Analyze Command Tests"
    "test-config.sh:Config Command Tests"
    "test-query.sh:Query Command Tests"
    "test-pattern-audit-check1.sh:Pattern-Audit Check 1 (cache classification, self-reference)"
    "test-pattern-audit-check6.sh:Pattern-Audit Check 6 (node-state invariant)"
    "test-pattern-audit-check7.sh:Pattern-Audit Check 7 (function tails)"
    "test-pattern-audit-check8.sh:Pattern-Audit Check 8 (quality DB owner)"
    "test-pattern-audit-check9.sh:Pattern-Audit Check 9 (memory authority owner)"
    "test-cmd-battery.sh:Command-Surface Battery"
    "test-schema-contract.sh:SQL-vs-Schema Contract"
    "test-mcp-parity.sh:MCP-vs-CLI Flag Parity"
    "test-output-budget.sh:Output Budget Golden Tests"
    "test-ipc-contract.sh:IPC Contract Validation"
)

# Slow tier — excluded by default; add with --slow (~200s, runs install+selftest)
declare -a SLOW_SUITES=(
    "test-release.sh:Release Tests"
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

    end_time=$(date +%s)
    duration=$((end_time - start_time))
    
    # Extract test counts from output (strip ANSI codes first).
    # Prefer "Results: X/Y passed" over "Tests: X | Passed: X | Failed: Y" —
    # tail -1 on the latter picks up "Failed: 0" as the test count.
    local clean_output
    clean_output=$(echo "$output" | sed 's/\x1b\[[0-9;]*m//g')
    if echo "$clean_output" | grep -qE "[0-9]+/[0-9]+ passed"; then
        local result_line
        result_line=$(echo "$clean_output" | grep -E "[0-9]+/[0-9]+ passed" | tail -1)
        passed=$(echo "$result_line" | grep -oE '[0-9]+' | head -1)
        tests=$(echo "$result_line" | grep -oE '[0-9]+' | sed -n '2p')
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
            # Show failure output
            echo "$output" | grep -E "✗|FAIL|Error" | head -10 | sed 's/^/    /'
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

            output=$(cat "/tmp/wv-test-${run_id}-$script.out" 2>/dev/null || echo "")
            rm -f "/tmp/wv-test-${run_id}-$script.out"
        
        # Parse results (strip ANSI codes first)
            clean_output=$(echo "$output" | sed 's/\x1b\[[0-9;]*m//g')
            if echo "$clean_output" | grep -qE "[0-9]+/[0-9]+ passed"; then
                result_line=$(echo "$clean_output" | grep -E "[0-9]+/[0-9]+ passed" | tail -1)
                passed=$(echo "$result_line" | grep -oE '[0-9]+' | head -1)
                tests=$(echo "$result_line" | grep -oE '[0-9]+' | sed -n '2p')
            else
                passed=0
                tests=0
            fi
        
            TOTAL_PASSED=$((TOTAL_PASSED + passed))
            TOTAL_TESTS=$((TOTAL_TESTS + tests))
        
            if [ "$exit_code" -ne 0 ]; then
                FAILED_SUITES+=("$name")
                echo -e "  ${RED}✗${NC} $name: $passed/$tests tests"
            else
                echo -e "  ${GREEN}✓${NC} $name: $passed/$tests tests"
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
