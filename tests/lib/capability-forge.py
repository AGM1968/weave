#!/usr/bin/env python3
"""Forge malformed capability registries, one per shape rule the schema states.

Each forgery breaks exactly one JSON Schema keyword in
contracts/command-capabilities-v1.schema.json. The suite feeds the same corpus
to two independent validators -- the executor in scripts/weave_registry.py and
ajv -- and requires them to agree, so "the schema is enforced" is a claim about a
real JSON Schema implementation rather than about a hand-written lookalike.

Usage: capability-forge.py <registry.json> <outdir>
Prints one case name per line, which is also <outdir>/<name>.json.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any
from collections.abc import Callable


def row(doc: dict[str, Any], operation: str, sub: str | None = None) -> dict[str, Any]:
    commands: list[dict[str, Any]] = doc["commands"]
    for candidate in commands:
        if candidate["operation"] == operation and candidate.get("suboperation") == sub:
            return candidate
    raise SystemExit(f"forge: no row for {operation}:{sub}")


# name -> (keyword broken, mutation)
FORGERIES: dict[str, Callable[[dict[str, Any]], object]] = {
    # uniqueItems on mutation_targets
    "dup-targets": lambda d: row(d, "add").__setitem__(
        "mutation_targets", row(d, "add")["mutation_targets"] + [row(d, "add")["mutation_targets"][0]]
    ),
    # pattern on handler
    "bad-handler": lambda d: row(d, "add").__setitem__("handler", "BAD-HANDLER"),
    # required on the command row
    "missing-operation": lambda d: row(d, "add").pop("operation"),
    # additionalProperties: false on the command row
    "unknown-field": lambda d: row(d, "add").__setitem__("note", "not a declared field"),
    # additionalProperties: false on the nested cache object
    "unknown-cache-field": lambda d: row(d, "add")["cache"].__setitem__("maybe", True),
    # enum on evidence_class
    "bad-class": lambda d: row(d, "add").__setitem__("evidence_class", "vandalism"),
    # enum on mutation_target
    "bad-target": lambda d: row(d, "add").__setitem__("mutation_targets", ["the_moon"]),
    # type on operation
    "operation-not-a-string": lambda d: row(d, "add").__setitem__("operation", 42),
    # required on the cache object
    "cache-missing-serve": lambda d: row(d, "add")["cache"].pop("serve"),
    # const on the document schema id
    "wrong-schema-id": lambda d: d.__setitem__("schema", "weave.command-capabilities.v2"),
    # minItems on commands
    "no-commands": lambda d: d.__setitem__("commands", []),
    # additionalProperties: false on the document
    "unknown-document-field": lambda d: d.__setitem__("version", 1),
}


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    source, outdir = Path(argv[1]), Path(argv[2])
    outdir.mkdir(parents=True, exist_ok=True)
    for name, mutate in FORGERIES.items():
        doc = json.loads(source.read_text(encoding="utf-8"))
        mutate(doc)
        target = outdir / f"{name}.json"
        target.write_text(
            json.dumps(doc, sort_keys=True, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
        print(name)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
