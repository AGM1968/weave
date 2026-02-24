#!/bin/bash
# run-all.sh — Master test runner for Weave CLI tests
#
# Run: bash tests/run-all.sh
# Exit: 0 if all suites pass, 1 if any fail
#
# Options:
#   --verbose    Show individual test output
#   --parallel   Run test suites in parallel (faster but interleaved output)
#   --suite=X    Run only specific suite (core, graph, data, health)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Options
VERBOSE=false
PARALLEL=false
SUITE_FILTER=""

while [ $# -gt 0 ]; do
    case "$1" in
        --verbose|-v) VERBOSE=true ;;
        --parallel|-p) PARALLEL=true ;;
        --suite=*) SUITE_FILTER="${1#*=}" ;;
        --help|-h)
            echo "Usage: $0 [--verbose] [--parallel] [--suite=NAME]"
            echo ""
            echo "Options:"
            echo "  --verbose, -v   Show individual test output"
            echo "  --parallel, -p  Run test suites in parallel"
            echo "  --suite=NAME    Run only specific suite (core, graph, data, health)"
            exit 0
            ;;
    esac
    shift
done

# Test suites
declare -a SUITES=(
    "test-core.sh:Core Commands"
    "test-graph.sh:Graph Commands"
    "test-data.sh:Data Commands"
    "test-health.sh:Health Commands"
    "test-sprint2b.sh:Sprint 2b Commands"
    "test-sprint34.sh:Sprint 3+4 Commands"
    "test-stress.sh:Stress Tests"
    "test-hooks.sh:Hook Tests"
)

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
    
    if [ "$VERBOSE" = true ]; then
        echo -e "${CYAN}Running: $name${NC}"
        echo "─────────────────────────────────────────────────────────────────────────────"
        bash "$SCRIPT_DIR/$script" 2>&1
        exit_code=$?
        echo ""
    else
        output=$(bash "$SCRIPT_DIR/$script" 2>&1) || exit_code=$?
        exit_code=${exit_code:-0}
    fi
    
    end_time=$(date +%s)
    duration=$((end_time - start_time))
    
    # Parse results from output
    local passed tests
    if [ "$VERBOSE" = true ]; then
        # Re-run to capture output for parsing (inefficient but works)
        output=$(bash "$SCRIPT_DIR/$script" 2>&1) || true
    fi
    
    # Extract test counts from output (strip ANSI codes first)
    local clean_output
    clean_output=$(echo "$output" | sed 's/\x1b\[[0-9;]*m//g')
    if echo "$clean_output" | grep -qE "Results:|Tests:"; then
        local result_line
        result_line=$(echo "$clean_output" | grep -E "Results:|Tests:" | tail -1)
        passed=$(echo "$result_line" | grep -oE '[0-9]+' | head -1)
        tests=$(echo "$result_line" | grep -oE '[0-9]+' | tail -1)
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
    echo -e "${YELLOW}Running ${#SUITES[@]} test suites in parallel...${NC}"
    echo ""
    
    # Run all suites in background
    declare -a PIDS
    for suite in "${SUITES[@]}"; do
        script="${suite%%:*}"
        (bash "$SCRIPT_DIR/$script" > "/tmp/wv-test-$script.out" 2>&1) &
        PIDS+=($!)
    done
    
    # Wait for all to complete
    for i in "${!SUITES[@]}"; do
        suite="${SUITES[$i]}"
        script="${suite%%:*}"
        name="${suite#*:}"
        pid="${PIDS[$i]}"
        
        wait "$pid" || true
        exit_code=$?
        
        output=$(cat "/tmp/wv-test-$script.out" 2>/dev/null || echo "")
        rm -f "/tmp/wv-test-$script.out"
        
        # Parse results (strip ANSI codes first)
        clean_output=$(echo "$output" | sed 's/\x1b\[[0-9;]*m//g')
        if echo "$clean_output" | grep -qE "Results:|Tests:"; then
            result_line=$(echo "$clean_output" | grep -E "Results:|Tests:" | tail -1)
            passed=$(echo "$result_line" | grep -oE '[0-9]+' | head -1)
            tests=$(echo "$result_line" | grep -oE '[0-9]+' | tail -1)
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

# Summary
echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
echo -e "${CYAN}Summary${NC}"
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""
echo -e "  Total tests: ${GREEN}$TOTAL_PASSED${NC}/${YELLOW}$TOTAL_TESTS${NC} passed"
echo -e "  Total time:  ${TOTAL_TIME}s"
echo ""

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
