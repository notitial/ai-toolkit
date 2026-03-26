# Documentation Index

## Reading Order

Start here. Documents are numbered for sequential reading, but each is standalone.

### Foundations (start here)
- **01** [Project Instructions](01-project-instructions.md) — How to write CLAUDE.md files that shape every AI response
- **02** [Rules](02-rules.md) — Rule authoring patterns: scoping, sizing, when to create
- **03** [Agents](03-agents.md) — Subagent architecture: taxonomy, tool/model scoping, execution policies

### Workflows
- **04** [Skills and Commands](04-skills-and-commands.md) — Reusable workflow design: categories, parallel spawning, meta-skills
- **05** [Orchestrator](05-orchestrator.md) — Autonomous pipeline: thin coordinator, wave execution, checkpoint recovery
- **06** [Convergence](06-convergence.md) — Intelligent loop termination: plateau detection, regression sensing

### Quality
- **07** [Reviews](07-reviews.md) — Multi-agent review: layered gates, severity rubrics, readiness verdicts
- **08** [Context Management](08-context-management.md) — Token optimization: checkpoints, compaction, session degradation
- **09** [Structural Context](09-structural-context.md) — Repo maps, code graphs, and structural indexing for agent navigation
- **10** [Permissions and Safety](10-permissions-and-safety.md) — Command whitelists, sandbox patterns, secrets safety

### Setup
- **11** [Repo Initialization](11-repo-initialization.md) — Bootstrap prompts, AI maturity model (Level A/B/C)
- **12** [Failure Patterns and Recovery](12-run-history.md) — Error taxonomy, recovery strategies, and run lessons

### Specialized
- **13** [Cross-Platform Parity](13-cross-platform-parity.md) — Parity enforcement for multi-target projects
- **14** [Prompt Engineering](14-prompt-engineering.md) — Prompt patterns that worked in practice
- **15** [Multi-Repo Coordination](15-multi-repo-coordination.md) — Coordinating agent work across separate repos: add-dir/additionalDirectories, Agent Teams, orchestrator workspace
- **19** [Orchestrator Context Discipline](19-orchestrator-context-discipline.md) — The live coordinator's own window: thinking as the dominant, legitimate consumer to GC; delegate the legwork and own the judgment; compact on state boundaries, not token ceilings
- **22** [New Repo Setup](22-new-repo-setup.md) — The GitHub-side checklist every new repo gets: settings, `main` ruleset, CI, secret scanning, PR title and description rules, PR review; run by `/repo-setup`

Decisions are recorded in [adr/](adr/README.md).

## Case Studies

Documents illustrate patterns with case studies drawn from real projects, with project names generalized. Figures (token counts, failure rates, review hit rates) come from the author's own runs and are illustrative, not benchmarks; published research is cited where it is used.

## Contributing

When adding knowledge:
1. Check if it fits an existing document before creating a new one
2. Lead with the generic pattern, then illustrate with a case study
3. Illustrate with concrete examples where possible
4. Keep documents focused on one topic
