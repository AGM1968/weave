#!/usr/bin/env bash
# wv-checkpoint-ci.sh — decide whether a weave-authored checkpoint/sync commit
# may safely carry GitHub's native [skip ci] push-skip marker.
#
# wv-e937f8 (external audit, a consumer repository's dev.3 session, cross-
# referenced against this repo's own wv-4637d2-equivalent history): GitHub
# applies [skip ci] to the WHOLE PUSH when the marker appears in the commit
# at the push's TIP, not just that commit's own diff. Every checkpoint site
# below stages `.weave/` only, so the checkpoint's OWN diff is always
# .weave-only — but if the checkpoint lands on top of already-unpushed
# non-.weave/ work (a real code/doc commit still waiting to be pushed),
# reinstating the marker silently skips CI for that work too the moment this
# checkpoint becomes the push tip. Reproduced live in this repo's own
# history: commit ec4eea5c ("auto-checkpoint ... [skip ci]") landed directly
# on top of 42f8e759 (real code+tests) and both were pushed together.
#
# wv-f76ac9's CI paths-ignore snippet fixes this from the CONSUMER's
# workflow-rule side (keys on changed files, robust to token placement).
# This fixes the marker at the source, for repos that haven't adopted that
# snippet or whose CI still greps the message.
#
# wv-822bea/wv-179c49 (distribution re-audit of wv-e937f8): the first cut
# above had three residual gaps, all in the direction of applying [skip ci]
# when it was NOT actually safe to:
#   1. Hardcoded "origin/$branch" instead of resolving the branch's actual
#      configured upstream via @{u} — wrong for a differently-named remote
#      branch or a non-origin remote.
#   2. Defaulted to " [skip ci]" whenever the upstream didn't resolve (new
#      branch, never pushed, or any other lookup failure). That's backwards:
#      a brand-new branch's first push sends its ENTIRE history as the push
#      tip's range, so a real code commit sitting under a [skip-ci-marked]
#      checkpoint gets silently skipped on that very first push — the exact
#      failure mode this function exists to prevent. Reproduced live in this
#      repo: a fresh branch + a real commit + no upstream both produced a
#      marker under the old logic.
#   3. Used the endpoint `git diff upstream..HEAD --name-only`, which shows
#      only the NET difference between two trees — a file added by one
#      unpushed commit and removed by a later one in the same range vanishes
#      from that diff entirely, even though non-.weave/ work did happen in
#      the range. `git log --name-only` over the same range lists every path
#      touched by any commit in it, which is what "does this range carry
#      non-.weave/ work" actually means.
# All three point the same direction: an inspection that can't prove the
# range is .weave/-only must fail toward NOT skipping CI, not toward
# skipping it — a spuriously-run CI check costs nothing but a bit of compute,
# a spuriously-skipped one silently hides a real regression from review.

# ── A checkpoint never rewrites a commit a push published (wv-13db30, wv-8258e5) ──
# The three checkpoint writers (auto_checkpoint, wv sync, the session-end
# checkpoint) collapse consecutive graph-only checkpoints by amending HEAD when
# it is not yet published. The upstream ref alone cannot say so. It moves only
# when a push completes, and the pre-push gate runs for minutes first: a
# checkpoint in that window amended the very commit being pushed (wv-13db30).
# It also never moves when the push names a URL instead of the remote, so it can
# sit commits behind what is published: a checkpoint ten days after such a push
# amended a published commit and diverged a consumer's main from GitHub
# (wv-8258e5). The pre-push hook runs for every push, so it records what each
# push publishes, and a recorded commit is never amended, however old the
# record.

# wv_push_inflight_file <git-root> — where that record lives: the git common
# dir, shared by worktrees and never part of a tree.
wv_push_inflight_file() {
    local dir
    dir=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
    printf '%s/weave-push-inflight\n' "$dir"
}

# wv_push_inflight_record <git-root> <commit>... — the pre-push hook records
# the commits it is about to publish, before its gate runs. One line per push,
# "<epoch> <commit>...", appended; the file keeps the newest
# WV_PUSH_RECORD_KEEP lines (default 50), so a push of another branch does not
# erase this branch's record. Never fails the push.
wv_push_inflight_record() {
    local root=$1 file keep=${WV_PUSH_RECORD_KEEP:-50}
    shift
    [ "$#" -gt 0 ] || return 0
    [[ "$keep" =~ ^[1-9][0-9]*$ ]] || keep=50
    file=$(wv_push_inflight_file "$root") || return 0
    if {
        [ -f "$file" ] && tail -n "$((keep - 1))" "$file" 2>/dev/null
        printf '%s' "$(date +%s)"; printf ' %s' "$@"; printf '\n'
    } > "$file.$$" 2>/dev/null; then
        mv -f "$file.$$" "$file" 2>/dev/null || rm -f "$file.$$" 2>/dev/null
    else
        rm -f "$file.$$" 2>/dev/null
    fi
    return 0
}

# wv_push_publishing <git-root> <commit> — 0 when a recorded push published or
# may still be publishing <commit>: a record names <commit> or a descendant of
# it, and the upstream ref does not contain that pushed commit (when it does,
# the ancestry test in wv_checkpoint_amendable already refuses). A record
# never ages out. A push that failed leaves its record, and checkpoints then add
# commits instead of amending until the next push, which costs a commit and
# never a rewrite.
wv_push_publishing() {
    local root=$1 commit=$2 file stamp pushed upstream line
    file=$(wv_push_inflight_file "$root") || return 1
    [ -f "$file" ] || return 1
    upstream=$(git -C "$root" rev-parse -q --verify '@{u}' 2>/dev/null) || upstream=""
    local p
    while IFS= read -r line; do
        read -r stamp pushed <<< "$line"
        [[ "$stamp" =~ ^[0-9]+$ ]] || continue
        for p in $pushed; do
            [ "$commit" = "$p" ] || git -C "$root" merge-base --is-ancestor "$commit" "$p" 2>/dev/null || continue
            [ -n "$upstream" ] && git -C "$root" merge-base --is-ancestor "$p" "$upstream" 2>/dev/null && continue
            return 0
        done
    done < "$file"
    return 1
}

# wv_push_recorded_ahead <git-root> — how many commits ahead of the upstream a
# recorded push already sent: 0 when there is no upstream or no record. The
# reports that count "unpushed" commits against the tracking ref read this, so
# a replica whose ref is stale (a refused fetch, a push to a URL) says so rather
# than telling the operator to push what is published (wv-d235b6). A failed push
# also leaves a record, so this is a doubt to report, never a reason to count
# the commits as pushed. Local only: no fetch, no network.
wv_push_recorded_ahead() {
    local root=$1 file upstream stamp pushed line p mb n best=0
    file=$(wv_push_inflight_file "$root") || { echo 0; return 0; }
    [ -f "$file" ] || { echo 0; return 0; }
    upstream=$(git -C "$root" rev-parse -q --verify '@{u}' 2>/dev/null) || { echo 0; return 0; }
    while IFS= read -r line; do
        read -r stamp pushed <<< "$line"
        [[ "$stamp" =~ ^[0-9]+$ ]] || continue
        for p in $pushed; do
            git -C "$root" merge-base --is-ancestor "$p" "$upstream" 2>/dev/null && continue
            mb=$(git -C "$root" merge-base HEAD "$p" 2>/dev/null) || continue
            n=$(git -C "$root" rev-list --count "$upstream..$mb" 2>/dev/null) || continue
            [ "$n" -gt "$best" ] && best=$n
        done
    done < "$file"
    echo "$best"
}

# wv_checkpoint_amendable <git-root> — 0 when HEAD may be amended by the next
# checkpoint: neither origin/<branch> nor the upstream contains it, it is a
# weave checkpoint commit, it changes only .weave/, and no recorded push
# published or may be publishing it. The one rule all three checkpoint writers
# apply; they each carried a copy, and only one of the copies listed renames
# correctly (wv-b60cd5).
wv_checkpoint_amendable() {
    local root=$1 branch head ref msg nw
    branch=$(git -C "$root" branch --show-current 2>/dev/null) || branch=""
    [ -n "$branch" ] || branch=main
    head=$(git -C "$root" rev-parse HEAD 2>/dev/null) || return 1
    # Containment, not equality: a HEAD behind its tracking ref is published too.
    for ref in "origin/$branch" '@{u}'; do
        git -C "$root" rev-parse -q --verify "$ref" >/dev/null 2>&1 || continue
        ! git -C "$root" merge-base --is-ancestor "$head" "$ref" 2>/dev/null || return 1
    done
    msg=$(git -C "$root" log -1 --format='%s' 2>/dev/null) || return 1
    [[ "$msg" =~ auto-checkpoint|sync\ state|session-start\ state|pre-compact\ checkpoint ]] || return 1
    # --no-renames: a file moved into .weave/ would otherwise list only under
    # its new path, and the commit would read as .weave-only (wv-b60cd5).
    nw=$(git -C "$root" diff --no-renames HEAD~1 HEAD --name-only 2>/dev/null) || return 1
    # One grep, no pipe: under pipefail a grep -q leaving early fails the pipe.
    ! grep -qv -e '^\.weave/' -e '^$' <<< "$nw" || return 1
    ! wv_push_publishing "$root" "$head"
}

# wv_checkpoint_ci_marker <git-root>
#   Echoes " [skip ci]" (leading space, ready to append to a commit subject)
#   only when the upstream resolves AND every path touched anywhere in the
#   unpushed range (@{u}..HEAD) is under .weave/. Echoes "" (empty) — no
#   marker, CI runs normally — when the range carries any non-.weave/ path,
#   when @{u} doesn't resolve (no remote, branch never pushed, no upstream
#   configured), or on any git inspection failure. Never fails the caller.
wv_checkpoint_ci_marker() {
    local git_root="$1"
    local upstream nonweave
    upstream=$(git -C "$git_root" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || echo "")
    if [ -z "$upstream" ]; then
        # No configured upstream (new/never-pushed branch, or none set) —
        # can't bound the range that would be pushed, so can't prove it's
        # .weave/-only. Fail toward running CI, not skipping it.
        echo ""
        return
    fi
    if ! git -C "$git_root" rev-parse --verify -q "$upstream" >/dev/null 2>&1; then
        # Upstream is configured but doesn't resolve locally (stale
        # tracking ref, not yet fetched) — same fail-safe direction.
        echo ""
        return
    fi
    local log_output log_rc
    # --no-renames: a source file moved into .weave/ listed only its new path,
    # so the range read as .weave/-only and CI was skipped (wv-581bb0).
    log_output=$(git -C "$git_root" log --format= --name-only --no-renames "$upstream..HEAD" 2>/dev/null)
    log_rc=$?
    if [ "$log_rc" -ne 0 ]; then
        # git log itself failed (bad range, corrupt repo, ...) — can't prove
        # .weave/-only, fail toward running CI.
        echo ""
        return
    fi
    nonweave=$(printf '%s\n' "$log_output" | grep -v '^\.weave/' | grep -v '^$' || true)
    if [ -n "$nonweave" ]; then
        echo ""
    else
        echo " [skip ci]"
    fi
}

# ── Graph state vs configuration (wv-2e6341) ──────────────────────────────────
# Checkpoint and sync commits carry the graph: files wv rewrites on its own as
# the graph changes. Everything else under .weave/ -- test-map.conf,
# quality.conf, patterns/, causal-cutover, evidence/ -- is configuration someone
# edits on purpose, and a change there selects pre-commit suites of its own.
# Staging all of .weave/ swept an in-progress test-map row into a
# 'session-start state' commit that skipped every one of those gates. This list
# is an allowlist: a new file wv writes stays uncommitted (and the stop hook
# says so) until it is added here, which is the safe direction.
WV_GRAPH_STATE_PATHS=(
    .weave/state.sql
    .weave/nodes.jsonl
    .weave/edges.jsonl
    .weave/deltas
    .weave/trails.md
    .weave/breadcrumbs.md
    .weave/runtime.md
    .weave/quality-adjudications.jsonl
)

# wv_stage_graph_state <git-root>
#   Stages additions, changes and deletions under the graph-state paths only.
#   A path is passed to git add when it is tracked, or on disk and not ignored:
#   one unmatched pathspec makes git add stage nothing, and an ignored one
#   makes it fail after staging the rest.
wv_stage_graph_state() {
    local git_root="$1" path present=()
    for path in "${WV_GRAPH_STATE_PATHS[@]}"; do
        if [ -n "$(git -C "$git_root" ls-files -- "$path" 2>/dev/null | head -1)" ] \
           || { [ -e "$git_root/$path" ] && ! git -C "$git_root" check-ignore -q -- "$path" 2>/dev/null; }; then
            present+=("$path")
        fi
    done
    [ "${#present[@]}" -gt 0 ] || return 0
    git -C "$git_root" add -A -- "${present[@]}" || return
    wv_stage_memory_projections "$git_root"
}

# ── Memory projections ride with the graph (wv-0cd718) ────────────────────────
# The committed projections render the graph's active memories. A commit whose
# graph changes that set must carry fresh projections, and the pre-commit gate
# checks it (wv-ff0419), but checkpoint and sync commits skip the gate: four
# memories reached HEAD that way on 2026-10-26..29 with no projection listing
# them, and the next commit to stage CLAUDE.md was refused for it.
WV_MEMORY_PROJECTION_PATHS=(
    CLAUDE.md
    AGENTS.md
    .codex/weave.json
    .github/copilot-instructions.md
)
WV_ACTIVE_MEMORY_FILTER='[.[] | .metadata |= (if type == "string" then fromjson else . // {} end)
    | select((.metadata.node_kind // .metadata.type) == "memory" and (.metadata.mem_status // "active") == "active")
    | {id, text, verified_at: .metadata.verified_at, hook: .metadata.hook, resident: .metadata.resident}] | sort_by(.id)'

# wv_stage_memory_projections <git-root>
#   When the staged graph's active memories differ from HEAD's, renders HEAD's
#   projections afresh in a scratch copy and stages the result beside the
#   graph. A working file that is neither HEAD's nor that render holds an edit
#   of its own; nothing is written or staged then, with a warning, because a
#   checkpoint must not commit someone's edit. Returns 0 either way: a
#   checkpoint is never refused for this.
wv_stage_memory_projections() {
    local git_root="$1" old new path scratch tracked=()
    [ "${_WV_MEMORY_RENDERING:-0}" = 1 ] && return 0
    command -v jq >/dev/null 2>&1 || return 0
    # Same blob, same memories: skip the two whole-graph reads (~0.4 s here).
    git -C "$git_root" diff --cached --quiet HEAD -- .weave/nodes.jsonl 2>/dev/null && return 0
    old=$(git -C "$git_root" show HEAD:.weave/nodes.jsonl 2>/dev/null | jq -sc "$WV_ACTIVE_MEMORY_FILTER" 2>/dev/null) || return 0
    new=$(git -C "$git_root" show :.weave/nodes.jsonl 2>/dev/null | jq -sc "$WV_ACTIVE_MEMORY_FILTER" 2>/dev/null) || return 0
    [ "$old" != "$new" ] || return 0
    # Only a projection that already carries the memory block takes part: a
    # render appends a block to a file without one, and a consumer's CLAUDE.md
    # or copilot-instructions.md without it is the user's (wv-91f0ca).
    for path in "${WV_MEMORY_PROJECTION_PATHS[@]}"; do
        case "$path" in
            *.json) git -C "$git_root" show "HEAD:$path" 2>/dev/null | jq -e '.memory' >/dev/null 2>&1 || continue ;;
            *) grep -qF -- '<!-- ── BEGIN WEAVE:MEMORY ──' <<< "$(git -C "$git_root" show "HEAD:$path" 2>/dev/null)" || continue ;;
        esac
        tracked+=("$path")
    done
    [ "${#tracked[@]}" -gt 0 ] || return 0
    scratch=$(mktemp -d "${TMPDIR:-/tmp}/wv-projections.XXXXXX") || return 0
    for path in "${tracked[@]}"; do
        mkdir -p "$scratch/$(dirname "$path")" 2>/dev/null
        git -C "$git_root" show "HEAD:$path" > "$scratch/$path" 2>/dev/null || { rm -rf "$scratch"; return 0; }
    done
    # The render must not checkpoint again, or it would land back here.
    if ! (cd "$git_root" && _WV_MEMORY_RENDERING=1 WV_AUTO_CHECKPOINT=0 \
            "${WV_CLI:-wv}" memory render --agent=all --base-dir="$scratch" >/dev/null 2>&1); then
        rm -rf "$scratch"
        echo "wv: active memories changed and 'wv memory render --agent=all' failed; the memory projections stay stale until it runs" >&2
        return 0
    fi
    for path in "${tracked[@]}"; do
        if ! cmp -s "$git_root/$path" "$scratch/$path" \
            && ! git -C "$git_root" diff --quiet HEAD -- "$path" 2>/dev/null; then
            rm -rf "$scratch"
            echo "wv: active memories changed, but $path has an edit of its own; run 'wv memory render --agent=all' and commit the projections with it" >&2
            return 0
        fi
    done
    for path in "${tracked[@]}"; do
        cat "$scratch/$path" > "$git_root/$path"
    done
    rm -rf "$scratch"
    git -C "$git_root" add -- "${tracked[@]}" 2>/dev/null || true
    return 0
}

# wv_staged_non_graph_state <git-root>
#   Prints staged paths that are not graph state, one per line: caller work,
#   including .weave/ configuration. A checkpoint that finds any must not
#   commit, or it absorbs that work. Returns 1 when the index cannot be listed:
#   that is not "nothing staged", and every caller treats it as staged work
#   (wv-9c6ae1). It returned 0 with no output, which a checkpoint read as safe.
wv_staged_non_graph_state() {
    local staged
    # --no-renames: a caller file moved into .weave/ must still show its removal.
    staged=$(git -C "$1" diff --cached --name-only --no-renames 2>/dev/null) || return 1
    wv_non_graph_state_paths <<< "$staged"
}

# wv_unstaged_non_graph_state <git-root>
#   Prints tracked paths outside graph state that have unstaged edits.
#   `git pull --rebase --autostash` stashes these and re-applies them, which in
#   a checkout someone else is editing (another agent session, the user's
#   editor) rewrites their files under them and strands the edits in a stash
#   when the re-apply conflicts (wv-fbbdff). A checkpoint pull that finds any
#   is skipped. Returns 1 when the tree cannot be listed; callers treat that as
#   edits present.
wv_unstaged_non_graph_state() {
    local changed
    changed=$(git -C "$1" diff --name-only --no-renames 2>/dev/null) || return 1
    wv_non_graph_state_paths <<< "$changed"
}

# wv_auto_commit_enabled [<git-root>] -- false when Weave must make no commit
# on its own: auto_checkpoint, wv sync's final sync-state commit, and the
# session-end and pre-compact checkpoints. Only auto_checkpoint read
# WV_AUTO_CHECKPOINT, so the switch stopped one path of three and a session
# holding its .weave/ commit still had it made for it (wv-fbbdff).
#   Two ways to turn them off: WV_AUTO_CHECKPOINT=0 in the environment, or the
# hold file `$(git rev-parse --git-path weave-autocommit-hold)` existing. The
# variable reaches only the processes that inherit it; harness hooks run in the
# harness's environment, so an agent's export never reached a hook's wv calls
# (wv-99d4d2). The file is seen by every process in that checkout (a linked
# worktree has its own), so one session can hold the checkout for all of them.
#   A third: a commit or push gate holding the checkout (wv-c5500d's lock). A
# checkpoint made or amended under a running gate moves HEAD beneath it
# (2026-11-09: an amend landed mid-gate); it waits for the next checkpoint
# instead (wv-2f32a7). The gate's own shell never calls this.
wv_auto_commit_enabled() { # predicate
    [ "${WV_AUTO_CHECKPOINT:-1}" != "0" ] || return 1
    local hold root="${1:-.}"
    hold=$(git -C "$root" rev-parse --git-path weave-autocommit-hold 2>/dev/null) || return 0
    case "$hold" in /*) ;; *) hold="$root/$hold" ;; esac
    [ ! -e "$hold" ] || return 1
    if ! declare -F wv_gate_hold_status >/dev/null; then
        # shellcheck source=/dev/null
        [ -r "$(dirname "${BASH_SOURCE[0]}")/wv-gate-hold.sh" ] \
            && . "$(dirname "${BASH_SOURCE[0]}")/wv-gate-hold.sh" 2>/dev/null
    fi
    if declare -F wv_gate_hold_status >/dev/null \
        && [ -n "$(cd "$root" 2>/dev/null && wv_gate_hold_status)" ]; then
        return 1
    fi
    return 0
}

# wv_prepush_gate_installed — true when git will run a Weave pre-push hook in
# this repository (core.hooksPath respected). The two-tier gate (wv-862ac0)
# defers [heavy] suites to that hook only when this holds, and wv done treats a
# heavy suite with no fresh row as deferred rather than stale only when it
# holds, so both sides of the deferral answer the question the same way.
# Executable, not merely present: git skips a hook without the execute bit, so
# a marked but non-executable file deferred heavy suites to a gate that never
# ran (wv-ecae1c). An unresolvable hooks dir is "not installed", not /pre-push.
wv_prepush_gate_installed() {
    local hooks
    hooks="$(git rev-parse --git-path hooks 2>/dev/null)" && [ -n "$hooks" ] || return 1
    [ -f "$hooks/pre-push" ] && [ -x "$hooks/pre-push" ] \
        && grep -q "Weave pre-push" "$hooks/pre-push" 2>/dev/null
}

# wv_reftx_gate_installed — true when git will run the Weave
# reference-transaction hook here, which binds a commit's publication to the
# tree the pre-commit gate judged (R1, wv-5f9d1c). git runs that hook from 2.28;
# an older git, or a missing, non-executable or foreign hook, is "not
# installed", and pre-commit then states that its admission is check-then-use.
wv_reftx_gate_installed() {
    local hooks v major minor
    v=$(git version 2>/dev/null) || return 1
    v=${v#git version }
    major=${v%%.*}; minor=${v#*.}; minor=${minor%%.*}
    case "$major$minor" in ''|*[!0-9]*) return 1 ;; esac
    [ "$major" -gt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -ge 28 ]; } || return 1
    hooks="$(git rev-parse --git-path hooks 2>/dev/null)" && [ -n "$hooks" ] || return 1
    [ -f "$hooks/reference-transaction" ] && [ -x "$hooks/reference-transaction" ] \
        && grep -q "Weave reference-transaction" "$hooks/reference-transaction" 2>/dev/null
}

# wv_non_graph_state_paths — filter repo-relative paths on stdin to those
# outside graph state, by the same allowlist. The pre-push gate (wv-862ac0)
# classifies a pushed range's files with it, so its idea of "graph state" is
# the one pre-commit and the checkpoint sites use.
wv_non_graph_state_paths() {
    local path prefix
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        for prefix in "${WV_GRAPH_STATE_PATHS[@]}"; do
            if [ "$path" = "$prefix" ] || [[ "$path" == "$prefix"/* ]]; then
                continue 2
            fi
        done
        printf '%s\n' "$path"
    done
}

# wv_path_absent <path> — the path is observably absent: nothing is at it, and
# its nearest existing ancestor is a directory this process can search. An
# unsearchable ancestor hides whether the path exists, and a test of it fails
# the same way a missing one does, so that is not absence (wv-3fab34).
wv_path_absent() { # predicate
    local d="$1"
    [ -e "$d" ] || [ -L "$d" ] && return 1
    while d=$(dirname -- "$d"); do
        [ -e "$d" ] && break
        [ "$d" = / ] || [ "$d" = . ] && return 1
    done
    [ -d "$d" ] && [ -x "$d" ]
}

# wv_config_read <path> — print a configuration file a gate depends on.
#   0  present: its content is on stdout
#   2  absent: observably nothing at the path (wv_path_absent)
#   1  unavailable: an entry that cannot be read -- unreadable, a directory,
#      a dangling symlink -- or a path whose existence cannot be observed
# Absent and unavailable used to be one answer: a dangling or unreadable
# test-map.conf read as no configuration, and the gates routed by heuristics
# or skipped the heavy tier (wv-b02828).
wv_config_read() {
    if [ -e "$1" ] || [ -L "$1" ]; then
        cat -- "$1" 2>/dev/null || return 1
        return 0
    fi
    wv_path_absent "$1" && return 2
    return 1
}

# wv_policy_value <text> <section> <key> — one key of .weave/policy.conf, the
# repository's policy settings (wv-27131a): ini sections, `key = value` on one
# line, `#` starts a comment, the last assignment wins. Prints nothing when unset.
wv_policy_value() {
    awk -v want="[$2]" -v key="$3" '
        { sub(/#.*/, ""); gsub(/^[ \t]+|[ \t]+$/, "") }
        /^\[/ { in_section = ($0 == want); next }
        in_section && index($0, "=") {
            k = substr($0, 1, index($0, "=") - 1); v = substr($0, index($0, "=") + 1)
            gsub(/[ \t]+$/, "", k); gsub(/^[ \t]+/, "", v)
            if (k == key) value = v
        }
        END { print value }' <<< "$1"
}

# wv_memory_outside_graph <weave_dir> <harness> — the repository keeps this
# harness's memory outside the graph by choice: [memory] outside_graph names it
# (comma or space separated) and reason is set (ruling D3 on wv-80fa17).
#   0  kept outside by choice: the reason is on stdout
#   1  not kept outside: no policy.conf, or the harness is not named
#   2  .weave/policy.conf cannot be read
#   3  named without a reason, which records no choice
wv_memory_outside_graph() {
    local text rc=0 names reason
    text=$(wv_config_read "$1/policy.conf") || rc=$?
    [ "$rc" -eq 2 ] && return 1
    [ "$rc" -eq 0 ] || return 2
    names=$(wv_policy_value "$text" memory outside_graph)
    case " ${names//,/ } " in *" $2 "*) ;; *) return 1 ;; esac
    reason=$(wv_policy_value "$text" memory reason)
    [ -n "$reason" ] || return 3
    printf '%s\n' "$reason"
}
