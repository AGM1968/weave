"""Focused tests for shared runtime orchestration task primitives."""
from __future__ import annotations

from runtime.orchestration.tasks import build_hive_summary, hive_task_prompt


def test_hive_task_prompt_mentions_subtree_and_done_flow() -> None:
    """The shared hive task prompt preserves the current hive work-cycle contract."""
    prompt = hive_task_prompt("wv-subtree")

    assert "wv-subtree" in prompt
    assert "wv_ready" in prompt
    assert "wv_done" in prompt


def test_build_hive_summary_counts_completed_cancelled_and_errors() -> None:
    """The shared summary builder preserves orchestrator summary semantics."""
    results = [
        {
            "agent_id": "a1",
            "subtree": "wv-1",
            "task": "stub",
            "turns": 2,
            "cost_usd": 0.02,
            "input_tokens": 20,
            "output_tokens": 10,
            "session_path": None,
            "stop_error": None,
        },
        {
            "agent_id": "a2",
            "subtree": "wv-2",
            "task": "stub",
            "turns": 0,
            "cost_usd": 0.0,
            "input_tokens": 0,
            "output_tokens": 0,
            "session_path": None,
            "stop_error": "cancelled",
        },
        {
            "agent_id": "a3",
            "subtree": "wv-3",
            "task": "stub",
            "turns": 0,
            "cost_usd": 0.0,
            "input_tokens": 0,
            "output_tokens": 0,
            "session_path": None,
            "stop_error": "boom",
        },
    ]

    summary = build_hive_summary(results)

    assert summary["ran_agents"] == 3
    assert summary["completed_agents"] == 1
    assert summary["cancelled_agents"] == 1
    assert summary["errors"] == 1
    assert summary["cancelled"] is True
