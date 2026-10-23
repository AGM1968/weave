#!/usr/bin/env bash
# test-git-hook-install.sh — Weave git hooks land where git runs them (wv-76c726)
#
# install.sh wrote $REPO_ROOT/.git/hooks (init-repo) or git-dir/hooks (the dev
# refresh). In a linked worktree .git is a file, so it returned 0 having
# installed nothing; under core.hooksPath git never ran what it wrote; and a
# custom hook was skipped with a one-line notice. wv doctor looked at the same
# wrong path and passed a hook git would not execute.
#
# `wv init-repo` runs the INSTALLED wv-init-repo, so an end-to-end init here
# would test the last install, not this checkout (wv-6a0cab). The functions are
# taken from this checkout's install.sh instead: both copies (installer and the
# generated wv-init-repo) must be identical, and one is driven directly.

set -euo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
export WV_CALL_SOURCE=test
# The commit gate runs suites with core.hooksPath=/dev/null injected through
# GIT_CONFIG_* (scripts/lib/wv-gate-pool.sh); every fixture repo here would read
# it as its own hooks path. These cases are about each repository's config.
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL="$PROJECT_ROOT/install.sh"

pass=0
run=0
ok() { echo "  ✓ $1"; pass=$((pass + 1)); run=$((run + 1)); }
bad() { echo "  ✗ $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/      /'; run=$((run + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected: $2"$'\n'"actual:   $3"; fi; }
has() { if [[ "$3" == *"$2"* ]]; then ok "$1"; else bad "$1" "missing '$2' in: $3"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "Weave git hooks install where git runs them (wv-76c726)"

# Every top-level definition of a function in install.sh, one block per copy.
copies() {
    awk -v fn="$1" '$0 ~ "^"fn"\\(\\) \\{" {f=1; n++} f {print n": "$0} f && /^}/ {f=0}' "$INSTALL"
}
echo "=== one definition, two copies ==="
for fn in resolve_git_hook_dir set_hook_dir_or_report install_git_hook_from_repo remove_retired_git_hook; do
    all=$(copies "$fn")
    one=$(grep '^1: ' <<<"$all" | sed 's/^1: //' || true)
    two=$(grep '^2: ' <<<"$all" | sed 's/^2: //' || true)
    if [ -n "$one" ] && [ "$one" = "$two" ]; then
        ok "$fn: the installer and the generated wv-init-repo carry the same body"
    else
        delta=$(diff <(printf '%s\n' "$one") <(printf '%s\n' "$two") || true)
        bad "$fn: the installer and the generated wv-init-repo carry the same body" "$delta"
    fi
done

# shellcheck disable=SC2034  # read by the sourced install.sh functions
YELLOW="" GREEN="" NC=""
eval "$(copies resolve_git_hook_dir | grep '^1: ' | sed 's/^1: //')"
eval "$(copies set_hook_dir_or_report | grep '^1: ' | sed 's/^1: //')"
eval "$(copies install_git_hook_from_repo | grep '^1: ' | sed 's/^1: //')"

new_repo() {
    git init -q "$1"
    git -C "$1" config user.name "Hook Install Test"
    git -C "$1" config user.email hooks@example.invalid
    git -C "$1" config commit.gpgsign false
}
SRC="$PROJECT_ROOT/scripts/hooks/pre-commit-weave.sh"

echo "=== where git runs hooks ==="
new_repo "$TMP/plain"
got=$(resolve_git_hook_dir "$TMP/plain")
check "a plain repository: its .git/hooks" "$(cd "$TMP/plain" && pwd -P)/.git/hooks" "$got"

git -C "$TMP/plain" commit -q --allow-empty -m init
git -C "$TMP/plain" worktree add -q "$TMP/linked" 2>/dev/null
common=$(cd "$TMP/plain" && pwd -P)/.git/hooks
got=$(resolve_git_hook_dir "$TMP/linked")
check "a linked worktree (.git is a file): the common hooks dir git uses" "$common" "$got"
set_hook_dir_or_report "$TMP/linked" 2>/dev/null
(cd "$TMP/linked" && install_git_hook_from_repo "$SRC" "Weave pre-commit" "pre-commit" >/dev/null 2>&1)
if [ -x "$common/pre-commit" ] && cmp -s "$SRC" "$common/pre-commit"; then
    ok "installing from a linked worktree puts an executable hook where git runs it"
else
    bad "installing from a linked worktree puts an executable hook where git runs it" "$(ls -l "$common" 2>&1)"
fi
hookdir_from_git=$(git -C "$TMP/linked" rev-parse --git-path hooks)
case "$hookdir_from_git" in /*) ;; *) hookdir_from_git="$(cd "$TMP/linked" && pwd -P)/$hookdir_from_git" ;; esac
check "...which is the directory git itself names for that worktree" "$common" "$hookdir_from_git"

echo "=== reported, never silent ==="
new_repo "$TMP/managed"; mkdir -p "$TMP/managed/.husky"
git -C "$TMP/managed" config core.hooksPath .husky
rc=0; msg=$(resolve_git_hook_dir "$TMP/managed") || rc=$?
check "core.hooksPath: not written to" "1" "$rc"
has "...and the reason names core.hooksPath" "core.hooksPath is set (.husky)" "$msg"
err=$(set_hook_dir_or_report "$TMP/managed" 2>&1 >/dev/null; true)
has "...and the install says no gate is active" "NOT installed — no commit or push gate is active" "$err"
HOOK_DIR=""; set_hook_dir_or_report "$TMP/managed" 2>/dev/null
(cd "$TMP/managed" && install_git_hook_from_repo "$SRC" "Weave pre-commit" "pre-commit" >/dev/null 2>&1)
check "...and nothing lands in the managed dir or .git/hooks" "absent absent" \
    "$([ -e "$TMP/managed/.husky/pre-commit" ] && echo present || echo absent) $([ -e "$TMP/managed/.git/hooks/pre-commit" ] && echo present || echo absent)"

new_repo "$TMP/custom"
printf '#!/bin/sh\necho mine\n' > "$TMP/custom/.git/hooks/pre-commit"; chmod +x "$TMP/custom/.git/hooks/pre-commit"
set_hook_dir_or_report "$TMP/custom" 2>/dev/null
err=$(cd "$TMP/custom" && install_git_hook_from_repo "$SRC" "Weave pre-commit" "pre-commit" 2>&1 >/dev/null)
has "a custom hook is kept, and the install says the Weave gate is NOT active" "the Weave pre-commit gate is NOT active" "$err"
check "...and the custom hook is untouched" "echo mine" "$(sed -n 2p "$TMP/custom/.git/hooks/pre-commit")"

rc=0; resolve_git_hook_dir "$TMP" >/dev/null || rc=$?
check "outside a repository: not installed, not a write to ./.git/hooks" "1 absent" "$rc $([ -e "$TMP/.git" ] && echo present || echo absent)"

echo "=== every Weave hook source is installed by both copies ==="
# A hook source that only one install path knows about is a gate one kind of
# repository never runs (the reference-transaction binding, wv-5f9d1c, needed
# all of them). Both the dev refresh and the generated wv-init-repo install
# each one, and wv-init-repo vendors it.
names() { if grep -qF -- "$2" "$INSTALL"; then ok "$1"; else bad "$1" "install.sh has no: $2"; fi; }
for src in "$PROJECT_ROOT"/scripts/hooks/*-weave.sh; do
    f=$(basename "$src")
    names "$f: installed by the dev repository refresh" "install_git_hook_from_repo ./scripts/hooks/$f"
    names "$f: installed by wv-init-repo" "install_git_hook_from_repo \"./scripts/hooks/$f\""
    has "$f: vendored by wv-init-repo" "$f" "$(grep -E '^    for _hf in ' "$INSTALL")"
done

echo "=== wv doctor looks where git looks ==="
doctor_hooks() {  # doctor_hooks <repo> -> the doctor's git-hook rows
    (cd "$1" && WV_HOT_ZONE="$TMP/zone-$(basename "$1")" WV_DB="$TMP/zone-$(basename "$1")/brain.db" \
        "$PROJECT_ROOT/scripts/wv" doctor 2>&1 | grep -E 'pre-commit hook|pre-push hook|hooks path' || true)
}
new_repo "$TMP/noexec"
cp "$SRC" "$TMP/noexec/.git/hooks/pre-commit"; chmod -x "$TMP/noexec/.git/hooks/pre-commit"
(cd "$TMP/noexec" && WV_HOT_ZONE="$TMP/zone-noexec" WV_DB="$TMP/zone-noexec/brain.db" "$PROJECT_ROOT/scripts/wv" init >/dev/null 2>&1) || true
has "a non-executable Weave hook is a warning, not a pass" "installed but not executable, so git skips it" "$(doctor_hooks "$TMP/noexec")"
git -C "$TMP/noexec" config core.hooksPath "$TMP/elsewhere"
has "core.hooksPath is reported" "core.hooksPath=$TMP/elsewhere" "$(doctor_hooks "$TMP/noexec")"

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
