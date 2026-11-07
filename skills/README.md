# Skills

Global skills live in this folder and are symlinked into `~/.claude/skills/` by `/setup-claude`. Project-scoped skills live in [.claude/skills/](../.claude/skills/) and work only inside this repo. The install roster is the table in the [README](../README.md#what-gets-installed).

## Global skills

### [/audit-claude](audit-claude/SKILL.md)

Audits any project's AI setup against the patterns in [docs/](../docs/README.md). Evaluates CLAUDE.md, rules, agents, skills, and settings. Classifies maturity level (A/B/C) and produces prioritized recommendations. Run from the target project.

### [/adr](adr/SKILL.md)

Creates and manages Architecture Decision Records. Scaffolds `docs/adr/` on first use, then creates sequentially numbered ADRs from a consistent template. Run from any project.

### [/repo-setup](repo-setup/SKILL.md)

Audits a named repo against the repo-setup checklist ([docs/07](../docs/07-new-repo-setup.md)): a read-only audit of each step (files through the github MCP, settings and rulesets from `gh` reads the user runs); an archived repo is reported and the run stops. In `setup` mode it then writes the missing files on a branch and opens a PR, on the user's go. Every repo setting, ruleset, App or secret change is printed as `gh` commands for the user; the skill changes none itself. Decided values live in [repo-setup/defaults.md](repo-setup/defaults.md); the rest is asked. `/repo-setup <owner/repo>` audits, `/repo-setup setup <owner/repo>` audits then fixes.

### [/add-claude-review](add-claude-review/SKILL.md)

Adds the automatic Claude PR review to the current repo from the kit in [tools/claude-review/](../tools/claude-review/README.md). Asks for the runner labels, the auth mode, the secret name and the reviewer GitHub App, applies only the documented replacement points, checks the SHAs and opens the PR; the user creates or installs the App, sets the variables and secrets, and merges. Also upgrades an existing copy. Run from the target repo.

### [/eta](eta/SKILL.md)

Reports where the current task stands and a grounded ETA, backed by a global learning KB at `~/.claude/.eta/` that improves as real durations are recorded. Produces a progress overview, a completion table (mirrors the ticket's structure when one is in scope, else done/remaining), and an ETA with a range and its basis; `/eta close` reconciles the actual duration back into the record so estimates sharpen over time. Run from any session.

## Multi-session and orchestration skills

Installed globally alongside the skills above; they work together across a feature's lifecycle:

- **[/feature-kickoff](feature-kickoff/SKILL.md)** — scaffolds a multi-session feature workspace (`.archive/<ticket>/`: STATE.md, plan.md with an Execution order section, handoff/ and review/ buses) and delegates the plan draft to `/fable-plan` (which reviews it); two modes (user-mode interactive, agent-mode structure-from-known). Plans and structures only — never authorizes execution
- **[/fable-plan](fable-plan/SKILL.md)** — drafts (or re-drafts) a workspace's `plan.md` by spawning the `plan-author` agent (on Fable), writes it, then runs the plan-reviewer loop and persists the verdict; the one shared plan-authoring implementation, used standalone or via feature-kickoff Step 4. Writes only `.archive/<ticket>/plan.md` — never STATE.md, code, a ledger row, or a lock
- **[/handover](handover/SKILL.md)** — generates a handover doc to continue work in a fresh session or report back to an orchestrator
- **[/review-gate](review-gate/SKILL.md)** — routes a change to the right reviewer slate (code-reviewer always; payments/security reviewers by files touched) and writes a consolidated go/no-go
- **[/archive-index](archive-index/SKILL.md)** — summarizes and indexes a feature's `.archive` workspace when resuming work
- **[/prep-compact](prep-compact/SKILL.md)** — pre-compaction triage: capture state, ask what's next, recommend compact vs handover vs resume
- **[/unattended-run](unattended-run/SKILL.md)** — arms (user-triggered only) and runs a kicked-off feature unattended, serialized via the orchestrator lock
- **[/workspace-lock-protocol](workspace-lock-protocol/SKILL.md)** — the lock's detailed rules, loaded on demand so the always-on `workspace-lock` rule can stay short: which lock id to use (one shared id for a team run, a per-session id when working alone), when a lock is yours to take, how a worker in another repo finds the team's lock, and what to do while waiting for it

## Project-scoped skills

These live in [.claude/skills/](../.claude/skills/) and are available only within this repo:

- **[setup-claude](../.claude/skills/setup-claude/SKILL.md)** — `/setup-claude`: bootstraps the global Claude Code environment from this repo. Installs agents, hooks, skills, rules, the statusline and tool scripts as symlinks, merges permissions into `settings.json`, and installs the pinned git-mcp binary (you register it with `claude mcp add --scope user`). Run from this repo
- **[cleanup-claude](../.claude/skills/cleanup-claude/SKILL.md)** — `/cleanup-claude`: the inverse of `/setup-claude` and the installers, for a clean reinstall. Drives `tools/cleanup-claude/cleanup.sh`, which the user runs: a dry run by default, `--apply` to remove the links into the checkout, the toolkit's settings keys (backup first; the security entries stay unless `--include-security`, and the github MCP guard hook stays unless the user says yes when asked or passes `--include-security`), the plain rc `source` lines and the toolkit's runtime state, and prints the root-owned, MCP, npm and Keychain commands for the user. Keeps login, transcripts, the session registry, CLAUDE.md, settings backups and Keychain. One machine per run
- **[add-account](../.claude/skills/add-account/SKILL.md)** — `/add-account`: adds, removes or moves an alternate Claude Code account launcher (`claude-<name>`, `code-<name>`, macOS only; see `tools/accounts.zsh`). The user answers the `security add-generic-password` prompt in their own terminal, so the secret never reaches the chat, and creates a subscription token with `claude setup-token` themselves; the skill adds the line to `~/.claude/accounts.conf` and checks it with `tools/install-copies.sh status`. Also covers removing an account and moving from a personal launchers file (the user removes its `source` line from `~/.zshrc`; agents edit no rc file)
- **[audit-practices](../.claude/skills/audit-practices/SKILL.md)** — audits documentation quality against the patterns in `docs/`
- **[audit-tooling](../.claude/skills/audit-tooling/SKILL.md)** — audits the tooling artifacts (agents, hooks, skills, settings) themselves
