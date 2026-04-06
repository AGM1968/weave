"""Tests for Sprint 3 signal symbiosis: EfficiencySnapshot, JSONL events, dispatcher escalation."""

from __future__ import annotations

import json
import time
from pathlib import Path

from runtime.compliance import _parse_event_message, _SessionMeta, evaluate
from runtime.hooks import SearchEfficiencyHook
from runtime.services.compaction_dispatcher import CompactionDispatcher, CompactionStrategy
from runtime.services.compaction_policy import CompactionConfig
from runtime.session import Session
from runtime.types import EfficiencySnapshot, Message


# ── EfficiencySnapshot + hook.snapshot() ─────────────────────────────────────


class TestEfficiencySnapshot:
    def _make_hook(self) -> SearchEfficiencyHook:
        hook = SearchEfficiencyHook()
        hook.on_prompt("test task")
        return hook

    def test_snapshot_initial_state(self) -> None:
        hook = self._make_hook()
        snap = hook.snapshot()
        assert snap.cascade_paths == {}
        assert snap.empty_streak == 0
        assert snap.bash_search_count == 0
        assert snap.turn == 0
        assert snap.is_thrashing is False

    def test_snapshot_reflects_cascade(self) -> None:
        hook = self._make_hook()
        # Three searches on the same path exceeds the threshold (>2)
        for _ in range(3):
            hook.after_tool("grep", {"path": "src/foo.py"}, "hit", False)
        snap = hook.snapshot()
        assert snap.cascade_paths["src/foo.py"] == 3
        assert snap.is_thrashing is True

    def test_snapshot_reflects_empty_streak(self) -> None:
        hook = self._make_hook()
        for _ in range(3):
            hook.after_tool("grep", {"path": "src/foo.py"}, "", False)
        snap = hook.snapshot()
        assert snap.empty_streak == 3
        assert snap.is_thrashing is True

    def test_snapshot_is_copy_not_live_ref(self) -> None:
        hook = self._make_hook()
        hook.after_tool("grep", {"path": "a.py"}, "hit", False)
        snap = hook.snapshot()
        # Mutating the hook after snapshot does not affect the snapshot
        hook.after_tool("grep", {"path": "b.py"}, "hit", False)
        assert "b.py" not in snap.cascade_paths

    def test_to_dict_round_trips(self) -> None:
        snap = EfficiencySnapshot(
            cascade_paths={"src/a.py": 3},
            empty_streak=1,
            bash_search_count=2,
            turn=5,
            is_thrashing=True,
        )
        d = snap.to_dict()
        assert d["cascade_paths"] == {"src/a.py": 3}
        assert d["empty_streak"] == 1
        assert d["bash_search_count"] == 2
        assert d["turn"] == 5
        assert d["is_thrashing"] is True


# ── JSONL event write + round-trip ────────────────────────────────────────────


class TestEfficiencyEventJSONL:
    def test_record_event_writes_efficiency_entry(self, tmp_path: Path) -> None:
        sess = Session.new(tmp_path / "sessions")
        sess.record_event(
            "efficiency",
            metadata={
                "cascade_paths": {"src/a.py": 3},
                "empty_streak": 0,
                "bash_search_count": 0,
                "turn": 2,
                "is_thrashing": True,
            },
            turn=2,
        )
        lines = [json.loads(ln) for ln in sess.path.read_text().splitlines()]
        ev = next(m for m in lines if m.get("metadata", {}).get("event_type") == "efficiency")
        assert ev["metadata"]["is_thrashing"] is True
        assert ev["metadata"]["turn"] == 2
        assert ev["turn"] == 2

    def test_parse_event_message_populates_efficiency_snapshots(self) -> None:
        meta = _SessionMeta()
        msg = {
            "role": "event",
            "metadata": {
                "event_type": "efficiency",
                "cascade_paths": {"src/b.py": 4},
                "empty_streak": 2,
                "bash_search_count": 1,
                "turn": 3,
                "is_thrashing": True,
            },
        }
        _parse_event_message(msg, meta)
        assert len(meta.efficiency_snapshots) == 1
        assert meta.efficiency_snapshots[0]["is_thrashing"] is True
        assert meta.efficiency_snapshots[0]["turn"] == 3

    def test_efficiency_event_round_trips_through_evaluate(self, tmp_path: Path) -> None:
        """Efficiency event written to JSONL surfaces in ComplianceReport.efficiency_snapshots."""
        session_file = tmp_path / "session.jsonl"
        entries = [
            {"role": "event", "turn": 0, "metadata": {
                "event_type": "session_start", "model": "claude-sonnet-4-6",
                "graph_active": 1, "graph_ready": 2,
            }},
            {"role": "event", "turn": 1, "metadata": {
                "event_type": "efficiency",
                "turn": 1, "is_thrashing": True,
                "bash_search_count": 5, "empty_streak": 3,
            }},
        ]
        session_file.write_text("\n".join(json.dumps(e) for e in entries))
        report = evaluate(session_file)
        assert len(report.efficiency_snapshots) == 1
        snapshot = report.efficiency_snapshots[0]
        assert snapshot["is_thrashing"] is True
        assert snapshot["turn"] == 1
        assert snapshot["bash_search_count"] == 5

    def test_legacy_jsonl_without_efficiency_events_parses_cleanly(self) -> None:
        """JSONL produced before Sprint 3 has no efficiency events — must not break."""
        meta = _SessionMeta()
        old_events = [
            {"role": "event", "metadata": {"event_type": "session_start", "model": "claude-3"}},
            {"role": "event", "metadata": {"event_type": "compaction", "messages_before": 10}},
        ]
        for msg in old_events:
            _parse_event_message(msg, meta)
        assert meta.efficiency_snapshots == []
        assert meta.compaction_count == 1


# ── Dispatcher escalation on is_thrashing ─────────────────────────────────────


def _make_dispatcher(soft: int = 1000, hard: int = 2000) -> CompactionDispatcher:
    cfg = CompactionConfig(soft_threshold=soft, hard_threshold=hard, keep_turns=3)
    return CompactionDispatcher(cfg)


def _make_messages(n: int) -> list[Message]:
    return [Message(role="user", content="x" * 10) for _ in range(n)]


class TestDispatcherThrashingEscalation:
    def test_thrashing_escalates_micro_to_full(self) -> None:
        disp = _make_dispatcher(soft=1, hard=100_000)
        messages = _make_messages(5)  # above soft threshold
        thrashing = EfficiencySnapshot(
            cascade_paths={"a": 5}, empty_streak=0, bash_search_count=0,
            turn=3, is_thrashing=True,
        )
        strategy = disp.select_strategy(messages, thrashing)
        assert strategy is CompactionStrategy.FULL

    def test_non_thrashing_stays_micro(self) -> None:
        disp = _make_dispatcher(soft=1, hard=100_000)
        messages = _make_messages(5)
        calm = EfficiencySnapshot(
            cascade_paths={}, empty_streak=0, bash_search_count=0,
            turn=3, is_thrashing=False,
        )
        strategy = disp.select_strategy(messages, calm)
        assert strategy is CompactionStrategy.MICRO

    def test_no_snapshot_stays_micro(self) -> None:
        disp = _make_dispatcher(soft=1, hard=100_000)
        messages = _make_messages(5)
        strategy = disp.select_strategy(messages, None)
        assert strategy is CompactionStrategy.MICRO

    def test_hard_threshold_always_full_regardless_of_thrashing(self) -> None:
        disp = _make_dispatcher(soft=1, hard=1)
        messages = _make_messages(5)
        calm = EfficiencySnapshot(
            cascade_paths={}, empty_streak=0, bash_search_count=0,
            turn=3, is_thrashing=False,
        )
        strategy = disp.select_strategy(messages, calm)
        assert strategy is CompactionStrategy.FULL

    def test_should_compact_passes_efficiency(self) -> None:
        disp = _make_dispatcher(soft=1, hard=100_000)
        messages = _make_messages(5)
        thrashing = EfficiencySnapshot(
            cascade_paths={"a": 5}, empty_streak=0, bash_search_count=0,
            turn=3, is_thrashing=True,
        )
        assert disp.should_compact(messages, thrashing) is True


# ── Time-based microcompact trigger ───────────────────────────────────────────


class TestDispatcherTimeTrigger:
    def test_idle_below_threshold_returns_none(self) -> None:
        """No compaction when tokens are low and gap is within threshold."""
        disp = _make_dispatcher(soft=100_000, hard=200_000)
        disp.idle_threshold_secs = 600.0
        # Just called record_turn — gap ~0s
        disp.record_turn()
        messages = _make_messages(5)  # well under soft threshold
        strategy = disp.select_strategy(messages)
        assert strategy is CompactionStrategy.NONE

    def test_idle_above_threshold_forces_micro(self) -> None:
        """When cache is cold (gap > threshold) and tokens are low, force MICRO."""
        disp = _make_dispatcher(soft=100_000, hard=200_000)
        disp.idle_threshold_secs = 0.0  # always expired
        messages = _make_messages(5)  # well under soft threshold
        strategy = disp.select_strategy(messages)
        assert strategy is CompactionStrategy.MICRO

    def test_record_turn_resets_gap(self) -> None:
        """record_turn() resets the gap so the idle trigger no longer fires."""
        disp = _make_dispatcher(soft=100_000, hard=200_000)
        disp.idle_threshold_secs = 0.0  # would fire without record_turn
        # Simulate: time passes, then a turn is recorded
        time.sleep(0.01)
        disp.record_turn()
        # After record_turn with threshold=0, gap is effectively 0 — still fires
        # but immediately after record_turn the gap is sub-millisecond.
        # Set threshold to a very large value to verify the reset works.
        disp.idle_threshold_secs = 3600.0  # 1 hour — won't fire after fresh record
        messages = _make_messages(5)
        strategy = disp.select_strategy(messages)
        assert strategy is CompactionStrategy.NONE

    def test_idle_trigger_skipped_when_tokens_above_soft(self) -> None:
        """When tokens > soft threshold, reactive logic runs instead of idle trigger."""
        disp = _make_dispatcher(soft=1, hard=100_000)
        disp.idle_threshold_secs = 0.0  # would fire if tokens were low
        messages = _make_messages(5)  # above soft=1
        strategy = disp.select_strategy(messages)
        # Tokens above soft: normal MICRO selected by reactive logic, not idle trigger
        assert strategy is CompactionStrategy.MICRO
