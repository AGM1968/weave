"""Focused tests for shared runtime session export shaping."""
from __future__ import annotations

from pathlib import Path

from runtime.services.session_export import content_text, render_html_export, render_text_export
from runtime.session import Session
from runtime.types import Message, ToolCall, ToolResult


def test_content_text_flattens_tool_results() -> None:
    result = content_text([
        ToolResult(id="tc1", content="first"),
        {"content": "second"},
        "third",
    ])
    assert "first" in result
    assert "second" in result
    assert "third" in result


def test_render_html_export_includes_branch_tips(tmp_path: Path) -> None:
    session = Session.new(tmp_path)
    root = session.append(Message(role="user", content="root"), turn=0)
    session.append(
        Message(
            role="assistant",
            content="branch-a",
            tool_calls=[ToolCall(id="tc1", name="wv_status", input={})],
        ),
        turn=1,
    )
    session.fork(root.id)
    session.append(Message(role="assistant", content="branch-b"), turn=2)

    html = render_html_export(
        session=session,
        messages=session.messages,
        total_tokens=123,
        total_cost=0.0456,
    )

    assert "Append-only Log" in html
    assert "Branch Tips" in html
    assert "branch-a" in html and "branch-b" in html
    assert "123 tokens" in html
    assert "$0.0456" in html


def test_render_text_export_includes_append_log(tmp_path: Path) -> None:
    session = Session.new(tmp_path)
    session.append(Message(role="user", content="root"), turn=0)
    session.append(Message(role="assistant", content="reply"), turn=1)

    text = render_text_export(session=session, messages=session.messages)

    assert "Weave Session Transcript" in text
    assert "Append-only log:" in text
    assert "Active branch transcript:" in text
    assert "assistant: reply" in text
