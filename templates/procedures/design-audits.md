---
id: design-audits
description:
  "Five audits to run on a change before committing it: three outcomes, a new dimension reaching
  every check, one fact stated once, the mechanism removed rather than guarded, and the adjacent
  defect classes. Use when a change decides something, adds a mode or field, changes a computed
  fact, or closes off an action the system is not allowed to take."
fallback: "wv guide --procedure=design-audits"
adapters: [codex, copilot]
visibility: shared
status: ready
---

# Design Audits

`verify-before-fixed` asks whether a check established anything. These audits ask whether the design
is complete before the check is written. Each one names a trigger in the change. Run only those
whose trigger the diff meets. Record the output on the node (`--learning` or the evidence of
`wv done`).

## 1. Three outcomes

**Trigger:** the change decides something: a gate, a health check, a lookup, a comparison, a
monitor, a judge.

A decision has three outcomes: pass, fail and inconclusive. Absence of data supports neither pass
nor fail. A read that returns nothing, returns empty or errors must refuse (exit non-zero, report
inconclusive, or leave a record an operator will see). It must not fall back to a default a reader
will trust. A measured zero and "no sample" must stay distinguishable: count the samples apart from
the aggregate.

For every read in the diff, ask what the person reading the result is shown when the read returns
nothing, and whether they can distinguish it from a measured value. The reflex on a timeout or an
error is a fallback that continues; the usual right answer is to fail and let the caller retry. The
judge panel is built this way: a Choice always names an option. It counts only when a Noul agrees
and both option orders agree. Otherwise the verdict is `inconclusive`.

## 2. A new dimension reaches every check

**Trigger:** the change adds a mode, a flag, a scope, a field key or a lifecycle state to data that
already has checks on it.

List every existing enforcement point on that data first: uniqueness constraints, "is there one
already" guards, conflict detection, retry and repair paths, exports. Then carry the new dimension
into each of them. When only the new code path learns the dimension, the existing checks keep
applying the old rules to it, and each review round turns up one more check that was missed.

Example: `claimed_by` and `risk_level` became patch keys that write the `metadata` column. Collision
detection was taught to group by column. Lost-write detection still groups by key. A `metadata`
replace forking with a `claimed_by` patch is lost with no report (wv-cf6f29).

## 3. One fact, stated once

**Trigger:** the change alters a computed fact: a count, a status rule, an eligibility test, a
label, a path or a default.

Write the fact as one sentence. Search for it wherever it could be written down (`wv search --code`,
`rg`, the docs and procedures) and list the sites. More than one site means the design merges them
into a single source of truth; updating each copy is a workaround, not the design. For every new
count or ratio, say which set each side ranges over: a denominator drawn from a different set than
its numerator produces a permanent false alarm.

## 4. Remove the mechanism, not guard the path

**Trigger:** the change closes off an action the system is not allowed to take.

The test is about a future caller. After the fix, could someone who never read this node add code
that takes the forbidden action again? If they could, the fix guards one path. Prefer, in order:

1. the action cannot be expressed (no command, field or argument for it);
2. every caller goes through one shared entry point that enforces it;
3. a database constraint or trigger refuses it;
4. a check at the call site.

If the fix is rung 4, say so in the commit and file the follow-up node. Example of rung 2: every
commit Weave makes on its own passes one predicate, `wv_auto_commit_enabled` (wv-fbbdff). A new
committing path inherits the hold without knowing about it.

## 5. Adjacent defect classes

**Trigger:** every change that adds code, before it is committed.

Two questions, in both directions:

- **Outward:** for every fact the diff asserts, find its other statements and check that they match.
  A fix can close its own defect completely and still add a new member of some other class.
- **Inward:** for each guard the change relies on (a suite, a lint rule, a hook, a constraint), was
  it opened and read? A guard whose trigger excludes this case cannot fail, and a gate's silence is
  not evidence. Check that the suite you expect ran, in the gate's environment.

Keep the classes a closed, named list rather than re-deriving them per change. In this workflow the
list is the detectors under `wv quality patterns` plus open finding nodes; a finding that maps to no
class becomes a new detector or finding, not a private note.

## Before committing

Answer these against the diff:

- Run it twice, or two copies at once: what changes?
- When a read returns nothing or errors, which value reaches the reader?
- Which test goes red if this line is broken on purpose? Was that checked or assumed?
- Which fact did this change establish, and where was it already written down?
- Which assumption, if wrong, breaks it, and was it verified against the code, the graph or the
  machine rather than a node's text?
