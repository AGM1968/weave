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
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)

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
    env -u WV_AGENT_ID -u CLAUDE_CODE_SSE_PORT -u CLAUDECODE -u AI_AGENT -u PI_SESSION_ID -u AMP_CURRENT_THREAD_ID -u CODEX_THREAD_ID -u CODEX_CI -u COPILOT_AGENT -u COPILOT_CLI -u COPILOT_AGENT_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u WV_SESSION_IDENTITY -u WV_SESSION_ID \
        "$@" bash -c "source '$RUNTIME_LIB'; resolve_agent_id" 2>/dev/null
}

mcp_identity() {
    # $1.. = env assignments
    local out
    out=$(env -u WV_AGENT_ID -u CLAUDE_CODE_SSE_PORT -u CLAUDECODE -u AI_AGENT -u PI_SESSION_ID -u AMP_CURRENT_THREAD_ID -u CODEX_THREAD_ID -u CODEX_CI -u COPILOT_AGENT -u COPILOT_CLI -u COPILOT_AGENT_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u WV_SESSION_IDENTITY -u WV_SESSION_ID \
        "$@" WV_PATH="$REPO_ROOT/scripts/wv" WV_PROJECT_ROOT="$REPO_ROOT" \
        node "$MCP_DIST" --scope=lite --health-check 2>/dev/null)
    echo "$out" | jq -r '.agent_id'
}

python_recognizes_local() {
    # $1 = claimed_by string to check; prints "true"/"false"
    # python3 directly, not poetry run: weave_gh is standard-library-only here
    # and the poetry indirection made this suite fail in any environment that
    # ships the tests without the development toolchain -- which is every
    # consumer of the public projection.
    # Python sees the host and user that resolve_agent_id() read (hostname,
    # whoami), not parts split back out of the identity: a hostname may hold
    # hyphens (macOS runners: Mac-...-6A841F8F983F.local), and splitting on
    # "-" then mocked a host python never has (wv-d71756).
    local host user
    host=$(hostname 2>/dev/null || echo "host")
    user=$(whoami 2>/dev/null || echo "user")
    PYTHONPATH="$REPO_ROOT/scripts" python3 - "$1" "$host" "$user" <<'PY' 2>/dev/null
import sys
from unittest.mock import patch
import subprocess
from weave_gh.phases import _desired_assignee_for_node, _current_gh_login
from weave_gh.models import WeaveNode

claimed_by, host, user = sys.argv[1:4]
_current_gh_login.cache_clear()
node = WeaveNode(id="wv-test", text="t", status="active", metadata={"claimed_by": claimed_by})
ok = subprocess.CompletedProcess([], returncode=0, stdout="octocat\n", stderr="")
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
    "IDE port alone is not claude (wv-08d7f9)|CLAUDE_CODE_SSE_PORT=1"
    "codex with an inherited IDE port (wv-08d7f9)|CLAUDE_CODE_SSE_PORT=1 CODEX_THREAD_ID=01a12cd8-e777-7f00-a22c-5bdd105db0ba"
    "claude in an IDE terminal|CLAUDE_CODE_SSE_PORT=1 CLAUDECODE=1 AI_AGENT=claude-code_2-1-318_agent CLAUDE_CODE_SESSION_ID=abc"
    "pi with an inherited IDE port (wv-08d7f9)|CLAUDE_CODE_SSE_PORT=1 AI_AGENT=pi PI_SESSION_ID=019a5e2c-7d10-7000-8000-000000000001"
    "amp with an inherited IDE port (wv-08d7f9)|CLAUDE_CODE_SSE_PORT=1 AI_AGENT=amp AMP_CURRENT_THREAD_ID=T-01a1a749-e3b6-723b-bd6c-86427007bbbe"
    "pi inside claude: AI_AGENT outranks CLAUDECODE|CLAUDECODE=1 AI_AGENT=pi PI_SESSION_ID=p1"
    "unknown AI_AGENT label, agnostic channel|AI_AGENT=Foo.Bar/9 WV_SESSION_ID=z"
    "AI_AGENT label with no session channel|AI_AGENT=constructor"
    "pi, session id missing|AI_AGENT=pi"
    "claude via CLAUDECODE alone (wv-50640a)|CLAUDECODE=1"
    "codex alone|CODEX_CI=1"
    "copilot alone|COPILOT_AGENT=1"
    "human (no markers)|"
    "claude+codex ambiguous (wv-4d4c96: claude must win)|CLAUDECODE=1 CODEX_CI=1"
    "all ambiguous (copilot must win)|CLAUDECODE=1 CODEX_CI=1 COPILOT_AGENT=1 AI_AGENT=pi"
    "claude session (wv-99978b)|CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=e2bbbaf2-606c-462b-8c2e-2d4305df0616"
    "codex session (wv-99978b)|CODEX_THREAD_ID=019a-bc12-34"
    "claude session, junk id digested whole|CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=a/b..c-d"
    "codex UUIDv7 thread (wv-24d57b)|CODEX_THREAD_ID=01a12cd8-e777-7f00-a22c-5bdd105db0ba"
    "codex UUIDv7 thread, same millisecond|CODEX_THREAD_ID=01a12cd8-e777-7a11-b33c-0123456789ab"
    "claude session, opted out|CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=abc WV_SESSION_IDENTITY=0"
    "claude session, explicit id wins|CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=abc WV_AGENT_ID=me"
    "claude, session id missing|CLAUDECODE=1"
    "copilot stays actor-owned|COPILOT_AGENT=1 CLAUDE_CODE_SESSION_ID=abc"
    "agnostic channel, any host (WV_SESSION_ID)|WV_SESSION_ID=amp-T-1234"
    "agnostic channel on copilot|COPILOT_AGENT=1 WV_SESSION_ID=xyz"
    "agnostic channel wins over harness default|CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=abc WV_SESSION_ID=def"
    "amp session variable alone, no AI_AGENT (wv-55a24d)|AMP_CURRENT_THREAD_ID=T-01a1a749-e3b6-723b-bd6c-86427007bbbe"
    "pi session variable alone, no AI_AGENT (wv-55a24d)|PI_SESSION_ID=019a5e2c-7d10-7000-8000-000000000001"
    "amp variable inside claude, no AI_AGENT (wv-55a24d)|CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=abc AMP_CURRENT_THREAD_ID=T-1"
    "claude inside amp: AI_AGENT decisive (wv-55a24d)|CLAUDECODE=1 AI_AGENT=claude-code_2-1-318_agent CLAUDE_CODE_SESSION_ID=abc AMP_CURRENT_THREAD_ID=T-1"
    "copilot cli session (wv-6781d7)|COPILOT_CLI=1 COPILOT_AGENT_SESSION_ID=e6ffa6a9-f6e4-48e1-88b1-26cb209c229a"
    "copilot cli, session id missing (wv-6781d7)|COPILOT_CLI=1"
    "copilot cli beside an inherited CLAUDECODE (wv-6781d7)|COPILOT_CLI=1 COPILOT_AGENT_SESSION_ID=s1 CLAUDECODE=1"
    "claude inside copilot cli: AI_AGENT decisive (wv-6781d7)|COPILOT_CLI=1 COPILOT_AGENT_SESSION_ID=s1 CLAUDECODE=1 AI_AGENT=claude-code_2-1-318_agent CLAUDE_CODE_SESSION_ID=abc"
    "COPILOT_AGENT ignores the Copilot CLI session variable (wv-6781d7)|COPILOT_AGENT=1 COPILOT_AGENT_SESSION_ID=s1"
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

# wv-55a24d: the session-variable fallback names the harness, not just parity.
# Amp's October 2026 work was credited to claude because an Amp process without
# AI_AGENT inside a Claude shell resolved claude with no diagnostic at all.
harness_of() { local id="$1"; printf '%s\n' "${id%%-*}"; }
expect_harness() {  # $1 label, $2 expected harness, $3.. env
    local label="$1" want="$2"; shift 2
    local got_b got_m
    got_b=$(harness_of "$(bash_identity "$@")")
    got_m=$(harness_of "$(mcp_identity "$@")")
    if [ "$got_b" = "$want" ] && [ "$got_m" = "$want" ]; then
        pass "$label -> $want in bash and MCP"
    else
        fail "$label -> $want" "bash=$got_b mcp=$got_m"
    fi
}
expect_harness "amp session variable alone" amp AMP_CURRENT_THREAD_ID=T-1
expect_harness "pi session variable alone" pi PI_SESSION_ID=p1
expect_harness "amp variable inside claude without AI_AGENT keeps claude" claude CLAUDECODE=1 AMP_CURRENT_THREAD_ID=T-1
expect_harness "AI_AGENT stays decisive over an inherited amp variable" claude CLAUDECODE=1 AI_AGENT=claude-code_2-1-318_agent AMP_CURRENT_THREAD_ID=T-1
expect_harness "AI_AGENT=amp unchanged" amp AI_AGENT=amp AMP_CURRENT_THREAD_ID=T-1
# wv-6781d7: Copilot CLI sets COPILOT_CLI=1, never COPILOT_AGENT (1.0.112). It
# leaks to children like CLAUDECODE, so it ranks after AI_AGENT.
expect_harness "Copilot CLI's marker alone" copilot COPILOT_CLI=1 COPILOT_AGENT_SESSION_ID=s1
expect_harness "Copilot CLI beside an inherited CLAUDECODE" copilot COPILOT_CLI=1 COPILOT_AGENT_SESSION_ID=s1 CLAUDECODE=1
expect_harness "Claude Code started from a Copilot CLI shell keeps claude" claude COPILOT_CLI=1 COPILOT_AGENT_SESSION_ID=s1 CLAUDECODE=1 AI_AGENT=claude-code_2-1-318_agent
# A Copilot CLI hook gets no session variable, only the payload's id (session_id
# with PascalCase events, sessionId in Copilot's own format): adoption must give
# it the owner its tool shell resolves.
cp_shell=$(bash_identity COPILOT_CLI=1 COPILOT_AGENT_SESSION_ID=e6ffa6a9-f6e4-48e1-88b1-26cb209c229a)
for payload in '{"session_id":"e6ffa6a9-f6e4-48e1-88b1-26cb209c229a"}' '{"sessionId":"e6ffa6a9-f6e4-48e1-88b1-26cb209c229a"}'; do
    cp_hook=$(env -u WV_AGENT_ID -u CLAUDE_CODE_SSE_PORT -u CLAUDECODE -u AI_AGENT -u PI_SESSION_ID -u AMP_CURRENT_THREAD_ID -u CODEX_THREAD_ID -u CODEX_CI -u COPILOT_AGENT -u COPILOT_AGENT_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u WV_SESSION_IDENTITY -u WV_SESSION_ID \
        COPILOT_CLI=1 bash -c "source '$RUNTIME_LIB'; wv_adopt_hook_session_id '$payload'; resolve_agent_id" 2>/dev/null)
    # Equal is not enough: an unrecognised harness makes both human and equal.
    if [[ "$cp_shell" == copilot-*-h[0-9a-f]* ]] && [ "$cp_hook" = "$cp_shell" ]; then
        pass "a Copilot CLI hook resolves its tool shell's owner from $payload ($cp_hook)"
    else
        fail "a Copilot CLI hook resolves its tool shell's owner from $payload" "shell=$cp_shell hook=$cp_hook"
    fi
done
_diag=$(env -u WV_AGENT_ID -u AI_AGENT -u CODEX_THREAD_ID -u CODEX_CI -u COPILOT_AGENT -u COPILOT_CLI -u COPILOT_AGENT_SESSION_ID -u PI_SESSION_ID \
    CLAUDECODE=1 AMP_CURRENT_THREAD_ID=T-1 bash -c "source '$RUNTIME_LIB'; resolve_agent_harness" 2>&1 >/dev/null || true)
if [[ "$_diag" == *"ambiguous agent markers (claude amp)"* ]]; then
    pass "amp variable beside claude is named in the ambiguity diagnostic, not silent"
else
    fail "amp variable beside claude is named in the ambiguity diagnostic" "stderr=[$_diag]"
fi
_diag=$(env -u WV_AGENT_ID -u CODEX_THREAD_ID -u CODEX_CI -u COPILOT_AGENT -u COPILOT_CLI -u COPILOT_AGENT_SESSION_ID -u PI_SESSION_ID \
    CLAUDECODE=1 AI_AGENT=claude-code_2-1-318_agent AMP_CURRENT_THREAD_ID=T-1 bash -c "source '$RUNTIME_LIB'; resolve_agent_harness" 2>&1 >/dev/null || true)
if [ -z "$_diag" ]; then
    pass "AI_AGENT set: the fallback is not consulted, so no diagnostic"
else
    fail "AI_AGENT set: no diagnostic" "stderr=[$_diag]"
fi

# wv-24d57b: the session part digests the WHOLE id. Two UUIDv7 thread ids from
# one millisecond share their first 12 characters (the timestamp), and ids that
# differ only in separators reduce to one alnum string; each pair must split,
# in bash and in MCP, and a known vector pins the digest across languages.
for pair in "CODEX_THREAD_ID=01a12cd8-e777-7f00-a22c-5bdd105db0ba|CODEX_THREAD_ID=01a12cd8-e777-7a11-b33c-0123456789ab" \
            "WV_SESSION_ID=a-b|WV_SESSION_ID=ab"; do
    x="${pair%%|*}"; y="${pair#*|}"
    if [ "$(bash_identity "$x")" != "$(bash_identity "$y")" ] && [ "$(mcp_identity "$x")" != "$(mcp_identity "$y")" ]; then
        pass "distinct owners for $x and $y (bash and MCP)"
    else
        fail "distinct owners for $x and $y" "bash: $(bash_identity "$x") / $(bash_identity "$y")"
    fi
done
vec=$(bash_identity CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=aaaaaaaa-1111-2222-3333-444444444444)
if [[ "$vec" == *-h61eef8f68895bbdc ]]; then
    pass "known vector: sha256(aaaaaaaa-1111-2222-3333-444444444444)[:16] = 61eef8f68895bbdc"
else
    fail "known vector for the session digest" "got: $vec"
fi

echo ""
echo "Test: python recognizes bash-produced harness-prefixed identities as local"
echo "============================================================================"

for harness in claude codex copilot human pi amp foobar9; do
    case "$harness" in
        claude)  ident=$(bash_identity CLAUDECODE=1) ;;
        codex)   ident=$(bash_identity CODEX_CI=1) ;;
        copilot) ident=$(bash_identity COPILOT_AGENT=1) ;;
        human)   ident=$(bash_identity) ;;
        foobar9) ident=$(bash_identity AI_AGENT=Foo.Bar/9) ;;
        *)       ident=$(bash_identity AI_AGENT="$harness") ;;
    esac
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

echo ""
echo "Test: session identity (wv-99978b) — format, python recognition, fail closed"
echo "============================================================================="

for envstr in "CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=e2bbbaf2-606c-462b-8c2e-2d4305df0616" \
              "CODEX_THREAD_ID=019a-bc12-34" "WV_SESSION_ID=amp-T-1234" \
              "AI_AGENT=pi PI_SESSION_ID=019a5e2c-7d10-7000-8000-000000000001" \
              "AI_AGENT=amp AMP_CURRENT_THREAD_ID=T-01a1a755-4c7b-77b4-9982-053d0b097bbb" \
              "COPILOT_CLI=1 COPILOT_AGENT_SESSION_ID=e6ffa6a9-f6e4-48e1-88b1-26cb209c229a"; do
    # shellcheck disable=SC2086  # envstr is a controlled, script-local word list
    ident=$(bash_identity $envstr)
    if [[ "$ident" =~ ^[a-z0-9]{1,24}-.+-.+-h[0-9a-f]{16}$ ]]; then
        pass "bash qualifies the session with a whole-id digest: $ident"
    else
        fail "bash qualifies the session" "got: $ident"
    fi
    recognized=$(python_recognizes_local "$ident")
    if [ "$recognized" = "true" ]; then
        pass "python recognizes session claim '$ident' as local"
    else
        fail "python recognizes session claim '$ident' as local" "got: $recognized"
    fi
done

bash_require() {
    env -u WV_AGENT_ID -u CLAUDE_CODE_SSE_PORT -u CLAUDECODE -u AI_AGENT -u PI_SESSION_ID -u AMP_CURRENT_THREAD_ID -u CODEX_THREAD_ID -u CODEX_CI -u COPILOT_AGENT -u COPILOT_CLI -u COPILOT_AGENT_SESSION_ID \
        -u CLAUDE_CODE_SESSION_ID -u WV_SESSION_IDENTITY -u WV_SESSION_ID \
        "$@" bash -c "set -euo pipefail; source '$RUNTIME_LIB'; require_agent_id" 2>/dev/null
}
for envstr in "CLAUDECODE=1" "CODEX_CI=1" "CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=..--" "WV_SESSION_ID=" \
              "AI_AGENT=pi" "AI_AGENT=amp" "COPILOT_CLI=1"; do
    # shellcheck disable=SC2086
    if out=$(bash_require $envstr); then
        fail "require_agent_id refuses an unverifiable session ($envstr)" "got: $out"
    else
        pass "require_agent_id refuses an unverifiable session ($envstr)"
    fi
done
for envstr in "" "COPILOT_AGENT=1" "CLAUDECODE=1 WV_SESSION_IDENTITY=0" "CLAUDECODE=1 WV_AGENT_ID=me" \
              "CLAUDE_CODE_SSE_PORT=1" "CLAUDE_CODE_SSE_PORT=1 CODEX_THREAD_ID=t1" \
              "CLAUDE_CODE_SSE_PORT=1 AI_AGENT=pi PI_SESSION_ID=p1" "AI_AGENT=constructor" \
              "COPILOT_AGENT=1 COPILOT_AGENT_SESSION_ID=s1"; do
    # shellcheck disable=SC2086
    if out=$(bash_require $envstr) && [ -n "$out" ]; then
        pass "require_agent_id admits an actor-owned identity (${envstr:-human}): $out"
    else
        fail "require_agent_id admits an actor-owned identity (${envstr:-human})"
    fi
done

echo ""
echo "Test: hyphenated, dotted, mixed-case hostname (wv-d71756, macOS runner shape)"
echo "=============================================================================="

HOST_SHIM=$(mktemp -d)
printf '#!/bin/sh\necho Mac-Mini-6A841F8F983F.local\n' > "$HOST_SHIM/hostname"
chmod +x "$HOST_SHIM/hostname"
for envstr in "CLAUDECODE=1" "CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=e2bbbaf2-606c-462b-8c2e-2d4305df0616"; do
    # shellcheck disable=SC2086  # envstr is a controlled, script-local word list
    ident=$(PATH="$HOST_SHIM:$PATH" bash_identity $envstr)
    case "$ident" in
        claude-Mac-Mini-6A841F8F983F.local-*) : ;;
        *) fail "sanity: bash used the shimmed hostname" "got: $ident"; continue ;;
    esac
    recognized=$(PATH="$HOST_SHIM:$PATH" python_recognizes_local "$ident")
    if [ "$recognized" = "true" ]; then
        pass "python recognizes '$ident' as local"
    else
        fail "python recognizes '$ident' as local" "got: $recognized"
    fi
done
rm -rf "$HOST_SHIM"

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
