#!/usr/bin/env python3
"""Validate a directory of coaching guide assets.

Parsing and per-file contract validation are delegated to the SHIPPED
validator, `weave_quality.guides.parse_guide`. That is deliberate: a second
parser living here would let this suite's negative controls pass against a copy
while the one that actually resolves guides at runtime drifted away from them.

What stays here is what the resolver has no reason to ask -- whole-directory
questions: catalog agreement, the reserved presentation guides, flat layout, and
guide files no catalogued type points at.

Reports one PROBLEM line per violation, then a COUNT line. A condition that
makes the scan itself untrustworthy (a missing directory) exits non-zero with no
COUNT, so the caller treats it as failure rather than as a clean result.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))

from weave_quality.guides import (  # noqa: E402  # pylint: disable=wrong-import-position
    PRESENTATION_IDS,
    PRESENTATION_VIOLATION,
    GuideError,
    parse_guide,
)


def check(guides_dir: Path, catalog_path: Path) -> list[str]:
    catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
    catalogued = catalog["types"]
    guide_ids = {entry["guide"] for entry in catalogued.values()}

    problems: list[str] = []
    entries = sorted(guides_dir.iterdir())
    if not entries:
        problems.append("guides directory is empty; the fallback guides must always ship")

    for path in entries:
        if path.is_dir():
            problems.append(f"{path.name}: guides must be flat, no subdirectories")
            continue
        if path.suffix != ".md":
            problems.append(f"{path.name}: only .md guide assets are supported")
            continue

        try:
            guide = parse_guide(path, "package")
        except GuideError as exc:
            problems.append(f"{exc}")
            continue

        if guide.id in PRESENTATION_IDS:
            if guide.violation_type != PRESENTATION_VIOLATION:
                problems.append(
                    f"{path.name}: a presentation guide must declare {PRESENTATION_VIOLATION}"
                )
            continue

        if guide.violation_type not in catalogued:
            problems.append(f"{path.name}: violation_type {guide.violation_type!r} is not catalogued")
        elif catalogued[guide.violation_type]["guide"] != guide.id:
            problems.append(
                f"{path.name}: catalog maps {guide.violation_type} to "
                f"{catalogued[guide.violation_type]['guide']!r}, not {guide.id!r}"
            )
        elif guide.id not in guide_ids:
            problems.append(f"{path.name}: no catalogued type resolves to this guide basename")

    for guide_id in sorted(PRESENTATION_IDS):
        if not (guides_dir / f"{guide_id}.md").is_file():
            problems.append(f"{guide_id}.md must ship with the package")

    return problems


def main() -> int:
    guides_dir = Path(sys.argv[1])
    catalog_path = Path(sys.argv[2])
    if not guides_dir.is_dir():
        raise SystemExit(f"not a guides directory: {guides_dir}")
    for problem in check(guides_dir, catalog_path):
        print("PROBLEM " + problem)
    print(f"COUNT {len(sorted(guides_dir.glob('*.md')))}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
