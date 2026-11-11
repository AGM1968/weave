#!/usr/bin/env bash
# Sourced by test-gate-lanes.sh inside its private synthetic repository.
# These files are created here, not read from the checkout or release. Keep
# their real gate-role names: the hook's external callers dispatch by path.

# The four external enforcement files and the two checks that read them (lane
# review S1, wv-a75d98; R-a: each is copied for its one check and is absent
# from the envelope every other stage runs in).
_ep_files=(tests/test-memory-projection-parity.sh tests/test-shipped-test-refs.sh
    tests/lib/release-leak-pattern.ere build-release.sh)
_ep_files_json=$(printf '%s\n' "${_ep_files[@]}" | jq -R . | jq -cs .)
# _ep_checkers <memory-checker> <leak-checker> — fixture checkers that record
# what their private directory holds, and refuse when a token says so.
_ep_checkers() {
    cat > tests/test-memory-projection-parity.sh <<'MEMORY_EOF'
#!/usr/bin/env bash
[ "${1:-}" = --subject ] || exit 0
d=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
seen=alone
for f in build-release.sh tests/lib/release-leak-pattern.ere tests/test-shipped-test-refs.sh; do
    [ ! -e "$d/$f" ] || seen=others
done
printf 'memory:@CHECKER@:%s:%s\n' "$seen" "$([ -x "$d/scripts/wv" ] && echo wv || echo nowv)" >> "@MARK@/external"
[ @CHECKER@ != refuse ] || { echo 'parity fixture refuses' >&2; exit 1; }
MEMORY_EOF
    cat > tests/test-shipped-test-refs.sh <<'LEAK_EOF'
#!/bin/sh
[ "${1:-}" = --scan ] || exit 0
policy=$4
pat=$(cat "$policy/tests/lib/release-leak-pattern.ere")
bld=$(sed -n 's/^# builder //p' "$policy/build-release.sh")
seen=alone
[ ! -e "$policy/tests/test-memory-projection-parity.sh" ] || seen=others
printf 'leak:@CHECKER@:%s:%s:%s\n' "$pat" "$bld" "$seen" >> "@MARK@/external"
case "@CHECKER@ $pat $bld" in *refuse*) echo 'release fixture policy refuses' >&2; exit 1 ;; esac
LEAK_EOF
    sed -i "s|@CHECKER@|$1|g; s|@MARK@|$MARK|g" tests/test-memory-projection-parity.sh
    sed -i "s|@CHECKER@|$2|g; s|@MARK@|$MARK|g" tests/test-shipped-test-refs.sh
}
# _ep_roles <shared|undeclared|malformed|invoking> — HEAD's contract for the four files.
# None is a shared product file here: a change to one would need a record,
# which the lane cases are not about.
_ep_roles() {
    local filter
    case "$1" in
        shared) filter='.check_authority = {"release-leak-guard": ["build-release.sh",
                    "tests/lib/release-leak-pattern.ere", "tests/test-shipped-test-refs.sh"],
                    "memory-projection": ["tests/test-memory-projection-parity.sh"]}' ;;
        undeclared) filter='del(.check_authority)' ;;
        # Every file named, but memory-projection also claims the builder it
        # does not read: the whole declaration is ignored.
        malformed) filter='.check_authority = {"release-leak-guard": ["build-release.sh",
                    "tests/lib/release-leak-pattern.ere", "tests/test-shipped-test-refs.sh"],
                    "memory-projection": ["tests/test-memory-projection-parity.sh", "build-release.sh"]}' ;;
        invoking) filter='del(.check_authority) | .invoking += $f' ;;
    esac
    jq --argjson f "$_ep_files_json" ".enforcement |= (. + (\$f - .)) | .shared = [] | $filter" \
        "$CONTRACT" > "$T/c.json" && cat "$T/c.json" > "$CONTRACT"
}
# _ep_setup <roles> — commit the base checkers, policy and contract.
_ep_setup() {
    reset_all; rm -f "$MARK/external"
    mkdir -p tests/lib
    _ep_checkers checker-base checker-base
    printf 'policy-base\n' > tests/lib/release-leak-pattern.ere
    printf '#!/bin/sh\n# builder base\n' > build-release.sh
    _ep_roles "$1"
    grep -qx 'CLAUDE.md = tests/test-memory-projection-parity.sh' .weave/test-map.conf \
        || printf 'CLAUDE.md = tests/test-memory-projection-parity.sh\n' >> .weave/test-map.conf
    commit_nohook "external policy fixture ($1)"
}
# _ep_trigger — stage what switches both checks on: an active memory change
# (the parity check) and a tests/ change (the leak guard), routing the probe.
_ep_trigger() {
    n=$((n+1))
    printf '{"id":"wv-%06d","text":"fixture memory %s","metadata":{"type":"memory","mem_status":"active"}}\n' "$n" "$n" \
        >> .weave/nodes.jsonl
    git add .weave/nodes.jsonl
    fresh tests/test-probe.sh
}
_ep_marks() { sort "$MARK/external" 2>/dev/null; }
_ep_unset() { git reset -q --hard HEAD~1; rm -f "${_ep_files[@]}" "$MARK/external" "$MARK/probe"; }

echo "R-a (wv-a75d98): each external check sees only its own files, none in the envelope"
_ep_setup shared
_ep_trigger; gate
check "(control) unchanged external enforcement admits a commit running both checks" "0" "$RC"
check "...each check holding only its own files, with scripts/ beside them" \
    $'leak:checker-base:policy-base:base:alone\nmemory:checker-base:alone:wv' "$(_ep_marks)"
_ep_unset

_ep_setup shared
cat > "$T/snip" <<'SNIP_EOF'
cat "$_PC_SCRIPTS/../build-release.sh" > /dev/null || { echo "fixture: build-release.sh is not in the envelope" >&2; exit 1; }
SNIP_EOF
into_hook "$T/snip"; commit_nohook "a stage that reads an external file from the envelope"
stage_src; gate
check "a stage other than the declared check that reads an external file fails" "1" "$RC"
has "...finding it absent from the envelope" "$OUT" "fixture: build-release.sh is not in the envelope"
git reset -q --hard HEAD~1; _ep_unset

_ep_setup shared
_ep_checkers checker-candidate checker-base
printf 'policy-candidate\n' > tests/lib/release-leak-pattern.ere
git add tests/test-memory-projection-parity.sh tests/lib/release-leak-pattern.ere
_ep_trigger; gate
check "two changed external files admit in separate lanes" "0" "$RC"
has "...with both lanes admitted" "$OUT" "candidate lanes: 2 of 2 admitted"
check "...each lane runs its own file's check with only its own file changed" \
    $'leak:checker-base:policy-base:base:alone\nleak:checker-base:policy-base:base:alone\nleak:checker-base:policy-candidate:base:alone\nmemory:checker-base:alone:wv\nmemory:checker-base:alone:wv\nmemory:checker-candidate:alone:wv' \
    "$(_ep_marks)"
# W1: the suites ran once, in the protected pass; both lanes shared them.
check "...sharing the protected pass's suites (the probe ran once)" "1" "$(runs probe)"
hasre "...the parity lane reusing" "$OUT" "candidate lane tests/test-memory-projection-parity\.sh: reused HEAD's suite results"
hasre "...the pattern lane reusing" "$OUT" "candidate lane tests/lib/release-leak-pattern\.ere: reused HEAD's suite results"
_ep_unset

_ep_setup shared
_ep_checkers checker-base checker-candidate
printf '#!/bin/sh\n# builder candidate\n' > build-release.sh
git add tests/test-shipped-test-refs.sh build-release.sh
_ep_trigger; gate
check "a changed builder and release checker admit in their own lanes" "0" "$RC"
check "...each rerunning the leak guard with its own file" \
    $'leak:checker-base:policy-base:base:alone\nleak:checker-base:policy-base:candidate:alone\nleak:checker-candidate:policy-base:base:alone' \
    "$(_ep_marks | grep '^leak:')"
check "...and sharing the suites (the probe ran once)" "1" "$(runs probe)"
hasre "...the builder lane reusing" "$OUT" "candidate lane build-release\.sh: reused HEAD's suite results"
hasre "...the release checker lane reusing" "$OUT" "candidate lane tests/test-shipped-test-refs\.sh: reused HEAD's suite results"
check "...and the gate record says so" "build-release.sh:true tests/test-shipped-test-refs.sh:true" \
    "$(tail -1 "$WV_GATE_LOG" | jq -r '[.lanes[] | "\(.path):\(.reused)"] | sort | join(" ")')"
_ep_unset

echo "W3: a planted break in each external file is still refused by its own lane"
for _ep_case in "tests/lib/release-leak-pattern.ere:pattern" "build-release.sh:builder" \
    "tests/test-shipped-test-refs.sh:checker" "tests/test-memory-projection-parity.sh:parity"; do
    _ep_path=${_ep_case%%:*}
    _ep_setup shared
    case "${_ep_case#*:}" in
        pattern) printf 'refuse\n' > "$_ep_path" ;;
        builder) printf '#!/bin/sh\n# builder refuse\n' > "$_ep_path" ;;
        checker) _ep_checkers checker-base refuse ;;
        parity) _ep_checkers refuse checker-base ;;
    esac
    git add "$_ep_path"; _ep_trigger; gate
    check "a breaking candidate $_ep_path is refused" "1" "$RC"
    has "...by its own lane" "$OUT" "the candidate version of $_ep_path does not admit"
    _ep_unset
done

echo "W6: combined changes, each lane applying its own file's rule"
_ep_setup shared
printf '#!/bin/sh\n# builder candidate\n' > build-release.sh; git add build-release.sh
fresh scripts/cmd/wv-cmd-gate.sh; _ep_trigger; gate
check "wv-cmd-gate.sh and build-release.sh staged together are admitted" "0" "$RC"
hasre "...the builder lane sharing the suites" "$OUT" "candidate lane build-release\.sh: reused HEAD's suite results"
hasre "...the wv-cmd-gate.sh lane rerunning them (R-b)" "$OUT" "candidate lane scripts/cmd/wv-cmd-gate\.sh: reran its suites"
check "...so the probe ran in the protected pass and that lane only" "2" "$(runs probe)"
reset_all
printf '#!/bin/sh\n# builder refuse\n' > build-release.sh
printf 'policy-candidate\n' > tests/lib/release-leak-pattern.ere
git add build-release.sh tests/lib/release-leak-pattern.ere; _ep_trigger; gate
check "a broken builder staged with another external file is refused" "1" "$RC"
has "...by the builder's lane" "$OUT" "the candidate version of build-release.sh does not admit"
_ep_unset

echo "N6: an external file the contract does not declare, or declares malformed, reruns its suites"
for _ep_roles_mode in undeclared malformed invoking; do
    _ep_setup "$_ep_roles_mode"
    printf '#!/bin/sh\n# builder candidate\n' > build-release.sh; git add build-release.sh
    _ep_trigger; gate
    check "($_ep_roles_mode) a changed builder is admitted" "0" "$RC"
    hasre "...its lane rerunning the suites" "$OUT" "candidate lane build-release\.sh: reran its suites"
    check "...so the probe ran twice" "2" "$(runs probe)"
    [ "$_ep_roles_mode" != malformed ] \
        || has "...the gate saying HEAD's declaration is ignored" "$OUT" "HEAD's gate role contract's check_authority is malformed"
    _ep_unset
done

echo "rule 1: check_authority only narrows without a record; malformed means rerun"
_ep_setup undeclared
_ep_roles shared
git add "$CONTRACT"; stage_src; gate
check "a contract that starts sharing external files without a record is refused" "1" "$RC"
has "...as a weakening of their full rerun" "$OUT" "drops the full rerun of"
reset_all
_ep_roles malformed
git add "$CONTRACT"; stage_src; gate
check "a malformed check_authority is not refused as an invalid contract" "0" "$RC"
has "...the gate saying it is ignored" "$OUT" "the staged gate role contract's check_authority is malformed"
_ep_unset

echo "the real parity and release callers execute their candidate policy"
reset_all
mkdir -p tests/lib
printf '#!/bin/sh\nexit 0\n' > tests/test-memory-projection-parity.sh
printf '# fixture builder\n' > build-release.sh
printf 'allow\n' > tests/lib/release-leak-pattern.ere
cat > tests/test-shipped-test-refs.sh <<'POLICY_EOF'
#!/bin/sh
[ "${1:-}" = --scan ] || exit 0
policy=${4:-$2}
if ! grep -qx allow "$policy/tests/lib/release-leak-pattern.ere"; then
    echo 'release fixture policy refuses' >&2
    exit 1
fi
POLICY_EOF
jq '.enforcement += ["tests/test-memory-projection-parity.sh", "tests/test-shipped-test-refs.sh",
                       "tests/lib/release-leak-pattern.ere", "build-release.sh"]
    | .invoking += ["tests/test-memory-projection-parity.sh", "tests/test-shipped-test-refs.sh",
                    "tests/lib/release-leak-pattern.ere", "build-release.sh"]
    | .shared = ["build-release.sh"]' "$CONTRACT" > "$T/c.json" && cat "$T/c.json" > "$CONTRACT"
printf 'CLAUDE.md = tests/test-memory-projection-parity.sh\n' >> .weave/test-map.conf
commit_nohook "real policy caller fixture"
stage_src; fresh tests/test-probe.sh; gate
check "(control) baseline release policy admits a healthy subject" "0" "$RC"

reset_all
printf '#!/bin/sh\n[ "${1:-}" = --scan ] || exit 0\nexit 1\n' > tests/test-shipped-test-refs.sh
git add tests/test-shipped-test-refs.sh; gate
check "a rejecting candidate release checker is actually run" "1" "$RC"
has "...in its own lane, not substituted into the protected pass" "$OUT" \
    "the candidate version of tests/test-shipped-test-refs.sh does not admit"

reset_all
printf '#!/bin/sh\nexit 0\n' > tests/test-shipped-test-refs.sh
printf 'refuse\n' > tests/lib/release-leak-pattern.ere
git add tests/test-shipped-test-refs.sh tests/lib/release-leak-pattern.ere; gate
check "a weakened checker cannot hide another policy file's refusal" "1" "$RC"
has "...the pattern lane retains the baseline checker and runs its own pattern" "$OUT" \
    "the candidate version of tests/lib/release-leak-pattern.ere does not admit"

reset_all
printf '#!/bin/sh\n[ "${1:-}" = --subject ] || exit 0\nexit 1\n' > tests/test-memory-projection-parity.sh
printf '%s\n' '{"id":"wv-000001","text":"fixture memory","metadata":{"type":"memory","mem_status":"active"}}' \
    >> .weave/nodes.jsonl
git add tests/test-memory-projection-parity.sh .weave/nodes.jsonl; gate
check "a rejecting candidate parity checker is actually run" "1" "$RC"
has "...in its own lane after the baseline parity check admitted" "$OUT" \
    "the candidate version of tests/test-memory-projection-parity.sh does not admit"
git reset -q --hard HEAD~1
rm -f tests/test-memory-projection-parity.sh tests/test-shipped-test-refs.sh tests/lib/release-leak-pattern.ere build-release.sh
