# Weave

Weave is a local-first work, memory, and policy graph for coding agents. Claude Code, Codex,
Copilot, MCP clients, CI, and human operators share one workflow through the `wv` command.

Project state lives in `.weave/`. SQLite serves local queries. Graph state is projected into Git,
where work, decisions, dependencies, and learnings persist across sessions and machines.

1.71 is the supported maintenance line and its current release is a prerelease. v1.70.3 is the
latest stable release.

## Features

- graph-backed tasks with criteria, risks, blockers, dependencies, and aliases;
- claim, preflight, verification, completion, and recovery workflows;
- durable decisions, patterns, pitfalls, trails, and context packs;
- impact-selected tests and policy checks tied to touched files;
- Git and optional GitHub issue synchronization;
- shared workflow surfaces for Claude Code, Codex, Copilot, CLI, and MCP clients;
- repository health, graph audits, code search, and prose-quality diagnostics;
- reviewed promotion of quality findings into tracked remediation work;
- repository-authored procedures, pattern rules, violation types and coaching guides that stay in
  that repository;
- graph memory shared by every host, with review, recall and graduation into repository surfaces.

## Requirements

- Linux or macOS;
- Bash, Git, SQLite 3, `jq`, and Python 3.11+;
- Node.js 20+ for the optional MCP server;
- GitHub CLI (`gh`) for GitHub synchronization.

Check dependencies with `./install.sh --check-deps`.

## Install

Latest stable release:

```bash
curl -sSL https://raw.githubusercontent.com/AGM1968/weave/v1.70.3/install.sh | bash
```

A prerelease: download the source archive from its
[GitHub release](https://github.com/AGM1968/weave/releases), then:

```bash
tar -xzf weave-<version>.tar.gz
cd weave-<version>
./install.sh --verify
```

Add `--with-mcp` to install the MCP server. With `~/.local/bin` on `PATH`, confirm the install with
`wv --version` and `wv selftest`.

## Start Using Weave

```bash
cd /path/to/your-project
wv init-repo --agent=all
wv bootstrap --json
```

`--agent=claude`, `--agent=codex`, or `--agent=copilot` projects a single host integration. Weave
checks repository ownership before writing managed files; `wv repo-class --json` reports a
repository's class.

A work cycle:

```bash
wv add "Fix session recovery" --status=active \
  --criteria="recovery test passes|failure mode documented" --risks=medium
wv preflight <node-id> --json

git add src/recovery.py tests/test_recovery.py
git commit -m "fix: recover interrupted sessions"
wv done <node-id> --learning="decision: ... | pattern: ... | pitfall: ..."

wv sync --gh
git add .weave/
git diff --cached --quiet || git commit -m "chore(weave): sync state"
git push
```

`wv help <command>` and `wv guide --topic=workflow` describe each command.

## Commit and Push Gates

`wv init-repo` installs pre-commit and pre-push hooks. A commit requires an active claim held by the
committing actor. The hooks run the suites `.weave/test-map.conf` routes to the changed files, in
your checkout, and record each gate in `~/.local/share/weave/gate_runs.jsonl`.

`wv init-repo` proposes a suite declaration from your lockfiles as
`.weave/gate-provision.proposed.json`. It is never adopted for you: rename it to
`.weave/gate-provision.json` to run those suites against a snapshot of the staged tree in a private
environment. `wv analyze gates` reports which routes still run in the checkout. Removing an adopted
suite later needs a retirement record, which the refusal prints.

## Updating

```bash
wv self-update                      # installs the release marked Latest
wv init-repo --agent=all --update   # in each project
wv load
wv doctor
```

`wv doctor` reports the current actor and active claims held by other actors; review them before
taking one over with `wv work <id> --force`. Install a prerelease from its archive as shown above.
Each release's Upgrading notes in [CHANGELOG.md](CHANGELOG.md) list any one-time steps.

## Data and Repository Boundaries

- Project graph data lives under `.weave/` in the project repository and is reviewed and committed
  like other project state.
- Runtime databases and caches are local; the committed `.weave/` projection is what synchronizes.
- Initialize only repositories you own.

See [CHANGELOG.md](CHANGELOG.md) for release changes and [LICENSE](LICENSE) for licensing terms.
