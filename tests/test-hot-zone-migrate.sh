#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# wv hotzone migrate (wv-97d68a, owner decision 2026-11-19): relocate the /tmp
# zone from the legacy layout (real /tmp/weave-codex-<uid>, the neutral name
# its alias) to the neutral name, the legacy name left as a fence symlink.
# Every layout is built under a private root (WV_TEST_HOT_ZONE_ROOT, honoured
# only under WV_TEST_MODE=1), and the fence is driven by real processes holding
# a file, a working directory or an environment value in the test zone, and by
# a planted pre-rc.14 copy of the placement code.
set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# The product's md5sum (wv-resolve-runtime.sh, side-effect free): the repo hash a
# product path is keyed on, the same on macOS, which has no md5sum(1) (wv-ef5621).
# shellcheck disable=SC1091  # resolved at run time
source "$ROOT/scripts/lib/wv-resolve-runtime.sh"
WV="$ROOT/scripts/wv"
run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }
has() { if [[ "$3" == *"$2"* ]]; then ok "$1"; else bad "$1" "expected to contain [$2], got [$3]"; fi; }
# Off Linux there is one zone name and nothing to migrate: a short section
# below checks that migrate says so and touches nothing (wv-4ccc98).
DARWIN=0
case "${OSTYPE:-}" in
    linux*) ;;
    darwin*) DARWIN=1 ;;
    *) echo "Linux and macOS only; skipped on ${OSTYPE:-unknown}"; echo "Results: 0/0 passed"; exit 0 ;;
esac
T=$(mktemp -d /tmp/wv-hot-zone-migrate-XXXXXX)
PIDS=()
cleanup() { local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "$T"; }
trap cleanup EXIT
Z="$T/zones"; mkdir -p "$Z/tmp" "$T/home" "$T/config"
uid=$(id -u)
N="$Z/tmp/weave-hotzone-$uid"
L="$Z/tmp/weave-codex-$uid"
H=aaaa1111

# mig [args] -> wv hotzone migrate under the test root, with a clean environment:
# a private HOME and config (no installed copies unless a case plants one) and
# no wv on PATH but the checkout's own.
mig() {
    env -i HOME="$T/home" PATH="/usr/bin:/bin" WV_CONFIG_DIR="$T/config" \
        WV_TEST_MODE=1 WV_TEST_HOT_ZONE_ROOT="$Z" WV_CALL_SOURCE=test WV_TEST_SUITE=1 \
        bash "$WV" hotzone migrate "$@" 2>&1
    echo "rc=$?"
}
populate() { mkdir -p "$1/$H" && chmod 700 "$1" "$1/$H" && sqlite3 "$1/$H/brain.db" "CREATE TABLE nodes(id TEXT); INSERT INTO nodes VALUES('kept');"; }
reset() { rm -rf "$N" "$L" "$Z/tmp"/weave-hotzone-*.migrate-*; }
is_link_to() { [ -L "$1" ] && [ "$(readlink -- "$1")" = "$2" ] && echo yes || echo no; }

if [ "$DARWIN" = 1 ]; then
    echo "macOS: nothing to migrate"
    out=$(mig --apply)
    has "migrate says there is nothing to do" "nothing to do" "$out"
    check "and creates nothing under the zone root" "" "$(ls -A "$Z/tmp")"
    echo ""
    echo "Results: $pass/$run passed"
    [ "$pass" -eq "$run" ]
    exit $?
fi
is_real_dir() { [ -d "$1" ] && [ ! -L "$1" ] && echo yes || echo no; }
relocated() {  # relocated <label> -> the end state, with the database intact
    check "$1: the neutral name is the real directory" "yes" "$(is_real_dir "$N")"
    check "$1: the legacy name is its fence link" "yes" "$(is_link_to "$L" "$N")"
    check "$1: the database moved intact" "kept" "$(sqlite3 -cmd "PRAGMA query_only=1" "file:$N/$H/brain.db?mode=rw" 'SELECT id FROM nodes;' 2>&1)"
    check "$1: no alias was left set aside" "" "$(ls -d "$Z/tmp"/weave-hotzone-*.migrate-* 2>/dev/null)"
}

echo "legacy only"
reset; populate "$L"; ino=$(wv_stat ino "$L/$H/brain.db" || echo unread-before)  # unread never matches (wv-b30dc6)
out=$(mig)
has "dry run says what moves" "move $L to $N" "$out"
has "dry run says the fence holds" "fence holds" "$out"
has "dry run exits 0" "rc=0" "$out"
check "dry run moves nothing" "yes" "$(is_real_dir "$L")"
out=$(mig --apply)
has "apply exits 0" "rc=0" "$out"
relocated "legacy only"
check "a rename, not a copy: the inode is kept" "$ino" "$(wv_stat ino "$N/$H/brain.db" || echo unread-after)"

echo "the legacy layout (neutral alias to the legacy directory)"
reset; populate "$L"; ln -s "$L" "$N"
out=$(mig --apply)
has "apply exits 0" "rc=0" "$out"
relocated "alias"

echo "neutral only, and rerun"
reset; populate "$N"
out=$(mig --apply)
has "no data moves" "no data moves" "$out"
relocated "neutral only"
out=$(mig --apply)
has "a rerun has nothing to do" "nothing to do" "$out"
has "and exits 0" "rc=0" "$out"

echo "neither name"
reset
out=$(mig --apply)
has "apply exits 0" "rc=0" "$out"
check "the neutral directory is created" "yes" "$(is_real_dir "$N")"
check "with its fence link" "yes" "$(is_link_to "$L" "$N")"

echo "both names present"
reset; populate "$N"; mkdir -m 700 "$L" "$L/ffff0000"; sqlite3 "$L/ffff0000/brain.db" "CREATE TABLE nodes(id TEXT);"
out=$(mig --apply)
has "both populated: refused" "both hold databases" "$out"
has "and exits 1" "rc=1" "$out"
check "nothing moved" "yes|yes" "$(is_real_dir "$N")|$(is_real_dir "$L")"
reset; populate "$L"; mkdir -m 700 "$N"
out=$(mig --apply)
has "an empty neutral directory beside a populated legacy one goes first" "removed the empty $N" "$out"
relocated "empty neutral beside legacy"
reset; populate "$N"; mkdir -m 700 "$L"
has "an empty legacy directory: the plan moves no data" "remove the empty $L, then link $L to $N; no data moves" "$(mig)"
out=$(mig --apply)
has "an empty legacy directory beside the neutral one goes" "removed the empty $L" "$out"
relocated "empty legacy beside neutral"
reset; populate "$N"; mkdir -m 700 "$L"; : > "$L/stray"
out=$(mig --apply)
has "a legacy directory with files but no database is refused" "holds files but no database" "$out"
check "and kept" "yes" "$([ -e "$L/stray" ] && echo yes || echo no)"

echo "fence: a process using the zone stops the move"
fenced() {  # fenced <label> -> apply is refused naming the process, nothing moved
    local out; out=$(mig --apply)
    has "$1: refused" "Processes still using the zone" "$out"
    has "$1: names the process" "pid ${PIDS[-1]}" "$out"
    has "$1: exits 1" "rc=1" "$out"
    check "$1: nothing moved" "yes" "$(is_real_dir "$L")"
    kill "${PIDS[-1]}" 2>/dev/null; wait "${PIDS[-1]}" 2>/dev/null
}
reset; populate "$L"; ln -s "$L" "$N"
bash -c 'exec 3<"$1"; exec sleep 60' _ "$L/$H/brain.db" & PIDS+=($!); sleep 0.3
fenced "an open file"
(cd "$N/$H" && exec sleep 60) & PIDS+=($!); sleep 0.3
fenced "a working directory reached by the alias"
env WV_DB="$N/$H/brain.db" sleep 60 & PIDS+=($!); sleep 0.3
fenced "a resolved WV_DB in the environment"
env WV_HOT_ZONE="$L/$H" sleep 60 & PIDS+=($!); sleep 0.3
fenced "a WV_HOT_ZONE by the legacy name"
env WV_HOT_ZONE="${N}0/$H" sleep 60 & PIDS+=($!); sleep 0.3
out=$(mig)
has "a longer name sharing the prefix is not the zone" "fence holds" "$out"
kill "${PIDS[-1]}" 2>/dev/null; wait "${PIDS[-1]}" 2>/dev/null

echo "fence: placement code that predates the neutral name"
reset; populate "$L"
old="$T/home/.local/lib/weave/lib/wv-resolve-runtime.sh"
mkdir -p "${old%/*}"
# shellcheck disable=SC2016  # the planted copy's own text, not expanded here
printf '_HZ="/tmp/weave-codex-${UID}"\n' > "$old"
out=$(mig --apply)
has "refused" "predates the neutral name" "$out"
has "names the copy" "$old" "$out"
has "exits 1" "rc=1" "$out"
check "nothing moved" "yes" "$(is_real_dir "$L")"
# shellcheck disable=SC2016  # as above
printf '_HZ="/tmp/weave-hotzone-${UID}"\n' > "$old"
has "a copy that knows the neutral name passes" "rc=0" "$(mig --apply)"
rm -rf "$T/home/.local"

echo "arguments"
has "an unknown argument exits 2" "rc=2" "$(mig --force)"
has "--help prints usage" "Usage: wv hotzone migrate" "$(mig --help)"

echo "never automatic"
callers=$(grep -rlIE "wv_hotzone_migrate|hotzone migrate --apply" "$ROOT/scripts" "$ROOT/templates" "$ROOT/install.sh" 2>/dev/null \
    | grep -vE "/scripts/wv$|/lib/wv-hotzone-migrate.sh$|/cmd/wv-cmd-help.sh$" || true)
check "only the dispatcher calls it; nothing runs it with --apply" "" "$callers"

echo "after a relocation, bash and python resolve the neutral directory"
reset; populate "$L"; mig --apply >/dev/null
REPO="$T/repo"; mkdir -p "$REPO"; git -C "$REPO" init -q; REPO=$(cd "$REPO" && pwd -P)
RH=$(echo "$REPO" | md5sum | cut -c1-8)
bash_db=$(cd "$REPO" && env -u WV_HOT_ZONE -u WV_DB WV_TEST_MODE=1 WV_TEST_HOT_ZONE_ROOT="$Z" WV_CONFIG_DIR="$T/config" "$WV" hotzone db 2>&1)
check "bash" "$N/$RH/brain.db" "$bash_db"
py_db=$(cd "$REPO" && env -u WV_HOT_ZONE -u WV_DB WV_TEST_MODE=1 WV_TEST_HOT_ZONE_ROOT="$Z" PYTHONPATH="$ROOT/scripts" \
    python3 -c 'from weave_gh.data import _resolve_db_path; print(_resolve_db_path())' 2>&1)
check "python" "$N/$RH/brain.db" "$py_db"

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ] && echo "All tests passed" || { echo "FAILED"; exit 1; }
