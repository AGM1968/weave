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
from dataclasses import dataclass, replace
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
ALLOWED_FRONTMATTER = ("id", "violation_type", "language", "summary", "sections")
ID_PATTERN = re.compile(r"^_?[a-z0-9]+(-[a-z0-9]+)*$")
_HEADING = re.compile(r"##\s+(.+?)\s*$")

# The declared-extension separator. Pipe rather than comma because the section
# names this exists to carry are prose -- one consumer's read "The appended negation,
# a second form under this type" -- and a comma would split them mid-name.
SECTION_DECLARATION_SEPARATOR = "|"
# A declared name is prose, not an identifier, but it still has to be a name: no
# markup, no newline, and short enough to render as a heading on any surface.
SECTION_NAME_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 ,.'()/-]{0,79}$")

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
    # Declared extensions, in body order, as (label, body) pairs. A tuple
    # because the dataclass is frozen and this crosses the purity boundary with
    # the rest of the value. Empty on every guide that does not declare any,
    # which is every package guide shipped today.
    extended: tuple[tuple[str, str], ...] = ()

    def content(self) -> dict[str, Any]:
        """The guide block a coaching response renders."""
        block: dict[str, Any] = {
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
        # Nested, never flattened alongside the fixed sections: a declared name
        # is authored downstream and would otherwise be free to collide with
        # `id`, `source`, or a section key and silently overwrite it.
        if self.extended:
            block["extended_sections"] = [
                {"label": label, "body": body} for label, body in self.extended
            ]
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


def _declared_sections(path: Path, raw: str | None, code: str) -> dict[str, str]:
    """The extra section names this one guide may carry, keyed by match name.

    The fixed vocabulary stays closed: a heading outside `SECTION_KEYS` is still
    an error unless the file itself declared it here. What this adds is a local
    tier, exactly as managed and local quality rules are tiered -- a name that
    fires in one repository is that repository's business, and a name that turns
    up across unrelated repositories is a construction that has earned a place
    in the fixed set. Promotion moves a name from here to `SECTION_KEYS`; it is
    not something a consumer can do to itself by writing a guide.
    """
    if raw is None:
        return {}
    if not raw.strip():
        raise GuideError(
            f"{path.name}: frontmatter 'sections' is present but declares nothing; omit it",
            code,
            path,
        )

    declared: dict[str, str] = {}
    for item in raw.split(SECTION_DECLARATION_SEPARATOR):
        label = _normalize(item)
        if not label:
            raise GuideError(
                f"{path.name}: frontmatter 'sections' has an empty entry", code, path
            )
        if not SECTION_NAME_PATTERN.fullmatch(label):
            raise GuideError(
                f"{path.name}: declared section {label!r} is not a section name", code, path
            )
        name = label.lower()
        if name in SECTION_KEYS:
            raise GuideError(
                f"{path.name}: declared section {label!r} is already a fixed section; a "
                f"declaration may extend the vocabulary, never redefine it",
                code,
                path,
            )
        if name in declared:
            raise GuideError(
                f"{path.name}: declared section {label!r} appears twice", code, path
            )
        declared[name] = label
    return declared


def _read_frontmatter(path: Path, code: str) -> tuple[str, dict[str, str], str]:
    """Read a guide's text and flat frontmatter, returning the unparsed section body."""
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise GuideError(f"{path}: cannot be read ({exc.strerror or exc})", code, path) from None
    except UnicodeDecodeError as exc:
        # A per-guide diagnostic, not a crash that loses every other result
        # (wv-7730bd): the file is invalid, the run that reads it is not.
        raise GuideError(f"{path.name}: not valid UTF-8 at byte {exc.start}", code, path) from None

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
    return text, frontmatter, body


def parse_guide(path: Path, source: str) -> Guide:
    """Parse and validate one guide file. Raises :class:`GuideError`."""
    code = "guide_override_invalid" if source == "project" else "guide_invalid"
    text, frontmatter, body = _read_frontmatter(path, code)

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

    declared = _declared_sections(path, frontmatter.get("sections"), code)

    sections: dict[str, str] = {}
    extended: dict[str, str] = {}
    labels: dict[str, str] = {}
    current: tuple[str, str] | None = None
    for line in body.splitlines():
        heading = _HEADING.fullmatch(line)
        if heading:
            raw = heading.group(1).strip()
            name = _normalize(raw).lower()
            # A second heading for a section already seen used to reset it,
            # silently discarding the first body (wv-76fc4a). Keyed on the
            # resolved section, so two spellings of one section also collide.
            if (name in SECTION_KEYS and SECTION_KEYS[name] in sections) or (
                name not in SECTION_KEYS and name in extended
            ):
                raise GuideError(
                    f"{path.name}: duplicate section {raw!r} — each section may appear once; "
                    f"merge the two bodies under one heading",
                    code,
                    path,
                )
            if name in SECTION_KEYS:
                current = ("fixed", SECTION_KEYS[name])
                sections[current[1]] = ""
            elif name in declared:
                # Declared. The label the reader sees is the author's own
                # spelling in the body, not the frontmatter's; the frontmatter
                # only decides which names are admissible.
                current = ("extended", name)
                extended[name] = ""
                labels[name] = _normalize(raw)
            else:
                raise GuideError(
                    f"{path.name}: unknown section {raw!r} — a section outside the fixed set must "
                    f"be declared in frontmatter 'sections'",
                    code,
                    path,
                )
            continue
        if current is None:
            continue
        kind, key = current
        target = sections if kind == "fixed" else extended
        target[key] = (target[key] + "\n" + line).strip()

    for required in REQUIRED_SECTIONS:
        if not sections.get(required):
            raise GuideError(f"{path.name}: section {required} is required", code, path)

    # A declaration the body never uses is drift in the direction the loud
    # failure above cannot see: the frontmatter widens what the file may contain
    # and nothing narrows it back when the content goes away.
    for name, label in declared.items():
        if name not in extended:
            raise GuideError(
                f"{path.name}: frontmatter declares section {label!r} but the body has "
                f"no such heading",
                code,
                path,
            )
        if not extended[name]:
            raise GuideError(f"{path.name}: declared section {label!r} is empty", code, path)

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
        extended=tuple((labels[name], _normalize(text)) for name, text in extended.items()),
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
        try:
            present = path.is_file()
        except OSError as exc:
            # An unreadable directory on the chain is not "no guide here": the
            # guide that would win may be behind it (wv-7730bd).
            raise GuideError(
                f"{path}: cannot be checked ({exc.strerror or exc})",
                "guide_override_invalid" if source == "project" else "guide_invalid",
                path,
            ) from None
        if not present:
            continue
        guide = parse_guide(path, source)
        if source == "fallback":
            # `replace` rather than a field-by-field rebuild: the rebuild had to
            # be revisited every time the value grew a field, and silently
            # dropped whatever it had not been taught about.
            return replace(
                guide,
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


# The vocabulary contract's entry statuses and guide basename rule
# (contracts/violation-vocabulary-v1.json guide_basename_rules.pattern; the
# leading underscore is reserved for the presentation guides). Fixed here, not
# read from the catalogue being checked, so a corrupted catalogue cannot
# loosen its own rules.
CATALOG_STATUSES = frozenset({"canonical", "compatibility", "legacy"})
CATALOG_GUIDE_PATTERN = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")


def validate_catalog(catalog: Any) -> list[str]:
    """The catalogue's canonical types, after checking the structure doctor relies on.

    A catalogue that is not an object with a non-empty `types` object, whose
    entries each carry a supported `status` and a `guide` basename the
    vocabulary contract allows, is rejected; so is one with no canonical type.
    Invalid input must never become an empty universe that reports complete
    (wv-7730bd), nor a smaller one: a misspelled status read as "not
    canonical" dropped that type from coverage, and its missing guide with it
    (wv-b303c9).
    """
    types = catalog.get("types") if isinstance(catalog, dict) else None
    if not isinstance(types, dict) or not types:
        raise GuideError("catalog has no types object", "catalog_unreadable")
    for key, entry in types.items():
        if not isinstance(entry, dict) or not isinstance(entry.get("status"), str) \
                or not isinstance(entry.get("guide"), str) or not entry["guide"]:
            raise GuideError(f"catalog entry {key!r} lacks a status or guide basename", "catalog_unreadable")
        if entry["status"] not in CATALOG_STATUSES:
            raise GuideError(f"catalog entry {key!r} has unsupported status {entry['status']!r} "
                             f"(expected one of {', '.join(sorted(CATALOG_STATUSES))})", "catalog_unreadable")
        if CATALOG_GUIDE_PATTERN.fullmatch(entry["guide"]) is None:
            raise GuideError(f"catalog entry {key!r} has guide basename {entry['guide']!r}, "
                             f"which does not match {CATALOG_GUIDE_PATTERN.pattern}", "catalog_unreadable")
    canonical = sorted(k for k, v in types.items() if v["status"] == "canonical")
    if not canonical:
        raise GuideError("catalog declares no canonical type", "catalog_unreadable")
    return canonical


def _project_assets(project_root: Path | None, invalid: list[dict[str, str]]) -> list[Guide]:
    """Every project guide under .weave/guides/ that parses; the rest go to INVALID."""
    if project_root is None:
        return []
    project_dir = project_root / PROJECT_GUIDES
    try:
        if not project_dir.is_dir():
            return []
        # iterdir, not glob: glob swallows a permission error and reports an
        # unlistable directory as one holding no guides.
        paths = sorted(p for p in project_dir.iterdir() if p.suffix == ".md")
    except OSError as exc:
        raise GuideError(f"{project_dir}: cannot be listed ({exc.strerror or exc})",
                         "guide_override_invalid", project_dir) from None
    parsed: list[Guide] = []
    for path in paths:
        try:
            parsed.append(parse_guide(path, "project"))
        except GuideError as exc:
            invalid.append({"file": path.name, "error": str(exc)})
    return parsed


# The worked guide init-repo seeds into every project
# (templates/authoring/manifest.conf). Its type is deliberately not in the
# vocabulary, so it resolves for nothing; doctor lists it apart from unused.
SEEDED_EXAMPLE_ID = "example-violation"


def doctor_report(
    catalog: dict[str, Any],
    project_root: Path | None = None,
    package_dir: Path | None = None,
) -> dict[str, Any]:
    """What `wv doctor` records about coaching guides (wv-7730bd).

    Computed with the shipped parser and resolver, never a second validator
    that could drift from them. Raises GuideError when the catalogue or the
    project guides directory cannot be read: that is a failed check, not a
    report.
      invalid        project guides parse_guide rejects, with the error
      unresolved     resolutions that raise: each project guide is resolved
                     in its own context (the catalogued type it serves, in
                     its own language), and each canonical type generically.
                     A parse-valid override coaching the wrong type fails
                     here, as it would in a coaching run.
      unused         project guides whose id is no catalogued guide basename:
                     no resolution ever selects them
      examples       the guide init-repo seeds to copy (SEEDED_EXAMPLE_ID),
                     while its type is still uncatalogued: unused by design
      fallback_only  canonical types that coach only through _uncoached
    """
    canonical = validate_catalog(catalog)
    types = catalog["types"]
    invalid: list[dict[str, str]] = []
    unresolved: list[dict[str, Any]] = []
    unused: list[str] = []
    examples: list[str] = []
    assets = _project_assets(project_root, invalid)
    for guide in assets:
        served = sorted(k for k, v in types.items() if v["guide"] == guide.id)
        if not served:
            name = f"{guide.id}.{guide.language}.md" if guide.language else f"{guide.id}.md"
            seeded = guide.id == SEEDED_EXAMPLE_ID and guide.violation_type not in types
            (examples if seeded else unused).append(name)
        for violation_type in served:
            try:
                resolve(violation_type, catalog, guide.language, project_root, package_dir)
            except GuideError as exc:
                unresolved.append({"violation_type": violation_type, "language": guide.language,
                                   "error": str(exc)})
    fallback_only: list[str] = []
    for violation_type in canonical:
        try:
            resolved = resolve(violation_type, catalog, None, project_root, package_dir)
        except GuideError as exc:
            entry = {"violation_type": violation_type, "language": None, "error": str(exc)}
            if entry not in unresolved:
                unresolved.append(entry)
            continue
        if resolved.missing_guide_id is not None:
            fallback_only.append(violation_type)
    return {
        "project_guides_checked": len(assets) + len(invalid),
        "invalid": invalid,
        "unresolved": unresolved,
        "unused": unused,
        "examples": examples,
        "canonical_types": len(canonical),
        "fallback_only": fallback_only,
    }


def default_catalog() -> Path:
    """The vocabulary, found as weave_quality finds it: beside the package when
    installed ($LIB_DIR/contracts), else at the source checkout's root."""
    installed = Path(__file__).resolve().parents[1] / "contracts" / "violation-vocabulary-v1.json"
    if installed.is_file():
        return installed
    return Path(__file__).resolve().parents[2] / "contracts" / "violation-vocabulary-v1.json"


def _main(argv: list[str]) -> int:
    """`python3 -m weave_quality.guides doctor [--catalog F] [--project-root D] [--package-dir D]`."""
    import argparse  # pylint: disable=import-outside-toplevel
    import json  # pylint: disable=import-outside-toplevel

    parser = argparse.ArgumentParser(prog="weave_quality.guides")
    sub = parser.add_subparsers(dest="command", required=True)
    doc = sub.add_parser("doctor", help="validate project guides and report coaching coverage as JSON")
    doc.add_argument("--catalog", type=Path, default=None)
    doc.add_argument("--project-root", type=Path)
    doc.add_argument("--package-dir", type=Path)
    args = parser.parse_args(argv)
    # A report is printed only when the check could run. Anything that stops
    # it (an unreadable or malformed catalogue, an unlistable guides directory)
    # prints {"error": ...} and exits 2, so the caller fails closed instead of
    # reading a partial or empty report as a pass.
    catalog_path = args.catalog or default_catalog()
    try:
        catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
        report = doctor_report(catalog, args.project_root, args.package_dir)
    except GuideError as exc:
        print(json.dumps({"error": str(exc), "code": exc.code}, sort_keys=True))
        return 2
    except (OSError, UnicodeDecodeError, ValueError) as exc:
        print(json.dumps({"error": f"{catalog_path}: {exc}", "code": "catalog_unreadable"}, sort_keys=True))
        return 2
    # Which copy produced the report, so the caller can refuse a report from a
    # module other than the one it selected (wrong copy of the tool).
    report["module"] = str(Path(__file__).resolve())
    report["package_dir"] = str((args.package_dir or PACKAGE_GUIDES).resolve())
    report["catalog"] = str(catalog_path.resolve())
    print(json.dumps(report, sort_keys=True))
    return 0


if __name__ == "__main__":
    import sys

    raise SystemExit(_main(sys.argv[1:]))
