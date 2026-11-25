#!/usr/bin/env bash
# The frozen candidate the pre-commit gate judges (wv-8e34cd, epic wv-d67163).
#
# scripts/lib/wv-gate-snapshot.sh records the base commit and the index tree
# once; scripts/hooks/pre-commit-weave.sh reads every in-hook check from them
# and admits a commit only while the index and HEAD still match. Pinned here:
#   - reads and materialisations come from the frozen tree after the live
#     index has moved on, and never touch the real index;
#   - absent and unreadable stay apart; unborn branches and unmerged indexes;
#   - a file staged, or HEAD moved, while the gate's suites run is refused,
#     against a healthy control that passes;
#   - `git commit -a` is judged by the index git will commit (GIT_INDEX_FILE).
#   - routing reads the test maps git holds, the frozen index's and the
#     base's, and unions them (F5, wv-fe8007).
#   - git publishes only the tree the gate judged: the reference-transaction
#     hook refuses a commit whose index changed after admission (R1, wv-5f9d1c).
# shellcheck source=tests/lib/sed-inplace.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/sed-inplace.sh"  # sed -i is GNU-only (wv-076a98)
set -uo pipefail
export WV_TEST_SUITE=1
export WV_CALL_SOURCE=test

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS="$ROOT/scripts/hooks"
LIB="$ROOT/scripts/lib/wv-gate-snapshot.sh"

run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }
has()   { if grep -qF -- "$3" <<< "$2"; then ok "$1"; else bad "$1" "missing [$3] in: $2"; fi; }
hasnt() { if grep -qF -- "$3" <<< "$2"; then bad "$1" "unexpected [$3]"; else ok "$1"; fi; }

T=$(mktemp -d /tmp/wv-gate-snapshot-XXXXXX)
trap 'rm -rf "$T"' EXIT
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
unset WV_GATE_BASE WV_GATE_TREE WV_GATE_PHASE WV_GATE_ID WV_GATE_CONTEXT WV_HOOK_REEXEC
newrepo() {
    git init -q -b main "$1"
    git -C "$1" config user.name "Gate Test"; git -C "$1" config user.email gate@example.com
    git -C "$1" config commit.gpgsign false
}
# lib <repo> <command> — run a library call in a fresh shell inside <repo>,
# carrying the frozen ids of the last freeze in $T/frozen.
lib() {
    local repo=$1; shift
    ( cd "$repo" || exit 99
      # shellcheck source=scripts/lib/wv-gate-snapshot.sh
      source "$LIB"
      [ -f "$T/frozen" ] && source "$T/frozen"
      eval "$*" )
}
freeze() {
    rm -f "$T/frozen"
    ( cd "$1" || exit 99
      # shellcheck source=scripts/lib/wv-gate-snapshot.sh
      source "$LIB"
      gate_freeze || exit 1
      printf 'WV_GATE_TREE=%s\n' "$WV_GATE_TREE"
      if [ -n "${WV_GATE_BASE+x}" ]; then printf 'WV_GATE_BASE=%s\n' "$WV_GATE_BASE"; else echo 'unset WV_GATE_BASE'; fi
    ) > "$T/frozen.tmp" && mv "$T/frozen.tmp" "$T/frozen"
}

echo "library: what is frozen"
R="$T/lib"; newrepo "$R"
mkdir -p "$R/d"; echo one > "$R/a"; echo inner > "$R/d/f"; printf 'x\ty\n' > "$R/tab	name"
ln -s a "$R/link"
git -C "$R" add -A && git -C "$R" commit -q -m base
echo two > "$R/a"; echo new > "$R/b"; git -C "$R" rm -q d/f; git -C "$R" add a b
freeze "$R"; check "freeze succeeds" "0" "$?"
check "the frozen tree is the index written as a tree" "$(git -C "$R" write-tree)" "$(lib "$R" 'echo $WV_GATE_TREE')"
check "the frozen base is HEAD" "$(git -C "$R" rev-parse HEAD)" "$(lib "$R" 'echo $WV_GATE_BASE')"
check "the transition lists added, modified and deleted paths" "a b d/f" \
    "$(lib "$R" 'gate_changed ""' | tr '\0' ' ' | sed 's/ $//')"
check "a diff filter narrows it" "d/f" "$(lib "$R" 'gate_changed D' | tr '\0' ' ' | sed 's/ $//')"

# Concurrent readers may encounter another Git process's index lock. Neither
# freezing nor admission freshness needs to update the caller's index cache.
locked_index=$(sha256sum "$R/.git/index" | cut -d' ' -f1)
: > "$R/.git/index.lock"
lib "$R" 'gate_freeze'; check "freeze can read an index held by another Git writer" "0" "$?"
lib "$R" 'gate_frozen_intact'; check "freshness can read the same locked index" "0" "$?"
check "neither reader rewrites the caller index" "$locked_index" "$(sha256sum "$R/.git/index" | cut -d' ' -f1)"
rm "$R/.git/index.lock"

# Move the live index on; everything must still read the frozen candidate.
idx_before=$(sha256sum "$R/.git/index" | cut -d' ' -f1)
echo three > "$R/a"; echo late > "$R/c"; git -C "$R" add a c
idx_moved=$(sha256sum "$R/.git/index" | cut -d' ' -f1)
[ "$idx_before" != "$idx_moved" ] && ok "(control) the live index really moved" || bad "(control) the live index really moved"
check "gate_show reads the frozen index, not the live one" "two" "$(lib "$R" 'gate_show index a')"
check "gate_show base reads the base commit" "one" "$(lib "$R" 'gate_show base a')"
lib "$R" 'gate_blob index c' >/dev/null; check "a path staged after the freeze is absent (1)" "1" "$?"
lib "$R" 'gate_blob index d' >/dev/null; check "a directory is not a blob (1)" "1" "$?"
lib "$R" 'gate_blob base link' >/dev/null; check "a symbolic link is refused as non-regular (3), not read" "3" "$?"
lib "$R" 'gate_show base link' >/dev/null; check "...by gate_show too" "3" "$?"
check "an unusual path name resolves exactly" "x	y" "$(lib "$R" "gate_show base \$'tab\\tname'")"
mkdir -p "$T/out"
lib "$R" "gate_materialise index '$T/out' a b"; check "materialise succeeds" "0" "$?"
check "...writing the frozen bytes" "two new" "$(cat "$T/out/a" "$T/out/b" | tr '\n' ' ' | sed 's/ $//')"
check "...without touching the real index" "$idx_moved" "$(sha256sum "$R/.git/index" | cut -d' ' -f1)"
lib "$R" "gate_materialise index '$T/out' c" 2>/dev/null; check "materialising a path the side lacks fails" "1" "$?"
lib "$R" "gate_materialise index '' a" 2>/dev/null; check "an empty target directory is refused" "1" "$?"
check "gate_ls lists the frozen side's blobs under a path" "d/f" "$(lib "$R" 'gate_ls base d' | tr '\0' ' ' | sed 's/ $//')"
check "...and nothing under a path the side lacks" "" "$(lib "$R" 'gate_ls index d' | tr '\0' ' ')"
lib "$R" 'gate_frozen_intact'; check "the moved index is not intact" "1" "$?"
git -C "$R" reset -q -- c; echo two > "$R/a"; git -C "$R" add a
lib "$R" 'gate_frozen_intact'; check "an index restored to the frozen tree is intact again" "0" "$?"
lib "$R" 'WV_GATE_TREE=0000000000000000000000000000000000000000 gate_show index a' >/dev/null 2>&1
check "an unreadable side is an error (2), not absent" "2" "$?"
lib "$R" 'WV_GATE_TREE= gate_changed ""' >/dev/null 2>&1; check "no frozen tree: listing fails" "1" "$?"

echo "library: unborn, unmerged, moved HEAD"
U="$T/unborn"; newrepo "$U"; echo first > "$U/f"; git -C "$U" add f
freeze "$U"; check "an unborn branch freezes" "0" "$?"
check "...with no base" "unset" "$(lib "$U" 'echo ${WV_GATE_BASE-unset}')"
check "...and every staged path listed as added" "f" "$(lib "$U" 'gate_changed A' | tr '\0' ' ' | sed 's/ $//')"
lib "$U" 'gate_frozen_intact'; check "...and is intact" "0" "$?"
M="$T/unmerged"; newrepo "$M"; echo x > "$M/f"; git -C "$M" add f; git -C "$M" commit -q -m base
blob=$(git -C "$M" hash-object -w "$M/f")
printf '100644 %s 2\tf\n100644 %s 3\tf\n' "$blob" "$blob" | git -C "$M" update-index --index-info
freeze "$M" 2>/dev/null; check "an unmerged index does not freeze" "1" "$?"
git -C "$M" reset -q
freeze "$R"   # the restored lib repo, for the HEAD case
child=$(git -C "$R" commit-tree -p HEAD -m moved "$(git -C "$R" rev-parse 'HEAD^{tree}')")
git -C "$R" update-ref refs/heads/main "$child"
lib "$R" 'gate_frozen_intact'; check "HEAD moved after the freeze: not intact" "1" "$?"

# ── The hook ──────────────────────────────────────────────────────────────
echo "hook: the commit git writes is the one the gate judged"
mkdir -p "$T/bin" "$T/cfg" "$T/marks"
ln -s "$ROOT/scripts/wv" "$T/bin/wv"
export PATH="$T/bin:$PATH" WV_LIB_DIR="$ROOT/scripts"
export WV_HOT_ZONE="$T" WV_DB="$T/brain.db" WV_CONFIG_DIR="$T/cfg" WV_PROJECT_DIR="$T/work"
export WV_SUITE_LOG="$T/suite_runs.jsonl" WV_GATE_LOG="$T/gate_runs.jsonl"
export WV_AUTO_SYNC=0 WV_AUTO_CHECKPOINT=0 WV_REQUIRE_LEARNING=0 WV_RUN_CACHE=0
MARK="$T/marks"; W="$T/work"
newrepo "$W"; cd "$W" || exit 1
mkdir -p src tests scripts .weave
# The probe suite does what its marker says while the gate runs: stage a file
# into the repository's real index, or move HEAD.
cat > tests/test-probe.sh <<PROBE_EOF
#!/bin/sh
echo run >> "$MARK/probe"
[ -f "$MARK/stage" ] && { echo raced > "$W/src/raced.txt"; git -C "$W" add src/raced.txt; }
[ -f "$MARK/move" ] && git -C "$W" update-ref refs/heads/main "\$(cat "$MARK/move")"
exit 0
PROBE_EOF
chmod +x tests/test-probe.sh
printf '#!/bin/sh\necho run >> "%s/probe2"\nexit 0\n' "$MARK" > tests/test-probe2.sh
chmod +x tests/test-probe2.sh
cat > .weave/test-map.conf <<'MAP_EOF'
[map]
src/a.sh = tests/test-probe.sh
scripts/ = tests/test-probe.sh
tests/test-probe.sh = tests/test-probe.sh
MAP_EOF
printf '#!/bin/sh\necho a\n' > src/a.sh
printf '#!/bin/sh\necho "s"\n' > scripts/s.sh
git add -A && git -c core.hooksPath=/dev/null commit -q -m fixture
wv add "snapshot fixture node" --status=active --force --criteria="c1|c2" --risks=low >/dev/null 2>&1
# Each run stages new bytes: the pool reuses a green result for content it has
# already seen, and a reused probe would not run.
n=0
precommit() {
    n=$((n+1)); printf '#!/bin/sh\necho a-%s\n' "$n" > src/a.sh; git add src/a.sh
    OUT=$(bash "$HOOKS/pre-commit-weave.sh" 2>&1); RC=$?
}
reset() { rm -f "$MARK/probe" "$MARK/stage" "$MARK/move"; git reset -q -- src/raced.txt 2>/dev/null; rm -f src/raced.txt; }

reset; precommit
check "(control) a quiet gate admits the commit" "0" "$RC"
check "(control) ...and ran the probe suite" "1" "$(wc -l < "$MARK/probe" 2>/dev/null | tr -d ' ')"
reset; touch "$MARK/stage"; precommit
check "a file staged while the suites ran is refused" "1" "$RC"
has "...naming why" "$OUT" "the index or HEAD changed while the gate ran"
check "...and the probe did stage it" "src/raced.txt" "$(git diff --cached --name-only -- src/raced.txt)"
reset
moved=$(git commit-tree -p HEAD -m moved "$(git rev-parse 'HEAD^{tree}')")
before=$(git rev-parse HEAD)
echo "$moved" > "$MARK/move"; precommit
check "HEAD moved while the suites ran is refused" "1" "$RC"
git update-ref refs/heads/main "$before"; reset
precommit
check "(control) the same commit passes once nothing moves" "0" "$RC"
git -c core.hooksPath=/dev/null commit -q -m a2

# A commit -a is judged by the index git commits (GIT_INDEX_FILE), not the
# repository's index, which does not hold the change.
printf '#!/bin/sh\nexec bash %s/pre-commit-weave.sh "$@"\n' "$HOOKS" > .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
if command -v shellcheck >/dev/null 2>&1; then
    # Interpolation is the point: a warning-level finding in the committed bytes.
    # shellcheck disable=SC2016
    printf '#!/bin/sh\necho "$never_assigned"\n' > scripts/s.sh
    reset; OUT=$(git commit -qam "lint by -a" 2>&1); RC=$?
    check "git commit -a: a lint finding in the committed bytes is refused" "1" "$RC"
    has "...by shellcheck" "$OUT" "SC2154"
    git checkout -q -- scripts/s.sh
else
    echo "  - shellcheck unavailable: the commit -a lint case is skipped"
fi
printf '#!/bin/sh\necho a3\n' > src/a.sh
reset; OUT=$(git commit -qam "clean -a" 2>&1); RC=$?
check "(control) git commit -a with clean content passes" "0" "$RC"
check "...and the commit carries it" "a3" "$(git show HEAD:src/a.sh | tail -1 | sed 's/echo //')"

if command -v ruff >/dev/null 2>&1; then
    echo "ruff: staged source and configuration, not the working tree (wv-3080d7)"
    ruff_base=$(git rev-parse HEAD)
    printf 'undefined_name\n' > src/staged.py
    git add src/staged.py
    printf 'print("working-tree fix")\n' > src/staged.py
    OUT=$(git commit -qm 'staged Python error' 2>&1); RC=$?
    check "ruff refuses an error fixed only in the working tree" "1" "$RC"
    has "...checking the staged bytes" "$OUT" "F821"
    git reset --hard -q "$ruff_base"

    printf 'print("staged clean")\n' > 'src/with space.py'; git add 'src/with space.py'
    printf 'undefined_name\n' > 'src/with space.py'
    OUT=$(git commit -qm 'staged Python clean' 2>&1); RC=$?
    check "(control) clean staged bytes pass, including a spaced path" "0" "$RC"
    git reset --hard -q "$ruff_base"

    printf '[lint]\nselect = ["EXE"]\n' > ruff.toml
    printf 'print("ok")\n' > src/mode.py; chmod 755 src/mode.py
    git add ruff.toml src/mode.py; chmod 644 src/mode.py
    OUT=$(git commit -qm 'staged executable without shebang' 2>&1); RC=$?
    check "ruff checks the frozen executable bit, not the working mode" "1" "$RC"
    has "...detecting the missing shebang" "$OUT" "EXE002"
    git reset --hard -q "$ruff_base"

    printf '[lint]\nselect = ["EXE"]\n' > ruff.toml
    printf '#!/usr/bin/env python3\nprint("ok")\n' > src/mode.py; chmod 755 src/mode.py
    git add ruff.toml src/mode.py; chmod 644 src/mode.py
    OUT=$(git commit -qm 'staged executable with shebang' 2>&1); RC=$?
    check "(control) a valid frozen executable passes despite the working mode" "0" "$RC"
    git reset --hard -q "$ruff_base"

    printf '[lint]\nselect = ["F821"]\n' > ruff.toml
    printf 'undefined_name\n' > src/config.py; git add ruff.toml src/config.py
    printf '[lint]\nignore = ["F821"]\n' > ruff.toml
    OUT=$(git commit -qm 'staged Ruff rules' 2>&1); RC=$?
    check "ruff does not take an unstaged weakening of its config" "1" "$RC"
    has "...applying the frozen rules" "$OUT" "F821"
    git reset --hard -q "$ruff_base"

    # Both inherited F401 and the nested F821 override must remain effective.
    printf '[tool.ruff.lint]\nselect = ["F401", "F821"]\n' > pyproject.toml
    printf 'extend = "../pyproject.toml"\n[lint]\nextend-ignore = ["F821"]\n' > src/.ruff.toml
    printf 'import os\nundefined_name\n' > src/inherited.py
    git add pyproject.toml src/.ruff.toml src/inherited.py
    OUT=$(git commit -qm 'inherited frozen Ruff rules' 2>&1); RC=$?
    check "nested Ruff configuration inherits frozen parent rules" "1" "$RC"
    has "...retaining the inherited rule" "$OUT" "F401"
    hasnt "...retaining the nested override" "$OUT" "F821"
    printf 'undefined_name\n' > src/inherited.py; git add src/inherited.py
    OUT=$(git commit -qm 'nested Ruff override control' 2>&1); RC=$?
    check "(control) legitimate nested rule selection can pass" "0" "$RC"
    git reset --hard -q "$ruff_base"

    # Import sorting needs unchanged modules too. The unselected package has
    # its own lint debt; supplying context must not start linting it as well.
    mkdir -p localpkg
    printf 'from typing import Any\nimport os\n\nthing = 1\n' > localpkg/__init__.py
    printf '[lint]\nselect = ["I"]\n' > ruff.toml
    git add ruff.toml localpkg/__init__.py
    git -c core.hooksPath=/dev/null commit -qm 'package context baseline'
    printf 'import requests\n\nfrom localpkg import thing\n\nprint(requests, thing)\n' > src/context.py
    git add src/context.py; rm -rf localpkg
    OUT=$(git commit -qm 'frozen package context' 2>&1); RC=$?
    check "unchanged package context comes from Git, without linting unselected files" "0" "$RC"
    git reset --hard -q "$ruff_base"

    printf 'fix = true\n[lint]\nselect = ["F401"]\n' > ruff.toml
    printf 'import os\n' > src/fixable.py; git add ruff.toml src/fixable.py
    OUT=$(RUFF_OUTPUT_FILE="$T/ruff-output" git commit -qm 'Ruff check must not fix' 2>&1); RC=$?
    check "auto-fix configuration cannot repair and admit staged errors" "1" "$RC"
    has "...reporting the fixable error instead" "$OUT" "F401"
    check "...without rewriting the working file" "import os" "$(cat src/fixable.py)"
    git reset --hard -q "$ruff_base"

    mkdir -p $'src/newline\n.weave'
    printf 'undefined_name\n' > $'src/newline\n.weave/name.py'
    git add $'src/newline\n.weave/name.py'
    OUT=$(git commit -qm 'Python path with newline' 2>&1); RC=$?
    check "a newline does not hide a Python path behind the .weave exclusion" "1" "$RC"
    has "...still finding its staged error" "$OUT" "F821"
    git reset --hard -q "$ruff_base"

    # The snapshot's config parser must not import code from the working tree.
    printf 'import subprocess\nsubprocess.call = lambda *args, **kwargs: 0\n' > tomllib.py
    printf 'undefined_name\n' > src/shadowed.py; git add src/shadowed.py
    OUT=$(git commit -qm 'working-tree module shadow' 2>&1); RC=$?
    check "an untracked module cannot turn Ruff's verdict into success" "1" "$RC"
    has "...the real checker still runs" "$OUT" "F821"
    rm -f tomllib.py; rm -rf __pycache__
    git reset --hard -q "$ruff_base"

    # Neither a user configuration nor a configuration above the private
    # checkout may weaken the defaults when this tree has no Ruff config.
    mkdir -p "$T/ruff-user/ruff"
    printf '[lint]\nignore = ["F821"]\n' > "$T/ruff-user/ruff/ruff.toml"
    printf 'undefined_name\n' > src/ambient.py; git add src/ambient.py
    OUT=$(XDG_CONFIG_HOME="$T/ruff-user" git commit -qm 'ambient Ruff config' 2>&1); RC=$?
    check "user Ruff configuration cannot weaken staged lint" "1" "$RC"
    has "...using project defaults instead" "$OUT" "F821"
    git reset --hard -q "$ruff_base"

    printf '[lint]\nignore = ["F821"]\n' > "$T/outside-ruff.toml"
    printf '[tool.ruff]\nextend = "%s/outside-ruff.toml"\n' "$T" > pyproject.toml
    printf 'undefined_name\n' > src/external.py; git add pyproject.toml src/external.py
    OUT=$(git commit -qm 'outside Ruff inheritance' 2>&1); RC=$?
    check "configuration inheritance cannot read outside the frozen tree" "1" "$RC"
    git reset --hard -q "$ruff_base"
else
    echo "  - ruff unavailable: staged Python cases are skipped"
fi

echo "F5: routing reads the maps git holds, and keeps both sides' routes (wv-fe8007)"
rm -f .git/hooks/pre-commit
suites() { wv impact --suites --files="$1" "${@:2}" 2>/dev/null | jq -r 'map(.name) | sort | join(" ")'; }
tiers() { wv impact --suites --files="$1" "${@:2}" 2>/dev/null | jq -r 'map("\(.name)=\(.tier)") | sort | join(" ")'; }
runs() { wc -l < "$MARK/$1" 2>/dev/null | tr -d ' ' || true; }
unmap() { sed_inplace '/^src\/a\.sh = /d' .weave/test-map.conf; }
remap() { git checkout -q HEAD -- .weave/test-map.conf; }
check "(control) HEAD's map routes src/a.sh to the probe" "tests/test-probe.sh" "$(suites src/a.sh --map-rev=HEAD)"
unmap
check "--map-rev ignores an unstaged row removal" "tests/test-probe.sh" "$(suites src/a.sh --map-rev=HEAD)"
check "(control) without it, the working-tree file routes" "" "$(suites src/a.sh)"
remap
printf 'src/a.sh = tests/test-probe2.sh\n' >> .weave/test-map.conf; unmap
printf 'src/a.sh = tests/test-probe2.sh\n' >> .weave/test-map.conf; git add .weave/test-map.conf
idx=$(git write-tree)
check "two maps: the routes of both are kept" "tests/test-probe.sh tests/test-probe2.sh" \
    "$(suites src/a.sh --map-rev="$idx" --map-rev=HEAD)"
check "...from a tree as well as a commit" "tests/test-probe2.sh" "$(suites src/a.sh --map-rev="$idx")"
printf '[heavy]\ntests/test-probe2.sh\n' >> .weave/test-map.conf; git add .weave/test-map.conf
idx=$(git write-tree)
check "a suite one map marks heavy and the other routes light stays light" \
    "tests/test-probe.sh=light tests/test-probe2.sh=light" "$(tiers src/a.sh --map-rev="$idx" --map-rev=HEAD)"
check "(control) heavy in the only map: heavy" "tests/test-probe2.sh=heavy" "$(tiers src/a.sh --map-rev="$idx")"
remap
nomap=$(git commit-tree -m "no map" "$(git mktree < /dev/null)")
check "a revision without a map routes by the heuristics alone" "tests/test-probe.sh" \
    "$(suites tests/test-probe.sh --map-rev="$nomap")"
wv impact --suites --files=src/a.sh --map-rev=0000000000000000000000000000000000000000 >/dev/null 2>&1
check "an unreadable revision fails the resolution" "1" "$?"
# R4 (wv-77b743): a map git holds as a link is refused, never parsed as its
# pathname and never followed into the working tree.
lnk=$(printf 'routes.conf' | git hash-object -w --stdin)
real=$(git hash-object -w .weave/test-map.conf)
symtree=$(printf '040000 tree %s\t.weave\n' "$(printf '120000 blob %s\ttest-map.conf\n100644 blob %s\troutes.conf\n' "$lnk" "$real" | git mktree)" | git mktree)
regtree=$(printf '040000 tree %s\t.weave\n' "$(printf '100644 blob %s\ttest-map.conf\n' "$real" | git mktree)" | git mktree)
check "(control) a regular map in a tree routes" "tests/test-probe.sh" "$(suites src/a.sh --map-rev="$regtree")"
out=$(wv impact --suites --files=src/a.sh --map-rev="$symtree" 2>&1); rc=$?
check "a map held as a link fails the resolution" "1" "$rc"
has "...saying it is not a regular file" "$out" "not a regular file"

reset; rm -f "$MARK/probe2"; unmap; precommit
check "hook: an unstaged row removal still runs the suite" "1" "$(runs probe)"
check "...and the commit is admitted" "0" "$RC"
remap; reset; unmap; git add .weave/test-map.conf; precommit
check "hook: a staged row removal still runs the suite in that commit" "1" "$(runs probe)"
remap; reset; rm -f "$MARK/probe2"
printf 'src/a.sh = tests/test-probe2.sh\n' >> .weave/test-map.conf; git add .weave/test-map.conf; precommit
check "hook: a staged new route runs its suite" "1" "$(runs probe2)"
check "...alongside HEAD's" "1" "$(runs probe)"
remap; reset
cp .weave/test-map.conf .weave/routes.conf; git add .weave/routes.conf
git update-index --cacheinfo "120000,$lnk,.weave/test-map.conf"; precommit
check "hook: a staged map held as a link refuses the commit" "1" "$RC"
has "...saying the gate does not follow links" "$OUT" "is not a regular file"
check "...before any suite ran" "" "$(runs probe)"
git rm -q --cached .weave/routes.conf; rm -f .weave/routes.conf; remap; reset

echo "R3: a selected suite that is absent is not a passed one (wv-fb861c)"
dropsuite() { git rm -q tests/test-probe.sh; sed_inplace '/test-probe\.sh/d' .weave/test-map.conf; git add .weave/test-map.conf; }
restore() { git reset -q; git checkout -q HEAD -- .weave tests src; rm -f .weave/test-map-retired.conf.new; reset; }
dropsuite; precommit
check "deleting a suite HEAD's map still routes to refuses the commit" "1" "$RC"
has "...naming the absent suite" "$OUT" "the judged tree does not contain it"
restore
printf 'wv-test tests/test-probe.sh = src/*\n' > .weave/test-map-retired.conf; git add -f .weave/test-map-retired.conf
dropsuite; precommit
check "a retirement staged in the same commit does not admit the deletion" "1" "$RC"
restore; rm -f .weave/test-map-retired.conf
printf 'wv-test tests/test-probe.sh = src/*\n' > .weave/test-map-retired.conf
git add -f .weave/test-map-retired.conf; git -c core.hooksPath=/dev/null commit -q -m "retire the probe"
dropsuite; precommit
check "(control) retired at HEAD first, the deletion is admitted" "0" "$RC"
has "...and says so" "$OUT" "absent and retired; not run"
restore; git rm -q .weave/test-map-retired.conf; git -c core.hooksPath=/dev/null commit -q -m "unretire"
printf '#!/bin/sh\nexit 0\n' > tests/test-gone.sh; git add tests/test-gone.sh; git -c core.hooksPath=/dev/null commit -q -m "an unrouted suite"
git rm -q tests/test-gone.sh; precommit
check "(control) deleting an unrouted suite is admitted: its own run was a suggestion" "0" "$RC"
restore
# This hook fixture is a consumer: it cannot execute a checkout suite that is
# absent on disk. Frozen self-host execution of missing checkout suites is
# covered through the public pool in test_gate_suite.py.
rm -f tests/test-probe.sh; precommit
check "a consumer suite absent from the checkout refuses even when Git holds it" "1" "$RC"
check "...and does not claim to have executed the missing suite" "no" "$([ -s "$MARK/probe" ] && echo yes || echo no)"
restore
out=$( cd "$W" && REPO_ROOT="$W" WV=wv
       hook_progress() { :; }; hook_duration_ms() { echo 0; }
       # shellcheck source=scripts/lib/wv-gate-pool.sh
       source "$ROOT/scripts/lib/wv-gate-pool.sh"
       printf '0\ttests/test-never-written.sh\t0\n' | run_hook_suites 2>&1 ); rc=$?
check "the pool refuses a missing suite rather than passing" "1" "$rc"
has "...naming it" "$out" "does not exist — refusing"

echo "R1: git publishes only the tree the gate judged (wv-5f9d1c)"
# The review's window: a file staged when the gate records its result, after
# its last comparison and before git reads the index. wv is wrapped so the
# staging happens at exactly that call.
rm -f "$T/bin/wv"
cat > "$T/bin/wv" <<WRAP_EOF
#!/bin/sh
if [ "\$1 \$2" = "test-record gate" ] && [ -f "$MARK/stage-at-record" ]; then
    echo raced > "$W/src/raced.txt"; git -C "$W" add src/raced.txt
fi
exec "$ROOT/scripts/wv" "\$@"
WRAP_EOF
chmod +x "$T/bin/wv"
printf '#!/bin/sh\nexec bash %s/pre-commit-weave.sh "$@"\n' "$HOOKS" > .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
records() { find "$(git rev-parse --git-path weave-gate)" -name 'admitted-*' 2>/dev/null | wc -l | tr -d ' '; }
k=0
change() { k=$((k+1)); printf '#!/bin/sh\necho r1-%s\n' "$k" > src/a.sh; git add src/a.sh; }
unrace() { rm -f "$MARK/stage-at-record"; git reset -q -- src/raced.txt 2>/dev/null; rm -f src/raced.txt; }

before=$(git rev-parse HEAD); change; touch "$MARK/stage-at-record"
OUT=$(git commit -qm "race without the binding hook" 2>&1); RC=$?
check "(the limit) without the binding hook the raced commit lands" "0" "$RC"
check "...carrying the unjudged file" "src/raced.txt" "$(git diff-tree -r --name-only HEAD | grep raced)"
has "...and the gate says its admission is check-then-use" "$OUT" "admission is check-then-use here"
git reset -q --hard "$before"; unrace

printf '#!/bin/sh\n# Weave reference-transaction (fixture wrapper)\nexec bash %s/reference-transaction-weave.sh "$@"\n' "$HOOKS" \
    > .git/hooks/reference-transaction
chmod +x .git/hooks/reference-transaction
before=$(git rev-parse HEAD); change; touch "$MARK/stage-at-record"
OUT=$(git commit -qm "race with the binding hook" 2>&1); RC=$?
check "with the binding hook the raced commit is refused" "1" "$([ "$RC" -ne 0 ] && echo 1 || echo 0)"
has "...naming the judged tree" "$OUT" "is not the tree the pre-commit gate judged"
check "...HEAD did not move" "$before" "$(git rev-parse HEAD)"
check "...and the record is gone" "0" "$(records)"
unrace
OUT=$(git commit -qm "the same commit, nothing raced" 2>&1); RC=$?
check "(control) the same commit with nothing raced lands" "0" "$RC"
hasnt "...with no limit note" "$OUT" "check-then-use"
check "...leaving no record" "0" "$(records)"
OUT=$(git commit -q --amend -m "amended" 2>&1); RC=$?
check "(control) an amend lands" "0" "$RC"
ok_refs=0
git config tag.gpgSign false  # a signing user config would make the tag annotated
git branch r1-side && git checkout -q r1-side && git checkout -q main && git tag r1-tag \
    && git update-ref refs/heads/r1-other HEAD && git branch -q -D r1-side r1-other && ok_refs=1
check "(control) branch, checkout, tag and update-ref pass the binding hook" "1" "$ok_refs"

# The record's contract, driven directly: the hook's parent is this subshell.
rt() {  # <state> <record tree> <record start or "now"> -> rc, and whether the record survived
    # $BASHPID is taken here, not inside $(...): there it names the command
    # substitution's own child, whose start time can fall in the next second
    # (wv-ef2683), and the hook then rightly drops the record.
    ( dir=$(git rev-parse --git-path weave-gate); mkdir -p "$dir"; me=$BASHPID
      st=$3; [ "$st" = now ] && st=$(ps -o lstart= -p "$me" | sed 's/^ *//; s/ *$//')
      printf 'tree=%s\nstart=%s\n' "$2" "$st" > "$dir/admitted-$BASHPID"
      bash "$HOOKS/reference-transaction-weave.sh" "$1" \
          < <(printf '%s %s refs/heads/main\n' "$(git rev-parse HEAD~1)" "$(git rev-parse HEAD)") >/dev/null 2>&1
      rc=$?; [ -f "$dir/admitted-$BASHPID" ] && kept=kept || kept=gone
      rm -f "$dir/admitted-$BASHPID"; echo "$rc $kept" )
}
headtree=$(git rev-parse 'HEAD^{tree}')
check "prepared, judged tree matches: passes, record kept for the commit step" "0 kept" "$(rt prepared "$headtree" now)"
check "prepared, another tree: aborts" "1 kept" "$(rt prepared 4b825dc642cb6eb9a060e54bf8d69288fbee4904 now)"
check "committed: the record is consumed" "0 gone" "$(rt committed "$headtree" now)"
# Newer git (2.56.1 seen; not 2.47.3) runs the hook in a "preparing" state
# before "prepared". The hook consumed the record there, so at "prepared" it
# found none and every commit passed unchecked (wv-412db3): the record now
# ends only in a terminal state.
check "preparing (newer git): passes, record kept for prepared" "0 kept" "$(rt preparing "$headtree" now)"
check "preparing then prepared with another tree: still aborts" "1 kept" \
    "$( ( dir=$(git rev-parse --git-path weave-gate); mkdir -p "$dir"; me=$BASHPID
          st=$(ps -o lstart= -p "$me" | sed 's/^ *//; s/ *$//')
          printf 'tree=%s\nstart=%s\n' 4b825dc642cb6eb9a060e54bf8d69288fbee4904 "$st" > "$dir/admitted-$me"
          line=$(printf '%s %s refs/heads/main\n' "$(git rev-parse HEAD~1)" "$(git rev-parse HEAD)")
          bash "$HOOKS/reference-transaction-weave.sh" preparing <<< "$line" >/dev/null 2>&1
          bash "$HOOKS/reference-transaction-weave.sh" prepared <<< "$line" >/dev/null 2>&1; rc=$?
          [ -f "$dir/admitted-$me" ] && kept=kept || kept=gone; rm -f "$dir/admitted-$me"; echo "$rc $kept" ) )"
check "aborted: the record is consumed" "0 gone" "$(rt aborted "$headtree" now)"
check "a state git may add later: passes, record kept" "0 kept" "$(rt some-future-state "$headtree" now)"
check "a record from an earlier process with this pid is dropped, not applied" "0 gone" \
    "$(rt prepared 4b825dc642cb6eb9a060e54bf8d69288fbee4904 'Thu Jan  1 00:00:00 1970')"
rm -f .git/hooks/reference-transaction .git/hooks/pre-commit

echo "focused pytest: consumer checkout interpreter and mutable test bytes"
mkdir -p tests/weave_quality .venv/bin
printf '.venv/\n' >> .git/info/exclude
# Pick the interpreter by what it can import, not by whether it exists: the
# release projection has a .venv without pytest, since build-release.sh strips
# the dev group, and the system python3 need not have it either (wv-0d0aea).
pytest_python=
for cand in "$ROOT/.venv/bin/python3" "$(command -v python3)"; do
    [ -x "$cand" ] && "$cand" -c 'import pytest' 2>/dev/null && { pytest_python=$cand; break; }
done
if [ -z "$pytest_python" ]; then
    # Provision one the way the gate's python-dev recipe does.
    mkdir -p "$T/pytest-env-project"
    cat > "$T/pytest-env-project/pyproject.toml" <<'PYTEST_ENV'
[project]
name = "checkout-pytest-env"
version = "0.1.0"
requires-python = ">=3.11,<4.0"
dependencies = ["pytest>=9,<10"]
[tool.poetry]
package-mode = false
PYTEST_ENV
    python3 -m venv --without-pip "$T/pytest-env" &&
        ( cd "$T/pytest-env-project" &&
          export VIRTUAL_ENV="$T/pytest-env" PATH="$T/pytest-env/bin:$PATH" \
              POETRY_VIRTUALENVS_CREATE=false POETRY_KEYRING_ENABLED=false \
              POETRY_CACHE_DIR="$T/poetry-cache" POETRY_CONFIG_DIR="$T/poetry-config" &&
          poetry lock --no-interaction && poetry sync --no-root --no-interaction ) \
        > "$T/pytest-env.log" 2>&1 &&
        pytest_python="$T/pytest-env/bin/python3"
fi
check "the checkout fixture has an interpreter that imports pytest" "0" \
    "$("${pytest_python:-false}" -c 'import pytest' >/dev/null 2>&1; echo $?)"
printf '#!/bin/sh\necho CHECKOUT_PYTEST_PYTHON\nexec "%s" "$@"\n' \
    "$pytest_python" > .venv/bin/python3
chmod +x .venv/bin/python3
printf 'def test_checkout():\n    assert False\n' > tests/weave_quality/test_checkout.py
git add tests/weave_quality/test_checkout.py
printf 'def test_checkout():\n    assert True\n' > tests/weave_quality/test_checkout.py
precommit
check "consumer focused pytest judges checkout bytes, not the staged defect" "0" "$RC"
has "...using the ignored checkout interpreter" "$OUT" "CHECKOUT_PYTEST_PYTHON"
has "...labelled checkout rather than frozen" "$OUT" "focused pytest checks (execution mode: checkout)"
has "...executing the passing checkout test" "$OUT" "1 passed"
printf 'def test_checkout():\n    assert False\n' > tests/weave_quality/test_checkout.py
precommit
check "a failing consumer checkout test refuses" "1" "$RC"
has "...because pytest executed that test" "$OUT" "FAILED tests/weave_quality/test_checkout.py::test_checkout"
git rm -q -f tests/weave_quality/test_checkout.py
rm -rf .venv tests/weave_quality

# Keep the frozen controls at their actual eligibility boundary. A consumer
# cannot prove staged pytest isolation; a committed self-hosting gate can.
cp -R "$ROOT/scripts/." scripts/
# These controls need scripts/ enforcement, not source-only external checks.
jq '.enforcement = ["scripts/"] | .invoking |= map(select(startswith("scripts/")))
    | .entry_points |= with_entries(select(.key | startswith("scripts/"))) | .shared = []' \
    scripts/hooks/gate-roles.json > "$T/fixture-roles.json" &&
    cat "$T/fixture-roles.json" > scripts/hooks/gate-roles.json
git add scripts
git -c core.hooksPath=/dev/null commit -q -m "self-hosting focused pytest fixture"

echo "focused pytest: self-hosting staged tests and locked private dependencies"
mkdir -p tests/lib tests/weave_quality
# This fixture supplies its own launcher, not a development-only source file.
pytest_suite=$(jq -r '.suites | to_entries[] | select(.value.executor == "pytest") | .key' \
    "$ROOT/scripts/lib/wv-gate-provision.json")
printf '#!/bin/bash\nexec .venv/bin/python3 -m pytest "$@" -q --tb=short -p no:cacheprovider\n' > "$pytest_suite"
cat > pyproject.toml <<'PYTEST_PROJECT'
[project]
name = "frozen-pytest-probe"
version = "0.1.0"
requires-python = ">=3.11,<4.0"
dependencies = []
[tool.poetry]
package-mode = false
[dependency-groups]
dev = ["pytest>=9,<10"]
PYTEST_PROJECT
lock_rc=0
POETRY_VIRTUALENVS_CREATE=false POETRY_KEYRING_ENABLED=false \
    POETRY_CACHE_DIR="$T/poetry-cache" POETRY_CONFIG_DIR="$T/poetry-config" \
    poetry lock --no-interaction > "$T/pytest-lock.log" 2>&1 || lock_rc=$?
check "the fixture has a real locked pytest dependency" "0" "$lock_rc"
printf 'def test_frozen():\n    assert True\n' > tests/weave_quality/test_frozen.py
git add pyproject.toml poetry.lock "$pytest_suite" tests/weave_quality/test_frozen.py
precommit
check "(control) a healthy focused pytest run admits" "0" "$RC"
has "...and executes the staged test" "$OUT" "1 passed"
check "...without creating a checkout venv" "absent" "$([ -e .venv ] && echo present || echo absent)"
printf 'def test_frozen():\n    assert False\n' > tests/weave_quality/test_frozen.py
git add tests/weave_quality/test_frozen.py
printf 'def test_frozen():\n    assert True\n' > tests/weave_quality/test_frozen.py
precommit
check "a staged pytest defect refuses despite an unstaged repair" "1" "$RC"
has "...because the staged assertion failed, not setup" "$OUT" "FAILED tests/weave_quality/test_frozen.py::test_frozen"
printf '#!/bin/bash\nexit 0\n' > "$pytest_suite"
git add "$pytest_suite"
precommit
check "a staged launcher cannot waive the protected pytest command" "1" "$RC"
has "...the staged assertion still fails" "$OUT" "FAILED tests/weave_quality/test_frozen.py::test_frozen"
git add tests/weave_quality/test_frozen.py
rm tests/weave_quality/test_frozen.py
precommit
check "a staged test missing on disk still runs" "0" "$RC"
has "...and reports the frozen test passing" "$OUT" "1 passed"
git rm -q -f "$pytest_suite" || exit 1
precommit
check "self-hosting focused pytest needs no development launcher" "0" "$RC"
has "...the protected command still runs the staged test" "$OUT" "1 passed"

echo ""
echo "test-gate-snapshot: $pass/$run passed"
[ "$pass" -eq "$run" ]
