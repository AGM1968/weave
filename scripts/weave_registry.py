#!/usr/bin/env python3
"""Validate the command capability registry and generate its shell projection.

The registry at contracts/command-capabilities.json is the single authority for
what each wv operation touches, whether the run cache may serve or must
invalidate, and how the counterweight classifies it. Consumers project from it:
Bash sources a generated case-statement artifact, evidence code reads the JSON,
and Rust deserializes the same JSON. Nothing parses shell source, and nothing
keeps a second hand-maintained copy -- the four copies that existed before drifted
apart unnoticed for a month (commit-refs, 871a348a).

Subcommands:
  validate   executes contracts/command-capabilities-v1.schema.json against the
             registry, then the invariants JSON Schema cannot state
  digest     SHA-256 over the registry's canonical bytes
  identity   the contract identity journal events and campaign manifests bind:
             the schema id, the schema digest, the registry digest and the
             composite over all three
  generate   write the shell projection
  check      regenerate into memory and byte-compare against the checked-in
             artifact, so an edited generated file fails rather than diverging

There is exactly one shape authority and it is executed, not restated. Field
presence, types, enums, patterns, uniqueness within a list and rejection of
unknown fields all come from running the schema document itself; this file holds
no parallel copy of them. A schema keyword the executor does not implement is a
hard error rather than a silent no-op, because an unexecuted keyword is an
unenforced one -- and tests/test-command-capabilities.sh cross-checks the
executor against ajv on the same accept/reject corpus, so "the schema is
enforced" is a claim about a real JSON Schema implementation.

TRUST BOUNDARY. The schema is input to this tool, not output of it: a trusted,
versioned build artifact that the executor applies and never inspects. It cannot
tell you that the schema is well-formed, and it does not try. An unsound schema
fails unevenly by construction -- an invalid regex on `handler.pattern` is never
compiled while the same regex on `operation.pattern` raises on the first row --
so treating "validate passed" as evidence about the schema would be reading a
verdict the tool never issued. Two things hold the other side of that boundary:
ajv compiles the schema in strict mode as a named check in the contract suite,
which is what certifies it; and the identity below covers the schema's bytes, so
a schema that changes meaning cannot keep the identity its consumers bound. A
semantic change belongs in a new -v2 file rather than an edit under v1, and the
identity is what makes an edit under v1 visible instead of silent. Adding
hand-written meta-schema checks here would rebuild the second authority this
registry exists to remove, one level up again.

Four invariants live here because JSON Schema cannot express them.

TOTALITY: every command in the wv dispatch table has a row with no suboperation.
An unclassified command is a latent cache bug and an evidence hole at once.

DOMINANCE: a command-level row is at least as strong as every suboperation row
beneath it. This is what makes "conservative where flags alter effects"
checkable: an unrecognized or newly added suboperation falls back to the
command-level row, which can never describe less than the specific behaviour it
stands in for.

EXCLUSIVITY: no row both serves from and invalidates the run cache.

CANONICITY: the file is in canonical form and sorted by (operation,
suboperation), with each key declared once, so its digest is reproducible.
"""

from __future__ import annotations

import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_REGISTRY = ROOT / "contracts" / "command-capabilities.json"
DEFAULT_SCHEMA = ROOT / "contracts" / "command-capabilities-v1.schema.json"

# observation < administrative < mutation_attempt. Membership is checked against
# the schema's evidence_class enum at validation time, so this ranking cannot
# outlive the vocabulary it ranks.
CLASS_RANK = {"observation": 0, "administrative": 1, "mutation_attempt": 2}

# JSON Schema keywords the executor below implements. Anything else appearing in
# the schema document fails validation outright: a keyword that is read but not
# applied would leave part of the contract unenforced while still looking
# declared, which is the failure mode this whole registry exists to remove.
SCHEMA_ANNOTATIONS = {"$comment", "$id", "$schema"}
SCHEMA_KEYWORDS = SCHEMA_ANNOTATIONS | {
    "$defs",
    "$ref",
    "additionalProperties",
    "const",
    "enum",
    "items",
    "minItems",
    "minLength",
    "minimum",
    "oneOf",
    "pattern",
    "properties",
    "required",
    "type",
    "uniqueItems",
}
JSON_TYPES = {
    "array": list,
    "boolean": bool,
    "integer": int,
    "null": type(None),
    "object": dict,
    "string": str,
}

GENERATED_HEADER = "# GENERATED FROM contracts/command-capabilities.json -- DO NOT EDIT"


def canonical(doc: dict) -> str:
    return json.dumps(doc, sort_keys=True, indent=2, ensure_ascii=False) + "\n"


def digest(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def key(rowdict: dict) -> tuple[str, str]:
    return (rowdict["operation"], rowdict.get("suboperation", ""))


def dispatch_commands(wv_path: Path) -> set[str]:
    """The dispatch-table command set, read the way pattern-audit reads it."""
    found = set()
    for line in wv_path.read_text(encoding="utf-8").splitlines():
        match = re.match(r"^\s+([a-z][a-zA-Z_-]+)\)", line)
        if match:
            found.add(match.group(1))
    return found


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def schema_keywords(schema: dict, seen: set[str] | None = None) -> set[str]:
    """Every keyword used anywhere in the schema document."""
    seen = set() if seen is None else seen
    seen.update(schema)
    for group in ("properties", "$defs"):
        for sub in schema.get(group, {}).values():
            if isinstance(sub, dict):
                schema_keywords(sub, seen)
    for single in ("additionalProperties", "items"):
        sub = schema.get(single)
        if isinstance(sub, dict):
            schema_keywords(sub, seen)
    for branch in schema.get("oneOf", []):
        if isinstance(branch, dict):
            schema_keywords(branch, seen)
    return seen


def resolve(node: dict, root: dict) -> dict:
    """Follow local $refs. Only '#/'-anchored pointers exist in this contract."""
    followed: set[str] = set()
    while "$ref" in node:
        ref = node["$ref"]
        if ref in followed or not ref.startswith("#/"):
            raise ValueError(f"unsupported or circular $ref {ref!r}")
        followed.add(ref)
        target: Any = root
        for part in ref[2:].split("/"):
            target = target[part]
        node = target
    return node


def _apply_type(value: Any, node: dict, where: str, errors: list[str]) -> bool:
    """The type gate. Returns False when the value is the wrong type, in which
    case no other keyword is meaningful and the caller stops."""
    if "type" not in node:
        return True
    # JSON Schema allows a list of names, and a nullable field is how the
    # attempt journal states "this call had no parent" as a value rather than an
    # absence. Executing only the scalar form would have meant spelling that as
    # anyOf purely to suit this executor.
    names = node["type"] if isinstance(node["type"], list) else [node["type"]]
    wanted = tuple(JSON_TYPES[name] for name in names)
    # JSON has no bool-as-integer: True is not 1 in a contract, whatever
    # Python's type hierarchy says.
    if not isinstance(value, wanted) or (isinstance(value, bool) and "boolean" not in names):
        errors.append(f"{where}: expected {node['type']}")
        return False
    return True


def _apply_scalar(value: Any, node: dict, where: str, errors: list[str]) -> None:
    """Keywords that constrain a single value."""
    if "const" in node and value != node["const"]:
        errors.append(f"{where}: must be {node['const']!r}, got {value!r}")
    if "enum" in node and value not in node["enum"]:
        errors.append(f"{where}: {value!r} is not one of {sorted(node['enum'])}")
    if "pattern" in node and isinstance(value, str):
        if not re.search(node["pattern"], value):
            errors.append(f"{where}: {value!r} does not match {node['pattern']}")
    if "minLength" in node and isinstance(value, str) and len(value) < node["minLength"]:
        errors.append(f"{where}: shorter than {node['minLength']} characters")
    if "minimum" in node and isinstance(value, int) and not isinstance(value, bool):
        if value < node["minimum"]:
            errors.append(f"{where}: below minimum {node['minimum']}")


def _apply_one_of(
    value: Any, node: dict, root: dict, path: str, where: str, errors: list[str]
) -> None:
    """Exactly one branch must accept, which is what makes the event-type union
    a discriminator rather than a list of suggestions."""
    if "oneOf" not in node:
        return
    matched = []
    for index, branch in enumerate(node["oneOf"]):
        branch_errors: list[str] = []
        apply_schema(value, branch, root, path, branch_errors)
        if not branch_errors:
            matched.append(index)
    if len(matched) != 1:
        errors.append(
            f"{where}: matches {len(matched)} of {len(node['oneOf'])} alternatives, expected exactly one"
        )


def _apply_object(
    value: dict, node: dict, root: dict, path: str, where: str, errors: list[str]
) -> None:
    """required, additionalProperties and per-property descent."""
    properties = node.get("properties", {})
    for name in node.get("required", []):
        if name not in value:
            errors.append(f"{where}: missing required field {name!r}")
    if node.get("additionalProperties") is False:
        for name in sorted(set(value) - set(properties)):
            errors.append(f"{where}: unknown field {name!r}")
    for name, sub in properties.items():
        if name in value:
            apply_schema(value[name], sub, root, f"{path}.{name}".lstrip("."), errors)


def _apply_array(
    value: list, node: dict, root: dict, path: str, where: str, errors: list[str]
) -> None:
    """minItems, uniqueItems and per-item descent."""
    if len(value) < node.get("minItems", 0):
        errors.append(f"{where}: needs at least {node['minItems']} item(s)")
    if node.get("uniqueItems"):
        frozen = [json.dumps(item, sort_keys=True) for item in value]
        duplicated = sorted({item for item in frozen if frozen.count(item) > 1})
        if duplicated:
            errors.append(f"{where}: duplicate items {duplicated}")
    item_schema = node.get("items")
    if isinstance(item_schema, dict):
        for index, item in enumerate(value):
            apply_schema(item, item_schema, root, f"{path}[{index}]", errors)


def apply_schema(value: Any, node: dict, root: dict, path: str, errors: list[str]) -> None:
    """Execute the schema document against a value, collecting every failure.

    Split by keyword group rather than kept as one chain: the groups are
    independent, and a single function over every keyword is where an
    unexecuted keyword hides.
    """
    node = resolve(node, root)
    where = path or "<document>"

    if not _apply_type(value, node, where, errors):
        return
    _apply_scalar(value, node, where, errors)
    _apply_one_of(value, node, root, path, where, errors)
    if isinstance(value, dict):
        _apply_object(value, node, root, path, where, errors)
    if isinstance(value, list):
        _apply_array(value, node, root, path, where, errors)


def _dominance_errors(seen: dict[tuple[str, str], dict]) -> list[str]:
    """DOMINANCE: the fallback row is never weaker than what it stands in for.

    This is what makes "conservative where flags alter effects" checkable rather
    than prose: an unrecognized or newly added suboperation falls back to the
    command-level row, which must never describe less than the specific
    behaviour it stands in for.
    """
    errors: list[str] = []
    for (op, sub), row in seen.items():
        if not sub:
            continue
        parent = seen.get((op, ""))
        if parent is None:
            errors.append(f"{op}:{sub} has no command-level row to fall back to")
            continue
        if not set(row["mutation_targets"]) <= set(parent["mutation_targets"]):
            errors.append(
                f"{op}:{sub} touches {sorted(set(row['mutation_targets']) - set(parent['mutation_targets']))} "
                f"which the {op} fallback does not declare"
            )
        if CLASS_RANK[row["evidence_class"]] > CLASS_RANK[parent["evidence_class"]]:
            errors.append(
                f"{op}:{sub} is {row['evidence_class']} but the {op} fallback is only "
                f"{parent['evidence_class']}"
            )
        if row["cache"]["invalidate"] and not parent["cache"]["invalidate"]:
            errors.append(f"{op}:{sub} invalidates but the {op} fallback does not")
        if parent["cache"]["serve"] and not row["cache"]["serve"]:
            errors.append(f"{op}:{sub} is not servable but the {op} fallback is")
    return errors


def validate(registry: Path, wv_path: Path, schema_path: Path = DEFAULT_SCHEMA) -> list[str]:
    try:
        raw = registry.read_text(encoding="utf-8")
        doc = json.loads(raw)
    except OSError as exc:
        return [f"registry unreadable at {registry}: {exc}"]
    except json.JSONDecodeError as exc:
        return [f"registry is not valid JSON: {exc}"]
    try:
        schema = json.loads(schema_path.read_text(encoding="utf-8"))
    except OSError as exc:
        return [f"schema unreadable at {schema_path}: {exc}"]
    except json.JSONDecodeError as exc:
        return [f"schema at {schema_path} is not valid JSON: {exc}"]

    unexecuted = sorted(schema_keywords(schema) - SCHEMA_KEYWORDS)
    if unexecuted:
        return [
            f"schema uses keywords this validator does not execute: {unexecuted} -- "
            "an unexecuted keyword is an unenforced one; implement it or drop it"
        ]

    # SHAPE. The schema document, executed. Nothing below restates it, and the
    # invariants below assume a well-shaped document, so shape failures stop here.
    errors: list[str] = []
    try:
        apply_schema(doc, schema, schema, "", errors)
    except (KeyError, TypeError, ValueError, re.error) as exc:
        # Not a verdict on the schema -- see TRUST BOUNDARY. The executor got as
        # far as a construct it could not apply, and says so instead of dying.
        return [
            f"the schema at {schema_path} could not be applied: {exc}; the executor "
            "assumes a well-formed schema and does not verify one, so compile it with "
            "ajv (tests/test-command-capabilities.sh) to find the fault"
        ]
    if errors:
        return errors

    ranked, declared = set(CLASS_RANK), set(schema["$defs"]["evidence_class"]["enum"])
    if ranked != declared:
        return [
            f"evidence_class ranking {sorted(ranked)} does not cover the schema "
            f"vocabulary {sorted(declared)}"
        ]

    rows = doc["commands"]
    seen: dict[tuple[str, str], dict] = {}
    for row in rows:
        # EXCLUSIVITY: serving a cached result and dropping the cache are
        # opposite dispositions, and a row claiming both classifies nothing.
        if row["cache"]["serve"] and row["cache"]["invalidate"]:
            errors.append(f"{key(row)}: cache cannot both serve and invalidate")
        if key(row) in seen:
            errors.append(f"{key(row)}: duplicate row")
        seen[key(row)] = row

    # TOTALITY: every dispatched command has a command-level row.
    base = {op for op, sub in seen if not sub}
    dispatched = dispatch_commands(wv_path)
    for missing in sorted(dispatched - base):
        errors.append(f"dispatch command {missing!r} has no command-level row")
    for extra_op in sorted(base - dispatched):
        errors.append(f"registry declares {extra_op!r}, which is not dispatched")

    errors.extend(_dominance_errors(seen))

    # CANONICITY: reproducible bytes, hence a reproducible digest.
    if raw != canonical(doc):
        errors.append("registry is not in canonical form (sorted keys, 2-space indent)")
    ordered = sorted(rows, key=lambda r: (r["operation"], r.get("suboperation", "")))
    if rows != ordered:
        errors.append("commands must be sorted by (operation, suboperation)")

    return errors


def contract_identity(
    registry: Path = DEFAULT_REGISTRY, schema_path: Path = DEFAULT_SCHEMA
) -> dict[str, str]:
    """The identity of the capability contract: the registry AND its schema.

    Binding the registry digest alone would let v1 change meaning invisibly --
    loosen a pattern, drop uniqueItems, widen an enum, and every digest captured
    before the edit still matches while the rows it admits are different.
    Consumers bind identity_sha256, which any implementation can reproduce from
    the two files:

        sha256(f"{schema id}\n{schema sha256}\n{registry sha256}\n")

    over the schema file's exact bytes and the registry's canonical bytes.
    """
    doc = load(registry)
    schema_sha = hashlib.sha256(schema_path.read_bytes()).hexdigest()
    registry_sha = digest(canonical(doc))
    schema_id = str(doc["schema"])
    return {
        "schema": schema_id,
        "schema_sha256": schema_sha,
        "registry_sha256": registry_sha,
        "identity_sha256": digest(f"{schema_id}\n{schema_sha}\n{registry_sha}\n"),
    }


def _branches(selected: list[str]) -> str:
    return "|".join(selected) if selected else ""


def _shell_cache_predicates(subs: list[dict], base: list[dict]) -> list[str]:
    """_wv_cap_serve and _wv_cap_invalidate: the run cache's two dispositions."""
    out: list[str] = []
    for name, field in (("_wv_cap_serve", "serve"), ("_wv_cap_invalidate", "invalidate")):
        sub_yes = [f'{r["operation"]}:{r["suboperation"]}' for r in subs if r["cache"][field]]
        sub_no = [f'{r["operation"]}:{r["suboperation"]}' for r in subs if not r["cache"][field]]
        base_yes = [r["operation"] for r in base if r["cache"][field]]
        out += [f"{name}() {{", '    case "${1}:${2-}" in']
        if sub_yes:
            out.append(f"        {_branches(sub_yes)}) return 0 ;;")
        if sub_no:
            out.append(f"        {_branches(sub_no)}) return 1 ;;")
        out += ["    esac", '    case "$1" in']
        if base_yes:
            out.append(f"        {_branches(base_yes)}) return 0 ;;")
        out += ["    esac", "    return 1", "}", ""]
    return out


def _shell_evidence_class(subs: list[dict], base: list[dict]) -> list[str]:
    """_wv_cap_evidence_class: how the counterweight classifies each row."""
    out = ["_wv_cap_evidence_class() {", '    case "${1}:${2-}" in']
    for cls in sorted(CLASS_RANK):
        selected = [f'{r["operation"]}:{r["suboperation"]}' for r in subs if r["evidence_class"] == cls]
        if selected:
            out.append(f'        {_branches(selected)}) printf %s {cls}; return 0 ;;')
    out += ["    esac", '    case "$1" in']
    for cls in sorted(CLASS_RANK):
        selected = [r["operation"] for r in base if r["evidence_class"] == cls]
        if selected:
            out.append(f'        {_branches(selected)}) printf %s {cls}; return 0 ;;')
    return out + ["    esac", "    return 1", "}", ""]


def _shell_targets(subs: list[dict], base: list[dict]) -> list[str]:
    """_wv_cap_targets: what a mutation may touch, which is what an attempt
    journal records. Class and cache alone cannot answer that."""
    out = ["_wv_cap_targets() {", '    case "${1}:${2-}" in']
    for row in subs:
        targets = " ".join(row["mutation_targets"])
        out.append(f'        {row["operation"]}:{row["suboperation"]}) printf %s "{targets}"; return 0 ;;')
    out += ["    esac", '    case "$1" in']
    for row in base:
        targets = " ".join(row["mutation_targets"])
        out.append(f'        {row["operation"]}) printf %s "{targets}"; return 0 ;;')
    return out + ["    esac", "    return 1", "}", ""]


def _shell_refines_and_known(subs: list[dict], base: list[dict]) -> list[str]:
    """_wv_cap_refines: whether a row of its own exists for this (operation,
    suboperation). The journal records what dispatch resolved, and "the second
    word" is not that -- most second words are operands, not refinements.
    _wv_cap_known: whether the first word is a dispatched command at all."""
    refined = [f'{r["operation"]}:{r["suboperation"]}' for r in subs]
    out = ["_wv_cap_refines() {", '    case "${1}:${2-}" in']
    if refined:
        out.append(f"        {_branches(refined)}) return 0 ;;")
    out += ["    esac", "    return 1", "}", ""]
    return out + [
        "_wv_cap_known() {",
        '    case "$1" in',
        f'        {_branches([r["operation"] for r in base])}) return 0 ;;',
        "    esac",
        "    return 1",
        "}",
        "",
    ]


def shell(registry: Path, schema_path: Path = DEFAULT_SCHEMA) -> str:
    doc = load(registry)
    identity = contract_identity(registry, schema_path)
    rows = doc["commands"]
    subs = [r for r in rows if r.get("suboperation")]
    base = [r for r in rows if not r.get("suboperation")]

    out = [
        "#!/bin/bash",
        GENERATED_HEADER,
        "#",
        "# Regenerate: python3 scripts/weave_registry.py generate",
        "# Verify:     python3 scripts/weave_registry.py check",
        "#",
        "# A listed suboperation branch is answered there and never reaches the",
        "# command-level branch below it, so an unlisted suboperation falls back to",
        "# the command-level row -- which validation guarantees is never weaker.",
        "",
        f'WV_CAPABILITIES_SCHEMA="{identity["schema"]}"',
        f'WV_CAPABILITIES_SHA256="{identity["registry_sha256"]}"',
        f'WV_CAPABILITIES_SCHEMA_SHA256="{identity["schema_sha256"]}"',
        f'WV_CAPABILITIES_IDENTITY="{identity["identity_sha256"]}"',
        "",
    ]

    out += _shell_cache_predicates(subs, base)
    out += _shell_evidence_class(subs, base)
    out += _shell_targets(subs, base)
    out += _shell_refines_and_known(subs, base)
    return "\n".join(out)


def main(argv: list[str]) -> int:
    root = ROOT
    registry = DEFAULT_REGISTRY
    wv_path = root / "scripts" / "wv"
    schema_path = DEFAULT_SCHEMA
    artifact = root / "scripts" / "lib" / "wv-command-capabilities.sh"
    action = argv[1] if len(argv) > 1 else "validate"
    # Explicit paths let the suite validate a deliberately broken copy -- of the
    # registry or of the schema -- without touching the checked-in contract.
    if len(argv) > 2:
        registry = Path(argv[2])
    if len(argv) > 3:
        wv_path = Path(argv[3])
    if len(argv) > 4:
        schema_path = Path(argv[4])

    if action == "validate":
        errors = validate(registry, wv_path, schema_path)
        for line in errors:
            print(f"x {line}", file=sys.stderr)
        return 1 if errors else 0
    if action == "digest":
        print(digest(canonical(load(registry))))
        return 0
    if action == "identity":
        print(json.dumps(contract_identity(registry, schema_path), indent=2, sort_keys=True))
        return 0
    if action == "generate":
        artifact.write_text(shell(registry, schema_path), encoding="utf-8")
        print(f"wrote {artifact.relative_to(root)}")
        return 0
    if action == "check":
        want = shell(registry, schema_path)
        if not artifact.is_file():
            print(f"x {artifact.relative_to(root)} is missing", file=sys.stderr)
            return 1
        if artifact.read_text(encoding="utf-8") != want:
            print(
                f"x {artifact.relative_to(root)} differs from the registry -- "
                "regenerate with: python3 scripts/weave_registry.py generate",
                file=sys.stderr,
            )
            return 1
        return 0

    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
