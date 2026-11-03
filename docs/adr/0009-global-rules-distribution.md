# 9. Distribute Global Rules via setup-claude Symlinks

**Status:** accepted
**Date:** 2026-07-06

## Context

The global always-on rules (`~/.claude/rules/*.md`) shape every Claude Code session on the
machine, and both the global CLAUDE.md and setup-claude's starter template cross-reference
them (workflow.md, communication.md). Yet they were unmanaged plain files: not tracked in any
repo, not installed by anything, unversioned, and unrecoverable. A fresh machine running
`/setup-claude` would get a CLAUDE.md referencing rules that do not exist.

Global rules are a distinct artifact class from project rules: `.claude/rules/*.md` are
project-scoped and activate on `paths` frontmatter; global rules are always-on and carry
**no frontmatter by design**.

## Options Considered

1. **Repo `rules/` + symlinks via setup-claude** — extend the [ADR 0006](0006-symlink-based-skill-distribution.md)
   pattern with a fourth 1:1 artifact class.
2. **Keep unmanaged** — status quo; rules stay machine-local files.
3. **Inline all rule content into the global CLAUDE.md** — one file, no rules directory.
4. **Copy instead of symlink** — snapshot semantics, re-run setup after every edit.

## Decision

Option 1. The repo gains a root `rules/` directory; a new setup-claude step discovers
`rules/*.md` and symlinks each to `~/.claude/rules/<name>.md`, exactly as agents, hooks,
and skills are installed.

**Conflict policy — deliberately more permissive than the other install steps.** The other
steps never overwrite anything without confirmation. The rules step, when it finds an
existing plain file at the target, compares byte-for-byte (`cmp -s`) against the repo copy:
identical → replace with the symlink automatically (nothing divergent can be lost — that is
the precondition that makes the relaxation safe); different → report a conflict and never
overwrite without confirmation. This handles the expected migration case where the live
files were copied from (or into) the repo before the symlink step existed.

Option 3 was rejected because it would blow the global CLAUDE.md's line budget (docs/01)
while removing the one-concern-per-file structure docs/02 prescribes. Options 2 and 4 fail
the same tests they failed in ADR 0006.

## Consequences

- Extends ADR 0006's artifact table with a fourth row: `rules/*.md` → `~/.claude/rules/<name>.md`.
- Global rules are now versioned, reviewable, and restorable; edits propagate instantly.
- The repo is public: rules content must remain publishable (generic engineering guidance,
  no secrets/PII — verified at introduction).
- No prune step: a rule deleted from the repo leaves an orphaned symlink on every machine that
  installed it. `/setup-claude` reports a dangling link in `~/.claude/rules/` as a conflict instead
  of deleting it, so the user removes it once.
- The audit-tooling skill must audit `rules/*.md` as its own category — project-rule checks
  (e.g., `paths` frontmatter present) do not apply to global rules.
