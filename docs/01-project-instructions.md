# Project Instructions (CLAUDE.md / Project Anchors)

The always-loaded instruction file that shapes every AI response in a project.

## Purpose

A project instruction file is the single document the AI reads on every conversation in a repository. It answers the question: "What do I need to know about this project before I touch anything?" Without one, each session starts from zero — the agent guesses at architecture, invents build commands, and ignores conventions you spent months establishing.

The instruction file serves three functions:

- **Identity** — what the project is, what it builds, what stack it uses.
- **Guardrails** — commands to run, conventions to follow, patterns to enforce.
- **Navigation** — where things live, so the agent can find code instead of hallucinating paths.

The file is always loaded, meaning it consumes context tokens on every interaction regardless of whether the conversation touches a particular topic. This constraint drives every decision about what goes in and what stays out.

## Anatomy of a CLAUDE.md

A well-structured instruction file covers six sections, roughly in this order:

### 1. Project Overview (3-8 lines)
One paragraph stating what the project is, its scope, and its repo structure. Include version scope constraints ("V1: single instance only") so the agent does not over-engineer. If the repo is a monorepo, describe the directory layout and which sub-projects have independent histories.

### 2. Build / Test / Lint Commands (5-15 lines)
The exact commands the agent should run. A table works well for multiple platforms. State any restrictions explicitly — if the agent should use aliases instead of raw tool invocations, say so. Include simulator names, environment activations, or any non-obvious prerequisites.

### 3. Architecture Summary (3-10 lines)
The pattern (MVVM, Clean Architecture, hexagonal), the dependency direction, and the state management approach. Keep this to the level of "how layers relate" — not class-by-class breakdowns. Link to a full architecture doc if one exists rather than reproducing it inline.

### 4. Key Conventions (5-15 lines)
The rules the agent must follow in every file it touches. Localization strategy, comment style, logging policy, magic number restrictions. Write these as imperative statements: "Never hardcode hex colors" rather than "We prefer using design tokens." Each convention should be one or two lines. If a convention needs a full paragraph of explanation, it belongs in a rule file instead.

### 5. Git Conventions (5-10 lines)
Commit message format with a concrete template, allowed types and scopes, safety rules (secrets checking, push policy, force-push restrictions). If the project uses ticket IDs, show the format.

### 6. Key Paths (5-15 lines)
A table mapping directory paths to their purpose. This is the agent's map of the codebase. Include paths to API specs, design tokens, localization files, generated code, configuration, and any AI-specific directories (agents, rules, skills).

Optional sections that earn their place in some projects: **Setup** (bootstrap steps for a fresh clone), **Orchestrator Protocol** (when and how to spawn subagents), **Security Constraints** (if the project handles auth, encryption, or PII).

### Writing style within the file

Use **bold** for emphasis on key terms and command names. Use tables for structured data (build commands, path maps). Use bullet lists for conventions. Avoid prose paragraphs — the agent processes structured, scannable content more reliably than narrative text. Every line should either state a fact about the project or give a directive. If a line does neither, it is consuming budget without contributing.

## Sizing and Budget

The instruction file is always loaded — every token in it is spent on every conversation, whether relevant or not. Research and iteration across real projects suggest these thresholds:

- **Target: under 200 lines** per instruction file. Beyond this, adherence drops measurably as instructions compete for attention in the context window.
- **Sweet spot: 60-100 lines** for a focused, single-platform project. Enough to cover all six sections without padding.
- **Hard ceiling: ~150 effective instructions** (distinct behavioral directives). After this point, the agent starts selectively ignoring rules, typically the ones furthest from the beginning and end of the file.

Think of this like the `alwaysApply` budget in Cursor: you would not set 20 rules to `alwaysApply: true`, because the model cannot attend to all of them simultaneously. The same logic applies here. If you have four major concerns (architecture, conventions, git, safety), each gets a portion of the budget. Anything that does not need to be present in every conversation should be moved to a path-scoped rule file (see [02-rules.md](02-rules.md)).

A practical way to audit: count the imperative statements in your file (lines that tell the agent to do or not do something). If the count exceeds 40-50, start moving the least-universal ones to rules. Conventions that only matter when editing UI code, test files, or API models are prime candidates for extraction.

## What Goes In vs What Stays Out

**Include in the instruction file:**
- Project identity and scope
- Build, test, and lint commands (exact invocations)
- Architecture pattern and dependency direction
- Conventions that apply to every file (comments, logging, naming)
- Git commit format and safety rules
- Key paths table

**Push to rule files (`.claude/rules/`).** Exception: in a repo that runs the PR review kit, a rule the review must enforce goes in a nested `CLAUDE.md`, because the review never reads `.claude/rules/` ([02-rules.md](02-rules.md), "Rules the PR review must enforce"):
- Detailed UI patterns (component structure, accessibility, navigation)
- Networking and data layer specifics (serialization, error mapping, DI)
- Testing conventions (framework, naming, mock patterns)
- API model conventions (DTO structure, endpoint spec format)
- Localization workflow details beyond the one-liner summary

**Push to agent definitions (`.claude/agents/`):**
- Platform-specific stack details and version pins
- Critical warnings that only apply when working in one platform
- Platform feature structure templates

**Leave out entirely:**
- Code examples (they consume tokens without adding behavioral weight)
- Long reference tables (API endpoint lists, color token tables)
- Explanations of why a convention exists (put that in the rule file)
- Instructions the agent already follows by default (do not waste budget reinforcing defaults)

The heuristic: if removing a line would not change the agent's behavior, remove it.

## Layered Instruction Architecture

Most real projects need more than one instruction file. The layering model has three tiers:

### Tier 1: User-Level Instructions (`~/.claude/CLAUDE.md`)
Personal preferences that apply across all projects: interaction style ("ask before coding"), communication tone ("concise, no trailing summaries"), and risk handling ("always stop and ask for auth, payments, PII"). This file is private and not checked into any repository. Keep it short — 10-30 lines. It sets the baseline behavior that project-level files then specialize.

### Tier 2: Root Project Instructions (`CLAUDE.md` at repo root)
The main instruction file for the repository. In a single-project repo, this contains everything. In a monorepo, this becomes a thin orchestrator anchor — it describes the overall structure, shared conventions, cross-cutting concerns, and delegates platform-specific details to Tier 3 files. The monorepo anchor should explicitly describe the orchestrator protocol: when to spawn subagents, which agents exist, and where their definitions live.

### Tier 3: Sub-Project Instructions (nested `CLAUDE.md` files)
Platform-specific or package-specific instruction files that live deeper in the directory tree. These load when the agent (or a subagent) is working within that subtree. They carry stack-specific details: framework versions, DI patterns, UI component structure, critical platform rules. They duplicate build commands from the root (agents working in a sub-project may not see the root file) but otherwise avoid repeating shared conventions.

The key design principle: **each tier adds specificity without repeating what the tier above already covers.** Shared conventions live at the root. Platform constraints live in the sub-project. Personal preferences live at the user level.

### How the tiers compose at runtime

When the agent works in a sub-project directory, it sees Tier 1 + Tier 2 + Tier 3 simultaneously. The combined token cost is the sum of all three files, so each tier must remain lean to keep the total manageable. A reasonable budget allocation: Tier 1 at 15-25 lines, Tier 2 at 60-80 lines, Tier 3 at 50-65 lines. That keeps the combined always-loaded instruction payload under 170 lines even when all three tiers are active.

The one deliberate duplication: build commands. A subagent working in a platform subdirectory may not have the root CLAUDE.md in its context, so the platform file repeats the relevant build aliases. Everything else — comment style, git format, logging policy — lives only at the root.

## Growing the File: Start Empty, Add on Failure

The most effective approach to writing instruction files is reactive, not anticipatory. Start with a near-empty file — project identity, build commands, and key paths — and add directives only when agents repeatedly make specific mistakes.

This pattern works because:

- **You cannot predict what agents will get wrong.** Many conventions you think need stating are already default behavior. Writing them wastes budget.
- **Auto-generated instruction files provide little benefit.** Empirical work on AGENTS.md (a cross-tool standard similar to CLAUDE.md) found that auto-generated or maximalist files often increase agent step counts and API costs without improving task success rates. Human-authored, concise files yield modest gains (~4% average improvement) — but only when focused on recurring, observed problems.
- **Failure is the signal.** When an agent makes the same mistake twice in a session, that is a candidate for a directive. One-off errors do not justify permanent always-loaded instructions.

The growth cycle: run a session, note what went wrong, add a targeted directive or rule, prune anything the agent already follows without prompting. After a few weeks the file stabilizes — most additions happen in the first week, and pruning keeps it lean as the agent improves.

This complements the rule-generation meta-pattern in [02-rules.md](02-rules.md) — the same "detect, propose, validate" loop applies to both instruction files and rules.

## Anti-Patterns

**Duplicating content across CLAUDE.md and rule files.** If a convention appears in both the instruction file and a path-scoped rule, updates will drift. Put the one-liner summary in the instruction file and the detailed workflow in the rule.

**Exceeding 200 lines.** When the file grows past this point, the instinct is to add "just one more section." Instead, audit what is already there. Move detailed content to rules. The instruction file is a routing table, not an encyclopedia.

**Including code examples.** A three-line snippet showing a screen pattern costs tokens on every conversation, including ones that never touch UI code. Put code examples in rule files scoped to the relevant paths.

**Writing passive descriptions instead of directives.** "We use library X for JSON serialization" does not tell the agent what to do. "Use library X with its converter factory for JSON. NOT library Y" does.

**Generic advice and vague phrasing.** Instructions like "write clean code" or "follow best practices" have negligible effect. Agents respond to concrete trigger-action rules: "When CI fails, do not push until it passes" or "Never modify files in `generated/`." If a directive could apply to any project, it is too vague to be useful.

**Listing things the agent already does correctly.** If you find yourself writing "use descriptive variable names," the agent already does this. Spend the budget on things it would get wrong without guidance.

**Forgetting the key paths table.** This is the single highest-value section per token spent. Without it, the agent wastes tool calls searching for files it could have navigated to directly.

**Treating the file as write-once.** The instruction file should be a living document. After a week of use, review which instructions the agent still violates (strengthen those), which it follows without the instruction (remove those), and which new mistakes have appeared (add targeted directives). Pruning is as important as writing.

## Case Study: A Cross-Platform Mobile Project

A cross-platform mobile project (native iOS + Android) used a polyrepo structure: a monorepo for docs, specs, and shared assets, plus two platform repositories nested under `apps/`. The AI setup spanned 31 files across three repos. Here is how the instruction files were sized and scoped.

### Monorepo CLAUDE.md (81 lines)
The root file serves as the orchestrator anchor. It contains:
- Project overview with repo structure and V1 scope (10 lines)
- Build command table covering both platforms via aliases (12 lines)
- Architecture summary — pattern, state management, tab structure (6 lines)
- Orchestrator protocol — when and how to spawn platform subagents (3 lines)
- Key conventions — localization, design tokens, constants, comments, logging (5 lines)
- Git conventions — commit format with ticket IDs, safety rules, version bumping (9 lines)
- Setup steps for a fresh clone (5 lines)
- Key paths table mapping 10 directories to their purposes (12 lines)

What it deliberately excludes: platform stack versions, framework-specific rules (serialization library choices, platform UI opt-ins, concurrency isolation), feature structure templates, testing framework details. All of these live in the platform CLAUDE.md files or in path-scoped rules.

### Platform CLAUDE.md Files (61 lines each)
The Android and iOS instruction files follow an identical structure but carry platform-specific content:
- Project identity with bundle ID and OS target (2 lines)
- Full stack with pinned versions (1 line)
- Build commands repeated from the root (relevant for standalone subagent work) (6 lines)
- Architecture with platform-specific patterns (4 lines)
- Critical rules — the handful of directives that, if violated, cause build failures or security issues (8 lines)
- Git conventions (3 lines)
- Shared conventions (3 lines)
- Feature directory structure template (8 lines)

The "Critical Rules" section is the most valuable per-token section in the platform files. These are the rules the agent would otherwise get wrong: which serialization library to use (and which to avoid), concurrency isolation defaults, keychain access levels. Each is phrased as a positive instruction followed by an explicit negative.

### What the Migration Revealed
When migrating from one AI tool to another (from a system using 13+ thin rule files per platform), several instructions were dropped entirely because the agent already followed them by default. Others were consolidated — separate rule files for commenting, named constants, and environment setup each became single lines in the CLAUDE.md. The consolidation reduced total always-loaded content by roughly 40% while maintaining the same behavioral coverage.

The sizing breakdown: 81 lines (monorepo) + 61 lines (Android) + 61 lines (iOS) = 203 lines total across three files, with no single file exceeding the 100-line sweet spot. Detailed content that would have pushed any file over budget lives in 9 rule files (3 per repo) that load only when the agent is editing relevant paths.
