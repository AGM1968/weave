"""Weave ↔ GitHub bidirectional sync package.

Replaces the monolithic sync_weave_gh.py with a structured package:
  - models: Data classes (WeaveNode, GitHubIssue, Edge, SyncStats)
  - cli: Subprocess wrappers (_run, gh_cli, wv_cli)
  - data: Fetching nodes, issues, and edges
  - rendering: Structured issue bodies, Mermaid graphs, close comments
  - labels: Label constants and management
  - body: WEAVE block extraction and body composition
  - phases: The three sync phases (Weave→GH, GH→Weave, closed sync)
  - notify: Live progress notifications from CLI hooks
"""

from __future__ import annotations

import logging
import shutil
from pathlib import Path

# ---------------------------------------------------------------------------
# Shared configuration
# ---------------------------------------------------------------------------

SCRIPT_DIR = Path(__file__).resolve().parent.parent
"""Path to the scripts/ directory (parent of weave_gh/)."""

_local_wv = SCRIPT_DIR / "wv"
WV_CMD = (
    str(_local_wv) if _local_wv.exists() else (shutil.which("wv") or str(_local_wv))
)
"""Path to the wv CLI entrypoint. Falls back to PATH lookup when installed."""

log = logging.getLogger("weave-sync")
"""Package-wide logger."""
