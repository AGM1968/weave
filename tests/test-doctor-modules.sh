#!/usr/bin/env bash
# wv doctor's module checks derive what an install needs (wv-587469).
#
# They used to verify typed lists -- 12 libraries and 5 of the 10 command
# modules -- so a missing findings/analyze/indexer/query/hook module,
# wv-gate-pool.sh or wv-checkpoint-ci.sh passed doctor. Now:
#   lib modules  every library a component names must be in lib/;
#   cmd modules  every cmd_* the dispatcher calls must be defined somewhere.
# Driven against a copy of scripts/ with parts removed or added.
set -uo pipefail
export WV_CALL_SOURCE=test

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }
has()   { if grep -qF -- "$3" <<< "$2"; then ok "$1"; else bad "$1" "missing [$3] in: $2"; fi; }

T=$(mktemp -d /tmp/wv-doctor-modules-XXXXXX)
trap 'rm -rf "$T"' EXIT
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
export WV_HOT_ZONE="$T/hot" WV_DB="$T/hot/brain.db" WV_CONFIG_DIR="$T/cfg" WV_PROJECT_DIR="$T/p"
export WV_AUTO_SYNC=0 WV_AUTO_CHECKPOINT=0 WV_SUITE_LOG="$T/s.jsonl"
mkdir -p "$T/hot" "$T/cfg" "$T/p"
cd "$T/p" && git init -q && git -c user.name=a -c user.email=a@a commit -q --allow-empty -m init

fresh_tree() { rm -rf "$T/scripts"; cp -r "$ROOT/scripts" "$T/scripts"; }
# check_of <name> — "status|detail" of one doctor check, from the tree at $T/scripts.
check_of() {
    WV_LIB_DIR="$T/scripts" bash "$T/scripts/wv" doctor --json 2>/dev/null \
        | jq -r --arg c "$1" '.checks[] | select(.check == $c) | "\(.status)|\(.detail)"'
}

echo "wv doctor derives the module set"
fresh_tree
check "lib modules pass on a complete tree" "pass" "$(check_of 'lib modules' | cut -d'|' -f1)"
check "cmd modules pass on a complete tree" "pass" "$(check_of 'cmd modules' | cut -d'|' -f1)"

rm "$T/scripts/lib/wv-gate-pool.sh"
r=$(check_of 'lib modules')
check "a missing library something loads fails lib modules" "fail" "${r%%|*}"
has "...naming it" "$r" "missing: wv-gate-pool.sh"

fresh_tree
rm "$T/scripts/cmd/wv-cmd-findings.sh"
r=$(check_of 'cmd modules')
check "a missing command module fails cmd modules" "fail" "${r%%|*}"
has "...naming the commands it defined" "$r" "cmd_findings"

fresh_tree
printf 'cmd_zz_probe() { :; }\n' > "$T/scripts/cmd/wv-cmd-zzprobe.sh"
check "an added module changes nothing: no typed list to update" "pass|pass" \
    "$(check_of 'lib modules' | cut -d'|' -f1)|$(check_of 'cmd modules' | cut -d'|' -f1)"

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
