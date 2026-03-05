---
name: pre-mortem
description: "Assesses failure scenarios and risk before significant tasks, then reorders implementation to address high-risk items first. Use when planning non-trivial or high-impact work."
---

# Pre-Mortem — Risk Assessment Gate

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator. Use `/weave` instead
> for the full graph-first workflow. Direct invocation is deprecated and may be removed in a future
> release.

**Trigger:** When claiming a feature, epic, or any task touching risky domains (auth, payments,
migrations, infrastructure, refactors).

**Purpose:** Address failure mode #1 (no risk assessment). Forces prospective hindsight — imagine
the task has failed, then work backward to identify what went wrong.

## Instructions

When invoked with a node ID (`/pre-mortem <wv-id>`):

### 1. Imagine Failure

Ask: "It's one week from now. This task has failed badly. What went wrong?"

Generate 3-5 failure scenarios:

- Technical failures (breaks existing functionality)
- Integration failures (doesn't work with other systems)
- Scope failures (takes 10x longer than expected)
- Data failures (corruption, loss, inconsistency)
- Security failures (vulnerabilities introduced)

### 2. Assess Each Risk

For each failure scenario, evaluate:

| Factor            | Scale                    | Description                       |
| ----------------- | ------------------------ | --------------------------------- |
| **Impact**        | low/medium/high/critical | How bad if it happens?            |
| **Likelihood**    | low/medium/high          | How likely to occur?              |
| **Detectability** | easy/medium/hard         | Will we notice before production? |

Priority = Impact × Likelihood (high-high = critical path risk)

### 3. Define Mitigations

For high-priority risks:

- **Prevention:** How to avoid the failure
- **Detection:** How to catch it early (tripwire)
- **Recovery:** How to roll back if it happens

### 4. Identify Blast Radius

What could be affected if something goes wrong?

- Files/modules touched
- Users/services impacted
- Data at risk
- Downstream dependencies

### 5. Create Rollback Plan

Before any changes:

- How to revert to working state?
- What's the backup strategy?
- Who needs to be notified?

### 6. Record in Metadata

```bash
wv update <id> --metadata='{
  "risks": [
    {
      "scenario": "Database migration corrupts user data",
      "impact": "critical",
      "likelihood": "medium",
      "mitigation": "Backup before migration, test on staging first",
      "tripwire": "Row count mismatch after migration"
    }
  ],
  "blast_radius": ["users table", "auth service", "all logged-in users"],
  "rollback_plan": "Restore from pre-migration backup within 15 minutes"
}'
```

## Output Format

**Example output:**

**Task:** wv-a1b2 — Migrate user sessions to Redis

**Failure Scenarios:**

1. [CRITICAL] **Session data lost during migration**
   - Impact: critical | Likelihood: medium
   - Mitigation: Export all sessions before, verify counts after
   - Tripwire: Session count drops by >5%

2. [WARNING] **Redis connection failures under load**
   - Impact: high | Likelihood: low
   - Mitigation: Connection pooling, fallback to old system
   - Tripwire: Connection timeout errors in logs

3. [LOW] **Migration takes longer than maintenance window**
   - Impact: medium | Likelihood: low
   - Mitigation: Test migration time on staging data
   - Tripwire: Progress <50% at halfway point

**Blast Radius:** auth-service, api-gateway, all active users

**Rollback Plan:** Revert config to use SQLite, sessions recreated on next login

**Recommendation:** Run on staging with production data copy first

## NEVER

- Skip risk assessment for "simple" changes to shared infrastructure
- Start implementation without identifying rollback plan
- Ignore medium-likelihood critical-impact risks
- Assume "it worked in dev" means it will work in production

## ALWAYS

- Run pre-mortem for any task with `type=feature` or `type=epic`
- Run pre-mortem for tasks touching: auth, payments, database, infrastructure
- Identify at least one tripwire (early warning sign)
- Define rollback plan before making changes

## Risk Domains (Auto-Trigger)

These domains should always trigger pre-mortem:

- **Authentication/Authorization** — Security implications
- **Payments/Billing** — Financial implications
- **Database migrations** — Data integrity
- **Infrastructure/DevOps** — System availability
- **Large refactors** — Regression potential
- **Third-party integrations** — External dependencies
- **User data handling** — Privacy implications

## Integration

This skill is called by:

- `/fix-issue` — Before implementation for significant tasks
- Pre-claim hook — Auto-invokes for features/epics and risky domains
- `/battle-plan` — Part of planning sequence

## Examples

### Example 1: Auth Change

```bash
/pre-mortem wv-b2c3

# Task: Add OAuth2 provider

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

# Risks:

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

#   1. Breaks existing email/password login (critical/low)

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

#   2. OAuth tokens stored insecurely (critical/medium)

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

#   3. Callback URL misconfiguration (high/medium)

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

# Blast radius: All users, login flow, session management

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

# Rollback: Feature flag to disable OAuth, revert to password-only

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

```

### Example 2: Database Migration

```bash
/pre-mortem wv-d4e5

# Task: Add indexes to users table

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

# Risks:

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

#   1. Table lock during index creation (high/high)

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

#   2. Disk space exhaustion (medium/low)

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

#   3. Query planner changes break existing queries (medium/medium)

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

# Blast radius: users table, all user-related queries

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

# Rollback: DROP INDEX, restore query performance

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

# Mitigation: Use CONCURRENTLY, run during low traffic

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

```

### Example 3: Refactor

```bash
/pre-mortem wv-f6g7

# Task: Extract shared utilities to new package

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

# Risks:

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

#   1. Import path changes break consumers (high/high)

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

#   2. Circular dependency introduced (medium/medium)

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

#   3. Build time increases significantly (low/medium)

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

# Blast radius: All packages importing utilities

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

# Rollback: Revert package extraction, inline utilities

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

# Mitigation: Update all imports in same PR, test full build

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

```

## Metadata Schema

```json
{
  "risks": [
    {
      "scenario": "Brief description of failure",
      "impact": "low|medium|high|critical",
      "likelihood": "low|medium|high",
      "detectability": "easy|medium|hard",
      "mitigation": "How to prevent or reduce",
      "tripwire": "Early warning sign"
    }
  ],
  "blast_radius": ["affected systems/files/users"],
  "rollback_plan": "How to revert if needed",
  "pre_checks": ["Verification before starting"],
  "risk_level": "low|medium|high|critical"
}
```

## Decision Gate

After pre-mortem, decide:

- **Proceed:** Risks are acceptable and mitigated
- **Reduce scope:** Too risky, simplify approach
- **Defer:** Need more information or preparation
- **Escalate:** Requires stakeholder input on risk acceptance

## Related Skills

- **/ship-it** — Define done criteria (pairs with risk assessment)
- **/wv-verify-complete** — Verify mitigations worked
- **/sanity-check** — Validate assumptions about risks
