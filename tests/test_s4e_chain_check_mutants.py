"""The S4e checker's mutant record is fresh and consistent (wv-29868f, wv-f28b58).

docs/e5-capture/s4e_chain_check_mutants.py runs out of band and writes
s4e_chain_check_mutants.json. This does not re-run it: it checks that the
record is well formed, that its verdict is pass, and that every digest in it is
the digest of the bytes on disk now, re-hashed here rather than trusted. A
change to the checker, its suite, the run sheet or the mutant set leaves this
red until the runner is run again.

It does not prove the runner produced the outcomes: a hand-edited record with
matching counts passes. The outcomes are reproducible, not attested; re-run the
runner to check them.
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
from types import ModuleType

import pytest

ROOT = Path(__file__).resolve().parents[1]
RUNNER_PATH = ROOT / "docs" / "e5-capture" / "s4e_chain_check_mutants.py"


def load_runner() -> ModuleType:
    spec = importlib.util.spec_from_file_location("s4e_chain_check_mutants", RUNNER_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load the mutant runner at {RUNNER_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


RUNNER = load_runner()
RECORD = json.loads((ROOT / RUNNER.RECORD).read_text(encoding="utf-8"))


def test_record_is_well_formed() -> None:
    assert RECORD["format"] == RUNNER.FORMAT
    for key in ("tool", "subject", "suite", "run_sheet", "baseline", "mutant_set", "counts", "verdict", "mutants"):
        assert key in RECORD, key
    assert set(RECORD["counts"]) == {"killed", "survived", "timeout", "incompetent"}
    assert sum(RECORD["counts"].values()) == RECORD["mutant_set"]["count"] == len(RECORD["mutants"])
    for outcome, count in RECORD["counts"].items():
        assert count == sum(1 for mutant in RECORD["mutants"] if mutant["outcome"] == outcome), outcome


def test_record_verdict_is_pass() -> None:
    # Kept apart from well-formedness: a well-formed record of a failing or
    # inconclusive run must not read as a passing one.
    assert RECORD["baseline"]["exit"] == 0
    assert RECORD["verdict"] == "pass"
    assert RECORD["counts"]["survived"] == 0 and RECORD["counts"]["incompetent"] == 0
    assert all(mutant["outcome"] in {"killed", "timeout"} for mutant in RECORD["mutants"])


@pytest.mark.parametrize("role", ["subject", "suite", "run_sheet"])
def test_record_describes_the_bytes_on_disk(role: str) -> None:
    data = (ROOT / RECORD[role]["path"]).read_bytes()
    assert RECORD[role]["sha256"] == RUNNER.sha256(data), f"re-run {RUNNER.RUNNER}: {RECORD[role]['path']} changed"
    assert RECORD[role]["git_blob"] == RUNNER.git_blob(data)


def test_record_was_made_by_this_runner_and_mutant_set() -> None:
    assert RECORD["tool"]["runner"]["sha256"] == RUNNER.sha256(RUNNER_PATH.read_bytes())
    assert RECORD["mutant_set"]["sha256"] == RUNNER.mutant_set_identity()
    assert [mutant["id"] for mutant in RECORD["mutants"]] == [mutant[0] for mutant in RUNNER.MUTANTS]


def test_git_blob_is_git_hash_object() -> None:
    assert RUNNER.git_blob(b"") == "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391"
    assert hashlib.sha256(b"").hexdigest() in RUNNER.sha256(b"")
