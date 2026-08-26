"""Observe auto-checkpoint commits against the wv calls that were in flight.

The auto-checkpointer makes a git commit after sync (``WV_AUTO_CHECKPOINT``,
throttled by ``WV_CHECKPOINT_INTERVAL``). That moves ``HEAD`` underneath anything
whose correctness spans two HEAD reads -- the E6 runner requires subject and
fresh-clone HEAD to match, and refuses when they diverge. The failure surfaces as
a generic mismatch, so each encounter has been diagnosed from scratch.

This needs no new emission. Checkpoint commits are dated in git history, and
every wv invocation already records ``ts`` and ``elapsed_ms`` in the call log, so
"which calls were running when this checkpoint landed" is answerable from
signals that exist today. Reading rather than instrumenting also keeps this out
of ``scripts/cmd`` and ``scripts/lib``, where a change would invalidate the six
E6 receipts and owe a recapture.

Observational only: an overlap is not a failure. It is the window in which one
becomes possible, which is the thing worth counting before designing a lock.

Usage:
    python3 profiling/checkpoint_overlap.py [--days N] [--log PATH] [--json]
"""

from __future__ import annotations

import argparse
import bisect
import json
import statistics
import subprocess
import sys
from collections import Counter
from pathlib import Path
from typing import Any

CHECKPOINT_MARKER = "auto-checkpoint"
DEFAULT_LOG = Path.home() / ".local/share/weave/wv_calls.jsonl"

# A checkpoint fires from auto_sync, which mutating commands invoke. Such a
# command therefore ENCLOSES the checkpoint it caused, and counting that as a
# collision inflates the rate to near 100% while saying nothing.
#
# The call log carries no pid, so enclosing and concurrent cannot be separated
# for a mutating command. They can for a read-only one: it never triggers
# auto_sync, so a checkpoint inside it necessarily came from another process.
# That subset is the honest signal, and it is the one this reports first.
TRIGGERING_COMMANDS = {
    "wv sync", "wv done", "wv add", "wv update", "wv quick", "wv work",
    "wv touch", "wv link", "wv unlink", "wv block", "wv resolve", "wv delete",
    "wv ship", "wv batch-done", "wv load", "wv record-edit", "wv unarchive",
}


def classification(cmd: str) -> str:
    """Whether an overlap could be the call's own checkpoint, or must be another process."""
    return "ambiguous" if cmd.strip() in TRIGGERING_COMMANDS else "necessarily_concurrent"


# git resolves "<N> days ago" against the epoch, and a window wide enough to
# reach before it yields NO commits rather than all of them -- a silent empty
# result that reads as "no checkpoints" instead of "bad window". Clamped, and
# the clamp is reported.
MAX_WINDOW_DAYS = 3650


def checkpoint_commits(repo: Path, days: int) -> list[dict[str, Any]]:
    """Every auto-checkpoint commit in the window, oldest first."""
    days = min(days, MAX_WINDOW_DAYS)
    result = subprocess.run(
        ["git", "log", f"--since={days} days ago", "--format=%H|%ct|%s"],
        cwd=repo, capture_output=True, text=True, check=False,
    )
    if result.returncode != 0:
        raise SystemExit(f"git log failed in {repo}: {result.stderr.strip()}")
    commits = []
    for line in result.stdout.splitlines():
        sha, _, rest = line.partition("|")
        ts, _, subject = rest.partition("|")
        if CHECKPOINT_MARKER in subject:
            commits.append({"sha": sha[:12], "ts": int(ts), "subject": subject})
    commits.reverse()
    return commits


def load_calls(log_path: Path, since: float) -> list[dict[str, Any]]:
    """Call rows in the window, with a usable start and duration.

    A row without both is not skipped quietly -- it is counted, because a
    measurement that silently drops its own inputs cannot be trusted about
    what it did not find.
    """
    calls: list[dict[str, Any]] = []
    unusable = 0
    with log_path.open(encoding="utf-8", errors="replace") as handle:
        for line in handle:
            if not line.strip():
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                unusable += 1
                continue
            ts, elapsed = row.get("ts"), row.get("elapsed_ms")
            if not isinstance(ts, (int, float)) or not isinstance(elapsed, (int, float)):
                unusable += 1
                continue
            if ts + elapsed / 1000.0 < since:
                continue
            calls.append({
                "start": float(ts),
                "end": float(ts) + float(elapsed) / 1000.0,
                "cmd": str(row.get("cmd", "?")),
                "source": str(row.get("source", "?")),
                "exit_status": row.get("exit_status"),
            })
    calls.sort(key=lambda c: c["start"])
    return calls, unusable  # type: ignore[return-value]


def overlapping(calls: list[dict[str, Any]], starts: list[float], moment: float) -> list[dict[str, Any]]:
    """Calls whose [start, end] window contains `moment`.

    Scans back from the insertion point rather than filtering the whole list:
    the log runs to hundreds of thousands of rows, and a checkpoint only ever
    overlaps calls that began before it.
    """
    index = bisect.bisect_right(starts, moment)
    hits = []
    for candidate in reversed(calls[:index]):
        if candidate["end"] >= moment:
            hits.append(candidate)
        # Calls are start-ordered, so an early start with a short duration says
        # nothing about earlier ones; keep walking. Bounded by the longest call
        # we care about rather than by the whole history.
        if moment - candidate["start"] > 3600:
            break
    return hits


def report(repo: Path, log_path: Path, days: int) -> dict[str, Any]:
    clamped = min(days, MAX_WINDOW_DAYS)
    commits = checkpoint_commits(repo, days)
    if not commits:
        return {"checkpoints": 0, "window_days": clamped, "note": "no auto-checkpoint commits in window"}

    since = min(c["ts"] for c in commits) - 3600
    calls, unusable = load_calls(log_path, since)
    starts = [c["start"] for c in calls]

    intervals = [b["ts"] - a["ts"] for a, b in zip(commits, commits[1:])]
    collisions: list[dict[str, Any]] = []
    concurrent: list[dict[str, Any]] = []
    by_command: Counter[str] = Counter()
    for commit in commits:
        hits = overlapping(calls, starts, float(commit["ts"]))
        if not hits:
            continue
        entry = {
            "checkpoint": commit["sha"],
            "ts": commit["ts"],
            "in_flight": [
                {"cmd": h["cmd"], "source": h["source"],
                 "kind": classification(h["cmd"]),
                 "seconds_into_call": round(commit["ts"] - h["start"], 1),
                 "call_seconds": round(h["end"] - h["start"], 1)}
                for h in hits
            ],
        }
        collisions.append(entry)
        for hit in entry["in_flight"]:
            by_command[hit["cmd"]] += 1
        if any(h["kind"] == "necessarily_concurrent" for h in entry["in_flight"]):
            concurrent.append(entry)

    summary: dict[str, Any] = {
        "window_days": clamped,
        "window_clamped": clamped != days,
        "checkpoints": len(commits),
        "calls_considered": len(calls),
        "unusable_log_rows": unusable,
        "checkpoints_overlapping_a_call": len(collisions),
        "overlap_rate": round(len(collisions) / len(commits), 3),
        "checkpoints_inside_a_read_only_call": len(concurrent),
        "concurrent_rate": round(len(concurrent) / len(commits), 3),
        "commands_caught_in_flight": by_command.most_common(10),
    }
    if intervals:
        summary["interval_seconds"] = {
            "min": min(intervals),
            "median": int(statistics.median(intervals)),
            "max": max(intervals),
            "under_throttle_600s": sum(1 for i in intervals if i < 600),
        }
    # Exposure by duration is the actionable form. The checkpointer fires at a
    # roughly steady rate during active work, so an operation of D seconds is
    # exposed for D seconds: P(collision) ~= D / mean_interval. It is what says
    # whether an operation is long enough to be worth quiescing, rather than
    # leaving that to taste.
    if intervals:
        # MEDIAN, not mean: the mean is dragged upward by multi-day idle gaps
        # (this repository has seen 4-day ones), which understates exposure
        # exactly when it matters -- during a dense working session, when both
        # checkpoints and long operations are frequent.
        typical = statistics.median(intervals)
    if intervals and typical > 0:
        summary["exposure"] = {
            "median_interval_seconds": int(typical),
            "mean_interval_seconds": int(sum(intervals) / len(intervals)),
            "basis": "median interval; the mean is skewed by idle gaps and understates active sessions",
            "collision_probability": {
                f"{d}s": round(min(d / typical, 1.0), 3)
                for d in (30, 90, 300, 600)
            },
        }
    elif intervals:
        # Every checkpoint in the same second: a real shape in a burst or a
        # synthetic fixture, and one no rate can describe. Say so rather than
        # divide by it.
        summary["exposure"] = {
            "median_interval_seconds": 0,
            "mean_interval_seconds": int(sum(intervals) / len(intervals)),
            "basis": "checkpoints share a timestamp; an interval-based rate is undefined",
            "collision_probability": {},
        }
    summary["collisions"] = collisions
    return summary


def render(summary: dict[str, Any]) -> str:
    if not summary.get("checkpoints"):
        return summary.get("note", "no checkpoints found")
    lines = [
        f"auto-checkpoints in {summary['window_days']}d: {summary['checkpoints']}",
        f"  wv calls considered: {summary['calls_considered']}"
        + (f" ({summary['unusable_log_rows']} unusable rows)" if summary["unusable_log_rows"] else ""),
    ]
    interval = summary.get("interval_seconds")
    if interval:
        lines.append(
            f"  interval s: min={interval['min']} median={interval['median']} max={interval['max']}"
            f" (under 600s throttle: {interval['under_throttle_600s']})"
        )
    lines.append(
        f"  landing inside any running call: {summary['checkpoints_overlapping_a_call']}"
        f" ({summary['overlap_rate']:.1%}) — mostly the command that caused them"
    )
    lines.append(
        f"  landing inside a READ-ONLY call (necessarily another process):"
        f" {summary['checkpoints_inside_a_read_only_call']}"
        f" ({summary['concurrent_rate']:.1%})"
    )
    exposure = summary.get("exposure")
    if exposure:
        odds = "  ".join(f"{d}={p:.1%}" for d, p in exposure["collision_probability"].items())
        lines.append(
            f"  exposure by operation length (median interval {exposure['median_interval_seconds']}s,"
            f" mean {exposure['mean_interval_seconds']}s skewed by idle): {odds}"
        )
        lines.append("  quiesce with WV_AUTO_CHECKPOINT=0 for anything that must hold HEAD still")
    if summary["commands_caught_in_flight"]:
        lines.append("  commands most often in flight:")
        for cmd, count in summary["commands_caught_in_flight"]:
            lines.append(f"    {count:4}  {cmd}")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__.splitlines()[0],
        epilog=(
            "Precondition this measures the need for: run anything that must hold HEAD still "
            "under WV_AUTO_CHECKPOINT=0. The checkpointer commits after sync, and an operation "
            "is exposed for as long as it runs.\n\n"
            "Overlap is reported in two forms. The headline counts every checkpoint landing "
            "inside a running call, and is close to 100% because a mutating command encloses "
            "the checkpoint it caused. The figure to read is the read-only subset: those calls "
            "never trigger a checkpoint, so one landing inside them came from another process.\n\n"
            "See docs/RUST-E6-DURABILITY-BATTERY.md, Recapture Preconditions."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--days", type=int, default=30,
                        help="History window; clamped to %d days because git returns nothing for a\n"
                             "window reaching before the epoch" % MAX_WINDOW_DAYS)
    parser.add_argument("--log", type=Path, default=DEFAULT_LOG,
                        help="WV_CALL_LOG JSONL; enable with: wv config enable session-analysis")
    parser.add_argument("--repo", type=Path, default=Path.cwd(),
                        help="Repository whose checkpoint commits are read (default: cwd)")
    parser.add_argument("--json", action="store_true",
                        help="Full report including every collision and its in-flight calls")
    args = parser.parse_args(argv)

    if not args.log.is_file():
        print(f"call log not found: {args.log}\nEnable it with: wv config enable session-analysis",
              file=sys.stderr)
        return 1

    summary = report(args.repo, args.log, args.days)
    print(json.dumps(summary, indent=2) if args.json else render(summary))
    return 0


if __name__ == "__main__":
    sys.exit(main())
