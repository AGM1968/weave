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
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
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

# wv-56fca6: the commit gate runs config, test-record and test-status, which
# live in wv-cmd-gate.sh, an invoking file; wv-cmd-ops.sh is not reached by
# the gate, so an edit to doctor or bootstrap code cannot change what it runs.
for c in "config get WV_CALL_LOG" "test-status --inputs --suites=tests/none.sh" \
         "test-record tests/none.sh --exit=0 --duration=1"; do
    # shellcheck disable=SC2086  # $c is a command line, split on purpose
    loads=$(WV_AUTOLOAD_TRACE=1 wvx "$LIB" $c 2>&1 >/dev/null | awk '/^wv autoload:/ {print $3}' | sort -u | paste -sd' ' -)
    check "wv ${c%% *} loads the gate module and never ops" "gate yes, ops no" \
        "gate $([[ " $loads " == *" gate "* ]] && echo yes || echo no), ops $([[ " $loads " == *" ops "* ]] && echo yes || echo no)"
done

# scripts/wv's autoload relies on no function being defined in two command
# modules (load order would then decide which definition wins); this holds it.
dups=$(cd "$LIB/cmd" && grep -hoE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' wv-cmd-*.sh | sort | uniq -d | paste -sd' ' -)
check "no function is defined at column 0 in two command modules" "" "$dups"
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

# wv-c153c4: load and done loaded all of wv-cmd-ops.sh for six shared helpers,
# and hotzone lived there, so every suite running them was routed from ops.
# The helpers moved to their callers' modules (python helpers to their own),
# hotzone to its own; each command loads what it uses and never ops. Last,
# because done closes the fixture node the checks above read.
loads_of() {  # loads_of <wv args...>: the command modules one call loads
    WV_AUTOLOAD_TRACE=1 wvx "$LIB" "$@" 2>&1 >/dev/null | awk '/^wv autoload:/ {print $3}' | sort -u | paste -sd' ' -
}
has() { [[ " $1 " == *" $2 "* ]] && echo yes || echo no; }
l=$(loads_of load); check "wv load loads data and never ops" "data yes, ops no" "data $(has "$l" data), ops $(has "$l" ops)"
l=$(loads_of hotzone list); check "wv hotzone loads hotzone and never ops" "hotzone yes, ops no" "hotzone $(has "$l" hotzone), ops $(has "$l" ops)"
l=$(loads_of quality functions "$LIB/wv"); check "a Python-backed command loads python and never ops" "python yes, ops no" "python $(has "$l" python), ops $(has "$l" ops)"
# init (every suite's fixture) reached ops through cmd_recover, status through
# _detect_git_pending; both moved out with what they call (wv-c153c4 round 3).
l=$(loads_of status); check "wv status never loads ops" "ops no" "ops $(has "$l" ops)"
l=$(loads_of recover --auto); check "wv recover loads recover and never ops" "recover yes, ops no" "recover $(has "$l" recover), ops $(has "$l" ops)"
l=$(cd "$T" && mkdir -p fresh && cd fresh && git init -q && WV_HOT_ZONE="$T/hot3" WV_DB="$T/hot3/brain.db" loads_of init)
check "wv init never loads ops" "ops no" "ops $(has "$l" ops)"
# wv-fc71f0: repository-owned procedures route only to the suites that create
# them, which holds only while a repository without any never loads the module.
l=$(cd "$T/fresh" && WV_HOT_ZONE="$T/hot3" WV_DB="$T/hot3/brain.db" loads_of guide --procedure=rules)
check "wv guide without repository procedures never loads procedures" "procedures no" "procedures $(has "$l" procedures)"
l=$(cd "$T/fresh" && WV_HOT_ZONE="$T/hot3" WV_DB="$T/hot3/brain.db" loads_of doctor)
check "wv doctor without repository procedures never loads procedures" "procedures no" "procedures $(has "$l" procedures)"
mkdir -p "$T/fresh/.weave/procedures" && touch "$T/fresh/.weave/procedures/x.md"
l=$(cd "$T/fresh" && WV_HOT_ZONE="$T/hot3" WV_DB="$T/hot3/brain.db" loads_of doctor)
check "control: wv doctor with a repository procedure loads procedures" "procedures yes" "procedures $(has "$l" procedures)"
rm -rf "$T/fresh/.weave/procedures"
# wv-a8f91e, wv-986c3d: wv-cmd-graduate.sh routes only to the suites that run
# it, which holds only while review loads it for a graduate verdict alone and
# doctor only over a graph holding an active memory.
l=$(cd "$T/fresh" && WV_HOT_ZONE="$T/hot3" WV_DB="$T/hot3/brain.db" loads_of doctor)
check "wv doctor without an active memory never loads graduate" "graduate no" "graduate $(has "$l" graduate)"
mid=$(cd "$T/fresh" && WV_HOT_ZONE="$T/hot3" WV_DB="$T/hot3/brain.db" wvx "$LIB" remember "autoload probe" --json 2>/dev/null | jq -r '.id')
l=$(cd "$T/fresh" && WV_HOT_ZONE="$T/hot3" WV_DB="$T/hot3/brain.db" loads_of memory review --apply)
check "wv memory review --apply without a graduate verdict never loads graduate" "graduate no" "graduate $(has "$l" graduate)"
l=$(cd "$T/fresh" && WV_HOT_ZONE="$T/hot3" WV_DB="$T/hot3/brain.db" loads_of memory review "$mid" --verdict=graduate --reason=probe --target=missing.md)
check "control: a graduate verdict loads graduate" "graduate yes" "graduate $(has "$l" graduate)"
l=$(cd "$T/fresh" && WV_HOT_ZONE="$T/hot3" WV_DB="$T/hot3/brain.db" loads_of doctor)
check "control: wv doctor over an active memory loads graduate" "graduate yes" "graduate $(has "$l" graduate)"
# done calls score_learning and validate_on_done with stderr discarded, so the
# trace cannot see a load they cause; hold where each moved function lives.
owner() { (cd "$LIB/cmd" && grep -lE "^$1\(\)" wv-cmd-*.sh | paste -sd' ' -); }
for pair in validate_on_done:wv-cmd-core.sh score_learning:wv-cmd-core.sh \
            _save_session_snapshot:wv-cmd-data.sh cmd_hotzone:wv-cmd-hotzone.sh \
            _bootstrap_python_command:wv-cmd-python.sh _wv_python_module_path:wv-cmd-python.sh \
            _wv_agent_python_exec_module:wv-cmd-python.sh \
            cmd_recover:wv-cmd-recover.sh _recover_run:wv-cmd-recover.sh _recover_ship:wv-cmd-recover.sh \
            _recover_sync:wv-cmd-recover.sh _recover_delete:wv-cmd-recover.sh _recover_session:wv-cmd-recover.sh \
            _detect_git_pending:wv-cmd-gitstate.sh _git_pending_hint:wv-cmd-gitstate.sh \
            _git_commit_weave_ownership:wv-cmd-gitstate.sh _git_status_has_outside_weave_changes:wv-cmd-gitstate.sh \
            _wv_repo_procedure_file:wv-cmd-procedures.sh _doctor_repo_procedures:wv-cmd-procedures.sh \
            _memory_graduate_target:wv-cmd-graduate.sh _doctor_memory_budget:wv-cmd-graduate.sh; do
    check "${pair%%:*} is defined in ${pair#*:}, not wv-cmd-ops.sh" "${pair#*:}" "$(owner "${pair%%:*}")"
done

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
