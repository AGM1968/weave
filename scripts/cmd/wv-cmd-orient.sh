#!/bin/bash
# wv-cmd-orient.sh — session orientation for agents
#
# Commands: bootstrap, bootstrap-agent, preflight, overview, digest, repo-class, audit-pitfalls, context-policy, session-summary
# Sourced by: wv entry point (autoloaded on first use)
# Dependencies: wv-config.sh, wv-db.sh, wv-validate.sh, wv-cmd-core.sh
#
# Moved unchanged from wv-cmd-ops.sh (wv-71933b, the wv-c153c4 split) so a change
# here routes only to the suites that exercise the orientation commands.
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
            {commit, exit, at, target, tier} + (
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

# _bootstrap_load_json -> the last wv load attempt on this hot zone's graph
# (wv-2f55dd): {state, at, reasons} from _weave_load_attempt, or null when no
# attempt was recorded. A failed load leaves the graph without every change made
# only in deltas since the last state.sql, and on 2026-11-09 one ran unnoticed for
# nine hours behind a single warning line (wv-5e5f18).
_bootstrap_load_json() {
    local db="${WV_DB:-}" row
    [ -n "$db" ] && [ -f "$db" ] || { echo null; return 0; }
    row=$(sqlite3 -readonly -json "$db" "SELECT state, at, reasons FROM _weave_load_attempt WHERE id = 1;" 2>/dev/null) \
        || { echo null; return 0; }
    jq -c '.[0] // null' <<< "${row:-[]}" 2>/dev/null || echo null
}

# _bootstrap_gate_json -> this checkout's gate state (wv-c5500d):
# {holder, last_push}, each a record from scripts/lib/wv-gate-hold.sh or null.
# holder is a gate running now (pid alive and started when recorded); a
# restarted session sees the push it left behind. Read-only: never takes the
# lock. null when the library is not beside this module.
_bootstrap_gate_json() {
    local lib holder last
    lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" 2>/dev/null && pwd)/wv-gate-hold.sh"
    [ -r "$lib" ] || { echo null; return 0; }
    # shellcheck source=/dev/null
    . "$lib" 2>/dev/null || { echo null; return 0; }
    holder=$(wv_gate_hold_status 2>/dev/null); [ -n "$holder" ] || holder=null
    last=$(wv_gate_push_last 2>/dev/null); [ -n "$last" ] || last=null
    jq -cn --slurpfile h <(printf '%s' "$holder") --slurpfile l <(printf '%s' "$last") \
        '{holder: $h[0], last_push: $l[0]}' 2>/dev/null || echo null
}

# _bootstrap_readiness_advisories <framework_json> <structural_json>
# [heavy_tier_json] [gate_json] [load_json] -> a JSON array of advisory strings, framework first.
_bootstrap_readiness_advisories() {
    # The structural list is uncapped: files, not argv (wv-200d36).
    jq -cn --slurpfile fw <(printf '%s' "$1") --slurpfile st <(printf '%s' "$2") \
        --slurpfile ht <(printf '%s' "${3:-null}") --slurpfile gt <(printf '%s' "${4:-null}") \
        --slurpfile ld <(printf '%s' "${5:-null}") '
        $fw[0] as $fw | $st[0] as $st | $ht[0] as $ht | $gt[0] as $gt | $ld[0] as $ld
        | ($gt.holder // null) as $hold
        | def short: (. // "") | .[0:9];
        # The tier the record names (wv-dfd636): make check is the fast tier.
        def ran: "\(.target // "make check")\(if .tier then " (\(.tier) tier)" else "" end)";
        [
            # The graph itself first: every other reading depends on it (wv-2f55dd).
            (if $ld != null and $ld.state == "failed" then
                "graph load not acknowledged (last attempt \($ld.at)): \($ld.reasons) - changes made only in deltas since the last state.sql are missing from this graph; fix before other work (wv load names the failing operation)"
             else empty end),
            (if $fw == null then empty
             elif $fw.state == "red" then
                "framework red: \($fw | ran) failed (exit \($fw.exit)) at HEAD \($fw.commit | short) - fix it before other work"
             elif $fw.state == "stale" then
                "framework unverified for HEAD: last \($fw | ran) ran at \($fw.commit | short) and exited \($fw.exit) - run make check"
             elif $fw.state == "unverified" then
                "framework unverified: \($fw | ran) passed at HEAD with uncommitted changes - commit or rerun"
             elif $fw.state == "unknown" then
                "framework unverified: \($fw.reason // "no result") - run make check"
             else empty end),
            ($st[] | "structural, fix first: \(.id) \(.text)"),
            (if $ht == null then empty
             elif $ht.state == "red" then
                "heavy tier red for commits not on \($ht.upstream): \([$ht.suites[] | select(.state == "red") | .suite] | join(", ")) - last frozen attempt failed; fix before other work; git push revalidates"
             elif $ht.state == "green" then
                "heavy tier last passed for this tip; current execution inputs are unverified - git push checks exact reuse eligibility"
             elif $ht.state == "pending" and ($hold.kind // "") == "pre-push" then
                "heavy tier pending for commits not on \($ht.upstream): \([$ht.suites[] | select(.state != "green") | .suite] | join(", ")) - a push gate is running them now (pid \($hold.pid)); wait for its result, do not push again"
             elif $ht.state == "pending" then
                "heavy tier pending for commits not on \($ht.upstream): \([$ht.suites[] | select(.state != "green") | .suite] | join(", ")) - git push runs them"
             elif $ht.state == "unknown" then
                "heavy tier unknown for commits not on \($ht.upstream): \($ht.reason // "no reason given") - git push refuses until it resolves"
             else empty end),
            # The gate of this checkout (wv-c5500d): one running now, then how the
            # last push ended when it did not pass.
            (if $hold == null then empty else
                "gate in flight on this checkout: \($hold.kind) held by \($hold.agent_id) (pid \($hold.pid), since \($hold.started_at)\(if ($hold.subject // "") != "" then ", \($hold.subject)" else "" end)) - wait for it; another commit or push gate is refused until it ends"
             end),
            ($gt.last_push // null | if . == null then empty
             elif .state == "failed" then
                "last push failed\(if (.detail // "") != "" then " on \(.detail)" else "" end) (exit \(.exit // "?"), ended \(.ended_at // "?"), \(.subject // "")) - fix it, then git push again"
             elif .state == "interrupted" then
                "last push interrupted: its gate (pid \(.pid), held by \(.agent_id), since \(.started_at)) ended without a result - git push again"
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

    # This owner's primary, else its newest claim: never another session's
    # active node (wv-43d6be, wv-1caf6c).
    active_id=$(resolve_active_primary "$WV_DB" "$WV_HOT_ZONE" 2>/dev/null || true)

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
        local q_status q_files
        q_status=$(echo "$quality_readiness" | jq -r '.quality.status // ""' 2>/dev/null || echo "")
        q_files=$(echo "$quality_readiness" | jq -r '.tracked_files // 0' 2>/dev/null || echo "0")
        # wv done scans an empty hot zone itself (wv-f4f431); scanning during
        # the work still shows a complexity refusal before the finish line.
        if [ "$q_status" = "scan_on_close" ]; then
            quality_advisory="quality scan needed: active node $active_id touches $q_files tracked file(s) but quality.db has no scan data — 'wv done' will scan before judging; run 'wv quality scan .' now to see any complexity refusal early"
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
    local framework_json structural_json heavy_json gate_json load_json readiness_advisories
    framework_json=$(_bootstrap_framework_json)
    structural_json=$(_bootstrap_structural_json)
    heavy_json=$(_bootstrap_heavy_tier_json 2>/dev/null) || heavy_json='null'
    [ -n "$heavy_json" ] || heavy_json='null'
    gate_json=$(_bootstrap_gate_json 2>/dev/null) || gate_json='null'
    [ -n "$gate_json" ] || gate_json='null'
    load_json=$(_bootstrap_load_json 2>/dev/null) || load_json='null'
    [ -n "$load_json" ] || load_json='null'
    readiness_advisories=$(_bootstrap_readiness_advisories "$framework_json" "$structural_json" "$heavy_json" "$gate_json" "$load_json" 2>/dev/null || echo '[]')

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
        --slurpfile gate <(printf '%s' "$gate_json") \
        --slurpfile load <(printf '%s' "$load_json") \
        --slurpfile memory <(printf '%s' "$memory_json") \
        '$status[0] as $status | $active_node[0] as $active_node
        | $context[0] as $context | $ready[0] as $ready | $learnings[0] as $learnings
        | $framework[0] as $framework | $structural[0] as $structural
        | $readiness_adv[0] as $readiness_adv | $heavy_tier[0] as $heavy_tier | $gate[0] as $gate | $load[0] as $load
        | $memory[0] as $memory
        | {
            status: $status,
            readiness: {load: $load, framework: $framework, structural: $structural, heavy_tier: $heavy_tier, gate: $gate, advisories: $readiness_adv},
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

    # A missing or empty quality.db (a reboot clears the tmpfs hot zone) no
    # longer blocks: wv done runs the scan itself before judging (wv-f4f431),
    # so the MCP close does not refuse what the CLI close recovers from.
    local quality_db="$WV_HOT_ZONE/quality.db" latest_scan=""
    [ -f "$quality_db" ] && latest_scan=$(sqlite3 -batch -cmd ".timeout 3000" "$quality_db" \
        "SELECT id FROM scan_meta ORDER BY id DESC LIMIT 1;" 2>/dev/null || echo "")
    if [ -z "$latest_scan" ]; then
        jq -cn \
            --argjson tracked_files "$tracked_files" \
            --arg quality_db "$quality_db" \
            --arg detail "quality.db has no scan data in this hot zone; wv done runs the scan before judging the close." \
            --arg hint 'Run `wv quality scan . --json` now to see any complexity refusal before the close.' \
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
                    status: "scan_on_close",
                    detail: "no scan data yet; wv done scans before judging",
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
    # The history node is a graph write: publish it like any other (wv-851fb4).
    auto_sync_or_warn >&2

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
