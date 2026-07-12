#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
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
    if grep -qF "$needle" <<<"$haystack"; then
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
    if grep -qF "$needle" <<<"$haystack"; then
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
MCP_SOURCE=$(cat "$PROJECT_ROOT/mcp/src/index.ts")
MCP_CONTRACT=$(cat "$PROJECT_ROOT/mcp/contract.json")
WORKFLOW_DOC=$(cat "$PROJECT_ROOT/templates/WORKFLOW.md")

EXPECTED_SERVER_COUNT=$(jq '.servers | length' "$PROJECT_ROOT/mcp/contract.json")
SERVER_COUNT=$(jq '.servers | keys | length' "$PROJECT_ROOT/.vscode/mcp.json")
assert_equals "$EXPECTED_SERVER_COUNT" "$SERVER_COUNT" "mcp.json: shipped config matches contract server count"
assert_contains "$MCP_JSON" '"weave"' "mcp.json: includes weave server"
assert_contains "$MCP_JSON" '"weave-session"' "mcp.json: includes weave-session server"
assert_contains "$MCP_JSON" '"weave-lite"' "mcp.json: includes weave-lite server"
assert_contains "$MCP_JSON" '"weave-inspect"' "mcp.json: includes weave-inspect server"
assert_not_contains "$MCP_JSON" '"weave-graph"' "mcp.json: does not ship weave-graph server"
assert_contains "$MCP_JSON" '"WV_AGENT_ID"' "mcp.json: pins explicit MCP agent identity"
assert_contains "$MCP_JSON" 'copilot-${workspaceFolderBasename}' "mcp.json: MCP agent identity is workspace-scoped"

assert_contains "$MCP_README" 'currently registers **four servers**' "mcp README: documents shipped four-server config"
assert_contains "$MCP_README" 'mcp/contract.json' "mcp README: points operators to machine-readable MCP contract"
assert_contains "$MCP_README" 'optional local addition' "mcp README: preserves scoped-server roadmap"
assert_contains "$MCP_README" '45 available tools' "mcp README: total tool count is current"
assert_contains "$MCP_README" '### Session scope — workflow lifecycle (12 tools)' "mcp README: session scope count is current"
assert_contains "$MCP_README" '### Inspect scope — read-only queries (22 tools)' "mcp README: inspect scope count is current"
assert_contains "$MCP_README" 'WV_AGENT_ID' "mcp README: documents explicit MCP agent identity"
assert_contains "$MCP_README" 'health-check' "mcp README: documents structured startup health check"
assert_contains "$MCP_README" '`weave_recover`' "mcp README: session tool inventory includes weave_recover"
assert_contains "$MCP_README" '`weave_edit_guard`' "mcp README: session tool inventory includes weave_edit_guard"
assert_contains "$MCP_README" '`weave-graph` (planned) / `weave` (current)' "mcp README: agent pairing distinguishes planned vs current graph server"
assert_contains "$MCP_README" '`weave-session` (planned) / `weave` (current)' "mcp README: agent pairing distinguishes planned vs current session server"
assert_contains "$MCP_README" 'WV_MCP_ALLOW_NETWORK' "mcp README: documents explicit network opt-in"
assert_contains "$MCP_README" 'close locally with `--no-gh`' "mcp README: documents local-only MCP close default"
assert_contains "$MCP_SOURCE" 'const MCP_ALLOW_NETWORK = process.env.WV_MCP_ALLOW_NETWORK === "1";' "mcp source: network lifecycle requires explicit env opt-in"
assert_contains "$MCP_SOURCE" 'schema: "weave-mcp-startup.v1"' "mcp source: emits structured startup health schema"
assert_contains "$MCP_SOURCE" 'cmd.push("--no-gh")' "mcp source: close tools add --no-gh by default"
assert_contains "$MCP_SOURCE" 'mcpNetworkFallback(`wv sync --gh' "mcp source: GitHub sync requests return CLI fallback"
# Name-anchored range, not a hardcoded absolute line range: any edit earlier in
# this (large, frequently-changed) file shifts absolute line numbers and silently
# stops testing the intended function — this broke once already (wv-fa566a).
MCP_VSCODE_CHECK_FN=$(awk '/_mcp_check_vscode_config\(\) \{/,/^    \}/' "$PROJECT_ROOT/scripts/cmd/wv-cmd-ops.sh")
assert_contains "$MCP_VSCODE_CHECK_FN" "mcp/contract.json" "mcp-status: validates VS Code config against contract"
assert_contains "$MCP_VSCODE_CHECK_FN" ".servers[].name" "mcp-status: derives expected server names from contract"
assert_contains "$MCP_VSCODE_CHECK_FN" ".environment.required[]" "mcp-status: derives required env from contract"
assert_equals "weave-mcp-contract.v1" "$(jq -r '.schema' "$PROJECT_ROOT/mcp/contract.json")" "mcp contract: has schema id"
assert_equals "weave-mcp-startup.v1" "$(jq -r '.startup_report_schema' "$PROJECT_ROOT/mcp/contract.json")" "mcp contract: names startup report schema"
assert_equals "5" "$(jq '.scopes | keys | length' "$PROJECT_ROOT/mcp/contract.json")" "mcp contract: declares all supported scopes"
assert_equals "$EXPECTED_SERVER_COUNT" "$(jq '.servers | length' "$PROJECT_ROOT/mcp/contract.json")" "mcp contract: declares shipped server entries"
assert_equals "true" "$(jq '(.environment.required | index("WV_PROJECT_ROOT") != null) and (.environment.required | index("WV_AGENT_ID") != null)' "$PROJECT_ROOT/mcp/contract.json")" "mcp contract: requires project root and agent identity"
assert_equals "45" "$(jq '.scopes.all.tool_count' "$PROJECT_ROOT/mcp/contract.json")" "mcp contract: all scope tool count is current"
assert_equals "13" "$(jq '.scopes.graph.tool_count' "$PROJECT_ROOT/mcp/contract.json")" "mcp contract: graph scope tool count is current"
assert_equals "12" "$(jq '.scopes.session.tool_count' "$PROJECT_ROOT/mcp/contract.json")" "mcp contract: session scope tool count is current"
assert_equals "7" "$(jq '.scopes.lite.tool_count' "$PROJECT_ROOT/mcp/contract.json")" "mcp contract: lite scope tool count is current"
assert_equals "22" "$(jq '.scopes.inspect.tool_count' "$PROJECT_ROOT/mcp/contract.json")" "mcp contract: inspect scope tool count is current"
assert_contains "$MCP_CONTRACT" '"start_when"' "mcp contract: scope lifecycle start_when is explicit"
assert_contains "$MCP_CONTRACT" '"start_policy"' "mcp contract: server lifecycle start_policy is explicit"
assert_equals "true" "$(jq 'all(.servers[]; .lifecycle == "client-managed-stdio" and (.start_policy | length > 0))' "$PROJECT_ROOT/mcp/contract.json")" "mcp contract: every shipped server has lifecycle policy"
assert_equals "true" "$(jq 'all(.scopes | to_entries[]; (.value.start_when | length > 0) and (.value.intended_clients | length > 0))' "$PROJECT_ROOT/mcp/contract.json")" "mcp contract: every scope has clients and start guidance"
assert_equals "true" "$(jq 'all(.servers[]; .name as $name | .scope as $scope | (.default == (.name == "weave")) and (.intended_clients | length > 0) and (.lifecycle == "client-managed-stdio") and (.start_policy | length > 0))' "$PROJECT_ROOT/mcp/contract.json")" "mcp contract: shipped servers declare default/client/lifecycle"
assert_contains "$MCP_README" '### Scope lifecycle' "mcp README: documents scope lifecycle table"
assert_contains "$MCP_README" 'client-managed stdio' "mcp README: lifecycle policy names client-managed stdio"
assert_contains "$MCP_README" 'weave-graph' "mcp README: lifecycle table includes optional graph scope"
assert_contains "$MCP_README" "All $(jq '.scopes.all.tool_count' "$PROJECT_ROOT/mcp/contract.json") tools" "mcp README: all-scope tool count matches contract"
assert_contains "$MCP_README" "### Session scope — workflow lifecycle ($(jq '.scopes.session.tool_count' "$PROJECT_ROOT/mcp/contract.json") tools)" "mcp README: session heading count matches contract"
assert_contains "$MCP_README" "### Inspect scope — read-only queries ($(jq '.scopes.inspect.tool_count' "$PROJECT_ROOT/mcp/contract.json") tools)" "mcp README: inspect heading count matches contract"

echo ""
echo "--- repair workflow guidance ---"
assert_contains "$WORKFLOW_DOC" '## Repair Workflow' "workflow doc: includes repair workflow section"
assert_contains "$WORKFLOW_DOC" 'needs_human_verification' "workflow doc: repair workflow covers resumable human verification"
assert_contains "$WORKFLOW_DOC" '`blindspot-pass`' "workflow doc: procedure index includes blindspot-pass"
assert_contains "$WORKFLOW_DOC" '`wv discover <id> --json`' "workflow doc: command table includes wv discover"
assert_contains "$WEAVE_SKILL" '### Repair Loop for Detected Issues' "weave skill: includes repair loop guidance"
assert_contains "$WEAVE_GUIDE" '## Repair Workflow for Detected Issues' "weave-guide: includes repair workflow guidance"
assert_contains "$WEAVE_GUIDE" 'wv trails save --msg="Detected workflow issue, created repair node, next step is ..."' "weave-guide: repair workflow preserves trails"

DISCOVERY_GUIDE=$("$PROJECT_ROOT/scripts/wv" guide --topic=discovery)
BLINDSPOT_PROCEDURE=$(cat "$PROJECT_ROOT/templates/procedures/blindspot-pass.md")
assert_contains "$DISCOVERY_GUIDE" 'wv discover <id>' "discovery guide: documents wv discover"
assert_contains "$DISCOVERY_GUIDE" 'wv guide --procedure=blindspot-pass' "discovery guide: points to blindspot-pass procedure"
assert_contains "$BLINDSPOT_PROCEDURE" '## Release Example' "blindspot procedure: includes release example"
assert_contains "$BLINDSPOT_PROCEDURE" '## MCP Example' "blindspot procedure: includes MCP example"
assert_contains "$BLINDSPOT_PROCEDURE" 'Do not create a blocking finding from a candidate' "blindspot procedure: keeps candidates non-blocking"

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
