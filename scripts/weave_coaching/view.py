"""Render canonical finding data as a bounded coaching response.

Pure, like the planner: values in, values out. It does not run analyzers, read
guides from disk, change dispositions, create tasks, or decide policy -- it is a
view over data someone else resolved.

Two rules shape everything here.

**Bounded by default, complete in JSON.** Text output shows a small sample of
occurrences and the true total; an untrimmed JSON envelope keeps every
occurrence. A reader who is shown four of forty and told it is four has been
misled, so the count is always the real one and `sampled` says whether the list
was trimmed.

**Content teaches; the detector message is provenance.** The occurrence line
leads with the stored match or context. Twenty repetitions of "too many
parameters" beside twenty locations say almost nothing, while twenty matched
fragments lined up under each other show the reader the shape they need to fix.
"""

from __future__ import annotations

from typing import Any

RESPONSE_FORMAT = "weave.coaching-response.v1"
COMPLETE_CLEAN = "complete_clean"
COMPLETE_WITH_FINDINGS = "complete_with_findings"
INCOMPLETE = "incomplete"

DEFAULT_SAMPLE = 3
MAX_TEXT_BYTES = 12_288
TRUNCATION_MARKER = "\n... output truncated (use --json for complete evidence)\n"

# Said in the clean view because a green structural result is the easiest thing
# in the system to over-read.
DEFAULT_CLEAN_MESSAGE = (
    "Analysis completed with no accepted defect in scope. These rules check "
    "structure and prose habits; they do not check correctness or design."
)


class ViewError(ValueError):
    """The data handed to the view cannot be rendered as a valid response."""


def _occurrence_line(occurrence: dict[str, Any]) -> dict[str, Any]:
    """One rendered occurrence, in whichever of the two shapes fits it.

    A location-bearing entry carries the promotion-time line; a file-scoped one
    carries no line at all rather than a placeholder, because a fabricated line
    is worse than an honest path.
    """
    anchor = occurrence["anchor"]
    location = occurrence.get("location") or {}
    line = location.get("line")

    rendered: dict[str, Any] = {
        "path": anchor["path"],
        "content": anchor.get("normalized_match") or anchor.get("normalized_context", ""),
        "shape": "location" if line else "file",
        "detectors": [
            {
                key: detector[key]
                for key in ("rule_id", "message", "finding_key")
                if detector.get(key)
            }
            for detector in occurrence["detectors"]
        ],
    }
    if line:
        rendered["line"] = line
        if location.get("column"):
            rendered["column"] = location["column"]
    return rendered


def _guide_block(guide: dict[str, Any]) -> dict[str, Any]:
    """The guide block: the fixed sections, plus whatever the guide declared.

    `extended_sections` stays a nested list rather than being merged into this
    block. Its labels are authored downstream, so flattening them here would let
    a consumer guide name a key this block already owns.
    """
    block = {
        "id": guide["id"],
        "source": guide.get("source", "package"),
        "why": guide["why"],
        "corrective_move": guide["corrective_move"],
    }
    for optional in (
        "language",
        "expected_outcome",
        "avoid",
        "names_missing_guide",
        "extended_sections",
        # Carried, not dropped: these are what make the fallback honest. A
        # block that says a guide is missing without naming which one leaves
        # the reader unable to act on the gap, and the schema requires both
        # whenever names_missing_guide is set.
        "missing_guide_id",
        "missing_violation_type",
    ):
        if guide.get(optional) is not None:
            block[optional] = guide[optional]
    return block


def _coaching_block(
    finding: dict[str, Any],
    guide: dict[str, Any],
    limit: int | None,
) -> dict[str, Any]:
    occurrences = finding["occurrences"]
    shown = occurrences if limit is None else occurrences[:limit]

    block: dict[str, Any] = {
        "violation_type": finding["violation_type"],
        # The TRUE total, never len(shown): a sample presented as a total is a
        # lie the reader has no way to detect.
        "occurrence_count": len(occurrences),
        "occurrences": [_occurrence_line(o) for o in shown],
        "guide": _guide_block(guide),
    }
    if len(shown) != len(occurrences):
        block["sampled"] = True
    for optional in ("node_id", "policy", "confidence", "recurrence", "resolving"):
        if finding.get(optional) is not None:
            block[optional] = finding[optional]
    return block


def render_response(
    findings: list[dict[str, Any]],
    guides: dict[str, dict[str, Any]],
    snapshot: dict[str, Any],
    limit: int | None = DEFAULT_SAMPLE,
    clean_message: str | None = None,
) -> dict[str, Any]:
    """Build the coaching response envelope.

    The state is derived, never passed in: an incomplete snapshot is incomplete
    whatever it carries, and only a complete snapshot with nothing to say may
    produce a clean message. That is the whole point of the three states -- a
    caller cannot configure an unreliable result into a reassuring one.
    """
    incomplete = snapshot.get("state") != "complete"
    blocks: list[dict[str, Any]] = []
    for finding in findings:
        # A finding may name its guide: findings of one type in different
        # languages are coached by different guides.
        guide_key = finding.get("guide_key") or finding["violation_type"]
        guide = guides.get(guide_key)
        if guide is None:
            raise ViewError(f"no resolved guide supplied for {guide_key!r}")
        blocks.append(_coaching_block(finding, guide, limit))

    response: dict[str, Any] = {"format": RESPONSE_FORMAT, "blocks": blocks}

    if incomplete:
        causes = [
            {
                "code": cause["reason"] if "reason" in cause else cause["code"],
                **{k: v for k, v in cause.items() if k in ("rule_id", "path", "detail", "remedy")},
            }
            for cause in snapshot.get("causes", [])
        ]
        if not causes:
            # An incomplete result that cannot say why is not reportable: the
            # reader would be told to distrust the run with no way to fix it.
            raise ViewError("an incomplete snapshot must carry at least one typed cause")
        response["state"] = INCOMPLETE
        response["causes"] = causes
    elif blocks:
        response["state"] = COMPLETE_WITH_FINDINGS
    else:
        response["state"] = COMPLETE_CLEAN
        response["clean_message"] = clean_message or DEFAULT_CLEAN_MESSAGE

    if any(block.get("sampled") for block in blocks):
        response["bounded"] = True
    return response


def _bounded_text(text: str) -> str:
    """Truncate text to an exact UTF-8 budget without splitting a code point."""
    encoded = text.encode("utf-8")
    if len(encoded) <= MAX_TEXT_BYTES:
        return text

    marker = TRUNCATION_MARKER.encode("utf-8")
    prefix = encoded[: MAX_TEXT_BYTES - len(marker)].decode("utf-8", errors="ignore")
    return prefix.rstrip() + TRUNCATION_MARKER


def render_text(response: dict[str, Any]) -> str:
    """The byte-bounded text rendering every surface shares.

    Deliberately one renderer rather than one per surface: `findings`, `ready`,
    context and discovery drifting into three dialects of the same coaching is
    the fragmentation this whole slice exists to remove.
    """
    lines: list[str] = []

    if response["state"] == INCOMPLETE:
        lines.append("[incomplete] analysis did not complete; a clean result cannot be trusted.")
        lines.append("")
        for cause in response.get("causes", []):
            target = cause.get("rule_id") or cause.get("path") or "-"
            lines.append(f"  {cause['code']}  {target}")
            if cause.get("detail"):
                lines.append(f"      {cause['detail']}")
            if cause.get("remedy"):
                lines.append(f"      run: {cause['remedy']}")
        if response["blocks"]:
            lines.append("")
            lines.append("Findings from the rules that did complete are shown below.")
            lines.append("")
    elif response["state"] == COMPLETE_CLEAN:
        return _bounded_text(response.get("clean_message", DEFAULT_CLEAN_MESSAGE))

    for block in response["blocks"]:
        count = block["occurrence_count"]
        noun = "occurrence" if count == 1 else "occurrences"
        header = f"-- {block['violation_type']} ({count} {noun}) --"
        lines.append(header)
        lines.append("")
        guide = block["guide"]
        lines.append(guide["why"])
        lines.append("")
        for occurrence in block["occurrences"]:
            where = occurrence["path"]
            if occurrence.get("line"):
                where = f"{where}:{occurrence['line']}"
            lines.append(f"  {where}")
            if occurrence.get("content"):
                lines.append(f"      {occurrence['content']}")
        if block.get("sampled"):
            hidden = count - len(block["occurrences"])
            lines.append(f"  ... {hidden} more (use --json for the complete evidence)")
        lines.append("")
        lines.append(guide["corrective_move"])
        if guide.get("expected_outcome"):
            lines.append("")
            lines.append(guide["expected_outcome"])
        if guide.get("avoid"):
            lines.append("")
            lines.append(f"Avoid: {guide['avoid']}")
        # After the fixed four, in the order the guide's own body puts them.
        for extra in guide.get("extended_sections") or ():
            lines.append("")
            lines.append(f"{extra['label']}:")
            lines.append(extra["body"])
        if guide.get("names_missing_guide"):
            lines.append("")
            lines.append(
                f"No specific guide exists for {block['violation_type']} yet; "
                "the generic guidance above is standing in for one."
            )
        trailer = [
            f"policy={block['policy']}" if block.get("policy") else "",
            f"confidence={block['confidence']}" if block.get("confidence") else "",
            f"seen={block['recurrence']}x" if block.get("recurrence") else "",
        ]
        trailer = [part for part in trailer if part]
        if trailer:
            lines.append("")
            lines.append("  " + "  ".join(trailer))
        lines.append("")

    return _bounded_text("\n".join(lines).rstrip() + "\n")
