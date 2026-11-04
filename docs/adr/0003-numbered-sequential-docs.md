# 3. Numbered Sequential Docs with Category Grouping

**Status:** accepted
**Date:** 2026-03-27

## Context

The knowledge base contains 14 documents covering topics from project instructions to prompt engineering. These need an organization scheme that works for both humans (reading to learn) and AI agents (loading specific context). Documents are standalone but build on concepts from earlier ones.

## Options Considered

1. **Numbered sequential with categories** — `01-project-instructions.md` through `14-prompt-engineering.md`, grouped into Foundations, Workflows, Quality, Setup, Specialized
2. **Flat directory with alphabetical naming** — `agents.md`, `context-management.md`, etc.
3. **Nested directories by category** — `foundations/project-instructions.md`, `workflows/skills.md`, etc.
4. **Wiki-style with cross-links** — no ordering, navigate by links

## Decision

Numbered sequential files with category grouping. Each document gets a two-digit prefix (`01`–`14`) that establishes reading order. Categories (Foundations, Workflows, Quality, Setup, Specialized) group related documents but don't create subdirectories — everything stays in `docs/`.

The numbering solves two problems: it gives newcomers a clear reading path (start at 01, read forward), and it gives agents a predictable naming convention (`docs/01-*.md` is always project instructions). Flat files in one directory are simpler than nested folders — agents can glob `docs/*.md` to find everything. Alphabetical naming loses the pedagogical progression. Wiki-style works for reference but not for learning.

## Consequences

- Adding a new document means assigning the next number and updating two indexes (`docs/README.md` and `README.md`; one index since the 2026-11-04 amendment below)
- One document per topic — if a document covers two concerns, it must be split
- Documents are standalone (can be read in isolation) but build on earlier concepts (reading in order is recommended)
- The category grouping is informational only — it appears in the index, not in the file paths
- Capped at ~20 documents before the sequential model becomes unwieldy
- Amended 2026-11-04: the docs were renumbered once into a gap-free reading order (01–17) in six groups: Foundations,
  Setting up a repo, Context, Quality, Orchestration, Specialized. The earlier numbers were kept from earlier history, so the
  gaps read as missing documents. `docs/README.md` is now the only docs index (the top-level
  `README.md` links to it), so a new document updates one index, not two. New documents still take the next number.
