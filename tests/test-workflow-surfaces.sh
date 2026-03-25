#!/usr/bin/env bash
# test-workflow-surfaces.sh — Regression checks for workflow-facing prompts/docs

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if echo "$haystack" | grep -qF "$needle"; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Expected to find: $needle"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if echo "$haystack" | grep -qF "$needle"; then
        echo -e "${RED}✗${NC} $message"
        echo "  Unexpectedly found: $needle"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    else
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    fi
}

assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="$3"
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

echo "=== Workflow Surface Regression Tests ==="
echo ""

echo "--- skills: claim flow ---"
WEAVE_SKILL=$(cat "$PROJECT_ROOT/.claude/skills/weave/SKILL.md")
FIX_ISSUE=$(cat "$PROJECT_ROOT/.claude/skills/fix-issue/SKILL.md")
SHIP_IT=$(cat "$PROJECT_ROOT/.claude/skills/ship-it/SKILL.md")
DECOMPOSE=$(cat "$PROJECT_ROOT/.claude/skills/wv-decompose-work/SKILL.md")
CLOSE_SESSION=$(cat "$PROJECT_ROOT/.claude/skills/close-session/SKILL.md")
PLAN_AGENT=$(cat "$PROJECT_ROOT/.claude/skills/plan-agent/SKILL.md")

assert_contains "$WEAVE_SKILL" 'Validate → claim (`wv work <id>`) → CONTEXT' "weave skill: node-id intake uses wv work"
assert_contains "$FIX_ISSUE" 'For Weave nodes: `wv work $ARGUMENTS`' "fix-issue: claim flow uses wv work"
assert_contains "$SHIP_IT" 'When claiming a node for active work (`wv work <id>`).' "ship-it: trigger references wv work"
assert_contains "$DECOMPOSE" 'Claim and start work: `wv work wv-XXXXXX`' "wv-decompose-work: next-step claim uses wv work"
assert_contains "$DECOMPOSE" 'Use `/weave <id>` for structured implementation' "wv-decompose-work: points to /weave for implementation"
assert_contains "$WEAVE_SKILL" 'wv done <id> --learning="decision: ... | pattern: ... | pitfall: ..."' "weave skill: close flow uses structured learning triplet"
assert_contains "$FIX_ISSUE" 'wv done $ARGUMENTS --learning="decision: ... | pattern: ... | pitfall: ..."' "fix-issue: close flow uses structured learning triplet"
assert_contains "$CLOSE_SESSION" 'wv done <id> --learning="decision: ... | pattern: ... | pitfall: ..."' "close-session: recommends structured learning triplet"
assert_contains "$PLAN_AGENT" 'wv done <id> --learning="decision: use pyproj.Geod for geodesic calculations | pattern: prefer vetted geospatial libraries over manual trig for accuracy | pitfall: manual trig shortcuts drift on longer routes"' "plan-agent: closing example uses structured learning triplet"

LEGACY_SKILL_MATCHES=$(rg -n 'wv update .*--status=active' "$PROJECT_ROOT/.claude/skills" || true)
assert_equals "" "$LEGACY_SKILL_MATCHES" "skills: no legacy wv update --status=active references remain"
LEGACY_LEARNING_MATCHES=$(rg -n 'wv done .*--learning="pattern:|Brief learning note|\"learning\":\{' "$PROJECT_ROOT/.claude/skills" || true)
assert_equals "" "$LEGACY_LEARNING_MATCHES" "skills: no shorthand or nested learning examples remain"

echo ""
echo "--- agents: claim flow and orchestrator entry ---"
WEAVE_GUIDE=$(cat "$PROJECT_ROOT/.claude/agents/weave-guide.md")
EPIC_PLANNER=$(cat "$PROJECT_ROOT/.claude/agents/epic-planner.md")

assert_contains "$WEAVE_GUIDE" 'wv work wv-XXXXXX' "weave-guide: example claim flow uses wv work"
assert_contains "$WEAVE_GUIDE" '/weave wv-XXXXXX' "weave-guide: integration points to /weave"
assert_contains "$EPIC_PLANNER" 'wv work wv-AAAAAA  # Claim it' "epic-planner: post-decomposition claim uses wv work"
assert_contains "$WEAVE_GUIDE" 'wv done wv-XXXXXX --learning="decision: what was chosen | pattern: reusable technique | pitfall: gotcha to avoid"' "weave-guide: closing example uses structured learning triplet"

LEGACY_AGENT_MATCHES=$(rg -n 'wv update .*--status=active|/fix-issue' "$PROJECT_ROOT/.claude/agents" || true)
assert_equals "" "$LEGACY_AGENT_MATCHES" "agents: no legacy claim-flow or /fix-issue references remain"
LEGACY_AGENT_LEARNING=$(rg -n 'wv done .*--learning="pattern:' "$PROJECT_ROOT/.claude/agents" || true)
assert_equals "" "$LEGACY_AGENT_LEARNING" "agents: no shorthand learning examples remain"

echo ""
echo "--- mcp: shipped config and roadmap docs ---"
MCP_JSON=$(cat "$PROJECT_ROOT/.vscode/mcp.json")
MCP_README=$(cat "$PROJECT_ROOT/mcp/README.md")
WORKFLOW_DOC=$(cat "$PROJECT_ROOT/templates/WORKFLOW.md")

SERVER_COUNT=$(jq '.servers | keys | length' "$PROJECT_ROOT/.vscode/mcp.json")
assert_equals "2" "$SERVER_COUNT" "mcp.json: shipped config has exactly two servers"
assert_contains "$MCP_JSON" '"weave"' "mcp.json: includes weave server"
assert_contains "$MCP_JSON" '"weave-inspect"' "mcp.json: includes weave-inspect server"
assert_not_contains "$MCP_JSON" '"weave-graph"' "mcp.json: does not ship weave-graph server"
assert_not_contains "$MCP_JSON" '"weave-session"' "mcp.json: does not ship weave-session server"

assert_contains "$MCP_README" 'currently registers **two servers**' "mcp README: documents shipped two-server config"
assert_contains "$MCP_README" 'upcoming runtime-agent specialisation' "mcp README: preserves aspirational scoped-server roadmap"
assert_contains "$MCP_README" '### Session scope — workflow lifecycle (9 tools)' "mcp README: session scope count is current"
assert_contains "$MCP_README" '### Inspect scope — read-only queries (14 tools)' "mcp README: inspect scope count is current"
assert_contains "$MCP_README" '`weave_recover`' "mcp README: session tool inventory includes weave_recover"
assert_contains "$MCP_README" '`weave_edit_guard`' "mcp README: session tool inventory includes weave_edit_guard"
assert_contains "$MCP_README" '`weave-graph` (planned) / `weave` (current)' "mcp README: agent pairing distinguishes planned vs current graph server"
assert_contains "$MCP_README" '`weave-session` (planned) / `weave` (current)' "mcp README: agent pairing distinguishes planned vs current session server"

echo ""
echo "--- repair workflow guidance ---"
assert_contains "$WORKFLOW_DOC" '## Repair Workflow' "workflow doc: includes repair workflow section"
assert_contains "$WORKFLOW_DOC" 'needs_human_verification' "workflow doc: repair workflow covers resumable human verification"
assert_contains "$WEAVE_SKILL" '### Repair Loop for Detected Issues' "weave skill: includes repair loop guidance"
assert_contains "$WEAVE_GUIDE" '## Repair Workflow for Detected Issues' "weave-guide: includes repair workflow guidance"
assert_contains "$WEAVE_GUIDE" 'wv breadcrumbs save --msg="Detected workflow issue, created repair node, next step is ..."' "weave-guide: repair workflow preserves breadcrumbs"

echo ""
echo "=== Results ==="
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"

if [ "$TESTS_FAILED" -eq 0 ]; then
    echo "All tests passed"
    exit 0
else
    echo "$TESTS_FAILED test(s) failed"
    exit 1
fi
