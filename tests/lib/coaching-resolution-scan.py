#!/usr/bin/env python3
"""Exercise the shipped guide resolver's chain, fallback, and failure modes.

Builds throwaway package and project guide trees, then asserts which layer wins
and which failures refuse to resolve. Reports one PROBLEM line per violation,
then a COUNT line; an unexpected condition raises so the caller sees a crash
rather than a short clean report.
"""

from __future__ import annotations

import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))

from weave_quality import guides  # noqa: E402  # pylint: disable=wrong-import-position

CATALOG = json.loads(Path("contracts/violation-vocabulary-v1.json").read_text(encoding="utf-8"))
VIOLATION = "code:swallowed-exception"
PACKAGE_GUIDES = Path("scripts/weave_quality/guides")


def write_guide(path: Path, guide_id: str, marker: str, language: str | None = None,
                violation: str = VIOLATION, sections: str | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    language_line = f"language: {language}\n" if language else ""
    body = sections if sections is not None else (
        f"\n## Why\n\n{marker}\n\n## Corrective move\n\nDo the {marker} thing.\n"
    )
    path.write_text(
        f"---\nid: {guide_id}\nviolation_type: {violation}\n{language_line}"
        f"summary: {marker}\n---\n{body}",
        encoding="utf-8",
    )


def scaffold(root: Path) -> tuple[Path, Path]:
    """A package tree with the three presentation guides, and an empty project tree."""
    package = root / "package-guides"
    package.mkdir(parents=True)
    for name in ("_clean.md", "_incomplete.md", "_uncoached.md"):
        (package / name).write_text(
            (PACKAGE_GUIDES / name).read_text(encoding="utf-8"), encoding="utf-8"
        )
    project = root / "project"
    (project / ".weave" / "guides").mkdir(parents=True)
    return package, project


def check() -> list[str]:
    problems: list[str] = []

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        package, project = scaffold(root)
        project_guides = project / ".weave" / "guides"

        write_guide(package / "swallowed-exception.md", "swallowed-exception", "package-generic")
        write_guide(package / "swallowed-exception.python.md", "swallowed-exception",
                    "package-python", language="python")

        # Package: a language variant outranks the generic guide.
        got = guides.resolve(VIOLATION, CATALOG, "python", package_dir=package)
        if got.summary != "package-python":
            problems.append(f"package language variant should win, got {got.summary!r}")
        got = guides.resolve(VIOLATION, CATALOG, None, package_dir=package)
        if got.summary != "package-generic":
            problems.append(f"package generic should serve a languageless finding, got {got.summary!r}")

        # A project GENERIC guide outranks a package LANGUAGE guide: the project
        # layer wins as a layer, not per-specificity. Getting this backwards
        # would silently ignore an override whenever a language variant shipped.
        write_guide(project_guides / "swallowed-exception.md", "swallowed-exception", "project-generic")
        got = guides.resolve(VIOLATION, CATALOG, "python", project_root=project, package_dir=package)
        if got.summary != "project-generic":
            problems.append(
                f"project generic must outrank a package language variant, got {got.summary!r}"
            )
        if got.source != "project":
            problems.append(f"resolved source should be 'project', got {got.source!r}")

        # Project language variant is the very top of the chain.
        write_guide(project_guides / "swallowed-exception.python.md", "swallowed-exception",
                    "project-python", language="python")
        got = guides.resolve(VIOLATION, CATALOG, "python", project_root=project, package_dir=package)
        if got.summary != "project-python":
            problems.append(f"project language variant must win, got {got.summary!r}")

        # A catalogued type with no guide of its own still coaches.
        got = guides.resolve("repo:hygiene", CATALOG, None, package_dir=package)
        if got.id != "_uncoached" or got.source != "fallback":
            problems.append(f"a guideless catalogued type must fall back, got {got.id!r}")
        if not got.content()["names_missing_guide"]:
            problems.append("the fallback must name that a specific guide is missing")
        if got.missing_guide_id != "repo-hygiene" or got.missing_violation_type != "repo:hygiene":
            problems.append("the fallback must identify the missing guide and violation type")

        # The resolution value carries the two summary fields a finding requires,
        # taken from the guide's own sections rather than invented.
        resolution = guides.resolve(
            VIOLATION, CATALOG, "python", project_root=project, package_dir=package
        ).resolution()
        if resolution["root_cause"] != "project-python":
            problems.append("resolution root_cause must come from the guide's Why section")
        if not resolution["proposed_fix"].startswith("Do the project-python"):
            problems.append("resolution proposed_fix must come from the Corrective move section")
        if "definition_hash" not in resolution["guide"]:
            problems.append("resolution must carry the guide digest as provenance")
        if set(resolution["guide"]) & {"why", "corrective_move", "sections"}:
            problems.append("a finding must store guide identity, never its prose body")

    # Failure modes get their own tree so a raised error cannot leave state behind.
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        package, project = scaffold(root)
        project_guides = project / ".weave" / "guides"
        write_guide(package / "swallowed-exception.md", "swallowed-exception", "package-generic")

        # An invalid override must refuse, NOT fall through to the package copy.
        write_guide(project_guides / "swallowed-exception.md", "swallowed-exception", "broken",
                    sections="\n## Why\n\nMissing its corrective move.\n")
        try:
            got = guides.resolve(VIOLATION, CATALOG, None, project_root=project, package_dir=package)
            problems.append(
                f"an invalid project override must fail closed; it resolved to {got.summary!r}"
            )
        except guides.GuideError as exc:
            if exc.code != "guide_override_invalid":
                problems.append(f"invalid override should report guide_override_invalid, got {exc.code!r}")

        # A guide claiming a different violation type than the one it was
        # resolved for is a mis-wired override, not a usable guide.
        write_guide(project_guides / "swallowed-exception.md", "swallowed-exception", "mismatched",
                    violation="repo:hygiene")
        try:
            guides.resolve(VIOLATION, CATALOG, None, project_root=project, package_dir=package)
            problems.append("a guide coaching another violation type must be refused")
        except guides.GuideError:
            pass

        # An uncatalogued type has no reviewed vocabulary behind it.
        try:
            guides.resolve("code:invented", CATALOG, None, package_dir=package)
            problems.append("an uncatalogued violation type must be refused")
        except guides.GuideError as exc:
            if exc.code != "uncatalogued_violation_type":
                problems.append(
                    "uncatalogued type should report uncatalogued_violation_type, "
                    f"got {exc.code!r}"
                )

        # A malformed catalog is distinct from a well-formed catalog that does
        # not contain the requested type; neither may escape as a raw KeyError.
        malformed_catalogs: tuple[dict[str, object], ...] = (
            {}, {"types": []}, {"types": {VIOLATION: {}}})
        for malformed in malformed_catalogs:
            try:
                guides.resolve(VIOLATION, malformed, None, package_dir=package)
                problems.append("a malformed catalog must be refused")
            except guides.GuideError as exc:
                if exc.code != "catalog_unreadable":
                    problems.append(
                        f"malformed catalog should report catalog_unreadable, got {exc.code!r}"
                    )

    return problems


def main() -> int:
    for problem in check():
        print("PROBLEM " + problem)
    print("COUNT 14")
    return 0


if __name__ == "__main__":
    sys.exit(main())
