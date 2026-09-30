#!/usr/bin/env bash
# wv-9d2036: wv load calls the Delta v2 replay as "db --cutover-seq N ops...".
# Before Python 3.12, argparse took both positionals at the first positional
# run and rejected the operations after the option (exit 2), so every cutover
# replay aborted on 3.11. Run that exact argv under the interpreter on PATH and
# under 3.11, the oldest requires-python allows. Kept apart from
# test-delta-v2-replay.sh, whose bytes live E6 evidence pins.

set -uo pipefail
export WV_CALL_SOURCE=test

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPLAY="$ROOT/scripts/lib/wv-delta-v2-replay.py"
OP="$ROOT/tests/fixtures/ipc/v1/durability/delta-operation-v2.json"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
DB="$TMP/empty.db"
sqlite3 "$DB" 'SELECT 1;' >/dev/null

pass=0
run=0
ok() { echo "  ✓ $1"; pass=$((pass + 1)); run=$((run + 1)); }
bad() { echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; run=$((run + 1)); }

# The cutover is far above any lineage, so the operation is skipped without
# touching the (empty) database: the check is the argv, not the evaluation.
check_argv() {
    local py="$1" label="$2" out rc disp
    out=$("$py" "$REPLAY" "$DB" --cutover-seq 999999999 "$OP" 2>&1) && rc=0 || rc=$?
    disp=$(printf '%s' "$out" | jq -r '.results[0].disposition' 2>/dev/null)
    if [ "$rc" = "0" ] && [ "$disp" = "skipped_pre_cutover" ]; then
        ok "$label parses wv load's cutover argv order"
    else
        bad "$label parses wv load's cutover argv order" "rc=$rc: $(tail -1 <<< "$out")"
    fi
}

echo "Delta v2 replay argv order (wv-9d2036)"
check_argv python3 "python3 ($(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])'))"

# uv python find only searches installed interpreters; it never downloads.
py311=$(command -v python3.11 2>/dev/null || uv python find 3.11 2>/dev/null || true)
if [ -n "$py311" ] && "$py311" -c 'import sys; sys.exit(sys.version_info[:2] != (3, 11))' 2>/dev/null; then
    check_argv "$py311" "Python 3.11"
else
    echo "  - SKIP Python 3.11: no 3.11 interpreter found (not counted)"
fi

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ] && [ "$run" -gt 0 ]
