# Architecture Decision Records

The significant design decisions for this repo, with their context and consequences. Check them before proposing a
change to something they cover.

## Format

Each ADR is a numbered file, `NNNN-short-title.md`, in the streamlined MADR template
([ADR 0002](0002-streamlined-madr-template.md)):

- **Status:** proposed, accepted, deprecated or superseded; the index adds "amended" when the ADR carries an
  amendment
- **Date:** when the decision was recorded, plus an optional **Accepted** date when it was accepted later
- **Context:** the forces at play and why a decision is needed
- **Options Considered:** the alternatives evaluated
- **Decision:** what was chosen and why
- **Consequences:** what becomes easier, harder or constrained

An ADR records what was decided at the time. A later change gets a dated amendment line or a new ADR, not a silent
rewrite.

## Index

| # | Title | Status | Date |
|---|-------|--------|------|
| 0001 | [Use Architecture Decision Records](0001-use-adrs.md) | accepted | 2026-03-27 |
| 0002 | [Streamlined MADR Template for ADRs](0002-streamlined-madr-template.md) | accepted | 2026-03-27 |
| 0003 | [Numbered Sequential Docs with Category Grouping](0003-numbered-sequential-docs.md) | accepted | 2026-03-27 |
| 0004 | [Documentation-First, No Production Code](0004-documentation-first-no-code.md) | accepted, amended | 2026-03-27 |
| 0005 | [Claude Code Configuration as Source of Truth](0005-claude-code-as-source-of-truth.md) | accepted | 2026-03-27 |
| 0006 | [Symlink-Based Artifact Distribution](0006-symlink-based-skill-distribution.md) | accepted, amended | 2026-03-27 |
| 0007 | [Global Setup Skill Over Manual Installation](0007-global-setup-skill.md) | accepted, amended | 2026-03-27 |
| 0008 | [Global Agent Roster](0008-global-agent-roster.md) | accepted, amended | 2026-03-28 |
| 0009 | [Distribute Global Rules via setup-claude Symlinks](0009-global-rules-distribution.md) | accepted, amended | 2026-07-06 |
| 0010 | [MCP Git Over Bash Git for Agent Permissions](0010-mcp-git-over-bash-git.md) | accepted | 2026-03-27 |
| 0011 | [Shell-Hook Enforcement for Agent Guardrails](0011-shell-hook-enforcement.md) | accepted | 2026-04-02 |
| 0012 | [Workspace Lock](0012-overnight-orchestrator-lock.md) | accepted, amended | 2026-07-03 |
| 0013 | [App-Owned PR Review, Verdict as a Signal](0013-app-owned-pr-review.md) | accepted | 2026-10-23 |
| 0014 | [Run Installs From the Live Checkout](0014-live-checkout-installs.md) | accepted | 2026-11-06 |
| 0015 | [A Vendored Build Kit With a Standard-Library MCP Server](0015-vendored-build-kit.md) | accepted | 2026-11-08 |
| 0016 | [Guarded Issue, Label and Project Writes](0016-guarded-issue-and-project-writes.md) | accepted | 2026-11-08 |

ADR 0012's file name keeps "overnight-orchestrator-lock" from its first title; links depend on the name, so it
stays.
