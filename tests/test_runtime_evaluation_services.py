"""Focused tests for extracted evaluation/observability services."""
from __future__ import annotations

import json
from pathlib import Path

from runtime.services.evaluation import (
    ComplianceReport,
    append_compliance_score_row,
    build_evaluation_signals,
    evaluation_event_payload,
    format_compliance_json,
    is_enforcement_block,
)
from runtime.services.session_observability import analyse_session


def test_append_compliance_score_row_writes_extended_columns(tmp_path: Path) -> None:
    """Shared TSV writer preserves the compliance trend-log schema used by the TUI."""
    report = ComplianceReport(
        session_path=str(tmp_path / "session.jsonl"),
        tool_events=[],
        violations=[],
        score=100,
        final_response="ok",
        model="claude-sonnet-4-6",
        context_load_policy="MEDIUM",
        compaction_count=1,
        graph_active=2,
        graph_ready=5,
        skills_injected=["pre-mortem", "ship-it"],
    )
    score_log = tmp_path / "compliance-scores.tsv"

    append_compliance_score_row(score_log, report)

    fields = score_log.read_text(encoding="utf-8").strip().split("\t")
    assert len(fields) == 12
    assert fields[1] == "100"
    assert fields[2] == "PASS"
    assert fields[6] == "claude-sonnet-4-6"
    assert fields[11] == "pre-mortem,ship-it"


def test_analyse_session_counts_enforcement_blocks_and_compliance_score(tmp_path: Path) -> None:
    """Shared session observability parser preserves blocked-call and compliance metrics."""
    session = tmp_path / "session.jsonl"
    session.write_text(
        "\n".join([
            json.dumps({
                "role": "assistant",
                "turn": 1,
                "content": "",
                "tool_calls": [{"id": "tc-1", "name": "wv_update", "input": {"status": "done"}}],
            }),
            json.dumps({
                "role": "tool_result",
                "turn": 1,
                "content": [{
                    "id": "tc-1",
                    "content": "No active Weave node available.",
                    "is_error": True,
                }],
            }),
            json.dumps({
                "role": "event",
                "metadata": {"event_type": "compliance", "score": 87},
            }),
        ]) + "\n",
        encoding="utf-8",
    )

    metrics = analyse_session(session)

    assert metrics["tool_calls"] == 1
    assert metrics["blocked_calls"] == 1
    assert metrics["compliance_score"] == 87


def test_format_compliance_json_preserves_report_metadata() -> None:
    """Shared JSON formatter preserves the public compliance report payload."""
    report = ComplianceReport(
        session_path="/tmp/session.jsonl",
        tool_events=[],
        violations=[],
        score=100,
        final_response="done",
        model="claude-sonnet-4-6",
        context_load_policy="LOW",
        compaction_count=2,
        graph_active=1,
        graph_ready=3,
        skills_injected=["pre-mortem", "ship-it"],
    )

    payload = json.loads(format_compliance_json(report))

    assert payload["model"] == "claude-sonnet-4-6"
    assert payload["context_load_policy"] == "LOW"
    assert payload["compaction_count"] == 2
    assert payload["skills_injected"] == ["pre-mortem", "ship-it"]


def test_is_enforcement_block_matches_runtime_gate_language() -> None:
    """Shared enforcement-block detector should classify runtime gate messages consistently."""
    assert is_enforcement_block("No active Weave node available.")
    assert not is_enforcement_block("ordinary tool failure")


def test_build_evaluation_signals_combines_report_and_profiler_metrics() -> None:
    """Unified evaluation signals should merge provider, enforcement, profiler, and compliance data."""
    report = ComplianceReport(
        session_path="/tmp/session.jsonl",
        tool_events=[],
        violations=[],
        score=92,
        final_response="done",
        model="claude-sonnet-4-6",
        context_load_policy="LOW",
        compaction_count=2,
        graph_active=1,
        graph_ready=3,
        skills_injected=["ship-it"],
    )
    metrics = {
        "total_in": 120,
        "total_out": 80,
        "total_cache_read": 40,
        "total_cache_create": 20,
        "total_cost": 0.123,
        "blocked_calls": 2,
        "tool_calls": 5,
        "turns": 4,
        "redirects": 1,
        "empty_results": 0,
        "compliance_score": 92,
        "top_turns": [(2, {"input": 70.0, "output": 30.0, "cost": 0.07})],
    }

    signals = build_evaluation_signals(report, metrics)
    payload = evaluation_event_payload(signals)

    assert signals.provider_usage["cache_read_tokens"] == 40
    assert signals.enforcement["blocked_calls"] == 2
    assert signals.compliance["score"] == 92
    assert payload["quality"] == {"ast_quality_score": None, "quality_source": "pending"}
    provider_usage = payload["provider_usage"]
    assert isinstance(provider_usage, dict)
    assert provider_usage["model"] == "claude-sonnet-4-6"


def test_analyse_session_reads_unified_evaluation_event_score(tmp_path: Path) -> None:
    """Session observability should surface evaluation-event compliance scores for shared reporting."""
    session = tmp_path / "session.jsonl"
    session.write_text(
        json.dumps({
            "role": "event",
            "metadata": {
                "event_type": "evaluation",
                "compliance": {"score": 91},
                "provider_usage": {"model": "claude-sonnet-4-6"},
            },
        }) + "\n",
        encoding="utf-8",
    )

    metrics = analyse_session(session)

    assert metrics["evaluation_score"] == 91


def test_analyse_session_supports_claude_transcript_cache_metrics(tmp_path: Path) -> None:
    """Observability parser should support Claude CLI/VSCode transcript JSONL format."""
    session = tmp_path / "claude-session.jsonl"
    session.write_text(
        "\n".join([
            json.dumps({
                "type": "assistant",
                "entrypoint": "cli",
                "message": {
                    "role": "assistant",
                    "content": [{"type": "tool_use", "id": "tu-1", "name": "Read"}],
                    "usage": {
                        "input_tokens": 100,
                        "output_tokens": 40,
                        "cache_read_input_tokens": 600,
                        "cache_creation_input_tokens": 200,
                    },
                },
            }),
            json.dumps({
                "type": "assistant",
                "entrypoint": "cli",
                "message": {
                    "role": "assistant",
                    "content": [{"type": "text", "text": "done"}],
                    "usage": {
                        "input_tokens": 120,
                        "output_tokens": 30,
                        "cache_read_input_tokens": 300,
                        "cache_creation_input_tokens": 300,
                    },
                },
            }),
        ]) + "\n",
        encoding="utf-8",
    )

    metrics = analyse_session(session)

    assert metrics["source_format"] == "claude"
    assert metrics["entrypoints"] == {"cli": 2}
    assert metrics["tool_calls"] == 1
    assert metrics["total_cache_read"] == 900
    assert metrics["total_cache_create"] == 500
    assert round(float(metrics["cache_read_ratio"]), 3) == 0.643
    assert metrics["cache_health"] == "warning"


def test_analyse_session_flags_recent_cache_stall(tmp_path: Path) -> None:
    """Recent turns with zero read + high creation should be flagged as likely broken cache."""
    session = tmp_path / "claude-stalled.jsonl"
    session.write_text(
        "\n".join([
            json.dumps({
                "type": "assistant",
                "entrypoint": "vscode",
                "message": {"role": "assistant", "usage": {
                    "cache_read_input_tokens": 0,
                    "cache_creation_input_tokens": 2500,
                }},
            }),
            json.dumps({
                "type": "assistant",
                "entrypoint": "vscode",
                "message": {"role": "assistant", "usage": {
                    "cache_read_input_tokens": 0,
                    "cache_creation_input_tokens": 2600,
                }},
            }),
        ]) + "\n",
        encoding="utf-8",
    )

    metrics = analyse_session(session, recent_window=2)

    assert metrics["cache_stalled"] is True
    assert metrics["cache_health"] == "broken-likely"
