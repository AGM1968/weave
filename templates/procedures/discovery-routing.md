---
id: discovery-routing
description: "Route graph, code, impact, and inspection queries by uncertainty and edit scope."
fallback: "wv guide --procedure=discovery-routing"
adapters: [claude, codex, copilot]
visibility: shared
status: ready
claude_skill: wv-discovery-routing
---

# Discovery Routing

Start with the smallest question that can resolve the uncertainty. Do not turn routine work into a
broad scan; branch into richer inspection only when scope, unfamiliarity, or risk warrants it.

| Need | Route |
| --- | --- |
| Locate related work or prior decisions | `wv search "<topic>"` → `wv query <exact predicates>` |
| Understand uncertain or cross-node work | `wv context <id> --json` → `wv discover <id> --json` → `wv impact <id>` |
| Locate unfamiliar implementation | `wv search --code "<concept>" --graph` |
| Edit broad or cross-module targets | `wv impact --files=<targets>` |
| Touch a hotspot or complex path | `wv quality functions <file>` then `wv quality patterns scan <scope>` |

`bootstrap` and `context` already include bounded discovery. Run direct `discover` when their result
shows a material unknown, cross-node relationship, prior learning, or candidate blind spot that must
be assessed before implementation.
