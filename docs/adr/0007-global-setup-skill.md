# 7. Global Setup Skill Over Manual Installation

**Status:** accepted
**Date:** 2026-03-27 · **Amended:** 2026-11-06 (ADR 0014: committed files only)

## Context

Users need to install skills, configure permissions, set up MCP servers, and maintain a global CLAUDE.md. This involves multiple files across `~/.claude/` — settings.json, mcp.json, skills symlinks, and CLAUDE.md. The question is how to manage this setup: manually via README instructions, a shell script, or an AI-executable skill.

## Options Considered

1. **Idempotent setup skill (`/setup-claude`)** — a SKILL.md that Claude Code itself executes, reading templates from this repo and applying them to `~/.claude/`
2. **Shell script** — a `setup.sh` that copies/symlinks files and modifies JSON
3. **Manual README instructions** — step-by-step instructions the user follows
4. **Package manager** — publish as a Homebrew formula or npm package

## Decision

Use an idempotent setup skill. `/setup-claude` is a SKILL.md that Claude Code executes from the ai-toolkit repo. It reads templates (`safe-permissions.json`, `global-claude-md.md`), discovers skills via `skills/*/SKILL.md`, and applies everything to `~/.claude/`. It is safe to run repeatedly — it detects existing state and only changes what's needed.

The skill approach has a unique advantage: Claude Code is both the installer and the runtime. It can read the current state, compare against templates, make intelligent decisions (skip vs add vs migrate), and report what changed — all in natural language. A shell script would need brittle JSON parsing. Manual instructions are error-prone and don't handle migration (like Bash→MCP permission replacement). A package manager adds publishing overhead for a tool each user runs from their own clone.

## Consequences

- Setup requires Claude Code itself — you can't bootstrap without it
- The skill handles migration logic (removing old Bash git permissions, dropping unnecessary plugins) alongside installation
- Templates in the repo are the source of truth — changing a template and re-running `/setup-claude` updates the global config
- The skill only touches `~/.claude/` — it never modifies project-level files
- Adding a new skill to the repo is automatic — the glob pattern discovers it on next run
- Amended by [ADR 0014](0014-live-checkout-installs.md) (2026-11-06): `/setup-claude` links only the artifacts committed at `HEAD` (`bash tools/install-copies.sh roster`), not every matching file on disk.
