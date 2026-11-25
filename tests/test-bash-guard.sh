#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# The bash guard (wv-7257a8). On macOS /bin/bash is bash 3.2, and every executed
# entry point started #!/bin/bash, so wv ran there under a shell that cannot
# execute its bash-4 syntax (mapfile, exec {fd}, associative arrays, ${v,,}).
# Each executed entry point now starts #!/usr/bin/env bash and carries the same
# guard, mastered in scripts/lib/wv-bash-guard.sh: under bash < 4 it re-executes
# itself with a bash >= 4 it finds, else refuses with a message. A real bash
# 3.2 is not available here, so WV_TEST_BASH_TOO_OLD (WV_TEST_MODE=1 only)
# makes the guard treat this bash as too old; the macOS probe runs it for real.
set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$ROOT/scripts/wv"
MASTER="$ROOT/scripts/lib/wv-bash-guard.sh"
run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }
has() { if [[ "$3" == *"$2"* ]]; then ok "$1"; else bad "$1" "expected to contain [$2], got [$3]"; fi; }
T=$(mktemp -d /tmp/wv-bash-guard-XXXXXX)
trap 'rm -rf "$T"' EXIT
tail -n +2 "$MASTER" > "$T/guard"   # the block every entry point carries

# targets — the executed bash entry points: tracked, a bash shebang, and
# executable or a git hook or a scaffold template; sourced modules (scripts/lib,
# scripts/cmd), tests, frozen records and generated projections are not.
targets() {
    git -C "$ROOT" ls-files -s | while read -r mode _ _ path; do
        case "$path" in
            tests/*|docs/*|evidence/*|patches/*|scripts/prose_rule_study/*|scripts/lib/*|scripts/cmd/*|.agents/*|.claude/skills/*|archive/*) continue ;;
        esac
        [ -f "$ROOT/$path" ] || continue
        first=$(sed -n 1p "$ROOT/$path"); [[ "$first" =~ ^\#!.*bash ]] || continue
        if [ "$mode" = 100755 ] || [[ "$path" =~ ^scripts/hooks/[^/]+\.sh$ ]] || [[ "$path" =~ ^templates/.*\.template$ ]]; then
            echo "$path"
        fi
    done
}

echo "every executed entry point uses env bash and carries the guard"
list=$(targets)
count=$(printf '%s\n' "$list" | grep -c . || true)
# A floor that shows the selection rule still finds entry points. The public
# projection ships 29 of the source's 40 (builder-only scripts stay here), so
# a shipped copy holds the lower floor; the source keeps its own (wv-445067).
floor=25
[ "$count" -ge "$floor" ] && ok "the rule finds the entry points ($count)" || bad "the rule finds the entry points" "found only $count (floor $floor)"
bad_shebang=""; missing=""; late=""
while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ "$(head -1 "$ROOT/$p")" = "#!/usr/bin/env bash" ] || bad_shebang+="$p "
    if ! python3 -c 'import sys; sys.exit(0 if open(sys.argv[2]).read() in open(sys.argv[1]).read() else 1)' "$ROOT/$p" "$T/guard"; then
        missing+="$p "; continue
    fi
    # nothing but comments and blank lines may run before the guard
    first_code=$(awk 'NR>1 && $0 !~ /^[[:space:]]*(#|$)/ {print; exit}' "$ROOT/$p")
    [ "$first_code" = "$(grep -v '^#' "$T/guard" | sed -n 1p)" ] || late+="$p "
done <<< "$list"
check "each starts #!/usr/bin/env bash" "" "$bad_shebang"
check "each carries the master guard byte for byte" "" "$missing"
check "the guard is the first code each runs" "" "$late"
init_heredoc=$(awk "/wv-init-repo\" << 'INITEOF'/{p=1;next} /^INITEOF\$/{p=0} p" "$ROOT/install.sh")
printf '%s\n' "$init_heredoc" > "$T/init"
python3 -c 'import sys; sys.exit(0 if open(sys.argv[2]).read() in open(sys.argv[1]).read() else 1)' "$T/init" "$T/guard" \
    && ok "the generated wv-init-repo carries the guard" || bad "the generated wv-init-repo carries the guard"
check "install.sh writes no #!/bin/bash script" "0" "$(grep -c '^#!/bin/bash' "$ROOT/install.sh")"

echo "the guard under a bash it treats as too old"
normal=$("$WV" help add 2>&1 | sed -n 1p)
out=$(WV_TEST_MODE=1 WV_TEST_BASH_TOO_OLD=1 "$WV" help add 2>&1; echo "rc=$?")
has "it re-executes under a bash >= 4 and runs the command" "$normal" "$out"
has "and exits 0" "rc=0" "$out"
out=$(WV_TEST_MODE=1 WV_TEST_BASH_TOO_OLD=1 WV_BASH_REEXEC=1 "$WV" help add 2>&1; echo "rc=$?")
has "with no bash >= 4 left to try it refuses" "needs bash 4 or newer" "$out"
has "naming the remedy" "brew install bash" "$out"
has "and exits 1" "rc=1" "$out"
out=$(WV_TEST_MODE=1 WV_TEST_BASH_TOO_OLD=1 bash -s -- help add < "$WV" 2>&1; echo "rc=$?")
has "read from stdin (no file to re-execute) it refuses" "needs bash 4 or newer" "$out"
# env -u: the commit gate runs suites with WV_TEST_MODE=1 exported.
out=$(env -u WV_TEST_MODE WV_TEST_BASH_TOO_OLD=1 "$WV" help add 2>&1; echo "rc=$?")
has "the test hook without WV_TEST_MODE=1 is ignored, with a warning" "WV_TEST_BASH_TOO_OLD needs WV_TEST_MODE=1" "$out"
has "and the command still runs" "rc=0" "$out"
# shellcheck disable=SC2016  # the probe script's own text, expanded when it runs
{ echo '#!/usr/bin/env bash'; cat "$T/guard"; printf '%s\n' 'printf "%s|%s|%s\n" "${WV_BASH_REEXEC-unset}" "$#" "$*"; cat'; } > "$T/probe"
chmod +x "$T/probe"
out=$(printf 'from stdin\n' | WV_TEST_MODE=1 WV_TEST_BASH_TOO_OLD=1 "$T/probe" a 'b c' 2>&1)
check "a re-executed script keeps its arguments and stdin, and clears the marker" "unset|2|a b c"$'\n'"from stdin" "$out"

echo "the python floor (wv-892318): python3 >= 3.11 for everything an entry point starts"
FLOOR_MASTER="$ROOT/scripts/lib/wv-python-floor.sh"
tail -n +2 "$FLOOR_MASTER" > "$T/floor"   # the block each python-running entry point carries
printf '_wv_python_floor\n' >> "$T/floor"  # and calls at once
# Executed entry points whose own code runs python3 (outside comments and the
# floor block itself) carry the block and its call; scripts/wv and the
# pre-commit hook get it through wv-config.sh, which sources the master.
missing_floor=""
while IFS= read -r p; do
    [ -n "$p" ] || continue
    code=$(sed -e '/^# wv python floor/,/^# end wv python floor/d' -e '/^[[:space:]]*#/d' "$ROOT/$p")
    grep -qE '(^|[^A-Za-z_./-])python3\b' <<< "$code" || continue
    case "$p" in scripts/wv|scripts/hooks/pre-commit-weave.sh) continue ;; esac
    # The block byte for byte, and a call to it after the block: install.sh
    # calls it in its install arm, after the refusals that must write nothing.
    python3 - "$ROOT/$p" "$FLOOR_MASTER" <<'PY' || missing_floor+="$p "
import re, sys
text = open(sys.argv[1]).read()
block = open(sys.argv[2]).read().split("\n", 1)[1]
i = text.find(block)
sys.exit(0 if i >= 0 and re.search(r"(^|[;&|]\s*)_wv_python_floor(\s*;|\s*$)", text[i + len(block):], re.M) else 1)
PY
done <<< "$list"
check "every entry point that runs python3 carries the floor block and calls it" "" "$missing_floor"
check "install.sh calls the floor after its FTS5 refusal, before installing" "1" \
    "$(grep -cE '^\s*install\)\s+check_sqlite_fts5 \|\| exit 1; _wv_python_floor; do_install' "$ROOT/install.sh")"
python3 -c 'import sys; sys.exit(0 if open(sys.argv[2]).read() in open(sys.argv[1]).read() else 1)' "$T/init" "$T/floor" \
    && ok "the generated wv-init-repo carries the floor" || bad "the generated wv-init-repo carries the floor"
check "wv-config.sh sources the master and calls it" "2" \
    "$(grep -cE '^source "\$\{BASH_SOURCE\[0\]%/\*\}/wv-python-floor.sh"|^_wv_python_floor$' "$ROOT/scripts/lib/wv-config.sh")"
check "scripts/wv and the pre-commit hook source wv-config.sh" "1 1" \
    "$(grep -c 'source "$WV_LIB_DIR/lib/wv-config.sh"' "$WV") $(grep -c 'source "$_PC_LIB_DIR/wv-config.sh"' "$ROOT/scripts/hooks/pre-commit-weave.sh")"
# Every directory install.sh puts wv-config.sh in also gets the master it
# sources: the hook lib dir lacking it stopped every PreToolUse hook (wv-892318).
cfg_dirs=$(grep -oE '(install_file|install_copy|download_file|curl -sSL) [^ ]*/scripts/lib/wv-config\.sh"? (-o )?"[^"]*"' "$ROOT/install.sh" \
    | grep -oE '"\$[A-Z_]+/lib/' | sort)
floor_dirs=$(grep -oE '(install_file|install_copy|download_file|curl -sSL) [^ ]*/scripts/lib/wv-python-floor\.sh"? (-o )?"[^"]*"' "$ROOT/install.sh" \
    | grep -oE '"\$[A-Z_]+/lib/' | sort)
check "install.sh installs wv-python-floor.sh wherever it installs wv-config.sh" "$cfg_dirs" "$floor_dirs"
[ "$(wc -l <<< "$cfg_dirs")" -ge 4 ] && ok "(control) the install sites of wv-config.sh are found ($(wc -l <<< "$cfg_dirs"))" \
    || bad "(control) the install sites of wv-config.sh are found" "$cfg_dirs"

# A real old python is not available here: a python3 that fails the floor
# probe and says so otherwise stands in for macOS's /usr/bin/python3 3.9.
REALPY=$(type -P python3)
mkdir -p "$T/oldpy" "$T/bin"
printf '#!/bin/sh\ncase "$*" in *version_info*) exit 1 ;; esac\necho OLD-PYTHON-RAN\n' > "$T/oldpy/python3"
chmod +x "$T/oldpy/python3"
# A PATH with the tools the floor and probe use and no python of any version.
for t in bash env mkdir ln mv mktemp cat; do ln -s "$(type -P "$t")" "$T/bin/$t"; done
# shellcheck disable=SC2016  # the probe script's own text, expanded when it runs
{ echo '#!/usr/bin/env bash'; cat "$T/guard" "$T/floor"; printf '%s\n' 'python3 -c "import sys; print(sys.version_info >= (3, 11))"'; } > "$T/pyprobe"
chmod +x "$T/pyprobe"
pyrun() { env -u WV_PYTHON_FLOOR_OK -u WV_PYTHON XDG_CACHE_HOME="$T/cache$1" "${@:2}" "$T/pyprobe" 2>&1; echo "rc=$?"; }
out=$(pyrun 1 PATH="$T/oldpy:$PATH")
check "an old python3 first on PATH: the probe's python3 is >= 3.11 (a newer one found on PATH)" "True"$'\n'"rc=0" "$out"
out=$(pyrun 2 PATH="$T/oldpy:$T/bin" WV_PYTHON="$REALPY")
check "with nothing newer on PATH, WV_PYTHON is used" "True"$'\n'"rc=0" "$out"
out=$(pyrun 3 PATH="$T/oldpy:$T/bin")
# The floor's last candidates are absolute (Homebrew's), which no PATH hides:
# where one meets the floor (a Mac runner, Mac run 45382707614) the floor must
# resolve to it; the refusal is judged only on a host with none (the Linux gate).
abs_ok=""
for c in /opt/homebrew/bin/python3 /usr/local/bin/python3; do
    if [ -x "$c" ] && "$c" -c 'import sys; sys.exit(sys.version_info < (3, 11))' 2>/dev/null; then abs_ok=$c; break; fi
done
if [ -n "$abs_ok" ]; then
    check "with nothing on PATH, the absolute candidate $abs_ok is used" "True"$'\n'"rc=0" "$out"
    echo "  - skipped here: the no-candidate refusal (this host has $abs_ok); judged where none exists"
else
    has "with no python >= 3.11 anywhere it refuses" "needs python 3.11 or newer" "$out"
    has "naming WV_PYTHON" "set WV_PYTHON" "$out"
    has "and exits 1, before running anything" "rc=1" "$out"
fi
[[ "$out" != *OLD-PYTHON-RAN* ]] && ok "the old python3 never ran the command" || bad "the old python3 never ran the command" "$out"
# shellcheck disable=SC2016  # the probe script's own text
{ echo '#!/usr/bin/env bash'; cat "$T/guard" "$T/floor"; printf '%s\n' 'printf "%s\n" "$PATH"'; } > "$T/pathprobe"
chmod +x "$T/pathprobe"
out=$(env -u WV_PYTHON_FLOOR_OK XDG_CACHE_HOME="$T/cache4" PATH="$PATH" "$T/pathprobe")
check "a python3 already >= 3.11 leaves PATH unchanged" "$PATH" "$out"
out=$(pyrun 1 PATH="$T/oldpy:$PATH")
check "a warm cache resolves the same way" "True"$'\n'"rc=0" "$out"
check "the cache records the resolved interpreter" "$T/oldpy/python3|" "$(sed -n 1p "$T/cache1/weave/python-floor")"
out=$(env -u WV_PYTHON_FLOOR_OK XDG_CACHE_HOME="$T/cache5" PATH="$T/oldpy:$PATH" \
    bash -c ". '$ROOT/scripts/lib/wv-config.sh' >/dev/null 2>&1; python3 -c 'import sys; print(sys.version_info >= (3, 11))'" 2>&1)
check "sourcing wv-config.sh (scripts/wv, the pre-commit hook) applies the floor" "True" "$out"

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ] && echo "All tests passed" || { echo "FAILED"; exit 1; }
