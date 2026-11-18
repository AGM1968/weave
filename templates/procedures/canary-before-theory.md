---
id: canary-before-theory
description:
  "Test a theory in a throwaway canary before reasoning further from code: a fresh load or run in a
  scratch clone at the suspect, the last good and the current commit. Use when a graph, replay, gate
  or tooling symptom has more than one plausible cause."
fallback: "wv guide --procedure=canary-before-theory"
adapters: [claude, codex, copilot]
visibility: shared
status: ready
claude_skill: wv-canary-before-theory
---

# Canary Before Theory

A theory that has not been run is a hypothesis, however well the code reads. Reading code is the
second step: the first is a cheap, disposable experiment whose outcome would differ if the theory
were wrong. In one incident, six experiments of a few minutes each found the cause, and two
plausible theories that took far longer to reason about each fell to a single run.

## The probe

For a symptom in the graph or its tooling (a load that is not acknowledged, a node that vanished or
came back, a gate that refuses or passes unexpectedly):

1. Clone the repository into a scratch directory and give the clone its own hot zone and config
   directory; nothing then reads or writes the live graph:
   `git clone --shared --no-checkout . <scratch>/r && git -C <scratch>/r checkout --detach <rev>`,
   then run `wv load` (or the failing command) there with `WV_HOT_ZONE`, `WV_DB` and
   `WV_CONFIG_DIR` pointing inside `<scratch>`.
2. Run it at three revisions first: the current one, the last known good one, and the suspect one
   (a merge, a sync, a release). One run that fails at the last known good revision settles "did
   this change cause it" before any code is read.
3. Bisect with the same probe when the boundary is unknown, then confirm both sides of the boundary
   by hand: the parent passes, the commit fails.
4. Only then read the code at the boundary, and reproduce the mechanism in a fixture small enough
   to become the regression test.

## Validity rules for a canary

- **Clean up every run.** Delete each clone as soon as its result is read. Clones of a large graph
  repository fill a tmpfs quickly, and the live hot zone usually lives on the same tmpfs.
- **Match the environment it stands in for.** A scratch path longer than the checkout's own moved a
  bisect boundary once: the clones reached a command-line length limit the checkout itself had not
  reached yet. Keep paths, users and variables comparable, and re-confirm a boundary after any
  environmental surprise.
- **Change one thing.** Do not export switches into a command whose result you will trust (for
  example `WV_AUTO_CHECKPOINT=0 git commit`): the gate's suites inherit them.
- **Never swap files in the working tree** to run the unfixed code. Use a scratch copy, as
  `verify-before-fixed` says; a swap interrupted midway leaves the tree on the wrong code.
- **Read evidence through the owning tool** where one exists (`wv hotzone diff`, `wv load` output,
  `git log -S`), and keep anything the canary finds, such as a commit or a hot zone, until the
  finding is recorded.

## Claims count too

A statement to another agent or to the owner about how the system behaves ("a commit lock prevents
this", "the merge caused it") is a theory as well. Run the two-minute canary before asserting it, or
mark it as unverified.
