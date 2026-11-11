---
id: verify-before-fixed
description:
  "Establish that a fix holds before calling it fixed: reproduce the cause, show the test failing
  without the fix, and check the failures are the expected ones. Use when closing any defect."
fallback: "wv guide --procedure=verify-before-fixed"
adapters: [claude, codex, copilot]
visibility: shared
status: ready
claude_skill: wv-verify-before-fixed
---

# Verify Before Fixed

This is the companion to recording evidence at all: that decides WHICH check to run, this decides
whether the check established anything. A green test proves the code and the test agree. It does not
prove either one is right. Every false-pass below was observed in a single day's work on this
repository, and in each case the fix looked correct, the suite was green, and the verification
established nothing.

## The two questions

Answer both, in order, before closing.

**1. Did I diagnose the cause, or silence the symptom?**

A report is evidence that something is wrong, not a specification of what. The fix that makes the
complaint stop is not always the fix that makes the defect stop.

The test that tells them apart: _state the mechanism in one sentence, then say what you would expect
to observe if that mechanism were the cause._ If you cannot name an observation that would
distinguish your explanation from a competing one, you have not diagnosed anything, and the close
should record the symptom as addressed and the cause as open.

Two of the six defects closed under `wv-5c92d1` produce the reported symptom and are still not the
reported cause. Recording that is not a failure to finish; claiming otherwise would have closed the
epic's open question on a shape match.

**2. Have I shown the test failing without the fix?**

Run the suite against the unfixed code. This is the whole of the discipline, and it is not optional,
because a test written after a fix is written to agree with it.

Run it in a scratch copy of the repository, never by swapping files in the working tree: two
overlapping swaps lost an edit, and a swap interrupted midway leaves the tree on the unfixed code.

```bash
# the fix is uncommitted: the copy takes <file> from HEAD, the rest from the working tree
scripts/variant-run.sh --replace=<file>=@HEAD:<file> -- bash tests/<suite>.sh   # expect failures
# the fix is committed: take <file> from the commit before it
scripts/variant-run.sh --replace=<file>=@<fix>~1:<file> -- bash tests/<suite>.sh
# a repository without the helper: a clone at HEAD holds the unfixed code; copy the new test in
d=$(mktemp -d) && git clone -q --shared . "$d" && cp tests/<suite>.sh "$d/tests/" \
  && (cd "$d" && bash tests/<suite>.sh); rm -rf "$d"
```

Never `git stash` for this (it pops unrelated work), and do not install the unfixed copy: check the
suite runs the copy's own code, not an installed one.

Then check three things about the failure, not just that there was one:

- **Did the revert take?** `grep -c` the removed symbol. A `sed` whose pattern contained `||` while
  `|` was the delimiter edited nothing, and the suite passed against unmodified code.
- **Are the failures the ones you expected?** Not more, not fewer, and not different ones.
- **Do the baseline assertions still pass?** A suite that fails entirely is not discriminating, it
  is broken. The signal is _which_ assertions flip.

## Steps the failure hid

When the fix ends a failure that went on for a long time, the steps after the failure point have not
run since it began. Fixing it runs them again, untested. Before closing:

1. List every step that runs after the point where it failed.
2. Run each one unstubbed, under adverse conditions: an unreachable remote, the host's time budget,
   a cold cache, a missing credential.
3. Fix what breaks before closing, or record it as a finding that blocks the close.

Example (wv-a32e69): the session-end routine was killed by a 1.5 s host budget on every exit for
eight months, and its tests ran a stub. Raising the budget meant the later steps would run again.
Listing them showed the local sync's auto-checkpoint pull, which against an unreachable remote took
33 s (five retries with backoff), past the new 30 s budget. Without the list, the fix would have
traded one silent kill for another.

## False passes to check for by name

| Shape                | What it looks like                                                                                                                                                                                               |
| -------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Unanchored match     | `grep -q "0/100"` also matches `100/100`: the assertion passed against the output it existed to reject                                                                                                        |
| Vacuous assertion    | The string being searched for lives in a layer the test never drives; its absence proves nothing                                                                                                              |
| Inert fixture        | The injected state does not trigger the path: a reversed column order does not break an `UPDATE`, which ignores column order                                                                                     |
| Self-healing path    | The defect repairs itself before the assertion looks, because the entry point runs the repair twice; drive the unit directly                                                                                     |
| Shared mutable state | One case's repair satisfies the next case's precondition; restore a pristine fixture per case                                                                                                                    |
| Wrong target         | An exported `WV_HOT_ZONE` owned by another repository once made the assertions run silently against the live graph; `wv` now refuses it (wv-5e804e); a suite that fails this way has the wrong cwd or exports |
| Environment artifact | A verdict manufactured by the caller's environment, in either direction: a leaked `WV_AUTO_CHECKPOINT=0` failed five checkpoint tests that pass under `env -u`                                                   |
| Stale analyzer       | `wv quality functions` reads a persisted scan; line ranges that disagree with the file mean the numbers predate the edit                                                                                         |
| Declared digest      | A hash written rather than derived from bytes verifies only that it was copied consistently                                                                                                                      |
| Equal fixture        | Two quantities that could diverge are set equal in the fixture: a test reading the wrong one still passes; make them deliberately unequal                                                                        |
| Encoded defect       | An existing test expects the buggy value and blocks the fix; changing that test belongs to the fix, and the commit message says which test changed                                                               |
| Unpinned input       | A clock, a random id or a file order varies between runs: the test passes or fails by chance; pin it in the fixture                                                                                              |

## Assertion hygiene

- Compare on a normalised value. `grep -c PATTERN || echo 0` emits **two** zeros, because `grep -c`
  prints `0` and exits 1, and the fallback appends a second line.
- Never assert on ANSI colour in captured output: colour is blanked when the stream is not a
  terminal, and the result then depends on how the suite was invoked. Assert on the marker.
- A pipe rewrites the exit status in both directions. `$?` after `tail` hides a failure, and an
  early-exiting reader invents one under `pipefail`. Read the suite's own summary line.
- Pin the contract shape-blind. A structural check that recognises only the _good_ forms skips a bad
  new call site instead of failing on it.
- Check what changed, not that the call happened. A test that checks only that the call returned, or
  that some row appeared, proves nothing: check every field a correct fix alters, and every field it
  should leave untouched.
- To show a test can fail, break the implementation by one line in the scratch copy, watch the test
  fail, and check that the failure points at that line. Deleting or renaming a file to make a test
  fail proves nothing: a missing file fails every test alike.

`design-audits` holds the checks to run on a design before the tests are written.

## Closing

`wv done --verification-method=` and `--verification-evidence=` are the record. Put the inverted
result in the evidence, with counts: _"14/14, and 4 of 14 fail with the fix reverted"_ is evidence.
_"tests pass"_ is not.

If part of the scope is unverified, say which part. An advisory left standing with a reason is worth
more than a marker forced green.
