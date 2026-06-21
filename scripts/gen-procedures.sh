#!/usr/bin/env bash
# Validate canonical procedure contracts. Projection targets are added as adapters mature.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/templates/procedures"

for arg in "$@"; do
    case "$arg" in
        --source=*) SOURCE="${arg#*=}" ;;
        --check) ;;
        *) echo "Usage: $0 [--source=<dir>] [--check]" >&2; exit 2 ;;
    esac
done

# Parse an `adapters: [a, b, c]` value into newline-separated tokens.
parse_adapters() {
    echo "$1" | tr -d '[]' | tr ',' '\n' | sed 's/[[:space:]]//g' | grep -v '^$' || true
}

# A resource path is unsafe if absolute or if it contains a `..` component;
# either escapes the procedure directory at copy/strip time.
path_unsafe() {
    case "$1" in
        '' | /*) return 0 ;;
    esac
    case "/$1/" in
        */../*) return 0 ;;
    esac
    return 1
}

# Validate the resources block: well-formed items, boolean executable, each path
# safe, exists beside the source, and flat. The download installer enumerates
# canonical files through GitHub's non-recursive contents API, and the Claude
# projection directory is flat, so resource subdirectories are not supported.
validate_resources() {
    local file="$1" dir res seen=" " base bad
    dir=$(dirname "$file")
    # executable values must be boolean
    bad=$(awk '/^resources:/{i=1; next} i && /^[a-z_]+:/{i=0}
        i && /^[[:space:]]*executable:/{v=$0; sub(/.*executable:[[:space:]]*/, "", v); if (v != "true" && v != "false") print NR": "v}' "$file")
    [ -z "$bad" ] || { echo "procedure $file: executable must be true or false ($bad)" >&2; return 1; }
    # every list item under resources must be a non-empty 'path:'
    bad=$(awk '/^resources:/{i=1; next} i && /^[a-z_]+:/{i=0}
        i && /^[[:space:]]*-[[:space:]]/{p=$0; sub(/.*path:[[:space:]]*/, "", p); if ($0 !~ /-[[:space:]]*path:/ || p == "") print NR}' "$file")
    [ -z "$bad" ] || { echo "procedure $file: malformed resource item (line $bad); each must be '- path: <file>'" >&2; return 1; }
    while IFS= read -r res; do
        [ -n "$res" ] || continue
        path_unsafe "$res" && { echo "procedure $file: unsafe resource path '$res' (no absolute or .. paths)" >&2; return 1; }
        [[ "$res" != */* ]] || { echo "procedure $file: resource path '$res' must be a flat filename" >&2; return 1; }
        [ -f "$dir/$res" ] || { echo "procedure $file: missing resource '$res'" >&2; return 1; }
        base=$(basename "$res")
        case "$seen" in *" $base "*) echo "procedure $file: resource basename collision '$base'" >&2; return 1 ;; esac
        seen="$seen$base "
    done < <(awk '/^resources:/{inside=1; next} inside && /^[a-z_]+:/{inside=0} inside && /^[[:space:]]*-[[:space:]]*path:/{sub(/.*path:[[:space:]]*/, ""); print}' "$file")
}

# Extract the (possibly block-scalar, prettier-wrapped) description as one line.
extract_description() {
    awk '
        /^description:/ { v=$0; sub(/^description:[[:space:]]*/, "", v); inside=1; next }
        inside {
            if ($0 ~ /^[a-z_]+:/ || $0 ~ /^---$/) { inside=0; next }
            line=$0; sub(/^[[:space:]]+/, "", line)
            v=(v=="" ? line : v" "line)
        }
        END { print v }
    ' "$1" | tr -d '"'
}

validate_procedure() {
    local file="$1" id description fallback adapters claude_skill visibility status tok
    id=$(awk -F': *' '/^id:/{print $2; exit}' "$file")
    description=$(extract_description "$file")
    fallback=$(awk -F': *' '/^fallback:/{print $2; exit}' "$file" | tr -d '"')
    adapters=$(awk -F': *' '/^adapters:/{print $2; exit}' "$file")
    claude_skill=$(awk -F': *' '/^claude_skill:/{print $2; exit}' "$file")
    visibility=$(awk -F': *' '/^visibility:/{print $2; exit}' "$file")
    status=$(awk -F': *' '/^status:/{print $2; exit}' "$file")
    [[ "$id" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "procedure $file: missing/invalid id" >&2; return 1; }
    [ "$fallback" = "wv guide --procedure=$id" ] || { echo "procedure $file: fallback must be wv guide --procedure=$id" >&2; return 1; }
    [ -n "$description" ] || { echo "procedure $file: description must be non-empty" >&2; return 1; }
    [ -n "$adapters" ] || { echo "procedure $file: adapters required" >&2; return 1; }
    local parsed_adapters
    parsed_adapters=$(parse_adapters "$adapters")
    [ -n "$parsed_adapters" ] || { echo "procedure $file: adapters must name at least one adapter" >&2; return 1; }
    while IFS= read -r tok; do
        [ -n "$tok" ] || continue
        case "$tok" in claude | codex | copilot) ;; *) echo "procedure $file: unknown adapter '$tok' (allowed: claude|codex|copilot)" >&2; return 1 ;; esac
    done <<< "$parsed_adapters"
    [[ "$adapters" =~ claude ]] && [[ "$claude_skill" =~ ^[a-z0-9][a-z0-9-]*$ ]] || [[ ! "$adapters" =~ claude ]] || { echo "procedure $file: Claude adapter requires claude_skill" >&2; return 1; }
    [[ -z "$visibility" || "$visibility" =~ ^(local|shared)$ ]] || { echo "procedure $file: visibility must be local or shared (default local)" >&2; return 1; }
    [[ -z "$status" || "$status" =~ ^(draft|ready)$ ]] || { echo "procedure $file: status must be draft or ready (default ready)" >&2; return 1; }
    validate_resources "$file" || return 1
}

# Cross-file integrity: ids and Claude skill names must be globally unique, or
# alphabetic projection silently overwrites a skill (the "one source" guarantee).
check_uniqueness() {
    local files=("$@") dupes
    [ "${#files[@]}" -gt 0 ] || return 0
    dupes=$(awk -F': *' '/^id:/{print $2}' "${files[@]}" | sort | uniq -d)
    [ -z "$dupes" ] || { echo "duplicate procedure id(s): $(echo "$dupes" | tr '\n' ' ')" >&2; return 1; }
    dupes=$(awk -F': *' '/^claude_skill:/{print $2}' "${files[@]}" | sort | uniq -d)
    [ -z "$dupes" ] || { echo "duplicate claude_skill(s): $(echo "$dupes" | tr '\n' ' ')" >&2; return 1; }
}

shopt -s nullglob
procedures=("$SOURCE"/*.md)
for procedure in "${procedures[@]}"; do validate_procedure "$procedure"; done
check_uniqueness "${procedures[@]}"
echo "procedure contracts: valid"
