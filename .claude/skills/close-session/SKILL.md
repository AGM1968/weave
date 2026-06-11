---
name: close-session
description:
  "Runs the end-of-session protocol to save, sync, and push work safely. Use when finishing a
  session or preparing to hand off work."
---

# Session Close Protocol

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator. Use `/weave` instead for
> the full graph-first workflow. Direct invocation is deprecated and may be removed in a future
> release.

**CRITICAL**: Work is NOT complete until `git push` succeeds.

## Mandatory Workflow

```bash
# 1. File issues for remaining work
wv add "..." --status=todo  # For anything needing follow-up

# 2. Run quality gates (if code changed)
# Tests, linters, builds as appropriate

# 3. Commit completed work while nodes are still active
#    prepare-commit-msg appends Weave-ID trailers during this step
git add <files>
git commit -m "descriptive work message"

# 4. Close completed nodes
wv done <id> --learning="decision: ... | pattern: ... | pitfall: ..."
# Or: wv batch-done <id1> <id2> ... --learning="shared sprint learning"

# 5. Sync and push
wv sync --gh              # Persist state AND sync to GitHub issues
git add .weave/           # Stage any GH metadata changes from sync
git diff --cached --quiet || git commit -m "chore(weave): sync state [skip ci]"
git push
git status  # MUST show "up to date with origin"
```

## Capture Learnings

For significant work:

```bash
wv done <id> --learning="decision: ... | pattern: ... | pitfall: ..." --no-overlap-check
# Or pre-structure the same fields in metadata first:
wv update <id> --metadata='{"decision":"...","pattern":"...","pitfall":"..."}'
wv done <id>
```

## Critical Rules

- NEVER stop before pushing — work stays stranded locally
- NEVER say "ready to push when you are" — YOU must push
- If push fails, resolve and retry until it succeeds

## Retro (optional but recommended)

After pushing, check if any commands dominated context cost this session:

```bash
wv analyze sessions --call-stats --top=5 --since-days=1 --source=agent
```

Always pass a window (`--since-days=1` for a session retro) AND `--source=agent`. Unwindowed output
is a lifetime aggregate that mixes instrumentation eras — it surfaces long-fixed costs, not this
session's. Without the source filter, high-frequency hook calls (filtered, ~500 B, mostly never
entering context) dominate the call counts and make institutional background noise look like an
agent behavior problem (2026-06-11 retro misread). `source=sync` and `source=test` are excluded by
default; `--source=agent` narrows to the only slice that actually costs context.

If the agent-sourced output shows `wv list` at the top by a large margin, switch to `wv query` or
`wv search` for targeted reads next session. See `wv guide --topic=discovery`.

Enable persistent tracking if not already on: `wv config enable session-analysis`

## Handoff

If work continues in another session:

- What was accomplished
- What remains to do
- Any blockers
