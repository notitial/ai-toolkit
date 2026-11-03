# 5. Claude Code Configuration as Source of Truth

**Status:** accepted
**Date:** 2026-03-27

## Context

This repo is used with both Claude Code and Cursor. Both tools have their own configuration formats: Claude Code uses `CLAUDE.md` and `.claude/rules/*.md`, Cursor uses `.cursor/rules/*.mdc`. The conventions, paths, and directives are largely the same across both, but maintaining two independent sources leads to drift — the Cursor `project-context.mdc` referenced directories (`prompts/`, `external-research/`) that had been removed months earlier.

## Options Considered

1. **Claude Code as canonical, Cursor mirrors** — maintain CLAUDE.md and `.claude/rules/` as the source of truth, sync Cursor rules from them
2. **Cursor as canonical, Claude mirrors** — maintain `.cursor/rules/` as the source of truth
3. **Independent maintenance** — each tool's config is maintained separately
4. **Shared config with tool-specific adapters** — one source file, build step generates both formats

## Decision

Claude Code configuration is the source of truth. `CLAUDE.md` and `.claude/rules/*.md` are maintained directly. Cursor rules are synced from them — either manually or via a prompt given to a Cursor agent.

Claude Code is the primary development tool for this repo (skills, MCP servers, setup automation are all Claude Code concepts). Cursor is used occasionally. Making the primary tool canonical reduces the chance of drift. Independent maintenance already failed — the Cursor rules went stale. A build step adds complexity for a docs-only repo with no build system.

## Consequences

- Cursor rules may lag behind Claude Code config until manually synced
- New conventions are added to CLAUDE.md first, then propagated to Cursor
- If Cursor becomes the primary tool, this decision should be revisited
