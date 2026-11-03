---
description: "Audit knowledge base documents for reusability and pattern focus. Use when someone asks to review docs for durability, check if content is too tool-specific, evaluate whether practices are reusable, or audit documentation for long-term relevance."
disable-model-invocation: true
---

# Audit Practices

Review the knowledge base (`docs/`) for reusability, pattern focus, and long-term durability. Flag content that is coupled to specific tools, versions, or products rather than teaching transferable patterns.

## Purpose

This repo's value comes from durable patterns, not tool recommendations. Tools change — patterns survive. This assessment catches content drift: docs that started as pattern guides but accumulated tool-specific advice that will go stale.

## Input

Optional: a specific document number or range (e.g., "just doc 09", "docs 07-10"). If no input is specified, assess all documents in `docs/`.

## Step 1: Read the documents

Read all target documents in `docs/`. For each document, evaluate against the criteria in Step 2.

## Step 2: Evaluate each document

Apply these checks to every document. Record findings as PASS, FLAG, or INFO.

### Check 1: Pattern-first structure

Every section should lead with the generic, reusable pattern before naming any specific tool.

- **PASS** — Section describes the pattern, then optionally names tools as examples: "tree-sitter-based repo maps (e.g., Aider's RepoMap)"
- **FLAG** — Section leads with a specific tool as the recommendation: "Use Aider's RepoMap to index your codebase"
- **Test:** Remove all tool/product names from the section. Does it still teach something useful? If yes → PASS. If the section collapses without the tool name → FLAG.

### Check 2: No product-as-recommendation

Specific products should appear as illustrative examples, not as primary recommendations.

- **PASS** — "MCP servers that build code graphs (such as CodeGraphContext or codebase-memory-mcp)"
- **FLAG** — "Install CodeGraphContext for code graph support"
- **Test:** Could someone using a different tool in the same category still follow the guidance? If yes → PASS.

### Check 3: No version-pinned or time-bound claims

Content should avoid claims that will become stale as the ecosystem evolves.

- **FLAG** — Star counts ("~2,600 stars"), specific version numbers ("v0.4.6"), market share claims, "as of 2026" statements
- **FLAG** — Adoption statistics that will change ("used by 60k+ repos")
- **INFO** — Date references in case studies are acceptable (they provide temporal context for the case study, not claims about current state)

### Check 4: No external URLs that will break

Links to external tools, repos, or services go stale. Internal cross-references are fine.

- **PASS** — Cross-references to other docs: `See [01-project-instructions.md](01-project-instructions.md)`
- **FLAG** — Links to external URLs: `[github.com/example/tool](https://github.com/example/tool)`
- **INFO** — Installation commands that reference package names are acceptable (e.g., `npm i -g @cyanheads/git-mcp-server@2.15.1`, the pinned install from setup-claude Step 6) — the command is actionable even if the package evolves

### Check 5: Transferable concepts over tool mechanics

Content should teach concepts that transfer across tools, not the mechanics of one specific tool.

- **PASS** — "A repo map ranks symbols by relevance using graph centrality (typically PageRank), then renders the top-N within a token budget"
- **FLAG** — "Aider's RepoMap class uses NetworkX to build a MultiDiGraph and runs PageRank with personalization vectors"
- **Test:** Would this content help someone building their own tool, or only someone using this specific tool?

### Check 6: Case studies use patterns, not product tutorials

Case studies should illustrate a pattern with a real scenario, not serve as a setup guide for a specific product.

- **PASS** — "A 2,000-file monorepo reduced orientation tokens by 80% after adding a code graph MCP server"
- **FLAG** — "Install CodeGraphContext, run `codegraph build`, then configure Claude Code's MCP settings"
- **Test:** Does the case study teach when and why to use the pattern, or just how to install a tool?

## Step 3: Produce the report

Output the report in this format:

```markdown
# Practice Audit Report

**Scope:** {which documents were assessed}
**Date:** {current date}

## Summary

{2-3 sentences: overall assessment, strongest area, most common issue}

## Findings by Document

### Doc {NN}: {title}
| # | Check | Status | Detail |
|---|-------|--------|--------|
| 1 | Pattern-first structure | PASS | All sections lead with patterns |
| 2 | No product-as-recommendation | FLAG | Line 87: "Install X" — should frame as example |
| ... | ... | ... | ... |

{Repeat for each document}

## Score

| Status | Count |
|--------|-------|
| PASS | N |
| FLAG | N |
| INFO | N |

## Recommendations

Prioritized list of changes, most impactful first:
1. {doc NN, line NN}: {what to change and why}
2. ...
```

## Step 4: Offer fixes

After presenting the report, ask the user if they want to apply fixes for any FLAG findings. Do not modify files without confirmation.

For each fix, the approach should be:
- Replace tool-as-recommendation with pattern-as-recommendation using the tool as an example
- Remove stale version/adoption claims
- Replace external URLs with descriptive text
- Reframe tool-specific mechanics as transferable concepts

## Stop Conditions

- Do not modify any files without explicit user confirmation
- If a document has zero FLAG findings, report it as clean and move on — do not invent issues
- INFO findings are informational only — do not recommend changes for them
- If the user specified a subset of docs, only assess those — do not expand scope
