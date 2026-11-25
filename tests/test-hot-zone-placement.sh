#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# Hot-zone placement (wv-b831e3, owner ruling 2026-10-06). Per repository, the
# zone already holding a non-empty brain.db wins, whichever zone it is; with
# none, every process -- human shell, agent, container -- uses the /tmp zone;
# with more than one, wv refuses rather than pick. Before this, an agent marker
# sent a process to /tmp/weave-codex-<uid> and a process without one followed
# that directory only if it existed, so which process started first after a
# boot decided which database a human shell and an agent shared.
#
# The /tmp zone has two names (wv-95bddf, owner decision 2026-10-05):
# /tmp/weave-hotzone-<uid> (NEUZ), the neutral one a process is given, and
# /tmp/weave-codex-<uid> (TMPZ), the legacy one. Created fresh (wv-97d68a), the
# neutral name is the real directory and the legacy name a fence symlink to it;
# the earlier layout (the legacy directory real, the neutral name its alias) is
# still adopted as it stands, and wv hotzone migrate relocates it.
#
# Every case runs bash (wv hotzone db) and python (weave_gh _resolve_db_path)
# with and without an agent marker, in both start orders, and requires one DB
# path. The three Linux zones are moved under a private root with
# WV_TEST_HOT_ZONE_ROOT, honoured only under WV_TEST_MODE=1.
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

# macOS has one zone base, $TMPDIR/weave-<uid>, and none of the Linux names:
# a short section below checks that instead of skipping (wv-4ccc98).
DARWIN=0
case "${OSTYPE:-}" in
    linux*) ;;
    darwin*) DARWIN=1 ;;
    *) echo "Linux and macOS placement only; skipped on ${OSTYPE:-unknown}"; echo "Results: 0/0 passed"; exit 0 ;;
esac

T=$(mktemp -d /tmp/wv-hot-zone-placement-XXXXXX)
trap 'rm -rf "$T"' EXIT
Z="$T/zones"
mkdir -p "$Z/tmp" "$Z/dev/shm"
uid=$(id -u)
NEUZ="$Z/tmp/weave-hotzone-$uid"
TMPZ="$Z/tmp/weave-codex-$uid"
SHMZ="$Z/dev/shm/weave"
OLDZ="$Z/tmp/weave-$uid"

REPO="$T/repo"; mkdir -p "$REPO"; git -C "$REPO" init -q
REPO=$(cd "$REPO" && pwd -P)
HASH=$(echo "$REPO" | md5sum | cut -c1-8)

# Agent and container markers, cleared for a human shell. CLAUDECODE is the
# Claude marker after wv-50640a; placement must not read any of them.
MARKERS=(CODEX_THREAD_ID CODEX_CI COPILOT_AGENT CLAUDE_CODE_SSE_PORT CLAUDECODE CI)
# as <human|agent> <cmd...> -> run with this suite's zones and that identity
as() {
    local who="$1"; shift
    local -a env_args=(-u WV_HOT_ZONE -u WV_DB -u WV_PROJECT_DIR)
    local m
    for m in "${MARKERS[@]}"; do env_args+=(-u "$m"); done
    [ "$who" = "agent" ] && env_args+=(CODEX_CI=1)
    # A terminal Claude Code session: CLAUDECODE alone (wv-21698b).
    [ "$who" = "claude" ] && env_args+=(CLAUDECODE=1)
    (cd "$REPO" && env "${env_args[@]}" WV_TEST_MODE=1 WV_TEST_HOT_ZONE_ROOT="$Z" \
        WV_CONFIG_DIR="$T/config" "$@")
}
bash_db() { as "$1" "$WV" hotzone db 2>&1; echo "rc=$?"; }
# bash_db1 <who> -> the first line of bash_db (no early-exit pipe under pipefail)
bash_db1() { local out; out=$(bash_db "$1"); printf '%s\n' "${out%%$'\n'*}"; }
py_db() {
    as "$1" env PYTHONPATH="$ROOT/scripts" python3 -c '
from weave_gh.data import HotZoneConflictError, HotZoneUnsafeError, _resolve_db_path
try:
    print(_resolve_db_path())
except HotZoneConflictError as e:
    print("conflict:", e)
except HotZoneUnsafeError as e:
    print("unsafe:", e)' 2>&1
}
populate() { mkdir -p "$1/$HASH" && chmod 700 "$1" "$1/$HASH" && printf 'x' > "$1/$HASH/brain.db"; }
reset() { rm -rf "$NEUZ" "$TMPZ" "$SHMZ" "$OLDZ"; }
mkdir -p "$T/config"

# agree <label> <expected-db> -> bash and python, human and agent, agree on it
agree() {
    local label="$1" want="$2" who
    for who in human agent claude; do
        check "$label: bash, $who" "$want" "$(bash_db1 "$who")"
        check "$label: python, $who" "$want" "$(py_db "$who")"
    done
}

if [ "$DARWIN" = 1 ]; then
    # The test root prefixes the temp-directory zone as it prefixes the Linux
    # zones, so a suite isolates the same way on every OS (wv-19572f, owner
    # 2026-11-23); before, darwin ignored the root and a suite that set only
    # the root reached the live per-user zone.
    echo "macOS: one zone under <test root>\$TMPDIR/weave-<uid>, bash and python agreeing"
    mkdir -p "$T/tmpdir"
    export TMPDIR="$T/tmpdir/"   # macOS's own TMPDIR ends in a slash
    agree "TMPDIR with a trailing slash" "$Z$T/tmpdir/weave-$uid/$HASH/brain.db"
    check "no doubled slash in the resolved path" "" "$(bash_db1 human | grep -F '//' || true)"
    echo ""
    echo "Results: $pass/$run passed"
    [ "$pass" -eq "$run" ]
    exit $?
fi

echo "no database: every process uses the /tmp zone"
reset
agree "no database" "$NEUZ/$HASH/brain.db"
mkdir -m 700 "$SHMZ"
agree "an empty /dev/shm zone does not attract" "$NEUZ/$HASH/brain.db"

echo "one database: its zone wins, whatever the marker"
for z in "$TMPZ" "$SHMZ" "$OLDZ"; do
    reset; populate "$z"
    agree "only ${z#"$Z"} holds it" "$z/$HASH/brain.db"
done
reset; populate "$SHMZ"; mkdir -m 700 "$TMPZ"
agree "an existing /tmp zone without this repo's DB does not pull from /dev/shm" "$SHMZ/$HASH/brain.db"
reset; (umask 077 && mkdir -p "$SHMZ/$HASH"); : > "$SHMZ/$HASH/brain.db"
agree "an empty brain.db holds nothing" "$NEUZ/$HASH/brain.db"

echo "start order no longer decides"
# Human first: wv init creates the database, then an agent resolves.
reset
as human "$WV" init >/dev/null 2>&1
check "human first: wv init created the DB in the /tmp zone" "yes" "$([ -s "$TMPZ/$HASH/brain.db" ] && echo yes || echo no)"
agree "human first" "$NEUZ/$HASH/brain.db"
# Agent first, and a terminal Claude session first.
for who in agent claude; do
    reset
    as "$who" "$WV" init >/dev/null 2>&1
    check "$who first: wv init created the DB in the /tmp zone" "yes" "$([ -s "$TMPZ/$HASH/brain.db" ] && echo yes || echo no)"
    agree "$who first" "$NEUZ/$HASH/brain.db"
done
# The CLAUDECODE switch (wv-21698b) cannot move a terminal Claude session off
# the /dev/shm database it used before: it adopts it, and creates no second.
reset; populate "$SHMZ"
check "a terminal Claude session keeps its /dev/shm database" "$SHMZ/$HASH/brain.db" "$(bash_db1 claude)"
check "python agrees" "$SHMZ/$HASH/brain.db" "$(py_db claude)"
check "no second database is created" "no" "$([ -e "$TMPZ/$HASH" ] && echo yes || echo no)"
# A human's legacy /dev/shm DB is adopted by an agent, not split from.
reset; populate "$SHMZ"
check "an agent adopts a human's /dev/shm database" "$SHMZ/$HASH/brain.db" "$(bash_db1 agent)"
check "nothing is created in the /tmp zone" "no" "$([ -e "$TMPZ/$HASH" ] && echo yes || echo no)"

echo "more than one database: refuse, never pick"
reset; populate "$TMPZ"; populate "$SHMZ"
out=$(bash_db human)
has "bash refuses" "refusing to choose a database" "$out"
has "bash names the /tmp copy" "$TMPZ/$HASH/brain.db" "$out"
has "bash names the /dev/shm copy" "$SHMZ/$HASH/brain.db" "$out"
has "wv exits nonzero" "rc=1" "$out"
has "bash refuses for an agent too" "refusing to choose a database" "$(bash_db agent)"
has "python refuses" "conflict: refusing to choose a database" "$(py_db human)"
out=$(cd "$REPO" && env -u WV_DB WV_TEST_MODE=1 WV_TEST_HOT_ZONE_ROOT="$Z" WV_CONFIG_DIR="$T/config" \
    WV_HOT_ZONE="$SHMZ/$HASH" "$WV" hotzone db 2>&1)
check "an explicit WV_HOT_ZONE settles it" "$SHMZ/$HASH/brain.db" "$out"

echo "the /tmp zone's two names (wv-95bddf)"
is_link_to() { [ -L "$1" ] && [ "$(readlink -- "$1")" = "$2" ] && echo yes || echo no; }
reset
as human "$WV" init >/dev/null 2>&1
check "wv init makes the neutral directory real (wv-97d68a)" "yes" "$([ -d "$NEUZ" ] && [ ! -L "$NEUZ" ] && echo yes || echo no)"
check "and the legacy name a fence symlink to it" "yes" "$(is_link_to "$TMPZ" "$NEUZ")"
check "one database under both names" "yes" "$([ "$NEUZ/$HASH/brain.db" -ef "$TMPZ/$HASH/brain.db" ] && echo yes || echo no)"
# A process that knows only the legacy name (an old binary, a resolved
# WV_HOT_ZONE) is refused by the base guard rather than given a second zone.
out=$(as human env WV_HOT_ZONE="$TMPZ/$HASH" "$WV" add "written by the legacy name" 2>&1; echo "rc=$?")
has "a write by the legacy name is refused at the fence" "refusing to use hot-zone base $TMPZ: it is a symlink" "$out"
check "and no second directory appears under it" "yes" "$(is_link_to "$TMPZ" "$NEUZ")"

reset; populate "$TMPZ"
agree "legacy only: used by its legacy name" "$TMPZ/$HASH/brain.db"
as human "$WV" status >/dev/null 2>&1
check "first use adds the alias beside it" "yes" "$(is_link_to "$NEUZ" "$TMPZ")"
agree "legacy plus alias: the neutral name" "$NEUZ/$HASH/brain.db"
check "nothing moved: the database is still in the real legacy directory" "yes" \
    "$([ -d "$TMPZ" ] && [ ! -L "$TMPZ" ] && [ -s "$TMPZ/$HASH/brain.db" ] && echo yes || echo no)"

reset; populate "$NEUZ"
agree "relocated (neutral only): used directly" "$NEUZ/$HASH/brain.db"
as human "$WV" status >/dev/null 2>&1
check "no legacy directory is recreated beside it: only the fence link" "yes" "$(is_link_to "$TMPZ" "$NEUZ")"

# Another repository's database in the legacy directory: the refusal is about
# the zone's two names, not this repository holding two copies.
reset; populate "$NEUZ"; mkdir -m 700 "$TMPZ" "$TMPZ/ffff0000"; printf 'x' > "$TMPZ/ffff0000/brain.db"
out=$(bash_db human)
has "both names populated: bash refuses" "are separate directories and both hold databases" "$out"
has "wv exits nonzero" "rc=1" "$out"
has "the refusal lists this repository's database" "$NEUZ/$HASH" "$out"
has "and the other repository's" "$TMPZ/ffff0000" "$out"
has "and says to remove nothing yet" "Remove nothing yet" "$out"
has "python refuses" "conflict: refusing to choose a hot zone" "$(py_db human)"
reset; (umask 077 && mkdir -p "$NEUZ"); populate "$TMPZ"
agree "both names, only the legacy populated: its holder" "$TMPZ/$HASH/brain.db"
# A new repository beside an empty neutral directory and a legacy one holding
# another repository's database lands in the legacy directory: landing in the
# neutral one would make the conflict the next call refuses (wv-6f2eed).
reset; mkdir -m 700 "$NEUZ" "$TMPZ" "$TMPZ/ffff0000"; printf 'x' > "$TMPZ/ffff0000/brain.db"
agree "both names, a new repository: the legacy directory" "$TMPZ/$HASH/brain.db"
as human "$WV" init >/dev/null 2>&1
check "wv init writes it there" "yes" "$([ -s "$TMPZ/$HASH/brain.db" ] && echo yes || echo no)"
check "the neutral directory stays empty" "no" "$([ -e "$NEUZ/$HASH" ] && echo yes || echo no)"
has "and the next call still works" "rc=0" "$(as human "$WV" status >/dev/null 2>&1; echo "rc=$?")"
reset; (umask 077 && mkdir -p "$NEUZ" "$TMPZ")
agree "both names, neither populated: the legacy directory" "$TMPZ/$HASH/brain.db"
reset; mkdir -m 700 "$TMPZ" "$NEUZ" "$NEUZ/ffff0000"; printf 'x' > "$NEUZ/ffff0000/brain.db"
agree "both names, only the neutral populated (relocated): the neutral directory" "$NEUZ/$HASH/brain.db"

reset; (umask 077 && mkdir -p "$TMPZ"); populate "$T/elsewhere"; ln -s "$T/elsewhere" "$NEUZ"
out=$(bash_db human)
has "an alias to another target: bash refuses" "is a symlink to $T/elsewhere, not $TMPZ" "$out"
has "python refuses" "unsafe: refusing to use hot-zone base $NEUZ: it is a symlink to $T/elsewhere" "$(py_db human)"
rm -rf "$T/elsewhere"

reset; ln -s "$TMPZ" "$NEUZ"
agree "an alias whose legacy directory was removed is usable" "$NEUZ/$HASH/brain.db"
as human "$WV" status >/dev/null 2>&1
check "first use makes the neutral name the directory (wv-97d68a)" "yes" "$([ -d "$NEUZ" ] && [ ! -L "$NEUZ" ] && echo yes || echo no)"
check "and the legacy name its fence link" "yes" "$(is_link_to "$TMPZ" "$NEUZ")"

reset; ln -s "$NEUZ" "$TMPZ"
agree "a fence link whose directory was removed: the neutral name" "$NEUZ/$HASH/brain.db"
as human "$WV" status >/dev/null 2>&1
check "first use recreates the neutral directory behind the fence link" "yes" "$([ -d "$NEUZ" ] && [ ! -L "$NEUZ" ] && echo yes || echo no)"

echo "the test root is inert without WV_TEST_MODE=1"
# shellcheck disable=SC2016  # $1/$2 expand in the bash -c child, passed as positional arguments
out=$(cd "$REPO" && env -u WV_HOT_ZONE -u WV_DB -u WV_TEST_MODE WV_TEST_HOT_ZONE_ROOT="$Z" \
    bash -c 'source "$1"; resolve_hot_zone "$2"' _ "$ROOT/scripts/lib/wv-resolve-runtime.sh" "$REPO" 2>&1)
has "it is ignored and says so" "WV_TEST_HOT_ZONE_ROOT needs WV_TEST_MODE=1" "$out"
# Either live name, by what this host holds: neither is under the test root.
case "$out" in
    *"/tmp/weave-hotzone-$uid"*|*"/tmp/weave-codex-$uid"*) ok "the real /tmp zone is used" ;;
    *) bad "the real /tmp zone is used" "got [$out]" ;;
esac

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ] && echo "All tests passed" || { echo "FAILED"; exit 1; }
