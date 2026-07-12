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

_bootstrap_repo_wv_path() {
    [ -n "${REPO_ROOT:-}" ] || return 0
    canonicalize_runtime_path "$REPO_ROOT/scripts/wv"
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

_bootstrap_python_command() {
    local repo_root="${REPO_ROOT:-}"

    if [ -n "$repo_root" ] && [ -f "$repo_root/pyproject.toml" ] && command -v poetry >/dev/null 2>&1; then
        echo "poetry run python"
        return 0
    fi
    if [ -n "$repo_root" ] && [ -x "$repo_root/.venv/bin/python3" ]; then
        canonicalize_runtime_path "$repo_root/.venv/bin/python3"
        return 0
    fi
    if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -x "${CLAUDE_PROJECT_DIR}/.venv/bin/python3" ]; then
        canonicalize_runtime_path "${CLAUDE_PROJECT_DIR}/.venv/bin/python3"
        return 0
    fi
    if [ -n "${CONDA_PREFIX:-}" ] || [ -n "${CONDA_DEFAULT_ENV:-}" ]; then
        if ! python3 -c "import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)" 2>/dev/null; then
            if [ -x /usr/bin/python3 ]; then
                canonicalize_runtime_path /usr/bin/python3
                return 0
            fi
        fi
    fi
    if command -v python3 >/dev/null 2>&1; then
        canonicalize_runtime_path "$(command -v python3)"
        return 0
    fi
    if command -v python >/dev/null 2>&1; then
        canonicalize_runtime_path "$(command -v python)"
    fi
}

_wv_python_module_path() {
    local module_dir="$1"
    local _wv_pypath="${WV_LIB_DIR:-$SCRIPT_DIR}"

    if [ ! -d "$_wv_pypath/$module_dir" ]; then
        local _wv_real
        _wv_real=$(readlink -f "$_wv_pypath/lib/wv-config.sh" 2>/dev/null || echo "")
        if [ -n "$_wv_real" ]; then
            _wv_pypath=$(dirname "$(dirname "$_wv_real")")
        fi
    fi

    printf '%s\n' "$_wv_pypath"
}

_wv_agent_python_exec_module() {
    local module="$1"
    local pypath="$2"
    shift 2

    local python_command
    python_command=$(_bootstrap_python_command)
    if [ -z "$python_command" ]; then
        echo "wv: no usable Python found for $module" >&2
        return 127
    fi

    case "$python_command" in
        "poetry run python")
            PYTHONPATH="$pypath" poetry run python -m "$module" "$@"
            ;;
        *)
            PYTHONPATH="$pypath" "$python_command" -m "$module" "$@"
            ;;
    esac
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
    # The hot-zone path (/tmp/weave-codex-*) was previously used here but is ephemeral
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
    if [ -n "$python_command" ]; then
        case "$python_command" in
            "poetry run python") command -v poetry >/dev/null 2>&1 && python_ready=true ;;
            *) [ -x "$python_command" ] && python_ready=true ;;
        esac
    fi
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
                echo "context pack, ready work, and recent learnings in one JSON blob."
                echo ""
                echo "Options:"
                echo "  --learnings=N  Number of recent learnings (default: 5)"
                echo "  --ready=N      Number of ready nodes (default: 10)"
                return 0
                ;;
        esac
        shift
    done

    if [ "$format" != "json" ]; then
        echo "Error: wv bootstrap only supports --json output" >&2
        return 1
    fi

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
    local ready_json
    ready_json=$(db_query_json_v2 "
        SELECT n.id, n.text, n.status, n.metadata FROM nodes n
        WHERE n.status = 'todo'
          AND json_extract(n.metadata, '\$.type') IS NOT 'finding'
          AND NOT EXISTS (
              SELECT 1 FROM edges e
              JOIN nodes blocker ON e.source = blocker.id
              WHERE e.target = n.id AND e.type = 'blocks' AND blocker.status != 'done'
          )
        ORDER BY n.created_at ASC
        LIMIT $ready_limit;
    ")
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
        drift_advisory="install drift: edited source not reinstalled (${drift_files}) — run ./install.sh (dev repo) or 'wv init-repo --update' (consumer) before committing, or the pre-commit drift gate fails"
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

    # ── Compose final JSON ──
    jq -n \
        --argjson status "$status_json" \
        --argjson active_node "$active_node" \
        --argjson context "$context_pack" \
        --argjson ready "$ready_json" \
        --argjson learnings "$learnings_json" \
        --arg breadcrumb "$breadcrumb" \
        --arg drift "$drift_advisory" \
        --arg quality "$quality_advisory" \
        --arg concurrent "$concurrent_advisory" \
        '{
            status: $status,
            active_node: $active_node,
            context: $context,
            advisories: ([$drift, $quality, $concurrent] | map(select(. != ""))),
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
            breadcrumb: (if $breadcrumb != "" then $breadcrumb else null end)
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

    jq -n \
        --argjson base "$base_json" \
        --argjson agent "$agent_json" \
        '$base + {agent: $agent}'
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_digest — Compact one-liner health summary for session start
# ═══════════════════════════════════════════════════════════════════════════

cmd_digest() {
    local format="text"

    while [ $# -gt 0 ]; do
        case "$1" in
            --json) format="json" ;;
        esac
        shift
    done

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
        AND n.id NOT IN (
            SELECT e.target FROM edges e
            WHERE e.type IN ('addresses', 'implements', 'supersedes')
        );
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
        esac
        shift
    done

    db_ensure

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
    local id="${1:-}"

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

    # Orphan check
    local total_edges
    total_edges=$(db_query "SELECT COUNT(*) FROM edges WHERE source='$id' OR target='$id';" 2>/dev/null || echo "0")
    if [ "$total_edges" = "0" ]; then
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
# validate_on_done — Write-time validation warnings when closing a node
# ═══════════════════════════════════════════════════════════════════════════

validate_on_done() {
    local id="${1:-}"
    local suppress_warn="${WV_NO_WARN:-0}"

    # Suppressed by env or --no-warn
    [ "$suppress_warn" = "1" ] && return 0

    local warnings=""

    # Check: no learning captured
    local has_learning
    has_learning=$(db_query "
        SELECT COUNT(*) FROM nodes WHERE id='$id'
        AND (json_extract(metadata, '\$.decision') IS NOT NULL
          OR json_extract(metadata, '\$.pattern') IS NOT NULL
          OR json_extract(metadata, '\$.pitfall') IS NOT NULL
          OR json_extract(metadata, '\$.learning') IS NOT NULL);
    " 2>/dev/null || echo "0")
    if [ "$has_learning" = "0" ]; then
        warnings="${warnings}\n  ⚠ No learning captured — consider: --learning=\"...\""
    fi

    # Check: no verification evidence
    # Suppressed when: (a) verification_method metadata is set, or (b) learning string
    # contains implicit verification keywords (test, passed, verified, lint, etc.)
    local has_verification
    has_verification=$(db_query "
        SELECT COUNT(*) FROM nodes WHERE id='$id'
        AND json_extract(metadata, '\$.verification_method') IS NOT NULL;
    " 2>/dev/null || echo "0")
    if [ "$has_verification" = "0" ]; then
        local learning_text has_implicit kw
        learning_text=$(db_query "
            SELECT LOWER(
                COALESCE(json_extract(metadata, '\$.learning'), '') || ' ' ||
                COALESCE(json_extract(metadata, '\$.decision'), '') || ' ' ||
                COALESCE(json_extract(metadata, '\$.pattern'),  '') || ' ' ||
                COALESCE(json_extract(metadata, '\$.pitfall'),  '')
            )
            FROM nodes WHERE id='$id';
        " 2>/dev/null || echo "")
        has_implicit=false
        for kw in "test" "passed" "verified" "lint" "clean" "make check" "pytest" "ruff" "mypy" "shellcheck"; do
            if [[ "$learning_text" == *"$kw"* ]]; then
                has_implicit=true
                break
            fi
        done
        if [ "$has_implicit" = false ]; then
            warnings="${warnings}\n  ⚠ No verification evidence — consider: wv update $id --metadata='{\"verification_method\":\"tests passed\"}'"
        fi
    fi

    local node_meta node_type finding_missing
    node_meta=$(_done_read_metadata "$id")
    node_type=$(echo "$node_meta" | jq -r '.type // "task"' 2>/dev/null || echo "task")
    if [ "$node_type" = "finding" ]; then
        finding_missing=$(_finding_missing_fields "$node_meta" | paste -sd ', ' - || true)
        if [ -n "$finding_missing" ]; then
            warnings="${warnings}\n  ⚠ Incomplete finding schema — missing or invalid ${finding_missing}"
        fi
    fi

    # Check: orphan node (no edges)
    # Findings are capture-and-park by design — orphan warning is noise for them.
    if [ "$node_type" != "finding" ]; then
        local edge_count
        edge_count=$(db_query "
            SELECT COUNT(*) FROM edges
            WHERE source='$id' OR target='$id';
        " 2>/dev/null || echo "0")
        if [ "$edge_count" = "0" ]; then
            warnings="${warnings}\n  ⚠ Orphan node — no edges. Consider: wv link $id <parent> --type=implements"
        fi
    fi

    # Check: touched files with deteriorating complexity trend
    local trend_rows trend_path trend_direction
    trend_rows=$(db_query "
        SELECT nf.path || '|' || ft.direction
        FROM node_files nf
        JOIN file_trend ft ON ft.path = nf.path
        WHERE nf.node_id='$id' AND ft.direction='deteriorating'
        ORDER BY nf.path;
    " 2>/dev/null || true)
    if [ -n "$trend_rows" ]; then
        while IFS='|' read -r trend_path trend_direction; do
            [ -z "$trend_path" ] && continue
            warnings="${warnings}\n  ⚠ Complexity trend ${trend_direction}: ${trend_path}"
        done <<< "$trend_rows"
    fi

    # Check: metadata size guard — large metadata (>50KB) causes sqlite3 -json to hang during sync
    local meta_size
    meta_size=$(db_query "
        SELECT LENGTH(COALESCE(metadata, '{}')) FROM nodes WHERE id='$id';
    " 2>/dev/null || echo "0")
    if [ "$meta_size" -gt 51200 ] 2>/dev/null; then
        warnings="${warnings}\n  ⚠ Metadata is ${meta_size} bytes (>50KB) — may cause wv sync to hang. Check for escape accumulation in learning strings."
    fi

    # Print warnings if any
    if [ -n "$warnings" ]; then
        echo -e "${YELLOW}Validation hints:${NC}${warnings}" >&2
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# score_learning — Heuristic quality score for learning metadata
# ═══════════════════════════════════════════════════════════════════════════

score_learning() {
    local id="${1:-}"
    local score=0

    local meta
    meta=$(db_query "SELECT json(metadata) FROM nodes WHERE id='$id';" 2>/dev/null)
    [ -z "$meta" ] && return

    # Collect all learning text (decision + pattern + pitfall + learning)
    local all_text
    all_text=$(echo "$meta" | jq -r '[.decision, .pattern, .pitfall, .learning] | map(select(. != null)) | join(" ")' 2>/dev/null)
    [ -z "$all_text" ] && return

    # +1: Length > 20 chars (not a stub)
    if [ ${#all_text} -gt 20 ]; then
        score=$((score + 1))
    fi

    # +2: Has categorized structure — either typed fields present or prefix in raw learning
    local has_typed
    has_typed=$(echo "$meta" | jq -r 'if (.decision != null or .pattern != null or .pitfall != null) then "yes" else "no" end' 2>/dev/null)
    if [ "$has_typed" = "yes" ] || echo "$all_text" | grep -qiE '(pattern:|pitfall:|decision:|technique:)'; then
        score=$((score + 2))
    fi

    # +1: References a specific file or function (contains . or / or ())
    if echo "$all_text" | grep -qE '(\.[a-z]{1,4}\b|/[a-z]|[a-z_]+\(\))'; then
        score=$((score + 1))
    fi

    # Store score in metadata
    local new_meta
    new_meta=$(echo "$meta" | jq --argjson s "$score" '. + {learning_hygiene: $s}' 2>/dev/null)
    if [ -n "$new_meta" ]; then
        new_meta="${new_meta//\'/\'\'}"
        db_query "UPDATE nodes SET metadata='$new_meta' WHERE id='$id';" 2>/dev/null
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# Session activity tracking
# ═══════════════════════════════════════════════════════════════════════════

_save_session_snapshot() {
    local snapshot="$WV_HOT_ZONE/.session_snapshot"
    local total done_count learnings
    # Exclude internal session_history singleton from counts so cross-session
    # delta math (cmd_session_summary) is not skewed by the hygiene record.
    total=$(db_query "SELECT COUNT(*) FROM nodes WHERE json_extract(metadata, '\$.type') IS NOT 'session_history';" 2>/dev/null || echo 0)
    done_count=$(db_query "SELECT COUNT(*) FROM nodes WHERE status='done' AND json_extract(metadata, '\$.type') IS NOT 'session_history';" 2>/dev/null || echo 0)
    learnings=$(db_query "
        SELECT COUNT(*) FROM nodes
        WHERE (json_extract(metadata, '\$.learning') IS NOT NULL
           OR json_extract(metadata, '\$.decision') IS NOT NULL
           OR json_extract(metadata, '\$.pattern') IS NOT NULL
           OR json_extract(metadata, '\$.pitfall') IS NOT NULL)
          AND json_extract(metadata, '\$.type') IS NOT 'session_history';
    " 2>/dev/null || echo 0)
    printf '%s\t%s\t%s\t%s\n' "$(date -u +%s)" "$total" "$done_count" "$learnings" > "$snapshot"
}

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
    now_total=$(db_query "SELECT COUNT(*) FROM nodes WHERE json_extract(metadata, '\$.type') IS NOT 'session_history';" 2>/dev/null || echo 0)
    now_done=$(db_query "SELECT COUNT(*) FROM nodes WHERE status='done' AND json_extract(metadata, '\$.type') IS NOT 'session_history';" 2>/dev/null || echo 0)
    now_learnings=$(db_query "
        SELECT COUNT(*) FROM nodes
        WHERE (json_extract(metadata, '\$.learning') IS NOT NULL
           OR json_extract(metadata, '\$.decision') IS NOT NULL
           OR json_extract(metadata, '\$.pattern') IS NOT NULL
           OR json_extract(metadata, '\$.pitfall') IS NOT NULL)
          AND json_extract(metadata, '\$.type') IS NOT 'session_history';
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
    created_session=$(db_query "SELECT COUNT(*) FROM nodes WHERE created_at >= '$start_iso' AND json_extract(metadata, '\$.type') IS NOT 'session_history' AND json_extract(metadata, '\$.type') IS NOT 'finding';" 2>/dev/null || echo 0)
    with_criteria=$(db_query "SELECT COUNT(*) FROM nodes WHERE created_at >= '$start_iso' AND json_extract(metadata, '\$.done_criteria') IS NOT NULL AND json_extract(metadata, '\$.type') IS NOT 'session_history' AND json_extract(metadata, '\$.type') IS NOT 'finding';" 2>/dev/null || echo 0)
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
    closed_session=$(db_query "SELECT COUNT(*) FROM nodes WHERE status='done' AND updated_at >= '$start_iso' AND json_extract(metadata, '\$.type') IS NOT 'session_history';" 2>/dev/null || echo 0)
    with_learning=$(db_query "SELECT COUNT(*) FROM nodes WHERE status='done' AND updated_at >= '$start_iso' AND (json_extract(metadata, '\$.decision') IS NOT NULL OR json_extract(metadata, '\$.pattern') IS NOT NULL OR json_extract(metadata, '\$.pitfall') IS NOT NULL OR json_extract(metadata, '\$.learning') IS NOT NULL) AND json_extract(metadata, '\$.type') IS NOT 'session_history';" 2>/dev/null || echo 0)
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
    local budget_file="$WV_HOT_ZONE/session-budget.json"
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
    hist_id=$(db_query "SELECT id FROM nodes WHERE json_extract(metadata, '\$.type') = 'session_history' LIMIT 1;" 2>/dev/null)
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
            '{type:"session_history", history:[{ts:$ts, score:$total, edit:$edit, criteria:$criteria, learning:$learning, budget:$budget}]}')
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
# cmd_recover — Resume incomplete operations from journal or ship_pending
# ═══════════════════════════════════════════════════════════════════════════

_git_status_has_outside_weave_changes() {
    local status_lines="$1"
    local raw_path old_path new_path

    while IFS= read -r raw_path; do
        [ -z "$raw_path" ] && continue
        raw_path="${raw_path:3}"
        if [[ "$raw_path" == *" -> "* ]]; then
            old_path="${raw_path%% -> *}"
            new_path="${raw_path##* -> }"
            if [[ "$old_path" != .weave/* ]] || [[ "$new_path" != .weave/* ]]; then
                return 0
            fi
        elif [[ "$raw_path" != .weave/* ]]; then
            return 0
        fi
    done <<< "$status_lines"

    return 1
}

_git_commit_weave_ownership() {
    local git_root="$1"
    local sha="$2"
    local paths path

    paths=$(git -C "$git_root" diff-tree --no-commit-id --name-only -r -m "$sha" 2>/dev/null || true)
    [ -n "$paths" ] || return 2

    while IFS= read -r path; do
        [ -z "$path" ] && continue
        if [[ "$path" != .weave/* ]]; then
            return 1
        fi
    done <<< "$paths"

    return 0
}

_git_pending_hint() {
    case "$1" in
        dirty_weave)
            echo "run: git add .weave/ && git commit -m \"chore: sync Weave [skip ci]\" && git push"
            ;;
        dirty_weave_and_ahead_weave)
            echo "run: git add .weave/ && git commit -m \"chore: sync Weave [skip ci]\" && git push"
            ;;
        ahead_weave)
            echo "run: git push"
            ;;
        no_upstream)
            echo "configure an upstream before retrying recovery"
            ;;
        dirty_outside_weave)
            echo "commit or stash non-.weave changes before retrying recovery"
            ;;
        ahead_non_weave)
            echo "separate or push non-.weave commits manually before retrying recovery"
            ;;
        ahead_empty_commit)
            echo "legacy or ambiguous empty commit ahead — manual remediation required"
            ;;
        *)
            echo "no action required"
            ;;
    esac
}

_detect_git_pending() {
    local git_root upstream="" weave_dirty="" all_status="" ahead_shas=""
    local pending=false weave_dirty_bool=false outside_dirty=false
    local state="clean" action="none" reason="clean" hint="no action required"
    local ahead_count=0 has_non_weave=false has_ambiguous_empty=false sha

    git_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    if [ -z "$git_root" ] || [ ! -d "$git_root/.git" ]; then
        jq -n \
            --argjson pending false \
            --arg state "clean" \
            --arg action "none" \
            --arg reason "not_repo" \
            --arg hint "no action required" \
            --arg upstream "" \
            --argjson ahead_count 0 \
            --argjson weave_dirty false \
            --argjson outside_dirty false \
            '{pending:$pending, state:$state, action:$action, reason:$reason, hint:$hint,
              upstream:$upstream, ahead_count:$ahead_count,
              weave_dirty:$weave_dirty, outside_dirty:$outside_dirty}'
        return 0
    fi

    weave_dirty=$(git -C "$git_root" status --porcelain -- .weave/ 2>/dev/null || true)
    [ -n "$weave_dirty" ] && weave_dirty_bool=true

    all_status=$(git -C "$git_root" status --porcelain 2>/dev/null || true)
    if [ -n "$all_status" ] && _git_status_has_outside_weave_changes "$all_status"; then
        outside_dirty=true
    fi

    upstream=$(git -C "$git_root" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || echo "")
    if [ -n "$upstream" ]; then
        ahead_shas=$(git -C "$git_root" rev-list "${upstream}..HEAD" 2>/dev/null || true)
        if [ -n "$ahead_shas" ]; then
            ahead_count=$(printf '%s\n' "$ahead_shas" | sed '/^$/d' | wc -l | tr -d ' ')
        fi
    fi

    if [ "$ahead_count" -gt 0 ] 2>/dev/null; then
        while IFS= read -r sha; do
            [ -z "$sha" ] && continue
            _git_commit_weave_ownership "$git_root" "$sha"
            case $? in
                1) has_non_weave=true ;;
                2) has_ambiguous_empty=true ;;
            esac
        done <<< "$ahead_shas"
    fi

    if [ "$weave_dirty_bool" = true ] || [ "$ahead_count" -gt 0 ] 2>/dev/null; then
        pending=true
    fi

    if [ "$pending" = true ]; then
        if [ -z "$upstream" ]; then
            state="unresolvable"
            reason="no_upstream"
        elif [ "$outside_dirty" = true ]; then
            state="unresolvable"
            reason="dirty_outside_weave"
        elif [ "$has_non_weave" = true ]; then
            state="unresolvable"
            reason="ahead_non_weave"
        elif [ "$has_ambiguous_empty" = true ]; then
            state="unresolvable"
            reason="ahead_empty_commit"
        elif [ "$weave_dirty_bool" = true ]; then
            state="recoverable"
            action="commit_push"
            reason="dirty_weave"
            if [ "$ahead_count" -gt 0 ] 2>/dev/null; then
                reason="dirty_weave_and_ahead_weave"
            fi
        else
            state="recoverable"
            action="push_only"
            reason="ahead_weave"
        fi
    fi

    hint=$(_git_pending_hint "$reason")
    jq -n \
        --argjson pending "$pending" \
        --arg state "$state" \
        --arg action "$action" \
        --arg reason "$reason" \
        --arg hint "$hint" \
        --arg upstream "$upstream" \
        --argjson ahead_count "$ahead_count" \
        --argjson weave_dirty "$weave_dirty_bool" \
        --argjson outside_dirty "$outside_dirty" \
        '{pending:$pending, state:$state, action:$action, reason:$reason, hint:$hint,
          upstream:$upstream, ahead_count:$ahead_count,
          weave_dirty:$weave_dirty, outside_dirty:$outside_dirty}'
}

cmd_recover() {
    local json_mode=false
    local auto_mode=false
    local session_mode=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) json_mode=true ;;
            --auto) auto_mode=true ;;  # Non-interactive (for wv init/work/ship triggers)
            --session) session_mode=true ;;  # Orphaned active node recovery
        esac
        shift
    done

    # === Session recovery: orphaned active nodes from crashed sessions ===
    if [ "$session_mode" = true ]; then
        _recover_session "$json_mode" "$auto_mode"
        return $?
    fi

    # Source 1: Journal-based recovery (hot zone, lost on reboot)
    local journal_found=false
    local recovery_info=""
    if journal_has_incomplete 2>/dev/null; then
        journal_found=true
        recovery_info=$(journal_recover --json 2>/dev/null || echo '{}')
    fi

    # Source 2: ship_pending metadata fallback (survives reboot via state.sql)
    local pending_nodes=""
    if [ "$journal_found" = false ]; then
        pending_nodes=$(db_query "
            SELECT id, text, json_extract(metadata, '$.ship_pending') as sp
            FROM nodes
            WHERE json_extract(metadata, '$.ship_pending') IS NOT NULL
                AND json_extract(metadata, '$.ship_pending') = 1;
        " 2>/dev/null || true)
    fi

    # Source 3: pending_close markers that need explicit human acknowledgement
    local pending_close_nodes=""
    if [ "$journal_found" = false ] && [ -z "$pending_nodes" ]; then
        pending_close_nodes=$(db_query "
            SELECT id || '|' || text || '|' ||
                   COALESCE(json_extract(metadata, '$.pending_close.reason'), '') || '|' ||
                   COALESCE(json_extract(metadata, '$.pending_close.resume_command'), '')
            FROM nodes
            WHERE json_extract(metadata, '$.needs_human_verification') = 1
                AND json_extract(metadata, '$.pending_close.reason') IS NOT NULL;
        " 2>/dev/null || true)
    fi

    # Source 4: explicit git-state surfacing for dirty/ahead .weave windows.
    # Intentionally disabled in --auto mode so init/work/ship do not perform
    # implicit git probing on read-path-triggered recovery checks.
    local git_pending_json=""
    local git_sync_pending=false
    local git_sync_state="clean"
    local git_sync_action="none"
    local git_sync_reason="clean"
    local git_sync_hint="no action required"
    if [ "$auto_mode" != true ] && [ "$journal_found" = false ] && [ -z "$pending_nodes" ] && [ -z "$pending_close_nodes" ]; then
        git_pending_json=$(_detect_git_pending 2>/dev/null || echo '{}')
        git_sync_pending=$(echo "$git_pending_json" | jq -r '.pending // false' 2>/dev/null || echo "false")
        git_sync_state=$(echo "$git_pending_json" | jq -r '.state // "clean"' 2>/dev/null || echo "clean")
        git_sync_action=$(echo "$git_pending_json" | jq -r '.action // "none"' 2>/dev/null || echo "none")
        git_sync_reason=$(echo "$git_pending_json" | jq -r '.reason // "clean"' 2>/dev/null || echo "clean")
        git_sync_hint=$(echo "$git_pending_json" | jq -r '.hint // "no action required"' 2>/dev/null || echo "no action required")
    fi

    # Nothing to recover
    if [ "$journal_found" = false ] && [ -z "$pending_nodes" ] && [ -z "$pending_close_nodes" ] && [ "$git_sync_pending" != true ]; then
        if [ "$json_mode" = true ]; then
            echo '{"status":"clean","message":"No incomplete operations"}'
        elif [ "$auto_mode" != true ]; then
            echo -e "${GREEN}✓${NC} No incomplete operations found"
        fi
        return 0
    fi

    # === Journal-based recovery ===
    if [ "$journal_found" = true ]; then
        local op op_id completed_steps pending_step pending_action args
        op=$(echo "$recovery_info" | jq -r '.operation.op')
        op_id=$(echo "$recovery_info" | jq -r '.operation.op_id')
        completed_steps=$(echo "$recovery_info" | jq -r '.operation.completed_steps | join(",")' 2>/dev/null)
        pending_step=$(echo "$recovery_info" | jq -r '.operation.pending_step.step // "unknown"')
        pending_action=$(echo "$recovery_info" | jq -r '.operation.pending_step.action // "unknown"')
        args=$(echo "$recovery_info" | jq -c '.operation.args // {}')

        if [ "$json_mode" = true ]; then
            echo "$recovery_info"
            return 0
        fi

        echo -e "${YELLOW}⚠ Incomplete operation detected${NC}"
        echo "  Operation: wv $op ($op_id)"
        echo "  Completed steps: ${completed_steps:-none}"
        echo "  Stuck at: step $pending_step ($pending_action)"
        echo ""

        # Determine recovery action based on op type and stuck step
        case "$op" in
            ship)
                _recover_ship "$args" "$pending_action" "$auto_mode"
                ;;
            sync)
                _recover_sync "$args" "$pending_action" "$auto_mode"
                ;;
            delete)
                _recover_delete "$args" "$pending_action" "$auto_mode"
                ;;
            *)
                echo -e "${YELLOW}Unknown operation type: $op${NC}" >&2
                echo "  Journal entry preserved. Manual recovery may be needed." >&2
                return 1
                ;;
        esac

        # Mark recovered op as complete so journal_clean can remove it
        _WV_CURRENT_OP_ID="$op_id"
        _WV_CURRENT_OP_TYPE="$op"
        journal_end

        # Clean completed ops from journal
        journal_clean
        return 0
    fi

    # === ship_pending fallback (reboot recovery) ===
    if [ -n "$pending_nodes" ]; then
        if [ "$json_mode" = true ]; then
            echo "{\"status\":\"ship_pending\",\"nodes\":$(echo "$pending_nodes" | jq -R -s 'split("\n") | map(select(length > 0) | split("|") | {id: .[0], text: .[1]})')}"
            return 0
        fi

        echo -e "${YELLOW}⚠ Found node(s) with ship_pending marker (likely interrupted by reboot)${NC}"
        echo "$pending_nodes" | while IFS='|' read -r node_id node_text _; do
            [ -z "$node_id" ] && continue
            echo "  $node_id: $node_text"
        done
        echo ""

        if [ "$auto_mode" = true ]; then
            echo -e "${CYAN}ℹ${NC} Auto-recovering: running sync for pending nodes"
        else
            echo -n "  Resume shipping these nodes? [Y/n] "
            read -r answer
            if [ "$answer" = "n" ] || [ "$answer" = "N" ]; then
                echo "  Skipped. Clear markers with: wv update <id> --metadata='{\"ship_pending\":null}'"
                return 0
            fi
        fi

        # Recovery: sync local graph state (node is already done, just need to persist)
        local _recover_prev_skip_sync_commit="${_WV_SKIP_SYNC_COMMIT:-}"
        export _WV_SKIP_SYNC_COMMIT=1
        cmd_sync 2>/dev/null || true
        if [ -n "$_recover_prev_skip_sync_commit" ]; then
            export _WV_SKIP_SYNC_COMMIT="$_recover_prev_skip_sync_commit"
        else
            unset _WV_SKIP_SYNC_COMMIT
        fi

        # Clear ship_pending markers
        echo "$pending_nodes" | while IFS='|' read -r node_id _ _; do
            [ -z "$node_id" ] && continue
            db_query "UPDATE nodes SET metadata = json_remove(metadata, '$.ship_pending') WHERE id = '$node_id';" 2>/dev/null || true
        done
        echo -e "${GREEN}✓${NC} Recovery complete"
    fi

    # === pending_close fallback (human verification required) ===
    if [ -n "$pending_close_nodes" ]; then
        if [ "$json_mode" = true ]; then
            local pending_close_json
            pending_close_json=$(echo "$pending_close_nodes" | jq -R -s '
                split("\n") |
                map(select(length > 0) | split("|") | {
                    id: .[0],
                    text: .[1],
                    reason: .[2],
                    resume_command: .[3]
                })')
            echo "{\"status\":\"needs_human_verification\",\"nodes\":$pending_close_json}"
            return 0
        fi

        echo -e "${YELLOW}⚠ Node(s) waiting for human verification before close${NC}"
        echo "$pending_close_nodes" | while IFS='|' read -r node_id node_text pending_reason resume_cmd; do
            [ -z "$node_id" ] && continue
            echo "  $node_id: $node_text"
            echo "    Reason: $pending_reason"
            if [ -n "$resume_cmd" ]; then
                echo "    Resume: $resume_cmd"
            fi
        done
        if [ "$auto_mode" = true ]; then
            echo -e "${CYAN}ℹ${NC} Leaving pending-close state for explicit human approval"
        fi
        return 0
    fi

    # === source-4 git-state fallback (explicit surfaces only) ===
    if [ "$git_sync_pending" = true ]; then
        if [ "$json_mode" = true ]; then
            if [ "$git_sync_state" = "recoverable" ]; then
                echo "$git_pending_json" | jq '. + {status:"git_pending"}'
            else
                echo "$git_pending_json" | jq '. + {status:"git_unresolvable"}'
            fi
            return 0
        fi

        echo -e "${YELLOW}⚠ Git-state pending detected${NC}"
        echo "  State: $git_sync_state"
        if [ "$git_sync_action" != "none" ]; then
            echo "  Action: $git_sync_action"
        fi
        echo "  Reason: $git_sync_reason"
        echo "  Hint: $git_sync_hint"
        return 0
    fi
}

# Recovery helpers for specific operation types

_recover_ship() {
    local args="$1"
    local stuck_action="$2"
    local auto="$3"
    local id
    id=$(echo "$args" | jq -r '.id // empty')

    case "$stuck_action" in
        done)
            echo "  Recovery: re-run cmd_done + sync"
            if [ "$auto" != true ]; then
                echo -n "  Proceed? [Y/n] "
                read -r answer
                [ "$answer" = "n" ] || [ "$answer" = "N" ] && return 0
            fi
            cmd_done "$id" --no-warn 2>/dev/null || true
            local _recover_prev_skip_sync_commit="${_WV_SKIP_SYNC_COMMIT:-}"
            export _WV_SKIP_SYNC_COMMIT=1
            cmd_sync 2>/dev/null || true
            if [ -n "$_recover_prev_skip_sync_commit" ]; then
                export _WV_SKIP_SYNC_COMMIT="$_recover_prev_skip_sync_commit"
            else
                unset _WV_SKIP_SYNC_COMMIT
            fi
            ;;
        sync)
            echo "  Recovery: re-run sync"
            if [ "$auto" != true ]; then
                echo -n "  Proceed? [Y/n] "
                read -r answer
                [ "$answer" = "n" ] || [ "$answer" = "N" ] && return 0
            fi
            local _recover_prev_skip_sync_commit="${_WV_SKIP_SYNC_COMMIT:-}"
            export _WV_SKIP_SYNC_COMMIT=1
            cmd_sync 2>/dev/null || true
            if [ -n "$_recover_prev_skip_sync_commit" ]; then
                export _WV_SKIP_SYNC_COMMIT="$_recover_prev_skip_sync_commit"
            else
                unset _WV_SKIP_SYNC_COMMIT
            fi
            ;;
        git_commit)
            echo "  Recovery: legacy push-complete ship detected; local graph is already synced"
            if [ "$auto" != true ]; then
                echo -n "  Proceed? [Y/n] "
                read -r answer
                [ "$answer" = "n" ] || [ "$answer" = "N" ] && return 0
            fi
            local git_pending_json git_sync_hint
            git_pending_json=$(_detect_git_pending 2>/dev/null || echo '{}')
            git_sync_hint=$(echo "$git_pending_json" | jq -r '.hint // "no action required"' 2>/dev/null || echo "no action required")
            echo "  Hint: $git_sync_hint"
            ;;
        git_push)
            echo "  Recovery: legacy push-complete ship detected; local graph is already synced"
            if [ "$auto" != true ]; then
                echo -n "  Proceed? [Y/n] "
                read -r answer
                [ "$answer" = "n" ] || [ "$answer" = "N" ] && return 0
            fi
            local git_pending_json git_sync_hint
            git_pending_json=$(_detect_git_pending 2>/dev/null || echo '{}')
            git_sync_hint=$(echo "$git_pending_json" | jq -r '.hint // "no action required"' 2>/dev/null || echo "no action required")
            echo "  Hint: $git_sync_hint"
            ;;
    esac

    # Clear ship_pending if present
    [ -n "$id" ] && db_query "UPDATE nodes SET metadata = json_remove(metadata, '$.ship_pending') WHERE id = '$id';" 2>/dev/null || true
    echo -e "${GREEN}✓${NC} Recovery complete"
}

_recover_sync() {
    local args="$1"
    local stuck_action="$2"
    local auto="$3"

    case "$stuck_action" in
        dump)
            echo "  Recovery: re-run sync in --mode=repair (resumable from last checkpoint)"
            ;;
        gh_sync)
            echo "  Recovery: re-run GH sync + commit (uses --mode=repair to resume from last checkpoint)"
            ;;
        git_commit)
            echo "  Recovery: re-run git commit"
            ;;
    esac

    if [ "$auto" != true ]; then
        echo -n "  Proceed? [Y/n] "
        read -r answer
        [ "$answer" = "n" ] || [ "$answer" = "N" ] && return 0
    fi

    local gh_flag
    gh_flag=$(echo "$args" | jq -r '.gh // false')
    if [ "$gh_flag" = "true" ]; then
        # Phase D: prefer --mode=repair so an interrupted sync resumes from
        # its checkpoint instead of redoing the entire walk.
        cmd_sync --gh --mode=repair 2>/dev/null || true
    else
        cmd_sync 2>/dev/null || true
    fi
    echo -e "${GREEN}✓${NC} Recovery complete"
}

_recover_delete() {
    local args="$1"
    local stuck_action="$2"
    local auto="$3"
    local gh_issue
    gh_issue=$(echo "$args" | jq -r '.gh_issue // empty')

    if [ "$stuck_action" = "gh_close" ] && [ -n "$gh_issue" ]; then
        echo "  Recovery: close GitHub issue #$gh_issue"
        if [ "$auto" != true ]; then
            echo -n "  Proceed? [Y/n] "
            read -r answer
            [ "$answer" = "n" ] || [ "$answer" = "N" ] && return 0
        fi
        if command -v gh >/dev/null 2>&1; then
            local repo
            repo=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")
            if [ -n "$repo" ]; then
                gh issue close "$gh_issue" --repo "$repo" 2>/dev/null && \
                    echo -e "${GREEN}✓${NC} Closed GitHub issue #$gh_issue" >&2 || \
                    echo -e "${YELLOW}Warning: Could not close issue${NC}" >&2
            fi
        fi
    else
        echo "  SQLite delete already completed. No further recovery needed."
    fi
    echo -e "${GREEN}✓${NC} Recovery complete"
}

# _recover_session — List/reclaim orphaned active nodes from crashed sessions
_recover_session() {
    local json_mode="$1"
    local auto_mode="$2"

    # Get all active nodes
    local active_nodes
    active_nodes=$(db_query "SELECT id, text FROM nodes WHERE status='active' ORDER BY id;" 2>/dev/null || true)

    local active_count=0
    if [ -n "$active_nodes" ]; then
        active_count=$(echo "$active_nodes" | wc -l)
    fi

    if [ "$active_count" -eq 0 ]; then
        if [ "$json_mode" = true ]; then
            echo '{"status":"clean","orphaned_nodes":[],"message":"No orphaned active nodes"}'
        else
            echo -e "${GREEN}✓${NC} No orphaned active nodes found"
        fi
        return 0
    fi

    if [ "$json_mode" = true ]; then
        local json_nodes="[]"
        json_nodes=$(echo "$active_nodes" | while IFS='|' read -r node_id node_text; do
            [ -z "$node_id" ] && continue
            jq -n --arg id "$node_id" --arg text "$node_text" '{id: $id, text: $text}'
        done | jq -s '.')
        jq -n --argjson nodes "$json_nodes" --argjson count "$active_count" \
            '{status: "orphaned", orphaned_nodes: $nodes, count: $count}'
        return 0
    fi

    echo -e "${YELLOW}⚠ ${active_count} node(s) marked active (possibly orphaned from a crashed session):${NC}"
    echo "$active_nodes" | while IFS='|' read -r node_id node_text; do
        [ -z "$node_id" ] && continue
        echo "  $node_id: $node_text"
    done
    echo ""

    if [ "$auto_mode" = true ]; then
        echo -e "${CYAN}ℹ${NC} Auto-reclaiming all active nodes for this session"
        echo "$active_nodes" | while IFS='|' read -r node_id _; do
            [ -z "$node_id" ] && continue
            # Nodes are already active — just confirm
            echo -e "  ${GREEN}✓${NC} $node_id — already active"
        done
        return 0
    fi

    echo "  Options:"
    echo "    wv work <id>           — Re-claim specific node"
    echo "    wv done <id>           — Close if work was complete at crash"
    echo "    wv update <id> --status=todo — Release back to ready queue"
    return 0
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
    local warnings=()

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
        if [ "$c_unimported" -gt 0 ]; then
            warnings+=("$c_unimported/$c_total Claude memory file(s) — import: wv memory import --source=claude --path=$memdir")
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
        if [ "$cdx_rep" -lt "$cdx_rows" ]; then
            warnings+=("$((cdx_rows - cdx_rep))/$cdx_rows Codex memory-pipeline row(s) — import: wv memory import --source=codex")
        fi
    fi

    if [ "$any_store" -eq 0 ]; then
        _doctor_record "memory authority" "pass" "no harness memory store for this repo"
    elif [ "${#warnings[@]}" -gt 0 ]; then
        local msg
        msg=$(printf '%s; ' "${warnings[@]}")
        msg="${msg%; }"
        _doctor_record "memory authority" "warn" "dual authority risk: $msg"
    else
        _doctor_record "memory authority" "pass" "harness memory all represented in graph"
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
        _dr_results="${_dr_results:+$_dr_results,}$(printf '{"check":"%s","status":"%s","detail":"%s"}' "$name" "$status" "$detail")"
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

# _doctor_check_modules — Check a directory for expected module files
_doctor_check_modules() {
    local label="$1" dir="$2" expected="$3"
    local found=0 missing=""
    for mod in $expected; do
        if [ -f "$dir/$mod" ]; then
            found=$((found + 1))
        else
            missing="${missing:+$missing, }$mod"
        fi
    done
    local total_expected
    total_expected=$(echo "$expected" | wc -w | tr -d ' ')
    if [ "$found" -eq "$total_expected" ]; then
        _doctor_record "$label" "pass" "$found/$total_expected"
    else
        _doctor_record "$label" "fail" "$found/$total_expected (missing: $missing)"
    fi
}

_doctor_agent_python_exec() {
    local python_command="$1"
    shift

    case "$python_command" in
        "poetry run python")
            PYTHONPATH="${WV_LIB_DIR:-}" poetry run python "$@"
            ;;
        "")
            return 127
            ;;
        *)
            PYTHONPATH="${WV_LIB_DIR:-}" "$python_command" "$@"
            ;;
    esac
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
    case "$python_command" in
        "poetry run python")
            if command -v poetry >/dev/null 2>&1; then
                _doctor_record "agent python" "pass" "$python_detail"
            else
                _doctor_record "agent python" "fail" "poetry required for agent python command but not found"
            fi
            ;;
        *)
            if [ -x "$python_command" ]; then
                _doctor_record "agent python" "pass" "$python_detail"
            else
                _doctor_record "agent python" "fail" "$python_detail not executable"
            fi
            ;;
    esac

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
    printf '%s\n' "$mcp_list" | grep -q '^weave-lite[[:space:]]' && has_lite=true
    printf '%s\n' "$mcp_list" | grep -q '^weave-inspect[[:space:]]' && has_inspect=true
    printf '%s\n' "$mcp_list" | grep -q '^weave[[:space:]]' && has_full=true

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
    for ev in SessionStart PreToolUse PostToolUse Stop; do
        jq -e --arg ev "$ev" '(.hooks[$ev] // []) | length > 0' "$hooks_file" >/dev/null 2>&1 || missing="${missing:+$missing, }$ev"
    done
    if [ -n "$missing" ]; then
        _doctor_record "codex hooks" "warn" ".codex/hooks.json is stale, missing event(s): $missing -- regenerate with wv init-repo --agent=codex --codex-hooks --force"
        return
    fi

    _doctor_record "codex hooks" "warn" ".codex/hooks.json covers SessionStart/PreToolUse/PostToolUse/Stop -- pending trust; review and trust with /hooks in Codex before it enforces"
}

cmd_hotzone() {
    local subcmd="${1:-}"
    shift || true

    case "$subcmd" in
        gc)
            local dry_run=false
            while [ $# -gt 0 ]; do
                case "$1" in
                    --dry-run) dry_run=true ;;
                esac
                shift
            done

            local hot_zone hz_parent removed=0 skipped=0
            hot_zone=$(resolve_repo_hot_zone)
            hz_parent=$(dirname "$hot_zone")

            if [ ! -d "$hz_parent" ]; then
                echo "Hot-zone parent $hz_parent not found — nothing to gc."
                return 0
            fi

            local now
            now=$(date +%s)
            local d eligible=0
            for d in "$hz_parent"/*/; do
                [ -f "${d}brain.db" ] || continue
                local canon_d
                canon_d=$(canonicalize_runtime_path "${d%/}")
                local canon_hot
                canon_hot=$(canonicalize_runtime_path "$hot_zone")
                [ "$canon_d" = "$canon_hot" ] && continue

                # Orphan: no owner file, or owner dir no longer exists
                local owner=""
                owner=$(cat "${d}.repo_root" 2>/dev/null || echo "")
                local is_orphan=false
                if [ -z "$owner" ]; then
                    is_orphan=true
                elif [ ! -d "$owner" ]; then
                    is_orphan=true
                fi
                "$is_orphan" || continue

                # Age guard: skip dirs with recent writes (< 1 hour) — may be active test
                local mtime
                mtime=$(stat -c%Y "${d}brain.db" 2>/dev/null || stat -f%m "${d}brain.db" 2>/dev/null || echo 0)
                local age=$(( now - mtime ))
                if [ "$age" -lt 3600 ]; then
                    skipped=$((skipped + 1))
                    continue
                fi

                eligible=$((eligible + 1))
                if [ "$dry_run" = true ]; then
                    echo "  would remove: ${d} (owner=${owner:-none}, age=${age}s)"
                else
                    rm -rf "$d" 2>/dev/null && removed=$((removed + 1)) || true
                fi
            done

            if [ "$dry_run" = true ]; then
                echo "wv hotzone gc --dry-run: $eligible eligible orphan(s); $skipped skipped (< 1h old) under $hz_parent"
            else
                echo "wv hotzone gc: removed $removed orphan(s), skipped $skipped (< 1h old) under $hz_parent"
            fi
            if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
                echo "note: not inside a git repo — the hot-zone parent resolves repo-relatively; cd into a repo to gc its family" >&2
            fi
            ;;
        list)
            local as_json=false
            while [ $# -gt 0 ]; do
                case "$1" in
                    --json) as_json=true ;;
                esac
                shift
            done
            local hot_zone hz_parent
            hot_zone=$(resolve_repo_hot_zone)
            hz_parent=$(dirname "$hot_zone")
            if [ ! -d "$hz_parent" ]; then
                if [ "$as_json" = true ]; then echo "[]"; else echo "Hot-zone parent $hz_parent not found."; fi
                return 0
            fi
            local d json_rows="" row_count=0
            for d in "$hz_parent"/*/; do
                [ -f "${d}brain.db" ] || continue
                row_count=$((row_count + 1))
                local owner=""
                owner=$(cat "${d}.repo_root" 2>/dev/null || echo "")
                local nodes=0
                nodes=$(sqlite3 "${d}brain.db" "SELECT COUNT(*) FROM nodes;" 2>/dev/null || echo "?")
                local label="live"
                if [ -z "$owner" ] || [ ! -d "$owner" ]; then
                    label="orphan"
                fi
                if [ "$as_json" = true ]; then
                    local row
                    # 'label' is a jq reserved word: jq 1.6 (dev machine apt)
                    # rejects both the bare key {label: ...} AND the variable
                    # $label; 1.7 tolerates them. Quote the key, avoid the name.
                    row=$(jq -n --arg lbl "$label" --arg path "${d%/}" --arg nodes "$nodes" --arg owner "${owner:-}" \
                        '{"label": $lbl, "path": $path, "nodes": (($nodes|tonumber?) // null), "owner": (if $owner == "" then null else $owner end)}')
                    json_rows="${json_rows:+$json_rows,}$row"
                else
                    printf '  %-10s  %s  nodes=%-4s  owner=%s\n' "$label" "${d%/}" "$nodes" "${owner:-none}"
                fi
            done
            if [ "$as_json" = true ]; then
                echo "[${json_rows}]"
            elif [ "$row_count" -eq 0 ]; then
                # Silence here looked like a defect during the v1.58 review —
                # always name the scanned parent so empty output is diagnosable.
                echo "(no hot-zone dirs under $hz_parent)" >&2
            fi
            if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
                echo "note: not inside a git repo — the hot-zone parent resolves repo-relatively; cd into a repo to see its family" >&2
            fi
            ;;
        db|--db)
            # Print the resolved brain.db path so agents/scripts never hand-roll
            # /dev/shm vs /tmp/weave-codex paths in raw sqlite3 (finding wv-f752a5:
            # a guessed path errors and — in a parallel tool batch — cancels its
            # siblings). Use: DB=$(wv hotzone --db); sqlite3 "$DB" "..."
            local hot_zone
            hot_zone=$(resolve_repo_hot_zone)
            echo "${WV_DB:-$hot_zone/brain.db}"
            ;;
        *)
            echo "Usage: wv hotzone <subcommand>"
            echo ""
            echo "Subcommands:"
            echo "  gc [--dry-run]   Remove orphan hot-zone dirs (no .repo_root or dead owner)"
            echo "  list             Show all hot-zone dirs with owner + node count"
            echo "  db               Print the resolved brain.db path (for raw sqlite3)"
            ;;
    esac
}

# _test_file_fingerprint <path> — content fingerprint of a SINGLE file for the
# test_results ledger. git blob hash (pure function of content; identical whether
# computed by the producer here or the consumer in _done_refresh_test_status),
# with an mtime:size fallback for untracked files or when git is unavailable.
# This is the single fingerprint definition both sides share — there is no
# combined-over-a-set key for either side to reconstruct.
_test_file_fingerprint() {
    local f="$1" h
    h=$(git hash-object "$f" 2>/dev/null)
    [ -z "$h" ] && h=$(stat -c '%Y:%s' "$f" 2>/dev/null || echo "missing")
    printf '%s' "$h"
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_config — front door for the two durable opt-in seams (finding wv-e754b0)
# ═══════════════════════════════════════════════════════════════════════════
# Users should never have to memorise an env-var name or a config-file path:
#   - Global knobs (WV_CALL_LOG, ...) -> $WV_CONFIG_DIR/config.env, sourced by
#     wv-config.sh on EVERY CLI + hook invocation (survives reboot; no env
#     inheritance dependency — resolves the session-analysis split-brain).
#   - Repo gate policy (test_gate) -> $WEAVE_DIR/quality.conf [thresholds],
#     loaded into the tmpfs policy_thresholds table by _load_quality_config.
#     A raw sqlite3 UPDATE is session-only (tmpfs, not in state.sql); the
#     [thresholds] section is the ONLY durable path.

_config_env_file() { echo "${WV_CONFIG_DIR:-$HOME/.config/weave}/config.env"; }

# _config_env_set KEY VALUE — upsert KEY="VALUE" in config.env (deduped, quoted).
_config_env_set() {
    local key="$1" val="$2" file tmp
    if ! [[ "$key" =~ ^WV_[A-Z0-9_]+$ ]]; then
        echo "wv config: invalid key '$key' (expected WV_[A-Z0-9_]+)" >&2
        return 1
    fi
    file=$(_config_env_file)
    if ! mkdir -p "$(dirname "$file")"; then
        echo "wv config: cannot create config directory $(dirname "$file")" >&2
        return 1
    fi
    if ! tmp=$(mktemp); then
        echo "wv config: cannot create temporary config file" >&2
        return 1
    fi
    {
        echo "# Weave global knobs — sourced by wv on every invocation (CLI + hooks)."
        echo "# Managed by 'wv config set/enable'."
    } > "$tmp" || { echo "wv config: cannot write temporary config file" >&2; rm -f "$tmp"; return 1; }
    # Carry forward existing assignments except the key being set (and drop old comments).
    if [ -f "$file" ]; then
        grep -vE '^[[:space:]]*#' "$file" 2>/dev/null | grep -vE "^[[:space:]]*${key}=" >> "$tmp" || true
    fi
    echo "${key}=\"${val}\"" >> "$tmp" || { echo "wv config: cannot write temporary config file" >&2; rm -f "$tmp"; return 1; }
    if ! mv "$tmp" "$file"; then
        echo "wv config: cannot update $file" >&2
        rm -f "$tmp"
        return 1
    fi
    return 0
}

# _config_env_unset KEY — remove a KEY assignment from config.env.
_config_env_unset() {
    local key="$1" file tmp
    file=$(_config_env_file)
    [ -f "$file" ] || return 0
    if ! tmp=$(mktemp); then
        echo "wv config: cannot create temporary config file" >&2
        return 1
    fi
    grep -vE "^[[:space:]]*${key}=" "$file" > "$tmp" 2>/dev/null || true
    if ! mv "$tmp" "$file"; then
        echo "wv config: cannot update $file" >&2
        rm -f "$tmp"
        return 1
    fi
    return 0
}

# _config_set_threshold KEY VALUE — upsert KEY = VALUE under [thresholds] in
# the repo's quality.conf (creates the section/file as needed). Durable seam.
_config_set_threshold() {
    local key="$1" val="$2" file="${WEAVE_DIR:-}/quality.conf"
    if [ -z "${WEAVE_DIR:-}" ]; then
        echo "wv config: not inside a Weave repo (no .weave dir) — gate policy is repo-scoped" >&2
        return 1
    fi
    mkdir -p "$WEAVE_DIR"
    python3 - "$file" "$key" "$val" <<'PY'
import os, re, sys
path, key, val = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path, encoding="utf-8").read().splitlines() if os.path.exists(path) else []
out, in_thr, seen_thr, done = [], False, False, False
for line in lines:
    m = re.match(r'^\[([a-z_]+)\]', line.strip())
    if m:
        if in_thr and not done:
            out.append(f"{key} = {val}"); done = True
        in_thr = (m.group(1) == "thresholds")
        seen_thr = seen_thr or in_thr
        out.append(line); continue
    if in_thr and re.match(rf'^\s*{re.escape(key)}\s*=', line):
        if not done:
            out.append(f"{key} = {val}"); done = True
        continue
    out.append(line)
if in_thr and not done:
    out.append(f"{key} = {val}"); done = True
if not seen_thr:
    if out and out[-1].strip():
        out.append("")
    out += ["[thresholds]", f"{key} = {val}"]
open(path, "w", encoding="utf-8").write("\n".join(out) + "\n")
PY
}

_config_enable_session_analysis() {
    local path="${WV_CALL_LOG_DEFAULT:-$HOME/.local/share/weave/wv_calls.jsonl}"
    mkdir -p "$(dirname "$path")"
    _config_env_set WV_CALL_LOG "$path" || return 1
    echo -e "${GREEN}✓${NC} session-analysis enabled"
    echo "  call log: $path"
    echo "  config:   $(_config_env_file)"
    echo "  Takes effect next wv invocation (CLI + hooks). Read: wv analyze sessions --call-stats"
    return 0
}

# _scaffold_test_map — write a commented starter .weave/test-map.conf when absent.
# Detects the repo stack (Python/Rust/Node/shell) and emits language-specific
# examples. No-op if test-map.conf already exists. Never auto-enforced — the user
# must edit and uncomment entries before the gate classifies any file.
_scaffold_test_map() {
    local tmap="${WEAVE_DIR}/test-map.conf"
    [ -f "$tmap" ] && return 0

    local repo_root; repo_root=$(dirname "$WEAVE_DIR")
    # Header common to all stacks
    local body
    body='# .weave/test-map.conf — source file to test suite mapping
# Format ([map] section, INI-style):
#   source_file = suite [suite ...]
# source_file: path relative to repo root. Three key forms (most specific wins):
#   exact      src/app/models.py = suite      single file
#   glob       src/**/*.py       = suite      shell glob (matches files in subdirs)
#   prefix     src/              = suite       any file under a directory (trailing /)
# suite:       path to a runnable shell script relative to repo root
#
# A `* = suite` line, or suites listed under a [default] section, run when no
# other key matches a file — so the gate fails *safe* (runs a broad suite)
# instead of *open* (runs nothing). Per-file precedence:
#   exact > glob/prefix > naming heuristic > [default].
# A file matching nothing (and no [default]) makes the pre-commit gate inert
# for it and now prints a one-line notice rather than passing silently.
#
# Uncomment and adapt the entries below.

[map]
'
    local added=0

    if [ -f "$repo_root/pyproject.toml" ] || [ -f "$repo_root/setup.cfg" ] || [ -f "$repo_root/setup.py" ]; then
        added=1
        body+='# Python (pyproject.toml / setup.cfg detected)
# Create a wrapper that sets up the env and runs pytest, e.g. scripts/run-tests.sh:
#   #!/usr/bin/env bash
#   set -e; cd "$(git rev-parse --show-toplevel)" && poetry run pytest tests
# Then map the whole source tree with one prefix (or glob) line:
# src/         = scripts/run-tests.sh
# src/**/*.py  = scripts/run-tests.sh
# Or set a fail-safe default for anything unmapped:
# *            = scripts/run-tests.sh

'
    fi

    if [ -f "$repo_root/Cargo.toml" ]; then
        added=1
        body+='# Rust (Cargo.toml detected)
# Create a wrapper, e.g. scripts/run-tests.sh:
#   #!/usr/bin/env bash
#   set -e; cd "$(git rev-parse --show-toplevel)" && cargo test
# Then map source files:
# src/lib.rs   = scripts/run-tests.sh
# src/main.rs  = scripts/run-tests.sh

'
    fi

    if [ -f "$repo_root/package.json" ]; then
        added=1
        body+='# Node.js (package.json detected)
# Create a wrapper, e.g. scripts/run-tests.sh:
#   #!/usr/bin/env bash
#   set -e; cd "$(git rev-parse --show-toplevel)" && npm test
# Then map source files:
# src/index.js = scripts/run-tests.sh
# src/app.ts   = scripts/run-tests.sh

'
    fi

    if [ -f "$repo_root/Makefile" ]; then
        added=1
        if grep -qE '^test[[:space:]]*:' "$repo_root/Makefile" 2>/dev/null; then
            body+='# Shell / Makefile (test target detected)
# Map each source script to its test counterpart:
# scripts/my-cmd.sh = tests/test-my-cmd.sh

'
        else
            body+='# Makefile detected — map shell scripts to their test files:
# scripts/my-cmd.sh = tests/test-my-cmd.sh

'
        fi
    fi

    if [ "$added" = "0" ]; then
        body+='# Example: map a source file to its test script
# scripts/my-command.sh = tests/test-my-command.sh

'
    fi

    printf '%s' "$body" > "$tmap"
    echo -e "  ${GREEN}✓${NC} scaffolded ${WEAVE_DIR}/test-map.conf — edit to match your project layout"
    echo "     see: wv guide --topic=verification"
}

_config_enable_test_gate() {
    local mode_val=1 label="warn"
    case "${1:-warn}" in
        warn|1)        mode_val=1; label="warn (advisory)" ;;
        block|2|--block) mode_val=2; label="block (hard)" ;;
        off|0)         mode_val=0; label="off" ;;
        *) echo "wv config: test-gate mode must be warn|block|off" >&2; return 1 ;;
    esac
    _config_set_threshold test_gate "$mode_val" || return 1
    _load_quality_config 2>/dev/null || true
    echo -e "${GREEN}✓${NC} verification gate set to ${label} (test_gate=${mode_val})"
    echo "  durable in: ${WEAVE_DIR}/quality.conf [thresholds]  (commit it to share the policy)"
    if [ "$mode_val" != "0" ]; then
        _scaffold_test_map
    fi
    return 0
}

# _config_key_source KEY — print the file that provides the effective value for KEY,
# or "(builtin default)" if not set in any layer. Checks config.env (global knobs)
# then quality.conf [thresholds] (repo gate). Used by --show-origin.
_config_key_source() {
    local key="$1"
    local env_file; env_file=$(_config_env_file)
    if grep -qE "^[[:space:]]*${key}=" "$env_file" 2>/dev/null; then
        echo "$env_file"; return 0
    fi
    if [ -n "${WEAVE_DIR:-}" ] && grep -qE "^[[:space:]]*${key}[[:space:]]*=" "${WEAVE_DIR}/quality.conf" 2>/dev/null; then
        echo "${WEAVE_DIR}/quality.conf"; return 0
    fi
    echo "builtin default"
}

_config_list() {
    local show_origin=0
    [ "${1:-}" = "--show-origin" ] && show_origin=1
    local file; file=$(_config_env_file)
    echo "Global knobs ($file):"
    if [ -f "$file" ] && grep -qvE '^[[:space:]]*(#|$)' "$file" 2>/dev/null; then
        if [ "$show_origin" = "1" ]; then
            grep -vE '^[[:space:]]*(#|$)' "$file" | sed "s|^|  |;s|\$|    ($file)|"
        else
            grep -vE '^[[:space:]]*(#|$)' "$file" | sed 's/^/  /'
        fi
    else
        echo "  (none set)"
    fi
    echo ""
    local origin_env=""; [ "$show_origin" = "1" ] && origin_env="    ($file)"
    if [ -n "${WV_CALL_LOG:-}" ]; then
        echo -e "session-analysis: ${GREEN}enabled${NC} -> ${WV_CALL_LOG}${origin_env}"
    else
        echo "session-analysis: disabled  (enable: wv config enable session-analysis)"
    fi
    local _suite_log="${WV_SUITE_LOG:-${WV_SUITE_LOG_DEFAULT:-$HOME/.local/share/weave/suite_runs.jsonl}}"
    local suite_src=""; [ "$show_origin" = "1" ] && { [ -n "${WV_SUITE_LOG:-}" ] && suite_src="    ($file)" || suite_src="    (builtin default)"; }
    if [ -n "${WV_SUITE_LOG:-}" ]; then
        echo -e "suite-history:    ${GREEN}always on${NC} -> ${_suite_log} (custom: WV_SUITE_LOG)${suite_src}"
    else
        echo "suite-history:    always on -> ${_suite_log}  (override: wv config set WV_SUITE_LOG <path>)${suite_src}"
    fi
    if [ -n "${WEAVE_DIR:-}" ]; then
        local tg quality_file="${WEAVE_DIR}/quality.conf"
        tg=$(sqlite3 "$WV_DB" "SELECT value FROM policy_thresholds WHERE key='test_gate';" 2>/dev/null)
        local gate_src=""
        if [ "$show_origin" = "1" ]; then
            if grep -qE '^[[:space:]]*test_gate[[:space:]]*=' "$quality_file" 2>/dev/null; then
                gate_src="    ($quality_file)"
            else
                gate_src="    (builtin default)"
            fi
        fi
        echo "verification-gate: test_gate=${tg:-?} (0=off 1=warn 2=block) [repo: $WEAVE_DIR]${gate_src}"
        if [ "$show_origin" = "0" ]; then
            if grep -qE '^[[:space:]]*test_gate[[:space:]]*=' "$quality_file" 2>/dev/null; then
                echo "                   durable (set in .weave/quality.conf [thresholds])"
            elif [ "${tg:-0}" != "0" ]; then
                echo -e "                   ${YELLOW}session-only${NC} — not in quality.conf; resets on reboot"
            fi
        fi
    fi
    return 0
}

_config_help() {
    cat <<'EOF'
Usage: wv config <subcommand>

  list [--show-origin]         Show current global knobs + feature state
  get <KEY> [--show-origin]    Print the effective value of a knob (and its source layer)
  set <KEY> <VALUE>            Set a global knob (WV_*) in config.env
  unset <KEY>                  Remove a global knob from config.env
  enable session-analysis      Turn on wv call logging (durable, CLI + hooks)
  disable session-analysis     Turn it off
  enable test-gate [warn|block] Make the verification gate durable in quality.conf
  disable test-gate            Set test_gate=0 (durable)

Global knobs live in ~/.config/weave/config.env (override dir: WV_CONFIG_DIR).
The verification gate is repo-scoped (.weave/quality.conf [thresholds]).
--show-origin annotates each value with the config file that provides it.
EOF
    return 0
}

cmd_config() {
    local sub="${1:-list}"
    shift || true
    case "$sub" in
        list|show) _config_list "${1:-}" ;;
        get)
            if [ -z "${1:-}" ]; then echo "wv config get: need a KEY" >&2; return 1; fi
            local _gkey="$1"
            if [ "${2:-}" = "--show-origin" ]; then
                local _src; _src=$(_config_key_source "$_gkey")
                echo "${!_gkey:-}    ($_src)"
            else
                echo "${!_gkey:-}"
            fi ;;
        set)
            if [ -z "${1:-}" ] || [ -z "${2:-}" ]; then echo "wv config set: need KEY VALUE" >&2; return 1; fi
            if _config_env_set "$1" "$2"; then echo -e "${GREEN}✓${NC} set $1 (effective next invocation)"; fi ;;
        unset)
            if [ -z "${1:-}" ]; then echo "wv config unset: need a KEY" >&2; return 1; fi
            _config_env_unset "$1"; echo -e "${GREEN}✓${NC} unset $1" ;;
        enable)
            case "${1:-}" in
                session-analysis) _config_enable_session_analysis ;;
                test-gate)        shift || true; _config_enable_test_gate "${1:-warn}" ;;
                *) echo "wv config enable: unknown feature '${1:-}' (session-analysis|test-gate)" >&2; return 1 ;;
            esac ;;
        disable)
            case "${1:-}" in
                session-analysis) _config_env_unset WV_CALL_LOG && echo -e "${GREEN}✓${NC} session-analysis disabled" ;;
                test-gate)        _config_enable_test_gate off ;;
                *) echo "wv config disable: unknown feature '${1:-}' (session-analysis|test-gate)" >&2; return 1 ;;
            esac ;;
        help|--help|-h) _config_help ;;
        *) echo "wv config: unknown subcommand '$sub'" >&2; _config_help >&2; return 1 ;;
    esac
}

# ── durable suite-run history (LL2) ─────────────────────────────────────────
# The tmpfs test_results table is current-state-only and wiped by `wv load`. This
# append-only JSONL log lives on disk so suite-run history (for measuring
# commit-time friction) survives wv load + reboot. The path is overridable via
# `wv config set WV_SUITE_LOG <path>`; default under the user data dir.
_suite_log_path() {
    echo "${WV_SUITE_LOG:-${WV_SUITE_LOG_DEFAULT:-$HOME/.local/share/weave/suite_runs.jsonl}}"
}

# _suite_log_append <suite> <files_csv> <exit> <duration_ms> <sha>
# One JSONL line per suite RUN (not per file). Best-effort: a logging failure must
# never break a commit hook. jq -cn guarantees valid JSON + escaping, so a path
# containing a quote can neither corrupt the log nor inject a field. Records only
# repo-relative paths + outcome metadata — never file content, env, or secrets —
# and `repo` is a basename so no absolute $HOME/username path leaks (no PII).
_suite_log_append() {
    local suite="$1" files="$2" exit_code="$3" duration_ms="$4" sha="$5"
    local log_path; log_path=$(_suite_log_path)
    [ -n "$log_path" ] || return 0
    mkdir -p "$(dirname "$log_path")" 2>/dev/null || return 0
    # exit_code/duration_ms are pre-coerced to digits by the caller; default-guard
    # anyway so a stray value can never make --argjson abort the whole line.
    case "$exit_code" in ''|*[!0-9]*) exit_code=0 ;; esac
    case "$duration_ms" in ''|*[!0-9]*) duration_ms=0 ;; esac
    local repo=""
    [ -n "${REPO_ROOT:-}" ] && repo=$(basename "$REPO_ROOT")
    jq -cn \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg repo "$repo" \
        --arg suite "$suite" \
        --arg files "$files" \
        --argjson exit "$exit_code" \
        --argjson duration_ms "$duration_ms" \
        --arg sha "$sha" \
        '{ts:$ts, repo:$repo, suite:$suite, files:$files, exit:$exit, duration_ms:$duration_ms, sha:$sha}' \
        >> "$log_path" 2>/dev/null || true
}

# cmd_test_record <suite> [--files=a,b] [--exit=N] [--commit=SHA] [--duration=MS]
# Records a suite outcome in the test_results ledger (producer shim). Writes ONE
# row per --files entry, keyed (suite, path), with that file's fingerprint and the
# shared exit code — so the consumer can ask per-file "is this content fresh?".
# Idempotent per (suite, path): a re-run overwrites the prior row (latest wins).
# With no --files, records a single sentinel row (path='') under the HEAD sha.
# --duration=MS is the suite run's wall-clock cost (LL1); the suite ran once, so
# every per-file row from that run carries the same shared duration. Omitted or
# non-numeric coerces to 0 (the "unmeasured" sentinel, matching the prior baseline).
# Side effect (LL2): also appends ONE durable JSONL history line per run to the
# on-disk suite log (_suite_log_append) so run history survives `wv load`/reboot,
# unlike the tmpfs table. Never fails the caller — a recording error must not break
# a commit hook.
cmd_test_record() {
    local suite="${1:-}"
    shift || true
    local files="" exit_code="0" commit_sha="" duration_ms="0"
    local arg
    for arg in "$@"; do
        case "$arg" in
            --files=*)    files="${arg#--files=}" ;;
            --exit=*)     exit_code="${arg#--exit=}" ;;
            --commit=*)   commit_sha="${arg#--commit=}" ;;
            --duration=*) duration_ms="${arg#--duration=}" ;;
            *) ;;
        esac
    done

    if [ -z "$suite" ]; then
        echo "Usage: wv test-record <suite> [--files=a,b] [--exit=N] [--commit=SHA] [--duration=MS]" >&2
        return 1
    fi

    # Coerce a non-numeric exit code to 1 (treat as failure) rather than corrupt the row.
    case "$exit_code" in
        ''|*[!0-9]*) exit_code=1 ;;
    esac
    # Coerce a non-numeric/empty duration to 0 rather than corrupt the row (cost-blind
    # is the prior baseline, so 0 is the safe "unmeasured" sentinel).
    case "$duration_ms" in
        ''|*[!0-9]*) duration_ms=0 ;;
    esac

    [ -z "$commit_sha" ] && commit_sha=$(git rev-parse --short HEAD 2>/dev/null || echo "")
    local suite_esc commit_esc
    suite_esc=$(sql_escape "$suite")
    commit_esc=$(sql_escape "$commit_sha")

    # Durable history: one append-only JSONL line per run, survives wv load (LL2).
    # The tmpfs upserts below remain the gate's current-state view.
    _suite_log_append "$suite" "$files" "$exit_code" "$duration_ms" "$commit_sha"

    if [ -z "$files" ]; then
        # Whole-suite run with no file set: one sentinel row keyed on HEAD.
        local head_fp
        head_fp=$(git rev-parse --short=16 HEAD 2>/dev/null || echo "nofiles")
        db_query "INSERT OR REPLACE INTO test_results(suite, path, fingerprint, exit_code, ran_at, commit_sha, duration_ms)
                  VALUES ('$suite_esc', '', '$(sql_escape "$head_fp")', $exit_code, datetime('now'), '$commit_esc', $duration_ms);" \
                  >/dev/null 2>&1 || true
        return 0
    fi

    # One row per file. printf '%s\n' guarantees a trailing newline so `read` does
    # not drop the last field.
    local f fp
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        fp=$(_test_file_fingerprint "$f")
        db_query "INSERT OR REPLACE INTO test_results(suite, path, fingerprint, exit_code, ran_at, commit_sha, duration_ms)
                  VALUES ('$suite_esc', '$(sql_escape "$f")', '$(sql_escape "$fp")', $exit_code, datetime('now'), '$commit_esc', $duration_ms);" \
                  >/dev/null 2>&1 || true
    done < <(printf '%s\n' "$files" | tr ',' '\n')
    return 0
}

# _doctor_check_git_hook label src_path installed_path grep_pattern install_cmd
# Records pass/warn via _doctor_record. Shared by pre-commit and prepare-commit-msg checks.
_doctor_check_git_hook() {
    local label="$1" src="$2" installed="$3" grep_pattern="$4" install_cmd="$5"
    if [ -f "$installed" ]; then
        if [ -f "$src" ] && cmp -s "$src" "$installed" 2>/dev/null; then
            _doctor_record "$label" "pass" "Weave hook installed and current"
        elif [ ! -f "$src" ] && grep -q "$grep_pattern" "$installed" 2>/dev/null; then
            _doctor_record "$label" "pass" "Weave hook installed (managed by wv init-repo)"
        elif grep -q "$grep_pattern" "$installed" 2>/dev/null; then
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
        if [ -f "$tmap" ]; then
            _doctor_record "test-map" "pass" ".weave/test-map.conf present"
        else
            _doctor_record "test-map" "warn" ".weave/test-map.conf absent — touched files classify 'unknown', gate inert even when on. See: wv guide --topic=verification"
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

    _dr_pass=0 _dr_fail=0 _dr_warn=0 _dr_total=0 _dr_results=""

    [ "$_dr_format" = "text" ] && echo "Weave Doctor — Installation Health"

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

    # 10b. FTS5 index integrity (PRAGMA integrity_check misses FTS5 shadow tables)
    if [ -n "${WV_DB:-}" ] && [ -f "$WV_DB" ]; then
        local fts5_ok
        fts5_ok=$(sqlite3 "$WV_DB" \
            "INSERT INTO nodes_fts(nodes_fts) VALUES('integrity-check');" 2>&1)
        if [ -z "$fts5_ok" ]; then
            _doctor_record "FTS5 index" "pass" "integrity OK"
        else
            if [ "$_dr_repair" = "true" ]; then
                sqlite3 "$WV_DB" \
                    "INSERT INTO nodes_fts(nodes_fts) VALUES('rebuild');" 2>/dev/null
                local fts5_recheck
                fts5_recheck=$(sqlite3 "$WV_DB" \
                    "INSERT INTO nodes_fts(nodes_fts) VALUES('integrity-check');" 2>&1)
                if [ -z "$fts5_recheck" ]; then
                    _doctor_record "FTS5 index" "pass" "repaired (rebuilt)"
                else
                    _doctor_record "FTS5 index" "fail" "repair failed — manual: wv reindex"
                fi
            else
                _doctor_record "FTS5 index" "fail" "corrupt — run: wv doctor --repair"
            fi
        fi
    fi

    # 11-12. Module checks
    _doctor_check_modules "lib modules" "$WV_LIB_DIR/lib" \
        "wv-config.sh wv-db.sh wv-validate.sh wv-cache.sh wv-journal.sh wv-gh.sh wv-hook-common.sh wv-resolve-project.sh"
    _doctor_check_modules "cmd modules" "$WV_LIB_DIR/cmd" \
        "wv-cmd-core.sh wv-cmd-graph.sh wv-cmd-data.sh wv-cmd-ops.sh wv-cmd-quality.sh"

    # 12b. Hook-common wiring check (Sprint 1 pattern crystallization)
    local _doctor_hooks_total=0
    local _doctor_hooks_ok=0
    local _doctor_hooks_missing=""
    local _doctor_project_root
    _doctor_project_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    if [ -n "$_doctor_project_root" ] && [ -d "$_doctor_project_root/.claude/hooks" ]; then
        local _doctor_hook_rel _doctor_hook_abs
        for _doctor_hook_rel in \
            ".claude/hooks/pre-action.sh" \
            ".claude/hooks/session-start-context.sh" \
            ".claude/hooks/session-end-sync.sh" \
            ".claude/hooks/stop-check.sh" \
            ".claude/hooks/pre-compact-context.sh" \
            ".claude/hooks/wv-touched-files.sh" \
            ".claude/hooks/context-guard.sh"; do
            _doctor_hooks_total=$((_doctor_hooks_total + 1))
            _doctor_hook_abs="$_doctor_project_root/$_doctor_hook_rel"
            if [ -f "$_doctor_hook_abs" ] && grep -q "wv-hook-common" "$_doctor_hook_abs" 2>/dev/null; then
                _doctor_hooks_ok=$((_doctor_hooks_ok + 1))
            else
                _doctor_hooks_missing="${_doctor_hooks_missing:+$_doctor_hooks_missing, }$_doctor_hook_rel"
            fi
        done
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
    # mirror of pattern-audit Check 6 — a node carrying active deferral metadata
    # (deferred/blocked_until/blocked_on) while status='todo' with no non-done blocks
    # edge, so status does not reflect the deferral. Uses the SAME canonical predicate
    # (wv_deferral_metadata_predicate) as Check 6 and wv_blocking_reason. Advisory only.
    # See docs/PROPOSAL-graph-as-policy-boundary.md.
    if [ -f "${WV_DB:-}" ]; then
        local _deferred_ready
        _deferred_ready=$(db_query "
            SELECT COUNT(*) FROM nodes n
            WHERE n.status='todo'
              AND $(wv_deferral_metadata_predicate n)
              AND NOT EXISTS (
                  SELECT 1 FROM edges e JOIN nodes b ON e.source=b.id
                  WHERE e.target=n.id AND e.type='blocks' AND b.status!='done' );
        " 2>/dev/null || echo "0")
        if [ "${_deferred_ready:-0}" -gt 0 ] 2>/dev/null; then
            _doctor_record "node-state" "warn" "$_deferred_ready node(s) carry deferral metadata while status='todo' — status must reflect it; see 'wv pattern-audit' (Check 6); fix with status=blocked-external or a blocks edge"
        else
            _doctor_record "node-state" "pass" "no deferral-metadata-vs-status divergence"
        fi
    fi

    # 14a-bis. Duplicate-authoritative-memory risk: durable Claude/Codex harness
    # memory for this repo not represented in the graph (S5, generalized F1).
    _doctor_memory_authority

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
    if [ -n "$git_root" ]; then
        _doctor_check_git_hook \
            "pre-commit hook" \
            "$git_root/scripts/hooks/pre-commit-weave.sh" \
            "$git_root/.git/hooks/pre-commit" \
            "Weave pre-commit" \
            "install -m 755 scripts/hooks/pre-commit-weave.sh .git/hooks/pre-commit"
        _doctor_check_git_hook \
            "prepare-commit-msg hook" \
            "$git_root/scripts/hooks/prepare-commit-msg-weave.sh" \
            "$git_root/.git/hooks/prepare-commit-msg" \
            "Weave: append Weave-ID trailers" \
            "install -m 755 scripts/hooks/prepare-commit-msg-weave.sh .git/hooks/prepare-commit-msg"
        _doctor_check_git_hook \
            "post-commit hook" \
            "$git_root/scripts/hooks/post-commit-weave.sh" \
            "$git_root/.git/hooks/post-commit" \
            "Weave post-commit" \
            "install -m 755 scripts/hooks/post-commit-weave.sh .git/hooks/post-commit"
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
                echo "$matcher" | grep -q "$tool" || missing_tools="${missing_tools:+$missing_tools, }$tool"
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

# ═══════════════════════════════════════════════════════════════════════════
# cmd_mcp_status — Verify MCP server is built and reachable
# ═══════════════════════════════════════════════════════════════════════════

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
            results="${results:+$results,}$(printf '{"check":"%s","status":"%s","detail":"%s"}' "$name" "$status" "$detail")"
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

    _mcp_check_vscode_config() {
        local config_path="$1"
        local config_label="$2"
        local missing=()
        local contract_path="$REPO_ROOT/mcp/contract.json"

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
                grep -q "$env_name" "$config_path" 2>/dev/null || missing+=("$env_name")
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
    local process_lines process_count duplicate_scope
    process_lines=$(pgrep -af 'mcp/dist/index.js|weave-mcp|node .*weave' 2>/dev/null | grep -v 'pgrep -af' || true)
    process_count=$(printf '%s\n' "$process_lines" | sed '/^$/d' | wc -l | tr -d ' ')
    duplicate_scope=$(
        printf '%s\n' "$process_lines" | sed '/^$/d' | awk '
            {
                scope="all"
                if ($0 ~ /--scope=graph/) scope="graph"
                else if ($0 ~ /--scope=session/) scope="session"
                else if ($0 ~ /--scope=lite/) scope="lite"
                else if ($0 ~ /--scope=inspect/) scope="inspect"
                count[scope]++
            }
            END {
                for (scope in count) if (count[scope] > 1) {
                    if (out) out=out ","
                    out=out scope ":" count[scope]
                }
                print out
            }'
    )
    if [ "$process_count" -eq 0 ] 2>/dev/null; then
        _mcp_record "server processes" "warn" "no running MCP server visible; start or restart the MCP client if tools are unavailable"
    elif [ -n "$duplicate_scope" ]; then
        _mcp_record "server processes" "warn" "${process_count} running, duplicate scope(s): ${duplicate_scope} — restart MCP servers to clear stale instances"
    else
        _mcp_record "server processes" "pass" "${process_count} running MCP server process(es), no duplicate scopes visible"
    fi

    # Summary
    if [ "$format" = "json" ]; then
        local overall="pass"
        [ "$fail" -gt 0 ] && overall="fail"
        printf '{"overall":"%s","passed":%d,"failed":%d,"warnings":%d,"total":%d,"checks":[%s]}\n' \
            "$overall" "$pass" "$fail" "$warn" "$total" "$results"
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
        _st_results="${_st_results:+$_st_results,}$(printf '{"test":"%s","status":"%s","detail":"%s"}' "$name" "$status" "$detail")"
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

    # 3. Link
    if [ -n "$id1" ] && [ -n "$id2" ]; then
        local link_out
        link_out=$(cmd_link "$id2" "$id1" --type=implements 2>&1) && _selftest_check "link" "1" "$id2 -> $id1" \
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
_h_quality_available="false" _h_quality_score=0 _h_quality_hotspots=0
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
        JOIN edges e ON e.target = n.id
        WHERE json_extract(n.metadata, '\$.pitfall') IS NOT NULL
        AND n.status != 'done'
        AND e.type IN ('addresses', 'implements', 'supersedes');
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
    _h_quality_hotspots=0
    _h_quality_files=0
    _h_quality_head=""
    _h_quality_scanned=""
    local quality_json
    local _hz_args=()
    if [ -n "$WV_HOT_ZONE" ]; then _hz_args=("--hot-zone" "$WV_HOT_ZONE"); fi
    quality_json=$(_wv_quality_python "${_hz_args[@]}" health-info 2>/dev/null || echo '{"available":false}')
    if echo "$quality_json" | jq -e '.available' >/dev/null 2>&1; then
        _h_quality_available=$(echo "$quality_json" | jq -r '.available')
        if [ "$_h_quality_available" = "true" ]; then
            _h_quality_score=$(echo "$quality_json" | jq -r '.score')
            _h_quality_hotspots=$(echo "$quality_json" | jq -r '.hotspot_count')
            _h_quality_files=$(echo "$quality_json" | jq -r '.total_files')
            _h_quality_head=$(echo "$quality_json" | jq -r '.git_head')
            _h_quality_scanned=$(echo "$quality_json" | jq -r '.scanned_at')
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
            '{available: true, score: $score, hotspot_count: $hotspots, total_files: $files, git_head: $git_head, scanned_at: $scanned_at}')
    else
        quality_obj='{"available":false}'
    fi
    # shellcheck disable=SC1010  # 'done' is a jq arg name, not the bash keyword
    jq -n \
        --arg status "$_h_status_text" \
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
        --argjson orphan_ids "$_h_orphan_ids" \
        --argjson intentional_standalones "$_h_intentional_standalones" \
        --argjson intentional_standalone_ids "$_h_intentional_standalone_ids" \
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
        --argjson gh_duplicate_issues "$_h_gh_duplicate_issues" \
        '{
            status: $status,
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
        echo "  Hotspots: $_h_quality_hotspots files above threshold"
        echo "  Last scan: $_h_quality_scanned (${_h_quality_head:0:7})"
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
        esac
        shift
    done

    # Handle --history: show log and exit
    if [ "$history_count" -gt 0 ] 2>/dev/null; then
        _health_show_history "$history_count" "$format"
        return 0
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
        if [ -f "$cache_file" ]; then
            local _hf_now _hf_mtime _hf_age _hf_fresh=true
            _hf_now=$(date +%s)
            _hf_mtime=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null || echo 0)
            _hf_age=$((_hf_now - _hf_mtime))
            [ "$_hf_age" -le "$fast_ttl" ] || _hf_fresh=false
            if [ -f "$WV_RUN_CACHE_SENTINEL" ] && [ "$cache_file" -ot "$WV_RUN_CACHE_SENTINEL" ]; then
                _hf_fresh=false
            fi
            if [ "$_hf_fresh" = "true" ]; then
                if [ "$format" = "json" ]; then
                    cat "$cache_file"
                else
                    echo "Health: $(jq -r '.score' "$cache_file" 2>/dev/null)/100 (fast, cached)"
                fi
                return 0
            fi
        fi
        _health_collect_metrics
        _health_compute_score
        # Append to the same trend log as the full path (only on recompute —
        # a cache hit means the DB is unchanged, so the data point is a duplicate)
        if [ -d "$WEAVE_DIR" ]; then
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%S)" \
                "$_h_health_score" "$_h_total_nodes" "$_h_total_edges" \
                "$_h_orphan_nodes" "$_h_ghost_edges" >> "$WEAVE_DIR/health.log"
        fi
        jq -n \
            --arg score "${_h_health_score:-0}" \
            --arg nodes "${_h_total_nodes:-0}" \
            --arg edges "${_h_total_edges:-0}" \
            --arg orphans "${_h_orphan_nodes:-0}" \
            '{"score":($score|tonumber),"total_nodes":($nodes|tonumber),"total_edges":($edges|tonumber),"orphan_nodes":($orphans|tonumber),"fast":true}' \
            > "$cache_file.tmp" 2>/dev/null && mv "$cache_file.tmp" "$cache_file"
        if [ "$format" = "json" ]; then
            cat "$cache_file" 2>/dev/null || jq -n --arg s "${_h_health_score:-0}" '{"score":($s|tonumber),"fast":true}'
        else
            echo "Health: ${_h_health_score}/100 (fast)"
        fi
        return 0
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
        _health_format_json "$strict"
        # JSON callers parse the output — exit 0 unless --strict
        if [ "$_h_invalid_statuses" -gt 0 ] || [ "$_h_contradictions" -gt 0 ]; then
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
    # - Always exit 1 for true errors: invalid statuses, contradictions
    if [ "$_h_invalid_statuses" -gt 0 ] || [ "$_h_contradictions" -gt 0 ]; then
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
        esac
        shift
    done
    case "$top" in
        ''|*[!0-9]*) top=20 ;;
    esac

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
        SELECT COUNT(DISTINCT target) FROM edges
        WHERE type IN ('addresses', 'implements', 'supersedes')
        AND target IN (
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

    # For each pitfall node, check for incoming addresses/implements/supersedes edges
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
            SELECT source FROM edges
            WHERE target='$id'
            AND type IN ('addresses', 'implements', 'supersedes')
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

    # ── Check 1: cache write-list completeness ──────────────────────────────
    # Every command in the dispatch table must be in one of:
    #   read (_wv_run_cache_is_read_cmd)
    #   write (_wv_run_cache_is_write_cmd)
    #   exempt (_wv_run_cache_is_exempt_cmd)
    # Unclassified commands are a latent cache-invalidation bug.

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
            if ! _wv_run_cache_is_read_cmd "$cmd" 2>/dev/null && \
               ! _wv_run_cache_is_write_cmd "$cmd" 2>/dev/null && \
               ! _wv_run_cache_is_exempt_cmd "$cmd" 2>/dev/null; then
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
            echo -e "${RED}✗ Check 1 FAIL: unclassified commands (not in read/write/exempt list):${NC}"
            echo "$unclassified_list" | while read -r c; do echo "    $c"; done
            echo -e "  Add to _wv_run_cache_is_write_cmd or _wv_run_cache_is_exempt_cmd in wv-cache.sh"
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
        [ "$format" = "text" ] && echo -e "${GREEN}✓ Check 1 PASS: all dispatch commands classified (read/write/exempt)${NC}"
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
            def_files=$(grep -rl "^${enum_name}=" "$search_root" 2>/dev/null | sort | tr '\n' ' ' | sed 's/[[:space:]]*$//')
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

    # ── Check 4: required hooks source wv-hook-common.sh ───────────────────
    local _hooks_dir="$_project_root/.claude/hooks"
    if [ -d "$_hooks_dir" ]; then
        local hook_missing=""
        local hook_missing_count=0
        local hook_total=0
        local hook_path
        for hook_path in \
            "$_hooks_dir/pre-action.sh" \
            "$_hooks_dir/session-start-context.sh" \
            "$_hooks_dir/session-end-sync.sh" \
            "$_hooks_dir/stop-check.sh" \
            "$_hooks_dir/pre-compact-context.sh" \
            "$_hooks_dir/wv-touched-files.sh" \
            "$_hooks_dir/context-guard.sh"; do
            hook_total=$((hook_total + 1))
            if [ ! -f "$hook_path" ] || ! grep -q "wv-hook-common" "$hook_path" 2>/dev/null; then
                hook_missing_count=$((hook_missing_count + 1))
                hook_missing="${hook_missing:+$hook_missing, }${hook_path#$_project_root/}"
            fi
        done

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
    # enforced gate. See docs/PROPOSAL-graph-as-policy-boundary.md.
    local divergent_nodes=""
    if [ -f "$WV_DB" ]; then
        divergent_nodes=$(db_query "
            SELECT id FROM nodes n
            WHERE n.status='todo'
              AND $(wv_deferral_metadata_predicate n)
              AND NOT EXISTS (
                  SELECT 1 FROM edges e JOIN nodes b ON e.source=b.id
                  WHERE e.target=n.id AND e.type='blocks' AND b.status!='done' );
        " 2>/dev/null || echo "")
    fi
    if [ -n "$divergent_nodes" ]; then
        local divergent_list dcount
        divergent_list=$(echo "$divergent_nodes" | tr '\n' ' ' | sed 's/ *$//')
        dcount=$(echo "$divergent_nodes" | grep -c .)
        if [ "$format" = "text" ]; then
            echo -e "${RED}✗ Check 6 FAIL: $dcount node(s) carry deferral metadata while status='todo' (status must reflect the deferral):${NC}"
            echo "$divergent_nodes" | while read -r nid; do [ -n "$nid" ] && echo "    $nid"; done
            echo -e "  Encode deferral as state: status=blocked-external (or add a blocks edge), not metadata.deferred/blocked_until/blocked_on alone."
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
        local _pa7_awk='
/^(function[ \t]+)?[A-Za-z_][A-Za-z0-9_]*\(\)[ \t]*\{[ \t]*(#.*)?$/ {
    fname=$0; sub(/\(\).*/,"",fname); sub(/^function[ \t]+/,"",fname)
    annotated = ($0 ~ /#[ \t]*predicate/) ? 1 : 0
    infunc=1; last=""; lastnr=0; next
}
infunc && /^\}/ {
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
        local _pa8_awk='
function allowed(fn) {
    return fn == "_bootstrap_agent_tools_json" ||
           fn == "_preflight_policy_readiness" ||
           fn == "_done_refresh_file_metrics" ||
           fn == "_done_refresh_trend_signals"
}
/^(function[ \t]+)?[A-Za-z_][A-Za-z0-9_]*\(\)[ \t]*\{/ {
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
        local _pa9_awk='
function allowed(fn) {
    return fn == "_memory_scan_claude" ||
           fn == "_memory_scan_codex" ||
           fn == "_memory_scan_copilot" ||
           fn == "_memory_import_claude_dir" ||
           fn == "_health_cache_summary" ||
           fn == "cmd_cache" ||
           fn == "_doctor_memory_authority" ||
           fn == "_doctor_codex_memory_rows"
}
/^(function[ \t]+)?[A-Za-z_][A-Za-z0-9_]*\(\)[ \t]*\{/ {
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
    for type in $VALID_EDGE_TYPES; do
        local desc=""
        case "$type" in
            blocks)     desc="Workflow dependency (target blocked by source)" ;;
            relates_to) desc="General semantic relationship" ;;
            implements) desc="Target implements source concept/spec" ;;
            contradicts) desc="Target contradicts source" ;;
            supersedes) desc="Target supersedes/replaces source" ;;
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
        esac
        shift
    done

    if [ -n "$procedure" ]; then
        if [[ ! "$procedure" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
            echo "Error: invalid procedure id '$procedure'" >&2
            return 1
        fi
        local procedure_file="${WV_CONFIG_DIR:-$HOME/.config/weave}/procedures/${procedure}.md"
        if [ ! -f "$procedure_file" ]; then
            echo "Error: unknown procedure '$procedure' (not installed: $procedure_file)" >&2
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
  pre-commit   hygiene gate (lint, active-node) + runs fast/impact suites + records
  post-commit  runs deferred slow suites + records (advisory, never blocks)
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
  wv edges <id>           --type=, --direction=, --depth=N

  wv show <id>          Full node detail. --json for machine-readable.
  wv tree <epic>        Epic → task hierarchy. --mermaid for diagram.
  wv path <id>          Ancestry chain to root.

  wv analyze sessions   Telemetry: top commands by output bytes / approx tokens.
    --call-stats          Run this after a session to see where context goes.
                          Window it (--since-days=1) for retro reading — unwindowed
                          output is a lifetime aggregate across instrumentation eras.
                          Prefer query or search over wv list for targeted reads;
                          reserve wv list for full enumeration only.

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

cmd_help_topic() {
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
        validate-finding)
            print_command_help "wv validate-finding <id>" "Validate finding metadata for a node. Exit 0 = valid; exit 1 = invalid. Outputs JSON {valid, errors[]}. Used by pre-close-verification hook to enforce violation_type and optional field constraints before a finding node can be closed."
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
            print_command_help "wv add <text> [--status=STATUS] [--parent=<id>] [--gh] [--alias=<name>] [--metadata=<json>] [--force] [--standalone] [--criteria=<text>] [--risks=<level>]" "Create a node and print its id. Use --parent when an active epic exists, or --standalone for repo-level chores."
            ;;
        remember)
            print_command_help "wv remember <text> [--kind=project] [--scope=repo] [--source-agent=name] [--json]" "Capture a graph-native memory node using metadata.type=memory and metadata.mem_status=active."
            ;;
        memory)
            print_command_help "wv memory recall [--agent=current|all|name] [--json] | wv memory render [--agent=all|current|claude|claude-memory|copilot|codex|codex-memory|workflow] [--base-dir=DIR] [--path=PATH] [--json] | wv memory scan --source=claude|codex|copilot|all [--repo-root=DIR] [--json] | wv memory import --source=claude --path=DIR [--repo-root=DIR] [--json] | wv memory import --source=codex [--path=DB] [--repo-root=DIR] [--json] | wv memory crystallize [--dry-run|--apply-reviewed] [--repo-root=DIR] [--json]" "Recall graph-native memory, render repo-local projections, scan harness state, import Claude project memories or Codex memory-pipeline rows as mem_status=candidate nodes, or crystallize candidates (dedup/verify/mark, promote reviewed). Capture records dynamic agent provenance; graph recall is agent-agnostic. --path is only valid for one render projection or a single Codex memory DB import."
            ;;
        delete)
            print_command_help "wv delete <id> [--force] [--dry-run] [--no-gh]" "Delete a node and its edges. Use --dry-run to preview deletions and --force to execute them."
            ;;
        done)
            print_command_help "wv done <id> [--learning=\"...\"|--learning-file=PATH] [--decision=\"...\"] [--pattern=\"...\"] [--pitfall=\"...\"] [--verification-method=\"...\"] [--verification-evidence=\"...\"|--verification-evidence-file=PATH] [--no-warn] [--acknowledge-overlap] [--skip-verification] [--no-overlap-check] [--no-gh]" "Close a node and optionally store structured learnings or bypass flags when policy allows it."
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
            print_command_help "wv list [--all] [--status=<status>] [--json | --json-v2] [--mode=bootstrap|discover|execute|full]" "List nodes, excluding done by default. Use --json-v2 for the lean parsed-metadata shape."
            ;;
        show)
            print_command_help "wv show <id> [--json | --json-v2] [--mode=bootstrap|discover|execute|full]" "Show node details in text or JSON. --json-v2 returns the lean parsed-metadata shape."
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
            print_command_help "wv guide [--topic=workflow|github|learnings|context|routing|mcp|verification|instrumentation|config|discovery]" "Show a quick reference for common Weave workflows, routing rules, and integrations."
            ;;
        prune)
            print_command_help "wv prune [--age=48h] [--dry-run] [--orphans-only]" "Archive old done nodes, optionally targeting only orphaned ones."
            ;;
        unarchive)
            print_command_help "wv unarchive <id> [--dry-run] [--with-edges]" "Restore a pruned node from .weave/archive/ back into the live graph."
            ;;
        clean-ghosts)
            print_command_help "wv clean-ghosts [--dry-run]" "Remove edges that reference deleted nodes."
            ;;
        compact)
            print_command_help "wv compact [--older-than=Nd] [--dry-run] [--force]" "Delete replayed delta files after age and active-claim safety checks."
            ;;
        refs)
            print_command_help "wv refs <file> | wv refs -t <text> | echo <text> | wv refs [--link --from=<id>] [--json] [--max=N]" "Extract Weave node references from text and optionally create edges."
            ;;
        import)
            print_command_help "wv import <file.jsonl> [--filter=\"id=...\"] [--dry-run]" "Import nodes from JSONL/JSON exports."
            ;;
        batch)
            print_command_help "wv batch [file] [--dry-run] [--stop-on-error]" "Execute multiple wv commands from a file or stdin."
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
        hotzone)
            print_command_help "wv hotzone list [--json]" "List all hot-zones (active graph DB directories) with status, node count, and owner."
            print_command_help "wv hotzone gc [--dry-run]" "Remove orphan hot-zone directories (no matching live repo). Skips dirs newer than 1h."
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
  init-repo         Bootstrap repo for Weave [--agent=claude|copilot|codex|all] [--codex-hooks] [--update] [--force]
  self-update       Refresh installed wv from the dev clone recorded at install time
  uninstall         Remove installed wv files (delegates to install.sh --uninstall)
  doctor            Installation + surface-contract checks (deps, hooks, ghost settings, matchers) [--json]
  hotzone <sub>     Hot-zone DB directories (list, gc) [--json] [--dry-run]
  selftest          Round-trip smoke test in isolated environment [--json]
  test-record <suite> Record a test-suite run for verification freshness (used by git hooks)
    mcp-status        Verify MCP server is built and IDE config shape is current [--json]
  health            System health check with score and diagnostics [--history[=N]]
  config            Manage durable opt-in knobs [list|get|set|unset|enable|disable]
    guide             Workflow quick reference [--topic=workflow|github|learnings|context|routing|mcp|verification|instrumentation|config|discovery]
  prune             Archive old done nodes
  unarchive <id>    Restore a pruned node from .weave/archive/ [--dry-run] [--with-edges]
  clean-ghosts      Delete ghost edges referencing deleted nodes [--dry-run] [legacy compatibility]
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
