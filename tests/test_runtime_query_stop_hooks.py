"""Focused tests for query stop-hook orchestration."""
from __future__ import annotations

from runtime.hooks import ReviewEvidenceHook
from runtime.query import StopHooks
from runtime.types import Message, Response, StopReason, Usage


def _end_turn(text: str = "Done.") -> Response:
    return Response(
        content=text,
        tool_calls=[],
        stop_reason=StopReason.END_TURN,
        usage=Usage(input_tokens=1, output_tokens=1),
    )


def test_stop_hooks_inject_redirect_message() -> None:
    """StopHooks owns before-answer redirect injection."""
    hook = ReviewEvidenceHook()
    hook.on_prompt("review the runtime code")
    stop_hooks = StopHooks([hook])
    messages = [Message(role="user", content="review the runtime code")]

    outcome = stop_hooks.apply_before_answer_redirect(messages)

    assert outcome.redirect_message is not None
    assert messages[-1].role == "user"
    assert "Before finalising this review" in str(messages[-1].content)


def test_stop_hooks_do_nothing_after_evidence() -> None:
    """Evidence-backed review prompts should not redirect."""
    hook = ReviewEvidenceHook()
    hook.on_prompt("review the runtime code")
    hook.before_tool("read", {"path": "runtime/agent.py"})
    stop_hooks = StopHooks([hook])
    messages = [Message(role="user", content="review the runtime code")]

    outcome = stop_hooks.apply_before_answer_redirect(messages)

    assert outcome.redirect_message is None
    assert len(messages) == 1


def test_post_turn_triggers_are_noop_for_now() -> None:
    """The post-turn trigger seam is behavior-safe until later tasks implement it."""
    stop_hooks = StopHooks([])
    messages = [Message(role="user", content="task")]

    stop_hooks.run_post_turn_triggers(
        response=_end_turn("Done."),
        messages=messages,
        turn_number=1,
    )

    assert len(messages) == 1
