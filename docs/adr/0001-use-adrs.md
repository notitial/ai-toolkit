# 1. Use Architecture Decision Records

**Status:** accepted
**Date:** 2026-03-27

## Context

Architectural decisions made during development are lost between conversations. CLAUDE.md captures rules and conventions, commit messages capture what changed, but neither captures why a particular choice was made over alternatives. Without this context, contributors — human and AI — re-litigate decisions that were already resolved.

## Options Considered

1. **ADRs in `docs/adr/`** — lightweight numbered markdown files, one per decision, following the format described by Michael Nygard
2. **Decision log in a single file** — one file with all decisions appended chronologically
3. **Inline comments in code** — document decisions where they apply

## Decision

Use Architecture Decision Records stored in `docs/adr/`. Each ADR is a numbered markdown file recording one decision: the context, options considered, what was decided, and the consequences.

ADRs are the right granularity for AI agents — each file is self-contained, scannable, and small enough to load into context. A single log file grows unbounded. Inline comments lack structure and are invisible outside the file they live in.

## Consequences

- Every significant architectural decision gets a permanent, structured record
- AI agents can check `docs/adr/` before proposing changes, avoiding re-litigation of settled decisions
- The team must agree on what constitutes "significant" — not every choice needs an ADR
- ADRs accumulate over time; superseded decisions should be marked, not deleted
