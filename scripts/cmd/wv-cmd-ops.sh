#!/bin/bash
# wv-cmd-ops.sh — Operations commands
#
# Commands: mcp-status, edge-types, cache, init-repo, self-update, uninstall
# Sourced by: wv entry point (autoloaded on first use)
# Dependencies: wv-config.sh, wv-db.sh, wv-cache.sh
#
# doctor, pattern-audit -> wv-cmd-doctor.sh; health, selftest -> wv-cmd-health.sh;
# help, guide -> wv-cmd-help.sh; bootstrap and the other orientation commands ->
# wv-cmd-orient.sh (wv-71933b, the wv-c153c4 split).

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
