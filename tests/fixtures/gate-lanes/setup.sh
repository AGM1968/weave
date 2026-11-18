#!/usr/bin/env bash
# Sourced by test-gate-lanes.sh and test-gate-roles.sh (split on wv-7e8216):
# the shared synthetic repository, whose HEAD carries this checkout's scripts/,
# and the assertion helpers. The caller sets SCRIPT_DIR, ROOT and the run/pass
# counters first.
set -uo pipefail
export WV_CALL_SOURCE=test
# Keep the inherited-budget scenario live in ordinary runs too; the one
# four-job case below must supply its own override (wv-6900e1).
export WV_GATE_JOBS=2


ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }
has()   { if grep -qF -- "$3" <<< "$2"; then ok "$1"; else bad "$1" "missing [$3] in: $(tail -8 <<< "$2")"; fi; }
hasnt() { if grep -qF -- "$3" <<< "$2"; then bad "$1" "unexpected [$3]"; else ok "$1"; fi; }
hasre() { if grep -qE -- "$3" <<< "$2"; then ok "$1"; else bad "$1" "no line matching /$3/ in: $(tail -8 <<< "$2")"; fi; }

T=$(mktemp -d /tmp/wv-gate-lanes-XXXXXX)
trap 'rm -rf "$T"' EXIT
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
unset WV_GATE_BASE WV_GATE_TREE WV_GATE_PHASE WV_GATE_ID WV_GATE_CONTEXT WV_HOOK_REEXEC
unset PYTHONPATH

mkdir -p "$T/bin" "$T/cfg" "$T/marks"
ln -s "$ROOT/scripts/wv" "$T/bin/wv"
export PATH="$T/bin:$PATH" WV_LIB_DIR="$ROOT/scripts"
export WV_HOT_ZONE="$T" WV_DB="$T/brain.db" WV_CONFIG_DIR="$T/cfg" WV_PROJECT_DIR="$T/work"
export WV_SUITE_LOG="$T/suite_runs.jsonl" WV_GATE_LOG="$T/gate_runs.jsonl"
export WV_SCRATCH_ROOT="$T/scratch"
export WV_AUTO_SYNC=0 WV_AUTO_CHECKPOINT=0 WV_REQUIRE_LEARNING=0 WV_RUN_CACHE=0
MARK="$T/marks"; W="$T/work"

git init -q -b main "$W"; cd "$W" || exit 1
git config user.name "Gate Test"; git config user.email gate@example.com
git config commit.gpgsign false; git config tag.gpgSign false
_gl_skip=()
git -C "$ROOT" ls-files -z -- scripts "${_gl_skip[@]}" \
    | tar -C "$ROOT" --null -T - -cf - | tar -xf -
# This synthetic repository holds only scripts/; external cases declare their own roles later.
jq '.enforcement = ["scripts/"] | .invoking |= map(select(startswith("scripts/")))
    | .entry_points |= with_entries(select(.key | startswith("scripts/"))) | .shared = []' \
    scripts/hooks/gate-roles.json > "$T/fixture-roles.json" &&
    cat "$T/fixture-roles.json" > scripts/hooks/gate-roles.json
mkdir -p src tests .weave
cat > tests/test-probe.sh <<PROBE_EOF
#!/bin/sh
echo run >> "$MARK/probe"
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
# A helper the fixture's checks use: strong at HEAD, it refuses a product
# carrying BUG in the frozen tree.
# The fixture copies modules with cross-file globals and local assignments.
# Declare its lint policy here: the source checkout's rc does not ship.
printf 'disable=SC2034,SC2155\n' > .shellcheckrc
cat > scripts/lib/wv-fixture-helper.sh <<'HELPER_EOF'
#!/usr/bin/env bash
fixture_src_ok() { ! git show "$WV_GATE_TREE:src/a.sh" 2>/dev/null | grep -q BUG; }
HELPER_EOF
git add -A && git -c core.hooksPath=/dev/null commit -q -m fixture
wv add "gate lanes fixture node" --status=active --force --criteria="c1|c2" --risks=low >/dev/null 2>&1
install -m 755 "$ROOT/scripts/hooks/pre-commit-weave.sh" .git/hooks/pre-commit
# The recovery module beside it, where this checkout has one (wv-669900); the
# name is assembled because the release strips that file.
_gl_rec=pre-commit-"recovery.sh"
[ ! -f "$ROOT/scripts/hooks/$_gl_rec" ] || install -m 644 "$ROOT/scripts/hooks/$_gl_rec" ".git/hooks/$_gl_rec"

HOOK=scripts/hooks/pre-commit-weave.sh
HELPER=scripts/lib/wv-fixture-helper.sh
CONTRACT=scripts/hooks/gate-roles.json
gate() { OUT=$(./.git/hooks/pre-commit 2>&1); RC=$?; }
runs() { if [ -f "$MARK/$1" ]; then wc -l < "$MARK/$1" | tr -d ' '; else echo 0; fi; }
lines() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }
reset_all() { git reset -q; git checkout -q -- .; git clean -qfd -- scripts src; rm -f "$MARK/probe"; }
commit_nohook() { git add -A && git -c core.hooksPath=/dev/null commit -q -m "$1"; }
# Fresh bytes each time: the pool reuses a green result for content it has seen.
n=0
fresh() { n=$((n+1)); printf '# fixture edit %s\n' "$n" >> "$1"; git add "$1"; }
stage_src() { n=$((n+1)); printf '#!/bin/sh\necho a-%s\n' "$n" > src/a.sh; git add src/a.sh; }
# into_hook <file> — insert <file>'s lines into the staged hook, where every
# lane runs them: after the frozen candidate and the role contract, before
# admission.
into_hook() {
    awk -v f="$1" '/^# _pc_git_pid — the git process/ { while ((getline l < f) > 0) print l } { print }' \
        "$HOOK" > "$T/hook.new" && cat "$T/hook.new" > "$HOOK" && git add "$HOOK"
}
# combined — one lane holding every staged gate file at once: the weaker
# check the review declined (prototype "one collective lane").
combined() {
    rm -rf "${T:?}/comb"; mkdir -p "$T/comb/tree"
    git checkout-index -a -f --prefix="$T/comb/tree/" 2>/dev/null
    find "$T/comb/tree" -mindepth 1 -maxdepth 1 ! -name scripts -exec rm -rf {} +
    git rev-parse HEAD > "$T/comb/weave-gate-lane"
    printf 'path=*\ntree=%s\nreuse=0\n' "$(git write-tree)" > "$T/comb/weave-gate-candidate"
    OUT=$(env -u WV_LIB_DIR -u WV_CLI bash "$T/comb/tree/$HOOK" 2>&1); RC=$?
}
