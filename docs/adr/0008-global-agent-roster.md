# 8. Global Agent Roster

**Status:** accepted
**Date:** 2026-03-28

## Context

Claude Code supports custom agents (`~/.claude/agents/`) that work across all projects. Without global agents, each project must define its own agents from scratch — or the user relies entirely on the main conversation context for tasks like code review, security analysis, and ADR management. Global agents provide reusable, role-scoped capabilities that any project can invoke.

The ai-toolkit knowledge base (doc 03) defines agent design patterns: 4-section structure, self-contained execution policies, minimal tool access, model routing by role. These patterns should be applied to the global agents.

## Options Considered

1. **Global agents with hooks** — Three global agents (code-reviewer, security-auditor, adr-advisor) plus two safety hooks (secret detection, destructive command blocking)
2. **Global agents only** — Same three agents, no hooks (rely on prompt-level safety only)
3. **Four agents including explorer** — Add a codebase exploration agent
4. **Project-specific only** — No global agents; define agents per-project as needed

## Decision

Global agents with hooks (option 1). Three agents, each read-only:

| Agent | Model | Purpose |
|-------|-------|---------|
| `code-reviewer` | Sonnet | Code quality review of staged/recent changes |
| `security-auditor` | Opus | Security analysis: secrets, OWASP top 10, PII leakage |
| `adr-advisor` | Sonnet | ADR analysis: find relevant decisions, detect conflicts, draft templates |

Explorer was excluded — Claude Code's built-in Explore subagent already handles fast codebase search. Adding a custom explorer would create overlap without meaningful differentiation.

Two safety hooks complement the agents:
- **Secret detector** — blocks Bash/Write/Edit containing secret patterns (AWS keys, GitHub PATs, PEM keys, etc.)
- **Destructive blocker** — blocks dangerous Bash commands (rm -rf, force push, hard reset, SQL drops)

Design principles applied:
- **Read-only by default** — no agent has Write, Edit, or Bash tools
- **Git MCP over Bash git** — agents use `mcp__git-mcp__*` tools, consistent with ADR 0010
- **Self-contained execution policies** — each agent includes its own allowed/prohibited block
- **Model routing by value** — Opus for security (high-stakes reasoning), Sonnet for review and ADR (balanced), Haiku reserved for future lightweight agents
- **Hooks for deterministic checks** — shell-based regex scanning, no API calls, fast exit

## Consequences

- Global agents are available in every project without per-project configuration
- Read-only constraint means agents cannot accidentally modify code — safe to invoke liberally
- Hooks add ~10ms latency per tool call (acceptable for safety)
- Adding a new global agent requires updating `~/.claude/agents/` only — no per-project changes
- Project-specific agents can override or supplement global ones when needed
- Hook scripts require `jq` to be installed (standard on macOS, needs explicit install on Linux)
- Amended 2026-07-06: `code-reviewer` moved Sonnet → Opus as a permanent adversarial gate: a gate's misses are silent,
  so it pins its tier rather than escalating on failure.
- Amended 2026-10-24: `code-reviewer` moved back to Sonnet, still pinned, because every PR in this repo also gets an
  independent automated review. The README install table is the current roster.
- Amended 2026-11-02: the roster has grown past the three agents above, each still read-only: `plan-reviewer`
  (Sonnet) checks a plan before code is written, `payments-reviewer` (Opus) reviews in-app purchase and billing
  changes, where a miss costs money, and `plan-author` (Fable, medium effort) drafts plans for `/fable-plan`. Drafting
  against a fixed template is structured generation, not adversarial reasoning, so it goes to Fable as the chosen
  specialist; the adversarial weight sits with the reviewer.
