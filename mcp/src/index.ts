#!/usr/bin/env node
/**
 * Weave MCP Server
 *
 * Exposes Weave CLI graph operations as MCP tools for AI assistants.
 * Uses stdio transport for compatibility with all MCP clients.
 *
 * Tools:
 *   weave_search   - Full-text search across nodes
 *   weave_add      - Create a new node
 *   weave_done     - Mark node complete
 *   weave_batch_done - Close multiple nodes at once
 *   weave_context  - Get Context Pack for a node
 *   weave_list     - List nodes with filters
 *   weave_link     - Create semantic edges
 *   weave_status   - Compact status summary
 *   weave_health   - Graph health check
 *   weave_quick    - Quick-add and start working
 *   weave_work     - Claim a node to work on
 *   weave_ship     - Complete + sync in one step
 *   weave_overview - Session start overview (status + digest + breadcrumbs)
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { CallToolRequestSchema, ListToolsRequestSchema, Tool } from "@modelcontextprotocol/sdk/types.js";
import { execFileSync } from "child_process";
import { accessSync, constants } from "fs";

// --- Scope definitions ---
// Each scope exposes a subset of tools for context-silo'd subagents.
// "all" (default) exposes everything for backward compatibility.
export type Scope = "graph" | "session" | "inspect" | "all";

export const SCOPE_TOOLS: Record<Exclude<Scope, "all">, string[]> = {
  graph: ["weave_add", "weave_link", "weave_done", "weave_batch_done", "weave_list", "weave_resolve", "weave_update"],
  session: [
    "weave_work",
    "weave_ship",
    "weave_quick",
    "weave_overview",
    "weave_close_session",
    "weave_breadcrumbs",
    "weave_plan",
  ],
  inspect: [
    "weave_context",
    "weave_search",
    "weave_status",
    "weave_health",
    "weave_preflight",
    "weave_sync",
    "weave_tree",
    "weave_learnings",
    "weave_guide",
  ],
};

function parseScope(): Scope {
  const arg = process.argv.find((a) => a.startsWith("--scope="));
  if (!arg) return "all";
  const value = arg.split("=")[1] as Scope;
  if (!["graph", "session", "inspect", "all"].includes(value)) {
    console.error(`Invalid scope "${value}". Valid: graph, session, inspect, all`);
    process.exit(1);
  }
  return value;
}

const ACTIVE_SCOPE = parseScope();

// Find wv CLI - check common locations
function findWvPath(): string {
  const paths = [
    process.env.WV_PATH,
    `${process.env.HOME}/.local/bin/wv`,
    "/usr/local/bin/wv",
    // Dev mode: relative to this package
    `${__dirname}/../../scripts/wv`,
  ].filter(Boolean) as string[];

  for (const p of paths) {
    try {
      accessSync(p, constants.X_OK);
      return p;
    } catch {
      continue;
    }
  }

  throw new Error("wv CLI not found. Install with: cd weave && ./install.sh");
}

const WV_PATH = findWvPath();

// Default timeout for wv commands (30s). Sync handlers override this.
const WV_TIMEOUT = 30_000;

// Execute wv command safely using execFileSync (no shell interpolation).
// Args are passed as an array — user input never touches a shell.
function wv(args: string[], timeout: number = WV_TIMEOUT): string {
  try {
    return execFileSync(WV_PATH, args, {
      encoding: "utf-8",
      maxBuffer: 10 * 1024 * 1024, // 10MB
      timeout,
      env: { ...process.env, WV_ACTIVE: process.env.WV_ACTIVE || "" },
    }).trim();
  } catch (error: unknown) {
    const execError = error as { stderr?: string; message?: string };
    throw new Error(execError.stderr || execError.message || "wv command failed");
  }
}

// Tool definitions
const TOOLS: Tool[] = [
  {
    name: "weave_search",
    description: "Full-text search across Weave nodes. Returns matching nodes ranked by relevance.",
    inputSchema: {
      type: "object",
      properties: {
        query: {
          type: "string",
          description: "Search query (supports stemming)",
        },
        limit: {
          type: "number",
          description: "Maximum results to return (default: 10)",
        },
        status: {
          type: "string",
          enum: ["todo", "in-progress", "done", "blocked", "blocked-external"],
          description: "Filter by status",
        },
      },
      required: ["query"],
    },
  },
  {
    name: "weave_add",
    description:
      "Create a new Weave node. Returns the generated node ID. IMPORTANT: Always set gh=true to create a linked GitHub issue, and provide an alias for readability.",
    inputSchema: {
      type: "object",
      properties: {
        text: {
          type: "string",
          description: "Node text/description",
        },
        status: {
          type: "string",
          enum: ["todo", "in-progress", "done", "blocked", "blocked-external"],
          description: "Initial status (default: todo)",
        },
        metadata: {
          type: "object",
          description: "JSON metadata (e.g., {type: 'task', priority: 1})",
        },
        gh: {
          type: "boolean",
          description:
            "Create a linked GitHub issue. Should ALWAYS be true unless explicitly told otherwise -- orphan nodes without GH issues lose traceability.",
        },
        alias: {
          type: "string",
          description:
            "Human-readable alias (e.g., 'fix-login-bug'). Should ALWAYS be set -- makes the graph readable and commands easier.",
        },
        parent: {
          type: "string",
          description:
            "Parent node ID to link via 'implements' edge (e.g., 'wv-a1b2'). Prevents orphan tasks -- always set for non-epic nodes.",
        },
      },
      required: ["text"],
    },
  },
  {
    name: "weave_done",
    description:
      "Mark a Weave node as complete. Always include a learning for non-trivial work -- captures decisions, patterns, and pitfalls for future sessions.",
    inputSchema: {
      type: "object",
      properties: {
        id: {
          type: "string",
          description: "Node ID (e.g., wv-a1b2)",
        },
        learning: {
          type: "string",
          description:
            "Learning to capture (decision/pattern/pitfall). IMPORTANT: Always provide for non-trivial work.",
        },
        no_warn: {
          type: "boolean",
          description: "Suppress validation hints (useful on machines without test env)",
        },
      },
      required: ["id"],
    },
  },
  {
    name: "weave_batch_done",
    description:
      "Close multiple nodes at once. Useful for completing a group of related tasks from a sprint. Applies the same learning to all nodes.",
    inputSchema: {
      type: "object",
      properties: {
        ids: {
          type: "array",
          items: { type: "string" },
          description: "Array of node IDs to close (e.g., ['wv-a1b2', 'wv-c3d4'])",
        },
        learning: {
          type: "string",
          description: "Learning to capture for all nodes",
        },
        no_warn: {
          type: "boolean",
          description: "Suppress validation hints",
        },
      },
      required: ["ids"],
    },
  },
  {
    name: "weave_context",
    description: "Get full Context Pack for a node: node details, blockers, ancestors, related nodes, and learnings.",
    inputSchema: {
      type: "object",
      properties: {
        id: {
          type: "string",
          description: "Node ID (optional if WV_ACTIVE is set)",
        },
      },
      required: [],
    },
  },
  {
    name: "weave_list",
    description: "List Weave nodes with optional filters.",
    inputSchema: {
      type: "object",
      properties: {
        status: {
          type: "string",
          enum: ["todo", "in-progress", "done", "blocked", "blocked-external"],
          description: "Filter by status",
        },
        all: {
          type: "boolean",
          description: "Include done nodes (default: false)",
        },
      },
      required: [],
    },
  },
  {
    name: "weave_link",
    description: "Create a semantic edge between two nodes.",
    inputSchema: {
      type: "object",
      properties: {
        from: {
          type: "string",
          description: "Source node ID",
        },
        to: {
          type: "string",
          description: "Target node ID",
        },
        type: {
          type: "string",
          enum: [
            "blocks",
            "relates_to",
            "implements",
            "contradicts",
            "supersedes",
            "references",
            "obsoletes",
            "addresses",
          ],
          description: "Edge type",
        },
        weight: {
          type: "number",
          description: "Edge weight 0.0-1.0 (default: 1.0)",
        },
      },
      required: ["from", "to", "type"],
    },
  },
  {
    name: "weave_status",
    description: "Get compact status summary: active work, ready count, blocked count.",
    inputSchema: {
      type: "object",
      properties: {},
      required: [],
    },
  },
  {
    name: "weave_health",
    description: "Run health check on Weave graph. Returns score and any issues found.",
    inputSchema: {
      type: "object",
      properties: {
        verbose: {
          type: "boolean",
          description: "Include detailed diagnostics",
        },
      },
      required: [],
    },
  },
  {
    name: "weave_quick",
    description:
      "Record a trivial completed task. Creates a done node with learning in one step. Equivalent to add + done + sync.",
    inputSchema: {
      type: "object",
      properties: {
        text: {
          type: "string",
          description: "Node text/description",
        },
      },
      required: ["text"],
    },
  },
  {
    name: "weave_work",
    description: "Claim a node to work on. Sets WV_ACTIVE context for subagent inheritance.",
    inputSchema: {
      type: "object",
      properties: {
        id: {
          type: "string",
          description: "Node ID to claim (e.g., wv-a1b2)",
        },
      },
      required: ["id"],
    },
  },
  {
    name: "weave_ship",
    description:
      "Complete current work: mark node done with learning, then sync to git layer. Auto-detects GitHub-linked nodes and syncs GH issues. Always include a learning for non-trivial work.",
    inputSchema: {
      type: "object",
      properties: {
        id: {
          type: "string",
          description: "Node ID to complete",
        },
        learning: {
          type: "string",
          description:
            "Learning to capture (decision/pattern/pitfall). IMPORTANT: Always provide for non-trivial work.",
        },
        gh: {
          type: "boolean",
          description: "Force GitHub sync (auto-detected if node or parent epic has gh_issue metadata)",
        },
      },
      required: ["id"],
    },
  },
  {
    name: "weave_overview",
    description:
      "Get a comprehensive overview: status summary, health digest, context load policy, and breadcrumbs. Ideal for session start.",
    inputSchema: {
      type: "object",
      properties: {},
      required: [],
    },
  },
  {
    name: "weave_preflight",
    description:
      "Pre-action checks for a node: existence, blockers, done_criteria, contradictions, context load. Returns structured JSON. Call before starting work.",
    inputSchema: {
      type: "object",
      properties: {
        id: {
          type: "string",
          description: "Node ID to check (e.g., wv-a1b2)",
        },
      },
      required: ["id"],
    },
  },
  {
    name: "weave_sync",
    description: "Persist graph to disk and optionally sync GitHub issues. Call periodically and before session end.",
    inputSchema: {
      type: "object",
      properties: {
        gh: {
          type: "boolean",
          description: "Also sync GitHub issues (default: false)",
        },
      },
      required: [],
    },
  },
  {
    name: "weave_resolve",
    description:
      "Resolve contradictions or duplicates between two nodes. Use --winner to pick one, --merge to combine, or --defer to postpone.",
    inputSchema: {
      type: "object",
      properties: {
        node1: {
          type: "string",
          description: "First node ID",
        },
        node2: {
          type: "string",
          description: "Second node ID",
        },
        mode: {
          type: "string",
          enum: ["winner", "merge", "defer"],
          description: "Resolution mode",
        },
        winner: {
          type: "string",
          description: "Winner node ID (required if mode=winner)",
        },
        rationale: {
          type: "string",
          description: "Reason for resolution",
        },
      },
      required: ["node1", "node2", "mode"],
    },
  },
  {
    name: "weave_close_session",
    description:
      "End-of-session cleanup: sync graph, check for uncommitted files and unpushed commits. Replaces session-end hook for MCP clients.",
    inputSchema: {
      type: "object",
      properties: {
        gh: {
          type: "boolean",
          description: "Also sync GitHub issues (default: true)",
        },
      },
      required: [],
    },
  },
  {
    name: "weave_tree",
    description:
      "View epic hierarchy as a tree. Returns JSON array with id, text, status, node_type, depth, root_id per node. Essential for seeing the graph structure.",
    inputSchema: {
      type: "object",
      properties: {
        active: {
          type: "boolean",
          description: "Filter to non-done subtrees only (default: false)",
        },
        depth: {
          type: "number",
          description: "Maximum recursion depth",
        },
      },
      required: [],
    },
  },
  {
    name: "weave_learnings",
    description:
      "Query captured learnings (patterns, decisions, pitfalls). Returns JSON array. Use before starting work to check prior decisions.",
    inputSchema: {
      type: "object",
      properties: {
        grep: {
          type: "string",
          description: "Keyword filter (e.g., 'SIGPIPE', 'sync')",
        },
        recent: {
          type: "number",
          description: "Limit to N most recent learnings",
        },
        category: {
          type: "string",
          description: "Filter by category",
        },
        node: {
          type: "string",
          description: "Filter to learnings from a specific node",
        },
      },
      required: [],
    },
  },
  {
    name: "weave_update",
    description:
      "Modify a node's metadata, status, text, or alias. Metadata is MERGED into existing keys (not replaced). Use remove_key to delete individual metadata keys.",
    inputSchema: {
      type: "object",
      properties: {
        id: {
          type: "string",
          description: "Node ID (e.g., wv-a1b2)",
        },
        status: {
          type: "string",
          enum: ["todo", "in-progress", "done", "blocked", "blocked-external"],
          description: "New status",
        },
        text: {
          type: "string",
          description: "New node text/description",
        },
        metadata: {
          type: "object",
          description:
            "JSON metadata to merge into existing keys (e.g., {commit: 'abc123'}). Existing keys are preserved.",
        },
        alias: {
          type: "string",
          description: "Human-readable alias",
        },
        remove_key: {
          type: "string",
          description: "Remove a single metadata key by name (e.g., 'gh_issue')",
        },
      },
      required: ["id"],
    },
  },
  {
    name: "weave_breadcrumbs",
    description: "Save, show, or clear session breadcrumbs. Use to leave context notes for future sessions or agents.",
    inputSchema: {
      type: "object",
      properties: {
        action: {
          type: "string",
          enum: ["save", "show", "clear"],
          description: "Action to perform (default: show)",
        },
        message: {
          type: "string",
          description: "Session note to save (required when action is 'save')",
        },
      },
      required: [],
    },
  },
  {
    name: "weave_guide",
    description:
      "Workflow quick reference for Weave. Returns human-readable guidance on the core workflow, GitHub integration, learnings format, or context policy. Call with no topic for the 5-step workflow overview.",
    inputSchema: {
      type: "object",
      properties: {
        topic: {
          type: "string",
          enum: ["workflow", "github", "learnings", "context", "mcp"],
          description:
            "Topic to show: workflow (default, 5-step process), github (issue integration), learnings (format + commands), context (load policy + wv context usage), mcp (server setup + tools)",
        },
      },
      required: [],
    },
  },
  {
    name: "weave_plan",
    description:
      "Import a markdown plan file as an epic with linked task nodes. One call creates epic + N tasks + implements edges + optional GitHub issues. The plan file must have '### Sprint N: Title' sections with numbered tasks.",
    inputSchema: {
      type: "object",
      properties: {
        file: {
          type: "string",
          description: "Path to markdown plan file",
        },
        sprint: {
          type: "number",
          description: "Which sprint section to import (e.g., 1, 2, 3)",
        },
        gh: {
          type: "boolean",
          description: "Create linked GitHub issues for each node",
        },
        dry_run: {
          type: "boolean",
          description: "Preview what would be created without creating nodes",
        },
      },
      required: ["file", "sprint"],
    },
  },
];

// Filter tools based on active scope
function getToolsForScope(scope: Scope, allTools: Tool[]): Tool[] {
  if (scope === "all") return allTools;
  const allowed = new Set(SCOPE_TOOLS[scope]);
  return allTools.filter((t) => allowed.has(t.name));
}

const SCOPED_TOOLS = getToolsForScope(ACTIVE_SCOPE, TOOLS);

// Tool handlers
function handleTool(name: string, args: Record<string, unknown>): { content: { type: "text"; text: string }[] } {
  let result: string;

  switch (name) {
    case "weave_search": {
      const query = args.query as string;
      const limit = args.limit as number | undefined;
      const status = args.status as string | undefined;
      const cmd = ["search", query, "--json"];
      if (limit) cmd.push(`--limit=${limit}`);
      if (status) cmd.push(`--status=${status}`);
      result = wv(cmd);
      break;
    }

    case "weave_add": {
      const text = args.text as string;
      const status = args.status as string | undefined;
      const metadata = args.metadata as Record<string, unknown> | undefined;
      const gh = args.gh as boolean | undefined;
      const alias = args.alias as string | undefined;
      const parent = args.parent as string | undefined;
      const cmd = ["add", text];
      if (status) cmd.push(`--status=${status}`);
      if (metadata) cmd.push(`--metadata=${JSON.stringify(metadata)}`);
      if (gh) cmd.push("--gh");
      if (alias) cmd.push(`--alias=${alias}`);
      if (parent) cmd.push(`--parent=${parent}`);
      result = wv(cmd);
      // Enforcement warnings
      const warnings: string[] = [];
      if (!gh) warnings.push("WARNING: No --gh flag. Node has no GitHub issue. Use gh=true for traceability.");
      if (!alias) warnings.push("WARNING: No alias set. Use alias parameter for readable node names.");
      if (warnings.length) result += "\n\n" + warnings.join("\n");
      break;
    }

    case "weave_done": {
      const id = args.id as string;
      const learning = args.learning as string | undefined;
      const noWarn = args.no_warn as boolean | undefined;
      const cmd = ["done", id];
      if (learning) cmd.push(`--learning=${learning}`);
      if (noWarn) cmd.push("--no-warn");
      result = wv(cmd);
      if (!learning)
        result +=
          "\n\nWARNING: No learning captured. Consider: what decision, pattern, or pitfall should future sessions know?";
      break;
    }

    case "weave_batch_done": {
      const ids = args.ids as string[];
      const learning = args.learning as string | undefined;
      const noWarn = args.no_warn as boolean | undefined;
      const cmd = ["batch-done", ...ids];
      if (learning) cmd.push(`--learning=${learning}`);
      if (noWarn) cmd.push("--no-warn");
      result = wv(cmd);
      break;
    }

    case "weave_context": {
      const id = args.id as string | undefined;
      const cmd = id ? ["context", id, "--json"] : ["context", "--json"];
      result = wv(cmd);
      break;
    }

    case "weave_list": {
      const status = args.status as string | undefined;
      const all = args.all as boolean | undefined;
      const cmd = ["list", "--json"];
      if (status) cmd.push(`--status=${status}`);
      if (all) cmd.push("--all");
      result = wv(cmd);
      break;
    }

    case "weave_link": {
      const from = args.from as string;
      const to = args.to as string;
      const type = args.type as string;
      const weight = args.weight as number | undefined;
      const cmd = ["link", from, to, `--type=${type}`];
      if (weight !== undefined) cmd.push(`--weight=${weight}`);
      result = wv(cmd);
      break;
    }

    case "weave_status": {
      result = wv(["status"]);
      break;
    }

    case "weave_health": {
      const verbose = args.verbose as boolean | undefined;
      const cmd = verbose ? ["health", "--verbose", "--json"] : ["health", "--json"];
      result = wv(cmd);
      break;
    }

    case "weave_quick": {
      const text = args.text as string;
      result = wv(["quick", text]);
      break;
    }

    case "weave_work": {
      const id = args.id as string;
      result = wv(["work", id]);
      break;
    }

    case "weave_ship": {
      const id = args.id as string;
      const learning = args.learning as string | undefined;
      const gh = args.gh as boolean | undefined;
      const cmd = ["ship", id];
      if (learning) cmd.push(`--learning=${learning}`);
      if (gh) cmd.push("--gh");
      result = wv(cmd, 60_000); // sync may be slow
      if (!learning)
        result +=
          "\n\nWARNING: No learning captured. Consider: what decision, pattern, or pitfall should future sessions know?";
      break;
    }

    case "weave_overview": {
      const parts: string[] = [];
      try {
        parts.push("=== Status ===\n" + wv(["status"]));
      } catch {
        /* skip */
      }
      try {
        parts.push("\n=== Digest ===\n" + wv(["digest"]));
      } catch {
        /* skip */
      }
      try {
        parts.push("\n=== Breadcrumbs ===\n" + wv(["breadcrumbs", "show"]));
      } catch {
        /* skip */
      }
      try {
        parts.push("\n=== Ready Work ===\n" + wv(["ready"]));
      } catch {
        /* skip */
      }
      // Context load policy (replaces session-start hook injection)
      // Try dev layout first (__dirname/../../scripts/), then installed (~/.config/weave/)
      try {
        const devPath = `${__dirname}/../../scripts/context-guard.sh`;
        const installedPath = `${process.env.HOME}/.config/weave/context-guard.sh`;
        let scriptPath: string | undefined;
        try {
          accessSync(devPath, constants.X_OK);
          scriptPath = devPath;
        } catch {
          /* not dev */
        }
        if (!scriptPath) {
          try {
            accessSync(installedPath, constants.X_OK);
            scriptPath = installedPath;
          } catch {
            /* not installed */
          }
        }
        if (scriptPath) {
          const policy = execFileSync("bash", [scriptPath], {
            encoding: "utf-8",
            timeout: 5000,
            env: { ...process.env },
          }).trim();
          const policyLine = policy.split("\n").find((l) => l.startsWith("policy:"));
          if (policyLine) parts.push("\n=== Context Policy ===\n" + policyLine);
        } else {
          parts.push("\n=== Context Policy ===\nUnavailable (context-guard.sh not found)");
        }
      } catch {
        /* skip — context-guard.sh execution failed */
      }
      result = parts.join("\n");
      break;
    }

    case "weave_preflight": {
      const id = args.id as string;
      result = wv(["preflight", id]);
      break;
    }

    case "weave_sync": {
      const gh = args.gh as boolean | undefined;
      const cmd = gh ? ["sync", "--gh"] : ["sync"];
      result = wv(cmd, 60_000); // sync may be slow
      break;
    }

    case "weave_resolve": {
      const node1 = args.node1 as string;
      const node2 = args.node2 as string;
      const mode = args.mode as string;
      const winner = args.winner as string | undefined;
      const rationale = args.rationale as string | undefined;
      const cmd = ["resolve", node1, node2];
      if (mode === "winner" && winner) {
        cmd.push(`--winner=${winner}`);
      } else if (mode === "merge") {
        cmd.push("--merge");
      } else if (mode === "defer") {
        cmd.push("--defer");
      }
      if (rationale) cmd.push(`--rationale=${rationale}`);
      result = wv(cmd);
      break;
    }

    case "weave_close_session": {
      const gh = (args.gh as boolean) ?? true;
      const parts: string[] = [];

      // 1. Sync graph (+ optional GH)
      try {
        const syncCmd = gh ? ["sync", "--gh"] : ["sync"];
        parts.push("=== Sync ===\n" + wv(syncCmd, 60_000));
      } catch (e) {
        parts.push("=== Sync ===\nError: " + (e as Error).message);
      }

      // 2. Check uncommitted files
      try {
        const uncommitted = execFileSync("git", ["status", "--porcelain"], {
          encoding: "utf-8",
          env: { ...process.env },
        }).trim();
        if (uncommitted) {
          parts.push("\n=== Uncommitted Files ===\n" + uncommitted);
        } else {
          parts.push("\n=== Uncommitted Files ===\nNone — working tree clean");
        }
      } catch {
        parts.push("\n=== Uncommitted Files ===\nCould not check");
      }

      // 3. Check unpushed commits
      try {
        const unpushed = execFileSync("git", ["log", "@{u}..HEAD", "--oneline"], {
          encoding: "utf-8",
          env: { ...process.env },
        }).trim();
        if (unpushed) {
          parts.push("\n=== Unpushed Commits ===\n" + unpushed);
        } else {
          parts.push("\n=== Unpushed Commits ===\nNone — up to date with remote");
        }
      } catch {
        parts.push("\n=== Unpushed Commits ===\nCould not check");
      }

      // 4. Active nodes warning
      try {
        const status = wv(["status"]);
        if (status.includes("active") && !status.includes("0 active")) {
          parts.push(
            "\n=== Warning ===\n" + "Active nodes still open — consider closing with weave_done or weave_ship"
          );
        }
      } catch {
        /* skip */
      }

      result = parts.join("\n");
      break;
    }

    case "weave_tree": {
      const active = args.active as boolean | undefined;
      const depth = args.depth as number | undefined;
      const cmd = ["tree", "--json"];
      if (active) cmd.push("--active");
      if (depth !== undefined) cmd.push(`--depth=${depth}`);
      result = wv(cmd);
      break;
    }

    case "weave_learnings": {
      const grep = args.grep as string | undefined;
      const recent = args.recent as number | undefined;
      const category = args.category as string | undefined;
      const node = args.node as string | undefined;
      const cmd = ["learnings", "--json"];
      if (grep) cmd.push(`--grep=${grep}`);
      if (recent !== undefined) cmd.push(`--recent=${recent}`);
      if (category) cmd.push(`--category=${category}`);
      if (node) cmd.push(`--node=${node}`);
      result = wv(cmd);
      break;
    }

    case "weave_update": {
      const id = args.id as string;
      const status = args.status as string | undefined;
      const text = args.text as string | undefined;
      const metadata = args.metadata as Record<string, unknown> | undefined;
      const alias = args.alias as string | undefined;
      const removeKey = args.remove_key as string | undefined;

      // --remove-key is a standalone operation (returns immediately)
      if (removeKey) {
        result = wv(["update", id, `--remove-key=${removeKey}`]);
        break;
      }

      const cmd = ["update", id];
      if (status) cmd.push(`--status=${status}`);
      if (text) cmd.push(`--text=${text}`);
      if (metadata) cmd.push(`--metadata=${JSON.stringify(metadata)}`);
      if (alias) cmd.push(`--alias=${alias}`);
      result = wv(cmd);
      break;
    }

    case "weave_breadcrumbs": {
      const action = (args.action as string) || "show";
      const message = args.message as string | undefined;
      const cmd = ["breadcrumbs", action];
      if (action === "save" && message) cmd.push(`--message=${message}`);
      result = wv(cmd);
      break;
    }

    case "weave_guide": {
      const topic = args.topic as string | undefined;
      const cmd = ["guide"];
      if (topic) cmd.push(`--topic=${topic}`);
      result = wv(cmd);
      break;
    }

    case "weave_plan": {
      const file = args.file as string;
      const sprint = args.sprint as number;
      const gh = args.gh as boolean | undefined;
      const dryRun = args.dry_run as boolean | undefined;
      const cmd = ["plan", file, `--sprint=${sprint}`];
      if (gh) cmd.push("--gh");
      if (dryRun) cmd.push("--dry-run");
      result = wv(cmd, 60_000); // GH issue creation can be slow
      break;
    }

    default:
      throw new Error(`Unknown tool: ${name}`);
  }

  return {
    content: [{ type: "text", text: result }],
  };
}

// Create and run server
async function main() {
  const scopeLabel = ACTIVE_SCOPE === "all" ? "" : `-${ACTIVE_SCOPE}`;
  const server = new Server(
    {
      name: `weave-mcp-server${scopeLabel}`,
      version: "1.5.4",
    },
    {
      capabilities: {
        tools: {},
      },
    }
  );

  // List available tools (filtered by scope)
  server.setRequestHandler(ListToolsRequestSchema, async () => ({
    tools: SCOPED_TOOLS,
  }));

  // Handle tool calls (enforce scope)
  server.setRequestHandler(CallToolRequestSchema, async (request) => {
    const { name, arguments: args } = request.params;

    // Reject tools not in active scope
    if (!SCOPED_TOOLS.some((t) => t.name === name)) {
      return {
        content: [
          {
            type: "text",
            text: `Error: Tool "${name}" is not available in scope "${ACTIVE_SCOPE}"`,
          },
        ],
        isError: true,
      };
    }

    try {
      return handleTool(name, (args as Record<string, unknown>) || {});
    } catch (error: unknown) {
      const err = error as Error;
      return {
        content: [{ type: "text", text: `Error: ${err.message}` }],
        isError: true,
      };
    }
  });

  // Start stdio transport
  const transport = new StdioServerTransport();
  await server.connect(transport);

  console.error(`Weave MCP server started (scope=${ACTIVE_SCOPE}, ${SCOPED_TOOLS.length} tools)`);
}

main().catch((error) => {
  console.error("Fatal error:", error);
  process.exit(1);
});
