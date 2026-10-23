---
id: work-context-leakage
violation_type: prose:work-context-leakage
summary: The document narrates the session or conversation that produced it.
---

## Why

A durable document is read later, by someone who was not in the conversation that wrote it. Phrases
that refer to that conversation (`as discussed`, `let me know if`, `in this session`) or announce a
change relative to it (`we now have`, `this is now resolved`) assume a shared before and after the
reader does not have. They also go stale: the next edit makes `now` wrong, and the reader cannot
tell which statements describe the present.

## Corrective move

Describe the work product as it is. State the current behaviour, value or decision without reference
to when or how it came about. Where the history is needed, put it where history belongs: the commit
message, the changelog entry, or the graph node, all of which carry a date. If a document needs a
status line, give it a date and a fact rather than a narrative.

## Expected outcome

A reader opening the document at any point gets statements that are true of the current state, with
no references to a conversation or a moment they cannot see.

## Avoid

Rephrasing the narration so it no longer matches (`following the earlier review`) while keeping the
before-and-after framing. The fix is to state the current fact, not to reword the reference to the
past.
