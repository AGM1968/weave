#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# Hot-zone owner state and the deletions that depend on it (wv-4ccc98).
# wv hotzone gc deleted a hot-zone directory whenever its .repo_root path did
# not exist, and doctor advised gc for it: a repository on an unmounted disk
# read as deleted, and its zone, which can hold writes no repository has yet
# (node_files before a snapshot, wv-64178f), was removed. The rebuild advice
# printed in four places deleted the zone too. hot_zone_owner_state is now the
# one predicate: gone only when the deletion is observed, otherwise unknown and
# kept; the advice moves the zone aside. gc itself never deletes on inference:
# it quarantines, purges only after the retention period, and restore undoes it.
# Portable (Linux and macOS): no GNU-only touch/stat forms, and the zone base
# is read from the resolver (macOS uses $TMPDIR/weave-<uid>).
set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$ROOT/scripts/wv"
RESOLVER="$ROOT/scripts/lib/wv-resolve-runtime.sh"
run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }
has() { if [[ "$3" == *"$2"* ]]; then ok "$1"; else bad "$1" "expected to contain [$2], got [$3]"; fi; }
lacks() { if [[ "$3" != *"$2"* ]]; then ok "$1"; else bad "$1" "expected not to contain [$2], got [$3]"; fi; }
T=$(mktemp -d /tmp/wv-hot-zone-gc-XXXXXX)
T=$(cd "$T" && pwd -P)   # canonical, as .repo_root holds it (/private/tmp on macOS)
# aged <file> <seconds> -- set its mtime that far in the past (negative: future)
qdir() { local m=("$BASE/.quarantine/$1."*); [ -e "${m[0]}" ] && echo "${m[0]}"; }  # quarantined copy of zone <name>
aged() { python3 -c 'import os,sys,time; t=time.time()-int(sys.argv[2]); os.utime(sys.argv[1],(t,t))' "$1" "$2"; }
# An empty directory outside every temporary root stands in for the mount point
# of a disk that is not mounted: /tmp paths are judged by the scratch rule.
M=$(mktemp -d "${XDG_CACHE_HOME:-$HOME/.cache}/wv-test-mount-XXXXXX" 2>/dev/null) || M=""
trap 'rm -rf "$T" ${M:+"$M"}' EXIT
ABSENT="/wv-test-absent-$$-$RANDOM"   # a top-level path that does not exist

# state <owner path or ""> -> hot_zone_owner_state's verdict for a zone owned by it
state() {
    local z="$T/zone-$RANDOM"; mkdir -p "$z"
    [ -n "$1" ] && printf '%s\n' "$1" > "$z/.repo_root"
    bash -c 'source "$1"; hot_zone_owner_state "$2"' _ "$RESOLVER" "$z" | cut -f1
}

echo "hot_zone_owner_state"
mkdir -p "$T/projects/live" "$T/projects/other"
check "the owner exists: live" "live" "$(state "$T/projects/live")"
check "no owner recorded: unknown" "unknown" "$(state "")"
check "removed from a parent that is there: gone" "gone" "$(state "$T/projects/deleted")"
check "a scratch tree under /tmp removed whole: gone" "gone" "$(state "/tmp/wv-test-gone-$$/scratch/repo")"
check "parent missing outside a temporary root (unmounted disk): unknown" "unknown" "$(state "$ABSENT/home/u/Documents/repo")"
if [ -n "$M" ]; then
    check "under an empty mount point: unknown" "unknown" "$(state "$M/repo")"
else
    ok "under an empty mount point: skipped (no writable cache directory)"
fi
: > "$T/projects/afile"
check "the owner path is a file: unknown" "unknown" "$(state "$T/projects/afile")"
out=$(z="$T/zone-why"; mkdir -p "$z"; printf '%s\n' "$ABSENT/d/repo" > "$z/.repo_root"; \
    bash -c 'source "$1"; hot_zone_owner_state "$2"' _ "$RESOLVER" "$z")
has "unknown says why" "unmounted disk" "$out"

echo "wv hotzone gc deletes only zones whose repository is gone"
uid=$(id -u)
Z="$T/zones"; mkdir -p "$Z/tmp"
REPO="$T/repo"; mkdir -p "$REPO"; git -C "$REPO" init -q; REPO=$(cd "$REPO" && pwd -P)
mkdir -p "$T/config" "$T/tmpdir"
# TMPDIR in the scratch tree: macOS places zones under $TMPDIR/weave-<uid>.
wvz() { (cd "$REPO" && env -u WV_HOT_ZONE -u WV_DB WV_TEST_MODE=1 WV_TEST_HOT_ZONE_ROOT="$Z" \
    TMPDIR="$T/tmpdir/" WV_CONFIG_DIR="$T/config" "$WV" "$@" 2>&1); }
wvz init >/dev/null
BASE=$(dirname "$(dirname "$(wvz hotzone db)")")
case "$BASE" in "$T"/*) ;; *) echo "  ✗ fixture: zone base $BASE is outside the scratch tree"; exit 1 ;; esac
check "the zone base has no doubled slash (macOS TMPDIR ends in /)" "" "$(grep -F '//' <<< "$BASE" || true)"
zone() {  # zone <name> <owner or ""> -> an old populated zone dir
    mkdir -p "$BASE/$1"; chmod 700 "$BASE/$1"
    sqlite3 "$BASE/$1/brain.db" "CREATE TABLE nodes(id TEXT);"
    [ -n "$2" ] && printf '%s\n' "$2" > "$BASE/$1/.repo_root"
    aged "$BASE/$1/brain.db" 10800
}
zone aaaa0001 "$T/projects/live"
zone aaaa0002 "$T/projects/deleted"
zone aaaa0003 "$ABSENT/media/disk/repo"
zone aaaa0004 ""
out=$(wvz hotzone gc --dry-run)
has "dry run: one eligible" "1 eligible orphan(s)" "$out"
has "dry run: the unmounted-disk zone is kept, with why" "kept: $BASE/aaaa0003/ (owner unknown:" "$out"
has "dry run: the unstamped zone is kept" "kept: $BASE/aaaa0004/ (owner unknown: no owner recorded" "$out"
out=$(wvz hotzone gc)
has "gc reports what it kept" "kept 2 (owner unknown)" "$out"
check "the deleted repository's zone leaves its place" "no" "$([ -e "$BASE/aaaa0002" ] && echo yes || echo no)"
Q=$(qdir aaaa0002)
check "it is quarantined, not deleted" "yes" "$([ -f "$Q/brain.db" ] && echo yes || echo no)"
has "with a record of where it was" "path=$BASE/aaaa0002" "$(cat "$Q/.quarantined" 2>/dev/null)"
has "gc says how to restore it" "wv hotzone restore ${Q##*/}" "$out"
check "the live repository's zone stays" "yes" "$([ -e "$BASE/aaaa0001" ] && echo yes || echo no)"
check "the unmounted-disk zone stays" "yes" "$([ -e "$BASE/aaaa0003" ] && echo yes || echo no)"
check "the unstamped zone stays" "yes" "$([ -e "$BASE/aaaa0004" ] && echo yes || echo no)"

echo "restore and purge"
out=$(wvz hotzone restore "${Q##*/}"; echo "rc=$?")
has "restore moves it back" "restored: $BASE/aaaa0002" "$out"
check "the zone is back with its database" "yes" "$([ -f "$BASE/aaaa0002/brain.db" ] && echo yes || echo no)"
check "and no quarantine record left in it" "no" "$([ -e "$BASE/aaaa0002/.quarantined" ] && echo yes || echo no)"
aged "$BASE/aaaa0002/brain.db" 10800
wvz hotzone gc >/dev/null
Q=$(qdir aaaa0002)
mkdir -p "$BASE/aaaa0002"
out=$(wvz hotzone restore "${Q##*/}"; echo "rc=$?")
has "restore refuses an occupied path" "occupied" "$out"
has "and exits nonzero" "rc=1" "$out"
rmdir "$BASE/aaaa0002"
out=$(WV_HOTZONE_QUARANTINE_DAYS=7 wvz hotzone gc)
check "inside the retention period nothing is purged" "yes" "$([ -d "$Q" ] && echo yes || echo no)"
aged "$Q/brain.db" -60   # written after quarantine
out=$(WV_HOTZONE_QUARANTINE_DAYS=0 wvz hotzone gc)
has "a quarantined zone written since is kept" "quarantine kept: $Q" "$out"
aged "$Q/brain.db" 10800
mkdir -p "$T/projects/deleted"
out=$(WV_HOTZONE_QUARANTINE_DAYS=0 wvz hotzone gc)
has "one whose owner came back is kept" "quarantine kept: $Q (owner live" "$out"
rmdir "$T/projects/deleted"
out=$(WV_HOTZONE_QUARANTINE_DAYS=0 wvz hotzone gc --dry-run)
has "dry run names the purge" "would purge: $Q" "$out"
check "and leaves it" "yes" "$([ -d "$Q" ] && echo yes || echo no)"
out=$(WV_HOTZONE_QUARANTINE_DAYS=0 wvz hotzone gc)
has "past retention, owner still gone, untouched: purged" "purged: $Q" "$out"
check "it is gone" "no" "$([ -e "$Q" ] && echo yes || echo no)"

echo "doctor advises gc only for deleted repositories"
zone aaaa0005 "$T/projects/deleted2"
out=$(wvz doctor --json | python3 -c 'import json,sys
for c in json.load(sys.stdin).get("checks", []):
    if "hot-zone" in c.get("check","") and ("orphan" in c["check"] or "owner" in c["check"]):
        print(c["check"] + "|" + c["detail"])')
has "the deleted one is an orphan for gc" "orphan hot-zones|1 dir(s)" "$out"
has "the unknown ones are reported apart" "unknown hot-zone owners|2 dir(s)" "$out"
unknown_line=$(printf '%s\n' "$out" | grep -F "unknown hot-zone owners" || true)
lacks "and gc is not advised for them" "run: wv hotzone gc" "$unknown_line"

echo "rebuild advice moves the zone aside"
out=$(bash -c 'source "$1"; hot_zone_rebuild_advice /tmp/weave-hotzone-1/abcd' _ "$RESOLVER")
has "it moves the zone aside" "mv /tmp/weave-hotzone-1/abcd /tmp/weave-hotzone-1/abcd.broken-" "$out"
has "and diffs the old copy after the load" "wv hotzone diff /tmp/weave-hotzone-1/abcd.broken-" "$out"
lacks "it never deletes" "rm -rf" "$out"
offenders=$(grep -rnIE 'rm -rf[^|;&]*WV_HOT_ZONE[^|;&]*&& *wv load' "$ROOT/scripts" "$ROOT/templates" 2>/dev/null || true)
check "no shipped surface advises deleting the hot zone to rebuild it" "" "$offenders"

echo "an unread count is not zero: wv init over an unreadable database"
DB=$(wvz hotzone db)
rm -f "$DB-wal" "$DB-shm"
for _ in 1 2 3 4 5 6 7 8; do printf 'not a database, but bytes someone may need\n'; done > "$DB"
before=$(sha256sum "$DB" | cut -d' ' -f1)
out=$(wvz init; echo "rc=$?")
has "wv init refuses" "cannot read the existing database" "$out"
has "and exits nonzero" "rc=1" "$out"
check "the file is left as it was" "$before" "$(sha256sum "$DB" | cut -d' ' -f1)"

# wv compact (deletes deltas) and wv cutover (strands un-synced ones) gate on a
# claim count; it read "0" when the query failed. A failure cannot be produced
# past wv_require_graph without a fault injector, so this is structural.
offenders=$(grep -nE '(active_claims|count)=\$\((db_query|sqlite3)[^)]*COUNT\(\*\)[^)]*\)[^|]*\|\| *echo "?0"?\)' \
    "$ROOT/scripts/cmd/wv-cmd-data.sh" "$ROOT/scripts/cmd/wv-cmd-core.sh" | grep -E 'active_claims|FROM nodes;' || true)
check "no deletion gate reads a failed count as zero" "" "$offenders"

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ] && echo "All tests passed" || { echo "FAILED"; exit 1; }
