"""P7 dogfood compliance scenarios — programmatic, no TUI required.

Replaces the TUI-executed P7 dogfood prompts with deterministic synthetic
sessions.  Each test builds a JSONL session, runs it through evaluate(),
and asserts the expected score and violation set.

Benefits over TUI runs:
  - No LLM cost, no network, runs in <1s for all scenarios
  - Deterministic — same session shape every run
  - Catches regressions in _parse_session, rule logic, and scoring
  - Fast feedback loop for compliance rule changes

Layout:
  _session()            — low-level JSONL entry builder
  _write()              — writes entries to a tmp path
  TestP7HappyPath       — compliant sessions that should score 100/100
  TestP7R1Discovery     — R1 violation scenarios end-to-end
  TestP7R2ClaimWork     — R2 violation scenarios end-to-end
  TestP7R3Learning      — R3 violation scenarios end-to-end
  TestP7R4Verification  — R4 violation scenarios end-to-end
  TestP7R6StatusBypass  — R6 violation scenarios end-to-end
  TestP7R7ReviewEvidence — R7 violation scenarios end-to-end
  TestP7R8SearchCascade — R8 violation scenarios end-to-end
  TestP7Scoring         — score arithmetic for multi-rule violations
  TestP7ContextPolicy   — context_load_policy interaction with R8
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any


# ── Session builder helpers ───────────────────────────────────────────────────

def _tool_call(id: str, name: str, inp: dict[str, Any] | None = None) -> dict[str, Any]:
    return {"id": id, "name": name, "input": inp or {}}


def _tool_result(id: str, content: str, is_error: bool = False) -> dict[str, Any]:
    return {"id": id, "content": content, "is_error": is_error}


def _assistant(turn: int, *calls: dict[str, Any]) -> dict[str, Any]:
    return {"role": "assistant", "turn": turn, "content": "", "tool_calls": list(calls)}


def _results(turn: int, *results: dict[str, Any]) -> dict[str, Any]:
    return {"role": "tool_result", "turn": turn, "content": list(results)}


def _session_start(
    graph_active: int = 1,
    graph_ready: int = 2,
    policy: str = "HIGH",
) -> dict[str, Any]:
    return {
        "role": "event", "turn": 0, "content": "",
        "metadata": {
            "event_type": "session_start",
            "model": "claude-sonnet-4-6",
            "context_load_policy": policy,
            "graph_active": graph_active,
            "graph_ready": graph_ready,
        },
    }


def _skill_injected(skill_name: str = "weave") -> dict[str, Any]:
    """Session-start event for a skill-managed session (no graph_active)."""
    return {
        "role": "event", "turn": 0, "content": "",
        "metadata": {"event_type": "skill_injected", "skill_name": skill_name},
    }


def _write(path: Path, entries: list[dict[str, Any]]) -> Path:
    path.write_text("\n".join(json.dumps(e) for e in entries) + "\n", encoding="utf-8")
    return path


# ── Canonical compliant session shape ────────────────────────────────────────

def _compliant_entries(*, policy: str = "HIGH") -> list[dict[str, Any]]:
    """Minimal session that satisfies all R1–R8 rules.

    Shape:
      turn 0 — session_start (graph_active=1 → bootstrap discovery + pre_claimed)
      turn 1 — wv_status (explicit R1 discovery)
      turn 2 — wv_work (explicit R2 claim)
      turn 3 — read (R7 evidence)
      turn 4 — wv_update with verification metadata (R4)
      turn 5 — wv_done with structured learning (R3)
    """
    return [
        _session_start(graph_active=1, graph_ready=2, policy=policy),
        _assistant(1, _tool_call("t1", "wv_status")),
        _results(1, _tool_result("t1", "1 active, 2 ready")),
        _assistant(2, _tool_call("t2", "wv_work", {"node_id": "wv-abc123"})),
        _results(2, _tool_result("t2", "Claimed: wv-abc123")),
        _assistant(3, _tool_call("t3", "read", {"file_path": "/tmp/foo.py"})),
        _results(3, _tool_result("t3", "def foo(): pass")),
        _assistant(4, _tool_call("t4", "wv_update", {
            "node_id": "wv-abc123",
            "metadata": {"verification": {"method": "pytest", "result": "pass"}},
        })),
        _results(4, _tool_result("t4", "Updated")),
        _assistant(5, _tool_call("t5", "wv_done", {
            "node_id": "wv-abc123",
            "learning": "decision: chose X | pattern: Y | pitfall: Z",
        })),
        _results(5, _tool_result("t5", "Closed")),
        {"role": "assistant", "turn": 6, "content": "Done.", "tool_calls": []},
    ]


# ── Happy-path tests ──────────────────────────────────────────────────────────


class TestP7HappyPath:
    """Fully compliant sessions must score 100/100."""

    def test_full_compliant_session_scores_100(self, tmp_path: Path) -> None:
        """Canonical happy path: discovery → claim → read → verify → done."""
        from runtime.compliance import evaluate

        report = evaluate(_write(tmp_path / "compliant.jsonl", _compliant_entries()))

        assert report.score == 100, (
            f"Expected 100/100, got {report.score}. "
            f"Violations: {[v.rule for v in report.violations]}"
        )

    def test_bootstrap_discovery_satisfies_r1_without_explicit_wv_status(
        self, tmp_path: Path
    ) -> None:
        """session_start with graph_active>=0 satisfies R1 — no need for wv_status call."""
        from runtime.compliance import evaluate

        entries = [
            _session_start(graph_active=1),
            # No wv_status — R1 should still pass via bootstrap_discovery
            _assistant(1, _tool_call("t1", "wv_work", {"node_id": "wv-abc123"})),
            _results(1, _tool_result("t1", "Claimed")),
            _assistant(2, _tool_call("t2", "wv_update", {
                "node_id": "wv-abc123",
                "metadata": {"verification": {"method": "test", "result": "pass"}},
            })),
            _results(2, _tool_result("t2", "Updated")),
            _assistant(3, _tool_call("t3", "wv_done", {
                "node_id": "wv-abc123",
                "learning": "decision: X | pattern: Y | pitfall: Z",
            })),
            _results(3, _tool_result("t3", "Closed")),
            {"role": "assistant", "turn": 4, "content": "Done.", "tool_calls": []},
        ]
        report = evaluate(_write(tmp_path / "bootstrap.jsonl", entries))

        r1 = [v for v in report.violations if v.rule == "R1:discovery_phase"]
        assert r1 == [], f"R1 false positive with bootstrap graph_active=1: {r1}"

    def test_pre_claimed_satisfies_r2_without_explicit_wv_work(
        self, tmp_path: Path
    ) -> None:
        """session_start with graph_active>0 satisfies R2 — bash is gated but pre_claimed."""
        from runtime.compliance import evaluate

        entries = [
            _session_start(graph_active=1),
            # No wv_work — R2 should pass via pre_claimed
            _assistant(1, _tool_call("t1", "bash", {"command": "git log --oneline -5"})),
            _results(1, _tool_result("t1", "abc123 some commit")),
            _assistant(2, _tool_call("t2", "wv_update", {
                "node_id": "wv-abc123",
                "metadata": {"verification": {"method": "manual", "result": "ok"}},
            })),
            _results(2, _tool_result("t2", "Updated")),
            _assistant(3, _tool_call("t3", "wv_done", {
                "node_id": "wv-abc123",
                "learning": "decision: X | pattern: Y | pitfall: Z",
            })),
            _results(3, _tool_result("t3", "Closed")),
            {"role": "assistant", "turn": 4, "content": "Done.", "tool_calls": []},
        ]
        report = evaluate(_write(tmp_path / "pre-claimed.jsonl", entries))

        r2 = [v for v in report.violations if v.rule == "R2:claim_before_work"]
        assert r2 == [], f"R2 false positive with pre_claimed (graph_active=1): {r2}"


# ── Skill-injected session ───────────────────────────────────────────────────


class TestP7SkillSession:
    """Skill-managed sessions (/weave) must not get false R1/R2 positives.

    In skill sessions there is no session_start event — graph_active stays -1.
    The skill handles INTAKE/CONTEXT before the JSONL starts, so the agent's
    first tool call is wv_context (not wv_status/wv_work).
    """

    def test_skill_session_scores_100_when_wv_context_called_first(
        self, tmp_path: Path
    ) -> None:
        from runtime.compliance import evaluate

        entries = [
            _skill_injected("weave"),
            _assistant(1, _tool_call("t1", "wv_context", {"node_id": "wv-abc123"})),
            _results(1, _tool_result("t1", "Context pack...")),
            _assistant(2, _tool_call("t2", "read", {"file_path": "/tmp/foo.py"})),
            _results(2, _tool_result("t2", "def foo(): pass")),
            _assistant(3, _tool_call("t3", "bash", {"command": "pytest -q"})),
            _results(3, _tool_result("t3", "1 passed")),
            _assistant(4, _tool_call("t4", "wv_update", {
                "node_id": "wv-abc123",
                "metadata": {"verification": {"method": "pytest", "result": "pass"}},
            })),
            _results(4, _tool_result("t4", "Updated")),
            _assistant(5, _tool_call("t5", "wv_done", {
                "node_id": "wv-abc123",
                "learning": "decision: X | pattern: Y | pitfall: Z",
            })),
            _results(5, _tool_result("t5", "Closed")),
            {"role": "assistant", "turn": 6, "content": "Done.", "tool_calls": []},
        ]
        report = evaluate(_write(tmp_path / "skill-session.jsonl", entries))

        r1 = [v for v in report.violations if "R1" in v.rule]
        r2 = [v for v in report.violations if "R2" in v.rule]
        assert r1 == [], f"R1 false positive in skill session: {r1}"
        assert r2 == [], f"R2 false positive in skill session: {r2}"
        assert report.score == 100, f"Expected 100/100, got {report.score}"

    def test_skill_session_fires_r1_r2_when_no_wv_context(
        self, tmp_path: Path
    ) -> None:
        """Skill session without wv_context should still trigger R1/R2."""
        from runtime.compliance import evaluate

        entries = [
            _skill_injected("weave"),
            _assistant(1, _tool_call("t1", "bash", {"command": "ls"})),
            _results(1, _tool_result("t1", "foo.py")),
            _assistant(2, _tool_call("t2", "wv_done", {
                "node_id": "wv-abc123",
                "learning": "decision: X | pattern: Y | pitfall: Z",
            })),
            _results(2, _tool_result("t2", "Closed")),
        ]
        report = evaluate(_write(tmp_path / "skill-no-context.jsonl", entries))

        r2 = [v for v in report.violations if "R2" in v.rule]
        assert len(r2) >= 1, "R2 should fire when no wv_context and no wv_work"


# ── R1 discovery scenarios ────────────────────────────────────────────────────


class TestP7R1Discovery:
    """R1: wv_status or wv_ready required before gated tools when no bootstrap."""

    def test_r1_fires_when_no_bootstrap_and_no_discovery(self, tmp_path: Path) -> None:
        """R1 fires when session_start has graph_active=-1 and no wv_status."""
        from runtime.compliance import evaluate

        entries = [
            _session_start(graph_active=-1),   # no graph state in bootstrap
            _assistant(1, _tool_call("t1", "wv_done", {
                "node_id": "wv-abc123",
                "learning": "decision: X | pattern: Y | pitfall: Z",
            })),
            _results(1, _tool_result("t1", "Closed")),
        ]
        report = evaluate(_write(tmp_path / "r1-miss.jsonl", entries))

        r1 = [v for v in report.violations if v.rule == "R1:discovery_phase"]
        assert len(r1) == 1
        assert r1[0].severity == "warning"

    def test_r1_silent_when_wv_ready_precedes_gated(self, tmp_path: Path) -> None:
        from runtime.compliance import evaluate

        entries = [
            _session_start(graph_active=-1),
            _assistant(1, _tool_call("t1", "wv_ready")),
            _results(1, _tool_result("t1", "[]")),
            _assistant(2, _tool_call("t2", "wv_done", {
                "node_id": "wv-abc123",
                "learning": "decision: X | pattern: Y | pitfall: Z",
            })),
            _results(2, _tool_result("t2", "Closed")),
        ]
        report = evaluate(_write(tmp_path / "r1-ready.jsonl", entries))

        r1 = [v for v in report.violations if v.rule == "R1:discovery_phase"]
        assert r1 == []


# ── R2 claim scenarios ────────────────────────────────────────────────────────


class TestP7R2ClaimWork:
    """R2: wv_work required before gated tools in sessions with no pre-existing node."""

    def test_r2_fires_when_wv_done_without_wv_work_and_no_pre_claimed(
        self, tmp_path: Path
    ) -> None:
        from runtime.compliance import evaluate

        entries = [
            _session_start(graph_active=0),   # 0 active → no pre_claimed
            _assistant(1, _tool_call("t1", "wv_status")),
            _results(1, _tool_result("t1", "0 active")),
            _assistant(2, _tool_call("t2", "wv_done", {
                "node_id": "wv-abc123",
                "learning": "decision: X | pattern: Y | pitfall: Z",
            })),
            _results(2, _tool_result("t2", "Closed")),
        ]
        report = evaluate(_write(tmp_path / "r2-miss.jsonl", entries))

        r2 = [v for v in report.violations if v.rule == "R2:claim_before_work"]
        assert len(r2) == 1, f"Expected R2 violation, got: {[v.rule for v in report.violations]}"

    def test_r2_fires_for_bash_without_claim(self, tmp_path: Path) -> None:
        """bash is GRAPH_REPAIR — R2 fires when bash succeeds without wv_work."""
        from runtime.compliance import evaluate

        entries = [
            _session_start(graph_active=0),
            _assistant(1, _tool_call("t1", "wv_status")),
            _results(1, _tool_result("t1", "0 active")),
            _assistant(2, _tool_call("t2", "bash", {"command": "rm -rf /tmp/test"})),
            _results(2, _tool_result("t2", "removed")),
        ]
        report = evaluate(_write(tmp_path / "r2-bash.jsonl", entries))

        r2 = [v for v in report.violations if v.rule == "R2:claim_before_work"]
        assert len(r2) == 1
        assert r2[0].turn == 2

    def test_r2_silent_when_wv_add_precedes_gated(self, tmp_path: Path) -> None:
        """wv_add is the create-and-claim pattern — satisfies R2 before gated tools."""
        from runtime.compliance import evaluate

        entries = [
            _session_start(graph_active=0),
            _assistant(1, _tool_call("t1", "wv_status")),
            _results(1, _tool_result("t1", "0 active")),
            _assistant(2,
                _tool_call("t2", "wv_add", {"text": "fix: thing", "status": "active"}),
                _tool_call("t3", "bash", {"command": "pytest -q"}),
            ),
            _results(2,
                _tool_result("t2", '{"id": "wv-new1"}'),
                _tool_result("t3", "1 passed"),
            ),
        ]
        report = evaluate(_write(tmp_path / "r2-wv-add-claim.jsonl", entries))

        r2 = [v for v in report.violations if v.rule == "R2:claim_before_work"]
        assert r2 == [], f"R2 false positive after wv_add: {r2}"

    def test_r1_silent_when_wv_add_precedes_gated(self, tmp_path: Path) -> None:
        """wv_add satisfies R1 discovery — creating a node IS a discovery decision."""
        from runtime.compliance import evaluate

        entries = [
            _session_start(graph_active=0),
            _assistant(1,
                _tool_call("t1", "wv_add", {"text": "fix: thing", "status": "active"}),
                _tool_call("t2", "bash", {"command": "pytest -q"}),
            ),
            _results(1,
                _tool_result("t1", '{"id": "wv-new1"}'),
                _tool_result("t2", "1 passed"),
            ),
        ]
        report = evaluate(_write(tmp_path / "r1-wv-add-discovery.jsonl", entries))

        r1 = [v for v in report.violations if v.rule == "R1:discovery_phase"]
        assert r1 == [], f"R1 false positive after wv_add: {r1}"

    def test_r2_fires_when_wv_add_without_active_status(self, tmp_path: Path) -> None:
        """wv_add without status=active (todo by default) must NOT satisfy R2."""
        from runtime.compliance import evaluate

        # graph_active=-1: no session_start bootstrap, so no pre_claimed shortcut
        entries = [
            _session_start(graph_active=-1),
            _assistant(1, _tool_call("t1", "wv_status")),
            _results(1, _tool_result("t1", "0 active")),
            _assistant(2,
                _tool_call("t2", "wv_add", {"text": "fix: thing"}),  # no status=active
                _tool_call("t3", "bash", {"command": "pytest -q"}),
            ),
            _results(2,
                _tool_result("t2", '{"id": "wv-new1"}'),
                _tool_result("t3", "1 passed"),
            ),
        ]
        report = evaluate(_write(tmp_path / "r2-wv-add-no-active.jsonl", entries))

        r2 = [v for v in report.violations if v.rule == "R2:claim_before_work"]
        assert len(r2) >= 1, "R2 must fire when wv_add omits status=active"

    def test_r1_fires_when_wv_add_without_active_status(self, tmp_path: Path) -> None:
        """wv_add without status=active must NOT satisfy R1 discovery."""
        from runtime.compliance import evaluate

        # graph_active=-1: no session_start bootstrap, so no bootstrap_discovery shortcut
        entries = [
            _session_start(graph_active=-1),
            _assistant(1,
                _tool_call("t1", "wv_add", {"text": "fix: thing"}),  # no status=active
                _tool_call("t2", "bash", {"command": "pytest -q"}),
            ),
            _results(1,
                _tool_result("t1", '{"id": "wv-new1"}'),
                _tool_result("t2", "1 passed"),
            ),
        ]
        report = evaluate(_write(tmp_path / "r1-wv-add-no-active.jsonl", entries))

        r1 = [v for v in report.violations if v.rule == "R1:discovery_phase"]
        assert len(r1) >= 1, "R1 must fire when wv_add omits status=active"


# ── R3 learning quality ───────────────────────────────────────────────────────


class TestP7R3Learning:
    """R3: wv_done learning must contain decision:|pattern:|pitfall: markers."""

    def test_r3_fires_for_unstructured_learning(self, tmp_path: Path) -> None:
        from runtime.compliance import evaluate

        entries = [
            _session_start(graph_active=1),
            _assistant(1, _tool_call("t1", "wv_done", {
                "node_id": "wv-abc123",
                "learning": "it worked fine",
            })),
            _results(1, _tool_result("t1", "Closed")),
        ]
        report = evaluate(_write(tmp_path / "r3-bad.jsonl", entries))

        r3 = [v for v in report.violations if v.rule == "R3:learning_quality"]
        assert len(r3) == 1

    def test_r3_silent_for_structured_learning(self, tmp_path: Path) -> None:
        from runtime.compliance import evaluate

        entries = [
            _session_start(graph_active=1),
            _assistant(1, _tool_call("t1", "wv_done", {
                "node_id": "wv-abc123",
                "learning": "decision: use X | pattern: always Y | pitfall: avoid Z",
            })),
            _results(1, _tool_result("t1", "Closed")),
        ]
        report = evaluate(_write(tmp_path / "r3-good.jsonl", entries))

        r3 = [v for v in report.violations if v.rule == "R3:learning_quality"]
        assert r3 == []

    def test_r3_silent_when_skip_verification(self, tmp_path: Path) -> None:
        from runtime.compliance import evaluate

        entries = [
            _session_start(graph_active=1),
            _assistant(1, _tool_call("t1", "wv_done", {
                "node_id": "wv-abc123",
                "skip_verification": True,
            })),
            _results(1, _tool_result("t1", "Closed")),
        ]
        report = evaluate(_write(tmp_path / "r3-skip.jsonl", entries))

        r3 = [v for v in report.violations if v.rule == "R3:learning_quality"]
        assert r3 == []


# ── R4 verification ───────────────────────────────────────────────────────────


class TestP7R4Verification:
    """R4: wv_update with verification metadata must precede wv_done."""

    def test_r4_fires_when_no_prior_wv_update(self, tmp_path: Path) -> None:
        from runtime.compliance import evaluate

        entries = [
            _session_start(graph_active=1),
            _assistant(1, _tool_call("t1", "wv_done", {
                "node_id": "wv-abc123",
                "learning": "decision: X | pattern: Y | pitfall: Z",
            })),
            _results(1, _tool_result("t1", "Closed")),
        ]
        report = evaluate(_write(tmp_path / "r4-miss.jsonl", entries))

        r4 = [v for v in report.violations if v.rule == "R4:verification_present"]
        assert len(r4) == 1

    def test_r4_fires_when_wv_update_lacks_verification_key(
        self, tmp_path: Path
    ) -> None:
        """wv_update with non-verification metadata must not satisfy R4."""
        from runtime.compliance import evaluate

        entries = [
            _session_start(graph_active=1),
            _assistant(1, _tool_call("t1", "wv_update", {
                "node_id": "wv-abc123",
                "metadata": {"priority": "high"},   # no verification key
            })),
            _results(1, _tool_result("t1", "Updated")),
            _assistant(2, _tool_call("t2", "wv_done", {
                "node_id": "wv-abc123",
                "learning": "decision: X | pattern: Y | pitfall: Z",
            })),
            _results(2, _tool_result("t2", "Closed")),
        ]
        report = evaluate(_write(tmp_path / "r4-wrong-meta.jsonl", entries))

        r4 = [v for v in report.violations if v.rule == "R4:verification_present"]
        assert len(r4) == 1

    def test_r4_silent_when_verification_present(self, tmp_path: Path) -> None:
        from runtime.compliance import evaluate

        entries = [
            _session_start(graph_active=1),
            _assistant(1, _tool_call("t1", "wv_update", {
                "node_id": "wv-abc123",
                "metadata": {
                    "verification": {"method": "pytest", "result": "all pass"},
                },
            })),
            _results(1, _tool_result("t1", "Updated")),
            _assistant(2, _tool_call("t2", "wv_done", {
                "node_id": "wv-abc123",
                "learning": "decision: X | pattern: Y | pitfall: Z",
            })),
            _results(2, _tool_result("t2", "Closed")),
        ]
        report = evaluate(_write(tmp_path / "r4-good.jsonl", entries))

        r4 = [v for v in report.violations if v.rule == "R4:verification_present"]
        assert r4 == []


# ── R5 enforcement blocks ─────────────────────────────────────────────────────


class TestP7R5EnforcementBlock:
    """R5: any enforcement gate fire means the agent attempted a workflow violation."""

    def test_r5_fires_when_tool_result_is_enforcement_block(
        self, tmp_path: Path
    ) -> None:
        """A tool result that contains enforcement-block language and is_error=True
        must produce exactly one R5:enforcement_block violation."""
        from runtime.compliance import evaluate

        entries = [
            _session_start(graph_active=1),
            _assistant(1, _tool_call("t1", "write", {"path": "/tmp/x.py", "content": "x"})),
            _results(1, _tool_result(
                "t1",
                "no active weave node — claim one with wv_work before editing files.",
                is_error=True,
            )),
        ]
        report = evaluate(_write(tmp_path / "r5-block.jsonl", entries))

        r5 = [v for v in report.violations if v.rule == "R5:enforcement_block"]
        assert len(r5) == 1
        assert r5[0].severity == "error"
        assert r5[0].turn == 1

    def test_r5_silent_when_tool_succeeds(self, tmp_path: Path) -> None:
        """A successful tool call must not trigger R5 even if the result text
        happens to contain partial enforcement-like language."""
        from runtime.compliance import evaluate

        entries = [
            _session_start(graph_active=1),
            _assistant(1, _tool_call("t1", "wv_status")),
            _results(1, _tool_result("t1", "1 active, 0 ready", is_error=False)),
        ]
        report = evaluate(_write(tmp_path / "r5-clean.jsonl", entries))

        r5 = [v for v in report.violations if v.rule == "R5:enforcement_block"]
        assert r5 == []


# ── R6 status bypass ──────────────────────────────────────────────────────────


class TestP7R6StatusBypass:
    """R6: wv_update must not set status=done or status=active (bypassing wv_done)."""

    def test_r6_fires_when_wv_update_sets_status_done(self, tmp_path: Path) -> None:
        from runtime.compliance import evaluate

        entries = [
            _session_start(graph_active=1),
            _assistant(1, _tool_call("t1", "wv_update", {
                "node_id": "wv-abc123",
                "status": "done",
            })),
            _results(1, _tool_result("t1", "Updated")),
        ]
        report = evaluate(_write(tmp_path / "r6-bypass.jsonl", entries))

        r6 = [v for v in report.violations if v.rule == "R6:update_status_bypass"]
        assert len(r6) == 1

    def test_r6_silent_for_status_blocked(self, tmp_path: Path) -> None:
        """Legitimate status transitions (blocked) must not trigger R6."""
        from runtime.compliance import evaluate

        entries = [
            _session_start(graph_active=1),
            _assistant(1, _tool_call("t1", "wv_update", {
                "node_id": "wv-abc123",
                "status": "blocked",
            })),
            _results(1, _tool_result("t1", "Updated")),
        ]
        report = evaluate(_write(tmp_path / "r6-blocked.jsonl", entries))

        r6 = [v for v in report.violations if v.rule == "R6:update_status_bypass"]
        assert r6 == []


# ── R7 review evidence ───────────────────────────────────────────────────────


class TestP7R7ReviewEvidence:
    """R7: sessions using wv_context must include file reads as evidence."""

    def test_r7_fires_when_wv_context_called_without_prior_read(
        self, tmp_path: Path
    ) -> None:
        from runtime.compliance import evaluate

        entries = [
            _session_start(graph_active=1),
            _assistant(1, _tool_call("t1", "wv_context", {"node_id": "wv-abc123"})),
            _results(1, _tool_result("t1", "Context pack...")),
        ]
        report = evaluate(_write(tmp_path / "r7-no-evidence.jsonl", entries))

        r7 = [v for v in report.violations if v.rule == "R7:review_evidence"]
        assert len(r7) == 1

    def test_r7_silent_when_read_follows_wv_context(self, tmp_path: Path) -> None:
        from runtime.compliance import evaluate

        entries = [
            _session_start(graph_active=1),
            _assistant(1, _tool_call("t1", "wv_context", {"node_id": "wv-abc123"})),
            _results(1, _tool_result("t1", "Context pack...")),
            _assistant(2, _tool_call("t2", "read", {"file_path": "/tmp/foo.py"})),
            _results(2, _tool_result("t2", "def foo(): pass")),
        ]
        report = evaluate(_write(tmp_path / "r7-with-evidence.jsonl", entries))

        r7 = [v for v in report.violations if v.rule == "R7:review_evidence"]
        assert r7 == []


# ── R8 search efficiency ──────────────────────────────────────────────────────


class TestP7R8SearchCascade:
    """R8: repeated searches on the same path are flagged after threshold."""

    def _grep_entries(self, path_str: str, count: int) -> list[dict[str, Any]]:
        entries = [_session_start(graph_active=1)]
        for i in range(count):
            tid = f"g{i}"
            entries.append(_assistant(i + 1, _tool_call(tid, "grep", {
                "path": path_str,
                "pattern": f"pattern_{i}",
            })))
            entries.append(_results(i + 1, _tool_result(tid, f"match_{i}")))
        return entries

    def test_r8_fires_at_4_under_high_policy(self, tmp_path: Path) -> None:
        from runtime.compliance import evaluate

        report = evaluate(_write(
            tmp_path / "r8-high.jsonl",
            self._grep_entries("src/foo.py", 4),
        ))
        r8 = [v for v in report.violations if v.rule == "R8:search_efficiency"]
        assert len(r8) == 1
        assert "reading the file directly" in r8[0].message

    def test_r8_silent_at_4_under_low_policy(self, tmp_path: Path) -> None:
        """4 greps under LOW policy is correct grep-first behaviour — must not fire."""
        from runtime.compliance import evaluate

        entries = self._grep_entries("src/foo.py", 4)
        entries[0] = _session_start(graph_active=1, policy="LOW")
        report = evaluate(_write(tmp_path / "r8-low-ok.jsonl", entries))

        r8 = [v for v in report.violations if v.rule == "R8:search_efficiency"]
        assert r8 == [], f"R8 false positive under LOW policy: {r8}"

    def test_r8_fires_at_6_under_low_policy(self, tmp_path: Path) -> None:
        from runtime.compliance import evaluate

        entries = self._grep_entries("src/foo.py", 6)
        entries[0] = _session_start(graph_active=1, policy="LOW")
        report = evaluate(_write(tmp_path / "r8-low-bad.jsonl", entries))

        r8 = [v for v in report.violations if v.rule == "R8:search_efficiency"]
        assert len(r8) == 1
        assert "read the file directly" not in r8[0].message   # LOW-policy message


# ── Scoring arithmetic ────────────────────────────────────────────────────────


class TestP7Scoring:
    """Score deduction is additive; multiple violations compound correctly."""

    def test_r2_violation_deducts_20_points(self, tmp_path: Path) -> None:
        """R2 is an error-severity rule — deducts 20 points."""
        from runtime.compliance import evaluate

        entries = [
            _session_start(graph_active=0),   # no pre_claimed
            _assistant(1, _tool_call("t1", "wv_status")),
            _results(1, _tool_result("t1", "0 active")),
            # R1 satisfied via wv_status; R2 violated — no wv_work before wv_done
            _assistant(2, _tool_call("t2", "wv_done", {
                "node_id": "wv-abc123",
                "learning": "decision: X | pattern: Y | pitfall: Z",
            })),
            _results(2, _tool_result("t2", "Closed")),
        ]
        report = evaluate(_write(tmp_path / "scoring-r2.jsonl", entries))

        # R2 error = -20; R4 (no verification) = -5; total ≤ 75
        r2 = [v for v in report.violations if v.rule == "R2:claim_before_work"]
        assert len(r2) == 1
        assert report.score <= 80, f"R2 should deduct 20pts, score={report.score}"

    def test_clean_session_scores_100(self, tmp_path: Path) -> None:
        from runtime.compliance import evaluate

        report = evaluate(_write(tmp_path / "perfect.jsonl", _compliant_entries()))
        assert report.score == 100

    def test_warning_only_session_scores_at_least_90(self, tmp_path: Path) -> None:
        """A session with only warning-severity violations must still pass (≥90)."""
        from runtime.compliance import evaluate

        # Single R8 warning (4 greps under HIGH policy)
        entries = [
            _session_start(graph_active=1, policy="HIGH"),
            _assistant(1, _tool_call("s1", "wv_status")),
            _results(1, _tool_result("s1", "1 active")),
        ]
        for i in range(4):
            tid = f"g{i}"
            entries.append(_assistant(i + 2, _tool_call(tid, "grep", {
                "path": "src/foo.py", "pattern": f"p{i}",
            })))
            entries.append(_results(i + 2, _tool_result(tid, f"hit_{i}")))
        entries.append(_assistant(6, _tool_call("t1", "wv_update", {
            "node_id": "wv-abc123",
            "metadata": {"verification": {"method": "test", "result": "pass"}},
        })))
        entries.append(_results(6, _tool_result("t1", "Updated")))
        entries.append(_assistant(7, _tool_call("t2", "wv_done", {
            "node_id": "wv-abc123",
            "learning": "decision: X | pattern: Y | pitfall: Z",
        })))
        entries.append(_results(7, _tool_result("t2", "Closed")))
        entries.append({"role": "assistant", "turn": 8, "content": "Done.", "tool_calls": []})

        report = evaluate(_write(tmp_path / "warning-only.jsonl", entries))
        assert report.score >= 90, (
            f"Warning-only session should score ≥90, got {report.score}. "
            f"Violations: {[(v.rule, v.severity) for v in report.violations]}"
        )


# ── Context load policy interaction ──────────────────────────────────────────


class TestP7ContextPolicy:
    """Context load policy affects R8 threshold and R_context_load_policy rule."""

    def test_read_without_prior_grep_fires_under_low_policy(
        self, tmp_path: Path
    ) -> None:
        """Under LOW policy, reading a large file without a prior grep violates policy."""
        from runtime.compliance import evaluate

        entries = [
            _session_start(graph_active=1, policy="LOW"),
            _assistant(1, _tool_call("t1", "read", {
                "file_path": "runtime/app.py",
                # no offset/limit — treated as large file read
            })),
            _results(1, _tool_result("t1", "\n".join(f"line {i}" for i in range(60)))),
        ]
        report = evaluate(_write(tmp_path / "ctx-no-grep.jsonl", entries))

        ctx = [v for v in report.violations if "context_policy" in v.rule]
        assert len(ctx) >= 1, (
            "Expected context_load_policy violation for read without prior grep under LOW"
        )

    def test_read_after_grep_is_clean_under_low_policy(self, tmp_path: Path) -> None:
        from runtime.compliance import evaluate

        entries = [
            _session_start(graph_active=1, policy="LOW"),
            _assistant(1, _tool_call("t1", "grep", {
                "path": "runtime/app.py", "pattern": "def foo",
            })),
            _results(1, _tool_result("t1", "app.py:42: def foo():")),
            _assistant(2, _tool_call("t2", "read", {
                "file_path": "runtime/app.py",
                "offset": 40, "limit": 20,
            })),
            _results(2, _tool_result("t2", "def foo(): pass")),
        ]
        report = evaluate(_write(tmp_path / "ctx-grep-first.jsonl", entries))

        ctx = [v for v in report.violations if "context_policy" in v.rule]
        assert ctx == [], f"Grep-first read under LOW must not fire: {ctx}"
