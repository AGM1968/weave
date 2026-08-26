"""Resolve and validate coaching guide assets.

This module reads the filesystem, which is exactly why it lives here and not in
`weave_coaching`: resolution is a host concern, and the pure planner and view
receive its answer as immutable values. It is also the one place that parses a
guide, so the production parser and the suite's validator cannot drift apart.

It must not touch `quality.db`. Guide resolution and quality evidence are two
different provider concerns that happen to share a package; only
`coaching_evidence` may open the database.

Resolution order, per contracts/coaching-guide-v1.schema.json:

    .weave/guides/<id>.<language>.md      project, language-specific
    .weave/guides/<id>.md                 project, generic
    <package>/guides/<id>.<language>.md   package, language-specific
    <package>/guides/<id>.md              package, generic
    <package>/guides/_uncoached.md        fallback

First hit wins; layers are never merged. A project override that fails
validation is NOT skipped in favour of the package copy -- it raises, because
silently preferring the package guide would hide a broken override for as long
as nobody looked.
"""

from __future__ import annotations

import hashlib
import re
import unicodedata
from dataclasses import dataclass
from pathlib import Path
from typing import Any

PACKAGE_GUIDES = Path(__file__).parent / "guides"
PROJECT_GUIDES = Path(".weave") / "guides"
FALLBACK_ID = "_uncoached"
PRESENTATION_IDS = ("_clean", "_incomplete", "_uncoached")
PRESENTATION_VIOLATION = "_presentation"

SECTION_KEYS = {
    "why": "why",
    "corrective move": "corrective_move",
    "expected outcome": "expected_outcome",
    "avoid": "avoid",
}
REQUIRED_SECTIONS = ("why", "corrective_move")
REQUIRED_FRONTMATTER = ("id", "violation_type", "summary")
ALLOWED_FRONTMATTER = ("id", "violation_type", "language", "summary")
ID_PATTERN = re.compile(r"^_?[a-z0-9]+(-[a-z0-9]+)*$")
_HEADING = re.compile(r"##\s+(.+?)\s*$")

# Ranges that cover the pictographs and dingbats house style keeps out of docs.
_EMOJI = re.compile("[←-⯿☀-➿\U0001f000-\U0001faff]")


class GuideError(Exception):
    """A guide could not be read or does not satisfy the contract.

    Carries the typed cause the coaching response reports, so a caller can
    render `guide_override_invalid` without re-deriving why.
    """

    def __init__(self, message: str, code: str, path: Path | None = None) -> None:
        super().__init__(message)
        self.code = code
        self.path = path


@dataclass(frozen=True)
class Guide:
    """One parsed guide asset. Frozen: it crosses the purity boundary as a value."""

    id: str
    violation_type: str
    language: str | None
    summary: str
    sections: dict[str, str]
    source: str
    definition_hash: str
    missing_guide_id: str | None = None
    missing_violation_type: str | None = None

    def content(self) -> dict[str, Any]:
        """The guide block a coaching response renders."""
        block = {
            "id": self.id,
            "language": self.language,
            "source": self.source,
            "names_missing_guide": self.id == FALLBACK_ID,
        }
        if self.missing_guide_id is not None:
            block["missing_guide_id"] = self.missing_guide_id
        if self.missing_violation_type is not None:
            block["missing_violation_type"] = self.missing_violation_type
        block.update(self.sections)
        return block

    def identity(self) -> dict[str, Any]:
        """The identity a canonical finding stores: never the prose body.

        `definition_hash` is promotion-time provenance only. It is not an
        identity, freshness, validation, or CLI/MCP parity input -- a project
        override makes it machine-local, so two hosts would otherwise disagree
        about the same defect. That classification is the whole reason this
        digest is safe while the rule definition hash is not; see
        docs/EVIDENCE-HASH-BINDING-CONTRACT.md.
        """
        identity = {
            "id": self.id,
            "language": self.language,
            "source": self.source,
            "definition_hash": self.definition_hash,
        }
        if self.missing_guide_id is not None:
            identity["missing_guide_id"] = self.missing_guide_id
        if self.missing_violation_type is not None:
            identity["missing_violation_type"] = self.missing_violation_type
        return identity

    def resolution(self, **overrides: Any) -> dict[str, Any]:
        """The `guide_resolution` value the promotion input carries.

        `root_cause` and `proposed_fix` are the two summary fields a canonical
        finding is required to hold. They are derived here, from the guide's own
        sections, so the pure planner never has to read a file to produce
        meaningful remediation.
        """
        resolved = {
            "guide": self.identity(),
            "root_cause": self.sections["why"],
            "proposed_fix": self.sections["corrective_move"],
        }
        resolved.update(overrides)
        return resolved


def _normalize(value: str) -> str:
    return " ".join(unicodedata.normalize("NFKC", value).split())


def parse_guide(path: Path, source: str) -> Guide:
    """Parse and validate one guide file. Raises :class:`GuideError`."""
    code = "guide_override_invalid" if source == "project" else "guide_invalid"
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise GuideError(f"{path}: cannot be read ({exc.strerror or exc})", code, path) from None

    if not text.startswith("---\n"):
        raise GuideError(f"{path.name}: missing frontmatter opening fence", code, path)
    _, _, rest = text.partition("---\n")
    block, fence, body = rest.partition("\n---\n")
    if not fence:
        raise GuideError(f"{path.name}: unterminated frontmatter", code, path)

    frontmatter: dict[str, str] = {}
    for lineno, line in enumerate(block.splitlines(), start=2):
        if not line.strip():
            continue
        if line[0] in " \t":
            raise GuideError(f"{path.name}:{lineno}: nested frontmatter is unsupported", code, path)
        key, sep, value = line.partition(":")
        if not sep:
            raise GuideError(f"{path.name}:{lineno}: expected 'key: value'", code, path)
        key = key.strip()
        if key not in ALLOWED_FRONTMATTER:
            raise GuideError(f"{path.name}:{lineno}: unknown frontmatter {key!r}", code, path)
        frontmatter[key] = value.strip()

    for required in REQUIRED_FRONTMATTER:
        if not frontmatter.get(required):
            raise GuideError(f"{path.name}: frontmatter {required} is required", code, path)

    stem = path.name[: -len(".md")] if path.name.endswith(".md") else path.name
    parts = stem.split(".")
    if len(parts) > 2:
        raise GuideError(f"{path.name}: at most one .<language> suffix is allowed", code, path)
    file_id = parts[0]
    file_language = parts[1] if len(parts) == 2 else None

    if frontmatter["id"] != file_id:
        raise GuideError(
            f"{path.name}: frontmatter id {frontmatter['id']!r} does not match filename "
            f"{file_id!r}",
            code,
            path,
        )
    if not ID_PATTERN.fullmatch(file_id):
        raise GuideError(f"{path.name}: id {file_id!r} is not a valid guide basename", code, path)

    declared_language = frontmatter.get("language") or None
    if declared_language != file_language:
        raise GuideError(
            f"{path.name}: frontmatter language {declared_language!r} does not match filename "
            f"{file_language!r}",
            code,
            path,
        )

    sections: dict[str, str] = {}
    current: str | None = None
    for line in body.splitlines():
        heading = _HEADING.fullmatch(line)
        if heading:
            name = heading.group(1).strip().lower()
            if name not in SECTION_KEYS:
                raise GuideError(f"{path.name}: unknown section {heading.group(1)!r}", code, path)
            current = SECTION_KEYS[name]
            sections[current] = ""
            continue
        if current is not None:
            sections[current] = (sections[current] + "\n" + line).strip()

    for required in REQUIRED_SECTIONS:
        if not sections.get(required):
            raise GuideError(f"{path.name}: section {required} is required", code, path)

    if _EMOJI.search(text):
        raise GuideError(f"{path.name}: guides use text markers, not emoji", code, path)

    return Guide(
        id=file_id,
        violation_type=frontmatter["violation_type"],
        language=file_language,
        summary=_normalize(frontmatter["summary"]),
        sections={key: _normalize(value) for key, value in sections.items()},
        source=source,
        definition_hash=hashlib.sha256(path.read_bytes()).hexdigest(),
    )


def candidate_paths(
    guide_id: str,
    language: str | None,
    project_root: Path | None = None,
    package_dir: Path | None = None,
) -> list[tuple[Path, str]]:
    """The resolution chain for one guide, in order, as (path, source) pairs."""
    package = package_dir or PACKAGE_GUIDES
    chain: list[tuple[Path, str]] = []
    if project_root is not None:
        project = project_root / PROJECT_GUIDES
        if language:
            chain.append((project / f"{guide_id}.{language}.md", "project"))
        chain.append((project / f"{guide_id}.md", "project"))
    if language:
        chain.append((package / f"{guide_id}.{language}.md", "package"))
    chain.append((package / f"{guide_id}.md", "package"))
    chain.append((package / f"{FALLBACK_ID}.md", "fallback"))
    return chain


def resolve(
    violation_type: str,
    catalog: dict[str, Any],
    language: str | None = None,
    project_root: Path | None = None,
    package_dir: Path | None = None,
) -> Guide:
    """Resolve the guide coaching `violation_type`, falling back when absent.

    A catalogued type with no guide of its own resolves to `_uncoached`, which
    still coaches and names the gap. An uncatalogued type is an error: the
    vocabulary is the contract, and inventing a guide for a type nobody reviewed
    would be a coaching surface with no review behind it.
    """
    types = catalog.get("types") if isinstance(catalog, dict) else None
    if not isinstance(types, dict):
        raise GuideError("catalog types must be an object", "catalog_unreadable")
    entry = types.get(violation_type)
    if entry is None:
        raise GuideError(
            f"violation type {violation_type!r} is not catalogued",
            "uncatalogued_violation_type",
        )
    if not isinstance(entry, dict) or not isinstance(entry.get("guide"), str):
        raise GuideError(
            f"catalog entry for {violation_type!r} has no guide basename",
            "catalog_unreadable",
        )
    guide_id = entry["guide"]

    for path, source in candidate_paths(guide_id, language, project_root, package_dir):
        if not path.is_file():
            continue
        guide = parse_guide(path, source)
        if source == "fallback":
            return Guide(
                id=guide.id,
                violation_type=guide.violation_type,
                language=guide.language,
                summary=guide.summary,
                sections=guide.sections,
                source=guide.source,
                definition_hash=guide.definition_hash,
                missing_guide_id=guide_id,
                missing_violation_type=violation_type,
            )
        if guide.violation_type != violation_type:
            raise GuideError(
                f"{path.name}: coaches {guide.violation_type!r}, not {violation_type!r}",
                "guide_override_invalid" if source == "project" else "guide_invalid",
                path,
            )
        return guide

    raise GuideError(
        f"no guide resolved for {violation_type!r} and no {FALLBACK_ID}.md fallback exists",
        "guide_missing",
    )


def resolve_all(
    violation_types: list[str],
    catalog: dict[str, Any],
    language: str | None = None,
    project_root: Path | None = None,
    package_dir: Path | None = None,
) -> dict[str, dict[str, Any]]:
    """The `resolved_guides` map a promotion input carries."""
    return {
        violation_type: resolve(
            violation_type, catalog, language, project_root, package_dir
        ).resolution()
        for violation_type in sorted(set(violation_types))
    }
