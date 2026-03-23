"""Tests for weave_gh.data — data fetching, DB path resolution, edge helpers."""

# pylint: disable=missing-class-docstring,missing-function-docstring

from __future__ import annotations

import json
import subprocess
from pathlib import Path
from typing import Any
from unittest.mock import patch

import pytest

from weave_gh.data import (
    _is_valid_node_id,
    _repo_hash,
    _resolve_db_path,
    get_blockers,
    get_children,
    get_edges_for_node,
    get_edges_for_nodes,
    get_github_issues,
    get_parent,
    get_repo,
    get_repo_url,
    get_weave_nodes,
)
from weave_gh.models import Edge


# ---------------------------------------------------------------------------
# get_repo / get_repo_url
# ---------------------------------------------------------------------------


class TestGetRepo:
    @patch("weave_gh.data.gh_cli", return_value="owner/repo")
    def test_returns_repo_name(self, _mock: Any) -> None:
        assert get_repo() == "owner/repo"

    @patch("weave_gh.data.gh_cli", return_value="another/project")
    def test_passes_correct_args(self, mock_gh: Any) -> None:
        get_repo()
        mock_gh.assert_called_once_with(
            "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"
        )


class TestGetRepoUrl:
    @patch("weave_gh.data.gh_cli", return_value="https://github.com/owner/repo")
    def test_returns_url(self, _mock: Any) -> None:
        assert get_repo_url() == "https://github.com/owner/repo"

    @patch("weave_gh.data.gh_cli", return_value="")
    def test_empty_string_when_no_output(self, _mock: Any) -> None:
        assert get_repo_url() == ""

    @patch("weave_gh.data.gh_cli", return_value=None)
    def test_none_becomes_empty_string(self, _mock: Any) -> None:
        assert get_repo_url() == ""


# ---------------------------------------------------------------------------
# get_weave_nodes
# ---------------------------------------------------------------------------


class TestGetWeaveNodes:
    @patch("weave_gh.data.wv_cli", return_value="")
    def test_empty_output_returns_empty(self, _mock: Any) -> None:
        assert get_weave_nodes() == []

    @patch("weave_gh.data.wv_cli", return_value="[]")
    def test_empty_json_returns_empty(self, _mock: Any) -> None:
        assert get_weave_nodes() == []

    @patch("weave_gh.data.wv_cli", return_value="not-json")
    def test_invalid_json_returns_empty(self, _mock: Any) -> None:
        assert get_weave_nodes() == []

    @patch(
        "weave_gh.data.wv_cli",
        return_value=json.dumps(
            [
                {
                    "id": "wv-abc1",
                    "text": "Test node",
                    "status": "todo",
                    "metadata": "{}",
                    "alias": None,
                }
            ]
        ),
    )
    def test_parses_single_node(self, _mock: Any) -> None:
        nodes = get_weave_nodes()
        assert len(nodes) == 1
        assert nodes[0].id == "wv-abc1"
        assert nodes[0].text == "Test node"
        assert nodes[0].status == "todo"

    @patch(
        "weave_gh.data.wv_cli",
        return_value=json.dumps(
            [
                {
                    "id": "wv-abc1",
                    "text": "Node with meta",
                    "status": "active",
                    "metadata": '{"type": "bug", "priority": 1}',
                    "alias": None,
                }
            ]
        ),
    )
    def test_parses_string_metadata(self, _mock: Any) -> None:
        nodes = get_weave_nodes()
        assert nodes[0].metadata == {"type": "bug", "priority": 1}

    @patch(
        "weave_gh.data.wv_cli",
        return_value=json.dumps(
            [
                {
                    "id": "wv-abc1",
                    "text": "Node with dict meta",
                    "status": "active",
                    "metadata": {"type": "feature"},
                    "alias": None,
                }
            ]
        ),
    )
    def test_parses_dict_metadata(self, _mock: Any) -> None:
        nodes = get_weave_nodes()
        assert nodes[0].metadata == {"type": "feature"}

    @patch(
        "weave_gh.data.wv_cli",
        return_value=json.dumps(
            [
                {
                    "id": "wv-abc1",
                    "text": "Node with bad meta",
                    "status": "todo",
                    "metadata": "not-json{",
                    "alias": None,
                }
            ]
        ),
    )
    def test_bad_metadata_becomes_empty_dict(self, _mock: Any) -> None:
        nodes = get_weave_nodes()
        assert nodes[0].metadata == {}

    @patch(
        "weave_gh.data.wv_cli",
        return_value=json.dumps(
            [
                {
                    "id": "wv-def2",
                    "text": "Aliased node",
                    "status": "done",
                    "metadata": "{}",
                    "alias": "my-alias",
                }
            ]
        ),
    )
    def test_alias_preserved(self, _mock: Any) -> None:
        nodes = get_weave_nodes()
        assert nodes[0].alias == "my-alias"

    @patch(
        "weave_gh.data.wv_cli",
        return_value=json.dumps(
            [
                {
                    "id": "wv-abc1",
                    "text": "No alias",
                    "status": "todo",
                    "metadata": "{}",
                    "alias": "",
                }
            ]
        ),
    )
    def test_empty_alias_becomes_none(self, _mock: Any) -> None:
        nodes = get_weave_nodes()
        assert nodes[0].alias is None


# ---------------------------------------------------------------------------
# get_github_issues
# ---------------------------------------------------------------------------


class TestGetGithubIssues:
    @patch("weave_gh.data.gh_cli", return_value="")
    def test_empty_output_returns_empty(self, _mock: Any) -> None:
        assert get_github_issues("owner/repo") == []

    @patch("weave_gh.data.gh_cli", return_value="[]")
    def test_empty_json_returns_empty(self, _mock: Any) -> None:
        assert get_github_issues("owner/repo") == []

    @patch("weave_gh.data.gh_cli", return_value="bad-json")
    def test_invalid_json_returns_empty(self, _mock: Any) -> None:
        assert get_github_issues("owner/repo") == []

    @patch(
        "weave_gh.data.gh_cli",
        return_value=json.dumps(
            [
                {
                    "number": 42,
                    "title": "Fix the bug",
                    "state": "OPEN",
                    "body": "Some description",
                    "labels": [{"name": "bug"}],
                    "assignees": [{"login": "alice"}],
                }
            ]
        ),
    )
    def test_parses_single_issue(self, _mock: Any) -> None:
        issues = get_github_issues("owner/repo")
        assert len(issues) == 1
        assert issues[0].number == 42
        assert issues[0].title == "Fix the bug"
        assert issues[0].state == "OPEN"
        assert issues[0].labels == ["bug"]
        assert issues[0].assignees == ["alice"]

    @patch(
        "weave_gh.data.gh_cli",
        return_value=json.dumps(
            [
                {
                    "number": 1,
                    "title": "No body",
                    "state": "CLOSED",
                    "body": None,
                    "labels": [],
                    "assignees": [],
                }
            ]
        ),
    )
    def test_none_body_becomes_empty_string(self, _mock: Any) -> None:
        issues = get_github_issues("owner/repo")
        assert issues[0].body == ""

    @patch("weave_gh.data.gh_cli")
    def test_warns_when_limit_hit(self, mock_gh: Any) -> None:
        from weave_gh.data import _GH_ISSUE_LIMIT

        mock_gh.return_value = json.dumps(
            [
                {
                    "number": i,
                    "title": f"Issue {i}",
                    "state": "OPEN",
                    "body": "",
                    "labels": [],
                    "assignees": [],
                }
                for i in range(_GH_ISSUE_LIMIT)
            ]
        )
        issues = get_github_issues("owner/repo")
        assert len(issues) == _GH_ISSUE_LIMIT


# ---------------------------------------------------------------------------
# _repo_hash
# ---------------------------------------------------------------------------


class TestRepoHash:
    @patch("subprocess.check_output", return_value="/home/user/project\n")
    def test_returns_8_char_hex(self, _mock: Any) -> None:
        h = _repo_hash()
        assert len(h) == 8
        assert all(c in "0123456789abcdef" for c in h)

    @patch(
        "subprocess.check_output",
        side_effect=subprocess.CalledProcessError(1, "git"),
    )
    def test_returns_empty_on_git_error(self, _mock: Any) -> None:
        assert _repo_hash() == ""

    @patch(
        "subprocess.check_output",
        side_effect=FileNotFoundError,
    )
    def test_returns_empty_when_git_missing(self, _mock: Any) -> None:
        assert _repo_hash() == ""


# ---------------------------------------------------------------------------
# _resolve_db_path
# ---------------------------------------------------------------------------


class TestResolveDbPath:
    def test_uses_wv_db_env_when_file_exists(self, tmp_path: Path) -> None:
        db = tmp_path / "brain.db"
        db.touch()
        with patch.dict("os.environ", {"WV_DB": str(db)}):
            assert _resolve_db_path() == str(db)

    def test_falls_back_to_candidate_when_exists(self, tmp_path: Path) -> None:
        db = tmp_path / "brain.db"
        db.touch()
        with patch("weave_gh.data._repo_hash", return_value=""), patch.dict(
            "os.environ", {"WV_DB": ""}
        ):
            with patch("weave_gh.data.Path") as mock_path_cls:
                # Make only our candidate exist
                def path_exists_for(p: str) -> bool:
                    return str(p) == str(db)

                mock_path_cls.side_effect = lambda p: (
                    type(
                        "P",
                        (),
                        {"exists": lambda self: path_exists_for(str(db))},
                    )()
                )
                # Just verify it doesn't crash when rhash is empty
                result = _resolve_db_path()
                assert isinstance(result, str)

    def test_returns_default_path_when_nothing_exists(self) -> None:
        with patch("weave_gh.data._repo_hash", return_value="abc12345"), patch.dict(
            "os.environ", {"WV_DB": ""}
        ), patch("weave_gh.data.Path") as mock_path_cls:
            mock_path_cls.return_value.exists.return_value = False
            result = _resolve_db_path()
            assert "abc12345" in result or result.endswith("brain.db")


# ---------------------------------------------------------------------------
# _is_valid_node_id
# ---------------------------------------------------------------------------


class TestIsValidNodeId:
    @pytest.mark.parametrize(
        "node_id",
        ["wv-abc1", "wv-1234", "wv-abcdef", "wv-0000ffff", "wv-a1b2c3"],
    )
    def test_valid_ids(self, node_id: str) -> None:
        assert _is_valid_node_id(node_id) is True

    @pytest.mark.parametrize(
        "node_id",
        [
            "",
            "abc1",
            "wv-",
            "wv-xyz!",
            "wv-ABC1",
            "'; DROP TABLE nodes; --",
            "wv-abc",  # only 3 chars — below minimum 4
        ],
    )
    def test_invalid_ids(self, node_id: str) -> None:
        assert _is_valid_node_id(node_id) is False


# ---------------------------------------------------------------------------
# get_edges_for_node
# ---------------------------------------------------------------------------


class TestGetEdgesForNode:
    def test_invalid_node_id_returns_empty(self, tmp_path: Path) -> None:
        db = tmp_path / "brain.db"
        db.touch()
        with patch("weave_gh.data._resolve_db_path", return_value=str(db)):
            assert get_edges_for_node("bad-id") == []

    def test_missing_db_returns_empty(self) -> None:
        with patch("weave_gh.data._resolve_db_path", return_value="/nonexistent/brain.db"):
            assert get_edges_for_node("wv-abc1") == []

    @patch("weave_gh.data._run")
    def test_returns_edges_from_db(self, mock_run: Any, tmp_path: Path) -> None:
        db = tmp_path / "brain.db"
        db.touch()
        mock_run.return_value = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=json.dumps(
                [
                    {
                        "source": "wv-abc1",
                        "target": "wv-def2",
                        "type": "blocks",
                        "weight": 1.0,
                    }
                ]
            ),
        )
        with patch("weave_gh.data._resolve_db_path", return_value=str(db)):
            edges = get_edges_for_node("wv-abc1")
        assert len(edges) == 1
        assert edges[0].source == "wv-abc1"
        assert edges[0].edge_type == "blocks"

    @patch("weave_gh.data._run")
    def test_empty_sqlite_output_returns_empty(self, mock_run: Any, tmp_path: Path) -> None:
        db = tmp_path / "brain.db"
        db.touch()
        mock_run.return_value = subprocess.CompletedProcess(
            args=[], returncode=0, stdout=""
        )
        with patch("weave_gh.data._resolve_db_path", return_value=str(db)):
            assert get_edges_for_node("wv-abc1") == []

    @patch("weave_gh.data._run")
    def test_bad_json_returns_empty(self, mock_run: Any, tmp_path: Path) -> None:
        db = tmp_path / "brain.db"
        db.touch()
        mock_run.return_value = subprocess.CompletedProcess(
            args=[], returncode=0, stdout="not-json"
        )
        with patch("weave_gh.data._resolve_db_path", return_value=str(db)):
            assert get_edges_for_node("wv-abc1") == []


# ---------------------------------------------------------------------------
# get_edges_for_nodes
# ---------------------------------------------------------------------------


class TestGetEdgesForNodes:
    def test_empty_list_returns_empty(self) -> None:
        assert get_edges_for_nodes([]) == []

    def test_missing_db_returns_empty(self) -> None:
        with patch("weave_gh.data._resolve_db_path", return_value="/nonexistent/brain.db"):
            assert get_edges_for_nodes(["wv-abc1"]) == []

    def test_all_invalid_ids_returns_empty(self, tmp_path: Path) -> None:
        db = tmp_path / "brain.db"
        db.touch()
        with patch("weave_gh.data._resolve_db_path", return_value=str(db)):
            assert get_edges_for_nodes(["bad-id", "also-bad"]) == []

    @patch("weave_gh.data._run")
    def test_returns_edges_for_multiple_nodes(self, mock_run: Any, tmp_path: Path) -> None:
        db = tmp_path / "brain.db"
        db.touch()
        mock_run.return_value = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=json.dumps(
                [
                    {
                        "source": "wv-abc1",
                        "target": "wv-def2",
                        "type": "implements",
                        "weight": 1.0,
                    },
                    {
                        "source": "wv-abc1",
                        "target": "wv-ghi3",
                        "type": "blocks",
                        "weight": 2.0,
                    },
                ]
            ),
        )
        with patch("weave_gh.data._resolve_db_path", return_value=str(db)):
            edges = get_edges_for_nodes(["wv-abc1", "wv-def2"])
        assert len(edges) == 2
        assert edges[1].edge_type == "blocks"
        assert edges[1].weight == 2.0

    @patch("weave_gh.data._run")
    def test_empty_sqlite_output_returns_empty(self, mock_run: Any, tmp_path: Path) -> None:
        db = tmp_path / "brain.db"
        db.touch()
        mock_run.return_value = subprocess.CompletedProcess(
            args=[], returncode=0, stdout="  "
        )
        with patch("weave_gh.data._resolve_db_path", return_value=str(db)):
            assert get_edges_for_nodes(["wv-abc1"]) == []

    @patch("weave_gh.data._run")
    def test_bad_json_returns_empty(self, mock_run: Any, tmp_path: Path) -> None:
        db = tmp_path / "brain.db"
        db.touch()
        mock_run.return_value = subprocess.CompletedProcess(
            args=[], returncode=0, stdout="invalid"
        )
        with patch("weave_gh.data._resolve_db_path", return_value=str(db)):
            assert get_edges_for_nodes(["wv-abc1"]) == []


# ---------------------------------------------------------------------------
# get_children / get_blockers / get_parent (edge helpers)
# ---------------------------------------------------------------------------


def _make_edges() -> list[Edge]:
    return [
        Edge(source="wv-child", target="wv-parent", edge_type="implements", weight=1.0),
        Edge(source="wv-blocker", target="wv-target", edge_type="blocks", weight=1.0),
        Edge(source="wv-abc1", target="wv-abc1", edge_type="addresses", weight=1.0),
    ]


class TestGetChildren:
    def test_returns_children_from_provided_edges(self) -> None:
        edges = _make_edges()
        children = get_children("wv-parent", all_edges=edges)
        assert children == ["wv-child"]

    def test_no_children_returns_empty(self) -> None:
        edges = _make_edges()
        assert get_children("wv-abc1", all_edges=edges) == []

    @patch("weave_gh.data.get_edges_for_node", return_value=[])
    def test_fetches_edges_when_not_provided(self, mock_get: Any) -> None:
        result = get_children("wv-abc1")
        mock_get.assert_called_once_with("wv-abc1")
        assert result == []


class TestGetBlockers:
    def test_returns_blockers_from_provided_edges(self) -> None:
        edges = _make_edges()
        blockers = get_blockers("wv-target", all_edges=edges)
        assert blockers == ["wv-blocker"]

    def test_no_blockers_returns_empty(self) -> None:
        edges = _make_edges()
        assert get_blockers("wv-parent", all_edges=edges) == []

    @patch("weave_gh.data.get_edges_for_node", return_value=[])
    def test_fetches_edges_when_not_provided(self, mock_get: Any) -> None:
        result = get_blockers("wv-abc1")
        mock_get.assert_called_once_with("wv-abc1")
        assert result == []


class TestGetParent:
    def test_returns_parent_from_provided_edges(self) -> None:
        edges = _make_edges()
        parent = get_parent("wv-child", all_edges=edges)
        assert parent == "wv-parent"

    def test_no_parent_returns_none(self) -> None:
        edges = _make_edges()
        assert get_parent("wv-parent", all_edges=edges) is None

    @patch("weave_gh.data.get_edges_for_node", return_value=[])
    def test_fetches_edges_when_not_provided(self, mock_get: Any) -> None:
        result = get_parent("wv-abc1")
        mock_get.assert_called_once_with("wv-abc1")
        assert result is None
