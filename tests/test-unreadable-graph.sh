#!/usr/bin/env bash
# A command that cannot read the graph must not report one (wv-90083c).
#
# wv status printed "Work:  active,  ready,  blocked." and exited 0 when the
# hot-zone database could not be opened, and --json printed zeros: an empty
# graph, reported as fact. The cause was the caller, not the read: local
# x=$(db_query ...) masks the substitution's status, and db_query ... 2>/dev/null
# || echo 0 turns a failure into a count. health said 100/100 healthy; digest,
# learnings, audit-pitfalls, pending-close, prune, tree, overview, search and
# memory recall reported nothing to report.
#
# Held for every command, not a list: each operation in
# contracts/command-capabilities.json runs against a repository whose hot zone
# cannot be created. db_ensure records each failure (WV_TEST_DB_ENSURE_LOG), so
# a command that touched the graph is known whether or not it silenced the
# message, and such a command must exit nonzero. A command that never reads the
# graph is free to succeed.
set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
export WV_CALL_SOURCE=test

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$ROOT/scripts/wv"

run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }

T=$(mktemp -d /tmp/wv-unreadable-XXXXXX)
trap 'rm -rf "$T"' EXIT
unset GIT_DIR GIT_WORK_TREE WV_HOT_ZONE WV_DB
REPO="$T/repo"
mkdir -p "$REPO" "$T/cfg" "$T/hot"
cd "$REPO" || exit 1
git init -q && git -c user.name=a -c user.email=a@a commit -q --allow-empty -m init
# A real graph on disk (.weave/state.sql, which db_ensure loads from), so
# "nothing to report" can only mean "could not read".
env WV_HOT_ZONE="$T/hot" WV_DB="$T/hot/brain.db" WV_PROJECT_DIR="$REPO" WV_CONFIG_DIR="$T/cfg" \
    WV_AUTO_SYNC=0 WV_AUTO_CHECKPOINT=0 bash -c '"$1" init >/dev/null 2>&1; "$1" add "a node" --standalone >/dev/null 2>&1; "$1" sync >/dev/null 2>&1' _ "$WV"
[ -s "$REPO/.weave/state.sql" ] && ok "fixture: the graph is on disk" || bad "fixture: the graph is on disk"

LOG="$T/db-ensure.log"
unreadable() {  # unreadable <wv args...>: run against a hot zone that cannot be created
    env WV_TEST_MODE=1 WV_TEST_HOT_ZONE_ROOT="$T/no/such/root" WV_TEST_DB_ENSURE_LOG="$LOG" \
        WV_PROJECT_DIR="$REPO" WV_CONFIG_DIR="$T/cfg" WV_AUTO_SYNC=0 WV_AUTO_CHECKPOINT=0 \
        timeout 60 "$WV" "$@" </dev/null >"$T/out" 2>"$T/err"
}

echo "a command that cannot read the graph does not report one"

# Control: the same repository, readable, reports its node and exits 0.
readable=$(env WV_HOT_ZONE="$T/hot" WV_DB="$T/hot/brain.db" WV_PROJECT_DIR="$REPO" WV_CONFIG_DIR="$T/cfg" \
    "$WV" status --json 2>/dev/null | jq -r '.ready // empty')
[ "${readable:-0}" -ge 1 ] && ok "control: a readable graph reports its node" \
    || bad "control: a readable graph reports its node" "status --json ready=[$readable]"

# Every registered operation bare, plus the forms that need an argument to
# reach their read. Skipped: commands that rewrite or reinstall the
# environment itself rather than report on it.
skip=" init load sync hook self-update uninstall init-repo bootstrap-agent cutover selftest recover "
mapfile -t ops < <(jq -r '.commands[].operation' "$ROOT/contracts/command-capabilities.json" | sort -u)
lines=()
for op in "${ops[@]}"; do [[ "$skip" == *" $op "* ]] || lines+=("$op"); done
lines+=("status --json" "search foo" "memory recall --json" "learnings --json")

touched=0; offenders=()
for line in "${lines[@]}"; do
    : > "$LOG"
    rc=0
    # shellcheck disable=SC2086  # a command line, split on purpose
    unreadable $line || rc=$?
    [ -s "$LOG" ] || continue
    touched=$((touched+1))
    [ "$rc" -ne 0 ] || offenders+=("wv $line -> exit 0: $(head -c 80 "$T/out" | tr '\n' ' ')")
done

# Non-vacuity: the hook must actually fire, or every command passes unseen.
[ "$touched" -ge 10 ] && ok "the graph-read hook saw $touched of ${#lines[@]} commands touch the graph" \
    || bad "the graph-read hook saw at least 10 commands touch the graph" "saw $touched"
if [ "${#offenders[@]}" -eq 0 ]; then
    ok "every command that touched the unreadable graph exited nonzero"
else
    bad "every command that touched the unreadable graph exited nonzero" "$(printf '%s\n      ' "${offenders[@]}")"
fi

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
