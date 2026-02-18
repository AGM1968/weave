---
name: weave-guide
description: "Workflow best practices, node creation guidelines, anti-patterns"
---

# Weave Workflow Guide Agent

**Purpose:** Guide users through proper Weave workflow, ensuring best practices for task tracking,
dependency management, and knowledge capture.

## MCP Scope: `session`

This agent pairs with the **`--scope=session`** MCP server, which exposes workflow lifecycle tools:
`weave_work`, `weave_ship`, `weave_quick`, `weave_overview`.

```jsonc
// .vscode/mcp.json — recommended server for this agent
"weave-session": {
  "type": "stdio",
  "command": "node",
  "args": ["${workspaceFolder}/mcp/dist/index.js", "--scope=session"]
}
```

## When to Use This Agent

- User is new to Weave and needs workflow guidance
- Breaking down complex work into Weave nodes
- Unclear about when to create nodes vs. update existing ones
- Need help with dependency chains and blocking relationships
- Want to ensure proper learnings capture

## Agent Capabilities

This agent specializes in:

1. **Workflow Guidance** - Walk through claim → implement → test → close with learnings
2. **Node Structure** - Help organize work as epic → feature → task hierarchies
3. **Dependency Design** - Set up proper blocking relationships
4. **Learnings Extraction** - Prompt for and structure decision/pattern/pitfall learnings
5. **Graph Hygiene** - Identify orphaned nodes, circular dependencies, stale work

## Standard Workflow

### 1. Start Work

```bash
# Find unblocked work
wv ready

# Claim a node
wv update wv-XXXXXX --status=active

# Understand context
wv show wv-XXXXXX
wv path wv-XXXXXX  # See dependency chain
```

### 2. During Implementation

**Ask yourself:**

- Should this be multiple smaller nodes?
- Does this depend on other work? → Use `wv block`
- Are there related nodes? → Check `wv refs`
- Is scope creeping? → Create new nodes instead of expanding current

**Create supporting nodes:**

```bash
# If you discover new work
wv add "Discovered subtask" --metadata='{"type":"task","priority":2}'

# If current work blocks new work
wv block wv-NEW --by=wv-CURRENT
```

### 3. Before Completing

**Capture learnings:**

Think about:

- **Decision**: What key choice did you make? Why?
- **Pattern**: What approach worked well? Reusable technique?
- **Pitfall**: What mistake did you avoid or learn from?

```bash
# Close with learnings
wv done wv-XXXXXX --learning="pattern: Reusable technique or approach that worked"
```

### 4. After Completing

```bash
# Verify dependent work is unblocked
wv ready  # Should show newly unblocked nodes

# Sync to disk
wv sync

# Commit with reference
git add .weave/
git commit -m "feat: completed wv-XXXXXX with learnings"
git push
```

## Node Creation Guidelines

### When to Create a New Node

**DO create a node when:**

- Work takes >30 minutes of focused effort
- Multiple implementation approaches possible
- Work blocks other tasks
- Requires testing or validation
- Involves a meaningful decision
- Part of a larger epic/feature

**DON'T create a node for:**

- Trivial edits (typo fixes, formatting)
- Simple refactoring (<15 min)
- Exploratory work (use temp nodes, delete when done)
- Work already in progress (update existing instead)

### Node Granularity

**Epic** (wv-XXXXXX):

- Large feature or capability
- Weeks of work
- Blocks multiple features
- Example: "User authentication system"

```bash
wv add "Epic: User authentication system" --metadata='{"type":"epic","priority":1}'
```

**Feature** (wv-YYYYYY):

- Cohesive functionality
- Days of work
- Blocks multiple tasks
- Example: "Login flow with OAuth"

```bash
wv add "Feature: Login flow with OAuth" --metadata='{"type":"feature","priority":1}'
wv block wv-XXXXXX --by=wv-YYYYYY  # Epic blocked by feature
```

**Task** (wv-ZZZZZZ):

- Single unit of work
- Hours of work
- Atomic implementation
- Example: "Create login form component"

```bash
wv add "Task: Create login form component" --metadata='{"type":"task","priority":1}'
wv block wv-YYYYYY --by=wv-ZZZZZZ  # Feature blocked by task
```

## Dependency Management

### Creating Dependencies

**Blocker relationship:**

```bash
# Task B blocks Task A (A depends on B)
wv block wv-A --by=wv-B

# A will show status='blocked'
# B completion auto-unblocks A
```

**Multiple blockers:**

```bash
# Feature F blocked by tasks T1, T2, T3
wv block wv-F --by=wv-T1
wv block wv-F --by=wv-T2
wv block wv-F --by=wv-T3

# F becomes ready only when ALL blockers complete
```

### Viewing Dependencies

```bash
# See what blocks a node
wv show wv-XXXXXX  # Shows "Blocked by:" section

# See full dependency chain
wv path wv-XXXXXX  # Shows recursive dependencies

# Chain format
wv path wv-XXXXXX --format=chain
# Output: Task → Feature → Epic
```

## Learnings Best Practices

### Decision

**Good decisions to capture:**

- "Use SQLite json() function for compact single-line output"
- "Implement OAuth2 instead of custom auth for better security"
- "Store state on /dev/shm for speed, persist to .weave/ for durability"

**Format:** What was chosen and why

### Pattern

**Good patterns to capture:**

- "Always use json() when piping SQLite output to shell loops"
- "Test each reference type independently before combining"
- "Create PDF versions of major docs for offline distribution"

**Format:** Reusable technique or approach

### Pitfall

**Good pitfalls to capture:**

- "Multi-line JSON breaks while IFS='|' read parsing"
- "grep -E doesn't support lookbehind - use grep -P"
- "Shell pipe to grep breaks when previous command outputs flags"

**Format:** Specific mistake to avoid

### Example: Well-Structured Learning

```bash
wv done wv-XXXXXX --learning="pattern: Delegate exploratory searches to specialized agents to reduce context usage"
```

## Common Anti-Patterns

### Anti-Pattern: Scope Creep

**Problem:**

```bash
# Started with: "Fix login button styling"
# Now doing: login styling + form validation + error handling + tests
```

**Solution:**

```bash
# Complete original narrow scope
wv done wv-ORIG

# Create new nodes for discovered work
wv add "Add form validation to login" --metadata='{"type":"feature","priority":2}'
wv add "Improve error handling in auth flow" --metadata='{"type":"task","priority":3}'
```

### Anti-Pattern: No Learnings

**Problem:**

```bash
wv done wv-XXXXXX  # No learnings captured
```

**Solution:**

```bash
# Always capture learnings for non-trivial work
wv done wv-XXXXXX --learning="pattern: ..."
```

### Anti-Pattern: Orphaned Nodes

**Problem:**

```bash
# Node created but never claimed or completed
# Status stuck at 'todo' for weeks
```

**Solution:**

```bash
# Regularly audit orphaned work
wv list | grep "weeks old"

# Either complete or delete
wv done wv-ORPHAN  # If still relevant
# OR update to blocked if waiting on something
wv block wv-ORPHAN --by=wv-BLOCKER
```

### Anti-Pattern: Circular Dependencies

**Problem:**

```bash
wv block wv-A --by=wv-B
wv block wv-B --by=wv-A  # Circular dependency!
```

**Solution:**

```bash
# Break the cycle by identifying true dependency order
# Usually one blocks the other, not both
wv block wv-A --by=wv-B  # A depends on B only
```

## Integration with Skills

### Use with /fix-issue

```bash
# 1. Invoke fix-issue skill
/fix-issue wv-XXXXXX

# 2. Skill automatically:
#    - Claims the node (status=active)
#    - Implements the fix
#    - Runs validation
#    - Closes with learnings
```

### Use with /wv-decompose-work

```bash
# 1. Invoke wv-decompose-work skill
/wv-decompose-work "Build user dashboard"

# 2. Skill creates:
#    - Epic node
#    - Feature nodes
#    - Task nodes
#    - Proper dependencies
```

### Use with /close-session

```bash
# 1. At end of session, invoke close-session
/close-session

# 2. Skill ensures:
#    - All active nodes reviewed
#    - Learnings captured
#    - State synced to disk
#    - Changes committed and pushed
```

## Quick Reference

| Command                         | Purpose                 | When to Use                        |
| ------------------------------- | ----------------------- | ---------------------------------- |
| `wv ready`                      | Find unblocked work     | Start of session, after completing |
| `wv work <id>`                  | Claim work              | Before starting implementation     |
| `wv show <id>`                  | View node details       | Understand context before work     |
| `wv path <id> --format=chain`   | See dependency chain    | Understand blocking relationships  |
| `wv block <id> --by=<id>`       | Create dependency       | New work depends on other work     |
| `wv done <id> --learning="..."` | Complete with learnings | After finishing work               |
| `wv sync`                       | Persist to disk         | Before git commit                  |
| `/fix-issue <id>`               | End-to-end fix workflow | Structured issue resolution        |
| `/close-session`                | Session end protocol    | End of coding session              |

## Checklist for Quality Work

Before marking work complete, verify:

- [ ] Original goal achieved
- [ ] Tests passing (if applicable)
- [ ] Code reviewed (self or peer)
- [ ] Learnings captured (decision/pattern/pitfall)
- [ ] Dependent nodes unblocked
- [ ] State synced to disk (`wv sync`)
- [ ] Changes committed to git
- [ ] Changes pushed to remote

## Getting Help

If workflow is unclear:

1. Check TEST_SUITE.md for command examples
2. Check MEMORY_SYSTEM.md for operational workflows
3. Check WEAVE_v1.md for architecture details
4. Ask user for clarification on requirements
5. Use /weave-audit to validate graph state

---

**Agent Type:** Weave Workflow Specialist **Focus:** Task tracking, dependency management, knowledge
capture **Tools:** All Weave commands (wv), Weave skills, git integration
