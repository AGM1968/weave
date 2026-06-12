#!/bin/bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# test-cmd-battery.sh — Command-surface battery: walk the dispatch table one
# command at a time with realistic data.
#
# Why this suite exists (finding wv-72f9b2, hollow-evidence): four shipped
# defects in one release window were invisible to the unit suites because no
# test invoked the actual command surface with realistic data. The battery
# closes that class structurally:
#   - every dispatch-table command is either exercised here or listed in
#     SKIPPED with a documented reason — the coverage guard fails on drift,
#     so a new command cannot ship unexercised by accident;
#   - seed data carries the field shapes that have actually broken parsing:
#     literal '|' in node text, apostrophes, integer-stored gh_issue;
#   - stdout and stderr are captured separately; --json surfaces must parse.
#
# Tiers:
#   R  read       — rc==0, output free of error markers
#   J  json       — R + stdout parses with jq
#   W  write      — same contract as R, against scratch data only
#   H  help-only  — `wv <cmd> --help` rc==0 (commands needing heavy fixtures;
#                   still catches dispatch breakage and parse-time errors)
# Weave-ID: wv-901b08

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$REPO_ROOT/scripts/wv"

# Isolated test environment
TEST_DIR=$(mktemp -d)
export WV_HOT_ZONE="$TEST_DIR/hot"
export WV_DB="$TEST_DIR/hot/brain.db"
export WV_REQUIRE_LEARNING=0
export WEAVE_DIR="$TEST_DIR/.weave"
export WV_PROJECT_DIR="$TEST_DIR"
export WV_NONINTERACTIVE=1
mkdir -p "$WV_HOT_ZONE" "$WEAVE_DIR"
cd "$TEST_DIR"
git init -q 2>/dev/null || true
git config user.email "battery@test.local" 2>/dev/null || true
git config user.name "battery" 2>/dev/null || true

TESTS_RUN=0
TESTS_PASSED=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Output markers that indicate a broken command rather than a soft warning.
ERROR_MARKERS='integer expression expected|unbound variable|syntax error|command not found|Traceback \(most recent|sqlite3: Error'

EXERCISED=""
SKIPPED=""

# battery <tier> <name> <cmd...> — run one surface, record coverage under <name>
battery() {
    local tier="$1" name="$2"
    shift 2
    EXERCISED="$EXERCISED $name"
    TESTS_RUN=$((TESTS_RUN + 1))

    if [ "$tier" = "H" ]; then
        set +e
        "$WV" "$name" --help >/dev/null 2>&1
        local rc=$?
        set -e
        if [ "$rc" -eq 0 ]; then
            echo -e "  ${GREEN}✓${NC} $name (help-only)"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            echo -e "  ${RED}✗${NC} $name --help rc=$rc"
        fi
        return 0
    fi

    local out_f err_f rc
    out_f=$(mktemp) err_f=$(mktemp)
    set +e
    "$WV" "$@" >"$out_f" 2>"$err_f"
    rc=$?
    set -e

    local fail=""
    [ "$rc" -ne 0 ] && fail="rc=$rc"
    if grep -qE "$ERROR_MARKERS" "$out_f" "$err_f" 2>/dev/null; then
        fail="${fail:+$fail, }error marker: $(grep -hoE "$ERROR_MARKERS" "$out_f" "$err_f" | head -1)"
    fi
    if [ "$tier" = "J" ] && ! jq -e . <"$out_f" >/dev/null 2>&1; then
        fail="${fail:+$fail, }stdout not valid JSON"
    fi

    if [ -z "$fail" ]; then
        echo -e "  ${GREEN}✓${NC} $name ($*)"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗${NC} $name ($*): $fail"
        echo "    stderr: $(head -2 "$err_f" | tr '\n' ' ')"
    fi
    rm -f "$out_f" "$err_f"
}

# skip <name> <reason> — document a deliberate non-exercise
skip() {
    SKIPPED="$SKIPPED $1"
    echo -e "  ${YELLOW}-${NC} $1 skipped: $2"
}

# ═══════════════════════════════════════════════════════════════════════════
# Seed: realistic graph data carrying historically-breaking field shapes
# ═══════════════════════════════════════════════════════════════════════════
echo "--- seeding scratch graph ---"
"$WV" init >/dev/null 2>&1
EXERCISED="$EXERCISED init"

N_PIPE=$("$WV" add "battery: glob gap fix | calibration: pipe in text" --force 2>/dev/null | grep -oP 'wv-[a-f0-9]+' | head -1)
N_APOS=$("$WV" add "battery: O'Brien's quoting probe node" --force --alias=bat-apos 2>/dev/null | grep -oP 'wv-[a-f0-9]+' | head -1)
N_DONE=$("$WV" add "battery: pre-closed node carrying integer gh metadata" --force 2>/dev/null | grep -oP 'wv-[a-f0-9]+' | head -1)
N_FIND=$("$WV" add "battery finding: suite-pass evidence with zero new-path coverage" --force 2>/dev/null | grep -oP 'wv-[a-f0-9]+' | head -1)
if [ -z "$N_PIPE" ] || [ -z "$N_APOS" ] || [ -z "$N_DONE" ] || [ -z "$N_FIND" ]; then
    echo -e "${RED}✗ seed failed — aborting battery${NC}"
    exit 1
fi
sqlite3 "$WV_DB" "UPDATE nodes SET metadata=json_set(COALESCE(metadata,'{}'),'\$.gh_issue', 4242) WHERE id='$N_DONE';"
sqlite3 "$WV_DB" "UPDATE nodes SET metadata=json_set(COALESCE(metadata,'{}'),
    '\$.type','finding','\$.promoted_at',datetime('now','-2 days'),
    '\$.finding', json('{\"fixable\":true,\"confidence\":\"high\",\"violation_type\":\"test:gap\"}'))
    WHERE id='$N_FIND';"
"$WV" work "$N_APOS" >/dev/null 2>&1
EXERCISED="$EXERCISED work"
"$WV" done "$N_DONE" --learning="pattern: battery seed learning with O'Neil's apostrophe | pitfall: pipe" >/dev/null 2>&1
EXERCISED="$EXERCISED done"
echo "  seeded: $N_PIPE $N_APOS $N_DONE $N_FIND"

# ═══════════════════════════════════════════════════════════════════════════
# Battery walk
# ═══════════════════════════════════════════════════════════════════════════
echo "--- core ---"
battery W add        add "battery: scratch write with 'quote | pipe'" --force
battery J list       list --json
battery R show       show "$N_PIPE"
battery R ready      ready
battery J status     status --json
battery R pending-close pending-close
battery W update     update "$N_PIPE" --metadata='{"battery":"O'\''Neil | piped"}'
battery W touch      touch "$N_APOS" --intent="battery touch intent"
battery R allowed-tools allowed-tools "$N_APOS"
battery W quick      quick "battery quick tracked no-op"
battery H batch-done
battery H bulk-update
battery H ship
battery H ship-agent

echo "--- graph ---"
battery W block      block "$N_PIPE" --by="$N_DONE"
battery W link       link "$N_FIND" "$N_PIPE" --type=relates_to
battery W unlink     unlink "$N_FIND" "$N_PIPE" --type=relates_to
# resolve is contradiction resolution — needs a two-node contradiction fixture
battery H resolve
battery R related    related "$N_PIPE"
battery R edges      edges "$N_PIPE"
battery R path       path "$N_PIPE"
battery R tree       tree
battery J context    context "$N_APOS" --json
battery R impact     impact --help
battery H batch
battery H plan
battery H enrich-topology

echo "--- data ---"
battery W sync       sync
battery W load       load
# compact's active-agent guard correctly refuses while a node is claimed —
# close the seeded active node so the dry-run exercises the normal path.
"$WV" done "$N_APOS" --skip-verification >/dev/null 2>&1 || "$WV" done "$N_APOS" >/dev/null 2>&1
battery R compact    compact --dry-run
battery R prune      prune --dry-run
battery R clean-ghosts clean-ghosts --dry-run
battery R learnings  learnings
battery R refs       refs -t "see $N_PIPE and $N_DONE"
battery J search     search "battery" --json
battery W reindex    reindex
battery R trails     trails
battery R breadcrumbs breadcrumbs
battery H unarchive
battery H import

echo "--- ops ---"
battery J bootstrap  bootstrap --json
battery J bootstrap-agent bootstrap-agent --json
battery R doctor     doctor
battery J hotzone    hotzone list --json
# hotzone outside a git repo must hint, not stay silent (wv-b75fbe)
TESTS_RUN=$((TESTS_RUN + 1))
NONREPO=$(mktemp -d)
hz_err=$( (cd "$NONREPO" && "$WV" hotzone list 2>&1 >/dev/null) || true )
if echo "$hz_err" | grep -q "not inside a git repo"; then
    echo -e "  ${GREEN}✓${NC} hotzone list outside a repo emits non-repo hint"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗${NC} hotzone list outside a repo is silent (no hint on stderr)"
fi
rm -rf "$NONREPO"
battery R recover    recover
# mcp-status rc reflects server-built state — env-dependent in scratch
battery H mcp-status
battery J health     health --json
battery R cache      cache
battery R preflight  preflight "$N_PIPE"
battery J digest     digest --json
battery J overview   overview --json
battery R session-summary session-summary
battery R audit-pitfalls audit-pitfalls
battery R edge-types edge-types --stats
battery R guide      guide --topic=discovery
battery R config     config
battery H test-record
battery H selftest

echo "--- quality / analysis / query ---"
battery W quality    quality scan
battery R findings   findings list --all
battery R validate-finding validate-finding "$N_FIND"
battery R analyze    analyze sessions --call-stats
battery W index      index .
battery J query      query status=todo --format=json
battery R help       help
battery R version    version

echo "--- deliberate skips ---"
skip delete      "exercised with full assertions in test-durability.sh (ownership guard, epoch)"
skip self-update "mutates the user-level install from a source clone"
skip uninstall   "destructive to the user-level install"
skip init-repo   "installer-class; covered by install/deploy pipeline + doctor"
skip pattern-audit "audits the source repo registry; meaningless from a scratch repo"

# ═══════════════════════════════════════════════════════════════════════════
# Coverage guard: every dispatch-table command is exercised or skipped
# ═══════════════════════════════════════════════════════════════════════════
echo "--- coverage guard ---"
TESTS_RUN=$((TESTS_RUN + 1))
DISPATCH=$(awk '/case "\$cmd" in/,/^    esac/' "$REPO_ROOT/scripts/wv" \
    | grep -oE '^\s+[a-z][a-z0-9|_-]*\)' | tr -d ' )' | cut -d'|' -f1 | sort -u)
MISSING=""
for c in $DISPATCH; do
    case " $EXERCISED $SKIPPED " in
        *" $c "*) ;;
        *) MISSING="$MISSING $c" ;;
    esac
done
if [ -z "$MISSING" ]; then
    echo -e "  ${GREEN}✓${NC} coverage: all $(echo "$DISPATCH" | wc -w) dispatch commands exercised or skip-documented"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗${NC} coverage: dispatch commands neither exercised nor skip-documented:$MISSING"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════
cd /tmp && rm -rf "$TEST_DIR"
echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
if [ "$TESTS_PASSED" -eq "$TESTS_RUN" ]; then
    echo -e "${GREEN}All tests passed${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed${NC}"
    exit 1
fi
