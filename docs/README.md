# Documentation Index

## Reading Order

Start here. Documents are numbered in reading order, but each is standalone.

### Foundations: what you configure
- **01** [Project Instructions](01-project-instructions.md) — How to write CLAUDE.md files that shape every AI response
- **02** [Rules](02-rules.md) — Rule authoring patterns: scoping, sizing, when to create
- **03** [Agents](03-agents.md) — Subagent architecture: taxonomy, tool/model scoping, execution policies
- **04** [Skills and Commands](04-skills-and-commands.md) — Reusable workflow design: categories, parallel spawning, meta-skills
- **05** [Permissions and Safety](05-permissions-and-safety.md) — Command whitelists, sandbox patterns, secrets safety

### Setting up a repo
- **06** [Repo Initialization](06-repo-initialization.md) — Bootstrap prompts, AI maturity model (Level A/B/C)
- **07** [New Repo Setup](07-new-repo-setup.md) — The GitHub-side checklist every new repo gets: settings, `main` ruleset, CI, secret scanning, PR title and description rules, PR review; run by `/repo-setup`

### Context
- **08** [Context Management](08-context-management.md) — Token optimization: checkpoints, compaction, session degradation
- **09** [Structural Context](09-structural-context.md) — Key paths, golden files, the native LSP tool, repo maps and code graphs for agent navigation

### Quality
- **10** [Reviews](10-reviews.md) — Multi-agent review: layered gates, severity rubrics, readiness verdicts
- **11** [Convergence](11-convergence.md) — Intelligent loop termination: plateau detection, regression sensing

### Orchestration
- **12** [Orchestrator](12-orchestrator.md) — Autonomous pipeline: thin coordinator, wave execution, checkpoint recovery
- **13** [Orchestrator Context Discipline](13-orchestrator-context-discipline.md) — The live coordinator's own window: thinking as the dominant, legitimate consumer to GC; delegate the legwork and own the judgment; compact on state boundaries, not token ceilings
- **14** [Prompt Engineering](14-prompt-engineering.md) — Prompt patterns that worked in practice: orchestrator and headless prompts
- **15** [Failure Patterns and Recovery](15-failure-patterns.md) — Error taxonomy, recovery strategies, and run lessons
- **16** [Multi-Repo Coordination](16-multi-repo-coordination.md) — Coordinating agent work across separate repos: add-dir/additionalDirectories, Agent Teams, orchestrator workspace

### Specialized
- **17** [Cross-Platform Parity](17-cross-platform-parity.md) — Parity enforcement for multi-target projects
- **18** [Device E2E Under Agent Control](18-device-e2e-automation.md) — UI end-to-end suites on simulators and devices: the device as an exclusive resource, killed runs vs timeouts, rate limits as the iteration budget

Decisions are recorded in [adr/](adr/README.md).

## Case Studies

Documents illustrate patterns with case studies drawn from real projects, with project names generalized. Figures (token counts, failure rates, review hit rates) come from the author's own runs and are illustrative, not benchmarks; published research is cited where it is used.

## Contributing

When adding knowledge:
1. Check if it fits an existing document before creating a new one
2. Lead with the generic pattern, then illustrate with a case study
3. Illustrate with concrete examples where possible
4. Keep documents focused on one topic
