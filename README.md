<p align="center">
  <img src="assets/icon/toolkit-icon.svg" alt="ai-toolkit: a round navy badge showing a cream tower of eight windows with a gold bookmark ribbon at its foot" width="160">
</p>

# ai-toolkit

A documentation-first knowledge base of AI-assisted development patterns, plus the Claude Code agents, hooks, skills and rules installed from it.

> **Status:** a personal toolkit, not a product. The install steps assume macOS (zsh, Homebrew, Keychain); the docs are plain markdown and read anywhere.

## What This Is

Patterns, methodologies, and lessons I've distilled from real projects — organized by topic, written for both humans and AI agents to consume. Alongside the docs, the repo ships the working setup they describe: global agents, hooks, skills and rules, a status line, and the scripts and tests behind them. `/setup-claude` installs it all into `~/.claude/`.

## Getting Started

Prerequisites (`/setup-claude` checks them first and stops with these hints if one is missing):

| Tool | Needed by | Install (macOS) |
|------|-----------|-----------------|
| `jq` | every hook parses its input with it | recent macOS ships `/usr/bin/jq`; otherwise `brew install jq` (it must then be on the PATH Claude Code starts with: the guards fall back to `/usr/bin` only) |
| `node` + `npm` | git-mcp-server | `brew install node` |
| `gh` | your own commands (agents are blocked from it, `hooks/gh-block.sh`); a missing login only warns | `brew install gh`, then `gh auth login`, answering **No** to "Authenticate Git with your GitHub credentials?" |

1. Clone this repo (https or ssh)
2. Open it in Claude Code and run `/setup-claude`
3. Restart Claude Code

`/setup-claude` is idempotent — safe to run repeatedly. It installs everything listed below into `~/.claude/`.

Once set up, go to any project and run `/audit-claude` to evaluate its AI configuration.

## What Gets Installed

| Category | Items | Destination |
|----------|-------|-------------|
| Agents | code-reviewer, security-auditor, adr-advisor, plan-reviewer, plan-author, payments-reviewer | `~/.claude/agents/` |
| Hooks | secret-detector, secret-redact-output, destructive-blocker, gh-block, git-mcp-redirect, git-mcp-guard, workspace-lock-guard, audit-logger, session-name-restore, github-mcp-update-check | `~/.claude/hooks/` |
| Skills | adr, audit-claude, feature-kickoff, fable-plan, handover, review-gate, archive-index, prep-compact, unattended-run, workspace-lock-protocol, eta, repo-setup | `~/.claude/skills/` |
| Rules | workflow, communication, engineering-defaults, security, model-discipline (always-on); workspace-lock (conditional — no-op unless a repo arms the lock) | `~/.claude/rules/` |
| MCP server | git-mcp (structured git tools replacing Bash git): the pinned binary (`npm i -g`, v2.15.1), registered by you with `claude mcp add --scope user` | `~/.claude.json` (user scope) |
| Status line | Context and rate-limit display | `~/.claude/statusline.sh` |
| Tool scripts | workspace-lock.sh; shell-init.zsh (your `~/.zshrc` sources it with `source ~/.claude/tools/shell-init.zsh`; it loads the `ait` zsh helpers) | `~/.claude/tools/` |
| Permissions | Safe defaults, hook wiring, plugin config | `~/.claude/settings.json` |

The guarded GitHub MCP setup ([tools/github-mcp/](tools/github-mcp/README.md)) is optional and not installed by `/setup-claude`: its root-owned copies come from the `ghm-install` helper.

## Structure

```
docs/                   Knowledge base (numbered in reading order, with gaps; see docs/README.md)
docs/adr/               Architecture Decision Records
agents/                 Global agent definitions installed to ~/.claude/agents/
hooks/                  Global hook scripts installed to ~/.claude/hooks/
skills/                 Global skills installed to ~/.claude/skills/
rules/                  Global always-on rules installed to ~/.claude/rules/
tools/                  Statusline, workspace-lock, github-mcp, and helper scripts and tests
assets/icon/            The project icon (SVG, mono variant, PNGs from 16 to 1024 px)
.claude/skills/         Project-scoped skills (setup-claude, cleanup-claude, audit-practices, audit-tooling)
.claude/commands/       Project command claude-pr-review (a fork of the code-review command from Anthropic's Claude Code plugins)
.claude/rules/          Path-scoped rules for this repo (documentation-quality)
.github/workflows/      Automatic Claude PR review workflow (ADR 0013)
CLAUDE.md               Project instructions for AI agents working in this repo
```

## Skills

### /setup-claude

Bootstraps the global Claude Code environment from this repo. Installs agents, hooks, skills, rules, the statusline and tool scripts as symlinks, merges permissions into `settings.json`, and installs the pinned git-mcp binary (you register it with `claude mcp add --scope user`). Run from this repo.

### /audit-claude

Audits any project's AI setup against the patterns in `docs/`. Evaluates CLAUDE.md, rules, agents, skills, and settings. Classifies maturity level (A/B/C) and produces prioritized recommendations. Run from the target project.

### /adr

Creates and manages Architecture Decision Records. Scaffolds `docs/adr/` on first use, then creates sequentially numbered ADRs from a consistent template. Run from any project.

### /repo-setup

Audits a named repo against the repo-setup checklist ([docs/22](docs/22-new-repo-setup.md)): a read-only audit of each step (files through the github MCP, settings and rulesets from `gh` reads the user runs); an archived repo is reported and the run stops. In `setup` mode it then writes the missing files on a branch and opens a PR, on the user's go. Every repo setting, ruleset, App or secret change is printed as `gh` commands for the user; the skill changes none itself. Decided values live in `skills/repo-setup/defaults.md`; the rest is asked. `/repo-setup <owner/repo>` audits, `/repo-setup setup <owner/repo>` audits then fixes.

### /eta

Reports where the current task stands and a grounded ETA, backed by a global learning KB at `~/.claude/.eta/` that improves as real durations are recorded. Produces a progress overview, a completion table (mirrors the ticket's structure when one is in scope, else done/remaining), and an ETA with a range and its basis; `/eta close` reconciles the actual duration back into the record so estimates sharpen over time. Run from any session.

### Multi-session / orchestration skills

Installed globally alongside the skills above; they work together across a feature's lifecycle:

- **/feature-kickoff** — scaffolds a multi-session feature workspace (`.archive/<ticket>/`: STATE.md, plan.md with an Execution order section, handoff/ and review/ buses) and delegates the plan draft to `/fable-plan` (which reviews it); two modes (user-mode interactive, agent-mode structure-from-known). Plans and structures only — never authorizes execution
- **/fable-plan** — drafts (or re-drafts) a workspace's `plan.md` by spawning the `plan-author` agent (on Fable), writes it, then runs the plan-reviewer loop and persists the verdict; the one shared plan-authoring implementation, used standalone or via feature-kickoff Step 4. Writes only `.archive/<ticket>/plan.md` — never STATE.md, code, a ledger row, or a lock
- **/handover** — generates a handover doc to continue work in a fresh session or report back to an orchestrator
- **/review-gate** — routes a change to the right reviewer slate (code-reviewer always; payments/security reviewers by files touched) and writes a consolidated go/no-go
- **/archive-index** — summarizes and indexes a feature's `.archive` workspace when resuming work
- **/prep-compact** — pre-compaction triage: capture state, ask what's next, recommend compact vs handover vs resume
- **/unattended-run** — arms (user-triggered only) and runs a kicked-off feature unattended, serialized via the orchestrator lock
- **/workspace-lock-protocol** — the lock's detailed rules, loaded on demand so the always-on `workspace-lock` rule can stay short: which lock id to use (one shared id for a team run, a per-session id when working alone), when a lock is yours to take, how a worker in another repo finds the team's lock, and what to do while waiting for it

### Project-scoped skills

These live in `.claude/skills/` and are available only within this repo:

- **setup-claude** — the `/setup-claude` installer described above
- **cleanup-claude** — `/cleanup-claude`: the inverse of `/setup-claude` and the installers, for a clean reinstall. Drives `tools/cleanup-claude/cleanup.sh`, which the user runs: a dry run by default, `--apply` to remove the links into the checkout, the toolkit's settings keys (backup first; the security entries stay unless `--include-security`), the plain rc `source` lines and the toolkit's runtime state, and prints the root-owned, MCP, npm and Keychain commands for the user. Keeps login, transcripts, the session registry, CLAUDE.md, settings backups and Keychain. One machine per run
- **audit-practices** — audits documentation quality against the patterns in `docs/`
- **audit-tooling** — audits the tooling artifacts (agents, hooks, skills, settings) themselves

## Tools

- **statusline.sh** — Custom Claude Code status line showing model, context window usage (scaled to the `autoCompactWindow` setting, 500k with the `/setup-claude` template; 250k if unset), and both the 5-hour and weekly rate limit windows. Also writes this account's rate-limit windows to a readings file another tool can turn into meters
- **workspace-lock** — Advisory JSON lock that serializes the mutating work (edits, builds, tests) of independent overnight orchestrators on one machine, over a shared working copy. See the `unattended-run` skill
- **github-mcp** — An optional, guarded setup of GitHub's MCP server: a launcher plus a hook that limits which GitHub writes agents may make, both installed root-owned so agents can't edit them, with their tests; its README covers install and token rotation. See [tools/github-mcp/README.md](tools/github-mcp/README.md)
- **cleanup-claude** — `bash tools/cleanup-claude/cleanup.sh [--apply] [--config-dir DIR] [--purge-ask] [--keep-ambiguous] [--include-security] [--verbose]`: removes what the repo installed on this machine (links that resolve into the checkout, the toolkit's settings.json keys and hook entries after a backup (the security entries stay unless `--include-security`), the plain rc `source` lines, runtime state). Dry run by default. Never touches login, Keychain, transcripts or CLAUDE.md; sudo, `claude mcp remove`, npm and Keychain steps are printed, never run. Driven by the project-scoped `/cleanup-claude` skill
- **ait** — `tools/ait.zsh` zsh helpers, loaded by `~/.zshrc` through `source ~/.claude/tools/shell-init.zsh`: `ait` (cd to the checkout), `ait-status` (what `/setup-claude` checks), `ghm-status`, `ghm-test` and `ghm-install`, which installs the GitHub MCP launcher and guard as root-owned copies from `main`'s committed files, with `main` clean and equal to `origin/main`: it shows the GitHub owners whose repos agents may write to, the Keychain account the token is read from and the diff, asks, then runs `sudo install`

- **install-copies.sh** — `bash tools/install-copies.sh status`: reports what is installed outside the checkout (the root-owned github MCP copies, install-time settings, the `~/.zshrc` line); `/setup-claude check` runs it
- **test-all.sh** — `bash tools/test-all.sh [--quick] [NAME…]`: runs every tool and hook test suite and prints a pass/fail table. Each hook (`secret-detector`, `destructive-blocker`, `git-mcp-guard`, …) has its suite under `tools/<name>/`; see [CLAUDE.md](CLAUDE.md) for which to run after a change

## Docs Overview

| # | Document | Topic |
|---|----------|-------|
| 01 | project-instructions | How to write CLAUDE.md and project anchor files |
| 02 | rules | Rule authoring patterns, scoping, sizing |
| 03 | agents | Subagent architecture, taxonomy, tool/model scoping |
| 04 | skills-and-commands | Skill design, categories, reusable workflow patterns |
| 05 | orchestrator | Autonomous pipeline design, thin coordinator pattern |
| 06 | convergence | Intelligent loop termination, plateau detection |
| 07 | reviews | Multi-agent review architecture, severity rubrics |
| 08 | context-management | Token optimization, checkpoints, session degradation |
| 09 | structural-context | Repo maps, code graphs, structural indexing for agents |
| 10 | permissions-and-safety | Command whitelists, sandbox patterns, secrets safety |
| 11 | repo-initialization | Bootstrap prompts, AI maturity model (A/B/C) |
| 12 | run-history | Failure Patterns and Recovery |
| 13 | cross-platform-parity | Parity enforcement for multi-target projects |
| 14 | prompt-engineering | Prompt patterns that worked in practice |
| 15 | multi-repo-coordination | Coordinating agent work across separate repos: add-dir, Agent Teams, orchestrator workspace |
| 19 | orchestrator-context-discipline | The live coordinator's own window: GC spent thinking, delegate legwork and own judgment, compact on state boundaries |
| 22 | new-repo-setup | The GitHub-side checklist every new repo gets (settings, ruleset, CI, secret scan, PR title and template, Claude review); `/repo-setup` walks it |

Document numbers keep their original order; a gap is a document not published here.

`docs/adr/` contains Architecture Decision Records documenting significant design choices for this repo.

## Case Studies

Documents illustrate patterns with case studies from real projects, with project names generalized. Figures (token counts, failure rates, consolidation ratios) come from the author's own runs and are illustrative, not benchmarks.

## How to Use

- **Set up your environment:** Run `/setup-claude` from this repo, then restart Claude Code
- **Audit a project:** Run `/audit-claude` from any project
- **For humans:** Read `docs/README.md` for the recommended reading order
- **For AI agents:** Read `CLAUDE.md` for project context, then `docs/README.md`
- **For new projects:** Start with docs 01, 02, 11 to set up AI tooling in a fresh repo

## Security

To report a vulnerability, see [SECURITY.md](SECURITY.md). Please don't open a public issue.

## License

MIT. See [LICENSE](LICENSE).
