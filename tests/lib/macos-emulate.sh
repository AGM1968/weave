#!/usr/bin/env bash
# macos-emulate.sh -- run a command on Linux with the macOS differences the
# macOS census found (wv-7551b6, run 44740467804), so portability work is
# checked locally instead of on billed macOS runners (wv-418760).
#
#   bash tests/lib/macos-emulate.sh <command> [args...]
#   e.g. bash tests/lib/macos-emulate.sh bash tests/run-all.sh --suite=test-graph
#
# What it emulates:
#   - tools that behave differently: the wrappers in tests/lib/bsd-shim/
#     (sed, grep, awk, mv, date, stat, realpath, paste, wc, touch, head, find,
#     tar),
#     and md5, which macOS has and Linux does not;
#   - tools macOS does not have: they are absent from PATH, so `command -v`
#     fails as it does on a Mac (not stubbed: a stub would make a probe pass);
#   - the path model: TMPDIR reaches its directory through a symlink and ends
#     in a slash, as /var/folders/... reaches /private/var/folders/...;
#   - the platform: every non-interactive bash sees OSTYPE=darwin25 (through
#     BASH_ENV, sourced after bash sets OSTYPE itself) and uname says Darwin,
#     so code that branches on the platform takes its macOS branch.
# PATH is a directory of symlinks to every tool on the caller's PATH except the
# absent ones, with the wrappers on top; the caller's directories are not on it.
#
# What it does not emulate: /proc and tmpfs, bash 3.2, case-insensitive APFS,
# host tool versions (sqlite3, jq, python3), Apple SQLite's persistent WAL
# (-wal and -shm outlive the last connection; test-load-dropped-nodes carries
# its own sqlite3 shim for it, wv-7551b6), \n in a sed replacement (GNU
# sed --posix still accepts it; check rewritten scripts against BSD rules),
# the system regex library (macOS refuses repetition counts above 255 in bash
# =~, wv-b2e048), python's platform (sys.platform stays linux, so suites that
# compare the bash and python resolvers disagree: test-hot-zone-placement,
# test-hot-zone-migrate), process discovery (test-concurrent-session), and
# BSD grep writing "Binary file X matches" to stdout (use grep -I, wv-f8e26d).
# Results for those three suites are not evidence either way here.
# Run suites alone when a result looks odd: in a parallel run, suites that
# share /tmp/weave-hotzone-<uid> can fail where they pass alone.
# A clean run here is necessary, not sufficient: a macOS run confirms a batch
# or a release candidate.
set -euo pipefail

[ "$#" -gt 0 ] || { echo "usage: macos-emulate.sh <command> [args...]" >&2; exit 2; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPERS="$HERE/bsd-shim"
# Not on macOS: GNU coreutils/util-linux only, or not installed by a Mac user.
# md5sum: macOS 26 ships it in /sbin only (census run 44740467804), older
# macOS not at all, and a hook or test PATH of /usr/bin:/bin leaves it out
# (Mac run 44853731684); macOS has md5 (wv-7d7d41). sha256sum stays: suites
# call it themselves, and the product's sha256sum stand-in (shasum) is
# checked on its own. Absent tools stay in $REAL for the wrappers.
ABSENT=(timeout gtimeout setsid flock nproc getent numfmt tac stdbuf sponge rg
    ionice chrt taskset unshare md5sum)
# Wrappers for macOS tools Linux lacks: they stand in, from the GNU tools.
STANDIN=(md5)

ROOT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/wv-macos-emulate.XXXXXX")
trap 'rm -rf "$ROOT_DIR"' EXIT
REAL="$ROOT_DIR/real"
BIN="$ROOT_DIR/bin"
mkdir -p "$REAL" "$BIN" "$ROOT_DIR/private/var/folders/wv/T"

absent() { local t; for t in "${ABSENT[@]}"; do [ "$1" = "$t" ] && return 0; done; return 1; }

# First executable of each name on the caller's PATH, as the shell would pick it.
IFS=: read -ra dirs <<<"$PATH"
for d in "${dirs[@]}"; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
        n=${f##*/}
        [ -x "$f" ] && [ ! -d "$f" ] || continue
        [ -e "$REAL/$n" ] || [ -L "$REAL/$n" ] && continue
        ln -s "$f" "$REAL/$n"
        absent "$n" || ln -s "$f" "$BIN/$n"
    done
done
for w in "$WRAPPERS"/*; do
    n=${w##*/}
    [[ " ${STANDIN[*]} " == *" $n "* ]] || [ -e "$REAL/$n" ] \
        || { echo "macos-emulate: no real $n on PATH to wrap" >&2; exit 1; }
    rm -f "$BIN/$n"; ln -s "$w" "$BIN/$n"
done

# /var -> /private/var: a logical TMPDIR whose physical path differs, with
# macOS's trailing slash.
ln -s "$ROOT_DIR/private/var" "$ROOT_DIR/var"

# bash sets OSTYPE at startup, overriding the environment; BASH_ENV runs after.
{
    echo 'OSTYPE=darwin25'
    [ -z "${BASH_ENV:-}" ] || printf '. %q\n' "$BASH_ENV"
} > "$ROOT_DIR/bash_env"
export BASH_ENV="$ROOT_DIR/bash_env"
export WV_BSD_SHIM_REAL="$REAL"
export PATH="$BIN"
export TMPDIR="$ROOT_DIR/var/folders/wv/T/"
export WV_MACOS_EMULATE=1
"$@"
