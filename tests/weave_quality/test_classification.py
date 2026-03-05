"""Tests for weave_quality.classification -- classify_file() and config parsing."""

# pylint: disable=missing-class-docstring,missing-function-docstring

from __future__ import annotations

import textwrap
from pathlib import Path

from weave_quality.classification import (
    classify_file,
    load_classify_overrides,
    _match_override,
    _segment_pattern,
)


# ---------------------------------------------------------------------------
# _segment_pattern helper
# ---------------------------------------------------------------------------


class TestSegmentPattern:
    def test_matches_directory_component(self) -> None:
        pat = _segment_pattern("tests")
        assert pat.search("tests/foo.py")
        assert pat.search("src/tests/bar.py")

    def test_no_partial_match(self) -> None:
        pat = _segment_pattern("dist")
        # "distributed" must NOT match
        assert not pat.search("distributed/foo.py")
        assert not pat.search("src/distributed/bar.py")

    def test_matches_root_level(self) -> None:
        pat = _segment_pattern("scripts")
        assert pat.search("scripts/run.sh")

    def test_matches_terminal_segment(self) -> None:
        """Segment at end of path (no trailing slash)."""
        pat = _segment_pattern("build")
        assert pat.search("project/build")


# ---------------------------------------------------------------------------
# classify_file -- built-in test patterns
# ---------------------------------------------------------------------------


class TestClassifyFileTest:
    def test_tests_directory(self) -> None:
        assert classify_file("tests/test_core.py") == "test"

    def test_test_subdirectory(self) -> None:
        assert classify_file("src/test/helpers.py") == "test"

    def test_nested_tests_dir(self) -> None:
        assert classify_file("project/tests/unit/test_foo.py") == "test"

    def test_test_prefix_filename(self) -> None:
        assert classify_file("src/test_foo.py") == "test"

    def test_test_suffix_filename(self) -> None:
        assert classify_file("src/foo_test.py") == "test"

    def test_test_prefix_nested(self) -> None:
        assert classify_file("mypackage/test_bar.py") == "test"

    def test_test_suffix_nested(self) -> None:
        assert classify_file("mypackage/bar_test.py") == "test"

    def test_leading_slash_stripped(self) -> None:
        assert classify_file("/tests/foo.py") == "test"


# ---------------------------------------------------------------------------
# classify_file -- built-in script patterns
# ---------------------------------------------------------------------------


class TestClassifyFileScript:
    def test_scripts_directory(self) -> None:
        assert classify_file("scripts/run.sh") == "script"

    def test_scripts_at_root(self) -> None:
        assert classify_file("scripts/deploy.py") == "script"

    def test_shell_script_extension(self) -> None:
        assert classify_file("tools/build.sh") == "script"

    def test_makefile(self) -> None:
        assert classify_file("Makefile") == "script"

    def test_makefile_nested(self) -> None:
        assert classify_file("subproject/Makefile") == "script"

    def test_toml_extension(self) -> None:
        assert classify_file("pyproject.toml") == "script"

    def test_cfg_extension(self) -> None:
        assert classify_file("setup.cfg") == "script"

    def test_ini_extension(self) -> None:
        assert classify_file("tox.ini") == "script"

    def test_setup_py(self) -> None:
        assert classify_file("setup.py") == "script"

    def test_conftest_py(self) -> None:
        assert classify_file("conftest.py") == "script"

    def test_conftest_nested(self) -> None:
        assert classify_file("tests/conftest.py") == "test"  # test wins over script


# ---------------------------------------------------------------------------
# classify_file -- built-in generated patterns
# ---------------------------------------------------------------------------


class TestClassifyFileGenerated:
    def test_dist_directory(self) -> None:
        assert classify_file("dist/output.py") == "generated"

    def test_build_directory(self) -> None:
        assert classify_file("build/lib/module.py") == "generated"

    def test_generated_directory(self) -> None:
        assert classify_file("generated/stubs.py") == "generated"

    def test_nested_dist(self) -> None:
        assert classify_file("project/dist/bundle.js") == "generated"

    def test_pb2_suffix(self) -> None:
        assert classify_file("proto/foo_pb2.py") == "generated"

    def test_dot_pb2_suffix(self) -> None:
        assert classify_file("proto/foo.pb2.py") == "generated"


# ---------------------------------------------------------------------------
# classify_file -- production (default)
# ---------------------------------------------------------------------------


class TestClassifyFileProduction:
    def test_simple_source_file(self) -> None:
        assert classify_file("src/app.py") == "production"

    def test_root_module(self) -> None:
        assert classify_file("mymodule/__init__.py") == "production"

    def test_nested_source(self) -> None:
        assert classify_file("src/core/engine.py") == "production"

    def test_readme_treated_as_production(self) -> None:
        # Not covered by any special pattern → production
        assert classify_file("README.md") == "production"

    def test_no_partial_test_match(self) -> None:
        # "protest.py" must NOT match test pattern
        assert classify_file("src/protest.py") == "production"

    def test_no_partial_dist_match(self) -> None:
        # "distributed/foo.py" must NOT match generated pattern
        assert classify_file("distributed/foo.py") == "production"


# ---------------------------------------------------------------------------
# classify_file -- priority order
# ---------------------------------------------------------------------------


class TestClassifyFilePriority:
    def test_generated_beats_test(self) -> None:
        # A file in dist/ that also has test_ prefix → generated wins
        assert classify_file("dist/test_output.py") == "generated"

    def test_generated_beats_script(self) -> None:
        assert classify_file("build/Makefile") == "generated"

    def test_test_beats_script(self) -> None:
        # conftest.py inside tests/ → test wins
        assert classify_file("tests/conftest.py") == "test"

    def test_windows_path_separators(self) -> None:
        # Backslashes normalised before matching
        assert classify_file("tests\\test_foo.py") == "test"


# ---------------------------------------------------------------------------
# classify_file -- override dict
# ---------------------------------------------------------------------------


class TestClassifyFileOverrides:
    def test_override_adds_test_prefix(self) -> None:
        overrides = {"test": ["custom_tests/"]}
        assert classify_file("custom_tests/foo.py", overrides) == "test"

    def test_override_adds_generated_prefix(self) -> None:
        overrides = {"generated": ["auto_gen/"]}
        assert classify_file("auto_gen/stubs.py", overrides) == "generated"

    def test_override_adds_script_prefix(self) -> None:
        overrides = {"script": ["infra/"]}
        assert classify_file("infra/deploy.py", overrides) == "script"

    def test_override_generated_beats_test(self) -> None:
        overrides = {"generated": ["auto_gen/"], "test": ["auto_gen/"]}
        # generated priority beats test
        assert classify_file("auto_gen/test_foo.py", overrides) == "generated"

    def test_override_does_not_affect_other_paths(self) -> None:
        overrides = {"test": ["custom_tests/"]}
        assert classify_file("src/app.py", overrides) == "production"

    def test_none_overrides_uses_builtins(self) -> None:
        assert classify_file("tests/foo.py", None) == "test"

    def test_empty_overrides_uses_builtins(self) -> None:
        assert classify_file("dist/foo.py", {}) == "generated"

    def test_override_nested_path(self) -> None:
        overrides = {"script": ["deploy/"]}
        assert classify_file("project/deploy/run.py", overrides) == "script"


# ---------------------------------------------------------------------------
# load_classify_overrides
# ---------------------------------------------------------------------------


class TestLoadClassifyOverrides:
    def test_no_conf_file(self, tmp_path: Path) -> None:
        result = load_classify_overrides(str(tmp_path))
        assert not result

    def test_conf_without_classify_section(self, tmp_path: Path) -> None:
        weave_dir = tmp_path / ".weave"
        weave_dir.mkdir()
        (weave_dir / "quality.conf").write_text(
            textwrap.dedent("""\
                [exclude]
                dist/
                build/
            """)
        )
        result = load_classify_overrides(str(tmp_path))
        assert not result

    def test_conf_with_classify_section(self, tmp_path: Path) -> None:
        weave_dir = tmp_path / ".weave"
        weave_dir.mkdir()
        (weave_dir / "quality.conf").write_text(
            textwrap.dedent("""\
                [exclude]
                dist/

                [classify]
                test = tests/,custom_tests/
                script = deploy/,infra/
                generated = auto_gen/
            """)
        )
        result = load_classify_overrides(str(tmp_path))
        assert result == {
            "test": ["tests/", "custom_tests/"],
            "script": ["deploy/", "infra/"],
            "generated": ["auto_gen/"],
        }

    def test_conf_ignores_blank_lines_and_comments(self, tmp_path: Path) -> None:
        weave_dir = tmp_path / ".weave"
        weave_dir.mkdir()
        (weave_dir / "quality.conf").write_text(
            textwrap.dedent("""\
                [classify]
                # This is a comment
                test = custom_tests/

                # Another comment
                generated = auto_gen/
            """)
        )
        result = load_classify_overrides(str(tmp_path))
        assert result["test"] == ["custom_tests/"]
        assert result["generated"] == ["auto_gen/"]

    def test_conf_classify_only_section(self, tmp_path: Path) -> None:
        weave_dir = tmp_path / ".weave"
        weave_dir.mkdir()
        (weave_dir / "quality.conf").write_text(
            textwrap.dedent("""\
                [classify]
                test = my_tests/
            """)
        )
        result = load_classify_overrides(str(tmp_path))
        assert result == {"test": ["my_tests/"]}

    def test_classify_overrides_integrated_with_classify_file(
        self, tmp_path: Path
    ) -> None:
        """End-to-end: conf → overrides → classify_file."""
        weave_dir = tmp_path / ".weave"
        weave_dir.mkdir()
        (weave_dir / "quality.conf").write_text(
            textwrap.dedent("""\
                [classify]
                test = custom_tests/
                script = deploy/
            """)
        )
        overrides = load_classify_overrides(str(tmp_path))
        assert classify_file("custom_tests/foo.py", overrides) == "test"
        assert classify_file("deploy/run.py", overrides) == "script"
        assert classify_file("src/app.py", overrides) == "production"

    def test_inline_comments_stripped_from_values(self, tmp_path: Path) -> None:
        """Inline # comments in [classify] values must not become part of the path."""
        weave_dir = tmp_path / ".weave"
        weave_dir.mkdir()
        (weave_dir / "quality.conf").write_text(
            textwrap.dedent("""\
                [classify]
                production = scripts/mylib/   # promote library code
                test = custom_tests/          # additional test directory
                script = infra/               # additional script directory
            """)
        )
        overrides = load_classify_overrides(str(tmp_path))
        assert overrides["production"] == ["scripts/mylib/"]
        assert overrides["test"] == ["custom_tests/"]
        assert overrides["script"] == ["infra/"]


# ---------------------------------------------------------------------------
# _match_override
# ---------------------------------------------------------------------------


class TestMatchOverride:
    def test_matches_root_prefix(self) -> None:
        assert _match_override("tests/foo.py", ["tests/"])

    def test_matches_nested_prefix(self) -> None:
        assert _match_override("src/tests/foo.py", ["tests/"])

    def test_no_partial_match(self) -> None:
        assert not _match_override("mytests/foo.py", ["tests/"])

    def test_multiple_prefixes_first_matches(self) -> None:
        assert _match_override("deploy/run.py", ["infra/", "deploy/"])

    def test_no_match_returns_false(self) -> None:
        assert not _match_override("src/app.py", ["tests/", "custom_tests/"])
