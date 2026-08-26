---
id: swallowed-exception
violation_type: code:swallowed-exception
summary: A catch-all that discards the error hides a failure nobody has named.
---

## Why

A handler that catches broadly and discards what it caught is not handling a failure you planned
for; it is hiding one you have not understood yet. The cost is paid later, by whoever is looking at
a system that is behaving wrongly and silently. If you can name the error you expect here and say
why it is safe to continue, that sentence is usually the fix.

## Corrective move

Catch only what you can name. If you cannot name the error the call actually raises, you are
guessing, and everything you did not think of should stay free to surface where someone can see it.
Then make the decision visible: recover from it, add context and re-raise it, or — at a boundary
that has to stay alive, such as a request handler, a worker loop, or a CLI entry point — log the
full trace and continue. Logging and returning a default is a legitimate choice when it is a choice.

## Expected outcome

Every remaining catch names a specific error and does something a reader can follow. If this fires
at three in the morning, someone will know it happened and know why.

## Avoid

Narrowing the exception type or adding a suppression comment purely to quiet the checker while the
error is still discarded. That clears the report and keeps the blind spot. The test is not whether
you re-raised — it is whether the failure leaves a trace.
