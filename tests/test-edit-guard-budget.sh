#!/usr/bin/env bash
# test-edit-guard-budget.sh -- the edit guard judges an edit inside its own
# wait budget, below the host's hook limit, and refuses an edit it could not
# judge in time (wv-3a8c06).
#
# The host kills a PreToolUse hook at its limit (10 s as install.sh writes it)
# and a killed guard admits the edit. The guard's wv list and wv context wait
# on whatever holds the graph; the schema lock alone is 10 s per call. Here the
# lock is really held, and a planted wv stalls or fails the context call.
#
# GIT_* is unset first: an exported GIT_DIR would point the scratch
# repositories at the real one (wv-8f1da6).

set -u
while IFS= read -r _v; do unset "$_v"; done < <(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p')
export WV_TEST_SUITE=1
export WV_CALL_SOURCE=test

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REAL_WV="$REPO_ROOT/scripts/wv"
HOOK="$REPO_ROOT/.claude/hooks/pre-action.sh"

T=$(mktemp -d)
HOLDER=""
cleanup() { [ -z "$HOLDER" ] || kill "$HOLDER" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
export WV_CONFIG_DIR="$T/cfg" WV_AGENT_ID="budget-test" WV_REQUIRE_LEARNING=0
export WV_AUTO_CHECKPOINT=0 WV_NONINTERACTIVE=1
mkdir -p "$WV_CONFIG_DIR"

pass=0; run=0
ok()  { echo "  ✓ $1"; pass=$((pass + 1)); run=$((run + 1)); }
bad() { echo "  ✗ $1"; [ -z "${2:-}" ] || echo "$2" | sed 's/^/      /'; run=$((run + 1)); }

# The fixture project carries its own scripts/wv, which the guard prefers: the
# checkout's wv, except that $T/stall saying sleep|fail stalls or fails context.
# It runs that wv as a child, not by exec, so its own path stays in the process
# list: a check for leftovers then sees this suite's calls, not those of suites
# running beside it in the gate.
R="$T/repo"; HZ="$T/hz"
mkdir -p "$R/scripts" "$HZ"; chmod 700 "$HZ"
cat > "$R/scripts/wv" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = context ]; then
    case "\$(cat "$T/stall" 2>/dev/null)" in
        sleep) exec sleep 30 ;;
        fail) exit 1 ;;
    esac
fi
"$REAL_WV" "\$@"
EOF
chmod +x "$R/scripts/wv"
export WV_PROJECT_DIR="$R" WEAVE_DIR="$R/.weave" WV_HOT_ZONE="$HZ"
cd "$R" || exit 1
git init -q && git config user.email t@t && git config user.name t
"$REAL_WV" init >/dev/null 2>&1
ID=$("$REAL_WV" add "budget fixture" --force --criteria=c --risks=low --status=active 2>&1 \
    | sed -nE 's/^✓ (wv-[a-f0-9]{6}): .*/\1/p' | head -1)
[[ "$ID" =~ ^wv-[0-9a-f]{6}$ ]] || { echo "fixture: node not created"; exit 1; }

PAYLOAD=$(jq -cn --arg f "$R/x.txt" '{tool_name:"Edit",tool_input:{file_path:$f,old_string:"a",new_string:"b"}}')
# Nothing remembered: no context stamp, no cached list.
fresh() { rm -rf "$HZ/run_cache" "$HZ"/owners/*/.context_checked_* 2>/dev/null; : > "$T/stall"; }
# guard -- run the hook; sets RC, MS (wall time) and ERR.
guard() {
    local t0 t1
    t0=$(date +%s%N)
    printf '%s' "$PAYLOAD" | bash "$HOOK" > /dev/null 2> "$T/err"
    RC=$?
    t1=$(date +%s%N)
    MS=$(( (t1 - t0) / 1000000 ))
    ERR=$(cat "$T/err")
}
# hold_schema_lock -- hold the migration lock and drop the stamp that lets a
# wv call skip it, as a load or a fresh migration does.
hold_schema_lock() {
    ( exec 9>"$HZ/.schema.lock"; flock -x 9; exec sleep 60 ) &
    HOLDER=$!
    sleep 0.3
    rm -f "$HZ/brain.db.ensured"
}
release() { kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null; HOLDER=""; }

echo "--- uncontended ---"
fresh; guard
if [ "$RC" -eq 0 ]; then ok "a claimed node, nothing holding the graph: admitted (${MS} ms)"
else bad "a claimed node, nothing holding the graph: admitted" "rc=$RC $ERR"; fi

echo "--- the schema lock held (wv list waits on it) ---"
fresh; hold_schema_lock
WV_PTU_WAIT_BUDGET_MS=2000 guard
if [ "$RC" -eq 2 ] && [ "$MS" -ge 1900 ] && [ "$MS" -lt 3500 ]; then
    ok "refused at the 2000 ms budget, not at the lock's 10 s (${MS} ms)"
else bad "refused at the 2000 ms budget" "rc=$RC ms=$MS $ERR"; fi
case "$ERR" in *"could not judge this edit in time: wv list"*) ok "...naming the call that waited" ;;
    *) bad "...naming the call that waited" "$ERR" ;; esac
if pgrep -f "$R/scripts/wv list" >/dev/null 2>&1; then bad "...and no wv list is left waiting" "$(pgrep -fa "$R/scripts/wv list")"
else ok "...and no wv list is left waiting"; fi

fresh; rm -f "$HZ/brain.db.ensured"
unset WV_PTU_WAIT_BUDGET_MS; guard
HOST_LIMIT=$(sed -nE 's/.*pre-action\.sh"\),"timeout":([0-9]+).*/\1/p' "$REPO_ROOT/install.sh")
if [ "$RC" -eq 2 ] && [ -n "$HOST_LIMIT" ] && [ "$MS" -lt $(( (HOST_LIMIT - 1) * 1000 )) ]; then
    ok "the default budget refuses inside the installed host limit of ${HOST_LIMIT} s, with a second to spare (${MS} ms)"
else bad "the default budget refuses inside the installed host limit" "rc=$RC ms=$MS limit=${HOST_LIMIT:-?} $ERR"; fi
release

echo "--- wv context cannot answer ---"
# Only the context call may be slow here. The cases above deleted the
# brain.db.ensured stamp, so the guard's wv list would first re-run the schema
# check (339 ms against 82 ms measured) and, under gate load, spend the budget
# there and name wv list instead (wv-e4b8e2): restore the stamp first.
fresh; "$REAL_WV" status >/dev/null 2>&1
[ -e "$HZ/brain.db.ensured" ] && ok "the schema stamp is back before the context stall" \
    || bad "the schema stamp is back before the context stall" "no $HZ/brain.db.ensured"
echo sleep > "$T/stall"
WV_PTU_WAIT_BUDGET_MS=2000 guard
if [ "$RC" -eq 2 ] && [ "$MS" -lt 3500 ]; then ok "a context call still waiting at the budget: refused (${MS} ms)"
else bad "a context call still waiting at the budget: refused" "rc=$RC ms=$MS $ERR"; fi
case "$ERR" in *"in time: wv context"*) ok "...naming wv context" ;; *) bad "...naming wv context" "$ERR" ;; esac

fresh; echo fail > "$T/stall"; guard
if [ "$RC" -eq 2 ]; then ok "a context call that fails: refused (exit 2), not a host error that admits it"
else bad "a context call that fails: refused (exit 2)" "rc=$RC $ERR"; fi

fresh; guard
if [ "$RC" -eq 0 ]; then ok "the graph answering again: admitted"
else bad "the graph answering again: admitted" "rc=$RC $ERR"; fi

echo "--- without timeout(1) the watchdog bounds the call ---"
# A PATH with every tool but timeout, as on macOS without coreutils.
mkdir -p "$T/bin"
for d in /usr/local/bin /usr/bin /bin; do
    for f in "$d"/*; do
        n=${f##*/}
        [ "$n" != timeout ] && [ ! -e "$T/bin/$n" ] && ln -s "$f" "$T/bin/$n" 2>/dev/null
    done
done
out=$(PATH="$T/bin" WV="$T/slow" WV_PTU_WAIT_BUDGET_MS=1000 bash -c '
    printf "#!/bin/sh\nexec sleep 30\n" > "$WV"; chmod +x "$WV"
    command -v timeout >/dev/null && { echo "timeout still on PATH"; exit 0; }
    source "$1/scripts/lib/wv-hook-common.sh"
    t0=$(date +%s%N); _hc_wv list; rc=$?; t1=$(date +%s%N)
    echo "rc=$rc ms=$(( (t1 - t0) / 1000000 ))"' _ "$REPO_ROOT" 2>&1)
case "$out" in
    rc=124\ ms=*) ms=${out##*ms=}
        if [ "$ms" -lt 2500 ]; then ok "a stalled call ends at the budget with 124 ($out)"
        else bad "a stalled call ends at the budget" "$out"; fi ;;
    *) bad "a stalled call ends at the budget with 124" "$out" ;;
esac

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
