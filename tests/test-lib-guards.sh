#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# Guards in scripts/lib that the suites routed to them never exercised
# (wv-12ea86). The cloud probe wv-0b9d5c planted a break in each, and every
# routed suite stayed green:
#   db_migrate_lineage   - skipping the post-repair re-verification, so a
#                          repair that silently did nothing reports success
#   journal_clear_stale  - an inverted guard that never clears a stale op
#                          (cmd_work relies on it to unstick a failed sync)
#   wv-resolve-project   - the CLAUDE_PROJECT_DIR fallback, and pairing hooks
#                          with the checkout's own wv before the installed one
#   wv-gh.sh             - no suite drove gh_notify or _refresh_parent_gh
# Each unit is driven directly, in an isolated directory: going through the wv
# binary reaches some of them more than once per process, which can repair
# what one call broke (see test-edge-enum-lineage.sh).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }

T=$(mktemp -d /tmp/wv-lib-guards-XXXXXX)
trap 'rm -rf "$T"' EXIT

# ── db_migrate_lineage verifies its repair ────────────────────────────────────
echo "db_migrate_lineage: the postcondition is checked, not assumed"
L="$T/lineage"; mkdir -p "$L/hot" "$L/.weave" "$L/cfg"
# A pre-lineage pair: both tables exist, neither carries the lineage columns.
mk_db() {
    rm -f "$L/hot/brain.db"
    sqlite3 "$L/hot/brain.db" "CREATE TABLE nodes (id TEXT PRIMARY KEY, text TEXT);
        CREATE TABLE edges (source TEXT, target TEXT, type TEXT, PRIMARY KEY(source, target, type));"
}
# migrate <stub-add-column: yes|no> -> "rc|verdict", stderr to $L/err
migrate() {
    (cd "$L" && WEAVE_DIR="$L/.weave" WV_HOT_ZONE="$L/hot" WV_DB="$L/hot/brain.db" WV_CONFIG_DIR="$L/cfg" \
        STUB="$1" bash -c "
source '$ROOT/scripts/lib/wv-config.sh' 2>/dev/null
source '$ROOT/scripts/lib/wv-db-lineage.sh' 2>/dev/null
[ \"\$WV_DB\" = '$L/hot/brain.db' ] || { echo 'ISOLATION-LOST'; exit 1; }
# A repair that reports success and changes nothing.
[ \"\$STUB\" = yes ] && _db_lineage_add_column() { return 0; }
db_migrate_lineage; rc=\$?
printf '%s|%s' \"\$rc\" \"\$(db_lineage_pair_verdict \"\$(db_lineage_shape nodes)\" \"\$(db_lineage_shape edges)\")\"
") 2>"$L/err"
}
mk_db
out=$(migrate no)
[ "$out" != "ISOLATION-LOST" ] && ok "the fixture database is the one under test" ||
    bad "the fixture database is the one under test" "wv-config rejected the hot-zone override"
check "a real repair succeeds and leaves the pair canonical (baseline)" "0|canonical" "$out"
mk_db
out=$(migrate yes)
check "a repair that did nothing fails the migration" "1|repairable" "$out"
grep -qF "could not be repaired" "$L/err" && ok "...and says the schema could not be repaired" ||
    bad "...and says the schema could not be repaired" "stderr: $(head -3 "$L/err")"

# ── journal_clear_stale ───────────────────────────────────────────────────────
echo "journal_clear_stale: clears an old incomplete op, and only that"
J="$T/journal"; mkdir -p "$J"
# clear <age> -> "rc|remaining-lines"
clear_stale() {
    WV_HOT_ZONE="$J" bash -c "
source '$ROOT/scripts/lib/wv-journal.sh' 2>/dev/null
journal_clear_stale $1; rc=\$?
n=0; [ -f '$J/ops.journal' ] && n=\$(wc -l < '$J/ops.journal')
printf '%s|%s' \"\$rc\" \"\$n\""
}
iso() { date -u -d "$1" +%Y-%m-%dT%H:%M:%SZ; }
printf '{"event":"begin","op":"sync","op_id":"old1","args":{},"ts":"%s"}\n' "$(iso '2 hours ago')" > "$J/ops.journal"
check "an incomplete op older than the limit is cleared" "0|0" "$(clear_stale 1800)"
printf '{"event":"begin","op":"sync","op_id":"new1","args":{},"ts":"%s"}\n' "$(iso '1 minute ago')" > "$J/ops.journal"
check "a recent incomplete op is kept" "1|1" "$(clear_stale 1800)"
{ printf '{"event":"begin","op":"sync","op_id":"done1","args":{},"ts":"%s"}\n' "$(iso '2 hours ago')"
  printf '{"event":"end","op":"sync","op_id":"done1","ts":"%s"}\n' "$(iso '2 hours ago')"; } > "$J/ops.journal"
check "a journal of completed ops is kept" "1|2" "$(clear_stale 1800)"
rm -f "$J/ops.journal"
check "a missing journal is not an error to clear" "1|0" "$(clear_stale 1800)"

# ── wv-resolve-project.sh ─────────────────────────────────────────────────────
echo "wv-resolve-project: the fallback chain"
P="$T/proj"; NG="$T/not-a-repo"; mkdir -p "$P/.weave" "$NG"
# resolve <cwd> [VAR=value...] -> "WV_PROJECT_DIR|WV", sourced from this checkout
resolve() {
    local cwd="$1"; shift
    (cd "$cwd" && env -u WV_PROJECT_DIR -u CLAUDE_PROJECT_DIR -u WV "$@" GIT_CEILING_DIRECTORIES="$T" bash -c "
source '$ROOT/scripts/lib/wv-resolve-project.sh'
printf '%s|%s' \"\$WV_PROJECT_DIR\" \"\$WV\"")
}
out=$(resolve "$NG" CLAUDE_PROJECT_DIR="$P")
check "outside a git repo, CLAUDE_PROJECT_DIR is the project" "$P" "${out%%|*}"
out=$(resolve "$NG" WV_PROJECT_DIR="$P")
check "a project with no scripts/wv pairs with this checkout's wv, not the installed one" "$ROOT/scripts/wv" "${out#*|}"
out=$(resolve "$NG" WV_PROJECT_DIR="$HOME")
check "HOME is never the project root" "" "${out%%|*}"

# ── wv-gh.sh ──────────────────────────────────────────────────────────────────
echo "wv-gh: gh_notify and _refresh_parent_gh hand off to weave_gh"
G="$T/gh"; B="$G/bin"; mkdir -p "$B" "$G/hot"
printf '#!/bin/sh\nexit 0\n' > "$B/gh"
printf '#!/bin/sh\nprintf "%%s|%%s\\n" "$PYTHONPATH" "$*" >> "%s"\n' "$G/calls" > "$B/python3"
chmod +x "$B/gh" "$B/python3"
# notify <shell code> -> the calls the stub python3 recorded
notify() {
    rm -f "$G/calls"
    env -u VIRTUAL_ENV PATH="$B:$PATH" WV_HOT_ZONE="$G/hot" bash -c "
source '$ROOT/scripts/lib/wv-gh.sh'
$1" >/dev/null 2>&1
    cat "$G/calls" 2>/dev/null
}
check "notifications are opt-in" "" "$(notify 'gh_notify wv-aaaaaa work')"
check "gh_notify done hands the learning to weave_gh" \
    "$ROOT/scripts|-m weave_gh --notify wv-aaaaaa done --learning keep it" \
    "$(notify 'WV_GH_NOTIFY=1 gh_notify wv-aaaaaa done --learning="keep it"')"
check "gh_notify block hands over the blocker" \
    "$ROOT/scripts|-m weave_gh --notify wv-aaaaaa block --blocker wv-bbbbbb" \
    "$(notify 'WV_GH_NOTIFY=1 gh_notify wv-aaaaaa block --blocker=wv-bbbbbb')"
check "_refresh_parent_gh asks weave_gh to refresh the parent" \
    "$ROOT/scripts|-m weave_gh --refresh-parent wv-aaaaaa" \
    "$(notify '_refresh_parent_gh wv-aaaaaa')"
# A PATH with the stub python3 and the two tools the helpers call, and no gh.
N="$G/nogh"; mkdir -p "$N"; cp "$B/python3" "$N/"
for t in dirname readlink cat rm; do ln -s "$(command -v "$t")" "$N/$t"; done
rm -f "$G/calls"
env -u VIRTUAL_ENV PATH="$N" WV_HOT_ZONE="$G/hot" "$(command -v bash)" -c "
source '$ROOT/scripts/lib/wv-gh.sh'
WV_GH_NOTIFY=1 gh_notify wv-aaaaaa work; _refresh_parent_gh wv-aaaaaa" >/dev/null 2>&1
check "without gh, nothing is handed off" "" "$(cat "$G/calls" 2>/dev/null)"

# ── S0 re-measure survivors (wv-70fdf4) ───────────────────────────────────────
# Each guard below was inverted in a planted break and every routed suite
# stayed green (S0 re-measure, wv-51427f).

# db_stamp_repo_owner records which repository a hot zone belongs to; the
# leaked-override check in wv-config.sh reads it. Inverting either early
# return left every hot zone unstamped.
echo "db_stamp_repo_owner: a hot zone is stamped with its repository"
S="$T/stamp"; mkdir -p "$S/repo" "$S/hot"
out=$(cd "$S/repo" && WV_HOT_ZONE="$S/hot" bash -c "
source '$ROOT/scripts/lib/wv-config.sh' >/dev/null 2>&1
source '$ROOT/scripts/lib/wv-db.sh' >/dev/null 2>&1
REPO_ROOT='$S/repo'; db_stamp_repo_owner; cat '$S/hot/.repo_root' 2>/dev/null")
check "the owner file names the repository" "$(cd "$S/repo" && pwd -P)" "$out"

# is_container decides hot-zone placement; CI is one of its signals. On a host
# with none of them the answer is "no" either way, so the signal is supplied.
echo "is_container: a container signal is detected, and cached"
out=$(env -u _WV_CONTAINER CI=1 bash -c "source '$ROOT/scripts/lib/wv-resolve-runtime.sh'; is_container && echo yes || echo no")
check "CI marks the runtime as a container" "yes" "$out"
out=$(env CI=1 _WV_CONTAINER=no bash -c "source '$ROOT/scripts/lib/wv-resolve-runtime.sh'; is_container && echo yes || echo no")
check "a cached answer is used as is" "no" "$out"

# stdin_has_input waits, bounded, for the first byte of an open pipe: wv refs
# and wv bulk-update read piped input through it. With its deadline comparison
# flipped it gave up at once and a slow producer's input was dropped.
echo "stdin_has_input: a slow first byte is waited for, within the bound"
out=$({ sleep 0.5; echo x; } | WV_STDIN_TIMEOUT=3 bash -c "source '$ROOT/scripts/lib/wv-validate.sh'; stdin_has_input && echo ready || echo none")
check "input arriving after 0.5s is seen" "ready" "$out"
out=$(sleep 3 | WV_STDIN_TIMEOUT=1 bash -c "source '$ROOT/scripts/lib/wv-validate.sh'; stdin_has_input && echo ready || echo none")
check "an open pipe that stays empty ends the wait" "none" "$out"

# wv-validate.sh sources the violation vocabulary projected from the contract;
# its built-in list is a fallback for a partial install and holds 9 of the
# types. Skipping the projection rejected every finding typed outside those.
echo "wv-validate: the projected violation vocabulary is the one in force"
out=$(bash -c "source '$ROOT/scripts/lib/wv-validate.sh'; printf ' %s ' \"\$FINDING_VIOLATION_TYPES\"")
case "$out" in *" prose:register "*) out=projected ;; *) out="fallback: $out" ;; esac
check "a type only the contract defines is accepted" "projected" "$out"

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
