---
description: Documentation quality standards for knowledge base articles in docs/
paths:
  - "docs/**"
---

# Documentation Quality Standards

These standards apply when creating or editing documents in `docs/`.

## Document Structure

- Start every document with an H1 title and a one-line scope statement explaining what the document covers.
- Use H2 for major sections, H3 for subsections. Do not skip heading levels.
- Lead with "What" and "Why" before "How." Readers need context before mechanics.
- End with a **Case Study** section when applicable. Use anonymized real-project examples.
- Include a source citation for every claim where applicable.

## Writing for Agent Consumption

- Bullets over paragraphs for constraints and guidelines.
- Tables for structured comparisons (e.g., role/permission, category/addition, before/after).
- Imperative statements: "Use X" not "We prefer X" or "It is recommended to use X."
- Do/Don't markers: use "Do not" or "Never:", not "try to avoid" or "consider not using."
- Code examples only when the pattern is complex enough to need them. Prefer showing real config over pseudocode.

## Content Decisions

- Before creating a new document, verify the topic is not already covered — check the existing documents (`docs/README.md` is the index).
- One document = one topic. If a document covers two distinct concerns, split it.
- Generic pattern first, then case study illustration. The pattern must be reusable across projects.
- Cross-reference related documents with relative links: `See [02-rules.md](02-rules.md)` rather than restating content.
- Do not duplicate content from CLAUDE.md. CLAUDE.md carries one-liners; this rule and the documents carry detail.

## Sizing

- Overview sections: 3–8 lines.
- Detailed sections: 15–40 lines.
- Case study sections: 15–30 lines.
- Total document: under 300 lines. If exceeding, split by concern.

## Adding New Documents

- Assign the next sequential number (e.g., `18-topic-name.md`).
- Place in the appropriate group: Foundations, Setting up a repo, Context, Quality, Orchestration, or Specialized.
- Update the index when adding or renaming documents: `docs/README.md` — reading order and group placement.
