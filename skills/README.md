# Skills

Global skills live in this folder and are symlinked into `~/.claude/skills/` by `/setup-claude`. Project-scoped skills live in [.claude/skills/](../.claude/skills/) and work only inside this repo. The install roster is the table in the [README](../README.md#what-gets-installed).

## Global skills

### [/audit-claude](audit-claude/SKILL.md)

Audits any project's AI setup against the patterns in [docs/](../docs/README.md). Evaluates CLAUDE.md, rules, agents, skills, and settings, and checks that the structural context is real: listed key paths and golden files exist, and an enabled code-intelligence plugin has its language server on PATH. Classifies maturity level (A/B/C) and produces prioritized recommendations. Run from the target project. User-invoked only: an agent cannot start it, so the person types `/audit-claude`.

### [/adr](adr/SKILL.md)

Creates and manages Architecture Decision Records. Scaffolds `docs/adr/` on first use, then creates sequentially numbered ADRs from a consistent template. Run from any project.

### [/repo-setup](repo-setup/SKILL.md)

Sets up a new repo against the repo-setup checklist ([docs/07](../docs/07-new-repo-setup.md)): audits it (the audit is [/audit-repo](audit-repo/SKILL.md)'s Steps 2–4), then on the user's go writes the missing files on a branch and opens a PR. Every repo setting, ruleset, App or secret change is printed as `gh` commands for the user; the skill changes none itself. Decided values live in [repo-setup/defaults.md](repo-setup/defaults.md), with the default [pre-commit config](../tools/gitleaks/.pre-commit-config.yaml); the rest is asked. `/repo-setup <owner/repo>` audits only, `/repo-setup setup <owner/repo>` audits then fixes.

### [/audit-repo](audit-repo/SKILL.md)

Reviews an existing repo against the same standard and closes what it can. It reads the repo's files and live GitHub state (a block of `gh` GETs the user runs, plus the github MCP), judges each item of [audit-repo/references/checklist.md](audit-repo/references/checklist.md) as present, missing or different, and saves the table. File gaps (workflows, pre-commit config, `dependabot.yml`, PR template, CLAUDE.md conventions) it fixes on a branch and opens as a PR, on the user's go. Live gaps (ruleset, merge settings, required checks, Dependabot alerts and security updates, the review kit's variables, secrets and App) it never writes: it prints the exact `gh` command for each, one step at a time, for the owner to run. `/audit-repo <owner/repo>`.

### [/add-claude-review](add-claude-review/SKILL.md)

Adds the automatic Claude PR review to the current repo: writes the caller `.github/workflows/claude-review.yml`, which calls the reusable kit ([tools/claude-review/](../tools/claude-review/README.md)) at `@main`. Asks for the runner labels, the key-job runner, the auth mode, the secret name and the reviewer GitHub App, checks the caller against the kit's shape and opens the PR; the user creates or installs the App, sets the variables and secrets, and merges. Also reconfigures a caller and moves a SHA pin to `@main`. Run from the target repo.

### [/claude-review-loop](claude-review-loop/SKILL.md)

Answers the automatic Claude review on a PR in a repo that runs the kit (`.github/workflows/claude-review.yml`): wait for the checks, read the findings, fix each or reply in its thread, then ask for one `@claude review --comments` run. Loaded on demand so the always-on `workflow` rule keeps only the trigger; an agent loads it before opening a PR there, marking one ready or pushing review fixes.

### [/add-build-kit](add-build-kit/SKILL.md)

Adds the opt-in iOS and Android build, test and lint tools from [tools/build-kit/](../tools/build-kit/README.md) to the current repo. Copies the kit into `tools/build-kit/` with a VERSION stamp, writes `.build-kit.json` (the allow-lists) from what it detects and what the user answers, adds the `ios` and `android` entries to `.mcp.json` and the named-tool permissions to `.claude/settings.json` (never a wildcard), and opens the PR; the exact diffs of the two files are shown first and wait for the user's go. Also upgrades an existing copy by diff. Run from the target repo.

### [/eta](eta/SKILL.md)

Reports where the current task stands and a grounded ETA, backed by a global learning KB at `~/.claude/.eta/` that improves as real durations are recorded. Produces a progress overview, a completion table (mirrors the ticket's structure when one is in scope, else done/remaining), and an ETA with a range and its basis; `/eta close` reconciles the actual duration back into the record so estimates sharpen over time. Run from any session.

### [/review-page](review-page/SKILL.md)

Builds one throwaway local HTML page that shows two or more real options as rendered previews side by side (each in its own frame at a phone, tablet or laptop width, light or dark), with a recommendation, Pick buttons, notes and one fixed JSON block to paste back. The kit and example live in [review-page/page.html](review-page/page.html); a session copies it under `.archive/review/`, replaces only the spec block and opens it in Chrome. The page is never published, has no tests and is deleted freely. Also starts from plain phrases such as "show me the options side by side".

## Multi-session and orchestration skills

Installed globally alongside the skills above; they work together across a feature's lifecycle:

- **[/feature-kickoff](feature-kickoff/SKILL.md)** — scaffolds a multi-session feature workspace (`.archive/<ticket>/`: STATE.md, plan.md with an Execution order section, handoff/ and review/ buses) and delegates the plan draft to `/fable-plan` (which reviews it); two modes (user-mode interactive, agent-mode structure-from-known). Plans and structures only — never authorizes execution
- **[/fable-plan](fable-plan/SKILL.md)** — drafts (or re-drafts) a workspace's `plan.md` by spawning the `plan-author` agent (on Fable), writes it, then runs the plan-reviewer loop and persists the verdict; the one shared plan-authoring implementation, used standalone or via feature-kickoff Step 4. Writes only `.archive/<ticket>/plan.md` — never STATE.md, code, a ledger row, or a lock
- **[/handover](handover/SKILL.md)** — generates a handover doc to continue work in a fresh session or report back to an orchestrator
- **[/review-gate](review-gate/SKILL.md)** — routes a change to the right reviewer slate (code-reviewer always; payments/security reviewers by files touched) and writes a consolidated go/no-go
- **[/archive-index](archive-index/SKILL.md)** — summarizes and indexes a feature's `.archive` workspace when resuming work
- **[/prep-compact](prep-compact/SKILL.md)** — pre-compaction triage: capture state, ask what's next, recommend compact vs handover vs resume
- **[/workspace-lock-protocol](workspace-lock-protocol/SKILL.md)** — the lock's detailed rules, loaded on demand so the always-on `workspace-lock` rule can stay short: which lock id to use (a shared slug for an open team, a per-session id when working alone), when a lock is yours to take, how a worker in another repo finds the team's lock, and what to do while waiting for it

## Project-scoped skills

These live in [.claude/skills/](../.claude/skills/) and are available only within this repo:

- **[setup-claude](../.claude/skills/setup-claude/SKILL.md)** — `/setup-claude`: bootstraps the global Claude Code environment from this repo. Installs agents, hooks, skills, rules, the statusline and tool scripts as symlinks, merges permissions into `settings.json`, and checks the registration of the git MCP server, which runs from the checkout (you register it with `claude mcp add --scope user`). Run from this repo
- **[cleanup-claude](../.claude/skills/cleanup-claude/SKILL.md)** — `/cleanup-claude`: the inverse of `/setup-claude` and the installers, for a clean reinstall. Drives `tools/cleanup-claude/cleanup.sh`, which the user runs: a dry run by default, `--apply` to remove the links into the checkout, the toolkit's settings keys (backup first; the security entries stay unless `--include-security`, and the github MCP guard hook stays unless the user says yes when asked or passes `--include-security`), the plain rc `source` lines and the toolkit's runtime state, and prints the root-owned, MCP and Keychain commands for the user. Keeps login, transcripts, the session registry, CLAUDE.md, settings backups and Keychain. One machine per run
- **[add-account](../.claude/skills/add-account/SKILL.md)** — `/add-account`: adds an alternate Claude Code account launcher (`claude-<name>`, `code-<name>`, macOS only; see `tools/accounts.zsh`). The user answers the `security add-generic-password` prompt in their own terminal, so the secret never reaches the chat, and creates a subscription token with `claude setup-token` themselves; the skill adds the line to `~/.claude/accounts.conf` and checks it with `tools/install-copies.sh status`
- **[remove-account](../.claude/skills/remove-account/SKILL.md)** — `/remove-account`: removes one account launcher or all of them. The skill drops the lines from `~/.claude/accounts.conf`; the user deletes the Keychain items and the accounts' VS Code folders with the commands it gives (deleting an item does not revoke the token or key)
- **[audit-practices](../.claude/skills/audit-practices/SKILL.md)** — audits documentation quality against the patterns in `docs/`
- **[audit-tooling](../.claude/skills/audit-tooling/SKILL.md)** — audits the tooling artifacts (agents, hooks, skills, settings) themselves
