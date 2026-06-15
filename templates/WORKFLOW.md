# Weave Workflow Reference

Canonical reference for `wv` — the task graph CLI for AI coding agents. Full docs: `wv guide` (MCP)
| Command list: `wv --help` | Focused help: `wv help <command>` or `wv <command> --help`

## Core Workflow

```txt
wv bootstrap --json               # 0. Session snapshot — status + active + context + ready + learnings
wv search "<topic>"               # 1. Check for existing related work before claiming/creating
wv ready                          # 2. Find unblocked work
wv work <id>                      # 3. Claim it (sets active, enters execute phase)
# ... do the work ...
git commit                        # 4. Commit work files — prepare-commit-msg appends Weave-ID: <id>
wv done <id> --learning="..."     # 5. Complete with learnings (requires attributed commit + evidence)
wv sync --gh                      # 6. Sync graph + GH (may dirty .weave/)
git add .weave/ && git commit     # 7. Commit graph state if dirty
git push                          # 8. MANDATORY before session end
```

Never edit a file without an active node. If `wv status` shows 0 active, run `wv work <id>` or
create a node first.

`wv bootstrap --json` replaces 7 separate calls at session start (see Token Awareness). For a quick
mid-session check, use `wv status` (~31 tokens). `git status && wv status` is the manual fallback
when bootstrap is unavailable.

**Sandbox shells:** if `wv` is not on PATH (e.g. Codex sandboxes omit `~/.local/bin`), use the
repo-local `./scripts/wv` wrapper — it appends `$HOME/.local/bin` and `$HOME/.cargo/bin` itself. The
Weave Makefile targets apply the same PATH fallback, so `make wv-*` and `make check` work without
shell configuration.

**Step 4 — commit attribution:** The `prepare-commit-msg` git hook (installed by `wv-init-repo`)
appends `Weave-ID: <id>` to every commit message automatically. `wv done` verifies this attribution
exists; if the hook was not installed, add the trailer manually or run
`git commit --amend -m "$(git log -1 --format=%B) Weave-ID: <id>"` before closing.

## Commands

| Command                    | What it does                                                                                                           | Key flags                                                                                                      |
| -------------------------- | ---------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| `wv ready`                 | List unblocked work                                                                                                    | `--json`, `--count`                                                                                            |
| `wv work <id>`             | Claim node (sets active); use `--reopen` for done nodes                                                                | `[--reopen]` to explicitly reopen a done node back to tracked work                                             |
| `wv add "<text>"`          | Create node                                                                                                            | `--gh`, `--status=`, `--parent=`, `--alias=`, `--standalone`                                                   |
| `wv done <id>`             | Complete node (auto-closes linked GH issue)                                                                            | `--learning="..."`, `--no-overlap-check`, `--no-gh`                                                            |
| `wv ship <id>`             | Done + sync in one step; pending Git sync is surfaced separately                                                       | `--learning="..."`, `--no-gh`, `--no-overlap-check`                                                            |
| `wv update <id>`           | Modify node                                                                                                            | `--status=`, `--text=`, `--alias=`, `--metadata=`, `--metadata-file=`, `--echo`                                |
| `wv overview`              | Compact graph/session snapshot                                                                                         | `--json`                                                                                                       |
| `wv help <command>`        | Focused help for one command                                                                                           | Also available as `wv <command> --help`                                                                        |
| `wv bootstrap`             | Session-start composite: status + active + context + ready + learnings                                                 | `--json` (run-cached, 45s TTL)                                                                                 |
| `wv touch`                 | Fire-and-forget intent write (zero stdout)                                                                             | `--intent="TEXT"`, `--files=path1,path2` (record edited paths in node_files)                                   |
| `wv quick "<text>"`        | Track trivial work (create active → commit → done)                                                                     | `--learning="..."`                                                                                             |
| `wv show <id>`             | Node details + blockers                                                                                                | `--json`                                                                                                       |
| `wv list`                  | Non-done nodes — capped 50 (~120 tok). Always emits alternatives footer. Prefer `wv ready` / `wv query` / `wv search`. | `--all`, `--status=`, `--json`                                                                                 |
| `wv block <id> --by=<id>`  | Add dependency edge                                                                                                    | `--context='{...}'`                                                                                            |
| `wv tree`                  | Epic → feature → task hierarchy                                                                                        | `--active`, `--depth=N`, `--mermaid`                                                                           |
| `wv path <id>`             | Ancestry chain                                                                                                         | `--format=chain`                                                                                               |
| `wv plan <file>`           | Import markdown as epic + tasks                                                                                        | `--sprint=N`, `--gh`, `--dry-run`                                                                              |
| `wv context <id> --json`   | Context pack (blockers, ancestors, pitfalls)                                                                           | Cached per session                                                                                             |
| `wv search <query>`        | Full-text search across graph nodes                                                                                    | `--json`, `--status=`                                                                                          |
| `wv index [path]`          | Index code files into brain.db for hybrid search                                                                       | `--ext=`, `--no-embed`, `--json`                                                                               |
| `wv search --code <query>` | Hybrid code search (BM25 + cosine RRF) over indexed chunks                                                             | `--mode=hybrid\|fts\|vector`, `--graph`, `--json`                                                              |
| `wv status`                | Compact status (active/ready/blocked counts)                                                                           |                                                                                                                |
| `wv learnings`             | Show captured decisions/patterns/pitfalls                                                                              | `--category=`, `--grep=`, `--dedup`                                                                            |
| `wv link <from> <to>`      | Create semantic edge                                                                                                   | `--type=`, `--context='{...}'`                                                                                 |
| `wv unlink <from> <to>`    | Remove a semantic edge                                                                                                 | `--type=`                                                                                                      |
| `wv edges <id>`            | Inspect all edges touching a node                                                                                      | `--type=`, `--json`                                                                                            |
| `wv related <id>`          | Explore N-hop neighborhood of a node                                                                                   | `--type=`, `--direction=`, `--depth=N`, `--json`                                                               |
| `wv refs <file\|-t text>`  | Extract Weave node references from text; optionally create edges                                                       | `--link`, `--from=<id>`, `--json`, `--max=N`                                                                   |
| `wv health`                | System health check with score                                                                                         | `--json`, `--verbose`, `--fix`, `--history[=N]`                                                                |
| `wv audit-pitfalls`        | List all pitfall learnings with resolution status                                                                      |                                                                                                                |
| `wv guide`                 | Workflow quick reference (in-terminal cheat sheet)                                                                     | `--topic=workflow\|github\|learnings\|context\|routing\|mcp\|verification\|instrumentation\|config\|discovery` |
| `wv reindex`               | Rebuild the full-text search index                                                                                     |                                                                                                                |
| `wv sync`                  | Dump to `.weave/state.sql`                                                                                             | `--gh` for GH sync, `--mode=fast\|full\|repair`, `--node=<id>`, `--dry-run`                                    |
| `wv load`                  | Restore from `.weave/state.sql`                                                                                        | Run by session start hook                                                                                      |
| `wv prune`                 | Archive done nodes >48h                                                                                                | `--age=`, `--orphans-only`, `--dry-run`                                                                        |
| `wv unarchive <id>`        | Restore a pruned node from `.weave/archive/` to live graph                                                             | `--dry-run`                                                                                                    |
| `wv quality scan`          | Scan repo for complexity + churn                                                                                       | `--exclude=`, `--json`                                                                                         |
| `wv quality hotspots`      | Ranked hotspot report                                                                                                  | `--top=N`, `--json`                                                                                            |
| `wv findings <sub>`        | Historical finding promotion/list workflow                                                                             | `list`, `promote`                                                                                              |
| `wv query [pred...]`       | Predicate-based graph reader (key=val, HAS, MATCH, IN, edge-type=)                                                     | `--format=table\|json\|short`, `--limit=N`, `--order=recent\|hygiene`                                          |
| `wv session-summary`       | Session hygiene score (0-100) + nodes created/completed/learnings                                                      |                                                                                                                |
| `wv digest`                | One-line health summary (cheaper than `wv health`)                                                                     | `--json`                                                                                                       |
| `wv cache`                 | Claude prompt-cache diagnostics (read vs creation ratio per session)                                                   | `--sessions=N`, `--all`, `--json`                                                                              |
| `wv hotzone list`          | List all active graph DB directories with node count and owner                                                         | `--json`                                                                                                       |
| `wv hotzone gc`            | Remove orphan hot-zone directories (no matching live repo)                                                             | `--dry-run`                                                                                                    |
| `wv compact`               | Delete replayed delta files after safety checks                                                                        | `--older-than=Nd`, `--dry-run`                                                                                 |
| `wv doctor`                | Installation health check (deps, hooks, ghost settings, matchers)                                                      | `--json`, `--repair`                                                                                           |
| `wv recover`               | Resume interrupted ship/sync flows; list orphaned active nodes                                                         | `--auto`, `--session`, `--json`                                                                                |
| `wv delete <id>`           | Permanently remove a node (closes linked GH issue)                                                                     | `--force`, `--dry-run`, `--no-gh`                                                                              |
| `wv preflight <id>`        | Machine-readable blockers, contradictions, readiness check for a node                                                  | returns JSON                                                                                                   |
| `wv clean-ghosts`          | Remove edges that reference deleted nodes                                                                              | `--dry-run`                                                                                                    |
| `wv edge-types`            | List valid semantic edge types with live edge counts                                                                   | `--stats`, `--json`                                                                                            |
| `wv self-update`           | Refresh installed wv from source clone recorded at install time                                                        |                                                                                                                |

`--standalone` persists `metadata.standalone=true`. `wv health` excludes intentional standalones
from `orphan_nodes` and reports them separately as `intentional_standalones`.

## Node Statuses

| Status             | Meaning                              |
| ------------------ | ------------------------------------ |
| `todo`             | Ready unless blocked                 |
| `active`           | Claimed, in progress                 |
| `done`             | Completed — auto-unblocks dependents |
| `blocked`          | Waiting on another node              |
| `blocked-external` | Waiting on external dep (API, human) |

Lifecycle: `todo` → `active` → `done`. Set `blocked` via `wv block`.

## Context Packs

Run `wv context <id> --json` before starting complex work:

- **Cached per session** — second call is ~40% faster
- **Auto-invalidates** — cache clears when edges change
- **Limited output** — top 5 related, top 3 pitfalls (prevents context explosion)
- **Nested learnings** — ancestors include decision/pattern/pitfall from metadata

## Edge Context

Edges carry a `context` JSON field. Auto-generated summaries use node aliases and are marked
`auto: true`. For edges with semantic meaning, provide explicit context:

```bash
wv link wv-A wv-B --type=blocks --context='{"reason":"Auth API must deploy before client"}'
wv block wv-A --by=wv-B --context='{"reason":"Depends on schema migration"}'
wv resolve A B --winner=A --rationale="Winner has broader scope"
```

- **Auto-context** (`{"summary":"fix-auth blocks deploy","auto":true}`) — scannable at a glance
- **Explicit context** (`{"reason":"..."}`) — semantic, non-derivable, always preserved on re-link
- **Backfill** — `wv health --fix` enriches all empty edges with auto-context

## Epic Decomposition

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

## GitHub Integration

```bash
wv add "Fix auth bug" --gh          # Create node + GH issue (linked)
wv done <id>                        # Closes node AND linked GH issue
wv sync --gh                        # Sync all nodes ↔ GH issues
```

Always use `--gh` when work should be visible in GitHub. `wv done` auto-closes linked issues.

### Sync modes (`--mode=fast|full|repair`)

`wv sync --gh` accepts a mode flag that controls scope and recovery behaviour:

| Mode     | When                                                                 | Behaviour                                                                                                             |
| -------- | -------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| `fast`   | Default for `wv ship` and `session-end-sync.sh`                      | Bounded to focus node + parent + children + blockers; skips Phase 2/3                                                 |
| `full`   | Manual exhaustive reconcile; suspected drift; bulk import            | Walks every node and issue (slowest, most thorough)                                                                   |
| `repair` | After a timeout/Ctrl-C/crash mid-sync — `wv recover` recommends this | Same scope as `full` but resumes from `.weave/repair-checkpoint.json`; SIGINT/SIGTERM print the resume hint to stderr |

The checkpoint is removed on clean completion. To reset it manually:

```bash
rm -f .weave/repair-checkpoint.json
wv sync --gh --mode=full
```

## Learnings

```bash
wv done <id> --learning="decision: what was chosen | pattern: reusable technique | pitfall: gotcha to avoid"
```

Good learnings are specific, actionable, and scoped to a concrete context.

## Quality Gate — GraphPolicyViolation

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

## Repair Workflow

When you detect a real workflow issue during execution (drift, missing guardrail, broken prompt/doc,
close-time friction), turn it into tracked remediation immediately:

1. **Decide whether it belongs in the current node**
   - Fix it in the current node only if it is required to complete the current task safely.
   - Otherwise create follow-up work instead of expanding scope silently.
2. **Create remediation work in the graph**
   - Use `wv add "Task: ..." --gh --parent=<feature-or-epic>` for discovered repair work.
   - If the current task cannot finish without the repair, block it:
     `wv block <current> --by=<new>`.
   - If the repair is related but not blocking, link it with
     `wv link <new> <current> --type=relates_to`.
3. **Leave a trail for the next step**
   - Save what was detected, what was created, and what should happen next with `wv trails save`.
4. **Avoid unattended close-time stalls**
   - For non-interactive agent flows, prefer recording pending-close state and surfacing
     `needs_human_verification` rather than blocking indefinitely on stdin prompts.
   - Humans can resume and approve explicitly; agents should stop in a resumable state, not hang.
5. **Classify errors before retrying**
   - Transient (network blip, lock contention, flaky test): retry once with brief backoff; if it
     fails again, escalate rather than loop.
   - Blocker (missing dependency, broken invariant, unresolved conflict): create a recovery node
     with `wv add "Fix: ..." --parent=<current>`, block current work with `wv block`, and surface
     the blocker clearly.
   - User-required (ambiguous spec, insufficient permissions, policy decision): stop and surface the
     gap explicitly. Do not guess or paper over it — unresolved ambiguity compounds into larger
     failures downstream.

## Rules

1. **Track ALL work** — `wv work <id>` or
   `wv add "<text>" --status=active --criteria="c1|c2" --risks=low` before editing files. Use `--gh`
   for GitHub-linked work. Use `--parent=<epic-id>` for sub-tasks — this is **mandatory**, not
   optional (see Epic Decomposition). Never edit without an active node.
2. **No untracked fixes** — even one-line changes get a node. Use `wv quick "<what>"` for trivial
   work.
3. **GitHub workflow** — create with `--gh`, close with `wv done` (auto-closes issue). Check
   `gh issue list` before session end.
4. **Sync + push mandatory** — `wv sync --gh` then `git push` before session end. Commit
   incrementally after each logical unit, not all at the end.
5. **Check context** — run `wv context <id> --json` before starting complex work.
6. **IDs are `wv-xxxxxx`** (4-6 hex chars). Use exact IDs from `wv ready`.
7. **Capture learnings** — use `--learning="..."` on `wv done` for non-trivial work.
8. **Bound session scope** — limit to 4-5 tasks per session. Context limits kill sessions mid-task.
9. **No hook bypass** — never use `--no-verify` or `WV_SKIP_PRECOMMIT=1`.
10. **No duplicate background commands** — before issuing any long-running command (`make check`,
    `wv sync --gh`, `npm run build`, `git push`), verify it is not already running. If a command
    goes to background, wait for its completion notification before re-issuing. Running the same
    command twice causes double syncs, wasted CI time, and conflicting writes.
11. **Graph records intent, conversation implements it** — before discussing what to do next, create
    the node. Intent not in the graph does not survive a crash or reboot.

    ```
    # Correct: node first, then discuss
    wv add "sync-state visibility" --parent=<epic>  →  then plan and implement

    # Wrong: intent lives only in chat
    "Item 2 is sync-state visibility — here's the plan..."  [session ends — intent lost]
    ```

12. **Verify assumptions before acting** — before relying on a file path, function name, API, or
    structure that has not been read in this session, grep or read to confirm it exists and matches
    expectations. Do not propagate unvalidated beliefs across multiple steps. If prior context was
    summarised or compacted, treat named artefacts as unverified until re-read.
13. **Sprint decomposition discipline** — when breaking a proposal into graph nodes:
    - Use the **proposal's sprint labels verbatim** in node text (`task(S2): ...` not `task(S3):`).
    - Set `done_criteria` and `risks` on **all nodes before claiming any** — use `--criteria=` /
      `--risks=` on `wv add` or batch-update immediately after creation.
    - The pre-claim hook passes silently when `done_criteria` is set at creation time. Leaving it
      unset turns every `wv work` call into a multi-turn planning interrupt.

    ```bash
    # Good: claim-ready nodes, set at decomposition time
    wv add "task(S2): --mode= flag on wv show" --parent=$FEAT \
      --criteria="--mode= parsed|bootstrap=id+text+status|make check passes" --risks=low

    # Bad: metadata deferred to claim time (triggers hook on every wv work)
    wv add "task(S2): --mode= flag on wv show" --parent=$FEAT
    ```

**Violation check:** If `wv status` shows 0 active nodes, STOP and claim one first.

## Session Context Management

Every turn is a branching point. Default "continue" accumulates context rot — performance degrades
around 300-400k tokens. Make deliberate choices:

### The 5-Option Framework

| Option       | When to use                                         | Weave action                                              |
| ------------ | --------------------------------------------------- | --------------------------------------------------------- |
| **Continue** | Current approach is working, context is fresh       | Keep going                                                |
| **Rewind**   | Failed approach — tool errors, wrong path, dead end | Rewind to before the attempt (see below)                  |
| **Compact**  | Context growing but direction is clear              | `/compact focus on <current task>, drop <completed work>` |
| **/clear**   | Task complete, starting unrelated work              | `wv trails save` → `/clear` → reload                      |
| **Subagent** | Work produces intermediate output you won't need    | Delegate, keep only the conclusion                        |

### Rewind — The Most Important Habit

After a failed approach, **rewind to before the attempt** instead of correcting in context. Failed
tool calls, error output, and dead-end reasoning pollute the context window with noise that
compaction cannot reliably clean.

**When to rewind:**

- First failed approach to a problem (don't wait for 2-3 failures)
- Tool errors that produced large output you'll never reference
- Wrong architectural direction discovered after significant exploration

**How to rewind:**

1. Before the risky attempt: `wv trails save --message="About to try X, current state is Y"`
2. After failure: use your client's rewind/undo feature to roll back to before the attempt
3. After rewinding: capture what you learned:
   `wv done <id> --learning="pitfall: X failed because Y"`
4. Start the fresh approach with clean context

If your client does not support rewind, use `/clear` with a saved trail instead — a fresh session
with captured learnings is better than a polluted context window.

### Compact Steering

Compaction is lossy — the model decides what mattered, and it does so at its least intelligent point
(context is full, attention is diluted). Steer it:

```
/compact focus on: <active task description>, current approach, open blockers
       drop: completed work, exploratory dead ends, verbose tool output
```

**Proactive compaction** beats reactive: compact early when you have a clear direction, not at the
limit when quality is lowest. After compaction, verify critical state survived:

```bash
wv status               # confirm active node is still known
wv context <id> --json  # reload context pack (rule 12: treat as unverified)
```

### Session Phases

The enforcement layer uses a three-phase state machine. Understanding phases explains why some edits
are blocked and others are not.

| Phase      | Set by             | Active-node check                 | Triggered by                               |
| ---------- | ------------------ | --------------------------------- | ------------------------------------------ |
| `discover` | session-start hook | edit-class tools blocked          | Session start — exploring before claiming  |
| `execute`  | `wv work <id>`     | enforced (hard block if 0 active) | Node claimed, substantive work in progress |
| `closing`  | `wv done <id>`     | skipped                           | Node just closed — allows follow-up commit |

The phase is stored in `.session_phase` in the hot zone and survives across tool calls within a
session. Default when no sentinel exists: `execute` (safe, enforcing).

**Common surprises explained by phases:**

- Reads and searches immediately after session start are allowed — you are in `discover`, but
  edit-class tools still require `wv work <id>` first.
- After `wv done`, you can commit the changes without a new active node — you are in `closing`.
- If you see "No active Weave node found (phase: execute)", you skipped `wv work` or the session
  epoch check blocked a stale inherited node — run `wv work <id>` to re-claim.

**Stale node detection:** `pre-action.sh` compares the active node's `updated_at` against the
session epoch. A node active from a prior session (crashed or abandoned) blocks edits until
explicitly re-claimed: `wv work <id>`. This prevents silently inheriting in-flight work.

### Subagent Delegation

Delegate when the work produces intermediate output you won't need again. Mental test: _"Will I need
this tool output, or just the conclusion?"_

| Delegate                                 | Keep in context                               |
| ---------------------------------------- | --------------------------------------------- |
| Verification runs (test suites, linters) | Architecture decisions being made now         |
| Research into unfamiliar code            | Active debugging with iterative fixes         |
| Documentation generation                 | Code changes requiring cross-file consistency |
| Bulk file operations                     | Conversations requiring user feedback         |

### Session Scope

Use the same session for **related** work where shared context carries value. Start a fresh session
for **independent** work. The 4-5 task limit (rule 8) assumes related tasks — independent tasks
should each get a fresh session to avoid cross-contamination.

**Signs you need a fresh session:**

- Context has been compacted 2+ times
- You're working on a different epic or feature than where you started
- Tool output from prior tasks is cluttering the window
- You catch yourself re-explaining context that should be obvious

### Token Awareness

Weave tracks output volume for every `wv` CLI call. Use this to understand your actual token costs:

```bash
# Enable call logging (add to shell profile for persistence)
export WV_CALL_LOG=~/.local/share/weave/wv_calls.jsonl

# View top commands by output volume
wv analyze sessions --call-stats          # ranked table with ~token estimates (lifetime aggregate)
wv analyze sessions --call-stats --top=5 --since-days=1 --source=agent  # session retro form
```

For a session retro, always pass a window AND `--source=agent`: unwindowed output mixes
instrumentation eras, and without the source filter high-frequency hook calls (small, filtered,
mostly never entering context) dominate the counts and misread as agent behavior.

**Known token costs** (measured values):

| Command        | Avg output                      | Purpose                                          |
| -------------- | ------------------------------- | ------------------------------------------------ |
| `wv touch`     | 0 B                             | Intent write — zero tokens                       |
| `wv status`    | ~125 B (~31 tok)                | Status check — cheapest read                     |
| `wv show`      | ~540 B (~135 tok)               | Node detail                                      |
| `wv list`      | ~120 tok (capped 50; done: 100) | Full dump — prefer `wv query` for targeted reads |
| `wv context`   | ~850 B (~212 tok)               | Context pack                                     |
| `wv ready`     | ~1.2 KB (~300 tok)              | Unblocked work                                   |
| `wv bootstrap` | ~2.2 KB (~547 tok)              | Session-start composite — replaces 7 calls       |
| `wv learnings` | ~4.5 KB (~1,138 tok)            | Captured knowledge (heaviest per-call)           |

Use `wv bootstrap --json` at session start (run-cached, single call). Use `wv status` for routine
checks. Reserve `wv learnings` for targeted `--grep=` queries.

**Targeted reads — prefer `wv query` / `wv search` over `wv list`:** `wv list` is capped at 50 items
(~120 tok/call) but is still called 900+ times/day by reflex. Each call now emits an alternatives
footer. Use targeted tools — they answer the same questions with less noise:

```bash
wv query 'status=active'                  # nodes by predicate (exact, ~600 tok)
wv query 'type=finding stale>=7'          # compound filter
wv search "<topic>"                       # fuzzy FTS5 by subject (~600 tok)
wv query 'id IN (wv-abc,wv-def)'          # pin a known set (single-quote the predicate)
```

Full discovery toolset reference: `wv guide --topic=discovery`

### Code Search

Two search surfaces, different signals:

| Command                      | Searches     | Use for                                             |
| ---------------------------- | ------------ | --------------------------------------------------- |
| `wv search "<topic>"`        | Graph nodes  | Prior decisions, findings, learnings, task history  |
| `wv search --code "<query>"` | Source files | Implementation location, function names, call sites |

Hybrid hunt pattern (highest signal):

```bash
wv search "auth"             # 1. What decisions/findings exist about auth?
wv search --code "auth"      # 2. Where is auth implemented?
wv learnings --grep="auth"   # 3. What pitfalls were hit?
```

Run `wv index` once per repo to enable `--code` mode (builds BM25 + vector index).

**No-index code search** — consumer's choice:

- `weave_code_search` (MCP) — Weave built-in, same hybrid ranking
- Semble: `semble search "<query>" <dir>` (CLI) or `mcp__semble__search` (MCP, pass `repo` param)
- Any tool works: ripgrep, semgrep, ast-grep, language server — Weave has no opinion here

### Ready Re-ranking

`wv ready` re-ranks unblocked nodes by overlap between `metadata.touched_files` and the per-session
recent-edits ring (last 20 edited paths, stored on tmpfs by `wv-touched-files` hook). Boosted nodes
show a green `[touched N]` marker in text output; JSON output re-orders silently.

After editing `scripts/cmd/wv-cmd-data.sh`, nodes whose `touched_files` include that path float to
the top — work already warm in file context surfaces first. Falls back to `created_at ASC` when no
edits have been made yet.

This signal is passive: it updates automatically as you edit files. No configuration needed.

**When markers appear:** `[touched N]` fires only after the first `PostToolUse` hook in the session
populates the recent-edits ring (Edit/Write tool calls; Bash reads do not count). Cold sessions and
the first `wv ready` invocation show nodes in `created_at` order with no markers. JSON output
silently sorts by overlap when present; falls back to `created_at` order otherwise.

## Graph Hygiene

Run `wv health` periodically to catch drift. Key maintenance commands:

```bash
wv health                        # score + orphan/ghost-edge counts
wv prune --age=7d --dry-run      # preview stale done nodes
wv prune --age=7d                # archive done nodes not updated in 7 days
wv prune --orphans-only          # archive done nodes with no edges (ignores age)
wv unarchive <id> --dry-run      # preview restoring a pruned node
wv unarchive <id>                # restore a pruned node to the live graph
```

**`--orphans-only` vs `--age=`:**

- `--age=Nd` uses `updated_at` — misses nodes touched today by `wv sync --gh`
- `--orphans-only` targets unlinked done nodes regardless of age — use this after a sync that
  bulk-closed nodes, or after a graph repair session

**Before pruning, classify orphans first:**

1. Garbage/test fixtures → `wv delete <id>`
2. Real work without a parent → `wv link <id> <epic> --type=implements`
3. Legitimate standalones (releases, chores) → create them with `--standalone`, or annotate retained
   history with `wv update <id> --metadata='{"standalone":true}'`; `wv health` reports these as
   `intentional_standalones`, not `orphan_nodes`
4. Archive intentional standalones only when you actually want them removed from the live graph →
   `wv prune --orphans-only`

**Stale test/smoke nodes** pollute `wv ready` and the ready-work signal. Audit periodically:

```bash
wv list --status=todo --json \
    | jq -r '.[] | select(.text | test("^(smoke|Bench|Test)"; "i")) | .id + ": " + .text'
```

Delete with `wv delete <id> --force`.

## Pre-commit Test Gate & CI Hygiene

`wv init-repo` scaffolds two optional, consumer-tunable files for a fast, low-noise gate:

- **`scripts/test-impacted.sh`** (seeded if-absent) — a fast, impact-scoped pre-commit test runner.
  It inspects the STAGED sources and runs the test command on ONLY their mirror test dirs (nearest
  existing ancestor), falling back to the full suite when nothing resolves. Edit the CONFIG block
  (`SRC_PREFIX`/`TEST_ROOT`/`RUNNER`/`RUN_ENV`) per repo, then route sources to it in
  `.weave/test-map.conf` (glob/prefix/`[default]` keys, wv 1.60.0+):

  ```ini
  [map]
  src/ = scripts/test-impacted.sh
  ```

  Origin (earth-engine-analysis test-bed): cut a localized change from 6.2s/1385 tests to ~1.1s. It
  is never overwritten on `--update` — it carries per-repo edits.

- **`.weave/ci-weave-paths-ignore.snippet.yml`** (refreshed on `--update`) — reference snippet
  recommending a `paths-ignore: ['.weave/**']` rule on each workflow trigger. Prefer this over the
  `[skip ci]` commit token: GitHub scans the whole message for `[skip ci]`, so a real commit that
  merely mentions the token self-skips. `paths-ignore` keys on changed files — pure-`.weave/` pushes
  skip while mixed code+`.weave/` pushes still run.

## Session End Behavior

The stop hook has one hard block; everything else soft-warns:

- **Active node open** → hard block. Close with `wv done <id> --learning="..."` first.
- **Uncommitted changes** → soft warning, does not block.
- **Unpushed commits / dirty .weave/** → soft warning. Run `git push` or `/close-session`.

No network calls in the hook (wv sync / git push belong in `/close-session`, not stop hook). The
`/close-session` skill handles the full protocol (sync, commit, push). Only invoke it when you're
actually done — a soft warning is not a signal to stop working.

## Skills

- `/weave [<id>|<text>]` — Graph-first orchestrator (primary interface)
- `/trails [<id>]` — Session memory capsule
- `/close-session` — End-of-session sync + push protocol

### Local Skills

Create project-specific skills by adding a `SKILL.md` file in `.claude/skills/<name>/`:

```bash
mkdir -p .claude/skills/my-skill
cat > .claude/skills/my-skill/SKILL.md << 'EOF'
---
name: my-skill
description: "What it does. Use when <trigger condition>."
---

# My Skill

Instructions here. Agents that support .claude/skills/ discover this automatically.
EOF
```

- **Skills** are auto-discovered from `.claude/skills/` by supporting agents (Claude Code, etc.) —
  no registration needed
- **Agents without skill support** (e.g. VS Code Copilot) use MCP tools or `copilot-instructions.md`
  instead
- Local skills are committed to git and shared with your team
- `wv init-repo --update` preserves user-created skills (only updates Weave-shipped ones)

## Agents

The default `weave` MCP server exposes all 40 tools. When `weave-inspect` is also registered,
read-only agents can use its 17-tool inspect subset.

- **weave-guide** — Workflow best practices, anti-patterns (session lifecycle tools)
- **epic-planner** — Strategic planning, scope, dependencies, risks (graph mutation tools)
- **learning-curator** — Extract learnings, retrospective analysis (read-only inspect tools)
