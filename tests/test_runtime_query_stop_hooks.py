"""Focused tests for query stop-hook orchestration."""
from __future__ import annotations

from runtime.hooks import OpenNodeHook, ReviewEvidenceHook
from runtime.query import StopHooks
from runtime.types import Message, Response, StopReason, ToolCall, ToolResult, Usage


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


def test_stop_hooks_stop_after_successful_close_when_no_nodes_remain() -> None:
    """A successful close-only tool batch should terminate the turn loop."""
    hook = OpenNodeHook()
    hook.on_prompt("close the node")
    hook.seed_active_nodes(["wv-abcd"])
    hook.after_tool("wv_done", {"node_id": "wv-abcd"}, '{"id":"wv-abcd"}', False)
    stop_hooks = StopHooks([hook])

    should_stop = stop_hooks.should_stop_after_tool_turn(
        [ToolCall(id="1", name="wv_done", input={"node_id": "wv-abcd"})],
        [ToolResult(id="1", content='{"id":"wv-abcd"}', is_error=False)],
    )

    assert should_stop is True


def test_stop_hooks_do_not_stop_after_failed_close() -> None:
    """Errored close batches should keep the loop running."""
    hook = OpenNodeHook()
    hook.on_prompt("close the node")
    hook.seed_active_nodes(["wv-abcd"])
    stop_hooks = StopHooks([hook])

    should_stop = stop_hooks.should_stop_after_tool_turn(
        [ToolCall(id="1", name="wv_done", input={"node_id": "wv-abcd"})],
        [ToolResult(id="1", content="error", is_error=True)],
    )

    assert should_stop is False
