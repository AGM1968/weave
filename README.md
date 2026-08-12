# Weave

Weave is a local-first work, memory, and policy graph for coding agents. It gives Claude Code,
Codex, Copilot, MCP clients, CI, and human operators one durable workflow built around the `wv`
command.

Weave stores project state in `.weave/`, uses SQLite for fast local queries, and projects durable
graph state into Git so work, decisions, dependencies, and learnings survive across sessions and
machines.

> **Release status:** 1.71 is the supported Bash/Python LTS maintenance line. The current 1.71
> release is a prerelease; v1.70.3 remains the latest stable release.

## What Weave Provides

- graph-backed tasks with criteria, risks, blockers, dependencies, and aliases;
- explicit claim, preflight, verification, completion, and recovery workflows;
- durable decisions, patterns, pitfalls, trails, and context packs;
- impact-selected tests and policy checks tied to touched files;
- Git and optional GitHub issue synchronization;
- shared workflow surfaces for Claude Code, Codex, Copilot, CLI, and MCP clients;
- repository health, graph audits, code search, and prose-quality diagnostics.

## Requirements

- Linux or macOS;
- Bash, Git, SQLite 3, `jq`, and Python 3.11+;
- Node.js 20+ only when installing the optional MCP server;
- GitHub CLI (`gh`) only when using GitHub synchronization.

Check dependencies without installing:

```bash
./install.sh --check-deps
```

## Install

### Latest stable release

```bash
curl -sSL https://raw.githubusercontent.com/AGM1968/weave/v1.70.3/install.sh | bash
```

Ensure `~/.local/bin` is on `PATH`, then confirm the installation:

```bash
wv --version
wv selftest
```

### A specific prerelease

Download the source archive attached to the desired
[GitHub release](https://github.com/AGM1968/weave/releases), extract it, and install from that
directory:

```bash
tar -xzf weave-1.71.0-rc.2.tar.gz
cd weave-1.71.0-rc.2
./install.sh --verify
```

Install the optional MCP server with:

```bash
./install.sh --with-mcp
```

## Start Using Weave

Initialize an owned project repository:

```bash
cd /path/to/your-project
wv init-repo --agent=all
wv bootstrap --json
```

Use `--agent=claude`, `--agent=codex`, or `--agent=copilot` when only one host integration should
be projected. Weave checks repository ownership before writing managed files; inspect uncertain
repositories with `wv repo-class --json` rather than forcing initialization.

A minimal work cycle:

```bash
# Create and claim work.
wv add "Fix session recovery" \
  --status=active \
  --criteria="recovery test passes|failure mode documented" \
  --risks=medium

# Inspect the active context and readiness gates.
wv bootstrap --json
wv preflight <node-id> --json

# Attribute changed files, commit the implementation, and close with reusable learning.
wv touch <node-id> --files=src/recovery.py,tests/test_recovery.py
git add src/recovery.py tests/test_recovery.py
git commit -m "fix: recover interrupted sessions"
wv done <node-id> \
  --learning="decision: ... | pattern: ... | pitfall: ..."

# Persist graph state and optionally synchronize linked GitHub issues.
wv sync --gh
git add .weave/
git diff --cached --quiet || git commit -m "chore(weave): sync state"
git push
```

Run `wv help`, `wv help <command>`, or `wv guide --topic=workflow` for command guidance.

## Updating

For stable installations:

```bash
wv self-update
```

After updating Weave, refresh managed integration files in each owned project:

```bash
wv init-repo --agent=all --update
wv load
wv bootstrap --json
```

Prereleases are opt-in and are not installed automatically while an older release remains marked
Latest. Install a prerelease archive explicitly as shown above.

## Data and Repository Boundaries

- Project graph data lives under `.weave/` in the project repository.
- Runtime databases and caches are local implementation details; durable projections are the Git
  synchronization surface.
- Do not initialize vendored or third-party repositories. Use `wv repo-class --json` when ownership
  is unclear.
- Review `.weave/` changes like any other project state before pushing them.

## Maintenance Status

Weave 1.71 is active and supported for correctness, security, durability, compatibility, and
installer fixes. It is not feature-frozen and this repository is not being archived.

A possible successor implementation is being evaluated separately. It is not part of this release,
has no authority over Weave repositories, and does not change the support status of this LTS line.
Archival would require a public replacement, documented migration and rollback, compatible graph
loading without semantic loss, successful canaries, and a final maintenance release announcing the
transition. Those conditions have not been met.

See [CHANGELOG.md](CHANGELOG.md) for release-specific changes and
[LICENSE](LICENSE) for licensing terms.
