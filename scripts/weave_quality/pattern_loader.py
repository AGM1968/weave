"""Which pattern rules are active, and where they came from.

Extracted from `__main__` so the evidence adapter can ask the same question the
CLI asks without importing the CLI. `coaching_evidence` needs exactly this
definition -- re-deriving it would let the adapter and the scan that produced
the receipts disagree about the rule set they are discussing -- but importing
`__main__` to get it formed a cycle that both sides had to paper over with
function-local imports.

The rule set is therefore owned here, by a module that depends only on
`prose_rules`, and both callers import it from one place.
"""

from __future__ import annotations

import configparser
import sys
from pathlib import Path

from .listing import directory_entries
from .prose_rules import PatternRuleValidationError, validate_pattern_rule

_DEFAULT_PATTERNS_DIR = Path(__file__).parent / "default_patterns"


def _disabled_patterns(conf_path: Path) -> set[str]:
    """Read [patterns] disabled = ... from quality.conf."""
    disabled: set[str] = set()
    if not conf_path.exists():
        return disabled
    cp = configparser.ConfigParser(inline_comment_prefixes=("#",), allow_no_value=True)
    cp.read(str(conf_path))
    raw = cp.get("patterns", "disabled", fallback="")
    for item in raw.replace(",", " ").split():
        if item.strip():
            disabled.add(item.strip())
    return disabled


def _load_pattern_rules(
    repo: Path, conf_disabled: set[str]
) -> list[tuple[str, Path, str]]:
    """Return [(rule_id, rule_path, language)] for all active pattern rules.

    Loads from:
      1. _DEFAULT_PATTERNS_DIR (built-in curated rules)
      2. <repo>/.weave/patterns/managed/*.yaml (projected by wv init-repo)
      3. <repo>/.weave/patterns/*.yaml (user-defined rules)
    Rules whose id appears in conf_disabled are skipped.

    language is captured here from validate_pattern_rule's own return value
    (it already reads and parses the file to validate it) instead of being
    re-derived later by a separate rule_language(rule_path) call. A second,
    unguarded read raced a rule file that vanished or became unreadable
    between validation and classification: rule_language() swallows OSError
    into "", which silently misclassified an already-validated prose rule as
    a code rule -- one that could then be dropped from `rules` entirely
    before ever reaching the per-rule execution boundary that would
    otherwise record a failed receipt (see wv-dc2e44).
    """
    rules: list[tuple[str, Path, str]] = []
    patterns_dir = repo / ".weave" / "patterns"
    seen: dict[str, Path] = {}
    for rule_dir in (
        _DEFAULT_PATTERNS_DIR,
        patterns_dir / "managed",
        patterns_dir,
    ):
        # A tier that is there but cannot be listed is an error, not an empty
        # tier: glob read it as holding no rules, so every rule in it stopped
        # running while scan, list and validate exited 0 (wv-4852bd). A tier
        # that is not there has no rules, as before.
        try:
            strays = directory_entries(rule_dir, "*.yml")
            rule_files = directory_entries(rule_dir, "*.yaml")
        except OSError as exc:
            raise PatternRuleValidationError(
                f"{rule_dir}: rule directory cannot be listed "
                f"({exc.strerror or exc}); its rules would not run"
            ) from None
        # A rule file the loader will not read must SAY SO. Only *.yaml is
        # loaded, so a perfectly valid rule saved as .yml never ran and scan,
        # list and validate all stayed silent with exit 0 -- the author had no
        # way to learn their rule was inert. Reported rather than loaded:
        # silently activating files that were never executing would change gate
        # outcomes in existing repos without anyone asking for it.
        for stray in strays:
            print(
                f"patterns: ignoring {stray}: rule files must use the .yaml "
                f"extension; rename it to {stray.with_suffix('.yaml').name} "
                "for it to be loaded",
                file=sys.stderr,
            )
        for yf in rule_files:
            rule_id = yf.stem
            language = validate_pattern_rule(yf, rule_id)
            if rule_id in conf_disabled:
                continue
            if rule_id in seen:
                # Finding N: this used to raise, which aborted the whole load
                # and took every rule down with it -- a repo attempting a local
                # override lost all of its register gates at once until it
                # worked out that its own patch was the cause. Degrade instead:
                # keep the earlier tier's rule (defaults and managed are the
                # shared, curated ones) and skip the colliding file.
                #
                # Deliberately NOT last-tier-wins. Silently swapping a shared
                # rule's definition is the trap one consumer's register hit, where
                # a local copy shadowed a managed rule and was never applied.
                # `patterns validate` still reports the collision as invalid,
                # so the loader degrading and the linter being strict agree
                # that the file is unusable -- they just differ on blast radius.
                print(
                    f"patterns: ignoring {yf}: duplicate pattern id {rule_id!r} "
                    f"already defined by {seen[rule_id]}; "
                    "rename the rule or remove one copy "
                    "(run 'wv quality patterns validate' to list every collision)",
                    file=sys.stderr,
                )
                continue
            seen[rule_id] = yf
            rules.append((rule_id, yf, language))
    return rules
