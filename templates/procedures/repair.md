---
id: repair
description: "Turn detected workflow drift, missing guardrails, and close-time friction into tracked remediation."
fallback: "wv guide --procedure=repair"
adapters: [codex, copilot]
visibility: shared
status: ready
---

# Repair Workflow

When execution exposes a real workflow defect, fix it in the current node only when it blocks safe
completion. Otherwise create follow-up work; do not expand scope silently.

```bash
wv add "Fix: <problem>" --gh --parent=<feature-or-epic>
wv block <current> --by=<new>             # only when completion depends on it
wv link <new> <current> --type=relates_to # otherwise preserve the relationship
wv trails save --message="Detected X; created Y; next step Z"
```

Retry transient failures once with brief backoff. For blockers, create and surface recovery work.
For ambiguity, permissions, or policy decisions, stop and request direction rather than guessing.
Non-interactive flows should record pending-close state and remain resumable rather than waiting on
stdin indefinitely.
