---
id: swallowed-exception
violation_type: code:swallowed-exception
language: python
summary: Project override — this repository logs through structlog, not logging.
---

## Why

A broad `except` that discards the error hides a failure nobody has named. In this repository the
cost is sharper: the worker loops retry silently, so a swallowed error becomes a job that never
completes and never complains.

## Corrective move

Catch the error you can name. At a loop boundary, record it with `log.exception(event=...)` and
continue; anywhere else, add context and re-raise with `raise ... from err`.

## Expected outcome

Every retry that gives up leaves one structured event carrying the original traceback.

## Avoid

Swapping the bare `except` for `except Exception` and calling it narrowed.
