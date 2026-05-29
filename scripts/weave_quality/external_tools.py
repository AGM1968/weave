"""Resolution helpers for optional external tools."""

from __future__ import annotations

import os
import shutil
from pathlib import Path


def _common_user_bin_dirs() -> list[Path]:
    home = Path.home()
    return [
        home / ".local" / "bin",
        home / ".cargo" / "bin",
    ]


def resolve_tool(name: str) -> str | None:
    """Resolve an executable from PATH or common per-user install dirs."""
    found = shutil.which(name)
    if found:
        return found

    if os.environ.get("WV_DISABLE_USER_TOOL_PATHS") == "1":
        return None

    for directory in _common_user_bin_dirs():
        candidate = directory / name
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


def ast_grep_bin() -> str | None:
    """Return the ast-grep executable path, if available."""
    return resolve_tool("ast-grep")
