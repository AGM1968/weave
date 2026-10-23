"""The weave_gh mutant set still applies to the source (wv-e869e3).

tests/weave_gh_mutants.py runs out of band (make mutants-gh): it is slow, one
suite run per mutant. This checks only that every mutant's anchor matches its
file exactly once, so an edit that moves a guard leaves this red instead of
leaving the runner to fail later. It does not prove the mutants are killed;
run the runner for that.
"""

from __future__ import annotations

import importlib.util
from pathlib import Path
from types import ModuleType

ROOT = Path(__file__).resolve().parents[1]
RUNNER_PATH = ROOT / "tests" / "weave_gh_mutants.py"


def load_runner() -> ModuleType:
    spec = importlib.util.spec_from_file_location("weave_gh_mutants", RUNNER_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load the mutant runner at {RUNNER_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


RUNNER = load_runner()


def test_every_anchor_matches_once() -> None:
    assert RUNNER.mutant_set_problems() == []


def test_suite_excludes_this_file_and_covers_the_rest() -> None:
    names = {Path(p).name for p in RUNNER.SUITE}
    assert "test_weave_gh_mutant_set.py" not in names
    assert {"test_weave_gh_data.py", "test_weave_gh_main.py", "test_weave_gh_phases.py"} <= names
