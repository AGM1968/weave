#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# wv analyze must bound its work by the requested window.
#
# The reader streamed and json.loads-ed every line and only then applied the
# window, so --since-days=1 cost the same as lifetime (6787ms vs 8398ms on a
# 649k-line log) and the Stop hook paid it on every session end (wv-4b1c60).
# It now binary-searches the first in-window line and rewinds a margin.
#
# Correctness matters more than the speed here: a seek that lands too late
# silently drops rows, and the aggregate would simply look smaller. Every case
# below compares wv's counts against a brute-force count of the same fixture.
set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$ROOT/scripts/wv"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
run=0; pass=0
ok() { run=$((run+1)); pass=$((pass+1)); echo -e "  ${GREEN}✓${NC} $1"; }
bad() { run=$((run+1)); echo -e "  ${RED}✗${NC} $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }

TEST_DIR=$(mktemp -d /tmp/wv-analyze-window-XXXXXX)
trap 'chmod -R u+w "$TEST_DIR" 2>/dev/null; rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/config"
LOG="$TEST_DIR/calls.jsonl"

# A fixture larger than the seek margin, otherwise the whole-file path is taken
# and the seek under test never runs. Rows are chronological, as appends are.
python3 - "$LOG" <<'PY'
import json, sys, time
now = time.time()
rows = 16000
span = 30 * 86400
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    for i in range(rows):
        ts = now - span + (span * i / rows)
        fh.write(json.dumps({
            "ts": round(ts, 6), "cmd": "wv probe", "stdout_bytes": 10,
            "stderr_bytes": 0, "elapsed_ms": 1, "source": "shell",
            "call_id": f"c{i:08d}", "padding": "x" * 120,
        }) + "\n")
PY
# Read-only: WV_CALL_LOG points at this fixture, so each wv call would
# otherwise append its own row and move the very counts under test.
FIXTURE_ROWS=$(( $(wc -l < "$LOG") ))
chmod 444 "$LOG"
echo "analyze window bounding  (fixture: $FIXTURE_ROWS rows, $(du -k "$LOG" | cut -f1)KB, read-only)"

expected() { # $1 = days
    python3 - "$LOG" "$1" <<'PY'
import json, sys, time
cutoff = time.time() - float(sys.argv[2]) * 86400
n = 0
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    if json.loads(line).get("ts", 0) >= cutoff:
        n += 1
print(n)
PY
}

actual() { # $1 = days ('' for lifetime)
    local flag=""; [ -n "$1" ] && flag="--since-days=$1"
    env WV_CONFIG_DIR="$TEST_DIR/config" WV_CALL_LOG="$LOG" \
        "$WV" analyze sessions --call-stats $flag 2>/dev/null |
        python3 -c "
import json,sys
d = json.load(sys.stdin)
print(sum(s['calls'] for s in d['call_stats']))
" 2>/dev/null
}

for days in 1 3 7 14 29; do
    exp=$(expected "$days"); act=$(actual "$days")
    # The fixture is evenly spaced, so a tolerance of one row absorbs the
    # boundary row moving between the two wall-clock reads.
    if [ -n "$act" ] && [ "$((exp > act ? exp - act : act - exp))" -le 1 ]; then
        ok "--since-days=$days counts $act rows (brute force: $exp)"
    else
        bad "--since-days=$days matches brute force" "expected ~$exp, got ${act:-<none>}"
    fi
done

total="$FIXTURE_ROWS"
check "lifetime still counts every row" "$total" "$(actual '')"

# A window wider than the log must behave exactly like lifetime.
check "window wider than the log equals lifetime" "$total" "$(actual 3650)"

echo ""
echo "  $pass/$run passed"
[ "$pass" -eq "$run" ]
