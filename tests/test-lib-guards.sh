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
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)

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
# BSD stand-ins (wv-372560, wv-e1ee87, wv-99f296, wv-0a8d84): no
# stat -c, no date -d, and %N printed as a literal N.
# Under tests/lib/macos-emulate.sh those stand-ins are already on PATH, so
# bsd runs the command as it is.
BSD="$T/bsd"; mkdir -p "$BSD/real"
if [ -z "${WV_BSD_SHIM_REAL:-}" ]; then
    for t in stat date pgrep script awk grep; do ln -s "$ROOT/tests/lib/bsd-shim/$t" "$BSD/$t"; ln -s "$(type -P "$t")" "$BSD/real/$t"; done
    ln -s "$(type -P iconv)" "$BSD/real/iconv"  # the awk stand-in checks UTF-8 with it
fi
# stand_in runs a command through the stand-ins (for the "(control)" checks of
# the stand-ins themselves). bsd runs a command on a BSD host: the stand-ins on
# Linux, but on a real Mac the host tools ARE BSD, and the stand-ins' GNU
# translations (date -r -> -d @) break them there (Mac round 2: 9 'bsd:' checks,
# wv-f8e26d), so a real darwin host runs it as it is.
stand_in() { if [ -n "${WV_BSD_SHIM_REAL:-}" ]; then "$@"; else PATH="$BSD:$PATH" WV_BSD_SHIM_REAL="$BSD/real" "$@"; fi; }
bsd() {
    case "${OSTYPE:-}" in darwin*) [ -n "${WV_MACOS_EMULATE:-}" ] || { "$@"; return; } ;; esac
    stand_in "$@"
}
# clear <age> -> "rc|remaining-lines"; the count is a number, not BSD wc's padded text
clear_stale() {
    WV_HOT_ZONE="$J" bash -c "
source '$ROOT/scripts/lib/wv-journal.sh' 2>/dev/null
journal_clear_stale $1; rc=\$?
n=0; [ -f '$J/ops.journal' ] && n=\$(( \$(wc -l < '$J/ops.journal') ))
printf '%s|%s' \"\$rc\" \"\$n\""
}
# iso <seconds-ago>
iso() { bash -c ". '$ROOT/scripts/lib/wv-resolve-runtime.sh'; wv_date_fmt -u \$(( \$(date +%s) - $1 )) +%Y-%m-%dT%H:%M:%SZ"; }
for host in native bsd; do
    run_as() { if [ "$host" = bsd ]; then bsd "$@"; else "$@"; fi; }
    printf '{"event":"begin","op":"sync","op_id":"old1","args":{},"ts":"%s"}\n' "$(iso 7200)" > "$J/ops.journal"
    check "$host: an incomplete op older than the limit is cleared" "0|0" "$(run_as clear_stale 1800)"
    printf '{"event":"begin","op":"sync","op_id":"new1","args":{},"ts":"%s"}\n' "$(iso 60)" > "$J/ops.journal"
    check "$host: a recent incomplete op is kept" "1|1" "$(run_as clear_stale 1800)"
    printf '{"event":"begin","op":"sync","op_id":"bad1","args":{},"ts":"%s"}\n' "not-a-time" > "$J/ops.journal"
    check "$host: an op whose start cannot be read is kept, not cleared as ancient" "1|1" "$(run_as clear_stale 1800)"
    { printf '{"event":"begin","op":"sync","op_id":"done1","args":{},"ts":"%s"}\n' "$(iso 7200)"
      printf '{"event":"end","op":"sync","op_id":"done1","ts":"%s"}\n' "$(iso 7200)"; } > "$J/ops.journal"
    check "$host: a journal of completed ops is kept" "1|2" "$(run_as clear_stale 1800)"
    rm -f "$J/ops.journal"
    check "$host: a missing journal is not an error to clear" "1|0" "$(run_as clear_stale 1800)"
done

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
# shellcheck disable=SC2016  # writes a script whose $ expands when that script runs
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
db_stamp_repo_owner '$S/repo'; cat '$S/hot/.repo_root' 2>/dev/null")
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

# generate_id printed 'wv-' when no sha256 tool answered, and the add failed
# later on a UNIQUE constraint (wv-ed3eac).
echo "wv-validate: generate_id refuses without a digest"
out=$(bash -c ". '$ROOT/scripts/lib/wv-resolve-runtime.sh'; . '$ROOT/scripts/lib/wv-validate.sh'; generate_id")
check "an id is wv- and six hex digits" "yes" "$([[ "$out" =~ ^wv-[0-9a-f]{6}$ ]] && echo yes || echo "no: $out")"
rc=0; out=$(bash -c ". '$ROOT/scripts/lib/wv-resolve-runtime.sh'; . '$ROOT/scripts/lib/wv-validate.sh'; sha256sum() { return 127; }; generate_id" 2>&1) || rc=$?
check "no digest: nonzero and no id printed" "1 no-id" "$rc $(grep -q '^wv-' <<< "$out" && echo id || echo no-id)"
check "...and the refusal names the missing tool" "yes" "$([[ "$out" == *"no sha256 tool"* ]] && echo yes || echo no)"

# Portable realpath forms (wv-e7426f): macOS realpath takes only -q.
echo "wv-resolve-runtime: realpath -e, -m and --relative-to without GNU flags"
mkdir -p "$T/rp/real/sub"; ln -s "$T/rp/real" "$T/rp/link"
rp() { bash -c ". '$ROOT/scripts/lib/wv-resolve-runtime.sh'; $1" 2>/dev/null; }
real=$(cd -P "$T/rp/real" && pwd)
check "existing: a symlink resolves" "$real" "$(rp "wv_realpath_existing '$T/rp/link'")"
check "existing: a missing path fails" "fail" "$(rp "wv_realpath_existing '$T/rp/none'" || echo fail)"
check "missing: the existing head resolves, the tail is kept" "$real/a/b" "$(rp "wv_realpath_missing '$T/rp/link/a/b'")"
check "relative: under root" "sub/x" "$(rp "wv_relpath '$T/rp/link' '$T/rp/real/sub/x'")"
check "relative: root itself is ." "." "$(rp "wv_relpath '$T/rp/real' '$T/rp/link'")"
check "relative: outside root fails" "fail" "$(rp "wv_relpath '$T/rp/real' '$T'" || echo fail)"

# Portable stat, date and clock readings (wv-372560, wv-e1ee87, wv-99f296):
# the same answers from GNU tools and from the BSD stand-ins, and a refusal,
# never 0, when there is no answer.
echo "wv-resolve-runtime: stat fields, stamps and clock readings on GNU and BSD"
printf 'twelve bytes' > "$T/st"; touch -d '2026-01-02 03:04:05 UTC' "$T/st" 2>/dev/null || touch -t 202601020304.05 "$T/st"
check "(control) the stand-in refuses stat -c" "refused" "$(stand_in stat -c %s "$T/st" 2>/dev/null || echo refused)"
check "(control) the stand-in prints %N as a literal N" "N" "$(stand_in date +%s%N | tr -d 0-9)"
check "(control) the stand-in refuses date -d" "refused" "$(stand_in date -d @0 +%s 2>/dev/null || echo refused)"
# GNU-only options (wv-f8e26d): both refusals hold on a real Mac too.
check "(control) the stand-in's pgrep -c counts nothing" "|refused" "$(stand_in pgrep -fc "^no-such-process-$$\$" 2>/dev/null)|$(stand_in pgrep -fc "^no-such-process-$$\$" >/dev/null 2>&1; [ "$?" -eq 2 ] && echo refused)"
check "(control) the stand-in refuses script -c" "refused" "$(stand_in script -qec true /dev/null >/dev/null 2>&1 || echo refused)"
# A \x escape in -F does not split on the byte under macOS awk (wv-e6ca42);
# the byte from bash still does. What the escape does split on is not asserted:
# a real Mac split on neither the byte nor the literal characters, the stand-in
# on the characters (Mac run 45339323254, wv-1fa160).
printf 'k\037real-byte\n' > "$T/awk-sep"
check "bsd: awk -F'\\x1f' does not split on the byte (on a real Mac, macOS awk itself)" "" \
    "$(bsd awk -F'\x1f' '$1 == "k" { print $2 }' "$T/awk-sep")"
check "bsd: ...and -F with the real byte splits on the byte" "real-byte" \
    "$(bsd awk -F $'\x1f' '$1 == "k" { print $2 }' "$T/awk-sep")"
# grep -Z is not --null on a Mac (wv-0a8d84): -lZ names end in a newline, so
# xargs -0 would get both as one argument; --null ends them in NUL on both.
printf 'hit\n' > "$T/gz-a"; printf 'hit\n' > "$T/gz-b"
check "bsd: grep -lZ ends names in a newline, not NUL (on a real Mac, macOS grep itself)" "0 2" \
    "$(bsd grep -lZF hit "$T/gz-a" "$T/gz-b" | tr -cd '\0' | wc -c | tr -d ' ') $(bsd grep -lZF hit "$T/gz-a" "$T/gz-b" | wc -l | tr -d ' ')"
check "bsd: ...and grep -l --null ends them in NUL" "2" \
    "$(bsd grep -l --null -F hit "$T/gz-a" "$T/gz-b" | tr -cd '\0' | wc -c | tr -d ' ')"
want_mtime=$(rp "wv_stat mtime '$T/st'")
for host in native bsd; do
    run_as() { if [ "$host" = bsd ]; then bsd "$@"; else "$@"; fi; }
    check "$host: wv_stat size" "12" "$(run_as rp "wv_stat size '$T/st'")"
    check "$host: wv_stat mtime matches GNU" "$want_mtime" "$(run_as rp "wv_stat mtime '$T/st'")"
    check "$host: wv_stat dev and ino are numbers" "ok" "$(run_as rp "wv_stat dev '$T/st'; wv_stat ino '$T/st'" | grep -cE '^[0-9]+$' | sed 's/^2$/ok/')"
    check "$host: wv_stat on a missing file fails, printing nothing" "|fail" "$(run_as rp "wv_stat mtime '$T/none'")|$(run_as rp "wv_stat mtime '$T/none'" >/dev/null || echo fail)"
    check "$host: wv_now ns is 19+ digits" "ok" "$(grep -qE '^[0-9]{19,}$' <<< "$(run_as rp 'wv_now ns')" && echo ok)"
    check "$host: wv_now ms is 13 digits" "ok" "$(grep -qE '^[0-9]{13}$' <<< "$(run_as rp 'wv_now ms')" && echo ok)"
    check "$host: wv_now us is seconds.microseconds" "ok" "$(grep -qE '^[0-9]{10,}\.[0-9]{6}$' <<< "$(run_as rp 'wv_now us')" && echo ok)"
    check "$host: wv_now sets a caller's variable" "ok" "$(run_as rp 'wv_now ms t; [[ $t =~ ^[0-9]{13}$ ]] && echo ok')"
    check "$host: an ISO Z stamp" "1795255200" "$(run_as rp "wv_date_epoch 2026-11-21T10:00:00Z")"
    check "$host: a zone-less sqlite stamp is UTC" "1795255200" "$(run_as rp "wv_date_epoch '2026-11-21 10:00:00'")"
    check "$host: fractional seconds and +00:00" "1795255200" "$(run_as rp "wv_date_epoch 2026-11-21T10:00:00.5+00:00")"
    check "$host: a bare date" "1795219200" "$(run_as rp "wv_date_epoch 2026-11-21")"
    check "$host: an unreadable stamp fails, never 0" "fail" "$(run_as rp "wv_date_epoch 'two days ago'" || echo fail)"
    check "$host: wv_date_fmt -u" "2026-11-21T10:00:00Z" "$(run_as rp "wv_date_fmt -u 1795255200 +%Y-%m-%dT%H:%M:%SZ")"
done

# wv_bound (wv-ea88cd): Weave's deadline on every host, one perl mechanism,
# timeout(1) or not. Timed with wv_now; each bound is far below the command.
echo "wv-resolve-runtime: wv_bound, a deadline without timeout(1)"
wb() { local t0 t1 out; t0=$(rp 'wv_now ms'); out=$(bash -c ". '$ROOT/scripts/lib/wv-resolve-runtime.sh'; $1; echo \"rc=\$?\"" 2>/dev/null | tail -1); t1=$(rp 'wv_now ms'); printf '%s %s\n' "$out" "$(( t1 - t0 ))"; }
within() { local r ms; read -r r ms <<< "$2"; if [ "$r" = "$1" ] && [ "$ms" -lt "$3" ]; then echo ok; else echo "$r in ${ms}ms"; fi; }
check "wv_bound passes the command's status through" "rc=7" "$(wb "wv_bound 5 sh -c 'exit 7'" | cut -d' ' -f1)"
check "a stalled command ends at the deadline with 124" "ok" "$(within rc=124 "$(wb 'wv_bound 0.5 sleep 6 >/dev/null')" 3000)"
check "a command that ignores TERM is killed a second later" "ok" "$(within rc=124 "$(wb "wv_bound 0.5 sh -c 'trap \"\" TERM; sleep 6' >/dev/null")" 4000)"
check "--group ends a child that holds the caller's pipe" "ok" "$(within rc=124 "$(wb "x=\$(wv_bound --group 0.5 sh -c 'sleep 6 & wait')")" 3000)"
check "a malformed duration is refused with 125, the command never run" "rc=125" "$(wb "wv_bound 5x touch '$T/wb-ran'" | cut -d' ' -f1)$([ -e "$T/wb-ran" ] && echo ' (ran)')"
# The agent-hook stage on a host without timeout(1): what macOS ran unbounded.
# A PATH holding everything on this one but timeout(1), as a Mac has.
NTO="$T/no-timeout-bin"; mkdir -p "$NTO"
IFS=: read -ra _nto_dirs <<< "$PATH"
for _d in "${_nto_dirs[@]}"; do for _f in "$_d"/*; do
    _n=${_f##*/}; [ "$_n" != timeout ] && [ -x "$_f" ] && [ ! -e "$NTO/$_n" ] && ln -s "$_f" "$NTO/$_n" 2>/dev/null
done; done
check "(control) the stripped PATH has no timeout(1)" "absent" "$(PATH="$NTO" command -v timeout >/dev/null 2>&1 && echo present || echo absent)"
check "a stalled agent-hook stage ends at WV_AGENT_HOOK_TIMEOUT, timeout(1) absent" "ok" \
    "$(within rc=124 "$(wb "PATH='$NTO'; . '$ROOT/scripts/lib/wv-pre-tool-use.sh'; WV_AGENT_HOOK_TIMEOUT=1 _agent_hook_run stalled sleep 6")" 4000)"

echo "no regex repetition count above 255 (BSD regcomp RE_DUP_MAX, wv-b2e048)"
# Linux's glibc accepts {256}; macOS refuses it, so only a sweep catches it here.
dup=$(cd "$ROOT" && git ls-files -z -- 'scripts/*.sh' 'tests/*.sh' scripts/wv \
    | xargs -0 grep -HnIE '\{(25[6-9]|2[6-9][0-9]|[3-9][0-9]{2}|[1-9][0-9]{3,})(,[0-9]*)?\}' 2>/dev/null \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | grep -v '^tests/test-lib-guards.sh:')
check "no {n} with n > 255 in tracked scripts and tests" "" "$dup"

echo "no bare timeout(1) in tracked scripts and tests (macOS has none, wv-f8e26d)"
# A suite calling timeout(1) on a Mac exits 127 without running the command;
# wv-412db3's sweep missed two MCP suites. Use wv_bound (scripts) or bounded
# (tests/lib/bounded.sh). wv_bound's own fallback, behind command -v, is exempt.
bare_to=$(cd "$ROOT" && git ls-files -z -- 'scripts/*.sh' 'scripts/hooks/*' 'tests/*.sh' 'tests/lib/*.sh' scripts/wv \
    | xargs -0 grep -HnIE '(^|[[:space:];&|(]|\$\()timeout[[:space:]]+(-[-a-zA-Z0-9]+[[:space:]]+)*["$0-9]' 2>/dev/null \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | grep -v '^tests/test-lib-guards.sh:' \
    | grep -vE '^scripts/lib/wv-resolve-runtime\.sh:[0-9]+:.*timeout (--foreground )?-k 1 "\$secs"')
check "no timeout(1) call outside wv_bound's guarded fallback" "" "$bare_to"

echo "no sqlite3 -readonly or mode=ro CLI open (macOS sqlite3 refuses a WAL file without its -shm, wv-986156)"
# Apple's /usr/bin/sqlite3 (3.51, Mac run 45396551036) returns 'unable to open
# database file (14)' for -readonly and file:...?mode=ro on a WAL database with
# no -shm beside it (a .backup copy); PRAGMA query_only=1 over a mode=rw URI
# reads it and refuses writes on every host. mode=rw, not a plain path: a plain
# path creates an empty database where none exists, which -readonly never did.
# Python's sqlite3 module (its own build) is not swept.
ro_open=$(cd "$ROOT" && git ls-files -z -- 'scripts/*.sh' 'scripts/hooks/*' 'tests/*.sh' 'tests/lib/*.sh' scripts/wv install.sh \
    | xargs -0 grep -HnIE "(^|[^.A-Za-z_])sqlite3 +-readonly\b|(^|[^.A-Za-z_])sqlite3 +[\"']file:[^\"']*mode=ro|ATTACH +DATABASE +[\"']file:[^\"']*mode=ro" 2>/dev/null \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | grep -v '^tests/test-lib-guards.sh:' \
    | grep -v '^tests/macos-probe.sh:')  # the probe reports these forms on purpose
check "no sqlite3 -readonly or mode=ro open in tracked shell" "" "$ro_open"
qo_plain=$(cd "$ROOT" && git ls-files -z -- 'scripts/*.sh' 'scripts/hooks/*' 'tests/*.sh' 'tests/lib/*.sh' scripts/wv install.sh \
    | xargs -0 grep -HnI 'PRAGMA query_only=1' 2>/dev/null | grep -v 'mode=rw' \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | grep -vE '^tests/(test-lib-guards|macos-probe)\.sh:')
check "every query_only open names its database as a mode=rw URI" "" "$qo_plain"
RO="$T/ro-copy"; mkdir -p "$RO"
sqlite3 "$RO/live.db" "PRAGMA journal_mode=WAL; CREATE TABLE t(a); INSERT INTO t VALUES (1),(2);" >/dev/null
sqlite3 "$RO/live.db" ".backup '$RO/copy.db'"
rm -f "$RO/copy.db-wal" "$RO/copy.db-shm"
check "query_only reads a WAL .backup copy with no -shm" "2" "$(sqlite3 -cmd "PRAGMA query_only=1" "file:$RO/copy.db?mode=rw" "SELECT count(*) FROM t;" 2>&1)"
check "...and refuses a write to it" "refused 2" \
    "$(sqlite3 -cmd "PRAGMA query_only=1" "file:$RO/copy.db?mode=rw" "INSERT INTO t VALUES (3);" >/dev/null 2>&1 || echo refused) $(sqlite3 "$RO/copy.db" "SELECT count(*) FROM t;")"
check "...and a missing database is refused, not created" "refused absent" \
    "$(sqlite3 -cmd "PRAGMA query_only=1" "file:$RO/missing.db?mode=rw" "SELECT 1;" >/dev/null 2>&1 || echo refused) $([ -e "$RO/missing.db" ] && echo created || echo absent)"

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
