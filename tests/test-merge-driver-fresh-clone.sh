#!/usr/bin/env bash
# A fresh clone without the merge drivers .gitattributes names is reported, and
# one command repairs it (wv-d24a69). git config is not cloned: .gitattributes
# routes .weave/state.sql, nodes.jsonl and edges.jsonl to merge=ours, and a
# fresh clone's first rebase over another clone's graph commit stopped on them.
# This suite clones a bare origin twice, makes concurrent graph commits, shows
# the rebase conflicting without the drivers, wv doctor and wv bootstrap naming
# them with one generated git config line, and the same rebase clean after
# running that line exactly as printed; wv doctor --repair also registers them
# in an owned repository.
export WV_CALL_SOURCE=test
set -uo pipefail
export WV_TEST_SUITE=1
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WV="$PROJECT_ROOT/scripts/wv"
run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
TMP=$(cd "$(mktemp -d /tmp/wv-merge-driver-XXXXXX)" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
# A scratch repository must not inherit the outer one (wv-8f1da6).
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
gitc() { git -c user.email=t@t -c user.name=t -c commit.gpgsign=false "$@"; }

echo "=== merge drivers in a fresh clone (wv-d24a69) ==="

# Origin: Weave's own .gitattributes block and a graph snapshot.
SEED="$TMP/seed"; mkdir -p "$SEED/.weave"
git -C "$SEED" init -q -b main
sed -n '/BEGIN WEAVE GITATTRIBUTES/,/END WEAVE GITATTRIBUTES/p' "$PROJECT_ROOT/.gitattributes" > "$SEED/.gitattributes"
printf 'node-a base\nnode-b base\n' > "$SEED/.weave/nodes.jsonl"
printf -- '-- state base\n' > "$SEED/.weave/state.sql"
gitc -C "$SEED" add -A && gitc -C "$SEED" commit -q -m seed
git clone -q --bare "$SEED" "$TMP/origin.git"

clone() { git clone -q "$TMP/origin.git" "$TMP/$1"; }
graph_commit() {  # graph_commit <clone> <label>: both graph files changed on the same lines
    printf 'node-a %s\nnode-b %s\n' "$2" "$2" > "$TMP/$1/.weave/nodes.jsonl"
    printf -- '-- state %s\n' "$2" > "$TMP/$1/.weave/state.sql"
    gitc -C "$TMP/$1" commit -q -am "graph $2"
}
in_clone() {  # in_clone <clone> <cmd...>: an isolated wv in that clone
    ( cd "$TMP/$1" && WV_HOT_ZONE="$TMP/hz-$1" WV_DB="$TMP/hz-$1/brain.db" WV_CONFIG_DIR="$TMP/cfg-$1" "${@:2}" )
}

# Control: without the drivers, a rebase over the other clone's graph commit conflicts.
clone a; clone b
graph_commit a from-a; git -C "$TMP/a" push -q origin main
graph_commit b from-b
if gitc -C "$TMP/b" pull -q --rebase origin main >/dev/null 2>&1; then
    bad "without the drivers a rebase over another clone's graph commit conflicts (control)"
else
    ok "without the drivers a rebase over another clone's graph commit conflicts (control)"
fi
git -C "$TMP/b" rebase --abort >/dev/null 2>&1

# A fresh clone is reported by wv doctor and wv bootstrap, with one line.
clone c
mkdir -p "$TMP/hz-c" "$TMP/cfg-c"
out=$(in_clone c "$WV" doctor --json 2>/dev/null)
got=$(jq -r '.checks[] | select(.check == "merge drivers") | "\(.status)|\(.detail)"' <<< "$out" 2>/dev/null)
[[ "$got" == warn\|*"ours, theirs, wv-trails"*"Fix: git config merge.ours.driver 'true' && "* ]] \
    && ok "wv doctor names every unregistered driver and the git config line" \
    || bad "wv doctor names every unregistered driver and the git config line" "$got"
out=$(in_clone c "$WV" bootstrap --json 2>/dev/null)
advisory=$(jq -r '.readiness.advisories[] | select(startswith("git merge drivers not registered"))' <<< "$out" 2>/dev/null)
[[ "$advisory" == *"ours, theirs, wv-trails"*"run: git config merge.ours.driver"* ]] \
    && ok "wv bootstrap readiness names the drivers and the same line" \
    || bad "wv bootstrap readiness names the drivers and the same line" "$(r=$(jq -c '.readiness' <<< "$out" 2>/dev/null); printf '%s' "${r:0:400}")"
fix_doctor=$(jq -r '.checks[] | select(.check == "merge drivers") | .detail | sub("^.*Fix: "; "")' <<< "$(in_clone c "$WV" doctor --json 2>/dev/null)")
fix_boot=${advisory##*run: }
[ -n "$fix_boot" ] && [ "$fix_boot" = "$fix_doctor" ] \
    && ok "doctor and bootstrap print the identical remedy" || bad "doctor and bootstrap print the identical remedy" "doctor=[$fix_doctor] boot=[$fix_boot]"

# The remedy, run exactly as printed: one line, no install, no wv write.
( cd "$TMP/c" && bash -c "$fix_boot" ) \
    && ok "the printed line runs as printed" || bad "the printed line runs as printed" "$fix_boot"
[ -z "$( (cd "$TMP/c" && . "$PROJECT_ROOT/scripts/lib/wv-git-hook-signature.sh" && wv_unregistered_merge_drivers .) )" ] \
    && ok "after the line every driver .gitattributes names is registered" \
    || bad "after the line every driver .gitattributes names is registered"
# A concurrent graph commit lands on origin after c was cloned, as in the
# canary, so c's rebase has the same conflict the control hit.
gitc -C "$TMP/a" pull -q --rebase origin main >/dev/null 2>&1
graph_commit a from-a-again; git -C "$TMP/a" push -q origin main
graph_commit c from-c
if gitc -C "$TMP/c" pull -q --rebase origin main >/dev/null 2>&1; then
    ok "after the line the rebase over another clone's graph commit is clean"
else
    bad "after the line the rebase over another clone's graph commit is clean" "$(git -C "$TMP/c" status --short | tr '\n' ' ')"
fi
got=$(in_clone c "$WV" bootstrap --json 2>/dev/null | jq -r '[.readiness.advisories[] | select(startswith("git merge drivers"))] | length' 2>/dev/null)
[ "$got" = 0 ] && ok "bootstrap no longer reports the drivers" || bad "bootstrap no longer reports the drivers" "count=$got"

# In a repository classified owned, wv doctor --repair registers them too.
clone d
mkdir -p "$TMP/hz-d" "$TMP/cfg-d"
# A remote-bearing clone is classified owned only with an explicit
# acknowledgement; that classification is the operator's, not the fix's.
in_clone d "$WV" repo-class set owned --acknowledge-upstream-fork >/dev/null 2>&1
got=$(in_clone d "$WV" doctor --repair --json 2>/dev/null | jq -r '.checks[] | select(.check == "merge drivers") | "\(.status)|\(.detail)"' 2>/dev/null)
[ "$got" = "pass|repaired: registered ours, theirs, wv-trails" ] \
    && ok "wv doctor --repair registers them in an owned repository" || bad "wv doctor --repair registers them in an owned repository" "$got"

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
