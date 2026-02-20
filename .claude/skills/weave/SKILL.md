---
name: weave
description: "Graph-first workflow orchestrator with four phases (INTAKE, CONTEXT, EXECUTE, CLOSE)."
---

# /weave — Graph-First Orchestrator

**Purpose:** Unified entry point for all Weave-tracked work. Ensures graph-first workflow with
Context Pack generation, blocker validation, and learning capture.

**Current Implementation:** All four phases (INTAKE, CONTEXT, EXECUTE, CLOSE)

## Delegation Router

The orchestrator routes tasks to appropriate model tiers for cost efficiency. Rules are defined in
`.claude/delegation-rules.yml`.

### Tier Selection

```text
┌─────────────────────────────────────────────────────────────┐
│                    Task Classification                       │
├──────────────┬──────────────┬──────────────┬───────────────┤
│    Haiku     │    Sonnet    │     Opus     │    Agents     │
│   (Simple)   │   (Medium)   │  (Complex)   │ (Specialized) │
├──────────────┼──────────────┼──────────────┼───────────────┤
│ parse JSON   │ summarize    │ implement    │ epic-planner  │
│ validate     │ explain      │ debug        │ learning-     │
│ extract      │ assess scope │ architect    │   curator     │
│ filter       │ analyze deps │ refactor     │ weave-guide   │
└──────────────┴──────────────┴──────────────┴───────────────┘
```

### Router Function

When executing a subtask, determine tier by:

1. **Check explicit tier:** If task specifies tier, use it
2. **Match keywords:** Check against routing keywords in rules
3. **Check token estimate:** Use max_tokens thresholds
4. **Default to Opus:** For unmatched or high-stakes tasks

```python
def route_task(task_description: str, context_size: int) -> str:
    """Determine which model tier to use for a task."""
    rules = load_rules(".claude/delegation-rules.yml")

    # Check for Haiku keywords
    if any(kw in task_description.lower() for kw in rules.routing.haiku_keywords):
        if context_size <= rules.tiers.haiku.max_input_tokens:
            return "haiku"

    # Check for Sonnet keywords
    if any(kw in task_description.lower() for kw in rules.routing.sonnet_keywords):
        if context_size <= rules.tiers.sonnet.max_input_tokens:
            return "sonnet"

    # Check for agent triggers
    for agent in rules.tiers.agents.agents:
        if evaluate_condition(agent.trigger.condition, context):
            return f"agent:{agent.id}"

    # Default to Opus
    return "opus"
```

### Delegation Examples

| Task                                 | Tier   | Reason                |
| ------------------------------------ | ------ | --------------------- |
| "Parse wv show output to get status" | Haiku  | Keywords: parse, get  |
| "Summarize context pack for user"    | Sonnet | Keywords: summarize   |
| "Implement authentication flow"      | Opus   | Keywords: implement   |
| Node with type=epic created          | Agent  | Trigger: epic-planner |

### Subagent Invocation

When routing to non-Opus tier, use `runSubagent`:

```text
When task matches Haiku tier:
  → Invoke runSubagent with focused prompt
  → Parse structured output
  → Continue in main orchestrator

When task matches Agent tier:
  → Invoke runSubagent with agent file context
  → Agent completes specialized task
  → Return results to orchestrator
```

### Fallback Chain

If a tier fails or produces invalid output:

```text
Haiku → Sonnet → Opus (fallback chain)
Agent failure → Opus (direct fallback)
```

Log all escalations for metrics tracking.

### Fallback Triggers

Escalate to next tier when:

| Condition                                 | Action                |
| ----------------------------------------- | --------------------- |
| Output parsing fails                      | Escalate + log reason |
| Response incomplete                       | Escalate + log reason |
| Confidence below threshold                | Escalate + log reason |
| Explicit "I can't" from model             | Escalate + log reason |
| Timeout (>30s for Haiku, >60s for Sonnet) | Escalate + log reason |

### Fallback Implementation

```python
def execute_with_fallback(task, tier, context):
    """Execute task with automatic fallback on failure."""
    fallback_chain = {
        "haiku": "sonnet",
        "sonnet": "opus",
        "agent": "opus"
    }

    try:
        result = invoke_tier(tier, task, context)
        if validate_output(result):
            log_delegation(task.id, tier, "success", tokens_used)
            return result
        else:
            raise InvalidOutputError("Output validation failed")
    except Exception as e:
        next_tier = fallback_chain.get(tier)
        if next_tier:
            log_escalation(tier, next_tier, str(e))
            return execute_with_fallback(task, next_tier, context)
        else:
            # Already at Opus, re-raise
            raise
```

### Recovery Patterns

When fallback occurs:

1. **Preserve context:** Pass original task + failure reason to higher tier
2. **Don't retry same approach:** Higher tier should try different strategy
3. **Log for analysis:** Track failure patterns to improve routing rules
4. **User notification:** For repeated escalations, warn about potential rule issues

## Haiku Subagent Tasks

The following tasks should be delegated to Haiku via `runSubagent`:

### Parse wv show Output

When you need to extract node details from `wv show` output:

```text
Delegate to Haiku:
  Prompt: "Parse this wv show JSON output and extract: id, text, status,
           and any metadata fields. Return as structured JSON."
  Input: <wv show --json output>
  Expected output: {id, text, status, metadata: {...}}
```

### Parse wv list Output

When you need to filter or process node lists:

```text
Delegate to Haiku:
  Prompt: "Parse this array of Weave nodes. Filter to only [todo/active] status.
           Return array with: id, text, status, priority (from metadata)."
  Input: <wv list --json output>
  Expected output: [{id, text, status, priority}, ...]
```

### Extract Blockers from Context Pack

When you need blocker information from context:

```text
Delegate to Haiku:
  Prompt: "Extract blockers from this Context Pack. For each blocker return:
           id, text, status, and whether it's resolved (status=done)."
  Input: <wv context --json output>
  Expected output: {blockers: [{id, text, status, resolved: bool}],
                    has_unresolved: bool}
```

### Validate Node Status

When checking if a node can be claimed:

```text
Delegate to Haiku:
  Prompt: "Check if this node is claimable. Claimable means status is
           'todo' or 'blocked'. Return claimable (bool) and reason."
  Input: {status: "...", id: "..."}
  Expected output: {claimable: bool, reason: string}
```

### Subagent Invocation Pattern

Use `runSubagent` tool with these parameters:

```text
runSubagent(
  description: "Parse wv show output",
  prompt: "You are a JSON parsing assistant. Parse this Weave CLI output
           and extract the requested fields. Return ONLY valid JSON.

           Input: <json>

           Extract: id, text, status, metadata

           Return format: {\"id\": \"...\", \"text\": \"...\", ...}"
)
```

**Key principles:**

- Keep prompts under 500 tokens
- Request structured JSON output only
- Include example of expected format
- Don't ask for reasoning, just extraction

### Subagent Context Inheritance (WV_ACTIVE)

When spawning subagents, pass the active node context via `WV_ACTIVE` environment variable:

**Pattern:**

1. Parent claims work with `wv work <id>` (sets node to in-progress)
2. Parent exports `WV_ACTIVE=<id>` (or uses `eval "$(wv work <id> --quiet)"`)
3. Subagent calls `wv context --json` (automatically uses WV_ACTIVE)
4. Subagent receives full Context Pack: node + blockers + ancestors + learnings

**Example workflow:**

```bash
# Parent agent claims work and sets context
eval "$(wv work wv-a1b2 --quiet)"

# Subagent (inherits WV_ACTIVE from environment)
context=$(wv context --json)
node_text=$(echo "$context" | jq -r '.node.text')
blockers=$(echo "$context" | jq -r '.blockers | length')
```

**When spawning via runSubagent:**

Include WV_ACTIVE in the prompt for subagents that need graph context:

```text
runSubagent(
  description: "Analyze blockers for current node",
  prompt: "Current work context:
           WV_ACTIVE: $WV_ACTIVE

           Run: wv context --json

           Analyze the blockers array and report which must be resolved first."
)
```

**Benefits:**

- Subagents automatically get relevant Context Pack
- No need to pass node ID explicitly in every prompt
- Consistent context across deep agent hierarchies
- Works with any tool that spawns child processes

### Haiku Result Caching

Cache Haiku results to avoid redundant calls within a session:

```bash
# Cache location (in tmpfs for speed)
HAIKU_CACHE="${WV_HOT_ZONE}/haiku_cache"  # WV_HOT_ZONE is per-repo namespaced

# Cache key: hash of (task_type + input)
cache_key=$(echo -n "${task_type}:${input}" | md5sum | cut -d' ' -f1)

# Check cache before calling Haiku
if [ -f "$HAIKU_CACHE/$cache_key" ]; then
    # Cache hit - use cached result
    result=$(cat "$HAIKU_CACHE/$cache_key")
else
    # Cache miss - call Haiku and cache result
    result=$(invoke_haiku "$prompt")
    echo "$result" > "$HAIKU_CACHE/$cache_key"
fi
```

**Cache invalidation:**

- Clear on any `wv` command that modifies state (add, update, done, block, link)
- TTL: 5 minutes (configurable in delegation-rules.yml)
- Clear on session end

**Cacheable tasks:**

- `parse_wv_show` - same node → same output
- `parse_wv_list` - same filter → same output
- `extract_blockers` - same context pack → same blockers
- `validate_node_status` - same status → same result

**Non-cacheable:**

- Anything involving timestamps
- Tasks with side effects
- User-facing summaries (context may have changed)

## Usage

```bash
/weave <id>        # Work a specific node
/weave <text>      # Create node from description
/weave             # Show ready work, pick one
```

## Iteration Model

The orchestrator is a state machine with defined transitions:

```text
┌─────────────────────────────────────────────────────────────┐
│                    WeaveOrchestrator                        │
├─────────────┬─────────────┬─────────────┬──────────────────┤
│   INTAKE    │   CONTEXT   │   EXECUTE   │      CLOSE       │
│             │   (graph)   │             │                  │
│ wv add/ready│ wv context  │ do work     │ wv done          │
└─────────────┴─────────────┴─────────────┴──────────────────┘
        │                         │
        │    ◄────────────────────┤ (new blocker/contradiction)
        │                         │
        └─────────────────────────┘ (scope expansion → new node)
```

**Normal flow:** INTAKE → CONTEXT → EXECUTE → CLOSE

**Iteration triggers (EXECUTE → CONTEXT):**

| Trigger         | Graph Change                 | Action                                   |
| --------------- | ---------------------------- | ---------------------------------------- |
| New blocker     | `wv block` called            | Re-query context, resolve blocker first  |
| Contradiction   | `wv link --type=contradicts` | Hard stop, resolve via `wv resolve`      |
| Scope expansion | Child node created           | Block current on child, work child first |

**Re-entry (INTAKE → new node):**

When scope expands significantly, create a new node and restart from INTAKE for that node. Current
node remains blocked until child completes.

## Phase 1: INTAKE — Select or Create Work

**Goal:** Ensure valid, claimable work is selected before starting.

### Agent Auto-Invocation

During INTAKE, automatically invoke specialized agents based on node type:

| Node Type        | Agent          | Trigger                           | Action                      |
| ---------------- | -------------- | --------------------------------- | --------------------------- |
| Epic (type=epic) | `epic-planner` | New epic or epic with no children | Suggest breakdown structure |
| Any              | `weave-guide`  | User expresses confusion          | Offer workflow guidance     |

**Pre-Launch Validation (required before any agent spawn):**

Before invoking any weave agent (epic-planner, learning-curator, weave-guide), verify it has Bash
tool access. Two Sprint 11 agents consumed ~25k tokens each and returned nothing due to missing Bash
permissions — this check prevents silent token burn.

```text
1. Read the agent definition file:
   → Path: .claude/agents/<name>.md (project-local) or ~/.claude/agents/<name>.md (global)
   → Use Read tool on that path

2. Check frontmatter for tools field containing "Bash":
   → PASS: tools field present and includes "Bash" (e.g. tools: ["Bash", "Read", ...])
   → FAIL: tools field missing, or "Bash" not listed

3. On FAIL → ABORT agent spawn with this error:
   ⛔ Agent pre-launch check failed: `<name>` lacks Bash tool access.
   File: .claude/agents/<name>.md has no `tools` field (or "Bash" is not listed).
   Without Bash, the agent cannot run wv commands and will return nothing.
   Fix: add `tools: ["Bash", "Read", "Grep", "Glob"]` to the agent frontmatter.
   → Do NOT spawn the agent.
   → Fall back to inline execution (perform the steps yourself instead of delegating).
```

**Epic Planner Auto-Invocation:**

When a node has `metadata.type = "epic"` and status is `todo`:

```text
1. Check if epic has child features/tasks
2. If no children:
   a. Pre-audit: search for existing implementation BEFORE suggesting breakdown
      → git log --oneline -20 -- . (recent work in repo)
      → grep -r "<epic-keywords>" . --include="*.py" --include="*.sh" -l
      → ls <expected-dirs> 2>/dev/null
      → Report: "Found X files / Y commits that may implement parts of this epic"
   b. Show pre-audit summary to user
   c. If significant existing work found:
      → Note which parts appear pre-solved
      → Pass findings to epic-planner so it excludes already-implemented tasks
   d. Suggest: "This epic has no breakdown. Invoke epic-planner?"
   → If yes: runSubagent(epic-planner) with epic context + pre-audit findings
   → Agent returns suggested feature/task structure (excluding pre-solved items)
   → User approves/modifies, nodes created
3. If has children:
   → Skip auto-invocation, proceed normally
```

**Opt-out:** User can skip with `--no-agents` flag or respond "no" to suggestion.

### Input Modes

#### Mode 1: Node ID Provided (`/weave wv-xxxxxx`)

1. **Validate node exists:**

   ```bash
   wv show <id>
   ```

   - If not found: Error, stop

2. **Check if node is claimable:**
   - Status must be `todo` or `blocked`
   - If `done`: Error "Node already completed"
   - If `active`: Warn "Node already claimed, continue anyway?" (proceed unless contradicts)

3. **Claim the node:**

   ```bash
   wv update <id> --status=active
   ```

4. **Proceed to CONTEXT phase** (not yet implemented - for now, show Context Pack):

   ```bash
   wv context <id> --json
   ```

#### Mode 2: Text Description Provided (`/weave "Fix authentication bug"`)

1. **Validate description clarity:**
   - Check length: Must be ≥5 words
   - Check for verb: Must contain action word
   - If vague: Invoke `/wv-clarify-spec` skill for clarification before creating

2. **Create node:**

   ```bash
   wv add "<text>" --status=active
   ```

   - Captures returned ID (wv-xxxxxx format)

3. **Proceed to CONTEXT phase** (not yet implemented - for now, show Context Pack):

   ```bash
   wv context <new-id> --json
   ```

#### Mode 3: No Input Provided (`/weave`)

1. **Show ready work:**

   ```bash
   wv ready --json
   ```

2. **Propose next unblocked task:**
   - Show top 3-5 ready nodes
   - Include: ID, text, priority (from metadata if available)
   - Prefer: priority=1, type=task (over feature/epic)

3. **Ask user to select:**
   - "Which task would you like to work on?"
   - Options: List of ready nodes + "Other" (for custom input)

4. **Once selected, proceed with Mode 1 or Mode 2 logic**

## Validation Rules

**Vague text detection (triggers wv-clarify-spec):**

- Less than 5 words
- No action verb (fix, add, update, implement, etc.)
- Too abstract ("make it better", "improve things")

**Claimable node check:**

- Status: `todo` or `blocked` → OK
- Status: `active` → Warn but allow
- Status: `done` → Block with error

## Phase 2: CONTEXT — Mandatory Graph Query

**Goal:** Build context before any planning or coding. Enforce graph-first workflow.

### Steps

1. **Generate Context Pack:**

   ```bash
   wv context <id> --json
   ```

2. **Parse and check for blockers:**
   - If `contradictions[]` is non-empty: **HARD STOP**
     - Present each contradiction
     - Require resolution via `wv resolve` (see below)
     - Cannot proceed to EXECUTE
   - If `blockers[]` has nodes with `status != done`: **STOP**
     - List unresolved blockers
     - Options: work blocker first, or remove dependency

3. **Surface relevant context:**
   - **Ancestors:** Show parent chain with their learnings
   - **Related nodes:** Nodes via `implements`/`references`/`relates_to`
   - **Pitfalls:** Unaddressed pitfalls (prompt: "Watch out for these")
   - **References with weight ≥0.7:** Flag as "must read before editing"

4. **Confirm ready to proceed:**
   - If no blockers/contradictions: "Context loaded. Proceeding to EXECUTE."
   - Cache Context Pack for this session (invalidates on edge changes)

### Contradiction Resolution

When `contradictions[]` is non-empty:

1. **Present options for each contradiction:**

   ```bash
   wv resolve <edge-id> --winner=<node-id>  # One decision supersedes
   wv resolve <edge-id> --merge             # Create merged node
   wv resolve <edge-id> --defer             # Change to relates_to
   ```

2. **Record resolution:** Create learning node with decision rationale

3. **Update graph:** Winner gets `supersedes` edge, or both get `obsoletes` to merger

4. **Re-run CONTEXT** after resolution

## Phase 3: EXECUTE — Do the Work

**Goal:** Perform the actual work with scope control and edge enforcement.

### Pre-Conditions (Enforced)

Before any code changes:

- Context Pack must exist and be current
- No unresolved contradictions
- No active blockers (all must be `done`)

If pre-conditions fail, return to CONTEXT phase.

### Edge Enforcement Rules

During execution, respect edge semantics:

| Edge Type    | Weight | Action                                                      |
| ------------ | ------ | ----------------------------------------------------------- |
| `references` | ≥0.7   | **Must read** referenced file/node before editing           |
| `references` | <0.7   | Suggested reading, not required                             |
| `implements` | any    | Extract checklist items from spec node, verify against spec |
| `supersedes` | any    | Warn if working on obsoleted node, suggest switch           |
| `obsoletes`  | any    | **Hard warn** — do not proceed without explicit override    |

### Scope Control (wv-guard-scope)

Monitor for scope creep during execution:

1. **Track touched files:** Maintain list of files edited
2. **Detect expansion:** If about to edit files unrelated to node text:
   - Prompt: "This seems outside scope. Create child node?"
   - If yes: Create child node, triggers iteration (see Iteration Model above)
3. **Limit changes:** Prefer small, focused commits over large refactors

### Stuck Detection (wv-detect-loop)

If same approach fails 2+ times:

1. **Recognize loop:** Track failed attempts (same error, same file)
2. **Prompt pivot:** "Approach failed twice. Try different strategy?"
3. **Options:**
   - Different implementation approach
   - Consult oracle for debugging advice
   - Create blocker node for prerequisite work
   - Escalate to user

## Phase 4: CLOSE — Complete with Learnings

**Goal:** Capture learnings, verify completion, and close node + GitHub issue.

### ⛔ Mandatory Pre-Close Gate

**DO NOT call `wv done` until ALL items are checked:**

```text
Pre-close checklist (non-trivial work):
  [ ] learning-curator invoked and produced structured learnings
  [ ] Learnings contain at least one of: decision: | pattern: | pitfall:
  [ ] Verification evidence captured (tests/build/manual)

Trivial work only (doc typo, breadcrumbs, README tweak):
  [ ] --skip-learnings used deliberately
  [ ] --skip-verification used deliberately
  If in doubt → not trivial → run the curator.
```

**If you are about to call `wv done` and the curator has NOT been invoked:**

```text
⛔ STOP. Do not proceed.
→ Invoke learning-curator now (see invocation steps below).
→ Only call wv done after structured learnings are ready.
```

**Anti-pattern (Sprint 11 — 6 nodes with flat learnings, curator never invoked):**

```text
✗ WRONG:  wv done wv-XXXX --learning="fixed the bug"
✓ RIGHT:  runSubagent(learning-curator) → get structured learnings
          wv done wv-XXXX --learning="decision: ... | pattern: ... | pitfall: ..."
```

### Learning Curator Invocation

**Always invoke** for non-trivial work — this is not a suggestion:

```text
When entering CLOSE phase:
1. Gather work context:
   - Files modified during EXECUTE
   - Decisions made (from chat history)
   - Problems encountered and solutions
   - Time spent / complexity assessment

2. Invoke learning-curator agent:
   → runSubagent(learning-curator) with:
     - Node text and metadata
     - Files changed
     - Summary of work done

3. Agent extracts and proposes:
   - decision: Key choice made and rationale
   - pattern: Reusable technique that worked
   - pitfall: Mistake to avoid (if any)
   - addresses: Links to resolved pitfalls

4. User confirms/edits learnings
5. Learnings stored in node metadata — then and only then call wv done
```

**Exception:** Trivial tasks (docs typos, breadcrumbs) can use `--skip-learnings`.

### Verification (wv-verify-complete)

Before closing, **require** evidence that work is complete:

1. **Check for verification evidence:**
   - Tests pass? (if applicable)
   - Build succeeds? (if applicable)
   - Manual verification done?

2. **If no evidence:** Prompt "How do we know this works?"
   - Run relevant test command
   - Check build output
   - Demonstrate functionality

3. **Must provide verification** via one of:
   - `--verification-method=test --verification-command='...' --verification-evidence='...'`
   - `--skip-verification` (only for trivial tasks like docs/breadcrumbs)

### Learning Capture (learning-curator)

Extract learnings from the completed work:

```bash
wv done <id> --learning="pattern: Reusable technique that worked"
```

**Learning format options:**

- `pattern: <reusable approach>` - Technique that worked well
- `pitfall: <mistake to avoid>` - What to not do next time
- `decision: <choice and rationale>` - Key architectural decision

### Pitfall Linking

When work addresses a previously identified pitfall:

1. **Review pitfalls from Context Pack**
2. **If addressed:** Include in `--addresses=` flag
3. **Creates bidirectional links:**
   - `wv-current.$.addresses = ["wv-pitfall"]`
   - `wv-pitfall.$.addressed_by = ["wv-current"]`
   - Edge: `wv-current --[addresses]--> wv-pitfall`

### New Pitfall Discovery

If new pitfall discovered during work:

1. **Create pitfall node:**
   `wv add "Pitfall: <description>" --metadata='{"type":"pitfall","pitfall":"..."}'`
2. **Link to current work:** `wv link <current> <pitfall> --type=relates_to`
3. **Close pitfall immediately:** `wv done <pitfall>`

### Close and Sync

```bash
wv done <id> --learning="pattern: ..."
wv sync
git add .weave/ && git commit -m "chore: sync Weave after completing <id> [skip ci]"
git push
```

**Verification checklist:**

- [ ] Node closed
- [ ] GitHub issue closed (if linked)
- [ ] Learnings captured
- [ ] State synced to `.weave/`
- [ ] Changes pushed to remote

## Notes

- This skill is **model-invocable** - can be called autonomously
- All four phases complete: INTAKE → CONTEXT → EXECUTE → CLOSE
- Orchestrator enforces graph-first workflow throughout
