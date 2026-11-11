"""Shared pytest fixtures."""

from __future__ import annotations

import os
from typing import Any

import pytest

# Inside a test suite the user's config.env cannot log wv calls (wv-6b0f57).
# Set here too so pytest run directly, not through a tests/*.sh wrapper, keeps
# the wv subprocesses its tests spawn out of the durable call log.
os.environ.setdefault("WV_TEST_SUITE", "1")


@pytest.fixture(autouse=True)
def _weave_gh_hot_zone_check_off(request: Any, monkeypatch: Any) -> None:
    """Keep weave_gh tests independent of this host's /tmp (wv-80be32).

    Many weave_gh tests resolve the DB path for real and mock only sqlite3, so
    the hot-zone base check would make them pass or fail on whatever
    /tmp/weave-hotzone-<uid> happens to hold. Tests of the check restore the real
    function, imported before this fixture runs, with monkeypatch.
    """
    if not request.node.path.name.startswith("test_weave_gh"):
        return
    import weave_gh.data  # pylint: disable=import-outside-toplevel  # noqa: PLC0415

    def allow_hot_zone(*_a: object) -> None:
        """Isolate unit tests from the live graph's hot-zone check."""

    monkeypatch.setattr(weave_gh.data, "_check_hot_zone", allow_hot_zone)
