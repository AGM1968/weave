"""Tests for weave_gh.cli rate-limit retry."""

import subprocess
from unittest.mock import patch, MagicMock

import pytest

from weave_gh.cli import _run


def _make_result(rc: int, stderr: str = "") -> MagicMock:
    r = MagicMock(spec=subprocess.CompletedProcess)
    r.returncode = rc
    r.stderr = stderr
    r.stdout = ""
    return r


def test_rate_limit_retries() -> None:
    """Should retry on rate limit then succeed."""
    results = [
        _make_result(1, "API rate limit exceeded"),
        _make_result(1, "API rate limit exceeded"),
        _make_result(0),
    ]
    with patch("subprocess.run", side_effect=results):
        with patch("time.sleep"):
            result = _run(["gh", "issue", "list"])
    assert result.returncode == 0


def test_permission_denied_no_retry() -> None:
    """Should NOT retry on 403 permission denied."""
    with patch(
        "subprocess.run",
        return_value=_make_result(1, "HTTP 403: Resource not accessible"),
    ):
        with pytest.raises(subprocess.CalledProcessError):
            _run(["gh", "issue", "list"], check=True)


def test_exhausted_retries_raises() -> None:
    """Should raise after max retries exhausted."""
    result = _make_result(1, "secondary rate limit reached")
    with patch("subprocess.run", return_value=result):
        with patch("time.sleep"):
            with pytest.raises(subprocess.CalledProcessError):
                _run(["gh", "issue", "list"], check=True)


def test_no_retry_on_check_false() -> None:
    """Should return failure result when check=False, not retry non-rate-limit."""
    with patch(
        "subprocess.run",
        return_value=_make_result(1, "not found"),
    ):
        result = _run(["gh", "issue", "view", "999"], check=False)
    assert result.returncode == 1


def test_success_no_retry() -> None:
    """Should return immediately on success, no retry."""
    with patch("subprocess.run", return_value=_make_result(0)) as mock_run:
        result = _run(["gh", "issue", "list"])
    assert result.returncode == 0
    assert mock_run.call_count == 1
