#!/usr/bin/env python3
"""Validate attempt-journal events against contracts/attempt-journal-v1.schema.json.

Executes the schema document with the same executor the capability registry uses,
including its keyword-coverage guard: a schema keyword the executor cannot apply
is a hard error rather than a silently unenforced rule. ajv checks the same events
in tests/test-attempt-journal.sh, so the claim "every event validates" is one a
real JSON Schema implementation also makes.

Usage: journal-validate.py <events.jsonl> [<events.jsonl> ...]
Prints one line per failure and exits nonzero if there were any.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

from weave_registry import (  # noqa: E402  # pylint: disable=wrong-import-position
    SCHEMA_KEYWORDS,
    apply_schema,
    schema_keywords,
)

SCHEMA_PATH = ROOT / "contracts" / "attempt-journal-v1.schema.json"


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
    unexecuted = sorted(schema_keywords(schema) - SCHEMA_KEYWORDS)
    if unexecuted:
        print(f"schema uses keywords this validator does not execute: {unexecuted}", file=sys.stderr)
        return 1

    failures = 0
    for path in argv[1:]:
        for number, raw in enumerate(Path(path).read_text(encoding="utf-8").splitlines(), 1):
            if not raw.strip():
                continue
            try:
                event = json.loads(raw)
            except json.JSONDecodeError as exc:
                print(f"{path}:{number}: not valid JSON: {exc}", file=sys.stderr)
                failures += 1
                continue
            errors: list[str] = []
            apply_schema(event, schema, schema, "", errors)
            for error in errors:
                print(f"{path}:{number}: {error}", file=sys.stderr)
            failures += bool(errors)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
