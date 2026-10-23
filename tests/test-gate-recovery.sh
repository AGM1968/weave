#!/usr/bin/env bash
# Gate recovery (S2c, wv-0af8f0; spec docs/findings/gate-s2c-recovery-2026-10-14).
#
# When HEAD's committed gate refuses every commit, the installed dispatcher
# admits, after HEAD's gate refused it,
#   R1  a commit adding one recovery record (and graph state besides), and
#   R2  a later commit making exactly that record's transitions, judged by the
#       recorded replacement tree after a negative control.
# Every case drives a real `git commit` in an isolated repository whose hooks
# are installed as install.sh installs them: pre-commit, and the
# reference-transaction hook that binds a commit to the tree its gate judged.
# Recovery commits never set --no-verify, WV_SKIP_PRECOMMIT or core.hooksPath.
# Fixture history standing for commits made elsewhere (a bypass, a fetch) is
# written with the hooks off (commit_nohook), as such history arrives.
#
# HEAD's refusal is a tripwire: a hook that admitted its own commit and refuses
# every later one while its own copy of the fixture helper is not executable.
# It lands through the gate. Pinned here: the R1 -> R2 flow and its records;
# R1 refusals; record validation before any gate runs (V1); one-use consumption
# by exact (mode, blob) transitions (A6, M1, M2); the execution tree versus the
# history base (B1); the negative control (C1-C3); the replacement's binding
# verdict and acknowledgement (R2v, B2); stability during each run (S1, S2);
# publication binding by the dispatcher (S3, L2); the recovery row failing
# closed (L1); the bound and its process group (T1-T3); a healthy HEAD's
# refusal overridden by a prior record, visibly (H1, the accepted D3a
# capability); shallow and partial clones (H2); the installed copy deciding
# (D1t); and the graph-state list matching the library's.
set -uo pipefail
export WV_TEST_SUITE=1
export WV_CALL_SOURCE=test

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }
# admitted <label> — the last try was admitted; on failure, show why not.
admitted() { if [ "$RC" -eq 0 ]; then ok "$1"; else bad "$1" "refused (rc $RC): $(tail -15 <<< "$OUT")"; fi; }
has()   { if grep -qF -- "$3" <<< "$2"; then ok "$1"; else bad "$1" "missing [$3] in: $(tail -12 <<< "$2")"; fi; }
hasnt() { if grep -qF -- "$3" <<< "$2"; then bad "$1" "unexpected [$3]"; else ok "$1"; fi; }

T=$(mktemp -d /tmp/wv-gate-recovery-XXXXXX)
# Process names unique to this run: parallel gate lanes run this suite at the
# same time, and a shared name let one run's pgrep/pkill see another's.
SL_HANG="60.$$" SL_DETACH="47.$$" SL_GROUP="30.$$"
cleanup() { pkill -fx "sleep $SL_DETACH" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
unset WV_GATE_BASE WV_GATE_TREE WV_GATE_PHASE WV_GATE_ID WV_GATE_CONTEXT WV_HOOK_REEXEC
unset WV_SKIP_PRECOMMIT WV_PRECOMMIT_RUNNING WV_GATE_RECOVERY_TIMEOUT PYTHONPATH

REAL_PS=$(command -v ps) REAL_GIT=$(command -v git)
mkdir -p "$T/bin" "$T/cfg" "$T/marks"
ln -s "$ROOT/scripts/wv" "$T/bin/wv"
MARK="$T/marks"; W="$T/work"
# ps, wrapped: the dispatcher's binding reads the git process's start time
# after its last stability check, so staging there lands in the window the
# reference-transaction hook closes (as tests/test-gate-snapshot.sh wraps wv).
cat > "$T/bin/ps" <<PS_EOF
#!/bin/sh
case " \$* " in
    *" lstart= "*)
        caller=\$(tr '\0' ' ' < /proc/\$PPID/cmdline 2>/dev/null)
        case "\$caller" in
            *.git/hooks/pre-commit*)
                if [ -f "$MARK/stage-at-bind" ]; then
                    rm -f "$MARK/stage-at-bind"
                    echo raced > "$W/src/raced.txt"; git -C "$W" add src/raced.txt
                fi ;;
        esac ;;
esac
exec "$REAL_PS" "\$@"
PS_EOF
chmod +x "$T/bin/ps"
# git, wrapped: with fail-mode-read set, the consumption walk's mode reads (the
# only ls-tree calls made with both --no-replace-objects and
# --literal-pathspecs) fail as an unreadable object store would, status 128.
# git puts its exec-path first in a hook's PATH, so this reaches only calls
# made from this shell (the unit case below), not the installed hook.
cat > "$T/bin/git" <<GIT_EOF
#!/bin/sh
if [ -f "$MARK/fail-mode-read" ]; then
    case " \$* " in
        *" --no-replace-objects --literal-pathspecs ls-tree "*)
            echo "fatal: injected mode-read failure" >&2; exit 128 ;;
    esac
fi
exec "$REAL_GIT" "\$@"
GIT_EOF
chmod +x "$T/bin/git"
export PATH="$T/bin:$PATH" WV_LIB_DIR="$ROOT/scripts"
export WV_HOT_ZONE="$T" WV_DB="$T/brain.db" WV_CONFIG_DIR="$T/cfg" WV_PROJECT_DIR="$W"
export WV_SUITE_LOG="$T/suite_runs.jsonl" WV_GATE_LOG="$T/gate_runs.jsonl"
export WV_AUTO_SYNC=0 WV_AUTO_CHECKPOINT=0 WV_REQUIRE_LEARNING=0 WV_RUN_CACHE=0

git init -q -b main "$W"; cd "$W" || exit 1
git config user.name "Gate Test"; git config user.email gate@example.com
git config commit.gpgsign false; git config tag.gpgSign false
_gr_skip=()
git -C "$ROOT" ls-files -z -- scripts "${_gr_skip[@]}" \
    | tar -C "$ROOT" --null -T - -cf - | tar -xf -
# This synthetic repository holds only scripts/; external cases declare their own roles later.
jq '.enforcement = ["scripts/"] | .invoking |= map(select(startswith("scripts/")))
    | .entry_points |= with_entries(select(.key | startswith("scripts/"))) | .shared = []' \
    scripts/hooks/gate-roles.json > "$T/fixture-roles.json" &&
    cat "$T/fixture-roles.json" > scripts/hooks/gate-roles.json
mkdir -p src tests .weave
# The routed suite: it counts its runs, notes the base it was given, and fails
# a hook staged as WEAKENED, which is how a healthy HEAD refuses a weakened
# replacement (H1).
cat > tests/test-probe.sh <<PROBE_EOF
#!/usr/bin/env bash
echo run >> "$MARK/probe"
echo "\${WV_GATE_BASE:-}" > "$MARK/probe-base"
hook=\$(git cat-file -p "\$WV_GATE_TREE:scripts/hooks/pre-commit-weave.sh" 2>/dev/null)
if grep -qx '# WEAKENED' <<< "\$hook"; then
    echo "probe: the staged hook is weakened" >&2
    exit 1
fi
exit 0
PROBE_EOF
chmod +x tests/test-probe.sh
cat > .weave/test-map.conf <<'MAP_EOF'
[map]
src/a.sh = tests/test-probe.sh
scripts/ = tests/test-probe.sh
tests/test-probe.sh = tests/test-probe.sh
MAP_EOF
printf '#!/bin/sh\necho a\n' > src/a.sh
printf '# graph trail\n' > .weave/trails.md
cp "$ROOT/.shellcheckrc" .shellcheckrc 2>/dev/null || true
printf '#!/usr/bin/env bash\nfixture_helper() { :; }\n' > scripts/lib/wv-fixture-helper.sh
chmod 644 scripts/lib/wv-fixture-helper.sh
git add -A && git -c core.hooksPath=/dev/null commit -q -m fixture
wv add "gate recovery fixture node" --status=active --force --criteria="c1|c2" --risks=low >/dev/null 2>&1
install -m 755 "$ROOT/scripts/hooks/pre-commit-weave.sh" .git/hooks/pre-commit
install -m 755 "$ROOT/scripts/hooks/reference-transaction-weave.sh" .git/hooks/reference-transaction

HOOK=scripts/hooks/pre-commit-weave.sh
HELPER=scripts/lib/wv-fixture-helper.sh
ORIG="$T/hook.orig"; cp "$HOOK" "$ORIG"
ROLES="# The role contract (S2b; boundary rules 1 and 2)"
AFTER_ROLES="# _pc_git_pid — the git process"

# try <message> — a real commit of what is staged.
try() { OUT=$(git commit -q -m "$1" 2>&1); RC=$?; }
commit_nohook() { git -c core.hooksPath=/dev/null commit -q -m "$1"; }
head() { git rev-parse HEAD; }
entry() { git ls-tree "$1" -- "$2" | awk '{ print $1, $3 }'; }
blob() { git hash-object -w "$1"; }
runs() { if [ -f "$MARK/$1" ]; then wc -l < "$MARK/$1" | tr -d ' '; else echo 0; fi; }
lines() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }
reset_all() {
    git reset -q; git checkout -q -- .; git clean -qfd -- scripts src .weave/gate-repairs
    rm -f "$MARK/poke-head" "$MARK/poke-ctl" "$MARK/stage-at-bind"
}
n=0
stage_src() { n=$((n+1)); printf '#!/bin/sh\necho a-%s\n' "$n" > src/a.sh; git add src/a.sh; }
stage_trail() { n=$((n+1)); printf -- '- trail %s\n' "$n" >> .weave/trails.md; git add .weave/trails.md; }
# with_lines <src> <before> <dst> <line>... — <src> with <line>s inserted
# before its first line starting with <before>.
with_lines() {
    local src=$1 pat=$2 dst=$3
    shift 3
    ADD="$(printf '%s\n' "$@")" PAT="$pat" awk \
        'index($0, ENVIRON["PAT"]) == 1 && !done { print ENVIRON["ADD"]; done = 1 } { print }' "$src" > "$dst"
    grep -qF -- "$1" "$dst" || { echo "fixture: could not insert into $src" >&2; exit 1; }
}
# record <file> <reason> <path> <bmode> <bblob> <rmode> <rblob> [...] — a
# recovery record staged at .weave/gate-repairs/<file>.
record() {
    local f=$1 reason=$2 paths='{}'
    shift 2
    while [ "$#" -ge 5 ]; do
        paths=$(jq -c --arg p "$1" --arg bm "$2" --arg bo "$3" --arg rm "$4" --arg ro "$5" \
            '. + {($p): {baseline_mode: $bm, baseline: $bo, replacement_mode: $rm, replacement: $ro}}' <<< "$paths")
        shift 5
    done
    mkdir -p .weave/gate-repairs
    jq -n --argjson paths "$paths" --arg r "$reason" \
        '{version: 1, kind: "recovery", paths: $paths, reason: $r, verification: "tests/test-gate-recovery.sh"}' \
        > ".weave/gate-repairs/$f"
    git add ".weave/gate-repairs/$f"
}
last_rec_row() { grep '"phase":"recovery"' "$WV_GATE_LOG" 2>/dev/null | tail -1; }
rec_rows() { grep -c '"phase":"recovery"' "$WV_GATE_LOG" 2>/dev/null || true; }
# refused <label> <expected text> — the last try was refused, HEAD stayed at $H0.
refused() {
    if [ "$RC" -ne 0 ]; then ok "$1 is refused"; else bad "$1 is refused" "admitted: $(tail -6 <<< "$OUT")"; fi
    has "...$2" "$OUT" "$2"
    check "...HEAD unchanged" "$H0" "$(head)"
}

check "(precondition) hooks are not disabled: no core.hooksPath" "" "$(git config --get core.hooksPath || true)"

echo "the installed copy's graph-state list is the library's"
_gr_lib=$(bash -c '. "$1/scripts/lib/wv-checkpoint-ci.sh" >/dev/null 2>&1; printf "%s\n" "${WV_GRAPH_STATE_PATHS[@]}"' _ "$ROOT")
_gr_hook=$(bash -c 'eval "$(sed -n "/^_PCR_GRAPH_STATE=(/,/)$/p" "$1")"; printf "%s\n" "${_PCR_GRAPH_STATE[@]}"' _ "$ROOT/$HOOK")
check "_PCR_GRAPH_STATE equals WV_GRAPH_STATE_PATHS" "$_gr_lib" "$_gr_hook"

echo "control: a healthy HEAD admits an ordinary commit, no recovery"
stage_src; try "ordinary"
admitted "(control) an ordinary commit is admitted"
hasnt "...without any recovery notice" "$OUT" "recovery"
: > "$T/no-such-dir-file"
stage_src; OUT=$(WV_GATE_LOG="$T/no-such-dir-file/gate.jsonl" git commit -q -m "ordinary, log unwritable" 2>&1); RC=$?
admitted "(L1 control) with the gate log unwritable an ordinary commit is still admitted"

# A1: lands through the gate (its candidate lane's base lacks the line).
TRIP="$T/hook.trip"
with_lines "$ORIG" "$ROLES" "$TRIP" \
    '# TRIPWIRE' \
    "if [ -f \"$MARK/poke-head\" ]; then _fx=\$(cat \"$MARK/poke-head\"); rm -f \"$MARK/poke-head\"; eval \"\$_fx\"; fi" \
    'if git cat-file -p "$WV_GATE_BASE:scripts/hooks/pre-commit-weave.sh" 2>/dev/null | grep -qx "# TRIPWIRE" \' \
    '    && [ ! -x "$_PC_SCRIPTS/lib/wv-fixture-helper.sh" ]; then' \
    '    echo "✗ fixture tripwire: this gate refuses every commit" >&2' \
    '    exit 1' \
    'fi'
cp "$TRIP" "$HOOK"; git add "$HOOK"; try "land a conditional refusal"
admitted "(A1 setup) the tripwire lands through the gate"
B_TRIP=$(entry HEAD "$HOOK"); B_HELPER=$(entry HEAD "$HELPER")
read -r bm_h bo_h <<< "$B_TRIP"; read -r bm_l bo_l <<< "$B_HELPER"

echo "A1: HEAD's gate now refuses every commit"
H0=$(head); stage_src; try "after the tripwire"
refused "(A1) an ordinary commit" "fixture tripwire"
hasnt "...with no recovery involved" "$OUT" "recovery"
reset_all

# The main replacement: the original hook, writing a mark once its role check
# has passed (so the negative control, refused at the role check, never
# does), plus a changed helper: two paths, judged as one unit.
REPL="$T/hook.repl"
with_lines "$ORIG" "$AFTER_ROLES" "$REPL" "echo exec >> \"$MARK/replacement\""
printf '#!/usr/bin/env bash\nfixture_helper() { return 0; }\n' > "$T/helper.repl"
ro_h=$(blob "$REPL"); ro_l=$(blob "$T/helper.repl")
MAIN=(.weave/gate-repairs/recover-main.json)
main_record() { record recover-main.json "the tripwire refuses every commit" \
    "$HOOK" "$bm_h" "$bo_h" "$bm_h" "$ro_h" "$HELPER" "$bm_l" "$bo_l" "$bm_l" "$ro_l"; }

echo "R1 refusals: what a record commit may not be (V1: checked before any gate runs)"
H0=$(head)
main_record; stage_src; try "record plus product"
refused "a record commit that also changes product code" "carries only the record and graph state, and this one also changes src/a.sh"
reset_all
main_record; cp ".weave/gate-repairs/recover-main.json" .weave/gate-repairs/second.json; git add .weave/gate-repairs; try "two records"
refused "a commit adding two records" "adds exactly one record, and this one changes 2"
reset_all
v1() {  # v1 <label> <jq edit> <expected>
    reset_all; main_record
    jq "$2" "${MAIN[0]}" > "$T/r.json" && cat "$T/r.json" > "${MAIN[0]}"; git add "${MAIN[0]}"
    try "$1"; refused "$1" "$3"
    hasnt "...without HEAD's gate being run bounded for it" "$OUT" "running HEAD's gate first, bounded"
}
v1 "a record without verification" 'del(.verification)' "is not a valid recovery record"
v1 "a symlink mode" ".paths[\"$HOOK\"].replacement_mode = \"120000\"" "is not a valid recovery record"
v1 "a submodule mode" ".paths[\"$HOOK\"].baseline_mode = \"160000\"" "is not a valid recovery record"
v1 "mode 100664" ".paths[\"$HOOK\"].replacement_mode = \"100664\"" "is not a valid recovery record"
v1 "an abbreviated id" ".paths[\"$HOOK\"].replacement = \"${ro_h:0:12}\"" "is not a valid recovery record"
v1 "a tree id for a blob" ".paths[\"$HOOK\"].replacement = \"$(git rev-parse 'HEAD^{tree}')\"" "does not name a blob in this repository"
v1 "a baseline that is not HEAD's" ".paths[\"$HOOK\"].baseline = \"$(blob "$ORIG")\"" "which is not HEAD's regular file there"
for _gr_p in "scripts/../$HOOK" "./$HOOK" "scripts//hooks/pre-commit-weave.sh" "scripts/hooks/" "src/a.sh"; do
    v1 "the path $_gr_p" ".paths[\"$_gr_p\"] = .paths[\"$HOOK\"] | del(.paths[\"$HOOK\"])" "which is not a canonical path under scripts/"
done
reset_all

echo "D1t: the installed copy decides, not the working tree's"
cp "$HOOK" "$T/wt.hook"
sed -i 's/^_pcr_record_rows() {$/_pcr_record_rows() { return 0;/' "$HOOK"
check "(D1t setup) the working tree's recovery check is gutted" "1" "$(grep -c '^_pcr_record_rows() { return 0;' "$HOOK")"
main_record; jq 'del(.verification)' "${MAIN[0]}" > "$T/r.json" && cat "$T/r.json" > "${MAIN[0]}"; git add "${MAIN[0]}"
try "malformed, decoy working tree"
refused "(D1t) a malformed record under a gutted working-tree check" "is not a valid recovery record"
cp "$T/wt.hook" "$HOOK"; reset_all

echo "R1 prerequisites and failures after HEAD's refusal"
main_record; stage_trail
OUT=$(WV_GATE_LOG="$T/no-such-dir-file/gate.jsonl" git commit -q -m "record, log unwritable" 2>&1); RC=$?
refused "(L1) a record commit whose recovery row cannot be written" "could not write the recovery row to the gate log"
reset_all
mv .git/hooks/reference-transaction "$T/reftx.off"
main_record; try "record, no binding hook"
refused "(S5) a record commit with no reference-transaction hook" "reference-transaction hook, which is not installed"
mv "$T/reftx.off" .git/hooks/reference-transaction; reset_all
main_record; echo 'echo poked >> src/a.sh; git add src/a.sh' > "$MARK/poke-head"; try "record, index moved"
refused "(S1) a record commit whose index changed during HEAD's run" "the index or HEAD changed during recovery"
reset_all

echo "R1: the record lands first, admitted on HEAD's refusal"
H0=$(head); _rows=$(rec_rows)
main_record; stage_trail
try "recovery record"
admitted "(R1) the record commit is admitted"
has "...after HEAD's gate refused it, bounded" "$OUT" "running HEAD's gate first, bounded at 900s"
has "...HEAD's refusal shown" "$OUT" "fixture tripwire"
has "...by the recovery record it adds" "$OUT" "admitted by the recovery record ${MAIN[0]} it adds"
has "...saying records are not approval" "$OUT" "Records give traceability, not approval."
hasnt "...claiming no replacement verdict" "$OUT" "verdict"
check "...HEAD advanced by one commit" "$H0" "$(git rev-parse HEAD~1)"
check "...holding the record and the graph state" "${MAIN[0]} .weave/trails.md" "$(git diff-tree -r --no-commit-id --name-only HEAD | sort | paste -sd ' ')"
check "...one recovery row more" "$((_rows + 1))" "$(rec_rows)"
check "...a recovery-record decision with HEAD's status and base" "recovery-record admit 1 $H0" \
    "$(last_rec_row | jq -r '"\(.trigger) \(.decision) \(.head_status) \(.base)"')"
check "...and no execution tree" "null" "$(last_rec_row | jq -r '.exec_tree')"

echo "R1x: an existing record is not modified by a record commit"
H0=$(head); jq '.reason = "changed"' "${MAIN[0]}" > "$T/r.json" && cat "$T/r.json" > "${MAIN[0]}"; git add "${MAIN[0]}"
try "modify a record"
refused "a commit modifying an existing recovery record" "this one modifies or deletes ${MAIN[0]}"
reset_all

echo "A4: the repair commit is judged by the recorded replacement"
H0=$(head); _probe=$(runs probe); _rows=$(rec_rows)
cp "$REPL" "$HOOK"; cp "$T/helper.repl" "$HELPER"; git add "$HOOK" "$HELPER"
F_TREE=$(git write-tree)
try "repair"
admitted "(A4) the repair commit is admitted"
has "...after HEAD's gate refused it" "$OUT" "fixture tripwire"
has "...the negative control refused the invalid contract" "$OUT" "the staged gate role contract (scripts/hooks/gate-roles.json) is not valid"
has "...the replacement acknowledged the execution tree" "$OUT" "Weave pre-commit: recovery execution tree $F_TREE acknowledged"
has "...admitted by the record, judged by the replacement" "$OUT" "judged by the replacement gate (execution tree ${F_TREE:0:12}"
check "...the replacement ran once, past its role check" "1" "$(runs replacement)"
check "...its routed suite reran" "$((_probe + 1))" "$(runs probe)"
check "(B1) ...given HEAD's commit as the history base, not the execution tree" "$H0" "$(cat "$MARK/probe-base")"
check "...HEAD advanced by one commit" "$H0" "$(git rev-parse HEAD~1)"
check "...the commit is the judged tree" "$F_TREE" "$(git rev-parse 'HEAD^{tree}')"
check "...one recovery row more" "$((_rows + 1))" "$(rec_rows)"
check "...a recovery-repair decision naming the execution tree and verdict" "recovery-repair admit $F_TREE admitted" \
    "$(last_rec_row | jq -r '"\(.trigger) \(.decision) \(.exec_tree) \(.verdict)"')"
has "...and the control's result" "$(last_rec_row)" "invalid-role diagnostic"

echo "A5: the repaired HEAD gates the ordinary way"
stage_src; try "after repair"
admitted "(A5) an ordinary commit is admitted"
hasnt "...with no recovery notice" "$OUT" "recovery"
hasnt "...and no tripwire" "$OUT" "fixture tripwire"

echo "H1: a healthy HEAD's refusal, overridden only by a prior record (D3a)"
WEAK="$T/hook.weak"
with_lines "$REPL" "$AFTER_ROLES" "$WEAK" '# WEAKENED' 'exit 0'
H0=$(head); cp "$WEAK" "$HOOK"; git add "$HOOK"; try "weaken"
refused "(H1) a weakened hook without a record" "FAILED tests/test-probe.sh"
hasnt "...with no recovery admission" "$OUT" "admitted by the recovery record"
reset_all
read -r bm_r bo_r <<< "$(entry HEAD "$HOOK")"
record weak.json "override a healthy refusal" "$HOOK" "$bm_r" "$bo_r" "$bm_r" "$(blob "$WEAK")"; stage_trail
try "record the weakening"
admitted "(H1) a healthy HEAD admits the record commit itself"
hasnt "...the ordinary way, without recovery" "$OUT" "admitted by the recovery record"
H0=$(head); _rows=$(rec_rows); cp "$WEAK" "$HOOK"; git add "$HOOK"; try "weaken, recorded"
admitted "(H1, C3) the recorded weakening is admitted over the healthy refusal"
has "...showing the healthy refusal" "$OUT" "FAILED tests/test-probe.sh"
has "...the control passed: the weakening kept the role check" "$OUT" "the staged gate role contract (scripts/hooks/gate-roles.json) is not valid"
has "...admitted by the record, visibly" "$OUT" "admitted by the recovery record .weave/gate-repairs/weak.json"
check "...with a recovery row" "$((_rows + 1))" "$(rec_rows)"

echo "A6: a record admits once (A-B-A)"
cp "$TRIP" "$HOOK"; git show "$bo_l" > "$HELPER"; chmod 644 "$HELPER"; git add "$HOOK" "$HELPER"
commit_nohook "history from elsewhere: back to the baseline"
check "(A6 setup) both paths are at the baseline again" "$B_TRIP|$B_HELPER" "$(entry HEAD "$HOOK")|$(entry HEAD "$HELPER")"
H0=$(head); cp "$REPL" "$HOOK"; cp "$T/helper.repl" "$HELPER"; git add "$HOOK" "$HELPER"
try "repair again"
refused "(A6) the same transition again" "recover-main.json was already used"
# The function itself, with blobs readable and only the mode reads failing.
_gr_since=$(git log -1 --format=%H -- "${MAIN[0]}")
_gr_fn=$(sed -n '/^_pcr_consumed() {/,/^}/p; /^_pcr_mode() {/,/^}/p' .git/hooks/pre-commit)
_gr_consumed() { bash -c 'eval "$1"; _wv_base=$(git rev-parse HEAD); shift; _pcr_consumed "$@"' _ "$_gr_fn" \
    "$_gr_since" "$HOOK" "$bm_h" "$bo_h" "$bm_h" "$ro_h"; echo $?; }
check "(unit) the walk finds the main record consumed" "0" "$(_gr_consumed)"
touch "$MARK/fail-mode-read"
check "(unit) ...and with its mode reads failing, cannot tell (2), not unused (1)" "2" "$(_gr_consumed)"
rm -f "$MARK/fail-mode-read"
reset_all

# Records for the cases below, each landed by R1 on the tripwire HEAD.
mkhook() {  # mkhook <name> <before> <line>... — the original hook with lines
    with_lines "$ORIG" "$2" "$T/hook.$1" "${@:3}"
}
mkhook two "$AFTER_ROLES" '# two'
mkhook c1 "$ROLES" 'exit 0'
mkhook c2 "$ROLES" 'echo "✗ fixture: some other failure" >&2' 'exit 1'
mkhook v "$AFTER_ROLES" 'exit 3'
grep -v -e '^if \[ -n "\$_PC_EXEC_TREE" \]; then$' -e 'recovery execution tree \$_PC_EXEC_TREE acknowledged' "$ORIG" \
    | awk 'prev_ack && /^fi$/ { prev_ack = 0; next } { prev_ack = 0 } /^# hook_progress, which WV_HOOK_PROGRESS=0 silences\.$/ { prev_ack = 1 } { print }' > "$T/hook.b2"
mkhook nb "# _pc_admit — the only way" '_pc_bind() { return 0; }'
# Stages a file from inside its own binding: after its own last stability
# check, so only the dispatcher's checks after the run can see it.
# Writes the graph in the negative control only, before its role check.
mkhook db "$ROLES" \
    "if [[ \"\${GIT_INDEX_FILE:-}\" == */control/index ]]; then \"\$WV\" add \"control-db-probe\" --force >/dev/null 2>&1; echo \"probe-rc=\$?\" >> \"$MARK/ctl-db\"; fi"
mkhook pr "# _pc_admit — the only way" \
    "_pc_bind() { if [ -f \"$MARK/poke-run\" ]; then rm -f \"$MARK/poke-run\"; echo poked >> src/a.sh; git add src/a.sh; fi; }"
mkhook pk "$ROLES" \
    "if [[ \"\${GIT_INDEX_FILE:-}\" == */control/index ]] && [ -f \"$MARK/poke-ctl\" ]; then _fx=\$(cat \"$MARK/poke-ctl\"); rm -f \"$MARK/poke-ctl\"; (unset GIT_INDEX_FILE; eval \"\$_fx\"); fi"
check "(B2 setup) the no-acknowledgement hook drops exactly the acknowledgement" "0|$(( $(wc -l < "$ORIG") - 3 ))" \
    "$(grep -c 'execution tree \$_PC_EXEC_TREE acknowledged' "$T/hook.b2")|$(wc -l < "$T/hook.b2")"
for _gr_r in two c1 c2 v b2 nb pk pr db; do
    record "$_gr_r.json" "fixture case $_gr_r" "$HOOK" "$bm_h" "$bo_h" "$bm_h" "$(blob "$T/hook.$_gr_r")"
    try "record $_gr_r"
    admitted "(setup) record $_gr_r lands by R1"
done
record m.json "mode-only: the helper lost its executable bit" "$HELPER" 100644 "$bo_l" 100755 "$bo_l"
try "record m"; admitted "(setup) the mode-only record lands by R1"
stage_hook() { cp "$T/hook.$1" "$HOOK"; git add "$HOOK"; }

echo "R2x: a repair commit makes exactly its record's transitions"
H0=$(head)
stage_hook two; printf '# one byte\n' >> "$HOOK"; git add "$HOOK"; try "one byte more"
refused "(R2x) one byte different" "recovery does not apply"
reset_all; stage_hook two; git update-index --chmod=+x "$HOOK"; try "mode differs"
refused "(R2x) the mode different" "names this commit's paths, but not these modes and blobs"
reset_all; stage_hook two; printf '#!/bin/sh\n' > scripts/lib/wv-other.sh; git add scripts/lib/wv-other.sh; try "extra gate path"
refused "(R2x) an unrecorded extra gate path" "a repair commit makes exactly the record's transitions"
reset_all; stage_hook two; stage_src; try "extra product path"
refused "(R2x) an unrecorded product path" "fixture tripwire"
hasnt "...HEAD's refusal unchanged, no recovery claimed" "$OUT" "recovery does not admit"
reset_all; git rm -q --cached "$HOOK"; try "deletion"
refused "(R2x) deleting a recorded path" "recovery does not apply"
reset_all

echo "C1-C2, R2v, B2: the control, the verdict and the acknowledgement"
stage_hook c1; try "replacement admits everything"
refused "(C1) a replacement that admits everything" "did not refuse the negative control with the invalid-role diagnostic (status 0)"
reset_all; stage_hook c2; try "replacement fails otherwise"
refused "(C2) a replacement refusing the control with another error" "did not refuse the negative control with the invalid-role diagnostic (status 1)"
reset_all; _probe=$(runs probe); stage_hook v; try "replacement refuses"
refused "(R2v) a replacement that refuses the commit" "the replacement gate refused this commit (status 3); its verdict binds"
reset_all; stage_hook b2; try "replacement ignores the mark"
refused "(B2) a replacement that does not acknowledge the execution tree" "did not acknowledge the execution tree mark"
reset_all

echo "S1, S2: the index and HEAD hold still through every run"
stage_hook pk; echo 'echo poked >> src/a.sh; git add src/a.sh' > "$MARK/poke-ctl"; try "index moves in the control"
refused "(S1) a repair whose index changed during the control" "the index or HEAD changed during recovery"
reset_all; git update-ref refs/heads/main "$H0"
stage_hook pk; echo 'git update-ref refs/heads/main HEAD~1' > "$MARK/poke-ctl"; try "HEAD moves in the control"
check "(S2) a repair whose HEAD moved during the control is refused" "1" "$([ "$RC" -ne 0 ] && echo 1 || echo 0)"
has "...for the move" "$OUT" "the index or HEAD changed during recovery"
git update-ref refs/heads/main "$H0"; reset_all
stage_hook pr; touch "$MARK/poke-run"; try "index moves after the replacement's last check"
refused "(S1) a repair whose index changed after the replacement's own last check" "the index or HEAD changed during recovery"
reset_all

echo "S3, L2: the dispatcher binds the commit to the tree it judged"
_rows=$(rec_rows); stage_hook nb; touch "$MARK/stage-at-bind"; try "staged after the last check"
refused "(S3) a file staged after recovery's last check, with a replacement that binds nothing" "is not the tree the pre-commit gate judged"
check "(L2) ...the row records the admission decision all the same" "$((_rows + 1))" "$(rec_rows)"
check "...naming what judged it" "recovery-repair admit admitted" "$(last_rec_row | jq -r '"\(.trigger) \(.decision) \(.verdict)"')"
has "...and the control" "$(last_rec_row)" "invalid-role diagnostic"
git reset -q -- src/raced.txt 2>/dev/null; rm -f src/raced.txt; reset_all

echo "M1, M2: a mode-only record is consumed by its transition, not by unchanged bytes"
stage_src; commit_nohook "unrelated history keeping the helper's bytes and mode"
H0=$(head); git update-index --chmod=+x "$HELPER"; try "mode-only repair"
admitted "(M2) the mode-only repair is admitted after an unrelated commit"
has "...by its record" "$OUT" "admitted by the recovery record .weave/gate-repairs/m.json"
check "...HEAD's helper is now executable" "100755 $bo_l" "$(entry HEAD "$HELPER")"
git update-index --chmod=-x "$HELPER"; chmod 644 "$HELPER"; commit_nohook "history from elsewhere: the bit lost again"
H0=$(head); git update-index --chmod=+x "$HELPER"; try "mode-only repair again"
refused "(M1) the mode-only transition again" "m.json was already used"
reset_all; chmod 644 "$HELPER"

echo "T1-T3: HEAD's gate is bounded for a recovery shape, and only then"
H0=$(head); stage_src; echo 'sleep 3' > "$MARK/poke-head"
_t0=$(date +%s); OUT=$(WV_GATE_RECOVERY_TIMEOUT=1 git commit -q -m "slow ordinary" 2>&1); RC=$?; _t1=$(date +%s)
refused "(T2) a slow HEAD gate on an ordinary commit" "fixture tripwire"
hasnt "...is not bounded" "$OUT" "did not finish within"
check "...it ran to its end" "1" "$([ $((_t1 - _t0)) -ge 3 ] && echo 1 || echo 0)"
reset_all
# The hang outlasts the check: OUT=$(...) waits for every process holding the
# output, so a group member left running would hold the commit open for 60s.
stage_hook v; echo "(sleep $SL_HANG) & sleep $SL_HANG" > "$MARK/poke-head"
_t0=$(date +%s); OUT=$(WV_GATE_RECOVERY_TIMEOUT=4 git commit -q -m "hanging HEAD" 2>&1); RC=$?; _t1=$(date +%s)
refused "(T1) a hanging HEAD gate on a repair" "did not finish within 4s (WV_GATE_RECOVERY_TIMEOUT)"
check "...returning long before the hang would end: the whole group was killed" "1" "$([ $((_t1 - _t0)) -lt 50 ] && echo 1 || echo "0 ($((_t1 - _t0))s)")"
has "...then recovery proceeded to the control" "$OUT" "recovery negative control"
has "...and the replacement's verdict" "$OUT" "the replacement gate refused this commit (status 3)"
check "...nothing of HEAD's group is left running" "0" "$(pgrep -fxc "sleep $SL_HANG" || true)"
reset_all
stage_hook v; echo "setsid sleep $SL_DETACH >/dev/null 2>&1 < /dev/null & sleep $SL_GROUP" > "$MARK/poke-head"
OUT=$(WV_GATE_RECOVERY_TIMEOUT=4 git commit -q -m "detaching HEAD" 2>&1); RC=$?
refused "(T3) a hanging HEAD gate whose child detached" "did not finish within 4s"
check "...its group is gone" "0" "$(pgrep -fxc "sleep $SL_GROUP" || true)"
check "...but the child that left the group is not contained (stated residual)" "1" "$(pgrep -fxc "sleep $SL_DETACH" || true)"
pkill -fx "sleep $SL_DETACH" 2>/dev/null; reset_all

echo "H2: a shallow or partial clone cannot show a record unused"
git -C "$W" config uploadpack.allowFilter true
for _gr_kind in shallow partial; do
    if [ "$_gr_kind" = shallow ]; then
        git clone -q --depth 1 "file://$W" "$T/$_gr_kind" 2>/dev/null
    else
        git clone -q --filter=blob:none "file://$W" "$T/$_gr_kind" 2>/dev/null
    fi
    (
        cd "$T/$_gr_kind" || exit 1
        git config user.name "Gate Test"; git config user.email gate@example.com
        install -m 755 "$ROOT/scripts/hooks/pre-commit-weave.sh" .git/hooks/pre-commit
        install -m 755 "$ROOT/scripts/hooks/reference-transaction-weave.sh" .git/hooks/reference-transaction
        cp "$T/hook.two" "$HOOK"; git add "$HOOK"
        git commit -q -m "repair in a $_gr_kind clone" > "$T/$_gr_kind.out" 2>&1
        echo "$?" > "$T/$_gr_kind.rc"
    )
    check "(H2) a repair in a $_gr_kind clone is refused" "1" "$([ "$(cat "$T/$_gr_kind.rc")" -ne 0 ] && echo 1 || echo 0)"
    has "...with the fetch hint" "$(cat "$T/$_gr_kind.out")" "history is shallow or partial"
done

echo "A7: an unreadable consuming commit is unreadable history, not an unused record"
# History from elsewhere consumes record two (with an extra file, so its hooks
# tree is its own), then returns to the baseline. That tree's loose object is
# then moved away, as a damaged store loses one, and the transition retried.
stage_hook two; printf 'x\n' > scripts/hooks/extra-consumer.txt; git add scripts/hooks/extra-consumer.txt
commit_nohook "history from elsewhere: record two's transition"; _gr_consumer=$(head)
cp "$TRIP" "$HOOK"; git rm -q scripts/hooks/extra-consumer.txt; git add "$HOOK"
commit_nohook "history from elsewhere: back to the baseline"
_gr_tree=$(git rev-parse "$_gr_consumer:scripts/hooks"); _gr_obj=".git/objects/${_gr_tree:0:2}/${_gr_tree:2}"
check "(A7 setup) the consuming commit's hooks tree is a loose object of its own" "1 1" \
    "$([ -f "$_gr_obj" ] && echo 1 || echo 0) $([ "$_gr_tree" != "$(git rev-parse HEAD:scripts/hooks)" ] && echo 1 || echo 0)"
H0=$(head); stage_hook two; mv "$_gr_obj" "$T/tree.obj"
try "record two again, history unreadable"; mv "$T/tree.obj" "$_gr_obj"
refused "(A7) the transition with its consuming commit unreadable" "could not read the history that shows whether"
hasnt "...never admitted as unused" "$OUT" "admitted by the recovery record"
try "record two again, history readable"
refused "(A7 control) with the object back, the record is consumed" "two.json was already used"
reset_all

echo "A8: the same for a recorded path with a space, which git echoes back when missing"
# git answers a missing "<commit>:<path>" by echoing it, so a parser reading
# the status from a fixed field misses it for a spaced path. Valid paths keep
# their spaces; the parser must not depend on them.
SP="scripts/with space.sh"
printf '#!/bin/sh\necho v1\n' > "$SP"; git add "$SP"; commit_nohook "history from elsewhere: a spaced gate path"
_gr_v1=$(git rev-parse "HEAD:$SP"); printf '#!/bin/sh\necho v2\n' > "$T/space.v2"; _gr_v2=$(blob "$T/space.v2")
record space.json "a spaced path" "$SP" 100644 "$_gr_v1" 100644 "$_gr_v2"; try "record space"
admitted "(A8 setup) the spaced-path record lands by R1"
# Genuine absence: the path deleted and re-added after the record. The walk
# meets commits that lack it; that is no transition, not unreadable history.
git rm -q "$SP"; commit_nohook "history from elsewhere: the spaced path deleted"
printf '#!/bin/sh\necho v1\n' > "$SP"; git add "$SP"; commit_nohook "history from elsewhere: and restored"
H0=$(head); cp "$T/space.v2" "$SP"; git add "$SP"; try "spaced repair, path once absent"
# The walk passing shows as recovery going on to the negative control (which
# the tripwire hook, the replacement here, then fails).
refused "(A8 absence control) the walk reads the absent path as no transition" "recovery negative control: the replacement must refuse"
hasnt "...not as unreadable history" "$OUT" "could not read the history"
hasnt "...nor as used" "$OUT" "space.json was already used"
reset_all
# Unreadable: a consuming commit whose scripts tree is its own, then moved away.
cp "$T/space.v2" "$SP"; printf 'x\n' > scripts/extra-consumer.txt; git add "$SP" scripts/extra-consumer.txt
commit_nohook "history from elsewhere: the spaced record's transition"; _gr_consumer=$(head)
printf '#!/bin/sh\necho v1\n' > "$SP"; git rm -q scripts/extra-consumer.txt; git add "$SP"
commit_nohook "history from elsewhere: back to the baseline"
_gr_tree=$(git rev-parse "$_gr_consumer:scripts"); _gr_obj=".git/objects/${_gr_tree:0:2}/${_gr_tree:2}"
check "(A8 setup) the consuming commit's scripts tree is a loose object of its own" "1 1" \
    "$([ -f "$_gr_obj" ] && echo 1 || echo 0) $([ "$_gr_tree" != "$(git rev-parse HEAD:scripts)" ] && echo 1 || echo 0)"
H0=$(head); cp "$T/space.v2" "$SP"; git add "$SP"; mv "$_gr_obj" "$T/tree.obj"
try "spaced repair, history unreadable"; mv "$T/tree.obj" "$_gr_obj"
refused "(A8) the spaced transition with its consuming commit unreadable" "could not read the history that shows whether"
hasnt "...never admitted as unused" "$OUT" "admitted by the recovery record"
try "spaced repair, history readable"
refused "(A8 control) with the object back, the spaced record is consumed" "space.json was already used"
reset_all

echo "C4: the negative control writes no shared graph state"
# Last: it lands, so HEAD's gate is healthy afterwards.
H0=$(head); stage_hook db; try "replacement writes the graph in its control"
admitted "(C4) a replacement that writes the graph during its control is admitted"
check "...its control did write a graph (the probe ran and succeeded)" "probe-rc=0" "$(cat "$MARK/ctl-db" 2>/dev/null)"
check "...into a private database: the fixture's graph has no such node" "0" \
    "$(wv list --all --json 2>/dev/null | grep -c control-db-probe)"

echo "X1: external enforcement recovery uses the replacement execution tree"
# A gate whose declared external policy refuses every commit. Only that
# policy changes: neither the hook nor its role declaration needs replacing.
printf '#!/bin/sh\n# old-policy\n' > build-release.sh
jq '.enforcement += ["build-release.sh"]' scripts/hooks/gate-roles.json > "$T/external-roles"
mv "$T/external-roles" scripts/hooks/gate-roles.json
with_lines "$ORIG" "$ROLES" "$T/external-trip" \
    'if ! grep -qx "# new-policy" "$_PC_SCRIPTS/../build-release.sh"; then' \
    '    echo "external policy refuses every commit" >&2; exit 1' \
    'fi'
cp "$T/external-trip" "$HOOK"
git add "$HOOK" scripts/hooks/gate-roles.json build-release.sh
commit_nohook "external policy refusal fixture"
_gr_ext_old=$(git rev-parse HEAD:build-release.sh)
_gr_ext_new=$(printf '#!/bin/sh\n# new-policy\n' | git hash-object -w --stdin)
record external.json "replace the refusing external policy" \
    build-release.sh 100644 "$_gr_ext_old" 100644 "$_gr_ext_new"
try "record external policy recovery"
admitted "(X1) the installed dispatcher admits the external-path record"
has "...after the old policy refused" "$OUT" "external policy refuses every commit"
printf '#!/bin/sh\n# new-policy\n' > build-release.sh; git add build-release.sh
try "repair external policy"
admitted "(X1) recovery runs the external replacement policy, not HEAD's policy"
has "...after its negative control" "$OUT" "recovery negative control"
check "...recording the actual replacement execution tree" "$(git rev-parse 'HEAD^{tree}')" \
    "$(jq -r '.exec_tree' <<< "$(last_rec_row)")"
stage_src; try "ordinary commit after external policy repair"
admitted "(X1 control) the repaired external policy gates ordinary commits"

echo "X2: a broken role declaration cannot disable installed recovery"
_gr_good_roles=$(git rev-parse HEAD:scripts/hooks/gate-roles.json)
jq '.enforcement += ["not-present"]' scripts/hooks/gate-roles.json > "$T/broken-roles"
mv "$T/broken-roles" scripts/hooks/gate-roles.json
with_lines "$ORIG" "$ROLES" "$T/roles-trip" \
    'if jq -e '\''.enforcement | index("not-present")'\'' "$_PC_SCRIPTS/hooks/gate-roles.json" >/dev/null; then' \
    '    echo "broken role declaration refuses every commit" >&2; exit 1' \
    'fi'
cp "$T/roles-trip" "$HOOK"
git add "$HOOK" scripts/hooks/gate-roles.json
commit_nohook "broken role declaration fixture"
_gr_bad_roles=$(git rev-parse HEAD:scripts/hooks/gate-roles.json)
record roles.json "repair the declaration naming a missing root" \
    scripts/hooks/gate-roles.json 100644 "$_gr_bad_roles" 100644 "$_gr_good_roles"
try "record role declaration recovery"
admitted "(X2) a missing declared root cannot prevent recording recovery"
has "...after HEAD's declaration refused" "$OUT" "broken role declaration refuses every commit"
git cat-file blob "$_gr_good_roles" > scripts/hooks/gate-roles.json
git add scripts/hooks/gate-roles.json
try "repair role declaration"
admitted "(X2) the installed dispatcher can recover the role declaration"
has "...with a replacement negative control" "$OUT" "recovery negative control"

echo ""
echo "gate recovery: $pass/$run passed"
[ "$pass" -eq "$run" ]
