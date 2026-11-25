#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# Hot-zone base safety (wv-80be32). Every base resolve_hot_zone can return
# lives in a world-writable sticky directory, so another local user can create
# it first and swap this repository's graph for theirs. A base is usable only
# as a real directory owned by this uid with no group or other write, or as the
# one exact alias a rename migration may leave. Bash (wv-resolve-runtime.sh,
# wv-config.sh, wv-db.sh) and Python (weave_gh/data.py) must agree.
#
# Guarded bases are fixed host paths, one of them live on every host, so the
# end-to-end cases add a private base with WV_TEST_HOT_ZONE_BASE, which is
# honoured only under WV_TEST_MODE=1 and can only add a base.
set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESOLVER="$ROOT/scripts/lib/wv-resolve-runtime.sh"

run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }
has() { if [[ "$3" == *"$2"* ]]; then ok "$1"; else bad "$1" "expected to contain [$2], got [$3]"; fi; }

T=$(mktemp -d /tmp/wv-hot-zone-base-XXXXXX)
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT

mode_of() { stat -c '%a' -- "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }
# problem <path> [<alias-target>] -> what hot_zone_dir_problem prints
problem() { bash -c 'source "$1"; hot_zone_dir_problem "$2" "${3:-}"' _ "$RESOLVER" "$@"; }
# resolver <function> <args...> -> run one resolver function, rc on the last line
resolver() { bash -c 'source "$1"; shift; "$@"; echo "rc=$?"' _ "$RESOLVER" "$@" 2>&1; }
# resolver1 <function> <args...> -> the first line of resolver's output
resolver1() { local out; out=$(resolver "$@"); printf '%s\n' "${out%%$'\n'*}"; }

# ── hot_zone_dir_problem: what a base may be ────────────────────────────────
echo "hot_zone_dir_problem: a base is a private, real directory of this uid"
check "an absent base is not a problem (it is created)" "" "$(problem "$T/absent")"
mkdir -m 700 "$T/private"
check "a 700 directory of this uid is usable" "" "$(problem "$T/private")"
mkdir -m 755 "$T/readable"
check "a 755 directory of this uid is usable" "" "$(problem "$T/readable")"
mkdir "$T/open"; chmod 777 "$T/open"
check "a mode-777 directory is refused" "is writable by group or others (mode 777)" "$(problem "$T/open")"
mkdir "$T/group"; chmod 775 "$T/group"
check "a group-writable directory is refused (umask 002 made the live one)" \
    "is writable by group or others (mode 775)" "$(problem "$T/group")"
: > "$T/file"
check "a file is refused" "is not a directory" "$(problem "$T/file")"
ln -s "$T/private" "$T/link"
check "a symlink is refused when no alias is allowed" "is a symlink" "$(problem "$T/link")"
if [ "$(id -u)" -ne 0 ]; then
    check "a directory of another uid is refused" "is owned by uid 0, not $(id -u)" "$(problem /)"
else
    ok "a directory of another uid is refused (skipped: running as root)"
fi

echo "hot_zone_dir_problem: the one alias a migration may leave"
check "an alias to exactly the allowed target is usable" "" "$(problem "$T/link" "$T/private")"
check "an alias to another target is refused" \
    "is a symlink to $T/private, not $T/readable" "$(problem "$T/link" "$T/readable")"
ln -s "$T/open" "$T/link-open"
check "an alias to a refused directory is refused" \
    "is a symlink to $T/open, which is writable by group or others (mode 777)" \
    "$(problem "$T/link-open" "$T/open")"
ln -s "$T/link" "$T/link-chain"
check "an alias to another symlink is refused" \
    "is a symlink to $T/link, which is not a real directory" "$(problem "$T/link-chain" "$T/link")"

# ── hot_zone_guarded_base: which paths are guarded ──────────────────────────
echo "hot_zone_guarded_base: the known shared-parent bases and their children"
uid=$(id -u)
check "a hash directory in the /tmp zone" "/tmp/weave-hotzone-$uid" \
    "$(resolver1 hot_zone_guarded_base "/tmp/weave-hotzone-$uid/175b8f29")"
check "a hash directory under the /tmp zone's legacy name" "/tmp/weave-codex-$uid" \
    "$(resolver1 hot_zone_guarded_base "/tmp/weave-codex-$uid/175b8f29")"
check "the /dev/shm base itself" "/dev/shm/weave" "$(resolver1 hot_zone_guarded_base /dev/shm/weave)"
check "a container base child" "/tmp/weave-$uid" "$(resolver1 hot_zone_guarded_base "/tmp/weave-$uid/abcd1234/")"
check "a private directory is not guarded" "rc=0" "$(resolver hot_zone_guarded_base "$T/private/abcd")"
check "a path deeper in a base is guarded" "/tmp/weave-hotzone-$uid" \
    "$(resolver1 hot_zone_guarded_base "/tmp/weave-hotzone-$uid/a/b")"
check "a sibling sharing the base's prefix is not guarded" "rc=0" \
    "$(resolver hot_zone_guarded_base "/tmp/weave-hotzone-${uid}x/a")"
# The live lock base: no test root, whatever this suite inherited (the gate
# gives each suite its own root, which now prefixes the lock base, wv-b3cb72).
check "the bash-dedup lock base is guarded" "/tmp/weave-bash-locks-$uid" \
    "$(unset WV_TEST_HOT_ZONE_ROOT; resolver1 hot_zone_guarded_base "$(unset WV_TEST_HOT_ZONE_ROOT; resolver1 resolve_bash_lock_dir abcd1234)")"
check "the lock directory is per uid" "/tmp/weave-bash-locks-$uid/abcd1234" \
    "$(unset WV_TEST_HOT_ZONE_ROOT; resolver1 resolve_bash_lock_dir abcd1234)"
# The test root prefixes the lock base as it prefixes every zone (wv-b3cb72):
# an isolated suite never reads or clears a live session's in-flight locks.
mkdir -p "$T/lockroot"
check "under a test root the lock directory is inside the root" "$T/lockroot/tmp/weave-bash-locks-$uid/abcd1234/s-sess" \
    "$(WV_TEST_MODE=1 WV_TEST_HOT_ZONE_ROOT="$T/lockroot" resolver1 resolve_bash_lock_dir abcd1234 sess)"
check "...and that base is guarded" "$T/lockroot/tmp/weave-bash-locks-$uid" \
    "$(WV_TEST_MODE=1 WV_TEST_HOT_ZONE_ROOT="$T/lockroot" resolver1 hot_zone_guarded_base "$T/lockroot/tmp/weave-bash-locks-$uid/abcd1234")"
check "...and ensure makes it inside the root, <root>/tmp included, mode 700" "rc=0 700" \
    "$(WV_TEST_MODE=1 WV_TEST_HOT_ZONE_ROOT="$T/lockroot" resolver hot_zone_ensure "$T/lockroot/tmp/weave-bash-locks-$uid/abcd1234" | tail -1) $(mode_of "$T/lockroot/tmp/weave-bash-locks-$uid")"
out=$(unset WV_TEST_MODE; WV_TEST_HOT_ZONE_ROOT="$T/lockroot" resolver resolve_bash_lock_dir abcd1234)
check "without WV_TEST_MODE=1 the root is ignored for locks too" "/tmp/weave-bash-locks-$uid/abcd1234" \
    "$(grep -m1 '^/' <<< "$out")"
has "...and says so" "WV_TEST_HOT_ZONE_ROOT needs WV_TEST_MODE=1" "$out"
out=$(unset WV_TEST_MODE; WV_TEST_HOT_ZONE_BASE="$T/tb" resolver hot_zone_guarded_base "$T/tb/leaf")
has "the test base is ignored without WV_TEST_MODE=1" "rc=0" "$out"
check "and not added" "no" "$([[ "$out" == "$T/tb"* ]] && echo yes || echo no)"
has "and says so" "WV_TEST_HOT_ZONE_BASE is set but WV_TEST_MODE=1 is not" "$out"
out=$(WV_TEST_MODE=1 WV_TEST_HOT_ZONE_BASE="tb" resolver hot_zone_guarded_base "tb/leaf")
has "a relative test base is refused" "is not an absolute path; ignoring it" "$out"
check "the warning is printed once per process" "1" \
    "$(env -u WV_TEST_MODE WV_TEST_HOT_ZONE_BASE="$T/tb" bash -c 'source "$1"; hot_zone_guarded_base x; hot_zone_guarded_base y' _ "$RESOLVER" 2>&1 | grep -c 'WV_TEST_HOT_ZONE_BASE.*ignoring')"
check "the test base is added under WV_TEST_MODE=1" "$T/tb" \
    "$(WV_TEST_MODE=1 WV_TEST_HOT_ZONE_BASE="$T/tb" resolver1 hot_zone_guarded_base "$T/tb/leaf")"

# ── hot_zone_ensure: creation is checked, never repaired ────────────────────
echo "hot_zone_ensure: one level at a time, 700, verified, never chmod"
export WV_TEST_MODE=1
B="$T/base-new"
out=$(WV_TEST_HOT_ZONE_BASE="$B" bash -c 'umask 002; source "$1"; hot_zone_ensure "$2/leaf"; echo "rc=$?"' _ "$RESOLVER" "$B" 2>&1)
check "a new base and leaf are created" "rc=0" "$out"
check "the base is 700 even under umask 002" "700" "$(mode_of "$B")"
check "the leaf is 700 even under umask 002" "700" "$(mode_of "$B/leaf")"

B="$T/base-open"; mkdir "$B"; chmod 777 "$B"
out=$(WV_TEST_HOT_ZONE_BASE="$B" resolver hot_zone_ensure "$B/leaf")
has "a mode-777 base is refused" "refusing to use hot-zone base $B: it is writable by group or others" "$out"
has "the refusal gives the owner's fix" "chmod go-w '$B'" "$out"
has "the refusal fails the call" "rc=1" "$out"
check "nothing is created in a refused base" "no" "$([ -e "$B/leaf" ] && echo yes || echo no)"
check "a refused base is not chmodded" "777" "$(mode_of "$B")"

B="$T/base-link"; ln -s "$T/private" "$B"
out=$(WV_TEST_HOT_ZONE_BASE="$B" resolver hot_zone_ensure "$B/leaf")
has "a symlinked base is refused" "it is a symlink" "$out"
check "nothing is created through the link" "no" "$([ -e "$T/private/leaf" ] && echo yes || echo no)"

B="$T/base-file"; : > "$B"
out=$(WV_TEST_HOT_ZONE_BASE="$B" resolver hot_zone_ensure "$B/leaf")
has "a base that is a file is refused" "it is not a directory" "$out"

B="$T/base-ok"; mkdir -m 700 "$B"; ln -s "$T/private" "$B/leaf"
out=$(WV_TEST_HOT_ZONE_BASE="$B" resolver hot_zone_ensure "$B/leaf")
has "a symlinked leaf in a good base is refused" "refusing to use hot zone $B/leaf: it is a symlink" "$out"

B="$T/base-deep"
out=$(WV_TEST_HOT_ZONE_BASE="$B" bash -c 'umask 002; source "$1"; hot_zone_ensure "$2/leaf/run_cache/x"; echo "rc=$?"' _ "$RESOLVER" "$B" 2>&1)
check "a path deeper in a new base is created" "rc=0" "$out"
check "its base is 700, not left to mkdir -p and the umask" "700" "$(mode_of "$B")"
check "its leaf is 700" "700" "$(mode_of "$B/leaf")"
check "the deeper levels are 700" "700" "$(mode_of "$B/leaf/run_cache/x")"
B="$T/base-deep-open"; mkdir "$B"; chmod 777 "$B"
out=$(WV_TEST_HOT_ZONE_BASE="$B" resolver hot_zone_ensure "$B/leaf/run_cache")
has "a path deeper in a mode-777 base is refused" "refusing to use hot-zone base $B" "$out"
check "nothing is created in it" "no" "$([ -e "$B/leaf" ] && echo yes || echo no)"

# wv_finalize journals from an EXIT trap. A bare return in a function called
# from a trap returns the status from before the trap, so a call that failed
# made every later journal write look failed (test-attempt-journal.sh).
out=$(bash -c 'source "$1"; p="$2"; g() { hot_zone_ensure "$p"; echo "trap rc=$?"; }; trap g EXIT; k=a-b; h() { echo "${!k}"; }; h' _ "$RESOLVER" "$T/trap/leaf" 2>/dev/null)
check "hot_zone_ensure succeeds in an exit trap after a failed command" "trap rc=0" "$out"

out=$(resolver hot_zone_ensure "$T/chosen/leaf")
check "a hot zone outside any guarded base is created as before" "rc=0" "$out"
check "and is 700" "700" "$(mode_of "$T/chosen/leaf")"

# ── concurrent first use: each link is created once, never inside itself ────
# wv-5cd5a4: both link sites check that the other name is absent, then link.
# A second process passing the check before the first links used to run a
# plain ln -s onto the new link, which ln treats as a destination directory,
# leaving legacy/weave-codex-<uid> -> legacy. The ln wrapper makes the
# interleaving deterministic: the winner's link lands between the loser's
# check and its ln. The legacy site adds the neutral alias beside a legacy
# directory; the neutral site, first use of a fresh zone, adds the legacy
# fence link beside the neutral directory (wv-97d68a).
echo "concurrent first use: the loser of the link race adds no link"
uid=$(id -u)
race() {  # race <root> <path to ensure> <winner's link target> <winner's link name>
    WV_TEST_HOT_ZONE_ROOT="$1" bash -c '
        source "$1"
        ln() { if [ -z "${raced:-}" ]; then raced=1; command ln -s -- "$3" "$4"; fi; command ln "$@"; }
        hot_zone_ensure "$2"; echo "rc=$?"' _ "$RESOLVER" "$2" "$3" "$4" 2>&1
}
for site in legacy neutral; do
    R="$T/race-$site"; mkdir -p "$R/tmp"
    N="$R/tmp/weave-hotzone-$uid"; L="$R/tmp/weave-codex-$uid"
    if [ "$site" = legacy ]; then
        # hot_zone_ensure's alias step, reached through the legacy name.
        mkdir -m 700 "$L"; out=$(race "$R" "$L/abcd1234" "$L" "$N")
        real="$L"; link="$N"; inner="$L/weave-hotzone-$uid"
    else
        # hot_zone_ensure's fence-link step, a fresh zone by the neutral name.
        out=$(race "$R" "$N/abcd1234" "$N" "$L")
        real="$N"; link="$L"; inner="$N/weave-codex-$uid"
    fi
    check "$site site: the loser still succeeds" "rc=0" "${out##*$'\n'}"
    check "$site site: no link inside the real directory" "absent" \
        "$([ -L "$inner" ] || [ -e "$inner" ] && echo present || echo absent)"
    check "$site site: the other name links to the real directory" "$real" "$(readlink -- "$link")"
    check "$site site: the real directory holds only the repo directory" "abcd1234" "$(ls -A "$real")"
done
unset WV_TEST_MODE

# ── structural: every creation site goes through the guard ──────────────────
echo "creation sites: no mkdir -p of a hot-zone path outside hot_zone_ensure"
# mkdir -p of a missing hot-zone path creates its base under the caller's
# umask, which is how the live base became 775. The variables are the ones that
# name a hot zone, a path in one, or the lock directory.
hz_vars='WV_HOT_ZONE|_HC_HOT_ZONE|_SC_HOT_ZONE|hot_zone|RING_DIR|BUDGET_DIR|ADVISORY_DIR|LOCK_DIR|WV_RUN_CACHE_DIR|_WV_JOURNAL_FILE|WV_DB|marker|dedup_dir'
offenders=$(grep -rnIE "mkdir -p (-- )?\"?\\\$\{?(${hz_vars})|mkdir -p \"\\\$\(dirname \"\\\$\{?(${hz_vars})" \
    "$ROOT/scripts/lib" "$ROOT/scripts/cmd" "$ROOT/scripts/hooks" "$ROOT/scripts/wv" 2>/dev/null \
    | grep -v "wv-resolve-runtime.sh" || true)
check "no unguarded mkdir -p of a hot-zone path" "" "$offenders"
offenders=$(grep -rnI "/tmp/weave-bash-locks/" "$ROOT/scripts" "$ROOT/templates" 2>/dev/null || true)
check "no production path names the uid-less lock directory" "" "$offenders"

# ── end to end through wv ───────────────────────────────────────────────────
echo "wv: refuses before use, creates safely"
REPO="$T/repo"; mkdir -p "$REPO"; git -C "$REPO" init -q
# wv_in <base> <cmd...> -> run the checkout's wv in REPO with a hot zone in <base>
wv_in() {
    local base="$1"; shift
    (cd "$REPO" && env -u WV_DB WV_TEST_MODE=1 WV_TEST_HOT_ZONE_BASE="$base" \
        WV_HOT_ZONE="$base/leaf" WV_PROJECT_DIR="$REPO" "$ROOT/scripts/wv" "$@" 2>&1; echo "rc=$?")
}
B="$T/wv-open"; mkdir "$B"; chmod 777 "$B"
out=$(wv_in "$B" status)
has "wv refuses a mode-777 base" "refusing to use hot-zone base $B" "$out"
has "wv exits nonzero on it" "rc=1" "$out"
check "wv created nothing in it" "no" "$([ -e "$B/leaf" ] && echo yes || echo no)"
B="$T/wv-link"; ln -s "$T/private" "$B"
out=$(wv_in "$B" status)
has "wv refuses a symlinked base" "it is a symlink" "$out"
B="$T/wv-new"
out=$(cd "$REPO" && umask 002 && wv_in "$B" init)
has "wv init succeeds in a new base" "rc=0" "$out"
check "wv created the base 700 under umask 002" "700" "$(mode_of "$B")"
check "wv created the leaf 700 under umask 002" "700" "$(mode_of "$B/leaf")"

# ── python parity ───────────────────────────────────────────────────────────
echo "weave_gh: the same rule before reading or backfilling a DB"
# py_check <base> -> what weave_gh's _resolve_db_path does with a DB in <base>/leaf
py_check() {
    (cd "$ROOT" && WV_TEST_MODE=1 WV_TEST_HOT_ZONE_BASE="$1" WV_HOT_ZONE="$1/leaf" \
        PYTHONPATH="$ROOT/scripts" python3 -c '
from weave_gh.data import HotZoneUnsafeError, _resolve_db_path
try:
    print("ok", _resolve_db_path())
except HotZoneUnsafeError as e:
    print("refused:", e)' 2>&1)
}
mk_db_in() { mkdir -p "$1/leaf" && : > "$1/leaf/brain.db"; }
B="$T/py-ok"; mkdir -m 700 "$B"; mk_db_in "$B"
check "python uses a DB in a private base" "ok $B/leaf/brain.db" "$(py_check "$B")"
B="$T/py-open"; mkdir "$B"; mk_db_in "$B"; chmod 777 "$B"
has "python refuses a mode-777 base" "refused: refusing to use hot-zone base $B: it is writable by group or others (mode 777)" "$(py_check "$B")"
B="$T/py-link"; mkdir -m 700 "$T/py-target"; mk_db_in "$T/py-target"; ln -s "$T/py-target" "$B"
has "python refuses a symlinked base" "refused: refusing to use hot-zone base $B: it is a symlink; another" "$(py_check "$B")"
B="$T/py-file"; : > "$B"
out=$(cd "$ROOT" && WV_TEST_MODE=1 WV_TEST_HOT_ZONE_BASE="$B" PYTHONPATH="$ROOT/scripts" python3 -c '
from weave_gh.data import _check_hot_zone
import os
try:
    _check_hot_zone(os.environ["WV_TEST_HOT_ZONE_BASE"] + "/leaf/brain.db", os.getuid())
    print("ok")
except Exception as e:
    print("refused:", e)' 2>&1)
has "python refuses a base that is a file" "it is not a directory" "$out"
out=$(cd "$ROOT" && PYTHONPATH="$ROOT/scripts" python3 -c '
from weave_gh.data import _hot_zone_dir_problem
import os, sys
print(_hot_zone_dir_problem(sys.argv[1], os.getuid(), sys.argv[2]) or "")' "$T/link" "$T/readable")
check "python refuses an alias to another target" "is a symlink to $T/private, not $T/readable" "$out"
out=$(cd "$ROOT" && PYTHONPATH="$ROOT/scripts" python3 -c '
from weave_gh.data import _hot_zone_dir_problem
import os, sys
print(_hot_zone_dir_problem(sys.argv[1], os.getuid(), sys.argv[2]) or "usable")' "$T/link" "$T/private")
check "python accepts the exact alias" "usable" "$out"
if [ "$(id -u)" -ne 0 ]; then
    out=$(cd "$ROOT" && PYTHONPATH="$ROOT/scripts" python3 -c '
from weave_gh.data import _hot_zone_dir_problem
import os
print(_hot_zone_dir_problem("/", os.getuid()))')
    check "python refuses a directory of another uid" "is owned by uid 0, not $(id -u)" "$out"
fi

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ] && echo "All tests passed" || { echo "FAILED"; exit 1; }
