"""Plan canonical promotions from normalized accepted evidence.

Pure: `plan_promotions` maps one `weave.coaching-promotion-input.v1` document to
one `weave.coaching-promotion-plan.v1` document and touches nothing else.

The three decisions worth reading before changing anything here:

* **Normalization is ours, not the provider's.** The provider emits raw
  `match_text` and `context_text`; this module folds them to the anchor. Moving
  it upstream would make normalization provider behaviour and leave the frozen
  cases proving nothing about the planner.
* **The anchor is not `qf-*`.** A detector's finding key embeds its rule id and
  a per-rule ordinal, so two rules seeing one defect can never share one. The
  conceptual anchor is (path, normalized match, normalized context) -- the
  durable content key with the rule id removed. Line and column are display
  data: they live only in the prunable scan table and were deliberately kept out
  of `qf-*` identity.
* **Merging is conservative.** Two rules reporting one anchor become one
  occurrence. A rule reporting the same anchor more than once makes the pairing
  ambiguous -- which of its observations is the other rule's? -- so nothing in
  that anchor merges until a reviewer says so.
"""

from __future__ import annotations

import hashlib
import json
import unicodedata
from typing import Any

INPUT_FORMAT = "weave.coaching-promotion-input.v1"
PLAN_FORMAT = "weave.coaching-promotion-plan.v1"
CATALOG_VERSION = "weave.violation-vocabulary.v1"

_MERGE_DECLINED_REPEATED = "repeated_anchor_within_rule"


class PlannerError(ValueError):
    """The input document cannot be planned as given."""


def normalize_text(value: str) -> str:
    """Fold a fragment to its identity form: NFKC, then collapse whitespace.

    Mirrors the quality scanner's own normalization so an anchor derived here
    and a content key derived there agree about what counts as the same text.
    """
    return " ".join(unicodedata.normalize("NFKC", value).split())


def anchor_of(observation: dict[str, Any]) -> dict[str, str]:
    """The conceptual location identity of one raw observation."""
    return {
        "path": observation["path"],
        "normalized_match": normalize_text(observation["match_text"]),
        "normalized_context": normalize_text(observation["context_text"]),
    }


def _anchor_key(anchor: dict[str, str]) -> tuple[str, str, str]:
    return (anchor["path"], anchor["normalized_match"], anchor["normalized_context"])


def _observation_key(observation: dict[str, Any]) -> tuple[str, str, str, str, str]:
    """Canonical order for evidence whose provider order has no semantics."""
    anchor = anchor_of(observation)
    detector = observation["detector"]
    return (*_anchor_key(anchor), detector["rule_id"], detector["finding_key"])


def _provider_rejection(rejection: dict[str, Any]) -> dict[str, Any]:
    """Canonicalize one provider refusal without making it promotable."""
    detector = rejection["detector"]
    return {
        "reason": rejection["reason"],
        "rule_id": detector["rule_id"],
        "finding_key": detector["finding_key"],
        "anchor": anchor_of(rejection),
        "detail": rejection["detail"],
    }


def promotion_id(
    violation_type: str,
    guide: dict[str, Any],
    scope: dict[str, Any],
) -> str:
    """The stable promotion identity for a candidate.

    Derived from the violation type, the resolved guide's id and language, and
    the reviewed scope -- never from display order, line or column, a detector
    message, source text, or the guide's digest. The digest in particular is
    machine-local once a project override exists, so including it would make two
    hosts disagree about identity for the same defect.
    """
    payload = json.dumps(
        [
            violation_type,
            guide["id"],
            guide.get("language"),
            scope["target"],
            scope["review_parent"],
            sorted(scope.get("rule_ids") or []),
        ],
        separators=(",", ":"),
    )
    return "cp-" + hashlib.sha256(payload.encode("utf-8")).hexdigest()


def _detector_record(observation: dict[str, Any]) -> dict[str, Any]:
    """The detector record a plan carries, dropping provider-only fields."""
    detector = observation["detector"]
    record = {
        "rule_id": detector["rule_id"],
        "finding_key": detector["finding_key"],
        "disposition": detector["disposition"],
        "scan_count": detector["scan_count"],
    }
    for optional in ("content_key", "message", "severity", "definition_hash"):
        if detector.get(optional):
            record[optional] = detector[optional]
    return record


def _occurrences_for(observations: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Group one violation type's observations into rendered occurrences.

    Grouping is by anchor; within an anchor, merging happens only when every
    contributing rule reported it exactly once. Order follows first arrival, so
    a plan does not depend on dict iteration order.
    """
    groups: dict[tuple[str, str, str], list[dict[str, Any]]] = {}
    anchors: dict[tuple[str, str, str], dict[str, str]] = {}
    for observation in sorted(observations, key=_observation_key):
        anchor = anchor_of(observation)
        key = _anchor_key(anchor)
        groups.setdefault(key, []).append(observation)
        anchors.setdefault(key, anchor)

    occurrences: list[dict[str, Any]] = []
    for key in sorted(groups):
        group = groups[key]
        counts: dict[str, int] = {}
        for observation in group:
            rule = observation["detector"]["rule_id"]
            counts[rule] = counts.get(rule, 0) + 1
        ambiguous = any(count > 1 for count in counts.values())

        if not ambiguous and len(group) > 1:
            occurrence: dict[str, Any] = {
                "anchor": anchors[key],
                "merged": True,
                "detectors": [_detector_record(o) for o in group],
            }
            location = _agreed_location(group)
            if location is not None:
                occurrence["location"] = location
            occurrences.append(occurrence)
            continue

        # Either one observation, or several the merge will not pair up. Each
        # keeps its own record and its own snapshot location.
        for observation in group:
            occurrence = {
                "anchor": anchors[key],
                "merged": False,
                "detectors": [_detector_record(observation)],
            }
            if ambiguous:
                occurrence["merge_declined"] = _MERGE_DECLINED_REPEATED
            if observation.get("location"):
                occurrence["location"] = observation["location"]
            occurrences.append(occurrence)
    return occurrences


def _agreed_location(group: list[dict[str, Any]]) -> dict[str, Any] | None:
    """The snapshot location a merged group does not contradict itself about.

    Two rules can report one anchor at different lines -- one matched the
    statement, the other the block that contains it. A merged occurrence shows a
    line only when they agree; a wrong line teaches the reader something untrue,
    while a missing one renders as a path and costs nothing.
    """
    locations = [o.get("location") for o in group]
    if not locations or any(location is None for location in locations):
        return None
    first = locations[0]
    if first is not None and all(location == first for location in locations[1:]):
        return dict(first)
    return None


def plan_promotions(document: dict[str, Any]) -> dict[str, Any]:
    """Map one promotion input to its plan.

    Raises :class:`PlannerError` when the document is not a promotion input at
    all. Everything a reviewer might disagree with -- an uncatalogued type, a
    rule with no mapping -- is reported as a rejection inside the plan rather
    than an exception, because a plan that lists what it refused is reviewable
    and a traceback is not.
    """
    if document.get("format") != INPUT_FORMAT:
        raise PlannerError(f"expected {INPUT_FORMAT}, got {document.get('format')!r}")
    if document.get("catalog_version") != CATALOG_VERSION:
        raise PlannerError(
            f"expected catalog {CATALOG_VERSION}, got {document.get('catalog_version')!r}"
        )

    scope = dict(document["scope"])
    if "rule_ids" in scope:
        scope["rule_ids"] = sorted(scope["rule_ids"])
    snapshot = document["snapshot"]
    plan: dict[str, Any] = {
        "format": PLAN_FORMAT,
        "scope": scope,
        "catalog_version": CATALOG_VERSION,
        "snapshot": snapshot,
        "candidates": [],
    }

    # Fail closed: an incomplete snapshot plans nothing, whatever it carries.
    if snapshot.get("state") != "complete":
        return plan

    mapping = document["rule_violation_types"]
    definition_bindings = document["rule_definition_bindings"]
    scoped_rules = set(scope.get("rule_ids") or [])
    if scoped_rules and set(definition_bindings) != scoped_rules:
        raise PlannerError("a complete input must bind exactly its reviewed rule_ids")
    guides = document["resolved_guides"]
    catalog_types = set(document["catalog_violation_types"])

    by_violation: dict[str, list[dict[str, Any]]] = {}
    rejected = [
        _provider_rejection(item)
        for item in sorted(document["provider_rejections"], key=_observation_key)
    ]

    for observation in sorted(document["observations"], key=_observation_key):
        detector = observation["detector"]
        if detector.get("disposition") != "accepted_defect":
            rejected.append({
                "reason": "not_accepted",
                "rule_id": detector["rule_id"],
                "anchor": anchor_of(observation),
                "detail": f"disposition is {detector.get('disposition')!r}",
            })
            continue
        binding = definition_bindings.get(detector["rule_id"])
        if binding is None:
            rejected.append({
                "reason": "conflicting_detector_facts",
                "rule_id": detector["rule_id"],
                "anchor": anchor_of(observation),
                "detail": "rule has no authorized definition binding",
            })
            continue
        violation_type = mapping.get(detector["rule_id"])
        if not violation_type:
            rejected.append({
                "reason": "uncatalogued_violation_type",
                "rule_id": detector["rule_id"],
                "anchor": anchor_of(observation),
                "detail": "rule declares no violation_type reference",
            })
            continue
        if violation_type not in catalog_types:
            rejected.append({
                "reason": "uncatalogued_violation_type",
                "rule_id": detector["rule_id"],
                "anchor": anchor_of(observation),
                "detail": f"{violation_type!r} is absent from the input catalog",
            })
            continue
        if violation_type not in guides:
            rejected.append({
                "reason": "no_guide_and_no_reviewed_fallback",
                "rule_id": detector["rule_id"],
                "anchor": anchor_of(observation),
                "detail": f"no resolved guide for {violation_type}",
            })
            continue
        by_violation.setdefault(violation_type, []).append(observation)

    for violation_type in sorted(by_violation):
        observations = by_violation[violation_type]
        resolution = guides[violation_type]
        guide = resolution["guide"]
        candidate: dict[str, Any] = {
            "promotion_id": promotion_id(violation_type, guide, scope),
            "violation_type": violation_type,
            "guide": guide,
            # Advisory unless the host reviewed it up: a promoted audit record
            # never becomes blocking work by default, and never by recurrence.
            "policy": resolution.get("policy", "advisory"),
            "root_cause": resolution["root_cause"],
            "proposed_fix": resolution["proposed_fix"],
            "occurrences": _occurrences_for(observations),
            "rule_definition_bindings": {
                rule_id: definition_bindings[rule_id]
                for rule_id in sorted({o["detector"]["rule_id"] for o in observations})
            },
        }
        for optional in ("confidence", "fixable"):
            if optional in resolution:
                candidate[optional] = resolution[optional]
        plan["candidates"].append(candidate)

    if rejected:
        plan["rejected"] = rejected
    return plan
