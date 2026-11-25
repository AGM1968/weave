#!/usr/bin/env bash
# Compile contracts/violation-vocabulary-v1.json into the shell projection.
#
# The catalog is the source of truth; Bash reads a generated fragment rather
# than parsing JSON on every invocation. Keeping the projection under
# scripts/lib/ puts it inside the E6 implementation-source closure automatically
# (the runner globs scripts/lib/*.sh), so no runner-manifest edit is needed --
# but it also means regenerating it is a hash-bound change.
#
# Usage: scripts/gen-violation-vocabulary.sh [--check]
# wv bash guard (wv-7257a8): bash >= 4 or a clear refusal. Identical in every executed entry point; master: scripts/lib/wv-bash-guard.sh.
_wv_bash_guard() {
    if [ -n "${WV_TEST_BASH_TOO_OLD:-}" ] && [ "${WV_TEST_MODE:-}" != 1 ]; then echo "wv: WV_TEST_BASH_TOO_OLD needs WV_TEST_MODE=1; ignoring it." >&2; fi
    if [ "${BASH_VERSINFO[0]:-0}" -ge 4 ] && ! { [ "${WV_TEST_MODE:-}" = 1 ] && [ "${WV_TEST_BASH_TOO_OLD:-}" = 1 ]; }; then
        unset WV_BASH_REEXEC
        return 0
    fi
    local b
    if [ -z "${WV_BASH_REEXEC:-}" ] && [ -f "$0" ]; then
        for b in ${WV_BASH:-} /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash /bin/bash; do
            # shellcheck disable=SC2016  # the child bash expands it
            if [ -x "$b" ] && [ "$("$b" -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null)" -ge 4 ] 2>/dev/null; then
                WV_BASH_REEXEC=1 WV_TEST_BASH_TOO_OLD='' exec "$b" "$0" "$@"
            fi
        done
    fi
    echo "wv: $0 needs bash 4 or newer but is running under bash ${BASH_VERSION:-unknown}." >&2
    echo "    On macOS /bin/bash is 3.2: install a newer one (brew install bash) or set WV_BASH to it." >&2
    exit 1
}
_wv_bash_guard "$@"
# end wv bash guard
# wv python floor (wv-892318): python3 >= 3.11 for every python3 this process starts. Identical in every entry point that runs python3 itself; master: scripts/lib/wv-python-floor.sh (wv-config.sh sources it for scripts/wv and the pre-commit hook).
# python3 on PATH if it meets the floor, else the first that does of
# WV_PYTHON, python3.14..python3.11, Homebrew's, linked as python3 in a shim dir
# put first on PATH; none is a refusal. A warm hit forks nothing: the location
# comes from bash's command hash, the verdict from WV_PYTHON_FLOOR_OK or a cache
# file newer than the interpreter (a memo: losing it costs one probe).
_wv_python_floor() {
    local p="" key c k="" r="" cand d
    hash python3 2>/dev/null && p=${BASH_CMDS[python3]:-}
    [ -n "$p" ] && [ "${WV_PYTHON_FLOOR_OK:-}" = "$p" ] && return 0
    key="$p|${WV_PYTHON:-}"
    c="${XDG_CACHE_HOME:-${HOME:-/nonexistent}/.cache}/weave/python-floor"
    if [ -n "$p" ] && [ -f "$c" ] && [ "$c" -nt "$p" ]; then
        { IFS= read -r k && IFS= read -r r; } < "$c" 2>/dev/null || r=""
        [ "$k" = "$key" ] && [ -x "$r" ] && [ "$c" -nt "$r" ] || r=""
    fi
    if [ -z "$r" ]; then
        for cand in "$p" ${WV_PYTHON:-} python3.14 python3.13 python3.12 python3.11 /opt/homebrew/bin/python3 /usr/local/bin/python3; do
            case "$cand" in "") continue ;; /*) ;; *) cand=$(type -P "$cand" 2>/dev/null) || continue ;; esac
            if [ -x "$cand" ] && "$cand" -c 'import sys; sys.exit(sys.version_info < (3, 11))' >/dev/null 2>&1; then
                r=$cand; break
            fi
        done
        if [ -z "$r" ]; then
            echo "wv: $0 needs python 3.11 or newer; python3 on PATH is ${p:-missing}." >&2
            echo "    Install one (macOS: brew install python) or set WV_PYTHON to it." >&2
            exit 1
        fi
        { mkdir -p "${c%/*}" && printf '%s\n%s\n' "$key" "$r" > "$c"; } 2>/dev/null || true
    fi
    if [ "$r" = "$p" ]; then export WV_PYTHON_FLOOR_OK="$p"; return 0; fi
    d="${c%/*}/pybin/${r//\//_}"
    if ! [ "$d/python3" -ef "$r" ]; then
        { mkdir -p "$d" && ln -s "$r" "$d/python3.$$" && mv -f "$d/python3.$$" "$d/python3"; } 2>/dev/null \
            || { d=$(mktemp -d "${TMPDIR:-/tmp}/wv-pybin.XXXXXX") && ln -s "$r" "$d/python3"; } \
            || { echo "wv: $0 cannot put python $r first on PATH; set PATH so python3 is 3.11 or newer." >&2; exit 1; }
    fi
    export PATH="$d:$PATH" WV_PYTHON_FLOOR_OK="$d/python3"
    hash -r
}
# end wv python floor
_wv_python_floor

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CATALOG="$ROOT/contracts/violation-vocabulary-v1.json"
GENERATED="$ROOT/scripts/lib/wv-violation-vocabulary.gen.sh"
CHECK_ONLY=false
[ "${1:-}" != "--check" ] || CHECK_ONLY=true

[ -f "$CATALOG" ] || { echo "gen-violation-vocabulary: missing $CATALOG" >&2; exit 1; }

emit() {
    local output="$1" types
    # Sorted so the projection is a pure function of the catalog's content and
    # not of its key order: a reordered catalog must not produce a different
    # file, or every reorder would invalidate the E6 receipts for nothing.
    types=$(python3 -c "
import json, sys
catalog = json.load(open(sys.argv[1], encoding='utf-8'))
names = sorted(catalog['types'])
if not names:
    raise SystemExit('violation vocabulary is empty')
for name in names:
    if any(ch.isspace() or ch == \"'\" for ch in name):
        raise SystemExit(f'violation type {name!r} is unusable in a space-delimited shell list')
print(' '.join(names))
" "$CATALOG")

    {
        printf '%s\n' '# GENERATED FROM contracts/violation-vocabulary-v1.json — do not edit.'
        printf '%s\n' '# Regenerate with: scripts/gen-violation-vocabulary.sh'
        printf '%s\n' '# shellcheck shell=bash'
        printf '%s\n' ''
        printf '%s\n' '# Space-delimited canonical finding.violation_type values. The catalog is'
        printf '%s\n' '# authoritative; this projection exists so the validator does not parse JSON'
        printf '%s\n' '# on every wv invocation.'
        printf 'FINDING_VIOLATION_TYPES="%s"\n' "$types"
    } > "$output"
}

if [ "$CHECK_ONLY" = true ]; then
    tmp=$(mktemp)
    trap 'rm -f "$tmp"' EXIT
    emit "$tmp"
    if ! cmp -s "$tmp" "$GENERATED"; then
        echo "gen-violation-vocabulary: $GENERATED is stale — run scripts/gen-violation-vocabulary.sh" >&2
        diff -u "$GENERATED" "$tmp" >&2 || true
        exit 1
    fi
    echo "violation vocabulary projection is current"
    exit 0
fi

emit "$GENERATED"
echo "wrote $GENERATED"
