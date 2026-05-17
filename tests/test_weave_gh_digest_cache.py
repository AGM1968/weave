"""Tests for weave_gh.digest_cache — Phase C structural digest cache."""

from __future__ import annotations

import json
from pathlib import Path

from weave_gh.digest_cache import (
    DIGEST_SCHEMA,
    compute_structural_digest,
    is_cache_hit,
    load_cache,
    save_cache,
    update_cache,
)
from weave_gh.models import Edge, WeaveNode


def _node(
    node_id: str,
    text: str = "T",
    status: str = "todo",
    gh_issue: int | None = None,
) -> WeaveNode:
    meta: dict[str, object] = {}
    if gh_issue is not None:
        meta["gh_issue"] = gh_issue
    return WeaveNode(id=node_id, text=text, status=status, metadata=meta)


def _edge(source: str, target: str, edge_type: str = "implements") -> Edge:
    return Edge(source=source, target=target, edge_type=edge_type)


# ---------------------------------------------------------------------------
# compute_structural_digest
# ---------------------------------------------------------------------------


class TestComputeStructuralDigest:
    def test_deterministic(self) -> None:
        node = _node("wv-a", gh_issue=1)
        nodes_by_id = {"wv-a": node}
        d1 = compute_structural_digest(node, nodes_by_id, [])
        d2 = compute_structural_digest(node, nodes_by_id, [])
        assert d1 == d2
        assert len(d1) == 16

    def test_status_change_changes_digest(self) -> None:
        n_todo = _node("wv-a", status="todo")
        n_done = _node("wv-a", status="done")
        d1 = compute_structural_digest(n_todo, {"wv-a": n_todo}, [])
        d2 = compute_structural_digest(n_done, {"wv-a": n_done}, [])
        assert d1 != d2

    def test_child_status_change_changes_digest(self) -> None:
        parent = _node("wv-p")
        c_todo = _node("wv-c", status="todo")
        c_done = _node("wv-c", status="done")
        # child implements parent → edge source=child, target=parent
        edges = [_edge("wv-c", "wv-p")]
        d1 = compute_structural_digest(parent, {"wv-p": parent, "wv-c": c_todo}, edges)
        d2 = compute_structural_digest(parent, {"wv-p": parent, "wv-c": c_done}, edges)
        assert d1 != d2

    def test_sibling_change_does_not_affect_focus(self) -> None:
        """A node's digest depends on its own parent/blockers/children only."""
        a = _node("wv-a")
        b_todo = _node("wv-b", status="todo")
        b_done = _node("wv-b", status="done")
        # a and b share no edges
        d1 = compute_structural_digest(a, {"wv-a": a, "wv-b": b_todo}, [])
        d2 = compute_structural_digest(a, {"wv-a": a, "wv-b": b_done}, [])
        assert d1 == d2


# ---------------------------------------------------------------------------
# load / save / hit / update
# ---------------------------------------------------------------------------


class TestCachePersistence:
    def test_load_missing_returns_empty(self, tmp_path: Path) -> None:
        cache = load_cache(tmp_path / "nope.json")
        assert cache == {"schema": DIGEST_SCHEMA, "entries": {}}

    def test_save_then_load_roundtrip(self, tmp_path: Path) -> None:
        path = tmp_path / "cache.json"
        cache = {"schema": DIGEST_SCHEMA, "entries": {"7": {"node_id": "wv-x", "digest": "abc"}}}
        save_cache(cache, path)
        assert path.exists()
        loaded = load_cache(path)
        assert loaded == cache

    def test_schema_mismatch_invalidates(self, tmp_path: Path) -> None:
        path = tmp_path / "cache.json"
        path.write_text(json.dumps({"schema": DIGEST_SCHEMA + 99, "entries": {"1": "x"}}))
        loaded = load_cache(path)
        assert loaded == {"schema": DIGEST_SCHEMA, "entries": {}}

    def test_corrupt_json_returns_empty(self, tmp_path: Path) -> None:
        path = tmp_path / "cache.json"
        path.write_text("{not json")
        loaded = load_cache(path)
        assert loaded == {"schema": DIGEST_SCHEMA, "entries": {}}

    def test_save_is_atomic_via_tmp(self, tmp_path: Path) -> None:
        path = tmp_path / "cache.json"
        save_cache({"schema": DIGEST_SCHEMA, "entries": {}}, path)
        # Tmp file should not remain after replace
        assert not (tmp_path / "cache.json.tmp").exists()
        assert path.exists()


class TestIsCacheHitAndUpdate:
    def test_miss_on_empty(self) -> None:
        assert is_cache_hit({"schema": 1, "entries": {}}, 5, "wv-a", "d") is False

    def test_hit_after_update(self) -> None:
        cache: dict = {"schema": DIGEST_SCHEMA, "entries": {}}
        update_cache(cache, 5, "wv-a", "deadbeef")
        assert is_cache_hit(cache, 5, "wv-a", "deadbeef") is True

    def test_miss_on_digest_change(self) -> None:
        cache: dict = {"schema": DIGEST_SCHEMA, "entries": {}}
        update_cache(cache, 5, "wv-a", "deadbeef")
        assert is_cache_hit(cache, 5, "wv-a", "feedface") is False

    def test_miss_on_node_id_change(self) -> None:
        cache: dict = {"schema": DIGEST_SCHEMA, "entries": {}}
        update_cache(cache, 5, "wv-a", "deadbeef")
        assert is_cache_hit(cache, 5, "wv-b", "deadbeef") is False
