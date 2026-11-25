#!/bin/bash
# wv-cmd-help.sh — command help, help topics and the workflow guide
#
# Commands: help, guide (and the help-topic dispatcher)
# Sourced by: wv entry point (autoloaded on first use)
# Dependencies: wv-config.sh; delegates <cmd> --help to the module defining <cmd>
#
# Moved unchanged from wv-cmd-ops.sh (wv-71933b, the wv-c153c4 split) so a change
# here routes only to the suites that exercise help and guide.

# ═══════════════════════════════════════════════════════════════════════════
# ═══════════════════════════════════════════════════════════════════════════
# cmd_guide — Quick workflow reference
# ═══════════════════════════════════════════════════════════════════════════

cmd_guide() {
    local topic="" procedure=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --topic=*) topic="${1#*=}" ;;
            --procedure=*) procedure="${1#*=}" ;;
            --help|-h) cmd_help guide; return 0 ;;
            -*) _wv_reject_arg guide "$1"; return 1 ;;  # wv-016983
        esac
        shift
    done

    if [ -n "$procedure" ]; then
        if [[ ! "$procedure" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
            echo "Error: invalid procedure id '$procedure'" >&2
            return 1
        fi
        # A repository's own procedure replaces the package one of the same id
        # here (wv-fc71f0); wv-cmd-procedures.sh resolves it, and loads only
        # when the repository has one.
        local procedure_file="${WV_CONFIG_DIR:-$HOME/.config/weave}/procedures/${procedure}.md"
        if [ -n "${REPO_ROOT:-}" ] && [ -f "$REPO_ROOT/.weave/procedures/${procedure}.md" ]; then
            procedure_file=$(_wv_repo_procedure_file "$procedure") || return 1
        fi
        if [ ! -f "$procedure_file" ]; then
            echo "Error: unknown procedure '$procedure' (not in .weave/procedures and not installed: $procedure_file)" >&2
            return 1
        fi
        cat "$procedure_file"
        return 0
    fi

    case "$topic" in
        workflow|"")
            cat <<'EOF'
Weave Workflow Quick Reference

  0. CLI path:     if ! command -v wv >/dev/null 2>&1; then wv() { ./scripts/wv "$@"; }; fi
  1. Snapshot:     wv bootstrap --json
  2. Find work:    wv ready
  3. Claim it:     wv work <id>
  4. Do the work   (edit files, run tests)
  5. Complete:     wv done <id> --learning="decision: ... | pattern: ... | pitfall: ..."
  6. Sync:         wv sync --gh
  7. Commit state: git add .weave/ && git diff --cached --quiet || git commit -m "chore(weave): sync state [skip ci]"
  8. Push:         git push

Create new work:
  wv add "Description"               # standalone node
  wv add "Description" --gh          # node + GitHub issue (linked)
  wv add "Task" --parent=<epic-id>   # child of an epic

Topics: wv guide --topic=github | learnings | context | routing | mcp | verification | instrumentation | config | discovery
EOF
            ;;
        github)
            cat <<'EOF'
Weave GitHub Integration

Create with a linked issue (atomic):
  wv add "Fix auth bug" --gh         # creates node + GH issue, links them

Close (auto-closes linked GH issue):
  wv done <id> --learning="..."      # closes node + linked GH issue

Ship (done + sync in one; pending Git sync is surfaced separately):
  git add <files> && git commit -m "..."   # commit code first
    wv ship <id> --learning="..."            # close + sync; check status for Git sync

Sync epic bodies / Mermaid diagrams:
  wv sync --gh                       # full bidirectional sync

Check GitHub sync status:
    gh issue list --state open --limit 200 --json number,title,labels \
        | jq '[.[] | select(any(.labels[]?.name; . == "weave-synced")) | {number:.number,title:.title}]'
  wv show <id> --json | jq '.[0].metadata | fromjson | .gh_issue'

Label taxonomy applied automatically:
  weave-synced   all Weave-linked issues
  epic           nodes with child tasks
  task           leaf task nodes
EOF
            ;;
        learnings)
            cat <<'EOF'
Weave Learnings

Capture on close (preferred format):
  wv done <id> --learning="decision: What was chosen and why | pattern: Reusable technique | pitfall: Specific mistake to avoid"

Or via metadata before closing:
  wv update <id> --metadata='{"decision":"...","pattern":"...","pitfall":"...","verification_evidence":"..."}'
  wv done <id>

Good learnings are:
  Specific  — not "be careful with X" but "X fails when Y because Z"
  Actionable — includes the fix, not just the problem
  Scoped    — tied to a concrete context, not generic advice

View learnings:
  wv learnings                          # all
  wv learnings --category=pitfall       # pitfalls only
  wv learnings --grep="sqlite"          # search
  wv learnings --recent=5               # last 5
  wv learnings --node=<id>              # for one node
  wv audit-pitfalls                     # unresolved pitfalls (top 20; --all for everything)
EOF
            ;;
        context)
            cat <<'EOF'
Weave Context Policy

Session start injects a policy based on repo size (wv context-policy prints the current
level and its directives):
EOF
            _context_policy_levels_text
            cat <<'EOF'

Editing: open a file with your harness's native file-read before editing it. Shell reads
(cat/grep/sed) and code-search are for inspection only — they do NOT satisfy edit-guards, so
editing a file you only inspected via a shell command is blocked ("File has not been read").
Grep/partial-read to find the spot; native-read the file you will change.

Context Pack (before complex work):
  wv context <id> --json | jq .
  Returns: node, blockers, ancestors, related nodes, pitfalls, contradictions

Scope rules:
  - Max 4-5 tasks per session (context limits kill mid-task)
  - Check wv status before editing — 0 active nodes means create one first
  - Run wv context before starting complex work to see pitfalls + ancestors
EOF
            ;;
        routing)
            cat <<'EOF'
Weave Routing Model

Runtime phase loop:
    BOOTSTRAP / DISCOVER → EXECUTE → SYNTHESIZE → BOOTSTRAP

DISCOVER quality floor:
    Before DISCOVER can advance to EXECUTE, gather discovery evidence with local read tools:
    read, grep, glob

Tool classes:
    READ_ONLY_TOOLS     — read, grep, glob, ls, wv_show, wv_context, wv_search, wv_tree, wv_learnings
    EXECUTE_TRIGGERS    — edit/write/bash or any mutation request that makes the next step unavoidable
    SYNTHESIZE_TRIGGERS — wv_done, wv_ship, close/handoff work after execution

Bootstrap depth:
    DISCOVERY mode — status line only (~50 tokens), best when no active node exists
    EXECUTION mode — full context pack, truncated to runtime budget (~3000 chars)

Practical CLI guidance:
    - Stay cheap first: read/grep/glob before bash or edit when you're still locating the control path
    - Claim work before mutation: wv ready → wv work <id> → wv context <id> --json
    - Use wv touch <id> --intent="..." for low-token progress checkpoints between larger steps
    - Close with structure: wv done <id> --learning="decision: ... | pattern: ... | pitfall: ..."

Token-saving pattern:
    Discovery turn   — wv bootstrap --json, grep, read small slices
    Execution turn   — edit the local slice, run one focused validation
    Synthesis turn   — wv update verification metadata, then wv done / wv ship
EOF
            ;;
        mcp)
            cat <<'EOF'
Weave MCP Server

The MCP (Model Context Protocol) server exposes Weave tools to AI clients.

Install & build:
  cd mcp && npm install && npm run build

Configure in your MCP client (e.g. Claude Desktop, VS Code):
  Command: node /path/to/mcp/dist/index.js
  Env: WV_PROJECT_ROOT=/path/to/your/repo

Key compound tools (prefer over multiple CLI calls):
  weave_overview  — status + health + ready work (session start overview)
  weave_bootstrap — single-call session context (wv bootstrap --json)
  weave_work      — claim node + return context pack
    weave_ship      — done + sync in one step; Git sync is surfaced separately
  weave_quick     — create + close trivial task in one call
  weave_preflight — pre-action checks before starting work
  weave_plan      — import markdown plan as epic + tasks

Other tools:
  weave_add, weave_done, weave_batch_done, weave_update, weave_list,
  weave_link, weave_tree, weave_context, weave_search, weave_resolve,
  weave_learnings, weave_guide, weave_status, weave_health, weave_sync,
  weave_trails (alias: weave_breadcrumbs), weave_close_session

CLI vs MCP:
  - MCP: fewer round-trips (compound tools), typed JSON responses
  - CLI: full command set, scripting, pipe-friendly, env var config
  - Both use the same SQLite graph — changes are visible to either
EOF
            ;;
        verification)
            cat <<'EOF'
Weave Verification Boundary

wv done is the single owner of the "is this correct?" decision. Other surfaces
RUN checks and RECORD outcomes; wv done READS them and decides. It never invokes
a linter or test runner — the close stays fast.

Three surfaces:
  pre-commit   hygiene gate (lint, active-node) + runs light impact suites + records
  pre-push     runs the [heavy] suites the pushed commits owe + records; refuses red
  wv done      reads recorded signals; owns the gate (nodes_policy_check trigger)

Pre-commit pytest behavior:
  If tests/weave_quality/ or tests/weave_indexer/ exists, the hook runs those
  optional focused pytest dirs for staged Python changes. Consumer repos are not
  required to create them; absent dirs are skipped. Repo-local tests should be
  exposed through .weave/test-map.conf as shell suites, e.g.
    src/auth/ee_auth.py = scripts/run-unit-tests.sh

Policy gates (rows in policy_thresholds; enforced only for files in node_files,
quality_exempt paths always skipped):
  mccabe_max[_lang]   block if a touched file's max function CC exceeds the limit
  trend_deteriorating block if a touched file's complexity is deteriorating (default off)
  test_gate           test correctness: 0=off, 1=warn (advisory), 2=block (default off)

Test gate flow:
  1. Record per file:   wv test-record <suite> --files=a,b --exit=N
                        (one row per file; fingerprint = git blob hash)
  2. Map paths->suites: .weave/test-map.conf   (source_file = suite [suite ...])
  3. wv done derives file_test_status per touched file:
       blob == recorded & exit 0  -> green
       blob == recorded & exit !=0 -> red
       blob != recorded            -> stale   (file changed since the run)
       no record / no mapping      -> unknown (never blocks)
  4. Act by level: off=inert | warn=advisory on red/stale | block=ABORT on red/stale

Enable for a repo (default is off/inert) — easiest is the durable toggle:
  wv config enable test-gate warn     # or 'block'; writes quality.conf for you
Or edit DURABLE config directly in .weave/quality.conf:
  [thresholds]
  test_gate = 1            # 1=warn, 2=block
  trend_deteriorating = 1
Committed + re-applied on every `wv load`, so it survives reboot. (brain.db is
tmpfs; policy_thresholds is not in state.sql, so a raw sqlite3 UPDATE is
session-only and resets on cold-start — use quality.conf for durable policy.)
`wv doctor` flags a gate that is set in the DB but not durably configured.

Exemptions: [exempt] patterns in quality.conf; node types finding/epic/session_history;
--skip-verification suppresses the warn advisory (block is a hard gate, not bypassable).

Full reference: docs/WEAVE.md § 4.7.
EOF
            ;;
        instrumentation)
            cat <<'EOF'
Weave Instrumentation & Opt-in Knobs

Two opt-in surfaces ship OFF by default. Turn them on through one front door —
`wv config` — so you never have to memorise an env var name or a file path.

1. Session analysis (which wv commands cost the most output/tokens)
   wv config enable session-analysis     # sets WV_CALL_LOG in config.env
   wv analyze sessions --call-stats --since-days=1   # read the report (windowed)
   wv config disable session-analysis

   Enablement lives in ~/.config/weave/config.env (override dir: WV_CONFIG_DIR)
   and is read from disk on EVERY invocation — CLI and harness-spawned hooks
   alike — so it survives reboot and never depends on env inheritance. With it
   off, the reader says so plainly instead of implying a phantom log path.

2. Verification gate (test-correctness gate on wv done) — repo-scoped
   wv config enable test-gate warn        # or 'block'
   wv config disable test-gate
   See: wv guide --topic=verification   (durability, test-map.conf, exemptions)

Inspect current state any time:
   wv config list      # global knobs + feature on/off + gate durability
   wv doctor           # flags a gate enabled in the DB but not durably configured

Global knobs live in ~/.config/weave/config.env, e.g.:
   WV_CALL_LOG="$HOME/.local/share/weave/wv_calls.jsonl"
   # WV_DELTA_RETAIN_DAYS=14
EOF
            ;;
        config)
            cat <<'EOF'
Weave Config Model

Two config layers:

  User-global (~/.config/weave/config.env)
    Personal knobs — WV_CALL_LOG, WV_SUITE_LOG, WV_DELTA_RETAIN_DAYS, ...
    Read from disk on EVERY invocation (CLI + hooks); survives reboot.
    Not committed to source control. Personal to this machine.

  Repo-committed (.weave/quality.conf [thresholds])
    Team policy — test_gate, mccabe_max, trend_deteriorating
    Loaded by wv load on session start. Commit it to share the policy.

Ownership rule:
  Personal preferences (log paths, verbosity)  -> config.env    (never commit)
  Team policy (gate mode, quality thresholds)  -> quality.conf  (commit it)

Quick reference:
  wv config list                          Show active knobs + feature state
  wv config list --show-origin            Show each value with its source file
  wv config get <KEY>                     Print effective value of a knob
  wv config get <KEY> --show-origin       Print value + which layer provides it
  wv config set <KEY> <VALUE>             Set a WV_* knob in config.env
  wv config unset <KEY>                   Remove a knob from config.env
  wv config enable session-analysis       Write WV_CALL_LOG to config.env
  wv config enable test-gate [warn|block] Write test_gate to quality.conf
                                          and scaffold .weave/test-map.conf
  wv config disable session-analysis | test-gate

Gitignore boundary:
  config.env        personal, never committed
  quality.conf      team policy, commit it to share the gate mode
  quality.local.conf  (planned) gitignored user-per-repo override for
                      personal threshold relaxation without touching quality.conf

Related topics:
  wv guide --topic=verification     test-map.conf, gate flow, exemptions
  wv guide --topic=instrumentation  opt-in knobs, session analysis
EOF
            ;;
        discovery)
            cat <<'EOF'
Weave Discovery Toolset

The ground-truth surface for audit and read-only exploration. These are the tools
to reach for BEFORE editing, not after.

  wv search <q>         FTS5 BM25 over all nodes. Fuzzy — finds "anything about X".
                          --limit=N     (equals-form only; --limit N fails)
                          --status=, --type=, --learning
                          --code        hybrid BM25+cosine over indexed code chunks
                                        (run `wv index .` once to enable)
                          --code --graph  attach active nodes to code results

  wv query <preds>      Predicate reader. Exact — answers "nodes where X = Y".
                          key=value, key!=value, key>=value, key IN (a,b,c)
                          HAS key, MATCH "phrase"
                          --order=field, --include=finding|learning
                          --format=short|json
                          QUIRK: parens in IN (...) break bash — single-quote
                          the whole predicate: wv query 'id IN (wv-abc,wv-def)'

  search vs query:      search = BM25-fuzzy ("find me anything about dedup")
                        query  = predicate-exact ("status=done type=finding stale>=7")
                        Use search to locate; use query to pin and filter.

  wv list               Enumeration, capped at 50 rows (100 with --status=done).
                          The stderr footer gives the matching total and how
                          many rows are hidden; --limit=N raises the cap, --all
                          lifts it and adds done nodes. A capped list is not
                          evidence a node is absent: before wv add, run
                          wv search "<topic>".

  wv discover <id>      Unknown-taxonomy report for one node.
                          --json        emits known_knowns, known_unknowns,
                                        unknown_knowns, unknown_unknown_candidates
                          --depth=N     impact depth for candidate surfacing
                          --limit=N     cap each bucket
                          Candidates are hypotheses until a probe produces evidence.

  wv impact <id>        Blast-radius walk over typed edges (blocks|implements|addresses).
                          --full        adds resolves|references|supersedes|obsoletes
                          --direction=fwd|rev|both
                          --files=a,b   seed from touched_files
                          QUIRK: a done-seed refuses fwd walk ("impact already
                          discharged") — use --direction=rev or --include-done

  wv related <id>       Typed-edge neighbourhood of a node.
                          --type=, --direction=, --depth=N
  wv edges <id>         A node's edges. --type=, --json

  wv show <id>          Full node detail. --json for machine-readable.
  wv tree <epic>        Epic → task hierarchy. --mermaid for diagram.
  wv path <id>          Ancestry chain to root.

  wv analyze sessions   Telemetry: top commands by output bytes / approx tokens.
    --call-stats          Run this after a session to see where context goes.
                          Window it (--since-days=1) for retro reading — unwindowed
                          output is a lifetime aggregate across instrumentation eras.
                          Prefer query or search over wv list for targeted reads;
                          reserve wv list for enumeration, and read its footer
                          for hidden rows (it caps at 50).

  wv cache              Prompt-cache health for the project.
                          --sessions=N, --all; ratio >65% OK / 35-65% LOW / <35% BAD

  wv bootstrap --json   One-call session context snapshot.
                          Replaces: git status + wv status + wv ready

Typical audit sequence:
  1. wv search "<topic>"          locate by subject
  2. wv query 'id IN (...)'       pin the set, filter by status/type
  3. wv show <id>                 read full detail
  4. wv discover <id> --json      classify facts, gaps, learnings, candidates
  5. wv impact <id> --direction=rev   check what depends on it
  6. wv edges <id>                confirm typed relationships

Related topics:
  wv guide --topic=routing      phase loop, tool classes, token-saving pattern
  wv guide --topic=context      context pack, scope rules
  wv guide --procedure=blindspot-pass
EOF
            ;;
        *)
            echo "Unknown topic: $topic" >&2
            echo "Topics: workflow (default), github, learnings, context, routing, mcp, verification, instrumentation, config, discovery" >&2
            return 1
            ;;
    esac
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_help — Show help
# ═══════════════════════════════════════════════════════════════════════════

print_command_help() {
    local usage="$1"
    local summary="$2"

    printf 'Usage: %s\n\n%s\n' "$usage" "$summary"
}

_help_delegate_topic() {
    local topic="${1:-}"
    shift || true

    case "$topic" in
        bootstrap)
            cmd_bootstrap --help
            ;;
        bootstrap-agent)
            cmd_bootstrap_agent --help
            ;;
        bulk-update)
            cmd_bulk_update --help
            ;;
        cache)
            cmd_cache --help
            ;;
        enrich-topology)
            cmd_enrich_topology --help
            ;;
        quality)
            if [ $# -gt 0 ]; then
                cmd_quality "$1" --help
            else
                cmd_quality --help
            fi
            ;;
        findings)
            if [ $# -gt 0 ]; then
                cmd_findings "$1" --help
            else
                cmd_findings --help
            fi
            ;;
        analyze)
            if [ $# -gt 0 ]; then
                cmd_analyze "$1" --help
            else
                cmd_analyze --help
            fi
            ;;
        index)
            cmd_index --help
            ;;
        query)
            cmd_query --help
            ;;
        hook)
            cmd_hook --help
            ;;
    esac
}

cmd_help_topic() {
    local topic="${1:-}"
    shift || true

    case "$topic" in
        bootstrap|bootstrap-agent|bulk-update|cache|enrich-topology|quality|findings|analyze|index|query|hook)
            _help_delegate_topic "$topic" "$@"
            ;;
        validate-finding)
            print_command_help "wv validate-finding <id>" "Validate finding metadata for a node. Exit 0 = valid; exit 1 = invalid. Outputs JSON {valid, errors[]}. Used by pre-close-verification hook to enforce violation_type and optional field constraints before a finding node can be closed."
            ;;
        test-status)
            print_command_help "wv test-status <suite> --files=a,b [--staged] [--quiet]" "Return success only when every named file has a fresh green result for the suite. --staged compares the recorded result with Git index blobs for pre-commit reuse; the default compares working-tree content."
            ;;
        init-repo)
            cmd_init_repo --help
            ;;
        update)
            cmd_update_help
            ;;
        help)
            print_command_help "wv help <command> [subcommand]" "Show focused help for one command. Nested subcommand families like quality/findings/analyze can take an extra subcommand argument."
            ;;
        init)
            print_command_help "wv init [--force]" "Initialize the Weave database in the current hot zone, recovering synced state when available."
            ;;
        add)
            print_command_help "wv add <text> [--status=STATUS] [--parent=<id>] [--gh] [--alias=<name>] [--metadata=<json>] [--force] [--standalone] [--criteria=<text>] [--risks=<level>] [--kind=<kind>] [--verification-plan=<text>] [--id=<wv-id>]" "Create a node and print its id. Use --parent when an active epic exists, or --standalone for repo-level chores. --risks sets risk_level, one of: ${VALID_RISK_LEVELS// /, } (contracts/node-field-registry-v1.json). --kind sets the node kind (${WRITABLE_NODE_KINDS// /, }); without it the kind comes from metadata type, then the text prefix (epic(, plan( ...), then task. --verification-plan records upfront what would count as done, surfaced again as a reminder if wv done is later blocked for missing verification. --id reconstructs a node under an id the graph has lost, so a pushed Weave-ID trailer stops pointing at nothing; it refuses an alias and refuses to overwrite a live id."
            ;;
        remember)
            print_command_help "wv remember <text> [--kind=project] [--scope=repo] [--source-agent=name] [--supersedes=<id>] [--exposure=rendered|graph-only] [--json]" "Capture a graph-native memory node using metadata.type=memory and metadata.mem_status=active. --exposure=graph-only keeps it out of every projection and bootstrap's index while recall still returns it; a superseding memory inherits its predecessor's exposure. To change a claim, do not edit the memory: --supersedes=<id> records the new one and keeps the old as mem_status=superseded with superseded_by, linked by a supersedes edge. Only an active memory can be superseded."
            ;;
        memory)
            print_command_help "wv memory recall [--agent=current|all|name] [--json] | wv memory render [--agent=all|current|claude|claude-memory|copilot|codex|codex-memory|agents|workflow] [--base-dir=DIR] [--path=PATH] [--json] | wv memory scan --source=claude|codex|copilot|all [--repo-root=DIR] [--json] | wv memory import --source=claude --path=DIR [--repo-root=DIR] [--json] | wv memory import --source=codex [--path=DB] [--repo-root=DIR] [--json] | wv memory crystallize [--dry-run|--apply-reviewed] [--repo-root=DIR] [--json] | wv memory review <id> --verdict=promote|merge|reject|verify --reason=TEXT [--target=<active id>] [--json] | wv memory review <active id> --verdict=graduate --reason=TEXT --target=<repo path> [--json] | wv memory review <active id> --verdict=exposure --exposure=rendered|graph-only --reason=TEXT [--json] | wv memory review --apply [--dry-run] [--json] | wv memory exposure <id> [--json]" "Recall graph-native memory (active and graduated), render repo-local projections (active only), scan harness state, import Claude project memories or Codex memory-pipeline rows as mem_status=candidate nodes, crystallize candidates (dedup/verify/mark, promote reviewed), or record a reviewer's verdict on a candidate, or graduate an active memory whose lesson a repository procedure, guide, detector or tracked document now carries, and apply the recorded verdicts (review), or record an exposure verdict on an active memory (graph-only leaves it out of every projection and bootstrap's index, never out of recall; applied by review --apply with who, when and why kept), and show a memory's exposure (exposure). Capture records dynamic agent provenance; graph recall is agent-agnostic. --path is only valid for one render projection or a single Codex memory DB import. The agents projection (AGENTS.md, included in --agent=all) only refreshes an existing WEAVE:MEMORY block; a file without one is left untouched."
            ;;
        delete)
            print_command_help "wv delete <id> [--force] [--dry-run] [--no-gh]" "Delete a node and its edges. Use --dry-run to preview deletions and --force to execute them."
            ;;
        done)
            print_command_help "wv done <id> [--completion-files=path,...] [--learning=\"...\"|--learning-file=PATH] [--decision=\"...\"] [--pattern=\"...\"] [--pitfall=\"...\"] [--verification-method=\"...\"] [--verification-evidence=\"...\"|--verification-evidence-file=PATH] [--no-warn] [--acknowledge-overlap] [--skip-verification] [--no-overlap-check] [--no-gh] [--force]" "Close a node; an explicit completion-files scope audits quality against attributed selected files while preserving file history. Refuses while files outside graph state are staged but not committed; --force closes anyway."
            ;;
        ship)
            print_command_help "wv ship <id> [--learning=\"...\"|--learning-file=PATH] [--verification-method=\"...\"] [--verification-evidence=\"...\"|--verification-evidence-file=PATH] [--decision=\"...\"] [--pattern=\"...\"] [--pitfall=\"...\"] [--gh] [--skip-verification] [--no-overlap-check]" "Close a node and sync graph state in one step; any remaining Git sync is surfaced separately."
            ;;
        ship-agent)
            print_command_help "wv ship-agent <id> [--learning=\"...\"|--learning-file=PATH] [--verification-method=\"...\"|--verify-method=\"...\"] [--verification-evidence=\"...\"|--verify-evidence=\"...\"|--verification-evidence-file=PATH] [--gh] [--no-gh] [--skip-verification] [--no-overlap-check] [--json]" "Run an agent-safe non-interactive ship flow with doctor --agent precheck and JSON output."
            ;;
        batch-done)
            print_command_help "wv batch-done <id1> <id2> ... [--learning=\"...\"] [--no-warn] [--no-gh]" "Close multiple nodes with a shared learning note."
            ;;
        work)
            print_command_help "wv work <id> [--quiet] [--force] [--continue] [--reopen] [--json] [--allowed-tools=t1,t2,...]" "Claim a node, set WV_ACTIVE for agent context, take over (--force) or continue your own pre-session claim (--continue), both recorded in claim_history, explicitly reopen done nodes, and optionally persist an allowed tool list. A node whose metadata.retires names an entity (skill:<name>, or an array) prints every reference to that name in tests/ install.sh templates/ scripts/ on stderr at claim time."
            ;;
        preflight)
            print_command_help "wv preflight <id>" "Return machine-readable blockers, contradictions, and readiness checks for a node."
            ;;
        recover)
            print_command_help "wv recover [--auto] [--json] [--session] [--reproject [--event=NAME]]" "Resume interrupted ship/sync/delete flows or inspect orphaned active work for the current session. --reproject: when the committed .weave/ snapshot lags the operations committed with it (a rebase or merge kept another copy's), rebuild it (wv load, wv sync) and commit graph state alone; deferred with the reason while a gate holds the checkout, WV_AUTO_CHECKPOINT=0, an autostash holds .weave/ changes or files outside graph state are staged. The post-rewrite and post-merge hooks run it."
            ;;
        overview)
            print_command_help "wv overview [--json]" "Show a compact operational snapshot: counts, health indicators, breadcrumb, and top ready work."
            ;;
        pending-close)
            print_command_help "wv pending-close [--json]" "List nodes waiting for explicit overlap acknowledgement before close."
            ;;
        ready)
            print_command_help "wv ready [--json | --json-v2] [--count] [--all] [--with-impact] [--findings] [--subtree=<id>] [--mode=bootstrap|discover|execute|full]" "List unblocked work. --with-impact ranks by blast radius (wv impact per node); --subtree=<id> scopes to a node's descendants; --findings includes the findings digest."
            ;;
        list)
            print_command_help "wv list [--all] [--ids=<id,...>] [--limit=N] [--status=<status>] [--claimed-by=<agent-id>|current] [--json | --json-v2] [--mode=bootstrap|discover|execute|full]" "List nodes, excluding done by default. Output is capped at 50 rows (100 with --status=done); when the cap hides rows, a stderr footer gives the matching total and the --limit=N that shows them all. --all lifts the cap and includes done nodes. --ids=<id,...> lists exactly the named nodes (wv-xxxxxx ids, any status, uncapped), so a caller needing a few rows need not read them all. A capped list is not evidence a node is absent: check wv search \"<topic>\" before wv add. Use --claimed-by=current for nodes owned by this agent and --json-v2 for the lean parsed-metadata shape."
            ;;
        show)
            print_command_help "wv show <id> [--json | --json-v2] [--mode=bootstrap|discover|execute|full] [--close-time] [--actors]" "Show node details in text or JSON. --json-v2 returns the lean parsed-metadata shape. --close-time derives when a done node last closed from the committed graph history (git): the node's updated_at in the first snapshot showing it done after one showing it open, with the window it fell in; it walks history, so it can take seconds. --actors lists who created, claimed and closed the node, read from the append-only Delta v2 operation log (one actor per operation); graph state keeps only the last writer, and history before the v2 log reports none."
            ;;
        status)
            print_command_help "wv status [--json] [--mode=bootstrap|discover|execute|full]" "Show compact status counts for the current graph."
            ;;
        touch)
            print_command_help "wv touch <id> (--metadata=<json> | --intent=<text> | --files=path1,path2)" "Silently merge metadata for low-friction intent tracking or file attribution. --files records repo-relative paths in node_files for impact/search grounding."
            ;;
        allowed-tools)
            print_command_help "wv allowed-tools <id> [--json]" "Inspect the metadata.allowed_tools list stored on a node."
            ;;
        quick)
            print_command_help "wv quick <text> [--learning=\"...\"]" "Create and close a trivial one-step node in a single command."
            ;;
        block)
            print_command_help "wv block <id> --by=<blocker-id>" "Add a workflow dependency edge so the target is blocked by another node."
            ;;
        link)
            print_command_help "wv link <from-id> <to-id> --type=<type> [--weight=<weight>] [--context=<json>]" "Create a semantic edge between two nodes. Use 'wv edge-types' to inspect valid edge types."
            ;;
        unlink)
            print_command_help "wv unlink <from-id> <to-id> --type=<type>" "Remove a semantic edge between two nodes."
            ;;
        resolve)
            print_command_help "wv resolve <node1> <node2> (--winner=<id> | --merge | --defer) [--rationale=<text>]" "Resolve a contradiction edge by selecting a winner, merging, or deferring with rationale."
            ;;
        related)
            print_command_help "wv related <id> [--type=<type>] [--direction=outbound|inbound|both] [--depth=N] [--json]" "Inspect a node's semantic relationships. --depth=N expands to N-hop neighborhood (default 1)."
            ;;
        edges)
            print_command_help "wv edges <id> [--type=<type>] [--json]" "Inspect all edges touching a node."
            ;;
        path)
            print_command_help "wv path <id> [--format=chain]" "Show the ancestry path for a node."
            ;;
        tree)
            print_command_help "wv tree [root] [--active] [--depth=N] [--all] [--json] [--mermaid]" "Render epic/task hierarchy as text, JSON, or Mermaid. Capped at 50 nodes (WV_TREE_CAP); --all lifts."
            ;;
        plan)
            print_command_help "wv plan <file.md> --sprint=N [--dry-run] [--gh] [--template]" "Import a markdown plan into epic/task nodes, or emit a template with --template."
            ;;
        context)
            print_command_help "wv context [id] --json [--mode=bootstrap|discover|execute|full]" "Generate a JSON context pack for a node. If <id> is omitted, wv uses WV_ACTIVE."
            ;;
        impact)
            print_command_help "wv impact <id>... [--files=path1,path2] [--direction=fwd|rev|both] [--depth=N] [--json] [--full] [--include-done] [--all] [--quality] | wv impact --suites --files=path1,path2 [--unmatched]" "Walk the dependency graph from one or more seed nodes. Reports impacted nodes by depth, risk_score/risk_factors, nodes unblocked when seeds complete, and affected test suites. --files=path1,path2 derives seeds from node_files attribution or touched_files metadata (unknown paths emit empty result). --include-done also allows done file owners to become seeds and includes done impacted nodes. --direction=both (default) follows blocks|implements|addresses edges in both directions; fwd=outward only; rev=inward only. --depth=N (default 3). --all removes the 50-node cap. --full adds resolves|references|supersedes|obsoletes to the traversed edge types. --json returns structured output. --suites --files= skips the graph and prints the test suites .weave/test-map.conf routes the files to, as a JSON array; --unmatched prints {suites, unmatched} instead, naming the files no route covers."
            ;;
        discover)
            print_command_help "wv discover <id> --json [--depth=N] [--limit=N]" "Compose query and impact signals into unknown-taxonomy buckets: known_knowns, known_unknowns, unknown_knowns, and unknown_unknown_candidates."
            ;;
        search)
            cat <<'SEARCHHELP'
Usage: wv search <query> [--limit=N] [--json] [--status=STATUS] [--type=TYPE] [--learning]
       wv search --code <query> [--limit=N] [--json] [--mode=hybrid|fts|vector] [--graph] [--filter=<expr>]

  Without --code: searches Weave graph nodes (FTS5 BM25)
  With --code:    searches indexed code chunks (RRF hybrid BM25+cosine)
  --type=TYPE:    filter by metadata.type (finding, task, epic, ...)
  --learning:     only nodes that have captured learning content
  --graph:        attach active Weave nodes + quality churn to results
  --filter=EXPR:  constrain code chunks by graph edge type
                  Supported: edge-type=<type>, edge-type!=<type>
                  Types: blocks, implements, relates_to, addresses, contradicts, resolves
                  Example: wv search --code "auth" --filter=edge-type=blocks
SEARCHHELP
            ;;
        reindex)
            print_command_help "wv reindex" "Rebuild the full-text search index."
            ;;
        learnings)
            print_command_help "wv learnings [--category=<cat>] [--grep=<pattern>] [--recent=N] [--mode=<mode>] [--node=<id>] [--show-graph]" "Show captured learnings, optionally filtered by category, text, node, or output mode."
            ;;
        trails|breadcrumbs)
            print_command_help "wv trails [save|show|clear|capsule <id>] [--message=\"...\"] [--json='{...}']" "Persist or inspect session trails (append-only handoff path). 'breadcrumbs' is a back-compat alias."
            ;;
        digest)
            print_command_help "wv digest [--json]" "Show a compact one-line health summary."
            ;;
        session-summary)
            print_command_help "wv session-summary" "Show session activity statistics such as nodes created, completed, and learnings captured."
            ;;
        audit-pitfalls)
            print_command_help "wv audit-pitfalls [--top=N] [--all] [--only-addressed] [--json]" "List unaddressed pitfalls (top 20 default); --all includes addressed."
            ;;
        edge-types)
            print_command_help "wv edge-types [--stats] [--json]" "List valid semantic edge types and what each one means. --stats adds live edge counts from the graph."
            ;;
        doctor)
            print_command_help "wv doctor [--json] [--repair] [--agent]" "Run installation and surface-contract diagnostics for the CLI, hooks, and repo wiring. --agent adds python, pytest, import-path, and provenance checks for agent flows."
            ;;
        repo-class)
            print_command_help "wv repo-class [--json] [--offline] | wv repo-class set owned|vendored-upstream [--acknowledge-upstream-fork] | wv repo-class audit [--json] [--offline]" "Inspect or persist clone-local repository ownership classification, or audit tracked and historical Weave scaffolding without mutation."
            ;;
        self-update)
            print_command_help "wv self-update" "Refresh installed wv from the dev clone recorded at install time. Equivalent to re-running install.sh from the source directory."
            ;;
        uninstall)
            print_command_help "wv uninstall" "Remove installed wv files. Delegates to install.sh --uninstall. Preserves ~/.config/weave (user data) — see output for manual cleanup of ~/.claude/settings.json hooks and consumer repo git hooks."
            ;;
        selftest)
            print_command_help "wv selftest [--json]" "Run a round-trip smoke test in an isolated environment."
            ;;
        mcp-status)
            print_command_help "wv mcp-status [--json]" "Check whether the local MCP server is built and whether the IDE config contains the current Weave server/env entries."
            ;;
        health)
            print_command_help "wv health [--history[=N]] [--verbose] [--json] [--fast]" "Run system health checks and optionally include recent health history. --fast serves a score-focused result from a write-invalidated cache (WV_HEALTH_FAST_TTL, default 300s) and skips quality collection — intended for hook callers."
            ;;
        guide)
            print_command_help "wv guide [--topic=workflow|github|learnings|context|routing|mcp|verification|instrumentation|config|discovery] | --procedure=<id>" "Show a quick reference for common Weave workflows, routing rules, and integrations.

--procedure=<id> prints a procedure: the repository's own
.weave/procedures/<id>.md if it has one, which replaces the installed procedure
of the same id in this repository, else the installed one. Repository
procedures follow the same contract and project into this repository's agent
surfaces when wv init-repo refreshes it; wv doctor reports a stale projection."
            ;;
        prune)
            print_command_help "wv prune [--age=30d] [--dry-run] [--orphans-only] | --compact-tombstones [--dry-run]" "Archive done nodes older than --age (default 30d) with deletion tombstones. Explicit only: refuses from a hook or session end. Keeps findings, memories, epics, plans, decisions, unresolved pitfalls, nodes a live node references and nodes with an open GitHub issue; --dry-run lists what each rule kept. --compact-tombstones drops tombstones below every rostered clone's watermark and the 90-day floor (needs WV_TOMBSTONE_COMPACTION=1). Policy: wv guide --procedure=prune-policy."
            ;;
        kind)
            print_command_help "wv kind backfill [--apply] [--json]" "Give every node a kind (metadata.node_kind, mirrored to type) from node_kind, type, then the text prefix; without --apply only reports, and --apply refuses if wv ready would change."
            ;;
        unarchive)
            print_command_help "wv unarchive <id> [--dry-run] [--with-edges]" "Restore a pruned node from .weave/archive/ back into the live graph."
            ;;
        commit-refs)
            print_command_help "wv commit-refs [--json] [--all] [--prune [--dry-run]] | --trailers [--json]" \
                "Audit the commit SHAs recorded in node metadata against the pushed branch.

--trailers runs the audit the other way round: Weave-ID trailers already pushed
to the world that name a node this graph has no record of ever writing. Absence
alone is not the finding, because pruned history is absent too, so an id is
reported only when the tracked write log never wrote it; ids predating that log
are separated as unadjudicable. Read-only and offline, and the repair it prints
is wv add --id=<id>.

Classes: reachable (ancestor of the pushed ref), pending (local only — unpushed
or on another branch, not an orphan), unreachable (object exists but no ref
reaches it — superseded by an amend/reset/rebase), missing (gone from this
object database). Orphaned = unreachable + missing.

By default only orphaned refs are listed; --all lists every recorded ref.
--prune removes orphaned refs at every node that records them, children
included — an epic-only edit does not survive, because epics regenerate their
commits list from their children."
            ;;
        clean-ghosts)
            print_command_help "wv clean-ghosts [--dry-run]" "Remove edges that reference deleted nodes."
            ;;
        compact)
            print_command_help "wv compact [--older-than=Nd] [--dry-run] [--force] | --pre-cutover [--dry-run|--resume|--abort|--restore=MANIFEST]" "Delete replayed delta files after age and active-claim safety checks. --pre-cutover retires the v1 deltas the loader skips since the causal cutover, under the maintenance lock, with an equivalence check, a committed manifest and a declared identity transition; --resume/--abort finish an interrupted run, --restore brings the files back (docs/PROPOSAL-delta-retention.md)."
            ;;
        cutover)
            print_command_help "wv cutover [--yes] [--force] [--json]" "Stamp the causal cutover (.weave/causal-cutover) so cmd_load skips the pre-lineage v1 delta back-catalog. Operator-run; requires every agent synced."
            ;;
        refs)
            print_command_help "wv refs <file> | wv refs -t <text> | echo <text> | wv refs [--link --from=<id>] [--json] [--max=N]" "Extract Weave node references from text and optionally create edges."
            ;;
        import)
            print_command_help "wv import <file.jsonl> [--filter=\"id=...\"] [--dry-run]" "Import nodes from JSONL/JSON exports."
            ;;
        batch)
            print_command_help "wv batch [file] [--dry-run] [--stop-on-error]" "Execute multiple wv commands from a file or stdin.

Line format: one command per line, with or without a leading 'wv'. Blank lines
and lines starting with # are skipped. A line is split into arguments by shell
quoting rules (single quotes, double quotes, backslash escapes) and nothing is
expanded: no globs, variables or command substitution, and a # inside a line is
literal text. A line with an unbalanced quote fails. Each command runs with
stdin closed, so it cannot read the rest of the batch.

  add \"Fix the parser\" --status=active
  wv update wv-1234 --text='a *literal* star'"
            ;;
        sync)
            print_command_help "wv sync [--gh] [--dry-run] [--mode=fast|full|repair] [--node=<id>]" "Persist in-memory graph state to the git-backed .weave layer and optionally sync GitHub issues. Modes: fast (bounded to focus + impacted set, default for wv ship/session-end), full (exhaustive reconcile), repair (resumable from .weave/repair-checkpoint.json after timeout/interrupt — use after wv recover or stop-hook recommendation)."
            ;;
        load)
            print_command_help "wv load" "Load the graph from the git-backed .weave layer."
            ;;
        version)
            print_command_help "wv version" "Print the installed Weave CLI version."
            ;;
        context-policy)
            print_command_help "wv context-policy [--json] [--refresh]" "Print the context load policy (HIGH/MEDIUM/LOW) and its reason, from repository size signals. The one source every harness reads: the Claude SessionStart hook and MCP weave_overview both call it. Cached an hour in .weave/.context_policy; keeps the .weave/runtime.md policy block current. Runs no load."
            ;;
        hotzone)
            print_command_help "wv hotzone list [--json]" "List all hot-zones (active graph DB directories) with status, node count, and owner."
            print_command_help "wv hotzone db" "Print this repository's resolved brain.db path. Read the graph DB through it (DB=\$(wv hotzone db); sqlite3 -cmd \"PRAGMA query_only=1\" \"file:\$DB?mode=rw\"; macOS sqlite3 cannot open a WAL database -readonly without its -shm, and mode=rw never creates one): placement adopts the zone already holding this repository's database, else the /tmp zone (wv-b831e3), and sqlite3 on a guessed path creates an empty database there."
            print_command_help "wv hotzone gc [--dry-run]" "Quarantine hot-zone directories whose repository is known to be deleted (its parent directory is present and lists entries, or it was a temporary scratch repository): each moves by rename into <base>/.quarantine/ with a record of where it was, never deleted on the spot. A later gc purges a quarantined zone after WV_HOTZONE_QUARANTINE_DAYS (default 7) only while its owner is still gone and nothing has written to it. An owner that cannot be seen, as on an unmounted disk, or no owner recorded, is unknown and kept, with the reason (wv-4ccc98). Skips dirs newer than 1h."
            print_command_help "wv hotzone restore <name|path>" "Move a quarantined hot-zone directory back to where gc found it; refuses when that path is occupied."
            print_command_help "wv hotzone diff <brain.db> <brain.db>" "Compare two copies of one repository's graph, read-only, over every table a sync keeps (nodes, edges, file attribution, tombstones): rows only in one, or differing. Run it before removing either copy of a repository found in two hot zones: syncing both does not merge them (wv-a73141). It needs no hot zone, so it runs even where placement is refused (wv-757de1). Exit 0 identical, 1 different, 2 unusable arguments."
            print_command_help "wv hotzone migrate [--apply]" "Relocate the /tmp hot zone from its legacy layout (a real /tmp/weave-codex-<uid>, the neutral /tmp/weave-hotzone-<uid> its alias) to the neutral name, leaving the legacy name a fence symlink (wv-97d68a). A maintenance operation, run by hand in a quiet window and never automatically: it moves nothing while any process of yours uses either name or any wv on the host predates the neutral name, refuses two populated directories, and moves only by one same-filesystem rename. Without --apply it reports what it would do. Exit 0 done or nothing to do, 1 refused, 2 bad arguments."
            ;;
        *)
            echo "Unknown help topic: $topic" >&2
            echo "Try 'wv --help' to list available commands." >&2
            return 1
            ;;
    esac
}

cmd_help() {
    local topic="${1:-}"
    if [ -n "$topic" ]; then
        shift || true
        cmd_help_topic "$topic" "$@"
        return $?
    fi

    cat <<EOF
wv — Weave CLI: In-memory graph for AI coding agents

Usage: wv <command> [args]
       wv help <command>
       wv <command> --help

Commands:
  init              Initialize database
  add <text>        Add a node (returns ID) [--gh creates GitHub issue]
  remember <text>   Capture graph-native memory (type=memory, mem_status=active)
  memory <sub>      Recall/render/scan/import graph memory
  delete <id>       Permanently remove a node + edges [--force] [--dry-run] [--no-gh]
  done <id>         Mark node complete [--learning="..."] [--no-warn] [auto-closes GH issue]
    ship <id>         Done + sync in one step; Git sync surfaced separately [--learning="..."] [--gh]
  batch-done        Close multiple nodes [--learning="..."] [--no-warn] [--no-gh]
  bulk-update       Update multiple nodes from JSON on stdin [--dry-run]
  work <id>         Claim node & set WV_ACTIVE for subagent context [--quiet]
  preflight <id>    Pre-action checks as JSON (blockers, contradictions, context load)
  recover           Resume incomplete operations (ship/sync/delete) [--auto] [--json] [--session] [--reproject]
  bootstrap         Single-call JSON bootstrap context for agents [--json]
    bootstrap-agent   Agent bootstrap contract with command/provenance/readiness [--json]
    ship-agent        Agent-safe non-interactive close + sync wrapper [--json]
  overview          Compact graph summary [--json]
  cache             Claude prompt-cache diagnostics [--json]
  pending-close     List nodes awaiting human acknowledgement after learning overlap [--json]
  ready             List unblocked work
  list              List nodes (excludes done by default)
  show <id>         Show node details
  status            Compact status for context injection
  update <id>       Update node (run 'wv update --help' for metadata forms and safer input)
  touch <id>        Silent metadata merge for per-turn intent updates
  allowed-tools     Read metadata.allowed_tools for a node [--json]
  quick             Create and close a trivial one-step node
  hook dispatch     Host-neutral lifecycle hook dispatcher [--event=] [--json]
  block <id>        Add blocking edge (--by=<blocker>)
  link <from> <to>  Create semantic edge (--type=<type> [--weight=] [--context=])
  unlink <from> <to> Remove a semantic edge (--type=<type>)
  resolve <n1> <n2> Resolve contradiction (--winner=<id> | --merge | --defer [--rationale=])
  related <id>      Show semantic relationships ([--type=] [--direction=] [--json])
  edges <id>        Inspect all edges for a node ([--type=] [--json])
  path <id>         Show ancestry chain
  impact <id>...    Blast-radius: impacted nodes, risk, unblocked work, test suites [--files=] [--json]
  discover <id>     Blindspot report: query + impact buckets [--json]
  tree              Show epic -> task hierarchy [--active] [--depth=N] [--json] [--mermaid] [root]
  plan <file>       Import markdown section as epic + tasks [--sprint=N] [--gh] [--dry-run] [--template]
  enrich-topology   Apply epic/task topology from JSON spec [--dry-run] [--sync-gh]
  context [id]      Generate Context Pack [--json | pretty-print] (uses WV_ACTIVE if no id)
  search <query>    Full-text search nodes [--limit=N] [--status=] [--json]
  reindex           Rebuild full-text search index
  learnings         Show captured learnings [--category=] [--grep=] [--recent=N] [--mode=]
  trails            Session trails [save|show|clear|capsule <id>] (alias: breadcrumbs)
  digest            Compact one-liner health summary [--json]
  session-summary   Session activity stats (nodes created/completed, learnings)
  audit-pitfalls    Show all pitfalls with resolution status
  pattern-audit     Audit source for recurring bug-pattern invariants [--json] [--strict]
  edge-types        List valid semantic edge types [--stats] [--json]
  repo-class        Inspect/set clone-local owned vs vendored-upstream classification; audit scaffolding exposure
  init-repo         Bootstrap owned repo for Weave [--agent=claude|copilot|codex|all] [--codex-hooks] [--update] [--force]
  self-update       Refresh installed wv from the dev clone recorded at install time
  uninstall         Remove installed wv files (delegates to install.sh --uninstall)
  doctor            Installation + surface-contract checks (deps, hooks, ghost settings, matchers) [--json]
  hotzone <sub>     Hot-zone DB directories (list, db, diff, gc, migrate) [--json] [--dry-run]
  context-policy    Context load policy (HIGH/MEDIUM/LOW) and reason [--json] [--refresh]
  selftest          Round-trip smoke test in isolated environment [--json]
  test-record <suite> Record a test-suite run for verification freshness (used by git hooks)
  test-status <suite> Check whether every named file has a fresh green suite result
    mcp-status        Verify MCP server is built and IDE config shape is current [--json]
  health            System health check with score and diagnostics [--history[=N]]
  config            Manage durable opt-in knobs [list|get|set|unset|enable|disable]
    guide             Workflow quick reference [--topic=workflow|github|learnings|context|routing|mcp|verification|instrumentation|config|discovery]
  prune             Archive old done nodes
  kind backfill     Give every node a kind from type and text prefix [--apply] [--json]
  cutover           Stamp the causal cutover so load skips the pre-lineage delta back-catalog [--yes] [--force] [--json]
  unarchive <id>    Restore a pruned node from .weave/archive/ [--dry-run] [--with-edges]
  clean-ghosts      Delete ghost edges referencing deleted nodes [--dry-run] [legacy compatibility]
  commit-refs       Audit recorded commit SHAs against the pushed branch [--json] [--all] [--prune]
  compact           Delete replayed deltas after safety checks [--older-than=Nd]
  refs <file|text>  Extract cross-references (dry-run, no edges)
  import <file>     Import from beads JSONL or JSON
  quality <sub>     Code quality scanner (scan, hotspots, diff, promote, reset)
  findings <sub>    Historical finding promotion (list, promote)
  validate-finding <id>  Validate finding metadata: exit 0/1 + JSON errors (used by pre-close hook)
  analyze <sub>     Analyze agent session traces and instrumentation data
  query [pred...]   Predicate-based graph reader (status=, HAS, MATCH, IN)
  batch [file]      Execute multiple wv commands from file or stdin [--dry-run] [--stop-on-error]
  sync              Persist to git layer (.weave/) [--gh GH sync] [--dry-run]
  load              Load from git layer

Options:
  --json            Output as JSON (ready, list, show, health, search)
  --all             Include done nodes (list)
  --count           Return count only (ready)
  --verbose, -v     Show diagnostics (health)
  --history[=N]     Show last N health checks (default 10)
  --format=chain    Show as "A -> B -> C" (path)
  --node=<id>       Filter to one node (learnings)
  --show-graph      Show pitfall resolution graph (learnings)
  --age=48h         Prune age threshold (prune)
  --dry-run         Show what would be pruned (prune, import)
  --max=N           Max references to extract (refs, default 10)
  --limit=N         Max results to return (search, default 10)
  --status=<status> Filter by status (search)
  --claimed-by=<id>|current  Filter list by claim owner
  --link            Create edges for detected refs (refs, requires --from)
  --from=<id>       Source node for edge creation (refs --link)
  --interactive     Prompt for non-auto refs in link mode (refs --link)
  --gh              Create GitHub issue (add) or run GH sync (sync)
  --learning="..."  Store learning note on close (done)
  --no-warn         Suppress validation warnings (done) [also: WV_NO_WARN=1]
  --remove-key=<k>  Remove a single metadata key (update)
  --metadata=<json> Merge JSON into existing metadata (update)
  --metadata-file=<path> Read metadata JSON from a file or stdin (update)
  --category=<cat>  Filter by type: decision/pattern/pitfall/learning (learnings)
  --grep=<pattern>  Search text and metadata (learnings)
  --recent=<N>      Show only last N learnings (learnings)
  --mode=<mode>     Output mode: bootstrap|discover|execute|full (read surfaces)
  --message="..."   Custom note for trails (trails save)

Examples:
  wv add "Fix authentication bug"
    wv add "Refactor API" --status=active --criteria="make check passes|docs updated" --risks=low --gh
  wv ready
  wv work wv-a1b2                             # claim node, show WV_ACTIVE export
  eval "\$(wv work wv-a1b2 --quiet)"          # claim and set WV_ACTIVE in one command
  wv context --json                           # uses WV_ACTIVE if set
  wv help update                              # focused help for one command
  wv show --help                              # alternate focused help form
  wv done wv-a1b2 --learning="pattern: always check X"
    wv ship wv-a1b2 --learning="decision: ..."  # done + sync; check status for Git sync
  wv batch-done wv-a1b2 wv-c3d4 --learning="sprint complete"
  wv preflight wv-a1b2                        # check blockers/contradictions
  wv recover --auto                           # resume interrupted operations
  echo '[{"id":"wv-a1b2","alias":"my-task"},{"id":"wv-c3d4","status":"active"}]' | wv bulk-update
  wv update wv-a1b2 --metadata='{"priority":1}'  # merges, not replaces
  wv update wv-a1b2 --metadata-file meta.json     # safer metadata input
  wv update wv-a1b2 --remove-key=old_field        # remove single key
  wv block wv-c3d4 --by=wv-a1b2
  wv link wv-a1b2 wv-c3d4 --type=implements --weight=0.8
  wv resolve wv-a1b2 wv-c3d4 --winner=wv-a1b2 --rationale="Approach A is more performant"
  wv related wv-a1b2 --type=implements
  wv edges wv-a1b2
  wv sync --gh
  wv path wv-c3d4 --format=chain
  wv search "authentication" --limit=5
  wv search "bug" --status=todo --json
  wv reindex
  wv plan --template > docs/my-plan.md          # scaffold a plan from template
  wv plan docs/my-plan.md --sprint=1 --dry-run   # preview import
  wv plan docs/my-plan.md --sprint=1 --gh         # import with GitHub issues
  wv refs docs/design.md
  wv refs -t "see wv-a1b2" --link --from=wv-c3d4
  wv refs file.md --json
  wv trails save --message="Pausing for review"
  wv trails show
  wv digest
  wv learnings --category=pitfall --recent=5
  wv learnings --grep="testing"
  wv done wv-a1b2 --no-warn
  wv init-repo                                # bootstrap .claude/ for current repo (claude agent)
  wv init-repo --agent=copilot                # add VS Code Copilot config (.vscode/mcp.json + instructions)
  wv init-repo --agent=codex                  # add Codex setup contract (.codex/weave.json)
  wv init-repo --agent=codex --codex-hooks    # opt in to project Codex lifecycle hooks
  wv init-repo --agent=all                    # claude, copilot, and codex
  wv init-repo --update                       # refresh managed files (skills, agents, instructions)
  wv init-repo --force                        # overwrite ALL files including user-customized
EOF
}
