---
name: resolve-refs
description: "Extracts and follows cross-references in documents or code. Use when a task contains node IDs, issue links, or file references that need systematic follow-up."
---

# Resolve References

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

Extract cross-references from: $ARGUMENTS

1. **Extract**: Run `~/.local/bin/wv refs $ARGUMENTS`
2. **Review**: Look at the suggested follow-up commands
3. **Follow**: Execute relevant commands to gather full context
4. **Summarize**: Report what was found at each reference

## Reference Types Detected

- `wv-xxxxxx` → `wv show wv-xxxxxx`
- `gh-N` or `#N` → `gh issue view N`
- `See Note N` → `rg "Note N" docs/`
- `ADR-xxx`, `RFC-xxx` → `rg -l "ADR-xxx" docs/`
- File paths → Read the file

## Guardrails

- Max 10 references per pass
- No automatic fetching (review commands first)
- No recursion (invoke again if needed)
