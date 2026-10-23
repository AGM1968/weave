#!/usr/bin/env python3
"""Mutation check for the weave_gh integrity guards (wv-e869e3, wv-80be32).

Each mutant disables one guard from wv-0d2d25, wv-820b76, wv-1d88c3,
wv-e869e3 or wv-80be32 (the hot-zone base check). The runner copies scripts/weave_gh to a temporary directory,
applies the mutant there (its anchor must match exactly once), and runs the
weave_gh pytest suite against the copy. The working tree is never modified.

A mutant is killed when the suite fails. Before the mutants run, the runner
checks that the unmutated copy passes and that a copy whose package import
fails makes the suite fail, which proves the suite imports the copy rather
than scripts/weave_gh.

Exit status: 0 when every mutant is killed, 1 otherwise.

    python3 tests/weave_gh_mutants.py [MUTANT_ID ...]
    make mutants-gh

The shell suite tests/test-durability.sh is not run per mutant. Its
real-weave_gh cases pin the exit-status contract with _sync_gh, which
EXIT_INTEGRITY=1 (G01) would break; the pytest suite catches G01 through
test_exit_codes_are_distinct.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "scripts" / "weave_gh"
# The mutant-set check reads scripts/weave_gh, not the copy, so it is left out.
SUITE = sorted(
    str(p.relative_to(ROOT))
    for p in (ROOT / "tests").glob("test_weave_gh_*.py")
    if p.name != "test_weave_gh_mutant_set.py"
)

# (id, file in scripts/weave_gh, anchor, replacement, guard it disables)
MUTANTS: list[tuple[str, str, str, str, str]] = [
    ("G01", "__main__.py", "EXIT_INTEGRITY = 3", "EXIT_INTEGRITY = 1",
     "integrity refusals share the transport exit status"),
    ("G02", "__main__.py", "        sys.exit(EXIT_INTERNAL)", "        raise",
     "an unexpected exception exits 1, read as a pending network step"),
    ("G03", "__main__.py", "    except (subprocess.CalledProcessError, OSError):\n        raise",
     "    except ():\n        raise",
     "a failed gh command exits EXIT_INTERNAL instead of 1"),
    ("G04", "__main__.py", "        confirm_mapped_issues_absent(repo, nodes, issues)\n",
     "        pass\n",
     "omitted mapped issues are not looked up before writes"),
    ("G05", "data.py", "    if distinct < max(total, total_after):",
     "    if distinct < total:", "the count after listing is ignored"),
    ("G06", "data.py", "    if distinct != len(issues):", "    if False:",
     "repeated issue numbers are accepted"),
    ("G07", "data.py", "    if len(issues) >= limit:", "    if len(issues) > limit:",
     "a listing that fills the limit is accepted"),
    ("G08", "data.py", "    if count < 0:", "    if count < -1:",
     "a count of -1 is accepted"),
    ("G09", "data.py", "    if number < 1:", "    if number < 0:",
     "issue number 0 is accepted"),
    ("G10", "data.py", "            issues.append(_parse_issue_row(row))",
     "            issues.append(GitHubIssue(row['number'], '', row['state']))",
     "issue rows are not schema-checked"),
    ("G11", "data.py", "    if state not in _ISSUE_STATES:", "    if False:",
     "unknown issue states are accepted"),
    ("G12", "data.py", "    if not NODE_ID_RE.fullmatch(node_id):",
     "    if not NODE_ID_RE.search(node_id):",
     "node ids need only contain the pattern"),
    ("G13", "data.py", "    if status not in NODE_STATUSES:", "    if False:",
     "unknown node statuses are accepted"),
    ("G14", "data.py", '        gh_issue = parse_gh_issue(meta.get("gh_issue"))',
     "        gh_issue = None", "metadata.gh_issue is not checked"),
    ("G15", "data.py", "    if len(set(ids)) != len(ids):", "    if False:",
     "repeated node ids are accepted"),
    ("G16", "data.py", "            raise ValueError(f\"metadata of {node_id} is not JSON: {e}\") from e",
     "            meta = {}", "unparseable metadata reads as {}"),
    ("G17", "data.py", "    for number in missing:", "    for number in []:",
     "omitted mapped issues are never looked up"),
    ("G18", "data.py", "            if _NOT_FOUND in result.stderr.lower():", "            if True:",
     "any failed lookup reads as not found"),
    ("G19", "data.py", '.endswith(f"/{repo.lower()}/issues/{number}")', '.endswith(f"/{number}")',
     "a pull request or transferred issue reads as present"),
    ("G20", "data.py", "    except (subprocess.CalledProcessError, OSError) as e:\n"
     "        raise NodeFetchError(f\"wv list failed: {e}\") from e",
     "    except (subprocess.CalledProcessError, OSError) as e:\n        raw = '[]'\n"
     "        data = []",
     "a failed wv list reads as an empty graph"),
    ("G21", "models.py", "    if isinstance(value, bool):", "    if False:",
     "gh_issue true reads as issue #1"),
    ("G22", "models.py", "        if value < 1:", "        if value < 0:",
     "gh_issue 0 is accepted"),
    ("G23", "models.py", '_GH_ISSUE_STR_RE = re.compile(r"[1-9][0-9]*")',
     '_GH_ISSUE_STR_RE = re.compile(r"[0-9]+")', "gh_issue '07' is accepted"),
    ("G24", "phases.py", "    if not NODE_ID_RE.fullmatch(node.id):", "    if False:",
     "a malformed id reaches the backfill SQL"),
    ("G25", "phases.py", "    if node.status not in NODE_STATUSES:",
     '    if node.status not in ("todo", "active", "done", "blocked"):',
     "blocked-external nodes get no issue"),
    ("G26", "phases.py", 'n.status == "done" and n.gh_issue in open_issues',
     'n.status == "done" and False',
     "fast sync drops done nodes whose issue is open"),
    ("G27", "labels.py", '    "blocked-external": ("weave:blocked", "d93f0b"),\n', "",
     "blocked-external nodes get no status label"),
    ("G28", "data.py", "    if st.st_mode & 0o022:", "    if False:",
     "a group- or other-writable hot-zone base is used"),
    ("G29", "data.py",
     "    if st.st_uid != uid:\n        return f\"is owned by",
     "    if False:\n        return f\"is owned by",
     "another uid's hot-zone base is used"),
    ("G30", "data.py", "        if alias_target is None:\n            return \"is a symlink\"",
     "        if False:\n            return \"is a symlink\"", "a symlinked hot-zone base is followed"),
    ("G31", "data.py", "    if target != alias_target:", "    if False:",
     "an alias to any target is accepted"),
    ("G32", "data.py", "    _check_hot_zone(db, uid)\n", "",
     "_resolve_db_path skips the base check"),
    # The check returns the graph path the sync lock sits beside (wv-0ae4cb).
    ("G33", "__main__.py", "    db_path = _check_hot_zone()\n",
     "    db_path = \"brain.db\"\n", "weave_gh writes before checking the hot-zone base"),
]


def mutant_set_problems() -> list[str]:
    """Return why the mutant set is unusable: an anchor that does not match
    exactly once, a no-op replacement, or a repeated id."""
    problems = []
    ids = [m[0] for m in MUTANTS]
    if len(set(ids)) != len(ids):
        problems.append("repeated mutant id")
    for mutant_id, name, anchor, replacement, _ in MUTANTS:
        text = (PACKAGE / name).read_text(encoding="utf-8")
        if text.count(anchor) != 1:
            problems.append(f"{mutant_id}: anchor matches {text.count(anchor)} times in {name}")
        if anchor == replacement:
            problems.append(f"{mutant_id}: replacement equals anchor")
    return problems


def run_suite(copy_root: Path) -> tuple[int, str]:
    """Run the weave_gh suite with copy_root first on sys.path; return its
    exit status and the first failing test, so a kill can be checked."""
    cmd = [
        sys.executable, "-m", "pytest", "-q", "-x", "-p", "no:cacheprovider",
        "-o", f"pythonpath={copy_root} scripts .", *SUITE,
    ]
    result = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, check=False)
    failed = next(
        (line.split(" - ")[0] for line in result.stdout.splitlines()
         if line.startswith(("FAILED tests/", "ERROR tests/"))),
        "",
    )
    return result.returncode, failed


def with_copy(edit: tuple[str, str, str] | None) -> tuple[int, str]:
    """Copy the package, apply ``edit`` (file, anchor, replacement), run the suite."""
    with tempfile.TemporaryDirectory(prefix="weave-gh-mutant-") as tmp:
        copy = Path(tmp) / "weave_gh"
        shutil.copytree(PACKAGE, copy, ignore=shutil.ignore_patterns("__pycache__"))
        if edit is not None:
            name, anchor, replacement = edit
            path = copy / name
            text = path.read_text(encoding="utf-8")
            assert text.count(anchor) == 1, (name, anchor)
            path.write_text(text.replace(anchor, replacement), encoding="utf-8")
        return run_suite(Path(tmp))


def main(argv: list[str]) -> int:
    problems = mutant_set_problems()
    if problems:
        print("mutant set is stale:\n  " + "\n  ".join(problems))
        return 1
    selected = [m for m in MUTANTS if not argv or m[0] in argv]
    if argv and len(selected) != len(set(argv)):
        print(f"unknown mutant id in {argv}")
        return 1

    if with_copy(None)[0] != 0:
        print("baseline: the unmutated copy fails the suite")
        return 1
    future = "from __future__ import annotations\n"
    if with_copy(("__init__.py", future, future + 'raise ImportError("canary")\n'))[0] == 0:
        print("baseline: a broken copy passes, so the suite is not importing the copy")
        return 1
    print(f"baseline: copy passes, broken copy fails ({len(SUITE)} suite files)")

    survived = []
    for mutant_id, name, anchor, replacement, guard in selected:
        code, failed = with_copy((name, anchor, replacement))
        killed = code != 0
        print(f"{mutant_id} {'killed  ' if killed else 'SURVIVED'} {name}: {guard}")
        if failed:
            print(f"    first failure: {failed}")
        if not killed:
            survived.append(mutant_id)
    print(f"{len(selected) - len(survived)}/{len(selected)} killed")
    return 1 if survived else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
