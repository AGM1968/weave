"""Subprocess wrappers for gh and wv CLIs."""

from __future__ import annotations

import subprocess
import time

from weave_gh import WV_CMD, log

# Match semantic rate-limit language only — NOT bare "403" or "429" which
# can mean permission denied (wrong repo, revoked token). Retrying a
# permission error wastes 14s for no benefit.
_RATE_LIMIT_PATTERNS = (
    "rate limit",
    "api rate limit",
    "secondary rate limit",
    "abuse detection",
)

_MAX_RETRIES = 3
_BASE_DELAY = 2.0  # seconds — doubles each retry: 2, 4, 8


def _is_rate_limited(result: subprocess.CompletedProcess[str]) -> bool:
    """Check if a gh CLI failure looks like a rate limit."""
    if result.returncode == 0:
        return False
    stderr = result.stderr.lower()
    return any(pat in stderr for pat in _RATE_LIMIT_PATTERNS)


def _run(cmd: list[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
    """Run a command with retry on rate limits."""
    result: subprocess.CompletedProcess[str] | None = None
    for attempt in range(_MAX_RETRIES + 1):
        log.debug("$ %s (attempt %d)", " ".join(cmd), attempt + 1)
        result = subprocess.run(cmd, capture_output=True, text=True, check=False)

        if result.returncode == 0:
            return result

        if _is_rate_limited(result) and attempt < _MAX_RETRIES:
            delay = _BASE_DELAY * (2**attempt)
            log.warning(
                "Rate limited, retrying in %.0fs (%d/%d): %s",
                delay,
                attempt + 1,
                _MAX_RETRIES,
                " ".join(cmd),
            )
            time.sleep(delay)
            continue

        # Non-rate-limit failure — don't retry
        break

    assert result is not None  # loop always runs at least once
    if check and result.returncode != 0:
        log.error("Command failed: %s\nstderr: %s", " ".join(cmd), result.stderr)
        raise subprocess.CalledProcessError(
            result.returncode, cmd, result.stdout, result.stderr
        )
    return result


def gh_cli(*args: str, check: bool = True) -> str:
    """Run gh CLI command, return stdout."""
    result = _run(["gh", *args], check=check)
    return result.stdout.strip()


def wv_cli(*args: str, check: bool = True) -> str:
    """Run wv CLI command, return stdout."""
    result = _run([WV_CMD, *args], check=check)
    return result.stdout.strip()
