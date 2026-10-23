"""The canonical applier: merge semantics, checked results, and idempotency.

Driven through an injected fake `wv` so every mutation the applier attempts is
visible and assertable. The two hazards under test are not hypothetical — both
are behaviours of code that ships today:

* `wv update --metadata[-file]` stores `json_patch(...)`, an RFC 7396 recursive
  merge, so an omitted nested key survives.
* the historical applier discards its `link` return codes, so a node with a
  missing edge reports success.
"""

# pylint: disable=missing-class-docstring,missing-function-docstring,redefined-outer-name,unused-argument

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pytest

from weave_quality.coaching_apply import (
    ApplyError,
    apply_plan,
    metadata_patch,
    plan_digest,
)

PROMOTION_ID = "cp-" + "a" * 64
PARENT = "wv-44e524"


def candidate(occurrence_paths: list[str]) -> dict[str, Any]:
    return {
        "promotion_id": PROMOTION_ID,
        "violation_type": "code:swallowed-exception",
        "guide": {"id": "swallowed-exception", "language": "python", "source": "package"},
        "policy": "advisory",
        "confidence": "high",
        "fixable": True,
        "root_cause": "A broad except discards an error nobody has named.",
        "proposed_fix": "Catch the specific error the call raises.",
        "occurrences": [
            {
                "anchor": {"path": p, "normalized_match": "except Exception: pass",
                           "normalized_context": "except Exception: pass"},
                "merged": False,
                "detectors": [{"rule_id": "bare-except-pass", "finding_key": "qf-" + "b" * 64,
                               "disposition": "accepted_defect", "scan_count": 1}],
            }
            for p in occurrence_paths
        ],
    }


def plan(occurrence_paths: list[str]) -> bytes:
    return json.dumps({
        "format": "weave.coaching-promotion-plan.v1",
        "scope": {"target": ".", "review_parent": PARENT, "rule_ids": ["bare-except-pass"]},
        "catalog_version": "weave.violation-vocabulary.v1",
        "snapshot": {"state": "complete"},
        "candidates": [candidate(occurrence_paths)],
    }).encode("utf-8")


class FakeWv:
    """A scriptable `wv`. Records every invocation; fails what it is told to."""

    def __init__(self, findings: list[dict[str, Any]] | None = None,
                 edges: list[dict[str, Any]] | None = None,
                 fail: dict[str, tuple[int, str]] | None = None) -> None:
        self.findings = findings or []
        self.edges = edges or []
        self.fail = fail or {}
        self.calls: list[tuple[str, ...]] = []

    def __call__(self, *args: str) -> tuple[int, str]:
        self.calls.append(args)
        verb = args[0]
        if verb in self.fail:
            return self.fail[verb]
        if args[:2] == ("findings", "list"):
            return 0, json.dumps(self.findings)
        if verb == "edges":
            return 0, json.dumps(self.edges)
        if verb == "add":
            return 0, "✓ wv-abc123: Finding: code:swallowed-exception (1 occurrence)"
        if verb in ("update", "link"):
            return 0, "✓ ok"
        raise AssertionError(f"unexpected command: {args}")

    def commands(self, verb: str) -> list[tuple[str, ...]]:
        return [c for c in self.calls if c[0] == verb]


class PatchWriter:  # pylint: disable=too-few-public-methods
    """A metadata writer that keeps every patch it was handed, in order."""

    def __init__(self, directory: Path) -> None:
        self.directory = directory
        self.written: list[dict[str, Any]] = []

    def __call__(self, patch: dict[str, Any]) -> str:
        self.written.append(patch)
        path = self.directory / f"patch{len(self.written)}.json"
        path.write_text(json.dumps(patch), encoding="utf-8")
        return str(path)


@pytest.fixture()
def writer(tmp_path: Path) -> PatchWriter:
    return PatchWriter(tmp_path)


def existing_node(occurrence_paths: list[str], extra: dict[str, Any] | None = None) -> dict[str, Any]:
    metadata = {
        "type": "finding",
        "finding": {
            "violation_type": "code:swallowed-exception",
            "root_cause": "old cause",
            "proposed_fix": "old fix",
            "policy": "advisory",
            "guide": {"id": "swallowed-exception", "language": "python", "source": "package"},
            "quality": {
                "promotion_id": PROMOTION_ID,
                "occurrences": [{"anchor": {"path": p}} for p in occurrence_paths],
                "decided_precision": 0.9,
            },
        },
    }
    if extra:
        metadata.update(extra)
    return {"id": "wv-abc123", "text": "Finding: old", "status": "todo", "metadata": metadata}


class TestMergePatch:
    def test_a_shrinking_plan_nulls_the_keys_it_dropped(self) -> None:
        """The ambiguity-flip case: scan N+1 holds fewer facts than scan N.

        Under RFC 7396 an omitted key survives, so without explicit nulls the
        node would keep describing evidence the reviewed plan does not contain.
        """
        current = {"finding": {"quality": {"promotion_id": PROMOTION_ID,
                                           "decided_precision": 0.9,
                                           "occurrences": [1, 2, 3]}}}
        desired = {"finding": {"quality": {"promotion_id": PROMOTION_ID, "occurrences": [1]}}}
        patch = metadata_patch(current, desired)
        assert patch["finding"]["quality"]["decided_precision"] is None
        assert patch["finding"]["quality"]["occurrences"] == [1]

    def test_metadata_outside_the_projection_is_never_touched(self) -> None:
        """A reviewer's note on the node is not ours to carry or to delete."""
        current = {"type": "finding", "reviewer_note": "keep me",
                   "finding": {"root_cause": "old"}}
        desired = {"type": "finding", "finding": {"root_cause": "new"}}
        patch = metadata_patch(current, desired)
        assert "reviewer_note" not in patch
        assert patch["finding"]["root_cause"] == "new"

    def test_an_unchanged_projection_produces_no_patch(self) -> None:
        current = {"type": "finding", "finding": {"root_cause": "same"}}
        patch = metadata_patch(current, {"type": "finding", "finding": {"root_cause": "same"}})
        assert patch == {}


class TestIdempotency:
    def test_no_existing_node_creates_and_links(self, writer: PatchWriter) -> None:
        wv = FakeWv(findings=[])
        result = apply_plan(plan(["a.py"]), run=wv, metadata_writer=writer)

        assert [r["action"] for r in result["applied"]] == ["create"]
        assert len(wv.commands("add")) == 1
        link = wv.commands("link")[0]
        assert link[1:] == ("wv-abc123", PARENT, "--type=references")

    def test_one_existing_node_updates_in_place(self, writer: PatchWriter) -> None:
        wv = FakeWv(findings=[existing_node(["a.py", "b.py"])],
                    edges=[{"source": "wv-abc123", "target": PARENT, "type": "references"}])
        result = apply_plan(plan(["a.py"]), run=wv, metadata_writer=writer)

        assert [r["action"] for r in result["applied"]] == ["update"]
        assert not wv.commands("add"), "an existing promotion must never create a second node"
        assert not wv.commands("link"), "an edge already present must not be re-created"
        patch = writer.written[0]
        assert patch["finding"]["quality"]["decided_precision"] is None

    def test_two_existing_nodes_fail_closed_without_mutating(self, writer: PatchWriter) -> None:
        duplicate = {**existing_node(["a.py"]), "id": "wv-def456"}
        wv = FakeWv(findings=[existing_node(["a.py"]), duplicate])

        with pytest.raises(ApplyError) as caught:
            apply_plan(plan(["a.py"]), run=wv, metadata_writer=writer)

        assert caught.value.code == "ambiguous_promotion_id"
        assert not wv.commands("add") and not wv.commands("update") and not wv.commands("link")

    def test_a_second_apply_of_the_same_plan_changes_nothing(self, writer: PatchWriter) -> None:
        """Re-running a reviewed plan must be inert, not additive."""
        wv = FakeWv(findings=[], edges=[])
        apply_plan(plan(["a.py"]), run=wv, metadata_writer=writer)
        created = json.loads(wv.commands("add")[0][2].removeprefix("--metadata="))

        settled = FakeWv(
            findings=[{"id": "wv-abc123", "text": "x", "status": "todo", "metadata": created}],
            edges=[{"source": "wv-abc123", "target": PARENT, "type": "references"}],
        )
        result = apply_plan(plan(["a.py"]), run=settled, metadata_writer=writer)

        assert [r["action"] for r in result["applied"]] == ["unchanged"]
        assert not settled.commands("add") and not settled.commands("update")
        assert not settled.commands("link")


class TestFailureHandling:
    def test_a_failed_link_raises_and_keeps_the_node(self, writer: PatchWriter) -> None:
        """The node stays. Deleting it would discard a real audit record and,
        on a transient failure, the only evidence the attempt happened."""
        wv = FakeWv(findings=[], edges=[], fail={"link": (1, "edge target not found")})

        with pytest.raises(ApplyError) as caught:
            apply_plan(plan(["a.py"]), run=wv, metadata_writer=writer)

        assert caught.value.code == "link_failed"
        assert len(wv.commands("add")) == 1
        assert not [c for c in wv.calls if c[0] == "delete"]

    def test_a_retry_after_a_failed_link_repairs_the_same_node(self, writer: PatchWriter) -> None:
        wv = FakeWv(
            findings=[existing_node(["a.py"])],
            edges=[],  # the link never landed
        )
        result = apply_plan(plan(["a.py"]), run=wv, metadata_writer=writer)

        assert result["applied"][0]["node_id"] == "wv-abc123"
        assert result["applied"][0]["links_repaired"] == [(PARENT, "references")]
        assert not wv.commands("add")

    def test_a_failed_update_is_reported_not_swallowed(self, writer: PatchWriter) -> None:
        wv = FakeWv(findings=[existing_node(["a.py", "b.py"])],
                    fail={"update": (1, "GraphPolicyViolation")})
        with pytest.raises(ApplyError) as caught:
            apply_plan(plan(["a.py"]), run=wv, metadata_writer=writer)
        assert caught.value.code == "update_failed"

    def test_an_incomplete_snapshot_cannot_be_applied(self, writer: PatchWriter) -> None:
        document = json.loads(plan(["a.py"]))
        document["snapshot"] = {"state": "incomplete",
                                "causes": [{"reason": "receipt_failed", "rule_id": "r"}]}
        with pytest.raises(ApplyError) as caught:
            apply_plan(json.dumps(document).encode(), run=FakeWv(), metadata_writer=writer)
        assert caught.value.code == "incomplete_snapshot"

    def test_a_document_that_is_not_a_plan_is_refused_before_any_call(self, writer: PatchWriter) -> None:
        # wv-e07ee4: without this check a foreign document with a complete
        # snapshot reached the graph writes.
        document = json.loads(plan(["a.py"]))
        document["format"] = "weave.coaching-promotion-input.v1"
        wv = FakeWv()
        with pytest.raises(ApplyError, match="not a promotion plan") as caught:
            apply_plan(json.dumps(document).encode(), run=wv, metadata_writer=writer)
        assert caught.value.code == "usage"
        assert not wv.calls


class TestPlanBytes:
    def test_the_digest_travels_into_the_node(self, writer: PatchWriter) -> None:
        raw = plan(["a.py"])
        wv = FakeWv(findings=[], edges=[])
        result = apply_plan(raw, run=wv, metadata_writer=writer)

        assert result["reviewed_plan_sha256"] == plan_digest(raw)
        created = json.loads(wv.commands("add")[0][2].removeprefix("--metadata="))
        assert created["coaching"]["reviewed_plan_sha256"] == plan_digest(raw)

    def test_review_parent_comes_from_the_plan(self, writer: PatchWriter) -> None:
        """Apply acts on the scope that was reviewed, not on an argument."""
        wv = FakeWv(findings=[], edges=[])
        result = apply_plan(plan(["a.py"]), run=wv, metadata_writer=writer)
        assert result["review_parent"] == PARENT
        assert wv.commands("link")[0][2] == PARENT

    def test_reformatted_plan_bytes_are_a_different_digest(self, writer: PatchWriter) -> None:
        """The bytes are the unit. A semantically equal re-serialisation is not
        the reviewed artifact, and must not silently pass as it."""
        raw = plan(["a.py"])
        reformatted = json.dumps(json.loads(raw), indent=2).encode("utf-8")
        assert plan_digest(raw) != plan_digest(reformatted)
