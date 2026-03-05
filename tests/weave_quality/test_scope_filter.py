"""Tests for _in_scope and _in_scope_path scope-filter predicates."""

# pylint: disable=missing-class-docstring,missing-function-docstring

from __future__ import annotations

from weave_quality.__main__ import _in_scope, _in_scope_path
from weave_quality.models import FileEntry


# ---------------------------------------------------------------------------
# _in_scope
# ---------------------------------------------------------------------------


class TestInScope:
    def test_production_entry_matches_production_scope(self) -> None:
        entry = FileEntry(path="src/app.py", category="production")
        assert _in_scope(entry, "production") is True

    def test_test_entry_does_not_match_production_scope(self) -> None:
        entry = FileEntry(path="tests/test_foo.py", category="test")
        assert _in_scope(entry, "production") is False

    def test_script_entry_does_not_match_production_scope(self) -> None:
        entry = FileEntry(path="scripts/build.sh", category="script")
        assert _in_scope(entry, "production") is False

    def test_generated_entry_does_not_match_production_scope(self) -> None:
        entry = FileEntry(path="dist/bundle.py", category="generated")
        assert _in_scope(entry, "production") is False

    def test_all_scope_matches_production_entry(self) -> None:
        entry = FileEntry(path="src/app.py", category="production")
        assert _in_scope(entry, "all") is True

    def test_all_scope_matches_test_entry(self) -> None:
        entry = FileEntry(path="tests/test_foo.py", category="test")
        assert _in_scope(entry, "all") is True

    def test_all_scope_matches_script_entry(self) -> None:
        entry = FileEntry(path="scripts/build.sh", category="script")
        assert _in_scope(entry, "all") is True

    def test_all_scope_matches_generated_entry(self) -> None:
        entry = FileEntry(path="dist/bundle.py", category="generated")
        assert _in_scope(entry, "all") is True

    def test_test_entry_matches_test_scope(self) -> None:
        entry = FileEntry(path="tests/test_foo.py", category="test")
        assert _in_scope(entry, "test") is True

    def test_script_entry_matches_script_scope(self) -> None:
        entry = FileEntry(path="scripts/run.sh", category="script")
        assert _in_scope(entry, "script") is True

    def test_default_category_is_production(self) -> None:
        # FileEntry default category should be "production"
        entry = FileEntry(path="src/module.py")
        assert _in_scope(entry, "production") is True


# ---------------------------------------------------------------------------
# _in_scope_path
# ---------------------------------------------------------------------------


class TestInScopePath:
    def test_production_path_matches_production_scope(self) -> None:
        assert _in_scope_path("src/app.py", "production") is True

    def test_test_path_does_not_match_production_scope(self) -> None:
        # tests/test_foo.py classifies as "test" → False for "production"
        assert _in_scope_path("tests/test_foo.py", "production") is False

    def test_test_path_with_all_scope_is_true(self) -> None:
        assert _in_scope_path("tests/test_foo.py", "all") is True

    def test_production_path_with_all_scope_is_true(self) -> None:
        assert _in_scope_path("src/app.py", "all") is True

    def test_script_path_with_all_scope_is_true(self) -> None:
        assert _in_scope_path("scripts/deploy.sh", "all") is True

    def test_generated_path_with_all_scope_is_true(self) -> None:
        assert _in_scope_path("dist/output.py", "all") is True

    def test_overrides_affect_classification(self) -> None:
        # With override, "custom_tests/foo.py" is "test" → False for "production"
        overrides = {"test": ["custom_tests/"]}
        assert _in_scope_path("custom_tests/foo.py", "production", overrides) is False

    def test_overrides_with_all_scope_still_true(self) -> None:
        overrides = {"test": ["custom_tests/"]}
        assert _in_scope_path("custom_tests/foo.py", "all", overrides) is True

    def test_no_overrides_uses_builtins(self) -> None:
        # Without overrides, "src/app.py" is "production"
        assert _in_scope_path("src/app.py", "production", None) is True
