#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# errexit must not depend on whether telemetry is enabled.
#
# scripts/wv sets `set -euo pipefail` at the top, but the call-log/journal
# wrapper used to run `set +e` around dispatch. config.env sets WV_CALL_LOG
# durably, so on an instrumented host every wv command ran with abort-on-error
# OFF while an uninstrumented host ran the same code with it ON. That is not a
# telemetry detail: 37 of the 39 db_ensure call sites ignore their return, so
# db_migrate_lineage's deliberate `return 1` (wv-db.sh:343) was swallowed and
# execution continued past a failed durability migration (wv-e7d5a3).
#
# The first assertion is a structural pin, deliberately. The divergence is not
# reachable through the public CLI: reaching it needs a mid-function failure
# injected below the dispatch table, and both a sabotaged sqlite3 on PATH and a
# write-rejecting stub failed to discriminate (SQL arrives on stdin, not argv).
# Pinning the source is what actually prevents the regression; the behavioural
# checks below guard the refactor that removed it.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$ROOT/scripts/wv"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
run=0; pass=0
ok() { run=$((run+1)); pass=$((pass+1)); echo -e "  ${GREEN}✓${NC} $1"; }
bad() { run=$((run+1)); echo -e "  ${RED}✗${NC} $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }

TEST_DIR=$(mktemp -d /tmp/wv-errexit-XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT
export WEAVE_DIR="$TEST_DIR/.weave"
export WV_HOT_ZONE="$TEST_DIR/hot"
export WV_CONFIG_DIR="$TEST_DIR/config"; mkdir -p "$WV_CONFIG_DIR"
cd "$TEST_DIR" || exit 1

echo "errexit dispatch parity"

# ── structural pin ─────────────────────────────────────────────────────────────

dispatch_block=$(sed -n '/^    trap ._wv_finalize. EXIT/,/^    exit "\$_wv_exit"/p' "$WV")
if [ -z "$dispatch_block" ]; then
    bad "dispatch block located in scripts/wv" "sed range matched nothing — did the wrapper move?"
else
    ok "dispatch block located in scripts/wv"
    if grep -q 'set +e' <<<"$dispatch_block"; then
        bad "dispatch does not disable errexit" "found 'set +e' between the EXIT trap and the exit"
    else
        ok "dispatch does not disable errexit"
    fi
fi

check "scripts/wv still enables errexit at the top" \
    "yes" "$(grep -qE '^set -euo pipefail' "$WV" && echo yes || echo no)"

# ── behavioural: status is reported identically either way ─────────────────────

with_log()    { WV_CALL_LOG="$TEST_DIR/calls.jsonl" "$WV" "$@" >/dev/null 2>&1; echo $?; }
without_log() { env -u WV_CALL_LOG WV_CONFIG_DIR="$TEST_DIR/config" "$WV" "$@" >/dev/null 2>&1; echo $?; }

fail_logged=$(with_log show wv-doesnotexist)
fail_plain=$(without_log show wv-doesnotexist)
check "failing command is non-zero with the call log"    "1" "$fail_logged"
check "failing command is non-zero without the call log" "1" "$fail_plain"
check "failing command agrees across both paths"  "$fail_plain" "$fail_logged"

ok_logged=$(with_log --version)
ok_plain=$(without_log --version)
check "succeeding command is zero with the call log"    "0" "$ok_logged"
check "succeeding command agrees across both paths" "$ok_plain" "$ok_logged"

# ── behavioural: telemetry still records the real status ───────────────────────

if [ -s "$TEST_DIR/calls.jsonl" ]; then
    ok "call log was written"
    statuses=$(python3 -c "
import json,sys
seen=set()
for line in open('$TEST_DIR/calls.jsonl'):
    line=line.strip()
    if line:
        try: seen.add(json.loads(line)['exit_status'])
        except Exception: pass
print(','.join(str(s) for s in sorted(seen)))
" 2>/dev/null)
    if grep -q '1' <<<"$statuses"; then
        ok "call log records a non-zero exit_status (statuses: $statuses)"
    else
        bad "call log records a non-zero exit_status" "saw only: $statuses"
    fi
else
    bad "call log was written" "no rows at $TEST_DIR/calls.jsonl"
fi

echo ""
echo "  $pass/$run passed"
[ "$pass" -eq "$run" ]
