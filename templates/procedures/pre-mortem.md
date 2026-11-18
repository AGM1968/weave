---
id: pre-mortem
description:
  "Assesses failure scenarios and risk before significant tasks, then reorders implementation to
  address high-risk items first. Use when planning non-trivial or high-impact work."
fallback: "wv guide --procedure=pre-mortem"
adapters: [claude, codex, copilot]
visibility: shared
status: ready
claude_skill: pre-mortem
---

# Pre-Mortem

Prospective hindsight before a risky claim: assume the task has already failed, work backward to
what went wrong, and record the risks on the node so the next agent inherits them.

Run it when claiming a feature or epic, and for any task touching authentication or authorization,
payments, database migrations, infrastructure, large refactors, third-party integrations, or user
data. The pre-claim hook reports a missing assessment as an advisory; it does not run this procedure
for you.

## Steps

1. **Imagine failure.** "One week from now this task has failed badly. What went wrong?" Write 3-5
   scenarios across technical (breaks existing behaviour), integration, scope (takes ten times
   longer), data (corruption, loss, inconsistency) and security failures.
2. **Assess each scenario.**

   | Factor        | Scale                    | Question                          |
   | ------------- | ------------------------ | --------------------------------- |
   | impact        | low/medium/high/critical | How bad if it happens?            |
   | likelihood    | low/medium/high          | How likely is it?                 |
   | detectability | easy/medium/hard         | Will it be noticed before damage? |

   Priority is impact times likelihood; a high-high scenario is on the critical path.

3. **Define mitigations** for the high-priority scenarios: prevention, detection (a tripwire, the
   earliest observable sign), and recovery.
4. **Identify the blast radius**: files and modules touched, users and services affected, data at
   risk, downstream dependencies. `wv impact <id>` gives the graph coupling.
5. **Write the rollback plan** before changing anything: how to return to a working state, what is
   backed up, who must be told.
6. **Reorder the work** so the highest-risk items are done and verified first.
7. **Record it on the node** (`--metadata` merges):

   ```bash
   wv update <id> --metadata='{
     "risks": [
       {
         "scenario": "Database migration corrupts user data",
         "impact": "critical",
         "likelihood": "medium",
         "detectability": "hard",
         "mitigation": "Back up before migrating; rehearse on a copy first",
         "tripwire": "Row count differs after migration"
       }
     ],
     "blast_radius": ["users table", "auth service"],
     "rollback_plan": "Restore from the pre-migration backup",
     "pre_checks": ["Backup verified restorable"],
     "risk_level": "high"
   }'
   ```

## Risk level

`risk_level` is a node field whose values are defined in one place,
`contracts/node-field-registry-v1.json` (`fields.risk_level.value.enum`). This procedure does not
repeat them: `wv add --help` prints the current set, and `wv` refuses any other value and names the
valid ones. A scenario's `impact` may be `critical`, but that is the scenario's own field; the
node's `risk_level` is then the highest level the contract admits. Use `--risks=<level>` on `wv add`
to set it at creation.

`wv discover <id> --json` reads `risks` back as known unknowns; the next agent inherits them there.

## Report shape

```text
Task: wv-a1b2 - Migrate user sessions to a new store
Scenarios:
  1. [critical/medium] Session data lost during migration
     mitigation: export sessions first, verify counts after; tripwire: count drops >5%
  2. [high/low] Store connection failures under load
     mitigation: connection pooling, fallback to the old store; tripwire: timeout errors
Blast radius: auth service, API gateway, active users
Rollback: revert config to the old store; sessions are recreated on next login
Decision: proceed | reduce scope | defer | escalate
```

## Decision

- **Proceed**: risks are acceptable and mitigated.
- **Reduce scope**: too risky as stated; simplify.
- **Defer**: more information or preparation is needed first.
- **Escalate**: risk acceptance is the owner's call; record the question on the node.

## Rules

- Never skip the assessment for a "simple" change to shared infrastructure.
- Never start implementation without a rollback plan.
- Never ignore a critical-impact scenario because its likelihood is only medium.
- "It worked in dev" is not evidence for production.
- Always name at least one tripwire.

Pairs with `wv guide --procedure=verify-before-fixed` (prove the mitigations held) and
`wv guide --procedure=blindspot-pass` (probe the assumptions behind each risk).
