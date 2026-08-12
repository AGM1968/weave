import json
import math
from collections.abc import Sequence
from pathlib import Path

from profiling.audit_sessions import evaluate  # pylint: disable=import-error


IDENTITY_A = {"kind": "sqlite_graph_fingerprint", "value": "sha256:" + "a" * 64}
IDENTITY_B = {"kind": "sqlite_graph_fingerprint", "value": "sha256:" + "b" * 64}


def _write(tmp_path: Path, rows: Sequence[object]) -> Path:
    path = tmp_path / "calls.jsonl"
    path.write_text("\n".join(json.dumps(row) for row in rows) + "\n{bad\n", encoding="utf-8")
    return path


def test_state_retries_turns_and_fallback_grouping(tmp_path: Path) -> None:
    """Ordering, workflow fallback, retries, and repeated state are deterministic."""
    rows = [
        {"ts": 3, "workflow_id": "trace", "call_id": "c3", "turn_id": "t2", "cmd": "wv query",
         "argv": ["query", "x"], "exit_status": 0, "graph_identity_before": IDENTITY_A,
         "graph_identity_after": IDENTITY_A},
        {"ts": 1, "workflow_id": "trace", "call_id": "c1", "turn_id": "t1", "cmd": "wv query",
         "argv": ["query", "x"], "exit_status": 2, "graph_identity_before": IDENTITY_A,
         "graph_identity_after": IDENTITY_A},
        {"ts": 2, "workflow_id": "trace", "call_id": "c2", "cmd": "wv query",
         "argv": ["query", "x"], "exit_status": 2, "graph_identity_before": IDENTITY_B,
         "graph_identity_after": IDENTITY_A},
    ]
    result = evaluate(_write(tmp_path, rows))
    observed = result["traces"][0]["observations"]
    assert observed["retries"] == 2
    assert observed["remediation"] == {"episodes": 1, "recovered": 1, "unrecovered": 0, "calls": 2}
    assert observed["turns"] == {"distinct": 2, "missing_turn_calls": 1}
    assert observed["state"]["repeated_query_context"] == 1
    assert observed["state"]["query_context_comparisons_available"] == 2
    assert result["input"]["malformed_json"] == 1


def test_missing_fields_and_unavailable_identity_are_explicit(tmp_path: Path) -> None:
    """Legacy omissions remain unavailable rather than becoming zero observations."""
    unavailable = {"status": "unavailable", "reason": "old row"}
    rows = [
        {"trace_id": "t", "cmd": "wv context", "argv": [], "exit_status": 0,
         "graph_identity_after": unavailable},
        {"trace_id": "t", "cmd": "wv context", "argv": [], "graph_identity_before": IDENTITY_A},
        {"cmd": "wv status"},
    ]
    result = evaluate(_write(tmp_path, rows))
    observed = result["observations"]
    assert observed["exits"] == {"available": 1, "unavailable": 1, "nonzero": 0}
    assert observed["turns"] == {"distinct": None, "missing_turn_calls": 2}
    assert observed["state"]["query_context_comparisons_unavailable"] == 1
    assert observed["state"]["repeated_query_context"] == 0
    assert result["input"]["rows_missing_group_id"] == 1


def test_malformed_graph_fingerprints_are_unavailable(tmp_path: Path) -> None:
    """Only canonical full SHA-256 graph fingerprints are comparable."""
    malformed = ("", "sha256:a", "sha256:" + "A" * 64, "md5:" + "a" * 64)
    rows = []
    for index, fingerprint in enumerate(malformed):
        identity = {"kind": "sqlite_graph_fingerprint", "value": fingerprint}
        rows.append({"ts": index, "trace_id": "t", "cmd": "wv query", "argv": ["query"],
                     "exit_status": 0, "graph_identity_before": identity,
                     "graph_identity_after": identity})

    observed = evaluate(_write(tmp_path, rows))["observations"]["state"]

    assert observed["before_available"] == 0
    assert observed["after_available"] == 0
    assert observed["unchanged_calls"] == 0
    assert observed["repeated_query_context"] == 0


def test_redacted_signatures_and_nonfinite_timestamps_are_unavailable(tmp_path: Path) -> None:
    """Lossy values and non-finite timestamps never create exact-call observations."""
    rows = [
        {"ts": math.nan, "trace_id": "t", "cmd": "wv query", "argv": ["query", "<redacted:1>"],
         "exit_status": 2, "graph_identity_after": IDENTITY_A},
        {"ts": math.inf, "trace_id": "t", "cmd": "wv query", "argv": ["query", "<redacted:1>"],
         "exit_status": 0, "graph_identity_before": IDENTITY_A, "graph_identity_after": IDENTITY_A},
        {"ts": 1, "trace_id": "t", "cmd": "wv update",
         "argv": ["update", "wv-abc123", "--metadata=<redacted:4>"], "exit_status": 2},
        {"ts": 2, "trace_id": "t", "cmd": "wv update",
         "argv": ["update", "wv-abc123", "--metadata=<redacted:4>"], "exit_status": 0},
    ]
    result = evaluate(_write(tmp_path, rows))
    observed = result["observations"]
    assert observed["calls"] == {"total": 4, "signature_available": 0, "signature_unavailable": 4}
    assert observed["retries"] == 0
    assert observed["remediation"] == {"episodes": 0, "recovered": 0, "unrecovered": 0, "calls": 0}
    assert observed["state"]["repeated_query_context"] == 0
    assert result["input"]["rows_missing_or_invalid_ts"] == 2


def test_provider_usage_join_retains_provenance_and_availability(tmp_path: Path) -> None:
    """Actual usage stays distinct from output estimates and preserves its source."""
    calls = _write(tmp_path, [{"ts": 1, "trace_id": "t", "stdout_bytes": 9}])
    usage_path = tmp_path / "usage.jsonl"
    usage_path.write_text(
        "\n".join([
            json.dumps({
                "format": "weave.provider-usage",
                "version": 1,
                "trace_id": "t",
                "usage_event_id": "usage-1",
                "usage_kind": "incremental",
                "provenance": {"host": "codex", "adapter": "session-export",
                               "adapter_version": "1", "provider": "openai", "model": "gpt-test"},
                "usage": {"input_tokens": 10, "output_tokens": 2, "cache_read_input_tokens": 4},
            }),
            json.dumps({
                "format": "weave.provider-usage",
                "version": 1,
                "trace_id": "other",
                "usage_event_id": "usage-2",
                "usage_kind": "incremental",
                "provenance": {"host": "claude-code", "adapter": "session-export",
                               "adapter_version": "1", "provider": "anthropic", "model": "test"},
                "usage": {"input_tokens": 20},
            }),
            json.dumps({
                "format": "weave.provider-usage", "version": 1, "trace_id": "t",
                "usage_event_id": "usage-bad", "usage_kind": "incremental",
                "provenance": {"host": "codex", "adapter": "session-export",
                               "adapter_version": "1", "provider": "openai", "model": "gpt-test"},
                "usage": {"input_tokens": -1},
            }),
        ]) + "\n",
        encoding="utf-8",
    )

    result = evaluate(calls, usage_path)
    assert result["observations"]["output_estimate"] == {
        "stdout_bytes": 9,
        "stdout_bytes_available": 1,
        "stdout_bytes_unavailable": 0,
        "estimated_output_tokens": 2,
    }
    assert result["usage_input"]["invalid_rows"] == 1
    assert result["usage_input"]["invalid_reasons"] == {"invalid_usage_metrics": 1}
    assert result["usage_input"]["unmatched_rows"] == 1
    provider_usage = result["provider_usage"]
    assert provider_usage["status"] == "available"
    assert provider_usage["groups"][0]["provenance"]["provider"] == "openai"
    assert provider_usage["groups"][0]["measurements"]["input_tokens"]["value"] == 10
    assert provider_usage["groups"][0]["measurements"]["cost_usd"] == {
        "value": None, "available_events": 0, "unavailable_events": 1,
    }


def test_absent_provider_usage_and_stdout_estimate_are_explicit(tmp_path: Path) -> None:
    """Missing host usage never promotes an absent byte estimate into actual usage."""
    calls = _write(tmp_path, [{"trace_id": "t"}])
    result = evaluate(calls)
    assert result["usage_input"]["status"] == "unavailable"
    assert result["provider_usage"]["status"] == "unavailable"
    assert result["observations"]["output_estimate"]["estimated_output_tokens"] is None

    usage_path = tmp_path / "all-null-usage.jsonl"
    usage_path.write_text(json.dumps({
        "format": "weave.provider-usage", "version": 1, "trace_id": "t",
        "usage_event_id": "null-usage", "usage_kind": "incremental",
        "provenance": {"host": "codex", "adapter": "session-export", "adapter_version": "1",
                       "provider": "openai", "model": "gpt-test"},
        "usage": {},
    }) + "\n", encoding="utf-8")
    null_result = evaluate(calls, usage_path)
    assert null_result["provider_usage"]["status"] == "unavailable"
    assert null_result["provider_usage"]["matched_events"] == 1
    assert null_result["provider_usage"]["groups"][0]["provenance"]["provider"] == "openai"


def test_usage_dedup_null_metrics_and_cost_overflow_are_explicit(tmp_path: Path) -> None:
    """Usage events are incremental, deduplicated, and never serialize non-finite totals."""
    calls = _write(tmp_path, [{"trace_id": "t"}])
    provenance = {"host": "codex", "adapter": "session-export", "adapter_version": "1",
                  "provider": "openai", "model": "gpt-test"}

    def event(event_id: str, usage: dict[str, object]) -> dict[str, object]:
        return {"format": "weave.provider-usage", "version": 1, "trace_id": "t",
                "usage_event_id": event_id, "usage_kind": "incremental",
                "provenance": provenance, "usage": usage}

    usage_path = tmp_path / "usage-edge.jsonl"
    usage_rows = "\n".join(json.dumps(row) for row in [
        event("null", {}),
        event("large-1", {"cost_usd": 1e308}),
        event("large-2", {"cost_usd": 1e308}),
        event("large-2", {"cost_usd": 1e308}),
        event("invalid-negative", {"cost_usd": -1}),
        event("invalid-bool", {"cost_usd": True}),
        event("invalid-huge", {"cost_usd": 10**4000}),
    ])
    huge_literal = json.dumps(event("parser-limit", {})).replace("{}", '{"cost_usd":' + "1" * 10000 + "}")
    usage_path.write_text(usage_rows + "\n" + huge_literal + "\n", encoding="utf-8")

    result = evaluate(calls, usage_path)
    assert result["usage_input"]["valid_rows"] == 3
    assert result["usage_input"]["duplicate_rows"] == 1
    assert result["usage_input"]["conflicting_duplicate_rows"] == 0
    assert result["usage_input"]["invalid_rows"] == 3
    assert result["usage_input"]["invalid_reasons"] == {"invalid_usage_metrics": 3}
    assert result["usage_input"]["malformed_json"] == 1
    cost = result["provider_usage"]["groups"][0]["measurements"]["cost_usd"]
    assert cost == {"value": None, "available_events": 2, "unavailable_events": 1,
                    "aggregation_error": "non-finite aggregate"}


def test_usage_conflicting_duplicate_ids_are_excluded_in_all_orders(tmp_path: Path) -> None:
    """Every row for a conflicted event ID is excluded and classified deterministically."""
    calls = _write(tmp_path, [{"trace_id": "t"}])
    provenance = {"host": "codex", "adapter": "session-export", "adapter_version": "1",
                  "provider": "openai", "model": "gpt-test"}

    def event(tokens: int) -> dict[str, object]:
        return {"format": "weave.provider-usage", "version": 1, "trace_id": "t",
                "usage_event_id": "reused", "usage_kind": "incremental",
                "provenance": provenance, "usage": {"input_tokens": tokens}}

    orders = (
        [event(10), event(20)],
        [event(20), event(10)],
        [event(10), event(10), event(20)],
        [event(10), event(20), event(10)],
        [event(20), event(10), event(10)],
        [event(10), event(20), event(20)],
    )
    for index, rows in enumerate(orders):
        usage_path = tmp_path / f"conflict-{index}.jsonl"
        usage_path.write_text("\n".join(json.dumps(row) for row in rows) + "\n", encoding="utf-8")
        result = evaluate(calls, usage_path)
        assert result["usage_input"]["valid_rows"] == 0
        assert result["usage_input"]["duplicate_rows"] == 0
        assert result["usage_input"]["conflicting_duplicate_rows"] == len(rows)
        assert result["usage_input"]["input_lines"] == sum(
            result["usage_input"][key]
            for key in (
                "blank_lines", "malformed_json", "invalid_rows", "valid_rows",
                "duplicate_rows", "conflicting_duplicate_rows",
            )
        )
        assert result["provider_usage"]["status"] == "unavailable"


def test_usage_replays_compare_normalized_values_and_join_identity(tmp_path: Path) -> None:
    """Representation-only differences replay; different resolved join identities conflict."""
    calls = _write(tmp_path, [{"trace_id": "t"}])
    provenance = {"host": "codex", "adapter": "session-export", "adapter_version": "1",
                  "provider": "openai", "model": "gpt-test"}
    base = {"format": "weave.provider-usage", "version": 1, "usage_event_id": "same",
            "usage_kind": "incremental", "provenance": provenance}
    equivalent = [
        {**base, "trace_id": "t", "usage": {"cost_usd": 1}},
        {**base, "workflow_id": "t", "usage": {"cost_usd": 1.0, "input_tokens": None}},
        {"usage": {"input_tokens": None, "cost_usd": 1.0}, "workflow_id": "t", **base},
    ]
    usage_path = tmp_path / "normalized-replays.jsonl"
    usage_path.write_text("\n".join(json.dumps(row) for row in equivalent) + "\n", encoding="utf-8")
    result = evaluate(calls, usage_path)
    assert result["usage_input"]["valid_rows"] == 1
    assert result["usage_input"]["duplicate_rows"] == 2
    assert result["usage_input"]["conflicting_duplicate_rows"] == 0
    assert result["provider_usage"]["matched_events"] == 1

    conflicting = [
        {**base, "trace_id": "t", "usage": {"input_tokens": 1}},
        {**base, "workflow_id": "other", "usage": {"input_tokens": 1}},
        {**base, "call_id": "t", "usage": {"input_tokens": 1}},
    ]
    usage_path.write_text("\n".join(json.dumps(row) for row in conflicting) + "\n", encoding="utf-8")
    result = evaluate(calls, usage_path)
    assert result["usage_input"]["valid_rows"] == 0
    assert result["usage_input"]["duplicate_rows"] == 0
    assert result["usage_input"]["conflicting_duplicate_rows"] == 3
    assert result["provider_usage"]["status"] == "unavailable"


def test_invalid_usage_row_does_not_taint_a_valid_event_id(tmp_path: Path) -> None:
    """Rows outside the canonical usage contract stay invalid rather than becoming ID conflicts."""
    calls = _write(tmp_path, [{"trace_id": "t"}])
    provenance = {"host": "codex", "adapter": "session-export", "adapter_version": "1",
                  "provider": "openai", "model": "gpt-test"}
    valid = {"format": "weave.provider-usage", "version": 1, "trace_id": "t",
             "usage_event_id": "mixed", "usage_kind": "incremental",
             "provenance": provenance, "usage": {"input_tokens": 10}}
    invalid = {**valid, "usage": {"input_tokens": -1}}
    for index, rows in enumerate(([valid, invalid], [invalid, valid])):
        usage_path = tmp_path / f"valid-invalid-{index}.jsonl"
        usage_path.write_text("\n".join(json.dumps(row) for row in rows) + "\n", encoding="utf-8")
        result = evaluate(calls, usage_path)
        assert result["usage_input"]["valid_rows"] == 1
        assert result["usage_input"]["invalid_rows"] == 1
        assert result["usage_input"]["invalid_reasons"] == {"invalid_usage_metrics": 1}
        assert result["usage_input"]["conflicting_duplicate_rows"] == 0
        assert result["provider_usage"]["groups"][0]["measurements"]["input_tokens"]["value"] == 10


def test_usage_invalid_reasons_are_itemized(tmp_path: Path) -> None:
    """Every schema rejection contributes one stable invalid-reason count."""
    calls = _write(tmp_path, [{"trace_id": "t"}])
    provenance = {"host": "codex", "adapter": "session-export", "adapter_version": "1",
                  "provider": "openai", "model": "gpt-test"}
    usage_path = tmp_path / "invalid-usage.jsonl"
    usage_path.write_text(
        "\n".join(json.dumps(row) for row in [
            {"format": "other", "version": 1},
            {"format": "weave.provider-usage", "version": True},
            {"format": "weave.provider-usage", "version": 1.0},
            {"format": "weave.provider-usage", "version": "1"},
            {"format": "weave.provider-usage"},
            {"format": "weave.provider-usage", "version": 1, "usage_event_id": "missing-trace",
             "usage_kind": "incremental", "provenance": provenance, "usage": {}},
            {"format": "weave.provider-usage", "version": 1, "trace_id": "t",
             "usage_kind": "incremental", "provenance": provenance, "usage": {}},
            {"format": "weave.provider-usage", "version": 1, "trace_id": "t",
             "usage_event_id": "kind", "usage_kind": "snapshot", "provenance": provenance, "usage": {}},
            {"format": "weave.provider-usage", "version": 1, "trace_id": "t",
             "usage_event_id": "provenance", "usage_kind": "incremental",
             "provenance": {"host": "codex"}, "usage": {}},
        ]) + "\n",
        encoding="utf-8",
    )

    result = evaluate(calls, usage_path)
    assert result["usage_input"]["invalid_rows"] == 9
    assert result["usage_input"]["invalid_reasons"] == {
        "unsupported_format": 5,
        "missing_trace_id": 1,
        "missing_usage_event_id": 1,
        "unsupported_usage_kind": 1,
        "invalid_provenance": 1,
    }
