#!/usr/bin/env python3
"""Check the frozen coaching fixtures against the contracts they stand for.

Phase 0 has no planner, so this does not replay one. It proves the fixtures are
internally coherent and say what cases.json claims they say — an incoherent
frozen case is worse than none, because Phase 1 would be built to satisfy it.

Reports one PROBLEM line per violation, then a COUNT line. Anything unexpected
raises, so a crash exits non-zero instead of printing a short, clean-looking
report.
"""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

FIXTURES = Path("tests/fixtures/coaching/v1")


def derived_promotion_id(candidate: dict, scope: dict) -> str:
    guide = candidate["guide"]
    payload = json.dumps(
        [
            candidate["violation_type"],
            guide["id"],
            guide.get("language"),
            scope["target"],
            scope["review_parent"],
            sorted(scope.get("rule_ids") or []),
        ],
        separators=(",", ":"),
    )
    return "cp-" + hashlib.sha256(payload.encode("utf-8")).hexdigest()


def check_case(name: str, catalog: dict) -> list[str]:
    problems: list[str] = []
    input_doc = json.loads((FIXTURES / "cases" / f"{name}.input.json").read_text(encoding="utf-8"))
    plan_doc = json.loads((FIXTURES / "cases" / f"{name}.plan.json").read_text(encoding="utf-8"))

    if input_doc["scope"] != plan_doc["scope"]:
        problems.append(f"{name}: input and plan disagree about the reviewed scope")
    if input_doc["snapshot"]["state"] != plan_doc["snapshot"]["state"]:
        problems.append(f"{name}: input and plan disagree about snapshot state")

    membership = set(input_doc["catalog_violation_types"])
    unknown_membership = membership - set(catalog["types"])
    if unknown_membership:
        problems.append(f"{name}: input claims uncatalogued types {sorted(unknown_membership)!r}")
    mapped_types = set(input_doc["rule_violation_types"].values())
    if not mapped_types <= membership:
        problems.append(f"{name}: rule mapping contains types absent from input catalog membership")
    resolved_types = set(input_doc["resolved_guides"])
    if not resolved_types <= membership:
        problems.append(f"{name}: resolved guides contain types absent from input catalog membership")

    incomplete = plan_doc["snapshot"]["state"] == "incomplete"
    if incomplete:
        if input_doc["observations"]:
            problems.append(f"{name}: an incomplete snapshot may not carry observations")
        if input_doc["provider_rejections"]:
            problems.append(f"{name}: an incomplete snapshot may not carry provider rejections")
        if plan_doc["candidates"]:
            problems.append(f"{name}: an incomplete snapshot may not plan candidates")
        if not plan_doc["snapshot"].get("causes"):
            problems.append(f"{name}: an incomplete snapshot must name its causes")
        return problems

    for observation in input_doc["observations"]:
        if observation["detector"]["disposition"] != "accepted_defect":
            problems.append(f"{name}: only accepted_defect evidence may enter the planner")

    active_rules = set(input_doc["scope"].get("rule_ids", []))
    if set(input_doc["rule_definition_bindings"]) != active_rules:
        problems.append(f"{name}: complete input does not bind exactly its active rules")

    input_keys = {o["detector"]["finding_key"] for o in input_doc["observations"]}
    rejected_input_keys = {
        r["detector"]["finding_key"] for r in input_doc["provider_rejections"]
    }
    plan_keys: set[str] = set()

    for candidate in plan_doc["candidates"]:
        expected = derived_promotion_id(candidate, plan_doc["scope"])
        if candidate["promotion_id"] != expected:
            problems.append(
                f"{name}: promotion_id does not match its specified derivation "
                f"(expected {expected})"
            )
        if candidate["violation_type"] not in catalog["types"]:
            problems.append(f"{name}: violation_type is not catalogued")
        else:
            catalogued_guide = catalog["types"][candidate["violation_type"]]["guide"]
            if candidate["guide"]["id"] != catalogued_guide:
                problems.append(
                    f"{name}: guide id {candidate['guide']['id']!r} is not the catalogued "
                    f"guide for {candidate['violation_type']}"
                )

        detector_rules = {
            detector["rule_id"]
            for occurrence in candidate["occurrences"]
            for detector in occurrence["detectors"]
        }
        if set(candidate["rule_definition_bindings"]) != detector_rules:
            problems.append(f"{name}: candidate bindings do not match contributing rules")

        for occurrence in candidate["occurrences"]:
            detectors = occurrence["detectors"]
            plan_keys.update(d["finding_key"] for d in detectors)
            rules = [d["rule_id"] for d in detectors]
            merged = occurrence.get("merged", False)

            if merged and len(detectors) < 2:
                problems.append(f"{name}: an occurrence claims merged with one detector record")
            if merged and len(set(rules)) != len(rules):
                problems.append(
                    f"{name}: a merged occurrence repeats a rule; merging is across rules only"
                )
            if not merged and len(detectors) > 1:
                problems.append(
                    f"{name}: an unmerged occurrence carries several detector records"
                )
            if occurrence.get("merge_declined") and merged:
                problems.append(f"{name}: an occurrence is both merged and merge_declined")

    if input_keys != plan_keys:
        lost = sorted(input_keys - plan_keys)
        added = sorted(plan_keys - input_keys)
        if lost:
            problems.append(f"{name}: plan loses qf-* evidence present in the input: {len(lost)}")
        if added:
            problems.append(f"{name}: plan invents qf-* evidence absent from the input: {len(added)}")

    rejected_plan_keys = {
        r["finding_key"] for r in plan_doc.get("rejected", []) if r.get("finding_key")
    }
    if rejected_input_keys != rejected_plan_keys:
        problems.append(f"{name}: provider rejections do not survive into the plan exactly")
    if rejected_input_keys & plan_keys:
        problems.append(f"{name}: provider-rejected evidence became a candidate")

    return problems


def main() -> int:
    catalog = json.loads(
        Path("contracts/violation-vocabulary-v1.json").read_text(encoding="utf-8")
    )
    manifest = json.loads((FIXTURES / "cases.json").read_text(encoding="utf-8"))
    problems: list[str] = []

    declared = [case["name"] for case in manifest["planner_cases"]]
    on_disk = sorted(p.name[: -len(".input.json")] for p in (FIXTURES / "cases").glob("*.input.json"))
    for name in sorted(set(declared) - set(on_disk)):
        problems.append(f"cases.json declares {name}, which has no fixture on disk")
    for name in sorted(set(on_disk) - set(declared)):
        problems.append(f"{name} is on disk but undeclared in cases.json")

    for name in sorted(set(declared) & set(on_disk)):
        problems.extend(check_case(name, catalog))

    # The pairing the flip case rests on: same scope, same anchor, different verdict.
    flip = next((c for c in manifest["planner_cases"] if c.get("pairs_with")), None)
    if flip is not None:
        base = json.loads((FIXTURES / "cases" / f"{flip['pairs_with']}.plan.json").read_text(encoding="utf-8"))
        later = json.loads((FIXTURES / "cases" / f"{flip['name']}.plan.json").read_text(encoding="utf-8"))
        base_merged = any(o.get("merged") for c in base["candidates"] for o in c["occurrences"])
        later_merged = any(o.get("merged") for c in later["candidates"] for o in c["occurrences"])
        if not base_merged or later_merged:
            problems.append(
                f"{flip['name']}: the flip pair must merge in the base case and not in the later one"
            )
        base_ids = {c["promotion_id"] for c in base["candidates"]}
        later_ids = {c["promotion_id"] for c in later["candidates"]}
        if base_ids != later_ids:
            problems.append(
                f"{flip['name']}: promotion identity must survive the flip — only the plan changes"
            )

    for problem in problems:
        print("PROBLEM " + problem)
    print(f"COUNT {len(declared)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
