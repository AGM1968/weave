#!/usr/bin/env bash
# Public allocator contract: capacity refusal, precedence and independent owners.
set -euo pipefail
export WV_TEST_SUITE=1
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/fallback" "$T/explicit root"
printf 'unrelated\n' > "$T/explicit root/brain.db"
cat > "$T/bin/df" <<'SH'
#!/bin/sh
printf 'Filesystem 1024-blocks Used Available Capacity Mounted\nfixture 100 63 %s 63%% /fixture\n' "$FIXTURE_FREE_KB"
SH
chmod +x "$T/bin/df"
export PATH="$T/bin:$PATH" FIXTURE_FREE_KB=37
export WV_SCRATCH_ROOT="$T/explicit root" TMPDIR="$T/fallback" WV_SCRATCH_MIN_KB=37
run=0; pass=0
check() { run=$((run+1)); if "$@"; then pass=$((pass+1)); else echo "FAIL: $*"; fi; }
allocator="$ROOT/scripts/lib/wv-scratch.sh"
FIXTURE_FREE_KB=37 bash "$allocator" >"$T/allocation" 2>"$T/report" &
owner=$!
rc=0; FIXTURE_FREE_KB=36 bash "$allocator" >"$T/concurrent-refused" 2>"$T/error" || rc=$?
wait "$owner"
a=$(cat "$T/allocation")
check test "$rc" -ne 0
check test ! -s "$T/concurrent-refused"
check test -d "$a"
b=$(bash "$allocator" 2>>"$T/report")
check test "$(dirname "$a")" = "$WV_SCRATCH_ROOT"
check test "$a" != "$b"
check grep -q 'available_kib=37 minimum_kib=37' "$T/report"
rm -rf "$a"
check test -d "$b"
check test -f "$WV_SCRATCH_ROOT/brain.db"
rm -rf "$b"
export FIXTURE_FREE_KB=36
rc=0; bash "$allocator" >"$T/refused" 2>"$T/error" || rc=$?
check test "$rc" -ne 0
check test ! -s "$T/refused"
check grep -q 'insufficient capacity before expensive work' "$T/error"
check test "$(find "$WV_SCRATCH_ROOT" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 0
export FIXTURE_FREE_KB=40
c=$(env -u WV_SCRATCH_ROOT bash "$allocator" 2>"$T/report")
check test "$(dirname "$c")" = "$TMPDIR"
rm -rf "$c"
rc=0; WV_SCRATCH_MIN_KB=invalid bash "$allocator" >/dev/null 2>"$T/error" || rc=$?
check test "$rc" -ne 0
check grep -q 'must be a nonnegative integer' "$T/error"
rc=0; WV_SCRATCH_MIN_KB=999999999999999999999999999 bash "$allocator" >"$T/refused" 2>"$T/error" || rc=$?
check test "$rc" -ne 0
check test ! -s "$T/refused"
echo "Results: $pass/$run passed"
test "$pass" -eq "$run"
