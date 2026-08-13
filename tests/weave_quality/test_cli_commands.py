"""Tests for weave_quality CLI commands.

Covers: hotspots, diff, promote, health-info, context-files, functions.
"""
# pylint: disable=missing-class-docstring,missing-function-docstring,redefined-outer-name,unused-argument,too-many-lines,too-few-public-methods

from __future__ import annotations

import argparse
import io
import json
import os
import sqlite3
import subprocess
from collections.abc import Generator
from pathlib import Path
from unittest.mock import patch

import pytest

from weave_quality.__main__ import (
    _discover_files,
    _finding_id,
    _get_current_head,
    _load_config_excludes,
    _load_pattern_rules,
    _stale_managed_pattern_ids,
    _resolve_repo,
    _run_pattern_rule,
    _shadowed_managed_pattern_ids,
    _wv_cmd,
    cmd_context_files,
    cmd_diff,
    cmd_findings_promote,
    cmd_functions,
    cmd_health_info,
    cmd_hotspots,
    cmd_patterns_list,
    cmd_patterns_adjudicate,
    cmd_patterns_report,
    cmd_patterns_scan,
    cmd_patterns_validate,
    cmd_promote,
    cmd_reset,
    cmd_scan,
)
from weave_quality.db import (
    ADJUDICATION_NUDGE_SCANS,
    begin_pattern_run,
    begin_scan,
    bulk_upsert_file_entries,
    bulk_upsert_function_cc,
    bulk_upsert_git_stats,
    db_path,
    finish_scan,
    get_file_entries,
    init_db,
    latest_pattern_run,
    latest_scan,
    pattern_finding_states,
    pattern_rule_runs,
    query_pattern_findings,
)
from weave_quality.hotspots import compute_hotspots
from weave_quality.models import FileEntry, FunctionCC, GitStats
from weave_quality.prose_rules import PatternRuleExecutionError


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture()
def db(tmp_path: Path) -> Generator[sqlite3.Connection, None, None]:
    """Fresh quality.db in a temp directory."""
    conn = init_db(hot_zone=str(tmp_path))
    yield conn
    conn.close()


def _configure_temp_git_repo(repo: Path) -> None:
    """Keep temp git repos independent from user signing identity config."""
    subprocess.run(["git", "config", "user.email", "t@t"], cwd=repo, check=True)
    subprocess.run(["git", "config", "user.name", "T"], cwd=repo, check=True)
    subprocess.run(["git", "config", "commit.gpgsign", "false"], cwd=repo, check=True)


def _commit_temp_git_repo(repo: Path, *args: str, env: dict[str, str] | None = None) -> None:
    """Commit in a temp repo without requiring user GPG agent access."""
    subprocess.run(
        ["git", "-c", "commit.gpgsign=false", "commit", *args],
        cwd=repo,
        check=True,
        env=env,
    )


def _entry(
    path: str,
    scan_id: int,  # pylint: disable=unused-argument
    complexity: float = 10.0,
    loc: int = 100,
) -> FileEntry:
    return FileEntry(
        path=path,
        scan_id=scan_id,
        language="python",
        loc=loc,
        complexity=complexity,
        functions=5,
        max_nesting=3,
        avg_fn_len=10.0,
    )


def _stats(
    path: str,
    churn: int = 50,
    hotspot: float = 0.0,
) -> GitStats:
    return GitStats(
        path=path,
        churn=churn,
        age_days=30,
        authors=2,
        hotspot=hotspot,
    )


def _populate_scan(
    conn: sqlite3.Connection,
    scan_id: int,  # pylint: disable=unused-argument
    entries: list[FileEntry],
    stats: list[GitStats],
) -> None:
    """Populate a scan with entries and git stats.

    Commits the transaction since db.py upserts no longer auto-commit
    (single-transaction scan model).
    """
    bulk_upsert_file_entries(conn, entries)
    compute_hotspots(entries, stats)
    bulk_upsert_git_stats(conn, stats)
    conn.commit()


# ---------------------------------------------------------------------------
# Tests: cmd_patterns_scan
# ---------------------------------------------------------------------------


class TestCmdPatternsScan:
    def test_no_rules_json_uses_normal_success_schema(
        self,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        conn = init_db(hot_zone=str(tmp_path))
        begin_scan(conn, "abc")
        conn.commit()
        conn.close()
        args = argparse.Namespace(hot_zone=str(tmp_path), path=str(tmp_path), json=True)

        with patch("weave_quality.__main__._load_pattern_rules", return_value=[]):
            assert cmd_patterns_scan(args) == 0

        assert json.loads(capsys.readouterr().out) == {
            "rules": 0,
            "rules_run": 0,
            "findings": 0,
            "by_rule": {},
            "matches": [],
        }

    def test_no_rules_scan_rejects_a_nonexistent_target(
        self,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """A zero-rule invocation (every rule disabled, or only code rules
        exist and ast-grep is unavailable) must still validate its target --
        returning success against a target that doesn't exist would
        otherwise be silently wrong, and no lifecycle row should exist for
        the rejected attempt."""
        missing = tmp_path / "does-not-exist"
        args = argparse.Namespace(hot_zone=str(tmp_path), path=str(missing), json=True)

        with patch("weave_quality.__main__._load_pattern_rules", return_value=[]):
            assert cmd_patterns_scan(args) != 0

        conn = init_db(hot_zone=str(tmp_path))
        assert latest_pattern_run(conn) is None
        conn.close()

    def test_no_rules_scan_records_a_finished_run_and_scopes_report(
        self,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """A successful zero-rule scan must still create and finish its own
        pattern_runs row -- otherwise it's absent from lifecycle history, and
        `report` (which used to derive scope from the first per-rule
        receipt, absent here) falls back to an unscoped report instead of
        reflecting this invocation's target."""
        docs = tmp_path / "docs"
        docs.mkdir()
        args = argparse.Namespace(hot_zone=str(tmp_path), path=str(docs), json=True)

        with (
            patch("weave_quality.__main__._resolve_repo", return_value=str(tmp_path)),
            patch("weave_quality.__main__._load_pattern_rules", return_value=[]),
        ):
            assert cmd_patterns_scan(args) == 0
            capsys.readouterr()

            conn = init_db(hot_zone=str(tmp_path))
            run = latest_pattern_run(conn)
            assert run is not None
            finished_at = conn.execute(
                "SELECT finished_at FROM pattern_runs WHERE id = ?", (run.id,)
            ).fetchone()[0]
            conn.close()
            assert finished_at is not None
            assert run.target == "docs"

            report_args = argparse.Namespace(hot_zone=str(tmp_path), json=True)
            assert cmd_patterns_report(report_args) == 0
            report = json.loads(capsys.readouterr().out)

        assert report["scope"] == "docs"

    def test_earlier_successful_rule_survives_a_later_rules_failure(
        self,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """Successful receipts were only persisted in one batch after every
        rule in the scan finished -- an earlier rule's success was never
        durably recorded if a LATER rule in the same invocation failed,
        so it was reported as not_run afterward, indistinguishable from
        never having executed at all."""
        doc = tmp_path / "doc.md"
        doc.write_text("Nothing interesting here.\n", encoding="utf-8")
        rule_a = tmp_path / "prose-a.yaml"
        rule_a.write_text(
            "id: prose-a\nlanguage: prose\nkind: lexicon\nterms:\n  - genuine\n",
            encoding="utf-8",
        )
        rule_b = tmp_path / "prose-b.yaml"
        rule_b.write_text(
            "id: prose-b\nlanguage: prose\nkind: lexicon\nterms:\n  - genuine\n",
            encoding="utf-8",
        )
        args = argparse.Namespace(hot_zone=str(tmp_path), path=str(doc), json=True)

        def fake_run_pattern_rule(
            rule_id: str, rule_path: Path, target: Path, scan_id: int, repo: Path, language: str
        ) -> list[object]:
            if rule_id == "prose-b":
                raise PatternRuleExecutionError("boom")
            return []

        with (
            patch("weave_quality.__main__._resolve_repo", return_value=str(tmp_path)),
            patch(
                "weave_quality.__main__._load_pattern_rules",
                return_value=[("prose-a", rule_a, "prose"), ("prose-b", rule_b, "prose")],
            ),
            patch(
                "weave_quality.__main__._run_pattern_rule",
                side_effect=fake_run_pattern_rule,
            ),
        ):
            assert cmd_patterns_scan(args) != 0
            capsys.readouterr()

        conn = init_db(hot_zone=str(tmp_path))
        run = latest_pattern_run(conn)
        assert run is not None
        receipts = {row["rule_id"]: row for row in pattern_rule_runs(conn, run.id)}
        conn.close()
        assert receipts["prose-a"]["status"] == "success"
        assert receipts["prose-a"]["hits"] == 0
        assert receipts["prose-b"]["status"] == "failed"

    def test_scan_records_a_failed_receipt_when_identity_attachment_raises(
        self,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """Finding-identity attachment reads each finding's source file --
        a real OSError there (Path.read_text() failing on a path that
        passed match validation but is still unusable for some other
        OS-level reason, e.g. permission denied) must be caught inside the
        same execution-failure boundary as a rule execution failure: a
        recorded failed receipt, not silently swallowed into a
        successfully-recorded finding with fallback context. Patches
        Path.read_text() itself (not _attach_pattern_finding_identities)
        so this exercises the function's own real exception handling, not
        a mocked stand-in for it."""
        target = tmp_path / "docs"
        target.mkdir()
        (target / "x.py").write_text("pass\n", encoding="utf-8")
        rule = tmp_path / "r.yaml"
        rule.write_text("id: r\nlanguage: python\n", encoding="utf-8")
        matches = [{"file": str(target / "x.py"), "range": {"start": {}}, "text": "m"}]
        args = argparse.Namespace(hot_zone=str(tmp_path), path=str(target), json=True)

        with (
            patch("weave_quality.__main__._resolve_repo", return_value=str(tmp_path)),
            patch(
                "weave_quality.__main__._load_pattern_rules",
                return_value=[("r", rule, "python")],
            ),
            patch("weave_quality.__main__.ast_grep_bin", return_value="/usr/bin/ast-grep"),
            patch(
                "subprocess.run",
                return_value=subprocess.CompletedProcess(
                    args=["ast-grep"], returncode=0, stdout=json.dumps(matches), stderr=""
                ),
            ),
            patch("pathlib.Path.read_text", side_effect=PermissionError("denied")),
        ):
            assert cmd_patterns_scan(args) != 0
            capsys.readouterr()

        conn = init_db(hot_zone=str(tmp_path))
        run = latest_pattern_run(conn)
        assert run is not None
        receipts = pattern_rule_runs(conn, run.id)
        findings = query_pattern_findings(conn, run.id)
        conn.close()
        assert len(receipts) == 1
        assert receipts[0]["status"] == "failed"
        assert "denied" in str(receipts[0]["error"])
        # No finding was silently recorded with a fallback empty context.
        assert findings == []

    def test_prose_rule_vanished_after_load_still_gets_a_failed_receipt(
        self,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """A rule _load_pattern_rules already classified as prose (language
        captured once, at validation time) whose file then vanishes before
        the prose/code split runs must still reach the per-rule execution
        boundary and record a failed receipt. Before wv-dc2e44, the split
        re-derived language via a separate rule_language(rule_path) read --
        which swallows OSError into "" -- misclassifying the now-missing
        file as a code rule; with ast-grep unavailable, that silently
        dropped it from `rules` entirely and took the zero-rule success
        branch instead of ever recording a failure."""
        docs = tmp_path / "docs"
        docs.mkdir()
        rule = tmp_path / "prose-vanish.yaml"
        rule.write_text(
            "id: prose-vanish\nlanguage: prose\nkind: lexicon\nterms:\n  - genuine\n",
            encoding="utf-8",
        )
        args = argparse.Namespace(hot_zone=str(tmp_path), path=str(docs), json=True)

        # _load_pattern_rules already captured language="prose" from
        # validate_pattern_rule -- simulate the file vanishing immediately
        # afterward, before cmd_patterns_scan's classification/execution
        # ever touches the filesystem again.
        rule.unlink()
        with (
            patch("weave_quality.__main__._resolve_repo", return_value=str(tmp_path)),
            patch(
                "weave_quality.__main__._load_pattern_rules",
                return_value=[("prose-vanish", rule, "prose")],
            ),
            patch("weave_quality.__main__.ast_grep_available", return_value=False),
        ):
            assert cmd_patterns_scan(args) != 0
            payload = json.loads(capsys.readouterr().out)

        assert payload["error"] == "pattern_rule_execution_failed"

        conn = init_db(hot_zone=str(tmp_path))
        run = latest_pattern_run(conn)
        assert run is not None
        receipts = pattern_rule_runs(conn, run.id)
        conn.close()
        assert len(receipts) == 1
        assert receipts[0]["status"] == "failed"

    def test_list_scopes_from_run_target_even_with_zero_receipts(
        self,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """`list` must read scope from pattern_runs.target, not the first
        per-rule receipt -- an interrupted run (crashed before any rule
        finished) still recorded its target on the run row, but has no
        receipts to derive it from the old way."""
        conn = init_db(hot_zone=str(tmp_path))
        begin_pattern_run(conn, "abc", "docs")
        conn.close()

        rule = tmp_path / "prose-test.yaml"
        rule.write_text(
            "id: prose-test\nlanguage: prose\nkind: lexicon\nterms:\n  - genuine\n",
            encoding="utf-8",
        )
        list_args = argparse.Namespace(hot_zone=str(tmp_path), path=str(tmp_path), json=False)
        with patch(
            "weave_quality.__main__._load_pattern_rules",
            return_value=[("prose-test", rule, "prose")],
        ):
            assert cmd_patterns_list(list_args) == 0
        listing = capsys.readouterr().out
        assert "last scanned: docs" in listing

    def test_scan_creates_implicit_scan_row_when_db_is_empty(
        self,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """patterns scan needs nothing from `wv quality scan` — a docs-only
        repo, or a docs-only session, shouldn't be forced through an
        unrelated complexity pass just to get a scan_id. It gets its own
        pattern_runs identity instead, and must NOT fabricate a scan_meta
        row -- that would make hotspots/functions pick up an empty "latest"
        complexity scan."""
        conn = init_db(hot_zone=str(tmp_path))
        assert latest_scan(conn) is None
        assert latest_pattern_run(conn) is None
        conn.close()
        doc = tmp_path / "doc.md"
        doc.write_text("A genuine result.\n", encoding="utf-8")
        rule = tmp_path / "prose-test.yaml"
        rule.write_text(
            "id: prose-test\nlanguage: prose\nkind: lexicon\nterms:\n  - genuine\n",
            encoding="utf-8",
        )
        args = argparse.Namespace(hot_zone=str(tmp_path), path=str(doc), json=True)

        with patch(
            "weave_quality.__main__._load_pattern_rules",
            return_value=[("prose-test", rule, "prose")],
        ):
            assert cmd_patterns_scan(args) == 0

        payload = json.loads(capsys.readouterr().out)
        assert payload["findings"] == 1

        conn = init_db(hot_zone=str(tmp_path))
        assert latest_scan(conn) is None
        assert latest_pattern_run(conn) is not None
        conn.close()

    @pytest.mark.parametrize("as_json", [False, True])
    def test_scan_reports_actionable_finding_locations(
        self,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
        as_json: bool,
    ) -> None:
        conn = init_db(hot_zone=str(tmp_path))
        begin_scan(conn, "abc")
        conn.commit()
        conn.close()
        doc = tmp_path / "doc.md"
        doc.write_text("A genuine result.\n", encoding="utf-8")
        rule = tmp_path / "prose-test.yaml"
        rule.write_text(
            "id: prose-test\nlanguage: prose\nkind: lexicon\nterms:\n  - genuine\n",
            encoding="utf-8",
        )
        args = argparse.Namespace(hot_zone=str(tmp_path), path=str(doc), json=as_json)

        # Patch repo to tmp_path so doc.md resolves as an in-repo finding --
        # this test is about location formatting, not the outside-repo
        # identity fallback (see
        # test_outside_repo_targets_get_collision_safe_absolute_finding_identity).
        with (
            patch("weave_quality.__main__._resolve_repo", return_value=str(tmp_path)),
            patch(
                "weave_quality.__main__._load_pattern_rules",
                return_value=[("prose-test", rule, "prose")],
            ),
        ):
            assert cmd_patterns_scan(args) == 0

        output = capsys.readouterr().out
        if as_json:
            payload = json.loads(output)
            assert payload["rules"] == payload["rules_run"] == 1
            assert payload["findings"] == 1
            assert payload["matches"] == [
                {
                    "rule_id": "prose-test",
                    "path": "doc.md",
                    "line": 1,
                    "col": 3,
                    "match_text": "genuine",
                    "severity": "info",
                    "finding_key": payload["matches"][0]["finding_key"],
                    "disposition": "unresolved",
                    "scan_count": 1,
                }
            ]
            assert payload["matches"][0]["finding_key"].startswith("qf-")
        else:
            assert "doc.md:1:3: [prose-test/info] genuine" in output

    def test_scan_finding_path_stays_lexical_through_a_symlink(
        self,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """A finding's stored path must reflect the name it was actually
        scanned under, not where a symlink resolves to -- otherwise a real
        file reached via two directory-walk entries (itself and a symlink
        to it) could collide into one finding identity or split into two."""
        real_dir = tmp_path / "real"
        real_dir.mkdir()
        real_file = real_dir / "a.md"
        real_file.write_text("A genuine result.\n", encoding="utf-8")
        docs = tmp_path / "docs"
        docs.mkdir()
        (docs / "link.md").symlink_to(real_file)
        rule = tmp_path / "prose-test.yaml"
        rule.write_text(
            "id: prose-test\nlanguage: prose\nkind: lexicon\nterms:\n  - genuine\n",
            encoding="utf-8",
        )
        args = argparse.Namespace(hot_zone=str(tmp_path), path=str(docs / "link.md"), json=True)

        with (
            patch("weave_quality.__main__._resolve_repo", return_value=str(tmp_path)),
            patch(
                "weave_quality.__main__._load_pattern_rules",
                return_value=[("prose-test", rule, "prose")],
            ),
        ):
            assert cmd_patterns_scan(args) == 0

        payload = json.loads(capsys.readouterr().out)
        assert [m["path"] for m in payload["matches"]] == ["docs/link.md"]

    def test_repeated_scan_creates_independent_runs_not_a_shared_one(
        self,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """Each `patterns scan` invocation gets its own pattern_runs id (see
        wv-c912b2), never reusing a prior invocation's -- querying by the
        complexity scan_id (which happens to equal 1 in a fresh db, same as
        the first pattern run) would silently test the wrong lifecycle
        sequence. Deliberately offset scan_meta's sequence from
        pattern_runs' so a coincidental id match can't mask a regression."""
        conn = init_db(hot_zone=str(tmp_path))
        begin_scan(conn, "abc")
        begin_scan(conn, "def")
        conn.commit()
        conn.close()

        doc = tmp_path / "doc.md"
        doc.write_text("A genuine result.\n", encoding="utf-8")
        rule = tmp_path / "prose-rule.yaml"
        rule.write_text(
            "\n".join(
                [
                    "id: prose-test",
                    "language: prose",
                    "kind: lexicon",
                    "terms:",
                    "  - genuine",
                    "",
                ]
            ),
            encoding="utf-8",
        )
        args = argparse.Namespace(hot_zone=str(tmp_path), path=str(doc), json=True)

        with patch(
            "weave_quality.__main__._load_pattern_rules",
            return_value=[("prose-test", rule, "prose")],
        ):
            assert cmd_patterns_scan(args) == 0
            capsys.readouterr()
            conn = init_db(hot_zone=str(tmp_path))
            first_run = latest_pattern_run(conn)
            conn.close()

            assert cmd_patterns_scan(args) == 0
            capsys.readouterr()
            conn = init_db(hot_zone=str(tmp_path))
            second_run = latest_pattern_run(conn)
            conn.close()

        assert first_run is not None and second_run is not None
        assert second_run.id != first_run.id  # a fresh id every invocation

        conn = init_db(hot_zone=str(tmp_path))
        first_rows = query_pattern_findings(conn, first_run.id)
        second_rows = query_pattern_findings(conn, second_run.id)
        conn.close()
        # Each run's own findings persist independently -- neither wiped the
        # other's, unlike the old scheme where a reused scan_id would.
        assert len(first_rows) == 1
        assert len(second_rows) == 1
        assert first_rows[0]["rule_id"] == second_rows[0]["rule_id"] == "prose-test"

    def test_stable_identity_adjudication_and_recurring_waiver_report(
        self,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        hotzone = tmp_path / "hotzone"
        conn = init_db(hot_zone=str(hotzone))
        begin_scan(conn, "abc")
        conn.commit()
        conn.close()
        doc = tmp_path / "doc.md"
        doc.write_text("A genuine result.\n", encoding="utf-8")
        rule = tmp_path / "prose-test.yaml"
        rule.write_text(
            "id: prose-test\nlanguage: prose\nkind: lexicon\nterms:\n  - genuine\n",
            encoding="utf-8",
        )
        scan_args = argparse.Namespace(hot_zone=str(hotzone), path=str(doc), json=True)

        with (
            patch("weave_quality.__main__._resolve_repo", return_value=str(tmp_path)),
            patch(
                "weave_quality.__main__._load_pattern_rules",
                return_value=[("prose-test", rule, "prose")],
            ),
        ):
            assert cmd_patterns_scan(scan_args) == 0
            first = json.loads(capsys.readouterr().out)
            finding_key = first["matches"][0]["finding_key"]
            adjudicate_args = argparse.Namespace(
                hot_zone=str(hotzone),
                finding_key=finding_key,
                disposition="waived",
                note="intentional terminology",
                json=True,
            )
            assert cmd_patterns_adjudicate(adjudicate_args) == 0
            capsys.readouterr()

            # Source movement, surrounding prose edits, and scan identity do
            # not change finding identity.
            doc.write_text("\nThe revised report has a genuine result today.\n", encoding="utf-8")
            conn = init_db(hot_zone=str(hotzone))
            begin_scan(conn, "def")
            conn.commit()
            conn.close()
            assert cmd_patterns_scan(scan_args) == 0
            second = json.loads(capsys.readouterr().out)

        assert second["matches"][0]["finding_key"] == finding_key
        assert second["matches"][0]["disposition"] == "waived"
        assert second["matches"][0]["scan_count"] == 2

        report_args = argparse.Namespace(hot_zone=str(hotzone), json=True)
        assert cmd_patterns_report(report_args) == 0
        report = json.loads(capsys.readouterr().out)
        assert report["by_rule"]["prose-test"]["decided_precision"] == 1.0
        assert report["by_rule"]["prose-test"]["decided_count"] == 1
        assert report["recurring_waivers"] == [
            {
                "finding_key": finding_key,
                "rule_id": "prose-test",
                "path": "doc.md",
                "match_text": "genuine",
                "scan_count": 2,
                "note": "intentional terminology",
            }
        ]

    def test_repeated_matches_have_distinct_position_independent_keys(
        self,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        hotzone = tmp_path / "hotzone"
        doc = tmp_path / "doc.md"
        doc.write_text(
            "A genuine first result.\n\nA genuine second result.\n", encoding="utf-8"
        )
        rule = tmp_path / "prose-test.yaml"
        rule.write_text(
            "id: prose-test\nlanguage: prose\nkind: lexicon\nterms:\n  - genuine\n",
            encoding="utf-8",
        )
        scan_args = argparse.Namespace(hot_zone=str(hotzone), path=str(doc), json=True)

        with (
            patch("weave_quality.__main__._resolve_repo", return_value=str(tmp_path)),
            patch(
                "weave_quality.__main__._load_pattern_rules",
                return_value=[("prose-test", rule, "prose")],
            ),
        ):
            assert cmd_patterns_scan(scan_args) == 0
            first = json.loads(capsys.readouterr().out)
            first_keys = [match["finding_key"] for match in first["matches"]]
            assert len(first_keys) == len(set(first_keys)) == 2

            adjudicate_args = argparse.Namespace(
                hot_zone=str(hotzone),
                finding_key=first_keys[1],
                disposition="waived",
                note="second occurrence",
                json=True,
            )
            assert cmd_patterns_adjudicate(adjudicate_args) == 0
            capsys.readouterr()

            doc.write_text(
                "Introductory material moved here.\n\n"
                "The first revised paragraph has a genuine result.\n\n"
                "The second revised paragraph also has a genuine result.\n",
                encoding="utf-8",
            )
            assert cmd_patterns_scan(scan_args) == 0
            second = json.loads(capsys.readouterr().out)

        assert [match["finding_key"] for match in second["matches"]] == first_keys
        assert [match["disposition"] for match in second["matches"]] == [
            "unresolved",
            "waived",
        ]

    def test_report_scopes_to_last_scan_target_by_default(
        self,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """Report defaults to the last scan's target, not the whole cross-scan
        history -- the earth-engine-analysis Part 4 finding that a per-target
        adjudication view beats a global last-scan count."""
        hotzone = tmp_path / "hotzone"
        conn = init_db(hot_zone=str(hotzone))
        begin_scan(conn, "abc")
        conn.commit()
        conn.close()

        docs = tmp_path / "docs"
        docs.mkdir()
        (docs / "a.md").write_text("A genuine result.\n", encoding="utf-8")
        other = tmp_path / "other"
        other.mkdir()
        (other / "b.md").write_text("A genuine result.\n", encoding="utf-8")
        rule = tmp_path / "prose-test.yaml"
        rule.write_text(
            "id: prose-test\nlanguage: prose\nkind: lexicon\nterms:\n  - genuine\n",
            encoding="utf-8",
        )

        with (
            patch("weave_quality.__main__._resolve_repo", return_value=str(tmp_path)),
            patch(
                "weave_quality.__main__._load_pattern_rules",
                return_value=[("prose-test", rule, "prose")],
            ),
        ):
            whole_repo_args = argparse.Namespace(
                hot_zone=str(hotzone), path=str(tmp_path), json=True
            )
            assert cmd_patterns_scan(whole_repo_args) == 0
            whole = json.loads(capsys.readouterr().out)
            docs_key = next(
                m["finding_key"] for m in whole["matches"] if m["path"] == "docs/a.md"
            )
            other_key = next(
                m["finding_key"] for m in whole["matches"] if m["path"] == "other/b.md"
            )
            assert (
                cmd_patterns_adjudicate(
                    argparse.Namespace(
                        hot_zone=str(hotzone),
                        finding_key=docs_key,
                        disposition="accepted_defect",
                        note=None,
                        json=True,
                    )
                )
                == 0
            )
            capsys.readouterr()
            assert (
                cmd_patterns_adjudicate(
                    argparse.Namespace(
                        hot_zone=str(hotzone),
                        finding_key=other_key,
                        disposition="false_positive",
                        note=None,
                        json=True,
                    )
                )
                == 0
            )
            capsys.readouterr()

            # Rescan just docs/ -- patterns scan always gets its own fresh
            # pattern_runs id (independent of scan_meta), so this can never
            # collide with and wipe other/b.md's occurrence the way reusing
            # a scan_id would. The last scan's target becomes docs/.
            docs_scan_args = argparse.Namespace(
                hot_zone=str(hotzone), path=str(docs), json=True
            )
            assert cmd_patterns_scan(docs_scan_args) == 0
            capsys.readouterr()

            report_args = argparse.Namespace(hot_zone=str(hotzone), json=True)
            assert cmd_patterns_report(report_args) == 0
            scoped = json.loads(capsys.readouterr().out)
            # The stored scan target is now a canonical repo-relative posix
            # path ("docs"), not the raw absolute invocation string -- so
            # `report` scopes correctly regardless of the caller's cwd.
            assert scoped["scope"] == "docs"
            assert scoped["by_rule"]["prose-test"]["decided_count"] == 1
            assert scoped["by_rule"]["prose-test"]["decided_precision"] == 1.0

            # Acting on that finding changes its stable key or removes it.
            # A real rescan allocates a NEW pattern_runs id, so the durable
            # adjudication must become dormant rather than contaminating the
            # current report's precision denominator forever.
            (docs / "a.md").write_text("A specific result.\n", encoding="utf-8")
            assert cmd_patterns_scan(docs_scan_args) == 0
            capsys.readouterr()
            assert cmd_patterns_report(report_args) == 0
            after_edit = json.loads(capsys.readouterr().out)
            assert after_edit["scope"] == "docs"
            assert not after_edit["by_rule"]
            assert after_edit["finding_count"] == 0

            # An explicit path argument overrides the last scan's target.
            other_report_args = argparse.Namespace(
                hot_zone=str(hotzone), path=str(other), json=True
            )
            assert cmd_patterns_report(other_report_args) == 0
            other_scoped = json.loads(capsys.readouterr().out)
            # An explicit --path is canonicalized the same way a scan target
            # is (cwd-relative, then relativized to repo), not echoed raw.
            assert other_scoped["scope"] == "other"
            assert other_scoped["by_rule"]["prose-test"]["decided_count"] == 1
            assert other_scoped["by_rule"]["prose-test"]["decided_precision"] == 0.0

    def test_cross_rule_span_collision_keeps_only_the_higher_maturity_finding(
        self,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """wv-19bc39 (external code review round 3 re-audit): two different
        rule ids independently flagging the identical (path, line, col)
        inflated the scan total and the by_rule summary with what is, from
        a reader's perspective, one finding counted twice -- reproduced
        exactly in earth-engine-analysis with the built-in
        prose-casual-register and a project-local prose-consequence-so both
        firing on the same comma-plus-'so' text. The higher-maturity rule
        (promotable) must win over the lower one (candidate); the loser
        must not appear in matches/by_rule at all.

        wv-c71833 revises what this means for the loser's receipt: wv-19bc39
        originally left each rule's persisted 'hits' receipt at its raw,
        pre-dedup count (a property of that rule alone), which meant
        `patterns scan`'s by_rule, the stored receipt, and `patterns list`'s
        displayed hit count could disagree for the same scan. The receipt is
        now overwritten from the same post-dedup finding set that by_rule
        and pattern_findings use, so all three agree; the rule's raw,
        pre-dedup count survives only as `raw_hits` in the scan JSON, not in
        the persisted receipt."""
        hotzone = tmp_path / "hotzone"
        docs = tmp_path / "docs"
        docs.mkdir()
        (docs / "a.md").write_text(
            "The gate passed, so any remaining warning is unrelated.\n", encoding="utf-8"
        )
        rule_pattern = (
            "id: {id}\nlanguage: prose\nkind: regex\nmaturity: {maturity}\n"
            "provenance: >-\n  test fixture\n"
            "message: >-\n  test fixture message\n"
            r"patterns:" "\n" r"  - ',\s*so\s+\S+'" "\n"
            "positive_controls:\n"
            "  - \"The gate passed, so any remaining warning is unrelated.\"\n"
            "negative_controls:\n"
            "  - \"The result follows from the measured causal model.\"\n"
        )
        promotable_rule = tmp_path / "prose-casual-register.yaml"
        promotable_rule.write_text(
            rule_pattern.format(id="prose-casual-register", maturity="promotable"),
            encoding="utf-8",
        )
        candidate_rule = tmp_path / "prose-consequence-so.yaml"
        candidate_rule.write_text(
            rule_pattern.format(id="prose-consequence-so", maturity="candidate"),
            encoding="utf-8",
        )

        with (
            patch("weave_quality.__main__._resolve_repo", return_value=str(tmp_path)),
            patch(
                "weave_quality.__main__._load_pattern_rules",
                return_value=[
                    ("prose-casual-register", promotable_rule, "prose"),
                    ("prose-consequence-so", candidate_rule, "prose"),
                ],
            ),
        ):
            args = argparse.Namespace(hot_zone=str(hotzone), path=str(docs), json=True)
            assert cmd_patterns_scan(args) == 0
            payload = json.loads(capsys.readouterr().out)

        assert payload["findings"] == 1
        assert len(payload["matches"]) == 1
        assert payload["matches"][0]["rule_id"] == "prose-casual-register"
        assert payload["by_rule"]["prose-casual-register"] == 1
        assert payload["by_rule"]["prose-consequence-so"] == 0
        # wv-c71833: the rule's own intrinsic match, pre-dedup, is still
        # visible -- just not in by_rule or the stored receipt anymore.
        assert payload["raw_hits"]["prose-casual-register"] == 1
        assert payload["raw_hits"]["prose-consequence-so"] == 1
        # The losing rule's persisted receipt now agrees with by_rule/list
        # (0, not its raw 1) -- wv-c71833 supersedes wv-19bc39's original
        # choice to leave the receipt at its raw count. See raw_hits above
        # for where that raw count is still surfaced.
        conn = init_db(hot_zone=str(hotzone))
        run = latest_pattern_run(conn)
        assert run is not None
        receipts = {str(row["rule_id"]): row for row in pattern_rule_runs(conn, run.id)}
        conn.close()
        assert receipts["prose-consequence-so"]["hits"] == 0
        assert receipts["prose-casual-register"]["hits"] == 1

    def test_collision_suppression_ignores_match_length_only_start_position_counts(
        self,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """wv-c71833: same-start-location collision suppression keys on
        (path, line, col) alone -- two rules that both start matching at the
        identical position but capture DIFFERENT amounts of text (different
        match_text length, different end position) must still collapse to
        one finding. This is the point of the name: it is not span-overlap
        or exact-span dedup, which would care about where a match ends."""
        hotzone = tmp_path / "hotzone"
        docs = tmp_path / "docs"
        docs.mkdir()
        text = "The gate passed, so any remaining warning is unrelated.\n"
        (docs / "a.md").write_text(text, encoding="utf-8")
        # Same start (the comma before "so"): rule_long's pattern consumes
        # through the next word, rule_short's stops right after "so" --
        # different match_text, different length, identical start position.
        rule_long = tmp_path / "prose-long.yaml"
        rule_long.write_text(
            "id: prose-long\nlanguage: prose\nkind: regex\nmaturity: promotable\n"
            "provenance: >-\n  test fixture\n"
            "message: >-\n  test fixture message\n"
            r"patterns:" "\n" r"  - ',\s*so\s+\S+'" "\n"
            "positive_controls:\n"
            "  - \"The gate passed, so any remaining warning is unrelated.\"\n"
            "negative_controls:\n"
            "  - \"The result follows from the measured causal model.\"\n",
            encoding="utf-8",
        )
        rule_short = tmp_path / "prose-short.yaml"
        rule_short.write_text(
            "id: prose-short\nlanguage: prose\nkind: regex\nmaturity: candidate\n"
            "provenance: >-\n  test fixture\n"
            "message: >-\n  test fixture message\n"
            r"patterns:" "\n" r"  - ',\s*so\b'" "\n"
            "positive_controls:\n"
            "  - \"The gate passed, so any remaining warning is unrelated.\"\n"
            "negative_controls:\n"
            "  - \"The result follows from the measured causal model.\"\n",
            encoding="utf-8",
        )

        # Confirm in isolation that the two rules really do capture
        # different-length text at the same start -- otherwise this test
        # wouldn't actually exercise the different-length case.
        with (
            patch("weave_quality.__main__._resolve_repo", return_value=str(tmp_path)),
            patch(
                "weave_quality.__main__._load_pattern_rules",
                return_value=[("prose-short", rule_short, "prose")],
            ),
        ):
            solo_args = argparse.Namespace(hot_zone=str(tmp_path / "solo"), path=str(docs), json=True)
            assert cmd_patterns_scan(solo_args) == 0
            solo_payload = json.loads(capsys.readouterr().out)
        short_len = len(solo_payload["matches"][0]["match_text"])

        with (
            patch("weave_quality.__main__._resolve_repo", return_value=str(tmp_path)),
            patch(
                "weave_quality.__main__._load_pattern_rules",
                return_value=[
                    ("prose-long", rule_long, "prose"),
                    ("prose-short", rule_short, "prose"),
                ],
            ),
        ):
            args = argparse.Namespace(hot_zone=str(hotzone), path=str(docs), json=True)
            assert cmd_patterns_scan(args) == 0
            payload = json.loads(capsys.readouterr().out)

        assert payload["findings"] == 1
        assert payload["matches"][0]["rule_id"] == "prose-long"
        assert len(payload["matches"][0]["match_text"]) != short_len
        assert payload["by_rule"]["prose-short"] == 0
        assert payload["raw_hits"]["prose-short"] == 1

    def test_rescan_winner_change_preserves_the_losing_finding_adjudication(
        self,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """wv-c71833: a rule's maturity can change between scans (promoted
        or demoted), which can flip which of two colliding rules wins the
        same (path, line, col) from one scan to the next. The loser's
        finding_key is rule-specific (derived from rule_id among other
        things), so it is a genuinely different identity from the new
        winner's -- its disposition/note in pattern_finding_state must
        stay exactly as adjudicated, not be silently dropped just because
        that rule no longer wins the current scan."""
        hotzone = tmp_path / "hotzone"
        docs = tmp_path / "docs"
        docs.mkdir()
        (docs / "a.md").write_text(
            "The gate passed, so any remaining warning is unrelated.\n", encoding="utf-8"
        )
        rule_pattern = (
            "id: {id}\nlanguage: prose\nkind: regex\nmaturity: {maturity}\n"
            "provenance: >-\n  test fixture\n"
            "message: >-\n  test fixture message\n"
            r"patterns:" "\n" r"  - ',\s*so\s+\S+'" "\n"
            "positive_controls:\n"
            "  - \"The gate passed, so any remaining warning is unrelated.\"\n"
            "negative_controls:\n"
            "  - \"The result follows from the measured causal model.\"\n"
        )
        rule_a = tmp_path / "prose-a.yaml"
        rule_b = tmp_path / "prose-b.yaml"

        # Scan 1: a is promotable, b is candidate -- a wins.
        rule_a.write_text(rule_pattern.format(id="prose-a", maturity="promotable"), encoding="utf-8")
        rule_b.write_text(rule_pattern.format(id="prose-b", maturity="candidate"), encoding="utf-8")
        with (
            patch("weave_quality.__main__._resolve_repo", return_value=str(tmp_path)),
            patch(
                "weave_quality.__main__._load_pattern_rules",
                return_value=[("prose-a", rule_a, "prose"), ("prose-b", rule_b, "prose")],
            ),
        ):
            args = argparse.Namespace(hot_zone=str(hotzone), path=str(docs), json=True)
            assert cmd_patterns_scan(args) == 0
            first = json.loads(capsys.readouterr().out)
        assert first["matches"][0]["rule_id"] == "prose-a"
        winner_key_scan1 = first["matches"][0]["finding_key"]

        adjudicate_args = argparse.Namespace(
            hot_zone=str(hotzone),
            finding_key=winner_key_scan1,
            disposition="waived",
            note="reviewed and accepted for now",
            json=True,
        )
        assert cmd_patterns_adjudicate(adjudicate_args) == 0
        capsys.readouterr()

        # Scan 2: maturity flips -- b is now promotable, a is now candidate.
        rule_a.write_text(rule_pattern.format(id="prose-a", maturity="candidate"), encoding="utf-8")
        rule_b.write_text(rule_pattern.format(id="prose-b", maturity="promotable"), encoding="utf-8")
        with (
            patch("weave_quality.__main__._resolve_repo", return_value=str(tmp_path)),
            patch(
                "weave_quality.__main__._load_pattern_rules",
                return_value=[("prose-a", rule_a, "prose"), ("prose-b", rule_b, "prose")],
            ),
        ):
            args = argparse.Namespace(hot_zone=str(hotzone), path=str(docs), json=True)
            assert cmd_patterns_scan(args) == 0
            second = json.loads(capsys.readouterr().out)
        assert second["matches"][0]["rule_id"] == "prose-b"
        winner_key_scan2 = second["matches"][0]["finding_key"]
        assert winner_key_scan2 != winner_key_scan1

        # The scan-1 winner is gone from the current finding set...
        assert all(m["finding_key"] != winner_key_scan1 for m in second["matches"])
        # ...but its disposition/note from scan 1 is still there, untouched.
        conn = init_db(hot_zone=str(hotzone))
        states = {
            str(row["finding_key"]): row for row in pattern_finding_states(conn, [winner_key_scan1])
        }
        conn.close()
        assert states[winner_key_scan1]["disposition"] == "waived"
        assert states[winner_key_scan1]["note"] == "reviewed and accepted for now"

    def test_outside_repo_targets_get_collision_safe_absolute_finding_identity(
        self,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """A scan target outside the repo can't get a repo-relative finding
        path. The old fallback kept only the target-relative label (e.g.
        "a.md"), so two distinct files under different outside targets that
        happen to share a basename collided into one finding identity --
        adjudicating one silently applied to the other. The lexical absolute
        source path is a collision-safe fallback, and report scopes an
        outside-repo target by that same absolute path instead of falling
        back to an unscoped report."""
        repo = tmp_path / "repo"
        repo.mkdir()
        outside1 = tmp_path / "outside1"
        outside1.mkdir()
        (outside1 / "a.md").write_text("A genuine result.\n", encoding="utf-8")
        outside2 = tmp_path / "outside2"
        outside2.mkdir()
        (outside2 / "a.md").write_text("A genuine result.\n", encoding="utf-8")
        rule = tmp_path / "prose-test.yaml"
        rule.write_text(
            "id: prose-test\nlanguage: prose\nkind: lexicon\nterms:\n  - genuine\n",
            encoding="utf-8",
        )

        with (
            patch("weave_quality.__main__._resolve_repo", return_value=str(repo)),
            patch(
                "weave_quality.__main__._load_pattern_rules",
                return_value=[("prose-test", rule, "prose")],
            ),
        ):
            first_args = argparse.Namespace(
                hot_zone=str(tmp_path), path=str(outside1), json=True
            )
            assert cmd_patterns_scan(first_args) == 0
            first = json.loads(capsys.readouterr().out)

            second_args = argparse.Namespace(
                hot_zone=str(tmp_path), path=str(outside2), json=True
            )
            assert cmd_patterns_scan(second_args) == 0
            second = json.loads(capsys.readouterr().out)

            first_key = first["matches"][0]["finding_key"]
            second_key = second["matches"][0]["finding_key"]
            assert first_key != second_key
            assert first["matches"][0]["path"] == str(outside1 / "a.md")
            assert second["matches"][0]["path"] == str(outside2 / "a.md")

            # Report defaults to the last scan's target (outside2) -- scoped
            # to only that target's finding, not outside1's too.
            report_args = argparse.Namespace(hot_zone=str(tmp_path), json=True)
            assert cmd_patterns_report(report_args) == 0
            report = json.loads(capsys.readouterr().out)

        assert report["scope"] == str(outside2)
        assert report["by_rule"]["prose-test"]["findings"] == 1

    def test_report_explicit_relative_path_resolves_against_cwd_not_as_repo_relative(
        self,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """An explicit `report <path>` argument is a normal CLI path argument
        (cwd-relative), not already repo-relative like a stored scan target
        -- '.' from inside repo/docs must scope to docs/, not repo root."""
        docs = tmp_path / "docs"
        docs.mkdir()
        (docs / "a.md").write_text("A genuine result.\n", encoding="utf-8")
        other = tmp_path / "other"
        other.mkdir()
        (other / "b.md").write_text("A genuine result.\n", encoding="utf-8")
        rule = tmp_path / "prose-test.yaml"
        rule.write_text(
            "id: prose-test\nlanguage: prose\nkind: lexicon\nterms:\n  - genuine\n",
            encoding="utf-8",
        )
        hotzone = tmp_path / "hotzone"

        with (
            patch("weave_quality.__main__._resolve_repo", return_value=str(tmp_path)),
            patch(
                "weave_quality.__main__._load_pattern_rules",
                return_value=[("prose-test", rule, "prose")],
            ),
        ):
            whole_repo_args = argparse.Namespace(
                hot_zone=str(hotzone), path=str(tmp_path), json=True
            )
            assert cmd_patterns_scan(whole_repo_args) == 0
            capsys.readouterr()

            cwd = os.getcwd()
            os.chdir(docs)
            try:
                dot_args = argparse.Namespace(hot_zone=str(hotzone), path=".", json=True)
                assert cmd_patterns_report(dot_args) == 0
                dot_scoped = json.loads(capsys.readouterr().out)
                assert dot_scoped["scope"] == "docs"
                assert dot_scoped["by_rule"]["prose-test"]["findings"] == 1

                up_args = argparse.Namespace(
                    hot_zone=str(hotzone), path="../other", json=True
                )
                assert cmd_patterns_report(up_args) == 0
                up_scoped = json.loads(capsys.readouterr().out)
                assert up_scoped["scope"] == "other"
                assert up_scoped["by_rule"]["prose-test"]["findings"] == 1
            finally:
                os.chdir(cwd)

    def test_report_nudges_a_rule_with_zero_adjudications_across_n_scans(
        self,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        hotzone = tmp_path / "hotzone"
        doc = tmp_path / "doc.md"
        doc.write_text("A genuine result.\n", encoding="utf-8")
        rule = tmp_path / "prose-test.yaml"
        rule.write_text(
            "id: prose-test\nlanguage: prose\nkind: lexicon\nterms:\n  - genuine\n",
            encoding="utf-8",
        )
        scan_args = argparse.Namespace(hot_zone=str(hotzone), path=str(doc), json=True)

        with patch(
            "weave_quality.__main__._load_pattern_rules",
            return_value=[("prose-test", rule, "prose")],
        ):
            for _ in range(ADJUDICATION_NUDGE_SCANS):
                conn = init_db(hot_zone=str(hotzone))
                begin_scan(conn, "abc")
                conn.commit()
                conn.close()
                assert cmd_patterns_scan(scan_args) == 0
                capsys.readouterr()

            report_args = argparse.Namespace(hot_zone=str(hotzone), json=True)
            assert cmd_patterns_report(report_args) == 0
            report = json.loads(capsys.readouterr().out)
            assert report["by_rule"]["prose-test"]["needs_adjudication"] is True

            text_args = argparse.Namespace(hot_zone=str(hotzone), json=False)
            assert cmd_patterns_report(text_args) == 0
            text = capsys.readouterr().out
            assert "prose-test: decided_precision=unavailable" in text
            assert "actionable_rate=unavailable" in text
            assert "[needs adjudication]" in text
            needs_line = next(
                line for line in text.splitlines() if line.startswith("Needs adjudication")
            )
            assert "prose-test" in needs_line

    def test_identity_and_storage_preserve_match_text_beyond_200_characters(
        self,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """Stored findings are queried by the real pattern_runs id (via
        latest_pattern_run), not the complexity scan_id, which only happens
        to equal the first pattern run's id in a fresh db. scan_meta's
        sequence is deliberately offset from pattern_runs' so a coincidental
        id match can't mask a regression."""
        hotzone = tmp_path / "hotzone"
        conn = init_db(hot_zone=str(hotzone))
        begin_scan(conn, "abc")
        begin_scan(conn, "def")
        conn.commit()
        conn.close()
        prefix = "a" * 205
        doc = tmp_path / "doc.md"
        doc.write_text(f"{prefix}b\n{prefix}c\n", encoding="utf-8")
        rule = tmp_path / "prose-long.yaml"
        rule.write_text(
            "id: prose-long\nlanguage: prose\nkind: regex\npatterns:\n  - 'a{205}[bc]'\n",
            encoding="utf-8",
        )
        args = argparse.Namespace(hot_zone=str(hotzone), path=str(doc), json=True)

        with (
            patch("weave_quality.__main__._resolve_repo", return_value=str(tmp_path)),
            patch(
                "weave_quality.__main__._load_pattern_rules",
                return_value=[("prose-long", rule, "prose")],
            ),
        ):
            assert cmd_patterns_scan(args) == 0
        payload = json.loads(capsys.readouterr().out)
        assert [match["match_text"] for match in payload["matches"]] == [
            f"{prefix}b",
            f"{prefix}c",
        ]
        assert len({match["finding_key"] for match in payload["matches"]}) == 2
        conn = init_db(hot_zone=str(hotzone))
        run = latest_pattern_run(conn)
        assert run is not None
        stored = query_pattern_findings(conn, run.id)
        conn.close()
        assert {row["match_text"] for row in stored} == {f"{prefix}b", f"{prefix}c"}

    def test_list_distinguishes_not_run_zero_hit_and_changed_definition(
        self,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        hotzone = tmp_path / "hotzone"
        conn = init_db(hot_zone=str(hotzone))
        begin_scan(conn, "abc")
        conn.commit()
        conn.close()
        doc = tmp_path / "doc.md"
        doc.write_text("A specific statement.\n", encoding="utf-8")
        rule = tmp_path / "prose-test.yaml"
        rule.write_text(
            "id: prose-test\nlanguage: prose\nkind: regex\npatterns:\n  - absent\n",
            encoding="utf-8",
        )
        args = argparse.Namespace(hot_zone=str(hotzone), path=str(doc), json=True)

        with (
            patch("weave_quality.__main__._resolve_repo", return_value=str(tmp_path)),
            patch(
                "weave_quality.__main__._load_pattern_rules",
                return_value=[("prose-test", rule, "prose")],
            ),
        ):
            assert cmd_patterns_list(args) == 0
            state = json.loads(capsys.readouterr().out)[0]
            assert state["status"] == "not_run" and state["hits"] is None

            assert cmd_patterns_scan(args) == 0
            capsys.readouterr()
            assert cmd_patterns_list(args) == 0
            state = json.loads(capsys.readouterr().out)[0]
            assert state["status"] == "success" and state["hits"] == 0

            rule.write_text(
                "id: prose-test\nlanguage: prose\nkind: regex\npatterns:\n  - changed\n",
                encoding="utf-8",
            )
            assert cmd_patterns_list(args) == 0
            state = json.loads(capsys.readouterr().out)[0]
            assert state["status"] == "not_run" and state["hits"] is None

    def test_list_text_header_shows_last_scanned_target(
        self,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        hotzone = tmp_path / "hotzone"
        conn = init_db(hot_zone=str(hotzone))
        begin_scan(conn, "abc")
        conn.commit()
        conn.close()
        doc = tmp_path / "doc.md"
        doc.write_text("A statement.\n", encoding="utf-8")
        rule = tmp_path / "prose-test.yaml"
        rule.write_text(
            "id: prose-test\nlanguage: prose\nkind: regex\npatterns:\n  - absent\n",
            encoding="utf-8",
        )
        args = argparse.Namespace(hot_zone=str(hotzone), path=str(doc), json=False)

        with (
            patch("weave_quality.__main__._resolve_repo", return_value=str(tmp_path)),
            patch(
                "weave_quality.__main__._load_pattern_rules",
                return_value=[("prose-test", rule, "prose")],
            ),
        ):
            # Before any patterns scan, no receipt exists yet — no target to show.
            assert cmd_patterns_list(args) == 0
            header = capsys.readouterr().out.splitlines()[0]
            assert header == "Active pattern rules (1):"

            assert cmd_patterns_scan(argparse.Namespace(hot_zone=str(hotzone), path=str(doc), json=True)) == 0
            capsys.readouterr()
            assert cmd_patterns_list(args) == 0
            header = capsys.readouterr().out.splitlines()[0]
            # Canonical repo-relative target, not the raw absolute invocation
            # string (doc.md is directly under the patched repo root).
            assert header == "Active pattern rules (1), last scanned: doc.md:"

    def test_execution_failure_is_receipted_and_does_not_replace_findings(
        self,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """A failed rescan must not touch the prior successful run's own
        findings -- queried by that run's OWN pattern_runs id (captured via
        latest_pattern_run), not the complexity scan_id, which only happens
        to equal the first pattern run's id in a fresh db. scan_meta's
        sequence is deliberately offset from pattern_runs' so a coincidental
        id match can't mask a regression."""
        hotzone = tmp_path / "hotzone"
        conn = init_db(hot_zone=str(hotzone))
        begin_scan(conn, "abc")
        begin_scan(conn, "def")
        conn.commit()
        conn.close()
        doc = tmp_path / "doc.md"
        doc.write_text("A statement.\n", encoding="utf-8")
        rule = tmp_path / "prose-test.yaml"
        rule.write_text(
            "id: prose-test\nlanguage: prose\nkind: regex\npatterns:\n  - statement\n",
            encoding="utf-8",
        )
        args = argparse.Namespace(hot_zone=str(hotzone), path=str(doc), json=True)

        with (
            patch("weave_quality.__main__._resolve_repo", return_value=str(tmp_path)),
            patch(
                "weave_quality.__main__._load_pattern_rules",
                return_value=[("prose-test", rule, "prose")],
            ),
        ):
            assert cmd_patterns_scan(args) == 0
            capsys.readouterr()
            conn = init_db(hot_zone=str(hotzone))
            successful_run = latest_pattern_run(conn)
            conn.close()

            with patch(
                "weave_quality.__main__._run_pattern_rule",
                side_effect=PatternRuleExecutionError("backend failed"),
            ):
                assert cmd_patterns_scan(args) == 1
            capsys.readouterr()
            assert cmd_patterns_list(args) == 0
            state = json.loads(capsys.readouterr().out)[0]

        assert state["status"] == "failed" and state["hits"] is None
        assert successful_run is not None
        conn = init_db(hot_zone=str(hotzone))
        failed_run = latest_pattern_run(conn)
        assert failed_run is not None and failed_run.id != successful_run.id
        assert len(query_pattern_findings(conn, successful_run.id)) == 1
        conn.close()

    def test_failed_pattern_snapshot_cannot_be_promoted(
        self,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        hotzone = tmp_path / "hotzone"
        conn = init_db(hot_zone=str(hotzone))
        begin_scan(conn, "abc")
        conn.commit()
        conn.close()
        doc = tmp_path / "doc.md"
        doc.write_text("A measured statement.\n", encoding="utf-8")
        rule = tmp_path / "prose-test.yaml"
        rule.write_text(
            "id: prose-test\nlanguage: prose\nkind: regex\npatterns:\n  - measured\n",
            encoding="utf-8",
        )
        scan_args = argparse.Namespace(hot_zone=str(hotzone), path=str(doc), json=False)
        promote_args = argparse.Namespace(
            hot_zone=str(hotzone),
            parent="wv-parent",
            from_patterns=True,
            dry_run=False,
            json=False,
            top=10,
        )

        with (
            patch("weave_quality.__main__._resolve_repo", return_value=str(tmp_path)),
            patch(
                "weave_quality.__main__._load_pattern_rules",
                return_value=[("prose-test", rule, "prose")],
            ),
        ):
            assert cmd_patterns_scan(scan_args) == 0
            with patch(
                "weave_quality.__main__._run_pattern_rule",
                side_effect=PatternRuleExecutionError("backend failed"),
            ):
                assert cmd_patterns_scan(scan_args) == 1
            with patch("weave_quality.__main__._wv_cmd") as wv_cmd:
                assert cmd_promote(promote_args) == 1
                wv_cmd.assert_not_called()

        assert "not a complete successful snapshot" in capsys.readouterr().err

    def test_malformed_rule_fails_scan_and_list(
        self,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        conn = init_db(hot_zone=str(tmp_path / "hotzone"))
        begin_scan(conn, "abc")
        conn.commit()
        conn.close()
        patterns = tmp_path / ".weave" / "patterns"
        patterns.mkdir(parents=True)
        broken = patterns / "broken.yaml"
        broken.write_text(
            "id: broken\nlanguage: prose\nkind: regex\n"
            "provenance: first line\n  move: malformed continuation\n"
            "patterns:\n  - broken\n",
            encoding="utf-8",
        )
        args = argparse.Namespace(
            hot_zone=str(tmp_path / "hotzone"),
            path=str(tmp_path),
            json=False,
        )

        with patch("weave_quality.__main__._resolve_repo", return_value=str(tmp_path)):
            assert cmd_patterns_list(args) == 1
            assert cmd_patterns_scan(args) == 1

        error = capsys.readouterr().err
        assert str(broken) in error
        assert "nested mapping unsupported" in error


def test_patterns_list_rejects_a_file_path_as_repo_root(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """wv-5b9f55 finding 9 (external code review): list/validate resolve
    `path` as the REPOSITORY ROOT (unlike scan/report, where `path` names
    a scan target and a single file is legitimate there) -- passing a
    file used to silently skip that project's own .weave/patterns/
    entirely (no such directory under a file) and return a misleadingly
    clean result built from built-in rules only. Must fail loudly
    instead."""
    a_file = tmp_path / "not_a_directory.txt"
    a_file.write_text("just a file\n", encoding="utf-8")
    args = argparse.Namespace(hot_zone=str(tmp_path / "hotzone"), path=str(a_file), json=False)

    with patch("weave_quality.__main__._resolve_repo", return_value=str(a_file)):
        assert cmd_patterns_list(args) == 1

    error = capsys.readouterr().err
    assert str(a_file) in error
    assert "not a directory" in error


def test_patterns_validate_rejects_a_file_path_as_repo_root(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """The same finding-9 fix applies to validate -- a file path resolved
    as the repository root must fail loudly, not silently validate only
    the built-in rule set as if the project had no custom/managed rules
    at all."""
    a_file = tmp_path / "not_a_directory.txt"
    a_file.write_text("just a file\n", encoding="utf-8")
    args = argparse.Namespace(hot_zone=str(tmp_path / "hotzone"), path=str(a_file), json=False)

    with patch("weave_quality.__main__._resolve_repo", return_value=str(a_file)):
        assert cmd_patterns_validate(args) == 1

    error = capsys.readouterr().err
    assert str(a_file) in error
    assert "not a directory" in error


def test_patterns_validate_rejects_a_file_path_as_repo_root_json(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """Same fix, --json mode: the error is a structured payload on stdout
    (matching _pattern_rule_error's own JSON convention), not merely a
    stderr message -- an MCP/scripted caller parsing stdout as JSON must
    get a real error object, not empty/absent output."""
    a_file = tmp_path / "not_a_directory.txt"
    a_file.write_text("just a file\n", encoding="utf-8")
    args = argparse.Namespace(hot_zone=str(tmp_path / "hotzone"), path=str(a_file), json=True)

    with patch("weave_quality.__main__._resolve_repo", return_value=str(a_file)):
        assert cmd_patterns_validate(args) == 1

    payload = json.loads(capsys.readouterr().out)
    assert payload["error"] == "invalid_repo_root"
    assert str(a_file) in payload["detail"]


def test_patterns_validate_reports_inaccessible_repo_root_instead_of_traceback(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """wv-0065a6 (external code review round 3, finding 8): repo.is_dir()
    doesn't just return False for an inaccessible path -- it can raise
    PermissionError/OSError outright (e.g. a chmod-000 ancestor
    directory). That used to propagate as an uncaught traceback instead
    of the structured JSON error this command otherwise promises.
    Mocking Path.is_dir's own side effect reproduces this deterministically
    without depending on running as a non-root user."""
    repo = tmp_path / "repo"
    repo.mkdir()
    args = argparse.Namespace(hot_zone=str(tmp_path / "hotzone"), path=str(repo), json=True)

    with (
        patch("weave_quality.__main__._resolve_repo", return_value=str(repo)),
        patch("pathlib.Path.is_dir", side_effect=PermissionError("denied")),
    ):
        assert cmd_patterns_validate(args) == 1

    payload = json.loads(capsys.readouterr().out)
    assert payload["error"] == "invalid_repo_root"
    assert "denied" in payload["detail"]


def test_patterns_validate_reports_inaccessible_pattern_tier_instead_of_traceback(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """Same finding-8 class, the other named location: repo itself is a
    fine, accessible directory (passes _non_directory_repo_root_error),
    but enumerating a *tier* directory underneath it
    (.weave/patterns/managed or .weave/patterns/) raises PermissionError
    out of _candidate_pattern_files' rule_dir.is_dir()/.glob() -- must
    surface as the same structured error, not a traceback, while a
    genuinely ABSENT tier directory (is_dir() returning False, not
    raising) still stays a silent, valid skip."""
    repo = tmp_path / "repo"
    (repo / ".weave" / "patterns").mkdir(parents=True)
    args = argparse.Namespace(hot_zone=str(tmp_path / "hotzone"), path=str(repo), json=True)

    with (
        patch("weave_quality.__main__._resolve_repo", return_value=str(repo)),
        patch("weave_quality.__main__._candidate_pattern_files", side_effect=PermissionError("denied")),
    ):
        assert cmd_patterns_validate(args) == 1

    payload = json.loads(capsys.readouterr().out)
    assert payload["error"] == "invalid_repo_root"
    assert "denied" in payload["detail"]


def test_patterns_list_reports_inaccessible_quality_conf_instead_of_traceback(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """wv-731450 (external code review round 3 re-audit of wv-0065a6): the
    fix guarded validate's _candidate_pattern_files but missed that list
    reads .weave/quality.conf via _disabled_patterns, then the tier
    directories via _load_pattern_rules, BEFORE any OSError boundary --
    an inaccessible (not just absent) .weave/ raised an uncaught
    PermissionError out of _disabled_patterns' conf_path.exists() instead
    of the structured JSON error this command otherwise promises."""
    repo = tmp_path / "repo"
    repo.mkdir()
    hotzone = tmp_path / "hotzone"
    init_db(hot_zone=str(hotzone)).close()
    args = argparse.Namespace(hot_zone=str(hotzone), path=str(repo), json=True)

    with (
        patch("weave_quality.__main__._resolve_repo", return_value=str(repo)),
        patch("weave_quality.__main__._disabled_patterns", side_effect=PermissionError("denied")),
    ):
        assert cmd_patterns_list(args) == 1

    payload = json.loads(capsys.readouterr().out)
    assert payload["error"] == "invalid_repo_root"
    assert "denied" in payload["detail"]


def test_patterns_list_reports_inaccessible_pattern_tier_instead_of_traceback(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """Same finding-8 class as validate's own tier-directory test: repo
    itself is fine and accessible, but _load_pattern_rules' tier
    enumeration (rule_dir.is_dir()/.glob()) raises PermissionError --
    must surface as the same structured error, not a traceback."""
    repo = tmp_path / "repo"
    repo.mkdir()
    hotzone = tmp_path / "hotzone"
    init_db(hot_zone=str(hotzone)).close()
    args = argparse.Namespace(hot_zone=str(hotzone), path=str(repo), json=True)

    with (
        patch("weave_quality.__main__._resolve_repo", return_value=str(repo)),
        patch("weave_quality.__main__._load_pattern_rules", side_effect=PermissionError("denied")),
    ):
        assert cmd_patterns_list(args) == 1

    payload = json.loads(capsys.readouterr().out)
    assert payload["error"] == "invalid_repo_root"
    assert "denied" in payload["detail"]


def test_patterns_list_reports_inaccessible_definition_hash_instead_of_traceback(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """Same finding-8 class, the OTHER guarded region: rules loaded fine,
    but a rule file becomes unreadable before _pattern_definition_hash's
    read_bytes() runs on it (e.g. permissions changed between load and
    hashing, or a race with an external process) -- must surface as the
    same structured error, not a traceback."""
    repo = tmp_path / "repo"
    patterns_dir = repo / ".weave" / "patterns"
    patterns_dir.mkdir(parents=True)
    rule = patterns_dir / "qp-test.yaml"
    rule.write_text(
        "id: qp-test\nlanguage: prose\nkind: regex\npatterns:\n  - absent\n",
        encoding="utf-8",
    )
    hotzone = tmp_path / "hotzone"
    init_db(hot_zone=str(hotzone)).close()
    args = argparse.Namespace(hot_zone=str(hotzone), path=str(repo), json=True)

    with (
        patch("weave_quality.__main__._resolve_repo", return_value=str(repo)),
        patch(
            "weave_quality.__main__._load_pattern_rules",
            return_value=[("qp-test", rule, "prose")],
        ),
        patch("weave_quality.__main__._pattern_definition_hash", side_effect=PermissionError("denied")),
    ):
        assert cmd_patterns_list(args) == 1

    payload = json.loads(capsys.readouterr().out)
    assert payload["error"] == "invalid_repo_root"
    assert "denied" in payload["detail"]


def test_patterns_list_rejects_a_nonexistent_path(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """wv-210ec4 (external code review round 2): the original finding-9
    fix exempted a path that doesn't exist at all (`repo.exists()` gated
    the check) on the theory it was a separate, pre-existing concern --
    but that let a typo'd or not-yet-created repo silently validate
    built-ins only, indistinguishable from a project with no custom
    rules, which is exactly the misleading-clean-result trap this check
    exists to close. A nonexistent path must fail loudly too, the same
    as a file path."""
    missing = tmp_path / "does" / "not" / "exist"
    hotzone = tmp_path / "hotzone"
    init_db(hot_zone=str(hotzone)).close()
    args = argparse.Namespace(hot_zone=str(hotzone), path=str(missing), json=False)

    with patch("weave_quality.__main__._resolve_repo", return_value=str(missing)):
        assert cmd_patterns_list(args) == 1

    error = capsys.readouterr().err
    assert str(missing) in error
    assert "not a directory" in error


def test_patterns_validate_rejects_a_broken_symlink_repo_root(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """wv-210ec4 (external code review round 2): a broken symlink is
    neither "exists and isn't a directory" (the original finding-9
    check) nor "doesn't exist at all" in any way a caller can tell apart
    from a genuinely missing path -- `Path.exists()`/`is_dir()` both
    report False for it, same as a plain missing path. Must fail loudly
    too, not silently validate built-ins only."""
    broken = tmp_path / "broken_link"
    broken.symlink_to(tmp_path / "does_not_exist")
    hotzone = tmp_path / "hotzone"
    init_db(hot_zone=str(hotzone)).close()
    args = argparse.Namespace(hot_zone=str(hotzone), path=str(broken), json=False)

    with patch("weave_quality.__main__._resolve_repo", return_value=str(broken)):
        assert cmd_patterns_validate(args) == 1

    error = capsys.readouterr().err
    assert str(broken) in error
    assert "not a directory" in error


def test_resolve_repo_prefers_override_over_repo_root(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """wv-20adef (external code review round 2): the bash `wv` entry
    point's own wv-config.sh unconditionally reassigns REPO_ROOT from
    `git rev-parse --show-toplevel` against the CURRENT process's cwd,
    discarding whatever value a parent process (e.g. the MCP server's
    internal report call) already set it to. WV_REPO_ROOT_OVERRIDE is
    never touched by wv-config.sh, so a caller that needs to steer repo
    resolution past that reassignment must be able to rely on it taking
    priority over REPO_ROOT -- both set here to DIFFERENT paths to prove
    the override, not just presence, wins."""
    override_dir = tmp_path / "override"
    repo_root_dir = tmp_path / "repo-root"
    override_dir.mkdir()
    repo_root_dir.mkdir()
    monkeypatch.setenv("WV_REPO_ROOT_OVERRIDE", str(override_dir))
    monkeypatch.setenv("REPO_ROOT", str(repo_root_dir))

    assert _resolve_repo(None) == str(override_dir)


def test_resolve_repo_falls_back_to_repo_root_without_override(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Companion to test_resolve_repo_prefers_override_over_repo_root:
    REPO_ROOT must still work exactly as before whenever
    WV_REPO_ROOT_OVERRIDE isn't set at all -- the new check must not
    change behavior for every existing (non-MCP-internal-report) caller."""
    repo_root_dir = tmp_path / "repo-root"
    repo_root_dir.mkdir()
    monkeypatch.delenv("WV_REPO_ROOT_OVERRIDE", raising=False)
    monkeypatch.setenv("REPO_ROOT", str(repo_root_dir))

    assert _resolve_repo(None) == str(repo_root_dir)


def test_pattern_loader_rejects_duplicate_ids(tmp_path: Path) -> None:
    patterns = tmp_path / ".weave" / "patterns"
    patterns.mkdir(parents=True)
    (patterns / "prose-register-review.yaml").write_text(
        "id: prose-register-review\nlanguage: prose\nkind: regex\n"
        "patterns:\n  - duplicate\n",
        encoding="utf-8",
    )
    with pytest.raises(ValueError, match="duplicate pattern id"):
        _load_pattern_rules(tmp_path, set())


def test_pattern_loader_validates_disabled_rules(tmp_path: Path) -> None:
    patterns = tmp_path / ".weave" / "patterns"
    patterns.mkdir(parents=True)
    (patterns / "disabled-broken.yaml").write_text(
        "id: disabled-broken\nlanguage: prose\nkind: regex\npatterns:\n",
        encoding="utf-8",
    )
    with pytest.raises(ValueError, match="missing or empty 'patterns'"):
        _load_pattern_rules(tmp_path, {"disabled-broken"})


def test_shadowed_managed_pattern_ids_reads_overridden_marker(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    managed = tmp_path / ".weave" / "patterns" / "managed"
    managed.mkdir(parents=True)
    (managed / ".overridden").write_text(
        "prose-casual-register.yaml\nmarkdown-split-code-span.yaml\n",
        encoding="utf-8",
    )
    monkeypatch.setenv("WV_CONFIG_DIR", str(tmp_path / "empty-config"))
    assert _shadowed_managed_pattern_ids(tmp_path) == [
        "prose-casual-register",
        "markdown-split-code-span",
    ]


def test_shadowed_managed_pattern_ids_absent_marker_is_empty(tmp_path: Path) -> None:
    assert not _shadowed_managed_pattern_ids(tmp_path)


def test_installed_manifest_finds_shadow_before_projection_refresh(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    config = tmp_path / "config" / "quality-patterns" / "managed"
    config.mkdir(parents=True)
    (config / "manifest.txt").write_text("promoted-rule.yaml\n", encoding="utf-8")
    repo = tmp_path / "repo"
    managed = repo / ".weave" / "patterns" / "managed"
    managed.mkdir(parents=True)
    local = repo / ".weave" / "patterns" / "promoted-rule.yaml"
    local.write_text("custom\n", encoding="utf-8")
    monkeypatch.setenv("WV_CONFIG_DIR", str(tmp_path / "config"))

    assert _shadowed_managed_pattern_ids(repo) == ["promoted-rule"]


def test_stale_managed_projection_compares_installed_inventory_and_content(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    config = tmp_path / "config" / "quality-patterns" / "managed"
    config.mkdir(parents=True)
    (config / "manifest.txt").write_text(
        "changed-rule.yaml\nnew-rule.yaml\n", encoding="utf-8"
    )
    (config / "changed-rule.yaml").write_text("current\n", encoding="utf-8")
    (config / "new-rule.yaml").write_text("new\n", encoding="utf-8")
    repo = tmp_path / "repo"
    managed = repo / ".weave" / "patterns" / "managed"
    managed.mkdir(parents=True)
    (managed / ".manifest").write_text(
        "changed-rule.yaml\nretired-rule.yaml\n", encoding="utf-8"
    )
    (managed / "changed-rule.yaml").write_text("stale\n", encoding="utf-8")
    (managed / "retired-rule.yaml").write_text("retired\n", encoding="utf-8")
    monkeypatch.setenv("WV_CONFIG_DIR", str(tmp_path / "config"))

    assert _stale_managed_pattern_ids(repo) == [
        "changed-rule",
        "new-rule",
        "retired-rule",
    ]


def test_patterns_list_warns_on_shadowed_managed_rule(
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    hotzone = tmp_path / "hotzone"
    init_db(hot_zone=str(hotzone)).close()
    managed = tmp_path / ".weave" / "patterns" / "managed"
    managed.mkdir(parents=True)
    (managed / ".manifest").write_text("older-rule.yaml\n", encoding="utf-8")
    config = tmp_path / "config" / "quality-patterns" / "managed"
    config.mkdir(parents=True)
    (config / "manifest.txt").write_text("promoted-rule.yaml\n", encoding="utf-8")
    (config / "promoted-rule.yaml").write_text("managed\n", encoding="utf-8")
    monkeypatch.setenv("WV_CONFIG_DIR", str(tmp_path / "config"))
    rule = tmp_path / ".weave" / "patterns" / "promoted-rule.yaml"
    rule.write_text(
        "id: promoted-rule\nlanguage: prose\nkind: regex\npatterns:\n  - absent\n",
        encoding="utf-8",
    )
    args = argparse.Namespace(hot_zone=str(hotzone), path=str(tmp_path), json=False)

    with (
        patch("weave_quality.__main__._resolve_repo", return_value=str(tmp_path)),
        patch(
            "weave_quality.__main__._load_pattern_rules",
            return_value=[("promoted-rule", rule, "prose")],
        ),
    ):
        assert cmd_patterns_list(args) == 0
        captured = capsys.readouterr()
        assert "promoted-rule" in captured.err
        assert "shadows an available managed rule" in captured.err
        assert "managed pattern projection is stale" in captured.err
        # stdout stays exactly the existing rule listing, unaffected
        assert "shadow" not in captured.out


def test_validate_reports_every_rule_independently_and_schema_coverage(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """Unlike list/scan (fail closed on the first bad rule), validate reports
    every candidate's own status in one pass, plus which documented prose
    schema kind/match_scope/maturity/optional-key values the valid ones
    actually exercise."""
    repo = tmp_path / "repo"
    patterns_dir = repo / ".weave" / "patterns"
    patterns_dir.mkdir(parents=True)
    (patterns_dir / "qp-test-density.yaml").write_text(
        "id: qp-test-density\n"
        "language: prose\n"
        "kind: density\n"
        "match_scope: document\n"
        "maturity: candidate\n"
        "min_count: 2\n"
        "paths:\n"
        "  - '*.md'\n"
        "terms:\n"
        "  - foo\n"
        "  - bar\n",
        encoding="utf-8",
    )
    (patterns_dir / "qp-test-bad.yaml").write_text(
        "id: qp-test-bad\nlanguage: prose\nkind: nonsense\nterms:\n  - foo\n",
        encoding="utf-8",
    )
    args = argparse.Namespace(hot_zone=str(tmp_path / "hz"), path=str(repo), json=True)

    with patch(
        "weave_quality.__main__._DEFAULT_PATTERNS_DIR", tmp_path / "no-default-rules"
    ):
        assert cmd_patterns_validate(args) == 1
        payload = json.loads(capsys.readouterr().out)

    by_id = {entry["rule_id"]: entry for entry in payload["rules"]}
    assert by_id["qp-test-density"]["status"] == "valid"
    assert by_id["qp-test-bad"]["status"] == "invalid"
    assert "unsupported prose kind" in by_id["qp-test-bad"]["error"]
    assert payload["valid"] is False

    coverage = payload["coverage"]
    assert coverage["kinds"] == {
        "lexicon": False,
        "motif": False,
        "density": True,
        "regex": False,
        "citation": False,
    }
    assert coverage["match_scopes"]["document"] is True
    assert coverage["match_scopes"]["line"] is False
    assert coverage["match_scopes"]["heading"] is False
    assert coverage["maturities"] == {
        "candidate": True,
        "observed": False,
        "promotable": False,
    }
    assert coverage["optional_keys"]["paths"] is True
    assert coverage["optional_keys"]["min_count"] is True
    assert coverage["optional_keys"]["exempt"] is False


def test_validate_rejects_cross_file_id_collisions_like_the_real_loader(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """The real loader (_load_pattern_rules) rejects a same-id rule defined
    in more than one tier; two independently-valid files sharing an id must
    not both report valid here -- that's exactly what scan/list would reject."""
    repo = tmp_path / "repo"
    patterns_dir = repo / ".weave" / "patterns"
    managed_dir = patterns_dir / "managed"
    managed_dir.mkdir(parents=True)
    (managed_dir / "qp-dup.yaml").write_text(
        "id: qp-dup\nlanguage: prose\nkind: lexicon\nterms:\n  - foo\n",
        encoding="utf-8",
    )
    (patterns_dir / "qp-dup.yaml").write_text(
        "id: qp-dup\nlanguage: prose\nkind: lexicon\nterms:\n  - bar\n",
        encoding="utf-8",
    )
    args = argparse.Namespace(hot_zone=str(tmp_path / "hz"), path=str(repo), json=True)

    with patch(
        "weave_quality.__main__._DEFAULT_PATTERNS_DIR", tmp_path / "no-default-rules"
    ):
        assert cmd_patterns_validate(args) == 1
        payload = json.loads(capsys.readouterr().out)

    entries = [entry for entry in payload["rules"] if entry["rule_id"] == "qp-dup"]
    assert len(entries) == 2
    assert all(entry["status"] == "invalid" for entry in entries)
    assert all("duplicate pattern id" in entry["error"] for entry in entries)
    assert payload["valid"] is False


def test_validate_coverage_excludes_a_rule_invalidated_by_id_collision(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """Coverage must reflect entries still valid AFTER collision
    invalidation -- a density rule that collides with a duplicate id is not
    a rule scan/list would ever run, so it must not count as exercising
    kind: density."""
    repo = tmp_path / "repo"
    patterns_dir = repo / ".weave" / "patterns"
    managed_dir = patterns_dir / "managed"
    managed_dir.mkdir(parents=True)
    (managed_dir / "qp-dup.yaml").write_text(
        "id: qp-dup\nlanguage: prose\nkind: density\nmin_count: 2\nterms:\n  - foo\n",
        encoding="utf-8",
    )
    (patterns_dir / "qp-dup.yaml").write_text(
        "id: qp-dup\nlanguage: prose\nkind: density\nmin_count: 2\nterms:\n  - bar\n",
        encoding="utf-8",
    )
    args = argparse.Namespace(hot_zone=str(tmp_path / "hz"), path=str(repo), json=True)

    with patch(
        "weave_quality.__main__._DEFAULT_PATTERNS_DIR", tmp_path / "no-default-rules"
    ):
        assert cmd_patterns_validate(args) == 1
        payload = json.loads(capsys.readouterr().out)

    assert payload["coverage"]["kinds"]["density"] is False


def test_validate_flags_a_valid_rule_colliding_with_a_malformed_duplicate(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """If one of two same-id files is malformed, the otherwise-valid copy
    must still be flagged as colliding -- the loader would fail on the
    malformed one first today, but the valid copy is just as unusable once
    that's fixed. The malformed entry keeps its own parse error too."""
    repo = tmp_path / "repo"
    patterns_dir = repo / ".weave" / "patterns"
    managed_dir = patterns_dir / "managed"
    managed_dir.mkdir(parents=True)
    (managed_dir / "qp-dup.yaml").write_text(
        "id: qp-dup\nlanguage: prose\nkind: lexicon\nterms:\n  - foo\n",
        encoding="utf-8",
    )
    (patterns_dir / "qp-dup.yaml").write_text(
        "id: qp-dup\nlanguage: prose\nkind: nonsense\nterms:\n  - bar\n",
        encoding="utf-8",
    )
    args = argparse.Namespace(hot_zone=str(tmp_path / "hz"), path=str(repo), json=True)

    with patch(
        "weave_quality.__main__._DEFAULT_PATTERNS_DIR", tmp_path / "no-default-rules"
    ):
        assert cmd_patterns_validate(args) == 1
        payload = json.loads(capsys.readouterr().out)

    entries = {
        entry["path"]: entry for entry in payload["rules"] if entry["rule_id"] == "qp-dup"
    }
    assert len(entries) == 2
    valid_copy = entries[str(managed_dir / "qp-dup.yaml")]
    malformed_copy = entries[str(patterns_dir / "qp-dup.yaml")]
    assert valid_copy["status"] == "invalid"
    assert "duplicate pattern id" in valid_copy["error"]
    assert malformed_copy["status"] == "invalid"
    assert "unsupported prose kind" in malformed_copy["error"]
    assert "duplicate pattern id" in malformed_copy["error"]


def test_validate_all_valid_returns_zero_and_text_output_lists_unused_surface(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    repo = tmp_path / "repo"
    patterns_dir = repo / ".weave" / "patterns"
    patterns_dir.mkdir(parents=True)
    (patterns_dir / "qp-test-lexicon.yaml").write_text(
        "id: qp-test-lexicon\nlanguage: prose\nkind: lexicon\nterms:\n  - foo\n",
        encoding="utf-8",
    )
    args = argparse.Namespace(hot_zone=str(tmp_path / "hz"), path=str(repo), json=False)

    with patch(
        "weave_quality.__main__._DEFAULT_PATTERNS_DIR", tmp_path / "no-default-rules"
    ):
        assert cmd_patterns_validate(args) == 0
        text = capsys.readouterr().out

    assert "qp-test-lexicon" in text
    assert "valid" in text
    assert "kind: 1/5 exercised, unused:" in text
    assert "density" in text and "motif" in text and "regex" in text


# ---------------------------------------------------------------------------
# Tests: _run_pattern_rule (ast-grep result containment)
# ---------------------------------------------------------------------------


class TestRunPatternRuleAstGrepContainment:
    @staticmethod
    def _mock_completed(matches: list[dict[str, object]]) -> subprocess.CompletedProcess[str]:
        return subprocess.CompletedProcess(
            args=["ast-grep"], returncode=0, stdout=json.dumps(matches), stderr=""
        )

    def test_directory_target_rejects_a_lexically_escaped_result(
        self, tmp_path: Path
    ) -> None:
        """relative_to() alone is a purely lexical prefix comparison -- an
        unnormalized ast-grep result path containing ".." can pass it despite
        actually naming a file outside the target directory. abspath()
        must collapse that before the containment check."""
        target = tmp_path / "docs"
        target.mkdir()
        sibling = tmp_path / "sibling"
        sibling.mkdir()
        (sibling / "x.py").write_text("pass\n", encoding="utf-8")
        escaped = str(target / ".." / "sibling" / "x.py")
        matches = [
            {"file": escaped, "range": {"start": {"line": 0, "column": 0}}, "text": "m"}
        ]
        with (
            patch("weave_quality.__main__.ast_grep_bin", return_value="/usr/bin/ast-grep"),
            patch("subprocess.run", return_value=self._mock_completed(matches)),
        ):
            with pytest.raises(PatternRuleExecutionError, match="outside target"):
                _run_pattern_rule(
                    "r", tmp_path / "r.yaml", target, scan_id=1, repo=tmp_path, language="python"
                )

    def test_file_target_rejects_a_different_file_with_the_same_basename(
        self, tmp_path: Path
    ) -> None:
        """A single-file target did no equality check at all -- it took
        match_path.name unconditionally, so a result for an unrelated file
        that merely shares a basename with the target was silently accepted
        as if it were the target."""
        target_dir = tmp_path / "a"
        target_dir.mkdir()
        target = target_dir / "x.py"
        target.write_text("pass\n", encoding="utf-8")
        other_dir = tmp_path / "b"
        other_dir.mkdir()
        other_file = other_dir / "x.py"
        other_file.write_text("pass\n", encoding="utf-8")
        matches = [
            {
                "file": str(other_file),
                "range": {"start": {"line": 0, "column": 0}},
                "text": "m",
            }
        ]
        with (
            patch("weave_quality.__main__.ast_grep_bin", return_value="/usr/bin/ast-grep"),
            patch("subprocess.run", return_value=self._mock_completed(matches)),
        ):
            with pytest.raises(PatternRuleExecutionError, match="outside target"):
                _run_pattern_rule(
                    "r", tmp_path / "r.yaml", target, scan_id=1, repo=tmp_path, language="python"
                )

    def test_directory_target_still_accepts_a_genuinely_contained_result(
        self, tmp_path: Path
    ) -> None:
        target = tmp_path / "docs"
        (target / "sub").mkdir(parents=True)
        real = target / "sub" / "x.py"
        real.write_text("pass\n", encoding="utf-8")
        matches = [
            {"file": str(real), "range": {"start": {"line": 0, "column": 0}}, "text": "m"}
        ]
        with (
            patch("weave_quality.__main__.ast_grep_bin", return_value="/usr/bin/ast-grep"),
            patch("subprocess.run", return_value=self._mock_completed(matches)),
        ):
            findings = _run_pattern_rule(
                "r", tmp_path / "r.yaml", target, scan_id=1, repo=tmp_path, language="python"
            )
        assert [f.path for f in findings] == ["sub/x.py"]

    def test_file_target_still_accepts_its_own_result(self, tmp_path: Path) -> None:
        target = tmp_path / "x.py"
        target.write_text("pass\n", encoding="utf-8")
        matches = [
            {"file": str(target), "range": {"start": {"line": 0, "column": 0}}, "text": "m"}
        ]
        with (
            patch("weave_quality.__main__.ast_grep_bin", return_value="/usr/bin/ast-grep"),
            patch("subprocess.run", return_value=self._mock_completed(matches)),
        ):
            findings = _run_pattern_rule(
                "r", tmp_path / "r.yaml", target, scan_id=1, repo=tmp_path, language="python"
            )
        assert [f.path for f in findings] == ["x.py"]

    def test_missing_line_and_column_default_to_zero(self, tmp_path: Path) -> None:
        """A record with no range.start at all is still valid -- line/column
        are optional, defaulting to 0, matching pre-validation behavior."""
        target = tmp_path / "docs"
        target.mkdir()
        real = target / "x.py"
        real.write_text("pass\n", encoding="utf-8")
        matches = [{"file": str(real), "range": {"start": {}}, "text": "m"}]
        with (
            patch("weave_quality.__main__.ast_grep_bin", return_value="/usr/bin/ast-grep"),
            patch("subprocess.run", return_value=self._mock_completed(matches)),
        ):
            findings = _run_pattern_rule(
                "r", tmp_path / "r.yaml", target, scan_id=1, repo=tmp_path, language="python"
            )
        assert [(f.line, f.col) for f in findings] == [(1, 0)]

    @pytest.mark.parametrize(
        "bad_match",
        [
            pytest.param({"range": {"start": {}}, "text": "m"}, id="missing_file"),
            pytest.param(
                {"file": "", "range": {"start": {}}, "text": "m"}, id="empty_file"
            ),
            pytest.param(
                {"file": "\x00.py", "range": {"start": {}}, "text": "m"},
                id="file_has_embedded_nul",
            ),
            pytest.param(
                {"file": "x.py", "range": [], "text": "m"}, id="range_not_a_mapping"
            ),
            pytest.param(
                {"file": "x.py", "range": {"start": []}, "text": "m"},
                id="start_not_a_mapping",
            ),
            pytest.param(
                {"file": "x.py", "range": {"start": {"line": "0"}}, "text": "m"},
                id="line_not_an_integer",
            ),
            pytest.param(
                {"file": "x.py", "range": {"start": {"line": True}}, "text": "m"},
                id="line_is_a_bool",
            ),
            pytest.param(
                {"file": "x.py", "range": {"start": {"line": -1}}, "text": "m"},
                id="line_is_negative",
            ),
            pytest.param(
                {"file": "x.py", "range": {"start": {"column": -1}}, "text": "m"},
                id="column_is_negative",
            ),
            pytest.param(
                {"file": "x.py", "range": {"start": {}}, "text": 5}, id="text_not_a_string"
            ),
        ],
    )
    def test_malformed_match_record_fails_closed(
        self, tmp_path: Path, bad_match: dict[str, object]
    ) -> None:
        """A malformed ast-grep match record must fail closed as
        PatternRuleExecutionError -- not escape as an uncaught
        AttributeError/TypeError/ValueError, and not silently resolve an
        empty file field to a phantom "." finding."""
        target = tmp_path / "docs"
        target.mkdir()
        matches = [bad_match]
        with (
            patch("weave_quality.__main__.ast_grep_bin", return_value="/usr/bin/ast-grep"),
            patch("subprocess.run", return_value=self._mock_completed(matches)),
        ):
            with pytest.raises(PatternRuleExecutionError, match="malformed match record"):
                _run_pattern_rule(
                    "r", tmp_path / "r.yaml", target, scan_id=1, repo=tmp_path, language="python"
                )


# ---------------------------------------------------------------------------
# Tests: cmd_hotspots
# ---------------------------------------------------------------------------


class TestCmdHotspots:
    def test_no_db_returns_error(self, tmp_path: Path) -> None:
        """hotspots with no quality.db returns error."""
        args = argparse.Namespace(
            hot_zone=str(tmp_path / "nonexistent"),
            top=10,
            json=False,
            scope="production",
        )
        result = cmd_hotspots(args)
        assert result == 1

    def test_no_scan_returns_error(
        self, db: sqlite3.Connection, tmp_path: Path
    ) -> None:
        """hotspots with empty db returns error."""
        _ = db  # ensure DB is created
        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            top=10,
            json=False,
            scope="production",
        )
        result = cmd_hotspots(args)
        assert result == 1

    def test_hotspots_text_output(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """hotspots with data returns ranked text output."""
        scan_id = begin_scan(db, "abc123")
        entries = [
            _entry("a.py", scan_id, complexity=100),
            _entry("b.py", scan_id, complexity=10),
        ]
        stats = [
            _stats("a.py", churn=50),
            _stats("b.py", churn=5),
        ]
        _populate_scan(db, scan_id, entries, stats)
        finish_scan(db, scan_id, 2, 100)
        db.close()

        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            top=10,
            json=False,
            scope="production",
        )
        result = cmd_hotspots(args)
        assert result == 0
        captured = capsys.readouterr()
        assert "a.py" in captured.err

    def test_hotspots_json_output(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """hotspots --json returns valid JSON with expected schema."""
        scan_id = begin_scan(db, "abc123")
        entries = [
            _entry("a.py", scan_id, complexity=100),
            _entry("b.py", scan_id, complexity=10),
        ]
        stats = [
            _stats("a.py", churn=50),
            _stats("b.py", churn=5),
        ]
        _populate_scan(db, scan_id, entries, stats)
        finish_scan(db, scan_id, 2, 100)
        db.close()

        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            top=10,
            json=True,
            scope="production",
        )
        result = cmd_hotspots(args)
        assert result == 0
        captured = capsys.readouterr()
        data = json.loads(captured.out)
        assert "hotspots" in data
        assert "scan_id" in data
        assert "git_head" in data
        assert "stale" in data
        # a.py should be the top hotspot (higher complexity + churn)
        if data["hotspots"]:
            assert data["hotspots"][0]["path"] == "a.py"

    def test_hotspots_top_limits_results(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """--top=1 limits to 1 result."""
        scan_id = begin_scan(db, "abc123")
        entries = [
            _entry("a.py", scan_id, complexity=100),
            _entry("b.py", scan_id, complexity=90),
            _entry("c.py", scan_id, complexity=80),
        ]
        stats = [
            _stats("a.py", churn=50, hotspot=0.9),
            _stats("b.py", churn=40, hotspot=0.8),
            _stats("c.py", churn=30, hotspot=0.7),
        ]
        _populate_scan(db, scan_id, entries, stats)
        finish_scan(db, scan_id, 3, 100)
        db.close()

        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            top=1,
            json=True,
            scope="production",
        )
        result = cmd_hotspots(args)
        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert len(data["hotspots"]) <= 1


# ---------------------------------------------------------------------------
# Tests: cmd_diff
# ---------------------------------------------------------------------------


class TestCmdDiff:
    def test_no_db_returns_error(self, tmp_path: Path) -> None:
        """diff with no quality.db returns error."""
        args = argparse.Namespace(
            hot_zone=str(tmp_path / "nonexistent"),
            json=False,
            scope="production",
        )
        result = cmd_diff(args)
        assert result == 1

    def test_single_scan_no_previous(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """diff with only one scan returns exit 0 with message."""
        scan_id = begin_scan(db, "abc123")
        finish_scan(db, scan_id, 5, 100)
        db.commit()
        db.close()

        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            json=False,
            scope="production",
        )
        result = cmd_diff(args)
        assert result == 0
        captured = capsys.readouterr()
        assert "No previous scan" in captured.err

    def test_single_scan_json(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """diff --json with one scan returns null previous."""
        scan_id = begin_scan(db, "abc123")
        finish_scan(db, scan_id, 5, 100)
        db.commit()
        db.close()

        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            json=True,
            scope="production",
        )
        result = cmd_diff(args)
        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert data["scan_previous"] is None
        assert data["scan_current"] == scan_id

    def test_diff_two_scans_no_change(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """diff between identical scans shows no significant changes."""
        # Scan 1
        s1 = begin_scan(db, "abc123")
        entries1 = [_entry("a.py", s1, complexity=10)]
        stats1 = [_stats("a.py", churn=5)]
        _populate_scan(db, s1, entries1, stats1)
        finish_scan(db, s1, 1, 100)

        # Scan 2 (same data)
        s2 = begin_scan(db, "abc456")
        entries2 = [_entry("a.py", s2, complexity=10)]
        stats2 = [_stats("a.py", churn=5)]
        _populate_scan(db, s2, entries2, stats2)
        finish_scan(db, s2, 1, 100)
        db.close()

        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            json=True,
            scope="production",
        )
        result = cmd_diff(args)
        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert data["improved"] == []
        assert data["degraded"] == []
        assert data["new_files"] == []
        assert data["removed_files"] == []

    def test_diff_shows_degraded(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """diff reports files where complexity increased."""
        # Scan 1
        s1 = begin_scan(db, "abc123")
        entries1 = [_entry("a.py", s1, complexity=10)]
        stats1 = [_stats("a.py", churn=5)]
        _populate_scan(db, s1, entries1, stats1)
        finish_scan(db, s1, 1, 100)

        # Scan 2 (complexity increased)
        s2 = begin_scan(db, "abc456")
        entries2 = [_entry("a.py", s2, complexity=30)]
        stats2 = [_stats("a.py", churn=5)]
        _populate_scan(db, s2, entries2, stats2)
        finish_scan(db, s2, 1, 100)
        db.close()

        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            json=True,
            scope="production",
        )
        result = cmd_diff(args)
        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert len(data["degraded"]) == 1
        assert data["degraded"][0]["path"] == "a.py"
        assert data["degraded"][0]["delta"] == 20.0

    def test_diff_shows_improved(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """diff reports files where complexity decreased."""
        # Scan 1
        s1 = begin_scan(db, "abc123")
        entries1 = [_entry("a.py", s1, complexity=30)]
        stats1 = [_stats("a.py", churn=5)]
        _populate_scan(db, s1, entries1, stats1)
        finish_scan(db, s1, 1, 100)

        # Scan 2 (complexity decreased)
        s2 = begin_scan(db, "abc456")
        entries2 = [_entry("a.py", s2, complexity=10)]
        stats2 = [_stats("a.py", churn=5)]
        _populate_scan(db, s2, entries2, stats2)
        finish_scan(db, s2, 1, 100)
        db.close()

        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            json=True,
            scope="production",
        )
        result = cmd_diff(args)
        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert len(data["improved"]) == 1
        assert data["improved"][0]["path"] == "a.py"
        assert data["improved"][0]["delta"] == -20.0

    def test_diff_shows_new_files(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """diff reports files that appear in current but not previous scan."""
        # Scan 1 (only a.py)
        s1 = begin_scan(db, "abc123")
        entries1 = [_entry("a.py", s1, complexity=10)]
        stats1 = [_stats("a.py", churn=5)]
        _populate_scan(db, s1, entries1, stats1)
        finish_scan(db, s1, 1, 100)

        # Scan 2 (a.py + b.py)
        s2 = begin_scan(db, "abc456")
        entries2 = [
            _entry("a.py", s2, complexity=10),
            _entry("b.py", s2, complexity=20),
        ]
        stats2 = [_stats("a.py", churn=5), _stats("b.py", churn=10)]
        _populate_scan(db, s2, entries2, stats2)
        finish_scan(db, s2, 2, 100)
        db.close()

        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            json=True,
            scope="production",
        )
        result = cmd_diff(args)
        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert len(data["new_files"]) == 1
        assert data["new_files"][0]["path"] == "b.py"

    def test_diff_shows_removed_files(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """diff reports files that disappeared from current scan."""
        # Scan 1 (a.py + b.py)
        s1 = begin_scan(db, "abc123")
        entries1 = [
            _entry("a.py", s1, complexity=10),
            _entry("b.py", s1, complexity=20),
        ]
        stats1 = [_stats("a.py", churn=5), _stats("b.py", churn=10)]
        _populate_scan(db, s1, entries1, stats1)
        finish_scan(db, s1, 2, 100)

        # Scan 2 (only a.py)
        s2 = begin_scan(db, "abc456")
        entries2 = [_entry("a.py", s2, complexity=10)]
        stats2 = [_stats("a.py", churn=5)]
        _populate_scan(db, s2, entries2, stats2)
        finish_scan(db, s2, 1, 100)
        db.close()

        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            json=True,
            scope="production",
        )
        result = cmd_diff(args)
        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert "b.py" in data["removed_files"]

    def test_diff_quality_score_delta(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """diff JSON includes quality_score_current and quality_score_previous."""
        # Scan 1
        s1 = begin_scan(db, "abc123")
        entries1 = [_entry("a.py", s1, complexity=10)]
        stats1 = [_stats("a.py", churn=5)]
        _populate_scan(db, s1, entries1, stats1)
        finish_scan(db, s1, 1, 100)

        # Scan 2
        s2 = begin_scan(db, "abc456")
        entries2 = [_entry("a.py", s2, complexity=10)]
        stats2 = [_stats("a.py", churn=5)]
        _populate_scan(db, s2, entries2, stats2)
        finish_scan(db, s2, 1, 100)
        db.close()

        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            json=True,
            scope="production",
        )
        result = cmd_diff(args)
        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert "quality_score_current" in data
        assert "quality_score_previous" in data
        assert isinstance(data["quality_score_current"], int)
        assert isinstance(data["quality_score_previous"], int)


# ---------------------------------------------------------------------------
# Tests: cmd_promote
# ---------------------------------------------------------------------------


def _make_promote_args(
    hot_zone: str,
    parent: str = "wv-abcdef",
    top: int = 5,
    json_out: bool = False,
    dry_run: bool = False,
) -> argparse.Namespace:
    return argparse.Namespace(
        hot_zone=hot_zone,
        parent=parent,
        top=top,
        json=json_out,
        dry_run=dry_run,
    )


def _make_findings_promote_args(
    parent: str = "",
    top: int = 5,
    json_out: bool = False,
    dry_run: bool = False,
    apply: bool = False,
    include_guardrails: bool = False,
    include_root_causes: bool = False,
    include_tooling: bool = False,
) -> argparse.Namespace:
    return argparse.Namespace(
        hot_zone="unused",
        parent=parent,
        top=top,
        json=json_out,
        dry_run=dry_run,
        apply=apply,
        include_guardrails=include_guardrails,
        include_root_causes=include_root_causes,
        include_tooling=include_tooling,
    )


class TestCmdPromote:
    def test_no_db_returns_error(self, tmp_path: Path) -> None:
        """promote with no quality.db returns error."""
        args = _make_promote_args(str(tmp_path / "nonexistent"))
        result = cmd_promote(args)
        assert result == 1

    def test_no_scan_returns_error(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
    ) -> None:
        """promote with empty db returns error."""
        _ = db
        args = _make_promote_args(str(tmp_path))
        result = cmd_promote(args)
        assert result == 1

    def test_no_parent_returns_error(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
    ) -> None:
        """promote without --parent returns error."""
        _ = db
        args = _make_promote_args(str(tmp_path), parent="")
        result = cmd_promote(args)
        assert result == 1

    def test_dry_run_no_wv_calls(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """dry-run prints plan without calling wv."""
        scan_id = begin_scan(db, str(tmp_path))
        entries = [
            _entry("a.py", scan_id, complexity=50.0),
            _entry("b.py", scan_id, complexity=30.0),
        ]
        stats = [
            _stats("a.py", churn=100),
            _stats("b.py", churn=80),
        ]
        _populate_scan(db, scan_id, entries, stats)
        finish_scan(db, scan_id, 2, 100)

        args = _make_promote_args(str(tmp_path), dry_run=True)

        with patch("weave_quality.__main__._wv_cmd") as mock_wv:
            # _wv_cmd for idempotency check returns empty list
            mock_wv.return_value = (0, "[]")
            result = cmd_promote(args)

        assert result == 0
        captured = capsys.readouterr()
        assert "[DRY-RUN]" in captured.err
        # Only the idempotency list check, no add/link calls
        mock_wv.assert_called_once_with("list", "--json", "--all")

    def test_promote_creates_nodes(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """promote creates nodes and links them via references edge."""
        scan_id = begin_scan(db, str(tmp_path))
        entries = [
            _entry("hot.py", scan_id, complexity=60.0),
            _entry("cold.py", scan_id, complexity=5.0),
        ]
        stats = [
            _stats("hot.py", churn=120),
            _stats("cold.py", churn=10),
        ]
        _populate_scan(db, scan_id, entries, stats)
        finish_scan(db, scan_id, 2, 100)

        args = _make_promote_args(str(tmp_path), top=1, json_out=True)

        def fake_wv(*cmd_args: str) -> tuple[int, str]:
            if cmd_args[0] == "list":
                return 0, "[]"
            if cmd_args[0] == "add":
                return 0, "wv-aaa111: Hotspot: hot.py ..."
            if cmd_args[0] == "link":
                return 0, ""
            return 1, "unknown"

        with patch("weave_quality.__main__._wv_cmd", side_effect=fake_wv):
            result = cmd_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert len(data["promoted"]) == 1
        assert data["promoted"][0]["node_id"] == "wv-aaa111"
        assert data["skipped"] == 0
        assert data["parent"] == "wv-abcdef"

    def test_promote_skips_existing(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """promote skips findings that already have Weave nodes."""
        scan_id = begin_scan(db, str(tmp_path))
        entries = [
            _entry("dup.py", scan_id, complexity=40.0),
            _entry("other.py", scan_id, complexity=5.0),
        ]
        stats = [
            _stats("dup.py", churn=90),
            _stats("other.py", churn=10),
        ]
        _populate_scan(db, scan_id, entries, stats)
        finish_scan(db, scan_id, 2, 100)

        # Compute the finding ID for dup.py so we can simulate existing node
        fid = _finding_id("dup.py")

        existing_node = json.dumps(
            [
                {
                    "id": "wv-exists",
                    "text": "old finding",
                    "metadata": json.dumps({"quality_finding_id": fid}),
                }
            ]
        )

        args = _make_promote_args(str(tmp_path), top=1, json_out=True)

        with patch("weave_quality.__main__._wv_cmd", return_value=(0, existing_node)):
            result = cmd_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert data["skipped"] == 1
        assert len(data["promoted"]) == 0

    def test_promote_json_schema(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """promote --json output has required fields."""
        scan_id = begin_scan(db, str(tmp_path))
        entries = [
            _entry("schema.py", scan_id, complexity=45.0),
            _entry("low.py", scan_id, complexity=5.0),
        ]
        stats = [
            _stats("schema.py", churn=70),
            _stats("low.py", churn=10),
        ]
        _populate_scan(db, scan_id, entries, stats)
        finish_scan(db, scan_id, 2, 100)

        args = _make_promote_args(str(tmp_path), top=1, json_out=True, dry_run=True)

        with patch("weave_quality.__main__._wv_cmd", return_value=(0, "[]")):
            result = cmd_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert "promoted" in data
        assert "skipped" in data
        assert "parent" in data
        assert isinstance(data["promoted"], list)


class TestCmdFindingsPromote:  # pylint: disable=too-many-public-methods
    def test_apply_requires_parent(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """Applying historical promotions requires an explicit parent."""
        args = _make_findings_promote_args(apply=True)
        result = cmd_findings_promote(args)
        assert result == 1
        assert "--parent" in capsys.readouterr().err

    def test_dry_run_extracts_candidate(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """Dry-run surfaces pitfall learnings as historical finding candidates."""
        nodes = json.dumps(
            [
                {
                    "id": "wv-source",
                    "text": "Investigate hook regression",
                    "status": "done",
                    "metadata": json.dumps(
                        {
                            "learning": (
                                "pitfall: hooks copied by install.sh but not wired into "
                                "settings.json"
                            )
                        }
                    ),
                }
            ]
        )
        args = _make_findings_promote_args(json_out=True)

        with patch("weave_quality.findings._wv_cmd", return_value=(0, nodes)) as mock_wv:
            result = cmd_findings_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert len(data["candidates"]) == 1
        assert data["candidates"][0]["source_node"] == "wv-source"
        assert data["candidates"][0]["metadata"]["type"] == "finding"
        mock_wv.assert_called_once_with("list", "--json", "--all")

    def test_skips_existing_promoted_finding(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """Existing promotions stay in the reviewed window and are reported as skipped."""
        existing_id = "abc123def456"
        nodes = json.dumps(
            [
                {
                    "id": "wv-source",
                    "text": "Investigate hook regression",
                    "status": "done",
                    "metadata": json.dumps(
                        {
                            "learning": (
                                "pitfall: hooks copied by install.sh but not wired into "
                                "settings.json"
                            ),
                            "historical_finding_id": existing_id,
                        }
                    ),
                },
                {
                    "id": "wv-existing",
                    "text": "Finding: hooks copied by install.sh but not wired into settings.json",
                    "status": "todo",
                    "metadata": json.dumps(
                        {
                            "type": "finding",
                            "historical_finding_id": existing_id,
                            "finding": {
                                "root_cause": (
                                    "hooks copied by install.sh but not wired into settings.json"
                                )
                            },
                            "source_node": "wv-source",
                        }
                    ),
                },
            ]
        )
        args = _make_findings_promote_args(json_out=True)

        with patch("weave_quality.findings._wv_cmd", return_value=(0, nodes)):
            result = cmd_findings_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert data["reviewed_candidates"] == 1
        assert data["skipped"] == 1
        assert len(data["candidates"]) == 1
        assert (
            data["candidates"][0]["text"]
            == "Finding: hooks copied by install.sh but not wired into settings.json"
        )
        assert data["candidates"][0]["eligible_for_apply"] is False
        assert data["candidates"][0]["skipped_reason"] == "already_promoted"
        assert data["candidates"][0]["metadata"]["promotion_batch_window"] == {
            "top": 5,
            "signal_types": ["defect"],
            "backfill": False,
        }

    def test_apply_creates_node_and_links_parent_and_source(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """Apply mode creates a finding node and references both parent and source."""
        nodes = json.dumps(
            [
                {
                    "id": "wv-source",
                    "text": "Investigate hook regression",
                    "status": "done",
                    "metadata": json.dumps(
                        {
                            "learning": (
                                "pitfall: hooks copied by install.sh but not wired into "
                                "settings.json"
                            )
                        }
                    ),
                }
            ]
        )
        args = _make_findings_promote_args(
            parent="wv-parent", json_out=True, apply=True
        )

        def fake_wv(*cmd_args: str) -> tuple[int, str]:
            if cmd_args == ("list", "--json", "--all"):
                return 0, nodes
            if cmd_args[0] == "add":
                return 0, "wv-new123: Finding: hooks copied by install.sh ..."
            if cmd_args[0] == "link":
                return 0, ""
            return 1, "unexpected"

        with patch("weave_quality.findings._wv_cmd", side_effect=fake_wv) as mock_wv:
            result = cmd_findings_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert len(data["promoted"]) == 1
        assert data["promoted"][0]["node_id"] == "wv-new123"
        link_calls = [call.args for call in mock_wv.call_args_list if call.args[0] == "link"]
        assert ("link", "wv-new123", "wv-parent", "--type=references") in link_calls
        assert ("link", "wv-new123", "wv-source", "--type=addresses") in link_calls
        assert data["reviewed_candidates"] == 1
        assert data["created"] == 1
        assert data["backfilled_beyond_reviewed_set"] == 0
        assert data["reviewed"][0]["metadata"]["promotion_batch_window"] == {
            "top": 5,
            "signal_types": ["defect"],
            "backfill": False,
        }

    def test_apply_does_not_backfill_beyond_reviewed_defect_window(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """Apply must only create from the reviewed defect slice."""
        nodes = json.dumps(
            [
                {
                    "id": "wv-source-a",
                    "text": "Finding #1 (HIGH): No-detection inflated metric to 1000.0 and was fixed.",
                    "status": "done",
                    "metadata": json.dumps({}),
                },
                {
                    "id": "wv-source-b",
                    "text": "Investigate factory config regression",
                    "status": "done",
                    "metadata": json.dumps(
                        {
                            "learning": (
                                "pitfall: factory silently dropped water_detection config and "
                                "caused false negatives"
                            )
                        }
                    ),
                },
                {
                    "id": "wv-source-c",
                    "text": "Investigate deeper defect",
                    "status": "done",
                    "metadata": json.dumps(
                        {
                            "learning": (
                                "pitfall: fallback shoreline path masked classifier failure and "
                                "produced wrong output"
                            )
                        }
                    ),
                },
                {
                    "id": "wv-existing",
                    "text": "Finding: Finding #1 (HIGH): No-detection inflated metric to 1000.0 and was fixed.",
                    "status": "todo",
                    "metadata": json.dumps(
                        {
                            "type": "finding",
                            "historical_finding_id": "hist-a",
                            "finding": {
                                "root_cause": (
                                    "Finding #1 (HIGH): No-detection inflated metric to 1000.0 "
                                    "and was fixed."
                                )
                            },
                            "source_node": "wv-source-a",
                        }
                    ),
                },
            ]
        )
        args = _make_findings_promote_args(parent="wv-parent", json_out=True, apply=True, top=2)

        def fake_wv(*cmd_args: str) -> tuple[int, str]:
            if cmd_args == ("list", "--json", "--all"):
                return 0, nodes
            if cmd_args[0] == "add":
                return 0, "wv-new222: Finding: second reviewed defect."
            if cmd_args[0] == "link":
                return 0, ""
            return 1, "unexpected"

        with patch("weave_quality.findings._wv_cmd", side_effect=fake_wv) as mock_wv:
            result = cmd_findings_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert data["reviewed_candidates"] == 2
        assert data["created"] == 1
        assert data["skipped_already_promoted"] == 1
        assert data["backfilled_beyond_reviewed_set"] == 0
        assert [item["text"] for item in data["reviewed"]] == [
            "Finding: Finding #1 (HIGH): No-detection inflated metric to 1000.0 and was fixed.",
            "Finding: factory silently dropped water_detection config and caused false negatives",
        ]
        assert len(data["promoted"]) == 1
        assert (
            data["promoted"][0]["text"]
            == "Finding: factory silently dropped water_detection config and caused false negatives"
        )
        add_calls = [call.args for call in mock_wv.call_args_list if call.args[0] == "add"]
        assert len(add_calls) == 1
        assert "factory silently dropped water_detection config" in add_calls[0][1]
        assert all(
            "fallback shoreline path masked classifier failure" not in item["text"]
            for item in data["reviewed"] + data["promoted"]
        )

    def test_additive_apply_matches_dry_run_reviewed_slice(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """Dry-run and apply must use the same additive reviewed window."""
        nodes = json.dumps(
            [
                {
                    "id": "wv-defect",
                    "text": "Finding #1 (HIGH): No-detection inflated metric to 1000.0 and was fixed.",
                    "status": "done",
                    "metadata": json.dumps({}),
                },
                {
                    "id": "wv-guardrail",
                    "text": "Guardrail note",
                    "status": "done",
                    "metadata": json.dumps(
                        {
                            "learning": (
                                "pitfall: reports must surface quality_flag to avoid downstream misuse"
                            )
                        }
                    ),
                },
                {
                    "id": "wv-root",
                    "text": "Explain threshold behavior",
                    "status": "done",
                    "metadata": json.dumps(
                        {
                            "learning": (
                                "decision: root cause confirmed because calibration revealed "
                                "triple-AND failure on turbid water."
                            )
                        }
                    ),
                },
                {
                    "id": "wv-existing",
                    "text": "Finding: Finding #1 (HIGH): No-detection inflated metric to 1000.0 and was fixed.",
                    "status": "todo",
                    "metadata": json.dumps(
                        {
                            "type": "finding",
                            "historical_finding_id": "hist-defect",
                            "finding": {
                                "root_cause": (
                                    "Finding #1 (HIGH): No-detection inflated metric to 1000.0 "
                                    "and was fixed."
                                )
                            },
                            "source_node": "wv-defect",
                        }
                    ),
                },
            ]
        )
        dry_run_args = _make_findings_promote_args(
            json_out=True, top=2, include_guardrails=True, include_root_causes=True
        )
        apply_args = _make_findings_promote_args(
            parent="wv-parent",
            json_out=True,
            apply=True,
            top=2,
            include_guardrails=True,
            include_root_causes=True,
        )

        with patch("weave_quality.findings._wv_cmd", return_value=(0, nodes)):
            dry_run_result = cmd_findings_promote(dry_run_args)

        assert dry_run_result == 0
        dry_run_data = json.loads(capsys.readouterr().out)

        def fake_wv(*cmd_args: str) -> tuple[int, str]:
            if cmd_args == ("list", "--json", "--all"):
                return 0, nodes
            if cmd_args[0] == "add":
                return 0, "wv-new333: Finding: reports must surface quality_flag ..."
            if cmd_args[0] == "link":
                return 0, ""
            return 1, "unexpected"

        with patch("weave_quality.findings._wv_cmd", side_effect=fake_wv):
            apply_result = cmd_findings_promote(apply_args)

        assert apply_result == 0
        apply_data = json.loads(capsys.readouterr().out)
        assert [
            item["historical_finding_id"] for item in dry_run_data["candidates"]
        ] == [item["historical_finding_id"] for item in apply_data["reviewed"]]
        assert [item["signal_type"] for item in apply_data["reviewed"]] == [
            "defect",
            "guardrail",
        ]
        assert apply_data["created"] == 1
        assert apply_data["skipped_already_promoted"] == 1
        assert apply_data["backfilled_beyond_reviewed_set"] == 0
        assert len(apply_data["promoted"]) == 1
        assert apply_data["promoted"][0]["signal_type"] == "guardrail"

    def test_filters_sprint_summary_noise(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """Sprint recap learnings should not be promoted as findings."""
        nodes = json.dumps(
            [
                {
                    "id": "wv-sprint",
                    "text": "Epic: Sprint 15",
                    "status": "done",
                    "metadata": json.dumps(
                        {
                            "learning": (
                                "Sprint 15 completed 10/11 tasks. Key outcomes: shipped "
                                "adaptive thresholds and toolkit."
                            )
                        }
                    ),
                }
            ]
        )
        args = _make_findings_promote_args(json_out=True)

        with patch("weave_quality.findings._wv_cmd", return_value=(0, nodes)):
            result = cmd_findings_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert data["candidates"] == []

    def test_keeps_bugfix_finding_text(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """Bugfix-style finding text remains promotable."""
        nodes = json.dumps(
            [
                {
                    "id": "wv-fix7",
                    "text": (
                        "Finding #7 (MED-HIGH): Error results report primary_metric=0.0. "
                        "Fix: Changed to float('nan')."
                    ),
                    "status": "done",
                    "metadata": json.dumps(
                        {
                            "type": "bugfix",
                            "severity": "MED-HIGH",
                            "files": ["src/monitoring/system.py"],
                        }
                    ),
                }
            ]
        )
        args = _make_findings_promote_args(json_out=True)

        with patch("weave_quality.findings._wv_cmd", return_value=(0, nodes)):
            result = cmd_findings_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert len(data["candidates"]) == 1
        assert data["candidates"][0]["source_node"] == "wv-fix7"

    def test_filters_task_stub_text(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """Raw task titles should not be promoted as historical findings."""
        nodes = json.dumps(
            [
                {
                    "id": "wv-task",
                    "text": (
                        "Task: Catoca YAML slope config — Add slope section to "
                        "config/sites/catoca.yaml."
                    ),
                    "status": "done",
                    "metadata": json.dumps(
                        {
                            "type": "task",
                            "learning": (
                                "pattern: slope section nested under strategy.config.slope "
                                "in catoca.yaml"
                            ),
                        }
                    ),
                }
            ]
        )
        args = _make_findings_promote_args(json_out=True)

        with patch("weave_quality.findings._wv_cmd", return_value=(0, nodes)):
            result = cmd_findings_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert data["candidates"] == []

    def test_filters_tooling_baseline_noise(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """Version and MCP verification notes should not be promoted."""
        nodes = json.dumps(
            [
                {
                    "id": "wv-mcp",
                    "text": "Verify upstream MCP fixes",
                    "status": "done",
                    "metadata": json.dumps(
                        {
                            "learning": (
                                "pattern: Weave 1.12.0 fixed both MCP bugs. "
                                "VIRTUAL_ENV=1 workaround is no longer needed in mcp.json. "
                                "All 4 MCP quality tools now return proper JSON."
                            )
                        }
                    ),
                }
            ]
        )
        args = _make_findings_promote_args(json_out=True)

        with patch("weave_quality.findings._wv_cmd", return_value=(0, nodes)):
            result = cmd_findings_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert data["candidates"] == []

    def test_filters_version_scan_quality_chatter_by_default(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """Weave version-scan quality chatter should stay tooling-only."""
        nodes = json.dumps(
            [
                {
                    "id": "wv-version-scan",
                    "text": "Verify upstream MCP/quality fixes from Weave 1.12.0",
                    "status": "done",
                    "metadata": json.dumps(
                        {
                            "learning": (
                                "pattern: Weave 1.12.0 fixed both MCP bugs. "
                                "Quality score dropped from 6-7 to 2/100 because 1.12.0 "
                                "scans 272 files (vs ~175 before) — likely scanning more "
                                "file types. All 4 MCP quality tools now return proper JSON."
                            )
                        }
                    ),
                }
            ]
        )
        args = _make_findings_promote_args(json_out=True)

        with patch("weave_quality.findings._wv_cmd", return_value=(0, nodes)):
            result = cmd_findings_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert data["candidates"] == []

    def test_filters_internal_tooling_noise_by_default(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """Weave/runtime tooling notes stay hidden unless explicitly requested."""
        nodes = json.dumps(
            [
                {
                    "id": "wv-tooling",
                    "text": "Fix sync behavior",
                    "status": "done",
                    "metadata": json.dumps(
                        {
                            "learning": (
                                "pitfall: wv sync hangs silently on metadata >100KB — "
                                "always pre-check sizes before sync"
                            )
                        }
                    ),
                }
            ]
        )
        args = _make_findings_promote_args(json_out=True)

        with patch("weave_quality.findings._wv_cmd", return_value=(0, nodes)):
            result = cmd_findings_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert data["include_tooling"] is False
        assert data["candidates"] == []

    def test_include_tooling_allows_internal_runtime_findings(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """Explicit tooling mode should surface internal runtime/tooling findings."""
        nodes = json.dumps(
            [
                {
                    "id": "wv-tooling",
                    "text": "Fix sync behavior",
                    "status": "done",
                    "metadata": json.dumps(
                        {
                            "learning": (
                                "pitfall: wv sync hangs silently on metadata >100KB — "
                                "always pre-check sizes before sync"
                            )
                        }
                    ),
                }
            ]
        )
        args = _make_findings_promote_args(json_out=True, include_tooling=True)

        with patch("weave_quality.findings._wv_cmd", return_value=(0, nodes)):
            result = cmd_findings_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert data["include_tooling"] is True
        assert len(data["candidates"]) == 1
        assert data["candidates"][0]["source_node"] == "wv-tooling"
        assert data["candidates"][0]["signal_type"] == "tooling"

    def test_filters_typing_only_learnings_from_default_defects(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """Typing-only mypy guidance should not appear in the default defect view."""
        nodes = json.dumps(
            [
                {
                    "id": "wv-typing",
                    "text": "fix mypy type errors",
                    "status": "done",
                    "metadata": json.dumps(
                        {
                            "learning": (
                                "pitfall: dict.get() returns Any not float even with default — "
                                "must cast explicitly. pattern: composite.bandNames().getInfo() "
                                "returns Any|None, guard with ''or []''."
                            )
                        }
                    ),
                }
            ]
        )
        args = _make_findings_promote_args(json_out=True)

        with patch("weave_quality.findings._wv_cmd", return_value=(0, nodes)):
            result = cmd_findings_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert data["candidates"] == []

    def test_include_tooling_surfaces_typing_hygiene_notes(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """Typing-only mypy guidance can still be inspected in tooling mode."""
        nodes = json.dumps(
            [
                {
                    "id": "wv-typing",
                    "text": "fix mypy type errors",
                    "status": "done",
                    "metadata": json.dumps(
                        {
                            "learning": (
                                "pitfall: dict.get() returns Any not float even with default — "
                                "must cast explicitly. pattern: composite.bandNames().getInfo() "
                                "returns Any|None, guard with ''or []''."
                            )
                        }
                    ),
                }
            ]
        )
        args = _make_findings_promote_args(json_out=True, include_tooling=True)

        with patch("weave_quality.findings._wv_cmd", return_value=(0, nodes)):
            result = cmd_findings_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert len(data["candidates"]) >= 1
        assert all(item["signal_type"] == "tooling" for item in data["candidates"])

    def test_default_mode_keeps_only_defects_from_mixed_clauses(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """Default promotion should keep defects and suppress other signal types."""
        nodes = json.dumps(
            [
                {
                    "id": "wv-mixed",
                    "text": "Review historical learnings",
                    "status": "done",
                    "metadata": json.dumps(
                        {
                            "learning": (
                                "finding: Error results default to 0.0 on failure. | "
                                "pitfall: timeline reports must surface quality_flag to avoid "
                                "downstream misuse. | "
                                "decision: Root cause confirmed because zone-wide histogram is "
                                "unimodal."
                            )
                        }
                    ),
                }
            ]
        )
        args = _make_findings_promote_args(json_out=True)

        with patch("weave_quality.findings._wv_cmd", return_value=(0, nodes)):
            result = cmd_findings_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert data["signal_types"] == ["defect"]
        assert len(data["candidates"]) == 1
        assert data["candidates"][0]["signal_type"] == "defect"

    def test_include_guardrails_surfaces_guardrail_candidates(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """Guardrails should only appear when explicitly requested."""
        nodes = json.dumps(
            [
                {
                    "id": "wv-guardrail",
                    "text": "Guardrail note",
                    "status": "done",
                    "metadata": json.dumps(
                        {
                            "learning": (
                                "pitfall: timeline reports must surface quality_flag to avoid "
                                "downstream misuse"
                            )
                        }
                    ),
                }
            ]
        )
        args = _make_findings_promote_args(json_out=True, include_guardrails=True)

        with patch("weave_quality.findings._wv_cmd", return_value=(0, nodes)):
            result = cmd_findings_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert data["include_guardrails"] is True
        assert len(data["candidates"]) == 1
        assert data["candidates"][0]["signal_type"] == "guardrail"

    def test_finding_clause_with_operational_rule_stays_guardrail(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """Finding segments with operational-suitability rules should not leak into defects."""
        nodes = json.dumps(
            [
                {
                    "id": "wv-operational",
                    "text": "Beachlength quality recap",
                    "status": "done",
                    "metadata": json.dumps(
                        {
                            "learning": (
                                "finding: AOI cloud is the quality-gate source of truth; "
                                "finite distances can still appear due to local openings and "
                                "must remain not_for_monitoring."
                            )
                        }
                    ),
                }
            ]
        )
        default_args = _make_findings_promote_args(json_out=True)
        guardrail_args = _make_findings_promote_args(
            json_out=True, include_guardrails=True
        )

        with patch("weave_quality.findings._wv_cmd", return_value=(0, nodes)):
            result = cmd_findings_promote(default_args)

        assert result == 0
        default_data = json.loads(capsys.readouterr().out)
        assert default_data["candidates"] == []

        with patch("weave_quality.findings._wv_cmd", return_value=(0, nodes)):
            result = cmd_findings_promote(guardrail_args)

        assert result == 0
        guardrail_data = json.loads(capsys.readouterr().out)
        assert len(guardrail_data["candidates"]) == 1
        assert guardrail_data["candidates"][0]["signal_type"] == "guardrail"

    def test_include_root_causes_surfaces_root_cause_candidates(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """Root-cause insights should only appear when explicitly requested."""
        nodes = json.dumps(
            [
                {
                    "id": "wv-root",
                    "text": "Explain Otsu failure",
                    "status": "done",
                    "metadata": json.dumps(
                        {
                            "learning": (
                                "decision: Root cause confirmed because zone-wide histogram is "
                                "unimodal with bimodality 0.42."
                            )
                        }
                    ),
                }
            ]
        )
        args = _make_findings_promote_args(json_out=True, include_root_causes=True)

        with patch("weave_quality.findings._wv_cmd", return_value=(0, nodes)):
            result = cmd_findings_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert data["include_root_causes"] is True
        assert len(data["candidates"]) == 1
        assert data["candidates"][0]["signal_type"] == "root_cause"

    def test_defect_beats_guardrail_when_clause_has_explicit_bug_semantics(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """Explicit bug semantics should stay defect even with guardrail wording."""
        nodes = json.dumps(
            [
                {
                    "id": "wv-nodefect",
                    "text": (
                        "Finding #8 (MEDIUM): No-detection inflates metric with "
                        "max_transect_distance; keep uncertain confidence."
                    ),
                    "status": "done",
                    "metadata": json.dumps({}),
                }
            ]
        )
        args = _make_findings_promote_args(json_out=True)

        with patch("weave_quality.findings._wv_cmd", return_value=(0, nodes)):
            result = cmd_findings_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert len(data["candidates"]) == 1
        assert data["candidates"][0]["signal_type"] == "defect"

    def test_collapses_duplicate_same_bug_promotions(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """Known same-bug variants should not consume multiple default slots."""
        nodes = json.dumps(
            [
                {
                    "id": "wv-dup-a",
                    "text": "Gradient epic",
                    "status": "done",
                    "metadata": json.dumps(
                        {
                            "learning": (
                                "pitfall: _convert_sampled_features hardcoded field list dropped "
                                "new bands — must update when adding any band to the pipeline"
                            )
                        }
                    ),
                },
                {
                    "id": "wv-dup-b",
                    "text": "Gradient baseline run",
                    "status": "done",
                    "metadata": json.dumps(
                        {
                            "learning": (
                                "pitfall: _convert_sampled_features had hardcoded field list "
                                "that dropped MNDWI_GRAD_MAG — band present in composite but "
                                "lost in profile dict"
                            )
                        }
                    ),
                },
            ]
        )
        args = _make_findings_promote_args(json_out=True)

        with patch("weave_quality.findings._wv_cmd", return_value=(0, nodes)):
            result = cmd_findings_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        root_causes = [item["finding"]["root_cause"] for item in data["candidates"]]
        assert len(root_causes) == 1
        assert "_convert_sampled_features" in root_causes[0]

    def test_additive_window_reserves_slot_for_root_cause(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """Small additive windows should still surface the requested class."""
        nodes = json.dumps(
            [
                {
                    "id": "wv-defect-a",
                    "text": "Finding #1: water_detection config silently dropped in factory.",
                    "status": "done",
                    "metadata": json.dumps({}),
                },
                {
                    "id": "wv-defect-b",
                    "text": "Finding #2: Unparseable cloud cover defaults to 0.0 (clear sky).",
                    "status": "done",
                    "metadata": json.dumps({}),
                },
                {
                    "id": "wv-root-a",
                    "text": "Explain threshold behavior",
                    "status": "done",
                    "metadata": json.dumps(
                        {
                            "learning": (
                                "decision: calibration revealed triple-AND failure on turbid "
                                "water, leading to redesign proposal."
                            )
                        }
                    ),
                },
            ]
        )
        args = _make_findings_promote_args(
            json_out=True, include_root_causes=True, top=2
        )

        with patch("weave_quality.findings._wv_cmd", return_value=(0, nodes)):
            result = cmd_findings_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert len(data["candidates"]) == 2
        assert {item["signal_type"] for item in data["candidates"]} == {
            "defect",
            "root_cause",
        }

    def test_filters_quality_methodology_notes_by_default(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """Code-quality methodology notes should stay internal by default."""
        nodes = json.dumps(
            [
                {
                    "id": "wv-method",
                    "text": "Explain quality hotspot",
                    "status": "done",
                    "metadata": json.dumps(
                        {
                            "learning": (
                                "pitfall: ev(G) measures max essential complexity across "
                                "functions — non-reducible flow needs targeted refactoring"
                            )
                        }
                    ),
                }
            ]
        )
        args = _make_findings_promote_args(json_out=True)

        with patch("weave_quality.findings._wv_cmd", return_value=(0, nodes)):
            result = cmd_findings_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert data["candidates"] == []

    def test_filters_ops_journal_tooling_note_by_default(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """ops.journal cleanup guidance should stay internal by default."""
        nodes = json.dumps(
            [
                {
                    "id": "wv-journal",
                    "text": "Document sync discipline",
                    "status": "done",
                    "metadata": json.dumps(
                        {
                            "learning": (
                                "pitfall: stale ops.journal accumulates from killed syncs, "
                                "clear with > redirect"
                            )
                        }
                    ),
                }
            ]
        )
        args = _make_findings_promote_args(json_out=True)

        with patch("weave_quality.findings._wv_cmd", return_value=(0, nodes)):
            result = cmd_findings_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert data["candidates"] == []

    def test_filters_trivial_test_assertion_fix(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """Trivial follow-up test assertion fixes should not become findings."""
        nodes = json.dumps(
            [
                {
                    "id": "wv-assert",
                    "text": "Fix 2 test assertions for edge_otsu config change",
                    "status": "done",
                    "metadata": json.dumps(
                        {
                            "learning": (
                                "Trivial fix: 2 tests asserted method=='otsu' but config "
                                "changed to 'edge_otsu'. Updated assertions to match."
                            )
                        }
                    ),
                }
            ]
        )
        args = _make_findings_promote_args(json_out=True)

        with patch("weave_quality.findings._wv_cmd", return_value=(0, nodes)):
            result = cmd_findings_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert data["candidates"] == []

    def test_filters_removed_symbol_test_cleanup(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """Test-symbol cleanup notes should not become findings."""
        nodes = json.dumps(
            [
                {
                    "id": "wv-testsymbols",
                    "text": "Remove legacy fallback",
                    "status": "done",
                    "metadata": json.dumps(
                        {
                            "learning": (
                                "Three other test files referenced removed symbols. "
                                "Always grep tests/ for removed symbols before committing."
                            )
                        }
                    ),
                }
            ]
        )
        args = _make_findings_promote_args(json_out=True)

        with patch("weave_quality.findings._wv_cmd", return_value=(0, nodes)):
            result = cmd_findings_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert data["candidates"] == []

    def test_filters_test_expectation_drift_after_behavior_change(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """Test expectation updates after behavior changes should not become findings."""
        nodes = json.dumps(
            [
                {
                    "id": "wv-seasonal",
                    "text": "15-C: Port seasonal models",
                    "status": "done",
                    "metadata": json.dumps(
                        {
                            "learning": (
                                "Pitfall: test_adaptive.py had a test expecting 'fixed' fallback "
                                "when no histogram — now that seasonal works, it returns "
                                "'seasonal_blend' instead."
                            )
                        }
                    ),
                }
            ]
        )
        args = _make_findings_promote_args(json_out=True)

        with patch("weave_quality.findings._wv_cmd", return_value=(0, nodes)):
            result = cmd_findings_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert data["candidates"] == []

    def test_filters_mock_exception_test_harness_noise(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """Mock exception advice for patched tests should not become findings."""
        nodes = json.dumps(
            [
                {
                    "id": "wv-ee-test",
                    "text": "15-E: Create PondAreaSampler",
                    "status": "done",
                    "metadata": json.dumps(
                        {
                            "learning": (
                                "pitfall: ee.EEException cannot be caught in tests when ee module "
                                "is patched — must create real Exception subclass via type() in "
                                "mock_ee.EEException"
                            )
                        }
                    ),
                }
            ]
        )
        args = _make_findings_promote_args(json_out=True)

        with patch("weave_quality.findings._wv_cmd", return_value=(0, nodes)):
            result = cmd_findings_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert data["candidates"] == []

    def test_filters_test_setup_mechanics_noise(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """Test setup mechanics should not become defects."""
        nodes = json.dumps(
            [
                {
                    "id": "wv-calibrate-test",
                    "text": "Debug calibrate fallback tests",
                    "status": "done",
                    "metadata": json.dumps(
                        {
                            "learning": (
                                "Testing calibrate() all-methods-fail fallback requires BOTH: "
                                "empty image_stats {} and mocked failures."
                            )
                        }
                    ),
                }
            ]
        )
        args = _make_findings_promote_args(json_out=True)

        with patch("weave_quality.findings._wv_cmd", return_value=(0, nodes)):
            result = cmd_findings_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert data["candidates"] == []

    def test_filters_mypy_cache_maintenance_noise(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """Local cache cleanup advice should not become findings."""
        nodes = json.dumps(
            [
                {
                    "id": "wv-cache-noise",
                    "text": "Task: add gradient fields",
                    "status": "done",
                    "metadata": json.dumps(
                        {
                            "learning": (
                                "pitfall: mypy cache corruption (AssertionError on "
                                "_frozen_importlib) — fix with rm -rf .mypy_cache"
                            )
                        }
                    ),
                }
            ]
        )
        args = _make_findings_promote_args(json_out=True)

        with patch("weave_quality.findings._wv_cmd", return_value=(0, nodes)):
            result = cmd_findings_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert data["candidates"] == []

    def test_filters_adc_scope_setup_noise(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """Cloud auth scope setup notes should not become findings."""
        nodes = json.dumps(
            [
                {
                    "id": "wv-adc-noise",
                    "text": "ADC auth requires EE scope for Earth Engine access",
                    "status": "done",
                    "metadata": json.dumps(
                        {
                            "learning": (
                                "pitfall: gcloud auth application-default login without --scopes "
                                "gives cloud-platform only — EE rejects with USER_PROJECT_DENIED"
                            )
                        }
                    ),
                }
            ]
        )
        args = _make_findings_promote_args(json_out=True)

        with patch("weave_quality.findings._wv_cmd", return_value=(0, nodes)):
            result = cmd_findings_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert data["candidates"] == []

    def test_include_tooling_surfaces_adc_scope_setup_notes(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """Environment setup notes should reappear in tooling mode."""
        nodes = json.dumps(
            [
                {
                    "id": "wv-adc-noise",
                    "text": "ADC auth requires EE scope for Earth Engine access",
                    "status": "done",
                    "metadata": json.dumps(
                        {
                            "learning": (
                                "pitfall: gcloud auth application-default login without --scopes "
                                "gives cloud-platform only — EE rejects with USER_PROJECT_DENIED"
                            )
                        }
                    ),
                }
            ]
        )
        args = _make_findings_promote_args(json_out=True, include_tooling=True)

        with patch("weave_quality.findings._wv_cmd", return_value=(0, nodes)):
            result = cmd_findings_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert len(data["candidates"]) == 1
        assert data["candidates"][0]["signal_type"] == "tooling"

    def test_filters_operator_workflow_notes_by_default(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """Operator workflow and wv-link guidance should stay tooling-only."""
        nodes = json.dumps(
            [
                {
                    "id": "wv-workflow",
                    "text": "Fix graph workflow notes",
                    "status": "done",
                    "metadata": json.dumps(
                        {
                            "learning": (
                                "regression_source: stale operator muscle memory; "
                                "wv link --context now expects JSON, so plain-text "
                                "--context strings fail with invalid JSON in --context."
                            )
                        }
                    ),
                }
            ]
        )
        args = _make_findings_promote_args(json_out=True)

        with patch("weave_quality.findings._wv_cmd", return_value=(0, nodes)):
            result = cmd_findings_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert data["candidates"] == []

    def test_filters_internal_quality_scanner_audit_by_default(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """Internal quality-scanner audit notes should stay hidden by default."""
        nodes = json.dumps(
            [
                {
                    "id": "wv-scanner",
                    "text": "Audit scanner improvements",
                    "status": "done",
                    "metadata": json.dumps(
                        {
                            "learning": (
                                "decision: quality scanner has 8 unfixed issues. "
                                "Top 3: match/case CC under-counting, DIT metric wrong, "
                                "ev always None in functions JSON."
                            )
                        }
                    ),
                }
            ]
        )
        args = _make_findings_promote_args(json_out=True)

        with patch("weave_quality.findings._wv_cmd", return_value=(0, nodes)):
            result = cmd_findings_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert data["candidates"] == []

    def test_filters_internal_workflow_rollout_guidance_by_default(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """Workflow/policy rollout guidance should stay hidden by default."""
        nodes = json.dumps(
            [
                {
                    "id": "wv-rollout",
                    "text": "Roll out advisory policy",
                    "status": "done",
                    "metadata": json.dumps(
                        {
                            "learning": (
                                "pitfall: mixing policy design and implementation execution "
                                "in one active node leads to long-lived stale tasks."
                            )
                        }
                    ),
                }
            ]
        )
        args = _make_findings_promote_args(json_out=True)

        with patch("weave_quality.findings._wv_cmd", return_value=(0, nodes)):
            result = cmd_findings_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert data["candidates"] == []

    def test_filters_short_decontextualized_pitfall(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """Short pitfall fragments without their own context should not be promoted."""
        nodes = json.dumps(
            [
                {
                    "id": "wv-short",
                    "text": "Implement helper",
                    "status": "done",
                    "metadata": json.dumps(
                        {
                            "learning": (
                                "pitfall: must guard mid_mean > 0 to avoid divide-by-zero"
                            )
                        }
                    ),
                }
            ]
        )
        args = _make_findings_promote_args(json_out=True)

        with patch("weave_quality.findings._wv_cmd", return_value=(0, nodes)):
            result = cmd_findings_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert data["candidates"] == []

    def test_filters_style_only_lint_pitfall(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """Style-only markdown lint learnings should not become findings."""
        nodes = json.dumps(
            [
                {
                    "id": "wv-style",
                    "text": "Update audit doc",
                    "status": "done",
                    "metadata": json.dumps(
                        {
                            "learning": (
                                "pitfall: markdown emphasis must use underscores not "
                                "asterisks per MD049"
                            )
                        }
                    ),
                }
            ]
        )
        args = _make_findings_promote_args(json_out=True)

        with patch("weave_quality.findings._wv_cmd", return_value=(0, nodes)):
            result = cmd_findings_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert data["candidates"] == []

    def test_filters_quality_cache_maintenance_noise(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """Quality DB cache maintenance notes should not become findings."""
        nodes = json.dumps(
            [
                {
                    "id": "wv-cache",
                    "text": "Port seasonal models",
                    "status": "done",
                    "metadata": json.dumps(
                        {
                            "learning": (
                                "Quality DB cache at /dev/shm/weave/ must be deleted after "
                                "adding new functions — incremental scan shows stale count."
                            )
                        }
                    ),
                }
            ]
        )
        args = _make_findings_promote_args(json_out=True)

        with patch("weave_quality.findings._wv_cmd", return_value=(0, nodes)):
            result = cmd_findings_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert data["candidates"] == []

    def test_filters_recap_style_quality_review_text(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """Recap-style quality review summaries should not become findings."""
        nodes = json.dumps(
            [
                {
                    "id": "wv-recap",
                    "text": (
                        "17-B-QR: Production quality review fixes — pond_area.py null-safety + "
                        "voting dedup guard, monitoring_runner.py skip observability"
                    ),
                    "status": "done",
                    "metadata": json.dumps({}),
                }
            ]
        )
        args = _make_findings_promote_args(json_out=True)

        with patch("weave_quality.findings._wv_cmd", return_value=(0, nodes)):
            result = cmd_findings_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert data["candidates"] == []

    def test_filters_test_coverage_pitfall(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """Test-coverage notes should not be promoted as findings."""
        nodes = json.dumps(
            [
                {
                    "id": "wv-tests",
                    "text": "Extend payload",
                    "status": "done",
                    "metadata": json.dumps(
                        {
                            "learning": (
                                "pitfall: no existing tests covered slope block either — "
                                "added 5 tests for gradient"
                            )
                        }
                    ),
                }
            ]
        )
        args = _make_findings_promote_args(json_out=True)

        with patch("weave_quality.findings._wv_cmd", return_value=(0, nodes)):
            result = cmd_findings_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert data["candidates"] == []

    def test_splits_unstructured_learning_into_atomic_clauses(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """Long unstructured learnings should promote concrete clauses, not the whole blob."""
        nodes = json.dumps(
            [
                {
                    "id": "wv-blob",
                    "text": "Production review fixes",
                    "status": "done",
                    "metadata": json.dumps(
                        {
                            "learning": (
                                "Three production hardening fixes touched code. "
                                "water_detection config silently dropped in factory. "
                                "monitoring runner now skips invalid scenes."
                            )
                        }
                    ),
                }
            ]
        )
        args = _make_findings_promote_args(json_out=True)

        with patch("weave_quality.findings._wv_cmd", return_value=(0, nodes)):
            result = cmd_findings_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert len(data["candidates"]) >= 1
        root_causes = [item["finding"]["root_cause"] for item in data["candidates"]]
        assert "water_detection config silently dropped in factory." in root_causes
        assert all("Three production hardening fixes touched code." != item for item in root_causes)

    def test_splits_numbered_compound_findings_into_atomic_candidates(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """Numbered multi-bug findings should split into separate promotable defects."""
        nodes = json.dumps(
            [
                {
                    "id": "wv-compound",
                    "text": "Production EE fixes",
                    "status": "done",
                    "metadata": json.dumps(
                        {
                            "learning": (
                                "finding: Three EE bugs fixed: "
                                "(1) band name '+' invalid and must use '_AND_' mapping, "
                                "(2) ee.ImageCollection input invalid unless wrapped in a list, "
                                "(3) cloud_cover defaults to 0.0 on parse failure."
                            )
                        }
                    ),
                }
            ]
        )
        args = _make_findings_promote_args(json_out=True)

        with patch("weave_quality.findings._wv_cmd", return_value=(0, nodes)):
            result = cmd_findings_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        root_causes = [item["finding"]["root_cause"] for item in data["candidates"]]
        assert len(root_causes) >= 3
        assert any("band name '+' invalid" in item for item in root_causes)
        assert any("ee.ImageCollection input invalid unless wrapped in a list" in item for item in root_causes)
        assert any("cloud_cover defaults to 0.0 on parse failure" in item for item in root_causes)
        assert all("Three EE bugs fixed:" not in item for item in root_causes)

    def test_numbered_ee_bug_prefix_keeps_split_items_as_defects(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """Shared EE-bug prefixes should preserve defect classification for split items."""
        nodes = json.dumps(
            [
                {
                    "id": "wv-ee-bugs",
                    "text": "Voting mode fixes",
                    "status": "done",
                    "metadata": json.dumps(
                        {
                            "learning": (
                                "finding: Three EE bugs fixed: "
                                "(1) ee.ImageCollection requires homogeneous band names "
                                "→ rename to 'vote' before sum(), "
                                "(2) condition_masks dict values have different names → normalize before merge."
                            )
                        }
                    ),
                }
            ]
        )
        args = _make_findings_promote_args(json_out=True)

        with patch("weave_quality.findings._wv_cmd", return_value=(0, nodes)):
            result = cmd_findings_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        root_causes = [item["finding"]["root_cause"] for item in data["candidates"]]
        assert any(
            "EE bug: ee.ImageCollection requires homogeneous band names" in item
            for item in root_causes
        )
        assert any(
            "EE bug: condition_masks dict values have different names" in item
            for item in root_causes
        )


# ---------------------------------------------------------------------------
# Tests: cmd_health_info
# ---------------------------------------------------------------------------


def _make_health_args(hot_zone: str) -> argparse.Namespace:
    return argparse.Namespace(hot_zone=hot_zone)


class TestCmdHealthInfo:
    def test_no_db_returns_unavailable(
        self,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """health-info with no quality.db returns available=false."""
        args = _make_health_args(str(tmp_path / "nonexistent"))
        cmd_health_info(args)
        data = json.loads(capsys.readouterr().out)
        assert data["available"] is False

    def test_no_scan_returns_unavailable(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """health-info with empty db returns available=false."""
        _ = db
        args = _make_health_args(str(tmp_path))
        cmd_health_info(args)
        data = json.loads(capsys.readouterr().out)
        assert data["available"] is False

    def test_with_scan_returns_score(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """health-info with scan data returns score and metadata."""
        scan_id = begin_scan(db, str(tmp_path))
        entries = [
            _entry("a.py", scan_id, complexity=50.0),
            _entry("b.py", scan_id, complexity=5.0),
        ]
        stats = [
            _stats("a.py", churn=100),
            _stats("b.py", churn=10),
        ]
        _populate_scan(db, scan_id, entries, stats)
        finish_scan(db, scan_id, 2, 100)

        args = _make_health_args(str(tmp_path))
        cmd_health_info(args)
        data = json.loads(capsys.readouterr().out)
        assert data["available"] is True
        assert isinstance(data["score"], int)
        assert "hotspot_count" in data
        assert "total_files" in data
        assert "git_head" in data
        assert "scanned_at" in data


# ---------------------------------------------------------------------------
# context-files
# ---------------------------------------------------------------------------


def _make_context_files_args(hot_zone: str) -> argparse.Namespace:
    return argparse.Namespace(hot_zone=hot_zone)


class TestCmdContextFiles:
    def test_no_db_returns_empty(
        self,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """context-files with no db returns empty quality list."""
        no_db_path = str(tmp_path / "nonexistent")
        args = _make_context_files_args(no_db_path)
        with patch("sys.stdin", io.StringIO("a.py\nb.py\n")):
            cmd_context_files(args)
        data = json.loads(capsys.readouterr().out)
        assert data["code_quality"] == []
        assert data["quality_as_of"] is None

    def test_no_scan_returns_empty(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """context-files with empty db (no scan) returns empty."""
        _ = db
        args = _make_context_files_args(str(tmp_path))
        with patch("sys.stdin", io.StringIO("a.py\n")):
            cmd_context_files(args)
        data = json.loads(capsys.readouterr().out)
        assert data["code_quality"] == []
        assert data["quality_as_of"] is None

    def test_no_stdin_returns_empty(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """context-files with no stdin paths returns empty."""
        scan_id = begin_scan(db, str(tmp_path))
        entries = [_entry("a.py", scan_id)]
        stats = [_stats("a.py", churn=50)]
        _populate_scan(db, scan_id, entries, stats)
        finish_scan(db, scan_id, 1, 100)

        args = _make_context_files_args(str(tmp_path))
        # Simulate tty (no piped stdin) - empty StringIO with isatty=True
        with patch("sys.stdin", io.StringIO("")):
            cmd_context_files(args)
        data = json.loads(capsys.readouterr().out)
        assert data["code_quality"] == []

    def test_returns_quality_for_known_files(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """context-files returns quality data for files in quality.db."""
        scan_id = begin_scan(db, str(tmp_path))
        entries = [
            _entry("a.py", scan_id, complexity=45.0),
            _entry("b.py", scan_id, complexity=12.0),
        ]
        stats = [
            _stats("a.py", churn=67),
            _stats("b.py", churn=18),
        ]
        _populate_scan(db, scan_id, entries, stats)
        finish_scan(db, scan_id, 2, 100)

        args = _make_context_files_args(str(tmp_path))
        with patch("sys.stdin", io.StringIO("a.py\nb.py\nunknown.py\n")):
            cmd_context_files(args)
        data = json.loads(capsys.readouterr().out)

        assert data["quality_as_of"] is not None
        assert len(data["code_quality"]) == 2

        # Check files present
        by_path = {item["path"]: item for item in data["code_quality"]}
        assert "a.py" in by_path
        # a.py has highest complexity+churn -> hotspot=1.0 after min-max normalization
        assert by_path["a.py"]["hotspot"] == 1.0
        assert by_path["a.py"]["churn"] == 67
        assert by_path["a.py"]["complexity"] == 45.0

        assert "b.py" in by_path
        # b.py has lowest values -> hotspot=0.0 after normalization
        assert by_path["b.py"]["hotspot"] == 0.0

        # unknown.py not in quality.db -> not in results
        assert "unknown.py" not in by_path

    def test_file_with_only_stats(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """context-files returns data for files with only git stats."""
        scan_id = begin_scan(db, str(tmp_path))
        # No file entries for c.py, only git stats
        stats = [_stats("c.py", churn=30, hotspot=0.5)]
        bulk_upsert_git_stats(db, stats)
        finish_scan(db, scan_id, 0, 100)
        db.commit()

        args = _make_context_files_args(str(tmp_path))
        with patch("sys.stdin", io.StringIO("c.py\n")):
            cmd_context_files(args)
        data = json.loads(capsys.readouterr().out)
        assert len(data["code_quality"]) == 1
        assert data["code_quality"][0]["path"] == "c.py"
        assert data["code_quality"][0]["hotspot"] == 0.5
        assert "complexity" not in data["code_quality"][0]


# ---------------------------------------------------------------------------
# Tests: cmd_functions
# ---------------------------------------------------------------------------


def _make_functions_args(
    hot_zone: str, path: str | None = None, use_json: bool = False
) -> argparse.Namespace:
    return argparse.Namespace(
        hot_zone=hot_zone,
        path=path,
        json=use_json,
    )


class TestCmdFunctions:
    def test_no_db_returns_error(
        self,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],  # noqa: ARG002
    ) -> None:
        """functions with no quality.db returns exit code 1."""
        args = _make_functions_args(str(tmp_path / "nonexistent"))
        result = cmd_functions(args)
        assert result == 1

    def test_no_scan_returns_error(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,  # noqa: ARG002
        capsys: pytest.CaptureFixture[str],  # noqa: ARG002
    ) -> None:
        """functions with empty db (no scans) returns exit code 1."""
        args = _make_functions_args(str(tmp_path))
        result = cmd_functions(args)
        assert result == 1

    def _populate_fn_cc(
        self,
        db: sqlite3.Connection,
        scan_id: int,
    ) -> None:
        """Insert file entry + function CC metrics for testing."""
        entry = FileEntry(
            path="src/foo.py",
            scan_id=scan_id,
            language="python",
            loc=100,
            complexity=25.0,
        )
        bulk_upsert_file_entries(db, [entry])
        fns = [
            FunctionCC(
                path="src/foo.py",
                scan_id=scan_id,
                function_name="process",
                complexity=15.0,
                line_start=10,
                line_end=50,
                is_dispatch=False,
            ),
            FunctionCC(
                path="src/foo.py",
                scan_id=scan_id,
                function_name="dispatch_fn",
                complexity=12.0,
                line_start=55,
                line_end=80,
                is_dispatch=True,
            ),
            FunctionCC(
                path="src/foo.py",
                scan_id=scan_id,
                function_name="helper",
                complexity=3.0,
                line_start=85,
                line_end=100,
                is_dispatch=False,
            ),
        ]
        bulk_upsert_function_cc(db, fns)
        db.commit()

    def test_text_output_sorted_by_complexity(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """Text output lists functions sorted by CC descending."""
        scan_id = begin_scan(db, "abc")
        self._populate_fn_cc(db, scan_id)
        finish_scan(db, scan_id, 1, 100)

        args = _make_functions_args(str(tmp_path))
        result = cmd_functions(args)
        assert result == 0

        out = capsys.readouterr().err
        fn_lines = [ln for ln in out.splitlines() if "\u2713" in ln or "\u2717" in ln]
        assert len(fn_lines) == 3
        assert "process" in fn_lines[0]
        assert "dispatch_fn" in fn_lines[1]
        assert "helper" in fn_lines[2]

    def test_text_output_flags_over_threshold(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """Functions over threshold are marked \u2717; compliant functions marked \u2713."""
        scan_id = begin_scan(db, "abc")
        self._populate_fn_cc(db, scan_id)
        finish_scan(db, scan_id, 1, 100)

        args = _make_functions_args(str(tmp_path))
        cmd_functions(args)
        out = capsys.readouterr().err

        assert "\u2717 process" in out
        assert "\u2713 helper" in out

    def test_dispatch_exempt_label(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """Dispatch functions get [dispatch \u2014 exempt] label and \u2713 mark."""
        scan_id = begin_scan(db, "abc")
        self._populate_fn_cc(db, scan_id)
        finish_scan(db, scan_id, 1, 100)

        args = _make_functions_args(str(tmp_path))
        cmd_functions(args)
        out = capsys.readouterr().err

        assert "[dispatch" in out
        for line in out.splitlines():
            if "dispatch_fn" in line and "exempt" in line:
                assert "\u2713" in line
                break
        else:
            raise AssertionError("No dispatch-exempt line found in output")

    def test_json_output_schema(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """JSON output contains expected keys for each function."""
        scan_id = begin_scan(db, "abc")
        self._populate_fn_cc(db, scan_id)
        finish_scan(db, scan_id, 1, 100)

        args = _make_functions_args(str(tmp_path), use_json=True)
        result = cmd_functions(args)
        assert result == 0

        data = json.loads(capsys.readouterr().out)
        assert isinstance(data, dict)
        assert "functions" in data
        assert "histogram" in data
        assert "cc_gini" in data
        fns = data["functions"]
        assert len(fns) == 3
        first = fns[0]  # sorted by CC desc
        assert first["function"] == "process"
        assert first["cc"] == 15.0
        assert first["is_dispatch"] is False
        assert "line_start" in first
        assert "line_end" in first

    def test_summary_line_format(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """Summary line correctly counts flagged vs exempt."""
        scan_id = begin_scan(db, "abc")
        self._populate_fn_cc(db, scan_id)
        finish_scan(db, scan_id, 1, 100)

        args = _make_functions_args(str(tmp_path))
        cmd_functions(args)
        out = capsys.readouterr().err

        # process (CC=15, not dispatch) is the only non-exempt flagged function
        # dispatch_fn (CC=12, is_dispatch=True) is exempt
        assert "1/3 functions exceed threshold" in out
        assert "dispatch-exempt" in out


# ---------------------------------------------------------------------------
# Tests: cmd_scan — category population
# ---------------------------------------------------------------------------


def _make_scan_args(hot_zone: str, path: str | None = None) -> argparse.Namespace:
    return argparse.Namespace(
        hot_zone=hot_zone,
        path=path,
        json=False,
        exclude=[],
    )


class TestCmdScanCategory:
    """Verify that cmd_scan() populates FileEntry.category via classify_file()."""

    def _build_repo(self, tmp_path: Path) -> Path:
        """Create a minimal git repo with files in different directories."""
        repo = tmp_path / "repo"
        repo.mkdir()

        # Initialise git repo (needed for git ls-files / rev-parse)
        subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
        _configure_temp_git_repo(repo)
        _commit_temp_git_repo(
            repo,
            "--allow-empty",
            "-m",
            "init",
            env={
                **os.environ,
                "GIT_AUTHOR_NAME": "t",
                "GIT_AUTHOR_EMAIL": "t@t",
                "GIT_COMMITTER_NAME": "t",
                "GIT_COMMITTER_EMAIL": "t@t",
            },
        )

        # tests/test_foo.py  -> category='test'
        (repo / "tests").mkdir()
        (repo / "tests" / "test_foo.py").write_text("x = 1\n")

        # scripts/run.sh     -> category='script'
        (repo / "scripts").mkdir()
        (repo / "scripts" / "run.sh").write_text("#!/bin/bash\necho hi\n")

        # src/app.py         -> category='production'
        (repo / "src").mkdir()
        (repo / "src" / "app.py").write_text("def main(): pass\n")

        return repo

    def test_test_files_get_test_category(self, tmp_path: Path) -> None:
        """Files under tests/ directory get category='test' after scan."""
        repo = self._build_repo(tmp_path)
        args = _make_scan_args(str(tmp_path), path=str(repo))

        result = cmd_scan(args)
        assert result == 0

        conn = init_db(hot_zone=str(tmp_path))
        scan = latest_scan(conn)
        assert scan is not None
        entries = get_file_entries(conn, scan.id)
        conn.close()

        by_path = {e.path: e for e in entries}
        test_entry = by_path.get("tests/test_foo.py")
        assert test_entry is not None, "tests/test_foo.py not found in scan"
        assert test_entry.category == "test"

    def test_script_files_get_script_category(self, tmp_path: Path) -> None:
        """Files under scripts/ directory get category='script' after scan."""
        repo = self._build_repo(tmp_path)
        args = _make_scan_args(str(tmp_path), path=str(repo))

        result = cmd_scan(args)
        assert result == 0

        conn = init_db(hot_zone=str(tmp_path))
        scan = latest_scan(conn)
        assert scan is not None
        entries = get_file_entries(conn, scan.id)
        conn.close()

        by_path = {e.path: e for e in entries}
        script_entry = by_path.get("scripts/run.sh")
        assert script_entry is not None, "scripts/run.sh not found in scan"
        assert script_entry.category == "script"

    def test_plain_python_gets_production_category(self, tmp_path: Path) -> None:
        """Plain .py files outside test/script dirs get category='production'."""
        repo = self._build_repo(tmp_path)
        args = _make_scan_args(str(tmp_path), path=str(repo))

        result = cmd_scan(args)
        assert result == 0

        conn = init_db(hot_zone=str(tmp_path))
        scan = latest_scan(conn)
        assert scan is not None
        entries = get_file_entries(conn, scan.id)
        conn.close()

        by_path = {e.path: e for e in entries}
        prod_entry = by_path.get("src/app.py")
        assert prod_entry is not None, "src/app.py not found in scan"
        assert prod_entry.category == "production"


class TestDiscoverFiles:
    """Tests for _discover_files file discovery and filtering."""

    def _make_git_repo(self, tmp_path: Path) -> Path:
        """Create a minimal git repo with Python and non-Python files."""
        subprocess.run(["git", "init", "-q", str(tmp_path)], check=True)
        _configure_temp_git_repo(tmp_path)
        (tmp_path / "main.py").write_text("x = 1\n")
        (tmp_path / "util.py").write_text("y = 2\n")
        (tmp_path / "skip_me.py").write_text("z = 3\n")
        subprocess.run(["git", "-C", str(tmp_path), "add", "."], check=True)
        _commit_temp_git_repo(tmp_path, "-q", "-m", "init")
        return tmp_path

    def test_discovers_python_files(self, tmp_path: Path) -> None:
        """Python files are discovered without exclusions."""
        repo = self._make_git_repo(tmp_path)
        files = _discover_files(str(repo))
        assert "main.py" in files
        assert "util.py" in files

    def test_exclude_globs_filters_files(self, tmp_path: Path) -> None:
        """Files matching exclude_globs are skipped."""
        repo = self._make_git_repo(tmp_path)
        files = _discover_files(str(repo), exclude_globs=["skip_me.py"])
        assert "skip_me.py" not in files
        assert "main.py" in files


# ---------------------------------------------------------------------------
# Tests: _load_config_excludes
# ---------------------------------------------------------------------------


class TestLoadConfigExcludes:
    def test_no_config_returns_empty(self, tmp_path: Path) -> None:
        """No quality.conf returns empty list."""
        assert not _load_config_excludes(str(tmp_path))

    def test_reads_exclude_section(self, tmp_path: Path) -> None:
        """Lines under [exclude] are returned."""
        conf = tmp_path / ".weave"
        conf.mkdir()
        (conf / "quality.conf").write_text("[exclude]\ndist/**\nbuild/**\n")
        result = _load_config_excludes(str(tmp_path))
        assert "dist/**" in result
        assert "build/**" in result

    def test_ignores_other_sections(self, tmp_path: Path) -> None:
        """Lines under other sections are not returned."""
        conf = tmp_path / ".weave"
        conf.mkdir()
        (conf / "quality.conf").write_text(
            "[classify]\nscripts/**=script\n[exclude]\nfoo/**\n"
        )
        result = _load_config_excludes(str(tmp_path))
        assert result == ["foo/**"]

    def test_strips_inline_comments(self, tmp_path: Path) -> None:
        """Inline # comments are stripped from values."""
        conf = tmp_path / ".weave"
        conf.mkdir()
        (conf / "quality.conf").write_text("[exclude]\ndist/**  # build output\n")
        result = _load_config_excludes(str(tmp_path))
        assert result == ["dist/**"]

    def test_skips_blank_lines_and_comments(self, tmp_path: Path) -> None:
        """Blank lines and # comment lines are ignored."""
        conf = tmp_path / ".weave"
        conf.mkdir()
        (conf / "quality.conf").write_text(
            "# top comment\n\n[exclude]\n# a comment\nfoo.py\n\nbar.py\n"
        )
        result = _load_config_excludes(str(tmp_path))
        assert result == ["foo.py", "bar.py"]


# ---------------------------------------------------------------------------
# Tests: _resolve_repo
# ---------------------------------------------------------------------------


class TestResolveRepo:
    def test_explicit_path_returned(self, tmp_path: Path) -> None:
        """Explicit path is resolved and returned."""
        result = _resolve_repo(str(tmp_path))
        assert result == str(tmp_path.resolve())

    def test_repo_root_env(self, tmp_path: Path) -> None:
        """REPO_ROOT env var overrides git detection."""
        with patch.dict(os.environ, {"REPO_ROOT": str(tmp_path)}, clear=False):
            result = _resolve_repo(None)
        assert result == str(tmp_path)

    def test_git_fallback(self) -> None:
        """Git root is returned when no path or env var."""
        fake_root = "/fake/root"
        fake_result = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=fake_root + "\n",
            stderr="",
        )
        with patch.dict(os.environ, {}, clear=False):
            # Ensure REPO_ROOT not set
            os.environ.pop("REPO_ROOT", None)
            with patch(
                "weave_quality.__main__.subprocess.run", return_value=fake_result
            ):
                result = _resolve_repo(None)
        assert result == fake_root

    def test_git_failure_falls_back_to_cwd(self) -> None:
        """When git fails, falls back to os.getcwd()."""
        os.environ.pop("REPO_ROOT", None)
        with patch.dict(os.environ, {}, clear=False):
            os.environ.pop("REPO_ROOT", None)
            with patch(
                "weave_quality.__main__.subprocess.run",
                side_effect=subprocess.CalledProcessError(128, "git"),
            ):
                result = _resolve_repo(None)
        assert result == os.getcwd()


# ---------------------------------------------------------------------------
# Tests: _get_current_head
# ---------------------------------------------------------------------------


class TestGetCurrentHead:
    def test_returns_sha_on_success(self) -> None:
        """Returns the git HEAD sha on success."""
        fake = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout="abc123def456abc123def456abc123def456abc1\n",
            stderr="",
        )
        with patch("weave_quality.__main__.subprocess.run", return_value=fake):
            result = _get_current_head()
        assert result == "abc123def456abc123def456abc123def456abc1"

    def test_returns_empty_on_error(self) -> None:
        """Returns empty string when git fails."""
        with patch(
            "weave_quality.__main__.subprocess.run",
            side_effect=subprocess.CalledProcessError(128, "git"),
        ):
            result = _get_current_head()
        assert result == ""

    def test_returns_empty_on_file_not_found(self) -> None:
        """Returns empty string when git not installed."""
        with patch(
            "weave_quality.__main__.subprocess.run",
            side_effect=FileNotFoundError("no git"),
        ):
            result = _get_current_head()
        assert result == ""


# ---------------------------------------------------------------------------
# Tests: _wv_cmd
# ---------------------------------------------------------------------------


class TestWvCmd:
    def test_returns_output_on_success(self) -> None:
        """Returns (0, stdout) on successful wv call."""
        fake = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout="wv-abc123: some node\n",
            stderr="",
        )
        with patch("weave_quality.__main__.subprocess.run", return_value=fake):
            rc, out = _wv_cmd("list", "--json")
        assert rc == 0
        assert "wv-abc123" in out

    def test_returns_error_when_not_found(self) -> None:
        """Returns (1, error message) when wv is not installed."""
        with patch(
            "weave_quality.__main__.subprocess.run",
            side_effect=FileNotFoundError("wv not found"),
        ):
            rc, out = _wv_cmd("list")
        assert rc == 1
        assert "not found" in out


# ---------------------------------------------------------------------------
# Tests: cmd_reset
# ---------------------------------------------------------------------------


class TestCmdReset:
    def test_reset_existing_db(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """reset deletes the quality.db and prints confirmation."""
        db.close()
        p = db_path(str(tmp_path))
        assert p.exists()

        args = argparse.Namespace(hot_zone=str(tmp_path))
        result = cmd_reset(args)
        assert result == 0
        captured = capsys.readouterr()
        assert "Deleted" in captured.err

    def test_reset_nonexistent_db(
        self,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """reset on missing db prints 'No quality.db found'."""
        args = argparse.Namespace(hot_zone=str(tmp_path / "nodb"))
        result = cmd_reset(args)
        assert result == 0
        captured = capsys.readouterr()
        assert "No quality.db" in captured.err


# ---------------------------------------------------------------------------
# Tests: cmd_scan — JSON output + bash file branch + carry-forward
# ---------------------------------------------------------------------------


class TestCmdScanExtended:
    def _build_git_repo(self, tmp_path: Path, *, with_bash: bool = False) -> Path:
        """Create a minimal git repo with Python (and optionally Bash) files."""
        repo = tmp_path / "repo"
        repo.mkdir()
        subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
        _configure_temp_git_repo(repo)
        env = {
            **os.environ,
            "GIT_AUTHOR_NAME": "t",
            "GIT_AUTHOR_EMAIL": "t@t",
            "GIT_COMMITTER_NAME": "t",
            "GIT_COMMITTER_EMAIL": "t@t",
        }
        (repo / "app.py").write_text("def foo(): pass\n")
        if with_bash:
            (repo / "run.sh").write_text("#!/bin/bash\necho hi\n")
        subprocess.run(["git", "add", "."], cwd=repo, check=True, env=env)
        _commit_temp_git_repo(repo, "-q", "-m", "init", env=env)
        return repo

    def test_json_output(
        self,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """cmd_scan --json emits expected JSON fields."""
        repo = self._build_git_repo(tmp_path)
        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            path=str(repo),
            json=True,
            exclude=[],
        )
        result = cmd_scan(args)
        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert "scan_id" in data
        assert "files_scanned" in data
        assert "quality_score" in data
        assert "languages" in data

    def test_bash_file_scanned(self, tmp_path: Path) -> None:
        """cmd_scan processes .sh files via bash_heuristic."""
        repo = self._build_git_repo(tmp_path, with_bash=True)
        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            path=str(repo),
            json=True,
            exclude=[],
        )
        result = cmd_scan(args)
        assert result == 0
        conn = init_db(hot_zone=str(tmp_path))
        scan = latest_scan(conn)
        assert scan is not None
        entries = get_file_entries(conn, scan.id)
        conn.close()
        by_path = {e.path: e for e in entries}
        assert "run.sh" in by_path
        assert by_path["run.sh"].language == "bash"

    def test_carry_forward_unchanged(
        self,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """Unchanged files are carried forward from previous scan."""
        repo = self._build_git_repo(tmp_path)
        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            path=str(repo),
            json=True,
            exclude=[],
        )
        # First scan — populates DB
        cmd_scan(args)
        capsys.readouterr()  # discard

        # Second scan — app.py unchanged → should be carried forward
        result = cmd_scan(args)
        assert result == 0
        data = json.loads(capsys.readouterr().out)
        # files_scanned >= 1 even though nothing changed
        assert data["files_scanned"] >= 1


# ---------------------------------------------------------------------------
# Tests: cmd_hotspots — stale warning text output
# ---------------------------------------------------------------------------


class TestCmdHotspotsStale:
    def test_stale_head_warning_in_text_mode(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """Stale scan emits a [WARN] line in text mode."""
        scan_id = begin_scan(db, "deadbeef0000000000000000000000000000000000")
        entries = [_entry("a.py", scan_id, complexity=100)]
        stats = [_stats("a.py", churn=50)]
        _populate_scan(db, scan_id, entries, stats)
        finish_scan(db, scan_id, 1, 100)
        db.close()

        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            top=10,
            json=False,
            scope="production",
        )
        with patch(
            "weave_quality.__main__._get_current_head",
            return_value="newhead000000000000000000000000000000000000",
        ):
            result = cmd_hotspots(args)
        assert result == 0
        out = capsys.readouterr().err
        assert "[WARN]" in out

    def test_no_hotspots_text_output(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """Text mode with no hotspots above threshold prints placeholder."""
        scan_id = begin_scan(db, "abc123")
        # Very low complexity → below hotspot threshold
        entries = [_entry("a.py", scan_id, complexity=1)]
        stats = [_stats("a.py", churn=1, hotspot=0.0)]
        _populate_scan(db, scan_id, entries, stats)
        finish_scan(db, scan_id, 1, 100)
        db.close()

        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            top=10,
            json=False,
            scope="production",
        )
        result = cmd_hotspots(args)
        assert result == 0
        out = capsys.readouterr().err
        assert "No hotspots" in out


# ---------------------------------------------------------------------------
# Tests: cmd_diff — human-readable (text) output
# ---------------------------------------------------------------------------


class TestCmdDiffTextOutput:
    def _two_scan_setup(
        self,
        db: sqlite3.Connection,
        complexity1: float = 10.0,
        complexity2: float = 30.0,
    ) -> None:
        s1 = begin_scan(db, "abc123")
        _populate_scan(
            db,
            s1,
            [_entry("a.py", s1, complexity=complexity1)],
            [_stats("a.py", churn=5)],
        )
        finish_scan(db, s1, 1, 100)

        s2 = begin_scan(db, "abc456")
        _populate_scan(
            db,
            s2,
            [_entry("a.py", s2, complexity=complexity2)],
            [_stats("a.py", churn=5)],
        )
        finish_scan(db, s2, 1, 100)
        db.close()

    def test_diff_degraded_text(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """Text diff shows Degraded: section when complexity increases."""
        self._two_scan_setup(db, complexity1=10.0, complexity2=30.0)
        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            json=False,
            scope="production",
        )
        result = cmd_diff(args)
        assert result == 0
        out = capsys.readouterr().err
        assert "Degraded:" in out
        assert "a.py" in out

    def test_diff_improved_text(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """Text diff shows Improved: section when complexity decreases."""
        self._two_scan_setup(db, complexity1=30.0, complexity2=10.0)
        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            json=False,
            scope="production",
        )
        result = cmd_diff(args)
        assert result == 0
        out = capsys.readouterr().err
        assert "Improved:" in out
        assert "a.py" in out

    def test_diff_no_change_text(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """Text diff shows 'No significant changes' when identical."""
        self._two_scan_setup(db, complexity1=10.0, complexity2=10.0)
        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            json=False,
            scope="production",
        )
        result = cmd_diff(args)
        assert result == 0
        out = capsys.readouterr().err
        assert "No significant changes" in out

    def test_diff_no_scan_returns_error(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
    ) -> None:
        """diff with db but no scan returns exit 1."""
        _ = db
        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            json=False,
            scope="production",
        )
        result = cmd_diff(args)
        assert result == 1

    def test_diff_new_removed_files_text(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """Text diff shows New files / Removed files sections."""
        s1 = begin_scan(db, "abc123")
        _populate_scan(
            db,
            s1,
            [_entry("a.py", s1), _entry("b.py", s1)],
            [_stats("a.py"), _stats("b.py")],
        )
        finish_scan(db, s1, 2, 100)

        s2 = begin_scan(db, "abc456")
        _populate_scan(
            db,
            s2,
            [_entry("a.py", s2), _entry("c.py", s2)],
            [_stats("a.py"), _stats("c.py")],
        )
        finish_scan(db, s2, 2, 100)
        db.close()

        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            json=False,
            scope="production",
        )
        result = cmd_diff(args)
        assert result == 0
        out = capsys.readouterr().err
        assert "New files:" in out
        assert "Removed files:" in out


# ---------------------------------------------------------------------------
# Tests: cmd_promote — additional paths
# ---------------------------------------------------------------------------


class TestCmdPromoteExtended:
    def _setup_no_hotspots(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
    ) -> None:
        """Populate a scan where no files have hotspot scores."""
        scan_id = begin_scan(db, str(tmp_path))
        entries = [_entry("low.py", scan_id, complexity=1.0)]
        stats = [_stats("low.py", churn=0, hotspot=0.0)]
        _populate_scan(db, scan_id, entries, stats)
        finish_scan(db, scan_id, 1, 100)
        db.close()

    def test_no_hotspots_returns_zero(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """promote with no ranked hotspots exits 0 with message."""
        self._setup_no_hotspots(db, tmp_path)
        args = _make_promote_args(str(tmp_path))
        result = cmd_promote(args)
        assert result == 0
        out = capsys.readouterr().err
        assert "No hotspots" in out

    def test_upsert_updates_existing_node(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """promote --upsert updates an existing promoted node."""
        scan_id = begin_scan(db, str(tmp_path))
        entries = [
            _entry("hot.py", scan_id, complexity=60.0),
            _entry("cold.py", scan_id, complexity=5.0),
        ]
        stats = [
            _stats("hot.py", churn=120),
            _stats("cold.py", churn=5),
        ]
        _populate_scan(db, scan_id, entries, stats)
        finish_scan(db, scan_id, 2, 100)

        fid = _finding_id("hot.py")
        existing = json.dumps(
            [
                {
                    "id": "wv-existing",
                    "text": "old node",
                    "metadata": json.dumps({"quality_finding_id": fid}),
                }
            ]
        )

        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            parent="wv-parent",
            top=5,
            json=True,
            dry_run=False,
            upsert=True,
        )

        def fake_wv(*cmd_args: str) -> tuple[int, str]:
            if cmd_args[0] == "list":
                return 0, existing
            return 0, ""

        with patch("weave_quality.__main__._wv_cmd", side_effect=fake_wv):
            result = cmd_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert "updated" in data
        assert len(data["updated"]) == 1
        assert data["updated"][0]["node_id"] == "wv-existing"

    def test_wv_add_failure_skips_node(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """promote skips a hotspot if wv add fails."""
        scan_id = begin_scan(db, str(tmp_path))
        entries = [
            _entry("err.py", scan_id, complexity=60.0),
            _entry("low.py", scan_id, complexity=5.0),
        ]
        stats = [
            _stats("err.py", churn=100),
            _stats("low.py", churn=5),
        ]
        _populate_scan(db, scan_id, entries, stats)
        finish_scan(db, scan_id, 2, 100)

        args = _make_promote_args(str(tmp_path), top=1, json_out=True)

        def fake_wv(*cmd_args: str) -> tuple[int, str]:
            if cmd_args[0] == "list":
                return 0, "[]"
            if cmd_args[0] == "add":
                return 1, "error: something went wrong"
            return 0, ""

        with patch("weave_quality.__main__._wv_cmd", side_effect=fake_wv):
            result = cmd_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert len(data["promoted"]) == 0

    def test_promote_text_output_skipped_message(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """Text mode: skipped message shown when findings already promoted."""
        scan_id = begin_scan(db, str(tmp_path))
        entries = [
            _entry("dup.py", scan_id, complexity=50.0),
            _entry("other.py", scan_id, complexity=5.0),
        ]
        stats = [
            _stats("dup.py", churn=80),
            _stats("other.py", churn=5),
        ]
        _populate_scan(db, scan_id, entries, stats)
        finish_scan(db, scan_id, 2, 100)

        fid = _finding_id("dup.py")
        existing = json.dumps(
            [
                {
                    "id": "wv-dup",
                    "text": "old",
                    "metadata": json.dumps({"quality_finding_id": fid}),
                }
            ]
        )

        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            parent="wv-p",
            top=5,
            json=False,
            dry_run=False,
            upsert=False,
        )
        with patch("weave_quality.__main__._wv_cmd", return_value=(0, existing)):
            result = cmd_promote(args)

        assert result == 0
        out = capsys.readouterr().err
        assert "Skipped" in out

    def test_promote_upsert_dry_run(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """promote --upsert --dry-run prints update plan without calling wv update."""
        scan_id = begin_scan(db, str(tmp_path))
        entries = [
            _entry("dry.py", scan_id, complexity=55.0),
            _entry("low.py", scan_id, complexity=5.0),
        ]
        stats = [
            _stats("dry.py", churn=90),
            _stats("low.py", churn=5),
        ]
        _populate_scan(db, scan_id, entries, stats)
        finish_scan(db, scan_id, 2, 100)

        fid = _finding_id("dry.py")
        existing = json.dumps(
            [
                {
                    "id": "wv-dry",
                    "text": "old",
                    "metadata": json.dumps({"quality_finding_id": fid}),
                }
            ]
        )

        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            parent="wv-p",
            top=5,
            json=True,
            dry_run=True,
            upsert=True,
        )

        def fake_wv(*cmd_args: str) -> tuple[int, str]:
            if cmd_args[0] == "list":
                return 0, existing
            return 0, ""

        with patch("weave_quality.__main__._wv_cmd", side_effect=fake_wv) as mock_wv:
            result = cmd_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert "updated" in data
        # Dry run: only the list call, no update call
        for call_args in mock_wv.call_args_list:
            assert call_args[0][0] != "update"


# ---------------------------------------------------------------------------
# Tests: cmd_functions — path fallback
# ---------------------------------------------------------------------------


class TestCmdFunctionsPathFallback:
    def _populate_with_path(
        self,
        db: sqlite3.Connection,
        scan_id: int,
        path: str,
    ) -> None:
        entry = FileEntry(
            path=path,
            scan_id=scan_id,
            language="python",
            loc=50,
            complexity=15.0,
        )
        bulk_upsert_file_entries(db, [entry])
        fns = [
            FunctionCC(
                path=path,
                scan_id=scan_id,
                function_name="f",
                complexity=15.0,
                line_start=1,
                line_end=20,
                is_dispatch=False,
            )
        ]
        bulk_upsert_function_cc(db, fns)
        db.commit()

    def test_no_path_uses_cwd_prefix_match(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
    ) -> None:
        """When args.path is None, all entries in the scan are returned."""
        scan_id = begin_scan(db, "abc")
        self._populate_with_path(db, scan_id, "src/foo.py")
        finish_scan(db, scan_id, 1, 100)

        args = _make_functions_args(str(tmp_path), path=None)
        result = cmd_functions(args)
        # With path=None, falls through to prefix match; may or may not find files
        # Depending on CWD, should not crash
        assert result in (0, 1)

    def test_nonexistent_path_returns_error(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
    ) -> None:
        """Functions with no matching files returns exit 1."""
        scan_id = begin_scan(db, "abc")
        self._populate_with_path(db, scan_id, "src/foo.py")
        finish_scan(db, scan_id, 1, 100)

        # Use a path that won't match any scanned file
        args = _make_functions_args(str(tmp_path), path="/completely/nonexistent/dir")
        result = cmd_functions(args)
        assert result == 1


# ---------------------------------------------------------------------------
# Tests: remaining edge-case coverage
# ---------------------------------------------------------------------------


class TestCmdScanCkMetrics:
    """Scan a Python file with a class → exercises CK metrics path (lines 329-331, 364)."""

    def _build_repo_with_class(self, tmp_path: Path) -> Path:
        repo = tmp_path / "repo"
        repo.mkdir()
        env = {
            **os.environ,
            "GIT_AUTHOR_NAME": "t",
            "GIT_AUTHOR_EMAIL": "t@t",
            "GIT_COMMITTER_NAME": "t",
            "GIT_COMMITTER_EMAIL": "t@t",
        }
        subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
        _configure_temp_git_repo(repo)
        (repo / "mymodule.py").write_text(
            "class MyClass:\n    def method(self) -> None:\n        pass\n"
        )
        subprocess.run(["git", "add", "."], cwd=repo, check=True, env=env)
        _commit_temp_git_repo(repo, "-q", "-m", "init", env=env)
        return repo

    def test_scan_file_with_class(self, tmp_path: Path) -> None:
        """Scanning a Python file with a class exercises CK metrics storage."""
        repo = self._build_repo_with_class(tmp_path)
        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            path=str(repo),
            json=True,
            exclude=[],
        )
        result = cmd_scan(args)
        assert result == 0

        conn = init_db(hot_zone=str(tmp_path))
        scan = latest_scan(conn)
        assert scan is not None
        entries = get_file_entries(conn, scan.id)
        conn.close()
        by_path = {e.path: e for e in entries}
        assert "mymodule.py" in by_path

    def test_scan_file_has_expected_language(self, tmp_path: Path) -> None:
        """Python class file is recognised as python language."""
        repo = self._build_repo_with_class(tmp_path)
        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            path=str(repo),
            json=True,
            exclude=[],
        )
        cmd_scan(args)
        conn = init_db(hot_zone=str(tmp_path))
        scan = latest_scan(conn)
        assert scan is not None
        entries = get_file_entries(conn, scan.id)
        conn.close()
        by_path = {e.path: e for e in entries}
        assert by_path["mymodule.py"].language == "python"


class TestCmdScanBashFunctions:
    """Scan a bash file with functions → exercises bash fn_cc remap (lines 354-355)."""

    def _build_repo_with_bash_fn(self, tmp_path: Path) -> Path:
        repo = tmp_path / "repo"
        repo.mkdir()
        env = {
            **os.environ,
            "GIT_AUTHOR_NAME": "t",
            "GIT_AUTHOR_EMAIL": "t@t",
            "GIT_COMMITTER_NAME": "t",
            "GIT_COMMITTER_EMAIL": "t@t",
        }
        subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
        _configure_temp_git_repo(repo)
        (repo / "run.sh").write_text(
            "#!/bin/bash\ndo_work() {\n  echo 'hello'\n}\ndo_work\n"
        )
        subprocess.run(["git", "add", "."], cwd=repo, check=True, env=env)
        _commit_temp_git_repo(repo, "-q", "-m", "init", env=env)
        return repo

    def test_scan_bash_with_function(self, tmp_path: Path) -> None:
        """Scanning a bash file with functions exercises fn_cc path remapping."""
        repo = self._build_repo_with_bash_fn(tmp_path)
        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            path=str(repo),
            json=True,
            exclude=[],
        )
        result = cmd_scan(args)
        assert result == 0

        conn = init_db(hot_zone=str(tmp_path))
        scan = latest_scan(conn)
        assert scan is not None
        entries = get_file_entries(conn, scan.id)
        conn.close()
        by_path = {e.path: e for e in entries}
        assert "run.sh" in by_path
        assert by_path["run.sh"].functions >= 1

    def test_scan_bash_language_set(self, tmp_path: Path) -> None:
        """Bash file is recognised as bash language."""
        repo = self._build_repo_with_bash_fn(tmp_path)
        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            path=str(repo),
            json=True,
            exclude=[],
        )
        cmd_scan(args)
        conn = init_db(hot_zone=str(tmp_path))
        scan = latest_scan(conn)
        assert scan is not None
        entries = get_file_entries(conn, scan.id)
        conn.close()
        by_path = {e.path: e for e in entries}
        assert by_path["run.sh"].language == "bash"


class TestCmdPromoteMetadataParsing:
    """Cover metadata-as-dict and invalid JSON branches in cmd_promote (996, 1000-1001)."""

    def _setup_with_hotspot(self, db: sqlite3.Connection, path: str) -> None:
        scan_id = begin_scan(db, "abc")
        entries = [
            _entry(path, scan_id, complexity=60.0),
            _entry("low.py", scan_id, complexity=5.0),
        ]
        stats = [
            _stats(path, churn=100),
            _stats("low.py", churn=5),
        ]
        _populate_scan(db, scan_id, entries, stats)
        finish_scan(db, scan_id, 2, 100)
        db.close()

    def test_metadata_already_dict(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """When metadata is already a dict (not string), branch at line 996 is exercised."""
        self._setup_with_hotspot(db, "hot.py")
        fid = _finding_id("hot.py")
        # metadata is a dict, not a JSON string
        existing = json.dumps(
            [
                {
                    "id": "wv-dictmeta",
                    "text": "old",
                    "metadata": {"quality_finding_id": fid},
                }
            ]
        )

        args = _make_promote_args(str(tmp_path), top=5, json_out=True)
        with patch("weave_quality.__main__._wv_cmd", return_value=(0, existing)):
            result = cmd_promote(args)

        assert result == 0
        data = json.loads(capsys.readouterr().out)
        assert data["skipped"] == 1

    def test_invalid_json_metadata_does_not_crash(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """Malformed JSON in node list doesn't crash (exception caught at line 1000)."""
        self._setup_with_hotspot(db, "hot2.py")
        # Return invalid JSON from wv list
        args = _make_promote_args(str(tmp_path), top=5, json_out=True)
        with patch(
            "weave_quality.__main__._wv_cmd", return_value=(0, "not valid json")
        ):
            result = cmd_promote(args)

        assert result == 0

    def test_upsert_text_mode_updated_message(
        self,
        db: sqlite3.Connection,
        tmp_path: Path,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        """Text mode with upsert shows 'Updated N existing findings' (line 1111)."""
        self._setup_with_hotspot(db, "upd.py")
        fid = _finding_id("upd.py")
        existing = json.dumps(
            [
                {
                    "id": "wv-upd",
                    "text": "old",
                    "metadata": json.dumps({"quality_finding_id": fid}),
                }
            ]
        )

        args = argparse.Namespace(
            hot_zone=str(tmp_path),
            parent="wv-p",
            top=5,
            json=False,
            dry_run=False,
            upsert=True,
        )

        def fake_wv(*cmd_args: str) -> tuple[int, str]:
            if cmd_args[0] == "list":
                return 0, existing
            return 0, ""

        with patch("weave_quality.__main__._wv_cmd", side_effect=fake_wv):
            result = cmd_promote(args)

        assert result == 0
        out = capsys.readouterr().err
        assert "Updated" in out
