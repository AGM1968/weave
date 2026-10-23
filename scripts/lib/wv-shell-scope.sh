#!/usr/bin/env bash
# wv-shell-scope.sh — the repo-declared shellcheck scope (wv-b9ce14, wv-7608e6)
#
# One selection policy for both linters: `make shellcheck` (scripts/shell-files.sh,
# over the working tree) and the pre-commit hook (over the staged index, after
# it materialises those bytes). A repository adopts it EXPLICITLY, with a
# tracked .weave/shellcheck.conf declaring `mode = derived`; nothing else turns
# it on, so an unrelated file of any name cannot change a consumer's gate.
#
#   [scope]
#   mode = derived          # the only mode; anything else is an error
#   [exclude]
#   archive/                # path prefixes never selected, one per line
#
# Selected: a regular file (not a symlink) with a .sh/.bash extension or a
# shell shebang (sh, bash, dash, ksh), outside every excluded prefix.

# wv_shell_scope_read_conf <conf> — parse into WV_SHELL_SCOPE_MODE and the
# WV_SHELL_SCOPE_EXCLUDES array. Prints why and returns 1 on an unreadable or
# malformed file: a repository that tried to adopt must not be judged by
# whatever half of its declaration parsed.
wv_shell_scope_read_conf() {
    local conf="$1" line section="" key value n=0
    WV_SHELL_SCOPE_MODE=""
    WV_SHELL_SCOPE_EXCLUDES=()
    [ -f "$conf" ] && [ -r "$conf" ] || { echo "cannot read $conf"; return 1; }
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [ -n "$line" ] || continue
        case "$line" in
            '[scope]'|'[exclude]') section="$line"; continue ;;
            '['*) echo "$conf:$n: unknown section $line"; return 1 ;;
        esac
        case "$section" in
            '[scope]')
                key="${line%%=*}"; value="${line#*=}"
                key="${key%"${key##*[![:space:]]}"}"; value="${value#"${value%%[![:space:]]*}"}"
                [ "$key" = "mode" ] && [ "$line" != "$key" ] || { echo "$conf:$n: expected 'mode = derived', got '$line'"; return 1; }
                WV_SHELL_SCOPE_MODE="$value" ;;
            '[exclude]') WV_SHELL_SCOPE_EXCLUDES+=("$line") ;;
            *) echo "$conf:$n: '$line' is outside any section"; return 1 ;;
        esac
    done < "$conf"
    [ "$WV_SHELL_SCOPE_MODE" = "derived" ] || { echo "$conf: mode must be 'derived', got '${WV_SHELL_SCOPE_MODE:-<none>}'"; return 1; }
}

# wv_shell_scope_select <root> — read NUL-separated paths relative to <root> on
# stdin and write the selected ones NUL-separated (order not significant). Call
# wv_shell_scope_read_conf first. Returns 1 when the shebang read fails, so a
# caller never mistakes a partial scan for a clean one.
wv_shell_scope_select() {
    local root="$1" path prefix
    local -a selected=() candidates=() shebang=()
    while IFS= read -r -d '' path; do
        for prefix in "${WV_SHELL_SCOPE_EXCLUDES[@]}"; do
            case "$path" in "$prefix"*) continue 2 ;; esac
        done
        [ -f "$root/$path" ] && [ ! -L "$root/$path" ] || continue
        case "$path" in
            *.sh|*.bash) selected+=("$path") ;;
            *) candidates+=("$path") ;;
        esac
    done
    if [ "${#candidates[@]}" -gt 0 ]; then
        # One awk over every candidate's first line; ./ keeps a name that
        # starts with '-' from reading as an option.
        mapfile -d '' -t shebang < <(cd "$root" && printf './%s\0' "${candidates[@]}" | xargs -0 awk '
            FNR == 1 { if ($0 ~ /^#!.*[\/ \t](ba|da|k)?sh([ \t]|$)/) printf "%s%c", substr(FILENAME, 3), 0; nextfile }')
        wait "$!" || return 1
        selected+=("${shebang[@]}")
    fi
    [ "${#selected[@]}" -eq 0 ] || printf '%s\0' "${selected[@]}"
}
