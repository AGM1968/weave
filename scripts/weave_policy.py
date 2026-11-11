#!/usr/bin/env python3
"""Validate and identify the policy-rules contract (contracts/policy-rules-v1.json).

The capability registry says what an operation touches; this contract says what
may refuse it. Each rule has an identity that no implementation detail supplies
(not a Bash function, a file path or an error string), so a non-Bash runtime can
enforce the same rule. Its sites say where today's code enforces it, and are
checked against that code rather than trusted.

Checks, beyond the schema:
  - rule-level decisions fold onto exactly the call-level verdict enum that
    contracts/policy-v1.schema.json owns, which is referenced rather than copied;
  - every (operation, suboperation) exists in the capability registry, and every
    state transition names a field and values the node field registry declares;
  - every site resolves: its file exists, its function exists, and its anchor
    occurs exactly the declared number of times;
  - completeness for the site classes code makes detectable: every SQLite abort,
    every host-hook denial and every refusing exit of a Weave git hook is
    claimed by a rule or a non-policy entry, and every emitted policy verdict
    names a declared rule. Command gates that emit nothing are not detectable
    and the contract says so (completeness.limit).

Usage:
  python3 scripts/weave_policy.py validate [--json]
  python3 scripts/weave_policy.py identity
  python3 scripts/weave_policy.py generate | check
  python3 scripts/weave_policy.py denominator <journal.jsonl>...
  python3 scripts/weave_policy.py totality [<journal.jsonl>...] [--hook-observations <jsonl>]... [--summary <path>]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from collections.abc import Iterator
from fnmatch import fnmatchcase
from pathlib import Path

sys.path.append(str(Path(__file__).resolve().parent))
from weave_registry import (  # noqa: E402  # pylint: disable=wrong-import-position
    Json, apply_schema, canonical, digest, key, load,
)

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CONTRACT = ROOT / "contracts" / "policy-rules-v1.json"
DEFAULT_SCHEMA = ROOT / "contracts" / "policy-rules-v1.schema.json"
DEFAULT_ARTIFACT = ROOT / "scripts" / "lib" / "wv-policy-rules.sh"
HOOK_OBSERVATION_SCHEMA = ROOT / "contracts" / "hook-observation-v1.schema.json"
GENERATED_HEADER = "# GENERATED FROM contracts/policy-rules-v1.json -- DO NOT EDIT"

# Site classes code makes detectable. A line is an enforcement site when it
# matches, outside a comment; each must be claimed by some declared site.
SQLITE_ABORT = re.compile(r"RAISE\(ABORT")
HOOK_DENY = re.compile(r'permissionDecision"?:\s*"deny"|"decision":\s*"block"')
HOOK_RETURN = re.compile(r"^\s*return 2\b")
EMIT = re.compile(r"wv_attempt_emit\s+policy_verdict")
EMIT_RULE = re.compile(r"\brule=([a-z][a-z0-9_]*)")
# The helpers every gate calls: wv_policy_verdict <rule> <decision> ...,
# wv_policy_refusal <category> ...; their own bodies are the emitter, not sites.
VERDICT = re.compile(r"\bwv_policy_verdict\s+([a-z][a-z0-9_]*)\s+([a-z]+)")
REFUSAL = re.compile(r"\bwv_policy_refusal\s+([a-z][a-z0-9_]*)")
EMITTER_FUNCTIONS = {"wv_attempt_emit", "wv_policy_verdict", "wv_policy_refusal"}
EMIT_ANCHORS = ("wv_policy_verdict ", "wv_policy_refusal ", "rule=")
# A close written as a bare UPDATE bypasses the close receipt, so the trigger
# would be the only judge and its refusal would carry no verdict (wv-957fc8).
# Every close goes through _done_close, whose SET list is a variable.
CLOSE_WRITE = re.compile(r"UPDATE\s+nodes\s+SET\b[^;]*\bstatus\s*=\s*'done'", re.IGNORECASE)
JOURNAL_WRITE = re.compile(r"wv_attempt_emit|wv_policy_verdict|wv_policy_refusal|WV_ATTEMPT_JOURNAL")
FUNCTION_DEF = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{")
HOOK_FILES = (".claude/hooks/*.sh", "scripts/lib/wv-hook-common.sh", "scripts/lib/wv-pre-tool-use.sh",
              "scripts/lib/wv-lifecycle-end.sh")
# What a hook records when it decides (scripts/lib/wv-hook-observe.sh,
# wv-664b7f): _hc_observe <rule> <decision> [bypass]. It never carries a call id.
HOOK_OBSERVE = re.compile(r"\b_hc_observe\s+([a-z][a-z0-9_]*)\s+([a-z]+)")
# Weave git hooks, the recovery module the pre-commit hook sources in the
# source repository (wv-669900; build-release.sh strips it and projects its
# sites out of the shipped contract), and the suite pool they source
# (wv-3477f0). A refusal is a
# non-zero exit in command position (statement start, or after ; | & { then
# else do), with a literal 1.. or a variable status; "(exit $rc" in a message
# is text, not a refusal.
GIT_HOOK_FILES = ("scripts/hooks/*-weave.sh", "scripts/hooks/pre-commit-recovery.sh", "scripts/lib/wv-gate-pool.sh")
GIT_REFUSAL = re.compile(r"(?:^|[;&|{]|\bthen\b|\belse\b|\bdo\b)\s*exit\s+(?:[1-9][0-9]*|\"?\$)")
# The markers build-release.sh cuts on, matched the way it matches them.
SOURCE_ONLY_BEGIN = re.compile(r"^\s*# BEGIN source-only\b")
SOURCE_ONLY_END = re.compile(r"^\s*# END source-only\b")
# Which enforcement owner decides a scope kind the denominator excludes: such a
# decision happens outside any wv call, so only that owner may make it.
OUT_OF_CALL_OWNERS = {"host_event": "host_hook", "git_event": "git_hook"}
SQL_FILES = ("scripts/lib/*.sh", "scripts/cmd/*.sh")
EMIT_FILES = ("scripts/lib/*.sh", "scripts/cmd/*.sh", "scripts/wv")
ANCHOR_WINDOW = 8


def _is_comment(line: str) -> bool:
    stripped = line.lstrip()
    return stripped.startswith("#") or stripped.startswith("--")


def _functions(lines: list[str]) -> list[str | None]:
    """The enclosing top-level function of each line, None outside any."""
    owner: list[str | None] = []
    current = None
    for line in lines:
        match = FUNCTION_DEF.match(line)
        if match:
            current = match.group(1)
        owner.append(current)
        if line.startswith("}"):
            current = None
    return owner


class Source:
    """One file's lines and the function each belongs to."""

    def __init__(self, path: Path) -> None:
        self.lines = path.read_text(encoding="utf-8", errors="replace").split("\n")
        self.owner = _functions(self.lines)

    def scope(self, function: str | None) -> list[int]:
        """Line indexes inside FUNCTION, or the whole file when it is None."""
        if function is None:
            return list(range(len(self.lines)))
        return [i for i, fn in enumerate(self.owner) if fn == function]

    def anchor_lines(self, anchor: str, function: str | None) -> list[int]:
        """Line indexes in scope whose text contains ANCHOR."""
        return [i for i in self.scope(function) if anchor in self.lines[i]]


class Checker:
    """One validation pass: loaded artifacts, source cache, claimed sites, errors."""

    def __init__(self, contract: Json, root: Path) -> None:
        self.contract = contract
        self.root = root
        self.errors: list[str] = []
        self.sources: dict[str, Source | None] = {}
        self.claimed: dict[str, list[tuple[str | None, list[int]]]] = {}
        # Lines each rule id (or "category:<name>") claims, so an emit is
        # checked against its own declaration rather than any declared site.
        self.keyed: dict[str, set[tuple[str, int]]] = {}
        self.decisions: dict[str, set[str]] = {}
        refs = contract["references"]
        self.registry = {key(row) for row in load(root / refs["capability_registry"])["commands"]}
        self.fields = load(root / refs["node_field_registry"])["fields"]
        verdict = load(root / refs["verdict_schema"])["$defs"]["verdict"]
        self.verdicts = set(verdict["properties"]["decision"]["enum"])
        self.owners = set(contract["enforcement_owners"])
        self.categories = {c["category"] for c in contract["non_policy_categories"]}

    def source(self, rel: str) -> Source | None:
        """The parsed file at REL, cached; None when it does not exist."""
        if rel not in self.sources:
            path = self.root / rel
            self.sources[rel] = Source(path) if path.is_file() else None
        return self.sources[rel]

    def vocabulary(self) -> None:
        """Decisions fold onto the verdict enum; every owner is classified for completeness."""
        decisions = set(self.contract["rule_decisions"])
        fold = {e["rule_decision"]: e["verdict"] for e in self.contract["verdict_fold"]}
        if set(fold) != decisions:
            self.errors.append(f"verdict_fold covers {sorted(fold)}, rule_decisions are {sorted(decisions)}")
        if set(fold.values()) != self.verdicts:
            self.errors.append(f"verdict_fold targets {sorted(set(fold.values()))} but the verdict "
                               f"schema's decision enum is {sorted(self.verdicts)}")
        completeness = self.contract["completeness"]
        classified = set(completeness["proven"]) | set(completeness["declared_only"])
        for owner in sorted(classified - self.owners):
            self.errors.append(f"completeness names unknown owner {owner}")
        if classified != self.owners:
            self.errors.append("completeness must classify every enforcement owner as proven or declared_only")

    def site(self, site: Json, where: str, claim: str = "") -> None:
        """Resolve a declared site in code and record the lines it claims."""
        if site["owner"] not in self.owners:
            self.errors.append(f"{where}: unknown owner {site['owner']}")
        src = self.source(site["path"])
        if src is None:
            self.errors.append(f"{where}: {site['path']} does not exist")
            return
        function = site.get("function")
        if function and not src.scope(function):
            self.errors.append(f"{where}: function {function} not found in {site['path']}")
            return
        anchor = site.get("anchor")
        hits: list[int] = []
        if anchor:
            hits = src.anchor_lines(anchor, function)
            want = site.get("occurrences", 1)
            if len(hits) != want:
                self.errors.append(f"{where}: anchor {anchor!r} occurs {len(hits)} time(s) in "
                                   f"{site['path']}{' ' + function if function else ''}, declared {want}")
        self.claimed.setdefault(site["path"], []).append((function, hits))
        if claim:
            self.keyed.setdefault(claim, set()).update((site["path"], hit) for hit in hits)

    def scope(self, scope: Json, where: str) -> None:
        """Applicability names what the registry or node field registry declares."""
        if scope["kind"] == "operation":
            pair = (scope["operation"], scope.get("suboperation", ""))
            if pair not in self.registry:
                self.errors.append(f"{where}: ({pair[0]}, {pair[1]}) is not in the capability registry")
        elif scope["kind"] == "transition":
            enum = self.fields.get(scope["field"], {}).get("value", {}).get("enum", [])
            if scope["from"] not in enum or scope["to"] not in enum:
                self.errors.append(f"{where}: transition {scope['field']} {scope['from']}->{scope['to']} "
                                   "is not declared by the node field registry")
            for operation in scope["via"]:
                if (operation, "") not in self.registry:
                    self.errors.append(f"{where}: transition via {operation}, not in the capability registry")
        elif scope.get("intercepts") and (scope["intercepts"], "") not in self.registry:
            self.errors.append(f"{where}: intercepts {scope['intercepts']}, not in the capability registry")

    def rule(self, rule: Json) -> None:
        """Check one rule's identity, vocabulary, applicability and sites."""
        rid = rule["rule_id"]
        where = f"rule {rid}"
        if rid in self.decisions:
            self.errors.append(f"{where}: duplicate rule_id")
        self.decisions[rid] = set(rule["decisions"])
        for decision in rule["decisions"]:
            if decision not in self.contract["rule_decisions"]:
                self.errors.append(f"{where}: decision {decision} is not a rule decision")
        for category in rule.get("conflates", []):
            if category not in self.categories:
                self.errors.append(f"{where}: conflates unknown category {category}")
        for scope in rule["applies_to"]:
            self.scope(scope, where)
        for site in rule["sites"]:
            self.site(site, where, rid)
            self.independent(rid, site, where)
            if site["owner"] == "command_gate" and not site.get("anchor", "").startswith(EMIT_ANCHORS):
                self.errors.append(f"{where}: command gate site in {site.get('function', site['path'])} "
                                   "is not anchored on its verdict emit")

    def independent(self, rid: str, site: Json, where: str) -> None:
        """A rule is not named after the code that happens to enforce it.

        An anchor of the form rule=<id> or wv_policy_verdict <id> is the code
        citing the rule, the one direction that is allowed.
        """
        if site.get("function") == rid:
            self.errors.append(f"{where}: rule_id equals its site's function name")
        anchor = site.get("anchor", "")
        if rid in anchor and anchor not in (f"rule={rid}", f"wv_policy_verdict {rid}"):
            self.errors.append(f"{where}: rule_id appears in its site's anchor {anchor!r}")

    def declarations(self) -> None:
        """Check every rule and every classified non-policy site."""
        for rule in self.contract["rules"]:
            self.rule(rule)
        for index, entry in enumerate(self.contract["non_policy_sites"]):
            if entry["category"] not in self.categories:
                self.errors.append(f"non_policy_sites[{index}]: unknown category {entry['category']}")
            for site in entry["sites"]:
                self.site(site, f"non_policy_sites[{index}]", "category:" + entry["category"])

    def denominator(self) -> None:
        """An exclusion may only remove decisions that happen before wv runs.

        A scope kind declared outside the denominator must belong to rules a
        host hook enforces, and a rule every scope of which is excluded must be
        enforced by host hooks alone: excluding a kind that an in-call gate also
        decides would drop real wv-call verdicts from the denominator quietly.
        Hooks never write the attempt journal, so no hook denial can become a
        wv call row.
        """
        excluded = excluded_kinds(self.contract)
        for entry in self.contract["denominator"]["excluded_scopes"]:
            if entry["kind"] in {"operation", "transition"}:
                self.errors.append(f"denominator excludes {entry['kind']} scopes, which decide inside a wv call")
            elif entry["kind"] not in OUT_OF_CALL_OWNERS:
                self.errors.append(f"denominator excludes {entry['kind']} scopes, which no out-of-call "
                                   "owner decides")
        outside = outside_denominator(self.contract)
        for rule in self.contract["rules"]:
            owners = {site["owner"] for site in rule["sites"]}
            kinds = {scope["kind"] for scope in rule["applies_to"]}
            for kind in sorted(kinds & excluded):
                owner = OUT_OF_CALL_OWNERS.get(kind)
                if owner and owner not in owners:
                    self.errors.append(f"rule {rule['rule_id']}: an excluded {kind} scope with no {owner} site")
            allowed = {OUT_OF_CALL_OWNERS[k] for k in kinds if k in OUT_OF_CALL_OWNERS}
            if rule["rule_id"] in outside and not owners <= allowed:
                self.errors.append(f"rule {rule['rule_id']}: outside the denominator but enforced in-call "
                                   f"by {sorted(owners - allowed)}")
        for rel, src in self.files(HOOK_FILES + GIT_HOOK_FILES):
            for i, line in enumerate(src.lines):
                if not _is_comment(line) and JOURNAL_WRITE.search(line):
                    self.errors.append(f"{rel}:{i + 1}: a hook writes the attempt journal; a hook denial "
                                       "is never a wv call row")

    def covered(self, rel: str, line: int, src: Source) -> bool:
        """Whether a declared site claims LINE of REL."""
        for function, hits in self.claimed.get(rel, []):
            if hits and any(abs(hit - line) <= ANCHOR_WINDOW for hit in hits):
                return True
            if not hits and function is not None and src.owner[line] == function:
                return True
        return False

    def files(self, patterns: tuple[str, ...]) -> Iterator[tuple[str, Source]]:
        """Existing files matching PATTERNS, as (repo-relative path, parsed source).

        Each pattern is one directory level, "dir/<glob>". A directory that is
        there but cannot be listed is an error, not an empty match: glob read
        one as holding nothing, and every enforcement site in it went
        unchecked while the contract validated (wv-4852bd).
        """
        for pattern in patterns:
            parent, _, name = pattern.rpartition("/")
            try:
                entries = sorted(os.listdir(self.root / parent))
            except (FileNotFoundError, NotADirectoryError):
                continue
            except OSError as exc:
                self.errors.append(f"{parent or '.'}/: cannot be listed ({exc.strerror or exc}); "
                                   f"the sites in {pattern} would go unchecked")
                continue
            for entry in entries:
                if not fnmatchcase(entry, name):
                    continue
                rel = f"{parent}/{entry}" if parent else entry
                src = self.source(rel)
                if src is not None:
                    yield rel, src

    def scan_sqlite(self) -> int:
        """Every SQLite abort must be claimed; returns how many were found."""
        found = 0
        for rel, src in self.files(SQL_FILES):
            for i, line in enumerate(src.lines):
                if SQLITE_ABORT.search(line) and not _is_comment(line):
                    found += 1
                    if not self.covered(rel, i, src):
                        self.errors.append(f"{rel}:{i + 1}: SQLite abort claimed by no rule or non-policy entry")
                if CLOSE_WRITE.search(line) and not _is_comment(line):
                    self.errors.append(f"{rel}:{i + 1}: a close written as a bare UPDATE bypasses the close "
                                       "receipt; route it through _done_close")
        return found

    def scan_hooks(self) -> int:
        """Every hook denial must be claimed; returns how many were found."""
        found = 0
        for rel, src in self.files(HOOK_FILES):
            for i, line in enumerate(src.lines):
                if _is_comment(line):
                    continue
                in_check = (src.owner[i] or "").startswith("_hc_check_")
                if HOOK_DENY.search(line) or (in_check and HOOK_RETURN.search(line)):
                    found += 1
                    if not self.covered(rel, i, src):
                        self.errors.append(f"{rel}:{i + 1}: hook denial claimed by no rule or non-policy entry")
        return found

    def scan_git_hooks(self) -> int:
        """Every refusing exit of a Weave git hook must be claimed (wv-3477f0).

        A git hook refuses by exiting non-zero, so each such exit is an
        enforcement site: a policy rule, or a non-policy category (a check the
        content failed, or a gate that could not run). An unclaimed one is a
        refusal the contract does not know about. Returns how many were found.
        """
        found = 0
        for rel, src in self.files(GIT_HOOK_FILES):
            inside = False
            for i, line in enumerate(src.lines):
                # Source-only blocks (the evidence lab, wv-1c1e15) never ship:
                # build-release.sh cuts them, so the contract, which ships,
                # describes the product without them. Markers must balance.
                if SOURCE_ONLY_BEGIN.match(line):
                    if inside:
                        self.errors.append(f"{rel}:{i + 1}: nested '# BEGIN source-only'")
                    inside = True
                    continue
                if SOURCE_ONLY_END.match(line):
                    if not inside:
                        self.errors.append(f"{rel}:{i + 1}: '# END source-only' without a BEGIN")
                    inside = False
                    continue
                if inside or _is_comment(line) or not GIT_REFUSAL.search(line):
                    continue
                found += 1
                if not self.covered(rel, i, src):
                    self.errors.append(f"{rel}:{i + 1}: git hook refusal claimed by no rule or non-policy entry")
            if inside:
                self.errors.append(f"{rel}: '# BEGIN source-only' is never closed")
        return found

    def scan_observations(self) -> int:
        """Every hook-owned rule names itself when its hook decides.

        A host-hook denial is otherwise indistinguishable from any other hook
        output, so policy totality could not observe the rule at all. Each
        _hc_observe must name a rule with a host_hook site and a decision that
        rule declares, from a line a declared site claims; each rule with a
        host_hook site must be named at least once.
        """
        hook_rules = {r["rule_id"] for r in self.contract["rules"]
                      if any(site["owner"] == "host_hook" for site in r["sites"])}
        named: set[str] = set()
        found = 0
        for rel, src in self.files(HOOK_FILES):
            for i, line in enumerate(src.lines):
                match = HOOK_OBSERVE.search(line)
                if not match or _is_comment(line):
                    continue
                found += 1
                rid, decision = match.group(1), match.group(2)
                named.add(rid)
                if rid not in hook_rules:
                    self.errors.append(f"{rel}:{i + 1}: observes {rid}, which no host_hook site enforces")
                elif decision not in self.decisions[rid]:
                    self.errors.append(f"{rel}:{i + 1}: observes {decision} for {rid}, which declares "
                                       f"{sorted(self.decisions[rid])}")
                elif not self.covered(rel, i, src):
                    self.errors.append(f"{rel}:{i + 1}: observes {rid} from a line no declared site claims")
        for rid in sorted(hook_rules - named):
            self.errors.append(f"rule {rid}: its hook decides without naming it (no _hc_observe {rid})")
        return found

    def scan_emits(self) -> int:
        """Every emit names a declared rule or category, from a site declared for it."""
        found = 0
        for rel, src in self.files(EMIT_FILES):
            for i, line in enumerate(src.lines):
                if _is_comment(line) or src.owner[i] in EMITTER_FUNCTIONS:
                    continue
                verdict, refusal = VERDICT.search(line), REFUSAL.search(line)
                if verdict:
                    self.verdict_emit(rel, i, verdict.group(1), verdict.group(2))
                elif refusal:
                    self.refusal_emit(rel, i, refusal.group(1))
                elif EMIT.search(line):
                    named = EMIT_RULE.search(" ".join(src.lines[i:i + 5]))
                    if not named:
                        self.errors.append(f"{rel}:{i + 1}: policy verdict emitted without a rule=")
                    else:
                        self.verdict_emit(rel, i, named.group(1), "")
                else:
                    continue
                found += 1
        return found

    def verdict_emit(self, rel: str, line: int, rid: str, decision: str) -> None:
        """An emitted verdict names a declared rule and decision, at that rule's site."""
        if rid not in self.decisions:
            self.errors.append(f"{rel}:{line + 1}: emits rule {rid}, which the contract does not declare")
        elif decision and decision not in self.decisions[rid]:
            self.errors.append(f"{rel}:{line + 1}: emits {decision} for {rid}, which declares "
                               f"{sorted(self.decisions[rid])}")
        elif (rel, line) not in self.keyed.get(rid, set()):
            self.errors.append(f"{rel}:{line + 1}: emits rule {rid} from a site the contract does not declare")

    def refusal_emit(self, rel: str, line: int, category: str) -> None:
        """An emitted refusal names a declared category, at a site declared for it."""
        if category not in self.categories:
            self.errors.append(f"{rel}:{line + 1}: refusal category {category} is not declared")
        elif (rel, line) not in self.keyed.get("category:" + category, set()):
            self.errors.append(f"{rel}:{line + 1}: {category} refusal from a site the contract does not declare")

def validate(contract_path: Path = DEFAULT_CONTRACT, schema_path: Path = DEFAULT_SCHEMA,
             root: Path = ROOT) -> Json:
    """Check the contract against its schema, the artifacts it references, and the code."""
    errors: list[str] = []
    contract = load(contract_path)
    schema = load(schema_path)
    apply_schema(contract, schema, schema, "$", errors)
    if errors:
        return {"errors": errors, "rules": 0, "detected": {}}
    checker = Checker(contract, root)
    checker.vocabulary()
    checker.declarations()
    checker.denominator()
    detected = {
        "sqlite_trigger": checker.scan_sqlite(),
        "host_hook": checker.scan_hooks(),
        "git_hook": checker.scan_git_hooks(),
        "emitted_verdicts": checker.scan_emits(),
        "hook_observations": checker.scan_observations(),
    }
    return {"errors": checker.errors, "rules": len(contract["rules"]), "detected": detected}


def contract_identity(contract_path: Path = DEFAULT_CONTRACT,
                      schema_path: Path = DEFAULT_SCHEMA) -> dict[str, str]:
    """The policy contract's identity: the contract AND its schema.

    Same construction as the capability registry's identity, under this
    contract's own schema id, so the two can never coincide and a consumer binds
    them separately:

        sha256(f"{schema id}\\n{schema sha256}\\n{contract sha256}\\n")
    """
    doc = load(contract_path)
    schema_sha = hashlib.sha256(schema_path.read_bytes()).hexdigest()
    contract_sha = digest(canonical(doc))
    schema_id = str(doc["schema"])
    return {
        "schema": schema_id,
        "contract_version": str(doc["contract_version"]),
        "schema_sha256": schema_sha,
        "contract_sha256": contract_sha,
        "identity_sha256": digest(f"{schema_id}\n{schema_sha}\n{contract_sha}\n"),
    }


def rule_decisions(contract_path: Path = DEFAULT_CONTRACT) -> set[str]:
    """The rule-level decision vocabulary, for consumers that must not restate it."""
    return set(load(contract_path)["rule_decisions"])


def excluded_kinds(contract: Json) -> set[str]:
    """Scope kinds the contract declares outside the wv-call denominator."""
    return {entry["kind"] for entry in contract["denominator"]["excluded_scopes"]}


def outside_denominator(contract: Json) -> set[str]:
    """Rules every scope of which is excluded: they can never decide inside a wv call."""
    excluded = excluded_kinds(contract)
    return {r["rule_id"] for r in contract["rules"]
            if all(scope["kind"] in excluded for scope in r["applies_to"])}


def applicability(contract: Json) -> dict[tuple[str, str], set[str]]:
    """The rules that can decide inside a call, keyed by (operation, suboperation).

    An operation scope without a suboperation, and a transition's via
    operations, apply to every suboperation of that operation, so they are keyed
    (operation, ""). A conditional scope applies whether or not its condition
    holds: over-inclusion can only make a call non-countable, never count one
    that a rule could have refused silently. Scopes of a kind the contract's
    denominator excludes (host_event: they decide before wv is invoked,
    wv-bd3041) are outside the per-call set.
    """
    excluded = excluded_kinds(contract)
    table: dict[tuple[str, str], set[str]] = {}
    for rule in contract["rules"]:
        for scope in rule["applies_to"]:
            if scope["kind"] in excluded:
                continue
            if scope["kind"] == "operation":
                keys = [(scope["operation"], scope.get("suboperation", ""))]
            elif scope["kind"] == "transition":
                keys = [(operation, "") for operation in scope["via"]]
            else:
                continue
            for pair in keys:
                table.setdefault(pair, set()).add(rule["rule_id"])
    return table


CALL_EVENTS = {"policy_verdict", "non_policy_refusal", "mutation_disposition", "call_completed"}


def denominator_report(journals: list[Path], contract_path: Path = DEFAULT_CONTRACT) -> Json:
    """The wv-call denominator of attempt journals, under the contract's declaration.

    A counted call is a call_id with exactly one call_started event. Anything
    else attached to a call -- a verdict, a refusal, a disposition, a completion
    -- must name one of those, so a row cannot be synthesized for a decision
    that never ran inside wv. A verdict for a rule the denominator excludes
    (one only a pre-invocation hook enforces) is a hook denial written as a wv
    call row, which the contract forbids.
    """
    contract = load(contract_path)
    rules = {r["rule_id"] for r in contract["rules"]}
    outside = outside_denominator(contract)
    errors: list[str] = []
    started: set[str] = set()
    attached: list[tuple[str, Json]] = []
    identities: set[str] = set()
    for path in journals:
        for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if not raw.strip():
                continue
            where = f"{path}:{number}"
            try:
                event = json.loads(raw)
            except json.JSONDecodeError as exc:
                errors.append(f"{where}: not valid JSON: {exc}")
                continue
            identities.add(str(event.get("policy_identity", "")))
            call = event.get("call_id")
            if not isinstance(call, str) or not call:
                errors.append(f"{where}: event has no call_id")
            elif event.get("event") == "call_started":
                if call in started:
                    errors.append(f"{where}: second call_started for {call}")
                started.add(call)
            elif event.get("event") in CALL_EVENTS:
                attached.append((where, event))
    for where, event in attached:
        call = event["call_id"]
        if call not in started:
            errors.append(f"{where}: {event['event']} for {call}, which has no call_started")
        rule = event.get("rule")
        if event.get("event") == "policy_verdict":
            if rule not in rules:
                errors.append(f"{where}: verdict for {rule}, which the contract does not declare")
            elif rule in outside:
                errors.append(f"{where}: verdict for {rule}, which only a pre-invocation hook enforces; "
                              "a hook denial is outside the wv-call denominator")
    denominator = contract["denominator"]
    return {
        "unit": denominator["unit"],
        "counted_calls": len(started),
        "call_ids": sorted(started),
        "excluded_scopes": sorted(excluded_kinds(contract)),
        "policy_identity": "sha256:" + contract_identity(contract_path)["identity_sha256"],
        "journal_policy_identities": sorted(identities),
        "errors": errors,
    }


TOTALITY_FORMAT = "weave.policy-totality.v1"
EVIDENCE_CLASSES = {"mutation_attempt", "observation", "administrative"}


def rule_cells(rule: Json) -> list[tuple[str, str | None]]:
    """What exercising RULE completely means: (decision, bypass) pairs to observe.

    Every declared decision, with no bypass, and for each bypass that leaves a
    recorded value, an allow carrying it: a flag records its name, an env knob
    NAME=value, and a state bypass only when it declares recorded_as (a prefix,
    such as quality_exempt:). A state bypass with nothing recorded is a
    condition under which the rule does not fire, not an override to observe.
    """
    cells: list[tuple[str, str | None]] = [(decision, None) for decision in rule["decisions"]]
    for bypass in rule["bypass"]:
        if bypass["kind"] == "flag":
            cells.append(("allow", bypass["name"]))
        elif bypass["kind"] == "env":
            cells.append(("allow", f"{bypass['name']}={bypass['value']}"))
        elif bypass.get("recorded_as"):
            cells.append(("allow", bypass["recorded_as"] + "*"))
    return cells


def _cell_label(cell: tuple[str, str | None]) -> str:
    return cell[0] if cell[1] is None else f"{cell[0]}+{cell[1]}"


def _observed_cells(journals: list[Path]) -> tuple[dict[str, set[tuple[str, str]]], list[str]]:
    """(rule -> {(decision, bypass)}) from the policy_verdict events of JOURNALS."""
    seen: dict[str, set[tuple[str, str]]] = {}
    errors: list[str] = []
    for path in journals:
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except OSError as exc:
            errors.append(f"journal unreadable at {path}: {exc}")
            continue
        for raw in lines:
            try:
                event = json.loads(raw) if raw.strip() else dict[str, object]()
            except json.JSONDecodeError:
                continue  # the denominator check reports it
            if event.get("event") == "policy_verdict":
                seen.setdefault(str(event.get("rule")), set()).add(
                    (str(event.get("decision")), str(event.get("bypass") or "")))
    return seen, errors


def _hook_cells(paths: list[Path], contract: Json, identity: str,
                seen: dict[str, set[tuple[str, str]]]) -> list[str]:
    """Add host-hook observations to SEEN; return what disqualifies any of them.

    An observation is a hook decision, so it may only name a rule a host hook
    enforces, must carry no wv call identity (the schema forbids one), and must
    have been written under this contract. Anything else is an error rather
    than a skipped line, so a malformed file cannot quietly prove nothing.
    """
    schema = load(HOOK_OBSERVATION_SCHEMA)
    hook_rules = {r["rule_id"] for r in contract["rules"]
                  if any(site["owner"] == "host_hook" for site in r["sites"])}
    errors: list[str] = []
    for path in paths:
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except OSError as exc:
            errors.append(f"hook observations unreadable at {path}: {exc}")
            continue
        for number, raw in enumerate(lines, 1):
            where = f"{path}:{number}"
            if not raw.strip():
                continue
            try:
                event = json.loads(raw)
            except json.JSONDecodeError as exc:
                errors.append(f"{where}: not valid JSON: {exc}")
                continue
            problems: list[str] = []
            apply_schema(event, schema, schema, "$", problems)
            if problems:
                errors.append(f"{where}: not a hook observation: {problems[0]}")
            elif event["rule"] not in hook_rules:
                errors.append(f"{where}: a hook observed {event['rule']}, which no host hook enforces")
            elif event["policy_identity"] != identity:
                errors.append(f"{where}: observed under policy identity {event['policy_identity']}, "
                              f"not this contract's {identity}")
            else:
                seen.setdefault(event["rule"], set()).add((event["decision"], event.get("bypass", "")))
    return errors


def _cell_observed(cell: tuple[str, str | None], seen: set[tuple[str, str]]) -> bool:
    decision, bypass = cell
    if bypass is None:
        return any(d == decision for d, _ in seen)
    if bypass.endswith("*"):
        return any(d == decision and b.startswith(bypass[:-1]) for d, b in seen)
    return (decision, bypass) in seen


def _registry_operations(registry_path: Path) -> tuple[list[tuple[str, str]], list[str]]:
    """The mutation-class (operation, suboperation) pairs, failing closed on any
    entry that cannot be classified."""
    errors: list[str] = []
    try:
        commands = load(registry_path)["commands"]
    except (OSError, ValueError, KeyError, TypeError) as exc:
        return [], [f"capability registry cannot be enumerated at {registry_path}: {exc}"]
    pairs: list[tuple[str, str]] = []
    for index, row in enumerate(commands):
        operation = row.get("operation") if isinstance(row, dict) else None
        klass = row.get("evidence_class") if isinstance(row, dict) else None
        if not isinstance(operation, str) or not operation or klass not in EVIDENCE_CLASSES:
            errors.append(f"registry entry {index} cannot be classified: {row!r}")
        elif klass == "mutation_attempt":
            pairs.append(key(row))
    return pairs, errors


def _operation_coverage(operations: list[tuple[str, str]], contract: Json,
                        rules: dict[str, Json]) -> tuple[dict[str, list[Json]], list[str]]:
    """Classify registry operations using observed rule states and declared gaps."""
    coverage = contract["coverage"]
    ungated = {key(entry) for entry in coverage["ungated"]}
    op_gaps = {key(entry): entry["node"] for entry in coverage["gaps"] if "operation" in entry}
    table = applicability(contract)
    errors: list[str] = []
    result: dict[str, list[Json]] = {"covered": [], "ungated": [], "gap": [], "uncovered": []}
    for pair in sorted(set(operations)):
        name = pair[0] + (f":{pair[1]}" if pair[1] else "")
        applicable = sorted(table.get((pair[0], ""), set()) | (table.get(pair, set()) if pair[1] else set()))
        pending = [r for r in applicable if rules[r]["state"] != "exercised"]
        if pair in op_gaps:
            result["gap"].append({"operation": name, "node": op_gaps[pair], "rules": applicable})
            if not pending and applicable:
                errors.append(f"operation {name} is covered but still declared a gap ({op_gaps[pair]})")
        elif not applicable:
            if pair in ungated:
                result["ungated"].append({"operation": name})
            else:
                result["uncovered"].append({"operation": name, "rules": []})
                errors.append(f"operation {name} has no applicable rule and is not declared ungated")
        elif pair in ungated:
            errors.append(f"operation {name} is declared ungated but {', '.join(applicable)} can decide in it")
        elif not pending:
            result["covered"].append({"operation": name, "rules": applicable})
        elif all(rules[r]["state"] == "gap" for r in pending):
            result["gap"].append({"operation": name, "rules": applicable,
                                  "node": sorted({rules[r]["node"] for r in pending})})
        else:
            result["uncovered"].append({"operation": name, "rules": applicable})
    for pair in sorted((ungated | set(op_gaps)) - set(operations)):
        errors.append(f"coverage declares {pair[0]}{':' + pair[1] if pair[1] else ''}, "
                      "which is not a mutation-class registry operation")
    return result, errors


# Owners whose decisions have no evidence channel at all: a host hook writes
# hook observations, a git hook writes nothing a commit's outcome could be
# grounded in (wv-3477f0).
NO_EVIDENCE_OWNERS = {"git_hook"}


def _outside_evidence(rule: Json, contract: Json) -> bool:
    """Whether RULE is enforced only by an owner with no evidence channel, at
    scopes the denominator excludes by declaration."""
    owners = {site["owner"] for site in rule["sites"]}
    kinds = {scope["kind"] for scope in rule["applies_to"]}
    return bool(owners) and owners <= NO_EVIDENCE_OWNERS and kinds <= excluded_kinds(contract)


def totality_report(journals: list[Path], contract_path: Path = DEFAULT_CONTRACT,
                    registry_path: Path | None = None, root: Path = ROOT,
                    hook_observations: list[Path] | None = None) -> Json:
    """Behavioural policy coverage: every mutation-class operation and every rule.

    An operation is covered when every rule that can decide inside it has had
    each of its cells observed as a journal verdict, ungated when the contract
    declares that no rule refuses it, and a gap when the contract records it (or
    one of its unexercised rules) as not yet countable, naming the node that
    closes it. Anything else is an error, so is a declaration that has gone
    stale (an ungated operation some rule now governs, a gap that is covered).
    Coverage is only ever what the journals show happened: a verdict whose
    emission was deleted is a missing cell, whatever the source still says.
    """
    contract = load(contract_path)
    registry_path = registry_path or root / contract["references"]["capability_registry"]
    operations, errors = _registry_operations(registry_path)
    seen, journal_errors = _observed_cells(journals)
    errors += journal_errors
    identity = "sha256:" + contract_identity(contract_path)["identity_sha256"]
    if journals:
        denominator = denominator_report(journals, contract_path)
        errors += denominator["errors"]
        # A journal written under another contract proves nothing about this one.
        for recorded in denominator["journal_policy_identities"]:
            if recorded != identity:
                errors.append(f"a journal was recorded under policy identity {recorded or '(none)'}, "
                              f"not this contract's {identity}")
    errors += _hook_cells(hook_observations or [], contract, identity, seen)
    coverage = contract["coverage"]
    rule_gaps = {entry["rule"]: entry["node"] for entry in coverage["gaps"] if "rule" in entry}

    rules: dict[str, Json] = {}
    for rule in contract["rules"]:
        rid = rule["rule_id"]
        if _outside_evidence(rule, contract):
            # A git hook decides outside any wv call, and nothing it runs is
            # proof of the commit's outcome, so no journal or observation can
            # exercise the rule (wv-3477f0). Reported, never counted or gapped.
            rules[rid] = {"state": "outside_evidence"}
            if rid in rule_gaps:
                errors.append(f"rule {rid} is outside evidence by declaration but still declared a gap")
            continue
        missing = [_cell_label(c) for c in rule_cells(rule) if not _cell_observed(c, seen.get(rid, set()))]
        if not missing:
            rules[rid] = {"state": "exercised"}
            if rid in rule_gaps:
                errors.append(f"rule {rid} is fully exercised but still declared a gap ({rule_gaps[rid]})")
        elif rid in rule_gaps:
            rules[rid] = {"state": "gap", "missing": missing, "node": rule_gaps[rid]}
        else:
            rules[rid] = {"state": "unexercised", "missing": missing}
            errors.append(f"rule {rid} has no observed verdict for {', '.join(missing)} and no declared gap")

    result, operation_errors = _operation_coverage(operations, contract, rules)
    errors += operation_errors
    for rid in sorted(set(rule_gaps) - set(rules)):
        errors.append(f"coverage declares a gap for rule {rid}, which the contract does not declare")

    gaps = bool(result["gap"]) or any(r["state"] == "gap" for r in rules.values())
    return {
        "format": TOTALITY_FORMAT,
        "policy_identity": identity,
        "registry_sha256": "sha256:" + hashlib.sha256(registry_path.read_bytes()).hexdigest()
        if registry_path.is_file() else None,
        "journals": [str(p) for p in journals],
        "hook_observations": [str(p) for p in hook_observations or []],
        "operations": result,
        "counts": {k: len(v) for k, v in result.items()} | {"enumerated": len(operations)},
        "rules": rules,
        "errors": errors,
        "passed": not errors,
        "complete": not errors and not gaps,
    }


def shell(contract_path: Path = DEFAULT_CONTRACT, schema_path: Path = DEFAULT_SCHEMA) -> str:
    """The generated shell projection: contract identity and per-call applicability."""
    identity = contract_identity(contract_path, schema_path)
    table = applicability(load(contract_path))
    base = {op: rules for (op, sub), rules in table.items() if not sub}
    out = [
        "#!/bin/bash",
        GENERATED_HEADER,
        "#",
        "# Regenerate: python3 scripts/weave_policy.py generate",
        "# Verify:     python3 scripts/weave_policy.py check",
        "#",
        "# _wv_policy_applicable <operation> [suboperation] prints the rules that can",
        "# decide inside such a call, space-separated and sorted. A suboperation",
        "# branch already includes its operation's rules.",
        "",
        f'WV_POLICY_SCHEMA="{identity["schema"]}"',
        f'WV_POLICY_CONTRACT_VERSION="{identity["contract_version"]}"',
        f'WV_POLICY_IDENTITY="{identity["identity_sha256"]}"',
        "",
        "_wv_policy_applicable() {",
        '    case "${1}:${2-}" in',
    ]
    for (op, sub), rules in sorted(table.items()):
        if sub:
            joined = " ".join(sorted(rules | base.get(op, set())))
            out.append(f'        {op}:{sub}) printf %s "{joined}"; return 0 ;;')
    out += ["    esac", '    case "$1" in']
    for op, rules in sorted(base.items()):
        out.append(f'        {op}) printf %s "{" ".join(sorted(rules))}"; return 0 ;;')
    out += ["    esac", "    return 0", "}", ""]
    return "\n".join(out)


def main() -> int:
    """Command-line entry: validate or print identity."""
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="command", required=True)
    check = sub.add_parser("validate")
    check.add_argument("--contract", type=Path, default=DEFAULT_CONTRACT)
    check.add_argument("--schema", type=Path, default=DEFAULT_SCHEMA)
    check.add_argument("--root", type=Path, default=ROOT)
    check.add_argument("--json", action="store_true")
    ident = sub.add_parser("identity")
    ident.add_argument("--contract", type=Path, default=DEFAULT_CONTRACT)
    ident.add_argument("--schema", type=Path, default=DEFAULT_SCHEMA)
    denom = sub.add_parser("denominator")
    denom.add_argument("journals", type=Path, nargs="+")
    denom.add_argument("--contract", type=Path, default=DEFAULT_CONTRACT)
    total = sub.add_parser("totality")
    total.add_argument("journals", type=Path, nargs="*")
    total.add_argument("--contract", type=Path, default=DEFAULT_CONTRACT)
    total.add_argument("--registry", type=Path)
    total.add_argument("--summary", type=Path, help="also write the report here")
    total.add_argument("--hook-observations", type=Path, action="append", default=[],
                       help="host-hook observation JSONL (WV_HOOK_OBSERVATIONS); repeatable")
    for name in ("generate", "check"):
        proj = sub.add_parser(name)
        proj.add_argument("--contract", type=Path, default=DEFAULT_CONTRACT)
        proj.add_argument("--schema", type=Path, default=DEFAULT_SCHEMA)
        proj.add_argument("--artifact", type=Path, default=DEFAULT_ARTIFACT)
    args = ap.parse_args()

    if args.command == "identity":
        print(json.dumps(contract_identity(args.contract, args.schema), indent=2))
        return 0
    if args.command == "denominator":
        report = denominator_report(args.journals, args.contract)
        print(json.dumps(report, indent=2))
        return 1 if report["errors"] else 0
    if args.command == "totality":
        report = totality_report(args.journals, args.contract, args.registry,
                                 hook_observations=args.hook_observations)
        text = json.dumps(report, indent=2) + "\n"
        if args.summary:
            args.summary.parent.mkdir(parents=True, exist_ok=True)
            args.summary.write_text(text, encoding="utf-8")
        print(text, end="")
        return 1 if report["errors"] else 0
    if args.command == "generate":
        args.artifact.write_text(shell(args.contract, args.schema), encoding="utf-8")
        print(f"wrote {args.artifact}")
        return 0
    if args.command == "check":
        current = args.artifact.read_text(encoding="utf-8") if args.artifact.is_file() else None
        if current != shell(args.contract, args.schema):
            print(f"x {args.artifact} differs from the policy contract -- regenerate with: "
                  "python3 scripts/weave_policy.py generate", file=sys.stderr)
            return 1
        return 0
    report = validate(args.contract, args.schema, args.root.resolve())
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        for error in report["errors"]:
            print(f"error: {error}", file=sys.stderr)
        state = "invalid" if report["errors"] else "valid"
        print(f"policy contract {state}: {report['rules']} rules; detected "
              + ", ".join(f"{k}={v}" for k, v in report["detected"].items()))
    return 1 if report["errors"] else 0


if __name__ == "__main__":
    sys.exit(main())
