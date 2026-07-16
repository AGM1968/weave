#!/usr/bin/env bash
# Read-only, deterministic inventory for future checkpoint/replay consumers.
# Records are NUL tuples: relative-path, sha256, byte-size, classification.

wv_delta_catalog_scan() {
    local root="$1" root_real file file_real rel hash size kind raw inventory
    [ -e "$root" ] || return 0
    if [ -L "$root" ] || [ ! -d "$root" ]; then
        echo "delta catalog: invalid root: $root" >&2
        return 1
    fi
    root_real=$(realpath -e -- "$root") || { echo "delta catalog: unreadable root" >&2; return 1; }
    raw=$(mktemp "${TMPDIR:-/tmp}/wv-delta-catalog-raw.XXXXXX") || return 1
    inventory=$(mktemp "${TMPDIR:-/tmp}/wv-delta-catalog.XXXXXX") || { rm -f "$raw"; return 1; }
    if ! LC_ALL=C find -P "$root_real" -mindepth 1 -print0 > "$raw"; then
        rm -f "$raw" "$inventory"
        echo "delta catalog: inventory scan failed" >&2
        return 1
    fi
    if ! LC_ALL=C sort -z "$raw" > "$inventory"; then
        rm -f "$raw" "$inventory"
        echo "delta catalog: inventory sort failed" >&2
        return 1
    fi
    rm -f "$raw"
    while IFS= read -r -d '' file; do
        [ -d "$file" ] && [ ! -L "$file" ] && continue
        if [ -L "$file" ] || [ ! -f "$file" ]; then
            echo "delta catalog: non-regular or symlink entry: $file" >&2
            rm -f "$inventory"; return 1
        fi
        file_real=$(realpath -e -- "$file") || { rm -f "$inventory"; echo "delta catalog: unreadable entry: $file" >&2; return 1; }
        case "$file_real" in "$root_real"/*) ;; *) rm -f "$inventory"; echo "delta catalog: entry escapes root: $file" >&2; return 1;; esac
        rel="${file_real#$root_real/}"
        case "$rel" in *$'\n'*|*$'\r'*|../*|*/../*|.|"") rm -f "$inventory"; echo "delta catalog: unsafe path: $rel" >&2; return 1;; esac
        hash=$(sha256sum -- "$file_real" | awk '{print $1}') || { rm -f "$inventory"; return 1; }
        size=$(stat -c '%s' -- "$file_real") || { rm -f "$inventory"; return 1; }
        case "$rel" in *.sql) kind=legacy_sql;; *.json) kind=v2_operation;; *) kind=unsupported;; esac
        printf '%s\0%s\0%s\0%s\0' "$rel" "$hash" "$size" "$kind"
    done < "$inventory"
    rm -f "$inventory"
}
