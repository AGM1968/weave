#!/usr/bin/env bash
# "done" is an argument to the wv helpers below, never the loop keyword.
# shellcheck disable=SC1010
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# Policy cells (wv-49b339). Every command_gate and sqlite_trigger rule cell the
# policy contract declares -- each decision, and an allow for each bypass that
# records a value -- driven end to end by a real wv call. tests/test-policy-gates.sh
# covers the representative set; this suite covers the rest, so the totality
# check (tests/test-policy-totality.sh) observes every cell in one of the two
# journals. Each cell asserts on the verdicts of its own call only: the journal
# lines that call appended, bound to that call's call_started.
set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WV="$ROOT/scripts/wv"
run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
TMP=$(mktemp -d /tmp/wv-policy-cells-XXXXXX)
trap 'rm -rf "$TMP"' EXIT
# POLICY_CELLS_JOURNAL keeps the journal past this suite's exit, for the
# totality check.
export WV_ATTEMPT_JOURNAL="${POLICY_CELLS_JOURNAL:-$TMP/attempts.jsonl}"
: > "$WV_ATTEMPT_JOURNAL"
export WV_REQUIRE_QUALITY=0

# repo <name> -> a fresh initialised repository directory
repo() {
    local d="$TMP/$1"
    mkdir -p "$d/config"
    git -C "$d" init -q . && git -C "$d" config user.email t@t && git -C "$d" config user.name t &&
        git -C "$d" config commit.gpgsign false
    in_repo "$d" "$WV" init >/dev/null 2>&1
    echo "$d"
}
# in_repo <dir> <command...> — run inside that repository's Weave environment
in_repo() {
    local d="$1"; shift
    (cd "$d" && export WEAVE_DIR="$d/.weave" WV_HOT_ZONE="$d/hot" WV_CONFIG_DIR="$d/config" && "$@")
}
sq_in() { sqlite3 -cmd ".timeout 5000" "$1/hot/brain.db" "$2"; }
add_in() {  # add_in <dir> <wv add args...> -> the new id (no early-exit pipe under pipefail)
    local out
    out=$(in_repo "$1" "$WV" add "${@:2}" 2>/dev/null)
    [[ "$out" =~ wv-[a-f0-9]{4,6} ]] && printf '%s\n' "${BASH_REMATCH[0]}"
}

# cell <label> <rule> <decision> <bypass|-|prefix*> <command...>
# The call must append a verdict for <rule> with that decision and bypass,
# under a call_id the same call recorded as call_started.
cell() {
    local label="$1" rule="$2" decision="$3" bypass="$4" before
    shift 4
    before=$(wc -l < "$WV_ATTEMPT_JOURNAL")
    "$@" > "$TMP/last.out" 2>&1 < /dev/null
    if tail -n +"$((before + 1))" "$WV_ATTEMPT_JOURNAL" | jq -se --arg r "$rule" --arg d "$decision" --arg b "$bypass" '
        [.[] | select(.event == "call_started") | .call_id] as $calls
        | any(.[]; .event == "policy_verdict" and .rule == $r and .decision == $d
              and ((.bypass // "-") as $got
                   | if ($b | endswith("*")) then ($got | startswith($b[:-1])) else $got == $b end)
              and (.call_id as $c | $calls | index($c) != null))' >/dev/null; then
        ok "$label"
    else
        bad "$label" "$(tail -n +"$((before + 1))" "$WV_ATTEMPT_JOURNAL" | jq -c 'select(.event=="policy_verdict") | [.rule,.decision,.bypass]' | tr '\n' ' ') | $(tail -2 "$TMP/last.out" | tr '\n' ' ')"
    fi
}

R=$(repo main)
w() { in_repo "$R" "$WV" "$@"; }
we() { in_repo "$R" env "$@"; }  # we VAR=value... "$WV" <args...>

epic=$(add_in "$R" "cells epic" --metadata='{"type":"epic"}' --force)

echo "=== add ==="
cell "an active add without claim-ready metadata is denied" active_add_requires_claim_readiness deny - \
    w add "kiwi orchard irrigation" --status=active --parent="$epic"
cell "--force records the claim-readiness override" active_add_requires_claim_readiness allow --force \
    w add "mango freight schedule" --status=active --parent="$epic" --force
add_in "$R" "harbour lantern quartz ferry" --parent="$epic" >/dev/null
cell "--force records the duplicate override" add_duplicate_check allow --force \
    w add "harbour lantern quartz ferry" --force
cell "--standalone records the duplicate override" add_duplicate_check allow --standalone \
    w add "harbour lantern quartz ferry" --standalone
live=$(add_in "$R" "reconstruct target node" --parent="$epic")
cell "reconstructing a live id is denied" reconstruct_never_overwrites deny - \
    w add "reconstructed text" --id="$live" --parent="$epic"

echo "=== work and delete ==="
reserved=$(add_in "$R" "reserved slot probe" --parent="$epic" --metadata='{"e5_reserved":true,"e5_slot":"cells"}')
cell "claiming a reserved node is denied" reserved_slot_claim deny - w work "$reserved"
cell "WV_ALLOW_RESERVED=1 records the reservation override" reserved_slot_claim allow WV_ALLOW_RESERVED=1 \
    we WV_ALLOW_RESERVED=1 "$WV" work "$reserved" --quiet
parent=$(add_in "$R" "delete parent probe" --parent="$epic")
add_in "$R" "delete child probe" --parent="$parent" >/dev/null
cell "--force records deleting a node with children" delete_preserves_children allow --force \
    w delete "$parent" --force

echo "=== edge invariants and closure ==="
e1=$(add_in "$R" "edge cell one" --parent="$epic"); e2=$(add_in "$R" "edge cell two" --parent="$epic")
cell "a self-edge is denied" edge_write_invariants deny - w link "$e1" "$e1" --type=relates_to
cell "an edge that keeps its invariant is allowed" edge_write_invariants allow - w link "$e1" "$e2" --type=relates_to
ep=$(add_in "$R" "closure cell parent" --parent="$epic"); add_in "$R" "closure cell child" --parent="$ep" >/dev/null
cell "closing over an open child is denied" close_children_accounted deny - w done "$ep" --skip-verification --no-warn
cell "closing a childless node is allowed" close_children_accounted allow - w done "$e2" --skip-verification --no-warn

echo "=== done ==="
active() {  # active <text> [metadata] -> a claimed node
    local n
    n=$(add_in "$R" "$1" --parent="$epic" --metadata="${2:-{\}}")
    w work "$n" >/dev/null 2>&1
    echo "$n"
}
n=$(active "human verification probe" '{"pending_close":{"reason":"needs a human to confirm"}}')
cell "a close waiting for human verification is denied" close_awaits_human_verification deny - \
    w done "$n" --skip-verification
cell "--acknowledge-overlap records closing over the wait" close_awaits_human_verification allow --acknowledge-overlap \
    w done "$n" --skip-verification --acknowledge-overlap
n=$(active "learning required probe")
cell "a close with no learning is denied" close_requires_learning deny - w done "$n"
cell "--no-warn records the learning bypass" close_requires_learning allow --no-warn w done "$n" --no-warn
n=$(active "learning knob probe")
cell "WV_REQUIRE_LEARNING=0 records the learning bypass" close_requires_learning allow WV_REQUIRE_LEARNING=0 \
    we WV_REQUIRE_LEARNING=0 "$WV" done "$n"
n=$(active "quality evidence probe")
sq_in "$R" "INSERT OR REPLACE INTO node_files(node_id,path) VALUES('$n','src/unscanned.py');"
# A close scans an empty hot zone in place (wv-f4f431); it is denied only when
# that scan cannot produce data, here a directory where quality.db belongs.
rm -f "$R/hot/quality.db" "$R/hot/quality.db-wal" "$R/hot/quality.db-shm"; mkdir "$R/hot/quality.db"
cell "a close whose in-place quality scan yields nothing is denied" close_requires_quality_evidence deny - \
    we WV_REQUIRE_QUALITY=1 "$WV" done "$n" --skip-verification
rmdir "$R/hot/quality.db"
n=$(active "finding probe" '{"type":"finding"}')
cell "a finding without a violation type is denied" finding_close_requires_violation_type deny - \
    w done "$n" --skip-verification
n=$(active "completion scope probe")
cell "a completion scope naming an untouched file is denied" completion_scope_integrity deny - \
    w done "$n" --skip-verification --completion-files=src/never.py
# A red test on an exempt path: the close goes through and names the exemption.
printf '\n[exempt]\nsrc/exempt/\n' >> "$R/.weave/quality.conf"
n=$(active "exempt config load")
w done "$n" --skip-verification >/dev/null 2>&1
sq_in "$R" "UPDATE policy_thresholds SET value=2 WHERE key='test_gate';"
n=$(active "exempt red test probe")
sq_in "$R" "INSERT OR REPLACE INTO file_test_status(path,state) VALUES('src/exempt/red.py','red');
            INSERT OR REPLACE INTO node_files(node_id,path) VALUES('$n','src/exempt/red.py');"
cell "a red test on an exempt path records the exemption" close_tests_not_red allow 'quality_exempt:*' \
    w done "$n" --skip-verification
sq_in "$R" "UPDATE policy_thresholds SET value=0 WHERE key='test_gate';"

echo "=== delegation ==="
# batch runs each line as its own wv call: the verdict belongs to that child
# call (with batch as parent_call_id), never to the batch call.
n=$(active "batch delegation probe")
before=$(wc -l < "$WV_ATTEMPT_JOURNAL")
echo "done $n" | w batch >/dev/null 2>&1
if tail -n +"$((before + 1))" "$WV_ATTEMPT_JOURNAL" | jq -se '
    (map(select(.event=="call_started" and .operation=="batch")) | first | .call_id) as $batch
    | ($batch != null)
      and any(.[]; .event=="policy_verdict" and .rule=="close_requires_learning" and .operation=="done")
      and ([.[] | select(.event=="policy_verdict" and .call_id==$batch)] | length == 0)
      and any(.[]; .event=="call_started" and .operation=="done" and .parent_call_id==$batch)' >/dev/null; then
    ok "a batch line is its own call, parented to the batch, which decides nothing"
else
    bad "a batch line is its own call, parented to the batch, which decides nothing" \
        "$(tail -n +"$((before + 1))" "$WV_ATTEMPT_JOURNAL" | jq -c '[.event,.operation,.rule,.call_id,.parent_call_id]' | tr '\n' ' ')"
fi
# ship-agent runs ship in-process, so ship's rules decide inside it.
n=$(active "ship agent probe")
cell "ship's close rules decide inside ship-agent" close_requires_learning deny - \
    w ship-agent "$n" --no-gh

echo "=== recover ==="
n=$(active "recover fabrication probe")
printf '%s\n' "{\"event\":\"begin\",\"op\":\"ship\",\"op_id\":\"cells-1\",\"args\":{\"id\":\"$n\"},\"ts\":\"2026-01-01T00:00:00Z\"}" \
    "{\"event\":\"step\",\"op\":\"ship\",\"op_id\":\"cells-1\",\"step\":1,\"action\":\"done\",\"status\":\"pending\",\"args\":{\"id\":\"$n\"},\"ts\":\"2026-01-01T00:00:01Z\"}" \
    > "$R/hot/ops.journal"
cell "recovery refuses to invent a close that never landed" recovery_never_fabricates_closure deny - \
    w recover --auto
rm -f "$R/hot/ops.journal"
cell "recovery with nothing to recover invents no close" recovery_never_fabricates_closure allow - \
    w recover

echo "=== sync shrink floor ==="
S=$(repo sync)
for i in 1 2 3 4 5 6 7 8 9 10; do add_in "$S" "floor node $i alpha$i" --standalone >/dev/null; done
in_repo "$S" "$WV" sync >/dev/null 2>&1
cp "$S/.weave/state.sql" "$TMP/full-state.sql"
sq_in "$S" "DELETE FROM nodes WHERE text LIKE 'floor node%' AND text NOT LIKE 'floor node 1 %';"
shrink() {  # shrink [env...] -- sync against the full committed state.sql
    cp "$TMP/full-state.sql" "$S/.weave/state.sql"
    in_repo "$S" env "$@" "$WV" sync
}
cell "a sync that would shrink the committed graph is denied" sync_shrink_floor deny - shrink WV_CELLS=1
# shellcheck disable=SC2016  # $1/$2 expand in the bash -c child, passed as positional arguments
cell "--force records the shrink" sync_shrink_floor allow --force \
    bash -c 'cp "$1" "$2/.weave/state.sql"; cd "$2" && WEAVE_DIR="$2/.weave" WV_HOT_ZONE="$2/hot" WV_CONFIG_DIR="$2/config" "$3" sync --force' _ "$TMP/full-state.sql" "$S" "$WV"
cell "WV_FORCE_SYNC=1 records the shrink" sync_shrink_floor allow WV_FORCE_SYNC=1 shrink WV_FORCE_SYNC=1
cell "WV_SYNC_FLOOR_RATIO=0 records the shrink" sync_shrink_floor allow WV_SYNC_FLOOR_RATIO=0 shrink WV_SYNC_FLOOR_RATIO=0

echo "=== coordination gates ==="
C=$(repo coord)
held=$(add_in "$C" "held claim" --standalone)
in_repo "$C" "$WV" work "$held" >/dev/null 2>&1
in_repo "$C" "$WV" sync >/dev/null 2>&1
cell "compacting while a claim is held is denied" compact_waits_for_claims deny - in_repo "$C" "$WV" compact
cell "--force records compacting over a claim" compact_waits_for_claims allow --force in_repo "$C" "$WV" compact --force
cell "cutting over while a claim is held is denied" cutover_waits_for_claims deny - in_repo "$C" "$WV" cutover
cell "--force records cutting over a claim" cutover_waits_for_claims allow --force in_repo "$C" "$WV" cutover --force

echo "=== init and repository class ==="
cell "initialising over a live graph is denied" init_preserves_existing_graph deny - w init
F=$(repo force)
add_in "$F" "doomed node" --standalone >/dev/null
cell "--force records reinitialising over a live graph" init_preserves_existing_graph allow --force \
    in_repo "$F" "$WV" init --force
L="$TMP/linked"; mkdir -p "$L/config" "$TMP/elsewhere"
git -C "$L" init -q . && ln -s "$TMP/elsewhere" "$L/.weave"
cell "initialising through a symlinked .weave is denied" init_refuses_symlinked_weave_dir deny - \
    in_repo "$L" "$WV" init
V="$TMP/vendored"; mkdir -p "$V/config"
git -C "$V" init -q . && git -C "$V" config --local weave.repositoryClass vendored-upstream
cell "writing Weave state into a vendored repository is denied" repository_write_requires_owned deny - \
    in_repo "$V" "$WV" init
U="$TMP/upstream"; mkdir -p "$U/config"
git -C "$U" init -q . && git -C "$U" remote add origin https://github.com/example/upstream.git
cell "owning a remote-bearing repository is denied without acknowledgement" owned_override_requires_acknowledgement deny - \
    in_repo "$U" "$WV" repo-class set owned
cell "--acknowledge-upstream-fork records the ownership override" owned_override_requires_acknowledgement allow --acknowledge-upstream-fork \
    in_repo "$U" "$WV" repo-class set owned --acknowledge-upstream-fork

echo "=== every event is schema-valid and inside the denominator ==="
if python3 "$ROOT/tests/lib/journal-validate.py" "$WV_ATTEMPT_JOURNAL" 2>"$TMP/schema.err"; then
    ok "all $(wc -l < "$WV_ATTEMPT_JOURNAL") events validate against the attempt-journal schema"
else
    bad "all events validate against the attempt-journal schema" "$(head -3 "$TMP/schema.err")"
fi
if out=$(python3 "$ROOT/scripts/weave_policy.py" denominator "$WV_ATTEMPT_JOURNAL"); then
    ok "every verdict is bound to a counted call ($(jq -r .counted_calls <<< "$out") calls)"
else
    bad "every verdict is bound to a counted call" "$(jq -c '.errors[:3]' <<< "$out")"
fi

echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
