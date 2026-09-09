---
id: register
violation_type: prose:register
summary: Register inappropriate to the document's audience.
---

## Why

A durable document is read cold by someone who was not there. The constructions this type catches
all belong to a different setting: the causal `so` that carries a clause is how a person reasons
aloud in conversation, a gambling metaphor turns a measured uncertainty into a wager, a superlative
asserts a ranking the text never establishes, and a sentence recounting what a previous
run reported tells the reader a fact that is no longer true before the one that is. Each reads as
the author narrating deliberation rather than stating a current value. The reader wants the value.

## Corrective move

State the thing that is true now, in the shortest form that survives being quoted on its own.

Clause-level causal `so` usually marks two sentences fused into one. Split them and let the second
stand: the consequence is normally the sentence worth keeping. Where the causal link is the claim,
name the mechanism instead of gesturing at it, and prefer `because` in front of the cause
over `so` in front of the effect. The `so that` form is purpose rather than register and is fine.

Replace a wager with the quantity you have: a probability, a measured rate, a bounded
range, or a plain statement that the value is unknown. Replace a superlative with the criterion and
the number that ranks it. Where no measurement exists, say that no measurement exists.

Delete the archaeology. If a prior reading was wrong, the current document carries the current value
and nothing else; the correction belongs in the change history, the graph node, or the commit
message, all of which are dated and none of which the cold reader must parse first.

## Expected outcome

Every sentence asserts something checkable about the present state. A reader who opens the document
at a random heading gets a fact rather than a stage in someone's reasoning, and no sentence has to
be read twice to work out whether it describes what is true or what used to be.

## Avoid

Swapping the connective and keeping the register. `, hence`, `, thus` and `, and therefore` carry
the same conversational clause the rule is pointing at, and they clear the matcher without changing
what the reader gets. The same trap applies to moving a superlative out of a sentence and into a
heading, where it makes a larger claim with less support.

Deleting a load-bearing causal explanation to satisfy the rule is the opposite failure. Where the
mechanism is the content, keep it and write it as a mechanism.
