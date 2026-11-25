#!/usr/bin/env bash
# wv-compact-pre-cutover.sh -- wv compact --pre-cutover: retire the v1 delta
# back-catalog written before the causal cutover (wv-28ef47,
# docs/PROPOSAL-delta-retention.md Stage A). Sourced by cmd_compact on demand.
#
# The loader already skips every header-less v1 delta once .weave/causal-cutover
# exists, so removing them changes no load, no clock and no lost-write report.
# It does change the causal identity, which hashes the whole catalog: that is a
# declared transition, recorded in the manifest and the commit message, and
# refused while an E5 capture window or reservation is open.
#
# Transaction, all under the exclusive maintenance lock (wv_maint_dir, wv-cmd-data.sh):
#   1. preconditions; 2. exact candidate set; 3. equivalence check on two
#   scratch loads; 4. pending record, then manifest; 5. revalidate the pinned
#   source; 6. remove; 7. revalidate the index; 8. commit; 9. clear pending.
# A crash anywhere after 4 leaves the pending record, which fences every
# shared-lock writer until --resume or --abort finishes the transaction.
#
# Fault-injection hooks for tests/test-delta-retention.sh, registered in
# tests/wv-test-hooks.registry and inert without WV_TEST_MODE=1:
#   WV_TEST_COMPACT_FAULT_AFTER_REMOVALS=N  SIGKILL this process after N removals
#   WV_TEST_COMPACT_PAUSE_FILE=F            after the preconditions, wait under
#                                           the lock while F exists
#   WV_TEST_COMPACT_PLANT_CANDIDATE=P       add tracked path P to the candidate
#                                           set, to show the equivalence check
#                                           refuses it

_PC_SCHEMA="weave.compaction-manifest.v1"

# _pc_test_hooks -- validate the fault hooks before any branch runs, and copy
# the armed ones into _PC_FAULT_AFTER, _PC_PAUSE_FILE and _PC_PLANT.
_pc_test_hooks() {
    _PC_FAULT_AFTER=""; _PC_PAUSE_FILE=""; _PC_PLANT=""
    local name val
    for name in WV_TEST_COMPACT_FAULT_AFTER_REMOVALS WV_TEST_COMPACT_PAUSE_FILE WV_TEST_COMPACT_PLANT_CANDIDATE; do
        val="${!name:-}"
        [ -n "$val" ] || continue
        if [ "${WV_TEST_MODE:-}" != "1" ]; then
            echo "wv compact: $name is set but WV_TEST_MODE=1 is not -- ignoring it" >&2
            continue
        fi
        case "$name" in
            WV_TEST_COMPACT_FAULT_AFTER_REMOVALS)
                [[ "$val" =~ ^[1-9][0-9]*$ ]] || { echo "wv compact: $name='$val' is not a recognised value (a positive integer)" >&2; return 1; }
                _PC_FAULT_AFTER=$val ;;
            WV_TEST_COMPACT_PAUSE_FILE)
                [ "${val#/}" != "$val" ] || { echo "wv compact: $name='$val' is not a recognised value (an absolute path)" >&2; return 1; }
                _PC_PAUSE_FILE=$val ;;
            WV_TEST_COMPACT_PLANT_CANDIDATE)
                case "$val" in /*|-*|*..*) echo "wv compact: $name='$val' is not a recognised value (a repository-relative path)" >&2; return 1 ;; esac
                _PC_PLANT=$val ;;
        esac
    done
}

_pc_fail() { echo -e "${RED}✗${NC} wv compact --pre-cutover: $*" >&2; return 1; }

# _pc_own_claim -- the active node this actor claims, newest first, or nothing.
_pc_own_claim() {
    local me
    me=$(require_agent_id 2>/dev/null) || return 0
    [ -n "$me" ] || return 0
    db_query "SELECT id FROM nodes WHERE status='active' AND json_extract(metadata, '\$.claimed_by') = '$(sql_escape "$me")' ORDER BY updated_at DESC LIMIT 1;" 2>/dev/null
}

# _pc_has_commit_hook -- true when a commit here runs a pre-commit hook.
_pc_has_commit_hook() {
    local dir
    dir=$(git -C "$_PC_TOP" config --get core.hooksPath 2>/dev/null) || dir=""
    if [ -z "$dir" ]; then
        dir=$(git -C "$_PC_TOP" rev-parse --git-path hooks 2>/dev/null) || return 1
        case "$dir" in /*) ;; *) dir="$_PC_TOP/$dir" ;; esac
    fi
    [ -x "$dir/pre-commit" ]
}

# _pc_take_exclusive -- set _PC_DIR and hold the maintenance lock exclusive for
# the rest of this process, or refuse. Never waits: a writer holding it shared
# means the moment is not quiet.
_pc_take_exclusive() {
    _PC_DIR=$(wv_maint_dir)
    [ -n "$_PC_DIR" ] || { _pc_fail "the project is not a git checkout"; return 1; }
    (umask 077 && mkdir -p "$_PC_DIR/windows") || return 1
    local fd lrc=0
    exec {fd}>>"$_PC_DIR/lock" || return 1
    # wv_lock_fd: flock(1), else python3 fcntl (wv-7faa60).
    wv_lock_fd "$fd" -x 0 || lrc=$?
    if [ "$lrc" -ne 0 ]; then
        exec {fd}>&-
        [ "$lrc" -ne 2 ] || { _pc_fail "no file-lock mechanism (neither flock(1) nor python3)"; return 1; }
        _pc_fail "the maintenance lock is held by another process ($_PC_DIR/lock): a sync, publish or capture window is in progress"
        return 1
    fi
    _PC_LOCK_FD=$fd
    # Scratch loads and git hooks run as descendants under this hold.
    export WV_MAINT_HOLDER="$_PC_DIR/lock"
}

# _pc_open_windows -- refuse while an E5 capture window is registered or an E5
# reservation is open. The window signal is the registration capture-start
# writes under the shared lock and capture-finish removes. A registration whose
# capture state file no longer exists is abandoned: capture-finish needs that
# file, so no receipt can ever come from it. It is named and not counted.
_pc_open_windows() {
    local f found=0 state
    for f in "$_PC_DIR"/windows/*.json; do
        [ -e "$f" ] || continue
        state=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("state",""))' "$f" 2>/dev/null)
        if [ -n "$state" ] && [ ! -e "$state" ]; then
            echo "wv compact --pre-cutover: ignoring abandoned capture window $f (state $state is gone)" >&2
            continue
        fi
        [ "$found" -eq 0 ] && echo "wv compact --pre-cutover: open E5 capture window(s):" >&2
        echo "    $f" >&2
        found=1
    done
    if [ "$found" -eq 1 ]; then
        echo "  Finish the capture (capture-finish removes its registration). A registration left by a" >&2
        echo "  crashed capture can be deleted by hand once that capture is abandoned." >&2
        _pc_fail "an E5 capture window is open"
        return 1
    fi
    local reserved
    reserved=$(db_query "SELECT id FROM nodes WHERE status != 'done' AND (CAST(json_extract(metadata, '\$.e5_reserved') AS TEXT) IN ('1','true') OR CAST(json_extract(metadata, '\$.reserved') AS TEXT) IN ('1','true'));" 2>/dev/null | tr '\n' ' ')
    if [ -n "${reserved// /}" ]; then
        _pc_fail "an E5 reservation is open: ${reserved% }"
        return 1
    fi
}

# _pc_marker_commit -- print the commit that last wrote the cutover marker in
# HEAD's history, after checking the marker parses. Refuses otherwise.
_pc_marker_commit() {
    local marker="$WEAVE_DIR/causal-cutover" rel commit
    [ -f "$marker" ] || { _pc_fail "no causal cutover marker (.weave/causal-cutover); nothing predates a cutover"; return 1; }
    python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
ok = d.get("schema") == "weave.causal-cutover.v1" and type(d.get("lineage_seq")) is int and d["lineage_seq"] >= 0
sys.exit(0 if ok else 1)' "$marker" || { _pc_fail "the cutover marker does not parse (schema weave.causal-cutover.v1 with a numeric lineage_seq)"; return 1; }
    rel="$_PC_REL/causal-cutover"
    commit=$(git -C "$_PC_TOP" log -1 --format=%H HEAD -- "$rel" 2>/dev/null)
    if [ -z "$commit" ] || ! git -C "$_PC_TOP" cat-file -e "HEAD:$rel" 2>/dev/null; then
        _pc_fail "the cutover marker is not committed in HEAD's ancestry"
        return 1
    fi
    if [ "$(git -C "$_PC_TOP" rev-parse "HEAD:$rel")" != "$(git -C "$_PC_TOP" hash-object "$marker")" ]; then
        _pc_fail "the cutover marker differs from the committed one"
        return 1
    fi
    printf '%s\n' "$commit"
}

# _pc_weave_status -- porcelain status of .weave/, untracked files included.
_pc_weave_status() {
    git -C "$_PC_TOP" status --porcelain=v1 --untracked-files=all -- "$_PC_REL" 2>/dev/null
}

# _pc_frontier DELTAS_DIR -- the delta_catalog_frontier identity component,
# computed exactly as scripts/wv and E5's _delta_frontier_component do, from
# the bytes on disk (no cache).
_pc_frontier() {
    python3 -c '
import hashlib, sys
from pathlib import Path
root = Path(sys.argv[1])
if not root.is_dir():
    print("delta_catalog_frontier\tabsent"); sys.exit(0)
entries = [p for p in root.rglob("*") if p.is_file() and not p.is_symlink()
           and not any(part.startswith(".staging-") for part in p.relative_to(root).parts)]
lines = sorted((f"{p.relative_to(root)}\t{hashlib.sha256(p.read_bytes()).hexdigest()}" for p in entries),
               key=lambda v: v.encode())
digest = hashlib.sha256(("\n".join(lines) + "\n").encode()).hexdigest()
print(f"delta_catalog_frontier\tpresent\t{len(entries)}\t{digest}")' "$1"
}

# _pc_candidates SOURCE MARKER_COMMIT OUT_TSV OUT_LISTED -- the exact eligible
# set: tracked .sql files outside any v2/ directory and any staging directory,
# with no lineage header, whose blob is unchanged since the marker commit.
# OUT_TSV gets "mode<TAB>blob<TAB>path" (paths relative to the top level).
# Header-less files changed or added after the marker go to OUT_LISTED: the
# loader skips them too, but they are not candidates.
_pc_candidates() {
    local source="$1" marker_commit="$2" out="$3" listed="$4"
    local -A at_marker=()
    local mode type blob path
    while IFS=$' \t' read -r mode type blob path; do
        at_marker["$path"]="$mode $blob"
    done < <(git -C "$_PC_TOP" ls-tree -r --full-tree "$marker_commit" -- "$_PC_REL/deltas" 2>/dev/null)
    : > "$out"; : > "$listed"
    local -a sql_paths=() sql_meta=()
    while IFS=$' \t' read -r mode type blob path; do
        case "$path" in *.sql) ;; *) continue ;; esac
        case "/$path/" in */v2/*|*/.staging-*) continue ;; esac
        sql_paths+=("$path"); sql_meta+=("$mode $blob")
    done < <(git -C "$_PC_TOP" ls-tree -r --full-tree "$source" -- "$_PC_REL/deltas")
    [ "${#sql_paths[@]}" -gt 0 ] || return 0
    # The loader's own structural signal: line 1 is the lineage header.
    local classified i=0 f _l _s _g head
    classified=$(printf "$_PC_TOP/%s\n" "${sql_paths[@]}" | _delta_classify) \
        || { _pc_fail "delta classification failed"; return 1; }
    while IFS=$'\x1f' read -r f _l _s _g head; do
        path="${sql_paths[$i]}"; i=$((i + 1))
        [ "$f" = "$_PC_TOP/$path" ] || { _pc_fail "classifier output out of order at $path"; return 1; }
        [ "${head#/\* weave-lineage seq=}" != "$head" ] && continue
        if [ "${at_marker[$path]:-}" = "${sql_meta[$((i - 1))]}" ]; then
            printf '%s\t%s\t%s\n' "${sql_meta[$((i - 1))]% *}" "${sql_meta[$((i - 1))]#* }" "$path" >> "$out"
        else
            printf '%s\n' "$path" >> "$listed"
        fi
    done <<< "$classified"
    [ "$i" -eq "${#sql_paths[@]}" ] || { _pc_fail "classifier answered for $i of ${#sql_paths[@]} files"; return 1; }
}

# _pc_scratch_load SIDE_DIR -- load SIDE_DIR/.weave into SIDE_DIR/hot/brain.db
# with the running wv, isolated from the user's config and from any sync, and
# write the four compared components beside it.
_pc_scratch_load() {
    local side="$1" rc=0
    mkdir -p "$side/hot" "$side/cfg"
    chmod 700 "$side/hot"
    env -u WV_ACTIVE WV_PROJECT_DIR="$side" WEAVE_DIR="$side/.weave" WV_HOT_ZONE="$side/hot" \
        WV_DB="$side/hot/brain.db" WV_CONFIG_DIR="$side/cfg" WV_AUTO_SYNC=0 WV_AUTO_CHECKPOINT=0 \
        WV_NONINTERACTIVE=1 WV_CALL_SOURCE=maintenance \
        "$SCRIPT_DIR/wv" load >"$side/load.out" 2>"$side/load.err" || rc=$?
    [ "$rc" -eq 0 ] || { _pc_fail "scratch load failed in $side (rc=$rc); see $side/load.err"; return 1; }
    dump_state_sql "$side/hot/brain.db" "$side/durable.sql" || return 1
    sqlite3 "$side/hot/brain.db" "SELECT * FROM tombstones ORDER BY 1, 2;" > "$side/tombstones" 2>/dev/null || : > "$side/tombstones"
    wv_lineage_seq_base "$side/hot/brain.db" "$side/.weave/deltas" > "$side/seq_base" || return 1
    # The lost-write report the load printed, one entry per indented line.
    awk '/lost a conflict on the same field/ {on = 1; next} on && /^    / {print; next} {on = 0}' \
        "$side/load.err" | LC_ALL=C sed $'s/\e\\[[0-9;]*m//g' > "$side/lost_writes"
}

# _pc_equivalence SOURCE CANDIDATES_TSV SCRATCH -- load the source tree with and
# without the candidates and require identical durable tables, tombstones,
# clock base and lost-write list. Prints the difference and fails otherwise.
_pc_equivalence() {
    local source="$1" cands="$2" scratch="$3" side comp bad=0
    for side in with without; do
        mkdir -p "$scratch/$side"
        git -C "$_PC_TOP" archive "$source" -- "$_PC_REL" | tar -x -C "$scratch/$side" || return 1
        if [ "$_PC_REL" != ".weave" ]; then
            mv "$scratch/$side/$_PC_REL" "$scratch/$side/.weave.tmp" && mv "$scratch/$side/.weave.tmp" "$scratch/$side/.weave"
        fi
    done
    local path
    while IFS=$'\t' read -r _ _ path; do
        rm -f "$scratch/without/.weave/${path#"$_PC_REL"/}"
    done < "$cands"
    for side in with without; do _pc_scratch_load "$scratch/$side" || return 1; done
    for comp in durable.sql tombstones seq_base lost_writes; do
        if ! cmp -s "$scratch/with/$comp" "$scratch/without/$comp"; then
            echo "  $comp differs with the candidates removed:" >&2
            diff "$scratch/with/$comp" "$scratch/without/$comp" | head -20 | sed 's/^/    /' >&2
            bad=1
        fi
    done
    [ "$bad" -eq 0 ] || { _pc_fail "equivalence check failed; nothing deleted"; return 1; }
}

# _pc_manifest_field MANIFEST KEY -- one top-level string field.
_pc_manifest_field() {
    python3 -c 'import json,sys; v=json.load(open(sys.argv[1])).get(sys.argv[2]); print(v if isinstance(v,str) else "")' "$1" "$2"
}

# _pc_manifest_entries MANIFEST -- "mode<TAB>blob<TAB>path" per entry.
_pc_manifest_entries() {
    python3 -c '
import json, sys
for e in json.load(open(sys.argv[1]))["entries"]:
    print("%s\t%s\t%s" % (e["mode"], e["blob"], e["path"]))' "$1"
}

# _pc_identity_after MANIFEST -- the recorded after-identity component.
_pc_identity_after() {
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["identity"]["after"])' "$1"
}

# _pc_pinned_check SOURCE ENTRIES_TSV MANIFEST_REL -- the state a resume, abort
# or publication may act on: HEAD is the source commit; every manifest path is
# absent or holds its recorded blob and mode, in the index and the working
# tree; and nothing else under .weave/ differs from the source, other than the
# manifest file itself. Prints every difference and fails on any.
_pc_pinned_check() {
    local source="$1" entries="$2" manifest_rel="$3" head bad=0
    head=$(git -C "$_PC_TOP" rev-parse HEAD 2>/dev/null)
    if [ "$head" != "$source" ]; then
        echo "  HEAD is $head, not the manifest's source commit $source" >&2
        bad=1
    fi
    local -A want=() idx=()
    local -a present=() modes=()
    local mode blob path line st
    while IFS=$'\t' read -r mode blob path; do want["$path"]="$mode $blob"; done < "$entries"
    while IFS=$' \t' read -r mode blob st path; do idx["$path"]="$mode $blob"; done \
        < <(git -C "$_PC_TOP" ls-files -s -- "$_PC_REL/deltas")
    for path in "${!want[@]}"; do
        if [ -n "${idx[$path]:-}" ] && [ "${idx[$path]}" != "${want[$path]}" ]; then
            echo "  index holds an unexpected blob or mode at $path" >&2; bad=1
        fi
        if [ -L "$_PC_TOP/$path" ]; then
            echo "  working tree holds a symlink at $path" >&2; bad=1
        elif [ -e "$_PC_TOP/$path" ]; then
            present+=("$path")
            if [ -x "$_PC_TOP/$path" ]; then modes+=(100755); else modes+=(100644); fi
        fi
    done
    # One hash-object for every present path, in order.
    if [ "${#present[@]}" -gt 0 ]; then
        local i=0
        while IFS= read -r blob; do
            path="${present[$i]}"
            if [ "${modes[$i]} $blob" != "${want[$path]}" ]; then
                echo "  working tree holds an unexpected blob or mode at $path" >&2; bad=1
            fi
            i=$((i + 1))
        done < <(printf '%s\n' "${present[@]}" | git -C "$_PC_TOP" hash-object --stdin-paths)
        [ "$i" -eq "${#present[@]}" ] || { echo "  hash-object answered for $i of ${#present[@]} paths" >&2; bad=1; }
    fi
    # Everything else under .weave/ must match the source commit.
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        path="${line:3}"
        if [ -n "${want[$path]:-}" ]; then
            case "${line:0:2}" in "D "|" D"|"DD") continue ;; esac
        fi
        if [ -n "$manifest_rel" ] && [ "$path" = "$manifest_rel" ]; then
            case "${line:0:2}" in "??"|"A ") continue ;; esac
        fi
        echo "  changed outside the manifest: $line" >&2; bad=1
    done < <(_pc_weave_status)
    [ "$bad" -eq 0 ]
}

# _pc_write_pending SOURCE MANIFEST_REL -- the fence. Written before the
# manifest and before any removal, atomically.
_pc_write_pending() {
    local tmp="$_PC_DIR/pending.json.$$"
    printf '{"schema":"weave.maintenance-pending.v1","operation":"compact-pre-cutover","source_commit":"%s","manifest":"%s","pid":%s,"started_at":"%s"}\n' \
        "$1" "$2" "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$tmp" && mv -f "$tmp" "$_PC_DIR/pending.json"
}

# _pc_publish MANIFEST_REL -- steps 5 to 9 from a written manifest. Shared by
# the first run and --resume.
_pc_publish() {
    local manifest_rel="$1" manifest="$_PC_TOP/$1" source entries removed=0 path
    source=$(_pc_manifest_field "$manifest" source_commit)
    entries=$(mktemp) || return 1
    _pc_manifest_entries "$manifest" > "$entries" || { rm -f "$entries"; _pc_fail "manifest unreadable: $manifest_rel"; return 1; }
    # Revalidate the pinned source immediately before removing anything: the
    # lock does not stop raw git, older binaries or another worktree.
    if ! _pc_pinned_check "$source" "$entries" "$manifest_rel"; then
        rm -f "$entries"
        _pc_fail "the tree no longer matches the manifest's source; nothing removed. Inspect, then --abort or restore by hand"
        return 1
    fi
    while IFS=$'\t' read -r _ _ path; do
        if [ -e "$_PC_TOP/$path" ]; then
            rm -f -- "$_PC_TOP/$path"
            removed=$((removed + 1))
            if [ -n "${_PC_FAULT_AFTER:-}" ] && [ "$removed" -ge "$_PC_FAULT_AFTER" ]; then
                kill -KILL $$
            fi
        fi
    done < "$entries"
    cut -f3 "$entries" | git -C "$_PC_TOP" rm -q --cached --ignore-unmatch --pathspec-from-file=- >/dev/null \
        || { rm -f "$entries"; _pc_fail "git rm failed; run --resume or --abort"; return 1; }
    git -C "$_PC_TOP" add -- "$manifest_rel" || { rm -f "$entries"; _pc_fail "could not stage the manifest"; return 1; }
    # Revalidate the index: exactly the manifest deletions plus the manifest.
    local expected actual after_now after_want
    expected=$( { cut -f3 "$entries" | sed 's/^/D\t/'; printf 'A\t%s\n' "$manifest_rel"; } | LC_ALL=C sort)
    actual=$(git -C "$_PC_TOP" diff --cached --no-renames --name-status HEAD | LC_ALL=C sort)
    rm -f "$entries"
    if [ "$(git -C "$_PC_TOP" rev-parse HEAD)" != "$source" ] || [ "$expected" != "$actual" ]; then
        _pc_fail "the index is not exactly the manifest's deletions plus the manifest; not committing. Run --abort"
        return 1
    fi
    after_want=$(_pc_identity_after "$manifest")
    after_now=$(_pc_frontier "$WEAVE_DIR/deltas")
    if [ "$after_now" != "$after_want" ]; then
        _pc_fail "the catalog identity after removal is not the manifest's ($after_now); not committing. Run --abort"
        return 1
    fi
    find "$WEAVE_DIR/deltas" -mindepth 1 -maxdepth 1 -type d -empty -delete 2>/dev/null || true
    local count own trailer=""
    count=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["entries"]))' "$manifest")
    own=$(_pc_own_claim)
    [ -z "$own" ] || trailer=$'\n'"Weave-ID: $own"
    if ! git -C "$_PC_TOP" commit -q -F - <<EOF
chore(weave): retire the pre-cutover v1 delta back-catalog ($count files)

wv compact --pre-cutover (wv-28ef47). The loader already skipped every file
removed here, so no load, clock or lost-write report changes.

Declared causal identity transition (delta_catalog_frontier):
  before: $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["identity"]["before"])' "$manifest")
  after:  $after_want

Manifest: $manifest_rel
Restore: wv compact --restore=$manifest_rel
$trailer
EOF
    then
        _pc_fail "the commit did not land; the pending record stays. Fix the cause, then --resume or --abort"
        return 1
    fi
    _pc_finalize "$manifest_rel" "$source"
}

# _pc_finalize MANIFEST_REL SOURCE -- confirm the commit is the transaction's,
# then lift the fence.
_pc_finalize() {
    local manifest_rel="$1" source="$2"
    if [ "$(git -C "$_PC_TOP" rev-parse HEAD^ 2>/dev/null)" != "$source" ] \
        || ! git -C "$_PC_TOP" cat-file -e "HEAD:$manifest_rel" 2>/dev/null; then
        _pc_fail "HEAD is not the compaction commit on $source; the pending record stays"
        return 1
    fi
    rm -f "$_PC_DIR/pending.json"
    echo -e "${GREEN}✓${NC} Retired the pre-cutover back-catalog in $(git -C "$_PC_TOP" rev-parse --short HEAD); manifest $manifest_rel" >&2
}

_pc_pending_field() {
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$_PC_DIR/pending.json" "$1"
}

# _pc_resume -- finish a pending transaction from its manifest.
_pc_resume() {
    [ -f "$_PC_DIR/pending.json" ] || { _pc_fail "no pending transaction to resume"; return 1; }
    local source manifest_rel
    source=$(_pc_pending_field source_commit)
    manifest_rel=$(_pc_pending_field manifest)
    # Stopped after the commit landed and before the fence lifted.
    if [ "$(git -C "$_PC_TOP" rev-parse HEAD)" != "$source" ] \
        && [ "$(git -C "$_PC_TOP" rev-parse HEAD^ 2>/dev/null)" = "$source" ] \
        && git -C "$_PC_TOP" cat-file -e "HEAD:$manifest_rel" 2>/dev/null; then
        _pc_finalize "$manifest_rel" "$source"
        return
    fi
    [ -f "$_PC_TOP/$manifest_rel" ] || { _pc_fail "the pending manifest was never written ($manifest_rel); run --abort"; return 1; }
    [ "$(_pc_manifest_field "$_PC_TOP/$manifest_rel" source_commit)" = "$source" ] \
        || { _pc_fail "the manifest's source commit disagrees with the pending record"; return 1; }
    _pc_publish "$manifest_rel"
}

# _pc_abort -- restore every manifest path from the source commit, remove the
# manifest, lift the fence. The tree and index end equal to the source commit.
_pc_abort() {
    [ -f "$_PC_DIR/pending.json" ] || { _pc_fail "no pending transaction to abort"; return 1; }
    local source manifest_rel entries
    source=$(_pc_pending_field source_commit)
    manifest_rel=$(_pc_pending_field manifest)
    entries=$(mktemp) || return 1
    if [ -f "$_PC_TOP/$manifest_rel" ]; then
        _pc_manifest_entries "$_PC_TOP/$manifest_rel" > "$entries" || { rm -f "$entries"; _pc_fail "manifest unreadable"; return 1; }
    fi
    if ! _pc_pinned_check "$source" "$entries" "$manifest_rel"; then
        rm -f "$entries"
        _pc_fail "the tree no longer matches the manifest's source; changing nothing"
        return 1
    fi
    if [ -s "$entries" ]; then
        cut -f3 "$entries" | git -C "$_PC_TOP" checkout "$source" --pathspec-from-file=- \
            || { rm -f "$entries"; _pc_fail "restore from $source failed"; return 1; }
    fi
    rm -f "$entries"
    git -C "$_PC_TOP" rm -q --cached --ignore-unmatch -- "$manifest_rel" >/dev/null 2>&1 || true
    rm -f "$_PC_TOP/$manifest_rel"
    rmdir "$WEAVE_DIR/compaction" 2>/dev/null || true
    if [ -n "$(_pc_weave_status)" ] || [ -n "$(git -C "$_PC_TOP" diff --cached --no-renames --name-only HEAD -- "$_PC_REL")" ]; then
        _pc_weave_status >&2
        _pc_fail "after restore .weave/ still differs from $source; the pending record stays"
        return 1
    fi
    rm -f "$_PC_DIR/pending.json"
    echo -e "${GREEN}✓${NC} Aborted: .weave/ matches $source again" >&2
}

# _pc_restore MANIFEST -- bring back a committed compaction's files from its
# source commit, verifying each blob. Leaves them staged for the operator.
_pc_restore() {
    local manifest="$1" source entries mode blob path bad=0
    [ -f "$manifest" ] || manifest="$_PC_TOP/$1"
    [ -f "$manifest" ] || { _pc_fail "no such manifest: $1"; return 1; }
    source=$(_pc_manifest_field "$manifest" source_commit)
    git -C "$_PC_TOP" cat-file -e "$source^{commit}" 2>/dev/null || { _pc_fail "source commit $source is not in this clone"; return 1; }
    entries=$(mktemp) || return 1
    _pc_manifest_entries "$manifest" > "$entries" || { rm -f "$entries"; _pc_fail "manifest unreadable"; return 1; }
    cut -f3 "$entries" | git -C "$_PC_TOP" checkout "$source" --pathspec-from-file=- \
        || { rm -f "$entries"; _pc_fail "checkout from $source failed"; return 1; }
    while IFS=$'\t' read -r mode blob path; do
        if [ "$(git -C "$_PC_TOP" hash-object -- "$path")" != "$blob" ]; then
            echo "  blob mismatch after restore: $path" >&2; bad=1
        fi
    done < "$entries"
    local n
    n=$(( $(wc -l < "$entries") )); rm -f "$entries"
    [ "$bad" -eq 0 ] || { _pc_fail "restore verification failed"; return 1; }
    echo -e "${GREEN}✓${NC} Restored $n file(s) from $source; they are staged. The causal identity changes back when you commit." >&2
}

# cmd_compact_pre_cutover [--dry-run|--resume|--abort|--restore=MANIFEST]
cmd_compact_pre_cutover() {
    local mode="run" restore=""
    _pc_test_hooks || return 1
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run) mode="dry" ;;
            --resume) mode="resume" ;;
            --abort) mode="abort" ;;
            --restore=*) mode="restore"; restore="${1#*=}" ;;
            *) echo "Unknown option: $1" >&2; return 1 ;;
        esac
        shift
    done
    _PC_TOP=$(git -C "${WV_PROJECT_DIR:-$(dirname "$WEAVE_DIR")}" rev-parse --show-toplevel 2>/dev/null) \
        || { _pc_fail "the project is not a git checkout"; return 1; }
    # wv_relpath fails for a path outside the checkout; realpath --relative-to
    # is GNU-only and on macOS left _PC_REL empty, past this check (wv-e7426f).
    _PC_REL=$(wv_relpath "$_PC_TOP" "$WEAVE_DIR") || { _pc_fail "$WEAVE_DIR is outside the checkout"; return 1; }
    case "$_PC_REL" in ''|..*|/*) _pc_fail "$WEAVE_DIR is outside the checkout"; return 1 ;; esac

    _pc_take_exclusive || return 1
    case "$mode" in
        resume) _pc_resume; return ;;
        abort) _pc_abort; return ;;
    esac
    if [ -f "$_PC_DIR/pending.json" ]; then
        wv_maint_pending_refusal "$_PC_DIR" "wv compact --pre-cutover"
        return 1
    fi
    if [ "$mode" = "restore" ]; then
        _pc_open_windows || return 1
        _pc_restore "$restore"; return
    fi

    # 1. Preconditions, all under the lock.
    local marker_commit source
    marker_commit=$(_pc_marker_commit) || return 1
    if [ -n "$(_pc_weave_status)" ]; then
        _pc_weave_status | head -10 >&2
        _pc_fail ".weave/ is not clean (working tree or index)"; return 1
    fi
    wv_require_graph || return 1
    # Another actor's claim is work in flight, so compaction waits for it. This
    # actor's own claim is the compaction's node: the commit at the end must
    # pass the pre-commit gate, which refuses a commit without one (wv-8bf28e).
    # An unresolvable identity matches no claim, so every claim counts.
    local claims me
    me=$(require_agent_id 2>/dev/null) || me=""
    claims=$(db_query "SELECT COUNT(*) FROM nodes WHERE status='active' AND json_extract(metadata, '\$.claimed_by') IS NOT NULL AND json_extract(metadata, '\$.claimed_by') != '$(sql_escape "$me")';" 2>/dev/null) \
        || { _pc_fail "could not read claims"; return 1; }
    [ "${claims:-1}" -eq 0 ] 2>/dev/null || { _pc_fail "${claims} node(s) are claimed by other actors; compaction waits until they release them"; return 1; }
    if [ "$mode" != "dry" ] && [ -z "$(_pc_own_claim)" ] && _pc_has_commit_hook; then
        _pc_fail "claim the compaction's node first (wv work <id>): this repository's pre-commit hook refuses a commit without a claim"
        return 1
    fi
    _pc_open_windows || return 1
    source=$(git -C "$_PC_TOP" rev-parse HEAD)

    local scratch rc=0
    scratch=$(mktemp -d "${TMPDIR:-/tmp}/wv-compact-XXXXXX") || return 1
    _pc_run "$mode" "$source" "$marker_commit" "$scratch" || rc=$?
    rm -rf "$scratch"
    return "$rc"
}

# _pc_run MODE SOURCE MARKER_COMMIT SCRATCH -- steps 2 to 9 of a first run.
_pc_run() {
    local mode="$1" source="$2" marker_commit="$3" scratch="$4"
    # 2. The exact eligible set.
    _pc_candidates "$source" "$marker_commit" "$scratch/candidates.tsv" "$scratch/listed" || return 1
    if [ -n "${_PC_PLANT:-}" ]; then
        git -C "$_PC_TOP" ls-tree --full-tree "$source" -- "$_PC_PLANT" \
            | awk -F'\t' '{split($1, a, " "); print a[1] "\t" a[3] "\t" $2}' >> "$scratch/candidates.tsv"
    fi
    if [ -n "${_PC_PAUSE_FILE:-}" ] && [ -e "$_PC_PAUSE_FILE" ]; then
        : > "$_PC_PAUSE_FILE.paused"
        while [ -e "$_PC_PAUSE_FILE" ]; do sleep 0.1; done
    fi
    local n_cand n_listed
    n_cand=$(( $(wc -l < "$scratch/candidates.tsv") )); n_listed=$(( $(wc -l < "$scratch/listed") ))
    echo "Candidates: $n_cand pre-cutover v1 delta(s), unchanged since marker commit ${marker_commit:0:12}." >&2
    if [ "$n_listed" -gt 0 ]; then
        echo "Not candidates ($n_listed): header-less v1 deltas added or changed after the marker; the loader skips them, they stay:" >&2
        sed 's/^/    /' "$scratch/listed" >&2
    fi
    [ "$n_cand" -gt 0 ] || { echo "Nothing to retire." >&2; return 0; }

    # 3. Equivalence on scratch loads of the source commit.
    _pc_equivalence "$source" "$scratch/candidates.tsv" "$scratch/eq" || return 1
    local before after
    before=$(_pc_frontier "$WEAVE_DIR/deltas")
    after=$(_pc_frontier "$scratch/eq/without/.weave/deltas")
    echo "Equivalence: durable tables, tombstones, lineage base and lost writes identical." >&2
    echo "Identity transition: $before -> $after" >&2
    if [ "$mode" = "dry" ]; then
        echo "Dry run: nothing written." >&2
        return 0
    fi

    # 4. Fence first, then the manifest.
    local stamp manifest_rel
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    manifest_rel="$_PC_REL/compaction/$stamp-pre-cutover.json"
    _pc_write_pending "$source" "$manifest_rel" || { _pc_fail "could not write the pending record"; return 1; }
    mkdir -p "$WEAVE_DIR/compaction"
    python3 -c '
import json, sys
src, marker, before, after, cands, listed, out, created = sys.argv[1:9]
entries = []
for line in open(cands):
    mode, blob, path = line.rstrip("\n").split("\t", 2)
    entries.append({"path": path, "blob": blob, "mode": mode})
doc = {
    "schema": "weave.compaction-manifest.v1",
    "operation": "compact-pre-cutover",
    "created_at": created,
    "source_commit": src,
    "marker_commit": marker,
    "identity": {"component": "delta_catalog_frontier", "before": before, "after": after},
    "entries": entries,
    "not_candidates": [l.rstrip("\n") for l in open(listed) if l.strip()],
}
with open(out, "w") as fh:
    json.dump(doc, fh, indent=1, sort_keys=True)
    fh.write("\n")' "$source" "$marker_commit" "$before" "$after" "$scratch/candidates.tsv" \
        "$scratch/listed" "$_PC_TOP/$manifest_rel" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        || { _pc_fail "could not write the manifest; the pending record stays, run --abort"; return 1; }

    # 5-9.
    _pc_publish "$manifest_rel"
}
