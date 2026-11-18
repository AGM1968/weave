#!/bin/bash
# wv-cmd-analyze.sh — wv analyze subcommand
#
# Usage:
#   wv analyze sessions --call-stats [--log=<path>] [--top=N] [--since-days=N] [--include-sync]
#   wv analyze sessions --trace-eval --log=<path> [--usage-log=<path>] --json
#   wv analyze suites [--log=<path>] [--json]
#   wv analyze checkpoints [--days=N] [--log=<path>] [--repo=<path>] [--json]
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
        gates)    cmd_analyze_gates "$@" ;;
        checkpoints) cmd_analyze_checkpoints "$@" ;;
        help|--help|-h)
            echo "Usage: wv analyze <subcommand> [options]"
            echo ""
            echo "Subcommands:"
            echo "  sessions --call-stats   Show top wv commands by byte output"
            echo "  sessions --trace-eval   Observe state-aware traces from a WV_CALL_LOG JSONL file"
            echo "  suites                  Per-suite run count + duration (total/avg/p50/p95) + pass/fail"
            echo "  gates                   Per-gate wall time by phase (p50/p90), estimate error"
            echo "                          Defaults to current repo; use --all to see all repos"
            echo "  checkpoints             Measure auto-checkpoint overlap with recorded wv calls"
            ;;
        *)
            echo "wv analyze: unknown subcommand: $sub" >&2
            echo "Run 'wv analyze help' for usage." >&2
            return 1
            ;;
    esac
}

cmd_analyze_checkpoints() {
    local analyzer="$WV_LIB_DIR/profiling/checkpoint_overlap.py"
    [ -f "$analyzer" ] || analyzer="$WV_LIB_DIR/../profiling/checkpoint_overlap.py"
    if [ ! -f "$analyzer" ]; then
        echo "wv analyze checkpoints: checkpoint analyzer is not installed" >&2
        return 1
    fi
    python3 "$analyzer" "$@"
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
    local since_days="" since_raw="" include_sync=0 include_test=0 want_json="" trace_eval=0 usage_log=""
    local mode
    mode=$(wv_resolve_mode)

    for arg in "$@"; do
        case "$arg" in
            --call-stats|--token-hogs) ;;   # primary mode flag — accepted, no-op (only mode for now)
            --trace-eval)    trace_eval=1; want_json=1 ;;
            --usage-log=*)   usage_log="${arg#--usage-log=}" ;;
            --log=*)        log_path="${arg#--log=}"; instrumentation_on=true ;;
            --top=*)        top_n="${arg#--top=}" ;;
            --source=*)     source_filter="${arg#--source=}" ;;
            --since-days=*) since_days="${arg#--since-days=}" ;;
            --since=*)      since_raw="${arg#--since=}" ;;
            --include-sync) include_sync=1 ;;
            --include-test) include_test=1 ;;
            --json)         want_json=1 ;;
            --help|-h)
                echo "Usage: wv analyze sessions --call-stats [--log=<path>] [--top=N] [--source=<src>]"
                echo "                            [--since-days=N | --since=<date>] [--include-sync]"
                echo "                            [--include-test] [--json]"
                echo "       wv analyze sessions --trace-eval --log=<path> [--usage-log=<path>] --json"
                echo ""
                echo "  --log=<path>      JSONL call log (default: ~/.local/share/weave/wv_calls.jsonl)"
                echo "  --top=N           Show top N commands (default: 10)"
                echo "  --source=<src>    Filter by call origin: agent, shell, hook, sync, test, mcp"
                echo "  --since-days=N    Only count calls from the last N days"
                echo "  --since=<date>    Only count calls at/after <date> (YYYY-MM-DD or epoch seconds)"
                echo "  --include-sync    Count source=sync traffic (excluded by default: pipeline-internal"
                echo "                    stdout that never enters agent context)"
                echo "  --include-test    Count source=test traffic (excluded by default: suite-driven calls)"
                echo "  --json            Force JSON output (default in discover/bootstrap mode)"
                echo "  --trace-eval      Emit versioned observational trace measurements as JSON"
                echo "  --usage-log=<path> Canonical host usage JSONL joined by trace/workflow/call ID"
                echo ""
                echo "Unwindowed runs are lifetime aggregates and may span instrumentation eras;"
                echo "for retro reading, always pass a window (e.g. --since-days=1)."
                echo ""
                echo "Enable logging (durable, picked up by CLI + hooks):"
                echo "  wv config enable session-analysis"
                return 0
                ;;
            *)
                echo "wv analyze sessions: unknown option: $arg" >&2
                return 1
                ;;
        esac
    done

    if [ "$trace_eval" -eq 1 ]; then
        local evaluator="$WV_LIB_DIR/profiling/audit_sessions.py"
        [ -f "$evaluator" ] || evaluator="$WV_LIB_DIR/../profiling/audit_sessions.py"
        local -a evaluator_args=(--log "$log_path")
        [ -z "$usage_log" ] || evaluator_args+=(--usage-log "$usage_log")
        python3 "$evaluator" "${evaluator_args[@]}"
        return $?
    fi

    # Resolve the window to an epoch cutoff. --since wins over --since-days.
    local since_epoch=""
    if [ -n "$since_raw" ]; then
        case "$since_raw" in
            ''|*[!0-9.]*)
                if ! since_epoch=$(date -d "$since_raw" +%s 2>/dev/null); then
                    echo "wv analyze: invalid --since value: '$since_raw' (use YYYY-MM-DD or epoch seconds)" >&2
                    return 1
                fi
                ;;
            *) since_epoch="$since_raw" ;;
        esac
    elif [ -n "$since_days" ]; then
        case "$since_days" in
            ''|*[!0-9]*)
                echo "wv analyze: invalid --since-days value: '$since_days' (expected a positive integer)" >&2
                return 1
                ;;
        esac
        since_epoch=$(( $(date +%s) - since_days * 86400 ))
    fi

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
    result=$(python3 - "$log_path" "$top_n" "$source_filter" "$since_epoch" "$include_sync" "$include_test" <<'PYEOF'
import json, os, re, sys, time
from collections import defaultdict

# The call log is append-only and never rotated, so it only grows: 649k lines
# and 401MB on this host by 2026-09. Streaming and json.loads-ing every line and
# only then testing the window made --since-days=1 cost the same as lifetime
# (6787ms vs 8398ms measured), and the Stop hook pays that on every session end.
# Timestamps are non-decreasing because entries are appended on completion, so
# the window's first row can be found by seeking rather than by reading.
_TS_RE = re.compile(r'"ts":\s*([0-9.]+)')


def line_ts(raw):
    """Timestamp of a log line, read without parsing the whole object."""
    match = _TS_RE.search(raw[:200])
    return float(match.group(1)) if match else None


def window_start_offset(path, since, margin_bytes=1 << 20):
    """Byte offset to start parsing from, or 0 to read everything.

    Binary search for the first line at or after `since`, then rewind a margin.
    Concurrent writers can interleave by milliseconds, so the first row at or
    after the window is not necessarily the first row that belongs in it; the
    margin absorbs that, and the per-row `ts < since` test below still decides
    membership. Returning 0 keeps the previous whole-file behaviour exactly.
    """
    if since is None:
        return 0
    try:
        size = os.path.getsize(path)
    except OSError:
        return 0
    if size <= margin_bytes:
        return 0
    lo, hi = 0, size
    with open(path, "rb") as fh:
        while lo < hi:
            mid = (lo + hi) // 2
            fh.seek(mid)
            if mid:
                fh.readline()  # discard the partial line the seek landed in
            raw = fh.readline()
            if not raw:
                hi = mid
                continue
            ts = line_ts(raw.decode("utf-8", "replace"))
            nxt = min(fh.tell(), hi)
            if ts is None:
                # An era-blind row carries no position in the window. Step past
                # it rather than stalling; if it is the last probe, hi wins.
                if nxt <= lo:
                    break
                lo = nxt
            elif ts < since:
                lo = nxt
            else:
                hi = mid
    return max(0, lo - margin_bytes)


log_path, top_n, source_filter = sys.argv[1], int(sys.argv[2]), sys.argv[3]
since_epoch = float(sys.argv[4]) if sys.argv[4] else None
include_sync = sys.argv[5] == "1"
include_test = sys.argv[6] == "1"
# Explicit --source=<src> is an opt-in to that traffic, same as --include-<src>.
drop_sources = set()
if not include_sync and source_filter != "sync":
    drop_sources.add("sync")
if not include_test and source_filter != "test":
    drop_sources.add("test")
totals: dict[str, dict] = defaultdict(
    lambda: {"calls": 0, "total_bytes": 0, "total_stdout_bytes": 0, "total_ms": 0}
)
reopen_count = 0
excluded = {"sync_calls": 0, "sync_bytes": 0, "test_calls": 0, "test_bytes": 0, "no_ts": 0}
min_ts = max_ts = None

try:
    start_offset = window_start_offset(log_path, since_epoch)
    with open(log_path, encoding="utf-8") as fh:
        if start_offset:
            fh.seek(start_offset)
            fh.readline()  # the offset lands mid-line by construction
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            ts = None
            try:
                if entry.get("ts") is not None:
                    ts = float(entry["ts"])
            except (TypeError, ValueError):
                pass
            if since_epoch is not None:
                if ts is None:
                    # Era-blind entry: no timestamp means no place in a window.
                    excluded["no_ts"] += 1
                    continue
                if ts < since_epoch:
                    continue
            if entry.get("event") == "reopen_done_node":
                reopen_count += 1
                continue
            source = entry.get("source", "shell")
            if source_filter and source != source_filter:
                continue
            stdout_b = int(entry.get("stdout_bytes", 0))
            stderr_b = int(entry.get("stderr_bytes", 0))
            if source in drop_sources:
                excluded[f"{source}_calls"] += 1
                excluded[f"{source}_bytes"] += stdout_b + stderr_b
                continue
            if ts is not None:
                min_ts = ts if min_ts is None or ts < min_ts else min_ts
                max_ts = ts if max_ts is None or ts > max_ts else max_ts
            cmd = str(entry.get("cmd", "unknown"))
            elapsed = int(entry.get("elapsed_ms", 0))
            totals[cmd]["calls"] += 1
            totals[cmd]["total_bytes"] += stdout_b + stderr_b
            totals[cmd]["total_stdout_bytes"] += stdout_b
            totals[cmd]["total_ms"] += elapsed
except OSError as exc:
    print(json.dumps({"error": str(exc)}))
    sys.exit(1)

span_days = round((max_ts - min_ts) / 86400) if min_ts is not None and max_ts is not None else 0
ranked = sorted(totals.items(), key=lambda x: x[1]["total_bytes"], reverse=True)[:top_n]
out = {
    "call_stats": [{"cmd": cmd, "estimated_output_tokens": stats["total_stdout_bytes"] // 4, **stats}
                   for cmd, stats in ranked],
    "reopen_count": reopen_count,
    "source_filter": source_filter or None,
    "window": ({"since_epoch": since_epoch,
                "since": time.strftime("%Y-%m-%d %H:%M", time.localtime(since_epoch))}
               if since_epoch is not None else None),
    "span_days": span_days,
    "excluded": excluded,
}
if since_epoch is None and span_days > 14:
    out["note"] = (f"lifetime aggregate spanning {span_days} days — may mix instrumentation eras; "
                   "use --since-days=N for retro reading")
print(json.dumps(out))
PYEOF
    ) || return 1

    if [ -n "$want_json" ] || [ "$mode" = "discover" ] || [ "$mode" = "bootstrap" ]; then
        echo "$result"
        return 0
    fi

    # Human-readable table
    local count
    count=$(echo "$result" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d['call_stats']))")
    if [ "$count" = "0" ]; then
        if [ -n "$since_epoch" ]; then
            echo "No calls in the requested window. Widen it (--since-days) or drop the window for lifetime stats."
        else
            echo "Call log exists but contains no parseable entries: $log_path"
        fi
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
    tokens = r['estimated_output_tokens']
    print(f\"{r['cmd']:<24} {r['total_bytes']:>10,} {tokens:>10,} {r['calls']:>8} {avg_ms:>10}\")
reopen = d.get('reopen_count', 0)
if reopen:
    print(f\"\\nPattern E — reopen (update done→active): {reopen} time{'s' if reopen != 1 else ''}\")
win = d.get('window')
if win:
    print(f\"\\nWindow: since {win['since']}\")
exc = d.get('excluded') or {}
if exc.get('sync_calls'):
    mb = exc['sync_bytes'] / 1e6
    print(f\"Excluded: {exc['sync_calls']} sync-internal calls ({mb:.1f} MB pipeline stdout, never enters context) — --include-sync to count\")
if exc.get('test_calls'):
    mb = exc['test_bytes'] / 1e6
    print(f\"Excluded: {exc['test_calls']} suite-driven calls ({mb:.1f} MB test stdout) — --include-test to count\")
if exc.get('no_ts'):
    print(f\"Excluded: {exc['no_ts']} entries with no timestamp (cannot be windowed)\")
if d.get('note'):
    print(f\"Note: {d['note']}\")
"
    printf "\nLog: %s\n" "$log_path"
}

# cmd_analyze_gates — wall time per gate invocation (wv-ffda33). Reads the gate
# log the commit hooks write (one line per gate: phase, wall ms, estimate,
# suites, outcome) and reports per phase p50/p90/max wall time, how far the
# gate's own estimate was off, and which suites' estimates miss worst (from the
# suite log's estimate_ms). History from before gate records existed has no
# gate_id, so it is grouped by commit sha and labelled approximate, never mixed
# into the exact figures.
cmd_analyze_gates() {
    local suite_log gate_log want_json="" since="" all_repos=0 mode max_stall=""
    suite_log=$(_suite_log_path)
    gate_log=$(_gate_log_path)
    mode=$(wv_resolve_mode)
    local cur_repo=""
    cur_repo=$(basename "${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo "")}" 2>/dev/null || true)
    for arg in "$@"; do
        case "$arg" in
            --json)       want_json=1 ;;
            --since=*)    since="${arg#--since=}" ;;
            --all)        all_repos=1 ;;
            --log=*)      suite_log="${arg#--log=}" ;;
            --gate-log=*) gate_log="${arg#--gate-log=}" ;;
            --max-stall=*) max_stall="${arg#--max-stall=}" ;;
            --help|-h)
                echo "Usage: wv analyze gates [--since=YYYY-MM-DD] [--all] [--json] [--log=<suite log>] [--gate-log=<gate log>] [--max-stall=<share>]"
                echo ""
                echo "  Per phase (pre-commit, post-commit, make): gates, failures, wall time"
                echo "  p50/p90/max, suites per gate, and estimate error (actual / estimate)."
                echo "  Suites whose estimates miss worst come from the suite log's estimate_ms."
                echo "  Suite runs recorded before gate records existed are grouped by commit"
                echo "  and reported separately as approximate. Provisioning counts each route's"
                echo "  mode (frozen or checkout) from the newest gate record that names it."
                echo "  Host pressure: gates recorded with PSI stall deltas report the share of"
                echo "  wall time some task stalled on CPU and on IO (p50/p90); the gate's own"
                echo "  suites contend too, so a share is host load including the gate."
                echo "  --max-stall=<share> leaves out every gate whose CPU or IO share exceeds"
                echo "  it (0-1), and its suite runs; gates without a pressure record are kept"
                echo "  and counted as unmeasured."
                return 0
                ;;
        esac
    done
    if [ -n "$max_stall" ] && ! [[ "$max_stall" =~ ^(0(\.[0-9]+)?|1(\.0+)?)$ ]]; then
        echo "wv analyze gates: invalid --max-stall value: '$max_stall' (expected a share from 0 to 1)" >&2
        return 1
    fi
    [ "$mode" = "discover" ] || [ "$mode" = "bootstrap" ] && want_json=1
    local repo_filter=""
    [ "$all_repos" = "0" ] && repo_filter="$cur_repo"

    local result
    result=$(python3 - "$suite_log" "$gate_log" "$repo_filter" "$since" "$max_stall" <<'PYEOF'
import json, math, os, sys
from collections import defaultdict

suite_log, gate_log, repo_filter, since, max_stall = sys.argv[1:6]

def rows(path):
    if not os.path.isfile(path):
        return []
    out = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            try:
                e = json.loads(line)
            except (json.JSONDecodeError, ValueError):
                continue
            if repo_filter and str(e.get("repo", "")) != repo_filter:
                continue
            if since and str(e.get("ts", "")) < since:
                continue
            out.append(e)
    return out

def pct(vals, q):
    if not vals:
        return None
    s = sorted(vals)
    return s[max(0, min(len(s) - 1, math.ceil(q * len(s)) - 1))]

def secs(ms):
    return None if ms is None else round(ms / 1000, 1)

def num(v):
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else None

# Host pressure (wv-58b10e): a gate row's PSI stall shares, or None for rows
# written without them. --max-stall drops gates above the share from every
# figure, their suite runs included; unmeasured gates stay and are counted.
def stall(g, kind):
    p = g.get("pressure")
    return num(p.get(kind + "_some_share")) if isinstance(p, dict) else None

gates = rows(gate_log)
stall_filter = None
excluded_ids = set()
if max_stall:
    limit = float(max_stall)
    kept = []
    for g in gates:
        shares = [v for v in (stall(g, "cpu"), stall(g, "io")) if v is not None]
        if shares and max(shares) > limit:
            excluded_ids.add(str(g.get("gate_id", "")))
        else:
            kept.append(g)
    stall_filter = {"max_share": limit, "excluded": len(gates) - len(kept),
                    "unmeasured_kept": sum(1 for g in kept if stall(g, "cpu") is None)}
    gates = kept
by_phase = defaultdict(list)
for g in gates:
    by_phase[str(g.get("phase") or "unknown")].append(g)

def stall_stats(gs):
    cpu = [v for v in (stall(g, "cpu") for g in gs) if v is not None]
    io = [v for v in (stall(g, "io") for g in gs) if v is not None]
    return {"pressure_gates": len(cpu),
            "cpu_stall_p50": pct(cpu, 0.5), "cpu_stall_p90": pct(cpu, 0.9),
            "io_stall_p50": pct(io, 0.5), "io_stall_p90": pct(io, 0.9)}

# Candidate lanes (wv-3dbc11): they write no suite rows, so their time is read
# from the gate record. Rows written before it carry no lanes_ms and are left
# out of every lane figure, never counted as zero.
# Lane figures are segmented by scheduler revision (wv-428a92) and never
# blended: a gate's scheduler is the one its lane rows name, and rows written
# before lanes named one ran fixed shares of WV_GATE_JOBS. The top-level lane
# figures describe the newest revision in the window; lane_schedulers carries
# every revision on its own, so a before/after reads straight off it.
def lane_scheduler(g):
    for lane in g.get("lanes") or []:
        if isinstance(lane, dict) and lane.get("scheduler"):
            return str(lane["scheduler"])
    return "fixed-share"

def lane_figures(lg):
    lane_ms = [num(g["lanes_ms"]) for g in lg]
    walls = sum(int(g.get("duration_ms") or 0) for g in lg)
    prot = [num(g.get("protected_ms")) for g in lg if num(g.get("protected_ms")) is not None]
    return {
        "lane_gates": len(lg),
        "lanes_p50_s": secs(pct(lane_ms, 0.5)), "lanes_p90_s": secs(pct(lane_ms, 0.9)),
        "lanes_share_of_wall": round(sum(lane_ms) / walls, 2) if walls > 0 else None,
        "protected_p50_s": secs(pct(prot, 0.5)), "protected_p90_s": secs(pct(prot, 0.9)),
    }

def lane_stats(gs):
    lg = [g for g in gs if num(g.get("lanes_ms")) is not None]
    groups = defaultdict(list)
    for g in lg:
        groups[lane_scheduler(g)].append(g)
    revisions = sorted(groups, key=lambda s: max(str(g.get("ts", "")) for g in groups[s]))
    newest = revisions[-1] if revisions else None
    return {
        **lane_figures(groups[newest] if newest else []),
        "lane_scheduler": newest,
        "lane_schedulers": [{"scheduler": s, **lane_figures(groups[s])} for s in revisions],
    }

phases = []
for phase, gs in sorted(by_phase.items()):
    walls = [int(g.get("duration_ms") or 0) for g in gs]
    ratios = [int(g["duration_ms"]) / int(g["estimate_ms"]) for g in gs
              if g.get("estimate_ms") and int(g.get("estimate_ms") or 0) > 0]
    phases.append({
        "phase": phase,
        "gates": len(gs),
        "failed": sum(1 for g in gs if int(g.get("exit") or 0) != 0),
        "wall_p50_s": secs(pct(walls, 0.5)),
        "wall_p90_s": secs(pct(walls, 0.9)),
        "wall_max_s": secs(max(walls) if walls else None),
        "suites_p50": pct([len(g.get("suites") or []) for g in gs], 0.5),
        "estimate_ratio_p50": round(pct(ratios, 0.5), 2) if ratios else None,
        "estimated_gates": len(ratios),
        **lane_stats(gs),
        **stall_stats(gs),
    })

lane_paths = defaultdict(lambda: {"runs": 0, "reran": 0, "ms": 0})
for g in gates:
    for lane in g.get("lanes") or []:
        if not isinstance(lane, dict) or num(lane.get("ms")) is None:
            continue
        lp = lane_paths[str(lane.get("path"))]
        lp["runs"] += 1
        lp["reran"] += 0 if lane.get("reused") else 1
        lp["ms"] += num(lane["ms"])
costly_lanes = sorted(({"path": p, "runs": v["runs"], "reran": v["reran"], "total_s": secs(v["ms"]),
                        "mean_s": secs(v["ms"] / v["runs"])} for p, v in lane_paths.items()),
                      key=lambda x: x["total_s"] or 0, reverse=True)[:10]

suite_rows = [e for e in rows(suite_log)
              if not e.get("gate_id") or str(e["gate_id"]) not in excluded_ids]
miss = defaultdict(list)
for e in suite_rows:
    est = e.get("estimate_ms")
    if est and int(est) > 0 and int(e.get("duration_ms") or 0) > 0:
        miss[str(e.get("suite"))].append(int(e["duration_ms"]) / int(est))
worst = sorted(({"suite": s, "runs": len(r), "ratio_p50": round(pct(r, 0.5), 2)}
                for s, r in miss.items()), key=lambda x: abs(math.log(x["ratio_p50"] or 1)), reverse=True)[:10]

legacy = defaultdict(list)
for e in suite_rows:
    if not e.get("gate_id"):
        legacy[str(e.get("sha", ""))].append(int(e.get("duration_ms") or 0))
serial = [sum(v) for v in legacy.values()]
longest = [max(v) for v in legacy.values() if v]
approx = {
    "commits": len(legacy),
    "serial_p50_s": secs(pct(serial, 0.5)), "serial_p90_s": secs(pct(serial, 0.9)),
    "serial_max_s": secs(max(serial) if serial else None),
    "longest_suite_p50_s": secs(pct(longest, 0.5)), "longest_suite_p90_s": secs(pct(longest, 0.9)),
    "note": "suite runs without gate_id grouped by sha; mixes phases, so approximate",
}
# Provisioning (transition rule 5, wv-0ee3f4): each route's mode from the
# newest gate record that names it. Records written before gate records carried
# provisioning are counted, not guessed from the gate-wide execution_mode.
latest = {}
recorded = 0
for g in sorted(gates, key=lambda x: str(x.get("ts", ""))):
    modes = g.get("provisioning")
    if not isinstance(modes, dict):
        continue
    recorded += 1
    for suite, m in modes.items():
        if m in ("frozen", "checkout"):
            latest[str(suite)] = m
checkout_routes = sorted(s for s, m in latest.items() if m == "checkout")
provisioning = {
    "routes": len(latest), "frozen": sum(1 for m in latest.values() if m == "frozen"),
    "checkout": len(checkout_routes), "checkout_routes": checkout_routes,
    "gates_recorded": recorded, "gates_without_record": len(gates) - recorded,
}
print(json.dumps({"phases": phases, "estimate_misses": worst, "approximate_by_commit": approx,
                  "provisioning": provisioning, "costly_lanes": costly_lanes, "stall_filter": stall_filter,
                  "gate_log": gate_log, "suite_log": suite_log,
                  "repo": repo_filter or "ALL", "since": since or None}))
PYEOF
    ) || return 1

    if [ -n "$want_json" ]; then
        echo "$result"
        return 0
    fi
    echo "$result" | jq -r '
        "Gate wall time (\(.repo)\(if .since then ", since \(.since)" else "" end))",
        (if .stall_filter then "  leaving out \(.stall_filter.excluded) gate(s) whose CPU or IO stall exceeded \(.stall_filter.max_share * 100 | floor)% of wall; \(.stall_filter.unmeasured_kept) kept without a pressure record" else empty end),
        (if (.phases | length) == 0 then "  no gate records yet: the commit hooks write them from now on"
         else (.phases[] | "  \(.phase): \(.gates) gates, \(.failed) failed, wall p50 \(.wall_p50_s)s p90 \(.wall_p90_s)s max \(.wall_max_s)s, suites p50 \(.suites_p50)" +
               (if .estimate_ratio_p50 then ", actual/estimate p50 \(.estimate_ratio_p50)" else "" end) +
               (if (.pressure_gates // 0) > 0 then "\n    host stall over \(.pressure_gates) gates: CPU p50 \(.cpu_stall_p50 * 100 | floor)% p90 \(.cpu_stall_p90 * 100 | floor)%, IO p50 \(.io_stall_p50 * 100 | floor)% p90 \(.io_stall_p90 * 100 | floor)% of wall" else "" end) +
               ([(.lane_schedulers // [])[] | "\n    candidate lanes (\(.scheduler)) in \(.lane_gates) gates: lanes p50 \(.lanes_p50_s)s p90 \(.lanes_p90_s)s, \((.lanes_share_of_wall // 0) * 100 | floor)% of their wall; protected pass p50 \(.protected_p50_s)s p90 \(.protected_p90_s)s"] | join(""))) end),
        "",
        (if (.costly_lanes | length) > 0 then "Candidate lanes costing most (total over the window):",
            (.costly_lanes[] | "  \(.path) \(.total_s)s over \(.runs) lanes, \(.reran) reran their suites"), "" else empty end),
        "Suites whose estimates miss worst (actual/estimate, p50):",
        (if (.estimate_misses | length) == 0 then "  none recorded yet"
         else (.estimate_misses[] | "  \(.suite) \(.ratio_p50)x over \(.runs) runs") end),
        "",
        "Approximate, from suite runs recorded before gate ids (grouped by commit):",
        "  \(.approximate_by_commit.commits) commits, serial p50 \(.approximate_by_commit.serial_p50_s)s p90 \(.approximate_by_commit.serial_p90_s)s max \(.approximate_by_commit.serial_max_s)s; longest suite p50 \(.approximate_by_commit.longest_suite_p50_s)s p90 \(.approximate_by_commit.longest_suite_p90_s)s",
        "",
        "Provisioning mode per route (newest gate record naming it):",
        (if .provisioning.gates_recorded == 0 then "  no gate record carries per-route modes yet"
         else "  \(.provisioning.routes) routes: \(.provisioning.frozen) frozen, \(.provisioning.checkout) in checkout mode (from \(.provisioning.gates_recorded) gate records)" end),
        (.provisioning.checkout_routes[] | "    checkout: \(.)")'
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
                           "total_ms": 0, "_durs": [], "_mono": [], "_legacy": [],
                           "last_ts": "", "last_sha": ""})

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
            # The estimate's sample (wv-b17a85): runs timed on the monotonic
            # clock, which leaves out a suspend. Rows from before rows carried
            # a clock are kept apart; a row on any other clock is never used.
            if dur > 0:
                clock = e.get("clock")
                if clock == "monotonic":
                    a["_mono"].append(dur)
                elif clock is None:
                    a["_legacy"].append(dur)
            ts = str(e.get("ts", ""))
            if ts >= a["last_ts"]:           # ISO-8601 sorts lexicographically
                a["last_ts"] = ts
                a["last_sha"] = str(e.get("sha", ""))
except OSError as exc:
    print(json.dumps({"error": str(exc)}))
    sys.exit(1)

def median(vals):
    return sorted(vals)[len(vals) // 2] if vals else 0

suites = []
total_runs = 0
for suite, a in agg.items():
    total_runs += a["runs"]
    # A suite with any monotonic run is estimated from those alone; one with
    # none yet falls back to its unlabelled history until it has one, so the
    # cutover does not make every suite look unmeasured (launched first).
    basis = "monotonic" if a["_mono"] else ("legacy" if a["_legacy"] else "none")
    sample = a["_mono"] or a["_legacy"]
    suites.append({
        "suite": suite,
        "runs": a["runs"],
        "passed": a["passed"],
        "failed": a["failed"],
        "total_ms": a["total_ms"],
        "avg_ms": a["total_ms"] // a["runs"] if a["runs"] else 0,
        "p95_ms": p95(a["_durs"]),
        # Median of measured runs only: 0 is the "unmeasured" sentinel, and the
        # gate's estimates read this field (wv-ffda33). Its sample is
        # estimate_basis: monotonic runs, else unlabelled legacy runs, never a
        # run labelled wall, boottime or unknown (wv-b17a85).
        "p50_ms": median(sample),
        # The same median over the last 10 measured runs (log order): an
        # all-history median lags a suite that is growing, and quoted
        # test-hooks.sh at ~173s while it was running 480-700s (wv-8138ec).
        "recent_p50_ms": median(sample[-10:]),
        "estimate_basis": basis,
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
