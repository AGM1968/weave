"""Tests for the Phase D repair-mode resume checkpoint."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from weave_gh import repair_checkpoint as rc


@pytest.fixture()
def cp_path(tmp_path: Path) -> Path:
    return tmp_path / "repair-checkpoint.json"


def test_new_checkpoint_has_schema_and_empty_processed() -> None:
    cp = rc.new_checkpoint()
    assert cp["schema"] == rc.CHECKPOINT_SCHEMA
    assert cp["processed"] == []
    assert "started_at" in cp


def test_load_returns_empty_when_missing(cp_path: Path) -> None:
    assert not cp_path.exists()
    cp = rc.load_checkpoint(cp_path)
    assert cp["processed"] == []
    assert cp["schema"] == rc.CHECKPOINT_SCHEMA


def test_save_and_load_roundtrip(cp_path: Path) -> None:
    cp = rc.new_checkpoint()
    rc.mark_processed(cp, "wv-aaaaaa")
    rc.mark_processed(cp, "wv-bbbbbb")
    rc.save_checkpoint(cp, cp_path)

    loaded = rc.load_checkpoint(cp_path)
    assert loaded["processed"] == ["wv-aaaaaa", "wv-bbbbbb"]


def test_mark_processed_is_idempotent() -> None:
    cp = rc.new_checkpoint()
    rc.mark_processed(cp, "wv-aaaaaa")
    rc.mark_processed(cp, "wv-aaaaaa")
    assert cp["processed"] == ["wv-aaaaaa"]


def test_processed_ids_returns_set() -> None:
    cp = rc.new_checkpoint()
    rc.mark_processed(cp, "wv-aaaaaa")
    rc.mark_processed(cp, "wv-bbbbbb")
    assert rc.processed_ids(cp) == {"wv-aaaaaa", "wv-bbbbbb"}


def test_load_rejects_schema_mismatch(cp_path: Path) -> None:
    cp_path.write_text(json.dumps({"schema": 999, "processed": ["wv-x"]}))
    loaded = rc.load_checkpoint(cp_path)
    assert loaded["processed"] == []
    assert loaded["schema"] == rc.CHECKPOINT_SCHEMA


def test_load_rejects_corrupt_json(cp_path: Path) -> None:
    cp_path.write_text("{not json")
    loaded = rc.load_checkpoint(cp_path)
    assert loaded["processed"] == []


def test_clear_checkpoint_removes_file(cp_path: Path) -> None:
    cp_path.write_text(json.dumps(rc.new_checkpoint()))
    assert cp_path.exists()
    rc.clear_checkpoint(cp_path)
    assert not cp_path.exists()


def test_clear_missing_checkpoint_is_safe(cp_path: Path) -> None:
    # Must not raise even when nothing to delete.
    rc.clear_checkpoint(cp_path)


def test_recommended_repair_cmd_constant() -> None:
    assert rc.RECOMMENDED_REPAIR_CMD == "wv sync --gh --mode=repair"
