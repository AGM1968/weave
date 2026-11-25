#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# FTS5 is required (wv-649510). On the macOS runner the first sqlite3 on PATH
# was a build without FTS5: wv init printed 'no such module: fts5' and then
# success, every write failed on 'no such table: main.nodes_fts', and doctor
# called the index corrupt and advised --repair. Now install, init, load and
# every command refuse on such a sqlite3, naming it and the remedy; init never
# reports success over an incomplete schema; doctor names the missing module.
# The no-FTS5 build is a stub on PATH that rejects any FTS5 statement the way
# such a build does and passes everything else to the real sqlite3.
set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$ROOT/scripts/wv"
run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }
has() { if [[ "$3" == *"$2"* ]]; then ok "$1"; else bad "$1" "expected to contain [$2], got [$3]"; fi; }
lacks() { if [[ "$3" != *"$2"* ]]; then ok "$1"; else bad "$1" "expected no [$2], got [$3]"; fi; }
T=$(mktemp -d /tmp/wv-fts5-required-XXXXXX)
trap 'rm -rf "$T"' EXIT
REAL_SQLITE=$(command -v sqlite3)
export REAL_SQLITE

# stub <dir> <pattern>: a sqlite3 that fails, as a build without the module
# does, on any argument or stdin script matching <pattern>. Like sqlite3 it
# reads stdin only when no SQL or option ends the command (the last argument
# has no space or semicolon and is no -flag); reading it otherwise blocks on a
# caller's open stdin.
stub() {
    mkdir -p "$1"
    cat > "$1/sqlite3" <<EOF
#!/usr/bin/env bash
pat='$2'
for a in "\$@"; do
    if [[ "\$a" =~ \$pat ]]; then echo 'Error: no such module: fts5' >&2; exit 1; fi
done
last="\${!#}"
if [[ "\$last" != *[\ \;]* && "\$last" != -* ]]; then
    in=\$(cat)
    if [[ "\$in" =~ \$pat ]]; then echo 'Error: no such module: fts5' >&2; exit 1; fi
    printf '%s\n' "\$in" | exec "\$REAL_SQLITE" "\$@"
fi
exec "\$REAL_SQLITE" "\$@"
EOF
    chmod +x "$1/sqlite3"
}
stub "$T/nofts" 'USING fts5'
stub "$T/halfschema" 'chunks_fts USING fts5'

# repo <name>: a scratch repo with its own hot zone and config; prints its dir.
repo() {
    local p="$T/$1"
    mkdir -p "$p/proj" "$p/config"
    git -C "$p/proj" init -q .
    echo "$p"
}
wvin() {  # wvin <repo dir> <PATH prefix or -> args...
    local p="$1" pre="$2"; shift 2
    local path="$PATH"; [ "$pre" = - ] || path="$pre:$PATH"
    (cd "$p/proj" && PATH="$path" WV_HOT_ZONE="$p/hot" WV_DB="$p/hot/brain.db" WV_CONFIG_DIR="$p/config" \
        WV_PROJECT_DIR="$p/proj" "$WV" "$@" 2>&1 < /dev/null)
}

echo "=== wv init refuses a sqlite3 without FTS5 ==="
A=$(repo a)
out=$(wvin "$A" "$T/nofts" init); rc=$?
check "init exits nonzero" 1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
has "the refusal names the sqlite3 it found" "$T/nofts/sqlite3 has no FTS5 module" "$out"
has "the refusal names the remedy" "/usr/bin/sqlite3" "$out"
lacks "init prints no success" "Initialized" "$out"
check "no database is left behind" no "$([ -f "$A/hot/brain.db" ] && echo yes || echo no)"

echo "=== wv init never reports success over an incomplete schema ==="
B=$(repo b)
out=$(wvin "$B" "$T/halfschema" init); rc=$?
check "init exits nonzero when a schema statement failed" 1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
has "it says the schema is incomplete" "schema incomplete" "$out"
lacks "init prints no success" "Initialized" "$out"

echo "=== a graph made with FTS5 is refused once the sqlite3 on PATH lacks it ==="
C=$(repo c)
out=$(wvin "$C" - init); rc=$?
check "init with the real sqlite3 succeeds" 0 "$rc"
seen=$(cat "$C/hot/.fts5-ok" 2>/dev/null)
check "the zone remembers the sqlite3 it probed" "$REAL_SQLITE" "$seen"
out=$(wvin "$C" "$T/nofts" add "fts5 probe node"); rc=$?
check "wv add exits nonzero" 1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
has "wv add names the missing module" "has no FTS5 module" "$out"
lacks "wv add does not reach a trigger failure" "no such table" "$out"
out=$(wvin "$C" "$T/nofts" load); rc=$?
check "wv load exits nonzero" 1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
has "wv load names the missing module" "has no FTS5 module" "$out"
out=$(wvin "$C" - add "fts5 probe node"); rc=$?
check "the real sqlite3 still writes afterwards" 0 "$rc"

echo "=== doctor names the missing module, never a corrupt index ==="
out=$(wvin "$C" "$T/nofts" doctor)
fts_line=$(awk '/FTS5[^a-z]/ && !/index/ {print; exit}' <<< "$out")
has "the FTS5 check fails with the cause" "has no FTS5 module" "$fts_line"
idx=$(awk '/FTS5 index/ {print; exit}' <<< "$out")
has "the index check says why it was not checked" "not checked" "$idx"
lacks "doctor does not advise --repair for the index" "run: wv doctor --repair" "$(grep 'FTS5' <<< "$out")"
out=$(wvin "$C" - doctor)
has "with FTS5 the check passes" "available" "$(awk '/FTS5/ {print; exit}' <<< "$out")"

echo "=== install refuses a sqlite3 without FTS5 ==="
# The real install.sh, from the checkout, into a scratch HOME: the refusal comes
# before any file is installed.
inst() {  # inst <PATH prefix or -> args...
    local pre="$1"; shift
    local path="$PATH"; [ "$pre" = - ] || path="$pre:$PATH"
    mkdir -p "$T/home"
    (cd "$ROOT" && PATH="$path" HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" ./install.sh "$@" 2>&1 < /dev/null)
}
out=$(inst "$T/nofts"); rc=$?
check "install exits nonzero" 1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
has "install names the sqlite3 and the module" "$T/nofts/sqlite3 has no FTS5 module" "$out"
check "install wrote nothing" "" "$(ls -A "$T/home" 2>/dev/null)"
out=$(inst "$T/nofts" --check-deps); rc=$?
check "--check-deps exits nonzero" 1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
has "--check-deps names the sqlite3 and the module" "$T/nofts/sqlite3 has no FTS5 module" "$out"
out=$(inst - --check-deps)
lacks "with FTS5 --check-deps raises no FTS5 refusal" "no FTS5 module" "$out"

echo ""
echo "Results: $pass/$run passed"
if [ "$pass" -eq "$run" ]; then echo "All tests passed"; exit 0; fi
exit 1
