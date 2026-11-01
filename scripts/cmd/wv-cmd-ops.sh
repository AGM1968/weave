#!/bin/bash
# wv-cmd-ops.sh — Operations and diagnostic commands
#
# Commands: bootstrap, health, cache, audit-pitfalls, edge-types, help
# Sourced by: wv entry point (after lib modules)
# Dependencies: wv-config.sh, wv-db.sh, wv-validate.sh, wv-cache.sh, wv-cmd-core.sh

# ═══════════════════════════════════════════════════════════════════════════
# cmd_bootstrap — Single-call session context for agents
# ═══════════════════════════════════════════════════════════════════════════
# Replaces the 8-call bootstrap sequence (list+status+list+show+context+
# search+ready+learnings) with one composite command. Returns everything
# an agent needs at session start in a single JSON blob.
#
# Usage: wv bootstrap --json [--learnings=N]
#
# Output shape:
#   { status: {active, ready, blocked, ...},
#     active_node: {id, text, status, done_criteria, ...} | null,
#     context: <context pack for active node> | null,
#     ready: [{id, text}, ...],
#     learnings: [{id, text, learning}, ...] }

# The project's own wv, for the operator to run; bootstrap reports the path and
# never runs it. The commit gate refuses a changed gate file that names gate
# code under the working tree's root, since a lane would run the commit's
# bytes (S2b review N1, wv-c424ed); a path only reported is not that, so it is
# joined from the root and a relative name.
_bootstrap_repo_wv_path() {
    [ -n "${REPO_ROOT:-}" ] || return 0
    local rel=scripts/wv
    canonicalize_runtime_path "$REPO_ROOT/$rel"
}

_bootstrap_invoked_wv_path() {
    if [ -n "${WV_CLI:-}" ]; then
        canonicalize_runtime_path "$WV_CLI"
        return 0
    fi
    local resolved
    resolved=$(command -v wv 2>/dev/null || true)
    if [ -n "$resolved" ]; then
        canonicalize_runtime_path "$resolved"
    fi
}

_bootstrap_canonical_wv_path() {
    local repo_wv
    repo_wv=$(_bootstrap_repo_wv_path)
    if [ -n "$repo_wv" ] && [ -x "$repo_wv" ]; then
        echo "$repo_wv"
        return 0
    fi

    local invoked_wv
    invoked_wv=$(_bootstrap_invoked_wv_path)
    if [ -n "$invoked_wv" ]; then
        echo "$invoked_wv"
    fi
}

_bootstrap_wv_provenance() {
    local path="$1"
    local repo_wv
    repo_wv=$(_bootstrap_repo_wv_path)
    local dev_wv=""
    if [ -n "${WV_LIB_DIR:-}" ]; then
        dev_wv=$(canonicalize_runtime_path "$WV_LIB_DIR/wv")
    fi
    local installed_wv
    installed_wv=$(canonicalize_runtime_path "$HOME/.local/bin/wv")

    if [ -n "$repo_wv" ] && [ "$path" = "$repo_wv" ]; then
        echo "repo-local"
    elif [ -n "$dev_wv" ] && [ "$path" = "$dev_wv" ]; then
        echo "repo-local"
    elif [ "$path" = "$installed_wv" ]; then
        echo "installed"
    elif [ -n "$path" ]; then
        echo "path"
    else
        echo "missing"
    fi
}

_bootstrap_shell_token() {
    local token="$1"
    if [[ "$token" =~ ^[A-Za-z0-9_./:=+-]+$ ]]; then
        printf '%s\n' "$token"
    else
        printf "'%s'\n" "${token//\'/\'\\\'\'}"
    fi
}

_bootstrap_agent_tools_json() {
    local wv_command="${1:-wv}"
    local wv_token
    local ast_grep_path ast_grep_version
    local chunks_count=0 quality_ready=false chunks_ready=false ast_grep_ready=false

    wv_token=$(_bootstrap_shell_token "$wv_command")

    ast_grep_path=$(command -v ast-grep 2>/dev/null || true)
    if [ -n "$ast_grep_path" ]; then
        ast_grep_ready=true
        ast_grep_version=$(ast-grep --version 2>/dev/null | head -1 || true)
    else
        ast_grep_version=""
    fi

    if [ -n "${WV_DB:-}" ] && [ -f "$WV_DB" ]; then
        chunks_count=$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='chunks';" 2>/dev/null | {
            read -r has_chunks
            if [ "${has_chunks:-0}" = "1" ]; then
                sqlite3 "$WV_DB" "SELECT COUNT(*) FROM chunks;" 2>/dev/null || echo 0
            else
                echo 0
            fi
        })
    fi
    [ "${chunks_count:-0}" -gt 0 ] 2>/dev/null && chunks_ready=true

    if [ -n "${WV_HOT_ZONE:-}" ] && [ -f "$WV_HOT_ZONE/quality.db" ]; then
        # scan_meta is the scan-run table (see weave_quality/db.py); same probe
        # as the search --code readiness path above.
        local latest_scan
        latest_scan=$(sqlite3 -batch -cmd ".timeout 3000" "$WV_HOT_ZONE/quality.db" \
            "SELECT id FROM scan_meta ORDER BY id DESC LIMIT 1;" 2>/dev/null || echo "")
        [ -n "$latest_scan" ] && quality_ready=true
    fi

    jq -n \
        --arg wv "$wv_token" \
        --arg wv_raw "$wv_command" \
        --arg ast_grep_path "$ast_grep_path" \
        --arg ast_grep_version "$ast_grep_version" \
        --argjson ast_grep_ready "$ast_grep_ready" \
        --argjson chunks_ready "$chunks_ready" \
        --argjson chunks_count "${chunks_count:-0}" \
        --argjson quality_ready "$quality_ready" \
        '{
            warmup: [
                ($wv + " doctor --agent --json"),
                ($wv + " index . --json"),
                ($wv + " quality scan . --json")
            ],
            code_search: {
                command: ($wv + " search --code \"<query>\" --json"),
                ready: $chunks_ready,
                chunks: $chunks_count,
                warmup: ($wv + " index . --json")
            },
            index: {
                command: ($wv + " index . --json"),
                ready: $chunks_ready,
                chunks: $chunks_count
            },
            quality: {
                command: ($wv + " quality scan . --json"),
                ready: $quality_ready
            },
            impact: {
                command: ($wv + " impact <id> --json --quality"),
                warmup: ($wv + " quality scan . --json")
            },
            discovery_routing: {
                procedure: ($wv + " guide --procedure=discovery-routing"),
                locate_work: [
                    {
                        operation: "search",
                        argv_template: [$wv_raw, "search", "{topic}", "--json"],
                        placeholders: {topic: "graph work topic, for example auth"}
                    },
                    {
                        operation: "query",
                        argv_template: [$wv_raw, "query", "{predicate}", "--format=json"],
                        placeholders: {predicate: "one exact predicate, for example status=active"}
                    }
                ],
                uncertain_or_cross_node: [
                    {operation: "context", argv_template: [$wv_raw, "context", "{node_id}", "--json"]},
                    {operation: "discover", argv_template: [$wv_raw, "discover", "{node_id}", "--json"]},
                    {operation: "impact", argv_template: [$wv_raw, "impact", "{node_id}", "--json"]}
                ],
                unfamiliar_implementation: {
                    operation: "search_code",
                    argv_template: [$wv_raw, "search", "--code", "{concept}", "--graph", "--json"]
                },
                broad_edit: {
                    operation: "impact_files",
                    argv_template: [$wv_raw, "impact", "--files={targets}", "--json"],
                    placeholders: {targets: "comma-separated repository-relative paths"}
                },
                hotspot: [
                    {operation: "quality_functions", argv_template: [$wv_raw, "quality", "functions", "{file}", "--json"]},
                    {operation: "quality_patterns", argv_template: [$wv_raw, "quality", "patterns", "scan", "{scope}", "--json"]}
                ]
            },
            ast_grep: {
                command: ($wv + " quality structural-search --pattern=<pattern> --lang=python --json"),
                ready: $ast_grep_ready,
                path: (if $ast_grep_path != "" then $ast_grep_path else null end),
                version: (if $ast_grep_version != "" then $ast_grep_version else null end)
            }
        }'
}

_bootstrap_codex_json() {
    local wv_command="${1:-wv}"
    local wv_token telemetry_log telemetry_token
    wv_token=$(_bootstrap_shell_token "$wv_command")
    # Use the durable config.env path when set; fall back to the persistent default.
    # The /tmp hot-zone path was previously used here but is ephemeral
    # and diverges from WV_CALL_LOG — two writers, two paths, no coordination.
    telemetry_log="${WV_CALL_LOG:-${WV_CALL_LOG_DEFAULT:-$HOME/.local/share/weave/wv_calls.jsonl}}"
    telemetry_token=$(_bootstrap_shell_token "$telemetry_log")
    local telemetry_enabled=false telemetry_writable=false
    [ -n "${WV_CALL_LOG:-}" ] && telemetry_enabled=true
    if [ "$telemetry_enabled" = true ]; then
        # Real append probe — permission bits lie on read-only filesystems
        # (Codex EROFS): the open itself must succeed. Logging would create
        # the file anyway, so the side effect is acceptable here.
        { : >> "$telemetry_log"; } 2>/dev/null && telemetry_writable=true
    else
        # Side-effect-free heuristic: never create a log that isn't enabled.
        if [ -e "$telemetry_log" ]; then
            [ -w "$telemetry_log" ] && telemetry_writable=true
        else
            [ -w "$(dirname "$telemetry_log")" ] && telemetry_writable=true
        fi
    fi

    jq -n --arg wv "$wv_token" --arg telemetry_log "$telemetry_log" --arg telemetry_token "$telemetry_token" \
        --argjson telemetry_enabled "$telemetry_enabled" \
        --argjson telemetry_writable "$telemetry_writable" '{
        mcp: {
            recommended_scope: "lite",
            safe_default: "weave-lite",
            full_scope_warning: "Full Weave MCP can hang in Codex on network/GitHub operations; use CLI commands for privileged work."
        },
        telemetry: ({
            call_log: $telemetry_log,
            enabled: $telemetry_enabled,
            writable: $telemetry_writable,
            scope: (if ($telemetry_enabled | not) then "disabled"
                    elif $telemetry_writable then "persistent"
                    else "unavailable" end),
            durability: "durable log at ~/.local/share/weave/wv_calls.jsonl (config.env WV_CALL_LOG); survives reboot",
            enable_for_command: "wv config enable session-analysis",
            analyze: ($wv + " analyze sessions --call-stats")
        } + (if $telemetry_enabled and ($telemetry_writable | not) then
            {warning: "call log path is not writable in this environment — new calls are NOT recorded; analyze reads stale host data"}
        elif ($telemetry_enabled | not) then
            {note: "session-analysis is not enabled — no calls are being recorded"}
        else {} end)),
        commands: {
            bootstrap: ($wv + " bootstrap-agent --json"),
            doctor: ($wv + " doctor --agent --json"),
            claim: ($wv + " work <id>"),
            record_edit: ($wv + " touch <id> --files=<path>"),
            close: ($wv + " ship-agent <id> --learning-file=<path> --verification-method=<cmd> --verification-evidence-file=<path> --json"),
            local_sync: ($wv + " sync --mode=fast --node=<id>"),
            github_sync: ($wv + " sync --gh --mode=fast --node=<id>")
        },
        network_policy: {
            mcp: "local/read-only by default",
            github_sync: "CLI only; request shell network approval when needed",
            git_push: "CLI only; request shell network/SSH approval when needed"
        }
    }'
}

_bootstrap_agent_info_json() {
    local wv_command invoked_wv repo_wv db_path python_command wv_provenance readiness_state tools_json codex_json
    local wv_ready=false db_ready=false python_ready=false command_mismatch=false

    wv_command=$(_bootstrap_canonical_wv_path)
    invoked_wv=$(_bootstrap_invoked_wv_path)
    repo_wv=$(_bootstrap_repo_wv_path)
    db_path=$(canonicalize_runtime_path "${WV_DB:-}")
    python_command=$(_bootstrap_python_command)
    wv_provenance=$(_bootstrap_wv_provenance "$invoked_wv")
    tools_json=$(_bootstrap_agent_tools_json "${wv_command:-wv}")
    codex_json=$(_bootstrap_codex_json "${wv_command:-wv}")

    [ -n "$wv_command" ] && [ -x "$wv_command" ] && wv_ready=true
    [ -n "$db_path" ] && [ -f "$db_path" ] && db_ready=true
    [ -n "$python_command" ] && [ -x "$python_command" ] && python_ready=true
    if [ -n "$wv_command" ] && [ -n "$invoked_wv" ] && [ "$wv_command" != "$invoked_wv" ]; then
        command_mismatch=true
    fi

    readiness_state="ready"
    if [ "$wv_ready" != "true" ] || [ "$db_ready" != "true" ] || [ "$python_ready" != "true" ]; then
        readiness_state="degraded"
    fi

    jq -n \
        --arg wv_command "$wv_command" \
        --arg invoked_wv "$invoked_wv" \
        --arg repo_wv "$repo_wv" \
        --arg wv_provenance "$wv_provenance" \
        --arg wv_lib_dir "$(canonicalize_runtime_path "${WV_LIB_DIR:-}")" \
        --arg db_path "$db_path" \
        --arg python_command "$python_command" \
        --arg readiness_state "$readiness_state" \
        --argjson tools "$tools_json" \
        --argjson codex "$codex_json" \
        --argjson wv_ready "$wv_ready" \
        --argjson db_ready "$db_ready" \
        --argjson python_ready "$python_ready" \
        --argjson command_mismatch "$command_mismatch" \
        '{
            wv_command: (if $wv_command != "" then $wv_command else null end),
            invoked_wv: (if $invoked_wv != "" then $invoked_wv else null end),
            repo_local_wv: (if $repo_wv != "" then $repo_wv else null end),
            wv_provenance: $wv_provenance,
            command_mismatch: $command_mismatch,
            wv_lib_dir: (if $wv_lib_dir != "" then $wv_lib_dir else null end),
            db_path: (if $db_path != "" then $db_path else null end),
            python_command: (if $python_command != "" then $python_command else null end),
            readiness: {
                state: $readiness_state,
                wv_command: $wv_ready,
                db_path: $db_ready,
                python_command: $python_ready
            },
            tools: $tools,
            codex: $codex
        } | with_entries(select(.value != null))'
}

# ── Readiness (wv-814d33) ── Working on a broken framework makes no sense
# (owner, 2026-09-24): make check red on main and a guard no route selected were
# both found mid-commit, while bootstrap said nothing and health read 100/100.
# Bootstrap is the step-0 surface every harness reads, so it now says whether
# the framework is known green for HEAD and which open structural nodes come
# first. Nothing runs here: the framework state is whatever `make check` last
# recorded in the clone's git dir, which every agent sharing the clone sees.

# _bootstrap_framework_json -> {state, commit, exit, at, target[, reason]} or
# null. state: green | red | stale (recorded for another commit) | unverified
# (passed with uncommitted changes) | unknown (checking repo, nothing recorded).
# A repository whose Makefile does not record a result gets null, not noise.
_bootstrap_framework_json() {
    local top git_dir record head
    top=$(git rev-parse --show-toplevel 2>/dev/null) || { echo 'null'; return 0; }
    git_dir=$(git -C "$top" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || { echo 'null'; return 0; }
    record="$git_dir/weave-framework-check.json"
    if [ ! -f "$record" ]; then
        if grep -qs 'weave-framework-check' "$top/Makefile"; then
            echo '{"state":"unknown","reason":"no make check result recorded in this clone"}'
        else
            echo 'null'
        fi
        return 0
    fi
    head=$(git -C "$top" rev-parse HEAD 2>/dev/null || echo "")
    # The same code-tree hash the Makefile records (wv-92d7c1): HEAD's top-level
    # tree without .weave/, so graph-only commits do not make a result stale.
    # Records written before code_tree existed fall back to the commit.
    local tree
    tree=$(git -C "$top" ls-tree HEAD 2>/dev/null | awk -F'\t' '$2 != ".weave"' | git -C "$top" hash-object --stdin 2>/dev/null || echo "")
    jq -c --arg head "$head" --arg tree "$tree" '
        if (.exit | type) != "number" or (.commit | type) != "string" then
            {state: "unknown", reason: "unreadable framework-check record"}
        else
            {commit, exit, at, target} + (
                if (if (.code_tree // "") != "" then .code_tree != $tree else .commit != $head end) then {state: "stale"}
                elif .exit != 0 then {state: "red"}
                elif .dirty == true then {state: "unverified", reason: "passed with uncommitted changes"}
                else {state: "green"} end)
        end' "$record" 2>/dev/null ||
        echo '{"state":"unknown","reason":"unreadable framework-check record"}'
}

# _bootstrap_structural_json -> [{id, text}] for open nodes marked
# metadata.structural, oldest first. Structural work is fixed before feature work.
_bootstrap_structural_json() {
    local rows
    rows=$(db_query_json "
        SELECT id, substr(text, 1, 90) AS text FROM nodes
        WHERE status != 'done'
          AND json_extract(metadata, '\$.structural') IN (1, 'true')
        ORDER BY created_at ASC;" 2>/dev/null)
    echo "${rows:-[]}"
}

# _bootstrap_heavy_tier_json -> the push tier's state for the commits not yet
# on the upstream (wv-862ac0), or null (no upstream, no [heavy] section):
# {state, upstream, suites:[{suite, state}]}. Green/red describe a previous
# frozen attempt for this tip, not current execution eligibility: bootstrap
# cannot reproduce the hook's protected installation and environment. Only
# pre-push's exact snapshot-key lookup authorizes reuse (wv-bbeff4).
# State is the worst observation, clear when nothing is owed, unknown when
# commits or suites cannot be listed. Nothing runs here; pre-push runs them.
_bootstrap_heavy_tier_json() {
    local top upstream files selected suite out st rows
    top=$(git rev-parse --show-toplevel 2>/dev/null) || { echo 'null'; return 0; }
    # An unavailable map is not one without [heavy]: it says unknown (wv-b02828).
    local map_text map_rc=0
    map_text=$(wv_config_read "$WEAVE_DIR/test-map.conf") || map_rc=$?
    [ "$map_rc" -eq 2 ] && { echo 'null'; return 0; }
    upstream=$(git -C "$top" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) \
        || { echo 'null'; return 0; }
    # A listing or routing failure is "unknown", never "clear": clear tells the
    # operator nothing is owed at push (wv-cf48a9).
    local unknown='{state: "unknown", upstream: $u, suites: [], reason: $r}'
    if [ "$map_rc" -ne 0 ]; then
        jq -cn --arg u "$upstream" --arg r ".weave/test-map.conf cannot be read" "$unknown"
        return 0
    fi
    # What pre-push owes, selected as it selects (follow-up review F3,
    # wv-ade029): each unpushed commit's files, routed by the maps that commit
    # and its parents hold. The working-tree map alone dropped a suite an
    # earlier commit deferred once a later one removed [heavy]. No tier at all
    # (null) only when no map, in the working tree or any of those commits,
    # declares one; the header is read as the router reads it (wv-ee5e36).
    local commits ids c p text heavy=no any_files=no
    commits=$(git -C "$top" rev-list "$upstream..HEAD" 2>/dev/null) || {
        jq -cn --arg u "$upstream" --arg r "git rev-list $upstream..HEAD failed" "$unknown"
        return 0
    }
    grep -qE '^[[:space:]]*\[heavy\]' <<< "$map_text" && heavy=yes
    if [ "$heavy" = no ] && [ -n "$commits" ]; then
        # shellcheck disable=SC2086  # a commit list, split on purpose
        ids=$(git -C "$top" rev-list --no-walk=unsorted --parents $commits 2>/dev/null) || {
            jq -cn --arg u "$upstream" --arg r "the unpushed commits' parents could not be listed" "$unknown"
            return 0
        }
        for c in $(tr ' ' '\n' <<< "$ids" | sort -u); do
            git -C "$top" cat-file -e "$c:.weave/test-map.conf" 2>/dev/null || continue
            text=$(git -C "$top" cat-file blob "$c:.weave/test-map.conf" 2>/dev/null) || {
                jq -cn --arg u "$upstream" --arg r "the test map at ${c:0:12} could not be read" "$unknown"
                return 0
            }
            grep -qE '^[[:space:]]*\[heavy\]' <<< "$text" && { heavy=yes; break; }
        done
    fi
    [ "$heavy" = yes ] || { echo 'null'; return 0; }
    local files parents routed heavy_now
    local -a file_args=() revs=()
    selected=""
    # Load the router before naming the maps: loading it sets _IMPACT_MAP_REVS
    # to (), which wiped the revisions set ahead of the first call, and that
    # call routed by the working-tree map instead.
    _wv_autoload graph
    for c in $commits; do
        files=$(git -C "$top" diff-tree --root -m -r --no-commit-id --name-only --no-renames "$c" 2>/dev/null) \
            && parents=$(git -C "$top" rev-parse "$c^@" 2>/dev/null) || {
            jq -cn --arg u "$upstream" --arg r "commit ${c:0:12} could not be read" "$unknown"
            return 0
        }
        files=$(sort -u <<< "$files" | wv_non_graph_state_paths)
        [ -n "$files" ] || continue
        any_files=yes
        mapfile -t file_args <<< "$files"
        revs=("$c")
        for p in $parents; do revs+=("$p"); done
        if ! routed=$(_IMPACT_MAP_REVS=("${revs[@]}"); _impact_suites_for_files "${file_args[@]}" 2>/dev/null) \
            || ! heavy_now=$(jq -r '.[] | select(.tier == "heavy") | .name' <<< "$routed" 2>/dev/null); then
            jq -cn --arg u "$upstream" --arg r "the suite selection could not be resolved (wv impact --suites)" "$unknown"
            return 0
        fi
        selected+="$heavy_now"$'\n'
    done
    if [ "$any_files" = no ]; then
        jq -cn --arg u "$upstream" '{state: "clear", upstream: $u, suites: []}'
        return 0
    fi
    selected=$(grep . <<< "$selected" | sort -u)
    # Observations never populate or substitute for @inputs reuse records.
    # Match the full frozen subject conservatively, including both the index
    # and worktree: opposite staged/unstaged edits must not cancel out here.
    local tree base input_base clean=false
    if ! tree=$(git -C "$top" rev-parse 'HEAD^{tree}' 2>/dev/null) \
        || ! base=$(git -C "$top" rev-parse 'HEAD^{commit}' 2>/dev/null) \
        || ! input_base=$(git -C "$top" merge-base HEAD "$upstream" 2>/dev/null); then
        jq -cn --arg u "$upstream" --arg r "the frozen readiness subject could not be resolved" "$unknown"
        return 0
    fi
    if git -C "$top" diff --quiet --ignore-submodules=none \
        && git -C "$top" diff --cached --quiet "$base" --ignore-submodules=none; then
        clean=true
    fi
    out='[]'
    if [ -n "$selected" ]; then
        rows=$(db_query_json "SELECT suite, fingerprint, exit_code FROM test_results
            WHERE path='@snapshot-observation:prepush';" 2>/dev/null) || rows='[]'
        while IFS= read -r suite; do
            [ -n "$suite" ] || continue
            st=$(jq -r --arg s "$suite" --arg t "$tree" --arg b "$base" --arg u "$input_base" \
                --argjson clean "$clean" '
                .[] | select(.suite == $s) | (.fingerprint | fromjson) as $o
                | select($clean and $o.tree == $t and $o.base == $b and $o.input_base == $u
                    and ($o.key | test("^snapshot-v1:[0-9a-f]{64}$")))
                | if .exit_code == 0 then "green" else "red" end' <<< "${rows:-[]}" 2>/dev/null)
            case "$st" in green|red) ;; *) st=pending ;; esac
            out=$(jq -c --arg s "$suite" --arg t "$st" '. + [{suite: $s, state: $t}]' <<< "$out")
        done <<< "$selected"
    fi
    jq -c --arg u "$upstream" '{upstream: $u, suites: .,
        basis: "snapshot-observation", execution_inputs: "unverified",
        state: (if length == 0 then "clear"
                elif any(.state == "red") then "red"
                elif any(.state == "pending") then "pending"
                else "green" end)}' <<< "$out"
}

# _bootstrap_readiness_advisories <framework_json> <structural_json>
# [heavy_tier_json] -> a JSON array of advisory strings, framework first.
_bootstrap_readiness_advisories() {
    # The structural list is uncapped: files, not argv (wv-200d36).
    jq -cn --slurpfile fw <(printf '%s' "$1") --slurpfile st <(printf '%s' "$2") \
        --slurpfile ht <(printf '%s' "${3:-null}") '
        $fw[0] as $fw | $st[0] as $st | $ht[0] as $ht
        | def short: (. // "") | .[0:9];
        [
            (if $fw == null then empty
             elif $fw.state == "red" then
                "framework red: \($fw.target // "make check") failed (exit \($fw.exit)) at HEAD \($fw.commit | short) - fix it before other work"
             elif $fw.state == "stale" then
                "framework unverified for HEAD: last \($fw.target // "make check") ran at \($fw.commit | short) and exited \($fw.exit) - run make check"
             elif $fw.state == "unverified" then
                "framework unverified: \($fw.target // "make check") passed at HEAD with uncommitted changes - commit or rerun"
             elif $fw.state == "unknown" then
                "framework unverified: \($fw.reason // "no result") - run make check"
             else empty end),
            ($st[] | "structural, fix first: \(.id) \(.text)"),
            (if $ht == null then empty
             elif $ht.state == "red" then
                "heavy tier red for commits not on \($ht.upstream): \([$ht.suites[] | select(.state == "red") | .suite] | join(", ")) - last frozen attempt failed; fix before other work; git push revalidates"
             elif $ht.state == "green" then
                "heavy tier last passed for this tip; current execution inputs are unverified - git push checks exact reuse eligibility"
             elif $ht.state == "pending" then
                "heavy tier pending for commits not on \($ht.upstream): \([$ht.suites[] | select(.state != "green") | .suite] | join(", ")) - git push runs them"
             elif $ht.state == "unknown" then
                "heavy tier unknown for commits not on \($ht.upstream): \($ht.reason // "no reason given") - git push refuses until it resolves"
             else empty end)
        ]'
}

cmd_bootstrap() {
    local format="json"
    local learnings_limit=5
    local ready_limit=10

    while [ $# -gt 0 ]; do
        case "$1" in
            --json)          format="json" ;;
            --learnings=*)   learnings_limit="${1#--learnings=}" ;;
            --ready=*)       ready_limit="${1#--ready=}" ;;
            --help|-h)
                echo "Usage: wv bootstrap --json [--learnings=N] [--ready=N]"
                echo ""
                echo "Single-call session context for agents. Returns status, active node"
                echo "context pack, ready work, recent learnings and the graph memory index"
                echo "(one line per active memory; full text: wv memory recall) in one JSON blob."
                echo ""
                echo "Options:"
                echo "  --learnings=N  Number of recent learnings (default: 5)"
                echo "  --ready=N      Number of ready nodes (default: 10)"
                return 0
                ;;
            -*) _wv_reject_arg bootstrap "$1"; return 1 ;;  # wv-016983
        esac
        shift
    done

    if [ "$format" != "json" ]; then
        echo "Error: wv bootstrap only supports --json output" >&2
        return 1
    fi
    case "$ready_limit" in
        ''|*[!0-9]*)
            echo "Error: wv bootstrap --ready takes a whole number, got '$ready_limit'" >&2
            return 1
            ;;
    esac

    db_ensure

    # ── 1. Status counts (single query) ──
    local status_json
    status_json=$(cmd_status --json 2>/dev/null || echo '{}')

    # ── 2. Active node + context pack ──
    local active_node="null"
    local context_pack="null"
    local active_id=""

    # Find primary or first active node
    active_id=$(get_primary_node 2>/dev/null || true)
    if [ -n "$active_id" ]; then
        local pstatus
        pstatus=$(db_query "SELECT status FROM nodes WHERE id='$active_id';" 2>/dev/null)
        [ "$pstatus" != "active" ] && active_id=""
    fi
    if [ -z "$active_id" ]; then
        active_id=$(db_query "SELECT id FROM nodes WHERE status='active' LIMIT 1;" 2>/dev/null)
    fi

    if [ -n "$active_id" ]; then
        # Get node details via json-v2 shape
        active_node=$(db_query_json_v2 "SELECT id, text, status, metadata FROM nodes WHERE id='$active_id';")
        active_node=$(echo "${active_node:-[]}" | jq '.[0] // null')

        # Get full context pack (reuses existing cmd_context logic + caching)
        context_pack=$(cmd_context "$active_id" --json --mode=discover 2>/dev/null || echo 'null')
        [ -z "$context_pack" ] && context_pack="null"
    fi

    # ── 3. Ready work ──
    # wv ready's own rows, so parked, reserved, memory and foreign-claimed nodes
    # stay out by the same predicate and order; a second query here drifted from
    # it and advertised parked work at every session start (wv-31d8c2).
    local ready_json
    ready_json=$(cmd_ready --json-v2 2>/dev/null | jq -c --argjson n "$ready_limit" '.[:$n]' 2>/dev/null)
    ready_json="${ready_json:-[]}"

    # ── 4. Recent learnings ──
    local learnings_json
    learnings_json=$(db_query_json "
        SELECT id, text, status, metadata FROM nodes
        WHERE status = 'done'
          AND (json_extract(metadata, '\$.learning') IS NOT NULL
               OR json_extract(metadata, '\$.decision') IS NOT NULL
               OR json_extract(metadata, '\$.pattern') IS NOT NULL
               OR json_extract(metadata, '\$.pitfall') IS NOT NULL)
        ORDER BY updated_at DESC
        LIMIT $learnings_limit;
    ")
    learnings_json="${learnings_json:-[]}"

    # ── 5. Trails (if present) ── prefer trails.md, fall back to legacy breadcrumbs.md
    local breadcrumb=""
    local bc_file="${WEAVE_DIR}/trails.md"
    [ -f "$bc_file" ] || bc_file="${WEAVE_DIR}/breadcrumbs.md"
    if [ -f "$bc_file" ]; then
        breadcrumb=$(head -5 "$bc_file" | grep -v '^#' | grep -v '^$' | head -1 | sed 's/^[[:space:]]*//')
    fi

    # ── Cross-agent install-drift advisory ── editing weave source without
    # reinstalling leaves installed copies stale; every harness reads bootstrap
    # at session start, so surface it here (Claude/Codex/Copilot alike).
    local drift_files drift_advisory=""
    if drift_files=$(_wv_source_drift); then
        drift_advisory="install drift: edited source not reinstalled (${drift_files}) — source commits do not install; run ./install.sh (dev repo) or 'wv init-repo --update' (consumer) explicitly when updating the installed runtime is intended"
    fi

    # ── Cross-agent quality-scan advisory ── the quality gate (_done_refresh_*)
    # blocks `wv done` when the active node touches tracked files but quality.db
    # is missing/un-scanned. That surfaces at the finish line, forcing a scan +
    # retry (wv-7fbc0f). Surface it early via the same readiness evaluator the
    # close gate uses, so the agent scans during work — cross-agent, every
    # harness reads bootstrap (Claude/Codex/Copilot). Advisory only; the close
    # gate stays authoritative.
    local quality_advisory=""
    if [ -n "$active_id" ]; then
        local quality_readiness
        quality_readiness=$(_preflight_policy_readiness "$active_id" 2>/dev/null || echo '{}')
        local q_blocking q_status q_files
        q_blocking=$(echo "$quality_readiness" | jq -r '.blocking // false' 2>/dev/null || echo "false")
        q_status=$(echo "$quality_readiness" | jq -r '.quality.status // ""' 2>/dev/null || echo "")
        q_files=$(echo "$quality_readiness" | jq -r '.tracked_files // 0' 2>/dev/null || echo "0")
        if [ "$q_blocking" = "true" ] && { [ "$q_status" = "missing" ] || [ "$q_status" = "stale" ]; }; then
            quality_advisory="quality scan needed: active node $active_id touches $q_files tracked file(s) but quality.db is $q_status — run 'wv quality scan .' now so 'wv done' isn't blocked at the finish line"
        fi
    fi

    # ── Concurrent-session advisory (wv-fa566a) ── a second live agent process
    # sharing this working tree can edit/delete files with no coordination; the
    # existing cross-agent guards cover .weave/, not the working tree itself.
    local concurrent_advisory="" _cs_root
    _cs_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    if [ -n "$_cs_root" ]; then
        concurrent_advisory=$(_wv_concurrent_session "$_cs_root" 2>/dev/null || echo "")
    fi

    # ── Readiness (wv-814d33) ── first in advisories: fix the framework first.
    local framework_json structural_json heavy_json readiness_advisories
    framework_json=$(_bootstrap_framework_json)
    structural_json=$(_bootstrap_structural_json)
    heavy_json=$(_bootstrap_heavy_tier_json 2>/dev/null) || heavy_json='null'
    [ -n "$heavy_json" ] || heavy_json='null'
    readiness_advisories=$(_bootstrap_readiness_advisories "$framework_json" "$structural_json" "$heavy_json" 2>/dev/null || echo '[]')

    # ── Graph memory index (wv-bff31b) ── the agnostic delivery path: every
    # harness, MCP client (weave_bootstrap passes this through) and wv_client
    # runtime reads bootstrap, while the projection files reach only the
    # harnesses that load them. The same one-line index the projections carry;
    # the full text is one recall away.
    local memory_json
    memory_json=$(_memory_recall_json 2>/dev/null | _memory_index_entries 2>/dev/null) || memory_json='[]'
    [ -n "$memory_json" ] || memory_json='[]'

    # ── Compose final JSON ──
    # Through files, not argv: the context pack and the --ready/--learnings
    # lists have no fixed size, and an argument past 128KB fails execve with
    # E2BIG before jq starts (wv-200d36; wv context had the same, f3375783).
    jq -n \
        --slurpfile status <(printf '%s' "$status_json") \
        --slurpfile active_node <(printf '%s' "$active_node") \
        --slurpfile context <(printf '%s' "$context_pack") \
        --slurpfile ready <(printf '%s' "$ready_json") \
        --slurpfile learnings <(printf '%s' "$learnings_json") \
        --arg breadcrumb "$breadcrumb" \
        --arg drift "$drift_advisory" \
        --arg quality "$quality_advisory" \
        --arg concurrent "$concurrent_advisory" \
        --slurpfile framework <(printf '%s' "$framework_json") \
        --slurpfile structural <(printf '%s' "$structural_json") \
        --slurpfile readiness_adv <(printf '%s' "$readiness_advisories") \
        --slurpfile heavy_tier <(printf '%s' "$heavy_json") \
        --slurpfile memory <(printf '%s' "$memory_json") \
        '$status[0] as $status | $active_node[0] as $active_node
        | $context[0] as $context | $ready[0] as $ready | $learnings[0] as $learnings
        | $framework[0] as $framework | $structural[0] as $structural
        | $readiness_adv[0] as $readiness_adv | $heavy_tier[0] as $heavy_tier
        | $memory[0] as $memory
        | {
            status: $status,
            readiness: {framework: $framework, structural: $structural, heavy_tier: $heavy_tier, advisories: $readiness_adv},
            active_node: $active_node,
            context: $context,
            advisories: ($readiness_adv + ([$drift, $quality, $concurrent] | map(select(. != "")))),
            ready: ($ready | map({id, text})),
            learnings: ($learnings | map(
                (if .metadata and (.metadata | type) == "string"
                 then (.metadata | fromjson? // {})
                 else (.metadata // {})
                 end) as $m |
                {
                    id,
                    text: (.text // ""),
                    learning: ($m.learning // null),
                    decision: ($m.decision // null),
                    pattern: ($m.pattern // null),
                    pitfall: ($m.pitfall // null)
                } | with_entries(select(.value != null and .value != ""))
            )),
            breadcrumb: (if $breadcrumb != "" then $breadcrumb else null end),
            memory: {
                count: ($memory | length),
                recall: "wv memory recall --agent=all --json",
                entries: ($memory | map({id, text, verified_at: .metadata.verified_at, full: (.index | not)}))
            }
        }'
}

cmd_bootstrap_agent() {
    local format="json"
    local learnings_limit=5
    local ready_limit=10

    while [ $# -gt 0 ]; do
        case "$1" in
            --json) format="json" ;;
            --learnings=*) learnings_limit="${1#--learnings=}" ;;
            --ready=*) ready_limit="${1#--ready=}" ;;
            --help|-h)
                echo "Usage: wv bootstrap-agent --json [--learnings=N] [--ready=N]"
                echo ""
                echo "Agent-safe bootstrap contract with canonical wv path, provenance, DB path,"
                echo "python command, readiness state, plus the standard bootstrap payload."
                echo ""
                echo "Options:"
                echo "  --learnings=N  Number of recent learnings (default: 5)"
                echo "  --ready=N      Number of ready nodes (default: 10)"
                return 0
                ;;
            -*) _wv_reject_arg bootstrap-agent "$1"; return 1 ;;  # wv-016983
        esac
        shift
    done

    if [ "$format" != "json" ]; then
        echo "Error: wv bootstrap-agent only supports --json output" >&2
        return 1
    fi

    local base_json agent_json
    base_json=$(cmd_bootstrap --json "--learnings=$learnings_limit" "--ready=$ready_limit") || return 1
    agent_json=$(_bootstrap_agent_info_json)

    # base_json is the bootstrap payload above, context pack included (wv-200d36).
    jq -n \
        --slurpfile base <(printf '%s' "$base_json") \
        --slurpfile agent <(printf '%s' "$agent_json") \
        '$base[0] + {agent: $agent[0]}'
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_digest — Compact one-liner health summary for session start
# ═══════════════════════════════════════════════════════════════════════════

cmd_digest() {
    local format="text"

    while [ $# -gt 0 ]; do
        case "$1" in
            --json) format="json" ;;
            --help|-h) cmd_help digest; return 0 ;;
            -*) _wv_reject_arg digest "$1"; return 1 ;;  # wv-016983
        esac
        shift
    done
    wv_require_graph || return 1

    local total active ready blocked blocked_ext done_c pending
    total=$(db_query "SELECT COUNT(*) FROM nodes;" 2>/dev/null || echo "0")
    active=$(db_query "SELECT COUNT(*) FROM nodes WHERE status='active';" 2>/dev/null || echo "0")
    ready=$(cmd_ready --count 2>/dev/null || echo "0")
    blocked=$(db_query "SELECT COUNT(*) FROM nodes WHERE status='blocked';" 2>/dev/null || echo "0")
    blocked_ext=$(db_query "SELECT COUNT(*) FROM nodes WHERE status='blocked-external';" 2>/dev/null || echo "0")
    done_c=$(db_query "SELECT COUNT(*) FROM nodes WHERE status='done';" 2>/dev/null || echo "0")
    pending=$(db_query "SELECT COUNT(*) FROM nodes WHERE status IN ('todo','pending');" 2>/dev/null || echo "0")

    local unaddressed_pitfalls
    unaddressed_pitfalls=$(db_query "
        SELECT COUNT(*) FROM nodes n
        WHERE json_extract(n.metadata, '\$.pitfall') IS NOT NULL
        AND n.status != 'done'
        AND n.id NOT IN (SELECT pitfall FROM ($(wv_pitfall_resolver_edges_sql)));
    " 2>/dev/null || echo "0")

    local stale_active
    stale_active=$(db_query "
        SELECT COUNT(*) FROM nodes
        WHERE status='active' AND datetime(updated_at) < datetime('now', '-7 days');
    " 2>/dev/null || echo "0")

    local ghost_edges
    ghost_edges=$(db_query "
        SELECT COUNT(*) FROM edges
        WHERE source NOT IN (SELECT id FROM nodes)
        OR target NOT IN (SELECT id FROM nodes);
    " 2>/dev/null || echo "0")

    # Build alerts
    local alerts=""
    [ "$unaddressed_pitfalls" -gt 0 ] && alerts="${alerts}${alerts:+, }${unaddressed_pitfalls} unaddressed pitfalls"
    [ "$stale_active" -gt 0 ] && alerts="${alerts}${alerts:+, }${stale_active} stale active (>7d)"
    [ "$ghost_edges" -gt 0 ] && alerts="${alerts}${alerts:+, }${ghost_edges} ghost edges"

    if [ "$format" = "json" ]; then
        # shellcheck disable=SC1010  # 'done' is a jq arg name, not the bash keyword
        jq -n \
            --argjson total "$total" \
            --argjson active "$active" \
            --argjson ready "$ready" \
            --argjson blocked "$blocked" \
            --argjson blocked_external "$blocked_ext" \
            --argjson done "$done_c" \
            --argjson pending "$pending" \
            --argjson unaddressed_pitfalls "$unaddressed_pitfalls" \
            --argjson stale_active "$stale_active" \
            --argjson ghost_edges "$ghost_edges" \
            --arg alerts "$alerts" \
            '{nodes: $total, active: $active, ready: $ready, blocked: $blocked,
              blocked_external: $blocked_external, done: $done, pending: $pending,
              alerts: $alerts,
              issues: {unaddressed_pitfalls: $unaddressed_pitfalls,
                       stale_active: $stale_active, ghost_edges: $ghost_edges}}'
        return
    fi

    # One-liner output
    local summary="📊 ${total} nodes: ${active} active, ${ready} ready, ${blocked} blocked"
    [ "$blocked_ext" -gt 0 ] && summary="${summary}, ${blocked_ext} blocked-external"
    summary="${summary}, ${done_c} done"
    if [ -n "$alerts" ]; then
        summary="${summary} ⚠ ${alerts}"
    fi
    echo "$summary"
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_overview — Session start overview (status + health + ready + breadcrumb)
# ═══════════════════════════════════════════════════════════════════════════

cmd_overview() {
    local format="text"
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) format="json" ;;
            --help|-h) cmd_help overview; return 0 ;;
            -*) _wv_reject_arg overview "$1"; return 1 ;;  # wv-016983
        esac
        shift
    done

    wv_require_graph || return 1

    # Status counts
    local total active ready_count blocked done_c
    total=$(db_query "SELECT COUNT(*) FROM nodes;")
    active=$(db_query "SELECT COUNT(*) FROM nodes WHERE status='active';")
    blocked=$(db_query "SELECT COUNT(*) FROM nodes WHERE status='blocked';")
    done_c=$(db_query "SELECT COUNT(*) FROM nodes WHERE status='done';")
    ready_count=$(cmd_ready --count 2>/dev/null || echo "0")

    # Health indicators
    local ghost_edges orphans total_edges
    ghost_edges=$(db_query "SELECT COUNT(*) FROM edges
        WHERE source NOT IN (SELECT id FROM nodes)
        OR target NOT IN (SELECT id FROM nodes);")
    orphans=$(db_query "SELECT COUNT(*) FROM nodes
        WHERE id NOT IN (SELECT source FROM edges)
        AND id NOT IN (SELECT target FROM edges);")
    total_edges=$(db_query "SELECT COUNT(*) FROM edges;")

    # Trail — stored as markdown at $WEAVE_DIR/trails.md (legacy breadcrumbs.md fallback)
    local breadcrumb=""
    local bc_file="${WEAVE_DIR}/trails.md"
    [ -f "$bc_file" ] || bc_file="${WEAVE_DIR}/breadcrumbs.md"
    if [ -f "$bc_file" ]; then
        breadcrumb=$(grep -v '^#' "$bc_file" | grep -v '^$' | head -1 | sed 's/^[[:space:]]*//')
    fi

    # Ready list (top 5) — intermediate variable to avoid SIGPIPE
    local raw_ready
    raw_ready=$(cmd_ready --json 2>/dev/null || echo "[]")
    local ready_list
    ready_list=$(echo "$raw_ready" | jq -c '[.[:5][] | {id, text}]' 2>/dev/null || echo "[]")

    if [ "$format" = "json" ]; then
        printf '{"status":{"total":%d,"active":%d,"ready":%d,"blocked":%d,"done":%d},' \
            "$total" "$active" "$ready_count" "$blocked" "$done_c"
        printf '"health":{"ghost_edges":%d,"orphans":%d,"total_edges":%d},' \
            "$ghost_edges" "$orphans" "$total_edges"
        printf '"breadcrumb":%s,' "$(echo "$breadcrumb" | jq -Rs '.')"
        printf '"ready":%s}\n' "$ready_list"
    else
        echo "Weave Overview"
        echo "  Nodes: $total ($active active, $ready_count ready, $blocked blocked, $done_c done)"
        echo "  Edges: $total_edges (${ghost_edges} ghost)"
        [ "$orphans" -gt 0 ] && echo "  ⚠ $orphans orphan nodes"
        [ -n "$breadcrumb" ] && echo "  Trail: $breadcrumb"
        if [ "$ready_count" -gt 0 ]; then
            echo ""
            echo "  Ready work:"
            echo "$ready_list" | jq -r '.[] | "    \(.id): \(.text)"' 2>/dev/null
        fi
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# _preflight_policy_readiness — Evaluate whether a node can satisfy policy
# gates if it currently has attributed files.
#
# Nodes with no tracked files are not yet policy-sensitive, so preflight
# should expose that state without blocking. Once node_files exist, quality
# scan prerequisites become blocking unless explicitly bypassed.
_preflight_policy_readiness() {
    local id="$1"
    local tracked_files
    tracked_files=$(db_query "SELECT COUNT(*) FROM node_files WHERE node_id='$(sql_escape "$id")';" 2>/dev/null || echo "")

    if [ -z "$tracked_files" ]; then
        jq -cn \
            --arg detail "node_files attribution data is unavailable" \
            --arg hint "Run wv init or repair the graph DB before relying on policy readiness." \
            '{
                policy_sensitive: false,
                ready: false,
                blocking: true,
                status: "unavailable",
                detail: $detail,
                hint: $hint,
                tracked_files: 0,
                attribution: {
                    ready: false,
                    status: "missing",
                    detail: "node_files table or attribution data is unavailable"
                },
                quality: {
                    ready: false,
                    status: "unknown",
                    detail: "Quality prerequisites could not be evaluated because attribution data is unavailable."
                }
            }'
        return 0
    fi

    if [ "$tracked_files" = "0" ]; then
        jq -cn \
            --arg detail "No tracked files are attributed to this node yet, so policy gating is not active." \
            --arg hint "Policy readiness will become blocking after touched files are written to node_files." \
            '{
                policy_sensitive: false,
                ready: true,
                blocking: false,
                status: "not_applicable",
                detail: $detail,
                hint: $hint,
                tracked_files: 0,
                attribution: {
                    ready: false,
                    status: "pending",
                    detail: "No tracked files attributed to this node."
                },
                quality: {
                    ready: true,
                    status: "not_applicable",
                    detail: "Quality prerequisites are only required once tracked files exist."
                }
            }'
        return 0
    fi

    if [ "${WV_REQUIRE_QUALITY:-1}" = "0" ]; then
        jq -cn \
            --argjson tracked_files "$tracked_files" \
            --arg detail "Policy-sensitive completion is currently bypassing quality prerequisites because WV_REQUIRE_QUALITY=0." \
            --arg hint "Unset WV_REQUIRE_QUALITY=0 to enforce quality-backed policy readiness." \
            '{
                policy_sensitive: true,
                ready: true,
                blocking: false,
                status: "bypassed",
                detail: $detail,
                hint: $hint,
                tracked_files: $tracked_files,
                attribution: {
                    ready: true,
                    status: "ready",
                    detail: "Tracked files are attributed to this node."
                },
                quality: {
                    ready: true,
                    status: "bypassed",
                    detail: "Quality prerequisites are bypassed by WV_REQUIRE_QUALITY=0."
                }
            }'
        return 0
    fi

    local quality_db="$WV_HOT_ZONE/quality.db"
    if [ ! -f "$quality_db" ]; then
        jq -cn \
            --argjson tracked_files "$tracked_files" \
            --arg quality_db "$quality_db" \
            --arg detail "Tracked files make this node policy-sensitive, but quality.db is missing." \
            --arg hint 'Run `wv quality scan .` before closing nodes that touch tracked files. Example: `wv quality scan . --json`.' \
            '{
                policy_sensitive: true,
                ready: false,
                blocking: true,
                status: "blocked",
                detail: $detail,
                hint: $hint,
                tracked_files: $tracked_files,
                attribution: {
                    ready: true,
                    status: "ready",
                    detail: "Tracked files are attributed to this node."
                },
                quality: {
                    ready: false,
                    status: "missing",
                    detail: "quality.db not found",
                    path: $quality_db
                }
            }'
        return 0
    fi

    local latest_scan
    latest_scan=$(sqlite3 -batch -cmd ".timeout 3000" "$quality_db" \
        "SELECT id FROM scan_meta ORDER BY id DESC LIMIT 1;" 2>/dev/null || echo "")
    if [ -z "$latest_scan" ]; then
        jq -cn \
            --argjson tracked_files "$tracked_files" \
            --arg quality_db "$quality_db" \
            --arg detail "Tracked files make this node policy-sensitive, but quality.db has no scan data." \
            --arg hint 'Run `wv quality scan .` before closing nodes that touch tracked files. Example: `wv quality scan . --json`.' \
            '{
                policy_sensitive: true,
                ready: false,
                blocking: true,
                status: "blocked",
                detail: $detail,
                hint: $hint,
                tracked_files: $tracked_files,
                attribution: {
                    ready: true,
                    status: "ready",
                    detail: "Tracked files are attributed to this node."
                },
                quality: {
                    ready: false,
                    status: "stale",
                    detail: "quality.db has no scan_meta rows",
                    path: $quality_db
                }
            }'
        return 0
    fi

    jq -cn \
        --argjson tracked_files "$tracked_files" \
        --arg quality_db "$quality_db" \
        --arg latest_scan "$latest_scan" \
        --arg detail "Policy prerequisites are satisfied for this node's tracked files." \
        --arg hint "Policy-sensitive completion can proceed with the current attribution and quality scan data." \
        '{
            policy_sensitive: true,
            ready: true,
            blocking: false,
            status: "ready",
            detail: $detail,
            hint: $hint,
            tracked_files: $tracked_files,
            attribution: {
                ready: true,
                status: "ready",
                detail: "Tracked files are attributed to this node."
            },
            quality: {
                ready: true,
                status: "ready",
                detail: "quality.db has scan data for policy-backed completion.",
                path: $quality_db,
                latest_scan: $latest_scan
            }
        }'
}

# cmd_preflight — Pre-action checks as JSON for MCP clients
# ═══════════════════════════════════════════════════════════════════════════

cmd_preflight() {
    local id="${1:-}" _pf_arg
    case "$id" in --help|-h) cmd_help preflight; return 0 ;; esac
    # It reads one id and nothing else; the rest was dropped (wv-016983).
    shift || true
    for _pf_arg in "$@"; do
        _wv_reject_arg preflight "$_pf_arg"
        return 1
    done

    if [ -z "$id" ]; then
        echo '{"error":"node ID required"}' >&2
        return 1
    fi

    validate_id "$id" || { echo '{"error":"invalid ID format"}'; return 1; }

    # Check node existence
    local exists
    exists=$(db_query "SELECT COUNT(*) FROM nodes WHERE id='$id';")
    if [ "$exists" = "0" ]; then
        cat <<EOF
{"node_exists":false,"node_active":false,"has_done_criteria":false,"has_blockers":false,"contradictions":[],"context_load":"NONE","warnings":["Node $id not found"],"policy_readiness":{"policy_sensitive":false,"ready":false,"blocking":false,"status":"unavailable","detail":"Node $id not found","hint":"Claim or create the node before evaluating policy readiness.","tracked_files":0,"attribution":{"ready":false,"status":"missing","detail":"Node not found"},"quality":{"ready":false,"status":"unknown","detail":"Node not found"}}}
EOF
        return 0
    fi

    # Gather node info
    local status text metadata
    status=$(db_query "SELECT status FROM nodes WHERE id='$id';")
    text=$(db_query "SELECT text FROM nodes WHERE id='$id';")
    metadata=$(db_query "SELECT COALESCE(json(metadata), '{}') FROM nodes WHERE id='$id';" 2>/dev/null || echo "{}")
    [[ "$metadata" != "{"* ]] && metadata="{}"

    local node_active=false
    [ "$status" = "active" ] && node_active=true

    # Check done_criteria
    local has_done_criteria=false
    local dc
    dc=$(echo "$metadata" | jq -r '.done_criteria // empty' 2>/dev/null)
    [ -n "$dc" ] && has_done_criteria=true

    # Check blockers
    local has_blockers=false
    local blocker_count
    blocker_count=$(db_query "
        SELECT COUNT(*) FROM edges e
        JOIN nodes blocker ON e.source = blocker.id
        WHERE e.target = '$id'
        AND e.type = 'blocks'
        AND blocker.status != 'done';
    " 2>/dev/null || echo "0")
    [ "$blocker_count" -gt 0 ] && has_blockers=true

    # Check contradictions (active node blocked, done node with open blockers)
    local contradictions="[]"
    local contra_items=""
    if [ "$status" = "active" ] && [ "$has_blockers" = "true" ]; then
        contra_items="\"Active node has unresolved blockers\""
    fi
    if [ "$status" = "done" ] && [ "$has_blockers" = "true" ]; then
        [ -n "$contra_items" ] && contra_items="${contra_items},"
        contra_items="${contra_items}\"Done node still has open blockers\""
    fi
    [ -n "$contra_items" ] && contradictions="[$contra_items]"

    # Context load estimate (based on edge count + descendants)
    local edge_count
    edge_count=$(db_query "SELECT COUNT(*) FROM edges WHERE source='$id' OR target='$id';" 2>/dev/null || echo "0")
    local context_load="LOW"
    [ "$edge_count" -gt 3 ] && context_load="MEDIUM"
    [ "$edge_count" -gt 8 ] && context_load="HIGH"

    # Collect warnings
    local warnings="[]"
    local warn_items=""
    [ "$has_done_criteria" = "false" ] && warn_items="\"No done_criteria defined\""

    local has_learning
    has_learning=$(echo "$metadata" | jq -r 'if (.decision // .pattern // .pitfall // .learning) then "yes" else "no" end' 2>/dev/null || echo "no")

    # Orphan check. wv-cccf70: a node explicitly created with --standalone
    # already records metadata.standalone=true -- that IS the declaration
    # that it's meant to have no edges (--parent required when active
    # epics exist routes here on purpose); warning about the exact state
    # the flag creates trains the reader to ignore validation hints.
    local total_edges is_standalone
    total_edges=$(db_query "SELECT COUNT(*) FROM edges WHERE source='$id' OR target='$id';" 2>/dev/null || echo "0")
    is_standalone=$(echo "$metadata" | jq -r '.standalone // false' 2>/dev/null || echo "false")
    if [ "$total_edges" = "0" ] && [ "$is_standalone" != "true" ]; then
        [ -n "$warn_items" ] && warn_items="${warn_items},"
        warn_items="${warn_items}\"Orphan node — no edges\""
    fi

    # Status anomaly
    if [ "$status" = "blocked" ] && [ "$has_blockers" = "false" ]; then
        [ -n "$warn_items" ] && warn_items="${warn_items},"
        warn_items="${warn_items}\"Status is blocked but no active blockers found\""
    fi

    [ -n "$warn_items" ] && warnings="[$warn_items]"

    local policy_readiness
    policy_readiness=$(_preflight_policy_readiness "$id")

    # Output JSON
    cat <<EOF
{"node_exists":true,"node_active":$node_active,"has_done_criteria":$has_done_criteria,"has_blockers":$has_blockers,"contradictions":$contradictions,"context_load":"$context_load","warnings":$warnings,"policy_readiness":$policy_readiness}
EOF
}

# ═══════════════════════════════════════════════════════════════════════════
# Session activity tracking
# ═══════════════════════════════════════════════════════════════════════════

cmd_session_summary() {
    local format="text"
    while [ $# -gt 0 ]; do
        case "$1" in --json) format="json" ;; esac
        shift
    done

    local snapshot="$WV_HOT_ZONE/.session_snapshot"
    if [ ! -f "$snapshot" ]; then
        echo "No session snapshot found. Run 'wv load' at session start."
        return 0
    fi

    local start_ts start_total start_done start_learnings
    IFS=$'\t' read -r start_ts start_total start_done start_learnings < "$snapshot"

    local now_ts now_total now_done now_learnings
    now_ts=$(date -u +%s)
    # Exclude internal session_history singleton; matches _save_session_snapshot.
    now_total=$(db_query "SELECT COUNT(*) FROM nodes WHERE $(wv_kind_sql) IS NOT 'session_history';" 2>/dev/null || echo 0)
    now_done=$(db_query "SELECT COUNT(*) FROM nodes WHERE status='done' AND $(wv_kind_sql) IS NOT 'session_history';" 2>/dev/null || echo 0)
    now_learnings=$(db_query "
        SELECT COUNT(*) FROM nodes
        WHERE (json_extract(metadata, '\$.learning') IS NOT NULL
           OR json_extract(metadata, '\$.decision') IS NOT NULL
           OR json_extract(metadata, '\$.pattern') IS NOT NULL
           OR json_extract(metadata, '\$.pitfall') IS NOT NULL)
          AND $(wv_kind_sql) IS NOT 'session_history';
    " 2>/dev/null || echo 0)

    local elapsed=$(( now_ts - start_ts ))
    local hours=$(( elapsed / 3600 ))
    local mins=$(( (elapsed % 3600) / 60 ))
    local created=$(( now_total - start_total ))
    local completed=$(( now_done - start_done ))
    local new_learnings=$(( now_learnings - start_learnings ))

    # Format duration
    local duration
    if [ "$hours" -gt 0 ]; then
        duration="${hours}h ${mins}m"
    else
        duration="${mins}m"
    fi

    # Hygiene score (C1): four 25pt components covering edit-discipline,
    # decomposition-discipline, learning-discipline, and call-discipline.
    # Each component degrades gracefully when its denominator is zero
    # (no penalty for sessions without that activity).
    _hygiene_score "$start_ts" "$now_ts"

    # Append score to history graph node so trend can be queried cross-session.
    _hygiene_record_history "$now_ts" "$_h_total" "$_h_edit" "$_h_criteria" "$_h_learning" "$_h_budget"

    if [ "$format" = "json" ]; then
        jq -n \
            --arg duration "$duration" \
            --argjson elapsed "$elapsed" \
            --argjson created "$created" \
            --argjson completed "$completed" \
            --argjson learnings "$new_learnings" \
            --argjson score "$_h_total" \
            --argjson edit "$_h_edit" \
            --argjson criteria "$_h_criteria" \
            --argjson learning_disc "$_h_learning" \
            --argjson budget "$_h_budget" \
            --argjson edits_total "$_h_edit_total" \
            --argjson edits_with_active "$_h_edit_with" \
            --argjson wv_calls "$_h_wv_calls" \
            '{
                duration: $duration,
                elapsed_seconds: $elapsed,
                nodes_created: $created,
                nodes_completed: $completed,
                learnings_captured: $learnings,
                hygiene: {
                    score: $score,
                    edit_discipline: $edit,
                    criteria_discipline: $criteria,
                    learning_discipline: $learning_disc,
                    call_discipline: $budget,
                    edits_total: $edits_total,
                    edits_with_active: $edits_with_active,
                    wv_calls: $wv_calls
                }
            }'
    else
        echo -e "Session: ${CYAN}${duration}${NC} | Nodes: ${GREEN}+${created}${NC} created, ${GREEN}${completed}${NC} completed | Learnings: ${GREEN}${new_learnings}${NC} captured"
        local _h_color="$GREEN"
        [ "$_h_total" -lt 60 ] && _h_color="$YELLOW"
        [ "$_h_total" -lt 30 ] && _h_color="$RED"
        echo -e "Hygiene:  ${_h_color}${_h_total}/100${NC}  edit:${_h_edit}/25  criteria:${_h_criteria}/25  learning:${_h_learning}/25  calls:${_h_budget}/25"
    fi
}

# Compute the four 25pt hygiene components plus the total. Returns via the
# global `_h_*` variables (decomposition-pattern documented in MEMORY.md
# under "Bash Decomposition Patterns").
_hygiene_score() {
    local start_ts="$1" now_ts="$2"
    local start_iso
    start_iso=$(date -u -d "@$start_ts" +"%Y-%m-%d %H:%M:%S" 2>/dev/null \
        || date -u -r "$start_ts" +"%Y-%m-%d %H:%M:%S" 2>/dev/null \
        || echo "1970-01-01 00:00:00")
    start_iso=$(sql_escape "$start_iso")

    # Component 1: edit discipline = % Edit/Write attempts that had an active node.
    local edits_file="$WV_HOT_ZONE/session-edits.json"
    _h_edit_total=0
    _h_edit_with=0
    if [ -f "$edits_file" ]; then
        _h_edit_total=$(jq -r '.total // 0' "$edits_file" 2>/dev/null || echo 0)
        _h_edit_with=$(jq -r '.with_active // 0' "$edits_file" 2>/dev/null || echo 0)
    fi
    if [ "$_h_edit_total" -gt 0 ]; then
        _h_edit=$(( 25 * _h_edit_with / _h_edit_total ))
    else
        _h_edit=25
    fi

    # Component 2: decomp discipline = % nodes created this session with done_criteria set.
    # Exclude internal session_history singleton and finding nodes (audit records, not work items).
    local created_session with_criteria
    created_session=$(db_query "SELECT COUNT(*) FROM nodes WHERE created_at >= '$start_iso' AND $(wv_kind_sql) IS NOT 'session_history' AND $(wv_kind_sql) IS NOT 'finding';" 2>/dev/null || echo 0)
    with_criteria=$(db_query "SELECT COUNT(*) FROM nodes WHERE created_at >= '$start_iso' AND json_extract(metadata, '\$.done_criteria') IS NOT NULL AND $(wv_kind_sql) IS NOT 'session_history' AND $(wv_kind_sql) IS NOT 'finding';" 2>/dev/null || echo 0)
    : "${created_session:=0}"
    : "${with_criteria:=0}"
    if [ "$created_session" -gt 0 ]; then
        _h_criteria=$(( 25 * with_criteria / created_session ))
    else
        _h_criteria=25
    fi

    # Component 3: learning discipline = % nodes closed this session with structured learning.
    # Exclude internal session_history singleton.
    local closed_session with_learning
    closed_session=$(db_query "SELECT COUNT(*) FROM nodes WHERE status='done' AND updated_at >= '$start_iso' AND $(wv_kind_sql) IS NOT 'session_history';" 2>/dev/null || echo 0)
    with_learning=$(db_query "SELECT COUNT(*) FROM nodes WHERE status='done' AND updated_at >= '$start_iso' AND (json_extract(metadata, '\$.decision') IS NOT NULL OR json_extract(metadata, '\$.pattern') IS NOT NULL OR json_extract(metadata, '\$.pitfall') IS NOT NULL OR json_extract(metadata, '\$.learning') IS NOT NULL) AND $(wv_kind_sql) IS NOT 'session_history';" 2>/dev/null || echo 0)
    : "${closed_session:=0}"
    : "${with_learning:=0}"
    if [ "$closed_session" -gt 0 ]; then
        _h_learning=$(( 25 * with_learning / closed_session ))
    else
        _h_learning=25
    fi

    # Component 4: call discipline = inverse of broad-call count from budget-tally.
    # Threshold matches WV_BUDGET_THRESHOLD default (20). Each call beyond it
    # costs 1 point; floored at 0 for runaway sessions.
    local budget_file
    budget_file=$(wv_session_budget_file "$WV_HOT_ZONE")
    _h_wv_calls=0
    [ -f "$budget_file" ] && _h_wv_calls=$(jq -r '.calls // 0' "$budget_file" 2>/dev/null || echo 0)
    local threshold="${WV_BUDGET_THRESHOLD:-20}"
    if [ "$_h_wv_calls" -le "$threshold" ]; then
        _h_budget=25
    else
        _h_budget=$(( 25 - (_h_wv_calls - threshold) ))
        [ "$_h_budget" -lt 0 ] && _h_budget=0
    fi

    _h_total=$(( _h_edit + _h_criteria + _h_learning + _h_budget ))
}

# Append a score record to a singleton session_history graph node so trend
# data syncs across machines via state.sql. Caps history at 20 entries.
_hygiene_record_history() {
    local ts="$1" total="$2" edit="$3" criteria="$4" learning="$5" budget="$6"
    local hist_id
    hist_id=$(db_query "SELECT id FROM nodes WHERE $(wv_kind_sql) = 'session_history' LIMIT 1;" 2>/dev/null)
    if [ -z "$hist_id" ]; then
        hist_id="wv-$(printf '%06x' $((RANDOM * RANDOM)) | head -c6)"
        local seed_meta
        seed_meta=$(jq -n \
            --argjson ts "$ts" \
            --argjson total "$total" \
            --argjson edit "$edit" \
            --argjson criteria "$criteria" \
            --argjson learning "$learning" \
            --argjson budget "$budget" \
            '{type:"session_history", node_kind:"session_history", history:[{ts:$ts, score:$total, edit:$edit, criteria:$criteria, learning:$learning, budget:$budget}]}')
        seed_meta_esc=$(sql_escape "$seed_meta")
        db_query "INSERT INTO nodes (id, text, status, metadata, created_at, updated_at) VALUES ('$hist_id', 'session-hygiene-history', 'done', '$seed_meta_esc', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP);" 2>/dev/null || true
        return 0
    fi
    local cur_meta new_meta new_meta_esc
    cur_meta=$(db_query "SELECT COALESCE(metadata, '{}') FROM nodes WHERE id='$hist_id';" 2>/dev/null)
    [ -z "$cur_meta" ] && cur_meta='{}'
    new_meta=$(echo "$cur_meta" | jq \
        --argjson ts "$ts" \
        --argjson total "$total" \
        --argjson edit "$edit" \
        --argjson criteria "$criteria" \
        --argjson learning "$learning" \
        --argjson budget "$budget" \
        '.history = ((.history // []) + [{ts:$ts, score:$total, edit:$edit, criteria:$criteria, learning:$learning, budget:$budget}] | .[-20:])' 2>/dev/null || echo "$cur_meta")
    new_meta_esc=$(sql_escape "$new_meta")
    db_query "UPDATE nodes SET metadata='$new_meta_esc', updated_at=CURRENT_TIMESTAMP WHERE id='$hist_id';" 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_doctor — Installation health check
# ═══════════════════════════════════════════════════════════════════════════

# Shared state for _doctor_record (avoids nested function dynamic scoping)
_dr_pass=0 _dr_fail=0 _dr_warn=0 _dr_total=0 _dr_results="" _dr_format="text"

# Count durable Codex memory-pipeline rows scoped to THIS repo. Codex's
# memories_*.sqlite stage1_outputs is the durable-memory analog to Claude's
# memory/*.md (thread/state/rollout DBs are session evidence, not durable
# memory, and are deliberately excluded — same scope as the Claude *.md-only
# check). Conservative: only count rows attributable via a cwd column; schemas
# without repo identity are skipped rather than guessed at.
_doctor_codex_memory_rows() {
    local repo_root="$1"
    local codex_dir="$HOME/.codex" db cols n total=0
    [ -d "$codex_dir" ] || { echo 0; return 0; }
    while IFS= read -r db; do
        [ -s "$db" ] || continue
        sqlite3 "$db" "SELECT name FROM sqlite_master WHERE type='table' AND name='stage1_outputs';" 2>/dev/null | grep -qx stage1_outputs || continue
        cols=$(sqlite3 "$db" "PRAGMA table_info('stage1_outputs');" 2>/dev/null | awk -F'|' '{print $2}' | tr '\n' ' ')
        case " $cols " in
            *" cwd "*)
                n=$(sqlite3 "$db" "SELECT COUNT(*) FROM stage1_outputs WHERE cwd='$(sql_escape "$repo_root")';" 2>/dev/null || echo 0)
                ;;
            *)
                n=0
                ;;
        esac
        [ -n "$n" ] && total=$((total + n))
    done < <(find "$codex_dir" -maxdepth 1 -type f -name "memories_*.sqlite" -print 2>/dev/null | sort)
    echo "$total"
}

# _doctor_memory_kept <harness> <label> — the store is kept outside the graph
# by a recorded choice; appends it to the caller's choices (wv-27131a).
_doctor_memory_kept() {
    local why
    [ -n "${WEAVE_DIR:-}" ] || return 1
    why=$(wv_memory_outside_graph "$WEAVE_DIR" "$1" 2>/dev/null) || return 1
    choices+=("$2 kept outside the graph by choice (.weave/policy.conf): $why")
}

_doctor_memory_authority() {
    # Duplicate-authoritative-memory risk (PROPOSAL-wv-agent-memory-substrate S5,
    # generalized in F1/wv-4c1efd): durable harness memory for THIS repo that is
    # not represented in the graph is a dual-authority leak — the graph is the
    # authority, harness files/DBs are evidence/projections. Report-only.
    #
    # Per-harness durable-memory analog (sessions are excluded as evidence):
    #   Claude  : ~/.claude/projects/<slug>/memory/*.md  (content-hash match)
    #   Codex   : ~/.codex/memories_*.sqlite stage1_outputs rows for this repo
    #   Copilot : none — VS Code workspace storage is chat/session + index-cache
    #             evidence (proposal §VS Code Copilot), not a durable memory store.
    local root slug memdir
    root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    [ -z "$root" ] && return 0
    if [ ! -f "${WV_DB:-}" ]; then
        _doctor_record "memory authority" "pass" "no graph db for this repo"
        return 0
    fi

    local any_store=0
    local warnings=() problems=() choices=()

    # A repository may keep a harness's memory outside the graph by choice,
    # recorded with a reason in .weave/policy.conf [memory] (wv-27131a, ruling
    # D3 on wv-80fa17). The advisory then reports the choice, not an import.
    local kept_names="" policy_text policy_rc=0 name
    if [ -n "${WEAVE_DIR:-}" ]; then
        policy_text=$(wv_config_read "$WEAVE_DIR/policy.conf") || policy_rc=$?
        if [ "$policy_rc" -eq 0 ]; then
            kept_names=$(wv_policy_value "$policy_text" memory outside_graph)
            for name in ${kept_names//,/ }; do
                case "$name" in
                    claude|codex) ;;
                    *) problems+=(".weave/policy.conf [memory] outside_graph names '$name'; known: claude, codex") ;;
                esac
            done
            if [ -n "$kept_names" ] && [ -z "$(wv_policy_value "$policy_text" memory reason)" ]; then
                problems+=(".weave/policy.conf [memory] outside_graph = $kept_names records no choice without a reason: add reason = ...")
            fi
        elif [ "$policy_rc" -ne 2 ]; then
            problems+=(".weave/policy.conf cannot be read")
        fi
    fi

    # Claude: memory/*.md vs graph source_hash (precise per-file match).
    slug=$(printf '%s' "$root" | tr '/' '-')
    memdir="$HOME/.claude/projects/$slug/memory"
    if [ -d "$memdir" ]; then
        local c_total=0 c_unimported=0 f h hit
        for f in "$memdir"/*.md; do
            [ -f "$f" ] || continue
            c_total=$((c_total + 1))
            any_store=1
            h=$(sha256sum "$f" 2>/dev/null | awk '{print $1}')
            [ -z "$h" ] && continue
            hit=$(db_query "SELECT 1 FROM nodes WHERE json_extract(metadata,'\$.source_hash')='$h' LIMIT 1;" 2>/dev/null || true)
            [ -z "$hit" ] && c_unimported=$((c_unimported + 1))
        done
        if [ "$c_unimported" -gt 0 ] && ! _doctor_memory_kept claude "Claude memory"; then
            warnings+=("$c_unimported/$c_total Claude memory file(s) — import: wv memory import --source=claude --path=$memdir, or record keeping it outside the graph in .weave/policy.conf [memory] with a reason")
        fi
    fi

    # Codex: durable memory-pipeline rows for this repo. A matching graph
    # candidate imported from memory_db evidence represents the row set for this
    # repo; otherwise report the import command that closes the authority gap.
    local cdx_rows cdx_rep
    cdx_rows=$(_doctor_codex_memory_rows "$root")
    if [ "${cdx_rows:-0}" -gt 0 ]; then
        any_store=1
        cdx_rep=$(db_query "SELECT COUNT(*) FROM nodes WHERE json_extract(metadata,'\$.source_agent')='codex' AND json_extract(metadata,'\$.source_kind')='memory_db' AND json_extract(metadata,'\$.repo_root')='$(sql_escape "$root")';" 2>/dev/null || echo 0)
        [ -z "$cdx_rep" ] && cdx_rep=0
        if [ "$cdx_rep" -lt "$cdx_rows" ] && ! _doctor_memory_kept codex "Codex memory"; then
            warnings+=("$((cdx_rows - cdx_rep))/$cdx_rows Codex memory-pipeline row(s) — import: wv memory import --source=codex, or record keeping it outside the graph in .weave/policy.conf [memory] with a reason")
        fi
    fi

    local msg=""
    [ "${#problems[@]}" -eq 0 ] || msg=$(printf '%s; ' "${problems[@]}")
    [ "${#warnings[@]}" -eq 0 ] || msg+="dual authority risk: $(printf '%s; ' "${warnings[@]}")"
    msg="${msg%; }"
    if [ -n "$msg" ]; then
        _doctor_record "memory authority" "warn" "$msg"
    elif [ "$any_store" -eq 0 ]; then
        _doctor_record "memory authority" "pass" "no harness memory store for this repo"
    elif [ "${#choices[@]}" -gt 0 ]; then
        msg=$(printf '%s; ' "${choices[@]}")
        _doctor_record "memory authority" "pass" "${msg%; }"
    else
        _doctor_record "memory authority" "pass" "harness memory all represented in graph"
    fi
}

# _doctor_commit_refs — orphaned commit-provenance advisory (wv-fc4ac2).
#
# `wv done` records the SHAs carrying a node's Weave-ID; an amend, reset,
# rebase or gc later strips them out from under the graph and nothing notices
# (wv-55d2de). This is the surface that makes the count visible without being
# asked for. Advisory only: existing orphans are a cleanup job (wv-3ce8d9),
# not an installation fault, and --repair deliberately does NOT prune them —
# discarding recorded provenance is a deliberate act, not a repair.
# _doctor_install_provenance — can this install say which fixes it has?
#
# VERSION cannot answer that. Fixes land continuously between bumps, so an
# install can be many commits behind while reporting an identical version
# string, and nothing on the consumer side reveals it. install.sh records the
# source commit; this reports it, and compares against the source checkout when
# that is still reachable.
_doctor_install_provenance() {
    # Honour WV_LIB_DIR: hardcoding the default path checked a DIFFERENT install
    # than the one running whenever the library lives elsewhere, so the report
    # described something the caller was not using.
    # Honour WV_LIB_DIR for a relocated INSTALL, but not when it points at the
    # source checkout: running from source, WV_LIB_DIR is scripts/, and reading
    # provenance from there describes the working tree rather than any installed
    # copy. Hardcoding the default was wrong for a relocated install; using it
    # blindly is wrong in dev mode. Distinguish the two.
    # Resolution lives in wv_install_provenance_file (wv-config.sh) so doctor and
    # wv --version can never describe different installs; the reasoning above is
    # kept there with it.
    local prov
    prov=$(wv_install_provenance_file 2>/dev/null || true)
    if [ -z "$prov" ] || [ ! -f "$prov" ]; then
        _doctor_record "install provenance" "warn" \
            "not recorded — re-run ./install.sh so this install can report which commit it came from"
        return 0
    fi
    local desc icommit ipath
    desc=$(grep -m1 '^describe=' "$prov" 2>/dev/null | cut -d= -f2-)
    icommit=$(grep -m1 '^commit=' "$prov" 2>/dev/null | cut -d= -f2-)
    ipath=$(grep -m1 '^source_path=' "$prov" 2>/dev/null | cut -d= -f2-)

    # Compare against the source it came from, when that is still present.
    if [ -n "$ipath" ] && [ -d "$ipath/.git" ] && [ -n "$icommit" ]; then
        local head behind
        head=$(git -C "$ipath" rev-parse HEAD 2>/dev/null || echo "")
        if [ -n "$head" ] && [ "$head" != "$icommit" ]; then
            behind=$(git -C "$ipath" rev-list --count "$icommit..$head" 2>/dev/null || echo "?")
            _doctor_record "install provenance" "warn" \
                "installed at ${desc:-unknown}; source is $behind commit(s) ahead — re-run ./install.sh"
            return 0
        fi
    fi
    # A dirty install is not a healthy one: it cannot be reproduced from any
    # commit, so reporting it as a clean pass hid exactly the case where the
    # running code does not correspond to anything in the history.
    local idirty
    idirty=$(grep -m1 '^dirty=' "$prov" 2>/dev/null | cut -d= -f2-)
    if [ "$idirty" = "true" ]; then
        _doctor_record "install provenance" "warn" \
            "${desc:-unknown} — installed from a DIRTY tree, so it matches no commit; reinstall from a clean checkout to make it reproducible"
        return 0
    fi
    _doctor_record "install provenance" "pass" "${desc:-unknown}"
}

_doctor_commit_refs() {
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        _doctor_record "commit refs" "pass" "not a git repository — nothing to verify against"
        return 0
    fi
    if ! declare -f cmd_commit_refs >/dev/null 2>&1; then
        _doctor_record "commit refs" "warn" "wv commit-refs unavailable in this install"
        return 0
    fi

    local summary orphaned nodes total
    summary=$(cmd_commit_refs --json 2>/dev/null || echo "")
    if [ -z "$summary" ]; then
        _doctor_record "commit refs" "warn" "sweep failed — run: wv commit-refs"
        return 0
    fi
    orphaned=$(printf '%s' "$summary" | jq -r '.totals.orphaned // 0' 2>/dev/null || echo 0)
    nodes=$(printf '%s' "$summary" | jq -r '.totals.orphaned_nodes // 0' 2>/dev/null || echo 0)
    total=$(printf '%s' "$summary" | jq -r '.totals.refs // 0' 2>/dev/null || echo 0)
    local ckpt reg unk
    ckpt=$(printf '%s' "$summary" | jq -r '.totals.orphaned_checkpoint // 0' 2>/dev/null || echo 0)
    reg=$(printf '%s' "$summary" | jq -r '.totals.orphaned_regular // 0' 2>/dev/null || echo 0)
    unk=$(printf '%s' "$summary" | jq -r '.totals.orphaned_unknown // 0' 2>/dev/null || echo 0)

    # Checkpoint churn is the DESIGNED steady state: auto-checkpoint commits are
    # superseded constantly, so their refs go unreachable as a matter of course.
    # Reporting that identically to a regular ref going unreachable made the
    # advisory a permanent warning, and a permanent warning is where a real
    # provenance loss hides. Only regular or unclassifiable orphans warn.
    if [ "${reg:-0}" -gt 0 ] 2>/dev/null || [ "${unk:-0}" -gt 0 ] 2>/dev/null; then
        # Why they are orphaned comes before the prune it offers (wv-6d53ec).
        local why
        why=$(printf '%s' "$summary" | jq -r '
            [ .refs[]? | select((.class == "unreachable" or .class == "missing") and .kind != "checkpoint")
              | (.reason // "unclassified") ]
            | group_by(.)
            | map("\(length) \({not_in_clone: "not in this clone", not_a_commit: "not a commit"}[.[0]] // .[0])")
            | join(", ")' 2>/dev/null || echo "")
        _doctor_record "commit refs" "warn" \
            "$((reg + unk)) non-checkpoint ref(s) orphaned of $total across $nodes node(s) (plus $ckpt expected checkpoint)${why:+: $why} — inspect: wv commit-refs; remove: wv commit-refs --prune"
    elif [ "${orphaned:-0}" -gt 0 ] 2>/dev/null; then
        _doctor_record "commit refs" "pass" \
            "$total recorded ref(s); $ckpt orphaned checkpoint ref(s) — expected churn, clear with: wv commit-refs --prune"
    else
        _doctor_record "commit refs" "pass" "$total recorded ref(s), none orphaned"
    fi
}

_doctor_local_procedure_command_refs() {
    local procedures_dir="$1" file id matches=""
    [ -d "$procedures_dir" ] || return 0

    for file in "$procedures_dir"/*.md; do
        [ -f "$file" ] || continue
        if awk '
            BEGIN { section=0; visibility="local"; command_ref=0 }
            /^---[[:space:]]*$/ { section++; next }
            section == 1 && /^visibility:/ {
                value=$0
                sub(/^visibility:[[:space:]]*/, "", value)
                sub(/[[:space:]]*#.*/, "", value)
                visibility=value
            }
            section >= 2 && $0 ~ /(^|[^.\/:[:alnum:]_-])wv[[:space:]]+[^[:space:]]/ {
                command_ref=1
            }
            END { exit !(visibility == "local" && command_ref) }
        ' "$file"; then
            id=$(awk -F': *' '/^id:/{print $2; exit}' "$file")
            [ -n "$id" ] || id=$(basename "$file" .md)
            matches="${matches:+$matches, }$id"
        fi
    done

    printf '%s' "$matches"
}

# _doctor_check_edge_invariants — stored edges that break their type's invariant
# and closed parents over open children nothing accounts for (ontology S2,
# wv-76b361). The query is the one wv link and wv done refuse by; history is
# reported here, never refused on read (D4). Each detail names up to five.
_doctor_check_edge_invariants() {
    local edges children n list
    if ! edges=$(db_query "SELECT invariant || ':' || source || '->' || target || ' (' || type || ')'
            FROM ($(wv_edge_violations_sql "SELECT source, target, type FROM edges"))
            ORDER BY type, invariant, source, target;" 2>/dev/null); then
        _doctor_record "edge invariants" "warn" "could not evaluate the edge invariants"
    elif [ -n "$edges" ]; then
        n=$(wc -l <<< "$edges")
        list=$(head -5 <<< "$edges" | tr '\n' ';' | sed 's/;$//; s/;/; /g')
        _doctor_record "edge invariants" "warn" "$n stored edge(s) break their type's invariant: $list$([ "$n" -gt 5 ] && echo '; ...') — see contracts/edge-types-v1.json"
    else
        _doctor_record "edge invariants" "pass" "every stored edge keeps its type's invariant"
    fi
    if ! children=$(db_query "SELECT p.id || '>' || c.id FROM edges e
            JOIN nodes p ON p.id = e.target JOIN nodes c ON c.id = e.source
            WHERE e.type = 'implements' AND p.status = 'done' AND $(wv_unaccounted_child_sql c e.target)
            ORDER BY p.id, c.id;" 2>/dev/null); then
        _doctor_record "closed parents" "warn" "could not evaluate closed parents over open children"
    elif [ -n "$children" ]; then
        n=$(wc -l <<< "$children")
        list=$(head -5 <<< "$children" | tr '\n' ' ' | sed 's/ $//')
        _doctor_record "closed parents" "warn" "$n open child(ren) under a closed parent, not parked, re-parented or resolved (parent>child): $list$([ "$n" -gt 5 ] && echo ' ...')"
    else
        _doctor_record "closed parents" "pass" "no closed parent over an unaccounted open child"
    fi
}

_doctor_record() {
    local name="$1" status="$2" detail="$3"
    _dr_total=$((_dr_total + 1))
    case "$status" in
        pass) _dr_pass=$((_dr_pass + 1)) ;;
        fail) _dr_fail=$((_dr_fail + 1)) ;;
        warn) _dr_warn=$((_dr_warn + 1)) ;;
    esac
    if [ "$_dr_format" = "json" ]; then
        # Details carry paths, commands and error text: escaped, or one quote
        # in a detail makes the whole --json report unparsable.
        _dr_results="${_dr_results:+$_dr_results,}$(printf '{"check":"%s","status":"%s","detail":"%s"}' "$name" "$status" "$(wv_json_escape "$detail")")"
    else
        local icon
        case "$status" in
            pass) icon="${GREEN}✓${NC}" ;;
            fail) icon="${RED}✗${NC}" ;;
            warn) icon="${YELLOW}⊘${NC}" ;;
        esac
        echo -e "  $icon $name: $detail"
    fi
}

# _doctor_entry_script — the wv script this process runs.
_doctor_entry_script() {
    if [ -f "$0" ]; then echo "$0"; else echo "${SCRIPT_DIR:-.}/wv"; fi
}

# _doctor_check_lib_refs <label> — every library a component names must exist.
# The required set is read from the code, not typed: each wv-*.sh / wv-*.py
# named outside a comment in the entry script, the libraries, the command
# modules and the git-hook sources, less command modules (checked below by
# what they define) and names whose parent path component is a hooks directory
# however spelled (hooks/, $_hooks_dir/, ${HOOKS_DIR}/): hook files, not
# libraries. $HOOK_DIR/../lib/wv-x.sh keeps lib/ as its parent and counts.
# A new library is required the moment something loads it; a typed list had to
# be remembered and was not (wv-587469).
_doctor_check_lib_refs() {
    local label="$1" entry refs r found=0 total=0 missing=""
    entry=$(_doctor_entry_script)
    refs=$(for f in "$entry" "$WV_LIB_DIR"/lib/*.sh "$WV_LIB_DIR"/cmd/*.sh "$WV_LIB_DIR"/hooks/*.sh; do
               [ -f "$f" ] && grep -v '^[[:space:]]*#' "$f"
           done 2>/dev/null | grep -oE '[^/[:space:]"'"'"']*/?wv-[a-z0-9-]+\.(sh|py)\b' \
           | awk -F/ '{ parent = (NF > 1) ? tolower($(NF-1)) : ""
                        name = $NF; sub(/^[^w]*/, "", name)
                        if (parent !~ /hook/ && name ~ /^wv-/ && name !~ /^wv-cmd-/) print name }' | sort -u)
    for r in $refs; do
        total=$((total + 1))
        if [ -f "$WV_LIB_DIR/lib/$r" ]; then
            found=$((found + 1))
        else
            missing="${missing:+$missing, }$r"
        fi
    done
    if [ -n "$missing" ]; then
        _doctor_record "$label" "fail" "$found/$total referenced libraries present (missing: $missing)"
    else
        _doctor_record "$label" "pass" "$found/$total referenced libraries present"
    fi
}

# _doctor_check_cmd_defs <label> — every cmd_* the dispatcher calls must be
# defined by some module. With command modules loaded on first use, a missing
# module shows only as its commands failing, so this is the check that names
# it. Assignments and expansions (local cmd_func=..., $cmd_func) are not calls.
_doctor_check_cmd_defs() {
    local label="$1" entry calls c found=0 total=0 missing=""
    entry=$(_doctor_entry_script)
    # shellcheck disable=SC2016  # the bracket expression [^$...] matches a literal $ in source text
    calls=$(grep -v '^[[:space:]]*#' "$entry" 2>/dev/null \
        | grep -oE '(^|[^$a-zA-Z0-9_{])cmd_[a-z0-9_]+[=]?' | grep -v '=$' \
        | grep -oE 'cmd_[a-z0-9_]+' | sort -u)
    for c in $calls; do
        total=$((total + 1))
        if grep -qE -- "^$c\(\)" "$entry" "$WV_LIB_DIR"/cmd/*.sh "$WV_LIB_DIR"/lib/*.sh 2>/dev/null; then
            found=$((found + 1))
        else
            missing="${missing:+$missing, }$c"
        fi
    done
    if [ -n "$missing" ]; then
        _doctor_record "$label" "fail" "$found/$total dispatched commands defined (undefined: $missing)"
    else
        _doctor_record "$label" "pass" "$found/$total dispatched commands defined"
    fi
}

_doctor_agent_python_exec() {
    local python_command="$1"
    shift

    [ -n "$python_command" ] || return 127
    PYTHONPATH="${WV_LIB_DIR:-}" "$python_command" "$@"
}

_doctor_check_agent_env() {
    local python_command
    python_command=$(_bootstrap_python_command)

    if [ -z "$python_command" ]; then
        _doctor_record "agent python" "fail" "no python command resolved for agent flows"
        _doctor_record "agent pytest" "fail" "cannot verify pytest without an agent python command"
        _doctor_record "agent imports" "fail" "cannot verify imports without an agent python command"
        return
    fi

    local python_detail="$python_command"
    if [ -x "$python_command" ]; then
        _doctor_record "agent python" "pass" "$python_detail"
    else
        _doctor_record "agent python" "fail" "$python_detail not executable"
    fi

    local pytest_version
    pytest_version=$(_doctor_agent_python_exec "$python_command" -m pytest --version 2>/dev/null | head -1 || true)
    if [ -n "$pytest_version" ]; then
        _doctor_record "agent pytest" "pass" "$pytest_version"
    else
        _doctor_record "agent pytest" "warn" "pytest missing for $python_detail — install project dev dependencies"
    fi

    local import_status
    import_status=$(_doctor_agent_python_exec "$python_command" -c 'import weave_gh, weave_indexer, weave_quality, weave_search; print("imports ok")' 2>/dev/null || true)
    if [ "$import_status" = "imports ok" ]; then
        _doctor_record "agent imports" "pass" "weave_gh weave_indexer weave_quality weave_search"
    else
        _doctor_record "agent imports" "warn" "PYTHONPATH/WV_LIB_DIR import path not ready for agent modules"
    fi
}

_doctor_check_codex_mcp() {
    if ! command -v codex >/dev/null 2>&1; then
        _doctor_record "codex mcp" "warn" "codex command not found; skip MCP scope check"
        return
    fi

    local mcp_list
    mcp_list=$(codex mcp list 2>/dev/null || true)
    if [ -z "$mcp_list" ]; then
        _doctor_record "codex mcp" "warn" "no Codex MCP registrations detected; optional: wv init-repo --agent=codex --codex-mcp"
        return
    fi

    local has_lite has_inspect has_full
    has_lite=false
    has_inspect=false
    has_full=false
    grep -q '^weave-lite[[:space:]]' <<< "$mcp_list" && has_lite=true
    grep -q '^weave-inspect[[:space:]]' <<< "$mcp_list" && has_inspect=true
    grep -q '^weave[[:space:]]' <<< "$mcp_list" && has_full=true

    if [ "$has_full" = true ] && { [ "$has_lite" = true ] || [ "$has_inspect" = true ]; }; then
        _doctor_record "codex mcp" "warn" "stale full weave MCP still registered alongside lite/inspect; remove it with: codex mcp remove weave"
    elif [ "$has_lite" = true ]; then
        _doctor_record "codex mcp" "pass" "weave-lite registered (recommended Codex default)"
    elif [ "$has_inspect" = true ]; then
        _doctor_record "codex mcp" "pass" "weave-inspect registered (read-only Codex scope)"
    elif [ "$has_full" = true ]; then
        _doctor_record "codex mcp" "warn" "full weave MCP registered; prefer weave-lite/inspect and use CLI for GitHub/network/write operations"
    else
        _doctor_record "codex mcp" "warn" "Weave MCP not registered for Codex; optional: wv init-repo --agent=codex --codex-mcp"
    fi
}

# Detect the project Codex hook config and surface trust guidance. Codex hook
# trust is reviewed inside Codex itself (via /hooks) and is not reliably
# inspectable from outside the running session, so a present + complete
# config still warns "pending trust" rather than "pass" (see
# docs/PROPOSAL-codex-hooks-rust-dispatch.md test plan item 10).
_doctor_check_codex_hooks() {
    local git_root hooks_file contract_file
    git_root=$(git rev-parse --show-toplevel 2>/dev/null)
    if [ -z "$git_root" ]; then
        _doctor_record "codex hooks" "warn" "not in a git repo; skip"
        return
    fi
    hooks_file="$git_root/.codex/hooks.json"
    contract_file="$git_root/.codex/weave.json"

    if [ ! -f "$hooks_file" ]; then
        if [ -f "$contract_file" ] && jq -e '(.hooks.enabled // 0) == 1' "$contract_file" >/dev/null 2>&1; then
            _doctor_record "codex hooks" "warn" ".codex/weave.json records hooks enabled but .codex/hooks.json is missing; run: wv init-repo --agent=codex --codex-hooks --force"
        else
            _doctor_record "codex hooks" "warn" "no project Codex hooks; optional: wv init-repo --agent=codex --codex-hooks"
        fi
        return
    fi

    if ! jq -e 'type == "object" and (.hooks | type) == "object"' "$hooks_file" >/dev/null 2>&1; then
        _doctor_record "codex hooks" "fail" ".codex/hooks.json is present but is not valid JSON with a top-level hooks object"
        return
    fi

    local missing="" ev
    for ev in SessionStart PreToolUse PostToolUse PreCompact Stop; do
        jq -e --arg ev "$ev" '(.hooks[$ev] // []) | length > 0' "$hooks_file" >/dev/null 2>&1 || missing="${missing:+$missing, }$ev"
    done
    if [ -n "$missing" ]; then
        _doctor_record "codex hooks" "warn" ".codex/hooks.json is stale, missing event(s): $missing -- regenerate with wv init-repo --agent=codex --codex-hooks --force"
        return
    fi

    # A blocking event that still runs dispatch with --json blocks with exit 1,
    # which Codex reads as a failed hook, so the guard is advisory only
    # (wv-5b774a); the generated config uses --format=host.
    local advisory=""
    for ev in PreToolUse Stop; do
        jq -e --arg ev "$ev" '[.hooks[$ev][]?.hooks[]?.command // empty | select(test("hook dispatch") and (test("--format=host") | not))] | length > 0' \
            "$hooks_file" >/dev/null 2>&1 && advisory="${advisory:+$advisory, }$ev"
    done
    if [ -n "$advisory" ]; then
        _doctor_record "codex hooks" "warn" ".codex/hooks.json is stale, $advisory dispatch without --format=host cannot block in Codex -- regenerate with wv init-repo --agent=codex --codex-hooks --force"
        return
    fi

    _doctor_record "codex hooks" "warn" ".codex/hooks.json covers SessionStart/PreToolUse/PostToolUse/PreCompact/Stop -- pending trust; review and trust with /hooks in Codex before it enforces"
}

# cmd_context_policy [--json] [--refresh] — the context load policy (HIGH/MEDIUM/
# LOW) from repository size signals: the one computation every harness reads
# (wv-f757a4). It lived only in the Claude SessionStart hook, whose script MCP
# ran under a 5s timeout behind a ~55s wv load and whose agent-mode output never
# carried the line MCP parsed, so MCP clients never saw it. Reads no graph and
# runs no load. Cached for an hour in .weave/.context_policy (POLICY_CACHE
# overrides, for tests); keeps the .weave/runtime.md block current.
_context_policy_decide() {
    local root="$1" nodes_file="$2" policy="MEDIUM" large_files jsonl_lines total_files
    local -a reasons=()
    large_files=$(cd "$root" && git ls-files -z '*.py' '*.ts' '*.js' '*.go' 2>/dev/null \
        | xargs -0 -r stat -c %s 2>/dev/null | awk '$1 > 51200 {c++} END {print c+0}')
    if [ "${large_files:-0}" -gt 10 ]; then
        policy="LOW"; reasons+=("many large source files detected")
    fi
    if [ -f "$nodes_file" ]; then
        jsonl_lines=$(wc -l < "$nodes_file" 2>/dev/null || echo 0)
        if [ "$jsonl_lines" -gt 100 ]; then
            policy="LOW"; reasons+=("large Weave history ($jsonl_lines nodes)")
        fi
    fi
    total_files=$(git -C "$root" ls-files '*.py' '*.ts' '*.js' 2>/dev/null | wc -l)
    if [ "$total_files" -gt 500 ] && [ "$policy" = "MEDIUM" ]; then
        reasons+=("large codebase ($total_files source files)")
    fi
    if [ ${#reasons[@]} -eq 0 ]; then
        policy="HIGH"; reasons+=("small/fresh workspace")
    fi
    printf '%s\n' "$policy" "${reasons[@]}"
}

_context_policy_runtime_md() {
    local runtime_md="$1" policy="$2" begin="<!-- BEGIN WEAVE RUNTIME CONTEXT -->"
    local end="<!-- END WEAVE RUNTIME CONTEXT -->" block tmp
    [ -f "$runtime_md" ] || return 0
    block="${begin}
Current context policy: ${policy}
Policy source: .weave/.context_policy
This file is loaded into weave-runtime system prompts. Keep repo-specific instructions below this block.
${end}"
    tmp=$(mktemp) || return 0
    if grep -qF -- "$begin" "$runtime_md"; then
        awk -v begin="$begin" -v end="$end" -v block="$block" '
            $0 == begin { print block; skip=1; next }
            skip && $0 == end { skip=0; next }
            skip { next }
            { print }
        ' "$runtime_md" > "$tmp"
    else
        { printf '%s\n\n' "$block"; cat "$runtime_md"; } > "$tmp"
    fi
    if cmp -s "$tmp" "$runtime_md"; then rm -f "$tmp"; else mv "$tmp" "$runtime_md"; fi
}

cmd_context_policy() {
    local json=false refresh=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) json=true ;;
            --refresh) refresh=true ;;
            *) echo "wv context-policy: unknown argument: $1" >&2; return 2 ;;
        esac
        shift
    done

    local root weave_dir cache default_cache cached=false policy decided age
    local -a reasons=()
    root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
    weave_dir="$root/.weave"
    default_cache="$weave_dir/.context_policy"
    cache="${POLICY_CACHE:-$default_cache}"

    age=$(( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || echo 0) ))
    if [ "$refresh" = false ] && [ -s "$cache" ] && [ "$age" -lt 3600 ]; then
        policy=$(head -1 "$cache")
        mapfile -t reasons < <(tail -n +2 "$cache")
        cached=true
    else
        decided=$(_context_policy_decide "$root" "$weave_dir/nodes.jsonl")
        policy=$(head -1 <<< "$decided")
        mapfile -t reasons < <(tail -n +2 <<< "$decided")
        # An uninitialised repository gets no .weave/ created for a cache.
        if [ "$cache" != "$default_cache" ] || [ -d "$weave_dir" ]; then
            mkdir -p "$(dirname "$cache")" 2>/dev/null \
                && printf '%s\n' "$policy" "${reasons[@]}" > "$cache" 2>/dev/null || true
        fi
    fi
    _context_policy_runtime_md "$weave_dir/runtime.md" "$policy"

    if [ "$json" = true ]; then
        jq -n --arg policy "$policy" --argjson cached "$cached" \
            '{policy: $policy, reasons: $ARGS.positional, cached: $cached, source: ".weave/.context_policy"}' \
            --args "${reasons[@]}"
    else
        echo "policy: $policy"
        [ ${#reasons[@]} -gt 0 ] && echo "reason: ${reasons[0]}"
    fi
    return 0
}

# _doctor_check_git_hook label src_path installed_path grep_pattern install_cmd
# Records pass/warn via _doctor_record. Shared by pre-commit and prepare-commit-msg checks.
_doctor_check_git_hook() {
    local label="$1" src="$2" installed="$3" grep_pattern="$4" install_cmd="$5"
    # git skips a hook without the execute bit: a current copy it will not run
    # is no gate at all (wv-76c726, the doctor side of wv-ecae1c).
    if [ -f "$installed" ] && [ ! -x "$installed" ] && grep -q -- "$grep_pattern" "$installed" 2>/dev/null; then
        _doctor_record "$label" "warn" "installed but not executable, so git skips it — chmod +x $installed"
        return 0
    fi
    if [ -f "$installed" ]; then
        if [ -f "$src" ] && cmp -s "$src" "$installed" 2>/dev/null; then
            _doctor_record "$label" "pass" "Weave hook installed and current"
        elif [ ! -f "$src" ] && grep -q -- "$grep_pattern" "$installed" 2>/dev/null; then
            _doctor_record "$label" "pass" "Weave hook installed (managed by wv init-repo)"
        elif grep -q -- "$grep_pattern" "$installed" 2>/dev/null; then
            _doctor_record "$label" "warn" "stale — $install_cmd"
        else
            _doctor_record "$label" "warn" "exists but not the Weave version — $install_cmd"
        fi
    else
        _doctor_record "$label" "warn" "not installed — $install_cmd"
    fi
}

# _doctor_check_hot_zone_orphans — warn about hot-zone dirs with no matching repo owner.
# Args: hot_zone path
_doctor_check_hot_zone_orphans() {
    local hot_zone="$1"
    local hz_parent; hz_parent=$(dirname "$hot_zone")
    [ -d "$hz_parent" ] || return 0
    local orphan_count=0 d owner
    for d in "$hz_parent"/*/; do
        [ -f "${d}brain.db" ] || continue
        owner=$(cat "${d}.repo_root" 2>/dev/null || echo "")
        if [ -n "$owner" ] && [ ! -d "$owner" ]; then
            orphan_count=$((orphan_count + 1))
        elif [ -z "$owner" ]; then
            [ "${d%/}" != "$hot_zone" ] && orphan_count=$((orphan_count + 1))
        fi
    done
    if [ "$orphan_count" -gt 0 ]; then
        _doctor_record "orphan hot-zones" "warn" \
            "$orphan_count unmatched dir(s) under $hz_parent — run: wv hotzone gc"
    fi
}

# _doctor_check_hot_zone_shadow — warn when this repo has a brain.db under a
# placement root it does not resolve to (wv-854b4a). Placement adopts the zone
# already holding this repo's database (wv-b831e3), and wv refuses to run when
# two non-empty ones exist, so what this can still see is an empty one: what
# sqlite3 leaves after opening a guessed path, which on 2026-09-25 read as a
# split brain. Reports only: placement is not changed here.
# Candidates are compared by file identity, not path: the /tmp zone's neutral
# name is a symlink to its legacy directory (wv-95bddf), so one live database
# has two paths, and advising removal of either would remove the live graph
# (wv-6f2eed). A file two names reach is reported once.
# Args: live hot_zone path. WV_DOCTOR_PLACEMENT_ROOTS overrides the roots (tests).
_doctor_check_hot_zone_shadow() {
    local hot_zone="$1" repo_root repo_hash uid root cand seen also="" found=0
    local -a reported=()
    repo_root="${WV_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}"
    [ -n "$repo_root" ] || return 0
    repo_hash=$(echo "$repo_root" | md5sum | cut -c1-8)
    uid=$(id -u 2>/dev/null || echo "$UID")
    for root in ${WV_DOCTOR_PLACEMENT_ROOTS:-/tmp/weave-hotzone-${uid} /tmp/weave-codex-${uid} /dev/shm/weave /tmp/weave-${uid}}; do
        [ "$root/$repo_hash" = "$hot_zone" ] && continue
        cand="$root/$repo_hash/brain.db"
        [ -f "$cand" ] || continue
        if [ "$cand" -ef "$hot_zone/brain.db" ]; then
            also="$cand"
            continue
        fi
        for seen in "${reported[@]}"; do
            [ "$cand" -ef "$seen" ] && continue 2
        done
        reported+=("$cand")
        found=1
        if [ ! -s "$cand" ]; then
            _doctor_record "hot-zone shadow" "warn" \
                "empty $cand (left by opening a guessed path); remove it. Live DB: $hot_zone/brain.db (wv hotzone db)"
        else
            _doctor_record "hot-zone shadow" "warn" \
                "second brain.db for this repo at $cand; live DB is $hot_zone/brain.db (wv hotzone db). Placement adopts the zone holding a database (wv-b831e3). Remove neither yet: the copies may have diverged and syncing both does not merge them (wv-a73141). Back up both (sqlite3 <db> \".backup '<file>'\"), run wv hotzone diff $hot_zone/brain.db $cand, carry what the live copy lacks into it, then remove the other"
        fi
    done
    [ "$found" -eq 0 ] && _doctor_record "hot-zone shadow" "pass" \
        "no brain.db for this repo outside $hot_zone${also:+ (also reached as $also: the same file, not a copy)}"
    return 0
}

# _doctor_check_hot_zone_names — report both names of the /tmp zone and which
# one is the physical directory (wv-7e1e49). During the rename transition the
# legacy name stays physical and the neutral name is an alias to it
# (wv-95bddf); a reader should not have to infer that from ls. Reports only:
# hot_zone_check and hot_zone_ensure decide what is used or refused, and the
# alias verdict is theirs, hot_zone_dir_problem, so the two cannot disagree
# (wv-9d2cd2: a looser comparison here passed an alias the guard refuses).
_doctor_check_hot_zone_names() {
    case "${OSTYPE:-}" in darwin*) return 0 ;; esac
    type _hot_zone_linux_zones >/dev/null 2>&1 || return 0
    _hot_zone_linux_zones
    local n="$_HZ_NEUTRAL" l="$_HZ_LEGACY" problem
    if [ -L "$n" ]; then
        problem=$(hot_zone_dir_problem "$n" "$l")
        if [ -n "$problem" ]; then
            _doctor_record "hot-zone names" "warn" \
                "$n $problem; wv refuses it as a hot-zone base"
        elif [ ! -e "$l" ] && [ ! -L "$l" ]; then
            _doctor_record "hot-zone names" "pass" \
                "$n is an alias of $l, which is absent; the next wv call that opens the zone recreates it as the physical directory"
        else
            _doctor_record "hot-zone names" "pass" \
                "physical: $l (legacy name, kept while hosts run mixed versions); $n is an alias of it"
        fi
    elif [ -d "$n" ] && [ -d "$l" ] && [ ! -L "$l" ]; then
        if [ -n "$_HZ_TMP_CONFLICT" ]; then
            _doctor_record "hot-zone names" "warn" \
                "$n and $l are separate directories that both hold databases; wv refuses to pick one"
        elif _hot_zone_populated "${_HZ_ZONES[0]}"; then
            _doctor_record "hot-zone names" "pass" \
                "physical: ${_HZ_ZONES[0]} (the one holding databases); $n and $l are separate directories"
        else
            _doctor_record "hot-zone names" "pass" \
                "physical: ${_HZ_ZONES[0]} (neither holds a database, so the legacy directory is the default authority); $n and $l are separate directories"
        fi
    elif [ -d "$n" ]; then
        if [ -L "$l" ]; then
            _doctor_record "hot-zone names" "pass" "physical: $n; legacy name $l is a symlink"
        else
            _doctor_record "hot-zone names" "pass" "physical: $n; legacy name $l absent"
        fi
    elif [ -d "$l" ] && [ ! -L "$l" ]; then
        _doctor_record "hot-zone names" "pass" \
            "physical: $l (legacy name); the alias $n is added on the next wv call that opens the zone"
    else
        _doctor_record "hot-zone names" "pass" \
            "neither $n nor $l exists; first use creates $l and the alias $n"
    fi
    return 0
}

# _doctor_check_delta_v2_catalog — fail when a committed Delta v2 op carries a
# hard disposition (wv-99c85a). wv load rolls the WHOLE v2 batch back on the
# first one and, unless WV_DELTA_V2_STRICT=1, only warns and falls back to v1,
# so one bad op silently disables v2 replay on every clone on every load. The
# static pass (wv-delta-v2-replay.py --check) needs no database.
_doctor_check_delta_v2_catalog() {
    [ -n "${WEAVE_DIR:-}" ] && [ -d "$WEAVE_DIR/deltas" ] || return 0
    local -a ops=()
    local line
    while IFS= read -r line; do
        [ -n "$line" ] && ops+=("$line")
    done < <(find "$WEAVE_DIR/deltas" -path '*/v2/*.json' -type f 2>/dev/null)
    [ "${#ops[@]}" -gt 0 ] || return 0

    local replay_py="${WV_LIB_DIR:-$SCRIPT_DIR}/lib/wv-delta-v2-replay.py"
    [ -f "$replay_py" ] || replay_py="$SCRIPT_DIR/lib/wv-delta-v2-replay.py"
    if [ ! -f "$replay_py" ]; then
        _doctor_record "delta v2 catalog" "warn" "replay evaluator not found; ${#ops[@]} op(s) unchecked"
        return 0
    fi
    local out rc=0 verdict
    out=$(python3 "$replay_py" --check "${ops[@]}" 2>/dev/null) || rc=$?
    verdict=$(printf '%s' "$out" | jq -r '
        if (.failures | length) == 0 then "ok"
        else "\(.failures | length) of \(.checked) op(s) fail: \(.failures[0].path | split("/") | .[-1]) (\(.failures[0].disposition): \(.failures[0].reason))"
        end' 2>/dev/null) || verdict=""
    if [ "$rc" -eq 0 ] && [ "$verdict" = "ok" ]; then
        _doctor_record "delta v2 catalog" "pass" "${#ops[@]} op(s) pass replay validation"
    elif [ "$rc" -eq 2 ] && [ -n "$verdict" ]; then
        _doctor_record "delta v2 catalog" "fail" \
            "$verdict — wv load rolls back ALL v2 replay and falls back to v1 on every clone"
    else
        _doctor_record "delta v2 catalog" "warn" "replay --check could not run (rc=$rc)"
    fi
}

# _doctor_check_install_drift — compare source scripts/ tree with installed ~/.local/lib/weave/.
_doctor_check_install_drift() {
    local source_path_file="$HOME/.config/weave/source-path"
    [ -f "$source_path_file" ] || return 0
    local src_root; src_root=$(cat "$source_path_file" 2>/dev/null || echo "")
    [ -n "$src_root" ] && [ -d "$src_root/scripts/cmd" ] || return 0
    local lib_dir="$HOME/.local/lib/weave"
    local drifted_count=0 src_file rel installed_file
    for src_file in "$src_root/scripts/cmd/"*.sh "$src_root/scripts/lib/"*.sh "$src_root/scripts/wv"; do
        [ -f "$src_file" ] || continue
        rel="${src_file#"$src_root/scripts/"}"
        installed_file="$lib_dir/$rel"
        [ "$rel" = "wv" ] && installed_file="$HOME/.local/bin/wv"
        if [ ! -f "$installed_file" ]; then
            drifted_count=$((drifted_count + 1))
        elif [ "$(md5sum "$src_file" 2>/dev/null | awk '{print $1}')" != \
              "$(md5sum "$installed_file" 2>/dev/null | awk '{print $1}')" ]; then
            drifted_count=$((drifted_count + 1))
        fi
    done
    if [ "$drifted_count" -eq 0 ]; then
        _doctor_record "install drift" "pass" "source and installed lib match"
    else
        _doctor_record "install drift" "warn" "$drifted_count file(s) differ — run: wv self-update"
    fi
}

# _doctor_check_verification — surface the P6 verification-gate layer (finding wv-e754b0 O2).
# Repo-scoped. The gate ships inert by default and nothing else tells a user it is off,
# what files it still needs, or that a raw sqlite3 UPDATE silently resets on reboot (tmpfs).
_doctor_check_verification() {
    [ -z "${WEAVE_DIR:-}" ] && return 0
    [ -n "${WV_DB:-}" ] && [ -f "$WV_DB" ] || return 0

    local conf="$WEAVE_DIR/quality.conf" tmap="$WEAVE_DIR/test-map.conf" tg
    tg=$(sqlite3 "$WV_DB" "SELECT value FROM policy_thresholds WHERE key='test_gate';" 2>/dev/null)
    [ -z "$tg" ] && tg="0"
    tg="${tg%.0}"   # sqlite may render the integer as 1.0

    local conf_has_gate=false
    grep -qE '^[[:space:]]*test_gate[[:space:]]*=' "$conf" 2>/dev/null && conf_has_gate=true

    # 1. gate state — test_gate=0 is the shipped default, so report it as pass+hint, not a failure.
    case "$tg" in
        0) _doctor_record "verification gate" "pass" "test_gate=0 (off — advisory; enable: wv config enable test-gate)" ;;
        1) _doctor_record "verification gate" "pass" "test_gate=1 (warn — soft advisory on wv done)" ;;
        2) _doctor_record "verification gate" "pass" "test_gate=2 (block — hard gate on wv done)" ;;
        *) _doctor_record "verification gate" "warn" "test_gate=$tg (unrecognised; expected 0|1|2)" ;;
    esac

    # 2. durability — a gate enabled only in the tmpfs DB resets on reboot (not in state.sql).
    if [ "$tg" != "0" ] && [ "$conf_has_gate" = false ]; then
        _doctor_record "verification config" "warn" "test_gate=$tg in DB but not in .weave/quality.conf [thresholds] — session-only, resets on reboot. Fix: wv config enable test-gate"
    elif [ "$conf_has_gate" = true ]; then
        _doctor_record "verification config" "pass" "durable in .weave/quality.conf [thresholds]"
    fi

    # 3. test-map required for the gate to classify anything when live.
    if [ "$tg" != "0" ]; then
        local tmap_rc=0
        wv_config_read "$tmap" >/dev/null || tmap_rc=$?
        if [ "$tmap_rc" -eq 0 ]; then
            _doctor_record "test-map" "pass" ".weave/test-map.conf present"
        elif [ "$tmap_rc" -ne 2 ]; then
            _doctor_record "test-map" "fail" ".weave/test-map.conf exists but cannot be read (unreadable, a directory, or a dangling symlink) — every gate refuses until it can"
        else
            _doctor_record "test-map" "warn" ".weave/test-map.conf absent — touched files classify 'unknown', gate inert even when on. See: wv guide --topic=verification"
        fi
    fi

    # 3b. provisioning mode (transition rule 5, wv-0ee3f4): how many routes the
    # newest gate records ran in checkout mode, a labelled transition state
    # until each is declared in .weave/gate-provision.json. Read from wv analyze
    # gates, the one place the gate log is aggregated.
    local prov
    if prov=$(cmd_analyze_gates --json 2>/dev/null | jq -c '.provisioning // empty' 2>/dev/null) && [ -n "$prov" ]; then
        if [ "$(jq -r '.gates_recorded' <<< "$prov")" = "0" ]; then
            _doctor_record "gate provisioning" "pass" "no gate record carries per-route modes yet"
        else
            _doctor_record "gate provisioning" "pass" "$(jq -r '"\(.routes) route(s): \(.frozen) frozen, \(.checkout) in checkout mode"
                + (if .checkout > 0 then " (\(.checkout_routes[:3] | join(", "))\(if .checkout > 3 then ", ..." else "" end)); declare them in .weave/gate-provision.json to run frozen" else "" end)' <<< "$prov")"
        fi
    fi

    # 4. ledger freshness — informational row count.
    local rows
    rows=$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM test_results;" 2>/dev/null)
    [ -z "$rows" ] && rows=0
    _doctor_record "test ledger" "pass" "$rows test_results row(s) recorded"
    return 0
}

cmd_doctor() {
    _dr_format="text"
    local _dr_repair=false
    local _dr_agent=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --json)   _dr_format="json" ;;
            --repair) _dr_repair=true ;;
            --agent)  _dr_agent=true ;;
        esac
        shift
    done

    # Only --repair writes repository scaffolding; say so rather than leave the
    # ownership rule silent on every plain doctor (wv-15422b). Only the doctor
    # operation records it: ship-agent runs doctor in-process as a readiness
    # probe, where this rule is not the call's to decide.
    if [ "$_dr_repair" != "true" ] && [ "${_WV_ATTEMPT_OPERATION:-doctor}" = "doctor" ]; then
        wv_policy_verdict repository_write_requires_owned allow no "" "no repair requested, so nothing is written"
    fi
    if [ "$_dr_repair" = "true" ]; then
        local _dr_repo_root _dr_persistent_root
        _dr_repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
        wv_repository_require_owned "$_dr_repo_root" "wv doctor --repair" || return 1
        if [ -n "${WEAVE_DIR:-}" ]; then
            _dr_persistent_root=$(dirname "$WEAVE_DIR")
            if [ -L "$WEAVE_DIR" ]; then
                echo "wv: refusing wv doctor --repair through symlinked Weave directory: $WEAVE_DIR" >&2
                return 1
            fi
            wv_repository_require_owned "$_dr_persistent_root" "wv doctor --repair" || return 1
        fi
    fi

    _dr_pass=0 _dr_fail=0 _dr_warn=0 _dr_total=0 _dr_results=""

    # Match the cold-start contract of graph commands. A committed state.sql is
    # the persistent authority after reboot or inside a fresh container; testing
    # the absent cache instead made Doctor's result depend on whether another wv
    # command happened to run first. Do not initialise an unconfigured repo here:
    # hydration is limited to a real committed snapshot and the default DB path.
    local _dr_hydration_failed=false
    if command -v sqlite3 >/dev/null 2>&1 &&
       [ -n "${WV_DB:-}" ] && [ ! -f "$WV_DB" ] &&
       [ -z "${WV_DB_CUSTOM:-}" ] && [ -f "$WEAVE_DIR/state.sql" ]; then
        db_ensure >/dev/null || _dr_hydration_failed=true
    fi

    [ "$_dr_format" = "text" ] && echo "Weave Doctor — Installation Health"

    if [ "$_dr_hydration_failed" = true ]; then
        _doctor_record "database hydration" "fail" \
            "could not restore the hot-zone database from .weave/state.sql"
    fi

    # Keep check order stable; helpers share this call's repair/format state
    # through Bash's dynamic scope (wv-813b05).
    _doctor_check_prerequisites
    _doctor_check_storage
    _doctor_check_repository_state
    _doctor_check_surfaces

    if [ "$_dr_agent" = true ]; then
        _doctor_check_agent_env
        _doctor_check_codex_mcp
        _doctor_check_codex_hooks
    fi

    # Summary
    if [ "$_dr_format" = "json" ]; then
        local overall="pass"
        [ "$_dr_fail" -gt 0 ] && overall="fail"
        printf '{"overall":"%s","passed":%d,"failed":%d,"warnings":%d,"total":%d,"checks":[%s]}\n' \
            "$overall" "$_dr_pass" "$_dr_fail" "$_dr_warn" "$_dr_total" "$_dr_results"
    else
        echo ""
        if [ "$_dr_fail" -gt 0 ]; then
            echo -e "Result: ${RED}${_dr_pass}/${_dr_total} passed${NC} (${_dr_fail} failed, ${_dr_warn} warnings)"
        elif [ "$_dr_warn" -gt 0 ]; then
            echo -e "Result: ${GREEN}${_dr_pass}/${_dr_total} passed${NC} (${_dr_warn} warnings)"
        else
            echo -e "Result: ${GREEN}${_dr_pass}/${_dr_total} passed${NC}"
        fi
    fi

    [ "$_dr_fail" -gt 0 ] && return 1
    return 0
}

_doctor_check_prerequisites() {
    # 1. sqlite3 present
    if command -v sqlite3 >/dev/null 2>&1; then
        local sq_ver
        sq_ver=$(sqlite3 --version 2>/dev/null | awk '{print $1}')
        _doctor_record "sqlite3" "pass" "$sq_ver"
        # 2. sqlite3 version >= 3.35
        local sq_major sq_minor
        sq_major=$(echo "$sq_ver" | cut -d. -f1)
        sq_minor=$(echo "$sq_ver" | cut -d. -f2)
        if [ "$sq_major" -gt 3 ] 2>/dev/null || { [ "$sq_major" -eq 3 ] && [ "$sq_minor" -ge 35 ]; } 2>/dev/null; then
            _doctor_record "sqlite3 version" "pass" ">= 3.35"
        else
            _doctor_record "sqlite3 version" "warn" "$sq_ver < 3.35"
        fi
        # 3. FTS5
        local fts5
        fts5=$(sqlite3 ":memory:" "SELECT sqlite_compileoption_used('ENABLE_FTS5');" 2>/dev/null || echo "0")
        if [ "$fts5" = "1" ]; then
            _doctor_record "FTS5" "pass" "available"
        else
            _doctor_record "FTS5" "warn" "not available"
        fi
    else
        _doctor_record "sqlite3" "fail" "not found"
    fi

    # 4. jq present
    if command -v jq >/dev/null 2>&1; then
        _doctor_record "jq" "pass" "$(jq --version 2>/dev/null)"
    else
        _doctor_record "jq" "fail" "not found"
    fi

    # 5. git present
    if command -v git >/dev/null 2>&1; then
        _doctor_record "git" "pass" "$(git --version 2>/dev/null | awk '{print $3}')"
    else
        _doctor_record "git" "fail" "not found"
    fi

    # 6. gh present (optional)
    if command -v gh >/dev/null 2>&1; then
        _doctor_record "gh" "pass" "$(gh --version 2>/dev/null | head -1 | awk '{print $3}')"
    else
        _doctor_record "gh" "warn" "not found (optional)"
    fi

    # 6b. ast-grep present (optional — enables structural_scan)
    if command -v ast-grep >/dev/null 2>&1; then
        local ag_ver
        local ag_path
        ag_path=$(command -v ast-grep)
        ag_ver=$(ast-grep --version 2>/dev/null | awk '{print $NF}')
        _doctor_record "structural_scan" "pass" "enabled (ast-grep $ag_ver at $ag_path)"
    else
        _doctor_record "structural_scan" "warn" "disabled (ast-grep not found — install manually or run ./install.sh --with-ast-grep)"
    fi

    return 0
}

_doctor_check_storage() {
    # 7. Hot zone exists
    local hot_zone="${WV_HOT_ZONE:-}"
    if [ -z "$hot_zone" ]; then
        hot_zone=$(resolve_hot_zone 2>/dev/null)
    fi
    local runtime_label
    runtime_label=$(resolve_runtime_label 2>/dev/null || echo "native")
    case "$runtime_label" in
        codex)
            _doctor_record "runtime" "pass" \
                "sandbox-agent — using /tmp hot zone because /dev/shm may not persist between tool calls"
            ;;
        container)
            _doctor_record "runtime" "pass" \
                "container — using /tmp hot zone by default"
            ;;
        *)
            _doctor_record "runtime" "pass" "native"
            ;;
    esac
    if [ -d "$hot_zone" ]; then
        # 8. Hot zone space
        local avail_kb
        avail_kb=$(df -k "$hot_zone" 2>/dev/null | awk 'NR==2 {print $4}')
        local avail_mb=$((avail_kb / 1024))
        if check_free_space "$hot_zone"; then
            _doctor_record "hot zone" "pass" "$hot_zone (${avail_mb}MB free)"
        else
            _doctor_record "hot zone" "warn" "$hot_zone (${avail_mb}MB free — low)"
        fi
        # 8b. Orphan hot-zone count (dirs with no matching .repo_root owner)
        _doctor_check_hot_zone_orphans "$hot_zone"
        # 8c. This repo's brain.db under a placement root it does not use
        _doctor_check_hot_zone_shadow "$hot_zone"
        # 8d. The /tmp zone's two names and which is physical
        _doctor_check_hot_zone_names
    else
        _doctor_record "hot zone" "fail" "not found: $hot_zone"
    fi

    # 8c. Session phase file contains a known value
    local _phase_file="${hot_zone}/.session_phase"
    if [ -f "$_phase_file" ]; then
        local _phase_val
        _phase_val=$(cat "$_phase_file" 2>/dev/null | tr -d '[:space:]')
        local _phase_valid=false
        local _pv
        for _pv in ${PHASE_VALUES:-discover execute closing}; do
            [ "$_phase_val" = "$_pv" ] && _phase_valid=true && break
        done
        if [ "$_phase_valid" = true ]; then
            _doctor_record "session phase" "pass" "$_phase_val"
        else
            _doctor_record "session phase" "warn" "unknown value '$_phase_val' in .session_phase (expected: ${PHASE_VALUES:-discover execute closing})"
        fi
    fi

    # 9-10. Database accessible + integrity
    if [ -n "${WV_DB:-}" ] && [ -f "$WV_DB" ]; then
        local db_test
        db_test=$(sqlite3 "$WV_DB" "SELECT 1;" 2>/dev/null)
        if [ "$db_test" = "1" ]; then
            local integrity
            integrity=$(sqlite3 "$WV_DB" "PRAGMA integrity_check;" 2>/dev/null)
            if [ "$integrity" = "ok" ]; then
                _doctor_record "database" "pass" "accessible, integrity OK"
            else
                _doctor_record "database" "fail" "integrity check failed"
            fi
        else
            _doctor_record "database" "fail" "not accessible"
        fi
    else
        _doctor_record "database" "warn" "no active database"
    fi

    # 10a. Writer-lineage schema shape.
    #
    # PRAGMA integrity_check validates the pages against themselves; it says
    # nothing about whether the columns the delta writer needs are there. During
    # the rc.11 consumer outage (wv-e1556b) this command reported "database:
    # accessible, integrity OK" and passed 35 of 38 checks while every wv sync
    # aborted on `no such column: lineage_seq` — nodes was migrated, edges was
    # not, and nothing here looked. Shape is asked of db_lineage_shape, the same
    # classifier db_migrate_lineage repairs from, so doctor and the migration
    # cannot disagree about the database in front of them.
    if [ -n "${WV_DB:-}" ] && [ -f "$WV_DB" ]; then
        local _lin_nodes _lin_edges
        _lin_nodes=$(db_lineage_shape nodes)
        _lin_edges=$(db_lineage_shape edges)
        # One verdict for the pair, from the same classifier the migration uses.
        # Reading the two shapes independently — an `||` on no-table — passed a
        # database whose nodes were canonical and whose edges did not exist,
        # while sync aborted and commit-refs could not persist. A table that has
        # not been created is benign only when neither has.
        case "$(db_lineage_pair_verdict "$_lin_nodes" "$_lin_edges")" in
        canonical)
            _doctor_record "lineage schema" "pass" "nodes and edges carry (lineage_actor, lineage_seq)"
            ;;
        preinit)
            _doctor_record "lineage schema" "warn" "graph tables not created yet (nodes=$_lin_nodes, edges=$_lin_edges)"
            ;;
        *)
            _doctor_record "lineage schema" "fail" "nodes=$_lin_nodes, edges=$_lin_edges — sync and commit-refs cannot persist; recover with: rm -rf \"\$WV_HOT_ZONE\" && wv load"
            ;;
        esac
    fi

    # 10a'. Delta v2 catalog integrity.
    _doctor_check_delta_v2_catalog

    # 10b. FTS5 index integrity.
    #
    # rank=1 compares the external-content index WITH nodes, detecting missing
    # entries as well as stale ones (wv-ccd364). The plain self-check passed
    # both missing-entry and orphan incidents. Keep the orphan probe to name
    # the stranded-rowid class caused by INSERT OR REPLACE (wv-d2e6c6).
    if [ -n "${WV_DB:-}" ] && [ -f "$WV_DB" ]; then
        local fts5_ok fts5_orphans fts5_rc=0
        fts5_ok=$(sqlite3 "$WV_DB" \
            "INSERT INTO nodes_fts(nodes_fts,rank) VALUES('integrity-check',1);" 2>&1) || fts5_rc=$?
        fts5_orphans=$(sqlite3 "$WV_DB" \
            "CREATE VIRTUAL TABLE temp.wv_fv USING fts5vocab(main, nodes_fts, instance);
             SELECT count(DISTINCT doc) FROM temp.wv_fv
             WHERE doc NOT IN (SELECT rowid FROM nodes);" 2>/dev/null || echo "")
        [ -n "$fts5_orphans" ] || fts5_orphans=0
        if [ "$fts5_rc" -eq 0 ] && [ -z "$fts5_ok" ] && [ "$fts5_orphans" -eq 0 ] 2>/dev/null; then
            _doctor_record "FTS5 index" "pass" "integrity OK; index agrees with node content"
        else
            local _fts5_why="corrupt or inconsistent with node content"
            [ "$fts5_orphans" -gt 0 ] 2>/dev/null \
                && _fts5_why="${fts5_orphans} orphaned index entries (rowids with no node)"
            if [ "$_dr_repair" = "true" ]; then
                # 'rebuild' re-derives from nodes for an external-content table,
                # so it discards orphans outright.
                sqlite3 "$WV_DB" \
                    "INSERT INTO nodes_fts(nodes_fts) VALUES('rebuild');" 2>/dev/null
                local fts5_recheck fts5_orphans_recheck fts5_recheck_rc=0
                fts5_recheck=$(sqlite3 "$WV_DB" \
                    "INSERT INTO nodes_fts(nodes_fts,rank) VALUES('integrity-check',1);" 2>&1) || fts5_recheck_rc=$?
                fts5_orphans_recheck=$(sqlite3 "$WV_DB" \
                    "CREATE VIRTUAL TABLE temp.wv_fv2 USING fts5vocab(main, nodes_fts, instance);
                     SELECT count(DISTINCT doc) FROM temp.wv_fv2
                     WHERE doc NOT IN (SELECT rowid FROM nodes);" 2>/dev/null || echo "")
                [ -n "$fts5_orphans_recheck" ] || fts5_orphans_recheck=0
                if [ "$fts5_recheck_rc" -eq 0 ] && [ -z "$fts5_recheck" ] && [ "$fts5_orphans_recheck" -eq 0 ] 2>/dev/null; then
                    _doctor_record "FTS5 index" "pass" "repaired (rebuilt)"
                else
                    _doctor_record "FTS5 index" "fail" "repair failed — manual: wv reindex"
                fi
            else
                _doctor_record "FTS5 index" "fail" "${_fts5_why} — run: wv doctor --repair"
            fi
        fi
    fi

    # 10c. FTS5 learning-index integrity (wv-ddb359: nodes_learning_fts is a
    # separate FTS5 table from nodes_fts, checked in 10b -- a corruption
    # confined to it is otherwise invisible to both PRAGMA integrity_check
    # and 10b's nodes_fts-only check. Repair is DROP + recreate, not
    # 'rebuild': nodes_learning_fts owns its content in its own shadow
    # table (unlike nodes_fts's content=nodes), so 'rebuild' would only
    # re-derive the index FROM that shadow table and preserve any
    # corruption living there. See db_reindex_fts5.
    if [ -n "${WV_DB:-}" ] && [ -f "$WV_DB" ]; then
        local learning_fts5_available
        learning_fts5_available=$(sqlite3 "$WV_DB" \
            "SELECT sqlite_compileoption_used('ENABLE_FTS5');" 2>/dev/null || echo "0")
        if [ "$learning_fts5_available" = "1" ]; then
            local learning_table_exists learning_fts_ok
            learning_table_exists=$(sqlite3 "$WV_DB" \
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='nodes_learning_fts';" 2>/dev/null)
            if [ "$learning_table_exists" = "1" ]; then
                learning_fts_ok=$(sqlite3 "$WV_DB" \
                    "INSERT INTO nodes_learning_fts(nodes_learning_fts) VALUES('integrity-check');" 2>&1)
            else
                # A missing table is itself the failure signal here (db_ensure
                # keeps it present via db_migrate_fts5_learning's CREATE IF NOT
                # EXISTS) -- not a reason to skip the check, or the exact
                # dropped-table corruption class this check exists for goes
                # undetected.
                learning_fts_ok="missing: nodes_learning_fts table does not exist"
            fi
            if [ -z "$learning_fts_ok" ]; then
                _doctor_record "FTS5 learning index" "pass" "integrity OK"
            else
                if [ "$_dr_repair" = "true" ]; then
                    sqlite3 "$WV_DB" "DROP TABLE IF EXISTS nodes_learning_fts;" 2>/dev/null
                    db_migrate_fts5_learning
                    local learning_recheck
                    learning_recheck=$(sqlite3 "$WV_DB" \
                        "INSERT INTO nodes_learning_fts(nodes_learning_fts) VALUES('integrity-check');" 2>&1)
                    if [ -z "$learning_recheck" ]; then
                        _doctor_record "FTS5 learning index" "pass" "repaired (dropped + rebuilt)"
                    else
                        _doctor_record "FTS5 learning index" "fail" "repair failed — manual: wv reindex"
                    fi
                else
                    _doctor_record "FTS5 learning index" "fail" "corrupt or missing — run: wv doctor --repair"
                fi
            fi
        fi
    fi

    return 0
}

# _hook_common_named <file> — the file exists and one of its executable lines
# (not a comment) names wv-hook-common. One process: grep -v | grep -q under
# pipefail reads a long file's early match as failure, the writer taking SIGPIPE.
_hook_common_named() { # predicate
    [ -f "$1" ] && awk '!/^[[:space:]]*#/ && /wv-hook-common/ { found = 1; exit } END { exit !found }' "$1"
}

# _hook_common_unwired <project-root> — the required Claude Code hooks that do
# not load wv-hook-common, one path per line, relative to the root. A hook
# passes when an executable line names it, or when the hook sources a library
# whose executable lines do: since cf8ff1425 the lifecycle and tool-use hooks
# are thin adapters and their library loads it (owner ruling on wv-b80a86). A
# library resolves as the adapters resolve it: ../lib beside the hook, the
# checkout's scripts/lib, then the installed ~/.config/weave/lib. Comments do
# not count; pre-action.sh passed on one before. Shared by wv doctor and
# pattern-audit Check 4.
_hook_common_unwired() {
    local root="$1" rel hook lib dir
    for rel in .claude/hooks/pre-action.sh .claude/hooks/session-start-context.sh \
        .claude/hooks/session-end-sync.sh .claude/hooks/stop-check.sh \
        .claude/hooks/pre-compact-context.sh .claude/hooks/wv-touched-files.sh \
        .claude/hooks/context-guard.sh; do
        hook="$root/$rel"
        _hook_common_named "$hook" && continue
        if [ -f "$hook" ]; then
            for lib in $(grep -v '^[[:space:]]*#' "$hook" \
                | grep -E '(^|[[:space:];&|])(\.|source)[[:space:]]' \
                | grep -oE 'wv-[a-z0-9-]+\.sh' | sort -u); do
                for dir in "${hook%/*}/../lib" "$root/scripts/lib" "${HOME}/.config/weave/lib"; do
                    [ -r "$dir/$lib" ] || continue
                    _hook_common_named "$dir/$lib" && continue 3
                    break
                done
            done
        fi
        echo "$rel"
    done
}

_doctor_check_repository_state() {
    # Ownership is actor identity, not session isolation. Other actors may be
    # working legitimately; even --repair must leave their claims untouched.
    local claim_actor claim_rows
    claim_actor=$(resolve_agent_id)
    if [ ! -f "${WV_DB:-}" ]; then
        _doctor_record "claim ownership" "warn" "current actor: $claim_actor; unavailable: no active database"
    elif ! claim_rows=$(db_query "SELECT id || ': ' || json_extract(metadata, '$.claimed_by')
        FROM nodes WHERE status='active'
        AND COALESCE(json_extract(metadata, '$.claimed_by'), '') != ''
        AND json_extract(metadata, '$.claimed_by') != '$(sql_escape "$claim_actor")'
        ORDER BY id;" 2>/dev/null); then
        _doctor_record "claim ownership" "warn" "current actor: $claim_actor; unavailable: active claim query failed"
    elif [ -n "$claim_rows" ]; then
        _doctor_record "claim ownership" "warn" "current actor: $claim_actor; active claims held by other actors (advisory):
$claim_rows
Inspect before explicitly authorizing per-node takeover with wv work ID --force; reservations still apply. No claims migrated."
    else
        _doctor_record "claim ownership" "pass" "current actor: $claim_actor; no active claims held by other actors"
    fi

    # 11-12. Module checks
    # Derived, not typed (wv-587469): the typed lists named 12 libraries and 5
    # of the 10 command modules, so a missing findings/analyze/indexer/query/hook
    # module, wv-gate-pool.sh or wv-checkpoint-ci.sh passed.
    _doctor_check_lib_refs "lib modules"
    _doctor_check_cmd_defs "cmd modules"

    # S0 provisioning advisory: inspect literals, never execute routed scripts.
    local gate_paths
    if ! gate_paths=$(python3 -I "$WV_LIB_DIR/lib/wv-gate-paths.py" "$REPO_ROOT" 2>&1); then
        _doctor_record "gate ignored paths" "warn" "$gate_paths"
    elif [ -n "$gate_paths" ]; then
        _doctor_record "gate ignored paths" "warn" "$gate_paths"
    else
        _doctor_record "gate ignored paths" "pass" "no literal ignored-path references found; computed paths are not evaluated"
    fi

    # 12b. Hook-common wiring check (Sprint 1 pattern crystallization); the
    # rule is _hook_common_unwired's, shared with pattern-audit Check 4.
    local _doctor_hooks_total=7
    local _doctor_hooks_ok=0
    local _doctor_hooks_missing=""
    local _doctor_project_root
    _doctor_project_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    if [ -n "$_doctor_project_root" ] && [ -d "$_doctor_project_root/.claude/hooks" ]; then
        local _doctor_unwired
        _doctor_unwired=$(_hook_common_unwired "$_doctor_project_root")
        _doctor_hooks_ok=$((_doctor_hooks_total - $(grep -c . <<< "$_doctor_unwired")))
        _doctor_hooks_missing=$(paste -sd, - <<< "$_doctor_unwired" | sed 's/,/, /g')
        if [ "$_doctor_hooks_ok" -eq "$_doctor_hooks_total" ]; then
            _doctor_record "hook-common wiring" "pass" "$_doctor_hooks_ok/$_doctor_hooks_total hooks source wv-hook-common.sh"
        else
            _doctor_record "hook-common wiring" "warn" "$_doctor_hooks_ok/$_doctor_hooks_total hooks wired (missing: $_doctor_hooks_missing)"
        fi
    fi

    # 13. .weave dir
    if [ -d "${WEAVE_DIR:-}" ]; then
        _doctor_record ".weave" "pass" "present"
    else
        _doctor_record ".weave" "warn" "not found"
    fi

    # 14. Journal health: check for incomplete operations
    if journal_has_incomplete 2>/dev/null; then
        local journal_info
        journal_info=$(journal_recover --json 2>/dev/null || echo '{}')
        local journal_op
        journal_op=$(echo "$journal_info" | jq -r '.operation.op // "unknown"' 2>/dev/null)
        _doctor_record "journal" "warn" "incomplete '$journal_op' operation — run 'wv recover'"
    else
        _doctor_record "journal" "pass" "clean (no incomplete operations)"
    fi

    # 14a. Node-state advisory: deferral-metadata-vs-status divergence. Per-install
    # mirror of pattern-audit Check 6 — a todo node carrying active deferral metadata
    # (deferred/blocked_until/blocked_on) with no non-done blocks edge, so status does
    # not reflect the deferral. A parked node (deferred with a deferred_reason) is a
    # todo state by design and is not counted (wv-5515e9). Both reports share
    # wv_deferral_divergent_sql. Advisory only.
    # See docs/PROPOSAL-graph-as-policy-boundary.md.
    if [ -f "${WV_DB:-}" ]; then
        local _deferred_ready
        _deferred_ready=$(db_query "
            SELECT COUNT(*) FROM nodes n WHERE $(wv_deferral_divergent_sql n);
        " 2>/dev/null || echo "0")
        if [ "${_deferred_ready:-0}" -gt 0 ] 2>/dev/null; then
            _doctor_record "node-state" "warn" "$_deferred_ready node(s) carry deferral metadata while status='todo' — status must reflect it; see 'wv pattern-audit' (Check 6); fix with status=blocked-external, a blocks edge, or park it with a deferred_reason"
        else
            _doctor_record "node-state" "pass" "no deferral-metadata-vs-status divergence"
        fi
        _doctor_check_edge_invariants
    fi

    # 14a-bis. Duplicate-authoritative-memory risk: durable Claude/Codex harness
    # memory for this repo not represented in the graph (S5, generalized F1).
    _doctor_memory_authority
    # Memory budget and expiry (wv-986c3d): wv-cmd-graduate.sh loads only when
    # the graph holds an active memory.
    [ -z "$( [ -f "${WV_DB:-}" ] && db_query "SELECT 1 FROM nodes WHERE $(wv_kind_sql) = 'memory'
        AND COALESCE(json_extract(metadata,'\$.mem_status'),'active') = 'active' LIMIT 1;" 2>/dev/null)" ] \
        || _doctor_memory_budget

    # 14a-quinquies. Can this install report which fixes it carries?
    _doctor_install_provenance

    # 14a-quater. Commit-provenance drift: SHAs recorded on nodes that no ref
    # reaches any more (amended/reset/rebased/gc'd) -- wv-55d2de.
    _doctor_commit_refs

    # 14a-ter. Managed pattern-rule shadow advisory: mirrors 'wv quality
    # patterns list' own warning (a project-local custom rule sharing a
    # managed rule's id, silently never applied -- see
    # scripts/weave_quality/__main__.py's _shadowed_managed_pattern_ids)
    # without re-deriving the detection logic here (wv-3a0a40) -- invokes
    # the SAME Python entry point patterns list itself uses
    # (_wv_quality_python, sourced from wv-cmd-quality.sh) and captures
    # its own stderr, where that command already prints the warning
    # unconditionally in both --json and text mode. Gated on the
    # .overridden marker file's own existence first (cheap short-circuit
    # -- _shadowed_managed_pattern_ids returns immediately without it
    # too, but this also skips the rule-load work entirely on a repo with
    # no managed-pattern reconcile history at all). Advisory only.
    if [ -f "${WEAVE_DIR:-}/patterns/managed/.overridden" ]; then
        local -a _shadow_py_args=()
        [ -n "$WV_HOT_ZONE" ] && _shadow_py_args+=("--hot-zone" "$WV_HOT_ZONE")
        _shadow_py_args+=("patterns" "list" "--json")
        # Capture ONLY stderr (2>&1 duplicates fd2 into the command-
        # substitution's own capture pipe BEFORE >/dev/null retargets fd1
        # away from it -- no external pipe to grep involved, so $? below
        # is _wv_quality_python's own exit status, not a pipeline tail's
        # (see feedback_pipe_masks_exit_code) -- capturing an unpiped
        # status is exactly why this doesn't reuse the piped form the
        # first version of this check had.
        local _shadow_stderr
        _shadow_stderr=$(_wv_quality_python "${_shadow_py_args[@]}" 2>&1 >/dev/null)
        local _shadow_status=$?
        if [ "$_shadow_status" -ne 0 ]; then
            # wv-92ca0e: a failed delegate means shadowing was never
            # actually evaluated -- never report pass for an unevaluated
            # check (e.g. a malformed local rule breaks patterns list
            # entirely, well before it would even reach shadow detection).
            _doctor_record "pattern-shadow" "warn" "could not evaluate managed-rule shadowing -- 'wv quality patterns list' failed (exit $_shadow_status); run it directly for detail"
        elif grep -q "shadows an available" <<< "$_shadow_stderr"; then
            local _shadow_count
            _shadow_count=$(echo "$_shadow_stderr" | grep -c "shadows an available")
            _doctor_record "pattern-shadow" "warn" "$_shadow_count managed rule(s) shadowed by a local copy — run 'wv quality patterns list' for detail"
        else
            _doctor_record "pattern-shadow" "pass" "no managed-rule shadowing detected"
        fi
    fi

    # 14a-ter-bis. Managed pattern-rule completeness (wv-8d16bd, external
    # code review round 3 re-audit): a manifest id whose file exists in
    # NEITHER tier (managed/ nor the project-local override) is not
    # shadowed, it is MISSING -- exactly the state left behind by deleting
    # a shadowing local copy without rerunning 'wv init-repo --update'
    # afterward (24 rules -> 23 in the reported audit). The pattern-shadow
    # check above only re-derives cmd_patterns_list's OWN warning, which
    # stops firing entirely once the id drops out of active_ids -- it
    # would report a false "pass" for a rule that quietly vanished.
    # Checked against the union of .overridden (shadowed ids) and
    # .manifest (currently-synced ids) -- every id either reconcile has
    # ever placed or knowingly skipped; both already store the bare
    # "<id>.yaml" filename.
    if [ -f "${WEAVE_DIR:-}/patterns/managed/.overridden" ] || [ -f "${WEAVE_DIR:-}/patterns/managed/.manifest" ]; then
        local _mc_missing="" _mc_id
        while IFS= read -r _mc_id; do
            [ -z "$_mc_id" ] && continue
            if [ ! -f "${WEAVE_DIR:-}/patterns/managed/$_mc_id" ] && [ ! -f "${WEAVE_DIR:-}/patterns/$_mc_id" ]; then
                _mc_missing="${_mc_missing:+$_mc_missing, }${_mc_id%.yaml}"
            fi
        done < <(cat "${WEAVE_DIR:-}/patterns/managed/.overridden" "${WEAVE_DIR:-}/patterns/managed/.manifest" 2>/dev/null | sort -u)
        if [ -n "$_mc_missing" ]; then
            _doctor_record "managed-pattern-completeness" "warn" "manifest id(s) missing from BOTH the managed and custom tiers (deleted without a resync?): $_mc_missing — run 'wv init-repo --update'"
        else
            _doctor_record "managed-pattern-completeness" "pass" "every known managed-pattern id resolves in one tier"
        fi
    fi

    # 14a-quinquies. Coaching guide advisories, mirroring the managed-pattern
    # family above. A project override under .weave/guides/ outranks the package
    # guide of the same id, so a stale override silently outranks an improved one
    # indefinitely -- the same failure the pattern-shadow record exists to surface.
    if [ -d "${WEAVE_DIR:-}/guides" ]; then
        local _gs_shadowed="" _gs_file _gs_name _gs_pkg
        _gs_pkg="$(_wv_python_module_path weave_quality 2>/dev/null)/weave_quality/guides"
        for _gs_file in "${WEAVE_DIR:-}"/guides/*.md; do
            [ -f "$_gs_file" ] || continue
            _gs_name="$(basename "$_gs_file")"
            [ -f "$_gs_pkg/$_gs_name" ] || continue
            _gs_shadowed="${_gs_shadowed:+$_gs_shadowed, }${_gs_name%.md}"
        done
        if [ -n "$_gs_shadowed" ]; then
            _doctor_record "guide-shadow" "warn" "project guide(s) shadowing a package guide of the same id: $_gs_shadowed — confirm the override is still wanted"
        else
            _doctor_record "guide-shadow" "pass" "no project guide is shadowing a package guide"
        fi
    fi

    # Guide validity and coaching completeness (wv-7730bd), computed by the
    # shipped parser and resolver ('python3 -m weave_quality.guides doctor') from
    # the module copy coaching selects, against this project's root -- never a
    # second validator in shell. Validity (every .weave/guides/*.md parses and
    # resolves where it is selected) is recorded apart from guide-shadow, a
    # preference, and from completeness, the canonical types that coach only
    # through _uncoached. Both records fail closed: a nonzero exit, output that
    # is not a complete report, or a report from a module copy other than the
    # one selected is a failed check, never a skipped one. Complete means every
    # entry has its shape too, and the verdicts come from the arrays' lengths:
    # judged by the rendered names, invalid:[{}] or fallback_only:[null]
    # rendered nothing and both records passed (wv-13dec1).
    local _gd_pypath _gd_out _gd_rc=0 _gd_err="" _gd_want _gd_got
    _gd_pypath="$(_wv_python_module_path weave_quality 2>/dev/null)"
    _gd_out=$(_wv_agent_python_exec_module weave_quality.guides "$_gd_pypath" \
        doctor --project-root "$REPO_ROOT" 2>/dev/null) || _gd_rc=$?
    if [ "$_gd_rc" -ne 0 ]; then
        _gd_err="guides doctor exited $_gd_rc: $(printf '%s' "$_gd_out" | jq -r '.error // "no error reported"' 2>/dev/null || printf 'no error reported')"
    elif ! printf '%s' "$_gd_out" | jq -e '
            def str: type == "string" and length > 0;
            def count: type == "number" and . >= 0 and . == floor;
            (.canonical_types | count) and .canonical_types > 0
            and (.project_guides_checked | count)
            and (.invalid | type == "array"
                and all(.[]; type == "object" and (.file | str) and (.error | str)
                    and (.errors | type == "array" and length > 0 and all(.[]; str))))
            and (.unresolved | type == "array"
                and all(.[]; type == "object" and (.violation_type | str)
                    and (.language == null or (.language | str)) and (.error | str)))
            and all(.unused, .examples, .fallback_only; type == "array" and all(.[]; str))
            and (.module | str)' >/dev/null 2>&1; then
        _gd_err="guides doctor printed no complete report"
    else
        _gd_want=$(readlink -f "$_gd_pypath/weave_quality/guides.py" 2>/dev/null || true)
        _gd_got=$(printf '%s' "$_gd_out" | jq -r '.module')
        [ -n "$_gd_want" ] && [ "$_gd_got" = "$_gd_want" ] \
            || _gd_err="guides doctor ran $_gd_got, not the selected copy ${_gd_want:-(unresolved under $_gd_pypath)}"
    fi
    local _gd_bad _gd_unused _gd_n _gd_canon _gd_fallback _gd_dead _gd_counts
    local _gd_nbad _gd_nunused _gd_nfallback
    if [ -z "$_gd_err" ]; then
        # One read, checked: a failed extraction is a failed check, not a
        # zero count.
        _gd_counts=$(printf '%s' "$_gd_out" | jq -r '[(.invalid | length) + (.unresolved | length),
            (.unused | length), (.fallback_only | length),
            ([.unresolved[] | select(.language == null)] | length),
            .project_guides_checked, .canonical_types] | @tsv' 2>/dev/null) \
            && read -r _gd_nbad _gd_nunused _gd_nfallback _gd_dead _gd_n _gd_canon <<< "$_gd_counts" \
            && [ -n "$_gd_canon" ] \
            || _gd_err="guides doctor report could not be read"
    fi
    if [ -n "$_gd_err" ]; then
        _doctor_record "guide-validity" "fail" "$_gd_err"
        _doctor_record "guide-completeness" "fail" "not computed: $_gd_err"
    else
        # Each failure carries the parser's own error, which names the field or
        # section. A list of file names alone left a consumer whose pre-rc.14
        # guide failed with nothing to fix (wv-ba21bd), and every violation in
        # the file, not the first: one fault per run cost a consumer three
        # runs on one guide (wv-273b2d).
        _gd_bad=$(printf '%s' "$_gd_out" | jq -r '[(.invalid[] | .file as $f
                | .errors[] | if startswith($f + ":") then . else $f + ": " + . end),
            (.unresolved[] | .violation_type + (if .language then " (" + .language + ")" else "" end)
                + ": " + .error)] | join("; ")')
        _gd_unused=$(printf '%s' "$_gd_out" | jq -r '.unused | join(", ")')
        if [ "$_gd_nbad" -gt 0 ]; then
            _doctor_record "guide-validity" "fail" "coaching would fail for: $_gd_bad — fix the named field or section, or remove the guide (format: .weave/guides.README.md)"
        elif [ "$_gd_nunused" -gt 0 ]; then
            _doctor_record "guide-validity" "warn" "project guide(s) no catalogued type selects: $_gd_unused — rename to the vocabulary's guide basename or remove"
        else
            _doctor_record "guide-validity" "pass" "$_gd_n project guide(s) checked; each parses and resolves where it is selected"
        fi
        _gd_fallback=$(printf '%s' "$_gd_out" | jq -r '.fallback_only | join(", ")')
        if [ "$_gd_dead" -gt 0 ]; then
            _doctor_record "guide-completeness" "fail" "$_gd_dead of $_gd_canon canonical violation type(s) resolve to no guide (see guide-validity)"
        elif [ "$_gd_nfallback" -gt 0 ]; then
            _doctor_record "guide-completeness" "warn" "canonical violation type(s) coaching only through the _uncoached fallback: $_gd_fallback"
        else
            _doctor_record "guide-completeness" "pass" "all $_gd_canon canonical violation types coach through a guide of their own"
        fi
    fi

    # 14a-quater. Procedure visibility semantic-drift advisory: local is the
    # safe default, but a local procedure that documents the installed `wv`
    # command may actually describe consumer behavior and warrants periodic
    # review for promotion to shared. Scan body content only so the required
    # frontmatter fallback (`wv guide --procedure=...`) does not self-match.
    # Repository-development invocations (`./scripts/wv`) are intentionally
    # excluded. Advisory only.
    local _pv_drift
    _pv_drift=$(_doctor_local_procedure_command_refs "${WV_CONFIG_DIR:-$HOME/.config/weave}/procedures")
    if [ -n "$_pv_drift" ]; then
        _doctor_record "procedure-visibility" "warn" "local procedure(s) reference consumer wv commands: $_pv_drift — review visibility: shared"
    else
        _doctor_record "procedure-visibility" "pass" "no local procedures reference consumer wv commands"
    fi
    # Repository-owned procedures (wv-fc71f0): wv-cmd-procedures.sh loads only
    # when the repository has some.
    ! compgen -G "${REPO_ROOT:-/nonexistent}/.weave/procedures/*.md" >/dev/null || _doctor_repo_procedures "$REPO_ROOT"

    # 14a-quinquies. Closed-node uncommitted dirt attribution (wv-e48993):
    # pre-close-verification.sh now scopes its blocking check to the closing
    # node's OWN touched_files, so genuinely foreign dirt no longer blocks
    # `wv done` (and is no longer misattributed under the wrong node's
    # Weave-ID). That fixed the false-block/misattribution bug, but it also
    # means a session can close every node it owns and still leave real work
    # uncommitted with nothing reporting it afterward -- this check closes
    # that gap. Advisory only; attributes current non-.weave dirt to the
    # most recently closed node whose touched_files overlaps it, when one
    # exists.
    local _cd_dirty
    # --no-renames (wv-b96ada): a staged rename lists only its new path, so the
    # old path - the one a closed node touched - never reached attribution.
    _cd_dirty=$(
        {
            git diff --no-renames --name-only 2>/dev/null
            git diff --no-renames --cached --name-only 2>/dev/null
            git ls-files --others --exclude-standard 2>/dev/null
        } | sort -u | grep -v '^$' \
          | grep -v '^\.weave/' \
          | grep -v '^\.claude/hooks/' \
          | grep -v '^\.claude/skills/' \
          | grep -v '^\.claude/agents/' || true
    )
    if [ -z "$_cd_dirty" ]; then
        _doctor_record "closed-node-dirt" "pass" "no uncommitted non-.weave files"
    else
        local _cd_count _cd_active_owned _cd_remainder _cd_remainder_count
        local _cd_done_owned _cd_done_remainder _cd_unattributed
        _cd_count=$(echo "$_cd_dirty" | grep -c .)
        # wv-822bea/wv-950080 (distribution re-audit): the prior "stop at the
        # first candidate node whose touched_files overlaps ANY dirty path"
        # logic false-passed a mixed dirty set (e.g. one file explained by an
        # active node, a second file that is genuinely done-owned or
        # unattributed) as soon as the active node matched, without ever
        # looking at whether it explained the REST of the dirt. It also used
        # `grep -Ff` (substring) rather than exact path equality, so
        # ownership of "foo" could wrongly explain "foo.txt". Fixed: build
        # the full set of paths owned by ANY currently-active node (union of
        # the uncapped node_files table and the capped metadata.touched_files
        # display copy, exact-line matched via comm), subtract that from the
        # dirty set, and only classify what's LEFT — never short-circuit on
        # the first match.
        _cd_active_owned=$(db_query "
            SELECT nf.path FROM node_files nf JOIN nodes n ON n.id = nf.node_id WHERE n.status='active'
            UNION
            SELECT je.value FROM nodes n, json_each(COALESCE(json_extract(n.metadata,'\$.touched_files'), '[]')) je WHERE n.status='active';
        " 2>/dev/null | sort -u)
        _cd_remainder=$(comm -23 <(printf '%s\n' "$_cd_dirty" | sort -u) <(printf '%s\n' "$_cd_active_owned" | sort -u))
        if [ -z "$_cd_remainder" ]; then
            _doctor_record "closed-node-dirt" "pass" "all $_cd_count uncommitted non-.weave file(s) explained by currently active node(s) own work"
        else
            _cd_remainder_count=$(echo "$_cd_remainder" | grep -c .)
            _cd_done_owned=$(db_query "
                SELECT nf.path FROM node_files nf JOIN nodes n ON n.id = nf.node_id WHERE n.status='done'
                UNION
                SELECT je.value FROM nodes n, json_each(COALESCE(json_extract(n.metadata,'\$.touched_files'), '[]')) je WHERE n.status='done';
            " 2>/dev/null | sort -u)
            _cd_done_remainder=$(comm -12 <(printf '%s\n' "$_cd_remainder" | sort -u) <(printf '%s\n' "$_cd_done_owned" | sort -u))
            _cd_unattributed=$(comm -23 <(printf '%s\n' "$_cd_remainder" | sort -u) <(printf '%s\n' "$_cd_done_owned" | sort -u))
            if [ -n "$_cd_done_remainder" ] && [ -n "$_cd_unattributed" ]; then
                _doctor_record "closed-node-dirt" "warn" "$_cd_remainder_count non-.weave file(s) uncommitted beyond any active node's own work: $(echo "$_cd_done_remainder" | grep -c .) likely from already-closed node(s) (touched_files/node_files overlap), $(echo "$_cd_unattributed" | grep -c .) with no clear owner — commit or discard"
            elif [ -n "$_cd_done_remainder" ]; then
                _doctor_record "closed-node-dirt" "warn" "$_cd_remainder_count non-.weave file(s) still uncommitted beyond any active node's own work, likely from already-closed node(s) (touched_files/node_files overlap) — commit or discard"
            else
                _doctor_record "closed-node-dirt" "warn" "$_cd_remainder_count non-.weave file(s) still uncommitted with no clear owner among active/done nodes — commit or discard"
            fi
        fi
    fi

    # 14b. Explicit git-state pending windows (.weave dirty / ahead of upstream)
    local git_pending_json git_sync_pending git_sync_state git_sync_action git_sync_reason git_sync_hint
    git_pending_json=$(_detect_git_pending 2>/dev/null || echo '{}')
    git_sync_pending=$(echo "$git_pending_json" | jq -r '.pending // false' 2>/dev/null || echo "false")
    git_sync_state=$(echo "$git_pending_json" | jq -r '.state // "clean"' 2>/dev/null || echo "clean")
    git_sync_action=$(echo "$git_pending_json" | jq -r '.action // "none"' 2>/dev/null || echo "none")
    git_sync_reason=$(echo "$git_pending_json" | jq -r '.reason // "clean"' 2>/dev/null || echo "clean")
    git_sync_hint=$(echo "$git_pending_json" | jq -r '.hint // "no action required"' 2>/dev/null || echo "no action required")
    if [ "$git_sync_pending" = "true" ]; then
        if [ "$git_sync_state" = "recoverable" ]; then
            _doctor_record "git sync" "warn" "$git_sync_action ($git_sync_reason) — $git_sync_hint"
        else
            _doctor_record "git sync" "warn" "$git_sync_state ($git_sync_reason) — $git_sync_hint"
        fi
    else
        _doctor_record "git sync" "pass" "clean"
    fi

    return 0
}

_doctor_check_surfaces() {
    # ── Surface-contract checks ──────────────────────────────────────────────

    # 15. Hook source vs installed drift: compare .claude/hooks/ with ~/.config/weave/hooks/
    local source_hooks_dir="${WEAVE_DIR:+$(dirname "$WEAVE_DIR")}/.claude/hooks"
    # Fallback: walk up from WV_LIB_DIR to find .claude/hooks
    if [ ! -d "$source_hooks_dir" ] && [ -n "${WV_LIB_DIR:-}" ]; then
        local candidate
        candidate=$(dirname "$WV_LIB_DIR")
        [ -d "$candidate/.claude/hooks" ] && source_hooks_dir="$candidate/.claude/hooks"
    fi
    local installed_hooks_dir="$HOME/.config/weave/hooks"
    if [ -d "$source_hooks_dir" ] && [ -d "$installed_hooks_dir" ]; then
        local drifted=""
        # Forward: repo-local hooks stale vs installed (catches wv self-update without init-repo --update)
        for src in "$source_hooks_dir"/*.sh; do
            local fname
            fname=$(basename "$src")
            local dst="$installed_hooks_dir/$fname"
            if [ ! -f "$dst" ]; then
                drifted="${drifted:+$drifted, }$fname (missing)"
            elif [ "$(md5sum "$src" 2>/dev/null | awk '{print $1}')" != "$(md5sum "$dst" 2>/dev/null | awk '{print $1}')" ]; then
                drifted="${drifted:+$drifted, }$fname (stale)"
            fi
        done
        # Reverse: new hooks in installed not yet in repo (added in a newer release)
        for dst in "$installed_hooks_dir"/*.sh; do
            local fname
            fname=$(basename "$dst")
            [ -f "$source_hooks_dir/$fname" ] || \
                drifted="${drifted:+$drifted, }$fname (new — not in repo)"
        done
        if [ -z "$drifted" ]; then
            _doctor_record "hook drift" "pass" "source and installed hooks match"
        else
            if [ "$_dr_repair" = "true" ]; then
                local _repaired=0
                for src in "$installed_hooks_dir"/*.sh; do
                    [ -f "$src" ] || continue
                    local _fname
                    _fname=$(basename "$src")
                    cp "$src" "$source_hooks_dir/$_fname" && _repaired=$((_repaired + 1))
                done
                _doctor_record "hook drift" "pass" "repaired ($_repaired hooks synced from ~/.config/weave/hooks/)"
            else
                _doctor_record "hook drift" "warn" "run: wv init-repo --update — drifted: $drifted"
            fi
        fi
    else
        _doctor_record "hook drift" "warn" "cannot compare — source or installed hooks dir missing"
    fi

    # 16. wv-runtime wrapper retired (S2) — standalone repo uses python -m weave_runtime
    _doctor_record "wv-runtime" "pass" "retired — use python -m weave_runtime (standalone repo)"

    # 17. Git commit hooks installed and match the repo-managed Weave versions
    local git_root
    git_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    # Checked where git runs hooks from (wv-76c726): $git_root/.git/hooks is
    # wrong in a linked worktree (.git is a file) and under core.hooksPath.
    local _dr_hooks="" _dr_hooks_path=""
    if [ -n "$git_root" ]; then
        _dr_hooks=$(git -C "$git_root" rev-parse --git-path hooks 2>/dev/null || true)
        case "$_dr_hooks" in ""|/*) ;; *) _dr_hooks="$git_root/$_dr_hooks" ;; esac
        _dr_hooks_path=$(git -C "$git_root" config --get core.hooksPath 2>/dev/null || true)
        if [ -n "$_dr_hooks_path" ]; then
            _doctor_record "hooks path" "warn" "core.hooksPath=$_dr_hooks_path: git runs hooks only from there and install.sh does not write to it — call the Weave hooks from it"
        fi
    fi
    if [ -n "$git_root" ] && [ -n "$_dr_hooks" ]; then
        _doctor_check_git_hook \
            "pre-commit hook" \
            "$git_root/scripts/hooks/pre-commit-weave.sh" \
            "$_dr_hooks/pre-commit" \
            "Weave pre-commit" \
            "install -m 755 scripts/hooks/pre-commit-weave.sh $_dr_hooks/pre-commit"
        _doctor_check_git_hook \
            "prepare-commit-msg hook" \
            "$git_root/scripts/hooks/prepare-commit-msg-weave.sh" \
            "$_dr_hooks/prepare-commit-msg" \
            "Weave: append Weave-ID trailers" \
            "install -m 755 scripts/hooks/prepare-commit-msg-weave.sh $_dr_hooks/prepare-commit-msg"
        # post-commit was retired (wv-56c823): a Weave copy still installed runs
        # the dead deferred-suite queue on every commit. A custom hook is not ours.
        local _dr_pc_hook
        _dr_pc_hook="$_dr_hooks/post-commit"
        if [ -f "$_dr_pc_hook" ] && grep -qF "Weave post-commit" "$_dr_pc_hook" 2>/dev/null; then
            _doctor_record "post-commit hook" "warn" "retired Weave post-commit hook still installed — run ./install.sh (dev repo) or wv init-repo --update"
        fi
        # The heavy tier (wv-862ac0): without it installed, pre-commit runs the
        # [heavy] suites itself, so a missing copy is slow, not unsafe.
        _doctor_check_git_hook \
            "pre-push hook" \
            "$git_root/scripts/hooks/pre-push-weave.sh" \
            "$_dr_hooks/pre-push" \
            "Weave pre-push" \
            "install -m 755 scripts/hooks/pre-push-weave.sh $_dr_hooks/pre-push"
        # Binds a commit's publication to the tree pre-commit judged
        # (wv-5f9d1c): without it, pre-commit admission is check-then-use.
        _doctor_check_git_hook \
            "reference-transaction hook" \
            "$git_root/scripts/hooks/reference-transaction-weave.sh" \
            "$_dr_hooks/reference-transaction" \
            "Weave reference-transaction" \
            "install -m 755 scripts/hooks/reference-transaction-weave.sh $_dr_hooks/reference-transaction"
    fi

    # 18. Ghost settings: check for chat.hooks.enabled in .vscode/settings.json
    if [ -n "$git_root" ] && [ -f "$git_root/.vscode/settings.json" ]; then
        if grep -q '"chat.hooks.enabled"' "$git_root/.vscode/settings.json" 2>/dev/null; then
            _doctor_record "ghost settings" "warn" '.vscode/settings.json contains chat.hooks.enabled — may interfere with Claude Code hooks'
        else
            _doctor_record "ghost settings" "pass" "no known ghost settings detected"
        fi
    fi

    # 19. Claude settings hook matcher coverage (PreToolUse covers Edit/Write/Bash)
    local claude_settings="$HOME/.claude/settings.json"
    if [ -f "$claude_settings" ]; then
        local matcher
        matcher=$(jq -r '.hooks.PreToolUse[]? | select(.hooks[]?.command | contains("pre-action")) | .matcher // ""' "$claude_settings" 2>/dev/null | head -1)
        if [ -n "$matcher" ]; then
            local missing_tools=""
            for tool in Edit Write Bash; do
                grep -q -- "$tool" <<< "$matcher" || missing_tools="${missing_tools:+$missing_tools, }$tool"
            done
            if [ -z "$missing_tools" ]; then
                _doctor_record "hook matchers" "pass" "Edit, Write, Bash covered"
            else
                _doctor_record "hook matchers" "warn" "missing: $missing_tools — run ./install.sh"
            fi
        else
            _doctor_record "hook matchers" "warn" "pre-action hook not registered in ~/.claude/settings.json — run ./install.sh"
        fi
    fi

    # 20. Installed lib vs source drift (only when installed from a local git clone)
    _doctor_check_install_drift

    # 21. Active wv provenance vs recommended repo-local wrapper
    local _dr_repo_wv _dr_invoked_wv _dr_provenance _dr_canonical_wv
    _dr_repo_wv=$(_bootstrap_repo_wv_path)
    _dr_invoked_wv=$(_bootstrap_invoked_wv_path)
    _dr_canonical_wv=$(_bootstrap_canonical_wv_path)
    _dr_provenance=$(_bootstrap_wv_provenance "$_dr_invoked_wv")
    if [ -z "$_dr_canonical_wv" ]; then
        _doctor_record "wv provenance" "warn" "unable to resolve active wv command"
    elif [ -n "$_dr_repo_wv" ] && [ -x "$_dr_repo_wv" ] && [ -n "$_dr_invoked_wv" ] && [ "$_dr_repo_wv" != "$_dr_invoked_wv" ]; then
        _doctor_record "wv provenance" "warn" "invoked $_dr_invoked_wv ($_dr_provenance); repo-local wrapper available at $_dr_repo_wv"
    else
        _doctor_record "wv provenance" "pass" "$_dr_canonical_wv ($_dr_provenance)"
    fi

    # 22. Verification-gate layer (P6) — repo-scoped; no-op outside a repo.
    _doctor_check_verification

    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_mcp_status — Verify MCP server is built and reachable
# ═══════════════════════════════════════════════════════════════════════════

_mcp_scope_statuses() { # contract_path process_lines
    local contract_path="$1" process_lines="$2"
    local scope expected running duplicate status entries=""

    # An unreadable authority ends this, rather than falling through the loop
    # and printing []. The empty array was indistinguishable from "the contract
    # declares no scopes", so a consumer with no contract at all was told its
    # servers were missing instead of that the contract was.
    if [ -z "$contract_path" ] || [ ! -f "$contract_path" ]; then
        return 1
    fi
    if ! jq -e '.scopes | type == "object"' "$contract_path" >/dev/null 2>&1; then
        return 1
    fi

    while IFS= read -r scope; do
        [ -n "$scope" ] || continue
        expected=$(jq -r --arg scope "$scope" '.scopes[$scope].configured_by_default // false' "$contract_path")
        running=$(
            printf '%s\n' "$process_lines" | sed '/^$/d' | awk -v target="$scope" '
                {
                    scope="all"
                    if ($0 ~ /--scope=/) {
                        scope=$0
                        sub(/^.*--scope=/, "", scope)
                        sub(/[[:space:]].*$/, "", scope)
                    }
                    if (scope == target) count++
                }
                END { print count + 0 }'
        )
        duplicate=false
        status="unknown"
        if [ "$running" -gt 1 ]; then
            duplicate=true
            status="stale"
        elif [ "$running" -eq 1 ]; then
            status="running"
        fi
        entries="${entries:+$entries,}$(printf '{"scope":"%s","expected":%s,"running":%d,"duplicate":%s,"status":"%s"}' \
            "$(wv_json_escape "$scope")" "$expected" "$running" "$duplicate" "$status")"
    done < <(jq -r '.scopes | keys[]' "$contract_path")

    printf '[%s]\n' "$entries"
}

cmd_mcp_status() {
    local format="text"
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) format="json" ;;
        esac
        shift
    done

    local pass=0 fail=0 warn=0 total=0
    local results=""

    _mcp_record() {
        local name="$1" status="$2" detail="$3"
        total=$((total + 1))
        case "$status" in
            pass) pass=$((pass + 1)) ;;
            fail) fail=$((fail + 1)) ;;
            warn) warn=$((warn + 1)) ;;
        esac
        if [ "$format" = "json" ]; then
            results="${results:+$results,}$(printf '{"check":"%s","status":"%s","detail":"%s"}' "$name" "$status" "$(wv_json_escape "$detail")")"
        else
            local icon
            case "$status" in
                pass) icon="${GREEN}✓${NC}" ;;
                fail) icon="${RED}✗${NC}" ;;
                warn) icon="${YELLOW}⊘${NC}" ;;
            esac
            echo -e "  $icon $name: $detail"
        fi
    }

    # The MCP contract is an installed asset, not a file in the repository being
    # inspected. It was read as "$REPO_ROOT/mcp/contract.json", which exists in
    # this development checkout and in no consumer: the VS Code check then
    # silently validated nothing and the scope table came back empty, so
    # mcp-status reported "no server visible" about a machine whose servers it
    # had never looked for. Installed copy first, source tree only as a
    # development fallback, and no third answer -- a missing authority is
    # reported, never assumed empty.
    _mcp_contract_path() {
        local candidate
        for candidate in "${WV_LIB_DIR:-}/mcp/contract.json" "$REPO_ROOT/mcp/contract.json"; do
            case "$candidate" in /mcp/contract.json) continue ;; esac
            [ -f "$candidate" ] && { printf '%s' "$candidate"; return 0; }
        done
        return 1
    }

    _mcp_check_vscode_config() {
        local config_path="$1"
        local config_label="$2"
        local missing=()
        local contract_path
        contract_path=$(_mcp_contract_path) || contract_path=""

        if command -v jq >/dev/null 2>&1 && [ -f "$contract_path" ]; then
            local expected_names required_env
            expected_names=$(jq -r '.servers[].name' "$contract_path" 2>/dev/null || true)
            required_env=$(jq -r '.environment.required[]' "$contract_path" 2>/dev/null || true)
            while IFS= read -r server_name; do
                [ -z "$server_name" ] && continue
                grep -q "\"$server_name\"" "$config_path" 2>/dev/null || missing+=("$server_name")
            done <<<"$expected_names"
            while IFS= read -r env_name; do
                [ -z "$env_name" ] && continue
                grep -q -- "$env_name" "$config_path" 2>/dev/null || missing+=("$env_name")
            done <<<"$required_env"
            grep -q 'WV_PATH' "$config_path" 2>/dev/null || missing+=("WV_PATH")
        else
            grep -q '"weave"' "$config_path" 2>/dev/null || missing+=("weave")
            grep -q '"weave-session"' "$config_path" 2>/dev/null || missing+=("weave-session")
            grep -q '"weave-lite"' "$config_path" 2>/dev/null || missing+=("weave-lite")
            grep -q '"weave-inspect"' "$config_path" 2>/dev/null || missing+=("weave-inspect")
            grep -q 'WV_PATH' "$config_path" 2>/dev/null || missing+=("WV_PATH")
            grep -q 'WV_PROJECT_ROOT' "$config_path" 2>/dev/null || missing+=("WV_PROJECT_ROOT")
            grep -q 'WV_AGENT_ID' "$config_path" 2>/dev/null || missing+=("WV_AGENT_ID")
        fi

        if [ "${#missing[@]}" -eq 0 ]; then
            _mcp_record "VS Code config" "pass" "$config_label"
            return
        fi

        _mcp_record "VS Code config" "warn" "$config_label missing $(IFS=', '; echo "${missing[*]}") — run wv init-repo --agent=copilot --force"
    }

    [ "$format" = "text" ] && echo "Weave MCP Status"

    # 1. Node.js
    if command -v node >/dev/null 2>&1; then
        local node_ver
        node_ver=$(node --version 2>/dev/null)
        _mcp_record "node" "pass" "$node_ver"
    else
        _mcp_record "node" "fail" "not found"
    fi

    # 2. MCP server built (check installed path, then repo root)
    local lib_dir="${WV_LIB_DIR:-$HOME/.local/lib/weave}"
    local repo_mcp="$REPO_ROOT/mcp/dist/index.js"
    local mcp_js=""
    if [ -f "$lib_dir/mcp/dist/index.js" ]; then
        mcp_js="$lib_dir/mcp/dist/index.js"
        _mcp_record "server built" "pass" "$mcp_js"
    elif [ -f "$repo_mcp" ]; then
        mcp_js="$repo_mcp"
        _mcp_record "server built" "pass" "$mcp_js (local dev)"
    else
        _mcp_record "server built" "fail" "not found — run install.sh --with-mcp"
    fi

    # 3. Server loadable (verify dist exists and has content — can't require() as it starts stdio)
    if [ -n "$mcp_js" ]; then
        local mcp_size
        mcp_size=$(wc -c < "$mcp_js" 2>/dev/null || echo "0")
        if [ "$mcp_size" -gt 1000 ] 2>/dev/null; then
            _mcp_record "server dist" "pass" "$(( mcp_size / 1024 ))KB bundle"
        else
            _mcp_record "server dist" "warn" "bundle looks too small (${mcp_size}B)"
        fi

        local startup_json startup_rc startup_status startup_scope startup_tools startup_agent
        startup_rc=0
        startup_json=$(node "$mcp_js" --scope=lite --health-check 2>/dev/null) || startup_rc=$?
        startup_rc=${startup_rc:-0}
        if [ "$startup_rc" -eq 0 ] && command -v jq >/dev/null 2>&1 && printf '%s' "$startup_json" | jq -e '.schema == "weave-mcp-startup.v1"' >/dev/null 2>&1; then
            startup_status=$(printf '%s' "$startup_json" | jq -r '.status')
            startup_scope=$(printf '%s' "$startup_json" | jq -r '.scope')
            startup_tools=$(printf '%s' "$startup_json" | jq -r '.tools')
            startup_agent=$(printf '%s' "$startup_json" | jq -r '.agent_id // "unset"')
            _mcp_record "startup health" "pass" "status=${startup_status} scope=${startup_scope} tools=${startup_tools} agent=${startup_agent}"
        else
            _mcp_record "startup health" "warn" "structured health-check unavailable — run: node $mcp_js --scope=lite --health-check"
        fi
    fi

    # 4. Check for IDE configs (supports both agents in same repo)
    local repo_root="$REPO_ROOT"
    local has_vscode=false has_claude=false
    if [ -f "$repo_root/.vscode/mcp.json" ]; then
        _mcp_check_vscode_config "$repo_root/.vscode/mcp.json" ".vscode/mcp.json"
        has_vscode=true
    elif [ -f "$repo_root/.mcp.json" ]; then
        _mcp_check_vscode_config "$repo_root/.mcp.json" ".mcp.json"
        has_vscode=true
    fi
    if [ -f "$repo_root/.claude/settings.local.json" ]; then
        if grep -q "mcpServers" "$repo_root/.claude/settings.local.json" 2>/dev/null; then
            _mcp_record "Claude config" "pass" "mcpServers in settings.local.json"
            has_claude=true
        fi
    fi
    if ! $has_vscode && ! $has_claude; then
        _mcp_record "IDE config" "warn" "no IDE config found — run wv init-repo --agent=copilot or --agent=all"
    fi

    # 5. Live process visibility. VS Code/Copilot owns stdio server lifetimes, so
    # absence is advisory, while extra same-scope processes are a stale-server smell.
    local process_lines process_count duplicate_scope per_scope scope_summary contract_path
    process_lines=$(pgrep -af 'mcp/dist/index.js|weave-mcp|node .*weave' 2>/dev/null | grep -v 'pgrep -af' || true)
    contract_path=$(_mcp_contract_path) || contract_path=""
    if ! per_scope=$(_mcp_scope_statuses "$contract_path" "$process_lines"); then
        # Said out loud. Reporting "no server visible" here would be a claim
        # about this machine's servers made without ever reading the contract
        # that names them.
        _mcp_record "server processes" "fail" \
            "MCP contract unavailable — reinstall weave (expected ${WV_LIB_DIR:-\$WV_LIB_DIR}/mcp/contract.json); scope status cannot be determined"
    else
        process_count=$(jq '[.[].running] | add // 0' <<<"$per_scope")
        duplicate_scope=$(jq -r '[.[] | select(.duplicate) | "\(.scope):\(.running)"] | join(",")' <<<"$per_scope")
        scope_summary=$(jq -r '[.[] | "\(.scope) \(if .expected then "expected" else "optional" end)/\(.status) (\(.running))"] | join(", ")' <<<"$per_scope")
        if [ "$process_count" -eq 0 ] 2>/dev/null; then
            _mcp_record "server processes" "warn" "$scope_summary — no server visible; start or restart the MCP client if tools are unavailable"
        elif [ -n "$duplicate_scope" ]; then
            _mcp_record "server processes" "warn" "$scope_summary — restart duplicate scope(s) ${duplicate_scope} to clear stale instances"
        else
            _mcp_record "server processes" "pass" "$scope_summary"
        fi
    fi

    # Summary
    if [ "$format" = "json" ]; then
        local overall="pass"
        [ "$fail" -gt 0 ] && overall="fail"
        printf '{"overall":"%s","passed":%d,"failed":%d,"warnings":%d,"total":%d,"checks":[%s],"per_scope":%s}\n' \
            "$overall" "$pass" "$fail" "$warn" "$total" "$results" "$per_scope"
    else
        echo ""
        if [ "$fail" -gt 0 ]; then
            echo -e "Result: ${RED}${pass}/${total} passed${NC} (${fail} failed, ${warn} warnings)"
        elif [ "$warn" -gt 0 ]; then
            echo -e "Result: ${GREEN}${pass}/${total} passed${NC} (${warn} warnings)"
        else
            echo -e "Result: ${GREEN}${pass}/${total} passed${NC}"
        fi
    fi

    [ "$fail" -gt 0 ] && return 1
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_selftest — Round-trip smoke test in isolated environment
# ═══════════════════════════════════════════════════════════════════════════

# Shared state for _selftest_check (avoids subshell capture issues)
_st_pass=0 _st_fail=0 _st_total=0 _st_results="" _st_format="text"

_selftest_check() {
    local name="$1" ok="$2" detail="$3"
    _st_total=$((_st_total + 1))
    if [ "$ok" = "1" ]; then
        _st_pass=$((_st_pass + 1))
        local status="pass"
    else
        _st_fail=$((_st_fail + 1))
        local status="fail"
    fi
    if [ "$_st_format" = "json" ]; then
        _st_results="${_st_results:+$_st_results,}$(printf '{"test":"%s","status":"%s","detail":"%s"}' "$name" "$status" "$(wv_json_escape "$detail")")"
    else
        local icon
        [ "$status" = "pass" ] && icon="${GREEN}✓${NC}" || icon="${RED}✗${NC}"
        echo -e "  $icon $name: $detail"
    fi
}

# _selftest_run_tests — Execute the 9 smoke tests (uses _selftest_check for recording)
_selftest_run_tests() {
    # 1. Init
    local init_out
    init_out=$(db_init 2>&1) && _selftest_check "init" "1" "database created" \
        || _selftest_check "init" "0" "failed: $init_out"

    # 2. Add nodes
    local id1 id2
    id1=$(cmd_add "selftest parent node" 2>/dev/null) && _selftest_check "add node 1" "1" "$id1" \
        || _selftest_check "add node 1" "0" "failed"
    id2=$(cmd_add "selftest child node" 2>/dev/null) && _selftest_check "add node 2" "1" "$id2" \
        || _selftest_check "add node 2" "0" "failed"

    # 3. Link. relates_to, not implements: step 6 closes node 1 while node 2 is
    # still open, and a node does not close over an open child (wv-76b361).
    # The closing node here is a blocker, which is what auto-unblock tests.
    if [ -n "$id1" ] && [ -n "$id2" ]; then
        local link_out
        link_out=$(cmd_link "$id2" "$id1" --type=relates_to 2>&1) && _selftest_check "link" "1" "$id2 -> $id1" \
            || _selftest_check "link" "0" "failed: $link_out"
    else
        _selftest_check "link" "0" "skipped (no node IDs)"
    fi

    # 4. Block
    if [ -n "$id1" ] && [ -n "$id2" ]; then
        local block_out
        block_out=$(cmd_block "$id2" --by="$id1" 2>&1) && _selftest_check "block" "1" "$id2 blocked by $id1" \
            || _selftest_check "block" "0" "failed: $block_out"
    else
        _selftest_check "block" "0" "skipped (no node IDs)"
    fi

    # 5. Work (claim parent)
    if [ -n "$id1" ]; then
        local work_out
        work_out=$(cmd_work "$id1" 2>&1) && _selftest_check "work" "1" "claimed $id1" \
            || _selftest_check "work" "0" "failed: $work_out"
    else
        _selftest_check "work" "0" "skipped"
    fi

    # 6. Done (complete parent — should auto-unblock child)
    if [ -n "$id1" ]; then
        local done_out
        done_out=$(cmd_done "$id1" --skip-verification 2>&1) && _selftest_check "done" "1" "completed $id1" \
            || _selftest_check "done" "0" "failed: $done_out"
    else
        _selftest_check "done" "0" "skipped"
    fi

    # 7. Verify child unblocked
    if [ -n "$id2" ]; then
        local child_status
        child_status=$(db_query "SELECT status FROM nodes WHERE id='$id2'")
        [ "$child_status" = "todo" ] && _selftest_check "auto-unblock" "1" "$id2 status=$child_status" \
            || _selftest_check "auto-unblock" "0" "$id2 status=$child_status (expected todo)"
    else
        _selftest_check "auto-unblock" "0" "skipped"
    fi

    # 8. Search (FTS5)
    local search_out
    search_out=$(cmd_search "selftest" --json 2>/dev/null)
    local search_count
    search_count=$(echo "$search_out" | jq 'length' 2>/dev/null || echo "0")
    [ "$search_count" -ge 1 ] 2>/dev/null && _selftest_check "search" "1" "$search_count results" \
        || _selftest_check "search" "0" "no results"

    # 9. Health
    local health_out
    health_out=$(cmd_health --json 2>/dev/null)
    local health_score
    health_score=$(echo "$health_out" | jq -r '.score' 2>/dev/null || echo "0")
    [ "$health_score" -gt 0 ] 2>/dev/null && _selftest_check "health" "1" "score $health_score" \
        || _selftest_check "health" "0" "score=$health_score"
}

cmd_selftest() {
    _st_format="text"
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) _st_format="json" ;;
        esac
        shift
    done

    _st_pass=0 _st_fail=0 _st_total=0 _st_results=""
    local test_dir
    test_dir=$(mktemp -d "${TMPDIR:-/tmp}/wv-selftest-XXXXXX")

    # Isolated environment — override hot zone, DB, AND WEAVE_DIR
    # Without WEAVE_DIR override, auto_sync writes state.sql/deltas to the
    # real .weave/ directory, corrupting the live graph on next load.
    local orig_db="${WV_DB:-}"
    local orig_hz="${WV_HOT_ZONE:-}"
    local orig_wd="${WEAVE_DIR:-}"
    export WV_HOT_ZONE="$test_dir"
    export WV_DB="$test_dir/brain.db"
    export WEAVE_DIR="$test_dir/.weave"
    mkdir -p "$WEAVE_DIR/deltas"
    _WV_DB_READY=""
    _WV_SIZE_CHECKED=""

    [ "$_st_format" = "text" ] && echo "Weave Selftest — Round-trip Smoke Test"

    _selftest_run_tests

    # Cleanup
    export WV_DB="$orig_db"
    export WV_HOT_ZONE="$orig_hz"
    export WEAVE_DIR="$orig_wd"
    _WV_DB_READY=""
    _WV_SIZE_CHECKED=""
    cd /tmp || true
    rm -rf "$test_dir"

    # Summary
    if [ "$_st_format" = "json" ]; then
        local overall="pass"
        [ "$_st_fail" -gt 0 ] && overall="fail"
        printf '{"overall":"%s","passed":%d,"failed":%d,"total":%d,"tests":[%s]}\n' \
            "$overall" "$_st_pass" "$_st_fail" "$_st_total" "$_st_results"
    else
        echo ""
        if [ "$_st_fail" -gt 0 ]; then
            echo -e "Result: ${RED}${_st_pass}/${_st_total} passed${NC} (${_st_fail} failed)"
        else
            echo -e "Result: ${GREEN}${_st_pass}/${_st_total} passed${NC}"
        fi
    fi

    [ "$_st_fail" -gt 0 ] && return 1
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_health — System health check
# ═══════════════════════════════════════════════════════════════════════════

# ═══════════════════════════════════════════════════════════════════════════
# cmd_health — Health check with score (decomposed into helpers)
# ═══════════════════════════════════════════════════════════════════════════

# Shared state for cmd_health helpers
_h_total_nodes=0 _h_active=0 _h_ready=0 _h_blocked=0 _h_blocked_ext=0
_h_done_count=0 _h_pending=0 _h_total_edges=0 _h_blocking_edges=0
_h_total_pitfalls=0 _h_addressed_pitfalls=0 _h_unaddressed_pitfalls=0
_h_orphan_nodes=0 _h_orphan_ids="[]" _h_intentional_standalones=0
_h_intentional_standalone_ids="[]" _h_ghost_edges=0 _h_empty_edge_ctx=0
_h_gh_duplicates=0 _h_gh_duplicate_issues="[]"
_h_stale_active=0 _h_contradictions=0 _h_invalid_statuses=0
_h_health_score=100 _h_issues="" _h_fixed_edge_ctx=0
_h_status_icon="" _h_status_text=""
_h_quality_available="false" _h_quality_score=0 _h_quality_hotspots=0 _h_quality_baseline_note=""
_h_quality_files=0 _h_quality_head="" _h_quality_scanned=""

# Show health history log and exit. Args: $1=count, $2=format
_health_show_history() {
    local count="$1" format="$2"
    local log_file="$WEAVE_DIR/health.log"
    if [ ! -f "$log_file" ]; then
        echo "No health history yet. Run 'wv health' to start logging."
        return 0
    fi
    local total
    total=$(wc -l < "$log_file")
    if [ "$format" = "json" ]; then
        tail -n "$count" "$log_file" | awk -F'\t' '{
            printf "{\"timestamp\":\"%s\",\"score\":%s,\"nodes\":%s,\"edges\":%s,\"orphans\":%s,\"ghost_edges\":%s}\n", $1, $2, $3, $4, $5, $6
        }' | jq -s '.'
    else
        echo -e "${CYAN}Health History${NC} (last $count of $total entries)"
        echo ""
        printf "  %-25s %5s %5s %5s %7s %11s\n" "Timestamp" "Score" "Nodes" "Edges" "Orphans" "Ghost Edges"
        printf "  %-25s %5s %5s %5s %7s %11s\n" "─────────────────────────" "─────" "─────" "─────" "───────" "───────────"
        tail -n "$count" "$log_file" | while IFS=$'\t' read -r ts score nodes edges orphans ghosts; do
            local icon="✅"
            [ "$score" -lt 90 ] 2>/dev/null && icon="⚠️"
            [ "$score" -lt 70 ] 2>/dev/null && icon="❌"
            printf "  %-25s %3s %s %5s %5s %7s %11s\n" "$ts" "$score" "$icon" "$nodes" "$edges" "$orphans" "$ghosts"
        done
    fi
}

# Collect all health metrics from DB into _h_* shared variables.
_health_collect_metrics() {
    # Node counts
    _h_total_nodes=$(db_query "SELECT COUNT(*) FROM nodes;" 2>/dev/null)
    _h_total_nodes="${_h_total_nodes:-0}"
    _h_active=$(db_query "SELECT COUNT(*) FROM nodes WHERE status='active';" 2>/dev/null)
    _h_active="${_h_active:-0}"
    _h_ready=$(cmd_ready --count 2>/dev/null)
    _h_ready="${_h_ready:-0}"
    _h_blocked=$(db_query "SELECT COUNT(*) FROM nodes WHERE status='blocked';" 2>/dev/null)
    _h_blocked="${_h_blocked:-0}"
    _h_blocked_ext=$(db_query "SELECT COUNT(*) FROM nodes WHERE status='blocked-external';" 2>/dev/null)
    _h_blocked_ext="${_h_blocked_ext:-0}"
    _h_done_count=$(db_query "SELECT COUNT(*) FROM nodes WHERE status='done';" 2>/dev/null)
    _h_done_count="${_h_done_count:-0}"
    _h_pending=$(db_query "SELECT COUNT(*) FROM nodes WHERE status='pending';" 2>/dev/null)
    _h_pending="${_h_pending:-0}"

    # Edge stats
    _h_total_edges=$(db_query "SELECT COUNT(*) FROM edges;" 2>/dev/null)
    _h_total_edges="${_h_total_edges:-0}"
    _h_blocking_edges=$(db_query "SELECT COUNT(*) FROM edges WHERE type='blocks';" 2>/dev/null)
    _h_blocking_edges="${_h_blocking_edges:-0}"

    # Pitfall stats — only count open (non-done) nodes; done-node pitfalls are captured learnings
    _h_total_pitfalls=$(db_query "
        SELECT COUNT(*) FROM nodes
        WHERE json_extract(metadata, '\$.pitfall') IS NOT NULL
        AND status != 'done';
    ")
    _h_addressed_pitfalls=$(db_query "
        SELECT COUNT(DISTINCT n.id) FROM nodes n
        JOIN ($(wv_pitfall_resolver_edges_sql)) r ON r.pitfall = n.id
        WHERE json_extract(n.metadata, '\$.pitfall') IS NOT NULL
        AND n.status != 'done';
    ")
    _h_unaddressed_pitfalls=$((_h_total_pitfalls - _h_addressed_pitfalls))

    # Intentional standalone nodes (no edges, but explicitly marked standalone=true)
    _h_intentional_standalones=$(db_query "
        SELECT COUNT(*) FROM nodes n
        WHERE COALESCE(json_extract(n.metadata, '\$.standalone'), 0) = 1
        AND n.id NOT IN (SELECT source FROM edges)
        AND n.id NOT IN (SELECT target FROM edges);
    ")
    _h_intentional_standalones="${_h_intentional_standalones:-0}"
    _h_intentional_standalone_ids=$(db_query "
        SELECT json_group_array(n.id) FROM nodes n
        WHERE COALESCE(json_extract(n.metadata, '\$.standalone'), 0) = 1
        AND n.id NOT IN (SELECT source FROM edges)
        AND n.id NOT IN (SELECT target FROM edges);
    ")
    _h_intentional_standalone_ids="${_h_intentional_standalone_ids:-[]}"

    # Orphan nodes (no edges at all, excluding intentional standalones and done nodes)
    _h_orphan_nodes=$(db_query "
        SELECT COUNT(*) FROM nodes n
        WHERE COALESCE(json_extract(n.metadata, '\$.standalone'), 0) != 1
        AND n.status != 'done'
        AND n.id NOT IN (SELECT source FROM edges)
        AND n.id NOT IN (SELECT target FROM edges);
    ")
    _h_orphan_ids=$(db_query "
        SELECT json_group_array(n.id) FROM nodes n
        WHERE COALESCE(json_extract(n.metadata, '\$.standalone'), 0) != 1
        AND n.status != 'done'
        AND n.id NOT IN (SELECT source FROM edges)
        AND n.id NOT IN (SELECT target FROM edges);
    ")
    _h_orphan_ids="${_h_orphan_ids:-[]}"

    # GH issue duplicates: non-done nodes sharing the same gh_issue number
    _h_gh_duplicates=$(db_query "
        SELECT COUNT(DISTINCT json_extract(metadata, '\$.gh_issue'))
        FROM nodes
        WHERE json_extract(metadata, '\$.gh_issue') IS NOT NULL
        AND status != 'done'
        GROUP BY json_extract(metadata, '\$.gh_issue')
        HAVING COUNT(*) > 1;
    " 2>/dev/null | wc -l | tr -d ' ')
    _h_gh_duplicates="${_h_gh_duplicates:-0}"
    if [ "${_h_gh_duplicates:-0}" -gt 0 ] 2>/dev/null; then
        local _dup_raw
        _dup_raw=$(db_query "
            SELECT json_group_array(json_object(
                'gh_issue', gi,
                'nodes', (
                    SELECT json_group_array(id)
                    FROM nodes n2
                    WHERE json_extract(n2.metadata, '\$.gh_issue') = gi
                    AND n2.status != 'done'
                )
            ))
            FROM (
                SELECT DISTINCT json_extract(metadata, '\$.gh_issue') as gi
                FROM nodes
                WHERE json_extract(metadata, '\$.gh_issue') IS NOT NULL
                AND status != 'done'
                GROUP BY gi
                HAVING COUNT(*) > 1
            );
        " 2>/dev/null)
        _h_gh_duplicate_issues="${_dup_raw:-[]}"
    fi

    # Ghost edges (referencing non-existent nodes)
    _h_ghost_edges=$(db_query "
        SELECT COUNT(*) FROM edges
        WHERE source NOT IN (SELECT id FROM nodes)
        OR target NOT IN (SELECT id FROM nodes);
    ")

    # Empty edge context
    _h_empty_edge_ctx=$(db_query "SELECT COUNT(*) FROM edges WHERE context='{}';")
    _h_empty_edge_ctx="${_h_empty_edge_ctx:-0}"

    # Stale active nodes (active for more than 7 days)
    _h_stale_active=$(db_query "
        SELECT COUNT(*) FROM nodes
        WHERE status='active'
        AND datetime(updated_at) < datetime('now', '-7 days');
    ")

    # Unresolved contradictions
    _h_contradictions=$(db_query "
        SELECT COUNT(*) FROM edges
        WHERE type='contradicts';
    ")

    # Invalid statuses (wv-01e7 fix)
    _h_invalid_statuses=$(db_query "
        SELECT COUNT(*) FROM nodes
        WHERE status NOT IN ('todo', 'active', 'done', 'blocked', 'blocked-external');
    ")

    # System metrics: RAM and tmpfs (hot zone)
    _h_ram_total_mb=0
    _h_ram_available_mb=0
    _h_shm_used_mb=0
    _h_shm_total_mb=0
    _h_db_size_kb=0
    if [ -f /proc/meminfo ]; then
        local ram_total_kb ram_avail_kb
        ram_total_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
        ram_avail_kb=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
        _h_ram_total_mb=$((ram_total_kb / 1024))
        _h_ram_available_mb=$((ram_avail_kb / 1024))
    fi
    if df /dev/shm >/dev/null 2>&1; then
        _h_shm_total_mb=$(df -BM /dev/shm | awk 'NR==2 {gsub(/M/,"",$2); print $2}')
        _h_shm_used_mb=$(df -BM /dev/shm | awk 'NR==2 {gsub(/M/,"",$3); print $3}')
    fi
    if [ -n "$WV_DB" ] && [ -f "$WV_DB" ]; then
        _h_db_size_kb=$(du -k "$WV_DB" 2>/dev/null | cut -f1)
        _h_db_size_kb="${_h_db_size_kb:-0}"
    fi
    _health_check_fts
}

# Probe content as well as index structure, without db_ensure repairing the
# evidence first. Also runs before fast-cache lookup: out-of-band damage does
# not touch the CLI write sentinel. A refused probe cannot certify health.
_health_check_fts() {
    _h_fts_integrity=preinit
    [ -f "$WV_DB" ] || return 0
    if sqlite3 -cmd ".timeout 5000" "$WV_DB" \
        "INSERT INTO nodes_fts(nodes_fts,rank) VALUES('integrity-check',1);" >/dev/null 2>&1; then
        _h_fts_integrity=ok
    else
        _h_fts_integrity=failed
    fi
}

# Compute health score from collected metrics. Sets _h_health_score, _h_issues,
# _h_status_icon, _h_status_text.
_health_compute_score() {
    _h_health_score=100
    _h_issues=""

    if [ "$_h_invalid_statuses" -gt 0 ]; then
        _h_health_score=$((_h_health_score - _h_invalid_statuses * 20))
        _h_issues="${_h_issues}invalid_statuses:$_h_invalid_statuses,"
    fi
    if [ "$_h_unaddressed_pitfalls" -gt 0 ]; then
        _h_health_score=$((_h_health_score - _h_unaddressed_pitfalls * 10))
        _h_issues="${_h_issues}unaddressed_pitfalls:$_h_unaddressed_pitfalls,"
    fi
    if [ "$_h_stale_active" -gt 0 ]; then
        _h_health_score=$((_h_health_score - _h_stale_active * 5))
        _h_issues="${_h_issues}stale_active:$_h_stale_active,"
    fi
    if [ "$_h_contradictions" -gt 0 ]; then
        _h_health_score=$((_h_health_score - _h_contradictions * 15))
        _h_issues="${_h_issues}unresolved_contradictions:$_h_contradictions,"
    fi
    if [ "$_h_ghost_edges" -gt 0 ]; then
        local ghost_penalty=30
        if [ "$_h_total_edges" -gt 0 ]; then
            ghost_penalty=$(( _h_ghost_edges * 30 / _h_total_edges ))
            if [ "$ghost_penalty" -gt 30 ]; then ghost_penalty=30; fi
        fi
        if [ "$ghost_penalty" -lt 5 ]; then ghost_penalty=5; fi
        _h_health_score=$((_h_health_score - ghost_penalty))
        _h_issues="${_h_issues}ghost_edges:$_h_ghost_edges,"
    fi
    if [ "$_h_orphan_nodes" -gt 5 ]; then
        local orphan_penalty=5
        if [ "$_h_total_nodes" -gt 0 ]; then
            orphan_penalty=$(( _h_orphan_nodes * 15 / _h_total_nodes ))
            if [ "$orphan_penalty" -gt 15 ]; then orphan_penalty=15; fi
        fi
        if [ "$orphan_penalty" -lt 3 ]; then orphan_penalty=3; fi
        _h_health_score=$((_h_health_score - orphan_penalty))
        _h_issues="${_h_issues}orphan_nodes:$_h_orphan_nodes,"
    fi
    if [ "${_h_gh_duplicates:-0}" -gt 0 ] 2>/dev/null; then
        local dup_penalty=$(( _h_gh_duplicates * 5 ))
        if [ "$dup_penalty" -gt 15 ]; then dup_penalty=15; fi
        _h_health_score=$((_h_health_score - dup_penalty))
        _h_issues="${_h_issues}gh_duplicates:$_h_gh_duplicates,"
    fi
    # RAM pressure: warn at <1GB available, critical at <500MB
    _h_ram_warning=false
    _h_ram_critical=false
    if [ "$_h_ram_available_mb" -gt 0 ]; then
        if [ "$_h_ram_available_mb" -lt 500 ]; then
            _h_ram_critical=true
            _h_health_score=$((_h_health_score - 15))
            _h_issues="${_h_issues}ram_critical:${_h_ram_available_mb}MB,"
        elif [ "$_h_ram_available_mb" -lt 1024 ]; then
            _h_ram_warning=true
            _h_health_score=$((_h_health_score - 5))
            _h_issues="${_h_issues}ram_low:${_h_ram_available_mb}MB,"
        fi
    fi

    # Clamp to 0-100
    if [ "$_h_health_score" -lt 0 ]; then _h_health_score=0; fi
    if [ "$_h_health_score" -gt 100 ]; then _h_health_score=100; fi

    if [ "$_h_fts_integrity" = failed ]; then
        _h_health_score=0
        _h_issues="${_h_issues}fts_integrity:failed,"
    fi

    # Status icon/text
    if [ "$_h_health_score" -ge 90 ]; then
        _h_status_icon="✅"; _h_status_text="healthy"
    elif [ "$_h_health_score" -ge 70 ]; then
        _h_status_icon="⚠️"; _h_status_text="warning"
    else
        _h_status_icon="❌"; _h_status_text="unhealthy"
    fi
}

# Collect code quality info (informational, does NOT affect main score).
# Sets _h_quality_* shared variables.
_health_collect_quality() {
    _h_quality_available="false"
    _h_quality_score=0
    _h_quality_baseline_note=""
    _h_quality_hotspots=0
    _h_quality_files=0
    _h_quality_head=""
    _h_quality_scanned=""
    _h_quality_stale="false"
    local quality_json
    local _hz_args=()
    if [ -n "$WV_HOT_ZONE" ]; then _hz_args=("--hot-zone" "$WV_HOT_ZONE"); fi
    quality_json=$(_wv_quality_python "${_hz_args[@]}" health-info 2>/dev/null || echo '{"available":false}')
    if echo "$quality_json" | jq -e '.available' >/dev/null 2>&1; then
        _h_quality_available=$(echo "$quality_json" | jq -r '.available')
        if [ "$_h_quality_available" = "true" ]; then
            _h_quality_score=$(echo "$quality_json" | jq -r '.score')
            _h_quality_baseline_note=$(echo "$quality_json" | jq -r '.baseline_note // ""')
            _h_quality_hotspots=$(echo "$quality_json" | jq -r '.hotspot_count')
            _h_quality_files=$(echo "$quality_json" | jq -r '.total_files')
            _h_quality_head=$(echo "$quality_json" | jq -r '.git_head')
            _h_quality_scanned=$(echo "$quality_json" | jq -r '.scanned_at')
            _h_quality_stale=$(echo "$quality_json" | jq -r '.stale == true')
        fi
    fi
}

# One-line cache health summary for wv health output
_health_cache_summary() {
    local proj_slug projects_dir jsonl
    proj_slug=$(pwd | tr '/' '-')
    projects_dir="$HOME/.claude/projects"
    # Pick most recent JSONL for this project
    jsonl=$(ls -t "$projects_dir/${proj_slug}"/*.jsonl 2>/dev/null | head -1 || true)
    if [ -z "$jsonl" ]; then
        echo "  no session data (run 'wv cache' to diagnose)"
        return
    fi
    python3 - "$jsonl" <<'PYEOF'
import sys, json, os
path = sys.argv[1]
total_read = total_create = turns = 0
try:
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line: continue
            try: e = json.loads(line)
            except: continue
            usage = e.get("usage")
            if usage is None:
                msg = e.get("message", {})
                if isinstance(msg, dict): usage = msg.get("usage")
            if isinstance(usage, dict):
                total_read  += usage.get("cache_read_input_tokens", 0) or 0
                total_create += usage.get("cache_creation_input_tokens", 0) or 0
                turns += 1
except Exception:
    pass
total = total_read + total_create
if total == 0:
    print("  no usage data in latest session")
    sys.exit(0)
ratio = total_read / total
status = "OK" if ratio > 0.65 else "LOW" if ratio > 0.35 else "BAD"
GREEN = "\033[0;32m"; YELLOW = "\033[1;33m"; RED = "\033[0;31m"; NC = "\033[0m"
colour = GREEN if status == "OK" else (YELLOW if status == "LOW" else RED)
sid = os.path.basename(path)[:8]
print(f"  {sid}  {turns} turns  {ratio:.1%} read  {colour}{status}{NC}  (run 'wv cache' for full report)")
PYEOF
}

# Backfill empty edge context. Sets _h_fixed_edge_ctx count.
_health_fix_edges() {
    _h_fixed_edge_ctx=0
    if [ "${_h_empty_edge_ctx:-0}" -eq 0 ]; then
        return 0
    fi
    while IFS=$'\x1f' read -r src tgt etype src_label tgt_label; do
        [ -z "$src" ] && continue
        local ctx
        ctx=$(jq -nc --arg s "$src_label" --arg t "$tgt_label" --arg e "$etype" \
            '{summary: ($s + " " + $e + " " + $t), auto: true}')
        local ctx_escaped="${ctx//\'/\'\'}"
        db_query "UPDATE edges SET context='$ctx_escaped'
            WHERE source='$src' AND target='$tgt' AND type='$etype'
            AND context='{}';"
        _h_fixed_edge_ctx=$((_h_fixed_edge_ctx + 1))
    done < <(sqlite3 -batch -cmd ".timeout 5000" -separator $'\x1f' "$WV_DB" \
        "SELECT e.source, e.target, e.type,
                COALESCE(s.alias, substr(s.text,1,40)),
                COALESCE(t.alias, substr(t.text,1,40))
         FROM edges e
         JOIN nodes s ON e.source = s.id
         JOIN nodes t ON e.target = t.id
         WHERE e.context = '{}';")
    # Update count after fix
    _h_empty_edge_ctx=$(db_query "SELECT COUNT(*) FROM edges WHERE context='{}';")
    _h_empty_edge_ctx="${_h_empty_edge_ctx:-0}"
}

# Emit health report as JSON. Args: $1=strict flag
_health_format_json() {
    local strict="$1"
    local quality_obj
    if [ "$_h_quality_available" = "true" ]; then
        quality_obj=$(jq -n \
            --argjson score "$_h_quality_score" \
            --argjson hotspots "$_h_quality_hotspots" \
            --argjson files "$_h_quality_files" \
            --arg git_head "$_h_quality_head" \
            --arg scanned_at "$_h_quality_scanned" \
            --argjson stale "$_h_quality_stale" \
            --arg baseline_note "$_h_quality_baseline_note" \
            '{available: true, score: $score, baseline_note: $baseline_note, hotspot_count: $hotspots, total_files: $files, git_head: $git_head, scanned_at: $scanned_at, stale: $stale}')
    else
        quality_obj='{"available":false}'
    fi
    # shellcheck disable=SC1010  # 'done' is a jq arg name, not the bash keyword
    jq -n \
        --arg status "$_h_status_text" \
        --arg fts_integrity "$_h_fts_integrity" \
        --argjson score "$_h_health_score" \
        --argjson total_nodes "$_h_total_nodes" \
        --argjson active "$_h_active" \
        --argjson ready "$_h_ready" \
        --argjson blocked "$_h_blocked" \
        --argjson blocked_external "$_h_blocked_ext" \
        --argjson done "$_h_done_count" \
        --argjson pending "$_h_pending" \
        --argjson total_edges "$_h_total_edges" \
        --argjson blocking_edges "$_h_blocking_edges" \
        --argjson total_pitfalls "$_h_total_pitfalls" \
        --argjson addressed_pitfalls "$_h_addressed_pitfalls" \
        --argjson unaddressed_pitfalls "$_h_unaddressed_pitfalls" \
        --argjson orphan_nodes "$_h_orphan_nodes" \
        --slurpfile orphan_ids <(printf '%s' "$_h_orphan_ids") \
        --argjson intentional_standalones "$_h_intentional_standalones" \
        --slurpfile intentional_standalone_ids <(printf '%s' "$_h_intentional_standalone_ids") \
        --argjson ghost_edges "$_h_ghost_edges" \
        --argjson stale_active "$_h_stale_active" \
        --argjson contradictions "$_h_contradictions" \
        --argjson invalid_statuses "$_h_invalid_statuses" \
        --argjson empty_edge_context "$_h_empty_edge_ctx" \
        --argjson fixed_edge_context "$_h_fixed_edge_ctx" \
        --argjson quality "$quality_obj" \
        --argjson ram_total_mb "$_h_ram_total_mb" \
        --argjson ram_available_mb "$_h_ram_available_mb" \
        --argjson shm_used_mb "$_h_shm_used_mb" \
        --argjson shm_total_mb "$_h_shm_total_mb" \
        --argjson db_size_kb "$_h_db_size_kb" \
        --argjson gh_duplicates "$_h_gh_duplicates" \
        --slurpfile gh_duplicate_issues <(printf '%s' "$_h_gh_duplicate_issues") \
        '# The three id lists are uncapped, one entry per matching node or
        # issue: files, not argv, past which execve fails E2BIG (wv-200d36).
        $orphan_ids[0] as $orphan_ids
        | $intentional_standalone_ids[0] as $intentional_standalone_ids
        | $gh_duplicate_issues[0] as $gh_duplicate_issues
        | {
            status: $status,
            fts_integrity: $fts_integrity,
            score: $score,
            nodes: {
                total: $total_nodes,
                active: $active,
                ready: $ready,
                blocked: $blocked,
                blocked_external: $blocked_external,
                done: $done,
                pending: $pending
            },
            edges: {
                total: $total_edges,
                blocking: $blocking_edges
            },
            pitfalls: {
                total: $total_pitfalls,
                addressed: $addressed_pitfalls,
                unaddressed: $unaddressed_pitfalls
            },
            issues: {
                orphan_nodes: $orphan_nodes,
                orphan_ids: $orphan_ids,
                intentional_standalones: $intentional_standalones,
                intentional_standalone_ids: $intentional_standalone_ids,
                ghost_edges: $ghost_edges,
                stale_active: $stale_active,
                unresolved_contradictions: $contradictions,
                invalid_statuses: $invalid_statuses,
                empty_edge_context: $empty_edge_context,
                fixed_edge_context: $fixed_edge_context,
                gh_duplicates: $gh_duplicates,
                gh_duplicate_issues: $gh_duplicate_issues
            },
            code_quality: $quality,
            system: {
                ram_total_mb: $ram_total_mb,
                ram_available_mb: $ram_available_mb,
                shm_used_mb: $shm_used_mb,
                shm_total_mb: $shm_total_mb,
                db_size_kb: $db_size_kb
            }
        }'
}

# Emit health report as text. Args: $1=verbose flag
_health_format_text() {
    local verbose="$1"

    echo -e "${CYAN}Weave Health Check${NC} $_h_status_icon"
    echo ""
    echo -e "${CYAN}Score:${NC} $_h_health_score/100 ($_h_status_text)"
    if [ "$_h_fts_integrity" = failed ]; then
        echo "  FTS5 index check failed or unavailable — run: wv doctor"
    fi
    echo ""
    echo -e "${CYAN}Nodes:${NC}"
    echo "  Total: $_h_total_nodes"
    local blocked_line="Active: $_h_active | Ready: $_h_ready | Blocked: $_h_blocked"
    if [ "$_h_blocked_ext" -gt 0 ]; then
        blocked_line="${blocked_line} | Blocked-Ext: $_h_blocked_ext"
    fi
    echo "  ${blocked_line} | Done: $_h_done_count | Pending: $_h_pending"
    echo ""
    echo -e "${CYAN}Edges:${NC}"
    echo "  Total: $_h_total_edges (blocking: $_h_blocking_edges)"
    echo ""
    echo -e "${CYAN}Pitfalls:${NC}"
    if [ "$_h_unaddressed_pitfalls" -gt 0 ]; then
        echo -e "  Total: $_h_total_pitfalls | Addressed: $_h_addressed_pitfalls | ${RED}Unaddressed: $_h_unaddressed_pitfalls${NC}"
    else
        echo -e "  Total: $_h_total_pitfalls | Addressed: $_h_addressed_pitfalls | ${GREEN}Unaddressed: $_h_unaddressed_pitfalls${NC}"
    fi
    echo ""
    echo -e "${CYAN}Quality:${NC}"
    if [ "$_h_quality_available" = "true" ]; then
        echo "  Score: $_h_quality_score/100"
        # A bare 0/100 read as a regression (wv-0f2438); the note comes from
        # the [baseline] section of .weave/quality.conf.
        [ -z "$_h_quality_baseline_note" ] || echo "  $_h_quality_baseline_note"
        echo "  Hotspots: $_h_quality_hotspots files above threshold"
        echo "  Last scan: $_h_quality_scanned (${_h_quality_head:0:7})"
        if [ "$_h_quality_stale" = "true" ]; then
            echo "  Scan is stale or incomplete; run: wv quality scan"
        fi
    else
        echo "  no scan data"
    fi
    echo ""
    echo -e "${CYAN}Cache:${NC}"
    _health_cache_summary

    if [ "$verbose" = true ]; then
        echo ""
        echo -e "${CYAN}Diagnostics:${NC}"
        echo "  Orphan nodes: $_h_orphan_nodes"
        echo "  Intentional standalones: $_h_intentional_standalones (excluded from orphan count)"
        echo "  Ghost edges: $_h_ghost_edges"
        echo "  Stale active (>7d): $_h_stale_active"
        echo "  Unresolved contradictions: $_h_contradictions"
        echo "  Invalid statuses: $_h_invalid_statuses"
        echo "  Empty edge context: $_h_empty_edge_ctx"
        echo ""
        echo -e "${CYAN}System:${NC}"
        echo "  RAM: ${_h_ram_available_mb}MB available / ${_h_ram_total_mb}MB total"
        echo "  tmpfs (/dev/shm): ${_h_shm_used_mb}MB used / ${_h_shm_total_mb}MB total"
        if [ "$_h_db_size_kb" -gt 0 ]; then
            echo "  Hot zone DB: ${_h_db_size_kb}KB"
        fi
    fi

    # Show issues if any
    if [ -n "$_h_issues" ] && [ "$_h_health_score" -lt 100 ]; then
        echo ""
        echo -e "${YELLOW}Issues:${NC}"
        if [ "$_h_unaddressed_pitfalls" -gt 0 ]; then echo -e "  ${YELLOW}⚠${NC} $_h_unaddressed_pitfalls unaddressed pitfall(s) - run 'wv audit-pitfalls'"; fi
        if [ "$_h_stale_active" -gt 0 ]; then echo -e "  ${YELLOW}⚠${NC} $_h_stale_active node(s) active >7 days - consider completing or closing"; fi
        if [ "$_h_contradictions" -gt 0 ]; then echo -e "  ${YELLOW}⚠${NC} $_h_contradictions unresolved contradiction(s) - run 'wv edges <id>' to inspect"; fi
        if [ "$_h_ghost_edges" -gt 0 ]; then echo -e "  ${YELLOW}⚠${NC} $_h_ghost_edges ghost edge(s) referencing deleted nodes - run 'wv clean-ghosts'"; fi
        if [ "$_h_orphan_nodes" -gt 5 ]; then echo -e "  ${YELLOW}⚠${NC} $_h_orphan_nodes orphan node(s) with no edges - consider linking or pruning"; fi
        if [ "${_h_gh_duplicates:-0}" -gt 0 ] 2>/dev/null; then echo -e "  ${YELLOW}⚠${NC} $_h_gh_duplicates GH issue(s) mapped to multiple open nodes - run 'wv health --json | jq .issues.gh_duplicate_issues' to inspect, then 'wv delete <id> --no-gh --dry-run' (use --no-gh to avoid closing an issue still owned by the survivor)"; fi
        if [ "$_h_invalid_statuses" -gt 0 ]; then echo -e "  ${RED}✗${NC} $_h_invalid_statuses node(s) with invalid status - run 'wv update <id> --status=todo' to fix"; fi
        if [ "$_h_empty_edge_ctx" -gt 0 ]; then echo -e "  ${YELLOW}⚠${NC} $_h_empty_edge_ctx edge(s) missing context - run 'wv health --fix' to backfill"; fi
        if [ "$_h_fixed_edge_ctx" -gt 0 ]; then echo -e "  ${GREEN}✓${NC} Fixed: enriched $_h_fixed_edge_ctx edge(s) with auto-context (marked auto:true)"; fi
        if [ "$_h_ram_critical" = true ]; then echo -e "  ${RED}✗${NC} RAM critically low: ${_h_ram_available_mb}MB available — system may OOM kill processes"; fi
        if [ "$_h_ram_warning" = true ]; then echo -e "  ${YELLOW}⚠${NC} RAM low: ${_h_ram_available_mb}MB available — avoid heavy builds (cargo, npm)"; fi
    fi
}

cmd_health() {
    local format="text"
    local verbose=false
    local history_count=0
    local fix=false
    local strict=false
    local fast=false

    while [ $# -gt 0 ]; do
        case "$1" in
            --json) format="json" ;;
            --verbose|-v) verbose=true ;;
            --history) history_count=10 ;;
            --history=*) history_count="${1#--history=}" ;;
            --fix) fix=true ;;
            --strict) strict=true ;;
            --fast) fast=true ;;
            --help|-h) cmd_help health; return 0 ;;
            -*) _wv_reject_arg health "$1"; return 1 ;;  # wv-016983
        esac
        shift
    done

    # Handle --history: show log and exit
    if [ "$history_count" -gt 0 ] 2>/dev/null; then
        _health_show_history "$history_count" "$format"
        return 0
    fi
    # A graph that does not exist scored 100/100 healthy (wv-90083c). One that
    # exists but db_ensure will not migrate (lineage drift) is still probed and
    # scored below, floored and with its recovery (wv-71d076), so only a
    # missing database is refused here.
    if ! db_ensure && [ ! -s "$WV_DB" ]; then
        echo -e "${RED}Error: cannot open the graph database ($WV_DB); not reporting from it${NC}" >&2
        return 1
    fi

    # --fast: score-focused path for hook callers (wv-0d77b1). Skips quality
    # collection — the score is computed before quality and does not depend on
    # it, so the value is exact, not approximate. Freshness reuses the run-cache
    # write sentinel (touched after every successful write command), so any
    # CLI graph write invalidates the cache; the TTL bounds staleness from
    # out-of-band writers that bypass the CLI (direct sqlite, runtime).
    if [ "$fast" = "true" ]; then
        local cache_file="$WV_HOT_ZONE/.health_fast.json"
        local fast_ttl="${WV_HEALTH_FAST_TTL:-300}"

        # Writability probe (wv-71d076). Everything the score is computed from
        # describes the graph's SHAPE — counts, orphans, ghost edges — and none
        # of it moves when the writer-lineage schema drifts. A hot zone that
        # wv sync and wv commit-refs cannot persist to therefore scores 100/100,
        # and session start reports that number at the top of every session.
        # This is the classifier wv doctor already uses, and it costs two
        # pragma_table_info reads.
        local _hf_lineage
        _hf_lineage=$(db_lineage_pair_verdict \
            "$(db_lineage_shape nodes)" "$(db_lineage_shape edges)" 2>/dev/null || echo unknown)
        _health_check_fts

        if [ -f "$cache_file" ]; then
            local _hf_now _hf_mtime _hf_age _hf_fresh=true
            _hf_now=$(date +%s)
            _hf_mtime=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null || echo 0)
            _hf_age=$((_hf_now - _hf_mtime))
            [ "$_hf_age" -le "$fast_ttl" ] || _hf_fresh=false
            # Strictly newer than the write sentinel, as the run cache (wv-228099).
            if [ -f "$WV_RUN_CACHE_SENTINEL" ] && ! [ "$cache_file" -nt "$WV_RUN_CACHE_SENTINEL" ]; then
                _hf_fresh=false
            fi
            # The cache is invalidated by CLI writes and by time, and a schema
            # drift is neither: a CLI upgrade or an out-of-band migration moves
            # the verdict without touching the write sentinel. Without this the
            # cached 100 outlives the drift for the whole TTL, which is exactly
            # the stale reassurance this probe was added to remove. A cache
            # written before the probe existed has no .lineage and is treated as
            # a mismatch, so the first run after an upgrade recomputes.
            if [ "$_hf_fresh" = "true" ] \
               && [ "$(jq -r '.lineage // "unrecorded"' "$cache_file" 2>/dev/null)" != "$_hf_lineage" ]; then
                _hf_fresh=false
            fi
            if [ "$_hf_fresh" = "true" ] \
               && [ "$(jq -r '.fts_integrity // "unrecorded"' "$cache_file" 2>/dev/null)" != "$_h_fts_integrity" ]; then
                _hf_fresh=false
            fi
            if [ "$_hf_fresh" = "true" ]; then
                if [ "$format" = "json" ]; then
                    cat "$cache_file" || return 1
                else
                    echo "Health: $(jq -r '.score' "$cache_file" 2>/dev/null)/100 (fast, cached)"
                    jq -r '.recovery // empty' "$cache_file" 2>/dev/null \
                        | while read -r _hf_rec; do
                              echo "  graph is not writable or could not be verified — inspect with: $_hf_rec" >&2
                          done
                    [ "$_h_fts_integrity" != failed ] || echo "  FTS5 index check failed or unavailable — run: wv doctor" >&2
                fi
                [ "$_h_fts_integrity" != failed ]
                return $?
            fi
        fi
        _health_collect_metrics
        _health_compute_score

        # A graph that cannot be written is not healthy at any shape score, so
        # the verdict floors it rather than subtracting from it. The three
        # tiers mirror wv doctor's, from the same classifier: canonical passes,
        # preinit is benign (db_init has not run yet, which is the ordinary
        # state of a fresh hot zone at session start), anything else fails.
        # 'unknown' means the probe itself could not run; that is reported but
        # does not floor, because a probe failure is not evidence of drift.
        local _hf_score="${_h_health_score:-0}" _hf_recovery=""
        case "$_hf_lineage" in
            canonical|preinit|unknown) ;;
            *)
                _hf_score=0
                # shellcheck disable=SC2016  # a recovery command printed for the user to run, literal by design
                _hf_recovery='rm -rf "$WV_HOT_ZONE" && wv load'
                ;;
        esac
        if [ "$_h_fts_integrity" = failed ]; then
            _hf_score=0
            [ -n "$_hf_recovery" ] || _hf_recovery='wv doctor'
        fi

        # Append to the same trend log as the full path (only on recompute —
        # a cache hit means the DB is unchanged, so the data point is a duplicate).
        # The floored score is what gets logged: the trend should show the drift,
        # not the shape score that ignored it.
        if [ -d "$WEAVE_DIR" ]; then
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%S)" \
                "$_hf_score" "$_h_total_nodes" "$_h_total_edges" \
                "$_h_orphan_nodes" "$_h_ghost_edges" >> "$WEAVE_DIR/health.log"
        fi
        local _hf_json
        _hf_json=$(jq -n \
            --arg score "$_hf_score" \
            --arg nodes "${_h_total_nodes:-0}" \
            --arg edges "${_h_total_edges:-0}" \
            --arg orphans "${_h_orphan_nodes:-0}" \
            --arg lineage "$_hf_lineage" \
            --arg fts_integrity "$_h_fts_integrity" \
            --arg recovery "$_hf_recovery" \
            '{"score":($score|tonumber),"total_nodes":($nodes|tonumber),"total_edges":($edges|tonumber),"orphan_nodes":($orphans|tonumber),"fast":true,"lineage":$lineage,"fts_integrity":$fts_integrity}
             + (if $recovery == "" then {} else {"recovery":$recovery} end)') || return 1
        # Cache storage is optional; its refusal must not substitute an older
        # healthy payload for the verdict just computed.
        { printf '%s\n' "$_hf_json" > "$cache_file.tmp" && mv "$cache_file.tmp" "$cache_file"; } 2>/dev/null \
            || rm -f "$cache_file.tmp" 2>/dev/null
        if [ "$format" = "json" ]; then
            printf '%s\n' "$_hf_json"
        else
            echo "Health: ${_hf_score}/100 (fast)"
            [ -n "$_hf_recovery" ] && \
                echo "  graph is not writable or could not be verified (lineage=$_hf_lineage) — inspect with: $_hf_recovery" >&2
            [ "$_h_fts_integrity" != failed ] || echo "  FTS5 index check failed or unavailable — run: wv doctor" >&2
        fi
        [ "$_h_fts_integrity" != failed ]
        return $?
    fi

    # Collect all metrics, compute score, gather quality info
    _health_collect_metrics
    _health_compute_score
    _health_collect_quality

    # Append to health history log only if this project has been initialised with wv-init-repo.
    # Guard prevents auto-creating .weave/ in repos that never opted in.
    local log_file="$WEAVE_DIR/health.log"
    if [ -d "$WEAVE_DIR" ]; then
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%S)" \
            "$_h_health_score" "$_h_total_nodes" "$_h_total_edges" \
            "$_h_orphan_nodes" "$_h_ghost_edges" >> "$log_file"
    fi

    # Backfill empty edge context if --fix
    if [ "$fix" = "true" ]; then
        _health_fix_edges
    fi

    # Format output
    if [ "$format" = "json" ]; then
        _health_format_json "$strict" || return 1
        # JSON callers parse the output — warnings exit 0 unless --strict.
        if [ "$_h_fts_integrity" = failed ] || [ "$_h_invalid_statuses" -gt 0 ] || [ "$_h_contradictions" -gt 0 ]; then
            return 1
        fi
        if [ "$strict" = true ] && [ "$_h_health_score" -lt 100 ]; then
            return 1
        fi
        return 0
    fi

    _health_format_text "$verbose"

    # Exit code logic:
    # - Default: exit 0 (warnings are informational, not errors)
    # - --strict: exit 1 if score < 100 (for CI fail-on-warning)
    # - Always exit 1 for failed index checks, invalid statuses, contradictions
    if [ "$_h_fts_integrity" = failed ] || [ "$_h_invalid_statuses" -gt 0 ] || [ "$_h_contradictions" -gt 0 ]; then
        return 1
    fi
    if [ "$strict" = true ] && [ "$_h_health_score" -lt 100 ]; then
        return 1
    fi
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_cache — Claude Code session cache health
# ═══════════════════════════════════════════════════════════════════════════

cmd_cache() {
    local format="text"
    local sessions_n=3
    local all_projects=false

    while [ $# -gt 0 ]; do
        case "$1" in
            --json)          format="json" ;;
            --sessions=*)    sessions_n="${1#--sessions=}" ;;
            --sessions)      shift; sessions_n="${1:-3}" ;;
            --all)           all_projects=true ;;
            --help|-h)
                cat >&2 <<'EOF'
Usage: wv cache [options]

Check Claude Code prompt-cache health for the current project.

Options:
  --sessions=N   Number of recent sessions to analyse (default: 3)
  --all          Include sessions from all projects, not just current
  --json         JSON output

Ratios:
  >65%  OK      — cache is working
  35-65% LOW    — possible warm-up or light bug impact
  <35%  BAD     — likely affected by a cache bug

Bugs:
  Sentinel (Bug 1): standalone Bun binary; every turn re-creates cache
  Resume (Bug 2):   deferred_tools_delta stripped on session save/resume
EOF
                return 0
                ;;
            -*) _wv_reject_arg cache "$1"; return 1 ;;  # wv-016983
        esac
        shift
    done

    # Detect Claude Code install type
    local claude_bin claude_type="unknown"
    claude_bin=$(command -v claude 2>/dev/null || echo "")
    if [ -n "$claude_bin" ]; then
        local real_bin
        real_bin=$(readlink -f "$claude_bin" 2>/dev/null || echo "$claude_bin")
        if file "$real_bin" 2>/dev/null | grep -q "ELF"; then
            claude_type="standalone-bun"
        elif file "$real_bin" 2>/dev/null | grep -q "script"; then
            claude_type="npx-script"
        fi
    fi

    # Resolve project session directories
    local projects_dir="$HOME/.claude/projects"
    local session_dirs=()
    if [ "$all_projects" = true ]; then
        while IFS= read -r d; do session_dirs+=("$d"); done < <(
            find "$projects_dir" -maxdepth 1 -mindepth 1 -type d 2>/dev/null
        )
    else
        local proj_slug
        proj_slug=$(pwd | tr '/' '-')
        local proj_dir="$projects_dir/${proj_slug}"
        [ -d "$proj_dir" ] && session_dirs=("$proj_dir")
    fi

    if [ ${#session_dirs[@]} -eq 0 ]; then
        echo "No Claude Code session data found for this project." >&2
        echo "Run 'wv cache --all' to check all projects." >&2
        return 0
    fi

    # Collect JSONL paths (most recent N per dir, sorted by mtime)
    local jsonl_list=""
    for dir in "${session_dirs[@]}"; do
        local found
        found=$(find "$dir" -maxdepth 1 -name "*.jsonl" -printf "%T@ %p\n" 2>/dev/null \
            | sort -rn | head -"$sessions_n" | awk '{print $2}')
        [ -n "$found" ] && jsonl_list="$jsonl_list"$'\n'"$found"
    done
    jsonl_list=$(printf '%s' "$jsonl_list" | grep -v '^$')

    if [ -z "$jsonl_list" ]; then
        echo "No session JSONL files found." >&2
        return 0
    fi

    # Write path list to a temp file so the Python heredoc can use stdin cleanly
    local _cache_tmp
    _cache_tmp=$(mktemp /tmp/wv-cache-XXXXXX.txt)
    echo "$jsonl_list" > "$_cache_tmp"
    # shellcheck disable=SC2064
    trap "rm -f '$_cache_tmp'" RETURN

    python3 - "$format" "$claude_type" "$_cache_tmp" <<'PYEOF'
import sys, json, os

format_out  = sys.argv[1]
claude_type = sys.argv[2]
paths_file  = sys.argv[3]

with open(paths_file) as pf:
    paths_raw = pf.read().strip().split('\n')
paths = [p for p in paths_raw if p and os.path.exists(p)]
paths.sort(key=os.path.getmtime, reverse=True)

def analyse(path):
    total_read = total_create = turns = 0
    has_deferred = False
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                e = json.loads(line)
            except json.JSONDecodeError:
                continue
            usage = e.get("usage")
            if usage is None:
                msg = e.get("message", {})
                if isinstance(msg, dict):
                    usage = msg.get("usage")
            if isinstance(usage, dict):
                total_read  += usage.get("cache_read_input_tokens", 0) or 0
                total_create += usage.get("cache_creation_input_tokens", 0) or 0
                turns += 1
            if "deferred_tools_delta" in str(e.get("content", "")):
                has_deferred = True
    total = total_read + total_create
    ratio = total_read / total if total > 0 else None
    return {
        "session_id": os.path.basename(path).replace(".jsonl", "")[:8],
        "path": path,
        "turns": turns,
        "cache_read": total_read,
        "cache_create": total_create,
        "ratio": ratio,
        "has_deferred_tools_delta": has_deferred,
        "status": (
            "ok"  if ratio is not None and ratio > 0.65 else
            "low" if ratio is not None and ratio > 0.35 else
            "bad" if ratio is not None else
            "no_data"
        ),
    }

results = []
for p in paths:
    try:
        results.append(analyse(p))
    except Exception as e:
        pass

if format_out == "json":
    out = {
        "claude_type": claude_type,
        "sessions": results,
    }
    if results:
        reads  = [r["cache_read"]   for r in results if r["ratio"] is not None]
        writes = [r["cache_create"] for r in results if r["ratio"] is not None]
        total  = sum(reads) + sum(writes)
        out["aggregate_ratio"] = sum(reads) / total if total > 0 else None
    print(json.dumps(out, indent=2))
    sys.exit(0)

# ── text output ──────────────────────────────────────────────────────────
CYAN  = "\033[0;36m"
GREEN = "\033[0;32m"
YELLOW= "\033[1;33m"
RED   = "\033[0;31m"
NC    = "\033[0m"

def status_colour(s):
    if s == "ok":      return f"{GREEN}OK{NC}"
    if s == "low":     return f"{YELLOW}LOW{NC}"
    if s == "bad":     return f"{RED}BAD{NC}"
    return f"{YELLOW}no data{NC}"

def ratio_str(r):
    if r is None:
        return "   n/a"
    return f"{r:5.1%}"

type_label = {
    "standalone-bun": f"{YELLOW}standalone (Bun){NC}",
    "npx-script":     f"{GREEN}npx/script{NC}",
}.get(claude_type, claude_type)

print(f"\nClaude Code install: {type_label}")
if claude_type == "standalone-bun":
    print(f"  {YELLOW}Sentinel bug (Bug 1) risk — consider alias to npx version{NC}")

# Filter to sessions that actually have usage data
data_sessions = [r for r in results if r["ratio"] is not None]
empty_sessions = [r for r in results if r["ratio"] is None]

if not data_sessions:
    print("\nNo cache data found in recent sessions.")
    if empty_sessions:
        print(f"({len(empty_sessions)} session(s) had no usage entries — may be too short to measure)")
    sys.exit(0)

print(f"\n{'Session':<12} {'Turns':>6}  {'Read':>12}  {'Create':>10}  {'Ratio':>7}  Status")
print("─" * 68)
for r in data_sessions:
    deferred = "  [deferred_tools_delta]" if r["has_deferred_tools_delta"] else ""
    print(
        f"{CYAN}{r['session_id']}{NC}  "
        f"{r['turns']:>6}  "
        f"{r['cache_read']:>12,}  "
        f"{r['cache_create']:>10,}  "
        f"{ratio_str(r['ratio'])}  "
        f"{status_colour(r['status'])}"
        f"{deferred}"
    )

# Aggregate
total_read  = sum(r["cache_read"]   for r in data_sessions)
total_write = sum(r["cache_create"] for r in data_sessions)
total       = total_read + total_write
agg_ratio   = total_read / total if total > 0 else None
agg_status  = (
    "ok"  if agg_ratio is not None and agg_ratio > 0.65 else
    "low" if agg_ratio is not None and agg_ratio > 0.35 else
    "bad"
)

print("─" * 68)
print(
    f"{'Aggregate':<12}  "
    f"{'':>6}  "
    f"{total_read:>12,}  "
    f"{total_write:>10,}  "
    f"{ratio_str(agg_ratio)}  "
    f"{status_colour(agg_status)}"
)

if empty_sessions:
    print(f"\n({len(empty_sessions)} short session(s) excluded — no usage data)")

# Advisory
if any(r["has_deferred_tools_delta"] for r in data_sessions):
    print(f"\n{YELLOW}deferred_tools_delta found — monitor for Bug 2 (session resume regression){NC}")

if agg_status in ("low", "bad"):
    print(f"\n{YELLOW}Cache health is degraded. Possible causes:{NC}")
    if claude_type == "standalone-bun":
        print("  - Bug 1 (sentinel): switch to 'npx @anthropic-ai/claude-code'")
    print("  - Bug 2 (resume): check for deferred_tools_delta in sessions")
    print("  - Short/fresh sessions (normal for <5 turns)")
PYEOF
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_audit_pitfalls — Show pitfalls with resolution status
# Default: unaddressed only, top 20 (output budget D3). --all for the full dump.
# ═══════════════════════════════════════════════════════════════════════════

cmd_audit_pitfalls() {
    local format="text"
    # Output budget (docs/PROPOSAL-wv-output-budget.md D3): the audit's purpose
    # is "what is still open" — default to unaddressed only, top 20. --all dumps.
    local show_addressed=false
    local show_unaddressed=true
    local top=20

    while [ $# -gt 0 ]; do
        case "$1" in
            --json) format="json" ;;
            --only-unaddressed) show_addressed=false; show_unaddressed=true ;;
            --only-addressed) show_addressed=true; show_unaddressed=false ;;
            --top=*) top="${1#*=}" ;;
            --all) show_addressed=true; show_unaddressed=true; top=0 ;;
            --help|-h) cmd_help audit-pitfalls; return 0 ;;
            -*) _wv_reject_arg audit-pitfalls "$1"; return 1 ;;  # wv-016983
        esac
        shift
    done
    case "$top" in
        ''|*[!0-9]*) top=20 ;;
    esac
    wv_require_graph || return 1

    # Query all nodes with pitfall metadata
    local query="
        SELECT id, text, status, json(metadata) as metadata FROM nodes
        WHERE json_extract(metadata, '\$.pitfall') IS NOT NULL
        ORDER BY updated_at DESC;
    "

    local results
    results=$(db_query_json "$query")
    local count
    [ -z "$results" ] && count=0 || count=$(echo "$results" | jq 'length' 2>/dev/null || echo "0")

    if [ "$count" = "0" ] || [ "$count" = "" ]; then
        echo "No pitfalls recorded yet."
        return
    fi

    # Addressed/eligible counts up front — they drive the truncation summary.
    local total_addressed
    total_addressed=$(db_query "
        SELECT COUNT(DISTINCT pitfall) FROM ($(wv_pitfall_resolver_edges_sql))
        WHERE pitfall IN (
            SELECT id FROM nodes
            WHERE json_extract(metadata, '\$.pitfall') IS NOT NULL
        )
    " 2>/dev/null || echo "0")
    local total_unaddressed=$((count - total_addressed))
    local eligible=0
    if [ "$show_addressed" = true ]; then
        eligible=$((eligible + total_addressed))
    fi
    if [ "$show_unaddressed" = true ]; then
        eligible=$((eligible + total_unaddressed))
    fi

    # For each pitfall node, check for a resolver (wv_pitfall_resolver_edges_sql)
    local shown=0
    echo "$results" | jq -c '.[]' | while IFS= read -r row; do
        # At cap: keep draining stdin (break would SIGPIPE jq under pipefail)
        # but skip all per-row work.
        if [ "$top" -gt 0 ] && [ "$shown" -ge "$top" ]; then
            continue
        fi
        local id text status pitfall
        id=$(echo "$row" | jq -r '.id')
        text=$(echo "$row" | jq -r '.text')
        status=$(echo "$row" | jq -r '.status')
        local metadata
        metadata=$(echo "$row" | jq -r '.metadata // "{}"')

        if [ "${metadata:0:1}" != "{" ]; then
            metadata=$(echo "$metadata" | jq -r '.' 2>/dev/null || echo "{}")
        fi

        pitfall=$(echo "$metadata" | jq -r '.pitfall // empty' 2>/dev/null)

        # Check for incoming resolution edges
        local resolvers
        resolvers=$(db_query "
            SELECT resolver FROM ($(wv_pitfall_resolver_edges_sql))
            WHERE pitfall='$id'
        " 2>/dev/null || echo "")

        local is_addressed=false
        if [ -n "$resolvers" ]; then
            local resolver_count
            resolver_count=$(echo "$resolvers" | wc -l)
            [ "$resolver_count" -gt 0 ] && is_addressed=true
        fi

        if [ "$is_addressed" = true ]; then
            [ "$show_addressed" = false ] && continue
        else
            [ "$show_unaddressed" = false ] && continue
        fi

        shown=$((shown + 1))

        if [ "$format" = "json" ]; then
            local resolver_ids
            if [ -n "$resolvers" ]; then
                resolver_ids=$(echo "$resolvers" | jq -R . | jq -s . 2>/dev/null || echo "[]")
            else
                resolver_ids="[]"
            fi
            jq -c -n \
                --arg id "$id" \
                --arg text "$text" \
                --arg status "$status" \
                --arg pitfall "$pitfall" \
                --argjson addressed "$is_addressed" \
                --argjson resolvers "$resolver_ids" \
                '{id: $id, text: $text, status: $status, pitfall: $pitfall, addressed: $addressed, addressed_by: $resolvers}'
        else
            local status_label node_status_label
            if [ "$is_addressed" = true ]; then
                status_label="${GREEN}[ADDRESSED]${NC}"
            else
                status_label="${RED}[UNADDRESSED]${NC}"
            fi
            # Show node status if not 'done'
            if [ "$status" != "done" ]; then
                node_status_label=" ${YELLOW}(${status})${NC}"
            else
                node_status_label=""
            fi
            echo -e "${CYAN}$id${NC} ${status_label}${node_status_label}: $text"
            echo -e "  ${YELLOW}Pitfall:${NC} $pitfall"

            if [ -n "$resolvers" ]; then
                echo -e "  ${GREEN}Addressed by:${NC}"
                echo "$resolvers" | while IFS= read -r resolver_id; do
                    [ -z "$resolver_id" ] && continue
                    local resolver_text
                    resolver_text=$(db_query "SELECT text FROM nodes WHERE id='$resolver_id';" 2>/dev/null)
                    echo "    - $resolver_id: $resolver_text"
                done
            fi
            echo ""
        fi
    done | if [ "$format" = "json" ]; then jq -s .; else cat; fi

    if [ "$format" != "json" ]; then
        echo -e "${CYAN}Summary:${NC}"
        echo -e "  Total pitfalls: $count"
        echo -e "  ${GREEN}Addressed: $total_addressed${NC}"
        echo -e "  ${RED}Unaddressed: $total_unaddressed${NC}"
        if [ "$top" -gt 0 ] && [ "$eligible" -gt "$top" ]; then
            echo -e "  ${YELLOW}Showing $top of $eligible matching — use --all for the full list${NC}"
        fi
    elif [ "$top" -gt 0 ] && [ "$eligible" -gt "$top" ]; then
        echo "wv audit-pitfalls: showing $top of $eligible (use --all for the full list)" >&2
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_pattern_audit — CI regression net for control-plane patterns
# Checks:
#   1. Every dispatch entry is in cache read, write, or exempt list.
#   2. Domain enum strings have exactly one definition (no silent drift).
#   3. No raw echo writes to .session_phase outside wv_set_phase.
#   4. Required Claude hooks source wv-hook-common.sh.
#   5. pre-action.sh stays a thin dispatcher (<= 60 lines).
#   6. Node-state invariant: no node declares deferral in metadata
#      (deferred/blocked_on) while still in the ready queue (todo + no
#      non-done blocks edge). See docs/PROPOSAL-graph-as-policy-boundary.md.
#   7. No non-predicate function ends in a bare `[ cond ] && cmd` tail.
#   8. Raw sqlite3 reads of quality.db stay inside blessed quality helpers.
# See docs/PROPOSAL-wv-pattern-crystallization.md for context.
# ═══════════════════════════════════════════════════════════════════════════

cmd_pattern_audit() {
    local format="text"
    local strict=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --json)   format="json" ;;
            --strict) strict=1 ;;
            --help|-h)
                echo "Usage: wv pattern-audit [--json] [--strict]"
                echo ""
                echo "  --json    machine-readable output"
                echo "  --strict  exit 1 if any issues found (for CI use)"
                return 0 ;;
            *) echo -e "${RED}Unknown option: $1${NC}" >&2; return 1 ;;
        esac
        shift
    done

    local issues=0
    local findings_json="[]"

    # ── Check 1: capability registry totality ───────────────────────────────
    # Every command in the dispatch table must have a row in
    # contracts/command-capabilities.json, which _wv_cap_known projects. An
    # unclassified command is a latent cache-invalidation bug and an evidence
    # hole at once: nothing decides whether the run cache may serve it, and E1
    # cannot say whether it mutates.

    # Self-reference the checkout actually running this check, not whatever
    # "wv" happens to resolve on PATH — a stale/newer installed binary can
    # have a different dispatch table than a git-worktree or historical-tag
    # checkout, producing a false FAIL (wv-dfaa75). Same fallback convention
    # as _hook_active_id/_wv_concurrent_session.
    local wv_bin
    wv_bin="${WV:-${WV_CLI:-$SCRIPT_DIR/wv}}"
    local wv_script
    wv_script=$(readlink -f "$wv_bin" 2>/dev/null || echo "$wv_bin")

    local dispatch_cmds unclassified_cmds=""
    if [ -f "$wv_script" ]; then
        while IFS= read -r cmd; do
            [ -z "$cmd" ] && continue
            if ! _wv_cap_known "$cmd" 2>/dev/null; then
                unclassified_cmds="${unclassified_cmds:+$unclassified_cmds|}$cmd"
            fi
        done < <(grep -E '^\s+[a-z][a-zA-Z_-]+\)' "$wv_script" \
                   | sed 's/[[:space:]]//g; s/).*$//' \
                   | grep -vE '^\-|\*|^esac' \
                   | sort -u)
    fi

    if [ -n "$unclassified_cmds" ]; then
        local unclassified_list
        unclassified_list=$(echo "$unclassified_cmds" | tr '|' '\n' | sort)
        if [ "$format" = "text" ]; then
            echo -e "${RED}✗ Check 1 FAIL: commands with no capability registry row:${NC}"
            echo "$unclassified_list" | while read -r c; do echo "    $c"; done
            echo -e "  Add a row to contracts/command-capabilities.json, then:"
            echo -e "    python3 scripts/weave_registry.py validate && python3 scripts/weave_registry.py generate"
        fi
        local count
        count=$(echo "$unclassified_cmds" | tr '|' '\n' | wc -l | tr -d ' ')
        local cmds_readable
        cmds_readable=$(echo "$unclassified_cmds" | tr '|' ',')
        findings_json=$(echo "$findings_json" | jq \
            --arg detail "unclassified commands: $cmds_readable" --argjson n "$count" \
            '. + [{"check":"cache_classification","status":"fail","detail":$detail,"count":$n}]')
        issues=$((issues + count))
    else
        [ "$format" = "text" ] && echo -e "${GREEN}✓ Check 1 PASS: every dispatch command has a capability registry row${NC}"
        findings_json=$(echo "$findings_json" | jq \
            '. + [{"check":"cache_classification","status":"pass","detail":"all commands classified","count":0}]')
    fi

    # ── Check 2: domain enum duplicate detection ────────────────────────────
    # Known domain enums must have exactly one definition. More than one means
    # a consumer copy has drifted or been forgotten when the canonical moved.

    # Resolve roots for scripts + hook checks.
    local _scripts_root _project_root _git_root
    _git_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    if [ -n "$_git_root" ] && [ -d "$_git_root/scripts" ]; then
        _project_root="$_git_root"
        _scripts_root="$_git_root/scripts"
    elif [ -n "${WV_PROJECT_DIR:-}" ] && [ -d "${WV_PROJECT_DIR}/scripts" ]; then
        _project_root="$WV_PROJECT_DIR"
        _scripts_root="${WV_PROJECT_DIR}/scripts"
    elif [ -n "${WV_LIB_DIR:-}" ] && [ -d "$(dirname "$WV_LIB_DIR")" ]; then
        _scripts_root=$(cd "$(dirname "$WV_LIB_DIR")" 2>/dev/null && pwd -P)
        _project_root=$(cd "${_scripts_root}/.." 2>/dev/null && pwd -P)
    else
        _scripts_root=$(dirname "$wv_script" 2>/dev/null || echo "")
        _project_root=$(cd "${_scripts_root}/.." 2>/dev/null && pwd -P)
    fi

    local enum_issues=0
    local enum_detail=""

    local -a KNOWN_ENUMS
    KNOWN_ENUMS=(
        "VALID_STATUSES"
        "VALID_EDGE_TYPES"
        "FINDING_VIOLATION_TYPES"
    )

    for enum_name in "${KNOWN_ENUMS[@]}"; do
        local def_count def_files
        # Count assignment lines: VAR_NAME="..." (not references like $VAR_NAME or --arg VAR_NAME)
        local search_root="${_project_root:-}/scripts"
        [ -d "$search_root" ] || search_root="${_scripts_root:-}"
        if [ -n "$search_root" ] && [ -d "$search_root" ]; then
            def_files=$(grep -rl -- "^${enum_name}=" "$search_root" 2>/dev/null | sort | tr '\n' ' ' | sed 's/[[:space:]]*$//')
            def_count=$(echo "$def_files" | tr ' ' '\n' | grep -c '[^[:space:]]' 2>/dev/null) || def_count=0
        else
            def_files=""
            def_count=0
        fi

        if [ "$def_count" -gt 1 ]; then
            if [ "$format" = "text" ]; then
                echo -e "${RED}✗ Check 2 FAIL: ${enum_name} defined in ${def_count} files — drift risk:${NC}"
                echo "$def_files" | tr ' ' '\n' | while read -r f; do [ -n "$f" ] && echo "    $f"; done
            fi
            enum_detail="${enum_detail:+$enum_detail; }${enum_name} in ${def_count} files"
            enum_issues=$((enum_issues + 1))
            issues=$((issues + 1))
        elif [ "$def_count" -eq 0 ]; then
            if [ "$format" = "text" ]; then
                echo -e "${YELLOW}⚠ Check 2 WARN: ${enum_name} not found — may be renamed or removed${NC}"
            fi
        else
            [ "$format" = "text" ] && echo -e "${GREEN}✓ Check 2 PASS: ${enum_name} — single definition${NC}"
        fi
    done

    if [ "$enum_issues" -eq 0 ]; then
        findings_json=$(echo "$findings_json" | jq \
            '. + [{"check":"enum_duplicates","status":"pass","detail":"all domain enums have single definition","count":0}]')
    else
        findings_json=$(echo "$findings_json" | jq \
            --arg detail "$enum_detail" --argjson n "$enum_issues" \
            '. + [{"check":"enum_duplicates","status":"fail","detail":$detail,"count":$n}]')
    fi

    # ── Check 3: phase writes must route via wv_set_phase ──────────────────
    local phase_write_hits
    local _phase_search_a="$_project_root/scripts"
    local _phase_search_b="$_project_root/.claude/hooks"
    [ -d "$_phase_search_a" ] || _phase_search_a="$_scripts_root"
    phase_write_hits=$(grep -RIn --include='*.sh' -E 'echo[[:space:]].*>[[:space:]]*[^[:space:]]*\.session_phase' \
        "$_phase_search_a" "$_phase_search_b" 2>/dev/null \
        | awk -F: '$3 !~ /^[[:space:]]*#/' \
        | grep -v 'scripts/lib/wv-config.sh' \
        | grep -v '/tests/' \
        || true)

    if [ -n "$phase_write_hits" ]; then
        local phase_issue_count
        phase_issue_count=$(echo "$phase_write_hits" | grep -c .) || phase_issue_count=0
        if [ "$format" = "text" ]; then
            echo -e "${RED}✗ Check 3 FAIL: raw .session_phase writes detected (use wv_set_phase):${NC}"
            echo "$phase_write_hits" | while IFS= read -r hit; do [ -n "$hit" ] && echo "    $hit"; done
        fi
        findings_json=$(echo "$findings_json" | jq \
            --arg detail "raw .session_phase writes outside wv_set_phase" --argjson n "$phase_issue_count" \
            '. + [{"check":"phase_writes","status":"fail","detail":$detail,"count":$n}]')
        issues=$((issues + phase_issue_count))
    else
        [ "$format" = "text" ] && echo -e "${GREEN}✓ Check 3 PASS: .session_phase writes route through wv_set_phase${NC}"
        findings_json=$(echo "$findings_json" | jq \
            '. + [{"check":"phase_writes","status":"pass","detail":"no raw .session_phase writes found","count":0}]')
    fi

    # ── Check 4: required hooks load wv-hook-common.sh ─────────────────────
    # Directly or through the library an adapter sources; the rule is
    # _hook_common_unwired's, shared with wv doctor (wv-b80a86).
    local _hooks_dir="$_project_root/.claude/hooks"
    if [ -d "$_hooks_dir" ]; then
        local hook_unwired hook_missing hook_missing_count
        local hook_total=7
        hook_unwired=$(_hook_common_unwired "$_project_root")
        hook_missing_count=$(grep -c . <<< "$hook_unwired") || hook_missing_count=0
        hook_missing=$(paste -sd, - <<< "$hook_unwired" | sed 's/,/, /g')

        if [ "$hook_missing_count" -gt 0 ]; then
            if [ "$format" = "text" ]; then
                echo -e "${RED}✗ Check 4 FAIL: required hooks missing wv-hook-common sourcing:${NC}"
                echo "    $hook_missing"
            fi
            findings_json=$(echo "$findings_json" | jq \
                --arg detail "missing hook-common source in: $hook_missing" --argjson n "$hook_missing_count" \
                '. + [{"check":"hook_common_sourcing","status":"fail","detail":$detail,"count":$n}]')
            issues=$((issues + hook_missing_count))
        else
            [ "$format" = "text" ] && echo -e "${GREEN}✓ Check 4 PASS: all required hooks source wv-hook-common.sh${NC}"
            findings_json=$(echo "$findings_json" | jq \
                --arg detail "all $hook_total required hooks source wv-hook-common.sh" \
                '. + [{"check":"hook_common_sourcing","status":"pass","detail":$detail,"count":0}]')
        fi
    else
        [ "$format" = "text" ] && echo -e "${YELLOW}⚠ Check 4 WARN: .claude/hooks not found — skipped${NC}"
        findings_json=$(echo "$findings_json" | jq \
            '. + [{"check":"hook_common_sourcing","status":"warn","detail":".claude/hooks not found; check skipped","count":0}]')
    fi

    # ── Check 5: pre-action.sh thin-dispatcher contract (≤ 60 lines) ────────
    local _pa_hook="$_project_root/.claude/hooks/pre-action.sh"
    if [ -f "$_pa_hook" ]; then
        local pa_lines
        pa_lines=$(wc -l < "$_pa_hook")
        if [ "$pa_lines" -gt 60 ]; then
            if [ "$format" = "text" ]; then
                echo -e "${RED}✗ Check 5 FAIL: pre-action.sh is $pa_lines lines (limit 60)${NC}"
            fi
            findings_json=$(echo "$findings_json" | jq \
                --argjson n "$pa_lines" \
                '. + [{"check":"thin_dispatcher","status":"fail","detail":"pre-action.sh exceeds 60-line limit","count":$n}]')
            issues=$((issues + 1))
        else
            [ "$format" = "text" ] && echo -e "${GREEN}✓ Check 5 PASS: pre-action.sh is $pa_lines lines (limit 60)${NC}"
            findings_json=$(echo "$findings_json" | jq \
                --argjson n "$pa_lines" \
                '. + [{"check":"thin_dispatcher","status":"pass","detail":"pre-action.sh within 60-line thin-dispatcher limit","count":$n}]')
        fi
    else
        [ "$format" = "text" ] && echo -e "${YELLOW}⚠ Check 5 WARN: pre-action.sh not found — skipped${NC}"
        findings_json=$(echo "$findings_json" | jq \
            '. + [{"check":"thin_dispatcher","status":"warn","detail":"pre-action.sh not found; check skipped","count":0}]')
    fi

    # ── Check 6: node-state invariant — deferral must be graph state, not metadata ──
    # A node carrying active deferral metadata (wv_deferral_metadata_predicate:
    # deferred=true / blocked_until future / blocked_on set) while status='todo' with no
    # inbound non-done blocks edge is a state inconsistency: status must be the
    # authoritative signal. Since wv-1f09a6 the read surfaces (cmd_ready/cmd_context via
    # wv_blocking_reason) already treat such a node as blocked — but its status still
    # claims 'todo', so status lies. This check enforces that status reflects the
    # deferral, keeping the metadata form from being a second, unreconciled
    # representation. Uses the SAME canonical predicate as wv_blocking_reason so the
    # checker and the reader cannot drift. Promotes findings wv-8bb0f4 / wv-f752a5 to an
    # enforced gate. A parked node (deferred with a deferred_reason) keeps status todo
    # by design and is exempt; the query is wv doctor's node-state query (wv-5515e9).
    # See docs/PROPOSAL-graph-as-policy-boundary.md.
    local divergent_nodes=""
    if [ -f "$WV_DB" ]; then
        divergent_nodes=$(db_query "
            SELECT id FROM nodes n WHERE $(wv_deferral_divergent_sql n);
        " 2>/dev/null || echo "")
    fi
    if [ -n "$divergent_nodes" ]; then
        local divergent_list dcount
        divergent_list=$(echo "$divergent_nodes" | tr '\n' ' ' | sed 's/ *$//')
        dcount=$(echo "$divergent_nodes" | grep -c .)
        if [ "$format" = "text" ]; then
            echo -e "${RED}✗ Check 6 FAIL: $dcount node(s) carry deferral metadata while status='todo' (status must reflect the deferral):${NC}"
            echo "$divergent_nodes" | while read -r nid; do [ -n "$nid" ] && echo "    $nid"; done
            echo -e "  Encode deferral as state: status=blocked-external (or add a blocks edge), not metadata.deferred/blocked_until/blocked_on alone; to park a node, give metadata.deferred a deferred_reason."
        fi
        findings_json=$(echo "$findings_json" | jq \
            --arg detail "deferred-but-ready nodes: $divergent_list" --argjson n "$dcount" \
            '. + [{"check":"node_state_deferral","status":"fail","detail":$detail,"count":$n}]')
        issues=$((issues + dcount))
    else
        [ "$format" = "text" ] && echo -e "${GREEN}✓ Check 6 PASS: no deferred-but-ready node-state divergence${NC}"
        findings_json=$(echo "$findings_json" | jq \
            '. + [{"check":"node_state_deferral","status":"pass","detail":"deferral encoded as status/edges, not metadata-only","count":0}]')
    fi

    # ── Check 7: no bare [ cond ] && cmd as a function's last statement ─────
    # Such a tail returns 1 when the condition is false; under set -euo
    # pipefail a caller in a plain context aborts. This class shipped >=5
    # bugs (graph learnings + audit finding A3-2). Predicate helpers are
    # exempt by name (^_?(is|has|can)_) or a '# predicate' annotation on the
    # definition line. A '|| ...' alternative on the tail makes it safe.
    local _pa7_scope="$_project_root/scripts"
    if [ -d "$_pa7_scope" ]; then
        # shellcheck disable=SC2016  # $0 and $n are awk fields inside the awk program
        local _pa7_awk='
/^(function[ \t]+)?[A-Za-z_][A-Za-z0-9_]*\(\)[ \t]*[{(][ \t]*(#.*)?$/ {
    fname=$0; sub(/\(\).*/,"",fname); sub(/^function[ \t]+/,"",fname)
    annotated = ($0 ~ /#[ \t]*predicate/) ? 1 : 0
    # A subshell body, name() ( ... ), ends at a column-0 ")" (wv-b80a86).
    body=$0; sub(/^[^(]*\(\)[ \t]*/,"",body); closer = substr(body,1,1) == "{" ? "}" : ")"
    infunc=1; last=""; lastnr=0; next
}
infunc && substr($0,1,1) == closer && $0 ~ /^[})][ \t]*(#.*)?$/ {
    if (last ~ /^[ \t]*\[\[?[^]]*\]\]?[ \t]*&&/ && last !~ /\|\|/ \
        && fname !~ /^_?(is|has|can)_/ && !annotated)
        printf "%s:%d: %s\n", FILENAME, lastnr, fname
    infunc=0; next
}
infunc {
    line=$0; sub(/^[ \t]+/,"",line)
    if (line != "" && line !~ /^#/) { last=$0; lastnr=FNR }
}'
        local _pa7_files tail_hits=""
        _pa7_files=$(find "$_pa7_scope" -name '*.sh' -not -path '*/tests/*' -not -path '*/archive/*' 2>/dev/null)
        [ -f "$_pa7_scope/wv" ] && _pa7_files="${_pa7_files}${_pa7_files:+
}$_pa7_scope/wv"
        if [ -n "$_pa7_files" ]; then
            tail_hits=$(echo "$_pa7_files" | xargs -r awk "$_pa7_awk" 2>/dev/null || true)
        fi
        if [ -n "$tail_hits" ]; then
            local tail_count
            tail_count=$(echo "$tail_hits" | grep -c .) || tail_count=0
            if [ "$format" = "text" ]; then
                echo -e "${RED}✗ Check 7 FAIL: $tail_count function(s) end in a bare [ cond ] && cmd tail:${NC}"
                echo "$tail_hits" | while IFS= read -r hit; do [ -n "$hit" ] && echo "    $hit"; done
                echo -e "  Convert to if/fi, append '|| true', or mark genuine predicates with '# predicate' on the definition line."
            fi
            findings_json=$(echo "$findings_json" | jq \
                --arg detail "$(echo "$tail_hits" | tr '\n' ' ' | sed 's/ *$//')" --argjson n "$tail_count" \
                '. + [{"check":"function_tail_returns","status":"fail","detail":$detail,"count":$n}]')
            issues=$((issues + tail_count))
        else
            [ "$format" = "text" ] && echo -e "${GREEN}✓ Check 7 PASS: no non-predicate function ends in a bare [ cond ] && cmd tail${NC}"
            findings_json=$(echo "$findings_json" | jq \
                '. + [{"check":"function_tail_returns","status":"pass","detail":"no errexit-fragile function tails","count":0}]')
        fi
    else
        [ "$format" = "text" ] && echo -e "${YELLOW}⚠ Check 7 WARN: $_pa7_scope not found — skipped${NC}"
        findings_json=$(echo "$findings_json" | jq \
            '. + [{"check":"function_tail_returns","status":"warn","detail":"scripts dir not found - skipped","count":0}]')
    fi

    # ── Check 8: quality.db sqlite3 access must stay behind blessed helpers ─
    # The quality readiness bug class recurs when callers hand-roll direct
    # sqlite3 probes against quality.db and drift from the owner schema in
    # scripts/weave_quality. Keep shell-side access in explicitly reviewed
    # helpers; new raw call sites must either move into one of these helpers or
    # justify a new blessed owner here.
    local _pa8_scope="$_project_root/scripts"
    if [ -d "$_pa8_scope" ]; then
        # shellcheck disable=SC2016  # $0 and $n are awk fields inside the awk program
        local _pa8_awk='
function allowed(fn) {
    return fn == "_bootstrap_agent_tools_json" ||
           fn == "_preflight_policy_readiness" ||
           fn == "_done_refresh_file_metrics" ||
           fn == "_done_refresh_trend_signals"
}
# Both bodies, name() { and name() ( (wv-b80a86). A line is charged to the
# last definition above it; a column-0 brace cannot end one here, since the awk
# programs in cmd_pattern_audit carry their own.
/^(function[ \t]+)?[A-Za-z_][A-Za-z0-9_]*\(\)[ \t]*[{(]/ {
    fname=$0; sub(/\(\).*/,"",fname); sub(/^function[ \t]+/,"",fname); next
}
{
    if ($0 ~ /^[ \t]*#/) next
    if (fname == "cmd_pattern_audit") next
    if ($0 ~ /sqlite3/ && ($0 ~ /quality\.db/ || $0 ~ /quality_db/)) {
        if (FILENAME ~ /\/scripts\/weave_quality\//) next
        if (allowed(fname)) next
        printf "%s:%d:%s: %s\n", FILENAME, FNR, fname, $0
    }
}'
        local _pa8_files quality_hits=""
        _pa8_files=$(find "$_pa8_scope" -type f \( -name '*.sh' -o -name 'wv' \) \
            -not -path '*/tests/*' -not -path '*/archive/*' 2>/dev/null)
        if [ -n "$_pa8_files" ]; then
            quality_hits=$(echo "$_pa8_files" | xargs -r awk "$_pa8_awk" 2>/dev/null || true)
        fi
        if [ -n "$quality_hits" ]; then
            local quality_count
            quality_count=$(echo "$quality_hits" | grep -c .) || quality_count=0
            if [ "$format" = "text" ]; then
                echo -e "${RED}✗ Check 8 FAIL: $quality_count raw sqlite3 quality.db access(es) outside blessed helpers:${NC}"
                echo "$quality_hits" | while IFS= read -r hit; do [ -n "$hit" ] && echo "    $hit"; done
                echo -e "  Move probes into _preflight_policy_readiness/_bootstrap_agent_tools_json or the quality owner module."
            fi
            findings_json=$(echo "$findings_json" | jq \
                --arg detail "$(echo "$quality_hits" | tr '\n' ' ' | sed 's/ *$//')" --argjson n "$quality_count" \
                '. + [{"check":"quality_db_sqlite_owner","status":"fail","detail":$detail,"count":$n}]')
            issues=$((issues + quality_count))
        else
            [ "$format" = "text" ] && echo -e "${GREEN}✓ Check 8 PASS: raw sqlite3 quality.db access stays in blessed helpers${NC}"
            findings_json=$(echo "$findings_json" | jq \
                '. + [{"check":"quality_db_sqlite_owner","status":"pass","detail":"quality.db sqlite3 access is owner-scoped","count":0}]')
        fi
    else
        [ "$format" = "text" ] && echo -e "${YELLOW}⚠ Check 8 WARN: $_pa8_scope not found — skipped${NC}"
        findings_json=$(echo "$findings_json" | jq \
            '. + [{"check":"quality_db_sqlite_owner","status":"warn","detail":"scripts dir not found - skipped","count":0}]')
    fi

    # ── Check 9: harness memory stores stay behind blessed helpers ──────────
    # The agent-memory substrate (PROPOSAL-wv-agent-memory-substrate) makes the
    # graph the single authority; per-harness stores are evidence/projections.
    # Harness-store paths ($HOME/.claude/projects, VS Code workspaceStorage, the
    # ~/.codex session/state/memory DBs) must only be read by the blessed
    # scan/import/telemetry/doctor helpers. A new site in a recall/render/
    # bootstrap path is a latent dual-authority leak — a harness file becoming
    # authoritative memory. New readers must justify a blessed entry here.
    local _pa9_scope="$_project_root/scripts"
    if [ -d "$_pa9_scope" ]; then
        # shellcheck disable=SC2016  # $0 and $n are awk fields inside the awk program
        local _pa9_awk='
function allowed(fn) {
    return fn == "_memory_scan_claude" ||
           fn == "_memory_scan_codex" ||
           fn == "_memory_scan_copilot" ||
           fn == "_memory_import_claude_dir" ||
           fn == "_health_cache_summary" ||
           fn == "cmd_cache" ||
           fn == "_doctor_memory_authority" ||
           fn == "_doctor_codex_memory_rows" ||
           # The Claude memory capture guard: it matches a written path against
           # the repo-scoped memory layout and imports only that (wv-b80a86).
           fn == "wv_potu_memory_guard" ||
           # Crash-recovery prompt harvest: the host'"'"'s transcript_path first,
           # Claude Code'"'"'s per-project transcript directory only when the host
           # sends none; it reads transcripts, never memory (wv-b80a86).
           fn == "wv_session_start_context"
}
# Both bodies, name() { and name() (: missing the subshell form charged
# wv_potu_memory_guard'"'"'s reads to _restore_generated_regions, the definition
# above it (wv-b80a86). A line is charged to the last definition above it.
/^(function[ \t]+)?[A-Za-z_][A-Za-z0-9_]*\(\)[ \t]*[{(]/ {
    fname=$0; sub(/\(\).*/,"",fname); sub(/^function[ \t]+/,"",fname); next
}
{
    if ($0 ~ /^[ \t]*#/) next
    if (fname == "cmd_pattern_audit") next
    if ($0 ~ /\.claude\/projects|workspaceStorage|\.codex\/(sessions|state_|memories_|history)/) {
        if (allowed(fname)) next
        printf "%s:%d:%s: %s\n", FILENAME, FNR, fname, $0
    }
}'
        local _pa9_files harness_hits=""
        _pa9_files=$(find "$_pa9_scope" -type f \( -name '*.sh' -o -name 'wv' \) \
            -not -path '*/tests/*' -not -path '*/archive/*' 2>/dev/null)
        if [ -n "$_pa9_files" ]; then
            harness_hits=$(echo "$_pa9_files" | xargs -r awk "$_pa9_awk" 2>/dev/null || true)
        fi
        if [ -n "$harness_hits" ]; then
            local harness_count
            harness_count=$(echo "$harness_hits" | grep -c .) || harness_count=0
            if [ "$format" = "text" ]; then
                echo -e "${RED}✗ Check 9 FAIL: $harness_count harness-store access(es) outside blessed memory helpers:${NC}"
                echo "$harness_hits" | while IFS= read -r hit; do [ -n "$hit" ] && echo "    $hit"; done
                echo -e "  Move harness reads into the scan/import helpers, or add a justified entry to Check 9's allowed()."
            fi
            findings_json=$(echo "$findings_json" | jq \
                --arg detail "$(echo "$harness_hits" | tr '\n' ' ' | sed 's/ *$//')" --argjson n "$harness_count" \
                '. + [{"check":"memory_authority_owner","status":"fail","detail":$detail,"count":$n}]')
            issues=$((issues + harness_count))
        else
            [ "$format" = "text" ] && echo -e "${GREEN}✓ Check 9 PASS: harness memory stores stay behind blessed helpers${NC}"
            findings_json=$(echo "$findings_json" | jq \
                '. + [{"check":"memory_authority_owner","status":"pass","detail":"harness-store access is owner-scoped","count":0}]')
        fi
    else
        [ "$format" = "text" ] && echo -e "${YELLOW}⚠ Check 9 WARN: $_pa9_scope not found — skipped${NC}"
        findings_json=$(echo "$findings_json" | jq \
            '. + [{"check":"memory_authority_owner","status":"warn","detail":"scripts dir not found - skipped","count":0}]')
    fi

    # ── Summary ─────────────────────────────────────────────────────────────
    if [ "$format" = "json" ]; then
        jq -n \
            --argjson findings "$findings_json" \
            --argjson total_issues "$issues" \
            '{"pattern_audit":{"issues":$total_issues,"findings":$findings}}'
    else
        echo ""
        if [ "$issues" -eq 0 ]; then
            echo -e "${GREEN}Pattern audit: PASS (0 issues)${NC}"
        else
            echo -e "${RED}Pattern audit: FAIL ($issues issue(s))${NC}"
        fi
    fi

    [ "$strict" -eq 1 ] && [ "$issues" -gt 0 ] && return 1
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_edge_types — Show valid edge types
# ═══════════════════════════════════════════════════════════════════════════

cmd_edge_types() {
    local show_stats=0
    local json_out=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --stats) show_stats=1 ;;
            --json)  json_out=1 ;;
            --help|-h)
                echo "Usage: wv edge-types [--stats] [--json]"
                echo "  --stats  Include live edge counts per type from the graph"
                echo "  --json   Machine-readable output (implies --stats)"
                return 0 ;;
            -*) _wv_reject_arg edge-types "$1"; return 1 ;;  # wv-016983
        esac
        shift
    done

    [ "$json_out" -eq 1 ] && show_stats=1

    local -A counts=()
    if [ "$show_stats" -eq 1 ] && [ -f "$WV_DB" ]; then
        while IFS='|' read -r type cnt; do
            counts["$type"]="$cnt"
        done < <(sqlite3 "$WV_DB" "SELECT type, COUNT(*) FROM edges GROUP BY type ORDER BY COUNT(*) DESC;" 2>/dev/null)
    fi

    if [ "$json_out" -eq 1 ]; then
        local first=1
        printf '['
        for type in $VALID_EDGE_TYPES; do
            local cnt="${counts[$type]:-0}"
            [ "$first" -eq 0 ] && printf ','
            printf '{"type":"%s","count":%s}' "$type" "$cnt"
            first=0
        done
        printf ']\n'
        return 0
    fi

    echo -e "${CYAN}Valid edge types:${NC}"
    echo ""
    # The meanings are contracts/edge-types-v1.json's, pinned by
    # tests/test-edge-invariants.sh; the invariants each type carries are there.
    for type in $VALID_EDGE_TYPES; do
        local desc=""
        case "$type" in
            blocks)     desc="Workflow dependency (target blocked by source)" ;;
            relates_to) desc="General semantic relationship" ;;
            implements) desc="Source implements target (child -> parent)" ;;
            contradicts) desc="Target contradicts source" ;;
            supersedes) desc="Target supersedes/replaces source (old -> new)" ;;
            references) desc="Target references/mentions source" ;;
            obsoletes)  desc="Target makes source obsolete" ;;
            addresses)  desc="Source addresses/fixes pitfall in target" ;;
            resolves)   desc="Links a task or fix with its finding handoff" ;;
        esac
        if [ "$show_stats" -eq 1 ]; then
            local cnt="${counts[$type]:-0}"
            printf "  ${GREEN}%-12s${NC} %4s  %s\n" "$type" "$cnt" "$desc"
        else
            echo -e "  ${GREEN}$type${NC} - $desc"
        fi
    done
}

# ═══════════════════════════════════════════════════════════════════════════
# ═══════════════════════════════════════════════════════════════════════════
# cmd_guide — Quick workflow reference
# ═══════════════════════════════════════════════════════════════════════════

cmd_guide() {
    local topic="" procedure=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --topic=*) topic="${1#*=}" ;;
            --procedure=*) procedure="${1#*=}" ;;
            --help|-h) cmd_help guide; return 0 ;;
            -*) _wv_reject_arg guide "$1"; return 1 ;;  # wv-016983
        esac
        shift
    done

    if [ -n "$procedure" ]; then
        if [[ ! "$procedure" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
            echo "Error: invalid procedure id '$procedure'" >&2
            return 1
        fi
        # A repository's own procedure replaces the package one of the same id
        # here (wv-fc71f0); wv-cmd-procedures.sh resolves it, and loads only
        # when the repository has one.
        local procedure_file="${WV_CONFIG_DIR:-$HOME/.config/weave}/procedures/${procedure}.md"
        if [ -n "${REPO_ROOT:-}" ] && [ -f "$REPO_ROOT/.weave/procedures/${procedure}.md" ]; then
            procedure_file=$(_wv_repo_procedure_file "$procedure") || return 1
        fi
        if [ ! -f "$procedure_file" ]; then
            echo "Error: unknown procedure '$procedure' (not in .weave/procedures and not installed: $procedure_file)" >&2
            return 1
        fi
        cat "$procedure_file"
        return 0
    fi

    case "$topic" in
        workflow|"")
            cat <<'EOF'
Weave Workflow Quick Reference

  0. CLI path:     if ! command -v wv >/dev/null 2>&1; then wv() { ./scripts/wv "$@"; }; fi
  1. Snapshot:     wv bootstrap --json
  2. Find work:    wv ready
  3. Claim it:     wv work <id>
  4. Do the work   (edit files, run tests)
  5. Complete:     wv done <id> --learning="decision: ... | pattern: ... | pitfall: ..."
  6. Sync:         wv sync --gh
  7. Commit state: git add .weave/ && git diff --cached --quiet || git commit -m "chore(weave): sync state [skip ci]"
  8. Push:         git push

Create new work:
  wv add "Description"               # standalone node
  wv add "Description" --gh          # node + GitHub issue (linked)
  wv add "Task" --parent=<epic-id>   # child of an epic

Topics: wv guide --topic=github | learnings | context | routing | mcp | verification | instrumentation | config | discovery
EOF
            ;;
        github)
            cat <<'EOF'
Weave GitHub Integration

Create with a linked issue (atomic):
  wv add "Fix auth bug" --gh         # creates node + GH issue, links them

Close (auto-closes linked GH issue):
  wv done <id> --learning="..."      # closes node + linked GH issue

Ship (done + sync in one; pending Git sync is surfaced separately):
  git add <files> && git commit -m "..."   # commit code first
    wv ship <id> --learning="..."            # close + sync; check status for Git sync

Sync epic bodies / Mermaid diagrams:
  wv sync --gh                       # full bidirectional sync

Check GitHub sync status:
    gh issue list --state open --limit 200 --json number,title,labels \
        | jq '[.[] | select(any(.labels[]?.name; . == "weave-synced")) | {number:.number,title:.title}]'
  wv show <id> --json | jq '.[0].metadata | fromjson | .gh_issue'

Label taxonomy applied automatically:
  weave-synced   all Weave-linked issues
  epic           nodes with child tasks
  task           leaf task nodes
EOF
            ;;
        learnings)
            cat <<'EOF'
Weave Learnings

Capture on close (preferred format):
  wv done <id> --learning="decision: What was chosen and why | pattern: Reusable technique | pitfall: Specific mistake to avoid"

Or via metadata before closing:
  wv update <id> --metadata='{"decision":"...","pattern":"...","pitfall":"...","verification_evidence":"..."}'
  wv done <id>

Good learnings are:
  Specific  — not "be careful with X" but "X fails when Y because Z"
  Actionable — includes the fix, not just the problem
  Scoped    — tied to a concrete context, not generic advice

View learnings:
  wv learnings                          # all
  wv learnings --category=pitfall       # pitfalls only
  wv learnings --grep="sqlite"          # search
  wv learnings --recent=5               # last 5
  wv learnings --node=<id>              # for one node
  wv audit-pitfalls                     # unresolved pitfalls (top 20; --all for everything)
EOF
            ;;
        context)
            cat <<'EOF'
Weave Context Policy

Session start hook injects a policy based on repo size:
  HIGH   — read files <500 lines whole; grep first for larger
  MEDIUM — always grep before read; no full reads >500 lines
  LOW    — always grep first; only read <200 line slices; summarize

Editing: open a file with your harness's native file-read before editing it. Shell reads
(cat/grep/sed) and code-search are for inspection only — they do NOT satisfy edit-guards, so
editing a file you only inspected via a shell command is blocked ("File has not been read").
Grep/partial-read to find the spot; native-read the file you will change.

Context Pack (before complex work):
  wv context <id> --json | jq .
  Returns: node, blockers, ancestors, related nodes, pitfalls, contradictions

Scope rules:
  - Max 4-5 tasks per session (context limits kill mid-task)
  - Check wv status before editing — 0 active nodes means create one first
  - Run wv context before starting complex work to see pitfalls + ancestors
EOF
            ;;
        routing)
            cat <<'EOF'
Weave Routing Model

Runtime phase loop:
    BOOTSTRAP / DISCOVER → EXECUTE → SYNTHESIZE → BOOTSTRAP

DISCOVER quality floor:
    Before DISCOVER can advance to EXECUTE, gather discovery evidence with local read tools:
    read, grep, glob

Tool classes:
    READ_ONLY_TOOLS     — read, grep, glob, ls, wv_show, wv_context, wv_search, wv_tree, wv_learnings
    EXECUTE_TRIGGERS    — edit/write/bash or any mutation request that makes the next step unavoidable
    SYNTHESIZE_TRIGGERS — wv_done, wv_ship, close/handoff work after execution

Bootstrap depth:
    DISCOVERY mode — status line only (~50 tokens), best when no active node exists
    EXECUTION mode — full context pack, truncated to runtime budget (~3000 chars)

Practical CLI guidance:
    - Stay cheap first: read/grep/glob before bash or edit when you're still locating the control path
    - Claim work before mutation: wv ready → wv work <id> → wv context <id> --json
    - Use wv touch <id> --intent="..." for low-token progress checkpoints between larger steps
    - Close with structure: wv done <id> --learning="decision: ... | pattern: ... | pitfall: ..."

Token-saving pattern:
    Discovery turn   — wv bootstrap --json, grep, read small slices
    Execution turn   — edit the local slice, run one focused validation
    Synthesis turn   — wv update verification metadata, then wv done / wv ship
EOF
            ;;
        mcp)
            cat <<'EOF'
Weave MCP Server

The MCP (Model Context Protocol) server exposes Weave tools to AI clients.

Install & build:
  cd mcp && npm install && npm run build

Configure in your MCP client (e.g. Claude Desktop, VS Code):
  Command: node /path/to/mcp/dist/index.js
  Env: WV_PROJECT_ROOT=/path/to/your/repo

Key compound tools (prefer over multiple CLI calls):
  weave_overview  — status + health + ready work (session start overview)
  weave_bootstrap — single-call session context (wv bootstrap --json)
  weave_work      — claim node + return context pack
    weave_ship      — done + sync in one step; Git sync is surfaced separately
  weave_quick     — create + close trivial task in one call
  weave_preflight — pre-action checks before starting work
  weave_plan      — import markdown plan as epic + tasks

Other tools:
  weave_add, weave_done, weave_batch_done, weave_update, weave_list,
  weave_link, weave_tree, weave_context, weave_search, weave_resolve,
  weave_learnings, weave_guide, weave_status, weave_health, weave_sync,
  weave_trails (alias: weave_breadcrumbs), weave_close_session

CLI vs MCP:
  - MCP: fewer round-trips (compound tools), typed JSON responses
  - CLI: full command set, scripting, pipe-friendly, env var config
  - Both use the same SQLite graph — changes are visible to either
EOF
            ;;
        verification)
            cat <<'EOF'
Weave Verification Boundary

wv done is the single owner of the "is this correct?" decision. Other surfaces
RUN checks and RECORD outcomes; wv done READS them and decides. It never invokes
a linter or test runner — the close stays fast.

Three surfaces:
  pre-commit   hygiene gate (lint, active-node) + runs light impact suites + records
  pre-push     runs the [heavy] suites the pushed commits owe + records; refuses red
  wv done      reads recorded signals; owns the gate (nodes_policy_check trigger)

Pre-commit pytest behavior:
  If tests/weave_quality/ or tests/weave_indexer/ exists, the hook runs those
  optional focused pytest dirs for staged Python changes. Consumer repos are not
  required to create them; absent dirs are skipped. Repo-local tests should be
  exposed through .weave/test-map.conf as shell suites, e.g.
    src/auth/ee_auth.py = scripts/run-unit-tests.sh

Policy gates (rows in policy_thresholds; enforced only for files in node_files,
quality_exempt paths always skipped):
  mccabe_max[_lang]   block if a touched file's max function CC exceeds the limit
  trend_deteriorating block if a touched file's complexity is deteriorating (default off)
  test_gate           test correctness: 0=off, 1=warn (advisory), 2=block (default off)

Test gate flow:
  1. Record per file:   wv test-record <suite> --files=a,b --exit=N
                        (one row per file; fingerprint = git blob hash)
  2. Map paths->suites: .weave/test-map.conf   (source_file = suite [suite ...])
  3. wv done derives file_test_status per touched file:
       blob == recorded & exit 0  -> green
       blob == recorded & exit !=0 -> red
       blob != recorded            -> stale   (file changed since the run)
       no record / no mapping      -> unknown (never blocks)
  4. Act by level: off=inert | warn=advisory on red/stale | block=ABORT on red/stale

Enable for a repo (default is off/inert) — easiest is the durable toggle:
  wv config enable test-gate warn     # or 'block'; writes quality.conf for you
Or edit DURABLE config directly in .weave/quality.conf:
  [thresholds]
  test_gate = 1            # 1=warn, 2=block
  trend_deteriorating = 1
Committed + re-applied on every `wv load`, so it survives reboot. (brain.db is
tmpfs; policy_thresholds is not in state.sql, so a raw sqlite3 UPDATE is
session-only and resets on cold-start — use quality.conf for durable policy.)
`wv doctor` flags a gate that is set in the DB but not durably configured.

Exemptions: [exempt] patterns in quality.conf; node types finding/epic/session_history;
--skip-verification suppresses the warn advisory (block is a hard gate, not bypassable).

Full reference: docs/WEAVE.md § 4.7.
EOF
            ;;
        instrumentation)
            cat <<'EOF'
Weave Instrumentation & Opt-in Knobs

Two opt-in surfaces ship OFF by default. Turn them on through one front door —
`wv config` — so you never have to memorise an env var name or a file path.

1. Session analysis (which wv commands cost the most output/tokens)
   wv config enable session-analysis     # sets WV_CALL_LOG in config.env
   wv analyze sessions --call-stats --since-days=1   # read the report (windowed)
   wv config disable session-analysis

   Enablement lives in ~/.config/weave/config.env (override dir: WV_CONFIG_DIR)
   and is read from disk on EVERY invocation — CLI and harness-spawned hooks
   alike — so it survives reboot and never depends on env inheritance. With it
   off, the reader says so plainly instead of implying a phantom log path.

2. Verification gate (test-correctness gate on wv done) — repo-scoped
   wv config enable test-gate warn        # or 'block'
   wv config disable test-gate
   See: wv guide --topic=verification   (durability, test-map.conf, exemptions)

Inspect current state any time:
   wv config list      # global knobs + feature on/off + gate durability
   wv doctor           # flags a gate enabled in the DB but not durably configured

Global knobs live in ~/.config/weave/config.env, e.g.:
   WV_CALL_LOG="$HOME/.local/share/weave/wv_calls.jsonl"
   # WV_DELTA_RETAIN_DAYS=14
EOF
            ;;
        config)
            cat <<'EOF'
Weave Config Model

Two config layers:

  User-global (~/.config/weave/config.env)
    Personal knobs — WV_CALL_LOG, WV_SUITE_LOG, WV_DELTA_RETAIN_DAYS, ...
    Read from disk on EVERY invocation (CLI + hooks); survives reboot.
    Not committed to source control. Personal to this machine.

  Repo-committed (.weave/quality.conf [thresholds])
    Team policy — test_gate, mccabe_max, trend_deteriorating
    Loaded by wv load on session start. Commit it to share the policy.

Ownership rule:
  Personal preferences (log paths, verbosity)  -> config.env    (never commit)
  Team policy (gate mode, quality thresholds)  -> quality.conf  (commit it)

Quick reference:
  wv config list                          Show active knobs + feature state
  wv config list --show-origin            Show each value with its source file
  wv config get <KEY>                     Print effective value of a knob
  wv config get <KEY> --show-origin       Print value + which layer provides it
  wv config set <KEY> <VALUE>             Set a WV_* knob in config.env
  wv config unset <KEY>                   Remove a knob from config.env
  wv config enable session-analysis       Write WV_CALL_LOG to config.env
  wv config enable test-gate [warn|block] Write test_gate to quality.conf
                                          and scaffold .weave/test-map.conf
  wv config disable session-analysis | test-gate

Gitignore boundary:
  config.env        personal, never committed
  quality.conf      team policy, commit it to share the gate mode
  quality.local.conf  (planned) gitignored user-per-repo override for
                      personal threshold relaxation without touching quality.conf

Related topics:
  wv guide --topic=verification     test-map.conf, gate flow, exemptions
  wv guide --topic=instrumentation  opt-in knobs, session analysis
EOF
            ;;
        discovery)
            cat <<'EOF'
Weave Discovery Toolset

The ground-truth surface for audit and read-only exploration. These are the tools
to reach for BEFORE editing, not after.

  wv search <q>         FTS5 BM25 over all nodes. Fuzzy — finds "anything about X".
                          --limit=N     (equals-form only; --limit N fails)
                          --status=, --type=, --learning
                          --code        hybrid BM25+cosine over indexed code chunks
                                        (run `wv index .` once to enable)
                          --code --graph  attach active nodes to code results

  wv query <preds>      Predicate reader. Exact — answers "nodes where X = Y".
                          key=value, key!=value, key>=value, key IN (a,b,c)
                          HAS key, MATCH "phrase"
                          --order=field, --include=finding|learning
                          --format=short|json
                          QUIRK: parens in IN (...) break bash — single-quote
                          the whole predicate: wv query 'id IN (wv-abc,wv-def)'

  search vs query:      search = BM25-fuzzy ("find me anything about dedup")
                        query  = predicate-exact ("status=done type=finding stale>=7")
                        Use search to locate; use query to pin and filter.

  wv list               Enumeration, capped at 50 rows (100 with --status=done).
                          The stderr footer gives the matching total and how
                          many rows are hidden; --limit=N raises the cap, --all
                          lifts it and adds done nodes. A capped list is not
                          evidence a node is absent: before wv add, run
                          wv search "<topic>".

  wv discover <id>      Unknown-taxonomy report for one node.
                          --json        emits known_knowns, known_unknowns,
                                        unknown_knowns, unknown_unknown_candidates
                          --depth=N     impact depth for candidate surfacing
                          --limit=N     cap each bucket
                          Candidates are hypotheses until a probe produces evidence.

  wv impact <id>        Blast-radius walk over typed edges (blocks|implements|addresses).
                          --full        adds resolves|references|supersedes|obsoletes
                          --direction=fwd|rev|both
                          --files=a,b   seed from touched_files
                          QUIRK: a done-seed refuses fwd walk ("impact already
                          discharged") — use --direction=rev or --include-done

  wv related <id>       Typed-edge neighbourhood of a node.
                          --type=, --direction=, --depth=N
  wv edges <id>         A node's edges. --type=, --json

  wv show <id>          Full node detail. --json for machine-readable.
  wv tree <epic>        Epic → task hierarchy. --mermaid for diagram.
  wv path <id>          Ancestry chain to root.

  wv analyze sessions   Telemetry: top commands by output bytes / approx tokens.
    --call-stats          Run this after a session to see where context goes.
                          Window it (--since-days=1) for retro reading — unwindowed
                          output is a lifetime aggregate across instrumentation eras.
                          Prefer query or search over wv list for targeted reads;
                          reserve wv list for enumeration, and read its footer
                          for hidden rows (it caps at 50).

  wv cache              Prompt-cache health for the project.
                          --sessions=N, --all; ratio >65% OK / 35-65% LOW / <35% BAD

  wv bootstrap --json   One-call session context snapshot.
                          Replaces: git status + wv status + wv ready

Typical audit sequence:
  1. wv search "<topic>"          locate by subject
  2. wv query 'id IN (...)'       pin the set, filter by status/type
  3. wv show <id>                 read full detail
  4. wv discover <id> --json      classify facts, gaps, learnings, candidates
  5. wv impact <id> --direction=rev   check what depends on it
  6. wv edges <id>                confirm typed relationships

Related topics:
  wv guide --topic=routing      phase loop, tool classes, token-saving pattern
  wv guide --topic=context      context pack, scope rules
  wv guide --procedure=blindspot-pass
EOF
            ;;
        *)
            echo "Unknown topic: $topic" >&2
            echo "Topics: workflow (default), github, learnings, context, routing, mcp, verification, instrumentation, config, discovery" >&2
            return 1
            ;;
    esac
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_help — Show help
# ═══════════════════════════════════════════════════════════════════════════

print_command_help() {
    local usage="$1"
    local summary="$2"

    printf 'Usage: %s\n\n%s\n' "$usage" "$summary"
}

_help_delegate_topic() {
    local topic="${1:-}"
    shift || true

    case "$topic" in
        bootstrap)
            cmd_bootstrap --help
            ;;
        bootstrap-agent)
            cmd_bootstrap_agent --help
            ;;
        bulk-update)
            cmd_bulk_update --help
            ;;
        cache)
            cmd_cache --help
            ;;
        enrich-topology)
            cmd_enrich_topology --help
            ;;
        quality)
            if [ $# -gt 0 ]; then
                cmd_quality "$1" --help
            else
                cmd_quality --help
            fi
            ;;
        findings)
            if [ $# -gt 0 ]; then
                cmd_findings "$1" --help
            else
                cmd_findings --help
            fi
            ;;
        analyze)
            if [ $# -gt 0 ]; then
                cmd_analyze "$1" --help
            else
                cmd_analyze --help
            fi
            ;;
        index)
            cmd_index --help
            ;;
        query)
            cmd_query --help
            ;;
        hook)
            cmd_hook --help
            ;;
    esac
}

cmd_help_topic() {
    local topic="${1:-}"
    shift || true

    case "$topic" in
        bootstrap|bootstrap-agent|bulk-update|cache|enrich-topology|quality|findings|analyze|index|query|hook)
            _help_delegate_topic "$topic" "$@"
            ;;
        validate-finding)
            print_command_help "wv validate-finding <id>" "Validate finding metadata for a node. Exit 0 = valid; exit 1 = invalid. Outputs JSON {valid, errors[]}. Used by pre-close-verification hook to enforce violation_type and optional field constraints before a finding node can be closed."
            ;;
        test-status)
            print_command_help "wv test-status <suite> --files=a,b [--staged] [--quiet]" "Return success only when every named file has a fresh green result for the suite. --staged compares the recorded result with Git index blobs for pre-commit reuse; the default compares working-tree content."
            ;;
        init-repo)
            cmd_init_repo --help
            ;;
        update)
            cmd_update_help
            ;;
        help)
            print_command_help "wv help <command> [subcommand]" "Show focused help for one command. Nested subcommand families like quality/findings/analyze can take an extra subcommand argument."
            ;;
        init)
            print_command_help "wv init [--force]" "Initialize the Weave database in the current hot zone, recovering synced state when available."
            ;;
        add)
            print_command_help "wv add <text> [--status=STATUS] [--parent=<id>] [--gh] [--alias=<name>] [--metadata=<json>] [--force] [--standalone] [--criteria=<text>] [--risks=<level>] [--kind=<kind>] [--verification-plan=<text>] [--id=<wv-id>]" "Create a node and print its id. Use --parent when an active epic exists, or --standalone for repo-level chores. --kind sets the node kind (epic, feature, task, finding, decision, plan, memory, session_history); without it the kind comes from metadata type, then the text prefix (epic(, plan( ...), then task. --verification-plan records upfront what would count as done, surfaced again as a reminder if wv done is later blocked for missing verification. --id reconstructs a node under an id the graph has lost, so a pushed Weave-ID trailer stops pointing at nothing; it refuses an alias and refuses to overwrite a live id."
            ;;
        remember)
            print_command_help "wv remember <text> [--kind=project] [--scope=repo] [--source-agent=name] [--supersedes=<id>] [--json]" "Capture a graph-native memory node using metadata.type=memory and metadata.mem_status=active. To change a claim, do not edit the memory: --supersedes=<id> records the new one and keeps the old as mem_status=superseded with superseded_by, linked by a supersedes edge. Only an active memory can be superseded."
            ;;
        memory)
            print_command_help "wv memory recall [--agent=current|all|name] [--json] | wv memory render [--agent=all|current|claude|claude-memory|copilot|codex|codex-memory|agents|workflow] [--base-dir=DIR] [--path=PATH] [--json] | wv memory scan --source=claude|codex|copilot|all [--repo-root=DIR] [--json] | wv memory import --source=claude --path=DIR [--repo-root=DIR] [--json] | wv memory import --source=codex [--path=DB] [--repo-root=DIR] [--json] | wv memory crystallize [--dry-run|--apply-reviewed] [--repo-root=DIR] [--json] | wv memory review <id> --verdict=promote|merge|reject|verify --reason=TEXT [--target=<active id>] [--json] | wv memory review <active id> --verdict=graduate --reason=TEXT --target=<repo path> [--json] | wv memory review --apply [--dry-run] [--json]" "Recall graph-native memory (active and graduated), render repo-local projections (active only), scan harness state, import Claude project memories or Codex memory-pipeline rows as mem_status=candidate nodes, crystallize candidates (dedup/verify/mark, promote reviewed), or record a reviewer's verdict on a candidate, or graduate an active memory whose lesson a repository procedure, guide, detector or tracked document now carries, and apply the recorded verdicts (review). Capture records dynamic agent provenance; graph recall is agent-agnostic. --path is only valid for one render projection or a single Codex memory DB import. The agents projection (AGENTS.md, included in --agent=all) only refreshes an existing WEAVE:MEMORY block; a file without one is left untouched."
            ;;
        delete)
            print_command_help "wv delete <id> [--force] [--dry-run] [--no-gh]" "Delete a node and its edges. Use --dry-run to preview deletions and --force to execute them."
            ;;
        done)
            print_command_help "wv done <id> [--completion-files=path,...] [--learning=\"...\"|--learning-file=PATH] [--decision=\"...\"] [--pattern=\"...\"] [--pitfall=\"...\"] [--verification-method=\"...\"] [--verification-evidence=\"...\"|--verification-evidence-file=PATH] [--no-warn] [--acknowledge-overlap] [--skip-verification] [--no-overlap-check] [--no-gh]" "Close a node; an explicit completion-files scope audits quality against attributed selected files while preserving file history."
            ;;
        ship)
            print_command_help "wv ship <id> [--learning=\"...\"|--learning-file=PATH] [--verification-method=\"...\"] [--verification-evidence=\"...\"|--verification-evidence-file=PATH] [--decision=\"...\"] [--pattern=\"...\"] [--pitfall=\"...\"] [--gh] [--skip-verification] [--no-overlap-check]" "Close a node and sync graph state in one step; any remaining Git sync is surfaced separately."
            ;;
        ship-agent)
            print_command_help "wv ship-agent <id> [--learning=\"...\"|--learning-file=PATH] [--verification-method=\"...\"|--verify-method=\"...\"] [--verification-evidence=\"...\"|--verify-evidence=\"...\"|--verification-evidence-file=PATH] [--gh] [--no-gh] [--skip-verification] [--no-overlap-check] [--json]" "Run an agent-safe non-interactive ship flow with doctor --agent precheck and JSON output."
            ;;
        batch-done)
            print_command_help "wv batch-done <id1> <id2> ... [--learning=\"...\"] [--no-warn] [--no-gh]" "Close multiple nodes with a shared learning note."
            ;;
        work)
            print_command_help "wv work <id> [--quiet] [--force] [--reopen] [--json] [--allowed-tools=t1,t2,...]" "Claim a node, set WV_ACTIVE for agent context, explicitly reopen done nodes, and optionally persist an allowed tool list."
            ;;
        preflight)
            print_command_help "wv preflight <id>" "Return machine-readable blockers, contradictions, and readiness checks for a node."
            ;;
        recover)
            print_command_help "wv recover [--auto] [--json] [--session]" "Resume interrupted ship/sync/delete flows or inspect orphaned active work for the current session."
            ;;
        overview)
            print_command_help "wv overview [--json]" "Show a compact operational snapshot: counts, health indicators, breadcrumb, and top ready work."
            ;;
        pending-close)
            print_command_help "wv pending-close [--json]" "List nodes waiting for explicit overlap acknowledgement before close."
            ;;
        ready)
            print_command_help "wv ready [--json | --json-v2] [--count] [--all] [--with-impact] [--findings] [--subtree=<id>] [--mode=bootstrap|discover|execute|full]" "List unblocked work. --with-impact ranks by blast radius (wv impact per node); --subtree=<id> scopes to a node's descendants; --findings includes the findings digest."
            ;;
        list)
            print_command_help "wv list [--all] [--limit=N] [--status=<status>] [--claimed-by=<agent-id>|current] [--json | --json-v2] [--mode=bootstrap|discover|execute|full]" "List nodes, excluding done by default. Output is capped at 50 rows (100 with --status=done); when the cap hides rows, a stderr footer gives the matching total and the --limit=N that shows them all. --all lifts the cap and includes done nodes. A capped list is not evidence a node is absent: check wv search \"<topic>\" before wv add. Use --claimed-by=current for nodes owned by this agent and --json-v2 for the lean parsed-metadata shape."
            ;;
        show)
            print_command_help "wv show <id> [--json | --json-v2] [--mode=bootstrap|discover|execute|full] [--close-time]" "Show node details in text or JSON. --json-v2 returns the lean parsed-metadata shape. --close-time derives when a done node last closed from the committed graph history (git): the node's updated_at in the first snapshot showing it done after one showing it open, with the window it fell in; it walks history, so it can take seconds."
            ;;
        status)
            print_command_help "wv status [--json] [--mode=bootstrap|discover|execute|full]" "Show compact status counts for the current graph."
            ;;
        touch)
            print_command_help "wv touch <id> (--metadata=<json> | --intent=<text> | --files=path1,path2)" "Silently merge metadata for low-friction intent tracking or file attribution. --files records repo-relative paths in node_files for impact/search grounding."
            ;;
        allowed-tools)
            print_command_help "wv allowed-tools <id> [--json]" "Inspect the metadata.allowed_tools list stored on a node."
            ;;
        quick)
            print_command_help "wv quick <text> [--learning=\"...\"]" "Create and close a trivial one-step node in a single command."
            ;;
        block)
            print_command_help "wv block <id> --by=<blocker-id>" "Add a workflow dependency edge so the target is blocked by another node."
            ;;
        link)
            print_command_help "wv link <from-id> <to-id> --type=<type> [--weight=<weight>] [--context=<json>]" "Create a semantic edge between two nodes. Use 'wv edge-types' to inspect valid edge types."
            ;;
        unlink)
            print_command_help "wv unlink <from-id> <to-id> --type=<type>" "Remove a semantic edge between two nodes."
            ;;
        resolve)
            print_command_help "wv resolve <node1> <node2> (--winner=<id> | --merge | --defer) [--rationale=<text>]" "Resolve a contradiction edge by selecting a winner, merging, or deferring with rationale."
            ;;
        related)
            print_command_help "wv related <id> [--type=<type>] [--direction=outbound|inbound|both] [--depth=N] [--json]" "Inspect a node's semantic relationships. --depth=N expands to N-hop neighborhood (default 1)."
            ;;
        edges)
            print_command_help "wv edges <id> [--type=<type>] [--json]" "Inspect all edges touching a node."
            ;;
        path)
            print_command_help "wv path <id> [--format=chain]" "Show the ancestry path for a node."
            ;;
        tree)
            print_command_help "wv tree [root] [--active] [--depth=N] [--all] [--json] [--mermaid]" "Render epic/task hierarchy as text, JSON, or Mermaid. Capped at 50 nodes (WV_TREE_CAP); --all lifts."
            ;;
        plan)
            print_command_help "wv plan <file.md> --sprint=N [--dry-run] [--gh] [--template]" "Import a markdown plan into epic/task nodes, or emit a template with --template."
            ;;
        context)
            print_command_help "wv context [id] --json [--mode=bootstrap|discover|execute|full]" "Generate a JSON context pack for a node. If <id> is omitted, wv uses WV_ACTIVE."
            ;;
        impact)
            print_command_help "wv impact <id>... [--files=path1,path2] [--direction=fwd|rev|both] [--depth=N] [--json] [--full] [--include-done] [--all] [--quality]" "Walk the dependency graph from one or more seed nodes. Reports impacted nodes by depth, risk_score/risk_factors, nodes unblocked when seeds complete, and affected test suites. --files=path1,path2 derives seeds from node_files attribution or touched_files metadata (unknown paths emit empty result). --include-done also allows done file owners to become seeds and includes done impacted nodes. --direction=both (default) follows blocks|implements|addresses edges in both directions; fwd=outward only; rev=inward only. --depth=N (default 3). --all removes the 50-node cap. --full adds resolves|references|supersedes|obsoletes to the traversed edge types. --json returns structured output."
            ;;
        discover)
            print_command_help "wv discover <id> --json [--depth=N] [--limit=N]" "Compose query and impact signals into unknown-taxonomy buckets: known_knowns, known_unknowns, unknown_knowns, and unknown_unknown_candidates."
            ;;
        search)
            cat <<'SEARCHHELP'
Usage: wv search <query> [--limit=N] [--json] [--status=STATUS] [--type=TYPE] [--learning]
       wv search --code <query> [--limit=N] [--json] [--mode=hybrid|fts|vector] [--graph] [--filter=<expr>]

  Without --code: searches Weave graph nodes (FTS5 BM25)
  With --code:    searches indexed code chunks (RRF hybrid BM25+cosine)
  --type=TYPE:    filter by metadata.type (finding, task, epic, ...)
  --learning:     only nodes that have captured learning content
  --graph:        attach active Weave nodes + quality churn to results
  --filter=EXPR:  constrain code chunks by graph edge type
                  Supported: edge-type=<type>, edge-type!=<type>
                  Types: blocks, implements, relates_to, addresses, contradicts, resolves
                  Example: wv search --code "auth" --filter=edge-type=blocks
SEARCHHELP
            ;;
        reindex)
            print_command_help "wv reindex" "Rebuild the full-text search index."
            ;;
        learnings)
            print_command_help "wv learnings [--category=<cat>] [--grep=<pattern>] [--recent=N] [--mode=<mode>] [--node=<id>] [--show-graph]" "Show captured learnings, optionally filtered by category, text, node, or output mode."
            ;;
        trails|breadcrumbs)
            print_command_help "wv trails [save|show|clear|capsule <id>] [--message=\"...\"] [--json='{...}']" "Persist or inspect session trails (append-only handoff path). 'breadcrumbs' is a back-compat alias."
            ;;
        digest)
            print_command_help "wv digest [--json]" "Show a compact one-line health summary."
            ;;
        session-summary)
            print_command_help "wv session-summary" "Show session activity statistics such as nodes created, completed, and learnings captured."
            ;;
        audit-pitfalls)
            print_command_help "wv audit-pitfalls [--top=N] [--all] [--only-addressed] [--json]" "List unaddressed pitfalls (top 20 default); --all includes addressed."
            ;;
        edge-types)
            print_command_help "wv edge-types [--stats] [--json]" "List valid semantic edge types and what each one means. --stats adds live edge counts from the graph."
            ;;
        doctor)
            print_command_help "wv doctor [--json] [--repair] [--agent]" "Run installation and surface-contract diagnostics for the CLI, hooks, and repo wiring. --agent adds python, pytest, import-path, and provenance checks for agent flows."
            ;;
        repo-class)
            print_command_help "wv repo-class [--json] [--offline] | wv repo-class set owned|vendored-upstream [--acknowledge-upstream-fork] | wv repo-class audit [--json] [--offline]" "Inspect or persist clone-local repository ownership classification, or audit tracked and historical Weave scaffolding without mutation."
            ;;
        self-update)
            print_command_help "wv self-update" "Refresh installed wv from the dev clone recorded at install time. Equivalent to re-running install.sh from the source directory."
            ;;
        uninstall)
            print_command_help "wv uninstall" "Remove installed wv files. Delegates to install.sh --uninstall. Preserves ~/.config/weave (user data) — see output for manual cleanup of ~/.claude/settings.json hooks and consumer repo git hooks."
            ;;
        selftest)
            print_command_help "wv selftest [--json]" "Run a round-trip smoke test in an isolated environment."
            ;;
        mcp-status)
            print_command_help "wv mcp-status [--json]" "Check whether the local MCP server is built and whether the IDE config contains the current Weave server/env entries."
            ;;
        health)
            print_command_help "wv health [--history[=N]] [--verbose] [--json] [--fast]" "Run system health checks and optionally include recent health history. --fast serves a score-focused result from a write-invalidated cache (WV_HEALTH_FAST_TTL, default 300s) and skips quality collection — intended for hook callers."
            ;;
        guide)
            print_command_help "wv guide [--topic=workflow|github|learnings|context|routing|mcp|verification|instrumentation|config|discovery] | --procedure=<id>" "Show a quick reference for common Weave workflows, routing rules, and integrations.

--procedure=<id> prints a procedure: the repository's own
.weave/procedures/<id>.md if it has one, which replaces the installed procedure
of the same id in this repository, else the installed one. Repository
procedures follow the same contract and project into this repository's agent
surfaces when wv init-repo refreshes it; wv doctor reports a stale projection."
            ;;
        prune)
            print_command_help "wv prune [--age=48h] [--dry-run] [--orphans-only]" "Archive old done nodes, optionally targeting only orphaned ones."
            ;;
        kind)
            print_command_help "wv kind backfill [--apply] [--json]" "Give every node a kind (metadata.node_kind, mirrored to type) from node_kind, type, then the text prefix; without --apply only reports, and --apply refuses if wv ready would change."
            ;;
        unarchive)
            print_command_help "wv unarchive <id> [--dry-run] [--with-edges]" "Restore a pruned node from .weave/archive/ back into the live graph."
            ;;
        commit-refs)
            print_command_help "wv commit-refs [--json] [--all] [--prune [--dry-run]] | --trailers [--json]" \
                "Audit the commit SHAs recorded in node metadata against the pushed branch.

--trailers runs the audit the other way round: Weave-ID trailers already pushed
to the world that name a node this graph has no record of ever writing. Absence
alone is not the finding, because pruned history is absent too, so an id is
reported only when the tracked write log never wrote it; ids predating that log
are separated as unadjudicable. Read-only and offline, and the repair it prints
is wv add --id=<id>.

Classes: reachable (ancestor of the pushed ref), pending (local only — unpushed
or on another branch, not an orphan), unreachable (object exists but no ref
reaches it — superseded by an amend/reset/rebase), missing (gone from this
object database). Orphaned = unreachable + missing.

By default only orphaned refs are listed; --all lists every recorded ref.
--prune removes orphaned refs at every node that records them, children
included — an epic-only edit does not survive, because epics regenerate their
commits list from their children."
            ;;
        clean-ghosts)
            print_command_help "wv clean-ghosts [--dry-run]" "Remove edges that reference deleted nodes."
            ;;
        compact)
            print_command_help "wv compact [--older-than=Nd] [--dry-run] [--force]" "Delete replayed delta files after age and active-claim safety checks."
            ;;
        cutover)
            print_command_help "wv cutover [--yes] [--force] [--json]" "Stamp the causal cutover (.weave/causal-cutover) so cmd_load skips the pre-lineage v1 delta back-catalog. Operator-run; requires every agent synced."
            ;;
        refs)
            print_command_help "wv refs <file> | wv refs -t <text> | echo <text> | wv refs [--link --from=<id>] [--json] [--max=N]" "Extract Weave node references from text and optionally create edges."
            ;;
        import)
            print_command_help "wv import <file.jsonl> [--filter=\"id=...\"] [--dry-run]" "Import nodes from JSONL/JSON exports."
            ;;
        batch)
            print_command_help "wv batch [file] [--dry-run] [--stop-on-error]" "Execute multiple wv commands from a file or stdin.

Line format: one command per line, with or without a leading 'wv'. Blank lines
and lines starting with # are skipped. A line is split into arguments by shell
quoting rules (single quotes, double quotes, backslash escapes) and nothing is
expanded: no globs, variables or command substitution, and a # inside a line is
literal text. A line with an unbalanced quote fails. Each command runs with
stdin closed, so it cannot read the rest of the batch.

  add \"Fix the parser\" --status=active
  wv update wv-1234 --text='a *literal* star'"
            ;;
        sync)
            print_command_help "wv sync [--gh] [--dry-run] [--mode=fast|full|repair] [--node=<id>]" "Persist in-memory graph state to the git-backed .weave layer and optionally sync GitHub issues. Modes: fast (bounded to focus + impacted set, default for wv ship/session-end), full (exhaustive reconcile), repair (resumable from .weave/repair-checkpoint.json after timeout/interrupt — use after wv recover or stop-hook recommendation)."
            ;;
        load)
            print_command_help "wv load" "Load the graph from the git-backed .weave layer."
            ;;
        version)
            print_command_help "wv version" "Print the installed Weave CLI version."
            ;;
        context-policy)
            print_command_help "wv context-policy [--json] [--refresh]" "Print the context load policy (HIGH/MEDIUM/LOW) and its reason, from repository size signals. The one source every harness reads: the Claude SessionStart hook and MCP weave_overview both call it. Cached an hour in .weave/.context_policy; keeps the .weave/runtime.md policy block current. Runs no load."
            ;;
        hotzone)
            print_command_help "wv hotzone list [--json]" "List all hot-zones (active graph DB directories) with status, node count, and owner."
            print_command_help "wv hotzone db" "Print this repository's resolved brain.db path. Read the graph DB through it (DB=\$(wv hotzone db); sqlite3 -readonly \"\$DB\"): placement adopts the zone already holding this repository's database, else the /tmp zone (wv-b831e3), and sqlite3 on a guessed path creates an empty database there."
            print_command_help "wv hotzone gc [--dry-run]" "Remove orphan hot-zone directories (no matching live repo). Skips dirs newer than 1h."
            print_command_help "wv hotzone diff <brain.db> <brain.db>" "Compare two copies of one repository's graph, read-only, over every table a sync keeps (nodes, edges, file attribution, tombstones): rows only in one, or differing. Run it before removing either copy of a repository found in two hot zones: syncing both does not merge them (wv-a73141). It needs no hot zone, so it runs even where placement is refused (wv-757de1). Exit 0 identical, 1 different, 2 unusable arguments."
            ;;
        *)
            echo "Unknown help topic: $topic" >&2
            echo "Try 'wv --help' to list available commands." >&2
            return 1
            ;;
    esac
}

cmd_help() {
    local topic="${1:-}"
    if [ -n "$topic" ]; then
        shift || true
        cmd_help_topic "$topic" "$@"
        return $?
    fi

    cat <<EOF
wv — Weave CLI: In-memory graph for AI coding agents

Usage: wv <command> [args]
       wv help <command>
       wv <command> --help

Commands:
  init              Initialize database
  add <text>        Add a node (returns ID) [--gh creates GitHub issue]
  remember <text>   Capture graph-native memory (type=memory, mem_status=active)
  memory <sub>      Recall/render/scan/import graph memory
  delete <id>       Permanently remove a node + edges [--force] [--dry-run] [--no-gh]
  done <id>         Mark node complete [--learning="..."] [--no-warn] [auto-closes GH issue]
    ship <id>         Done + sync in one step; Git sync surfaced separately [--learning="..."] [--gh]
  batch-done        Close multiple nodes [--learning="..."] [--no-warn] [--no-gh]
  bulk-update       Update multiple nodes from JSON on stdin [--dry-run]
  work <id>         Claim node & set WV_ACTIVE for subagent context [--quiet]
  preflight <id>    Pre-action checks as JSON (blockers, contradictions, context load)
  recover           Resume incomplete operations (ship/sync/delete) [--auto] [--json] [--session]
  bootstrap         Single-call JSON bootstrap context for agents [--json]
    bootstrap-agent   Agent bootstrap contract with command/provenance/readiness [--json]
    ship-agent        Agent-safe non-interactive close + sync wrapper [--json]
  overview          Compact graph summary [--json]
  cache             Claude prompt-cache diagnostics [--json]
  pending-close     List nodes awaiting human acknowledgement after learning overlap [--json]
  ready             List unblocked work
  list              List nodes (excludes done by default)
  show <id>         Show node details
  status            Compact status for context injection
  update <id>       Update node (run 'wv update --help' for metadata forms and safer input)
  touch <id>        Silent metadata merge for per-turn intent updates
  allowed-tools     Read metadata.allowed_tools for a node [--json]
  quick             Create and close a trivial one-step node
  hook dispatch     Host-neutral lifecycle hook dispatcher [--event=] [--json]
  block <id>        Add blocking edge (--by=<blocker>)
  link <from> <to>  Create semantic edge (--type=<type> [--weight=] [--context=])
  unlink <from> <to> Remove a semantic edge (--type=<type>)
  resolve <n1> <n2> Resolve contradiction (--winner=<id> | --merge | --defer [--rationale=])
  related <id>      Show semantic relationships ([--type=] [--direction=] [--json])
  edges <id>        Inspect all edges for a node ([--type=] [--json])
  path <id>         Show ancestry chain
  impact <id>...    Blast-radius: impacted nodes, risk, unblocked work, test suites [--files=] [--json]
  discover <id>     Blindspot report: query + impact buckets [--json]
  tree              Show epic -> task hierarchy [--active] [--depth=N] [--json] [--mermaid] [root]
  plan <file>       Import markdown section as epic + tasks [--sprint=N] [--gh] [--dry-run] [--template]
  enrich-topology   Apply epic/task topology from JSON spec [--dry-run] [--sync-gh]
  context [id]      Generate Context Pack [--json | pretty-print] (uses WV_ACTIVE if no id)
  search <query>    Full-text search nodes [--limit=N] [--status=] [--json]
  reindex           Rebuild full-text search index
  learnings         Show captured learnings [--category=] [--grep=] [--recent=N] [--mode=]
  trails            Session trails [save|show|clear|capsule <id>] (alias: breadcrumbs)
  digest            Compact one-liner health summary [--json]
  session-summary   Session activity stats (nodes created/completed, learnings)
  audit-pitfalls    Show all pitfalls with resolution status
  pattern-audit     Audit source for recurring bug-pattern invariants [--json] [--strict]
  edge-types        List valid semantic edge types [--stats] [--json]
  repo-class        Inspect/set clone-local owned vs vendored-upstream classification; audit scaffolding exposure
  init-repo         Bootstrap owned repo for Weave [--agent=claude|copilot|codex|all] [--codex-hooks] [--update] [--force]
  self-update       Refresh installed wv from the dev clone recorded at install time
  uninstall         Remove installed wv files (delegates to install.sh --uninstall)
  doctor            Installation + surface-contract checks (deps, hooks, ghost settings, matchers) [--json]
  hotzone <sub>     Hot-zone DB directories (list, db, diff, gc) [--json] [--dry-run]
  context-policy    Context load policy (HIGH/MEDIUM/LOW) and reason [--json] [--refresh]
  selftest          Round-trip smoke test in isolated environment [--json]
  test-record <suite> Record a test-suite run for verification freshness (used by git hooks)
  test-status <suite> Check whether every named file has a fresh green suite result
    mcp-status        Verify MCP server is built and IDE config shape is current [--json]
  health            System health check with score and diagnostics [--history[=N]]
  config            Manage durable opt-in knobs [list|get|set|unset|enable|disable]
    guide             Workflow quick reference [--topic=workflow|github|learnings|context|routing|mcp|verification|instrumentation|config|discovery]
  prune             Archive old done nodes
  kind backfill     Give every node a kind from type and text prefix [--apply] [--json]
  cutover           Stamp the causal cutover so load skips the pre-lineage delta back-catalog [--yes] [--force] [--json]
  unarchive <id>    Restore a pruned node from .weave/archive/ [--dry-run] [--with-edges]
  clean-ghosts      Delete ghost edges referencing deleted nodes [--dry-run] [legacy compatibility]
  commit-refs       Audit recorded commit SHAs against the pushed branch [--json] [--all] [--prune]
  compact           Delete replayed deltas after safety checks [--older-than=Nd]
  refs <file|text>  Extract cross-references (dry-run, no edges)
  import <file>     Import from beads JSONL or JSON
  quality <sub>     Code quality scanner (scan, hotspots, diff, promote, reset)
  findings <sub>    Historical finding promotion (list, promote)
  validate-finding <id>  Validate finding metadata: exit 0/1 + JSON errors (used by pre-close hook)
  analyze <sub>     Analyze agent session traces and instrumentation data
  query [pred...]   Predicate-based graph reader (status=, HAS, MATCH, IN)
  batch [file]      Execute multiple wv commands from file or stdin [--dry-run] [--stop-on-error]
  sync              Persist to git layer (.weave/) [--gh GH sync] [--dry-run]
  load              Load from git layer

Options:
  --json            Output as JSON (ready, list, show, health, search)
  --all             Include done nodes (list)
  --count           Return count only (ready)
  --verbose, -v     Show diagnostics (health)
  --history[=N]     Show last N health checks (default 10)
  --format=chain    Show as "A -> B -> C" (path)
  --node=<id>       Filter to one node (learnings)
  --show-graph      Show pitfall resolution graph (learnings)
  --age=48h         Prune age threshold (prune)
  --dry-run         Show what would be pruned (prune, import)
  --max=N           Max references to extract (refs, default 10)
  --limit=N         Max results to return (search, default 10)
  --status=<status> Filter by status (search)
  --claimed-by=<id>|current  Filter list by claim owner
  --link            Create edges for detected refs (refs, requires --from)
  --from=<id>       Source node for edge creation (refs --link)
  --interactive     Prompt for non-auto refs in link mode (refs --link)
  --gh              Create GitHub issue (add) or run GH sync (sync)
  --learning="..."  Store learning note on close (done)
  --no-warn         Suppress validation warnings (done) [also: WV_NO_WARN=1]
  --remove-key=<k>  Remove a single metadata key (update)
  --metadata=<json> Merge JSON into existing metadata (update)
  --metadata-file=<path> Read metadata JSON from a file or stdin (update)
  --category=<cat>  Filter by type: decision/pattern/pitfall/learning (learnings)
  --grep=<pattern>  Search text and metadata (learnings)
  --recent=<N>      Show only last N learnings (learnings)
  --mode=<mode>     Output mode: bootstrap|discover|execute|full (read surfaces)
  --message="..."   Custom note for trails (trails save)

Examples:
  wv add "Fix authentication bug"
    wv add "Refactor API" --status=active --criteria="make check passes|docs updated" --risks=low --gh
  wv ready
  wv work wv-a1b2                             # claim node, show WV_ACTIVE export
  eval "\$(wv work wv-a1b2 --quiet)"          # claim and set WV_ACTIVE in one command
  wv context --json                           # uses WV_ACTIVE if set
  wv help update                              # focused help for one command
  wv show --help                              # alternate focused help form
  wv done wv-a1b2 --learning="pattern: always check X"
    wv ship wv-a1b2 --learning="decision: ..."  # done + sync; check status for Git sync
  wv batch-done wv-a1b2 wv-c3d4 --learning="sprint complete"
  wv preflight wv-a1b2                        # check blockers/contradictions
  wv recover --auto                           # resume interrupted operations
  echo '[{"id":"wv-a1b2","alias":"my-task"},{"id":"wv-c3d4","status":"active"}]' | wv bulk-update
  wv update wv-a1b2 --metadata='{"priority":1}'  # merges, not replaces
  wv update wv-a1b2 --metadata-file meta.json     # safer metadata input
  wv update wv-a1b2 --remove-key=old_field        # remove single key
  wv block wv-c3d4 --by=wv-a1b2
  wv link wv-a1b2 wv-c3d4 --type=implements --weight=0.8
  wv resolve wv-a1b2 wv-c3d4 --winner=wv-a1b2 --rationale="Approach A is more performant"
  wv related wv-a1b2 --type=implements
  wv edges wv-a1b2
  wv sync --gh
  wv path wv-c3d4 --format=chain
  wv search "authentication" --limit=5
  wv search "bug" --status=todo --json
  wv reindex
  wv plan --template > docs/my-plan.md          # scaffold a plan from template
  wv plan docs/my-plan.md --sprint=1 --dry-run   # preview import
  wv plan docs/my-plan.md --sprint=1 --gh         # import with GitHub issues
  wv refs docs/design.md
  wv refs -t "see wv-a1b2" --link --from=wv-c3d4
  wv refs file.md --json
  wv trails save --message="Pausing for review"
  wv trails show
  wv digest
  wv learnings --category=pitfall --recent=5
  wv learnings --grep="testing"
  wv done wv-a1b2 --no-warn
  wv init-repo                                # bootstrap .claude/ for current repo (claude agent)
  wv init-repo --agent=copilot                # add VS Code Copilot config (.vscode/mcp.json + instructions)
  wv init-repo --agent=codex                  # add Codex setup contract (.codex/weave.json)
  wv init-repo --agent=codex --codex-hooks    # opt in to project Codex lifecycle hooks
  wv init-repo --agent=all                    # claude, copilot, and codex
  wv init-repo --update                       # refresh managed files (skills, agents, instructions)
  wv init-repo --force                        # overwrite ALL files including user-customized
EOF
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_repo_class — Clone-local repository ownership boundary and exposure audit
# ═══════════════════════════════════════════════════════════════════════════
cmd_repo_class() {
    local action="show" format="text" offline=0 acknowledge=0 class="" repo
    repo=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
    while [ $# -gt 0 ]; do
        case "$1" in
            show|audit) action="$1" ;;
            set)
                action="set"
                shift
                class="${1:-}"
                ;;
            --json) format="json" ;;
            --offline) offline=1 ;;
            --acknowledge-upstream-fork) acknowledge=1 ;;
            --help|-h)
                cmd_help repo-class
                return 0
                ;;
            *) echo "wv repo-class: unknown argument: $1" >&2; return 2 ;;
        esac
        shift
    done

    if [ "$action" = "set" ]; then
        [ -n "$class" ] || { echo "wv repo-class set requires owned or vendored-upstream" >&2; return 2; }
        wv_repository_class_set "$repo" "$class" "$acknowledge" || return $?
    fi

    local result rc=0
    if [ "$action" = "audit" ]; then
        result=$(wv_repository_audit_json "$repo" "$offline") || rc=$?
    else
        result=$(wv_repository_class_json "$repo" "$offline")
    fi
    if [ "$format" = "json" ]; then
        printf '%s\n' "$result"
    elif [ "$action" = "audit" ]; then
        printf 'Repository class: %s (%s)\n' "$(jq -r '.class' <<< "$result")" "$(jq -r '.reason' <<< "$result")"
        case "$(jq -r '.exposure_state' <<< "$result")" in
            clean) printf 'Scaffolding audit: clean\n' ;;
            residue_only) printf 'Scaffolding audit: PASS (unreachable residue; pruning optional)\n' ;;
            *) printf 'Scaffolding audit: REMEDIATION REQUIRED\n' ;;
        esac
        if [ "$(jq -r '.remediation_required' <<< "$result")" = true ]; then
            jq -r '(.current_exposure.tracked_paths[] | "  tracked: \(.)"), (.current_exposure.marker_paths[] | "  marker: \(.)"), (.reachable_exposure.history_commits[] | "  reachable history: \(.)")' <<< "$result"
        elif [ "$(jq -r '.exposure_state' <<< "$result")" = residue_only ]; then
            jq -r '.residue.commits[] | "  unreachable residue: \(.)"' <<< "$result"
        fi
    else
        printf 'Repository class: %s\n' "$(jq -r '.class' <<< "$result")"
        printf 'Source: %s\n' "$(jq -r '.source' <<< "$result")"
        printf 'Reason: %s\n' "$(jq -r '.reason' <<< "$result")"
    fi
    return "$rc"
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_init_repo — Bootstrap a repo for Claude Code + Weave (Alt-A architecture)
#
# Creates .claude/settings.json with permissions only (no hooks key).
# Global hooks live in ~/.claude/settings.json — installed by install.sh.
# ═══════════════════════════════════════════════════════════════════════════
cmd_init_repo() {
    # Delegate to the standalone wv-init-repo binary which handles
    # --agent=claude|copilot|codex|all, --update, --force, skills, agents,
    # copilot-instructions, .vscode/mcp.json, etc.
    local init_repo_bin
    init_repo_bin=$(command -v wv-init-repo 2>/dev/null || echo "$HOME/.local/bin/wv-init-repo")

    if [ -x "$init_repo_bin" ]; then
        "$init_repo_bin" "$@"
    else
        echo -e "${RED}✗${NC} wv-init-repo not found. Run install.sh first." >&2
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_self_update — Refresh installed wv from the dev clone
# Reads source path written by install.sh to ~/.config/weave/source-path.
# Falls back to wv-update for release-binary users (no local clone).
# ═══════════════════════════════════════════════════════════════════════════
cmd_self_update() {
    local source_path_file="$HOME/.config/weave/source-path"
    local wv_update_bin
    wv_update_bin=$(command -v wv-update 2>/dev/null || echo "$HOME/.local/bin/wv-update")

    if [ -f "$source_path_file" ]; then
        local src_root; src_root=$(cat "$source_path_file" 2>/dev/null || echo "")
        if [ -n "$src_root" ] && [ -f "$src_root/install.sh" ] && \
           git -C "$src_root" rev-parse --git-dir &>/dev/null 2>&1; then
            echo "Updating Weave from $src_root..."
            cd "$src_root" && bash install.sh "$@"
            return $?
        fi
    fi

    # Fallback: use the standalone wv-update binary
    if [ -x "$wv_update_bin" ]; then
        "$wv_update_bin" "$@"
    else
        echo -e "${RED}✗${NC} No install source found. Re-run install.sh from the dev clone." >&2
        return 1
    fi
}

# cmd_uninstall — Remove installed wv files via install.sh --uninstall
# ═══════════════════════════════════════════════════════════════════════════
cmd_uninstall() {
    local source_path_file="$HOME/.config/weave/source-path"

    if [ -f "$source_path_file" ]; then
        local src_root; src_root=$(cat "$source_path_file" 2>/dev/null || echo "")
        if [ -n "$src_root" ] && [ -f "$src_root/install.sh" ]; then
            bash "$src_root/install.sh" --uninstall "$@"
            return $?
        fi
    fi

    # Fallback: download install.sh from GitHub and run --uninstall
    local tmp_installer; tmp_installer=$(mktemp /tmp/wv-install-XXXXXX.sh)
    echo "Downloading install.sh from GitHub..."
    if curl -sSL "https://raw.githubusercontent.com/AGM1968/weave/main/install.sh" -o "$tmp_installer"; then
        bash "$tmp_installer" --uninstall "$@"
        local rc=$?
        rm -f "$tmp_installer"
        return $rc
    else
        rm -f "$tmp_installer"
        echo -e "${RED}✗${NC} Could not reach GitHub. Run install.sh --uninstall manually." >&2
        return 1
    fi
}
