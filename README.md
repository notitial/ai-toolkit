<p align="center">
  <img src="assets/icon/toolkit-icon.svg" alt="ai-toolkit: a round navy badge showing an upright cream book whose cover is a grid of eight small windows, with a gold bookmark ribbon at its foot" width="160">
</p>

# ai-toolkit

A documentation-first knowledge base of AI-assisted development patterns, plus the Claude Code agents, hooks, skills and rules installed from it.

> **Status:** a personal toolkit, not a product. The install steps assume macOS (zsh, Homebrew, Keychain); the docs are plain markdown and read anywhere.

## What This Is

Patterns, methodologies and lessons distilled from real projects, organized by topic and written for both humans and AI agents.
Alongside the docs, the repo ships the working setup they describe, and `/setup-claude` installs it into `~/.claude/`.

## Getting Started

Prerequisites (`/setup-claude` checks them first and stops with these hints if one is missing):

| Tool | Needed by | Install (macOS) |
|------|-----------|-----------------|
| `jq` | every hook parses its input with it | recent macOS ships `/usr/bin/jq`; otherwise `brew install jq` (it must then be on the PATH Claude Code starts with: the guards fall back to `/usr/bin` only) |
| `node` + `npm` | git-mcp-server | `brew install node` |

1. Clone this repo (https or ssh)
2. Open it in Claude Code and run `/setup-claude`, which is idempotent, so safe to repeat
3. Restart Claude Code

Then run `/audit-claude` in any project to evaluate its AI configuration.

## What Gets Installed

| Category | Items | Destination |
|----------|-------|-------------|
| [Agents](agents/) | code-reviewer, security-auditor, adr-advisor, plan-reviewer, plan-author, payments-reviewer | `~/.claude/agents/` |
| [Hooks](hooks/) | secret-detector, secret-redact-output, destructive-blocker, gh-block, git-mcp-redirect, build-redirect, git-mcp-guard, workspace-lock-guard, audit-logger, session-name-restore, github-mcp-update-check | `~/.claude/hooks/` |
| [Skills](skills/README.md) | adr, audit-claude, feature-kickoff, fable-plan, handover, review-gate, archive-index, prep-compact, unattended-run, workspace-lock-protocol, eta, repo-setup, add-claude-review, add-build-kit | `~/.claude/skills/` |
| [Rules](rules/) | workflow, communication, engineering-defaults, security, model-discipline (always-on); workspace-lock (conditional) | `~/.claude/rules/` |
| [MCP server](docs/adr/0010-mcp-git-over-bash-git.md) | git-mcp: structured git tools replacing Bash git; the pinned binary (v2.15.1), registered by you with `claude mcp add --scope user` | `~/.claude.json` |
| [Status line](tools/statusline.sh) | Context and rate-limit display | `~/.claude/statusline.sh` |
| [Tool scripts](tools/README.md) | workspace-lock.sh; shell-init.zsh (loads the `ait` zsh helpers and the account launchers; your `~/.zshrc` sources it) | `~/.claude/tools/` |
| [Permissions](docs/05-permissions-and-safety.md) | Safe defaults, hook wiring, plugin config | `~/.claude/settings.json` |

The guarded GitHub MCP setup ([tools/github-mcp/](tools/github-mcp/README.md)) is optional and not installed by `/setup-claude`: it runs from the live checkout, so a merge and a fast-forward pull are the install.

## Where to Go Next

- [docs/README.md](docs/README.md): the reading order, 17 docs in six groups
- A new repo: [docs/06](docs/06-repo-initialization.md) and [docs/07](docs/07-new-repo-setup.md), plus `/repo-setup`
- [skills/README.md](skills/README.md): every skill, global and project-scoped
- [tools/README.md](tools/README.md): the scripts, with [github-mcp](tools/github-mcp/README.md), [workspace-lock](tools/workspace-lock/README.md) and the opt-in [build-kit](tools/build-kit/README.md)
- [docs/adr/README.md](docs/adr/README.md): the decisions behind the design
- [CLAUDE.md](CLAUDE.md): for agents working in this repo

## Security

To report a vulnerability, see [SECURITY.md](SECURITY.md). Please don't open a public issue.

## License

MIT. See [LICENSE](LICENSE).
