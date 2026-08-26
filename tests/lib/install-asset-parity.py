#!/usr/bin/env python3
"""Compare install.sh's hardcoded fallback lists against what the repo holds.

The network installer enumerates each package through the GitHub contents API
and falls back to a literal list when that call fails or is rate-limited. A
module missing from the fallback does not fail the install -- it installs a
package that imports and then dies at runtime, on the machine least able to
diagnose it. Both quality lists had already drifted before this check existed.

Reports one PROBLEM line per drifted list, then a COUNT line.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# (label, assignment variable in install.sh, source directory, suffix)
LISTS = [
    ("weave_quality modules", "quality_modules", "scripts/weave_quality", ".py"),
    ("weave_coaching modules", "coaching_modules", "scripts/weave_coaching", ".py"),
    ("coaching guides", "coaching_guides", "scripts/weave_quality/guides", ".md"),
]


def declared(installer: str, variable: str) -> set[str] | None:
    """The literal fallback list assigned to `variable`, if there is one."""
    match = re.search(rf'^\s*{variable}="([^"]*)"\s*$', installer, re.MULTILINE)
    return set(match.group(1).split()) if match else None


def check() -> list[str]:
    installer = (ROOT / "install.sh").read_text(encoding="utf-8")
    problems: list[str] = []

    for label, variable, directory, suffix in LISTS:
        fallback = declared(installer, variable)
        if fallback is None:
            problems.append(f"{label}: no literal fallback list found for ${variable}")
            continue
        on_disk = {p.name for p in (ROOT / directory).glob(f"*{suffix}")}
        missing = sorted(on_disk - fallback)
        extra = sorted(fallback - on_disk)
        if missing:
            problems.append(
                f"{label}: fallback omits {', '.join(missing)} — an API-unavailable "
                f"install would ship an incomplete {directory}"
            )
        if extra:
            problems.append(
                f"{label}: fallback names {', '.join(extra)}, which {directory} no longer has"
            )

    # scripts/lib is installed by an explicit per-file list, not a glob, so a
    # new lib module is shipped only if someone remembered all three sites. A
    # sourced fragment that never installs leaves the consumer running a
    # different definition than the repository has -- which is how the new
    # vocabulary projection reached a commit gate uninstalled.
    lib_dir = ROOT / "scripts" / "lib"
    for module in sorted(lib_dir.glob("*.sh")):
        if f"scripts/lib/{module.name}" not in installer:
            problems.append(
                f"scripts/lib/{module.name} is never installed by install.sh — "
                "add it to the local, config, and network install sites"
            )

    # Every path install.sh names must exist AND be tracked by git. A file the
    # installer references but git does not carry ships as nothing: the release
    # tarball and a fresh clone both lack it, while the developer's own tree has
    # it and looks fine. This repository has produced that shape three times --
    # an evidence bundle's *.jsonl, and profiling/, both excluded by a broad
    # ignore rule and surviving only because someone once used `git add -f`.
    referenced = set(re.findall(r'\./((?:profiling|scripts|contracts)/[\w./-]+\.(?:py|sh|json|md))', installer))
    referenced |= set(re.findall(r'\$REPO/((?:profiling|scripts|contracts)/[\w./-]+\.(?:py|sh|json|md))', installer))
    tracked = set(
        subprocess.run(["git", "ls-files"], cwd=ROOT, capture_output=True, text=True, check=False)
        .stdout.split()
    )
    for ref in sorted(referenced):
        if not (ROOT / ref).is_file():
            problems.append(f"install.sh references {ref}, which does not exist")
        elif ref not in tracked:
            problems.append(
                f"install.sh references {ref}, which git does not track — it would ship as "
                "nothing from a clean clone (check .gitignore; add it with git add -f)"
            )

    # Every contract the runtime reads must be installed by BOTH branches.
    required = {
        "violation-vocabulary-v1.json",
        "coaching-promotion-v1.schema.json",
        "coaching-response-v1.schema.json",
        "coaching-guide-v1.schema.json",
    }
    for contract in sorted(required):
        if not (ROOT / "contracts" / contract).is_file():
            problems.append(f"contracts/{contract} is referenced by install.sh but absent")
        if contract not in installer:
            problems.append(f"install.sh never installs contracts/{contract}")

    # The local branch installs by glob; the directories it globs must exist.
    for directory in ("scripts/weave_coaching", "scripts/weave_quality/guides"):
        if f'./{directory}/' not in installer:
            problems.append(f"install.sh local branch does not install {directory}")

    manifest = "scripts/weave_quality/default_patterns/manifest.json"
    if not (ROOT / manifest).is_file():
        problems.append(f"{manifest} is absent")
    if installer.count(manifest) != 2:
        problems.append(f"install.sh must install {manifest} on both local and remote paths")

    return problems


def main() -> int:
    for problem in check():
        print("PROBLEM " + problem)
    print(f"COUNT {len(LISTS)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
