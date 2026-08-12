"""Portable, observational evaluator for WV_CALL_LOG JSONL.

Rows are grouped by the first non-empty ``trace_id``, ``workflow_id``, or
``call_id`` and ordered by numeric ``ts`` (missing/invalid timestamps sort
after timestamped rows), then input position.  A retry is a later call with
the same normalized ``cmd`` plus ``argv`` while a nonzero attempt remains
pending.  The first nonzero attempt starts one remediation episode; every
later same-signature call while pending is a remediation call and retry, and
a zero exit recovers that episode.

Repeated query/context state is observed only when the previous same-signature
call's graph identity after and the current identity before are comparable
``sqlite_graph_fingerprint`` objects and equal.  Unequal comparable objects
are changed observations; missing, unavailable, or structurally mismatched
objects are unavailable comparisons.  Counts are measurements, not policy
judgments. Optional canonical host-usage JSONL is joined by trace identity;
stable incremental event IDs prevent replay from double-counting actual usage.
"""

from __future__ import annotations

import argparse
import json
import math
import re
from collections import defaultdict
from pathlib import Path
from typing import Any

FORMAT = "weave.trace-observations"
VERSION = 1
USAGE_FORMAT = "weave.provider-usage"
USAGE_VERSION = 1
REDACTION_MARKER = re.compile(r"(?:^|=)<redacted:[0-9]+>$")
USAGE_TOKEN_FIELDS = (
    "input_tokens",
    "output_tokens",
    "cache_read_input_tokens",
    "cache_creation_input_tokens",
)
USAGE_PROVENANCE_FIELDS = ("host", "adapter", "adapter_version", "provider", "model")
GRAPH_FINGERPRINT = re.compile(r"sha256:[0-9a-f]{64}")


def _nonempty(row: dict[str, Any], name: str) -> str | None:
    value = row.get(name)
    return value if isinstance(value, str) and value else None


def _signature(row: dict[str, Any]) -> str | None:
    cmd = row.get("cmd")
    argv = row.get("argv")
    if not isinstance(cmd, str) or not cmd.strip() or not isinstance(argv, list):
        return None
    if not all(isinstance(item, str) for item in argv):
        return None
    if any(REDACTION_MARKER.search(item) for item in argv):
        # Redacted values preserve only byte length. Distinct same-length inputs
        # therefore cannot honestly be identified as retries or repeated calls.
        return None
    return json.dumps([" ".join(cmd.split()), argv], separators=(",", ":"), ensure_ascii=True)


def _identity(value: Any) -> tuple[str, str] | None:
    if not isinstance(value, dict):
        return None
    fingerprint = value.get("value")
    if (
        value.get("kind") != "sqlite_graph_fingerprint"
        or not isinstance(fingerprint, str)
        or GRAPH_FINGERPRINT.fullmatch(fingerprint) is None
    ):
        return None
    return (value["kind"], fingerprint)


def _new_counts() -> dict[str, Any]:
    return {
        "calls": {"total": 0, "signature_available": 0, "signature_unavailable": 0},
        "output_estimate": {
            "stdout_bytes": 0,
            "stdout_bytes_available": 0,
            "stdout_bytes_unavailable": 0,
            "estimated_output_tokens": None,
        },
        "turns": {"distinct": None, "missing_turn_calls": 0},
        "exits": {"available": 0, "unavailable": 0, "nonzero": 0},
        "retries": 0,
        "state": {
            "before_available": 0,
            "before_unavailable": 0,
            "after_available": 0,
            "after_unavailable": 0,
            "unchanged_calls": 0,
            "changed_calls": 0,
            "repeated_query_context": 0,
            "query_context_comparisons_available": 0,
            "query_context_comparisons_unavailable": 0,
        },
        "remediation": {"episodes": 0, "recovered": 0, "unrecovered": 0, "calls": 0},
    }


def _record_output_and_turn(out: dict[str, Any], row: dict[str, Any], turns: set[str]) -> None:
    stdout_bytes = row.get("stdout_bytes")
    if isinstance(stdout_bytes, int) and not isinstance(stdout_bytes, bool) and stdout_bytes >= 0:
        out["output_estimate"]["stdout_bytes"] += stdout_bytes
        out["output_estimate"]["stdout_bytes_available"] += 1
    else:
        out["output_estimate"]["stdout_bytes_unavailable"] += 1
    turn = _nonempty(row, "turn_id")
    if turn is None:
        out["turns"]["missing_turn_calls"] += 1
    else:
        turns.add(turn)


def _record_state_observation(
    out: dict[str, Any],
    row: dict[str, Any],
    signature: str | None,
    prior_after: dict[str, Any],
) -> None:
    before = _identity(row.get("graph_identity_before"))
    after = _identity(row.get("graph_identity_after"))
    out["state"]["before_available" if before else "before_unavailable"] += 1
    out["state"]["after_available" if after else "after_unavailable"] += 1
    if before is not None and after is not None:
        out["state"]["unchanged_calls" if before == after else "changed_calls"] += 1

    if signature is not None and row.get("cmd") in {"wv query", "wv context"} and signature in prior_after:
        previous = _identity(prior_after[signature])
        if previous is not None and before is not None:
            out["state"]["query_context_comparisons_available"] += 1
            if previous == before:
                out["state"]["repeated_query_context"] += 1
        else:
            out["state"]["query_context_comparisons_unavailable"] += 1
    if signature is not None and row.get("cmd") in {"wv query", "wv context"}:
        prior_after[signature] = row.get("graph_identity_after")


def _measure(rows: list[dict[str, Any]]) -> dict[str, Any]:
    out = _new_counts()
    turns: set[str] = set()
    pending: set[str] = set()
    prior_after: dict[str, Any] = {}
    for row in rows:
        out["calls"]["total"] += 1
        _record_output_and_turn(out, row, turns)
        signature = _signature(row)
        out["calls"]["signature_available" if signature else "signature_unavailable"] += 1
        _record_state_observation(out, row, signature, prior_after)

        exit_status = row.get("exit_status")
        if not isinstance(exit_status, int) or isinstance(exit_status, bool):
            out["exits"]["unavailable"] += 1
            if signature is not None and signature in pending:
                out["retries"] += 1
                out["remediation"]["calls"] += 1
            continue
        out["exits"]["available"] += 1
        if exit_status != 0:
            out["exits"]["nonzero"] += 1
        if signature is None:
            continue
        if signature in pending:
            out["retries"] += 1
            out["remediation"]["calls"] += 1
            if exit_status == 0:
                pending.remove(signature)
                out["remediation"]["recovered"] += 1
        elif exit_status != 0:
            pending.add(signature)
            out["remediation"]["episodes"] += 1

    out["turns"]["distinct"] = len(turns) if turns else None
    out["remediation"]["unrecovered"] = len(pending)
    if out["output_estimate"]["stdout_bytes_available"]:
        out["output_estimate"]["estimated_output_tokens"] = out["output_estimate"]["stdout_bytes"] // 4
    return out


def _aggregate(measurements: list[dict[str, Any]]) -> dict[str, Any]:
    """Sum trace-local measurements without linking signatures across traces."""
    out = _new_counts()
    turn_total = 0
    turns_available = False
    for measured in measurements:
        for key in out["calls"]:
            out["calls"][key] += measured["calls"][key]
        for key in out["output_estimate"]:
            if key != "estimated_output_tokens":
                out["output_estimate"][key] += measured["output_estimate"][key]
        for key in out["exits"]:
            out["exits"][key] += measured["exits"][key]
        for key in out["state"]:
            out["state"][key] += measured["state"][key]
        for key in out["remediation"]:
            out["remediation"][key] += measured["remediation"][key]
        out["retries"] += measured["retries"]
        out["turns"]["missing_turn_calls"] += measured["turns"]["missing_turn_calls"]
        if measured["turns"]["distinct"] is not None:
            turns_available = True
            turn_total += measured["turns"]["distinct"]
    out["turns"]["distinct"] = turn_total if turns_available else None
    if out["output_estimate"]["stdout_bytes_available"]:
        out["output_estimate"]["estimated_output_tokens"] = out["output_estimate"]["stdout_bytes"] // 4
    return out


def _normalize_usage_metrics(usage: dict[str, Any]) -> dict[str, int | float | None] | None:
    """Return canonical finite metrics, preserving unavailable dimensions as null."""
    normalized_usage: dict[str, int | float | None] = {}
    for field in USAGE_TOKEN_FIELDS:
        value = usage.get(field)
        if value is None:
            normalized_usage[field] = None
        elif isinstance(value, int) and not isinstance(value, bool) and value >= 0:
            normalized_usage[field] = value
        else:
            return None
    cost = usage.get("cost_usd")
    if cost is None:
        normalized_usage["cost_usd"] = None
    elif isinstance(cost, (int, float)) and not isinstance(cost, bool) and cost >= 0:
        try:
            normalized_cost = float(cost)
        except (OverflowError, ValueError):
            return None
        if not math.isfinite(normalized_cost):
            return None
        normalized_usage["cost_usd"] = normalized_cost
    else:
        return None
    return normalized_usage


def _usage_event(raw: Any) -> tuple[str | None, dict[str, Any] | None, str | None]:
    """Normalize one canonical host-usage row without inventing absent values."""
    if not isinstance(raw, dict):
        return None, None, "non_object"
    trace_id = _nonempty(raw, "trace_id") or _nonempty(raw, "workflow_id") or _nonempty(raw, "call_id")
    event_id = _nonempty(raw, "usage_event_id")
    provenance = raw.get("provenance")
    usage = raw.get("usage")
    version = raw.get("version")
    if (
        raw.get("format") != USAGE_FORMAT
        or not isinstance(version, int)
        or isinstance(version, bool)
        or version != USAGE_VERSION
    ):
        return None, None, "unsupported_format"
    if trace_id is None:
        return None, None, "missing_trace_id"
    if event_id is None:
        return None, None, "missing_usage_event_id"
    if raw.get("usage_kind") != "incremental":
        return None, None, "unsupported_usage_kind"
    if not isinstance(provenance, dict) or not isinstance(usage, dict):
        return None, None, "invalid_shape"
    if any(_nonempty(provenance, field) is None for field in USAGE_PROVENANCE_FIELDS):
        return None, None, "invalid_provenance"
    normalized_usage = _normalize_usage_metrics(usage)
    if normalized_usage is None:
        return None, None, "invalid_usage_metrics"
    normalized_provenance = {field: provenance[field] for field in USAGE_PROVENANCE_FIELDS}
    return trace_id, {"usage_event_id": event_id, "provenance": normalized_provenance,
                      "usage": normalized_usage}, None


def _provider_usage(events: list[dict[str, Any]]) -> dict[str, Any]:
    """Aggregate actual host usage while retaining each provider provenance group."""
    if not events:
        return {
            "status": "unavailable",
            "reason": "no matching provider usage events",
            "matched_events": 0,
            "groups": [],
        }
    grouped: dict[str, dict[str, Any]] = {}
    metric_fields = (*USAGE_TOKEN_FIELDS, "cost_usd")
    any_measurement = False
    for event in events:
        provenance = event["provenance"]
        key = json.dumps(provenance, sort_keys=True, separators=(",", ":"))
        if key not in grouped:
            grouped[key] = {
                "provenance": provenance,
                "events": 0,
                "measurements": {
                    field: {"value": None, "available_events": 0, "unavailable_events": 0}
                    for field in metric_fields
                },
            }
        group = grouped[key]
        group["events"] += 1
        for field in metric_fields:
            value = event["usage"][field]
            measurement = group["measurements"][field]
            if value is None:
                measurement["unavailable_events"] += 1
            else:
                measurement["available_events"] += 1
                any_measurement = True
                if "aggregation_error" in measurement:
                    continue
                if measurement["value"] is None:
                    measurement["value"] = 0.0 if field == "cost_usd" else 0
                candidate = measurement["value"] + value
                if field == "cost_usd" and not math.isfinite(candidate):
                    measurement["value"] = None
                    measurement["aggregation_error"] = "non-finite aggregate"
                else:
                    measurement["value"] = candidate
    return {
        "status": "available" if any_measurement else "unavailable",
        **({} if any_measurement else {"reason": "matching events expose no usage metrics"}),
        "matched_events": len(events),
        "groups": [grouped[key] for key in sorted(grouped)],
    }


def _usage_accounting() -> dict[str, Any]:
    return {
        "input_lines": 0,
        "blank_lines": 0,
        "malformed_json": 0,
        "invalid_rows": 0,
        "duplicate_rows": 0,
        "conflicting_duplicate_rows": 0,
        "valid_rows": 0,
        "unmatched_rows": 0,
        "invalid_reasons": {},
    }


def _record_invalid_usage(accounting: dict[str, Any], reason: str | None) -> None:
    accounting["invalid_rows"] += 1
    invalid_reasons = accounting["invalid_reasons"]
    key = reason or "invalid_row"
    invalid_reasons[key] = invalid_reasons.get(key, 0) + 1


def _read_usage(path: Path) -> tuple[dict[str, list[dict[str, Any]]], dict[str, Any]]:
    grouped: defaultdict[str, list[dict[str, Any]]] = defaultdict(list)
    accounting = _usage_accounting()
    events_by_id: defaultdict[str, list[tuple[str, dict[str, Any]]]] = defaultdict(list)
    with path.open(encoding="utf-8") as stream:
        for line in stream:
            accounting["input_lines"] += 1
            if not line.strip():
                accounting["blank_lines"] += 1
                continue
            try:
                raw = json.loads(line)
            except (json.JSONDecodeError, ValueError):
                accounting["malformed_json"] += 1
                continue
            trace_id, normalized, reason = _usage_event(raw)
            if reason is not None or trace_id is None or normalized is None:
                _record_invalid_usage(accounting, reason)
                continue
            event_id = normalized["usage_event_id"]
            events_by_id[event_id].append((trace_id, normalized))

    for event_id in sorted(events_by_id):
        occurrences = events_by_id[event_id]
        first = occurrences[0]
        if any(occurrence != first for occurrence in occurrences[1:]):
            accounting["conflicting_duplicate_rows"] += len(occurrences)
            continue
        trace_id, normalized = first
        grouped[trace_id].append(normalized)
        accounting["valid_rows"] += 1
        accounting["duplicate_rows"] += len(occurrences) - 1
    return dict(grouped), accounting


def evaluate(path: Path, usage_path: Path | None = None) -> dict[str, Any]:
    """Read *path* and return deterministic raw trace observations."""
    grouped: defaultdict[str, list[tuple[float | None, int, dict[str, Any]]]] = defaultdict(list)
    accounting = {"input_lines": 0, "blank_lines": 0, "malformed_json": 0, "non_object_rows": 0,
                  "rows_missing_group_id": 0, "rows_observed": 0, "rows_missing_or_invalid_ts": 0}
    with path.open(encoding="utf-8") as stream:
        for position, line in enumerate(stream):
            accounting["input_lines"] += 1
            if not line.strip():
                accounting["blank_lines"] += 1
                continue
            try:
                raw = json.loads(line)
            except (json.JSONDecodeError, ValueError):
                accounting["malformed_json"] += 1
                continue
            if not isinstance(raw, dict):
                accounting["non_object_rows"] += 1
                continue
            group = _nonempty(raw, "trace_id") or _nonempty(raw, "workflow_id") or _nonempty(raw, "call_id")
            if group is None:
                accounting["rows_missing_group_id"] += 1
                continue
            ts_raw = raw.get("ts")
            try:
                ts = float(ts_raw) if ts_raw is not None and not isinstance(ts_raw, bool) else None
            except (TypeError, ValueError):
                ts = None
            if ts is not None and not math.isfinite(ts):
                ts = None
            if ts is None:
                accounting["rows_missing_or_invalid_ts"] += 1
            grouped[group].append((ts, position, raw))
            accounting["rows_observed"] += 1

    usage_by_trace: dict[str, list[dict[str, Any]]] = {}
    usage_accounting: dict[str, Any] = {
        "status": "unavailable",
        "reason": "no provider usage log supplied",
        "log": None,
    }
    if usage_path is not None:
        usage_by_trace, usage_counts = _read_usage(usage_path)
        usage_accounting = {"status": "available", "log": str(usage_path), **usage_counts}

    traces: list[dict[str, Any]] = []
    trace_measurements: list[dict[str, Any]] = []
    matched_usage: list[dict[str, Any]] = []
    for trace_id in sorted(grouped):
        ordered = sorted(grouped[trace_id], key=lambda item: (item[0] is None, item[0] or 0.0, item[1]))
        measured = _measure([item[2] for item in ordered])
        trace_measurements.append(measured)
        usage_events = usage_by_trace.get(trace_id, [])
        matched_usage.extend(usage_events)
        traces.append({"trace_id": trace_id, "observations": measured,
                       "provider_usage": _provider_usage(usage_events)})
    if usage_path is not None:
        usage_accounting["unmatched_rows"] = sum(
            len(events) for trace_id, events in usage_by_trace.items() if trace_id not in grouped
        )
    return {"format": FORMAT, "version": VERSION, "input": {"log": str(path), **accounting},
            "usage_input": usage_accounting, "observations": _aggregate(trace_measurements),
            "provider_usage": _provider_usage(matched_usage), "traces": traces}


def main() -> int:
    """Run the JSONL evaluator CLI."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", required=True, type=Path, help="WV_CALL_LOG-compatible JSONL")
    parser.add_argument("--usage-log", type=Path,
                        help="canonical host provider-usage JSONL joined by trace/workflow/call ID")
    args = parser.parse_args()
    try:
        result = evaluate(args.log, args.usage_log)
    except OSError as exc:
        parser.error(str(exc))
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
