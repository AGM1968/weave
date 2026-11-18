#!/usr/bin/env bash
# The gate role contract: invariants every gate keeps, whatever runs it (split
# from test-gate-lanes.sh on wv-7e8216; the compiled gate plan, wv-518c6c,
# keeps these and retires the candidate-lane mechanism). Pinned here, in a
# fixture whose HEAD carries this checkout's scripts/:
#   - a candidate gate that cannot admit its own commit is refused;
#   - D3 at the dispatcher layer: a new check and a weakened helper staged
#     together are refused, though one combined candidate lane admits them;
#   - D4: a check needing a helper changed in the same commit is refused until
#     the helper lands first;
#   - HEAD's contract decides: deleting, narrowing or breaking it is refused,
#     and a dependency it does not declare, or cannot resolve, is refused;
#   - a new reference to gate code through REPO_ROOT, which is the working
#     tree rather than a lane's copy, is refused (R1, wv-23798e);
#   - a lane runs only the pre-commit hook, so a commit changing another
#     declared entry point is refused, never admitted as run (R2, wv-403fb5);
#   - repair and retirement records admit one exact change, once (S2c).
export WV_TEST_SUITE=1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
run=0; pass=0
# shellcheck source=tests/fixtures/gate-lanes/setup.sh
source "$SCRIPT_DIR/fixtures/gate-lanes/setup.sh" || exit 1

echo "a candidate gate that cannot admit its own commit is refused"
reset_all
printf '%s\n' 'echo "✗ fixture: the candidate gate refuses" >&2; exit 1' > "$T/snip"
into_hook "$T/snip"
gate
check "a hook that refuses every commit is refused" "1" "$RC"
has "...in its lane" "$OUT" "the candidate version of $HOOK does not admit this commit"
has "...showing why" "$OUT" "fixture: the candidate gate refuses"

reset_all; git rm -q scripts/lib/wv-gate-pool.sh
gate
check "deleting a library the gate needs is refused" "1" "$RC"
has "...before a lane, requiring explicit retirement" "$OUT" "deleting enforcement scripts/lib/wv-gate-pool.sh needs a prior exact retirement record"

reset_all; git rm -q "$HOOK"
gate
check "deleting the gate's hook is refused" "1" "$RC"
has "...as a retirement, which needs a record" "$OUT" "deletes the gate's hook"

echo "D3: a new check and a weakened helper, staged together"
reset_all
cat > "$T/snip" <<'SNIP_EOF'
. "$_PC_SCRIPTS/lib/wv-fixture-helper.sh"
if ! fixture_src_ok; then echo "✗ fixture: src/a.sh carries BUG" >&2; exit 1; fi
SNIP_EOF
into_hook "$T/snip"
printf '#!/usr/bin/env bash\nfixture_src_ok() { return 0; }\n' > "$HELPER"; git add "$HELPER"
printf '#!/bin/sh\necho BUG\n' > src/a.sh; git add src/a.sh
combined
check "(control) one combined candidate lane admits the defect" "0" "$RC"
gate
check "per-file lanes refuse it" "1" "$RC"
has "...in the new check's lane, against HEAD's helper" "$OUT" "fixture: src/a.sh carries BUG"

echo "D4: a check needing a helper changed in the same commit"
reset_all
# shellcheck disable=SC2016  # the hook's text, not this suite's expansion
printf '%s\n' '. "$_PC_SCRIPTS/lib/wv-fixture-helper.sh"' 'fixture_new_check || exit 1' > "$T/snip"
into_hook "$T/snip"
printf 'fixture_new_check() { return 0; }\n' >> "$HELPER"; git add "$HELPER"
gate
check "is refused while the helper is staged with it" "1" "$RC"
has "...telling the author to land the helper first" "$OUT" "land that file first"
git reset -q -- "$HOOK"; git checkout -q -- "$HOOK"
gate
check "the helper alone is admitted" "0" "$RC"
commit_nohook "helper first"
into_hook "$T/snip"
gate
check "then the check that needs it is admitted" "0" "$RC"
git reset -q --hard HEAD~1; rm -f "$MARK/probe"

echo "R1 (wv-23798e): gate code named through REPO_ROOT is the working tree, not a lane's copy"
reset_all
# shellcheck disable=SC2016  # the hook's text, not this suite's expansion
printf '%s\n' '. "$REPO_ROOT/scripts/lib/wv-fixture-helper.sh"' \
    'if ! fixture_src_ok; then echo "✗ fixture: src/a.sh carries BUG" >&2; exit 1; fi' > "$T/snip"
into_hook "$T/snip"
printf '#!/usr/bin/env bash\nfixture_src_ok() { return 0; }\n' > "$HELPER"; git add "$HELPER"
printf '#!/bin/sh\necho BUG\n' > src/a.sh; git add src/a.sh
gate
check "a new check loading a weakened helper through REPO_ROOT is refused" "1" "$RC"
has "...as a new working-tree reference to gate code" "$OUT" "names scripts/lib/wv-fixture-helper.sh through REPO_ROOT"
reset_all
# shellcheck disable=SC2016
printf '%s\n' '. "$REPO_ROOT/scripts/lib"/wv-fixture-helper.sh' > "$T/snip"
into_hook "$T/snip"
gate
check "...and through a directory prefix" "1" "$RC"
has "...naming the prefix" "$OUT" "names scripts/lib through REPO_ROOT"
reset_all
# shellcheck disable=SC2016
printf '%s\n' '. "$REPO_ROOT"/scripts/lib/wv-fixture-helper.sh' > "$T/snip"
into_hook "$T/snip"
gate
check "...and with the variable quoted apart from the path" "1" "$RC"
has "...naming the helper" "$OUT" "names scripts/lib/wv-fixture-helper.sh through REPO_ROOT"
reset_all; fresh "$HOOK"
gate
check "(control) a changed hook naming gate code beside itself is admitted" "0" "$RC"
[ "$RC" = 0 ] || tail -15 <<< "$OUT" | sed 's/^/      | /'

echo "N1 (wv-c424ed): a HEAD fallback cannot be spent on an active load"
# HEAD carries an inert REPO_ROOT fallback, on a path no lane takes, as the
# hook's consumer branch did. The review moved it onto the lane's path and
# kept the count.
reset_all
# shellcheck disable=SC2016
printf '%s\n' 'if false; then _gl_fallback="$REPO_ROOT/scripts/lib"; fi' > "$T/snip"
into_hook "$T/snip"; commit_nohook "inert fallback"
_gl_n1_base=$(git rev-parse HEAD)
# shellcheck disable=SC2016
printf '%s\n' '. "$REPO_ROOT/scripts/lib"/wv-fixture-helper.sh' \
    'if ! fixture_src_ok; then echo "✗ fixture: src/a.sh carries BUG" >&2; exit 1; fi' > "$T/snip"
into_hook "$T/snip"
# shellcheck disable=SC2016
sed 's|_gl_fallback="$REPO_ROOT/scripts/lib"|_gl_fallback="$HOME/unused-fixture-lib"|' "$HOOK" > "$T/hook.new" \
    && cat "$T/hook.new" > "$HOOK" && git add "$HOOK"
check "(precondition) the fallback is gone from the staged hook" "0" \
    "$(git show ":$HOOK" | grep -c '_gl_fallback="\$REPO_ROOT')"
printf '#!/usr/bin/env bash\nfixture_src_ok() { return 0; }\n' > "$HELPER"; git add "$HELPER"
printf '#!/bin/sh\necho BUG\n' > src/a.sh; git add src/a.sh
gate
check "the review's substitution is refused" "1" "$RC"
has "...as a working-tree reference in a changed file" "$OUT" "A file this commit changes may name no gate code that way"
hasnt "...before any lane admits it" "$OUT" "2 of 2 admitted"
reset_all; fresh scripts/lib/wv-cache.sh
gate
check "(control) a commit leaving the file with HEAD's fallback alone is admitted" "0" "$RC"
reset_all; git reset -q --hard "$_gl_n1_base~1"; rm -f "$MARK/probe"

echo "R2 (wv-403fb5): a changed entry point other than pre-commit is refused"
for _gl_ev in pre-push prepare-commit-msg reference-transaction; do
    reset_all; fresh "scripts/hooks/$_gl_ev-weave.sh"
    gate
    check "a changed $_gl_ev hook is refused" "1" "$RC"
    has "...since no lane can run it" "$OUT" "changes the $_gl_ev hook (scripts/hooks/$_gl_ev-weave.sh)"
done
reset_all
sed '1a exit 1' scripts/hooks/pre-push-weave.sh > "$T/pp" && cat "$T/pp" > scripts/hooks/pre-push-weave.sh
git add scripts/hooks/pre-push-weave.sh
gate
check "the review's pre-push hook that exits at once is refused" "1" "$RC"
hasnt "...and not reported as an admitted lane" "$OUT" "1 of 1 admitted"
reset_all
jq 'del(.entry_points["scripts/hooks/pre-push-weave.sh"])' "$CONTRACT" > "$T/c.json" && cat "$T/c.json" > "$CONTRACT"
git add "$CONTRACT"
gate
check "dropping an entry point from the contract is refused" "1" "$RC"
has "...naming it" "$OUT" "drops scripts/hooks/pre-push-weave.sh"

echo "N2 (wv-3b601f): an entry point's event is part of its role"
reset_all
jq '.entry_points["scripts/hooks/pre-push-weave.sh"] = "pre-commit"' "$CONTRACT" > "$T/c.json" \
    && cat "$T/c.json" > "$CONTRACT"; git add "$CONTRACT"
gate
check "relabelling pre-push as pre-commit is refused" "1" "$RC"
has "...since only the hook a lane runs serves pre-commit" "$OUT" "staged gate role contract ($CONTRACT) is not valid"
# The review's second step, against a HEAD that already accepted the relabel.
commit_nohook "relabelled pre-push"
sed '1a exit 1' scripts/hooks/pre-push-weave.sh > "$T/pp" && cat "$T/pp" > scripts/hooks/pre-push-weave.sh
git add scripts/hooks/pre-push-weave.sh
gate
check "...and a HEAD carrying the relabel admits no broken pre-push" "1" "$RC"
hasnt "...as an admitted lane" "$OUT" "1 of 1 admitted"
reset_all; git reset -q --hard HEAD~1
jq '.entry_points["scripts/hooks/pre-push-weave.sh"] = "post-commit"' "$CONTRACT" > "$T/c.json" \
    && cat "$T/c.json" > "$CONTRACT"; git add "$CONTRACT"
gate
check "changing an entry point to another event is refused" "1" "$RC"
has "...naming both events" "$OUT" "changes the event of scripts/hooks/pre-push-weave.sh from pre-push to post-commit"
reset_all
jq '.entry_points["scripts/hooks/pre-push-weave.sh"] = "pre-psuh"' "$CONTRACT" > "$T/c.json" \
    && cat "$T/c.json" > "$CONTRACT"; git add "$CONTRACT"
gate
check "an event git does not have is refused" "1" "$RC"
has "...as an invalid contract" "$OUT" "staged gate role contract ($CONTRACT) is not valid"
reset_all
printf '#!/bin/sh\nexit 1\n' > scripts/hooks/commit-msg-weave.sh; chmod +x scripts/hooks/commit-msg-weave.sh
jq '.entry_points["scripts/hooks/commit-msg-weave.sh"] = "commit-msg"' "$CONTRACT" > "$T/c.json" \
    && cat "$T/c.json" > "$CONTRACT"; git add "$CONTRACT" scripts/hooks/commit-msg-weave.sh
gate
check "a new hook the commit declares for another event is refused" "1" "$RC"
has "...since no lane runs it" "$OUT" "changes the commit-msg hook (scripts/hooks/commit-msg-weave.sh)"

echo "S2c (wv-9a805a): a repair record committed first admits one exact entry-point change"
reset_all
RT=scripts/hooks/reference-transaction-weave.sh
_gl_s2c_head=$(git rev-parse HEAD)
# record <name> <path> <baseline> <replacement> [jq filter]
record() {
    local bm rm
    mkdir -p .weave/gate-repairs
    bm=$(git ls-tree HEAD -- "$2" | cut -d' ' -f1)
    rm=$(git ls-files --stage -- "$2" | cut -d' ' -f1)
    jq -n --arg p "$2" --arg o "$3" --arg n "$4" --arg bm "$bm" --arg rm "$rm" \
        '{version: 2, kind: "repair", path: $p, baseline: $o, replacement: $n,
          baseline_mode: $bm, replacement_mode: $rm,
          reason: "fixture repair", verification: "fixture suite"}' | jq "${5:-.}" \
        > ".weave/gate-repairs/$1.json"
}
commit_record() { git add .weave/gate-repairs && git -c core.hooksPath=/dev/null commit -q -m "record $1" -- .weave/gate-repairs; }
_gl_rt_a=$(git rev-parse "HEAD:$RT")
printf '# repaired\n' >> "$RT"; _gl_rt_b=$(git hash-object "$RT"); git add "$RT"
gate
check "(control) without a record the change is refused" "1" "$RC"
has "...printing the record that would admit it" "$OUT" "\"replacement\": \"$_gl_rt_b\""
# wv-c909ff: the verdict depends only on the staged paths and HEAD's records,
# so it comes before the protected pass: the routed probe never runs.
check "...before any routed suite runs" "0" "$(runs probe)"
record rt "$RT" "$_gl_rt_a" "$_gl_rt_b"; git add .weave/gate-repairs
gate
check "a record staged in the same commit admits nothing" "1" "$RC"
check "...refused before any routed suite runs" "0" "$(runs probe)"
git reset -q -- .weave/gate-repairs
record rt "$RT" "$_gl_rt_a" "$_gl_rt_a"; commit_record rt
record rt "$RT" "$_gl_rt_a" "$_gl_rt_b"; git add .weave/gate-repairs "$RT"
gate
check "a record at HEAD edited in the same commit to name these bytes admits nothing" "1" "$RC"
check "...refused before any routed suite runs" "0" "$(runs probe)"
git reset -q -- .weave/gate-repairs "$RT"; commit_record rt; git add "$RT"
gate
check "a record committed first admits that exact change" "0" "$RC"
has "...saying the hook was not run" "$OUT" "$RT is not run; this change to the reference-transaction hook is admitted by the repair record .weave/gate-repairs/rt.json"
has "...and that a record is not approval" "$OUT" "traceability, not approval"
hasnt "...building no lane for it" "$OUT" "candidate lanes:"
check "...after the protected pass ran its routed suite (the preflight admits nothing)" "1" "$(runs probe)"
check "...saying so once: the preflight decides the same way but reports nothing" "1" \
    "$(grep -c 'is not run; this change to the reference-transaction hook' <<< "$OUT")"
printf '# and more\n' >> "$RT"; git add "$RT"; rm -f "$MARK/probe"
gate
check "...but not other bytes" "1" "$RC"
check "...refused before any routed suite runs" "0" "$(runs probe)"
git checkout -q HEAD -- "$RT"; printf '# repaired\n' >> "$RT"; git add "$RT"
_gl_rec=$(git rev-parse HEAD)
git -c core.hooksPath=/dev/null commit -q -m "A to B" -- "$RT"
_gl_consuming_tree=$(git rev-parse HEAD:scripts)
# Distinguish the historical subtree from the later staged B subtree; hiding
# a shared tree would merely make the staged candidate unreadable too.
printf 'later context\n' > scripts/history-marker.txt
git add scripts/history-marker.txt
git -c core.hooksPath=/dev/null commit -q -m "later context" -- scripts/history-marker.txt
git show "$_gl_rec:$RT" > "$RT"; git -c core.hooksPath=/dev/null commit -q -m "B to A" -- "$RT"
printf '# repaired\n' >> "$RT"; git add "$RT"; rm -f "$MARK/probe"
gate
check "a record is consumed once its transition lands, even after A-B-A" "1" "$RC"
has "...asking for a new record" "$OUT" "To land this exact change, commit a repair record"
check "...refused before any routed suite runs" "0" "$(runs probe)"
# Follow-up review F1 (wv-a18f1e): the same history, truncated. A depth-1 clone
# holds the record as if added at its root, so the transitions that consumed
# it are not there to see. Driven through the resolver the gate calls, since a
# clone is another repository with no graph of its own here.
resolve_record() { # resolve_record <repo> <path> — gate_repair_record's status there
    ( cd "$1" || exit 9
      # shellcheck source=scripts/lib/wv-gate-snapshot.sh
      source "$ROOT/scripts/lib/wv-gate-snapshot.sh"
      # shellcheck source=scripts/lib/wv-gate-lanes.sh
      source "$ROOT/scripts/lib/wv-gate-lanes.sh"
      gate_freeze || exit 8
      gate_repair_record "$2" "${3:-repair}" >/dev/null 2>&1; echo $? )
}
check "(control) the resolver finds the record consumed in full history" "1" "$(resolve_record "$W" "$RT")"
# Only the disposable fixture's consuming subtree is hidden. HEAD and its
# installed gate remain readable; absence of an old subtree is not absence
# of the hook at that commit (wv-5df974).
_gl_object=".git/objects/${_gl_consuming_tree:0:2}/${_gl_consuming_tree:2}"
mv "$_gl_object" "$T/consuming-tree"
check "unreadable consumption history cannot revive a repair record" "2" "$(resolve_record "$W" "$RT")"
rm -f "$MARK/probe"
gate
check "the hook refuses unreadable consumption history" "1" "$RC"
has "...naming the unreadable repair history" "$OUT" "could not read the repair records"
check "...before any routed suite runs" "0" "$(runs probe)"
mv "$T/consuming-tree" "$_gl_object"
check "(control) restored history still reports the record consumed" "1" "$(resolve_record "$W" "$RT")"
git clone -q --depth 1 "file://$W" "$T/shallow"
printf '# repaired\n' >> "$T/shallow/$RT"; git -C "$T/shallow" add "$RT"
check "(precondition) the clone is shallow and holds the record" "true .weave/gate-repairs/rt.json" \
    "$(git -C "$T/shallow" rev-parse --is-shallow-repository) $(git -C "$T/shallow" ls-files .weave/gate-repairs)"
check "in a shallow clone the record's use cannot be established, so it admits nothing" "3" \
    "$(resolve_record "$T/shallow" "$RT")"
# The preflight the hook runs before any suite (wv-c909ff) reaches that
# verdict through the same resolver and refuses on it.
_gl_pre=$( cd "$T/shallow" || exit 9
    # shellcheck source=scripts/lib/wv-gate-snapshot.sh
    source "$ROOT/scripts/lib/wv-gate-snapshot.sh"
    # shellcheck source=scripts/lib/wv-gate-lanes.sh
    source "$ROOT/scripts/lib/wv-gate-lanes.sh"
    gate_freeze || exit 8
    gate_roles_check || exit 7
    gate_entry_points_preflight 2>&1; echo "rc=$?" )
has "...and the preflight refuses there, before any suite" "$_gl_pre" "history is shallow or partial"
hasre "...with a refusing status" "$_gl_pre" "^rc=1$"
git config uploadpack.allowFilter true
git clone -q --filter=blob:none "file://$W" "$T/partial" 2>/dev/null
printf '# repaired\n' >> "$T/partial/$RT"; git -C "$T/partial" add "$RT"
check "(precondition) the other clone is partial" "yes" \
    "$(git -C "$T/partial" config --get-regexp '^(extensions\.partialclone|remote\..*\.promisor)$' >/dev/null && echo yes)"
check "...nor in a partial clone, whose missing blobs read as absent paths" "3" \
    "$(resolve_record "$T/partial" "$RT")"
git reset -q --hard "$_gl_rec"
printf '# repaired\n' >> "$RT"; git add "$RT"
check "(control) a record nothing has used admits in full history" "0" "$(resolve_record "$W" "$RT")"
git reset -q --hard "$_gl_rec"
git rm -q "$RT"; git -c core.hooksPath=/dev/null commit -q -m "temporarily absent hook"
git show "$_gl_rec:$RT" > "$RT"; chmod +x "$RT"
git add "$RT"; git -c core.hooksPath=/dev/null commit -q -m "restore unused baseline"
printf '# repaired\n' >> "$RT"; git add "$RT"
check "an absent historical path does not make an unused record unreadable" "0" "$(resolve_record "$W" "$RT")"
git reset -q --hard "$_gl_rec"
git checkout -q -b side
printf '# repaired\n' >> "$RT"; git -c core.hooksPath=/dev/null commit -q -m "side: A to B" -- "$RT"
git checkout -q main; git -c core.hooksPath=/dev/null merge -q -s ours side -m "merge side, keeping A"
printf '# repaired\n' >> "$RT"; git add "$RT"; rm -f "$MARK/probe"
gate
check "...and when it landed on a branch merged back, keeping the baseline" "1" "$RC"
has "...asking for a new record" "$OUT" "To land this exact change, commit a repair record"
check "...refused before any routed suite runs" "0" "$(runs probe)"
git reset -q --hard "$_gl_rec"; git branch -q -D side
git rm -q --cached .weave/gate-repairs/rt.json
record rt "$RT" "$_gl_rt_a" "$_gl_rt_b" 'del(.verification)'
git add .weave/gate-repairs; git -c core.hooksPath=/dev/null commit -q -m "invalid record" -- .weave/gate-repairs
printf '# repaired\n' >> "$RT"; git add "$RT"; rm -f "$MARK/probe"
gate
check "a record without its verification admits nothing" "1" "$RC"
check "...refused before any routed suite runs" "0" "$(runs probe)"
git reset -q --hard "$_gl_s2c_head"; rm -rf .weave/gate-repairs

echo "repair v2 binds modes as well as blobs (wv-7205b0)"
# Equal blobs do not mean equal transitions: this record permits 755 -> 644,
# not an unchanged file in an unrelated commit.
_gl_mode_blob=$(git rev-parse "HEAD:$RT")
record mode "$RT" "$_gl_mode_blob" "$_gl_mode_blob" '.replacement_mode = "100644"'
commit_record mode
chmod -x "$RT"; git add "$RT"
check "(control) an unused mode-only record admits its exact transition" "0" "$(resolve_record "$W" "$RT")"
printf 'unrelated\n' > src/context.txt; git add src/context.txt
git -c core.hooksPath=/dev/null commit -q -m "unrelated context" -- src/context.txt
check "an unrelated same-blob commit does not consume a mode-only record" "0" "$(resolve_record "$W" "$RT")"
gate
check "the hook admits the still-unused mode-only record" "0" "$RC"
git -c core.hooksPath=/dev/null commit -q -m "mode A to B" -- "$RT"
_gl_mode_consumer=$(git rev-parse HEAD)
chmod +x "$RT"; git add "$RT"
git -c core.hooksPath=/dev/null commit -q -m "mode B to A" -- "$RT"
chmod -x "$RT"; git add "$RT"; rm -f "$MARK/probe"
gate
check "a mode-only A-B-A transition cannot reuse its record" "1" "$RC"
check "...refused before routed suites" "0" "$(runs probe)"
# Exercise the hook's mode-read error path without removing readable blobs.
# gate invokes the installed hook directly, so this private PATH wrapper is
# reachable; its marker proves the intended fault was actually injected.
_gl_real_git=$(command -v git)
cat > "$T/bin/git" <<MODE_GIT_EOF
#!/usr/bin/env bash
if [ "\$*" = "--no-replace-objects --literal-pathspecs ls-tree --full-tree $_gl_mode_consumer -- $RT" ]; then
    echo reached > "$MARK/mode-read-fault"
    exit 128
fi
exec "$_gl_real_git" "\$@"
MODE_GIT_EOF
chmod +x "$T/bin/git"
gate
rm -f "$T/bin/git"
check "(precondition) the historical mode read failed at the intended call" "reached" "$(cat "$MARK/mode-read-fault" 2>/dev/null)"
check "a failed mode read cannot revive a consumed record" "1" "$RC"
has "...reported as unreadable history" "$OUT" "could not read the repair records"
git reset -q --hard "$_gl_s2c_head"; rm -rf .weave/gate-repairs

printf '# mode-bound repair\n' >> "$RT"; git add "$RT"
record modes "$RT" "$_gl_mode_blob" "$(git hash-object "$RT")"
commit_record modes
check "(control) a content repair admits at its recorded mode" "0" "$(resolve_record "$W" "$RT")"
chmod -x "$RT"; git add "$RT"; rm -f "$MARK/probe"
gate
check "the same repair bytes at an unrecorded replacement mode are refused" "1" "$RC"
check "...refused before routed suites" "0" "$(runs probe)"
chmod +x "$RT"; git add "$RT"
# Existing v1 records stay in history, but cannot silently acquire inferred
# modes. A new, previously committed v2 record is required for admission.
jq '.version = 1 | del(.baseline_mode, .replacement_mode)' .weave/gate-repairs/modes.json > "$T/v1.json"
mv "$T/v1.json" .weave/gate-repairs/modes.json
commit_record v1
gate
check "a mode-less v1 repair record cannot authorize a future transition" "1" "$RC"
has "...printing a version-2 template" "$OUT" '"version": 2'
git reset -q --hard "$_gl_s2c_head"; rm -rf .weave/gate-repairs

PP=scripts/hooks/pre-push-weave.sh
_gl_pp_a=$(git rev-parse "HEAD:$PP")
printf '# repaired\n' >> "$PP"
record pp "$PP" "$_gl_pp_a" "$(git hash-object "$PP")"
commit_record pp; git add "$PP"
gate
check "(control) a recorded pre-push change naming no gate code through REPO_ROOT is admitted" "0" "$RC"
reset_all; git reset -q --hard "$_gl_s2c_head"; rm -rf .weave/gate-repairs
# A record does not excuse a working-tree reference: plant one, and check it
# is there, since the hook itself no longer carries any.
# shellcheck disable=SC2016  # the hook's text, not this suite's expansion
printf '%s\n' '_gl_planted="$REPO_ROOT/scripts/lib"' >> "$PP"
check "(precondition) the staged pre-push names gate code through REPO_ROOT" "1" \
    "$(grep -cF '"$REPO_ROOT/scripts/lib"' "$PP")"
record pp "$PP" "$_gl_pp_a" "$(git hash-object "$PP")"
commit_record pp; git add "$PP"
gate
check "a recorded change adding a REPO_ROOT gate reference is still refused" "1" "$RC"
has "...for that reference" "$OUT" "$PP names scripts/lib through REPO_ROOT"
reset_all; git reset -q --hard "$_gl_s2c_head"; rm -rf .weave/gate-repairs

echo "shared roles require exact records without replacing the candidate verdict"
_gl_record_start=$(git rev-parse HEAD)
reset_all
jq '.shared = ["src/a.sh"]' "$CONTRACT" > "$T/c.json"; cat "$T/c.json" > "$CONTRACT"; git add "$CONTRACT"
gate
check "a shared role outside enforcement is refused" "1" "$RC"
has "...rather than silently omitted" "$OUT" "shared path src/a.sh is not declared enforcement"
reset_all
jq '.shared = ["scripts/lib/no-shared-file.sh"]' "$CONTRACT" > "$T/c.json"; cat "$T/c.json" > "$CONTRACT"; git add "$CONTRACT"
gate
check "a missing shared file is refused" "1" "$RC"
has "...naming the missing shared file" "$OUT" "shared path scripts/lib/no-shared-file.sh is missing"
reset_all
jq '.shared = false' "$CONTRACT" > "$T/c.json"; cat "$T/c.json" > "$CONTRACT"; git add "$CONTRACT"
gate
check "a malformed shared field cannot mean no shared roles" "1" "$RC"
reset_all
cat > "$T/snip" <<'SHARED_EOF'
. "$_PC_SCRIPTS/lib/wv-fixture-helper.sh"
if ! fixture_src_ok; then echo 'fixture: baseline guard refuses BUG' >&2; exit 1; fi
SHARED_EOF
into_hook "$T/snip"
jq --arg p "$HELPER" '.shared = [$p] | .invoking += [$p]' "$CONTRACT" > "$T/c.json"
cat "$T/c.json" > "$CONTRACT"; commit_nohook "fixture shared role"
_gl_shared_blob=$(git rev-parse "HEAD:$HELPER")
fresh "$HELPER"; gate
check "a shared change without a record is refused" "1" "$RC"
check "...before any routed suite" "0" "$(runs probe)"
record shared "$HELPER" "$_gl_shared_blob" "$(git hash-object "$HELPER")"
git add .weave/gate-repairs; gate
check "a shared record staged alongside the change admits nothing" "1" "$RC"
commit_record shared; gate
check "a prior exact shared record admits a harmless change" "0" "$RC"
has "...while still judging the candidate lane" "$OUT" "candidate lanes: 1 of 1 admitted"
has "...with traceability, not approval" "$OUT" "shared change"
chmod +x "$HELPER"; git add "$HELPER"; gate
check "a shared record at a different mode admits nothing" "1" "$RC"
reset_all
printf '#!/usr/bin/env bash\nfixture_src_ok() { return 1; }\n' > "$HELPER"; git add "$HELPER"
record shared "$HELPER" "$_gl_shared_blob" "$(git hash-object "$HELPER")"
commit_record shared; gate
check "a recorded but broken shared candidate is refused" "1" "$RC"
has "...by its own lane, not replaced by the record" "$OUT" "candidate version of $HELPER does not admit"
reset_all
jq '.shared = []' "$CONTRACT" > "$T/c.json"; cat "$T/c.json" > "$CONTRACT"; git add "$CONTRACT"
gate
check "shared-to-enforcement demotion needs its own contract record" "1" "$RC"
record roles "$CONTRACT" "$(git rev-parse "HEAD:$CONTRACT")" "$(git hash-object "$CONTRACT")"
commit_record roles; gate
check "an exact prior contract record admits that demotion" "0" "$RC"
has "...with the contract record named" "$OUT" ".weave/gate-repairs/roles.json"
git reset -q --hard "$_gl_record_start"; rm -rf .weave/gate-repairs

echo "retirement records admit deletion only, once, with the baseline guard active"
reset_all
into_hook "$T/snip"; commit_nohook "fixture retiring guard"
_gl_retire_base=$(git rev-parse HEAD)
_gl_retire_blob=$(git rev-parse "HEAD:$HELPER")
git rm -q "$HELPER"; gate
check "an unrecorded enforcement deletion is refused" "1" "$RC"
check "...before any routed suite" "0" "$(runs probe)"
record retire "$HELPER" "$_gl_retire_blob" "" '.replacement_mode = "000000"'
commit_record retire; gate
check "a repair record cannot substitute for a retirement record" "1" "$RC"
record retire "$HELPER" "$_gl_retire_blob" "" '.kind = "retirement" | .replacement_mode = "000000"'
git add .weave/gate-repairs; gate
check "a retirement record staged with deletion admits nothing" "1" "$RC"
commit_record retire; gate
check "a prior exact retirement record admits deletion" "0" "$RC"
has "...explicitly naming retirement" "$OUT" "retirement record"
check "...after the protected routed suite ran" "1" "$(runs probe)"
printf '#!/bin/sh\necho BUG\n' > src/a.sh; git add src/a.sh; gate
check "retirement never bypasses the baseline subject check" "1" "$RC"
has "...with the baseline refusal preserved" "$OUT" "fixture: baseline guard refuses BUG"
git checkout -q HEAD -- src/a.sh
git show "$_gl_retire_base:$HELPER" > "$HELPER"
printf '\nfixture_src_ok() { return 1; }\n' >> "$HELPER"; git add "$HELPER"; gate
check "a retirement record does not excuse a broken rewrite" "1" "$RC"
has "...which still has its candidate lane" "$OUT" "candidate version of $HELPER does not admit"
git rm -q -f "$HELPER"; commit_nohook "fixture retired"
_gl_retire_tree=$(git rev-parse HEAD:scripts/lib)
git show "$_gl_retire_base:$HELPER" > "$HELPER"; commit_nohook "fixture restored"
# Keep the index's missing-helper subtree distinct from the historical one:
# hiding the latter must exercise history, not an unreadable candidate.
printf 'later tree\n' > scripts/lib/retire-later-fixture.txt
git add scripts/lib/retire-later-fixture.txt
git rm -q "$HELPER"
check "a retirement stays consumed after deletion and restoration" "1" "$(resolve_record "$W" "$HELPER" retirement)"
_gl_object=".git/objects/${_gl_retire_tree:0:2}/${_gl_retire_tree:2}"
mv "$_gl_object" "$T/retired-tree"
check "unreadable retirement history is unknown, never unused" "2" "$(resolve_record "$W" "$HELPER" retirement)"
mv "$T/retired-tree" "$_gl_object"
check "(control) readable retirement history remains consumed" "1" "$(resolve_record "$W" "$HELPER" retirement)"
_gl_consumed_rc=$(
    source "$ROOT/scripts/lib/wv-gate-snapshot.sh"
    source "$ROOT/scripts/lib/wv-gate-lanes.sh"
    gate_freeze || exit 8
    wait() { return 127; }
    rc=0; gate_repair_record "$HELPER" retirement >/dev/null 2>&1 || rc=$?
    printf '%s\n' "$rc"
)
check "readable consumed history survives unavailable wait bookkeeping" "1" "$_gl_consumed_rc"
# A listing can emit valid records and still fail. Consumption checks launch
# their own processes, so their status must not replace the listing's status.
_gl_listing_rc=$(
    cd "$W" || exit 9
    source "$ROOT/scripts/lib/wv-gate-snapshot.sh"
    source "$ROOT/scripts/lib/wv-gate-lanes.sh"
    gate_freeze || exit 8
    git() {
        if [ "${1:-}" = ls-tree ] && [ "${2:-}" = -r ] \
            && [ "${3:-}" = --full-tree ] && [ "${6:-}" = .weave/gate-repairs ]; then
            command git "$@" || return
            return 73
        fi
        command git "$@"
    }
    gate_repair_record "$HELPER" retirement >/dev/null 2>&1
    echo $?
)
check "a failed record listing stays unknown after consumption checks" "2" "$_gl_listing_rc"
git reset -q --hard "$_gl_record_start"; rm -rf .weave/gate-repairs

echo "HEAD's role contract decides"
reset_all; git rm -q "$CONTRACT"; stage_src
gate
check "deleting the contract is refused" "1" "$RC"
has "...as retiring the boundary" "$OUT" "removes the gate role contract"

reset_all; jq '.invoking -= ["scripts/wv"]' "$CONTRACT" > "$T/c.json" && cat "$T/c.json" > "$CONTRACT"; git add "$CONTRACT"
gate
check "dropping an invoking file is refused" "1" "$RC"
has "...naming it" "$OUT" "drops scripts/wv"

reset_all; jq '.enforcement = ["scripts/hooks/"]' "$CONTRACT" > "$T/c.json" && cat "$T/c.json" > "$CONTRACT"; git add "$CONTRACT"
gate
check "narrowing enforcement is refused" "1" "$RC"
has "...naming the prefix" "$OUT" "drops scripts/"

reset_all; printf '{\n' > "$CONTRACT"; git add "$CONTRACT"
gate
check "an invalid staged contract is refused" "1" "$RC"
has "...as invalid" "$OUT" "staged gate role contract ($CONTRACT) is not valid"

reset_all
# shellcheck disable=SC2016  # the hook's text, not this suite's expansion
printf '%s\n' ': "$REPO_ROOT/undeclared/thing"' > "$T/snip"; into_hook "$T/snip"
gate
check "a dependency the contract does not declare is refused" "1" "$RC"
has "...naming it" "$OUT" "names undeclared/thing (index), which HEAD's gate role contract does not declare"
jq '.external["undeclared/thing"] = "fixture"' "$CONTRACT" > "$T/c.json" && cat "$T/c.json" > "$CONTRACT"; git add "$CONTRACT"
gate
check "declaring it in the same commit does not admit it" "1" "$RC"

reset_all
# shellcheck disable=SC2016
printf '%s\n' ': "$REPO_ROOT/scripts/lib/no-such-file.sh"' > "$T/snip"; into_hook "$T/snip"
gate
check "an enforcement dependency that does not exist is refused" "1" "$RC"
has "...as unresolved" "$OUT" "scripts/lib/no-such-file.sh, an enforcement path the index tree does not have (unresolved)"


reset_all
echo ""
echo "gate roles: $pass/$run passed"
[ "$pass" -eq "$run" ]
