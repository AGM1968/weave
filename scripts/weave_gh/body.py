"""WEAVE block extraction and issue body composition."""

from __future__ import annotations

import re

# Regex to extract the WEAVE block and its hash
_WEAVE_BLOCK_RE = re.compile(
    r"<!-- WEAVE:BEGIN hash=([a-f0-9]+) -->\r?\n(.*?)<!-- WEAVE:END -->",
    re.DOTALL,
)


def extract_weave_block(body: str) -> tuple[str | None, str | None]:
    """Extract (hash, content) from existing WEAVE block in issue body."""
    m = _WEAVE_BLOCK_RE.search(body)
    if m:
        return m.group(1), m.group(2)
    return None, None


def extract_human_content(body: str) -> str:
    """Extract human-written content above the WEAVE block."""
    m = _WEAVE_BLOCK_RE.search(body)
    if m:
        return body[: m.start()].rstrip()
    # No WEAVE block — the entire body is human content (legacy issue)
    # Preserve it above the new WEAVE block
    if body.strip():
        return body.rstrip()
    return ""


def compose_issue_body(human_content: str, weave_block: str) -> str:
    """Combine human content and WEAVE block into final issue body."""
    if human_content:
        return f"{human_content}\n\n{weave_block}"
    return weave_block


def should_update_body(existing_body: str, new_weave_block: str) -> bool:
    """Check if the issue body needs updating by comparing content hashes."""
    existing_hash, _ = extract_weave_block(existing_body)
    new_hash, _ = extract_weave_block(new_weave_block)
    if existing_hash is None:
        return True  # No existing WEAVE block — need to add one
    return existing_hash != new_hash


def parse_gh_body_description(body: str) -> str:
    """Extract description from GH issue body (content before WEAVE block)."""
    human = extract_human_content(body)
    if human:
        # Strip out the old "**Weave ID**: ..." preamble from legacy bodies
        lines = human.split("\n")
        clean = [
            line
            for line in lines
            if not line.startswith("**Weave ID**")
            and line.strip() != "---"
            and line.strip() != "*Synced from Weave*"
        ]
        return "\n".join(clean).strip()
    return ""


# Regex for GitHub issue template form sections: ### Header\n\nvalue
_FORM_SECTION_RE = re.compile(
    r"^### (.+?)\s*\n\n(.*?)(?=\n### |\Z)", re.DOTALL | re.MULTILINE
)


def parse_issue_template_fields(body: str) -> dict[str, str]:
    """Parse structured fields from GitHub issue template form body.

    Returns dict with lowercase keys (e.g. "type", "priority", "description",
    "weave id"). Values are stripped. Empty/placeholder values are excluded.
    """
    fields: dict[str, str] = {}
    for m in _FORM_SECTION_RE.finditer(body):
        key = m.group(1).strip().lower()
        val = m.group(2).strip()
        if val and val != "_No response_":
            fields[key] = val
    return fields
