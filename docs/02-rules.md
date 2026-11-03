# Rules

Scoped instructions that activate on file patterns or always — the building blocks of consistent AI behavior.

## What a Rule Is

A rule is a targeted instruction that supplements your project-level context file (CLAUDE.md, AGENTS.md, .cursorrules) with focused guidance for a specific concern. Where the project context file describes what the project is, rules describe how to work within it — scoped to particular files, domains, or workflows.

Rules activate in two ways:

- **Always-on:** Loaded into every conversation regardless of which files are open. Reserved for non-negotiable constraints like security gates and command whitelists.
- **Pattern-scoped:** Loaded only when the agent touches files matching a glob or path pattern. This is where most rules should live.

The distinction matters because every always-on rule consumes tokens in every interaction, even when irrelevant. Pattern-scoped rules cost nothing until they are needed.

## Anatomy of a Rule

Both Cursor and Claude Code rules follow the same general structure: metadata frontmatter followed by structured content.

**Cursor (.mdc files):**
```yaml
---
description: Localization and string resource conventions
alwaysApply: false
globs: ["platform-a/**/*.kt", "platform-b/**/*.swift", "core/localization/**"]
---
```

**Claude Code (.md files):**
```yaml
---
paths:
  - "core/api/**"
---
```

The frontmatter controls when the rule activates. The content below it follows a consistent pattern:

- **Title** — a clear name for the concern (e.g., "# Cross-Platform Contract")
- **Scope statement** — one line defining what the rule covers and what it does not
- **Sections** — grouped by sub-concern, using headers for scanability
- **Do/Don't markers** — explicit positive and negative constraints
- **References** — pointers to canonical docs, related rules, or specs

A well-written rule reads like a checklist an agent can follow mechanically. If a human would need to interpret it, it is too vague.

## The alwaysApply Budget

Every always-on rule adds to the token baseline of every conversation. This cost is invisible until it is not.

In one project's audit, the always-applied baseline had grown to approximately 11,000 tokens:

| Source | Approx Tokens |
|---|---:|
| User rules | ~2,200 |
| Project context file | ~1,800 |
| project-identity rule (always) | ~1,600 |
| git-safety rule (always) | ~900 |
| localization rule (always) | ~1,300 |
| code-quality rule (always) | ~1,600 |
| Platform always rules (combined) | ~1,550 |
| **Total** | **~11,000** |

The problem: a docs-only editing session still loaded localization policy, code-quality enforcement, and platform anchor rules — none of which were relevant. This burned context window on every turn.

**Practical guidelines:**

- Aim for 3–4 always-on project rules maximum; the global rules `/setup-claude` installs count separately. These should cover truly global concerns: security gates, command restrictions, and project identity.
- Move code-style enforcement, naming conventions, and domain-specific policy to pattern-scoped rules.
- Audit your always-on baseline periodically. If a rule does not apply to at least 80% of sessions, it should not be always-on.

## Scoping Strategies

### Cursor: Globs

Cursor rules use glob patterns in the `globs` frontmatter field. The rule activates when any open file matches:

```yaml
globs: ["platform-a/**/*.kt", "platform-a/**/*.kts"]
```

Effective glob patterns are specific enough to avoid false activation but broad enough to catch all relevant files. For a localization rule, this means including source files, the localization data, and any generator scripts:

```yaml
globs: ["platform-a/**/*.kt", "platform-b/**/*.swift", "core/localization/**", "tools/generate_strings.py"]
```

### Claude Code: Paths

Claude Code rules use `paths` in frontmatter. The rule activates when the agent reads, edits, or discusses files under the specified paths:

```yaml
paths:
  - "core/api/**"
```

Paths are directory-oriented rather than extension-oriented. A single path like `"docs/**"` or `"core/**"` can replace multiple globs.

### Choosing the Right Scope

- **Single domain, single directory:** Use one path/glob (e.g., `core/api/**` for API model standards).
- **Cross-cutting concern, multiple directories:** List all relevant paths (e.g., localization touches `core/localization/**`, `tools/`, and both platform source trees).
- **Platform-specific:** Scope to the platform directory (e.g., `platform-a/**` or `platform-b/**`).

Do not use overly broad patterns like `**/*.md` that would activate on any Markdown file in the project.

## Content Structure

Rules are consumed by AI agents, not rendered in a browser. Optimize for machine parsing and human review:

- **Bullets over paragraphs.** Agents extract constraints more reliably from lists than from prose.
- **Do/Don't markers.** Make constraints unambiguous. Use "Do not" or a marker like "Forbidden:" rather than hedging with "try to avoid."
- **Code examples only when the pattern is complex.** A multi-component screen pattern with dependency injection benefits from a 15-line example. A "no hardcoded strings" rule does not.
- **Cross-references over duplication.** Point to canonical docs instead of restating them. "See `docs/architecture.md` for layer rules" is better than pasting the layer diagram into the rule.
- **Max 300 lines, prefer under 200.** If a rule exceeds this, it is covering too many concerns and should be split.
- **One rule = one concern.** A rule about git safety should not also define commit message format. Split them.

## When to Create a Rule

The trigger is repetition: if you correct the same mistake twice in a session, it is a candidate for a rule.

### The Rule-Generation Meta-Pattern

This can be codified as a self-referential rule that activates when editing rule files:

1. **Detect the pattern.** Same correction applied 2+ times in a session.
2. **Propose the rule.** State the file path, a brief content summary, and the trigger condition.
3. **Do not over-create.** Skip one-off fixes, cases already covered by existing rules, and trivial formatting preferences.

The meta-rule should also define a checklist for a well-formed rule: YAML frontmatter present, under 300 lines, clear do/don't markers, bullets preferred, paths relative to rules root, and activation verified after creation.

### Start with Zero Rules

Do not front-load rules at project setup. Begin with an instruction file (CLAUDE.md) and zero rules, then add rules only when the agent repeatedly makes the same mistake. This reactive approach has two benefits: it avoids rules that duplicate default behavior (wasting tokens), and it ensures every rule addresses a real, observed problem.

After a few weeks, rule creation naturally plateaus — most gaps surface in the first week of active use. Periodically audit existing rules and remove any that the agent now follows without them (due to model updates or convention internalization).

**Rules are not the answer for everything.** If guidance is project-wide and rarely changes (build commands, repo structure), it belongs in CLAUDE.md. See [01-project-instructions.md](01-project-instructions.md) for what belongs at the project level. If guidance is transient or session-specific, state it in the conversation. Rules fill the middle ground: durable, scoped, and too specific for the project context file.

## Organization

Group rules into folders by domain. A flat list of 20+ rule files becomes unnavigable:

```
.cursor/rules/
  general/          # Project-wide: git safety, command whitelist, code review
  core/             # Domain contracts: localization, named constants, API models
  platform/         # Platform anchors: platform-a-always, platform-b-always
  development/      # Tooling: virtual environments, version management
  testing/          # Test parity, coverage expectations
  ui/               # Screen patterns, component conventions
```

Claude Code rules often follow a flatter structure because consolidation reduces the count:

```
.claude/rules/
  api-models.md             # paths: core/api/**
  cross-platform-contract.md  # paths: docs/**, core/**
  localization.md           # paths: core/localization/**, tools/generate_strings.py
```

The folder names are a taxonomy, not a framework. Pick domains that match your project's natural boundaries.

## Duplication Avoidance

Duplication is the most common rules anti-pattern and the hardest to detect as a project grows. In one project's audit, the directive "Never log secrets, tokens, or PII" appeared in seven separate files: the project-identity rule, git-safety rule, both platform always-rules, both nested platform rules, and the project context file.

Each duplicate added tokens without adding information. Worse, when guidance needed updating, some copies were missed, creating contradictions.

**Prevention strategies:**

- **Assign canonical ownership.** Each concern has exactly one rule that defines it. Other rules cross-reference: "PII sanitization: see cross-platform-contract rule."
- **Use the one-question test.** If someone asks "where is the logging policy defined?" there should be one clear answer.
- **Audit after growth spurts.** After adding 5+ rules, scan for overlapping content. One project's post-audit consolidation saved ~4,250 tokens in docs-only sessions.

## Anti-Patterns

**`alwaysApply: true` with `globs` together.** If a rule has globs, it should not also be always-on. The glob exists to limit when the rule loads. Combining both means the globs are ignored and the rule is always-on — but the intent is ambiguous to anyone reading the frontmatter.

**Generic descriptions.** A description like "Code quality rules" tells the agent nothing useful about whether the rule is relevant. Use specific descriptions: "Named constants policy — magic numbers forbidden in production code."

**Hardcoded absolute paths.** Rules should use paths relative to the project root. Absolute paths (`/Users/x/project/src/`) break for every other contributor and agent environment.

**Duplicating project-level context.** Do not restate what the project context file already says. Rules supplement the project context file; they do not replace it.

**Kitchen-sink rules.** A single rule covering git safety, commit format, PR conventions, and release workflow is doing the work of four rules. Split by concern so each can be independently scoped and maintained.

## Case Study: Cross-Platform Rule Consolidation

A cross-platform mobile project with a polyrepo structure — a core monorepo for docs, specs, and shared resources, plus independent Git repos for each platform — accumulated 26 rules over several months of development.

### The Growth Phase: 26 Rules

The rules spanned six domain folders plus nested platform rules inside each app repo. The system worked — agents produced consistent code and followed conventions — but several problems emerged:

- **Token bloat.** Six rules were marked always-on, creating an 11,000-token baseline. A third of that was irrelevant in any given session.
- **Duplication.** Key directives (no secrets logging, polyrepo context, orchestration protocol) were repeated across 3–7 files each.
- **Maintenance drag.** Updating a policy meant editing multiple files and hoping none were missed.
- **Signal dilution.** With so much always-on context, agents occasionally deprioritized the most important constraints.

### The Consolidation: 3 Rules

The project consolidated 26 rules into 3 dense, path-scoped rules plus a comprehensive project context file. The principles:

1. **Move project-wide facts into the context file.** Build commands, repo structure, key paths, git conventions, and architecture overview all belong in the project context file — not scattered across rules.
2. **Consolidate by activation scope, not by original topic.** The three resulting rules mapped to natural file-access patterns: API work (`core/api/**`), cross-platform design work (`docs/**`, `core/**`), and localization work (`core/localization/**`, `tools/`).
3. **Eliminate always-on rules entirely.** Everything previously always-on either moved into the project context file (where it is always-on by definition but in a single managed location) or became path-scoped.
4. **Deduplicate ruthlessly.** Each concept has exactly one canonical location.

The result: agents receive the same guidance with fewer tokens, clearer ownership, and a single file to update per concern. The 26-to-3 reduction was not about losing information — it was about eliminating redundancy and choosing the right layer (project context vs. rule vs. docs) for each piece of guidance.
