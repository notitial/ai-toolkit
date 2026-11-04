# Skills and Commands

Reusable workflow instructions invoked by name. The building blocks of AI-assisted development workflows.

## What They Are

A **skill** (Claude Code) or **command** (Cursor) is a named, multi-step procedure that an agent executes when invoked. Think of them as shell scripts for AI — repeatable workflows with defined inputs, steps, and outputs.

| | Cursor Command | Claude Code Skill |
|---|---|---|
| Location | `.cursor/commands/*.md` | `.claude/skills/<name>/SKILL.md` |
| Invocation | `/command-name` in chat | `/skill-name` or auto-triggered by description match |
| Context cost | Loaded into context when invoked | Description always in context (for auto-triggering); full text loads when invoked |
| Arguments | Freeform — parsed by the agent | Freeform — parsed by the agent |
| Subagent spawning | Via `Task` tool | Via `Agent` tool |

The key difference: Claude Code skills have richer metadata (description for auto-matching, model invocation control) while Cursor commands are simpler markdown files. Both serve the same purpose — packaging repeatable workflows.

**Why skills matter:** Without them, you re-explain the same multi-step process every session. A skill captures the procedure once, and every invocation gets the same quality. Skills also compose — a verification skill can spawn three domain-specific subagents in parallel, each running their own check.

## Anatomy of a Skill

A well-structured skill contains:

1. **Name and description** — what it does, when to use it (Claude Code uses this for auto-triggering)
2. **Input** — what arguments or context the skill expects
3. **Steps** — numbered, concrete actions (not vague guidance)
4. **Output format** — what the skill produces when done
5. **Stop conditions** — when to stop iterating or when to fail gracefully
6. **Subagent instructions** — if the skill spawns workers, what each receives

Example structure for a "scaffold new feature" skill. It sets `disable-model-invocation: true` because scaffolding has side effects: Claude never starts it on its own, only the user runs it with `/name`.

```markdown
---
description: Scaffold a new feature with MVVM stubs and test files
disable-model-invocation: true
---

# Scaffold Feature

## Input
- Feature name (e.g., "instance-settings")

## Steps
1. Create feature directory structure, ViewModel, View, and test stub
2. Run project build to verify scaffold compiles
3. Add row to tracking table

## Output
- Files created
- Build status
- Any structural gaps found
```

**Critical detail:** Steps must reference real paths and real commands. "Run the tests" is vague; "`project-test`" is actionable. Skills that reference abstractions instead of concrete commands break silently.

## Design Principles

### Self-contained over contextual
A skill should work without the agent having read other docs first. Include the paths, commands, and conventions it needs inline. Cross-reference rules or docs by path for edge cases, but the happy path should be fully specified in the skill.

### Concrete over abstract
Every step should be copy-pasteable or directly executable. If a step says "update the relevant configuration," it will be interpreted differently every time. Instead: "Add a row to `docs/testing-strategy.md` in the tracking table."

### Agent-executable SKILL.md files
Structure SKILL.md files as imperative instructions, not descriptive documentation. Include explicit do/don't guardrails ("Do NOT quote YAML values", "Always build skeleton before populating"). A well-written SKILL.md doubles as both an instruction document and a specification — an evaluated skill pack demonstrated this pattern with classification skills whose SKILL.md files served as both agent instructions and complete classification specs.

### Include stop conditions
Without explicit stop conditions, an agent will loop forever on a "fix all issues" instruction. Every skill that iterates needs: max passes, what constitutes success, when to stop and report instead of continuing. See [11-convergence.md](11-convergence.md).

Stop conditions vary by skill category:
- **Iterative skills** (self-review, fix loops) — use convergence criteria: stop on plateau (same issues remaining for 2+ passes), regression (issues increased), or iteration cap (default 3).
- **Pipeline skills** — define per-stage failure policies: which stages retry (build: up to 3x), which stages abort the pipeline (dependency resolution failure), which stages degrade gracefully (lint warnings do not block).
- **Verification skills** — define pass/fail thresholds: what severity level blocks a merge, what percentage of checks must pass, what findings are informational vs actionable.

**When to keep vs consolidate:** A skill earns its existence when it is invoked independently at least weekly. If two skills are always invoked together, merge them. If a skill is only ever called as a step inside a pipeline, absorb it into that pipeline.

### Good defaults over documented workarounds
**Skill-default recidivism rule:** if users override a skill's default behavior verbatim ≥3
times (e.g. always passing "…but do not commit"), that is a defect in the skill — change the
default, don't document the workaround.

### Parallel when independent
If a skill needs results from multiple domains, spawn subagents in parallel rather than running sequentially. A verification skill that runs build, test, and lint across multiple scopes can cut wall-clock time by 3x with parallel agents.

### Low context cost when idle
Only a skill's description sits in context by default; its full text loads when the skill is invoked, so a project with 30 skills pays for 30 descriptions, not 30 procedures. Keep descriptions short and specific.

`disable-model-invocation: true` goes further, and it is a behaviour switch, not a token saving: Claude can no longer start the skill on its own, only the user can run it with `/name`, and its description leaves context too. Use it for skills with side effects (deploys, scaffolding, commits) that should run only when asked. Leave it off wherever auto-triggering is the point.

## Skill Categories

### Scaffold skills
Create file structures for new features, screens, or modules. They encode your project's conventions — directory layout, naming, boilerplate patterns — so every new feature starts with the right structure.

**Key pattern:** Scaffold skills should run the build after creating files. A scaffold that does not compile is worse than no scaffold — the developer inherits broken state.

### Pipeline skills
Multi-step workflows with gates between stages. The most complex category — they coordinate multiple agents and have branching logic.

Example — a feature implementation pipeline:
1. **Read** — parse the ticket, extract acceptance criteria, dependencies, localization needs
2. **Analyze** — check dependency files exist, inventory existing patterns, read API specs
3. **Plan** — map criteria to files, choose test scenarios, plan implementation order
4. **Implement** — write code, tests, localization entries (bottom-up: data layer first)
5. **Build + Test + Lint** — retry up to 3x on failure
6. **Self-review** — converge loop with checklist (up to 3 passes)
7. **Commit** — one commit per story, formatted per conventions

Pipeline skills are where most orchestration value lives. They turn "implement this feature" from a 30-minute conversation into a single invocation.

### Verification skills
Read-and-report skills that check state without modifying it. Essential for review workflows and CI.

Examples:
- **Local CI** — spawn multiple agents (root checks, build+test+lint per scope), collect results into a table
- **Code review** — domain-specific checklists (architecture compliance, security, naming, test coverage)
- **Parity audit** — compare feature directories and test files across scopes, report gaps

**Key pattern:** Verification skills produce structured output (tables, severity-categorized findings) so the invoker can parse results quickly.

### Utility skills
Single-purpose automations for recurring tasks. Simple, focused, high-frequency.

Examples:
- **Generate strings** — edit localization source, run generator, verify output
- **Bump version** — read version file, apply bump logic, update build files
- **Prepare PR** — gather diff, extract ticket IDs, generate title and description

Utility skills are the easiest to write and the highest-ROI starting point. If you do the same 5-step process weekly, make it a skill.

### Meta skills
Generic patterns that other skills compose. They define _how_ to iterate, not _what_ to iterate on.

Examples:
- **Converge** — run a task repeatedly with intelligent stop analysis (see [11-convergence.md](11-convergence.md))
- **Self-review** — apply a checklist to recently changed code, flag issues by severity

Meta skills are parameterized — the converge loop does not know about your lint rules; it just knows how to run something, measure progress, and decide when to stop.

## The Parallel Subagent Spawn Pattern

The most powerful skill pattern: spawning multiple agents to work simultaneously on independent scopes.

```
Skill: "local-ci"
  |- Agent 1 (root): validate docs, check schemas, run shellcheck
  |- Agent 2 (scope-a): build -> test -> lint
  +- Agent 3 (scope-b): build -> test -> lint

Collect all reports -> produce summary table
```

Design rules for parallel spawning:
- **Disjoint scopes only** — agents must not edit the same files. If they do, serialize them.
- **Clear contract** — each agent receives exactly what it needs (file paths, commands, acceptance criteria) and returns a structured report.
- **Fail independently** — one agent's failure should not block or corrupt another's work.
- **Collect, don't stream** — the invoking skill waits for all agents, then processes all reports together. Interleaving results wastes tokens on partial context.

## Distributing Skills

To share skills across projects or teams, package them as a Claude Code plugin
([plugins docs](https://code.claude.com/docs/en/plugins)).

## Consolidation

A common evolution: start with many fine-grained commands, then consolidate as patterns emerge.

One project consolidated from 31 commands to 8 skills. The consolidation followed these principles:

1. **Merge aliases** — `compile-a`, `compile-b`, `compile-all` became one `local-ci` skill that detects what changed and runs the right subset
2. **Absorb into pipelines** — standalone `lint`, `test`, `build` commands became steps inside `local-ci` and `review`
3. **Drop backward-compat wrappers** — `review-feature` and `cross-review` were aliases pointing to the same thing
4. **Promote meta-patterns** — the converge loop, previously inline in a pipeline skill, became its own composable skill

The result: fewer entry points, less duplication, clearer ownership. Each skill does one complete thing rather than one step of a thing.

## Case Study: Command-to-Skill Consolidation

Three skills from a mature project illustrate the range:

**Feature implementation** (pipeline, 7 steps) — The most complex skill. Takes a ticket ID, runs the full implementation cycle from reading requirements through committing code. Each step has explicit inputs, outputs, and failure handling. The key insight: bottom-up implementation order (data layer first, then domain, then presentation) because each layer's tests can run independently.

**Local CI** (verification, 3-agent parallel) — Spawns root and two domain-scoped agents simultaneously. Root validates documentation and schema consistency. Domain agents run build+test+lint with whitelisted command aliases. Produces a multi-column report table. Wall-clock time: roughly the same as the slowest scope, not the sum of all three.

**Converge** (meta, composable) — A loop wrapper with metrics tracking and intelligent stop analysis. Used inside the feature implementation pipeline to wrap self-review passes. Tracks issues_found, issues_fixed, issues_remaining per iteration. Stops on plateau (same remaining for 2+ passes), regression (issues increased), or cap (default 3 iterations). The analysis between passes is an LLM judgment call, not a simple count comparison — this is what makes it work.
