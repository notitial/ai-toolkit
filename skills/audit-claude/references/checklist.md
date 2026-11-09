# Audit Checklist

Evaluation criteria distilled from the knowledge base in `docs/`. Each check produces PASS, PARTIAL, MISSING, or N/A.

## Category 1: Project Instructions (docs 01, 08)

| # | Check | How to verify |
|---|-------|---------------|
| 1.1 | CLAUDE.md exists at repo root | Glob for `CLAUDE.md` in root |
| 1.2 | Has Project Overview section | Scan for H2 containing "overview" or "what this is" |
| 1.3 | Has Build/Test/Lint section | Scan for H2 containing "build", "test", or "lint". If no build system, section should say so explicitly |
| 1.4 | Has Architecture or Structure section | Scan for H2 containing "architecture", "structure", or "stack" |
| 1.5 | Has Conventions section | Scan for H2 containing "conventions", "patterns", or "style" |
| 1.6 | Has Git Conventions section | Scan for H2 containing "git" — commit format, branch naming |
| 1.7 | Has Key Paths table | Scan for a markdown table with "path" or "file" column header |
| 1.8 | Under 200 lines | Count lines. PARTIAL if 200-250, MISSING if >250 |
| 1.9 | Uses imperative voice | Spot-check for "Use", "Do not", "Run" vs passive "It is recommended", "We prefer" |
| 1.10 | No code examples consuming token budget | Check for fenced code blocks longer than 10 lines — these belong in rules or docs |
| 1.11 | No content that belongs in rules | Check for domain-specific or path-scoped guidance that should be a rule instead |

## Category 2: Rules (docs 02, 08)

| # | Check | How to verify |
|---|-------|---------------|
| 2.1 | Rules directory exists | Glob for `.claude/rules/` or `.cursor/rules/` |
| 2.2 | Each rule has proper frontmatter | Read each rule file: a path-scoped Claude Code rule needs `paths` (one without it is always-on, counted in 2.3), Cursor needs `globs` or `alwaysApply` |
| 2.3 | No more than 3-4 always-on rules | Count rules with `alwaysApply: true` (Cursor) or no `paths` field (Claude Code rules in CLAUDE.md) |
| 2.4 | Each rule under 300 lines | Count lines per rule file |
| 2.5 | One rule = one concern | Check if any rule covers multiple unrelated topics (git + code style + naming = kitchen-sink) |
| 2.6 | No duplication across rules | Grep for repeated directives across rule files and CLAUDE.md |
| 2.7 | Do/Don't markers present | Check for explicit "Do not", "Never", "Forbidden" vs hedging "try to avoid", "consider" |
| 2.8 | No hardcoded absolute paths | Grep for `/Users/`, `/home/`, `C:\` in rule files |
| 2.9 | Canonical ownership clear | Each major concern (logging policy, naming, security) should trace to exactly one file |

## Category 3: Agents (doc 03)

| # | Check | How to verify |
|---|-------|---------------|
| 3.1 | Agent definitions exist | Glob for `.claude/agents/*.md` or `.cursor/agents/*.md` |
| 3.2 | Each agent has identity and scope | Read each agent: does it state what it's responsible for and what directory/repo it operates in? |
| 3.3 | Tool scoping per role | Check frontmatter `tools` field (Claude Code) or execution policy prose. Reviewers should not have Write. Coordinators should not have Build |
| 3.4 | Execution policy inline | Each agent should contain its own allowed/prohibited commands block — not reference an external file |
| 3.5 | Report format defined | Check for a structured report template (status, commit, files, blockers) |
| 3.6 | Model selection matches the role's stakes | Check `model` frontmatter. Haiku for lightweight lookups, Sonnet for implementation and routine review, Opus where a miss is costly (security, architecture, payments) |
| 3.7 | No command chaining in execution policy | Grep for `&&`, `||`, `;` in allowed commands sections |

## Category 4: Skills (doc 04)

| # | Check | How to verify |
|---|-------|---------------|
| 4.1 | Skills directory exists | Glob for `.claude/skills/*/SKILL.md` or `.claude/commands/*.md`. Also glob `.claude/skills/*.md` — flat skill files are not recognized by Claude Code; flag any found and recommend restructuring into `<name>/SKILL.md` directories |
| 4.2 | Each skill has description field | Read frontmatter for `description` — needed for auto-triggering |
| 4.3 | Steps are concrete | Check that steps reference specific paths, commands, or tools — not abstract instructions |
| 4.4 | Output format defined | Check for explicit output template or format specification |
| 4.5 | Stop conditions defined | For iterative skills: check for iteration cap, convergence criteria, or explicit "when to stop" |
| 4.6 | `disable-model-invocation: true` set (or exception documented) | Check frontmatter — prevents token cost when a user-only skill is idle. `false` is acceptable only when the workflow requires model invocation and the exception is documented in the skill description or CLAUDE.md |

## Category 5: Permissions and Safety (doc 05)

| # | Check | How to verify |
|---|-------|---------------|
| 5.1 | settings.json exists | Check `.claude/settings.json` |
| 5.2 | Permissions use specific patterns | Read `permissions.allow` in `.claude/settings.json` — flag `Bash(*)` or overly broad patterns |
| 5.3 | No web tools unless justified | Check `permissions.allow` for `curl`, `wget`, `fetch` |
| 5.4 | Build commands wrapped in aliases | Check if raw build tools (`xcodebuild`, `gradlew`, `cargo`) appear vs project aliases |
| 5.5 | .gitignore covers settings.local.json | Read .gitignore for `.claude/settings.local.json` |
| 5.6 | Secret patterns excluded | Check .gitignore for `.env`, `*.jks`, `*.pem`, `*.p12`, `credentials.*` |
| 5.7 | Git MCP server configured when available | Check `~/.claude/mcp.json` or project `.mcp.json` for a git MCP server (e.g., `git-mcp`). If present, verify MCP git permissions exist in `permissions.allow`. If absent, recommend as improvement — do not penalize |
| 5.8 | No Bash git permissions when MCP available | If a git MCP server is configured, flag any remaining `Bash(git *)` entries in `permissions.allow` as migrable to MCP equivalents. N/A if no git MCP is configured |

## Category 6: Git Safety (docs 01, 05)

| # | Check | How to verify |
|---|-------|---------------|
| 6.1 | Commit message format documented | Check CLAUDE.md for commit format guidance (conventional commits, imperative mood, etc.) |
| 6.2 | Force-push restrictions mentioned | Check for "no force push" or equivalent in CLAUDE.md or rules |
| 6.3 | Secret-checking guidance present | Check for pre-commit hook references, gitleaks, or manual secret-check instructions |
| 6.4 | One-commit-per-task policy | For multi-agent setups: check orchestrator instructions for per-task commit guidance |

## Category 7: Context Efficiency (docs 08, 13)

| # | Check | How to verify |
|---|-------|---------------|
| 7.1 | CLAUDE.md under 200 lines | Already checked in 1.8 — reference that result |
| 7.2 | Rules under 300 lines each | Already checked in 2.4 — reference that result |
| 7.3 | Total always-loaded token estimate reasonable | Estimate: CLAUDE.md lines + sum of always-on rule lines. Flag if >300 total lines always-loaded |
| 7.4 | No directive duplication across files | Grep for common repeated phrases across CLAUDE.md, rules, agent definitions |
| 7.5 | No verbose content in always-loaded positions | Check for long code examples, full API specs, or reference tables in CLAUDE.md or always-on rules |
| 7.6 | Orchestrator context discipline present | If the project runs orchestrators: check for guidance that treats extended thinking as garbage-collectable (compact on task/state boundaries), delegates heavy self-contained legwork to subagents that return evidence not a verdict, and guards resume specs against wholesale re-reads. This is usually **inherited from the global install** (`~/.claude/skills/{prep-compact,handover}` + the global CLAUDE.md "Subagents & Delegation" line), which project-local discovery does not glob — check there before concluding it is absent, and report MISSING only if the project defines its OWN orchestrator/resume machinery that lacks it. Grep for a `13-orchestrator-context-discipline` reference or the phrase "re-read only specific ranges, never wholesale". N/A for non-orchestrator projects. See docs/13 |

## Category 8: Orchestration Readiness (docs 12, 11, 10, 13) — Level C only

| # | Check | How to verify |
|---|-------|---------------|
| 8.1 | Checkpoint mechanism defined | Grep for "checkpoint" in agents, skills, or docs. Check for checkpoint file pattern |
| 8.2 | Thin coordinator principle followed | If orchestrator agent exists: verify it does not have Build/Test tools and instructions say "never read code" |
| 8.3 | Convergence patterns have iteration caps | Check convergence/review skills for max pass limits (typically 2-5) |
| 8.4 | Structured report format defined | Check agent definitions for `---REPORT---` or similar delimited format |
| 8.5 | Wave-based execution present | Check orchestrator instructions for wave/batch grouping of tasks |
| 8.6 | Commit verification step exists | Check for post-completion git verification (git log check after agent reports PASS) |
| 8.7 | Severity rubric defined | Check for CRITICAL/HIGH/MEDIUM/LOW or equivalent severity scale in review agents or rules |
| 8.8 | Spec quality gate present | Check for pre-implementation validation of requirements completeness |
| 8.9 | Reviewer/generator separation | Check that code-review agents are defined as subagents with their own context (not inline self-review in the implementing agent). Reviewer agents should have read-only tool scope — no Write/Edit/Bash for modifying code. See `docs/10-reviews.md#adversarial-review-and-reviewer-failure-modes` |
| 8.10 | Reviewers are grounded and skeptical | Read each review agent. PASS if it can see test/lint/build output AND is told to assume issues exist; PARTIAL if one holds; MISSING if neither. See `docs/10-reviews.md#adversarial-review-and-reviewer-failure-modes` |
| 8.11 | Re-review / fix-loop cap has ONE loaded source of truth | The cap number is the same everywhere, lives in an always-loaded file (CLAUDE.md or rules), and doesn't grow with the loop it bounds (no "+1 per wave"). See `docs/11-convergence.md` |
| 8.12 | Review loop's terminal state is a decision, not just "escalate" | At the cap, a 2nd consecutive NO-GO or a regression, the rule names a decision (ship with filed follow-ups, revert, or one scoped question). MISSING if the only exit is escalating to a human. See `docs/11-convergence.md` |
| 8.13 | Findings have a deferred path; reviewers classify reachability | Reviewers give a reachability verdict per finding, and a defect no released client can reach can be filed as deferred instead of blocking. See `docs/10-reviews.md` |
| 8.14 | Required verifications are feasibility-checked before the loop | Before the first round, every REQUIRED check is confirmed runnable at this point in the release chain; one that can't run must not force a NO-GO. See `docs/10-reviews.md#verification-gate` |
| 8.15 | Post-compaction read discipline in resume specs | The project's own handover/continuation templates say to re-read only specific ranges of large files, never whole files. A project relying on the global `prep-compact`/`handover` skills inherits this: PASS. See `docs/13-orchestrator-context-discipline.md` |

## Category 9: Cross-Platform Parity (doc 17) — multi-platform only

| # | Check | How to verify |
|---|-------|---------------|
| 9.1 | Shared domain model defined | Check for canonical model definitions referenced by multiple platform agents or rules |
| 9.2 | Error hierarchy matching | Check for consistent error type definitions across platforms |
| 9.3 | Test naming convention shared | Check for cross-platform test naming pattern in rules or CLAUDE.md |
| 9.4 | Parity audit mechanism exists | Check for parity reviewer agent, parity table, or parity check skill |

## Category 10: Structural Context (doc 09) — Level C indicator

| # | Check | How to verify |
|---|-------|---------------|
| 10.1 | Key paths table exists in CLAUDE.md | Already checked in 1.7 — reference that result |
| 10.2 | Structural context appropriate for repo size | In a large repo (roughly 500+ files), check doc 09 Tiers 1-2: a key paths table, golden files, a CLAUDE.md in major subdirectories. Flag as PARTIAL only if those are thin and nothing else covers navigation. A missing repo map or code graph server is never a finding on file count alone: doc 09 adds them only when its "Choosing the Right Tier" signals show Tiers 1-2 fall short |
| 10.3 | Heavier structural tooling is justified | If a code-intelligence (LSP) plugin, repo map or code graph MCP server (`.mcp.json`) is configured, check that it is referenced in CLAUDE.md. N/A when none is configured |
| 10.4 | No entire-repo context dumps or LLM-built maps | Check for tools or scripts that flatten entire repos into single files for context injection, or generate a codebase map whose layers an LLM writes. Flag as anti-pattern if found (doc 09, Anti-Patterns) |
