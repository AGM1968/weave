#!/usr/bin/env bash
# A suite-resolver failure is never "no suites" (wv-cf48a9).
#
# _impact_suites_for_files maps changed files to suites for every gate. Its
# callers used to discard its status: a failed resolution read as an empty
# route table, so the pre-push reuse key covered fewer inputs than the suite
# has and an earlier green result for the narrower key was reused; the
# pre-commit gate ran no suite and passed; wv done's refresh recorded the path
# unknown; bootstrap's heavy-tier report said clear. And the resolver itself
# returned 0 on a test map it could not read, routing by the naming heuristic.
# Pinned here, each against a healthy control:
#   - an unreadable or malformed test map fails the resolver and the CLI;
#   - a failed resolver makes the reuse key uncomputable: the green row for
#     the narrower key (seeded) is not served;
#   - the refresh records the path stale, the heavy-tier report says unknown,
#     the pre-commit gate refuses the commit;
#   - impact's file-only JSON stays valid for a path holding a quote;
#   - every other input the key reads is acquired fail-closed (wv-3fab34): a
#     failed index listing, a short, failed or malformed hash batch, a failed
#     symlink hash, or a path whose absence cannot be observed makes the key
#     uncomputable, while a real deletion still keys as missing;
#   - a test map that is there but unavailable -- a dangling symlink, or a
#     .weave/ that cannot be searched -- is never "no map" (wv-b02828): the
#     router and key fail, the heavy-tier report says unknown, and pre-push
#     refuses; a readable symlinked map still works;
#   - a staged-file listing that fails is not an empty one (wv-9c6ae1): the
#     hook's first listing, the graph-state classifier, and the listings for
#     ruff, quality rules and shellcheck each refuse the commit; the classifier
#     itself returns nonzero, so a checkpoint never reads the failure as
#     "nothing staged". A git wrapper on PATH fails only the one listing under test.
# Failures are injected two ways: a real unreadable conf (skipped as root,
# which reads it anyway), and a resolver replaced in a harness that sources
# this checkout's modules, the only way to fail it with the conf unchanged.
set -uo pipefail
export WV_TEST_SUITE=1
export WV_CALL_SOURCE=test

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS="$ROOT/scripts/hooks"

run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }
has()   { if grep -qF -- "$3" <<< "$2"; then ok "$1"; else bad "$1" "missing [$3] in: $(tail -5 <<< "$2")"; fi; }
hasnt() { if grep -qF -- "$3" <<< "$2"; then bad "$1" "unexpected [$3]"; else ok "$1"; fi; }

T=$(mktemp -d /tmp/wv-resolver-fail-XXXXXX)
trap 'chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/cfg"
ln -s "$ROOT/scripts/wv" "$T/bin/wv"
export PATH="$T/bin:$PATH"
export WV_LIB_DIR="$ROOT/scripts"
export WV_HOT_ZONE="$T" WV_DB="$T/brain.db" WV_CONFIG_DIR="$T/cfg" WV_PROJECT_DIR="$T/work"
export WV_SUITE_LOG="$T/suite_runs.jsonl" WV_GATE_LOG="$T/gate_runs.jsonl"
export WV_AUTO_SYNC=0 WV_AUTO_CHECKPOINT=0 WV_REQUIRE_LEARNING=0 WV_RUN_CACHE=0
unset WV_GATE_PHASE WV_GATE_ID WV_GATE_CONTEXT WV_HOOK_REEXEC
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

git init -q --bare "$T/remote.git"
git init -q -b main "$T/work"
cd "$T/work" || exit 1
git config user.name "Gate Test"; git config user.email gate@example.com; git config commit.gpgsign false
git remote add origin "$T/remote.git"
mkdir -p src tests .weave
for s in a h; do
    printf '#!/bin/sh\nexit 0\n' > "tests/test-$s.sh"
    chmod +x "tests/test-$s.sh"
done
# src/r.sh routes to test-a but is outside test-a's declared inputs: only the
# route table puts it in test-a's key.
cat > .weave/test-map.conf <<'EOF_CONF_rf01'
[map]
src/a.sh = tests/test-a.sh
src/r.sh = tests/test-a.sh
src/h.sh = tests/test-h.sh
[inputs]
tests/test-a.sh = src/a.sh tests/test-a.sh
[heavy]
tests/test-h.sh
EOF_CONF_rf01
printf 'a\n' > src/a.sh
printf 'r\n' > src/r.sh
printf 'h\n' > src/h.sh
git add -A && git -c core.hooksPath=/dev/null commit -q -m "fixture"
git -c core.hooksPath=/dev/null push -q -u origin main 2>/dev/null
wv add "resolver fixture node" --status=active --force --criteria="c1|c2" --risks=low >/dev/null 2>&1
CONF_GOOD=$(cat .weave/test-map.conf)

# harness <body> — this checkout's modules sourced into one shell, as scripts/wv
# would, so a function can be replaced; FAIL_RESOLVER=1 replaces the resolver.
# GIT_FAULT=<kind> replaces git in the harness for one acquisition: the index
# listing fails; the --stdin-paths batch stops after one hash (failing, or
# exiting 0), or prints a non-id; the --stdin (symlink) hash fails.
harness() {
    WEAVE_DIR="$T/work/.weave" FAIL_RESOLVER="${FAIL_RESOLVER:-0}" GIT_FAULT="${GIT_FAULT:-}" bash -c "
        source '$ROOT/scripts/lib/wv-config.sh' 2>/dev/null
        source '$ROOT/scripts/lib/wv-validate.sh'
        source '$ROOT/scripts/lib/wv-db.sh'
        source '$ROOT/scripts/lib/wv-checkpoint-ci.sh'
        source '$ROOT/scripts/lib/wv-attempt-journal.sh'
        source '$ROOT/scripts/cmd/wv-cmd-graph.sh'
        source '$ROOT/scripts/cmd/wv-cmd-orient.sh'
        source '$ROOT/scripts/cmd/wv-cmd-doctor.sh'
        source '$ROOT/scripts/cmd/wv-cmd-gate.sh'
        source '$ROOT/scripts/cmd/wv-cmd-core.sh'
        if [ \"\$FAIL_RESOLVER\" = 1 ]; then
            _impact_suites_for_files() { echo 'injected resolver failure' >&2; return 1; }
        fi
        if [ -n \"\$GIT_FAULT\" ]; then
            git() {
                local out
                case \"\$GIT_FAULT \$*\" in
                    'ls-fail '*'ls-files -s'*) return 1 ;;
                    'hash-short-fail '*'--stdin-paths'*) out=\$(command git \"\$@\"); head -n 1 <<< \"\$out\"; return 1 ;;
                    'hash-short-ok '*'--stdin-paths'*) out=\$(command git \"\$@\"); head -n 1 <<< \"\$out\"; return 0 ;;
                    'hash-garbage '*'--stdin-paths'*) out=\$(command git \"\$@\"); sed 's/^/x/' <<< \"\$out\"; return 0 ;;
                    'stdin-fail '*'hash-object --stdin') cat >/dev/null; return 1 ;;
                esac
                command git \"\$@\"
            }
        fi
        $1"
}
unreadable_ok=1
if [ "$(id -u)" = 0 ]; then unreadable_ok=0; fi

echo "resolver: a test map it cannot use is a failure"
out=$(wv impact --suites --files=src/a.sh 2>/dev/null); rc=$?
check "control: a readable map routes and exits 0" "0 tests/test-a.sh" "$rc $(jq -r '[.[].name] | join(" ")' <<< "$out" 2>/dev/null)"
if [ "$unreadable_ok" = 1 ]; then
    chmod 000 .weave/test-map.conf
    err=$(wv impact --suites --files=src/a.sh 2>&1 >/dev/null); rc=$?
    chmod 644 .weave/test-map.conf
    check "an unreadable map fails wv impact --suites" "1" "$rc"
    has "...and says which file" "$err" "cannot read"
else
    echo "  - skipped: unreadable-map cases (root reads a mode-000 file)"
fi
printf '[map]\n= tests/test-a.sh\n%s\n' "$CONF_GOOD" > .weave/test-map.conf
err=$(wv impact --suites --files=src/a.sh 2>&1 >/dev/null); rc=$?
printf '%s\n' "$CONF_GOOD" > .weave/test-map.conf
check "a mapping with no source path fails the resolver" "1" "$rc"
has "...and names the line" "$err" "a mapping with no source path"

echo "reuse key: a failed resolver is no key, not a narrower one"
k0=$(wv test-status --inputs --suites=tests/test-a.sh 2>/dev/null | cut -f2)
check "control: the clean tree has a key" "1" "$(grep -cE '^[0-9a-f]{40}$' <<< "$k0")"
wv test-record tests/test-a.sh --exit=0 --inputs-key="$k0" >/dev/null 2>&1
printf 'r broken\n' > src/r.sh
check "control: a routed edit outside the declared inputs moves the key" "stale" \
    "$(wv test-status --inputs --suites=tests/test-a.sh 2>/dev/null | cut -f1)"
out=$(FAIL_RESOLVER=1 harness "_test_input_keys worktree tests/test-a.sh" 2>/dev/null); rc=$?
check "an injected resolver failure makes the key uncomputable" "1 " "$rc $out"
out=$(FAIL_RESOLVER=1 harness "cmd_test_status --inputs --suites=tests/test-a.sh" 2>/dev/null); rc=$?
hasnt "...so the green row for the narrower key is not served" "$out" "green"
check "...and test-status --inputs exits nonzero" "1" "$rc"
out=$(harness "_test_input_keys worktree tests/test-a.sh" 2>/dev/null); rc=$?
check "control: the same harness with the real resolver keys the suite" "0 1" "$rc $(grep -c 'tests/test-a.sh' <<< "$out")"
if [ "$unreadable_ok" = 1 ]; then
    chmod 000 .weave/test-map.conf
    wv test-status --inputs --suites=tests/test-a.sh >/dev/null 2>&1; rc=$?
    chmod 644 .weave/test-map.conf
    check "an unreadable map makes test-status --inputs exit nonzero" "1" "$rc"
fi
git checkout -q -- src/r.sh

echo "reuse key: every input is acquired fail-closed (wv-3fab34)"
keyof() { harness "_test_input_keys $1 tests/test-a.sh" 2>/dev/null; }
# Two different staged contents of a keyed file.
printf 'a v1\n' > src/a.sh && git add src/a.sh
k1=$(keyof staged); rc1=$?
printf 'a v2\n' > src/a.sh && git add src/a.sh
k2=$(keyof staged)
check "control: healthy staged keys differ for different staged content" "0 differ" \
    "$rc1 $([ -n "$k1" ] && [ "$k1" != "$k2" ] && echo differ)"
out=$(GIT_FAULT=ls-fail keyof staged); rc=$?
check "a failed index listing makes the staged key uncomputable" "1 " "$rc $out"
git reset -q; git checkout -q -- src/a.sh
printf 'a v3\n' > src/a.sh; printf '#!/bin/sh\nexit 0 # edited\n' > tests/test-a.sh
out=$(keyof worktree); rc=$?
check "control: the worktree key is computable with two files to hash" "0 1" "$rc $(grep -c 'tests/test-a.sh' <<< "$out")"
for f in hash-short-fail hash-short-ok hash-garbage; do
    out=$(GIT_FAULT=$f keyof worktree); rc=$?
    check "a $f hash batch makes the worktree key uncomputable" "1 " "$rc $out"
done
ln -s a.sh src/link.sh
out=$(keyof worktree); rc=$?
check "control: a changed symlink keys" "0" "$rc"
out=$(GIT_FAULT=stdin-fail keyof worktree); rc=$?
check "a failed symlink hash makes the key uncomputable" "1 " "$rc $out"
rm -f src/link.sh
git checkout -q -- src/a.sh tests/test-a.sh
# A tracked file deleted from the working tree is an input that is absent.
rm -f src/r.sh
out=$(keyof worktree); rc=$?
check "control: a real deletion still keys (as missing)" "0 1" "$rc $(grep -c 'tests/test-a.sh' <<< "$out")"
git checkout -q -- src/r.sh
if [ "$unreadable_ok" = 1 ]; then
    mkdir -p src/deep && printf 'd\n' > src/deep/d.sh && git add src/deep/d.sh \
        && git -c core.hooksPath=/dev/null commit -q -m "deep"
    printf 'd2\n' > src/deep/d.sh
    chmod 000 src/deep
    out=$(harness "_test_input_keys worktree tests/test-a.sh" 2>/dev/null); rc=$?
    chmod 755 src/deep
    check "a path under an unsearchable directory is not keyed as missing" "1 " "$rc $out"
    git checkout -q -- src/deep/d.sh
fi

echo "wv done refresh: a failed resolution is stale, not unknown"
nid=$(wv list --json 2>/dev/null | jq -r 'first(.[] | select(.text == "resolver fixture node") | .id)')
sqlite3 "$WV_DB" "INSERT OR REPLACE INTO node_files(node_id, path) VALUES ('$nid', 'src/a.sh');"
fts() { sqlite3 "$WV_DB" "SELECT state FROM file_test_status WHERE path='src/a.sh';"; }
harness "_done_refresh_test_status '$nid'" 2>/dev/null
check "control: a mapped path with no row is stale" "stale" "$(fts)"
sqlite3 "$WV_DB" "DELETE FROM file_test_status;"
printf '[map]\n' > .weave/test-map.conf
harness "_done_refresh_test_status '$nid'" 2>/dev/null
check "control: an unmapped path is unknown" "unknown" "$(fts)"
sqlite3 "$WV_DB" "DELETE FROM file_test_status;"
err=$(FAIL_RESOLVER=1 harness "_done_refresh_test_status '$nid'" 2>&1 >/dev/null)
check "an injected resolver failure records the path stale" "stale" "$(fts)"
has "...and says so" "$err" "could not resolve the test suites for src/a.sh"
printf '%s\n' "$CONF_GOOD" > .weave/test-map.conf

echo "bootstrap heavy tier: a failed resolution is unknown, not clear"
printf 'h2\n' > src/h.sh
git add src/h.sh && git -c core.hooksPath=/dev/null commit -q -m "heavy change"
out=$(harness "_bootstrap_heavy_tier_json" 2>/dev/null)
check "control: an owed heavy suite is pending" "pending tests/test-h.sh" \
    "$(jq -r '"\(.state) \([.suites[].suite] | join(" "))"' <<< "$out" 2>/dev/null)"
out=$(FAIL_RESOLVER=1 harness "_bootstrap_heavy_tier_json" 2>/dev/null)
check "an injected resolver failure reports unknown" "unknown" "$(jq -r '.state' <<< "$out" 2>/dev/null)"
adv=$(harness "_bootstrap_readiness_advisories null '[]' '$out'" 2>/dev/null)
has "...with an advisory" "$adv" "heavy tier unknown for commits not on origin/main"

echo "test map: unavailable is not absent (wv-b02828)"
mv .weave/test-map.conf "$T/map-real.conf"
ln -s "$T/map-real.conf" .weave/test-map.conf
out=$(wv impact --suites --files=src/a.sh 2>/dev/null); rc=$?
check "control: a symlinked readable map routes" "0 tests/test-a.sh" "$rc $(jq -r '[.[].name] | join(" ")' <<< "$out" 2>/dev/null)"
pp() {
    bash "$ROOT/scripts/hooks/pre-push-weave.sh" origin "$T/remote.git" \
        < <(printf 'refs/heads/main %s refs/heads/main %s\n' "$(git rev-parse HEAD)" "$(git rev-parse origin/main)") 2>&1
}
out=$(pp)
hasnt "control: pre-push reads a symlinked map" "$out" "cannot be read"
rm -f .weave/test-map.conf && ln -s "$T/no-such-map.conf" .weave/test-map.conf
err=$(wv impact --suites --files=src/a.sh 2>&1 >/dev/null); rc=$?
check "a dangling map fails the router" "1" "$rc"
has "...saying it cannot be read" "$err" "cannot read"
wv test-status --inputs --suites=tests/test-a.sh >/dev/null 2>&1; rc=$?
check "a dangling map makes the reuse key uncomputable" "1" "$rc"
out=$(harness "_bootstrap_heavy_tier_json" 2>/dev/null)
check "a dangling map makes the heavy-tier report unknown, not null" "unknown" "$(jq -r '.state' <<< "$out" 2>/dev/null)"
sqlite3 "$WV_DB" "INSERT OR REPLACE INTO policy_thresholds(key, value) VALUES('test_gate', '2');"
printf '%s\n' '_doctor_record() { printf "%s|%s\n" "$1" "$2"; }' > "$T/doctor-probe.sh"
out=$(harness "source '$T/doctor-probe.sh'; _doctor_check_verification" 2>/dev/null)
check "doctor fails the test-map check on a dangling map, not 'absent'" "test-map|fail" "$(grep '^test-map|' <<< "$out")"
sqlite3 "$WV_DB" "DELETE FROM policy_thresholds WHERE key='test_gate';"
out=$(pp); rc=$?
check "a dangling map refuses the push" "1" "$rc"
has "...naming the map" "$out" ".weave/test-map.conf exists but cannot be read"
rm -f .weave/test-map.conf && mv "$T/map-real.conf" .weave/test-map.conf
if [ "$unreadable_ok" = 1 ]; then
    chmod 000 .weave
    out=$(harness "_impact_suites_for_files src/a.sh" 2>/dev/null); rc=$?
    out2=$(pp); rc2=$?
    chmod 755 .weave
    check "an unsearchable .weave/ fails the router" "1" "$rc"
    check "an unsearchable .weave/ refuses the push" "1" "$rc2"
    has "...naming the directory" "$out2" ".weave/ cannot be searched"
fi

echo "pre-commit: a failed resolution refuses the commit"
printf 'a2\n' > src/a.sh
git add src/a.sh
out=$(bash "$HOOKS/pre-commit-weave.sh" 2>&1); rc=$?
check "control: a readable map runs the routed suite and passes" "0" "$rc"
# The gate routes by the maps git holds (F5, wv-fe8007): the working-tree
# file is not an input, unreadable or malformed. A malformed map in the
# index, or one git cannot read (below, with the failing git), refuses.
if [ "$unreadable_ok" = 1 ]; then
    chmod 000 .weave/test-map.conf
    printf 'a3\n' > src/a.sh; git add src/a.sh
    out=$(bash "$HOOKS/pre-commit-weave.sh" 2>&1); rc=$?
    chmod 644 .weave/test-map.conf
    check "an unreadable working-tree map is not an input: the commit is judged" "0" "$rc"
    has "...by the map git holds" "$out" "tests/test-a.sh"
fi
printf '[map]\n= tests/test-a.sh\n%s\n' "$CONF_GOOD" > .weave/test-map.conf
printf 'a4\n' > src/a.sh; git add src/a.sh
out=$(bash "$HOOKS/pre-commit-weave.sh" 2>&1); rc=$?
check "a malformed working-tree map is not an input either" "0" "$rc"
git add .weave/test-map.conf
out=$(bash "$HOOKS/pre-commit-weave.sh" 2>&1); rc=$?
check "a malformed staged map refuses the commit" "1" "$rc"
has "...naming the cause" "$out" "could not resolve the suites for the staged files"
git reset -q
printf '%s\n' "$CONF_GOOD" > .weave/test-map.conf

echo "pre-commit: a failed staged listing refuses the commit (wv-9c6ae1)"
mkdir -p "$T/fakegit"
REAL_GIT=$(command -v git)
printf '#!/usr/bin/env bash\nif [ -n "${FAKE_GIT_FAIL:-}" ] && [[ "$*" =~ $FAKE_GIT_FAIL ]]; then exit 1; fi\nexec "%s" "$@"\n' "$REAL_GIT" > "$T/fakegit/git"
chmod +x "$T/fakegit/git"
# fg_hook <regex> — the pre-commit hook with git failing on matching argv.
fg_hook() { PATH="$T/fakegit:$PATH" FAKE_GIT_FAIL="$1" bash "$HOOKS/pre-commit-weave.sh" 2>&1; }
printf 'a3\n' > src/a.sh
printf 'print(1)\n' > src/p.py
printf '#!/bin/sh\necho s\n' > src/s.sh
git add src/a.sh src/p.py src/s.sh
out=$(fg_hook '^$'); rc=$?
check "control: the wrapper with no fault admits the commit" "0" "$rc"
# The hook lists the frozen transition (wv-8e34cd): diff-tree between the base
# tree and the index tree, each resolved first; every listing and each
# resolution can fail.
for f in '^diff-tree -r -z --name-only --no-renames [0-9a-f]+ [0-9a-f]+$' \
    'diff-filter=AM [0-9a-f]+ [0-9a-f]+$' 'diff-filter=AMD [0-9a-f]+ [0-9a-f]+$' \
    'diff-filter=ACMR [0-9a-f]+ [0-9a-f]+$' '^rev-parse --verify --quiet [0-9a-f]+\^\{tree\}$'; do
    out=$(fg_hook "$f"); rc=$?
    check "a failed listing ($f) refuses the commit" "1" "$rc"
    has "...saying the staged files could not be listed" "$out" "could not list the staged files"
done
out=$(fg_hook '^write-tree$'); rc=$?
check "an index that cannot be frozen refuses the commit" "1" "$rc"
has "...saying it could not record the index" "$out" "could not record the index as a tree"
out=$(fg_hook '^-C .* ls-tree --full-tree [0-9a-f]+ -- \.weave/test-map\.conf$'); rc=$?
check "a map git cannot read refuses the commit" "1" "$rc"
has "...naming the cause" "$out" "could not resolve the suites for the staged files"
out=$(PATH="$T/fakegit:$PATH" FAKE_GIT_FAIL='diff --cached' harness "wv_staged_non_graph_state '$T/work'" 2>/dev/null); rc=$?
check "the classifier reports a failed listing, not an empty one" "1 " "$rc $out"
out=$(harness "wv_staged_non_graph_state '$T/work'" 2>/dev/null); rc=$?
check "control: the classifier lists staged work" "0 3" "$rc $(grep -c . <<< "$out")"
git reset -q; rm -f src/p.py src/s.sh; git checkout -q -- src/a.sh

echo "impact: the file-only JSON is valid for any path"
out=$(wv impact --files='src/q"x.sh' --json 2>/dev/null)
check "a path holding a quote round-trips" 'src/q"x.sh' "$(jq -r '.files[0]' <<< "$out" 2>/dev/null)"

echo ""
echo "resolver failure: $pass/$run passed"
[ "$pass" -eq "$run" ]
