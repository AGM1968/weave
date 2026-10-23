#!/usr/bin/env bash
# _wv_source_drift (scripts/lib/wv-config.sh): which edited sources are not
# installed. It drives the pre-commit and bootstrap drift advisories,
# so a source it does not compare is one whose edits
# never reach the installed copy -- or consumers, for the git-hook sources that
# wv init-repo --update vendors from ~/.local/lib/weave/hooks (wv-ff2fb1).
# Driven directly against a temp source tree, HOME and config dir.
set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
export WV_CALL_SOURCE=test

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }

T=$(mktemp -d /tmp/wv-source-drift-XXXXXX)
trap 'rm -rf "$T"' EXIT
SRC="$T/src"; H="$T/home"; CFG="$T/cfg"
mkdir -p "$SRC/scripts/cmd" "$SRC/scripts/lib" "$SRC/scripts/hooks" \
    "$H/.local/lib/weave/cmd" "$H/.local/lib/weave/lib" "$H/.local/lib/weave/hooks" "$H/.local/bin" "$CFG"
printf '%s\n' "$SRC" > "$CFG/source-path"
echo 'cmd' > "$SRC/scripts/cmd/wv-cmd-x.sh"; cp "$SRC/scripts/cmd/wv-cmd-x.sh" "$H/.local/lib/weave/cmd/"
echo 'lib' > "$SRC/scripts/lib/wv-x.sh";     cp "$SRC/scripts/lib/wv-x.sh" "$H/.local/lib/weave/lib/"
echo 'wv' > "$SRC/scripts/wv";               cp "$SRC/scripts/wv" "$H/.local/bin/wv"
echo 'hook' > "$SRC/scripts/hooks/pre-commit-weave.sh"
cp "$SRC/scripts/hooks/pre-commit-weave.sh" "$H/.local/lib/weave/hooks/"
echo 'not a weave hook' > "$SRC/scripts/hooks/README.md"

# drift — run the real function with the temp HOME and config dir.
drift() {
    HOME="$H" WV_CONFIG_DIR="$CFG" bash -c "
source '$ROOT/scripts/lib/wv-config.sh' >/dev/null 2>&1
if out=\$(_wv_source_drift); then printf '%s' \"\$out\"; else printf 'clean'; fi"
}

echo "source drift covers the git-hook sources"
check "every source matching its installed copy reports clean" "clean" "$(drift)"
echo '# edited' >> "$SRC/scripts/hooks/pre-commit-weave.sh"
check "an edited git-hook source is reported" "pre-commit-weave.sh" "$(drift)"
cp "$SRC/scripts/hooks/pre-commit-weave.sh" "$H/.local/lib/weave/hooks/"
check "reinstalling it clears the report" "clean" "$(drift)"
echo 'hook' > "$SRC/scripts/hooks/pre-push-weave.sh"
check "a git-hook source with no installed copy is reported" "pre-push-weave.sh" "$(drift)"
rm -f "$SRC/scripts/hooks/pre-push-weave.sh"
echo '# edited' >> "$SRC/scripts/cmd/wv-cmd-x.sh"
check "an edited command module is still reported" "wv-cmd-x.sh" "$(drift)"
cp "$SRC/scripts/cmd/wv-cmd-x.sh" "$H/.local/lib/weave/cmd/"

# The agent hooks install to $WV_CONFIG_DIR/hooks, where settings.json runs
# them. No case had that directory, so a flipped guard that skipped the whole
# branch survived (wv-70fdf4).
echo "source drift covers the agent hooks"
mkdir -p "$SRC/.claude/hooks" "$CFG/hooks"
echo 'agent hook' > "$SRC/.claude/hooks/pre-action.sh"; cp "$SRC/.claude/hooks/pre-action.sh" "$CFG/hooks/"
check "an agent hook matching its installed copy reports clean" "clean" "$(drift)"
echo '# edited' >> "$SRC/.claude/hooks/pre-action.sh"
check "an edited agent hook is reported" "pre-action.sh" "$(drift)"

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
