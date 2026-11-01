#!/usr/bin/env bash
# "done" is an argument to the wv helpers below, never the loop keyword.
# shellcheck disable=SC1010
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# Host-hook policy cells (wv-664b7f). A host hook decides before wv runs, so it
# leaves no wv call and no attempt-journal row (wv-bd3041). Its evidence is a
# hook observation (scripts/lib/wv-hook-observe.sh), written when
# WV_HOOK_OBSERVATIONS names a path: the contract rule, the decision, any bypass,
# and no call identity. This suite drives every host_hook rule cell with a real
# hook invocation and asserts on the observations that invocation appended, and
# on the hook's own verdict (exit status or deny JSON), so a rule that is named
# but no longer enforced fails here too.
set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WV="$ROOT/scripts/wv"
HOOKS="$ROOT/.claude/hooks"
run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
TMP=$(cd "$(mktemp -d /tmp/wv-policy-hooks-XXXXXX)" && pwd -P)
P="$TMP/project"
LOCKS="/tmp/weave-bash-locks-$(id -u)/$(echo "$P" | md5sum | cut -c1-8)"
trap 'rm -rf "$TMP" "$LOCKS"' EXIT
# POLICY_HOOKS_OBSERVATIONS keeps the observations past this suite's exit, for
# the totality check.
export WV_HOOK_OBSERVATIONS="${POLICY_HOOKS_OBSERVATIONS:-$TMP/observations.jsonl}"
: > "$WV_HOOK_OBSERVATIONS"
export WV_HOT_ZONE="$TMP/hot" WV_DB="$TMP/hot/brain.db" WV_CONFIG_DIR="$TMP/config"
export CLAUDE_PROJECT_DIR="$P" WV_PROJECT_DIR="$P"
export WV_REQUIRE_LEARNING=0 WV_REQUIRE_QUALITY=0
mkdir -p "$P/src" "$WV_HOT_ZONE" "$WV_CONFIG_DIR"
cd "$P" || exit 1
git init -q . && git config user.email t@t && git config user.name t && git config commit.gpgsign false
"$WV" init >/dev/null 2>&1
echo "print('ok')" > src/app.py
git add -A && git commit -q -m "initial"
first_id() {  # first_id <text> -> the first node id in it (no early-exit pipe under pipefail)
    [[ "$1" =~ wv-[a-f0-9]{4,6} ]] && printf '%s\n' "${BASH_REMATCH[0]}"
}
epic=$(first_id "$("$WV" add "hooks epic" --metadata='{"type":"epic"}' --force 2>/dev/null)")

node() {  # node <text> [wv add args...] -> id
    first_id "$("$WV" add "$1" --parent="$epic" "${@:2}" 2>/dev/null)"
}
claim() {  # claim <id> — the only active node from here on
    local other
    for other in $("$WV" list --status=active --json 2>/dev/null | jq -r '.[].id'); do
        [ "$other" = "$1" ] || "$WV" update "$other" --status=todo >/dev/null 2>&1
    done
    "$WV" work "$1" >/dev/null 2>&1
    rm -f "$WV_HOT_ZONE"/.context_checked_* "$WV_HOT_ZONE/.session_epoch" "$WV_HOT_ZONE/.session_phase"
}
edit_of() { jq -cn --arg p "$1" '{tool_name:"Edit",tool_input:{file_path:$p,old_string:"a",new_string:"b"}}'; }
bash_of() { jq -cn --arg c "$1" --arg cwd "$P" '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}'; }

# hookcell <label> <rule> <decision> <bypass|-> <expect: exit2|deny|block|pass> <hook> <payload>
# The invocation must append an observation for <rule> with that decision and
# bypass, carrying no call identity, and the hook itself must decide as expected.
hookcell() {
    local label="$1" rule="$2" decision="$3" bypass="$4" expect="$5" hook="$6" payload="$7" before rc
    before=$(wc -l < "$WV_HOOK_OBSERVATIONS")
    printf '%s' "$payload" | bash "$HOOKS/$hook" > "$TMP/hook.out" 2> "$TMP/hook.err"
    rc=$?
    local decided=false
    case "$expect" in
        exit2) [ "$rc" = 2 ] && decided=true ;;
        deny)  [ "$rc" = 0 ] && jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$TMP/hook.out" >/dev/null 2>&1 && decided=true ;;
        # A Stop block is the JSON with exit 0, the shape both hosts honour (wv-25903d).
        block) [ "$rc" = 0 ] && jq -e '.decision == "block"' "$TMP/hook.out" >/dev/null 2>&1 && decided=true ;;
        pass)  [ "$rc" = 0 ] && ! grep -q '"deny"' "$TMP/hook.out" && decided=true ;;
    esac
    if ! $decided; then
        bad "$label" "hook did not decide $expect (rc=$rc): $(head -c 300 "$TMP/hook.out" "$TMP/hook.err" | tr '\n' ' ')"
        return
    fi
    if tail -n +"$((before + 1))" "$WV_HOOK_OBSERVATIONS" | jq -se --arg r "$rule" --arg d "$decision" --arg b "$bypass" '
        any(.[]; .event == "hook_decision" and .rule == $r and .decision == $d
            and ((.bypass // "-") == $b)
            and (has("call_id") or has("parent_call_id") | not))' >/dev/null; then
        ok "$label"
    else
        bad "$label" "observed: $(tail -n +"$((before + 1))" "$WV_HOOK_OBSERVATIONS" | jq -c '[.rule,.decision,.bypass]' | tr '\n' ' ')"
    fi
}

echo "=== pre-action guards ==="
seq 1 600 > "$P/src/big.txt"
hookcell "reading a large file whole is denied" read_size_budget deny - deny pre-action.sh \
    "$(jq -cn --arg p "$P/src/big.txt" '{tool_name:"Read",tool_input:{file_path:$p}}')"
hookcell "editing the installed copy is denied" edit_source_not_installed_copy deny - exit2 pre-action.sh \
    "$(edit_of "$HOME/.local/bin/wv")"
hookcell "editing with no active node is denied" edit_requires_active_node deny - exit2 pre-action.sh \
    "$(edit_of "$P/src/app.py")"
work=$(node "hook edit probe" --criteria="c1" --risks=low)
claim "$work"
printf '%s' discover > "$WV_HOT_ZONE/.session_phase"
hookcell "editing in the discover phase is denied" edit_blocked_in_phase deny - exit2 pre-action.sh \
    "$(edit_of "$P/src/app.py")"
rm -f "$WV_HOT_ZONE/.session_phase"
echo $(( $(date +%s) + 3600 )) > "$WV_HOT_ZONE/.session_epoch"
hookcell "editing under a node from an earlier session is denied" active_node_not_stale deny - exit2 pre-action.sh \
    "$(edit_of "$P/src/app.py")"
rm -f "$WV_HOT_ZONE/.session_epoch"
rival=$(node "hook contradiction rival")
sqlite3 "$WV_DB" "INSERT INTO edges(source,target,type,weight,created_at) VALUES('$work','$rival','contradicts',1.0,CURRENT_TIMESTAMP);"
hookcell "editing under an unresolved contradiction is denied" active_node_contradictions_resolved deny - exit2 pre-action.sh \
    "$(edit_of "$P/src/app.py")"
sqlite3 "$WV_DB" "DELETE FROM edges WHERE type='contradicts';"
blocker=$(node "hook blocker")
sqlite3 "$WV_DB" "INSERT INTO edges(source,target,type,weight,created_at) VALUES('$blocker','$work','blocks',1.0,CURRENT_TIMESTAMP);"
rm -f "$WV_HOT_ZONE"/.context_checked_*
hookcell "editing a node with an open blocker is denied" active_node_not_blocked deny - exit2 pre-action.sh \
    "$(edit_of "$P/src/app.py")"
sqlite3 "$WV_DB" "DELETE FROM edges WHERE type='blocks';"

echo "=== claim preflight ==="
bare=$(node "hook claim probe")
for cell in "claim_requires_done_criteria deny" "claim_requires_alias deny" "claim_premortem_advisory advisory"; do
    set -- $cell
    hookcell "a claim without $1 records $2" "$1" "$2" - deny pre-claim-skills.sh "$(bash_of "wv work $bare")"
done
# The advisory alone records advisory and lets the claim through (wv-6e4798).
advised=$(node "hook claim advisory probe" --alias=claim-advised --criteria="c1")
hookcell "a claim missing only risks records advisory and is not denied" claim_premortem_advisory advisory - pass \
    pre-claim-skills.sh "$(bash_of "wv work $advised")"

echo "=== close preflight ==="
finding=$(node "hook finding probe" --metadata='{"type":"finding"}')
hookcell "closing a finding without a violation type is denied" finding_close_requires_violation_type deny - deny \
    pre-close-verification.sh "$(bash_of "wv done $finding")"
dirty=$(node "hook dirty probe")
echo "uncommitted" > "$P/src/dirty.py"
hookcell "closing with uncommitted work is denied" close_requires_committed_work deny - deny \
    pre-close-verification.sh "$(bash_of "wv done $dirty")"
rm -f "$P/src/dirty.py" "$P/src/big.txt"
hookcell "closing with no attributed commit is denied" close_requires_attributed_commit deny - deny \
    pre-close-verification.sh "$(bash_of "wv done $dirty")"
committed=$(node "hook verification probe" --metadata='{"commit":"0000000"}')
hookcell "closing with no verification evidence is denied" close_requires_verification_evidence deny - deny \
    pre-close-verification.sh "$(bash_of "wv done $committed")"
hookcell "--skip-verification records the evidence override" close_requires_verification_evidence allow --skip-verification pass \
    pre-close-verification.sh "$(bash_of "wv done $committed --skip-verification")"

echo "=== bash dedup ==="
rm -rf "$LOCKS"
printf '%s' "$(bash_of "make check")" | bash "$HOOKS/bash-dedup.sh" >/dev/null 2>&1
hookcell "re-issuing an in-flight command is denied" no_duplicate_inflight_command deny - deny \
    bash-dedup.sh "$(bash_of "make check")"
printf '%s\nrunning\nmake check\n\n' "$(date +%s)" > "$LOCKS/make-build.lock"
hookcell "busy-waiting on a live background task is denied" no_busy_wait_polling deny - deny \
    bash-dedup.sh "$(bash_of "until false; do sleep 1; done")"
rm -rf "$LOCKS"

echo "=== session end ==="
claim "$work"
"$WV" sync >/dev/null 2>&1
git add -A >/dev/null 2>&1 && git commit -q -m "graph state" >/dev/null 2>&1
rm -f "$WV_HOT_ZONE/.stop_check_lock"
if [ -z "$(git status --porcelain)" ]; then
    hookcell "ending the session with an active node is blocked" session_end_requires_no_active_node deny - block \
        stop-check.sh '{"stop_hook_active":false}'
    jq -se 'map(select(.rule=="session_end_requires_no_active_node")) | last | .hook_event == "Stop"' \
        "$WV_HOOK_OBSERVATIONS" >/dev/null && ok "a Stop decision is observed as a Stop event" ||
        bad "a Stop decision is observed as a Stop event"
else
    bad "the tree is clean before the stop check" "$(git status --porcelain | sed -n '1,3p')"
fi

echo "=== observations are hook evidence, never wv call rows ==="
if python3 - "$WV_HOOK_OBSERVATIONS" "$ROOT" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[2] + "/scripts")
from weave_registry import apply_schema, load
schema = load(__import__("pathlib").Path(sys.argv[2]) / "contracts/hook-observation-v1.schema.json")
bad = 0
for line in open(sys.argv[1]):
    errors = []
    apply_schema(json.loads(line), schema, schema, "$", errors)
    bad += bool(errors)
sys.exit(1 if bad else 0)
PY
then ok "all $(wc -l < "$WV_HOOK_OBSERVATIONS") observations validate against the hook-observation schema"
else bad "all observations validate against the hook-observation schema"; fi
unset WV_HOOK_OBSERVATIONS
before=$(find "$TMP" -name '*.jsonl' -newer "$P/src/app.py" | wc -l)
printf '%s' "$(edit_of "$HOME/.local/bin/wv")" | bash "$HOOKS/pre-action.sh" >/dev/null 2>&1
[ "$(find "$TMP" -name '*.jsonl' -newer "$P/src/app.py" | wc -l)" = "$before" ] &&
    ok "with WV_HOOK_OBSERVATIONS unset a hook writes nothing" ||
    bad "with WV_HOOK_OBSERVATIONS unset a hook writes nothing"

echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
