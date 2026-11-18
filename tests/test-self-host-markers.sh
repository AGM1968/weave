#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# test-self-host-markers.sh — the retired boolean "Weave's own tree" is two
# derived capabilities, each kept as inline copies; this suite fails when any
# copy drifts (wv-225efc). Both read the immutable base or HEAD tree only,
# never the working tree, index, remote or repository ownership class
# (wv-repository-class.sh, which governs scaffolding writes, not the gate).
#
#   lane  — committed gate source: does the base carry a gate that can run itself? It needs
#           the hook being run AND scripts/wv at the base (wv-9da519). Read by
#           pre-commit-weave.sh and pre-push-weave.sh (each names its own hook),
#           by wv-gate-suite.py SELF_HOST_MARKERS for the frozen default, which
#           follows the pre-commit lane (wv-981f92), and named by the
#           wv-gate-pool.sh mode reason.
#   hint  — source installer available: may a message name ./install.sh? It needs
#           install.sh AND scripts/wv at HEAD (wv-376de3). Read by both hooks,
#           prepare-commit-msg-weave.sh and wv-pre-tool-use.sh.
# A fork tracking the hook and scripts/wv without install.sh takes the lane and
# is told to refresh with wv; the answers diverge exactly there. Each copy is
# inline because the lane is chosen before any library loads, and the hints
# are the messages printed when libraries are missing.
#
# Working-tree probes (install.sh's generated wrapper, wv self-update's source
# lookup, wv-config.sh, build-release.sh) ask a third question, whether a
# directory on disk is a source checkout, and are not covered here.
#
# Exit codes: 0 all checks pass, 1 otherwise.

set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)

ROOT="${WV_SELF_HOST_MARKERS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

python3 -I - "$ROOT" <<'PY'
import ast
import re
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1])
failed = 0
passed = 0


def check(name, got, want):
    global failed, passed
    if got == want:
        passed += 1
        print(f"  \u2713 {name}")
    else:
        failed += 1
        print(f"  \u2717 {name}\n      expected {sorted(want) if isinstance(want, set) else want}"
              f"\n      got      {sorted(got) if isinstance(got, set) else got}")


def text(rel):
    return (root / rel).read_text(encoding="utf-8")


def code_lines(rel):
    """Non-comment lines of a shell file, with their numbers."""
    for n, line in enumerate(text(rel).splitlines(), 1):
        if not line.lstrip().startswith("#"):
            yield n, line


LS_TREE = re.compile(r'ls-tree (?:"\$_wv_base"|HEAD) -- ((?:[\w./-]+ ?)+?) 2>')
HINT = {"install.sh", "scripts/wv"}
HOOKS = {"pre-commit-weave": "scripts/hooks/pre-commit-weave.sh",
         "pre-push-weave": "scripts/hooks/pre-push-weave.sh"}

print("=== lane: the hook being run and scripts/wv ===")
for hook, rel in HOOKS.items():
    want = {rel, "scripts/wv"}
    lanes = [set(m.group(1).split()) for _, l in code_lines(rel)
             if "$_wv_base" in l and (m := LS_TREE.search(l))]
    check(f"{hook}: one lane test, reading its own hook and scripts/wv", lanes, [want])
    counts = []
    for _, l in code_lines(rel):
        m = re.search(r"grep -cE \$'\\t\((.*?)\)\$'", l)
        if m:
            counts.append({p.replace("\\\\.", ".") for p in m.group(1).split("|")})
    check(f"{hook}: the entry count matches the same two paths", counts, [want])
    # Enforcement read fails closed: an unreadable base refuses, never consumer mode.
    body = text(rel)
    m = re.search(r'! _wv_self=\$\(git ls-tree "\$_wv_base" -- [^\n]*\n[^\n]*could not read HEAD\'s tree[^\n]*\n\s*exit 1', body)
    check(f"{hook}: an unreadable base refuses", bool(m), True)

tree = ast.parse(text("scripts/lib/wv-gate-suite.py"))
markers = None
for node in ast.walk(tree):
    if isinstance(node, ast.Assign) and any(getattr(t, "id", "") == "SELF_HOST_MARKERS" for t in node.targets):
        markers = set(ast.literal_eval(node.value.args[0]))
check("wv-gate-suite.py SELF_HOST_MARKERS is the pre-commit lane's pair",
      markers, {HOOKS["pre-commit-weave"], "scripts/wv"})
m = re.search(r"legacy self-host: [^\"]*carries (\S+) and (\S+)\"", text("scripts/lib/wv-gate-pool.sh"))
check("wv-gate-pool.sh names the same pair when it explains a frozen default",
      set(m.groups()) if m else None, {HOOKS["pre-commit-weave"], "scripts/wv"})

print("=== hint: install.sh and scripts/wv ===")
HINT_SITES = ["scripts/hooks/pre-commit-weave.sh", "scripts/hooks/pre-push-weave.sh",
              "scripts/hooks/prepare-commit-msg-weave.sh", "scripts/lib/wv-pre-tool-use.sh"]
for rel in HINT_SITES:
    hints = [set(m.group(1).split()) for _, l in code_lines(rel)
             if "./install.sh" in l or "install.sh scripts/wv" in l
             if (m := LS_TREE.search(l)) and "$_wv_base" not in l]
    check(f"{Path(rel).name}: one ./install.sh hint, testing install.sh and scripts/wv", hints, [HINT])
    # Remediation read is non-authoritative: a failed read counts 0 entries and
    # names the consumer-safe refresh, never ./install.sh.
    safe = [l for _, l in code_lines(rel) if "install.sh scripts/wv 2>/dev/null | wc -l)\" -eq 2" in l]
    check(f"{Path(rel).name}: a failed read falls back to the wv refresh", len(safe), 1)

print("=== inventory: no unclassified site ===")
listed = subprocess.run(["git", "-C", str(root), "ls-files", "scripts", ".claude/hooks", "install.sh"],
                        capture_output=True, text=True, check=True).stdout.split()
found = set()
for rel in listed:
    p = root / rel
    if not p.is_file() or p.suffix not in ("", ".sh"):
        continue
    try:
        body = p.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        continue
    for n, line in enumerate(body.splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        if re.search(r"git (?:-C \S+ )?ls-tree [^|]*-- [^|]*scripts/wv\b", line):
            found.add(rel)
check("HEAD-tree tests naming scripts/wv live only at the classified sites", found,
      set(HOOKS.values()) | set(HINT_SITES))
py_sites = set()
for rel in listed:
    if rel.endswith(".py") and "SELF_HOST" in (root / rel).read_text(encoding="utf-8", errors="replace"):
        py_sites.add(rel)
check("SELF_HOST_MARKERS is defined in one Python module", py_sites, {"scripts/lib/wv-gate-suite.py"})

print(f"\nResults: {passed}/{passed + failed} passed")
sys.exit(1 if failed else 0)
PY
