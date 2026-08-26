#!/usr/bin/env python3
"""Render coaching responses for a set of scenarios and check their invariants.

Writes each rendered envelope to the output directory so the shell suite can
validate them against contracts/coaching-response-v1.schema.json with ajv --
schema validity and behavioural correctness are different questions and both
have to be asked.

Reports one PROBLEM line per violation, then a COUNT line.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))

from weave_coaching import view  # noqa: E402
from weave_quality import guides as guide_resolver  # noqa: E402

CATALOG = json.loads(
    Path("contracts/violation-vocabulary-v1.json").read_text(encoding="utf-8")
)
VIOLATION = "code:swallowed-exception"


def anchor(path: str, match: str) -> dict[str, object]:
    return {"path": path, "normalized_match": match, "normalized_context": match}


def occurrence(path: str, match: str, line: int | None, rule: str = "bare-except-pass"):
    entry: dict[str, object] = {
        "anchor": anchor(path, match),
        "detectors": [{"rule_id": rule, "finding_key": "qf-" + "a" * 64,
                       "message": "Silenced exception hides errors."}],
    }
    if line is not None:
        entry["location"] = {"scan_id": 1, "line": line}
    return entry


def finding(occurrences: list[dict[str, object]], **extra: object) -> dict[str, object]:
    base = {"violation_type": VIOLATION, "occurrences": occurrences}
    base.update(extra)
    return base


def check(out_dir: Path) -> list[str]:
    problems: list[str] = []
    guide = guide_resolver.resolve(VIOLATION, CATALOG, "python").content()
    guides = {VIOLATION: guide}
    complete = {"state": "complete"}

    def emit(name: str, response: dict[str, object]) -> None:
        (out_dir / f"{name}.json").write_text(json.dumps(response, indent=2) + "\n")

    # 1. Nothing to report, and the clean message is qualified.
    clean = view.render_response([], guides, complete)
    emit("clean", clean)
    if clean["state"] != "complete_clean":
        problems.append(f"an empty complete run must be complete_clean, got {clean['state']}")
    if "causes" in clean:
        problems.append("a clean response may not carry causes")
    if "correctness" not in clean.get("clean_message", ""):
        problems.append("the clean message must qualify what these rules do not check")

    # 2. Findings present: no clean message may ride along.
    single = view.render_response([finding([occurrence("a.py", "except Exception: pass", 12)])],
                                  guides, complete)
    emit("with-findings", single)
    if single["state"] != "complete_with_findings":
        problems.append(f"findings must yield complete_with_findings, got {single['state']}")
    if "clean_message" in single:
        problems.append("a response with findings may not carry a clean message")

    # 3. Bounded sampling reports the TRUE total, not the sample size.
    many = [occurrence(f"f{i}.py", f"except Exception: pass  # {i}", i + 1) for i in range(9)]
    bounded = view.render_response([finding(many)], guides, complete, limit=3)
    emit("bounded", bounded)
    block = bounded["blocks"][0]
    if block["occurrence_count"] != 9:
        problems.append(f"occurrence_count must be the true total, got {block['occurrence_count']}")
    if len(block["occurrences"]) != 3:
        problems.append(f"the sample must respect the limit, got {len(block['occurrences'])}")
    if not block.get("sampled") or not bounded.get("bounded"):
        problems.append("a trimmed listing must say so via sampled/bounded")
    text = view.render_text(bounded)
    if "6 more" not in text:
        problems.append("bounded text must name how many occurrences it did not show")

    # 4. Complete JSON keeps every occurrence when nothing is trimmed.
    unbounded = view.render_response([finding(many)], guides, complete, limit=None)
    emit("unbounded", unbounded)
    if len(unbounded["blocks"][0]["occurrences"]) != 9:
        problems.append("an untrimmed response must retain every occurrence")
    if unbounded["blocks"][0].get("sampled") or unbounded.get("bounded"):
        problems.append("an untrimmed response must not claim to be sampled")

    # 5. A file-scoped occurrence carries no line rather than a placeholder.
    file_scoped = view.render_response(
        [finding([occurrence("whole.md", "document-scope observation", None)])], guides, complete
    )
    emit("file-scope", file_scoped)
    rendered = file_scoped["blocks"][0]["occurrences"][0]
    if rendered.get("shape") != "file" or "line" in rendered:
        problems.append("a locationless occurrence must render as file shape with no line")
    if ":" in view.render_text(file_scoped).split("whole.md")[1][:1]:
        problems.append("file-shaped text must not print a path:line separator")

    # 6. Incomplete wins over everything, and still shows what did complete.
    partial = view.render_response(
        [finding([occurrence("a.py", "except Exception: pass", 12)])],
        guides,
        {"state": "incomplete", "causes": [
            {"reason": "receipt_failed", "rule_id": "unquoted-variable",
             "detail": "rule execution failed", "remedy": "wv quality patterns scan"}]},
    )
    emit("incomplete", partial)
    if partial["state"] != "incomplete":
        problems.append("an incomplete snapshot must produce state=incomplete even with findings")
    if "clean_message" in partial:
        problems.append("an incomplete response may never carry a clean message")
    if not partial["blocks"]:
        problems.append("findings from rules that did complete must still render")
    if partial["causes"][0]["code"] != "receipt_failed":
        problems.append("a cause reason must map onto the response cause code")
    incomplete_text = view.render_text(partial)
    if "[incomplete]" not in incomplete_text or "cannot be trusted" not in incomplete_text:
        problems.append("incomplete text must say the result cannot be trusted")

    # 7. The fallback still coaches and names the gap.
    fallback = guide_resolver.resolve("repo:hygiene", CATALOG).content()
    uncoached = view.render_response(
        [{"violation_type": "repo:hygiene",
          "occurrences": [occurrence("x.py", "something", 3)]}],
        {"repo:hygiene": fallback},
        complete,
    )
    emit("uncoached", uncoached)
    if not uncoached["blocks"][0]["guide"].get("names_missing_guide"):
        problems.append("the fallback must declare that a specific guide is missing")
    if "No specific guide exists" not in view.render_text(uncoached):
        problems.append("fallback text must name the missing guide rather than imply none is needed")

    # 8. Refusals: data that cannot be rendered honestly is refused, not patched.
    try:
        view.render_response([finding([occurrence("a.py", "x", 1)])], {}, complete)
        problems.append("a finding with no resolved guide must be refused")
    except view.ViewError:
        pass
    try:
        view.render_response([], guides, {"state": "incomplete", "causes": []})
        problems.append("an incomplete snapshot with no causes must be refused")
    except view.ViewError:
        pass

    # 9. Occurrence sampling alone is not a text budget: guide prose, paths,
    # content, blocks and causes can each be large. Exercise multibyte text so
    # the cap is proven in UTF-8 bytes, not Python characters, and confirm the
    # complete envelope is not mutated to make the text fit.
    large_guide = dict(guide)
    large_guide["why"] = "why-λ " * view.MAX_TEXT_BYTES
    oversized = view.render_response(
        [finding([occurrence("large.py", "except Exception: pass", 1)])],
        {VIOLATION: large_guide},
        complete,
    )
    emit("oversized-text", oversized)
    oversized_text = view.render_text(oversized)
    if len(oversized_text.encode("utf-8")) > view.MAX_TEXT_BYTES:
        problems.append("default text rendering exceeds its UTF-8 byte budget")
    if not oversized_text.endswith(view.TRUNCATION_MARKER):
        problems.append("truncated text must end with the explicit JSON escape-hatch marker")
    if oversized["blocks"][0]["guide"]["why"] != large_guide["why"]:
        problems.append("text truncation must not discard evidence from the JSON envelope")

    return problems


def main() -> int:
    out_dir = Path(sys.argv[1])
    out_dir.mkdir(parents=True, exist_ok=True)
    for problem in check(out_dir):
        print("PROBLEM " + problem)
    print(f"COUNT {len(sorted(out_dir.glob('*.json')))}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
