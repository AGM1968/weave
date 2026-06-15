"""Tests for ASTCache — blob-SHA keyed analysis result cache."""

# pylint: disable=missing-function-docstring,redefined-outer-name

import subprocess
import time

import pytest

from weave_quality.ast_cache import ASTCache
from weave_quality.models import CKMetrics, FileEntry, FunctionCC


def _make_entry(path: str = "foo.py", scan_id: int = 1) -> FileEntry:
    return FileEntry(
        path=path, scan_id=scan_id, language="python",
        loc=100, complexity=5.0, functions=3, max_nesting=2,
        avg_fn_len=10.0, essential_complexity=1.5, indent_sd=0.3,
        category="production",
    )


def _make_ck(path: str = "foo.py", scan_id: int = 1) -> CKMetrics:
    return CKMetrics(
        path=path, scan_id=scan_id,
        metrics={"wmc": 5.0, "cbo": 2.0, "rfc": 8.0, "lcom": 0.3, "noc": 0.0, "direct_bases": 1.0},
    )


def _make_fn_cc(path: str = "foo.py", scan_id: int = 1) -> list[FunctionCC]:
    return [
        FunctionCC(path=path, scan_id=scan_id, function_name="foo", line_start=1,
                   line_end=10, complexity=3.0, essential_complexity=1.0, is_dispatch=False),
        FunctionCC(path=path, scan_id=scan_id, function_name="bar", line_start=12,
                   line_end=20, complexity=2.0, essential_complexity=1.0, is_dispatch=True),
    ]


@pytest.fixture()
def cache(tmp_path):
    c = ASTCache.open(tmp_path, scanner_version="1.0.0")
    yield c
    c.close()


def test_miss_on_empty_cache(cache):
    assert cache.get("abc123", "foo.py", 1, "production") is None
    assert cache.misses == 1
    assert cache.hits == 0


def test_put_then_get_roundtrip(cache):
    entry = _make_entry()
    ck = _make_ck()
    fn_cc = _make_fn_cc()

    cache.put("sha001", entry, ck, fn_cc)
    result = cache.get("sha001", "foo.py", 1, "production")

    assert result is not None
    got_entry, got_ck, got_fn_cc = result

    assert got_entry.loc == 100
    assert got_entry.complexity == 5.0
    assert got_entry.path == "foo.py"
    assert got_entry.scan_id == 1
    assert got_entry.category == "production"

    assert got_ck is not None
    assert got_ck.metrics["wmc"] == 5.0
    assert got_ck.path == "foo.py"

    assert len(got_fn_cc) == 2
    assert got_fn_cc[0].function_name == "foo"
    assert got_fn_cc[1].is_dispatch is True
    assert cache.hits == 1


def test_path_and_scan_id_injected_at_get(cache):
    entry = _make_entry(path="orig.py", scan_id=1)
    ck = _make_ck(path="orig.py", scan_id=1)
    fn_cc = _make_fn_cc(path="orig.py", scan_id=1)

    cache.put("sha002", entry, ck, fn_cc)
    result = cache.get("sha002", "different/path.py", scan_id=99, category="test")

    assert result is not None
    got_entry, got_ck, got_fn_cc = result
    assert got_entry.path == "different/path.py"
    assert got_entry.scan_id == 99
    assert got_entry.category == "test"
    assert got_ck is not None and got_ck.path == "different/path.py"
    for fc in got_fn_cc:
        assert fc.path == "different/path.py"
        assert fc.scan_id == 99


def test_none_ck_roundtrips(cache):
    entry = _make_entry()
    cache.put("sha003", entry, None, [])
    result = cache.get("sha003", "foo.py", 1, "production")
    assert result is not None
    _, got_ck, got_fn_cc = result
    assert got_ck is None
    assert got_fn_cc == []


def test_scanner_version_isolation(tmp_path):
    c1 = ASTCache.open(tmp_path, scanner_version="1.0.0")
    c2 = ASTCache.open(tmp_path, scanner_version="2.0.0")
    entry = _make_entry()

    c1.put("sha004", entry, None, [])
    c1.flush()

    assert c2.get("sha004", "foo.py", 1, "production") is None
    assert c1.get("sha004", "foo.py", 1, "production") is not None

    c1.close()
    c2.close()


def test_empty_blob_sha_is_noop(cache):
    entry = _make_entry()
    cache.put("", entry, None, [])
    assert cache.get("", "foo.py", 1, "production") is None


def test_insert_or_replace(cache):
    entry_v1 = _make_entry()
    entry_v2 = FileEntry(
        path="foo.py", scan_id=1, language="python",
        loc=200, complexity=10.0, functions=5, max_nesting=3,
        avg_fn_len=20.0, essential_complexity=2.0, indent_sd=0.5,
        category="production",
    )

    cache.put("sha005", entry_v1, None, [])
    cache.put("sha005", entry_v2, None, [])

    result = cache.get("sha005", "foo.py", 1, "production")
    assert result is not None
    assert result[0].loc == 200


def test_cache_persists_across_open(tmp_path):
    c = ASTCache.open(tmp_path, scanner_version="1.0.0")
    entry = _make_entry()
    c.put("sha006", entry, None, [])
    c.close()

    c2 = ASTCache.open(tmp_path, scanner_version="1.0.0")
    result = c2.get("sha006", "foo.py", 1, "production")
    c2.close()
    assert result is not None
    assert result[0].loc == 100


def test_prune_removes_old_entries(tmp_path):
    c = ASTCache.open(tmp_path, scanner_version="1.0.0")
    entry = _make_entry()
    c.put("sha_old", entry, None, [])
    # Backdate the entry via flush + direct SQL (testing internal state intentionally)
    c.flush()
    c._conn.execute(  # pylint: disable=protected-access
        "UPDATE ast_result_cache SET cached_at = ? WHERE blob_sha = ?",
        (int(time.time()) - 100 * 86400, "sha_old"),
    )
    c._conn.commit()  # pylint: disable=protected-access
    deleted = c.prune()
    assert deleted == 1
    assert c.get("sha_old", "foo.py", 1, "production") is None
    c.close()


def test_open_falls_back_to_path_when_not_git(tmp_path):
    # Not a git repo: cache lives at the given path's .weave/ (existing behavior).
    c = ASTCache.open(tmp_path, scanner_version="1.0.0")
    c.close()
    assert (tmp_path / ".weave" / "ast_cache.db").exists()


def test_open_anchors_cache_at_git_toplevel(tmp_path):
    # Regression for wv-a94144: a subdir-scoped scan path must anchor the cache
    # at the git top-level, not drop a nested .weave/ in the subdir.
    subprocess.run(["git", "init", "-q", str(tmp_path)], check=True)
    subdir = tmp_path / "src" / "trigger_launcher"
    subdir.mkdir(parents=True)

    c = ASTCache.open(subdir, scanner_version="1.0.0")
    c.close()

    # Cache anchored at repo root, not the subdir scan path.
    assert (tmp_path / ".weave" / "ast_cache.db").exists()
    assert not (subdir / ".weave").exists()
