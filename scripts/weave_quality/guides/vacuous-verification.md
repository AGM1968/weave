---
id: vacuous-verification
violation_type: code:vacuous-verification
summary: A check that exists and reads as coverage but cannot fail on the defect it names.
---

## Why

A missing check is visible: someone reading the code can see nothing guards the path. A check that
cannot fail is worse. It appears in the suite, it passes, and it tells every reader the path is
covered. The usual shapes are a guard that is trivially true in the failure case (a tag-equals-HEAD
test when nothing was committed), a failure that is survivable where it matters (warn and continue
on the one commit the release depends on), a test that asserts behaviour the bug itself produced, a
matcher that silently misses a variant of what it matches, and a suite that exercises an installed
copy while the change sits in source.

## Corrective move

Watch the check fail against the defect before trusting it. Put the defect back: revert the fix,
plant a mutant on the guarded line, or install a decoy copy that announces itself. Then confirm the
check fails, and fails for the reason it names. If it still passes, find what it observes instead.
A guard that is true when the operation it guards did nothing needs the precondition that makes it
mean something. A step whose failure the caller survives needs to stop the caller. A test needs to
assert on the whole value that decides the outcome, such as the full argument vector rather than the
subcommand, or the parsed structure rather than a line prefix. A suite needs to run the copy under
test, which means resolving the code beside it before any installed one.

## Expected outcome

Every check on the path has been seen failing against the defect it claims to catch, and a reader
can say which input makes it fail.

## Avoid

Making the check fail once on a toy input while the guarded path stays unobserved, or adding an
assertion that passes after the fix and was never run against the broken code. An equality test
between source and an installed copy passes as soon as the installer catches up and proves nothing
about which copy ran. The test is not whether the check can fail somewhere; it is whether it fails
on this defect, on this path.
