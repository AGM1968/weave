"""Integration regressions for WvClient close semantics against the real wv CLI."""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

from runtime.wv_client import WvClient

_REPO_ROOT = Path(__file__).parent.parent
_WV_SCRIPT = str(_REPO_ROOT / "scripts" / "wv")
_OVERLAP_LEARNING = (
    "decision: runtime wv_done wrapper enforces finding schema in two stages — "
    "missing fields first, then type validation | pattern: confidence must be "
    "string enum high|medium|low; fixable must be boolean true|false — not floats "
    'or strings | pitfall: agents pass confidence=0.9 (float) or fixable="yes" '
    "and get rejected; error message is actionable and names the exact fields"
)


def _run_wv(args: list[str], *, cwd: Path, env: dict[str, str]) -> str:
    result = subprocess.run(
        [_WV_SCRIPT, *args],
        cwd=cwd,
        env=env,
        text=True,
        capture_output=True,
        check=True,
    )
    return result.stdout.strip()


def test_wv_done_succeeds_when_overlap_is_advisory_for_findings(tmp_path: Path) -> None:
    env = {
        **os.environ,
        "WV_HOT_ZONE": str(tmp_path),
        "WV_DB": str(tmp_path / "brain.db"),
        "WV_REQUIRE_LEARNING": "1",
        "WV_NONINTERACTIVE": "1",
    }
    subprocess.run(["git", "init", "-q"], cwd=tmp_path, check=True, capture_output=True)
    _run_wv(["init"], cwd=tmp_path, env=env)

    seed_id = _run_wv(["add", "Seed overlap learning"], cwd=tmp_path, env=env).splitlines()[-1]
    _run_wv(["done", seed_id, f"--learning={_OVERLAP_LEARNING}"], cwd=tmp_path, env=env)

    metadata = (
        '{"type":"finding","verification":{"method":"test","result":"pass"},'
        '"finding":{"violation_type":"schema_enforcement_test",'
        '"root_cause":"runtime wv_done wrapper validates finding metadata types and '
        'presence before allowing close",'
        '"proposed_fix":"agents must set confidence as one of high|medium|low '
        '(string) and fixable as boolean before closing a finding node",'
        '"confidence":"high","fixable":true}}'
    )
    finding_id = _run_wv(
        ["add", "Finding overlap advisory", f"--metadata={metadata}"],
        cwd=tmp_path,
        env=env,
    ).splitlines()[-1]

    client = WvClient(wv_bin=_WV_SCRIPT, env=env, cwd=tmp_path)
    result = client.done(finding_id, learning=_OVERLAP_LEARNING)

    assert result["status"] == "done"
    shown = client.show(finding_id)
    assert shown["status"] == "done"
    assert "learning_overlap_noted" in str(shown.get("metadata", ""))
