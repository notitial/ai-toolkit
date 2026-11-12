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
# Resolve: run `ls -ld ~/.claude/skills/audit-claude`; it prints "... audit-claude -> <target>".
# Drop the trailing "skills/audit-claude" from <target> and append "docs".
TOOLKIT_DOCS=<target minus skills/audit-claude>/docs
```

If the symlink is missing or broken, fall back to searching for the ai-toolkit repo by checking common locations or asking the user. Do not guess the docs path from the audited repo's layout.

## Input

Optional: the user may specify a focus area (e.g., "just check my CLAUDE.md", "focus on rules", "am I ready for orchestration?"). If no focus is specified, run the full audit. The user may also name a path for the report (Step 6).

**Invocation:** this skill is user-invoked only (`disable-model-invocation`). An agent or a dispatched session cannot start it with the Skill tool; the person types `/audit-claude` in the session. A brief that wants an audit must say so, and must not tell the agent to run the skill itself.

## Tools and shell

- Glob and Grep may be missing from the session. Fall back to `find`, `ls` and `grep -r --exclude='*.env*'` through Bash. Read still reads a file.
- zsh expands an unquoted `*` and `(`: quote every glob (`--include='*.md'`, `-name '*.md'`) and escape `find` groups (`\( -o \)`), or the command fails with "no matches found".
- The audit is read-only and needs no workspace lock. A lock guard may still refuse some read-only shell forms, so prefer single plain commands with absolute paths: no pipes, no `cd … &&`, no `awk`. Forms that pass, and the ones they replace:
  - `which <binary>`, not `command -v`.
  - `ls -ld <symlink>` (the target follows `->`), not `readlink -f`.
  - `find <dir> -type f -not -path '*/.git/*' -not -path '*/node_modules/*'` (one `-not -path` per excluded folder, no `-o` groups), not `git ls-files`.
  - The one-command file count and tally in Step 1, not a `find … | sort | uniq` chain. A lock guard may refuse that `python3` form (it reads only `find`, `wc` and similar): then count with one `find <root> -type f` (one `-not -path` per skipped folder, one `-not -name` per asset extension) piped to `wc -l` if the guard accepts the pipe. If that is refused too, report the file count and language shares as "not verified" and decide the size gates in 10.2 from the folders you listed.
- A hook may redirect Bash `git status`, `git log` and `git diff` to the git MCP tool. Use `mcp__git-mcp__git_status`, `git_log` and `git_diff`, each with `path` set to the audited repo. Read-only plumbing such as `git ls-files` passes as Bash, but the find form above stays preferred.
- When a command is refused, do not work around the guard (no wrapping the same call in another tool): record that check as "not verified" with the reason.

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
~/.claude.json                      # User-scope MCP servers: extract only the mcpServers key names (below)
rules/ agents/ skills/ hooks/       # Repo root: the global layer's source, when linked into ~/.claude (Global layer, below)
```

Record what exists and what does not. If nothing exists, skip to Step 4 (classify as Level 0).

Then collect the structural-context facts that Category 10 and check 1.12 need:

- **File count and main languages:** one command gives both, over one file set. It walks the repo without the VCS, dependency, build and archive folders, drops the asset files and tallies the rest by extension (by name when a file has none):

  ```
  python3 -I -c 'import os,sys,collections
  skip={".git",".archive",".venv","node_modules","dist","build","target","vendor"}
  asset=set(".png .jpg .jpeg .gif .svg .ico .webp .ttf .otf .woff .woff2 .mp3 .mp4 .mov .pdf .lock .log .pyc".split())
  named={"package-lock.json","pnpm-lock.yaml",".DS_Store"}
  c=collections.Counter();t=0
  for r,d,f in os.walk(sys.argv[1]):
      d[:]=[x for x in d if x not in skip]
      for n in f:
          t+=1;e=os.path.splitext(n)[1].lower()
          if n not in named and e not in asset: c[e or n]+=1
  s=sum(c.values())
  print(t,t-s,s,c.most_common(25))' <repo root>
  ```

  It prints the files walked, the amount dropped (images, SVG included; fonts; media; PDFs; lockfiles; logs; `.DS_Store`), the source file count and the tally. Report all three numbers. The source file count decides the ~50 and ~500 gates in the checklist and the maturity criteria. Markdown and other text files count, in the count and in the tally alike, so a docs-first repo reads as large as it is. Add a folder to `skip` or a name to `named` when the repo ignores it (read `.gitignore`); a stray generated file the lists do not name stays counted. The figure is approximate because it walks the disk, not `git ls-files`; say so. The tally gives each language's share.
- **Code-intelligence plugins:** extract `enabledPlugins` from `.claude/settings.json`, `.claude/settings.local.json` and `~/.claude/settings.json`, noting which file enables each plugin. For each main language, look up the official plugin and binary in `references/code-intelligence.md` and record one of: `enabled` (then check the binary and the install record as that file says), `disabled`, or `available: <plugin>` when it is not enabled. A plugin that is not enabled is information, never a finding.
- **Named paths:** list every path in the CLAUDE.md key paths table or map, and every golden file (a path CLAUDE.md or a rule presents as a pattern to copy), for checks 1.12 and 10.2.
- **Global layer:** list `~/.claude/rules/*`, `~/.claude/agents/*`, `~/.claude/skills/*` and `~/.claude/hooks/*`, one `ls -ld` command each (use `ls -ld ~/.claude/rules` when the folder itself is a link). Each line shows a link's target. An entry whose target is inside the audited repo is **owned by this repo** and installed globally (the repo keeps root `rules/`, `agents/`, `skills/` or `hooks/` and links them into `~/.claude`); every other entry is **inherited**. Count both; read no inherited file and no hook body. Owned files are project files: read them, and count them for Categories 2, 3, 4 and 8 and the classification, as if they sat under `.claude/` (the checklist says how). Step 6 reports both counts.

**Settings privacy:** never Read `~/.claude/settings.json`, `~/.claude.json` or a project settings file whole just to get one key. `~/.claude.json` also holds private data (account details, per-project history, tokens): say so in the report if it comes up, and report nothing from it but server names. Extract the one key with one command: `jq .enabledPlugins <file>` when `which jq` finds it, otherwise `python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("enabledPlugins"))' <file>`. For user-scope MCP servers (checks 5.7, 5.8, 10.3) extract only the key names: `jq '.mcpServers | keys' ~/.claude.json`, or the same python with `list(json.load(open(sys.argv[1])).get("mcpServers", {}))`. For user-level permissions or hooks (the "global by design" and 6.2 evidence) extract only key names too: `.permissions | keys`, `.hooks | keys`. One exception, for check 5.7: a count of the git MCP entries in the allowlist, `jq --arg n <server name> '[(.permissions.allow // [])[] | select(. == "mcp__" + $n or startswith("mcp__" + $n + "__"))] | length' ~/.claude/settings.json`, with the git MCP server name that discovery found (or the same in python with `.get("permissions", {}).get("allow", [])`). It counts a whole-server entry and per-tool entries; no allowlist gives 0, reported as no matching entries for that server. Report the number, never the entries. The rest of the file is not read and not reported. (`.claude/settings.json` is read in full only for the Category 5 checks, which need its permissions.)

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

The Score totals count each check once, not each table row: a check that Detail covers in several rows is one entry, so two runs compare.

Be specific in the Detail column. Quote actual content when relevant ("CLAUDE.md is 247 lines — 47 over the 200-line target"). Name the specific file and line when flagging an issue.

**Named paths (checks 1.12, 10.2):** Glob each path. For a stale finding, name every missing path in the Detail column. Do not stop at the first miss.

**Context efficiency estimate (Category 7):** Count lines in CLAUDE.md + all always-on rules that really load, with their bytes (`wc -c`) and a token estimate (bytes / 4). Report the project-only total and flag it above about 4,000 tokens, the check 7.3 threshold; tokens decide, and the line count (300 lines is roughly 4,000 tokens) is context. Report separately the total with the inherited global instruction files (`~/.claude/CLAUDE.md`, `~/.claude/rules/*.md` not owned by this repo; owned rules are already in the project total); that second total is information and does not change the status.

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
| Not verified | N |

## Recommendations

Prioritized by impact. HIGH = blocking next maturity level or causing active harm. MEDIUM = improvement opportunity. LOW = polish.

1. **[HIGH]** <what to do> — <why> (See `<doc-path>`, "<section name>")
2. **[MEDIUM]** <what to do> — <why> (See `<doc-path>`, "<section name>")
3. ...

## Global layer

<One or two lines: the counts of user-level rules, agents, skills and hooks, split into owned by this repo (installed from its root folders) and inherited. Say that the maturity level counts the project's own files, owned ones included, and that inherited setup is not credited to it. Name each "global by design" gap the checklist recorded and say it still reads as a gap in the level.>

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
