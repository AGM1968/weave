#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# test-memory-exposure.sh — graph-only versus rendered memory (wv-287b39)
#
# metadata.exposure says whether a memory is rendered: "rendered" (the default,
# also when absent) or "graph-only". A graph-only memory is left out of every
# rendered surface (the projection files, bootstrap's index, the doctor's block
# budget) and stays in graph recall (wv memory recall, wv show, wv search).
#
# Covers:
#   - capture: wv remember --exposure=graph-only persists the field; a bad
#     value is refused; absent stays absent (no silent migration)
#   - update: an existing memory changes exposure only through a review
#     verdict (--verdict=exposure --exposure=... --reason=...) applied by
#     wv memory review --apply, which keeps who, when and why; the verdict
#     refuses without a reason, on a memory that is not active, on a bad or
#     unchanged value;
#     wv memory exposure <id> only shows, and refuses a value or a non-memory
#   - supersede: the successor inherits its predecessor's exposure unless told
#   - every renderer: CLAUDE.md, copilot-instructions.md, .codex/weave.json,
#     a marked AGENTS.md, bootstrap's index (with a graph_only count) and the
#     doctor's block budget leave a graph-only memory out
#   - recall is not narrowed: recall, show and search still return it
#   - a memory set back to rendered returns to the projections
#   - the checkpoint's and the gate's change filters see an exposure flip
#
# Exit codes:
#   0 - All tests passed
#   1 - Unexpected failure

set -euo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$PROJECT_ROOT/scripts/wv"

SCRATCH=$(bash "$PROJECT_ROOT/scripts/lib/wv-scratch.sh")
export TMPDIR="$SCRATCH"
unset WV_SCRATCH_ROOT
TEST_DIR="$SCRATCH/repo"
export WV_HOT_ZONE="$TEST_DIR/hot"
export WV_DB="$WV_HOT_ZONE/brain.db"
export WV_REQUIRE_LEARNING=0
export WV_RUN_CACHE=0
export WV_AUTO_CHECKPOINT=0
export WV_PROJECT_DIR="$TEST_DIR"
export WV_CONFIG_DIR="$SCRATCH/config"
export WV_SUITE_LOG="$TEST_DIR/suite_runs.jsonl"

cleanup() { cd / && rm -rf "$SCRATCH"; }
trap cleanup EXIT

pass() { echo -e "${GREEN}✓${NC} $1"; TESTS_RUN=$((TESTS_RUN + 1)); TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo -e "${RED}✗${NC} $1"; [ -z "${2:-}" ] || echo "  $2"; TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1)); }
check() { # check <message> <command...>
    local msg="$1"; shift
    if "$@" >/dev/null 2>&1; then pass "$msg"; else fail "$msg"; fi
}

mkdir -p "$TEST_DIR" "$WV_CONFIG_DIR"
cd "$TEST_DIR"
git init -q
"$WV" init >/dev/null 2>&1

_id() { jq -r '.id'; }
SHOWN=$("$WV" remember "Shown memory first sentence. SHOWN-BODY." --json 2>/dev/null | _id)
HIDDEN=$("$WV" remember "Hidden memory first sentence. HIDDEN-BODY-TOKEN." --exposure=graph-only --json 2>/dev/null | _id || true)
PLAIN_TASK=""
add_out=$("$WV" add "an ordinary task node" --standalone --force 2>/dev/null || true)
[[ "$add_out" =~ (wv-[0-9a-f]{6}) ]] && PLAIN_TASK="${BASH_REMATCH[1]}"

_meta() { "$WV" show "$1" --json 2>/dev/null | jq -r "(.[0]? // .) | .metadata | (fromjson? // .) | $2"; }

echo ""
echo "Capture and update"
echo "=================="
if [[ "$HIDDEN" =~ ^wv-[0-9a-f]+$ ]]; then pass "remember --exposure=graph-only captures a memory"; else fail "remember --exposure=graph-only captures a memory" "got '$HIDDEN'"; fi
[ "$(_meta "$HIDDEN" '.exposure // "absent"')" = graph-only ] \
    && pass "the graph-only choice is persisted in metadata.exposure" \
    || fail "the graph-only choice is persisted in metadata.exposure"
[ "$(_meta "$SHOWN" '.exposure // "absent"')" = absent ] \
    && pass "a memory captured without --exposure carries no field (rendered by default)" \
    || fail "a memory captured without --exposure carries no field (rendered by default)"
if "$WV" remember "bad exposure" --exposure=secret >/dev/null 2>&1; then
    fail "remember refuses an unknown exposure value"
else
    pass "remember refuses an unknown exposure value"
fi
out=$("$WV" memory exposure "$HIDDEN" 2>/dev/null || true)
[ "$out" = "$HIDDEN exposure: graph-only" ] && pass "memory exposure <id> shows the value" \
    || fail "memory exposure <id> shows the value" "got '$out'"
[ "$("$WV" memory exposure "$SHOWN" --json 2>/dev/null | jq -r '.exposure' || true)" = rendered ] \
    && pass "an absent field reads as rendered" || fail "an absent field reads as rendered"
if "$WV" memory exposure "$SHOWN" graph-only >/dev/null 2>&1 \
    || [ "$(_meta "$SHOWN" '.exposure // "absent"')" != absent ]; then
    fail "memory exposure only shows: it refuses a value and writes nothing"
else
    pass "memory exposure only shows: it refuses a value and writes nothing"
fi
if [ -n "$PLAIN_TASK" ] && ! "$WV" memory exposure "$PLAIN_TASK" >/dev/null 2>&1 \
    && ! "$WV" memory review "$PLAIN_TASK" --verdict=exposure --exposure=graph-only --reason=r >/dev/null 2>&1 \
    && [ "$(_meta "$PLAIN_TASK" '.exposure // "absent"')" = absent ]; then
    pass "a node that is not a memory is refused"
else
    fail "a node that is not a memory is refused"
fi
refused() { ! "$WV" memory review "$@" >/dev/null 2>&1; }
check "the exposure verdict refuses without a reason" refused "$SHOWN" --verdict=exposure --exposure=graph-only
check "the exposure verdict refuses an unknown value" refused "$SHOWN" --verdict=exposure --exposure=hidden --reason=r
check "the exposure verdict refuses the value the memory already has" refused "$SHOWN" --verdict=exposure --exposure=rendered --reason=r
check "--exposure goes only with the exposure verdict" refused "$SHOWN" --verdict=reject --exposure=graph-only --reason=r

SUCC=$("$WV" remember "Hidden successor first sentence." --supersedes="$HIDDEN" --json 2>/dev/null | _id || true)
[ "$(_meta "$SUCC" '.exposure // "absent"')" = graph-only ] \
    && pass "a superseding memory inherits graph-only from its predecessor" \
    || fail "a superseding memory inherits graph-only from its predecessor"
SUCC2=$("$WV" remember "Shown successor first sentence." --supersedes="$SUCC" --exposure=rendered --json 2>/dev/null | _id || true)
[ "$(_meta "$SUCC2" '.exposure // "absent"')" = rendered ] \
    && pass "an explicit --exposure overrides the inherited one" \
    || fail "an explicit --exposure overrides the inherited one"
# HIDDEN is superseded now.
check "the exposure verdict refuses a memory that is not active" refused "$HIDDEN" --verdict=exposure --exposure=rendered --reason=r
HIDDEN2=$("$WV" remember "Second hidden first sentence. HIDDEN2-BODY." --json 2>/dev/null | _id)
expose() { # expose <id> <value> <reason>: record the verdict, then apply it
    "$WV" memory review "$1" --verdict=exposure --exposure="$2" --reason="$3" >/dev/null 2>&1 \
        && "$WV" memory review --apply >/dev/null 2>&1
}
"$WV" memory review "$HIDDEN2" --verdict=exposure --exposure=graph-only --reason="subsystem reference only" >/dev/null 2>&1 || true
[ "$(_meta "$HIDDEN2" '.exposure // "absent"')" = absent ] \
    && pass "a recorded exposure verdict changes nothing until applied" \
    || fail "a recorded exposure verdict changes nothing until applied"
"$WV" memory review --apply >/dev/null 2>&1 || true
[ "$(_meta "$HIDDEN2" '.exposure // "absent"')" = graph-only ] \
    && pass "review --apply sets the exposure" \
    || fail "review --apply sets the exposure"
if [ "$(_meta "$HIDDEN2" '.exposure_reason')" = "subsystem reference only" ] \
    && [[ "$(_meta "$HIDDEN2" '.exposure_at')" == *T* ]] \
    && [ -n "$(_meta "$HIDDEN2" '.exposure_by // empty')" ]; then
    pass "the applied verdict records why, when and by whom"
else
    fail "the applied verdict records why, when and by whom" "$(_meta "$HIDDEN2" '{exposure_by, exposure_at, exposure_reason}')"
fi
shown=$("$WV" memory exposure "$HIDDEN2" 2>/dev/null || true)
check "memory exposure shows the recorded reason" grep -qF -- "subsystem reference only" <<< "$shown"

echo ""
echo "Every renderer leaves graph-only out"
echo "===================================="
mkdir -p .github .codex
printf '# Agents\n\n<!-- ── BEGIN WEAVE:MEMORY ── x -->\n<!-- ── END WEAVE:MEMORY ── -->\n' > AGENTS.md
"$WV" memory render --agent=all >/dev/null 2>&1 || true
for f in CLAUDE.md .github/copilot-instructions.md AGENTS.md; do
    if grep -qF -- "$SHOWN" "$f" 2>/dev/null && ! grep -qF -- "$HIDDEN2" "$f" && ! grep -qF -- "Hidden memory" "$f"; then
        pass "$f lists the rendered memory and not the graph-only one"
    else
        fail "$f lists the rendered memory and not the graph-only one"
    fi
done
if jq -e --arg s "$SHOWN" --arg h "$HIDDEN2" \
    '(.memory.entries | map(.id)) as $ids | ($ids | index($s)) != null and ($ids | index($h)) == null' \
    .codex/weave.json >/dev/null 2>&1; then
    pass ".codex/weave.json lists the rendered memory and not the graph-only one"
else
    fail ".codex/weave.json lists the rendered memory and not the graph-only one"
fi
check "the projection header says recall holds what the index leaves out" \
    grep -qF "Recall also returns the graph-only memories this index leaves out." CLAUDE.md

boot=$("$WV" bootstrap --json 2>/dev/null || echo '{}')
if jq -e --arg s "$SHOWN" --arg h "$HIDDEN2" \
    '(.memory.entries | map(.id)) as $ids | ($ids | index($s)) != null and ($ids | index($h)) == null' \
    <<< "$boot" >/dev/null 2>&1; then
    pass "bootstrap's index leaves the graph-only memory out"
else
    fail "bootstrap's index leaves the graph-only memory out"
fi
# Active graph-only: HIDDEN2 (HIDDEN and SUCC are superseded; SUCC2 is rendered).
[ "$(jq -r '.memory.graph_only // "missing"' <<< "$boot")" = 1 ] \
    && pass "bootstrap counts the active graph-only memories" \
    || fail "bootstrap counts the active graph-only memories" "got $(jq -c '.memory | del(.entries)' <<< "$boot")"

budget_with=$("$WV" doctor --json 2>/dev/null | jq -r 'first(.. | objects | select(.check? == "memory budget") | .detail) // ""' 2>/dev/null || true)
bytes_with=$(grep -oE '^memory block is [0-9]+' <<< "$budget_with" | grep -oE '[0-9]+' || true)
expose "$HIDDEN2" rendered "needed every session after all" || true
budget_without=$("$WV" doctor --json 2>/dev/null | jq -r 'first(.. | objects | select(.check? == "memory budget") | .detail) // ""' 2>/dev/null || true)
bytes_without=$(grep -oE '^memory block is [0-9]+' <<< "$budget_without" | grep -oE '[0-9]+' || true)
if [ -n "$bytes_with" ] && [ -n "$bytes_without" ] && [ "$bytes_with" -lt "$bytes_without" ]; then
    pass "the doctor's block budget does not count a graph-only memory"
else
    fail "the doctor's block budget does not count a graph-only memory" "graph-only: '$budget_with'; rendered: '$budget_without'"
fi
"$WV" memory render --agent=all >/dev/null 2>&1 || true
check "a memory set back to rendered returns to the projections" grep -qF -- "$HIDDEN2" CLAUDE.md
expose "$HIDDEN2" graph-only "subsystem reference only" || true

echo ""
echo "Graph recall is not narrowed"
echo "============================"
recall=$("$WV" memory recall --agent=all --json 2>/dev/null || echo '[]')
if jq -e --arg h "$HIDDEN2" 'map(.id) | index($h) != null' <<< "$recall" >/dev/null; then
    pass "memory recall returns the graph-only memory"
else
    fail "memory recall returns the graph-only memory"
fi
check "memory recall returns its full text" grep -qF "HIDDEN2-BODY" <<< "$recall"
check "wv show returns the graph-only memory" bash -c "'$WV' show '$HIDDEN2' 2>/dev/null | grep -qF 'HIDDEN2-BODY'"
check "wv search finds the graph-only memory" bash -c "'$WV' search 'HIDDEN2' 2>/dev/null | grep -qF '$HIDDEN2'"

echo ""
echo "Change detection sees an exposure flip"
echo "======================================"
# The checkpoint and the gate decide whether projections must change by
# comparing a filtered view of the active memories; a flip must change it.
# shellcheck source=/dev/null
filter=$(bash -c "source '$PROJECT_ROOT/scripts/lib/wv-checkpoint-ci.sh' >/dev/null 2>&1; printf '%s' \"\$WV_ACTIVE_MEMORY_FILTER\"")
row_r='{"id":"wv-aaaaaa","text":"t","metadata":"{\"type\":\"memory\",\"mem_status\":\"active\"}"}'
row_g='{"id":"wv-aaaaaa","text":"t","metadata":"{\"type\":\"memory\",\"mem_status\":\"active\",\"exposure\":\"graph-only\"}"}'
if [ -n "$filter" ] && [ "$(jq -sc "$filter" <<< "$row_r")" != "$(jq -sc "$filter" <<< "$row_g")" ]; then
    pass "the checkpoint's memory filter sees an exposure flip"
else
    fail "the checkpoint's memory filter sees an exposure flip"
fi
gate_filter=$(sed -n "/^    _pc_memory_filter='/,/sort_by(.id)'\$/p" "$PROJECT_ROOT/scripts/hooks/pre-commit-weave.sh" \
    | sed "1s/^    _pc_memory_filter='//; \$s/'\$//")
if [ -n "$gate_filter" ] && [ "$(jq -sc "$gate_filter" <<< "$row_r")" != "$(jq -sc "$gate_filter" <<< "$row_g")" ]; then
    pass "the gate's memory filter sees an exposure flip"
else
    fail "the gate's memory filter sees an exposure flip"
fi
row_e='{"id":"wv-aaaaaa","text":"t","metadata":"{\"type\":\"memory\",\"mem_status\":\"active\",\"exposure\":\"rendered\"}"}'
if [ -n "$filter" ] && [ "$(jq -sc "$filter" <<< "$row_r")" = "$(jq -sc "$filter" <<< "$row_e")" ]; then
    pass "absent and explicit rendered compare equal (no spurious re-render)"
else
    fail "absent and explicit rendered compare equal (no spurious re-render)"
fi

echo ""
echo "=========================================="
echo "Tests run: $TESTS_RUN, passed: $TESTS_PASSED, failed: $TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
