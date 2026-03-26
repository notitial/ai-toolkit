# 2. Streamlined MADR Template for ADRs

**Status:** accepted
**Date:** 2026-03-27

## Context

The ADR skill needs a template that agents use to create new Architecture Decision Records. Multiple established formats exist with different levels of detail. The template must be useful for AI agents in future sessions — they need to quickly understand what was decided and why, including what alternatives were rejected.

## Options Considered

1. **Nygard original** — Title, Status, Context, Decision, Consequences. Simple but lacks "Options Considered"
2. **Full MADR (Markdown Any Decision Records)** — Adds decision drivers, pros/cons tables per option, links, validation sections. Comprehensive but verbose
3. **Streamlined MADR variant** — Status, Date, Context, Options Considered, Decision, Consequences. Richer than Nygard, leaner than full MADR

## Decision

Use the streamlined MADR variant. It adds "Options Considered" to the Nygard format (critical for AI agents) and "Date" for temporal context, but omits MADR's pros/cons tables, decision drivers, and validation sections.

The "Options Considered" section is the key addition. AI agents benefit from seeing rejected alternatives — without it, they may propose approaches that were already evaluated and dismissed, wasting conversation time re-litigating settled decisions. Full MADR's per-option pros/cons tables add bulk without proportional value; the Decision section already explains why the chosen option won.

## Consequences

- ADRs are scannable — 6 sections, typically 30-60 lines each
- AI agents see rejected alternatives, reducing re-litigation
- The template is embedded in the skill (no external reference file needed at ~20 lines)
- Teams wanting more structure can extend the template per-project without breaking the skill
