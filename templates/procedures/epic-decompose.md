---
id: epic-decompose
description:
  "Decompose an epic into features and tasks with proper parent edges and blocking order. Use when
  starting a new epic that needs a task breakdown before work can begin."
fallback: "wv guide --procedure=epic-decompose"
adapters: [codex, copilot]
visibility: shared
---

# Epic Decomposition

Epics with no child edges produce a **flat graph** — `wv context`, `wv path`, and commit aggregation
all break silently. Always link sub-tasks at creation time:

```bash
# 1. Create the epic
EPIC=$(wv add "Epic: big feature" --metadata='{"type":"epic","priority":1}')

# 2. Create features linked to the epic — --parent creates the implements edge
FEAT=$(wv add "Feature: sub-capability" --metadata='{"type":"feature"}' --parent=$EPIC)

# 3. Create tasks linked to their feature — set criteria at creation time
TASK=$(wv add "task(S1): specific work" --parent=$FEAT \
  --criteria="criterion 1|criterion 2|make check passes" --risks=low)

# 4. Set blocking order (epic unblocked only when features done)
wv block $EPIC --by=$FEAT
wv block $FEAT --by=$TASK
```

**Rules:**

- `--parent=` is **mandatory** for every feature and task — never optional
- `--criteria=` and `--risks=` at creation time makes nodes claim-ready immediately (hook silent
  pass)
- Use the proposal's sprint labels verbatim in node text — drift causes audit mismatches
- Use `/wv-decompose-work` skill for structured breakdowns
- Run `/weave-audit` — reports epics with no children and deducts score
