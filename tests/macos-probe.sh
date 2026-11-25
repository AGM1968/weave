#!/usr/bin/env bash
# macos-probe.sh — what Weave does on macOS, step by step (wv-4ccc98). Run by
# .github/workflows/macos-probe.yml on a macos-latest runner. Every step runs,
# its output is printed under a header, and the summary lists each failure; the
# script exits 1 if any step failed. It installs Weave into the runner's own
# HOME and uses a scratch repository; it is not meant for a developer machine.
set -uo pipefail
export WV_CALL_SOURCE=test
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failed=()

step() {  # step <name> <command...> -> run it, print its output, record failure
    local name="$1"; shift
    echo "::group::$name"
    "$@"
    local rc=$?
    echo "[rc=$rc]"
    echo "::endgroup::"
    [ "$rc" -eq 0 ] || { failed+=("$name (rc=$rc)"); echo "::error::$name failed (rc=$rc)"; }
    return 0
}

# shellcheck disable=SC2016  # expands in the child shell, by design
step "environment" bash -c 'sw_vers; uname -a; echo "bash: $BASH_VERSION"; command -v bash jq sqlite3 git python3 md5sum sha256sum shasum stat touch mktemp realpath readlink 2>&1; echo "TMPDIR=$TMPDIR"; ls -ld /tmp; df -h "$TMPDIR" | tail -1'
# FTS5 is required (wv-649510). The runner's first sqlite3 on PATH has been an
# Android SDK build without it: install must refuse that one, naming it. Then
# /usr/bin/sqlite3 (which has FTS5) goes first for every later step.
fts5_probe() { sqlite3 :memory: "CREATE VIRTUAL TABLE t USING fts5(a);" >/dev/null 2>&1; }
echo "first sqlite3 on PATH: $(command -v sqlite3) ($(sqlite3 --version 2>&1 | cut -c1-40))"
NOFTS_DIR=""
if ! fts5_probe; then
    NOFTS_DIR=$(dirname "$(command -v sqlite3)")
    # shellcheck disable=SC2016  # expands in the child shell, by design
    step "install refuses a sqlite3 without FTS5" bash -c '
        out=$(cd "$1" && ./install.sh 2>&1); rc=$?; printf "%s\n" "$out" | grep -i -A2 fts5
        [ "$rc" -ne 0 ] && [[ "$out" == *"has no FTS5 module"* ]]' _ "$ROOT"
    FTS_BIN=$(mktemp -d) && ln -s /usr/bin/sqlite3 "$FTS_BIN/sqlite3" && export PATH="$FTS_BIN:$PATH"
fi
step "sqlite3 on PATH has FTS5" bash -c 'command -v sqlite3; sqlite3 :memory: "CREATE VIRTUAL TABLE t USING fts5(a);"'
# wv_bound, the one deadline mechanism, needs perl with core POSIX and
# Time::HiRes (wv-ea88cd): measured here, not assumed.
step "perl with POSIX and Time::HiRes (wv_bound)" bash -c 'command -v perl && perl -v | sed -n 2p && perl -MPOSIX -MTime::HiRes=alarm -e 1'
# The runner puts Homebrew perl first; whether Apple's own perl ships is what a
# Mac without Homebrew perl relies on (reported, wv-ea88cd).
step "Apple /usr/bin/perl (reported)" bash -c 'if [ -x /usr/bin/perl ]; then /usr/bin/perl -v | sed -n 2p; /usr/bin/perl -MPOSIX -MTime::HiRes=alarm -e 1 && echo "core modules: ok"; else echo "/usr/bin/perl absent"; fi'
# Whether this macOS date prints %N literally (wv-43082a): reported, not judged.
step "date +%s%N (reported)" bash -c 'out=$(date +%s%N); echo "$out"; case "$out" in *N) echo "%N is literal here" ;; *) echo "%N is supported here" ;; esac'
# Read-only opens of a WAL database that has no -wal/-shm beside it (a .backup
# copy), per sqlite3 build: which open forms work here (wv-986156).
step "read-only opens of a WAL copy (reported)" bash -c '
    d=$(mktemp -d); trap "rm -rf \"\$d\"" EXIT
    for s in /usr/bin/sqlite3 "$(command -v sqlite3)"; do
        [ -x "$s" ] || continue
        rm -f "$d"/*; "$s" "$d/live.db" "PRAGMA journal_mode=WAL; CREATE TABLE t(a); INSERT INTO t VALUES (1),(2);" >/dev/null
        "$s" "$d/live.db" ".backup '"'"'$d/copy.db'"'"'"; rm -f "$d/copy.db-wal" "$d/copy.db-shm"
        echo "== $s ($("$s" --version | cut -c1-30)); copy journal: $("$s" "$d/copy.db" "PRAGMA journal_mode;" 2>&1)"; rm -f "$d/copy.db-wal" "$d/copy.db-shm"
        echo "-readonly:        $("$s" -readonly "$d/copy.db" "SELECT count(*) FROM t;" 2>&1)"
        echo "file:?mode=ro:    $("$s" "file:$d/copy.db?mode=ro" "SELECT count(*) FROM t;" 2>&1)"
        echo "query_only read:  $("$s" -cmd "PRAGMA query_only=1" "$d/copy.db" "SELECT count(*) FROM t;" 2>&1)"
        echo "query_only write: $("$s" -cmd "PRAGMA query_only=1" "$d/copy.db" "INSERT INTO t VALUES (3);" 2>&1; echo rc=$?)"
        echo "-readonly, shm present: $("$s" -readonly "$d/copy.db" "SELECT count(*) FROM t;" 2>&1)"
    done
    rm -f "$d/copy.db-wal" "$d/copy.db-shm"
    echo "python3 mode=ro: $(python3 -c "import sqlite3,sys; print(sqlite3.sqlite_version, sqlite3.connect(\"file:\"+sys.argv[1]+\"?mode=ro\", uri=True).execute(\"SELECT count(*) FROM t\").fetchone()[0])" "$d/copy.db" 2>&1 | tail -1)"'
step "install" bash -c "cd '$ROOT' && ./install.sh"
export PATH="$HOME/.local/bin:$PATH"
step "wv runs" wv --version
# The bash guard (wv-7257a8): run wv through the system bash 3.2 on purpose. It
# must re-execute under a bash >= 4 (Homebrew's) and work, with no bash-4
# syntax error from the 3.2 parse.
# shellcheck disable=SC2016  # expands in the child shell, by design
step "wv under /bin/bash 3.2 re-executes under bash >= 4" bash -c '
    /bin/bash --version | sed -n 1p
    out=$(/bin/bash "$(command -v wv)" --version 2>&1); rc=$?; printf "%s\n" "$out"
    case "$out" in *"bad substitution"*|*"syntax error"*) exit 1 ;; esac
    exit $rc'
# shellcheck disable=SC2016  # expands in the child shell, by design
step "a hook under /bin/bash 3.2 re-executes too" bash -c '
    h="$HOME/.config/weave/hooks/stop-check.sh"; [ -f "$h" ] || { echo "no installed hook at $h"; exit 1; }
    head -1 "$h"; out=$(printf "{}" | /bin/bash "$h" 2>&1); rc=$?; printf "%s\n" "$out" | sed -n 1,5p
    case "$out" in *"bad substitution"*|*"syntax error"*|*"needs bash 4"*) exit 1 ;; esac
    exit 0'

R=$(mktemp -d)/repo
mkdir -p "$R" && git -C "$R" init -q && git -C "$R" config user.email probe@example.invalid && git -C "$R" config user.name probe
in_repo() { (cd "$R" && "$@"); }
step "wv init" in_repo wv init
if [ -n "$NOFTS_DIR" ]; then
    # shellcheck disable=SC2016  # expands in the child shell, by design
    step "wv init refuses the sqlite3 without FTS5" bash -c '
        r=$(mktemp -d) && git -C "$r" init -q
        out=$(cd "$r" && PATH="$1:$PATH" wv init 2>&1); rc=$?; printf "%s\n" "$out" | sed -n 1,4p
        [ "$rc" -ne 0 ] && [[ "$out" == *"has no FTS5 module"* ]] && [[ "$out" != *Initialized* ]]' _ "$NOFTS_DIR"
fi
step "wv add" in_repo wv add "macOS probe node" --standalone
step "wv status" in_repo wv status
step "wv hotzone db (placement)" in_repo wv hotzone db
step "the zone is under TMPDIR" bash -c "cd '$R' && db=\$(wv hotzone db) && echo \"\$db\" && case \"\$db\" in \"\${TMPDIR%/}\"/weave-*|/private\"\${TMPDIR%/}\"/weave-*) ;; *) echo 'not under TMPDIR'; exit 1 ;; esac"
step "wv list" in_repo wv list
# wv test-status rejected a fresh green record on the Mac (wv-bfd445) and on
# no Linux host, git 2.56.1 included: show both sides of the comparison
# (recorded row, worktree and index blobs, the verdict) so the differing
# side is evidence, not a guess. Reported; the step fails only if the
# verdict is not green.
step "test-record then test-status agree (wv-bfd445)" bash -c '
    cd "$1" && printf "a\n" > a.sh && printf "b\n" > b.sh && git add a.sh b.sh
    wv test-record tests/probe.sh --files=a.sh,b.sh --exit=0; echo "record rc=$?"
    for f in a.sh b.sh; do echo "$f hash-object=$(git hash-object "$f") index=$(git rev-parse ":$f")"; done
    db=$(wv hotzone db); echo "db=$db"
    sqlite3 "$db" "SELECT suite, path, fingerprint, exit_code FROM test_results WHERE suite=\"tests/probe.sh\";"
    wv test-status tests/probe.sh --files=a.sh,b.sh; rc=$?; echo "status rc=$rc"
    wv test-status tests/probe.sh --files=a.sh,b.sh --staged; echo "staged rc=$?"
    exit "$rc"' _ "$R"
step "wv sync" in_repo wv sync
step "wv doctor" in_repo wv doctor
step "wv hotzone list" in_repo wv hotzone list
step "wv hotzone gc --dry-run" in_repo wv hotzone gc --dry-run
step "wv hotzone migrate (nothing to do off Linux)" in_repo wv hotzone migrate

# Locks (wv-7faa60): flock(1) is util-linux. Without it the hot-zone write lock,
# the schema lock and the attribution lock take no lock at all. Report whether
# flock exists, and whether python3's fcntl.flock on the shell's fd holds after
# python exits (the fallback the fix will use), checked by a second process.
step "flock(1) presence (report only; wv-lock.sh uses python3 fcntl without it)" bash -c 'command -v flock || echo "flock(1) absent"'
# shellcheck disable=SC2016  # expands in the child shell, by design
step "python fcntl lock on an inherited fd holds (fallback canary)" bash -c '
    L=$(mktemp); exec {fd}>>"$L"
    python3 -c "import fcntl,sys; fcntl.flock(int(sys.argv[1]), fcntl.LOCK_EX)" "$fd" || exit 2
    if python3 -c "import fcntl,sys; f=open(sys.argv[1],\"a\"); fcntl.flock(f, fcntl.LOCK_EX|fcntl.LOCK_NB)" "$L" 2>/dev/null; then
        echo "a second process got the lock: the fallback does NOT hold"; exit 1
    fi
    echo "a second process is refused while the holder fd is open: the fallback holds"
    exec {fd}>&-
    python3 -c "import fcntl,sys; f=open(sys.argv[1],\"a\"); fcntl.flock(f, fcntl.LOCK_EX|fcntl.LOCK_NB)" "$L" \
        && echo "released when the holder closes its fd"'

# Persistent WAL (wv-7551b6): a .backup of a WAL database is in WAL mode, and
# Apple's SQLite is expected to keep -wal and -shm after the last connection
# closes, which is why scratch databases are removed with db_remove_file.
# Report only: it states what this sqlite3 does, either way.
# shellcheck disable=SC2016  # expands in the child shell, by design
step "persistent WAL: companions left after an attached backup closes (report only)" bash -c '
    d=$(mktemp -d); cd "$d" || exit 0
    sqlite3 live.db "PRAGMA journal_mode=WAL; CREATE TABLE t(a); INSERT INTO t VALUES(1);" >/dev/null
    sqlite3 live.db ".backup snap.db"; sqlite3 new.db "CREATE TABLE t(a);"
    sqlite3 new.db "ATTACH DATABASE '"'"'snap.db'"'"' AS pre; SELECT count(*) FROM pre.t; DETACH DATABASE pre;" >/dev/null
    ls -a | grep snap; ls snap.db-wal snap.db-shm >/dev/null 2>&1 \
        && echo "kept: persistent WAL" || echo "removed: no persistent WAL"
    cd / && rm -rf "$d"'

# ANSI strip (wv-ab04dd): the form every site uses must strip colour codes with
# BSD sed and pass non-UTF-8 bytes through instead of aborting the pipeline.
# shellcheck disable=SC2016  # expands in the child shell, by design
step "ANSI strip works on BSD sed and survives non-UTF-8 input" bash -c '
    out=$(printf "\033[31mred\033[0m ok \377\376 end\n" | LC_ALL=C sed $'"'"'s/\e\\[[0-9;]*m//g'"'"'); rc=$?
    printf "%s\n" "$out" | od -c | sed -n 1,2p
    [ "$rc" -eq 0 ] && [[ "$out" == "red ok "*" end" ]] && [[ "$out" != *$'"'"'\e'"'"'* ]]'

# Delta listings (wv-8ea297): BSD find has no -printf, so the catalog listing
# falls back to BSD stat -f '%N<tab>%z<tab>%Fm' and the load's by-name list
# uses plain -print. Both must list real files here, never an empty set.
# shellcheck disable=SC2016  # expands in the child shell, by design
step "delta listings work with BSD find and stat" bash -c '
    source "$1/scripts/lib/wv-load-receipt.sh"; source "$1/scripts/lib/wv-delta-catalog.sh"
    d=$(mktemp -d); mkdir -p "$d/2026-01-02" "$d/2026-01-01"
    printf a > "$d/2026-01-02/100-b.sql"; printf bb > "$d/2026-01-01/200-a.sql"
    listing=$(wv_delta_file_listing "$d") || { echo "listing refused"; exit 1; }
    printf "%s\n" "$listing"
    byname=$(wv_delta_paths_by_name "$d" -name "*.sql") || { echo "by-name refused"; exit 1; }
    printf "%s\n" "$byname"
    rm -rf "$d"
    [ "$(printf "%s\n" "$listing" | wc -l | tr -d " ")" = 2 ] \
        && [[ "$listing" =~ 2026-01-02/100-b.sql$'"'"'\t'"'"'1$'"'"'\t'"'"'[0-9]+\.[0-9]+ ]] \
        && [[ "${byname%%$'"'"'\n'"'"'*}" == */100-b.sql ]]' _ "$ROOT"

# Gate supervisor (wv-7551b6): every suite and candidate lane the gate runs on
# macOS exited 2 at once (uncovered-paths, gate-hold-hooks, evidence-bindings),
# and the gate's failure report filters out the supervisor's own message. Run
# it directly so its stderr shows, with the ps snapshot its Darwin path reads.
# shellcheck disable=SC2016  # expands in the child shell, by design
step "gate supervisor launches a command on this platform" bash -c '
    python3 --version
    ps -axo pid=,ppid=,pgid=,stat=,etime=,wchan=,command= >/dev/null; echo "ps snapshot rc=$?"
    python3 -I "$1/scripts/lib/wv-gate-supervisor.py" probe 30 /bin/echo supervised-ok; rc=$?
    echo "supervisor rc=$rc"; [ "$rc" -eq 0 ]' _ "$ROOT"

# The portable suites, as the macos-portable workflow runs them (one list).
step "portable suites (tests/macos-portable.sh)" bash "$ROOT/tests/macos-portable.sh"

echo ""
if [ "${#failed[@]}" -eq 0 ]; then
    echo "macOS probe: every step passed"
else
    echo "macOS probe: ${#failed[@]} step(s) failed:"
    printf '  - %s\n' "${failed[@]}"
    exit 1
fi
