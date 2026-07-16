#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib/wv-delta-catalog.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
pass=0; run=0
ok(){ echo "  ✓ $1"; pass=$((pass+1)); run=$((run+1)); }
bad(){ echo "  ✗ $1"; run=$((run+1)); }
mkdir -p "$TMP/deltas/z" "$TMP/deltas/a"
printf x > "$TMP/deltas/z/late.sql"; printf y > "$TMP/deltas/a/early.json"
mapfile -d '' -t out < <(wv_delta_catalog_scan "$TMP/deltas")
[ "${out[0]}" = "a/early.json" ] && [ "${out[3]}" = "v2_operation" ] && [ "${out[4]}" = "z/late.sql" ] && [ "${out[7]}" = "legacy_sql" ] && ok "sorted NUL inventory classifies files" || bad "sorted NUL inventory classifies files"
ln -s "$TMP/deltas/z/late.sql" "$TMP/deltas/link.sql"
if wv_delta_catalog_scan "$TMP/deltas" >/dev/null 2>&1; then bad "symlink is rejected"; else ok "symlink is rejected"; fi
rm "$TMP/deltas/link.sql"
mkfifo "$TMP/deltas/pipe"
if wv_delta_catalog_scan "$TMP/deltas" >/dev/null 2>&1; then bad "non-regular entry is rejected"; else ok "non-regular entry is rejected"; fi
rm "$TMP/deltas/pipe"
ln -s "$TMP/deltas" "$TMP/link-root"
if wv_delta_catalog_scan "$TMP/link-root" >/dev/null 2>&1; then bad "symlink root is rejected"; else ok "symlink root is rejected"; fi
echo "Results: $pass/$run passed"; [ "$pass" -eq "$run" ]
