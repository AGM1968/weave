"""End-to-end: a real scan and adjudication become a promotion input and a plan.

Every earlier coaching test drives the planner from hand-written fixtures. This
one drives it from an actual `quality.db`: scan a file with a real rule,
adjudicate the finding, and prove the adapter emits evidence the pure planner
can turn into a candidate without ever touching the database itself.

That end-to-end shape is what catches the disagreements a fixture cannot -- a
column the adapter reads under a name the table does not use, a disposition
filter that silently matches nothing, a snapshot that reports complete while the
receipts say otherwise.
"""

# `== []` is deliberate throughout: these assertions pin an empty list, not
# merely a falsey value, which `not x` would weaken to.
# pylint: disable=missing-class-docstring,missing-function-docstring,redefined-outer-name
# pylint: disable=use-implicit-booleaness-not-comparison,too-few-public-methods

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
from pathlib import Path
from unittest.mock import patch

import pytest

from weave_coaching import plan_promotions
from weave_quality.__main__ import cmd_patterns_scan
from weave_quality.coaching_evidence import (
    EvidenceError,
    _package_rule_manifest,
    build_promotion_input,
)
from weave_quality.db import (
    adjudicate_pattern_finding,
    init_db,
    latest_pattern_run,
    pattern_finding_states,
)

CATALOG = json.loads(
    (Path(__file__).resolve().parents[2] / "contracts" / "violation-vocabulary-v1.json")
    .read_text(encoding="utf-8")
)
SCOPE = {"target": ".", "review_parent": "wv-44e524"}

# Deliberately NOT `except Exception: pass`. The built-in bare-except-pass rule
# matches that, and the scanner suppresses a second rule firing at the identical
# (path, line, col) -- so the custom rule would silently record zero hits and
# this file would be testing the wrong rule. See test_scan_suppression below.
RULE = """id: swallow-check
language: python
violation_type: code:swallowed-exception
message: "Silenced exception hides errors."
severity: warning
rule:
  pattern: |
    try:
      $$$BODY
    except ValueError:
      pass
"""

SOURCE = """def risky():
    try:
        do_work()
    except ValueError:
        pass
"""

COLLIDING_SOURCE = """def other():
    try:
        do_work()
    except Exception:
        pass
"""


@pytest.fixture()
def scanned(tmp_path: Path) -> Path:
    """A repo with one rule, one matching file, and one completed scan."""
    rules = tmp_path / ".weave" / "patterns"
    rules.mkdir(parents=True)
    (rules / "swallow-check.yaml").write_text(RULE, encoding="utf-8")
    (tmp_path / "app.py").write_text(SOURCE, encoding="utf-8")
    subprocess.run(["git", "init", "-q"], cwd=tmp_path, check=True)
    subprocess.run(["git", "config", "user.email", "test@example.invalid"], cwd=tmp_path, check=True)
    subprocess.run(["git", "config", "user.name", "Weave Test"], cwd=tmp_path, check=True)
    subprocess.run(["git", "add", ".weave/patterns/swallow-check.yaml", "app.py"], cwd=tmp_path, check=True)
    subprocess.run(["git", "commit", "-qm", "fixture"], cwd=tmp_path, check=True)

    args = argparse.Namespace(hot_zone=str(tmp_path), path=str(tmp_path), json=True)
    with patch("weave_quality.__main__._resolve_repo", return_value=str(tmp_path)):
        assert cmd_patterns_scan(args) == 0
    return tmp_path


def _accept_everything(repo: Path) -> list[str]:
    conn = init_db(hot_zone=str(repo))
    keys = [str(state["finding_key"]) for state in pattern_finding_states(conn)]
    for key in keys:
        adjudicate_pattern_finding(conn, key, "accepted_defect", note="reviewed in test")
    conn.commit()
    conn.close()
    return keys


class TestPromotionInput:
    def test_unadjudicated_evidence_yields_no_observations(self, scanned: Path) -> None:
        """Recurrence is not acceptance: an unresolved finding never promotes."""
        document = build_promotion_input(scanned, CATALOG, SCOPE, hot_zone=str(scanned))

        assert document["snapshot"]["state"] == "complete"
        assert document["observations"] == []
        assert document["provider_rejections"] == []
        assert plan_promotions(document)["candidates"] == []

    def test_accepted_evidence_becomes_a_candidate(self, scanned: Path) -> None:
        keys = _accept_everything(scanned)
        assert keys, "the rule must actually match, or this proves nothing"

        document = build_promotion_input(scanned, CATALOG, SCOPE, hot_zone=str(scanned))
        assert [o["detector"]["finding_key"] for o in document["observations"]] == keys
        # Scoped to the rule under test: shipped rules legitimately declare
        # their own types, and whole-dict equality re-breaks every time one does.
        assert document["rule_violation_types"]["swallow-check"] == "code:swallowed-exception"
        binding = document["rule_definition_bindings"]["swallow-check"]
        assert binding["authority"] == "target_head"
        assert binding["revision"] == subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=scanned, capture_output=True, text=True, check=True
        ).stdout.strip()

        observation = document["observations"][0]
        # Raw, not normalized: normalization belongs to the planner.
        assert observation["match_text"]
        assert "anchor" not in observation
        # The line is a current-scan snapshot, and the durable row has none.
        assert observation["location"]["line"] >= 1

        plan = plan_promotions(document)
        assert len(plan["candidates"]) == 1
        candidate = plan["candidates"][0]
        assert candidate["violation_type"] == "code:swallowed-exception"
        assert candidate["promotion_id"].startswith("cp-")
        assert candidate["proposed_fix"], "a promoted finding needs real remediation"
        assert candidate["occurrences"][0]["anchor"]["path"] == "app.py"

    def test_the_resolved_guide_is_the_package_guide(self, scanned: Path) -> None:
        _accept_everything(scanned)
        document = build_promotion_input(
            scanned, CATALOG, SCOPE, hot_zone=str(scanned), language="python"
        )
        resolution = document["resolved_guides"]["code:swallowed-exception"]
        assert resolution["guide"]["id"] == "swallowed-exception"
        assert resolution["guide"]["language"] == "python"
        assert resolution["root_cause"] and resolution["proposed_fix"]
        # Identity travels; the prose body does not.
        assert set(resolution["guide"]) == {"id", "language", "source", "definition_hash"}

    def test_an_explicit_rule_scope_carries_only_its_authority(self, scanned: Path) -> None:
        _accept_everything(scanned)
        scope = {**SCOPE, "rule_ids": ["swallow-check"]}
        document = build_promotion_input(scanned, CATALOG, scope, hot_zone=str(scanned))

        assert set(document["rule_definition_bindings"]) == {"swallow-check"}
        assert len(plan_promotions(document)["candidates"]) == 1

    def test_a_stale_definition_hash_makes_the_snapshot_incomplete(self, scanned: Path) -> None:
        """Editing a rule after its scan invalidates the receipt, and an
        incomplete snapshot may not carry evidence or plan candidates."""
        _accept_everything(scanned)
        rule = scanned / ".weave" / "patterns" / "swallow-check.yaml"
        rule.write_text(RULE + "\n# touched after the scan\n", encoding="utf-8")
        subprocess.run(["git", "add", str(rule)], cwd=scanned, check=True)
        subprocess.run(["git", "commit", "-qm", "change rule"], cwd=scanned, check=True)

        document = build_promotion_input(scanned, CATALOG, SCOPE, hot_zone=str(scanned))
        assert document["snapshot"]["state"] == "incomplete"
        assert [c["reason"] for c in document["snapshot"]["causes"]] == ["definition_hash_stale"]
        assert document["observations"] == []
        assert plan_promotions(document)["candidates"] == []

    def test_a_dirty_rule_cannot_certify_its_own_scan(self, scanned: Path) -> None:
        """Receipt and worktree equality do not establish committed provenance."""
        rule = scanned / ".weave" / "patterns" / "swallow-check.yaml"
        rule.write_text(RULE + "\n# uncommitted scan bytes\n", encoding="utf-8")
        args = argparse.Namespace(hot_zone=str(scanned), path=str(scanned), json=True)
        with patch("weave_quality.__main__._resolve_repo", return_value=str(scanned)):
            assert cmd_patterns_scan(args) == 0

        document = build_promotion_input(scanned, CATALOG, SCOPE, hot_zone=str(scanned))
        assert document["snapshot"]["state"] == "incomplete"
        assert "repo_rule_not_at_head" in {
            cause["reason"] for cause in document["snapshot"]["causes"]
        }
        assert "swallow-check" not in document["rule_definition_bindings"]

    def test_an_accepted_row_absent_from_the_current_scan_is_rejected(
        self, scanned: Path
    ) -> None:
        """The durable row outlives the observation. Promoting from evidence
        nobody can currently see is what `not_current` exists to prevent."""
        _accept_everything(scanned)
        conn = init_db(hot_zone=str(scanned))
        run = latest_pattern_run(conn)
        assert run is not None
        conn.execute("DELETE FROM pattern_findings WHERE scan_id = ?", (run.id,))
        conn.commit()
        conn.close()

        document = build_promotion_input(scanned, CATALOG, SCOPE, hot_zone=str(scanned))
        assert document["snapshot"]["state"] == "complete"
        assert document["observations"] == []
        assert len(document["provider_rejections"]) == 1
        provider_rejection = document["provider_rejections"][0]
        assert provider_rejection["reason"] == "not_current"
        assert "anchor" not in provider_rejection

        plan = plan_promotions(document)
        assert plan["candidates"] == []
        assert len(plan["rejected"]) == 1
        rejection = plan["rejected"][0]
        assert rejection["reason"] == "not_current"
        assert rejection["finding_key"] == provider_rejection["detector"]["finding_key"]
        assert rejection["anchor"]["path"] == "app.py"

    def test_duplicate_current_key_fails_closed_instead_of_choosing_a_location(
        self, scanned: Path
    ) -> None:
        _accept_everything(scanned)
        conn = init_db(hot_zone=str(scanned))
        run = latest_pattern_run(conn)
        assert run is not None
        conn.execute(
            "INSERT INTO pattern_findings "
            "(scan_id, finding_key, path, rule_id, line, col, match_text, severity) "
            "SELECT scan_id, finding_key, path, rule_id, line + 1, col, match_text, severity "
            "FROM pattern_findings WHERE scan_id = ? LIMIT 1",
            (run.id,),
        )
        conn.commit()
        conn.close()

        with pytest.raises(EvidenceError) as caught:
            build_promotion_input(scanned, CATALOG, SCOPE, hot_zone=str(scanned))
        assert caught.value.code == "duplicate_current_finding_key"

    def test_a_rule_declaring_no_violation_type_is_unmapped(self, scanned: Path) -> None:
        """An unmapped rule's observations reach the planner and are rejected
        there by name, rather than being guessed into some default type."""
        rule = scanned / ".weave" / "patterns" / "swallow-check.yaml"
        rule.write_text(RULE.replace("violation_type: code:swallowed-exception\n", ""),
                        encoding="utf-8")
        subprocess.run(["git", "add", str(rule)], cwd=scanned, check=True)
        subprocess.run(["git", "commit", "-qm", "remove mapping"], cwd=scanned, check=True)
        args = argparse.Namespace(hot_zone=str(scanned), path=str(scanned), json=True)
        with patch("weave_quality.__main__._resolve_repo", return_value=str(scanned)):
            assert cmd_patterns_scan(args) == 0
        _accept_everything(scanned)

        document = build_promotion_input(scanned, CATALOG, SCOPE, hot_zone=str(scanned))
        assert "swallow-check" not in document["rule_violation_types"]
        plan = plan_promotions(document)
        assert plan["candidates"] == []
        assert [r["reason"] for r in plan["rejected"]] == ["uncatalogued_violation_type"]


class TestFailureModes:
    def test_package_manifest_is_an_exact_inventory_and_digest_authority(
        self, tmp_path: Path
    ) -> None:
        source = Path(__file__).resolve().parents[2] / "scripts/weave_quality/default_patterns"
        copied = tmp_path / "default_patterns"
        shutil.copytree(source, copied)
        rules, _manifest_hash = _package_rule_manifest(copied)
        assert set(rules) == {path.name for path in copied.glob("*.yaml")}

        (copied / "unexpected.yaml").write_text("id: unexpected\n", encoding="utf-8")
        with pytest.raises(ValueError, match="exact .yaml inventory"):
            _package_rule_manifest(copied)

        (copied / "unexpected.yaml").unlink()
        first = next(copied.glob("*.yaml"))
        first.write_text(first.read_text(encoding="utf-8") + "\n# tampered\n", encoding="utf-8")
        with pytest.raises(ValueError, match="differs from its manifest digest"):
            _package_rule_manifest(copied)

    def test_a_missing_database_is_refused(self, tmp_path: Path) -> None:
        with pytest.raises(EvidenceError) as caught:
            build_promotion_input(tmp_path, CATALOG, SCOPE, hot_zone=str(tmp_path))
        assert caught.value.code == "no_database"


class TestScanSuppression:
    """What the scanner does to two rules that fire at one spot.

    Recorded here because it bounds what promotion can ever see. The scanner
    suppresses a same-(path, line, col) collision between rules and keeps the
    higher-maturity one, so the loser's finding never reaches durable state and
    its provenance is gone before any promotion runs. Cross-rule merge in the
    planner therefore applies to collisions the scanner does NOT suppress --
    equal normalized text at different positions -- not to this case.
    """

    def test_a_same_span_collision_reaches_promotion_as_one_rule(self, tmp_path: Path) -> None:
        rules = tmp_path / ".weave" / "patterns"
        rules.mkdir(parents=True)
        # A rule that competes with the built-in bare-except-pass on one span.
        (rules / "swallow-check.yaml").write_text(
            RULE.replace("except ValueError:", "except Exception:"), encoding="utf-8"
        )
        (tmp_path / "app.py").write_text(COLLIDING_SOURCE, encoding="utf-8")

        args = argparse.Namespace(hot_zone=str(tmp_path), path=str(tmp_path), json=True)
        with patch("weave_quality.__main__._resolve_repo", return_value=str(tmp_path)):
            assert cmd_patterns_scan(args) == 0

        conn = init_db(hot_zone=str(tmp_path))
        states = pattern_finding_states(conn)
        conn.close()

        # Both rules matched, but only one durable row exists, and the other
        # rule's finding_key is unrecoverable from here.
        assert len(states) == 1
        assert {str(s["rule_id"]) for s in states} == {"bare-except-pass"}
