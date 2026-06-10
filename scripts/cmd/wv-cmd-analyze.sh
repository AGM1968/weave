#!/bin/bash
# wv-cmd-analyze.sh — wv analyze subcommand
#
# Usage:
#   wv analyze sessions --call-stats [--log=<path>] [--top=N]
#   wv analyze suites [--log=<path>] [--json]
#
# Reads a JSONL call log (enable durably with `wv config enable session-analysis`,
# which sets WV_CALL_LOG in ~/.config/weave/config.env) and surfaces the wv
# subcommands consuming the most stdout+stderr bytes.
#
# Default log path: ~/.local/share/weave/wv_calls.jsonl
# Default top N: 10

cmd_analyze() {
    local sub="${1:-help}"
    shift || true
    case "$sub" in
        sessions) cmd_analyze_sessions "$@" ;;
        suites)   cmd_analyze_suites "$@" ;;
        help|--help|-h)
            echo "Usage: wv analyze <subcommand> [options]"
            echo ""
            echo "Subcommands:"
            echo "  sessions --call-stats   Show top wv commands by byte output"
            echo "  suites                  Per-suite run count + duration (total/avg/p95) + pass/fail"
            echo "                          Defaults to current repo; use --all to see all repos"
            ;;
        *)
            echo "wv analyze: unknown subcommand: $sub" >&2
            echo "Run 'wv analyze help' for usage." >&2
            return 1
            ;;
    esac
}

cmd_analyze_sessions() {
    # Distinguish "instrumentation off" from "on but no calls yet". The reader
    # must not imply a default path the writer never populates (finding O1a):
    # logging only happens when WV_CALL_LOG is set (now disk-sourced from
    # config.env), or when --log= points the reader at an explicit file.
    local default_log="${WV_CALL_LOG_DEFAULT:-${HOME}/.local/share/weave/wv_calls.jsonl}"
    local log_path="${WV_CALL_LOG:-$default_log}"
    local instrumentation_on=false
    [ -n "${WV_CALL_LOG:-}" ] && instrumentation_on=true
    local top_n=10
    local source_filter=""
    local mode
    mode=$(wv_resolve_mode)

    for arg in "$@"; do
        case "$arg" in
            --call-stats|--token-hogs) ;;   # primary mode flag — accepted, no-op (only mode for now)
            --log=*)      log_path="${arg#--log=}"; instrumentation_on=true ;;
            --top=*)      top_n="${arg#--top=}" ;;
            --source=*)   source_filter="${arg#--source=}" ;;
            --help|-h)
                echo "Usage: wv analyze sessions --call-stats [--log=<path>] [--top=N] [--source=<src>]"
                echo ""
                echo "  --log=<path>      JSONL call log (default: ~/.local/share/weave/wv_calls.jsonl)"
                echo "  --top=N           Show top N commands (default: 10)"
                echo "  --source=<src>    Filter by call origin: shell, hook, sync, agent"
                echo ""
                echo "Enable logging (durable, picked up by CLI + hooks):"
                echo "  wv config enable session-analysis"
                return 0
                ;;
        esac
    done

    if [ ! -f "$log_path" ]; then
        if [ "$mode" = "discover" ] || [ "$mode" = "bootstrap" ]; then
            if [ "$instrumentation_on" = true ]; then
                echo '{"call_stats":[],"message":"no call log found","log_path":"'"$log_path"'","instrumentation":"enabled"}'
            else
                echo '{"call_stats":[],"message":"instrumentation disabled","instrumentation":"disabled","enable":"wv config enable session-analysis"}'
            fi
        elif [ "$instrumentation_on" = true ]; then
            echo "Instrumentation enabled but no calls recorded yet at: $log_path"
            echo "Run some wv commands, then re-run this report."
        else
            echo "Session analysis is off — no call log is being written."
            echo "Enable instrumentation (durable, picked up by CLI + hooks):"
            echo "  wv config enable session-analysis"
        fi
        return 0
    fi

    # Parse JSONL and aggregate by cmd using python3 (available in runtime env)
    local result
    result=$(python3 - "$log_path" "$top_n" "$source_filter" <<'PYEOF'
import json, sys
from collections import defaultdict

log_path, top_n, source_filter = sys.argv[1], int(sys.argv[2]), sys.argv[3]
totals: dict[str, dict] = defaultdict(lambda: {"calls": 0, "total_bytes": 0, "total_ms": 0})
reopen_count = 0

try:
    with open(log_path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            if entry.get("event") == "reopen_done_node":
                reopen_count += 1
                continue
            if source_filter and entry.get("source", "shell") != source_filter:
                continue
            cmd = str(entry.get("cmd", "unknown"))
            stdout_b = int(entry.get("stdout_bytes", 0))
            stderr_b = int(entry.get("stderr_bytes", 0))
            elapsed = int(entry.get("elapsed_ms", 0))
            totals[cmd]["calls"] += 1
            totals[cmd]["total_bytes"] += stdout_b + stderr_b
            totals[cmd]["total_ms"] += elapsed
except OSError as exc:
    print(json.dumps({"error": str(exc)}))
    sys.exit(1)

ranked = sorted(totals.items(), key=lambda x: x[1]["total_bytes"], reverse=True)[:top_n]
print(json.dumps({
    "call_stats": [{"cmd": cmd, "approx_tokens": stats["total_bytes"] // 4, **stats} for cmd, stats in ranked],
    "reopen_count": reopen_count,
    "source_filter": source_filter or None
}))
PYEOF
    ) || return 1

    if [ "$mode" = "discover" ] || [ "$mode" = "bootstrap" ]; then
        echo "$result"
        return 0
    fi

    # Human-readable table
    local count
    count=$(echo "$result" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d['call_stats']))")
    if [ "$count" = "0" ]; then
        echo "Call log exists but contains no parseable entries: $log_path"
        return 0
    fi

    if [ -n "$source_filter" ]; then
        printf "\n${CYAN}Top %s wv commands by output volume (source: %s)${NC}\n" "$top_n" "$source_filter"
    else
        printf "\n${CYAN}Top %s wv commands by output volume${NC}\n" "$top_n"
    fi
    printf "${DIM}%-24s %10s %10s %8s %10s${NC}\n" "COMMAND" "BYTES" "~TOKENS" "CALLS" "AVG_MS"
    echo "$(printf '%0.s─' {1..66})"

    echo "$result" | python3 -c "
import json, sys
d = json.load(sys.stdin)
rows = d['call_stats']
for r in rows:
    avg_ms = r['total_ms'] // r['calls'] if r['calls'] else 0
    tokens = r.get('approx_tokens', r['total_bytes'] // 4)
    print(f\"{r['cmd']:<24} {r['total_bytes']:>10,} {tokens:>10,} {r['calls']:>8} {avg_ms:>10}\")
reopen = d.get('reopen_count', 0)
if reopen:
    print(f\"\\nPattern E — reopen (update done→active): {reopen} time{'s' if reopen != 1 else ''}\")
"
    printf "\nLog: %s\n" "$log_path"
}

# cmd_analyze_suites — report over the durable suite-run history (LL2/LL3).
# Reads the append-only JSONL written by `wv test-record` (WV_SUITE_LOG) and
# aggregates per suite: run count, pass/fail counts, and total/avg/p95 duration_ms.
# Defaults to the current repo (JSONL `repo` field = basename of repo root).
# Use --all or --repo=<path> to widen scope.
cmd_analyze_suites() {
    local default_log="${WV_SUITE_LOG_DEFAULT:-${HOME}/.local/share/weave/suite_runs.jsonl}"
    local log_path="${WV_SUITE_LOG:-$default_log}"
    local mode want_json="" all_repos=0
    mode=$(wv_resolve_mode)

    # Default repo filter: basename of current repo root.
    local cur_repo=""
    cur_repo=$(basename "${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo "")}" 2>/dev/null || true)

    for arg in "$@"; do
        case "$arg" in
            --log=*)    log_path="${arg#--log=}" ;;
            --json)     want_json=1 ;;
            --all)      all_repos=1 ;;
            --repo=*)   cur_repo=$(basename "${arg#--repo=}") ;;
            --help|-h)
                echo "Usage: wv analyze suites [--log=<path>] [--repo=<path>] [--all] [--json]"
                echo ""
                echo "  --log=<path>   Suite history JSONL (default: ~/.local/share/weave/suite_runs.jsonl)"
                echo "  --repo=<path>  Filter to a specific repo by name (default: current repo)"
                echo "  --all          Show merged output across all repos"
                echo "  --json         Force JSON output (default in discover/bootstrap mode)"
                echo ""
                echo "History is written automatically by the commit hooks (always on)."
                echo "Override the path: wv config set WV_SUITE_LOG <path>"
                return 0
                ;;
        esac
    done

    # Empty cur_repo (outside a git repo) falls through to all-repos behaviour.
    local repo_filter=""
    [ "$all_repos" = "0" ] && repo_filter="$cur_repo"

    # Default to JSON in machine-facing modes; --json forces it everywhere.
    if [ "$mode" = "discover" ] || [ "$mode" = "bootstrap" ]; then
        want_json=1
    fi

    if [ ! -f "$log_path" ]; then
        if [ -n "$want_json" ]; then
            echo '{"suites":[],"total_runs":0,"message":"no suite history recorded yet","log_path":"'"$log_path"'","repo":"'"${repo_filter:-ALL}"'"}'
        else
            echo "No suite-run history yet at: $log_path"
            echo "History is written automatically by the commit hooks on the next test run."
        fi
        return 0
    fi

    local result
    result=$(python3 - "$log_path" "$repo_filter" <<'PYEOF'
import json, math, sys
from collections import defaultdict

log_path = sys.argv[1]
repo_filter = sys.argv[2]   # empty string = show all repos
agg = defaultdict(lambda: {"runs": 0, "passed": 0, "failed": 0,
                           "total_ms": 0, "_durs": [], "last_ts": "", "last_sha": ""})

def p95(vals):
    if not vals:
        return 0
    s = sorted(vals)
    k = math.ceil(0.95 * len(s)) - 1   # nearest-rank
    return s[max(0, min(k, len(s) - 1))]

try:
    with open(log_path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                e = json.loads(line)
            except json.JSONDecodeError:
                continue
            if repo_filter and str(e.get("repo", "")) != repo_filter:
                continue
            suite = str(e.get("suite", "unknown"))
            dur = int(e.get("duration_ms", 0) or 0)
            ok = int(e.get("exit", 0) or 0) == 0
            a = agg[suite]
            a["runs"] += 1
            a["passed" if ok else "failed"] += 1
            a["total_ms"] += dur
            a["_durs"].append(dur)
            ts = str(e.get("ts", ""))
            if ts >= a["last_ts"]:           # ISO-8601 sorts lexicographically
                a["last_ts"] = ts
                a["last_sha"] = str(e.get("sha", ""))
except OSError as exc:
    print(json.dumps({"error": str(exc)}))
    sys.exit(1)

suites = []
total_runs = 0
for suite, a in agg.items():
    total_runs += a["runs"]
    suites.append({
        "suite": suite,
        "runs": a["runs"],
        "passed": a["passed"],
        "failed": a["failed"],
        "total_ms": a["total_ms"],
        "avg_ms": a["total_ms"] // a["runs"] if a["runs"] else 0,
        "p95_ms": p95(a["_durs"]),
        "last_ts": a["last_ts"],
        "last_sha": a["last_sha"],
    })
suites.sort(key=lambda s: s["total_ms"], reverse=True)   # heaviest first
print(json.dumps({"suites": suites, "total_runs": total_runs, "log_path": log_path,
                  "repo": repo_filter if repo_filter else "ALL"}))
PYEOF
    ) || return 1

    if [ -n "$want_json" ]; then
        echo "$result"
        return 0
    fi

    # Human-readable table.
    local count
    count=$(echo "$result" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('suites',[])))")
    if [ "$count" = "0" ]; then
        if [ -n "$repo_filter" ]; then
            echo "No suite history for repo '$repo_filter'. Use --all to see all repos."
        else
            echo "Suite history exists but contains no parseable entries: $log_path"
        fi
        return 0
    fi

    local scope_label="${repo_filter:-ALL repos}"
    printf "\n${CYAN}Suite-run history${NC}  ${DIM}[repo: %s]${NC}\n" "$scope_label"
    printf "${DIM}%-28s %6s %6s %6s %12s %12s %12s${NC}\n" \
        "SUITE" "RUNS" "PASS" "FAIL" "TOTAL_MS" "AVG_MS" "P95_MS"
    echo "$(printf '%0.s─' {1..84})"
    echo "$result" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for r in data['suites']:
    print(f\"{r['suite']:<28} {r['runs']:>6} {r['passed']:>6} {r['failed']:>6} \"
          f\"{r['total_ms']:>12,} {r['avg_ms']:>12,} {r['p95_ms']:>12,}\")
"
    printf "\nLog: %s\n" "$log_path"
}
