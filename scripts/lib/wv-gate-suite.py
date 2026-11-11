#!/usr/bin/env python3
"""Execute a suite against frozen Git content with private declared build inputs.

The caller supplies protected policy, not policy from the candidate. Git's
immutable object store supplies history; no checkout environment or generated
output is copied. Each invocation owns its worktree, index, dependencies and
caches. The caller's supervisor owns cancellation and scratch cleanup.
"""

from __future__ import annotations

import argparse
import configparser
import fcntl
from fnmatch import fnmatchcase
import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
from typing import Any

# The paths that make a tree Weave's own source, as both hooks test them.
SELF_HOST_MARKERS = frozenset({"scripts/hooks/pre-commit-weave.sh", "scripts/wv"})


class SuiteError(Exception):
    """Required snapshot or provisioning input could not be established."""


def digest(path: Path) -> str:
    """Hash actual bytes rather than accepting a declared digest."""
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def run(command: list[str], cwd: Path, env: dict[str, str], *, capture: bool = False) -> str:
    """Run a prerequisite, preserving its failure as a gate refusal."""
    result = subprocess.run(command, cwd=cwd, env=env, check=False, text=True,
                            stdout=subprocess.PIPE if capture else None)
    if result.returncode:
        raise SuiteError(f"{command[0]} exited {result.returncode}: {' '.join(command[1:])}")
    return result.stdout.strip() if capture else ""


def private_environment(repo: Path, work: Path) -> dict[str, str]:
    """Own Git, graph and filesystem state; toolchain settings belong to policy."""
    env = dict(os.environ)
    for key in list(env):
        if key.startswith("GIT_"):
            env.pop(key)
    for key in ("WV_DB", "WV_HOT_ZONE", "WV_PROJECT_DIR", "WEAVE_DIR",
                "WV_CONFIG_DIR", "WV_CALL_LOG", "WV_LIB_DIR", "WV_CLI"):
        env.pop(key, None)
    paths = []
    for entry in os.get_exec_path():
        path = Path(entry).resolve()
        if not path.is_relative_to(repo):
            paths.append(str(path))
    env.update({
        "PATH": os.pathsep.join(paths), "HOME": str(work / "home"),
        "XDG_CONFIG_HOME": str(work / "config"), "XDG_CACHE_HOME": str(work / "cache"),
        "TMPDIR": str(work / "tmp"),
        "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "core.hooksPath",
        "GIT_CONFIG_VALUE_0": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CEILING_DIRECTORIES": str(work),
        "WV_TEST_MODE": "1",
        "WV_TEST_HOT_ZONE_ROOT": str(work / "hotzones"),
        "WV_CONFIG_DIR": str(work / "weave-config"),
        "WV_TEST_SUITE": "1", "WV_CALL_SOURCE": "test",
    })
    for name in ("home", "config", "cache", "tmp", "weave-config"):
        (work / name).mkdir()
    return env


def compatibility(path: Path | None) -> tuple[dict[str, Any], str]:
    """Interpret old tokens using trusted data, never candidate defaults."""
    source = path or Path(__file__).with_name("wv-gate-provision.json")
    raw = source.read_bytes()
    document = json.loads(raw, object_pairs_hook=declaration_object)
    if "compatibility" not in document and path is not None:
        source = Path(__file__).with_name("wv-gate-provision.json")
        raw = source.read_bytes()
        document = json.loads(raw, object_pairs_hook=declaration_object)
    catalog = declaration_fields(document["compatibility"],
                                 {"tools", "environment", "commands", "recipes", "executors"}, "compatibility catalog")
    declaration_list(catalog["tools"], "compatibility tools")
    if not isinstance(catalog["recipes"], dict) or not isinstance(catalog["executors"], dict):
        raise SuiteError("compatibility recipes and executors must be objects")
    for recipe in catalog["recipes"].values():
        generic_recipe(recipe)
    for spec in catalog["executors"].values():
        declaration_fields(spec, {"requires", "run"}, "compatibility executor")
        declaration_list(spec["requires"], "compatibility executor prerequisites")
        declaration_list(spec["run"], "compatibility executor argv")
    command_policy(catalog["commands"])
    environment_policy(catalog["environment"])
    return catalog, hashlib.sha256(raw).hexdigest()


def policy_for(path: Path | None, suite: str, document: dict[str, Any] | None = None) -> dict[str, Any]:
    """Normalize installed legacy policy or select an already normalized suite."""
    if document is not None:
        return dict(document["suites"][suite])
    policy: dict[str, Any] = {"version": 1, "default": {}}
    if path:
        policy = json.loads(path.read_text(), object_pairs_hook=declaration_object)
    if policy.get("version") != 1:
        raise SuiteError("unsupported suite provisioning policy version")
    catalog, catalog_hash = compatibility(path)
    merged: dict[str, Any] = {"tools": catalog["tools"], "dependencies": [], "artifacts": []}
    for entry in (policy["default"], policy.get("suites", {}).get(suite, {})):
        for key in ("tools", "dependencies", "artifacts"):
            merged[key] = sorted(set(merged[key] + declaration_list(entry.get(key, []), key)))
        for key in ("executor", "history"):
            if key in entry:
                merged[key] = entry[key]
    return legacy_suite(merged, suite, catalog, catalog_hash)


def legacy_suite(entry: dict[str, Any], suite: str, catalog: dict[str, Any], catalog_hash: str) -> dict[str, Any]:
    """Old declarations select opaque catalog records, not engine branches."""
    tools = sorted(set(catalog["tools"] + entry.get("tools", [])))
    names = sorted(set(entry.get("dependencies", []))) + sorted(set(entry.get("artifacts", [])))
    recipes = []
    for name in names:
        if name not in catalog["recipes"]:
            raise SuiteError(f"unsupported dependency declaration: {name}")
        recipe = catalog["recipes"][name]
        if not set(recipe.get("tools", [])).issubset(tools):
            raise SuiteError(f"dependency {name} has undeclared toolchain inputs")
        if not set(recipe.get("requires", [])).issubset(names[:names.index(name)]):
            raise SuiteError(f"unsupported artifact declaration: {name}; missing prerequisite")
        recipes.append(dict(recipe))
    executor = entry.get("executor", "bash")
    if executor not in catalog["executors"]:
        raise SuiteError(f"unsupported suite executor {executor}")
    spec = catalog["executors"][executor]
    if not set(spec["requires"]).issubset(names):
        raise SuiteError(f"{executor} executor requires declared private dependencies")
    history = entry.get("history", "base")
    if history not in ("base", "none"):
        raise SuiteError(f"unsupported history declaration for {suite}")
    return {"tools": tools, "recipes": recipes, "executor": spec["run"], "history": history,
            "environment": catalog["environment"], "commands": catalog["commands"], "catalog_sha256": catalog_hash}


def tool_identity(name: str, env: dict[str, str], cwd: Path) -> dict[str, str]:
    """Host toolchains are explicit residual inputs: resolved bytes and version."""
    executable = shutil.which(name, path=env["PATH"])
    if executable is None:
        raise SuiteError(f"required toolchain {name} is missing")
    path = Path(executable).resolve()
    version = subprocess.run([executable, "--version"], cwd=cwd, env=env, check=False,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return {"path": str(path), "sha256": digest(path),
            "version": version.stdout.strip(), "version_exit": str(version.returncode)}


def tree_entries(repo: Path, tree: str, env: dict[str, str]) -> dict[str, str]:
    """Acquire modes and objects from immutable trees, including graph inputs."""
    result = subprocess.run(["git", "ls-tree", "-rz", tree], cwd=repo, env=env,
                            check=True, stdout=subprocess.PIPE)
    entries = {}
    for entry in result.stdout.split(b"\0"):
        if entry:
            metadata, path = entry.split(b"\t", 1)
            entries[os.fsdecode(path)] = metadata.decode()
    return entries


def declaration_fields(value: Any, allowed: set[str], label: str) -> dict[str, Any]:
    """Reject unsupported schema fields rather than pretending to execute them."""
    if not isinstance(value, dict) or set(value) - allowed:
        raise SuiteError(f"invalid {label}: expected only {sorted(allowed)}")
    return value


def declaration_list(value: Any, label: str) -> list[str]:
    """Declarations contain names, not shell strings or implicit conversions."""
    if not isinstance(value, list) or not all(isinstance(item, str) and item for item in value):
        raise SuiteError(f"invalid {label}: expected a list of nonempty strings")
    return value


def declaration_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    """Duplicate JSON keys cannot ambiguously establish policy or adoption."""
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise SuiteError(f"duplicate declaration key: {key}")
        result[key] = value
    return result


def string_map(value: Any, label: str) -> dict[str, str]:
    """Environment and command declarations do not coerce JSON values."""
    if not isinstance(value, dict) or not all(isinstance(k, str) and k and isinstance(v, str)
                                              for k, v in value.items()):
        raise SuiteError(f"invalid {label}: expected string mappings")
    return value


def environment_policy(value: Any) -> dict[str, Any]:
    """Toolchain isolation settings are explicit protected data."""
    value = declaration_fields(value, {"unset", "set", "inherit", "path_markers"}, "environment")
    for field in ("unset", "path_markers"):
        declaration_list(value.get(field, []), f"environment {field}")
    for field in ("set", "inherit"):
        string_map(value.get(field, {}), f"environment {field}")
    return value


def relative_path(value: Any, label: str, *, dot: bool = False) -> str:
    """Declared source paths cannot escape or alias the frozen root."""
    if not isinstance(value, str) or not value:
        raise SuiteError(f"{label} must be a repository-relative path")
    if value == "." and dot:
        return value
    if (Path(value).is_absolute() or "\\" in value
            or any(part in ("", ".", "..") for part in value.split("/"))
            or any(ord(char) < 32 for char in value)):
        raise SuiteError(f"{label} must be a repository-relative path")
    return value


def command_policy(value: Any) -> dict[str, str]:
    """Only named, relative source commands may be exposed on PATH."""
    aliases = string_map(value, "commands")
    for name, path in aliases.items():
        relative_path(name, "command name")
        if "/" in name:
            raise SuiteError("command name must not contain a directory")
        relative_path(path, "command source")
    return aliases


def generic_recipe(value: Any) -> dict[str, Any]:
    """Validate generic commands without choosing a language or build system."""
    value = declaration_fields(value,
                               {"tools", "inputs", "run", "cwd", "env", "outputs", "provides", "requires",
                                "resolution", "fetch"}, "recipe")
    for field in ("tools", "inputs", "outputs", "requires"):
        declaration_list(value.get(field, []), f"recipe {field}")
    for path in value.get("inputs", []):
        relative_path(path, "recipe input")
    for field in ("env", "provides"):
        string_map(value.get(field, {}), f"recipe {field}")
    commands = value.get("run")
    if not isinstance(commands, list) or not commands:
        raise SuiteError("recipe run requires nonempty argv")
    for argv in [commands] if isinstance(commands[0], str) else commands:
        if not declaration_list(argv, "recipe argv"):
            raise SuiteError("recipe run requires nonempty argv")
    for path in [value.get("cwd", "."), *value.get("outputs", [])]:
        relative_path(path, "recipe cwd/output", dot=True)
    if "resolution" in value:
        relative_path(value["resolution"], "captured resolution")
        if not value.get("outputs"):
            raise SuiteError("a captured resolution requires installed outputs")
    if "fetch" in value:
        argv = declaration_list(value["fetch"], "artifact fetch argv")
        if "resolution" not in value or not any("{artifact}" in arg for arg in argv):
            raise SuiteError("artifact fetch requires a resolution and an {artifact} destination")
    return value


def declaration_policy(document: Any, catalog_path: Path | None = None) -> dict[str, Any]:
    """Old and generic protected declarations converge on the same executor."""
    document = declaration_fields(document,
                                  {"version", "recipes", "suites", "default", "environment", "commands", "tools"},
                                  "declaration")
    if (not isinstance(document.get("version"), int) or document["version"] not in (2, 3)
            or document.get("default", {"mode": "checkout"}) != {"mode": "checkout"}):
        raise SuiteError("unsupported declaration version or default mode")
    legacy = document["version"] == 2
    if legacy and set(document) & {"environment", "commands", "tools"}:
        raise SuiteError("unsupported legacy declaration fields")
    catalog: dict[str, Any] = {}
    catalog_hash = ""
    if legacy:
        catalog, catalog_hash = compatibility(catalog_path)
    settings = environment_policy(document.get("environment", {}))
    shared_tools = declaration_list(document.get("tools", []), "declaration tools")
    aliases = command_policy(document.get("commands", {}))
    recipes = document.get("recipes")
    suites = document.get("suites")
    if not isinstance(recipes, dict) or not isinstance(suites, dict):
        raise SuiteError("declaration requires recipe and suite objects")
    for name, recipe in recipes.items():
        if legacy:
            declaration_fields(recipe, {"tools", "dependencies", "artifacts"}, f"recipe {name}")
            for field, values in recipe.items():
                declaration_list(values, f"recipe {name} {field}")
            legacy_suite(dict(recipe, artifacts=[]), "", catalog, catalog_hash)
            if any(label not in catalog["recipes"] for label in recipe.get("artifacts", [])):
                raise SuiteError(f"unsupported artifact declaration in recipe {name}")
        else:
            generic_recipe(recipe)
    policy: dict[str, Any] = {"suites": {}}
    for suite, raw in suites.items():
        relative_path(suite, "suite")
        entry = declaration_fields(raw, {"tools", "recipes", "executor", "history"}, f"suite {suite}")
        expanded: dict[str, Any] = {"tools": declaration_list(entry.get("tools", []), f"suite {suite} tools"),
                                    "dependencies": [], "artifacts": []}
        for name in declaration_list(entry.get("recipes", []), f"suite {suite} recipes"):
            if name not in recipes:
                raise SuiteError(f"suite {suite} names missing recipe {name}")
            if legacy:
                for field in ("tools", "dependencies", "artifacts"):
                    expanded[field] += recipes[name].get(field, [])
            else:
                expanded["tools"] += recipes[name].get("tools", [])
        expanded["executor"] = entry.get("executor", "bash" if legacy else [])
        expanded["history"] = entry.get("history", "base")
        if expanded["history"] not in ("base", "none"):
            raise SuiteError(f"unsupported history declaration for {suite}")
        if legacy:
            policy["suites"][suite] = legacy_suite(expanded, suite, catalog, catalog_hash)
        else:
            declaration_list(expanded["executor"], "suite executor")
            selected = entry.get("recipes", [])
            for index, name in enumerate(selected):
                if not set(recipes[name].get("requires", [])).issubset(selected[:index]):
                    raise SuiteError(f"recipe {name} requires an earlier selected recipe")
            policy["suites"][suite] = {"tools": sorted(set(["bash", "git"] + shared_tools + expanded["tools"])),
                "recipes": [recipes[name] for name in selected], "executor": expanded["executor"],
                "history": expanded["history"], "environment": settings, "commands": aliases}
    return policy


def read_declaration(repo: Path, revision: str, env: dict[str, str],
                     catalog_path: Path | None = None) -> tuple[str | None, dict[str, Any] | None]:
    """Only immutable regular blobs can declare adoption; broken is not absent."""
    entry = run(["git", "ls-tree", revision, "--", ".weave/gate-provision.json"],
                repo, env, capture=True)
    if not entry:
        return None, None
    entry = entry.split("\t", 1)[0]
    if not entry.startswith(("100644 blob ", "100755 blob ")):
        raise SuiteError("provisioning declaration is not a regular file")
    document = json.loads(run(["git", "cat-file", "blob", entry.split()[-1]], repo, env, capture=True),
                          object_pairs_hook=declaration_object)
    return entry, declaration_policy(document, catalog_path)


def retirement_refusal(code: int, removed: list[str], template: str) -> str:
    """Say what an unadmitted removal of adopted suites needs (wv-cc36c7).

    The refusal used to print the internal check's shell script. A consumer
    could not tell that a record admits the removal, where it goes, or what it
    must say; the record is printed here with the exact bytes it must name.
    """
    what = ("stops declaring " + ", ".join(removed)) if removed else "removes .weave/gate-provision.json"
    if code == 3:
        return (f"this commit {what}; a retirement record matches, but its one use cannot be "
                "established in a shallow or partial clone: fetch complete history and commit again")
    if code != 1:
        return f"this commit {what}, and the gate could not establish whether a retirement record admits it"
    return (f"this commit {what}, which adopted suites cannot do silently (transition rule 4). "
            "Commit a retirement record under .weave/gate-repairs/ first, on its own, then commit this "
            "change; the record admits these exact bytes once. Fill in reason and verification:\n" + template)


def declaration_plan(repo: Path, tree: str, base: str | None, env: dict[str, str],
                     catalog_path: Path | None = None) -> dict[str, Any]:
    """Validate both sides before selecting per-suite mode from the base alone."""
    env = dict(env, GIT_NO_REPLACE_OBJECTS="1")
    baseline = base or run(["git", "hash-object", "-t", "tree", "/dev/null"], repo, env, capture=True)
    old_entry, old = read_declaration(repo, baseline, env, catalog_path)
    _, candidate = read_declaration(repo, tree, env, catalog_path)
    removed: set[str] = set()
    if old is not None:
        removed.update(old["suites"])
    if candidate is not None:
        removed.difference_update(candidate["suites"])
    if old and (candidate is None or removed):
        # Use the existing exact-byte, mode-bound, one-use history check;
        # staged records, shallow history and replay cannot admit removal.
        library = Path(__file__).resolve().parent
        checked = subprocess.run(["bash", "-c", '''
source "$1/wv-gate-snapshot.sh" || exit 2
source "$1/wv-gate-lanes.sh" || exit 2
WV_GATE_TREE=$2 WV_GATE_BASE=$3
gate_repair_record .weave/gate-provision.json retirement >/dev/null; rc=$?
[ "$rc" -ne 1 ] || _gate_repair_template .weave/gate-provision.json retirement
exit "$rc"
''', "provision-retirement", str(library), tree, baseline], cwd=repo, env=env, check=False, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        if checked.returncode:
            raise SuiteError(retirement_refusal(checked.returncode, sorted(removed) if candidate else [],
                                                checked.stdout.strip()))
    # Weave's own tree, by the hooks' K1 test (wv-9da519): the hook AND
    # scripts/wv. A consumer that vendors the hook sources has no scripts/wv
    # and runs its suites in checkout mode (wv-981f92).
    legacy = old is None and SELF_HOST_MARKERS <= tree_entries(repo, baseline, env).keys()
    if legacy and run(["git", "log", "-1", "--format=%H", baseline, "--", ".weave/gate-provision.json"],
                      repo, env, capture=True):
        legacy = False  # A retired declaration must not resurrect installed defaults.
    if legacy and run(["git", "rev-parse", "--is-shallow-repository"], repo, env, capture=True) == "true":
        raise SuiteError("shallow history cannot establish legacy bootstrap eligibility; fetch complete history")
    return {"default_mode": "frozen" if legacy else "checkout", "policy": old,
            "declaration": old_entry}


def selected_policy(args: argparse.Namespace, suite: str) -> tuple[str, dict[str, Any]]:
    """Installed defaults apply only to the legacy self-host bootstrap."""
    if args.mode != "auto":
        return args.mode, policy_for(args.policy, suite)
    document = args.declaration["policy"]
    if document is not None:
        if suite in document["suites"]:
            return "frozen", policy_for(None, suite, document)
        return "checkout", {}
    mode = args.declaration["default_mode"]
    return mode, policy_for(args.policy, suite) if mode == "frozen" else {}


def frozen_maps(repo: Path, revisions: list[str],
                env: dict[str, str]) -> list[tuple[str | None, configparser.ConfigParser]]:
    """Read and validate the candidate and baseline routing declarations."""
    maps = []
    for revision in dict.fromkeys(revisions):
        listing = tree_entries(repo, revision, env)
        entry = listing.get(".weave/test-map.conf")
        conf = configparser.ConfigParser(interpolation=None, strict=False, allow_no_value=True, delimiters=("=",))
        conf.optionxform = lambda optionstr: optionstr
        if entry:
            if not entry.startswith(("100644 blob ", "100755 blob ")):
                raise SuiteError("frozen test map is not a regular file")
            conf.read_string(run(["git", "cat-file", "blob", entry.split()[-1]], repo, env, capture=True))
        maps.append((entry, conf))
    return maps


def routed_inputs(repo: Path, tree: str, base: str, changed: set[str],
                  env: dict[str, str], work: Path) -> dict[str, set[str]]:
    """Resolve frozen changed inputs with the gate's existing suite router."""
    routed: dict[str, set[str]] = {}
    if changed:
        if any("\n" in path for path in changed):
            raise SuiteError("the reuse route table cannot represent a newline in an input path")
        # Use the gate's existing router, including scanners, defaults and
        # naming rules. Do not implement a second, narrower routing algorithm.
        scripts = Path(__file__).resolve().parents[1]
        route_text = run(["bash", "-c", '''
source "$1/cmd/wv-cmd-graph.sh" || exit
REPO_ROOT=$2 WEAVE_DIR=$5
_IMPACT_MAP_REVS=("$3" "$4")
shift 5
_impact_suites_for_files --routes "$@"
''', "snapshot-routes", str(scripts), str(repo), tree, base, str(work / "routing"), *sorted(changed)],
                         repo, env, capture=True)
        for line in route_text.splitlines():
            path, suite = line.rsplit("\t", 1)
            if path not in changed:
                raise SuiteError("router returned an input outside the frozen change set")
            routed.setdefault(suite, set()).add(path)
    return routed


def suite_inputs(suite: str, policy: dict[str, Any], entries: dict[str, str], changed: set[str],
                 maps: list[tuple[str | None, configparser.ConfigParser]],
                 routed: dict[str, set[str]]) -> set[str]:
    """Combine scoped source inputs with mandatory dependency and build inputs."""
    scopes = [(conf.get("inputs", suite) or "").split() for _, conf in maps
              if conf.has_option("inputs", suite) and conf.get("inputs", suite) is not None]
    paths = set(changed)
    if scopes:
        paths = {path for path in changed
                 if any(fnmatchcase(path, glob) or (glob.endswith("/") and path.startswith(glob))
                        for scope in scopes for glob in scope)
                 or path in routed.get(suite, set())}
    paths.add(suite)
    paths.update(recipe_inputs(policy, entries))
    return paths


def recipe_inputs(policy: dict[str, Any], entries: dict[str, str]) -> set[str]:
    """Every declared pattern must acquire regular blobs from the frozen tree."""
    paths: set[str] = set()
    for recipe in policy["recipes"]:
        patterns = recipe.get("inputs", []) + ([recipe["resolution"]] if "resolution" in recipe else [])
        for pattern in patterns:
            matched = {path for path in entries if fnmatchcase(path, pattern)}
            if not matched:
                raise SuiteError(f"missing frozen recipe input: {pattern}")
            if any(not entries[path].startswith(("100644 blob ", "100755 blob ")) for path in matched):
                raise SuiteError(f"recipe input is not a regular frozen blob: {pattern}")
            paths.update(matched)
    return paths


def substitute(value: str, root: Path, work: Path) -> str:
    """Replace only owned path tokens; ordinary command syntax stays literal."""
    for name, path in {"work": root, "env": work / "env", "cache": work / "cache"}.items():
        value = value.replace("{" + name + "}", str(path))
    return value


def configured_environment(policy: dict[str, Any], env: dict[str, str], root: Path, work: Path) -> dict[str, str]:
    """Apply protected environment data identically during planning and execution."""
    result = dict(env)
    config = policy["environment"]
    for key in list(result):
        if any(fnmatchcase(key, pattern) for pattern in config.get("unset", [])):
            del result[key]
    markers = config.get("path_markers", [])
    result["PATH"] = os.pathsep.join(path for path in result["PATH"].split(os.pathsep)
                                    if not any((Path(path).parent / marker).exists() for marker in markers))
    for key, fallback in config.get("inherit", {}).items():
        result[key] = os.environ.get(key, os.path.expanduser(fallback))
    result.update({key: substitute(value, root, work) for key, value in config.get("set", {}).items()})
    return result


def describe(args: argparse.Namespace, env: dict[str, str], work: Path) -> dict[str, Any]:
    """Freeze a reuse plan before installing anything; legacy keys cannot match.

    Content scopes describe subject inputs, not history independence. History
    is conservative by default; only protected policy can opt a suite out.
    Enforcement is keyed by content, not a graph-only commit's tree identity.
    """
    repo = args.repo.resolve()
    tree = run(["git", "rev-parse", f"{args.tree}^{{tree}}"], repo, env, capture=True)
    authority = args.authority or args.base or tree
    base = args.base or run(["git", "hash-object", "-t", "tree", "/dev/null"], repo, env, capture=True)
    upstream = subprocess.run(["git", "rev-parse", "--verify", "@{u}"], cwd=repo, env=env,
                              check=False, capture_output=True, text=True)
    input_base = base
    if args.base and upstream.returncode == 0:
        input_base = run(["git", "merge-base", args.base, upstream.stdout.strip()], repo, env, capture=True)
    entries = tree_entries(repo, tree, env)
    previous = tree_entries(repo, input_base, env)
    changed = {path for path in entries.keys() | previous.keys() if entries.get(path) != previous.get(path)}
    maps = frozen_maps(repo, [tree, base], env)
    authority_entries = tree_entries(repo, authority, env)
    roles_entry = authority_entries.get("scripts/hooks/gate-roles.json")
    roles: dict[str, list[str]] = {"enforcement": ["scripts/"], "invoking": []}
    if roles_entry:
        roles = json.loads(run(["git", "cat-file", "blob", roles_entry.split()[-1]], repo, env, capture=True))
    enforcement = {path: entry for path, entry in authority_entries.items()
                   if any(path == prefix.rstrip("/") or path.startswith(prefix.rstrip("/") + "/")
                          for prefix in roles["enforcement"])}
    scripts = Path(__file__).resolve().parents[1]
    routed = routed_inputs(repo, tree, base, changed, env, work)
    invoking = {}
    for path in roles["invoking"]:
        actual = scripts / path.removeprefix("scripts/") if path.startswith("scripts/") else scripts.parent / path
        invoking[path] = digest(actual) if actual.is_file() else None
    volatile = {"_", "PWD", "OLDPWD", "SHLVL", "WV_GATE_ID", "WV_GATE_PHASE", "WV_GATE_EXECUTION_MODE",
                "WV_GATE_TREE", "WV_GATE_BASE", "WV_GATE_POOL_TAG"}
    common = {"execution_mode": "frozen", "input_base": input_base, "maps": [entry for entry, _ in maps],
              "enforcement": enforcement, "invoking": invoking,
              "router_sha256": digest(scripts / "cmd/wv-cmd-graph.sh"),
              "backend": digest(Path(__file__)), "platform": [platform.system(), platform.machine()],
              "context": os.environ.get("WV_GATE_CONTEXT", "precommit")}
    plans: dict[str, Any] = {}
    for suite in args.command:
        mode, policy = selected_policy(args, suite)
        if mode == "checkout":
            plans[suite] = {"key": None, "identity": {"execution_mode": "checkout"}}
            continue
        execution_env = configured_environment(policy, env, work / "tree", work)
        environment = {key: value.replace(str(work), "<private>")
                       for key, value in execution_env.items() if key not in volatile}
        tools = {name: tool_identity(name, execution_env, work) for name in policy["tools"]}
        paths = suite_inputs(suite, policy, entries, changed, maps, routed)
        identity = dict(common, policy=policy, tools=tools,
                        environment_sha256=hashlib.sha256(json.dumps(environment, sort_keys=True).encode()).hexdigest(),
                        inputs={path: entries.get(path) for path in sorted(paths)},
                        history=args.base if policy["history"] == "base" else None)
        if args.mode == "auto":
            identity["declaration"] = args.declaration["declaration"]
        key = "snapshot-v1:" + hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
        plans[suite] = {"key": key, "identity": identity}
    return {"tree": tree, "base": args.base, "authority": authority, "suites": plans}


def snapshot(repo: Path, tree: str, base: str | None, root: Path, env: dict[str, str]) -> None:
    """Use private Git metadata and a synthetic candidate with the original parent.

    Alternates read immutable Git history, not build outputs. All new objects,
    refs, index writes and checkout writes belong to this invocation. Remove
    the clone's remote so a suite cannot accidentally push to the source repo.
    """
    run(["git", "clone", "--quiet", "--shared", "--no-checkout", "--", str(repo), str(root)],
        root.parent, env)
    run(["git", "remote", "remove", "origin"], root, env)
    tree = run(["git", "rev-parse", "--verify", f"{tree}^{{tree}}"], root, env, capture=True)
    # Do not materialise an outbound tracked symlink, including one whose
    # intermediate components could redirect writes outside the snapshot.
    entries = subprocess.run(["git", "ls-tree", "-rz", tree], cwd=root, env=env,
                             check=True, stdout=subprocess.PIPE).stdout
    for entry in entries.split(b"\0"):
        if not entry:
            continue
        metadata, raw_path = entry.split(b"\t", 1)
        mode, _, blob = metadata.split()
        if mode == b"120000":
            target = run(["git", "cat-file", "blob", blob.decode()], root, env, capture=True)
            path = root / os.fsdecode(raw_path)
            if Path(target).is_absolute() or not (path.parent / target).resolve().is_relative_to(root):
                raise SuiteError(f"outbound source symlink: {os.fsdecode(raw_path)}")
    parent: list[str] = []
    if base:
        base = run(["git", "rev-parse", "--verify", f"{base}^{{commit}}"], root, env, capture=True)
        parent = ["-p", base]
    commit_env = dict(env, GIT_AUTHOR_NAME="Weave gate", GIT_COMMITTER_NAME="Weave gate",
                      GIT_AUTHOR_EMAIL="gate@example.invalid", GIT_COMMITTER_EMAIL="gate@example.invalid")
    commit = run(["git", "-c", "commit.gpgsign=false", "commit-tree", tree, *parent,
                  "-m", "Frozen gate candidate"], root, commit_env, capture=True)
    run(["git", "checkout", "--quiet", "--detach", commit], root, env)


def private_path(value: str, root: Path, work: Path) -> Path:
    """Cwd and output paths stay within the snapshot, private prefix or cache."""
    path = root / substitute(value, root, work)
    resolved = path.resolve()
    if not any(resolved.is_relative_to(boundary) for boundary in (root, work / "env", work / "cache")):
        raise SuiteError(f"recipe path escapes private roots: {value}")
    return path


def captured_artifacts(root: Path, recipe: dict[str, Any]) -> list[dict[str, str]]:
    """A frozen resolution names exact distribution bytes, not version ranges."""
    if "resolution" not in recipe:
        return []
    document = declaration_fields(json.loads((root / recipe["resolution"]).read_bytes(),
                                             object_pairs_hook=declaration_object),
                                  {"version", "artifacts"}, "captured resolution")
    if (not isinstance(document.get("version"), int) or isinstance(document["version"], bool)
            or document["version"] != 1
            or not isinstance(document.get("artifacts"), list) or not document["artifacts"]):
        raise SuiteError("captured resolution requires version 1 and nonempty artifacts")
    seen = set()
    artifacts = []
    for value in document["artifacts"]:
        entry = string_map(declaration_fields(value, {"path", "sha256", "source"}, "artifact"), "artifact")
        name = relative_path(entry.get("path"), "artifact filename")
        sha = entry.get("sha256", "")
        if "/" in name or name in seen or len(sha) != 64 or any(char not in "0123456789abcdef" for char in sha):
            raise SuiteError("artifact requires a unique filename and lowercase SHA-256")
        seen.add(name)
        artifacts.append(entry)
    return artifacts


def verify_artifact(path: Path, sha: str) -> None:
    """Never accept a link, missing bytes or a declared hash without reading."""
    if path.is_symlink() or not path.is_file() or digest(path) != sha:
        raise SuiteError(f"artifact hash mismatch: {path.name}")


def publish_artifact(cache: Path, artifact: dict[str, str], recipe: dict[str, Any],
                     cwd: Path, work: Path, env: dict[str, str]) -> None:
    """Populate a single locked digest, publishing only complete verified bytes."""
    sha = artifact["sha256"]
    target = cache / sha
    if target.exists() or target.is_symlink():
        verify_artifact(target, sha)
        return
    if not recipe.get("fetch") or not artifact.get("source"):
        raise SuiteError(f"artifact cache miss without acquisition: {sha}")
    with tempfile.TemporaryDirectory(prefix="acquire-", dir=work) as temporary:
        acquired = Path(temporary) / "artifact"
        argv = [substitute(arg, cwd, work).replace("{artifact}", str(acquired))
                .replace("{source}", artifact["source"]) for arg in recipe["fetch"]]
        run(argv, cwd, env)
        verify_artifact(acquired, sha)
        with tempfile.NamedTemporaryFile(prefix=".incoming-", dir=cache, delete=False) as stream:
            pending = Path(stream.name)
            try:
                with acquired.open("rb") as source:
                    shutil.copyfileobj(source, stream)
                stream.flush()
                os.fsync(stream.fileno())
                verify_artifact(pending, sha)
                pending.chmod(0o444)
                os.replace(pending, target)
            finally:
                pending.unlink(missing_ok=True)


def stage_artifacts(cache: Path, artifacts: list[dict[str, str]], recipe: dict[str, Any],
                    root: Path, work: Path, env: dict[str, str]) -> dict[str, str]:
    """Share immutable artifacts under a per-digest lock, never writable prefixes."""
    if not artifacts:
        return {}
    cache.mkdir(parents=True, mode=0o700, exist_ok=True)
    metadata = cache.lstat()
    if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.geteuid() or metadata.st_mode & 0o022:
        raise SuiteError("artifact cache must be an owned directory without group/other writers")
    hashes = {}
    for artifact in artifacts:
        sha = artifact["sha256"]
        descriptor = os.open(cache / f".{sha}.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, "rb+") as lock:
            metadata = os.fstat(lock.fileno())
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid() or metadata.st_mode & 0o022:
                raise SuiteError("artifact cache lock must be an owned regular file without other writers")
            fcntl.flock(lock, fcntl.LOCK_EX)
            publish_artifact(cache, artifact, recipe, root, work, env)
            private = private_path("{cache}/" + artifact["path"], root, work)
            if not private.exists() and not private.is_symlink():
                shutil.copyfile(cache / sha, private)
                private.chmod(0o400)
            verify_artifact(private, sha)
        hashes[artifact["path"]] = sha
    return hashes


def _output_entries(path: Path) -> list[Path]:
    """Every entry under PATH, sorted, as rglob("*") yields them.

    rglob walked past a directory it could not list, so the fingerprint left
    out whatever that directory held and a change there went unseen
    (wv-c6c7cf); this raises SuiteError instead. Symlinked directories are
    yielded, not entered.
    """
    def unlisted(exc: OSError) -> None:
        raise SuiteError(f"cannot list installed output {exc.filename}: {exc.strerror or exc}") from exc
    found: list[Path] = []
    for dirpath, dirnames, filenames in os.walk(path, onerror=unlisted):
        found.extend(Path(dirpath) / name for name in dirnames + filenames)
    return sorted(found)


def output_digest(path: Path) -> str:
    """Fingerprint installed bytes, link targets and permissions before the suite."""
    entries = []
    paths = [path, *_output_entries(path)] if path.is_dir() else [path]
    for item in paths:
        mode = item.lstat().st_mode
        if stat.S_ISLNK(mode):
            value = os.readlink(item)
        elif stat.S_ISREG(mode):
            value = digest(item)
        elif stat.S_ISDIR(mode):
            value = ""
        else:
            raise SuiteError(f"installed output is not a regular file, directory or link: {item}")
        entries.append([str(item.relative_to(path)), mode, value])
    return hashlib.sha256(json.dumps(sorted(entries), separators=(",", ":")).encode()).hexdigest()


def provision(root: Path, work: Path, policy: dict[str, Any], env: dict[str, str],
              cache: Path) -> tuple[dict[str, str], list[dict[str, Any]]]:
    """Run protected argv and verify all frozen recipe inputs after each step."""
    entries = tree_entries(root, "HEAD", env)
    inputs = {name: digest(root / name) for name in sorted(recipe_inputs(policy, entries))}
    receipts = []
    all_artifacts: dict[str, str] = {}
    for recipe in policy["recipes"]:
        cwd = private_path(recipe.get("cwd", "."), root, work)
        outputs = recipe.get("outputs", [])
        for output in outputs:
            if private_path(output, root, work).exists():
                raise SuiteError(f"recipe output already exists before provisioning: {output}")
        recipe_env = dict(env, **{key: substitute(value, root, work) for key, value in recipe.get("env", {}).items()})
        artifacts = stage_artifacts(cache, captured_artifacts(root, recipe), recipe, root, work, recipe_env)
        all_artifacts.update(artifacts)
        commands = recipe["run"]
        for argv in [commands] if isinstance(commands[0], str) else commands:
            verify_provision_inputs(root, work, inputs, all_artifacts)
            run([substitute(value, root, work) for value in argv], cwd, recipe_env)
            verify_provision_inputs(root, work, inputs, all_artifacts)
        for output in outputs:
            if not private_path(output, root, work).exists():
                raise SuiteError(f"missing recipe output: {output}")
        if "resolution" in recipe:
            receipts.append({"resolution": {"path": recipe["resolution"], "sha256": inputs[recipe["resolution"]]},
                             "artifacts": artifacts, "outputs": outputs})
        for key, value in recipe.get("provides", {}).items():
            value = substitute(value, root, work)
            env[key] = value + os.pathsep + env["PATH"] if key == "PATH" else value
    for receipt in receipts:
        receipt["outputs"] = {value: output_digest(private_path(value, root, work)) for value in receipt["outputs"]}
    return inputs, receipts


def verify_provision_inputs(root: Path, work: Path, inputs: dict[str, str], artifacts: dict[str, str]) -> None:
    """Acquisition and installation cannot rewrite frozen inputs or private artifacts."""
    for name, original in inputs.items():
        if (not (root / name).is_file() or not (root / name).resolve().is_relative_to(root)
                or digest(root / name) != original):
            raise SuiteError(f"provisioning changed staged recipe input: {name}")
    for name, sha in artifacts.items():
        verify_artifact(work / "cache" / name, sha)


def execute(args: argparse.Namespace) -> int:
    """Prepare one execution boundary and return the suite's observable status."""
    repo = args.repo.resolve()
    if args.mode == "auto" or args.declarations:
        args.declaration = declaration_plan(repo, args.tree, args.base, dict(os.environ), args.policy)
    if args.declarations:
        print(json.dumps(args.declaration, sort_keys=True))
        return 0
    if args.work is None or args.provenance is None or not args.command:
        raise SuiteError("execution requires work, provenance and a suite")
    work = args.work.resolve()
    work.mkdir(exist_ok=False)
    mode, policy = selected_policy(args, args.command[0])
    if mode == "checkout" and not args.describe:
        if args.plan or (args.policy and args.mode != "auto"):
            raise SuiteError("checkout execution cannot use a frozen plan or provisioning policy")
        suite, *suite_args = args.command
        if Path(suite).is_absolute() or ".." in Path(suite).parts:
            raise SuiteError("suite must be a repository-relative path")
        identity = {"execution_mode": "checkout", "context": os.environ.get("WV_GATE_CONTEXT", "precommit"),
                    "tree": args.tree, "base": args.base, "suite": suite, "key": None}
        args.provenance.write_text(json.dumps(identity, sort_keys=True, indent=2) + "\n")
        print(f"Weave checkout: {suite}; mutable checkout inputs; reuse disabled", flush=True)
        return subprocess.run(["bash", str(repo / suite), *suite_args], cwd=repo, check=False).returncode
    env = private_environment(repo, work)
    if args.describe:
        args.provenance.write_text(json.dumps(describe(args, env, work), sort_keys=True, indent=2) + "\n")
        return 0
    return execute_frozen(args, policy, env, work)


def execute_frozen(args: argparse.Namespace, policy: dict[str, Any], env: dict[str, str], work: Path) -> int:
    """Verify the reuse plan, provision the snapshot and run its selected suite."""
    repo = args.repo.resolve()
    root = work / "tree"
    suite, *suite_args = args.command
    if Path(suite).is_absolute() or ".." in Path(suite).parts:
        raise SuiteError("suite must be a repository-relative path")
    key = None
    if args.plan:
        if suite_args:
            raise SuiteError("planned suite execution cannot change its arguments")
        expected = json.loads(args.plan.read_text())
        actual = describe(args, env, work)
        if any(expected[name] != actual[name] for name in ("tree", "base", "authority")) \
                or expected["suites"][suite] != actual["suites"][suite]:
            raise SuiteError("suite execution inputs differ from the frozen reuse plan")
        key = actual["suites"][suite]["key"]
    env = configured_environment(policy, env, root, work)
    tools = {name: tool_identity(name, env, work) for name in policy["tools"]}
    snapshot(repo, args.tree, args.base, root, env)
    if not policy["executor"] and not (root / suite).is_file():
        raise SuiteError(f"frozen tree does not contain selected suite {suite}")
    locks, receipts = provision(root, work, policy, env, args.artifact_cache)
    # Expose only protected command aliases, never an arbitrary source directory.
    commands = work / "bin"
    commands.mkdir()
    for name, source in policy["commands"].items():
        if (root / source).is_file():
            cli = commands / name
            cli.write_text(f'#!/bin/sh\nexec {shlex.quote(str(root / source))} "$@"\n')
            cli.chmod(0o755)
    env["PATH"] = str(commands) + os.pathsep + env["PATH"]
    env["WV_GATE_TREE"] = args.tree
    if args.base:
        env["WV_GATE_BASE"] = args.base
    else:
        env.pop("WV_GATE_BASE", None)
    identity = {"execution_mode": "frozen", "context": os.environ.get("WV_GATE_CONTEXT", "precommit"),
                "tree": args.tree, "base": args.base, "suite": suite,
                "arguments": suite_args, "policy": policy, "tools": tools,
                "lockfiles": locks, "provisioning": receipts, "backend_sha256": digest(Path(__file__)), "key": key}
    if args.mode == "auto":
        identity["declaration"] = args.declaration["declaration"]
    args.provenance.write_text(json.dumps(identity, sort_keys=True, indent=2) + "\n")
    print(f"Weave snapshot: {suite}; tree={args.tree}; base={args.base or 'unborn'}", flush=True)
    command = [substitute(value, root, work) for value in policy["executor"]] or ["bash", str(root / suite)]
    command += suite_args
    return subprocess.run(command, cwd=root, env=env, check=False).returncode


def main() -> int:
    """CLI used by protected gate workers and isolated regression controls."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--tree", required=True)
    parser.add_argument("--base")
    parser.add_argument("--authority")
    parser.add_argument("--mode", choices=("frozen", "checkout", "auto"), default="frozen")
    parser.add_argument("--declarations", action="store_true")
    parser.add_argument("--describe", action="store_true")
    parser.add_argument("--plan", type=Path)
    parser.add_argument("--policy", type=Path)
    parser.add_argument("--work", type=Path)
    parser.add_argument("--provenance", type=Path)
    parser.add_argument("--artifact-cache", type=Path,
                        default=Path(os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache"))) / "weave/artifacts")
    parser.add_argument("command", nargs="*")
    args = parser.parse_args()
    try:
        return execute(args)
    except (SuiteError, OSError, ValueError, KeyError, configparser.Error, subprocess.CalledProcessError) as error:
        print(f"Weave snapshot refused: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
