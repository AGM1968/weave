"""Historical findings promotion helpers."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from typing import Any

_HISTORICAL_PATH_RE = re.compile(
    r"\b(?:[\w.-]+/)*[\w.-]+\.(?:py|sh|ts|tsx|js|jsx|json|ya?ml|md|toml|ini|cfg)\b"
)
_HISTORICAL_RULE_RE = re.compile(r"\bR\d+:[A-Za-z0-9._-]+\b")
_HISTORICAL_SUMMARY_RE = re.compile(
    r"^(?:sprint|phase|epic)\b.*\b(?:complete|completed|validation complete|validated)\b",
    re.IGNORECASE,
)
_HISTORICAL_SIGNAL_TYPES = ("defect", "guardrail", "root_cause", "tooling")
_HISTORICAL_NUMBERED_ITEM_RE = re.compile(
    r"\(\d+\)\s*(.*?)(?=(?:,\s*\(\d+\)|;\s*\(\d+\)|\s+\(\d+\)|$))"
)


def _wv_cmd(*cmd_args: str) -> tuple[int, str]:
    """Run a wv CLI command, return (returncode, stdout)."""
    try:
        result = subprocess.run(
            [os.environ.get("WV_CLI", "wv"), *cmd_args],
            capture_output=True,
            text=True,
            check=False,
        )
        return result.returncode, result.stdout.strip()
    except FileNotFoundError:
        return 1, "wv command not found"


def _load_node_metadata(node: dict[str, Any]) -> dict[str, Any]:
    """Return a node metadata dict from list/show JSON output."""
    metadata = node.get("metadata", {})
    if isinstance(metadata, dict):
        return metadata
    if isinstance(metadata, str) and metadata:
        try:
            parsed = json.loads(metadata)
        except json.JSONDecodeError:
            return {}
        return parsed if isinstance(parsed, dict) else {}
    return {}


def _normalize_finding_text(text: str) -> str:
    """Normalize text for idempotency and exact-match dedupe."""
    return re.sub(r"[^a-z0-9]+", " ", text.lower()).strip()


def _historical_duplicate_signature(text: str, signal_type: str) -> str | None:
    """Return a coarse duplicate signature for known same-bug historical variants."""
    if signal_type != "defect":
        return None

    lower = text.lower()
    if (
        "_convert_sampled_features" in lower
        and "hardcoded field list" in lower
        and any(token in lower for token in ("dropped", "lost"))
    ):
        return "defect:_convert_sampled_features:hardcoded-field-list-drop"
    return None


def _truncate_finding_text(text: str, limit: int = 120) -> str:
    """Trim text without breaking mid-word when possible."""
    compact = " ".join(text.split())
    if len(compact) <= limit:
        return compact
    clipped = compact[: limit - 3].rstrip()
    if " " in clipped:
        clipped = clipped.rsplit(" ", 1)[0]
    return f"{clipped}..."


def _extract_learning_segments(text: str, default_kind: str) -> list[tuple[str, str]]:
    """Split learning text into typed segments."""
    segments: list[tuple[str, str]] = []
    for raw_part in re.split(r"\s*[|\n]\s*", text.strip()):
        part = raw_part.strip(" -")
        if not part:
            continue
        match = re.match(r"(?i)(decision|pattern|pitfall|finding):\s*(.+)", part)
        if match:
            for clause in _split_learning_part(match.group(2).strip()):
                segments.append((match.group(1).lower(), clause))
            continue
        for clause in _split_learning_part(part):
            segments.append((default_kind, clause))
    return segments


def _split_learning_part(part: str) -> list[str]:
    """Split one learning part into atomic clauses where possible."""
    compact = " ".join(part.split())
    if not compact:
        return []

    shared_prefix = ""
    enumerated_text = compact
    match = re.match(r"^(.*?):\s*(\(\d+\).+)$", compact)
    if match:
        shared_prefix = match.group(1).strip()
        enumerated_text = match.group(2).strip()

    numbered_items = [
        item.strip(" ,;")
        for item in _HISTORICAL_NUMBERED_ITEM_RE.findall(enumerated_text)
        if len(item.strip(" ,;").split()) >= 4
    ]
    if len(numbered_items) >= 2:
        prefix_lower = shared_prefix.lower()
        if "bug" in prefix_lower and "ee" in prefix_lower:
            shared_prefix = "EE bug"
        elif "bug" in prefix_lower and "fix" in prefix_lower:
            shared_prefix = "Bug fix"
        elif shared_prefix and re.match(
            r"^(?:one|two|three|four|five|several|multiple)\b", prefix_lower
        ):
            shared_prefix = ""
        results: list[str] = []
        for item in numbered_items:
            if shared_prefix:
                results.append(f"{shared_prefix}: {item}")
            else:
                results.append(item)
        return results

    clauses = re.split(r"(?<=[.!?])\s+", compact)
    results = [clause.strip(" -") for clause in clauses if len(clause.strip(" -").split()) >= 4]
    if results:
        return results
    return [compact] if len(compact.split()) >= 4 else []


def _collect_historical_segments(
    node: dict[str, Any], metadata: dict[str, Any]
) -> list[tuple[str, str, bool]]:
    """Collect historical learning and text segments from a done node."""
    segments: list[tuple[str, str, bool]] = []
    seen: set[tuple[str, str]] = set()

    def add_segment(kind: str, text: str, promoted_from_learning: bool) -> None:
        cleaned = " ".join(text.split())
        if not cleaned:
            return
        dedupe_key = (kind, _normalize_finding_text(cleaned))
        if dedupe_key in seen:
            return
        seen.add(dedupe_key)
        segments.append((kind, cleaned, promoted_from_learning))

    for key in ("finding", "pitfall", "pattern", "decision"):
        value = metadata.get(key)
        if isinstance(value, str):
            add_segment(key, value, True)

    learning = metadata.get("learning")
    if isinstance(learning, str):
        for kind, text in _extract_learning_segments(learning, "learning"):
            add_segment(kind, text, True)

    node_text = node.get("text")
    node_type = str(metadata.get("type", "")).lower()
    if (
        isinstance(node_text, str)
        and len(node_text.split()) >= 5
        and not _historical_is_task_stub_text(node_text, node_type)
    ):
        add_segment("text", node_text, False)

    return segments


def _extract_file_refs(text: str) -> list[str]:
    """Extract file-like references mentioned in learning text."""
    matches = _HISTORICAL_PATH_RE.findall(text)
    ordered: list[str] = []
    seen: set[str] = set()
    for match in matches:
        if match not in seen:
            ordered.append(match)
            seen.add(match)
    return ordered


def _historical_candidate_score(
    source_kind: str, signal_type: str, text: str, files: list[str]
) -> int:
    """Assign a simple promotion score to a historical candidate."""
    lower = text.lower()
    score = {
        "finding": 4,
        "pitfall": 3,
        "learning": 1,
        "decision": 1,
        "pattern": 1,
        "text": 0,
    }.get(source_kind, 0)
    score += {
        "defect": 2,
        "guardrail": 1,
        "root_cause": 1,
        "tooling": 0,
    }.get(signal_type, 0)

    if files:
        score += 2
    if _historical_has_code_context(text):
        score += 1
    if any(
        token in lower
        for token in (
            "critical",
            "severe",
            "high",
            "security",
            "regression",
            "false positive",
            "failure",
            "broken",
            "stale",
            "hang",
            "blocked",
            "risk",
            "denied",
            "orphan",
            "silently",
            "dropped",
            "invalid",
            "misconfigured",
        )
    ):
        score += 2
    if any(
        token in lower
        for token in (
            "production",
            "runtime",
            "session",
            "hook",
            "sync",
            "workflow",
            "close",
            "verification",
            "github",
            "issue",
            "agent",
        )
    ):
        score += 1
    if any(
        token in lower
        for token in (
            "fix",
            "update",
            "record",
            "remove",
            "wire",
            "add",
            "must",
            "should",
            "need",
            "missing",
            "omitted",
            "because",
            "caused by",
            "root cause",
        )
    ):
        score += 2
    if re.search(r"\b\d+(?:\.\d+)?\b", text):
        score += 1
    if len(text.split()) >= 8:
        score += 1
    return score


def _historical_signal_type(text: str, source_kind: str, node_type: str) -> str | None:
    """Classify one clause into a promotion signal bucket."""
    lower = text.lower()
    tooling_tokens = (
        "mcp",
        "adc ",
        "application-default login",
        "user_project_denied",
        "cloud-platform only",
        ".mypy_cache",
        "cache corruption",
        "_frozen_importlib",
        "gcloud auth",
        "earthengine,https://www.googleapis.com/auth/cloud-platform",
    )
    root_cause_tokens = (
        "root cause",
        "confirmed",
        "because",
        "revealed",
        "dominated by",
        "driven by",
        "due to",
        "unimodal",
        "bimodality",
        "zone-wide histogram",
        "causing",
        "redesign",
        "proposal",
    )
    guardrail_tokens = (
        "must",
        "must not",
        "should",
        "always",
        "quality_flag",
        "not_for_monitoring",
        "downstream misuse",
        "uncertain",
        "guardrail",
    )
    defect_tokens = (
        "error",
        "wrong",
        "defaults to",
        "defaulting to",
        "silently dropped",
        "silently",
        "dropped",
        "bypass",
        "bypasses",
        "returns",
        "inflates",
        "invalid",
        "regression",
        "false positive",
        "broken",
        "nan",
        "null",
        "fix:",
        "omitted",
        "missing",
        "coerced to",
        "hardcoded",
        "lost",
        "unparseable",
        "count*interval",
    )
    explicit_defect = (
        node_type in {"bugfix", "finding"}
        or lower.startswith(("bug:", "ee bug:", "bug fix:"))
        or lower.startswith("finding #")
        or any(token in lower for token in defect_tokens)
    )
    explicit_guardrail = any(token in lower for token in guardrail_tokens)
    explicit_root_cause = "root cause" in lower or any(token in lower for token in root_cause_tokens)

    if _historical_is_internal_tooling_note(text) or any(token in lower for token in tooling_tokens):
        return "tooling"
    if explicit_guardrail:
        if explicit_defect:
            return "defect"
        return "guardrail"
    if explicit_root_cause and not explicit_defect:
        return "root_cause"
    if explicit_defect:
        return "defect"
    if source_kind == "pitfall":
        return "defect"
    return None


def _historical_is_summary_noise(text: str) -> bool:
    """Return True for retrospective summaries that should not become findings."""
    lower = text.lower()
    if _HISTORICAL_SUMMARY_RE.search(text):
        return True
    return any(
        token in lower
        for token in (
            "completed 10/11 tasks",
            "key outcomes:",
            "resolves all 13 audit issues",
            "legacy reference only",
            "no longer used in production pipeline",
            "won't-fix",
            "ported 4 seasonal models",
            "identical generic.json structure",
            "future refactor should extract",
            "unify in future cleanup",
            "epic created with 5 tasks",
            "created comprehensive improvement plan",
            "production quality review fixes",
            "production hardening fixes touched code",
        )
    )


def _historical_is_task_stub_text(text: str, node_type: str) -> bool:
    """Return True when raw node text is a task/epic stub, not a finding."""
    lower = text.lower()
    if node_type == "task":
        return True
    return lower.startswith(("task:", "epic:", "feature:", "chore:"))


def _historical_is_tooling_baseline_noise(text: str) -> bool:
    """Return True for environment/version verification notes that are never findings."""
    lower = text.lower()
    return any(
        token in lower
        for token in (
            "weave 1.",
            "mcp bug",
            "mcp bugs",
            "mcp quality tools",
            "mcp.json",
            "vscode hooks enabled",
            "vscode hook",
            "vscode hooks",
            "spawnsync fix",
            "virtual_env=1",
            "new tools verified",
            "quality baseline",
            "quality score dropped",
            "scans 272 files",
            "scanning more file types",
            "all 4 mcp quality tools now return proper json",
            "scan dropped",
            "18x faster",
            "pre-commit hook verified",
            "make targets added",
            "python 3.10 guard",
            "stderr drop",
            "all 4 mcp quality tools",
        )
    )


def _historical_is_internal_tooling_note(text: str) -> bool:
    """Return True for Weave/runtime/tooling learnings hidden by default."""
    lower = text.lower()
    return any(
        token in lower
        for token in (
            "quality db cache",
            "/dev/shm/weave/",
            "incremental scan shows stale count",
            "quality scanner has",
            "match/case cc",
            "visit_match_case",
            "dit metric",
            "ev always none",
            "essential_complexity",
            "functioncc dataclass",
            "_complexityvisitor",
            "_essentialcomplexityvisitor",
            "quality score ignores ev/gini",
            "excepthandler",
            "rollout-policy tasks",
            "active node leads to long-lived stale tasks",
            "mixing policy design and implementation execution",
            "track implementation deltas in a separate execution node",
            "wv link --context",
            "plain-text --context strings",
            "invalid json in --context",
            "operator muscle memory",
            "regression_source:",
            "ops.journal",
            "killed syncs",
            "wv sync/recover",
            "wv sync hangs silently",
            "metadata >100kb",
            "metadata exceeds 100kb",
            "pre-check sizes before sync",
            "ev(g)",
            "essential complexity",
            "max essential complexity",
            "non-reducible flow",
            "mypy no-any-return",
            "dict.get() returns any",
            "must cast explicitly",
            "returns any|none",
            "bandnames().getinfo() returns any",
            "guard with ''or []''",
            "check overriding signature",
            "type alias",
        )
    )


def _historical_is_style_noise(text: str) -> bool:
    """Return True for style-only lint learnings that are not operational findings."""
    lower = text.lower()
    return any(
        token in lower
        for token in (
            "md049",
            "markdown emphasis must use underscores",
            "asterisks per md049",
            "lint rule",
            "style-only",
        )
    )


def _historical_is_test_noise(text: str) -> bool:
    """Return True for test-coverage notes that are not product findings."""
    lower = text.lower()
    if "no existing tests covered" in lower:
        return True
    if "trivial fix:" in lower and "assert" in lower:
        return True
    if "had a test expecting" in lower and "test_" in lower:
        return True
    if "cannot be caught in tests" in lower and "module is patched" in lower:
        return True
    if "mock_ee.eeexception" in lower:
        return True
    if "updated assertions" in lower:
        return True
    if "testing calibrate()" in lower and "requires both" in lower:
        return True
    if "test files referenced removed symbols" in lower:
        return True
    if "grep tests/" in lower and "removed symbols" in lower:
        return True
    return bool(re.search(r"\badded \d+ tests?\b", lower) and "test" in lower)


def _historical_needs_more_context(text: str, source_kind: str, files: list[str]) -> bool:
    """Return True for overly-short fragments that lack concrete context."""
    if source_kind not in {"pitfall", "learning"}:
        return False
    if files:
        return False
    lower = text.lower()
    words = lower.split()
    if len(words) >= 12:
        return False
    if _HISTORICAL_PATH_RE.search(text):
        return False
    if re.search(r"\b[a-z_][a-z0-9_]*\(\)", text):
        return False
    return any(
        token in lower
        for token in (
            "divide-by-zero",
            "divide by zero",
            "must guard",
            "must check",
            "must handle",
            "should guard",
        )
    )


def _historical_has_code_context(text: str) -> bool:
    """Return True when text names a concrete config/code surface."""
    lower = text.lower()
    return bool(
        _HISTORICAL_PATH_RE.search(text)
        or re.search(r"\b[a-z_][a-z0-9_]*\b", text)
        or any(token in lower for token in ("config", "factory", "runner", "timeline"))
    )


def _historical_confidence(score: int) -> str:
    """Map a score to the required finding confidence enum."""
    if score >= 7:
        return "high"
    if score >= 5:
        return "medium"
    return "low"


def _historical_severity(text: str, score: int) -> str:
    """Infer a user-facing severity label from the source text."""
    lower = text.lower()
    if any(token in lower for token in ("critical", "security", "severe", "outage")):
        return "high"
    if any(token in lower for token in ("regression", "broken", "failure", "risk")):
        return "medium"
    return "medium" if score >= 6 else "low"


def _historical_violation_type(source_kind: str, signal_type: str, text: str) -> str:
    """Infer a violation type for a promoted finding."""
    if rule_match := _HISTORICAL_RULE_RE.search(text):
        return rule_match.group(0)
    if signal_type in _HISTORICAL_SIGNAL_TYPES:
        return f"historical:{signal_type}"
    if source_kind in {"finding", "pitfall"}:
        return f"historical:{source_kind}"
    return "historical:learning-promotion"


def _historical_proposed_fix(source_node: str, text: str, files: list[str]) -> str:
    """Infer a reasonable proposed fix from a promoted historical candidate."""
    lower = text.lower()
    if any(
        token in lower
        for token in ("fix", "update", "record", "remove", "wire", "add", "must", "should")
    ):
        return _truncate_finding_text(text, limit=220)
    if files:
        joined = ", ".join(files[:3])
        return f"Review {joined} and turn the historical learning into a concrete guardrail or fix."
    return f"Review source node {source_node} and convert the promoted learning into a tracked fix."


def _historical_finding_id(source_node: str, source_kind: str, text: str) -> str:
    """Build a stable idempotency key for promoted historical findings."""
    normalized = _normalize_finding_text(text)
    return hashlib.sha256(f"{source_node}:{source_kind}:{normalized}".encode()).hexdigest()[:12]


def _build_historical_candidate(
    node: dict[str, Any],
    metadata: dict[str, Any],
    source_kind: str,
    text: str,
    promoted_from_learning: bool,
) -> dict[str, object] | None:
    """Convert one learning/text segment into a promotable candidate."""
    source_node = str(node.get("id", ""))
    if not source_node:
        return None

    node_type = str(metadata.get("type", "")).lower()
    if _historical_is_summary_noise(text):
        return None

    files = _extract_file_refs(text)
    if _historical_is_tooling_baseline_noise(text):
        return None
    if _historical_is_style_noise(text):
        return None
    if _historical_is_test_noise(text):
        return None
    if _historical_needs_more_context(text, source_kind, files):
        return None
    signal_type = _historical_signal_type(text, source_kind, node_type)
    if signal_type is None:
        return None
    score = _historical_candidate_score(source_kind, signal_type, text, files)
    threshold = 4 if source_kind in {"finding", "pitfall"} else 5
    if source_kind == "learning" and _historical_has_code_context(text):
        threshold = 4
    if score < threshold:
        return None

    confidence = _historical_confidence(score)
    severity = _historical_severity(text, score)
    finding = {
        "violation_type": _historical_violation_type(source_kind, signal_type, text),
        "root_cause": text,
        "proposed_fix": _historical_proposed_fix(source_node, text, files),
        "confidence": confidence,
        "fixable": bool(
            files
            or re.search(
                r"\b(fix|update|record|remove|wire|add|must|should|need)\b",
                text.lower(),
            )
        ),
        "evidence_sessions": [source_node],
    }
    summary = _truncate_finding_text(text)
    title = summary if summary.lower().startswith("finding:") else f"Finding: {summary}"
    return {
        "text": title,
        "source_node": source_node,
        "source_kind": source_kind,
        "signal_type": signal_type,
        "promoted_from_learning": promoted_from_learning,
        "historical_finding_id": _historical_finding_id(source_node, source_kind, text),
        "category": f"historical-{signal_type}",
        "severity": severity,
        "files": files,
        "score": score,
        "finding": finding,
    }


def _historical_score_value(candidate: dict[str, object]) -> int:
    """Return a typed score value from a candidate payload."""
    score = candidate.get("score", 0)
    return score if isinstance(score, int) else 0


def _prepare_historical_candidates(
    loaded_nodes: list[dict[str, Any]],
) -> tuple[set[str], set[str], set[tuple[str, str]], list[dict[str, object]]]:
    """Split nodes into existing finding indexes and ranked promotion candidates."""
    existing_ids: set[str] = set()
    existing_texts: set[str] = set()
    existing_source_roots: set[tuple[str, str]] = set()
    candidates_by_id: dict[str, dict[str, object]] = {}

    for raw_node in loaded_nodes:
        metadata = _load_node_metadata(raw_node)
        if metadata.get("type") == "finding":
            existing_texts.add(_normalize_finding_text(str(raw_node.get("text", ""))))
            historical_id = metadata.get("historical_finding_id")
            if isinstance(historical_id, str) and historical_id:
                existing_ids.add(historical_id)
            source_node = metadata.get("source_node")
            finding = metadata.get("finding", {})
            if (
                isinstance(source_node, str)
                and source_node
                and isinstance(finding, dict)
                and isinstance(finding.get("root_cause"), str)
            ):
                existing_source_roots.add(
                    (source_node, _normalize_finding_text(str(finding["root_cause"])))
                )
            continue

        if raw_node.get("status") != "done":
            continue

        for source_kind, text, promoted_from_learning in _collect_historical_segments(
            raw_node, metadata
        ):
            candidate = _build_historical_candidate(
                raw_node,
                metadata,
                source_kind,
                text,
                promoted_from_learning,
            )
            if candidate is None:
                continue
            candidate_id = str(candidate["historical_finding_id"])
            current = candidates_by_id.get(candidate_id)
            if current is None or _historical_score_value(candidate) > _historical_score_value(
                current
            ):
                candidates_by_id[candidate_id] = candidate

    ranked = sorted(
        candidates_by_id.values(),
        key=lambda item: (
            -_historical_score_value(item),
            str(item["source_node"]),
            str(item["text"]),
        ),
    )
    return existing_ids, existing_texts, existing_source_roots, ranked


def _historical_candidate_already_promoted(
    candidate: dict[str, object],
    existing_ids: set[str],
    existing_texts: set[str],
    existing_source_roots: set[tuple[str, str]],
) -> bool:
    """Return True when a candidate matches an existing finding."""
    normalized_text = _normalize_finding_text(str(candidate["text"]))
    source_root_key = (
        str(candidate["source_node"]),
        _normalize_finding_text(
            str(
                (
                    candidate["finding"]
                    if isinstance(candidate["finding"], dict)
                    else {}
                ).get("root_cause", "")
            )
        ),
    )
    return (
        str(candidate["historical_finding_id"]) in existing_ids
        or normalized_text in existing_texts
        or source_root_key in existing_source_roots
    )


def _historical_promotion_window(
    top_n: int, selected_signal_types: set[str]
) -> dict[str, object]:
    """Describe the reviewed promotion window for later audit."""
    return {
        "top": top_n,
        "signal_types": sorted(selected_signal_types),
        "backfill": False,
    }


def _historical_promotion_metadata(
    candidate: dict[str, object], review_window: dict[str, object]
) -> dict[str, object]:
    """Build finding metadata for a reviewed historical candidate."""
    return {
        "type": "finding",
        "finding": candidate["finding"],
        "source_node": candidate["source_node"],
        "historical_finding_id": candidate["historical_finding_id"],
        "promoted_from_learning": candidate["promoted_from_learning"],
        "severity": candidate["severity"],
        "category": candidate["category"],
        "files": candidate["files"],
        "signal_type": candidate["signal_type"],
        "promotion_batch_window": review_window,
    }


def _print_historical_review_event(
    candidate: dict[str, object], parent: str, label: str
) -> None:
    """Emit a reviewed-candidate status line."""
    print(f"{label}: {candidate['text']}", file=sys.stderr)
    print(f"  -> source {candidate['source_node']}", file=sys.stderr)
    if parent:
        print(f"  -> references {parent}", file=sys.stderr)


def _historical_created_node_id(output: str) -> str:
    """Extract a Weave node id from command output."""
    for word in output.split():
        if word.startswith("wv-"):
            return word.rstrip(":")
    return ""


def _apply_historical_candidate(
    candidate: dict[str, object], metadata: dict[str, object], parent: str
) -> tuple[dict[str, object] | None, str | None]:
    """Create and link a reviewed historical finding candidate."""
    rc_add, out = _wv_cmd(
        "add",
        str(candidate["text"]),
        f"--metadata={json.dumps(metadata)}",
        "--force",
    )
    if rc_add != 0:
        print(
            f"Error creating historical finding for {candidate['source_node']}: {out}",
            file=sys.stderr,
        )
        return None, "create_failed"

    node_id = _historical_created_node_id(out)
    if not node_id:
        return None, "missing_node_id"

    if parent:
        _wv_cmd("link", node_id, parent, "--type=references")
    source_node = str(candidate["source_node"])
    if source_node != parent:
        _wv_cmd("link", node_id, source_node, "--type=references")
    print(f"Created {node_id}: {candidate['text']}", file=sys.stderr)
    return {"node_id": node_id, "created": True, "eligible_for_apply": True}, None


def _historical_json_result(
    *,
    dry_run: bool,
    include_guardrails: bool,
    include_root_causes: bool,
    include_tooling: bool,
    selected_signal_types: set[str],
    review_window: dict[str, object],
    reviewed: list[dict[str, object]],
    promoted: list[dict[str, object]],
    skipped_already_promoted: int,
    skipped_invalid: int,
    duplicate_skipped: int,
    parent: str,
) -> dict[str, object]:
    """Build JSON output for historical findings promotion."""
    result: dict[str, object] = {
        "skipped": skipped_already_promoted + skipped_invalid,
        "reviewed_candidates": len(reviewed),
        "created": len(promoted),
        "skipped_already_promoted": skipped_already_promoted,
        "skipped_invalid": skipped_invalid,
        "backfilled_beyond_reviewed_set": 0,
        "duplicate_candidates_filtered": duplicate_skipped,
        "dry_run": dry_run,
        "include_guardrails": include_guardrails,
        "include_root_causes": include_root_causes,
        "include_tooling": include_tooling,
        "signal_types": sorted(selected_signal_types),
        "review_window": review_window,
    }
    if parent:
        result["parent"] = parent
    if dry_run:
        result["candidates"] = reviewed
    else:
        result["reviewed"] = reviewed
        result["promoted"] = promoted
    return result


def _print_historical_summary(
    *,
    dry_run: bool,
    reviewed: list[dict[str, object]],
    promoted: list[dict[str, object]],
    skipped_already_promoted: int,
    skipped_invalid: int,
) -> None:
    """Print text output for historical findings promotion."""
    if not reviewed:
        print("No historical findings met promotion criteria.", file=sys.stderr)
        return
    if dry_run:
        print(
            f"Reviewed {len(reviewed)} historical finding candidate(s).",
            file=sys.stderr,
        )
        if skipped_already_promoted > 0:
            print(
                f"{skipped_already_promoted} reviewed candidate(s) already promoted.",
                file=sys.stderr,
            )
        return

    print(f"Reviewed candidates: {len(reviewed)}", file=sys.stderr)
    print(f"Created: {len(promoted)}", file=sys.stderr)
    print(
        f"Skipped already promoted: {skipped_already_promoted}",
        file=sys.stderr,
    )
    print(f"Skipped filtered/invalid: {skipped_invalid}", file=sys.stderr)
    print("Backfilled beyond reviewed set: 0", file=sys.stderr)


def _select_historical_candidates(
    ranked: list[dict[str, object]],
    selected_signal_types: set[str],
    top_n: int,
) -> tuple[list[dict[str, object]], int]:
    """Select the reviewed window with reserved visibility for requested signal classes."""
    eligible: list[dict[str, object]] = []
    skipped = 0
    seen_signatures: set[str] = set()
    for candidate in ranked:
        if str(candidate.get("signal_type", "")) not in selected_signal_types:
            continue
        finding = candidate.get("finding")
        root_cause = str(finding.get("root_cause", "")) if isinstance(finding, dict) else ""
        signature = _historical_duplicate_signature(
            root_cause,
            str(candidate.get("signal_type", "")),
        )
        if signature is not None and signature in seen_signatures:
            skipped += 1
            continue
        if signature is not None:
            seen_signatures.add(signature)
        eligible.append(candidate)

    if len(selected_signal_types) <= 1 or top_n <= 1:
        return eligible[:top_n], skipped

    selected: list[dict[str, object]] = []
    used_ids: set[str] = set()
    for signal_type in ("defect", "guardrail", "root_cause", "tooling"):
        if signal_type not in selected_signal_types or len(selected) >= top_n:
            continue
        for candidate in eligible:
            candidate_id = str(candidate.get("historical_finding_id", ""))
            if (
                str(candidate.get("signal_type", "")) == signal_type
                and candidate_id not in used_ids
            ):
                selected.append(candidate)
                used_ids.add(candidate_id)
                break

    if len(selected) >= top_n:
        return selected[:top_n], skipped

    for candidate in eligible:
        candidate_id = str(candidate.get("historical_finding_id", ""))
        if candidate_id in used_ids:
            continue
        selected.append(candidate)
        used_ids.add(candidate_id)
        if len(selected) >= top_n:
            break
    return selected, skipped


def cmd_findings_promote(args: argparse.Namespace) -> int:
    """Promote historical learnings from done nodes into finding nodes."""
    top_n: int = args.top
    parent: str = args.parent
    json_output: bool = args.json
    include_guardrails: bool = getattr(args, "include_guardrails", False)
    include_root_causes: bool = getattr(args, "include_root_causes", False)
    include_tooling: bool = getattr(args, "include_tooling", False)
    apply: bool = getattr(args, "apply", False)
    dry_run: bool = getattr(args, "dry_run", False) or not apply
    selected_signal_types = {"defect"}
    if include_guardrails:
        selected_signal_types.add("guardrail")
    if include_root_causes:
        selected_signal_types.add("root_cause")
    if include_tooling:
        selected_signal_types.add("tooling")

    if apply and not parent:
        print("Error: --parent=<node-id> is required with --apply.", file=sys.stderr)
        return 1

    rc, nodes_json = _wv_cmd("list", "--json", "--all")
    if rc != 0:
        print("Error: unable to load Weave nodes.", file=sys.stderr)
        return 1

    try:
        loaded_nodes = json.loads(nodes_json) if nodes_json else []
    except json.JSONDecodeError:
        print("Error: unable to parse Weave node list.", file=sys.stderr)
        return 1
    if not isinstance(loaded_nodes, list):
        print("Error: unexpected Weave node payload.", file=sys.stderr)
        return 1

    typed_nodes = [node for node in loaded_nodes if isinstance(node, dict)]
    existing_ids, existing_texts, existing_source_roots, ranked = _prepare_historical_candidates(
        typed_nodes
    )

    selected_candidates, duplicate_skipped = _select_historical_candidates(
        ranked,
        selected_signal_types,
        top_n,
    )
    review_window = _historical_promotion_window(top_n, selected_signal_types)
    reviewed: list[dict[str, object]] = []
    promoted: list[dict[str, object]] = []
    skipped_already_promoted = 0
    skipped_invalid = 0
    for candidate in selected_candidates:
        metadata = _historical_promotion_metadata(candidate, review_window)
        reviewed_entry = {**candidate, "metadata": metadata}
        if _historical_candidate_already_promoted(
            candidate, existing_ids, existing_texts, existing_source_roots
        ):
            skipped_already_promoted += 1
            reviewed_entry["eligible_for_apply"] = False
            reviewed_entry["skipped_reason"] = "already_promoted"
            reviewed.append(reviewed_entry)
            if dry_run:
                _print_historical_review_event(
                    candidate, parent, "[DRY-RUN] Already promoted"
                )
            else:
                print(f"Skipped already promoted: {candidate['text']}", file=sys.stderr)
            continue

        if dry_run:
            _print_historical_review_event(candidate, parent, "[DRY-RUN] Would create")
            reviewed_entry["eligible_for_apply"] = True
            reviewed.append(reviewed_entry)
            continue

        creation_result, skip_reason = _apply_historical_candidate(
            candidate, metadata, parent
        )
        if skip_reason is not None:
            skipped_invalid += 1
            reviewed_entry["eligible_for_apply"] = False
            reviewed_entry["skipped_reason"] = skip_reason
            reviewed.append(reviewed_entry)
            continue

        reviewed_entry.update(creation_result or {})
        reviewed.append(reviewed_entry)
        promoted.append(reviewed_entry)

    if json_output:
        print(
            json.dumps(
                _historical_json_result(
                    dry_run=dry_run,
                    include_guardrails=include_guardrails,
                    include_root_causes=include_root_causes,
                    include_tooling=include_tooling,
                    selected_signal_types=selected_signal_types,
                    review_window=review_window,
                    reviewed=reviewed,
                    promoted=promoted,
                    skipped_already_promoted=skipped_already_promoted,
                    skipped_invalid=skipped_invalid,
                    duplicate_skipped=duplicate_skipped,
                    parent=parent,
                )
            )
        )
    else:
        _print_historical_summary(
            dry_run=dry_run,
            reviewed=reviewed,
            promoted=promoted,
            skipped_already_promoted=skipped_already_promoted,
            skipped_invalid=skipped_invalid,
        )

    return 0
