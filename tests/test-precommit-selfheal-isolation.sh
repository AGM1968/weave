#!/usr/bin/env bash
# test-precommit-selfheal-isolation.sh — source admission never installs the host
# (wv-801b89; historical test-run isolation regression wv-75937a).
#
# Source drift remains visible, but installation is an explicit operation.
# Normal, agent and test callers must all leave the installed runtime alone.
#
# Driven against the real hook with a temp HOME, config dir and source tree
# whose install.sh is a stub that only records it ran.
set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$ROOT/scripts/hooks/pre-commit-weave.sh"

run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }

T=$(mktemp -d /tmp/wv-selfheal-XXXXXX)
trap 'rm -rf "$T"' EXIT
SRC="$T/src"; H="$T/home"; CFG="$T/cfg"; REPO="$T/repo"; MARK="$T/installed"; SUITE_MARK="$T/suite-ran"
mkdir -p "$SRC/scripts/lib" "$H/.local/lib/weave/lib" "$CFG" "$REPO" "$T/hot" "$T/bin"
printf '#!/bin/sh\nexec "%s/scripts/wv" "$@"\n' "$ROOT" > "$T/bin/wv"
chmod +x "$T/bin/wv"
printf '%s\n' "$SRC" > "$CFG/source-path"
# Drift: a source lib the temp HOME has no installed copy of.
echo 'lib' > "$SRC/scripts/lib/wv-x.sh"
printf '#!/bin/sh\necho ran >> "%s"\n' "$MARK" > "$SRC/install.sh"
chmod +x "$SRC/install.sh"

git -C "$REPO" init -q
mkdir -p "$REPO/.weave" "$REPO/checks"
printf '[map]\nfile.txt = checks/probe.sh\nchecks/probe.sh = checks/probe.sh\n.weave/test-map.conf = checks/probe.sh\n' \
    > "$REPO/.weave/test-map.conf"
printf '#!/bin/sh\nprintf ran > "%s"\n[ ! -f "%s/fail-suite" ]\n' "$SUITE_MARK" "$T" > "$REPO/checks/probe.sh"
echo x > "$REPO/file.txt"
git -C "$REPO" add file.txt .weave/test-map.conf checks/probe.sh
( cd "$REPO" && env -u WV_LIB_DIR -u WV_DB -u WV_PROJECT_DIR \
    HOME="$H" WV_CONFIG_DIR="$CFG" WV_HOT_ZONE="$T/hot" WV_AUTO_SYNC=0 WV_AUTO_CHECKPOINT=0 \
    "$ROOT/scripts/wv" add "source admission fixture" --status=active --force --criteria="c1|c2" --risks=low \
    >"$T/claim.out" 2>&1 ) || { cat "$T/claim.out"; exit 1; }

# precondition: the fixture really is drifted, or both cases prove nothing.
drift=$(HOME="$H" WV_CONFIG_DIR="$CFG" bash -c "
source '$ROOT/scripts/lib/wv-config.sh' >/dev/null 2>&1
_wv_source_drift && echo drifted")
case "$drift" in *drifted) ok "the fixture source tree is drifted from the temp install (precondition)" ;;
    *) bad "the fixture source tree is drifted from the temp install (precondition)" "got: $drift" ;; esac

# run_hook <WV_CALL_SOURCE value or empty> — the real hook, from the fixture repo.
run_hook() {
    rm -f "$MARK" "$SUITE_MARK"
    RC=0
    ( cd "$REPO" && env -u WV_CALL_SOURCE -u WV_PRECOMMIT_RUNNING -u WV_SKIP_PRECOMMIT \
        -u WV_LIB_DIR -u WV_DB -u WV_PROJECT_DIR \
        PATH="$T/bin:$PATH" HOME="$H" WV_CONFIG_DIR="$CFG" WV_HOT_ZONE="$T/hot" WV_HOOK_PROGRESS=0 \
        ${1:+WV_CALL_SOURCE=$1} bash "$HOOK" ) >"$T/hook.out" 2>&1 || RC=$?
}

for caller in test agent ""; do
    echo "pre-commit source admission (${caller:-normal})"
    run_hook "$caller"
    if [ -f "$MARK" ]; then
        bad "${caller:-normal} caller does not run install.sh" "$(head -5 "$T/hook.out")"
    else
        ok "${caller:-normal} caller does not run install.sh"
    fi
    grep -qF 'install drift' "$T/hook.out" \
        && ok "${caller:-normal} caller still reports drift" \
        || bad "${caller:-normal} caller still reports drift" "$(head -5 "$T/hook.out")"
    [ "$RC" -eq 0 ] && ok "${caller:-normal} caller admits healthy source despite drift" \
        || bad "${caller:-normal} caller admits healthy source despite drift" "status=$RC: $(tail -5 "$T/hook.out")"
    [ -f "$SUITE_MARK" ] && ok "${caller:-normal} caller runs the routed suite" \
        || bad "${caller:-normal} caller runs the routed suite" "$(tail -5 "$T/hook.out")"
done

touch "$T/fail-suite"
run_hook ""
[ "$RC" -eq 1 ] && grep -qF 'probe.sh failed' "$T/hook.out" \
    && ok "a failing routed suite still refuses admission" \
    || bad "a failing routed suite still refuses admission" "status=$RC: $(tail -8 "$T/hook.out")"
if [ -f "$MARK" ]; then
    bad "refused source does not run install.sh" "installer marker exists"
else
    ok "refused source does not run install.sh"
fi

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
