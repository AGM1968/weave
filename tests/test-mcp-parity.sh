#!/bin/bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# test-mcp-parity.sh — MCP-vs-CLI flag parity guard (wv-0eb81a)
#
# For every MCP tool with a CLI counterpart, each CLI --flag must appear in
# the tool's inputSchema properties (snake_case-normalized) or in the baseline
# below. Implements the test sketched in
# docs/findings/v1.51.0-mcp-unarchive-with-edges-parity.md:145 after the
# weave_unarchive --with-edges drift shipped unnoticed in v1.51.0.
#
# The BASELINE lists gaps that existed when this test was introduced
# (2026-06-12). They are accepted-but-tracked: shrink the list when exposing
# a flag, never grow it silently — a NEW gap fails this test.
# Weave-ID: wv-0eb81a

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$REPO_ROOT/scripts/wv"
MCP_DIST="$REPO_ROOT/mcp/dist/index.js"

TESTS_RUN=0
TESTS_PASSED=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

# MCP-only tools and composites with no single CLI counterpart.
SKIP_TOOLS="edit_guard close_session code_search breadcrumbs"

# Irregular tool-name -> CLI command mappings.
declare -A OVERRIDE=(
    [structural_search]="quality structural-search"
    [record_edit]="touch"
)

# Flags MCP handles implicitly for every tool.
GLOBAL_IGNORE='^--(help|json)$'

# Accepted gaps at baseline date (see header). Format: "<tool> <--flag>".
# Triaged 2026-06-12 (wv-3599d4). Categories:
#   policy-network    server-owned: handlers inject --no-gh / gate gh behind
#                     WV_MCP_ALLOW_NETWORK (gh hangs on Codex sandbox network
#                     denial — the timeout that defines the lite/no-network
#                     contract). Never expose to callers.
#   safety-bypass     deliberate: verification/claim bypasses stay CLI-only.
#   renamed           equivalent exists under a different property name.
#   inline-equiv      *-file flag; MCP takes the content inline instead.
#   tool-split        covered by a dedicated MCP tool.
#   format/tty        output-shaping or interactive; meaningless over MCP.
#   server-default    tuning knob the server owns.
#   EXPOSE            real drift; expose then delete the line (wv-4a1de6).
BASELINE="# --- policy-network (WV_MCP_ALLOW_NETWORK owns these) ---
weave_done --no-gh
weave_batch_done --no-gh
# --- safety-bypass ---
weave_done --skip-verification
weave_ship --skip-verification
weave_work --force
# --- renamed: no_overlap_check / from_id+to_id / mode / limit / work.reopen ---
weave_done --acknowledge-overlap
weave_block --by
weave_resolve --defer
weave_resolve --merge
weave_quality_hotspots --top
weave_update --reopen
# --- inline-equiv (content passed inline over MCP) ---
weave_done --learning-file
weave_done --verification-evidence-file
weave_ship --learning-file
weave_ship --verification-evidence-file
weave_update --metadata-file
# --- tool-split (dedicated tool covers it) ---
weave_search --code
weave_search --learning
weave_search --mode
weave_search --graph
weave_search --filter
# --- format/tty ---
weave_list --json-v
weave_show --json-v
weave_show --mode
weave_learnings --show-graph
weave_update --echo
weave_work --quiet
weave_work --allowed-tools
weave_health --fast
# --- server-default tuning ---
weave_index --chunk-size
weave_index --model
weave_index --overlap
# --- EXPOSE tier 1: exposed 2026-06-12 (wv-4a1de6) — lines deleted ---
# --- EXPOSE tier 2: exposed/reclassified 2026-06-12 (wv-8e217e) ---
# weave_search.type, weave_code_search.filter, weave_impact.files exposed;
# search --mode/--graph/--filter reclassified tool-split (code-path flags,
# already on weave_code_search).
# --- EXPOSE tier 3: exposed 2026-06-12 (wv-db8aeb) — lines deleted ---
# All nine exposed incl. quality_patterns 'promote' subcommand (was absent
# from the enum entirely)."

# ═══════════════════════════════════════════════════════════════════════════
# Fetch the live tool schemas over stdio (one-shot tools/list, all scopes)
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
echo "  MCP-vs-CLI flag parity"
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""

TEST_DIR=$(mktemp -d)
trap 'cd /tmp && rm -rf "$TEST_DIR"' EXIT
SCHEMA="$TEST_DIR/mcp-schema.json"

if [ ! -f "$MCP_DIST" ]; then
    fail "mcp/dist/index.js exists" "run: npm --prefix mcp run build"
    echo ""
    echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
    exit 1
fi

printf '%s\n%s\n%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"parity-test","version":"0"}}}' \
    '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
    | timeout 20 node "$MCP_DIST" --scope=all 2>/dev/null \
    | jq -s '[.[] | select(.id==2)][0].result.tools' > "$SCHEMA" || true

tool_count=$(jq 'length' "$SCHEMA" 2>/dev/null || echo 0)
if [ "${tool_count:-0}" -ge 40 ]; then
    pass "tools/list served $tool_count tools (scope=all)"
else
    fail "tools/list served $tool_count tools (scope=all)" "expected >= 40; is mcp/dist stale?"
    echo ""
    echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
    exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════
# Parity check
# ═══════════════════════════════════════════════════════════════════════════

# Map weave_<rest> to its CLI command; echoes the command, rc=1 if none.
map_tool() {
    local rest="$1" cand first help
    local cands=()
    [ -n "${OVERRIDE[$rest]:-}" ] && cands+=("${OVERRIDE[$rest]}")
    cands+=("${rest//_/ }" "${rest//_/-}")
    for cand in "${cands[@]}"; do
        first=${cand%% *}
        # Multi-word commands expand intentionally.
        # shellcheck disable=SC2086
        help=$("$WV" $cand --help 2>&1 || true)
        # Real subcommand help starts "Usage: wv <cmd>"; the global fallback
        # for unknown commands starts "Usage: wv <command>".
        if echo "$help" | grep -qE "^Usage: wv $first"; then
            echo "$cand"
            return 0
        fi
    done
    return 1
}

# CLI flags missing from a tool's schema (after normalization + ignores),
# one "<tool> <--flag>" per line. $1=tool $2=cli_cmd $3=schema_file
parity_gaps() {
    local tool="$1" cli_cmd="$2" schema_file="$3" cli_flags props
    # shellcheck disable=SC2086
    cli_flags=$("$WV" $cli_cmd --help 2>&1 | grep -oE '\-\-[a-z][a-z-]*' | sort -u || true)
    props=$(jq -r --arg t "$tool" \
        '.[] | select(.name==$t) | .inputSchema.properties // {} | keys[]' \
        "$schema_file" | sed 's/_/-/g; s/^/--/' | sort -u)
    comm -23 <(echo "$cli_flags") <(echo "$props") \
        | grep -E '^--' | grep -vE "$GLOBAL_IGNORE" | sed "s/^/$tool /" || true
}

new_gaps=""
checked=0
skipped=0
while read -r tool; do
    rest=${tool#weave_}
    if echo "$SKIP_TOOLS" | tr ' ' '\n' | grep -qxF "$rest"; then
        skipped=$((skipped + 1))
        continue
    fi
    if ! cli_cmd=$(map_tool "$rest"); then
        echo -e "  ${YELLOW}⊘${NC} $tool — no CLI counterpart found (skipped)"
        skipped=$((skipped + 1))
        continue
    fi
    checked=$((checked + 1))
    while read -r gap; do
        [ -z "$gap" ] && continue
        echo "$BASELINE" | grep -qxF "$gap" && continue
        new_gaps="$new_gaps$gap"$'\n'
    done < <(parity_gaps "$tool" "$cli_cmd" "$SCHEMA")
done < <(jq -r '.[].name' "$SCHEMA")

if [ "$checked" -ge 35 ]; then
    pass "parity checked on $checked tools ($skipped skip-documented)"
else
    fail "parity checked on $checked tools ($skipped skip-documented)" "expected >= 35; mapping regression?"
fi

if [ -z "$new_gaps" ]; then
    pass "no NEW CLI flag missing from MCP schemas (baseline: $(echo "$BASELINE" | grep -c '^weave_') accepted gaps)"
else
    fail "no NEW CLI flag missing from MCP schemas" "new drift: $(echo "$new_gaps" | tr '\n' ' ')"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Execution smoke — tools/call must actually run, not just list schemas.
# Catches spawn-layer breakage (e.g. Codex spawnSync error.code=EPERM with
# exit 0, treated as fatal pre-fix) that schema/list parity cannot see.
# ═══════════════════════════════════════════════════════════════════════════

call_out=$(printf '%s\n%s\n%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"parity-test","version":"0"}}}' \
    '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
    '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"weave_guide","arguments":{"topic":"workflow"}}}' \
    | timeout 20 node "$MCP_DIST" --scope=all 2>/dev/null \
    | jq -rs '[.[] | select(.id==3)][0].result.content[0].text // empty' || true)
if [ -n "$call_out" ] && ! echo "$call_out" | grep -qi "^Error:"; then
    pass "tools/call executes a real command (weave_guide returned content)"
else
    fail "tools/call executes a real command (weave_guide returned content)" "output: '${call_out:0:120}'"
fi

# DB-read smoke: weave_query routes through the read path against the live
# graph — catches read-path breakage (e.g. wvRead --mode appended to a
# command that rejects it) that the shell-out smoke above cannot see.
query_out=$(printf '%s\n%s\n%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"parity-test","version":"0"}}}' \
    '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
    '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"weave_query","arguments":{"predicates":["status=done"],"limit":1}}}' \
    | timeout 20 node "$MCP_DIST" --scope=all 2>/dev/null \
    | jq -rs '[.[] | select(.id==4)][0].result.content[0].text // empty' || true)
if [ -n "$query_out" ] && ! echo "$query_out" | grep -qi "unknown option"; then
    pass "tools/call weave_query reads the graph (no unknown-option error)"
else
    fail "tools/call weave_query reads the graph (no unknown-option error)" "output: '${query_out:0:120}'"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Red-tests — the v1.51.0 weave_unarchive --with-edges bug shape
# ═══════════════════════════════════════════════════════════════════════════

# Control: the v1.51.0 fix holds — with_edges is exposed today.
gaps=$(parity_gaps "weave_unarchive" "unarchive" "$SCHEMA")
if ! echo "$gaps" | grep -qF -- "--with-edges"; then
    pass "control: weave_unarchive exposes --with-edges (v1.51.0 fix holds)"
else
    fail "control: weave_unarchive exposes --with-edges (v1.51.0 fix holds)" "$gaps"
fi

# Red: strip with_edges from a schema copy; the checker must flag it.
MUTILATED="$TEST_DIR/mutilated-schema.json"
jq 'map(if .name == "weave_unarchive" then del(.inputSchema.properties.with_edges) else . end)' \
    "$SCHEMA" > "$MUTILATED"
gaps=$(parity_gaps "weave_unarchive" "unarchive" "$MUTILATED")
if echo "$gaps" | grep -qxF "weave_unarchive --with-edges"; then
    pass "red-test: removing with_edges from the schema is flagged (v1.51.0 bug shape)"
else
    fail "red-test: removing with_edges from the schema is flagged (v1.51.0 bug shape)" "checker output: '$gaps'"
fi

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
