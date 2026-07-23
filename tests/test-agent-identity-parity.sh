#!/bin/bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# test-agent-identity-parity.sh — cross-harness agent-identity contract guard (wv-5fbc6c)
#
# Three independent implementations must agree on agent identity (claimed_by /
# delta provenance / MCP startup.agent_id): bash (scripts/lib/wv-resolve-runtime.sh,
# canonical), TypeScript (mcp/src/index.ts, full parity reimplementation), and
# Python (scripts/weave_gh/phases.py, recognition-only -- it never computes its
# own identity, only recognizes an already-written claimed_by as local). See
# docs/AGENT-IDENTITY-CONTRACT.md for the full contract.
#
# Regression target: wv-4d4c96 (bash codex/claude precedence flip). This suite
# fails loudly if bash and MCP ever compute a different identity for the same
# env markers, or if python stops recognizing a harness-prefixed local claim.
# Weave-ID: wv-5fbc6c

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNTIME_LIB="$REPO_ROOT/scripts/lib/wv-resolve-runtime.sh"
MCP_DIST="$REPO_ROOT/mcp/dist/index.js"

TESTS_RUN=0
TESTS_PASSED=0

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

pass() {
    echo -e "  ${GREEN}✓${NC} $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
    TESTS_RUN=$((TESTS_RUN + 1))
}

fail() {
    echo -e "  ${RED}✗${NC} $1"
    [ -n "${2:-}" ] && echo "    $2"
    TESTS_RUN=$((TESTS_RUN + 1))
}

if [ ! -f "$MCP_DIST" ]; then
    fail "mcp/dist/index.js exists" "run: npm --prefix mcp run build"
    echo ""
    echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
    exit 1
fi

bash_identity() {
    # $1.. = env assignments, e.g. CLAUDE_CODE_SSE_PORT=1 CODEX_CI=1
    env -u WV_AGENT_ID -u CLAUDE_CODE_SSE_PORT -u CODEX_THREAD_ID -u CODEX_CI -u COPILOT_AGENT \
        "$@" bash -c "source '$RUNTIME_LIB'; resolve_agent_id" 2>/dev/null
}

mcp_identity() {
    # $1.. = env assignments
    local out
    out=$(env -u WV_AGENT_ID -u CLAUDE_CODE_SSE_PORT -u CODEX_THREAD_ID -u CODEX_CI -u COPILOT_AGENT \
        "$@" WV_PATH="$REPO_ROOT/scripts/wv" WV_PROJECT_ROOT="$REPO_ROOT" \
        node "$MCP_DIST" --scope=lite --health-check 2>/dev/null)
    echo "$out" | jq -r '.agent_id'
}

python_recognizes_local() {
    # $1 = claimed_by string to check; prints "true"/"false"
    PYTHONPATH="$REPO_ROOT/scripts" poetry run --directory "$REPO_ROOT" python - "$1" <<'PY' 2>/dev/null
import sys
from unittest.mock import patch
import subprocess
from weave_gh.phases import _desired_assignee_for_node, _current_gh_login
from weave_gh.models import WeaveNode

claimed_by = sys.argv[1]
_current_gh_login.cache_clear()
node = WeaveNode(id="wv-test", text="t", status="active", metadata={"claimed_by": claimed_by})
ok = subprocess.CompletedProcess([], returncode=0, stdout="octocat\n", stderr="")
host, user = claimed_by.rsplit("-", 2)[-2:] if claimed_by.count("-") >= 2 else (claimed_by, "")
with patch("weave_gh.phases.socket.gethostname", return_value=host), \
     patch("weave_gh.phases.getpass.getuser", return_value=user), \
     patch("weave_gh.phases._run", return_value=ok):
    result = _desired_assignee_for_node(node)
print("true" if result == "octocat" else "false")
PY
}

echo ""
echo "Test: bash vs MCP identity parity (same env, same machine -> same string)"
echo "==========================================================================="

declare -a SCENARIOS=(
    "claude alone|CLAUDE_CODE_SSE_PORT=1"
    "codex alone|CODEX_CI=1"
    "copilot alone|COPILOT_AGENT=1"
    "human (no markers)|"
    "claude+codex ambiguous (wv-4d4c96: claude must win)|CLAUDE_CODE_SSE_PORT=1 CODEX_CI=1"
    "all three ambiguous (copilot must win)|CLAUDE_CODE_SSE_PORT=1 CODEX_CI=1 COPILOT_AGENT=1"
)

for scenario in "${SCENARIOS[@]}"; do
    label="${scenario%%|*}"
    envstr="${scenario#*|}"
    # shellcheck disable=SC2086  # envstr is a controlled, script-local word list
    b=$(bash_identity $envstr)
    # shellcheck disable=SC2086
    m=$(mcp_identity $envstr)
    if [ "$b" = "$m" ]; then
        pass "$label -> bash and MCP agree ($b)"
    else
        fail "$label -> bash and MCP diverge" "bash=$b mcp=$m"
    fi
done

echo ""
echo "Test: python recognizes bash-produced harness-prefixed identities as local"
echo "============================================================================"

for harness in claude codex copilot human; do
    ident=$(bash_identity CLAUDE_CODE_SSE_PORT="$([ "$harness" = claude ] && echo 1)" \
                            CODEX_CI="$([ "$harness" = codex ] && echo 1)" \
                            COPILOT_AGENT="$([ "$harness" = copilot ] && echo 1)")
    case "$ident" in
        "$harness"-*) : ;;
        *) fail "sanity: bash produced a $harness-prefixed identity" "got: $ident"; continue ;;
    esac
    recognized=$(python_recognizes_local "$ident")
    if [ "$recognized" = "true" ]; then
        pass "python recognizes '$ident' ($harness) as a local claim"
    else
        fail "python recognizes '$ident' ($harness) as a local claim" "got: $recognized"
    fi
done

# ═══════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
echo -e "Results: $TESTS_PASSED/$TESTS_RUN passed"
if [ "$TESTS_PASSED" -eq "$TESTS_RUN" ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed.${NC}"
    exit 1
fi
