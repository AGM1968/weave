"""File path classification for quality scanning.

Classifies files into four categories:
  - production: main application code (default)
  - test: test files and directories
  - script: build scripts, configuration, tooling
  - generated: generated/compiled output files

Category priority order: generated > test > script > production.

Supports per-project overrides via .weave/quality.conf [classify] section:

  [classify]
  test = tests/,custom_tests/
  script = deploy/,infra/
  generated = auto_gen/
"""

from __future__ import annotations

import re
from pathlib import Path


# ---------------------------------------------------------------------------
# Built-in classification patterns
# ---------------------------------------------------------------------------


def _segment_pattern(segment: str) -> re.Pattern[str]:
    """Compile a regex matching `segment` as a path component.

    Matches the literal segment preceded by start-of-string or a slash,
    and followed by a slash or end-of-string.  This prevents partial
    matches (e.g. "dist" must not match "distributed/").
    """
    escaped = re.escape(segment.rstrip("/"))
    return re.compile(r"(?:^|/)" + escaped + r"(?:/|$)")


# Pre-compiled patterns for built-in rules.
# Priority order applied by classify_file(): generated > test > script.

_GENERATED_PATTERNS: list[re.Pattern[str]] = [
    _segment_pattern("dist"),
    _segment_pattern("build"),
    _segment_pattern("generated"),
    re.compile(r"\.pb2\.py$"),
    re.compile(r"_pb2\.py$"),
]

_TEST_PATTERNS: list[re.Pattern[str]] = [
    _segment_pattern("test"),
    _segment_pattern("tests"),
    re.compile(r"(?:^|/)test_[^/]+\.py$"),
    re.compile(r"(?:^|/)[^/]+_test\.py$"),
]

_SCRIPT_PATTERNS: list[re.Pattern[str]] = [
    _segment_pattern("scripts"),
    re.compile(r"(?:^|/)Makefile$"),
    re.compile(r"\.sh$"),
    re.compile(r"\.toml$"),
    re.compile(r"\.cfg$"),
    re.compile(r"\.ini$"),
    re.compile(r"(?:^|/)setup\.py$"),
    re.compile(r"(?:^|/)conftest\.py$"),
]


# ---------------------------------------------------------------------------
# Config override parsing
# ---------------------------------------------------------------------------


def load_classify_overrides(repo: str) -> dict[str, list[str]]:
    """Read [classify] section overrides from .weave/quality.conf.

    Returns a dict mapping category name to list of path prefix strings.
    Example return value::

        {
            "test": ["tests/", "custom_tests/"],
            "script": ["deploy/", "infra/"],
            "generated": ["auto_gen/"],
        }

    Returns empty dict if quality.conf does not exist or has no [classify]
    section.
    """
    conf = Path(repo) / ".weave" / "quality.conf"
    if not conf.exists():
        return {}

    overrides: dict[str, list[str]] = {}
    in_section = False

    for raw_line in conf.read_text().splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("["):
            in_section = line.lower() == "[classify]"
            continue
        if not in_section:
            continue
        # key = value
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip().lower()
        parts = [p.strip() for p in value.split(",") if p.strip()]
        if key and parts:
            overrides[key] = parts

    return overrides


def _match_override(rel_path: str, prefixes: list[str]) -> bool:
    """Return True if rel_path matches any of the given prefix strings.

    Each prefix is treated as a path component boundary so that
    "tests/" matches "tests/foo.py" and "src/tests/bar.py" but not
    "mytests/foo.py".
    """
    for prefix in prefixes:
        stripped = prefix.rstrip("/")
        pattern = re.compile(r"(?:^|/)" + re.escape(stripped) + r"(?:/|$)")
        if pattern.search(rel_path):
            return True
    return False


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def classify_file(
    rel_path: str,
    overrides: dict[str, list[str]] | None = None,
) -> str:
    """Classify a file path into production/test/script/generated category.

    Args:
        rel_path: Relative path from the repo root (e.g. ``src/app.py``).
        overrides: Optional dict from :func:`load_classify_overrides`.
            Keys are category names; values are lists of path prefix strings.

    Returns:
        One of ``"production"``, ``"test"``, ``"script"``, ``"generated"``.

    Priority order (highest wins):
        1. generated
        2. test
        3. script
        4. production (default)

    Override prefixes are checked before built-in patterns, using the same
    priority order.  This allows projects to reclassify paths that would
    otherwise fall into a lower-priority bucket.
    """
    # Normalise separators; strip leading slash for consistent matching.
    path = rel_path.replace("\\", "/").lstrip("/")

    # --- Override checks (applied first, same priority order) ---
    # "production" is checked first so it can promote paths that built-in
    # patterns would otherwise classify as script/test.
    if overrides:
        for category in ("production", "generated", "test", "script"):
            prefixes = overrides.get(category)
            if prefixes and _match_override(path, prefixes):
                return category

    # --- Built-in pattern checks ---
    for pattern in _GENERATED_PATTERNS:
        if pattern.search(path):
            return "generated"

    for pattern in _TEST_PATTERNS:
        if pattern.search(path):
            return "test"

    for pattern in _SCRIPT_PATTERNS:
        if pattern.search(path):
            return "script"

    return "production"
