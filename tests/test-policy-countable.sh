#!/usr/bin/env bash
# "done" is an argument to the wv helpers below, never the loop keyword.
# shellcheck disable=SC1010
# A clean call is countable (wv-15422b). call_completed.policy.countable is true
# only when every rule the policy contract applies to the call's operation
# recorded a durable verdict, in evidence mode. Gates used to speak only when
# they denied, were bypassed or advised, so a clean call left most applicable
# rules silent and was never countable. Each gate now records its allow when it
# examined the call and let it through, and this suite drives one clean call
# through every mutation-class operation that has applicable rules.
set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
TMP=$(mktemp -d /tmp/wv-policy-countable-XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# setup_repo <dir> <wv> — a fresh owned repository with an initialised graph
setup_repo() {
    mkdir -p "$1/cfg"
    git -C "$1" init -q . && git -C "$1" config user.email t@t && git -C "$1" config user.name t
    (cd "$1" && WEAVE_DIR="$1/.weave" WV_HOT_ZONE="$1/hot" WV_CONFIG_DIR="$1/cfg" "$2" init) </dev/null >/dev/null 2>&1
}
R="$TMP/repo"; J="$TMP/journal.jsonl"; WV="$ROOT/scripts/wv"
setup_repo "$R" "$WV"
: > "$J"
# w <wv args...> — an ordinary (unjournaled) call in the repository
w() { (cd "$R" && WEAVE_DIR="$R/.weave" WV_HOT_ZONE="$R/hot" WV_CONFIG_DIR="$R/cfg" WV_REQUIRE_QUALITY=0 "$WV" "$@") < "${STDIN:-/dev/null}" 2>/dev/null; }
node() { w add "$1" --standalone --criteria=c --risks=low --alias="$2" | grep -oE 'wv-[a-f0-9]{6}' | sed -n 1p; }
# counted <label> <wv args...> — the call, journaled in evidence mode, must
# complete countable.
counted() {
    local label="$1" before result
    shift
    before=$(wc -l < "$J")
    (cd "$R" && WEAVE_DIR="$R/.weave" WV_HOT_ZONE="$R/hot" WV_CONFIG_DIR="$R/cfg" WV_REQUIRE_QUALITY=0 \
        WV_EVIDENCE_MODE=1 WV_ATTEMPT_JOURNAL="$J" WV_CALL_SOURCE=agent "$WV" "$@") \
        < "${STDIN:-/dev/null}" >/dev/null 2>&1
    result=$(tail -n +"$((before + 1))" "$J" | jq -rc 'select(.event=="call_completed")
        | "\(.policy.countable) \(.policy.state) \((.policy.applicable_rules - .policy.evaluated_rules) | join(","))"' | tail -1)
    if [ "${result%% *}" = "true" ]; then
        ok "$label is countable"
    else
        bad "$label is countable" "${result:-no call_completed was recorded}"
    fi
}

echo "=== one clean call per operation ==="
counted "wv add" add "a plain countable node" --standalone
counted "wv add --status=active" add "an active countable node" --standalone --status=active --criteria=c --risks=low
a=$(node "work target" wt); b=$(node "block target" bt)
counted "wv work" work "$a"
counted "wv block" block "$b" --by="$a"
counted "wv link" link "$a" "$b" --type=relates_to
counted "wv update" update "$b" --text="changed text"
c=$(node "done target" dt); w work "$c" >/dev/null
counted "wv done" done "$c" --learning="pattern: a distinctive zebra phrase" --verification-method=m --verification-evidence=e
d=$(node "delete target" delt)
counted "wv delete" delete "$d"
counted "wv quick" quick "a quick countable thing"
f=$(node "ship target" st); w work "$f" >/dev/null
counted "wv ship" ship "$f" --learning="pattern: another quokka phrase" --no-gh
g=$(node "ship agent target" sat); w work "$g" >/dev/null
counted "wv ship-agent" ship-agent "$g" --learning="pattern: a third ibis phrase" --no-gh
h1=$(node "batch one" b1); h2=$(node "batch two" b2); w work "$h1" >/dev/null; w work "$h2" >/dev/null
counted "wv batch-done" batch-done "$h1" "$h2" --learning="pattern: a fourth heron phrase" --no-gh
counted "wv sync" sync
w done "$a" --skip-verification >/dev/null
counted "wv compact" compact
counted "wv cutover" cutover --yes
counted "wv doctor" doctor
counted "wv recover" recover
counted "wv repo-class set" repo-class set owned
k=$(node "bulk target" bkt); printf '[{"id":"%s","status":"todo"}]' "$k" > "$TMP/bulk.json"
STDIN="$TMP/bulk.json" counted "wv bulk-update" bulk-update
r1=$(node "resolve one" r1); r2=$(node "resolve two" r2)
counted "wv resolve --defer" resolve "$r1" "$r2" --defer
r3=$(node "resolve three" r3); r4=$(node "resolve four" r4)
counted "wv resolve --winner" resolve "$r3" "$r4" --winner="$r3"
F="$TMP/fresh"; mkdir -p "$F/cfg"; git -C "$F" init -q .
before=$(wc -l < "$J")
(cd "$F" && WEAVE_DIR="$F/.weave" WV_HOT_ZONE="$F/hot" WV_CONFIG_DIR="$F/cfg" WV_EVIDENCE_MODE=1 \
    WV_ATTEMPT_JOURNAL="$J" WV_CALL_SOURCE=agent "$WV" init) </dev/null >/dev/null 2>&1
[ "$(tail -n +"$((before + 1))" "$J" | jq -r 'select(.event=="call_completed") | .policy.countable' | tail -1)" = true ] &&
    ok "wv init in a fresh repository is countable" || bad "wv init in a fresh repository is countable"

echo "=== a call that syncs records its completion ==="
# wv-15422b: sync's own EXIT trap used to replace the call's completion trap.
for op in sync quick ship; do
    started=$(jq -r --arg o "$op" 'select(.event=="call_started" and .operation==$o) | .call_id' "$J" | tail -1)
    if [ -n "$started" ] && jq -e --arg c "$started" 'select(.event=="call_completed" and .call_id==$c)' "$J" >/dev/null; then
        ok "wv $op records call_completed"
    else
        bad "wv $op records call_completed"
    fi
done

echo "=== a gate that stops recording its allow breaks countability ==="
# Tripwire on a copy of the scripts: remove block_graph_acyclic's allow and
# the same clean call must lose countability, naming the silent rule.
cp -r "$ROOT/scripts" "$TMP/scripts-copy"
sed -i '/wv_policy_verdict block_graph_acyclic allow/d' "$TMP/scripts-copy/cmd/wv-cmd-graph.sh"
T="$TMP/trip"; setup_repo "$T" "$TMP/scripts-copy/wv"
tw() { (cd "$T" && WEAVE_DIR="$T/.weave" WV_HOT_ZONE="$T/hot" WV_CONFIG_DIR="$T/cfg" "$TMP/scripts-copy/wv" "$@") </dev/null 2>/dev/null; }
t1=$(tw add "trip one" --standalone | grep -oE 'wv-[a-f0-9]{6}' | sed -n 1p)
t2=$(tw add "trip two" --standalone | grep -oE 'wv-[a-f0-9]{6}' | sed -n 1p)
TJ="$TMP/trip.jsonl"; : > "$TJ"
(cd "$T" && WEAVE_DIR="$T/.weave" WV_HOT_ZONE="$T/hot" WV_CONFIG_DIR="$T/cfg" WV_EVIDENCE_MODE=1 \
    WV_ATTEMPT_JOURNAL="$TJ" WV_CALL_SOURCE=agent "$TMP/scripts-copy/wv" block "$t2" --by="$t1") </dev/null >/dev/null 2>&1
trip=$(jq -rc 'select(.event=="call_completed") | "\(.policy.countable) \((.policy.applicable_rules - .policy.evaluated_rules) | join(","))"' "$TJ" | tail -1)
[ "$trip" = "false block_graph_acyclic" ] &&
    ok "without its allow, a clean wv block is not countable and names the silent rule" ||
    bad "without its allow, a clean wv block is not countable and names the silent rule" "$trip"

echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
