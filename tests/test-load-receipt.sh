#!/usr/bin/env bash
# test-load-receipt.sh -- `wv load --if-changed` skips the rebuild only when
# the hot zone's load receipt says the database already holds this .weave/
# (wv-4dc121, scripts/lib/wv-load-receipt.sh).
#
# Session start ran a full load every time: 25 s of a 34 s start on this
# repository's catalog, though the hot zone usually held that graph already.
# The skip is only safe if every way the database and .weave/ can part loads
# in full, so each case below is one of those ways, beside the controls that
# show the skip happens at all.
#
# GIT_* is unset first: an exported GIT_DIR would point the scratch
# repositories at the real one (wv-8f1da6).

set -u
while IFS= read -r _v; do unset "$_v"; done < <(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p')
export WV_TEST_SUITE=1
export WV_CALL_SOURCE=test

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$REPO_ROOT/scripts/wv"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export WV_CONFIG_DIR="$T/cfg"
export WV_AGENT_ID="receipt-test"
export WV_REQUIRE_LEARNING=0
export WV_AUTO_CHECKPOINT=0
export WV_NONINTERACTIVE=1
mkdir -p "$WV_CONFIG_DIR"

pass=0; run=0
ok()  { echo "  ✓ $1"; pass=$((pass + 1)); run=$((run + 1)); }
bad() { echo "  ✗ $1"; [ -z "${2:-}" ] || echo "$2" | sed 's/^/      /'; run=$((run + 1)); }
check() { local msg="$1"; shift; if "$@"; then ok "$msg"; else bad "$msg"; fi; }

R="$T/repo"; mkdir -p "$R"
# zone <dir> -- this repository, served from the hot zone <dir>.
zone() {
    export WV_PROJECT_DIR="$R" WEAVE_DIR="$R/.weave" WV_HOT_ZONE="$1"
    unset WV_DB
    mkdir -p "$WV_HOT_ZONE"; chmod 700 "$WV_HOT_ZONE"
}
add_node() { "$WV" add "$1" --criteria=c --risks=low 2>&1 | sed -nE 's/^✓ (wv-[a-f0-9]{6}): .*/\1/p' | head -1; }
# load_kind [wv] -- "skipped" or "full" for one `wv load --if-changed`.
load_kind() {
    "${1:-$WV}" load --if-changed > "$T/load.out" 2>&1
    if grep -q 'rebuild skipped' "$T/load.out"; then echo skipped
    elif grep -q 'Loaded from' "$T/load.out"; then echo full
    else echo "neither: $(tail -2 "$T/load.out")"; fi
}
has_node() { "$WV" show "$1" >/dev/null 2>&1; }

cd "$R" || exit 1
git init -q && git config user.email t@t && git config user.name t && git config commit.gpgsign false
zone "$T/z1"
"$WV" init >/dev/null 2>&1
BASE=$(add_node "base node")
"$WV" sync >/dev/null 2>&1
git add -A >/dev/null && git -c core.hooksPath=/dev/null commit -qm fixture

echo "--- the receipt ---"
# lib <fn> [args] -- one library call, with this checkout's code as the loader.
lib() { ( source "$REPO_ROOT/scripts/lib/wv-load-receipt.sh"; export WV_LIB_DIR="$REPO_ROOT/scripts"; "$@" ); }
lib_at() { local d="$1"; shift; ( source "$REPO_ROOT/scripts/lib/wv-load-receipt.sh"; export WV_LIB_DIR="$d"; "$@" ); }
not() { ! "$@"; }
DB="$T/z1/brain.db"
check "no receipt: not current" not lib wv_receipt_current "$WEAVE_DIR" "$DB"
lib wv_receipt_write "$WEAVE_DIR" "$DB"
check "once written: current" lib wv_receipt_current "$WEAVE_DIR" "$DB"
check "...for this .weave/ only" not lib wv_receipt_current "$T/elsewhere/.weave" "$DB"
sqlite3 "$DB" "UPDATE nodes SET text = text || ' (lib)' WHERE id = '$BASE';"
check "a graph write: not current" not lib wv_receipt_current "$WEAVE_DIR" "$DB"
lib wv_receipt_write "$WEAVE_DIR" "$DB"
printf -- '-- appended\n' >> "$R/.weave/state.sql"
check "a state.sql change: not current" not lib wv_receipt_current "$WEAVE_DIR" "$DB"
git -c core.hooksPath=/dev/null checkout -q HEAD -- .weave/state.sql
lib wv_receipt_write "$WEAVE_DIR" "$DB"
mkdir -p "$R/.weave/deltas/2099-01-01"
printf -- '-- no-op delta from elsewhere\n' > "$R/.weave/deltas/2099-01-01/lib.sql"
check "a catalog change: not current" not lib wv_receipt_current "$WEAVE_DIR" "$DB"
rm -rf "$R/.weave/deltas/2099-01-01"
lib wv_receipt_write "$WEAVE_DIR" "$DB"
cp -r "$REPO_ROOT/scripts" "$T/newer"
printf '\n# a newer loader\n' >> "$T/newer/cmd/wv-cmd-data.sh"
check "a different loader: not current" not lib_at "$T/newer" wv_receipt_current "$WEAVE_DIR" "$DB"
check "...and the same one still is" lib wv_receipt_current "$WEAVE_DIR" "$DB"

echo "--- a sync renews only what it published itself ---"
# The receipt the publish found must name the catalog before it, and the
# catalog after must be that plus exactly the moved files.
renew_case() {  # renew_case <extra file to plant during the publish, or ''>
    lib wv_receipt_write "$WEAVE_DIR" "$DB"
    (
        source "$REPO_ROOT/scripts/lib/wv-load-receipt.sh"
        export WV_LIB_DIR="$REPO_ROOT/scripts"
        wv_receipt_catalog_listing "$WEAVE_DIR" > "$T/before"
        mkdir -p "$WEAVE_DIR/deltas/2099-02-02"
        printf -- '-- moved\n' > "$WEAVE_DIR/deltas/2099-02-02/moved-$1x.sql"
        printf '2099-02-02/moved-%sx.sql\n' "$1" > "$T/moved"
        [ -z "$1" ] || printf -- '-- foreign\n' > "$WEAVE_DIR/deltas/2099-02-02/$1"
        wv_receipt_renew_after_publish "$WEAVE_DIR" "$DB" "$T/before" "$T/moved"
    )
    test -s "$T/z1/load-receipt" && echo kept || echo removed
}
check "only its own files moved: renewed" test "$(renew_case '')" = kept
check "a foreign file landed in the window: removed" test "$(renew_case foreign.sql)" = removed


echo "--- the skip ---"
check "a first --if-changed load with no receipt is full" test "$(load_kind)" = full
check "...and leaves a receipt" test -s "$T/z1/load-receipt"
check "the next one, nothing changed, is skipped" test "$(load_kind)" = skipped
check "...and the graph is still there" has_node "$BASE"
check "a plain wv load is always full" test "$("$WV" load 2>&1 | grep -c 'Loaded from')" = 1
check "...and leaves the receipt current" test "$(load_kind)" = skipped

echo "--- every way the database and .weave/ part loads in full ---"
sqlite3 "$T/z1/brain.db" "UPDATE nodes SET text = text || ' (raw)' WHERE id = '$BASE';"
check "a graph write no sync published" test "$(load_kind)" = full
check "...after which the receipt is current again" test "$(load_kind)" = skipped

zone "$T/z2"
check "another zone's first load is full" test "$(load_kind)" = full
FOREIGN=$(add_node "written in zone 2")
"$WV" sync >/dev/null 2>&1
zone "$T/z1"
check "another zone's sync (its state.sql and deltas)" test "$(load_kind)" = full
check "...which brings its node in" has_node "$FOREIGN"

OWN=$(add_node "written in zone 1")
"$WV" sync >/dev/null 2>&1
check "this zone's own sync renews the receipt: skipped" test "$(load_kind)" = skipped
check "...with its node" has_node "$OWN"

cp "$R/.weave/state.sql" "$T/state.keep"
git -c core.hooksPath=/dev/null checkout -q HEAD -- .weave/state.sql
check "state.sql replaced from git" test "$(load_kind)" = full
cp "$T/state.keep" "$R/.weave/state.sql"
"$WV" load >/dev/null 2>&1

mkdir -p "$R/.weave/deltas/2099-01-01"
printf -- '-- no-op delta from elsewhere\n' > "$R/.weave/deltas/2099-01-01/elsewhere.sql"
check "a delta file arriving in the catalog" test "$(load_kind)" = full
check "...after which the receipt is current again" test "$(load_kind)" = skipped

rm -f "$T/z1/load-receipt"
check "no receipt (a rebooted zone)" test "$(load_kind)" = full

check "a different wv (loader digest)" test "$(load_kind "$T/newer/wv")" = full
"$WV" load >/dev/null 2>&1

check "a foreign file in a publish's window leaves the next load full" test "$(renew_case foreign.sql)" = removed
check "...and it is" test "$(load_kind)" = full

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
