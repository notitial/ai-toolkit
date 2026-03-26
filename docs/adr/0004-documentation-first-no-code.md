# 4. Documentation-First, No Production Code

**Status:** accepted
**Date:** 2026-03-27

## Context

This repo captures patterns and methodologies for AI-assisted development, distilled from real projects. The question is what form this knowledge should take — executable tooling, a framework, configuration templates, or pure documentation.

## Options Considered

1. **Markdown-only knowledge base** — documents, skills, and reference material, no production code or build system
2. **Framework with code** — reusable libraries, CLI tools, or generators that implement the patterns
3. **Config template repository** — copy-paste-ready configuration files for CLAUDE.md, rules, settings.json
4. **Hybrid** — documentation plus reference implementations

## Decision

Markdown-only knowledge base. No production code, no build system, no test suite, no linter. The only exceptions are concrete tools documented inline (MCP servers in `tools/`, skills in `skills/`).

Patterns are more durable than implementations. A framework couples to specific tool versions and breaks when APIs change. Config templates become stale copies — projects diverge from them immediately. Documentation captures the *why* and *when*, not just the *what*, letting readers adapt patterns to their own context. The MCP servers and skills are exceptions because they are tools *about* AI-assisted development, not application code.

## Consequences

- No `package.json`, `Makefile`, or CI pipeline to maintain
- Documents must be self-contained and agent-consumable (structured, scannable, imperative)
- CLAUDE.md explicitly states "no build system" so agents don't waste time searching for one
- Concrete tooling lives in `tools/` and `skills/` as documented exceptions, not as the primary deliverable
- The repo can't be "installed" — it's read and applied, not imported
- Amended: the repo has since grown concrete tools with their own tests (`tools/`, `hooks/`, run together by
  `bash tools/test-all.sh`). "No build system, no test suite" now means no repo-wide one; code stays the exception.
