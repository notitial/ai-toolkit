# Multi-Repo Coordination

How to coordinate AI-agent work across several separate repositories without merging them into a monorepo — covering coordination mechanisms, cross-repo file access, Agent Teams, and the orchestrator-workspace pattern.

## When You Need This

Use this when a change spans repositories that ship and version independently — e.g. a
backend, a mobile app, and one or more web apps sharing an API contract. The work needs
coordination (shared task list, consistent decisions, cross-repo review), but each repo
must keep its own CLAUDE.md, rules, and MCP config.

The naive options each fail at scale:

- **One session per repo, human relays status** (the "manual file bus") — works, but the
  human is the integration point, copy-pasting between chats.
- **Merge into a monorepo** — heavy, disruptive, often impossible (separate deploy
  pipelines, access boundaries).

This document covers the middle path: keep the repos separate, give one session (or one
Agent Team) coordinated access to all of them.

## Three Coordination Mechanisms

| Mechanism | Coordination | Cross-session? | Token cost | Best for |
|---|---|---|---|---|
| **Manual file bus** | Human relays `.archive/` status docs between per-repo sessions | Yes (files persist) | Lowest | Full per-repo isolation; budget-sensitive work |
| **Subagents** (Agent tool) | Lead spawns workers that report back; lead coordinates | No (results return to caller) | Low — results summarized | Focused tasks where only the result matters |
| **Agent Teams** | Lead + teammates share a task list and message each other directly | No (teams don't survive `/resume`) | High (~7× in plan mode) | Work where agents must challenge each other and self-coordinate |

Default to the **file bus + subagents**; reach for **Agent Teams** only when teammates
genuinely need to discuss and self-claim work. See [03-agents.md](03-agents.md),
[05-orchestrator.md](05-orchestrator.md), [07-reviews.md](07-reviews.md).

## Granting Cross-Repo File Access

Two mechanisms add sibling repos to a session without moving them. They are **not**
equivalent:

| | `--add-dir` flag | `permissions.additionalDirectories` (settings.json) |
|---|---|---|
| Persistence | Per session (re-pass each launch) | Persistent — applies whenever the folder is opened |
| Read/write in added repos | Yes | Yes |
| Loads added repos' CLAUDE.md / `.claude/rules` | Yes, **with** `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1` | **No** — file access only |
| VS Code extension | via `/add-dir` (per session) | Yes (the recommended way for the extension) |

- **Do:** use `permissions.additionalDirectories` for the everyday persistent setup, with
  absolute paths (relative paths are not documented as supported there).
- **Do:** keep `--add-dir` for sessions where you also want each repo's CLAUDE.md
  auto-loaded.

### The up-tree gotcha

CLAUDE.md loads **up** the directory tree, not down — a session rooted at a parent (or at
one repo with siblings added) does **not** auto-load the added repos' CLAUDE.md unless
`--add-dir` + `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1` is used. Consequences:

- On the persistent (`additionalDirectories`) path the added repos' CLAUDE.md and
  `.claude/rules/` do **not** load at all — it is file access only.
- Even on the `--add-dir` path, added-repo CLAUDE.md auto-loads to teammates (validated
  v2.1.193), but `.claude/rules/` auto-load to teammates is **unverified**.
- **Always** instruct a worker operating in a repo to read that repo's `CLAUDE.md` and
  `.claude/rules/` first, and put that instruction in its spawn prompt.

### MCP is not inherited up-tree either

Project-scoped MCP servers (a sub-repo's `.mcp.json`) do **not** load from a parent /
orchestrator cwd. If a tool must be available across repos, declare it at **user scope**
(`~/.claude/`), never in a sub-repo's `.mcp.json`.

## Agent Teams Across Repos

Agent Teams (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`, experimental) give a lead session
teammates that share a task list and message each other directly. Key facts for
multi-repo use:

- **Single working directory.** Teammates are rooted at the **lead's** cwd; there is no
  per-teammate working directory (GitHub issue #23669, open). Adding repos to the lead —
  or co-locating under a parent — are the only ways to span repos.
- **Teammates inherit the lead's added directories.** Validated on Claude Code v2.1.193:
  a spawned teammate gets full **read + write** across the lead's added repos via *both*
  `--add-dir` and persistent `permissions.additionalDirectories` — even though the docs
  list only CLAUDE.md / MCP / skills as inherited. This is **undocumented**; re-verify
  after upgrades.
- **Inherited (documented):** the teammate's own CLAUDE.md hierarchy (user/project/local),
  MCP (project + user settings), skills, the spawn prompt, the lead's permission mode and
  effort. **Not inherited:** the lead's conversation history. (Added-repo CLAUDE.md/rules
  loading is the separate, partly-unverified path noted above.)
- **Cost:** ~7× tokens in plan mode per teammate (~21× with three). Use Sonnet teammates,
  keep teams small, and shut them down when done.
- **No persistence:** teammates do not survive `/resume` or `/rewind`. The `.archive/`
  file bus remains the cross-session layer.

**Use teams when** workers must challenge each other or self-coordinate across repos in
one sitting. **Do not use Agent Teams for** budget-sensitive or long-lived work — use the
file bus plus per-repo subagents instead.

## Move vs. Add-Dir

| Choose | When |
|---|---|
| **Add-dir / additionalDirectories** (no move) | Default. Repos stay independent; one workspace grants access. Validated to work for teams (v2.1.193). |
| **Physically co-locate** under a parent | Only if teammate inheritance regresses in a future version, or tooling genuinely needs one real root. Co-location carries the *same* single-cwd and up-tree-CLAUDE.md caveats — its only gain is removing the "added directory" question. |

Prefer add-dir. A move is disruptive and, given inheritance works, usually buys nothing.

## The Orchestrator-Workspace Pattern

Create a lightweight **non-git** workspace folder that coordinates the repos:

- `CLAUDE.md` — a repo manifest (path, purpose, stack per repo) and the working rules
  above (read-repo-CLAUDE.md-first; user-scope MCP).
- `.claude/settings.json` — `permissions.additionalDirectories` listing the repos
  (absolute paths) plus the experimental-teams env flag, scoped to this workspace.
- `.archive/<ticket>/` — the file bus: `STATE.md`, `plan.md` (with its `## Execution order`
  section), `handoff/<role>-status.md`, `review/<date>-<HHMM>-<short-sha>-findings.md`.
- An optional launch script that passes `--add-dir` for the CLAUDE.md-auto-load case.

Operationalize it with the orchestrator skills ([04-skills-and-commands.md](04-skills-and-commands.md)):
scaffold a ticket workspace, hand off bounded sub-tasks, gate merges through a reviewer
slate, and index the workspace on resume.

## Case Study

A four-repo product platform (one backend, one mobile app, two web apps) that shipped
independently and had been coordinated via a manual file bus across four per-repo chats.

- **Goal:** let one session — and ideally an Agent Team — coordinate across all four
  without merging them.
- **Test:** the open question was whether a teammate inherits the lead's added repos. A
  one-teammate probe (Sonnet) on Claude Code v2.1.193 confirmed **read + write**
  propagation via both `--add-dir` and persistent `permissions.additionalDirectories`
  (the latter through the VS Code extension).
- **Outcome:** kept the repos in place; a non-git orchestrator workspace with
  `additionalDirectories` + the file bus replaced the manual relay. No monorepo move.
- **Caveat that survived:** `additionalDirectories` is file-access-only, so each worker is
  still told to read its repo's CLAUDE.md + rules first — cheap insurance against the
  undocumented inheritance behavior changing.

## See Also

- [05-orchestrator.md](05-orchestrator.md) — the autonomous-pipeline coordinator (the
  *how-to-run-work* pattern this composes with).
- [03-agents.md](03-agents.md), [07-reviews.md](07-reviews.md) — subagents and
  multi-agent review.
- [04-skills-and-commands.md](04-skills-and-commands.md) — packaging orchestrator steps
  as skills.
- Sources: GitHub anthropics/claude-code #23669 (per-teammate working directory, open);
  empirical validation on Claude Code v2.1.193 (2026-06).
