---
description: "Create and manage Architecture Decision Records (ADRs). Use when someone asks to create an ADR, record an architecture decision, scaffold ADR support, or when a significant architectural decision surfaces during conversation."
disable-model-invocation: true
---

# ADR

Create and manage Architecture Decision Records — lightweight markdown documents that capture one significant design or architecture decision each. Stored in `docs/adr/` as numbered files.

## Input

- **Topic or title** for the ADR (required for creating, optional for scaffolding)
- **Context** the user provides during conversation (decision background, constraints, options discussed)

## Step 1: Detect mode

Check whether `docs/adr/` exists in the current project.

- **Does not exist:** Run Step 2A (scaffold), then Step 2B if a topic was given.
- **Exists:** Run Step 2B (create new ADR).

## Step 2A: Scaffold ADR directory

Run this once per project to set up ADR infrastructure.

### Create `docs/adr/`

```bash
mkdir -p docs/adr
```

### Write `docs/adr/0000-use-adrs.md`

```markdown
# 0. Use Architecture Decision Records

**Status:** accepted
**Date:** {today's date, YYYY-MM-DD}

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
```

### Write `docs/adr/README.md`

```markdown
# Architecture Decision Records

This directory contains Architecture Decision Records (ADRs) for the project. ADRs capture significant design and architecture decisions along with their context and consequences.

## Format

Each ADR is a numbered markdown file: `NNNN-short-title.md`. The format includes:

- **Status** — proposed, accepted, deprecated, or superseded
- **Date** — when the decision was recorded
- **Context** — what forces are at play, why a decision is needed
- **Options Considered** — alternatives that were evaluated
- **Decision** — what was chosen and why
- **Consequences** — what becomes easier, harder, or constrained

## Index

| # | Title | Status | Date |
|---|-------|--------|------|
| 0000 | [Use Architecture Decision Records](0000-use-adrs.md) | accepted | {today's date} |
```

### Update project CLAUDE.md

If the project has a `CLAUDE.md`, add the following line under the most appropriate existing section (typically "Key Conventions" or "Architecture"):

```
- Before proposing architectural changes, check `docs/adr/` for existing decisions. When a significant architectural decision is made, propose creating an ADR.
```

- If no `CLAUDE.md` exists: skip this step and note it in the report.
- If the directive is already present: skip.
- If no section fits naturally: add a `## Architecture Decisions` section with the directive.

### Report

Tell the user what was created:
- `docs/adr/` directory
- `docs/adr/0000-use-adrs.md` (bootstrapping ADR)
- `docs/adr/README.md` (format reference and index)
- Whether CLAUDE.md was updated

## Step 2B: Create new ADR

### Read existing ADRs

Read all `docs/adr/NNNN-*.md` files. Understand:
- Existing decisions (to avoid contradictions)
- Writing style and level of detail (to maintain consistency)
- Any decisions that relate to the current topic

### Determine next number

Find the highest `NNNN` prefix among existing files. The new ADR is `NNNN + 1`, zero-padded to 4 digits.

### Draft the ADR

Use the template below. Fill in as much as possible from the conversation context. For any section where information is missing, write a clear placeholder.

Present the draft to the user for review before writing. Ask specifically:
- Is the context accurate and complete?
- Are there options that should be added or removed?
- Is the decision correctly captured?

### Write the ADR

After user confirmation, write the file to `docs/adr/NNNN-short-title.md`. Use a lowercase, hyphenated slug for the filename.

### Update index

Add a row to the index table in `docs/adr/README.md`:

```
| NNNN | [Title](NNNN-short-title.md) | proposed | {today's date} |
```

### Report

Tell the user: file path, ADR number, and title.

## ADR Template

```markdown
# {NUMBER}. {Title}

**Status:** {proposed | accepted | deprecated | superseded by [NNNN](NNNN-title.md)}
**Date:** {YYYY-MM-DD}

## Context

{What is the issue? What forces are at play? Why does a decision need to be made?}

## Options Considered

1. **{Option A}** — {one-line summary}
2. **{Option B}** — {one-line summary}
3. **{Option C}** — {one-line summary, if applicable}

## Decision

{What was decided and why. Reference the chosen option.}

## Consequences

- {What becomes easier or better}
- {What becomes harder or worse}
- {What new constraints or follow-up decisions this creates}
```

## Stop Conditions

- Do not write an ADR without user confirmation of the title and decision.
- If the user provides only a topic, draft the Context and Options Considered sections and ask for confirmation before writing.
- Do not overwrite existing ADR files.
- Do not modify existing ADRs unless explicitly asked. Status changes (e.g., marking as superseded) are the exception — confirm with the user first.
- If `docs/adr/README.md` is missing but `docs/adr/` exists, recreate the README by scanning existing ADR files.
