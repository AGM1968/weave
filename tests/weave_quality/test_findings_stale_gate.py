"""Regression tests for the stale-signal gate in findings promotion (wv-dc9f3e).

A learning whose source node closed long ago likely describes an already-fixed
issue; promoting it resurfaces resolved work as a fresh finding (3/5 of the first
real promotion batch were already resolved — wv-54920f). `_prepare_historical_candidates`
gates on the source node's `updated_at` recency.
"""

from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone

from weave_quality.findings import (
    _node_updated_before,
    _prepare_historical_candidates,
)

_NOW = datetime.now(timezone.utc)


def _node(node_id: str, age_days: int | None) -> dict[str, object]:
    """A done node carrying a pitfall learning, closed `age_days` ago (None = no ts)."""
    updated = (
        None
        if age_days is None
        else (_NOW - timedelta(days=age_days)).strftime("%Y-%m-%d %H:%M:%S")
    )
    return {
        "id": node_id,
        "status": "done",
        "text": f"{node_id} learning",
        "updated_at": updated,
        "metadata": json.dumps(
            {
                "pitfall": (
                    f"deploy gap in scripts/{node_id}.sh — manual reinstall "
                    "per release leaves stale hooks"
                )
            }
        ),
    }


def _candidate_ids(nodes: list[dict[str, object]], max_age_days: int) -> set[str]:
    """Source-node ids of candidates surviving the gate at `max_age_days`."""
    _, _, _, ranked = _prepare_historical_candidates(nodes, max_age_days=max_age_days)
    return {str(c["source_node"]) for c in ranked}


class TestNodeUpdatedBefore:
    """The recency primitive: is a node's updated_at older than the cutoff?"""

    def test_old_node_is_before_cutoff(self) -> None:
        """A 90-day-old node is older than a 30-day cutoff."""
        assert _node_updated_before(_node("a", 90), _NOW - timedelta(days=30)) is True

    def test_recent_node_is_not_before_cutoff(self) -> None:
        """A 2-day-old node is not older than a 30-day cutoff."""
        assert _node_updated_before(_node("b", 2), _NOW - timedelta(days=30)) is False

    def test_missing_timestamp_fails_open(self) -> None:
        """No updated_at -> cannot prove stale -> never excluded."""
        assert _node_updated_before(_node("c", None), _NOW - timedelta(days=30)) is False

    def test_malformed_timestamp_fails_open(self) -> None:
        """An unparseable timestamp is treated as not-stale (fail open)."""
        assert _node_updated_before({"updated_at": "not-a-date"}, _NOW) is False


class TestStaleSignalGate:
    """The promotion gate: old learnings are excluded so resolved work is not re-promoted."""

    def test_gate_excludes_old_keeps_recent(self) -> None:
        """30-day gate drops the 90-day learning, keeps recent + undated."""
        nodes = [_node("old", 90), _node("new", 2), _node("undated", None)]
        kept = _candidate_ids(nodes, max_age_days=30)
        assert "old" not in kept, "stale 90-day learning leaked past the 30-day gate"
        assert "new" in kept, "recent learning wrongly excluded"
        assert "undated" in kept, "undated learning should fail open"

    def test_gate_disabled_includes_old(self) -> None:
        """max_age_days=0 disables the gate — even old learnings are candidates."""
        nodes = [_node("old", 90), _node("new", 2)]
        kept = _candidate_ids(nodes, max_age_days=0)
        assert kept == {"old", "new"}, "max_age_days=0 must disable the gate"

    def test_tighter_window_is_monotonic(self) -> None:
        """Narrowing the window monotonically shrinks the candidate set."""
        nodes = [_node("d1", 1), _node("d10", 10), _node("d40", 40)]
        assert _candidate_ids(nodes, 0) == {"d1", "d10", "d40"}
        assert _candidate_ids(nodes, 30) == {"d1", "d10"}
        assert _candidate_ids(nodes, 5) == {"d1"}
