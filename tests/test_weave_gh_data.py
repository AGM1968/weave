"""Tests for weave_gh.data — data fetching, DB path resolution, edge helpers."""

# pylint: disable=missing-class-docstring,missing-function-docstring

from __future__ import annotations

import json
import os
import re
import subprocess
from pathlib import Path
from typing import Any
from unittest.mock import patch

import pytest

from weave_gh.models import NODE_STATUSES, GitHubIssue, WeaveNode
from weave_gh.data import (
    _is_valid_node_id,
    HotZoneConflictError,
    HotZoneUnsafeError,
    _check_hot_zone,
    _linux_hot_zones,
    _tmp_zone_names,
    _hot_zone_dir_problem,
    _hot_zone_guarded_base,
    _repo_hash,
    _resolve_db_path,
    compute_impacted_node_ids,
    get_blockers,
    get_children,
    get_edges_for_node,
    get_edges_for_nodes,
    IssueFetchError,
    NodeFetchError,
    confirm_mapped_issues_absent,
    get_github_issue_count,
    get_github_issues,
    get_parent,
    get_repo,
    get_repo_url,
    get_weave_nodes,
)
from weave_gh.models import Edge
from weave_gh import data


# ---------------------------------------------------------------------------
# get_repo / get_repo_url
# ---------------------------------------------------------------------------


# Every value a gh_issue metadata field must refuse (wv-e869e3).
_BAD_GH_ISSUES: tuple[object, ...] = (True, False, 0, -1, 1.5, 2.0, "oops", "", "07", "-3", {}, [4])


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
    @patch("weave_gh.data.wv_cli", return_value="[]")
    def test_empty_graph_returns_empty(self, _mock: Any) -> None:
        assert get_weave_nodes() == []

    @patch("weave_gh.data.wv_cli", return_value="[]")
    def test_all_nodes_by_default(self, mock: Any) -> None:
        get_weave_nodes()
        mock.assert_called_once_with("list", "--all", "--json-v2")

    @patch("weave_gh.data.wv_cli", return_value="[]")
    def test_ids_list_only_those_nodes(self, mock: Any) -> None:
        """wv-26fd0b: a caller needing a few nodes asks wv list --ids, not every node."""
        get_weave_nodes(ids=["wv-aaaaaa", "wv-bbbbbb"])
        mock.assert_called_once_with("list", "--ids=wv-aaaaaa,wv-bbbbbb", "--json-v2")

    @patch("weave_gh.data.wv_cli", return_value="[]")
    def test_empty_ids_reads_nothing(self, mock: Any) -> None:
        assert not get_weave_nodes(ids=[])
        mock.assert_not_called()

    @pytest.mark.parametrize(
        "reply",
        ["", "not-json", '{"not": "a list"}', subprocess.CalledProcessError(1, "wv")],
    )
    def test_failed_listing_raises(self, reply: Any) -> None:
        """wv-0d2d25: a failed listing is not an empty graph; returning [] made
        Phase 2 create a Weave node for every open issue."""
        kwargs: dict[str, Any] = {"side_effect": reply} if isinstance(reply, BaseException) else {
            "return_value": reply
        }
        with patch("weave_gh.data.wv_cli", **kwargs), pytest.raises(NodeFetchError):
            get_weave_nodes()

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
    def test_bad_metadata_raises(self, _mock: Any) -> None:
        """wv-1d88c3: unparseable metadata used to read as {}, dropping the
        node's gh_issue so the sync would create a duplicate issue."""
        with pytest.raises(NodeFetchError, match="metadata of wv-abc1 is not JSON"):
            get_weave_nodes()

    @pytest.mark.parametrize(
        ("row", "fault"),
        [
            ({"text": "x", "status": "todo"}, "'id' is NoneType"),
            ({"id": "", "text": "x", "status": "todo"}, "'id' is ''"),
            # wv-e869e3: ids and statuses are contract-checked, not just typed.
            # _backfill_gh_issue interpolates the id into SQL.
            ({"id": "not-a-node", "text": "x", "status": "todo"}, "'id' is 'not-a-node'"),
            ({"id": "wv-abc1'; --", "text": "x", "status": "todo"}, "expected wv-<4-6 hex>"),
            ({"id": "wv-ABC1", "text": "x", "status": "todo"}, "expected wv-<4-6 hex>"),
            ({"id": "wv-abc1", "text": "x", "status": "nonsense"}, "status 'nonsense'"),
            ({"id": "wv-abc1", "status": "todo"}, "'text' is NoneType"),
            ({"id": "wv-abc1", "text": "x"}, "'status' is NoneType"),
            ({"id": "wv-abc1", "text": "x", "status": 3}, "'status' is int"),
            ({"id": "wv-abc1", "text": "x", "status": "todo", "alias": 7}, "'alias' is int"),
            ({"id": "wv-abc1", "text": "x", "status": "todo", "metadata": "[1]"},
             "not a JSON object"),
            ({"id": "wv-abc1", "text": "x", "status": "todo", "metadata": 5}, "is int"),
            # wv-e869e3: gh_issue true was coerced to #1; "oops" and {} raised
            # an untyped error after GitHub writes had begun.
            *[
                ({"id": "wv-abc1", "text": "x", "status": "todo",
                  "metadata": {"gh_issue": bad}}, "wv-abc1: gh_issue is")
                for bad in _BAD_GH_ISSUES
            ],
            ("wv-abc1", "row is str"),
        ],
    )
    def test_malformed_row_raises(self, row: Any, fault: str) -> None:
        """wv-1d88c3: a malformed row raised a raw KeyError, which exits 1 and
        reads as a non-fatal transport failure."""
        with patch("weave_gh.data.wv_cli", return_value=json.dumps([row])), \
                pytest.raises(NodeFetchError, match=f"row 0 is malformed: .*{re.escape(fault)}"):
            get_weave_nodes()

    def test_repeated_node_id_raises(self) -> None:
        row = {"id": "wv-abc1", "text": "x", "status": "todo"}
        with patch("weave_gh.data.wv_cli", return_value=json.dumps([row, row])), \
                pytest.raises(NodeFetchError, match="repeated 1 node id"):
            get_weave_nodes()

    @pytest.mark.parametrize("metadata", [None, "", {}, "{}"])
    def test_empty_metadata_forms_read_as_empty(self, metadata: Any) -> None:
        row = {"id": "wv-abc1", "text": "x", "status": "todo", "metadata": metadata}
        with patch("weave_gh.data.wv_cli", return_value=json.dumps([row])):
            assert get_weave_nodes()[0].metadata == {}

    @pytest.mark.parametrize("status", NODE_STATUSES)
    def test_every_cli_status_is_accepted(self, status: str) -> None:
        row = {"id": "wv-abc1", "text": "x", "status": status}
        with patch("weave_gh.data.wv_cli", return_value=json.dumps([row])):
            assert get_weave_nodes()[0].status == status

    @pytest.mark.parametrize("node_id", ["wv-abcd", "wv-abc12", "wv-a1b2c3"])
    def test_every_cli_id_length_is_accepted(self, node_id: str) -> None:
        row = {"id": node_id, "text": "x", "status": "todo"}
        with patch("weave_gh.data.wv_cli", return_value=json.dumps([row])):
            assert get_weave_nodes()[0].id == node_id

    @pytest.mark.parametrize(("raw", "number"), [(1, 1), (4830, 4830), ("7", 7)])
    def test_gh_issue_is_normalised_to_int(self, raw: Any, number: int) -> None:
        row = {"id": "wv-abc1", "text": "x", "status": "todo", "metadata": {"gh_issue": raw}}
        with patch("weave_gh.data.wv_cli", return_value=json.dumps([row])):
            node = get_weave_nodes()[0]
        assert node.gh_issue == number
        assert node.metadata["gh_issue"] == number

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


def _raw_issue(number: int, **fields: Any) -> dict[str, Any]:
    issue: dict[str, Any] = {
        "number": number, "title": f"Issue {number}", "state": "CLOSED",
        "body": "", "labels": [], "assignees": [],
    }
    issue.update(fields)
    return issue


class _FakeGh:
    """gh stand-in answering the count query and the issue list separately.

    ``count`` may be a list: successive count queries take successive values,
    the last one repeating, so a test can move the count across the listing.
    """

    def __init__(self, count: Any, listing: Any) -> None:
        self.counts = list(count) if isinstance(count, list) else [count]
        self.listing = listing
        self.calls: list[tuple[str, ...]] = []

    def __call__(self, *args: str, **_k: Any) -> str:
        self.calls.append(args)
        if args[:2] == ("api", "graphql"):
            reply = self.counts.pop(0) if len(self.counts) > 1 else self.counts[0]
        else:
            assert args[:2] == ("issue", "list"), args
            reply = self.listing
        if isinstance(reply, BaseException):
            raise reply
        return reply if isinstance(reply, str) else json.dumps(reply)

    def list_limit(self) -> int:
        call = next(c for c in self.calls if c[:2] == ("issue", "list"))
        return int(call[call.index("--limit") + 1])


class TestGetGithubIssues:
    def test_empty_repo_returns_empty(self) -> None:
        with patch("weave_gh.data.gh_cli", _FakeGh("0", "[]")):
            assert get_github_issues("owner/repo") == []

    def test_parses_single_issue(self) -> None:
        raw = _raw_issue(
            42, title="Fix the bug", state="OPEN", body="Some description",
            labels=[{"name": "bug"}], assignees=[{"login": "alice"}],
        )
        with patch("weave_gh.data.gh_cli", _FakeGh("1", [raw])):
            issues = get_github_issues("owner/repo")
        assert len(issues) == 1
        assert issues[0].number == 42
        assert issues[0].title == "Fix the bug"
        assert issues[0].state == "OPEN"
        assert issues[0].labels == ["bug"]
        assert issues[0].assignees == ["alice"]

    def test_none_body_becomes_empty_string(self) -> None:
        with patch("weave_gh.data.gh_cli", _FakeGh("1", [_raw_issue(1, body=None)])):
            issues = get_github_issues("owner/repo")
        assert issues[0].body == ""

    def test_fetches_past_the_old_fixed_limit(self) -> None:
        """wv-0d2d25: the limit follows the live count, so the oldest issue of
        5200 is returned rather than dropped at 5000."""
        fake = _FakeGh("5200", [_raw_issue(n) for n in range(5200, 0, -1)])
        with patch("weave_gh.data.gh_cli", fake):
            issues = get_github_issues("owner/repo")
        assert len(issues) == 5200
        assert issues[-1].number == 1
        assert fake.list_limit() > 5200

    def test_issues_created_after_the_count_are_accepted(self) -> None:
        fake = _FakeGh("2", [_raw_issue(3), _raw_issue(2), _raw_issue(1)])
        with patch("weave_gh.data.gh_cli", fake):
            assert len(get_github_issues("owner/repo")) == 3

    def test_fewer_issues_than_the_count_raises(self) -> None:
        fake = _FakeGh("3", [_raw_issue(3), _raw_issue(2)])
        with patch("weave_gh.data.gh_cli", fake), \
                pytest.raises(IssueFetchError, match="fetched 2 distinct.*counted 3"):
            get_github_issues("owner/repo")

    def test_empty_list_against_nonzero_count_raises(self) -> None:
        """The old code returned [] on empty output, which sends every node to
        issue creation."""
        with patch("weave_gh.data.gh_cli", _FakeGh("4781", "")), \
                pytest.raises(IssueFetchError, match="fetched 0 distinct.*counted 4781"):
            get_github_issues("owner/repo")

    def test_count_rising_during_the_listing_raises(self) -> None:
        """wv-1d88c3: count 2, #3 created, then [#3, #2] matches the stale
        count with #1 missing. The count read after listing (3) catches it."""
        fake = _FakeGh(["2", "3"], [_raw_issue(3), _raw_issue(2)])
        with patch("weave_gh.data.gh_cli", fake), \
                pytest.raises(IssueFetchError, match="counted 2 before listing and 3 after"):
            get_github_issues("owner/repo")
        assert [c[:2] for c in fake.calls] == [
            ("api", "graphql"), ("issue", "list"), ("api", "graphql")
        ]

    def test_count_falling_during_the_listing_still_needs_the_first_count(self) -> None:
        fake = _FakeGh(["3", "2"], [_raw_issue(3), _raw_issue(2)])
        with patch("weave_gh.data.gh_cli", fake), \
                pytest.raises(IssueFetchError, match="counted 3 before listing and 2 after"):
            get_github_issues("owner/repo")

    def test_listing_covering_both_counts_is_accepted(self) -> None:
        fake = _FakeGh(["2", "3"], [_raw_issue(3), _raw_issue(2), _raw_issue(1)])
        with patch("weave_gh.data.gh_cli", fake):
            assert [i.number for i in get_github_issues("owner/repo")] == [3, 2, 1]

    def test_recount_transport_failure_is_transport(self) -> None:
        fake = _FakeGh(["1", subprocess.CalledProcessError(1, "gh")], [_raw_issue(1)])
        with patch("weave_gh.data.gh_cli", fake), pytest.raises(IssueFetchError) as exc:
            get_github_issues("owner/repo")
        assert exc.value.transport is True

    def test_list_filling_the_limit_raises(self) -> None:
        fake = _FakeGh("2", [_raw_issue(n) for n in range(3, 0, -1)])
        with patch("weave_gh.data.gh_cli", fake), \
                patch("weave_gh.data._GH_ISSUE_HEADROOM", 1), \
                pytest.raises(IssueFetchError, match="filling the limit"):
            get_github_issues("owner/repo")

    def test_repeated_issue_number_raises(self) -> None:
        """wv-820b76: [#2, #2] against a count of 2 has the right length but
        hides a missing #1."""
        fake = _FakeGh("2", [_raw_issue(2), _raw_issue(2)])
        with patch("weave_gh.data.gh_cli", fake), \
                pytest.raises(IssueFetchError, match="repeated 1 issue number") as exc:
            get_github_issues("owner/repo")
        assert exc.value.transport is False

    def test_repeat_plus_extra_still_short_of_distinct_count_raises(self) -> None:
        """A repeat padded by an issue created after the count is still caught."""
        fake = _FakeGh("3", [_raw_issue(4), _raw_issue(2), _raw_issue(2)])
        with patch("weave_gh.data.gh_cli", fake), pytest.raises(IssueFetchError):
            get_github_issues("owner/repo")

    @pytest.mark.parametrize(
        ("entry", "fault"),
        [
            ({"title": "no number"}, "'number' is NoneType"),
            ({**_raw_issue(1), "number": "1"}, "'number' is str"),
            ({**_raw_issue(1), "number": True}, "'number' is bool"),
            # wv-e869e3: issue numbers start at 1.
            ({**_raw_issue(1), "number": 0}, "'number' is 0"),
            ({**_raw_issue(1), "number": -1}, "'number' is -1"),
            ("not-a-dict", "row is str"),
            ({"number": 1}, "'state' is NoneType"),
            ({**_raw_issue(1), "title": None}, "'title' is NoneType"),
            ({**_raw_issue(1), "state": "MERGED"}, "state 'MERGED'"),
            ({**_raw_issue(1), "body": 5}, "'body' is int"),
            ({**_raw_issue(1), "labels": None}, "'labels' is NoneType"),
            ({**_raw_issue(1), "labels": ["bug"]}, "labels entry without a string 'name'"),
            ({**_raw_issue(1), "assignees": [{"name": "x"}]},
             "assignees entry without a string 'login'"),
        ],
    )
    def test_malformed_row_raises_integrity_error(self, entry: Any, fault: str) -> None:
        """wv-1d88c3: a malformed row raised a raw KeyError, which exits 1 and
        reads as a non-fatal transport failure."""
        with patch("weave_gh.data.gh_cli", _FakeGh("1", [entry])), \
                pytest.raises(
                    IssueFetchError, match=f"row 0 is malformed: .*{re.escape(fault)}"
                ) as exc:
            get_github_issues("owner/repo")
        assert exc.value.transport is False

    @pytest.mark.parametrize(
        ("listing", "transport"),
        [
            ("bad-json", False),
            ('{"not": "a list"}', False),
            (subprocess.CalledProcessError(1, "gh"), True),
        ],
    )
    def test_list_failure_raises(self, listing: Any, transport: bool) -> None:
        with patch("weave_gh.data.gh_cli", _FakeGh("1", listing)), \
                pytest.raises(IssueFetchError) as exc:
            get_github_issues("owner/repo")
        assert exc.value.transport is transport

    @pytest.mark.parametrize(
        ("count", "transport"),
        [
            ("", False),
            ("null", False),
            # wv-e869e3: -1/-1 with [] passed the completeness check and
            # returned an empty list, the duplicate-creation hazard of wv-0d2d25.
            ("-1", False),
            (subprocess.CalledProcessError(1, "gh"), True),
        ],
    )
    def test_count_failure_raises_before_listing(self, count: Any, transport: bool) -> None:
        fake = _FakeGh(count, [_raw_issue(1)])
        with patch("weave_gh.data.gh_cli", fake), pytest.raises(IssueFetchError) as exc:
            get_github_issues("owner/repo")
        assert exc.value.transport is transport
        assert all(c[:2] != ("issue", "list") for c in fake.calls)

    def test_short_list_is_an_integrity_failure(self) -> None:
        fake = _FakeGh("3", [_raw_issue(3), _raw_issue(2)])
        with patch("weave_gh.data.gh_cli", fake), pytest.raises(IssueFetchError) as exc:
            get_github_issues("owner/repo")
        assert exc.value.transport is False


class TestGetGithubIssueCount:
    def test_negative_count_raises(self) -> None:
        with patch("weave_gh.data.gh_cli", _FakeGh("-1", "[]")), \
                pytest.raises(IssueFetchError, match="negative: -1") as exc:
            get_github_issue_count("owner/repo")
        assert exc.value.transport is False

    def test_zero_count_is_an_empty_repository(self) -> None:
        with patch("weave_gh.data.gh_cli", _FakeGh("0", "[]")):
            assert get_github_issue_count("owner/repo") == 0

    def test_queries_owner_and_name(self) -> None:
        fake = _FakeGh("4781", "[]")
        with patch("weave_gh.data.gh_cli", fake):
            assert get_github_issue_count("AGM1968/memory-system") == 4781
        args = fake.calls[0]
        assert "owner=AGM1968" in args
        assert "name=memory-system" in args
        assert ".data.repository.issues.totalCount" in args


def _view(returncode: int, stdout: str = "", stderr: str = "") -> Any:
    return subprocess.CompletedProcess(["gh"], returncode, stdout, stderr)


_NOT_FOUND_ERR = (
    "GraphQL: Could not resolve to an issue or pull request with the number of 9. "
    "(repository.issue)"
)


class TestConfirmMappedIssuesAbsent:
    """wv-e869e3: counts prove cardinality, not membership. An issue leaving
    the repository while another arrives keeps the count, so a mapped issue
    the list omitted must be looked up before Phase 1 replaces it."""

    REPO = "Owner/Repo"
    NODES = [
        WeaveNode("wv-aaa1", "listed", "todo", {"gh_issue": 1}),
        WeaveNode("wv-aaa2", "omitted", "todo", {"gh_issue": 9}),
        WeaveNode("wv-aaa3", "unmapped", "todo"),
    ]
    ISSUES = [GitHubIssue(1, "listed", "OPEN"), GitHubIssue(2, "other", "OPEN")]

    def _confirm(self, result: Any) -> list[list[str]]:
        calls: list[list[str]] = []

        def fake_run(cmd: list[str], *, check: bool = True) -> Any:
            calls.append(cmd)
            # Faithful to the real _run: a failure under check=True raises.
            if check and result.returncode != 0:
                raise subprocess.CalledProcessError(result.returncode, cmd, result.stdout, result.stderr)
            return result

        with patch("weave_gh.data._run", fake_run):
            confirm_mapped_issues_absent(self.REPO, self.NODES, self.ISSUES)
        return calls

    def test_omitted_issue_that_exists_raises(self) -> None:
        url = '{"url": "https://github.com/owner/repo/issues/9"}'
        with pytest.raises(IssueFetchError, match=r"#9 \(mapped by wv-aaa2\) exists") as exc:
            self._confirm(_view(0, url))
        assert exc.value.transport is False

    def test_only_mapped_numbers_missing_from_the_list_are_looked_up(self) -> None:
        calls = self._confirm(_view(1, stderr=_NOT_FOUND_ERR))
        assert calls == [
            ["gh", "issue", "view", "9", "--repo", self.REPO, "--json", "url"]
        ]

    @pytest.mark.parametrize(
        "url",
        [
            "https://github.com/owner/repo/pull/9",
            "https://github.com/owner/elsewhere/issues/9",
        ],
    )
    def test_pull_request_or_transferred_issue_is_absent(self, url: str) -> None:
        self._confirm(_view(0, json.dumps({"url": url})))

    def test_lookup_failure_is_transport(self) -> None:
        with pytest.raises(IssueFetchError, match="could not look up") as exc:
            self._confirm(_view(1, stderr="error connecting to api.github.com"))
        assert exc.value.transport is True

    @pytest.mark.parametrize("stdout", ["", "{}", "[]", "nope"])
    def test_lookup_without_a_url_is_an_integrity_failure(self, stdout: str) -> None:
        with pytest.raises(IssueFetchError, match="returned no url") as exc:
            self._confirm(_view(0, stdout))
        assert exc.value.transport is False

    def test_nothing_missing_makes_no_call(self) -> None:
        calls: list[Any] = []
        def record_call(*a: object, **_k: object) -> None:
            """Record an unexpected command without executing it."""
            calls.append(a)

        with patch("weave_gh.data._run", record_call):
            confirm_mapped_issues_absent(
                self.REPO, self.NODES[:1], self.ISSUES
            )
        assert calls == []


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

    def test_wv_db_is_used_even_before_it_exists(self, tmp_path: Path) -> None:
        # As bash's resolve_db: WV_DB names the database, existing or not.
        db = str(tmp_path / "later.db")
        with patch.dict("os.environ", {"WV_DB": db}):
            assert _resolve_db_path() == db

    def test_wv_hot_zone_names_the_database(self, tmp_path: Path) -> None:
        with patch.dict("os.environ", {"WV_DB": "", "WV_HOT_ZONE": str(tmp_path)}):
            assert _resolve_db_path() == str(tmp_path / "brain.db")


class _ZoneFixture:  # pylint: disable=too-few-public-methods
    """Zone layout, resolver and population helpers shared by the placement
    and naming tests; a base class rather than borrowed functions, which
    bound the wrong self type (wv-4dcf9c)."""

    HASH = "abc12345"
    UID = 1000

    def _zones(self, root: Path) -> dict[str, Path]:
        return {
            # The /tmp zone: "neutral" is the name a process is given when no
            # zone exists yet, "tmp" the legacy directory that stays physical
            # (wv-95bddf).
            "neutral": root / "tmp" / f"weave-hotzone-{self.UID}",
            "tmp": root / "tmp" / f"weave-codex-{self.UID}",
            "shm": root / "dev" / "shm" / "weave",
            "legacy": root / "tmp" / f"weave-{self.UID}",
        }

    def _resolve(self, root: Path, **env: str) -> str:
        base_env = {"WV_DB": "", "WV_HOT_ZONE": "", "WV_TEST_MODE": "1",
                    "WV_TEST_HOT_ZONE_ROOT": str(root)}
        with patch.dict("os.environ", {**base_env, **env}), patch(
            "weave_gh.data._repo_hash", return_value=self.HASH
        ), patch("weave_gh.data.os.getuid", return_value=self.UID), patch(
            "weave_gh.data.sys.platform", "linux"
        ):
            return _resolve_db_path()

    def _populate(self, zone: Path, content: str = "x") -> None:
        (zone / self.HASH).mkdir(parents=True, exist_ok=True)
        (zone / self.HASH / "brain.db").write_text(content)


class TestPlacementRule(_ZoneFixture):
    """wv-b831e3 (owner ruling 2026-10-06): the zone already holding this
    repository's database wins; with none, the /tmp zone for every process;
    with more than one, refuse. tests/test-hot-zone-placement.sh drives bash
    and python together."""

    @pytest.mark.parametrize(
        "markers",
        [{}, {"CODEX_CI": "1"}, {"CLAUDE_CODE_SSE_PORT": "1"}, {"CLAUDECODE": "1"}, {"CI": "1"}],
    )
    def test_no_database_uses_the_tmp_zone_for_every_process(
        self, tmp_path: Path, markers: dict[str, str]
    ) -> None:
        zones = self._zones(tmp_path)
        assert self._resolve(tmp_path, **markers) == f"{zones['neutral']}/{self.HASH}/brain.db"

    @pytest.mark.parametrize("holder", ["tmp", "shm", "legacy"])
    @pytest.mark.parametrize("markers", [{}, {"CODEX_CI": "1"}])
    def test_the_zone_holding_the_database_wins(
        self, tmp_path: Path, holder: str, markers: dict[str, str]
    ) -> None:
        zones = self._zones(tmp_path)
        self._populate(zones[holder])
        # The /tmp zone existing without this repo's DB does not pull it away.
        zones["tmp"].mkdir(parents=True, exist_ok=True)
        assert self._resolve(tmp_path, **markers) == f"{zones[holder]}/{self.HASH}/brain.db"

    def test_an_empty_database_holds_nothing(self, tmp_path: Path) -> None:
        zones = self._zones(tmp_path)
        self._populate(zones["shm"], content="")
        assert self._resolve(tmp_path) == f"{zones['neutral']}/{self.HASH}/brain.db"

    def test_more_than_one_holder_refuses(self, tmp_path: Path) -> None:
        zones = self._zones(tmp_path)
        self._populate(zones["tmp"])
        self._populate(zones["shm"])
        with pytest.raises(HotZoneConflictError, match="more than one hot zone") as exc:
            self._resolve(tmp_path)
        assert str(zones["tmp"]) in str(exc.value) and str(zones["shm"]) in str(exc.value)
        # wv-a73141: the copies may have diverged, and syncing both does not
        # merge them, so the advice is backup, diff and reconcile, never
        # "sync one, then remove the other".
        msg = str(exc.value)
        assert "Remove nothing yet" in msg
        assert "\".backup '<file>'\" (never cp)" in msg
        assert "wv hotzone diff <copy you keep> <other copy>" in msg
        assert "keep one with" not in msg

    def test_an_explicit_hot_zone_settles_a_conflict(self, tmp_path: Path) -> None:
        zones = self._zones(tmp_path)
        self._populate(zones["tmp"])
        self._populate(zones["shm"])
        chosen = str(zones["shm"] / self.HASH)
        assert self._resolve(tmp_path, WV_HOT_ZONE=chosen) == f"{chosen}/brain.db"

    def test_the_test_root_needs_test_mode(self, tmp_path: Path) -> None:
        with patch.dict("os.environ", {"WV_TEST_HOT_ZONE_ROOT": str(tmp_path), "WV_TEST_MODE": ""}):
            assert _tmp_zone_names(self.UID) == (
                f"/tmp/weave-hotzone-{self.UID}", f"/tmp/weave-codex-{self.UID}"
            )


class TestTmpZoneNames(_ZoneFixture):
    """wv-95bddf (owner decision 2026-10-05): the /tmp zone is named
    /tmp/weave-hotzone-<uid>; while hosts run mixed versions the legacy
    /tmp/weave-codex-<uid> stays physical and the neutral name is at most a
    symlink to it. tests/test-hot-zone-placement.sh drives bash the same way."""

    def _dir(self, path: Path) -> Path:
        path.mkdir(parents=True, exist_ok=True)
        path.chmod(0o700)
        return path

    def _alias(self, zones: dict[str, Path], target: Path | None = None) -> None:
        self._dir(zones["neutral"].parent)
        zones["neutral"].symlink_to(target or zones["tmp"])

    def test_legacy_only_is_used_by_its_legacy_name(self, tmp_path: Path) -> None:
        zones = self._zones(tmp_path)
        self._populate(self._dir(zones["tmp"]))
        assert self._resolve(tmp_path) == f"{zones['tmp']}/{self.HASH}/brain.db"

    def test_the_alias_is_used_and_counted_once(self, tmp_path: Path) -> None:
        zones = self._zones(tmp_path)
        self._populate(self._dir(zones["tmp"]))
        self._alias(zones)
        assert self._resolve(tmp_path) == f"{zones['neutral']}/{self.HASH}/brain.db"
        env = {"WV_TEST_MODE": "1", "WV_TEST_HOT_ZONE_ROOT": str(tmp_path)}
        with patch.dict("os.environ", env):
            assert _linux_hot_zones(self.UID) == (
                [str(zones["neutral"]), str(zones["shm"]), str(zones["legacy"])], False
            )

    def test_a_relocated_neutral_zone_is_used_directly(self, tmp_path: Path) -> None:
        zones = self._zones(tmp_path)
        self._populate(self._dir(zones["neutral"]))
        assert self._resolve(tmp_path) == f"{zones['neutral']}/{self.HASH}/brain.db"

    def test_both_names_populated_refuses(self, tmp_path: Path) -> None:
        zones = self._zones(tmp_path)
        self._populate(self._dir(zones["neutral"]))
        # A different repository in the legacy directory: still two zones.
        (self._dir(zones["tmp"]) / "ffff0000").mkdir()
        (zones["tmp"] / "ffff0000" / "brain.db").write_text("x")
        with pytest.raises(HotZoneConflictError, match="separate directories") as exc:
            self._resolve(tmp_path)
        assert str(zones["neutral"]) in str(exc.value) and str(zones["tmp"]) in str(exc.value)
        # Every database is listed, and nothing is to be removed before each is synced.
        assert f"{zones['neutral']}/{self.HASH}" in str(exc.value)
        assert f"{zones['tmp']}/ffff0000" in str(exc.value)
        assert "Remove nothing yet" in str(exc.value)
        # wv-a73141: backup and diff before any removal, never sync-then-remove.
        assert "\".backup '<file>'\" (never cp)" in str(exc.value)
        assert "wv hotzone diff <legacy copy> <neutral copy>" in str(exc.value)
        assert "only then remove" in str(exc.value)
        assert "IN BOTH ZONES" not in str(exc.value)

    def test_a_repository_in_both_names_is_marked_for_reconciling(self, tmp_path: Path) -> None:
        # wv-a73141: the same repository in both zones has two copies that
        # may have diverged; the inventory marks it so step 3 is not skipped.
        zones = self._zones(tmp_path)
        self._populate(self._dir(zones["neutral"]))
        self._populate(self._dir(zones["tmp"]))
        with pytest.raises(HotZoneConflictError, match="separate directories") as exc:
            self._resolve(tmp_path)
        msg = str(exc.value)
        assert f"{zones['neutral']}/{self.HASH} (repository unknown) [IN BOTH ZONES" in msg
        assert f"{zones['tmp']}/{self.HASH} (repository unknown) [IN BOTH ZONES" in msg

    @pytest.mark.parametrize("other_in_legacy", [True, False])
    def test_a_new_repository_beside_an_empty_neutral_dir_uses_the_legacy_dir(
        self, tmp_path: Path, other_in_legacy: bool
    ) -> None:
        # wv-6f2eed: landing in the empty neutral directory would create the
        # two-populated-zones conflict the next call refuses.
        zones = self._zones(tmp_path)
        self._dir(zones["neutral"])
        self._dir(zones["tmp"])
        if other_in_legacy:
            (zones["tmp"] / "ffff0000").mkdir()
            (zones["tmp"] / "ffff0000" / "brain.db").write_text("x")
        assert self._resolve(tmp_path) == f"{zones['tmp']}/{self.HASH}/brain.db"

    def test_a_relocated_neutral_dir_beside_an_empty_legacy_dir_comes_first(
        self, tmp_path: Path
    ) -> None:
        zones = self._zones(tmp_path)
        self._dir(zones["tmp"])
        (self._dir(zones["neutral"]) / "ffff0000").mkdir()
        (zones["neutral"] / "ffff0000" / "brain.db").write_text("x")
        assert self._resolve(tmp_path) == f"{zones['neutral']}/{self.HASH}/brain.db"

    def test_both_names_one_populated_uses_the_holder(self, tmp_path: Path) -> None:
        zones = self._zones(tmp_path)
        self._dir(zones["neutral"])
        self._populate(self._dir(zones["tmp"]))
        assert self._resolve(tmp_path) == f"{zones['tmp']}/{self.HASH}/brain.db"

    def test_an_alias_to_another_target_is_refused(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:

        # conftest stubs the check for weave_gh tests; this one needs it.
        monkeypatch.setattr(data, "_check_hot_zone", _check_hot_zone)
        zones = self._zones(tmp_path)
        elsewhere = self._dir(tmp_path / "elsewhere")
        self._populate(elsewhere)
        self._alias(zones, elsewhere)
        with pytest.raises(HotZoneUnsafeError, match=f"is a symlink to {elsewhere}, not"):
            self._resolve(tmp_path)

    def test_an_alias_whose_legacy_directory_was_removed_is_usable(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:

        monkeypatch.setattr(data, "_check_hot_zone", _check_hot_zone)
        zones = self._zones(tmp_path)
        self._alias(zones)
        assert self._resolve(tmp_path) == f"{zones['neutral']}/{self.HASH}/brain.db"

    def test_a_legacy_symlink_beside_a_real_neutral_zone_is_not_a_second_zone(
        self, tmp_path: Path
    ) -> None:
        zones = self._zones(tmp_path)
        self._populate(self._dir(zones["neutral"]))
        zones["tmp"].symlink_to(zones["neutral"])
        assert self._resolve(tmp_path) == f"{zones['neutral']}/{self.HASH}/brain.db"


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


# ---------------------------------------------------------------------------
# compute_impacted_node_ids (Phase B fast-path helper)
# ---------------------------------------------------------------------------


class TestComputeImpactedNodeIds:
    def test_focus_alone_with_no_edges(self) -> None:
        assert compute_impacted_node_ids("wv-solo", all_edges=[]) == {"wv-solo"}

    def test_includes_parent(self) -> None:
        edges = [
            Edge(source="wv-focus", target="wv-parent",
                 edge_type="implements", weight=1.0),
        ]
        assert compute_impacted_node_ids("wv-focus", all_edges=edges) == {
            "wv-focus",
            "wv-parent",
        }

    def test_includes_children(self) -> None:
        edges = [
            Edge(source="wv-c1", target="wv-focus",
                 edge_type="implements", weight=1.0),
            Edge(source="wv-c2", target="wv-focus",
                 edge_type="implements", weight=1.0),
        ]
        assert compute_impacted_node_ids("wv-focus", all_edges=edges) == {
            "wv-focus",
            "wv-c1",
            "wv-c2",
        }

    def test_includes_blockers_both_directions(self) -> None:
        edges = [
            Edge(source="wv-bk", target="wv-focus",
                 edge_type="blocks", weight=1.0),
            Edge(source="wv-focus", target="wv-blocked",
                 edge_type="blocks", weight=1.0),
        ]
        assert compute_impacted_node_ids("wv-focus", all_edges=edges) == {
            "wv-focus",
            "wv-bk",
            "wv-blocked",
        }

    def test_excludes_siblings(self) -> None:
        # focus + sibling share a parent but sibling is not in impacted set
        edges = [
            Edge(source="wv-focus", target="wv-parent",
                 edge_type="implements", weight=1.0),
            Edge(source="wv-sibling", target="wv-parent",
                 edge_type="implements", weight=1.0),
        ]
        impacted = compute_impacted_node_ids("wv-focus", all_edges=edges)
        assert impacted == {"wv-focus", "wv-parent"}
        assert "wv-sibling" not in impacted


# ---------------------------------------------------------------------------
# Hot-zone base safety (wv-80be32); tests/test-hot-zone-base.sh drives bash
# and python together. tests/conftest.py turns the check off for weave_gh
# tests; these restore the real _check_hot_zone imported above.
# ---------------------------------------------------------------------------


class TestHotZoneBase:
    UID = os.getuid()

    def test_private_directory_is_usable(self, tmp_path: Path) -> None:
        (tmp_path / "b").mkdir(mode=0o700)
        assert _hot_zone_dir_problem(str(tmp_path / "b"), self.UID) is None

    def test_absent_base_is_not_a_problem(self, tmp_path: Path) -> None:
        assert _hot_zone_dir_problem(str(tmp_path / "absent"), self.UID) is None

    @pytest.mark.parametrize("mode", [0o777, 0o775, 0o757, 0o1777])
    def test_group_or_other_write_is_refused(self, tmp_path: Path, mode: int) -> None:
        base = tmp_path / "b"
        base.mkdir()
        base.chmod(mode)
        assert _hot_zone_dir_problem(str(base), self.UID) == (
            f"is writable by group or others (mode {mode:o})"
        )

    def test_other_owner_is_refused(self, tmp_path: Path) -> None:
        (tmp_path / "b").mkdir(mode=0o700)
        assert _hot_zone_dir_problem(str(tmp_path / "b"), self.UID + 1) == (
            f"is owned by uid {self.UID}, not {self.UID + 1}"
        )

    def test_symlink_is_refused_without_an_alias(self, tmp_path: Path) -> None:
        (tmp_path / "real").mkdir(mode=0o700)
        (tmp_path / "link").symlink_to(tmp_path / "real")
        assert _hot_zone_dir_problem(str(tmp_path / "link"), self.UID) == "is a symlink"

    def test_alias_must_name_the_exact_target(self, tmp_path: Path) -> None:
        real, other = tmp_path / "real", tmp_path / "other"
        real.mkdir(mode=0o700)
        other.mkdir(mode=0o700)
        (tmp_path / "link").symlink_to(real)
        link = str(tmp_path / "link")
        assert _hot_zone_dir_problem(link, self.UID, str(real)) is None
        assert _hot_zone_dir_problem(link, self.UID, str(other)) == (
            f"is a symlink to {real}, not {other}"
        )
        assert _hot_zone_dir_problem(link, self.UID + 1, str(real)) == (
            f"is a symlink owned by uid {self.UID}, not {self.UID + 1}"
        )

    def test_file_is_refused(self, tmp_path: Path) -> None:
        (tmp_path / "f").write_text("")
        assert _hot_zone_dir_problem(str(tmp_path / "f"), self.UID) == "is not a directory"

    def test_only_known_bases_and_their_children_are_guarded(self) -> None:
        base = f"/tmp/weave-codex-{self.UID}"
        assert _hot_zone_guarded_base(f"{base}/abcd1234", self.UID) == base
        assert _hot_zone_guarded_base(base, self.UID) == base
        assert _hot_zone_guarded_base("/tmp/weave/abcd1234", self.UID) == "/tmp/weave"
        assert _hot_zone_guarded_base(f"{base}/a/b", self.UID) == base
        assert _hot_zone_guarded_base(f"{base}x/a", self.UID) is None
        assert _hot_zone_guarded_base("/home/x/hz", self.UID) is None

    def test_test_base_needs_test_mode(self, tmp_path: Path, monkeypatch: Any) -> None:
        monkeypatch.setenv("WV_TEST_HOT_ZONE_BASE", str(tmp_path))
        monkeypatch.delenv("WV_TEST_MODE", raising=False)
        assert _hot_zone_guarded_base(str(tmp_path / "hz"), self.UID) is None
        monkeypatch.setenv("WV_TEST_MODE", "1")
        assert _hot_zone_guarded_base(str(tmp_path / "hz"), self.UID) == str(tmp_path)
        monkeypatch.setenv("WV_TEST_HOT_ZONE_BASE", "relative")
        assert _hot_zone_guarded_base("relative/hz", self.UID) is None

    def test_resolve_db_path_refuses_an_unsafe_base(
        self, tmp_path: Path, monkeypatch: Any
    ) -> None:

        monkeypatch.setattr(data, "_check_hot_zone", _check_hot_zone)
        base = tmp_path / "base"
        (base / "leaf").mkdir(parents=True)
        (base / "leaf" / "brain.db").write_text("")
        monkeypatch.setenv("WV_TEST_MODE", "1")
        monkeypatch.setenv("WV_TEST_HOT_ZONE_BASE", str(base))
        monkeypatch.setenv("WV_HOT_ZONE", str(base / "leaf"))
        monkeypatch.delenv("WV_DB", raising=False)
        base.chmod(0o700)
        assert _resolve_db_path() == str(base / "leaf" / "brain.db")
        base.chmod(0o777)
        with pytest.raises(HotZoneUnsafeError, match="writable by group or others"):
            _resolve_db_path()
