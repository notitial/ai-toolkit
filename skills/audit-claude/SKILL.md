---
description: "Audit a project's AI-assisted development setup: evaluates CLAUDE.md, rules, agents, skills and settings against best practices, classifies the maturity level (0/A/B/C) and returns prioritized recommendations. User-invoked only: run /audit-claude to audit or improve an AI setup or to learn its maturity level, optionally with a focus area."
disable-model-invocation: true
---

# Audit Claude

Analyze the current project's AI-assisted development configuration and produce a structured audit report with findings, maturity classification, and prioritized recommendations.

## Configuration

Knowledge base location — resolve dynamically from this skill's install path:

```
# This SKILL.md lives at <ai-toolkit>/skills/audit-claude/SKILL.md
# The docs are at <ai-toolkit>/docs/
# Resolve: follow the symlink at ~/.claude/skills/audit-claude back to the repo, then use ../docs/
AI_TOOLING_DOCS=$(dirname $(dirname $(readlink -f ~/.claude/skills/audit-claude)))/docs
```

If the symlink is missing or broken, fall back to searching for the ai-toolkit repo by checking common locations or asking the user.

## Input

Optional: the user may specify a focus area (e.g., "just check my CLAUDE.md", "focus on rules", "am I ready for orchestration?"). If no focus is specified, run the full audit.

## Steps

### Step 1: Discover AI artifacts

Use Glob and Read to find and catalog everything in the current project:

```
CLAUDE.md                           # Root and any nested (monorepo tiers)
.claude/rules/*.md                  # Claude Code rules
.claude/agents/*.md                 # Claude Code agents
.claude/skills/*/SKILL.md           # Claude Code skills
.claude/skills/*.md                 # Flat skill files (not recognized — flag for restructuring)
.claude/commands/*.md               # Claude Code commands
.claude/settings.json               # Claude Code settings
.claude/settings.local.json         # Local overrides (should be gitignored)
.cursorrules                        # Cursor legacy rules
.cursor/rules/*.mdc                 # Cursor rules
.cursor/agents/*.md                 # Cursor agents
.cursor/commands/*.md               # Cursor commands
.gitignore                          # For secret/settings exclusion checks
```

Record what exists and what does not. If nothing exists, skip to Step 4 (classify as Level 0).

If the user specified a focus area, still discover everything but only evaluate the relevant categories in Step 3.

### Step 2: Read evaluation criteria

Read the checklist and maturity criteria from the references directory (relative to this SKILL.md):

- `references/checklist.md` — 10 categories of evaluation checks
- `references/maturity-criteria.md` — A/B/C/0 classification rules

### Step 3: Evaluate each category

For each applicable category in the checklist, evaluate every check against the discovered artifacts. Record one of:

- **PASS** — the check is fully satisfied
- **PARTIAL** — the check is partially satisfied (explain what's missing)
- **MISSING** — the check is not satisfied at all
- **N/A** — the check does not apply at this maturity level or project type

Be specific in the Detail column. Quote actual content when relevant ("CLAUDE.md is 247 lines — 47 over the 200-line target"). Name the specific file and line when flagging an issue.

**Context efficiency estimate (Category 7):** Count lines in CLAUDE.md + all always-on rules. Report the total and flag it above 300 lines, the check 7.3 threshold (roughly 4,000 tokens at ~13 tokens per line).

**Duplication scan (Category 7):** Grep for common directive phrases ("force push", "no secrets", command names) across CLAUDE.md, rules, and agent definitions. Report any directive that appears in 3+ files.

### Step 4: Classify maturity level

Follow the classification procedure in `references/maturity-criteria.md`. Report the level and what's needed to reach the next level.

### Step 5: Pull specific recommendations

For each PARTIAL or MISSING finding, read the relevant document from the knowledge base to pull the specific recommendation:

| Category | Doc to read |
|----------|-------------|
| 1 (Project Instructions) | `$AI_TOOLING_DOCS/01-project-instructions.md` |
| 2 (Rules) | `$AI_TOOLING_DOCS/02-rules.md` |
| 3 (Agents) | `$AI_TOOLING_DOCS/03-agents.md` |
| 4 (Skills) | `$AI_TOOLING_DOCS/04-skills-and-commands.md` |
| 5 (Permissions) | `$AI_TOOLING_DOCS/10-permissions-and-safety.md` |
| 6 (Git Safety) | `$AI_TOOLING_DOCS/01-project-instructions.md`, `$AI_TOOLING_DOCS/10-permissions-and-safety.md` |
| 7 (Context Efficiency) | `$AI_TOOLING_DOCS/08-context-management.md`, `$AI_TOOLING_DOCS/19-orchestrator-context-discipline.md` |
| 8 (Orchestration) | `$AI_TOOLING_DOCS/05-orchestrator.md`, `$AI_TOOLING_DOCS/06-convergence.md`, `$AI_TOOLING_DOCS/07-reviews.md`, `$AI_TOOLING_DOCS/19-orchestrator-context-discipline.md` |
| 9 (Cross-Platform) | `$AI_TOOLING_DOCS/13-cross-platform-parity.md` |
| 10 (Structural Context) | `$AI_TOOLING_DOCS/09-structural-context.md` |

Only read the docs needed for actual findings — do not read every doc on every audit.

Extract the specific section that addresses the finding. Summarize the recommendation in 1-2 sentences. Include the doc path and section name for the user to read the full guidance.

### Step 6: Produce the report

Output the report in this format:

```markdown
# AI Setup Audit Report

**Project:** <directory name>
**Date:** <current date>
**Maturity Level:** <0 | A | B | C> — <one-line summary of what this means>

## Summary

<2-3 sentences: overall assessment, strongest area, most impactful gap>

## Findings

### Category 1: Project Instructions
| # | Check | Status | Detail |
|---|-------|--------|--------|
| 1.1 | CLAUDE.md exists | PASS | Found at root, 156 lines |
| 1.2 | Has overview section | PASS | "## Project Overview" at line 3 |
| ... | ... | ... | ... |

### Category 2: Rules
| # | Check | Status | Detail |
|---|-------|--------|--------|
| ... | ... | ... | ... |

<repeat for each applicable category>

## Score

| Status | Count |
|--------|-------|
| PASS | N |
| PARTIAL | N |
| MISSING | N |
| N/A | N |

## Recommendations

Prioritized by impact. HIGH = blocking next maturity level or causing active harm. MEDIUM = improvement opportunity. LOW = polish.

1. **[HIGH]** <what to do> — <why> (See `<doc-path>`, "<section name>")
2. **[MEDIUM]** <what to do> — <why> (See `<doc-path>`, "<section name>")
3. ...

## Next Maturity Level

To reach Level <next>:
- <specific artifact or change needed>
- <specific artifact or change needed>
```

## Stop Conditions

- If no AI artifacts exist at all (Level 0): produce a short report with bootstrapping recommendations only. Do not run the full checklist.
- If the user specified a focus area: only produce findings and recommendations for the relevant categories. Still classify maturity level.
- Do not offer to apply changes unless the user explicitly asks. This is a read-only audit by default.
