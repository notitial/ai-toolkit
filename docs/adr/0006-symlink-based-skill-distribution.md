# 6. Symlink-Based Artifact Distribution

**Status:** accepted
**Date:** 2026-03-27 · **Amended:** 2026-11-06 (ADR 0014: committed files only)

## Context

This repo produces globally-installed artifacts — skills, agents, and hooks — that need to be available under `~/.claude/` for Claude Code to discover them. The question is how to get them there.

| Artifact type | Repo location | Install target |
|---------------|---------------|----------------|
| Skills | `skills/*/SKILL.md` | `~/.claude/skills/<name>` |
| Agents | `agents/*.md` | `~/.claude/agents/<name>.md` |
| Hooks | `hooks/*.sh` | `~/.claude/hooks/<name>.sh` |

All three are 1:1 mappings — the source file IS the installed file, not a template that gets transformed.

## Options Considered

1. **Symlinks from repo to `~/.claude/`** — `ln -s /path/to/ai-toolkit/skills/adr ~/.claude/skills/adr`
2. **Copy files** — duplicate into `~/.claude/` during setup
3. **npm/package manager** — publish as packages, install globally
4. **Git submodule** — add ai-toolkit as a submodule in each project

## Decision

Use symlinks for all 1:1 artifacts. The `setup-claude` skill discovers artifacts in `skills/`, `agents/`, and `hooks/` and creates symlinks at their install targets.

Symlinks mean edits to the ai-toolkit repo propagate instantly — no reinstall step. This fits the repo's iterative development model where artifacts are refined frequently. Copies would require re-running setup after every change. npm packaging adds publishing overhead for a repo each user runs from their own clone. Submodules are heavy and project-scoped, not user-scoped.

Config templates (`safe-permissions.json`, `global-claude-md.md`) are NOT symlinked — they are merge references that setup-claude compares against existing config, not files installed as-is.

## Consequences

- Artifact updates are instant — edit the source, every project sees the change
- Artifacts break if the ai-toolkit repo moves — symlinks become dangling (mitigated by `setup-claude` detecting and reporting conflicts)
- The repo must stay checked out on disk — artifacts aren't standalone
- `setup-claude` is idempotent — re-running detects existing correct symlinks and skips them
- Repo structure mirrors the install target: `agents/` → `~/.claude/agents/`, `hooks/` → `~/.claude/hooks/`, `skills/` → `~/.claude/skills/`
- Extended by [ADR 0009](0009-global-rules-distribution.md): `rules/` → `~/.claude/rules/` added as a fourth 1:1 artifact class (with a byte-match auto-replace conflict policy specific to that step)
- Amended by [ADR 0014](0014-live-checkout-installs.md) (2026-11-06): `/setup-claude` links only the artifacts committed at `HEAD` (`bash tools/install-copies.sh roster`), not every matching file on disk.
