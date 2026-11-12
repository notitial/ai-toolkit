# CLAUDE.md

## Project Overview

ai-toolkit is a personal knowledge base for AI-assisted development patterns. It captures methodologies, lessons, and reusable patterns distilled from real projects.

Documentation-first: the knowledge base in `docs/` is markdown. Working code (TypeScript, shell, Python) lives in `tools/` and `hooks/`, with its own tests. This is distilled, reusable knowledge — not a copy of any project's config files, not a framework, not project-specific.

## Build / Test / Lint

No repo-wide build or lint — `docs/` is markdown only. `bash tools/test-all.sh` runs every suite and prints a pass/fail table (`--quick` skips the slow ones, `NAME…` runs only those; keep its suite list in step with the "Test suites" list in `tools/README.md`, which names the suite to run after changing each hook or tool).

Outside the directories in that list, do not search for `package.json`, `Makefile`, or similar.

## Document Structure

- `docs/` — Numbered knowledge base (01–18, no gaps) in reading order; each stands alone but builds on earlier ones. Organized in six groups: Foundations (01–05), Setting up a repo (06–07), Context (08–09), Quality (10–11), Orchestration (12–16), Specialized (17–18). See `docs/README.md` for the full index.
- `agents/` — Global agent definitions (symlinked to `~/.claude/agents/` via `/setup-claude`).
- `hooks/` — Global hook scripts (symlinked to `~/.claude/hooks/` via `/setup-claude`).
- `rules/` — Global always-on rule files (symlinked to `~/.claude/rules/` via `/setup-claude`; no frontmatter — distinct from project-scoped `.claude/rules/`; see ADR 0009).
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
- Squash-merge PRs (the repo allows nothing else): the PR title, with its `(#N)`, becomes the commit title, and the PR description becomes the commit body — so the title must be conventional and the description must stand as the commit's record. After a fix round changes what a PR does (counts, behavior, review status), re-read the description against the final head and update it before handing the PR over: a merged commit message can't be fixed. Avoid merge commits on `main` — pull with `--ff-only`.
- No force push. A PR branch that falls behind `main` gets `main` merged in, never a rebase (`rules/workflow.md`, Stale PR Branches).
- No worktrees; branch in a plain clone under `/tmp` (see Where agents edit). Never push to `main`; land every change through a PR.
- Check for secrets before committing — no `.env`, API keys, credentials.
- Every non-draft PR gets an automatic Claude review (`.github/workflows/claude-review.yml`, see ADR 0013); its verdict is a signal, not a required approval. Every PR to `main` also runs `.github/workflows/ci.yml`: `Install Checks`, required, fails on a hook committed without the executable bit; `Tool Checks`, required, runs `tools/test-all.sh --quick`. `.github/workflows/secret-scan.yml` runs `Secret Scan / gitleaks` on every PR to `main`, also required.

## Where agents edit

The live checkout is what `/setup-claude` links into `~/.claude` (hooks, rules, skills, agents, the status line, the tool scripts) and what the github MCP launcher and guard run from, so a branch or half-done edit there goes live on the next tool call, MCP start or window reload. It stays on `main` and moves only with `git pull --ff-only` after a merge: the merge plus that pull is the install.

- Code changes go in a plain clone under `/tmp`, such as `/tmp/ai-toolkit-<task>`, never a worktree. Git MCP calls carry `path` set to that clone. Never edit a tracked file in the live checkout.
- `.archive/` (STATE.md, handoffs) stays in the live checkout: it is gitignored, so a clone has none.
- `/tmp` is wiped on reboot: push the branch before stopping or handing over.
- A long-lived session may still run in the live folder, since the tool that tracks it keys it to the folder it started in; it edits in its clone.
- `/setup-claude` backs this with permission rules: asks on edits of `~/.claude/settings.json` and `settings.local.json`, denies on the live checkout's `.git/`, `hooks/`, `rules/`, `agents/`, `skills/`, `tools/github-mcp/`, `tools/workspace-lock/`, `tools/statusline.sh`, `tools/shell-init.zsh`, `tools/ait.zsh`, `tools/accounts.zsh` and `tools/install-copies.sh`. A shell write (`sed -i`, a redirect, `git checkout` in the live checkout) is not an Edit, so no rule stops it: the clone discipline is the control.

## Patterns

Copy these when adding the same kind of file:

- A hook and its test: `hooks/gh-block.sh` (header says why, what it matches, known gaps and that it fails closed; bash 3.2) with `tools/gh-block/test-gh-block.sh` (runs the hook under `HOOK_SHELL` with a temp `HOME`, one line per deny or pass case).
- A skill: `skills/archive-index/SKILL.md` (a `description` that says when to run it, `disable-model-invocation`, input, numbered steps, output).
- A knowledge-base doc: `docs/09-structural-context.md` (scope line, the pattern, choosing between options, anti-patterns, case study, sources).

## Key Paths

| Path | Purpose |
|------|---------|
| `docs/01-project-instructions.md` | CLAUDE.md design guidance (this repo follows it) |
| `docs/02-rules.md` | Rule authoring patterns |
| `docs/06-repo-initialization.md` | Bootstrap prompts and AI maturity model |
| `tools/README.md` | Every tool: what it does, its README, and the test suite to run after a change |
| `.claude/settings.json` | Project-level permissions allowlist (no hooks) |
| `.claude/rules/` | Path-scoped rules (loaded on demand) |
| `.claude/commands/` | Project command claude-pr-review (a fork of the code-review command from Anthropic's Claude Code plugins) |
| `.github/workflows/` | Automatic Claude PR review workflow (ADR 0013); `ci.yml`, the test suites on every PR |
| `assets/icon/` | The project icon (SVG, mono variant, PNGs from 16 to 1024 px) |
| `README.md` | Repo overview, install table and links |
