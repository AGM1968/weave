#!/usr/bin/env bash
# wv loads its command modules on first use (wv-13a9ae).
#
# scripts/wv defines a stub for every function a cmd module defines at column
# 0; the first call sources the owning module and re-dispatches. Pinned here:
#   - a command loads only what it reaches (wv list: core, not ops);
#   - output is the same with autoload on and off (WV_AUTOLOAD=0 = eager);
#   - a column-0 "name() {" inside a heredoc cannot shadow a library function
#     (without the guard, a heredoc naming db_ensure breaks every command that
#     touches the database).
set -uo pipefail
export WV_CALL_SOURCE=test

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }

T=$(mktemp -d /tmp/wv-autoload-XXXXXX)
trap 'rm -rf "$T"' EXIT
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_DIR GIT_WORK_TREE WV_AUTOLOAD WV_AUTOLOAD_TRACE
export WV_HOT_ZONE="$T/hot" WV_DB="$T/hot/brain.db" WV_CONFIG_DIR="$T/cfg" WV_PROJECT_DIR="$T/p"
export WV_AUTO_SYNC=0 WV_AUTO_CHECKPOINT=0 WV_REQUIRE_LEARNING=0 WV_RUN_CACHE=0
export WV_SUITE_LOG="$T/suite_runs.jsonl"
mkdir -p "$T/hot" "$T/cfg" "$T/p"
cd "$T/p" || exit 1
git init -q && git -c user.name=a -c user.email=a@a commit -q --allow-empty -m init

# wv from a given lib tree (WV_LIB_DIR: the tree's scripts/)
wvx() { local lib="$1"; shift; WV_LIB_DIR="$lib" bash "$lib/wv" "$@"; }
LIB="$ROOT/scripts"

echo "wv command modules load on first use"
wvx "$LIB" add "autoload probe" --force >/dev/null 2>&1
id=$(wvx "$LIB" list --json 2>/dev/null | jq -r '.[0].id')
check "fixture node exists" "yes" "$([ -n "$id" ] && [ "$id" != null ] && echo yes || echo no)"

loads=$(WV_AUTOLOAD_TRACE=1 wvx "$LIB" list 2>&1 >/dev/null | awk '/^wv autoload:/ {print $3}' | sort -u | paste -sd' ' -)
check "wv list loads the core module and nothing else" "core" "$loads"
eager=$(WV_AUTOLOAD=0 WV_AUTOLOAD_TRACE=1 wvx "$LIB" list 2>&1 >/dev/null | grep -c '^wv autoload:')
check "WV_AUTOLOAD=0 loads every command module up front" \
    "$(find "$LIB/cmd" -maxdepth 1 -name 'wv-cmd-*.sh' | wc -l | tr -d ' ')" "$eager"
# A module added later is loaded eagerly too: the eager set is the same glob
# the stubs come from, not a typed list (ultrareview #4574).
cp -r "$ROOT/scripts" "$T/extra"
printf '_autoload_extra_probe() { :; }\n' > "$T/extra/cmd/wv-cmd-zzextra.sh"
extra_trace=$(WV_AUTOLOAD=0 WV_AUTOLOAD_TRACE=1 wvx "$T/extra" list 2>&1 >/dev/null)
check "WV_AUTOLOAD=0 also loads a module added after the list was written" "yes" \
    "$(grep -q '^wv autoload: zzextra' <<< "$extra_trace" && echo yes || echo no)"

for c in "list --json" "show $id --json" "status --json" "help" "ready --json"; do
    # shellcheck disable=SC2086  # $c is a command line, split on purpose
    a=$(wvx "$LIB" $c 2>&1); b=$(WV_AUTOLOAD=0 wvx "$LIB" $c 2>&1)
    check "wv $c is the same with autoload on and off" "same" "$([ "$a" = "$b" ] && echo same || echo differs)"
done

# A heredoc line naming a library function at column 0, in a copy of the tree.
cp -r "$ROOT/scripts" "$T/scripts"
cat >> "$T/scripts/cmd/wv-cmd-hook.sh" <<'EOF'
_autoload_probe_text() {
    cat <<'TEXT'
db_ensure() {
TEXT
}
EOF
# A fresh hot zone: creating the database is db_ensure's job, so a shadowed
# db_ensure shows as a missing node (an existing database hides it).
shadow=$(
    export WV_HOT_ZONE="$T/hot2" WV_DB="$T/hot2/brain.db"
    mkdir -p "$T/hot2"
    wvx "$T/scripts" add "shadow probe" --force >/dev/null 2>&1
    wvx "$T/scripts" list --json 2>/dev/null | jq -r '.[0].text' 2>/dev/null
)
check "a heredoc line naming db_ensure does not shadow it" "shadow probe" "$shadow"

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
