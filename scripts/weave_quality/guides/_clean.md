---
id: _clean
violation_type: _presentation
summary: Rendered when analysis completed and no accepted defect is in scope.
---

## Why

Every active rule produced a successful receipt matching its current definition, and no occurrence
in scope carries an `accepted_defect` disposition. That is a real result, and it is narrow: these
rules check structure and prose habits. They do not check whether the code is correct, whether the
design holds, or whether the change does what it claims.

## Corrective move

Treat this as one green light among several. If nothing else has reviewed this change set — a test
run, a reader, a review pass — a clean pattern scan is not a substitute for one.

## Expected outcome

You know that the rules that ran, ran completely, and found nothing accepted. You do not know more
than that.
