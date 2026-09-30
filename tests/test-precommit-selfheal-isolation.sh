#!/usr/bin/env bash
# test-precommit-selfheal-isolation.sh — a test run never reinstalls the host
# through the pre-commit install-drift self-heal (wv-75937a).
#
# The self-heal reads source-path from the config dir and runs that checkout's
# ./install.sh against the REAL HOME (it unsets the isolation vars on purpose).
# A suite that commits inside its fixture runs the hook, so a test run
# reinstalled the host from the working tree: the cloud probe wv-0b9d5c could
# not keep a planted mutant out of the install while tests/test-hooks.sh ran,
# and a mutant hook installed that way broke the probing agent's own hooks.
#
# Driven against the real hook with a temp HOME, config dir and source tree
# whose install.sh is a stub that only records it ran.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$ROOT/scripts/hooks/pre-commit-weave.sh"

run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }

T=$(mktemp -d /tmp/wv-selfheal-XXXXXX)
trap 'rm -rf "$T"' EXIT
SRC="$T/src"; H="$T/home"; CFG="$T/cfg"; REPO="$T/repo"; MARK="$T/installed"
mkdir -p "$SRC/scripts/lib" "$H/.local/lib/weave/lib" "$CFG" "$REPO" "$T/hot"
printf '%s\n' "$SRC" > "$CFG/source-path"
# Drift: a source lib the temp HOME has no installed copy of.
echo 'lib' > "$SRC/scripts/lib/wv-x.sh"
printf '#!/bin/sh\necho ran >> "%s"\n' "$MARK" > "$SRC/install.sh"
chmod +x "$SRC/install.sh"

git -C "$REPO" init -q
echo x > "$REPO/file.txt"
git -C "$REPO" add file.txt

# precondition: the fixture really is drifted, or both cases prove nothing.
drift=$(HOME="$H" WV_CONFIG_DIR="$CFG" bash -c "
source '$ROOT/scripts/lib/wv-config.sh' >/dev/null 2>&1
_wv_source_drift && echo drifted")
case "$drift" in *drifted) ok "the fixture source tree is drifted from the temp install (precondition)" ;;
    *) bad "the fixture source tree is drifted from the temp install (precondition)" "got: $drift" ;; esac

# run_hook <WV_CALL_SOURCE value or empty> — the real hook, from the fixture repo.
run_hook() {
    rm -f "$MARK"
    ( cd "$REPO" && env -u WV_CALL_SOURCE -u WV_PRECOMMIT_RUNNING -u WV_SKIP_PRECOMMIT \
        -u WV_LIB_DIR -u WV_DB -u WV_PROJECT_DIR \
        HOME="$H" WV_CONFIG_DIR="$CFG" WV_HOT_ZONE="$T/hot" WV_HOOK_PROGRESS=0 \
        ${1:+WV_CALL_SOURCE=$1} bash "$HOOK" ) >"$T/hook.out" 2>&1 || true
}

echo "pre-commit self-heal under a test run"
run_hook test
[ -f "$MARK" ] && bad "a hook run under WV_CALL_SOURCE=test does not run install.sh" "$(head -5 "$T/hook.out")" \
    || ok "a hook run under WV_CALL_SOURCE=test does not run install.sh"
grep -qF 'install drift' "$T/hook.out" \
    && ok "it still reports the drift" \
    || bad "it still reports the drift" "$(head -5 "$T/hook.out")"

echo "pre-commit self-heal outside a test run"
run_hook ""
[ -f "$MARK" ] && ok "a hook run outside a test still self-heals via install.sh" \
    || bad "a hook run outside a test still self-heals via install.sh" "$(head -5 "$T/hook.out")"

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
