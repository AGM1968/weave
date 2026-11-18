---
id: quality-gate
description:
  "Close work on evidence: set testable done criteria before implementing, verify with an executable
  check and record the evidence at close, and recover when wv done is blocked by a complexity
  threshold. Use when starting a tracked node, before wv done, or when a closure fails on CC limits."
fallback: "wv guide --procedure=quality-gate"
adapters: [claude, codex, copilot]
visibility: shared
claude_skill: wv-verify-complete
---

# Quality Gate

A node closes on evidence that its done criteria hold, not on the work looking right. The criteria
are set before implementation, the evidence is recorded at close, and the complexity gate refuses a
close that leaves a touched file over its threshold.

## Done criteria before implementation

Set the criteria when the node is created or claimed (`wv work <id>`), before any code is written:

```bash
wv add "<text>" --criteria="c1|c2|c3" --risks=low --verification-plan="<how each will be checked>"
wv update <id> --metadata='{"done_criteria":["..."],"non_goals":["..."]}'   # an existing node
```

- Each criterion is binary and checkable: an outcome ("a failed login shows an error"), not an
  activity or a judgement ("make login work", "improve UX").
- Keep three to seven; more means the node should be split.
- Name at least one non-goal, giving "while I'm here" work a recorded boundary.
- When the criteria are unclear, settle them with the owner before implementing.
- Never add criteria mid-implementation: new requirements and discovered scope become their own
  nodes (`wv add ... --parent=<epic>`), checked against the non-goals first.
- Review the criteria when the work takes longer than expected.

## Verification before close

Before `wv done` on non-trivial work, run the strongest check that applies and keep its output:

| Method    | When                           | Evidence                    |
| --------- | ------------------------------ | --------------------------- |
| test      | tests cover the area           | command and pass output     |
| build     | compiled language or bundler   | clean build output          |
| typecheck | typed code                     | no type errors              |
| lint      | style or quality checks exist  | clean lint output           |
| runtime   | behaviour checked by hand      | steps and observed result   |
| diff      | review is the only check       | before and after, explained |

Check each done criterion against that evidence, then record it on the close:

```bash
wv done <id> --verification-method=test --verification-evidence="tests/test-x.sh: 34/34" \
  --learning="decision: ... | pattern: ... | pitfall: ..."
wv done <id> --verification-method=test --verification-evidence-file=<log>
```

The close gate refuses non-trivial work with no recorded verification; a plan recorded with
`--verification-plan` is shown back at that point, to be confirmed with evidence.

- Run at least one executable check; "no errors in the editor" and "should work" are not evidence.
- Never claim a check passed without running it, and never skip verification because a change looks
  trivial when it touches shared code.
- A fix to a defect also follows the verify-before-fixed procedure
  (`wv guide --procedure=verify-before-fixed`).

When verification is not possible (no tests, environment unavailable), record that as the method
with its reason, `--verification-method=deferred --verification-evidence="<why>"`, and add a
follow-up node for the missing check before closing. `--skip-verification` bypasses only the hook
layer; the advisory checks in `wv done` still run.

## Complexity gate: GraphPolicyViolation

`wv done` enforces CC thresholds (Bash: 100, Python: 25, TypeScript: 15). If a node touches a file
over the limit, closure is blocked with `GraphPolicyViolation`.

**Resolution path:**

```bash
wv quality functions <file>    # see which functions are over the limit
# Option A: refactor the file, commit, wv quality scan, retry wv done
# Option B: exempt the path in .weave/quality.conf then wv load
```

**Exempting a path** (monolithic scripts, archived code, one-off utilities):

```ini
# .weave/quality.conf
[exempt]
install.sh          # full path match — monolithic, not application logic
archive/            # directory prefix (trailing / required)
```

After editing `.weave/quality.conf`, run `wv load` to sync exemptions into the live DB, then retry
`wv done`. The `WV_REQUIRE_QUALITY=0` env var bypasses the refresh functions only — the DB
constraint still fires; use the conf file instead.

**Per-developer override** (gitignored, never shared): `.weave/quality.local.conf` is loaded after
`.weave/quality.conf` and lets you suppress `warn`-level gates locally without touching the shared
config. Team-wide `test_gate=2` (block) gates cannot be downgraded by the local layer.
