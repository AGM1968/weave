#!/bin/bash
# wv-cmd-analyze.sh — wv analyze subcommand
#
# Usage:
#   wv analyze sessions --token-hogs [--log=<path>] [--top=N]
#
# Reads a JSONL call log produced by WvClient(call_log_path=...) and surfaces
# the wv subcommands consuming the most stdout+stderr bytes.
#
# Default log path: ~/.local/share/weave/wv_calls.jsonl
# Default top N: 10

cmd_analyze() {
    local sub="${1:-help}"
    shift || true
    case "$sub" in
        sessions) cmd_analyze_sessions "$@" ;;
        help|--help|-h)
            echo "Usage: wv analyze <subcommand> [options]"
            echo ""
            echo "Subcommands:"
            echo "  sessions --token-hogs   Show top wv commands by byte output"
            ;;
        *)
            echo "wv analyze: unknown subcommand: $sub" >&2
            echo "Run 'wv analyze help' for usage." >&2
            return 1
            ;;
    esac
}

cmd_analyze_sessions() {
    local log_path="${HOME}/.local/share/weave/wv_calls.jsonl"
    local top_n=10
    local mode
    mode=$(wv_resolve_mode)

    for arg in "$@"; do
        case "$arg" in
            --token-hogs) ;;   # primary mode flag — accepted, no-op (only mode for now)
            --log=*)      log_path="${arg#--log=}" ;;
            --top=*)      top_n="${arg#--top=}" ;;
            --help|-h)
                echo "Usage: wv analyze sessions --token-hogs [--log=<path>] [--top=N]"
                echo ""
                echo "  --log=<path>   JSONL call log (default: ~/.local/share/weave/wv_calls.jsonl)"
                echo "  --top=N        Show top N commands (default: 10)"
                return 0
                ;;
        esac
    done

    if [ ! -f "$log_path" ]; then
        if [ "$mode" = "discover" ] || [ "$mode" = "bootstrap" ]; then
            echo '{"token_hogs":[],"message":"no call log found","log_path":"'"$log_path"'"}'
        else
            echo "No call log found at: $log_path"
            echo "Enable instrumentation by passing call_log_path= to WvClient."
        fi
        return 0
    fi

    # Parse JSONL and aggregate by cmd using python3 (available in runtime env)
    local result
    result=$(python3 - "$log_path" "$top_n" <<'PYEOF'
import json, sys
from collections import defaultdict

log_path, top_n = sys.argv[1], int(sys.argv[2])
totals: dict[str, dict] = defaultdict(lambda: {"calls": 0, "total_bytes": 0, "total_ms": 0})

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
print(json.dumps([{"cmd": cmd, **stats} for cmd, stats in ranked]))
PYEOF
    ) || return 1

    if [ "$mode" = "discover" ] || [ "$mode" = "bootstrap" ]; then
        echo "$result"
        return 0
    fi

    # Human-readable table
    local count
    count=$(echo "$result" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
    if [ "$count" = "0" ]; then
        echo "Call log exists but contains no parseable entries: $log_path"
        return 0
    fi

    printf "\n${CYAN}Top %s wv commands by byte output${NC}\n" "$top_n"
    printf "${DIM}%-28s %10s %8s %10s${NC}\n" "COMMAND" "BYTES" "CALLS" "AVG_MS"
    echo "$(printf '%0.s─' {1..60})"

    echo "$result" | python3 -c "
import json, sys
rows = json.load(sys.stdin)
for r in rows:
    avg_ms = r['total_ms'] // r['calls'] if r['calls'] else 0
    print(f\"{r['cmd']:<28} {r['total_bytes']:>10,} {r['calls']:>8} {avg_ms:>10}\")
"
    printf "\nLog: %s\n" "$log_path"
}
