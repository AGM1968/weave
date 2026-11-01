"""wv-60bf88: a repository declares its own violation types (memory graduation S2).

A detector under .weave/patterns whose violation_type is project:<name> admits
that type in its repository only, coached by .weave/guides/<name>[.<language>].md.
The shipped vocabulary may never hold a project: type.
"""

from __future__ import annotations

# pylint: disable=missing-class-docstring,missing-function-docstring

import json
from pathlib import Path
from typing import Any

import pytest

from weave_quality.guides import (
    GuideError,
    default_catalog,
    doctor_report,
    project_types,
    resolve,
    with_project_types,
)


def _catalog() -> dict[str, Any]:
    catalog: dict[str, Any] = json.loads(default_catalog().read_text(encoding="utf-8"))
    return catalog


def _detector(root: Path, rule_id: str, violation_type: str) -> None:
    patterns = root / ".weave" / "patterns"
    patterns.mkdir(parents=True, exist_ok=True)
    (patterns / f"{rule_id}.yaml").write_text(
        f"id: {rule_id}\nlanguage: bash\nviolation_type: {violation_type}\nrule:\n  pattern: rm $X\n",
        encoding="utf-8",
    )


def _guide(root: Path, name: str, language: str | None, marker: str) -> None:
    guides = root / ".weave" / "guides"
    guides.mkdir(parents=True, exist_ok=True)
    stem = f"{name}.{language}" if language else name
    lines = ["---", f"id: {name}", f"violation_type: project:{name}", f"summary: {marker}"]
    if language:
        lines.append(f"language: {language}")
    lines += ["---", "", "## Why", "", f"{marker} costs.", "", "## Corrective move", "", "Fix it.", ""]
    (guides / f"{stem}.md").write_text("\n".join(lines), encoding="utf-8")


class TestProjectTypes:
    def test_a_declaring_detector_admits_its_type(self, tmp_path: Path) -> None:
        _detector(tmp_path, "house-db-rm", "project:house-db")
        assert project_types(tmp_path) == {"project:house-db": {"status": "project", "guide": "house-db"}}

    def test_a_repository_without_detectors_declares_nothing(self, tmp_path: Path) -> None:
        assert not project_types(tmp_path)
        assert not project_types(None)

    def test_a_catalogued_type_on_a_detector_is_not_a_declaration(self, tmp_path: Path) -> None:
        _detector(tmp_path, "local-rule", "code:swallowed-exception")
        assert not project_types(tmp_path)

    def test_a_malformed_project_name_is_refused(self, tmp_path: Path) -> None:
        _detector(tmp_path, "bad", "project:Bad_Name")
        with pytest.raises(GuideError):
            project_types(tmp_path)

    def test_the_shipped_vocabulary_may_not_hold_a_project_type(self) -> None:
        forged = _catalog()
        forged["types"]["project:smuggled"] = {"status": "canonical", "guide": "smuggled"}
        with pytest.raises(GuideError):
            with_project_types(forged, None)


class TestResolution:
    def test_the_language_variant_resolves_before_the_generic_guide(self, tmp_path: Path) -> None:
        _detector(tmp_path, "house-db-rm", "project:house-db")
        _guide(tmp_path, "house-db", None, "GENERIC")
        _guide(tmp_path, "house-db", "bash", "BASH")
        catalog = with_project_types(_catalog(), tmp_path)
        assert resolve("project:house-db", catalog, "bash", tmp_path).summary == "BASH"
        assert resolve("project:house-db", catalog, "python", tmp_path).summary == "GENERIC"
        assert resolve("project:house-db", catalog, None, tmp_path).source == "project"

    def test_another_repository_rejects_the_type(self, tmp_path: Path) -> None:
        declaring, other = tmp_path / "a", tmp_path / "b"
        _detector(declaring, "house-db-rm", "project:house-db")
        _guide(declaring, "house-db", None, "GENERIC")
        with pytest.raises(GuideError) as raised:
            resolve("project:house-db", with_project_types(_catalog(), other), None, other)
        assert raised.value.code == "uncatalogued_violation_type"

    def test_doctor_counts_a_project_guide_as_used(self, tmp_path: Path) -> None:
        _detector(tmp_path, "house-db-rm", "project:house-db")
        _guide(tmp_path, "house-db", None, "GENERIC")
        report = doctor_report(_catalog(), tmp_path)
        assert report["unused"] == [] and report["invalid"] == [] and report["unresolved"] == []

    def test_doctor_reports_a_guide_for_an_undeclared_project_type_unused(self, tmp_path: Path) -> None:
        _guide(tmp_path, "house-db", None, "GENERIC")
        assert doctor_report(_catalog(), tmp_path)["unused"] == ["house-db.md"]
