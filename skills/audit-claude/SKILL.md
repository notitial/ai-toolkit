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
TOOLKIT_DOCS=$(dirname $(dirname $(readlink -f ~/.claude/skills/audit-claude)))/docs
```

If the symlink is missing or broken, fall back to searching for the ai-toolkit repo by checking common locations or asking the user.

## Input

Optional: the user may specify a focus area (e.g., "just check my CLAUDE.md", "focus on rules", "am I ready for orchestration?"). If no focus is specified, run the full audit. The user may also name a path for the report (Step 6).

**Invocation:** this skill is user-invoked only (`disable-model-invocation`). An agent or a dispatched session cannot start it with the Skill tool; the person types `/audit-claude` in the session. A brief that wants an audit must say so, and must not tell the agent to run the skill itself.

## Tools and shell

- Glob and Grep may be missing from the session. Fall back to `find`, `ls` and `grep -r --exclude='*.env*'` through Bash. Read still reads a file.
- Check that a binary exists with `which <binary>`, not `command -v`.
- The audit is read-only and needs no workspace lock. A lock guard may still refuse some read-only shell forms, so prefer single plain commands: no pipes, no `cd … &&`, no `awk`. When a command is refused, do not work around the guard: record that check as "not verified" with the reason.

## Steps

### Step 1: Discover AI artifacts

Use Glob and Read (or the fallbacks above) to find and catalog everything in the current project:

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
~/.claude/settings.json             # User settings: extract only the enabledPlugins key (below)
```

Record what exists and what does not. If nothing exists, skip to Step 4 (classify as Level 0).

Then collect the structural-context facts that Category 10 and check 1.12 need:

- **File count:** count tracked source files: `git ls-files`, minus images (SVG included), fonts, media, lockfiles and other generated or binary assets. Ignored folders (`.archive/`, `node_modules`, build output) are not tracked, so they do not count. Without git, or when `git ls-files` is refused, count with `find` under the same exclusions (dependency, build and VCS folders too) and say the figure is approximate. This figure decides the ~50 and ~500 gates in the checklist and the maturity criteria.
- **Main languages:** tally the same source files by extension, keeping each language's share.
- **Code-intelligence plugins:** extract `enabledPlugins` from `.claude/settings.json`, `.claude/settings.local.json` and `~/.claude/settings.json`, noting which file enables each plugin. For each main language, look up the official plugin and binary in `references/code-intelligence.md` and record one of: `enabled` (then check the binary and the install record as that file says), `disabled`, or `available: <plugin>` when it is not enabled. A plugin that is not enabled is information, never a finding.
- **Named paths:** list every path in the CLAUDE.md key paths table or map, and every golden file (a path CLAUDE.md or a rule presents as a pattern to copy), for checks 1.12 and 10.2.
- **Global layer:** count the entries in `~/.claude/rules`, `~/.claude/agents`, `~/.claude/skills` and `~/.claude/hooks` with `ls`. Count only; read none of them. Step 6 reports the counts.

**Settings privacy:** never Read `~/.claude/settings.json`, or a project settings file, whole just to get `enabledPlugins`. Extract that one key with one command: `jq .enabledPlugins <file>` when `which jq` finds it, otherwise `python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("enabledPlugins"))' <file>`. The rest of the file is not read and not reported. (`.claude/settings.json` is read in full only for the Category 5 checks, which need its permissions.)

If the user specified a focus area, still discover everything but only evaluate the relevant categories in Step 3.

### Step 2: Read evaluation criteria

Read the checklist and maturity criteria from the references directory (relative to this SKILL.md):

- `references/checklist.md` — 10 categories of evaluation checks
- `references/maturity-criteria.md` — A/B/C/0 classification rules
- `references/code-intelligence.md` — official code-intelligence plugins, their binaries and extensions (for Step 1 and check 10.3)

### Step 3: Evaluate each category

For each applicable category in the checklist, evaluate every check against the discovered artifacts. Record one of:

- **PASS** — the check is fully satisfied
- **PARTIAL** — the check is partially satisfied (explain what's missing)
- **MISSING** — the check is not satisfied at all
- **N/A** — the check does not apply at this maturity level or project type

Be specific in the Detail column. Quote actual content when relevant ("CLAUDE.md is 247 lines — 47 over the 200-line target"). Name the specific file and line when flagging an issue.

**Named paths (checks 1.12, 10.2):** Glob each path. For a stale finding, name every missing path in the Detail column. Do not stop at the first miss.

**Context efficiency estimate (Category 7):** Count lines in CLAUDE.md + all always-on rules, with their bytes (`wc -c`) and a token estimate (bytes / 4). Report the project-only total and flag it above 300 lines, the check 7.3 threshold (roughly 4,000 tokens at ~13 tokens per line). Report separately the total with the global instruction files (`~/.claude/CLAUDE.md`, `~/.claude/rules/*.md`); that second total is information and does not change the status.

**Duplication scan (Category 7):** Grep for common directive phrases ("force push", "no secrets", command names) across CLAUDE.md, rules, and agent definitions. Report any directive that appears in 3+ files.

### Step 4: Classify maturity level

Follow the classification procedure in `references/maturity-criteria.md`. Report the level and what's needed to reach the next level.

### Step 5: Pull specific recommendations

For each PARTIAL or MISSING finding, read the relevant document from the knowledge base to pull the specific recommendation:

| Category | Doc to read |
|----------|-------------|
| 1 (Project Instructions) | `$TOOLKIT_DOCS/01-project-instructions.md` |
| 2 (Rules) | `$TOOLKIT_DOCS/02-rules.md` |
| 3 (Agents) | `$TOOLKIT_DOCS/03-agents.md` |
| 4 (Skills) | `$TOOLKIT_DOCS/04-skills-and-commands.md` |
| 5 (Permissions) | `$TOOLKIT_DOCS/05-permissions-and-safety.md` |
| 6 (Git Safety) | `$TOOLKIT_DOCS/01-project-instructions.md`, `$TOOLKIT_DOCS/05-permissions-and-safety.md` |
| 7 (Context Efficiency) | `$TOOLKIT_DOCS/08-context-management.md`, `$TOOLKIT_DOCS/13-orchestrator-context-discipline.md` |
| 8 (Orchestration) | `$TOOLKIT_DOCS/12-orchestrator.md`, `$TOOLKIT_DOCS/11-convergence.md`, `$TOOLKIT_DOCS/10-reviews.md`, `$TOOLKIT_DOCS/13-orchestrator-context-discipline.md` |
| 9 (Cross-Platform) | `$TOOLKIT_DOCS/17-cross-platform-parity.md` |
| 10 (Structural Context) | `$TOOLKIT_DOCS/09-structural-context.md` |

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

## Global layer

<One or two lines: the counts of user-level rules, agents, skills and hooks the project inherits. Say that the maturity level reflects only the project's own files, and that inherited setup is not credited to it.>

## Next Maturity Level

To reach Level <next>:
- <specific artifact or change needed>
- <specific artifact or change needed>
```

If the user named a path for the report, also write the report there. That file is the audit's only write; without a named path, write nothing.

## Stop Conditions

- If no AI artifacts exist at all (Level 0): produce a short report with bootstrapping recommendations only. Do not run the full checklist.
- If the user specified a focus area: only produce findings and recommendations for the relevant categories. Still classify maturity level.
- Do not offer to apply changes unless the user explicitly asks. This is a read-only audit by default (the report file the user names is the one exception).
