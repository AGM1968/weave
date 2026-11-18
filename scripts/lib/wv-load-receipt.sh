#!/usr/bin/env bash
# wv-load-receipt.sh -- the hot zone's load receipt (wv-4dc121).
#
# A full load rebuilds the live database from .weave/state.sql and replays
# every delta in the catalog. On this repository's catalog that took 25 s of a
# 34 s session start, paid at every start although the hot zone (tmpfs, kept
# between sessions) usually already held exactly that graph.
#
# The receipt records, for one hot zone and one .weave/, what its database is
# known to hold:
#   state    sha256 of .weave/state.sql
#   catalog  sha256 of the delta catalog listing (path, size, mtime)
#   rows     sha256 of the graph rows (nodes, edges, node_files, tombstones)
#   loader   sha256 of the code that loads (load, migrations, replay)
# `wv load --if-changed` skips the rebuild only when all four still match.
# Anything else loads in full: a pull or another zone's sync (catalog or
# state), a graph write after the last sync (rows), a new wv (loader), a
# reboot that empties the zone (no receipt).
#
# A full load writes it, for the state and catalog it read before its import,
# and only when neither moved during the load. A sync renews it as it
# publishes its own deltas, and only when the catalog before the publish is
# the receipt's and after it differs by exactly the files this publish moved:
# a delta from anywhere else in that window removes the receipt instead.
# Every failure to compute an input fails toward a full load.

# _wv_receipt_file -- the receipt's path in this repository's hot zone.
_wv_receipt_file() {
    [ -n "${WV_HOT_ZONE:-}" ] && [ -d "$WV_HOT_ZONE" ] || return 1
    printf '%s/load-receipt\n' "$WV_HOT_ZONE"
}

# wv_receipt_clear -- remove the receipt; the next --if-changed load is full.
wv_receipt_clear() {
    local f
    f=$(_wv_receipt_file) || return 0
    rm -f "$f" 2>/dev/null || true
}

# wv_receipt_catalog_listing <weave_dir> -- "path\tsize\tmtime" per published
# delta file, sorted. Staging directories are PID-scoped scratch, not catalog.
wv_receipt_catalog_listing() {
    local root="$1/deltas"
    [ -d "$root" ] || return 0
    LC_ALL=C find -P "$root" -type f -not -path '*/.staging-*' -printf '%P\t%s\t%T@\n' 2>/dev/null \
        | LC_ALL=C sort
}

# _wv_receipt_sha -- sha256 of stdin, the hex only.
_wv_receipt_sha() {
    local out
    out=$(sha256sum) || return 1
    printf '%s\n' "${out%% *}"
}

# wv_receipt_rows <db> -- digest of the rows state.sql and the deltas carry.
wv_receipt_rows() {
    local db="$1"
    local -
    [ -f "$db" ] || return 1
    set -o pipefail
    sqlite3 -readonly "$db" 2>/dev/null <<'SQL' | _wv_receipt_sha
BEGIN;
SELECT json_array('node', id, text, status, json(metadata), alias, created_at, updated_at,
                  lineage_actor, lineage_seq)
FROM nodes ORDER BY id;
SELECT json_array('edge', source, target, type, weight, json(context), created_at,
                  lineage_actor, lineage_seq)
FROM edges ORDER BY source, target, type;
SELECT json_array('node_file', node_id, path)
FROM node_files ORDER BY node_id, path;
SELECT json_array('tombstone', kind, id, lineage_seq, lineage_actor)
FROM tombstones ORDER BY kind, id;
COMMIT;
SQL
}

# wv_receipt_loader -- digest of the code a load runs. A new wv that migrates
# the schema or replays differently loads in full once.
wv_receipt_loader() {
    local lib="${WV_LIB_DIR:-}" f
    [ -n "$lib" ] || return 1
    for f in lib/VERSION cmd/wv-cmd-data.sh lib/wv-db.sh lib/wv-db-lineage.sh lib/wv-delta.sh \
             lib/wv-delta-v2-replay.py lib/wv-load-ack.py lib/wv-load-receipt.sh; do
        if [ -f "$lib/$f" ]; then
            printf '%s ' "$f"; sha256sum < "$lib/$f" | cut -d' ' -f1
        else
            printf '%s missing\n' "$f"
        fi
    done | _wv_receipt_sha
}

# wv_receipt_inputs <weave_dir> <db> [catalog_sha] -- "state catalog rows loader".
wv_receipt_inputs() {
    local weave_dir="$1" db="$2" catalog="${3:-}" state rows loader
    [ -f "$weave_dir/state.sql" ] || return 1
    state=$(_wv_receipt_sha < "$weave_dir/state.sql") || return 1
    if [ -z "$catalog" ]; then
        catalog=$( (set -o pipefail; wv_receipt_catalog_listing "$weave_dir" | _wv_receipt_sha) ) || return 1
    fi
    rows=$( (wv_receipt_rows "$db") ) || return 1
    loader=$(wv_receipt_loader) || return 1
    [[ "$state$catalog$rows$loader" =~ ^[a-f0-9]{256}$ ]] || return 1
    printf '%s %s %s %s\n' "$state" "$catalog" "$rows" "$loader"
}

# wv_receipt_write <weave_dir> <db> [catalog_sha] -- record the inputs now;
# clears instead when any cannot be computed.
wv_receipt_write() {
    local f inputs
    f=$(_wv_receipt_file) || return 0
    if ! inputs=$(wv_receipt_inputs "$@"); then
        rm -f "$f" 2>/dev/null
        return 0
    fi
    { printf 'v1\t%s\t%s\t%s\n' "$1" "$2" "$inputs" > "$f.$$" && mv -f "$f.$$" "$f"; } 2>/dev/null \
        || rm -f "$f.$$" "$f" 2>/dev/null
    return 0
}

# _wv_receipt_read <weave_dir> <db> -- the recorded inputs, when the receipt is
# for this .weave/ and this database.
_wv_receipt_read() {
    local f ver wdir db inputs
    f=$(_wv_receipt_file) || return 1
    [ -r "$f" ] || return 1
    IFS=$'\t' read -r ver wdir db inputs < "$f" 2>/dev/null || return 1
    [ "$ver" = v1 ] && [ "$wdir" = "$1" ] && [ "$db" = "$2" ] || return 1
    printf '%s\n' "$inputs"
}

# wv_receipt_current <weave_dir> <db> -- 0 when the database holds exactly what
# a full load of this .weave/ would give it.
wv_receipt_current() {
    local recorded now
    recorded=$(_wv_receipt_read "$1" "$2") || return 1
    now=$(wv_receipt_inputs "$1" "$2") || return 1
    [ "$recorded" = "$now" ]
}

# wv_receipt_renew_after_publish <weave_dir> <db> <before_listing_file> <published_file>
# -- called by a delta publish. <before_listing_file> is the catalog listing
# taken just before the publish; <published_file> lists, one per line, the
# catalog paths it moved in. Renewed only when the catalog the receipt holds
# is the one before, and the one after is that plus exactly these files.
wv_receipt_renew_after_publish() {
    local weave_dir="$1" db="$2" before="$3" published="$4" recorded before_sha after_rest
    recorded=$(_wv_receipt_read "$weave_dir" "$db") || { wv_receipt_clear; return 0; }
    before_sha=$(_wv_receipt_sha < "$before") || { wv_receipt_clear; return 0; }
    local -a fields
    read -r -a fields <<< "$recorded"
    if [ "$before_sha" != "${fields[1]:-}" ]; then
        wv_receipt_clear
        return 0
    fi
    after_rest=$( (set -o pipefail
        wv_receipt_catalog_listing "$weave_dir" \
            | awk -F'\t' 'FILENAME == ARGV[1] { moved[$0] = 1; next } !($1 in moved)' "$published" - \
            | _wv_receipt_sha) ) || { wv_receipt_clear; return 0; }
    if [ "$after_rest" != "$before_sha" ]; then
        wv_receipt_clear
        return 0
    fi
    wv_receipt_write "$weave_dir" "$db"
}
