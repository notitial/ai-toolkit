# CLAUDE.md

## Project Overview

ai-toolkit is a personal knowledge base for AI-assisted development patterns. It captures methodologies, lessons, and reusable patterns distilled from real projects.

Documentation-first: the knowledge base in `docs/` is markdown. Working code (TypeScript, shell, Python) lives in `tools/` and `hooks/`, with its own tests. This is distilled, reusable knowledge — not a copy of any project's config files, not a framework, not project-specific.

## Build / Test / Lint

No repo-wide build or lint — `docs/` is markdown only. `bash tools/test-all.sh` runs every suite below and prints a pass/fail table (`--quick` skips the slow ones, `NAME…` runs only those; keep its suite list in step with this one). Exceptions, all under `tools/`:

- `tools/gh-block/` — `bash tools/gh-block/test-gh-block.sh` after changing `hooks/gh-block.sh`.
- `tools/github-mcp/` — `bash tools/github-mcp/test-guard.sh` after changing `guard.sh` or `launch`; `bash tools/github-mcp/test-update-check.sh` after changing `hooks/github-mcp-update-check.sh`.
- `tools/ait.zsh`, `tools/shell-init.zsh` — `bash tools/test-ait.sh` after changing either (needs zsh).
- `tools/install-copies.sh` — `bash tools/test-install-copies.sh` after changing it.
- `tools/statusline.sh` — `bash tools/test-statusline.sh` after changing it; it also checks `rate_color_for` against `tools/pace-vectors.tsv` (regenerate with `bash tools/gen-pace-vectors.sh > tools/pace-vectors.tsv` when the colour maths changes).
- `tools/session-name/` — `bash tools/session-name/test-restore.sh` after changing `hooks/session-name-restore.sh`.
- `tools/cleanup-claude/` — `bash tools/cleanup-claude/test-cleanup.sh` after changing `cleanup.sh` or what `/setup-claude` and the installers put on a machine (needs jq).
- `tools/claude-review/` — `python3 -I -B -m unittest discover -s tools/claude-review/tests` after changing the workflow's inline scripts, the kit's files or this repo's installed copies (`.github/workflows/claude-review.yml`, `.claude/commands/claude-pr-review.md`).
- `tools/audit-logger/`, `tools/destructive-blocker/`, `tools/git-mcp-guard/`, `tools/git-mcp-redirect/`, `tools/secret-detector/`, `tools/secret-redact-output/` — `bash tools/<name>/test-<name>.sh` after changing the matching `hooks/<name>.sh`.
- `tools/workspace-lock/` — `bash tools/workspace-lock/test-guard.sh` and `bash tools/workspace-lock/test-acquire.sh` (about 1.5 min) after changing the lock script or its guard.

Outside those directories, do not search for `package.json`, `Makefile`, or similar.

## Document Structure

- `docs/` — Numbered knowledge base (01–17, no gaps) in reading order; each stands alone but builds on earlier ones. Organized in six groups: Foundations (01–05), Setting up a repo (06–07), Context (08–09), Quality (10–11), Orchestration (12–16), Specialized (17). See `docs/README.md` for the full index.
- `agents/` — Global agent definitions (symlinked to `~/.claude/agents/` via `/setup-claude`).
- `hooks/` — Global hook scripts (symlinked to `~/.claude/hooks/` via `/setup-claude`).
- `rules/` — Global always-on rule files (symlinked to `~/.claude/rules/` via `/setup-claude`; no frontmatter — distinct from project-scoped `.claude/rules/`).
- `skills/` — Global Claude Code skills, symlinked via `/setup-claude`. The README install table is the roster of global installs.
- `tools/` — Reusable tooling (scripts and their tests).
- `.archive/` — Gitignored working area (session artifacts, handovers, audits) plus archived source material. Do not modify archived source subfolders; new work goes in new subfolders.

## Key Conventions

- `docs/` is markdown only. Code files only for a concrete tool (`tools/`) or hook (`hooks/`).
- Documents are agent-consumable: structured, scannable, clear section headers, bullets over prose.
- Prefer concrete case studies over abstract advice. Show the pattern, then explain why it works.
- Keep documents focused on one topic. Cross-reference instead of duplicating.
- When adding knowledge: check the existing documents before creating a new one (`docs/README.md` is the index).
- When adding an agent, hook, skill, or rule: update the README install table — the roster of global installs. Describe a skill in `skills/README.md` (project-scoped ones are listed only there) and a tool in `tools/README.md`.
- Lead with the generic, reusable pattern. Illustrate with a case study. Cite the source (project, file, run).
- Sizing: CLAUDE.md under 200 lines. Rules under 300 lines. See docs 01 and 02 for detailed guidance.
- For detailed writing standards when editing `docs/`, see `.claude/rules/documentation-quality.md`.
- Before proposing architectural changes, check `docs/adr/` for existing decisions. When a significant architectural decision is made, propose creating an ADR.

## Git Conventions

- Commit titles: `<prefix>: <description>` — prefix is one of `docs` (knowledge base, ADRs), `feat` (new tool/agent/skill/hook capability), `fix` (broken behavior corrected), `chore` (repo maintenance). Never a bare, unprefixed title.
- Imperative mood, lowercase, title ≤50 characters. Specifics go in the body, not the title.
- One commit per logical change. Squash review-churn ("address findings", "round-N fixes") into the commit it amends before landing; never commit the same fix twice.
- Squash-merge PRs (the repo allows nothing else): the PR title, with its `(#N)`, becomes the commit title, and the PR description becomes the commit body — so the title must be conventional and the description must stand as the commit's record. Avoid merge commits on `main` — pull with `--ff-only`.
- No force push. A PR branch that falls behind `main` gets `main` merged in, never a rebase (`rules/workflow.md`, Stale PR Branches).
- No worktrees; branch in a plain clone under `/tmp` (see Where agents edit). Never push to `main`; land every change through a PR.
- Check for secrets before committing — no `.env`, API keys, credentials.
- Every non-draft PR gets an automatic Claude review (`.github/workflows/claude-review.yml`, see ADR 0013); its verdict is a signal, not a required approval. Every PR to `main` also runs `.github/workflows/ci.yml`: `Install Checks`, required, fails on a hook committed without the executable bit; `Tool Checks`, not required, runs `tools/test-all.sh --quick`.

## Where agents edit

The live checkout is what `/setup-claude` links into `~/.claude` (hooks, rules, skills, agents, the status line, the tool scripts) and what the github MCP launcher and guard run from, so a branch or half-done edit there goes live on the next tool call, MCP start or window reload. It stays on `main` and moves only with `git pull --ff-only` after a merge: the merge plus that pull is the install.

- Code changes go in a plain clone under `/tmp`, such as `/tmp/ai-toolkit-<task>`, never a worktree. Git MCP calls carry `path` set to that clone. Never edit a tracked file in the live checkout.
- `.archive/` (STATE.md, handoffs) stays in the live checkout: it is gitignored, so a clone has none.
- `/tmp` is wiped on reboot: push the branch before stopping or handing over.
- A long-lived session may still run in the live folder, since the tool that tracks it keys it to the folder it started in; it edits in its clone.
- `/setup-claude` backs this with permission rules: asks on edits of `~/.claude/settings.json` and `settings.local.json`, denies on the live checkout's `.git/`, `hooks/`, `rules/`, `agents/`, `skills/`, `tools/github-mcp/`, `tools/workspace-lock/`, `tools/statusline.sh`, `tools/shell-init.zsh` and `tools/ait.zsh`. A shell write (`sed -i`, a redirect, `git checkout` in the live checkout) is not an Edit, so no rule stops it: the clone discipline is the control.

## Key Paths

| Path | Purpose |
|------|---------|
| `docs/README.md` | Document index and reading order |
| `docs/01-project-instructions.md` | CLAUDE.md design guidance (this repo follows it) |
| `docs/02-rules.md` | Rule authoring patterns |
| `docs/06-repo-initialization.md` | Bootstrap prompts and AI maturity model |
| `agents/` | Global agent definitions (roster: README install table) |
| `hooks/` | Global hook scripts (roster: README install table) |
| `rules/` | Global always-on rules installed to `~/.claude/rules/` (see ADR 0009) |
| `skills/` | Global skills (roster: README install table) |
| `tools/` | Reusable tooling (statusline, scripts) |
| `tools/workspace-lock/` | Advisory lock serializing independent unattended orchestrators (used by the `unattended-run` skill) |
| `tools/claude-review/` | The Claude PR review kit: the canonical workflow and review command other repos copy (this repo runs the same copies), its setup guide, tests and reviewer cases; `/add-claude-review` installs it |
| `tools/github-mcp/` | Optional guarded GitHub MCP setup: a launcher plus a hook limiting which GitHub writes agents may make, run from the live checkout, which they require to be reviewed code (clean main, HEAD on origin/main, binary hash pinned); its README covers install and token rotation |
| `tools/shell-init.zsh` | The one line `~/.zshrc` sources (`source ~/.claude/tools/shell-init.zsh`): loads `tools/ait.zsh` |
| `tools/ait.zsh` | zsh helpers: `ait`, `ait-status`, `ghm-status` (the GitHub MCP wiring check), `ghm-test` |
| `.claude/settings.json` | Project-level permissions allowlist (no hooks) |
| `.claude/rules/` | Path-scoped rules (loaded on demand) |
| `.claude/commands/` | Project command claude-pr-review (a fork of the code-review command from Anthropic's Claude Code plugins) |
| `.github/workflows/` | Automatic Claude PR review workflow (ADR 0013); `ci.yml`, the test suites on every PR |
| `assets/icon/` | The project icon (SVG, mono variant, PNGs from 16 to 1024 px) |
| `README.md` | Repo overview, install table and links |
