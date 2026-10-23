"""S4e rehearsal chain check (docs/e5-capture/s4e_chain_check.py).

The check's job is to FAIL a capture that does not prove the rehearsal ran as
written and that every row tagged agent was the agent's. Each case builds a
capture from bytes the way capture-finish does (a call-log slice and a Claude
session export bound by digest in the receipt), so the check reads the same
artifacts it reads in a real rehearsal. The cases are the review findings on
0b930bc1f (wv-b131b2), 0a74c0c66 (wv-6caf18) and 04429c93f (wv-29868f); the
mutants that each case kills are recorded by
docs/e5-capture/s4e_chain_check_mutants.py, and test_mutant_record_is_current
binds that record to these bytes.
"""

from __future__ import annotations

import datetime as dt
import gzip
import hashlib
import json
import re
import sys
import time
import uuid
from collections.abc import Callable
from pathlib import Path
from typing import Any

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "docs" / "e5-capture"))
sys.path.insert(0, str(ROOT / "scripts" / "weave_evidence"))

from e5_workflows import canonical_bytes, claude_session_envelope  # noqa: E402  # pylint: disable=wrong-import-position
# pylint: disable-next=wrong-import-position  # after the sys.path setup it needs
from s4e_chain_check import SCRATCH, SCRATCH_FILE, STEPS, bare_wv_argv, check, prompt_lines  # noqa: E402

WORKFLOW = "s4e-rehearsal-test"
NODE = "wv-abc123"
BASE = 1791211800.0
IDENTITY = {"kind": "canonical_fingerprint", "value": "sha256:" + "a" * 64}
OK = {"is_error": False, "content": "ok"}
REFUSED = {"is_error": True, "content": "PreToolUse:Bash hook error: Claim preflight for wv-abc123 - unmet gates"}


def iso(offset: float) -> str:
    moment = dt.datetime.fromtimestamp(BASE + offset, dt.UTC)
    return moment.strftime("%Y-%m-%dT%H:%M:%S.") + f"{moment.microsecond // 1000:03d}Z"


def row(argv: list[str], at: float, *, source: str = "agent", workflow: str = WORKFLOW,
        call_id: str | None = None, parent: str | None = None) -> dict[str, Any]:
    return {
        "ts": BASE + at, "cmd": f"wv {argv[0]}", "source": source,
        "call_id": call_id or f"wv-{uuid.uuid4().hex}", "parent_call_id": parent,
        "workflow_id": workflow, "exit_status": 0, "argv": argv,
        "graph_identity_before": IDENTITY, "graph_identity_after": IDENTITY,
    }


def repo_of(tmp_path: Path) -> Path:
    return (tmp_path / "repo").resolve()


def capture(tmp_path: Path, rows: list[dict[str, Any]], calls: list[tuple[Any, ...]], *,
            mutate: Callable[[list[dict[str, Any]]], list[dict[str, Any]]] | None = None) -> Path:
    """A capture output dir.

    calls = (tool_use time, tool_result time, command or {"name", "input"}[, result]);
    a tool_result time of None writes no tool_result. mutate(events) may edit
    the session's events before they are serialized.
    """
    repo = repo_of(tmp_path)
    repo.mkdir(exist_ok=True)
    out = tmp_path / "out"
    out.mkdir()
    session = str(uuid.uuid4())

    def event(kind: str, at: float, content: object) -> dict[str, Any]:
        return {"type": kind, "sessionId": session, "cwd": str(repo), "uuid": str(uuid.uuid4()),
                "timestamp": iso(at), "message": {"role": kind, "content": content}}

    events = [event("user", -10, "run the rehearsal")]
    for index, (start, end, tool, *result) in enumerate(calls):
        tool = tool if isinstance(tool, dict) else {"name": "Bash", "input": {"command": tool}}
        tool_id = f"toolu_{index:04d}"
        events.append(event("assistant", start, [{"type": "tool_use", "id": tool_id, **tool}]))
        if end is not None:
            events.append(event("user", end, [
                {"type": "tool_result", "tool_use_id": tool_id, **(result[0] if result else OK)}]))
    if mutate is not None:
        events = mutate(events)
    raw = b"".join(json.dumps(item).encode() + b"\n" for item in events)
    export = gzip.compress(canonical_bytes(claude_session_envelope(raw, session, repo)))
    log = b"".join(json.dumps(item).encode() + b"\n" for item in rows)
    (out / "host-export.json.gz").write_bytes(export)
    (out / "call-log.slice.jsonl").write_bytes(log)

    def ref(name: str, data: bytes) -> dict[str, str]:
        return {"artifact_path": name, "artifact_sha256": "sha256:" + hashlib.sha256(data).hexdigest()}

    receipt = {
        "purpose": "dry_run", "workflow_id": WORKFLOW, "session_id": session, "host": "claude",
        "started_at": iso(-5), "ended_at": iso(5000),
        "acquisition": "claude_local_session_jsonl_v1",
        "row_identity_start": IDENTITY, "row_identity_end": IDENTITY,
        "evidence_refs": {"call_log": ref("call-log.slice.jsonl", log),
                          "host_export": ref("host-export.json.gz", export)},
    }
    (out / "capture-receipt.json").write_text(json.dumps(receipt), encoding="utf-8")
    return out


def _redact(match: re.Match[str]) -> str:
    return f"=<redacted:{len(match[1].encode())}>"


def rehearsal(tmp_path: Path) -> tuple[list[dict[str, Any]], list[tuple[Any, ...]]]:
    """Rows and calls of a rehearsal that ran exactly as the run sheet says."""
    path = str(repo_of(tmp_path) / SCRATCH_FILE)
    rows: list[dict[str, Any]] = []
    calls: list[tuple[Any, ...]] = []
    for number, (name, expected) in enumerate(STEPS):
        start = number * 10.0 + 0.5
        if name == "Bash":
            argv = [NODE if token == SCRATCH else token for token in expected]
            logged = [re.sub(r"=(.+)", _redact, token) for token in argv]
            command = "./scripts/wv " + " ".join(
                token.replace("=", "='", 1) + "'" if "{" in token else token for token in argv)
            rows.append(row(logged, start + 0.5))
            calls.append((start, start + 1.5, command))
        else:
            calls.append((start, start + 1.5, {"name": name, "input": dict(expected, file_path=path)}))
    return rows, calls


def judged(out: Path) -> list[str]:
    """The attribution verdict alone, for cases that are not whole rehearsals."""
    return [problem for problem in check(out) if not problem.startswith("run sheet:")]


def not_issued(problems: list[str]) -> list[str]:
    return [problem for problem in problems if "not issued by the agent" in problem]


def unlogged(problems: list[str]) -> list[str]:
    return [problem for problem in problems if "no agent row logged it" in problem]


def steps(problems: list[str]) -> list[str]:
    return [problem for problem in problems if problem.startswith("run sheet:")]


# A whole rehearsal: the only PASS.

def test_rehearsal_run_as_written_passes(tmp_path: Path) -> None:
    assert check(capture(tmp_path, *rehearsal(tmp_path))) == []


def test_write_content_may_end_with_a_newline(tmp_path: Path) -> None:
    rows, calls = rehearsal(tmp_path)
    calls[2][2]["input"]["content"] = "one\n"
    assert check(capture(tmp_path, rows, calls)) == []


def test_missing_step_fails(tmp_path: Path) -> None:
    rows, calls = rehearsal(tmp_path)
    del calls[1], rows[1]
    assert steps(check(capture(tmp_path, rows, calls)))


def test_extra_non_bash_call_fails(tmp_path: Path) -> None:
    rows, calls = rehearsal(tmp_path)
    calls.append((200.0, 201.0, {"name": "Read", "input": {"file_path": "/etc/hostname"}}))
    assert any("8 tool calls" in problem for problem in check(capture(tmp_path, rows, calls)))


def test_steps_out_of_order_fail(tmp_path: Path) -> None:
    rows, calls = rehearsal(tmp_path)
    calls[2], calls[4] = (calls[2][0], calls[2][1], calls[4][2]), (calls[4][0], calls[4][1], calls[2][2])
    assert len(steps(check(capture(tmp_path, rows, calls)))) == 2


def test_a_step_on_another_node_fails(tmp_path: Path) -> None:
    rows, calls = rehearsal(tmp_path)
    calls[3] = (calls[3][0], calls[3][1], "./scripts/wv show wv-def456 --json")
    rows[2] = row(["show", "wv-def456", "--json"], rows[2]["ts"] - BASE)
    assert any("step 4 ran" in problem for problem in check(capture(tmp_path, rows, calls)))


@pytest.mark.parametrize("change", [
    {"content": "two"},
    {"file_path": "/tmp/elsewhere.txt"},
    {"replace_all": True},
    {"old_string": "one", "new_string": "three"},
])
def test_write_or_edit_with_other_input_fails(tmp_path: Path, change: dict[str, object]) -> None:
    rows, calls = rehearsal(tmp_path)
    step = 2 if "content" in change else 4
    calls[step][2]["input"].update(change)
    assert any(f"step {step + 1}" in problem for problem in check(capture(tmp_path, rows, calls)))


def test_step_by_another_tool_with_the_expected_input_fails(tmp_path: Path) -> None:
    # Only the tool name tells this Edit from the Write the run sheet asks for.
    rows, calls = rehearsal(tmp_path)
    calls[2][2]["name"] = "Edit"
    assert any("step 3 is a 'Edit' call" in problem for problem in check(capture(tmp_path, rows, calls)))


def test_errored_step_fails(tmp_path: Path) -> None:
    rows, calls = rehearsal(tmp_path)
    calls[0] = (*calls[0][:3], REFUSED)
    del rows[0]
    assert any("step 1 (Bash) returned an error" in problem for problem in check(capture(tmp_path, rows, calls)))


def test_run_sheet_prompt_is_the_checked_steps() -> None:
    # Line for line, not by substring: 'containing the line: one' followed by
    # 'then write two' passed a substring check (wv-f28b58).
    sheet = (ROOT / "docs" / "e5-capture" / "s4e-rehearsal.md").read_text(encoding="utf-8")
    prompt = sheet.split("S4e dry-run rehearsal. Do exactly these steps", 1)[1].split("```", 1)[0]
    assert re.findall(r"^\d+\. .*$", prompt, re.MULTILINE) == prompt_lines()


def test_prompt_bash_lines_parse_to_the_checked_argv() -> None:
    for line, (name, expected) in zip(prompt_lines(), STEPS):
        if name == "Bash":
            command = line.split("Run: ", 1)[1].replace(SCRATCH, NODE)
            assert bare_wv_argv(command) == [NODE if token == SCRATCH else token for token in expected], line


# Attribution: agent rows and Bash calls one to one.

def test_agent_rows_matching_bare_bash_commands_pass(tmp_path: Path) -> None:
    out = capture(tmp_path, [
        row(["show", "wv-abc", "--json"], 1.0),
        row(["update", "wv-abc", "--status=<redacted:4>"], 11.0),
        row(["update", "wv-abc", "--metadata=<redacted:21>"], 21.0),
    ], [
        (0.5, 2.0, "./scripts/wv show wv-abc --json"),
        (10.5, 12.0, "./scripts/wv update wv-abc --status=todo"),
        (20.5, 22.0, "./scripts/wv update wv-abc --metadata='{\"rehearsal_probe\":1}'"),
    ])
    assert judged(out) == []


def test_hook_call_inside_agent_interval_tagged_agent_fails(tmp_path: Path) -> None:
    # The claim guard's shape: its wv show runs during the agent's own wv work.
    out = capture(tmp_path, [row(["show", "wv-abc", "--json"], 1.0), row(["work", "wv-abc"], 1.5)],
                  [(0.5, 2.0, "./scripts/wv work wv-abc")])
    problems = not_issued(judged(out))
    assert len(problems) == 1 and "'wv show'" in problems[0]


def test_one_command_accounts_for_one_row(tmp_path: Path) -> None:
    out = capture(tmp_path, [row(["status"], 1.0), row(["status"], 1.2)], [(0.5, 2.0, "./scripts/wv status")])
    assert len(not_issued(judged(out))) == 1


def test_row_outside_the_command_interval_fails(tmp_path: Path) -> None:
    out = capture(tmp_path, [row(["status"], 5.0)], [(0.5, 2.0, "./scripts/wv status")])
    assert len(not_issued(judged(out))) == 1


def test_redacted_length_must_match(tmp_path: Path) -> None:
    out = capture(tmp_path, [row(["update", "wv-abc", "--status=<redacted:5>"], 1.0)],
                  [(0.5, 2.0, "./scripts/wv update wv-abc --status=todo")])
    assert len(not_issued(judged(out))) == 1


@pytest.mark.parametrize("command", [
    "echo ./scripts/wv status",          # mentions wv, executes echo
    "false && ./scripts/wv status",      # never reached
    "./scripts/wv status; ./scripts/wv list",
    "./scripts/wv status | tail -1",
    "./scripts/wv status > /tmp/out",    # redirection changes what ran around it
    "./scripts/wv status 2>/dev/null",
    "FOO=1 ./scripts/wv status",         # env prefix
    "./scripts/wv status\nrm -f x",      # second line
    "(./scripts/wv status)",             # subshell
    "./scripts/wv status $(true)",       # command substitution
])
def test_only_a_single_bare_wv_command_counts(tmp_path: Path, command: str) -> None:
    out = capture(tmp_path, [row(["status"], 1.0)], [(0.5, 2.0, command)])
    assert len(not_issued(judged(out))) == 1, command


def test_grammar_is_linear_on_a_command_it_rejects() -> None:
    # A safe-character run nested in the word repetition backtracks through
    # 2^n parses before rejecting; 24 characters take seconds, the fix microseconds.
    started = time.perf_counter()
    assert bare_wv_argv("./scripts/wv " + "a" * 24 + ";") is None
    assert time.perf_counter() - started < 0.5


def test_expansion_cannot_satisfy_a_redacted_length(tmp_path: Path) -> None:
    # '$STS' is four bytes as text; the shell would have logged its expansion.
    out = capture(tmp_path, [row(["update", "wv-abc", "--status=<redacted:4>"], 1.0)],
                  [(0.5, 2.0, "./scripts/wv update wv-abc --status=$STS")])
    assert len(not_issued(judged(out))) == 1


@pytest.mark.parametrize("command", [
    "wv status",                # whatever PATH resolves: bytes the receipt does not bind
    "scripts/wv status",
    "/tmp/fake/wv status",
    "../wv status",
    "./wv status",
])
def test_only_the_repository_wv_counts(tmp_path: Path, command: str) -> None:
    out = capture(tmp_path, [row(["status"], 1.0)], [(0.5, 2.0, command)])
    assert len(not_issued(judged(out))) == 1, command


@pytest.mark.parametrize("command, argv", [
    ("./scripts/wv show 'line\nbreak'", ["show", "line\nbreak"]),
    ('./scripts/wv show "line\nbreak"', ["show", "line\nbreak"]),
    ("./scripts/wv show 'a\rb'", ["show", "a\rb"]),
])
def test_quoted_line_break_is_rejected(tmp_path: Path, command: str, argv: list[str]) -> None:
    out = capture(tmp_path, [row(argv, 1.0)], [(0.5, 2.0, command)])
    assert len(not_issued(judged(out))) == 1, command


@pytest.mark.parametrize("at", [1.5, 1000.0])
def test_descendant_of_a_matched_row_is_not_accepted_by_ancestry(tmp_path: Path, at: float) -> None:
    out = capture(tmp_path, [
        row(["show", "wv-abc", "--json"], 1.0, call_id="wv-parent"),
        row(["delete", "wv-xyz"], at, parent="wv-parent"),
    ], [(0.5, 2.0, "./scripts/wv show wv-abc --json")])
    problems = not_issued(judged(out))
    assert len(problems) == 1 and "'wv delete'" in problems[0]


def test_host_wv_call_missing_from_the_log_fails(tmp_path: Path) -> None:
    out = capture(tmp_path, [row(["show", "wv-abc", "--json"], 1.0)],
                  [(0.5, 2.0, "./scripts/wv show wv-abc --json"), (10.5, 12.0, "./scripts/wv status")])
    problems = unlogged(judged(out))
    assert len(problems) == 1 and "status" in problems[0]


def test_host_wv_call_logged_as_hook_fails(tmp_path: Path) -> None:
    # Read-only, so the identity chain cannot see it: only the converse can.
    out = capture(tmp_path, [row(["show", "wv-abc", "--json"], 1.0), row(["status"], 11.0, source="hook")],
                  [(0.5, 2.0, "./scripts/wv show wv-abc --json"), (10.5, 12.0, "./scripts/wv status")])
    problems = unlogged(judged(out))
    assert len(problems) == 1 and "logged as hook" in problems[0]


def test_call_refused_by_a_hook_needs_no_row(tmp_path: Path) -> None:
    out = capture(tmp_path, [row(["status"], 11.0)],
                  [(0.5, 2.0, "./scripts/wv work wv-abc", REFUSED), (10.5, 12.0, "./scripts/wv status")])
    assert judged(out) == []


def test_call_that_ran_and_failed_still_needs_its_row(tmp_path: Path) -> None:
    failed = {"is_error": True, "content": "Exit code 1\nPreToolUse:Bash hook error: forged by output"}
    out = capture(tmp_path, [], [(0.5, 2.0, "./scripts/wv work wv-abc", failed)])
    assert len(unlogged(judged(out))) == 1


def test_any_other_bash_call_in_the_window_fails(tmp_path: Path) -> None:
    out = capture(tmp_path, [row(["status"], 1.0)],
                  [(0.5, 2.0, "./scripts/wv status"), (10.5, 12.0, "ls docs")])
    assert any("'ls docs'" in problem and "not one bare" in problem for problem in judged(out))


def test_bash_call_without_a_result_fails(tmp_path: Path) -> None:
    out = capture(tmp_path, [], [(0.5, None, "./scripts/wv status")])
    assert any("has no tool_result" in problem for problem in judged(out))


def test_bash_calls_outside_the_window_are_not_judged(tmp_path: Path) -> None:
    out = capture(tmp_path, [row(["status"], 1.0)], [(-30.0, -20.0, "ls"), (0.5, 2.0, "./scripts/wv status")])
    assert judged(out) == []


@pytest.mark.parametrize("start, end", [(-6.0, -4.0), (4999.0, 5001.0)])
def test_bash_call_crossing_the_window_fails(tmp_path: Path, start: float, end: float) -> None:
    # The window is iso(-5)..iso(5000): a call straddling either edge may have
    # logged its row outside the slice.
    out = capture(tmp_path, [], [(start, end, "./scripts/wv status")])
    assert any("crosses the capture window" in problem for problem in judged(out))


def test_overlapping_wv_calls_fail(tmp_path: Path) -> None:
    # Two parallel calls with the same argv: greedy matching could misassign.
    out = capture(tmp_path, [row(["status"], 1.0), row(["status"], 1.5)],
                  [(0.5, 3.0, "./scripts/wv status"), (0.8, 2.0, "./scripts/wv status")])
    assert any("overlap" in problem for problem in judged(out))


# A malformed host transcript is refused, never read past.

def malformed(problems: list[str], words: str) -> bool:
    return any(problem.startswith("host transcript:") and words in problem for problem in problems)


def test_duplicate_tool_use_id_fails(tmp_path: Path) -> None:
    # Under one id, the wv call used to replace the ls call that came first.
    def reuse_id(events: list[dict[str, Any]]) -> list[dict[str, Any]]:
        events[3]["message"]["content"][0]["id"] = "toolu_0000"
        events[4]["message"]["content"][0]["tool_use_id"] = "toolu_0000"
        return events
    out = capture(tmp_path, [row(["status"], 11.0)],
                  [(0.5, 2.0, "ls docs"), (10.5, 12.0, "./scripts/wv status")], mutate=reuse_id)
    assert malformed(check(out), "repeats tool_use id")


def test_orphan_tool_result_fails(tmp_path: Path) -> None:
    def orphan(events: list[dict[str, Any]]) -> list[dict[str, Any]]:
        events[2]["message"]["content"][0]["tool_use_id"] = "toolu_9999"
        return events
    out = capture(tmp_path, [row(["status"], 1.0)], [(0.5, 2.0, "./scripts/wv status")], mutate=orphan)
    assert malformed(check(out), "answers no earlier tool_use")


def test_second_tool_result_fails(tmp_path: Path) -> None:
    def answer_twice(events: list[dict[str, Any]]) -> list[dict[str, Any]]:
        return events + [dict(events[2], uuid=str(uuid.uuid4()))]
    out = capture(tmp_path, [row(["status"], 1.0)], [(0.5, 2.0, "./scripts/wv status")], mutate=answer_twice)
    assert malformed(check(out), "more than one tool_result")


def test_result_before_its_call_fails(tmp_path: Path) -> None:
    # A refusal that predates its own call is not evidence of anything.
    out = capture(tmp_path, [row(["status"], 11.0)],
                  [(1.5, 0.5, "./scripts/wv work wv-abc", REFUSED), (10.5, 12.0, "./scripts/wv status")])
    assert malformed(check(out), "predates its tool_use")


@pytest.mark.parametrize("key", ["id", "tool_use_id"])
@pytest.mark.parametrize("value", [None, "", 7])
def test_tool_id_that_is_not_a_non_empty_string_fails(tmp_path: Path, key: str, value: object) -> None:
    # Both sides agreeing on a non-id must not pair a call with its result.
    def set_ids(events: list[dict[str, Any]]) -> list[dict[str, Any]]:
        for event in events[1:]:
            block = event["message"]["content"][0]
            if key == "id" or block["type"] == "tool_result":
                block["tool_use_id" if block["type"] == "tool_result" else "id"] = value
        return events
    rows, calls = rehearsal(tmp_path)
    out = capture(tmp_path, rows, calls[:1], mutate=set_ids)
    assert malformed(check(out), "is not a non-empty string")


@pytest.mark.parametrize("flag", ["true", "false", 1, 0])
def test_is_error_that_is_not_a_boolean_fails(tmp_path: Path, flag: object) -> None:
    rows, calls = rehearsal(tmp_path)
    calls[0] = (*calls[0][:3], {"is_error": flag, "content": "ok"})
    assert malformed(check(capture(tmp_path, rows, calls)), "is not a boolean")


def test_is_error_null_reads_as_no_error(tmp_path: Path) -> None:
    # The host writes null for Write and Edit results.
    rows, calls = rehearsal(tmp_path)
    calls[2] = (*calls[2][:3], {"is_error": None, "content": "File created"})
    assert check(capture(tmp_path, rows, calls)) == []


# Provenance and scope.

def test_foreign_workflow_rows_are_listed_not_judged(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    out = capture(tmp_path, [row(["show", "wv-abc", "--json"], 1.0),
                             row(["status"], 1.5, workflow="")],
                  [(0.5, 2.0, "./scripts/wv show wv-abc --json")])
    assert judged(out) == []
    assert "foreign rows" in capsys.readouterr().out


def test_wv_hook_tagged_agent_fails(tmp_path: Path) -> None:
    out = capture(tmp_path, [row(["hook", "dispatch"], 1.0)], [(0.5, 2.0, "./scripts/wv hook dispatch")])
    assert any("'wv hook' tagged 'agent'" in problem for problem in check(out))


@pytest.mark.parametrize("artifact", ["call-log.slice.jsonl", "host-export.json.gz"])
def test_artifact_not_matching_receipt_digest_fails(tmp_path: Path, artifact: str) -> None:
    out = capture(tmp_path, *rehearsal(tmp_path))
    path = out / artifact
    path.write_bytes(path.read_bytes() + b"\n")
    assert any("artifact_sha256 must match" in problem for problem in check(out))
