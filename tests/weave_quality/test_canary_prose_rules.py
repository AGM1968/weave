"""Upstream known-answer canary from earth-engine-analysis audit wv-7a8d45."""

# pylint: disable=missing-class-docstring,missing-function-docstring

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import pytest

from weave_quality.prose_rules import run_prose_rule

ROOT = Path(__file__).parents[2]
DEFAULT = ROOT / "scripts" / "weave_quality" / "default_patterns"
MANAGED = ROOT / "templates" / "quality-patterns" / "managed"


@dataclass(frozen=True)
class Canary:
    ref: str
    rule_id: str
    source: str
    fires: bool


CANARIES = (
    # PR-1: the zero-precision motif stays retired; a narrow reassurance rule
    # covers its true positive without matching the audited technical sense.
    Canary(
        "PR-1a",
        "prose-verification-reassurance",
        "One independent closure dimension. " * 3,
        False,
    ),
    Canary(
        "PR-1b",
        "prose-verification-reassurance",
        "The result was measured carefully. It was measured again. "
        "A final measured result followed.\n",
        True,
    ),
    Canary(
        "PR-1c",
        "prose-verification-reassurance",
        "The rate was measured at 5/min. " * 3,
        False,
    ),
    Canary(
        "PR-4a",
        "prose-significance-heading",
        "## 2.3 The inconsistency, and why it matters\n",
        True,
    ),
    Canary(
        "PR-4b",
        "prose-rhetorical-heading",
        "## 4. Why each sensor senses what it does\n",
        True,
    ),
    Canary(
        "PR-5a",
        "test-contrastive-negation",
        "The pass counted the `X, not Y` construction.\n",
        False,
    ),
    Canary(
        "PR-5b",
        "test-contrastive-negation",
        "Density is primary, not ancillary.\n",
        True,
    ),
    Canary(
        "PR-5c",
        "prose-emphasis-hedge",
        "The pass removed every `actually` from the body.\n",
        False,
    ),
    Canary(
        "PR-5d",
        "test-contrastive-negation",
        "Counted like this:\n\n```text\nresult, not expected\n```\n",
        False,
    ),
    Canary(
        "PR-5e",
        "test-contrastive-negation",
        "| Case | Result |\n|:--|:--|\n| `X, not Y` | silent |\n",
        False,
    ),
    Canary(
        "PR-5f",
        "test-contrastive-negation",
        "## The `X, not Y` construction\n",
        False,
    ),
    Canary(
        "PR-5g",
        "test-contrastive-negation",
        "- the `X, not Y` construction was counted\n",
        False,
    ),
    Canary(
        "PR-5h",
        "test-contrastive-negation",
        "> the `X, not Y` construction was counted\n",
        False,
    ),
    Canary(
        "QP-1a",
        "test-contrastive-negation",
        "The target is the mean, not the sample.\n",
        True,
    ),
    Canary(
        "QP-2a",
        "prose-register-review",
        "The surface is bright, so the index over-reads.\n",
        True,
    ),
    Canary(
        "QP-2b",
        "prose-em-dash-density",
        "One—two—three—four linked asides.\n",
        True,
    ),
    Canary(
        "QP-2c",
        "prose-em-dash-density",
        "One—two—three linked clauses.\n",
        False,
    ),
    Canary(
        "CI-1a",
        "markdown-citation-integrity",
        "Follows (Yue et al., 2019).\n\n## Sources\nYue, J. et al. (2019). Soil moisture.\n",
        False,
    ),
    Canary(
        "CI-1b",
        "markdown-citation-integrity",
        "Follows (Yue et al., 2019).\n\n## Bibliography\nYue, J. et al. (2019). Soil moisture.\n",
        False,
    ),
    Canary(
        "CI-1c",
        "markdown-citation-integrity",
        "Follows (Yue et al., 2019).\n\n## References\nYue, J. et al. (2019). Soil moisture.\n",
        False,
    ),
    Canary(
        "CI-2a",
        "markdown-citation-integrity",
        "Reported in (D1.2, 2024) and (P29, 2026).\n\n## References\n",
        False,
    ),
    Canary(
        "CI-3a",
        "markdown-citation-integrity",
        "Tracked as (wv-e321fd, 2026) in the graph.\n\n## References\n",
        False,
    ),
    Canary(
        "AC-1a",
        "prose-rhetorical-heading",
        "## 4. What each sensor senses\n",
        True,
    ),
    Canary(
        "AC-1b",
        "prose-rhetorical-heading",
        "## 5.1.2 Which depth is the optical target\n",
        True,
    ),
    Canary(
        "AC-2a",
        "prose-significance-heading",
        "## 2. The conversion, and where its error comes from\n",
        True,
    ),
    Canary(
        "AC-3a",
        "prose-work-context-leakage",
        "Copy from this chat into a file.\n\nAnything you want adjusted?\n",
        True,
    ),
    Canary(
        "AC-4a",
        "markdown-citation-integrity",
        "Result (Nkobane, 2014).\n\n## References\nNkobane, M. (2015). Study.\n",
        True,
    ),
    Canary(
        "AC-4b",
        "markdown-citation-integrity",
        "Result (MacRobert, 2013).\n\n## References\n"
        "MacRobert, C. and Blight, G. A field study.\n",
        True,
    ),
    Canary(
        "AC-5a",
        "markdown-bare-url",
        "Source: https://doi.org/10.1016/j.isprsjprs.2019.06.012\n",
        True,
    ),
)


def _test_rule(tmp_path: Path) -> Path:
    rule = tmp_path / "test-contrastive-negation.yaml"
    rule.write_text(
        "id: test-contrastive-negation\n"
        "language: prose\n"
        "kind: regex\n"
        "match_scope: paragraph\n"
        "patterns:\n"
        "  - ',\\s+not\\b'\n",
        encoding="utf-8",
    )
    return rule


def _rule_path(rule_id: str, tmp_path: Path) -> Path:
    if rule_id == "test-contrastive-negation":
        return _test_rule(tmp_path)
    for directory in (DEFAULT, MANAGED):
        candidate = directory / f"{rule_id}.yaml"
        if candidate.exists():
            return candidate
    raise AssertionError(f"canary rule is not shipped: {rule_id}")


def test_canary_fixture_count_is_auditable() -> None:
    assert len(CANARIES) == 29
    assert len({canary.ref for canary in CANARIES}) == 29


@pytest.mark.parametrize("canary", CANARIES, ids=lambda canary: canary.ref)
def test_rc4_known_answer_canary(canary: Canary, tmp_path: Path) -> None:
    document = tmp_path / f"{canary.ref}.md"
    document.write_text(canary.source, encoding="utf-8")
    assert not (DEFAULT / "prose-number-free-verification.yaml").exists()

    rule_path = _rule_path(canary.rule_id, tmp_path)
    findings = run_prose_rule(canary.rule_id, rule_path, document, scan_id=1, repo=ROOT)
    assert bool(findings) is canary.fires
