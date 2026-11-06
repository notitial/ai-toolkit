---
description: "Audit the ai-toolkit repo's own configuration artifacts — agent templates, hook scripts, skills, rules, permissions, MCP config, and CLAUDE.md. Use when someone asks to check the repo's tooling health, validate templates, verify hooks work, or audit the setup-claude pipeline. Does NOT audit docs/ — use /audit-practices for that."
disable-model-invocation: true
---

# Audit Tooling

Validate the ai-toolkit repo's configuration artifacts for correctness, consistency, and alignment with the patterns documented in `docs/`. Covers everything except `docs/` itself (use `/audit-practices` for that).

## Scope

This skill audits artifacts in six categories:

1. **Agent definitions** — `agents/*.md`
2. **Hook scripts** — `hooks/*.sh`
3. **Skills** — `.claude/skills/*/SKILL.md` and `skills/*/SKILL.md`
4. **Rules** — `.claude/rules/*.md` (project-scoped) and `rules/*.md` (global always-on — a distinct artifact class, see Category 4b)
5. **Permissions template** — `.claude/skills/setup-claude/templates/safe-permissions.json`
6. **Project CLAUDE.md** — root `CLAUDE.md`

## Input

Optional: a specific category (e.g., "just check hooks", "agents only"). If no input is specified, audit all categories.

## Step 1: Discover artifacts

Use Glob to find all artifacts:

```
agents/*.md
hooks/*.sh
.claude/skills/setup-claude/templates/safe-permissions.json
.claude/skills/setup-claude/templates/global-claude-md.md
.claude/skills/*/SKILL.md
skills/*/SKILL.md
.claude/rules/*.md
rules/*.md
.claude/settings.json
CLAUDE.md
README.md
```

Read each discovered file. Record what exists and what is missing.

## Step 2: Evaluate each category

Apply the checks below. Record findings as PASS, FLAG, or INFO.

### Category 1: Agent Templates

For each agent in `agents/`:

| # | Check | How to verify |
|---|-------|---------------|
| 1.1 | Valid YAML frontmatter | Has `name`, `description`, `model`, `tools` fields |
| 1.2 | Four-section structure | Has Identity & Scope, Key Context, Execution Policy, Report Format sections (or equivalent H2s) |
| 1.3 | Tool scoping matches role | Reviewers/auditors: no Write, Edit, or Bash. Implementers: may have write tools. Cross-check `tools` frontmatter against role described in Identity section |
| 1.4 | Model selection appropriate | Opus for security/architecture review. Sonnet for balanced tasks. Haiku for lightweight. Check `model` field against role |
| 1.5 | No Bash tool for read-only agents | Agents with read-only roles must not have Bash in tools list |
| 1.6 | Git MCP over Bash git | If agent needs git access, uses `mcp__git-mcp__*` tools, not Bash git commands |
| 1.7 | Self-contained execution policy | Execution policy is inline, not referencing external rule files |

### Category 2: Hook Scripts

For each hook in `hooks/`:

| # | Check | How to verify |
|---|-------|---------------|
| 2.1 | Executable flag | File has `#!/bin/bash` shebang and would be installed with +x |
| 2.2 | Reads JSON from stdin | Script uses `cat` or similar to capture stdin, then parses with `jq` |
| 2.3 | Uses structured JSON output | Deny decisions use `hookSpecificOutput.permissionDecision: "deny"` format |
| 2.4 | Exit 0 always | Script never exits non-zero — uses JSON output for decisions, not exit codes |
| 2.5 | Pattern coverage reasonable | Secret detector: covers AWS, GitHub, OpenAI/Stripe, PEM keys, JWT, Slack, .env files. Destructive blocker: covers rm -rf, DROP/DELETE/TRUNCATE, git force push/reset/clean, dd, mkfs |
| 2.6 | No false positives on safe input | Run a mental walkthrough: would `echo "hello world"` or `git status` trigger a deny? |
| 2.7 | Grep handles special patterns | Patterns starting with dashes use `--` end-of-options marker |

### Category 3: Skills

For each SKILL.md in `.claude/skills/` and `skills/`:

| # | Check | How to verify |
|---|-------|---------------|
| 3.1 | Has description frontmatter | `description` field present and specific enough for auto-triggering |
| 3.2 | Has `disable-model-invocation: true` | Prevents token cost when idle |
| 3.3 | Steps are concrete | Steps reference specific file paths, glob patterns, or tool names — not abstract instructions |
| 3.4 | Output format defined | Has explicit report template or format specification |
| 3.5 | Stop conditions defined | For skills that iterate: has max passes, convergence criteria, or "when to stop" |
| 3.6 | Self-contained | Happy path is fully specified without needing to read external docs |
| 3.7 | References resolve | Any file paths or glob patterns mentioned in the skill actually exist in the repo |

### Category 4: Project Rules

For each rule in `.claude/rules/` (project-scoped, path-activated):

| # | Check | How to verify |
|---|-------|---------------|
| 4.1 | Has path frontmatter | `paths`/`globs` field present and scoped appropriately. **Applies to project rules ONLY — do not run this check against `rules/*.md`** |
| 4.2 | Under 300 lines | Count lines |
| 4.3 | One concern per rule | Does not cover multiple unrelated topics |
| 4.4 | Uses imperative voice | "Use X", "Do not Y" — not "We prefer X", "Consider Y" |
| 4.5 | No hardcoded absolute paths | No `/Users/`, `/home/`, `C:\` references |
| 4.6 | No duplication with CLAUDE.md | Check that rule content does not repeat what CLAUDE.md already says |

### Category 4b: Global Rules

For each rule in repo-root `rules/` (global always-on, installed to `~/.claude/rules/` per ADR 0009):

| # | Check | How to verify |
|---|-------|---------------|
| 4b.1 | NO frontmatter | Global rules are always-on by design — FLAG if `paths`/`globs` frontmatter is present |
| 4b.2 | Under 300 lines | Count lines (these load in every session — smaller is better) |
| 4b.3 | One concern per rule | Does not cover multiple unrelated topics |
| 4b.4 | Uses imperative voice | Same as 4.4 |
| 4b.5 | No hardcoded absolute paths | Same as 4.5 |
| 4b.6 | Canonical ownership | Content does not duplicate the global CLAUDE.md starter template (`templates/global-claude-md.md`) — each concern has exactly one home |
| 4b.7 | No name collision | No file in `rules/` shares a basename with a file in `.claude/rules/` (both install/load under the same rule namespace) |

### Category 5: Permissions Template

Check `templates/safe-permissions.json`:

| # | Check | How to verify |
|---|-------|---------------|
| 5.1 | Valid JSON | File parses without error |
| 5.2 | Permissions use specific patterns | No `Bash(*)` or overly broad wildcards |
| 5.3 | MCP git tools present | `mcp__git-mcp__*` permissions exist for git operations |
| 5.4 | No Bash git in allow list | Bash git permissions only appear in `_migration.removeBashGit`, not in `permissions.allow` |
| 5.5 | Hooks reference existing scripts | Each hook `command` path (e.g., `$HOME/.claude/hooks/secret-detector.sh`) corresponds to a script in `hooks/`. One intended exception: the github guard, `/bin/bash -p '<live checkout>/tools/github-mcp/guard.sh' || exit 2` (check that the file exists at the path the hook names; never repoint it at `hooks/`) |
| 5.6 | Migration list consistent | Every Bash pattern in `removeBashGit` has a corresponding MCP permission in `allow` (or is intentionally prompt-only like `git branch`) |
| 5.7 | Plugins are current | `enabledPlugins` list does not include plugins that are in `_migration.removePlugins` |

### Category 6: Project CLAUDE.md

Check the root `CLAUDE.md` against doc 01 criteria:

| # | Check | How to verify |
|---|-------|---------------|
| 6.1 | Under 200 lines | Count lines |
| 6.2 | Has required sections | Project Overview, Build/Test/Lint, Key Conventions, Git Conventions, Key Paths |
| 6.3 | Key paths are accurate | Every path in the Key Paths table actually exists in the repo |
| 6.4 | Uses imperative voice | Spot-check for directives vs passive descriptions |
| 6.5 | No stale references | Skill names, doc numbers, and file paths mentioned are current |
| 6.6 | Skills list current | Skills mentioned in Document Structure match what actually exists in `skills/` |

### Cross-Cutting: Setup Skill & Roster Consistency

| # | Check | How to verify |
|---|-------|---------------|
| 7.1 | setup-claude discovery covers all artifact dirs | Steps 2–5 discovery globs cover `agents/`, `hooks/`, `skills/`, `rules/` — no artifact directory is missed |
| 7.2 | README install table matches filesystem | Compare the README "What Gets Installed" rows against `ls agents/ hooks/ skills/ rules/` (ignore `skills/README.md`) — the table is the repo's only enumerated roster (CLAUDE.md convention); FLAG any drift in either direction |
| 7.3 | Report step stays discovery-based | setup-claude's Report step (Step 11) contains no hardcoded artifact rosters — one row per discovered artifact |

## Step 3: Produce the report

Output the report in this format:

```markdown
# Tooling Audit Report

**Date:** {current date}

## Summary

{2-3 sentences: overall health, strongest area, most impactful issue}

## Findings

### Category 1: Agent Templates
| # | Check | Status | Detail |
|---|-------|--------|--------|
| 1.1 | Valid YAML frontmatter | PASS | All 3 agents have name, description, model, tools |
| ... | ... | ... | ... |

{Repeat for each category}

### Cross-Cutting: Setup Skill & Roster Consistency
| # | Check | Status | Detail |
|---|-------|--------|--------|
| 7.2 | README roster matches filesystem | PASS | Table rows match ls output for all four dirs |
| ... | ... | ... | ... |

## Score

| Status | Count |
|--------|-------|
| PASS | N |
| FLAG | N |
| INFO | N |

## Recommendations

Prioritized list of fixes:
1. {category, check #}: {what to change and why}
2. ...
```

## Step 4: Offer fixes

After presenting the report, ask the user if they want to apply fixes for any FLAG findings. Do not modify files without confirmation.

## Stop Conditions

- Do not modify any files without explicit user confirmation
- If a category has zero FLAG findings, report it as clean and move on
- INFO findings are informational only — do not recommend changes
- If the user specified a subset of categories, only audit those
