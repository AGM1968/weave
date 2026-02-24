# Contributing to Weave

Thank you for your interest in contributing to Weave.

## Getting Started

1. Fork the repository
2. Clone your fork: `git clone https://github.com/<you>/weave`
3. Install locally: `./install.sh`
4. Run the tests: `poetry run pytest tests/ -q` and `bash tests/run-all.sh`

## Development Setup

**Requirements:**

- Bash 4+
- SQLite 3.35+ (with FTS5)
- jq
- Python 3.10+ with Poetry (for GitHub sync module and tests)
- Node.js 18+ (for MCP server)
- ShellCheck (for linting bash scripts)

**Install dev dependencies:**

```bash
poetry install
```

**Project structure:**

```text
scripts/wv          # Main CLI entrypoint
scripts/cmd/        # Command implementations (core, graph, data, ops)
scripts/lib/        # Shared libraries (db, config, cache, validation)
scripts/weave_gh/   # Python GitHub sync module
mcp/src/            # MCP server (TypeScript)
tests/              # Test suites (bash + pytest)
templates/          # Agent instruction templates
.claude/            # Claude Code hooks, agents, skills
```

## Workflow

This project uses Weave itself for task tracking. All contributions should follow the Weave
workflow:

```bash
wv-init-repo --agent=all              # Set up hooks and agent configs
# After Weave upgrades: wv-init-repo --update  # Refresh hooks/skills/agents
wv add "Your contribution" --gh       # Create a tracked task
wv work <id>                          # Claim it
# ... make changes ...
wv done <id> --learning="..."         # Complete with learning
wv sync --gh && git push              # Sync and push
```

The pre-commit hook enforces that an active Weave node exists before committing. Use
`git commit --no-verify` to bypass if needed.

## Code Standards

### Bash (scripts/)

- ShellCheck clean (`shellcheck scripts/wv scripts/cmd/*.sh scripts/lib/*.sh`)
- Use `set -euo pipefail` in all scripts
- Never pipe `db_query_json` directly into `jq` (causes SIGPIPE under pipefail)
- Use intermediate variables instead
- Edit source files in `scripts/`, not installed copies in `~/.local/`
- Run `./install.sh` after editing scripts to sync installed copies

### Python (scripts/weave_gh/, tests/)

- Ruff for linting and formatting
- Type hints required
- pytest for testing (`poetry run pytest tests/ -q`)

### TypeScript (mcp/)

- Strict TypeScript (`tsc --noEmit`)
- Build: `cd mcp && npm run build`

### Markdown

- Markdownlint clean (`npx markdownlint-cli '**/*.md'`)
- No image emojis -- use text markers instead

## Testing

```bash
# Python tests (GitHub sync module)
poetry run pytest tests/ -q

# Bash tests (CLI, graph, cache)
bash tests/run-all.sh

# Full validation
shellcheck scripts/wv scripts/cmd/*.sh scripts/lib/*.sh
poetry run pytest tests/ -q
bash tests/run-all.sh
```

## Pull Requests

1. Create a feature branch from `main`
2. Follow the Weave workflow (tracked task with learning)
3. Ensure all tests pass and linters are clean
4. Write a clear commit message referencing the Weave node ID
5. Open a PR with a description of what changed and why

## Reporting Issues

For questions or ideas, use [Discussions](https://github.com/AGM1968/weave/discussions). For bugs
and feature requests, use [Issues](https://github.com/AGM1968/weave/issues). Include:

- What you expected vs what happened
- Steps to reproduce
- Output of `wv doctor` and `wv mcp-status`
- OS and shell version

## License

By contributing, you agree that your contributions will be licensed under the
[AGPL-3.0 License](LICENSE).
