#!/bin/bash
# run-all.sh — Master test runner for Weave CLI tests
#
# Run: bash tests/run-all.sh             (parallel, fast tier — ~400s wall time)
#      bash tests/run-all.sh --serial    (serial, for readable output)
#      bash tests/run-all.sh --suite=X   (single suite by name fragment)
# Exit: 0 if all suites pass, 1 if any fail

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Tag suite-driven wv calls so call-stats can separate them from real traffic,
# and keep them out of the user's durable call log: under WV_TEST_SUITE=1 the
# user's config.env cannot enable WV_CALL_LOG (wv-6b0f57). Each suite exports
# the marker itself too, for when it runs on its own.
export WV_CALL_SOURCE=test WV_TEST_SUITE=1

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
    "test-scratch-resources.sh:Scratch Capacity and Ownership"
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
    "test-lifecycle-hooks-adverse.sh:Lifecycle Hooks Under Adverse Conditions"
    "test-hook-parity.sh:Claude/Codex Hook Parity Tests"
    "test-guide-procedure.sh:Procedure Guide Contract"
    "test-procedure-contracts.sh:Procedure Contract Validation"
    "test-procedure-lifecycle.sh:Procedure Delivery Lifecycle"
    "test-procedure-e2e-lifecycle.sh:Procedure E2E Delivery Lifecycle (install + init-repo + guide)"
    "test-procedure-install-reconcile.sh:Procedure Install Reconciliation"
    "test-procedure-projection-ownership.sh:Procedure Projection Ownership + Integrity"
    "test-procedure-visibility.sh:Procedure Visibility Contract"
    "test-repo-procedures.sh:Repository-Owned Procedures"
    "test-hook-suite-cwd.sh:Hook Suite Deleted-CWD Regression"
    "test-hook-stale-copy.sh:Git Hook Stale-Copy Guard"
    "test-hook-duration.sh:Git Hook Duration Helper"
    "test-hook-body-ratchet.sh:The Pre-commit Hook Body Only Shrinks"
    "test-test-line-ratchet.sh:Net Test Lines Are Reported, Never Refused"
    "test-init-repo.sh:Init-Repo Tests"
    "test-install-ast-grep.sh:Install ast-grep Opt-in Tests"
    "test-install-file.sh:Install File Atomic-Replace Tests"
    "test-install-provenance.sh:Install Provenance Tests"
    "test-concurrent-session.sh:Concurrent Session Detection Tests"
    "test-shared-checkout-claim.sh:Shared Checkout Claim Tests"
    "test-zone-write-lock.sh:Zone Write Lock Tests"
    "test-mcp-status-scopes.sh:MCP Status Scope Tests"
    "test-crash-sentinel.sh:Crash Sentinel Tests"
    "test-multi-agent.sh:Multi-Agent Tests"
    "test-delta-unit.sh:Delta Unit Tests"
    "test-delta-v2-writer.sh:Delta v2 Writer"
    "test-delta-v2-replay.sh:Delta v2 Replay Evaluator"
    "test-delta-v2-replay-argv.sh:Delta v2 Replay Argv on Python 3.11"
    "test-delta-v2-replay-validation.sh:Delta v2 Replay Edge Field Validation"
    "test-stage-b-ruling-a.sh:Stage B Ruling A (creates and patches never deletable)"
    "test-delta-catalog.sh:Delta Catalog Scanner"
    "test-tombstone-reconcile.sh:Deletion Tombstone Reconcile"
    "test-removal-redump.sh:Delete/Prune Re-dump Guards"
    "test-delta-replay-order.sh:Delta Replay Lineage Ordering"
    "test-load-fts-rebuild.sh:Load Re-derives nodes_fts After Replay"
    "test-load-v1-replay-branch.sh:Load v1 Replay Success/Failure Branch"
    "test-precommit-selfheal-isolation.sh:Pre-commit Self-heal Skips Test Runs"
    "test-context-policy.sh:Context Load Policy Command"
    "test-metadata-canonical-numbers.sh:Metadata Numbers Are Canonical Integers"
    "test-update-arg-forms.sh:Update Applies or Refuses Every Argument"
    "test-lib-guards.sh:Lib Guards the Routed Suites Missed"
    "test-hot-zone-base.sh:Hot-zone Bases Another User Could Control Are Refused"
    "test-session-index-trigger.sh:Session Start Rebuilds An Empty Code Index"
    "test-hot-zone-placement.sh:Hot-zone Placement Adopts the Zone Holding the Database"
    "test-hot-zone-migrate.sh:Hot-zone Migrate Relocates the /tmp Zone Behind a Fence"
    "test-hot-zone-gc.sh:Hot-zone GC Deletes Only Zones Whose Repository Is Known Gone"
    "test-bash-guard.sh:Executed Entry Points Run Under Bash 4 or Refuse"
    "test-fts5-required.sh:A sqlite3 Without FTS5 Is Refused, Never Half-Initialised"
    "test-hot-zone-reconcile.sh:Divergent Copies of One Graph Are Reconciled Before Removal"
    "test-gate-zone-guard.sh:The Gate Fails a Suite That Leaks Into the Live Hot Zone"
    "test-cli-guards.sh:CLI Guards the Routed Suites Missed"
    "test-cli-unknown-args.sh:Write Paths Refuse Unknown Arguments"
    "test-budget-location.sh:Call Tally Lands Where Hygiene Reads It"
    "test-install-skill-prune.sh:Install Prunes Skills It No Longer Ships"
    "test-cutover.sh:Causal Cutover Marker"
    "test-delta-retention.sh:Delta Retention Stage A (compact --pre-cutover)"
    "test-delta-writer-fence.sh:State.sql Writers Fenced Against a Pre-Compaction Database"
    "test-delta-load-ack.sh:Load Acknowledged Only After a Fully Applied Load"
    "test-load-receipt.sh:Load Skipped Only When the Hot Zone Holds .weave/"
    "test-stranded-closes.sh:Doctor Names Closes Main Has Not Committed"
    "test-edit-guard-budget.sh:Edit Guard Judges Within Its Wait Budget"
    "test-uncovered-paths.sh:Staged Files No Route Covers Are Named"
    "test-graph-persistence-ux.sh:Writes Publish Deltas; Branch Switch and Trails Merge Keep the Graph"
    "test-clone-roster.sh:Clone Roster Accounts For Every Catalog Writer"
    "test-lineage-publish.sh:Live Graph Equals Its Reload After Claim and Delete"
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
    "test-doctor-hotzone-shadow.sh:Doctor Hot-Zone Shadow Advisory"
    "test-doctor-delta-v2-catalog.sh:Doctor Delta v2 Catalog Integrity"
    "test-memory-exposure.sh:Memory Exposure: Graph-Only Versus Rendered"
    "test-skill-provenance.sh:Skill Provenance: Adopt Weave's Own Unmarked Copies"
    "test-skill-retirement.sh:Skill Retirement: Remove Weave's Own Retired Copies"
    "test-doctor-closed-node-dirt.sh:Doctor Closed-Node Uncommitted-Dirt Attribution"
    "test-doctor-managed-pattern-completeness.sh:Doctor Managed-Pattern Completeness Advisory"
    "test-doctor-codex-trust.sh:Doctor Codex Hook Trust"
    "test-doctor-guides.sh:Doctor Guide Validity and Completeness"
    "test-cmd-battery.sh:Command-Surface Battery"
    "test-schema-contract.sh:SQL-vs-Schema Contract"
    "test-citation-drift.sh:Doc Citation Drift"
    "test-policy-contract.sh:Policy Rules Contract"
    "test-risk-level-authority.sh:risk_level Authority"
    "test-status-authority.sh:status Authority"
    "test-node-kind.sh:Node Kind Authority"
    "test-edge-invariants.sh:Edge Invariants"
    "test-unblock-recompute.sh:Unblock Recompute on Edge Removal"
    "test-worktree-hook-checkout.sh:Hooks Judge the Command Checkout"
    "test-suite-cost-identity.sh:One Suite Cost Keyed by Repository"
    "test-bash-lock-session.sh:Duplicate-Command Lock per Session"
    "test-mcp-version-handshake.sh:MCP Rebuild and Version Handshake"
    "test-merge-driver-fresh-clone.sh:Merge Drivers in a Fresh Clone"
    "test-self-host-markers.sh:Committed Gate and Installer Markers"
    "test-db-size-guard.sh:DB Size Guard"
    "test-quick-commit-hook.sh:Quick Commit Under Hook"
    "test-close-time.sh:Derived Close Time"
    "test-done-staged-work.sh:Done Over Staged Work"
    "test-worktree-guidance.sh:Worktree Guidance"
    "test-gate-provisioning-report.sh:Gate Provisioning Report"
    "test-provision-retirement.sh:Provisioning Retirement"
    "test-checkpoint-push-race.sh:Checkpoint Push Race"
    "test-projection-verdict.sh:Committed Snapshot Covers Its Operations"
    "test-work-claim-persistence.sh:Claim Persistence"
    "test-session-identity-claims.sh:Session Identity Claims"
    "test-session-local-state.sh:Session-Local State"
    "test-session-acceptance.sh:Session Acceptance"
    "test-run-all-counts.sh:Aggregate Test Counts"
    "test-gate-measure.sh:Gate Measurement"
    "test-policy-gates.sh:Command Gate Verdicts"
    "test-policy-cells.sh:Policy Rule Cells"
    "test-policy-countable.sh:Clean Calls Countable"
    "test-policy-hooks.sh:Policy Host-Hook Cells"
    "test-policy-totality.sh:Policy Totality"
    "test-mcp-parity.sh:MCP-vs-CLI Flag Parity"
    "test-agent-identity-parity.sh:Cross-Harness Agent-Identity Parity"
    "test-command-capabilities.sh:Command Capability Registry"
    "test-causal-identity.sh:Composite Causal Identity"
    "test-attempt-journal.sh:Attempt Journal"
    "test-telemetry-normalization.sh:Call-Log Operation Normalization"
    "test-errexit-dispatch.sh:Errexit Dispatch Parity"
    "test-autosync-visibility.sh:Auto-Sync Failure Visibility"
    "test-durability-refusal.sh:Durability Refusal Surface"
    "test-health-writability.sh:Health Writability Probe"
    "test-edge-enum-lineage.sh:Edge Enum Rebuild Lineage Preservation"
    "test-db-ensure-memo.sh:db_ensure Per-Process Memo"
    "test-prepush-gate.sh:Two-Tier Commit Gate (pre-push heavy tier)"
    "test-gate-input-reuse.sh:Input-Keyed Suite Reuse"
    "test-gate-snapshot.sh:Frozen Gate Candidate"
    "test-protected-dispatcher.sh:Protected Dispatcher"
    "test-potu-route-advisory.sh:Edit Advisory For A Suite Under Route Evidence"
    "test-gate-hold.sh:One Gate At A Time Per Checkout"
    "test-wv-clock.sh:Durations On A Declared Clock"
    "test-gate-hold-hooks.sh:The Git Hooks Take The Per-Checkout Gate Lock"
    "test-prune-bulk-tombstones.sh:A Large Prune Keeps Its Tombstones"
    "test-prune-policy.sh:A Prune Is Explicit And Keeps What Live Work Cites"
    "test-graph-credentials.sh:Graph Text Refuses Credentials"
    "test-load-ack-visibility.sh:An Unacknowledged Graph Load Is Loud"
    "test-checkpoint-ff-only.sh:An Auto-Checkpoint Never Rewrites History"
    "test-gate-lanes.sh:Gate Candidate Lanes"
    "test-gate-roles.sh:Gate Role Contract"
    "test-gate-pool-order.sh:Gate Pool Launch Order And Lane Shares"
    "test-shellcheck-gate.sh:Shellcheck Gate Policy Transitions"
    "test-resolver-failure.sh:Suite Resolver Failure"
    "test-assert-continue.sh:Assertions Never Abort A Suite"
    "test-cli-autoload.sh:CLI Command-Module Autoload"
    "test-source-drift.sh:Install Source Drift Detection"
    "test-doctor-modules.sh:Doctor Derived Module Checks"
    "test-lineage-stamp-recovery.sh:Lineage Stamp Failure Routing"
    "test-load-dropped-nodes.sh:Load Dropped-Node Reporting"
    "test-load-swap.sh:Live Database Changes Only Through SQLite"
    "test-node-reconstruction.sh:Node Reconstruction Under A Lost Id"
    "test-build-identity.sh:Build Identity In --version"
    "test-reserved-slot-guard.sh:Reserved Counted-Capture Slot Guard"
    "test-work-retires-sweep.sh:Claim-Time Retires Reference Sweep"
    "test-call-log-rotation.sh:Call-Log Rotation"
    "test-analyze-window.sh:Analyze Window Bounding"
    # On disk since the conservation baseline landed, named by no aggregate
    # and by no skip line, so it ran only when the impact gate happened to
    # select it (wv-30cfe8). 1.8s, offline, no opt-in reason.
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
    "test-unreadable-graph.sh:Unreadable Graph Is Not Reported"
    "test-hook-common.sh:Shared Hook Library"
    "test-hook-dispatch.sh:Host-Neutral Hook Dispatch"
    "test-consumer-shellcheck.sh:Vendored Shell Files Under Consumer Lint"
    "test-git-hook-install.sh:Git Hooks Install Where Git Runs Them"
    "test-journal.sh:Operation Journal"
    "test-phase-fsm.sh:Session Phase State Machine"
    "test-quality.sh:Quality Scan and Reset"
    "test-quality-exempt-links.sh:Quality Exemptions Name Their Node"
    "test-test-hook-registry.sh:Production Fault-Injection Hook Inventory"
    "test-validate-finding.sh:Validate-Finding Golden Fixtures"
    "test-workflow-manifest.sh:Workflow Manifest Projections"
    "test-wv-flag-normalization.sh:Canonical Flag Telemetry Normalization"
)

# Slow tier — excluded by default; add with --slow (~200s, runs install+selftest)
declare -a SLOW_SUITES=(
)

# Declared-and-never-run. This array executes nothing; it exists so that a
# suite which deliberately does not run is STATED rather than merely absent,
# and so that the release-closure guard can insist every tests/test-*.sh is
# run, slow, or here. An entry must also be excluded from the release: a suite
# this repository declines to run must not ship to a consumer who would run it.
declare -a UNRUN_SUITES=(
    # Routing shims for .weave/test-map.conf (wv-75d9c5): the pytest they run is
    # make test's, so running them here would run it twice. Dev-only in the release.
)

declare -a SUITES=("${FAST_SUITES[@]}")
if [ "$INCLUDE_SLOW" = true ]; then
    SUITES+=("${SLOW_SUITES[@]}")
fi

# Results tracking
declare -A RESULTS
# Suites that ran but print no parseable test count (wv-40c851). They are
# named, never folded into the total as 0/0, which silently understated it.
UNCOUNTED_SUITES=()

# _suite_counts <clean-output>: set PARSED_PASSED/PARSED_TESTS from a suite's
# own summary; return 1 when it printed none. Two formats are in use:
# "Results: X/Y passed" and "Tests: N | Passed: P | Failed: F".
# Suite output is bytes, not text: a suite may print non-UTF-8 (wv-ab04dd), and
# macOS grep/sed/awk then error or read it as binary under a UTF-8 locale. Every
# reader of suite output in this file runs under LC_ALL=C; the suites do not.
_suite_counts() {
    local out="$1" line numbers
    local -x LC_ALL=C
    if grep -qE "[0-9]+/[0-9]+ passed" <<<"$out"; then
        line=$(grep -E "[0-9]+/[0-9]+ passed" <<<"$out" | tail -1)
        numbers=$(grep -oE '[0-9]+' <<<"$line")
        PARSED_PASSED=${numbers%%$'\n'*}
        PARSED_TESTS=$(sed -n '2p' <<<"$numbers")
        return 0
    fi
    if grep -qE "Tests: *[0-9]+ *\| *Passed: *[0-9]+" <<<"$out"; then
        line=$(grep -E "Tests: *[0-9]+ *\| *Passed: *[0-9]+" <<<"$out" | tail -1)
        PARSED_TESTS=$(sed -E 's/.*Tests: *([0-9]+).*/\1/' <<<"$line")
        PARSED_PASSED=$(sed -E 's/.*Passed: *([0-9]+).*/\1/' <<<"$line")
        return 0
    fi
    PARSED_PASSED=0
    PARSED_TESTS=0
    return 1
}
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
        output=$(BASH_ENV="$SUITE_BASH_ENV" bash "$SCRIPT_DIR/$script" 2>&1) && exit_code=0 || exit_code=$?
        echo "$output"
        echo ""
    else
        output=$(BASH_ENV="$SUITE_BASH_ENV" bash "$SCRIPT_DIR/$script" 2>&1) && exit_code=0 || exit_code=$?
    fi
    EXECUTED_SUITES+=("$script")

    end_time=$(date +%s)
    duration=$((end_time - start_time))
    
    # Extract test counts from output (strip ANSI codes first).
    # Prefer "Results: X/Y passed" over "Tests: X | Passed: X | Failed: Y" —
    # tail -1 on the latter picks up "Failed: 0" as the test count.
    local clean_output
    clean_output=$(printf '%s' "$output" | LC_ALL=C sed $'s/\e\\[[0-9;]*m//g')
    local counted=true
    _suite_counts "$clean_output" || { counted=false; UNCOUNTED_SUITES+=("$script"); }
    passed=$PARSED_PASSED
    tests=$PARSED_TESTS
    local count_label="$passed/$tests tests"
    [ "$counted" = true ] || count_label="no test count"

    RESULTS["$script"]="$passed/$tests"
    TOTAL_PASSED=$((TOTAL_PASSED + passed))
    TOTAL_TESTS=$((TOTAL_TESTS + tests))
    
    if [ "${exit_code:-0}" -ne 0 ]; then
        FAILED_SUITES+=("$name")
        echo -e "  ${RED}✗${NC} $name: $count_label (${duration}s)"
        if [ "$VERBOSE" != true ]; then
            # Show failure output. awk, not `grep | head`: head leaves after ten
            # lines and the SIGPIPE that kills grep is this runner's own status
            # under `set -euo pipefail`, so reporting a failure could abort the
            # run that was reporting it.
            LC_ALL=C awk '/✗|FAIL|Error/ && shown < 10 { print "    " $0; shown++ }' <<<"$clean_output"
        fi
    else
        echo -e "  ${GREEN}✓${NC} $name: $count_label (${duration}s)"
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

# Each suite starts with tests/lib/errexit-report.sh sourced, so one that
# errexit ends names its file, line, exit code and command (wv-f03855).
SUITE_BASH_ENV="$SCRIPT_DIR/lib/errexit-report.sh"
[ -f "$SUITE_BASH_ENV" ] || { echo -e "${RED}Error: $SUITE_BASH_ENV is missing${NC}" >&2; exit 2; }

# Run suites
RUN_SCRATCH=$(bash "$SCRIPT_DIR/../scripts/lib/wv-scratch.sh")
trap 'rm -rf "$RUN_SCRATCH"' EXIT
mkdir "$RUN_SCRATCH/tmp"
export TMPDIR="$RUN_SCRATCH/tmp"
# The explicit root is consumed at the runner boundary; nested fixtures may
# choose their own TMPDIR without an outer override defeating their isolation.
unset WV_SCRATCH_ROOT
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
            (BASH_ENV="$SUITE_BASH_ENV" bash "$SCRIPT_DIR/$script" > "$RUN_SCRATCH/wv-test-${run_id}-$script.out" 2>&1) &
            PIDS+=($!)
        done

        for ((i=batch_start; i<batch_end; i++)); do
            suite="${SUITES[$i]}"
            script="${suite%%:*}"
            name="${suite#*:}"
            pid="${PIDS[$((i - batch_start))]}"

            wait "$pid" && exit_code=0 || exit_code=$?
            EXECUTED_SUITES+=("$script")

            suite_log="$RUN_SCRATCH/wv-test-${run_id}-$script.out"
            output=$(cat "$suite_log" 2>/dev/null || echo "")

            # Parse results (strip ANSI codes first). Normalize once, then match
            # on herestrings: `echo "$x" | grep -q` lets grep leave at its first
            # match while the writer is still writing, and the SIGPIPE that
            # follows becomes the pipeline's status under `set -o pipefail`.
            clean_output=$(printf '%s' "$output" | LC_ALL=C sed $'s/\e\\[[0-9;]*m//g')
            count_label=""
            if ! _suite_counts "$clean_output"; then
                UNCOUNTED_SUITES+=("$script")
                count_label="no test count"
            fi
            passed=$PARSED_PASSED
            tests=$PARSED_TESTS
            [ -n "$count_label" ] || count_label="$passed/$tests tests"

            TOTAL_PASSED=$((TOTAL_PASSED + passed))
            TOTAL_TESTS=$((TOTAL_TESTS + tests))

            if [ "$exit_code" -ne 0 ]; then
                FAILED_SUITES+=("$name")
                echo -e "  ${RED}✗${NC} $name: $count_label"
                # A COUNT IS NOT A DIAGNOSIS. This deleted the suite's output and
                # printed only "45/46", so a single failing assertion inside a
                # release --verify could not be identified afterwards at all --
                # and a one-assertion failure is exactly the shape a flake takes.
                # The failing suite's full output is kept, and its failure lines
                # are shown here as the serial path already does. awk rather than
                # `grep | head`, because a reader that leaves early is the bug
                # this whole change is about.
                LC_ALL=C awk '/✗|FAIL|Error/ && shown < 10 { print "    " $0; shown++ }' <<<"$clean_output"
                failed_log="${WV_TEST_FAILED_LOG_DIR:-$(dirname "$RUN_SCRATCH")}/wv-test-failed-${run_id}-$script.out"
                if mv "$suite_log" "$failed_log" 2>/dev/null; then
                    echo "    full output: $failed_log"
                fi
            else
                echo -e "  ${GREEN}✓${NC} $name: $count_label"
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

# Summary
echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
echo -e "${CYAN}Summary${NC}"
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""
echo -e "  Total tests: ${GREEN}$TOTAL_PASSED${NC}/${YELLOW}$TOTAL_TESTS${NC} passed"
if [ ${#UNCOUNTED_SUITES[@]} -gt 0 ]; then
    # The total above covers only suites that print a count; these ran and are
    # not in it, so they are named rather than counted as 0/0 (wv-40c851).
    echo -e "  ${YELLOW}Not in the test total${NC} (${#UNCOUNTED_SUITES[@]} suite(s) print no test count): $(printf '%s ' "${UNCOUNTED_SUITES[@]}")"
fi
echo -e "  Total time:  ${TOTAL_TIME}s"
echo ""

# Machine-readable execution record. Unprefixed counts and colour make the
# summary above unreliable to parse; these lines are the contract the release
# reads. A suite appears here only if its process ran and returned a status.
echo "executed-suites-total: ${#EXECUTED_SUITES[@]}"
for _executed in "${EXECUTED_SUITES[@]}"; do
    echo "executed-suite: $_executed"
done
echo "uncounted-suites-total: ${#UNCOUNTED_SUITES[@]}"
for _uncounted in "${UNCOUNTED_SUITES[@]}"; do
    echo "uncounted-suite: $_uncounted"
done
echo ""

if [ "$INCLUDE_SLOW" = false ] && [ ${#SLOW_SUITES[@]} -gt 0 ]; then
    echo -e "  ${YELLOW}Slow suites skipped:${NC} $(printf '%s ' "${SLOW_SUITES[@]}" | sed 's/:[^:]*//g')"
    echo -e "  Run with ${CYAN}--slow${NC} to include (adds ~200s)"
    echo ""
fi

# What the verdict does NOT cover, carried onto the verdict line itself. The
# notice above scrolls away; the last line is what a reader and a grep both
# take as the result, and a bare "ALL TESTS PASSED" was read as the whole
NOT_RUN=()
if [ "$INCLUDE_SLOW" = false ] && [ ${#SLOW_SUITES[@]} -gt 0 ]; then
    for _declared_suite in "${SLOW_SUITES[@]}"; do NOT_RUN+=("${_declared_suite%%:*}"); done
fi
if [ ${#UNRUN_SUITES[@]} -gt 0 ]; then
    for _declared_suite in "${UNRUN_SUITES[@]}"; do NOT_RUN+=("${_declared_suite%%:*}"); done
fi
DECLARED_TOTAL=$(( ${#FAST_SUITES[@]} + ${#SLOW_SUITES[@]} + ${#UNRUN_SUITES[@]} ))
SCOPE="${#EXECUTED_SUITES[@]}/${DECLARED_TOTAL} suites"
if [ ${#NOT_RUN[@]} -gt 0 ]; then
    SCOPE="$SCOPE; not run: ${NOT_RUN[*]}"
fi

if [ ${#FAILED_SUITES[@]} -gt 0 ]; then
    echo -e "  ${RED}Failed suites:${NC}"
    for suite in "${FAILED_SUITES[@]}"; do
        echo -e "    - $suite"
    done
    echo ""
    echo -e "${RED}FAILED${NC} — $SCOPE"
    exit 1
else
    echo -e "${GREEN}ALL TESTS PASSED${NC} — $SCOPE"
    exit 0
fi
