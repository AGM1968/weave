---
id: swallowed-exception
violation_type: code:swallowed-exception
language: python
summary: A broad except that discards the error hides a failure nobody has named.
---

## Why

A bare `except:`, `except Exception:`, or `except BaseException:` whose body discards the error is
hiding a failure you have not understood, not handling one you planned for. Before writing it, name
the error you expect and why continuing is safe. That sentence is usually the fix.

## Corrective move

Catch what you can name: `ValueError`, `KeyError`, `TimeoutError`, whatever the call really raises.
Then make the decision visible — recover, add context and re-raise with `raise ... from err`, or, at
a boundary that must stay alive, record the traceback with `logging.exception(...)` and continue.
Returning a default after logging is a real option; returning one silently is not.

## Expected outcome

Each remaining `except` names its error and leaves a trace. Errors nobody anticipated propagate to
where they can be seen instead of disappearing into a `pass`.

## Avoid

Narrowing the type or adding `# noqa` only to satisfy ruff while the error is still discarded. Also
avoid `except Exception: logging.debug(...)`, which is a swallow wearing a log call — a message
nobody reads at a level nobody enables is the same silence.
