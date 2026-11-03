# Repo Initialization

Bootstrap prompts and the AI maturity model for adding AI tooling to any project.

## The Maturity Model

Not every project needs a full orchestration pipeline. AI tooling maturity grows in stages:

### Level A — Rules Only

The foundation. Every project should reach this level.

- **Git safety rule:** Secret patterns to block, no force-push without confirmation, pre-commit hooks
- **Code quality rule:** Project-specific patterns, naming conventions, error handling approach
- **Error handling rule:** How errors are mapped, where boundaries are, what gets logged
- **CLAUDE.md:** Project identity, build commands, key paths, architecture overview

**When to stay at A:** Solo projects, small codebases, infrequent AI assistance. Rules prevent mistakes without adding workflow complexity.

### Level B — Rules + Skills + Commands

Adds repeatable workflows on top of rules.

- **Scaffold skill:** Create new features/modules with consistent structure
- **Review skill:** Code review checklist, possibly with subagent delegation
- **CI skill:** Run build/test/lint with structured output
- **Version bump skill:** Coordinate version changes across config files

**When to move to B:** You find yourself explaining the same multi-step process to the AI agent repeatedly. A skill captures it once.

### Level C — Mature Orchestrated

Full agent-based workflows with coordination, parity enforcement, and autonomous operation.

- **Specialized agents:** Platform-specific, architecture, documentation, review
- **Orchestration skills:** Multi-agent feature implementation, parallel CI, parity audit
- **Convergence patterns:** Self-review loops, intelligent stop analysis
- **Checkpoint-driven recovery:** Persistent state for long-running workflows

**When to move to C:** Multi-platform projects, team-scale development, overnight orchestration runs. The coordination overhead is justified by the parallelism and consistency gains.

### Promotion Guidelines

- A to B: After 2–3 weeks of stable AI-assisted development with rules catching issues.
- B to C: When you have 10+ features to implement and want overnight automation.
- Never skip levels — each builds on the previous. Level C without Level A rules is chaos with extra steps.

## The Init Prompt

A bootstrap prompt for adding AI tooling to a project for the first time. Structured in phases:

### Phase 0 — Repo Analysis

The agent examines the repo and produces a structured project profile. This is the most important phase — every subsequent decision depends on it. The profile must cover:

1. **Stack identification** — Language, framework, build system, test framework. Detect polyglot setups (e.g., backend + frontend in one repo).
2. **Directory structure and module boundaries** — Top-level layout, where features live, how code is organized into modules or packages.
3. **Development workflow** — Branching strategy, CI/CD pipeline, deployment targets, release process.
4. **Existing AI artifacts** — Any `.claude/`, `.cursor/`, rules, skills, or agent instructions already present. Classify current maturity level (A/B/C) if artifacts exist.
5. **Code conventions already in use** — Naming patterns, error handling style, import organization, formatting tools.
6. **Architectural zone classification** — Categorize codebase areas using the zone model (see below).

**Output:** A written project profile document that informs the strategy in Phase 1. Do not skip this phase or produce it mentally — write it out for human review.

### Zone Model

Four zones classify codebase areas by risk and behavioral expectations. Use this model during Phase 0 to map the repo and during Phase 1 to calibrate rule strictness.

| Zone | Name | Description | Examples |
|------|------|-------------|----------|
| 1 | Foundational | Core infrastructure — shared utilities, config, base classes | Logging, DI containers, build config |
| 2 | Feature | Business logic — features, entities, services | Models, use cases, validation |
| 3 | Integration | Glue code connecting domain to infrastructure, API boundaries | Controllers, adapters, serialization |
| 4 | Critical | Security, payments, data migrations, auth flows | Auth middleware, payment processing, schema migrations |

Higher zones require stricter rules, more thorough review, and tighter tool restrictions. Zone 4 code should always require human approval before agent modifications. See [02-rules.md](02-rules.md) for rule authoring patterns that can be scoped per zone.

### Phase R — Research

Stack-specific best practices for AI tooling:
- What rules does this stack need? (e.g., React projects need component patterns; Go projects need error wrapping rules)
- What common mistakes should rules catch?
- What workflows would benefit from skills?

**Tagging:** Each finding is tagged as `candidate-rule`, `candidate-skill`, `candidate-command`, or `ignore`.

### Phase 1 — Strategy

A file-by-file creation plan with rationale:
- Which rules to create and why, calibrated to zone classification from Phase 0
- Which skills to create (if Level B+)
- CLAUDE.md content plan
- What *not* to create yet (avoid premature complexity)

The strategy is presented for human review before execution.

### Phase 2 — Execution

Fixed creation order to avoid forward references:
1. Meta files (CLAUDE.md, settings.json)
2. Rules (loaded on file match, so they need to exist before skills reference them)
3. Skills/commands (can reference rules and CLAUDE.md)
4. Agent definitions (if Level C)

### Phase 3 — Self-Review

Re-read all created files. Check for:
- Consistency (same conventions referenced the same way across files)
- Completeness (no forward references to uncreated files)
- Size (CLAUDE.md under 200 lines, rules under 300 lines — see [01-project-instructions.md](01-project-instructions.md) and [02-rules.md](02-rules.md))
- No duplication (same instruction in two places)

## The Upgrade Prompt

Same phases as init, but starts from existing setup. Key differences:

- **Phase 0** classifies the current maturity level (A/B/C) and re-evaluates zone boundaries.
- **Phase R** is conditional — only research if the stack has changed or new patterns have emerged.
- **Phase 2** applies low-risk upgrades only: new rules, improved skills, updated references. Do not restructure existing working configurations.
- **Idempotent:** Safe to rerun weekly. Running it on a fully up-to-date project produces no changes.

**Conservative promotion:** The upgrade prompt promotes A to B or B to C only when the project clearly benefits. Never force complexity on a project that works fine at its current level.

## Universal Targets

Every project at Level A should have:

1. **Git safety rule** — Secret patterns, force-push prevention, pre-commit hooks
2. **Code quality rule** — Naming, error handling, patterns specific to the project's stack
3. **CLAUDE.md** — Project identity, build commands, key paths
4. **Build command documentation** — How to build, test, lint (even if it is just `npm test`)
5. **Error handling convention** — Where errors are caught, how they are mapped, what gets logged

These five elements prevent the most common AI-assisted development mistakes: committing secrets, violating project conventions, not knowing how to build, and inconsistent error handling.

The GitHub side of a new repo (settings, the `main` ruleset, CI, secret scanning, PR title and description rules, the Claude review) is a separate checklist: [22-new-repo-setup.md](22-new-repo-setup.md).

## Category-Specific Additions

Beyond universals, different project types benefit from different rules:

| Category | Key Addition | Why |
|---|---|---|
| **Backend** | Deployment consistency | Agents should not introduce config that differs between environments |
| **Mobile** | Accessibility rule | Platform-specific accessibility requirements (tap targets, screen readers) |
| **Library** | API design rule | Public API stability, backward compatibility, deprecation patterns |
| **Monorepo** | Cross-package consistency | Shared conventions, version alignment, dependency rules |
| **Multi-platform** | Parity enforcement | Domain model alignment, test coverage matching |

## Rerun Behavior

The init prompt should detect existing setup:
- If AI tooling exists, redirect to upgrade flow.
- If partial setup, init only the missing pieces.

The upgrade prompt should be idempotent:
- Running on a current project produces no changes.
- Running on an outdated project applies incremental improvements.
- Never destructive — do not delete files or remove rules.

## Case Study: Level A to C in One Month

One multi-platform mobile project (native iOS + Android, shared domain model) reached Level C maturity through three stages:

**Level A (initial setup):** CLAUDE.md with project identity and build commands. Git safety rule. Cross-platform contract rule. This was sufficient for early development — the AI could build, test, and commit without violating core conventions. Zone classification identified auth and payment flows as Zone 4, triggering a dedicated safety rule.

**Level B (after 2 weeks):** Added scaffold skills (new-feature, platform-specific scaffolds), review skills, version bump skill. These eliminated repeated explanations of "how to add a new feature to both platforms." 6 rules, 4 skills, 2 custom commands.

**Level C (after 1 month):** Full orchestration with specialized agents, orchestrator pipeline, convergence patterns, checkpoint-driven recovery. This enabled overnight autonomous runs of up to 25 stories over 3 sessions (~8 per session). 12 rules, 8 skills, 4 agent definitions.

The init and upgrade prompts were developed to replicate this progression for new projects. The init prompt ran Phases 0–3 to bootstrap from zero. The upgrade prompt ran weekly to apply improvements learned from orchestration runs.
