---
id: design-flaw
violation_type: design:flaw
summary: A component relies on a guarantee the system it runs in does not provide.
---

## Why

The findings filed under this type share one shape: a design assumes something about its
surroundings that is not true. A hook reads a field the host never sends. A version number that is
meant to increase can repeat within one second. A hash that is meant to be stable differs between
two versions of the same tool. A specification leaves an input unbounded and lets it reach a remote
command. None of these fails in the case the author tested, which is why they survive review: the
failure belongs to the gap between the assumed guarantee and the one the system provides.

## Corrective move

Write the assumption down as a checkable statement: which component guarantees what, under which
conditions. Then check it against the running component, not a fixture written from the same
assumption: capture what the host sends, run the operation twice in one second, compute the hash on
both tool versions. Fix the design where the guarantee is missing, either by depending on something
that does hold or by making the component hold it itself. Add a test that fails when the assumption
is false, and look for other places that rely on the same assumption, since the same belief usually
appears more than once.

## Expected outcome

Every guarantee the design depends on is named, observed in the running system, and covered by a
test that would fail if it stopped holding. The finding's class is closed, not only its first
instance.

## Avoid

Patching the one symptom that surfaced, such as a special case for the field name the host happens
to use today, while the design still assumes the guarantee elsewhere. Avoid also a fixture that
encodes the assumption: a test written from the belief cannot detect that the belief is wrong.
