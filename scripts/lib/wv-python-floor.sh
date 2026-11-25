#!/usr/bin/env bash
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
