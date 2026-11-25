#!/usr/bin/env bash
# wv-gate-lanes.sh — the role contract and the candidate lanes of the protected
# commit gate (S2b, wv-7ee8fe, epic wv-d67163; boundary rules 1, 2 and 4,
# wv-ecf877, prototyped in docs/findings/gate-boundary-prototype-2026-10-12).
#
# Sourced by: scripts/hooks/pre-commit-weave.sh, in the protected lane only
# (the copy of HEAD's scripts/ the S2a dispatcher runs). The caller provides
# hook_progress, hook_gate_jobs (wv-gate-pool.sh) and the frozen candidate
# (wv-gate-snapshot.sh); the clock readings come from wv-clock.sh, sourced
# here beside this file (wv-b17a85).
#
# The contract, scripts/hooks/gate-roles.json, is read from the base, never the
# candidate: a commit cannot reassign roles for itself. It names
#   enforcement  path prefixes the gate runs from HEAD's copy (rule 3, S2a)
#   invoking     files deciding how suites run or whether a result is reused
#   entry_points the git hooks among them and the event each serves; an
#                event never changes without a record
#   shared       exact enforcement files also serving as product; any change
#                needs an exact prior record and still runs its candidate lane
#   external     paths outside enforcement that enforcement files name
#   check_authority
#                optional; for each check a lane may share, the external
#                enforcement files only that check reads (lane review S1,
#                wv-a75d98). A declared file that is not invoking shares the
#                protected pass's suite results in its lane; its own check
#                still runs there. Absent or malformed (any type error,
#                unknown check, or a check naming a file it does not own):
#                the whole declaration is ignored and every external file
#                reruns; the contract stays valid and the gate says so.
#
#   gate_roles_check        rules 1 and 2; on refusal sets _GATE_ROLES_WHY,
#                           returns 1
#   gate_lanes_changed      the frozen transition's enforcement paths
#   gate_lanes_run <dir> [hook args...]
#                           rule 4: each changed enforcement file is judged in
#                           its own lane, against HEAD's copies of every other
#                           file; every lane must admit, so the first refusal
#                           stops the rest unless WV_GATE_KEEP_GOING=1
#   gate_repair_record <path> [repair|retirement]
#                           rule 5: the repair record at HEAD admitting this
#                           commit's transition of <path>, if one is live
#   gate_entry_points_preflight
#                           rule 5 over every changed entry point, before any
#                           suite runs; gate_lanes_run applies it again
#
# A lane is HEAD's scripts/ (in a recovery run, the execution tree's: S2c,
# wv-0af8f0) with one file replaced by its staged bytes (or
# removed, if the commit deletes it), run as this hook beside a
# weave-gate-candidate mark. It runs only the pre-commit hook: a commit that
# changes another declared entry point is refused before any suite runs,
# unless a repair record admits that exact change, which then is not run. Run
# together, changed files could weaken one another (prototype D3); alone, a
# file that needs another file changed in the same commit fails in its lane,
# and that file lands first (D4).

# shellcheck source=scripts/lib/wv-clock.sh
source "$(dirname "${BASH_SOURCE[0]}")/wv-clock.sh"
GATE_ROLES_PATH="scripts/hooks/gate-roles.json"
GATE_REPAIRS_DIR=".weave/gate-repairs"

# _gate_roles_valid — stdin is a well-formed contract. An entry point serves a
# git hook event (githooks(5)), and only the hook a lane runs serves
# pre-commit: a label is what exempts a changed entry point from refusal, so a
# contract naming another file pre-commit is not valid (S2b review N2,
# wv-3b601f).
_gate_roles_valid() {
    jq -se 'length == 1 and (.[0] |
        def root:
            type == "string" and length > 0
            and (contains("\\") | not) and (test("[[:cntrl:]]") | not)
            and (rtrimstr("/") | split("/")
                 | all(.[]; . != "" and . != "." and . != ".."));
        .version == 1
        and (.enforcement | type == "array" and length > 0
             and all(.[]; root))
        and (.invoking | type == "array" and all(.[]; type == "string" and length > 0))
        and (.shared == null or (.shared | type == "array"
             and all(.[]; root and (endswith("/") | not))))
        and (.external | type == "object" and all(.[]; type == "string"))
        and ((.entry_points // {}) | type == "object"
             and all(.[]; IN("applypatch-msg", "pre-applypatch", "post-applypatch",
                 "pre-commit", "pre-merge-commit", "prepare-commit-msg", "commit-msg",
                 "post-commit", "pre-rebase", "post-checkout", "post-merge", "pre-push",
                 "pre-receive", "update", "proc-receive", "post-receive", "post-update",
                 "reference-transaction", "push-to-checkout", "pre-auto-gc",
                 "post-rewrite", "sendemail-validate", "fsmonitor-watchman",
                 "post-index-change"))
             and ([to_entries[] | select(.value == "pre-commit") | .key]
                  | . == [] or . == ["scripts/hooks/pre-commit-weave.sh"]))
    )' >/dev/null 2>&1
}

# _GATE_AUTHORITY_JQ — jq definition of `authority`: the contract's
# check_authority when it is well formed, else {} (lane review S1, wv-a75d98).
# Well formed: an object whose keys are known checks, each holding a non-empty
# subset of the files that check alone reads. Anything else is not a
# declaration at all, so every external file reruns its suites; a malformed
# field never shares and never refuses.
_GATE_AUTHORITY_JQ='def authority:
    {"release-leak-guard": ["build-release.sh", "tests/lib/release-leak-pattern.ere",
                            "tests/test-shipped-test-refs.sh"],
     "memory-projection": ["tests/test-memory-projection-parity.sh"]} as $own
    | (.check_authority // {}) as $a
    | if ($a | type) == "object"
         and ($a | all(to_entries[]; $own[.key] as $o
              | $o != null and (.value | type) == "array" and (.value | length) > 0
              and (.value | all(.[]; type == "string")) and (.value - $o) == []))
      then $a else {} end;'

# _gate_authority_note <json> <whose> — say when a contract carries a
# check_authority the gate ignores.
_gate_authority_note() {
    if jq -se "length == 1 and (.[0] | $_GATE_AUTHORITY_JQ"' .check_authority != null and authority != .check_authority)' \
        >/dev/null 2>&1 <<< "$1"; then
        echo "⚠ Weave pre-commit: $2 gate role contract's check_authority is malformed, so it is ignored: every external enforcement file reruns every suite (wv-a75d98)" >&2
    fi
}

# _gate_roles_side <side> — the contract's bytes on that side; 1 absent or
# unreadable, 2 invalid.
_gate_roles_side() {
    local json
    json=$(gate_show "$1" "$GATE_ROLES_PATH") || return 1
    _gate_roles_valid <<< "$json" || return 2
    printf '%s\n' "$json"
}

# _gate_under <path> <prefix>... — path lies under one of the prefixes.
_gate_under() {
    local p=$1 pre
    shift
    for pre in "$@"; do
        pre=${pre%/}
        case "$p" in "$pre"|"$pre"/*) return 0 ;; esac
    done
    return 1
}

# Capture NUL-separated paths into the caller's array only after the producer
# succeeds. Bash 5.2 can lose a completed process substitution's wait status
# (wv-5a776d); foreground acquisition also preserves partial-output refusals.
_gate_read_paths() {
    local _grp_array=$1 _grp_file _grp_rc=0
    shift
    _grp_file=$(mktemp "${TMPDIR:-/tmp}/wv-gate-paths.XXXXXX") || return 1
    "$@" > "$_grp_file" || _grp_rc=$?
    if [ "$_grp_rc" -eq 0 ]; then
        mapfile -d '' -t "$_grp_array" < "$_grp_file" || _grp_rc=$?
    fi
    rm -f "$_grp_file"
    return "$_grp_rc"
}

# Repair records (boundary rule 5; S2c, wv-9a805a). A JSON file committed at
# HEAD under .weave/gate-repairs/ names one transition:
#   {"version": 2, "kind": "repair", "path": "<gate file>",
#    "baseline_mode": "100755", "replacement_mode": "100755",
#    "baseline": "<HEAD's blob>", "replacement": "<the staged blob>",
#    "reason": "...", "verification": "..."}
# It admits a commit only when HEAD holds that baseline (mode, blob) and the
# index that replacement, and only until the transition lands: once any commit after the
# record (or its last change) went from the baseline to the replacement, on any
# branch merged since, it admits nothing more, even after the path returns to
# the baseline. An agent may write any record. A record gives traceability,
# not approval, and the gate says so. Mode-less v1 repair records remain
# historical evidence but cannot admit a future transition; write a fresh v2
# record instead (wv-7205b0). Recovery records have their own, unchanged version.
# A v2 retirement record uses kind "retirement", replacement "" and
# replacement_mode "000000": confirmed absence, not a wildcard. It admits
# deletion only and is consumed by the same history walk. It never bypasses
# the baseline gate or retires the boundary as a whole (wv-732b60).
# For .weave/gate-provision.json only, retirement may instead name an exact
# regular-file replacement removing adopted suites (wv-3c7ca5). The loader
# establishes that removal; byte/mode matching and consumption remain here.

# _gate_repair_mode <tree-ish> <path> — regular file mode; 1 absent, 2 unreadable
# or non-regular. Keep this separate from installed recovery's trusted code.
_gate_repair_mode() {
    local line
    line=$(git --no-replace-objects --literal-pathspecs ls-tree --full-tree "$1" -- "$2" 2>/dev/null) || return 2
    case "$line" in
        '100644 blob '*|'100755 blob '*) printf '%s\n' "${line%% *}" ;;
        '') return 1 ;;
        *) return 2 ;;
    esac
}

# _gate_repair_consumed <record commit> <path> <bm> <baseline> <rm> <replacement> — some
# commit reachable from the frozen base and not from the record's commit made
# the transition against one of its parents. 0 consumed, 1 not, 2 unreadable.
_gate_repair_consumed() {
    local since=$1 path=$2 bm=$3 old=$4 rm=$5 new=$6 line c p cm pm history objects
    local -a pairs=() objs=()
    history=$(git --no-replace-objects rev-list --parents "$WV_GATE_BASE" --not "$since" 2>/dev/null) || return 2
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        c=${line%% *}
        for p in ${line#"$c"}; do pairs+=("$c" "$p"); done
    done <<< "$history"
    [ "${#pairs[@]}" -gt 0 ] || return 1
    objects=$(set -o pipefail
        for c in "${pairs[@]}"; do printf '%s:%s\n' "$c" "$path"; done \
            | git --no-replace-objects cat-file --batch-check='%(objectname)' 2>/dev/null) || return 2
    mapfile -t objs <<< "$objects"
    [ "${#objs[@]}" -eq "${#pairs[@]}" ] || return 2
    # batch-check reports both an absent path and an unreadable object as
    # "<commit>:<path> missing", successfully. Only actual absence can match
    # a retirement. Preserve that full answer (paths may contain spaces), then
    # confirm every non-OID with a literal tree read (wv-5df974).
    for c in "${!objs[@]}"; do
        case "${objs[c]}" in
            ''|*[!0-9a-f]*)
                line=$(git --no-replace-objects --literal-pathspecs ls-tree --full-tree \
                    "${pairs[c]}" -- "$path" 2>/dev/null) || return 2
                [ -z "$line" ] || return 2
                objs[c]="" ;;
        esac
    done
    for ((c = 0; c < ${#objs[@]}; c += 2)); do
        [ "${objs[c]}" = "$new" ] && [ "${objs[c+1]}" = "$old" ] || continue
        # A retirement's replacement is confirmed absence, never an unreadable
        # object. Repairs still require both regular files to be readable.
        cm=$(_gate_repair_mode "${pairs[c]}" "$path") || {
            [ "$?" -eq 1 ] && [ "$rm" = 000000 ] && cm=000000 || return 2
        }
        pm=$(_gate_repair_mode "${pairs[c+1]}" "$path") || return 2
        [ "$cm" = "$rm" ] && [ "$pm" = "$bm" ] \
            && [ "$cm ${objs[c]}" != "$pm ${objs[c+1]}" ] && return 0
    done
    return 1
}

# gate_repair_record <path> [repair|retirement] — prints the record at HEAD that admits this
# commit's transition of <path>. 0 found, 1 none, 2 could not tell, 3 a
# matching record whose use cannot be established: consumption is read from
# history, which a shallow or partial clone does not hold whole, and history
# missing is not proof the record is unused. A depth-1 clone revived a
# consumed record by treating it as added at its root (follow-up review F1,
# wv-a18f1e). Replacement objects are ignored: they rewrite what history says.
gate_repair_record() {
    local path=$1 kind=${2:-repair} base_tree idx_tree old new bm rm mode type rec json since rc records
    case "$kind" in repair|retirement) ;; *) return 2 ;; esac
    [ -n "${WV_GATE_BASE:-}" ] || return 1
    base_tree=$(gate_side_tree base) && idx_tree=$(gate_side_tree index) || return 2
    rc=0; bm=$(_gate_repair_mode "$base_tree" "$path") || rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    rc=0; rm=$(_gate_repair_mode "$idx_tree" "$path") || rc=$?
    if [ "$kind" = retirement ]; then
        case "$rc" in
            1) rm=000000; new="" ;;
            0)
                [ "$path" = .weave/gate-provision.json ] || return 1
                new=$(git rev-parse -q --verify "$idx_tree:$path" 2>/dev/null) || return 2 ;;
            *) return 2 ;;
        esac
    else
        [ "$rc" -eq 0 ] || return "$rc"
        new=$(git rev-parse -q --verify "$idx_tree:$path" 2>/dev/null) || return 1
    fi
    old=$(git rev-parse -q --verify "$base_tree:$path" 2>/dev/null) || return 1
    # Consumption checks launch their own processes and overwrite $!; finish
    # reading the records before interpreting any of them.
    records=$(git ls-tree -r --full-tree "$base_tree" -- "$GATE_REPAIRS_DIR" 2>/dev/null) || return 2
    while IFS=$'\t' read -r mode rec; do
        type=${mode#* }; type=${type%% *}
        case "${mode%% *} $type $rec" in
            "100644 blob $GATE_REPAIRS_DIR/"*.json) ;;
            *) continue ;;
        esac
        json=$(gate_show base "$rec") || return 2
        jq -se --arg p "$path" --arg o "$old" --arg n "$new" --arg bm "$bm" --arg rm "$rm" --arg k "$kind" 'length == 1 and (.[0] |
            .version == 2 and .kind == $k and .path == $p
            and .baseline == $o and .replacement == $n
            and .baseline_mode == $bm and .replacement_mode == $rm
            and (.reason | type == "string" and length > 0)
            and (.verification | type == "string" and length > 0))' >/dev/null 2>&1 <<< "$json" || continue
        [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = false ] || return 3
        # A partial clone says so as extensions.partialClone or, from git 2.4x,
        # only as remote.<name>.promisor.
        [ -z "$(git config --get-regexp '^(extensions\.partialclone|remote\..*\.promisor)$' 2>/dev/null)" ] || return 3
        since=$(git --no-replace-objects log -1 --full-history --diff-filter=AM --format=%H "$WV_GATE_BASE" -- "$rec" 2>/dev/null) \
            && [ -n "$since" ] || return 2
        rc=0; _gate_repair_consumed "$since" "$path" "$bm" "$old" "$rm" "$new" || rc=$?
        case "$rc" in
            0) continue ;;
            1) printf '%s\n' "$rec"; return 0 ;;
            *) return 2 ;;
        esac
    done <<< "$records"
    return 1
}

# _gate_repair_template <path> [repair|retirement] — the record that would admit this commit's
# transition of <path>, for the refusal to print.
_gate_repair_template() {
    local old new bm rm kind=${2:-repair}
    old=$(git rev-parse -q --verify "$(gate_side_tree base):$1" 2>/dev/null) || old="<HEAD has none>"
    new=$(git rev-parse -q --verify "$(gate_side_tree index):$1" 2>/dev/null) || new="<the index has none>"
    bm=$(_gate_repair_mode "$(gate_side_tree base)" "$1") || bm="<HEAD has no regular file>"
    rm=$(_gate_repair_mode "$(gate_side_tree index)" "$1") || rm="<the index has no regular file>"
    # A retirement that deletes the file names no replacement; one that keeps
    # the file and stops naming a suite names the staged bytes, as
    # gate_repair_record matches them (wv-cc36c7: this blanked both).
    if [ "$kind" = retirement ] && ! git rev-parse -q --verify "$(gate_side_tree index):$1" >/dev/null 2>&1; then
        new=""; rm=000000
    fi
    jq -n --arg p "$1" --arg o "$old" --arg n "$new" --arg bm "$bm" --arg rm "$rm" --arg k "$kind" \
        '{version: 2, kind: $k, path: $p, baseline: $o, replacement: $n,
          baseline_mode: $bm, replacement_mode: $rm,
          reason: "<why this change>", verification: "<how this change was checked>"}'
}

# gate_entry_points <file>... — rule 5 over changed gate files. A lane runs
# only the pre-commit hook, so it cannot run another git hook as written, and
# admitting one would claim a run that never happened (S2b review R2,
# wv-403fb5; owner decision from
# docs/findings/entry-point-lanes-panel-2026-10-13). Changing one waits for a
# record (S2c): one committed earlier, naming this exact change, admits it
# without a lane. Sets _GATE_EP_LANES to the files a lane runs and
# _GATE_EP_RECORDED to "<file>\t<event>\t<record>" for each a record admits;
# shared and retirement replace <event> for those transitions. Shared files
# retain their lane; a retired file has no candidate to run. HEAD's gate still
# judges the subject, so retirement is not a bypass of its refusal.
# any other entry-point change is refused here (printed, return 1).
# One implementation, called twice over one frozen tree: by
# gate_entry_points_preflight before any suite runs, since the verdict
# depends only on the staged paths and HEAD's records (wv-c909ff: a refusal
# arrived after a 991s green pass), and by gate_lanes_run at admission.
gate_entry_points() {
    local f ev rec rrc kind shared
    _GATE_EP_LANES=() _GATE_EP_RECORDED=()
    for f in "$@"; do
        # HEAD's event, else the staged one: a new hook file the commit
        # declares for another event is not run either.
        if ! ev=$(jq -rn --arg f "$f" --argjson b "$_GATE_ROLES_JSON" --argjson i "${_GATE_ROLES_IDX_JSON:-$_GATE_ROLES_JSON}" \
                '$b.entry_points[$f] // $i.entry_points[$f] // empty' 2>/dev/null); then
            echo "✗ Weave pre-commit: could not read the gate entry points from the role contracts — refusing" >&2
            return 1
        fi
        shared=$(jq -r --arg f "$f" '(.shared // []) | index($f) != null' <<< "$_GATE_ROLES_JSON") || return 1
        rrc=0; gate_blob index "$f" >/dev/null 2>&1 || rrc=$?
        kind=repair
        case "$rrc" in
            0) ;;
            1)
                if [ "$f" = scripts/hooks/pre-commit-weave.sh ]; then
                    echo "✗ Weave pre-commit: this commit deletes the gate's hook; retiring the whole boundary is outside the file-retirement protocol — refusing" >&2
                    return 1
                fi
                kind=retirement ;;
            *) echo "✗ Weave pre-commit: could not read changed enforcement $f as a regular file — refusing" >&2; return 1 ;;
        esac
        if [ "$kind" = repair ] && [ "$shared" = false ] && { [ -z "$ev" ] || [ "$ev" = pre-commit ]; }; then
            _GATE_EP_LANES+=("$f")
            continue
        fi
        rrc=0; rec=$(gate_repair_record "$f" "$kind") || rrc=$?
        case "$rrc" in
            0)
                if [ "$kind" = retirement ]; then
                    ev=retirement
                elif [ -z "$ev" ] || [ "$ev" = pre-commit ]; then
                    ev=shared
                    _GATE_EP_LANES+=("$f")
                fi
                _GATE_EP_RECORDED+=("$f"$'\t'"$ev"$'\t'"$rec")
                continue ;;
            1)
                {
                    if [ "$kind" = retirement ]; then
                        echo "✗ Weave pre-commit: deleting enforcement $f needs a prior exact retirement record; a repair record cannot retire it:"
                    elif [ "$shared" = true ] && { [ -z "$ev" ] || [ "$ev" = pre-commit ]; }; then
                        echo "✗ Weave pre-commit: shared change to $f needs a prior exact repair record and must still pass its candidate lane:"
                    else
                        echo "✗ Weave pre-commit: this commit changes the $ev hook ($f). A candidate lane runs only the pre-commit hook, so it cannot run $f as written. To land this exact change, commit a repair record under $GATE_REPAIRS_DIR/ first, on its own (boundary rule 5, wv-9a805a); it admits these bytes once, and records give traceability, not approval:"
                    fi
                    _gate_repair_template "$f" "$kind" | sed 's/^/    /'
                    echo "  — refusing"
                } >&2
                return 1 ;;
            3)
                echo "✗ Weave pre-commit: a $kind record names this change to $f, but this clone's history is shallow or partial, so whether the record was already used cannot be established. Fetch the full history (git fetch --unshallow, or --refetch for a partial clone), then commit again — refusing" >&2
                return 1 ;;
            *)
                echo "✗ Weave pre-commit: could not read the repair records for $f — refusing" >&2
                return 1 ;;
        esac
    done
}

# gate_entry_points_preflight — gate_entry_points over the frozen transition's
# changed gate files, for the hook to call before any suite runs. Needs
# gate_roles_check first. Admits nothing: gate_lanes_run decides again.
gate_entry_points_preflight() {
    local -a files=()
    local rc
    _gate_read_paths files gate_lanes_changed; rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "✗ Weave pre-commit: could not list the changed gate files (rule-5 preflight, status $rc) — refusing" >&2
        return 1
    fi
    [ "${#files[@]}" -gt 0 ] || return 0
    gate_entry_points "${files[@]}"
}

gate_roles_check() {
    _GATE_ROLES_WHY=""
    local base_json idx_json rc=0 lost side tree hits line file ref ev json root rec=""
    local -a enf=()
    # The contract and the enforcement code come from the auth side: HEAD's
    # tree, or a recovery run's execution tree (S2c, wv-0af8f0), whose roles
    # judge the recorded transition it carries.
    base_json=$(_gate_roles_side auth) || rc=$?
    case "$rc" in
        0) ;;
        1) _GATE_ROLES_WHY="HEAD carries no gate role contract ($GATE_ROLES_PATH), so nothing decides which files the gate protects"; return 1 ;;
        *) _GATE_ROLES_WHY="HEAD's gate role contract ($GATE_ROLES_PATH) is not valid"; return 1 ;;
    esac
    rc=0
    idx_json=$(_gate_roles_side index) || rc=$?
    case "$rc" in
        0) ;;
        1) _GATE_ROLES_WHY="this commit removes the gate role contract ($GATE_ROLES_PATH); retiring the boundary needs a record (S2c, wv-d2995e)"; return 1 ;;
        *) _GATE_ROLES_WHY="the staged gate role contract ($GATE_ROLES_PATH) is not valid"; return 1 ;;
    esac
    # Rule 1: a later commit must not lose what this one is checked under. An
    # enforcement prefix, invoking file or entry point the candidate drops is a
    # demotion, and so is a file it newly lets a check share (wv-a75d98).
    lost=$(jq -rn --argjson b "$base_json" --argjson i "$idx_json" \
        "$_GATE_AUTHORITY_JQ"'
         def shares($c): [$c | authority | to_entries[] | .key as $k
             | .value[] | "the full rerun of \(.) (now shared through check_authority \($k))"];
         (($b.enforcement - $i.enforcement) + ($b.invoking - $i.invoking)
          + (($b.shared // []) - ($i.shared // []))
          + (($b.entry_points // {} | keys) - ($i.entry_points // {} | keys))
          + (shares($i) - shares($b)))[0] // empty') || {
        _GATE_ROLES_WHY="could not compare the gate role contracts"; return 1; }
    if [ -n "$lost" ] && ! rec=$(gate_repair_record "$GATE_ROLES_PATH"); then
        _GATE_ROLES_WHY="the staged gate role contract drops $lost, which weakens what later commits are checked under; that needs a record (S2c, wv-d2995e)"
        return 1
    fi
    # An entry point's event is part of its role: relabelling pre-push as
    # pre-commit would let the next commit change it unrun (S2b review N2,
    # wv-3b601f).
    lost=$(jq -rn --argjson b "$base_json" --argjson i "$idx_json" \
        '[($b.entry_points // {}) | to_entries[]
          | select(($i.entry_points // {})[.key] != .value)
          | "\(.key) from \(.value) to \(($i.entry_points // {})[.key])"][0] // empty') || {
        _GATE_ROLES_WHY="could not compare the gate role contracts"; return 1; }
    if [ -n "$lost" ] && ! rec=$(gate_repair_record "$GATE_ROLES_PATH"); then
        _GATE_ROLES_WHY="the staged gate role contract changes the event of $lost; an entry point's role changes only with a record (S2c, wv-d2995e)"
        return 1
    fi
    # The installed dispatcher copies scripts/ and four exact external files
    # (wv-732b60). A declaration cannot grant authority to a path that copy
    # omits, or silently name a missing dependency. Validate each side's own
    # roots, including promotions not yet enforced by HEAD's roles.
    for side in auth index; do
        json=$base_json
        [ "$side" = index ] && json=$idx_json
        tree=$(gate_side_tree "$side") || { _GATE_ROLES_WHY="could not resolve the $side tree"; return 1; }
        while IFS= read -r root; do
            rc=0
            case "$root" in
                scripts|scripts/*)
                    git cat-file -e "$tree:${root%/}" 2>/dev/null || rc=$? ;;
                tests/test-memory-projection-parity.sh|tests/test-shipped-test-refs.sh|tests/lib/release-leak-pattern.ere|build-release.sh)
                    gate_blob "$side" "$root" >/dev/null 2>&1 || rc=$? ;;
                *) _GATE_ROLES_WHY="$side contract has unsupported enforcement root $root; the protected copy cannot run it"; return 1 ;;
            esac
            if [ "$rc" -ne 0 ]; then
                _GATE_ROLES_WHY="$side enforcement root $root is missing, unreadable or not a regular external file"
                return 1
            fi
        done < <(jq -r '.enforcement[]' <<< "$json")
        mapfile -t enf < <(jq -r '.enforcement[]' <<< "$json")
        while IFS= read -r file; do
            [ -n "$file" ] || continue
            if ! _gate_under "$file" "${enf[@]}"; then
                _GATE_ROLES_WHY="$side shared path $file is not declared enforcement"
                return 1
            fi
            if ! gate_blob "$side" "$file" >/dev/null 2>&1; then
                _GATE_ROLES_WHY="$side shared path $file is missing, unreadable or not a regular file"
                return 1
            fi
        done < <(jq -r '(.shared // [])[]' <<< "$json")
    done
    # Rule 2, on both sides, under HEAD's roles: every repository path an
    # enforcement file names through REPO_ROOT is enforcement that exists on
    # that side, or declared external. Only that form is seen, with or without
    # a closing quote before the slash; a path built another way is not (residual,
    # stated in the CHANGELOG).
    # REPO_ROOT is the working tree, not a lane's protected copy, so an
    # enforcement path loaded through it runs the commit's bytes in every lane
    # (S2b review R1, wv-23798e). A file this commit changes may name none:
    # HEAD's are fallbacks on paths no lane takes, and a count of them let a
    # commit move one onto a path a lane does take (review N1, wv-c424ed). A
    # file the commit leaves alone runs as HEAD's in every lane.
    local -A changed=()
    local base_tree label
    base_tree=$(gate_side_tree auth) || { _GATE_ROLES_WHY="could not resolve the base tree"; return 1; }
    mapfile -t enf < <(jq -r '.enforcement[]' <<< "$base_json")
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        if ! gate_blob auth "$line" >/dev/null; then
            _GATE_ROLES_WHY="HEAD's gate role contract names the invoking file $line, which HEAD does not have"
            return 1
        fi
    done < <(jq -r '.invoking[]' <<< "$base_json")
    for side in auth index; do
        label=$side
        [ "$side" = auth ] && label=$([ -n "${_PC_EXEC_TREE:-}" ] && echo execution || echo base)
        tree=$(gate_side_tree "$side") || { _GATE_ROLES_WHY="could not resolve the $label tree"; return 1; }
        rc=0
        hits=$(git grep -o -E '\$\{?REPO_ROOT\}?"?/[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*' \
            "$tree" -- "${enf[@]}" 2>/dev/null) || rc=$?
        [ "$rc" -le 1 ] || { _GATE_ROLES_WHY="could not scan the $label enforcement files"; return 1; }
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            line=${line#"$tree":}
            file=${line%%:*}
            ref=${line#*:}
            ref=${ref#\$\{REPO_ROOT\}}
            ref=${ref#\$REPO_ROOT}
            ref=${ref#\"}
            ref=${ref#/}
            if _gate_under "$ref" "${enf[@]}"; then
                if ! git cat-file -e "$tree:$ref" 2>/dev/null; then
                    _GATE_ROLES_WHY="$file names $ref, an enforcement path the $label tree does not have (unresolved)"
                    return 1
                fi
            elif ! jq -se --arg r "$ref" 'length == 1 and (.[0] | .external | has($r))' >/dev/null 2>&1 <<< "$base_json"; then
                _GATE_ROLES_WHY="$file names $ref ($label), which HEAD's gate role contract does not declare; declare it in $GATE_ROLES_PATH in an earlier commit"
                return 1
            fi
        done < <(sort -u <<< "$hits")
        [ "$side" = index ] || continue
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            line=${line#"$tree":}
            file=${line%%:*}
            ref=${line#*:}
            ref=${ref#\$\{REPO_ROOT\}}
            ref=${ref#\$REPO_ROOT}
            ref=${ref#\"}
            ref=${ref#/}
            _gate_under "$ref" "${enf[@]}" || continue
            if [ -z "${changed[$file]:-}" ]; then
                changed[$file]=no
                [ "$(git rev-parse -q --verify "$tree:$file" 2>/dev/null)" = \
                    "$(git rev-parse -q --verify "$base_tree:$file" 2>/dev/null)" ] || changed[$file]=yes
            fi
            [ "${changed[$file]}" = yes ] || continue
            # A changed entry point no lane runs is refused for that first:
            # the record it needs (S2c) is the one to name.
            ev=$(jq -rn --arg f "$file" --argjson b "$base_json" --argjson i "$idx_json" \
                '$b.entry_points[$f] // $i.entry_points[$f] // empty' 2>/dev/null) || ev=""
            if [ -n "$ev" ] && [ "$ev" != pre-commit ] && ! gate_repair_record "$file" >/dev/null; then
                _GATE_ROLES_WHY="this commit changes the $ev hook ($file). A candidate lane runs only the pre-commit hook, so it cannot run $file as written; changing it needs a repair record committed first under $GATE_REPAIRS_DIR/ (boundary rule 5, wv-9a805a): $(_gate_repair_template "$file" | jq -c .)"
                return 1
            fi
            _GATE_ROLES_WHY="$file names $ref through REPO_ROOT, which is the working tree, not the protected copy each lane runs; name it beside the hook (\$_PC_SCRIPTS, or relative to BASH_SOURCE). A file this commit changes may name no gate code that way (S2b review N1, wv-c424ed)"
            return 1
        done <<< "$hits"
    done
    if [ -n "$rec" ]; then
        echo "⚠ Weave pre-commit: role transition is covered by $rec; traceability, not approval, and the current gate still judges this commit" >&2
    fi
    _gate_authority_note "$base_json" "HEAD's"
    _gate_authority_note "$idx_json" "the staged"
    _GATE_ROLES_JSON=$base_json _GATE_ROLES_IDX_JSON=$idx_json
}

# gate_lanes_changed — enforcement paths the frozen transition changes, NUL
# separated. Needs gate_roles_check first. On failure it says on stderr which
# step failed (wv-759e9a): the preflight once refused inside a gate pool with
# nothing to show why, and never standalone.
gate_lanes_changed() {
    local -a enf=() paths=()
    local p rc enforcement
    enforcement=$(jq -r '.enforcement[]' <<< "${_GATE_ROLES_JSON:-}") \
        || { echo "gate_lanes_changed: decode enforcement paths (status $?) — refusing" >&2; return 1; }
    if [ -z "$enforcement" ]; then
        echo "gate_lanes_changed: the role contract lists no enforcement paths (status 1) — refusing" >&2
        return 1
    fi
    mapfile -t enf <<< "$enforcement"
    # Changed against the auth side: in a recovery run the execution tree,
    # which already holds the recorded paths as staged, so they get no lane.
    local auth idx
    auth=$(gate_side_tree auth) || { echo "gate_lanes_changed: resolve frozen auth tree (status $?) — refusing" >&2; return 1; }
    idx=$(gate_side_tree index) || { echo "gate_lanes_changed: resolve frozen index tree (status $?) — refusing" >&2; return 1; }
    _gate_read_paths paths git diff-tree -r -z --name-only --no-renames "$auth" "$idx"; rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "gate_lanes_changed: capture git diff-tree $auth $idx failed (status $rc)" >&2
        return 1
    fi
    for p in "${paths[@]}"; do
        _gate_under "$p" "${enf[@]}" && printf '%s\0' "$p"
    done
    return 0
}

# gate_lanes_slots <dir> <jobs> — the gate-wide suite budget (wv-428a92):
# <jobs> slot files that every lane's suites take one of before they launch
# (wv-gate-supervisor.py holds the flock). Lanes each running a pool of the
# whole bound once ran 12 suite jobs on 4 CPUs (wv-d7af8d); fixed shares fixed
# that but left a slot idle whenever its lane finished early or had fewer
# suites than its share. With shared slots each lane may queue up to <jobs>
# suites, and whichever lane has one waiting takes the next free slot.
GATE_LANES_SCHEDULER="shared-slots"
gate_lanes_slots() {
    local dir=$1 jobs=$2 s
    mkdir "$dir" || { echo "gate_lanes_slots: create $dir (status $?) — refusing" >&2; return 1; }
    for ((s = 0; s < jobs; s++)); do
        : > "$dir/$s" || { echo "gate_lanes_slots: create slot $s in $dir (status $?) — refusing" >&2; return 1; }
    done
}

# _gate_lane_build <dir> <tar> <path> — the execution envelope with <path>
# staged. An external gate file is never placed in it: the check that reads
# one takes the lane's copy from the frozen tree (R-a, wv-a75d98).
_gate_lane_build() {
    local d=$1 tar=$2 f=$3 blob rc=0 mode tree
    mkdir -p "$d/tree" || { echo "_gate_lane_build: create $d/tree (status $?) — refusing" >&2; return 1; }
    tar -xf "$tar" -C "$d/tree" || { echo "_gate_lane_build: extract $tar (status $?) — refusing" >&2; return 1; }
    rm -f "$d/tree/$f" || { echo "_gate_lane_build: remove $f (status $?) — refusing" >&2; return 1; }
    case "$f" in scripts/*) ;; *) return 0 ;; esac
    blob=$(gate_blob index "$f") || rc=$?
    case "$rc" in
        0)
            mkdir -p "$(dirname "$d/tree/$f")" || { echo "_gate_lane_build: create parent for $f (status $?) — refusing" >&2; return 1; }
            git cat-file blob "$blob" > "$d/tree/$f" || { echo "_gate_lane_build: write blob $blob for $f (status $?) — refusing" >&2; return 1; }
            tree=$(gate_side_tree index) || { echo "_gate_lane_build: resolve index tree (status $?) — refusing" >&2; return 1; }
            mode=$(git ls-tree --full-tree "$tree" -- "$f") || { echo "_gate_lane_build: read mode for $f (status $?) — refusing" >&2; return 1; }
            mode=${mode%% *}
            chmod "$([ "$mode" = 100755 ] && echo 755 || echo 644)" "$d/tree/$f" || { echo "_gate_lane_build: chmod $f (status $?) — refusing" >&2; return 1; } ;;
        1) ;;
        *) echo "_gate_lane_build: read staged blob for $f (status $rc) — refusing" >&2; return 1 ;;
    esac
}

# _gate_lanes_first_refusal <root> <launched> — the index of the first of the
# <launched> lanes under <root> that finished and refused, or nothing.
_gate_lanes_first_refusal() {
    local k rc
    for ((k = 0; k < $2; k++)); do
        rc=$(cat "$1/$k/rc" 2>/dev/null) || continue
        [ "$rc" = 0 ] || { echo "$k"; return 0; }
    done
}

gate_lanes_run() {
    local work=$1 root t0 c0 k0 jobs i n=0 running=0 failed=0 stopped=0 reuse f ev tree saved _gl_pid=""
    local logs=""
    shift
    local -a files=() pids=() reuses=()
    _GATE_LANES_DONE="" _GATE_LANES_RUNS="" _GATE_LANES_MS="" _GATE_LANES_T0="" _GATE_LANES_CLOCK=""
    _gate_read_paths files gate_lanes_changed \
        || { echo "✗ Weave pre-commit: could not list the changed gate files (admission, status $?) — refusing" >&2; return 1; }
    [ "${#files[@]}" -gt 0 ] || return 0
    # Rule 5 decides here, at admission, over the same frozen tree the
    # preflight judged before the suites ran.
    gate_entry_points "${files[@]}" || return 1
    local recorded
    for recorded in ${_GATE_EP_RECORDED[@]+"${_GATE_EP_RECORDED[@]}"}; do
        IFS=$'\t' read -r f ev recorded <<< "$recorded"
        case "$ev" in
            shared) echo "⚠ Weave pre-commit: shared change to $f is covered by $recorded and still runs in its candidate lane; traceability, not approval" >&2 ;;
            retirement) echo "⚠ Weave pre-commit: deletion of $f is covered by retirement record $recorded; the baseline gate still judges this commit; traceability, not approval" >&2 ;;
            *) echo "⚠ Weave pre-commit: $f is not run; this change to the $ev hook is admitted by the repair record $recorded, which gives traceability, not approval (boundary rule 5)" >&2 ;;
        esac
    done
    files=(${_GATE_EP_LANES[@]+"${_GATE_EP_LANES[@]}"})
    [ "${#files[@]}" -gt 0 ] || return 0
    # t0 is when the lanes started (an epoch stamp for the gate record); their
    # total is measured on wv-clock.sh's clock, which leaves out a suspend.
    t0=$(wv_now ns 2>/dev/null || echo 0)
    wv_clock_ms c0 k0
    root=$(mktemp -d "$work/lanes.XXXXXX") || { echo "gate_lanes_run: allocate lanes under $work (status $?) — refusing" >&2; return 1; }
    tree=$(gate_side_tree auth) || { echo "gate_lanes_run: resolve auth tree (status $?) — refusing" >&2; return 1; }
    _pc_gate_archive "$tree" "$root/gate.tar" || { echo "gate_lanes_run: archive auth tree $tree (status $?) — refusing" >&2; return 1; }
    jobs=$(hook_gate_jobs)
    # `wait -n` needs bash 4.3; older bash runs the lanes one at a time.
    if [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 3 ]; }; then
        jobs=1
    fi
    gate_lanes_slots "$root/slots" "$jobs" || return 1
    hook_progress "candidate lanes: ${#files[@]} changed gate file(s), each judged in its own lane holding it as staged and HEAD's other files (boundary rule 4), sharing $jobs suite slot(s)..."
    # Finish preparation before launching any lane: a later setup refusal
    # cannot leave an earlier lane running without a supervisor to await it.
    for i in "${!files[@]}"; do
        f=${files[$i]}
        if ! _gate_lane_build "$root/$i" "$root/gate.tar" "$f"; then
            echo "✗ Weave pre-commit: could not build the candidate lane for $f — refusing" >&2
            return 1
        fi
        if [ ! -f "$root/$i/tree/scripts/hooks/pre-commit-weave.sh" ]; then
            echo "✗ Weave pre-commit: this commit deletes the gate's hook ($f); retiring the gate needs a record (S2c, wv-d2995e) — refusing" >&2
            return 1
        fi
        # An external file shares the protected pass's suite results only when
        # HEAD's contract declares the one check that reads it; anything else,
        # including a contract whose check_authority is absent or malformed,
        # reruns (N6, wv-a75d98).
        reuse=0
        case "$f" in
            scripts/*) jq -se --arg f "$f" 'length == 1 and (.[0] | .invoking | index($f) == null)' ;;
            *) jq -se --arg f "$f" "length == 1 and (.[0] | $_GATE_AUTHORITY_JQ"' (.invoking | index($f) == null)
                    and ([authority[][]] | index($f) != null))' ;;
        esac >/dev/null 2>&1 <<< "$_GATE_ROLES_JSON" && reuse=1
        # The lane mark is history (HEAD); a recovery run's lanes also carry
        # its execution tree, the code they were built from.
        if [ -n "${_PC_EXEC_TREE:-}" ]; then
            printf '%s\n' "$_PC_EXEC_TREE" > "$root/$i/weave-gate-exec" \
                || { echo "gate_lanes_run: mark execution tree for $f (status $?) — refusing" >&2; return 1; }
        fi
        printf '%s\n' "$WV_GATE_BASE" > "$root/$i/weave-gate-lane" \
            || { echo "gate_lanes_run: mark base for $f (status $?) — refusing" >&2; return 1; }
        printf 'path=%s\ntree=%s\nreuse=%s\n' "$f" "$WV_GATE_TREE" "$reuse" > "$root/$i/weave-gate-candidate" \
            || { echo "gate_lanes_run: mark candidate for $f (status $?) — refusing" >&2; return 1; }
        reuses[i]=$reuse
    done
    saved=$(trap -p INT TERM HUP)
    trap 'for _gl_pid in "${pids[@]}"; do kill -TERM "$_gl_pid" 2>/dev/null || true; done; for _gl_pid in "${pids[@]}"; do wait "$_gl_pid" 2>/dev/null || true; done; exit 130' INT TERM HUP
    # The first refusal decides (wv-744cb2): every lane must admit, so once one
    # refuses, the lanes still running are stopped and the rest never start,
    # as the suite pool stops at its first failed suite. Waiting for them cost
    # 400-2,690s on four refused gates in the 30 days to 2026-11-19.
    # WV_GATE_KEEP_GOING=1 (gate-preflight.sh --keep-going) judges every lane.
    local keep=${WV_GATE_KEEP_GOING:-0} stop=""
    for i in "${!files[@]}"; do
        if [ "$running" -ge "$jobs" ]; then
            wait -n 2>/dev/null || true
            running=$((running - 1))
        fi
        [ "$keep" = 1 ] || [ -n "$stop" ] || stop=$(_gate_lanes_first_refusal "$root" "${#pids[@]}")
        if [ -n "$stop" ]; then
            : > "$root/$i/stopped"
            continue
        fi
        (
            lt0=$(wv_now ns 2>/dev/null || echo 0)
            lrc=0
            WV_GATE_ELAPSED="$root/$i/elapsed" \
            gate_run_bounded "candidate lane ${files[$i]}" "${WV_GATE_LANE_TIMEOUT:-7200}" \
                env -u WV_LIB_DIR -u WV_CLI -u WV_PRECOMMIT_RUNNING -u WV_SKIP_PRECOMMIT -u WV_GATE_ELAPSED WV_HOOK_REEXEC=1 \
                WV_GATE_LANE_JOBS="$jobs" WV_GATE_SLOTS="$root/slots" WV_GATE_SC_LOCK="$root/shellcheck.lock" \
                bash "$root/$i/tree/scripts/hooks/pre-commit-weave.sh" "$@" > "$root/$i/out" 2>&1 || lrc=$?
            # The supervisor's monotonic reading leaves out a suspend (wv-b17a85).
            if read -r lel lkind < "$root/$i/elapsed" 2>/dev/null \
                && [ "$lkind" = monotonic ] && [[ "$lel" =~ ^[0-9]+$ ]]; then
                echo "$lel" > "$root/$i/ms"; echo monotonic > "$root/$i/clock"
            else
                hook_duration_ms "$lt0" > "$root/$i/ms"; echo wall > "$root/$i/clock"
            fi
            # Written last and by rename: an rc file means the lane finished.
            echo "$lrc" > "$root/$i/rc.tmp" && mv "$root/$i/rc.tmp" "$root/$i/rc"
        ) &
        pids+=("$!")
        running=$((running + 1))
    done
    # Drain one lane at a time, so a refusal stops the others while they run.
    # Without wait -n (bash before 4.3) the lanes ran one at a time and a
    # refusal already stopped the launches above.
    if [ "$keep" != 1 ] && [ "$jobs" -gt 1 ]; then
        while [ -z "$stop" ] && [ "$running" -gt 0 ]; do
            wait -n 2>/dev/null || true
            running=$((running - 1))
            stop=$(_gate_lanes_first_refusal "$root" "${#pids[@]}")
        done
    fi
    if [ -n "$stop" ]; then
        for i in "${!pids[@]}"; do
            [ -f "$root/$i/rc" ] && continue
            : > "$root/$i/stopped"
            kill -TERM "${pids[$i]}" 2>/dev/null || true
        done
    fi
    for i in "${pids[@]}"; do wait "$i" 2>/dev/null || true; done
    trap - INT TERM HUP
    [ -z "$saved" ] || eval "$saved"
    for i in "${!files[@]}"; do
        n=$((n + 1))
        # A lane stopped by another's refusal judged nothing: it neither admits
        # nor refuses. A lane that finished as it was stopped keeps its result.
        if [ ! -f "$root/$i/rc" ] && [ -f "$root/$i/stopped" ]; then
            stopped=$((stopped + 1))
            hook_progress "candidate lane ${files[$i]}: not judged, stopped after ${files[$stop]} refused (WV_GATE_KEEP_GOING=1 judges every lane)"
            continue
        fi
        # Per-lane cost, so a lane that reruns its suites is measured on its
        # own rather than hidden in the total (wv-7ee8fe).
        hook_progress "candidate lane ${files[$i]}: $([ "${reuses[$i]}" = 1 ] && echo "reused HEAD's suite results" || echo "reran its suites") from $jobs shared suite slot(s) in $(cat "$root/$i/ms" 2>/dev/null || echo "?")ms"
        if [ "$(cat "$root/$i/rc" 2>/dev/null)" = "0" ]; then
            _GATE_LANES_DONE="${_GATE_LANES_DONE:+$_GATE_LANES_DONE,}${files[$i]}"
            continue
        fi
        failed=$((failed + 1))
        {
            echo ""
            echo "✗ Weave pre-commit: the candidate version of ${files[$i]} does not admit this commit, run against HEAD's copies of every other gate file (boundary rule 4, exit $(cat "$root/$i/rc" 2>/dev/null || echo lost))."
            echo "  If it needs another file this commit changes, land that file first."
            # The dispatcher's EXIT trap removes work, including these lanes.
            # Retain only logs outside it, not the bulky execution copies.
            [ -n "$logs" ] || logs=$(wv_scratch_create) || logs=""
            if [ -n "$logs" ]; then
                if cp "$root/$i/out" "$logs/$i.out"; then
                    echo "  full output: $logs/$i.out"
                else
                    echo "  could not retain lane output (copy status $?)"
                fi
            fi
            LC_ALL=C sed $'s/\e\\[[0-9;]*m//g' "$root/$i/out" 2>/dev/null | grep -v '^Weave pre-commit: ' | grep . | tail -20 | sed 's/^/    /'
        } >&2
    done
    wv_clock_since _GATE_LANES_MS _GATE_LANES_CLOCK "$c0" "$k0"
    hook_progress "candidate lanes: $((n - failed - stopped)) of $n admitted$([ "$stopped" -eq 0 ] || echo ", $stopped stopped") in ${_GATE_LANES_MS}ms"
    # For the gate record (wv-3dbc11): lanes write no suite rows of their own,
    # so without this their time is the unattributed tail of the gate's wall
    # time (wv-241d5f). One object per lane, the ms and rc the lines above print.
    _GATE_LANES_T0=$t0
    _GATE_LANES_RUNS=$(for i in "${!files[@]}"; do
        jq -cn --arg path "${files[$i]}" --arg reused "${reuses[$i]}" --arg ms "$(cat "$root/$i/ms" 2>/dev/null)" \
            --arg jobs "$jobs" --arg rc "$(cat "$root/$i/rc" 2>/dev/null)" --arg sched "$GATE_LANES_SCHEDULER" \
            --arg clock "$(cat "$root/$i/clock" 2>/dev/null || echo unknown)" \
            --arg stopped "$([ ! -f "$root/$i/rc" ] && [ -f "$root/$i/stopped" ] && echo 1)" \
            '{path:$path, reused:($reused == "1"), ms:($ms | tonumber? // null),
              jobs:($jobs | tonumber? // null), rc:($rc | tonumber? // null), scheduler:$sched, clock:$clock}
             + (if $stopped == "1" then {stopped:true} else {} end)'
    done | jq -cs '.' 2>/dev/null) || _GATE_LANES_RUNS=""
    rm -rf "$root"
    [ "$failed" -eq 0 ]
}
