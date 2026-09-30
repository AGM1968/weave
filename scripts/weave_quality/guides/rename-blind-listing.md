---
id: rename-blind-listing
violation_type: code:rename-blind-listing
summary: A path listing that follows renames drops the old path where the old path decides the outcome.
---

## Why

Porcelain `git diff`, `git log` and `git show` detect renames by default. A renamed file then
appears once, under its new path, and a `--diff-filter` of added or modified paths drops it
altogether. Where the listing only feeds a display that is harmless. Where the old path decides
something, it is a silent hole: a gate routes suites by path and never selects the ones the old
path owes, a CI marker sees a range as metadata-only when a source file moved into the metadata
directory, and a hash binding never notices that its pinned file left.

## Corrective move

Ask what the listing decides. If the old path matters to that decision (test routing, evidence
pinning, lint selection, a skip-CI verdict), add `--no-renames`: the rename then appears as a
deletion of the old path and an addition of the new one, and each side reaches the logic that needs
it. Prove it with a fixture that sets `diff.renames=true`, runs `git mv` on a file the old path
routes, and fails on the unfixed listing.

## Expected outcome

Every listing whose paths decide an outcome sees both sides of a rename, and each remaining
rename-following listing has a recorded reason.

## Avoid

Adding `--no-renames` everywhere to clear the rule. Churn metrics, history views and file
attribution want renames followed: splitting a rename into a deletion and an addition there
inflates churn and breaks the file's history. Disposition those findings with the reason instead. A
listing that only tests for emptiness is also unaffected, because a rename is non-empty either way.
