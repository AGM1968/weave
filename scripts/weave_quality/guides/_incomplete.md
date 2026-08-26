---
id: _incomplete
violation_type: _presentation
summary: Rendered when analysis did not complete, so no clean result can be trusted.
---

## Why

At least one active rule has no successful receipt, failed during the last scan, or has a receipt
that predates its current definition. Findings from the rules that did complete are still shown and
still real, but the result as a whole is incomplete: an absence of findings here is an absence of
evidence, not evidence of absence.

## Corrective move

Read the listed causes. Each names the rule and why its evidence is missing, failed, or stale. Fix
the rule or its tooling, then re-run the scan named in the remedy to obtain a trustworthy snapshot.

## Expected outcome

Either every active rule reports a successful receipt matching its current definition, or the result
keeps saying it is incomplete.

## Avoid

Reading the shown findings as the whole picture, promoting from this snapshot, or configuring the
failing rule away to turn the result green. A rule silenced because it was broken is the same blind
spot with a quieter name.
