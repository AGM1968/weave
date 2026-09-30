#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# The wv call tally lands where the hygiene score reads it (wv-76bb48).
#
# .claude/hooks/wv-budget-tally.sh wrote /dev/shm/weave/<hash>/session-budget.json
# while the call-discipline component read $WV_HOT_ZONE/session-budget.json. Under
# a sandboxed runtime the hot zone is /tmp/weave-codex-<uid>/<hash>, so the score
# never saw the file and awarded 25/25 however many calls were made. The existing
# check in test-sprint34.sh plants the file in the hot zone itself, so it tests
# the reader alone and could not see the mismatch. This suite drives the real
# hook and then reads the score, under each runtime class, with no hot-zone
# override: the resolution itself is what is under test.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WV="$ROOT/scripts/wv"
HOOK="$ROOT/.claude/hooks/wv-budget-tally.sh"
run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }

T=$(mktemp -d /tmp/wv-budget-loc-XXXXXX)
ZONES=()
cleanup() { rm -rf "$T"; for z in "${ZONES[@]}"; do [ -n "$z" ] && rm -rf "$z"; done; }
trap cleanup EXIT

# as_runtime <native|sandboxed> <cmd...> — run with only that class's marker set
# and every hot-zone override removed, in the scratch repo.
as_runtime() {
    local rt="$1"; shift
    local -a marker=()
    [ "$rt" = sandboxed ] && marker=(CLAUDE_CODE_SSE_PORT=1)
    (cd "$R" && env -u WV_HOT_ZONE -u WV_DB -u WV_PROJECT_DIR -u WEAVE_DIR -u WV_BUDGET_DIR \
        -u CODEX_THREAD_ID -u CODEX_CI -u COPILOT_AGENT -u CLAUDE_CODE_SSE_PORT \
        WV_CONFIG_DIR="$T/cfg-$rt" WV_AUTO_CHECKPOINT=0 WV_NONINTERACTIVE=1 "${marker[@]}" "$@")
}

for rt in native sandboxed; do
    echo "=== $rt runtime ==="
    R="$T/repo-$rt"; mkdir -p "$R" "$T/cfg-$rt"
    git -C "$R" init -q . && git -C "$R" config user.email t@t && git -C "$R" config user.name t
    as_runtime "$rt" "$WV" init >/dev/null 2>&1
    as_runtime "$rt" "$WV" load >/dev/null 2>&1   # session snapshot for session-summary
    db=$(as_runtime "$rt" "$WV" hotzone db 2>/dev/null)
    zone="${db%/*}"; ZONES+=("$zone")
    # Placement differs by host (a sandbox without a usable /dev/shm falls back
    # to /tmp); what is under test is that writer and reader agree on it.
    [ -n "$db" ] && ok "the CLI resolves a hot zone under the $rt runtime ($zone)" ||
        bad "the CLI resolves a hot zone under the $rt runtime" "no db path"
    # 25 wv calls through the real hook: 5 past the default threshold of 20.
    for _ in $(seq 25); do
        printf '{"tool_name":"Bash","tool_input":{"command":"wv status"},"tool_response":{"output":"x"}}' |
            as_runtime "$rt" bash "$HOOK" >/dev/null 2>&1
    done
    calls=$(jq -r '.calls // 0' "$zone/session-budget.json" 2>/dev/null || echo missing)
    [ "$calls" = 25 ] && ok "the hook tallies into the $rt hot zone" ||
        bad "the hook tallies into the $rt hot zone" "calls in $zone: $calls"
    score=$(as_runtime "$rt" "$WV" session-summary --json 2>/dev/null | jq -r '.hygiene.call_discipline' 2>/dev/null)
    [ "$score" = 20 ] && ok "the $rt score reads that tally (25 calls -> 20/25)" ||
        bad "the $rt score reads that tally (25 calls -> 20/25)" "call_discipline=$score"
done

echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
