#!/bin/bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# test-analyze.sh — Tests for wv analyze sessions --call-stats
# Weave-ID: wv-ad7df8

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$REPO_ROOT/scripts/wv"

# Counter for tests
TESTS_RUN=0
TESTS_PASSED=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-contains assertion}"
    if echo "$haystack" | grep -qF -- "$needle"; then
        echo -e "  ${GREEN}✓${NC} $msg"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗${NC} $msg"
        echo "    Expected to contain: '$needle'"
        echo "    Actual: '$haystack'"
    fi
    TESTS_RUN=$((TESTS_RUN + 1))
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-not contains assertion}"
    if ! echo "$haystack" | grep -qF -- "$needle"; then
        echo -e "  ${GREEN}✓${NC} $msg"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗${NC} $msg"
        echo "    Expected NOT to contain: '$needle'"
        echo "    Actual: '$haystack'"
    fi
    TESTS_RUN=$((TESTS_RUN + 1))
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-equality assertion}"
    if [ "$expected" = "$actual" ]; then
        echo -e "  ${GREEN}✓${NC} $msg"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗${NC} $msg"
        echo "    Expected: '$expected'"
        echo "    Actual:   '$actual'"
    fi
    TESTS_RUN=$((TESTS_RUN + 1))
}

# ═══════════════════════════════════════════════════════════════════════════
# Setup — synthetic call log
# ═══════════════════════════════════════════════════════════════════════════

LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT

# Write 3 synthetic entries: wv show (largest), wv status, wv ready
cat >"$LOG" <<'EOF'
{"ts":1000000000.0,"cmd":"wv show","stdout_bytes":9000,"stderr_bytes":500,"elapsed_ms":80}
{"ts":1000000001.0,"cmd":"wv status","stdout_bytes":100,"stderr_bytes":0,"elapsed_ms":15}
{"ts":1000000002.0,"cmd":"wv ready","stdout_bytes":4500,"stderr_bytes":0,"elapsed_ms":30}
{"ts":1000000003.0,"cmd":"wv show","stdout_bytes":8000,"stderr_bytes":0,"elapsed_ms":75}
EOF

echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
echo "  wv analyze sessions --call-stats"
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""

# ───────────────────────────────────────────────────────────────────────────
# Test 1: basic output contains top command
# ───────────────────────────────────────────────────────────────────────────
output=$($WV analyze sessions --call-stats --log="$LOG" 2>&1)
assert_contains "$output" "wv show" "top command 'wv show' appears in output"

# ───────────────────────────────────────────────────────────────────────────
# Test 2: aggregation — wv show has 2 calls totalling 17500 bytes
# ───────────────────────────────────────────────────────────────────────────
output=$($WV analyze sessions --call-stats --log="$LOG" 2>&1)
assert_contains "$output" "17500" "wv show bytes aggregated correctly (9000+500+8000 = 17500)"

# ───────────────────────────────────────────────────────────────────────────
# Test 3: ordering — wv show before wv ready (17500 > 4500)
# Output may be single-line JSON, so check string position within line
# ───────────────────────────────────────────────────────────────────────────
show_pos=$(echo "$output" | tr ',' '\n' | grep -n '"wv show"' | head -1 | cut -d: -f1)
ready_pos=$(echo "$output" | tr ',' '\n' | grep -n '"wv ready"' | head -1 | cut -d: -f1)
if [ -n "$show_pos" ] && [ -n "$ready_pos" ] && [ "$show_pos" -lt "$ready_pos" ]; then
    echo -e "  ${GREEN}✓${NC} wv show ranked before wv ready"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗${NC} wv show ranked before wv ready"
    echo "    show_pos=$show_pos ready_pos=$ready_pos"
fi
TESTS_RUN=$((TESTS_RUN + 1))

# ───────────────────────────────────────────────────────────────────────────
# Test 4: --top=1 limits output to single entry
# ───────────────────────────────────────────────────────────────────────────
output=$($WV analyze sessions --call-stats --log="$LOG" --top=1 2>&1)
assert_contains "$output" "wv show" "--top=1 includes top entry"
assert_not_contains "$output" "wv status" "--top=1 excludes lower entries"

# ───────────────────────────────────────────────────────────────────────────
# Test 5: missing log produces informative message (not a crash)
# Output varies by mode (JSON in discover/bootstrap, human text otherwise),
# but both paths include "no call log found".
# ───────────────────────────────────────────────────────────────────────────
output=$($WV analyze sessions --call-stats --log=/nonexistent/path.jsonl 2>&1 || true)
assert_contains "$output" "no call log found" "missing log shows informative message"

# ───────────────────────────────────────────────────────────────────────────
# Test 6: WV_CALL_LOG env var picked up as default log path
# ───────────────────────────────────────────────────────────────────────────
output=$(WV_CALL_LOG="$LOG" $WV analyze sessions --call-stats 2>&1)
assert_contains "$output" "wv show" "WV_CALL_LOG env var used as default log"

# ───────────────────────────────────────────────────────────────────────────
# Test 7: --token-hogs still accepted as backwards-compat alias
# ───────────────────────────────────────────────────────────────────────────
output=$($WV analyze sessions --token-hogs --log="$LOG" 2>&1)
assert_contains "$output" "wv show" "--token-hogs alias still works"

# ───────────────────────────────────────────────────────────────────────────
# Test 8: byte-derived estimate is explicitly named, never presented as actual tokens
# ───────────────────────────────────────────────────────────────────────────
output=$(WV_MODE=discover $WV analyze sessions --call-stats --log="$LOG" 2>&1)
assert_contains "$output" "estimated_output_tokens" "estimated output token field in JSON output"
assert_not_contains "$output" "approx_tokens" "legacy ambiguous token estimate name is absent"
show_estimate=$(printf '%s' "$output" | jq -r '.call_stats[] | select(.cmd == "wv show") | .estimated_output_tokens')
assert_eq "4250" "$show_estimate" "output token estimate derives from stdout bytes only"

# ═══════════════════════════════════════════════════════════════════════════
# Windowing + sync exclusion (wv-079d76 — era-blind call-stats)
# Fixture: one 30-day-old entry, one fresh entry, one fresh sync entry,
# one entry with no timestamp.
# ═══════════════════════════════════════════════════════════════════════════
WLOG=$(mktemp)
NOW=$(date +%s)
OLD=$((NOW - 30 * 86400))
cat >"$WLOG" <<EOF
{"ts":$OLD.0,"cmd":"wv oldcmd","stdout_bytes":1000,"stderr_bytes":0,"elapsed_ms":5,"source":"shell"}
{"ts":$NOW.0,"cmd":"wv newcmd","stdout_bytes":2000,"stderr_bytes":0,"elapsed_ms":5,"source":"shell"}
{"ts":$NOW.0,"cmd":"wv synccmd","stdout_bytes":99999,"stderr_bytes":0,"elapsed_ms":5,"source":"sync"}
{"cmd":"wv notscmd","stdout_bytes":10,"stderr_bytes":0,"elapsed_ms":5,"source":"shell"}
{"ts":$NOW.0,"cmd":"wv testcmd","stdout_bytes":5000,"stderr_bytes":0,"elapsed_ms":5,"source":"test"}
{"ts":$NOW.0,"cmd":"wv agentcmd","stdout_bytes":3000,"stderr_bytes":0,"elapsed_ms":5,"source":"agent"}
EOF

# Test W1: source=sync excluded by default, exclusion reported
output=$(WV_MODE=discover $WV analyze sessions --call-stats --log="$WLOG" 2>&1)
assert_not_contains "$output" "wv synccmd" "sync traffic excluded by default"
assert_contains "$output" '"sync_calls": 1' "excluded sync call count reported"

# Test W2: --include-sync restores sync traffic
output=$(WV_MODE=discover $WV analyze sessions --call-stats --log="$WLOG" --include-sync 2>&1)
assert_contains "$output" "wv synccmd" "--include-sync counts sync traffic"

# Test W3: explicit --source=sync is an implicit opt-in
output=$(WV_MODE=discover $WV analyze sessions --call-stats --log="$WLOG" --source=sync 2>&1)
assert_contains "$output" "wv synccmd" "--source=sync includes sync traffic"
assert_not_contains "$output" "wv newcmd" "--source=sync excludes other sources"

# Test W4: --since-days=7 drops the 30-day-old entry and the no-ts entry
output=$(WV_MODE=discover $WV analyze sessions --call-stats --log="$WLOG" --since-days=7 2>&1)
assert_contains "$output" "wv newcmd" "--since-days keeps in-window entry"
assert_not_contains "$output" "wv oldcmd" "--since-days drops out-of-window entry"
assert_not_contains "$output" "wv notscmd" "--since-days drops entries with no timestamp"
assert_contains "$output" '"no_ts": 1' "no-timestamp exclusion count reported"
assert_contains "$output" '"window"' "window metadata present in JSON"

# Test W5: --since=<epoch> works as an absolute cutoff
output=$(WV_MODE=discover $WV analyze sessions --call-stats --log="$WLOG" --since=$((NOW - 86400)) 2>&1)
assert_contains "$output" "wv newcmd" "--since=<epoch> keeps recent entry"
assert_not_contains "$output" "wv oldcmd" "--since=<epoch> drops old entry"

# Test W6: --since=<YYYY-MM-DD> date form accepted
output=$(WV_MODE=discover $WV analyze sessions --call-stats --log="$WLOG" --since=2001-01-01 2>&1)
assert_contains "$output" "wv oldcmd" "--since=<date> includes entries after the date"

# Test W7: invalid --since / --since-days rejected with clear error
output=$($WV analyze sessions --call-stats --log="$WLOG" --since=notadate 2>&1 || true)
assert_contains "$output" "invalid --since" "invalid --since value rejected"
output=$($WV analyze sessions --call-stats --log="$WLOG" --since-days=abc 2>&1 || true)
assert_contains "$output" "invalid --since-days" "invalid --since-days value rejected"

# Test W8: --json forces JSON output even outside discover mode
output=$(WV_MODE=execute $WV analyze sessions --call-stats --log="$WLOG" --json 2>&1)
assert_contains "$output" '"call_stats"' "--json forces JSON output in execute mode"

# Test W9: no window + wide span emits lifetime-aggregate note
output=$(WV_MODE=discover $WV analyze sessions --call-stats --log="$WLOG" 2>&1)
assert_contains "$output" "lifetime aggregate" "wide unwindowed span carries era advisory note"

# Test W10: human table footer reports sync exclusion
output=$(WV_MODE=execute $WV analyze sessions --call-stats --log="$WLOG" 2>&1)
assert_contains "$output" "sync-internal" "table footer reports sync exclusion"

# Test W11: source=test excluded by default, exclusion reported (wv-67871d)
output=$(WV_MODE=discover $WV analyze sessions --call-stats --log="$WLOG" 2>&1)
assert_not_contains "$output" "wv testcmd" "test-suite traffic excluded by default"
assert_contains "$output" '"test_calls": 1' "excluded test call count reported"

# Test W12: --include-test restores suite traffic; --source=test is implicit opt-in
output=$(WV_MODE=discover $WV analyze sessions --call-stats --log="$WLOG" --include-test 2>&1)
assert_contains "$output" "wv testcmd" "--include-test counts suite traffic"
output=$(WV_MODE=discover $WV analyze sessions --call-stats --log="$WLOG" --source=test 2>&1)
assert_contains "$output" "wv testcmd" "--source=test includes suite traffic"
assert_not_contains "$output" "wv newcmd" "--source=test excludes other sources"

# Test W13: agent-tagged traffic counted normally and filterable
output=$(WV_MODE=discover $WV analyze sessions --call-stats --log="$WLOG" --source=agent 2>&1)
assert_contains "$output" "wv agentcmd" "--source=agent isolates agent traffic"

# Test W14: hook-common forces WV_CALL_SOURCE=hook even when session env says agent
hooked=$(WV_CALL_SOURCE=agent bash -c 'source "'"$REPO_ROOT"'/scripts/lib/wv-hook-common.sh" 2>/dev/null; echo "$WV_CALL_SOURCE"')
if [ "$hooked" = "hook" ]; then
    echo -e "  ${GREEN}✓${NC} wv-hook-common.sh overrides inherited agent tag with hook"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗${NC} wv-hook-common.sh overrides inherited agent tag with hook (got: '$hooked')"
fi
TESTS_RUN=$((TESTS_RUN + 1))

echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
echo "  wv analyze sessions --trace-eval"
echo "═══════════════════════════════════════════════════════════════════════════"

TRACELOG=$(mktemp)
USAGELOG=$(mktemp)
trap 'rm -f "$LOG" "$WLOG" "$TRACELOG" "$USAGELOG"' EXIT
cat >"$TRACELOG" <<'EOF'
{"ts":1,"trace_id":"trace-a","call_id":"a1","turn_id":"turn-1","cmd":"wv query","argv":["query","x"],"exit_status":0,"graph_identity_before":{"kind":"sqlite_graph_fingerprint","value":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"graph_identity_after":{"kind":"sqlite_graph_fingerprint","value":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}
{"ts":2,"trace_id":"trace-a","call_id":"a2","cmd":"wv query","argv":["query","x"],"exit_status":0,"graph_identity_before":{"kind":"sqlite_graph_fingerprint","value":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"graph_identity_after":{"kind":"sqlite_graph_fingerprint","value":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}
{"ts":3,"trace_id":"trace-a","call_id":"a3","cmd":"wv query","argv":["query","x"],"exit_status":0,"graph_identity_before":{"kind":"sqlite_graph_fingerprint","value":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"},"graph_identity_after":{"kind":"sqlite_graph_fingerprint","value":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}}
{"ts":4,"trace_id":"trace-a","call_id":"a4","cmd":"wv query","argv":["query","x"],"exit_status":0,"graph_identity_after":{"status":"unavailable","reason":"old row"}}
EOF
cat >"$USAGELOG" <<'EOF'
{"format":"weave.provider-usage","version":1,"trace_id":"trace-a","usage_event_id":"usage-1","usage_kind":"incremental","provenance":{"host":"claude-code","adapter":"session-export","adapter_version":"1","provider":"anthropic","model":"claude-test"},"usage":{"input_tokens":12,"output_tokens":3,"cache_read_input_tokens":5,"cache_creation_input_tokens":7,"cost_usd":null}}
{"format":"weave.provider-usage","version":1,"trace_id":"not-in-call-log","usage_event_id":"usage-2","usage_kind":"incremental","provenance":{"host":"codex","adapter":"session-export","adapter_version":"1","provider":"openai","model":"gpt-test"},"usage":{"input_tokens":20,"output_tokens":4}}
EOF
output=$($WV analyze sessions --trace-eval --log="$TRACELOG" --usage-log="$USAGELOG" --json 2>&1)
assert_contains "$output" '"format": "weave.trace-observations"' "trace evaluator emits explicit format"
assert_contains "$output" '"repeated_query_context": 1' "only unchanged-state repeated query is observed"
assert_contains "$output" '"query_context_comparisons_available": 2' "changed identity is comparable but not repeated"
assert_contains "$output" '"query_context_comparisons_unavailable": 1' "missing identity comparison is unavailable"
assert_contains "$output" '"distinct": 1, "missing_turn_calls": 3' "turn unavailability is explicit"
assert_not_contains "$output" 'gate_outcome' "trace output has no gate outcome"
assert_not_contains "$output" '"pass"' "trace output has no pass authority"
assert_not_contains "$output" 'violations' "trace output does not label observations violations"
assert_contains "$output" '"provider": "anthropic"' "matched actual usage retains provider provenance"
assert_contains "$output" '"input_tokens": {"available_events": 1, "unavailable_events": 0, "value": 12}' "actual input usage is joined"
assert_contains "$output" '"unmatched_rows": 1' "unmatched usage remains explicit"

INSTALLED_LIB=$(mktemp -d)
mkdir -p "$INSTALLED_LIB/profiling"
cp "$REPO_ROOT/profiling/audit_sessions.py" "$INSTALLED_LIB/profiling/audit_sessions.py"
installed_output=$(WV_LIB_DIR="$INSTALLED_LIB" bash -c '
    wv_resolve_mode() { echo execute; }
    source "$1"
    cmd_analyze_sessions --trace-eval --log="$2" --json
' _ "$REPO_ROOT/scripts/cmd/wv-cmd-analyze.sh" "$TRACELOG")
assert_contains "$installed_output" '"format": "weave.trace-observations"' "installed library layout resolves trace evaluator"
if $WV analyze sessions --trace-eval --log="$TRACELOG" --unknown-trace-option >/dev/null 2>&1; then
    echo -e "  ${RED}✗${NC} trace evaluator rejects unknown options"
else
    echo -e "  ${GREEN}✓${NC} trace evaluator rejects unknown options"
    TESTS_PASSED=$((TESTS_PASSED + 1))
fi
TESTS_RUN=$((TESTS_RUN + 1))
rm -rf "$INSTALLED_LIB"

echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
echo "  wv analyze suites (LL3 — durable suite-run history)"
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""

# Synthetic suite history: test-core 3 runs (1 fail, durs 180k/200k/160k),
# test-graph 2 runs (durs 35k/40k). nearest-rank p95 of core = 200000.
SUITELOG=$(mktemp)
trap 'rm -f "$LOG" "$WLOG" "$SUITELOG"' EXIT
cat >"$SUITELOG" <<'EOF'
{"ts":"2026-05-31T10:00:00Z","repo":"r","suite":"tests/test-core.sh","files":"a.sh","exit":0,"duration_ms":180000,"sha":"aaa1"}
{"ts":"2026-05-31T10:05:00Z","repo":"r","suite":"tests/test-core.sh","files":"b.sh","exit":1,"duration_ms":200000,"sha":"aaa2"}
{"ts":"2026-05-31T10:10:00Z","repo":"r","suite":"tests/test-core.sh","files":"c.sh","exit":0,"duration_ms":160000,"sha":"aaa3"}
{"ts":"2026-05-31T09:00:00Z","repo":"r","suite":"tests/test-graph.sh","files":"x.sh","exit":0,"duration_ms":35000,"sha":"bbb1"}
{"ts":"2026-05-31T09:30:00Z","repo":"r","suite":"tests/test-graph.sh","files":"y.sh","exit":0,"duration_ms":40000,"sha":"bbb2"}
EOF

# Test 9: reads the durable history (suite name appears). Fixture uses repo="r";
# use --all so these aggregation tests are not affected by the default repo filter.
output=$(WV_MODE=discover $WV analyze suites --log="$SUITELOG" --all 2>&1)
assert_contains "$output" "tests/test-core.sh" "analyze suites reads the history log"

# Test 10: total_ms aggregated per suite (180000+200000+160000 = 540000)
assert_contains "$output" '"total_ms": 540000' "per-suite total duration aggregated"

# Test 11: avg + p95 reported (avg 180000, p95 nearest-rank = 200000)
assert_contains "$output" '"avg_ms": 180000' "avg duration reported"
assert_contains "$output" '"p95_ms": 200000' "p95 duration (nearest-rank) reported"

# Test 12: pass/fail counts (core: 2 pass, 1 fail)
assert_contains "$output" '"passed": 2' "pass count reported"
assert_contains "$output" '"failed": 1' "fail count reported"

# Test 13: heaviest suite sorted first (core total 540000 > graph 75000)
core_pos=$(echo "$output" | tr ',' '\n' | grep -n 'test-core.sh' | head -1 | cut -d: -f1)
graph_pos=$(echo "$output" | tr ',' '\n' | grep -n 'test-graph.sh' | head -1 | cut -d: -f1)
if [ -n "$core_pos" ] && [ -n "$graph_pos" ] && [ "$core_pos" -lt "$graph_pos" ]; then
    echo -e "  ${GREEN}✓${NC} heaviest suite (test-core) sorted first"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗${NC} heaviest suite sorted first (core_pos=$core_pos graph_pos=$graph_pos)"
fi
TESTS_RUN=$((TESTS_RUN + 1))

# Test 14: text table mode (execute) renders a P95_MS column header
output=$(WV_MODE=execute $WV analyze suites --log="$SUITELOG" --all 2>&1)
assert_contains "$output" "P95_MS" "text mode renders a table with P95_MS column"

# Test 15: --json forces JSON even in execute mode
output=$(WV_MODE=execute $WV analyze suites --log="$SUITELOG" --all --json 2>&1)
assert_contains "$output" '"suites"' "--json forces JSON output in execute mode"

# Test 16: malformed lines are skipped (still 5 valid runs)
echo 'not json {{{' >>"$SUITELOG"
output=$(WV_MODE=discover $WV analyze suites --log="$SUITELOG" --all 2>&1)
assert_contains "$output" '"total_runs": 5' "malformed log lines skipped (5 valid runs survive)"

# Test 17: empty/missing history is graceful (JSON)
output=$(WV_MODE=discover $WV analyze suites --log=/nonexistent/suite_runs.jsonl 2>&1 || true)
assert_contains "$output" "no suite history recorded yet" "missing history shows graceful message"

# Test 18: WV_SUITE_LOG env var used as default log path
output=$(WV_MODE=discover WV_SUITE_LOG="$SUITELOG" $WV analyze suites --all 2>&1)
assert_contains "$output" "tests/test-core.sh" "WV_SUITE_LOG env var used as default log"

# Test 19: --repo=r filters to fixture repo, shows data
output=$(WV_MODE=discover $WV analyze suites --log="$SUITELOG" --repo=r 2>&1)
assert_contains "$output" "tests/test-core.sh" "--repo=r filters to matching repo rows"

# Test 20: --repo=other returns empty (no rows for that repo)
output=$(WV_MODE=execute $WV analyze suites --log="$SUITELOG" --repo=other 2>&1)
assert_contains "$output" "No suite history for repo 'other'" "--repo=other shows no-data message"

# Test 21: JSON output includes repo scope field
output=$(WV_MODE=discover $WV analyze suites --log="$SUITELOG" --repo=r 2>&1)
assert_contains "$output" '"repo": "r"' "JSON output includes repo scope field"

# ═══════════════════════════════════════════════════════════════════════════
# Call instrumentation append safety (wv-ac0f6a — calllog-leak)
# Fresh WV_CONFIG_DIR so config.env cannot override the test's WV_CALL_LOG.
# ═══════════════════════════════════════════════════════════════════════════

# Test 22: unwritable WV_CALL_LOG produces zero stderr noise
ISOCONF=$(mktemp -d)
stderr_out=$(WV_CONFIG_DIR="$ISOCONF" WV_CALL_LOG=/nonexistent-dir/wv_calls.jsonl $WV --version 2>&1 >/dev/null)
assert_not_contains "$stderr_out" "nonexistent-dir" "unwritable WV_CALL_LOG leaks no redirection error"

# Test 23: writable WV_CALL_LOG still records the invocation
WRITELOG="$ISOCONF/calls.jsonl"
WV_CONFIG_DIR="$ISOCONF" WV_CALL_LOG="$WRITELOG" $WV --version >/dev/null 2>&1
logged=$(cat "$WRITELOG" 2>/dev/null || true)
assert_contains "$logged" '"cmd":"wv --version"' "writable WV_CALL_LOG records invocation"
call_contract_ok=$(printf '%s' "$logged" | jq -r '.exit_status == 0 and (.call_id | length > 0) and .policy_revision.status == "unavailable" and .policy_revision.provenance == "wv_call_log"' 2>/dev/null || true)
assert_contains "$call_contract_ok" "true" "call record exposes exit, call identity, and unavailable policy revision"

# All externally supplied identity characters must remain valid JSONL.
WV_CONFIG_DIR="$ISOCONF" WV_CALL_LOG="$WRITELOG" WV_CALL_ID=$'call\tid\v' $WV --version >/dev/null 2>&1
control_row=$(tail -1 "$WRITELOG" 2>/dev/null || true)
control_json_ok=$(printf '%s' "$control_row" | jq -r '.call_id == "call\tid\u000b" and .trace_id == .call_id' 2>/dev/null || true)
assert_contains "$control_json_ok" "true" "control characters in correlation IDs are JSON escaped"

# Test 24: short free-text option values are structurally redacted
SHORT_SECRET="short-secret"
WV_CONFIG_DIR="$ISOCONF" WV_CALL_LOG="$WRITELOG" $WV update wv-abc123 --metadata="{\"token\":\"$SHORT_SECRET\"}" >/dev/null 2>&1 || true
logged=$(tail -1 "$WRITELOG" 2>/dev/null || true)
assert_not_contains "$logged" "$SHORT_SECRET" "short free-text argv value is not logged"
assert_contains "$logged" '"--metadata=<redacted:' "inline free-text option retains only normalized option name"
WV_CONFIG_DIR="$ISOCONF" WV_CALL_LOG="$WRITELOG" $WV update wv-abc123 --text=é >/dev/null 2>&1 || true
logged=$(tail -1 "$WRITELOG" 2>/dev/null || true)
assert_contains "$logged" '"--text=<redacted:2>"' "redaction marker records UTF-8 byte length"

# Flag-shaped, ID-shaped, split-form, nested-command, and invalid-operation values also fail closed.
: > "$WRITELOG"
WV_CONFIG_DIR="$ISOCONF" WV_CALL_LOG="$WRITELOG" $WV guide --topic="$SHORT_SECRET" >/dev/null 2>&1 || true
WV_CONFIG_DIR="$ISOCONF" WV_CALL_LOG="$WRITELOG" $WV config set CONFIG_VALUE --private-value >/dev/null 2>&1 || true
WV_CONFIG_DIR="$ISOCONF" WV_CALL_LOG="$WRITELOG" $WV update wv-abc123 --text wv-badbad >/dev/null 2>&1 || true
WV_CONFIG_DIR="$ISOCONF" WV_CALL_LOG="$WRITELOG" $WV update wv-abc123 --metadata "$SHORT_SECRET" >/dev/null 2>&1 || true
WV_CONFIG_DIR="$ISOCONF" WV_CALL_LOG="$WRITELOG" $WV update wv-abc123 --metadata-file wv-dead >/dev/null 2>&1 || true
WV_CONFIG_DIR="$ISOCONF" WV_CALL_LOG="$WRITELOG" $WV update wv-abc123 --metadata-file --json >/dev/null 2>&1 || true
WV_CONFIG_DIR="$ISOCONF" WV_CALL_LOG="$WRITELOG" $WV "$SHORT_SECRET" >/dev/null 2>&1 || true
logged=$(cat "$WRITELOG" 2>/dev/null || true)
assert_not_contains "$logged" "$SHORT_SECRET" "all short secret shapes are absent from argv and cmd"
assert_not_contains "$logged" "--private-value" "flag-shaped config value is redacted"
assert_not_contains "$logged" "wv-badbad" "ID-shaped free text outside an ID position is redacted"
assert_not_contains "$logged" "wv-dead" "ID-shaped split-form option operand is redacted"
assert_not_contains "$logged" '"--metadata-file","--json"' "option-shaped split-form operand is redacted"
assert_contains "$logged" '"argv":["update","wv-abc123","--metadata","<redacted:12>"]' "split-form value redacts while positional node ID remains joinable"

# Canonical IDs remain visible only in declared ID-bearing positions.
WV_CONFIG_DIR="$ISOCONF" WV_CALL_LOG="$WRITELOG" $WV add "parent probe" --parent=wv-abc123 --force >/dev/null 2>&1 || true
logged=$(tail -1 "$WRITELOG" 2>/dev/null || true)
assert_contains "$logged" '"--parent=wv-abc123"' "inline parent node ID remains joinable"

# Test 25: trace_id defaults to workflow_id and accepts an explicit correlation id
WV_CONFIG_DIR="$ISOCONF" WV_CALL_LOG="$WRITELOG" WV_WORKFLOW_ID=workflow-123 $WV --version >/dev/null 2>&1
logged=$(tail -1 "$WRITELOG" 2>/dev/null || true)
assert_contains "$logged" '"workflow_id":"workflow-123","trace_id":"workflow-123"' "workflow id supplies default trace correlation"
WV_CONFIG_DIR="$ISOCONF" WV_CALL_LOG="$WRITELOG" WV_WORKFLOW_ID=workflow-123 WV_TRACE_ID=trace-456 $WV --version >/dev/null 2>&1
logged=$(tail -1 "$WRITELOG" 2>/dev/null || true)
assert_contains "$logged" '"trace_id":"trace-456"' "explicit trace correlation overrides workflow default"
WV_CONFIG_DIR="$ISOCONF" WV_CALL_LOG="$WRITELOG" env -u WV_WORKFLOW_ID -u WV_TRACE_ID $WV --version >/dev/null 2>&1
logged=$(tail -1 "$WRITELOG" 2>/dev/null || true)
trace_fallback_ok=$(printf '%s' "$logged" | jq -r '.trace_id == .call_id and (.trace_id | length > 0)' 2>/dev/null || true)
assert_contains "$trace_fallback_ok" "true" "trace correlation falls back to generated call id"

# Test 26: graph fingerprints compare across wrapper connections and detect mutation
GRAPH_REPO="$ISOCONF/graph-repo"
GRAPH_CONFIG="$ISOCONF/graph-config"
GRAPH_LOG="$ISOCONF/graph-calls.jsonl"
mkdir -p "$GRAPH_REPO" "$GRAPH_CONFIG"
git -C "$GRAPH_REPO" init -q
(cd "$GRAPH_REPO" && WV_CONFIG_DIR="$GRAPH_CONFIG" $WV init >/dev/null 2>&1)
(cd "$GRAPH_REPO" && WV_CONFIG_DIR="$GRAPH_CONFIG" WV_CALL_LOG="$GRAPH_LOG" $WV add "telemetry mutation" --force >/dev/null 2>&1)
mutation_row=$(tail -1 "$GRAPH_LOG" 2>/dev/null || true)
graph_mutation_ok=$(printf '%s' "$mutation_row" | jq -r '.graph_identity_before.kind == "sqlite_graph_fingerprint" and .graph_identity_after.kind == "sqlite_graph_fingerprint" and .graph_identity_before != .graph_identity_after' 2>/dev/null || true)
assert_contains "$graph_mutation_ok" "true" "graph fingerprint changes after a real mutation"
(cd "$GRAPH_REPO" && WV_CONFIG_DIR="$GRAPH_CONFIG" WV_CALL_LOG="$GRAPH_LOG" $WV status --json >/dev/null 2>&1)
read_row=$(tail -1 "$GRAPH_LOG" 2>/dev/null || true)
graph_read_ok=$(printf '%s' "$read_row" | jq -r '.graph_identity_before.kind == "sqlite_graph_fingerprint" and .graph_identity_after.kind == "sqlite_graph_fingerprint" and .graph_identity_before == .graph_identity_after' 2>/dev/null || true)
assert_contains "$graph_read_ok" "true" "graph fingerprint stays stable across a read-only call"
(cd "$GRAPH_REPO" && WV_CONFIG_DIR="$GRAPH_CONFIG" WV_CALL_LOG="$GRAPH_LOG" $WV ready --count >/dev/null 2>&1)
ready_row=$(tail -1 "$GRAPH_LOG" 2>/dev/null || true)
assert_contains "$ready_row" '"argv":["ready","--count"]' "supported ready flag remains visible in normalized operation identity"
(cd "$GRAPH_REPO" && WV_CONFIG_DIR="$GRAPH_CONFIG" WV_CALL_LOG="$GRAPH_LOG" $WV ready --subtree=wv-abc123 >/dev/null 2>&1) || true
subtree_inline_row=$(tail -1 "$GRAPH_LOG" 2>/dev/null || true)
assert_contains "$subtree_inline_row" '"--subtree=wv-abc123"' "inline subtree node ID remains joinable"
(cd "$GRAPH_REPO" && WV_CONFIG_DIR="$GRAPH_CONFIG" WV_CALL_LOG="$GRAPH_LOG" $WV ready --subtree wv-abc123 >/dev/null 2>&1) || true
subtree_split_row=$(tail -1 "$GRAPH_LOG" 2>/dev/null || true)
assert_contains "$subtree_split_row" '"argv":["ready","--subtree","wv-abc123"]' "split subtree node ID remains joinable"
(cd "$GRAPH_REPO" && WV_CONFIG_DIR="$GRAPH_CONFIG" WV_CALL_LOG="$GRAPH_LOG" $WV analyze sessions --call-stats --log="$TRACELOG" --json >/dev/null 2>&1)
analyze_row=$(tail -1 "$GRAPH_LOG" 2>/dev/null || true)
assert_contains "$analyze_row" '"argv":["analyze","sessions","--call-stats","--log=<redacted:' "analyze mode and log option remain visible while path is redacted"
rm -rf "$ISOCONF"

echo ""

# ═══════════════════════════════════════════════════════════════════════════
# Direct-agent source attribution adapters (wv-67517b)
# Codex/Copilot direct CLI calls have no per-call env injection like Claude's
# settings.json, so without an adapter they record as shell — indistinguishable
# from a human terminal. The wrapper attests "agent" from host-guaranteed exec
# markers when WV_CALL_SOURCE is unset. Explicit WV_CALL_SOURCE (mcp/hook/...)
# must always win. Contract: docs/TELEMETRY-SOURCE-CONTRACT.md
# Each case uses a fresh WV_CONFIG_DIR so config.env cannot inject WV_CALL_SOURCE,
# and a sandbox-writable WV_CALL_LOG (the Codex sandbox cannot write the default).
# ───────────────────────────────────────────────────────────────────────────
adapter_source() {
    # Run wv with a clean provenance env, echo the recorded "source" field.
    local conf log
    conf=$(mktemp -d)
    log="$conf/calls.jsonl"
    env -u WV_CALL_SOURCE -u CODEX_THREAD_ID -u CODEX_CI -u COPILOT_AGENT \
        WV_CONFIG_DIR="$conf" WV_CALL_LOG="$log" "$@" "$WV" --version >/dev/null 2>&1
    grep -o '"source":"[^"]*"' "$log" 2>/dev/null | tail -1
    rm -rf "$conf"
}

# Test 27: Codex direct CLI (CODEX_THREAD_ID) attests agent, not shell
src=$(adapter_source CODEX_THREAD_ID=thr_abc123)
assert_contains "$src" '"source":"agent"' "Codex CODEX_THREAD_ID direct call records agent"
assert_not_contains "$src" '"source":"shell"' "Codex direct call is not silently shell"

# Test 28: Codex CI marker (CODEX_CI=1) attests agent
src=$(adapter_source CODEX_CI=1)
assert_contains "$src" '"source":"agent"' "Codex CODEX_CI=1 direct call records agent"

# Test 29: VS Code Copilot direct CLI (COPILOT_AGENT=1) attests agent, not shell
src=$(adapter_source COPILOT_AGENT=1)
assert_contains "$src" '"source":"agent"' "Copilot COPILOT_AGENT=1 direct call records agent"
assert_not_contains "$src" '"source":"shell"' "Copilot direct call is not silently shell"

# Test 30: no host marker and no WV_CALL_SOURCE -> shell (unproven origin preserved)
src=$(adapter_source)
assert_contains "$src" '"source":"shell"' "Bare terminal with no marker stays shell"

# Test 31: explicit WV_CALL_SOURCE=mcp wins over a Codex marker (MCP children stay mcp)
src=$(adapter_source CODEX_THREAD_ID=thr_abc123 WV_CALL_SOURCE=mcp)
assert_contains "$src" '"source":"mcp"' "MCP override beats Codex marker (children stay mcp)"

# Test 32: explicit WV_CALL_SOURCE=hook wins over a Copilot marker
src=$(adapter_source COPILOT_AGENT=1 WV_CALL_SOURCE=hook)
assert_contains "$src" '"source":"hook"' "hook override beats Copilot marker"

# Test 33: spurious COPILOT_AGENT value (not "1") does not attest agent
src=$(adapter_source COPILOT_AGENT=0)
assert_contains "$src" '"source":"shell"' "COPILOT_AGENT=0 does not attest agent"

echo ""

# ═══════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════
echo "═══════════════════════════════════════════════════════════════════════════"
echo -e "Results: $TESTS_PASSED/$TESTS_RUN passed"
if [ "$TESTS_PASSED" -eq "$TESTS_RUN" ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed.${NC}"
    exit 1
fi
